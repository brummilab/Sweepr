# Sweepr - runtime loader for the router
#
# One dot-source gives the caller the shared PowerShell runtime: version.ps1, base.ps1, log.ps1,
# file_ops.ps1 and ui.ps1, all taken from the folder of this file (never from the working directory
# or caller variables). Loading writes nothing, creates no files and uses no network; loading twice
# is harmless. The update check, TUI download, history and command modules are not loaded here.

. ([System.IO.Path]::Combine($PSScriptRoot, 'version.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'base.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'log.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'file_ops.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'ui.ps1'))

function Get-SwRuntimeInfo {
    <#
    .SYNOPSIS
        Sweepr version, PowerShell version and Windows version for --version and the debug header.
    .DESCRIPTION
        The installation root is two levels above the folder of this file. An error of the Windows
        version query reaches the caller, which decides how to report it.
    #>
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $windows = Get-WindowsVersion
    return @{
        Version    = [string](Get-SwInstalledVersion -RootDir $root)
        PowerShell = [string]$PSVersionTable.PSVersion.ToString()
        Windows    = [string]$windows['Version']
    }
}

function Initialize-SwDataFolders {
    <#
    .SYNOPSIS
        Makes sure the config and cache folders of the current data mode exist.
    .DESCRIPTION
        The folders come from base.ps1 (profile, portable or SWEEPR_DATA_DIR). Existing folders and
        their content stay as they are. A folder that cannot be created is a terminating error; the
        router checks beforehand that the data folder is writable and explains it to the user.
    #>
    $ErrorActionPreference = 'Stop'
    foreach ($path in @((Get-ConfigPath), (Get-CachePath))) {
        # The base functions report a failure as an error record; make sure it really stops here.
        if (-not [System.IO.Directory]::Exists([string]$path)) {
            throw "Cannot create the Sweepr data folder: $path"
        }
    }
}

# Old names, kept as forwarding functions (not aliases, so test mocks of either name behave) until the
# router is rewritten.
function Get-SweeprVersion { Get-SwRuntimeInfo }

function Initialize-Sweepr { Initialize-SwDataFolders }

# The router relies on these for the rest of its run.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
