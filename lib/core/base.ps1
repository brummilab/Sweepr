# Sweepr - base: data folders, system information, colour and icon tables, size format, literal
# quoting, path protection, whitelist, list files and final path resolution
#
# Loaded by dot-sourcing, by the router and by most modules. Loading writes nothing, creates no file or
# folder, starts no process and uses no network; it only defines functions and fills the script
# variables below. A second load in the same scope changes nothing: tables and lists that a caller
# changed stay as they are. Setting $script:SWEEPR_BASE_LOADED to $false makes the next load evaluate
# the data folders, the configuration and the protection lists from the current environment again.
#
# Script variables that callers read or replace (every function reads them at each call, nothing is
# cached): Config (ConfigPath, CachePath, WhitelistFile), Colors, Icons, ProtectedPaths,
# ExactProtectedPaths, DefaultWhitelistPatterns, SweeprCleanPathGuard.
#
# The protection code fails closed: whenever it cannot decide, the path counts as protected.

if ($(try { [bool]$script:SWEEPR_BASE_LOADED } catch { $false })) {
    # Callers rely on these for the rest of their run, also when the tables were already loaded.
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    return
}

# ============================================================================
# Small helpers
# ============================================================================

function Get-SwBaseEnv {
    # Value of an environment variable; an unset variable is an empty string.
    param([string]$Name)
    $value = [System.Environment]::GetEnvironmentVariable($Name)
    if ($null -eq $value) { return '' }
    return [string]$value
}

