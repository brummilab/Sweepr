# freeMole - History Module
# Reads the operation log that Write-MoleOperation appends, for fm history.

#Requires -Version 5.1
Set-StrictMode -Version Latest

if ((Get-Variable -Name 'MOLE_HISTORY_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:MOLE_HISTORY_LOADED) { return }
$script:MOLE_HISTORY_LOADED = $true

$script:MoleHistoryDefaultLimit = 20
$script:MoleHistoryMaxLimit = 200

# A limit is a plain decimal from 1 to 200, the macOS CLI's range.
function ConvertTo-MoleHistoryLimit {
    param([string]$Value)

    if ($Value -notmatch '^[0-9]{1,3}$') { return $null }
    $number = [int]$Value
    if ($number -lt 1 -or $number -gt $script:MoleHistoryMaxLimit) { return $null }
    return $number
}

function New-MoleHistorySession {
    param([string]$Command, [string]$RunId, [string]$StartedAt)

    return [ordered]@{
        command         = $Command
        run_id          = $RunId
        started_at      = $StartedAt
        operation_count = 0
        actions         = [ordered]@{ removed = 0; recycled = 0; uninstalled = 0; skipped = 0; failed = 0; other = 0 }
    }
}

# Sessions in log order with their action counts, and every record. A record
# whose run has no start marker (a log cut by rotation) opens its own session.
function Read-MoleHistory {
    param([string]$Path)

    $sessions = New-Object System.Collections.Generic.List[object]
    $operations = New-Object System.Collections.Generic.List[object]
    $byRun = @{}
    if (-not [System.IO.File]::Exists($Path)) {
        return @{ Sessions = @(); Operations = @() }
    }

    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -match '^# ========== (\S+)(?: run=(\S+))? session started at (.+) ==========$') {
            $session = New-MoleHistorySession -Command $Matches[1] -RunId ([string]$Matches[2]) -StartedAt $Matches[3]
            $sessions.Add($session)
            $byRun["$($session.command)|$($session.run_id)"] = $session
            continue
        }
        # The detail is the last parenthesis-free "(...)"; everything before it is the path.
        if ($line -notmatch '^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\] \[(\S+)(?: run=(\S+))?\] ([A-Z]+) (.+) \(([^()]*)\)$') { continue }
        $record = [ordered]@{
            timestamp = $Matches[1]
            command   = $Matches[2]
            run_id    = [string]$Matches[3]
            action    = $Matches[4].ToLowerInvariant()
            path      = $Matches[5]
            detail    = $(if ($Matches[6] -eq "-") { "" } else { $Matches[6] })
        }
        $operations.Add($record)

        $key = "$($record.command)|$($record.run_id)"
        if (-not $byRun.ContainsKey($key)) {
            $session = New-MoleHistorySession -Command $record.command -RunId $record.run_id -StartedAt $record.timestamp
            $sessions.Add($session)
            $byRun[$key] = $session
        }
        $session = $byRun[$key]
        $session.operation_count++
        if ($session.actions.Contains($record.action)) { $session.actions[$record.action]++ }
        else { $session.actions.other++ }
    }
    return @{ Sessions = $sessions.ToArray(); Operations = $operations.ToArray() }
}

# The newest $Limit entries, newest first.
function Select-MoleHistoryNewest {
    param($Items, [int]$Limit)

    $all = @($Items)
    if ($all.Count -eq 0) { return @() }
    $start = [Math]::Max(0, $all.Count - $Limit)
    $newest = @($all[$start..($all.Count - 1)])
    [array]::Reverse($newest)
    return $newest
}

function Format-MoleHistoryActions {
    param($Actions)

    $parts = @()
    foreach ($name in @("removed", "recycled", "uninstalled", "skipped", "failed", "other")) {
        if ($Actions[$name] -gt 0) { $parts += "$name $($Actions[$name])" }
    }
    if ($parts.Count -eq 0) { return "no file actions" }
    return $parts -join ", "
}

function Show-MoleHistoryText {
    param($History, [int]$Limit, [string]$LogPath)

    Write-Host "freeMole History"
    Write-Host ""
    Write-Host "Recent sessions"
    $sessions = @(Select-MoleHistoryNewest -Items $History.Sessions -Limit $Limit)
    if ($sessions.Count -eq 0) { Write-Host "  No operation history yet." }
    foreach ($session in $sessions) {
        Write-Host ("  {0,-10} {1}, {2}" -f $session.command, $session.started_at, (Format-MoleHistoryActions $session.actions))
    }
    Write-Host ""
    Write-Host "Recent operations"
    $operations = @(Select-MoleHistoryNewest -Items $History.Operations -Limit $Limit)
    if ($operations.Count -eq 0) { Write-Host "  No operations recorded yet." }
    foreach ($operation in $operations) {
        $detail = if ($operation.detail) { " ($($operation.detail))" } else { "" }
        Write-Host ("  {0} {1,-11} {2}{3}" -f $operation.timestamp, $operation.action, $operation.path, $detail)
    }
    Write-Host ""
    Write-Host "Log"
    Write-Host "  operations: $LogPath"
    Write-Host ""
}

function ConvertTo-MoleHistoryJson {
    param($History, [int]$Limit, [string]$LogPath)

    $report = [ordered]@{
        logs       = [ordered]@{ operations = $LogPath }
        limit      = $Limit
        sessions   = @(Select-MoleHistoryNewest -Items $History.Sessions -Limit $Limit)
        operations = @(Select-MoleHistoryNewest -Items $History.Operations -Limit $Limit)
    }
    return ConvertTo-Json -InputObject $report -Depth 6
}
