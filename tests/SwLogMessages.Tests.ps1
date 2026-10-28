# Sweepr - tests for the console messages, the debug mode, the debug session log and the sections of
# lib\core\log.ps1.
#
# The rule numbers in the test names (LG- and S-) number the rules and the safety invariants of the
# module's behavior; each rule and invariant has at least one test.
#
# Interface pinned here (new names; each old name stays as a forwarding function):
#   Write-SwInfo, Write-SwSuccess, Write-SwWarning, Write-SwError, Write-SwDryRun [-Message]
#   Write-SwDebug [-Message]                         diagnostic line, only in debug mode
#   Write-SwDiagnosticLine [-Message]                stderr when stdout is redirected, else Write-Host
#   Test-SwOutputRedirected                          [Console]::IsOutputRedirected, $false on any failure
#   Enable-SwDebugMode, Start-SwDebugSession -Header, Complete-SwDebugSession
#   Start-SwSection [-Title], Stop-SwSection, Set-SwSectionActivity
# Script variables that tests replace: $script:LogConfig (DebugEnabled, LogFile), $script:SweeprDebugLogFile,
# $script:CurrentSection (Active, Activity, Name), $script:SectionCollector, $script:SpinnerDisabled,
# $script:Colors, $script:Icons.
#
# Seams used with Mock:
#   Write-Host                  every console line is one call with one string
#   Get-SwColor, Get-SwIcon     the tables are asked at every call
#   Stop-SwSpinner, Start-SwSpinner, Initialize-SwSpinner, Test-SwInteractiveOutput
#   Write-SwDiagnosticLine, Test-SwOutputRedirected, Write-SwSuccess, Write-SwWarning, Write-SwDebug
#   Get-Date                    one call without parameters per debug file line
#
# Platform notes:
#   - Everything lives in $TestDrive; no real log, no registry, no network.
#   - [Console]::SetError replaces the error writer for the redirected case; every test puts it back.
#   - A file held with FileShare.None refuses a second open on Windows and on Linux (advisory lock).
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    # Function, level word in the debug file, colour name and icon name of the five message writers.
    $script:HostileTexts = @(
        @{ Label = 'a NUL character'; Text = ('a' + [char]0 + 'b') }
        @{ Label = 'an escape sequence'; Text = ('a' + [char]27 + '[31mb') }
        @{ Label = 'a line break'; Text = ('a' + [char]13 + [char]10 + 'b') }
        @{ Label = 'a very long text'; Text = ('x' * 5000) }
        @{ Label = 'a lone surrogate'; Text = ('a' + [char]0xD800 + 'b') }
        @{ Label = 'format and wildcard characters'; Text = '{0} %TEMP% $(x) `n [a]*?' }
        @{ Label = 'white space only'; Text = '   ' }
        @{ Label = 'the empty string'; Text = '' }
        @{ Label = '$null'; Text = $null }
    )
    $script:Writers = @(
        @{ Name = 'Write-SwInfo'; Level = 'INFO'; Color = 'Cyan'; Icon = 'List'; Texts = $script:HostileTexts }
        @{ Name = 'Write-SwSuccess'; Level = 'SUCCESS'; Color = 'Green'; Icon = 'Success'; Texts = $script:HostileTexts }
        @{ Name = 'Write-SwWarning'; Level = 'WARN'; Color = 'Yellow'; Icon = 'Warning'; Texts = $script:HostileTexts }
        @{ Name = 'Write-SwError'; Level = 'ERROR'; Color = 'Red'; Icon = 'Error'; Texts = $script:HostileTexts }
        @{ Name = 'Write-SwDryRun'; Level = 'DRYRUN'; Color = 'Yellow'; Icon = 'DryRun'; Texts = $script:HostileTexts }
    )

    # LG-24 and S-4: text that carries a terminal sequence or another control character.
    $script:SectionTitles = @(
        @{ Label = 'a plain title'; Title = 'User cleanup' }
        @{ Label = 'a title with an escape sequence'; Title = ('a' + [char]27 + '[31mb') }
        @{ Label = 'a title with a NUL character'; Title = ('a' + [char]0 + 'b') }
        @{ Label = 'a title with a line break'; Title = ('a' + [char]13 + [char]10 + 'b') }
        @{ Label = 'the empty title'; Title = '' }
    )
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:CoreDir = [System.IO.Path]::Combine($script:RepoRoot, 'lib', 'core')
    $script:LogScript = [System.IO.Path]::Combine($script:CoreDir, 'log.ps1')
    $script:HistoryScript = [System.IO.Path]::Combine($script:CoreDir, 'history.ps1')
    $script:OnWindows = [System.IO.Path]::DirectorySeparatorChar -eq '\'
    $script:Sep = [string][System.IO.Path]::DirectorySeparatorChar
    $script:WorkCounter = 0
    $script:Crlf = [string][char]13 + [string][char]10
    $script:Esc = [string][char]27
    $script:Utf8 = New-Object System.Text.UTF8Encoding $false
    # The patterns of the readers of the log, spelled the same way.
    $script:Options = [System.Text.RegularExpressions.RegexOptions]::CultureInvariant -bor [System.Text.RegularExpressions.RegexOptions]::Singleline
    $script:RecordPattern = New-Object System.Text.RegularExpressions.Regex('\A\[([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})\] \[([^\s\]]+)(?: run=([^\s\]]+))?\] ([A-Z]+) (.+) \(([^()]*)\)\z', $script:Options)
    $script:MarkerPattern = New-Object System.Text.RegularExpressions.Regex('\A# ={10} ([^\s\]]+)(?: run=([^\s\]]+))? session started at (.+?) ={10}\z', $script:Options)

    # ---- environment and script variables ---------------------------------------------------------

    function script:Save-Env([string[]]$Names) {
        $saved = @{}
        foreach ($name in $Names) { $saved[$name] = [System.Environment]::GetEnvironmentVariable($name) }
        $saved
    }
    function script:Restore-Env([hashtable]$Saved) {
        foreach ($name in @($Saved.Keys)) {
            $value = $Saved[$name]
            if ($null -eq $value) { $value = [NullString]::Value }
            [System.Environment]::SetEnvironmentVariable($name, $value)
        }
    }
    # An empty value removes the variable. Since .NET 10 SetEnvironmentVariable(name, "") keeps the
    # variable with an empty value, and PowerShell 7.6 passes a plain $null to the method as "";
    # only [NullString]::Value is a real null.
    function script:Set-Env([string]$Name, [AllowNull()][AllowEmptyString()][string]$Value) {
        if ([string]::IsNullOrEmpty($Value)) { [System.Environment]::SetEnvironmentVariable($Name, [NullString]::Value) }
        else { [System.Environment]::SetEnvironmentVariable($Name, $Value) }
    }
    $script:EnvNames = @('SWEEPR_NO_OPLOG', 'SWEEPR_DRY_RUN', 'SWEEPR_DEBUG', 'SWEEPR_DATA_DIR', '_SWEEPR_OPLOG_RUN_COMMAND',
        '_SWEEPR_OPLOG_RUN_ID', 'USERPROFILE', 'TERM', 'NO_COLOR', 'ZZ_SWEEPR_LOG_TEST')
    $script:StateNames = @('Config', 'Colors', 'Icons', 'SWEEPR_LOG_LOADED', 'SweeprOperationsLogFile', 'SweeprOperationsLogMaxBytes',
        'SweeprOperationsLogStarted', 'SweeprDebugLogFile', 'SweeprLogDir', 'LogConfig', 'CurrentSection', 'SectionCollector',
        'SpinnerDisabled', 'Clock', 'DateCalls', 'DateCallsWithArguments', 'Texts', 'Messages', 'Hosted', 'Order', 'Sleeps', 'Calls')
    function script:Save-State {
        $state = @{}
        foreach ($name in $script:StateNames) {
            $variable = Get-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue
            if ($null -eq $variable) { $state[$name] = @{ Exists = $false; Value = $null }; continue }
            $value = $variable.Value
            if ($value -is [hashtable]) { $value = $value.Clone() }
            $state[$name] = @{ Exists = $true; Value = $value }
        }
        $state
    }
    function script:Restore-State([hashtable]$State) {
        foreach ($name in $script:StateNames) {
            $entry = $State[$name]
            if ($entry.Exists) {
                $value = $entry.Value
                if ($value -is [hashtable]) { $value = $value.Clone() }
                Set-Variable -Name $name -Scope Script -Value $value
            }
            else { Remove-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue }
        }
    }

    # ---- file system helpers ----------------------------------------------------------------------

    function script:P {
        param([string]$Base, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Parts)
        $result = $Base
        foreach ($part in $Parts) { $result = [System.IO.Path]::Combine($result, $part) }
        $result
    }
    function script:New-Dir([string]$Path) { [void][System.IO.Directory]::CreateDirectory($Path); $Path }
    function script:New-Work {
        $script:WorkCounter++
        New-Dir (P $TestDrive ('w' + $script:WorkCounter))
    }
    # Name, kind and length of everything below a folder, sorted; '<missing>' for a folder that is not there.
    function script:Get-Listing([string]$Root) {
        if (-not [System.IO.Directory]::Exists($Root)) { return '<missing>' }
        $rows = New-Object System.Collections.Generic.List[string]
        $base = [System.IO.Path]::GetFullPath($Root)
        foreach ($item in @(Get-ChildItem -LiteralPath $Root -Recurse -Force)) {
            $rel = $item.FullName.Substring($base.Length).TrimStart('\', '/')
            if ($item.PSIsContainer) { $rows.Add("D $rel") } else { $rows.Add("F $rel $($item.Length)") }
        }
        @($rows | Sort-Object)
    }
    # Both separators folded, no case, no trailing separator: the comparison form of a path.
    function script:Get-Cmp([string]$Path) { $Path.Replace('\', '/').TrimEnd('/').ToLowerInvariant() }

    function script:Assert-Defined([string[]]$Names) {
        foreach ($name in $Names) {
            ($null -ne (Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue)) | Should -BeTrue -Because "$name must be defined after loading"
        }
    }
    # Runs a block that must throw and gives the error record. A block that does not throw fails the test,
    # and so does a block that only fails because a function does not exist.
    function script:Assert-Throws([scriptblock]$Block) {
        $failure = $null
        try { $null = & $Block } catch { $failure = $_ }
        if ($null -eq $failure) { throw 'expected an exception, but there was none' }
        if ($failure.Exception -is [System.Management.Automation.CommandNotFoundException]) { throw ('the function does not exist: ' + $failure.Exception.Message) }
        $failure
    }
    # True when the exception or one of its inner exceptions is of the type (method calls wrap the error).
    function script:Test-ExceptionChain($Exception, [type]$Type) {
        $current = $Exception
        while ($null -ne $current) {
            if ($Type.IsInstanceOfType($current)) { return $true }
            $current = $current.InnerException
        }
        $false
    }
    # Everything a block writes to any stream, as a list.
    function script:Get-AllOutput([scriptblock]$Block) {
        , @(& $Block 2>&1 3>&1 4>&1 5>&1 6>&1)
    }

    # ---- reading the operations log ---------------------------------------------------------------

    function script:Get-LogText([string]$Path) { $script:Utf8.GetString([System.IO.File]::ReadAllBytes($Path)) }
    # All lines of the file, empty ones included; a missing file gives no lines.
    function script:Get-LogLines([string]$Path) {
        if (-not [System.IO.File]::Exists($Path)) { return }
        [regex]::Split((Get-LogText $Path), [regex]::Escape($script:Crlf))
    }
    function script:Get-RecordLines([string]$Path) {
        @(Get-LogLines $Path) | Where-Object { $_.Length -gt 0 -and $_[0] -eq [char]'[' }
    }
    function script:Get-MarkerLines([string]$Path) {
        @(Get-LogLines $Path) | Where-Object { $_.Length -gt 0 -and $_[0] -eq [char]'#' }
    }
    # The match of the record pattern for the one record in the file.
    function script:Get-OneRecord([string]$Path) {
        $records = @(Get-RecordLines $Path)
        $records.Count | Should -Be 1 -Because 'one record was written'
        $match = $script:RecordPattern.Match($records[0])
        $match.Success | Should -BeTrue -Because "the line matches the record pattern: $($records[0])"
        $match
    }

    # The expected form of a path or detail, written independently of the module.
    function script:Get-Escaped([string]$Text) {
        if ($null -eq $Text) { return '' }
        $builder = New-Object System.Text.StringBuilder
        foreach ($char in $Text.ToCharArray()) {
            $code = [int]$char
            if ($code -eq 9) { [void]$builder.Append('\t') }
            elseif ($code -eq 10) { [void]$builder.Append('\n') }
            elseif ($code -eq 13) { [void]$builder.Append('\r') }
            elseif ($code -lt 32 -or $code -eq 127) { [void]$builder.Append('\x' + $code.ToString('x2')) }
            else { [void]$builder.Append($char) }
        }
        $builder.ToString()
    }
    function script:Get-ExpectedDetail([string]$Detail) {
        if ([string]::IsNullOrEmpty($Detail)) { return '-' }
        (Get-Escaped $Detail).Replace('(', '[').Replace(')', ']')
    }

    # ---- seams ------------------------------------------------------------------------------------

    # A frozen clock: a call of Get-Date answers $script:Clock; calls with parameters are counted apart.
    function script:Use-Clock([datetime]$At = ([datetime]'2026-10-15 10:00:01')) {
        $script:Clock = $At
        $script:DateCalls = 0
        $script:DateCallsWithArguments = 0
        Mock Get-Date {
            $script:DateCalls++
            if (-not [string]::IsNullOrEmpty($Format) -or -not [string]::IsNullOrEmpty($UFormat) -or $null -ne $Date -or $Year -ne 0 -or $Month -ne 0 -or $Day -ne 0 -or
                $Hour -ne 0 -or $Minute -ne 0 -or $Second -ne 0 -or $Millisecond -ne 0) { $script:DateCallsWithArguments++ }
            $script:Clock
        }
    }
    # Records the text of every message about a line that was not written (or any debug message).
    function script:Use-DebugCapture {
        $script:Messages = New-Object System.Collections.Generic.List[string]
        Mock Write-SwDebug { $script:Messages.Add([string]$Message) }
    }

    # ---- child processes --------------------------------------------------------------------------

    function script:Invoke-ChildPowerShell {
        param([string]$Script, [string]$WorkingDirectory = $TestDrive, [hashtable]$Environment = @{}, [string[]]$RemoveEnvironment = @())
        $exe = (Get-Process -Id $PID).Path
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Script))
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.WorkingDirectory = $WorkingDirectory
        foreach ($name in $RemoveEnvironment) { if ($psi.EnvironmentVariables.ContainsKey($name)) { $psi.EnvironmentVariables.Remove($name) } }
        foreach ($name in $Environment.Keys) { $psi.EnvironmentVariables[$name] = [string]$Environment[$name] }
        $process = [System.Diagnostics.Process]::Start($psi)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { $process.Kill(); throw 'child PowerShell timed out' }
        [pscustomobject]@{ ExitCode = $process.ExitCode; Out = $stdout.Result; Err = $stderr.Result }
    }
    # Windows PowerShell serializes progress records into redirected stderr as CLIXML. That is the host
    # talking, not the loaded file: drop the progress records and the envelope, keep anything else.
    function script:Get-ChildStderr([string]$Text) {
        if ([string]::IsNullOrEmpty($Text)) { return '' }
        $clean = [regex]::Replace($Text, '(?s)<Obj S="progress".*?</Obj>', '')
        $clean = [regex]::Replace($clean, '<Objs[^>]*>|</Objs>|#< CLIXML', '')
        $clean.Trim()
    }
    function script:ConvertTo-TestLiteral([string]$Value) { "'" + $Value.Replace("'", "''") + "'" }

    # ---- per-test state ---------------------------------------------------------------------------

    function script:Start-Case {
        $script:SavedState = Save-State
        $script:SavedEnv = Save-Env $script:EnvNames
        foreach ($name in 'SWEEPR_NO_OPLOG', 'SWEEPR_DRY_RUN', 'SWEEPR_DEBUG', '_SWEEPR_OPLOG_RUN_COMMAND', '_SWEEPR_OPLOG_RUN_ID', 'ZZ_SWEEPR_LOG_TEST') { Set-Env $name $null }
        $script:Work = New-Work
        $script:Dir = P $script:Work 'config'
        $script:LogPath = P $script:Dir 'operations.log'
        $script:DebugPath = P $script:Dir 'sweepr_debug_session.log'
        $script:Config = @{ ConfigPath = $script:Dir; CachePath = (P $script:Work 'cache'); WhitelistFile = (P $script:Dir 'whitelist.txt') }
        $script:SweeprOperationsLogFile = $script:LogPath
        $script:SweeprOperationsLogStarted = $false
        $script:SweeprOperationsLogMaxBytes = 5242880
        $script:SweeprDebugLogFile = $script:DebugPath
        $script:LogConfig = @{ DebugEnabled = $false; LogFile = $null }
        $script:CurrentSection = @{ Active = $false; Activity = $false; Name = '' }
        $script:SectionCollector = $null
        $script:SpinnerDisabled = $true
    }
    function script:Stop-Case {
        Restore-Env $script:SavedEnv
        Restore-State $script:SavedState
    }

    # ---- helpers for the message tests ------------------------------------------------------------

    # What a console text becomes: controls other than tab, line feed and carriage return, and U+007F to
    # U+009F, turn into a space.
    function script:Get-Sanitized([AllowNull()][string]$Text) {
        if ($null -eq $Text) { return '' }
        $builder = New-Object System.Text.StringBuilder
        foreach ($char in $Text.ToCharArray()) {
            $code = [int]$char
            $keep = ($code -eq 9 -or $code -eq 10 -or $code -eq 13)
            if (($code -lt 32 -and -not $keep) -or ($code -ge 127 -and $code -le 159)) { [void]$builder.Append(' ') }
            else { [void]$builder.Append($char) }
        }
        $builder.ToString()
    }
    function script:Remove-Ansi([string]$Text) { [regex]::Replace($Text, ([string][char]27) + '\[[0-9;]*[A-Za-z]', '') }

    # Every call of Write-Host: the arguments, how many, and whether other parameters were used.
    function script:Use-HostCapture {
        $script:Hosted = New-Object System.Collections.Generic.List[object]
        $script:Order = New-Object System.Collections.Generic.List[string]
        Mock Write-Host {
            $script:Order.Add('host')
            $script:Hosted.Add(@{ Items = @($Object); NoNewline = [bool]$NoNewline; Foreground = $ForegroundColor; Background = $BackgroundColor; Separator = $Separator })
        }
    }
    # Colours and symbols that show which name was asked for.
    function script:Use-Marks {
        Mock Get-SwColor { 'C<' + $Name + '>' }
        Mock Get-SwIcon { 'I<' + $Name + '>' }
    }
    function script:Use-SpinnerRecorder {
        Mock Stop-SwSpinner { $script:Order.Add('stop') }
        Mock Start-SwSpinner { $script:Order.Add('start') }
    }
    function script:Use-RealTables {
        $script:Colors = Get-SwDefaultColors
        $script:Icons = Get-SwDefaultIcons
    }
    # The text lines of the console, one per call; a call without a text gives an empty line.
    function script:Get-HostLines { @($script:Hosted | ForEach-Object { if (@($_.Items).Count -eq 0) { '' } else { [string]$_.Items[0] } }) }

    function script:Open-Held([string]$Path, [string]$Share = 'None', [string]$Access = 'ReadWrite') {
        [void](New-Dir ([System.IO.Path]::GetDirectoryName($Path)))
        $script:Holder = [System.IO.File]::Open($Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]$Access, [System.IO.FileShare]$Share)
    }
    function script:Close-Held {
        if ($null -ne $script:Holder) { $script:Holder.Dispose(); $script:Holder = $null }
    }
    # The debug file is on: the folder exists and LogConfig names the file.
    function script:Use-DebugFile([bool]$DebugEnabled = $false) {
        [void](New-Dir $script:Dir)
        $script:LogConfig = @{ DebugEnabled = $DebugEnabled; LogFile = $script:DebugPath }
    }
    # The expected line of the debug file for a message.
    function script:Get-ExpectedFileLine([string]$Level, [string]$Text, [string]$Time = '10:00:01') {
        $Time + ' [' + $Level + '] ' + (Get-Escaped $Text)
    }

    # What the whole file changes in the process, put back after the last test.
    $script:RootState = Save-State
    $script:RootEnv = Save-Env $script:EnvNames
    $script:RootError = [Console]::Error
    $script:Holder = $null
    . $script:LogScript
}

