# Sweepr - tests for how lib\core\log.ps1 gets a record into operations.log: the session marker, the
# encoding, the folder, rotation, the retry when the file is held, what happens when a line cannot be
# written, concurrent use, and the compatibility with the reader of the log.
#
# The rule numbers in the test names (LG- and S-) number the rules and the safety invariants of the
# module's behavior; each rule and invariant has at least one test. The form of the line itself is in
# tests/SwLogLine.Tests.ps1.
#
# Interface pinned here (new names; each old name stays as a forwarding function):
#   Write-SwOperation [-Action] [-Path] [-Detail]    appends at most one record, with the marker before the first
#   Add-SwOperationText -File -Text                  appends text (UTF-8 without BOM), retries, throws at the end
#   Move-SwOperationLogAside -File                   moves the file to <File>.old, replacing an older .old
# Script variables that tests replace: $script:SweeprOperationsLogFile, $script:SweeprOperationsLogStarted,
# $script:SweeprOperationsLogMaxBytes.
#
# Seams used with Mock:
#   Get-Date, Write-SwDebug, Add-SwOperationText, Move-SwOperationLogAside, Start-Sleep
#
# Platform notes:
#   - Everything lives in $TestDrive; no real operations.log, no registry, no network. The gate sets
#     SWEEPR_NO_OPLOG=1; every test that writes unsets it and the file puts it back.
#   - A file held with FileShare.None refuses a second open on Windows and on Linux (advisory lock);
#     the share modes ReadWrite of two writers conflict only on Windows. Tests marked [W] describe a
#     Windows fact and are meant to fail on Linux where it does not hold or cannot be built.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    # S-3: input that must never make a writer throw.
    $script:HostileTexts = @(
        @{ Label = 'a NUL character'; Text = ('a' + [char]0 + 'b') }
        @{ Label = 'a line break'; Text = ('a' + [char]13 + [char]10 + 'b') }
        @{ Label = 'an escape sequence'; Text = ('a' + [char]27 + '[31mb') }
        @{ Label = 'a very long text'; Text = ('x' * 5000) }
        @{ Label = 'a lone surrogate'; Text = ('a' + [char]0xD800 + 'b') }
        @{ Label = 'format and wildcard characters'; Text = '{0} %TEMP% $(x) `n [a]*?' }
        @{ Label = 'white space only'; Text = '   ' }
        @{ Label = 'the empty string'; Text = '' }
    )
    $script:FileStates = @(
        @{ State = 'a normal log file'; Texts = $script:HostileTexts }
        @{ State = 'a folder in place of the log file'; Texts = $script:HostileTexts }
        @{ State = 'a file in place of the parent folder'; Texts = $script:HostileTexts }
        @{ State = 'no log file configured'; Texts = $script:HostileTexts }
        @{ State = 'SWEEPR_NO_OPLOG set to 1'; Texts = $script:HostileTexts }
    )
    $script:HostileCases = @(, @{ Texts = $script:HostileTexts })
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
        '_SWEEPR_OPLOG_RUN_ID', 'USERPROFILE', 'TERM', 'ZZ_SWEEPR_LOG_TEST')
    $script:StateNames = @('Config', 'Colors', 'Icons', 'SWEEPR_LOG_LOADED', 'SweeprOperationsLogFile', 'SweeprOperationsLogMaxBytes',
        'SweeprOperationsLogStarted', 'SweeprDebugLogFile', 'SweeprLogDir', 'LogConfig', 'CurrentSection', 'SectionCollector',
        'SpinnerDisabled', 'Clock', 'DateCalls', 'DateCallsWithArguments', 'Texts', 'Messages', 'Hosted', 'Order', 'Sleeps', 'Calls', 'FilesCleaned', 'TotalItems')
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

    # ---- helpers for the writer -------------------------------------------------------------------

    # The marker and the record of one call, as the writer is meant to produce them.
    function script:Get-ExpectedMarker([string]$Label, [string]$Time) {
        $script:Crlf + '# ========== ' + $Label + ' session started at ' + $Time + ' ==========' + $script:Crlf
    }
    function script:Get-ExpectedRecord([string]$Time, [string]$Label, [string]$Action, [string]$Path, [string]$Detail) {
        '[' + $Time + '] [' + $Label + '] ' + $Action + ' ' + $Path + ' (' + $Detail + ')' + $script:Crlf
    }

    # Replaces Add-SwOperationText by a recorder of the file and the text; the first $FailFirst calls throw.
    function script:Use-TextCapture([int]$FailFirst = 0) {
        $script:Texts = New-Object System.Collections.Generic.List[string]
        $script:Files = New-Object System.Collections.Generic.List[string]
        $script:CallNo = 0
        $script:FailFirst = $FailFirst
        $script:StartedDuringCall = New-Object System.Collections.Generic.List[object]
        Mock Add-SwOperationText {
            $script:CallNo++
            $script:Texts.Add([string]$Text)
            $script:Files.Add([string]$File)
            $script:StartedDuringCall.Add($script:SweeprOperationsLogStarted)
            if ($script:CallNo -le $script:FailFirst) { throw 'append failed' }
        }
    }
    # Replaces Start-Sleep by a recorder of the pauses. Releases the held file at the $ReleaseAt-th pause.
    function script:Use-Sleep([int]$ReleaseAt = 0) {
        $script:Sleeps = New-Object System.Collections.Generic.List[int]
        $script:ReleaseAt = $ReleaseAt
        Mock Start-Sleep {
            $script:Sleeps.Add([int]$Milliseconds)
            if ($script:ReleaseAt -gt 0 -and $script:Sleeps.Count -ge $script:ReleaseAt -and $null -ne $script:Holder) {
                $script:Holder.Dispose()
                $script:Holder = $null
            }
        }
    }
    # Opens the file and keeps it open, with the given share mode.
    function script:Open-Held([string]$Path, [string]$Share = 'None', [string]$Access = 'ReadWrite') {
        [void](New-Dir ([System.IO.Path]::GetDirectoryName($Path)))
        $script:Holder = [System.IO.File]::Open($Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]$Access, [System.IO.FileShare]$Share)
    }
    function script:Close-Held {
        if ($null -ne $script:Holder) { $script:Holder.Dispose(); $script:Holder = $null }
    }
    function script:Write-FileBytes([string]$Path, [byte[]]$Bytes) {
        [void](New-Dir ([System.IO.Path]::GetDirectoryName($Path)))
        [System.IO.File]::WriteAllBytes($Path, $Bytes)
    }
    # $Count bytes of one value; the default value 0 is the fast case for large files.
    function script:New-Bytes([int]$Count, [byte]$Value = 0) {
        $data = New-Object byte[] $Count
        if ($Value -ne 0) { for ($i = 0; $i -lt $Count; $i++) { $data[$i] = $Value } }
        , $data
    }
    function script:Test-StartsWith([byte[]]$Bytes, [byte[]]$Prefix) {
        if ($Bytes.Length -lt $Prefix.Length) { return $false }
        for ($i = 0; $i -lt $Prefix.Length; $i++) { if ($Bytes[$i] -ne $Prefix[$i]) { return $false } }
        $true
    }
    function script:Test-Contains([byte[]]$Bytes, [byte[]]$Needle) {
        for ($i = 0; $i -le $Bytes.Length - $Needle.Length; $i++) {
            $same = $true
            for ($j = 0; $j -lt $Needle.Length; $j++) { if ($Bytes[$i + $j] -ne $Needle[$j]) { $same = $false; break } }
            if ($same) { return $true }
        }
        $false
    }

    # What the whole file changes in the process, put back after the last test.
    $script:RootState = Save-State
    $script:RootEnv = Save-Env $script:EnvNames
    $script:Holder = $null
    . $script:LogScript
    . $script:HistoryScript
}

