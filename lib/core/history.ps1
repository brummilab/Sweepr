# Sweepr - operations history reader
#
# `sw history` shows what Sweepr removed, recycled, uninstalled, disabled, restored, skipped or failed
# to do. The data comes from operations.log, which other commands append to. This file only reads
# that log and renders it; it never writes, rotates or repairs anything.
#
# It can be loaded on its own: loading defines functions and script constants only. No output, no
# files, no network, and no change to the caller's strict mode or error preference.

$script:SwHistoryActionNames = @('removed', 'recycled', 'uninstalled', 'disabled', 'restored', 'skipped', 'failed', 'other')
$script:SwHistoryMaxLimit = 200

# One record: [time] [command run=id] ACTION path (detail). ASCII classes are spelled out because
# [0-9] and \d differ for non-ASCII digits, and a forged line must not become a record.
# The path is greedy and the detail is the last group without parentheses, so paths such as
# "C:\Program Files (x86)\App" keep their own parentheses.
$script:SwHistoryRecordPattern = New-Object System.Text.RegularExpressions.Regex(
    '\A\[([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})\] \[([^\s\]]+)(?: run=([^\s\]]+))?\] ([A-Z]+) (.+) \(([^()]*)\)\z',
    ([System.Text.RegularExpressions.RegexOptions]::CultureInvariant -bor [System.Text.RegularExpressions.RegexOptions]::Singleline))

# One session marker: # ========== command run=id session started at <text> ==========
$script:SwHistoryMarkerPattern = New-Object System.Text.RegularExpressions.Regex(
    '\A# ={10} ([^\s\]]+)(?: run=([^\s\]]+))? session started at (.+?) ={10}\z',
    ([System.Text.RegularExpressions.RegexOptions]::CultureInvariant -bor [System.Text.RegularExpressions.RegexOptions]::Singleline))

function ConvertTo-SwHistoryLimit {
    <#
    .SYNOPSIS
        Validates a --limit value: one to three ASCII digits, 1 to 200. Returns the number, or $null
        for anything else. Never throws.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if ($null -eq $Value) { return $null }
    # \z, not $: a trailing newline must not slip through.
    if (-not [regex]::IsMatch($Value, '\A[0-9]{1,3}\z')) { return $null }
    $number = [int]::Parse($Value, [System.Globalization.CultureInfo]::InvariantCulture)
    if ($number -lt 1 -or $number -gt $script:SwHistoryMaxLimit) { return $null }
    return $number
}

function New-SwHistoryActions {
    $actions = [ordered]@{}
    foreach ($name in $script:SwHistoryActionNames) { $actions[$name] = 0 }
    return [pscustomobject]$actions
}

function New-SwHistorySession {
    param([string]$Command, [string]$RunId, [string]$StartedAt)
    return [pscustomobject][ordered]@{
        command         = $Command
        run_id          = $RunId
        started_at      = $StartedAt
        operation_count = 0
        actions         = (New-SwHistoryActions)
    }
}

function Read-SwHistory {
    <#
    .SYNOPSIS
        Reads operations.log into Sessions and Operations, both oldest first.
    .DESCRIPTION
        A missing file gives an empty result. A file that exists but cannot be read throws, so the
        caller never mistakes "unreadable" for "no history". Lines that are neither a session marker
        nor a record are skipped. The content is only ever treated as text.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $sessions = New-Object System.Collections.Generic.List[object]
    $operations = New-Object System.Collections.Generic.List[object]
    $result = [pscustomobject]@{ Sessions = @(); Operations = @() }

    # A folder in the log's place is "exists but unreadable", not "missing".
    if (-not [System.IO.File]::Exists($Path) -and -not [System.IO.Directory]::Exists($Path)) { return $result }

    $lines = New-Object System.Collections.Generic.List[string]
    $stream = $null
    $reader = $null
    try {
        # ReadWrite sharing: a Sweepr process appending right now must neither block nor be blocked by us.
        $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        # Detects and drops a BOM; invalid bytes become replacement characters instead of errors.
        $reader = New-Object System.IO.StreamReader($stream, (New-Object System.Text.UTF8Encoding($false)), $true)
        while ($null -ne ($line = $reader.ReadLine())) { $lines.Add($line) }
    }
    catch [System.IO.FileNotFoundException] { return $result }
    catch [System.IO.DirectoryNotFoundException] { return $result }
    catch {
        # New-Object wraps the real error ("Exception calling ..."); the inner .NET message is the
        # useful part and usually names the path already, so add the path only when it does not.
        $reason = $_.Exception
        if ($null -ne $reason.InnerException) { $reason = $reason.InnerException }
        $text = $reason.Message
        if ($text.IndexOf($Path, [System.StringComparison]::Ordinal) -lt 0) { $text = "Cannot read '$Path': $text" }
        throw (New-Object System.IO.IOException($text))
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }

    # A record belongs to the latest session with the same command and run id. A repeated marker
    # starts a new session; earlier records stay with the older one.
    $current = @{}
    foreach ($line in $lines) {
        if ($line.Length -eq 0) { continue }
        $first = $line[0]

        if ($first -eq [char]'#') {
            $m = $script:SwHistoryMarkerPattern.Match($line)
            if (-not $m.Success) { continue }
            $session = New-SwHistorySession -Command $m.Groups[1].Value -RunId $m.Groups[2].Value -StartedAt $m.Groups[3].Value
            $sessions.Add($session)
            $current[$session.command + "`0" + $session.run_id] = $session
            continue
        }

        if ($first -ne [char]'[') { continue }
        $m = $script:SwHistoryRecordPattern.Match($line)
        if (-not $m.Success) { continue }

        $timestamp = $m.Groups[1].Value
        $command = $m.Groups[2].Value
        $runId = $m.Groups[3].Value
        $action = $m.Groups[4].Value.ToLowerInvariant()
        $detail = $m.Groups[6].Value
        if ($detail -ceq '-') { $detail = '' }

        $key = $command + "`0" + $runId
        if (-not $current.ContainsKey($key)) {
            $session = New-SwHistorySession -Command $command -RunId $runId -StartedAt $timestamp
            $sessions.Add($session)
            $current[$key] = $session
        }
        $session = $current[$key]
        $counter = if ($script:SwHistoryActionNames -contains $action -and $action -ne 'other') { $action } else { 'other' }
        $session.actions.$counter = [int]$session.actions.$counter + 1
        $session.operation_count = [int]$session.operation_count + 1

        $operations.Add([pscustomobject][ordered]@{
                timestamp = $timestamp
                command   = $command
                run_id    = $runId
                action    = $action
                path      = $m.Groups[5].Value
                detail    = $detail
            })
    }

    $result.Sessions = $sessions.ToArray()
    $result.Operations = $operations.ToArray()
    return $result
}

