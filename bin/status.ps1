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

function Get-StarterPathCollision {
    # Windows PowerShell 5.1 reads [ ] * ? in a path it loads or starts as a pattern, so a folder called d[1]
    # also matches a folder called d1 and the file of the wrong folder could be used. Returns a message when
    # the pattern matches anything but the literal file, otherwise $null. PowerShell 7 reads the path as it is.
    param([string]$Path, [string]$Edition = $PSVersionTable.PSEdition)

    if ($Edition -cne 'Desktop') { return $null }
    if ($Path.IndexOfAny([char[]]'[]*?') -lt 0) { return $null }
    $found = @()
    try {
        $provider = $null
        $found = @($ExecutionContext.SessionState.Path.GetResolvedProviderPathFromPSPath($Path, [ref]$provider))
    }
    catch { return $null }
    $literal = [System.IO.Path]::GetFullPath($Path)
    foreach ($item in $found) {
        if (-not [string]::Equals([System.IO.Path]::GetFullPath([string]$item), $literal, [System.StringComparison]::OrdinalIgnoreCase)) {
            return ('Sweepr cannot use the folder ' + [System.IO.Path]::GetDirectoryName($Path) + ': a folder name with [ ] * or ? is read as a pattern by Windows PowerShell 5.1, and here it also matches ' +
                [System.IO.Path]::GetDirectoryName([string]$item) + '. Rename or move the installation to a folder without these characters.')
        }
    }
    return $null
}

# The installation folder from this script's own location, never from the working directory; .NET
# path calls keep brackets and quotes in a folder name literal.
$rootDir = [System.IO.Path]::GetDirectoryName($PSScriptRoot)
$tuiFile = [System.IO.Path]::Combine($rootDir, 'lib', 'core', 'tui_binaries.ps1')
$collision = Get-StarterPathCollision -Path $tuiFile
if ($null -ne $collision) {
    [Console]::Error.WriteLine($collision)
    exit 1
}
try { . $tuiFile }
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}

$program = Resolve-SwTuiBinary -Name 'status' -WindowsDir $rootDir -DestinationPath ([System.IO.Path]::Combine($rootDir, 'bin', 'status.exe')) -SourcePath './cmd/status/'
if ([string]::IsNullOrEmpty($program)) {
    Write-SwTuiStatus 'Sweepr could not provide the verified status program for this version.' -Color 'Red'
    Write-SwTuiStatus 'Check the network connection, or install Go: Sweepr then builds the program on this computer.' -Color 'Yellow'
    exit 1
}

$collision = Get-StarterPathCollision -Path $program
if ($null -ne $collision) {
    Write-SwTuiStatus $collision -Color 'Red'
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
