# Sweepr - tests for the two small changes to command scripts that the router relies on:
#   bin\update.ps1   declares [CmdletBinding()] and no alias "debug", so a stray word is an error and
#                    sw update help never starts an update (RT-9, RT-24)
#   bin\features.ps1 an entry that fails in --restore gives exit code 1, and the winget call leaves
#                    $global:LASTEXITCODE at 0 (RT-14, RT-24)
#
# The rule numbers in the test names (RT- and S) number the rules and the safety invariants of the
# router's behavior; each testable rule and invariant has at least one test.
#
# Method: the real scripts run in a child PowerShell (the one that runs the tests) in a fake installation
# in $TestDrive. The fake installation has no install.ps1 and no .git folder, so a real update cannot
# start: its first step reports that the installer is missing. For features --restore the real script runs
# with the replaced console and winget functions described below; nothing real is changed: the saved list
# of removed apps is a file in $TestDrive, winget is a function that returns a code, and there is no
# network. USERPROFILE and SWEEPR_DATA_DIR of the child point into $TestDrive.
#
# How features.ps1 is driven: the script is cut after its last function (the part after it starts the
# command). A copy runs the definitions, then a file with replacements for the console (interactive
# console, the menu that selects every row, the confirmation) and for the one function that runs winget,
# then the real start of the command and the real exit. The file lib\core\features.ps1 and every function
# that decides what is restored are the real ones. Only the winget function itself is also run for real,
# against a program called winget that returns 3.
#
# Platform notes:
#   - Tests marked [W] describe a Windows fact and are meant to fail on Linux where it does not hold.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
    $script:Pwsh = (Get-Process -Id $PID).Path
    $script:IsWin = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)

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
    function script:Remove-Ansi([string]$Text) { return [regex]::Replace($Text, '\x1b\[[0-9;?]*[A-Za-z]', '') }
    function script:Get-Lines([string]$Text) { return @($Text -split "`r?`n" | Where-Object { $_.Trim() -ne '' }) }

    $script:Unset = @('SWEEPR_DEBUG', 'SWEEPR_DRY_RUN', 'SWEEPR_ANALYZE_PATH', '_SWEEPR_OPLOG_RUN_COMMAND', '_SWEEPR_OPLOG_RUN_ID', 'FIXTURE_WINGET_CODES', 'SWEEPR_DATA_DIR')
    function script:Invoke-Process {
        param([string]$Arguments, $Install, [hashtable]$Environment = @{})
        $env2 = @{ USERPROFILE = $Install.Home; HOME = $Install.Home; SWEEPR_DATA_DIR = $Install.Data; SWEEPR_NO_OPLOG = '1' }
        foreach ($name in $Environment.Keys) { $env2[$name] = $Environment[$name] }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:Pwsh
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.WorkingDirectory = $TestDrive
        foreach ($name in @($script:Unset | Where-Object { -not $env2.ContainsKey($_) })) { if ($psi.EnvironmentVariables.ContainsKey($name)) { $psi.EnvironmentVariables.Remove($name) } }
        foreach ($name in $env2.Keys) { $psi.EnvironmentVariables[$name] = [string]$env2[$name] }
        $process = [System.Diagnostics.Process]::Start($psi)
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { $process.Kill(); throw 'child PowerShell timed out' }
        $out = Remove-Ansi $stdout.Result
        $err = Remove-Ansi (Get-ChildStderr $stderr.Result)
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Out = $out; Err = $err; All = ($out + "`n" + $err) }
    }
    function script:New-Install([string]$Name = 'sweepr', [switch]$WithRouter) {
        $parent = New-Dir (Join-Path $TestDrive ('c-' + [guid]::NewGuid().ToString('N')))
        $root = New-Dir ([System.IO.Path]::Combine($parent, $Name))
        $bin = New-Dir (Join-Path $root 'bin')
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'lib') -Destination $root -Recurse
        [System.IO.File]::WriteAllText((Join-Path $root 'VERSION'), "9.8.7`n", $script:Utf8)
        if ($WithRouter) { Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'sweepr.ps1') -Destination $root }
        return [pscustomobject]@{
            Root   = $root
            Bin    = $bin
            Parent = $parent
            Data   = (Join-Path $parent 'data')
            Home   = (New-Dir (Join-Path $parent 'home'))
            Router = (Join-Path $root 'sweepr.ps1')
        }
    }
    function script:Invoke-Router {
        param($Install, [string]$Form, [string[]]$Words)
        if ($Form -eq 'File') {
            $line = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (ConvertTo-WinArgument $Install.Router)
            foreach ($word in $Words) { $line += ' ' + (ConvertTo-WinArgument $word) }
        }
        else {
            $literals = ''
            foreach ($word in $Words) { $literals += ' ' + (ConvertTo-TestLiteral $word) }
            $text = '& ' + (ConvertTo-TestLiteral $Install.Router) + $literals + '; exit $LASTEXITCODE'
            $line = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command ' + (ConvertTo-WinArgument $text)
        }
        return (Invoke-Process -Arguments $line -Install $Install)
    }
}

