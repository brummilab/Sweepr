# Sweepr - data path resolution, portable detection and install method tests (F-01a)
# Platform neutral: only TestDrive, environment variables and dot-sourced libraries.
# Nothing here touches the real profile; USERPROFILE and SWEEPR_DATA_DIR are
# redirected per test and restored afterwards.

BeforeAll {
    $script:ProjectRoot = Split-Path -Parent $PSScriptRoot
    $script:SavedProfile = $env:USERPROFILE
    $script:SavedDataDir = $env:SWEEPR_DATA_DIR
    $script:SavedDebug = $env:SWEEPR_DEBUG
    $script:SavedConfig = $null
    if (Get-Variable -Name Config -Scope Script -ErrorAction SilentlyContinue) { $script:SavedConfig = $script:Config }

    # Paths are compared with one separator so the tests hold on both platforms.
    function script:Norm {
        param([string]$Path)
        return ([string]$Path).Replace('\', '/').TrimEnd('/')
    }

    $script:SWEEPR_BASE_LOADED = $false
    . (Join-Path $script:ProjectRoot 'lib\core\base.ps1')

    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:ProjectRoot 'sweepr.ps1'), [ref]$null, [ref]$null)
    $definition = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-SweeprInstallMethod'
        }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
    Set-Item -Path 'function:script:Get-SweeprInstallMethod' -Value (Get-Item 'function:Get-SweeprInstallMethod').ScriptBlock
}

AfterAll {
    $env:USERPROFILE = $script:SavedProfile
    $env:SWEEPR_DATA_DIR = $script:SavedDataDir
    $env:SWEEPR_DEBUG = $script:SavedDebug
    if ($null -ne $script:SavedConfig) { $script:Config = $script:SavedConfig }
}

Describe 'Resolve-SweeprDataPaths' {
    BeforeEach {
        $script:Case = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:AppRoot = Join-Path $script:Case 'app'
        $script:UserHome = Join-Path $script:Case 'home'
        New-Item -ItemType Directory -Path $script:AppRoot, $script:UserHome -Force | Out-Null
        $env:USERPROFILE = $script:UserHome
        $env:SWEEPR_DATA_DIR = $null
    }

    AfterEach {
        $env:USERPROFILE = $script:SavedProfile
        $env:SWEEPR_DATA_DIR = $script:SavedDataDir
    }

    It 'Uses the user profile when there is no override and no marker' {
        $paths = Resolve-SweeprDataPaths -RootDir $script:AppRoot
        $paths.Mode | Should -BeExactly 'Profile'
        Norm $paths.ConfigPath | Should -BeExactly (Norm "$($script:UserHome)/.config/sweepr")
        Norm $paths.CachePath | Should -BeExactly (Norm "$($script:UserHome)/.cache/sweepr")
    }

    It 'Uses the data folder next to the program when sweepr.portable is a file' {
        Set-Content -LiteralPath (Join-Path $script:AppRoot 'sweepr.portable') -Value ''
        $paths = Resolve-SweeprDataPaths -RootDir $script:AppRoot
        $paths.Mode | Should -BeExactly 'Portable'
        Norm $paths.ConfigPath | Should -BeExactly (Norm "$($script:AppRoot)/data/config")
        Norm $paths.CachePath | Should -BeExactly (Norm "$($script:AppRoot)/data/cache")
    }

    It 'Uses SWEEPR_DATA_DIR as an override' {
        $override = Join-Path $script:Case 'elsewhere'
        $env:SWEEPR_DATA_DIR = $override
        $paths = Resolve-SweeprDataPaths -RootDir $script:AppRoot
        $paths.Mode | Should -BeExactly 'Override'
        Norm $paths.ConfigPath | Should -BeExactly (Norm "$override/config")
        Norm $paths.CachePath | Should -BeExactly (Norm "$override/cache")
    }

    It 'Prefers the override over the portable marker' {
        Set-Content -LiteralPath (Join-Path $script:AppRoot 'sweepr.portable') -Value ''
        $override = Join-Path $script:Case 'elsewhere'
        $env:SWEEPR_DATA_DIR = $override
        $paths = Resolve-SweeprDataPaths -RootDir $script:AppRoot
        $paths.Mode | Should -BeExactly 'Override'
        Norm $paths.ConfigPath | Should -BeExactly (Norm "$override/config")
    }

    It 'Prefers the portable marker over the profile' {
        Set-Content -LiteralPath (Join-Path $script:AppRoot 'sweepr.portable') -Value ''
        (Resolve-SweeprDataPaths -RootDir $script:AppRoot).Mode | Should -BeExactly 'Portable'
    }

    It 'Treats an empty SWEEPR_DATA_DIR as not set' {
        $env:SWEEPR_DATA_DIR = ''
        (Resolve-SweeprDataPaths -RootDir $script:AppRoot).Mode | Should -BeExactly 'Profile'
        Set-Content -LiteralPath (Join-Path $script:AppRoot 'sweepr.portable') -Value ''
        (Resolve-SweeprDataPaths -RootDir $script:AppRoot).Mode | Should -BeExactly 'Portable'
    }

    It 'Does not count a sweepr.portable folder as the marker' {
        New-Item -ItemType Directory -Path (Join-Path $script:AppRoot 'sweepr.portable') -Force | Out-Null
        (Resolve-SweeprDataPaths -RootDir $script:AppRoot).Mode | Should -BeExactly 'Profile'
    }

    It 'Creates nothing while resolving' {
        Set-Content -LiteralPath (Join-Path $script:AppRoot 'sweepr.portable') -Value ''
        $null = Resolve-SweeprDataPaths -RootDir $script:AppRoot
        Test-Path -LiteralPath (Join-Path $script:AppRoot 'data') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:UserHome -Force).Count | Should -Be 0
    }
}

