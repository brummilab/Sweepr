# Sweepr - History Module
# Reads the operation log that Write-SweeprOperation appends, for sw history.

#Requires -Version 5.1
Set-StrictMode -Version Latest

if ((Get-Variable -Name 'SWEEPR_HISTORY_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:SWEEPR_HISTORY_LOADED) { return }
$script:SWEEPR_HISTORY_LOADED = $true

$script:SweeprHistoryDefaultLimit = 20
$script:SweeprHistoryMaxLimit = 200

# A limit is a plain decimal from 1 to 200.
function ConvertTo-SweeprHistoryLimit {
    param([string]$Value)

    if ($Value -notmatch '^[0-9]{1,3}$') { return $null }
    $number = [int]$Value
    if ($number -lt 1 -or $number -gt $script:SweeprHistoryMaxLimit) { return $null }
    return $number
}

function New-SweeprHistorySession {
    param([string]$Command, [string]$RunId, [string]$StartedAt)

    return [ordered]@{
        command         = $Command
        run_id          = $RunId
        started_at      = $StartedAt
        operation_count = 0
        actions         = [ordered]@{ removed = 0; recycled = 0; uninstalled = 0; disabled = 0; restored = 0; skipped = 0; failed = 0; other = 0 }
    }
}

# Sessions in log order with their action counts, and every record. A record
# whose run has no start marker (a log cut by rotation) opens its own session.
function Read-SweeprHistory {
    param([string]$Path)

    $sessions = New-Object System.Collections.Generic.List[object]
    $operations = New-Object System.Collections.Generic.List[object]
    $byRun = @{}
    if (-not [System.IO.File]::Exists($Path)) {
        return @{ Sessions = @(); Operations = @() }
    }

    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -match '^# ========== (\S+)(?: run=(\S+))? session started at (.+) ==========$') {
            $session = New-SweeprHistorySession -Command $Matches[1] -RunId ([string]$Matches[2]) -StartedAt $Matches[3]
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
            $session = New-SweeprHistorySession -Command $record.command -RunId $record.run_id -StartedAt $record.timestamp
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
function Select-SweeprHistoryNewest {
    param($Items, [int]$Limit)

    $all = @($Items)
    if ($all.Count -eq 0) { return @() }
    $start = [Math]::Max(0, $all.Count - $Limit)
    $newest = @($all[$start..($all.Count - 1)])
    [array]::Reverse($newest)
    return $newest
}

function Format-SweeprHistoryActions {
    param($Actions)

    $parts = @()
    foreach ($name in @("removed", "recycled", "uninstalled", "disabled", "restored", "skipped", "failed", "other")) {
        if ($Actions[$name] -gt 0) { $parts += "$name $($Actions[$name])" }
    }
    if ($parts.Count -eq 0) { return "no file actions" }
    return $parts -join ", "
}

function Show-SweeprHistoryText {
    param($History, [int]$Limit, [string]$LogPath)

    Write-Host "Sweepr History"
    Write-Host ""
    Write-Host "Recent sessions"
    $sessions = @(Select-SweeprHistoryNewest -Items $History.Sessions -Limit $Limit)
    if ($sessions.Count -eq 0) { Write-Host "  No operation history yet." }
    foreach ($session in $sessions) {
        Write-Host ("  {0,-10} {1}, {2}" -f $session.command, $session.started_at, (Format-SweeprHistoryActions $session.actions))
    }
    Write-Host ""
    Write-Host "Recent operations"
    $operations = @(Select-SweeprHistoryNewest -Items $History.Operations -Limit $Limit)
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

function ConvertTo-SweeprHistoryJson {
    param($History, [int]$Limit, [string]$LogPath)

    $report = [ordered]@{
        logs       = [ordered]@{ operations = $LogPath }
        limit      = $Limit
        sessions   = @(Select-SweeprHistoryNewest -Items $History.Sessions -Limit $Limit)
        operations = @(Select-SweeprHistoryNewest -Items $History.Operations -Limit $Limit)
    }
    return ConvertTo-Json -InputObject $report -Depth 6
}
