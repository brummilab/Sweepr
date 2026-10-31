# Sweepr - tests for how sweepr.ps1 maps the words of a command to the parameters of its script:
# Resolve-SwCommandParameter and Resolve-SwCommandArguments (RT-5 to RT-10), and the contract the real
# command scripts in bin\ have to keep for it (RT-24).
#
# The rule numbers in the test names (RT- and S) number the rules and the safety invariants of the
# router's behavior; each testable rule and invariant has at least one test. The other router files are
# SwRouterLoad (RT-1 to RT-3), SwRouterCommand (RT-11 to RT-15), SwRouterMain (RT-4, RT-16, RT-17,
# RT-21), SwRouterScreens (RT-18 to RT-20, RT-23) and SwRouterProcess (the two call forms).
#
# Interface pinned here (sweepr.ps1 is loaded by dot-sourcing and defines these at the top level):
#   Resolve-SwCommandParameter -Parameters <IDictionary> -Flag <string>   parameter name or $null
#   Resolve-SwCommandArguments -CommandName <string> -Arguments <string[]>
#       object with Valid, Splat (hashtable), Words (string[]), Message, Hint
#   $script:SWEEPR_BIN is read at every call; the tests point it at stand-in scripts in $TestDrive.
#
# Platform notes:
#   - The stand-in scripts only declare the parameter blocks of the real commands; nothing runs. The
#     second part reads the real scripts in bin\ (parameters only, nothing runs).
#   - Nothing real is touched: no files outside $TestDrive, no environment change that stays.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    $script:AllCommands = @('clean', 'uninstall', 'analyze', 'status', 'optimize', 'purge', 'history', 'features', 'check', 'update', 'remove')
    $script:DebugCommands = @('clean', 'uninstall', 'optimize', 'analyze', 'purge', 'features', 'check', 'update')
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:RouterFile = Join-Path $script:RepoRoot 'sweepr.ps1'
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
    $script:EnDash = [string][char]0x2013

    # What loading the router and the tests change in the process is put back after the last test.
    $script:SavedEnv = @{}
    foreach ($name in 'SWEEPR_DATA_DIR', 'SWEEPR_DRY_RUN', 'SWEEPR_DEBUG', '_SWEEPR_OPLOG_RUN_COMMAND', '_SWEEPR_OPLOG_RUN_ID', 'USERPROFILE', 'HOME', 'SWEEPR_NO_OPLOG') {
        $script:SavedEnv[$name] = [System.Environment]::GetEnvironmentVariable($name)
    }
    $script:SavedExitCode = $global:LASTEXITCODE
    $script:SavedLocation = (Get-Location).Path

    $script:HomeDir = Join-Path $TestDrive 'router-home'
    [void][System.IO.Directory]::CreateDirectory($script:HomeDir)
    $env:USERPROFILE = $script:HomeDir
    $env:HOME = $script:HomeDir
    $env:SWEEPR_DATA_DIR = Join-Path $script:HomeDir 'data'
    $env:SWEEPR_NO_OPLOG = '1'

    . $script:RouterFile

    # The parameter blocks of the real command scripts (the scripts are the source of the options).
    $script:Blocks = [ordered]@{}
    $script:Blocks['clean'] = @'
[CmdletBinding()]
param(
    [Alias('dry-run')][switch]$DryRun,
    [Alias('s')][switch]$System,
    [Alias('game-media')][switch]$GameMedia,
    [Alias('gpu-shaders')][switch]$GpuShaders,
    [Alias('d')][switch]$DebugMode,
    [Alias('w')][switch]$Whitelist,
    [Alias('h')][switch]$ShowHelp
)
'@
    $script:Blocks['uninstall'] = @'
[CmdletBinding()]
param(
    [Alias('dry-run')][switch]$DryRun,
    [Alias('d')][switch]$DebugMode,
    [Alias('r')][switch]$Rescan,
    [switch]$List,
    [Alias('h')][switch]$ShowHelp
)
'@
    $script:Blocks['optimize'] = @'
[CmdletBinding()]
param(
    [Alias('dry-run')][switch]$DryRun,
    [Alias('d')][switch]$DebugMode,
    [Alias('h')][switch]$ShowHelp
)
'@
    $script:Blocks['purge'] = @'
[CmdletBinding()]
param(
    [Alias('dry-run')][switch]$DryRun,
    [Alias('d')][switch]$DebugMode,
    [Alias('p')][switch]$Paths,
    [Alias('h')][switch]$ShowHelp
)
'@
    $script:Blocks['analyze'] = @'
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Path,
    [Alias('h')][switch]$ShowHelp,
    [switch]$Json,
    [Alias('d')][switch]$DebugMode
)
'@
    $script:Blocks['status'] = @'
[CmdletBinding(PositionalBinding = $false)]
param(
    [Alias('h')][switch]$ShowHelp,
    [switch]$Json,
    [switch]$Watch,
    [string]$Interval
)
'@
    $script:Blocks['history'] = @'
[CmdletBinding(PositionalBinding = $false)]
param(
    [Alias('h')][switch]$ShowHelp,
    [switch]$Json,
    $Limit,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingArguments
)
'@
    $script:Blocks['features'] = @'
[CmdletBinding()]
param(
    [Alias('dry-run')][switch]$DryRun,
    [Alias('d')][switch]$DebugMode,
    [switch]$List,
    [Alias('all-users-future')][switch]$AllUsersFuture,
    [switch]$Restore,
    [Alias('h')][switch]$ShowHelp
)
'@
    $script:Blocks['check'] = @'
