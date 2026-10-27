# Sweepr - tests for lib\core\common.ps1
#
# Written from the spec only. Covers the load contract (2.1), rules V-1 to V-7, the non-goals (5) and the
# transition names (L7-1: old names stay as forwarding functions, not aliases).
#
# Interface pinned here (spec 2.2, L7-7):
#   Get-SwRuntimeInfo          hashtable Version, PowerShell, Windows (V-1 to V-4)
#   Initialize-SwDataFolders   creates the config and cache folder of the current data paths (V-5 to V-7)
#   Get-SweeprVersion / Initialize-Sweepr   old names, forwarding functions
#
# Platform neutral: the Windows version query (Get-WindowsVersion from base.ps1) is mocked, the data
# folders live in $TestDrive. Loading tests run in a child PowerShell against a copy of lib\core in a fake
# installation root, so the folder of common.ps1 decides the root (not the working directory).

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:CoreDir = Join-Path $script:RepoRoot 'lib\core'
    . (Join-Path $script:CoreDir 'common.ps1')

    function script:Invoke-ChildPowerShell {
        param([string]$Script, [string]$WorkingDirectory = $TestDrive, [hashtable]$Environment = @{}, [string[]]$RemoveEnvironment = @())
        $exe = (Get-Process -Id $PID).Path
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Script))
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.WorkingDirectory = $WorkingDirectory
        foreach ($name in $RemoveEnvironment) { if ($psi.EnvironmentVariables.ContainsKey($name)) { $psi.EnvironmentVariables.Remove($name) } }
        foreach ($name in $Environment.Keys) { $psi.EnvironmentVariables[$name] = [string]$Environment[$name] }
        $process = [System.Diagnostics.Process]::Start($psi)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { $process.Kill(); throw 'child PowerShell timed out' }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Out = $stdout.Result; Err = $stderr.Result }
    }

    function script:ConvertTo-Literal([string]$Value) { "'" + $Value.Replace("'", "''") + "'" }

    # A fake installation: <root>\VERSION and a copy of lib\core.
    function script:New-FakeInstall {
        param([string]$Name, [string]$Version)
        $root = Join-Path $TestDrive $Name
        $core = Join-Path $root 'lib'
        New-Item -ItemType Directory -Path $core -Force | Out-Null
        Copy-Item -LiteralPath $script:CoreDir -Destination $core -Recurse -Force
        [System.IO.File]::WriteAllText((Join-Path $root 'VERSION'), "$Version`r`n")
        return $root
    }
}

Describe 'Sw common loader' {
    BeforeAll {
        $script:FakeRoot = New-FakeInstall -Name 'fake-install' -Version '7.7.7'
        $script:FakeProfile = Join-Path $TestDrive 'fake-profile'
        $script:OtherCwd = Join-Path $TestDrive 'elsewhere'
        New-Item -ItemType Directory -Path $script:FakeProfile, $script:OtherCwd -Force | Out-Null
        # A decoy lib\core under the working directory must not be used.
        New-Item -ItemType Directory -Path (Join-Path $script:OtherCwd 'lib\core') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:OtherCwd 'VERSION'), '6.6.6')

        $common = ConvertTo-Literal (Join-Path $script:FakeRoot 'lib\core\common.ps1')
        $names = "'Get-SwInstalledVersion','Repair-SwModuleSearchPath','Get-CachePath','Get-ConfigPath','Write-Info','Stop-Spinner'," +
            "'Test-SafePath','Format-SwSizeRow','Show-SwResultFrame','Show-SwLogo','Get-SwConsoleSize','Measure-SwDisplayWidth'," +
            "'Get-SwRuntimeInfo','Initialize-SwDataFolders','Get-SweeprVersion','Initialize-Sweepr'"
        $script:LoadResult = Invoke-ChildPowerShell -WorkingDirectory $script:OtherCwd -RemoveEnvironment @('SWEEPR_DATA_DIR') -Environment @{
            USERPROFILE = $script:FakeProfile
            HOME        = $script:FakeProfile
        } -Script @"