AfterAll {
    Close-Held
    [Console]::SetError($script:RootError)
    Restore-State $script:RootState
    Restore-Env $script:RootEnv
}

# ============================================================================
# The five message writers
# ============================================================================

Describe 'Message writers: the line' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Write-SwInfo', 'Write-SwSuccess', 'Write-SwWarning', 'Write-SwError', 'Write-SwDryRun'
        Use-HostCapture
        Use-SpinnerRecorder
        Use-RealTables
    }
    AfterEach { Stop-Case }

    It 'LG-20 builds <Name> from the colour <Color> and the symbol <Icon>, both asked for at the time of the call' -ForEach $script:Writers {
        Use-Marks
        & $Name -Message 'x'
        $script:Hosted.Count | Should -Be 1
        $script:Hosted[0].Items[0] | Should -BeExactly ('  ' + 'C<' + $Color + '>' + 'I<' + $Icon + '>' + ' ' + 'C<NC>' + 'x')
    }

    It 'LG-21 calls Write-Host once with one string and no other parameter: <Name>' -ForEach $script:Writers {
        & $Name -Message 'x'
        $script:Hosted.Count | Should -Be 1
        @($script:Hosted[0].Items).Count | Should -Be 1
        $script:Hosted[0].Items[0] | Should -BeOfType [string]
        $script:Hosted[0].NoNewline | Should -BeFalse
        $script:Hosted[0].Foreground | Should -BeNullOrEmpty
        $script:Hosted[0].Background | Should -BeNullOrEmpty
        $script:Hosted[0].Separator | Should -BeNullOrEmpty
    }

    It 'LG-21 writes two spaces, the colour, the symbol, a space, the reset sequence and the text with the real tables: <Name>' -ForEach $script:Writers {
        & $Name -Message 'Cleaned'
        $expected = '  ' + $script:Colors[$Color] + $script:Icons[$Icon] + ' ' + $script:Colors['NC'] + 'Cleaned'
        $script:Hosted[0].Items[0] | Should -BeExactly $expected
        (Remove-Ansi $script:Hosted[0].Items[0]) | Should -BeExactly ('  ' + $script:Icons[$Icon] + ' Cleaned')
    }

    It 'LG-21 leaves out the symbol and its space when the symbol is empty or unknown: <Name>' -ForEach $script:Writers {
        Mock Get-SwColor { 'C<' + $Name + '>' }
        Mock Get-SwIcon { $script:IconAnswer }
        foreach ($value in @('', $null)) {
            $script:Hosted.Clear()
            $script:IconAnswer = $value
            { & $Name -Message 'x' } | Should -Not -Throw
            $script:Hosted[0].Items[0] | Should -BeExactly ('  ' + 'C<' + $Color + '>' + 'C<NC>' + 'x')
        }
    }

    It 'LG-21 counts $null from Get-SwColor as an empty string, without the text null: <Name>' -ForEach $script:Writers {
        Mock Get-SwColor { $null }
        Mock Get-SwIcon { 'I<' + $Name + '>' }
        { & $Name -Message 'x' } | Should -Not -Throw
        $script:Hosted[0].Items[0] | Should -BeExactly ('  ' + 'I<' + $Icon + '>' + ' ' + 'x')
    }

    It 'LG-21 writes an empty text for $null and for the empty string: <Name>' -ForEach $script:Writers {
        Use-Marks
        foreach ($value in @($null, '')) {
            $script:Hosted.Clear()
            & $Name -Message $value
            $script:Hosted[0].Items[0] | Should -BeExactly ('  ' + 'C<' + $Color + '>' + 'I<' + $Icon + '>' + ' ' + 'C<NC>')
        }
    }

    It 'LG-21 takes the colours from the colour function whatever NO_COLOR says: <Name>' -ForEach $script:Writers {
        Use-Marks
        Set-Env 'NO_COLOR' '1'
        & $Name -Message 'x'
        $script:Hosted[0].Items[0] | Should -BeExactly ('  ' + 'C<' + $Color + '>' + 'I<' + $Icon + '>' + ' ' + 'C<NC>' + 'x')
    }

    It 'LG-21 takes the message by position: <Name>' -ForEach $script:Writers {
        Use-Marks
        & $Name 'by position'
        $script:Hosted[0].Items[0] | Should -BeExactly ('  ' + 'C<' + $Color + '>' + 'I<' + $Icon + '>' + ' ' + 'C<NC>' + 'by position')
    }

    It 'LG-21 reads the colour and symbol tables at every call: <Name>' -ForEach $script:Writers {
        $script:Colors[$Color] = 'FIRST'
        $script:Icons[$Icon] = '1'
        & $Name -Message 'x'
        $script:Colors[$Color] = 'SECOND'
        $script:Icons[$Icon] = '2'
        & $Name -Message 'x'
        $script:Hosted[0].Items[0] | Should -BeExactly ('  FIRST1 ' + $script:Colors['NC'] + 'x')
        $script:Hosted[1].Items[0] | Should -BeExactly ('  SECOND2 ' + $script:Colors['NC'] + 'x')
    }

    It 'LG-21 repairs a symbol table without the symbol and still writes the line: <Name>' -ForEach $script:Writers {
        $script:Icons = @{ Solid = '*' }
        { & $Name -Message 'x' } | Should -Not -Throw
        $script:Icons.ContainsKey($Icon) | Should -BeTrue
        $script:Icons[$Icon] | Should -Not -BeNullOrEmpty
        (Remove-Ansi $script:Hosted[0].Items[0]) | Should -BeExactly ('  ' + $script:Icons[$Icon] + ' x')
    }

    It 'LG-21 survives a missing colour and symbol table: <Name>' -ForEach $script:Writers {
        Remove-Variable -Name Colors, Icons -Scope Script
        { & $Name -Message 'x' } | Should -Not -Throw
        $script:Hosted.Count | Should -Be 1
        (Remove-Ansi $script:Hosted[0].Items[0]) | Should -BeLike '  * x'
    }
}

