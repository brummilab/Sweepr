# Sweepr - Update Command
# Updates a source-channel installation from the main branch.

#Requires -Version 5.1
# [CmdletBinding()] makes a stray word an error instead of a silent entry in $args. No alias "debug":
# it would collide with the common parameter -Debug; the router maps --debug to DebugMode itself.
[CmdletBinding()]
param(
    [Alias('d')]
    [switch]$DebugMode,

    [Alias('h')]
    [switch]$ShowHelp
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$windowsDir = Split-Path -Parent $scriptDir
$installScript = Join-Path $windowsDir "install.ps1"
$gitDir = Join-Path $windowsDir ".git"

function Show-UpdateHelp {
    $esc = [char]27
    Write-Host ""
    Write-Host "$esc[1;35msw update$esc[0m - Update the Windows source channel"
    Write-Host ""
    Write-Host "$esc[33mUsage:$esc[0m sw update"
    Write-Host ""
    Write-Host "$esc[33mBehavior:$esc[0m"
    Write-Host "  - Pulls the latest commit from origin/main"
    Write-Host "  - Re-runs the local installer in-place, without the component menu"
    Write-Host "  - analyze/status: if the source matches the release tag, the verified release file"
    Write-Host "    is downloaded; otherwise they are built with Go (if available)"
    Write-Host ""
    Write-Host "$esc[33mNotes:$esc[0m"
    Write-Host "  - Works only for git-based source installs"
    Write-Host "  - Portable copy (sweepr.portable next to sweepr.ps1): not updated in place;"
    Write-Host "    download sweepr-<version>-x64-portable.zip from the Releases page and replace"
    Write-Host "    the program files, keeping the data folder"
    Write-Host "  - winget or Scoop copies: prints that package manager's own command instead"
    Write-Host "  - Legacy copied installs should be reinstalled with quick-install"
    Write-Host "  - Use --debug to include full git output on failures"
    Write-Host ""
}

$script:SweeprGitProxyArguments = $null

# Git ignores the Windows system proxy that PowerShell downloads use, so on a
# machine that reaches GitHub only through that proxy, clone and pull fail
# while every other download works. Pass the system proxy to git for this
# run, unless the user already gave git a proxy of their own.
function Get-SweeprSystemProxy {
    param([Uri]$Target)

    try {
        $proxy = [System.Net.WebRequest]::GetSystemWebProxy().GetProxy($Target)
    }
    catch {
        return $null
    }
    if (-not $proxy -or $proxy.AbsoluteUri -eq $Target.AbsoluteUri) {
        return $null
    }
    return $proxy.AbsoluteUri.TrimEnd('/')
}

function Get-GitProxyArguments {
    if ($null -ne $script:SweeprGitProxyArguments) {
        return $script:SweeprGitProxyArguments
    }
    $script:SweeprGitProxyArguments = @()

    foreach ($name in @("HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY")) {
        if ([Environment]::GetEnvironmentVariable($name) -or [Environment]::GetEnvironmentVariable($name.ToLowerInvariant())) {
            return $script:SweeprGitProxyArguments
        }
    }
    foreach ($key in @("http.proxy", "https.proxy")) {
        try {
            $configured = & git config --get $key 2>$null
        }
        catch {
            $configured = $null
        }
        if ($configured) {
            return $script:SweeprGitProxyArguments
        }
    }

    $proxy = Get-SweeprSystemProxy -Target ([Uri]"https://github.com/")
    if ($proxy) {
        $script:SweeprGitProxyArguments = @("-c", "http.proxy=$proxy")
    }
    return $script:SweeprGitProxyArguments
}

function Invoke-GitCommand {
    param(
        [string]$WorkingDirectory,
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $previousNativeErrorPreference = $null
    $hasNativeErrorPreference = $false

    if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
        $previousNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
        $hasNativeErrorPreference = $true
    }

    try {
        $gitArguments = @()
        if ($WorkingDirectory) {
            $gitArguments += @("-C", $WorkingDirectory)
        }
        $gitArguments += @(Get-GitProxyArguments)
        $gitArguments += $Arguments

        $output = & git @gitArguments 2>&1
        $exitCode = $LASTEXITCODE

        return [pscustomobject]@{
            ExitCode = $exitCode
            Text = ((@($output) | ForEach-Object { "$_" }) -join [Environment]::NewLine).Trim()
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($hasNativeErrorPreference) {
            $PSNativeCommandUseErrorActionPreference = $previousNativeErrorPreference
        }
    }
}

function Mask-GitText {
    param([string]$Text)

    if (-not $Text) {
        return ""
    }

    return ($Text -replace '(https?://)([^/@\s]+)@', '$1***@')
}

function Write-IndentedText {
    param([string]$Text)

    if (-not $Text) {
        return
    }

    foreach ($line in ($Text -split "`r?`n")) {
        Write-Host "    $line"
    }
}

function Write-GitFailure {
    param(
        [string]$Message,
        [Parameter(Mandatory)]
        $Result
    )

    Write-Host "$Message (git exit $($Result.ExitCode))." -ForegroundColor Red
    $text = Mask-GitText -Text $Result.Text
    if (-not $text) {
        return
    }

    if ($DebugMode) {
        Write-Host "Git output:" -ForegroundColor Yellow
        Write-IndentedText -Text $text
    }
    else {
        $firstLine = ($text -split "`r?`n" | Select-Object -First 1)
        Write-Host "    $firstLine"
        Write-Host "    Re-run with 'sw update --debug' for full git output." -ForegroundColor Yellow
    }
}

# Raw user PATH (%VAR% stays text); same reader as install.ps1.
function Get-SweeprUserPathRaw {
    # The registry exists on Windows only (tests and tooling also run this on other systems).
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        return [PSCustomObject]@{ Value = ""; Kind = "ExpandString" }
    }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment")
    if (-not $key) {
        return [PSCustomObject]@{ Value = ""; Kind = "ExpandString" }
    }
    try {
        $value = $key.GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $kind = "ExpandString"
        if ($null -ne $key.GetValue("Path", $null)) {
            $kind = [string]$key.GetValueKind("Path")
        }
        return [PSCustomObject]@{ Value = [string]$value; Kind = $kind }
    }
    finally {
        $key.Close()
    }
}

# Entries match as folders: %VAR% expanded, trailing backslash dropped, case ignored.
function Test-SweeprPathEntryMatch {
    param([string]$Entry, [string]$Directory)

    $left = [Environment]::ExpandEnvironmentVariables($Entry.Trim()).TrimEnd('\')
    $right = [Environment]::ExpandEnvironmentVariables($Directory.Trim()).TrimEnd('\')
    if (-not $left -or -not $right) { return $false }
    return [string]::Equals($left, $right, [StringComparison]::OrdinalIgnoreCase)
}

function Test-InstallDirOnUserPath {
    param([string]$Path)

    $raw = Get-SweeprUserPathRaw
    if (-not $raw.Value) {
        return $false
    }

    foreach ($entry in ($raw.Value -split ";")) {
        if (Test-SweeprPathEntryMatch -Entry $entry -Directory $Path) { return $true }
    }
    return $false
}

if ($ShowHelp) {
    Show-UpdateHelp
    return
}

# The upgrade command for a copy installed by winget or Scoop,
# recognized by the folder each one installs into; $null otherwise.
function Get-PackageManagerUpgradeCommand {
    param([string]$InstallDir)

    $path = $InstallDir.TrimEnd('\') + '\'
    if ($path -like "*\Microsoft\WinGet\Packages\brummilab.Sweepr_*") {
        return "winget upgrade brummilab.Sweepr"
    }
    if ($path -like "*\scoop\apps\sweepr\*") {
        return "scoop update sweepr"
    }
    return $null
}

# A portable copy is replaced by hand: the marker file is checked before the
# installer, package manager and .git checks so none of them can apply to it.
if (Test-Path -LiteralPath (Join-Path $windowsDir "sweepr.portable") -PathType Leaf) {
    Write-Host "This is a portable copy of Sweepr, so 'sw update' cannot update it in place." -ForegroundColor Yellow
    Write-Host "Download sweepr-<version>-x64-portable.zip from https://github.com/brummilab/sweepr/releases" -ForegroundColor Yellow
    Write-Host "and replace the program files with it. Keep the folder 'data' (your settings and operation log) when replacing." -ForegroundColor Yellow
    exit 1
}

if ($DebugMode) {
    $env:SWEEPR_DEBUG = "1"
}

if (-not (Test-Path $installScript)) {
    Write-Host "Installer not found at: $installScript" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $gitDir)) {
    # Package-manager installs update through that manager, never through git.
    $upgradeCommand = Get-PackageManagerUpgradeCommand -InstallDir $windowsDir
    if ($upgradeCommand) {
        Write-Host "This copy of Sweepr is managed by a package manager." -ForegroundColor Yellow
        Write-Host "Update it with: $upgradeCommand" -ForegroundColor Yellow
        exit 1
    }
    Write-Host "This copy is not a git-based source install, so 'sw update' cannot update it in place." -ForegroundColor Red
    Write-Host "To replace it, remove or rename $windowsDir, then run:" -ForegroundColor Yellow
    Write-Host "  irm https://raw.githubusercontent.com/brummilab/sweepr/main/quick-install.ps1 | iex" -ForegroundColor Yellow
    Write-Host "A release ZIP also works: run its install.ps1 with a new -InstallDir and -AddToPath." -ForegroundColor Yellow
    exit 1
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "Git is not installed. Install Git to use 'sw update'." -ForegroundColor Red
    exit 1
}

$dirtyStatus = Invoke-GitCommand -WorkingDirectory $windowsDir -Arguments @("status", "--porcelain", "--untracked-files=no")
if ($dirtyStatus.ExitCode -ne 0) {
    Write-GitFailure -Message "Failed to inspect git status" -Result $dirtyStatus
    exit 1
}

if ($dirtyStatus.Text) {
    Write-Host "Local tracked changes detected in the installation directory." -ForegroundColor Red
    Write-Host "Commit or discard them before running 'sw update'." -ForegroundColor Yellow
    exit 1
}

$remoteResult = Invoke-GitCommand -WorkingDirectory $windowsDir -Arguments @("remote", "get-url", "origin")
$remote = $remoteResult.Text
if ($remoteResult.ExitCode -ne 0 -or -not $remote) {
    if ($remoteResult.ExitCode -ne 0) {
        Write-GitFailure -Message "Failed to inspect git remote 'origin'" -Result $remoteResult
    }
    else {
        Write-Host "Git remote 'origin' is not configured for this install." -ForegroundColor Red
    }
    exit 1
}

$branchResult = Invoke-GitCommand -WorkingDirectory $windowsDir -Arguments @("branch", "--show-current")
$branch = $branchResult.Text
if ($branchResult.ExitCode -ne 0 -or -not $branch) {
    $branch = "main"
}

$beforeResult = Invoke-GitCommand -WorkingDirectory $windowsDir -Arguments @("rev-parse", "--short", "HEAD")
$before = $beforeResult.Text
if ($beforeResult.ExitCode -ne 0 -or -not $before) {
    Write-Host "Failed to read current revision." -ForegroundColor Red
    exit 1
}

Write-Host "Updating source from $(Mask-GitText -Text $remote) ($branch)..." -ForegroundColor Cyan

$pullResult = Invoke-GitCommand -WorkingDirectory $windowsDir -Arguments @("pull", "--ff-only", "--tags", "origin", $branch)
if ($pullResult.ExitCode -ne 0) {
    Write-GitFailure -Message "Failed to update source" -Result $pullResult
    exit 1
}

$afterResult = Invoke-GitCommand -WorkingDirectory $windowsDir -Arguments @("rev-parse", "--short", "HEAD")
$after = $afterResult.Text
if ($afterResult.ExitCode -ne 0 -or -not $after) {
    Write-Host "Updated source, but failed to read the new revision." -ForegroundColor Red
    exit 1
}

if ($after -eq $before) {
    Write-Host "Already up to date at $after." -ForegroundColor Green
}
else {
    Write-Host "Updated source: $before -> $after" -ForegroundColor Green
}

$installParams = @{
    InstallDir = $windowsDir
    # An update must never open the component menu.
    NoPrompt   = $true
}

if (Test-InstallDirOnUserPath -Path $windowsDir) {
    $installParams.AddToPath = $true
}

Write-Host "Refreshing local installation..." -ForegroundColor Cyan
& $installScript @installParams