function Get-SwHistoryWindow {
    # The last Limit items of a list, newest first. The position in the log decides, not the timestamp.
    param([AllowNull()][object[]]$Items, [int]$Limit)

    if ($null -eq $Items) { $Items = @() }
    if ($Limit -lt 1) { $Limit = 1 }
    $count = $Items.Count
    $take = [Math]::Min($count, $Limit)
    $window = New-Object object[] $take
    for ($i = 0; $i -lt $take; $i++) { $window[$i] = $Items[$count - 1 - $i] }
    return $window
}

function Format-SwHistoryActions {
    <#
    .SYNOPSIS
        "removed 2, failed 1": the non-zero counters in a fixed order, or a hint when all are zero.
    #>
    param([Parameter(Mandatory)]$Actions)

    $parts = @()
    foreach ($name in $script:SwHistoryActionNames) {
        $count = 0
        if ($null -ne $Actions.PSObject.Properties[$name]) { $count = [int]$Actions.$name }
        if ($count -gt 0) { $parts += ('{0} {1}' -f $name, $count) }
    }
    if ($parts.Count -eq 0) { return 'nothing changed' }
    return ($parts -join ', ')
}

function ConvertTo-SwHistoryJson {
    <#
    .SYNOPSIS
        The JSON document for `sw history --json`, with the limit applied per list.
    #>
    param(
        [Parameter(Mandatory)]$History,
        [int]$Limit = 20,
        [string]$LogPath = ''
    )

    $sessionItems = New-Object System.Collections.Generic.List[object]
    foreach ($s in (Get-SwHistoryWindow -Items @($History.Sessions) -Limit $Limit)) {
        $actions = [ordered]@{}
        foreach ($name in $script:SwHistoryActionNames) { $actions[$name] = [int]$s.actions.$name }
        $sessionItems.Add([ordered]@{
                command         = [string]$s.command
                run_id          = [string]$s.run_id
                started_at      = [string]$s.started_at
                operation_count = [int]$s.operation_count
                actions         = $actions
            })
    }
    $operationItems = New-Object System.Collections.Generic.List[object]
    foreach ($o in (Get-SwHistoryWindow -Items @($History.Operations) -Limit $Limit)) {
        $operationItems.Add([ordered]@{
                timestamp = [string]$o.timestamp
                command   = [string]$o.command
                run_id    = [string]$o.run_id
                action    = [string]$o.action
                path      = [string]$o.path
                detail    = [string]$o.detail
            })
    }

    # -InputObject and typed arrays: piping would unroll a one-element list into a bare object in
    # Windows PowerShell 5.1, and the schema promises arrays.
    $document = [ordered]@{
        logs       = [ordered]@{ operations = $LogPath }
        limit      = [int]$Limit
        sessions   = [object[]]$sessionItems.ToArray()
        operations = [object[]]$operationItems.ToArray()
    }
    return (ConvertTo-Json -InputObject $document -Depth 6)
}

function Write-SwHistoryText {
    <#
    .SYNOPSIS
        Writes the text view of the history to the host. Log text is printed as is.
    #>
    param(
        [Parameter(Mandatory)]$History,
        [int]$Limit = 20,
        [string]$LogPath = ''
    )

    Write-Host 'Sweepr history'
    Write-Host ''
    Write-Host 'Sessions (newest first)'
    $sessions = @(Get-SwHistoryWindow -Items @($History.Sessions) -Limit $Limit)
    if ($sessions.Count -eq 0) {
        Write-Host '  No sessions recorded.'
    }
    foreach ($s in $sessions) {
        $summary = Format-SwHistoryActions -Actions $s.actions
        Write-Host ('  {0} {1}, {2}' -f ([string]$s.command).PadRight(10), $s.started_at, $summary)
    }
    Write-Host ''
    Write-Host 'Operations (newest first)'
    $operations = @(Get-SwHistoryWindow -Items @($History.Operations) -Limit $Limit)
    if ($operations.Count -eq 0) {
        Write-Host '  No operations recorded.'
    }
    foreach ($o in $operations) {
        # String concatenation, not -f: a path may contain braces.
        $line = '  ' + $o.timestamp + '  ' + ([string]$o.action).PadRight(11) + ' ' + $o.path
        if ($o.detail.Length -gt 0) { $line += ' (' + $o.detail + ')' }
        Write-Host $line
    }
    Write-Host ''
    Write-Host 'Log'
    Write-Host ('  ' + $LogPath)
}
