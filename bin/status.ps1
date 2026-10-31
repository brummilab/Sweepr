# Sweepr - Status Command
# Starts the native system monitor (status.exe) and hands its exit code on.

#Requires -Version 5.1
# PositionalBinding off: the program takes no loose word, so one is an error for the router, not a value.
[CmdletBinding(PositionalBinding = $false)]
param(
    [Alias('h')]
    [switch]$ShowHelp,

    [switch]$Json,

    [switch]$Watch,

    [string]$Interval
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-StatusUsageText {
    Write-Host 'Usage: sw status [options]'
    Write-Host ''
    Write-Host 'Show CPU, memory, disks, network and the busiest processes of this computer.'
    Write-Host 'Nothing is changed.'
    Write-Host ''
    Write-Host 'Options:'
    Write-Host '  --json               Print one measurement as JSON and exit'
    Write-Host '  --watch              Print one JSON line per measurement until stopped'
    Write-Host '  --interval=<time>    Wait between two measurements with --watch (500ms, 1s, 2m)'
    Write-Host '  -h, --help           Show this help'
    Write-Host ''
    Write-Host 'Keys in the live display:'
    Write-Host '  c                    Change how many CPU cores are listed (2, 4, 8, all)'
    Write-Host '  q, Esc               Quit'
}

if ($ShowHelp) {
    Write-StatusUsageText
    return
}

# The installation folder from this script's own location, never from the working directory; .NET
# path calls keep brackets and quotes in a folder name literal.
$rootDir = [System.IO.Path]::GetDirectoryName($PSScriptRoot)
. ([System.IO.Path]::Combine($rootDir, 'lib', 'core', 'tui_binaries.ps1'))

$program = Resolve-SwTuiBinary -Name 'status' -WindowsDir $rootDir -DestinationPath ([System.IO.Path]::Combine($rootDir, 'bin', 'status.exe')) -SourcePath './cmd/status/'
if ([string]::IsNullOrEmpty($program)) {
    Write-SwTuiStatus 'Sweepr could not provide the verified status program for this version.' -Color 'Red'
    Write-SwTuiStatus 'Check the network connection, or install Go: Sweepr then builds the program on this computer.' -Color 'Yellow'
    exit 1
}

# Only these three forms reach the program; the interval is one argument, also when it holds blanks.
$arguments = @()
if ($Json) { $arguments += '--json' }
if ($Watch) { $arguments += '--watch' }
if (-not [string]::IsNullOrEmpty($Interval)) { $arguments += ('--interval=' + $Interval) }

& $program @arguments
# Under -File only an explicit exit carries the program's code to the caller.
exit $LASTEXITCODE
