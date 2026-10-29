# Sweepr - tests for the waiting spinner, the progress call and the interactive-output check of
# lib\core\log.ps1, including the native class Sweepr.SwSpinner.
#
# The rule numbers in the test names (LG- and S-) number the rules and the safety invariants of the
# module's behavior; each rule and invariant has at least one test.
#
# Interface pinned here (new names; each old name stays as a forwarding function):
#   Test-SwInteractiveOutput                         $true only on a real console
#   Initialize-SwSpinner                             compiles Sweepr.SwSpinner once, never while loading
#   Start-SwSpinner [-Message], Update-SwSpinner [-Message], Stop-SwSpinner
#   Write-SwProgress [-Activity] [-Status] [-PercentComplete] [-Completed] [-Current] [-Total] [-Message] [-Width]
#   [Sweepr.SwSpinner]::Start(string) / Stop() / Fit(string, int)
# Script variables that tests replace: $script:SpinnerDisabled, $script:CurrentSection.
#
# Seams used with Mock:
#   Test-SwInteractiveOutput, Initialize-SwSpinner, Start-SwSpinner, Update-SwSpinner, Stop-SwSpinner
#   Write-Host, Write-Progress, Add-Type
#
# Platform notes:
#   - The animation tests replace Console.Out by a writer, which is the documented fallback of the class;
#     the real console API is only used on Windows and checked in the test marked [W], which runs a
#     child PowerShell with its own console screen buffer.
#   - A host without a console window reports no usable width (an exception, or zero or a negative
#     number). The tests that look at the text of a frame then accept any non-empty beginning of the label.
#   - Timing: the animation ticks every 80 ms; the tests wait generously and allow a range of frames.
#   - Nothing real is touched: no registry, no network, no real operations.log.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    # LG-39 (6): the examples of the rule.
    $script:FitCases = @(
        @{ Label = 'CJK before ASCII'; Value = ([string][char]0x4E2D + [char]0x6587 + 'abc'); Cells = 5; Expected = ([string][char]0x4E2D + [char]0x6587 + 'a') }
        @{ Label = 'a wide character that does not fit'; Value = ([string][char]0x4E2D + [char]0x6587); Cells = 3; Expected = ([string][char]0x4E2D) }
        @{ Label = 'an emoji that does not fit'; Value = ('a' + [char]0xD83D + [char]0xDE00 + 'b'); Cells = 2; Expected = 'a' }
        @{ Label = 'plain text that fits'; Value = 'plain'; Cells = 80; Expected = 'plain' }
        @{ Label = 'zero cells'; Value = 'abc'; Cells = 0; Expected = '' }
        @{ Label = 'negative cells'; Value = 'abc'; Cells = -3; Expected = '' }
        @{ Label = 'a combining mark stays with its base'; Value = ('e' + [char]0x0301 + 'x'); Cells = 1; Expected = ('e' + [char]0x0301) }
        @{ Label = 'the empty string'; Value = ''; Cells = 5; Expected = '' }
        @{ Label = 'null'; Value = $null; Cells = 5; Expected = '' }
        @{ Label = 'a wide character first with one cell'; Value = ([string][char]0x4E2D + 'a'); Cells = 1; Expected = '' }
        @{ Label = 'a narrow character after a wide one that does not fit is not taken'; Value = ('a' + [char]0x4E2D + 'b'); Cells = 2; Expected = 'a' }
        @{ Label = 'exactly as many cells as the text has'; Value = ('ab' + [char]0x4E2D); Cells = 4; Expected = ('ab' + [char]0x4E2D) }
        @{ Label = 'a lone high surrogate counts one cell'; Value = ('a' + [char]0xD800 + 'b'); Cells = 2; Expected = ('a' + [char]0xD800) }
        @{ Label = 'a lone low surrogate counts one cell'; Value = ('a' + [char]0xDC00 + 'b'); Cells = 3; Expected = ('a' + [char]0xDC00 + 'b') }
        @{ Label = 'a high surrogate at the end counts one cell'; Value = ('ab' + [char]0xD83D); Cells = 3; Expected = ('ab' + [char]0xD83D) }
        @{ Label = 'a zero-width space counts nothing'; Value = ('a' + [char]0x200B + 'b'); Cells = 2; Expected = ('a' + [char]0x200B + 'b') }
    )

    # LG-39 (6): code points on both sides of every range, and the categories that count nothing.
    $script:WidthCases = @(
        @{ CodePoint = 0x10FF; Cells = 1 }, @{ CodePoint = 0x1100; Cells = 2 }, @{ CodePoint = 0x115F; Cells = 2 }, @{ CodePoint = 0x1160; Cells = 1 }
        @{ CodePoint = 0x2328; Cells = 1 }, @{ CodePoint = 0x2329; Cells = 2 }, @{ CodePoint = 0x232A; Cells = 2 }, @{ CodePoint = 0x232B; Cells = 1 }
        @{ CodePoint = 0x2E7F; Cells = 1 }, @{ CodePoint = 0x2E80; Cells = 2 }, @{ CodePoint = 0x303E; Cells = 2 }, @{ CodePoint = 0x303F; Cells = 1 }
        @{ CodePoint = 0x3040; Cells = 2 }, @{ CodePoint = 0x4E2D; Cells = 2 }, @{ CodePoint = 0xA4CF; Cells = 2 }, @{ CodePoint = 0xA4D0; Cells = 1 }
        @{ CodePoint = 0xABFF; Cells = 1 }, @{ CodePoint = 0xAC00; Cells = 2 }, @{ CodePoint = 0xD7A3; Cells = 2 }, @{ CodePoint = 0xD7A4; Cells = 1 }
        @{ CodePoint = 0xF8FF; Cells = 1 }, @{ CodePoint = 0xF900; Cells = 2 }, @{ CodePoint = 0xFAFF; Cells = 2 }, @{ CodePoint = 0xFB00; Cells = 1 }
        @{ CodePoint = 0xFE0F; Cells = 0 }, @{ CodePoint = 0xFE10; Cells = 2 }, @{ CodePoint = 0xFE19; Cells = 2 }, @{ CodePoint = 0xFE1A; Cells = 1 }
        @{ CodePoint = 0xFE2F; Cells = 0 }, @{ CodePoint = 0xFE30; Cells = 2 }, @{ CodePoint = 0xFE6F; Cells = 2 }, @{ CodePoint = 0xFE70; Cells = 1 }
        @{ CodePoint = 0xFEFF; Cells = 0 }, @{ CodePoint = 0xFF00; Cells = 2 }, @{ CodePoint = 0xFF21; Cells = 2 }, @{ CodePoint = 0xFF60; Cells = 2 }
        @{ CodePoint = 0xFF61; Cells = 1 }, @{ CodePoint = 0xFFDF; Cells = 1 }, @{ CodePoint = 0xFFE0; Cells = 2 }, @{ CodePoint = 0xFFE6; Cells = 2 }
        @{ CodePoint = 0xFFE7; Cells = 1 }, @{ CodePoint = 0x1F2FF; Cells = 1 }, @{ CodePoint = 0x1F300; Cells = 2 }, @{ CodePoint = 0x1F600; Cells = 2 }
        @{ CodePoint = 0x1FAFF; Cells = 2 }, @{ CodePoint = 0x1FB00; Cells = 1 }, @{ CodePoint = 0x1FFFF; Cells = 1 }, @{ CodePoint = 0x20000; Cells = 2 }
        @{ CodePoint = 0x3FFFD; Cells = 2 }, @{ CodePoint = 0x3FFFE; Cells = 1 }, @{ CodePoint = 0x40000; Cells = 1 }
        @{ CodePoint = 0x0041; Cells = 1 }, @{ CodePoint = 0x00E9; Cells = 1 }, @{ CodePoint = 0x0020; Cells = 1 }
        @{ CodePoint = 0x0300; Cells = 0 }, @{ CodePoint = 0x0301; Cells = 0 }, @{ CodePoint = 0x3099; Cells = 0 }, @{ CodePoint = 0x20DD; Cells = 0 }
        @{ CodePoint = 0x200B; Cells = 0 }, @{ CodePoint = 0x200D; Cells = 0 }, @{ CodePoint = 0x00AD; Cells = 0 }
        @{ CodePoint = 0x0001; Cells = 0 }, @{ CodePoint = 0x001B; Cells = 0 }, @{ CodePoint = 0x007F; Cells = 0 }, @{ CodePoint = 0x0085; Cells = 0 }
    )

    $script:WidthCases = @($script:WidthCases | ForEach-Object { $_['Hex'] = ('{0:X4}' -f $_['CodePoint']); $_ })

    # LG-38: how the label of the spinner is chosen.
    $script:ProgressCases = @(
        @{ Label = 'activity and status'; Parameters = @{ Activity = 'Scanning apps'; Status = 'Registry'; PercentComplete = 50 }; Expected = 'Scanning apps, Registry' }
        @{ Label = 'a message wins over activity'; Parameters = @{ Activity = 'A'; Message = 'M' }; Expected = 'M' }
        @{ Label = 'a message wins over activity and status'; Parameters = @{ Activity = 'A'; Status = 'S'; Message = 'M' }; Expected = 'M' }
        @{ Label = 'only the activity'; Parameters = @{ Activity = 'A' }; Expected = 'A' }
        @{ Label = 'an empty status'; Parameters = @{ Activity = 'A'; Status = '' }; Expected = 'A' }
        @{ Label = 'an empty message and a status'; Parameters = @{ Activity = 'A'; Status = 'S'; Message = '' }; Expected = 'A, S' }
        @{ Label = 'percent, current, total and width change nothing'; Parameters = @{ Activity = 'A'; Status = 'S'; PercentComplete = 99; Current = 3; Total = 9; Width = 10 }; Expected = 'A, S' }
        @{ Label = 'a percent value without text'; Parameters = @{ Activity = 'A'; PercentComplete = 10 }; Expected = 'A' }
    )

    # A terminal for the child process: the util-linux program script gives one on Linux.
    $script:HasTerminal = $false
    if ([System.IO.Path]::DirectorySeparatorChar -ne '\') {
        try { $script:HasTerminal = (@(& script --version 2>&1) -join ' ') -match 'util-linux' } catch { $script:HasTerminal = $false }
    }

    $script:HostileMessages = @(
        @{ Label = 'a NUL character'; Text = ('a' + [char]0 + 'b') }
        @{ Label = 'an escape sequence'; Text = ('a' + [char]27 + '[31mb') }
        @{ Label = 'a line break'; Text = ('a' + [char]13 + [char]10 + 'b') }
        @{ Label = 'a very long text'; Text = ('x' * 5000) }
        @{ Label = 'a lone surrogate'; Text = ('a' + [char]0xD800 + 'b') }
        @{ Label = 'format and wildcard characters'; Text = '{0} %TEMP% $(x) `n [a]*?' }
        @{ Label = 'the empty string'; Text = '' }
        @{ Label = '$null'; Text = $null }
    )
    $script:HostileCases = @(, @{ Texts = $script:HostileMessages })
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

    # ---- helpers for the spinner tests ------------------------------------------------------------

    $script:Glyphs = @([string][char]0x2816, [string][char]0x2832, [string][char]0x2834, [string][char]0x2826)

    # A writer that takes its time for every write, to hold the animation thread inside a frame.
    if ($null -eq ('SwTestSlowWriter' -as [type])) {
        Add-Type -TypeDefinition @'
using System.IO;
using System.Threading;
public class SwTestSlowWriter : StringWriter {
    public int DelayMs;
    public override void Write(string value) { if (DelayMs > 0) { Thread.Sleep(DelayMs); } base.Write(value); }
    public override void Write(char value) { if (DelayMs > 0) { Thread.Sleep(DelayMs); } base.Write(value); }
    public override void Write(char[] buffer, int index, int count) { if (DelayMs > 0) { Thread.Sleep(DelayMs); } base.Write(buffer, index, count); }
}
'@
    }

    # A writer in place of Console.Out; writes of the animation thread and reads of the test do not mix
    # while the spinner runs, and the test reads after Stop.
    function script:Use-FakeConsole {
        $script:SavedOut = [Console]::Out
        $script:SavedErr = [Console]::Error
        $script:OutWriter = New-Object System.IO.StringWriter
        $script:ErrWriter = New-Object System.IO.StringWriter
        [Console]::SetOut([System.IO.TextWriter]::Synchronized($script:OutWriter))
        [Console]::SetError([System.IO.TextWriter]::Synchronized($script:ErrWriter))
    }
    function script:Restore-FakeConsole {
        if ($null -ne ('Sweepr.SwSpinner' -as [type])) { try { [Sweepr.SwSpinner]::Stop() } catch { $null = $_ } }
        if ($null -ne $script:SavedOut) { [Console]::SetOut($script:SavedOut); $script:SavedOut = $null }
        if ($null -ne $script:SavedErr) { [Console]::SetError($script:SavedErr); $script:SavedErr = $null }
    }
    function script:Use-SpinnerType {
        Assert-Defined 'Initialize-SwSpinner'
        Initialize-SwSpinner
        ($null -ne ('Sweepr.SwSpinner' -as [type])) | Should -BeTrue -Because 'Initialize-SwSpinner defines Sweepr.SwSpinner'
        [Sweepr.SwSpinner]::Stop()
    }
    function script:Get-WindowWidth {
        try { [int][Console]::WindowWidth } catch { 0 }
    }
    # The frames of the text the spinner wrote: glyph and message of each.
    function script:Get-SpinnerFrames([string]$Text) {
        $esc = [string][char]27
        $pattern = '^' + [regex]::Escape($esc + '[2K') + '  ' + [regex]::Escape($esc + '[34m') + '(?<g>[' + [char]0x2816 + [char]0x2832 + [char]0x2834 + [char]0x2826 + '])' + [regex]::Escape($esc + '[0m') + ' (?<m>.*)$'
        $frames = New-Object System.Collections.Generic.List[object]
        foreach ($segment in $Text.Split([char]13)) {
            $match = [regex]::Match($segment, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
            if ($match.Success) { $frames.Add(@{ Glyph = $match.Groups['g'].Value; Message = $match.Groups['m'].Value }) }
        }
        , $frames
    }
    # Every part of the text between two carriage returns is empty, a frame, or the clear-line sequence.
    function script:Test-OnlyFramesAndClear([string]$Text) {
        $esc = [string][char]27
        $clear = $esc + '[2K'
        foreach ($segment in $Text.Split([char]13)) {
            if ($segment.Length -eq 0 -or $segment -ceq $clear) { continue }
            if ($segment.StartsWith($clear + '  ' + $esc + '[34m')) { continue }
            return $false
        }
        $true
    }
    # The message of a frame, compared with the label: equal after fitting when the window width is
    # known; otherwise any non-empty beginning of the label.
    function script:Assert-FrameMessage([string]$Message, [string]$Label) {
        $width = Get-WindowWidth
        if ($width -gt 5) {
            $cells = [math]::Max(1, $width - 5)
            $Message | Should -BeExactly (Get-RefFit $Label $cells)
        }
        else {
            $Message.Length | Should -BeGreaterThan 0
            $Label.StartsWith($Message) | Should -BeTrue -Because "the message '$Message' begins the label '$Label'"
        }
    }

    # The rules of the cell widths, written independently of the module.
    function script:Get-RefCells([string]$Text, [int]$Index) {
        $first = $Text[$Index]
        $codePoint = [int]$first
        if ([char]::IsHighSurrogate($first)) {
            if ($Index + 1 -lt $Text.Length -and [char]::IsLowSurrogate($Text[$Index + 1])) { $codePoint = [char]::ConvertToUtf32($first, $Text[$Index + 1]) }
            else { return 1 }
        }
        elseif ([char]::IsLowSurrogate($first)) { return 1 }
        $category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($Text, $Index)
        if ($category -in @([System.Globalization.UnicodeCategory]::NonSpacingMark, [System.Globalization.UnicodeCategory]::EnclosingMark,
                [System.Globalization.UnicodeCategory]::Format, [System.Globalization.UnicodeCategory]::Control)) { return 0 }
        $ranges = @(@(0x1100, 0x115F), @(0x2329, 0x232A), @(0x2E80, 0x303E), @(0x3040, 0xA4CF), @(0xAC00, 0xD7A3), @(0xF900, 0xFAFF),
            @(0xFE10, 0xFE19), @(0xFE30, 0xFE6F), @(0xFF00, 0xFF60), @(0xFFE0, 0xFFE6), @(0x1F300, 0x1FAFF), @(0x20000, 0x3FFFD))
        foreach ($range in $ranges) { if ($codePoint -ge $range[0] -and $codePoint -le $range[1]) { return 2 } }
        1
    }
    function script:Get-RefFit([AllowNull()][string]$Value, [int]$Cells) {
        if ([string]::IsNullOrEmpty($Value) -or $Cells -le 0) { return '' }
        $starts = [System.Globalization.StringInfo]::ParseCombiningCharacters($Value)
        $sum = 0
        $end = 0
        for ($i = 0; $i -lt $starts.Length; $i++) {
            $next = $Value.Length
            if ($i + 1 -lt $starts.Length) { $next = $starts[$i + 1] }
            $width = Get-RefCells $Value $starts[$i]
            if ($sum + $width -gt $Cells) { break }
            $sum += $width
            $end = $next
        }
        $Value.Substring(0, $end)
    }

    # What the whole file changes in the process, put back after the last test.
    $script:RootState = Save-State
    $script:RootEnv = Save-Env $script:EnvNames
    $script:SavedOut = $null
    $script:SavedErr = $null
    . $script:LogScript
}

