# Sweepr - tests for the line that lib\core\log.ps1 writes to operations.log: when a line is written,
# its form, the command and run id, the time, the escaping of path and detail, the action word, and
# the safety invariants that follow from the form.
#
# The rule numbers in the test names (LG- and S-) number the rules and the safety invariants of the
# module's behavior; each rule and invariant has at least one test. The rules for the marker, the file,
# rotation, retries and failures are in tests/SwLogWrite.Tests.ps1.
#
# Interface pinned here (new names; each old name stays as a forwarding function):
#   Write-SwOperation [-Action] [-Path] [-Detail]    appends at most one line to the operations log
#   ConvertTo-SwLogValue [-Value]                    control characters written out as text
# Script variables that tests replace: $script:SweeprOperationsLogFile, $script:SweeprOperationsLogStarted,
# $script:SweeprOperationsLogMaxBytes, $script:SWEEPR_LOG_LOADED.
# Environment: SWEEPR_NO_OPLOG, SWEEPR_DRY_RUN, _SWEEPR_OPLOG_RUN_COMMAND, _SWEEPR_OPLOG_RUN_ID.
#
# Seams used with Mock:
#   Get-Date                    one call without parameters per record
#   Write-SwDebug               the message about a line that was not written
#   Add-SwOperationText         the only call that appends text
#   Write-Host                  must stay unused by the writer
# Read back with Read-SwHistory (lib\core\history.ps1) and the patterns of the readers.
#
# Platform notes:
#   - Everything lives in $TestDrive; no real operations.log, no registry, no network. The gate sets
#     SWEEPR_NO_OPLOG=1; every test that writes unsets it and the file puts it back.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    $script:ValidActions = @(
        @{ Action = 'REMOVED' }, @{ Action = 'RECYCLED' }, @{ Action = 'UNINSTALLED' }, @{ Action = 'DISABLED' }
        @{ Action = 'RESTORED' }, @{ Action = 'SKIPPED' }, @{ Action = 'FAILED' }, @{ Action = 'OPTIMIZED' }
        @{ Action = 'OWNER' }, @{ Action = 'X' }, @{ Action = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' }
    )

    # LG-10: everything that is not at least one ASCII capital letter and nothing else.
    $script:InvalidActions = @(
        @{ Label = 'lower case'; Action = 'removed' }
        @{ Label = 'mixed case'; Action = 'Removed' }
        @{ Label = 'a hyphen'; Action = 'OPT-IMIZED' }
        @{ Label = 'a space'; Action = 'A B' }
        @{ Label = 'a line feed inside'; Action = ('REM' + [char]10 + 'OVED') }
        @{ Label = 'a trailing line feed'; Action = ('REMOVED' + [char]10) }
        @{ Label = 'a trailing carriage return'; Action = ('REMOVED' + [char]13) }
        @{ Label = 'a digit'; Action = 'REMOVED2' }
        @{ Label = 'an underscore'; Action = 'RE_MOVED' }
        @{ Label = 'a capital with a diaeresis'; Action = ([string][char]0xC4 + 'BC') }
        @{ Label = 'full-width capitals'; Action = ([string][char]0xFF32 + [char]0xFF25) }
        @{ Label = 'the Kelvin sign'; Action = ('RE' + [char]0x212A) }
        @{ Label = 'a NUL character'; Action = ('RE' + [char]0 + 'MOVED') }
        @{ Label = 'an escape character'; Action = ('RE' + [char]27 + 'MOVED') }
        @{ Label = 'white space only'; Action = ' ' }
        @{ Label = 'the empty string'; Action = '' }
    )

    # LG-7: values that are valid and that are not, for the command and for the run id.
    $script:ValidCommands = @(
        @{ Label = 'a plain word'; Value = 'purge' }
        @{ Label = 'a word with a capital'; Value = 'Uninstall' }
        @{ Label = 'a word with a diaeresis'; Value = ([string][char]0xDC + 'ber') }
        @{ Label = 'a word with an opening bracket'; Value = 'a[b' }
        @{ Label = 'a word with parentheses'; Value = 'x(y)' }
        @{ Label = 'a long word'; Value = ('c' * 200) }
    )
    $script:InvalidCommands = @(
        @{ Label = 'a forged bracket sequence'; Value = 'clean x] [forged' }
        @{ Label = 'a space'; Value = 'a b' }
        @{ Label = 'a tab'; Value = ('a' + [char]9 + 'b') }
        @{ Label = 'a closing bracket'; Value = 'a]b' }
        @{ Label = 'a line feed'; Value = ('a' + [char]10 + 'b') }
        @{ Label = 'a trailing line feed'; Value = ('clean' + [char]10) }
        @{ Label = 'a carriage return'; Value = ('a' + [char]13 + 'b') }
        @{ Label = 'U+0085'; Value = ('a' + [char]0x85 + 'b') }
        @{ Label = 'a no-break space'; Value = ('a' + [char]0xA0 + 'b') }
        @{ Label = 'an em space'; Value = ('a' + [char]0x2003 + 'b') }
        @{ Label = 'a line separator'; Value = ('a' + [char]0x2028 + 'b') }
        @{ Label = 'an ideographic space'; Value = ('a' + [char]0x3000 + 'b') }
        @{ Label = 'DEL'; Value = ('a' + [char]0x7F + 'b') }
        @{ Label = 'an escape character'; Value = ('a' + [char]27 + 'b') }
        @{ Label = 'a space only'; Value = ' ' }
    )
    $script:ValidRunIds = @(
        @{ Label = 'digits and hyphens'; Value = '20261015100000-4242-17' }
        @{ Label = 'a short word'; Value = 'a1' }
        @{ Label = 'an equals sign'; Value = 'x=y' }
        @{ Label = 'an opening bracket'; Value = 'a[b' }
    )
    $script:InvalidRunIds = @(
        @{ Label = 'a space'; Value = 'a b' }
        @{ Label = 'a closing bracket'; Value = 'a]b' }
        @{ Label = 'a tab'; Value = ('a' + [char]9 + 'b') }
        @{ Label = 'a line feed'; Value = ('a' + [char]10 + 'b') }
        @{ Label = 'U+0085'; Value = ('a' + [char]0x85 + 'b') }
        @{ Label = 'a no-break space'; Value = ('a' + [char]0xA0 + 'b') }
        @{ Label = 'a line separator'; Value = ('a' + [char]0x2028 + 'b') }
        @{ Label = 'DEL'; Value = ('a' + [char]0x7F + 'b') }
        @{ Label = 'a space only'; Value = ' ' }
    )

    # LG-9: the control characters and what they are written as.
    $script:EscapeCases = @(
        @{ Name = 'U+0009 (tab)'; Code = 9; Expected = '\t' }
        @{ Name = 'U+000A (line feed)'; Code = 10; Expected = '\n' }
        @{ Name = 'U+000D (carriage return)'; Code = 13; Expected = '\r' }
    )
    foreach ($code in @(0..8) + @(11, 12) + @(14..31) + @(127)) {
        $script:EscapeCases += , @{ Name = ('U+{0:X4}' -f $code); Code = $code; Expected = ('\x{0:x2}' -f $code) }
    }

    # LG-9 and S-6: text that must reach the file as it is.
    $script:LiteralTexts = @(
        @{ Label = 'a format placeholder'; Text = 'C:\Temp\{0} and {1:N2}' }
        @{ Label = 'a percent variable'; Text = 'C:\%ZZ_SWEEPR_LOG_TEST%\x' }
        @{ Label = 'a subexpression'; Text = 'C:\$(Get-Date)\x' }
        @{ Label = 'a variable'; Text = 'C:\$env:ZZ_SWEEPR_LOG_TEST\x' }
        @{ Label = 'a backtick'; Text = ('C:\a' + [char]96 + 'nb') }
        @{ Label = 'brackets'; Text = 'C:\Cache [1]\x' }
        @{ Label = 'wildcards'; Text = 'C:\*?[]\x' }
        @{ Label = 'a double quote'; Text = 'C:\Temp\q"uote' }
        @{ Label = 'an apostrophe'; Text = 'C:\Temp\it''s' }
        @{ Label = 'a semicolon and an ampersand'; Text = 'C:\a;b&c' }
    )

    # S-1: text that tries to make a second record or marker.
    $script:ForgeryTexts = @(
        @{ Label = 'a line feed'; Text = ('C:\a' + [char]10 + 'b') }
        @{ Label = 'a carriage return'; Text = ('C:\a' + [char]13 + 'b') }
        @{ Label = 'a CRLF pair'; Text = ('C:\a' + [char]13 + [char]10 + 'b') }
        @{ Label = 'a NUL character'; Text = ('C:\a' + [char]0 + 'b') }
        @{ Label = 'an escape character'; Text = ('C:\a' + [char]27 + '[2Jb') }
        @{ Label = 'a line separator'; Text = ('C:\a' + [char]0x2028 + 'b') }
        @{ Label = 'a paragraph separator'; Text = ('C:\a' + [char]0x2029 + 'b') }
        @{ Label = 'U+0085'; Text = ('C:\a' + [char]0x85 + 'b') }
        @{ Label = 'the marker text'; Text = '# ========== x run=y session started at z ==========' }
        @{ Label = 'a record text'; Text = '[2026-01-01 00:00:00] [x] REMOVED C:\f (1)' }
        @{ Label = 'a marker and a record after a line break'; Text = ([string][char]13 + [char]10 + '# ========== forged session started at 2026-01-01 00:00:00 ==========' + [char]13 + [char]10 + '[2026-01-01 00:00:00] [forged] REMOVED C:\f (1)') }
    )

    $script:Cultures = @()
    $probe = [datetime]'2026-10-15 10:00:01'
    foreach ($name in 'fi-FI', 'ar-SA', 'th-TH') {
        try {
            $culture = [System.Globalization.CultureInfo]::GetCultureInfo($name)
            $text = $probe.ToString('yyyy-MM-dd HH:mm:ss', $culture)
            if ($text -ne '2026-10-15 10:00:01') { $script:Cultures += , @{ Culture = $name; Own = $text } }
        }
        catch { $null = $_ }
    }
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

    # Splits the file at CRLF; every part is empty, a marker or a record, and none holds a line break.
    function script:Assert-OnlyRecords([string]$Path, [int]$Records, [int]$Markers) {
        $parts = @(Get-LogLines $Path)
        $recordCount = 0
        $markerCount = 0
        foreach ($part in $parts) {
            $part.Contains([string][char]10) | Should -BeFalse -Because 'no line feed inside a line'
            $part.Contains([string][char]13) | Should -BeFalse -Because 'no carriage return inside a line'
            if ($part.Length -eq 0) { continue }
            if ($script:RecordPattern.IsMatch($part)) { $recordCount++ }
            elseif ($script:MarkerPattern.IsMatch($part)) { $markerCount++ }
            else { throw "a line that is neither a record nor a marker: $part" }
        }
        $recordCount | Should -Be $Records
        $markerCount | Should -Be $Markers
        # A reader that splits at line feeds sees the same number of lines.
        $reader = New-Object System.IO.StreamReader($Path, $script:Utf8)
        try {
            $lines = 0
            while ($null -ne ($line = $reader.ReadLine())) { if ($line.Length -gt 0) { $lines++ } }
            $lines | Should -Be ($Records + $Markers)
        }
        finally { $reader.Dispose() }
    }

    # What the whole file changes in the process, put back after the last test.
    $script:RootState = Save-State
    $script:RootEnv = Save-Env $script:EnvNames
    . $script:LogScript
    . $script:HistoryScript
}