Describe 'Message writers: the spinner, the channel and the text' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Write-SwInfo', 'Write-SwSuccess', 'Write-SwWarning', 'Write-SwError', 'Write-SwDryRun', 'Test-SwOutputRedirected', 'Write-SwDiagnosticLine'
        Use-RealTables
        $script:SavedError = [Console]::Error
    }
    AfterEach { [Console]::SetError($script:SavedError); Stop-Case }

    It 'LG-22 stops the spinner, writes the line and starts the spinner once while a section is active: <Name>' -ForEach $script:Writers {
        Use-HostCapture
        Use-SpinnerRecorder
        $script:CurrentSection = @{ Active = $true; Activity = $false; Name = 'X' }
        & $Name -Message 'x'
        ($script:Order -join ',') | Should -BeExactly 'stop,host,start'
    }

    It 'LG-22 stops the spinner and does not start it when no section is active: <Name>' -ForEach $script:Writers {
        Use-HostCapture
        Use-SpinnerRecorder
        $script:CurrentSection = @{ Active = $false; Activity = $false; Name = '' }
        & $Name -Message 'x'
        ($script:Order -join ',') | Should -BeExactly 'stop,host'
    }

    It 'LG-23 returns nothing to the pipeline and writes one information record and nothing else: <Name>' -ForEach $script:Writers {
        $streams = Get-AllOutput { & $Name -Message 'x' }
        $streams.Count | Should -Be 1
        ($streams[0] -is [System.Management.Automation.InformationRecord]) | Should -BeTrue
        "$($streams[0])" | Should -BeLike '*x'
    }

    It 'LG-23 uses neither the warning nor the error stream, also for a warning and an error: <Name>' -ForEach $script:Writers {
        $streams = Get-AllOutput { & $Name -Message 'x' }
        foreach ($record in $streams) {
            ($record -is [System.Management.Automation.WarningRecord]) | Should -BeFalse
            ($record -is [System.Management.Automation.ErrorRecord]) | Should -BeFalse
            ($record -is [System.Management.Automation.VerboseRecord]) | Should -BeFalse
            ($record -is [System.Management.Automation.DebugRecord]) | Should -BeFalse
        }
    }

    It 'LG-23 is silenced completely by 6>$null: <Name>' -ForEach $script:Writers {
        $output = @(& { & $Name -Message 'x' } 6>$null)
        $output.Count | Should -Be 0
    }

    It 'LG-23 still writes to the information stream and not to stderr when standard output is redirected: <Name>' -ForEach $script:Writers {
        Mock Test-SwOutputRedirected { $true }
        $writer = New-Object System.IO.StringWriter
        [Console]::SetError($writer)
        $streams = Get-AllOutput { & $Name -Message 'x' }
        $streams.Count | Should -Be 1
        ($streams[0] -is [System.Management.Automation.InformationRecord]) | Should -BeTrue
        $writer.ToString() | Should -BeExactly ''
    }

    It 'LG-24 turns every control character except tab, line feed and carriage return, and U+007F to U+009F, into a space: <Name>' -ForEach $script:Writers {
        Use-HostCapture
        Use-SpinnerRecorder
        Mock Get-SwColor { '' }
        Mock Get-SwIcon { '' }
        $builder = New-Object System.Text.StringBuilder
        foreach ($code in @(0..255)) { [void]$builder.Append('<' + [char]$code + '>') }
        $text = $builder.ToString()
        & $Name -Message $text
        $script:Hosted[0].Items[0] | Should -BeExactly ('  ' + (Get-Sanitized $text))
    }

    It 'LG-24 keeps tab, line feed and carriage return, so a text with a line feed stays on more than one line: <Name>' -ForEach $script:Writers {
        Use-HostCapture
        Use-SpinnerRecorder
        Mock Get-SwColor { '' }
        Mock Get-SwIcon { '' }
        $text = 'one' + [char]10 + 'two' + [char]9 + 'three' + [char]13 + 'four'
        & $Name -Message $text
        $script:Hosted[0].Items[0] | Should -BeExactly ('  ' + $text)
    }

    It 'LG-24 keeps text above U+009F: <Name>' -ForEach $script:Writers {
        Use-HostCapture
        Use-SpinnerRecorder
        Mock Get-SwColor { '' }
        Mock Get-SwIcon { '' }
        $text = 'a' + [char]0xA0 + [char]0xDC + [char]0x4E2D + [char]0xD83D + [char]0xDE00 + [char]0x2028 + 'z'
        & $Name -Message $text
        $script:Hosted[0].Items[0] | Should -BeExactly ('  ' + $text)
    }

    It 'S-4 shows a terminal sequence from a file name as text, with the escape character gone: <Name>' -ForEach $script:Writers {
        Use-HostCapture
        Use-SpinnerRecorder
        Mock Get-SwColor { '' }
        Mock Get-SwIcon { '' }
        & $Name -Message ('x' + [char]27 + '[31my')
        $script:Hosted[0].Items[0] | Should -BeExactly '  x [31my'
        $script:Hosted[0].Items[0].Contains([string][char]27) | Should -BeFalse
    }

    It 'S-4 keeps the escape characters of the module itself outside the text: <Name>' -ForEach $script:Writers {
        Use-HostCapture
        Use-SpinnerRecorder
        & $Name -Message ('x' + [char]27 + '[31my')
        $line = $script:Hosted[0].Items[0]
        $line.StartsWith('  ' + $script:Colors[$Color]) | Should -BeTrue
        $line.EndsWith($script:Colors['NC'] + 'x [31my') | Should -BeTrue
    }

    It 'S-6 keeps format placeholders, variables and wildcards of the text as they are: <Name>' -ForEach $script:Writers {
        Use-HostCapture
        Use-SpinnerRecorder
        Mock Get-SwColor { '' }
        Mock Get-SwIcon { '' }
        Set-Env 'ZZ_SWEEPR_LOG_TEST' 'expanded'
        $text = 'C:\{0} %ZZ_SWEEPR_LOG_TEST% $(Get-Date) $env:ZZ_SWEEPR_LOG_TEST [a]*? {1:N2}'
        & $Name -Message $text
        $script:Hosted[0].Items[0] | Should -BeExactly ('  ' + $text)
    }

    It 'S-3 throws for no text and writes at most one line: <Name>' -ForEach $script:Writers {
        Use-HostCapture
        Use-SpinnerRecorder
        Use-DebugFile $true
        Mock Write-SwDiagnosticLine { }
        foreach ($item in $Texts) {
            $text = $item.Text
            $script:Hosted.Clear()
            $failure = $null
            try { & $Name -Message $text } catch { $failure = $_ }
            ($null -eq $failure) | Should -BeTrue -Because "$Name with $($item.Label) threw: $failure"
            $script:Hosted.Count | Should -Be 1 -Because "one line for $($item.Label)"
        }
    }
}

