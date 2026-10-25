# Sweepr Windows - installer uninstall tests
# %LOCALAPPDATA%\Sweepr may also hold another app's data, so
# removing the CLI must never take that app's files with it.

BeforeAll {
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $installScript = Join-Path $script:WindowsDir "install.ps1"
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($installScript, [ref]$null, [ref]$null)
    foreach ($name in @("Assert-InstallPhysicalPath", "Get-NormalizedPath", "Test-ProtectedInstallRoot", "Get-SweeprInstallEntries", "Get-SweeprInstallNestedFiles", "Remove-SweeprNestedFiles", "Remove-SweeprConfigEntry", "Test-SweeprInstallDir", "Uninstall-Sweepr")) {
        $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true)
        if (-not $definition) { throw "$name not found in install.ps1" }
        . ([scriptblock]::Create($definition.Extent.Text))
        Set-Item -Path "function:script:$name" -Value (Get-Item "function:$name").ScriptBlock
    }

    function Write-Info { param($Message) }
    function Write-Success { param($Message) }
    function Write-SweeprWarning { param($Message) }
    function Write-SweeprError { param($Message) }
    function Remove-FromUserPath { param($Directory) }
    function Remove-StartMenuShortcut { param($InstallDir) $true }

    function New-CliTree {
        param([string]$Root)
        New-Item -ItemType Directory -Path (Join-Path $Root "lib\core"), (Join-Path $Root "bin"), (Join-Path $Root ".git") -Force | Out-Null
        Set-Content -Path (Join-Path $Root "sweepr.ps1") -Value "#"
        Set-Content -Path (Join-Path $Root "lib\core\base.ps1") -Value "#"
        Set-Content -Path (Join-Path $Root "sw.cmd") -Value "@echo off"
        Set-Content -Path (Join-Path $Root "VERSION") -Value "1.30.0"
    }
}

