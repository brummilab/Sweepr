# Sweepr Windows - Release Build Script
# Builds release artifacts for distribution via package managers
# Outputs: ZIP, EXE, and generates SHA256 hashes

#Requires -Version 5.1
param(
    [Parameter(Mandatory=$false)]
    [string]$Version,
    
    [switch]$SkipTests,
    [switch]$ShowHelp
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ============================================================================
# Configuration
# ============================================================================

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
$releaseDir = Join-Path $projectRoot "release"
$binDir = Join-Path $projectRoot "bin"
$cmdDir = Join-Path $projectRoot "cmd"
$versionFile = Join-Path $projectRoot "VERSION"

# Read version from VERSION if not provided
if (-not $Version) {
    if (Test-Path $versionFile) {
        $Version = (Get-Content $versionFile -Raw).Trim()
    }
    if (-not $Version) {
        Write-Host "Error: Could not detect version from VERSION" -ForegroundColor Red
        exit 1
    }
}

$buildDate = Get-Date -Format "yyyy-MM-dd"
$archiveName = "sweepr-$Version-x64"

# ============================================================================
# Help
# ============================================================================

function Show-BuildHelp {
    Write-Host ""
    Write-Host "Sweepr Windows Release Build Script" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage: .\build-release.ps1 [-Version <version>] [-SkipTests]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -Version <ver>  Specify version (default: read from VERSION)"
    Write-Host "  -SkipTests      Skip running tests before building"
    Write-Host "  -ShowHelp       Show this help message"
    Write-Host ""
    Write-Host "Output:"
    Write-Host "  release/sweepr-<version>-x64.zip        Portable archive"
    Write-Host "  release/analyze-windows-x64.exe       Disk analyzer TUI"
    Write-Host "  release/status-windows-x64.exe        Status TUI"
    Write-Host "  release/SHA256SUMS.txt                 Hash file for verification"
    Write-Host ""
}

if ($ShowHelp) {
    Show-BuildHelp
    exit 0
}

# ============================================================================
# Banner
# ============================================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Sweepr Windows - Release Build" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Version: $Version" -ForegroundColor Yellow
Write-Host "Build Date: $buildDate" -ForegroundColor Yellow
Write-Host "Output: $releaseDir" -ForegroundColor Yellow
Write-Host ""

# ============================================================================
# Pre-flight Checks
# ============================================================================

Write-Host "[1/6] Running pre-flight checks..." -ForegroundColor Cyan

# Check Go installation
$goVersion = & go version 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Error: Go is not installed" -ForegroundColor Red
    Write-Host "  Install from: https://golang.org/dl/" -ForegroundColor Gray
    exit 1
}
Write-Host "  Go: $goVersion" -ForegroundColor Green

# Check PowerShell version
$psVersion = $PSVersionTable.PSVersion
Write-Host "  PowerShell: $psVersion" -ForegroundColor Green

# Check required directories exist
$requiredDirs = @($binDir, $cmdDir, "$projectRoot\lib")
foreach ($dir in $requiredDirs) {
    if (-not (Test-Path $dir)) {
        Write-Host "  Error: Required directory not found: $dir" -ForegroundColor Red
        exit 1
    }
}
Write-Host "  Project structure: OK" -ForegroundColor Green
Write-Host ""

# ============================================================================
# Run Tests
# ============================================================================

if (-not $SkipTests) {
    Write-Host "[2/6] Running tests..." -ForegroundColor Cyan
    
    $testScript = Join-Path $projectRoot "scripts\test.ps1"
    if (Test-Path $testScript) {
        try {
            & $testScript
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  Tests failed! Aborting release build." -ForegroundColor Red
                exit 1
            }
            Write-Host "  All tests passed" -ForegroundColor Green
        } catch {
            Write-Host "  Test execution failed: $_" -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "  Warning: Test script not found, skipping..." -ForegroundColor Yellow
    }
    Write-Host ""
} else {
    Write-Host "[2/6] Skipping tests (--SkipTests flag)" -ForegroundColor Yellow
    Write-Host ""
}

# ============================================================================
# Clean Release Directory
# ============================================================================

