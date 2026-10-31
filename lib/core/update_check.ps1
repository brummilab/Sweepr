# Sweepr - automatic update hint
#
# After a normal interactive command (or in the main menu) show one line when the installation's
# channel has published a newer stable version. The lookup runs briefly in a hidden Windows PowerShell
# process, its result is cached, the command never waits for it, and nothing is ever installed.
#
# Two sides share this file:
#   Foreground (router): Test-SwUpdateHintAllowed, Start-SwUpdateProbe, Write-SwUpdateHint. Uses
#   base.ps1 (cache folder, PowerShell literals) and log.ps1 (interactive output) already loaded.
#   Background: a fresh Windows PowerShell loads this file from the installation alone and calls
#   Invoke-SwUpdateLookup. That part must not need any other Sweepr module.
#
# Loading defines functions only: no output, no files, no network.

$script:SwUpdateSchema = 1
$script:SwUpdateRetrySeconds = 3600      # pending or failed lookup
$script:SwUpdateFoundSeconds = 86400     # successful lookup
$script:SwUpdateCacheName = 'update-check.json'
$script:SwUpdateReleasePage = 'https://github.com/brummilab/sweepr/releases'
$script:SwUpdateSources = @{
    scoop  = 'https://raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/sweepr.json'
    winget = 'https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests/b/brummilab/Sweepr'
    github = 'https://api.github.com/repos/brummilab/sweepr/releases?per_page=100'
}

# ============================================================================
# Shared helpers (foreground and background)
# ============================================================================

function Test-SwStableVersion {
    # Exactly X.Y.Z with 1 to 5 ASCII digits each; anything else (pre-releases, extra lines, escape
    # sequences from a network answer) is not a version Sweepr shows or stores.
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ($null -eq $Text) { return $false }
    return [regex]::IsMatch($Text, '\A[0-9]{1,5}\.[0-9]{1,5}\.[0-9]{1,5}\z')
}

function Get-SwUpdateChannel {
    # Installation method from the router, folded to the channel that decides source and hint.
    param([AllowNull()][AllowEmptyString()][string]$Method)
    if ($null -eq $Method) { return 'copy' }
    switch ($Method.ToLowerInvariant()) {
        'source' { return 'source' }
        'winget' { return 'winget' }
        'scoop' { return 'scoop' }
        'portable' { return 'portable' }
    }
    return 'copy'
}

function Get-SwUtcTicks {
    # Through Get-Date so tests can move the clock.
    return [long]((Get-Date).ToUniversalTime().Ticks)
}

function Read-SwUpdateEntry {
    <#
    .SYNOPSIS
        The cache entry for Key, or $null when the file is missing, unreadable, not the expected
        JSON, for another key, from the future or with an unknown interval. Never throws.
    #>
    param([string]$CacheFile, [string]$Key, [long]$Now)

    try {
        if (-not [System.IO.File]::Exists($CacheFile)) { return $null }
        $data = [System.IO.File]::ReadAllText($CacheFile) | ConvertFrom-Json -ErrorAction Stop
        if ($data -isnot [System.Management.Automation.PSCustomObject]) { return $null }
        $props = $data.PSObject.Properties
        foreach ($name in 'Schema', 'Key', 'CheckedTicks', 'Interval', 'Latest') {
            if ($null -eq $props[$name]) { return $null }
        }
        if ([string]$props['Schema'].Value -ne [string]$script:SwUpdateSchema) { return $null }
        if (-not [string]::Equals([string]$props['Key'].Value, $Key, [System.StringComparison]::Ordinal)) { return $null }
        $checked = [long]$props['CheckedTicks'].Value
        $interval = [long]$props['Interval'].Value
        if ($checked -gt $Now) { return $null }
        if ($interval -ne $script:SwUpdateRetrySeconds -and $interval -ne $script:SwUpdateFoundSeconds) { return $null }
        $latest = ''
        if ($null -ne $props['Latest'].Value) { $latest = [string]$props['Latest'].Value }
        return @{ CheckedTicks = $checked; Interval = $interval; Latest = $latest }
    }
    catch {
        return $null
    }
}