AfterAll {
    Restore-FakeConsole
    Restore-State $script:RootState
    Restore-Env $script:RootEnv
}

# ============================================================================
# Test-SwInteractiveOutput
# ============================================================================

Describe 'Test-SwInteractiveOutput' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Test-SwInteractiveOutput'
    }
    AfterEach { Stop-Case }

    It 'LG-36 gives one boolean, never a list' {
        $answer = @(Test-SwInteractiveOutput)
        $answer.Count | Should -Be 1
        $answer[0] | Should -BeOfType [bool]
    }

    It 'LG-36 gives $false for TERM=<Value>, whatever the case' -ForEach @(
        @{ Value = 'dumb' }, @{ Value = 'DUMB' }, @{ Value = 'Dumb' }
    ) {
        Set-Env 'TERM' $Value
        $answer = @(Test-SwInteractiveOutput)
        $answer.Count | Should -Be 1
        $answer[0] | Should -BeFalse
    }

    It 'LG-36 does not throw when TERM is not set' {
        Set-Env 'TERM' $null
        { Test-SwInteractiveOutput } | Should -Not -Throw
        @(Test-SwInteractiveOutput)[0] | Should -BeOfType [bool]
    }

    It 'LG-36 reads TERM at every call' {
        Set-Env 'TERM' 'dumb'
        Test-SwInteractiveOutput | Should -BeFalse
        Set-Env 'TERM' 'xterm'
        { Test-SwInteractiveOutput } | Should -Not -Throw
    }

    It 'LG-36 checks the host name, both redirections and TERM, and answers $false when a check fails' {
        $body = (Get-Command -Name Test-SwInteractiveOutput -CommandType Function).ScriptBlock.ToString()
        $body | Should -Match 'ConsoleHost'
        $body | Should -Match 'IsOutputRedirected'
        $body | Should -Match 'IsInputRedirected'
        $body | Should -Match '(?i)TERM'
        $body | Should -Match '(?i)dumb'
        $body | Should -Match '(?s)try\s*\{.*\}\s*catch'
        # A failing check cannot be provoked here: judge what the handler answers.
        $ast = (Get-Command -Name Test-SwInteractiveOutput -CommandType Function).ScriptBlock.Ast
        $handlers = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))
        $handlers.Count | Should -BeGreaterThan 0
        foreach ($handler in $handlers) {
            $handler.Body.Extent.Text | Should -Match '\$false' -Because 'a failing check answers false'
            $handler.Body.Extent.Text | Should -Not -Match '\$true' -Because 'a failing check never answers true'
        }
    }
}

