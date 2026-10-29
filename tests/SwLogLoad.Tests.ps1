# Sweepr - tests for the load contract, the interface and the transition names of lib\core\log.ps1:
# loading, repeated loading, the log folder, strict mode and the error preference, the source rules,
# the functions and parameters, and the forwarding functions under the old names.
#
# The rule numbers in the test names (LG- and S-) number the rules and the safety invariants of the
# module's behavior; each rule and invariant has at least one test.
#
# Interface pinned here (new names; each old name stays as a forwarding function, not an alias):
#   Write-SwOperation, ConvertTo-SwLogValue, Add-SwOperationText, Move-SwOperationLogAside
#   Write-SwInfo, Write-SwSuccess, Write-SwWarning, Write-SwError, Write-SwDryRun, Write-SwDebug
#   Write-SwDiagnosticLine, Test-SwOutputRedirected, Enable-SwDebugMode, Start-SwDebugSession,
#   Complete-SwDebugSession, Start-SwSection, Stop-SwSection, Set-SwSectionActivity,
#   Test-SwInteractiveOutput, Initialize-SwSpinner, Start-SwSpinner, Update-SwSpinner, Stop-SwSpinner,
#   Write-SwProgress
# Script variables that callers read or replace: SWEEPR_LOG_LOADED, SweeprOperationsLogFile,
# SweeprOperationsLogMaxBytes, SweeprOperationsLogStarted, SweeprDebugLogFile, LogConfig, CurrentSection,
# SectionCollector, SpinnerDisabled.
#
# Platform notes:
#   - Paths are built from $TestDrive. Expected and actual paths are compared with both separators
#     folded and without case, so the tests run on Windows and on Linux.
#   - Loading tests that need a clean process run a child PowerShell. A child never writes outside
#     $TestDrive and the data folder of a child is a folder of the test drive.
#   - Tests marked [W] describe a Windows fact and are meant to fail on Linux where it does not hold.
#   - Nothing real is touched: no registry, no network, no real operations.log.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    # Old name, new name, how to call the old name once, and the parameters the new function must get.
    $script:Forwarders = @(
        @{ Old = 'Write-SweeprOperation'; New = 'Write-SwOperation'; Pass = $false
            Invoke = { Write-SweeprOperation -Action 'REMOVED' -Path 'Example-Path' -Detail 'Example-Detail' }
            Filter = { $Action -eq 'REMOVED' -and $Path -eq 'Example-Path' -and $Detail -eq 'Example-Detail' } }
        @{ Old = 'ConvertTo-SweeprLogValue'; New = 'ConvertTo-SwLogValue'; Pass = $true
            Invoke = { ConvertTo-SweeprLogValue -Value 'Example-Value' }
            Filter = { $Value -eq 'Example-Value' } }
        @{ Old = 'Add-SweeprOperationText'; New = 'Add-SwOperationText'; Pass = $false
            Invoke = { Add-SweeprOperationText -File 'Example-File' -Text 'Example-Text' }
            Filter = { $File -eq 'Example-File' -and $Text -eq 'Example-Text' } }
        @{ Old = 'Write-Info'; New = 'Write-SwInfo'; Pass = $false
            Invoke = { Write-Info -Message 'Example-Message' }
            Filter = { $Message -eq 'Example-Message' } }
        @{ Old = 'Write-Success'; New = 'Write-SwSuccess'; Pass = $false
            Invoke = { Write-Success -Message 'Example-Message' }
            Filter = { $Message -eq 'Example-Message' } }
        @{ Old = 'Write-SweeprWarning'; New = 'Write-SwWarning'; Pass = $false
            Invoke = { Write-SweeprWarning -Message 'Example-Message' }
            Filter = { $Message -eq 'Example-Message' } }
        @{ Old = 'Write-SweeprError'; New = 'Write-SwError'; Pass = $false
            Invoke = { Write-SweeprError -Message 'Example-Message' }
            Filter = { $Message -eq 'Example-Message' } }
        @{ Old = 'Write-DryRun'; New = 'Write-SwDryRun'; Pass = $false
            Invoke = { Write-DryRun -Message 'Example-Message' }
            Filter = { $Message -eq 'Example-Message' } }
        @{ Old = 'Write-Debug'; New = 'Write-SwDebug'; Pass = $false
            Invoke = { Write-Debug -Message 'Example-Message' }
            Filter = { $Message -eq 'Example-Message' } }
        @{ Old = 'Start-Section'; New = 'Start-SwSection'; Pass = $false
            Invoke = { Start-Section -Title 'Example-Title' }
            Filter = { $Title -eq 'Example-Title' } }
        @{ Old = 'Stop-Section'; New = 'Stop-SwSection'; Pass = $false
            Invoke = { Stop-Section }
            Filter = { $true } }
        @{ Old = 'Set-SectionActivity'; New = 'Set-SwSectionActivity'; Pass = $false
            Invoke = { Set-SectionActivity }
            Filter = { $true } }
        @{ Old = 'Test-SweeprInteractiveOutput'; New = 'Test-SwInteractiveOutput'; Pass = $true
            Invoke = { Test-SweeprInteractiveOutput }
            Filter = { $true } }
        @{ Old = 'Initialize-SweeprSpinner'; New = 'Initialize-SwSpinner'; Pass = $false
            Invoke = { Initialize-SweeprSpinner }
            Filter = { $true } }
        @{ Old = 'Start-Spinner'; New = 'Start-SwSpinner'; Pass = $false
            Invoke = { Start-Spinner -Message 'Example-Message' }
            Filter = { $Message -eq 'Example-Message' } }
        @{ Old = 'Update-Spinner'; New = 'Update-SwSpinner'; Pass = $false
            Invoke = { Update-Spinner -Message 'Example-Message' }
            Filter = { $Message -eq 'Example-Message' } }
        @{ Old = 'Stop-Spinner'; New = 'Stop-SwSpinner'; Pass = $false
            Invoke = { Stop-Spinner }
            Filter = { $true } }
        @{ Old = 'Write-Progress'; New = 'Write-SwProgress'; Pass = $false
            Invoke = { Write-Progress -Activity 'Example-Activity' -Status 'Example-Status' -PercentComplete 50 -Completed -Current 3 -Total 9 -Message 'Example-Message' -Width 12 }
            Filter = { $Activity -eq 'Example-Activity' -and $Status -eq 'Example-Status' -and $PercentComplete -eq 50 -and $Completed -and $Current -eq 3 -and $Total -eq 9 -and $Message -eq 'Example-Message' -and $Width -eq 12 } }
        @{ Old = 'Enable-DebugMode'; New = 'Enable-SwDebugMode'; Pass = $false
            Invoke = { Enable-DebugMode }
            Filter = { $true } }
        @{ Old = 'Start-SweeprDebugSession'; New = 'Start-SwDebugSession'; Pass = $false
            Invoke = { Start-SweeprDebugSession -Header @('Example-Header') }
            Filter = { @($Header).Count -eq 1 -and $Header[0] -eq 'Example-Header' } }
        @{ Old = 'Complete-SweeprDebugSession'; New = 'Complete-SwDebugSession'; Pass = $false
            Invoke = { Complete-SweeprDebugSession }
            Filter = { $true } }
    )

    # The new functions with the names of their parameters; Position0 is the parameter at position 0.
    $script:Interface = @(
        @{ Name = 'Write-SwOperation'; Parameters = @('Action', 'Path', 'Detail'); Positions = @('Action', 'Path', 'Detail') }
        @{ Name = 'ConvertTo-SwLogValue'; Parameters = @('Value'); Positions = @('Value') }
        @{ Name = 'Add-SwOperationText'; Parameters = @('File', 'Text'); Positions = @() }
        @{ Name = 'Move-SwOperationLogAside'; Parameters = @('File'); Positions = @() }
        @{ Name = 'Write-SwInfo'; Parameters = @('Message'); Positions = @('Message') }
        @{ Name = 'Write-SwSuccess'; Parameters = @('Message'); Positions = @('Message') }
        @{ Name = 'Write-SwWarning'; Parameters = @('Message'); Positions = @('Message') }
        @{ Name = 'Write-SwError'; Parameters = @('Message'); Positions = @('Message') }
        @{ Name = 'Write-SwDryRun'; Parameters = @('Message'); Positions = @('Message') }
        @{ Name = 'Write-SwDebug'; Parameters = @('Message'); Positions = @('Message') }
        @{ Name = 'Write-SwDiagnosticLine'; Parameters = @('Message'); Positions = @() }
        @{ Name = 'Test-SwOutputRedirected'; Parameters = @(); Positions = @() }
        @{ Name = 'Enable-SwDebugMode'; Parameters = @(); Positions = @() }
        @{ Name = 'Start-SwDebugSession'; Parameters = @('Header'); Positions = @() }
        @{ Name = 'Complete-SwDebugSession'; Parameters = @(); Positions = @() }
        @{ Name = 'Start-SwSection'; Parameters = @('Title'); Positions = @('Title') }
        @{ Name = 'Stop-SwSection'; Parameters = @(); Positions = @() }
        @{ Name = 'Set-SwSectionActivity'; Parameters = @(); Positions = @() }
        @{ Name = 'Test-SwInteractiveOutput'; Parameters = @(); Positions = @() }
        @{ Name = 'Initialize-SwSpinner'; Parameters = @(); Positions = @() }
        @{ Name = 'Start-SwSpinner'; Parameters = @('Message'); Positions = @('Message') }
        @{ Name = 'Update-SwSpinner'; Parameters = @('Message'); Positions = @('Message') }
        @{ Name = 'Stop-SwSpinner'; Parameters = @(); Positions = @() }
        @{ Name = 'Write-SwProgress'; Parameters = @('Activity', 'Status', 'PercentComplete', 'Completed', 'Current', 'Total', 'Message', 'Width'); Positions = @() }
    )

    # Parameter, type and default text (empty: no default) that the interface fixes.
    $script:ParameterFacts = @(
        @{ Name = 'Write-SwOperation'; Parameter = 'Action'; Type = 'System.String'; Default = '' }
        @{ Name = 'Write-SwOperation'; Parameter = 'Path'; Type = 'System.String'; Default = '' }
        @{ Name = 'Write-SwOperation'; Parameter = 'Detail'; Type = 'System.String'; Default = "''" }
        @{ Name = 'Add-SwOperationText'; Parameter = 'File'; Type = 'System.String'; Default = '' }
        @{ Name = 'Add-SwOperationText'; Parameter = 'Text'; Type = 'System.String'; Default = '' }
        @{ Name = 'Move-SwOperationLogAside'; Parameter = 'File'; Type = 'System.String'; Default = '' }
        @{ Name = 'Write-SwInfo'; Parameter = 'Message'; Type = 'System.String'; Default = '' }
        @{ Name = 'Write-SwDiagnosticLine'; Parameter = 'Message'; Type = 'System.String'; Default = "''" }
        @{ Name = 'Start-SwDebugSession'; Parameter = 'Header'; Type = 'System.String[]'; Default = '' }
        @{ Name = 'Start-SwSection'; Parameter = 'Title'; Type = 'System.String'; Default = '' }
        @{ Name = 'Write-SwProgress'; Parameter = 'Status'; Type = 'System.String'; Default = "''" }
        @{ Name = 'Write-SwProgress'; Parameter = 'PercentComplete'; Type = 'System.Int32'; Default = '-1' }
        @{ Name = 'Write-SwProgress'; Parameter = 'Completed'; Type = 'System.Management.Automation.SwitchParameter'; Default = '' }
        @{ Name = 'Write-SwProgress'; Parameter = 'Current'; Type = 'System.Int32'; Default = '0' }
        @{ Name = 'Write-SwProgress'; Parameter = 'Total'; Type = 'System.Int32'; Default = '0' }
        @{ Name = 'Write-SwProgress'; Parameter = 'Message'; Type = 'System.String'; Default = "''" }
        @{ Name = 'Write-SwProgress'; Parameter = 'Width'; Type = 'System.Int32'; Default = '30' }
        @{ Name = 'Write-SwProgress'; Parameter = 'Activity'; Type = 'System.String'; Default = '*' }
    )

    # LG-1: values of $script:Config that must not make loading fail. Usable: the folder comes from it.
    $script:ConfigCases = @(
        @{ Label = 'a null Config'; Make = { $null }; Usable = $false }
        @{ Label = 'a text'; Make = { 'C:\not\a\table' }; Usable = $false }
        @{ Label = 'a number'; Make = { 42 }; Usable = $false }
        @{ Label = 'an array'; Make = { @('a', 'b') }; Usable = $false }
        @{ Label = 'an empty table'; Make = { @{} }; Usable = $false }
        @{ Label = 'an empty ConfigPath'; Make = { @{ ConfigPath = '' } }; Usable = $false }
        @{ Label = 'a null ConfigPath'; Make = { @{ ConfigPath = $null } }; Usable = $false }
        @{ Label = 'an object that is not a dictionary'; Make = { [pscustomobject]@{ ConfigPath = 'C:\x\config' } }; Usable = $false }
        @{ Label = 'a ConfigPath with a NUL character'; Make = { @{ ConfigPath = ('C:\x' + [char]0 + 'y') } }; Usable = $null }
        @{ Label = 'a ConfigPath with characters that are not allowed in names'; Make = { @{ ConfigPath = 'C:\a|b<c>d*e?f"g' } }; Usable = $null }
        @{ Label = 'a ConfigPath on a drive that does not exist'; Make = { @{ ConfigPath = 'Q:\nodrive\config' } }; Usable = $null }
        @{ Label = 'an ordered dictionary'; Make = { [ordered]@{ ConfigPath = 'C:\x\config' } }; Usable = $true }
        @{ Label = 'a hashtable with a ConfigPath'; Make = { @{ ConfigPath = 'C:\x\config' } }; Usable = $true }
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

    # ---- helpers for the load tests ---------------------------------------------------------------

    function script:Get-ParamSignature([string]$Name) {
        $command = Get-Command -Name $Name -CommandType Function -ErrorAction Stop
        $common = [System.Management.Automation.Cmdlet]::CommonParameters + [System.Management.Automation.Cmdlet]::OptionalCommonParameters
        $ast = $command.ScriptBlock.Ast
        $declared = @()
        if ($ast -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            if ($ast.Parameters) { $declared = @($ast.Parameters) }
            elseif ($ast.Body.ParamBlock) { $declared = @($ast.Body.ParamBlock.Parameters) }
        }
        elseif ($ast.ParamBlock) { $declared = @($ast.ParamBlock.Parameters) }
        $lines = @()
        foreach ($parameter in $declared) {
            $paramName = $parameter.Name.VariablePath.UserPath
            if ($paramName -in $common) { continue }
            $meta = $command.Parameters[$paramName]
            $attribute = $meta.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | Select-Object -First 1
            $position = 'none'
            $mandatory = $false
            if ($null -ne $attribute) { $position = [string]$attribute.Position; $mandatory = [bool]$attribute.Mandatory }
            $default = ''
            if ($null -ne $parameter.DefaultValue) { $default = $parameter.DefaultValue.Extent.Text }
            $lines += ('{0}|{1}|pos={2}|mandatory={3}|default={4}' -f $paramName, $meta.ParameterType.FullName, $position, $mandatory, $default)
        }
        $lines
    }
    function script:Get-ParameterFact([string]$Name, [string]$Parameter) {
        $command = Get-Command -Name $Name -CommandType Function -ErrorAction Stop
        $meta = $command.Parameters[$Parameter]
        if ($null -eq $meta) { throw "$Name has no parameter $Parameter" }
        $ast = $command.ScriptBlock.Ast
        $declared = @()
        if ($ast -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            if ($ast.Parameters) { $declared = @($ast.Parameters) }
            elseif ($ast.Body.ParamBlock) { $declared = @($ast.Body.ParamBlock.Parameters) }
        }
        elseif ($ast.ParamBlock) { $declared = @($ast.ParamBlock.Parameters) }
        $default = ''
        foreach ($parameterAst in $declared) {
            if ($parameterAst.Name.VariablePath.UserPath -eq $Parameter -and $null -ne $parameterAst.DefaultValue) { $default = $parameterAst.DefaultValue.Extent.Text }
        }
        $attribute = $meta.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | Select-Object -First 1
        $position = -1
        if ($null -ne $attribute -and $attribute.Position -ge 0) { $position = $attribute.Position }
        @{ Type = $meta.ParameterType.FullName; Default = $default; Position = $position }
    }

    # The profile folder of a test: a fake one in the work folder.
    function script:New-FakeProfile {
        New-Dir (P $script:Work 'profile')
    }
    # What the three path variables should be for a data folder, in the comparison form.
    function script:Get-ExpectedLogPath([string]$Folder) { Get-Cmp (P $Folder 'operations.log') }
    function script:Get-ExpectedDebugPath([string]$Folder) { Get-Cmp (P $Folder 'sweepr_debug_session.log') }

    # The syntax tree and tokens of the module, parsed once.
    function script:Get-CSharpSources($Ast) {
        @($Ast.FindAll({ param($n)
                    ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and
                    $n.Value -match 'class\s+SwSpinner'
                }, $true) | ForEach-Object { $_.Value })
    }

    # What the whole file changes in the process, put back after the last test.
    $script:RootState = Save-State
    $script:RootEnv = Save-Env $script:EnvNames
    . $script:LogScript
}

