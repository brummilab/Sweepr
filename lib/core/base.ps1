# Sweepr - Base Definitions and Utilities
# Core definitions, constants, and basic utility functions used by all modules

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Prevent multiple sourcing
if ((Get-Variable -Name 'SWEEPR_BASE_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:SWEEPR_BASE_LOADED) { return }
$script:SWEEPR_BASE_LOADED = $true

# ============================================================================
# Color Definitions (ANSI escape codes for modern terminals)
# ============================================================================
function Get-SweeprDefaultColors {
    $esc = [char]27
    return @{
        Green      = "$esc[0;32m"
        Blue       = "$esc[0;34m"
        Cyan       = "$esc[0;36m"
        Yellow     = "$esc[0;33m"
        Purple     = "$esc[0;35m"
        PurpleBold = "$esc[1;35m"
        Red        = "$esc[0;31m"
        Gray       = "$esc[0;90m"
        White      = "$esc[0;37m"
        NC         = "$esc[0m"  # No Color / Reset
    }
}

# ============================================================================
# Icon Definitions
# ============================================================================
function Get-SweeprDefaultIcons {
    # Keep this block ASCII-only so Windows PowerShell 5.1 does not
    # mis-parse BOM-less source files and collapse comment lines.
    return @{
        Confirm  = [char]0x25CE  # circle confirm marker
        Admin    = [char]0x2699  # admin/settings marker
        Success  = [char]0x2713  # success check
        Error    = [char]0x263B  # error marker
        Warning  = [char]0x25CF  # warning dot
        Empty    = [char]0x25CB  # empty circle
        Solid    = [char]0x25CF  # solid dot
        List     = [char]0x2022  # list bullet
        Arrow    = [char]0x27A4  # navigation arrow
        DryRun   = [char]0x2192  # dry-run arrow
        NavUp    = [char]0x2191  # up arrow
        NavDown  = [char]0x2193  # down arrow
        Folder   = [char]0x25A0  # folder substitute
        File     = [char]0x25A1  # file substitute
        Trash    = [char]0x2718  # trash substitute
    }
}

$script:DefaultColors = Get-SweeprDefaultColors
$script:DefaultIcons = Get-SweeprDefaultIcons

function Get-OrCreateScriptHashtable {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $existing = Get-Variable -Name $Name -Scope Script -ErrorAction SilentlyContinue
    if ($existing -and $existing.Value -is [hashtable]) {
        return $existing.Value
    }

    $table = @{}
    Set-Variable -Name $Name -Scope Script -Value $table
    return $table
}

function Get-SweeprDefaultHashtable {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Colors', 'Icons')]
        [string]$Name
    )

    $defaultVariable = Get-Variable -Name "Default$Name" -Scope Script -ErrorAction SilentlyContinue
    if ($defaultVariable -and $defaultVariable.Value -is [hashtable]) {
        return $defaultVariable.Value
    }

    switch ($Name) {
        'Colors' { return Get-SweeprDefaultColors }
        'Icons' { return Get-SweeprDefaultIcons }
    }
}

function Initialize-SweeprVisualDefaults {
    $defaultColors = Get-SweeprDefaultHashtable -Name "Colors"
    $colors = Get-OrCreateScriptHashtable -Name "Colors"

    foreach ($entry in $defaultColors.GetEnumerator()) {
        if (-not $colors.ContainsKey($entry.Key)) {
            $colors[$entry.Key] = $entry.Value
        }
    }

    $defaultIcons = Get-SweeprDefaultHashtable -Name "Icons"
    $icons = Get-OrCreateScriptHashtable -Name "Icons"

    foreach ($entry in $defaultIcons.GetEnumerator()) {
        if (-not $icons.ContainsKey($entry.Key)) {
            $icons[$entry.Key] = $entry.Value
        }
    }
}

function Get-SweeprVisualValue {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Colors', 'Icons')]
        [string]$TableName,

        [Parameter(Mandatory)]
        [string]$Key
    )

    $table = Get-OrCreateScriptHashtable -Name $TableName
    if (-not $table.ContainsKey($Key)) {
        $defaults = Get-SweeprDefaultHashtable -Name $TableName
        if ($defaults.ContainsKey($Key)) {
            $table[$Key] = $defaults[$Key]
        }
    }

    if ($table.ContainsKey($Key)) {
        return $table[$Key]
    }

    return $null
}