Describe 'Test-SweeprPortable' {
    BeforeEach {
        $script:AppRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:AppRoot -Force | Out-Null
    }

    It 'Is false without the marker' {
        Test-SweeprPortable -RootDir $script:AppRoot | Should -BeFalse
    }

    It 'Is true when sweepr.portable is a file' {
        Set-Content -LiteralPath (Join-Path $script:AppRoot 'sweepr.portable') -Value ''
        Test-SweeprPortable -RootDir $script:AppRoot | Should -BeTrue
    }

    It 'Is false when sweepr.portable is a folder' {
        New-Item -ItemType Directory -Path (Join-Path $script:AppRoot 'sweepr.portable') -Force | Out-Null
        Test-SweeprPortable -RootDir $script:AppRoot | Should -BeFalse
    }
}

Describe 'Assert-SweeprDataWritable' {
    BeforeEach {
        $script:Case = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:UserHome = Join-Path $script:Case 'home'
        New-Item -ItemType Directory -Path $script:UserHome -Force | Out-Null
        $env:USERPROFILE = $script:UserHome
    }

    AfterEach { $env:USERPROFILE = $script:SavedProfile }

    It 'Creates a missing folder and leaves no probe file behind' {
        $target = Join-Path $script:Case 'data/config'
        { Assert-SweeprDataWritable -Path $target } | Should -Not -Throw
        Test-Path -LiteralPath $target -PathType Container | Should -BeTrue
        @(Get-ChildItem -LiteralPath $target -Force).Count | Should -Be 0
    }

    It 'Accepts a folder that already exists' {
        $target = Join-Path $script:Case 'existing'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        { Assert-SweeprDataWritable -Path $target } | Should -Not -Throw
        @(Get-ChildItem -LiteralPath $target -Force).Count | Should -Be 0
    }

    It 'Throws the documented message when the target cannot be created' {
        $blocker = Join-Path $script:Case 'blocker'
        Set-Content -LiteralPath $blocker -Value 'a file, not a folder'
        $target = Join-Path $blocker 'config'
        $expected = "Sweepr data folder is not writable: $target. Sweepr does not fall back to your user profile."
        { Assert-SweeprDataWritable -Path $target } | Should -Throw -ExpectedMessage $expected
    }

    It 'Does not fall back to the user profile when it fails' {
        $blocker = Join-Path $script:Case 'blocker'
        Set-Content -LiteralPath $blocker -Value 'a file, not a folder'
        { Assert-SweeprDataWritable -Path (Join-Path $blocker 'config') } | Should -Throw -ExpectedMessage 'Sweepr data folder is not writable:*'
        @(Get-ChildItem -LiteralPath $script:UserHome -Force).Count | Should -Be 0
    }
}

