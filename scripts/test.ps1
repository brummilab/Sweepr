# freeMole Windows - Test Runner Script
# Runs all tests (Pester for PowerShell, go test for Go)

#Requires -Version 5.1
param(
    [switch]$Verbose,
    [switch]$NoPester,
    [switch]$NoGo,
    [switch]$Coverage
)

$ErrorActionPreference = "Stop"
$script:ExitCode = 0
# Test removals must not land in the developer's own operation log.
$env:MO_NO_OPLOG = "1"

# Get script directory
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$windowsDir = Split-Path -Parent $scriptDir

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  freeMole Windows - Test Suite" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# Pester Tests
# ============================================================================

if (-not $NoPester) {
    Write-Host "[Pester] Running PowerShell tests..." -ForegroundColor Yellow
    Write-Host ""
    
    # Check if Pester is installed
    $pesterModule = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge "5.0.0" }
    
    if (-not $pesterModule) {
        Write-Host "  Installing Pester 5.x..." -ForegroundColor Gray
        Install-Module -Name Pester -MinimumVersion 5.0.0 -Force -SkipPublisherCheck -Scope CurrentUser
    }
    
    Import-Module Pester -MinimumVersion 5.0.0
    
    $testsDir = Join-Path $windowsDir "tests"
    
    $config = New-PesterConfiguration
    $config.Run.Path = $testsDir
    $config.Run.Exit = $false
    $config.Run.PassThru = $true
    $config.Output.Verbosity = if ($Verbose) { "Detailed" } else { "Normal" }
    
    if ($Coverage) {
        $config.CodeCoverage.Enabled = $true
        $config.CodeCoverage.Path = @(
            (Join-Path $windowsDir "lib\core\*.ps1"),
            (Join-Path $windowsDir "lib\clean\*.ps1"),
            (Join-Path $windowsDir "bin\*.ps1")
        )
        $config.CodeCoverage.OutputPath = Join-Path $windowsDir "coverage-pester.xml"
    }
    
    $result = Invoke-Pester -Configuration $config
    
    Write-Host ""
    Write-Host "[Pester] Summary:" -ForegroundColor Yellow
    
    # Pester 5 reports assertion and container failures through its result.
    # A missing result or a suite with no passing tests is not a passing gate.
    if ($null -ne $result -and $result.Result -eq 'Passed' -and
        $result.PassedCount -gt 0 -and $result.FailedCount -eq 0) {
        Write-Host "  All Pester tests passed!" -ForegroundColor Green
    }
    else {
        Write-Host "  Pester did not complete a passing test run." -ForegroundColor Red
        $script:ExitCode = 1
    }
    
    Write-Host ""
}

# ============================================================================
# Go Tests
# ============================================================================

if (-not $NoGo) {
    Write-Host "[Go] Running Go tests..." -ForegroundColor Yellow
    Write-Host ""
    
    # Only -NoGo may skip this part of the gate.
    # Several Go installs can be on PATH at once; the first is the one a shell runs.
    $goCommand = Get-Command go -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $goReady = $false
    if ($goCommand) {
        $goVersion = & $goCommand.Source version 2>&1
        $goReady = $LASTEXITCODE -eq 0
    }
    if (-not $goReady) {
        Write-Host "  Go is unavailable or its version check failed." -ForegroundColor Red
        $script:ExitCode = 1
    }
    else {
        Write-Host "  $goVersion" -ForegroundColor Gray
        Write-Host ""
        
        Push-Location $windowsDir
        try {
            $goArgs = @("test")
            if ($Verbose) {
                $goArgs += "-v"
            }
            if ($Coverage) {
                $goArgs += "-coverprofile=coverage-go.out"
            }
            $goArgs += "./..."
            
            & $goCommand.Source @goArgs
            
            if ($LASTEXITCODE -ne 0) {
                $script:ExitCode = 1
            }
            else {
                Write-Host ""
                Write-Host "[Go] All tests passed" -ForegroundColor Green
            }
        }
        finally {
            Pop-Location
        }
    }
    
    Write-Host ""
}

# ============================================================================
# Summary
# ============================================================================

Write-Host "========================================" -ForegroundColor Cyan
if ($script:ExitCode -eq 0) {
    Write-Host "  All tests passed!" -ForegroundColor Green
}
else {
    Write-Host "  Some tests failed!" -ForegroundColor Red
}
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

exit $script:ExitCode