# ============================================================================
# Test-SwInteractiveOutput on a terminal
# ============================================================================

Describe 'Test-SwInteractiveOutput on a terminal' -Skip:(-not $script:HasTerminal) {
    BeforeAll {
        $script:TerminalScript = P $TestDrive 'interactive.ps1'
        [System.IO.File]::WriteAllText($script:TerminalScript, ("`$ErrorActionPreference = 'Stop'" + [Environment]::NewLine + ". $(ConvertTo-TestLiteral $script:LogScript)" + [Environment]::NewLine + "'result=' + @(Test-SwInteractiveOutput).Count + ':' + (Test-SwInteractiveOutput)" + [Environment]::NewLine))
        # Runs a command line of the shell with a terminal as standard input and output; gives what it printed.
        function script:Invoke-OnTerminal([string]$Command) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'script'
            $psi.Arguments = '-qec "' + $Command + '" /dev/null'
            $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            if ($psi.EnvironmentVariables.ContainsKey('SWEEPR_DEBUG')) { $psi.EnvironmentVariables.Remove('SWEEPR_DEBUG') }
            $process = [System.Diagnostics.Process]::Start($psi)
            $process.StandardInput.Close()
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(120000)) { $process.Kill(); throw 'the terminal command timed out' }
            $stdout.Result
        }
        $script:Shell = (Get-Process -Id $PID).Path
        $script:Run = "'" + $script:Shell + "' -NoProfile -File '" + $script:TerminalScript + "'"
    }

    It 'LG-36 gives $true on a terminal when TERM is xterm' {
        (Invoke-OnTerminal ('env TERM=xterm ' + $script:Run)) | Should -Match 'result=1:True'
    }

    It 'LG-36 gives $true on a terminal when TERM is not set' {
        (Invoke-OnTerminal ('env -u TERM ' + $script:Run)) | Should -Match 'result=1:True'
    }

    It 'LG-36 gives $false on a terminal when TERM is <Value>, whatever the case' -ForEach @(
        @{ Value = 'dumb' }, @{ Value = 'DUMB' }, @{ Value = 'Dumb' }
    ) {
        (Invoke-OnTerminal ('env TERM=' + $Value + ' ' + $script:Run)) | Should -Match 'result=1:False'
    }

    It 'LG-36 gives $false when standard output is redirected' {
        (Invoke-OnTerminal ('env TERM=xterm ' + $script:Run + ' | cat')) | Should -Match 'result=1:False'
    }

    It 'LG-36 gives $false when standard input is redirected' {
        (Invoke-OnTerminal ('env TERM=xterm ' + $script:Run + ' < /dev/null')) | Should -Match 'result=1:False'
    }
}