[CmdletBinding()]
param(
    [switch]$Json,
    [switch]$Report,
    [Alias('no-open')][switch]$NoOpen,
    [Alias('dry-run')][switch]$DryRun,
    [Alias('d')][switch]$DebugMode,
    [Alias('h')][switch]$ShowHelp
)
'@
    $script:Blocks['update'] = @'
[CmdletBinding()]
param(
    [Alias('d')][switch]$DebugMode,
    [Alias('h')][switch]$ShowHelp
)
'@
    $script:Blocks['remove'] = @'
[CmdletBinding()]
param(
    [Alias('h')][switch]$ShowHelp
)
'@
    # Stand-ins with a declaration of their own, for the rules about the declaration itself.
    $script:Blocks['fake'] = @'
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Path,
    [string]$X,
    [switch]$Flag,
    $Any,
    [Alias('h')][switch]$ShowHelp,
    [Alias('d')][switch]$DebugMode
)
'@
    $script:Blocks['nocb'] = "param([switch]`$ShowHelp)"
    $script:Blocks['noparam'] = "'no parameters'"
    $script:Blocks['two'] = @'
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$A,
    [Parameter(Position = 1)][string]$B,
    [switch]$Flag
)
'@
    $script:Blocks['nohelp'] = @'
[CmdletBinding()]
param([switch]$Flag)
'@
    $script:Blocks['rest'] = @'
[CmdletBinding()]
param(
    [switch]$Flag,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)
'@

    # A folder with one script per block; the router reads the parameters, nothing runs.
    $script:BinDir = Join-Path $TestDrive 'stand-in-bin'
    [void][System.IO.Directory]::CreateDirectory($script:BinDir)
    foreach ($name in $script:Blocks.Keys) {
        [System.IO.File]::WriteAllText((Join-Path $script:BinDir "$name.ps1"), $script:Blocks[$name] + "`n'ran'`n", $script:Utf8)
    }

    # An unset variable is removed: .NET 8 treats an empty value as unset, newer .NET keeps it as an empty value.
    function script:Set-EnvValue {
        param([string]$Name, $Value)
        if ($null -eq $Value) { [System.Environment]::SetEnvironmentVariable($Name, [NullString]::Value) }
        else { [System.Environment]::SetEnvironmentVariable($Name, [string]$Value) }
    }

    function script:Get-ParameterTable([string]$Name) {
        return (Get-Command -Name (Join-Path $script:BinDir "$Name.ps1") -CommandType ExternalScript).Parameters
    }
    function script:Get-SplatText($Result) {
        return (@($Result.Splat.Keys | Sort-Object | ForEach-Object { "$_=$($Result.Splat[$_])" }) -join ';')
    }
    function script:Resolve-Words([string]$Command, [string[]]$Words) {
        $script:SWEEPR_BIN = $script:BinDir
        return (Resolve-SwCommandArguments -CommandName $Command -Arguments $Words)
    }
}

AfterAll {
    foreach ($name in $script:SavedEnv.Keys) { Set-EnvValue -Name $name -Value $script:SavedEnv[$name] }
    $global:LASTEXITCODE = $script:SavedExitCode
    Set-Location -LiteralPath $script:SavedLocation
}

Describe 'Router functions for the words of a command exist' {
    It 'Defines <Name> with the parameters of the interface' -ForEach @(
        @{ Name = 'Resolve-SwCommandParameter'; Parameters = @('Parameters', 'Flag') }
        @{ Name = 'Resolve-SwCommandArguments'; Parameters = @('CommandName', 'Arguments') }
    ) {
        $command = Get-Command -Name $Name -CommandType Function -ErrorAction Stop
        foreach ($parameter in $Parameters) { $command.Parameters.ContainsKey($parameter) | Should -BeTrue -Because "-$parameter" }
    }
}

