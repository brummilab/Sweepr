# Sweepr - tests for `sw history` (lib\core\history.ps1 and bin\history.ps1)
#
# Covers the rules H-1 to H-18 and the safety invariants S1 to S7. The rule
# number is part of every test name.
#
# Interface pinned here:
#   Read-SwHistory -Path <file>                        object with Sessions and Operations, oldest first
#   Format-SwHistoryActions -Actions <actions object>  "removed 1, failed 1" or the hint for a session without actions
#   ConvertTo-SwHistoryJson -History -Limit -LogPath   the JSON document (string)
#   Write-SwHistoryText -History -Limit -LogPath       text on the host (information stream, 6>&1)
#   ConvertTo-SwHistoryLimit -Value <string>           [int] 1..200 or $null
#
# Platform notes:
#   - Function tests and most process tests are platform neutral: fixture logs are plain text files in
#     $TestDrive (Windows paths only as text); the log path is steered with SWEEPR_DATA_DIR.
#   - bin\history.ps1 and the router (sweepr.ps1) run in a child process of the same PowerShell host.
#     The router forms of --limit go through the real router; the other argument shapes call
#     the script directly with named parameters (-Json, -Limit:<value>, -ShowHelp, positional words).
#   - The router creates its own config and cache folders; "creates nothing" is therefore checked on the
#     script (direct call) and, for the router, on the log file and everything below the data folder
#     except those two folders.
#   - Context 'sw history on real Windows' needs Windows semantics (profile and portable data paths with
#     backslashes, share modes, ACLs). These tests belong in tests/linux-known-failures.txt on Linux.

BeforeDiscovery {
    # H-9: lines that are neither a marker nor a record. Each one is skipped silently.
    $script:ForeignLines = @(
        @{ Name = 'lowercase action'; Line = '[2026-10-15 10:00:01] [clean run=a1] removed C:\x (1KB)' }
        @{ Name = 'digit in action'; Line = '[2026-10-15 10:00:01] [clean run=a1] REMOVED2 C:\x (1KB)' }
        @{ Name = 'hyphen in action'; Line = '[2026-10-15 10:00:01] [clean run=a1] RE-MOVED C:\x (1KB)' }
        @{ Name = 'nested parentheses in the detail'; Line = '[2026-10-15 10:00:01] [clean run=a1] REMOVED C:\x (a (b))' }
        @{ Name = 'stray closing parenthesis in the detail'; Line = '[2026-10-15 10:00:01] [clean run=a1] REMOVED C:\x (a)b)' }
        @{ Name = 'no closing group'; Line = '[2026-10-15 10:00:01] [clean run=a1] REMOVED C:\x' }
        @{ Name = 'no path'; Line = '[2026-10-15 10:00:01] [clean run=a1] REMOVED (1KB)' }
        @{ Name = 'truncated record'; Line = '[2026-10-15 10:00:01] [clean run=a1] REMO' }
        @{ Name = 'truncated timestamp'; Line = '[2026-10-15 10:0' }
        @{ Name = 'timestamp with a letter'; Line = '[2026-10-15 1x:00:01] [clean run=a1] REMOVED C:\x (1KB)' }
        @{ Name = 'single digit month'; Line = '[2026-1-5 10:00:01] [clean run=a1] REMOVED C:\x (1KB)' }
        @{ Name = 'timestamp without seconds'; Line = '[2026-10-15 10:00] [clean run=a1] REMOVED C:\x (1KB)' }
        @{ Name = 'empty command'; Line = '[2026-10-15 10:00:01] [] REMOVED C:\x (1KB)' }
        @{ Name = 'command with a space'; Line = '[2026-10-15 10:00:01] [clean up run=a1] REMOVED C:\x (1KB)' }
        @{ Name = 'empty run id'; Line = '[2026-10-15 10:00:01] [clean run=] REMOVED C:\x (1KB)' }
        @{ Name = 'no space after the label'; Line = '[2026-10-15 10:00:01] [clean run=a1]REMOVED C:\x (1KB)' }
        @{ Name = 'plain text'; Line = 'Hello world' }
        @{ Name = 'other comment'; Line = '# this is some other comment' }
        @{ Name = 'blank line'; Line = '' }
        @{ Name = 'spaces only'; Line = '    ' }
        @{ Name = 'marker with a command that has a space'; Line = '# ========== clean up run=a1 session started at 2026-10-15 10:00:00 ==========' }
        @{ Name = 'marker without the closing rule'; Line = '# ========== clean run=a1 session started at 2026-10-15 10:00:00' }
    )

    # H-14: valid and invalid values for ConvertTo-SwHistoryLimit.
    $script:ValidLimits = @(
        @{ Value = '1'; Expected = 1 }
        @{ Value = '20'; Expected = 20 }
        @{ Value = '200'; Expected = 200 }
        @{ Value = '010'; Expected = 10 }
        @{ Value = '001'; Expected = 1 }
        @{ Value = '99'; Expected = 99 }
    )
    $fullwidthFive = [string][char]0xFF15
    $arabicFive = [string][char]0x0665
    $script:InvalidLimits = @(
        @{ Name = 'zero'; Value = '0' }
        @{ Name = 'two hundred and one'; Value = '201' }
        @{ Name = 'one thousand'; Value = '1000' }
        @{ Name = 'four digits with a leading zero'; Value = '0010' }
        @{ Name = 'double zero'; Value = '00' }
        @{ Name = 'minus one'; Value = '-1' }
        @{ Name = 'plus five'; Value = '+5' }
        @{ Name = 'letters'; Value = 'abc' }
        @{ Name = 'empty'; Value = '' }
        @{ Name = 'decimal'; Value = '5.0' }
        @{ Name = 'exponent'; Value = '1e1' }
        @{ Name = 'hex'; Value = '0x10' }
        @{ Name = 'leading space'; Value = ' 5' }
        @{ Name = 'trailing space'; Value = '5 ' }
        @{ Name = 'trailing newline'; Value = "5`n" }
        @{ Name = 'fullwidth digit'; Value = $fullwidthFive }
        @{ Name = 'arabic-indic digit'; Value = $arabicFive }
    )
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:CoreDir = [System.IO.Path]::Combine($script:RepoRoot, 'lib', 'core')
    $script:HistoryModule = [System.IO.Path]::Combine($script:CoreDir, 'history.ps1')
    $script:HistoryScript = [System.IO.Path]::Combine($script:RepoRoot, 'bin', 'history.ps1')
    $script:RouterScript = [System.IO.Path]::Combine($script:RepoRoot, 'sweepr.ps1')
    $script:OnWindows = [System.IO.Path]::DirectorySeparatorChar -eq '\'
    . $script:HistoryModule

    # ---- fixture builders ------------------------------------------------------------------------

    function script:New-Marker([string]$Command, [string]$RunId, [string]$Started) {
        $label = if ($RunId) { "$Command run=$RunId" } else { $Command }
        return "# ========== $label session started at $Started =========="
    }

    function script:New-Record([string]$Time, [string]$Command, [string]$RunId, [string]$Action, [string]$Path, [string]$Detail = '-') {
        $label = if ($RunId) { "$Command run=$RunId" } else { $Command }
        return "[$Time] [$label] $Action $Path ($Detail)"
    }

    function script:Join-LogLines([string[]]$Lines) {
        return (($Lines -join "`r`n") + "`r`n")
    }

    function script:New-DataDir {
        $dir = [System.IO.Path]::Combine($TestDrive, ('data-' + [guid]::NewGuid().ToString('N')))
        [void][System.IO.Directory]::CreateDirectory($dir)
        return $dir
    }

    function script:Get-DataLogPath([string]$DataDir) {
        return [System.IO.Path]::Combine([System.IO.Path]::GetFullPath($DataDir), 'config', 'operations.log')
    }

    function script:Write-FixtureText([string]$Path, [string]$Text, [switch]$Bom) {
        $dir = Split-Path -Parent $Path
        if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
        $encoding = New-Object System.Text.UTF8Encoding ([bool]$Bom)
        [System.IO.File]::WriteAllText($Path, $Text, $encoding)
    }

    # A data folder whose config\operations.log holds the lines (CRLF, UTF-8 without BOM).
    function script:New-LogDataDir([string[]]$Lines) {
        $dir = New-DataDir
        Write-FixtureText -Path (Get-DataLogPath $dir) -Text (Join-LogLines $Lines)
        return $dir
    }

    # A bare log file (for the function tests): returns its path.
    function script:New-LogFile([string[]]$Lines) {
        $path = [System.IO.Path]::Combine($TestDrive, ('log-' + [guid]::NewGuid().ToString('N')), 'operations.log')
        Write-FixtureText -Path $path -Text (Join-LogLines $Lines)
        return $path
    }

    function script:Read-Fixture([string[]]$Lines) {
        return Read-SwHistory -Path (New-LogFile $Lines)
    }

    # Records of two plain REMOVED entries.
    function script:Get-ExampleLines {
        return @(
            ''
            (New-Marker 'clean' 'a1' '2026-10-15 10:00:00')
            (New-Record '2026-10-15 10:00:01' 'clean' 'a1' 'REMOVED' 'C:\Temp\one' '1.0KB')
            (New-Record '2026-10-15 10:00:02' 'clean' 'a1' 'REMOVED' 'C:\Temp\two' '2.0KB')
        )
    }

    # Text of Write-SwHistoryText: information-stream records joined the way a console shows them.
    function script:Get-HistoryText {
        param($History, [int]$Limit = 20, [string]$LogPath = 'C:\Example\config\operations.log')
        $records = @(& { Write-SwHistoryText -History $History -Limit $Limit -LogPath $LogPath } 6>&1)
        $sb = New-Object System.Text.StringBuilder
        foreach ($r in $records) {
            if ($r -is [System.Management.Automation.InformationRecord]) {
                $data = $r.MessageData
                $isHost = $data -is [System.Management.Automation.HostInformationMessage]
                $text = if ($isHost) { $data.Message } else { [string]$data }
                [void]$sb.Append($text)
                if (-not ($isHost -and $data.NoNewLine)) { [void]$sb.Append("`n") }
            }
            else {
                [void]$sb.Append([string]$r)
                [void]$sb.Append("`n")
            }
        }
        return $sb.ToString()
    }

    function script:Get-HistoryJson {
        param($History, [int]$Limit = 20, [string]$LogPath = 'C:\Example\config\operations.log')
        return (ConvertTo-SwHistoryJson -History $History -Limit $Limit -LogPath $LogPath)
    }

    # Everything below a folder: relative path, size, write time and (for files) SHA-256.
    function script:Get-Snapshot([string]$Root, [switch]$FilesOnly) {
        if (-not [System.IO.Directory]::Exists($Root)) { return @('<missing>') }
        $rows = @()
        foreach ($item in @(Get-ChildItem -LiteralPath $Root -Recurse -Force)) {
            $rel = $item.FullName.Substring($Root.Length).TrimStart('\', '/')
            if ($item.PSIsContainer) {
                if (-not $FilesOnly) { $rows += "D $rel" }
            }
            else {
                $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
                $rows += "F $rel $($item.Length) $($item.LastWriteTimeUtc.Ticks) $hash"
            }
        }
        return @($rows | Sort-Object)
    }

    # ---- child processes -------------------------------------------------------------------------

    function script:Invoke-Child {
        param(
            [string[]]$ArgumentList,
            [hashtable]$Environment = @{},
            [string[]]$RemoveEnvironment = @(),
            [string]$WorkingDirectory = $TestDrive
        )
        $exe = (Get-Process -Id $PID).Path
        $quoted = foreach ($a in $ArgumentList) { '"' + ($a -replace '"', '\"') + '"' }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass ' + ($quoted -join ' ')
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
        $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding $false
        $psi.WorkingDirectory = $WorkingDirectory
        $baseline = @('_SWEEPR_OPLOG_RUN_COMMAND', '_SWEEPR_OPLOG_RUN_ID', 'SWEEPR_DEBUG', 'SWEEPR_DRY_RUN', 'SWEEPR_DATA_DIR')
        foreach ($name in @($baseline + $RemoveEnvironment)) {
            if ($psi.EnvironmentVariables.ContainsKey($name)) { $psi.EnvironmentVariables.Remove($name) }
        }
        foreach ($name in $Environment.Keys) { $psi.EnvironmentVariables[$name] = [string]$Environment[$name] }
        $process = [System.Diagnostics.Process]::Start($psi)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { $process.Kill(); throw 'child PowerShell timed out' }
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Out = $stdout.Result; Err = $stderr.Result; Both = ($stdout.Result + "`n" + $stderr.Result) }
    }

    # sweepr.ps1 history ... with the data folder steered by SWEEPR_DATA_DIR.
    function script:Invoke-Router {
        param([string]$DataDir, [string[]]$Words, [hashtable]$Environment = @{}, [string[]]$RemoveEnvironment = @())
        $env2 = @{ SWEEPR_DATA_DIR = $DataDir }
        foreach ($k in $Environment.Keys) { $env2[$k] = $Environment[$k] }
        return Invoke-Child -ArgumentList (@('-File', $script:RouterScript, 'history') + $Words) -Environment $env2 -RemoveEnvironment $RemoveEnvironment
    }

    # bin\history.ps1 called directly with PowerShell source text for its arguments, e.g. "-Json -Limit:'5'".
    function script:Invoke-HistoryScript {
        param(
            [string]$DataDir,
            [string]$ArgText = '',
            [string]$ScriptPath = $script:HistoryScript,
            [hashtable]$Environment = @{},
            [string[]]$RemoveEnvironment = @(),
            [string]$WorkingDirectory = $TestDrive
        )
        $env2 = @{}
        if ($DataDir) { $env2['SWEEPR_DATA_DIR'] = $DataDir }
        foreach ($k in $Environment.Keys) { $env2[$k] = $Environment[$k] }
        $literal = "'" + $ScriptPath.Replace("'", "''") + "'"
        $code = "[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding `$false; & $literal $ArgText; exit `$LASTEXITCODE"
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($code))
        return Invoke-Child -ArgumentList @('-EncodedCommand', $encoded) -Environment $env2 -RemoveEnvironment $RemoveEnvironment -WorkingDirectory $WorkingDirectory
    }

    # Runs source text in a child PowerShell and returns what it printed after the ##RESULT## marker.
    function script:Invoke-ChildCode {
        param([string]$Code, [string]$WorkingDirectory = $TestDrive)
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Code))
        return Invoke-Child -ArgumentList @('-EncodedCommand', $encoded) -WorkingDirectory $WorkingDirectory
    }

    function script:ConvertTo-Literal([string]$Value) { return "'" + $Value.Replace("'", "''") + "'" }

    function script:Get-ErrorFrom([scriptblock]$Block) {
        try { & $Block } catch { return $_ }
        return $null
    }
}