AfterAll {
    Restore-State $script:RootState
    Restore-Env $script:RootEnv
}

# ============================================================================
# Loading
# ============================================================================

Describe 'Loading log.ps1' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Write-SwOperation', 'Write-SwInfo', 'Start-SwSpinner'
    }
    AfterEach { Stop-Case }

    It 'LG-1 loads in a fresh process after nothing else, without output or error, and defines the new functions' {
        $data = P $script:Work 'child-data'
        $probe = New-Dir (P $script:Work 'probe')
        $code = @"
`$ErrorActionPreference = 'Stop'
. $(ConvertTo-TestLiteral $script:LogScript)
foreach (`$name in 'Write-SwOperation', 'Write-SwInfo', 'Start-SwSection', 'Start-SwSpinner', 'Write-Info', 'Write-Debug') {
    if (-not (Get-Command `$name -CommandType Function -ErrorAction SilentlyContinue)) { 'missing:' + `$name }
}
'done'
"@
        $result = Invoke-ChildPowerShell -Script $code -WorkingDirectory $probe -Environment @{ SWEEPR_DATA_DIR = $data } -RemoveEnvironment @('SWEEPR_DEBUG', 'SWEEPR_NO_OPLOG')
        (Get-ChildStderr $result.Err) | Should -BeNullOrEmpty
        $result.Out.Trim() | Should -BeExactly 'done'
        $result.ExitCode | Should -Be 0
        [System.IO.Directory]::Exists($data) | Should -BeFalse
        (Get-Listing $probe) -join '|' | Should -BeExactly ''
    }

    It 'LG-1 loads with an empty USERPROFILE and writes nothing to the working folder or the home folder' {
        $homeDir = New-Dir (P $script:Work 'home')
        $probe = New-Dir (P $script:Work 'probe')
        $code = @"
`$ErrorActionPreference = 'Stop'
. $(ConvertTo-TestLiteral $script:LogScript)
'after'
"@
        $result = Invoke-ChildPowerShell -Script $code -WorkingDirectory $probe -Environment @{ HOME = $homeDir } -RemoveEnvironment @('USERPROFILE', 'SWEEPR_DATA_DIR', 'SWEEPR_DEBUG', 'SWEEPR_NO_OPLOG')
        (Get-ChildStderr $result.Err) | Should -BeNullOrEmpty
        $result.Out.Trim() | Should -BeExactly 'after'
        $result.ExitCode | Should -Be 0
        (Get-Listing $probe) -join '|' | Should -BeExactly ''
        @(Get-Listing $homeDir | Where-Object { $_ -match 'sweepr|operations|debug_session' }).Count | Should -Be 0 -Because 'the host may keep its own cache in the home folder, the module writes nothing there'
    }

    It 'LG-1 takes base.ps1 from the folder of log.ps1 and not from the working directory' {
        $root = P $script:Work 'fake-root'
        $core = New-Dir (P $root 'lib' 'core')
        foreach ($name in 'log.ps1', 'base.ps1') { [System.IO.File]::Copy((P $script:CoreDir $name), (P $core $name), $true) }
        $cwd = New-Dir (P $script:Work 'decoy-cwd')
        foreach ($name in 'base.ps1', 'log.ps1') { [System.IO.File]::WriteAllText((P $cwd $name), "throw 'a decoy from the working directory was loaded'") }
        $decoyLib = New-Dir (P $cwd 'lib' 'core')
        foreach ($name in 'base.ps1', 'log.ps1') { [System.IO.File]::WriteAllText((P $decoyLib $name), "throw 'a decoy from the working directory was loaded'") }
        $code = @"
`$ErrorActionPreference = 'Stop'
. $(ConvertTo-TestLiteral (P $core 'log.ps1'))
foreach (`$name in 'Write-SwOperation', 'Get-SwColor', 'Get-SwIcon', 'Write-SwInfo') {
    if (-not (Get-Command `$name -ErrorAction SilentlyContinue)) { 'missing:' + `$name }
}
'done'
"@
        $result = Invoke-ChildPowerShell -Script $code -WorkingDirectory $cwd -RemoveEnvironment @('SWEEPR_DEBUG')
        (Get-ChildStderr $result.Err) | Should -BeNullOrEmpty
        $result.Out.Trim() | Should -BeExactly 'done'
        $result.ExitCode | Should -Be 0
    }

    It 'LG-1 writes nothing, starts nothing and compiles nothing while loading, also when everything is evaluated again' {
        Mock Add-Type { }
        Mock Start-Process { }
        Mock Invoke-WebRequest { }
        Mock Invoke-RestMethod { }
        Mock New-Item { }
        Mock Out-File { }
        Mock Set-Content { }
        Mock Add-Content { }
        $before = Get-Listing $script:Work
        $script:SWEEPR_LOG_LOADED = $false
        $output = Get-AllOutput { . $script:LogScript }
        $output.Count | Should -Be 0
        $output = Get-AllOutput { . $script:LogScript }
        $output.Count | Should -Be 0
        foreach ($name in 'Add-Type', 'Start-Process', 'Invoke-WebRequest', 'Invoke-RestMethod', 'New-Item', 'Out-File', 'Set-Content', 'Add-Content') {
            Should -Invoke -CommandName $name -Times 0 -Exactly -Because "loading must not call $name"
        }
        (Get-Listing $script:Work) -join '|' | Should -BeExactly ($before -join '|')
        [System.IO.Directory]::Exists($script:Dir) | Should -BeFalse
    }

    It 'LG-1 does not throw for <Label>' -ForEach $script:ConfigCases {
        Set-Env 'USERPROFILE' (New-FakeProfile)
        $script:Config = & $Make
        $script:SWEEPR_LOG_LOADED = $false
        { . $script:LogScript } | Should -Not -Throw
        $script:SweeprOperationsLogFile | Should -BeOfType [string]
        $script:SweeprDebugLogFile | Should -BeOfType [string]
        $script:LogConfig | Should -BeOfType [hashtable]
    }

    It 'LG-1 does not throw when Config is removed and USERPROFILE is empty' {
        Remove-Variable -Name Config -Scope Script
        Set-Env 'USERPROFILE' $null
        $script:SWEEPR_LOG_LOADED = $false
        { . $script:LogScript } | Should -Not -Throw
    }

    It 'LG-1 [W] builds the path on a drive that does not exist without asking the drive' {
        $script:Config = @{ ConfigPath = 'Z:\nodrive\config' }
        $script:SWEEPR_LOG_LOADED = $false
        { . $script:LogScript } | Should -Not -Throw
        $script:SweeprOperationsLogFile | Should -BeExactly 'Z:\nodrive\config\operations.log'
        $script:SweeprDebugLogFile | Should -BeExactly 'Z:\nodrive\config\sweepr_debug_session.log'
    }
}

# ============================================================================
# Repeated loading and the starting state
# ============================================================================

Describe 'Loading log.ps1 again' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Write-SwOperation', 'Write-SwInfo', 'Start-SwSpinner'
    }
    AfterEach { Stop-Case }

    It 'LG-2 changes nothing on a second load: paths, marker, limit, debug state, section, collector and spinner switch' {
        $logConfig = @{ DebugEnabled = $true; LogFile = 'custom-debug.log' }
        $section = @{ Active = $true; Activity = $true; Name = 'Changed' }
        $collector = New-Object 'System.Collections.Generic.List[string]'
        $script:SweeprOperationsLogFile = 'custom-operations.log'
        $script:SweeprDebugLogFile = 'custom-debug-file.log'
        $script:SweeprOperationsLogStarted = $true
        $script:SweeprOperationsLogMaxBytes = 7
        $script:LogConfig = $logConfig
        $script:CurrentSection = $section
        $script:SectionCollector = $collector
        $script:SpinnerDisabled = $true
        $script:Config = @{ ConfigPath = (P $script:Work 'other' 'config') }
        . $script:LogScript
        $script:SweeprOperationsLogFile | Should -BeExactly 'custom-operations.log'
        $script:SweeprDebugLogFile | Should -BeExactly 'custom-debug-file.log'
        $script:SweeprOperationsLogStarted | Should -BeTrue
        $script:SweeprOperationsLogMaxBytes | Should -Be 7
        [object]::ReferenceEquals($script:LogConfig, $logConfig) | Should -BeTrue
        $script:LogConfig.DebugEnabled | Should -BeTrue
        $script:LogConfig.LogFile | Should -BeExactly 'custom-debug.log'
        [object]::ReferenceEquals($script:CurrentSection, $section) | Should -BeTrue
        $script:CurrentSection.Name | Should -BeExactly 'Changed'
        [object]::ReferenceEquals($script:SectionCollector, $collector) | Should -BeTrue
        $script:SpinnerDisabled | Should -BeTrue
        $script:SWEEPR_LOG_LOADED | Should -BeTrue
    }

    It 'LG-2 recomputes everything from the current Config and environment when the marker is $false' {
        $folder = P $script:Work 'again' 'config'
        $script:Config = @{ ConfigPath = $folder }
        Set-Env 'SWEEPR_DEBUG' '1'
        $script:SweeprOperationsLogFile = 'custom-operations.log'
        $script:SweeprOperationsLogStarted = $true
        $script:SweeprOperationsLogMaxBytes = 7
        $script:LogConfig = @{ DebugEnabled = $false; LogFile = 'custom-debug.log' }
        $script:CurrentSection = @{ Active = $true; Activity = $true; Name = 'Changed' }
        $script:SectionCollector = New-Object 'System.Collections.Generic.List[string]'
        $script:SpinnerDisabled = $true
        $script:SWEEPR_LOG_LOADED = $false
        . $script:LogScript
        (Get-Cmp $script:SweeprOperationsLogFile) | Should -BeExactly (Get-ExpectedLogPath $folder)
        (Get-Cmp $script:SweeprDebugLogFile) | Should -BeExactly (Get-ExpectedDebugPath $folder)
        $script:SweeprOperationsLogStarted | Should -BeFalse
        $script:SweeprOperationsLogMaxBytes | Should -Be 5242880
        $script:LogConfig.DebugEnabled | Should -BeTrue
        $script:LogConfig.LogFile | Should -BeExactly $script:SweeprDebugLogFile
        $script:CurrentSection.Active | Should -BeFalse
        $script:CurrentSection.Activity | Should -BeFalse
        $script:CurrentSection.Name | Should -BeExactly ''
        ($null -eq $script:SectionCollector) | Should -BeTrue -Because 'there is no collector until a caller sets one'
        $script:SpinnerDisabled | Should -BeFalse
        $script:SWEEPR_LOG_LOADED | Should -BeTrue
        [System.IO.Directory]::Exists($folder) | Should -BeFalse -Because 'loading creates no folder'
    }

    It 'LG-2 sets DebugEnabled to <Expected> and LogFile to <Label> for SWEEPR_DEBUG=<Value>' -ForEach @(
        @{ Value = '1'; Expected = $true; Label = 'the debug file' }
        @{ Value = '0'; Expected = $false; Label = 'null' }
        @{ Value = 'true'; Expected = $false; Label = 'null' }
        @{ Value = 'yes'; Expected = $false; Label = 'null' }
        @{ Value = '11'; Expected = $false; Label = 'null' }
        @{ Value = '1 '; Expected = $false; Label = 'null' }
        @{ Value = ''; Expected = $false; Label = 'null' }
    ) {
        $folder = P $script:Work 'dbg' 'config'
        $script:Config = @{ ConfigPath = $folder }
        Set-Env 'SWEEPR_DEBUG' $Value
        $script:SWEEPR_LOG_LOADED = $false
        . $script:LogScript
        $script:LogConfig.DebugEnabled | Should -Be $Expected
        if ($Expected) { (Get-Cmp $script:LogConfig.LogFile) | Should -BeExactly (Get-ExpectedDebugPath $folder) }
        else { $script:LogConfig.LogFile | Should -BeNullOrEmpty }
        [System.IO.File]::Exists($script:SweeprDebugLogFile) | Should -BeFalse -Because 'loading creates no debug file'
    }

    It 'LG-2 reads SWEEPR_DEBUG only while loading: a later change leaves debug mode as it is, also after a second load' {
        Assert-Defined 'Write-SwDebug', 'Write-SwDiagnosticLine'
        Mock Write-SwDiagnosticLine { }
        Set-Env 'SWEEPR_DEBUG' '1'
        . $script:LogScript
        $script:LogConfig.DebugEnabled | Should -BeFalse
        $script:LogConfig.LogFile | Should -BeNullOrEmpty
        Write-SwDebug 'quiet'
        Should -Invoke -CommandName Write-SwDiagnosticLine -Times 0 -Exactly
    }

    It 'LG-2 gives every variable of the interface a value after loading, readable under strict mode' {
        $script:SWEEPR_LOG_LOADED = $false
        . $script:LogScript
        foreach ($name in 'SWEEPR_LOG_LOADED', 'SweeprOperationsLogFile', 'SweeprOperationsLogMaxBytes', 'SweeprOperationsLogStarted',
            'SweeprDebugLogFile', 'LogConfig', 'CurrentSection', 'SectionCollector', 'SpinnerDisabled') {
            ($null -ne (Get-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue)) | Should -BeTrue -Because "$name exists after loading"
        }
        $script:SWEEPR_LOG_LOADED | Should -BeOfType [bool]
        $script:SweeprOperationsLogFile | Should -BeOfType [string]
        $script:SweeprOperationsLogMaxBytes | Should -Be 5242880
        $script:SweeprOperationsLogStarted | Should -BeOfType [bool]
        $script:SweeprOperationsLogStarted | Should -BeFalse
        $script:SweeprDebugLogFile | Should -BeOfType [string]
        ($null -eq $script:SectionCollector) | Should -BeTrue -Because 'there is no collector until a caller sets one'
        $script:SpinnerDisabled | Should -BeOfType [bool]
        $script:SpinnerDisabled | Should -BeFalse
    }

    It 'LG-2 gives LogConfig exactly the keys DebugEnabled and LogFile and CurrentSection exactly Active, Activity and Name' {
        $script:SWEEPR_LOG_LOADED = $false
        . $script:LogScript
        $script:LogConfig | Should -BeOfType [hashtable]
        (@($script:LogConfig.Keys | Sort-Object) -join ',') | Should -BeExactly 'DebugEnabled,LogFile'
        $script:LogConfig['DebugEnabled'] | Should -BeOfType [bool]
        $script:CurrentSection | Should -BeOfType [hashtable]
        (@($script:CurrentSection.Keys | Sort-Object) -join ',') | Should -BeExactly 'Active,Activity,Name'
        $script:CurrentSection['Active'] | Should -BeOfType [bool]
        $script:CurrentSection['Activity'] | Should -BeOfType [bool]
        $script:CurrentSection['Name'] | Should -BeOfType [string]
    }
}

# ============================================================================
# The folder
# ============================================================================

Describe 'The folder of the log files' {
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

    It 'LG-3 takes the folder from Config: <Label>' -ForEach ($script:ConfigCases | Where-Object { $_.Usable -eq $true }) {
        $script:Config = & $Make
        $script:SWEEPR_LOG_LOADED = $false
        . $script:LogScript
        (Get-Cmp $script:SweeprOperationsLogFile) | Should -BeExactly (Get-ExpectedLogPath 'C:\x\config')
        (Get-Cmp $script:SweeprDebugLogFile) | Should -BeExactly (Get-ExpectedDebugPath 'C:\x\config')
    }

    It 'LG-3 falls back to the profile folder plus .config\sweepr when Config is missing' {
        $profileDir = New-FakeProfile
        Set-Env 'USERPROFILE' $profileDir
        Remove-Variable -Name Config -Scope Script
        $script:SWEEPR_LOG_LOADED = $false
        . $script:LogScript
        $expected = P $profileDir '.config' 'sweepr'
        (Get-Cmp $script:SweeprOperationsLogFile) | Should -BeExactly (Get-ExpectedLogPath $expected)
        (Get-Cmp $script:SweeprDebugLogFile) | Should -BeExactly (Get-ExpectedDebugPath $expected)
        [System.IO.Directory]::Exists($expected) | Should -BeFalse -Because 'loading creates no folder'
    }

    It 'LG-3 falls back to the profile folder plus .config\sweepr when Config cannot be used: <Label>' -ForEach ($script:ConfigCases | Where-Object { $_.Usable -eq $false }) {
        $profileDir = New-FakeProfile
        Set-Env 'USERPROFILE' $profileDir
        $script:Config = & $Make
        $script:SWEEPR_LOG_LOADED = $false
        . $script:LogScript
        (Get-Cmp $script:SweeprOperationsLogFile) | Should -BeExactly (Get-ExpectedLogPath (P $profileDir '.config' 'sweepr'))
    }

    It 'LG-3 leaves all three paths empty, the debug file off and writes nothing when there is no Config and no USERPROFILE' {
        Set-Env 'USERPROFILE' $null
        Set-Env 'SWEEPR_DEBUG' '1'
        Remove-Variable -Name Config -Scope Script
        $script:SWEEPR_LOG_LOADED = $false
        . $script:LogScript
        $script:SweeprOperationsLogFile | Should -BeExactly ''
        $script:SweeprDebugLogFile | Should -BeExactly ''
        $script:LogConfig.LogFile | Should -BeNullOrEmpty
        Mock Add-SwOperationText { }
        { Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB' } | Should -Not -Throw
        Should -Invoke -CommandName Add-SwOperationText -Times 0 -Exactly
    }

    It 'LG-3 does not read SWEEPR_DATA_DIR itself: the folder comes from Config, or from the profile when there is no Config' {
        Set-Env 'SWEEPR_DATA_DIR' (P $script:Work 'from-environment')
        $folder = P $script:Work 'from-config' 'config'
        $script:Config = @{ ConfigPath = $folder }
        $script:SWEEPR_LOG_LOADED = $false
        . $script:LogScript
        (Get-Cmp $script:SweeprOperationsLogFile) | Should -BeExactly (Get-ExpectedLogPath $folder)
        $profileDir = New-FakeProfile
        Set-Env 'USERPROFILE' $profileDir
        Remove-Variable -Name Config -Scope Script
        $script:SWEEPR_LOG_LOADED = $false
        . $script:LogScript
        (Get-Cmp $script:SweeprOperationsLogFile) | Should -BeExactly (Get-ExpectedLogPath (P $profileDir '.config' 'sweepr'))
    }

    It 'LG-3 determines the folder once while loading: a later change of Config does not move the writer' {
        $folder = P $script:Work 'first' 'config'
        $script:Config = @{ ConfigPath = $folder }
        $script:SWEEPR_LOG_LOADED = $false
        . $script:LogScript
        $script:Config = @{ ConfigPath = (P $script:Work 'second' 'config') }
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail '1KB'
        [System.IO.File]::Exists((P $folder 'operations.log')) | Should -BeTrue
        [System.IO.Directory]::Exists((P $script:Work 'second')) | Should -BeFalse
    }
}

# ============================================================================
# Strict mode and error preference
# ============================================================================

Describe 'Strict mode and error preference after loading' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Write-SwOperation'
    }
    AfterEach { Stop-Case }

    It 'LG-4 sets strict mode and the error preference Stop after a first and after a second load in a fresh process' {
        $code = @"
`$ErrorActionPreference = 'Continue'
Set-StrictMode -Off
. $(ConvertTo-TestLiteral $script:LogScript)
'eap=' + `$ErrorActionPreference
try { `$null = `$undefinedVariableForTheTest; 'strict=off' } catch { 'strict=on' }
'marker=' + `$script:SWEEPR_LOG_LOADED
`$ErrorActionPreference = 'Continue'
Set-StrictMode -Off
. $(ConvertTo-TestLiteral $script:LogScript)
'eap2=' + `$ErrorActionPreference
try { `$null = `$undefinedVariableForTheTest; 'strict2=off' } catch { 'strict2=on' }
"@
        $result = Invoke-ChildPowerShell -Script $code -RemoveEnvironment @('SWEEPR_DEBUG')
        $lines = @($result.Out -split "`r?`n" | Where-Object { $_ })
        $lines | Should -Contain 'eap=Stop'
        $lines | Should -Contain 'strict=on'
        $lines | Should -Contain 'marker=True'
        $lines | Should -Contain 'eap2=Stop'
        $lines | Should -Contain 'strict2=on'
    }

    It 'LG-4 sets strict mode and the error preference again on a second load without the marker reset' {
        $ErrorActionPreference = 'Continue'
        Set-StrictMode -Off
        . $script:LogScript
        $ErrorActionPreference | Should -Be 'Stop'
        { $null = $undefinedVariableForTheTest } | Should -Throw
    }

    It 'LG-4 sets strict mode and the error preference when it evaluates everything again' {
        $ErrorActionPreference = 'Continue'
        Set-StrictMode -Off
        $script:SWEEPR_LOG_LOADED = $false
        . $script:LogScript
        $ErrorActionPreference | Should -Be 'Stop'
        { $null = $undefinedVariableForTheTest } | Should -Throw
    }
}

