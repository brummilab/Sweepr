# Sweepr - Features Command
# Interactive removal of preinstalled Microsoft apps and optional Windows features.
# The allowlist, the protection lock, the inventory and the command text live in
# lib/core/features.ps1; this script only runs the flow: list, menu, confirm, remove.

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Alias('dry-run')]
    [switch]$DryRun,

    [Alias('d')]
    [switch]$DebugMode,

    [switch]$List,

    [Alias('all-users-future')]
    [switch]$AllUsersFuture,

    [Alias('h')]
    [switch]$ShowHelp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Script location
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Join-Path (Split-Path -Parent $scriptDir) "lib"

# Import core modules
. "$libDir\core\base.ps1"
. "$libDir\core\log.ps1"
. "$libDir\core\ui.ps1"
. "$libDir\core\file_ops.ps1"
. "$libDir\core\features.ps1"

# 0 ok, 1 stopped by the administrator rule, 2 usage (no interactive console).
$script:FeaturesExitCode = 0

# ============================================================================
# Help
# ============================================================================

function Show-FeaturesHelp {
    $esc = [char]27
    Write-Host ""
    Write-Host "$esc[1;35msw features$esc[0m - Remove preinstalled apps and optional Windows features"
    Write-Host ""
    Write-Host "$esc[33mUsage:$esc[0m sw features [options]"
    Write-Host ""
    Write-Host "$esc[33mOptions:$esc[0m"
    Write-Host "  --dry-run            Show the exact commands, change nothing"
    Write-Host "  --list               List what can be removed and exit (JSON when piped)"
    Write-Host "  --all-users-future   Also remove the app for future users (administrator)"
    Write-Host "  --debug              Enable debug logging"
    Write-Host "  --help               Show this help message"
    Write-Host ""
    Write-Host "$esc[33mNotes:$esc[0m"
    Write-Host "  - Only entries from a fixed, reviewed list are offered, nothing is preselected"
    Write-Host "  - Apps are removed for the current user; the Microsoft Store can reinstall them"
    Write-Host "  - Optional Windows features need an administrator PowerShell"
    Write-Host "  - Sweepr never restarts Windows and never asks for administrator rights itself"
    Write-Host ""
}

# ============================================================================
# Small helpers (separate so tests can replace the console)
# ============================================================================

function Test-FeaturesListAsJson {
    return [Console]::IsOutputRedirected
}

function Test-FeaturesInteractive {
    try { return -not [Console]::IsInputRedirected } catch { return $false }
}

function Read-FeaturesMenuKey {
    return [Console]::ReadKey($true)
}

# ============================================================================
# Menu
# ============================================================================

function Show-FeaturesMenu {
    <#
    .SYNOPSIS
        Checkbox menu over inventory rows. Nothing is checked at the start.
    .OUTPUTS
        The checked rows in menu order (an empty array when none), or $null when cancelled.
    #>
    param([object[]]$Items)

    $rows = @($Items)
    if ($rows.Count -eq 0) { return , @() }

    $checked = New-Object 'bool[]' $rows.Count
    $cursor = 0

    # Hiding the cursor can fail without a real console.
    try { [Console]::CursorVisible = $false } catch { }

    try {
        while ($true) {
            Clear-Host
            Write-Host ""
            Write-Host "Select what to remove"
            Write-Host "Up/Down move | Space select | Enter confirm | Esc or Q cancel"
            Write-Host ""

            for ($i = 0; $i -lt $rows.Count; $i++) {
                $row = $rows[$i]
                $pointer = if ($i -eq $cursor) { ">" } else { " " }
                $box = if ($checked[$i]) { "[x]" } else { "[ ]" }
                $line = "$pointer $box $($row.Title)"
                if ($i -eq $cursor) { Write-Host $line -ForegroundColor Cyan } else { Write-Host $line }
                Write-Host "        $($row.Description)" -ForegroundColor DarkGray
                if (-not [string]::IsNullOrWhiteSpace([string]$row.Warning)) {
                    Write-Host "        Warning: $($row.Warning)" -ForegroundColor Yellow
                }
            }

            $key = Read-FeaturesMenuKey
            switch ($key.Key) {
                'UpArrow' { if ($cursor -gt 0) { $cursor-- } }
                'DownArrow' { if ($cursor -lt $rows.Count - 1) { $cursor++ } }
                'Spacebar' { $checked[$cursor] = -not $checked[$cursor] }
                'Enter' {
                    $selected = @()
                    for ($i = 0; $i -lt $rows.Count; $i++) {
                        if ($checked[$i]) { $selected += $rows[$i] }
                    }
                    return , @($selected)
                }
                'Escape' { return $null }
                'Q' { return $null }
            }
        }
    }
    finally {
        try { [Console]::CursorVisible = $true } catch { }
    }
}

