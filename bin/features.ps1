# Sweepr - Features Command
# Interactive removal of preinstalled Microsoft apps and optional Windows features,
# and --restore to bring back what an earlier run removed.
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

    [switch]$Restore,

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

# 0 ok, 1 stopped by the administrator rule or an unreadable restore list, 2 usage
# (no interactive console, options that do not go together).
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
    Write-Host "  --restore            Bring back what Sweepr removed earlier (cannot be combined with --list or --all-users-future)"
    Write-Host "  --debug              Enable debug logging"
    Write-Host "  --help               Show this help message"
    Write-Host ""
    Write-Host "$esc[33mNotes:$esc[0m"
    Write-Host "  - Only entries from a fixed, reviewed list are offered, nothing is preselected"
    Write-Host "  - Apps are removed for the current user; --restore reinstalls them with winget or points to the Microsoft Store"
    Write-Host "  - Every removal is saved first in features-removed.json in the Sweepr data folder"
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
    param([object[]]$Items, [string]$Notice = "", [string]$Heading = "Select what to remove")

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
            Write-Host $Heading
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

# A removal that failed took nothing away, so the record saved for it goes again.
# A record that was already there before this run stays.
function Undo-FeaturesSavedRecord {
    param($Row, $Saved)

    if (-not $Saved.Added) { return }
    $undo = Remove-SweeprFeatureRemovedRecord -Id $Row.Id -Target $Row.Target
    if (-not $undo.Ok) {
        Write-Host "  Could not take the record back out of features-removed.json: $($undo.Error)" -ForegroundColor Yellow
    }
}

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
        $catalogEntry = $null
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
                    $catalogEntry = $entry[0]
                    $inventory = Get-SweeprFeatureInventory -Catalog @($catalogEntry)
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

        # Fail closed: the way back is saved first. When it cannot be saved, nothing is touched.
        $provisionedForRecord = $null
        if ($provisionedCommand) { $provisionedForRecord = $fresh.ProvisionedName }
        try {
            $record = New-SweeprFeatureRemovedRecord -Item $fresh -CatalogEntry $catalogEntry -ProvisionedName $provisionedForRecord
            $saved = Add-SweeprFeatureRemovedRecord -Record $record
        }
        catch {
            $saved = [pscustomobject]@{ Ok = $false; Added = $false; Error = "Cannot save the restore list $(Get-SweeprFeaturesRemovedPath) ($($_.Exception.Message))" }
        }
        if (-not $saved.Ok) {
            Write-SweeprOperation -Action "FAILED" -Path $logPath -Detail "not removed: $($saved.Error)"
            Write-Host "failed, not removed ($($saved.Error))" -ForegroundColor Red
            continue
        }

        if ($fresh.Kind -eq 'App') {
            try {
                Remove-AppxPackage -Package $fresh.Target -ErrorAction Stop
            }
            catch {
                $message = Get-FeaturesErrorText $_
                Undo-FeaturesSavedRecord -Row $fresh -Saved $saved
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
                Undo-FeaturesSavedRecord -Row $fresh -Saved $saved
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
# Restore (sw features --restore)
# ============================================================================

# Separate so tests never run the real winget.
function Test-FeaturesWingetAvailable {
    try { return [bool](Get-Command -Name winget -CommandType Application -ErrorAction SilentlyContinue) }
    catch { return $false }
}

# The only place that runs winget. Its own output goes to the console, the return value is the exit code.
function Invoke-FeaturesWinget {
    param([string[]]$Arguments)

    $global:LASTEXITCODE = 0
    & winget @Arguments | Out-Host
    return [int]$global:LASTEXITCODE
}

# An app counts as installed when exactly one package carries the exact name from the saved
# full name (the part before the first underscore). Anything else is not guessed.
function Test-FeaturesAppInstalled {
    param([string]$Target)

    $name = ([string]$Target).Split('_')[0]
    if ([string]::IsNullOrWhiteSpace($name)) { return $false }
    try {
        $found = @(Get-AppxPackage -Name ([WildcardPattern]::Escape($name)) -ErrorAction Stop |
            Where-Object { $_ -and [string](Get-SweeprFeatureProperty $_ 'Name') -eq $name })
        return ($found.Count -eq 1)
    }
    catch { return $false }
}

# The catalog entry a saved row is bound to, read fresh. $null when there is none (or it is not unique).
function Get-FeaturesCatalogEntry {
    param($Record)

    return (Get-SweeprFeatureCatalogEntryForRecord -Record $Record -Catalog @(Get-SweeprFeatureCatalog))
}

function Get-FeaturesStoreHint {
    param([string]$Title, [string]$Reason)

    return "$Reason - install $Title from the Microsoft Store"
}

# Rows for the menu: one per valid saved record, in file order. The saved record is all that is used;
# the catalog is not consulted, so a record outlives a change of the list.
function Get-FeaturesRestoreRows {
    param([object[]]$Records)

    $rows = @()
    foreach ($record in @($Records)) {
        $kind = [string](Get-SweeprFeatureProperty $record 'Kind')
        $title = Get-SweeprFeatureRecordTitle -Record $record
        $removedAt = ([string](Get-SweeprFeatureProperty $record 'RemovedAt')) -replace '[^0-9A-Za-z:.\-+ ]', ''
        $when = if ($removedAt) { "Removed $removedAt. " } else { "" }
        if ($kind -eq 'App') {
            # Only the current catalog decides whether winget can be used; the id in the file is ignored.
            $storeId = Get-SweeprFeatureCatalogStoreId -CatalogEntry (Get-FeaturesCatalogEntry -Record $record)
            $how = if ($storeId) { "Reinstalls the app from the Microsoft Store with winget." } else { "No Store id is known: Sweepr can only point you to the Microsoft Store." }
        }
        else {
            $how = "Turns the Windows feature back on (administrator, may need a restart)."
        }
        $rows += [pscustomobject]@{
            Id          = [string](Get-SweeprFeatureProperty $record 'Id')
            Kind        = $kind
            Title       = $title
            Description = "$when$how"
            Warning     = $null
            Target      = [string](Get-SweeprFeatureProperty $record 'Target')
            Record      = $record
        }
    }
    return , @($rows)
}

# What a restore of one row would do, for the preview.
function Get-FeaturesRestorePreviewText {
    param($Row, [bool]$WingetAvailable)

    $command = Get-SweeprFeatureRestoreCommand -Record $Row.Record -CatalogEntry (Get-FeaturesCatalogEntry -Record $Row.Record)
    if ($Row.Kind -ne 'App') { return $command }
    if (Test-FeaturesAppInstalled -Target $Row.Target) { return "Already installed: only the saved record would be removed" }
    if (-not $command) { return (Get-FeaturesStoreHint -Title $Row.Title -Reason "No Store id is known") }
    if (-not $WingetAvailable) { return (Get-FeaturesStoreHint -Title $Row.Title -Reason "winget is not available") }
    return $command
}

# A restored row leaves the list; an entry that cannot be updated is reported, not hidden.
function Complete-FeaturesRestoredRecord {
    param($Row)

    $update = Remove-SweeprFeatureRemovedRecord -Id $Row.Id -Target $Row.Target
    if (-not $update.Ok) {
        Write-Host "  Could not remove the entry from features-removed.json: $($update.Error)" -ForegroundColor Yellow
    }
}

function Invoke-FeaturesRestoreRun {
    <#
    .SYNOPSIS
        Restores the chosen rows one by one; each success leaves the list right away.
    .OUTPUTS
        $true when at least one result needs a Windows restart.
    #>
    param([object[]]$Selected, [bool]$WingetAvailable)

    $restartNeeded = $false

    foreach ($row in @($Selected)) {
        $logPath = Get-FeaturesLogPath -Item $row
        Write-Host "  $($row.Title) ... " -NoNewline

        $command = $null
        $failure = $null
        $catalogEntry = $null
        try {
            # The catalog is read again for every row: what runs must be allowed now, not only when the list was written.
            $catalogEntry = Get-FeaturesCatalogEntry -Record $row.Record
            $command = Get-SweeprFeatureRestoreCommand -Record $row.Record -CatalogEntry $catalogEntry
        }
        catch { $failure = $_.Exception.Message }
        if ($failure) {
            Write-SweeprOperation -Action "FAILED" -Path $logPath -Detail $failure
            Write-Host "failed ($failure)" -ForegroundColor Red
            continue
        }

        if ($row.Kind -eq 'App') {
            if (Test-FeaturesAppInstalled -Target $row.Target) {
                Write-SweeprOperation -Action "RESTORED" -Path $logPath -Detail "already installed; saved record removed"
                Write-Host "already installed" -ForegroundColor Green
                Complete-FeaturesRestoredRecord -Row $row
                continue
            }
            $hint = $null
            if (-not $command) { $hint = Get-FeaturesStoreHint -Title $row.Title -Reason "No Store id is known" }
            elseif (-not $WingetAvailable) { $hint = Get-FeaturesStoreHint -Title $row.Title -Reason "winget is not available" }
            if ($hint) {
                Write-SweeprOperation -Action "SKIPPED" -Path $logPath -Detail $hint
                Write-Host "skipped ($hint)" -ForegroundColor Yellow
                continue
            }

            $exitCode = $null
            try {
                $arguments = Get-SweeprFeatureWingetArguments -StoreId (Get-SweeprFeatureCatalogStoreId -CatalogEntry $catalogEntry)
                $exitCode = [int](@(Invoke-FeaturesWinget -Arguments $arguments))[-1]
            }
            catch {
                $failure = Get-FeaturesErrorText $_
            }
            # 0x8A15002B (no applicable update) and 0x8A150061 (package already installed): the app is there.
            if (-not $failure -and ($exitCode -eq -1978335189 -or $exitCode -eq -1978335135)) {
                Write-SweeprOperation -Action "RESTORED" -Path $logPath -Detail "already installed (winget exit code $exitCode); saved record removed"
                Write-Host "already installed" -ForegroundColor Green
                Complete-FeaturesRestoredRecord -Row $row
                continue
            }
            if (-not $failure -and $exitCode -ne 0) { $failure = "exit code $exitCode" }
            if ($failure) {
                Write-SweeprOperation -Action "FAILED" -Path $logPath -Detail "$command failed: $failure"
                Write-Host "failed ($failure)" -ForegroundColor Red
                continue
            }
            Write-SweeprOperation -Action "RESTORED" -Path $logPath -Detail $command
            Write-Host "restored" -ForegroundColor Green
            Complete-FeaturesRestoredRecord -Row $row
            continue
        }

        # Optional feature: catalog and rights are checked again right before the change.
        if (-not $catalogEntry) {
            $reason = "no longer in the list of removable entries"
            Write-SweeprOperation -Action "SKIPPED" -Path $logPath -Detail $reason
            Write-Host "skipped ($reason)" -ForegroundColor Yellow
            continue
        }
        $isAdmin = $false
        try { $isAdmin = [bool](Test-IsAdmin) } catch { $isAdmin = $false }
        if (-not $isAdmin) {
            $reason = "administrator rights are gone"
            Write-SweeprOperation -Action "SKIPPED" -Path $logPath -Detail $reason
            Write-Host "skipped ($reason)" -ForegroundColor Yellow
            continue
        }
        $result = $null
        try {
            $result = Enable-WindowsOptionalFeature -Online -FeatureName $row.Target -NoRestart -ErrorAction Stop
        }
        catch {
            $failure = Get-FeaturesErrorText $_
            Write-SweeprOperation -Action "FAILED" -Path $logPath -Detail "$command failed: $failure"
            Write-Host "failed ($failure)" -ForegroundColor Red
            continue
        }
        $needsRestart = $false
        foreach ($item in @($result)) {
            if ((Get-SweeprFeatureProperty $item 'RestartNeeded') -eq $true) { $needsRestart = $true }
        }
        $detail = $command
        if ($needsRestart) {
            $detail = "$command; restart needed"
            $restartNeeded = $true
        }
        Write-SweeprOperation -Action "RESTORED" -Path $logPath -Detail $detail
        Write-Host "restored" -ForegroundColor Green
        Complete-FeaturesRestoredRecord -Row $row
    }

    return $restartNeeded
}

# The restore flow after the list is read: menu, preview or confirmation, run.
function Invoke-FeaturesRestoreFlow {
    param([object[]]$Rows, [string]$Notice, [bool]$Preview)

    $selected = Show-FeaturesMenu -Items $Rows -Notice $Notice -Heading "Select what to restore"
    if ($null -eq $selected) {
        Write-Info "Cancelled"
        return
    }
    $selected = @($selected)
    if ($selected.Count -eq 0) {
        Write-Info "Nothing selected"
        return
    }

    $wingetAvailable = [bool](Test-FeaturesWingetAvailable)

    if ($Preview) {
        Write-Host ""
        Write-Host "Dry run: these commands would run, nothing is changed:" -ForegroundColor Yellow
        Write-Host ""
        foreach ($row in $selected) {
            Write-Host "  $($row.Title)"
            $text = $null
            try { $text = Get-FeaturesRestorePreviewText -Row $row -WingetAvailable $wingetAvailable }
            catch { $text = "cannot be restored: $($_.Exception.Message)" }
            Write-Host "      $text"
        }
        Write-Host ""
        return
    }

    Write-Host ""
    Write-Host "The following will be restored:" -ForegroundColor Yellow
    Write-Host ""
    foreach ($row in $selected) {
        Write-Host "  $($row.Title) ($($row.Target))"
        $text = $null
        try { $text = Get-FeaturesRestorePreviewText -Row $row -WingetAvailable $wingetAvailable }
        catch { $text = "cannot be restored: $($_.Exception.Message)" }
        Write-Host "      $text"
    }
    Write-Host ""
    $confirm = Read-Host "Continue? (y/N)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
        Write-Info "Cancelled"
        return
    }

    Write-Host ""
    $restartNeeded = Invoke-FeaturesRestoreRun -Selected $selected -WingetAvailable $wingetAvailable
    Write-Host ""
    if ($restartNeeded) {
        Write-Host "Restart Windows to finish." -ForegroundColor Yellow
    }
}

function Invoke-FeaturesRestoreCommand {
    param([switch]$DryRun, [switch]$List, [switch]$AllUsersFuture)

    if ($List -or $AllUsersFuture) {
        Write-SweeprError "--restore cannot be combined with --list or --all-users-future."
        $script:FeaturesExitCode = 2
        return
    }

    if ($DryRun) {
        $env:SWEEPR_DRY_RUN = "1"
        Set-DryRunMode -Enabled $true
    }
    $preview = [bool]$DryRun -or [bool](Test-DryRunMode)

    $stored = Read-SweeprFeaturesRemoved
    if (-not $stored.Ok) {
        Write-SweeprError "$($stored.Error). The file was not changed; fix or move it aside to use --restore."
        $script:FeaturesExitCode = 1
        return
    }
    $records = @($stored.Items)
    if ($records.Count -eq 0) {
        Write-Info "Nothing to restore: Sweepr has no saved removals."
        return
    }

    if (-not (Test-FeaturesInteractive)) {
        Write-SweeprError "sw features --restore needs an interactive console."
        $script:FeaturesExitCode = 2
        return
    }

    # Invalid records stay in the file untouched; they are just never offered.
    $valid = @($records | Where-Object { Test-SweeprFeatureRemovedRecord -Record $_ })

    $isAdmin = $false
    try { $isAdmin = [bool](Test-IsAdmin) } catch { $isAdmin = $false }
    # The file is user-writable: a record is only offered when the current catalog allows it too.
    $catalog = @(Get-SweeprFeatureCatalog)
    $bound = @()
    foreach ($record in $valid) {
        if (Test-SweeprFeatureRecordKindClash -Record $record -Catalog $catalog) { continue }
        if ((Get-SweeprFeatureProperty $record 'Kind') -eq 'OptionalFeature' -and -not (Get-SweeprFeatureCatalogEntryForRecord -Record $record -Catalog $catalog)) { continue }
        $bound += $record
    }
    $invalidCount = $records.Count - $bound.Count
    $offered = @($bound | Where-Object { (Get-SweeprFeatureProperty $_ 'Kind') -eq 'App' -or $isAdmin })
    $notice = ""
    if ($offered.Count -lt $bound.Count) { $notice = Get-FeaturesNeedAdminText }

    if ($offered.Count -eq 0) {
        if ($notice) { Write-FeaturesNeedAdminHint }
        else { Write-Info "Nothing to restore: no saved entry in features-removed.json can be offered." }
    }
    else {
        Invoke-FeaturesRestoreFlow -Rows (Get-FeaturesRestoreRows -Records $offered) -Notice $notice -Preview $preview
    }

    if ($invalidCount -gt 0) {
        Write-Host "$invalidCount saved entries in features-removed.json are not valid or not in the current list of restorable entries and were not offered; the file was left as it is." -ForegroundColor Yellow
    }
}

# ============================================================================
# Command
# ============================================================================

function Invoke-FeaturesCommand {
    param(
        [switch]$DryRun,
        [switch]$List,
        [switch]$AllUsersFuture,
        [switch]$Restore,
        [switch]$ShowHelp
    )

    $script:FeaturesExitCode = 0

    if ($ShowHelp) {
        Show-FeaturesHelp
        return
    }

    if ($Restore) {
        Invoke-FeaturesRestoreCommand -DryRun:$DryRun -List:$List -AllUsersFuture:$AllUsersFuture
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
try { Invoke-FeaturesCommand -DryRun:$DryRun -List:$List -AllUsersFuture:$AllUsersFuture -Restore:$Restore -ShowHelp:$ShowHelp }
finally { Stop-Spinner }
if ($script:FeaturesExitCode -ne 0) { exit $script:FeaturesExitCode }
