# Installer refresh, literal launcher arguments, and package-manager routing.
BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'install.ps1'), [ref]$null, [ref]$null)
    foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        . ([scriptblock]::Create($definition.Extent.Text))
        Set-Item -Path "function:script:$($definition.Name)" -Value (Get-Item "function:$($definition.Name)").ScriptBlock
    }
    . (Join-Path $script:RepoRoot 'lib\core\tui_binaries.ps1')
    $script:RealBuild = (Get-Command -Name Build-SwTuiBinary -CommandType Function).ScriptBlock
    $script:Colors = @{ Red=''; Green=''; Yellow=''; Blue=''; Cyan=''; Gray=''; NC='' }
}

Describe 'Source native tool refresh' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'bin'), (Join-Path $script:Root '.git') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Root 'bin\analyze.exe') -Value 'old'
        Set-Content -LiteralPath (Join-Path $script:Root 'bin\status.exe') -Value 'old'
        Mock Get-SwToolPath { 'C:\Example\Go\bin\go.exe' } -ParameterFilter { $Name -eq 'go' }
        Mock Test-SwSourceMatchesRelease { $false }
        Mock Build-SwTuiBinary { Set-Content -LiteralPath $DestinationPath -Value 'current source'; $true }
        Mock Restore-SwTuiRelease { throw 'A source refresh must not silently use the older tagged binary' }
    }
    It 'Refreshes both existing tools from the current source' {
        Ensure-OptionalTuiTools -RootDir $script:Root 6>$null
        (Get-Content -LiteralPath (Join-Path $script:Root 'bin\analyze.exe') -Raw).Trim() | Should -Be 'current source'
        (Get-Content -LiteralPath (Join-Path $script:Root 'bin\status.exe') -Raw).Trim() | Should -Be 'current source'
        Should -Invoke Build-SwTuiBinary -Times 2 -Exactly
    }
    It 'Uses a verified prebuilt refresh when the local source matches the release' {
        Mock Test-SwSourceMatchesRelease { $true }
        Mock Get-SwToolPath { $null } -ParameterFilter { $Name -eq 'go' }
        Mock Restore-SwTuiRelease { Set-Content -LiteralPath $DestinationPath -Value 'verified release'; 'ok' }
        Ensure-OptionalTuiTools -RootDir $script:Root 6>$null
        (Get-Content -LiteralPath (Join-Path $script:Root 'bin\analyze.exe') -Raw).Trim() | Should -Be 'verified release'
        Should -Invoke Restore-SwTuiRelease -Times 2 -Exactly
        Should -Invoke Build-SwTuiBinary -Times 0
    }
    It 'Keeps old tools and fails when a current source build fails' {
        Mock Build-SwTuiBinary { $false }
        { Ensure-OptionalTuiTools -RootDir $script:Root 6>$null } | Should -Throw '*refresh*'
        (Get-Content -LiteralPath (Join-Path $script:Root 'bin\analyze.exe') -Raw).Trim() | Should -Be 'old'
    }
    It 'Does not claim a successful refresh when Go is unavailable' {
        Mock Get-SwToolPath { $null } -ParameterFilter { $Name -eq 'go' }
        Mock Build-SwTuiBinary { & $script:RealBuild -Name $Name -WindowsDir $WindowsDir -DestinationPath $DestinationPath -SourcePath $SourcePath 6>$null 3>$null }
        { Ensure-OptionalTuiTools -RootDir $script:Root 6>$null } | Should -Throw '*Go*'
        (Get-Content -LiteralPath (Join-Path $script:Root 'bin\analyze.exe') -Raw).Trim() | Should -Be 'old'
    }
}

Describe 'Fresh source install without Go' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'bin'), (Join-Path $script:Root '.git') -Force | Out-Null
        Mock Get-SwToolPath { $null } -ParameterFilter { $Name -eq 'go' }
        Mock Test-SwSourceMatchesRelease { $false }
        Mock Restore-SwTuiRelease { throw 'A source refresh must not silently use the older tagged binary' }
    }
    It 'Warns instead of failing when no tool existed to keep' {
        { Ensure-OptionalTuiTools -RootDir $script:Root 6>$null 3>$null } | Should -Not -Throw
        Test-Path -LiteralPath (Join-Path $script:Root 'bin\analyze.exe') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Root 'bin\status.exe') | Should -BeFalse
    }
    It 'Still fails when only one of two existing tools can be refreshed' {
        Set-Content -LiteralPath (Join-Path $script:Root 'bin\status.exe') -Value 'old'
        { Ensure-OptionalTuiTools -RootDir $script:Root 6>$null 3>$null } | Should -Throw '*status*'
        (Get-Content -LiteralPath (Join-Path $script:Root 'bin\status.exe') -Raw).Trim() | Should -Be 'old'
    }
}