# ====================================================================================================
Describe 'ConvertTo-SwHistoryLimit (H-14)' {
    It 'H-14 accepts <Value> as <Expected>' -ForEach $script:ValidLimits {
        $result = ConvertTo-SwHistoryLimit -Value $Value
        $result | Should -BeOfType [int]
        $result | Should -Be $Expected
    }

    It 'H-14 rejects <Name> with $null' -ForEach $script:InvalidLimits {
        $result = ConvertTo-SwHistoryLimit -Value $Value
        ($null -eq $result) | Should -BeTrue
    }

    It 'H-14 never throws, whatever the value looks like' {
        foreach ($value in @('', ' ', 'abc', '9999999999999999999999', "1`r`n", '1_0', ([string][char]0xFF11), '--limit', '$(exit)', '[1]', '*')) {
            { ConvertTo-SwHistoryLimit -Value $value } | Should -Not -Throw
        }
    }
}

# ====================================================================================================
Describe 'Read-SwHistory: records and markers (H-4 to H-8)' {
    It 'H-4 reads command, run id, action, path and detail of a record' {
        $h = Read-Fixture @((New-Record '2026-10-15 10:00:01' 'clean' 'a1' 'REMOVED' 'C:\Temp\one' '1.0KB'))
        @($h.Operations).Count | Should -Be 1
        $op = @($h.Operations)[0]
        $op.timestamp | Should -Be '2026-10-15 10:00:01'
        $op.command | Should -Be 'clean'
        $op.run_id | Should -Be 'a1'
        $op.action | Should -Be 'removed'
        $op.path | Should -Be 'C:\Temp\one'
        $op.detail | Should -Be '1.0KB'
    }

    It 'H-4 gives an empty run_id for a record without run id' {
        $h = Read-Fixture @('[2026-10-15 10:00:01] [sweepr] REMOVED C:\Temp\x (-)')
        @($h.Operations).Count | Should -Be 1
        @($h.Operations)[0].run_id | Should -Be ''
        @($h.Operations)[0].command | Should -Be 'sweepr'
    }

    It 'H-4 does not check the timestamp numbers for calendar validity' {
        $h = Read-Fixture @('[2026-99-99 99:99:99] [clean run=a1] REMOVED C:\x (1KB)')
        @($h.Operations).Count | Should -Be 1
        @($h.Operations)[0].timestamp | Should -Be '2026-99-99 99:99:99'
    }

    It 'H-4 accepts digits, dots and hyphens in the command and a router style run id' {
        $h = Read-Fixture @('[2026-10-15 10:00:01] [sw-clean.2 run=20261015100000-4242-12345] REMOVED C:\x (1KB)')
        @($h.Operations).Count | Should -Be 1
        @($h.Operations)[0].command | Should -Be 'sw-clean.2'
        @($h.Operations)[0].run_id | Should -Be '20261015100000-4242-12345'
    }

    It 'H-4 accepts any uppercase word as the action and keeps it as lowercase text' {
        $h = Read-Fixture @('[2026-10-15 10:00:01] [clean run=a1] FUTUREWORD C:\x (1KB)')
        @($h.Operations).Count | Should -Be 1
        @($h.Operations)[0].action | Should -Be 'futureword'
    }

    It 'H-5 splits path <Name> from the last parenthesis-free group' -ForEach @(
        @{ Name = 'with parentheses and a plain detail'; Line = '[2026-10-15 11:00:02] [uninstall run=b2] RECYCLED C:\Program Files (x86)\Contoso App (2.0MB)'; Path = 'C:\Program Files (x86)\Contoso App'; Detail = '2.0MB' }
        @{ Name = 'with parentheses and a bracketed detail'; Line = '[2026-10-15 11:00:02] [uninstall run=b2] FAILED C:\Program Files (x86)\App (old) (error [5])'; Path = 'C:\Program Files (x86)\App (old)'; Detail = 'error [5]' }
        @{ Name = 'with a dash detail'; Line = '[2026-10-15 11:00:02] [clean run=a1] REMOVED C:\Temp\x (-)'; Path = 'C:\Temp\x'; Detail = '' }
        @{ Name = 'containing (x) and a dash detail'; Line = '[2026-10-15 11:00:02] [clean run=a1] REMOVED C:\Temp\Some Name (x) (-)'; Path = 'C:\Temp\Some Name (x)'; Detail = '' }
        @{ Name = 'with an unclosed parenthesis'; Line = '[2026-10-15 11:00:02] [clean run=a1] REMOVED C:\Temp\Odd (name (-)'; Path = 'C:\Temp\Odd (name'; Detail = '' }
        @{ Name = 'with a detail that has spaces, semicolons and brackets'; Line = '[2026-10-15 11:00:02] [features run=f1] DISABLED feature:Contoso-Legacy (Disable-WindowsOptionalFeature -Online -FeatureName Contoso-Legacy -NoRestart; restart needed [x])'; Path = 'feature:Contoso-Legacy'; Detail = 'Disable-WindowsOptionalFeature -Online -FeatureName Contoso-Legacy -NoRestart; restart needed [x]' }
    ) {
        $h = Read-Fixture @($Line)
        @($h.Operations).Count | Should -Be 1
        @($h.Operations)[0].path | Should -Be $Path
        @($h.Operations)[0].detail | Should -Be $Detail
    }

    It 'H-6 makes one session per marker and counts the records of each' {
        $h = Read-Fixture @(
            ''
            (New-Marker 'clean' 'a1' '2026-10-15 10:00:00')
            (New-Record '2026-10-15 10:00:01' 'clean' 'a1' 'REMOVED' 'C:\Temp\one' '1KB')
            (New-Record '2026-10-15 10:00:02' 'clean' 'a1' 'REMOVED' 'C:\Temp\two' '1KB')
            (New-Record '2026-10-15 10:00:03' 'clean' 'a1' 'FAILED' 'C:\Temp\three' 'denied')
            ''
            (New-Marker 'uninstall' 'b2' '2026-10-15 11:00:00')
            (New-Record '2026-10-15 11:00:01' 'uninstall' 'b2' 'UNINSTALLED' 'Contoso App' 'exit code 0')
            (New-Record '2026-10-15 11:00:02' 'uninstall' 'b2' 'RECYCLED' 'C:\Program Files (x86)\Contoso App' '2.0MB')
        )
        $s = @($h.Sessions)
        $s.Count | Should -Be 2
        $s[0].command | Should -Be 'clean'
        $s[0].run_id | Should -Be 'a1'
        $s[0].started_at | Should -Be '2026-10-15 10:00:00'
        $s[0].operation_count | Should -Be 3
        $s[1].command | Should -Be 'uninstall'
        $s[1].run_id | Should -Be 'b2'
        $s[1].started_at | Should -Be '2026-10-15 11:00:00'
        $s[1].operation_count | Should -Be 2
        @($h.Operations).Count | Should -Be 5
    }

    It 'H-6 keeps interleaved records of two runs with their own run' {
        $h = Read-Fixture @(
            ''
            (New-Marker 'clean' 'a1' '2026-10-15 10:00:00')
            (New-Marker 'purge' 'b2' '2026-10-15 10:00:00')
            (New-Record '2026-10-15 10:00:01' 'clean' 'a1' 'REMOVED' 'C:\Temp\one' '1KB')
            (New-Record '2026-10-15 10:00:02' 'purge' 'b2' 'RECYCLED' 'C:\Code\x' '1KB')
            (New-Record '2026-10-15 10:00:03' 'clean' 'a1' 'REMOVED' 'C:\Temp\two' '1KB')
        )
        $s = @($h.Sessions)
        $s.Count | Should -Be 2
        $s[0].run_id | Should -Be 'a1'
        $s[0].operation_count | Should -Be 2
        $s[0].actions.removed | Should -Be 2
        $s[0].actions.recycled | Should -Be 0
        $s[1].run_id | Should -Be 'b2'
        $s[1].operation_count | Should -Be 1
        $s[1].actions.recycled | Should -Be 1
    }

    It 'H-6 creates a session from the first record of a run without marker' {
        $h = Read-Fixture @((New-Record '2026-10-15 10:00:01' 'purge' 'c3' 'REMOVED' 'C:\Code\app\node_modules' '5.0MB'))
        $s = @($h.Sessions)
        $s.Count | Should -Be 1
        $s[0].command | Should -Be 'purge'
        $s[0].run_id | Should -Be 'c3'
        $s[0].started_at | Should -Be '2026-10-15 10:00:01'
        $s[0].operation_count | Should -Be 1
    }

    It 'H-6 makes two sessions for the same command with different run ids' {
        $h = Read-Fixture @(
            (New-Record '2026-10-15 10:00:01' 'clean' 'a1' 'REMOVED' 'C:\Temp\one' '1KB')
            (New-Record '2026-10-15 10:00:02' 'clean' 'a2' 'REMOVED' 'C:\Temp\two' '1KB')
        )
        @($h.Sessions).Count | Should -Be 2
    }

    It 'H-6 makes two sessions for the same run id with different commands' {
        $h = Read-Fixture @(
            (New-Record '2026-10-15 10:00:01' 'clean' 'a1' 'REMOVED' 'C:\Temp\one' '1KB')
            (New-Record '2026-10-15 10:00:02' 'purge' 'a1' 'REMOVED' 'C:\Temp\two' '1KB')
        )
        @($h.Sessions).Count | Should -Be 2
    }

    It 'H-6 starts a new session at a second marker with the same command and run id' {
        $h = Read-Fixture @(
            ''
            (New-Marker 'clean' 'a1' '2026-10-15 10:00:00')
            (New-Record '2026-10-15 10:00:01' 'clean' 'a1' 'REMOVED' 'C:\Temp\one' '1KB')
            (New-Record '2026-10-15 10:00:02' 'clean' 'a1' 'REMOVED' 'C:\Temp\two' '1KB')
            ''
            (New-Marker 'clean' 'a1' '2026-10-15 12:00:00')
            (New-Record '2026-10-15 12:00:01' 'clean' 'a1' 'FAILED' 'C:\Temp\three' 'denied')
        )
        $s = @($h.Sessions)
        $s.Count | Should -Be 2
        $s[0].started_at | Should -Be '2026-10-15 10:00:00'
        $s[0].operation_count | Should -Be 2
        $s[0].actions.removed | Should -Be 2
        $s[1].started_at | Should -Be '2026-10-15 12:00:00'
        $s[1].operation_count | Should -Be 1
        $s[1].actions.failed | Should -Be 1
        $s[1].actions.removed | Should -Be 0
    }

    It 'H-6 orders sessions by their position in the log, not by timestamp' {
        $h = Read-Fixture @(
            ''
            (New-Marker 'clean' 'a1' '2026-10-15 12:00:00')
            (New-Record '2026-10-15 12:00:01' 'clean' 'a1' 'REMOVED' 'C:\Temp\one' '1KB')
            ''
            (New-Marker 'purge' 'b2' '2026-10-15 08:00:00')
            (New-Record '2026-10-15 08:00:01' 'purge' 'b2' 'REMOVED' 'C:\Temp\two' '1KB')
        )
        @($h.Sessions)[0].run_id | Should -Be 'a1'
        @($h.Sessions)[1].run_id | Should -Be 'b2'
    }

    It 'H-6 puts a session created by a markerless record at the position of that record' {
        $h = Read-Fixture @(
            ''
            (New-Marker 'clean' 'a1' '2026-10-15 10:00:00')
            (New-Record '2026-10-15 10:00:01' 'purge' 'c3' 'REMOVED' 'C:\Code\x' '1KB')
            (New-Record '2026-10-15 10:00:02' 'clean' 'a1' 'REMOVED' 'C:\Temp\one' '1KB')
            ''
            (New-Marker 'uninstall' 'b2' '2026-10-15 11:00:00')
        )
        $ids = @(@($h.Sessions) | ForEach-Object { $_.run_id })
        ($ids -join ',') | Should -Be 'a1,c3,b2'
    }

    It 'H-7 reads a marker without records as a session with count 0 and all counters 0' {
        $h = Read-Fixture @('', (New-Marker 'clean' 'a1' '2026-10-15 10:00:00'))
        $s = @($h.Sessions)
        $s.Count | Should -Be 1
        $s[0].command | Should -Be 'clean'
        $s[0].run_id | Should -Be 'a1'
        $s[0].started_at | Should -Be '2026-10-15 10:00:00'
        $s[0].operation_count | Should -Be 0
        foreach ($name in @('removed', 'recycled', 'uninstalled', 'disabled', 'restored', 'skipped', 'failed', 'other')) {
            $s[0].actions.$name | Should -Be 0
        }
        @($h.Operations).Count | Should -Be 0
    }

    It 'H-7 takes the start text of a marker unchanged and allows a marker without run id' {
        $h = Read-Fixture @('', (New-Marker 'sweepr' '' 'yesterday around noon'))
        $s = @($h.Sessions)
        $s.Count | Should -Be 1
        $s[0].command | Should -Be 'sweepr'
        $s[0].run_id | Should -Be ''
        $s[0].started_at | Should -Be 'yesterday around noon'
    }

    It 'H-8 counts each action word in its own counter' {
        $h = Read-Fixture @(
            ''
            (New-Marker 'clean' 'a1' '2026-10-15 10:00:00')
            (New-Record '2026-10-15 10:00:01' 'clean' 'a1' 'REMOVED' 'C:\a' '1KB')
            (New-Record '2026-10-15 10:00:02' 'clean' 'a1' 'FAILED' 'C:\b' 'x')
            (New-Record '2026-10-15 10:00:03' 'clean' 'a1' 'SKIPPED' 'C:\c' 'x')
        )
        $a = @($h.Sessions)[0].actions
        $a.removed | Should -Be 1
        $a.failed | Should -Be 1
        $a.skipped | Should -Be 1
        $a.other | Should -Be 0
        $a.recycled | Should -Be 0
    }

    It 'H-8 counts features removed, disabled, failed and skipped one each' {
        $h = Read-Fixture @(
            ''
            (New-Marker 'features' 'f1' '2026-10-25 10:00:00')
            (New-Record '2026-10-25 10:00:01' 'features' 'f1' 'REMOVED' 'appx:Contoso.Example_2.5.0.0_x64__examplepublisher' 'Remove-AppxPackage -Package Contoso.Example_2.5.0.0_x64__examplepublisher')
            (New-Record '2026-10-25 10:00:02' 'features' 'f1' 'DISABLED' 'feature:Contoso-Legacy' 'Disable-WindowsOptionalFeature -Online -FeatureName Contoso-Legacy -NoRestart; restart needed')
            (New-Record '2026-10-25 10:00:03' 'features' 'f1' 'FAILED' 'appx:Contoso.Broken_1.0.0.0_x64__examplepublisher' 'denied')
            (New-Record '2026-10-25 10:00:04' 'features' 'f1' 'SKIPPED' 'feature:Contoso-Other' 'not installed')
        )
        $s = @($h.Sessions)[0]
        $s.actions.removed | Should -Be 1
        $s.actions.disabled | Should -Be 1
        $s.actions.failed | Should -Be 1
        $s.actions.skipped | Should -Be 1
        $s.actions.other | Should -Be 0
        $s.operation_count | Should -Be 4
        @($h.Operations)[0].path | Should -Be 'appx:Contoso.Example_2.5.0.0_x64__examplepublisher'
        @($h.Operations)[1].path | Should -Be 'feature:Contoso-Legacy'
    }

    It 'H-8 counts restored, failed and skipped from a features restore run' {
        $h = Read-Fixture @(
            ''
            (New-Marker 'features' 'r1' '2026-10-26 09:00:00')
            (New-Record '2026-10-26 09:00:01' 'features' 'r1' 'RESTORED' 'feature:Contoso-Legacy' 'Enable-WindowsOptionalFeature')
            (New-Record '2026-10-26 09:00:02' 'features' 'r1' 'RESTORED' 'feature:Contoso-Other' 'Enable-WindowsOptionalFeature')
            (New-Record '2026-10-26 09:00:03' 'features' 'r1' 'FAILED' 'appx:Contoso.Example' 'denied')
            (New-Record '2026-10-26 09:00:04' 'features' 'r1' 'SKIPPED' 'appx:Contoso.Other' 'gone')
        )
        $a = @($h.Sessions)[0].actions
        $a.restored | Should -Be 2
        $a.failed | Should -Be 1
        $a.skipped | Should -Be 1
        $a.removed | Should -Be 0
        $a.other | Should -Be 0
    }

    It 'H-8 counts recycled and uninstalled separately from removed' {
        $h = Read-Fixture @(
            (New-Record '2026-10-15 11:00:01' 'uninstall' 'b2' 'UNINSTALLED' 'Contoso App' 'exit code 0')
            (New-Record '2026-10-15 11:00:02' 'uninstall' 'b2' 'RECYCLED' 'C:\Program Files (x86)\Contoso App' '2.0MB')
        )
        $a = @($h.Sessions)[0].actions
        $a.uninstalled | Should -Be 1
        $a.recycled | Should -Be 1
        $a.removed | Should -Be 0
    }

    It 'H-8 counts OPTIMIZED, OWNER and unknown words as other and lowercases the action' {
        $h = Read-Fixture @(
            (New-Record '2026-10-15 10:00:01' 'optimize' 'o1' 'OPTIMIZED' 'dns-cache' 'flushed')
            (New-Record '2026-10-15 10:00:02' 'clean' 'o1' 'OWNER' 'C:\Example\npm' 'npm cache clean')
            (New-Record '2026-10-15 10:00:03' 'optimize' 'o1' 'SOMETHINGNEW' 'x' 'y')
        )
        @($h.Operations)[0].action | Should -Be 'optimized'
        @($h.Operations)[1].action | Should -Be 'owner'
        @($h.Operations)[2].action | Should -Be 'somethingnew'
        (@($h.Sessions) | ForEach-Object { $_.actions.other } | Measure-Object -Sum).Sum | Should -Be 3
        (@($h.Sessions) | ForEach-Object { $_.actions.removed } | Measure-Object -Sum).Sum | Should -Be 0
    }

    It 'H-8 reports zero, not missing, for counters a command never wrote' {
        $h = Read-Fixture @((New-Record '2026-10-15 10:00:01' 'clean' 'a1' 'REMOVED' 'C:\a' '1KB'))
        $a = @($h.Sessions)[0].actions
        foreach ($name in @('removed', 'recycled', 'uninstalled', 'disabled', 'restored', 'skipped', 'failed', 'other')) {
            ($null -ne $a.$name) | Should -BeTrue
            $a.$name | Should -BeOfType [int]
        }
        $a.disabled | Should -Be 0
        $a.restored | Should -Be 0
    }

    It 'H-8 counts appx-provisioned paths like any other path and keeps appx and feature identifiers unchanged' {
        $h = Read-Fixture @(
            (New-Record '2026-10-15 10:00:01' 'features' 'f1' 'REMOVED' 'appx-provisioned:Contoso.Example_1.0.0.0_neutral_~_examplepublisher' 'DISM')
            (New-Record '2026-10-15 10:00:02' 'features' 'f1' 'REMOVED' 'appx:Contoso.Example_1.0.0.0_x64__examplepublisher' 'Remove-AppxPackage')
        )
        @($h.Sessions)[0].actions.removed | Should -Be 2
        @($h.Operations)[0].path | Should -Be 'appx-provisioned:Contoso.Example_1.0.0.0_neutral_~_examplepublisher'
        @($h.Operations)[1].path | Should -Be 'appx:Contoso.Example_1.0.0.0_x64__examplepublisher'
    }

    It 'H-8 makes the counters of every session add up to its operation count' {
        $words = @('REMOVED', 'RECYCLED', 'UNINSTALLED', 'DISABLED', 'RESTORED', 'SKIPPED', 'FAILED', 'OPTIMIZED', 'OWNER', 'MYSTERY')
        $lines = @('', (New-Marker 'clean' 'a1' '2026-10-15 10:00:00'))
        $n = 0
        foreach ($w in $words) {
            foreach ($i in 1..($n % 3 + 1)) { $lines += (New-Record '2026-10-15 10:00:01' 'clean' 'a1' $w "C:\Temp\$w$i" '1KB'); $n++ }
        }
        $lines += (New-Record '2026-10-15 10:00:02' 'purge' 'p1' 'REMOVED' 'C:\Code\x' '1KB')
        $h = Read-Fixture $lines
        foreach ($s in @($h.Sessions)) {
            $a = $s.actions
            ($a.removed + $a.recycled + $a.uninstalled + $a.disabled + $a.restored + $a.skipped + $a.failed + $a.other) | Should -Be $s.operation_count
        }
        @($h.Sessions)[0].operation_count | Should -Be $n
    }
}