# ============================================================================
# The debug file written by the message writers
# ============================================================================

Describe 'Message writers: the debug file' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Write-SwInfo', 'Write-SwSuccess', 'Write-SwWarning', 'Write-SwError', 'Write-SwDryRun', 'Write-SwDebug', 'Write-SwDiagnosticLine'
        Use-HostCapture
        Use-SpinnerRecorder
        Use-RealTables
        Use-Clock
        Mock Write-SwDiagnosticLine { }
    }
    AfterEach { Close-Held; Stop-Case }

    It 'LG-25 appends HH:mm:ss [LEVEL] text to the debug file, whether debug mode is on or off: <Name>' -ForEach $script:Writers {
        foreach ($enabled in @($false, $true)) {
            if (Test-Path -LiteralPath $script:DebugPath) { [System.IO.File]::Delete($script:DebugPath) }
            Use-DebugFile $enabled
            & $Name -Message 'x (1)'
            Get-LogText $script:DebugPath | Should -BeExactly ('10:00:01 [' + $Level + '] x (1)' + $script:Crlf)
        }
    }

    It 'LG-25 appends to what the file holds and does not replace it' {
        Use-DebugFile
        [System.IO.File]::WriteAllText($script:DebugPath, ('previous line' + $script:Crlf))
        Write-SwInfo 'first'
        Write-SwWarning 'second'
        Get-LogText $script:DebugPath | Should -BeExactly ('previous line' + $script:Crlf + '10:00:01 [INFO] first' + $script:Crlf + '10:00:01 [WARN] second' + $script:Crlf)
    }

    It 'LG-25 creates nothing when LogConfig.LogFile is not set: <Label>' -ForEach @(
        @{ Label = 'null'; Value = $null }
        @{ Label = 'the empty string'; Value = '' }
    ) {
        $script:LogConfig = @{ DebugEnabled = $true; LogFile = $Value }
        Write-SwInfo 'x'
        [System.IO.File]::Exists($script:DebugPath) | Should -BeFalse
        [System.IO.Directory]::Exists($script:Dir) | Should -BeFalse
        $script:Hosted.Count | Should -Be 1
    }

    It 'LG-25 reads LogConfig.LogFile at every call' {
        Use-DebugFile
        $other = P $script:Dir 'other.log'
        Write-SwInfo 'one'
        $script:LogConfig = @{ DebugEnabled = $false; LogFile = $other }
        Write-SwInfo 'two'
        Get-LogText $script:DebugPath | Should -BeExactly ('10:00:01 [INFO] one' + $script:Crlf)
        Get-LogText $other | Should -BeExactly ('10:00:01 [INFO] two' + $script:Crlf)
    }

    It 'LG-8 reads the clock once for a line of the debug file, without parameters' {
        Use-DebugFile
        Write-SwInfo 'x'
        $script:DateCalls | Should -Be 1
        $script:DateCallsWithArguments | Should -Be 0
    }

    It 'LG-8 writes the time of the debug file with 24 hours and two digits' {
        Use-DebugFile
        $script:Clock = [datetime]'2026-01-02 15:04:05'
        Write-SwInfo 'afternoon'
        $script:Clock = [datetime]'2026-01-02 03:04:05'
        Write-SwInfo 'night'
        Get-LogText $script:DebugPath | Should -BeExactly ('15:04:05 [INFO] afternoon' + $script:Crlf + '03:04:05 [INFO] night' + $script:Crlf)
    }

    It 'LG-31 writes one line for a message with a line feed, with the control characters written out: <Name>' -ForEach $script:Writers {
        Use-DebugFile
        $text = 'a' + [char]10 + 'b' + [char]9 + 'c' + [char]13 + 'd' + [char]27 + 'e' + [char]0 + 'f'
        & $Name -Message $text
        Get-LogText $script:DebugPath | Should -BeExactly ('10:00:01 [' + $Level + '] a\nb\tc\rd\x1be\x00f' + $script:Crlf)
    }

    It 'LG-31 keeps parentheses and brackets in the debug file' {
        Use-DebugFile
        Write-SwInfo 'x (1) [2]'
        Get-LogText $script:DebugPath | Should -BeExactly ('10:00:01 [INFO] x (1) [2]' + $script:Crlf)
    }

    It 'LG-31 writes UTF-8 without a byte order mark, with CRLF' {
        Use-DebugFile
        Write-SwInfo ('Uebung ' + [char]0xDC)
        $bytes = [System.IO.File]::ReadAllBytes($script:DebugPath)
        $bytes[0] | Should -Be 0x31
        $script:Utf8.GetString($bytes) | Should -BeExactly ('10:00:01 [INFO] Uebung ' + [char]0xDC + $script:Crlf)
        $bytes[$bytes.Length - 2] | Should -Be 13
        $bytes[$bytes.Length - 1] | Should -Be 10
    }

    It 'LG-31 does not throw, show anything extra or create the folder when the folder of the debug file is missing: <Name>' -ForEach $script:Writers {
        Mock Write-SwDebug { }
        Mock Start-Sleep { }
        $script:LogConfig = @{ DebugEnabled = $true; LogFile = (P $script:Work 'missing' 'debug.log') }
        { & $Name -Message 'x' } | Should -Not -Throw
        [System.IO.Directory]::Exists((P $script:Work 'missing')) | Should -BeFalse
        $script:Hosted.Count | Should -Be 1
        Should -Invoke -CommandName Write-SwDebug -Times 0 -Exactly
        Should -Invoke -CommandName Start-Sleep -Times 0 -Exactly
    }

    It 'LG-31 does not throw and does not call Write-SwDebug when the debug file is a folder' {
        Mock Write-SwDebug { }
        $folder = New-Dir (P $script:Dir 'debug.log')
        $script:LogConfig = @{ DebugEnabled = $true; LogFile = $folder }
        { Write-SwInfo 'x' } | Should -Not -Throw
        Should -Invoke -CommandName Write-SwDebug -Times 0 -Exactly
        $script:Hosted.Count | Should -Be 1
    }

    It 'LG-31 does not retry and does not throw when another process holds the debug file' {
        Mock Write-SwDebug { }
        Mock Start-Sleep { }
        Use-DebugFile
        [System.IO.File]::WriteAllText($script:DebugPath, 'held')
        Open-Held $script:DebugPath 'None'
        { Write-SwInfo 'x' } | Should -Not -Throw
        Should -Invoke -CommandName Start-Sleep -Times 0 -Exactly
        Should -Invoke -CommandName Write-SwDebug -Times 0 -Exactly
        Close-Held
        [System.IO.File]::ReadAllText($script:DebugPath) | Should -BeExactly 'held'
    }

    It 'LG-31 does not rotate the debug file' {
        Use-DebugFile
        $script:SweeprOperationsLogMaxBytes = 4
        [System.IO.File]::WriteAllText($script:DebugPath, ('x' * 64))
        Write-SwInfo 'x'
        [System.IO.File]::Exists($script:DebugPath + '.old') | Should -BeFalse
        (Get-LogText $script:DebugPath).StartsWith('x' * 64) | Should -BeTrue
    }

    It 'S-3 throws for no text in the debug file and writes one line: <Name>' -ForEach $script:Writers {
        Use-DebugFile $true
        foreach ($item in $Texts) {
            $text = $item.Text
            $failure = $null
            try { & $Name -Message $text } catch { $failure = $_ }
            ($null -eq $failure) | Should -BeTrue -Because "$Name with $($item.Label) threw: $failure"
        }
        $lines = @(Get-LogLines $script:DebugPath | Where-Object { $_.Length -gt 0 })
        $lines.Count | Should -Be $Texts.Count
        foreach ($line in $lines) {
            $line | Should -Match '^10:00:01 \[[A-Z]+\] '
            @($line.ToCharArray() | Where-Object { [int]$_ -lt 32 -or [int]$_ -eq 127 }).Count | Should -Be 0 -Because 'no raw control character in the debug file'
        }
    }
}

