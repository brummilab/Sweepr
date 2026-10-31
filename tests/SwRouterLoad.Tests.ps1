# Sweepr - tests for loading sweepr.ps1: the shape of the file, the order of the start, dot-sourcing
# (RT-1, RT-2, RT-3), the script variables of the router and the functions it defines.
#
# The rule numbers in the test names (RT- and S) number the rules and the safety invariants of the
# router's behavior; each testable rule and invariant has at least one test. The other router files are
# SwRouterArgs (RT-5 to RT-10, RT-24), SwRouterCommand (RT-11 to RT-15), SwRouterMain (RT-4, RT-16,
# RT-17, RT-21), SwRouterScreens (RT-18 to RT-20, RT-23) and SwRouterProcess (the two call forms).
#
# Interface pinned here (all on the top level of sweepr.ps1, loaded by dot-sourcing):
#   Invoke-SwMain -Arguments, Invoke-SwCommand -CommandName -Arguments, Resolve-SwCommandArguments,
#   Resolve-SwCommandParameter, Show-SwHelp, Show-SwMenu -UpdateContext, Read-SwMenuKey, Show-SwVersion,
#   Get-SwNativeArchitecture, Get-SwDebugHeader -CommandLine, Get-SwInstallMethod -RootDir,
#   Get-SwInstallDescription -RootDir, Get-SwSourceCommit -RootDir, Initialize-SwDataDir
# Script variables: SWEEPR_ROOT, SWEEPR_BIN, SWEEPR_VER, SWEEPR_LIB, SWEEPR_CORE, SweeprExitCode.
#
# Platform notes:
#   - Loading tests run in a child PowerShell (the one that runs the tests) against a copy of the router,
#     VERSION and lib in a fake installation root in $TestDrive; USERPROFILE and SWEEPR_DATA_DIR of the
#     child point into $TestDrive. Nothing real is touched.
#   - Tests marked [W] describe a Windows fact and are meant to fail on Linux where it does not hold.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    $script:IsCore = ($PSVersionTable['PSEdition'] -eq 'Core')
    $script:RouterFunctions = @(
        'Invoke-SwMain', 'Invoke-SwCommand', 'Resolve-SwCommandArguments', 'Resolve-SwCommandParameter', 'Show-SwHelp', 'Show-SwMenu',
        'Read-SwMenuKey', 'Show-SwVersion', 'Get-SwNativeArchitecture', 'Get-SwDebugHeader', 'Get-SwInstallMethod',
        'Get-SwInstallDescription', 'Get-SwSourceCommit', 'Initialize-SwDataDir'
    )
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:RouterFile = Join-Path $script:RepoRoot 'sweepr.ps1'
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
    $script:Pwsh = (Get-Process -Id $PID).Path
    $script:Names = @('Invoke-SwMain', 'Invoke-SwCommand', 'Resolve-SwCommandArguments', 'Resolve-SwCommandParameter', 'Show-SwHelp', 'Show-SwMenu',
        'Read-SwMenuKey', 'Show-SwVersion', 'Get-SwNativeArchitecture', 'Get-SwDebugHeader', 'Get-SwInstallMethod',
        'Get-SwInstallDescription', 'Get-SwSourceCommit', 'Initialize-SwDataDir')

    function script:ConvertTo-TestLiteral([string]$Value) { "'" + $Value.Replace("'", "''") + "'" }
    function script:Invoke-ChildPowerShell {
        param([string]$Script, [string]$WorkingDirectory = $TestDrive, [hashtable]$Environment = @{}, [string[]]$RemoveEnvironment = @())
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Script))
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:Pwsh
        $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
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
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Out = $stdout.Result; Err = $stderr.Result }
    }
    # Windows PowerShell serializes progress records into redirected stderr as CLIXML. That is the host
    # talking, not the loaded file: drop the progress records and the envelope.
    function script:Get-ChildStderr([string]$Text) {
        if ([string]::IsNullOrEmpty($Text)) { return '' }
        $clean = [regex]::Replace($Text, '(?s)<Obj S="progress".*?</Obj>', '')
        $clean = [regex]::Replace($clean, '<Objs[^>]*>|</Objs>|#< CLIXML', '')
        return $clean.Trim()
    }
    function script:Get-Listing([string]$Root) {
        if (-not [System.IO.Directory]::Exists($Root)) { return @() }
        return @([System.IO.Directory]::GetFileSystemEntries($Root, '*', [System.IO.SearchOption]::AllDirectories) | Sort-Object)
    }
    # A fake installation: router, VERSION and lib (the whole folder).
    function script:New-FakeInstall([string]$Name, [string]$Version) {
        $root = Join-Path $TestDrive $Name
        [void][System.IO.Directory]::CreateDirectory($root)
        Copy-Item -LiteralPath $script:RouterFile -Destination $root
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'lib') -Destination $root -Recurse
        [System.IO.File]::WriteAllText((Join-Path $root 'VERSION'), "$Version`r`n", $script:Utf8)
        return $root
    }
}

