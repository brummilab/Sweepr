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

# Separate so tests can choose the window size. Unknown sizes fall back to a small, safe screen.
function Get-FeaturesWindowHeight {
    try {
        $height = [int][Console]::WindowHeight
        if ($height -ge 5) { return $height }
    }
    catch { }
    return 24
}

function Get-FeaturesWindowWidth {
    try {
        $width = [int][Console]::WindowWidth
        if ($width -ge 30) { return $width }
    }
    catch { }
    return 80
}

# Word-wraps text into at most $MaxLines lines of $Width characters; an overflow ends in "...".
function Split-FeaturesText {
    param([string]$Text, [int]$Width, [int]$MaxLines)

    $lines = @()
    $current = ""
    $words = @(([string]$Text) -split '\s+' | Where-Object { $_ })
    $overflow = $false
    foreach ($word in $words) {
        if ($word.Length -gt $Width) { $word = $word.Substring(0, $Width) }
        $candidate = if ($current) { "$current $word" } else { $word }
        if ($candidate.Length -le $Width) { $current = $candidate; continue }
        if ($lines.Count + 1 -ge $MaxLines) { $overflow = $true; break }
        $lines += $current
        $current = $word
    }
    if ($current) { $lines += $current }
    if ($overflow -and $lines.Count -gt 0) {
        $last = $lines[$lines.Count - 1]
        if ($last.Length + 3 -gt $Width) { $last = $last.Substring(0, [Math]::Max(0, $Width - 3)) }
        $lines[$lines.Count - 1] = "$last..."
    }
    return , @($lines)
}

function Get-FeaturesNeedAdminText {
    return "Run Sweepr in an administrator PowerShell for optional Windows features."
}

# ============================================================================
# Menu
# ============================================================================