# ============================================================================
# Write-SwDebug
# ============================================================================

Describe 'Write-SwDebug' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Write-SwDebug', 'Write-SwDiagnosticLine', 'Stop-SwSpinner', 'Start-SwSpinner'
        Use-HostCapture
        Use-SpinnerRecorder
        Use-RealTables
        Use-Clock
        $script:Lines = New-Object System.Collections.Generic.List[string]
        Mock Write-SwDiagnosticLine { $script:Order.Add('diag'); $script:Lines.Add([string]$Message) }
    }
    AfterEach { Stop-Case }

    It 'LG-26 does nothing when debug mode is off: no line, no file, no spinner call, even with a debug file set' {
        Use-DebugFile $false
        Write-SwDebug 'x'
        Should -Invoke -CommandName Write-SwDiagnosticLine -Times 0 -Exactly
        Should -Invoke -CommandName Stop-SwSpinner -Times 0 -Exactly
        Should -Invoke -CommandName Start-SwSpinner -Times 0 -Exactly
        Should -Invoke -CommandName Write-Host -Times 0 -Exactly
        [System.IO.File]::Exists($script:DebugPath) | Should -BeFalse
    }

    It 'LG-26 writes the diagnostic line with the grey colour, [DEBUG], the text and the reset sequence' {
        Mock Get-SwColor { 'C<' + $Name + '>' }
        $script:LogConfig = @{ DebugEnabled = $true; LogFile = $null }
        Write-SwDebug 'something happened'
        $script:Lines.Count | Should -Be 1
        $script:Lines[0] | Should -BeExactly ('  C<Gray>[DEBUG] something happened' + 'C<NC>')
    }

    It 'LG-26 counts $null from Get-SwColor as empty' {
        Mock Get-SwColor { $null }
        $script:LogConfig = @{ DebugEnabled = $true; LogFile = $null }
        { Write-SwDebug 'x' } | Should -Not -Throw
        $script:Lines[0] | Should -BeExactly '  [DEBUG] x'
    }

    It 'LG-26 stops the spinner, writes the line and restarts the spinner while a section is active' {
        $script:LogConfig = @{ DebugEnabled = $true; LogFile = $null }
        $script:CurrentSection = @{ Active = $true; Activity = $false; Name = 'X' }
        Write-SwDebug 'x'
        ($script:Order -join ',') | Should -BeExactly 'stop,diag,start'
    }

    It 'LG-26 does not restart the spinner when no section is active' {
        $script:LogConfig = @{ DebugEnabled = $true; LogFile = $null }
        $script:CurrentSection = @{ Active = $false; Activity = $false; Name = '' }
        Write-SwDebug 'x'
        ($script:Order -join ',') | Should -BeExactly 'stop,diag'
    }

    It 'LG-26 appends HH:mm:ss [DEBUG] text to the debug file when LogConfig.LogFile is set' {
        Use-DebugFile $true
        Write-SwDebug 'x'
        Get-LogText $script:DebugPath | Should -BeExactly ('10:00:01 [DEBUG] x' + $script:Crlf)
    }

    It 'LG-26 creates no file when LogConfig.LogFile is not set' {
        $script:LogConfig = @{ DebugEnabled = $true; LogFile = $null }
        Write-SwDebug 'x'
        [System.IO.File]::Exists($script:DebugPath) | Should -BeFalse
        [System.IO.Directory]::Exists($script:Dir) | Should -BeFalse
    }

    It 'LG-26 replaces control characters in the line and writes them out in the file' {
        Use-DebugFile $true
        Write-SwDebug ('a' + [char]27 + '[31mb' + [char]10 + 'c')
        $script:Lines[0].Contains('a [31mb' + [char]10 + 'c') | Should -BeTrue
        $script:Lines[0].Contains([string][char]27) | Should -BeTrue -Because 'only the colour sequences of the module remain'
        (Remove-Ansi $script:Lines[0]).Contains([string][char]27) | Should -BeFalse
        Get-LogText $script:DebugPath | Should -BeExactly ('10:00:01 [DEBUG] a\x1b[31mb\nc' + $script:Crlf)
    }

    It 'LG-26 shows no debug record and does not call the built-in cmdlet under $DebugPreference Continue' {
        $script:LogConfig = @{ DebugEnabled = $false; LogFile = $null }
        $DebugPreference = 'Continue'
        $streams = Get-AllOutput { Write-SwDebug 'x' }
        $streams.Count | Should -Be 0
        $script:LogConfig = @{ DebugEnabled = $true; LogFile = $null }
        $streams = Get-AllOutput { Write-SwDebug 'x' }
        @($streams | Where-Object { $_ -is [System.Management.Automation.DebugRecord] }).Count | Should -Be 0
    }

    It 'LG-26 writes an empty text for $null' {
        $script:LogConfig = @{ DebugEnabled = $true; LogFile = $null }
        { Write-SwDebug $null } | Should -Not -Throw
        (Remove-Ansi $script:Lines[0]) | Should -BeExactly '  [DEBUG] '
    }

    It 'S-3 throws for no text in debug mode: <Label>' -ForEach $script:HostileTexts {
        Use-DebugFile $true
        { Write-SwDebug $Text } | Should -Not -Throw
    }
}