function Join-SwBasePath {
    # Base plus separator plus Child, as plain text. Unlike Path.Combine it never throws for odd
    # characters, and a base that ends in a separator or is a drive root gives no doubled separator.
    param([string]$Base, [string]$Child)
    return $Base.TrimEnd([char[]]@('\', '/')) + [string][System.IO.Path]::DirectorySeparatorChar + $Child
}

function Join-SwBaseText {
    # Environment value plus a backslash plus Rest. An empty value gives the bare Rest, a relative text
    # that matches no absolute path, instead of a root-relative one that could match something else.
    param([string]$Base, [string]$Rest)
    if ([string]::IsNullOrWhiteSpace($Base)) { return $Rest }
    return $Base.TrimEnd([char[]]@('\', '/')) + '\' + $Rest
}

function Test-SwBaseWindows {
    # The Windows file API exists only on Windows; other hosts only run the tests and the gate.
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

function Get-SwBaseProfileRoot {
    # USERPROFILE, else the profile folder .NET reports for the user, else an empty string.
    $value = Get-SwBaseEnv 'USERPROFILE'
    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    try { $value = [string][System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile) }
    catch { $value = '' }
    if ([string]::IsNullOrWhiteSpace($value)) { return '' }
    return $value
}

# ============================================================================
# Literal quoting
# ============================================================================

function ConvertTo-SwPsLiteral {
    <#
    .SYNOPSIS
        Value as a single-quoted PowerShell literal that parses back to exactly that value.
    .DESCRIPTION
        PowerShell reads the apostrophe and the four typographic single quotes U+2018, U+2019, U+201A
        and U+201B as quotes, so each one is doubled. Nothing else needs escaping inside single
        quotes. $null gives an empty literal. For code handed to a child process.
    #>
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Value)

    if ($null -eq $Value) { $Value = '' }
    foreach ($code in 0x27, 0x2018, 0x2019, 0x201A, 0x201B) {
        $quote = [string][char]$code
        $Value = $Value.Replace($quote, $quote + $quote)
    }
    return "'" + $Value + "'"
}

# ============================================================================
# Colours and icons
# ============================================================================

function Get-SwDefaultColors {
    <#
    .SYNOPSIS
        New table of the ANSI colour sequences. The table does not depend on the terminal.
    #>
    $esc = [string][char]27
    return @{
        Green      = $esc + '[0;32m'
        Blue       = $esc + '[0;34m'
        Cyan       = $esc + '[0;36m'
        Yellow     = $esc + '[0;33m'
        Purple     = $esc + '[0;35m'
        PurpleBold = $esc + '[1;35m'
        Red        = $esc + '[0;31m'
        Gray       = $esc + '[0;90m'
        White      = $esc + '[0;37m'
        NC         = $esc + '[0m'
    }
}

function Get-SwDefaultIcons {
    <#
    .SYNOPSIS
        New table of the symbols, each a single character.
    .DESCRIPTION
        Built from code points: Windows PowerShell 5.1 reads a script without BOM through the legacy
        code page, so a symbol typed into this file would come out wrong.
    #>
    return @{
        Confirm = [string][char]0x25CE
        Admin   = [string][char]0x2699
        Success = [string][char]0x2713
        Error   = [string][char]0x263B
        Warning = [string][char]0x25CF
        Empty   = [string][char]0x25CB
        Solid   = [string][char]0x25CF
        List    = [string][char]0x2022
        NavUp   = [string][char]0x2191
        NavDown = [string][char]0x2193
        Folder  = [string][char]0x25A0
        File    = [string][char]0x25A1
        Trash   = [string][char]0x2718
        Arrow   = [string][char]0x27A4
        DryRun  = [string][char]0x2192
    }
}

function Initialize-SwVisualDefaults {
    <#
    .SYNOPSIS
        Fills the missing keys of the colour and icon tables with the defaults.
    .DESCRIPTION
        Existing values stay. A table that is missing or is not a hashtable is created. Safe to
        repeat, also under strict mode when the variables were removed.
    #>
    try { $colors = $script:Colors } catch { $colors = $null }
    try { $icons = $script:Icons } catch { $icons = $null }
    if ($colors -isnot [hashtable]) { $colors = @{} }
    if ($icons -isnot [hashtable]) { $icons = @{} }

    $defaultColors = Get-SwDefaultColors
    foreach ($key in @($defaultColors.Keys)) {
        if (-not $colors.ContainsKey($key)) { $colors[$key] = $defaultColors[$key] }
    }
    $defaultIcons = Get-SwDefaultIcons
    foreach ($key in @($defaultIcons.Keys)) {
        if (-not $icons.ContainsKey($key)) { $icons[$key] = $defaultIcons[$key] }
    }
    $script:Colors = $colors
    $script:Icons = $icons
}

function Get-SwColor {
    <#
    .SYNOPSIS
        ANSI sequence for a colour name, or $null for an unknown name.
    .DESCRIPTION
        An entry of the table wins, also when it differs from the default. A name that is only
        missing from the table gets its default, which is also stored in the table.
    #>
    param([Parameter(Mandatory = $true, Position = 0)][string]$Name)

    try { $table = $script:Colors } catch { $table = $null }
    if ($table -is [hashtable] -and $table.ContainsKey($Name)) { return $table[$Name] }
    $defaults = Get-SwDefaultColors
    if (-not $defaults.ContainsKey($Name)) { return $null }
    if ($table -is [hashtable]) { $table[$Name] = $defaults[$Name] }
    else { Initialize-SwVisualDefaults }
    return $defaults[$Name]
}

function Get-SwIcon {
    <#
    .SYNOPSIS
        Symbol for an icon name, or $null for an unknown name. Same lookup as Get-SwColor.
    #>
    param([Parameter(Mandatory = $true, Position = 0)][string]$Name)

    try { $table = $script:Icons } catch { $table = $null }
    if ($table -is [hashtable] -and $table.ContainsKey($Name)) { return $table[$Name] }
    $defaults = Get-SwDefaultIcons
    if (-not $defaults.ContainsKey($Name)) { return $null }
    if ($table -is [hashtable]) { $table[$Name] = $defaults[$Name] }
    else { Initialize-SwVisualDefaults }
    return $defaults[$Name]
}

# ============================================================================
# Data folders
# ============================================================================

function Test-SwPortable {
    <#
    .SYNOPSIS
        True when the program folder holds a file named sweepr.portable.
    .DESCRIPTION
        A folder of that name does not count. Never throws, also for a drive that is not there.
    #>
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$RootDir)

    try {
        if ([string]::IsNullOrWhiteSpace($RootDir)) { return $false }
        return [bool][System.IO.File]::Exists([System.IO.Path]::Combine($RootDir, 'sweepr.portable'))
    }
    catch { return $false }
}

function Resolve-SwDataPaths {
    <#
    .SYNOPSIS
        Where the data folders are: Mode (Override, Portable or Profile), ConfigPath and CachePath.
    .DESCRIPTION
        SWEEPR_DATA_DIR wins, then the portable marker in the program folder, then the user profile.
        The paths are plain text: nothing is created or probed, and a drive that is not there causes
        no error here (Assert-SwDataWritable reports it). Portable gives the same paths as an
        override set to <program folder>\data.
    #>
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$RootDir)

    $override = Get-SwBaseEnv 'SWEEPR_DATA_DIR'
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $base = $override.Trim()
        try {
            if (-not [System.IO.Path]::IsPathRooted($base)) {
                $base = [System.IO.Path]::Combine((Get-Location -PSProvider FileSystem).ProviderPath, $base)
            }
            $base = [System.IO.Path]::GetFullPath($base)
        }
        catch {
            # Keep the text as typed; the writability check names it in its message.
            $base = $override.Trim()
        }
        return @{
            Mode       = 'Override'
            ConfigPath = (Join-SwBasePath $base 'config')
            CachePath  = (Join-SwBasePath $base 'cache')
        }
    }

    if (Test-SwPortable -RootDir $RootDir) {
        $base = Join-SwBasePath $RootDir 'data'
        try { $base = [System.IO.Path]::GetFullPath($base) } catch { $null = $_ }
        return @{
            Mode       = 'Portable'
            ConfigPath = (Join-SwBasePath $base 'config')
            CachePath  = (Join-SwBasePath $base 'cache')
        }
    }

    $profileRoot = Get-SwBaseProfileRoot
    if ([string]::IsNullOrWhiteSpace($profileRoot)) {
        # No profile known: leave the paths empty rather than point at the root of the current drive.
        return @{ Mode = 'Profile'; ConfigPath = ''; CachePath = '' }
    }
    return @{
        Mode       = 'Profile'
        ConfigPath = (Join-SwBasePath (Join-SwBasePath $profileRoot '.config') 'sweepr')
        CachePath  = (Join-SwBasePath (Join-SwBasePath $profileRoot '.cache') 'sweepr')
    }
}

function New-SwBaseConfig {
    # The program folder is two levels above this file (<program folder>\lib\core\base.ps1); the
    # working directory plays no part.
    $programRoot = ''
    if (-not [string]::IsNullOrEmpty($PSScriptRoot)) {
        $lib = [System.IO.Path]::GetDirectoryName($PSScriptRoot)
        if (-not [string]::IsNullOrEmpty($lib)) { $programRoot = [string][System.IO.Path]::GetDirectoryName($lib) }
    }
    $paths = Resolve-SwDataPaths -RootDir $programRoot
    $whitelist = ''
    if (-not [string]::IsNullOrWhiteSpace($paths.ConfigPath)) { $whitelist = Join-SwBasePath $paths.ConfigPath 'whitelist.txt' }
    return @{
        ConfigPath    = $paths.ConfigPath
        CachePath     = $paths.CachePath
        WhitelistFile = $whitelist
    }
}

function Assert-SwDataWritable {
    <#
    .SYNOPSIS
        Makes sure Path is a folder Sweepr can write to, or stops.
    .DESCRIPTION
        A missing folder is created with its parents, then a probe file with a unique name is written
        and removed again. Only that probe is ever deleted. On any failure the function stops with a
        message that names the path; it never switches to another folder.
    #>
    param([Parameter(Mandatory = $true, Position = 0)][AllowNull()][AllowEmptyString()][string]$Path)

    $ErrorActionPreference = 'Stop'
    $probe = $null
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { throw 'The data folder is empty.' }
        [void][System.IO.Directory]::CreateDirectory($Path)
        $candidate = [System.IO.Path]::Combine($Path, '.write-test-' + [guid]::NewGuid().ToString('N'))
        # CreateNew fails when the name exists, so the probe is always a file created right here.
        $stream = [System.IO.File]::Open($candidate, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $probe = $candidate
        try { $stream.WriteByte(120) }
        finally { $stream.Dispose() }
        [System.IO.File]::Delete($probe)
        $probe = $null
    }
    catch {
        if ($null -ne $probe) {
            try { [System.IO.File]::Delete($probe) } catch { $null = $_ }
        }
        throw "Sweepr data folder is not writable: $Path. Sweepr does not fall back to your user profile."
    }
}

function Confirm-SwBaseFolder {
    # The folder stored under Key in the configuration, created when missing. Any failure stops.
    param([string]$Key)

    $ErrorActionPreference = 'Stop'
    try { $config = $script:Config } catch { $config = $null }
    $path = ''
    if ($config -is [System.Collections.IDictionary] -and $config.Contains($Key)) { $path = [string]$config[$Key] }
    if ([string]::IsNullOrWhiteSpace($path)) { throw "The Sweepr $Key is not set." }
    try {
        # Literal .NET calls: brackets and wildcard characters in the name belong to the name.
        if (-not [System.IO.Directory]::Exists($path)) { [void][System.IO.Directory]::CreateDirectory($path) }
    }
    catch {
        throw "Cannot create the Sweepr folder: $path ($($_.Exception.Message))"
    }
    return $path
}

function Get-SwConfigPath {
    <#
    .SYNOPSIS
        The configuration folder from $script:Config, created when it is missing.
    #>
    $ErrorActionPreference = 'Stop'
    return (Confirm-SwBaseFolder -Key 'ConfigPath')
}

function Get-SwCachePath {
    <#
    .SYNOPSIS
        The cache folder from $script:Config, created when it is missing.
    #>
    $ErrorActionPreference = 'Stop'
    return (Confirm-SwBaseFolder -Key 'CachePath')
}

# ============================================================================
# System information
# ============================================================================

function Test-SwAdmin {
    <#
    .SYNOPSIS
        True when this process runs elevated as a member of the Administrators group.
    .DESCRIPTION
        An administrator without elevation gets $false. Asks nothing, starts nothing. An error of the
        identity query reaches the caller, which decides how to treat it.
    #>
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
        return [bool]$principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    finally { $identity.Dispose() }
}

function Get-SwFreeSpace {
    <#
    .SYNOPSIS
        Free space of a drive as text in the size format, or Unknown.
    .DESCRIPTION
        Drive is a letter, optionally with a colon and a backslash (C, C: or C:\). Anything else is
        not looked up at all, so no input can change what is asked. Never throws.
    #>
    param([Parameter(Position = 0)][string]$Drive = $env:SystemDrive)

    try {
        if ($null -eq $Drive) { return 'Unknown' }
        $match = [regex]::Match($Drive, '\A([A-Za-z])(?::\\?)?\z')
        if (-not $match.Success) { return 'Unknown' }
        $info = [System.IO.DriveInfo]::new($match.Groups[1].Value.ToUpperInvariant() + ':\')
        if (-not $info.IsReady) { return 'Unknown' }
        return (Format-SwByteSize -Bytes ([long]$info.TotalFreeSpace))
    }
    catch { return 'Unknown' }
}

function Get-SwWindowsVersion {
    <#
    .SYNOPSIS
        Name, Version, Build and Arch of the operating system, each a non-empty string. Never throws.
    .DESCRIPTION
        Taken from the operating system object of the management interface; a value it does not give
        comes from the registry, the .NET OS version and PROCESSOR_ARCHITECTURE, in that order.
        Version is whatever the source gives (10.0.<build>, or a display version such as 23H2 from
        the registry).
    #>
    $name = ''
    $version = ''
    $build = ''
    $arch = ''
    try {
        $system = @(Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop)[0]
        if ($null -ne $system) {
            $name = [string]$system.Caption
            $version = [string]$system.Version
            $build = [string]$system.BuildNumber
            $arch = [string]$system.OSArchitecture
        }
    }
    catch {
        $name = ''
        $version = ''
        $build = ''
        $arch = ''
    }

    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($version) -or [string]::IsNullOrWhiteSpace($build)) {
        $registryName = ''
        $registryVersion = ''
        $registryBuild = ''
        try {
            $key = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
            foreach ($candidate in 'ProductName') {
                $property = $key.PSObject.Properties[$candidate]
                if ($null -ne $property) { $registryName = [string]$property.Value }
            }
            foreach ($candidate in 'DisplayVersion', 'CurrentVersion') {
                $property = $key.PSObject.Properties[$candidate]
                if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) { $registryVersion = [string]$property.Value; break }
            }
            $property = $key.PSObject.Properties['CurrentBuildNumber']
            if ($null -ne $property) { $registryBuild = [string]$property.Value }
        }
        catch { $null = $_ }
        $dotNet = [System.Environment]::OSVersion.Version
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $registryName }
        if ([string]::IsNullOrWhiteSpace($version)) { $version = $registryVersion }
        if ([string]::IsNullOrWhiteSpace($version)) { $version = $dotNet.ToString() }
        if ([string]::IsNullOrWhiteSpace($build)) { $build = $registryBuild }
        if ([string]::IsNullOrWhiteSpace($build) -and $dotNet.Build -ge 0) { $build = [string]$dotNet.Build }
    }
    if ([string]::IsNullOrWhiteSpace($arch)) { $arch = Get-SwBaseEnv 'PROCESSOR_ARCHITECTURE' }

    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'Windows' }
    if ([string]::IsNullOrWhiteSpace($version)) { $version = 'Unknown' }
    if ([string]::IsNullOrWhiteSpace($build)) { $build = 'Unknown' }
    if ([string]::IsNullOrWhiteSpace($arch)) { $arch = 'Unknown' }
    return @{ Name = $name.Trim(); Version = $version.Trim(); Build = $build.Trim(); Arch = $arch.Trim() }
}