Describe 'Generated cmd launchers' {
    BeforeEach {
        $script:SourceDir = Join-Path $TestDrive "Bob's tools! & files"
        New-Item -ItemType Directory -Path $script:SourceDir -Force | Out-Null
        $script:VERSION = 'test'
        $script:InstallDir = $script:SourceDir
        $script:Force = $false
        $script:AddToPath = $false
        $script:CreateShortcut = $false
        Mock Ensure-OptionalTuiTools {}
        Mock Test-ProtectedInstallRoot { $false }
        @'
[Environment]::GetCommandLineArgs() | Out-Null
[System.IO.File]::WriteAllText($env:SWEEPR_TEST_CAPTURE, (ConvertTo-Json -InputObject @($args) -Compress))
exit 7
'@ | Set-Content -LiteralPath (Join-Path $script:SourceDir 'sweepr.ps1')
        Install-Sweepr 6>$null | Should -BeTrue
    }
    It 'Keeps a launcher symbolic-link target unchanged' -ForEach @('sw.cmd', 'sweepr.cmd') {
        $launcher = Join-Path $script:SourceDir $_
        $target = Join-Path $TestDrive ('outside-' + [guid]::NewGuid().ToString('N') + '.cmd')
        Set-Content -LiteralPath $target -Value 'external launcher'
        Remove-Item -LiteralPath $launcher -Force
        $null = New-Item -ItemType SymbolicLink -Path $launcher -Target $target -ErrorAction Stop
        try {
            { Install-Sweepr 6>$null } | Should -Throw '*linked install path*'
            Get-Content -LiteralPath $target | Should -Be 'external launcher'
        }
        finally { [System.IO.File]::Delete($launcher) }
    }
    It 'Returns the script exit code when removal deletes its running batch file' {
        @'
Remove-Item -LiteralPath (Join-Path $PSScriptRoot 'sw.cmd') -Force
exit 7
'@ | Set-Content -LiteralPath (Join-Path $script:SourceDir 'sweepr.ps1')
        $start = New-Object System.Diagnostics.ProcessStartInfo
        $start.FileName = $env:ComSpec
        $start.UseShellExecute = $false
        $start.Arguments = '/d /s /c ""' + (Join-Path $script:SourceDir 'sw.cmd') + '" remove"'
        $process = [System.Diagnostics.Process]::Start($start)
        $process.WaitForExit()
        $process.ExitCode | Should -Be 7
        $process.Dispose()
        (Join-Path $script:SourceDir 'sw.cmd') | Should -Not -Exist
    }
    It 'Preserves apostrophes, exclamation marks, spaces, metacharacters and long flags' {
        $capture = Join-Path $TestDrive 'literal-args.json'
        $saved = $env:SWEEPR_TEST_CAPTURE
        $env:SWEEPR_TEST_CAPTURE = $capture
        try {
            $start = New-Object System.Diagnostics.ProcessStartInfo
            $start.FileName = $env:ComSpec
            $start.UseShellExecute = $false
            $start.Arguments = '/d /s /c ""' + (Join-Path $script:SourceDir 'sw.cmd') + '" analyze "D:\Bob''s files! & notes" --dry-run "percent%value""'
            $process = [System.Diagnostics.Process]::Start($start)
            $process.WaitForExit()
            $process.ExitCode | Should -Be 7
            $process.Dispose()
            $actual = Get-Content -LiteralPath $capture -Raw | ConvertFrom-Json
            $actual.Count | Should -Be 4
            $actual[0] | Should -Be 'analyze'
            $actual[1] | Should -Be "D:\Bob's files! & notes"
            $actual[2] | Should -Be '--dry-run'
            $actual[3] | Should -Be 'percent%value'
        }
        finally { $env:SWEEPR_TEST_CAPTURE = $saved }
    }
}