function Test-SwReparsePath {
    # True when Path or any folder above it is a reparse point (junction, symbolic link). Writing
    # there could land somewhere else, even for an elevated process.
    param([string]$Path)

    $item = New-Object System.IO.FileInfo -ArgumentList $Path
    if ([int]$item.Attributes -ne -1 -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $true }
    $folder = $item.Directory
    while ($null -ne $folder) {
        if ([int]$folder.Attributes -ne -1 -and ($folder.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $true }
        $folder = $folder.Parent
    }
    return $false
}

function Write-SwUpdateEntry {
    <#
    .SYNOPSIS
        Replaces the cache file atomically: a new temporary file next to it, then a swap.
    .DESCRIPTION
        Throws on any failure. Refuses to write through reparse points. Only its own temporary file
        is ever removed.
    #>
    param([string]$CacheFile, [string]$Key, [long]$CheckedTicks, [long]$Interval, [string]$Latest)

    $CacheFile = [System.IO.Path]::GetFullPath($CacheFile)
    if (Test-SwReparsePath -Path $CacheFile) { throw "Refusing to write the update cache through a link: $CacheFile" }

    $json = [ordered]@{
        Schema       = $script:SwUpdateSchema
        Key          = $Key
        CheckedTicks = $CheckedTicks
        Interval     = $Interval
        Latest       = $Latest
    } | ConvertTo-Json -Compress

    $folder = [System.IO.Path]::GetDirectoryName($CacheFile)
    $temp = [System.IO.Path]::Combine($folder, ([System.IO.Path]::GetFileName($CacheFile) + '.' + [guid]::NewGuid().ToString('N') + '.tmp'))
    $created = $false
    try {
        $stream = New-Object System.IO.FileStream -ArgumentList $temp, ([System.IO.FileMode]::CreateNew), ([System.IO.FileAccess]::Write), ([System.IO.FileShare]::None)
        $created = $true
        try {
            $bytes = (New-Object System.Text.UTF8Encoding -ArgumentList $false).GetBytes($json)
            $stream.Write($bytes, 0, $bytes.Length)
        }
        finally { $stream.Dispose() }

        if ([System.IO.File]::Exists($CacheFile)) {
            [System.IO.File]::Replace($temp, $CacheFile, [NullString]::Value)
        }
        else {
            [System.IO.File]::Move($temp, $CacheFile)
        }
    }
    finally {
        if ($created -and [System.IO.File]::Exists($temp)) {
            # Own, just-created temporary file, not a cleanup target, so no Remove-Safe* here.
            try { [System.IO.File]::Delete($temp) } catch { $null = $_ }
        }
    }
}

# ============================================================================
# Foreground
# ============================================================================

function Test-SwStdErrRedirected {
    # Separate so tests can set it; a redirected stderr means a script or log is listening.
    try { return [bool][Console]::IsErrorRedirected }
    catch { return $true }
}

function Test-SwUpdateHintAllowed {
    <#
    .SYNOPSIS
        True when a normal interactive command (or the menu) may show an update hint.
    .DESCRIPTION
        Never for dry runs, structured output, help or version, list modes or commands such as
        check, history, features and update. Only checks: starts, writes and asks nothing.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$CommandName,
        [AllowNull()][AllowEmptyCollection()][string[]]$Arguments
    )

    if ($env:SWEEPR_DRY_RUN -eq '1') { return $false }

    if (-not [string]::IsNullOrEmpty($CommandName)) {
        $allowed = @('clean', 'uninstall', 'optimize', 'purge', 'analyze', 'status')
        if ($allowed -notcontains $CommandName.ToLowerInvariant()) { return $false }
    }

    foreach ($argument in @($Arguments)) {
        if ($null -eq $argument) { continue }
        if ([regex]::IsMatch([string]$argument, '\A--?(json|ndjson|watch|help|h|version|v|list|dry-run|whitelist)([=:].*)?\z',
                [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, Singleline')) {
            return $false
        }
    }

    if (-not (Test-SweeprInteractiveOutput)) { return $false }
    if (Test-SwStdErrRedirected) { return $false }
    return $true
}

function Start-SwBackgroundProcess {
    <#
    .SYNOPSIS
        Starts FilePath with Arguments hidden and returns at once; the only process start here.
    .DESCRIPTION
        No shell, no window, no handle kept and no waiting. Separate so tests can capture the start.
    #>
    param([string]$FilePath, [string]$Arguments)

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    $info.Arguments = $Arguments
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    # Do not hold the user's current folder open for the lifetime of the lookup.
    $info.WorkingDirectory = [System.IO.Path]::GetDirectoryName($FilePath)
    $process = [System.Diagnostics.Process]::Start($info)
    if ($null -ne $process) { $process.Dispose() }
}

function Start-SwUpdateProbe {
    <#
    .SYNOPSIS
        Starts the background lookup when the cached answer is missing or stale; returns a context
        for Get-SwUpdateHint/Write-SwUpdateHint, or $null.
    .DESCRIPTION
        Pre-releases never get a hint. A pending entry with a one-hour interval is written before the
        start, so failures are retried at most hourly and parallel runs start no second lookup.
        Never waits, never throws, never writes to the host.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$RootDir,
        [AllowNull()][AllowEmptyString()][string]$Version,
        [AllowNull()][AllowEmptyString()][string]$Method
    )

    try {
        if (-not (Test-SwStableVersion -Text $Version)) { return $null }
        if ([string]::IsNullOrWhiteSpace($RootDir)) { return $null }

        $channel = Get-SwUpdateChannel -Method $Method
        # A new version, folder or channel makes an old entry worthless.
        $key = 'root=' + $RootDir + '|version=' + $Version + '|channel=' + $channel
        $cacheFile = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine([string](Get-CachePath), $script:SwUpdateCacheName))
        $context = [pscustomobject]@{ CacheFile = $cacheFile; Key = $key; Version = $Version; Channel = $channel }

        $now = Get-SwUtcTicks
        $entry = Read-SwUpdateEntry -CacheFile $cacheFile -Key $key -Now $now
        if ($null -ne $entry -and ($now - $entry.CheckedTicks) -lt ($entry.Interval * [TimeSpan]::TicksPerSecond)) {
            return $context
        }

        Write-SwUpdateEntry -CacheFile $cacheFile -Key $key -CheckedTicks $now -Interval $script:SwUpdateRetrySeconds -Latest ''

        $windowsRoot = $env:SystemRoot
        if ([string]::IsNullOrWhiteSpace($windowsRoot)) { return $null }
        $powershell = $windowsRoot.TrimEnd('\') + '\System32\WindowsPowerShell\v1.0\powershell.exe'
        $scriptFile = [System.IO.Path]::Combine($RootDir, 'lib', 'core', 'update_check.ps1')

        # Every value is a quoted literal (all five single quote forms doubled), so a path, key or
        # channel arrives unchanged and is never run as code.
        $command = @(
            "`$ErrorActionPreference = 'Stop'"
            "`$ProgressPreference = 'SilentlyContinue'"
            ('. ' + (ConvertTo-SweeprPsLiteral -Value $scriptFile))
            ('Invoke-SwUpdateLookup ' + (ConvertTo-SweeprPsLiteral -Value $cacheFile) + ' ' +
                (ConvertTo-SweeprPsLiteral -Value $key) + ' ' + (ConvertTo-SweeprPsLiteral -Value $channel))
        ) -join "`n"
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
        $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand ' + $encoded

        Start-SwBackgroundProcess -FilePath $powershell -Arguments $arguments
        return $context
    }
    catch {
        return $null
    }
}

function Get-SwUpdateHint {
    <#
    .SYNOPSIS
        The one-line hint for a context, or nothing. Reads only the cache.
    #>
    param([AllowNull()][object]$Context)

    try {
        if ($null -eq $Context) { return }
        if ($Context -isnot [System.Management.Automation.PSCustomObject]) { return }
        $now = Get-SwUtcTicks
        $entry = Read-SwUpdateEntry -CacheFile ([string]$Context.CacheFile) -Key ([string]$Context.Key) -Now $now
        if ($null -eq $entry) { return }
        if (($now - $entry.CheckedTicks) -ge ($script:SwUpdateFoundSeconds * [TimeSpan]::TicksPerSecond)) { return }
        $latest = $entry.Latest
        if (-not (Test-SwStableVersion -Text $latest)) { return }
        if (-not (Test-SwStableVersion -Text ([string]$Context.Version))) { return }
        if ([version]$latest -le [version][string]$Context.Version) { return }

        switch ([string]$Context.Channel) {
            'winget' { return "Sweepr $latest is available. Update with: winget upgrade brummilab.Sweepr" }
            'scoop' { return "Sweepr $latest is available. Update with: scoop update sweepr" }
            'source' { return "Sweepr $latest is available. Update with: sw update" }
            'portable' {
                return "Sweepr $latest is available: download sweepr-$latest-x64-portable.zip from $($script:SwUpdateReleasePage), replace the program files and keep the data folder."
            }
        }
        return "Sweepr $latest is available: $($script:SwUpdateReleasePage)/tag/V$latest-windows"
    }
    catch {
        return
    }
}

function Write-SwUpdateHint {
    <#
    .SYNOPSIS
        Writes the hint in yellow when there is one; any failure is swallowed so the command's
        result never changes because of it.
    #>
    param([AllowNull()][object]$Context)

    try {
        $hint = Get-SwUpdateHint -Context $Context
        if (-not [string]::IsNullOrEmpty($hint)) { Write-Host -Object $hint -ForegroundColor Yellow }
    }
    catch {
        $null = $_
    }
}

# ============================================================================
# Background
# ============================================================================

function Get-SwLatestVersion {
    # Highest stable X.Y.Z the channel's source offers, or $null. Network errors reach the caller.
    param([string]$Channel)

    $headers = @{ Accept = 'application/vnd.github+json' }
    $request = @{
        TimeoutSec      = 10
        UserAgent       = 'Sweepr-UpdateCheck'
        Headers         = $headers
        UseBasicParsing = $true
        ErrorAction     = 'Stop'
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    switch ($Channel) {
        'scoop' {
            $answer = Invoke-RestMethod -Uri $script:SwUpdateSources.scoop @request
            if ($null -ne $answer -and $null -ne $answer.PSObject.Properties['version']) {
                $candidates.Add([string]$answer.PSObject.Properties['version'].Value)
            }
        }
        'winget' {
            $answer = Invoke-RestMethod -Uri $script:SwUpdateSources.winget @request
            foreach ($item in @($answer | ForEach-Object { $_ })) {
                if ($null -eq $item) { continue }
                $props = $item.PSObject.Properties
                if ($null -eq $props['type'] -or $null -eq $props['name']) { continue }
                if ([string]$props['type'].Value -ne 'dir') { continue }
                $candidates.Add([string]$props['name'].Value)
            }
        }
        default {
            $answer = Invoke-RestMethod -Uri $script:SwUpdateSources.github @request
            foreach ($item in @($answer | ForEach-Object { $_ })) {
                if ($null -eq $item) { continue }
                $props = $item.PSObject.Properties
                if ($null -eq $props['tag_name'] -or $null -eq $props['draft'] -or $null -eq $props['prerelease']) { continue }
                if ($props['draft'].Value -ne $false -or $props['prerelease'].Value -ne $false) { continue }
                # Only the tag counts (case-sensitive); release titles are free text.
                $match = [regex]::Match([string]$props['tag_name'].Value, '\AV([0-9]{1,5}\.[0-9]{1,5}\.[0-9]{1,5})-windows\z')
                if ($match.Success) { $candidates.Add($match.Groups[1].Value) }
            }
        }
    }

    $best = $null
    foreach ($candidate in $candidates) {
        if (-not (Test-SwStableVersion -Text $candidate)) { continue }
        if ($null -eq $best -or [version]$candidate -gt [version]$best) { $best = $candidate }
    }
    return $best
}

function Invoke-SwUpdateLookup {
    <#
    .SYNOPSIS
        Runs in the hidden background process: asks the channel's source and stores a found version.
    .DESCRIPTION
        The entry is only updated while a valid entry for the same key still exists, so a removed
        cache is not recreated and another installation's entry is left alone. A failed lookup keeps
        the pending entry and its one-hour retry.
    #>
    param([string]$CacheFile, [string]$Key, [string]$Channel)

    if ($PSVersionTable['PSEdition'] -ne 'Core') {
        # Windows PowerShell may not offer TLS 1.2 by default; GitHub requires it. Keep the others.
        # SystemDefault (0) lets the system choose, and adding a flag would replace that choice.
        $protocol = [System.Net.ServicePointManager]::SecurityProtocol
        if ([int]$protocol -ne 0) {
            [System.Net.ServicePointManager]::SecurityProtocol = $protocol -bor [System.Net.SecurityProtocolType]::Tls12
        }
    }

    $latest = $null
    try { $latest = Get-SwLatestVersion -Channel (Get-SwUpdateChannel -Method $Channel) }
    catch { return }
    if (-not (Test-SwStableVersion -Text $latest)) { return }

    $now = Get-SwUtcTicks
    $entry = Read-SwUpdateEntry -CacheFile $CacheFile -Key $Key -Now $now
    if ($null -eq $entry) { return }
    Write-SwUpdateEntry -CacheFile $CacheFile -Key $Key -CheckedTicks $now -Interval $script:SwUpdateFoundSeconds -Latest $latest
}

# ============================================================================
# Old names (forwarding functions until the router is rewritten)
# ============================================================================

function Test-SweeprUpdateNoticeAllowed {
    param(
        [AllowNull()][AllowEmptyString()][string]$CommandName,
        [AllowNull()][AllowEmptyCollection()][string[]]$Arguments
    )
    Test-SwUpdateHintAllowed @PSBoundParameters
}

function Start-SweeprUpdateCheck {
    param(
        [AllowNull()][AllowEmptyString()][string]$RootDir,
        [AllowNull()][AllowEmptyString()][string]$Version,
        [AllowNull()][AllowEmptyString()][string]$Method
    )
    Start-SwUpdateProbe @PSBoundParameters
}

function Show-SweeprUpdateNotice {
    param([AllowNull()][object]$Context)
    Write-SwUpdateHint @PSBoundParameters
}