Write-Host "[3/6] Preparing release directory..." -ForegroundColor Cyan

if (Test-Path $releaseDir) {
    Write-Host "  Cleaning existing release directory..." -ForegroundColor Gray
    Remove-Item $releaseDir -Recurse -Force
}

New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null
Write-Host "  Release directory ready: $releaseDir" -ForegroundColor Green
Write-Host ""

# ============================================================================
# Build Go Binaries
# ============================================================================

Write-Host "[4/6] Building Go binaries..." -ForegroundColor Cyan

Push-Location $projectRoot
try {
    # Build flags for release (strip debug info, optimize)
    $env:CGO_ENABLED = "0"
    $env:GOOS = "windows"
    $env:GOARCH = "amd64"
    $ldflags = "-s -w -X main.version=$Version -X main.buildDate=$buildDate"
    
    # Ensure bin directory exists
    if (-not (Test-Path $binDir)) {
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    }
    
    # Build analyze.exe
    Write-Host "  Building analyze.exe..." -ForegroundColor Gray
    & go build -ldflags $ldflags -o "$binDir\analyze.exe" "./cmd/analyze/"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Failed to build analyze.exe" -ForegroundColor Red
        exit 1
    }
    $analyzeSize = (Get-Item "$binDir\analyze.exe").Length / 1KB
    Write-Host "  Built: analyze.exe ($([math]::Round($analyzeSize, 0)) KB)" -ForegroundColor Green
    
    # Build status.exe
    Write-Host "  Building status.exe..." -ForegroundColor Gray
    & go build -ldflags $ldflags -o "$binDir\status.exe" "./cmd/status/"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Failed to build status.exe" -ForegroundColor Red
        exit 1
    }
    $statusSize = (Get-Item "$binDir\status.exe").Length / 1KB
    Write-Host "  Built: status.exe ($([math]::Round($statusSize, 0)) KB)" -ForegroundColor Green

    # sw.exe is the launcher package managers put on PATH; it sits at the
    # archive root next to sweepr.ps1, so it is built outside bin\.
    Write-Host "  Building sw.exe..." -ForegroundColor Gray
    $launcherDir = Join-Path $releaseDir "launcher"
    New-Item -ItemType Directory -Path $launcherDir -Force | Out-Null
    & go build -ldflags "-s -w" -o "$launcherDir\sw.exe" "./cmd/sw/"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Failed to build sw.exe" -ForegroundColor Red
        exit 1
    }
    Write-Host "  Built: sw.exe" -ForegroundColor Green
}
finally {
    Pop-Location
}
Write-Host ""

# ============================================================================
# Create Portable ZIP Archive
# ============================================================================

Write-Host "[5/6] Creating portable ZIP archive..." -ForegroundColor Cyan

$tempBuildDir = Join-Path $releaseDir "temp-build"
New-Item -ItemType Directory -Path $tempBuildDir -Force | Out-Null

# Copy all necessary files
$filesToInclude = @(
    @{Source = "$projectRoot\sweepr.ps1"; Dest = "$tempBuildDir\sweepr.ps1"},
    @{Source = "$projectRoot\install.ps1"; Dest = "$tempBuildDir\install.ps1"},
    @{Source = "$projectRoot\go.mod"; Dest = "$tempBuildDir\go.mod"},
    @{Source = "$projectRoot\go.sum"; Dest = "$tempBuildDir\go.sum"},
    @{Source = "$projectRoot\VERSION"; Dest = "$tempBuildDir\VERSION"},
    @{Source = "$projectRoot\LICENSE"; Dest = "$tempBuildDir\LICENSE"},
    @{Source = "$projectRoot\README.md"; Dest = "$tempBuildDir\README.md"},
    @{Source = "$releaseDir\launcher\sw.exe"; Dest = "$tempBuildDir\sw.exe"}
)

foreach ($file in $filesToInclude) {
    if (Test-Path $file.Source) {
        Copy-Item $file.Source $file.Dest -Force
        Write-Host "  Added: $(Split-Path $file.Source -Leaf)" -ForegroundColor Gray
    }
}

