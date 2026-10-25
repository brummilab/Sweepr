# Sweepr - Gate, PowerShell part: parse every script, lint test structure, run Pester.
# Called by scripts/gate.sh. Both scopes run the complete ./tests suite.
#   -Scope all       (Windows) every test must pass.
#   -Scope portable  (Linux/macOS) the failures must be a subset of
#                    tests/linux-known-failures.txt (tests that need real Windows:
#                    registry, powershell.exe, Appx, junctions). A failure that is not
#                    listed turns the gate red; a listed test that now passes is
#                    reported so the list can shrink.

#Requires -Version 5.1
param(
    [ValidateSet('all', 'portable')]
    [string]$Scope = 'portable'
)

$ErrorActionPreference = 'Stop'

$parseErrors = 0
foreach ($file in Get-ChildItem -Path . -Recurse -Filter *.ps1 -File | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }) {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    foreach ($e in @($errors)) {
        Write-Host "$($file.FullName):$($e.Extent.StartLineNumber): $($e.Message)"
        $parseErrors++
    }
}
if ($parseErrors -gt 0) { Write-Host "PowerShell parse errors: $parseErrors"; exit 1 }

# Pester 5 runs only one BeforeAll/BeforeEach/AfterAll/AfterEach per block; a second
# one is silently ignored. Flag any Describe/Context that directly holds more than one.
$setupNames = @('BeforeAll', 'BeforeEach', 'AfterAll', 'AfterEach')
$blockNames = @('Describe', 'Context')
$dupes = 0
foreach ($file in Get-ChildItem -Path ./tests -Filter *.Tests.ps1 -File) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    $blocks = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in $blockNames
        }, $true)
    foreach ($block in $blocks) {
        $body = $block.CommandElements |
            Where-Object { $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst] } |
            Select-Object -Last 1
        if (-not $body) { continue }
        $direct = @()
        foreach ($st in $body.ScriptBlock.EndBlock.Statements) {
            if ($st -is [System.Management.Automation.Language.PipelineAst] -and
                $st.PipelineElements.Count -eq 1 -and
                $st.PipelineElements[0] -is [System.Management.Automation.Language.CommandAst] -and
                $st.PipelineElements[0].GetCommandName() -in $setupNames) {
                $direct += $st.PipelineElements[0]
            }
        }
        foreach ($grp in @($direct | Group-Object { $_.GetCommandName() } | Where-Object { $_.Count -gt 1 })) {
            Write-Host "$($file.FullName):$($grp.Group[1].Extent.StartLineNumber): $($grp.Count) x $($grp.Name) directly in one $($block.GetCommandName()) block (Pester runs only one)"
            $dupes++
        }
    }
}
if ($dupes -gt 0) { Write-Host "Duplicate setup blocks: $dupes"; exit 1 }

# Pin the Pester version like .github/workflows/test.yml: prefer 6.2.0, fall back to 5.7.1.
$preferred = '6.2.0'
$fallback = '5.7.1'
$pesterVersion = $null
foreach ($v in @($preferred, $fallback)) {
    if (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version.ToString() -eq $v }) { $pesterVersion = $v; break }
}
if (-not $pesterVersion) {
    try {
        Install-Module -Name Pester -RequiredVersion $preferred -Force -SkipPublisherCheck -Scope CurrentUser -ErrorAction Stop
        $pesterVersion = $preferred
    }
    catch {
        Write-Host "Pester $preferred is unavailable; falling back to $fallback."
        Install-Module -Name Pester -RequiredVersion $fallback -Force -SkipPublisherCheck -Scope CurrentUser
        $pesterVersion = $fallback
    }
}
Import-Module Pester -RequiredVersion $pesterVersion
Write-Host "Pester $pesterVersion"

$config = New-PesterConfiguration
$config.Run.Path = @('./tests')
$config.Run.PassThru = $true
# ~300 expected failures would drown the log; the portable scope prints its own summary.
$config.Output.Verbosity = if ($Scope -eq 'all') { 'Normal' } else { 'None' }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$result = Invoke-Pester -Configuration $config
Write-Host ("Pester: {0} passed, {1} failed, {2} skipped in {3:N0}s" -f $result.PassedCount, $result.FailedCount, $result.SkippedCount, $sw.Elapsed.TotalSeconds)

if ($Scope -eq 'all') {
    if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') { exit 1 }
    exit 0
}

# portable: compare against the known Windows-only failures.
if ($result.PassedCount -eq 0) { Write-Host 'Pester ran no passing tests.'; exit 1 }
$knownPath = './tests/linux-known-failures.txt'
# Pester 6 renders a boolean -ForEach value as '$true', Pester 5 as 'True'; compare without the '$'.
function ConvertTo-TestKey([string]$Path) { $Path.Trim() -replace '\$(?=(true|false)\b)', '' }
$known = @(Get-Content -LiteralPath $knownPath | Where-Object { $_.Trim() -and -not $_.StartsWith('#') } | ForEach-Object { ConvertTo-TestKey $_ })
$failed = @($result.Failed | ForEach-Object { ConvertTo-TestKey $_.ExpandedPath } | Sort-Object -Unique)
$loadErrors = @($result.Containers | Where-Object { $_.Result -eq 'Failed' -and @($_.Blocks).Count -eq 0 })
$new = @($failed | Where-Object { $_ -notin $known })
$fixed = @($known | Where-Object { $_ -notin $failed })
if ($fixed.Count -gt 0) {
    Write-Host "Note: $($fixed.Count) listed test(s) now pass; remove them from ${knownPath}:"
    $fixed | ForEach-Object { Write-Host "  $_" }
}
if ($loadErrors.Count -gt 0) {
    Write-Host "Test files failed to load: $(($loadErrors | ForEach-Object { $_.Item }) -join ', ')"
    exit 1
}
if ($new.Count -gt 0) {
    Write-Host "NEW failures not in ${knownPath}: $($new.Count)"
    $new | ForEach-Object { Write-Host "  $_" }
    exit 1
}
Write-Host "Pester gate: $($failed.Count) known Windows-only failure(s), no new ones."