# ============================================================================
# The diagnostic line
# ============================================================================

Describe 'Write-SwDiagnosticLine and Test-SwOutputRedirected' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Write-SwDiagnosticLine', 'Test-SwOutputRedirected'
        Use-HostCapture
        $script:SavedError = [Console]::Error
        $script:ErrorWriter = New-Object System.IO.StringWriter
        [Console]::SetError($script:ErrorWriter)
    }
    AfterEach { [Console]::SetError($script:SavedError); Stop-Case }

    It 'LG-27 writes the text to standard error, not to Write-Host and not to a PowerShell stream, when standard output is redirected' {
        Mock Test-SwOutputRedirected { $true }
        $streams = Get-AllOutput { Write-SwDiagnosticLine -Message 'a diagnostic' }
        $streams.Count | Should -Be 0
        $script:Hosted.Count | Should -Be 0
        $script:ErrorWriter.ToString() | Should -BeExactly ('a diagnostic' + [System.Environment]::NewLine)
    }

    It 'LG-27 writes the text with one Write-Host call and nothing to standard error when standard output is not redirected' {
        Mock Test-SwOutputRedirected { $false }
        Write-SwDiagnosticLine -Message 'a diagnostic'
        $script:Hosted.Count | Should -Be 1
        @($script:Hosted[0].Items).Count | Should -Be 1
        $script:Hosted[0].Items[0] | Should -BeExactly 'a diagnostic'
        $script:ErrorWriter.ToString() | Should -BeExactly ''
    }

    It 'LG-27 writes an empty line without a text, in both cases' {
        Mock Test-SwOutputRedirected { $true }
        Write-SwDiagnosticLine
        $script:ErrorWriter.ToString() | Should -BeExactly ([System.Environment]::NewLine)
        Mock Test-SwOutputRedirected { $false }
        Write-SwDiagnosticLine
        $script:Hosted.Count | Should -Be 1
        $script:Hosted[0].Items[0] | Should -BeExactly ''
    }

    It 'LG-27 keeps the text of a line as it is, colour sequences included, in both cases' {
        $text = '  ' + $script:Esc + '[0;90m[DEBUG] x' + $script:Esc + '[0m'
        Mock Test-SwOutputRedirected { $true }
        Write-SwDiagnosticLine -Message $text
        $script:ErrorWriter.ToString() | Should -BeExactly ($text + [System.Environment]::NewLine)
    }

    It 'LG-27 gives the answer of [Console]::IsOutputRedirected as one boolean' {
        $answer = @(Test-SwOutputRedirected)
        $answer.Count | Should -Be 1
        $answer[0] | Should -BeOfType [bool]
        $answer[0] | Should -Be ([Console]::IsOutputRedirected)
    }

    It 'LG-27 consults [Console]::IsOutputRedirected in Test-SwOutputRedirected and answers $false when that fails' {
        $body = (Get-Command -Name Test-SwOutputRedirected -CommandType Function).ScriptBlock.ToString()
        $body | Should -Match 'IsOutputRedirected'
        $body | Should -Match '(?s)try\s*\{.*\}\s*catch'
        # The failing call cannot be provoked here: judge what the handler answers.
        $ast = (Get-Command -Name Test-SwOutputRedirected -CommandType Function).ScriptBlock.Ast
        $handlers = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
        $handlers.Count | Should -BeGreaterThan 0
        foreach ($handler in $handlers) {
            $handler.Body.Extent.Text | Should -Match '\$false' -Because 'a failing check answers false'
            $handler.Body.Extent.Text | Should -Not -Match '\$true' -Because 'a failing check never answers true'
        }
    }
}

# ============================================================================
# Debug mode and the debug session
# ============================================================================