# ============================================================================
# Start-SwSpinner, Update-SwSpinner, Stop-SwSpinner
# ============================================================================

Describe 'Spinner functions' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Start-SwSpinner', 'Update-SwSpinner', 'Stop-SwSpinner', 'Initialize-SwSpinner', 'Test-SwInteractiveOutput'
        Use-SpinnerType
        Use-FakeConsole
        $script:SpinnerDisabled = $false
    }
    AfterEach { Restore-FakeConsole; Stop-Case }

    It 'LG-37 does nothing when SpinnerDisabled is true: no initialization, no output' {
        Mock Test-SwInteractiveOutput { $true }
        Mock Initialize-SwSpinner { }
        Mock Write-Host { }
        $script:SpinnerDisabled = $true
        Start-SwSpinner -Message 'x'
        [System.Threading.Thread]::Sleep(200)
        Should -Invoke -CommandName Initialize-SwSpinner -Times 0 -Exactly
        Should -Invoke -CommandName Write-Host -Times 0 -Exactly
        $script:OutWriter.ToString() | Should -BeExactly ''
    }

    It 'LG-37 does nothing when the output is not interactive, for Start, Update and Stop: no Write-Host, no bytes on stdout or stderr' {
        Mock Test-SwInteractiveOutput { $false }
        Mock Initialize-SwSpinner { }
        Mock Write-Host { }
        Start-SwSpinner -Message 'x'
        Update-SwSpinner -Message 'y'
        Stop-SwSpinner
        [System.Threading.Thread]::Sleep(200)
        Should -Invoke -CommandName Initialize-SwSpinner -Times 0 -Exactly
        Should -Invoke -CommandName Write-Host -Times 0 -Exactly
        $script:OutWriter.ToString() | Should -BeExactly ''
        $script:ErrWriter.ToString() | Should -BeExactly ''
    }

    It 'LG-37 starts the animation with the label when the output is interactive' {
        Mock Test-SwInteractiveOutput { $true }
        Mock Write-Host { }
        Start-SwSpinner -Message 'Scanning'
        [System.Threading.Thread]::Sleep(300)
        Stop-SwSpinner
        $frames = Get-SpinnerFrames $script:OutWriter.ToString()
        $frames.Count | Should -BeGreaterThan 0
        Assert-FrameMessage $frames[0].Message 'Scanning'
        Should -Invoke -CommandName Write-Host -Times 0 -Exactly
    }

    It 'LG-37 calls Initialize-SwSpinner before starting' {
        Mock Test-SwInteractiveOutput { $true }
        Mock Initialize-SwSpinner { }
        Start-SwSpinner -Message 'x'
        Should -Invoke -CommandName Initialize-SwSpinner -Times 1 -Exactly
    }

    It 'LG-37 shows a label with tab, line feed, carriage return and escape characters on one line without them' {
        Mock Test-SwInteractiveOutput { $true }
        $label = 'a' + [char]9 + 'b' + [char]10 + 'c' + [char]13 + 'd' + [char]27 + '[31m'
        Start-SwSpinner -Message $label
        [System.Threading.Thread]::Sleep(300)
        Stop-SwSpinner
        $text = $script:OutWriter.ToString()
        Test-OnlyFramesAndClear $text | Should -BeTrue -Because 'a carriage return of the label would split a frame'
        $text.Contains([string][char]10) | Should -BeFalse
        $text.Contains([string][char]9) | Should -BeFalse
        $stripped = $text.Replace(([string][char]27 + '[2K'), '').Replace(([string][char]27 + '[34m'), '').Replace(([string][char]27 + '[0m'), '')
        $stripped.Contains([string][char]27) | Should -BeFalse -Because 'the escape character of the label is gone'
        $frames = Get-SpinnerFrames $text
        $frames.Count | Should -BeGreaterThan 0
        Assert-FrameMessage $frames[0].Message 'a b c d [31m'
    }

    It 'LG-37 shows a short waiting text when no message is given' {
        Mock Test-SwInteractiveOutput { $true }
        Start-SwSpinner
        [System.Threading.Thread]::Sleep(300)
        Stop-SwSpinner
        $frames = Get-SpinnerFrames $script:OutWriter.ToString()
        $frames.Count | Should -BeGreaterThan 0
        $frames[0].Message.Length | Should -BeGreaterThan 0
    }

    It 'LG-37 swallows an error of the initialization and keeps the static output' {
        Mock Test-SwInteractiveOutput { $true }
        Mock Initialize-SwSpinner { throw 'no dynamic compilation here' }
        Mock Write-Host { }
        { Start-SwSpinner -Message 'x' } | Should -Not -Throw
        { Update-SwSpinner -Message 'x' } | Should -Not -Throw
        Should -Invoke -CommandName Write-Host -Times 0 -Exactly
    }

    It 'LG-37 lets Update-SwSpinner call Start-SwSpinner with the message' {
        Mock Start-SwSpinner { }
        Update-SwSpinner -Message 'Next step'
        Should -Invoke -CommandName Start-SwSpinner -Times 1 -Exactly -ParameterFilter { $Message -eq 'Next step' }
    }

    It 'LG-37 lets Update-SwSpinner replace the label while the animation runs' {
        Mock Test-SwInteractiveOutput { $true }
        Start-SwSpinner -Message 'One'
        [System.Threading.Thread]::Sleep(200)
        Update-SwSpinner -Message 'Two'
        [System.Threading.Thread]::Sleep(250)
        Stop-SwSpinner
        $frames = Get-SpinnerFrames $script:OutWriter.ToString()
        $frames[$frames.Count - 1].Message | Should -Not -BeNullOrEmpty
        $frames[$frames.Count - 1].Message[0] | Should -BeExactly 'T'
    }

    It 'LG-37 stops a running animation with Stop-SwSpinner and clears the line, also when SpinnerDisabled is true' {
        [Sweepr.SwSpinner]::Start('Scanning')
        [System.Threading.Thread]::Sleep(250)
        $script:SpinnerDisabled = $true
        Stop-SwSpinner
        $text = $script:OutWriter.ToString()
        $text.EndsWith([string][char]13 + [char]27 + '[2K') | Should -BeTrue
        [System.Threading.Thread]::Sleep(200)
        $script:OutWriter.ToString() | Should -BeExactly $text
    }

    It 'S-3 throws for no message: Start, Update and Stop' -ForEach $script:HostileCases {
        Mock Test-SwInteractiveOutput { $true }
        foreach ($item in $Texts) {
            $text = $item.Text
            $failure = $null
            try { Start-SwSpinner -Message $text; Update-SwSpinner -Message $text; Stop-SwSpinner } catch { $failure = $_ }
            ($null -eq $failure) | Should -BeTrue -Because "the spinner with $($item.Label) threw: $failure"
        }
        Stop-SwSpinner
        Test-OnlyFramesAndClear $script:OutWriter.ToString() | Should -BeTrue
    }

    It 'S-3 does not throw when Stop-SwSpinner is called without a started animation or twice' {
        { Stop-SwSpinner; Stop-SwSpinner } | Should -Not -Throw
    }
}