Describe 'Copied installation ownership' {
    BeforeEach {
        $script:SourceDir = Join-Path $TestDrive ('copy-source-' + [guid]::NewGuid().ToString('N'))
        $script:InstallDir = Join-Path $TestDrive ('copy-destination-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:SourceDir 'lib\core'), (Join-Path $script:SourceDir 'bin') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:SourceDir 'install.ps1') -Value '# installer'
        Set-Content -LiteralPath (Join-Path $script:SourceDir 'sweepr.ps1') -Value '# entry'
        Set-Content -LiteralPath (Join-Path $script:SourceDir 'lib\core\base.ps1') -Value '# core'
        $script:VERSION = 'test'
        $script:Force = $true
        $script:AddToPath = $false
        $script:CreateShortcut = $false
        Mock Ensure-OptionalTuiTools {}
        Mock Test-ProtectedInstallRoot { $false }
    }
    It 'Copies its installer so the installed remove command can run' {
        Install-Sweepr 6>$null | Should -BeTrue
        Get-Content -LiteralPath (Join-Path $script:InstallDir 'install.ps1') | Should -Be '# installer'
    }
    It 'Installs into a pre-created empty destination' {
        New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null
        Install-Sweepr 6>$null | Should -BeTrue
        Get-Content -LiteralPath (Join-Path $script:InstallDir 'install.ps1') | Should -Be '# installer'
    }
    It 'Preserves unrelated files when force updating a shared install' {
        New-Item -ItemType Directory -Path (Join-Path $script:InstallDir 'bin'), (Join-Path $script:InstallDir 'lib\core') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:InstallDir 'sweepr.ps1') -Value '# old'
        Set-Content -LiteralPath (Join-Path $script:InstallDir 'lib\core\base.ps1') -Value '# old'
        Set-Content -LiteralPath (Join-Path $script:InstallDir 'bin\user-tool.exe') -Value 'mine'
        Install-Sweepr 6>$null | Should -BeTrue
        Get-Content -LiteralPath (Join-Path $script:InstallDir 'bin\user-tool.exe') | Should -Be 'mine'
    }
    It 'Refuses a linked destination ancestor without modifying its target' {
        $outside = Join-Path $TestDrive ('outside-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        $link = Join-Path $TestDrive ('copy-link-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Junction -Path $link -Target $outside
        try {
            $script:InstallDir = Join-Path $link 'sweepr'
            { Install-Sweepr 6>$null } | Should -Throw '*linked install path*'
            @(Get-ChildItem -LiteralPath $outside -Force).Count | Should -Be 0
        }
        finally { [System.IO.Directory]::Delete($link) }
    }
    It 'Refuses force merging into an unrelated directory' {
        New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:InstallDir 'notes.txt') -Value 'mine'
        Install-Sweepr 6>$null | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $script:InstallDir 'notes.txt') | Should -Be 'mine'
        Test-Path -LiteralPath (Join-Path $script:InstallDir 'sweepr.ps1') | Should -BeFalse
    }
}

Describe 'Package manager update without Git' {
    It 'Prints the winget command before requiring Git' {
        $root = Join-Path $TestDrive 'Microsoft\WinGet\Packages\brummilab.Sweepr_fixture'
        New-Item -ItemType Directory -Path (Join-Path $root 'bin') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'bin\update.ps1') -Destination (Join-Path $root 'bin\update.ps1')
        Set-Content -LiteralPath (Join-Path $root 'install.ps1') -Value '# fixture'
        $saved = $env:PATH
        try {
            $env:PATH = ''
            $output = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'bin\update.ps1') 2>&1
            ($output -join "`n") | Should -Match 'winget upgrade brummilab\.Sweepr'
            ($output -join "`n") | Should -Not -Match 'Git is not installed'
        }
        finally { $env:PATH = $saved }
    }
}