function Show-FeaturesMenu {
    <#
    .SYNOPSIS
        Checkbox menu over inventory rows. Nothing is checked at the start.
    .DESCRIPTION
        One line per row; the description and warning of the cursor row sit below the list.
        Every screen (after Clear-Host) fits the window, with the notice in its head, and the
        row window follows the cursor.
    .OUTPUTS
        The checked rows in menu order (an empty array when none), or $null when cancelled.
    #>
    param([object[]]$Items, [string]$Notice = "")

    $rows = @($Items)
    if ($rows.Count -eq 0) { return , @() }

    $checked = New-Object 'bool[]' $rows.Count
    $cursor = 0
    $top = 0

    # Hiding the cursor can fail without a real console.
    try { [Console]::CursorVisible = $false } catch { }

    try {
        while ($true) {
            $height = Get-FeaturesWindowHeight
            $width = Get-FeaturesWindowWidth
            # Head: title, controls and the notice. Foot: status line, two description lines, one warning line.
            $fixed = 2 + $(if ($Notice) { 1 } else { 0 }) + 1 + 2 + 1
            # One line less than the window: a full screen would scroll its first line away.
            $size = [Math]::Max(3, $height - 1 - $fixed)
            $size = [Math]::Min($size, $rows.Count)
            if ($cursor -lt $top) { $top = $cursor }
            if ($cursor -ge $top + $size) { $top = $cursor - $size + 1 }
            if ($top -gt $rows.Count - $size) { $top = $rows.Count - $size }
            if ($top -lt 0) { $top = 0 }

            Clear-Host
            Write-Host "Select what to remove"
            Write-Host "Up/Down move | Space select | Enter confirm | Esc/Q cancel"
            if ($Notice) { Write-Host $Notice -ForegroundColor Yellow }

            for ($i = $top; $i -lt $top + $size; $i++) {
                $pointer = if ($i -eq $cursor) { ">" } else { " " }
                $box = if ($checked[$i]) { "[x]" } else { "[ ]" }
                $line = "$pointer $box $($rows[$i].Title)"
                if ($i -eq $cursor) { Write-Host $line -ForegroundColor Cyan } else { Write-Host $line }
            }

            $count = @($checked | Where-Object { $_ }).Count
            Write-Host ("Showing {0}-{1} of {2}, {3} selected" -f ($top + 1), ($top + $size), $rows.Count, $count) -ForegroundColor DarkGray
            $current = $rows[$cursor]
            foreach ($line in (Split-FeaturesText -Text ([string]$current.Description) -Width ($width - 6) -MaxLines 2)) {
                Write-Host "  $line" -ForegroundColor DarkGray
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$current.Warning)) {
                foreach ($line in (Split-FeaturesText -Text "Warning: $($current.Warning)" -Width ($width - 6) -MaxLines 1)) {
                    Write-Host "  $line" -ForegroundColor Yellow
                }
            }

            $key = Read-FeaturesMenuKey
            switch ($key.Key) {
                'UpArrow' { if ($cursor -gt 0) { $cursor-- } }
                'DownArrow' { if ($cursor -lt $rows.Count - 1) { $cursor++ } }
                'PageUp' { $cursor = [Math]::Max(0, $cursor - $size) }
                'PageDown' { $cursor = [Math]::Min($rows.Count - 1, $cursor + $size) }
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
    Write-Host (Get-FeaturesNeedAdminText) -ForegroundColor Yellow
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

function Get-FeaturesErrorText {
    param($ErrorRecord)

    $text = $ErrorRecord.Exception.Message
    if ([string]::IsNullOrWhiteSpace($text)) { $text = [string]$ErrorRecord }
    return $text
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
                # Only this entry is read again, from a fresh catalog: one that left the catalog is not removed.
                $entry = @(Get-SweeprFeatureCatalog | Where-Object { (Get-SweeprFeatureProperty $_ 'Id') -eq $row.Id })
                if ($entry.Count -ne 1) {
                    $skipReason = "no longer in the list of removable entries"
                }
                else {
                    $inventory = Get-SweeprFeatureInventory -Catalog @($entry[0])
                    $same = @($inventory.Items | Where-Object { $_.Id -eq $row.Id -and $_.Target -eq $row.Target })
                    if ($same.Count -eq 1) { $fresh = $same[0] }
                    else { $skipReason = "no longer installed, changed or not offered any more since you reviewed it" }
                }
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

        $message = $null
        try {
            $userCommand = Get-FeaturesCommandText -Item $fresh -WithProvisioned $false
            $fullCommand = Get-FeaturesCommandText -Item $fresh -WithProvisioned $WithProvisioned
            $provisionedCommand = $null
            if ($fullCommand.Length -gt $userCommand.Length) {
                $provisionedCommand = $fullCommand.Substring($userCommand.Length).TrimStart(';', ' ')
            }
        }
        catch {
            $message = $_.Exception.Message
        }
        if ($message) {
            Write-SweeprOperation -Action "FAILED" -Path $logPath -Detail $message
            Write-Host "failed ($message)" -ForegroundColor Red
            continue
        }

        if ($fresh.Kind -eq 'App') {
            try {
                Remove-AppxPackage -Package $fresh.Target -ErrorAction Stop
            }
            catch {
                $message = Get-FeaturesErrorText $_
                Write-SweeprOperation -Action "FAILED" -Path $logPath -Detail "$userCommand failed: $message"
                Write-Host "failed ($message)" -ForegroundColor Red
                continue
            }
            Write-SweeprOperation -Action "REMOVED" -Path $logPath -Detail $userCommand
            if (-not $provisionedCommand) {
                Write-Host "removed" -ForegroundColor Green
                continue
            }
            # Each step has its own record, so a partial result is visible in the log.
            $provisionedPath = "appx-provisioned:$($fresh.ProvisionedName)"
            try {
                $null = Remove-AppxProvisionedPackage -Online -PackageName $fresh.ProvisionedName -ErrorAction Stop
                Write-SweeprOperation -Action "REMOVED" -Path $provisionedPath -Detail $provisionedCommand
                Write-Host "removed, also for future users" -ForegroundColor Green
            }
            catch {
                $message = Get-FeaturesErrorText $_
                Write-SweeprOperation -Action "FAILED" -Path $provisionedPath -Detail "$provisionedCommand failed: $message"
                Write-Host "removed for you, provisioned package failed ($message)" -ForegroundColor Red
            }
        }
        else {
            try {
                $result = Disable-WindowsOptionalFeature -Online -FeatureName $fresh.Target -NoRestart -ErrorAction Stop
            }
            catch {
                $message = Get-FeaturesErrorText $_
                Write-SweeprOperation -Action "FAILED" -Path $logPath -Detail "$userCommand failed: $message"
                Write-Host "failed ($message)" -ForegroundColor Red
                continue
            }
            $needsRestart = $false
            foreach ($entry in @($result)) {
                if ((Get-SweeprFeatureProperty $entry 'RestartNeeded') -eq $true) { $needsRestart = $true }
            }
            $detail = $userCommand
            if ($needsRestart) {
                $detail = "$userCommand; restart needed"
                $restartNeeded = $true
            }
            Write-SweeprOperation -Action "DISABLED" -Path $logPath -Detail $detail
            Write-Host "disabled" -ForegroundColor Green
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

    $notice = ""
    if ($inventory.FeaturesNeedAdmin) { $notice = Get-FeaturesNeedAdminText }

    if ($items.Count -eq 0) {
        if ($notice) { Write-FeaturesNeedAdminHint }
        Write-Info "Nothing to remove: none of the listed apps or features is present."
        return
    }

    if (-not (Test-FeaturesInteractive)) {
        Write-SweeprError "sw features needs an interactive console. Use sw features --list to see what is offered."
        $script:FeaturesExitCode = 2
        return
    }

    $selected = Show-FeaturesMenu -Items $items -Notice $notice
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