Describe "install.ps1 -Uninstall" {
    BeforeEach {
        $script:SavedLocalAppData = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
        $script:USERPROFILE_SAVED = $env:USERPROFILE
        $env:USERPROFILE = Join-Path $TestDrive "profile-without-config"
        $script:InstallDirGiven = $true
        $script:SourceDir = $null
    }

    AfterEach {
        $env:LOCALAPPDATA = $script:SavedLocalAppData
        $env:USERPROFILE = $script:USERPROFILE_SAVED
    }

    It "Never removes a config folder recursively when it gained an entry after the listing" {
        $dir = Join-Path $TestDrive ("config-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir "late.txt") -Value "x"
        $item = Get-Item -LiteralPath $dir -Force
        Mock Get-ChildItem { @() }
        Mock Remove-Item {} -ParameterFilter { Test-Path -LiteralPath $LiteralPath -PathType Container }

        { Remove-SweeprConfigEntry -Item $item } | Should -Throw
        Should -Invoke Remove-Item -Times 0 -Exactly -ParameterFilter { Test-Path -LiteralPath $LiteralPath -PathType Container }
        Test-Path -LiteralPath (Join-Path $dir "late.txt") | Should -BeTrue
    }

    It "Keeps another app's files when the CLI shares its folder" {
        $shared = Join-Path $env:LOCALAPPDATA "Sweepr"
        New-CliTree -Root $shared
        Set-Content -Path (Join-Path $shared "license.dat") -Value "license"
        New-Item -ItemType Directory -Path (Join-Path $shared "backups") -Force | Out-Null
        $InstallDir = $shared

        Uninstall-Sweepr | Should -BeTrue

        Test-Path (Join-Path $shared "license.dat") | Should -BeTrue
        Test-Path (Join-Path $shared "backups") | Should -BeTrue
        Test-Path (Join-Path $shared "sweepr.ps1") | Should -BeFalse
        Test-Path (Join-Path $shared "lib") | Should -BeFalse
        Test-Path (Join-Path $shared ".git") | Should -BeFalse
    }

    It "Keeps unrelated files inside common install directories and Git metadata" {
        $shared = Join-Path $env:LOCALAPPDATA "Tools"
        New-CliTree -Root $shared
        Set-Content -LiteralPath (Join-Path $shared "bin\user-tool.exe") -Value "mine"
        Set-Content -LiteralPath (Join-Path $shared "lib\user-library.txt") -Value "mine"
        Set-Content -LiteralPath (Join-Path $shared ".git\config") -Value "user repository"
        $InstallDir = $shared
        Uninstall-Sweepr | Should -BeTrue
        Get-Content -LiteralPath (Join-Path $shared "bin\user-tool.exe") | Should -Be "mine"
        Get-Content -LiteralPath (Join-Path $shared "lib\user-library.txt") | Should -Be "mine"
        Get-Content -LiteralPath (Join-Path $shared ".git\config") | Should -Be "user repository"
        Test-Path -LiteralPath (Join-Path $shared "lib\core\base.ps1") | Should -BeFalse
    }

    It "Keeps a Git worktree pointer when removing Sweepr files" {
        $own = Join-Path $env:LOCALAPPDATA "worktree"
        New-CliTree -Root $own
        [System.IO.Directory]::Delete((Join-Path $own ".git"))
        Set-Content -LiteralPath (Join-Path $own ".git") -Value "gitdir: elsewhere"
        $InstallDir = $own
        Uninstall-Sweepr | Should -BeTrue
        Get-Content -LiteralPath (Join-Path $own ".git") | Should -Be "gitdir: elsewhere"
        Test-Path -LiteralPath (Join-Path $own "sweepr.ps1") | Should -BeFalse
    }

    It "Keeps a linked install directory and the files outside it" {
        $outside = Join-Path $env:LOCALAPPDATA "outside"
        New-CliTree -Root $outside
        $link = Join-Path $env:LOCALAPPDATA "linked"
        $null = New-Item -ItemType Junction -Path $link -Target $outside
        try {
            $InstallDir = $link
            { Uninstall-Sweepr } | Should -Throw '*linked install path*'
            Test-Path -LiteralPath (Join-Path $outside "sweepr.ps1") | Should -BeTrue
        }
        finally { [System.IO.Directory]::Delete($link) }
    }

    It "Removes the docs files Sweepr ships and the folders they leave empty" {
        $own = Join-Path $env:LOCALAPPDATA "Programs\sweepr-cli"
        New-CliTree -Root $own
        foreach ($file in Get-SweeprInstallNestedFiles) {
            $path = Join-Path $own $file
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            Set-Content -Path $path -Value "png"
        }
        $InstallDir = $own

        Uninstall-Sweepr | Should -BeTrue

        Test-Path $own | Should -BeFalse
    }

    It "Keeps a docs folder that holds the user's own files" {
        $shared = Join-Path $env:LOCALAPPDATA "Tools"
        New-CliTree -Root $shared
        New-Item -ItemType Directory -Path (Join-Path $shared "docs") -Force | Out-Null
        Set-Content -Path (Join-Path $shared "docs\development-pitfalls.md") -Value "shipped"
        Set-Content -Path (Join-Path $shared "docs\notes.md") -Value "mine"
        $InstallDir = $shared

        Uninstall-Sweepr | Should -BeTrue

        Test-Path (Join-Path $shared "docs\notes.md") | Should -BeTrue
        Test-Path (Join-Path $shared "docs\development-pitfalls.md") | Should -BeFalse
        Test-Path (Join-Path $shared "sweepr.ps1") | Should -BeFalse
    }

    It "Knows every top-level entry and docs file the repository ships" {
        $known = @(Get-SweeprInstallEntries)
        $nested = @(Get-SweeprInstallNestedFiles)
        $roots = @($nested | ForEach-Object { ($_ -split '\\')[0] } | Select-Object -Unique)
        foreach ($entry in @(Get-ChildItem -LiteralPath $script:WindowsDir -Force)) {
            ($known -contains $entry.Name -or $roots -contains $entry.Name) | Should -BeTrue -Because "$($entry.Name) must be removable by sw remove"
        }
        foreach ($root in $roots) {
            $base = Join-Path $script:WindowsDir $root
            foreach ($file in @(Get-ChildItem -LiteralPath $base -Recurse -File -Force)) {
                $relative = $file.FullName.Substring($script:WindowsDir.TrimEnd('\').Length + 1)
                $nested | Should -Contain $relative
            }
        }
    }

    It "Removes a folder that holds only the CLI" {
        $own = Join-Path $env:LOCALAPPDATA "Programs\sweepr-cli"
        New-CliTree -Root $own
        $InstallDir = $own

        Uninstall-Sweepr | Should -BeTrue

        Test-Path $own | Should -BeFalse
    }

    It "Removes the Sweepr cache with the install and keeps linked targets" {
        $own = Join-Path $env:LOCALAPPDATA "Programs\sweepr-cli"
        New-CliTree -Root $own
        $InstallDir = $own
        $env:USERPROFILE = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        $cache = Join-Path $env:USERPROFILE ".cache\sweepr"
        New-Item -ItemType Directory -Path (Join-Path $cache "old") -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $cache "old\nested.txt") -Value "cache"
        $outside = Join-Path $TestDrive ("outside-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $outside "keep.txt") -Value "mine"
        $null = New-Item -ItemType Junction -Path (Join-Path $cache "linked") -Target $outside
        try {
            Uninstall-Sweepr | Should -BeTrue

            Test-Path -LiteralPath $cache | Should -BeFalse
            Get-Content -LiteralPath (Join-Path $outside "keep.txt") | Should -Be "mine"
        }
        finally {
            $link = Join-Path $cache "linked"
            if (Test-Path -LiteralPath $link) { [System.IO.Directory]::Delete($link) }
        }
    }

    It "Records the cache removal in the operation log" {
        $own = Join-Path $env:LOCALAPPDATA "Programs\sweepr-cli"
        New-CliTree -Root $own
        $InstallDir = $own
        $env:USERPROFILE = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path (Join-Path $env:USERPROFILE ".cache\sweepr") -Force | Out-Null
        $global:UninstallOps = @()
        function global:Write-SweeprOperation {
            param($Action, $Path, $Detail)
            $global:UninstallOps += "$Action $Path $Detail"
        }
        try {
            Uninstall-Sweepr | Should -BeTrue
        }
        finally {
            Remove-Item function:global:Write-SweeprOperation -ErrorAction SilentlyContinue
        }
        ($global:UninstallOps -join "`n") | Should -Match 'REMOVED .*\.cache\\sweepr cache'
    }

    It "Keeps the Sweepr cache when the folder is not a Sweepr install" {
        $other = Join-Path $env:LOCALAPPDATA "NotSweepr"
        New-Item -ItemType Directory -Path $other -Force | Out-Null
        $InstallDir = $other
        $env:USERPROFILE = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        $cache = Join-Path $env:USERPROFILE ".cache\sweepr"
        New-Item -ItemType Directory -Path $cache -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $cache "keep.txt") -Value "cache"

        Uninstall-Sweepr | Should -BeFalse

        Test-Path -LiteralPath (Join-Path $cache "keep.txt") | Should -BeTrue
    }

    It "Keeps the operation log when the user removes the config files" {
        $own = Join-Path $env:LOCALAPPDATA "Programs\sweepr-cli"
        New-CliTree -Root $own
        $InstallDir = $own
        $env:USERPROFILE = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        $config = Join-Path $env:USERPROFILE ".config\sweepr"
        New-Item -ItemType Directory -Path (Join-Path $config "cache") -Force | Out-Null
        foreach ($name in @("operations.log", "operations.log.old", "whitelist.txt", "sweepr_debug_session.log", "cache\apps.json")) {
            Set-Content -LiteralPath (Join-Path $config $name) -Value $name
        }
        Mock Read-Host { "y" }

        Uninstall-Sweepr | Should -BeTrue

        Get-Content -LiteralPath (Join-Path $config "operations.log") | Should -Be "operations.log"
        Get-Content -LiteralPath (Join-Path $config "operations.log.old") | Should -Be "operations.log.old"
        @(Get-ChildItem -LiteralPath $config -Force | ForEach-Object Name | Sort-Object) | Should -Be @("operations.log", "operations.log.old")
    }

    It "Removes the config folder when it holds no operation log" {
        $own = Join-Path $env:LOCALAPPDATA "Programs\sweepr-cli"
        New-CliTree -Root $own
        $InstallDir = $own
        $env:USERPROFILE = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        $config = Join-Path $env:USERPROFILE ".config\sweepr"
        New-Item -ItemType Directory -Path $config -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $config "whitelist.txt") -Value "x"
        Mock Read-Host { "y" }

        Uninstall-Sweepr | Should -BeTrue

        Test-Path -LiteralPath $config | Should -BeFalse
    }

    It "Removes an unlocked native launcher through the PowerShell entrypoint" {
        $own = Join-Path $env:LOCALAPPDATA "Programs\sweepr-cli"
        New-CliTree -Root $own
        $InstallDir = $own
        Set-Content -LiteralPath (Join-Path $own 'sw.exe') -Value 'fixture'

        Uninstall-Sweepr | Should -BeTrue

        Test-Path -LiteralPath $own | Should -BeFalse
    }

    It "Refuses a locked native launcher before changing any install files or PATH" {
        $own = Join-Path $env:LOCALAPPDATA "Programs\sweepr's cli"
        New-CliTree -Root $own
        $InstallDir = $own
        $exe = Join-Path $own 'sw.exe'
        Set-Content -LiteralPath $exe -Value 'locked fixture'
        Mock Remove-FromUserPath {}
        Mock Remove-StartMenuShortcut { $true }
        Mock Write-Info {}
        $expectedCommand = "Close other Sweepr sessions, then run in PowerShell: & '" + (Join-Path $own 'sweepr.ps1').Replace("'", "''") + "' remove"
        $handle = [IO.File]::Open($exe, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            Uninstall-Sweepr | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $own 'lib\core\base.ps1') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $own 'VERSION') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $own 'sw.cmd') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $own 'sweepr.ps1') | Should -BeTrue
            Should -Invoke Remove-FromUserPath -Times 0 -Exactly
            Should -Invoke Remove-StartMenuShortcut -Times 0 -Exactly
            Should -Invoke Write-Info -Times 1 -Exactly -ParameterFilter { $Message -eq $expectedCommand }
        }
        finally { $handle.Dispose() }
    }

    It "Keeps config behind a junction at <LinkedPart>" -TestCases @(
        @{ LinkedPart = 'sweepr' }
        @{ LinkedPart = '.config' }
    ) {
        param($LinkedPart)
        $own = Join-Path $env:LOCALAPPDATA "Programs\sweepr-cli"
        New-CliTree -Root $own
        $InstallDir = $own
        $env:USERPROFILE = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        $outside = Join-Path $env:LOCALAPPDATA "outside"
        New-Item -ItemType Directory -Path $outside, $env:USERPROFILE -Force | Out-Null
        if ($LinkedPart -eq 'sweepr') {
            New-Item -ItemType Directory -Path (Join-Path $env:USERPROFILE '.config') -Force | Out-Null
            $link = Join-Path $env:USERPROFILE '.config\sweepr'
            $sentinel = Join-Path $outside 'keep.txt'
        }
        else {
            New-Item -ItemType Directory -Path (Join-Path $outside 'sweepr') -Force | Out-Null
            $link = Join-Path $env:USERPROFILE '.config'
            $sentinel = Join-Path $outside 'sweepr\keep.txt'
        }
        Set-Content -LiteralPath $sentinel -Value 'keep'
        $null = New-Item -ItemType Junction -Path $link -Target $outside
        Mock Read-Host { 'y' }
        try {
            Uninstall-Sweepr | Should -BeTrue
            Get-Content -LiteralPath $sentinel | Should -Be 'keep'
            Test-Path -LiteralPath $link | Should -BeTrue
        }
        finally {
            if (Test-Path -LiteralPath $link) { [System.IO.Directory]::Delete($link) }
        }
    }

    It "Unlinks a junction in the config folder and keeps its target's files" {
        $own = Join-Path $env:LOCALAPPDATA "Programs\sweepr-cli"
        New-CliTree -Root $own
        $InstallDir = $own
        $env:USERPROFILE = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        $config = Join-Path $env:USERPROFILE ".config\sweepr"
        New-Item -ItemType Directory -Path (Join-Path $config "cache") -Force | Out-Null
        $outside = Join-Path $env:LOCALAPPDATA "outside"
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $outside "keep.txt") -Value "keep"
        $link = Join-Path $config "linked"
        $nested = Join-Path $config "cache\linked"
        $null = New-Item -ItemType Junction -Path $link -Target $outside
        $null = New-Item -ItemType Junction -Path $nested -Target $outside
        Mock Read-Host { "y" }

        try {
            Uninstall-Sweepr | Should -BeTrue

            Get-Content -LiteralPath (Join-Path $outside "keep.txt") | Should -Be "keep"
            Test-Path -LiteralPath $link | Should -BeFalse
            Test-Path -LiteralPath $nested | Should -BeFalse
            Test-Path -LiteralPath $config | Should -BeFalse
        }
        finally {
            foreach ($path in @($link, $nested)) {
                if (Test-Path -LiteralPath $path) { [System.IO.Directory]::Delete($path) }
            }
        }
    }

    It "Removes nothing from a folder that is not a Sweepr install" {
        $appData = Join-Path $env:LOCALAPPDATA "Sweepr"
        New-Item -ItemType Directory -Path $appData -Force | Out-Null
        Set-Content -Path (Join-Path $appData "license.dat") -Value "license"
        Set-Content -Path (Join-Path $appData "VERSION") -Value "app"
        $InstallDir = $appData

        Uninstall-Sweepr | Should -BeFalse

        Test-Path (Join-Path $appData "license.dat") | Should -BeTrue
        Test-Path (Join-Path $appData "VERSION") | Should -BeTrue
    }

    It "Never falls back to %LOCALAPPDATA%\Sweepr when the install folder is gone" {
        $appData = Join-Path $env:LOCALAPPDATA "Sweepr"
        New-Item -ItemType Directory -Path $appData -Force | Out-Null
        Set-Content -Path (Join-Path $appData "license.dat") -Value "license"
        $InstallDir = Join-Path $env:LOCALAPPDATA "Programs\sweepr-cli"

        Uninstall-Sweepr | Should -BeTrue

        Test-Path (Join-Path $appData "license.dat") | Should -BeTrue
    }
}

