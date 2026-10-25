# Sweepr - Logging Module
# Provides consistent logging functions with colors and icons

#Requires -Version 5.1
Set-StrictMode -Version Latest

# Prevent multiple sourcing
if ((Get-Variable -Name 'SWEEPR_LOG_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:SWEEPR_LOG_LOADED) { return }
$script:SWEEPR_LOG_LOADED = $true

# Import base module
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\base.ps1"
Initialize-SweeprVisualDefaults

# ============================================================================
# Log Configuration
# ============================================================================

# --debug keeps one session log a reporter can send. It sits with the CLI's
# own config, not in %LOCALAPPDATA%\Sweepr, which is reserved for app data.
# log.ps1 can be loaded alone; without a Config it falls back to the profile.
$script:SweeprLogDir = "$env:USERPROFILE\.config\sweepr"
if ((Get-Variable -Name 'Config' -Scope Script -ErrorAction SilentlyContinue) -and ($script:Config -is [System.Collections.IDictionary]) -and $script:Config['ConfigPath']) {
    $script:SweeprLogDir = [string]$script:Config['ConfigPath']
}
$script:SweeprDebugLogFile = Join-Path $script:SweeprLogDir 'sweepr_debug_session.log'

# Each command script loads this module afresh after the router has set
# SWEEPR_DEBUG, so the switch has to be read here, at load time.
$script:LogConfig = @{
    DebugEnabled = $env:SWEEPR_DEBUG -eq "1"
    LogFile      = $(if ($env:SWEEPR_DEBUG -eq "1") { $script:SweeprDebugLogFile } else { $null })
    Verbose      = $false
}

# What clean, purge, optimize and uninstall actually removed, one line per
# item in operations.log, so a report can carry it.
# Dry runs write nothing; SWEEPR_NO_OPLOG=1 turns it off.
$script:SweeprOperationsLogFile = Join-Path $script:SweeprLogDir 'operations.log'
$script:SweeprOperationsLogMaxBytes = 5MB
$script:SweeprOperationsLogStarted = $false

function ConvertTo-SweeprLogValue {
    param([string]$Value)

    # Control characters become escapes so a file name cannot forge a record.
    # Backslashes stay literal: Windows paths are full of them.
    return [regex]::Replace([string]$Value, '[\x00-\x1f\x7f]', {
            param($match)
            switch ([int][char]$match.Value) {
                9 { '\t' }
                10 { '\n' }
                13 { '\r' }
                default { '\x{0:x2}' -f [int][char]$match.Value }
            }
        })
}

function Write-SweeprOperation {
    param(
        [string]$Action,
        [string]$Path,
        [string]$Detail = ""
    )

    if ($env:SWEEPR_NO_OPLOG -eq "1" -or [string]::IsNullOrEmpty($Path)) { return }

    try {
        $command = if ($env:_SWEEPR_OPLOG_RUN_COMMAND) { $env:_SWEEPR_OPLOG_RUN_COMMAND } else { "sweepr" }
        $label = if ($env:_SWEEPR_OPLOG_RUN_ID) { "$command run=$($env:_SWEEPR_OPLOG_RUN_ID)" } else { $command }
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        # Every record ends in one parenthesis-free "(detail)", so a reader can split
        # it from a path that holds parentheses, such as "Program Files (x86)".
        $safeDetail = if ($Detail) { (ConvertTo-SweeprLogValue $Detail).Replace("(", "[").Replace(")", "]") } else { "-" }
        $line = "[$timestamp] [$label] $Action $(ConvertTo-SweeprLogValue $Path) ($safeDetail)"
        $file = $script:SweeprOperationsLogFile
        $text = "$line`r`n"
        if (-not $script:SweeprOperationsLogStarted) {
            $dir = Split-Path -Parent $file
            if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
            $info = New-Object System.IO.FileInfo $file
            if ($info.Exists -and $info.Length -gt $script:SweeprOperationsLogMaxBytes) {
                Move-Item -LiteralPath $file -Destination "$file.old" -Force
            }
            # The marker is written with the first record, so a run that removes
            # nothing leaves the log untouched.
            $text = "`r`n# ========== $label session started at $timestamp ==========`r`n$text"
        }
        Add-SweeprOperationText -File $file -Text $text
        $script:SweeprOperationsLogStarted = $true
    }
    catch {
        # The record must never fail the removal it describes, but --debug says it was lost.
        Write-Debug "operations.log not written: $($_.Exception.Message)"
    }
}

# Another Sweepr run (or sw analyze) may hold the file for the moment it appends,
# so a sharing violation is retried briefly instead of dropping the line.
function Add-SweeprOperationText {
    param([string]$File, [string]$Text)

    $encoding = New-Object System.Text.UTF8Encoding $false
    $attempts = 5
    for ($attempt = 1; ; $attempt++) {
        try {
            [System.IO.File]::AppendAllText($File, $Text, $encoding)
            return
        }
        catch [System.IO.IOException] {
            if ($attempt -ge $attempts) { throw }
            Start-Sleep -Milliseconds (20 * $attempt)
        }
    }
}

function Add-SweeprLogLine {
    param([string]$Line)

    $path = $script:LogConfig.LogFile
    if (-not $path) { return }
    try {
        [System.IO.File]::AppendAllText($path, "$Line`r`n", (New-Object System.Text.UTF8Encoding $false))
    }
    catch { } # A log that cannot be written must not stop maintenance.
}

# ============================================================================
# Core Logging Functions
# ============================================================================

function Write-LogMessage {
    <#
    .SYNOPSIS
        Internal function to write formatted log message
    #>
    param(
        [string]$Message,
        [string]$Level,
        [string]$Color,
        [string]$Icon
    )

    $timestamp = Get-Date -Format "HH:mm:ss"
    $colorCode = Get-SweeprColor -Name $Color
    $nc = Get-SweeprColor -Name "NC"

    $formattedIcon = if ($Icon) { "$Icon " } else { "" }
    $output = "  ${colorCode}${formattedIcon}${nc}${Message}"

    Stop-Spinner
    Write-Host $output
    if ($script:CurrentSection.Active) { Start-Spinner }

    Add-SweeprLogLine "$timestamp [$Level] $Message"
}

function Write-Info {
    <#
    .SYNOPSIS
        Write an informational message
    #>
    param([string]$Message)
    Write-LogMessage -Message $Message -Level "INFO" -Color "Cyan" -Icon (Get-SweeprIcon -Name "List")
}

function Write-Success {
    <#
    .SYNOPSIS
        Write a success message
    #>
    param([string]$Message)
    Write-LogMessage -Message $Message -Level "SUCCESS" -Color "Green" -Icon (Get-SweeprIcon -Name "Success")
}


function Write-SweeprWarning {
    <#
    .SYNOPSIS
        Write a warning message
    #>
    param([string]$Message)
    Write-LogMessage -Message $Message -Level "WARN" -Color "Yellow" -Icon (Get-SweeprIcon -Name "Warning")
}

function Write-SweeprError {
    <#
    .SYNOPSIS
        Write an error message
    #>
    param([string]$Message)
    Write-LogMessage -Message $Message -Level "ERROR" -Color "Red" -Icon (Get-SweeprIcon -Name "Error")
}


# A diagnostic line, not a result. Both launchers start a child PowerShell
# whose host lines land in its stdout, so with stdout redirected
# (`sw uninstall --list --debug | ConvertFrom-Json`, `$out = sw ...`) they
# would corrupt the data a caller reads. Send them to stderr then; a console
# keeps the usual host output.
function Write-SweeprDiagnosticLine {
    param([string]$Message = "")

    $redirected = $false
    try { $redirected = [Console]::IsOutputRedirected } catch { }
    if ($redirected) { [Console]::Error.WriteLine($Message) }
    else { Write-Host $Message }
}

function Write-Debug {
    <#
    .SYNOPSIS
        Write a debug message (only if debug mode is enabled)
    #>
    param([string]$Message)

    if ($script:LogConfig.DebugEnabled) {
        $gray = Get-SweeprColor -Name "Gray"
        $nc = Get-SweeprColor -Name "NC"
        Stop-Spinner
        Write-SweeprDiagnosticLine "  ${gray}[DEBUG] $Message${nc}"
        if ($script:CurrentSection.Active) { Start-Spinner }
        Add-SweeprLogLine "$(Get-Date -Format 'HH:mm:ss') [DEBUG] $Message"
    }
}

function Write-DryRun {
    <#
    .SYNOPSIS
        Write a dry-run message (action that would be taken)
    #>
    param([string]$Message)
    Write-LogMessage -Message $Message -Level "DRYRUN" -Color "Yellow" -Icon (Get-SweeprIcon -Name "DryRun")
}

# ============================================================================
# Section Functions (for progress indication)
# ============================================================================

$script:CurrentSection = @{
    Active   = $false
    Activity = $false
    Name     = ""
}

function Start-Section {
    <#
    .SYNOPSIS
        Start a new section with a title
    #>
    param([string]$Title)

    Stop-Spinner
    $script:CurrentSection.Active = $true
    $script:CurrentSection.Activity = $false
    $script:CurrentSection.Name = $Title

    $purple = Get-SweeprColor -Name "PurpleBold"
    $nc = Get-SweeprColor -Name "NC"
    $arrow = Get-SweeprIcon -Name "Arrow"

    Write-Host ""
    Write-Host "${purple}${arrow} ${Title}${nc}"
    Start-Spinner
}

function Stop-Section {
    <#
    .SYNOPSIS
        End the current section
    #>
    Stop-Spinner
    if ($script:CurrentSection.Active -and -not $script:CurrentSection.Activity) {
        Write-Success "Nothing to tidy"
    }
    $script:CurrentSection.Active = $false
    Stop-Spinner
}

function Set-SectionActivity {
    <#
    .SYNOPSIS
        Mark that activity occurred in current section
    #>
    if ($script:CurrentSection.Active) {
        $script:CurrentSection.Activity = $true
    }
}

# ============================================================================
# Progress Spinner
# ============================================================================

function Test-SweeprInteractiveOutput {
    try {
        return $Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected -and
            -not [Console]::IsInputRedirected -and $env:TERM -ne 'dumb'
    }
    catch { return $false }
}

function Initialize-SweeprSpinner {
    if ('Sweepr.TerminalSpinner' -as [type]) { return }
    # A CLR timer continues while PowerShell waits on synchronous filesystem work.
    # It never calls PowerShell from a background thread. Stop drains its callback
    # before the foreground writes a row or returns control to the caller.
    Add-Type -TypeDefinition @'
using System;
using System.Threading;
using System.Runtime.InteropServices;
namespace Sweepr {
    public static class TerminalSpinner {
        static readonly object Gate = new object();
        static readonly System.IO.TextWriter OriginalOutput = Console.Out;
        [DllImport("kernel32.dll")]
        static extern IntPtr GetStdHandle(int name);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        static extern bool WriteConsoleW(IntPtr handle, string value, uint length, out uint written, IntPtr reserved);
        static void Write(string value) {
            // Console.Write encodes Braille as '?' on legacy code pages. Keep
            // Unicode at the console boundary without changing the shared code page.
            uint written;
            if (Object.ReferenceEquals(Console.Out, OriginalOutput) &&
                WriteConsoleW(GetStdHandle(-11), value, (uint)value.Length, out written, IntPtr.Zero)) return;
            Console.Write(value); // Redirected handles and explicit Console.SetOut writers.
        }
        // Same wide ranges as Get-TerminalTextWidth: CJK takes two cells, so
        // cutting by UTF-16 length lets a long label wrap and scroll every frame.
        static bool IsWide(int p) {
            return (p >= 0x1100 && p <= 0x115f) || (p >= 0x2329 && p <= 0x232a) ||
                (p >= 0x2e80 && p <= 0xa4cf && p != 0x303f) || (p >= 0xac00 && p <= 0xd7a3) ||
                (p >= 0xf900 && p <= 0xfaff) || (p >= 0xfe10 && p <= 0xfe19) ||
                (p >= 0xfe30 && p <= 0xfe6f) || (p >= 0xff00 && p <= 0xff60) ||
                (p >= 0xffe0 && p <= 0xffe6) || (p >= 0x1f300 && p <= 0x1faff) ||
                (p >= 0x20000 && p <= 0x3fffd);
        }
        public static string Fit(string value, int cells) {
            var builder = new System.Text.StringBuilder();
            int used = 0;
            var elements = System.Globalization.StringInfo.GetTextElementEnumerator(value);
            while (elements.MoveNext()) {
                string element = elements.GetTextElement();
                var category = System.Globalization.CharUnicodeInfo.GetUnicodeCategory(element, 0);
                int width = category == System.Globalization.UnicodeCategory.NonSpacingMark ||
                    category == System.Globalization.UnicodeCategory.EnclosingMark ||
                    category == System.Globalization.UnicodeCategory.Format ||
                    category == System.Globalization.UnicodeCategory.Control ? 0 :
                    IsWide(element.Length > 1 && char.IsSurrogatePair(element[0], element[1]) ? char.ConvertToUtf32(element[0], element[1]) : element[0]) ? 2 : 1;
                if (used + width > cells) break;
                builder.Append(element);
                used += width;
            }
            return builder.ToString();
        }
        static readonly char[] Frames = { '\u2816', '\u2832', '\u2834', '\u2826' };
        static Timer timer;
        static string text;
        static int frame;
        static bool drawn;
        public static void Start(string message) {
            lock (Gate) {
                text = message;
                if (timer != null) return;
                frame = 0;
                timer = new Timer(Draw, null, 80, 80);
            }
        }
        static void Draw(object state) {
            lock (Gate) {
                if (timer == null) return;
                try {
                    int columns = 80;
                    try { columns = Console.WindowWidth; } catch (System.IO.IOException) { }
                    string label = Fit(text, Math.Max(1, columns - 5));
                    Write("\r\x1b[2K  \x1b[34m" + Frames[frame++ % Frames.Length] + "\x1b[0m " + label);
                    drawn = true;
                } catch { /* Losing a terminal must not interrupt maintenance. */ }
            }
        }
        public static void Stop() {
            lock (Gate) {
                if (timer != null) { timer.Dispose(); timer = null; }
                if (drawn) {
                    try { Write("\r\x1b[2K"); } catch { }
                    drawn = false;
                }
            }
        }
    }
}
'@
}

function Start-Spinner {
    param([string]$Message = "Scanning...")
    if (-not (Test-SweeprInteractiveOutput)) { return }
    try {
        Initialize-SweeprSpinner
        # Messages are terminal text, never control sequences supplied by paths.
        $safeMessage = $Message -replace '[\x00-\x1f\x7f]', ' '
        [Sweepr.TerminalSpinner]::Start($safeMessage)
    }
    catch { } # A host without dynamic compilation keeps the normal static output.
}

function Update-Spinner {
    param([string]$Message = "Scanning...")
    Start-Spinner -Message $Message
}

function Stop-Spinner {
    if ('Sweepr.TerminalSpinner' -as [type]) { [Sweepr.TerminalSpinner]::Stop() }
}

function Write-Progress {
    # Match the built-in parameter names used by the application/project scanners.
    param(
        [string]$Activity = "Scanning...",
        [string]$Status = "",
        [int]$PercentComplete = -1,
        [switch]$Completed,
        [int]$Current = 0,
        [int]$Total = 0,
        [string]$Message = "",
        [int]$Width = 30
    )
    if ($Completed) { Stop-Spinner; return }
    $label = if ($Message) { $Message } elseif ($Status) { "$Activity, $Status" } else { $Activity }
    Update-Spinner -Message $label
}

# ============================================================================
# Log File Management
# ============================================================================

function Enable-DebugMode {
    <#
    .SYNOPSIS
        Enable debug logging
    #>
    $env:SWEEPR_DEBUG = "1"
    $script:LogConfig.DebugEnabled = $true
    if (-not $script:LogConfig.LogFile) { $script:LogConfig.LogFile = $script:SweeprDebugLogFile }
}

function Start-SweeprDebugSession {
    <#
    .SYNOPSIS
        Start a fresh --debug session log with the given header lines
    #>
    param([string[]]$Header)

    Enable-DebugMode
    $path = $script:SweeprDebugLogFile
    $gray = Get-SweeprColor -Name "Gray"
    $nc = Get-SweeprColor -Name "NC"
    try {
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $rule = "-" * 70
        $text = (@($rule) + @($Header) + @($rule)) -join "`r`n"
        [System.IO.File]::WriteAllText($path, "$text`r`n", (New-Object System.Text.UTF8Encoding $false))
        Write-SweeprDiagnosticLine "${gray}[DEBUG] Debug logging enabled. Session log: $path${nc}"
    }
    catch {
        $script:LogConfig.LogFile = $null
        Write-SweeprWarning "Debug log not writable: $path"
    }
}

function Complete-SweeprDebugSession {
    <#
    .SYNOPSIS
        Tell the user where the --debug session log was saved
    #>
    if (-not $script:LogConfig.LogFile) { return }
    $gray = Get-SweeprColor -Name "Gray"
    $nc = Get-SweeprColor -Name "NC"
    Write-SweeprDiagnosticLine ""
    Write-SweeprDiagnosticLine "${gray}Debug session log saved to:${nc} $($script:LogConfig.LogFile)"
    Write-SweeprDiagnosticLine ""
}

# ============================================================================
# Exports (functions are available via dot-sourcing)
# ============================================================================
# Functions: Write-Info, Write-Success, Write-Warning, Write-Error, etc.
