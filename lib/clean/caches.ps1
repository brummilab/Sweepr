# Sweepr - cache sections of sw clean: browser caches, application caches, GPU shader caches
#
# The sections "Browser caches", "Application caches" and "GPU shader caches". Loaded by
# dot-sourcing; it loads cache_guard.ps1 for the owner probe, the cache cleaner and the profile
# discovery. Loading writes nothing, creates no file or folder and starts no process; it only
# defines functions. A second load in the same scope changes nothing.
#
# Only the folders named in the tables below are ever offered, and the sections never remove anything
# themselves: a cache folder goes to Clear-SwAppCache (which keeps it while its owner may be working),
# a shader cache folder to Clear-SwDirectoryContents. Cookies, logins, offline data and the state of
# a program are never in a table. A path that is, or lies below, a path already offered in the same
# run is not offered again.

# The dependencies come from the folder of this file, never from the working directory.
. ([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PSScriptRoot), 'core', 'base.ps1'))
. ([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PSScriptRoot), 'core', 'log.ps1'))
. ([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PSScriptRoot), 'core', 'file_ops.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'cache_guard.ps1'))

# ============================================================================
# Small helpers
# ============================================================================

function Invoke-SwCleanCacheOffer {
    # Hands one cache folder to the cache cleaner, once per run: a folder at or below a path that was
    # offered before is skipped. A failure stops only this folder.
    param(
        [string]$Path,
        [string]$Description,
        [string[]]$Processes,
        [string]$LockPath,
        $Offered
    )

    try {
        if (Test-SwCleanOffered -Path $Path -Offered $Offered) { return }
        Add-SwCleanOffered -Path $Path -Offered $Offered
        if ([string]::IsNullOrEmpty($LockPath)) { $null = Clear-SwAppCache -Path $Path -Description $Description -Processes $Processes }
        else { $null = Clear-SwAppCache -Path $Path -Description $Description -Processes $Processes -LockPath $LockPath }
    }
    catch { Write-SwDebug "cache not offered, ${Path}: $($_.Exception.Message)" }
}

function Get-SwCleanProfileFolders {
    # The profile folders below a root, as full paths; nothing when the discovery fails.
    param([string]$Root)

    try { return @(Get-SwCacheProfiles -Root $Root | ForEach-Object { [string]$_.FullName }) }
    catch {
        Write-SwDebug "profiles not listed, ${Root}: $($_.Exception.Message)"
        return @()
    }
}

# ============================================================================
# Browser caches
# ============================================================================

function Clear-SwBrowserCaches {
    <#
    .SYNOPSIS
        The section "Browser caches": Chrome, Edge, Brave, Vivaldi, Firefox and Opera.
    .DESCRIPTION
        Chromium browsers: the cache folders of the root first, then Cache, Code Cache and GPUCache of
        every profile. Firefox: the local cache folders with the lock file of the roaming profile, and
        the shader cache of the roaming profile; the roaming cache2 is profile data and stays. Opera:
        the same three folders in the root itself (older layout) and in every profile. Writes nothing
        to the pipeline; a failing target stops only itself.
    #>
    $ErrorActionPreference = 'Stop'
    Start-SwSection 'Browser caches'
    try {
        $offered = [System.Collections.Generic.List[object]]::new()
        $local = Get-SwCleanEnvRoot -Name 'LOCALAPPDATA'
        $roaming = Get-SwCleanEnvRoot -Name 'APPDATA'
        $profileLeaves = @('Cache', 'Code Cache', 'GPUCache')

        $chromium = @(
            @{ Name = 'Chrome'; Process = 'chrome'; Rest = @('Google', 'Chrome', 'User Data'); RootLeaves = @('ShaderCache', 'GrShaderCache') }
            @{ Name = 'Edge'; Process = 'msedge'; Rest = @('Microsoft', 'Edge', 'User Data'); RootLeaves = @('ShaderCache') }
            @{ Name = 'Brave'; Process = 'brave'; Rest = @('BraveSoftware', 'Brave-Browser', 'User Data'); RootLeaves = @() }
            @{ Name = 'Vivaldi'; Process = 'vivaldi'; Rest = @('Vivaldi', 'User Data'); RootLeaves = @() }
        )
        if ($null -ne $local) {
            foreach ($browser in $chromium) {
                try {
                    $root = Join-SwCleanPath -Base $local -Rest $browser.Rest
                    $lock = Join-SwCleanPath -Base $root -Rest @('lockfile')
                    foreach ($leaf in $browser.RootLeaves) {
                        Invoke-SwCleanCacheOffer -Path (Join-SwCleanPath -Base $root -Rest @($leaf)) -Description ($browser.Name + ' ' + $leaf) -Processes @($browser.Process) -LockPath $lock -Offered $offered
                    }
                    foreach ($profileFolder in (Get-SwCleanProfileFolders -Root $root)) {
                        foreach ($leaf in $profileLeaves) {
                            Invoke-SwCleanCacheOffer -Path (Join-SwCleanPath -Base $profileFolder -Rest @($leaf)) -Description ($browser.Name + ' ' + $leaf) -Processes @($browser.Process) -LockPath $lock -Offered $offered
                        }
                    }
                }
                catch { Write-SwDebug "$($browser.Name) caches not handled: $($_.Exception.Message)" }
            }
        }

        # Firefox keeps its caches in the local profile and its lock file in the roaming one, so the
        # local part needs both variables.
        if ($null -ne $local -and $null -ne $roaming) {
            try {
                $localProfiles = Join-SwCleanPath -Base $local -Rest @('Mozilla', 'Firefox', 'Profiles')
                $roamingProfiles = Join-SwCleanPath -Base $roaming -Rest @('Mozilla', 'Firefox', 'Profiles')
                foreach ($profileFolder in (Get-SwCleanProfileFolders -Root $localProfiles)) {
                    $lock = Join-SwCleanPath -Base $roamingProfiles -Rest @([System.IO.Path]::GetFileName($profileFolder), 'parent.lock')
                    foreach ($leaf in 'cache2', 'startupCache') {
                        Invoke-SwCleanCacheOffer -Path (Join-SwCleanPath -Base $profileFolder -Rest @($leaf)) -Description 'Firefox cache' -Processes @('firefox') -LockPath $lock -Offered $offered
                    }
                }
            }
            catch { Write-SwDebug "Firefox caches not handled: $($_.Exception.Message)" }
        }
        if ($null -ne $roaming) {
            try {
                $roamingProfiles = Join-SwCleanPath -Base $roaming -Rest @('Mozilla', 'Firefox', 'Profiles')
                foreach ($profileFolder in (Get-SwCleanProfileFolders -Root $roamingProfiles)) {
                    $lock = Join-SwCleanPath -Base $profileFolder -Rest @('parent.lock')
                    Invoke-SwCleanCacheOffer -Path (Join-SwCleanPath -Base $profileFolder -Rest @('shader-cache')) -Description 'Firefox cache' -Processes @('firefox') -LockPath $lock -Offered $offered
                }
            }
            catch { Write-SwDebug "Firefox shader caches not handled: $($_.Exception.Message)" }
        }

        # Opera: the root itself counts as a candidate, because older versions kept the caches there.
        $operaRoots = [System.Collections.Generic.List[string]]::new()
        if ($null -ne $roaming) { $operaRoots.Add((Join-SwCleanPath -Base $roaming -Rest @('Opera Software', 'Opera Stable'))) }
        if ($null -ne $local) { $operaRoots.Add((Join-SwCleanPath -Base $local -Rest @('Opera Software', 'Opera Stable'))) }
        foreach ($root in $operaRoots) {
            try {
                $lock = Join-SwCleanPath -Base $root -Rest @('lockfile')
                $candidates = @($root) + @(Get-SwCleanProfileFolders -Root $root)
                foreach ($candidate in $candidates) {
                    foreach ($leaf in $profileLeaves) {
                        Invoke-SwCleanCacheOffer -Path (Join-SwCleanPath -Base $candidate -Rest @($leaf)) -Description 'Opera cache' -Processes @('opera') -LockPath $lock -Offered $offered
                    }
                }
            }
            catch { Write-SwDebug "Opera caches not handled: $($_.Exception.Message)" }
        }
    }
    finally { Stop-SwSection }
}

# ============================================================================
# Application caches
# ============================================================================

function Clear-SwAppCaches {
    <#
    .SYNOPSIS
        The section "Application caches": Discord, Slack, Teams (classic and new), Cursor, Windsurf,
        Obsidian and Notion.
    .DESCRIPTION
        Only the named cache folders are offered, never the folder of the application itself and
        never its storage, offline data or databases. The cache folders of the new Teams lie in its
        web view profiles. Writes nothing to the pipeline; a failing target stops only itself.
    #>
    $ErrorActionPreference = 'Stop'
    Start-SwSection 'Application caches'
    try {
        $offered = [System.Collections.Generic.List[object]]::new()
        $local = Get-SwCleanEnvRoot -Name 'LOCALAPPDATA'
        $roaming = Get-SwCleanEnvRoot -Name 'APPDATA'
        $leaves = @('Cache', 'Code Cache', 'GPUCache')

        if ($null -ne $roaming) {
            $roamingApps = @(
                @{ Folder = @('discord'); Process = 'discord'; Description = 'Discord cache'; Leaves = $leaves }
                @{ Folder = @('Slack'); Process = 'slack'; Description = 'Slack cache'; Leaves = $leaves }
                @{ Folder = @('Microsoft', 'Teams'); Process = 'Teams'; Description = 'Teams cache'; Leaves = @('Cache', 'GPUCache') }
                @{ Folder = @('Cursor'); Process = 'Cursor'; Description = 'Cursor cache'; Leaves = $leaves }
                @{ Folder = @('Windsurf'); Process = 'Windsurf'; Description = 'Windsurf cache'; Leaves = $leaves }
                @{ Folder = @('Obsidian'); Process = 'Obsidian'; Description = 'Obsidian cache'; Leaves = $leaves }
                @{ Folder = @('Notion'); Process = 'Notion'; Description = 'Notion cache'; Leaves = $leaves }
            )
            foreach ($app in $roamingApps) {
                try {
                    $root = Join-SwCleanPath -Base $roaming -Rest $app.Folder
                    foreach ($leaf in $app.Leaves) {
                        Invoke-SwCleanCacheOffer -Path (Join-SwCleanPath -Base $root -Rest @($leaf)) -Description $app.Description -Processes @($app.Process) -LockPath '' -Offered $offered
                    }
                }
                catch { Write-SwDebug "$($app.Description) not handled: $($_.Exception.Message)" }
            }
        }

        # The new Teams keeps its caches in the profiles of its web view; the folders at the root of
        # the web view are no profile and stay.
        if ($null -ne $local) {
            try {
                $webView = Join-SwCleanPath -Base $local -Rest @('Packages', 'MSTeams_8wekyb3d8bbwe', 'LocalCache', 'Microsoft', 'MSTeams', 'EBWebView')
                $lock = Join-SwCleanPath -Base $webView -Rest @('lockfile')
                foreach ($profileFolder in (Get-SwCleanProfileFolders -Root $webView)) {
                    foreach ($leaf in $leaves) {
                        Invoke-SwCleanCacheOffer -Path (Join-SwCleanPath -Base $profileFolder -Rest @($leaf)) -Description 'Teams cache' -Processes @('ms-teams') -LockPath $lock -Offered $offered
                    }
                }
            }
            catch { Write-SwDebug "Teams caches not handled: $($_.Exception.Message)" }
        }
    }
    finally { Stop-SwSection }
}

# ============================================================================
# GPU shader caches
# ============================================================================

function Clear-SwGpuShaderCaches {
    <#
    .SYNOPSIS
        The section "GPU shader caches": the shader caches of NVIDIA, AMD, Intel and DirectX.
    .DESCRIPTION
        Runs only on request: every game compiles its shaders again at its next start. The content of
        each folder that exists goes to Clear-SwDirectoryContents, the folder itself stays; no owner
        probe is made, files that are in use are reported by the helper. The folder below TEMP is only
        offered when TEMP is a plausible root. Writes nothing to the pipeline.
    #>
    $ErrorActionPreference = 'Stop'
    Start-SwSection 'GPU shader caches'
    try {
        $offered = [System.Collections.Generic.List[object]]::new()
        $targets = @(
            @{ Base = 'LOCALAPPDATA'; Rest = @('NVIDIA', 'DXCache'); Description = 'NVIDIA shader cache' }
            @{ Base = 'LOCALAPPDATA'; Rest = @('NVIDIA', 'GLCache'); Description = 'NVIDIA shader cache' }
            @{ Base = 'LOCALAPPDATA'; Rest = @('NVIDIA Corporation', 'NV_Cache'); Description = 'NVIDIA shader cache' }
            @{ Base = 'TEMP'; Rest = @('NVIDIA Corporation', 'NV_Cache'); Description = 'NVIDIA shader cache' }
            @{ Base = 'LOCALAPPDATA'; Rest = @('AMD', 'DXCache'); Description = 'AMD shader cache' }
            @{ Base = 'LOCALAPPDATA'; Rest = @('AMD', 'GLCache'); Description = 'AMD shader cache' }
            @{ Base = 'LOCALAPPDATA'; Rest = @('AMD', 'VkCache'); Description = 'AMD shader cache' }
            @{ Base = 'LOCALAPPDATA'; Rest = @('Intel', 'ShaderCache'); Description = 'Intel shader cache' }
            @{ Base = 'APPDATA'; Rest = @('Intel', 'ShaderCache'); Description = 'Intel shader cache' }
            @{ Base = 'LOCALAPPDATA'; Rest = @('D3DSCache'); Description = 'DirectX shader cache' }
            @{ Base = 'LOCALAPPDATA'; Rest = @('Microsoft', 'DirectX Shader Cache'); Description = 'DirectX pipeline cache' }
            @{ Base = 'LOCALAPPDATA'; Rest = @('VulkanCache'); Description = 'Vulkan pipeline cache' }
        )
        foreach ($target in $targets) {
            try {
                $base = Get-SwCleanEnvRoot -Name $target.Base
                if ($null -eq $base) { continue }
                $folder = Join-SwCleanPath -Base $base -Rest $target.Rest
                if (-not (Test-SwCleanDirectory -Path $folder)) { continue }
                # TEMP is the only base that a user can point at anything: the folder below it counts
                # only when TEMP itself is a plausible root.
                if ($target.Base -eq 'TEMP' -and -not (Test-SwCleanRootPlausible -Root $base)) {
                    Add-SwCleanNotMeasured -Name $target.Description -Reason 'not verified'
                    continue
                }
                if (Test-SwCleanOffered -Path $folder -Offered $offered) { continue }
                Add-SwCleanOffered -Path $folder -Offered $offered
                $null = Clear-SwDirectoryContents -Path $folder -Description $target.Description
            }
            catch { Write-SwDebug "shader cache not offered, $($target.Description): $($_.Exception.Message)" }
        }
    }
    finally { Stop-SwSection }
}

# ============================================================================
# Old names, kept as forwarding functions (not aliases, so a test mock of either name behaves) until
# the callers move to the new ones.
# ============================================================================

function Clear-BrowserCaches { Clear-SwBrowserCaches }

function Clear-AppCaches { Clear-SwAppCaches }

function Clear-GPUShaderCaches { Clear-SwGpuShaderCaches }

# Other modules rely on these for the rest of their run.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