Describe "Start menu shortcut removal" {
    BeforeAll {
        $installScript = Join-Path $script:WindowsDir "install.ps1"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($installScript, [ref]$null, [ref]$null)
        $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Remove-StartMenuShortcut"
            }, $true)
        $text = $definition.Extent.Text -replace '^function Remove-StartMenuShortcut', 'function Remove-ShortcutUnderTest'
        . ([scriptblock]::Create($text))
        Set-Item -Path "function:script:Remove-ShortcutUnderTest" -Value (Get-Item "function:Remove-ShortcutUnderTest").ScriptBlock

        function New-TestShortcut {
            param([string]$Path, [string]$Target, [string]$Arguments)
            $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
            $shortcut.TargetPath = $Target
            $shortcut.Arguments = $Arguments
            $shortcut.Save()
        }
    }

    It "Removes this install's shortcut and keeps another app's" {
        $programs = Join-Path $TestDrive "Programs"
        New-Item -ItemType Directory -Path $programs -Force | Out-Null
        $install = Join-Path $TestDrive "sweepr-cli"
        New-TestShortcut -Path (Join-Path $programs "Sweepr.lnk") -Target (Join-Path $TestDrive "Vendor.App\Sweepr.exe") -Arguments ""
        New-TestShortcut -Path (Join-Path $programs "Sweepr CLI.lnk") -Target "powershell.exe" -Arguments "-NoExit -ExecutionPolicy Bypass -File `"$install\sweepr.ps1`""

        Remove-ShortcutUnderTest -InstallDir $install -ProgramsPath $programs | Should -BeTrue

        Test-Path (Join-Path $programs "Sweepr.lnk") | Should -BeTrue
        Test-Path (Join-Path $programs "Sweepr CLI.lnk") | Should -BeFalse
    }

    It "Removes a 1.30.0 Sweepr.lnk that starts this install" {
        $programs = Join-Path $TestDrive "Programs-legacy"
        New-Item -ItemType Directory -Path $programs -Force | Out-Null
        $install = Join-Path $TestDrive "legacy-install"
        New-TestShortcut -Path (Join-Path $programs "Sweepr.lnk") -Target "powershell.exe" -Arguments "-NoExit -ExecutionPolicy Bypass -File `"$install\sweepr.ps1`""

        Remove-ShortcutUnderTest -InstallDir $install -ProgramsPath $programs | Should -BeTrue

        Test-Path (Join-Path $programs "Sweepr.lnk") | Should -BeFalse
    }
}