Set-StrictMode -Off
`$ErrorActionPreference = 'Continue'
`$script:SWEEPR_ROOT = 'router-root'
`$script:SWEEPR_VER = 'router-ver'
`$scriptDir = 'caller-dir'
. $common
. $common
'##RESULT##'
`$r = [ordered]@{}
`$r.Eap = [string]`$ErrorActionPreference
`$r.Strict = try { `$null = `$notDefinedAnywhere; 'off' } catch { 'on' }
`$r.Root = `$script:SWEEPR_ROOT
`$r.Ver = `$script:SWEEPR_VER
`$r.Missing = @(foreach (`$n in @($names)) { if (-not (Get-Command `$n -ErrorAction SilentlyContinue)) { `$n } })
`$r.UpdateCheck = @(foreach (`$n in @('Test-SwUpdateHintAllowed','Start-SwUpdateProbe','Start-SweeprUpdateCheck','Show-SweeprUpdateNotice')) { if (Get-Command `$n -ErrorAction SilentlyContinue) { `$n } })
function Get-WindowsVersion { @{ Name = 'Windows'; Version = '10.0.19045'; Build = '19045'; Arch = 'x64' } }
`$r.Version = [string](Get-SwRuntimeInfo).Version
`$r | ConvertTo-Json -Compress
"@
        $parts = $script:LoadResult.Out -split '##RESULT##'
        $script:LoadOutput = $parts[0]
        $script:LoadData = if ($parts.Count -gt 1) { $parts[1].Trim() | ConvertFrom-Json } else { $null }
    }

    It 'Loads twice in one scope without error' {
        $script:LoadResult.ExitCode | Should -Be 0
        $script:LoadData | Should -Not -BeNullOrEmpty
    }

    It 'Writes nothing while loading (2.1)' {
        $script:LoadOutput.Trim() | Should -BeNullOrEmpty
    }

    It 'Creates no Sweepr files or folders while loading (2.1)' {
        # PowerShell itself may create its own folders in the profile; Sweepr must not create any.
        @(Get-ChildItem -LiteralPath $script:FakeProfile -Force -Recurse | Where-Object { $_.FullName -match '(?i)sweepr' }).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $script:FakeRoot -Force -Recurse -Directory | Where-Object { $_.Name -eq 'data' }).Count | Should -Be 0
    }

    It 'Makes the functions of version, base, log, file_ops and ui available (2.1)' {
        @($script:LoadData.Missing) | Should -BeNullOrEmpty
    }

    It 'Leaves ErrorActionPreference Stop and strict mode Latest in the caller scope (2.1)' {
        $script:LoadData.Eap | Should -Be 'Stop'
        $script:LoadData.Strict | Should -Be 'on'
    }

    It 'Takes the installation root from its own location, not the working directory (2.1, V-1)' {
        $script:LoadData.Version | Should -Be '7.7.7'
    }

    It 'Does not overwrite the router variables (2.3)' {
        $script:LoadData.Root | Should -Be 'router-root'
        $script:LoadData.Ver | Should -Be 'router-ver'
    }

    It 'Does not load the update check (5)' {
        @($script:LoadData.UpdateCheck) | Should -BeNullOrEmpty
    }
}

Describe 'Get-SwRuntimeInfo' {
    BeforeEach {
        Mock Get-WindowsVersion { @{ Name = 'Windows Example'; Version = '10.0.22631'; Build = '22631'; Arch = 'x64' } }
    }

    It 'Returns a hashtable with Version, PowerShell and Windows' {
        $info = Get-SwRuntimeInfo
        $info | Should -BeOfType [hashtable]
        foreach ($key in 'Version', 'PowerShell', 'Windows') { $info.ContainsKey($key) | Should -BeTrue }
    }

    It 'Takes Version from the version module for the installation root (V-1)' {
        (Get-SwRuntimeInfo).Version | Should -BeExactly (Get-SwInstalledVersion -RootDir $script:RepoRoot)
    }

    It 'Reports the full PowerShell version as text (V-2)' {
        $info = Get-SwRuntimeInfo
        $info.PowerShell | Should -BeOfType [string]
        $info.PowerShell | Should -BeExactly $PSVersionTable.PSVersion.ToString()
    }

    It 'Reports the Version field of the Windows version query (V-3)' {
        (Get-SwRuntimeInfo).Windows | Should -BeExactly '10.0.22631'
    }

    It 'Passes an error of the Windows version query to the caller (V-4)' {
        Mock Get-WindowsVersion { throw 'query failed' }
        { Get-SwRuntimeInfo } | Should -Throw '*query failed*'
    }
}

