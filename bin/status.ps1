# freeMole - Status Command
# System status monitor wrapper

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Alias('h')]
    [switch]$ShowHelp,

    [switch]$Json,

    [switch]$Watch,

    [string]$Interval
)

$ErrorActionPreference = "Stop"

# Script location
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$windowsDir = Split-Path -Parent $scriptDir
$defaultBinPath = Join-Path $windowsDir "bin\status.exe"
. (Join-Path $windowsDir "lib\core\tui_binaries.ps1")

# Help
function Show-StatusHelp {
    $esc = [char]27
    Write-Host ""
    Write-Host "$esc[1;35mfm status$esc[0m - Real-time system health monitor"
    Write-Host ""
    Write-Host "$esc[33mUsage:$esc[0m fm status [options]"
    Write-Host ""
    Write-Host "$esc[33mOptions:$esc[0m"
    Write-Host "  --json             Output one metrics snapshot as JSON"
    Write-Host "  --watch            Stream snapshots as newline-delimited JSON"
    Write-Host "  --interval=2s      With --watch, collection interval (default 1s)"
    Write-Host "  --help             Show this help message"
    Write-Host ""
    Write-Host "$esc[33mDisplays:$esc[0m"
    Write-Host "  - System health score (0-100)"
    Write-Host "  - CPU, Memory, Disk, Power, Processes and Network cards"
    Write-Host ""
    Write-Host "$esc[33mKeybindings:$esc[0m"
    Write-Host "  c            Cycle how many CPU cores are listed"
    Write-Host "  k            Show or hide the mole"
    Write-Host "  q / Esc      Quit"
    Write-Host ""
}

if ($ShowHelp) {
    Show-StatusHelp
    return
}

$binPath = Ensure-TuiBinary -Name "status" -WindowsDir $windowsDir -DestinationPath $defaultBinPath -SourcePath "./cmd/status/"
if (-not $binPath) {
    Write-TuiBinaryStatus "Could not download the verified status tool for this version from GitHub Releases." -Color Red
    Write-TuiBinaryStatus "Check the network and run 'fm status' again. With Go installed, freeMole builds it locally instead." -Color Yellow
    exit 1
}

# Run the binary
$binArgs = @()
if ($Json) { $binArgs += "--json" }
if ($Watch) { $binArgs += "--watch" }
if ($Interval) { $binArgs += "--interval=$Interval" }
& $binPath @binArgs

# Explicitly propagate native failures through powershell.exe -File as well
# as the executable launcher. Help returns before reaching this point.
exit $LASTEXITCODE
