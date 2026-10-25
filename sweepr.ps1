#!/usr/bin/env pwsh
# Sweepr - Windows System Maintenance Toolkit
# Main CLI entry point

#Requires -Version 5.1
param(
    [Parameter(Position = 0)]
    [string]$Command,

    [Parameter(Position = 1, ValueFromRemainingArguments)]
    [string[]]$CommandArgs,

    [Alias('v')]
    [switch]$Version,
    
    [Alias('h')]
    [switch]$ShowHelp
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# The installed .cmd launcher uses -File, which binds --debug as PowerShell's
# common parameter instead of leaving it in CommandArgs for the child command.
if ($PSBoundParameters.ContainsKey('Debug') -and $PSBoundParameters['Debug']) {
    if ($null -eq $CommandArgs) { $CommandArgs = @('--debug') }
    else { $CommandArgs += '--debug' }
    $DebugPreference = 'SilentlyContinue'
}

# Get script directory
$script:SWEEPR_ROOT = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:SWEEPR_BIN = Join-Path $script:SWEEPR_ROOT "bin"
$script:SWEEPR_LIB = Join-Path $script:SWEEPR_ROOT "lib"
$script:SWEEPR_CORE = Join-Path $script:SWEEPR_LIB "core"

# Read the version before loading the rest of the runtime so every entrypoint
# resolves the same release tag.
. "$script:SWEEPR_CORE\version.ps1"
Repair-SweeprModulePath
$script:SWEEPR_VER = Get-SweeprVersionString -RootDir $script:SWEEPR_ROOT

# Import core
. "$script:SWEEPR_LIB\core\common.ps1"
. "$script:SWEEPR_LIB\core\update_check.ps1"

# ============================================================================
# Version Info
# ============================================================================

function Show-Version {
    $info = Get-SweeprVersion
    $windows = Get-WindowsVersion
    Write-Host "Sweepr version $($info.Version)"
    Write-Host "Windows: $($windows.Name) $($windows.Version)"
    Write-Host "Architecture: $(Get-NativeArchitecture)"
    Write-Host "PowerShell: $($info.PowerShell)"
    Write-Host "Disk Free: $(Get-FreeSpace)"
    Write-Host "Install: $(Get-SweeprInstallDescription -RootDir $script:SWEEPR_ROOT)"
}

# The machine's own architecture. An x64 process on ARM64 Windows (sw.exe
# runs PowerShell under emulation) sees AMD64 in its environment, so read the
# system-wide value Windows keeps in the registry.
function Get-NativeArchitecture {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
    $native = (Get-ItemProperty -Path $key -Name PROCESSOR_ARCHITECTURE -ErrorAction SilentlyContinue).PROCESSOR_ARCHITECTURE
    if ($native) {
        return $native
    }
    return $env:PROCESSOR_ARCHITECTURE
}

# The facts a --debug session log opens with. No user or machine name.
function Get-SweeprDebugHeader {
    param([string]$CommandLine)

    $lines = @("Sweepr Debug Session, $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')", "Command: sw $CommandLine")
    try {
        $info = Get-SweeprVersion
        $windows = Get-WindowsVersion
        $lines += "Sweepr version: $($info.Version)"
        $lines += "Windows: $($windows.Name) $($windows.Version)"
        $lines += "Architecture: $(Get-NativeArchitecture)"
        $lines += "PowerShell: $($info.PowerShell) $($PSVersionTable.PSEdition)"
        $lines += "Install: $(Get-SweeprInstallDescription -RootDir $script:SWEEPR_ROOT)"
    }
    catch { $lines += "Environment: unavailable" }
    return $lines
}

# A source install checks out a release tag; naming its commit tells a report
# exactly which source ran. Read from .git without starting git.
function Get-SweeprSourceCommit {
    param([string]$RootDir)

    $gitDir = Join-Path $RootDir ".git"
    try {
        $head = ([System.IO.File]::ReadAllText((Join-Path $gitDir "HEAD"))).Trim()
        if ($head -match '^ref: (refs/\S+)$') {
            $ref = $Matches[1]
            $loose = Join-Path $gitDir ($ref -replace '/', '\')
            $head = $null
            if (Test-Path -LiteralPath $loose -PathType Leaf) {
                $head = ([System.IO.File]::ReadAllText($loose)).Trim()
            }
            else {
                $packed = Join-Path $gitDir "packed-refs"
                if (Test-Path -LiteralPath $packed -PathType Leaf) {
                    foreach ($line in [System.IO.File]::ReadAllLines($packed)) {
                        if ($line -match "^([0-9a-f]{40}) $([regex]::Escape($ref))$") { $head = $Matches[1]; break }
                    }
                }
            }
        }
        if ($head -match '^[0-9a-f]{40}$') { return $head.Substring(0, 7) }
    }
    catch { } # A worktree link or unreadable metadata just leaves the commit out.
    return $null
}

function Get-SweeprInstallDescription {
    param([string]$RootDir)

    $method = Get-SweeprInstallMethod -RootDir $RootDir
    if ($method -eq "Source") {
        $commit = Get-SweeprSourceCommit -RootDir $RootDir
        if ($commit) { return "Source ($commit)" }
    }
    return $method
}

# How this copy was installed, by the folder each channel installs into.
function Get-SweeprInstallMethod {
    param([string]$RootDir)

    if (Test-SweeprPortable -RootDir $RootDir) { return "Portable" }
    $path = $RootDir.TrimEnd('\') + '\'
    if ($path -like "*\Microsoft\WinGet\Packages\brummilab.Sweepr_*") { return "winget" }
    if ($path -like "*\scoop\apps\sweepr\*") { return "Scoop" }
    if (Test-Path -LiteralPath (Join-Path $RootDir ".git")) { return "Source" }
    return "Copy"
}

# ============================================================================
# Help
# ============================================================================

function Show-MainHelp {
    $blue = $script:Colors.Blue
    $green = $script:Colors.Green
    $nc = $script:Colors.NC

    function Write-HelpRow([string]$Usage, [string]$Description) {
        Write-Host ("  {0}{1,-28}{2} {3}" -f $green, $Usage, $nc, $Description)
    }

    Show-Banner
    Write-Host "${blue}COMMANDS${nc}"
    Write-HelpRow "sw" "Main menu"
    Write-HelpRow "sw clean" "Free up disk space"
    Write-HelpRow "sw uninstall" "Remove apps completely"
    Write-HelpRow "sw features" "Remove preinstalled apps and Windows features"
    Write-HelpRow "sw optimize" "Refresh caches and services"
    Write-HelpRow "sw analyze" "Explore disk usage"
    Write-HelpRow "sw status" "Monitor system health"
    Write-HelpRow "sw purge" "Remove old project artifacts"
    Write-HelpRow "sw inspect <app>" "Look inside an app with REA (read-only)"
    Write-HelpRow "sw history" "Review cleanup activity"
    Write-HelpRow "sw update" "Update to latest version"
    Write-HelpRow "sw remove" "Remove Sweepr from system"
    Write-HelpRow "sw --help" "Show help"
    Write-HelpRow "sw --version" "Show version"
    Write-Host ""
    Write-HelpRow "sw clean --dry-run" "Preview cleanup"
    Write-HelpRow "sw clean --whitelist" "Manage protected paths"
    Write-HelpRow "sw clean --system" "Include system cleanup (run as administrator)"
    Write-HelpRow "sw optimize --dry-run" "Preview optimization"
    Write-HelpRow "sw uninstall --dry-run" "Preview app uninstall"
    Write-HelpRow "sw features --dry-run" "Preview what would be removed"
    Write-HelpRow "sw features --restore" "Bring back apps and features removed earlier"
    Write-HelpRow "sw purge --dry-run" "Preview project purge"
    Write-HelpRow "sw purge --paths" "Configure scan directories"
    Write-HelpRow "sw history --json" "Export cleanup history"
    Write-HelpRow "sw analyze D:\" "Analyze another drive"
    Write-HelpRow "sw inspect Slack --deep" "Runtime, signer, DLLs and .NET metadata"
    Write-HelpRow "sw inspect --setup" "Register REA with MCP clients"
    Write-Host ""
    Write-Host "${blue}OPTIONS${nc}"
    Write-HelpRow "--debug" "Show detailed operation logs"
    Write-Host ""
}

# ============================================================================
# Interactive Menu
# ============================================================================

# The main menu: five numbered commands, arrow keys or 1-5,
# M for the full help, V for the version, Q to quit. Returns a command name,
# "help", "version" or $null.
function Show-MainMenu {
    param($UpdateContext = $null)
    $items = @(
        @{ Command = "clean"; Label = "Clean        Free up disk space" },
        @{ Command = "uninstall"; Label = "Uninstall    Remove apps completely" },
        @{ Command = "optimize"; Label = "Optimize     Refresh caches and services" },
        @{ Command = "analyze"; Label = "Analyze      Explore disk usage" },
        @{ Command = "status"; Label = "Status       Monitor system health" }
    )
    $cyan = $script:Colors.Cyan
    $gray = $script:Colors.Gray
    $nc = $script:Colors.NC
    $esc = [char]27
    $controls = "${gray}$([char]0x2191)$([char]0x2193)  |  Enter  |  M More  |  V Version  |  Q Quit${nc}"
    $selected = 0

    Write-Host -NoNewline "$esc[?25l"
    try {
        while ($true) {
            Clear-Host
            Write-Host ""
            Show-Banner
            for ($i = 0; $i -lt $items.Count; $i++) {
                if ($i -eq $selected) {
                    Write-Host "${cyan}$($script:Icons.Arrow) $($i + 1). $($items[$i].Label)${nc}"
                }
                else {
                    Write-Host "  $($i + 1). $($items[$i].Label)"
                }
            }
            Write-Host ""
            Write-Host $controls
            Show-SweeprUpdateNotice -Context $UpdateContext

            $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            switch ($key.VirtualKeyCode) {
                38 { if ($selected -gt 0) { $selected-- } }
                40 { if ($selected -lt $items.Count - 1) { $selected++ } }
                13 { return $items[$selected].Command }
                27 { return $null }
            }
            $char = [string]$key.Character
            if ($char -match '^[1-5]$') {
                return $items[[int]$char - 1].Command
            }
            switch ($char.ToLowerInvariant()) {
                'k' { if ($selected -gt 0) { $selected-- } }
                'j' { if ($selected -lt $items.Count - 1) { $selected++ } }
                'm' { return "help" }
                'v' { return "version" }
                'q' { return $null }
            }
        }
    }
    finally {
        Write-Host -NoNewline "$esc[?25h"
    }
}

# ============================================================================
# Command Router
# ============================================================================

# Maps a command-line flag (dry-run, help, h) to the parameter its command
# script declares. A flag nothing declares is refused rather than passed on:
# scripts without [CmdletBinding()] ignore unknown parameters, so
# `sw remove --help` used to uninstall Sweepr.
function Resolve-CommandParameterName {
    param(
        $Parameters,
        [string]$Flag
    )

    $common = @([System.Management.Automation.PSCmdlet]::CommonParameters) +
        @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
    foreach ($parameter in $Parameters.Values) {
        if ($common -contains $parameter.Name) {
            continue
        }
        if ($parameter.Name -eq $Flag -or $parameter.Aliases -contains $Flag) {
            return $parameter.Name
        }
    }

    # --help and --debug are spelled the same for every command.
    $synonyms = @{ "help" = "ShowHelp"; "debug" = "DebugMode" }
    if ($synonyms.ContainsKey($Flag)) {
        foreach ($parameter in $Parameters.Values) {
            if ($parameter.Name -eq $synonyms[$Flag]) {
                return $parameter.Name
            }
        }
    }
    return $null
}

function Invoke-SweeprCommand {
    param(
        [string]$CommandName,
        [string[]]$Arguments
    )

    $scriptPath = Join-Path $script:SWEEPR_BIN "$CommandName.ps1"

    if (-not (Test-Path $scriptPath)) {
        $script:SweeprExitCode = 2
        Write-SweeprError "Unknown command: $CommandName"
        Write-Host ""
        Write-Host "Run 'sw --help' for available commands"
        return
    }

    # A previous native command must not make a help-only invocation fail.
    if ($CommandName -in @("analyze", "status", "history", "inspect", "features")) { $global:LASTEXITCODE = 0 }

    # Execute the command script with arguments using splatting
    # This properly handles switch parameters passed as strings
    $argCount = if ($null -eq $Arguments) { 0 } else { @($Arguments).Count }
    $splatParams = @{}
    $positionalArgs = @()
    if ($argCount -gt 0) {
        $declared = (Get-Command -Name $scriptPath -CommandType ExternalScript).Parameters

        $argList = @($Arguments)
        for ($index = 0; $index -lt $argList.Count; $index++) {
            # Shell parsing already removed syntactic quotes. Literal quote
            # characters belong to the argument and must be preserved.
            $cleanArg = $argList[$index]

            if ($cleanArg -match '^-{1,2}([\w-]+)$') {
                # A switch (--dry-run), or a flag that takes the next word as
                # its value (--interval 1s), as the command declares it.
                $paramName = Resolve-CommandParameterName -Parameters $declared -Flag $Matches[1]
                if (-not $paramName) {
                    Write-SweeprError "Unknown option for sw ${CommandName}: $cleanArg"
                    Write-Host "Run 'sw $CommandName --help' to see its options"
                    $script:SweeprExitCode = 2
                    return
                }
                $takesValue = $declared[$paramName].ParameterType -ne [System.Management.Automation.SwitchParameter]
                $next = $index + 1
                if ($takesValue -and $next -lt $argList.Count -and [string]$argList[$next] -notmatch '^-{1,2}[A-Za-z]') {
                    $splatParams[$paramName] = $argList[$next]
                    $index = $next
                }
                else {
                    $splatParams[$paramName] = $true
                }
            }
            elseif ($cleanArg -match '^-{1,2}([\w-]+)[=:](.+)$') {
                # It's a named parameter with value (e.g., --name=value)
                $paramName = Resolve-CommandParameterName -Parameters $declared -Flag $Matches[1]
                if (-not $paramName) {
                    Write-SweeprError "Unknown option for sw ${CommandName}: $cleanArg"
                    Write-Host "Run 'sw $CommandName --help' to see its options"
                    $script:SweeprExitCode = 2
                    return
                }
                $paramValue = $Matches[2]
                $splatParams[$paramName] = $paramValue
            }
            else {
                # Positional argument
                $positionalArgs += $cleanArg
            }
        }
    }

    # The operation log reads the run from the environment in the command's own scope.
    $env:_SWEEPR_OPLOG_RUN_COMMAND = $CommandName
    $env:_SWEEPR_OPLOG_RUN_ID = "{0}-{1}-{2}" -f (Get-Date -Format "yyyyMMddHHmmss"), $PID, (Get-Random -Maximum 100000)

    # The command script loads the log module afresh, so the session has to
    # exist before it starts for its own debug lines to reach the file.
    $debugSession = $splatParams.ContainsKey("DebugMode")
    if ($debugSession) {
        Start-SweeprDebugSession -Header (Get-SweeprDebugHeader -CommandLine ((@($CommandName) + @($Arguments)) -join " "))
    }
    try {
        if ($positionalArgs.Count -gt 0) {
            & $scriptPath @splatParams @positionalArgs
        }
        else {
            & $scriptPath @splatParams
        }
    }
    finally {
        if ($debugSession) { Complete-SweeprDebugSession }
    }
    if ($CommandName -in @("analyze", "status", "history", "inspect", "features")) {
        $script:SweeprExitCode = $LASTEXITCODE
    }
}

# ============================================================================
# Main
# ============================================================================

# Where Sweepr keeps its own files is decided once in base.ps1 (Config). Here the
# decision is handed to child processes and checked before any command runs.
function Initialize-SweeprDataDir {
    $paths = Resolve-SweeprDataPaths -RootDir $script:SWEEPR_ROOT
    if ($paths.Mode -eq 'Portable') {
        # Command scripts and the Go tools read this variable at start-up.
        $env:SWEEPR_DATA_DIR = Join-Path $script:SWEEPR_ROOT 'data'
    }
    elseif ($paths.Mode -eq 'Override') {
        # Children get the absolute, trimmed form so every tool lands in the same folder.
        $env:SWEEPR_DATA_DIR = Split-Path -Parent $paths.ConfigPath
    }
    if ($paths.Mode -ne 'Profile') {
        Assert-SweeprDataWritable -Path $paths.ConfigPath
        Assert-SweeprDataWritable -Path $paths.CachePath
    }
}

function Main {
    # Check the data folder first: Initialize-Sweepr creates the config and cache
    # folders, and a read-only portable stick must fail with the clear message.
    Initialize-SweeprDataDir

    # Initialize
    Initialize-Sweepr

    # Native -File and the executable launcher bind switches differently.
    # Normalize both forms before routing, keeping command options on the child.
    $effectiveShowHelp = $ShowHelp
    $effectiveVersion = $Version
    $effectiveCommand = $Command
    $effectiveArguments = @()
    if ($null -ne $CommandArgs) { $effectiveArguments = @($CommandArgs) }
    if (-not $effectiveCommand -and $effectiveArguments.Count -gt 0) {
        $effectiveCommand = $effectiveArguments[0]
        if ($effectiveArguments.Count -gt 1) {
            $effectiveArguments = @($effectiveArguments[1..($effectiveArguments.Count - 1)])
        }
        else {
            $effectiveArguments = @()
        }
    }
    if ($effectiveCommand) {
        if ($effectiveShowHelp) {
            $effectiveArguments += "--help"
            $effectiveShowHelp = $false
        }
        if ($effectiveVersion) {
            $effectiveArguments += "--version"
            $effectiveVersion = $false
        }
    }

    if ($effectiveCommand -match '^-{1,2}(.+)$') {
        $switchName = $Matches[1].ToLower()
        switch ($switchName) {
            'showhelp' { $effectiveShowHelp = $true; $effectiveCommand = $null }
            'help' { $effectiveShowHelp = $true; $effectiveCommand = $null }
            'h' { $effectiveShowHelp = $true; $effectiveCommand = $null }
            'version' { $effectiveVersion = $true; $effectiveCommand = $null }
            'v' { $effectiveVersion = $true; $effectiveCommand = $null }
        }
    }

    # Handle version flag
    if ($effectiveVersion) {
        Show-Version
        return
    }

    # Handle help flag
    if ($effectiveShowHelp -and -not $effectiveCommand) {
        Show-MainHelp
        return
    }

    # If command specified, route to it
    $updateContext = $null
    if (Test-SweeprUpdateNoticeAllowed -CommandName $effectiveCommand -Arguments $effectiveArguments) {
        $updateContext = Start-SweeprUpdateCheck -RootDir $script:SWEEPR_ROOT -Version $script:SWEEPR_VER -Method (Get-SweeprInstallMethod -RootDir $script:SWEEPR_ROOT)
    }
    if ($effectiveCommand) {
        $validCommands = @("clean", "uninstall", "analyze", "status", "optimize", "purge", "inspect", "history", "features", "update", "remove")

        if ($effectiveCommand -in $validCommands) {
            Invoke-SweeprCommand -CommandName $effectiveCommand -Arguments $effectiveArguments
            if ($script:SweeprExitCode -eq 0) { Show-SweeprUpdateNotice -Context $updateContext }
        }
        else {
            $script:SweeprExitCode = 2
            Write-SweeprError "Unknown command: $effectiveCommand"
            Write-Host ""
            Write-Host "Available commands: $($validCommands -join ', ')"
            Write-Host "Run 'sw --help' for more information"
        }
        return
    }

    # Interactive mode: pick once, run it, return to the shell.
    $choice = Show-MainMenu -UpdateContext $updateContext
    Clear-Host
    if ($null -eq $choice) {
        return
    }
    if ($choice -eq "help") {
        Show-MainHelp
    }
    elseif ($choice -eq "version") {
        Show-Version
    }
    else {
        Invoke-SweeprCommand -CommandName $choice -Arguments @()
        if ($script:SweeprExitCode -eq 0) { Show-SweeprUpdateNotice -Context $updateContext }
    }
}

# Run
$script:SweeprExitCode = 0
try {
    Main
}
catch {
    Write-Host ""
    if ($_.Exception.Message -like 'Sweepr data folder is not writable:*') {
        Write-SweeprError $_.Exception.Message
    }
    else {
        Write-SweeprError "An error occurred: $_"
    }
    Write-Host ""
    exit 1
}
if ($script:SweeprExitCode -ne 0) {
    exit $script:SweeprExitCode
}
