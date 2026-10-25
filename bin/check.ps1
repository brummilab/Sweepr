# Sweepr - Check Command
# Looks at this PC once and reports: cleanup potential, removable apps, system health and
# project artifacts. It only reads. The data comes from the shared library functions
# (clean preview, feature inventory, health, purge preview); this script runs them, cleans the
# answer down to a fixed allowlist and prints it (console summary, --json, or --report).

#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Json,

    [switch]$Report,

    [Alias('no-open')]
    [switch]$NoOpen,

    [Alias('dry-run')]
    [switch]$DryRun,

    [Alias('d')]
    [switch]$DebugMode,

    [Alias('h')]
    [switch]$ShowHelp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Script location. Taken before the modules are loaded: each of them sets its own $scriptDir.
$script:CheckRootDir = Split-Path -Parent $PSScriptRoot
$script:CheckLibDir = Join-Path $script:CheckRootDir "lib"

# Import core modules
. "$script:CheckLibDir\core\base.ps1"
. "$script:CheckLibDir\core\log.ps1"
. "$script:CheckLibDir\core\ui.ps1"
. "$script:CheckLibDir\core\file_ops.ps1"
. "$script:CheckLibDir\core\version.ps1"
. "$script:CheckLibDir\core\features.ps1"
. "$script:CheckLibDir\core\health.ps1"
. "$script:CheckLibDir\clean\preview.ps1"
. "$script:CheckLibDir\clean\projects.ps1"

# Get-SweeprPurgePreview reads this counter of projects.ps1 under strict mode; it must exist in
# this script scope, whatever the load order was.
if (-not (Get-Variable -Name 'PurgeUnverified' -Scope Script -ErrorAction SilentlyContinue)) { $script:PurgeUnverified = 0 }

# 0 the check ran, 1 --report was asked and the report could not be made, 2 usage (set by the router).
$script:CheckExitCode = 0


# ============================================================================
# Help and small helpers
# ============================================================================

# Limits of the project search (the built-in folders only) and of the lists in the result. Kept
# short, because the answer is a first look, and an incomplete result is reported as such.
# A function, not script variables: the command functions must not depend on the top level.
function Get-CheckLimits {
    return @{
        ProjectMaxDepth       = 3
        ProjectSecondsPerRoot = 10
        ProjectSecondsTotal   = 40
        ProjectSizeFiles      = 20000
        TopCount              = 20
    }
}

function Show-CheckHelp {
    $esc = [char]27
    Write-Host ""
    Write-Host "$esc[1;35msw check$esc[0m - Look at this PC once and report (changes nothing)"
    Write-Host ""
    Write-Host "$esc[33mUsage:$esc[0m sw check [options]"
    Write-Host ""
    Write-Host "$esc[33mOptions:$esc[0m"
    Write-Host "  --json         Write the result as one JSON document (when the output is redirected)"
    Write-Host "  --report       Also write an HTML report and open it"
    Write-Host "  --no-open      With --report, do not open the report"
    Write-Host "  --dry-run      Accepted; sw check never changes anything"
    Write-Host "  --debug        Show detailed operation logs"
    Write-Host "  --help         Show this help message"
    Write-Host ""
    Write-Host "$esc[33mChecks:$esc[0m"
    Write-Host "  - Cleanup potential (what sw clean would free)"
    Write-Host "  - Apps and Windows features that can be removed with sw features"
    Write-Host "  - System health: disks, memory, uptime, updates, startup programs"
    Write-Host "  - Project artifacts (what sw purge would offer)"
    Write-Host ""
    Write-Host "Run it in an administrator PowerShell to also check system cleanup and optional Windows features."
    Write-Host ""
}

function Test-CheckOutputAsJson {
    try { return [bool][Console]::IsOutputRedirected }
    catch { return $false }
}

function Get-CheckVersion {
    return [string](Get-SweeprVersionString -RootDir $script:CheckRootDir)
}

# The value of a property, or $Default when the object or the property is missing.
function Get-CheckProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