Describe 'Resolve-SwCommandParameter (RT-7)' {
    It 'Maps the flag <Flag> of <Command> to <Expected>' -ForEach @(
        @{ Command = 'uninstall'; Flag = 'list'; Expected = 'List' }
        @{ Command = 'uninstall'; Flag = 'r'; Expected = 'Rescan' }
        @{ Command = 'analyze'; Flag = 'json'; Expected = 'Json' }
        @{ Command = 'analyze'; Flag = 'path'; Expected = 'Path' }
        @{ Command = 'features'; Flag = 'restore'; Expected = 'Restore' }
        @{ Command = 'features'; Flag = 'all-users-future'; Expected = 'AllUsersFuture' }
        @{ Command = 'check'; Flag = 'no-open'; Expected = 'NoOpen' }
        @{ Command = 'check'; Flag = 'NoOpen'; Expected = 'NoOpen' }
        @{ Command = 'check'; Flag = 'report'; Expected = 'Report' }
        @{ Command = 'clean'; Flag = 'dry-run'; Expected = 'DryRun' }
        @{ Command = 'clean'; Flag = 'DryRun'; Expected = 'DryRun' }
        @{ Command = 'clean'; Flag = 'DRYRUN'; Expected = 'DryRun' }
        @{ Command = 'clean'; Flag = 'system'; Expected = 'System' }
        @{ Command = 'clean'; Flag = 's'; Expected = 'System' }
        @{ Command = 'clean'; Flag = 'S'; Expected = 'System' }
        @{ Command = 'clean'; Flag = 'w'; Expected = 'Whitelist' }
        @{ Command = 'clean'; Flag = 'game-media'; Expected = 'GameMedia' }
        @{ Command = 'clean'; Flag = 'gpu-shaders'; Expected = 'GpuShaders' }
        @{ Command = 'purge'; Flag = 'p'; Expected = 'Paths' }
        @{ Command = 'purge'; Flag = 'paths'; Expected = 'Paths' }
        @{ Command = 'history'; Flag = 'limit'; Expected = 'Limit' }
        @{ Command = 'status'; Flag = 'interval'; Expected = 'Interval' }
        @{ Command = 'status'; Flag = 'watch'; Expected = 'Watch' }
    ) {
        Resolve-SwCommandParameter -Parameters (Get-ParameterTable $Command) -Flag $Flag | Should -BeExactly $Expected
    }

    It 'Maps help, h and showhelp of <Command> to ShowHelp' -ForEach @(
        $script:AllCommands | ForEach-Object { @{ Command = $_ } }
    ) {
        foreach ($flag in 'help', 'h', 'showhelp', 'ShowHelp', 'HELP') {
            Resolve-SwCommandParameter -Parameters (Get-ParameterTable $Command) -Flag $flag | Should -BeExactly 'ShowHelp' -Because $flag
        }
    }

    It 'Maps debug and d of <Command> to DebugMode' -ForEach @(
        $script:DebugCommands | ForEach-Object { @{ Command = $_ } }
    ) {
        foreach ($flag in 'debug', 'd', 'D', 'DebugMode', 'Debug') {
            Resolve-SwCommandParameter -Parameters (Get-ParameterTable $Command) -Flag $flag | Should -BeExactly 'DebugMode' -Because $flag
        }
    }

    It 'Does not map debug of <Command>, which has no DebugMode, to the common parameter' -ForEach @(
        @{ Command = 'history' }
        @{ Command = 'status' }
        @{ Command = 'remove' }
    ) {
        foreach ($flag in 'debug', 'd', 'Debug') {
            $null -eq (Resolve-SwCommandParameter -Parameters (Get-ParameterTable $Command) -Flag $flag) | Should -BeTrue -Because $flag
        }
    }

    It 'Never matches the common parameter <Flag>, although every script has [CmdletBinding()]' -ForEach @(
        @{ Flag = 'verbose' }
        @{ Flag = 'Verbose' }
        @{ Flag = 'erroraction' }
        @{ Flag = 'warningaction' }
        @{ Flag = 'informationaction' }
        @{ Flag = 'progressaction' }
        @{ Flag = 'errorvariable' }
        @{ Flag = 'warningvariable' }
        @{ Flag = 'informationvariable' }
        @{ Flag = 'outvariable' }
        @{ Flag = 'outbuffer' }
        @{ Flag = 'pipelinevariable' }
        @{ Flag = 'whatif' }
        @{ Flag = 'confirm' }
    ) {
        $null -eq (Resolve-SwCommandParameter -Parameters (Get-ParameterTable 'clean') -Flag $Flag) | Should -BeTrue
        $null -eq (Resolve-SwCommandParameter -Parameters (Get-ParameterTable 'history') -Flag $Flag) | Should -BeTrue
    }

    It 'Does not match a part of a name or a pattern: <Flag>' -ForEach @(
        @{ Flag = 'sys' }
        @{ Flag = 'dry' }
        @{ Flag = 'dry*' }
        @{ Flag = '*' }
        @{ Flag = '?' }
        @{ Flag = '[a-z]' }
        @{ Flag = 'system ' }
        @{ Flag = 'Syste' }
        @{ Flag = '' }
        @{ Flag = ' ' }
    ) {
        $null -eq (Resolve-SwCommandParameter -Parameters (Get-ParameterTable 'clean') -Flag $Flag) | Should -BeTrue
    }

    It 'Returns $null for an unknown flag and never throws' -ForEach @(
        @{ Flag = 'bogus' }
        @{ Flag = '5' }
        @{ Flag = 'a b' }
        @{ Flag = "x`ny" }
    ) {
        $result = $null
        $thrown = $null
        try { $result = Resolve-SwCommandParameter -Parameters (Get-ParameterTable 'clean') -Flag $Flag } catch { $thrown = $_ }
        $thrown | Should -BeNullOrEmpty
        $null -eq $result | Should -BeTrue
    }

    It 'Returns $null for an empty table of parameters' {
        $null -eq (Resolve-SwCommandParameter -Parameters @{} -Flag 'help') | Should -BeTrue
    }

    It 'Maps help and debug to the synonyms only when the script declares ShowHelp and DebugMode' {
        $table = Get-ParameterTable 'nohelp'
        $null -eq (Resolve-SwCommandParameter -Parameters $table -Flag 'help') | Should -BeTrue
        $null -eq (Resolve-SwCommandParameter -Parameters $table -Flag 'h') | Should -BeTrue
        $null -eq (Resolve-SwCommandParameter -Parameters $table -Flag 'debug') | Should -BeTrue
        Resolve-SwCommandParameter -Parameters $table -Flag 'flag' | Should -BeExactly 'Flag'
    }

    It 'Returns the name as a string' {
        Resolve-SwCommandParameter -Parameters (Get-ParameterTable 'clean') -Flag 's' | Should -BeOfType [string]
    }
}