AfterAll {
    Close-Held
    Restore-State $script:RootState
    Restore-Env $script:RootEnv
}

# ============================================================================
# Session marker
# ============================================================================

Describe 'Write-SwOperation: session marker' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Write-SwOperation', 'Add-SwOperationText', 'Write-SwDebug', 'Move-SwOperationLogAside'
        Use-Clock
        Use-DebugCapture
        Use-Sleep
        Mock Write-Host { }
        Set-Env '_SWEEPR_OPLOG_RUN_COMMAND' 'clean'
        Set-Env '_SWEEPR_OPLOG_RUN_ID' 'a1'
    }
    AfterEach { Close-Held; Stop-Case }

    It 'LG-11 puts the marker and the first record into one text and gives the second record a text of its own' {
        Use-TextCapture
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        Write-SwOperation -Action 'REMOVED' -Path 'C:\y' -Detail '2KB'
        $script:Texts.Count | Should -Be 2
        $script:Texts[0] | Should -BeExactly ((Get-ExpectedMarker 'clean run=a1' '2026-10-15 10:00:01') + (Get-ExpectedRecord '2026-10-15 10:00:01' 'clean run=a1' 'REMOVED' 'C:\x' '1KB'))
        $script:Texts[1] | Should -BeExactly (Get-ExpectedRecord '2026-10-15 10:00:01' 'clean run=a1' 'REMOVED' 'C:\y' '2KB')
    }

    It 'LG-11 appends once per record, to the file named in the variable' {
        Use-TextCapture
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        Write-SwOperation -Action 'REMOVED' -Path 'C:\y' -Detail '2KB'
        Write-SwOperation -Action 'FAILED' -Path 'C:\z' -Detail 'no'
        Should -Invoke -CommandName Add-SwOperationText -Times 3 -Exactly
        foreach ($file in $script:Files) { $file | Should -BeExactly $script:LogPath }
    }

    It 'LG-11 reads the log file name at every call' {
        Use-TextCapture
        $other = P $script:Work 'other' 'operations.log'
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        $script:SweeprOperationsLogFile = $other
        Write-SwOperation -Action 'REMOVED' -Path 'C:\y' -Detail '2KB'
        $script:Files[0] | Should -BeExactly $script:LogPath
        $script:Files[1] | Should -BeExactly $other
    }

    It 'LG-11 sets SweeprOperationsLogStarted only after the text was appended' {
        Use-TextCapture
        $script:SweeprOperationsLogStarted | Should -BeFalse
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        $script:StartedDuringCall[0] | Should -BeFalse -Because 'the marker is not yet written while the text is appended'
        $script:SweeprOperationsLogStarted | Should -BeTrue
    }

    It 'LG-11 keeps SweeprOperationsLogStarted false when the first append fails and writes the marker with the next record' {
        Use-TextCapture -FailFirst 1
        { Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB' } | Should -Not -Throw
        $script:SweeprOperationsLogStarted | Should -BeFalse
        Write-SwOperation -Action 'REMOVED' -Path 'C:\y' -Detail '2KB'
        $script:Texts.Count | Should -Be 2
        $script:Texts[1] | Should -BeExactly ((Get-ExpectedMarker 'clean run=a1' '2026-10-15 10:00:01') + (Get-ExpectedRecord '2026-10-15 10:00:01' 'clean run=a1' 'REMOVED' 'C:\y' '2KB'))
        $script:Texts[1].StartsWith($script:Crlf + '# ==========') | Should -BeTrue
        $script:SweeprOperationsLogStarted | Should -BeTrue
    }

    It 'LG-11 writes a marker again after a caller sets SweeprOperationsLogStarted to false' {
        Use-TextCapture
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        $script:SweeprOperationsLogStarted = $false
        Write-SwOperation -Action 'REMOVED' -Path 'C:\y' -Detail '2KB'
        $script:Texts[1].StartsWith($script:Crlf + '# ========== clean run=a1 session started at ') | Should -BeTrue
    }

    It 'LG-11 writes no marker while SweeprOperationsLogStarted is true' {
        Use-TextCapture
        $script:SweeprOperationsLogStarted = $true
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        $script:Texts[0] | Should -BeExactly (Get-ExpectedRecord '2026-10-15 10:00:01' 'clean run=a1' 'REMOVED' 'C:\x' '1KB')
    }

    It 'LG-11 leaves the marker for the first call that writes: an earlier call that wrote nothing leaves none' {
        Use-TextCapture
        Set-Env 'SWEEPR_NO_OPLOG' '1'
        Write-SwOperation -Action 'REMOVED' -Path 'C:\skipped' -Detail '1KB'
        Write-SwOperation -Action 'removed' -Path 'C:\skipped' -Detail '1KB'
        Set-Env 'SWEEPR_NO_OPLOG' $null
        Write-SwOperation -Action 'REMOVED' -Path '' -Detail '1KB'
        $script:SweeprOperationsLogStarted | Should -BeFalse
        $script:Texts.Count | Should -Be 0
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        $script:Texts.Count | Should -Be 1
        $script:Texts[0].StartsWith($script:Crlf + '# ========== clean run=a1 session started at ') | Should -BeTrue
    }

    It 'LG-11 writes one marker for the file: the second record adds one line only' {
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        Write-SwOperation -Action 'REMOVED' -Path 'C:\y' -Detail '2KB'
        @(Get-MarkerLines $script:LogPath).Count | Should -Be 1
        @(Get-RecordLines $script:LogPath).Count | Should -Be 2
        $lines = @(Get-LogLines $script:LogPath)
        $lines.Count | Should -Be 5 -Because 'blank line, marker, two records, and the empty part after the last CRLF'
    }
}

# ============================================================================
# Encoding
# ============================================================================