# A path as it may appear in the result. First normalized: "/" counts as "\" and a leading \\?\
# or \\?\UNC\ is dropped. Then: below the profile as ~\..., below another user's folder as
# C:\Users\<user>\..., a network path as \\<host>\<share>\...; anything else unchanged. Finally
# every whole path part equal to the user name becomes <user> (a redirected AppData folder on a
# file server holds the name).
function Convert-CheckPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return '' }

    $normalize = {
        param([string]$Value)
        $text = $Value.Replace('/', '\')
        if ($text.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) { $text = '\\' + $text.Substring(8) }
        elseif ($text.StartsWith('\\?\', [StringComparison]::Ordinal) -or $text.StartsWith('\\.\', [StringComparison]::Ordinal)) { $text = $text.Substring(4) }
        return $text
    }
    $text = & $normalize $Path
    $result = $text

    $profilePath = ''
    if (-not [string]::IsNullOrEmpty([string]$env:USERPROFILE)) { $profilePath = (& $normalize ([string]$env:USERPROFILE)).TrimEnd('\') }

    if ($profilePath.Length -gt 0 -and $text.Equals($profilePath, [StringComparison]::OrdinalIgnoreCase)) { $result = '~' }
    elseif ($profilePath.Length -gt 0 -and $text.Length -gt $profilePath.Length -and
        $text.StartsWith($profilePath, [StringComparison]::OrdinalIgnoreCase) -and $text[$profilePath.Length] -eq '\') {
        $result = '~' + $text.Substring($profilePath.Length)
    }
    elseif ($text -match '^\\\\([^\\]+)(?:\\([^\\]+))?(\\.*)?$') {
        $rest = ''
        if ($Matches[3]) { $rest = $Matches[3] }
        $result = if ($Matches[2]) { '\\<host>\<share>' + $rest } else { '\\<host>' }
    }
    elseif ($text -match '^([A-Za-z]:\\Users\\)[^\\]+(\\.*)?$') {
        $result = $Matches[1] + '<user>' + $Matches[2]
    }

    $userName = [string]$env:USERNAME
    if ($userName.Length -gt 0) {
        $parts = $result.Split([char]92)
        for ($n = 0; $n -lt $parts.Count; $n++) {
            if ($parts[$n].Equals($userName, [StringComparison]::OrdinalIgnoreCase)) { $parts[$n] = '<user>' }
        }
        $result = $parts -join '\'
    }
    return $result
}

# Reason texts come from a fixed list only; a source text never reaches the result.
function Convert-CheckReason {
    param($Reason)
    $text = ([string]$Reason).Trim()
    if ($text -ieq 'external tool') { return 'external tool' }
    if ($text -ieq 'needs administrator') { return 'needs administrator' }
    if ($text -match '^(?i)error') { return 'error' }
    return 'not available'
}

function New-CheckNotMeasured {
    param([string]$Section, [string]$Name, $Reason)
    return [pscustomobject][ordered]@{
        Section = $Section
        Name    = Convert-CheckPath -Path $Name
        Reason  = Convert-CheckReason -Reason $Reason
    }
}

function New-CheckFailedSection {
    return [pscustomobject][ordered]@{ Status = 'error'; Reason = 'error' }
}

function Format-CheckDate {
    param($Value)
    if ($null -eq $Value) { return $null }
    try { return ([datetime]$Value).ToString('s', [System.Globalization.CultureInfo]::InvariantCulture) }
    catch { return $null }
}

function Format-CheckNumber {
    param($Value)
    if ($null -eq $Value) { return '?' }
    return ([double]$Value).ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

# ============================================================================
# Areas: data in, allowlisted section out
# ============================================================================

function Get-CheckCleanSection {
    param($Preview, [bool]$IncludesSystem)

    $groups = [System.Collections.Generic.List[object]]::new()
    foreach ($section in @(Get-CheckProperty $Preview 'Sections')) {
        if ($null -eq $section) { continue }
        $groups.Add([pscustomobject][ordered]@{
                Name       = [string](Get-CheckProperty $section 'Name' '')
                TotalBytes = [long](Get-CheckProperty $section 'TotalBytes' 0)
                Count      = [int](Get-CheckProperty $section 'Count' 0)
            })
    }

    $top = [System.Collections.Generic.List[object]]::new()
    $hits = @(Get-CheckProperty $Preview 'Hits')
    $biggest = @($hits | Where-Object { $null -ne $_ } | Sort-Object -Property @{ Expression = { [long](Get-CheckProperty $_ 'SizeBytes' 0) }; Descending = $true } | Select-Object -First (Get-CheckLimits).TopCount)
    foreach ($hit in $biggest) {
        $top.Add([pscustomobject][ordered]@{
                Section   = [string](Get-CheckProperty $hit 'Section' '')
                Path      = Convert-CheckPath -Path ([string](Get-CheckProperty $hit 'Path' ''))
                SizeBytes = [long](Get-CheckProperty $hit 'SizeBytes' 0)
                Count     = [int](Get-CheckProperty $hit 'Count' 0)
            })
    }

    return [pscustomobject][ordered]@{
        Status         = 'ok'
        Reason         = $null
        IncludesSystem = $IncludesSystem
        TotalBytes     = [long](Get-CheckProperty $Preview 'TotalBytes' 0)
        Count          = [int](Get-CheckProperty $Preview 'Count' 0)
        Groups         = $groups.ToArray()
        Top            = $top.ToArray()
    }
}

function Get-CheckAppsSection {
    param($Inventory)

    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @(Get-CheckProperty $Inventory 'Items')) {
        if ($null -eq $item) { continue }
        $items.Add([pscustomobject][ordered]@{
                Id    = [string](Get-CheckProperty $item 'Id' '')
                Kind  = [string](Get-CheckProperty $item 'Kind' '')
                Title = [string](Get-CheckProperty $item 'Title' '')
            })
    }
    return [pscustomobject][ordered]@{
        Status     = 'ok'
        Reason     = $null
        Count      = $items.Count
        NeedsAdmin = [bool](Get-CheckProperty $Inventory 'FeaturesNeedAdmin' $false)
        Items      = $items.ToArray()
    }
}

function Get-CheckSystemSection {
    param($Health)

    $drives = [System.Collections.Generic.List[object]]::new()
    $disks = Get-CheckProperty $Health 'Disks'
    foreach ($drive in @(Get-CheckProperty $disks 'Drives')) {
        if ($null -eq $drive) { continue }
        $drives.Add([pscustomobject][ordered]@{
                Drive       = [string](Get-CheckProperty $drive 'Drive' '')
                SizeBytes   = Get-CheckProperty $drive 'SizeBytes'
                FreeBytes   = Get-CheckProperty $drive 'FreeBytes'
                FreePercent = Get-CheckProperty $drive 'FreePercent'
                IsSystem    = [bool](Get-CheckProperty $drive 'IsSystem' $false)
                Health      = [string](Get-CheckProperty $drive 'Health' '')
            })
    }

    $memory = Get-CheckProperty $Health 'Memory'
    $uptime = Get-CheckProperty $Health 'Uptime'
    $updates = Get-CheckProperty $Health 'Updates'
    $pending = Get-CheckProperty $Health 'PendingUpdates'
    $startup = Get-CheckProperty $Health 'Startup'

    $recent = [System.Collections.Generic.List[object]]::new()
    foreach ($update in @(Get-CheckProperty $updates 'Recent')) {
        if ($null -eq $update) { continue }
        $recent.Add([pscustomobject][ordered]@{
                Id          = [string](Get-CheckProperty $update 'Id' '')
                InstalledOn = Format-CheckDate (Get-CheckProperty $update 'InstalledOn')
            })
    }

    # Name and source only; the command line of a startup entry can hold paths and arguments.
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @(Get-CheckProperty $startup 'Entries')) {
        if ($null -eq $entry) { continue }
        $entries.Add([pscustomobject][ordered]@{
                Name   = Convert-CheckPath -Path ([string](Get-CheckProperty $entry 'Name' ''))
                Source = [string](Get-CheckProperty $entry 'Source' '')
            })
    }

    return [pscustomobject][ordered]@{
        Status         = 'ok'
        Reason         = $null
        Disks          = [pscustomobject][ordered]@{
            Measured = [bool](Get-CheckProperty $disks 'Measured' $false)
            Drives   = $drives.ToArray()
        }
        Memory         = [pscustomobject][ordered]@{
            Measured    = [bool](Get-CheckProperty $memory 'Measured' $false)
            TotalBytes  = Get-CheckProperty $memory 'TotalBytes'
            FreeBytes   = Get-CheckProperty $memory 'FreeBytes'
            UsedBytes   = Get-CheckProperty $memory 'UsedBytes'
            UsedPercent = Get-CheckProperty $memory 'UsedPercent'
        }
        Uptime         = [pscustomobject][ordered]@{
            Measured   = [bool](Get-CheckProperty $uptime 'Measured' $false)
            LastBoot   = Format-CheckDate (Get-CheckProperty $uptime 'LastBoot')
            UptimeDays = Get-CheckProperty $uptime 'UptimeDays'
        }
        Updates        = [pscustomobject][ordered]@{
            Measured        = [bool](Get-CheckProperty $updates 'Measured' $false)
            LastInstalledOn = Format-CheckDate (Get-CheckProperty $updates 'LastInstalledOn')
            Recent          = $recent.ToArray()
        }
        PendingUpdates = [pscustomobject][ordered]@{
            Measured  = [bool](Get-CheckProperty $pending 'Measured' $false)
            Total     = Get-CheckProperty $pending 'Total'
            Important = Get-CheckProperty $pending 'Important'
        }
        Startup        = [pscustomobject][ordered]@{
            Measured = [bool](Get-CheckProperty $startup 'Measured' $false)
            Count    = Get-CheckProperty $startup 'Count'
            Entries  = $entries.ToArray()
        }
    }
}

# Health parts that could not be read, as not-measured entries (name of the part, cleaned reason).
function Get-CheckSystemNotMeasured {
    param($Health)
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($name in @('Disks', 'Memory', 'Uptime', 'Updates', 'PendingUpdates', 'Startup')) {
        $part = Get-CheckProperty $Health $name
        if ($null -eq $part -or -not [bool](Get-CheckProperty $part 'Measured' $false)) {
            $result.Add((New-CheckNotMeasured -Section 'System' -Name $name -Reason (Get-CheckProperty $part 'Reason')))
        }
    }
    return $result.ToArray()
}

function Get-CheckProjectsSection {
    param($Preview)

    $projects = @(Get-CheckProperty $Preview 'Projects' | Where-Object { $null -ne $_ })
    $timedOut = $false
    foreach ($root in @(Get-CheckProperty $Preview 'Roots')) {
        if ($null -ne $root -and [bool](Get-CheckProperty $root 'TimedOut' $false)) { $timedOut = $true }
    }

    $top = [System.Collections.Generic.List[object]]::new()
    $biggest = @($projects | Sort-Object -Property @{ Expression = { [long](Get-CheckProperty $_ 'TotalBytes' 0) }; Descending = $true } | Select-Object -First (Get-CheckLimits).TopCount)
    foreach ($project in $biggest) {
        $label = [string](Get-CheckProperty $project 'DisplayPath' '')
        if ([string]::IsNullOrEmpty($label)) { $label = [string](Get-CheckProperty $project 'Path' '') }
        $top.Add([pscustomobject][ordered]@{
                Path         = Convert-CheckPath -Path $label
                Name         = Convert-CheckPath -Path ([string](Get-CheckProperty $project 'Name' ''))
                TotalBytes   = [long](Get-CheckProperty $project 'TotalBytes' 0)
                SizeComplete = [bool](Get-CheckProperty $project 'SizeComplete' $false)
            })
    }

    return [pscustomobject][ordered]@{
        Status            = 'ok'
        Reason            = $null
        Count             = $projects.Count
        TotalBytes        = [long](Get-CheckProperty $Preview 'TotalBytes' 0)
        Complete          = [bool](Get-CheckProperty $Preview 'Complete' $false)
        TimedOut          = $timedOut
        SkippedUnverified = [int](Get-CheckProperty $Preview 'SkippedUnverified' 0)
        Top               = $top.ToArray()
    }
}

# ============================================================================
# Console summary
# ============================================================================

function Write-CheckSummary {
    param($Result, [string]$ReportPath, [string]$ReportProblem)

    $clean = $Result.Sections.Clean
    $apps = $Result.Sections.Apps
    $system = $Result.Sections.System
    $projects = $Result.Sections.Projects

    Write-Host ""
    if ($clean.Status -ne 'ok') { Write-Host "Cleanup potential: error" }
    else {
        $files = if ($clean.Count -eq 1) { 'file' } else { 'files' }
        Write-Host ("Cleanup potential: {0} in {1} {2}" -f (Format-ByteSize $clean.TotalBytes), $clean.Count, $files)
    }

    if ($apps.Status -ne 'ok') { Write-Host "Apps and features: error" }
    else { Write-Host ("Apps and features: {0} can be removed with sw features" -f $apps.Count) }

    if ($system.Status -ne 'ok') { Write-Host "System health: error" }
    else {
        Write-Host "System health:"
        if ($system.Disks.Measured) {
            foreach ($drive in @($system.Disks.Drives)) {
                Write-Host ("  Disk {0} {1} free of {2}" -f $drive.Drive, (Format-ByteSize ([long]$drive.FreeBytes)), (Format-ByteSize ([long]$drive.SizeBytes)))
            }
        }
        else { Write-Host "  Disks: not measured" }
        if ($system.Memory.Measured) { Write-Host ("  Memory: {0}% used" -f (Format-CheckNumber $system.Memory.UsedPercent)) }
        else { Write-Host "  Memory: not measured" }
        if ($system.Uptime.Measured) { Write-Host ("  Uptime: {0} days" -f (Format-CheckNumber $system.Uptime.UptimeDays)) }
        else { Write-Host "  Uptime: not measured" }
        if ($system.Startup.Measured) { Write-Host ("  Startup programs: {0}" -f $system.Startup.Count) }
        else { Write-Host "  Startup programs: not measured" }
    }

    if ($projects.Status -ne 'ok') { Write-Host "Project artifacts: error" }
    else {
        $noun = if ($projects.Count -eq 1) { 'project' } else { 'projects' }
        $size = Format-ByteSize $projects.TotalBytes
        if ($projects.Complete) { Write-Host ("Project artifacts: {0} in {1} {2}" -f $size, $projects.Count, $noun) }
        else { Write-Host ("Project artifacts: at least {0} in {1} {2} (incomplete)" -f $size, $projects.Count, $noun) }
    }

    $missing = @($Result.NotMeasured)
    if ($missing.Count -gt 0) {
        $parts = [System.Collections.Generic.List[string]]::new()
        foreach ($reason in @($missing | ForEach-Object { $_.Reason } | Select-Object -Unique)) {
            $names = @($missing | Where-Object { $_.Reason -eq $reason } | ForEach-Object { $_.Name })
            $parts.Add(("{0} ({1})" -f ($names -join ', '), $reason))
        }
        Write-Host ("Not measured: {0}" -f ($parts.ToArray() -join '; '))
    }

    if (-not $Result.IsAdmin) {
        Write-Host "Run Sweepr in an administrator PowerShell to also check system cleanup and optional Windows features."
    }
    if ($ReportPath) { Write-Host ("Report: {0}" -f $ReportPath) }
    if ($ReportProblem) { Write-Host $ReportProblem -ForegroundColor Red }
    Write-Host "Nothing was changed."
    Write-Host ""
}

# ============================================================================
# Command
# ============================================================================

function Invoke-CheckCommand {
    param(
        [switch]$Json,
        [switch]$Report,
        [switch]$NoOpen,
        [switch]$DryRun,
        [switch]$ShowHelp
    )

    $script:CheckExitCode = 0
    if ($ShowHelp) {
        Show-CheckHelp
        return
    }

    # --dry-run is accepted and changes nothing: sw check is always a dry run.
    $asJson = $Json.IsPresent -and (Test-CheckOutputAsJson)
    $savedDryRun = [bool](Test-DryRunMode)
    $savedNoOplog = $env:SWEEPR_NO_OPLOG
    $reportPath = $null
    $reportProblem = $null
    $result = $null

    try {
        Set-DryRunMode -Enabled $true
        $env:SWEEPR_NO_OPLOG = '1'

        # Not being able to ask the system counts as not elevated.
        $isAdmin = $false
        try { $isAdmin = [bool](Test-IsAdmin) } catch { $isAdmin = $false }
        $sections = [ordered]@{}
        $notMeasured = [System.Collections.Generic.List[object]]::new()

        # Clean (-System only as administrator; no tool of the PC is started)
        try {
            $previewArgs = @{ SkipExternalTools = $true }
            if ($isAdmin) { $previewArgs['System'] = $true }
            $preview = Get-SweeprCleanPreview @previewArgs
            $sections['Clean'] = Get-CheckCleanSection -Preview $preview -IncludesSystem $isAdmin
            foreach ($entry in @(Get-CheckProperty $preview 'NotMeasured')) {
                if ($null -eq $entry) { continue }
                $notMeasured.Add((New-CheckNotMeasured -Section 'Clean' -Name ([string](Get-CheckProperty $entry 'Name' '')) -Reason (Get-CheckProperty $entry 'Reason')))
            }
            if (-not $isAdmin -and @($notMeasured | Where-Object { $_.Section -eq 'Clean' -and $_.Name -eq 'System cleanup' }).Count -eq 0) {
                $notMeasured.Add((New-CheckNotMeasured -Section 'Clean' -Name 'System cleanup' -Reason 'needs administrator'))
            }
        }
        catch {
            Write-Debug "sw check: cleanup area failed: $($_.Exception.Message)"
            $sections['Clean'] = New-CheckFailedSection
        }

        # Apps
        try {
            $inventory = Get-SweeprFeatureInventory
            $sections['Apps'] = Get-CheckAppsSection -Inventory $inventory
            if ($sections['Apps'].NeedsAdmin) {
                $notMeasured.Add((New-CheckNotMeasured -Section 'Apps' -Name 'Optional Windows features' -Reason 'needs administrator'))
            }
        }
        catch {
            Write-Debug "sw check: apps area failed: $($_.Exception.Message)"
            $sections['Apps'] = New-CheckFailedSection
        }

        # System
        try {
            $health = Get-SweeprHealth
            $sections['System'] = Get-CheckSystemSection -Health $health
            foreach ($entry in @(Get-CheckSystemNotMeasured -Health $health)) { $notMeasured.Add($entry) }
        }
        catch {
            Write-Debug "sw check: system area failed: $($_.Exception.Message)"
            $sections['System'] = New-CheckFailedSection
        }

        # Projects (the built-in folders; the limits are bound here, not left to the defaults)
        try {
            $limits = Get-CheckLimits
            $purge = Get-SweeprPurgePreview -MaxDepth $limits.ProjectMaxDepth -MaxSecondsPerRoot $limits.ProjectSecondsPerRoot -MaxTotalSeconds $limits.ProjectSecondsTotal -MaxSizeFiles $limits.ProjectSizeFiles
            $sections['Projects'] = Get-CheckProjectsSection -Preview $purge
            if (-not $sections['Projects'].Complete) {
                $why = if ($sections['Projects'].TimedOut) { 'time limit' } else { 'incomplete' }
                # The reason is one of the two fixed texts; they are not run through the source filter.
                $notMeasured.Add([pscustomobject][ordered]@{ Section = 'Projects'; Name = 'Project artifacts'; Reason = $why })
            }
        }
        catch {
            Write-Debug "sw check: project area failed: $($_.Exception.Message)"
            $sections['Projects'] = New-CheckFailedSection
        }

        $result = [pscustomobject][ordered]@{
            Version     = [string](Get-CheckVersion)
            GeneratedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz', [System.Globalization.CultureInfo]::InvariantCulture)
            IsAdmin     = $isAdmin
            Sections    = [pscustomobject]$sections
            NotMeasured = $notMeasured.ToArray()
        }

        if ($Report) {
            if (-not (Get-Command -Name 'Invoke-SweeprCheckReport' -ErrorAction SilentlyContinue)) {
                $reportProblem = "The report is not available in this version."
                $script:CheckExitCode = 1
            }
            else {
                try {
                    $made = @(Invoke-SweeprCheckReport -Result $result -NoOpen:$NoOpen | Where-Object { $_ -is [string] -and $_.Length -gt 0 })
                    if ($made.Count -gt 0) { $reportPath = [string]$made[$made.Count - 1] }
                }
                catch {
                    Write-Debug "sw check: report failed: $($_.Exception.Message)"
                    $reportProblem = "The report is not available: it could not be created."
                    $script:CheckExitCode = 1
                }
            }
        }
    }
    finally {
        Set-DryRunMode -Enabled $savedDryRun
        $env:SWEEPR_NO_OPLOG = $savedNoOplog
    }

    if ($asJson) {
        # One document on the success stream; a report problem goes to the error stream.
        if ($reportProblem) { [Console]::Error.WriteLine($reportProblem) }
        ConvertTo-Json -InputObject $result -Depth 10
        return
    }
    Write-CheckSummary -Result $result -ReportPath $reportPath -ReportProblem $reportProblem
}

# Run main
if ($DebugMode) {
    Enable-DebugMode
    $DebugPreference = "Continue"
}
try { Invoke-CheckCommand -Json:$Json -Report:$Report -NoOpen:$NoOpen -DryRun:$DryRun -ShowHelp:$ShowHelp }
finally { Stop-Spinner }
if ($script:CheckExitCode -ne 0) { exit $script:CheckExitCode }
