# Sweepr - tests for Invoke-SwCommand, the start of a command script: the name of the command, the script
# path, the run environment, the debug session, the exit code and the restoring of the environment
# (RT-5, RT-11 to RT-15, S1, S3, S11).
#
# The rule numbers in the test names (RT- and S) number the rules and the safety invariants of the
# router's behavior; each testable rule and invariant has at least one test. The other router files are
# SwRouterLoad (RT-1 to RT-3), SwRouterArgs (RT-5 to RT-10, RT-24), SwRouterMain (RT-4, RT-16, RT-17,
# RT-21), SwRouterScreens (RT-18 to RT-20, RT-23) and SwRouterProcess (the two call forms).
#
# Interface pinned here (sweepr.ps1 is loaded by dot-sourcing):
#   Invoke-SwCommand -CommandName <string> -Arguments <string[]>
#       writes the output of the command script to the pipeline and nothing else, sets
#       $script:SweeprExitCode (always), and writes a rejection or an error through Write-SwError.
#   $script:SWEEPR_BIN is read at every call; the tests point it at stand-in scripts in $TestDrive.
#
# Platform notes:
#   - The command scripts are stand-ins in $TestDrive. The debug session, its end and the data folders
#     are mocks or live in $TestDrive. USERPROFILE and SWEEPR_DATA_DIR point into $TestDrive while the
#     tests run. Native programs started by stand-ins are the PowerShell that runs the tests.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:RouterFile = Join-Path $script:RepoRoot 'sweepr.ps1'
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
    $script:Pwsh = (Get-Process -Id $PID).Path
    $script:EnvNames = @('SWEEPR_DATA_DIR', 'SWEEPR_DRY_RUN', 'SWEEPR_DEBUG', '_SWEEPR_OPLOG_RUN_COMMAND', '_SWEEPR_OPLOG_RUN_ID', 'USERPROFILE', 'HOME', 'SWEEPR_NO_OPLOG')
    $script:RunNames = @('SWEEPR_DRY_RUN', 'SWEEPR_DEBUG', '_SWEEPR_OPLOG_RUN_COMMAND', '_SWEEPR_OPLOG_RUN_ID')

    $script:SavedEnv = @{}
    foreach ($name in $script:EnvNames) { $script:SavedEnv[$name] = [System.Environment]::GetEnvironmentVariable($name) }
    $script:SavedExitCode = $global:LASTEXITCODE
    $script:SavedCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture

    $script:HomeDir = Join-Path $TestDrive 'command-home'
    [void][System.IO.Directory]::CreateDirectory($script:HomeDir)
    $env:USERPROFILE = $script:HomeDir
    $env:HOME = $script:HomeDir
    $env:SWEEPR_DATA_DIR = Join-Path $script:HomeDir 'data'
    $env:SWEEPR_NO_OPLOG = '1'

    . $script:RouterFile

    # An unset variable is removed: .NET 8 treats an empty value as unset, newer .NET keeps it as an empty value.
    function script:Set-EnvValue {
        param([string]$Name, $Value)
        if ($null -eq $Value) { [System.Environment]::SetEnvironmentVariable($Name, [NullString]::Value) }
        else { [System.Environment]::SetEnvironmentVariable($Name, [string]$Value) }
    }

    function script:ConvertTo-TestLiteral([string]$Value) { "'" + $Value.Replace("'", "''") + "'" }
    $pwshLiteral = ConvertTo-TestLiteral $script:Pwsh

    $script:Standard = @'
[CmdletBinding()]
param(
    [Alias('dry-run')][switch]$DryRun,
    [Alias('d')][switch]$DebugMode,
    [Alias('h')][switch]$ShowHelp
)
'@
    $script:Scripts = [ordered]@{}
    $script:Scripts['fake'] = @'
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Path,
    [switch]$Flag,
    [Alias('h')][switch]$ShowHelp,
    [Alias('d')][switch]$DebugMode
)
'RAN'
'BOUND=' + (($PSBoundParameters.Keys | Sort-Object) -join ',')
'@
    $script:Scripts['envshow'] = $script:Standard + @'

