# Sweepr Windows - renders the winget and Scoop manifests for one
# published release from the templates in packaging/.
#
#   .\scripts\render-packaging.ps1 -Version 1.31.0 -SumsFile release\SHA256SUMS.txt
#
# The zip checksum comes from the release's SHA256SUMS.txt, so run this after
# the signed assets are uploaded. Output goes to release\packaging\.

#Requires -Version 5.1
param(
    [Parameter(Mandatory)]
    [string]$Version,

    [Parameter(Mandatory)]
    [string]$SumsFile,

    [string]$OutDir,

    [string]$ReleaseDate = (Get-Date -Format "yyyy-MM-dd")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version must look like 1.31.0, got '$Version'"
}

$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) {
    $OutDir = Join-Path $projectRoot "release\packaging"
}

$zipName = "sweepr-$Version-x64.zip"
$zipHash = $null
foreach ($line in (Get-Content -LiteralPath $SumsFile)) {
    $entry = $line.Trim([char]0xFEFF).Trim()
    if ($entry -match '^([0-9a-fA-F]{64})\s+\*?(.+)$' -and $Matches[2].Trim() -eq $zipName) {
        $zipHash = $Matches[1].ToLowerInvariant()
    }
}
if (-not $zipHash) {
    throw "$SumsFile has no checksum for $zipName"
}

$tag = "V$Version-windows"
$values = @{
    "VERSION"      = $Version
    "TAG"          = $tag
    "ZIP_URL"      = "https://github.com/brummilab/sweepr/releases/download/$tag/$zipName"
    "ZIP_SHA256"   = $zipHash
    "RELEASE_DATE" = $ReleaseDate
}

$templates = @(
    @{ From = "winget\brummilab.Sweepr.yaml"; To = "winget\manifests\b\brummilab\Sweepr\$Version\brummilab.Sweepr.yaml" },
    @{ From = "winget\brummilab.Sweepr.installer.yaml"; To = "winget\manifests\b\brummilab\Sweepr\$Version\brummilab.Sweepr.installer.yaml" },
    @{ From = "winget\brummilab.Sweepr.locale.en-US.yaml"; To = "winget\manifests\b\brummilab\Sweepr\$Version\brummilab.Sweepr.locale.en-US.yaml" },
    @{ From = "scoop\sweepr.json"; To = "scoop\sweepr.json" }
)

$utf8 = New-Object System.Text.UTF8Encoding $false
foreach ($template in $templates) {
    $source = Join-Path $projectRoot "packaging\$($template.From)"
    $text = [System.IO.File]::ReadAllText($source)
    foreach ($key in $values.Keys) {
        $text = $text.Replace("{{$key}}", $values[$key])
    }
    if ($text -match '\{\{[A-Z_]+\}\}') {
        throw "Unfilled placeholder $($Matches[0]) in $($template.From)"
    }
    $target = Join-Path $OutDir $template.To
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    [System.IO.File]::WriteAllText($target, $text, $utf8)
    Write-Host "  $($template.To)"
}

Write-Host "Rendered manifests for $tag in $OutDir"