AfterAll {
    Restore-State $script:RootState
    Restore-Env $script:RootEnv
}

# ============================================================================
# When a line is written
# ============================================================================

Describe 'Write-SwOperation: when a line is written' {
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

    It 'LG-5 writes nothing when SWEEPR_NO_OPLOG is 1: no folder, no file, no marker, no output, no exception' {
        Set-Env 'SWEEPR_NO_OPLOG' '1'
        Mock Add-SwOperationText { }
        $streams = @(Write-SwOperation -Action 'REMOVED' -Path 'C:\Users\Example\a.tmp' -Detail '1KB' 2>&1 3>&1 4>&1 5>&1 6>&1)
        $streams.Count | Should -Be 0
        [System.IO.Directory]::Exists($script:Dir) | Should -BeFalse
        [System.IO.File]::Exists($script:LogPath) | Should -BeFalse
        $script:SweeprOperationsLogStarted | Should -BeFalse
        Should -Invoke -CommandName Add-SwOperationText -Times 0 -Exactly
        Should -Invoke -CommandName Write-Host -Times 0 -Exactly
        $script:Messages.Count | Should -Be 0
    }

    It 'LG-5 writes a record when SWEEPR_NO_OPLOG is <Label>' -ForEach @(
        @{ Label = 'empty'; Value = '' }
        @{ Label = '0'; Value = '0' }
        @{ Label = 'true'; Value = 'true' }
        @{ Label = 'TRUE'; Value = 'TRUE' }
        @{ Label = 'yes'; Value = 'yes' }
        @{ Label = '2'; Value = '2' }
        @{ Label = '1 with a trailing blank'; Value = '1 ' }
        @{ Label = '1 with a leading blank'; Value = ' 1' }
        @{ Label = '01'; Value = '01' }
    ) {
        Set-Env 'SWEEPR_NO_OPLOG' $Value
        Write-SwOperation -Action 'REMOVED' -Path 'C:\Users\Example\a.tmp' -Detail '1KB'
        @(Get-RecordLines $script:LogPath).Count | Should -Be 1
    }

    It 'LG-5 reads SWEEPR_NO_OPLOG at every call' {
        Set-Env 'SWEEPR_NO_OPLOG' '1'
        Write-SwOperation -Action 'REMOVED' -Path 'C:\Users\Example\first' -Detail '1KB'
        [System.IO.File]::Exists($script:LogPath) | Should -BeFalse
        Set-Env 'SWEEPR_NO_OPLOG' $null
        Write-SwOperation -Action 'REMOVED' -Path 'C:\Users\Example\second' -Detail '1KB'
        Set-Env 'SWEEPR_NO_OPLOG' '1'
        Write-SwOperation -Action 'REMOVED' -Path 'C:\Users\Example\third' -Detail '1KB'
        $records = @(Get-RecordLines $script:LogPath)
        $records.Count | Should -Be 1
        $records[0] | Should -Match 'second'
    }

    It 'LG-5 writes nothing for a path that is <Label>' -ForEach @(
        @{ Label = 'the empty string'; Path = '' }
        @{ Label = '$null'; Path = $null }
    ) {
        Mock Add-SwOperationText { }
        { Write-SwOperation -Action 'REMOVED' -Path $Path -Detail 'x' } | Should -Not -Throw
        [System.IO.Directory]::Exists($script:Dir) | Should -BeFalse
        Should -Invoke -CommandName Add-SwOperationText -Times 0 -Exactly
        $script:SweeprOperationsLogStarted | Should -BeFalse
    }

    It 'LG-5 writes nothing when called without arguments' {
        Mock Add-SwOperationText { }
        { Write-SwOperation } | Should -Not -Throw
        [System.IO.Directory]::Exists($script:Dir) | Should -BeFalse
        Should -Invoke -CommandName Add-SwOperationText -Times 0 -Exactly
    }

    It 'LG-5 writes a record for a path of one space' {
        Write-SwOperation -Action 'REMOVED' -Path ' ' -Detail 'x'
        $record = Get-OneRecord $script:LogPath
        $record.Groups[5].Value | Should -BeExactly ' '
    }

    It 'LG-5 writes nothing and does not throw when the log file name is <Label>' -ForEach @(
        @{ Label = 'empty'; File = '' }
        @{ Label = '$null'; File = $null }
    ) {
        $probe = New-Dir (P $script:Work 'probe')
        $previous = [System.Environment]::CurrentDirectory
        [System.Environment]::CurrentDirectory = $probe
        try {
            Mock Add-SwOperationText { }
            $script:SweeprOperationsLogFile = $File
            { Write-SwOperation -Action 'REMOVED' -Path 'C:\Users\Example\a.tmp' -Detail '1KB' } | Should -Not -Throw
            Should -Invoke -CommandName Add-SwOperationText -Times 0 -Exactly
            (Get-Listing $probe) -join '|' | Should -BeExactly ''
            [System.IO.Directory]::Exists($script:Dir) | Should -BeFalse
            $script:SweeprOperationsLogStarted | Should -BeFalse
        }
        finally { [System.Environment]::CurrentDirectory = $previous }
    }

    It 'LG-5 does not read SWEEPR_DRY_RUN: a direct call writes' {
        Set-Env 'SWEEPR_DRY_RUN' '1'
        Write-SwOperation -Action 'REMOVED' -Path 'C:\Users\Example\a.tmp' -Detail '1KB'
        @(Get-RecordLines $script:LogPath).Count | Should -Be 1
    }

    It 'LG-5 writes nothing for an action that is <Label>, creates no folder and reports it once' -ForEach $script:InvalidActions {
        Mock Add-SwOperationText { }
        { Write-SwOperation -Action $Action -Path 'C:\Users\Example\a.tmp' -Detail '1KB' } | Should -Not -Throw
        Should -Invoke -CommandName Add-SwOperationText -Times 0 -Exactly
        [System.IO.Directory]::Exists($script:Dir) | Should -BeFalse
        $script:SweeprOperationsLogStarted | Should -BeFalse
        $script:Messages.Count | Should -Be 1
        $script:Messages[0] | Should -BeLike 'operations.log not written: *'
    }

    It 'LG-10 writes nothing for an action of $null' {
        Mock Add-SwOperationText { }
        { Write-SwOperation -Action $null -Path 'C:\Users\Example\a.tmp' -Detail '1KB' } | Should -Not -Throw
        Should -Invoke -CommandName Add-SwOperationText -Times 0 -Exactly
        [System.IO.Directory]::Exists($script:Dir) | Should -BeFalse
    }

    It 'LG-10 writes the action <Action> unchanged' -ForEach $script:ValidActions {
        Write-SwOperation -Action $Action -Path 'C:\Users\Example\a.tmp' -Detail '1KB'
        $record = Get-OneRecord $script:LogPath
        $record.Groups[4].Value | Should -BeExactly $Action
        $script:Messages.Count | Should -Be 0
    }

    It 'LG-5 leaves no folder after an aborted call whatever the reason' {
        Set-Env 'SWEEPR_NO_OPLOG' '1'
        Write-SwOperation -Action 'REMOVED' -Path 'C:\x' -Detail 'd'
        Set-Env 'SWEEPR_NO_OPLOG' $null
        Write-SwOperation -Action 'removed' -Path 'C:\x' -Detail 'd'
        Write-SwOperation -Action 'REMOVED' -Path '' -Detail 'd'
        [System.IO.Directory]::Exists($script:Dir) | Should -BeFalse
        [System.IO.Directory]::Exists($script:Work + $script:Sep + 'config') | Should -BeFalse
    }
}