# Copy directories
$dirsToInclude = @("bin", "lib", "cmd")
foreach ($dir in $dirsToInclude) {
    $sourcePath = Join-Path $projectRoot $dir
    $destPath = Join-Path $tempBuildDir $dir
    if (Test-Path $sourcePath) {
        Copy-Item $sourcePath $destPath -Recurse -Force
        $fileCount = (Get-ChildItem $destPath -Recurse -File).Count
        Write-Host "  Added: $dir\ ($fileCount files)" -ForegroundColor Gray
    }
}

# Create ZIP archive
$zipPath = Join-Path $releaseDir "$archiveName.zip"
Write-Host "  Compressing to ZIP..." -ForegroundColor Gray
& (Join-Path $scriptDir "new-release-zip.ps1") -SourceDir $tempBuildDir -Destination $zipPath

$zipSize = (Get-Item $zipPath).Length / 1MB
Write-Host "  Created: $archiveName.zip ($([math]::Round($zipSize, 2)) MB)" -ForegroundColor Green

# The portable ZIP is the same tree plus the sweepr.portable marker. It is added
# only after the normal ZIP exists, because winget/Scoop use the normal ZIP and
# the marker would switch them into portable mode.
$portableMarker = Join-Path $tempBuildDir "sweepr.portable"
$portableText = "This file turns on Sweepr portable mode. Settings, whitelist, operation log and caches are kept in the data folder next to it; nothing is written to your user profile. Delete this file to use the normal per-user folders instead."
[System.IO.File]::WriteAllText($portableMarker, $portableText + "`r`n", (New-Object System.Text.UTF8Encoding $false))
$portableName = "$archiveName-portable.zip"
$portableZipPath = Join-Path $releaseDir $portableName
& (Join-Path $scriptDir "new-release-zip.ps1") -SourceDir $tempBuildDir -Destination $portableZipPath
$portableSize = (Get-Item $portableZipPath).Length / 1MB
Write-Host "  Created: $portableName ($([math]::Round($portableSize, 2)) MB)" -ForegroundColor Green

# Cleanup temp directories
Remove-Item $tempBuildDir -Recurse -Force
Remove-Item (Join-Path $releaseDir "launcher") -Recurse -Force
Write-Host ""

# ============================================================================
# TUI Assets and Checksums
# ============================================================================

Write-Host "[6/6] Writing TUI assets and checksums..." -ForegroundColor Cyan

# The raw TUI executables are what lib/core/tui_binaries.ps1 downloads, and
# SHA256SUMS.txt must list every asset it may verify.
$tuiAssets = @(
    @{ Source = Join-Path $binDir "analyze.exe"; Name = "analyze-windows-x64.exe" },
    @{ Source = Join-Path $binDir "status.exe"; Name = "status-windows-x64.exe" }
)
foreach ($tui in $tuiAssets) {
    Copy-Item -LiteralPath $tui.Source -Destination (Join-Path $releaseDir $tui.Name) -Force
    Write-Host "  $($tui.Name)" -ForegroundColor Gray
}
& (Join-Path $scriptDir "write-checksums.ps1") -Directory $releaseDir -Files (@("$archiveName.zip", $portableName) + ($tuiAssets | ForEach-Object { $_.Name }))
Write-Host ""

# ============================================================================
# Summary
# ============================================================================

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Build Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Release artifacts in: $releaseDir" -ForegroundColor Yellow
Write-Host ""
Write-Host "Files created:" -ForegroundColor Cyan
Get-ChildItem $releaseDir | ForEach-Object {
    $size = if ($_.PSIsContainer) { "-" } else { "$([math]::Round($_.Length / 1KB, 0)) KB" }
    Write-Host "  - $($_.Name) ($size)" -ForegroundColor Gray
}
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Test the ZIP archive: Expand-Archive release\$archiveName.zip -DestinationPath test\" -ForegroundColor Gray
Write-Host "  2. Follow RELEASE.md to check and publish" -ForegroundColor Gray
Write-Host ""
Write-Host "To verify integrity:" -ForegroundColor Cyan
Write-Host "  sha256sum -c release\SHA256SUMS.txt" -ForegroundColor Gray
Write-Host ""
