# Sweepr - System Health Module
# Read-only system state as data: disks, memory, uptime, updates and startup entries.
# Every function returns one object with Measured and Reason; what could not be read is
# marked (Measured = $false, values $null), never reported as zero or as healthy.

#Requires -Version 5.1
Set-StrictMode -Version Latest

# Prevent multiple sourcing
if ((Get-Variable -Name 'SWEEPR_HEALTH_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:SWEEPR_HEALTH_LOADED) { return }
$script:SWEEPR_HEALTH_LOADED = $true

# Import dependencies
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\base.ps1"

# ============================================================================
# Disks, memory, uptime
# ============================================================================

function Get-SweeprDiskInfo {
    <#
    .SYNOPSIS
        Fixed disks with size, free space and health (Healthy, Warning, Unhealthy or Unknown)
    #>
    [CmdletBinding()]
    param()

    try {
        $disks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop)
    }
    catch {
        return [pscustomobject]@{ Measured = $false; Reason = $_.Exception.Message; Drives = @() }
    }

    $drives = New-Object System.Collections.Generic.List[object]
    foreach ($disk in $disks) {
        [long]$size = $disk.Size
        [long]$free = $disk.FreeSpace
        $freePercent = $null
        if ($size -gt 0) { $freePercent = [Math]::Round(($free / $size) * 100, 1) }

        # The health belongs to the physical disk below the volume. Standard users and
        # older systems may not be allowed to ask; that is Unknown, not Healthy.
        $health = 'Unknown'
        try {
            $letter = ([string]$disk.DeviceID).Substring(0, 1)
            $physical = @(Get-Partition -DriveLetter $letter -ErrorAction Stop | Get-Disk -ErrorAction Stop)
            if ($physical.Count -gt 0) {
                $status = [string]$physical[0].HealthStatus
                if ($status -in @('Healthy', 'Warning', 'Unhealthy')) { $health = $status }
            }
        }
        catch { $health = 'Unknown' }

        $drives.Add([pscustomobject]@{
                Drive       = [string]$disk.DeviceID
                Label       = [string]$disk.VolumeName
                FileSystem  = [string]$disk.FileSystem
                SizeBytes   = $size
                FreeBytes   = $free
                FreePercent = $freePercent
                IsSystem    = [string]::Equals([string]$disk.DeviceID, [string]$env:SystemDrive, [StringComparison]::OrdinalIgnoreCase)
                Health      = $health
            })
    }
    return [pscustomobject]@{ Measured = $true; Reason = $null; Drives = $drives.ToArray() }
}

function Get-SweeprMemoryInfo {
    <#
    .SYNOPSIS
        Total, free and used physical memory in bytes
    #>
    [CmdletBinding()]
    param()

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        # The operating system reports kilobytes.
        [long]$total = [long]$os.TotalVisibleMemorySize * 1024
        [long]$free = [long]$os.FreePhysicalMemory * 1024
        if ($total -le 0) { throw 'The operating system reported no memory size' }
        [long]$used = $total - $free
        return [pscustomobject]@{
            Measured    = $true
            Reason      = $null
            TotalBytes  = $total
            FreeBytes   = $free
            UsedBytes   = $used
            UsedPercent = [Math]::Round(($used / $total) * 100, 1)
        }
    }
    catch {
        return [pscustomobject]@{ Measured = $false; Reason = $_.Exception.Message; TotalBytes = $null; FreeBytes = $null; UsedBytes = $null; UsedPercent = $null }
    }
}

function Get-SweeprUptimeInfo {
    <#
    .SYNOPSIS
        Last boot and uptime in days
    #>
    [CmdletBinding()]
    param([datetime]$Now = (Get-Date))

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $boot = [datetime]$os.LastBootUpTime
        return [pscustomobject]@{
            Measured   = $true
            Reason     = $null
            LastBoot   = $boot
            UptimeDays = [Math]::Round(($Now - $boot).TotalDays, 1)
        }
    }
    catch {
        return [pscustomobject]@{ Measured = $false; Reason = $_.Exception.Message; LastBoot = $null; UptimeDays = $null }
    }
}

# ============================================================================
# Updates
# ============================================================================

function Get-SweeprUpdateInfo {
    <#
    .SYNOPSIS
        Date of the last installed update and the most recent ones, newest first
    #>
    [CmdletBinding()]
    param([int]$Count = 5)

    try {
        # Entries without a date cannot be placed in time and are ignored.
        $dated = @(Get-HotFix -ErrorAction Stop | Where-Object { $null -ne $_.InstalledOn } | Sort-Object -Property InstalledOn -Descending)
        $recent = @($dated | Select-Object -First $Count | ForEach-Object {
                [pscustomobject]@{ Id = [string]$_.HotFixID; Description = [string]$_.Description; InstalledOn = [datetime]$_.InstalledOn }
            })
        $last = $null
        if ($dated.Count -gt 0) { $last = [datetime]$dated[0].InstalledOn }
        return [pscustomobject]@{ Measured = $true; Reason = $null; LastInstalledOn = $last; Recent = $recent }
    }
    catch {
        return [pscustomobject]@{ Measured = $false; Reason = $_.Exception.Message; LastInstalledOn = $null; Recent = @() }
    }
}

