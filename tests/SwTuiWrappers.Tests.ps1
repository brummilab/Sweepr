# Sweepr - tests for bin\status.ps1 and bin\analyze.ps1, the thin starters of the two native programs.
#
# The rule numbers in the test names (WS- and WA-) number the rules of the starters; each testable rule
# has at least one test. The last part runs both starters through the router (RT-9 and RT-14 meet WS-3
# and WA-5 there).
#
# Method: every run is a child PowerShell (the one that runs the tests) on a copy of the starter in a
# fake installation root in $TestDrive. The root holds the real lib\core, except for tui_binaries.ps1,
# which is a fixture. The fixture defines only Resolve-SwTuiBinary with the four parameters Name,
# WindowsDir, DestinationPath and SourcePath (a call with any other parameter fails), records every call
# and the two environment variables, and returns the path of a stand-in program (a shell script on
# Linux, a .cmd file on Windows) that prints ARGS=, TARGET= (SWEEPR_ANALYZE_PATH) and DEBUG=
# (SWEEPR_DEBUG) and exits with FIXTURE_EXIT. Nothing real is touched: no network, no real program, no
# profile (USERPROFILE and SWEEPR_DATA_DIR point into $TestDrive).
#
# Platform notes:
#   - Tests marked [W] describe a Windows fact and are meant to fail on Linux where it does not hold.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    $script:IsWindowsHost = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:IsWin = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
    $script:Pwsh = (Get-Process -Id $PID).Path
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)

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
    function script:Get-NormalPath([string]$Path) { return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/') }

    # Runs a child PowerShell with the given command-line text and environment.
    function script:Invoke-Process {
        param([string]$Arguments, [hashtable]$Environment = @{}, [string[]]$RemoveEnvironment = @(), [string]$WorkingDirectory = $TestDrive)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:Pwsh
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.WorkingDirectory = $WorkingDirectory
        foreach ($name in $RemoveEnvironment) { if ($psi.EnvironmentVariables.ContainsKey($name)) { $psi.EnvironmentVariables.Remove($name) } }
        foreach ($name in $Environment.Keys) { $psi.EnvironmentVariables[$name] = [string]$Environment[$name] }
        $process = [System.Diagnostics.Process]::Start($psi)
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { $process.Kill(); throw 'child PowerShell timed out' }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Out = $stdout.Result; Err = (Get-ChildStderr $stderr.Result) }
    }

    # A stand-in for a native program: see the header.
    function script:New-Program([string]$Dir) {
        [void][System.IO.Directory]::CreateDirectory($Dir)
        if ($script:IsWin) {
            $path = [System.IO.Path]::Combine($Dir, 'prog.cmd')
            $text = "@echo off`r`necho ARGS=%*`r`nif defined SWEEPR_ANALYZE_PATH (echo TARGET=%SWEEPR_ANALYZE_PATH%) else (echo TARGET=NOTSET)`r`n" +
                "if defined SWEEPR_DEBUG (echo DEBUG=%SWEEPR_DEBUG%) else (echo DEBUG=NOTSET)`r`nif not defined FIXTURE_EXIT set FIXTURE_EXIT=0`r`nexit /b %FIXTURE_EXIT%`r`n"
            [System.IO.File]::WriteAllText($path, $text, [System.Text.Encoding]::ASCII)
        }
        else {
            $path = [System.IO.Path]::Combine($Dir, 'prog')
            $text = @'
#!/bin/sh
printf 'ARGS=%s\n' "$*"
for a in "$@"; do printf 'ARG=%s\n' "$a"; done
if [ -n "${SWEEPR_ANALYZE_PATH+x}" ]; then printf 'TARGET=%s\n' "$SWEEPR_ANALYZE_PATH"; else printf 'TARGET=NOTSET\n'; fi
if [ -n "${SWEEPR_DEBUG+x}" ]; then printf 'DEBUG=%s\n' "$SWEEPR_DEBUG"; else printf 'DEBUG=NOTSET\n'; fi
exit "${FIXTURE_EXIT:-0}"
'@
            [System.IO.File]::WriteAllText($path, ($text -replace "`r`n", "`n") + "`n", $script:Utf8)
            & chmod 755 $path
        }
        return $path
    }

    $script:FixtureTui = @'
# Test fixture in place of tui_binaries.ps1.
function Resolve-SwTuiBinary {
    param([string]$Name, [string]$WindowsDir, [string]$DestinationPath, [string]$SourcePath)
    if ($env:SWEEPR_FIXTURE_LOG) {
        $entry = [ordered]@{
            Name            = $Name
            WindowsDir      = $WindowsDir
            DestinationPath = $DestinationPath
            SourcePath      = $SourcePath
            AnalyzePath     = $env:SWEEPR_ANALYZE_PATH
            Debug           = $env:SWEEPR_DEBUG
        }
        [System.IO.File]::AppendAllText($env:SWEEPR_FIXTURE_LOG, ((ConvertTo-Json -InputObject $entry -Compress) + "`n"))
    }
    if ($env:SWEEPR_FIXTURE_RESOLVE -eq 'null') { return $null }
    return $env:SWEEPR_FIXTURE_PROGRAM
}