# ============================================================================
# Sections and the spinner
# ============================================================================

Describe 'Sections with a real spinner' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Start-SwSection', 'Stop-SwSection', 'Start-SwSpinner', 'Initialize-SwSpinner', 'Test-SwInteractiveOutput'
        Use-SpinnerType
        Use-FakeConsole
        Mock Write-Host { }
        Mock Test-SwInteractiveOutput { $true }
    }
    AfterEach { Restore-FakeConsole; Stop-Case }

    It 'LG-32 shows the title and starts no spinner when SpinnerDisabled is true' {
        Mock Initialize-SwSpinner { }
        $script:SpinnerDisabled = $true
        Start-SwSection 'User'
        Should -Invoke -CommandName Initialize-SwSpinner -Times 0 -Exactly
        Should -Invoke -CommandName Write-Host -Times 1
        $script:CurrentSection.Name | Should -BeExactly 'User'
        $script:CurrentSection.Active | Should -BeTrue
    }

    It 'LG-32 starts the spinner after the title when SpinnerDisabled is false' {
        Mock Initialize-SwSpinner { }
        $script:SpinnerDisabled = $false
        Start-SwSection 'User'
        Should -Invoke -CommandName Initialize-SwSpinner -Times 1 -Exactly
    }

    It 'LG-34 leaves no spinner running after Stop-SwSection: nothing is written after it returns' {
        $script:SpinnerDisabled = $false
        Start-SwSection 'User'
        [System.Threading.Thread]::Sleep(250)
        Stop-SwSection
        $text = $script:OutWriter.ToString()
        $text.EndsWith([string][char]13 + [char]27 + '[2K') | Should -BeTrue
        [System.Threading.Thread]::Sleep(200)
        $script:OutWriter.ToString() | Should -BeExactly $text
    }
}

# ============================================================================
# Write-SwProgress
# ============================================================================

Describe 'Write-SwProgress' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Write-SwProgress', 'Update-SwSpinner', 'Stop-SwSpinner'
        $script:Calls = New-Object System.Collections.Generic.List[object]
        Mock Update-SwSpinner { $script:Calls.Add(@{ Function = 'update'; Message = $Message }) }
        Mock Stop-SwSpinner { $script:Calls.Add(@{ Function = 'stop'; Message = $null }) }
        Mock Write-Host { }
    }
    AfterEach { Stop-Case }

    It 'LG-38 sets the label of the spinner once: <Label>' -ForEach $script:ProgressCases {
        $splat = $Parameters
        Write-SwProgress @splat
        $script:Calls.Count | Should -Be 1
        $script:Calls[0].Function | Should -BeExactly 'update'
        $script:Calls[0].Message | Should -BeExactly $Expected
    }

    It 'LG-38 stops the spinner once and does nothing else when -Completed is set' {
        Write-SwProgress -Activity 'A' -Status 'S' -PercentComplete 100 -Completed -Message 'M' -Current 3 -Total 3
        $script:Calls.Count | Should -Be 1
        $script:Calls[0].Function | Should -BeExactly 'stop'
        Should -Invoke -CommandName Update-SwSpinner -Times 0 -Exactly
    }

    It 'LG-38 uses a short waiting text when called without arguments' {
        Write-SwProgress
        $script:Calls.Count | Should -Be 1
        $script:Calls[0].Message | Should -Not -BeNullOrEmpty
    }

    It 'LG-38 writes nothing to the progress stream, the console or the pipeline and does not call the built-in Write-Progress' {
        Mock Write-Progress { }
        $streams = Get-AllOutput { Write-SwProgress -Activity 'A' -Status 'S' -PercentComplete 10 }
        $streams.Count | Should -Be 0
        Should -Invoke -CommandName Write-Progress -Times 0 -Exactly
        Should -Invoke -CommandName Write-Host -Times 0 -Exactly
    }

    It 'LG-38 accepts and ignores percent, current, total and width' {
        { Write-SwProgress -Activity 'A' -PercentComplete -1 -Current 0 -Total 0 -Width 30 } | Should -Not -Throw
        { Write-SwProgress -Activity 'A' -PercentComplete 100 -Current 5 -Total 5 -Width 1 } | Should -Not -Throw
        $script:Calls.Count | Should -Be 2
        $script:Calls[0].Message | Should -BeExactly $script:Calls[1].Message
    }

    It 'S-3 throws for no activity, status or message' -ForEach $script:HostileCases {
        foreach ($item in $Texts) {
            $text = $item.Text
            $failure = $null
            try { Write-SwProgress -Activity $text -Status $text -Message $text } catch { $failure = $_ }
            ($null -eq $failure) | Should -BeTrue -Because "Write-SwProgress with $($item.Label) threw: $failure"
        }
    }
}