# ============================================================================
# Source rules
# ============================================================================

Describe 'Source rules of log.ps1' {
    BeforeAll {
        $script:SourceBytes = [System.IO.File]::ReadAllBytes($script:LogScript)
        $script:SourceTokens = $null
        $script:SourceErrors = $null
        $script:SourceAst = [System.Management.Automation.Language.Parser]::ParseFile($script:LogScript, [ref]$script:SourceTokens, [ref]$script:SourceErrors)
        function script:Get-CommandNames($Ast) {
            @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        }
        # The text of a function and of the functions of the same file that it calls, to a depth of three.
        function script:Get-FunctionText($Ast, [string]$Name) {
            $functions = @{}
            foreach ($node in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $functions[$node.Name] = $node }
            if (-not $functions.ContainsKey($Name)) { return '' }
            $seen = New-Object 'System.Collections.Generic.HashSet[string]'
            $level = @($Name)
            $text = New-Object System.Text.StringBuilder
            for ($depth = 0; $depth -lt 3 -and $level.Count -gt 0; $depth++) {
                $next = @()
                foreach ($item in $level) {
                    if (-not $seen.Add($item)) { continue }
                    [void]$text.AppendLine($functions[$item].Extent.Text)
                    $next += @(Get-CommandNames $functions[$item] | Where-Object { $functions.ContainsKey($_) })
                }
                $level = $next
            }
            $text.ToString()
        }
    }
    BeforeEach {
        # The rules below judge the module, so they need a module that defines its functions.
        Assert-Defined 'Write-SwOperation', 'Initialize-SwSpinner', 'Write-SwProgress'
    }

    It 'LG-1 is ASCII or UTF-8 with a byte order mark' {
        $bytes = $script:SourceBytes
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count
        ($nonAscii -eq 0 -or $hasBom) | Should -BeTrue
    }

    It 'LG-1 parses without errors' {
        @($script:SourceErrors).Count | Should -Be 0
    }

    It 'LG-1 uses no syntax that only PowerShell 7 reads' {
        $only7 = @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark')
        $found = @($script:SourceTokens | Where-Object { $_.Kind.ToString() -in $only7 } | ForEach-Object { "$($_.Kind) at line $($_.Extent.StartLineNumber)" })
        $found | Should -BeNullOrEmpty
        $nodes = @($script:SourceAst.FindAll({ param($n) $n.GetType().Name -in @('TernaryExpressionAst', 'PipelineChainAst', 'NullConditionalMemberExpressionAst') }, $true))
        $nodes.Count | Should -Be 0
    }

    It 'S-6 never evaluates text, starts a process or uses the network' {
        $names = @(Get-CommandNames $script:SourceAst)
        foreach ($forbidden in 'Invoke-Expression', 'iex', 'Start-Process', 'start', 'saps', 'Invoke-WebRequest', 'iwr', 'curl', 'wget', 'Invoke-RestMethod', 'irm', 'Invoke-Command', 'Start-Job') {
            $names | Should -Not -Contain $forbidden
        }
    }

    It 'S-6 uses no process, web or socket class' {
        $text = [System.IO.File]::ReadAllText($script:LogScript)
        $text | Should -Not -Match 'System\.Diagnostics\.Process|WebClient|HttpClient|System\.Net\.|WebRequest'
    }

    It 'S-6 formats with -f only when the format string is a literal' {
        $formats = @($script:SourceAst.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.BinaryExpressionAst] -and $n.Operator -eq [System.Management.Automation.Language.TokenKind]::Format
                }, $true))
        foreach ($node in $formats) {
            ($node.Left -is [System.Management.Automation.Language.StringConstantExpressionAst]) | Should -BeTrue -Because "the format string at line $($node.Extent.StartLineNumber) is not a literal"
        }
    }

    It 'LG-41 calls no built-in Write-Debug, Write-Progress, Write-Warning or Write-Error and no old name' {
        $names = @(Get-CommandNames $script:SourceAst)
        $old = @('Write-SweeprOperation', 'ConvertTo-SweeprLogValue', 'Add-SweeprOperationText', 'Write-Info', 'Write-Success', 'Write-SweeprWarning',
            'Write-SweeprError', 'Write-DryRun', 'Write-Debug', 'Start-Section', 'Stop-Section', 'Set-SectionActivity', 'Test-SweeprInteractiveOutput',
            'Initialize-SweeprSpinner', 'Start-Spinner', 'Update-Spinner', 'Stop-Spinner', 'Write-Progress', 'Enable-DebugMode',
            'Start-SweeprDebugSession', 'Complete-SweeprDebugSession', 'Write-Warning', 'Write-Error')
        foreach ($name in $old) { $names | Should -Not -Contain $name -Because "the module calls $name" }
    }

    It 'LG-41 defines each old name as a function and none of the three internal old helpers' {
        $defined = @($script:SourceAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
        foreach ($name in @('Write-SweeprOperation', 'ConvertTo-SweeprLogValue', 'Add-SweeprOperationText', 'Write-Info', 'Write-Success',
                'Write-SweeprWarning', 'Write-SweeprError', 'Write-DryRun', 'Write-Debug', 'Start-Section', 'Stop-Section', 'Set-SectionActivity',
                'Test-SweeprInteractiveOutput', 'Initialize-SweeprSpinner', 'Start-Spinner', 'Update-Spinner', 'Stop-Spinner', 'Write-Progress',
                'Enable-DebugMode', 'Start-SweeprDebugSession', 'Complete-SweeprDebugSession')) {
            $defined | Should -Contain $name
        }
        foreach ($name in 'Add-SweeprLogLine', 'Write-LogMessage', 'Write-SweeprDiagnosticLine') { $defined | Should -Not -Contain $name }
    }

    It 'LG-8 calls Get-Date only without parameters' {
        $calls = @($script:SourceAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-Date' }, $true))
        $calls.Count | Should -BeGreaterThan 0 -Because 'the module reads the clock'
        foreach ($call in $calls) { $call.CommandElements.Count | Should -Be 1 -Because "Get-Date at line $($call.Extent.StartLineNumber) has parameters" }
    }

    It 'LG-1 builds paths without Join-Path' {
        @(Get-CommandNames $script:SourceAst) | Should -Not -Contain 'Join-Path'
    }

    It 'LG-15 pauses only with Start-Sleep -Milliseconds' {
        $calls = @($script:SourceAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-Sleep' }, $true))
        $calls.Count | Should -BeGreaterThan 0 -Because 'the retry waits with Start-Sleep'
        foreach ($call in $calls) {
            $named = @($call.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
            ($named.Count -eq 1 -and 'Milliseconds'.StartsWith($named[0], [System.StringComparison]::OrdinalIgnoreCase)) | Should -BeTrue -Because "Start-Sleep at line $($call.Extent.StartLineNumber)"
        }
    }

    It 'LG-17 opens the file with write access and the share mode read and write, and does not use AppendAllText, Add-Content or Out-File' {
        $text = Get-FunctionText $script:SourceAst 'Add-SwOperationText'
        $text | Should -Not -BeNullOrEmpty
        $text | Should -Match 'FileShare\]::ReadWrite' -Because 'Add-SwOperationText opens with the share mode read and write'
        $members = @($script:SourceAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true) | ForEach-Object { $_.Member.Extent.Text })
        $members | Should -Not -Contain 'AppendAllText'
        $members | Should -Not -Contain 'AppendAllLines'
        $names = @(Get-CommandNames $script:SourceAst)
        foreach ($name in 'Add-Content', 'Out-File', 'Set-Content') { $names | Should -Not -Contain $name }
    }

    It 'LG-40 compiles native code only inside Initialize-SwSpinner' {
        $calls = @($script:SourceAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-Type' }, $true))
        $calls.Count | Should -BeGreaterThan 0
        foreach ($call in $calls) {
            $parent = $call.Parent
            $function = $null
            while ($null -ne $parent) {
                if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $function = $parent.Name; break }
                $parent = $parent.Parent
            }
            $function | Should -BeExactly 'Initialize-SwSpinner' -Because "Add-Type at line $($call.Extent.StartLineNumber)"
        }
    }

    It 'LG-39 declares a public static class Sweepr.SwSpinner' {
        $sources = @(Get-CSharpSources $script:SourceAst)
        $sources.Count | Should -Be 1
        $sources[0] | Should -Match 'namespace\s+Sweepr\b'
        $sources[0] | Should -Match 'public\s+static\s+class\s+SwSpinner\b'
    }

    It 'LG-39 keeps the C# within what the compiler of Windows PowerShell 5.1 reads (no ?., string interpolation, nameof, expression bodies, out var, tuples)' {
        $sources = @(Get-CSharpSources $script:SourceAst)
        $sources.Count | Should -Be 1
        $code = [regex]::Replace([regex]::Replace($sources[0], '(?s)/\*.*?\*/', ''), '//[^\r\n]*', '')
        $code | Should -Not -Match '\?\.' -Because 'null-conditional member access needs C# 6'
        $code | Should -Not -Match '\$@?"' -Because 'string interpolation needs C# 6'
        $code | Should -Not -Match '\bnameof\s*\(' -Because 'nameof needs C# 6'
        $code | Should -Not -Match '(?m)\b(public|private|protected|internal|static)\b[^;{}=(]*(\([^)]*\))?\s*=>' -Because 'expression-bodied members need C# 6'
        $code | Should -Not -Match '\?\[' -Because 'null-conditional indexing needs C# 6'
        $code | Should -Not -Match '\bout\s+var\b' -Because 'out var needs C# 7'
        $code | Should -Not -Match '\bis\s+\w+\s+\w+\s*\)' -Because 'pattern matching needs C# 7'
        $code | Should -Not -Match 'ValueTuple|\bTuple\s*<' -Because 'tuples need C# 7'
    }

    It 'LG-39 does not let the animation thread reach PowerShell' {
        $sources = @(Get-CSharpSources $script:SourceAst)
        $sources.Count | Should -Be 1
        foreach ($word in 'System.Management.Automation', 'ScriptBlock', 'Runspace', 'PowerShell', 'Pipeline') {
            $sources[0].Contains($word) | Should -BeFalse -Because "the C# source names $word"
        }
    }
}

# ============================================================================
# Interface
# ============================================================================

Describe 'Interface of log.ps1' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
    }

    It 'Offers <Name> as a function with exactly the documented parameters' -ForEach $script:Interface {
        $command = Get-Command -Name $Name -CommandType Function -ErrorAction Stop
        $common = [System.Management.Automation.Cmdlet]::CommonParameters + [System.Management.Automation.Cmdlet]::OptionalCommonParameters
        $declared = @($command.Parameters.Keys | Where-Object { $_ -notin $common } | Sort-Object)
        ($declared -join ',') | Should -BeExactly ((@($Parameters) | Sort-Object) -join ',')
        for ($i = 0; $i -lt @($Positions).Count; $i++) {
            $attribute = $command.Parameters[$Positions[$i]].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | Select-Object -First 1
            $attribute.Position | Should -Be $i -Because "-$($Positions[$i]) is at position $i"
        }
    }

    It 'Gives <Parameter> of <Name> the type <Type> and the default <Default>' -ForEach $script:ParameterFacts {
        $fact = Get-ParameterFact $Name $Parameter
        $fact.Type | Should -BeExactly $Type
        if ($Default -eq '*') { $fact.Default | Should -Not -BeNullOrEmpty -Because 'the default is a short waiting text' }
        else { ($fact.Default -replace '^"(.*)"$', '''$1''') | Should -BeExactly $Default }
    }

    It 'Requires none of the parameters of Write-SwOperation' {
        $command = Get-Command -Name Write-SwOperation -CommandType Function -ErrorAction Stop
        foreach ($parameter in 'Action', 'Path', 'Detail') {
            $attribute = $command.Parameters[$parameter].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | Select-Object -First 1
            $attribute.Mandatory | Should -BeFalse -Because "-$parameter is optional"
        }
    }
}