function Write-SwTuiStatus {
    param([Parameter(Position = 0)][string]$Message, [string]$Color = 'Gray')
    [Console]::Error.WriteLine($Message)
}
'@

    # A fake installation: real starters and lib\core, the fixture instead of tui_binaries.ps1, a program.
    function script:New-Install {
        param([string]$Name = 'sweepr', [switch]$WithRouter, [string]$ProgramDirName = 'program')
        $parent = New-Dir (Join-Path $TestDrive ('w-' + [guid]::NewGuid().ToString('N')))
        $root = New-Dir ([System.IO.Path]::Combine($parent, $Name))
        $bin = New-Dir (Join-Path $root 'bin')
        $core = New-Dir ([System.IO.Path]::Combine($root, 'lib', 'core'))
        foreach ($file in 'status.ps1', 'analyze.ps1') { Copy-Item -LiteralPath (Join-Path (Join-Path $script:RepoRoot 'bin') $file) -Destination $bin }
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path (Join-Path $script:RepoRoot 'lib') 'core') -File) { Copy-Item -LiteralPath $file.FullName -Destination $core }
        [System.IO.File]::WriteAllText((Join-Path $core 'tui_binaries.ps1'), $script:FixtureTui, $script:Utf8)
        [System.IO.File]::WriteAllText((Join-Path $root 'VERSION'), "9.8.7`n", $script:Utf8)
        if ($WithRouter) { Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'sweepr.ps1') -Destination $root }
        $program = New-Program (Join-Path $parent $ProgramDirName)
        return [pscustomobject]@{
            Root    = $root
            Bin     = $bin
            Parent  = $parent
            Program = $program
            Log     = (Join-Path $parent 'fixture.log')
            Data    = (Join-Path $parent 'data')
            Home    = (New-Dir (Join-Path $parent 'home'))
        }
    }
    function script:Get-FixtureCalls($Install) {
        if (-not [System.IO.File]::Exists($Install.Log)) { return @() }
        return @([System.IO.File]::ReadAllLines($Install.Log) | Where-Object { $_.Trim() -ne '' } | ForEach-Object { $_ | ConvertFrom-Json })
    }
    function script:Get-ProcessEnvironment($Install, [hashtable]$Extra = @{}) {
        $environment = @{
            USERPROFILE            = $Install.Home
            HOME                   = $Install.Home
            SWEEPR_DATA_DIR        = $Install.Data
            SWEEPR_NO_OPLOG        = '1'
            SWEEPR_FIXTURE_LOG     = $Install.Log
            SWEEPR_FIXTURE_PROGRAM = $Install.Program
        }
        foreach ($name in $Extra.Keys) { $environment[$name] = $Extra[$name] }
        return $environment
    }
    $script:Unset = @('SWEEPR_ANALYZE_PATH', 'SWEEPR_DEBUG', 'SWEEPR_DRY_RUN', 'FIXTURE_EXIT', 'SWEEPR_FIXTURE_RESOLVE', '_SWEEPR_OPLOG_RUN_COMMAND', '_SWEEPR_OPLOG_RUN_ID')

    # The starter run with -File and PowerShell parameter names.
    function script:Invoke-Starter {
        param($Install, [string]$Script, [string[]]$Arguments = @(), [hashtable]$Environment = @{})
        $remove = @($script:Unset | Where-Object { -not $Environment.ContainsKey($_) })
        $line = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (ConvertTo-WinArgument (Join-Path $Install.Bin "$Script.ps1"))
        foreach ($argument in $Arguments) { $line += ' ' + (ConvertTo-WinArgument $argument) }
        return Invoke-Process -Arguments $line -Environment (Get-ProcessEnvironment $Install $Environment) -RemoveEnvironment $remove
    }
    # The starter run as a command with text before and after the call (to look at the session).
    function script:Invoke-StarterCommand {
        param($Install, [string]$Script, [string]$Call, [string]$After = '', [hashtable]$Environment = @{})
        $remove = @($script:Unset | Where-Object { -not $Environment.ContainsKey($_) })
        $path = ConvertTo-TestLiteral (Join-Path $Install.Bin "$Script.ps1")
        $text = $Call.Replace('{SCRIPT}', $path)
        if ($After -ne '') { $text += "; $After" }
        $text += '; exit $LASTEXITCODE'
        $line = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command ' + (ConvertTo-WinArgument $text)
        return Invoke-Process -Arguments $line -Environment (Get-ProcessEnvironment $Install $Environment) -RemoveEnvironment $remove
    }
    $script:AfterEnvironment = "'AFTER=[' + `$env:SWEEPR_ANALYZE_PATH + ']'; 'AFTERDEBUG=[' + `$env:SWEEPR_DEBUG + ']'"
    function script:Get-Value([string]$Out, [string]$Key) {
        foreach ($line in (Get-Lines $Out)) { if ($line.StartsWith($Key + '=')) { return $line.Substring($Key.Length + 1) } }
        return $null
    }

    # The router run in the two forms of the launchers.
    function script:Invoke-Router {
        param($Install, [string]$Form, [string[]]$Words, [hashtable]$Environment = @{})
        $remove = @($script:Unset | Where-Object { -not $Environment.ContainsKey($_) })
        $router = Join-Path $Install.Root 'sweepr.ps1'
        if ($Form -eq 'File') {
            $line = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (ConvertTo-WinArgument $router)
            foreach ($word in $Words) { $line += ' ' + (ConvertTo-WinArgument $word) }
        }
        else {
            $literals = (@($Words | ForEach-Object { ConvertTo-TestLiteral $_ }) -join ' ')
            $text = "& $(ConvertTo-TestLiteral $router) $literals; exit `$LASTEXITCODE"
            $line = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command ' + (ConvertTo-WinArgument $text)
        }
        return Invoke-Process -Arguments $line -Environment (Get-ProcessEnvironment $Install $Environment) -RemoveEnvironment $remove
    }
}