# F-01b (Design Rev 2a): with SWEEPR_DATA_DIR set (and no portable marker) the
# uninstaller removes the installation as before, never the override folder,
# and does not touch the profile data folders either: Sweepr kept nothing there.
Describe 'Uninstall in override mode' {
    BeforeAll {
        $script:OvSavedLocal = $env:LOCALAPPDATA
        $script:OvSavedProfile = $env:USERPROFILE
        $script:OvSavedData = $env:SWEEPR_DATA_DIR
        function script:Get-OverrideTree {
            param([string]$Path)
            $base = (Get-Item -LiteralPath $Path).FullName.TrimEnd('\')
            $lines = foreach ($item in @(Get-ChildItem -LiteralPath $Path -Recurse -Force)) {
                $rel = $item.FullName.Substring($base.Length)
                if ($item.PSIsContainer) { "D $rel" } else { "F $rel :: " + [IO.File]::ReadAllText($item.FullName) }
            }
            return (@($lines | Sort-Object) -join "`n")
        }
    }

    AfterAll {
        $env:LOCALAPPDATA = $script:OvSavedLocal
        $env:USERPROFILE = $script:OvSavedProfile
        $env:SWEEPR_DATA_DIR = $script:OvSavedData
    }

    BeforeEach {
        $case = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $env:LOCALAPPDATA = Join-Path $case 'local'
        $script:OvProfile = Join-Path $case 'profile'
        $script:OvRoot = Join-Path $case 'app'
        $script:OvData = Join-Path $case 'elsewhere'
        foreach ($dir in 'lib\core', 'bin', '.git') { New-Item -ItemType Directory -Path (Join-Path $script:OvRoot $dir) -Force | Out-Null }
        Set-Content -LiteralPath (Join-Path $script:OvRoot 'sweepr.ps1') -Value '#'
        Set-Content -LiteralPath (Join-Path $script:OvRoot 'lib\core\base.ps1') -Value '#'
        foreach ($dir in 'config', 'cache') { New-Item -ItemType Directory -Path (Join-Path $script:OvData $dir) -Force | Out-Null }
        Set-Content -LiteralPath (Join-Path $script:OvData 'config\whitelist.txt') -Value 'mine'
        Set-Content -LiteralPath (Join-Path $script:OvData 'config\operations.log') -Value 'REMOVED example'
        Set-Content -LiteralPath (Join-Path $script:OvData 'cache\app_scan_cache_v6.json') -Value '{}'
        New-Item -ItemType Directory -Path (Join-Path $script:OvProfile '.config\sweepr'), (Join-Path $script:OvProfile '.cache\sweepr') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:OvProfile '.config\sweepr\whitelist.txt') -Value 'profile data'
        Set-Content -LiteralPath (Join-Path $script:OvProfile '.cache\sweepr\x.bin') -Value 'profile cache'
        $env:USERPROFILE = $script:OvProfile
        $env:SWEEPR_DATA_DIR = $script:OvData
        $script:InstallDirGiven = $true
        $script:Said = @()
        Mock Remove-FromUserPath { $true }
        Mock Remove-StartMenuShortcut { $true }
        Mock Read-Host { 'y' }
        Mock Write-Host { $script:Said += "$Object" }
        Mock Write-Info { $script:Said += "$Message" }
        Mock Write-Success { $script:Said += "$Message" }
        Mock Write-SweeprWarning { $script:Said += "$Message" }
        Mock Write-SweeprError { $script:Said += "$Message" }
    }

    It 'Removes the installation but never the override folder' {
        $dataBefore = Get-OverrideTree -Path $script:OvData
        $InstallDir = $script:OvRoot
        Uninstall-Sweepr | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:OvRoot 'sweepr.ps1') | Should -BeFalse
        Test-Path -LiteralPath $script:OvData -PathType Container | Should -BeTrue
        Get-OverrideTree -Path $script:OvData | Should -BeExactly $dataBefore
    }

    It 'Leaves the profile data folders alone and does not ask about them' {
        $profileBefore = Get-OverrideTree -Path $script:OvProfile
        $InstallDir = $script:OvRoot
        Uninstall-Sweepr | Should -BeTrue
        Get-OverrideTree -Path $script:OvProfile | Should -BeExactly $profileBefore
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'Names the override folder in a hint' {
        $InstallDir = $script:OvRoot
        Uninstall-Sweepr | Should -BeTrue
        ($script:Said -join "`n") | Should -BeLike "*Your Sweepr data stays in $($script:OvData)*delete it yourself*"
    }
}

# F-01b: the portable check in sw update comes before any Git or installer
# requirement, so it also works on a machine without Git on PATH.
Describe 'Portable update without Git' {
    It 'Prints the portable message with an empty PATH' {
        $root = Join-Path $TestDrive 'portable-app'
        New-Item -ItemType Directory -Path (Join-Path $root 'bin'), (Join-Path $root 'lib'), (Join-Path $root 'data') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'bin\update.ps1') -Destination (Join-Path $root 'bin\update.ps1')
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'lib\core') -Destination (Join-Path $root 'lib\core') -Recurse
        Set-Content -LiteralPath (Join-Path $root 'sweepr.portable') -Value ''
        Set-Content -LiteralPath (Join-Path $root 'install.ps1') -Value '# fixture'
        $saved = $env:PATH
        try {
            $env:PATH = ''
            $output = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'bin\update.ps1') 2>&1
            $code = $LASTEXITCODE
        }
        finally { $env:PATH = $saved }
        $code | Should -Be 1
        ($output -join "`n") | Should -Match 'x64-portable\.zip'
        ($output -join "`n") | Should -Not -Match 'Git is not installed'
        Test-Path -LiteralPath (Join-Path $root 'data') -PathType Container | Should -BeTrue
    }
}