function Get-SweeprColor {
    param([Parameter(Mandatory)][string]$Name)
    return Get-SweeprVisualValue -TableName "Colors" -Key $Name
}

function Get-SweeprIcon {
    param([Parameter(Mandatory)][string]$Name)
    return Get-SweeprVisualValue -TableName "Icons" -Key $Name
}

Initialize-SweeprVisualDefaults

# ============================================================================
# Global Configuration Constants
# ============================================================================
function Test-SweeprPortable {
    <#
    .SYNOPSIS
        True when the marker file sweepr.portable (a file, not a folder) sits in RootDir
    #>
    param([string]$RootDir)

    if ([string]::IsNullOrWhiteSpace($RootDir)) { return $false }
    # File.Exists is false for a folder and (unlike Join-Path) never throws on an unreachable drive.
    return [System.IO.File]::Exists([System.IO.Path]::Combine($RootDir, 'sweepr.portable'))
}

function Resolve-SweeprDataPaths {
    <#
    .SYNOPSIS
        Decide where Sweepr keeps its own files. Creates nothing.
    .DESCRIPTION
        Order: SWEEPR_DATA_DIR (Override), sweepr.portable marker (Portable), user profile (Profile).
        A relative override is made absolute against the current directory, so PowerShell and the
        Go tools (which read the value from the environment) end up in the same folder.
    #>
    param([string]$RootDir)

    $override = $env:SWEEPR_DATA_DIR
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $override = $override.Trim()
        if (-not [System.IO.Path]::IsPathRooted($override)) {
            $override = Join-Path (Get-Location).ProviderPath $override
        }
        $override = [System.IO.Path]::GetFullPath($override)
        return @{
            Mode       = 'Override'
            ConfigPath = Join-Path $override 'config'
            CachePath  = Join-Path $override 'cache'
        }
    }
    if (Test-SweeprPortable -RootDir $RootDir) {
        return @{
            Mode       = 'Portable'
            ConfigPath = Join-Path $RootDir 'data\config'
            CachePath  = Join-Path $RootDir 'data\cache'
        }
    }
    return @{
        Mode       = 'Profile'
        ConfigPath = "$env:USERPROFILE\.config\sweepr"
        CachePath  = "$env:USERPROFILE\.cache\sweepr"
    }
}

