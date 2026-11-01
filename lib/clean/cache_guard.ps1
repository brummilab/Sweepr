# Sweepr - cache guard: what the clean sections share
#
# The owner probe for a cache that belongs to a running program, the cleaner for one cache folder, the
# discovery of the profile folders below a browser or application root, and the small path and
# plausibility helpers that the sections of sw clean build on. Loaded by dot-sourcing. Loading writes
# nothing, creates no file or folder and starts no process; it only defines functions. A second load
# in the same scope changes nothing.
#
# Nothing here removes anything. A cache folder goes to Clear-SwDirectoryContents with a condition that
# asks the owner probe afresh at every call, so a program that starts after the measurement keeps its
# cache. Whenever the probe cannot decide, the answer is "the owner may be working": the cache stays.
#
# Script variable that callers may replace: SwProbeBudgetSeconds (seconds one profile or report scan
# may take; 2 when it is missing or not a number; 0 counts as always used up). It is never created here.

# The dependencies come from the folder of this file, never from the working directory.
. ([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PSScriptRoot), 'core', 'base.ps1'))
. ([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PSScriptRoot), 'core', 'log.ps1'))
. ([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PSScriptRoot), 'core', 'file_ops.ps1'))

# ============================================================================
# Paths from the environment
# ============================================================================

function Test-SwCleanCompletePath {
    # A path that means the same place for every API: a drive letter with a separator, and on hosts
    # without drive letters a leading slash. Relative, root-relative, drive-relative and UNC paths are
    # not complete, so a damaged variable can never point a target at the current drive or a share.
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path.IndexOf([char]0) -ge 0) { return $false }
    if ([regex]::IsMatch($Path, '\A[A-Za-z]:[\\/]')) { return $true }
    if ([System.IO.Path]::DirectorySeparatorChar -eq '/' -and $Path.StartsWith('/', [System.StringComparison]::Ordinal)) { return $true }
    return $false
}

function Get-SwCleanEnvRoot {
    # The trimmed value of an environment variable when it is a complete path, otherwise $null: every
    # target that needs the variable is then left out.
    param([string]$Name)

    try { $value = [System.Environment]::GetEnvironmentVariable($Name) }
    catch { return $null }
    if ($null -eq $value) { return $null }
    $value = ([string]$value).Trim()
    if (-not (Test-SwCleanCompletePath -Path $value)) { return $null }
    return $value
}