Describe 'Config values come from the resolver' {
    BeforeEach {
        $script:Case = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:UserHome = Join-Path $script:Case 'home'
        New-Item -ItemType Directory -Path $script:UserHome -Force | Out-Null
        $env:USERPROFILE = $script:UserHome
        $env:SWEEPR_DATA_DIR = $null
    }

    AfterEach {
        $env:USERPROFILE = $script:SavedProfile
        $env:SWEEPR_DATA_DIR = $script:SavedDataDir
    }

    It 'Keeps the profile locations in profile mode' {
        $script:SWEEPR_BASE_LOADED = $false
        . (Join-Path $script:ProjectRoot 'lib\core\base.ps1')
        Norm $script:Config.ConfigPath | Should -BeExactly (Norm "$($script:UserHome)/.config/sweepr")
        Norm $script:Config.CachePath | Should -BeExactly (Norm "$($script:UserHome)/.cache/sweepr")
        Norm $script:Config.WhitelistFile | Should -BeExactly (Norm "$($script:UserHome)/.config/sweepr/whitelist.txt")
    }

    It 'Moves config, cache and whitelist under the data folder in override mode' {
        $data = Join-Path $script:Case 'data'
        $env:SWEEPR_DATA_DIR = $data
        $script:SWEEPR_BASE_LOADED = $false
        . (Join-Path $script:ProjectRoot 'lib\core\base.ps1')
        Norm $script:Config.ConfigPath | Should -BeExactly (Norm "$data/config")
        Norm $script:Config.CachePath | Should -BeExactly (Norm "$data/cache")
        Norm $script:Config.WhitelistFile | Should -BeExactly (Norm "$data/config/whitelist.txt")
    }

    It 'Hands out the configured folders through Get-ConfigPath and Get-CachePath' {
        $script:Config.ConfigPath = Join-Path $script:Case 'cfg'
        $script:Config.CachePath = Join-Path $script:Case 'cch'
        Get-ConfigPath | Should -BeExactly $script:Config.ConfigPath
        Get-CachePath | Should -BeExactly $script:Config.CachePath
        Test-Path -LiteralPath $script:Config.ConfigPath -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $script:Config.CachePath -PathType Container | Should -BeTrue
    }
}

Describe 'Log files follow the configured folder' {
    BeforeEach {
        $script:Case = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:UserHome = Join-Path $script:Case 'home'
        New-Item -ItemType Directory -Path $script:UserHome -Force | Out-Null
        $env:USERPROFILE = $script:UserHome
        $env:SWEEPR_DEBUG = '1'
    }

    AfterEach {
        $env:USERPROFILE = $script:SavedProfile
        $env:SWEEPR_DEBUG = $script:SavedDebug
    }

    It 'Puts operations.log and the debug session log under Config.ConfigPath' {
        $script:Config = @{ ConfigPath = (Join-Path $script:Case 'portable/data/config') }
        $script:SWEEPR_LOG_LOADED = $false
        . (Join-Path $script:ProjectRoot 'lib\core\log.ps1')
        Norm $script:SweeprOperationsLogFile | Should -BeExactly (Norm "$($script:Case)/portable/data/config/operations.log")
        Norm $script:SweeprDebugLogFile | Should -BeExactly (Norm "$($script:Case)/portable/data/config/sweepr_debug_session.log")
        Norm $script:LogConfig.LogFile | Should -BeExactly (Norm $script:SweeprDebugLogFile)
    }

    It 'Falls back to the profile when log.ps1 is loaded without a Config' {
        Remove-Variable -Name Config -Scope Script -ErrorAction SilentlyContinue
        $script:SWEEPR_LOG_LOADED = $false
        . (Join-Path $script:ProjectRoot 'lib\core\log.ps1')
        Norm $script:SweeprOperationsLogFile | Should -BeExactly (Norm "$($script:UserHome)/.config/sweepr/operations.log")
        Norm $script:SweeprDebugLogFile | Should -BeExactly (Norm "$($script:UserHome)/.config/sweepr/sweepr_debug_session.log")
    }
}

Describe 'Command scripts take their files from the configured folders' {
    # These scripts only run on Windows, so the paths are checked in the source:
    # no hard-wired profile location may remain for Sweepr's own files.
    It '<File> no longer hard-wires the profile for <Name>' -ForEach @(
        @{ File = 'bin\clean.ps1'; Name = 'clean-list.txt' },
        @{ File = 'bin\purge.ps1'; Name = 'purge_paths.txt' },
        @{ File = 'bin\uninstall.ps1'; Name = 'the app cache' }
    ) {
        $path = Join-Path $script:ProjectRoot $File
        $hardWired = @(Select-String -LiteralPath $path -Pattern '\$env:USERPROFILE\\\.(config|cache)\\sweepr' | ForEach-Object { $_.Line.Trim() })
        $hardWired | Should -BeNullOrEmpty
        $source = Get-Content -LiteralPath $path -Raw
        $source | Should -Match 'Get-ConfigPath|Get-CachePath|\$script:Config\.(ConfigPath|CachePath)'
    }

    It 'Keeps the update check file in the cache folder' {
        $source = Get-Content -LiteralPath (Join-Path $script:ProjectRoot 'lib\core\update_check.ps1') -Raw
        $source | Should -Match "Get-CachePath\) 'update-check\.json'"
    }
}