# ====================================================================================================
Describe 'Read-SwHistory: missing, foreign and broken input (H-3, H-9, H-10, H-11, S3, S5)' {
    It 'H-3 returns empty Sessions and Operations for a missing file without an error' {
        $path = [System.IO.Path]::Combine($TestDrive, 'no-such-folder', 'operations.log')
        $h = Read-SwHistory -Path $path
        ($null -ne $h.Sessions) | Should -BeTrue
        ($null -ne $h.Operations) | Should -BeTrue
        @($h.Sessions).Count | Should -Be 0
        @($h.Operations).Count | Should -Be 0
        [System.IO.File]::Exists($path) | Should -BeFalse
        [System.IO.Directory]::Exists((Split-Path -Parent $path)) | Should -BeFalse
    }

    It 'H-3 returns empty results for an empty file' {
        $path = [System.IO.Path]::Combine($TestDrive, 'empty-log', 'operations.log')
        Write-FixtureText -Path $path -Text ''
        $h = Read-SwHistory -Path $path
        @($h.Sessions).Count | Should -Be 0
        @($h.Operations).Count | Should -Be 0
    }

    It 'H-3 returns empty results for a file with only blank lines and foreign lines' {
        $h = Read-Fixture @('', '   ', 'Hello world', '# just a comment', '[2026-10-15 10:00:01] [clean run=a1] removed C:\x (1KB)')
        ($null -ne $h.Sessions) | Should -BeTrue
        @($h.Sessions).Count | Should -Be 0
        @($h.Operations).Count | Should -Be 0
    }

    It 'H-9 skips <Name> and reads the lines around it' -ForEach $script:ForeignLines {
        $before = New-Record '2026-10-15 10:00:00' 'clean' 'a1' 'REMOVED' 'C:\Temp\before' '1KB'
        $after = New-Record '2026-10-15 10:00:02' 'clean' 'a1' 'FAILED' 'C:\Temp\after' 'denied'
        $h = Read-Fixture @($before, $Line, $after)
        @($h.Operations).Count | Should -Be 2
        @($h.Operations)[0].path | Should -Be 'C:\Temp\before'
        @($h.Operations)[1].path | Should -Be 'C:\Temp\after'
        @($h.Sessions).Count | Should -Be 1
        @($h.Sessions)[0].operation_count | Should -Be 2
        @($h.Sessions)[0].actions.removed | Should -Be 1
        @($h.Sessions)[0].actions.failed | Should -Be 1
        @($h.Sessions)[0].actions.other | Should -Be 0
    }

    It 'H-9 makes no session and no operation from <Name> alone' -ForEach $script:ForeignLines {
        $h = Read-Fixture @($Line)
        @($h.Sessions).Count | Should -Be 0
        @($h.Operations).Count | Should -Be 0
    }

    It 'H-9 keeps Hello world in the middle of a log harmless for the rest' {
        $h = Read-Fixture @(
            ''
            (New-Marker 'clean' 'a1' '2026-10-15 10:00:00')
            (New-Record '2026-10-15 10:00:01' 'clean' 'a1' 'REMOVED' 'C:\Temp\one' '1KB')
            'Hello world'
            (New-Record '2026-10-15 10:00:02' 'clean' 'a1' 'REMOVED' 'C:\Temp\two' '1KB')
        )
        @($h.Sessions).Count | Should -Be 1
        @($h.Sessions)[0].operation_count | Should -Be 2
    }

    It 'H-10 keeps backslash-n, backslash-t and backslash-x escapes as two or four characters of text' {
        $h = Read-Fixture @(
            '[2026-10-15 10:00:01] [clean run=a1] REMOVED C:\Temp\a\nb (1KB)'
            '[2026-10-15 10:00:02] [clean run=a1] REMOVED C:\Temp\a\tb (x\ry)'
            '[2026-10-15 10:00:03] [clean run=a1] REMOVED C:\Temp\\x1b[31mred (esc \x1b here)'
        )
        $ops = @($h.Operations)
        $ops.Count | Should -Be 3
        $ops[0].path | Should -Be 'C:\Temp\a\nb'
        $ops[0].path.Length | Should -Be 'C:\Temp\a\nb'.Length
        $ops[1].path | Should -Be 'C:\Temp\a\tb'
        $ops[1].detail | Should -Be 'x\ry'
        $ops[2].path | Should -Be 'C:\Temp\\x1b[31mred'
        $ops[2].detail | Should -Be 'esc \x1b here'
        foreach ($op in $ops) {
            $op.path | Should -Not -Match '[\x00-\x1f\x7f]'
            $op.detail | Should -Not -Match '[\x00-\x1f\x7f]'
        }
    }

    It 'H-10 keeps marker text inside a path a record and makes no session from it' {
        $evil = '# ========== x run=y session started at z =========='
        $h = Read-Fixture @("[2026-10-15 10:00:01] [clean run=a1] REMOVED C:\Temp\$evil (1KB)")
        @($h.Operations).Count | Should -Be 1
        @($h.Operations)[0].path | Should -Be "C:\Temp\$evil"
        @($h.Sessions).Count | Should -Be 1
        @($h.Sessions)[0].command | Should -Be 'clean'
        @($h.Sessions) | Where-Object { $_.command -eq 'x' } | Should -BeNullOrEmpty
    }

    It 'H-10 judges a record split across two real lines as two foreign lines' {
        $h = Read-Fixture @(
            '[2026-10-15 10:00:01] [clean run=a1] REMOVED C:\Temp\a'
            'b (1KB)'
        )
        @($h.Operations).Count | Should -Be 0
        @($h.Sessions).Count | Should -Be 0
    }

    It 'H-11 recognises a first line that starts with a UTF-8 BOM' {
        $path = [System.IO.Path]::Combine($TestDrive, 'bom-log', 'operations.log')
        Write-FixtureText -Path $path -Text (Join-LogLines @((New-Record '2026-10-15 10:00:01' 'clean' 'a1' 'REMOVED' 'C:\Temp\one' '1KB'))) -Bom
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes[0] | Should -Be 0xEF
        $h = Read-SwHistory -Path $path
        @($h.Operations).Count | Should -Be 1
        @($h.Operations)[0].timestamp | Should -Be '2026-10-15 10:00:01'
        @($h.Operations)[0].command | Should -Be 'clean'
    }

    It 'H-11 recognises a marker on the first line after a BOM' {
        $path = [System.IO.Path]::Combine($TestDrive, 'bom-marker', 'operations.log')
        Write-FixtureText -Path $path -Text (Join-LogLines @((New-Marker 'clean' 'a1' '2026-10-15 10:00:00'))) -Bom
        $h = Read-SwHistory -Path $path
        @($h.Sessions).Count | Should -Be 1
        @($h.Sessions)[0].started_at | Should -Be '2026-10-15 10:00:00'
    }

    It 'H-11 reads LF, CRLF and CR line endings alike' {
        $lines = @(
            (New-Record '2026-10-15 10:00:01' 'clean' 'a1' 'REMOVED' 'C:\Temp\one' '1KB')
            (New-Record '2026-10-15 10:00:02' 'clean' 'a1' 'REMOVED' 'C:\Temp\two' '2KB')
            (New-Record '2026-10-15 10:00:03' 'clean' 'a1' 'FAILED' 'C:\Temp\three' 'denied')
        )
        foreach ($eol in @("`r`n", "`n", "`r")) {
            $path = [System.IO.Path]::Combine($TestDrive, ('eol-' + [guid]::NewGuid().ToString('N')), 'operations.log')
            Write-FixtureText -Path $path -Text (($lines -join $eol) + $eol)
            $h = Read-SwHistory -Path $path
            @($h.Operations).Count | Should -Be 3
            @($h.Operations)[2].path | Should -Be 'C:\Temp\three'
            @($h.Operations)[1].detail | Should -Be '2KB'
        }
    }

    It 'H-11 reads a log that mixes line endings' {
        $path = [System.IO.Path]::Combine($TestDrive, 'mixed-eol', 'operations.log')
        $text = (New-Record '2026-10-15 10:00:01' 'clean' 'a1' 'REMOVED' 'C:\Temp\one' '1KB') + "`n" +
        (New-Record '2026-10-15 10:00:02' 'clean' 'a1' 'REMOVED' 'C:\Temp\two' '2KB') + "`r`n"
        Write-FixtureText -Path $path -Text $text
        @((Read-SwHistory -Path $path).Operations).Count | Should -Be 2
    }

    It 'H-11 keeps umlauts and CJK characters in paths' {
        $umlaut = 'C:\Users\Example\' + [char]0x00DC + 'bung'
        $cjk = 'C:\Users\Example\' + [char]0x65E5 + [char]0x672C + [char]0x8A9E
        $h = Read-Fixture @(
            (New-Record '2026-10-15 10:00:01' 'clean' 'a1' 'REMOVED' $umlaut '1KB')
            (New-Record '2026-10-15 10:00:02' 'clean' 'a1' 'REMOVED' $cjk '1KB')
        )
        @($h.Operations)[0].path | Should -Be $umlaut
        @($h.Operations)[1].path | Should -Be $cjk
    }

    It 'H-11 does not fail on invalid UTF-8 byte sequences and still reads the other lines' {
        $path = [System.IO.Path]::Combine($TestDrive, 'invalid-utf8', 'operations.log')
        $dir = Split-Path -Parent $path
        [void][System.IO.Directory]::CreateDirectory($dir)
        $enc = New-Object System.Text.UTF8Encoding $false
        $bytes = New-Object System.Collections.Generic.List[byte]
        $bytes.AddRange($enc.GetBytes("[2026-10-15 10:00:01] [clean run=a1] REMOVED C:\Temp\bad"))
        $bytes.Add(0xC3); $bytes.Add(0x28)
        $bytes.AddRange($enc.GetBytes(" (1KB)`r`n"))
        $bytes.AddRange($enc.GetBytes("[2026-10-15 10:00:02] [clean run=a1] REMOVED C:\Temp\good (1KB)`r`n"))
        [System.IO.File]::WriteAllBytes($path, $bytes.ToArray())
        $h = Read-SwHistory -Path $path
        @($h.Operations).Count | Should -BeGreaterOrEqual 1
        @($h.Operations)[-1].path | Should -Be 'C:\Temp\good'
    }

    It 'S5 survives pseudo-random binary content and returns arrays' {
        $path = [System.IO.Path]::Combine($TestDrive, 'junk-log', 'operations.log')
        [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        $rng = New-Object System.Random 4711
        $junk = New-Object byte[] 65536
        $rng.NextBytes($junk)
        [System.IO.File]::WriteAllBytes($path, $junk)
        $h = Read-SwHistory -Path $path
        ($null -ne $h.Sessions) | Should -BeTrue
        ($null -ne $h.Operations) | Should -BeTrue
    }

    It 'S5 reads a very long unterminated line quickly and keeps the records around it' {
        $long = '[2026-10-15 10:00:01] [clean run=a1] REMOVED ' + ('a (b ' * 40000)
        $lines = @(
            (New-Record '2026-10-15 10:00:00' 'clean' 'a1' 'REMOVED' 'C:\Temp\before' '1KB')
            $long
            (New-Record '2026-10-15 10:00:02' 'clean' 'a1' 'REMOVED' 'C:\Temp\after' '1KB')
        )
        $path = New-LogFile $lines
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $h = Read-SwHistory -Path $path
        $sw.Stop()
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 20
        @($h.Operations).Count | Should -Be 2
    }

    It 'S5 recognises a record with a very long path' {
        $longPath = 'C:\Temp\' + ('x' * 100000)
        $h = Read-Fixture @((New-Record '2026-10-15 10:00:01' 'clean' 'a1' 'REMOVED' $longPath '1KB'))
        @($h.Operations).Count | Should -Be 1
        @($h.Operations)[0].path.Length | Should -Be $longPath.Length
    }

    It 'S5 counts a record only in the session named by its own line, even when the path imitates another record' {
        $imitation = 'C:\a [2026-10-15 10:00:00] [clean run=a1] FAILED C:\b (x)'
        $h = Read-Fixture @(
            ''
            (New-Marker 'clean' 'a1' '2026-10-15 10:00:00')
            (New-Record '2026-10-15 10:00:01' 'clean' 'a1' 'REMOVED' 'C:\Temp\one' '1KB')
            ''
            (New-Marker 'uninstall' 'b2' '2026-10-15 11:00:00')
            (New-Record '2026-10-15 11:00:01' 'uninstall' 'b2' 'REMOVED' $imitation 'y')
        )
        $s = @($h.Sessions)
        $s.Count | Should -Be 2
        $s[0].operation_count | Should -Be 1
        $s[0].actions.failed | Should -Be 0
        $s[1].operation_count | Should -Be 1
        $s[1].actions.removed | Should -Be 1
        $s[1].actions.failed | Should -Be 0
        @($h.Operations)[1].path | Should -Be $imitation
        @($h.Operations)[1].detail | Should -Be 'y'
    }

    It 'S3 treats paths and details as plain text and never runs, resolves or fetches them' {
        $marker = [System.IO.Path]::Combine($TestDrive, 'S3-marker-' + [guid]::NewGuid().ToString('N'))
        $victim = [System.IO.Path]::Combine($TestDrive, 'victim-' + [guid]::NewGuid().ToString('N') + '.txt')
        [System.IO.File]::WriteAllText($victim, 'keep')
        $evilPath = '$(New-Item -ItemType File -Path ' + $marker + ' -Force)'
        $evilDetail = "'; New-Item -ItemType File -Path $marker -Force; '"
        Mock Invoke-Expression { throw 'S3: Invoke-Expression was called' }
        Mock Invoke-WebRequest { throw 'S3: network access' }
        Mock Invoke-RestMethod { throw 'S3: network access' }
        Mock Start-Process { throw 'S3: process start' }
        $h = Read-Fixture @(
            (New-Record '2026-10-15 10:00:01' 'clean' 'a1' 'REMOVED' $evilPath $evilDetail.Replace('(', '[').Replace(')', ']'))
            (New-Record '2026-10-15 10:00:02' 'clean' 'a1' 'REMOVED' $victim '1KB')
            (New-Record '2026-10-15 10:00:03' 'clean' 'a1' 'REMOVED' 'C:\Temp\*[abc]?' '1KB')
            (New-Record '2026-10-15 10:00:04' 'clean' 'a1' 'REMOVED' 'https://example.invalid/x' '1KB')
        )
        $null = Get-HistoryJson -History $h
        $null = Get-HistoryText -History $h
        @($h.Operations).Count | Should -Be 4
        @($h.Operations)[0].path | Should -Be $evilPath
        @($h.Operations)[2].path | Should -Be 'C:\Temp\*[abc]?'
        [System.IO.File]::Exists($marker) | Should -BeFalse
        [System.IO.File]::ReadAllText($victim) | Should -Be 'keep'
        Should -Invoke Invoke-Expression -Exactly -Times 0 -Scope It
        Should -Invoke Invoke-WebRequest -Exactly -Times 0 -Scope It
        Should -Invoke Invoke-RestMethod -Exactly -Times 0 -Scope It
        Should -Invoke Start-Process -Exactly -Times 0 -Scope It
    }
}

# ====================================================================================================
Describe 'Read-SwHistory: one file only, read only, no lock (H-1, H-2, H-12, S1, S6, S7)' {
    It 'H-1 never reads operations.log.old next to the log' {
        $path = New-LogFile @((New-Record '2026-10-15 10:00:01' 'clean' 'a1' 'REMOVED' 'C:\Temp\current' '1KB'))
        Write-FixtureText -Path "$path.old" -Text (Join-LogLines @(
                ''
                (New-Marker 'purge' 'old1' '2026-09-01 10:00:00')
                (New-Record '2026-09-01 10:00:01' 'purge' 'old1' 'REMOVED' 'C:\Temp\ancient' '1KB')))
        $h = Read-SwHistory -Path $path
        @($h.Operations).Count | Should -Be 1
        @($h.Operations)[0].path | Should -Be 'C:\Temp\current'
        @($h.Sessions).Count | Should -Be 1
        @($h.Sessions)[0].run_id | Should -Be 'a1'
    }

    It 'S7 reads nothing but the file it is given' {
        $path = New-LogFile @((New-Record '2026-10-15 10:00:01' 'clean' 'a1' 'REMOVED' 'C:\Temp\current' '1KB'))
        $dir = Split-Path -Parent $path
        foreach ($other in @('sweepr_debug_session.log', 'features-removed.json', 'operations.log.old', 'operations.log.bak', 'other.log')) {
            Write-FixtureText -Path ([System.IO.Path]::Combine($dir, $other)) -Text (Join-LogLines @((New-Record '2026-09-01 10:00:01' 'purge' 'x9' 'REMOVED' "C:\Temp\from-$other" '1KB')))
        }
        $h = Read-SwHistory -Path $path
        @($h.Operations).Count | Should -Be 1
        @($h.Operations)[0].path | Should -Be 'C:\Temp\current'
    }

    It 'H-2 leaves the log byte-identical, keeps its write time and creates no file' {
        $path = New-LogFile (Get-ExampleLines)
        $dir = Split-Path -Parent $path
        $bytesBefore = [System.IO.File]::ReadAllBytes($path)
        $timeBefore = [System.IO.File]::GetLastWriteTimeUtc($path)
        $snapBefore = Get-Snapshot -Root $dir
        $h = Read-SwHistory -Path $path
        $null = Get-HistoryJson -History $h -LogPath $path
        $null = Get-HistoryText -History $h -LogPath $path
        $null = Format-SwHistoryActions -Actions @($h.Sessions)[0].actions
        $bytesAfter = [System.IO.File]::ReadAllBytes($path)
        $bytesAfter.Length | Should -Be $bytesBefore.Length
        ([System.BitConverter]::ToString($bytesAfter)) | Should -Be ([System.BitConverter]::ToString($bytesBefore))
        [System.IO.File]::GetLastWriteTimeUtc($path) | Should -Be $timeBefore
        (Get-Snapshot -Root $dir) -join "`n" | Should -Be ($snapBefore -join "`n")
    }

    It 'H-2 creates neither folder nor file when the log is missing' {
        $root = New-DataDir
        $path = [System.IO.Path]::Combine($root, 'config', 'operations.log')
        $h = Read-SwHistory -Path $path
        $null = Get-HistoryJson -History $h -LogPath $path
        $null = Get-HistoryText -History $h -LogPath $path
        @(Get-ChildItem -LiteralPath $root -Force -Recurse).Count | Should -Be 0
    }

    It 'S1 never calls the write functions of the log module while reading and formatting' {
        . ([System.IO.Path]::Combine($script:CoreDir, 'base.ps1'))
        . ([System.IO.Path]::Combine($script:CoreDir, 'log.ps1'))
        Mock Write-SweeprOperation { }
        Mock Add-SweeprOperationText { }
        $path = New-LogFile (Get-ExampleLines)
        $h = Read-SwHistory -Path $path
        $null = Get-HistoryJson -History $h -LogPath $path
        $null = Get-HistoryText -History $h -LogPath $path
        Should -Invoke Write-SweeprOperation -Exactly -Times 0 -Scope It
        Should -Invoke Add-SweeprOperationText -Exactly -Times 0 -Scope It
    }

    It 'H-12 throws, and names a real error, when the log path is a folder' {
        $path = [System.IO.Path]::Combine($TestDrive, 'folder-log', 'operations.log')
        [void][System.IO.Directory]::CreateDirectory($path)
        $err = Get-ErrorFrom { $null = Read-SwHistory -Path $path }
        ($null -ne $err) | Should -BeTrue
        $err | Should -BeOfType ([System.Management.Automation.ErrorRecord])
        $err.Exception | Should -Not -BeOfType ([System.Management.Automation.CommandNotFoundException])
        $err.FullyQualifiedErrorId | Should -Not -Match 'CommandNotFound'
    }

    It 'H-12 does not return an empty history for a log that exists but cannot be read' {
        $path = [System.IO.Path]::Combine($TestDrive, 'folder-log-2', 'operations.log')
        [void][System.IO.Directory]::CreateDirectory($path)
        $script:result = $null
        $err = Get-ErrorFrom { $script:result = Read-SwHistory -Path $path }
        ($null -ne $err) | Should -BeTrue
        ($null -eq $script:result) | Should -BeTrue
        $err.FullyQualifiedErrorId | Should -Not -Match 'CommandNotFound'
    }

    It 'S6 closes the log after reading so that a writer can append and open it exclusively' {
        $path = New-LogFile (Get-ExampleLines)
        $null = Read-SwHistory -Path $path
        $enc = New-Object System.Text.UTF8Encoding $false
        { [System.IO.File]::AppendAllText($path, "`r`n# appended after the read`r`n", $enc) } | Should -Not -Throw
        $stream = $null
        try {
            { $script:stream = [System.IO.File]::Open($path, 'Open', 'ReadWrite', 'None') } | Should -Not -Throw
        }
        finally { if ($script:stream) { $script:stream.Dispose() } }
    }
}

# ====================================================================================================
Describe 'Format-SwHistoryActions (H-7, H-8, H-17)' {
    It 'H-17 shows only disabled 1 for a session with one DISABLED record' {
        $h = Read-Fixture @((New-Record '2026-10-25 10:00:02' 'features' 'f1' 'DISABLED' 'feature:Contoso-Legacy' 'x'))
        $text = Format-SwHistoryActions -Actions @($h.Sessions)[0].actions
        $text | Should -BeExactly 'disabled 1'
    }

    It 'H-17 joins removed 1, failed 1 with a comma and a space and leaves out zero counters' {
        $h = Read-Fixture @(
            (New-Record '2026-10-15 10:00:01' 'clean' 'a1' 'REMOVED' 'C:\a' '1KB')
            (New-Record '2026-10-15 10:00:02' 'clean' 'a1' 'FAILED' 'C:\b' 'x')
        )
        Format-SwHistoryActions -Actions @($h.Sessions)[0].actions | Should -BeExactly 'removed 1, failed 1'
    }

    It 'H-17 lists the actions in the fixed order removed, recycled, uninstalled, disabled, restored, skipped, failed, other' {
        $words = @('OPTIMIZED', 'FAILED', 'SKIPPED', 'RESTORED', 'DISABLED', 'UNINSTALLED', 'RECYCLED', 'REMOVED')
        $lines = @()
        for ($i = 0; $i -lt $words.Count; $i++) {
            foreach ($j in 1..($i + 1)) { $lines += (New-Record '2026-10-15 10:00:01' 'clean' 'a1' $words[$i] "C:\Temp\$($words[$i])$j" '1KB') }
        }
        $h = Read-Fixture $lines
        Format-SwHistoryActions -Actions @($h.Sessions)[0].actions | Should -BeExactly 'removed 8, recycled 7, uninstalled 6, disabled 5, restored 4, skipped 3, failed 2, other 1'
    }

    It 'H-17 writes restored 2 for two RESTORED records' {
        $h = Read-Fixture @(
            (New-Record '2026-10-26 09:00:01' 'features' 'r1' 'RESTORED' 'feature:A' 'x')
            (New-Record '2026-10-26 09:00:02' 'features' 'r1' 'RESTORED' 'feature:B' 'x')
        )
        Format-SwHistoryActions -Actions @($h.Sessions)[0].actions | Should -BeExactly 'restored 2'
    }

    It 'H-7 gives a hint without any action name or number for a session with only zero counters' {
        $h = Read-Fixture @('', (New-Marker 'clean' 'a1' '2026-10-15 10:00:00'))
        $text = Format-SwHistoryActions -Actions @($h.Sessions)[0].actions
        $text | Should -BeOfType [string]
        $text.Trim() | Should -Not -BeNullOrEmpty
        $text | Should -Not -Match '(removed|recycled|uninstalled|disabled|restored|skipped|failed|other)\s+\d'
        $text | Should -Not -Match '\d'
    }
}

# ====================================================================================================
Describe 'ConvertTo-SwHistoryJson (H-13, H-16, H-11, S4)' {
    BeforeAll {
        $script:ExampleLog = New-LogFile (Get-ExampleLines)
        $script:ExampleHistory = Read-SwHistory -Path $script:ExampleLog
    }

    It 'H-16 returns one string that ConvertFrom-Json parses' {
        $json = ConvertTo-SwHistoryJson -History $script:ExampleHistory -Limit 20 -LogPath $script:ExampleLog
        $json | Should -BeOfType [string]
        { $json | ConvertFrom-Json } | Should -Not -Throw
        $json.TrimStart()[0] | Should -Be '{'
    }

    It 'H-16 writes the top-level keys logs, limit, sessions, operations in this order' {
        $obj = (Get-HistoryJson -History $script:ExampleHistory -LogPath $script:ExampleLog) | ConvertFrom-Json
        ($obj.PSObject.Properties.Name -join ',') | Should -Be 'logs,limit,sessions,operations'
        ($obj.logs.PSObject.Properties.Name -join ',') | Should -Be 'operations'
        $obj.logs.operations | Should -Be $script:ExampleLog
    }

    It 'H-16 writes the session and operation keys in the pinned order' {
        $obj = (Get-HistoryJson -History $script:ExampleHistory -LogPath $script:ExampleLog) | ConvertFrom-Json
        (@($obj.sessions)[0].PSObject.Properties.Name -join ',') | Should -Be 'command,run_id,started_at,operation_count,actions'
        (@($obj.sessions)[0].actions.PSObject.Properties.Name -join ',') | Should -Be 'removed,recycled,uninstalled,disabled,restored,skipped,failed,other'
        (@($obj.operations)[0].PSObject.Properties.Name -join ',') | Should -Be 'timestamp,command,run_id,action,path,detail'
    }

    It 'H-16 writes limit and the counters as numbers, not strings' {
        $json = Get-HistoryJson -History $script:ExampleHistory -Limit 20 -LogPath $script:ExampleLog
        $json | Should -Match '"limit":\s*20\s*[,}]'
        $json | Should -Match '"operation_count":\s*2\s*[,}]'
        $json | Should -Match '"removed":\s*2\s*[,}]'
        $json | Should -Match '"other":\s*0\s*[,}]'
    }

    It 'H-16 writes sessions and operations as arrays when there is exactly one element' {
        $h = Read-Fixture @((New-Record '2026-10-15 10:00:01' 'clean' 'a1' 'REMOVED' 'C:\Temp\one' '1KB'))
        $json = Get-HistoryJson -History $h
        $json | Should -Match '"sessions":\s*\['
        $json | Should -Match '"operations":\s*\['
        $obj = $json | ConvertFrom-Json
        ($obj.sessions -is [array]) | Should -BeTrue
        ($obj.operations -is [array]) | Should -BeTrue
        @($obj.operations).Count | Should -Be 1
        $obj.operations[0].action | Should -Be 'removed'
    }

    It 'H-16 writes empty arrays, not null, for an empty history' {
        $path = [System.IO.Path]::Combine($TestDrive, 'json-missing', 'operations.log')
        $h = Read-SwHistory -Path $path
        $json = ConvertTo-SwHistoryJson -History $h -Limit 20 -LogPath $path
        $json | Should -Match '"sessions":\s*\[\s*\]'
        $json | Should -Match '"operations":\s*\[\s*\]'
        $json | Should -Match '"limit":\s*20'
        $obj = $json | ConvertFrom-Json
        ($obj.sessions -is [array]) | Should -BeTrue
        @($obj.sessions).Count | Should -Be 0
        @($obj.operations).Count | Should -Be 0
        $obj.logs.operations | Should -Be $path
    }

    It 'H-16 keeps backslashes, quotes and umlauts so that the parsed path equals the logged path' {
        $paths = @('C:\Temp\q"uote', 'C:\Temp\back\slash\', ('C:\Users\Example\' + [char]0x00DC + 'bung'), 'C:\Temp\{0} %USERPROFILE% <tag> & ''single''')
        $lines = @()
        $i = 0
        foreach ($p in $paths) { $i++; $lines += (New-Record "2026-10-15 10:00:0$i" 'clean' 'a1' 'REMOVED' $p '1KB') }
        $h = Read-Fixture $lines
        $obj = (Get-HistoryJson -History $h) | ConvertFrom-Json
        $got = @($obj.operations | ForEach-Object { $_.path })
        # newest first
        $got[0] | Should -Be $paths[3]
        $got[1] | Should -Be $paths[2]
        $got[2] | Should -Be $paths[1]
        $got[3] | Should -Be $paths[0]
    }

    It 'H-16 lowercases the action and gives an empty detail for a dash' {
        $h = Read-Fixture @('[2026-10-15 10:00:01] [optimize run=o1] OPTIMIZED dns-cache (-)')
        $op = @((Get-HistoryJson -History $h | ConvertFrom-Json).operations)[0]
        $op.action | Should -Be 'optimized'
        $op.detail | Should -Be ''
        $op.run_id | Should -Be 'o1'
    }

    It 'H-16 writes an empty run_id string, not null, when a record has no run id' {
        $h = Read-Fixture @('[2026-10-15 10:00:01] [sweepr] REMOVED C:\x (-)')
        $obj = Get-HistoryJson -History $h | ConvertFrom-Json
        $obj.operations[0].run_id | Should -BeExactly ''
        $obj.sessions[0].run_id | Should -BeExactly ''
    }

    It 'H-13 lists the newest operation first and applies the limit per list' {
        $obj = (Get-HistoryJson -History $script:ExampleHistory -Limit 1 -LogPath $script:ExampleLog) | ConvertFrom-Json
        @($obj.operations).Count | Should -Be 1
        $obj.operations[0].path | Should -Be 'C:\Temp\two'
        $obj.limit | Should -Be 1
    }

    It 'H-13 returns the last sessions of the log, newest first, with limit 2 of 3' {
        $h = Read-Fixture @(
            ''
            (New-Marker 'clean' 'A' '2026-10-15 10:00:00')
            (New-Record '2026-10-15 10:00:01' 'clean' 'A' 'REMOVED' 'C:\Temp\a' '1KB')
            ''
            (New-Marker 'purge' 'B' '2026-10-15 11:00:00')
            (New-Record '2026-10-15 11:00:01' 'purge' 'B' 'REMOVED' 'C:\Temp\b' '1KB')
            ''
            (New-Marker 'uninstall' 'C' '2026-10-15 12:00:00')
            (New-Record '2026-10-15 12:00:01' 'uninstall' 'C' 'REMOVED' 'C:\Temp\c' '1KB')
        )
        $obj = (Get-HistoryJson -History $h -Limit 2) | ConvertFrom-Json
        @($obj.sessions).Count | Should -Be 2
        $obj.sessions[0].run_id | Should -Be 'C'
        $obj.sessions[1].run_id | Should -Be 'B'
    }

    It 'H-13 follows the position in the log when timestamps run backwards' {
        $h = Read-Fixture @(
            (New-Record '2026-10-15 12:00:00' 'clean' 'a1' 'REMOVED' 'C:\Temp\first' '1KB')
            (New-Record '2026-10-15 08:00:00' 'clean' 'a1' 'REMOVED' 'C:\Temp\second' '1KB')
        )
        $obj = (Get-HistoryJson -History $h -Limit 1) | ConvertFrom-Json
        $obj.operations[0].path | Should -Be 'C:\Temp\second'
    }

    It 'H-13 shows all five entries for limit 200' {
        $lines = foreach ($i in 1..5) { New-Record "2026-10-15 10:00:0$i" 'clean' "r$i" 'REMOVED' "C:\Temp\n$i" '1KB' }
        $h = Read-Fixture @($lines)
        $obj = (Get-HistoryJson -History $h -Limit 200) | ConvertFrom-Json
        @($obj.operations).Count | Should -Be 5
        @($obj.sessions).Count | Should -Be 5
        $obj.limit | Should -Be 200
    }

    It 'H-13 does not change operation_count or the counters of a session when the limit cuts the operations' {
        $lines = @('', (New-Marker 'clean' 'a1' '2026-10-15 10:00:00'))
        foreach ($i in 1..5) { $lines += (New-Record "2026-10-15 10:00:0$i" 'clean' 'a1' 'REMOVED' "C:\Temp\n$i" '1KB') }
        $h = Read-Fixture $lines
        $obj = (Get-HistoryJson -History $h -Limit 1) | ConvertFrom-Json
        @($obj.operations).Count | Should -Be 1
        $obj.sessions[0].operation_count | Should -Be 5
        $obj.sessions[0].actions.removed | Should -Be 5
    }

    It 'H-13 applies the limit to sessions and operations independently' {
        $lines = @()
        foreach ($i in 1..3) {
            $lines += ''
            $lines += (New-Marker 'clean' "s$i" "2026-10-15 1${i}:00:00")
            foreach ($j in 1..3) { $lines += (New-Record "2026-10-15 1${i}:00:0$j" 'clean' "s$i" 'REMOVED' "C:\Temp\s${i}o$j" '1KB') }
        }
        $h = Read-Fixture $lines
        $obj = (Get-HistoryJson -History $h -Limit 4) | ConvertFrom-Json
        @($obj.sessions).Count | Should -Be 3
        @($obj.operations).Count | Should -Be 4
        $obj.operations[0].path | Should -Be 'C:\Temp\s3o3'
        $obj.operations[3].path | Should -Be 'C:\Temp\s2o3'
    }

    It 'H-13 does not fail for limits outside 1 to 200' {
        { $null = Get-HistoryJson -History $script:ExampleHistory -Limit 1000 } | Should -Not -Throw
        { $null = Get-HistoryJson -History $script:ExampleHistory -Limit 0 } | Should -Not -Throw
    }

    It 'S4 writes placeholder-like text in a path and a detail verbatim' {
        $p = 'C:\Temp\{0} {1:N} %USERPROFILE% $(Get-Date) `n [abc] $env:PATH'
        $d = '{0} %TEMP% $[exit 1] `t [x]'
        $h = Read-Fixture @((New-Record '2026-10-15 10:00:01' 'clean' 'a1' 'REMOVED' $p $d))
        $op = (Get-HistoryJson -History $h | ConvertFrom-Json).operations[0]
        $op.path | Should -BeExactly $p
        $op.detail | Should -BeExactly $d
    }
}

# ====================================================================================================
Describe 'Write-SwHistoryText (H-3, H-7, H-13, H-17, S4)' {
    BeforeAll {
        $script:ExampleLog = New-LogFile (Get-ExampleLines)
        $script:ExampleHistory = Read-SwHistory -Path $script:ExampleLog
    }

    It 'H-17 shows the session line as command, start time, comma and the action summary' {
        $text = Get-HistoryText -History $script:ExampleHistory -LogPath $script:ExampleLog
        $text | Should -Match 'clean\s+2026-10-15 10:00:00, removed 2'
    }

    It 'H-17 pads the command to at least 10 characters before the start time' {
        $text = Get-HistoryText -History $script:ExampleHistory -LogPath $script:ExampleLog
        $text | Should -Match 'clean {5,}2026-10-15 10:00:00, removed 2'
    }

    It 'H-17 shows an operation as timestamp, action, path and the detail in parentheses' {
        $text = Get-HistoryText -History $script:ExampleHistory -LogPath $script:ExampleLog
        $text | Should -Match 'removed\s+C:\\Temp\\two \(2\.0KB\)'
        $text | Should -Match 'removed\s+C:\\Temp\\one \(1\.0KB\)'
        $text | Should -Match '2026-10-15 10:00:02\s+removed\s+C:\\Temp\\two'
    }

    It 'H-17 pads the action word to at least 11 characters before the path' {
        $text = Get-HistoryText -History $script:ExampleHistory -LogPath $script:ExampleLog
        $text | Should -Match 'removed {4,}C:\\Temp\\two'
    }

    It 'H-17 shows the newest operation first' {
        $text = Get-HistoryText -History $script:ExampleHistory -LogPath $script:ExampleLog
        $text.IndexOf('C:\Temp\two') | Should -BeGreaterThan -1
        $text.IndexOf('C:\Temp\two') | Should -BeLessThan $text.IndexOf('C:\Temp\one')
    }

    It 'H-17 shows the sessions section, then the operations section, then the log path' {
        $text = Get-HistoryText -History $script:ExampleHistory -LogPath $script:ExampleLog
        $sessionAt = $text.IndexOf('removed 2')
        $operationAt = $text.IndexOf('C:\Temp\two')
        $logAt = $text.LastIndexOf($script:ExampleLog)
        $sessionAt | Should -BeGreaterThan -1
        $sessionAt | Should -BeLessThan $operationAt
        $operationAt | Should -BeLessThan $logAt
    }

    It 'H-1 shows the full path of the log that was read' {
        $text = Get-HistoryText -History $script:ExampleHistory -LogPath 'C:\Users\Example\.config\sweepr\operations.log'
        $text | Should -BeLike '*C:\Users\Example\.config\sweepr\operations.log*'
    }

    It 'H-3 shows the log path even when the file does not exist and shows no entries' {
        $path = [System.IO.Path]::Combine($TestDrive, 'text-missing', 'operations.log')
        $h = Read-SwHistory -Path $path
        $text = Get-HistoryText -History $h -LogPath $path
        $text | Should -BeLike "*$path*"
        $text | Should -Not -Match '\d{4}-\d{2}-\d{2} \d{2}:\d{2}'
        $text | Should -Not -Match '(removed|recycled|uninstalled|disabled|restored|skipped|failed)\s+\d'
        @($text -split "`n" | Where-Object { $_.Trim() }).Count | Should -BeGreaterOrEqual 5
    }

    It 'H-7 shows a session without records with its start and without any action count' {
        $h = Read-Fixture @('', (New-Marker 'clean' 'a1' '2026-10-15 10:00:00'))
        $text = Get-HistoryText -History $h
        $text | Should -Match 'clean\s+2026-10-15 10:00:00, '
        $text | Should -Not -Match '(removed|recycled|uninstalled|disabled|restored|skipped|failed|other)\s+\d'
    }

    It 'H-17 shows disabled 1 and not the no-actions hint for a session with one DISABLED record' {
        $h = Read-Fixture @(
            ''
            (New-Marker 'features' 'f1' '2026-10-25 10:00:00')
            (New-Record '2026-10-25 10:00:02' 'features' 'f1' 'DISABLED' 'feature:Contoso-Legacy' 'Disable-WindowsOptionalFeature -Online -FeatureName Contoso-Legacy -NoRestart; restart needed')
        )
        $text = Get-HistoryText -History $h
        $text | Should -Match 'features\s+2026-10-25 10:00:00, disabled 1'
        $text | Should -Match 'disabled\s+feature:Contoso-Legacy \(Disable-WindowsOptionalFeature -Online -FeatureName Contoso-Legacy -NoRestart; restart needed\)'
    }

    It 'H-17 shows restored 2 for a restore run' {
        $h = Read-Fixture @(
            ''
            (New-Marker 'features' 'r1' '2026-10-26 09:00:00')
            (New-Record '2026-10-26 09:00:01' 'features' 'r1' 'RESTORED' 'feature:A' 'x')
            (New-Record '2026-10-26 09:00:02' 'features' 'r1' 'RESTORED' 'feature:B' 'x')
            (New-Record '2026-10-26 09:00:03' 'features' 'r1' 'FAILED' 'feature:C' 'x')
        )
        (Get-HistoryText -History $h) | Should -Match 'restored 2'
    }

    It 'H-17 leaves the detail and its parentheses out when the log has a dash' {
        $h = Read-Fixture @('[2026-10-15 10:00:01] [clean run=a1] REMOVED C:\Temp\nodetail (-)')
        $line = @((Get-HistoryText -History $h) -split "`n" | Where-Object { $_ -like '*C:\Temp\nodetail*' })
        $line.Count | Should -Be 1
        $line[0] | Should -Not -Match '\('
        $line[0] | Should -Not -Match '-\)'
        $line[0].TrimEnd() | Should -Match 'C:\\Temp\\nodetail$'
    }

    It 'H-17 does not truncate a long command name' {
        $h = Read-Fixture @('[2026-10-15 10:00:01] [very-long-command run=a1] REMOVED C:\x (1KB)')
        (Get-HistoryText -History $h) | Should -BeLike '*very-long-command*'
    }

    It 'H-13 shows the newest sessions first and only as many as the limit' {
        $h = Read-Fixture @(
            ''
            (New-Marker 'clean' 'A' '2026-10-15 10:00:00')
            (New-Record '2026-10-15 10:00:01' 'clean' 'A' 'REMOVED' 'C:\Temp\a' '1KB')
            ''
            (New-Marker 'purge' 'B' '2026-10-15 11:00:00')
            (New-Record '2026-10-15 11:00:01' 'purge' 'B' 'REMOVED' 'C:\Temp\b' '1KB')
            ''
            (New-Marker 'uninstall' 'C' '2026-10-15 12:00:00')
            (New-Record '2026-10-15 12:00:01' 'uninstall' 'C' 'REMOVED' 'C:\Temp\c' '1KB')
        )
        $text = Get-HistoryText -History $h -Limit 2
        $c = $text.IndexOf('uninstall')
        $b = $text.IndexOf('purge')
        $c | Should -BeGreaterThan -1
        $b | Should -BeGreaterThan $c
        $text.IndexOf('2026-10-15 10:00:00') | Should -Be -1
    }

    It 'H-13 shows only the newest operation for limit 1' {
        $text = Get-HistoryText -History $script:ExampleHistory -Limit 1 -LogPath $script:ExampleLog
        $text | Should -BeLike '*C:\Temp\two*'
        $text | Should -Not -BeLike '*C:\Temp\one*'
    }

    It 'H-13 shows all entries when there are fewer than the limit' {
        $text = Get-HistoryText -History $script:ExampleHistory -Limit 200 -LogPath $script:ExampleLog
        $text | Should -BeLike '*C:\Temp\one*'
        $text | Should -BeLike '*C:\Temp\two*'
    }

    It 'S4 prints placeholder-like text, escape text and brackets verbatim and no control character' {
        $p = 'C:\Temp\{0} {1:N} %USERPROFILE% $(Get-Date) `n [abc] \x1b[31m \n'
        $d = '{0} %TEMP% $[exit 1] [x] \t'
        $h = Read-Fixture @((New-Record '2026-10-15 10:00:01' 'clean' 'a1' 'REMOVED' $p $d))
        $text = Get-HistoryText -History $h
        $text.Contains($p + ' (' + $d + ')') | Should -BeTrue
        $text | Should -Not -Match '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'
        $text | Should -Not -Match ([string][char]27)
    }

    It 'H-10 shows the escape text of a path and keeps it on one line' {
        $h = Read-Fixture @('[2026-10-15 10:00:01] [clean run=a1] REMOVED C:\Temp\a\nb\x1b[31mc (1KB)')
        $lines = @((Get-HistoryText -History $h) -split "`n" | Where-Object { $_ -like '*C:\Temp\a*' })
        $lines.Count | Should -Be 1
        $lines[0].Contains('C:\Temp\a\nb\x1b[31mc (1KB)') | Should -BeTrue
    }

    It 'H-11 shows non-ASCII characters of a path unchanged' {
        $umlaut = 'C:\Users\Example\' + [char]0x00DC + 'bung' + [char]0x65E5 + [char]0x672C
        $h = Read-Fixture @((New-Record '2026-10-15 10:00:01' 'clean' 'a1' 'REMOVED' $umlaut '1KB'))
        (Get-HistoryText -History $h).Contains($umlaut) | Should -BeTrue
    }

    It 'H-17 returns nothing on the success stream, all text goes to the host' {
        $out = @(& { Write-SwHistoryText -History $script:ExampleHistory -Limit 20 -LogPath $script:ExampleLog } 6>$null)
        $out.Count | Should -Be 0
    }
}

# ====================================================================================================
Describe 'bin/history.ps1: script shape and loading (H-18, 2.1)' {
    It 'H-18 loads history.ps1 alone without output, files, base.ps1 or log.ps1, and twice in one scope' {
        $solo = [System.IO.Path]::Combine($TestDrive, 'solo-' + [guid]::NewGuid().ToString('N'))
        $work = [System.IO.Path]::Combine($TestDrive, 'solo-work-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($solo)
        [void][System.IO.Directory]::CreateDirectory($work)
        Copy-Item -LiteralPath $script:HistoryModule -Destination ([System.IO.Path]::Combine($solo, 'history.ps1'))
        $module = ConvertTo-Literal ([System.IO.Path]::Combine($solo, 'history.ps1'))
        $code = @"
`$before = @(Get-ChildItem -LiteralPath (Get-Location).ProviderPath -Force -Recurse).Count
. $module
. $module
`$names = 'Read-SwHistory','Format-SwHistoryActions','ConvertTo-SwHistoryJson','Write-SwHistoryText','ConvertTo-SwHistoryLimit'
`$missing = @(foreach (`$n in `$names) { if (-not (Get-Command `$n -ErrorAction SilentlyContinue)) { `$n } })
`$after = @(Get-ChildItem -LiteralPath (Get-Location).ProviderPath -Force -Recurse).Count
`$r = [ordered]@{}
`$r.Missing = `$missing -join ','
`$r.Eap = [string]`$ErrorActionPreference
`$r.Strict = try { `$null = `$notDefinedAnywhere; 'off' } catch { 'on' }
`$r.Files = `$after - `$before
`$r.Base = [bool](Get-Command Write-SweeprOperation -ErrorAction SilentlyContinue)
Write-Output '##RESULT##'
`$r | ConvertTo-Json -Compress
"@
        $result = Invoke-ChildCode -Code $code -WorkingDirectory $work
        $result.ExitCode | Should -Be 0
        $parts = $result.Out -split '##RESULT##'
        $parts[0].Trim() | Should -BeNullOrEmpty
        $data = $parts[1].Trim() | ConvertFrom-Json
        $data.Missing | Should -Be ''
        $data.Files | Should -Be 0
        $data.Base | Should -BeFalse
    }

    It 'H-18 leaves strict mode off and ErrorActionPreference Continue in the caller after loading history.ps1' {
        $module = ConvertTo-Literal $script:HistoryModule
        $code = @"
. $module
`$r = [ordered]@{}
`$r.Eap = [string]`$ErrorActionPreference
`$r.Strict = try { `$null = `$notDefinedAnywhere; 'off' } catch { 'on' }
Write-Output '##RESULT##'
`$r | ConvertTo-Json -Compress
"@
        $result = Invoke-ChildCode -Code $code
        $data = ($result.Out -split '##RESULT##')[1].Trim() | ConvertFrom-Json
        $data.Eap | Should -Be 'Continue'
        $data.Strict | Should -Be 'off'
    }

    It 'H-18 leaves strict mode Latest and ErrorActionPreference SilentlyContinue of the caller as they were' {
        $module = ConvertTo-Literal $script:HistoryModule
        $code = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'SilentlyContinue'
. $module
`$r = [ordered]@{}
`$r.Eap = [string]`$ErrorActionPreference
`$r.Strict = try { `$null = `$notDefinedAnywhere; 'off' } catch { 'on' }
Write-Output '##RESULT##'
`$r | ConvertTo-Json -Compress
"@
        $result = Invoke-ChildCode -Code $code
        $data = ($result.Out -split '##RESULT##')[1].Trim() | ConvertFrom-Json
        $data.Eap | Should -Be 'SilentlyContinue'
        $data.Strict | Should -Be 'on'
    }

    It 'H-18 takes its module folder from its own location, not from the working directory' {
        # A fake installation root with the real script and the real lib\core, and a decoy lib\core in the working directory.
        $root = [System.IO.Path]::Combine($TestDrive, 'fake-root-' + [guid]::NewGuid().ToString('N'))
        $binDir = [System.IO.Path]::Combine($root, 'bin')
        $libDir = [System.IO.Path]::Combine($root, 'lib')
        [void][System.IO.Directory]::CreateDirectory($binDir)
        [void][System.IO.Directory]::CreateDirectory($libDir)
        Copy-Item -LiteralPath $script:HistoryScript -Destination ([System.IO.Path]::Combine($binDir, 'history.ps1'))
        Copy-Item -LiteralPath $script:CoreDir -Destination $libDir -Recurse
        $cwd = [System.IO.Path]::Combine($TestDrive, 'decoy-cwd-' + [guid]::NewGuid().ToString('N'))
        $decoyCore = [System.IO.Path]::Combine($cwd, 'lib', 'core')
        [void][System.IO.Directory]::CreateDirectory($decoyCore)
        foreach ($f in @('base.ps1', 'log.ps1', 'history.ps1')) {
            [System.IO.File]::WriteAllText([System.IO.Path]::Combine($decoyCore, $f), "Write-Output 'DECOY-LOADED'`r`n")
        }
        $data = New-LogDataDir (Get-ExampleLines)
        $r = Invoke-HistoryScript -DataDir $data -ArgText '-Json' -ScriptPath ([System.IO.Path]::Combine($binDir, 'history.ps1')) -WorkingDirectory $cwd
        $r.Both | Should -Not -Match 'DECOY-LOADED'
        $r.ExitCode | Should -Be 0
        $obj = $r.Out | ConvertFrom-Json
        @($obj.operations).Count | Should -Be 2
    }

    It 'H-18 reads the same log from a foreign working directory as from the install folder' {
        $data = New-LogDataDir (Get-ExampleLines)
        $elsewhere = [System.IO.Path]::Combine($TestDrive, 'elsewhere-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($elsewhere)
        $a = Invoke-HistoryScript -DataDir $data -ArgText '-Json' -WorkingDirectory $elsewhere
        $b = Invoke-HistoryScript -DataDir $data -ArgText '-Json' -WorkingDirectory $script:RepoRoot
        $a.ExitCode | Should -Be 0
        $b.ExitCode | Should -Be 0
        $a.Out | Should -Be $b.Out
        @(($a.Out | ConvertFrom-Json).operations).Count | Should -Be 2
    }

    It 'H-18 sets ErrorActionPreference Stop and strict mode Latest for itself' {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:HistoryScript, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        $eap = @($ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left.Extent.Text -match '^\$ErrorActionPreference$' -and
                    $n.Right.Extent.Text.Trim('"', "'") -eq 'Stop'
                }, $true))
        $eap.Count | Should -BeGreaterThan 0
        $strict = @($ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -eq 'Set-StrictMode' -and
                    $n.Extent.Text -match 'Latest'
                }, $true))
        $strict.Count | Should -BeGreaterThan 0
    }

    It 'H-15 declares ShowHelp (alias h) and Json as switches, an untyped Limit and a remaining-arguments collector, but no DebugMode' {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:HistoryScript, [ref]$tokens, [ref]$errors)
        $params = @($ast.ParamBlock.Parameters)
        $byName = @{}
        foreach ($p in $params) { $byName[$p.Name.VariablePath.UserPath] = $p }

        $byName.ContainsKey('ShowHelp') | Should -BeTrue
        $byName.ContainsKey('Json') | Should -BeTrue
        $byName.ContainsKey('Limit') | Should -BeTrue
        $byName.ContainsKey('DebugMode') | Should -BeFalse

        $typeOf = {
            param($p)
            $t = @($p.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.TypeConstraintAst] })
            if ($t.Count -gt 0) { $t[0].TypeName.Name } else { '' }
        }
        (& $typeOf $byName['ShowHelp']) | Should -Match '^(switch|System\.Management\.Automation\.SwitchParameter)$'
        (& $typeOf $byName['Json']) | Should -Match '^(switch|System\.Management\.Automation\.SwitchParameter)$'
        (& $typeOf $byName['Limit']) | Should -Not -Match '^(switch|System\.Management\.Automation\.SwitchParameter|int|int32|System\.Int32)$'

        $aliases = @($byName['ShowHelp'].Attributes | Where-Object { $_ -is [System.Management.Automation.Language.AttributeAst] -and $_.TypeName.Name -eq 'Alias' } |
                ForEach-Object { $_.PositionalArguments | ForEach-Object { $_.Extent.Text.Trim('"', "'") } })
        $aliases | Should -Contain 'h'

        $remaining = @($params | Where-Object {
                @($_.Attributes | Where-Object {
                        $_ -is [System.Management.Automation.Language.AttributeAst] -and $_.TypeName.Name -eq 'Parameter' -and
                        @($_.NamedArguments | Where-Object { $_.ArgumentName -eq 'ValueFromRemainingArguments' }).Count -gt 0
                    }).Count -gt 0
            })
        $remaining.Count | Should -Be 1
    }
}

# ====================================================================================================
Describe 'sw history through the router and the script (H-1, H-2, H-3, H-12 to H-17, S1, S2, S7)' {
    BeforeAll {
        $script:LogLines = Get-ExampleLines
    }

    It 'H-1 reads config\operations.log below SWEEPR_DATA_DIR and shows that path in the text' {
        $data = New-LogDataDir $script:LogLines
        $r = Invoke-Router -DataDir $data -Words @()
        $r.ExitCode | Should -Be 0
        ($r.Out -replace '\\', '/') | Should -BeLike ('*' + ((Get-DataLogPath $data) -replace '\\', '/') + '*')
        $r.Out | Should -Match 'clean\s+2026-10-15 10:00:00, removed 2'
    }

    It 'H-1 shows the log path in logs.operations of the JSON' {
        $data = New-LogDataDir $script:LogLines
        $r = Invoke-Router -DataDir $data -Words @('--json')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out | ConvertFrom-Json
        ($obj.logs.operations -replace '\\', '/') | Should -Be ((Get-DataLogPath $data) -replace '\\', '/')
    }

    It 'H-1 does not show entries of operations.log.old' {
        $data = New-LogDataDir $script:LogLines
        Write-FixtureText -Path ((Get-DataLogPath $data) + '.old') -Text (Join-LogLines @(
                ''
                (New-Marker 'purge' 'old1' '2026-09-01 10:00:00')
                (New-Record '2026-09-01 10:00:01' 'purge' 'old1' 'REMOVED' 'C:\Temp\ancient' '1KB')))
        $r = Invoke-Router -DataDir $data -Words @('--json')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Not -Match 'ancient'
        $r.Out | Should -Not -Match 'old1'
    }

    It 'S7 reads only config\operations.log and no other file below or beside the data folder' {
        $data = New-LogDataDir $script:LogLines
        $cfg = Split-Path -Parent (Get-DataLogPath $data)
        foreach ($f in @('sweepr_debug_session.log', 'features-removed.json', 'operations.log.old', 'operations.log.bak')) {
            Write-FixtureText -Path ([System.IO.Path]::Combine($cfg, $f)) -Text (Join-LogLines @((New-Record '2026-09-01 10:00:01' 'purge' 'x9' 'REMOVED' "C:\Temp\decoy-$f" '1KB')))
        }
        Write-FixtureText -Path ([System.IO.Path]::Combine($data, 'operations.log')) -Text (Join-LogLines @((New-Record '2026-09-01 10:00:01' 'purge' 'x9' 'REMOVED' 'C:\Temp\decoy-outside' '1KB')))
        Write-FixtureText -Path ([System.IO.Path]::Combine($data, 'cache', 'operations.log')) -Text (Join-LogLines @((New-Record '2026-09-01 10:00:01' 'purge' 'x9' 'REMOVED' 'C:\Temp\decoy-cache' '1KB')))
        $r = Invoke-Router -DataDir $data -Words @('--json')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Not -Match 'decoy-'
        @(($r.Out | ConvertFrom-Json).operations).Count | Should -Be 2
    }

    It 'H-2 leaves the log byte-identical and adds no file when run through the router' {
        $data = New-LogDataDir $script:LogLines
        $before = Get-Snapshot -Root $data -FilesOnly
        $r1 = Invoke-Router -DataDir $data -Words @()
        $r2 = Invoke-Router -DataDir $data -Words @('--json', '--limit', '1')
        $r1.ExitCode | Should -Be 0
        $r2.ExitCode | Should -Be 0
        (Get-Snapshot -Root $data -FilesOnly) -join "`n" | Should -Be ($before -join "`n")
    }

    It 'H-2 leaves the log byte-identical, its folder unchanged and adds no marker when the script runs' {
        $data = New-LogDataDir $script:LogLines
        $before = Get-Snapshot -Root $data
        $r1 = Invoke-HistoryScript -DataDir $data
        $r2 = Invoke-HistoryScript -DataDir $data -ArgText '-Json -Limit:''1'''
        $r1.ExitCode | Should -Be 0
        $r2.ExitCode | Should -Be 0
        (Get-Snapshot -Root $data) -join "`n" | Should -Be ($before -join "`n")
    }

    It 'H-2 creates neither log, folder nor .old when the script runs without a log' {
        $data = New-DataDir
        $r1 = Invoke-HistoryScript -DataDir $data
        $r2 = Invoke-HistoryScript -DataDir $data -ArgText '-Json'
        $r1.ExitCode | Should -Be 0
        $r2.ExitCode | Should -Be 0
        @(Get-ChildItem -LiteralPath $data -Force -Recurse).Count | Should -Be 0
    }

    It 'H-2 creates no log and no .old when the router runs without a log' {
        $data = New-DataDir
        $r = Invoke-Router -DataDir $data -Words @('--json')
        $r.ExitCode | Should -Be 0
        [System.IO.File]::Exists((Get-DataLogPath $data)) | Should -BeFalse
        @(Get-ChildItem -LiteralPath $data -Force -Recurse -File).Count | Should -Be 0
    }

    It 'S1 writes no record and no session marker even with the router run variables set and logging not disabled' {
        $data = New-LogDataDir $script:LogLines
        $before = Get-Snapshot -Root $data -FilesOnly
        $env2 = @{ _SWEEPR_OPLOG_RUN_COMMAND = 'history'; _SWEEPR_OPLOG_RUN_ID = '20261015120000-4242-99' }
        $r = Invoke-HistoryScript -DataDir $data -ArgText '-Json' -Environment $env2 -RemoveEnvironment @('SWEEPR_NO_OPLOG')
        $r.ExitCode | Should -Be 0
        (Get-Snapshot -Root $data -FilesOnly) -join "`n" | Should -Be ($before -join "`n")
        $text = [System.IO.File]::ReadAllText((Get-DataLogPath $data))
        $text | Should -Not -Match 'history run='
    }

    It 'S1 creates no log when none existed, with the run variables set and logging not disabled' {
        $data = New-DataDir
        $env2 = @{ _SWEEPR_OPLOG_RUN_COMMAND = 'history'; _SWEEPR_OPLOG_RUN_ID = '20261015120000-4242-99' }
        $r = Invoke-HistoryScript -DataDir $data -Environment $env2 -RemoveEnvironment @('SWEEPR_NO_OPLOG')
        $r.ExitCode | Should -Be 0
        @(Get-ChildItem -LiteralPath $data -Force -Recurse).Count | Should -Be 0
    }

    It 'S1 writes nothing through the router either when logging is not disabled' {
        $data = New-LogDataDir $script:LogLines
        $before = Get-Snapshot -Root $data -FilesOnly
        $r = Invoke-Router -DataDir $data -Words @() -RemoveEnvironment @('SWEEPR_NO_OPLOG')
        $r.ExitCode | Should -Be 0
        (Get-Snapshot -Root $data -FilesOnly) -join "`n" | Should -Be ($before -join "`n")
    }

    It 'H-1 still reads the log when SWEEPR_NO_OPLOG is 1 (the variable only switches writing off)' {
        $data = New-LogDataDir $script:LogLines
        $r = Invoke-Router -DataDir $data -Words @('--json') -Environment @{ SWEEPR_NO_OPLOG = '1' }
        $r.ExitCode | Should -Be 0
        @(($r.Out | ConvertFrom-Json).operations).Count | Should -Be 2
    }

    It 'H-1 ignores SWEEPR_DRY_RUN' {
        $data = New-LogDataDir $script:LogLines
        $r = Invoke-Router -DataDir $data -Words @('--json') -Environment @{ SWEEPR_DRY_RUN = '1' }
        $r.ExitCode | Should -Be 0
        @(($r.Out | ConvertFrom-Json).operations).Count | Should -Be 2
    }

    It 'H-3 exits 0 with the empty hints in the text when there is no log' {
        $data = New-DataDir
        $r = Invoke-Router -DataDir $data -Words @()
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Not -Match '\d{4}-\d{2}-\d{2} \d{2}:\d{2}'
        ($r.Out -replace '\\', '/') | Should -BeLike ('*' + ((Get-DataLogPath $data) -replace '\\', '/') + '*')
    }

    It 'H-3 exits 0 with empty sessions and operations and the default limit in the JSON when there is no log' {
        $data = New-DataDir
        $r = Invoke-Router -DataDir $data -Words @('--json')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Match '"sessions":\s*\[\s*\]'
        $r.Out | Should -Match '"operations":\s*\[\s*\]'
        $obj = $r.Out | ConvertFrom-Json
        $obj.limit | Should -Be 20
        @($obj.sessions).Count | Should -Be 0
    }

    It 'H-3 exits 0 for an empty log file' {
        $data = New-DataDir
        Write-FixtureText -Path (Get-DataLogPath $data) -Text ''
        $r = Invoke-Router -DataDir $data -Words @('--json')
        $r.ExitCode | Should -Be 0
        @(($r.Out | ConvertFrom-Json).sessions).Count | Should -Be 0
    }

    It 'H-3 exits 0 for a log with only blank and foreign lines' {
        $data = New-LogDataDir @('', 'Hello world', '# comment', '[2026-10-15 10:00:01] [clean run=a1] removed C:\x (1KB)')
        $r = Invoke-Router -DataDir $data -Words @('--json')
        $r.ExitCode | Should -Be 0
        @(($r.Out | ConvertFrom-Json).operations).Count | Should -Be 0
    }

    It 'H-9 exits 0 and reads the rest when a foreign line sits in the middle of the log' {
        $data = New-LogDataDir @(
            ''
            (New-Marker 'clean' 'a1' '2026-10-15 10:00:00')
            (New-Record '2026-10-15 10:00:01' 'clean' 'a1' 'REMOVED' 'C:\Temp\one' '1KB')
            'Hello world'
            (New-Record '2026-10-15 10:00:02' 'clean' 'a1' 'REMOVED' 'C:\Temp\two' '2KB')
        )
        $r = Invoke-Router -DataDir $data -Words @('--json')
        $r.ExitCode | Should -Be 0
        @(($r.Out | ConvertFrom-Json).operations).Count | Should -Be 2
    }

    It 'H-12 exits 1 with a message that names the path and prints no history when the log is a folder (router)' {
        $data = New-DataDir
        $logPath = Get-DataLogPath $data
        [void][System.IO.Directory]::CreateDirectory($logPath)
        $r = Invoke-Router -DataDir $data -Words @('--json')
        $r.ExitCode | Should -Be 1
        $r.Out | Should -Not -Match '"sessions"'
        $r.Both | Should -BeLike "*$logPath*"
        $r.Both | Should -Not -Match '(?m)^\s*at\s+\S+,\s+\S+:\s+line\s+\d+'
        $r.Both | Should -Not -Match '(?m)^At\s+\S+:\d+\s+char:\d+'
    }

    It 'H-12 exits 1 for the text form too and prints no history table (router)' {
        $data = New-DataDir
        $logPath = Get-DataLogPath $data
        [void][System.IO.Directory]::CreateDirectory($logPath)
        $r = Invoke-Router -DataDir $data -Words @()
        $r.ExitCode | Should -Be 1
        $r.Out | Should -Not -Match '\d{4}-\d{2}-\d{2} \d{2}:\d{2}'
        $r.Both | Should -BeLike "*$logPath*"
    }

    It 'H-12 exits 1 with a message that names the path and prints no history when the log is a folder (script)' {
        $data = New-DataDir
        $logPath = Get-DataLogPath $data
        [void][System.IO.Directory]::CreateDirectory($logPath)
        $r = Invoke-HistoryScript -DataDir $data -ArgText '-Json'
        $r.ExitCode | Should -Be 1
        $r.Out | Should -Not -Match '"sessions"'
        $r.Out | Should -Not -Match '\{'
        $r.Both | Should -BeLike "*$logPath*"
        $r.Both | Should -Not -Match '(?m)^\s*at\s+\S+,\s+\S+:\s+line\s+\d+'
        $r.Both | Should -Not -Match '(?m)^At\s+\S+:\d+\s+char:\d+'
    }

    It 'S2 treats a missing log as success and an unreadable one as an error, never as empty' {
        $missing = New-DataDir
        $broken = New-DataDir
        [void][System.IO.Directory]::CreateDirectory((Get-DataLogPath $broken))
        (Invoke-HistoryScript -DataDir $missing -ArgText '-Json').ExitCode | Should -Be 0
        $r = Invoke-HistoryScript -DataDir $broken -ArgText '-Json'
        $r.ExitCode | Should -Be 1
        $r.Out | Should -Not -Match '"sessions"'
    }

    It 'H-13 uses limit 20 and at most 20 entries per list when --limit is not given' {
        $lines = @()
        foreach ($i in 1..25) {
            $lines += ''
            $lines += (New-Marker 'clean' ('r{0:00}' -f $i) ('2026-10-15 10:{0:00}:00' -f $i))
            $lines += (New-Record ('2026-10-15 10:{0:00}:01' -f $i) 'clean' ('r{0:00}' -f $i) 'REMOVED' ('C:\Temp\n{0:00}' -f $i) '1KB')
        }
        $data = New-LogDataDir $lines
        $r = Invoke-Router -DataDir $data -Words @('--json')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out | ConvertFrom-Json
        $obj.limit | Should -Be 20
        @($obj.sessions).Count | Should -Be 20
        @($obj.operations).Count | Should -Be 20
        $obj.sessions[0].run_id | Should -Be 'r25'
        $obj.operations[0].path | Should -Be 'C:\Temp\n25'
        $obj.operations[19].path | Should -Be 'C:\Temp\n06'
    }

    It 'H-13 and H-14 take limit <Name> through the router' -ForEach @(
        @{ Name = '--limit=5'; Words = @('--limit=5', '--json'); Expected = 5 }
        @{ Name = '--limit:5'; Words = @('--limit:5', '--json'); Expected = 5 }
        @{ Name = '--limit 5'; Words = @('--limit', '5', '--json'); Expected = 5 }
        @{ Name = '--json before --limit 5'; Words = @('--json', '--limit', '5'); Expected = 5 }
        @{ Name = 'mixed case --JSON --Limit=5'; Words = @('--JSON', '--Limit=5'); Expected = 5 }
        @{ Name = 'single dash -json -limit:5'; Words = @('-json', '-limit:5'); Expected = 5 }
        @{ Name = '--limit 010 with leading zeros'; Words = @('--limit', '010', '--json'); Expected = 10 }
        @{ Name = 'given twice, last value wins'; Words = @('--limit', '3', '--limit', '4', '--json'); Expected = 4 }
        @{ Name = '--limit 200'; Words = @('--limit=200', '--json'); Expected = 200 }
    ) {
        $data = New-LogDataDir $script:LogLines
        $r = Invoke-Router -DataDir $data -Words $Words
        $r.ExitCode | Should -Be 0
        $obj = $r.Out | ConvertFrom-Json
        $obj.limit | Should -Be $Expected
    }

    It 'H-13 limits both lists through --limit 1' {
        $data = New-LogDataDir ($script:LogLines + @('', (New-Marker 'purge' 'p1' '2026-10-16 10:00:00'), (New-Record '2026-10-16 10:00:01' 'purge' 'p1' 'REMOVED' 'C:\Code\x' '1KB')))
        $r = Invoke-Router -DataDir $data -Words @('--json', '--limit', '1')
        $r.ExitCode | Should -Be 0
        $obj = $r.Out | ConvertFrom-Json
        @($obj.sessions).Count | Should -Be 1
        @($obj.operations).Count | Should -Be 1
        $obj.sessions[0].run_id | Should -Be 'p1'
        $obj.operations[0].path | Should -Be 'C:\Code\x'
    }

    It 'H-14 rejects --limit <Name> with exit 2, names the value and prints no history' -ForEach @(
        @{ Name = '0'; Words = @('--limit', '0'); Needle = '0' }
        @{ Name = '201'; Words = @('--limit', '201'); Needle = '201' }
        @{ Name = '1000'; Words = @('--limit=1000'); Needle = '1000' }
        @{ Name = '-1 (a word, not an option)'; Words = @('--limit', '-1'); Needle = '-1' }
        @{ Name = 'abc with --json'; Words = @('--limit', 'abc', '--json'); Needle = 'abc' }
        @{ Name = '5.0'; Words = @('--limit', '5.0'); Needle = '5.0' }
        @{ Name = '0 given with equals'; Words = @('--limit=0'); Needle = '0' }
    ) {
        $data = New-LogDataDir $script:LogLines
        $r = Invoke-Router -DataDir $data -Words $Words
        $r.ExitCode | Should -Be 2
        $r.Out | Should -Not -Match '"sessions"'
        $r.Out | Should -Not -Match 'Temp\\one'
        $r.Out | Should -Not -Match 'Temp\\two'
        $r.Both | Should -BeLike "*$Needle*"
    }

    It 'H-14 rejects <Name> as a missing value with exit 2 and a message' -ForEach @(
        @{ Name = '--limit at the end'; Words = @('--limit') }
        @{ Name = '--limit directly before --json'; Words = @('--limit', '--json') }
    ) {
        $data = New-LogDataDir $script:LogLines
        $r = Invoke-Router -DataDir $data -Words $Words
        $r.ExitCode | Should -Be 2
        $r.Out | Should -Not -Match '"sessions"'
        $r.Out | Should -Not -Match 'Temp\\one'
        $r.Both.Trim() | Should -Not -BeNullOrEmpty
    }

    It 'H-14 and H-15 treat --limit= as a surplus word with exit 2' {
        $data = New-LogDataDir $script:LogLines
        $r = Invoke-Router -DataDir $data -Words @('--limit=', '--json')
        $r.ExitCode | Should -Be 2
        $r.Out | Should -Not -Match '"sessions"'
        $r.Both | Should -BeLike '*--limit=*'
    }

    It 'H-15 rejects a surplus word with exit 2, names it and points to sw history --help' {
        $data = New-LogDataDir $script:LogLines
        $r = Invoke-Router -DataDir $data -Words @('extra')
        $r.ExitCode | Should -Be 2
        $r.Both | Should -BeLike '*extra*'
        $r.Both | Should -BeLike '*sw history --help*'
        $r.Out | Should -Not -Match 'Temp\\one'
        $r.Out | Should -Not -Match '\d{4}-\d{2}-\d{2} \d{2}:\d{2}'
    }

    It 'H-15 rejects a surplus word after a valid --limit with exit 2' {
        $data = New-LogDataDir $script:LogLines
        $r = Invoke-Router -DataDir $data -Words @('--limit', '5', 'extra')
        $r.ExitCode | Should -Be 2
        $r.Both | Should -BeLike '*extra*'
        $r.Out | Should -Not -Match 'Temp\\one'
    }

    It 'H-15 rejects the unknown option <Option> with exit 2 and prints no history' -ForEach @(
        @{ Option = '--foo' }
        @{ Option = '--debug' }
    ) {
        $data = New-LogDataDir $script:LogLines
        $r = Invoke-Router -DataDir $data -Words @($Option, '--json')
        $r.ExitCode | Should -Be 2
        $r.Out | Should -Not -Match '"sessions"'
        $r.Out | Should -Not -Match 'Temp\\one'
    }

    It 'H-15 prints the short help with exit 0 for <Name>' -ForEach @(
        @{ Name = '--help'; Words = @('--help') }
        @{ Name = '-h'; Words = @('-h') }
        @{ Name = '--help before an invalid limit'; Words = @('--help', '--limit', '0') }
        @{ Name = '--help with a surplus word'; Words = @('--help', 'extra') }
        @{ Name = '--help with --json'; Words = @('--help', '--json') }
    ) {
        $data = New-LogDataDir $script:LogLines
        $r = Invoke-Router -DataDir $data -Words $Words
        $r.ExitCode | Should -Be 0
        $r.Out | Should -BeLike '*sw history [[]OPTIONS]*'
        $r.Out | Should -BeLike '*--json*'
        $r.Out | Should -BeLike '*--limit N*'
        $r.Out | Should -Match '1\s*(-|to|\u2013)\s*200'
        $r.Out | Should -BeLike '*-h, --help*'
        $r.Out | Should -Not -Match 'Temp\\one'
        $r.Out | Should -Not -Match '"sessions"'
    }

    It 'H-15 does not read the log for --help, even when the log cannot be read' {
        $data = New-DataDir
        [void][System.IO.Directory]::CreateDirectory((Get-DataLogPath $data))
        $r = Invoke-Router -DataDir $data -Words @('--help')
        $r.ExitCode | Should -Be 0
        $r.Out | Should -BeLike '*sw history [[]OPTIONS]*'
    }

    It 'H-15 creates no log when it prints the help' {
        $data = New-DataDir
        $r = Invoke-Router -DataDir $data -Words @('-h')
        $r.ExitCode | Should -Be 0
        [System.IO.File]::Exists((Get-DataLogPath $data)) | Should -BeFalse
    }

    It 'H-16 prints only the JSON document on stdout, nothing before or after it' {
        $data = New-LogDataDir $script:LogLines
        $r = Invoke-Router -DataDir $data -Words @('--json')
        $r.ExitCode | Should -Be 0
        $text = $r.Out.Trim()
        $text[0] | Should -Be '{'
        $text[$text.Length - 1] | Should -Be '}'
        { $text | ConvertFrom-Json } | Should -Not -Throw
        $r.Out | Should -Match '"sessions":\s*\['
    }

    It 'H-17 prints the complete text on redirected stdout, without notices or prompts' {
        $data = New-LogDataDir $script:LogLines
        $r = Invoke-Router -DataDir $data -Words @()
        $r.ExitCode | Should -Be 0
        $r.Out | Should -Match 'clean\s+2026-10-15 10:00:00, removed 2'
        $r.Out | Should -Match 'removed\s+C:\\Temp\\two \(2\.0KB\)'
        $r.Out | Should -Match 'removed\s+C:\\Temp\\one \(1\.0KB\)'
        $r.Out.IndexOf('C:\Temp\two') | Should -BeLessThan $r.Out.IndexOf('C:\Temp\one')
        ($r.Out -replace '\\', '/') | Should -BeLike ('*' + ((Get-DataLogPath $data) -replace '\\', '/') + '*')
        $r.Out | Should -Not -Match '(?i)update'
        $r.Out | Should -Not -Match ([string][char]27)
    }

    It 'H-16 prints the JSON without an update notice' {
        $data = New-LogDataDir $script:LogLines
        $r = Invoke-Router -DataDir $data -Words @('--json')
        $r.Out | Should -Not -Match '(?i)update'
    }

    It 'H-14 treats the router limit forms and the direct script limit alike for -Limit as true plus the next word' {
        $data = New-LogDataDir $script:LogLines
        $r = Invoke-HistoryScript -DataDir $data -ArgText '-Limit:$true ''5'' -Json'
        $r.ExitCode | Should -Be 0
        ($r.Out | ConvertFrom-Json).limit | Should -Be 5
    }

    It 'H-14 accepts a numeric -Limit value given to the script directly' {
        $data = New-LogDataDir $script:LogLines
        $r = Invoke-HistoryScript -DataDir $data -ArgText '-Limit 7 -Json'
        $r.ExitCode | Should -Be 0
        ($r.Out | ConvertFrom-Json).limit | Should -Be 7
    }

    It 'H-14 rejects -Limit given without a value to the script directly with exit 2' {
        $data = New-LogDataDir $script:LogLines
        $r = Invoke-HistoryScript -DataDir $data -ArgText '-Limit:$true -Json'
        $r.ExitCode | Should -Be 2
        $r.Out | Should -Not -Match '"sessions"'
        $r.Both.Trim() | Should -Not -BeNullOrEmpty
    }

    It 'H-14 rejects a numeric -Limit 0 given to the script directly with exit 2' {
        $data = New-LogDataDir $script:LogLines
        $r = Invoke-HistoryScript -DataDir $data -ArgText '-Limit 0 -Json'
        $r.ExitCode | Should -Be 2
        $r.Out | Should -Not -Match '"sessions"'
    }

    It 'H-15 rejects a surplus positional word given to the script directly with exit 2' {
        $data = New-LogDataDir $script:LogLines
        $r = Invoke-HistoryScript -DataDir $data -ArgText '''extra'''
        $r.ExitCode | Should -Be 2
        $r.Both | Should -BeLike '*extra*'
        $r.Out | Should -Not -Match '\d{4}-\d{2}-\d{2} \d{2}:\d{2}'
    }

    It 'H-15 prints the help for -ShowHelp together with an invalid limit, exit 0' {
        $data = New-LogDataDir $script:LogLines
        $r = Invoke-HistoryScript -DataDir $data -ArgText '-ShowHelp -Limit:''0'' ''extra'''
        $r.ExitCode | Should -Be 0
        $r.Out | Should -BeLike '*sw history [[]OPTIONS]*'
    }

    It 'H-11 prints non-ASCII path characters unchanged in the JSON from the script' {
        $umlaut = 'C:\Users\Example\' + [char]0x00DC + 'bung'
        $cjk = 'C:\Users\Example\' + [char]0x65E5 + [char]0x672C
        $data = New-LogDataDir @(
            (New-Record '2026-10-15 10:00:01' 'clean' 'a1' 'REMOVED' $umlaut '1KB')
            (New-Record '2026-10-15 10:00:02' 'clean' 'a1' 'REMOVED' $cjk '1KB')
        )
        $r = Invoke-HistoryScript -DataDir $data -ArgText '-Json'
        $r.ExitCode | Should -Be 0
        $obj = $r.Out | ConvertFrom-Json
        $obj.operations[0].path | Should -Be $cjk
        $obj.operations[1].path | Should -Be $umlaut
    }

    It 'H-11 reads a log that starts with a BOM through the script' {
        $data = New-DataDir
        Write-FixtureText -Path (Get-DataLogPath $data) -Text (Join-LogLines $script:LogLines) -Bom
        $r = Invoke-HistoryScript -DataDir $data -ArgText '-Json'
        $r.ExitCode | Should -Be 0
        @(($r.Out | ConvertFrom-Json).operations).Count | Should -Be 2
    }
}

# ====================================================================================================
Describe 'sw history on real Windows (H-1, H-12, S2, S6)' {
    # These tests need Windows semantics: backslash data paths, share modes, ACLs. On Linux and macOS they
    # fail by design and belong in tests/linux-known-failures.txt.

    It 'H-1 reads %USERPROFILE%\.config\sweepr\operations.log in profile mode' {
        $profileDir = [System.IO.Path]::Combine($TestDrive, 'Example-' + [guid]::NewGuid().ToString('N'))
        $logPath = $profileDir + '\.config\sweepr\operations.log'
        Write-FixtureText -Path $logPath -Text (Join-LogLines (Get-ExampleLines))
        $r = Invoke-Child -ArgumentList @('-File', $script:RouterScript, 'history', '--json') -Environment @{ USERPROFILE = $profileDir }
        $r.ExitCode | Should -Be 0
        $obj = $r.Out | ConvertFrom-Json
        $obj.logs.operations | Should -Be $logPath
        @($obj.operations).Count | Should -Be 2
    }

    It 'H-1 reads data\config\operations.log next to the program folder in portable mode' {
        $root = [System.IO.Path]::Combine($TestDrive, 'portable-' + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::Combine($root, 'bin'))
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::Combine($root, 'lib'))
        Copy-Item -LiteralPath $script:HistoryScript -Destination ([System.IO.Path]::Combine($root, 'bin', 'history.ps1'))
        Copy-Item -LiteralPath $script:CoreDir -Destination ([System.IO.Path]::Combine($root, 'lib')) -Recurse
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($root, 'sweepr.portable'), '')
        $logPath = $root + '\data\config\operations.log'
        Write-FixtureText -Path $logPath -Text (Join-LogLines (Get-ExampleLines))
        $r = Invoke-HistoryScript -DataDir '' -ArgText '-Json' -ScriptPath ([System.IO.Path]::Combine($root, 'bin', 'history.ps1'))
        $r.ExitCode | Should -Be 0
        $obj = $r.Out | ConvertFrom-Json
        $obj.logs.operations | Should -Be $logPath
        @($obj.operations).Count | Should -Be 2
    }

    It 'H-12 throws instead of returning an empty history when another handle holds the log exclusively' {
        $path = New-LogFile (Get-ExampleLines)
        $stream = [System.IO.File]::Open($path, 'Open', 'ReadWrite', 'None')
        try {
            $err = Get-ErrorFrom { Read-SwHistory -Path $path }
            ($null -ne $err) | Should -BeTrue
            $err.FullyQualifiedErrorId | Should -Not -Match 'CommandNotFound'
        }
        finally { $stream.Dispose() }
    }

    It 'H-12 exits 1 with the path in the message and no history when another handle holds the log exclusively' {
        $data = New-LogDataDir (Get-ExampleLines)
        $logPath = Get-DataLogPath $data
        $stream = [System.IO.File]::Open($logPath, 'Open', 'ReadWrite', 'None')
        try {
            $r = Invoke-HistoryScript -DataDir $data -ArgText '-Json'
            $r.ExitCode | Should -Be 1
            $r.Out | Should -Not -Match '"sessions"'
            $r.Both | Should -BeLike "*$logPath*"
        }
        finally { $stream.Dispose() }
    }

    It 'S6 reads while a writer holds the log open for appending and allows readers (share mode Read)' {
        $path = New-LogFile (Get-ExampleLines)
        $writer = New-Object System.IO.FileStream $path, ([System.IO.FileMode]::Append), ([System.IO.FileAccess]::Write), ([System.IO.FileShare]::Read)
        try {
            $h = Read-SwHistory -Path $path
            @($h.Operations).Count | Should -Be 2
        }
        finally { $writer.Dispose() }
    }

    It 'S6 reads while a writer holds the log with read and write sharing' {
        $path = New-LogFile (Get-ExampleLines)
        $writer = New-Object System.IO.FileStream $path, ([System.IO.FileMode]::Append), ([System.IO.FileAccess]::Write), ([System.IO.FileShare]::ReadWrite)
        try {
            $h = Read-SwHistory -Path $path
            @($h.Operations).Count | Should -Be 2
        }
        finally { $writer.Dispose() }
    }

    It 'S6 lets the writer keep writing while the script reads the log' {
        $data = New-LogDataDir (Get-ExampleLines)
        $logPath = Get-DataLogPath $data
        $writer = New-Object System.IO.FileStream $logPath, ([System.IO.FileMode]::Append), ([System.IO.FileAccess]::Write), ([System.IO.FileShare]::Read)
        try {
            $r = Invoke-HistoryScript -DataDir $data -ArgText '-Json'
            $r.ExitCode | Should -Be 0
            $bytes = [System.Text.Encoding]::UTF8.GetBytes("`r`n# still writing`r`n")
            { $writer.Write($bytes, 0, $bytes.Length); $writer.Flush() } | Should -Not -Throw
        }
        finally { $writer.Dispose() }
    }

    It 'H-12 throws when access to the log is denied by an ACL' {
        $path = New-LogFile (Get-ExampleLines)
        $null = & icacls.exe $path '/deny' '*S-1-1-0:(R)'
        try {
            $err = Get-ErrorFrom { Read-SwHistory -Path $path }
            ($null -ne $err) | Should -BeTrue
            $err.FullyQualifiedErrorId | Should -Not -Match 'CommandNotFound'
        }
        finally { $null = & icacls.exe $path '/reset' }
    }

    It 'H-12 exits 1 with the path in the message when access to the log is denied by an ACL' {
        $data = New-LogDataDir (Get-ExampleLines)
        $logPath = Get-DataLogPath $data
        $null = & icacls.exe $logPath '/deny' '*S-1-1-0:(R)'
        try {
            $r = Invoke-HistoryScript -DataDir $data -ArgText '-Json'
            $r.ExitCode | Should -Be 1
            $r.Out | Should -Not -Match '"sessions"'
            $r.Both | Should -BeLike "*$logPath*"
        }
        finally { $null = & icacls.exe $logPath '/reset' }
    }
}
