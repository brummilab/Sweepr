# Sweepr - user section of sw clean: old temp files, error reports, old log files
#
# The section "User essentials" and the report rule that the system section shares. Loaded by
# dot-sourcing. Loading writes nothing, creates no file or folder and starts no process; it only
# defines functions. A second load in the same scope changes nothing.
#
# Nothing here removes anything itself. What is chosen goes to Remove-SwOldFiles and Remove-SwItems,
# which decide about protection, whitelist, file identity and dry run, in a preview and in a real run
# alike. Only plain files directly in a folder are offered, never the folders below it, except the
# error reports, where a whole report folder is offered once it is old all the way down.
#
# Script variable that callers may replace: SwProbeBudgetSeconds (see cache_guard.ps1).

# The dependencies come from the folder of this file, never from the working directory.
. ([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PSScriptRoot), 'core', 'base.ps1'))
. ([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PSScriptRoot), 'core', 'log.ps1'))
. ([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PSScriptRoot), 'core', 'file_ops.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'cache_guard.ps1'))

# ============================================================================
# Report rule
# ============================================================================

function Get-SwReportChecks {
    # The state that the conditions of the report offers need. A condition runs inside the helper long
    # after the function that made it has returned, so its data is kept here under a key that its text
    # names. Created on first use.
    $existing = Get-Variable -Name 'SwReportChecks' -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $existing -or $existing.Value -isnot [hashtable]) { $script:SwReportChecks = @{} }
    return $script:SwReportChecks
}

function Reset-SwReportChecks {
    # Empties the table of the report offers. Every section run starts with an empty one, so that it
    # does not grow when the sections run more than once in a process. Never throws.
    try { $null = (Get-SwReportChecks).Clear() }
    catch { $script:SwReportChecks = @{} }
}

function Test-SwReportEntryAge {
    <#
    .SYNOPSIS
        'Old', 'New' or 'Incomplete' for one report: an entry and everything below it.
    .DESCRIPTION
        The entry and every descendant, hidden and system entries included, must exist, be readable and
        be no link, and both their write time and their creation time must lie strictly before the
        cut-off. One entry that does not say so makes the report 'New'. More than 4096 entries or more
        than the probe budget make it 'Incomplete'. Times are read afresh at every call. Never throws.
    #>
    param([string]$Path, [datetime]$Cutoff)

    try {
        $ErrorActionPreference = 'Stop'
        $budget = Get-SwCleanProbeBudget
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        if ([System.IO.Directory]::Exists($Path)) { $top = [System.IO.DirectoryInfo]::new($Path) }
        elseif ([System.IO.File]::Exists($Path)) { $top = [System.IO.FileInfo]::new($Path) }
        else { return 'New' }

        $pending = [System.Collections.Generic.Stack[object]]::new()
        $pending.Push($top)
        $seen = 0
        while ($pending.Count -gt 0) {
            $node = $pending.Pop()
            $seen++
            if ($seen -gt 4096 -or $clock.Elapsed.TotalSeconds -ge $budget) { return 'Incomplete' }
            $attributes = $node.Attributes
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return 'New' }
            if (-not ($node.LastWriteTime -lt $Cutoff)) { return 'New' }
            if (-not ($node.CreationTime -lt $Cutoff)) { return 'New' }
            if ($node -is [System.IO.DirectoryInfo]) {
                foreach ($child in $node.EnumerateFileSystemInfos()) { $pending.Push($child) }
            }
        }
        return 'Old'
    }
    catch { return 'New' }
}

function Test-SwReportRemovable {
    # The condition of one report offer: the root still has the identity it had when it was listed and
    # the report is still old with the same cut-off, judged on freshly read times. Exactly one [bool].
    param([string]$Key, [string]$Path)

    try {
        $checks = Get-SwReportChecks
        if (-not $checks.ContainsKey($Key)) { return $false }
        $state = $checks[$Key]
        $unchanged = @(Test-SwPathSnapshot -Snapshot $state.Snapshot)
        if (-not (($unchanged.Count -eq 1) -and ($unchanged[0] -is [bool]) -and ($unchanged[0] -eq $true))) { return $false }
        return ((Test-SwReportEntryAge -Path $Path -Cutoff $state.Cutoff) -ceq 'Old')
    }
    catch { return $false }
}

