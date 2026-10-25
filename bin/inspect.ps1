# freeMole - Inspect Command
# Read-only look inside an installed app with REA: runtime, code signer,
# imported DLLs and .NET metadata. Never runs, changes or deletes the target.

#Requires -Version 5.1
[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$Json,

    [switch]$Deep,

    [switch]$Setup,

    [Alias('d')]
    [switch]$DebugMode,

    [Alias('h')]
    [switch]$ShowHelp,

    [Parameter(ValueFromRemainingArguments)]
    [string[]]$Rest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Join-Path (Split-Path -Parent $scriptDir) "lib"

. "$libDir\core\base.ps1"
. "$libDir\core\log.ps1"
. "$libDir\core\rea.ps1"

function Show-InspectHelp {
    $esc = [char]27
    Write-Host ""
    Write-Host "$esc[1;35mfm inspect$esc[0m - Look inside an installed app with REA (read-only)"
    Write-Host ""
    Write-Host "$esc[33mUsage:$esc[0m fm inspect [options] <app name | folder | file.exe>"
    Write-Host ""
    Write-Host "$esc[33mOptions:$esc[0m"
    Write-Host "  --deep          Also list imported DLLs and .NET assembly metadata"
    Write-Host "  --json          Print the summary as JSON"
    Write-Host "  --setup         Register REA's MCP server with your AI agents (npx rea-agents setup)"
    Write-Host "  --debug         Show detailed operation logs"
    Write-Host "  -h, --help      Show this help message"
    Write-Host ""
    Write-Host "$esc[33mExamples:$esc[0m"
    Write-Host "  fm inspect Slack                         # Find Slack among installed apps"
    Write-Host "  fm inspect `"C:\Program Files\App`" --deep"
    Write-Host "  fm inspect .\tool.exe --json"
    Write-Host ""
    Write-Host "Needs REA: 'npm install --global rea-agents', or Node.js 22+ for npx."
    Write-Host "REA reads headers and metadata only. It does not run the app or verify signatures."
    Write-Host ""
}

# Progress lines go to stderr while JSON goes to stdout.
function Write-InspectStatus {
    param([string]$Message)
    if ($Json) { [Console]::Error.WriteLine($Message) }
    else { Write-Host $Message -ForegroundColor Gray }
}

function Show-InspectSummary {
    param($Summary)

    $esc = [char]27
    Write-Host ""
    Write-Host "$esc[1;35m$($Summary.Name)$esc[0m"
    Write-Host "  Path:        $($Summary.Path)"
    if ($Summary.MainExecutable) { Write-Host "  Executable:  $($Summary.MainExecutable)" }
    if ($Summary.Architecture) { Write-Host "  Arch:        $($Summary.Architecture)" }

    if ($Summary.Kind -ne "Directory") {
        Write-Host "  Runtime:     not checked (pass the install folder to detect it)"
    }
    elseif (@($Summary.Runtimes).Count -gt 0) {
        $families = @($Summary.Runtimes | ForEach-Object { "$($_.Family) ($($_.Confidence))" })
        Write-Host "  Runtime:     $($families -join ', ')"
    }
    else {
        Write-Host "  Runtime:     native or unknown (no Electron, .NET, Unity, Godot or Unreal markers)"
    }

    if ($null -eq $Summary.Signed) {
        Write-Host "  Signature:   not checked"
    }
    elseif ($Summary.Signed -and $Summary.Signer) {
        $who = $Summary.Signer.Subject
        if ($Summary.Signer.Organization -and $Summary.Signer.Organization -ne $who) { $who = "$who, $($Summary.Signer.Organization)" }
        Write-Host "  Signature:   $esc[32m$who$esc[0m (issuer: $($Summary.Signer.Issuer))"
    }
    elseif ($Summary.Signed) {
        Write-Host "  Signature:   certificate table present, signer not identified"
    }
    else {
        Write-Host "  Signature:   $esc[33mno embedded Authenticode table$esc[0m (may still be catalog-signed)"
    }

    if ($Summary.Managed) {
        $frameworks = @($Summary.Managed.TargetFrameworks) -join ', '
        $line = "$($Summary.Managed.RuntimeFamily)"
        if ($Summary.Managed.Assembly) { $line += ", $($Summary.Managed.Assembly)" }
        if ($frameworks) { $line += ", $frameworks" }
        Write-Host "  .NET:        $line"
    }

    if (@($Summary.ImportedDlls).Count -gt 0) {
        Write-Host "  Imports:     $(@($Summary.ImportedDlls).Count) DLLs"
        foreach ($dll in @($Summary.ImportedDlls)) { Write-Host "               $dll" }
    }

    if (@($Summary.NextProbes).Count -gt 0) {
        Write-Host ""
        Write-Host "  Go deeper with REA:"
        foreach ($probe in @($Summary.NextProbes | Select-Object -First 5)) {
            $command = $probe.Operation -replace '_', '-'
            Write-Host "    rea $command `"$($probe.Path)`""
        }
    }

    foreach ($message in @($Summary.Errors)) {
        Write-Host "  $esc[33m! $message$esc[0m"
    }
    Write-Host ""
}

