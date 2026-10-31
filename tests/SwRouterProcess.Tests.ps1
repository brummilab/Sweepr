# Sweepr - tests for the router as the launchers start it: a child PowerShell runs sweepr.ps1 in the two
# call forms of 2.2, and both must give the same result for the same words (RT-1, RT-2, RT-4, RT-9 to
# RT-11, RT-13, RT-14, RT-16, RT-18 to RT-22, S1, S2, S4, S11).
#
# The two forms:
#   File     <powershell> -NoProfile -ExecutionPolicy Bypass -File <sweepr.ps1> <word> <word> ...
#            (what sw.cmd and sweepr.cmd do)
#   Command  <powershell> -NoProfile -ExecutionPolicy Bypass -Command "& '<sweepr.ps1>' '<word>' ...; exit $LASTEXITCODE"
#            (what sw.exe does; every word is a literal in single quotes, a quote is doubled)
#
# The rule numbers in the test names (RT- and S) number the rules and the safety invariants of the
# router's behavior; each testable rule and invariant has at least one test. The other router files are
# SwRouterLoad (RT-1 to RT-3), SwRouterArgs (RT-5 to RT-10, RT-24), SwRouterCommand (RT-11 to RT-15),
# SwRouterMain (RT-4, RT-16, RT-17, RT-21) and SwRouterScreens (RT-18 to RT-20, RT-23).
#
# Method: every run is a child PowerShell (the one that runs the tests) on a fake installation in
# $TestDrive: a copy of sweepr.ps1, VERSION and lib, and stand-in command scripts in bin. USERPROFILE
# and SWEEPR_DATA_DIR of the child point into $TestDrive, the standard input is closed, nothing runs a
# real update and there is no network. The stand-ins start no program but the test PowerShell.
#
# Platform notes:
#   - A word of the form --name:value is two words under File and one under Command (PowerShell splits
#     it). The tests for it use the rules of 2.2; Windows PowerShell 5.1 behaves the same way only on
#     the Windows CI.
#   - Exit codes above 255 and negative ones are not checked in a process on Linux (the system keeps
#     the low byte); the in-process tests in SwRouterCommand.Tests.ps1 check the full range.
#   - Tests marked [W] describe a Windows fact and are meant to fail on Linux where it does not hold.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    $script:Forms = @(@{ Form = 'File' }, @{ Form = 'Command' })
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:RouterFile = Join-Path $script:RepoRoot 'sweepr.ps1'
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
    $script:Pwsh = (Get-Process -Id $PID).Path
    $pwshLiteral = "'" + $script:Pwsh.Replace("'", "''") + "'"

    function script:New-Dir([string]$Path) {
        [void][System.IO.Directory]::CreateDirectory($Path)
        return $Path
    }
    function script:ConvertTo-TestLiteral([string]$Value) { "'" + $Value.Replace("'", "''") + "'" }
    function script:ConvertTo-WinArgument([string]$Argument) {
        if ($Argument.Length -gt 0 -and $Argument.IndexOfAny([char[]]@(' ', "`t", "`n", '"')) -lt 0) { return $Argument }
        $builder = New-Object System.Text.StringBuilder
        [void]$builder.Append('"')
        $i = 0
        while ($i -lt $Argument.Length) {
            $slashes = 0
            while ($i -lt $Argument.Length -and $Argument[$i] -eq '\') { $slashes++; $i++ }
            if ($i -eq $Argument.Length) { [void]$builder.Append('\', $slashes * 2); break }
            if ($Argument[$i] -eq '"') { [void]$builder.Append('\', $slashes * 2 + 1); [void]$builder.Append('"') }
            else { [void]$builder.Append('\', $slashes); [void]$builder.Append($Argument[$i]) }
            $i++
        }
        [void]$builder.Append('"')
        return $builder.ToString()
    }
    function script:Get-ChildStderr([string]$Text) {
        if ([string]::IsNullOrEmpty($Text)) { return '' }
        $clean = [regex]::Replace($Text, '(?s)<Obj S="progress".*?</Obj>', '')
        $clean = [regex]::Replace($clean, '<Objs[^>]*>|</Objs>|#< CLIXML', '')
        return $clean.Trim()
    }
    function script:Get-Lines([string]$Text) { return @($Text -split "`r?`n" | Where-Object { $_.Trim() -ne '' }) }
    function script:Remove-Ansi([string]$Text) { return [regex]::Replace($Text, '\x1b\[[0-9;?]*[A-Za-z]', '') }
    function script:Get-Listing([string]$Root) {
        if (-not [System.IO.Directory]::Exists($Root)) { return @() }
        return @([System.IO.Directory]::GetFileSystemEntries($Root, '*', [System.IO.SearchOption]::AllDirectories) | Sort-Object)
    }

    # Stand-in command scripts with the parameter blocks of the real commands.
    $script:Blocks = [ordered]@{}
    $script:Blocks['clean'] = "[CmdletBinding()]`nparam([Alias('dry-run')][switch]`$DryRun, [Alias('s')][switch]`$System, [Alias('game-media')][switch]`$GameMedia, [Alias('gpu-shaders')][switch]`$GpuShaders, [Alias('d')][switch]`$DebugMode, [Alias('w')][switch]`$Whitelist, [Alias('h')][switch]`$ShowHelp)"
    $script:Blocks['purge'] = "[CmdletBinding()]`nparam([Alias('dry-run')][switch]`$DryRun, [Alias('d')][switch]`$DebugMode, [Alias('p')][switch]`$Paths, [Alias('h')][switch]`$ShowHelp)"
    $script:Blocks['uninstall'] = "[CmdletBinding()]`nparam([Alias('dry-run')][switch]`$DryRun, [Alias('d')][switch]`$DebugMode, [Alias('r')][switch]`$Rescan, [switch]`$List, [Alias('h')][switch]`$ShowHelp)"
    $script:Blocks['status'] = "[CmdletBinding(PositionalBinding = `$false)]`nparam([Alias('h')][switch]`$ShowHelp, [switch]`$Json, [switch]`$Watch, [string]`$Interval)"
    $script:Blocks['analyze'] = "[CmdletBinding()]`nparam([Parameter(Position = 0)][string]`$Path, [Alias('h')][switch]`$ShowHelp, [switch]`$Json, [Alias('d')][switch]`$DebugMode)"
    $script:Blocks['history'] = "[CmdletBinding(PositionalBinding = `$false)]`nparam([Alias('h')][switch]`$ShowHelp, [switch]`$Json, `$Limit, [Parameter(ValueFromRemainingArguments = `$true)][string[]]`$RemainingArguments)"
    $script:Blocks['features'] = "[CmdletBinding()]`nparam([Alias('dry-run')][switch]`$DryRun, [Alias('d')][switch]`$DebugMode, [switch]`$List, [Alias('all-users-future')][switch]`$AllUsersFuture, [switch]`$Restore, [Alias('h')][switch]`$ShowHelp)"
    $script:Blocks['update'] = "[CmdletBinding()]`nparam([Alias('d')][switch]`$DebugMode, [Alias('h')][switch]`$ShowHelp)"
    $script:Blocks['remove'] = "[CmdletBinding()]`nparam([Alias('h')][switch]`$ShowHelp)"
    $script:BodyTemplate = @"

if (`$env:SW_TEST_MODE -eq 'jsondebug') {
    . ([System.IO.Path]::Combine(`$PSScriptRoot, '..', 'lib', 'core', 'log.ps1'))
    Write-SwDebug 'a debug line of the command'
    '[{"name":"Example"}]'
    return
}
if (`$env:SW_TEST_MODE -eq 'json') { '{"example":1}'; return }
if (`$PSBoundParameters.ContainsKey('ShowHelp')) { 'HELP:@@NAME@@'; return }
'RAN:@@NAME@@'
'BOUND=' + ((`$PSBoundParameters.Keys | Sort-Object) -join ',')
'DEBUGENV=[' + `$env:SWEEPR_DEBUG + ']'
'COMMANDENV=[' + `$env:_SWEEPR_OPLOG_RUN_COMMAND + ']'
@@EXTRA@@
switch (`$env:SW_TEST_MODE) {
    'exit5' { exit 5 }
    'native7' { & $pwshLiteral -NoProfile -NonInteractive -Command 'exit 7'; exit `$LASTEXITCODE }
    'tolerated' { & $pwshLiteral -NoProfile -NonInteractive -Command 'exit 128'; 'done' }
    'lastfeature' { `$global:LASTEXITCODE = -1978335189; 'done' }
    'fail1' { 'FAILING'; exit 1 }
    'throw' { throw 'boom' }
}
"@
    function script:New-ProcInstall {
        param([string]$Name = 'sweepr', [switch]$Portable)
        $parent = New-Dir (Join-Path $TestDrive ('p-' + [guid]::NewGuid().ToString('N')))
        $root = New-Dir ([System.IO.Path]::Combine($parent, $Name))
        $bin = New-Dir (Join-Path $root 'bin')
        Copy-Item -LiteralPath $script:RouterFile -Destination $root
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'lib') -Destination $root -Recurse
        [System.IO.File]::WriteAllText((Join-Path $root 'VERSION'), "9.8.7`n", $script:Utf8)
        if ($Portable) { [System.IO.File]::WriteAllText((Join-Path $root 'sweepr.portable'), '') }
        foreach ($command in $script:Blocks.Keys) {
            $extra = ''
            if ($command -eq 'history') { $extra = "'LIMIT=[' + `$Limit + ']'`n'WORDS=[' + (`$RemainingArguments -join '|') + ']'" }
            $body = $script:BodyTemplate.Replace('@@NAME@@', $command).Replace('@@EXTRA@@', $extra)
            [System.IO.File]::WriteAllText((Join-Path $bin "$command.ps1"), $script:Blocks[$command] + $body + "`n", $script:Utf8)
        }
        return [pscustomobject]@{
            Root   = $root
            Parent = $parent
            Router = (Join-Path $root 'sweepr.ps1')
            Home   = (New-Dir (Join-Path $parent 'home'))
        }
    }
    $script:Unset = @('SWEEPR_DEBUG', 'SWEEPR_DRY_RUN', 'SWEEPR_ANALYZE_PATH', '_SWEEPR_OPLOG_RUN_COMMAND', '_SWEEPR_OPLOG_RUN_ID', 'SW_TEST_MODE', 'SWEEPR_DATA_DIR')

    # Runs the router in one of the two forms. Returns the exit code and the output of both streams.
    function script:Invoke-Router {
        param($Install, [string]$Form, [string[]]$Words = @(), [hashtable]$Environment = @{}, [string]$Prefix = '', [string]$DataDir = $null, [switch]$KeepData)
        $env2 = @{ USERPROFILE = $Install.Home; HOME = $Install.Home; SWEEPR_NO_OPLOG = '1' }
        if (-not $KeepData) {
            if ([string]::IsNullOrEmpty($DataDir)) { $DataDir = Join-Path $Install.Parent ('data-' + [guid]::NewGuid().ToString('N')) }
            $env2['SWEEPR_DATA_DIR'] = $DataDir
        }
        foreach ($name in $Environment.Keys) { $env2[$name] = $Environment[$name] }
        $remove = @($script:Unset | Where-Object { -not $env2.ContainsKey($_) })
        if ($Form -eq 'File') {
            $line = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (ConvertTo-WinArgument $Install.Router)
            foreach ($word in $Words) { $line += ' ' + (ConvertTo-WinArgument $word) }
        }
        else {
            $literals = ''
            foreach ($word in $Words) { $literals += ' ' + (ConvertTo-TestLiteral $word) }
            $text = $Prefix + '& ' + (ConvertTo-TestLiteral $Install.Router) + $literals + '; exit $LASTEXITCODE'
            $line = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command ' + (ConvertTo-WinArgument $text)
        }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:Pwsh
        $psi.Arguments = $line
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.WorkingDirectory = $TestDrive
        foreach ($name in $remove) { if ($psi.EnvironmentVariables.ContainsKey($name)) { $psi.EnvironmentVariables.Remove($name) } }
        foreach ($name in $env2.Keys) { $psi.EnvironmentVariables[$name] = [string]$env2[$name] }
        $process = [System.Diagnostics.Process]::Start($psi)
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { $process.Kill(); throw 'child PowerShell timed out' }
        $out = Remove-Ansi $stdout.Result
        $err = Remove-Ansi (Get-ChildStderr $stderr.Result)
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Out = $out; Err = $err; All = ($out + "`n" + $err); DataDir = $DataDir }
    }
    function script:Get-Value($Result, [string]$Key) {
        foreach ($line in (Get-Lines $Result.Out)) { if ($line.StartsWith($Key + '=')) { return $line.Substring($Key.Length + 1) } }
        return $null
    }
    $script:Shared = New-ProcInstall
}

Describe 'The router as the launchers start it' {
    Context 'words are data and both forms agree (RT-1, RT-7, RT-9, S1, S2)' {
        It 'Binds <Words> of <Command> to <Bound> in the form <Form>' -ForEach @(
            foreach ($form in 'File', 'Command') {
                @{ Form = $form; Command = 'clean'; Words = @('-s'); Bound = 'System' }
                @{ Form = $form; Command = 'clean'; Words = @('-w'); Bound = 'Whitelist' }
                @{ Form = $form; Command = 'purge'; Words = @('-p'); Bound = 'Paths' }
                @{ Form = $form; Command = 'clean'; Words = @('--dry-run', '--system'); Bound = 'DryRun,System' }
                @{ Form = $form; Command = 'clean'; Words = @('-h'); Bound = 'ShowHelp' }
            }
        ) {
            $run = Invoke-Router $script:Shared $Form (@($Command) + $Words)
            $run.ExitCode | Should -Be 0
            if ($Bound -eq 'ShowHelp') { $run.Out | Should -Match "HELP:$Command" }
            else { Get-Value $run 'BOUND' | Should -BeExactly $Bound }
        }

        It 'Does not take -s for a parameter of PowerShell itself: no help, no ambiguity message, in the form <Form>' -ForEach $script:Forms {
            $run = Invoke-Router $script:Shared $Form @('clean', '-s')
            $run.ExitCode | Should -Be 0
            $run.Out | Should -Match 'RAN:clean'
            $run.All | Should -Not -Match '(?i)ambiguous|cannot be resolved|more than one'
            $run.Out | Should -Not -Match 'HELP:'
        }

        It 'Gives history --limit:5 and --limit 5 the same limit in the form <Form>' -ForEach $script:Forms {
            $colon = Invoke-Router $script:Shared $Form @('history', '--limit:5')
            $space = Invoke-Router $script:Shared $Form @('history', '--limit', '5')
            Get-Value $colon 'LIMIT' | Should -BeExactly '[5]'
            Get-Value $space 'LIMIT' | Should -BeExactly '[5]'
            $colon.ExitCode | Should -Be 0
        }

        It 'Gives every word of history to the script in the form <Form>' -ForEach $script:Forms {
            $run = Invoke-Router $script:Shared $Form @('history', 'foo', 'bar')
            Get-Value $run 'WORDS' | Should -BeExactly '[foo|bar]'
        }

        It 'Rejects the unknown option <Word> before the script runs, with exit 2 and the message, in the form <Form>' -ForEach @(
            foreach ($form in 'File', 'Command') {
                @{ Form = $form; Word = '--verbose' }
                @{ Form = $form; Word = '-v' }
            }
        ) {
            $run = Invoke-Router $script:Shared $Form @('clean', $Word)
            $run.ExitCode | Should -Be 2
            $run.All | Should -Match ('Unknown option for sw clean: .*' + [regex]::Escape($Word))
            $run.All | Should -Match 'sw clean --help'
            $run.Out | Should -Not -Match 'RAN:'
        }

        It 'Rejects a value for a switch and a missing value with exit 2 in the form <Form>' -ForEach $script:Forms {
            $run = Invoke-Router $script:Shared $Form @('clean', '--dry-run=false')
            $run.ExitCode | Should -Be 2
            $run.All | Should -Match 'Option takes no value for sw clean: '
            $run.Out | Should -Not -Match 'RAN:'
            $run = Invoke-Router $script:Shared $Form @('status', '--interval')
            $run.ExitCode | Should -Be 2
            $run.All | Should -Match 'Option needs a value for sw status: '
        }

        It 'Rejects an extra word with exit 2 in the form <Form>' -ForEach $script:Forms {
            $run = Invoke-Router $script:Shared $Form @('clean', 'x')
            $run.ExitCode | Should -Be 2
            $run.All | Should -Match 'Unexpected argument for sw clean: x'
            $run = Invoke-Router $script:Shared $Form @('update', 'help')
            $run.ExitCode | Should -Be 2
            $run.All | Should -Match 'Unexpected argument for sw update: help'
            $run.Out | Should -Not -Match 'RAN:'
        }

        It 'Rejects an unknown command with exit 2 and names the commands in the form <Form>' -ForEach $script:Forms {
            $run = Invoke-Router $script:Shared $Form @('nonsense')
            $run.ExitCode | Should -Be 2
            $run.All | Should -Match 'Unknown command: nonsense'
            $run.All | Should -Match '\bclean\b'
            $run.All | Should -Match '\bremove\b'
            $run.All | Should -Match 'sw --help'
        }

        It 'Keeps an apostrophe in a word and rejects it as an unknown command in the form <Form>' -ForEach $script:Forms {
            $run = Invoke-Router $script:Shared $Form @("it's")
            $run.ExitCode | Should -Be 2
            $run.All | Should -Match "Unknown command: it's"
            $run.Out | Should -Not -Match 'RAN:'
        }

        It 'Never runs a word as code in the form <Form>' -ForEach $script:Forms {
            $marker = Join-Path $script:Shared.Parent ('marker-' + [guid]::NewGuid().ToString('N') + '.txt')
            foreach ($word in ('$(New-Item -ItemType File -Path ' + (ConvertTo-TestLiteral $marker) + ')'), ('x; New-Item -ItemType File -Path ' + (ConvertTo-TestLiteral $marker))) {
                $run = Invoke-Router $script:Shared $Form @($word)
                $run.ExitCode | Should -Be 2
                $run.All | Should -Match 'Unknown command: '
            }
            [System.IO.File]::Exists($marker) | Should -BeFalse
        }

        It 'Never starts a script by a path word in the form <Form>' -ForEach $script:Forms {
            foreach ($word in '..\bin\clean', 'clean.ps1') {
                $run = Invoke-Router $script:Shared $Form @($word)
                $run.ExitCode | Should -Be 2
                $run.Out | Should -Not -Match 'RAN:'
            }
        }

        It 'Takes the command in any letter case and passes it on in lower case in the form <Form>' -ForEach $script:Forms {
            $run = Invoke-Router $script:Shared $Form @('CLEAN', '--dry-run')
            $run.ExitCode | Should -Be 0
            Get-Value $run 'COMMANDENV' | Should -BeExactly '[clean]'
            Get-Value $run 'BOUND' | Should -BeExactly 'DryRun'
        }
    }

    Context 'the debug session (RT-4, RT-13)' {
        It 'Writes the debug session file for sw clean --help --debug in the form <Form>' -ForEach $script:Forms {
            $run = Invoke-Router $script:Shared $Form @('clean', '--help', '--debug')
            $run.ExitCode | Should -Be 0
            $run.Out | Should -Match 'HELP:clean'
            $file = [System.IO.Path]::Combine($run.DataDir, 'config', 'sweepr_debug_session.log')
            [System.IO.File]::Exists($file) | Should -BeTrue
            $text = [System.IO.File]::ReadAllText($file)
            $text | Should -Match 'Command: sw clean .*--debug'
        }

        It 'Moves a leading --debug behind the command and starts the session in the form <Form>' -ForEach $script:Forms {
            $run = Invoke-Router $script:Shared $Form @('--debug', 'clean', '--dry-run')
            $run.ExitCode | Should -Be 0
            Get-Value $run 'BOUND' | Should -BeExactly 'DebugMode,DryRun'
            Get-Value $run 'DEBUGENV' | Should -BeExactly '[1]'
            [System.IO.File]::Exists([System.IO.Path]::Combine($run.DataDir, 'config', 'sweepr_debug_session.log')) | Should -BeTrue
        }

        It 'Takes -Debug of PowerShell as the debug option of the command in the form <Form>' -ForEach $script:Forms {
            $run = Invoke-Router $script:Shared $Form @('clean', '-Debug')
            $run.ExitCode | Should -Be 0
            Get-Value $run 'BOUND' | Should -BeExactly 'DebugMode'
            [System.IO.File]::Exists([System.IO.Path]::Combine($run.DataDir, 'config', 'sweepr_debug_session.log')) | Should -BeTrue
        }

        It 'Starts no session without the option in the form <Form>' -ForEach $script:Forms {
            $run = Invoke-Router $script:Shared $Form @('clean', '--dry-run')
            Get-Value $run 'DEBUGENV' | Should -BeExactly '[]'
            [System.IO.File]::Exists([System.IO.Path]::Combine($run.DataDir, 'config', 'sweepr_debug_session.log')) | Should -BeFalse
        }

        It 'Keeps standard output to the data of the command with --debug in the form <Form>' -ForEach $script:Forms {
            $run = Invoke-Router $script:Shared $Form @('uninstall', '--list', '--debug') -Environment @{ SW_TEST_MODE = 'jsondebug' }
            $run.ExitCode | Should -Be 0
            $run.Out.Trim() | Should -BeExactly '[{"name":"Example"}]'
            $run.Err | Should -Match 'Debug log'
            [System.IO.File]::Exists([System.IO.Path]::Combine($run.DataDir, 'config', 'sweepr_debug_session.log')) | Should -BeTrue
        }
    }

    Context 'the exit code (RT-14, S11)' {
        It 'Gives <Expected> for the mode <Mode> of <Command> in the form <Form>' -ForEach @(
            foreach ($form in 'File', 'Command') {
                @{ Form = $form; Command = 'clean'; Mode = 'exit5'; Expected = 5 }
                @{ Form = $form; Command = 'status'; Mode = 'native7'; Expected = 7 }
                @{ Form = $form; Command = 'update'; Mode = 'fail1'; Expected = 1 }
                @{ Form = $form; Command = 'remove'; Mode = 'fail1'; Expected = 1 }
                @{ Form = $form; Command = 'update'; Mode = 'tolerated'; Expected = 0 }
                @{ Form = $form; Command = 'features'; Mode = 'lastfeature'; Expected = 0 }
                @{ Form = $form; Command = 'clean'; Mode = ''; Expected = 0 }
            }
        ) {
            $env2 = @{}
            if ($Mode -ne '') { $env2['SW_TEST_MODE'] = $Mode }
            $run = Invoke-Router $script:Shared $Form @($Command) -Environment $env2
            $run.ExitCode | Should -Be $Expected
            $run.Out | Should -Match "RAN:$Command"
            if ($Mode -eq 'fail1') { $run.Out | Should -Match 'FAILING' }
        }

        It 'Gives exit 1 and the message for an exception of the command in the form <Form>' -ForEach $script:Forms {
            $run = Invoke-Router $script:Shared $Form @('clean') -Environment @{ SW_TEST_MODE = 'throw' }
            $run.ExitCode | Should -Be 1
            $run.All | Should -Match 'boom'
        }

        It 'Gives 0 for help after an earlier failure left the code at 1' {
            $run = Invoke-Router $script:Shared 'Command' @('clean', '--help') -Prefix '$global:LASTEXITCODE = 1; '
            $run.ExitCode | Should -Be 0
            $run.Out | Should -Match 'HELP:clean'
        }

        It 'Gives 0 for a successful command after an earlier failure left the code at 3' {
            $run = Invoke-Router $script:Shared 'Command' @('clean') -Prefix '$global:LASTEXITCODE = 3; '
            $run.ExitCode | Should -Be 0
        }

        It 'Never gives 0 for exit 5 in the form <Form>' -ForEach $script:Forms {
            (Invoke-Router $script:Shared $Form @('clean') -Environment @{ SW_TEST_MODE = 'exit5' }).ExitCode | Should -Not -Be 0
        }
    }

    Context 'version and help (RT-18, RT-19, S10)' {
        It 'Shows the six version lines and gives 0 in the form <Form>' -ForEach $script:Forms {
            $run = Invoke-Router $script:Shared $Form @('--version')
            $run.ExitCode | Should -Be 0
            $lines = @(Get-Lines $run.Out | ForEach-Object { $_.Trim() })
            $lines[0] | Should -Match '^Sweepr version 9\.8\.7$'
            ($lines -join "`n") | Should -Match '(?m)^Architecture: \S+'
            ($lines -join "`n") | Should -Match '(?m)^Install: (Source|Portable|winget|Scoop|Copy)'
            ($lines -join "`n") | Should -Match '(?m)^Disk Free: '
            ($lines -join "`n") | Should -Match '(?m)^PowerShell: \d'
            ($lines -join "`n") | Should -Match '(?m)^Windows: '
        }

        It 'Shows the help of the router and gives 0 in the form <Form>: <Word>' -ForEach @(
            foreach ($form in 'File', 'Command') {
                @{ Form = $form; Word = '--help' }
                @{ Form = $form; Word = '-h' }
                @{ Form = $form; Word = '--showhelp' }
            }
        ) {
            $run = Invoke-Router $script:Shared $Form @($Word)
            $run.ExitCode | Should -Be 0
            $run.Out | Should -Match 'COMMANDS'
            $run.Out | Should -Match 'sw uninstall --dry-run'
            $run.Out | Should -Match 'sw features --restore'
            $run.Out | Should -Match 'sw check --report'
            $run.Out | Should -Not -Match '(?i)inspect'
            $run.Out | Should -Match ([regex]::Escape('https://github.com/brummilab/sweepr'))
        }

        It 'Creates no data folder for help, version and a rejection in the form <Form>' -ForEach $script:Forms {
            foreach ($words in @('nonsense'), @('clean', '--bogus')) {
                $run = Invoke-Router $script:Shared $Form $words
                $run.ExitCode | Should -Be 2 -Because ($words -join ' ')
                [System.IO.Directory]::Exists($run.DataDir) | Should -BeFalse -Because ($words -join ' ')
            }
        }

        It 'Creates the data folder for a command in the form <Form>' -ForEach $script:Forms {
            $run = Invoke-Router $script:Shared $Form @('clean', '--dry-run')
            [System.IO.Directory]::Exists([System.IO.Path]::Combine($run.DataDir, 'config')) | Should -BeTrue
            [System.IO.Directory]::Exists([System.IO.Path]::Combine($run.DataDir, 'cache')) | Should -BeTrue
        }
    }

    Context 'the menu without a console (RT-20)' {
        It 'Draws the menu, then ends with a message and exit 1 and does not hang, with the words <Words> in the form <Form>' -ForEach @(
            @{ Form = 'File'; Words = @() }
            @{ Form = 'Command'; Words = @('') }
            @{ Form = 'Command'; Words = @() }
        ) {
            $run = Invoke-Router $script:Shared $Form $Words
            $run.ExitCode | Should -Be 1
            $run.All | Should -Match 'Free up disk space'
            $run.All | Should -Match 'Q Quit'
            @(Get-Lines $run.Err).Count + @(Get-Lines $run.Out).Count | Should -BeGreaterThan 8
        }
    }

    Context 'the data folder (RT-16, S4)' {
        It 'Uses the data folder of a portable installation, creates it, and touches nothing in the profile, in the form <Form>' -ForEach $script:Forms {
            $install = New-ProcInstall -Portable
            $run = Invoke-Router $install $Form @('clean', '--dry-run') -KeepData
            $run.ExitCode | Should -Be 0
            [System.IO.Directory]::Exists([System.IO.Path]::Combine($install.Root, 'data', 'config')) | Should -BeTrue
            [System.IO.Directory]::Exists([System.IO.Path]::Combine($install.Root, 'data', 'cache')) | Should -BeTrue
            @(Get-Listing $install.Home | Where-Object { $_ -match '(?i)sweepr|[\\/]\.config|[\\/]\.cache[\\/]sweepr' }).Count | Should -Be 0
        }

        It 'Stops with the message of the check, exit 1 and nothing in the profile when the portable data folder cannot be written, in the form <Form>' -ForEach $script:Forms {
            $install = New-ProcInstall -Portable
            [System.IO.File]::WriteAllText([System.IO.Path]::Combine($install.Root, 'data'), 'a file where the folder should be')
            $run = Invoke-Router $install $Form @('clean', '--dry-run') -KeepData
            $run.ExitCode | Should -Be 1
            $run.All | Should -Match 'Sweepr data folder is not writable: '
            $run.All | Should -Match ([regex]::Escape('does not fall back to your user profile.'))
            $run.Out | Should -Not -Match 'RAN:'
            @(Get-Listing $install.Home | Where-Object { $_ -match '(?i)sweepr|[\\/]\.config|[\\/]\.cache[\\/]sweepr' }).Count | Should -Be 0
        }

        It 'Shows the version and the help of a portable installation whose data folder cannot be written, with exit 0, in the form <Form>' -ForEach $script:Forms {
            $install = New-ProcInstall -Portable
            [System.IO.File]::WriteAllText([System.IO.Path]::Combine($install.Root, 'data'), 'a file where the folder should be')
            $run = Invoke-Router $install $Form @('--version') -KeepData
            $run.ExitCode | Should -Be 0
            $run.Out | Should -Match 'Sweepr version'
            $run = Invoke-Router $install $Form @('--help') -KeepData
            $run.ExitCode | Should -Be 0
        }

        It 'Gives the command the trimmed override folder in the form <Form>' -ForEach $script:Forms {
            $folder = Join-Path $script:Shared.Parent ('override-' + [guid]::NewGuid().ToString('N'))
            $run = Invoke-Router $script:Shared $Form @('clean', '--dry-run') -DataDir "  $folder  "
            $run.ExitCode | Should -Be 0
            [System.IO.Directory]::Exists([System.IO.Path]::Combine($folder, 'config')) | Should -BeTrue
        }
    }

    Context 'the start of the file (RT-2)' {
        It 'Ends with exit 1 when the VERSION file cannot be read, in the form <Form>' -ForEach $script:Forms {
            $install = New-ProcInstall
            Remove-Item -LiteralPath (Join-Path $install.Root 'VERSION') -Force
            [void][System.IO.Directory]::CreateDirectory((Join-Path $install.Root 'VERSION'))
            $run = Invoke-Router $install $Form @('--version')
            $run.ExitCode | Should -Be 1
            $run.All | Should -Match '(?i)version'
        }

        It 'Reads the version from the file of its own folder, not from the working directory, in the form <Form>' -ForEach $script:Forms {
            $run = Invoke-Router $script:Shared $Form @('--version')
            $run.Out | Should -Match 'Sweepr version 9\.8\.7'
        }
    }

    Context 'an installation folder with unusual characters (RT-11)' {
        It 'Runs the command in a folder called <Folder> in the form <Form>' -ForEach @(
            foreach ($form in 'File', 'Command') {
                @{ Form = $form; Folder = 'Tools [USB]\sweepr' }
                @{ Form = $form; Folder = "Bob's tools! & files" }
                @{ Form = $form; Folder = 'a b (x86) [1]' }
            }
        ) {
            $install = New-ProcInstall -Name $Folder.Replace('\', [string][System.IO.Path]::DirectorySeparatorChar)
            $run = Invoke-Router $install $Form @('clean', '--help')
            $run.ExitCode | Should -Be 0
            $run.Out | Should -Match 'HELP:clean'
            $run.All | Should -Not -Match 'Unknown command'
            $run = Invoke-Router $install $Form @('clean', '--dry-run')
            $run.ExitCode | Should -Be 0
            Get-Value $run 'BOUND' | Should -BeExactly 'DryRun'
        }
    }

    Context 'clean output of runs that machines read (RT-22)' {
        It 'Gives standard output only the data of the command, also with --debug, in the form <Form>: <Words>' -ForEach @(
            foreach ($form in 'File', 'Command') {
                @{ Form = $form; Words = @('status', '--json') }
                @{ Form = $form; Words = @('analyze', '--json') }
                @{ Form = $form; Words = @('uninstall', '--list') }
            }
        ) {
            $run = Invoke-Router $script:Shared $Form $Words -Environment @{ SW_TEST_MODE = 'json' }
            $run.ExitCode | Should -Be 0
            $run.Out.Trim() | Should -BeExactly '{"example":1}'
        }
    }
}