Describe 'Debug mode and the debug session' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Enable-SwDebugMode', 'Start-SwDebugSession', 'Complete-SwDebugSession', 'Write-SwDiagnosticLine', 'Write-SwWarning', 'Write-SwDebug', 'Write-SwInfo'
        Use-HostCapture
        Use-SpinnerRecorder
        Use-RealTables
        $script:Lines = New-Object System.Collections.Generic.List[string]
        $script:Warnings = New-Object System.Collections.Generic.List[string]
        Mock Write-SwDiagnosticLine { $script:Lines.Add([string]$Message) }
    }
    AfterEach { Stop-Case }

    It 'LG-28 sets SWEEPR_DEBUG to 1 and turns debug mode on' {
        Enable-SwDebugMode
        [System.Environment]::GetEnvironmentVariable('SWEEPR_DEBUG') | Should -BeExactly '1'
        $script:LogConfig.DebugEnabled | Should -BeTrue
    }

    It 'LG-28 names the debug file when LogConfig.LogFile is empty, and keeps a file that is set' {
        Enable-SwDebugMode
        $script:LogConfig.LogFile | Should -BeExactly $script:DebugPath
        $script:LogConfig = @{ DebugEnabled = $false; LogFile = 'already-set.log' }
        Enable-SwDebugMode
        $script:LogConfig.LogFile | Should -BeExactly 'already-set.log'
    }

    It 'LG-28 leaves LogConfig.LogFile empty when there is no debug file' {
        $script:SweeprDebugLogFile = ''
        Enable-SwDebugMode
        $script:LogConfig.DebugEnabled | Should -BeTrue
        $script:LogConfig.LogFile | Should -BeNullOrEmpty
    }

    It 'LG-28 creates neither a file nor a folder' {
        Enable-SwDebugMode
        [System.IO.File]::Exists($script:DebugPath) | Should -BeFalse
        [System.IO.Directory]::Exists($script:Dir) | Should -BeFalse
    }

    It 'LG-29 replaces the file with a separator of 70 hyphens, the header lines and the separator again' {
        [void](New-Dir $script:Dir)
        [System.IO.File]::WriteAllText($script:DebugPath, 'previous session')
        Start-SwDebugSession -Header @('a', 'b')
        $separator = '-' * 70
        Get-LogText $script:DebugPath | Should -BeExactly ($separator + $script:Crlf + 'a' + $script:Crlf + 'b' + $script:Crlf + $separator + $script:Crlf)
        [System.Environment]::GetEnvironmentVariable('SWEEPR_DEBUG') | Should -BeExactly '1'
        $script:LogConfig.DebugEnabled | Should -BeTrue
    }

    It 'LG-29 writes UTF-8 without a byte order mark and no single line feed' {
        Start-SwDebugSession -Header @(('header ' + [char]0xDC))
        $bytes = [System.IO.File]::ReadAllBytes($script:DebugPath)
        $bytes[0] | Should -Be 45
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -eq 10) { $bytes[$i - 1] | Should -Be 13 }
        }
    }

    It 'LG-29 creates the folder of the debug file when it is missing' {
        Start-SwDebugSession -Header @('a')
        [System.IO.File]::Exists($script:DebugPath) | Should -BeTrue
    }

    It 'LG-29 writes only the two separators for a header of $null or an empty array' {
        foreach ($header in @($null, @())) {
            Start-SwDebugSession -Header $header
            $lines = @(Get-LogLines $script:DebugPath | Where-Object { $_.Length -gt 0 })
            $lines.Count | Should -Be 2
            $lines[0] | Should -BeExactly ('-' * 70)
            $lines[1] | Should -BeExactly ('-' * 70)
        }
    }

    It 'LG-29 sets LogConfig.LogFile to the path and says so in a grey line that names the path' {
        Start-SwDebugSession -Header @('a')
        $script:LogConfig.LogFile | Should -BeExactly $script:DebugPath
        $script:Lines.Count | Should -Be 1
        $script:Lines[0].Contains($script:DebugPath) | Should -BeTrue
    }

    It 'LG-29 takes the path of the session even when LogConfig.LogFile held an older one' {
        $script:LogConfig = @{ DebugEnabled = $true; LogFile = (P $script:Work 'older' 'debug.log') }
        Start-SwDebugSession -Header @('a')
        $script:LogConfig.LogFile | Should -BeExactly $script:DebugPath
    }

    It 'LG-29 lets later message lines land in the same file, after the header' {
        Mock Get-Date { [datetime]'2026-10-15 10:00:01' }
        Start-SwDebugSession -Header @('a')
        Write-SwInfo 'later'
        $lines = @(Get-LogLines $script:DebugPath | Where-Object { $_.Length -gt 0 })
        $lines[$lines.Count - 1] | Should -BeExactly '10:00:01 [INFO] later'
        $lines[0] | Should -BeExactly ('-' * 70)
    }

    It 'LG-29 writes a header line with a line break as one line with the escape' {
        Start-SwDebugSession -Header @(('a' + [char]10 + 'b'), ('c' + [char]27 + 'd'))
        $lines = @(Get-LogLines $script:DebugPath | Where-Object { $_.Length -gt 0 })
        $lines.Count | Should -Be 4
        $lines[1] | Should -BeExactly 'a\nb'
        $lines[2] | Should -BeExactly 'c\x1bd'
    }

    It 'LG-29 gives up without an exception when the folder cannot be created: no file, LogConfig.LogFile null, debug mode on, a warning that names the path' {
        Mock Write-SwWarning { $script:Warnings.Add([string]$Message) }
        $blocked = P $script:Work 'blocked'
        [System.IO.File]::WriteAllText($blocked, 'a file')
        $script:SweeprDebugLogFile = P $blocked 'sweepr_debug_session.log'
        { Start-SwDebugSession -Header @('a') } | Should -Not -Throw
        $script:LogConfig.LogFile | Should -BeNullOrEmpty
        $script:LogConfig.DebugEnabled | Should -BeTrue
        @($script:Warnings | Where-Object { $_.Contains($script:SweeprDebugLogFile) }).Count | Should -Be 1
        Should -Invoke -CommandName Write-SwWarning -Times 1 -Exactly
    }

    It 'LG-29 gives up without an exception when the debug file is a folder' {
        Mock Write-SwWarning { $script:Warnings.Add([string]$Message) }
        [void](New-Dir $script:DebugPath)
        { Start-SwDebugSession -Header @('a') } | Should -Not -Throw
        $script:LogConfig.LogFile | Should -BeNullOrEmpty
        $script:LogConfig.DebugEnabled | Should -BeTrue
        Should -Invoke -CommandName Write-SwWarning -Times 1 -Exactly
    }

    It 'LG-29 gives up without an exception when there is no debug file path' {
        Mock Write-SwWarning { $script:Warnings.Add([string]$Message) }
        $script:SweeprDebugLogFile = ''
        { Start-SwDebugSession -Header @('a') } | Should -Not -Throw
        $script:LogConfig.LogFile | Should -BeNullOrEmpty
        $script:LogConfig.DebugEnabled | Should -BeTrue
        Should -Invoke -CommandName Write-SwWarning -Times 1 -Exactly
    }

    It 'LG-29 lets Write-SwDebug and the writers go on working after a failed start, only without a file' {
        Mock Write-SwWarning { }
        $blocked = P $script:Work 'blocked-two'
        [System.IO.File]::WriteAllText($blocked, 'a file')
        $script:SweeprDebugLogFile = P $blocked 'sweepr_debug_session.log'
        Start-SwDebugSession -Header @('a')
        { Write-SwDebug 'x' } | Should -Not -Throw
        { Write-SwInfo 'x' } | Should -Not -Throw
        $script:Lines.Count | Should -Be 1 -Because 'only the line of Write-SwDebug reaches the diagnostic line'
    }

    It 'LG-30 writes nothing when LogConfig.LogFile is empty' {
        $script:LogConfig = @{ DebugEnabled = $true; LogFile = $null }
        Complete-SwDebugSession
        $script:Lines.Count | Should -Be 0
        $script:LogConfig = @{ DebugEnabled = $true; LogFile = '' }
        Complete-SwDebugSession
        $script:Lines.Count | Should -Be 0
    }

    It 'LG-30 writes an empty line, a line with the path of the debug file and an empty line through the diagnostic line' {
        $script:LogConfig = @{ DebugEnabled = $true; LogFile = $script:DebugPath }
        Complete-SwDebugSession
        $script:Lines.Count | Should -Be 3
        $script:Lines[0] | Should -BeExactly ''
        $script:Lines[1].Contains($script:DebugPath) | Should -BeTrue
        $script:Lines[2] | Should -BeExactly ''
    }
}