function Get-SweeprPendingUpdates {
    <#
    .SYNOPSIS
        Pending updates from the local Windows Update catalog (no network)
    #>
    [CmdletBinding()]
    param([int]$TimeoutSeconds = 5)

    $job = $null
    try {
        # Query the local catalog in a disposable process: COM can stall even
        # without network access, and must not hold the caller open.
        $job = Start-Job -ScriptBlock {
            $ErrorActionPreference = 'Stop'
            $updateSession = New-Object -ComObject Microsoft.Update.Session
            $updateSearcher = $updateSession.CreateUpdateSearcher()
            $updateSearcher.Online = $false
            $searchResult = $updateSearcher.Search("IsInstalled=0")
            [pscustomobject]@{
                Total = $searchResult.Updates.Count
                Important = @($searchResult.Updates | Where-Object { $_.MsrcSeverity -in @('Critical', 'Important') }).Count
            }
        }
        $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
        if (-not $completed -or $job.State -ne 'Completed') { throw 'Windows Update query did not complete' }
        $result = @(Receive-Job -Job $job -ErrorAction Stop)
        if ($result.Count -ne 1 -or $null -eq $result[0].Total -or $null -eq $result[0].Important -or
            $result[0].Total -lt 0 -or $result[0].Important -lt 0 -or $result[0].Important -gt $result[0].Total) {
            throw 'Windows Update query returned an incomplete result'
        }
        return [pscustomobject]@{ Measured = $true; Reason = $null; Total = [int]$result[0].Total; Important = [int]$result[0].Important }
    }
    catch {
        return [pscustomobject]@{ Measured = $false; Reason = $_.Exception.Message; Total = $null; Important = $null }
    }
    finally {
        if ($null -ne $job) {
            if ($job.State -notin @('Completed', 'Failed', 'Stopped')) { Stop-Job -Job $job -ErrorAction SilentlyContinue }
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }
}

# ============================================================================
# Startup
# ============================================================================

function Get-SweeprStartupEntries {
    <#
    .SYNOPSIS
        Registered startup programs (Run keys and the Startup folder)
    .DESCRIPTION
        Missing is the list of sources that exist but could not be read. A source that does not
        exist counts as empty. Registered entries may be disabled in StartupApproved; they are
        counted without inferring a health issue from quantity alone.
    #>
    [CmdletBinding()]
    param()

    $entries = New-Object System.Collections.Generic.List[object]
    $missing = New-Object System.Collections.Generic.List[string]
    $sourcesRead = 0
    $providerNames = @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')

    $runKeys = @(
        @{ Source = 'HKCU Run'; Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' }
        @{ Source = 'HKLM Run'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' }
        @{ Source = 'HKLM Run (32-bit)'; Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' }
    )
    foreach ($key in $runKeys) {
        try {
            if (Test-Path $key.Path) {
                $items = Get-ItemProperty -Path $key.Path -ErrorAction Stop
                foreach ($property in @($items.PSObject.Properties | Where-Object { $_.Name -notin $providerNames })) {
                    $entries.Add([pscustomobject]@{ Name = [string]$property.Name; Command = [string]$property.Value; Source = $key.Source })
                }
            }
            $sourcesRead++
        }
        catch { $missing.Add($key.Source) }
    }

    try {
        $startupFolder = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
        if (Test-Path $startupFolder) {
            foreach ($file in @(Get-ChildItem -Path $startupFolder -File -ErrorAction Stop)) {
                $entries.Add([pscustomobject]@{ Name = [string]$file.Name; Command = [string]$file.FullName; Source = 'Startup folder' })
            }
        }
        $sourcesRead++
    }
    catch { $missing.Add('Startup folder') }

    $measured = $sourcesRead -gt 0
    $reason = $null
    if (-not $measured) { $reason = 'No startup source could be read' }
    return [pscustomobject]@{
        Measured = $measured
        Reason   = $reason
        Entries  = $entries.ToArray()
        Count    = $entries.Count
        Missing  = $missing.ToArray()
    }
}

# ============================================================================
# Everything at once
# ============================================================================

function Get-SweeprHealth {
    <#
    .SYNOPSIS
        All system state parts in one object; a failing part never hides the others
    #>
    [CmdletBinding()]
    param()

    $isAdmin = $false
    try { $isAdmin = [bool](Test-IsAdmin) } catch { $isAdmin = $false }

    $parts = [ordered]@{
        Disks          = { Get-SweeprDiskInfo }
        Memory         = { Get-SweeprMemoryInfo }
        Uptime         = { Get-SweeprUptimeInfo }
        Updates        = { Get-SweeprUpdateInfo }
        PendingUpdates = { Get-SweeprPendingUpdates }
        Startup        = { Get-SweeprStartupEntries }
    }
    $health = [ordered]@{ IsAdmin = $isAdmin }
    $notMeasured = New-Object System.Collections.Generic.List[object]
    foreach ($name in @($parts.Keys)) {
        try { $part = & $parts[$name] }
        catch { $part = [pscustomobject]@{ Measured = $false; Reason = $_.Exception.Message } }
        $health[$name] = $part
        if (-not $part.Measured) { $notMeasured.Add([pscustomobject]@{ Name = $name; Reason = $part.Reason }) }
    }
    $health['NotMeasured'] = $notMeasured.ToArray()
    return [pscustomobject]$health
}
