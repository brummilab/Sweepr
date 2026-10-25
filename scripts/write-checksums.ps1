# Sweepr Windows - writes SHA256SUMS.txt for a set of release files.
# Used by the release workflow and by sign-release.ps1, so the format lives in
# one place: "<sha256>  <file name>", LF line endings, UTF-8 without a BOM.

#Requires -Version 5.1
param(
    [Parameter(Mandatory)]
    [string]$Directory,

    [Parameter(Mandatory)]
    [string[]]$Files
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$lines = foreach ($file in $Files) {
    $path = Join-Path $Directory $file
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing release file: $file"
    }
    "{0}  {1}" -f (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(), $file
}

$sumsPath = Join-Path $Directory "SHA256SUMS.txt"
[System.IO.File]::WriteAllText($sumsPath, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding $false))
Write-Host "Wrote $sumsPath"