# ============================================================================
# Size format
# ============================================================================

function Format-SwByteSize {
    <#
    .SYNOPSIS
        Byte count with a binary unit, such as 1.5MB or 2KB, without a space.
    .DESCRIPTION
        The unit follows the real value (1 KB = 1024 B), not the rounded one, so 1048575 bytes show
        as 1,024KB. Digits and separators follow the culture of the process. Negative values show
        as plain bytes.
    #>
    param([Parameter(Position = 0)][long]$Bytes)

    if ($Bytes -ge 1TB) { return ('{0:N2}TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2}GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1}MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0}KB' -f ($Bytes / 1KB)) }
    return ('{0}B' -f $Bytes)
}

# ============================================================================
# Path text and final path resolution
# ============================================================================

function Get-SwBaseFullPath {
    # Full path of Path (relative paths against the working directory of the process, not the
    # PowerShell location), or $null when the text is empty or cannot be normalized.
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ($Path.IndexOf([char]0) -ge 0) { return $null }
    try { return [System.IO.Path]::GetFullPath($Path) }
    catch { return $null }
}

function ConvertTo-SwBaseCmp {
    # Comparison form of a full path: one separator kind, no trailing separator. The tests that run on
    # other hosts mix both separators, and a trailing one must never decide a comparison.
    param([string]$Path)
    return $Path.Replace('/', '\').TrimEnd([char[]]@('\'))
}

function Initialize-SwBaseNative {
    # Compiles the small Windows file API wrapper on first use (never at load). False when that is not
    # possible, for example in constrained language mode; callers then treat an existing path as
    # unresolvable instead of guessing.
    try { $state = $script:SwBaseNativeState } catch { $state = $null }
    if ($state -eq $true) { return $true }
    if ($state -eq $false) { return $false }

    $source = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class SwBaseNative
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFileAttributesW(string fileName);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFileW(string fileName, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(IntPtr file, StringBuilder buffer, uint length, uint flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    // The extended prefix switches off the system's own path rewriting, so a path is used as given.
    private static string ToNative(string path)
    {
        while (path.Length > 3 && path[path.Length - 1] == '\\')
        {
            path = path.Substring(0, path.Length - 1);
        }
        if (path.StartsWith("\\\\?\\", StringComparison.Ordinal) || path.StartsWith("\\\\.\\", StringComparison.Ordinal)) { return path; }
        if (path.StartsWith("\\\\", StringComparison.Ordinal)) { return "\\\\?\\UNC\\" + path.Substring(2); }
        return "\\\\?\\" + path;
    }

    private static string Strip(string path)
    {
        if (path.StartsWith("\\\\?\\UNC\\", StringComparison.Ordinal)) { return "\\\\" + path.Substring(8); }
        if (path.StartsWith("\\\\?\\", StringComparison.Ordinal) && path.Length >= 6 && path[5] == ':') { return path.Substring(4); }
        return path;
    }

    // status: 0 = resolved, 1 = the path does not exist, 2 = it exists but cannot be resolved.
    public static string Resolve(string path, out int status)
    {
        status = 2;
        string native = ToNative(path);
        uint attributes = GetFileAttributesW(native);
        if (attributes == 0xFFFFFFFF)
        {
            int error = Marshal.GetLastWin32Error();
            if (error == 2 || error == 3 || error == 15 || error == 53 || error == 67 ||
                error == 123 || error == 161 || error == 206 || error == 267)
            {
                status = 1;
            }
            return null;
        }
        // Access 0 reads attributes only; the backup flag allows folders; reparse points are followed.
        IntPtr handle = CreateFileW(native, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        if (handle == new IntPtr(-1)) { return null; }
        try
        {
            StringBuilder buffer = new StringBuilder(1024);
            uint length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
            if (length >= buffer.Capacity)
            {
                buffer = new StringBuilder((int)length + 1);
                length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
            }
            if (length == 0 || length >= buffer.Capacity) { return null; }
            status = 0;
            return Strip(buffer.ToString());
        }
        finally
        {
            CloseHandle(handle);
        }
    }
}
'@
    try {
        if (-not ('SwBaseNative' -as [type])) { Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop }
        $script:SwBaseNativeState = $true
    }
    catch { $script:SwBaseNativeState = $false }
    return [bool]$script:SwBaseNativeState
}

function Get-SwBaseFinalPathInfo {
    # What the file system makes of a full path. Status is
    #   Resolved      Path holds the final spelling (links, short names and aliases resolved)
    #   Missing       the path does not exist
    #   Unresolvable  it exists but its final spelling cannot be determined
    #   NoApi         this host has no Windows file API; the typed spelling stands in for the final one
    param([string]$FullPath)

    if (-not (Test-SwBaseWindows)) { return @{ Status = 'NoApi'; Path = $FullPath } }

    $root = [System.IO.Path]::GetPathRoot($FullPath)
    if ($null -eq $root) { $root = '' }
    $probe = $FullPath.TrimEnd([char[]]@('\', '/'))
    if ($probe.Length -lt $root.Length) { $probe = $root }

    if (-not (Initialize-SwBaseNative)) {
        $present = [System.IO.File]::Exists($probe) -or [System.IO.Directory]::Exists($probe)
        if ($present) { return @{ Status = 'Unresolvable'; Path = $null } }
        return @{ Status = 'Missing'; Path = $null }
    }

    [int]$status = 0
    try { $final = [SwBaseNative]::Resolve($probe, [ref]$status) }
    catch { return @{ Status = 'Unresolvable'; Path = $null } }
    if ($status -eq 0 -and -not [string]::IsNullOrEmpty($final)) { return @{ Status = 'Resolved'; Path = [string]$final } }
    if ($status -eq 1) { return @{ Status = 'Missing'; Path = $null } }
    return @{ Status = 'Unresolvable'; Path = $null }
}

function Resolve-SwSafePath {
    <#
    .SYNOPSIS
        The final spelling of a path, or $null when it cannot be determined.
    .DESCRIPTION
        The path is normalized first (relative paths against the working directory of the process).
        A path that does not exist gives its normalized form, so planning works. An existing path
        gives where the file system really leads (links, 8.3 names and aliases resolved, no \\?\
        prefix). An existing path that cannot be resolved gives $null and is never treated as
        missing. Hosts without the Windows file API give the normalized path. Never throws.
    #>
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Path)

    try {
        $full = Get-SwBaseFullPath -Path $Path
        if ($null -eq $full) { return $null }
        $info = Get-SwBaseFinalPathInfo -FullPath $full
        switch ([string]$info.Status) {
            'Resolved' { return [string]$info.Path }
            'Unresolvable' { return $null }
            default { return $full }
        }
    }
    catch { return $null }
}

# ============================================================================
# Protection rules
# ============================================================================

function Add-SwBaseEntryForms {
    # Adds the comparison forms of one list entry: as written and, when the entry exists and the file
    # system spells it differently (link, short name), the final spelling too. An empty entry or one
    # that cannot be normalized protects nothing and is skipped.
    param([System.Collections.Generic.List[string]]$Target, [string]$Entry)

    $full = Get-SwBaseFullPath -Path $Entry
    if ($null -eq $full) { return }
    $typed = ConvertTo-SwBaseCmp $full
    if ($typed.Length -eq 0) { return }
    $Target.Add($typed)

    $info = Get-SwBaseFinalPathInfo -FullPath $full
    if ([string]$info.Status -ne 'Resolved') { return }
    $final = ConvertTo-SwBaseCmp ([string]$info.Path)
    if ($final.Length -gt 0 -and -not $final.Equals($typed, [System.StringComparison]::OrdinalIgnoreCase)) { $Target.Add($final) }
}

function Get-SwBaseProtectionLists {
    # The protection lists in comparison form, read from the script variables at every call. A missing
    # list is an error, which the caller turns into "protected".
    $prefix = $script:ProtectedPaths
    $exact = $script:ExactProtectedPaths
    if ($null -eq $prefix -or $null -eq $exact) { throw 'The protection lists are missing.' }

    $lists = @{
        Prefix   = [System.Collections.Generic.List[string]]::new()
        Exact    = [System.Collections.Generic.List[string]]::new()
        Packages = [System.Collections.Generic.List[string]]::new()
    }
    foreach ($entry in @($prefix)) { Add-SwBaseEntryForms -Target $lists.Prefix -Entry ([string]$entry) }
    foreach ($entry in @($exact)) { Add-SwBaseEntryForms -Target $lists.Exact -Entry ([string]$entry) }

    $localAppData = Get-SwBaseEnv 'LOCALAPPDATA'
    if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
        Add-SwBaseEntryForms -Target $lists.Packages -Entry (Join-SwBaseText $localAppData 'Packages')
    }
    return $lists
}

function Get-SwBaseCleanGuard {
    # The clean-only switch, read at every call. Never set means off.
    try { $value = $script:SweeprCleanPathGuard } catch { return $false }
    if ($null -eq $value) { return $false }
    return [bool]$value
}

function Test-SwBaseProtectionRules {
    # The rules on one spelling of a path. Everything compares whole path segments, ordinal and
    # without case, so a name that only begins like an entry is never mistaken for it.
    param([string]$Full, [hashtable]$Lists, [bool]$Guard)

    $ignoreCase = [System.StringComparison]::OrdinalIgnoreCase
    $cmp = ConvertTo-SwBaseCmp $Full

    foreach ($entry in $Lists.Exact) {
        if ($cmp.Equals($entry, $ignoreCase)) { return $true }
    }
    foreach ($entry in $Lists.Prefix) {
        if ($cmp.Equals($entry, $ignoreCase) -or $cmp.StartsWith($entry + '\', $ignoreCase)) { return $true }
    }
    foreach ($packages in $Lists.Packages) {
        if ($cmp.Equals($packages, $ignoreCase)) { return $true }
        if ($cmp.StartsWith($packages + '\', $ignoreCase)) {
            # Only while cleaning, and only for the cache leaves of the Teams web view profile, the
            # part below Packages may be left unprotected by this rule; other rules still apply.
            $released = $false
            if ($Guard) {
                $rest = $cmp.Substring($packages.Length)
                $released = [regex]::IsMatch($rest, $script:SwBaseTeamsLeafPattern, ([System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant))
            }
            if (-not $released) { return $true }
        }
    }

    # Segment rules: wrap the path in separators so a needle can only match whole segments.
    $parts = $cmp.Split([char[]]@('\'), [System.StringSplitOptions]::RemoveEmptyEntries)
    $haystack = '\' + [string]::Join('\', $parts) + '\'
    foreach ($needle in $script:SwBaseSegmentsAll) {
        if ($haystack.IndexOf($needle, $ignoreCase) -ge 0) { return $true }
    }
    if ($Guard) {
        foreach ($needle in $script:SwBaseSegmentsClean) {
            if ($haystack.IndexOf($needle, $ignoreCase) -ge 0) { return $true }
        }
    }
    return $false
}

function Test-SwProtectedPath {
    <#
    .SYNOPSIS
        True when the path must not be changed.
    .DESCRIPTION
        Fails closed: an empty path, a path that cannot be normalized and every internal error give
        $true. The rules are the exact list ($script:ExactProtectedPaths), the prefix list
        ($script:ProtectedPaths, with everything below), the Packages folder, the credential and
        certificate segments, and during clean the key, browser-profile and transcript segments
        ($script:SweeprCleanPathGuard). List entries are compared as written and in their final
        spelling.

        Without -AlreadyResolved an existing path is also checked in its final spelling (links, short
        names, aliases), and an existing path whose final spelling cannot be found counts as
        protected. A path that does not exist gets only the answer for its text. With
        -AlreadyResolved the text is judged as given and the file system is not asked about the path.
        Never changes anything.
    #>
    param(
        [Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Path,
        [switch]$AlreadyResolved
    )

    $ErrorActionPreference = 'Stop'
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
        $full = Get-SwBaseFullPath -Path $Path
        if ($null -eq $full) { return $true }

        $lists = Get-SwBaseProtectionLists
        $guard = Get-SwBaseCleanGuard
        if (Test-SwBaseProtectionRules -Full $full -Lists $lists -Guard $guard) { return $true }
        if ($AlreadyResolved) { return $false }

        $info = Get-SwBaseFinalPathInfo -FullPath $full
        switch ([string]$info.Status) {
            'Resolved' {
                $finalFull = Get-SwBaseFullPath -Path ([string]$info.Path)
                if ($null -eq $finalFull) { return $true }
                if ((ConvertTo-SwBaseCmp $finalFull).Equals((ConvertTo-SwBaseCmp $full), [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
                return [bool](Test-SwBaseProtectionRules -Full $finalFull -Lists $lists -Guard $guard)
            }
            'Unresolvable' { return $true }
            default { return $false }
        }
    }
    catch { return $true }
}

# ============================================================================
# List files
# ============================================================================

function Read-SwListBytes {
    <#
    .SYNOPSIS
        All bytes of a list file, read with shared access. Throws on any read error.
    .DESCRIPTION
        The file is opened for reading only, allowing other processes to write or delete it meanwhile,
        so a file an editor holds open can be read. An empty file gives an empty array, never $null.
        The name is literal; brackets and wildcard characters are part of it.
    #>
    param([Parameter(Mandatory = $true, Position = 0)][string]$Path)

    $ErrorActionPreference = 'Stop'
    try {
        if ([System.IO.Directory]::Exists($Path)) { throw "Cannot read the list file, it is a folder: $Path" }
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        try {
            $memory = [System.IO.MemoryStream]::new()
            try {
                $stream.CopyTo($memory)
                $bytes = $memory.ToArray()
            }
            finally { $memory.Dispose() }
        }
        finally { $stream.Dispose() }
    }
    catch { throw }
    return , ([byte[]]$bytes)
}

function ConvertFrom-SwListBytes {
    <#
    .SYNOPSIS
        Lines of a list file given as bytes.
    .DESCRIPTION
        Never uses the default encoding of the platform. A byte order mark decides the encoding and is
        removed: UTF-8, UTF-32 (checked before UTF-16, whose mark it starts with) and UTF-16, both
        byte orders. Without a mark the bytes are read as strict UTF-8, and when they are not valid
        UTF-8 as the system ANSI code page. Lines end at CRLF, CR or LF; empty lines stay in the
        result for the reader to skip. Bad bytes never throw, they decode to replacement characters.
    #>
    param([Parameter(Mandatory = $true, Position = 0)][AllowEmptyCollection()][byte[]]$Bytes)

    $count = $Bytes.Length
    if ($count -ge 4 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE -and $Bytes[2] -eq 0 -and $Bytes[3] -eq 0) {
        $text = [System.Text.UTF32Encoding]::new($false, $false).GetString($Bytes, 4, $count - 4)
    }
    elseif ($count -ge 4 -and $Bytes[0] -eq 0 -and $Bytes[1] -eq 0 -and $Bytes[2] -eq 0xFE -and $Bytes[3] -eq 0xFF) {
        $text = [System.Text.UTF32Encoding]::new($true, $false).GetString($Bytes, 4, $count - 4)
    }
    elseif ($count -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        $text = [System.Text.UTF8Encoding]::new($false, $false).GetString($Bytes, 3, $count - 3)
    }
    elseif ($count -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        $text = [System.Text.UnicodeEncoding]::new($false, $false).GetString($Bytes, 2, $count - 2)
    }
    elseif ($count -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        $text = [System.Text.UnicodeEncoding]::new($true, $false).GetString($Bytes, 2, $count - 2)
    }
    else {
        try { $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($Bytes) }
        catch { $text = [System.Text.Encoding]::Default.GetString($Bytes) }
    }
    return , ([string[]][regex]::Split($text, "\r\n|\r|\n"))
}

function ConvertFrom-SwListEntry {
    <#
    .SYNOPSIS
        The path a list line means, or $null when the line means no path.
    .DESCRIPTION
        Steps: trim; an empty line or one starting with # is a comment (a # after text is part of
        the text); remove one enclosing pair of quotes; an entry that starts with a single slash is
        returned as it is (a path of another platform must not become the root of the current drive);
        otherwise / becomes \, ~ and ~\... become the profile folder (nothing when USERPROFILE is
        empty), and %VAR% is expanded. An undefined variable leaves the entry literal. A defined one
        is used only when the result is rooted (X:\ or \\server); a relative or root-relative rest
        would mean a different place than written and is dropped.

        With -IncludeRaw an entry that expansion changed or dropped also gives the unexpanded
        spelling, as a second string (expanded first) or alone, because a real folder may be named
        %NAME%. Never throws.
    #>
    param(
        [Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Line,
        [switch]$IncludeRaw
    )

    try {
        if ($null -eq $Line) { return $null }
        $entry = $Line.Trim()
        if ($entry.Length -eq 0 -or $entry[0] -eq [char]35) { return $null }

        if ($entry.Length -ge 2) {
            $first = $entry[0]
            $last = $entry[$entry.Length - 1]
            if (($first -eq [char]34 -and $last -eq [char]34) -or ($first -eq [char]39 -and $last -eq [char]39)) {
                $entry = $entry.Substring(1, $entry.Length - 2).Trim()
                if ($entry.Length -eq 0) { return $null }
            }
        }

        if ($entry[0] -eq [char]47 -and ($entry.Length -eq 1 -or $entry[1] -ne [char]47)) { return $entry }
        $entry = $entry.Replace('/', '\')

        if ($entry[0] -eq [char]126 -and ($entry.Length -eq 1 -or $entry[1] -eq [char]92)) {
            $profileRoot = Get-SwBaseEnv 'USERPROFILE'
            if ([string]::IsNullOrWhiteSpace($profileRoot)) { return $null }
            $entry = $profileRoot.TrimEnd([char[]]@('\', '/')) + $entry.Substring(1)
        }

        if ($entry.IndexOf([char]37) -lt 0) { return $entry }
        $expanded = [System.Environment]::ExpandEnvironmentVariables($entry)
        if ([string]::Equals($expanded, $entry, [System.StringComparison]::Ordinal)) { return $entry }

        $expanded = $expanded.Replace('/', '\')
        if ([regex]::IsMatch($expanded, '\A(?:[A-Za-z]:\\|\\\\[^\\])')) {
            if ($IncludeRaw) { return , ([string[]]@($expanded, $entry)) }
            return $expanded
        }
        if ($IncludeRaw) { return $entry }
        return $null
    }
    catch { return $null }
}

# ============================================================================
# Whitelist
# ============================================================================

function Add-SwBaseWhitelistRow {
    # Adds one protected folder or pattern to the rows of a whitelist state. A literal row (data
    # folders) never has wildcard meaning. For other rows the text is also a pattern when it holds
    # * ? [ or a backtick; a pattern without [ and backtick also protects what lies below its
    # matches. When the written folder exists and the file system spells it differently (junction,
    # symbolic link, short name), the final spelling is added as a literal row. Rows are independent
    # of each other, so the order of the lines never matters.
    param([System.Collections.Generic.List[object]]$Rows, [string]$Pattern, [bool]$Literal)

    if ([string]::IsNullOrWhiteSpace($Pattern)) { return }
    $root = $Pattern.TrimEnd([char[]]@('\'))
    if ($root.Trim().Length -eq 0) { return }

    $hasWildcard = (-not $Literal) -and ($root.IndexOfAny([char[]]@('*', '?', '[', '`')) -ge 0)
    $row = @{ Root = $root; RootSlash = $root + '\'; Wild = $null; WildChild = $null }
    if ($hasWildcard) {
        $options = [System.Management.Automation.WildcardOptions]::IgnoreCase -bor [System.Management.Automation.WildcardOptions]::CultureInvariant
        try { $row.Wild = [System.Management.Automation.WildcardPattern]::new($root, $options) }
        catch { $row.Wild = $null }
        if ($root.IndexOfAny([char[]]@('[', '`')) -lt 0) {
            try { $row.WildChild = [System.Management.Automation.WildcardPattern]::new($root + '\*', $options) }
            catch { $row.WildChild = $null }
        }
    }
    $Rows.Add($row)

    # A relative text is no folder to resolve: it would be taken against the working directory.
    if ($hasWildcard -or -not [regex]::IsMatch($root, '\A(?:[A-Za-z]:[\\/]|\\\\[^\\])')) { return }
    try {
        $full = Get-SwBaseFullPath -Path $root
        if ($null -eq $full) { return }
        $info = Get-SwBaseFinalPathInfo -FullPath $full
        if ([string]$info.Status -ne 'Resolved') { return }
        $final = ConvertTo-SwBaseCmp ([string]$info.Path)
        if ($final.Length -eq 0 -or $final.Equals((ConvertTo-SwBaseCmp $full), [System.StringComparison]::OrdinalIgnoreCase)) { return }
        $Rows.Add(@{ Root = $final; RootSlash = $final + '\'; Wild = $null; WildChild = $null })
    }
    catch {
        # Not resolvable: the written spelling stays the only one.
        $null = $_
    }
}

function Get-SwWhitelistState {
    <#
    .SYNOPSIS
        The protection a whitelist gives, ready for any number of Test-SwWhitelisted calls.
    .DESCRIPTION
        Built from the default patterns ($script:DefaultWhitelistPatterns), the data folders
        ($script:Config ConfigPath and CachePath, protected literally) and the lines of the whitelist
        file ($script:Config.WhitelistFile, read at every call). A missing file adds no lines. A file
        that exists but whose metadata or content cannot be read (access denied, a folder instead of
        a file, read or decoding errors, NUL characters) gives a state that protects every path:
        unknown protection is never an empty list. The result is opaque; hand it to
        Test-SwWhitelisted -State. Never throws.
    #>
    $ErrorActionPreference = 'Stop'
    try {
        $rows = [System.Collections.Generic.List[object]]::new()

        $defaults = $script:DefaultWhitelistPatterns
        if ($null -eq $defaults) { throw 'The default whitelist is missing.' }
        foreach ($pattern in @($defaults)) { Add-SwBaseWhitelistRow -Rows $rows -Pattern ([string]$pattern) -Literal $false }

        $config = $script:Config
        if ($config -isnot [System.Collections.IDictionary]) { throw 'The configuration is missing.' }
        foreach ($key in 'ConfigPath', 'CachePath') {
            if (-not $config.Contains($key)) { continue }
            $folder = [string]$config[$key]
            if ([string]::IsNullOrWhiteSpace($folder)) { continue }
            Add-SwBaseWhitelistRow -Rows $rows -Pattern $folder -Literal $true
            if ($folder.Contains('/')) { Add-SwBaseWhitelistRow -Rows $rows -Pattern $folder.Replace('/', '\') -Literal $true }
        }

        $file = ''
        if ($config.Contains('WhitelistFile')) { $file = [string]$config['WhitelistFile'] }
        if ([string]::IsNullOrWhiteSpace($file)) { throw 'The whitelist file path is not set.' }

        $present = $false
        try {
            $item = Get-Item -LiteralPath $file -Force -ErrorAction Stop
            $present = $true
            if ($null -eq $item) { $present = [System.IO.File]::Exists($file) }
        }
        catch [System.Management.Automation.ItemNotFoundException] { $present = $false }

        if ($present) {
            $bytes = Read-SwListBytes -Path $file
            if ($null -eq $bytes) { throw 'The whitelist file gave no bytes.' }
            $lines = ConvertFrom-SwListBytes -Bytes ([byte[]]$bytes)
            foreach ($line in @($lines)) {
                if ($null -eq $line) { continue }
                if (([string]$line).IndexOf([char]0) -ge 0) { throw 'The whitelist file contains NUL characters.' }
                # Assigned first: the result is one string, two strings as one array, or nothing.
                $converted = ConvertFrom-SwListEntry -Line ([string]$line) -IncludeRaw
                foreach ($pattern in @($converted)) {
                    if ($null -ne $pattern) { Add-SwBaseWhitelistRow -Rows $rows -Pattern ([string]$pattern) -Literal $false }
                }
            }
        }
        return @{ KeepAll = $false; Rows = $rows }
    }
    catch {
        Write-Debug "The whitelist cannot be read, every path stays protected: $($_.Exception.Message)"
        return @{ KeepAll = $true; Rows = [System.Collections.Generic.List[object]]::new() }
    }
}

function Test-SwWhitelisted {
    <#
    .SYNOPSIS
        True when the whitelist protects the path.
    .DESCRIPTION
        The path is compared as given, with no normalization and no file system access; a trailing
        backslash is ignored. A row protects its folder and everything below it, never a sibling whose
        name only begins like it, and a literal folder keeps its descendants even when its name holds
        brackets. A pattern row also matches as a wildcard. An empty path, an unusable state and every
        error give $true. Without -State the state is read now (one read of the whitelist file); with
        a state nothing is read.
    #>
    param(
        [Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Path,
        [Parameter(Position = 1)][object]$State = $null
    )

    $ErrorActionPreference = 'Stop'
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
        if ($null -eq $State) { $State = Get-SwWhitelistState }
        if ($State -isnot [hashtable] -or -not $State.ContainsKey('KeepAll') -or -not $State.ContainsKey('Rows')) { return $true }
        if ([bool]$State.KeepAll) { return $true }

        $ignoreCase = [System.StringComparison]::OrdinalIgnoreCase
        $candidate = $Path.TrimEnd([char[]]@('\'))
        foreach ($row in $State.Rows) {
            if ($candidate.Equals($row.Root, $ignoreCase) -or $candidate.StartsWith($row.RootSlash, $ignoreCase)) { return $true }
            if ($null -ne $row.Wild -and $row.Wild.IsMatch($candidate)) { return $true }
            if ($null -ne $row.WildChild -and $row.WildChild.IsMatch($candidate)) { return $true }
        }
        return $false
    }
    catch { return $true }
}

# ============================================================================
# Old names, kept as forwarding functions (not aliases, so a test mock of either name behaves) until
# the callers move to the new ones.
# ============================================================================

function ConvertTo-SweeprPsLiteral {
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Value)
    ConvertTo-SwPsLiteral -Value $Value
}

function Get-SweeprColor {
    param([Parameter(Mandatory = $true, Position = 0)][string]$Name)
    Get-SwColor -Name $Name
}

function Get-SweeprIcon {
    param([Parameter(Mandatory = $true, Position = 0)][string]$Name)
    Get-SwIcon -Name $Name
}

function Get-SweeprDefaultColors { Get-SwDefaultColors }

function Get-SweeprDefaultIcons { Get-SwDefaultIcons }

function Initialize-SweeprVisualDefaults { Initialize-SwVisualDefaults }

function Test-SweeprPortable {
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$RootDir)
    Test-SwPortable -RootDir $RootDir
}

function Resolve-SweeprDataPaths {
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$RootDir)
    Resolve-SwDataPaths -RootDir $RootDir
}

function Assert-SweeprDataWritable {
    param([Parameter(Mandatory = $true, Position = 0)][AllowNull()][AllowEmptyString()][string]$Path)
    Assert-SwDataWritable -Path $Path
}

function Get-ConfigPath { Get-SwConfigPath }

function Get-CachePath { Get-SwCachePath }

function Test-IsAdmin { Test-SwAdmin }

function Get-FreeSpace {
    param([Parameter(Position = 0)][string]$Drive = $env:SystemDrive)
    Get-SwFreeSpace -Drive $Drive
}

function Get-WindowsVersion { Get-SwWindowsVersion }

function Format-ByteSize {
    param([Parameter(Position = 0)][long]$Bytes)
    Format-SwByteSize -Bytes $Bytes
}

function Test-ProtectedPath {
    param(
        [Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Path,
        [switch]$AlreadyResolved
    )
    Test-SwProtectedPath -Path $Path -AlreadyResolved:$AlreadyResolved
}

function Resolve-SafePath {
    param([Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Path)
    Resolve-SwSafePath -Path $Path
}

function Get-WhitelistState { Get-SwWhitelistState }

function Test-Whitelisted {
    param(
        [Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Path,
        [Parameter(Position = 1)][object]$State = $null
    )
    Test-SwWhitelisted -Path $Path -State $State
}

function Read-SweeprListBytes {
    param([Parameter(Mandatory = $true, Position = 0)][string]$Path)
    Read-SwListBytes -Path $Path
}

function ConvertFrom-SweeprListBytes {
    param([Parameter(Mandatory = $true, Position = 0)][AllowEmptyCollection()][byte[]]$Bytes)
    ConvertFrom-SwListBytes -Bytes $Bytes
}

function ConvertFrom-SweeprListEntry {
    param(
        [Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Line,
        [switch]$IncludeRaw
    )
    ConvertFrom-SwListEntry -Line $Line -IncludeRaw:$IncludeRaw
}

# ============================================================================
# Data and state, evaluated once per load (see the header)
# ============================================================================

# Folder name sequences, written as the text to find inside a path wrapped in backslashes. The first
# group protects in every command, the second only while cleaning.
$script:SwBaseSegmentsAll = @(
    '\Microsoft\Credentials\', '\Microsoft\Protect\', '\Microsoft\Crypto\', '\Microsoft\Vault\',
    '\Microsoft\SystemCertificates\', '\Microsoft\Windows\Start Menu\'
)
$script:SwBaseSegmentsClean = @(
    '\.ssh\', '\.gnupg\', '\.aws\', '\.azure\', '\.kube\', '\.docker\', '\Login Data\', '\Cookies\',
    '\Web Data\', '\Local Storage\', '\Session Storage\', '\IndexedDB\', '\Sessions\',
    '\Local Extension Settings\', '\Sync Data\', '\Service Worker\CacheStorage\',
    '\Adobe\Common\Team Projects Cache\', '\pypoetry\Cache\virtualenvs\', '\User\History\',
    '\.claude\projects\', '\.claude\file-history\', '\.claude\history.jsonl\', '\.codex\sessions\',
    '\.codex\archived_sessions\', '\.codex\history.jsonl\'
)

# Below the Packages folder: the cache leaves of the Teams web view profiles. The rest of Packages
# stays protected.
$script:SwBaseTeamsLeafPattern = '\A\\MSTeams_8wekyb3d8bbwe\\LocalCache\\Microsoft\\MSTeams\\EBWebView\\[^\\]+\\(?:Cache|Code Cache|GPUCache)(?:\\.*)?\z'

$script:SwBaseNativeState = $null

# Colour and icon tables: fill what is missing, keep what a caller already set.
Initialize-SwVisualDefaults

$script:Config = New-SwBaseConfig

$script:ProtectedPaths = @(
    'C:\Windows', 'C:\Windows\System32', 'C:\Windows\SysWOW64', 'C:\Program Files', 'C:\Program Files (x86)',
    'C:\Program Files\Windows Defender', 'C:\Program Files (x86)\Windows Defender',
    'C:\ProgramData\Microsoft\Windows Defender'
)
foreach ($swBaseName in 'SYSTEMROOT', 'WINDIR') {
    $swBaseValue = Get-SwBaseEnv $swBaseName
    if (-not [string]::IsNullOrWhiteSpace($swBaseValue)) { $script:ProtectedPaths += $swBaseValue }
}
Remove-Variable -Name swBaseName, swBaseValue -ErrorAction SilentlyContinue

# Only the profile folder itself: targeted cache cleanup below it stays possible.
$script:ExactProtectedPaths = @()
$swBaseProfile = Get-SwBaseEnv 'USERPROFILE'
if (-not [string]::IsNullOrWhiteSpace($swBaseProfile)) { $script:ExactProtectedPaths = @($swBaseProfile) }

# Always protected, whatever the user's whitelist file says. An empty environment value gives a
# relative text that matches no absolute path.
$swBaseLocal = Get-SwBaseEnv 'LOCALAPPDATA'
$swBaseRoaming = Get-SwBaseEnv 'APPDATA'
$script:DefaultWhitelistPatterns = @(
    (Join-SwBaseText $swBaseLocal 'Microsoft\Windows\Explorer'),
    (Join-SwBaseText $swBaseLocal 'Microsoft\Windows\Fonts'),
    (Join-SwBaseText $swBaseRoaming 'Microsoft\Windows\Recent'),
    (Join-SwBaseText $swBaseProfile '.vscode\extensions'),
    (Join-SwBaseText $swBaseProfile '.nuget'),
    (Join-SwBaseText $swBaseProfile '.cargo'),
    (Join-SwBaseText $swBaseProfile '.rustup'),
    (Join-SwBaseText $swBaseProfile '.m2\repository'),
    (Join-SwBaseText $swBaseProfile '.gradle\caches\modules-2\files-*'),
    (Join-SwBaseText $swBaseProfile '.ollama\models'),
    (Join-SwBaseText $swBaseLocal 'JetBrains')
)
Remove-Variable -Name swBaseProfile, swBaseLocal, swBaseRoaming -ErrorAction SilentlyContinue

# Set by the clean command before it deletes; unset means off.
if ($null -eq $(try { $script:SweeprCleanPathGuard } catch { $null })) { $script:SweeprCleanPathGuard = $false }

$script:SWEEPR_BASE_LOADED = $true

# Other modules rely on these for the rest of their run.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