# ============================================================================
# The form of the line
# ============================================================================

Describe 'Write-SwOperation: the form of the line' {
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

    It 'LG-6 writes the marker and the record in the documented form for a new file' {
        Set-Env '_SWEEPR_OPLOG_RUN_COMMAND' 'clean'
        Set-Env '_SWEEPR_OPLOG_RUN_ID' '20261015100000-4242-17'
        Write-SwOperation -Action 'REMOVED' -Path 'C:\Users\Example\AppData\Local\Temp\a.tmp' -Detail '1.0KB'
        $expected = $script:Crlf +
        '# ========== clean run=20261015100000-4242-17 session started at 2026-10-15 10:00:01 ==========' + $script:Crlf +
        '[2026-10-15 10:00:01] [clean run=20261015100000-4242-17] REMOVED C:\Users\Example\AppData\Local\Temp\a.tmp (1.0KB)' + $script:Crlf
        Get-LogText $script:LogPath | Should -BeExactly $expected
    }

    It 'LG-6 keeps the parentheses of a path and gives Read-SwHistory the fields of the line' {
        Set-Env '_SWEEPR_OPLOG_RUN_COMMAND' 'uninstall'
        Write-SwOperation -Action 'RECYCLED' -Path 'C:\Program Files (x86)\Contoso App' -Detail '2.0MB'
        $records = @(Get-RecordLines $script:LogPath)
        $records.Count | Should -Be 1
        $records[0] | Should -BeExactly '[2026-10-15 10:00:01] [uninstall] RECYCLED C:\Program Files (x86)\Contoso App (2.0MB)'
        $history = Read-SwHistory -Path $script:LogPath
        @($history.Operations).Count | Should -Be 1
        $history.Operations[0].command | Should -BeExactly 'uninstall'
        $history.Operations[0].run_id | Should -BeExactly ''
        $history.Operations[0].action | Should -BeExactly 'recycled'
        $history.Operations[0].path | Should -BeExactly 'C:\Program Files (x86)\Contoso App'
        $history.Operations[0].detail | Should -BeExactly '2.0MB'
        $history.Operations[0].timestamp | Should -BeExactly '2026-10-15 10:00:01'
    }

    It 'LG-6 gives Read-SwHistory the run id of the line' {
        Set-Env '_SWEEPR_OPLOG_RUN_COMMAND' 'clean'
        Set-Env '_SWEEPR_OPLOG_RUN_ID' 'a1'
        Write-SwOperation -Action 'FAILED' -Path 'C:\Users\Example\b.tmp' -Detail 'access denied'
        $history = Read-SwHistory -Path $script:LogPath
        $history.Operations[0].run_id | Should -BeExactly 'a1'
        $history.Operations[0].detail | Should -BeExactly 'access denied'
        $history.Sessions[0].run_id | Should -BeExactly 'a1'
    }

    It 'LG-6 takes the three parameters by position: action, path, detail' {
        Write-SwOperation 'SKIPPED' 'C:\Users\Example\c.tmp' 'in use'
        $record = Get-OneRecord $script:LogPath
        $record.Groups[4].Value | Should -BeExactly 'SKIPPED'
        $record.Groups[5].Value | Should -BeExactly 'C:\Users\Example\c.tmp'
        $record.Groups[6].Value | Should -BeExactly 'in use'
    }

    It 'LG-6 writes a detail of - when the detail parameter is left out' {
        Write-SwOperation -Action 'REMOVED' -Path 'C:\Users\Example\a.tmp'
        $record = Get-OneRecord $script:LogPath
        $record.Groups[6].Value | Should -BeExactly '-'
    }

    It 'LG-6 ends every line with CRLF and has no single line feed or carriage return' {
        Write-SwOperation -Action 'REMOVED' -Path 'C:\Users\Example\a.tmp' -Detail '1KB'
        Write-SwOperation -Action 'FAILED' -Path 'C:\Users\Example\b.tmp' -Detail 'x'
        $bytes = [System.IO.File]::ReadAllBytes($script:LogPath)
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i] -eq 10) { $i | Should -BeGreaterThan 0; $bytes[$i - 1] | Should -Be 13 -Because "line feed at byte $i follows a carriage return" }
            if ($bytes[$i] -eq 13) { $bytes[$i + 1] | Should -Be 10 -Because "carriage return at byte $i is followed by a line feed" }
        }
        $bytes[$bytes.Length - 2] | Should -Be 13
        $bytes[$bytes.Length - 1] | Should -Be 10
    }

    It 'LG-6 puts exactly one space between the parts of the record' {
        Write-SwOperation -Action 'REMOVED' -Path 'C:\a' -Detail 'd'
        @(Get-RecordLines $script:LogPath)[0] | Should -BeExactly '[2026-10-15 10:00:01] [sweepr] REMOVED C:\a (d)'
    }

    It 'LG-6 gives every record a match for the record pattern and every marker a match for the marker pattern' {
        Set-Env '_SWEEPR_OPLOG_RUN_COMMAND' 'clean'
        Set-Env '_SWEEPR_OPLOG_RUN_ID' 'r1'
        foreach ($path in @('C:\a', 'C:\Program Files (x86)\b', ('C:\c' + [char]10 + 'd'), 'C:\Users\Example\Uebung', ('C:\' + [char]0xDC + 'bung\' + [char]0x4E2D))) {
            Write-SwOperation -Action 'REMOVED' -Path $path -Detail 'x (1)'
        }
        foreach ($line in @(Get-RecordLines $script:LogPath)) { $script:RecordPattern.IsMatch($line) | Should -BeTrue -Because $line }
        $markers = @(Get-MarkerLines $script:LogPath)
        $markers.Count | Should -Be 1
        $script:MarkerPattern.IsMatch($markers[0]) | Should -BeTrue -Because $markers[0]
        @(Get-RecordLines $script:LogPath).Count | Should -Be 5
    }

    It 'LG-6 returns nothing and prints nothing on success, also in debug mode' {
        $script:LogConfig = @{ DebugEnabled = $true; LogFile = $null }
        $streams = @(Write-SwOperation -Action 'REMOVED' -Path 'C:\a' -Detail 'd' 2>&1 3>&1 4>&1 5>&1 6>&1)
        $streams.Count | Should -Be 0
        Should -Invoke -CommandName Write-Host -Times 0 -Exactly
        $script:Messages.Count | Should -Be 0
    }
}

# ============================================================================
# Command and run id
# ============================================================================

Describe 'Write-SwOperation: command and run id' {
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

    It 'LG-7 names the command in the label: <Label>' -ForEach $script:ValidCommands {
        Set-Env '_SWEEPR_OPLOG_RUN_COMMAND' $Value
        Write-SwOperation -Action 'REMOVED' -Path 'C:\a' -Detail 'd'
        $record = Get-OneRecord $script:LogPath
        $record.Groups[2].Value | Should -BeExactly $Value
        $record.Groups[3].Value | Should -BeExactly ''
        @(Get-RecordLines $script:LogPath)[0] | Should -BeExactly ('[2026-10-15 10:00:01] [' + $Value + '] REMOVED C:\a (d)')
    }

    It 'LG-7 uses sweepr for an empty or missing command' {
        Write-SwOperation -Action 'REMOVED' -Path 'C:\a' -Detail 'd'
        (Get-OneRecord $script:LogPath).Groups[2].Value | Should -BeExactly 'sweepr'
        @(Get-RecordLines $script:LogPath)[0] | Should -BeExactly '[2026-10-15 10:00:01] [sweepr] REMOVED C:\a (d)'
    }

    It 'LG-7 uses sweepr for an invalid command: <Label>' -ForEach $script:InvalidCommands {
        Set-Env '_SWEEPR_OPLOG_RUN_COMMAND' $Value
        Write-SwOperation -Action 'REMOVED' -Path 'C:\a' -Detail 'd'
        @(Get-RecordLines $script:LogPath)[0] | Should -BeExactly '[2026-10-15 10:00:01] [sweepr] REMOVED C:\a (d)'
        $history = Read-SwHistory -Path $script:LogPath
        $history.Operations[0].command | Should -BeExactly 'sweepr'
        @($history.Sessions).Count | Should -Be 1
    }

    It 'LG-7 appends the run id after the command: <Label>' -ForEach $script:ValidRunIds {
        Set-Env '_SWEEPR_OPLOG_RUN_COMMAND' 'clean'
        Set-Env '_SWEEPR_OPLOG_RUN_ID' $Value
        Write-SwOperation -Action 'REMOVED' -Path 'C:\a' -Detail 'd'
        @(Get-RecordLines $script:LogPath)[0] | Should -BeExactly ('[2026-10-15 10:00:01] [clean run=' + $Value + '] REMOVED C:\a (d)')
        @(Get-MarkerLines $script:LogPath)[0] | Should -BeExactly ('# ========== clean run=' + $Value + ' session started at 2026-10-15 10:00:01 ==========')
        $history = Read-SwHistory -Path $script:LogPath
        $history.Operations[0].run_id | Should -BeExactly $Value
    }

    It 'LG-7 leaves out an invalid run id and keeps the command: <Label>' -ForEach $script:InvalidRunIds {
        Set-Env '_SWEEPR_OPLOG_RUN_COMMAND' 'clean'
        Set-Env '_SWEEPR_OPLOG_RUN_ID' $Value
        Write-SwOperation -Action 'REMOVED' -Path 'C:\a' -Detail 'd'
        @(Get-RecordLines $script:LogPath)[0] | Should -BeExactly '[2026-10-15 10:00:01] [clean] REMOVED C:\a (d)'
        @(Get-MarkerLines $script:LogPath)[0] | Should -BeExactly '# ========== clean session started at 2026-10-15 10:00:01 =========='
    }

    It 'LG-7 writes sweepr with the run id when only the run id is set' {
        Set-Env '_SWEEPR_OPLOG_RUN_ID' 'a1'
        Write-SwOperation -Action 'REMOVED' -Path 'C:\a' -Detail 'd'
        @(Get-RecordLines $script:LogPath)[0] | Should -BeExactly '[2026-10-15 10:00:01] [sweepr run=a1] REMOVED C:\a (d)'
    }

    It 'LG-7 writes sweepr when the command is invalid and the run id is valid' {
        Set-Env '_SWEEPR_OPLOG_RUN_COMMAND' 'clean x] [forged'
        Set-Env '_SWEEPR_OPLOG_RUN_ID' 'a1'
        Write-SwOperation -Action 'REMOVED' -Path 'C:\a' -Detail 'd'
        @(Get-RecordLines $script:LogPath)[0] | Should -BeExactly '[2026-10-15 10:00:01] [sweepr run=a1] REMOVED C:\a (d)'
    }

    It 'LG-7 reads command and run id at every call' {
        Set-Env '_SWEEPR_OPLOG_RUN_COMMAND' 'purge'
        Set-Env '_SWEEPR_OPLOG_RUN_ID' 'a1'
        Write-SwOperation -Action 'REMOVED' -Path 'C:\first' -Detail 'd'
        Set-Env '_SWEEPR_OPLOG_RUN_COMMAND' 'optimize'
        Set-Env '_SWEEPR_OPLOG_RUN_ID' $null
        Write-SwOperation -Action 'REMOVED' -Path 'C:\second' -Detail 'd'
        $records = @(Get-RecordLines $script:LogPath)
        $records[0] | Should -BeExactly '[2026-10-15 10:00:01] [purge run=a1] REMOVED C:\first (d)'
        $records[1] | Should -BeExactly '[2026-10-15 10:00:01] [optimize] REMOVED C:\second (d)'
    }
}

# ============================================================================
# Time
# ============================================================================

Describe 'Write-SwOperation: time' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Write-SwOperation', 'Add-SwOperationText', 'Write-SwDebug'
        Use-DebugCapture
        Mock Write-Host { }
        $script:SavedCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
    }
    AfterEach {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $script:SavedCulture
        Stop-Case
    }

    It 'LG-8 writes the time of the clock as yyyy-MM-dd HH:mm:ss' {
        Use-Clock ([datetime]'2026-10-15 10:00:01')
        Write-SwOperation -Action 'REMOVED' -Path 'C:\a' -Detail 'd'
        (Get-OneRecord $script:LogPath).Groups[1].Value | Should -BeExactly '2026-10-15 10:00:01'
    }

    It 'LG-8 uses two digits and the 24-hour clock: 2026-01-02 15:04:05 and 2026-01-02 03:04:05' {
        Use-Clock ([datetime]'2026-01-02 15:04:05')
        Write-SwOperation -Action 'REMOVED' -Path 'C:\a' -Detail 'd'
        $script:Clock = [datetime]'2026-01-02 03:04:05'
        Write-SwOperation -Action 'REMOVED' -Path 'C:\b' -Detail 'd'
        $records = @(Get-RecordLines $script:LogPath)
        $records[0] | Should -BeLike '`[2026-01-02 15:04:05`] *'
        $records[1] | Should -BeLike '`[2026-01-02 03:04:05`] *'
    }

    It 'LG-8 calls Get-Date once per record, without parameters, and shares the time with the marker' {
        Use-Clock ([datetime]'2026-10-15 10:00:01')
        Set-Env '_SWEEPR_OPLOG_RUN_COMMAND' 'clean'
        Write-SwOperation -Action 'REMOVED' -Path 'C:\a' -Detail 'd'
        $script:DateCalls | Should -Be 1 -Because 'marker and first record share one reading of the clock'
        $script:Clock = [datetime]'2026-10-15 10:00:02'
        Write-SwOperation -Action 'REMOVED' -Path 'C:\b' -Detail 'd'
        $script:DateCalls | Should -Be 2
        $script:DateCallsWithArguments | Should -Be 0
        @(Get-MarkerLines $script:LogPath)[0] | Should -BeExactly '# ========== clean session started at 2026-10-15 10:00:01 =========='
        @(Get-RecordLines $script:LogPath)[1] | Should -BeLike '`[2026-10-15 10:00:02`] *'
    }

    It 'LG-8 writes ASCII digits and the separators of the invariant culture under <Culture>' -ForEach $script:Cultures {
        Use-Clock ([datetime]'2026-10-15 10:00:01')
        [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($Culture)
        ([datetime]'2026-10-15 10:00:01').ToString('yyyy-MM-dd HH:mm:ss') | Should -BeExactly $Own -Because 'the culture changes the plain format on this host'
        Write-SwOperation -Action 'REMOVED' -Path 'C:\a' -Detail 'd'
        (Get-OneRecord $script:LogPath).Groups[1].Value | Should -BeExactly '2026-10-15 10:00:01'
        @(Get-MarkerLines $script:LogPath)[0] | Should -BeExactly '# ========== sweepr session started at 2026-10-15 10:00:01 =========='
    }
}