# ============================================================================
# Output helpers
# ============================================================================

function Write-FeaturesNeedAdminHint {
    Write-Host "Run Sweepr in an administrator PowerShell for optional Windows features." -ForegroundColor Yellow
}

function Write-FeaturesList {
    param($Inventory)

    Write-Host ""
    foreach ($item in @($Inventory.Items)) {
        $kindLabel = if ($item.Kind -eq 'App') { "app" } else { "feature" }
        Write-Host "  $($item.Title) ($kindLabel)"
        Write-Host "      $($item.Description)" -ForegroundColor DarkGray
        if (-not [string]::IsNullOrWhiteSpace([string]$item.Warning)) {
            Write-Host "      Warning: $($item.Warning)" -ForegroundColor Yellow
        }
    }
    Write-Host ""
    if ($Inventory.FeaturesNeedAdmin) { Write-FeaturesNeedAdminHint }
}

function ConvertTo-FeaturesListJson {
    param($Inventory)

    $records = @()
    foreach ($item in @($Inventory.Items)) {
        $records += [ordered]@{
            id          = [string]$item.Id
            kind        = [string]$item.Kind
            title       = [string]$item.Title
            description = [string]$item.Description
            warning     = $(if ([string]::IsNullOrWhiteSpace([string]$item.Warning)) { $null } else { [string]$item.Warning })
            target      = [string]$item.Target
            provisioned = [bool]$item.Provisioned
        }
    }
    $document = [ordered]@{
        items               = @($records)
        features_need_admin = [bool]$Inventory.FeaturesNeedAdmin
    }
    return ($document | ConvertTo-Json -Depth 5)
}

# Identifier in the operations log: appx:<PackageFullName> or feature:<FeatureName>.
function Get-FeaturesLogPath {
    param($Item)

    if ($Item.Kind -eq 'App') { return "appx:$($Item.Target)" }
    return "feature:$($Item.Target)"
}

function Get-FeaturesCommandText {
    param($Item, [bool]$WithProvisioned)

    # The option is passed only when it is set, so the text never names a step that does not run.
    $options = @{}
    if ($WithProvisioned) { $options['AllUsersFuture'] = $true }
    return (Get-SweeprFeatureCommand -Item $Item @options)
}

# ============================================================================
# Removal
# ============================================================================

function Invoke-FeaturesRemoval {
    <#
    .SYNOPSIS
        Removes the reviewed rows one by one, re-checking each right before it is touched.
    .OUTPUTS
        $true when at least one result needs a Windows restart.
    #>
    param([object[]]$Selected, [bool]$WithProvisioned)

    $restartNeeded = $false

    foreach ($row in @($Selected)) {
        $logPath = Get-FeaturesLogPath -Item $row
        Write-Host "  $($row.Title) ... " -NoNewline

        # Fresh read: the reviewed row must still be offered with the same target.
        $fresh = $null
        $skipReason = $null
        try {
            if ($WithProvisioned -and -not [bool](Test-IsAdmin)) {
                $skipReason = "administrator rights are gone"
            }
            else {
                $inventory = Get-SweeprFeatureInventory
                $matches_ = @($inventory.Items | Where-Object { $_.Id -eq $row.Id -and $_.Target -eq $row.Target })
                if ($matches_.Count -eq 1) { $fresh = $matches_[0] }
                else { $skipReason = "no longer installed, changed or not offered any more since you reviewed it" }
            }
        }
        catch {
            $skipReason = "could not re-check: $($_.Exception.Message)"
        }

        if (-not $fresh) {
            Write-SweeprOperation -Action "SKIPPED" -Path $logPath -Detail $skipReason
            Write-Host "skipped ($skipReason)" -ForegroundColor Yellow
            continue
        }

        try {
            $command = Get-FeaturesCommandText -Item $fresh -WithProvisioned $WithProvisioned
            if ($fresh.Kind -eq 'App') {
                Remove-AppxPackage -Package $fresh.Target -ErrorAction Stop
                if ($WithProvisioned -and $fresh.Provisioned -eq $true) {
                    $null = Remove-AppxProvisionedPackage -Online -PackageName $fresh.ProvisionedName -ErrorAction Stop
                }
                Write-SweeprOperation -Action "REMOVED" -Path $logPath -Detail $command
                Write-Host "removed" -ForegroundColor Green
            }
            else {
                $result = Disable-WindowsOptionalFeature -Online -FeatureName $fresh.Target -NoRestart -ErrorAction Stop
                $needsRestart = $false
                foreach ($entry in @($result)) {
                    if ((Get-SweeprFeatureProperty $entry 'RestartNeeded') -eq $true) { $needsRestart = $true }
                }
                $detail = $command
                if ($needsRestart) {
                    $detail = "$command; restart needed"
                    $restartNeeded = $true
                }
                Write-SweeprOperation -Action "DISABLED" -Path $logPath -Detail $detail
                Write-Host "disabled" -ForegroundColor Green
            }
        }
        catch {
            $message = $_.Exception.Message
            if ([string]::IsNullOrWhiteSpace($message)) { $message = [string]$_ }
            Write-SweeprOperation -Action "FAILED" -Path $logPath -Detail $message
            Write-Host "failed ($message)" -ForegroundColor Red
        }
    }

    return $restartNeeded
}