function Join-SwCleanPath {
    # Base plus the segments, joined with one separator of the host. A trailing separator of the base
    # goes only when something is appended; without segments the base is returned as it is.
    param([string]$Base, [string[]]$Rest)

    $segments = @($Rest)
    if ($segments.Count -eq 0) { return $Base }
    $separator = [string][System.IO.Path]::DirectorySeparatorChar
    $path = $Base.TrimEnd([char[]]@('\', '/'))
    foreach ($segment in $segments) { $path = $path + $separator + $segment }
    return $path
}

function Test-SwCleanDirectory {
    # True for an existing folder. The check is literal: [ ] * ? and backquotes are part of the name.
    param([string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $false }
    try { return [bool][System.IO.Directory]::Exists($Path) }
    catch { return $false }
}

function Get-SwCleanProbeBudget {
    # Seconds one scan of profiles or reports may take. A missing or unusable variable gives 2; a
    # negative one and 0 give 0, which counts as always used up.
    try { $raw = $script:SwProbeBudgetSeconds }
    catch { return [double]2 }
    if ($null -eq $raw) { return [double]2 }
    try { $value = [double]$raw }
    catch { return [double]2 }
    if ($value -lt 0) { return [double]0 }
    return $value
}

function Get-SwCleanRootLabel {
    # A short name for a scan root in the list of what could not be measured: the last two segments, so
    # that two browsers with a "User Data" folder stay apart.
    param([string]$Path)

    try {
        $trimmed = $Path.TrimEnd([char[]]@('\', '/'))
        $leaf = [System.IO.Path]::GetFileName($trimmed)
        $parent = [System.IO.Path]::GetDirectoryName($trimmed)
        if ([string]::IsNullOrEmpty($parent)) { return $leaf }
        $above = [System.IO.Path]::GetFileName($parent)
        if ([string]::IsNullOrEmpty($above)) { return $leaf }
        return ($above + ' ' + $leaf)
    }
    catch { return [string]$Path }
}

function Add-SwCleanNotMeasured {
    # Notes that a target was left out because it could not be verified or scanned completely. The
    # reason is one of the two fixed texts 'not verified' and 'incomplete scan'. Nothing is logged.
    param([string]$Name, [string]$Reason)

    try { $null = Add-SwNotMeasured -Name $Name -Reason $Reason }
    catch { Write-SwDebug "not-measured note lost for ${Name}: $($_.Exception.Message)" }
}

# ============================================================================
# Comparison of paths: one offer per place, plausible roots
# ============================================================================

function ConvertTo-SwCleanCompare {
    # Comparison form of a path: normalized, one separator kind, no trailing separator. Case is left to
    # the comparison. A path that cannot be normalized is compared as typed.
    param([string]$Path)

    $full = $Path
    try { $full = [System.IO.Path]::GetFullPath($Path) }
    catch { $null = $_ }
    return $full.Replace('/', '\').TrimEnd([char[]]@('\'))
}

function Test-SwCleanSameOrUnder {
    # True when the first comparison form is the second or lies below it.
    param([string]$Child, [string]$Parent)

    if ([string]::Equals($Child, $Parent, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $Child.StartsWith($Parent + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-SwCleanPathForms {
    # The two spellings that count for "the same place": the typed one (normalized) and the final one
    # (links resolved). The final one is an empty string when it cannot be determined.
    param([string]$Path)

    $typed = ConvertTo-SwCleanCompare -Path $Path
    $resolved = ''
    try {
        $final = Resolve-SwSafePath -Path $Path
        if ($null -ne $final -and -not [string]::IsNullOrEmpty([string]$final)) { $resolved = ConvertTo-SwCleanCompare -Path ([string]$final) }
    }
    catch { $resolved = '' }
    return [pscustomobject]@{ Typed = $typed; Resolved = $resolved }
}

function Test-SwCleanOffered {
    # True when the path is, or lies below, a path that this run already handed to a helper. The typed
    # spellings are compared with each other, and so are the final ones.
    param([string]$Path, $Offered)

    $forms = Get-SwCleanPathForms -Path $Path
    foreach ($entry in $Offered) {
        if (Test-SwCleanSameOrUnder -Child $forms.Typed -Parent $entry.Typed) { return $true }
        if ($forms.Resolved.Length -gt 0 -and $entry.Resolved.Length -gt 0 -and (Test-SwCleanSameOrUnder -Child $forms.Resolved -Parent $entry.Resolved)) { return $true }
    }
    return $false
}

function Add-SwCleanOffered {
    param([string]$Path, $Offered)

    [void]$Offered.Add((Get-SwCleanPathForms -Path $Path))
}

function Get-SwCleanAnchors {
    # The folders that no file target may be, or contain: the profile, the two application data
    # folders and the known folders of the user. Each has a name, so that one rule can skip itself.
    $anchors = [System.Collections.Generic.List[object]]::new()
    $profileRoot = Get-SwCleanEnvRoot -Name 'USERPROFILE'
    foreach ($name in 'USERPROFILE', 'LOCALAPPDATA', 'APPDATA') {
        $value = Get-SwCleanEnvRoot -Name $name
        if ($null -ne $value) { $anchors.Add([pscustomobject]@{ Name = $name; Path = $value }) }
    }
    foreach ($folder in 'Desktop', 'MyDocuments', 'MyPictures', 'MyMusic', 'MyVideos') {
        try { $known = [string][System.Environment]::GetFolderPath([System.Environment+SpecialFolder]$folder) }
        catch { $known = '' }
        if (Test-SwCleanCompletePath -Path $known) { $anchors.Add([pscustomobject]@{ Name = $folder; Path = $known.Trim() }) }
    }
    # The Downloads folder has no entry in the .NET list.
    if ($null -ne $profileRoot) { $anchors.Add([pscustomobject]@{ Name = 'Downloads'; Path = (Join-SwCleanPath -Base $profileRoot -Rest @('Downloads')) }) }
    return $anchors.ToArray()
}

function Test-SwCleanRootPlausible {
    <#
    .SYNOPSIS
        True when a folder may be the root of a file target: only plain files directly in it are offered.
    .DESCRIPTION
        The folder must be written canonically (no . or .. segment, no doubled separator), must not be a
        drive root, must not be the profile, an application data folder or a known folder of the user,
        and must not contain any of them. Both spellings count, the typed one and the final one with
        links resolved. -AllowEqualTo names one of the folders that the root may equal: the target
        "files in APPDATA" is the application data folder itself. Anything unclear gives $false.
    #>
    param([string]$Root, [string]$AllowEqualTo = '')

    try {
        if (-not (Test-SwCleanCompletePath -Path $Root)) { return $false }
        $typed = $Root.Trim()
        $full = [System.IO.Path]::GetFullPath($typed)
        $own = ConvertTo-SwCleanCompare -Path $full
        # Canonical: normalizing changes nothing but the kind of separator.
        if (-not [string]::Equals($own, $typed.Replace('/', '\').TrimEnd([char[]]@('\')), [System.StringComparison]::Ordinal)) { return $false }

        $forms = [System.Collections.Generic.List[string]]::new()
        $forms.Add($own)
        $resolved = Resolve-SwSafePath -Path $full
        if ($null -ne $resolved -and -not [string]::IsNullOrEmpty([string]$resolved)) {
            $other = ConvertTo-SwCleanCompare -Path ([string]$resolved)
            if (-not $forms.Contains($other)) { $forms.Add($other) }
        }

        $roots = [System.Collections.Generic.List[string]]::new()
        foreach ($form in $forms) {
            $driveRoot = [System.IO.Path]::GetPathRoot($form)
            if ($null -eq $driveRoot) { $driveRoot = '' }
            $roots.Add($driveRoot.Replace('/', '\').TrimEnd([char[]]@('\')))
        }
        for ($i = 0; $i -lt $forms.Count; $i++) {
            if ([string]::Equals($forms[$i], $roots[$i], [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        }

        foreach ($anchor in (Get-SwCleanAnchors)) {
            $anchorForms = Get-SwCleanPathForms -Path $anchor.Path
            $names = @($anchorForms.Typed)
            if ($anchorForms.Resolved.Length -gt 0) { $names += $anchorForms.Resolved }
            foreach ($form in $forms) {
                foreach ($name in $names) {
                    if ($anchor.Name -ne $AllowEqualTo -and [string]::Equals($form, $name, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
                    if ($name.StartsWith($form + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
                }
            }
        }
        return $true
    }
    catch { return $false }
}

# ============================================================================
# Owner probe
# ============================================================================

function Test-SwCacheOwnerIdle {
    <#
    .SYNOPSIS
        True only when the program that owns a cache is sure not to be working.
    .DESCRIPTION
        Gives exactly one [bool] and never throws. No names, a process list that cannot be read, a
        running process of one of the names (without case and without .exe), a lock file that is
        held, is a folder or is a link, and every exception on the way all give $false: unknown is not
        idle. A lock file that does not exist counts as idle. The lock file is opened for reading only,
        shared with nobody, and closed at once; it is never created. The answer is not kept: every
        call asks afresh.
    #>
    param(
        [Parameter(Position = 0)][AllowNull()][AllowEmptyCollection()][string[]]$Names,
        [Parameter(Position = 1)][string]$LockPath = ''
    )

    try {
        $ErrorActionPreference = 'Stop'
        $wanted = [System.Collections.Generic.List[string]]::new()
        foreach ($name in @($Names)) {
            if ($null -eq $name) { continue }
            $text = ([string]$name).Trim()
            if ($text.Length -gt 0) { $wanted.Add($text) }
        }
        if ($wanted.Count -eq 0) { return $false }

        $processes = @(Get-Process -ErrorAction Stop)
        foreach ($process in $processes) {
            $processName = [string]$process.ProcessName
            if ([string]::IsNullOrWhiteSpace($processName)) { return $false }
            if ($processName.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) { $processName = $processName.Substring(0, $processName.Length - 4) }
            foreach ($candidate in $wanted) {
                if ([string]::Equals($processName, $candidate, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($LockPath)) {
            $attributes = $null
            try { $attributes = [System.IO.File]::GetAttributes($LockPath) }
            catch [System.IO.FileNotFoundException] { return $true }
            catch [System.IO.DirectoryNotFoundException] { return $true }
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) { return $false }
            $stream = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
            $stream.Dispose()
        }
        return $true
    }
    catch { return $false }
}

# ============================================================================
# One cache folder
# ============================================================================

function Clear-SwAppCache {
    <#
    .SYNOPSIS
        Offers the content of one cache folder, unless its owner may be working.
    .DESCRIPTION
        Writes nothing to the pipeline and never throws. A folder that does not exist is ignored. A
        folder that Test-SwSafePath refuses or that has no file identity is left alone and noted as
        not verified. Otherwise the folder goes to Clear-SwDirectoryContents with a condition that asks
        Test-SwCacheOwnerIdle at every call; the helper asks it again after measuring and before
        removing, also in a preview, so an owner that starts meanwhile keeps its cache.
    #>
    param(
        [string]$Path,
        [string]$Description,
        [string[]]$Processes,
        [string]$LockPath = ''
    )

    try {
        $ErrorActionPreference = 'Stop'
        if (-not (Test-SwCleanDirectory -Path $Path)) { return }
        $label = $Description
        if ([string]::IsNullOrEmpty($label)) { $label = Get-SwCleanRootLabel -Path $Path }

        $safe = @(Test-SwSafePath -Path $Path)
        $allowed = ($safe.Count -eq 1) -and ($safe[0] -is [bool]) -and ($safe[0] -eq $true)
        $snapshot = $null
        if ($allowed) { $snapshot = Get-SwPathSnapshot -Path $Path }
        if (-not $allowed -or $null -eq $snapshot) {
            Add-SwCleanNotMeasured -Name $label -Reason 'not verified'
            return
        }

        # The condition is text, because it runs inside the helper long after this function has ended: a
        # script block made here would lose its variables, and one with captured variables could not see
        # the functions of the caller. Names and path are literals; the probe is found by name at call time.
        $nameList = (@($Processes | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-SwPsLiteral -Value ([string]$_) }) -join ', ')
        $lockText = ConvertTo-SwPsLiteral -Value $LockPath
        $source = '$answer = @(Test-SwCacheOwnerIdle -Names @(' + $nameList + ') -LockPath ' + $lockText + '); ' +
            '($answer.Count -eq 1) -and ($answer[0] -is [bool]) -and ($answer[0] -eq $true)'
        $condition = [scriptblock]::Create($source)
        $null = Clear-SwDirectoryContents -Path $Path -Description $Description -CanRemove $condition
    }
    catch { Write-SwDebug "cache not offered, ${Path}: $($_.Exception.Message)" }
}

# ============================================================================
# Profile folders
# ============================================================================

function Get-SwCacheProfiles {
    <#
    .SYNOPSIS
        The profile folders directly below a browser or application root, one by one.
    .DESCRIPTION
        One level, never recursive, read literally. Nothing at all is given, and the root is noted as
        not verified or as an incomplete scan, when the root has no file identity (a link, or below a
        link), has more than 128 folders, takes longer than the probe budget, has a folder that cannot
        be read, or changed while it was listed. A missing root and a root that is a file give nothing
        and no note. Folders that are links (or whose attributes cannot be read) are left out, and so
        are folders named like a cache folder of the root (Cache, Code Cache, GPUCache, ShaderCache,
        GrShaderCache): they are not profiles. Every folder, also the left-out ones, counts for the
        limit. Never throws.
    #>
    param([string]$Root)

    try {
        $ErrorActionPreference = 'Stop'
        if (-not (Test-SwCleanCompletePath -Path $Root)) { return }
        if (-not (Test-SwCleanDirectory -Path $Root)) { return }
        $label = Get-SwCleanRootLabel -Path $Root

        $snapshot = Get-SwPathSnapshot -Path $Root
        if ($null -eq $snapshot) {
            Add-SwCleanNotMeasured -Name $label -Reason 'not verified'
            return
        }

        $budget = Get-SwCleanProbeBudget
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        if ($clock.Elapsed.TotalSeconds -ge $budget) {
            Add-SwCleanNotMeasured -Name $label -Reason 'incomplete scan'
            return
        }

        $leaves = @('Cache', 'Code Cache', 'GPUCache', 'ShaderCache', 'GrShaderCache')
        $found = [System.Collections.Generic.List[string]]::new()
        $profiles = [System.Collections.Generic.List[object]]::new()
        try {
            foreach ($folder in [System.IO.Directory]::EnumerateDirectories($Root)) {
                $found.Add([string]$folder)
                if ($found.Count -gt 128 -or $clock.Elapsed.TotalSeconds -ge $budget) {
                    Add-SwCleanNotMeasured -Name $label -Reason 'incomplete scan'
                    return
                }
            }
        }
        catch {
            Add-SwCleanNotMeasured -Name $label -Reason 'incomplete scan'
            return
        }
        $ordered = $found.ToArray()
        [System.Array]::Sort($ordered, [System.StringComparer]::OrdinalIgnoreCase)

        foreach ($folder in $ordered) {
            if ($clock.Elapsed.TotalSeconds -ge $budget) {
                Add-SwCleanNotMeasured -Name $label -Reason 'incomplete scan'
                return
            }
            try { $item = Get-Item -LiteralPath $folder -Force -ErrorAction Stop }
            catch {
                Add-SwCleanNotMeasured -Name $label -Reason 'incomplete scan'
                return
            }
            # Attributes that are missing or cannot be read make the entry a link: it is not entered.
            $isLink = $true
            try {
                $attributes = $item.Attributes
                if ($null -ne $attributes) { $isLink = (([System.IO.FileAttributes]$attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) }
            }
            catch { $isLink = $true }
            if ($isLink) { continue }
            $leaf = [System.IO.Path]::GetFileName($folder)
            $named = $false
            foreach ($candidate in $leaves) {
                if ([string]::Equals($leaf, $candidate, [System.StringComparison]::OrdinalIgnoreCase)) { $named = $true }
            }
            if ($named) { continue }
            $profiles.Add([System.IO.DirectoryInfo]::new($folder))
        }

        $unchanged = @(Test-SwPathSnapshot -Snapshot $snapshot)
        if (-not (($unchanged.Count -eq 1) -and ($unchanged[0] -is [bool]) -and ($unchanged[0] -eq $true))) {
            Add-SwCleanNotMeasured -Name $label -Reason 'incomplete scan'
            return
        }
        foreach ($profile in $profiles) { $profile }
    }
    catch { Write-SwDebug "profiles not listed, ${Root}: $($_.Exception.Message)" }
}

# ============================================================================
# Old names, kept as forwarding functions (not aliases, so a test mock of either name behaves) until
# the callers move to the new ones. Get-SweeprCacheProfiles had no caller outside and has no forwarder.
# ============================================================================

function Test-SweeprCacheOwnerIdle {
    param(
        [Parameter(Position = 0)][string[]]$Names,
        [Parameter(Position = 1)][string]$LockPath = ''
    )
    Test-SwCacheOwnerIdle @PSBoundParameters
}

function Clear-SweeprAppCache {
    param(
        [Parameter(Position = 0)][string]$Path,
        [Parameter(Position = 1)][string]$Description,
        [Parameter(Position = 2)][string[]]$Processes,
        [Parameter(Position = 3)][string]$LockPath = ''
    )
    Clear-SwAppCache @PSBoundParameters
}

# Other modules rely on these for the rest of their run.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