'COMMAND=[' + $env:_SWEEPR_OPLOG_RUN_COMMAND + ']'
'ID=[' + $env:_SWEEPR_OPLOG_RUN_ID + ']'
'DRY=[' + $env:SWEEPR_DRY_RUN + ']'
'DEBUG=[' + $env:SWEEPR_DEBUG + ']'
'LAST=[' + $global:LASTEXITCODE + ']'
'@
    $script:Scripts['childenv'] = $script:Standard + @"

& $pwshLiteral -NoProfile -NonInteractive -Command '[Console]::Out.WriteLine(`$env:_SWEEPR_OPLOG_RUN_COMMAND + [char]124 + `$env:_SWEEPR_OPLOG_RUN_ID)'
"@
    $script:Scripts['output'] = $script:Standard + "`n'A'`n5`n'B'`n"
    $script:Scripts['silent'] = $script:Standard + "`n"
    $script:Scripts['ex5'] = $script:Standard + "`n'before'`nexit 5`n"
    $script:Scripts['ex0'] = $script:Standard + "`nexit 0`n"
    $script:Scripts['exneg'] = $script:Standard + "`nexit -3`n"
    $script:Scripts['exbig'] = $script:Standard + "`nexit 2147483647`n"
    $script:Scripts['exnative7'] = $script:Standard + "`n& $pwshLiteral -NoProfile -NonInteractive -Command 'exit 7'`nexit `$LASTEXITCODE`n"
    $script:Scripts['nativetolerated'] = $script:Standard + "`n& $pwshLiteral -NoProfile -NonInteractive -Command 'exit 128'`n'done'`n"
    $script:Scripts['nativethenzero'] = $script:Standard + "`n& $pwshLiteral -NoProfile -NonInteractive -Command 'exit 128'`nexit 0`n"
    $script:Scripts['lastleft'] = $script:Standard + "`n`$global:LASTEXITCODE = 3`n'done'`n"
    $script:Scripts['lastfeature'] = $script:Standard + "`n`$global:LASTEXITCODE = -1978335189`n'done'`n"
    $script:Scripts['update'] = $script:Standard + "`n'FAILING'`nexit 1`n"
    $script:Scripts['remove'] = $script:Standard + "`n'FAILING'`nexit 1`n"
    $script:Scripts['thrower'] = $script:Standard + "`nthrow 'boom'`n"
    $script:Scripts['setenv'] = $script:Standard + @'

$env:SWEEPR_DRY_RUN = '1'
$env:SWEEPR_DEBUG = '1'
'DURING=[' + $env:SWEEPR_DRY_RUN + '|' + $env:SWEEPR_DEBUG + ']'
'@
    $script:Scripts['setthenthrow'] = $script:Standard + "`n`$env:SWEEPR_DRY_RUN = '1'`n`$env:_SWEEPR_OPLOG_RUN_ID = 'changed'`nthrow 'boom'`n"
    $script:Scripts['setthenexit'] = $script:Standard + "`n`$env:SWEEPR_DRY_RUN = '1'`nexit 4`n"
    $script:Scripts['order'] = $script:Standard + "`n`$global:SwTestOrder.Add('script')`n"
    $script:Scripts['marker'] = $script:Standard + "`n[System.IO.File]::WriteAllText(`$env:SW_TEST_MARKER, 'ran')`n"

    function script:New-BinDir([string]$Path) {
        [void][System.IO.Directory]::CreateDirectory($Path)
        foreach ($name in $script:Scripts.Keys) {
            [System.IO.File]::WriteAllText((Join-Path $Path "$name.ps1"), $script:Scripts[$name] + "`n", $script:Utf8)
        }
        return $Path
    }
    $script:Bin = New-BinDir (Join-Path $TestDrive 'command-bin')

    # Runs the block with the host stream merged into the output; separates the lines of the host.
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
    function script:Invoke-Cmd([string]$Name, [string[]]$Words = @()) {
        $script:SweeprExitCode = 55
        $script:CallName = $Name
        $script:CallWords = $Words
        return (Invoke-Captured { Invoke-SwCommand -CommandName $script:CallName -Arguments $script:CallWords })
    }
    function script:Get-Value($Result, [string]$Key) {
        foreach ($line in @($Result.Output)) { if (([string]$line).StartsWith($Key + '=')) { return ([string]$line).Substring($Key.Length + 1) } }
        return $null
    }
}

