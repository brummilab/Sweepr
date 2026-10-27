# Sweepr - History Command
# Shows the most recent runs and entries of the operations log, as text or JSON. Read only.

#Requires -Version 5.1
# PositionalBinding off: a stray word must land in RemainingArguments, never in Limit.
[CmdletBinding(PositionalBinding = $false)]
param(
    [Alias('h')]
    [switch]$ShowHelp,

    [switch]$Json,

    # Not typed: the router passes the bare switch value $true when --limit has no value.
    $Limit,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Module folder from this script's own location, never from the working directory.
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Join-Path (Split-Path -Parent $scriptDir) 'lib'

. "$libDir\core\base.ps1"
. "$libDir\core\log.ps1"
. "$libDir\core\history.ps1"

function Write-HistoryHelp {
    Write-Host 'Usage: sw history [OPTIONS]'
    Write-Host ''
    Write-Host 'Show what Sweepr removed, recycled, uninstalled, disabled, restored, skipped'
    Write-Host 'or failed to do, from the operations log. Nothing is changed.'
    Write-Host ''
    Write-Host 'Options:'
    Write-Host '  --json         Print one JSON document instead of text'
    Write-Host '  --limit N      Show at most N sessions and N operations (1-200, default 20)'
    Write-Host '  -h, --help     Show this help'
}

function Stop-HistoryUsage {
    # Usage errors go to stderr so stdout never holds a half result.
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 2
}

if ($ShowHelp) {
    Write-HistoryHelp
    exit 0
}

$words = @()
if ($null -ne $RemainingArguments) { $words = @($RemainingArguments) }

$effectiveLimit = 20
if ($PSBoundParameters.ContainsKey('Limit')) {
    $rawLimit = $Limit
    if ($rawLimit -is [bool] -and $rawLimit) {
        # Direct call "-Limit 5": the value arrives as the next loose word.
        if ($words.Count -eq 0) {
            Stop-HistoryUsage 'sw history: --limit needs a value (1-200). See sw history --help.'
        }
        $rawLimit = $words[0]
        $words = @($words | Select-Object -Skip 1)
    }
    $parsed = ConvertTo-SwHistoryLimit -Value ([string]$rawLimit)
    if ($null -eq $parsed) {
        Stop-HistoryUsage ("sw history: invalid --limit value '{0}' (use a whole number from 1 to 200)." -f [string]$rawLimit)
    }
    $effectiveLimit = $parsed
}

if ($words.Count -gt 0) {
    Stop-HistoryUsage ("sw history: unexpected argument '{0}'. See sw history --help." -f $words[0])
}

$logPath = [string]$script:SweeprOperationsLogFile

try {
    $history = Read-SwHistory -Path $logPath
}
catch {
    # One plain line with path and reason, no stack trace.
    [Console]::Error.WriteLine('sw history: ' + $_.Exception.Message)
    exit 1
}

if ($Json) {
    Write-Output (ConvertTo-SwHistoryJson -History $history -Limit $effectiveLimit -LogPath $logPath)
}
else {
    Write-SwHistoryText -History $history -Limit $effectiveLimit -LogPath $logPath
}
exit 0