Describe 'Write-SwOperation: encoding and appending' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Write-SwOperation', 'Add-SwOperationText', 'Write-SwDebug'
        Use-Clock
        Use-DebugCapture
        Use-Sleep
        Mock Write-Host { }
    }
    AfterEach { Close-Held; Stop-Case }

    It 'LG-12 starts a new file with the bytes 0D 0A 23 and no byte order mark' {
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        $bytes = [System.IO.File]::ReadAllBytes($script:LogPath)
        $bytes[0] | Should -Be 13
        $bytes[1] | Should -Be 10
        $bytes[2] | Should -Be 35
    }

    It 'LG-12 keeps the content of a file with a byte order mark and foreign lines byte for byte' {
        $before = [byte[]](@(0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::ASCII.GetBytes('foreign line' + [char]10 + 'another one without a carriage return' + [char]10 + 'last'))
        Write-FileBytes $script:LogPath $before
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        $after = [System.IO.File]::ReadAllBytes($script:LogPath)
        $after.Length | Should -BeGreaterThan $before.Length
        Test-StartsWith $after $before | Should -BeTrue -Because 'the old content is still the start of the file'
        $rest = $script:Utf8.GetString($after, $before.Length, $after.Length - $before.Length)
        $rest.StartsWith($script:Crlf + '# ==========') | Should -BeTrue -Because 'the new part starts with the blank line of the marker'
    }

    It 'LG-12 writes a path with a diaeresis and CJK characters as UTF-8 and reads it back' {
        $path = 'C:\Users\Example\' + [char]0xDC + 'bung\' + [char]0x4E2D
        Write-SwOperation -Action 'REMOVED' -Path $path -Detail 'd'
        $bytes = [System.IO.File]::ReadAllBytes($script:LogPath)
        Test-Contains $bytes ([byte[]](0xC3, 0x9C)) | Should -BeTrue -Because 'U+00DC is C3 9C'
        Test-Contains $bytes ([byte[]](0xE4, 0xB8, 0xAD)) | Should -BeTrue -Because 'U+4E2D is E4 B8 AD'
        (Read-SwHistory -Path $script:LogPath).Operations[0].path | Should -BeExactly $path
    }

    It 'LG-12 turns a character that cannot be encoded into a replacement character and still writes the record' {
        { Write-SwOperation -Action 'REMOVED' -Path ('C:\a' + [char]0xD800 + 'b') -Detail 'd' } | Should -Not -Throw
        @(Get-RecordLines $script:LogPath).Count | Should -Be 1
        Test-Contains ([System.IO.File]::ReadAllBytes($script:LogPath)) ([byte[]](0xEF, 0xBF, 0xBD)) | Should -BeTrue
        $script:Messages.Count | Should -Be 0
    }

    It 'LG-12 only appends: a second call leaves every byte of the first part as it was' {
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        $first = [System.IO.File]::ReadAllBytes($script:LogPath)
        Write-SwOperation -Action 'REMOVED' -Path 'C:\y' -Detail '2KB'
        $second = [System.IO.File]::ReadAllBytes($script:LogPath)
        Test-StartsWith $second $first | Should -BeTrue
    }

    It 'LG-15 appends the text of Add-SwOperationText to a new file as UTF-8 without a byte order mark' {
        [void](New-Dir $script:Dir)
        $text = 'line one' + $script:Crlf + 'Uebung ' + [char]0xDC + [char]0x4E2D + $script:Crlf
        Add-SwOperationText -File $script:LogPath -Text $text
        $bytes = [System.IO.File]::ReadAllBytes($script:LogPath)
        Test-StartsWith $bytes ([byte[]][System.Text.Encoding]::ASCII.GetBytes('line one')) | Should -BeTrue
        $script:Utf8.GetString($bytes) | Should -BeExactly $text
    }

    It 'LG-15 appends the text of Add-SwOperationText after the existing bytes' {
        $before = [System.Text.Encoding]::ASCII.GetBytes('old content without a line end')
        Write-FileBytes $script:LogPath $before
        Add-SwOperationText -File $script:LogPath -Text ('new' + $script:Crlf)
        $script:Utf8.GetString([System.IO.File]::ReadAllBytes($script:LogPath)) | Should -BeExactly ('old content without a line end' + 'new' + $script:Crlf)
    }
}

# ============================================================================
# The folder
# ============================================================================