Describe 'sweepr.ps1 defines the functions of the router (RT-3)' {
    BeforeAll {
        $script:HomeDir = Join-Path $TestDrive 'load-home'
        [void][System.IO.Directory]::CreateDirectory($script:HomeDir)
        $script:SavedProfile = $env:USERPROFILE
        $script:SavedData = $env:SWEEPR_DATA_DIR
        $env:USERPROFILE = $script:HomeDir
        $env:SWEEPR_DATA_DIR = Join-Path $script:HomeDir 'data'
        . $script:RouterFile
    }
    AfterAll {
        $env:USERPROFILE = $script:SavedProfile
        $env:SWEEPR_DATA_DIR = $script:SavedData
    }

    It 'Defines <_> as a function' -ForEach $script:RouterFunctions {
        (Get-Command -Name $_ -CommandType Function -ErrorAction Stop).Name | Should -Be $_
    }

    It 'Gives <Name> the parameters of the interface' -ForEach @(
        @{ Name = 'Invoke-SwMain'; Parameters = @('Arguments') }
        @{ Name = 'Invoke-SwCommand'; Parameters = @('CommandName', 'Arguments') }
        @{ Name = 'Show-SwMenu'; Parameters = @('UpdateContext') }
        @{ Name = 'Get-SwDebugHeader'; Parameters = @('CommandLine') }
        @{ Name = 'Get-SwInstallMethod'; Parameters = @('RootDir') }
        @{ Name = 'Get-SwInstallDescription'; Parameters = @('RootDir') }
        @{ Name = 'Get-SwSourceCommit'; Parameters = @('RootDir') }
    ) {
        $command = Get-Command -Name $Name -CommandType Function -ErrorAction Stop
        foreach ($parameter in $Parameters) { $command.Parameters.ContainsKey($parameter) | Should -BeTrue -Because "$Name has -$parameter" }
    }

    It 'Sets the script variables of the router from the folder of the file' {
        $script:SWEEPR_ROOT | Should -BeExactly $script:RepoRoot.TrimEnd('\', '/')
        $script:SWEEPR_BIN | Should -BeExactly ([System.IO.Path]::Combine($script:RepoRoot, 'bin'))
        $script:SWEEPR_LIB | Should -BeExactly ([System.IO.Path]::Combine($script:RepoRoot, 'lib'))
        $script:SWEEPR_CORE | Should -BeExactly ([System.IO.Path]::Combine($script:RepoRoot, 'lib', 'core'))
        $script:SWEEPR_VER | Should -BeExactly (Get-SwInstalledVersion -RootDir $script:RepoRoot)
    }

    It 'Has loaded update_check.ps1, so its functions can be mocked' {
        (Get-Command -Name 'Start-SwUpdateProbe' -CommandType Function -ErrorAction Stop).Name | Should -Be 'Start-SwUpdateProbe'
        Mock Start-SwUpdateProbe { 'mocked probe' }
        Start-SwUpdateProbe -RootDir 'x' -Version '1.0.0' -Method 'Copy' | Should -BeExactly 'mocked probe'
    }

    It 'Has loaded the shared modules' {
        foreach ($name in 'Get-SwInstalledVersion', 'Repair-SwModuleSearchPath', 'Get-SwRuntimeInfo', 'Initialize-SwDataFolders', 'Resolve-SwDataPaths', 'Assert-SwDataWritable', 'Write-SwError', 'Start-SwDebugSession', 'Complete-SwDebugSession', 'Show-SwLogo', 'Test-SwUpdateHintAllowed', 'Write-SwUpdateHint') {
            (Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty -Because $name
        }
    }

    It 'Defines no function under an old name (no forwarding functions in the router)' -ForEach @(
        @{ Name = 'Main' }
        @{ Name = 'Invoke-SweeprCommand' }
        @{ Name = 'Resolve-CommandParameterName' }
        @{ Name = 'Show-MainHelp' }
        @{ Name = 'Show-MainMenu' }
        @{ Name = 'Show-Version' }
        @{ Name = 'Get-NativeArchitecture' }
        @{ Name = 'Get-SweeprDebugHeader' }
        @{ Name = 'Get-SweeprInstallMethod' }
        @{ Name = 'Get-SweeprInstallDescription' }
        @{ Name = 'Get-SweeprSourceCommit' }
        @{ Name = 'Initialize-SweeprDataDir' }
    ) {
        # Functions only: on Windows `Main` also names a Control Panel applet (main.cpl).
        Get-Command -Name $Name -CommandType Function -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

Describe 'The router file has no parameters of its own (RT-1)' {
    It 'Declares no param block and no [CmdletBinding()], so every word stays data' {
        $command = Get-Command -Name $script:RouterFile -CommandType ExternalScript
        $command.Parameters.Count | Should -Be 0
    }

    It 'Has no param block in its syntax tree' {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:RouterFile, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        $null -eq $ast.ParamBlock | Should -BeTrue
    }

    It 'Has no [CmdletBinding()] attribute at the top of the file' {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:RouterFile, [ref]$tokens, [ref]$errors)
        @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AttributeAst] -and $n.TypeName.Name -eq 'CmdletBinding' -and $n.Parent -eq $ast.ParamBlock }, $true)).Count | Should -Be 0
    }
}