# ============================================================================
# Sections
# ============================================================================

Describe 'Sections' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Start-SwSection', 'Stop-SwSection', 'Set-SwSectionActivity', 'Write-SwSuccess', 'Stop-SwSpinner', 'Start-SwSpinner'
        Use-HostCapture
        Use-SpinnerRecorder
        Use-RealTables
        $script:Lines = New-Object System.Collections.Generic.List[string]
        Mock Write-SwSuccess { $script:Order.Add('success'); $script:Lines.Add([string]$Message) }
    }
    AfterEach { Stop-Case }

    It 'LG-32 appends each title to the collector unchanged and keeps the last one as the name' {
        $collector = New-Object 'System.Collections.Generic.List[string]'
        $script:SectionCollector = $collector
        Start-SwSection 'User'
        Start-SwSection 'Apps'
        ($collector -join ',') | Should -BeExactly 'User,Apps'
        $script:CurrentSection.Name | Should -BeExactly 'Apps'
        $script:CurrentSection.Active | Should -BeTrue
        $script:CurrentSection.Activity | Should -BeFalse
    }

    It 'LG-32 hands the title to the collector unchanged, control characters included' {
        $collector = New-Object 'System.Collections.Generic.List[string]'
        $script:SectionCollector = $collector
        $title = 'a' + [char]27 + '[31mb' + [char]0
        Start-SwSection $title
        $collector[0] | Should -BeExactly $title
        $script:CurrentSection.Name | Should -BeExactly $title
    }

    It 'LG-32 starts a section even when the collector cannot take a title: <Label>' -ForEach @(
        @{ Label = 'a text'; Make = { 'not a list' } }
        @{ Label = 'a number'; Make = { 42 } }
        @{ Label = 'an object without Add'; Make = { [pscustomobject]@{ Name = 'x' } } }
    ) {
        $script:SectionCollector = & $Make
        { Start-SwSection 'User' } | Should -Not -Throw
        $script:CurrentSection.Name | Should -BeExactly 'User'
        $script:CurrentSection.Active | Should -BeTrue
        $script:Hosted.Count | Should -BeGreaterThan 0
    }

    It 'LG-32 works without a collector' {
        $script:SectionCollector = $null
        { Start-SwSection 'User' } | Should -Not -Throw
        $script:CurrentSection.Name | Should -BeExactly 'User'
    }

    It 'LG-32 resets Activity to false when a new section starts' {
        $script:CurrentSection = @{ Active = $true; Activity = $true; Name = 'Old' }
        Start-SwSection 'New'
        $script:CurrentSection.Activity | Should -BeFalse
        $script:CurrentSection.Name | Should -BeExactly 'New'
    }

    It 'LG-32 writes a blank line and the title line in the colour PurpleBold with the arrow symbol' {
        Mock Get-SwColor { 'C<' + $Name + '>' }
        Mock Get-SwIcon { 'I<' + $Name + '>' }
        Start-SwSection 'User'
        (Get-HostLines) -join "`n" | Should -BeExactly ("`n" + 'C<PurpleBold>I<Arrow> User' + 'C<NC>')
    }

    It 'LG-32 counts $null from the colour and symbol functions as empty' {
        Mock Get-SwColor { $null }
        Mock Get-SwIcon { $null }
        { Start-SwSection 'User' } | Should -Not -Throw
        (Get-HostLines) -join "`n" | Should -BeExactly ("`n" + ' User')
    }

    It 'LG-32 writes the title with the real tables' {
        Start-SwSection 'User'
        $title = $script:Colors['PurpleBold'] + $script:Icons['Arrow'] + ' User' + $script:Colors['NC']
        (Get-HostLines) -join "`n" | Should -BeExactly ("`n" + $title)
    }

    It 'LG-32 replaces control characters of the title on the console: <Label>' -ForEach $script:SectionTitles {
        Mock Get-SwColor { '' }
        Mock Get-SwIcon { '' }
        Start-SwSection $Title
        (Get-HostLines) -join "`n" | Should -BeExactly ("`n" + ' ' + (Get-Sanitized $Title))
    }

    It 'LG-32 stops the spinner first, writes, and starts the spinner last' {
        Start-SwSection 'User'
        $events = @($script:Order)
        $events[0] | Should -BeExactly 'stop'
        $events[$events.Count - 1] | Should -BeExactly 'start'
        @($events | Where-Object { $_ -eq 'stop' }).Count | Should -Be 1
        @($events | Where-Object { $_ -eq 'start' }).Count | Should -Be 1
        (@($events[1..($events.Count - 2)] | Where-Object { $_ -ne 'host' })).Count | Should -Be 0
    }

    It 'LG-32 does not close the section that was active before: no message for it' {
        Start-SwSection 'First'
        Start-SwSection 'Second'
        Should -Invoke -CommandName Write-SwSuccess -Times 0 -Exactly
    }

    It 'LG-33 marks the active section as having activity' {
        $script:CurrentSection = @{ Active = $true; Activity = $false; Name = 'X' }
        Set-SwSectionActivity
        $script:CurrentSection.Activity | Should -BeTrue
    }

    It 'LG-33 does nothing when no section is active' {
        $script:CurrentSection = @{ Active = $false; Activity = $false; Name = '' }
        Set-SwSectionActivity
        $script:CurrentSection.Activity | Should -BeFalse
    }

    It 'LG-34 writes one success message for a section without activity, then stops the spinner again' {
        Start-SwSection 'X'
        $script:Order.Clear()
        $script:Lines.Clear()
        Stop-SwSection
        ($script:Order -join ',') | Should -BeExactly 'stop,success,stop'
        $script:Lines.Count | Should -Be 1
        $script:Lines[0] | Should -Not -BeNullOrEmpty
        $script:CurrentSection.Active | Should -BeFalse
        $script:CurrentSection.Name | Should -BeExactly 'X'
    }

    It 'LG-34 writes no message for a section with activity and stops the spinner' {
        Start-SwSection 'X'
        Set-SwSectionActivity
        $script:Order.Clear()
        Stop-SwSection
        Should -Invoke -CommandName Write-SwSuccess -Times 0 -Exactly
        $events = @($script:Order)
        $events[0] | Should -BeExactly 'stop'
        $events[$events.Count - 1] | Should -BeExactly 'stop'
        $script:CurrentSection.Active | Should -BeFalse
        $script:CurrentSection.Name | Should -BeExactly 'X'
    }

    It 'LG-34 writes no message and does not throw when there was no section' {
        $script:CurrentSection = @{ Active = $false; Activity = $false; Name = '' }
        $script:Order.Clear()
        { Stop-SwSection } | Should -Not -Throw
        Should -Invoke -CommandName Write-SwSuccess -Times 0 -Exactly
        $script:Hosted.Count | Should -Be 0
        $events = @($script:Order)
        $events[0] | Should -BeExactly 'stop'
        $events[$events.Count - 1] | Should -BeExactly 'stop'
    }

    It 'LG-34 writes the success message once even when called twice' {
        Start-SwSection 'X'
        Stop-SwSection
        Stop-SwSection
        Should -Invoke -CommandName Write-SwSuccess -Times 1 -Exactly
    }

    It 'LG-35 does not throw when a test replaced CurrentSection by a table with the three keys: <Label>' -ForEach @(
        @{ Label = 'active with activity'; Active = $true; Activity = $true; Name = 'A' }
        @{ Label = 'active without activity'; Active = $true; Activity = $false; Name = 'A' }
        @{ Label = 'inactive'; Active = $false; Activity = $false; Name = '' }
    ) {
        $script:CurrentSection = @{ Active = $Active; Activity = $Activity; Name = $Name }
        { Set-SwSectionActivity } | Should -Not -Throw
        { Stop-SwSection } | Should -Not -Throw
        $script:CurrentSection = @{ Active = $Active; Activity = $Activity; Name = $Name }
        { Start-SwSection 'B' } | Should -Not -Throw
    }

    It 'S-3 throws for no title and no state: <Label>' -ForEach $script:SectionTitles {
        $script:SectionCollector = New-Object 'System.Collections.Generic.List[string]'
        { Start-SwSection $Title } | Should -Not -Throw
        { Set-SwSectionActivity } | Should -Not -Throw
        { Stop-SwSection } | Should -Not -Throw
    }

    It 'S-3 does not throw for a title of $null' {
        { Start-SwSection $null } | Should -Not -Throw
        { Stop-SwSection } | Should -Not -Throw
    }
}