# ============================================================================
# Initialize-SwSpinner
# ============================================================================

Describe 'Initialize-SwSpinner' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Initialize-SwSpinner', 'Stop-SwSpinner', 'Start-SwSpinner'
    }
    AfterEach { Stop-Case }

    It 'LG-40 defines the type Sweepr.SwSpinner and does nothing when it is there already' {
        Initialize-SwSpinner
        ($null -ne ('Sweepr.SwSpinner' -as [type])) | Should -BeTrue
        Mock Add-Type { }
        { Initialize-SwSpinner } | Should -Not -Throw
        Should -Invoke -CommandName Add-Type -Times 0 -Exactly
    }

    It 'LG-40 can be called any number of times without the error that the type exists' {
        { Initialize-SwSpinner; Initialize-SwSpinner; Initialize-SwSpinner } | Should -Not -Throw
    }

    It 'LG-40 compiles only on the first use: not while loading, not in Stop-SwSpinner, not in a disabled or non-interactive Start-SwSpinner (fresh process)' {
        $code = @"
`$ErrorActionPreference = 'Stop'
. $(ConvertTo-TestLiteral $script:LogScript)
'after load: ' + [bool]('Sweepr.SwSpinner' -as [type])
Stop-SwSpinner
'after stop: ' + [bool]('Sweepr.SwSpinner' -as [type])
`$script:SpinnerDisabled = `$true
Start-SwSpinner -Message 'x'
'after disabled start: ' + [bool]('Sweepr.SwSpinner' -as [type])
`$env:TERM = 'dumb'
`$script:SpinnerDisabled = `$false
Start-SwSpinner -Message 'x'
Update-SwSpinner -Message 'x'
'after dumb start: ' + [bool]('Sweepr.SwSpinner' -as [type])
Initialize-SwSpinner
'after initialize: ' + [bool]('Sweepr.SwSpinner' -as [type])
Initialize-SwSpinner
'after second initialize: ' + [bool]('Sweepr.SwSpinner' -as [type])
[Sweepr.SwSpinner]::Stop()
'done'
"@
        $result = Invoke-ChildPowerShell -Script $code -RemoveEnvironment @('SWEEPR_DEBUG')
        $lines = @($result.Out -split "`r?`n" | Where-Object { $_ })
        $lines | Should -Contain 'after load: False'
        $lines | Should -Contain 'after stop: False'
        $lines | Should -Contain 'after disabled start: False'
        $lines | Should -Contain 'after dumb start: False'
        $lines | Should -Contain 'after initialize: True'
        $lines | Should -Contain 'after second initialize: True'
        $lines | Should -Contain 'done'
        (Get-ChildStderr $result.Err) | Should -BeNullOrEmpty
        $result.ExitCode | Should -Be 0
    }
}

# ============================================================================
# The native class
# ============================================================================