# ============================================================================
# Command
# ============================================================================

function Invoke-FeaturesCommand {
    param(
        [switch]$DryRun,
        [switch]$List,
        [switch]$AllUsersFuture,
        [switch]$ShowHelp
    )

    $script:FeaturesExitCode = 0

    if ($ShowHelp) {
        Show-FeaturesHelp
        return
    }

    $preview = [bool]$DryRun -or [bool](Test-DryRunMode)

    # Rights first: a real --all-users-future run stops before it reads, asks or changes anything.
    $isAdmin = $false
    try { $isAdmin = [bool](Test-IsAdmin) } catch { $isAdmin = $false }
    if ($AllUsersFuture -and -not $List -and -not $preview -and -not $isAdmin) {
        Write-SweeprError "Run Sweepr in an administrator PowerShell for --all-users-future."
        $script:FeaturesExitCode = 1
        return
    }

    $asJson = $List -and (Test-FeaturesListAsJson)

    # The JSON form keeps the console free of anything but the document.
    if (-not $asJson) {
        Write-Host "Reading Windows features, this can take a few seconds..."
    }
    $inventory = Get-SweeprFeatureInventory
    $items = @($inventory.Items)

    if ($List) {
        if ($asJson) { Write-Output (ConvertTo-FeaturesListJson -Inventory $inventory) }
        else { Write-FeaturesList -Inventory $inventory }
        return
    }

    if ($DryRun) {
        $env:SWEEPR_DRY_RUN = "1"
        Set-DryRunMode -Enabled $true
    }

    if ($inventory.FeaturesNeedAdmin) { Write-FeaturesNeedAdminHint }

    if ($items.Count -eq 0) {
        Write-Info "Nothing to remove: none of the listed apps or features is present."
        return
    }

    if (-not (Test-FeaturesInteractive)) {
        Write-SweeprError "sw features needs an interactive console. Use sw features --list to see what is offered."
        $script:FeaturesExitCode = 2
        return
    }

    $selected = Show-FeaturesMenu -Items $items
    if ($null -eq $selected) {
        Write-Info "Cancelled"
        return
    }
    $selected = @($selected)
    if ($selected.Count -eq 0) {
        Write-Info "Nothing selected"
        return
    }

    # The provisioned step only exists when the option is set; a preview shows it as it would run.
    $withProvisioned = [bool]$AllUsersFuture

    if ($preview) {
        Write-Host ""
        Write-Host "Dry run: these commands would run, nothing is changed:" -ForegroundColor Yellow
        Write-Host ""
        foreach ($row in $selected) {
            Write-Host "  $($row.Title)"
            if (-not [string]::IsNullOrWhiteSpace([string]$row.Warning)) {
                Write-Host "      Warning: $($row.Warning)" -ForegroundColor Yellow
            }
            Write-Host "      $(Get-FeaturesCommandText -Item $row -WithProvisioned $withProvisioned)"
        }
        Write-Host ""
        if ($AllUsersFuture -and -not $isAdmin) {
            Write-Host "A real run of --all-users-future needs an administrator PowerShell; this preview may not show provisioned packages."
        }
        return
    }

    Write-Host ""
    Write-Host "The following will be removed:" -ForegroundColor Yellow
    Write-Host ""
    foreach ($row in $selected) {
        Write-Host "  $($row.Title)"
        if (-not [string]::IsNullOrWhiteSpace([string]$row.Warning)) {
            Write-Host "      Warning: $($row.Warning)" -ForegroundColor Yellow
        }
    }
    Write-Host ""
    $confirm = Read-Host "Continue? (y/N)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
        Write-Info "Cancelled"
        return
    }

    Write-Host ""
    $restartNeeded = Invoke-FeaturesRemoval -Selected $selected -WithProvisioned $withProvisioned
    Write-Host ""
    if ($restartNeeded) {
        Write-Host "Restart Windows to finish." -ForegroundColor Yellow
    }
}

# Run main
if ($DebugMode) {
    Enable-DebugMode
    $DebugPreference = "Continue"
}
try { Invoke-FeaturesCommand -DryRun:$DryRun -List:$List -AllUsersFuture:$AllUsersFuture -ShowHelp:$ShowHelp }
finally { Stop-Spinner }
if ($script:FeaturesExitCode -ne 0) { exit $script:FeaturesExitCode }