Describe 'Starter parameters (WS-1, WA-1)' {
    BeforeAll {
        $script:StatusCommand = Get-Command -Name (Join-Path (Join-Path $script:RepoRoot 'bin') 'status.ps1') -CommandType ExternalScript
        $script:AnalyzeCommand = Get-Command -Name (Join-Path (Join-Path $script:RepoRoot 'bin') 'analyze.ps1') -CommandType ExternalScript
        function script:Get-ExplicitPositions($Command) {
            $positions = @()
            foreach ($parameter in $Command.Parameters.Values) {
                foreach ($attribute in $parameter.Attributes) {
                    if ($attribute -is [System.Management.Automation.ParameterAttribute] -and $attribute.Position -ge 0) { $positions += [pscustomobject]@{ Name = $parameter.Name; Position = $attribute.Position } }
                }
            }
            return $positions
        }
    }

    It 'Gives status the parameters ShowHelp (alias h), Json, Watch and Interval as a string' {
        $parameters = $script:StatusCommand.Parameters
        foreach ($name in 'ShowHelp', 'Json', 'Watch', 'Interval') { $parameters.ContainsKey($name) | Should -BeTrue -Because $name }
        $parameters['ShowHelp'].Aliases | Should -Contain 'h'
        $parameters['ShowHelp'].ParameterType | Should -Be ([switch])
        $parameters['Json'].ParameterType | Should -Be ([switch])
        $parameters['Watch'].ParameterType | Should -Be ([switch])
        $parameters['Interval'].ParameterType | Should -Be ([string])
    }

    It 'Gives status no positional parameter and no DebugMode' {
        @(Get-ExplicitPositions $script:StatusCommand).Count | Should -Be 0
        $script:StatusCommand.Parameters.ContainsKey('DebugMode') | Should -BeFalse
    }

    It 'Gives analyze the parameters Path (string, position 0), ShowHelp (alias h), Json and DebugMode (alias d)' {
        $parameters = $script:AnalyzeCommand.Parameters
        foreach ($name in 'Path', 'ShowHelp', 'Json', 'DebugMode') { $parameters.ContainsKey($name) | Should -BeTrue -Because $name }
        $parameters['Path'].ParameterType | Should -Be ([string])
        @(Get-ExplicitPositions $script:AnalyzeCommand | Where-Object { $_.Name -eq 'Path' })[0].Position | Should -Be 0
        @(Get-ExplicitPositions $script:AnalyzeCommand).Count | Should -Be 1
        $parameters['ShowHelp'].Aliases | Should -Contain 'h'
        $parameters['DebugMode'].Aliases | Should -Contain 'd'
        $parameters['Json'].ParameterType | Should -Be ([switch])
    }

    It 'Declares [CmdletBinding()] in <Name>' -ForEach @(
        @{ Name = 'status' }
        @{ Name = 'analyze' }
    ) {
        $command = Get-Command -Name (Join-Path (Join-Path $script:RepoRoot 'bin') "$Name.ps1") -CommandType ExternalScript
        $command.Parameters.ContainsKey('Verbose') | Should -BeTrue
    }

    It 'Declares no alias debug in <Name>' -ForEach @(
        @{ Name = 'status' }
        @{ Name = 'analyze' }
    ) {
        $command = Get-Command -Name (Join-Path (Join-Path $script:RepoRoot 'bin') "$Name.ps1") -CommandType ExternalScript
        foreach ($parameter in $command.Parameters.Values) {
            if ($parameter.Name -in @('Debug', 'Verbose', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable', 'ProgressAction')) { continue }
            $parameter.Aliases | Should -Not -Contain 'debug' -Because $parameter.Name
        }
    }
}

Describe 'sw status starter' {
    Context 'help (WS-2)' {
        BeforeAll {
            $script:Install = New-Install
            $script:Help = Invoke-Starter -Install $script:Install -Script 'status' -Arguments @('-ShowHelp') -Environment @{ FIXTURE_EXIT = '9' }
            $script:HelpText = $script:Help.Out
        }

        It 'Returns normally with exit code 0 and writes nothing to the error stream' {
            $script:Help.ExitCode | Should -Be 0
            $script:Help.Err | Should -BeNullOrEmpty
        }

        It 'Neither provides nor starts the program' {
            @(Get-FixtureCalls $script:Install).Count | Should -Be 0
            $script:HelpText | Should -Not -Match 'ARGS='
        }

        It 'Shows the usage, the options and the keys' {
            $script:HelpText | Should -CMatch 'Usage'
            $script:HelpText | Should -Match ([regex]::Escape('sw status [options]'))
            foreach ($text in '--json', '--watch', '--interval=<', '--help') { $script:HelpText | Should -Match ([regex]::Escape($text)) -Because $text }
            $script:HelpText | Should -Match '(?<![\w-])c(?![\w-])'
            $script:HelpText | Should -Match '(?i)(?<![\w-])q(?![\w-])'
            $script:HelpText | Should -Match '(?i)esc'
        }


        It 'Does not mention the file names of the program, the key k, battery, proxy or alerts' {
            $script:HelpText | Should -Not -Match '(?i)status\.exe'
            $script:HelpText | Should -Not -Match '(?i)status-windows-x64'
            $script:HelpText | Should -Not -Match '(?i)(?<![\w-])k(?![\w-])'
            $script:HelpText | Should -Not -Match '(?i)batter'
            $script:HelpText | Should -Not -Match '(?i)proxy'
            $script:HelpText | Should -Not -Match '(?i)alert|alarm'
            $script:HelpText | Should -Not -Match '(?i)health'
        }

        It 'Shows the help for -h as well' {
            $run = Invoke-Starter -Install $script:Install -Script 'status' -Arguments @('-h')
            $run.ExitCode | Should -Be 0
            $run.Out | Should -Match 'Usage'
            @(Get-FixtureCalls $script:Install).Count | Should -Be 0
        }
    }

    Context 'the call of the program (WS-3)' {
        BeforeAll {
            $script:Install = New-Install
        }
        BeforeEach {
            if ([System.IO.File]::Exists($script:Install.Log)) { [System.IO.File]::Delete($script:Install.Log) }
        }

        It 'Asks for the program with exactly the four named parameters, for this installation' {
            $run = Invoke-Starter -Install $script:Install -Script 'status'
            $run.ExitCode | Should -Be 0
            $calls = @(Get-FixtureCalls $script:Install)
            $calls.Count | Should -Be 1
            $calls[0].Name | Should -BeExactly 'status'
            Get-NormalPath $calls[0].WindowsDir | Should -BeExactly (Get-NormalPath $script:Install.Root)
            Get-NormalPath $calls[0].DestinationPath | Should -BeExactly (Get-NormalPath ([System.IO.Path]::Combine($script:Install.Root, 'bin', 'status.exe')))
            $calls[0].SourcePath | Should -BeExactly './cmd/status/'
        }

        It 'Starts the program without an argument when no option is given' {
            $run = Invoke-Starter -Install $script:Install -Script 'status'
            Get-Value $run.Out 'ARGS' | Should -BeExactly ''
            if (-not $script:IsWin) { @(Get-Lines $run.Out | Where-Object { $_.StartsWith('ARG=') }).Count | Should -Be 0 }
        }

        It 'Passes --json for -Json' {
            $run = Invoke-Starter -Install $script:Install -Script 'status' -Arguments @('-Json')
            Get-Value $run.Out 'ARGS' | Should -BeExactly '--json'
        }

        It 'Passes --watch for -Watch' {
            $run = Invoke-Starter -Install $script:Install -Script 'status' -Arguments @('-Watch')
            Get-Value $run.Out 'ARGS' | Should -BeExactly '--watch'
        }

        It 'Passes --interval=<value> in one argument, always with an equals sign' {
            $run = Invoke-Starter -Install $script:Install -Script 'status' -Arguments @('-Interval', '1s')
            Get-Value $run.Out 'ARGS' | Should -BeExactly '--interval=1s'
        }

        It 'Passes the options in the order --json, --watch, --interval' {
            $run = Invoke-Starter -Install $script:Install -Script 'status' -Arguments @('-Interval', '2s', '-Watch', '-Json')
            Get-Value $run.Out 'ARGS' | Should -BeExactly '--json --watch --interval=2s'
        }

        It 'Passes an interval with a blank as one argument' {
            $run = Invoke-Starter -Install $script:Install -Script 'status' -Arguments @('-Interval', '2 s')
            if ($script:IsWin) { Get-Value $run.Out 'ARGS' | Should -Match '^"?--interval=2 s"?$' }
            else {
                @(Get-Lines $run.Out | Where-Object { $_.StartsWith('ARG=') }) | Should -Be @('ARG=--interval=2 s')
            }
        }

        It 'Treats the interval as data: a value with shell characters stays one argument' {
            $run = Invoke-Starter -Install $script:Install -Script 'status' -Arguments @('-Interval', 'a; b & c | d')
            $run.ExitCode | Should -Be 0
            if (-not $script:IsWin) { @(Get-Lines $run.Out | Where-Object { $_.StartsWith('ARG=') }) | Should -Be @('ARG=--interval=a; b & c | d') }
        }

        It 'Passes no --interval for an empty interval' {
            $run = Invoke-StarterCommand -Install $script:Install -Script 'status' -Call "& {SCRIPT} -Interval ''"
            $run.ExitCode | Should -Be 0
            Get-Value $run.Out 'ARGS' | Should -BeExactly ''
        }

        It 'Passes no other argument than the three forms' {
            $run = Invoke-Starter -Install $script:Install -Script 'status' -Arguments @('-Json', '-Watch', '-Interval', '5s')
            Get-Value $run.Out 'ARGS' | Should -BeExactly '--json --watch --interval=5s'
        }

        It 'Ends with the exit code of the program: <Code>' -ForEach @(
            @{ Code = 0 }
            @{ Code = 1 }
            @{ Code = 7 }
            @{ Code = 3 }
        ) {
            $run = Invoke-Starter -Install $script:Install -Script 'status' -Environment @{ FIXTURE_EXIT = [string]$Code }
            $run.ExitCode | Should -Be $Code
            $run.Out | Should -Match 'ARGS=' -Because 'the program ran'
        }

        It 'Writes nothing to standard output but the program output' {
            $run = Invoke-Starter -Install $script:Install -Script 'status' -Arguments @('-Json')
            $lines = @(Get-Lines $run.Out)
            $lines.Count | Should -BeGreaterThan 0
            @($lines | Where-Object { $_ -notmatch '^(ARGS|ARG|TARGET|DEBUG)=' }).Count | Should -Be 0
            $run.Err | Should -BeNullOrEmpty
        }

        It 'Reports a program that cannot be provided: exit 1, two hints on standard error, nothing on standard output' {
            $run = Invoke-Starter -Install $script:Install -Script 'status' -Arguments @('-Json') -Environment @{ SWEEPR_FIXTURE_RESOLVE = 'null' }
            $run.ExitCode | Should -Be 1
            $run.Out.Trim() | Should -BeNullOrEmpty
            $hints = @(Get-Lines $run.Err)
            $hints.Count | Should -Be 2
            $run.Err | Should -Match '(?i)network|internet|connection'
            $run.Err | Should -Match '\bGo\b'
        }

        It 'Does not start the program when it cannot be provided' {
            $marker = Join-Path $script:Install.Parent 'ran.txt'
            $run = Invoke-Starter -Install $script:Install -Script 'status' -Environment @{ SWEEPR_FIXTURE_RESOLVE = 'null'; FIXTURE_EXIT = '0' }
            $run.ExitCode | Should -Be 1
            @(Get-FixtureCalls $script:Install).Count | Should -Be 1
            $run.Out | Should -Not -Match 'ARGS='
        }

        It 'Loads tui_binaries.ps1 and starts the program from paths with brackets, quotes, blanks and an ampersand' {
            $install = New-Install -Name "Tools [x64] it's & more" -ProgramDirName 'prog dir & [1]'
            $run = Invoke-Starter -Install $install -Script 'status' -Arguments @('-Json')
            $run.ExitCode | Should -Be 0
            Get-Value $run.Out 'ARGS' | Should -BeExactly '--json'
            $calls = @(Get-FixtureCalls $install)
            $calls.Count | Should -Be 1
            Get-NormalPath $calls[0].WindowsDir | Should -BeExactly (Get-NormalPath $install.Root)
        }
    }
}

Describe 'sw analyze starter' {
    Context 'help (WA-2)' {
        BeforeAll {
            $script:Install = New-Install
            $script:Help = Invoke-StarterCommand -Install $script:Install -Script 'analyze' -Call '& {SCRIPT} -ShowHelp -Path ''D:\scan'' -DebugMode' -After $script:AfterEnvironment -Environment @{ SWEEPR_ANALYZE_PATH = 'C:\alt'; SWEEPR_DEBUG = 'keep'; FIXTURE_EXIT = '9' }
            $script:HelpText = $script:Help.Out
        }

        It 'Returns normally with exit code 0 and writes nothing to the error stream' {
            $script:Help.ExitCode | Should -Be 0
            $script:Help.Err | Should -BeNullOrEmpty
        }

        It 'Neither provides nor starts the program and does not change the environment' {
            @(Get-FixtureCalls $script:Install).Count | Should -Be 0
            $script:HelpText | Should -Not -Match 'ARGS='
            Get-Value $script:HelpText 'AFTER' | Should -BeExactly '[C:\alt]'
            Get-Value $script:HelpText 'AFTERDEBUG' | Should -BeExactly '[keep]'
        }

        It 'Shows the usage, the title and the options' {
            $script:HelpText | Should -CMatch 'Usage'
            $script:HelpText | Should -Match ([regex]::Escape('sw analyze [options] [path]'))
            $script:HelpText | Should -CMatch 'Disk explorer'
            foreach ($text in '--json', '--debug', '--help') { $script:HelpText | Should -Match ([regex]::Escape($text)) -Because $text }
        }


        It 'Names the key R' {
            $script:HelpText | Should -CMatch '(?m)^\s+R\s+\S'
        }

        It 'Lists the keys: <Pattern>' -ForEach @(
            @{ Pattern = '(?i)enter' }
            @{ Pattern = '(?i)esc' }
            @{ Pattern = '(?i)backspace' }
            @{ Pattern = '(?i)space' }
            @{ Pattern = '(?i)del' }
            @{ Pattern = '(?i)pg\s?up|page\s?up' }
            @{ Pattern = '(?i)pg\s?dn|page\s?down' }
            @{ Pattern = '(?<![\w-])T(?![\w-])' }
            @{ Pattern = '(?<![\w-])R(?![\w-])' }
            @{ Pattern = '(?<![\w-])Q(?![\w-])' }
        ) {
            $script:HelpText | Should -CMatch $Pattern
        }

        It 'Does not list the keys and names that no longer exist: <Pattern>' -ForEach @(
            @{ Pattern = '(?<![\w-])O(?![\w-])' }
            @{ Pattern = '(?<![\w-])F(?![\w-])' }
            @{ Pattern = '(?<![\w-])P(?![\w-])' }
            @{ Pattern = '(?<![\w-])S(?![\w-])' }
            @{ Pattern = '(?<![\w-])h(?![\w-])' }
            @{ Pattern = '(?<![\w-])j(?![\w-])' }
            @{ Pattern = '(?<![\w-])k(?![\w-])' }
            @{ Pattern = '(?<![\w-])l(?![\w-])' }
            @{ Pattern = '--path' }
            @{ Pattern = '(?i)analyze\.exe' }
            @{ Pattern = '(?i)analyze-windows-x64' }
        ) {
            $script:HelpText | Should -Not -CMatch $Pattern
        }
    }

    Context 'the call of the program (WA-3, WA-5)' {
        BeforeAll {
            $script:Install = New-Install
        }
        BeforeEach {
            if ([System.IO.File]::Exists($script:Install.Log)) { [System.IO.File]::Delete($script:Install.Log) }
        }

        It 'Asks for the program with exactly the four named parameters, for this installation' {
            $run = Invoke-Starter -Install $script:Install -Script 'analyze'
            $run.ExitCode | Should -Be 0
            $calls = @(Get-FixtureCalls $script:Install)
            $calls.Count | Should -Be 1
            $calls[0].Name | Should -BeExactly 'analyze'
            Get-NormalPath $calls[0].WindowsDir | Should -BeExactly (Get-NormalPath $script:Install.Root)
            Get-NormalPath $calls[0].DestinationPath | Should -BeExactly (Get-NormalPath ([System.IO.Path]::Combine($script:Install.Root, 'bin', 'analyze.exe')))
            $calls[0].SourcePath | Should -BeExactly './cmd/analyze/'
        }

        It 'Starts the program without an argument when no option is given' {
            $run = Invoke-Starter -Install $script:Install -Script 'analyze'
            Get-Value $run.Out 'ARGS' | Should -BeExactly ''
        }

        It 'Passes only --json for -Json' {
            $run = Invoke-Starter -Install $script:Install -Script 'analyze' -Arguments @('-Json')
            Get-Value $run.Out 'ARGS' | Should -BeExactly '--json'
        }

        It 'Never passes the path as an argument: it goes into SWEEPR_ANALYZE_PATH' -ForEach @(
            @{ Arguments = @('-Path', 'D:\scan target') }
            @{ Arguments = @('D:\scan target') }
            @{ Arguments = @('-Json', '-Path', 'D:\scan target') }
        ) {
            $run = Invoke-Starter -Install $script:Install -Script 'analyze' -Arguments $Arguments
            $run.ExitCode | Should -Be 0
            $expected = ''
            if ($Arguments -contains '-Json') { $expected = '--json' }
            Get-Value $run.Out 'ARGS' | Should -BeExactly $expected
            Get-Value $run.Out 'TARGET' | Should -BeExactly 'D:\scan target'
        }

        It 'Does not cut a quote off the path' {
            $run = Invoke-Starter -Install $script:Install -Script 'analyze' -Arguments @('-Path', 'D:\x"y')
            Get-Value $run.Out 'TARGET' | Should -BeExactly 'D:\x"y'
        }

        It 'Ends with the exit code of the program: <Code>' -ForEach @(
            @{ Code = 0 }
            @{ Code = 1 }
            @{ Code = 7 }
        ) {
            $run = Invoke-Starter -Install $script:Install -Script 'analyze' -Environment @{ FIXTURE_EXIT = [string]$Code }
            $run.ExitCode | Should -Be $Code
            $run.Out | Should -Match 'ARGS=' -Because 'the program ran'
        }

        It 'Reports a program that cannot be provided: exit 1, two hints on standard error, nothing on standard output' {
            $run = Invoke-Starter -Install $script:Install -Script 'analyze' -Arguments @('-Json') -Environment @{ SWEEPR_FIXTURE_RESOLVE = 'null' }
            $run.ExitCode | Should -Be 1
            $run.Out.Trim() | Should -BeNullOrEmpty
            @(Get-Lines $run.Err).Count | Should -Be 2
            $run.Err | Should -Match '\bGo\b'
        }

        It 'Provides the program before it changes any environment variable' {
            $run = Invoke-Starter -Install $script:Install -Script 'analyze' -Arguments @('-Path', 'D:\x', '-DebugMode') -Environment @{ SWEEPR_ANALYZE_PATH = 'C:\alt'; SWEEPR_FIXTURE_RESOLVE = 'null' }
            $run.ExitCode | Should -Be 1
            $calls = @(Get-FixtureCalls $script:Install)
            $calls.Count | Should -Be 1
            $calls[0].AnalyzePath | Should -BeExactly 'C:\alt'
            $calls[0].Debug | Should -BeNullOrEmpty
        }

        It 'Provides the program before it changes any environment variable also when it succeeds' {
            $null = Invoke-Starter -Install $script:Install -Script 'analyze' -Arguments @('-Path', 'D:\x', '-DebugMode') -Environment @{ SWEEPR_ANALYZE_PATH = 'C:\alt' }
            $calls = @(Get-FixtureCalls $script:Install)
            $calls[0].AnalyzePath | Should -BeExactly 'C:\alt'
            $calls[0].Debug | Should -BeNullOrEmpty
        }
    }

    Context 'the environment of the run (WA-4, S3)' {
        BeforeAll {
            $script:Install = New-Install
        }

        It 'Sets SWEEPR_ANALYZE_PATH for the program and leaves it unset afterwards when it was unset' {
            $run = Invoke-StarterCommand -Install $script:Install -Script 'analyze' -Call '& {SCRIPT} -Path ''D:\x''' -After $script:AfterEnvironment
            Get-Value $run.Out 'TARGET' | Should -BeExactly 'D:\x'
            Get-Value $run.Out 'AFTER' | Should -BeExactly '[]'
        }

        It 'Removes an earlier SWEEPR_ANALYZE_PATH for the program when no path is given, and puts it back afterwards' {
            $run = Invoke-StarterCommand -Install $script:Install -Script 'analyze' -Call '& {SCRIPT} -Json' -After $script:AfterEnvironment -Environment @{ SWEEPR_ANALYZE_PATH = 'C:\alt' }
            Get-Value $run.Out 'TARGET' | Should -BeExactly 'NOTSET'
            Get-Value $run.Out 'AFTER' | Should -BeExactly '[C:\alt]'
        }

        It 'Removes an earlier SWEEPR_ANALYZE_PATH for the program when the path is empty, and puts it back afterwards' {
            $run = Invoke-StarterCommand -Install $script:Install -Script 'analyze' -Call '& {SCRIPT} -Path ''''' -After $script:AfterEnvironment -Environment @{ SWEEPR_ANALYZE_PATH = 'C:\alt' }
            Get-Value $run.Out 'TARGET' | Should -BeExactly 'NOTSET'
            Get-Value $run.Out 'AFTER' | Should -BeExactly '[C:\alt]'
        }

        It 'Replaces an earlier SWEEPR_ANALYZE_PATH for the program and puts it back afterwards' {
            $run = Invoke-StarterCommand -Install $script:Install -Script 'analyze' -Call '& {SCRIPT} -Path ''D:\x''' -After $script:AfterEnvironment -Environment @{ SWEEPR_ANALYZE_PATH = 'C:\alt' }
            Get-Value $run.Out 'TARGET' | Should -BeExactly 'D:\x'
            Get-Value $run.Out 'AFTER' | Should -BeExactly '[C:\alt]'
        }

        It 'Sets SWEEPR_DEBUG to 1 for -DebugMode and unsets it again afterwards' {
            $run = Invoke-StarterCommand -Install $script:Install -Script 'analyze' -Call '& {SCRIPT} -DebugMode' -After $script:AfterEnvironment
            Get-Value $run.Out 'DEBUG' | Should -BeExactly '1'
            Get-Value $run.Out 'AFTERDEBUG' | Should -BeExactly '[]'
        }

        It 'Sets SWEEPR_DEBUG to 1 for -DebugMode and puts an earlier value back afterwards' {
            $run = Invoke-StarterCommand -Install $script:Install -Script 'analyze' -Call '& {SCRIPT} -DebugMode' -After $script:AfterEnvironment -Environment @{ SWEEPR_DEBUG = 'keep' }
            Get-Value $run.Out 'DEBUG' | Should -BeExactly '1'
            Get-Value $run.Out 'AFTERDEBUG' | Should -BeExactly '[keep]'
        }

        It 'Leaves SWEEPR_DEBUG as it is without -DebugMode' {
            $run = Invoke-StarterCommand -Install $script:Install -Script 'analyze' -Call '& {SCRIPT}' -After $script:AfterEnvironment -Environment @{ SWEEPR_DEBUG = 'keep' }
            Get-Value $run.Out 'DEBUG' | Should -BeExactly 'keep'
            Get-Value $run.Out 'AFTERDEBUG' | Should -BeExactly '[keep]'
        }

        It 'Restores both variables when the program cannot be started' {
            $missing = Join-Path $script:Install.Parent 'no-such-program'
            $run = Invoke-StarterCommand -Install $script:Install -Script 'analyze' -Call "try { & {SCRIPT} -Path 'D:\x' -DebugMode } catch { 'CAUGHT' }" -After $script:AfterEnvironment -Environment @{ SWEEPR_FIXTURE_PROGRAM = $missing; SWEEPR_ANALYZE_PATH = 'C:\alt'; SWEEPR_DEBUG = 'keep' }
            $run.Out | Should -Match 'CAUGHT'
            Get-Value $run.Out 'AFTER' | Should -BeExactly '[C:\alt]'
            Get-Value $run.Out 'AFTERDEBUG' | Should -BeExactly '[keep]'
        }

        It 'Restores both variables, set before or not, when the program fails' {
            $run = Invoke-StarterCommand -Install $script:Install -Script 'analyze' -Call '& {SCRIPT} -Path ''D:\x'' -DebugMode' -After $script:AfterEnvironment -Environment @{ FIXTURE_EXIT = '1' }
            $run.ExitCode | Should -Be 1
            Get-Value $run.Out 'AFTER' | Should -BeExactly '[]'
            Get-Value $run.Out 'AFTERDEBUG' | Should -BeExactly '[]'
        }

        It 'Does not change or check the path: a path that does not exist reaches the program as it is' {
            $run = Invoke-Starter -Install $script:Install -Script 'analyze' -Arguments @('-Path', 'Z:\does\not\exist\..\..\x ')
            Get-Value $run.Out 'TARGET' | Should -BeExactly 'Z:\does\not\exist\..\..\x '
        }
    }
}

Describe 'The starters through the router' {
    BeforeAll {
        $script:Install = New-Install -WithRouter
    }

    It 'Passes status options to the program in the form <Form>: --watch --interval 1s' -ForEach @(
        @{ Form = 'File' }
        @{ Form = 'Command' }
    ) {
        $run = Invoke-Router -Install $script:Install -Form $Form -Words @('status', '--watch', '--interval', '1s')
        $run.ExitCode | Should -Be 0
        Get-Value $run.Out 'ARGS' | Should -BeExactly '--watch --interval=1s'
    }

    It 'Passes status --interval=<value> in the form <Form>' -ForEach @(
        @{ Form = 'File' }
        @{ Form = 'Command' }
    ) {
        $run = Invoke-Router -Install $script:Install -Form $Form -Words @('status', '--interval=2s', '--json')
        $run.ExitCode | Should -Be 0
        Get-Value $run.Out 'ARGS' | Should -BeExactly '--json --interval=2s'
    }

    It 'Returns the exit code of the program from status in the form <Form>: 7' -ForEach @(
        @{ Form = 'File' }
        @{ Form = 'Command' }
    ) {
        $run = Invoke-Router -Install $script:Install -Form $Form -Words @('status') -Environment @{ FIXTURE_EXIT = '7' }
        $run.ExitCode | Should -Be 7
    }

    It 'Passes analyze --json and the path as data in the form <Form>' -ForEach @(
        @{ Form = 'File' }
        @{ Form = 'Command' }
    ) {
        $run = Invoke-Router -Install $script:Install -Form $Form -Words @('analyze', '--json', 'D:\scan target')
        $run.ExitCode | Should -Be 0
        Get-Value $run.Out 'ARGS' | Should -BeExactly '--json'
        Get-Value $run.Out 'TARGET' | Should -BeExactly 'D:\scan target'
    }

    It 'Returns the exit code 1 of analyze for a path the program refuses, in the form <Form>' -ForEach @(
        @{ Form = 'File' }
        @{ Form = 'Command' }
    ) {
        $run = Invoke-Router -Install $script:Install -Form $Form -Words @('analyze', 'D:\missing') -Environment @{ FIXTURE_EXIT = '1' }
        $run.ExitCode | Should -Be 1
    }

    It 'Gives analyze --debug the program with SWEEPR_DEBUG=1' {
        $run = Invoke-Router -Install $script:Install -Form 'Command' -Words @('analyze', '--debug')
        $run.ExitCode | Should -Be 0
        Get-Value $run.Out 'DEBUG' | Should -BeExactly '1'
    }

    It 'Shows the help of status and analyze without providing a program' {
        foreach ($command in 'status', 'analyze') {
            $before = @(Get-FixtureCalls $script:Install).Count
            $run = Invoke-Router -Install $script:Install -Form 'File' -Words @($command, '--help')
            $run.ExitCode | Should -Be 0
            $run.Out | Should -Match 'Usage'
            @(Get-FixtureCalls $script:Install).Count | Should -Be $before
        }
    }

    It 'Rejects status --debug as an unknown option and a second word of analyze, before the program is provided' {
        $before = @(Get-FixtureCalls $script:Install).Count
        $run = Invoke-Router -Install $script:Install -Form 'File' -Words @('status', '--debug')
        $run.ExitCode | Should -Be 2
        $run = Invoke-Router -Install $script:Install -Form 'File' -Words @('analyze', 'a', 'b')
        $run.ExitCode | Should -Be 2
        @(Get-FixtureCalls $script:Install).Count | Should -Be $before
    }
}