Describe 'Initialize-SwDataFolders' {
    BeforeEach {
        $script:SavedConfigPath = $script:Config.ConfigPath
        $script:SavedCachePath = $script:Config.CachePath
        $script:SavedDataDir = $env:SWEEPR_DATA_DIR
    }
    AfterEach {
        $script:Config.ConfigPath = $script:SavedConfigPath
        $script:Config.CachePath = $script:SavedCachePath
        $env:SWEEPR_DATA_DIR = $script:SavedDataDir
    }

    BeforeAll {
        # Point base.ps1's current data paths (and the override variable) at one folder.
        function script:Use-DataRoot([string]$Root) {
            $env:SWEEPR_DATA_DIR = $Root
            $script:Config.ConfigPath = [System.IO.Path]::Combine($Root, 'config')
            $script:Config.CachePath = [System.IO.Path]::Combine($Root, 'cache')
        }
    }

    It 'Creates the missing config and cache folders (V-5)' {
        $root = Join-Path $TestDrive 'data-new'
        Use-DataRoot $root
        Initialize-SwDataFolders
        [System.IO.Directory]::Exists([System.IO.Path]::Combine($root, 'config')) | Should -BeTrue
        [System.IO.Directory]::Exists([System.IO.Path]::Combine($root, 'cache')) | Should -BeTrue
    }

    It 'Treats brackets in the data path literally (V-5)' {
        $parent = Join-Path $TestDrive 'brackets'
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        # A sibling that the bracket pattern would match as a wildcard.
        New-Item -ItemType Directory -Path (Join-Path $parent 'd') -Force | Out-Null
        $root = [System.IO.Path]::Combine($parent, '[d]')
        [void][System.IO.Directory]::CreateDirectory($root)
        Use-DataRoot $root
        Initialize-SwDataFolders
        [System.IO.Directory]::Exists([System.IO.Path]::Combine($root, 'config')) | Should -BeTrue
        [System.IO.Directory]::Exists([System.IO.Path]::Combine($root, 'cache')) | Should -BeTrue
        @(Get-ChildItem -LiteralPath (Join-Path $parent 'd') -Force).Count | Should -Be 0
    }

    It 'Keeps existing folders and their content (V-6)' {
        $root = Join-Path $TestDrive 'data-existing'
        Use-DataRoot $root
        New-Item -ItemType Directory -Path (Join-Path $root 'config'), (Join-Path $root 'cache') -Force | Out-Null
        $whitelist = Join-Path $root 'config\whitelist.txt'
        $cached = Join-Path $root 'cache\update-check.json'
        [System.IO.File]::WriteAllText($whitelist, 'keep me')
        [System.IO.File]::WriteAllText($cached, '{}')
        Initialize-SwDataFolders
        [System.IO.File]::ReadAllText($whitelist) | Should -BeExactly 'keep me'
        [System.IO.File]::ReadAllText($cached) | Should -BeExactly '{}'
    }

    It 'Writes nothing to the output or the host (V-6)' {
        Use-DataRoot (Join-Path $TestDrive 'data-quiet')
        $records = @(Initialize-SwDataFolders *>&1 | Where-Object { $_ -isnot [System.Management.Automation.DebugRecord] })
        $records.Count | Should -Be 0
    }

    It 'Throws when a folder cannot be created (V-7)' {
        $blocker = Join-Path $TestDrive 'data-is-a-file'
        [System.IO.File]::WriteAllText($blocker, 'not a folder')
        Use-DataRoot $blocker
        Get-Command Initialize-SwDataFolders -CommandType Function -ErrorAction Stop | Out-Null
        { Initialize-SwDataFolders } | Should -Throw
    }
}

Describe 'Sw common transition names (L7-1)' {
    It 'Keeps <Name> as a function, not an alias' -ForEach @(
        @{ Name = 'Get-SweeprVersion' }
        @{ Name = 'Initialize-Sweepr' }
    ) {
        (Get-Command -Name $Name -ErrorAction Stop).CommandType | Should -Be 'Function'
        Get-Alias -Name $Name -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'Get-SweeprVersion returns the same values as Get-SwRuntimeInfo' {
        Mock Get-WindowsVersion { @{ Name = 'Windows Example'; Version = '10.0.22631'; Build = '22631'; Arch = 'x64' } }
        $old = Get-SweeprVersion
        $new = Get-SwRuntimeInfo
        foreach ($key in 'Version', 'PowerShell', 'Windows') { $old[$key] | Should -BeExactly $new[$key] }
    }

    It 'Get-SweeprVersion forwards to Get-SwRuntimeInfo' {
        Mock Get-SwRuntimeInfo { @{ Version = 'forwarded'; PowerShell = 'x'; Windows = 'y' } }
        (Get-SweeprVersion).Version | Should -Be 'forwarded'
        Should -Invoke Get-SwRuntimeInfo -Times 1 -Exactly
    }

    It 'Initialize-Sweepr forwards to Initialize-SwDataFolders' {
        Mock Initialize-SwDataFolders { }
        Initialize-Sweepr
        Should -Invoke Initialize-SwDataFolders -Times 1 -Exactly
    }
}
