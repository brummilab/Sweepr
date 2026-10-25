# Sweepr - Cleanup Preview Module
# The cleanup flow of `sw clean`, and a read-only variant that returns its dry-run hits as data

#Requires -Version 5.1
Set-StrictMode -Version Latest

# Prevent multiple sourcing
if ((Get-Variable -Name 'SWEEPR_CLEAN_PREVIEW_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:SWEEPR_CLEAN_PREVIEW_LOADED) { return }
$script:SWEEPR_CLEAN_PREVIEW_LOADED = $true

# Import dependencies
# $PSScriptRoot, not a variable the loaded modules overwrite: each of them sets its own $scriptDir.
. "$PSScriptRoot\..\core\base.ps1"
. "$PSScriptRoot\..\core\log.ps1"
. "$PSScriptRoot\..\core\file_ops.ps1"
. "$PSScriptRoot\user.ps1"
. "$PSScriptRoot\caches.ps1"
. "$PSScriptRoot\dev.ps1"
. "$PSScriptRoot\apps.ps1"
. "$PSScriptRoot\system.ps1"

# ============================================================================
# Cleanup sections (shared by sw clean and the preview)
# ============================================================================

# Runs the cleanup sections in the order `sw clean` always used. The caller sets
# the dry-run mode first; this function neither prints a banner nor clears the screen.
function Invoke-SweeprCleanSections {
    param(
        [bool]$IncludeSystem,
        [bool]$IncludeGameMedia,
        [bool]$IncludeGpuShaders
    )

    # User essentials (temp, logs, etc.)
    Invoke-UserCleanup -TempDaysOld 7 -LogDaysOld 7

    # Browser caches
    Clear-BrowserCaches

    # GPU shader caches (NVIDIA, AMD, Intel, DirectX) only on request: every game
    # compiles its shaders again on its next launch, which can take minutes
    if ($IncludeGpuShaders) {
        Clear-GPUShaderCaches
    }

    # Application caches
    Clear-AppCaches

    # Developer tools
    Invoke-DevToolsCleanup

    # Applications cleanup (with optional game media)
    if ($IncludeGameMedia) {
        Invoke-AppCleanup -IncludeGameMedia -GameMediaDaysOld 90
    }
    else {
        Invoke-AppCleanup
    }

    # System cleanup (if requested and admin)
    if ($IncludeSystem -and (Test-IsAdmin)) {
        Invoke-SystemCleanup
    }
}

# ============================================================================
# Read-only preview as data
# ============================================================================

function Get-SweeprCleanPreview {
    <#
    .SYNOPSIS
        What `sw clean --dry-run` would clean, as one data object
    .DESCRIPTION
        Runs the cleanup sections in dry-run mode with a collector on the shared dry-run sink, so
        nothing is removed, no list file is written and nothing is printed. With -SkipExternalTools
        no installed tool (npm, pip, go ...) is started; those caches are listed in NotMeasured.
        -System adds the system sections only as an administrator; it never elevates.
    #>
    [CmdletBinding()]
    param(
        [switch]$System,
        [switch]$SkipExternalTools,
        [switch]$GameMedia,
        [switch]$GpuShaders
    )

    $isAdmin = [bool](Test-IsAdmin)
    $includeSystem = $System.IsPresent -and $isAdmin

    $hitList = New-Object System.Collections.Generic.List[object]
    $sectionList = New-Object System.Collections.Generic.List[string]
    $skippedTools = New-Object System.Collections.Generic.List[object]
    $notMeasured = New-Object System.Collections.Generic.List[object]

    # Everything this function switches is put back, so a caller in the middle of its own
    # (dry) run sees no change in mode or statistics.
    $saved = @{
        DryRun    = $script:SweeprDryRunMode
        Collector = $script:DryRunCollector
        Sections  = $script:SectionCollector
        Skip      = $script:SweeprSkipExternalTools
        Skipped   = $script:NotMeasuredCollector
        NoSpinner = $script:SpinnerDisabled
        Size      = $script:TotalSizeCleaned
        Files     = $script:FilesCleaned
        Items     = $script:TotalItems
        Owner     = $script:OwnerCleanups
        Active    = $script:CurrentSection.Active
    }
    try {
        Reset-CleanupStats
        Set-DryRunMode -Enabled $true
        $script:DryRunCollector = $hitList
        $script:SectionCollector = $sectionList
        $script:SweeprSkipExternalTools = $SkipExternalTools.IsPresent
        $script:NotMeasuredCollector = $skippedTools
        $script:SpinnerDisabled = $true
        try {
            # Host output (stream 6) and warnings belong to the interactive command, not to data.
            Invoke-SweeprCleanSections -IncludeSystem $includeSystem -IncludeGameMedia $GameMedia.IsPresent -IncludeGpuShaders $GpuShaders.IsPresent 6>$null 3>$null
        }
        catch {
            $notMeasured.Add([pscustomobject]@{ Section = 'Cleanup'; Name = 'Cleanup'; Reason = "error: $($_.Exception.Message)" })
        }
    }
    finally {
        $script:CurrentSection.Active = $saved.Active
        $script:SweeprDryRunMode = $saved.DryRun
        $script:DryRunCollector = $saved.Collector
        $script:SectionCollector = $saved.Sections
        $script:SweeprSkipExternalTools = $saved.Skip
        $script:NotMeasuredCollector = $saved.Skipped
        $script:SpinnerDisabled = $saved.NoSpinner
        $script:TotalSizeCleaned = $saved.Size
        $script:FilesCleaned = $saved.Files
        $script:TotalItems = $saved.Items
        $script:OwnerCleanups = $saved.Owner
    }

    foreach ($tool in $skippedTools.ToArray()) { $notMeasured.Add($tool) }
    if ($System.IsPresent -and -not $isAdmin) {
        $notMeasured.Add([pscustomobject]@{ Section = 'System cleanup'; Name = 'System cleanup'; Reason = 'needs administrator' })
    }

    # Sections in run order; a hit outside any announced section still gets its own entry.
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($name in $sectionList.ToArray()) { if (-not $names.Contains($name)) { $names.Add($name) } }
    foreach ($hit in $hitList.ToArray()) { if (-not $names.Contains($hit.Section)) { $names.Add($hit.Section) } }

    $sections = New-Object System.Collections.Generic.List[object]
    foreach ($name in $names.ToArray()) {
        $sectionHits = @($hitList.ToArray() | Where-Object { $_.Section -eq $name })
        [long]$bytes = 0
        [int]$count = 0
        foreach ($hit in $sectionHits) { $bytes += $hit.SizeBytes; $count += $hit.Count }
        $sections.Add([pscustomobject]@{ Name = $name; Hits = $sectionHits; TotalBytes = $bytes; Count = $count })
    }

    [long]$totalBytes = 0
    [int]$totalCount = 0
    foreach ($hit in $hitList.ToArray()) { $totalBytes += $hit.SizeBytes; $totalCount += $hit.Count }

    return [pscustomobject]@{
        DryRun      = $true
        IsAdmin     = $isAdmin
        Sections    = $sections.ToArray()
        Hits        = $hitList.ToArray()
        TotalBytes  = $totalBytes
        Count       = $totalCount
        NotMeasured = $notMeasured.ToArray()
    }
}