Describe 'Sweepr.SwSpinner' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Initialize-SwSpinner'
        Use-SpinnerType
        Use-FakeConsole
    }
    AfterEach { Restore-FakeConsole; Stop-Case }

    It 'LG-39 is a public static class of the namespace Sweepr with exactly the members Start, Stop and Fit' {
        $type = [Sweepr.SwSpinner]
        $type.Namespace | Should -BeExactly 'Sweepr'
        $type.IsPublic | Should -BeTrue
        ($type.IsAbstract -and $type.IsSealed) | Should -BeTrue -Because 'a static class is abstract and sealed'
        $flags = [System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::Static -bor [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::DeclaredOnly
        $members = @($type.GetMembers($flags) | Where-Object { $_.MemberType -ne [System.Reflection.MemberTypes]::NestedType } | ForEach-Object { $_.Name } | Sort-Object -Unique)
        ($members -join ',') | Should -BeExactly 'Fit,Start,Stop'
        $type.GetMethod('Fit').ReturnType | Should -Be ([string])
        @($type.GetMethod('Fit').GetParameters() | ForEach-Object { $_.ParameterType.Name }) -join ',' | Should -BeExactly 'String,Int32'
        @($type.GetMethod('Start').GetParameters() | ForEach-Object { $_.ParameterType.Name }) -join ',' | Should -BeExactly 'String'
        @($type.GetMethod('Stop').GetParameters()).Count | Should -Be 0
    }

    It 'LG-39 fits <Label>' -ForEach $script:FitCases {
        [Sweepr.SwSpinner]::Fit($Value, $Cells) | Should -BeExactly $Expected
    }

    It 'LG-39 counts the code point U+<Hex> as <Cells> cell(s)' -ForEach $script:WidthCases {
        $element = [char]::ConvertFromUtf32($CodePoint)
        $probe = [Sweepr.SwSpinner]::Fit($element + 'a', 1)
        if ($Cells -eq 0) { $probe | Should -BeExactly ($element + 'a') }
        elseif ($Cells -eq 1) { $probe | Should -BeExactly $element }
        else { $probe | Should -BeExactly '' }
    }

    It 'LG-39 gives the same result as the rules of the cell widths for random text and widths' {
        $random = New-Object System.Random 20261031
        $pool = @(0x41, 0x61, 0x20, 0x30, 0xE9, 0x4E2D, 0x6587, 0x3042, 0xAC00, 0xFF21, 0x1100, 0x301, 0x300, 0x200B, 0x200D, 0x01, 0x7F, 0x85, 0x303F, 0x2329, 0xFE10, 0xFFE0)
        for ($n = 0; $n -lt 300; $n++) {
            $builder = New-Object System.Text.StringBuilder
            $length = $random.Next(0, 12)
            for ($i = 0; $i -lt $length; $i++) {
                $pick = $random.Next(0, 26)
                if ($pick -lt $pool.Count) { [void]$builder.Append([char]$pool[$pick]) }
                elseif ($pick -eq 22) { [void]$builder.Append([char]::ConvertFromUtf32(0x1F600)) }
                elseif ($pick -eq 23) { [void]$builder.Append([char]::ConvertFromUtf32(0x20000)) }
                elseif ($pick -eq 24) { [void]$builder.Append([char]0xD800) }
                else { [void]$builder.Append([char]0xDC00) }
            }
            $text = $builder.ToString()
            $cells = $random.Next(-1, 14)
            [Sweepr.SwSpinner]::Fit($text, $cells) | Should -BeExactly (Get-RefFit $text $cells) -Because "sample $n, $cells cells"
        }
    }

    It 'LG-39 never throws in Fit, also for lone surrogates and control characters' {
        foreach ($text in @(([string][char]0xD800), ([string][char]0xDC00), ([string][char]0xDC00 + [char]0xD800), ([string][char]0), ([string][char]27 + '[31m'), ('x' * 100000))) {
            { [void][Sweepr.SwSpinner]::Fit($text, 10) } | Should -Not -Throw
        }
    }

    It 'LG-39 writes nothing when Stop follows Start at once' {
        $quiet = $false
        for ($attempt = 0; $attempt -lt 3 -and -not $quiet; $attempt++) {
            $script:OutWriter.GetStringBuilder().Clear() | Out-Null
            [Sweepr.SwSpinner]::Start('Scanning')
            [Sweepr.SwSpinner]::Stop()
            $quiet = ($script:OutWriter.ToString().Length -eq 0)
        }
        $quiet | Should -BeTrue -Because 'the first frame comes after 80 ms; only a slow host may need another attempt'
    }

    It 'LG-39 draws the braille frames in order from U+2816 at a tick of about 80 ms' {
        [Sweepr.SwSpinner]::Start('Scanning')
        [System.Threading.Thread]::Sleep(350)
        [Sweepr.SwSpinner]::Stop()
        $text = $script:OutWriter.ToString()
        $text.Contains($script:Glyphs[0]) | Should -BeTrue -Because 'U+2816 is drawn'
        $text.Contains($script:Glyphs[1]) | Should -BeTrue -Because 'U+2832 is drawn'
        $frames = Get-SpinnerFrames $text
        $frames.Count | Should -BeGreaterOrEqual 2
        $frames.Count | Should -BeLessOrEqual 7 -Because 'one frame every 80 ms in 350 ms'
        for ($i = 0; $i -lt $frames.Count; $i++) {
            $frames[$i].Glyph | Should -BeExactly $script:Glyphs[$i % 4] -Because "frame $i"
        }
    }

    It 'LG-39 keeps the tick of 80 ms: 7 to 12 frames in 800 ms' {
        [Sweepr.SwSpinner]::Start('Scanning')
        [System.Threading.Thread]::Sleep(800)
        [Sweepr.SwSpinner]::Stop()
        $frames = Get-SpinnerFrames $script:OutWriter.ToString()
        $frames.Count | Should -BeGreaterOrEqual 7 -Because 'a tick slower than about 115 ms'
        $frames.Count | Should -BeLessOrEqual 12 -Because 'a tick faster than about 65 ms'
    }

    It 'LG-39 draws no frame in the first 30 ms' {
        $quiet = $false
        for ($attempt = 0; $attempt -lt 3 -and -not $quiet; $attempt++) {
            $script:OutWriter.GetStringBuilder().Clear() | Out-Null
            [Sweepr.SwSpinner]::Start('Scanning')
            [System.Threading.Thread]::Sleep(30)
            [Sweepr.SwSpinner]::Stop()
            $quiet = ($script:OutWriter.ToString().Length -eq 0)
        }
        $quiet | Should -BeTrue -Because 'the first frame comes after 80 ms; only a slow host may need another attempt'
    }

    It 'LG-39 writes a frame as a carriage return, clear line, two spaces, blue glyph, reset, a space and the label' {
        [Sweepr.SwSpinner]::Start('Scanning')
        [System.Threading.Thread]::Sleep(250)
        [Sweepr.SwSpinner]::Stop()
        $text = $script:OutWriter.ToString()
        $text.StartsWith([string][char]13 + [char]27 + '[2K  ' + [char]27 + '[34m' + $script:Glyphs[0] + [char]27 + '[0m ') | Should -BeTrue
        Test-OnlyFramesAndClear $text | Should -BeTrue
        $frames = Get-SpinnerFrames $text
        $frames.Count | Should -BeGreaterThan 0
        Assert-FrameMessage $frames[0].Message 'Scanning'
    }

    It 'LG-39 fits a long label to the window width minus 5 cells, or to the width of 80 when it cannot be read' {
        $label = 'long ' * 60
        [Sweepr.SwSpinner]::Start($label)
        [System.Threading.Thread]::Sleep(250)
        [Sweepr.SwSpinner]::Stop()
        $frames = Get-SpinnerFrames $script:OutWriter.ToString()
        $frames.Count | Should -BeGreaterThan 0
        $readable = $true
        $width = 0
        try { $width = [int][Console]::WindowWidth } catch { $readable = $false }
        $length = $frames[0].Message.Length
        if (-not $readable) { $length | Should -Be 80 -Because 'the window width cannot be read' }
        elseif ($width -gt 5) { $length | Should -Be ($width - 5) -Because 'the window width is read at each frame' }
        else { $length | Should -BeIn @(1, 80) -Because 'a host that answers a width of 0 or less without an error: one cell or the fallback' }
        $length | Should -BeLessThan $label.Length
    }

    It 'LG-39 clears the line when Stop ends an animation that drew a frame, and writes nothing more' {
        [Sweepr.SwSpinner]::Start('Scanning')
        [System.Threading.Thread]::Sleep(250)
        [Sweepr.SwSpinner]::Stop()
        $text = $script:OutWriter.ToString()
        $text.EndsWith([string][char]13 + [char]27 + '[2K') | Should -BeTrue
        [System.Threading.Thread]::Sleep(200)
        $script:OutWriter.ToString() | Should -BeExactly $text
    }

    It 'LG-39 writes nothing and does not throw for a repeated Stop and for a Stop without Start' {
        { [Sweepr.SwSpinner]::Stop() } | Should -Not -Throw
        $script:OutWriter.ToString() | Should -BeExactly ''
        [Sweepr.SwSpinner]::Start('Scanning')
        [System.Threading.Thread]::Sleep(200)
        [Sweepr.SwSpinner]::Stop()
        $text = $script:OutWriter.ToString()
        { [Sweepr.SwSpinner]::Stop(); [Sweepr.SwSpinner]::Stop() } | Should -Not -Throw
        $script:OutWriter.ToString() | Should -BeExactly $text
    }

    It 'LG-39 writes nothing after Stop has returned, in repeated runs' {
        for ($run = 0; $run -lt 8; $run++) {
            $script:OutWriter.GetStringBuilder().Clear() | Out-Null
            [Sweepr.SwSpinner]::Start('Run ' + $run)
            [System.Threading.Thread]::Sleep(85 + 10 * $run)
            [Sweepr.SwSpinner]::Stop()
            $length = $script:OutWriter.ToString().Length
            [System.Threading.Thread]::Sleep(110)
            $script:OutWriter.ToString().Length | Should -Be $length -Because "run $run wrote after Stop"
        }
    }

    It 'LG-39 writes nothing after Stop has returned, also when the writer is slow and a frame is being written' {
        $slow = New-Object SwTestSlowWriter
        $slow.DelayMs = 100
        [Console]::SetOut([System.IO.TextWriter]::Synchronized($slow))
        for ($run = 0; $run -lt 3; $run++) {
            $slow.GetStringBuilder().Clear() | Out-Null
            [Sweepr.SwSpinner]::Start('Slow ' + $run)
            [System.Threading.Thread]::Sleep(120 + 40 * $run)
            [Sweepr.SwSpinner]::Stop()
            $length = $slow.ToString().Length
            [System.Threading.Thread]::Sleep(300)
            $slow.ToString().Length | Should -Be $length -Because "run $run wrote after Stop"
        }
    }

    It 'LG-39 only replaces the label when Start is called while the animation runs: the frames go on in order' {
        [Sweepr.SwSpinner]::Start('One')
        [System.Threading.Thread]::Sleep(200)
        [Sweepr.SwSpinner]::Start('Two')
        [System.Threading.Thread]::Sleep(250)
        [Sweepr.SwSpinner]::Stop()
        $frames = Get-SpinnerFrames $script:OutWriter.ToString()
        $frames.Count | Should -BeGreaterOrEqual 3
        for ($i = 0; $i -lt $frames.Count; $i++) {
            $frames[$i].Glyph | Should -BeExactly $script:Glyphs[$i % 4] -Because "frame $i continues the sequence"
        }
        $frames[0].Message[0] | Should -BeExactly 'O'
        $frames[$frames.Count - 1].Message[0] | Should -BeExactly 'T'
    }

    It 'LG-39 survives many label changes while it runs and writes nothing after Stop' {
        [Sweepr.SwSpinner]::Start('first')
        for ($i = 0; $i -lt 300; $i++) { [Sweepr.SwSpinner]::Start('label ' + $i) }
        [System.Threading.Thread]::Sleep(120)
        [Sweepr.SwSpinner]::Stop()
        $length = $script:OutWriter.ToString().Length
        [System.Threading.Thread]::Sleep(150)
        $script:OutWriter.ToString().Length | Should -Be $length
        Test-OnlyFramesAndClear $script:OutWriter.ToString() | Should -BeTrue
    }

    It 'LG-39 swallows a writer that fails and does not end the process (fresh process)' {
        $code = @"
`$ErrorActionPreference = 'Stop'
. $(ConvertTo-TestLiteral $script:LogScript)
Initialize-SwSpinner
[Sweepr.SwSpinner]::Stop()
`$broken = New-Object System.IO.StringWriter
`$broken.Dispose()
[Console]::SetOut(`$broken)
[Sweepr.SwSpinner]::Start('Scanning')
[System.Threading.Thread]::Sleep(300)
[Sweepr.SwSpinner]::Stop()
[System.Threading.Thread]::Sleep(150)
[Console]::Error.WriteLine('alive')
"@
        $result = Invoke-ChildPowerShell -Script $code -RemoveEnvironment @('SWEEPR_DEBUG')
        $result.Err | Should -Match 'alive'
        $result.ExitCode | Should -Be 0
    }

    It 'LG-39 [W] writes the Braille characters to the standard output handle of a real console buffer and keeps the code page' {
        $script:OnWindows | Should -BeTrue -Because 'the console API exists only on Windows'
        $resultFile = P $script:Work 'console-result.txt'
        $csharp = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class SwTestConsole {
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool AllocConsole();
    [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GetStdHandle(int id);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetStdHandle(int id, IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr CreateConsoleScreenBuffer(uint access, uint share, IntPtr attributes, uint flags, IntPtr data);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool ReadConsoleOutputCharacterW(IntPtr handle, StringBuilder buffer, uint length, uint coordinate, out uint read);
    [DllImport("kernel32.dll")] public static extern uint GetConsoleOutputCP();
}
'@
        $template = @'
$ErrorActionPreference = 'Stop'
$resultFile = __RESULT__
try {
    Add-Type -TypeDefinition __CSHARP__
    [void][SwTestConsole]::AllocConsole()
    $original = [SwTestConsole]::GetStdHandle(-11)
    $buffer = [SwTestConsole]::CreateConsoleScreenBuffer([uint32]3221225472, [uint32]3, [IntPtr]::Zero, [uint32]1, [IntPtr]::Zero)
    if ($buffer -eq [IntPtr]::Zero -or $buffer -eq [IntPtr](-1)) { [System.IO.File]::WriteAllText($resultFile, 'skip: no console screen buffer'); return }
    $codePage = [SwTestConsole]::GetConsoleOutputCP()
    [void][SwTestConsole]::SetStdHandle(-11, $buffer)
    . __LOG__
    Initialize-SwSpinner
    [Sweepr.SwSpinner]::Start('Scanning')
    [System.Threading.Thread]::Sleep(450)
    [Sweepr.SwSpinner]::Stop()
    $text = New-Object System.Text.StringBuilder 400
    $read = [uint32]0
    [void][SwTestConsole]::ReadConsoleOutputCharacterW($buffer, $text, [uint32]400, [uint32]0, [ref]$read)
    [void][SwTestConsole]::SetStdHandle(-11, $original)
    $found = $false
    foreach ($char in $text.ToString().ToCharArray()) { if ([int]$char -in 0x2816, 0x2832, 0x2834, 0x2826) { $found = $true } }
    $after = [SwTestConsole]::GetConsoleOutputCP()
    [System.IO.File]::WriteAllText($resultFile, ('found=' + $found + ';codepage-kept=' + ($codePage -eq $after)))
}
catch { [System.IO.File]::WriteAllText($resultFile, ('error: ' + $_.Exception.Message)) }
'@
        $code = $template.Replace('__RESULT__', (ConvertTo-TestLiteral $resultFile)).Replace('__CSHARP__', (ConvertTo-TestLiteral $csharp)).Replace('__LOG__', (ConvertTo-TestLiteral $script:LogScript))
        $null = Invoke-ChildPowerShell -Script $code -RemoveEnvironment @('SWEEPR_DEBUG')
        [System.IO.File]::Exists($resultFile) | Should -BeTrue -Because 'the child wrote its result'
        $result = [System.IO.File]::ReadAllText($resultFile)
        if ($result.StartsWith('skip:')) { Set-ItResult -Skipped -Because $result; return }
        $result | Should -BeExactly 'found=True;codepage-kept=True'
    }
}
