# Sweepr - tests for Invoke-SwMain, the entry point of the router: the root words, the choice of the
# command, the order of the steps (data folder, update hint, run), the exit code, the menu round trip and
# the handling of errors (RT-4, RT-5, RT-10, RT-14 to RT-17, RT-20 to RT-22, S1 to S3, S11).
#
# The rule numbers in the test names (RT- and S) number the rules and the safety invariants of the
# router's behavior; each testable rule and invariant has at least one test. The other router files are
# SwRouterLoad (RT-1 to RT-3), SwRouterArgs (RT-5 to RT-10, RT-24), SwRouterCommand (RT-11 to RT-15),
# SwRouterScreens (RT-18 to RT-20, RT-23) and SwRouterProcess (the two call forms).
#
# Interface pinned here (sweepr.ps1 is loaded by dot-sourcing):
#   Invoke-SwMain -Arguments <string[]>   gives the exit code as an [int], the last item it writes to the
#       pipeline (the output of a command script comes before it); it never throws; it does not call exit.
#   After the call $global:LASTEXITCODE and $script:SweeprExitCode hold the code.
#
# Platform notes:
#   - The command scripts are stand-ins in $TestDrive (one per command, with the parameter block of the
#     real command). The modules the router calls are mocked where a test needs to see or stop them:
#     the debug session, the data folders, the update hint, the menu, help and version, Clear-Host.
#     USERPROFILE and SWEEPR_DATA_DIR point into $TestDrive while the tests run.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:RouterFile = Join-Path $script:RepoRoot 'sweepr.ps1'
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
    $script:EnvNames = @('SWEEPR_DATA_DIR', 'SWEEPR_DRY_RUN', 'SWEEPR_DEBUG', '_SWEEPR_OPLOG_RUN_COMMAND', '_SWEEPR_OPLOG_RUN_ID', 'USERPROFILE', 'HOME', 'SWEEPR_NO_OPLOG',
        'SW_TEST_THROW', 'SW_TEST_EXIT', 'SW_TEST_JSON', 'SW_TEST_SUFFIX')

    $script:SavedEnv = @{}
    foreach ($envName in $script:EnvNames) { $script:SavedEnv[$envName] = [System.Environment]::GetEnvironmentVariable($envName) }
    $script:SavedExitCode = $global:LASTEXITCODE

    $script:HomeDir = Join-Path $TestDrive 'main-home'
    [void][System.IO.Directory]::CreateDirectory($script:HomeDir)
    $env:USERPROFILE = $script:HomeDir
    $env:HOME = $script:HomeDir
    $env:SWEEPR_NO_OPLOG = '1'
    [System.Environment]::SetEnvironmentVariable('SWEEPR_DATA_DIR', [NullString]::Value)

    . $script:RouterFile

    $script:RealAssert = (Get-Command -Name Assert-SwDataWritable -CommandType Function).ScriptBlock
    $script:RealFolders = (Get-Command -Name Initialize-SwDataFolders -CommandType Function).ScriptBlock
    $script:RealAllowed = (Get-Command -Name Test-SwUpdateHintAllowed -CommandType Function).ScriptBlock
    $script:RealMenu = (Get-Command -Name Show-SwMenu -CommandType Function).ScriptBlock
    $script:RealError = (Get-Command -Name Write-SwError -CommandType Function).ScriptBlock

    $script:Blocks = [ordered]@{}
    $script:Blocks['clean'] = "[CmdletBinding()]`nparam([Alias('dry-run')][switch]`$DryRun, [Alias('s')][switch]`$System, [Alias('game-media')][switch]`$GameMedia, [Alias('gpu-shaders')][switch]`$GpuShaders, [Alias('d')][switch]`$DebugMode, [Alias('w')][switch]`$Whitelist, [Alias('h')][switch]`$ShowHelp)"
    $script:Blocks['uninstall'] = "[CmdletBinding()]`nparam([Alias('dry-run')][switch]`$DryRun, [Alias('d')][switch]`$DebugMode, [Alias('r')][switch]`$Rescan, [switch]`$List, [Alias('h')][switch]`$ShowHelp)"
    $script:Blocks['optimize'] = "[CmdletBinding()]`nparam([Alias('dry-run')][switch]`$DryRun, [Alias('d')][switch]`$DebugMode, [Alias('h')][switch]`$ShowHelp)"
    $script:Blocks['purge'] = "[CmdletBinding()]`nparam([Alias('dry-run')][switch]`$DryRun, [Alias('d')][switch]`$DebugMode, [Alias('p')][switch]`$Paths, [Alias('h')][switch]`$ShowHelp)"
    $script:Blocks['analyze'] = "[CmdletBinding()]`nparam([Parameter(Position = 0)][string]`$Path, [Alias('h')][switch]`$ShowHelp, [switch]`$Json, [Alias('d')][switch]`$DebugMode)"
    $script:Blocks['status'] = "[CmdletBinding(PositionalBinding = `$false)]`nparam([Alias('h')][switch]`$ShowHelp, [switch]`$Json, [switch]`$Watch, [string]`$Interval)"
    $script:Blocks['history'] = "[CmdletBinding(PositionalBinding = `$false)]`nparam([Alias('h')][switch]`$ShowHelp, [switch]`$Json, `$Limit, [Parameter(ValueFromRemainingArguments = `$true)][string[]]`$RemainingArguments)"
    $script:Blocks['features'] = "[CmdletBinding()]`nparam([Alias('dry-run')][switch]`$DryRun, [Alias('d')][switch]`$DebugMode, [switch]`$List, [Alias('all-users-future')][switch]`$AllUsersFuture, [switch]`$Restore, [Alias('h')][switch]`$ShowHelp)"
    $script:Blocks['check'] = "[CmdletBinding()]`nparam([switch]`$Json, [switch]`$Report, [Alias('no-open')][switch]`$NoOpen, [Alias('dry-run')][switch]`$DryRun, [Alias('d')][switch]`$DebugMode, [Alias('h')][switch]`$ShowHelp)"
    $script:Blocks['update'] = "[CmdletBinding()]`nparam([Alias('d')][switch]`$DebugMode, [Alias('h')][switch]`$ShowHelp)"
    $script:Blocks['remove'] = "[CmdletBinding()]`nparam([Alias('h')][switch]`$ShowHelp)"
    $script:Blocks['evil'] = "[CmdletBinding()]`nparam([Alias('h')][switch]`$ShowHelp)"

    # An unset variable is removed: .NET 8 treats an empty value as unset, newer .NET keeps it as an empty value.
    function script:Set-EnvValue {
        param([string]$Name, $Value)
        if ($null -eq $Value) { [System.Environment]::SetEnvironmentVariable($Name, [NullString]::Value) }
        else { [System.Environment]::SetEnvironmentVariable($Name, [string]$Value) }
    }

    function script:New-BinDir([string]$Path, [string[]]$Skip = @()) {
        [void][System.IO.Directory]::CreateDirectory($Path)
        foreach ($name in $script:Blocks.Keys) {
            if ($Skip -contains $name) { continue }
            $body = @"

if (Get-Variable -Name SwRunLog -Scope Global -ErrorAction SilentlyContinue) { `$global:SwRunLog.Add('script') }
if (`$env:SW_TEST_JSON) { `$env:SW_TEST_JSON; return }
'RAN:$name'
'BOUND=' + ((`$PSBoundParameters.Keys | Sort-Object) -join ',')
'COMMAND=[' + `$env:_SWEEPR_OPLOG_RUN_COMMAND + ']'
'DATA=[' + `$env:SWEEPR_DATA_DIR + ']'
if (`$env:SW_TEST_THROW) { throw ('boom' + [string]`$env:SW_TEST_SUFFIX) }
if (`$env:SW_TEST_EXIT) { exit ([int]`$env:SW_TEST_EXIT) }
"@
            [System.IO.File]::WriteAllText((Join-Path $Path "$name.ps1"), $script:Blocks[$name] + $body + "`n", $script:Utf8)
        }
        return $Path
    }
    $script:Bin = New-BinDir (Join-Path $TestDrive 'main-bin')
    $script:CopyRoot = Join-Path $TestDrive 'main-root'
    [void][System.IO.Directory]::CreateDirectory($script:CopyRoot)

    function script:Invoke-Captured([scriptblock]$Block) {
        $thrown = $null
        $records = @()
        try { $records = @(& $Block 6>&1) } catch { $thrown = $_ }
        $out = New-Object System.Collections.Generic.List[object]
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($record in $records) {
            if ($record -is [System.Management.Automation.InformationRecord]) { $lines.Add([string]$record.MessageData) }
            else { $out.Add($record) }
        }
        return [pscustomobject]@{ Output = $out.ToArray(); Lines = $lines.ToArray(); Text = ($lines -join "`n"); Thrown = $thrown }
    }
    # Invoke-SwMain: the code is the last item written, the rest is the output of the command.
    function script:Invoke-Main([string[]]$Words) {
        $script:CallWords = $Words
        $script:SweeprExitCode = 55
        $captured = Invoke-Captured { Invoke-SwMain -Arguments $script:CallWords }
        $all = @($captured.Output)
        $code = $null
        $rest = @()
        if ($all.Count -gt 0) {
            $code = $all[$all.Count - 1]
            if ($all.Count -gt 1) { $rest = @($all[0..($all.Count - 2)]) }
        }
        return [pscustomobject]@{ Code = $code; Output = $rest; Lines = $captured.Lines; Text = $captured.Text; Thrown = $captured.Thrown }
    }
    function script:Get-Value($Result, [string]$Key) {
        foreach ($line in @($Result.Output)) { if (([string]$line).StartsWith($Key + '=')) { return ([string]$line).Substring($Key.Length + 1) } }
        return $null
    }
    function script:Get-NormalPath([string]$Path) { return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/') }
}