Describe 'Resolve-SwCommandArguments: valid words (RT-6, RT-7, RT-8, RT-9)' {
    It 'Maps <Words> for <Command> to <Splat> with the words <Positional>' -ForEach @(
        # RT-1: the short options that PowerShell would take for itself under -File
        @{ Command = 'clean'; Words = @('-s'); Splat = 'System=True'; Positional = '' }
        @{ Command = 'clean'; Words = @('-w'); Splat = 'Whitelist=True'; Positional = '' }
        @{ Command = 'purge'; Words = @('-p'); Splat = 'Paths=True'; Positional = '' }
        @{ Command = 'clean'; Words = @('--dry-run'); Splat = 'DryRun=True'; Positional = '' }
        @{ Command = 'clean'; Words = @('-DryRun'); Splat = 'DryRun=True'; Positional = '' }
        @{ Command = 'clean'; Words = @('--DRY-RUN'); Splat = 'DryRun=True'; Positional = '' }
        @{ Command = 'clean'; Words = @('--dryrun'); Splat = 'DryRun=True'; Positional = '' }
        @{ Command = 'clean'; Words = @('--system', '--game-media', '--gpu-shaders'); Splat = 'GameMedia=True;GpuShaders=True;System=True'; Positional = '' }
        @{ Command = 'clean'; Words = @('--debug'); Splat = 'DebugMode=True'; Positional = '' }
        @{ Command = 'clean'; Words = @('-d'); Splat = 'DebugMode=True'; Positional = '' }
        @{ Command = 'clean'; Words = @('-Debug'); Splat = 'DebugMode=True'; Positional = '' }
        @{ Command = 'clean'; Words = @('-DebugMode'); Splat = 'DebugMode=True'; Positional = '' }
        @{ Command = 'clean'; Words = @('--help'); Splat = 'ShowHelp=True'; Positional = '' }
        @{ Command = 'clean'; Words = @('-h'); Splat = 'ShowHelp=True'; Positional = '' }
        @{ Command = 'clean'; Words = @('-help'); Splat = 'ShowHelp=True'; Positional = '' }
        @{ Command = 'clean'; Words = @('--showhelp'); Splat = 'ShowHelp=True'; Positional = '' }
        @{ Command = 'clean'; Words = @('--dry-run', '--dry-run'); Splat = 'DryRun=True'; Positional = '' }
        @{ Command = 'clean'; Words = @(); Splat = ''; Positional = '' }
        @{ Command = 'uninstall'; Words = @('--list'); Splat = 'List=True'; Positional = '' }
        @{ Command = 'uninstall'; Words = @('-r'); Splat = 'Rescan=True'; Positional = '' }
        @{ Command = 'features'; Words = @('--restore'); Splat = 'Restore=True'; Positional = '' }
        @{ Command = 'features'; Words = @('--all-users-future', '--dry-run'); Splat = 'AllUsersFuture=True;DryRun=True'; Positional = '' }
        @{ Command = 'check'; Words = @('--no-open', '--report'); Splat = 'NoOpen=True;Report=True'; Positional = '' }
        @{ Command = 'update'; Words = @('--debug'); Splat = 'DebugMode=True'; Positional = '' }
        @{ Command = 'remove'; Words = @('--help'); Splat = 'ShowHelp=True'; Positional = '' }
        # RT-8 values of status
        @{ Command = 'status'; Words = @('--watch', '--interval', '1s'); Splat = 'Interval=1s;Watch=True'; Positional = '' }
        @{ Command = 'status'; Words = @('--watch', '--interval=1s'); Splat = 'Interval=1s;Watch=True'; Positional = '' }
        @{ Command = 'status'; Words = @('--interval:1s'); Splat = 'Interval=1s'; Positional = '' }
        @{ Command = 'status'; Words = @('-Interval', '3s'); Splat = 'Interval=3s'; Positional = '' }
        @{ Command = 'status'; Words = @('--INTERVAL=4s'); Splat = 'Interval=4s'; Positional = '' }
        @{ Command = 'status'; Words = @('--interval', '2s', '--json'); Splat = 'Interval=2s;Json=True'; Positional = '' }
        @{ Command = 'status'; Words = @('--watch', '--json'); Splat = 'Json=True;Watch=True'; Positional = '' }
        @{ Command = 'status'; Words = @('--interval', '1s', '--interval', '2s'); Splat = 'Interval=2s'; Positional = '' }
        @{ Command = 'status'; Words = @('--interval', '-1'); Splat = 'Interval=-1'; Positional = '' }
        @{ Command = 'status'; Words = @('--interval', '-'); Splat = 'Interval=-'; Positional = '' }
        @{ Command = 'status'; Words = @('--interval', '--'); Splat = 'Interval=--'; Positional = '' }
        @{ Command = 'status'; Words = @('--interval', 'D:\x'); Splat = 'Interval=D:\x'; Positional = '' }
        @{ Command = 'status'; Words = @('--interval=a=b'); Splat = 'Interval=a=b'; Positional = '' }
        @{ Command = 'status'; Words = @('--interval=a:b'); Splat = 'Interval=a:b'; Positional = '' }
        # RT-8 values of history
        @{ Command = 'history'; Words = @('--limit', '5'); Splat = 'Limit=5'; Positional = '' }
        @{ Command = 'history'; Words = @('--limit=5'); Splat = 'Limit=5'; Positional = '' }
        @{ Command = 'history'; Words = @('--limit:5'); Splat = 'Limit=5'; Positional = '' }
        @{ Command = 'history'; Words = @('--limit', '-1'); Splat = 'Limit=-1'; Positional = '' }
        @{ Command = 'history'; Words = @('--limit=5', '--limit=7'); Splat = 'Limit=7'; Positional = '' }
        @{ Command = 'history'; Words = @('--limit', '5', 'foo'); Splat = 'Limit=5'; Positional = 'foo' }
        @{ Command = 'history'; Words = @('--json'); Splat = 'Json=True'; Positional = '' }
        # RT-9 positional words
        @{ Command = 'analyze'; Words = @('D:\'); Splat = ''; Positional = 'D:\' }
        @{ Command = 'analyze'; Words = @('--json', 'D:\scan target'); Splat = 'Json=True'; Positional = 'D:\scan target' }
        @{ Command = 'analyze'; Words = @('D:\scan target', '--json'); Splat = 'Json=True'; Positional = 'D:\scan target' }
        @{ Command = 'analyze'; Words = @('--path', 'D:\x'); Splat = 'Path=D:\x'; Positional = '' }
        @{ Command = 'analyze'; Words = @('--path=D:\x'); Splat = 'Path=D:\x'; Positional = '' }
        @{ Command = 'history'; Words = @('foo', 'bar'); Splat = ''; Positional = 'foo|bar' }
        @{ Command = 'history'; Words = @('a', 'b', 'c', 'd', 'e'); Splat = ''; Positional = 'a|b|c|d|e' }
        @{ Command = 'rest'; Words = @('x', '--flag', 'y'); Splat = 'Flag=True'; Positional = 'x|y' }
        @{ Command = 'two'; Words = @('a', 'b'); Splat = ''; Positional = 'a|b' }
        # RT-6 forms that are words
        @{ Command = 'fake'; Words = @('--x='); Splat = ''; Positional = '--x=' }
        @{ Command = 'fake'; Words = @('-'); Splat = ''; Positional = '-' }
        @{ Command = 'fake'; Words = @('--x=a=b'); Splat = 'X=a=b'; Positional = '' }
        @{ Command = 'fake'; Words = @('--x:a:b'); Splat = 'X=a:b'; Positional = '' }
        @{ Command = 'fake'; Words = @('--any'); Splat = 'Any=True'; Positional = '' }
        @{ Command = 'fake'; Words = @('--any', 'value'); Splat = 'Any=value'; Positional = '' }
    ) {
        $result = Resolve-Words $Command $Words
        $result.Valid | Should -BeTrue
        $result.Message | Should -BeNullOrEmpty
        Get-SplatText $result | Should -BeExactly $Splat
        (@($result.Words) -join '|') | Should -BeExactly $Positional
    }

    It 'Keeps a quote and an apostrophe in an option value and in a word' {
        $result = Resolve-Words 'fake' @("--path=C:\fixture\reports'")
        $result.Splat['Path'] | Should -BeExactly "C:\fixture\reports'"
        $result = Resolve-Words 'fake' @("C:\fixture\reports'")
        @($result.Words) | Should -Be @("C:\fixture\reports'")
        $result = Resolve-Words 'fake' @('"quoted"')
        @($result.Words) | Should -Be @('"quoted"')
        $result = Resolve-Words 'fake' @("--x=it's")
        $result.Splat['X'] | Should -BeExactly "it's"
    }

    It 'Keeps a path with a colon, a blank or a bracket as one word' -ForEach @(
        @{ Word = 'D:\scan target' }
        @{ Word = 'C:\Users\Example\[x]' }
        @{ Word = '/tmp/a:b' }
        @{ Word = '\\server\share\folder' }
    ) {
        $result = Resolve-Words 'analyze' @($Word)
        $result.Valid | Should -BeTrue
        @($result.Words) | Should -Be @($Word)
    }

    It 'Takes a word with a dash from another script as a positional word: <Case>' -ForEach @(
        @{ Case = 'en dash before a name'; Word = ([string][char]0x2013 + 'json') }
        @{ Case = 'em dash before a name'; Word = ([string][char]0x2014 + 'json') }
        @{ Case = 'minus sign before a name'; Word = ([string][char]0x2212 + 'json') }
    ) {
        $result = Resolve-Words 'analyze' @($Word)
        $result.Valid | Should -BeTrue
        @($result.Words) | Should -Be @($Word)
        $result.Splat.Count | Should -Be 0
    }

    It 'Gives a Splat that is a hashtable, Words that are strings, and $true for a switch' {
        $result = Resolve-Words 'analyze' @('--json', 'D:\x')
        $result.Splat | Should -BeOfType [hashtable]
        $result.Splat['Json'] | Should -BeOfType [bool]
        $result.Splat['Json'] | Should -BeTrue
        $result.Words.GetType().Name | Should -Be 'String[]'
        $result.Valid | Should -BeOfType [bool]
    }

    It 'Gives $true for an untyped value parameter without a value and for one followed by an option' {
        $result = Resolve-Words 'history' @('--limit')
        $result.Valid | Should -BeTrue
        $result.Splat['Limit'] | Should -BeOfType [bool]
        $result.Splat['Limit'] | Should -BeTrue
        $result = Resolve-Words 'history' @('--limit', '--json')
        $result.Valid | Should -BeTrue
        $result.Splat['Limit'] | Should -BeOfType [bool]
        $result.Splat['Limit'] | Should -BeTrue
        $result.Splat['Json'] | Should -BeTrue
    }

    It 'Gives the value of a typed value parameter as a string' {
        (Resolve-Words 'status' @('--interval', '5')).Splat['Interval'] | Should -BeOfType [string]
        (Resolve-Words 'history' @('--limit', '5')).Splat['Limit'] | Should -BeOfType [string]
    }

    It 'Keeps the order of the words' {
        @((Resolve-Words 'history' @('c', '--json', 'a', 'b')).Words) | Should -Be @('c', 'a', 'b')
    }

    It 'Accepts a word for a script with a declaration that has no [CmdletBinding()] only within its capacity' {
        (Resolve-Words 'nocb' @('--help')).Valid | Should -BeTrue
    }
}

Describe 'Resolve-SwCommandArguments: rejections (RT-7, RT-8, RT-9, RT-10)' {
    It 'Rejects the unknown option <Word> of <Command>' -ForEach @(
        @{ Command = 'clean'; Word = '--bogus' }
        @{ Command = 'clean'; Word = '--verbose' }
        @{ Command = 'clean'; Word = '-Verbose' }
        @{ Command = 'clean'; Word = '-v' }
        @{ Command = 'clean'; Word = '--ErrorAction' }
        @{ Command = 'clean'; Word = '-WhatIf' }
        @{ Command = 'clean'; Word = '-Confirm' }
        @{ Command = 'clean'; Word = '-5' }
        @{ Command = 'clean'; Word = '--sys' }
        @{ Command = 'clean'; Word = '--dry-run-now' }
        @{ Command = 'history'; Word = '--debug' }
        @{ Command = 'history'; Word = '-d' }
        @{ Command = 'status'; Word = '--debug' }
        @{ Command = 'remove'; Word = '--debug' }
        @{ Command = 'update'; Word = '--verbose' }
    ) {
        $result = Resolve-Words $Command @($Word)
        $result.Valid | Should -BeFalse
        $result.Message | Should -BeLike "Unknown option for sw ${Command}: *"
        $result.Message | Should -BeLike "*$Word"
        $result.Hint | Should -BeLike "*sw $Command --help*"
    }

    It 'Rejects the first unknown option among valid ones' {
        $result = Resolve-Words 'clean' @('--dry-run', '--bogus', '--system')
        $result.Valid | Should -BeFalse
        $result.Message | Should -BeLike 'Unknown option for sw clean: *--bogus'
    }

    It 'Rejects a value for the switch <Word> of <Command>' -ForEach @(
        @{ Command = 'clean'; Word = '--dry-run=false' }
        @{ Command = 'clean'; Word = '--dry-run:true' }
        @{ Command = 'clean'; Word = '-s=1' }
        @{ Command = 'status'; Word = '--json=true' }
        @{ Command = 'analyze'; Word = '--json:1' }
        @{ Command = 'features'; Word = '--restore=yes' }
    ) {
        $result = Resolve-Words $Command @($Word)
        $result.Valid | Should -BeFalse
        $result.Message | Should -BeLike "Option takes no value for sw ${Command}: *"
        $result.Message | Should -BeLike "*$Word"
        $result.Hint | Should -BeLike "*sw $Command --help*"
    }

    It 'Rejects the string option <Word> without a value: <Words>' -ForEach @(
        @{ Word = '--interval'; Words = @('--interval') }
        @{ Word = '--interval'; Words = @('--interval', '--json') }
        @{ Word = '--interval'; Words = @('--interval', '-x') }
        @{ Word = '--interval'; Words = @('--interval', '--watch', '--json') }
        @{ Word = '-Interval'; Words = @('-Interval') }
    ) {
        $result = Resolve-Words 'status' $Words
        $result.Valid | Should -BeFalse
        $result.Message | Should -BeLike 'Option needs a value for sw status: *'
        $result.Message | Should -BeLike "*$Word"
        $result.Hint | Should -BeLike '*sw status --help*'
    }

    It 'Rejects the word <Word> for <Command>: more words than the script takes' -ForEach @(
        @{ Command = 'update'; Word = 'help' }
        @{ Command = 'update'; Word = '/?' }
        @{ Command = 'update'; Word = 'check' }
        @{ Command = 'update'; Word = 'status' }
        @{ Command = 'clean'; Word = 'x' }
        @{ Command = 'status'; Word = 'foo' }
        @{ Command = 'remove'; Word = 'x' }
        @{ Command = 'check'; Word = 'x' }
        @{ Command = 'nocb'; Word = 'x' }
        @{ Command = 'noparam'; Word = 'x' }
        @{ Command = 'status'; Word = ([string][char]0x2013 + 'json') }
    ) {
        $result = Resolve-Words $Command @($Word)
        $result.Valid | Should -BeFalse
        $result.Message | Should -BeLike "Unexpected argument for sw ${Command}: *"
        $result.Message | Should -BeLike "*$Word"
        $result.Hint | Should -BeLike "*sw $Command --help*"
    }

    It 'Names the first word beyond the capacity: <Command> <Words>' -ForEach @(
        @{ Command = 'analyze'; Words = @('a', 'b'); First = 'b' }
        @{ Command = 'analyze'; Words = @('a', 'b', 'c'); First = 'b' }
        @{ Command = 'two'; Words = @('a', 'b', 'c'); First = 'c' }
        @{ Command = 'analyze'; Words = @('--json', 'a', '--json', 'b'); First = 'b' }
    ) {
        $result = Resolve-Words $Command $Words
        $result.Valid | Should -BeFalse
        $result.Message | Should -BeLike "Unexpected argument for sw ${Command}: *"
        $result.Message | Should -BeLike "*$First"
    }

    It 'Does not count the value of an option as a word' {
        (Resolve-Words 'status' @('--interval', '1s')).Valid | Should -BeTrue
        (Resolve-Words 'analyze' @('--path', 'D:\x')).Valid | Should -BeTrue
        (Resolve-Words 'fake' @('--x', 'value', 'D:\x')).Valid | Should -BeTrue
    }

    It 'Uses a Message and a Hint of $null only for a valid result' {
        $valid = Resolve-Words 'clean' @('--dry-run')
        $null -eq $valid.Message | Should -BeTrue
        $null -eq $valid.Hint | Should -BeTrue
        $invalid = Resolve-Words 'clean' @('--bogus')
        $invalid.Message | Should -Not -BeNullOrEmpty
        $invalid.Hint | Should -Not -BeNullOrEmpty
    }
}

Describe 'Resolve-SwCommandArguments: no side effects and no output (RT-10, S2)' {
    It 'Writes nothing to any stream, creates nothing and changes no variable' -ForEach @(
        @{ Command = 'clean'; Words = @('--dry-run', '-s') }
        @{ Command = 'clean'; Words = @('--bogus') }
        @{ Command = 'status'; Words = @('--interval') }
        @{ Command = 'update'; Words = @('help') }
    ) {
        $script:SWEEPR_BIN = $script:BinDir
        $script:SweeprExitCode = 55
        $envBefore = (Get-ChildItem Env: | Sort-Object Name | ForEach-Object { $_.Name + '=' + $_.Value }) -join '|'
        $filesBefore = @(Get-ChildItem -LiteralPath $TestDrive -Recurse -Force | ForEach-Object { $_.FullName } | Sort-Object)
        $records = @(Resolve-SwCommandArguments -CommandName $Command -Arguments $Words *>&1)
        # The result itself is the one object; nothing else is written.
        @($records | Where-Object { $_ -is [System.Management.Automation.InformationRecord] -or $_ -is [System.Management.Automation.ErrorRecord] -or $_ -is [System.Management.Automation.WarningRecord] }).Count | Should -Be 0
        @($records).Count | Should -Be 1
        $script:SweeprExitCode | Should -Be 55
        (Get-ChildItem Env: | Sort-Object Name | ForEach-Object { $_.Name + '=' + $_.Value }) -join '|' | Should -BeExactly $envBefore
        @(Get-ChildItem -LiteralPath $TestDrive -Recurse -Force | ForEach-Object { $_.FullName } | Sort-Object) | Should -Be $filesBefore
        $script:SweeprExitCode = 0
    }

    It 'Starts no script: a stand-in that would leave a mark is not run' {
        $mark = Join-Path $TestDrive 'ran.txt'
        $dir = Join-Path $TestDrive 'mark-bin'
        [void][System.IO.Directory]::CreateDirectory($dir)
        [System.IO.File]::WriteAllText((Join-Path $dir 'marker.ps1'), "[CmdletBinding()]`nparam([switch]`$Flag)`n[System.IO.File]::WriteAllText('$($mark.Replace("'", "''"))', 'ran')`n", $script:Utf8)
        $script:SWEEPR_BIN = $dir
        $null = Resolve-SwCommandArguments -CommandName 'marker' -Arguments @('--flag')
        [System.IO.File]::Exists($mark) | Should -BeFalse
    }

    It 'Reads $script:SWEEPR_BIN at every call' {
        $first = Join-Path $TestDrive 'bin-first'
        $second = Join-Path $TestDrive 'bin-second'
        [void][System.IO.Directory]::CreateDirectory($first)
        [void][System.IO.Directory]::CreateDirectory($second)
        [System.IO.File]::WriteAllText((Join-Path $first 'probe.ps1'), "[CmdletBinding()]`nparam([switch]`$Alpha)`n", $script:Utf8)
        [System.IO.File]::WriteAllText((Join-Path $second 'probe.ps1'), "[CmdletBinding()]`nparam([switch]`$Beta)`n", $script:Utf8)
        $script:SWEEPR_BIN = $first
        (Resolve-SwCommandArguments -CommandName 'probe' -Arguments @('--alpha')).Valid | Should -BeTrue
        (Resolve-SwCommandArguments -CommandName 'probe' -Arguments @('--beta')).Valid | Should -BeFalse
        $script:SWEEPR_BIN = $second
        (Resolve-SwCommandArguments -CommandName 'probe' -Arguments @('--alpha')).Valid | Should -BeFalse
        (Resolve-SwCommandArguments -CommandName 'probe' -Arguments @('--beta')).Valid | Should -BeTrue
    }

    It 'Reads the parameters of a script in a folder with brackets, quotes and blanks literally' {
        $parent = Join-Path $TestDrive 'literal-bin'
        [void][System.IO.Directory]::CreateDirectory((Join-Path $parent 'b1'))
        [System.IO.File]::WriteAllText((Join-Path $parent 'b1\probe.ps1'), "[CmdletBinding()]`nparam([switch]`$Wrong)`n", $script:Utf8)
        $dir = [System.IO.Path]::Combine($parent, "Bob's [b1] & tools")
        [void][System.IO.Directory]::CreateDirectory($dir)
        [System.IO.File]::WriteAllText((Join-Path $dir 'probe.ps1'), "[CmdletBinding()]`nparam([switch]`$Right)`n", $script:Utf8)
        $script:SWEEPR_BIN = $dir
        $result = Resolve-SwCommandArguments -CommandName 'probe' -Arguments @('--right')
        $result.Valid | Should -BeTrue
        $result.Splat.ContainsKey('Right') | Should -BeTrue
    }
}

Describe 'The command scripts of the repository keep the contract of the router (RT-24)' {
    BeforeAll {
        $script:RealBin = Join-Path $script:RepoRoot 'bin'
        function script:Get-RealParameters([string]$Name) {
            return (Get-Command -Name (Join-Path $script:RealBin "$Name.ps1") -CommandType ExternalScript).Parameters
        }
    }

    It 'Declares [CmdletBinding()] in bin\<Command>.ps1' -ForEach @(
        $script:AllCommands | ForEach-Object { @{ Command = $_ } }
    ) {
        (Get-RealParameters $Command).ContainsKey('Verbose') | Should -BeTrue
    }

    It 'Declares ShowHelp with the alias h in bin\<Command>.ps1' -ForEach @(
        $script:AllCommands | ForEach-Object { @{ Command = $_ } }
    ) {
        $parameters = Get-RealParameters $Command
        $parameters.ContainsKey('ShowHelp') | Should -BeTrue
        $parameters['ShowHelp'].Aliases | Should -Contain 'h'
        $parameters['ShowHelp'].ParameterType | Should -Be ([switch])
    }

    It 'Declares no alias debug in bin\<Command>.ps1' -ForEach @(
        $script:AllCommands | ForEach-Object { @{ Command = $_ } }
    ) {
        $common = @('Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ProgressAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable', 'WhatIf', 'Confirm')
        foreach ($parameter in (Get-RealParameters $Command).Values) {
            if ($parameter.Name -in $common) { continue }
            $parameter.Aliases | Should -Not -Contain 'debug' -Because $parameter.Name
        }
    }

    It 'Maps the options of <Command> to the parameters of the real script' -ForEach @(
        @{ Command = 'clean'; Flag = 'dry-run'; Expected = 'DryRun' }
        @{ Command = 'clean'; Flag = 's'; Expected = 'System' }
        @{ Command = 'clean'; Flag = 'w'; Expected = 'Whitelist' }
        @{ Command = 'uninstall'; Flag = 'list'; Expected = 'List' }
        @{ Command = 'uninstall'; Flag = 'r'; Expected = 'Rescan' }
        @{ Command = 'optimize'; Flag = 'dry-run'; Expected = 'DryRun' }
        @{ Command = 'analyze'; Flag = 'json'; Expected = 'Json' }
        @{ Command = 'status'; Flag = 'json'; Expected = 'Json' }
        @{ Command = 'status'; Flag = 'watch'; Expected = 'Watch' }
        @{ Command = 'status'; Flag = 'interval'; Expected = 'Interval' }
        @{ Command = 'purge'; Flag = 'p'; Expected = 'Paths' }
        @{ Command = 'history'; Flag = 'limit'; Expected = 'Limit' }
        @{ Command = 'history'; Flag = 'json'; Expected = 'Json' }
        @{ Command = 'features'; Flag = 'restore'; Expected = 'Restore' }
        @{ Command = 'features'; Flag = 'all-users-future'; Expected = 'AllUsersFuture' }
        @{ Command = 'check'; Flag = 'no-open'; Expected = 'NoOpen' }
        @{ Command = 'check'; Flag = 'report'; Expected = 'Report' }
    ) {
        Resolve-SwCommandParameter -Parameters (Get-RealParameters $Command) -Flag $Flag | Should -BeExactly $Expected
    }

    It 'Maps debug of <Command> to DebugMode in the real script' -ForEach @(
        $script:DebugCommands | ForEach-Object { @{ Command = $_ } }
    ) {
        Resolve-SwCommandParameter -Parameters (Get-RealParameters $Command) -Flag 'debug' | Should -BeExactly 'DebugMode'
        Resolve-SwCommandParameter -Parameters (Get-RealParameters $Command) -Flag 'd' | Should -BeExactly 'DebugMode'
    }

    It 'Has no DebugMode in the real scripts of history, status and remove' -ForEach @(
        @{ Command = 'history' }
        @{ Command = 'status' }
        @{ Command = 'remove' }
    ) {
        (Get-RealParameters $Command).ContainsKey('DebugMode') | Should -BeFalse
    }

    It 'Rejects a word for the real script of <Command> before anything runs' -ForEach @(
        @{ Command = 'update'; Word = 'help' }
        @{ Command = 'update'; Word = '/?' }
        @{ Command = 'status'; Word = 'foo' }
        @{ Command = 'clean'; Word = 'x' }
        @{ Command = 'remove'; Word = 'x' }
        @{ Command = 'features'; Word = 'x' }
        @{ Command = 'check'; Word = 'x' }
        @{ Command = 'optimize'; Word = 'x' }
        @{ Command = 'purge'; Word = 'x' }
        @{ Command = 'uninstall'; Word = 'x' }
    ) {
        $script:SWEEPR_BIN = $script:RealBin
        $result = Resolve-SwCommandArguments -CommandName $Command -Arguments @($Word)
        $result.Valid | Should -BeFalse
        $result.Message | Should -BeLike "Unexpected argument for sw ${Command}: *"
    }

    It 'Takes one word for analyze and any number for history from the real scripts' {
        $script:SWEEPR_BIN = $script:RealBin
        (Resolve-SwCommandArguments -CommandName 'analyze' -Arguments @('D:\')).Valid | Should -BeTrue
        (Resolve-SwCommandArguments -CommandName 'analyze' -Arguments @('a', 'b')).Valid | Should -BeFalse
        (Resolve-SwCommandArguments -CommandName 'history' -Arguments @('foo', 'bar', 'baz')).Valid | Should -BeTrue
    }

    It 'Accepts the options of the real status script, including a value' {
        $script:SWEEPR_BIN = $script:RealBin
        $result = Resolve-SwCommandArguments -CommandName 'status' -Arguments @('--watch', '--interval', '1s')
        $result.Valid | Should -BeTrue
        $result.Splat['Interval'] | Should -BeExactly '1s'
        $result.Splat['Watch'] | Should -BeTrue
    }
}