Describe 'bin\update.ps1' {
    BeforeAll {
        $script:UpdateFile = Join-Path (Join-Path $script:RepoRoot 'bin') 'update.ps1'
        # No install.ps1 and no .git: a real update cannot start here.
        $script:Install = New-Install -WithRouter
        Copy-Item -LiteralPath $script:UpdateFile -Destination $script:Install.Bin
        $script:Parameters = (Get-Command -Name (Join-Path $script:Install.Bin 'update.ps1') -CommandType ExternalScript).Parameters
        $script:InstallerMessage = 'Installer not found'
    }

    It 'Declares [CmdletBinding()]' {
        $script:Parameters.ContainsKey('Verbose') | Should -BeTrue
    }

    It 'Declares DebugMode with the alias d and without the alias debug' {
        $script:Parameters.ContainsKey('DebugMode') | Should -BeTrue
        $script:Parameters['DebugMode'].Aliases | Should -Contain 'd'
        $script:Parameters['DebugMode'].Aliases | Should -Not -Contain 'debug'
    }

    It 'Declares ShowHelp with the alias h' {
        $script:Parameters['ShowHelp'].Aliases | Should -Contain 'h'
    }

    It 'Declares no parameter that takes a word' {
        $positions = @()
        foreach ($parameter in $script:Parameters.Values) {
            foreach ($attribute in $parameter.Attributes) {
                if ($attribute -is [System.Management.Automation.ParameterAttribute] -and $attribute.Position -ge 0) { $positions += $parameter.Name }
            }
        }
        $positions.Count | Should -Be 0
    }

    It 'Reports the missing installer as the first step of a real update, which the next tests rely on' {
        $line = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (ConvertTo-WinArgument (Join-Path $script:Install.Bin 'update.ps1'))
        $run = Invoke-Process -Arguments $line -Install $script:Install
        $run.ExitCode | Should -Be 1
        $run.All | Should -Match $script:InstallerMessage
    }

    It 'Rejects a stray word when it is run directly: <Word>' -ForEach @(
        @{ Word = 'help' }
        @{ Word = '/?' }
        @{ Word = 'check' }
        @{ Word = 'status' }
    ) {
        $line = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (ConvertTo-WinArgument (Join-Path $script:Install.Bin 'update.ps1')) + ' ' + (ConvertTo-WinArgument $Word)
        $run = Invoke-Process -Arguments $line -Install $script:Install
        $run.ExitCode | Should -Not -Be 0
        $run.All | Should -Not -Match $script:InstallerMessage
    }

    It 'Shows its help for -ShowHelp and changes nothing' {
        $line = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (ConvertTo-WinArgument (Join-Path $script:Install.Bin 'update.ps1')) + ' -ShowHelp'
        $run = Invoke-Process -Arguments $line -Install $script:Install
        $run.ExitCode | Should -Be 0
        $run.Out | Should -Match 'Usage'
        $run.All | Should -Not -Match $script:InstallerMessage
    }

    It 'Is not run by sw update <Word> in the form <Form>: exit 2, the message, nothing of a real update' -ForEach @(
        foreach ($form in 'File', 'Command') {
            foreach ($word in 'help', '/?', 'check', 'status') { @{ Form = $form; Word = $word } }
        }
    ) {
        $run = Invoke-Router $script:Install $Form @('update', $Word)
        $run.ExitCode | Should -Be 2
        $run.All | Should -Match ('Unexpected argument for sw update: ' + [regex]::Escape($Word))
        $run.All | Should -Match 'sw update --help'
        $run.All | Should -Not -Match $script:InstallerMessage
        $run.All | Should -Not -Match '(?i)not a git-based|git is not installed|updating source|refreshing local'
    }

    It 'Shows its help for sw update --help in the form <Form>' -ForEach @(
        @{ Form = 'File' }
        @{ Form = 'Command' }
    ) {
        $run = Invoke-Router $script:Install $Form @('update', '--help')
        $run.ExitCode | Should -Be 0
        $run.Out | Should -Match 'Usage'
        $run.All | Should -Not -Match $script:InstallerMessage
    }

    It 'Reaches the real script with sw update <Option>, which sets the debug mode, in the form <Form>' -ForEach @(
        foreach ($form in 'File', 'Command') {
            foreach ($option in '--debug', '-d', '-Debug') { @{ Form = $form; Option = $option } }
        }
    ) {
        $run = Invoke-Router $script:Install $Form @('update', $Option)
        $run.ExitCode | Should -Be 1
        $run.All | Should -Match $script:InstallerMessage
        $file = [System.IO.Path]::Combine($script:Install.Data, 'config', 'sweepr_debug_session.log')
        [System.IO.File]::Exists($file) | Should -BeTrue
        [System.IO.File]::ReadAllText($file) | Should -Match ('Command: sw update ' + [regex]::Escape($Option))
        [System.IO.File]::Delete($file)
    }

    It 'Gives the exit code of the failing real script through the router, in the form <Form>' -ForEach @(
        @{ Form = 'File' }
        @{ Form = 'Command' }
    ) {
        $run = Invoke-Router $script:Install $Form @('update')
        $run.ExitCode | Should -Be 1
        $run.All | Should -Match $script:InstallerMessage
    }
}