Describe 'The order of the start (RT-2)' {
    BeforeAll {
        # The one test that reads the source: the repair has to come before common.ps1, and on Linux
        # (edition Core) the effect of the repair cannot be seen.
        $tokens = $null
        $errors = $null
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:RouterFile, [ref]$tokens, [ref]$errors)
        $script:Commands = @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
        function script:Test-InFunction($Node) {
            $parent = $Node.Parent
            while ($null -ne $parent) {
                if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $true }
                $parent = $parent.Parent
            }
            return $false
        }
        function script:Get-DotSourceOffset([string]$Pattern) {
            $found = @($script:Commands | Where-Object { $_.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot -and $_.Extent.Text -match $Pattern -and -not (Test-InFunction $_) })
            if ($found.Count -eq 0) { return -1 }
            return $found[0].Extent.StartOffset
        }
    }

    It 'Loads version.ps1, then repairs the module path, then reads the version, then loads common.ps1 and update_check.ps1' {
        $version = Get-DotSourceOffset 'version\.ps1'
        $repair = @($script:Commands | Where-Object { $_.GetCommandName() -eq 'Repair-SwModuleSearchPath' -and -not (Test-InFunction $_) })
        $common = Get-DotSourceOffset 'common\.ps1'
        $update = Get-DotSourceOffset 'update_check\.ps1'
        $assignments = @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -match 'SWEEPR_VER' -and $n.Right.Extent.Text -match 'Get-SwInstalledVersion' }, $true))
        $version | Should -BeGreaterThan -1
        $repair.Count | Should -BeGreaterThan 0
        $common | Should -BeGreaterThan -1
        $update | Should -BeGreaterThan -1
        $assignments.Count | Should -BeGreaterThan 0
        $repairAt = $repair[0].Extent.StartOffset
        $versionAt = $assignments[0].Extent.StartOffset
        $version | Should -BeLessThan $repairAt
        $repairAt | Should -BeLessThan $versionAt
        $versionAt | Should -BeLessThan $common
        $repairAt | Should -BeLessThan $common
        $common | Should -BeLessThan $update
    }
}