AfterAll {
    foreach ($name in $script:SavedEnv.Keys) { Set-EnvValue -Name $name -Value $script:SavedEnv[$name] }
    $global:LASTEXITCODE = $script:SavedExitCode
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $script:SavedCulture
    Remove-Variable -Name SwTestOrder -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Invoke-SwCommand' {
    BeforeEach {
        foreach ($envName in $script:RunNames) { Set-EnvValue -Name $envName -Value $null }
        $script:SWEEPR_BIN = $script:Bin
        $script:SweeprExitCode = 0
        $global:LASTEXITCODE = 0
        $script:Errors = New-Object System.Collections.Generic.List[string]
        $script:Sessions = New-Object System.Collections.Generic.List[object]
        $global:SwTestOrder = New-Object System.Collections.Generic.List[string]
        Mock Write-SwError { $script:Errors.Add([string]$Message); Write-Host $Message }
        Mock Start-SwDebugSession { $script:Sessions.Add(@($Header)); $global:SwTestOrder.Add('start') }
        Mock Complete-SwDebugSession { $global:SwTestOrder.Add('complete'); $script:DebugAtComplete = $env:SWEEPR_DEBUG }
        $script:DebugAtComplete = 'not called'
    }
    AfterEach {
        foreach ($envName in $script:RunNames) { Set-EnvValue -Name $envName -Value $null }
        $env:SW_TEST_MARKER = $null
    }

    Context 'the name of the command and the script (RT-5, RT-11, S1)' {
        It 'Runs the stand-in script of a valid name and gives its output unchanged' {
            $result = Invoke-Cmd 'fake'
            $result.Thrown | Should -BeNullOrEmpty
            @($result.Output)[0] | Should -BeExactly 'RAN'
            $script:SweeprExitCode | Should -Be 0
        }

        It 'Writes nothing of its own: only the output of the script reaches the pipeline' {
            $result = Invoke-Cmd 'output'
            @($result.Output).Count | Should -Be 3
            @($result.Output)[0] | Should -BeExactly 'A'
            @($result.Output)[1] | Should -Be 5
            @($result.Output)[1] | Should -BeOfType [int]
            @($result.Output)[2] | Should -BeExactly 'B'
            $result.Lines.Count | Should -Be 0
        }

        It 'Writes nothing at all for a script without output, and returns no exit code object' {
            $result = Invoke-Cmd 'silent'
            @($result.Output).Count | Should -Be 0
            $result.Lines.Count | Should -Be 0
            $script:SweeprExitCode | Should -Be 0
        }

        It 'Passes the options and the words to the script' {
            $result = Invoke-Cmd 'fake' @('--flag', 'D:\scan target')
            Get-Value $result 'BOUND' | Should -BeExactly 'Flag,Path'
        }

        It 'Rejects the name <Name> as an unknown command with exit 2 and runs nothing' -ForEach @(
            @{ Name = '..\bin\marker' }
            @{ Name = '../bin/marker' }
            @{ Name = 'marker.ps1' }
            @{ Name = 'bin/marker' }
            @{ Name = 'c:marker' }
            @{ Name = 'marker;calc' }
            @{ Name = 'marker calc' }
            @{ Name = '$(calc)' }
            @{ Name = 'it''s' }
            @{ Name = '-marker' }
            @{ Name = '1marker' }
            @{ Name = 'mark*' }
            @{ Name = 'mark[e]r' }
        ) {
            $env:SW_TEST_MARKER = Join-Path $TestDrive 'marker.txt'
            if ([System.IO.File]::Exists($env:SW_TEST_MARKER)) { [System.IO.File]::Delete($env:SW_TEST_MARKER) }
            $result = Invoke-Cmd $Name
            $result.Thrown | Should -BeNullOrEmpty
            $script:SweeprExitCode | Should -Be 2
            $script:Errors.Count | Should -BeGreaterThan 0
            $script:Errors[0] | Should -BeLike 'Unknown command: *'
            $script:Errors[0] | Should -BeLike "*$([WildcardPattern]::Escape($Name))"
            [System.IO.File]::Exists($env:SW_TEST_MARKER) | Should -BeFalse
            @($result.Output).Count | Should -Be 0
        }

        It 'Tells an unknown command the commands to choose from' {
            $null = Invoke-Cmd '..\x'
            ($script:Errors -join "`n") | Should -Match 'Unknown command: '
        }

        It 'Runs no script for a rejected name: the environment and the exit code stay as they were' {
            $null = Invoke-Cmd '..\bin\envshow'
            foreach ($envName in $script:RunNames) { [System.Environment]::GetEnvironmentVariable($envName) | Should -BeNullOrEmpty }
            $script:Sessions.Count | Should -Be 0
        }

        It 'Reports a damaged installation with exit 1 and the command name when the script is missing' {
            $result = Invoke-Cmd 'nosuchscript'
            $result.Thrown | Should -BeNullOrEmpty
            $script:SweeprExitCode | Should -Be 1
            $script:Errors.Count | Should -BeGreaterThan 0
            $script:Errors[0] | Should -Match 'nosuchscript'
            $script:Errors[0] | Should -Not -BeLike 'Unknown command:*'
        }

        It 'Reports a damaged installation, not an exception, when the script folder is on a drive that does not exist' {
            $script:SWEEPR_BIN = 'Q:\no such drive\bin'
            $result = Invoke-Cmd 'fake'
            $result.Thrown | Should -BeNullOrEmpty
            $script:SweeprExitCode | Should -Be 1
            $script:Errors[0] | Should -Match 'fake'
        }

        It 'Reads $script:SWEEPR_BIN at every call' {
            $other = New-BinDir (Join-Path $TestDrive 'command-bin-other')
            [System.IO.File]::WriteAllText((Join-Path $other 'fake.ps1'), "[CmdletBinding()]`nparam([switch]`$Flag)`n'OTHER'`n", $script:Utf8)
            $script:SWEEPR_BIN = $other
            @((Invoke-Cmd 'fake').Output)[0] | Should -BeExactly 'OTHER'
            $script:SWEEPR_BIN = $script:Bin
            @((Invoke-Cmd 'fake').Output)[0] | Should -BeExactly 'RAN'
        }

        It 'Runs a script in a folder called <Folder>, with brackets, quotes, blanks and an ampersand, from there and nowhere else' -ForEach @(
            @{ Folder = 'd[1]' }
            @{ Folder = "Bob's tools! & files" }
            @{ Folder = ([string]'Tools ' + [char]0x2019 + 's [USB]') }
            @{ Folder = 'a b (x86)' }
            @{ Folder = 'a`b $x ;y' }
        ) {
            $parent = Join-Path $TestDrive ('literal-' + [guid]::NewGuid().ToString('N'))
            # A sibling the folder name would match as a pattern, with a script of the same name that says so.
            $decoy = Join-Path $parent 'd1'
            [void][System.IO.Directory]::CreateDirectory($decoy)
            [System.IO.File]::WriteAllText((Join-Path $decoy 'fake.ps1'), "[CmdletBinding()]`nparam([switch]`$Flag)`n'DECOY'`n", $script:Utf8)
            $bin = [System.IO.Path]::Combine($parent, $Folder)
            [void][System.IO.Directory]::CreateDirectory($bin)
            [System.IO.File]::WriteAllText([System.IO.Path]::Combine($bin, 'fake.ps1'), "[CmdletBinding()]`nparam([switch]`$Flag)`n'REAL'`n", $script:Utf8)
            $script:SWEEPR_BIN = $bin
            $result = Invoke-Cmd 'fake' @('--flag')
            $result.Thrown | Should -BeNullOrEmpty
            @($result.Output)[0] | Should -BeExactly 'REAL'
            $script:SweeprExitCode | Should -Be 0
        }
    }

    Context 'the run environment (RT-12)' {
        It 'Sets the command name and a run id of digits and hyphens for the script' {
            $result = Invoke-Cmd 'envshow'
            Get-Value $result 'COMMAND' | Should -BeExactly '[envshow]'
            Get-Value $result 'ID' | Should -MatchExactly '^\[[0-9]{14}-[0-9]+-[0-9]{1,5}\]$'
        }

        It 'Builds the run id from the time, the process id and a random number' {
            Mock Get-Date {
                $moment = [datetime]'2026-10-15 10:00:00'
                if ($PesterBoundParameters.ContainsKey('Format')) { return $moment.ToString([string]$PesterBoundParameters['Format'], [System.Globalization.CultureInfo]::InvariantCulture) }
                return $moment
            }
            Mock Get-Random { 17 }
            $result = Invoke-Cmd 'envshow'
            Get-Value $result 'ID' | Should -BeExactly "[20261015100000-$PID-17]"
        }

        It 'Uses ASCII digits and the Gregorian year in a culture with another calendar' {
            $culture = $null
            try { $culture = [System.Globalization.CultureInfo]::new('ar-SA') } catch { $culture = $null }
            if ($null -eq $culture -or $culture.Name -ne 'ar-SA') { Set-ItResult -Skipped -Because 'the culture ar-SA is not available on this host'; return }
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $culture
            try { $result = Invoke-Cmd 'envshow' }
            finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $script:SavedCulture }
            $id = Get-Value $result 'ID'
            $id | Should -MatchExactly '^\[[0-9]{14}-[0-9]+-[0-9]{1,5}\]$'
            $year = [datetime]::Now.Year
            ($id.Substring(1, 4) -eq [string]$year -or $id.Substring(1, 4) -eq [string]($year - 1)) | Should -BeTrue
        }

        It 'Gives the child processes of the script the same values' {
            $result = Invoke-Cmd 'childenv'
            $line = @($result.Output | Where-Object { ([string]$_) -match '^childenv\|' })
            $line.Count | Should -Be 1
            ([string]$line[0]) | Should -MatchExactly '^childenv\|[0-9]{14}-[0-9]+-[0-9]{1,5}$'
        }

        It 'Sets $global:LASTEXITCODE to 0 before the script starts' {
            $global:LASTEXITCODE = 9
            $result = Invoke-Cmd 'envshow'
            Get-Value $result 'LAST' | Should -BeExactly '[0]'
        }

        It 'Gives the script the values the user had for the unrelated variables' {
            $env:SWEEPR_DRY_RUN = 'user value'
            $result = Invoke-Cmd 'envshow'
            Get-Value $result 'DRY' | Should -BeExactly '[user value]'
        }
    }

    Context 'the debug session (RT-13)' {
        It 'Starts one debug session with a header for <Words>, and ends it after the run' -ForEach @(
            @{ Words = @('--debug') }
            @{ Words = @('-d') }
            @{ Words = @('-Debug') }
            @{ Words = @('-DebugMode') }
            @{ Words = @('--DEBUG') }
        ) {
            $null = Invoke-Cmd 'fake' $Words
            $script:Sessions.Count | Should -Be 1
            Should -Invoke Start-SwDebugSession -Times 1 -Exactly
            Should -Invoke Complete-SwDebugSession -Times 1 -Exactly
        }

        It 'Gives the debug session a header whose second line is the command line' {
            $null = Invoke-Cmd 'fake' @('--help', '--debug')
            $script:Sessions.Count | Should -Be 1
            $header = @($script:Sessions[0])
            $header.Count | Should -BeGreaterThan 1
            $header[1] | Should -BeExactly 'Command: sw fake --help --debug'
        }

        It 'Starts no debug session without the option' -ForEach @(
            @{ Words = @() }
            @{ Words = @('--flag') }
            @{ Words = @('--help') }
            @{ Words = @('D:\debug') }
        ) {
            $null = Invoke-Cmd 'fake' $Words
            Should -Invoke Start-SwDebugSession -Times 0 -Exactly
            Should -Invoke Complete-SwDebugSession -Times 0 -Exactly
        }

        It 'Starts the session before the script and ends it after the script' {
            $null = Invoke-Cmd 'order' @('--debug')
            @($global:SwTestOrder) | Should -Be @('start', 'script', 'complete')
        }

        It 'Ends the debug session also when the script throws, and lets the exception through' {
            $result = Invoke-Cmd 'thrower' @('--debug')
            $result.Thrown | Should -Not -BeNullOrEmpty
            $result.Thrown.Exception.Message | Should -Match 'boom'
            Should -Invoke Start-SwDebugSession -Times 1 -Exactly
            Should -Invoke Complete-SwDebugSession -Times 1 -Exactly
        }

        It 'Does not start a session for a rejected line' {
            $null = Invoke-Cmd 'fake' @('--debug', '--bogus')
            Should -Invoke Start-SwDebugSession -Times 0 -Exactly
            Should -Invoke Complete-SwDebugSession -Times 0 -Exactly
            $script:SweeprExitCode | Should -Be 2
        }
    }

    Context 'the exit code (RT-14, S11)' {
        It 'Takes the code of an explicit exit: <Script> gives <Expected>' -ForEach @(
            @{ Script = 'ex5'; Expected = 5 }
            @{ Script = 'exneg'; Expected = -3 }
            @{ Script = 'exbig'; Expected = 2147483647 }
            @{ Script = 'exnative7'; Expected = 7 }
            @{ Script = 'update'; Expected = 1 }
            @{ Script = 'remove'; Expected = 1 }
        ) {
            $null = Invoke-Cmd $Script
            $script:SweeprExitCode | Should -Be $Expected
        }

        It 'Gives 0 for exit 0, also after a native program that failed' -ForEach @(
            @{ Script = 'ex0' }
            @{ Script = 'nativethenzero' }
        ) {
            $null = Invoke-Cmd $Script
            $script:SweeprExitCode | Should -Be 0
        }

        It 'Gives 0 for a script that ends without exit, whatever code a native program left: <Script>' -ForEach @(
            @{ Script = 'silent' }
            @{ Script = 'nativetolerated' }
            @{ Script = 'lastleft' }
            @{ Script = 'lastfeature' }
            @{ Script = 'fake' }
        ) {
            $null = Invoke-Cmd $Script
            $script:SweeprExitCode | Should -Be 0
        }

        It 'Does not take an old code from before the call' {
            $global:LASTEXITCODE = 9
            $null = Invoke-Cmd 'silent'
            $script:SweeprExitCode | Should -Be 0
            $script:SweeprExitCode = 8
            $null = Invoke-Cmd 'silent'
            $script:SweeprExitCode | Should -Be 0
        }

        It 'Sets $script:SweeprExitCode on every call, also for a script with output' {
            $script:SweeprExitCode = 55
            $null = Invoke-SwCommand -CommandName 'output' -Arguments @()
            $script:SweeprExitCode | Should -Be 0
        }

        It 'Gives the output of the failing script and the code 1 for update and remove' {
            $result = Invoke-Cmd 'update'
            @($result.Output)[0] | Should -BeExactly 'FAILING'
            $script:SweeprExitCode | Should -Be 1
            $result = Invoke-Cmd 'remove'
            @($result.Output)[0] | Should -BeExactly 'FAILING'
            $script:SweeprExitCode | Should -Be 1
        }

        It 'Gives exit 0 for the help of a script after a failed earlier run left $global:LASTEXITCODE at 1' {
            $global:LASTEXITCODE = 1
            $null = Invoke-Cmd 'fake' @('--help')
            $script:SweeprExitCode | Should -Be 0
        }
    }

    Context 'putting the environment back (RT-15, S3)' {
        It 'Leaves the variables unset that were unset before, after a script that sets them' {
            $result = Invoke-Cmd 'setenv'
            Get-Value $result 'DURING' | Should -BeExactly '[1|1]'
            foreach ($envName in $script:RunNames) { [System.Environment]::GetEnvironmentVariable($envName) | Should -BeNullOrEmpty -Because $envName }
        }

        It 'Puts the values back that the user had' {
            $env:SWEEPR_DRY_RUN = 'user dry'
            $env:SWEEPR_DEBUG = 'user debug'
            $env:_SWEEPR_OPLOG_RUN_COMMAND = 'user command'
            $env:_SWEEPR_OPLOG_RUN_ID = 'user-id'
            $null = Invoke-Cmd 'setenv'
            $env:SWEEPR_DRY_RUN | Should -BeExactly 'user dry'
            $env:SWEEPR_DEBUG | Should -BeExactly 'user debug'
            $env:_SWEEPR_OPLOG_RUN_COMMAND | Should -BeExactly 'user command'
            $env:_SWEEPR_OPLOG_RUN_ID | Should -BeExactly 'user-id'
        }

        It 'Keeps a dry run that the user set before: 1 before and 1 after' {
            $env:SWEEPR_DRY_RUN = '1'
            $null = Invoke-Cmd 'setenv'
            $env:SWEEPR_DRY_RUN | Should -BeExactly '1'
        }

        It 'Leaves the run values as they were after an ordinary run' {
            $env:_SWEEPR_OPLOG_RUN_ID = 'before-id'
            $null = Invoke-Cmd 'envshow'
            $env:_SWEEPR_OPLOG_RUN_ID | Should -BeExactly 'before-id'
            [System.Environment]::GetEnvironmentVariable('_SWEEPR_OPLOG_RUN_COMMAND') | Should -BeNullOrEmpty
        }

        It 'Puts the environment back when the script throws' {
            $env:_SWEEPR_OPLOG_RUN_ID = 'before-id'
            $result = Invoke-Cmd 'setthenthrow'
            $result.Thrown | Should -Not -BeNullOrEmpty
            [System.Environment]::GetEnvironmentVariable('SWEEPR_DRY_RUN') | Should -BeNullOrEmpty
            $env:_SWEEPR_OPLOG_RUN_ID | Should -BeExactly 'before-id'
        }

        It 'Puts the environment back when the script exits with an error' {
            $null = Invoke-Cmd 'setthenexit'
            $script:SweeprExitCode | Should -Be 4
            [System.Environment]::GetEnvironmentVariable('SWEEPR_DRY_RUN') | Should -BeNullOrEmpty
        }

        It 'Removes SWEEPR_DEBUG that a debug session set, and keeps the user value of an earlier one' -ForEach @(
            @{ Before = $null }
            @{ Before = 'keep' }
        ) {
            Mock Start-SwDebugSession { $env:SWEEPR_DEBUG = '1'; $global:SwTestOrder.Add('start') }
            Set-EnvValue -Name 'SWEEPR_DEBUG' -Value $Before
            $null = Invoke-Cmd 'fake' @('--debug')
            [System.Environment]::GetEnvironmentVariable('SWEEPR_DEBUG') | Should -BeExactly $Before
        }

        It 'Puts the environment back after the debug session has ended, not before' {
            Mock Start-SwDebugSession { $env:SWEEPR_DEBUG = '1' }
            $null = Invoke-Cmd 'fake' @('--debug')
            $script:DebugAtComplete | Should -BeExactly '1'
            [System.Environment]::GetEnvironmentVariable('SWEEPR_DEBUG') | Should -BeNullOrEmpty
        }

        It 'Does not start the next run in debug mode after a run with --debug' {
            Mock Start-SwDebugSession { $env:SWEEPR_DEBUG = '1' }
            $null = Invoke-Cmd 'fake' @('--debug')
            $result = Invoke-Cmd 'envshow'
            Get-Value $result 'DEBUG' | Should -BeExactly '[]'
        }

        It 'Leaves a dry run of an earlier run out of the next run' {
            $null = Invoke-Cmd 'setenv'
            $result = Invoke-Cmd 'envshow'
            Get-Value $result 'DRY' | Should -BeExactly '[]'
        }

        It 'Puts the environment back after a run that was rejected before it started, too' {
            $env:SWEEPR_DRY_RUN = 'user dry'
            $null = Invoke-Cmd 'fake' @('--bogus')
            $env:SWEEPR_DRY_RUN | Should -BeExactly 'user dry'
            [System.Environment]::GetEnvironmentVariable('_SWEEPR_OPLOG_RUN_ID') | Should -BeNullOrEmpty
        }
    }

    Context 'rejections (RT-10, S2)' {
        It 'Rejects <Case> with exit 2, a message with the prefix and the word, and the hint, and runs nothing' -ForEach @(
            @{ Case = 'an unknown option'; Words = @('--bogus'); Prefix = 'Unknown option for sw fake: '; Word = '--bogus' }
            @{ Case = 'the common parameter --verbose'; Words = @('--verbose'); Prefix = 'Unknown option for sw fake: '; Word = '--verbose' }
            @{ Case = 'a value for a switch'; Words = @('--flag=false'); Prefix = 'Option takes no value for sw fake: '; Word = '--flag=false' }
            @{ Case = 'an extra word'; Words = @('a', 'b'); Prefix = 'Unexpected argument for sw fake: '; Word = 'b' }
        ) {
            $result = Invoke-Cmd 'fake' $Words
            $result.Thrown | Should -BeNullOrEmpty
            $script:SweeprExitCode | Should -Be 2
            $script:Errors[0] | Should -BeLike "$Prefix*"
            $script:Errors[0] | Should -BeLike "*$Word"
            $result.Text | Should -Match 'sw fake --help'
            @($result.Output).Count | Should -Be 0
            [System.Environment]::GetEnvironmentVariable('_SWEEPR_OPLOG_RUN_ID') | Should -BeNullOrEmpty
            Should -Invoke Start-SwDebugSession -Times 0 -Exactly
        }
    }
}