Describe 'Get-SweeprInstallMethod' {
    BeforeEach {
        $script:AppRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:AppRoot -Force | Out-Null
    }

    It 'Says Copy for a plain folder' {
        Get-SweeprInstallMethod -RootDir $script:AppRoot | Should -BeExactly 'Copy'
    }

    It 'Says Portable when the marker file is present' {
        Set-Content -LiteralPath (Join-Path $script:AppRoot 'sweepr.portable') -Value ''
        Get-SweeprInstallMethod -RootDir $script:AppRoot | Should -BeExactly 'Portable'
    }

    It 'Checks the marker before Source' {
        New-Item -ItemType Directory -Path (Join-Path $script:AppRoot '.git') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:AppRoot 'sweepr.portable') -Value ''
        Get-SweeprInstallMethod -RootDir $script:AppRoot | Should -BeExactly 'Portable'
    }

    It 'Still says Source for a Git checkout without the marker' {
        New-Item -ItemType Directory -Path (Join-Path $script:AppRoot '.git') -Force | Out-Null
        Get-SweeprInstallMethod -RootDir $script:AppRoot | Should -BeExactly 'Source'
    }

    It 'Recognises the winget and Scoop folders' -ForEach @(
        @{ Root = 'C:\Users\Example\AppData\Local\Microsoft\WinGet\Packages\brummilab.Sweepr_Fixture'; Expected = 'winget' },
        @{ Root = 'C:\Users\Example\scoop\apps\sweepr\current'; Expected = 'Scoop' }
    ) {
        Get-SweeprInstallMethod -RootDir $Root | Should -BeExactly $Expected
    }
}

Describe 'Resolve-SweeprDataPaths override edge cases' {
    BeforeEach {
        $script:Case = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:AppRoot = Join-Path $script:Case 'app'
        $script:UserHome = Join-Path $script:Case 'home'
        New-Item -ItemType Directory -Path $script:AppRoot, $script:UserHome -Force | Out-Null
        $env:USERPROFILE = $script:UserHome
        $script:SavedLocation = (Get-Location).Path
    }

    AfterEach {
        Set-Location -LiteralPath $script:SavedLocation
        $env:USERPROFILE = $script:SavedProfile
        $env:SWEEPR_DATA_DIR = $script:SavedDataDir
    }

    It 'Treats a whitespace-only SWEEPR_DATA_DIR as not set' {
        $env:SWEEPR_DATA_DIR = '   '
        $paths = Resolve-SweeprDataPaths -RootDir $script:AppRoot
        $paths.Mode | Should -BeExactly 'Profile'
        Norm $paths.ConfigPath | Should -BeExactly (Norm "$($script:UserHome)/.config/sweepr")
    }

    It 'Resolves a relative override against the current directory' {
        Set-Location -LiteralPath $script:Case
        $env:SWEEPR_DATA_DIR = Join-Path 'rel' 'data'
        $full = (Get-Item -LiteralPath $script:Case).FullName
        $paths = Resolve-SweeprDataPaths -RootDir $script:AppRoot
        $paths.Mode | Should -BeExactly 'Override'
        Norm $paths.ConfigPath | Should -BeExactly (Norm "$full/rel/data/config")
        Norm $paths.CachePath | Should -BeExactly (Norm "$full/rel/data/cache")
    }
}

Describe 'sweepr.ps1 start order' {
    BeforeAll {
        $script:SweeprAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:ProjectRoot 'sweepr.ps1'), [ref]$null, [ref]$null)
    }

    It 'Checks the data folder is writable before Initialize-Sweepr creates folders' {
        $main = $script:SweeprAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Main'
            }, $true)
        $main | Should -Not -BeNullOrEmpty
        $calls = @($main.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
        $check = @($calls | Where-Object { $_.GetCommandName() -eq 'Initialize-SweeprDataDir' })
        $init = @($calls | Where-Object { $_.GetCommandName() -eq 'Initialize-Sweepr' })
        $check.Count | Should -BeGreaterThan 0
        $init.Count | Should -BeGreaterThan 0
        $check[0].Extent.StartOffset | Should -BeLessThan $init[0].Extent.StartOffset
    }

    It 'Defines Initialize-SweeprDataDir and lets it call Assert-SweeprDataWritable' {
        $fn = $script:SweeprAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Initialize-SweeprDataDir'
            }, $true)
        $fn | Should -Not -BeNullOrEmpty
        $fn.Extent.Text | Should -Match 'Assert-SweeprDataWritable'
    }
}