function Assert-SweeprDataWritable {
    <#
    .SYNOPSIS
        Throw unless Path can be created and written to (create folder, write and remove a probe file)
    #>
    param([string]$Path)

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        $probe = Join-Path $Path ('.write-test-' + [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($probe, 'x')
        # Own, just-created single file and not a cleanup target, so no Remove-Safe* here.
        [System.IO.File]::Delete($probe)
    }
    catch {
        throw "Sweepr data folder is not writable: $Path. Sweepr does not fall back to your user profile."
    }
}

# Program folder: two levels above lib\core
$script:SweeprDataPaths = Resolve-SweeprDataPaths -RootDir (Split-Path (Split-Path $PSScriptRoot))

$script:Config = @{
    TempFileAgeDays        = 7       # Temp file retention (days)
    OrphanAgeDays          = 60      # Orphaned data retention (days)
    MaxParallelJobs        = 15      # Parallel job limit
    LogAgeDays             = 7       # Log retention (days)
    CrashReportAgeDays     = 7       # Crash report retention (days)
    MaxIterations          = 100     # Max iterations for scans
    ConfigPath             = $script:SweeprDataPaths.ConfigPath
    CachePath              = $script:SweeprDataPaths.CachePath
    WhitelistFile          = Join-Path $script:SweeprDataPaths.ConfigPath 'whitelist.txt'
}

# ============================================================================
# Default Whitelist Patterns (paths to never clean)
# ============================================================================
$script:DefaultWhitelistPatterns = @(
    "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"     # Windows Explorer cache
    "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"        # User fonts
    "$env:APPDATA\Microsoft\Windows\Recent"            # Recent files (used by shell)
    "$env:USERPROFILE\.vscode\extensions"              # VS Code extensions
    "$env:USERPROFILE\.nuget"                          # NuGet packages
    "$env:USERPROFILE\.cargo"                          # Rust packages
    "$env:USERPROFILE\.rustup"                         # Rust toolchain
    "$env:USERPROFILE\.m2\repository"                  # Maven repository
    "$env:USERPROFILE\.gradle\caches\modules-2\files-*" # Gradle modules
    "$env:USERPROFILE\.ollama\models"                  # Ollama AI models
    "$env:LOCALAPPDATA\JetBrains"                      # JetBrains IDEs
)

# ============================================================================
# Protected System Paths (NEVER touch these)
# ============================================================================
$script:ProtectedPaths = @(
    "C:\Windows"
    "C:\Windows\System32"
    "C:\Windows\SysWOW64"
    "C:\Program Files"
    "C:\Program Files (x86)"
    "C:\Program Files\Windows Defender"
    "C:\Program Files (x86)\Windows Defender"
    "C:\ProgramData\Microsoft\Windows Defender"
    "$env:SYSTEMROOT"
    "$env:WINDIR"
)

$script:ExactProtectedPaths = @(
    "$env:USERPROFILE" # Protect the user profile root without blocking targeted cache cleanup below it.
)

# Path segments no Sweepr command may delete under, wherever they appear: DPAPI
# master keys, the credential vault, certificates and the Start Menu, several of
# which sit right beside real caches under AppData. Matched case-insensitively
# as whole path segments, so "Cryptography" or "MyVault" is not a match.
$script:ProtectedPathSegments = @(
    "Microsoft\Credentials"
    "Microsoft\Protect"
    "Microsoft\Crypto"
    "Microsoft\Vault"
    "Microsoft\SystemCertificates"
    "Microsoft\Windows\Start Menu"
)

# Clean only, enabled by bin/clean.ps1 through $script:SweeprCleanPathGuard: SSH,
# GPG and cloud CLI keys and cached tokens, browser and Electron profile stores
# (sign-ins, site data, open tabs), VS Code's local file history and AI assistant
# transcripts. Purge and uninstall do not use this list, because a project's
# node_modules can hold a package folder named "cookies".
$script:CleanProtectedPathSegments = @(
    ".ssh"
    ".gnupg"
    ".aws"
    ".azure"
    ".kube"
    ".docker"
    "Login Data"
    "Cookies"
    "Web Data"
    "Local Storage"
    "Session Storage"
    "IndexedDB"
    "Sessions"
    "Local Extension Settings"
    "Sync Data"
    "Service Worker\CacheStorage"
    "Adobe\Common\Team Projects Cache"
    "pypoetry\Cache\virtualenvs"
    "User\History"
    ".claude\projects"
    ".claude\file-history"
    ".claude\history.jsonl"
    ".codex\sessions"
    ".codex\archived_sessions"
    ".codex\history.jsonl"
)

if (-not (Get-Variable -Name 'SweeprCleanPathGuard' -Scope Script -ErrorAction SilentlyContinue)) {
    $script:SweeprCleanPathGuard = $false
}

# ============================================================================
# System Utilities
# ============================================================================

function Test-IsAdmin {
    <#
    .SYNOPSIS
        Check if running with administrator privileges
    #>
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FreeSpace {
    <#
    .SYNOPSIS
        Get free disk space on system drive
    .OUTPUTS
        Human-readable string (e.g., "100GB")
    #>
    param([string]$Drive = $env:SystemDrive)
    
    $disk = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='$Drive'" -ErrorAction SilentlyContinue
    if ($disk) {
        return Format-ByteSize -Bytes $disk.FreeSpace
    }
    return "Unknown"
}

function Get-WindowsVersion {
    <#
    .SYNOPSIS
        Get Windows version information
    #>
    try {
        $os = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop
        return @{
            Name    = $os.Caption
            Version = $os.Version
            Build   = $os.BuildNumber
            Arch    = $os.OSArchitecture
        }
    }
    catch {
        $currentVersion = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue
        $fallbackVersion = [System.Environment]::OSVersion.Version

        return @{
            Name    = if ($currentVersion.ProductName) { $currentVersion.ProductName } else { "Windows" }
            Version = if ($currentVersion.DisplayVersion) { $currentVersion.DisplayVersion } elseif ($currentVersion.CurrentVersion) { $currentVersion.CurrentVersion } else { $fallbackVersion.ToString() }
            Build   = if ($currentVersion.CurrentBuildNumber) { $currentVersion.CurrentBuildNumber } else { $fallbackVersion.Build.ToString() }
            Arch    = if ($env:PROCESSOR_ARCHITECTURE) { $env:PROCESSOR_ARCHITECTURE } else { "Unknown" }
        }
    }
}

# ============================================================================
# Path Utilities
# ============================================================================

function Test-PathHasSegment {
    <#
    .SYNOPSIS
        Whether a full path contains one of the segment sequences as whole segments
    #>
    param(
        [string]$NormalizedPath,
        [string[]]$Segments
    )

    foreach ($segment in $Segments) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }
        $needle = "\" + $segment
        if ($NormalizedPath.IndexOf("$needle\", [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $NormalizedPath.EndsWith($needle, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

# Resolve an existing path to the final path the filesystem actually uses.
# Path.GetFullPath already normalizes the tested 8.3 and trailing-dot aliases,
# but a junction or symbolic link can still lead to a different protected tree.
# The handle resolves the final target; the Get-Item fallback covers hosts
# where Add-Type is unavailable. Returns three states:
#   Exists = $false             no such path; callers keep the lexical answer
#   Exists = $true, Path = ...  the path resolved to its final spelling
#   Exists = $true, Path = $null the path exists but cannot be resolved
function Resolve-SweeprExistingPathInfo {
    param([string]$Path)

    $resolved = $null
    try {
        if (-not ('Sweepr.PathAliasResolver' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Sweepr {
    public static class PathAliasResolver {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path, uint length, uint flags);

        public static string Resolve(string path) {
            using (SafeFileHandle handle = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
                if (handle.IsInvalid) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                StringBuilder buffer = new StringBuilder(512);
                uint size = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
                if (size == 0) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                if (size >= buffer.Capacity) {
                    buffer = new StringBuilder((int)size + 1);
                    size = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
                    if (size == 0 || size >= buffer.Capacity) {
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    }
                }
                return buffer.ToString();
            }
        }
    }
}
'@ -ErrorAction Stop
        }
        $resolved = [Sweepr.PathAliasResolver]::Resolve($Path)
    }
    catch {
        $resolved = $null
    }

    if (-not $resolved) {
        try {
            $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            if ($null -ne $item -and $item.FullName) {
                $resolved = $item.FullName
            }
        }
        catch {
            $resolved = $null
        }
    }

    if (-not $resolved) {
        $exists = $false
        try {
            $exists = [System.IO.File]::Exists($Path) -or [System.IO.Directory]::Exists($Path)
        }
        catch {
            $exists = $true
        }
        return @{ Exists = $exists; Path = $null }
    }

    # GetFinalPathNameByHandle returns a \\?\ path; fold it back to the
    # drive-letter shape the protection lists use, UNC shares included.
    if ($resolved.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
        $resolved = '\\' + $resolved.Substring(8)
    }
    elseif ($resolved.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
        $resolved = $resolved.Substring(4)
    }
    return @{ Exists = $true; Path = $resolved }
}

# Each protected entry is compared in both its configured spelling and its
# final filesystem spelling, so a short-name or environment spelling in the
# list still protects the long path a walk yields. Normalized forms are built
# once per distinct entry, not once per candidate.
$script:SweeprProtectedPathFormCache = @{}

function Get-SweeprProtectedPathForms {
    param([string]$Protected)

    if ($script:SweeprProtectedPathFormCache.ContainsKey($Protected)) {
        return $script:SweeprProtectedPathFormCache[$Protected]
    }

    $forms = New-Object System.Collections.Generic.List[string]
    try {
        $forms.Add([System.IO.Path]::GetFullPath($Protected).TrimEnd('\'))
    }
    catch {
    }
    $info = Resolve-SweeprExistingPathInfo -Path $Protected
    if ($info.Exists -and $info.Path) {
        try {
            $canonical = [System.IO.Path]::GetFullPath($info.Path).TrimEnd('\')
            if (-not $forms.Contains($canonical)) {
                $forms.Add($canonical)
            }
        }
        catch {
        }
    }
    $script:SweeprProtectedPathFormCache[$Protected] = $forms.ToArray()
    return $script:SweeprProtectedPathFormCache[$Protected]
}

# Existing lexical list checks, factored out so the typed spelling and the
# resolved final path are judged by exactly the same rules.
function Test-SweeprProtectedPathForm {
    param([string]$NormalizedPath)

    $normalizedPath = $NormalizedPath

    if (Test-PathHasSegment -NormalizedPath $normalizedPath -Segments $script:ProtectedPathSegments) {
        return $true
    }

    if ($script:SweeprCleanPathGuard -and
        (Test-PathHasSegment -NormalizedPath $normalizedPath -Segments $script:CleanProtectedPathSegments)) {
        return $true
    }

    # UWP data stays protected. Only automatic clean may reach the named Teams
    # WebView profile's three disposable leaves; user whitelist rules still win.
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        foreach ($packages in (Get-SweeprProtectedPathForms -Protected (Join-Path $env:LOCALAPPDATA 'Packages'))) {
            if ($normalizedPath -eq $packages -or $normalizedPath.StartsWith($packages + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $relative = $normalizedPath.Substring($packages.Length)
                $teamsCache = '^\\MSTeams_8wekyb3d8bbwe\\LocalCache\\Microsoft\\MSTeams\\EBWebView\\[^\\]+\\(Cache|Code Cache|GPUCache)(\\|$)'
                if (-not $script:SweeprCleanPathGuard -or $relative -notmatch $teamsCache) { return $true }
            }
        }
    }

    foreach ($protected in $script:ExactProtectedPaths) {
        if ([string]::IsNullOrWhiteSpace($protected)) {
            continue
        }

        foreach ($normalizedProtected in (Get-SweeprProtectedPathForms -Protected $protected)) {
            if ($normalizedPath -eq $normalizedProtected) {
                return $true
            }
        }
    }

    foreach ($protected in $script:ProtectedPaths) {
        if ([string]::IsNullOrWhiteSpace($protected)) {
            continue
        }

        foreach ($normalizedProtected in (Get-SweeprProtectedPathForms -Protected $protected)) {
            if ($normalizedPath -eq $normalizedProtected -or
                $normalizedPath.StartsWith("$normalizedProtected\", [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }
    return $false
}

function Test-ProtectedPath {
    <#
    .SYNOPSIS
        Check if a path is protected and should never be modified
    #>
    param([string]$Path, [switch]$AlreadyResolved)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $true
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $normalizedPath = $fullPath.TrimEnd('\')
    }
    catch {
        return $true
    }

    # The typed spelling first, including protected prefixes and segments.
    if (Test-SweeprProtectedPathForm -NormalizedPath $normalizedPath) {
        return $true
    }

    # Test-SafePath judges the typed spelling and its resolved final path
    # separately, so neither call needs a second handle probe here.
    if ($AlreadyResolved) { return $false }

    # Existing aliases (8.3 short names, trailing-dot spellings, reparse
    # points) reach the same tree under a spelling the lexical rules miss.
    $alias = Resolve-SweeprExistingPathInfo -Path $fullPath
    if (-not $alias.Exists) {
        return $false
    }
    if (-not $alias.Path) {
        # A path that exists but cannot be resolved could name any target.
        return $true
    }
    $resolvedPath = $alias.Path.TrimEnd('\')
    if ($resolvedPath -eq $normalizedPath) {
        return $false
    }
    return (Test-SweeprProtectedPathForm -NormalizedPath $resolvedPath)
}

# Decodes the bytes of a user list file (whitelist, purge_paths) to text lines.
# Callers read the file with [System.IO.File]::ReadAllBytes so the decoding is never
# left to the platform default. Windows PowerShell
# 5.1 decodes a file without BOM through the ANSI code page, and Notepad and VS Code
# save UTF-8 without BOM, so the decoding is explicit: a UTF-8 or UTF-16 BOM is
# honoured and stripped, everything else is UTF-8 (a strict decode first; bytes that
# are not valid UTF-8 fall back to the system ANSI code page, the old behaviour).
function ConvertFrom-SweeprListBytes {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)

    $bytes = $Bytes
    $start = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = New-Object System.Text.UTF8Encoding($false, $true)
        $start = 3
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = New-Object System.Text.UnicodeEncoding($false, $false)
        $start = 2
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = New-Object System.Text.UnicodeEncoding($true, $false)
        $start = 2
    }
    else {
        $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    }
    try {
        $text = $encoding.GetString($bytes, $start, $bytes.Length - $start)
    }
    catch [System.Text.DecoderFallbackException] {
        $text = [System.Text.Encoding]::Default.GetString($bytes, $start, $bytes.Length - $start)
    }
    return @($text -split "`r?`n")
}

# Normalizes one line of a user list to the path it means, or returns $null for a
# line that means nothing (blank, comment, empty after unquoting, a variable that
# expands to nothing). Order: trim, comment, enclosing quotes ("Copy as path"),
# trim, "/" to "\", "~" to the profile, %VAR% expansion. An undefined %VAR% stays
# literal, so it matches no real path. A value must never mean more than written:
# an entry whose %VAR% expanded away leaves a relative or root-relative remainder,
# which would match a different place than the user named, so it is dropped.
function ConvertFrom-SweeprListEntry {
    param([AllowNull()][string]$Line)

    if ($null -eq $Line) { return $null }
    $entry = $Line.Trim()
    if (-not $entry -or $entry.StartsWith('#')) { return $null }

    if ($entry.Length -ge 2 -and
        (($entry[0] -eq '"' -and $entry[$entry.Length - 1] -eq '"') -or
        ($entry[0] -eq "'" -and $entry[$entry.Length - 1] -eq "'"))) {
        $entry = $entry.Substring(1, $entry.Length - 2).Trim()
    }
    if (-not $entry) { return $null }

    # A single leading "/" is not a Windows spelling (a path of another platform
    # keeps its separators); anything else is a Windows path typed with "/".
    if (-not ($entry.Length -ge 2 -and $entry[0] -eq '/' -and $entry[1] -ne '/')) {
        $entry = $entry.Replace('/', '\')
    }

    if ($entry -eq '~' -or $entry.StartsWith('~\')) {
        $profileRoot = $env:USERPROFILE
        if ([string]::IsNullOrWhiteSpace($profileRoot)) { return $null }
        $entry = $profileRoot.TrimEnd('\') + $entry.Substring(1)
    }

    if ($entry.IndexOf('%') -ge 0) {
        $expanded = [Environment]::ExpandEnvironmentVariables($entry)
        if ($expanded -ne $entry) {
            $expanded = $expanded.Trim()
            # Only a drive-rooted or UNC result is a path the user can have meant.
            if ($expanded -notmatch '^([A-Za-z]:\\|\\\\[^\\])') { return $null }
            $entry = $expanded
        }
    }
    return $entry
}

function Test-WhitelistPattern {
    param([string]$Path, [string]$Pattern)

    # A copied filesystem path may contain valid literal brackets. Check its
    # spelling first; wildcard interpretation must not revoke that protection.
    $root = $Pattern.TrimEnd('\')
    if ([string]::Equals($Path.TrimEnd('\'), $root, [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($Path -like $Pattern) { return $true }
    return ($root.IndexOfAny([char[]]@('[', '`')) -lt 0) -and ($Path -like ($root + '\*'))
}

# The patterns that protect a path, read once. A caller checking many paths in a
# row (one tree walk) passes this to Test-Whitelisted instead of rereading the
# file for every child. Absence is empty; unreadable protection is unknown and
# retains every target.
function Get-WhitelistState {
    $patterns = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in $script:DefaultWhitelistPatterns) {
        $patterns.Add([Environment]::ExpandEnvironmentVariables($pattern))
    }

    $retainAll = $false
    try {
        $null = Get-Item -LiteralPath $script:Config.WhitelistFile -ErrorAction Stop
        try {
            # Explicit UTF-8 read (BOM aware, see ConvertFrom-SweeprListBytes); a read
            # error is caught below and retains every target.
            $userBytes = [System.IO.File]::ReadAllBytes($script:Config.WhitelistFile)
            $userPatterns = @(ConvertFrom-SweeprListBytes -Bytes $userBytes)
            foreach ($line in $userPatterns) {
                $pattern = ConvertFrom-SweeprListEntry -Line $line
                if ($pattern) { $patterns.Add($pattern) }
            }
        }
        catch {
            Write-Debug "Whitelist unreadable; retaining target"
            $retainAll = $true
        }
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        # Absent is empty.
    }
    catch {
        Write-Debug "Whitelist metadata unavailable; retaining target"
        $retainAll = $true
    }

    # What Test-WhitelistPattern derives from a pattern on every call: its
    # root without a trailing backslash, that root as a directory prefix, and
    # whether -like can match anything beyond that (a wildcard or a backtick,
    # which PowerShell treats as an escape). Without one, the root test already
    # covers an exact match.
    $roots = New-Object System.Collections.Generic.List[string]
    $prefixes = New-Object System.Collections.Generic.List[string]
    $wild = New-Object System.Collections.Generic.List[bool]
    $matchPatterns = New-Object System.Collections.Generic.List[string]
    # The active data folders (config and cache) are protected like a literal
    # whitelist directory, so Sweepr's own whitelist, operation log and caches
    # survive a cleanup target that contains them (e.g. an override below the
    # temp folder). Read at call time; an empty setting protects nothing. These
    # rows are literal: brackets and wildcard characters in the folder name are
    # never interpreted as a pattern.
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($pattern in $patterns) { $rows.Add(@{ Pattern = $pattern; Literal = $false }) }
    foreach ($dataDir in @($script:Config.ConfigPath, $script:Config.CachePath)) {
        if (-not [string]::IsNullOrWhiteSpace($dataDir) -and $dataDir.TrimEnd('\')) {
            $rows.Add(@{ Pattern = $dataDir; Literal = $true })
        }
    }
    foreach ($row in $rows) {
        $pattern = $row.Pattern
        $root = $pattern.TrimEnd('\')
        $matchPatterns.Add($pattern)
        $roots.Add($root)
        $prefixes.Add($root + '\')
        $hasWildcard = (-not $row.Literal) -and ($pattern.IndexOfAny([char[]]@('*', '?', '[', '`')) -ge 0)
        $wild.Add($hasWildcard)
        # A whitelist root that is itself a junction points at a different
        # final spelling. Keep both, so the resolved candidate matches the
        # protection the user wrote for the root.
        if (-not $hasWildcard) {
            $info = Resolve-SweeprExistingPathInfo -Path $root
            if ($info.Exists -and $info.Path) {
                $canonical = $info.Path.TrimEnd('\')
                if (-not [string]::Equals($canonical, $root, [StringComparison]::OrdinalIgnoreCase)) {
                    # All matcher arrays describe the same row, including aliases.
                    $matchPatterns.Add($canonical)
                    $roots.Add($canonical)
                    $prefixes.Add($canonical + '\')
                    $wild.Add($false)
                }
            }
        }
    }
    return @{
        RetainAll = $retainAll
        Patterns  = $matchPatterns.ToArray()
        Roots     = $roots.ToArray()
        Prefixes  = $prefixes.ToArray()
        Wild      = $wild.ToArray()
    }
}

function Test-Whitelisted {
    <#
    .SYNOPSIS
        Check if path matches a whitelist pattern
    #>
    param([string]$Path, $State = $null)

    if ($null -eq $State) { $State = Get-WhitelistState }
    if ($State.RetainAll) { return $true }
    # Same rule as Test-WhitelistPattern, without a call per pattern.
    $trimmed = $Path.TrimEnd('\')
    $roots = $State.Roots
    for ($i = 0; $i -lt $roots.Length; $i++) {
        if ([string]::Equals($trimmed, $roots[$i], [StringComparison]::OrdinalIgnoreCase) -or
            $Path.StartsWith($State.Prefixes[$i], [StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($State.Wild[$i]) {
            # A * / ? entry naming a folder covers what is below it, like a literal one.
            # Bracket and escape syntax stays exact: it is ambiguous with literal names.
            if ($Path -like $State.Patterns[$i]) { return $true }
            if ($roots[$i].IndexOfAny([char[]]@('[', '`')) -lt 0 -and $Path -like ($roots[$i] + '\*')) { return $true }
        }
    }
    return $false
}

function Resolve-SafePath {
    <#
    .SYNOPSIS
        Resolve and validate a path for safe operations
    #>
    param([string]$Path)

    try {
        $resolved = [System.IO.Path]::GetFullPath($Path)
    }
    catch {
        return $null
    }

    # Existing paths resolve to their final spelling so later whitelist and
    # protection checks see the target, not an 8.3 or trailing-dot alias of it.
    # A path that exists but cannot be resolved is refused, never treated as a
    # missing candidate.
    $alias = Resolve-SweeprExistingPathInfo -Path $resolved
    if (-not $alias.Exists) {
        return $resolved
    }
    if (-not $alias.Path) {
        return $null
    }
    return $alias.Path
}

# ============================================================================
# Formatting Utilities
# ============================================================================

function Format-ByteSize {
    <#
    .SYNOPSIS
        Convert bytes to human-readable format
    #>
    param([long]$Bytes)
    
    if ($Bytes -ge 1TB) {
        return "{0:N2}TB" -f ($Bytes / 1TB)
    }
    elseif ($Bytes -ge 1GB) {
        return "{0:N2}GB" -f ($Bytes / 1GB)
    }
    elseif ($Bytes -ge 1MB) {
        return "{0:N1}MB" -f ($Bytes / 1MB)
    }
    elseif ($Bytes -ge 1KB) {
        return "{0:N0}KB" -f ($Bytes / 1KB)
    }
    else {
        return "{0}B" -f $Bytes
    }
}

# ============================================================================
# Environment Detection
# ============================================================================

function Get-ConfigPath {
    <#
    .SYNOPSIS
        Get Sweepr config directory, creating it if needed
    #>
    $path = $script:Config.ConfigPath
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    return $path
}

function Get-CachePath {
    <#
    .SYNOPSIS
        Get Sweepr cache directory, creating it if needed
    #>
    $path = $script:Config.CachePath
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    return $path
}

# ============================================================================
# Exports (functions and variables are available via dot-sourcing)
# ============================================================================
# Variables: Colors, Icons, Config, ProtectedPaths, ExactProtectedPaths, DefaultWhitelistPatterns
# Functions: Test-IsAdmin, Get-FreeSpace, Get-WindowsVersion, etc.
