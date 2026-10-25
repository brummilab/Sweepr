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