# ---------------------------------------------------------------------------
# F-01b: sw update, sw remove and install.ps1 -Uninstall in portable and
# override mode (Design Rev 2 section 9 and Rev 2a).
# The command scripts run as child processes of the current host against a
# fake program folder in TestDrive. Nothing real is touched: USERPROFILE and
# HOME point into TestDrive for the child, install.ps1 in the fixture is a
# stub that only leaves a marker file when it is called.
# ---------------------------------------------------------------------------

Describe 'Portable command scripts' {
    BeforeAll {
        $script:HostExe = (Get-Process -Id $PID).Path

        # Every file with its content, plus every folder: a change, a deletion
        # or a new file shows up as a difference.
        function script:Get-TreeSnapshot {
            param([string]$Path)
            $base = (Get-Item -LiteralPath $Path).FullName.TrimEnd('\', '/')
            $lines = foreach ($item in @(Get-ChildItem -LiteralPath $Path -Recurse -Force)) {
                $rel = $item.FullName.Substring($base.Length).Replace('\', '/')
                if ($item.PSIsContainer) { "D $rel" } else { "F $rel :: " + [IO.File]::ReadAllText($item.FullName) }
            }
            return (@($lines | Sort-Object) -join "`n")
        }

        function script:New-FakeApp {
            param([string]$Base, [switch]$Portable, [switch]$WithGit)
            $root = Join-Path $Base 'app'
            foreach ($dir in 'bin', 'lib', 'data/config', 'data/cache') {
                New-Item -ItemType Directory -Path (Join-Path $root $dir) -Force | Out-Null
            }
            Copy-Item -LiteralPath (Join-Path $script:ProjectRoot 'bin/update.ps1') -Destination (Join-Path $root 'bin/update.ps1')
            Copy-Item -LiteralPath (Join-Path $script:ProjectRoot 'bin/remove.ps1') -Destination (Join-Path $root 'bin/remove.ps1')
            Copy-Item -LiteralPath (Join-Path $script:ProjectRoot 'lib/core') -Destination (Join-Path $root 'lib/core') -Recurse
            Set-Content -LiteralPath (Join-Path $root 'sweepr.ps1') -Value '#'
            Set-Content -LiteralPath (Join-Path $root 'VERSION') -Value '1.2.3'
            # Stub installer: proves whether remove.ps1 handed over to it.
            Set-Content -LiteralPath (Join-Path $root 'install.ps1') -Value @'
param([string]$InstallDir, [switch]$Uninstall)
Set-Content -LiteralPath (Join-Path $PSScriptRoot 'installer-ran.txt') -Value "Uninstall=$Uninstall"
'@
            Set-Content -LiteralPath (Join-Path $root 'data/config/whitelist.txt') -Value 'C:\Users\Example\keep'
            Set-Content -LiteralPath (Join-Path $root 'data/config/operations.log') -Value 'REMOVED example'
            Set-Content -LiteralPath (Join-Path $root 'data/cache/update-check.json') -Value '{}'
            if ($Portable) { Set-Content -LiteralPath (Join-Path $root 'sweepr.portable') -Value '' }
            if ($WithGit) { New-Item -ItemType Directory -Path (Join-Path $root '.git') -Force | Out-Null }
            return $root
        }

        function script:Invoke-FakeCommand {
            param([string]$Script, [string]$Stdin = 'n')
            $text = $Stdin | & $script:HostExe -NoProfile -File $Script 2>&1 | Out-String
            return @{ Output = $text; ExitCode = $LASTEXITCODE }
        }
    }

    BeforeEach {
        $script:Case = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:UserHome = Join-Path $script:Case 'home'
        New-Item -ItemType Directory -Path (Join-Path $script:UserHome '.config/sweepr'), (Join-Path $script:UserHome '.cache/sweepr') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:UserHome '.config/sweepr/whitelist.txt') -Value 'profile data'
        $script:SavedHome = $env:HOME
        $env:USERPROFILE = $script:UserHome
        $env:HOME = $script:UserHome
        $env:SWEEPR_DATA_DIR = $null
        $env:SWEEPR_DEBUG = $null
    }

    AfterEach {
        $env:USERPROFILE = $script:SavedProfile
        $env:HOME = $script:SavedHome
        $env:SWEEPR_DATA_DIR = $script:SavedDataDir
        $env:SWEEPR_DEBUG = $script:SavedDebug
    }

    Context 'sw update' {
        It 'Installs nothing, names the portable asset and the Releases page, and exits 1' {
            $root = New-FakeApp -Base $script:Case -Portable
            $before = Get-TreeSnapshot -Path $root
            $result = Invoke-FakeCommand -Script (Join-Path $root 'bin/update.ps1')
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'https://github\.com/brummilab/sweepr/releases'
            $result.Output | Should -Match 'sweepr-[0-9A-Za-z.<>-]+-x64-portable\.zip'
            $result.Output | Should -Match 'data'
            Get-TreeSnapshot -Path $root | Should -BeExactly $before
        }

        It 'Answers with the portable message, not with the copy or source messages' {
            $root = New-FakeApp -Base $script:Case -Portable
            $result = Invoke-FakeCommand -Script (Join-Path $root 'bin/update.ps1')
            $result.Output | Should -Match 'x64-portable\.zip'
            $result.Output | Should -Not -Match 'not a git-based source install'
            $result.Output | Should -Not -Match 'Installer not found'
            $result.Output | Should -Not -Match 'Git is not installed'
            $result.Output | Should -Not -Match 'quick-install'
        }

        It 'Treats the marker as stronger than a .git folder and never starts the installer' {
            $root = New-FakeApp -Base $script:Case -Portable -WithGit
            $before = Get-TreeSnapshot -Path $root
            $result = Invoke-FakeCommand -Script (Join-Path $root 'bin/update.ps1')
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'sweepr-[0-9A-Za-z.<>-]+-x64-portable\.zip'
            Test-Path -LiteralPath (Join-Path $root 'installer-ran.txt') | Should -BeFalse
            Get-TreeSnapshot -Path $root | Should -BeExactly $before
        }

        It 'Also holds when SWEEPR_DATA_DIR points at the portable data folder (sweepr.ps1 sets it that way)' {
            $root = New-FakeApp -Base $script:Case -Portable
            $env:SWEEPR_DATA_DIR = Join-Path $root 'data'
            $before = Get-TreeSnapshot -Path $root
            $result = Invoke-FakeCommand -Script (Join-Path $root 'bin/update.ps1')
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'sweepr-[0-9A-Za-z.<>-]+-x64-portable\.zip'
            Get-TreeSnapshot -Path $root | Should -BeExactly $before
        }

        It 'Keeps the existing message for a plain copy without the marker' {
            $root = New-FakeApp -Base $script:Case
            $result = Invoke-FakeCommand -Script (Join-Path $root 'bin/update.ps1')
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'not a git-based source install'
            $result.Output | Should -Not -Match 'x64-portable\.zip'
        }
    }

    Context 'sw remove in portable mode' {
        It 'Deletes nothing: program files, data folder and installer stay exactly as they were' {
            $root = New-FakeApp -Base $script:Case -Portable
            $before = Get-TreeSnapshot -Path $root
            $result = Invoke-FakeCommand -Script (Join-Path $root 'bin/remove.ps1') -Stdin 'y'
            $result.ExitCode | Should -Be 1
            Get-TreeSnapshot -Path $root | Should -BeExactly $before
            Test-Path -LiteralPath (Join-Path $root 'sweepr.portable') -PathType Leaf | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $root 'sweepr.ps1') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $root 'data/config/whitelist.txt') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $root 'data/config/operations.log') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $root 'data/cache/update-check.json') | Should -BeTrue
        }

        It 'Does not hand over to the installer and does not ask for confirmation' {
            $root = New-FakeApp -Base $script:Case -Portable
            $result = Invoke-FakeCommand -Script (Join-Path $root 'bin/remove.ps1') -Stdin 'y'
            Test-Path -LiteralPath (Join-Path $root 'installer-ran.txt') | Should -BeFalse
            $result.Output | Should -Not -Match '\(y/N\)'
            $result.Output | Should -Not -Match 'Cancelled'
        }

        It 'Prints the documented message with the program folder and its data folder' {
            $root = New-FakeApp -Base $script:Case -Portable
            $result = Invoke-FakeCommand -Script (Join-Path $root 'bin/remove.ps1') -Stdin 'y'
            $flat = ($result.Output -replace '\s+', ' ').Trim()
            $flat | Should -Match ('Sweepr portable leaves nothing outside its folder\. To remove it, delete ' + [regex]::Escape($root) + '\. Your settings and operation log are in ' + [regex]::Escape($root) + '[\\/]data\.')
        }

        It 'Leaves the profile folders alone' {
            $root = New-FakeApp -Base $script:Case -Portable
            # Only Sweepr's own profile folders: the child PowerShell host writes
            # its own files below HOME.
            $config = Join-Path $script:UserHome '.config/sweepr'
            $cache = Join-Path $script:UserHome '.cache/sweepr'
            $configBefore = Get-TreeSnapshot -Path $config
            $cacheBefore = Get-TreeSnapshot -Path $cache
            $null = Invoke-FakeCommand -Script (Join-Path $root 'bin/remove.ps1') -Stdin 'y'
            Test-Path -LiteralPath $config -PathType Container | Should -BeTrue
            Test-Path -LiteralPath $cache -PathType Container | Should -BeTrue
            Get-TreeSnapshot -Path $config | Should -BeExactly $configBefore
            Get-TreeSnapshot -Path $cache | Should -BeExactly $cacheBefore
        }

        It 'Refuses even when SWEEPR_DATA_DIR points at the portable data folder' {
            $root = New-FakeApp -Base $script:Case -Portable
            $env:SWEEPR_DATA_DIR = Join-Path $root 'data'
            $before = Get-TreeSnapshot -Path $root
            $result = Invoke-FakeCommand -Script (Join-Path $root 'bin/remove.ps1') -Stdin 'y'
            $result.ExitCode | Should -Be 1
            $result.Output | Should -Match 'Sweepr portable leaves nothing outside its folder'
            Get-TreeSnapshot -Path $root | Should -BeExactly $before
        }

        It 'Refuses even when SWEEPR_DATA_DIR points somewhere else, and that folder is untouched' {
            $root = New-FakeApp -Base $script:Case -Portable
            $elsewhere = Join-Path $script:Case 'elsewhere'
            New-Item -ItemType Directory -Path (Join-Path $elsewhere 'config') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $elsewhere 'config/whitelist.txt') -Value 'mine'
            $env:SWEEPR_DATA_DIR = $elsewhere
            $before = Get-TreeSnapshot -Path $root
            $elsewhereBefore = Get-TreeSnapshot -Path $elsewhere
            $result = Invoke-FakeCommand -Script (Join-Path $root 'bin/remove.ps1') -Stdin 'y'
            $result.ExitCode | Should -Be 1
            Get-TreeSnapshot -Path $root | Should -BeExactly $before
            Get-TreeSnapshot -Path $elsewhere | Should -BeExactly $elsewhereBefore
        }
    }

    Context 'sw remove with SWEEPR_DATA_DIR but without the marker (override mode)' {
        It 'Still asks and hands over to the installer, and never touches the override folder itself' {
            $root = New-FakeApp -Base $script:Case
            $override = Join-Path $script:Case 'elsewhere'
            New-Item -ItemType Directory -Path (Join-Path $override 'config') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $override 'config/whitelist.txt') -Value 'mine'
            $env:SWEEPR_DATA_DIR = $override
            $overrideBefore = Get-TreeSnapshot -Path $override
            $result = Invoke-FakeCommand -Script (Join-Path $root 'bin/remove.ps1') -Stdin 'y'
            $result.Output | Should -Not -Match 'Sweepr portable leaves nothing'
            Get-Content -LiteralPath (Join-Path $root 'installer-ran.txt') | Should -Match 'Uninstall=True'
            Get-TreeSnapshot -Path $override | Should -BeExactly $overrideBefore
        }
    }
}

