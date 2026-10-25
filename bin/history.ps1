# Sweepr - History Command
# Review recent cleanup, purge, optimize and uninstall activity.

#Requires -Version 5.1
[CmdletBinding(PositionalBinding = $false)]
param(
    [Alias('h')]
    [switch]$ShowHelp,

    [switch]$Json,

    # `--limit=20` arrives as the value; `--limit 20` as a switch plus the next word.
    $Limit,

    [Parameter(ValueFromRemainingArguments)]
    [string[]]$Rest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Join-Path (Split-Path -Parent $scriptDir) "lib"
. "$libDir\core\base.ps1"
. "$libDir\core\log.ps1"
. "$libDir\core\history.ps1"

function Show-HistoryHelp {
    Write-Host "Usage: sw history [OPTIONS]"
    Write-Host ""
    Write-Host "Review recent Sweepr cleanup and removal activity."
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  --json           Output history as JSON"
    Write-Host "  --limit N        Show the most recent N entries, 1-200"
    Write-Host "  -h, --help       Show this help message"
}

if ($ShowHelp) {
    Show-HistoryHelp
    return
}

$extra = @($Rest | Where-Object { $null -ne $_ })
$limitValue = $script:SweeprHistoryDefaultLimit
if ($null -ne $Limit) {
    $raw = if ($Limit -is [bool] -or $Limit -is [switch]) {
        if ($extra.Count -eq 0) {
            Write-Host "Missing value for --limit"
            exit 2
        }
        $first = $extra[0]
        $extra = @($extra | Select-Object -Skip 1)
        $first
    }
    else { [string]$Limit }
    $limitValue = ConvertTo-SweeprHistoryLimit $raw
    if ($null -eq $limitValue) {
        Write-Host "Invalid value for --limit: $raw"
        exit 2
    }
}
if ($extra.Count -gt 0) {
    Write-Host "Unexpected argument for sw history: $($extra[0])"
    Write-Host "Run 'sw history --help' for usage."
    exit 2
}

$logPath = $script:SweeprOperationsLogFile
$history = Read-SweeprHistory -Path $logPath
if ($Json) {
    ConvertTo-SweeprHistoryJson -History $history -Limit $limitValue -LogPath $logPath
}
else {
    Show-SweeprHistoryText -History $history -Limit $limitValue -LogPath $logPath
}