Describe 'Write-SwOperation: the folder of the log file' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Write-SwOperation', 'Add-SwOperationText', 'Write-SwDebug'
        Use-Clock
        Use-DebugCapture
        Use-Sleep
        Mock Write-Host { }
    }
    AfterEach { Close-Held; Stop-Case }

    It 'LG-13 creates the folder with its parents before the first record' {
        $script:SweeprOperationsLogFile = P $script:Work 'new' 'below' 'operations.log'
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        [System.IO.Directory]::Exists((P $script:Work 'new' 'below')) | Should -BeTrue
        [System.IO.File]::Exists($script:SweeprOperationsLogFile) | Should -BeTrue
    }

    It 'LG-13 does not need a folder when the log file is a bare file name' {
        $probe = New-Dir (P $script:Work 'probe')
        $previous = [System.Environment]::CurrentDirectory
        [System.Environment]::CurrentDirectory = $probe
        try {
            $script:SweeprOperationsLogFile = 'operations-bare.log'
            { Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB' } | Should -Not -Throw
            [System.IO.File]::Exists((P $probe 'operations-bare.log')) | Should -BeTrue
            $script:Messages.Count | Should -Be 0
        }
        finally { [System.Environment]::CurrentDirectory = $previous }
    }

    It 'LG-13 writes nothing and reports it once when a parent of the folder is a file' {
        $blocked = P $script:Work 'blocked'
        [System.IO.File]::WriteAllText($blocked, 'a file')
        $script:SweeprOperationsLogFile = P $blocked 'operations.log'
        { Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB' } | Should -Not -Throw
        $script:SweeprOperationsLogStarted | Should -BeFalse
        $script:Messages.Count | Should -Be 1
        $script:Messages[0] | Should -BeLike 'operations.log not written: *'
        [System.IO.File]::ReadAllText($blocked) | Should -BeExactly 'a file'
    }

    It 'LG-13 does not create the folder again once the marker is written' {
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        [System.IO.Directory]::Delete($script:Dir, $true)
        { Write-SwOperation -Action 'REMOVED' -Path 'C:\y' -Detail '2KB' } | Should -Not -Throw
        [System.IO.Directory]::Exists($script:Dir) | Should -BeFalse
        $script:Messages.Count | Should -Be 1
        $script:Messages[0] | Should -BeLike 'operations.log not written: *'
    }

    It 'LG-13 creates nothing but the folder and the file' {
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        $listing = @(Get-Listing $script:Work)
        $listing.Count | Should -Be 2
        $listing[0] | Should -BeExactly 'D config'
        $listing[1] | Should -BeLike ('F config' + $script:Sep + 'operations.log *')
    }
}

# ============================================================================
# Rotation
# ============================================================================

Describe 'Write-SwOperation: rotation of a large log' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Write-SwOperation', 'Add-SwOperationText', 'Write-SwDebug', 'Move-SwOperationLogAside'
        Use-Clock
        Use-DebugCapture
        Use-Sleep
        Mock Write-Host { }
        $script:Old = $script:LogPath + '.old'
    }
    AfterEach { Close-Held; Stop-Case }

    It 'LG-14 moves a file of 64 bytes to .old when the limit is 16 and starts a new file with the marker' {
        $content = New-Bytes 64 65
        Write-FileBytes $script:LogPath $content
        $script:SweeprOperationsLogMaxBytes = 16
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        [System.IO.File]::ReadAllBytes($script:Old).Length | Should -Be 64
        (@([System.IO.File]::ReadAllBytes($script:Old) | Where-Object { $_ -ne 65 }).Count) | Should -Be 0
        $text = Get-LogText $script:LogPath
        $text.StartsWith($script:Crlf + '# ====') | Should -BeTrue
        $text.Contains('AAAA') | Should -BeFalse -Because 'the old content is not in the new file'
        $listing = @(Get-Listing $script:Dir)
        $listing.Count | Should -Be 2
    }

    It 'LG-14 does not rotate a file of exactly the limit' {
        Write-FileBytes $script:LogPath (New-Bytes 16 65)
        $script:SweeprOperationsLogMaxBytes = 16
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        [System.IO.File]::Exists($script:Old) | Should -BeFalse
        (Get-LogText $script:LogPath).StartsWith('AAAAAAAAAAAAAAAA' + $script:Crlf + '# ==========') | Should -BeTrue
    }

    It 'LG-14 rotates a file of one byte more than the limit' {
        Write-FileBytes $script:LogPath (New-Bytes 17 65)
        $script:SweeprOperationsLogMaxBytes = 16
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        [System.IO.File]::ReadAllBytes($script:Old).Length | Should -Be 17
    }

    It 'LG-14 uses a limit of 5 MiB: a file of 5242880 bytes stays, one of 5242881 bytes rotates' {
        Write-FileBytes $script:LogPath (New-Bytes 5242880)
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        [System.IO.File]::Exists($script:Old) | Should -BeFalse
        [System.IO.File]::Delete($script:LogPath)
        Write-FileBytes $script:LogPath (New-Bytes 5242881)
        $script:SweeprOperationsLogStarted = $false
        Write-SwOperation -Action 'REMOVED' -Path 'C:\y' -Detail '1KB'
        [System.IO.File]::ReadAllBytes($script:Old).Length | Should -Be 5242881
    }

    It 'LG-14 asks Move-SwOperationLogAside for the log file, once, and only when it rotates' {
        Mock Move-SwOperationLogAside { }
        Write-FileBytes $script:LogPath (New-Bytes 64 65)
        $script:SweeprOperationsLogMaxBytes = 16
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        Should -Invoke -CommandName Move-SwOperationLogAside -Times 1 -Exactly -ParameterFilter { $File -eq $script:LogPath }
        $script:SweeprOperationsLogMaxBytes = 100000
        $script:SweeprOperationsLogStarted = $false
        Write-SwOperation -Action 'REMOVED' -Path 'C:\y' -Detail '1KB'
        Should -Invoke -CommandName Move-SwOperationLogAside -Times 1 -Exactly
    }

    It 'LG-14 does not rotate again during the same load after the first record' {
        Mock Move-SwOperationLogAside { }
        Write-FileBytes $script:LogPath (New-Bytes 64 65)
        $script:SweeprOperationsLogMaxBytes = 16
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        Write-SwOperation -Action 'REMOVED' -Path 'C:\y' -Detail '1KB'
        Write-SwOperation -Action 'REMOVED' -Path 'C:\z' -Detail '1KB'
        Should -Invoke -CommandName Move-SwOperationLogAside -Times 1 -Exactly
    }

    It 'LG-14 checks again when a caller sets SweeprOperationsLogStarted to false' {
        Mock Move-SwOperationLogAside { }
        Write-FileBytes $script:LogPath (New-Bytes 64 65)
        $script:SweeprOperationsLogMaxBytes = 16
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        $script:SweeprOperationsLogStarted = $false
        Write-SwOperation -Action 'REMOVED' -Path 'C:\y' -Detail '1KB'
        Should -Invoke -CommandName Move-SwOperationLogAside -Times 2 -Exactly
    }

    It 'LG-14 reads the limit at every check' {
        Mock Move-SwOperationLogAside { }
        Write-FileBytes $script:LogPath (New-Bytes 64 65)
        $script:SweeprOperationsLogMaxBytes = 63
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        Should -Invoke -CommandName Move-SwOperationLogAside -Times 1 -Exactly
        $script:SweeprOperationsLogStarted = $false
        $script:SweeprOperationsLogMaxBytes = 100000000
        Write-SwOperation -Action 'REMOVED' -Path 'C:\y' -Detail '1KB'
        Should -Invoke -CommandName Move-SwOperationLogAside -Times 1 -Exactly
    }

    It 'LG-14 does not rotate when the log file is missing' {
        Mock Move-SwOperationLogAside { }
        $script:SweeprOperationsLogMaxBytes = 0
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        Should -Invoke -CommandName Move-SwOperationLogAside -Times 0 -Exactly
        @(Get-RecordLines $script:LogPath).Count | Should -Be 1
    }

    It 'LG-14 does not rotate when the log file is a folder, and writes nothing without an exception' {
        Mock Move-SwOperationLogAside { }
        [void](New-Dir $script:LogPath)
        $script:SweeprOperationsLogMaxBytes = 0
        { Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB' } | Should -Not -Throw
        Should -Invoke -CommandName Move-SwOperationLogAside -Times 0 -Exactly
        $script:Messages.Count | Should -Be 1
    }

    It 'LG-14 appends the record to the existing file and reports once when Move-SwOperationLogAside fails' {
        Mock Move-SwOperationLogAside { throw 'cannot move' }
        $content = New-Bytes 64 65
        Write-FileBytes $script:LogPath $content
        $script:SweeprOperationsLogMaxBytes = 16
        { Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB' } | Should -Not -Throw
        $after = [System.IO.File]::ReadAllBytes($script:LogPath)
        Test-StartsWith $after $content | Should -BeTrue -Because 'the old content stays'
        @(Get-RecordLines $script:LogPath).Count | Should -Be 1
        @(Get-MarkerLines $script:LogPath).Count | Should -Be 1
        $script:Messages.Count | Should -Be 1
        $script:Messages[0] | Should -BeLike 'operations.log not written: *'
        $script:Messages[0] | Should -Match '(?i)rotat|\.old|move'
    }

    It 'LG-16 reports one message naming both reasons when the rotation and the append both fail' {
        Mock Move-SwOperationLogAside { throw 'cannot move' }
        Mock Add-SwOperationText { throw 'disk full' }
        Write-FileBytes $script:LogPath (New-Bytes 64 65)
        $script:SweeprOperationsLogMaxBytes = 16
        { Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB' } | Should -Not -Throw
        $script:Messages.Count | Should -Be 1
        $script:Messages[0] | Should -BeLike 'operations.log not written: *'
        $script:Messages[0] | Should -Match 'cannot move'
        $script:Messages[0] | Should -Match 'disk full'
        $script:SweeprOperationsLogStarted | Should -BeFalse
    }

    It 'LG-14 replaces an existing .old file' {
        Write-FileBytes $script:Old ([System.Text.Encoding]::ASCII.GetBytes('previous generation, longer than the new one is not'))
        Write-FileBytes $script:LogPath (New-Bytes 64 66)
        $script:SweeprOperationsLogMaxBytes = 16
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        $old = [System.IO.File]::ReadAllBytes($script:Old)
        $old.Length | Should -Be 64
        @($old | Where-Object { $_ -ne 66 }).Count | Should -Be 0
    }

    It 'LG-14 rotates and writes in a data folder whose name has brackets' {
        $dir = P $script:Work 'a[1]' 'config'
        $script:SweeprOperationsLogFile = P $dir 'operations.log'
        Write-FileBytes $script:SweeprOperationsLogFile (New-Bytes 64 65)
        $script:SweeprOperationsLogMaxBytes = 16
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        [System.IO.File]::ReadAllBytes((P $dir 'operations.log.old')).Length | Should -Be 64
        @(Get-RecordLines $script:SweeprOperationsLogFile).Count | Should -Be 1
        $script:Messages.Count | Should -Be 0
    }

    It 'LG-14 moves the file to the same name with .old and replaces an older .old (Move-SwOperationLogAside)' {
        Write-FileBytes $script:LogPath ([System.Text.Encoding]::ASCII.GetBytes('current'))
        Write-FileBytes $script:Old ([System.Text.Encoding]::ASCII.GetBytes('older generation'))
        Move-SwOperationLogAside -File $script:LogPath
        [System.IO.File]::Exists($script:LogPath) | Should -BeFalse
        [System.IO.File]::ReadAllText($script:Old) | Should -BeExactly 'current'
    }

    It 'LG-14 moves a file in a folder with brackets in the name (Move-SwOperationLogAside)' {
        $log = P $script:Work 'b[2]' 'operations.log'
        Write-FileBytes $log ([System.Text.Encoding]::ASCII.GetBytes('current'))
        Move-SwOperationLogAside -File $log
        [System.IO.File]::Exists($log) | Should -BeFalse
        [System.IO.File]::ReadAllText($log + '.old') | Should -BeExactly 'current'
    }

    It 'LG-14 [W] throws when the file cannot be moved because another process holds it (Move-SwOperationLogAside)' {
        Write-FileBytes $script:LogPath ([System.Text.Encoding]::ASCII.GetBytes('current'))
        Open-Held $script:LogPath 'None'
        $failure = Assert-Throws { Move-SwOperationLogAside -File $script:LogPath }
        $failure | Should -Not -BeNullOrEmpty
        Close-Held
        [System.IO.File]::ReadAllText($script:LogPath) | Should -BeExactly 'current'
    }
}

# ============================================================================
# Retry
# ============================================================================

Describe 'Add-SwOperationText: retry and failure' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Add-SwOperationText'
        Use-Sleep
        [void](New-Dir $script:Dir)
    }
    AfterEach { Close-Held; Stop-Case }

    It 'LG-15 waits once and then appends exactly once when the file is released during the first pause' {
        [System.IO.File]::WriteAllText($script:LogPath, 'x')
        Open-Held $script:LogPath 'None'
        Use-Sleep 1
        Add-SwOperationText -File $script:LogPath -Text ('once' + $script:Crlf)
        $script:Sleeps.Count | Should -Be 1
        [System.IO.File]::ReadAllText($script:LogPath) | Should -BeExactly ('x' + 'once' + $script:Crlf)
    }

    It 'LG-15 makes 5 attempts with 4 pauses and passes on the last error when the file stays held' {
        [System.IO.File]::WriteAllText($script:LogPath, 'x')
        Open-Held $script:LogPath 'None'
        $failure = Assert-Throws { Add-SwOperationText -File $script:LogPath -Text ('never' + $script:Crlf) }
        Test-ExceptionChain $failure.Exception ([System.IO.IOException]) | Should -BeTrue -Because 'the last IOException is passed on'
        $script:Sleeps.Count | Should -Be 4
        Close-Held
        [System.IO.File]::ReadAllText($script:LogPath) | Should -BeExactly 'x'
    }

    It 'LG-15 pauses ascending, each under 250 ms and all together under 1 second' {
        [System.IO.File]::WriteAllText($script:LogPath, 'x')
        Open-Held $script:LogPath 'None'
        $null = Assert-Throws { Add-SwOperationText -File $script:LogPath -Text 'never' }
        $pauses = @($script:Sleeps)
        $pauses.Count | Should -Be 4
        $sum = 0
        for ($i = 0; $i -lt $pauses.Count; $i++) {
            $pauses[$i] | Should -BeGreaterThan 0
            $pauses[$i] | Should -BeLessThan 250
            if ($i -gt 0) { $pauses[$i] | Should -BeGreaterOrEqual $pauses[$i - 1] }
            $sum += $pauses[$i]
        }
        $pauses[3] | Should -BeGreaterThan $pauses[0] -Because 'the pauses grow'
        $sum | Should -BeLessThan 1000
    }

    It 'LG-15 succeeds on the fifth attempt when the file is released during the fourth pause' {
        [System.IO.File]::WriteAllText($script:LogPath, 'x')
        Open-Held $script:LogPath 'None'
        Use-Sleep 4
        Add-SwOperationText -File $script:LogPath -Text ('late' + $script:Crlf)
        $script:Sleeps.Count | Should -Be 4
        [System.IO.File]::ReadAllText($script:LogPath) | Should -BeExactly ('x' + 'late' + $script:Crlf)
    }

    It 'LG-15 passes on an UnauthorizedAccessException at once, without a pause, when the path is a folder' {
        [void](New-Dir $script:LogPath)
        $failure = Assert-Throws { Add-SwOperationText -File $script:LogPath -Text 'x' }
        Test-ExceptionChain $failure.Exception ([System.UnauthorizedAccessException]) | Should -BeTrue
        $script:Sleeps.Count | Should -Be 0
    }

    It 'LG-15 treats a missing folder as an IOException: 4 pauses, then the error' {
        $missing = P $script:Work 'no' 'such' 'operations.log'
        $failure = Assert-Throws { Add-SwOperationText -File $missing -Text 'x' }
        Test-ExceptionChain $failure.Exception ([System.IO.IOException]) | Should -BeTrue
        $script:Sleeps.Count | Should -Be 4
    }

    It 'LG-17 appends to a file that another reader holds with read and write sharing, without a pause' {
        [System.IO.File]::WriteAllText($script:LogPath, 'x')
        Open-Held $script:LogPath 'ReadWrite' 'Read'
        Add-SwOperationText -File $script:LogPath -Text ('while read' + $script:Crlf)
        $script:Sleeps.Count | Should -Be 0
        Close-Held
        [System.IO.File]::ReadAllText($script:LogPath) | Should -BeExactly ('x' + 'while read' + $script:Crlf)
    }

    It 'LG-17 [W] appends to a file that another writer holds with read and write sharing, without a pause' {
        [System.IO.File]::WriteAllText($script:LogPath, 'x')
        Open-Held $script:LogPath 'ReadWrite' 'Write'
        Add-SwOperationText -File $script:LogPath -Text ('while written' + $script:Crlf)
        $script:Sleeps.Count | Should -Be 0
        Close-Held
        [System.IO.File]::ReadAllText($script:LogPath) | Should -Match 'while written'
    }
}