AfterAll {
    foreach ($envName in $script:SavedEnv.Keys) { Set-EnvValue -Name $envName -Value $script:SavedEnv[$envName] }
    $global:LASTEXITCODE = $script:SavedExitCode
    Remove-Variable -Name SwRunLog -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Invoke-SwMain' {
    BeforeEach {
        foreach ($envName in @('SWEEPR_DRY_RUN', 'SWEEPR_DEBUG', '_SWEEPR_OPLOG_RUN_COMMAND', '_SWEEPR_OPLOG_RUN_ID', 'SW_TEST_THROW', 'SW_TEST_EXIT', 'SW_TEST_JSON', 'SW_TEST_SUFFIX', 'SWEEPR_DATA_DIR')) {
            Set-EnvValue -Name $envName -Value $null
        }
        $script:SWEEPR_BIN = $script:Bin
        $script:SWEEPR_ROOT = $script:CopyRoot
        $script:SWEEPR_VER = '1.2.3'
        $script:SweeprExitCode = 0
        $global:LASTEXITCODE = 0
        $script:Errors = New-Object System.Collections.Generic.List[string]
        $script:Sessions = New-Object System.Collections.Generic.List[object]
        $global:SwRunLog = New-Object System.Collections.Generic.List[string]
        $script:Events = $global:SwRunLog
        $script:Asserted = New-Object System.Collections.Generic.List[string]
        Mock Write-SwError { $script:Errors.Add([string]$Message); $script:Events.Add('error'); Write-Host $Message }
        Mock Start-SwDebugSession { $script:Sessions.Add(@($Header)); $script:Events.Add('session') }
        Mock Complete-SwDebugSession { $script:Events.Add('complete') }
        Mock Initialize-SwDataFolders { $script:Events.Add('folders') }
        Mock Assert-SwDataWritable { $script:Asserted.Add([string]$Path); $script:Events.Add('assert') }
        Mock Test-SwUpdateHintAllowed { $false }
        Mock Start-SwUpdateProbe { $script:Events.Add('probe'); 'context' }
        Mock Write-SwUpdateHint { $script:Events.Add('hint') }
        Mock Show-SwLogo { }
        Mock Clear-Host { $script:Events.Add('clear') }
        Mock Show-SwMenu { $script:Events.Add('menu'); $null }
        Mock Show-SwHelp { $script:Events.Add('help') }
        Mock Show-SwVersion { $script:Events.Add('version') }
        Mock Invoke-WebRequest { throw 'the router uses no network' }
        Mock Invoke-RestMethod { throw 'the router uses no network' }
        Mock Start-Process { throw 'the router starts no process of its own' }
    }
    AfterEach {
        foreach ($envName in @('SWEEPR_DRY_RUN', 'SWEEPR_DEBUG', '_SWEEPR_OPLOG_RUN_COMMAND', '_SWEEPR_OPLOG_RUN_ID', 'SW_TEST_THROW', 'SW_TEST_EXIT', 'SW_TEST_JSON', 'SW_TEST_SUFFIX', 'SWEEPR_DATA_DIR')) {
            Set-EnvValue -Name $envName -Value $null
        }
    }

    Context 'the root words (RT-4)' {
        It 'Runs the command and gives the code 0 as an integer' {
            $result = Invoke-Main @('clean', '--dry-run')
            $result.Thrown | Should -BeNullOrEmpty
            $result.Code | Should -BeOfType [int]
            $result.Code | Should -Be 0
            Get-Value $result 'BOUND' | Should -BeExactly 'DryRun'
            @($result.Output)[0] | Should -BeExactly 'RAN:clean'
        }

        It 'Takes a leading --debug as the last word of the command: <First>' -ForEach @(
            @{ First = '--debug' }
            @{ First = '-debug' }
            @{ First = '--DEBUG' }
            @{ First = '-Debug' }
        ) {
            $result = Invoke-Main @($First, 'clean', '--dry-run')
            Get-Value $result 'BOUND' | Should -BeExactly 'DebugMode,DryRun'
            $script:Sessions.Count | Should -Be 1
            @($script:Sessions[0])[1] | Should -BeExactly 'Command: sw clean --dry-run --debug'
        }

        It 'Takes a leading --debug with the command alone' {
            $result = Invoke-Main @('--debug', 'update')
            Get-Value $result 'BOUND' | Should -BeExactly 'DebugMode'
            @($script:Sessions[0])[1] | Should -BeExactly 'Command: sw update --debug'
        }

        It 'Treats --debug alone as an unknown command' {
            $result = Invoke-Main @('--debug')
            $result.Code | Should -Be 2
            $script:Errors[0] | Should -BeLike 'Unknown command: --debug*'
            $script:Sessions.Count | Should -Be 0
        }

        It 'Takes only one leading --debug: the second one is the command, and an unknown one' {
            $result = Invoke-Main @('--debug', '--debug', 'clean')
            $result.Code | Should -Be 2
            $script:Errors[0] | Should -BeLike 'Unknown command: --debug*'
        }

        It 'Skips empty and blank words before the first word: <Words>' -ForEach @(
            @{ Words = @('', 'clean') }
            @{ Words = @('', '  ', 'clean', '--dry-run') }
            @{ Words = @("`t", 'clean') }
        ) {
            $result = Invoke-Main $Words
            @($result.Output)[0] | Should -BeExactly 'RAN:clean'
            $result.Code | Should -Be 0
        }

        It 'Opens the menu for no word, for an empty word and for blank words only' -ForEach @(
            @{ Words = @() }
            @{ Words = @('') }
            @{ Words = @('', '  ') }
        ) {
            $result = Invoke-Main $Words
            $result.Code | Should -Be 0
            $script:Events | Should -Contain 'menu'
            @($result.Output).Count | Should -Be 0
        }

        It 'Shows the help of the router for <Word>, ignores the words after it, and gives 0' -ForEach @(
            @{ Word = '--help' }
            @{ Word = '-h' }
            @{ Word = '-help' }
            @{ Word = '--showhelp' }
            @{ Word = '-ShowHelp' }
            @{ Word = '--HELP' }
            @{ Word = '-H' }
        ) {
            $result = Invoke-Main @($Word, 'clean', '--bogus')
            $result.Code | Should -Be 0
            @($script:Events | Where-Object { $_ -eq 'help' }).Count | Should -Be 1
            $script:Events | Should -Not -Contain 'version'
            @($result.Output).Count | Should -Be 0
        }

        It 'Shows the version for <Word> and gives 0' -ForEach @(
            @{ Word = '--version' }
            @{ Word = '-v' }
            @{ Word = '-version' }
            @{ Word = '--VERSION' }
            @{ Word = '-V' }
        ) {
            $result = Invoke-Main @($Word)
            $result.Code | Should -Be 0
            @($script:Events | Where-Object { $_ -eq 'version' }).Count | Should -Be 1
            $script:Events | Should -Not -Contain 'help'
        }

        It 'Takes the first word when both are given' {
            $null = Invoke-Main @('--version', '--help')
            @($script:Events | Where-Object { $_ -in 'help', 'version' }) | Should -Be @('version')
            $script:Events.Clear()
            $null = Invoke-Main @('--help', '--version')
            @($script:Events | Where-Object { $_ -in 'help', 'version' }) | Should -Be @('help')
        }

        It 'Shows the help of the command, not of the router, for clean --help' {
            $result = Invoke-Main @('clean', '--help')
            Get-Value $result 'BOUND' | Should -BeExactly 'ShowHelp'
            $script:Events | Should -Not -Contain 'help'
        }

        It 'Treats help and /? without a hyphen as unknown commands' -ForEach @(
            @{ Word = 'help' }
            @{ Word = '/?' }
            @{ Word = 'version' }
            @{ Word = '?' }
        ) {
            $result = Invoke-Main @($Word)
            $result.Code | Should -Be 2
            $script:Errors[0] | Should -BeLike "Unknown command: $([WildcardPattern]::Escape($Word))*"
            $script:Events | Should -Not -Contain 'help'
        }

        It 'Gives -v to the command, which rejects it, instead of showing the version' {
            $result = Invoke-Main @('clean', '-v')
            $result.Code | Should -Be 2
            $script:Errors[0] | Should -BeLike 'Unknown option for sw clean: *-v'
            $script:Events | Should -Not -Contain 'version'
        }
    }

    Context 'the name of the command (RT-5, S1)' {
        It 'Runs the command <Word> in any letter case with its name in lower case' -ForEach @(
            @{ Word = 'CLEAN' }
            @{ Word = 'Clean' }
            @{ Word = 'cLeAn' }
        ) {
            $result = Invoke-Main @($Word, '--dry-run')
            $result.Code | Should -Be 0
            @($result.Output)[0] | Should -BeExactly 'RAN:clean'
            Get-Value $result 'COMMAND' | Should -BeExactly '[clean]'
        }

        It 'Runs each of the eleven commands' -ForEach @(
            @('clean', 'uninstall', 'analyze', 'status', 'optimize', 'purge', 'history', 'features', 'check', 'update', 'remove') | ForEach-Object { @{ Command = $_ } }
        ) {
            $result = Invoke-Main @($Command)
            $result.Code | Should -Be 0
            @($result.Output)[0] | Should -BeExactly "RAN:$Command"
            Get-Value $result 'COMMAND' | Should -BeExactly "[$Command]"
        }

        It 'Rejects a name that is not on the list, also when a script of that name is in the folder' -ForEach @(
            @{ Word = 'evil' }
            @{ Word = 'inspect' }
            @{ Word = 'nonsense' }
        ) {
            $result = Invoke-Main @($Word)
            $result.Code | Should -Be 2
            $script:Errors[0] | Should -BeLike "Unknown command: $Word*"
            @($result.Output).Count | Should -Be 0
        }

        It 'Names the valid commands in the hint, and neither inspect nor the folder content' {
            $result = Invoke-Main @('nonsense')
            $result.Text | Should -Match 'sw --help'
            foreach ($name in 'clean', 'uninstall', 'analyze', 'status', 'optimize', 'purge', 'history', 'features', 'check', 'update', 'remove') { $result.Text | Should -Match "\b$name\b" }
            $result.Text | Should -Not -Match 'evil'
            $result.Text | Should -Not -Match 'inspect'
        }

        It 'Rejects a word that is code or a path as an unknown command and runs nothing: <Word>' -ForEach @(
            @{ Word = 'x; calc' }
            @{ Word = '$(calc)' }
            @{ Word = 'it''s' }
            @{ Word = '..\bin\clean' }
            @{ Word = '../bin/clean' }
            @{ Word = 'clean.ps1' }
            @{ Word = 'C:\Windows\System32\calc.exe' }
            @{ Word = 'a`b' }
            @{ Word = 'a b' }
            @{ Word = '-' }
            @{ Word = '--' }
            @{ Word = '*' }
            @{ Word = 'cle[a]n' }
        ) {
            $result = Invoke-Main @($Word)
            $result.Code | Should -Be 2
            $script:Errors[0] | Should -BeLike 'Unknown command: *'
            $script:Errors[0].Contains($Word) | Should -BeTrue
            @($result.Output).Count | Should -Be 0
            $script:Sessions.Count | Should -Be 0
        }

        It 'Reports a damaged installation with exit 1 when the script of a valid command is missing' {
            $bin = New-BinDir (Join-Path $TestDrive 'main-bin-damaged') -Skip @('clean')
            $script:SWEEPR_BIN = $bin
            $result = Invoke-Main @('clean')
            $result.Code | Should -Be 1
            $script:Errors[0] | Should -Match 'clean'
            $script:Errors[0] | Should -Not -BeLike 'Unknown command:*'
        }
    }

    Context 'a rejection changes nothing (RT-10, S2)' {
        It 'Starts nothing and creates nothing for <Case>' -ForEach @(
            @{ Case = 'an unknown option'; Words = @('clean', '--bogus'); Pattern = 'Unknown option for sw clean: *--bogus'; Hint = 'sw clean --help' }
            @{ Case = 'the common parameter --verbose'; Words = @('clean', '--verbose'); Pattern = 'Unknown option for sw clean: *--verbose'; Hint = 'sw clean --help' }
            @{ Case = 'the common parameter -Verbose'; Words = @('clean', '-Verbose'); Pattern = 'Unknown option for sw clean: *-Verbose'; Hint = 'sw clean --help' }
            @{ Case = 'a value for a switch'; Words = @('clean', '--dry-run=false'); Pattern = 'Option takes no value for sw clean: *--dry-run=false'; Hint = 'sw clean --help' }
            @{ Case = 'a missing value'; Words = @('status', '--interval'); Pattern = 'Option needs a value for sw status: *--interval'; Hint = 'sw status --help' }
            @{ Case = 'a word for update'; Words = @('update', 'help'); Pattern = 'Unexpected argument for sw update: *help'; Hint = 'sw update --help' }
            @{ Case = 'a second word for analyze'; Words = @('analyze', 'a', 'b'); Pattern = 'Unexpected argument for sw analyze: *b'; Hint = 'sw analyze --help' }
            @{ Case = '--debug for history'; Words = @('history', '--debug'); Pattern = 'Unknown option for sw history: *--debug'; Hint = 'sw history --help' }
            @{ Case = '--debug for status'; Words = @('--debug', 'status'); Pattern = 'Unknown option for sw status: *--debug'; Hint = 'sw status --help' }
            @{ Case = 'an unknown command'; Words = @('nonsense'); Pattern = 'Unknown command: nonsense*'; Hint = 'sw --help' }
        ) {
            $env:_SWEEPR_OPLOG_RUN_ID = 'before-id'
            $env:SWEEPR_DRY_RUN = 'user dry'
            $result = Invoke-Main $Words
            $result.Thrown | Should -BeNullOrEmpty
            $result.Code | Should -Be 2
            $script:SweeprExitCode | Should -Be 2
            $global:LASTEXITCODE | Should -Be 2
            $script:Errors[0] | Should -BeLike $Pattern
            $result.Text | Should -Match ([regex]::Escape($Hint))
            @($result.Output).Count | Should -Be 0
            Should -Invoke Start-SwUpdateProbe -Times 0 -Exactly
            Should -Invoke Test-SwUpdateHintAllowed -Times 0 -Exactly
            Should -Invoke Write-SwUpdateHint -Times 0 -Exactly
            Should -Invoke Start-SwDebugSession -Times 0 -Exactly
            Should -Invoke Complete-SwDebugSession -Times 0 -Exactly
            Should -Invoke Initialize-SwDataFolders -Times 0 -Exactly
            Should -Invoke Assert-SwDataWritable -Times 0 -Exactly
            $env:_SWEEPR_OPLOG_RUN_ID | Should -BeExactly 'before-id'
            $env:SWEEPR_DRY_RUN | Should -BeExactly 'user dry'
            [System.Environment]::GetEnvironmentVariable('_SWEEPR_OPLOG_RUN_COMMAND') | Should -BeNullOrEmpty
            [System.Environment]::GetEnvironmentVariable('SWEEPR_DEBUG') | Should -BeNullOrEmpty
        }

        It 'Does not even look for the data folders for a rejection, help or version' -ForEach @(
            @{ Words = @('clean', '--bogus') }
            @{ Words = @('nonsense') }
            @{ Words = @('--help') }
            @{ Words = @('--version') }
        ) {
            Mock Resolve-SwDataPaths { throw 'the data folders must not be looked at' }
            $result = Invoke-Main $Words
            $result.Thrown | Should -BeNullOrEmpty
            Should -Invoke Resolve-SwDataPaths -Times 0 -Exactly
        }

        It 'Creates no file in the profile or the working directory for a rejection' {
            $before = @(Get-ChildItem -LiteralPath $script:HomeDir -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
            $null = Invoke-Main @('clean', '--bogus')
            @(Get-ChildItem -LiteralPath $script:HomeDir -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) | Should -Be $before
        }
    }

    Context 'the exit code (RT-14, S11)' {
        It 'Gives the exit code of the command as the result, in $global:LASTEXITCODE and in $script:SweeprExitCode: <Code>' -ForEach @(
            @{ Code = 1 }
            @{ Code = 3 }
            @{ Code = 7 }
            @{ Code = 255 }
        ) {
            $env:SW_TEST_EXIT = [string]$Code
            $result = Invoke-Main @('status')
            $result.Code | Should -Be $Code
            $script:SweeprExitCode | Should -Be $Code
            $global:LASTEXITCODE | Should -Be $Code
        }

        It 'Leaves $global:LASTEXITCODE at 0 after a success, whatever it was before' {
            $global:LASTEXITCODE = 9
            $result = Invoke-Main @('status')
            $result.Code | Should -Be 0
            $global:LASTEXITCODE | Should -Be 0
        }

        It 'Leaves $global:LASTEXITCODE at 0 after help, version and the menu' -ForEach @(
            @{ Words = @('--help') }
            @{ Words = @('--version') }
            @{ Words = @() }
        ) {
            $global:LASTEXITCODE = 9
            $result = Invoke-Main $Words
            $result.Code | Should -Be 0
            $global:LASTEXITCODE | Should -Be 0
        }

        It 'Puts the output of the command before the code' {
            $result = Invoke-Main @('clean')
            @($result.Output).Count | Should -BeGreaterThan 2
            @($result.Output)[0] | Should -BeExactly 'RAN:clean'
        }

        It 'Does not call exit' {
            $env:SW_TEST_EXIT = '5'
            $result = Invoke-Main @('clean')
            $result.Code | Should -Be 5
        }
    }

    Context 'putting the environment back (RT-15, S3)' {
        It 'Leaves SWEEPR_DRY_RUN and the run values as they were' {
            $env:SWEEPR_DRY_RUN = 'user dry'
            $env:_SWEEPR_OPLOG_RUN_ID = 'before-id'
            $null = Invoke-Main @('clean', '--dry-run')
            $env:SWEEPR_DRY_RUN | Should -BeExactly 'user dry'
            $env:_SWEEPR_OPLOG_RUN_ID | Should -BeExactly 'before-id'
            [System.Environment]::GetEnvironmentVariable('_SWEEPR_OPLOG_RUN_COMMAND') | Should -BeNullOrEmpty
        }

        It 'Leaves SWEEPR_DEBUG unset after a run with --debug' {
            Mock Start-SwDebugSession { $env:SWEEPR_DEBUG = '1' }
            $null = Invoke-Main @('clean', '--debug')
            [System.Environment]::GetEnvironmentVariable('SWEEPR_DEBUG') | Should -BeNullOrEmpty
            $next = Invoke-Main @('clean')
            [System.Environment]::GetEnvironmentVariable('SWEEPR_DEBUG') | Should -BeNullOrEmpty
            $next.Code | Should -Be 0
        }
    }

    Context 'the data folder (RT-16, S4)' {
        It 'Sets SWEEPR_DATA_DIR to the data folder of a portable installation for the command and puts it back' {
            $root = Join-Path $TestDrive 'main-portable'
            [void][System.IO.Directory]::CreateDirectory($root)
            [System.IO.File]::WriteAllText((Join-Path $root 'sweepr.portable'), '')
            $script:SWEEPR_ROOT = $root
            $result = Invoke-Main @('clean')
            $result.Code | Should -Be 0
            $data = (Get-Value $result 'DATA').Trim('[', ']')
            Get-NormalPath $data | Should -BeExactly (Get-NormalPath ([System.IO.Path]::Combine($root, 'data')))
            [System.Environment]::GetEnvironmentVariable('SWEEPR_DATA_DIR') | Should -BeNullOrEmpty
        }

        It 'Checks the config and the cache folder of a portable installation for writing, before it creates the folders' {
            $root = Join-Path $TestDrive 'main-portable-order'
            [void][System.IO.Directory]::CreateDirectory($root)
            [System.IO.File]::WriteAllText((Join-Path $root 'sweepr.portable'), '')
            $script:SWEEPR_ROOT = $root
            $null = Invoke-Main @('clean')
            $script:Asserted.Count | Should -Be 2
            Get-NormalPath $script:Asserted[0] | Should -BeExactly (Get-NormalPath ([System.IO.Path]::Combine($root, 'data', 'config')))
            Get-NormalPath $script:Asserted[1] | Should -BeExactly (Get-NormalPath ([System.IO.Path]::Combine($root, 'data', 'cache')))
            $script:Events.IndexOf('folders') | Should -BeGreaterThan $script:Events.LastIndexOf('assert')
            Should -Invoke Initialize-SwDataFolders -Times 1 -Exactly
        }

        It 'Gives the command the normalized override folder and puts the typed value back' {
            $folder = Join-Path $TestDrive 'main-override'
            $typed = "  $folder  "
            Set-EnvValue -Name 'SWEEPR_DATA_DIR' -Value $typed
            $result = Invoke-Main @('clean')
            $result.Code | Should -Be 0
            $data = (Get-Value $result 'DATA').Trim('[', ']')
            Get-NormalPath $data | Should -BeExactly (Get-NormalPath $folder)
            $data | Should -Not -Match '^\s|\s$'
            [System.Environment]::GetEnvironmentVariable('SWEEPR_DATA_DIR') | Should -BeExactly $typed
            $script:Asserted.Count | Should -Be 2
        }

        It 'Leaves SWEEPR_DATA_DIR alone and checks nothing for the profile mode' {
            $result = Invoke-Main @('clean')
            $result.Code | Should -Be 0
            Get-Value $result 'DATA' | Should -BeExactly '[]'
            Should -Invoke Assert-SwDataWritable -Times 0 -Exactly
            Should -Invoke Initialize-SwDataFolders -Times 1 -Exactly
        }

        It 'Runs the data steps before the update hint and the command, and for the menu too' {
            Mock Test-SwUpdateHintAllowed { $true }
            $null = Invoke-Main @('clean')
            $script:Events.IndexOf('folders') | Should -BeLessThan $script:Events.IndexOf('probe')
            $script:Events.IndexOf('folders') | Should -BeLessThan $script:Events.IndexOf('script')
            $script:Events.Clear()
            $null = Invoke-Main @()
            $script:Events.IndexOf('folders') | Should -BeLessThan $script:Events.IndexOf('menu')
            Should -Invoke Initialize-SwDataFolders -Times 2 -Exactly
        }

        It 'Stops with the message of the check, exit 1 and nothing created when the data folder is not writable' {
            $message = 'Sweepr data folder is not writable: X:\data\config. Sweepr does not fall back to your user profile.'
            $script:ThrownMessage = $message
            Mock Assert-SwDataWritable { throw $script:ThrownMessage }
            Set-EnvValue -Name 'SWEEPR_DATA_DIR' -Value (Join-Path $TestDrive 'main-unwritable')
            $result = Invoke-Main @('clean')
            $result.Thrown | Should -BeNullOrEmpty
            $result.Code | Should -Be 1
            $script:Errors.Count | Should -Be 1
            $script:Errors[0] | Should -BeExactly $message
            @($result.Output).Count | Should -Be 0
            Should -Invoke Initialize-SwDataFolders -Times 0 -Exactly
            Should -Invoke Start-SwUpdateProbe -Times 0 -Exactly
            [System.Environment]::GetEnvironmentVariable('SWEEPR_DATA_DIR') | Should -BeExactly (Join-Path $TestDrive 'main-unwritable')
        }

        It 'Stops with the real message and creates nothing in the profile when the override folder is below a file' {
            Mock Assert-SwDataWritable { & $script:RealAssert $Path }
            Mock Initialize-SwDataFolders { throw 'the folders must not be created' }
            $blocker = Join-Path $TestDrive 'main-blocker'
            [System.IO.File]::WriteAllText($blocker, 'a file')
            Set-EnvValue -Name 'SWEEPR_DATA_DIR' -Value (Join-Path $blocker 'sub')
            $before = @(Get-ChildItem -LiteralPath $script:HomeDir -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
            $result = Invoke-Main @('clean')
            $result.Code | Should -Be 1
            $script:Errors[0] | Should -BeLike 'Sweepr data folder is not writable: *'
            $script:Errors[0] | Should -BeLike '*does not fall back to your user profile.'
            $script:Errors[0] | Should -Not -BeLike 'Error*'
            @($result.Output).Count | Should -Be 0
            @(Get-ChildItem -LiteralPath $script:HomeDir -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) | Should -Be $before
        }

        It 'Creates the config and cache folder of a writable override folder' {
            $folder = Join-Path $TestDrive 'main-real-folders'
            $savedConfig = $script:Config.ConfigPath
            $savedCache = $script:Config.CachePath
            try {
                Set-EnvValue -Name 'SWEEPR_DATA_DIR' -Value $folder
                $script:Config.ConfigPath = [System.IO.Path]::Combine($folder, 'config')
                $script:Config.CachePath = [System.IO.Path]::Combine($folder, 'cache')
                Mock Assert-SwDataWritable { & $script:RealAssert $Path }
                Mock Initialize-SwDataFolders { & $script:RealFolders }
                $result = Invoke-Main @('clean')
                $result.Code | Should -Be 0
                [System.IO.Directory]::Exists([System.IO.Path]::Combine($folder, 'config')) | Should -BeTrue
                [System.IO.Directory]::Exists([System.IO.Path]::Combine($folder, 'cache')) | Should -BeTrue
            }
            finally {
                $script:Config.ConfigPath = $savedConfig
                $script:Config.CachePath = $savedCache
            }
        }

        It 'Shows the version of a portable installation whose folder cannot be written, with exit 0' {
            $root = Join-Path $TestDrive 'main-portable-readonly'
            [void][System.IO.Directory]::CreateDirectory($root)
            [System.IO.File]::WriteAllText((Join-Path $root 'sweepr.portable'), '')
            $script:SWEEPR_ROOT = $root
            Mock Assert-SwDataWritable { throw 'Sweepr data folder is not writable: X' }
            $result = Invoke-Main @('--version')
            $result.Code | Should -Be 0
            $script:Events | Should -Contain 'version'
            Should -Invoke Assert-SwDataWritable -Times 0 -Exactly
        }
    }

    Context 'the update hint (RT-17)' {
        BeforeEach {
            Mock Test-SwUpdateHintAllowed { $true }
        }

        It 'Asks whether a hint is allowed, starts the probe for this installation before the command, and shows the hint after it' {
            $null = Invoke-Main @('clean', '--dry-run')
            Should -Invoke Test-SwUpdateHintAllowed -Times 1 -Exactly -ParameterFilter { $CommandName -eq 'clean' -and @($Arguments) -contains '--dry-run' }
            Should -Invoke Start-SwUpdateProbe -Times 1 -Exactly -ParameterFilter {
                $RootDir -eq $script:SWEEPR_ROOT -and $Version -eq $script:SWEEPR_VER -and $Method -eq (Get-SwInstallMethod -RootDir $script:SWEEPR_ROOT)
            }
            Should -Invoke Write-SwUpdateHint -Times 1 -Exactly -ParameterFilter { $Context -eq 'context' }
            $script:Events.IndexOf('probe') | Should -BeLessThan $script:Events.IndexOf('hint')
        }

        It 'Runs the steps in this order: data folders, probe, script, hint' {
            $null = Invoke-Main @('status')
            @($script:Events | Where-Object { $_ -in 'folders', 'probe', 'script', 'hint' }) | Should -Be @('folders', 'probe', 'script', 'hint')
        }

        It 'Shows no hint after a command that exits with an error, but starts the probe before it' {
            $env:SW_TEST_EXIT = '3'
            $result = Invoke-Main @('clean')
            $result.Code | Should -Be 3
            Should -Invoke Start-SwUpdateProbe -Times 1 -Exactly
            Should -Invoke Write-SwUpdateHint -Times 0 -Exactly
        }

        It 'Starts no probe when no hint is allowed' {
            Mock Test-SwUpdateHintAllowed { $false }
            $null = Invoke-Main @('clean', '--dry-run')
            Should -Invoke Start-SwUpdateProbe -Times 0 -Exactly
        }

        It 'Starts no probe and shows no hint for help, version and rejections' -ForEach @(
            @{ Words = @('--help') }
            @{ Words = @('--version') }
            @{ Words = @('nonsense') }
            @{ Words = @('clean', '--bogus') }
            @{ Words = @('update', 'help') }
        ) {
            $null = Invoke-Main $Words
            Should -Invoke Start-SwUpdateProbe -Times 0 -Exactly
            Should -Invoke Write-SwUpdateHint -Times 0 -Exactly
        }

        It 'Allows no hint for the runs that must stay clean: <Words>' -ForEach @(
            @{ Words = @('analyze', '--json') }
            @{ Words = @('status', '--json') }
            @{ Words = @('status', '--watch') }
            @{ Words = @('uninstall', '--list') }
            @{ Words = @('clean', '--dry-run') }
            @{ Words = @('clean', '--help') }
            @{ Words = @('update') }
            @{ Words = @('history') }
            @{ Words = @('features') }
            @{ Words = @('check') }
        ) {
            # The real decision of the update module, not a mock of it.
            Mock Test-SwUpdateHintAllowed { & $script:RealAllowed @PesterBoundParameters }
            $null = Invoke-Main $Words
            Should -Invoke Start-SwUpdateProbe -Times 0 -Exactly
            Should -Invoke Write-SwUpdateHint -Times 0 -Exactly
        }

        It 'Writes no line of its own for the hint decision, in the output of the command' {
            $result = Invoke-Main @('status', '--json')
            @($result.Lines | Where-Object { $_ -ne '' }).Count | Should -Be 0
        }
    }

    Context 'the menu (RT-20)' {
        It 'Starts the probe once before the menu and gives the menu its context' {
            Mock Test-SwUpdateHintAllowed { $true }
            Mock Show-SwMenu { $script:Events.Add('menu'); $script:MenuContext = $UpdateContext; $null }
            $script:MenuContext = 'not set'
            $result = Invoke-Main @()
            $result.Code | Should -Be 0
            Should -Invoke Start-SwUpdateProbe -Times 1 -Exactly
            Should -Invoke Test-SwUpdateHintAllowed -Times 1 -Exactly -ParameterFilter { [string]::IsNullOrEmpty($CommandName) }
            $script:MenuContext | Should -BeExactly 'context'
            $script:Events.IndexOf('probe') | Should -BeLessThan $script:Events.IndexOf('menu')
        }

        It 'Clears the screen once after the menu returns: <Choice>' -ForEach @(
            @{ Choice = $null }
            @{ Choice = 'help' }
            @{ Choice = 'version' }
            @{ Choice = 'status' }
        ) {
            $script:Choice = $Choice
            Mock Show-SwMenu { $script:Events.Add('menu'); $script:Choice }
            $null = Invoke-Main @()
            @($script:Events | Where-Object { $_ -eq 'clear' }).Count | Should -Be 1
            $script:Events.IndexOf('clear') | Should -BeGreaterThan $script:Events.IndexOf('menu')
        }

        It 'Gives 0 and runs nothing when the menu is left without a choice' {
            $result = Invoke-Main @()
            $result.Code | Should -Be 0
            @($result.Output).Count | Should -Be 0
        }

        It 'Shows the help after the menu returns help, and the version after it returns version' {
            Mock Show-SwMenu { $script:Events.Add('menu'); 'help' }
            $null = Invoke-Main @()
            $script:Events | Should -Contain 'help'
            $script:Events.Clear()
            Mock Show-SwMenu { $script:Events.Add('menu'); 'version' }
            $null = Invoke-Main @()
            $script:Events | Should -Contain 'version'
        }

        It 'Runs the chosen command once with no words and then ends: no second menu' {
            Mock Show-SwMenu { $script:Events.Add('menu'); 'status' }
            $result = Invoke-Main @()
            $result.Code | Should -Be 0
            @($result.Output)[0] | Should -BeExactly 'RAN:status'
            Get-Value $result 'BOUND' | Should -BeExactly ''
            @($script:Events | Where-Object { $_ -eq 'menu' }).Count | Should -Be 1
        }

        It 'Gives the exit code of the chosen command' {
            Mock Show-SwMenu { 'clean' }
            $env:SW_TEST_EXIT = '4'
            (Invoke-Main @()).Code | Should -Be 4
        }

        It 'Shows the hint after a chosen command that succeeded, and not after one that failed' {
            Mock Test-SwUpdateHintAllowed { $true }
            Mock Show-SwMenu { 'status' }
            $null = Invoke-Main @()
            Should -Invoke Write-SwUpdateHint -Times 1 -Exactly -ParameterFilter { $Context -eq 'context' }
            Should -Invoke Start-SwUpdateProbe -Times 1 -Exactly
            $env:SW_TEST_EXIT = '3'
            $null = Invoke-Main @()
            Should -Invoke Write-SwUpdateHint -Times 1 -Exactly
        }

        It 'Ends with a message and exit 1, and does not hang, when no key can be read' {
            Mock Show-SwMenu { & $script:RealMenu @PesterBoundParameters }
            Mock Read-SwMenuKey { throw 'Cannot read a key: the input is redirected.' }
            $result = Invoke-Main @()
            $result.Thrown | Should -BeNullOrEmpty
            $result.Code | Should -Be 1
            $script:Errors.Count | Should -BeGreaterThan 0
            $script:Errors[0] | Should -Match 'Cannot read a key'
        }
    }

    Context 'errors (RT-21)' {
        It 'Catches an exception of the command: a blank line, the message, a blank line, exit 1' {
            $env:SW_TEST_THROW = '1'
            $result = Invoke-Main @('clean')
            $result.Thrown | Should -BeNullOrEmpty
            $result.Code | Should -Be 1
            $script:SweeprExitCode | Should -Be 1
            $global:LASTEXITCODE | Should -Be 1
            $script:Errors.Count | Should -Be 1
            $script:Errors[0] | Should -Match 'boom'
            $lines = @($result.Lines)
            $lines.Count | Should -Be 3
            $lines[0] | Should -BeExactly ''
            $lines[1] | Should -Match 'boom'
            $lines[2] | Should -BeExactly ''
        }

        It 'Has ended the debug session and put the environment back before it reports the exception' {
            $env:SW_TEST_THROW = '1'
            $env:SWEEPR_DRY_RUN = 'user dry'
            $null = Invoke-Main @('clean', '--debug')
            $script:Events.IndexOf('complete') | Should -BeGreaterThan $script:Events.IndexOf('session')
            $script:Events.IndexOf('complete') | Should -BeGreaterThan $script:Events.IndexOf('script')
            $script:Events.IndexOf('complete') | Should -BeLessThan $script:Events.IndexOf('error')
            $env:SWEEPR_DRY_RUN | Should -BeExactly 'user dry'
            [System.Environment]::GetEnvironmentVariable('_SWEEPR_OPLOG_RUN_ID') | Should -BeNullOrEmpty
        }

        It 'Catches an exception of a module and gives exit 1 with its message' {
            Mock Initialize-SwDataFolders { throw 'cannot create the folders' }
            $result = Invoke-Main @('clean')
            $result.Thrown | Should -BeNullOrEmpty
            $result.Code | Should -Be 1
            $script:Errors[0] | Should -Match 'cannot create the folders'
        }

        It 'Shows the message of the data folder check as it is, without a prefix, and gives exit 1' {
            $message = 'Sweepr data folder is not writable: X:\config. Sweepr does not fall back to your user profile.'
            $script:ThrownMessage = $message
            Mock Initialize-SwDataFolders { throw $script:ThrownMessage }
            $result = Invoke-Main @('clean')
            $result.Code | Should -Be 1
            $script:Errors[0] | Should -BeExactly $message
        }

        It 'Gives exit 1 and a message when the version cannot be read for --version' {
            Mock Show-SwVersion { throw 'the runtime information is not available' }
            $result = Invoke-Main @('--version')
            $result.Thrown | Should -BeNullOrEmpty
            $result.Code | Should -Be 1
            $script:Errors[0] | Should -Match 'runtime information'
        }
    }

    Context 'control characters in what is shown (S9)' {
        BeforeEach {
            Mock Write-SwError { $script:Errors.Add([string]$Message); & $script:RealError @PesterBoundParameters }
        }

        It 'Does not hand the control characters of an exception message to the host as they are' {
            $esc = [string][char]27
            $env:SW_TEST_THROW = '1'
            $env:SW_TEST_SUFFIX = 'xx[31mred'
            $plain = Invoke-Main @('clean')
            $env:SW_TEST_SUFFIX = $esc + '[31mred' + [char]7 + 'end'
            $result = Invoke-Main @('clean')
            $result.Code | Should -Be 1
            ($plain.Lines -join "`n") | Should -Match 'boom'
            $count = { param($lines) ($lines -join "`n").Split([char]27).Count }
            (& $count $result.Lines) | Should -Be (& $count $plain.Lines)
            ($result.Lines -join "`n").Contains([string][char]7) | Should -BeFalse
        }

        It 'Does not hand the control characters of a rejected word to the host as they are' {
            $esc = [string][char]27
            $plain = Invoke-Main @('evilxx[31mred')
            $result = Invoke-Main @("evil$esc[31mred" + [char]7 + 'end')
            $result.Code | Should -Be 2
            $count = { param($lines) ($lines -join "`n").Split([char]27).Count }
            (& $count $result.Lines) | Should -Be (& $count $plain.Lines)
            ($result.Lines -join "`n").Contains([string][char]7) | Should -BeFalse
        }
    }

    Context 'clean output of runs that machines read (RT-22)' {
        It 'Writes nothing of its own around the command: <Words>' -ForEach @(
            @{ Words = @('status', '--json') }
            @{ Words = @('analyze', '--json') }
            @{ Words = @('uninstall', '--list') }
            @{ Words = @('clean', '--dry-run') }
            @{ Words = @('clean') }
        ) {
            $env:SW_TEST_JSON = '{"example":1}'
            $result = Invoke-Main $Words
            $result.Code | Should -Be 0
            @($result.Output) | Should -Be @('{"example":1}')
            $result.Lines.Count | Should -Be 0
        }

        It 'Uses no network and starts no process of its own' {
            $null = Invoke-Main @('clean', '--dry-run')
            $null = Invoke-Main @('--help')
            $null = Invoke-Main @('nonsense')
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
            Should -Invoke Start-Process -Times 0 -Exactly
        }

        It 'Does not clear the screen for a command given on the command line' -ForEach @(
            @{ Words = @('clean') }
            @{ Words = @('uninstall', '--list') }
            @{ Words = @('status', '--json') }
            @{ Words = @('--help') }
            @{ Words = @('--version') }
            @{ Words = @('nonsense') }
        ) {
            $null = Invoke-Main $Words
            Should -Invoke Clear-Host -Times 0 -Exactly
        }
    }
}