# ============================================================================
# Old names (forwarding functions)
# ============================================================================

Describe 'Transition names of the log functions' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Write-SwDiagnosticLine'
    }
    AfterEach { Stop-Case }

    It 'LG-41 keeps <Old> as a function, not an alias' -ForEach $script:Forwarders {
        (Get-Command -Name $Old -ErrorAction Stop).CommandType | Should -Be 'Function'
        Get-Alias -Name $Old -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        (Get-Command -Name $New -ErrorAction Stop).CommandType | Should -Be 'Function'
    }

    It 'LG-41 gives <Old> the same parameters as <New> (names, types, positions, mandatory flags, defaults)' -ForEach $script:Forwarders {
        $old = @(Get-ParamSignature $Old)
        $new = @(Get-ParamSignature $New)
        ($old -join "`n") | Should -BeExactly ($new -join "`n")
    }

    It 'LG-41 forwards <Old> to <New> once with the same values' -ForEach $script:Forwarders {
        Mock -CommandName $New -MockWith { 'forwarded' }
        $result = & $Invoke
        if ($Pass) { $result | Should -Be 'forwarded' }
        Should -Invoke -CommandName $New -Times 1 -Exactly -ParameterFilter $Filter
    }

    It 'LG-41 lets Write-Debug and Write-Progress replace the built-in cmdlets without common parameters' {
        foreach ($name in 'Write-Debug', 'Write-Progress') {
            $command = Get-Command -Name $name -CommandType Function -ErrorAction Stop
            $command.CmdletBinding | Should -BeFalse -Because "$name has no CmdletBinding"
            $command.Parameters.ContainsKey('Debug') | Should -BeFalse -Because "$name has no -Debug"
            $command.Parameters.ContainsKey('Verbose') | Should -BeFalse -Because "$name has no -Verbose"
        }
    }

    It 'LG-41 gives the Write-Debug forwarder no extra output of its own under $DebugPreference Continue' {
        Mock Write-Host { }
        $DebugPreference = 'Continue'
        $script:LogConfig = @{ DebugEnabled = $false; LogFile = $null }
        $streams = Get-AllOutput { Write-Debug 'quiet' }
        $streams.Count | Should -Be 0
    }

    It 'LG-41 lets no mock of an old name reach into the module: calls inside use the new names' {
        $script:CurrentSection = @{ Active = $false; Activity = $false; Name = '' }
        $script:SpinnerDisabled = $true
        Mock Write-Host { }
        Mock Write-Info { }
        Mock Write-Success { }
        Mock Write-SweeprWarning { }
        Mock Write-SweeprError { }
        Mock Write-DryRun { }
        Mock Start-Section { }
        Mock Set-SectionActivity { }
        Mock Stop-Spinner { }
        Mock Start-Spinner { }
        Mock Write-Debug { }
        Write-SwInfo 'x'
        Write-SwSuccess 'x'
        Write-SwWarning 'x'
        Write-SwError 'x'
        Write-SwDryRun 'x'
        Start-SwSection 'x'
        Set-SwSectionActivity
        Stop-SwSection
        Update-SwSpinner 'x'
        Write-SwProgress -Activity 'x'
        foreach ($name in 'Write-Info', 'Write-Success', 'Write-SweeprWarning', 'Write-SweeprError', 'Write-DryRun', 'Start-Section', 'Set-SectionActivity', 'Stop-Spinner', 'Start-Spinner', 'Write-Debug') {
            Should -Invoke -CommandName $name -Times 0 -Exactly -Because "the module calls the new names, not $name"
        }
    }

    It 'S-3 does not throw when <Old> is called' -ForEach $script:Forwarders {
        Mock Write-Host { }
        Mock Write-SwDiagnosticLine { }
        # The forwarders of the writing names are called with relative example paths: no file, not even in the working folder.
        Mock Add-SwOperationText { }
        { & $Invoke } | Should -Not -Throw
    }
}
