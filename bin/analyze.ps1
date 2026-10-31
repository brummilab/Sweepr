# Sweepr - Analyze Command
# Starts the native disk explorer (analyze.exe) and hands its exit code on.

#Requires -Version 5.1
[CmdletBinding()]
param(
    # The folder reaches the program only through SWEEPR_ANALYZE_PATH, never as an argument.
    [Parameter(Position = 0)]
    [string]$Path,

    [Alias('h')]
    [switch]$ShowHelp,

    [switch]$Json,

    [Alias('d')]
    [switch]$DebugMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-AnalyzeUsageText {
    Write-Host 'Usage: sw analyze [options] [path]'
    Write-Host ''
    Write-Host 'Disk explorer: see which folders and files take the space, and move entries to the'
    Write-Host 'Recycle Bin. Without a path it opens the drives or folders of this computer.'
    Write-Host ''
    Write-Host 'Options:'
    Write-Host '  --json               Print the sizes as JSON instead of opening the explorer'
    Write-Host '  --debug              Write a debug log and show where it is'
    Write-Host '  -h, --help           Show this help'
    Write-Host ''
    Write-Host 'Keys:'
    Write-Host '  Up, Down             Move the cursor'
    Write-Host '  PgUp, PgDn           Move one page; Home and End jump to the first and last entry'
    Write-Host '  Enter, Right         Open the folder'
    Write-Host '  Left, Backspace      Go back'
    Write-Host '  Space                Mark or unmark an entry'
    Write-Host '  Delete               Move the marked entries to the Recycle Bin (asks first)'
    Write-Host '  T                    Show the largest files'
    Write-Host '  R                    Rescan the current folder'
    Write-Host '  Esc                  Go back; in the overview, quit'
    Write-Host '  Q                    Quit'
}

function Set-AnalyzeVariable {
    # A null value removes the variable; [NullString]::Value is how PowerShell tells .NET so (a plain
    # $null would arrive as an empty string and leave an empty variable behind).
    param([string]$Name, [AllowNull()]$Value)

    if ($null -eq $Value) { [System.Environment]::SetEnvironmentVariable($Name, [NullString]::Value) }
    else { [System.Environment]::SetEnvironmentVariable($Name, [string]$Value) }
}

if ($ShowHelp) {
    Write-AnalyzeUsageText
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

# The program is provided before any variable changes, so a failure leaves the environment alone.
$program = Resolve-SwTuiBinary -Name 'analyze' -WindowsDir $rootDir -DestinationPath ([System.IO.Path]::Combine($rootDir, 'bin', 'analyze.exe')) -SourcePath './cmd/analyze/'
if ([string]::IsNullOrEmpty($program)) {
    Write-SwTuiStatus 'Sweepr could not provide the verified analyze program for this version.' -Color 'Red'
    Write-SwTuiStatus 'Check the network connection, or install Go: Sweepr then builds the program on this computer.' -Color 'Yellow'
    exit 1
}

$collision = Get-StarterPathCollision -Path $program
if ($null -ne $collision) {
    Write-SwTuiStatus $collision -Color 'Red'
    exit 1
}

$arguments = @()
if ($Json) { $arguments += '--json' }

# Both variables are put back to what the session had, also when the program cannot be started.
$savedPath = [System.Environment]::GetEnvironmentVariable('SWEEPR_ANALYZE_PATH')
$savedDebug = [System.Environment]::GetEnvironmentVariable('SWEEPR_DEBUG')
$exitCode = 0
try {
    # Removed, not emptied, when there is no path: an earlier value must not leak into this run.
    if ([string]::IsNullOrEmpty($Path)) { Set-AnalyzeVariable -Name 'SWEEPR_ANALYZE_PATH' -Value $null }
    else { Set-AnalyzeVariable -Name 'SWEEPR_ANALYZE_PATH' -Value $Path }
    if ($DebugMode) { Set-AnalyzeVariable -Name 'SWEEPR_DEBUG' -Value '1' }

    & $program @arguments
    $exitCode = [int]$LASTEXITCODE
}
finally {
    Set-AnalyzeVariable -Name 'SWEEPR_ANALYZE_PATH' -Value $savedPath
    Set-AnalyzeVariable -Name 'SWEEPR_DEBUG' -Value $savedDebug
}
# Under -File only an explicit exit carries the program's code to the caller.
exit $exitCode