function Clear-SwReportRoot {
    <#
    .SYNOPSIS
        Offers the old error reports directly in one folder, one Remove-SwItems call per report.
    .DESCRIPTION
        Writes nothing to the pipeline and never throws. A report is a direct entry of the root, folder
        or file, hidden ones included; with -DumpOnly only files ending in .dmp. It is offered only
        when it is old all the way down (see Test-SwReportEntryAge) against one cut-off fixed at the
        start. The condition of the offer repeats the age check on fresh times and the identity check
        of the root after the helper has measured the report. The whole root is left alone, and noted
        as not verified or as an incomplete scan, when it has no file identity (a link, or below a
        link), holds more than 4096 entries, takes longer than the probe budget or changed while it
        was listed. A negative number of days offers nothing.
    #>
    param(
        [string]$Root,
        [int]$DaysOld,
        [string]$Description,
        [switch]$DumpOnly
    )

    try {
        $ErrorActionPreference = 'Stop'
        if ($DaysOld -lt 0) { return }
        if (-not (Test-SwCleanCompletePath -Path $Root)) { return }
        if (-not (Test-SwCleanDirectory -Path $Root)) { return }
        # The whole root path names the entry: the user and the system root have the same last segments.
        $label = $Description + ' (' + $Root + ')'

        $snapshot = Get-SwPathSnapshot -Path $Root
        if ($null -eq $snapshot) {
            Add-SwCleanNotMeasured -Name $label -Reason 'not verified'
            return
        }

        # One cut-off for the whole call, so that a clock that moves on cannot change what is old.
        $cutoff = (Get-Date).AddDays(-$DaysOld)
        $budget = Get-SwCleanProbeBudget
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        if ($clock.Elapsed.TotalSeconds -ge $budget) {
            Add-SwCleanNotMeasured -Name $label -Reason 'incomplete scan'
            return
        }

        $entries = [System.Collections.Generic.List[object]]::new()
        try {
            foreach ($entry in [System.IO.DirectoryInfo]::new($Root).EnumerateFileSystemInfos()) {
                $entries.Add($entry)
                if ($entries.Count -gt 4096 -or $clock.Elapsed.TotalSeconds -ge $budget) {
                    Add-SwCleanNotMeasured -Name $label -Reason 'incomplete scan'
                    return
                }
            }
        }
        catch {
            Add-SwCleanNotMeasured -Name $label -Reason 'incomplete scan'
            return
        }

        $unchanged = @(Test-SwPathSnapshot -Snapshot $snapshot)
        if (-not (($unchanged.Count -eq 1) -and ($unchanged[0] -is [bool]) -and ($unchanged[0] -eq $true))) {
            Add-SwCleanNotMeasured -Name $label -Reason 'not verified'
            return
        }

        $key = [guid]::NewGuid().ToString('N')
        $registered = $false
        foreach ($entry in $entries) {
            try {
                $path = Join-SwCleanPath -Base $Root -Rest @([string]$entry.Name)
                if ($DumpOnly) {
                    if ($entry -is [System.IO.DirectoryInfo]) { continue }
                    if (-not ([string]$entry.Name).EndsWith('.dmp', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                }
                $age = Test-SwReportEntryAge -Path $path -Cutoff $cutoff
                if ($age -ceq 'Incomplete') {
                    Add-SwCleanNotMeasured -Name $label -Reason 'incomplete scan'
                    continue
                }
                if ($age -cne 'Old') { continue }
                if (-not $registered) {
                    (Get-SwReportChecks)[$key] = @{ Snapshot = $snapshot; Cutoff = $cutoff }
                    $registered = $true
                }
                $condition = [scriptblock]::Create('Test-SwReportRemovable -Key ' + (ConvertTo-SwPsLiteral -Value $key) + ' -Path ' + (ConvertTo-SwPsLiteral -Value $path))
                $null = Remove-SwItems -Paths @($path) -Description $Description -CanRemove $condition
            }
            catch { Write-SwDebug "report not offered, $($entry.Name) in ${Root}: $($_.Exception.Message)" }
        }
    }
    catch { Write-SwDebug "report folder not handled, ${Root}: $($_.Exception.Message)" }
}

# ============================================================================
# Targets
# ============================================================================

function Clear-SwUserTempFiles {
    <#
    .SYNOPSIS
        Offers the old files directly in TEMP. Folders in it and everything below them stay.
    .DESCRIPTION
        Hidden and system files count. Nothing is offered when TEMP is not a complete path, is not a
        folder, is not a plausible root (the profile, a data folder, a known folder, a drive root and so
        on, see Test-SwCleanRootPlausible; noted as not verified) or when the days are negative.
    #>
    param([int]$DaysOld = 7)

    try {
        $ErrorActionPreference = 'Stop'
        if ($DaysOld -lt 0) { return }
        $root = Get-SwCleanEnvRoot -Name 'TEMP'
        if ($null -eq $root) { return }
        if (-not (Test-SwCleanDirectory -Path $root)) { return }
        if (-not (Test-SwCleanRootPlausible -Root $root)) {
            Add-SwCleanNotMeasured -Name 'User temp files' -Reason 'not verified'
            return
        }
        $null = Remove-SwOldFiles -Path $root -DaysOld $DaysOld -Filter '*' -Description 'User temp files'
    }
    catch { Write-SwDebug "temp files not offered: $($_.Exception.Message)" }
}

function Clear-SwErrorReports {
    <#
    .SYNOPSIS
        Offers the old error reports of the user: the report archive, the report queue and old dump files.
    #>
    param([int]$DaysOld = 7)

    try {
        $ErrorActionPreference = 'Stop'
        $local = Get-SwCleanEnvRoot -Name 'LOCALAPPDATA'
        if ($null -eq $local) { return }
        $archive = Join-SwCleanPath -Base $local -Rest @('Microsoft', 'Windows', 'WER', 'ReportArchive')
        $queue = Join-SwCleanPath -Base $local -Rest @('Microsoft', 'Windows', 'WER', 'ReportQueue')
        $dumps = Join-SwCleanPath -Base $local -Rest @('CrashDumps')
        try { $null = Clear-SwReportRoot -Root $archive -DaysOld $DaysOld -Description 'Error reports' }
        catch { Write-SwDebug "error reports not handled, ${archive}: $($_.Exception.Message)" }
        try { $null = Clear-SwReportRoot -Root $queue -DaysOld $DaysOld -Description 'Error reports' }
        catch { Write-SwDebug "error reports not handled, ${queue}: $($_.Exception.Message)" }
        try { $null = Clear-SwReportRoot -Root $dumps -DaysOld $DaysOld -Description 'Error reports' -DumpOnly }
        catch { Write-SwDebug "dump files not handled, ${dumps}: $($_.Exception.Message)" }
    }
    catch { Write-SwDebug "error reports not offered: $($_.Exception.Message)" }
}

function Get-SwOldLogFiles {
    # The old log files directly in a folder: the name ends in .log (compared here, because the file
    # system search of Windows PowerShell 5.1 also finds .log1 and .logfile), the file is neither hidden
    # nor a system file nor a link, and it was last written before the cut-off.
    param([string]$Folder, [datetime]$Cutoff)

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($file in [System.IO.Directory]::EnumerateFiles($Folder)) {
        $name = [System.IO.Path]::GetFileName([string]$file)
        if (-not $name.EndsWith('.log', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $attributes = [System.IO.File]::GetAttributes([string]$file)
        $skip = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System -bor [System.IO.FileAttributes]::ReparsePoint
        if (($attributes -band $skip) -ne 0) { continue }
        if (-not ([System.IO.File]::GetLastWriteTime([string]$file) -lt $Cutoff)) { continue }
        $names.Add($name)
    }
    $ordered = $names.ToArray()
    [System.Array]::Sort($ordered, [System.StringComparer]::Ordinal)
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $ordered) { $paths.Add((Join-SwCleanPath -Base $Folder -Rest @($name))) }
    return $paths.ToArray()
}

function Clear-SwUserLogs {
    <#
    .SYNOPSIS
        Offers the old log files directly in the local Temp folder and directly in APPDATA.
    .DESCRIPTION
        One Remove-SwItems call per folder that has at least one. The local Temp folder is left to the
        temp target when TEMP is the same folder. A folder that is no plausible root is left out and
        noted as not verified. Negative days offer nothing.
    #>
    param([int]$DaysOld = 7)

    try {
        $ErrorActionPreference = 'Stop'
        if ($DaysOld -lt 0) { return }
        $cutoff = (Get-Date).AddDays(-$DaysOld)

        $targets = [System.Collections.Generic.List[object]]::new()
        $local = Get-SwCleanEnvRoot -Name 'LOCALAPPDATA'
        if ($null -ne $local) { $targets.Add([pscustomobject]@{ Folder = (Join-SwCleanPath -Base $local -Rest @('Temp')); AllowEqualTo = '' }) }
        $roaming = Get-SwCleanEnvRoot -Name 'APPDATA'
        # The files of APPDATA itself are the target, so equality with APPDATA is no reason to refuse it.
        if ($null -ne $roaming) { $targets.Add([pscustomobject]@{ Folder = $roaming; AllowEqualTo = 'APPDATA' }) }
        $temp = Get-SwCleanEnvRoot -Name 'TEMP'
        $tempForms = $null
        if ($null -ne $temp) { $tempForms = Get-SwCleanPathForms -Path $temp }

        foreach ($target in $targets) {
            try {
                $folder = [string]$target.Folder
                if (-not (Test-SwCleanDirectory -Path $folder)) { continue }
                # The temp target already offers every old file of this folder, logs included.
                # Same folder when the typed spellings agree or, if both are known, the final ones (links resolved).
                if ($null -ne $tempForms) {
                    $folderForms = Get-SwCleanPathForms -Path $folder
                    if ([string]::Equals($folderForms.Typed, $tempForms.Typed, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                    if ($folderForms.Resolved.Length -gt 0 -and $tempForms.Resolved.Length -gt 0 -and [string]::Equals($folderForms.Resolved, $tempForms.Resolved, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                }
                if (-not (Test-SwCleanRootPlausible -Root $folder -AllowEqualTo ([string]$target.AllowEqualTo))) {
                    Add-SwCleanNotMeasured -Name 'Old log files' -Reason 'not verified'
                    continue
                }
                $paths = @(Get-SwOldLogFiles -Folder $folder -Cutoff $cutoff)
                if ($paths.Count -eq 0) { continue }
                $null = Remove-SwItems -Paths ([string[]]$paths) -Description 'Old log files'
            }
            catch { Write-SwDebug "log files not offered, $($target.Folder): $($_.Exception.Message)" }
        }
    }
    catch { Write-SwDebug "log files not offered: $($_.Exception.Message)" }
}

# ============================================================================
# The section
# ============================================================================

function Invoke-SwUserCleanup {
    <#
    .SYNOPSIS
        The section "User essentials": old temp files, error reports (seven days, whatever TempDaysOld
        says) and old log files. Writes nothing to the pipeline; a failing part stops only itself.
    #>
    param(
        [int]$TempDaysOld = 7,
        [int]$LogDaysOld = 7
    )

    $ErrorActionPreference = 'Stop'
    Start-SwSection 'User essentials'
    try {
        Reset-SwReportChecks
        try { $null = Clear-SwUserTempFiles -DaysOld $TempDaysOld }
        catch { Write-SwDebug "temp files failed: $($_.Exception.Message)" }
        try { $null = Clear-SwErrorReports -DaysOld 7 }
        catch { Write-SwDebug "error reports failed: $($_.Exception.Message)" }
        try { $null = Clear-SwUserLogs -DaysOld $LogDaysOld }
        catch { Write-SwDebug "log files failed: $($_.Exception.Message)" }
    }
    finally { Stop-SwSection }
}

# ============================================================================
# Old names, kept as forwarding functions (not aliases, so a test mock of either name behaves) until
# the callers move to the new ones. The switches of the removed targets are accepted and do nothing.
# ============================================================================

function Invoke-UserCleanup {
    param(
        [Parameter(Position = 0)][int]$TempDaysOld = 7,
        [Parameter(Position = 1)][int]$DownloadsDaysOld = 30,
        [Parameter(Position = 2)][int]$LogDaysOld = 7,
        [switch]$IncludeDownloads,
        [switch]$IncludeRecycleBin
    )
    Invoke-SwUserCleanup -TempDaysOld $TempDaysOld -LogDaysOld $LogDaysOld
}

function Clear-UserTempFiles {
    param([Parameter(Position = 0)][int]$DaysOld = 7)
    Clear-SwUserTempFiles @PSBoundParameters
}

function Clear-ErrorReports {
    param([Parameter(Position = 0)][int]$DaysOld = 7)
    Clear-SwErrorReports @PSBoundParameters
}

function Clear-UserLogs {
    param([Parameter(Position = 0)][int]$DaysOld = 7)
    Clear-SwUserLogs @PSBoundParameters
}

# Other modules rely on these for the rest of their run.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
