# Sweepr - Analyze Command
# Disk space analyzer wrapper

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Path,
    
    [Alias('h')]
    [switch]$ShowHelp,

    [switch]$Json,

    [Alias('d')]
    [switch]$DebugMode
)

$ErrorActionPreference = "Stop"

# Script location
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$windowsDir = Split-Path -Parent $scriptDir
$defaultBinPath = Join-Path $windowsDir "bin\analyze.exe"
. (Join-Path $windowsDir "lib\core\tui_binaries.ps1")

# Help
function Show-AnalyzeHelp {
    $esc = [char]27
    Write-Host ""
    Write-Host "$esc[1;35msw analyze$esc[0m - Disk explorer: folder sizes, largest files, Recycle Bin"
    Write-Host ""
    Write-Host "$esc[33mUsage:$esc[0m sw analyze [options] [path]"
    Write-Host ""
    Write-Host "$esc[33mOptions:$esc[0m"
    Write-Host "  [path]     Folder to open (default: profile folder and fixed drives)"
    Write-Host "  --json     Output the measurement as JSON instead of the interactive view"
    Write-Host "  --debug    Write a debug log"
    Write-Host "  --help     Show this help message"
    Write-Host ""
    Write-Host "$esc[33mKeybindings:$esc[0m"
    Write-Host "  Up/Down          Move the cursor"
    Write-Host "  PgUp/PgDn        Page up or down"
    Write-Host "  Enter/Right      Open folder"
    Write-Host "  Left/Backspace   Go back"
    Write-Host "  Space            Mark or unmark"
    Write-Host "  Delete           Move marked entries to the Recycle Bin (asks first)"
    Write-Host "  T                Largest files"
    Write-Host "  R                Measure again"
    Write-Host "  Esc              Back; quits in the overview"
    Write-Host "  Q                Quit"
    Write-Host ""
}

if ($ShowHelp) {
    Show-AnalyzeHelp
    return
}

$binPath = Ensure-TuiBinary -Name "analyze" -WindowsDir $windowsDir -DestinationPath $defaultBinPath -SourcePath "./cmd/analyze/"
if (-not $binPath) {
    Write-TuiBinaryStatus "Could not download the verified analyze tool for this version from GitHub Releases." -Color Red
    Write-TuiBinaryStatus "Check the network and run 'sw analyze' again. With Go installed, Sweepr builds it locally instead." -Color Yellow
    exit 1
}

$previousDebug = $env:SWEEPR_DEBUG
if ($DebugMode) { $env:SWEEPR_DEBUG = "1" }

# Pass the path for this run only: without one the analyzer opens the overview,
# so a path left in the session by an earlier run must not leak into the next.
$previousPath = $env:SWEEPR_ANALYZE_PATH
$env:SWEEPR_ANALYZE_PATH = $Path
# --json makes the analyzer print one JSON object and exit without the TUI.
$binArgs = @()
if ($Json) { $binArgs += "--json" }
try {
    & $binPath @binArgs
}
finally {
    $env:SWEEPR_ANALYZE_PATH = $previousPath
    $env:SWEEPR_DEBUG = $previousDebug
}

# Explicitly propagate native failures through powershell.exe -File as well
# as the executable launcher. Help returns before reaching this point.
exit $LASTEXITCODE