# ============================================================================
# Failures lose the line, never the caller
# ============================================================================

Describe 'Write-SwOperation: a line that cannot be written' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Write-SwOperation', 'Add-SwOperationText', 'Write-SwDebug', 'Move-SwOperationLogAside', 'Write-SwDiagnosticLine'
        Use-Clock
        Use-DebugCapture
        Use-Sleep
        Mock Write-Host { }
        Mock Write-SwDiagnosticLine { }
    }
    AfterEach { Close-Held; Stop-Case }

    It 'LG-16 reports a folder in place of the log file once, with the prefix and the path, and throws nothing' {
        [void](New-Dir $script:LogPath)
        $streams = Get-AllOutput { Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB' }
        $streams.Count | Should -Be 0
        $script:Messages.Count | Should -Be 1
        $script:Messages[0] | Should -BeLike 'operations.log not written: *'
        $script:Messages[0].Contains($script:LogPath) | Should -BeTrue
        $script:Messages[0].Length | Should -BeGreaterThan ('operations.log not written: ' + $script:LogPath).Length -Because 'the reason follows'
        $script:Sleeps.Count | Should -Be 0
        $script:SweeprOperationsLogStarted | Should -BeFalse
        Should -Invoke -CommandName Write-Host -Times 0 -Exactly
    }

    It 'LG-16 reports a failing append once and keeps the file as it was' {
        Mock Add-SwOperationText { throw 'disk full' }
        Write-FileBytes $script:LogPath (New-Bytes 10)
        { Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB' } | Should -Not -Throw
        $script:Messages.Count | Should -Be 1
        $script:Messages[0] | Should -BeLike 'operations.log not written: *'
        [System.IO.File]::ReadAllBytes($script:LogPath).Length | Should -Be 10
        $script:SweeprOperationsLogStarted | Should -BeFalse
    }

    It 'LG-16 writes nothing and reports once when the clock fails' {
        Mock Get-Date { throw 'clock failed' }
        { Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB' } | Should -Not -Throw
        [System.IO.File]::Exists($script:LogPath) | Should -BeFalse
        $script:Messages.Count | Should -Be 1
        $script:Messages[0] | Should -BeLike 'operations.log not written: *'
        $script:SweeprOperationsLogStarted | Should -BeFalse
    }

    It 'LG-16 loses the record, reports it once and throws nothing when the file stays held' {
        [void](New-Dir $script:Dir)
        [System.IO.File]::WriteAllText($script:LogPath, 'x')
        Open-Held $script:LogPath 'None'
        { Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB' } | Should -Not -Throw
        $script:Sleeps.Count | Should -Be 4
        $script:Messages.Count | Should -Be 1
        $script:Messages[0] | Should -BeLike 'operations.log not written: *'
        Close-Held
        [System.IO.File]::ReadAllText($script:LogPath) | Should -BeExactly 'x'
        $script:SweeprOperationsLogStarted | Should -BeFalse
    }

    It 'LG-16 writes the record once and reports nothing when the file is released during a pause' {
        [void](New-Dir $script:Dir)
        [System.IO.File]::WriteAllText($script:LogPath, 'x')
        Open-Held $script:LogPath 'None'
        Use-Sleep 2
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        $script:Sleeps.Count | Should -Be 2
        $script:Messages.Count | Should -Be 0
        @(Get-RecordLines $script:LogPath).Count | Should -Be 1
        @(Get-MarkerLines $script:LogPath).Count | Should -Be 1
    }

    It 'LG-16 appends one complete text per record: marker and record come in one call' {
        Use-TextCapture
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        Should -Invoke -CommandName Add-SwOperationText -Times 1 -Exactly
        $script:Texts[0].EndsWith($script:Crlf) | Should -BeTrue
        $script:Texts[0].Contains('# ==========') | Should -BeTrue
        $script:Texts[0].Contains('REMOVED C:\x (1KB)') | Should -BeTrue
    }

    It 'LG-16 returns nothing, before and after a lost record, and does not change the result of the caller' {
        [void](New-Dir $script:LogPath)
        $result = & {
            'before'
            Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
            'after'
        }
        @($result) -join '|' | Should -BeExactly 'before|after'
    }

    It 'S-3 throws for no input in no state of the log file: <State>' -ForEach $script:FileStates {
        $blocked = P $script:Work 'blocked'
        if ($State -eq 'a folder in place of the log file') { [void](New-Dir $script:LogPath) }
        elseif ($State -eq 'a file in place of the parent folder') { [System.IO.File]::WriteAllText($blocked, 'f'); $script:SweeprOperationsLogFile = P $blocked 'operations.log' }
        elseif ($State -eq 'no log file configured') { $script:SweeprOperationsLogFile = '' }
        elseif ($State -eq 'SWEEPR_NO_OPLOG set to 1') { Set-Env 'SWEEPR_NO_OPLOG' '1' }
        foreach ($item in $Texts) {
            $text = $item.Text
            $failure = $null
            try { $streams = Get-AllOutput { Write-SwOperation -Action 'REMOVED' -Path $text -Detail $text } }
            catch { $failure = $_ }
            ($null -eq $failure) | Should -BeTrue -Because "Write-SwOperation with $($item.Label) in the state '$State' threw: $failure"
            $streams.Count | Should -Be 0 -Because "no output for $($item.Label)"
        }
        $script:Messages.Count | Should -BeLessOrEqual $Texts.Count
    }

    It 'S-3 does not throw for an action, command and run id of any kind' -ForEach $script:HostileCases {
        foreach ($item in $Texts) {
            Set-Env '_SWEEPR_OPLOG_RUN_COMMAND' $item.Text
            Set-Env '_SWEEPR_OPLOG_RUN_ID' $item.Text
            { Write-SwOperation -Action $item.Text -Path 'C:\x' -Detail 'd' } | Should -Not -Throw -Because $item.Label
        }
    }
}

# ============================================================================
# Concurrent use
# ============================================================================

Describe 'Write-SwOperation: concurrent use' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Write-SwOperation', 'Add-SwOperationText', 'Write-SwDebug'
        Use-Clock
        Use-DebugCapture
        Use-Sleep
        Mock Write-Host { }
    }
    AfterEach { Close-Held; Stop-Case }

    It 'LG-17 writes while a reader holds the log open with read and write sharing and does not wait' {
        Write-SwOperation -Action 'REMOVED' -Path 'C:\first' -Detail 'd'
        Open-Held $script:LogPath 'ReadWrite' 'Read'
        Write-SwOperation -Action 'REMOVED' -Path 'C:\second' -Detail 'd'
        $script:Sleeps.Count | Should -Be 0
        $script:Messages.Count | Should -Be 0
        Close-Held
        @(Get-RecordLines $script:LogPath).Count | Should -Be 2
    }

    It 'LG-17 lets sw history read the log while a writer holds it open with read and write sharing' {
        Write-SwOperation -Action 'REMOVED' -Path 'C:\first' -Detail 'd'
        Open-Held $script:LogPath 'ReadWrite' 'Write'
        $history = Read-SwHistory -Path $script:LogPath
        @($history.Operations).Count | Should -Be 1
    }
}

Describe 'Write-SwOperation: two processes append at the same time' {
    BeforeAll {
        # Two child PowerShell processes append 40 records each in a loop while the test opens the file
        # for reading again and again; the results are read by the tests below.
        $script:SharedDir = New-Dir (P $TestDrive 'shared-run')
        $script:SharedFile = P $script:SharedDir 'operations.log'
        $script:SharedCount = 40
        $processes = New-Object System.Collections.Generic.List[object]
        foreach ($name in 'childa', 'childb') {
            $code = @"
`$ErrorActionPreference = 'Stop'
. $(ConvertTo-TestLiteral $script:LogScript)
`$script:SweeprOperationsLogFile = $(ConvertTo-TestLiteral $script:SharedFile)
for (`$i = 0; `$i -lt $($script:SharedCount); `$i++) { Write-SwOperation -Action 'REMOVED' -Path ('C:\$name\file' + `$i) -Detail 'x' }
"@
            $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($code))
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = (Get-Process -Id $PID).Path
            $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            foreach ($variable in 'SWEEPR_NO_OPLOG', 'SWEEPR_DEBUG', 'SWEEPR_DRY_RUN', '_SWEEPR_OPLOG_RUN_ID') { if ($psi.EnvironmentVariables.ContainsKey($variable)) { $psi.EnvironmentVariables.Remove($variable) } }
            $psi.EnvironmentVariables['_SWEEPR_OPLOG_RUN_COMMAND'] = $name
            $psi.EnvironmentVariables['SWEEPR_DATA_DIR'] = $script:SharedDir
            $process = [System.Diagnostics.Process]::Start($psi)
            $processes.Add(@{ Process = $process; Out = $process.StandardOutput.ReadToEndAsync(); Err = $process.StandardError.ReadToEndAsync() })
        }
        $script:SharedReads = 0
        $deadline = [datetime]::UtcNow.AddSeconds(120)
        while (@($processes | Where-Object { -not $_.Process.HasExited }).Count -gt 0 -and [datetime]::UtcNow -lt $deadline) {
            if ([System.IO.File]::Exists($script:SharedFile)) {
                $stream = $null
                try {
                    $stream = [System.IO.File]::Open($script:SharedFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                    $script:SharedReads++
                }
                catch { $null = $_ }
                finally { if ($null -ne $stream) { $stream.Dispose() } }
            }
            [System.Threading.Thread]::Sleep(5)
        }
        $script:SharedExit = @()
        $script:SharedErrors = @()
        foreach ($entry in $processes) {
            if (-not $entry.Process.WaitForExit(120000)) { $entry.Process.Kill(); throw 'a writing child timed out' }
            $script:SharedExit += $entry.Process.ExitCode
            $script:SharedErrors += (Get-ChildStderr $entry.Err.Result)
        }
    }

    It 'LG-17 [W] lets neither writer nor reader wait for good: both children finish, the reader opens the file all along' {
        foreach ($code in $script:SharedExit) { $code | Should -Be 0 -Because ($script:SharedErrors -join ' ') }
        $script:SharedReads | Should -BeGreaterThan 0
    }

    It 'S-8 [W] leaves only whole lines in the file' {
        $lines = @(Get-LogLines $script:SharedFile | Where-Object { $_.Length -gt 0 })
        $lines.Count | Should -BeGreaterThan 0
        foreach ($line in $lines) {
            ($script:RecordPattern.IsMatch($line) -or $script:MarkerPattern.IsMatch($line)) | Should -BeTrue -Because "a whole line: $line"
        }
    }

    It 'S-8 [W] keeps every record exactly once, none overwritten by the other process' {
        $records = @(Get-RecordLines $script:SharedFile)
        $records.Count | Should -Be (2 * $script:SharedCount)
        foreach ($name in 'childa', 'childb') {
            for ($i = 0; $i -lt $script:SharedCount; $i++) {
                @($records | Where-Object { $_.Contains(' C:\' + $name + '\file' + $i + ' ') }).Count | Should -Be 1 -Because "$name wrote file$i once"
            }
        }
    }
}

# ============================================================================
# Compatibility with sw history
# ============================================================================

Describe 'Write-SwOperation: files that sw history reads' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Write-SwOperation', 'Add-SwOperationText', 'Write-SwDebug'
        Use-Clock
        Use-DebugCapture
        Mock Write-Host { }
    }
    AfterEach { Stop-Case }

    It 'LG-18 gives Read-SwHistory two sessions with 2 and 1 operations for two runs in one file' {
        Set-Env '_SWEEPR_OPLOG_RUN_COMMAND' 'clean'
        Set-Env '_SWEEPR_OPLOG_RUN_ID' 'a1'
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        Write-SwOperation -Action 'FAILED' -Path 'C:\y' -Detail 'access denied'
        Set-Env '_SWEEPR_OPLOG_RUN_COMMAND' 'uninstall'
        Set-Env '_SWEEPR_OPLOG_RUN_ID' 'b2'
        $script:SweeprOperationsLogStarted = $false
        Write-SwOperation -Action 'UNINSTALLED' -Path 'C:\Program Files (x86)\Contoso App' -Detail '2.0MB'
        $history = Read-SwHistory -Path $script:LogPath
        $sessions = @($history.Sessions)
        $sessions.Count | Should -Be 2
        $sessions[0].command | Should -BeExactly 'clean'
        $sessions[0].run_id | Should -BeExactly 'a1'
        $sessions[0].operation_count | Should -Be 2
        $sessions[1].command | Should -BeExactly 'uninstall'
        $sessions[1].run_id | Should -BeExactly 'b2'
        $sessions[1].operation_count | Should -Be 1
        $sessions[0].started_at | Should -BeExactly '2026-10-15 10:00:01'
    }

    It 'LG-18 gives Read-SwHistory one session when the path holds a line break and the text of a marker' {
        $path = 'C:\x' + [char]13 + [char]10 + '# ========== x run=y session started at z =========='
        Write-SwOperation -Action 'REMOVED' -Path $path -Detail 'd'
        $history = Read-SwHistory -Path $script:LogPath
        @($history.Sessions).Count | Should -Be 1
        $history.Sessions[0].command | Should -BeExactly 'sweepr'
        @($history.Operations).Count | Should -Be 1
    }

    It 'LG-18 gives Read-SwHistory every written record, with the inputs assigned correctly' {
        $expected = New-Object System.Collections.Generic.List[object]
        $actions = @('REMOVED', 'RECYCLED', 'UNINSTALLED', 'DISABLED', 'RESTORED', 'SKIPPED', 'FAILED', 'OPTIMIZED', 'OWNER')
        for ($i = 0; $i -lt $actions.Count; $i++) {
            $path = 'C:\Program Files (x86)\App ' + $i + [char]0xDC
            Write-SwOperation -Action $actions[$i] -Path $path -Detail ('d (' + $i + ')')
            $expected.Add(@{ Action = $actions[$i].ToLowerInvariant(); Path = $path; Detail = ('d [' + $i + ']') })
        }
        $operations = @((Read-SwHistory -Path $script:LogPath).Operations)
        $operations.Count | Should -Be $actions.Count
        for ($i = 0; $i -lt $actions.Count; $i++) {
            $operations[$i].action | Should -BeExactly $expected[$i].Action
            $operations[$i].path | Should -BeExactly $expected[$i].Path
            $operations[$i].detail | Should -BeExactly $expected[$i].Detail
        }
    }

    It 'LG-18 uses sweepr as the command when no run command is set' {
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        (Read-SwHistory -Path $script:LogPath).Sessions[0].command | Should -BeExactly 'sweepr'
    }
}

# ============================================================================
# No side effects, own files only
# ============================================================================

Describe 'Write-SwOperation: no side effects and only its own files' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Write-SwOperation', 'Add-SwOperationText', 'Write-SwDebug', 'Write-SwDiagnosticLine', 'Stop-SwSpinner', 'Start-SwSpinner'
        Use-Clock
        Use-DebugCapture
        Use-Sleep
        Mock Write-Host { }
    }
    AfterEach { Close-Held; Stop-Case }

    It 'LG-19 touches no spinner, section, statistic or console, also in debug mode and after a success' {
        Mock Write-SwDiagnosticLine { }
        Mock Stop-SwSpinner { }
        Mock Start-SwSpinner { }
        $script:LogConfig = @{ DebugEnabled = $true; LogFile = $null }
        $section = @{ Active = $true; Activity = $false; Name = 'Cleanup' }
        $script:CurrentSection = $section
        $collector = New-Object 'System.Collections.Generic.List[string]'
        $script:SectionCollector = $collector
        $script:SpinnerDisabled = $false
        $script:FilesCleaned = 5
        $script:TotalItems = 7
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        Should -Invoke -CommandName Write-Host -Times 0 -Exactly
        Should -Invoke -CommandName Write-SwDiagnosticLine -Times 0 -Exactly
        Should -Invoke -CommandName Stop-SwSpinner -Times 0 -Exactly
        Should -Invoke -CommandName Start-SwSpinner -Times 0 -Exactly
        $script:CurrentSection.Active | Should -BeTrue
        $script:CurrentSection.Activity | Should -BeFalse
        $script:CurrentSection.Name | Should -BeExactly 'Cleanup'
        $collector.Count | Should -Be 0
        $script:SpinnerDisabled | Should -BeFalse
        $script:FilesCleaned | Should -Be 5
        $script:TotalItems | Should -Be 7
        $script:Messages.Count | Should -Be 0
    }

    It 'S-5 creates only the folder and operations.log, and operations.log.old when it rotates' {
        $probe = New-Dir (P $script:Work 'probe')
        $previous = [System.Environment]::CurrentDirectory
        [System.Environment]::CurrentDirectory = $probe
        try {
            Write-FileBytes $script:LogPath (New-Bytes 64 65)
            $script:SweeprOperationsLogMaxBytes = 16
            Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
            $listing = @(Get-Listing $script:Work | Where-Object { $_ -notlike '*probe*' })
            $listing.Count | Should -Be 3
            @($listing | Where-Object { $_ -ceq 'D config' }).Count | Should -Be 1
            @($listing | Where-Object { $_ -ceq ('F config' + $script:Sep + 'operations.log.old 64') }).Count | Should -Be 1
            @($listing | Where-Object { $_ -clike ('F config' + $script:Sep + 'operations.log *') -and $_ -notlike '*.old*' }).Count | Should -Be 1
            (Get-Listing $probe) -join '|' | Should -BeExactly ''
        }
        finally { [System.Environment]::CurrentDirectory = $previous }
    }

    It 'S-5 leaves exactly operations.log and operations.log.old in the folder after a rotation' {
        Write-FileBytes $script:LogPath (New-Bytes 64 65)
        $script:SweeprOperationsLogMaxBytes = 16
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        $names = @(Get-ChildItem -LiteralPath $script:Dir -Force | ForEach-Object { $_.Name } | Sort-Object)
        ($names -join '|') | Should -BeExactly 'operations.log|operations.log.old'
    }

    It 'S-5 leaves the other files of the folder as they are' {
        [void](New-Dir $script:Dir)
        [System.IO.File]::WriteAllText((P $script:Dir 'whitelist.txt'), 'keep me')
        [System.IO.File]::WriteAllText((P $script:Dir 'sweepr_debug_session.log'), 'keep me too')
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        [System.IO.File]::ReadAllText((P $script:Dir 'whitelist.txt')) | Should -BeExactly 'keep me'
        [System.IO.File]::ReadAllText((P $script:Dir 'sweepr_debug_session.log')) | Should -BeExactly 'keep me too'
    }

    It 'S-5 writes to the file named in the variable and to no other place' {
        $elsewhere = P $script:Work 'elsewhere' 'chosen.log'
        $script:SweeprOperationsLogFile = $elsewhere
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        [System.IO.File]::Exists($elsewhere) | Should -BeTrue
        [System.IO.Directory]::Exists($script:Dir) | Should -BeFalse
        @(Get-Listing $script:Work).Count | Should -Be 2
    }

    It 'S-7 writes nothing anywhere when no folder is known, and does not fall back to a default folder' {
        $profileDir = New-Dir (P $script:Work 'profile')
        $probe = New-Dir (P $script:Work 'probe')
        $previous = [System.Environment]::CurrentDirectory
        [System.Environment]::CurrentDirectory = $probe
        try {
            Set-Env 'USERPROFILE' $profileDir
            $script:SweeprOperationsLogFile = ''
            $script:SweeprDebugLogFile = ''
            { Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB' } | Should -Not -Throw
            (Get-Listing $profileDir) -join '|' | Should -BeExactly ''
            (Get-Listing $probe) -join '|' | Should -BeExactly ''
            @(Get-Listing $script:Work).Count | Should -Be 2 -Because 'only the two empty folders of the test exist'
        }
        finally { [System.Environment]::CurrentDirectory = $previous }
    }

    It 'S-6 starts no process, uses no network and compiles nothing when it writes' {
        Mock Start-Process { }
        Mock Invoke-WebRequest { }
        Mock Invoke-RestMethod { }
        Mock Invoke-Expression { }
        Mock Add-Type { }
        Write-SwOperation -Action 'REMOVED' -Path 'C:\$(Get-Date) {0} %TEMP%' -Detail '`x'
        foreach ($name in 'Start-Process', 'Invoke-WebRequest', 'Invoke-RestMethod', 'Invoke-Expression', 'Add-Type') {
            Should -Invoke -CommandName $name -Times 0 -Exactly -Because "writing must not call $name"
        }
        @(Get-RecordLines $script:LogPath).Count | Should -Be 1
    }
}