Describe 'Loading by dot-sourcing (RT-2, RT-3)' {
    BeforeAll {
        $script:Fake = New-FakeInstall 'load-install' '7.7.7'
        $script:Profile2 = Join-Path $TestDrive 'load-profile'
        $script:Data = Join-Path $TestDrive 'load-data'
        $script:OtherCwd = Join-Path $TestDrive 'load-elsewhere'
        [void][System.IO.Directory]::CreateDirectory($script:Profile2)
        [void][System.IO.Directory]::CreateDirectory($script:OtherCwd)
        # Decoys in the working directory: nothing may be taken from there.
        [void][System.IO.Directory]::CreateDirectory((Join-Path $script:OtherCwd 'lib\core'))
        [System.IO.File]::WriteAllText((Join-Path $script:OtherCwd 'VERSION'), '6.6.6', $script:Utf8)
        [System.IO.File]::WriteAllText((Join-Path $script:OtherCwd 'lib\core\version.ps1'), "function Get-SwInstalledVersion { 'decoy' }`n", $script:Utf8)

        $router = ConvertTo-TestLiteral (Join-Path $script:Fake 'sweepr.ps1')
        $names = ($script:Names | ForEach-Object { "'$_'" }) -join ','
        $script:FilesBefore = @(Get-Listing $script:Fake)
        $script:Run = Invoke-ChildPowerShell -WorkingDirectory $script:OtherCwd -RemoveEnvironment @('SWEEPR_DRY_RUN', 'SWEEPR_DEBUG', '_SWEEPR_OPLOG_RUN_COMMAND', '_SWEEPR_OPLOG_RUN_ID') -Environment @{
            USERPROFILE     = $script:Profile2
            HOME            = $script:Profile2
            SWEEPR_DATA_DIR = $script:Data
            SWEEPR_NO_OPLOG = '1'
        } -Script @"
Set-StrictMode -Off
`$ErrorActionPreference = 'Continue'
`$script:SweeprExitCode = 77
`$envBefore = (Get-ChildItem Env: | Sort-Object Name | ForEach-Object { `$_.Name + '=' + `$_.Value }) -join '|'
. $router
'##RESULT##'
`$r = [ordered]@{}
`$r.StillRunning = 'yes'
`$r.Eap = [string]`$ErrorActionPreference
`$r.Strict = try { `$null = `$notDefinedAnywhere; 'off' } catch { 'on' }
`$r.Missing = @(foreach (`$n in @($names)) { if (-not (Get-Command `$n -CommandType Function -ErrorAction SilentlyContinue)) { `$n } })
`$r.Old = @(foreach (`$n in @('Main','Invoke-SweeprCommand','Show-MainHelp','Show-MainMenu')) { if (Get-Command `$n -CommandType Function -ErrorAction SilentlyContinue) { `$n } })
`$r.Root = [string]`$script:SWEEPR_ROOT
`$r.Bin = [string]`$script:SWEEPR_BIN
`$r.Lib = [string]`$script:SWEEPR_LIB
`$r.Core = [string]`$script:SWEEPR_CORE
`$r.Ver = [string]`$script:SWEEPR_VER
`$r.ExitCode = [string]`$script:SweeprExitCode
`$r.EnvSame = (((Get-ChildItem Env: | Sort-Object Name | ForEach-Object { `$_.Name + '=' + `$_.Value }) -join '|') -eq `$envBefore)
`$r.Processes = @(Get-Process -Name 'sw*' -ErrorAction SilentlyContinue).Count
`$r | ConvertTo-Json -Compress
"@
        $parts = $script:Run.Out -split '##RESULT##'
        $script:LoadOutput = $parts[0]
        $script:Data2 = $null
        if ($parts.Count -gt 1) { $script:Data2 = $parts[1].Trim() | ConvertFrom-Json }
    }

    It 'Returns to the caller: no exit and no run of Invoke-SwMain' {
        $script:Run.ExitCode | Should -Be 0
        $script:Data2 | Should -Not -BeNullOrEmpty
        $script:Data2.StillRunning | Should -Be 'yes'
    }

    It 'Writes nothing while loading' {
        $script:LoadOutput.Trim() | Should -BeNullOrEmpty
        (Get-ChildStderr $script:Run.Err) | Should -BeNullOrEmpty
    }

    It 'Defines every function of the interface and none under an old name' {
        @($script:Data2.Missing) | Should -BeNullOrEmpty
        @($script:Data2.Old) | Should -BeNullOrEmpty
    }

    It 'Takes the root from the folder of the file and the version from its VERSION, not from the working directory' {
        $script:Data2.Root.TrimEnd('\', '/') | Should -BeExactly $script:Fake.TrimEnd('\', '/')
        $script:Data2.Bin | Should -BeExactly ([System.IO.Path]::Combine($script:Fake, 'bin'))
        $script:Data2.Lib | Should -BeExactly ([System.IO.Path]::Combine($script:Fake, 'lib'))
        $script:Data2.Core | Should -BeExactly ([System.IO.Path]::Combine($script:Fake, 'lib', 'core'))
        $script:Data2.Ver | Should -BeExactly '7.7.7'
    }

    It 'Leaves $script:SweeprExitCode as the caller set it' {
        $script:Data2.ExitCode | Should -Be '77'
    }

    It 'Changes no environment variable' {
        $script:Data2.EnvSame | Should -BeTrue
    }

    It 'Creates no file or folder: not in the installation, the profile, the data folder or the working directory' {
        @(Get-Listing $script:Fake) | Should -Be $script:FilesBefore
        @(Get-Listing $script:Profile2 | Where-Object { $_ -match '(?i)sweepr|[\\/]\.config' }).Count | Should -Be 0
        [System.IO.Directory]::Exists($script:Data) | Should -BeFalse
        @(Get-Listing $script:OtherCwd).Count | Should -Be 4
    }

    It 'Leaves strict mode on and the error preference on Stop in the caller after loading' {
        $script:Data2.Eap | Should -Be 'Stop'
        $script:Data2.Strict | Should -Be 'on'
    }
}