Describe 'bin\features.ps1 --restore' {
    BeforeAll {
        $script:FeaturesFile = Join-Path (Join-Path $script:RepoRoot 'bin') 'features.ps1'
        $script:Overrides = @'
# Test replacements, run after the definitions of features.ps1 and before the command starts.
function Test-FeaturesInteractive { return $true }
function Test-FeaturesWingetAvailable { return $true }
function Test-FeaturesAppInstalled { param($Target) return $false }
function Show-FeaturesMenu { param([object[]]$Items, [string]$Notice = '', [string]$Heading = '') return , @($Items) }
function Read-Host { param($Prompt) return 'y' }
$script:FixtureWingetCall = 0
function Invoke-FeaturesWinget {
    param([string[]]$Arguments)
    $codes = @($env:FIXTURE_WINGET_CODES -split ',')
    $code = [int]$codes[[Math]::Min($script:FixtureWingetCall, $codes.Count - 1)]
    $script:FixtureWingetCall++
    return $code
}
'@
        $script:SavedList = @'
{"version":1,"items":[
{"Id":"app.weather","Kind":"App","Title":"Weather","Target":"Microsoft.BingWeather_8wekyb3d8bbwe","Restore":{"Type":"Store","StoreId":"9WZDNCRFJ3Q2"},"RemovedAt":"2026-10-01T10:00:00Z"},
{"Id":"app.phone-link","Kind":"App","Title":"Phone Link","Target":"Microsoft.YourPhone_8wekyb3d8bbwe","Restore":{"Type":"Store","StoreId":"9NMPJ99VJBWV"},"RemovedAt":"2026-10-01T10:00:01Z"}
]}
'@

        # The script cut after its last function: the head holds the definitions, the tail starts the command.
        $text = [System.IO.File]::ReadAllText($script:FeaturesFile)
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
        $functions = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })
        $script:CutAt = ($functions | ForEach-Object { $_.Extent.EndOffset } | Measure-Object -Maximum).Maximum
        $script:Head = $text.Substring(0, $script:CutAt)
        $script:Tail = $text.Substring($script:CutAt)

        function script:New-FeaturesInstall {
            $install = New-Install
            [System.IO.File]::WriteAllText((Join-Path $install.Bin 'features-overrides.ps1'), $script:Overrides, $script:Utf8)
            $overridesLiteral = ConvertTo-TestLiteral (Join-Path $install.Bin 'features-overrides.ps1')
            [System.IO.File]::WriteAllText((Join-Path $install.Bin 'features-run.ps1'), $script:Head + "`n. $overridesLiteral`n" + $script:Tail, $script:Utf8)
            [System.IO.File]::WriteAllText((Join-Path $install.Bin 'features-head.ps1'), $script:Head, $script:Utf8)
            $config = New-Dir (Join-Path $install.Data 'config')
            $install | Add-Member -NotePropertyName ListFile -NotePropertyValue (Join-Path $config 'features-removed.json')
            [System.IO.File]::WriteAllText($install.ListFile, $script:SavedList, $script:Utf8)
            return $install
        }
        function script:Invoke-Restore($Install, [string]$Codes) {
            $line = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (ConvertTo-WinArgument (Join-Path $Install.Bin 'features-run.ps1')) + ' -Restore'
            return (Invoke-Process -Arguments $line -Install $Install -Environment @{ FIXTURE_WINGET_CODES = $Codes })
        }
        function script:Get-SavedIds($Install) {
            $document = [System.IO.File]::ReadAllText($Install.ListFile) | ConvertFrom-Json
            return @($document.items | ForEach-Object { $_.Id })
        }
    }

    It 'Has a script that can be cut after its last function and still starts the command' {
        $script:Tail | Should -Match 'Invoke-FeaturesCommand'
        $script:Head | Should -Match 'function Invoke-FeaturesWinget'
    }

    It 'Gives exit 0 when every entry is restored' {
        $install = New-FeaturesInstall
        $run = Invoke-Restore $install '0,0'
        $run.ExitCode | Should -Be 0
        $run.Out | Should -Match 'restored'
        @(Get-SavedIds $install).Count | Should -Be 0
    }

    It 'Gives exit 0 when an entry is already installed and nothing failed' -ForEach @(
        @{ Codes = '-1978335189,-1978335135' }
        @{ Codes = '-1978335135,0' }
        @{ Codes = '0,-1978335189' }
    ) {
        $install = New-FeaturesInstall
        $run = Invoke-Restore $install $Codes
        $run.ExitCode | Should -Be 0
        $run.Out | Should -Match 'already installed'
        $run.Out | Should -Not -Match 'failed'
    }

    It 'Gives exit 1 when an entry fails, with the winget codes <Codes>' -ForEach @(
        @{ Codes = '1,0' }
        @{ Codes = '0,1' }
        @{ Codes = '1,1' }
        @{ Codes = '3,3' }
    ) {
        $install = New-FeaturesInstall
        $run = Invoke-Restore $install $Codes
        $run.ExitCode | Should -Be 1
        $run.Out | Should -Match 'failed'
    }

    It 'Gives exit 1 when an entry failed earlier and the last line is already installed' -ForEach @(
        @{ Codes = '1,-1978335135' }
        @{ Codes = '1,-1978335189' }
    ) {
        $install = New-FeaturesInstall
        $run = Invoke-Restore $install $Codes
        $run.ExitCode | Should -Be 1
        $run.Out | Should -Match 'failed'
        $run.Out | Should -Match 'already installed'
    }

    It 'Keeps the entry that failed in the saved list and removes the others' {
        $install = New-FeaturesInstall
        $null = Invoke-Restore $install '1,0'
        @(Get-SavedIds $install) | Should -Be @('app.weather')
    }

    It 'Gives exit 1 for an unreadable saved list, as before' {
        $install = New-FeaturesInstall
        [System.IO.File]::WriteAllText($install.ListFile, 'not json', $script:Utf8)
        (Invoke-Restore $install '0,0').ExitCode | Should -Be 1
    }

    It 'Gives exit 0 when there is nothing to restore' {
        $install = New-FeaturesInstall
        [System.IO.File]::WriteAllText($install.ListFile, '{"version":1,"items":[]}', $script:Utf8)
        (Invoke-Restore $install '0,0').ExitCode | Should -Be 0
    }

    It 'Leaves $global:LASTEXITCODE at 0 after the winget call, whatever winget returned, and still returns the code' {
        $install = New-FeaturesInstall
        $tools = New-Dir (Join-Path $install.Parent 'fake-winget')
        if ($script:IsWin) { [System.IO.File]::WriteAllText((Join-Path $tools 'winget.cmd'), "@exit /b 3`r`n") }
        else {
            [System.IO.File]::WriteAllText((Join-Path $tools 'winget'), "#!/bin/sh`nexit 3`n", $script:Utf8)
            & chmod 755 (Join-Path $tools 'winget')
        }
        $head = ConvertTo-TestLiteral (Join-Path $install.Bin 'features-head.ps1')
        $command = ". $head`n`$global:LASTEXITCODE = 99`n`$result = Invoke-FeaturesWinget -Arguments @('example')`n[Console]::Out.WriteLine('RET=' + [string]@(`$result)[-1])`n[Console]::Out.WriteLine('LAST=' + [string]`$global:LASTEXITCODE)"
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
        $run = Invoke-Process -Arguments "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded" -Install $install -Environment @{ PATH = ($tools + [System.IO.Path]::PathSeparator + $env:PATH) }
        $run.Out | Should -Match 'RET=3'
        $run.Out | Should -Match 'LAST=0'
    }
}