function Main {
    if ($DebugMode) {
        Enable-DebugMode
        $DebugPreference = "Continue"
    }

    if ($ShowHelp) {
        Show-InspectHelp
        return
    }

    $invocation = Get-MoleReaInvocation
    if (-not $invocation) {
        Write-MoleError "REA was not found. Install it with 'npm install --global rea-agents' (Node.js 22 or newer)."
        Write-Host "More: https://github.com/morluto/rea"
        exit 1
    }
    Write-Debug "REA runner: $($invocation.Description)"

    if ($Setup) {
        # Interactive: REA shows its proposed agent changes and asks first.
        & $invocation.File @($invocation.Prefix) "setup"
        exit $LASTEXITCODE
    }

    $targetText = (@($Rest | Where-Object { $_ }) -join ' ').Trim()
    if (-not $targetText) {
        Write-MoleError "Name an installed app, a folder or an .exe to inspect"
        Write-Host "Run 'fm inspect --help' for usage."
        exit 2
    }

    $target = Resolve-MoleInspectTarget -Target $targetText
    if ($target.ContainsKey("Error")) {
        Write-MoleError $target.Error
        foreach ($name in @($target.Matches)) { Write-Host "  $($script:Icons.List) $name" }
        exit 2
    }

    if ($target.Kind -eq "Directory" -and -not $target.MainExecutable) {
        $target.MainExecutable = Get-MoleInspectMainExecutable -Directory $target.Path
    }

    $errors = @()
    $desktop = $null
    $certificates = $null
    $imports = $null
    $managed = $null

    if ($invocation.Prefix.Count -gt 0) {
        Write-InspectStatus "Starting REA through npx; the first run downloads it..."
    }

    if ($target.Kind -eq "Directory") {
        Write-InspectStatus "Inspecting install folder..."
        $run = Invoke-MoleRea -Invocation $invocation -Arguments @("inspect-desktop-application", $target.Path, "--detail", "complete")
        if ($run.ExitCode -eq 0) { $desktop = $run.Data } else { $errors += "Folder inspection failed: $($run.Error)" }
    }

    $exe = $target.MainExecutable
    if ($exe -and $exe -match '\.(exe|dll|sys)$') {
        Write-InspectStatus "Reading code signature of $(Split-Path -Leaf $exe)..."
        $run = Invoke-MoleRea -Invocation $invocation -Arguments @("inspect-pe-certificates", $exe)
        if ($run.ExitCode -eq 0) { $certificates = $run.Data } else { $errors += "Signature check failed: $($run.Error)" }

        $isDotnet = $desktop -and @($desktop.normalized_result.candidates | Where-Object { $_ -and $_.family -eq "dotnet" }).Count -gt 0
        if ($Deep) {
            Write-InspectStatus "Reading imported DLLs..."
            $run = Invoke-MoleRea -Invocation $invocation -Arguments @("inspect-pe-imports", $exe)
            if ($run.ExitCode -eq 0) { $imports = $run.Data } else { $errors += "Import listing failed: $($run.Error)" }
        }
        if ($Deep -or $isDotnet) {
            $run = Invoke-MoleRea -Invocation $invocation -Arguments @("inspect-managed-artifact", $exe)
            # A native image is not an error: it simply has no .NET metadata.
            if ($run.ExitCode -eq 0 -and $run.Data.normalized_result.classification.status -eq "managed") { $managed = $run.Data }
        }
    }
    elseif (-not $exe) {
        $errors += "No main executable found; signature not checked"
    }

    $summary = ConvertTo-MoleInspectSummary -Target $target -Desktop $desktop -Certificates $certificates -Imports $imports -Managed $managed -Errors $errors
    if ($Json) {
        $summary | ConvertTo-Json -Depth 6
    }
    else {
        Show-InspectSummary -Summary $summary
    }

    if ($null -eq $desktop -and $null -eq $certificates) { exit 1 }
}

Main