Describe 'The module search path (RT-2)' {
    It 'Leaves PSModulePath as it was in PowerShell 7' -Skip:(-not $script:IsCore) {
        $fake = New-FakeInstall 'load-path-core' '7.7.7'
        $modulePath = (@('C:\Program Files\PowerShell\7\Modules', 'C:\Windows\system32\WindowsPowerShell\v1.0\Modules') -join [System.IO.Path]::PathSeparator)
        $router = ConvertTo-TestLiteral (Join-Path $fake 'sweepr.ps1')
        $home2 = Join-Path $TestDrive 'load-path-home'
        [void][System.IO.Directory]::CreateDirectory($home2)
        $run = Invoke-ChildPowerShell -Environment @{ PSModulePath = $modulePath; USERPROFILE = $home2; HOME = $home2; SWEEPR_DATA_DIR = (Join-Path $home2 'data'); SWEEPR_NO_OPLOG = '1' } -Script "`$before = `$env:PSModulePath; . $router; [Console]::Out.Write('SAME=' + (`$before -ceq `$env:PSModulePath))"
        $run.Out | Should -BeExactly 'SAME=True'
    }

    It '[W] Leaves only Windows PowerShell 5.1 module folders after loading in Windows PowerShell with an inherited PowerShell 7 module path' {
        $fake = New-FakeInstall 'load-path-desktop' '7.7.7'
        $windowsPowerShell = Join-Path ([System.Environment]::GetEnvironmentVariable('SystemRoot')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $home2 = Join-Path $TestDrive 'load-path-home2'
        [void][System.IO.Directory]::CreateDirectory($home2)
        $inherited = 'C:\Program Files\PowerShell\7\Modules;C:\Users\Example\Documents\PowerShell\Modules;C:\Windows\system32\WindowsPowerShell\v1.0\Modules'
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $windowsPowerShell
        $command = ". $(ConvertTo-TestLiteral (Join-Path $fake 'sweepr.ps1')); [Console]::Out.Write(`$env:PSModulePath)"
        $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.EnvironmentVariables['PSModulePath'] = $inherited
        $psi.EnvironmentVariables['USERPROFILE'] = $home2
        $psi.EnvironmentVariables['SWEEPR_DATA_DIR'] = (Join-Path $home2 'data')
        $psi.EnvironmentVariables['SWEEPR_NO_OPLOG'] = '1'
        $process = [System.Diagnostics.Process]::Start($psi)
        $process.StandardInput.Close()
        $out = $process.StandardOutput.ReadToEnd()
        [void]$process.WaitForExit(60000)
        $entries = @($out.Split(';') | Where-Object { $_ -ne '' })
        $entries.Count | Should -BeGreaterThan 0
        foreach ($entry in $entries) { ($entry + '\') | Should -Not -Match '\\PowerShell\\' }
        $entries | Should -Contain 'C:\Windows\system32\WindowsPowerShell\v1.0\Modules'
    }
}

Describe 'The text of a start error' {
    It 'Writes no control character of a folder name to standard error' {
        # An escape character in a folder name is possible on Linux only; Windows does not allow it.
        if ($PSVersionTable['PSEdition'] -ne 'Core' -or [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { Set-ItResult -Skipped -Because 'Windows folder names cannot hold control characters'; return }
        $esc = [string][char]27
        $root = New-FakeInstall ('start-error' + $esc + '[31m') '1.0.0'
        # A folder in place of VERSION makes version.ps1 throw a message that holds the path.
        [System.IO.File]::Delete((Join-Path $root 'VERSION'))
        [void][System.IO.Directory]::CreateDirectory((Join-Path $root 'VERSION'))
        $run = Invoke-ChildPowerShell -Script ("& " + (ConvertTo-TestLiteral (Join-Path $root 'sweepr.ps1')) + " --version; exit `$LASTEXITCODE")
        $run.ExitCode | Should -Be 1
        $run.Err | Should -Match 'Sweepr cannot start'
        $run.Err | Should -Match 'start-error'
        $run.Err.Contains($esc) | Should -BeFalse
    }
}