Describe 'install.ps1 -Uninstall in portable mode' {
    BeforeAll {
        $installAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:ProjectRoot 'install.ps1'), [ref]$null, [ref]$null)
        foreach ($name in @('Assert-InstallPhysicalPath', 'Get-NormalizedPath', 'Test-ProtectedInstallRoot', 'Get-SweeprInstallEntries', 'Get-SweeprInstallNestedFiles', 'Remove-SweeprNestedFiles', 'Remove-SweeprConfigEntry', 'Test-SweeprInstallDir', 'Uninstall-Sweepr')) {
            $definition = $installAst.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
                }, $true)
            if (-not $definition) { throw "$name not found in install.ps1" }
            . ([scriptblock]::Create($definition.Extent.Text))
            Set-Item -Path "function:script:$name" -Value (Get-Item "function:$name").ScriptBlock
        }
        # Messages are collected through every channel the installer uses.
        function script:Write-Info { param($Message) $script:Said += "$Message" }
        function script:Write-Success { param($Message) $script:Said += "$Message" }
        function script:Write-SweeprWarning { param($Message) $script:Said += "$Message" }
        function script:Write-SweeprError { param($Message) $script:Said += "$Message" }
        function script:Remove-FromUserPath { param($Directory) $script:PathTouched = $true }
        function script:Remove-StartMenuShortcut { param($InstallDir) $script:ShortcutTouched = $true; $true }
        function script:Read-Host { param($Prompt) $script:Prompted = $true; 'y' }

        function script:Get-TreeText {
            param([string]$Path)
            $base = (Get-Item -LiteralPath $Path).FullName.TrimEnd('\', '/')
            $lines = foreach ($item in @(Get-ChildItem -LiteralPath $Path -Recurse -Force)) {
                $rel = $item.FullName.Substring($base.Length).Replace('\', '/')
                if ($item.PSIsContainer) { "D $rel" } else { "F $rel :: " + [IO.File]::ReadAllText($item.FullName) }
            }
            return (@($lines | Sort-Object) -join "`n")
        }
    }

    BeforeEach {
        $script:Case = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:UserHome = Join-Path $script:Case 'home'
        $script:Root = Join-Path $script:Case 'app'
        New-Item -ItemType Directory -Path $script:UserHome, (Join-Path $script:Root 'lib/core'), (Join-Path $script:Root 'data/config') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Root 'sweepr.ps1') -Value '#'
        Set-Content -LiteralPath (Join-Path $script:Root 'lib/core/base.ps1') -Value '#'
        Set-Content -LiteralPath (Join-Path $script:Root 'sweepr.portable') -Value ''
        Set-Content -LiteralPath (Join-Path $script:Root 'data/config/operations.log') -Value 'REMOVED example'
        $script:SavedLocal = $env:LOCALAPPDATA
        $script:SavedAppData = $env:APPDATA
        $env:LOCALAPPDATA = Join-Path $script:Case 'local'
        $env:APPDATA = Join-Path $script:Case 'roaming'
        $env:USERPROFILE = $script:UserHome
        $env:SWEEPR_DATA_DIR = $null
        $script:Said = @()
        $script:PathTouched = $false
        $script:ShortcutTouched = $false
        $script:Prompted = $false
        $script:InstallDirGiven = $true
        $script:SourceDir = $null
    }

    AfterEach {
        $env:LOCALAPPDATA = $script:SavedLocal
        $env:APPDATA = $script:SavedAppData
        $env:USERPROFILE = $script:SavedProfile
        $env:SWEEPR_DATA_DIR = $script:SavedDataDir
    }

    It 'Refuses a folder with sweepr.portable, says why, and removes nothing' {
        $InstallDir = $script:Root
        $before = Get-TreeText -Path $script:Root
        Uninstall-Sweepr | Should -BeFalse
        Get-TreeText -Path $script:Root | Should -BeExactly $before
        Test-Path -LiteralPath (Join-Path $script:Root 'sweepr.portable') -PathType Leaf | Should -BeTrue
        ($script:Said -join ' ') | Should -Match 'portable'
    }

    It 'Neither touches PATH or shortcuts nor asks about config files' {
        $InstallDir = $script:Root
        Uninstall-Sweepr | Should -BeFalse
        $script:PathTouched | Should -BeFalse
        $script:ShortcutTouched | Should -BeFalse
        $script:Prompted | Should -BeFalse
    }

    It 'Leaves the profile folders alone' {
        $InstallDir = $script:Root
        New-Item -ItemType Directory -Path (Join-Path $script:UserHome '.config/sweepr'), (Join-Path $script:UserHome '.cache/sweepr') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:UserHome '.config/sweepr/whitelist.txt') -Value 'profile data'
        $profileBefore = Get-TreeText -Path $script:UserHome
        Uninstall-Sweepr | Should -BeFalse
        Get-TreeText -Path $script:UserHome | Should -BeExactly $profileBefore
    }

    It 'Refuses regardless of SWEEPR_DATA_DIR (<Where>: set by sweepr.ps1 or by the user)' -ForEach @(
        @{ Where = 'data' }, @{ Where = 'elsewhere' }
    ) {
        $InstallDir = $script:Root
        $env:SWEEPR_DATA_DIR = Join-Path $(if ($Where -eq 'data') { $script:Root } else { $script:Case }) $Where
        if ($Where -eq 'elsewhere') {
            New-Item -ItemType Directory -Path $env:SWEEPR_DATA_DIR -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $env:SWEEPR_DATA_DIR 'keep.txt') -Value 'mine'
        }
        $before = Get-TreeText -Path $script:Root
        Uninstall-Sweepr | Should -BeFalse
        Get-TreeText -Path $script:Root | Should -BeExactly $before
        $script:PathTouched | Should -BeFalse
    }

    It 'Refuses when the folder is found through the script location instead of -InstallDir' {
        $script:InstallDirGiven = $false
        $script:SourceDir = $script:Root
        $before = Get-TreeText -Path $script:Root
        Uninstall-Sweepr | Should -BeFalse
        Get-TreeText -Path $script:Root | Should -BeExactly $before
    }

    It 'Does not treat a sweepr.portable folder as the marker' {
        Remove-Item -LiteralPath (Join-Path $script:Root 'sweepr.portable') -Force
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'sweepr.portable') -Force | Out-Null
        $InstallDir = $script:Root
        Uninstall-Sweepr | Should -Not -BeNullOrEmpty
        $script:PathTouched | Should -BeTrue
    }
}