# ============================================================================
# Writing out path and detail
# ============================================================================

Describe 'ConvertTo-SwLogValue' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Assert-Defined 'ConvertTo-SwLogValue'
    }

    It 'LG-9 writes <Name> as <Expected>' -ForEach $script:EscapeCases {
        $text = 'a' + [string][char]$Code + 'b'
        ConvertTo-SwLogValue -Value $text | Should -BeExactly ('a' + $Expected + 'b')
    }

    It 'LG-9 writes the example from the documentation' {
        $text = 'C:\a' + [char]9 + 'b' + [char]10 + 'c' + [char]27
        ConvertTo-SwLogValue $text | Should -BeExactly 'C:\a\tb\nc\x1b'
        ConvertTo-SwLogValue ([string][char]0) | Should -BeExactly '\x00'
        ConvertTo-SwLogValue ([string][char]127) | Should -BeExactly '\x7f'
        ConvertTo-SwLogValue ([string][char]13 + [char]10) | Should -BeExactly '\r\n'
    }

    It 'LG-9 writes the hexadecimal digits in lower case' {
        ConvertTo-SwLogValue ([string][char]0x1F) | Should -BeExactly '\x1f'
        ConvertTo-SwLogValue ([string][char]0x1A) | Should -BeExactly '\x1a'
        ConvertTo-SwLogValue ([string][char]0x0B) | Should -BeExactly '\x0b'
    }

    It 'LG-9 keeps backslashes, quotes, parentheses and brackets' {
        $text = 'C:\Temp\q"uote (x86) [1] {a}'
        ConvertTo-SwLogValue $text | Should -BeExactly $text
    }

    It 'LG-9 keeps characters above U+007E and the C1 controls: <Label>' -ForEach @(
        @{ Label = 'a diaeresis'; Text = ('C:\Users\Example\' + [char]0xDC + 'bung') }
        @{ Label = 'CJK'; Text = ('C:\' + [char]0x4E2D + [char]0x6587) }
        @{ Label = 'an emoji'; Text = ('a' + [char]0xD83D + [char]0xDE00 + 'b') }
        @{ Label = 'a lone high surrogate'; Text = ('a' + [char]0xD800 + 'b') }
        @{ Label = 'a lone low surrogate'; Text = ('a' + [char]0xDC00 + 'b') }
        @{ Label = 'U+0085'; Text = ('a' + [char]0x85 + 'b') }
        @{ Label = 'U+009F'; Text = ('a' + [char]0x9F + 'b') }
        @{ Label = 'U+00A0'; Text = ('a' + [char]0xA0 + 'b') }
        @{ Label = 'a line separator'; Text = ('a' + [char]0x2028 + 'b') }
        @{ Label = 'a byte order mark'; Text = ('a' + [char]0xFEFF + 'b') }
    ) {
        ConvertTo-SwLogValue $Text | Should -BeExactly $Text
    }

    It 'LG-9 gives the empty string for $null and for the empty string, as one value' {
        $nullResult = @(ConvertTo-SwLogValue -Value $null)
        $nullResult.Count | Should -Be 1
        $nullResult[0] | Should -BeExactly ''
        $emptyResult = @(ConvertTo-SwLogValue -Value '')
        $emptyResult.Count | Should -Be 1
        $emptyResult[0] | Should -BeExactly ''
    }

    It 'LG-9 gives one string, not a list, also for text with line breaks' {
        $result = @(ConvertTo-SwLogValue ('a' + [char]10 + 'b' + [char]13 + 'c'))
        $result.Count | Should -Be 1
        $result[0] | Should -BeOfType [string]
    }

    It 'LG-9 leaves no character from U+0000 to U+001F or U+007F in the result for random text' {
        $random = New-Object System.Random 20261028
        $extra = @(0x2028, 0x2029, 0x85, 0x200B, 0xFEFF, 0x4E2D, 0x1B, 0xD800, 0xDC00, 0x0A, 0x0D, 0x09, 0x7F, 0x00)
        for ($n = 0; $n -lt 300; $n++) {
            $length = $random.Next(0, 40)
            $chars = New-Object System.Collections.Generic.List[char]
            for ($i = 0; $i -lt $length; $i++) {
                if ($random.Next(0, 4) -eq 0) { $chars.Add([char]$extra[$random.Next(0, $extra.Count)]) }
                else { $chars.Add([char]$random.Next(0, 256)) }
            }
            $text = -join $chars
            $result = ConvertTo-SwLogValue $text
            $bad = @($result.ToCharArray() | Where-Object { [int]$_ -lt 32 -or [int]$_ -eq 127 })
            $bad.Count | Should -Be 0 -Because "the result of sample $n has no control character"
            $result | Should -BeExactly (Get-Escaped $text) -Because "sample $n is written like the reference"
        }
    }

    It 'LG-9 does not change parentheses itself: only the detail of a record gets brackets' {
        ConvertTo-SwLogValue 'error (5)' | Should -BeExactly 'error (5)'
    }
}

Describe 'Write-SwOperation: path and detail' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        Assert-Defined 'Write-SwOperation', 'ConvertTo-SwLogValue', 'Add-SwOperationText', 'Write-SwDebug'
        Use-Clock
        Use-DebugCapture
        Mock Write-Host { }
    }
    AfterEach { Stop-Case }

    It 'LG-9 writes the control characters of a path as escapes and keeps its parentheses' {
        $path = 'C:\Program Files (x86)\a' + [char]9 + 'b' + [char]10 + 'c' + [char]27
        Write-SwOperation -Action 'REMOVED' -Path $path -Detail 'd'
        $record = Get-OneRecord $script:LogPath
        $record.Groups[5].Value | Should -BeExactly 'C:\Program Files (x86)\a\tb\nc\x1b'
    }

    It 'LG-9 writes parentheses of a detail as brackets: error (5) becomes error [5]' {
        Write-SwOperation -Action 'FAILED' -Path 'C:\a' -Detail 'error (5)'
        @(Get-RecordLines $script:LogPath)[0] | Should -BeExactly '[2026-10-15 10:00:01] [sweepr] FAILED C:\a (error [5])'
        (Get-OneRecord $script:LogPath).Groups[6].Value | Should -BeExactly 'error [5]'
    }

    It 'LG-9 writes - for a detail of <Label>' -ForEach @(
        @{ Label = 'the empty string'; Detail = '' }
        @{ Label = '$null'; Detail = $null }
    ) {
        Write-SwOperation -Action 'REMOVED' -Path 'C:\a' -Detail $Detail
        (Get-OneRecord $script:LogPath).Groups[6].Value | Should -BeExactly '-'
        (Read-SwHistory -Path $script:LogPath).Operations[0].detail | Should -BeExactly ''
    }

    It 'LG-9 keeps a detail that is exactly - as it is' {
        Write-SwOperation -Action 'REMOVED' -Path 'C:\a' -Detail '-'
        (Get-OneRecord $script:LogPath).Groups[6].Value | Should -BeExactly '-'
    }

    It 'LG-9 keeps a detail of white space as white space' {
        Write-SwOperation -Action 'REMOVED' -Path 'C:\a' -Detail '   '
        (Get-OneRecord $script:LogPath).Groups[6].Value | Should -BeExactly '   '
        @(Get-RecordLines $script:LogPath)[0] | Should -BeExactly '[2026-10-15 10:00:01] [sweepr] REMOVED C:\a (   )'
    }

    It 'LG-9 writes the control characters of a detail as escapes' {
        Write-SwOperation -Action 'FAILED' -Path 'C:\a' -Detail ('line1' + [char]13 + [char]10 + 'line2' + [char]0)
        (Get-OneRecord $script:LogPath).Groups[6].Value | Should -BeExactly 'line1\r\nline2\x00'
    }

    It 'LG-9 changes every parenthesis of a detail: (()) becomes [[]]' {
        Write-SwOperation -Action 'FAILED' -Path 'C:\a' -Detail '(())'
        (Get-OneRecord $script:LogPath).Groups[6].Value | Should -BeExactly '[[]]'
    }

    It 'LG-9 leaves non-ASCII text of path and detail unchanged and reads it back' {
        $path = 'C:\Users\Example\' + [char]0xDC + 'bung\' + [char]0x4E2D + [char]0x6587 + '\' + [char]0xD83D + [char]0xDE00
        Write-SwOperation -Action 'REMOVED' -Path $path -Detail ([string][char]0xE4 + 'rger')
        $operation = (Read-SwHistory -Path $script:LogPath).Operations[0]
        $operation.path | Should -BeExactly $path
        $operation.detail | Should -BeExactly ([string][char]0xE4 + 'rger')
    }

    It 'LG-9 keeps the text of the path: <Label>' -ForEach $script:LiteralTexts {
        Set-Env 'ZZ_SWEEPR_LOG_TEST' 'expanded'
        Write-SwOperation -Action 'REMOVED' -Path $Text -Detail 'd'
        (Get-OneRecord $script:LogPath).Groups[5].Value | Should -BeExactly $Text
    }

    It 'S-6 keeps the text of the detail with brackets for parentheses: <Label>' -ForEach $script:LiteralTexts {
        Set-Env 'ZZ_SWEEPR_LOG_TEST' 'expanded'
        Write-SwOperation -Action 'REMOVED' -Path 'C:\a' -Detail $Text
        (Get-OneRecord $script:LogPath).Groups[6].Value | Should -BeExactly (Get-ExpectedDetail $Text)
    }

    It 'LG-9 round-trips random paths and details through the file and Read-SwHistory' {
        $random = New-Object System.Random 20261029
        $pool = @(0..255) + @(0x2028, 0x2029, 0x200B, 0xFEFF, 0x4E2D, 0x1B, 0x0A, 0x0D, 0x09, 0x7F, 0x00, 0x28, 0x29, 0x5B, 0x5D, 0x20, 0x2D)
        $expected = New-Object System.Collections.Generic.List[object]
        for ($n = 0; $n -lt 60; $n++) {
            $path = New-Object System.Text.StringBuilder
            for ($i = 0; $i -lt $random.Next(1, 30); $i++) { [void]$path.Append([char]$pool[$random.Next(0, $pool.Count)]) }
            $detail = New-Object System.Text.StringBuilder
            for ($i = 0; $i -lt $random.Next(0, 20); $i++) { [void]$detail.Append([char]$pool[$random.Next(0, $pool.Count)]) }
            Write-SwOperation -Action 'REMOVED' -Path $path.ToString() -Detail $detail.ToString()
            $wantDetail = Get-ExpectedDetail $detail.ToString()
            if ($wantDetail -ceq '-') { $wantDetail = '' }
            $expected.Add(@{ Path = (Get-Escaped $path.ToString()); Detail = $wantDetail })
        }
        $operations = @((Read-SwHistory -Path $script:LogPath).Operations)
        $operations.Count | Should -Be 60
        for ($n = 0; $n -lt 60; $n++) {
            $operations[$n].path | Should -BeExactly $expected[$n].Path -Because "path of sample $n"
            $operations[$n].detail | Should -BeExactly $expected[$n].Detail -Because "detail of sample $n"
        }
    }
}

# ============================================================================
# Safety invariants of the form
# ============================================================================

Describe 'Write-SwOperation: one line per record' {
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

    It 'S-1 gives a path with <Label> one record and no extra marker' -ForEach $script:ForgeryTexts {
        Write-SwOperation -Action 'REMOVED' -Path $Text -Detail 'd'
        Assert-OnlyRecords $script:LogPath 1 1
        $history = Read-SwHistory -Path $script:LogPath
        @($history.Sessions).Count | Should -Be 1
        $history.Sessions[0].command | Should -BeExactly 'sweepr'
        @($history.Operations).Count | Should -Be 1
    }

    It 'S-1 gives a detail with <Label> one record and no extra marker' -ForEach $script:ForgeryTexts {
        Write-SwOperation -Action 'REMOVED' -Path 'C:\a' -Detail $Text
        Assert-OnlyRecords $script:LogPath 1 1
        @((Read-SwHistory -Path $script:LogPath).Sessions).Count | Should -Be 1
    }

    It 'S-1 keeps the number of lines equal to the number of calls after many hostile values' -ForEach @(, @{ Items = $script:ForgeryTexts }) {
        $calls = 0
        foreach ($item in $Items) {
            Write-SwOperation -Action 'REMOVED' -Path $item.Text -Detail $item.Text
            $calls++
        }
        Assert-OnlyRecords $script:LogPath $calls 1
    }

    It 'S-1 keeps one line per record for random hostile text' {
        $random = New-Object System.Random 20261030
        $pool = @(0..255) + @(0x2028, 0x2029, 0x85, 0xFEFF, 0xD800, 0xDC00)
        for ($n = 0; $n -lt 80; $n++) {
            $path = New-Object System.Text.StringBuilder
            for ($i = 0; $i -lt $random.Next(1, 30); $i++) { [void]$path.Append([char]$pool[$random.Next(0, $pool.Count)]) }
            $detail = New-Object System.Text.StringBuilder
            for ($i = 0; $i -lt $random.Next(0, 30); $i++) { [void]$detail.Append([char]$pool[$random.Next(0, $pool.Count)]) }
            Write-SwOperation -Action 'FAILED' -Path $path.ToString() -Detail $detail.ToString()
        }
        Assert-OnlyRecords $script:LogPath 80 1
    }

    It 'S-2 gives the action no way to forge a record: an action with a line break writes nothing' {
        $forged = 'REMOVED C:\f (1)' + [char]13 + [char]10 + '[2026-01-01 00:00:00] [x] REMOVED'
        Write-SwOperation -Action $forged -Path 'C:\a' -Detail 'd'
        [System.IO.File]::Exists($script:LogPath) | Should -BeFalse
    }

    It 'S-2 gives command and run id no way to forge a label' {
        Set-Env '_SWEEPR_OPLOG_RUN_COMMAND' ('clean] [forged' + [char]13 + [char]10 + '[2026-01-01 00:00:00] [x')
        Set-Env '_SWEEPR_OPLOG_RUN_ID' ('a] [b' + [char]10 + 'c')
        Write-SwOperation -Action 'REMOVED' -Path 'C:\a' -Detail 'd'
        Assert-OnlyRecords $script:LogPath 1 1
        @(Get-RecordLines $script:LogPath)[0] | Should -BeExactly '[2026-10-15 10:00:01] [sweepr] REMOVED C:\a (d)'
    }
}
