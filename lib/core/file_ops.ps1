# Sweepr - file operations: path guard, file identity, tree walk and sizes, removal of single
# entries and trees, the Recycle Bin path, dry-run state, preview list and cleanup statistics
#
# This is the only place that deletes files or folders or moves them to the Recycle Bin. Loaded by
# dot-sourcing, by the router and by every command module. Loading writes nothing, creates no file or
# folder, starts no process, uses no network and compiles no native code (that happens at first use);
# it only defines functions and fills the script variables below. A second load in the same scope
# changes nothing: dry-run state, counters, collectors and variables that a caller changed stay as
# they are. Setting $script:SWEEPR_FILEOPS_LOADED to $false makes the next load read SWEEPR_DRY_RUN
# again and put the counters, the collectors and the walk budget back to their starting values.
#
# Script variables that callers read or replace (read at every call, nothing is cached):
# SweeprDryRunMode, TotalSizeCleaned (KB), FilesCleaned, TotalItems, OwnerCleanups, DryRunCollector,
# NotMeasuredCollector, ExportListFile (may be unset) and SwWalkBudgetSeconds.
#
# The code fails closed: whenever it cannot decide (no identity for a path, a protection question
# without an answer, an unreadable whitelist, an exception before the removal), nothing is removed.
# A folder is never removed recursively: its entries are checked first, removed one by one, and the
# folder itself goes only when it is empty.

if ($(try { [bool]$script:SWEEPR_FILEOPS_LOADED } catch { $false })) {
    # Callers rely on these for the rest of their run, also when the module was loaded already.
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    return
}

# The dependencies come from the folder of this file, never from the working directory.
. ([System.IO.Path]::Combine($PSScriptRoot, 'base.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'log.ps1'))

# ============================================================================
# Small helpers
# ============================================================================

function Get-SwFileOpsField {
    # One field of a snapshot or tree result, whatever its kind: table, object, test double or $null.
    # A field that is not there gives $null, also under strict mode.
    param($Object, [string]$Name)

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Write-SwFileOpsDebug {
    # A diagnostic line must never turn a removal that happened into an error.
    param([string]$Message)

    try { Write-Debug $Message }
    catch { $null = $_ }
}

function Test-SwFileOpsExactTrue {
    # True only for exactly one [bool] true. A condition, a guard or a safety answer that gives nothing,
    # something else or several values is "no".
    param($Answer)

    $values = @($Answer)
    return (($values.Count -eq 1) -and ($values[0] -is [bool]) -and ($values[0] -eq $true))
}

function Test-SwFileOpsSamePath {
    # Same spelling after normalization, without case, with one separator kind and no trailing separator.
    param([string]$Left, [string]$Right)

    try {
        $one = [System.IO.Path]::GetFullPath($Left).Replace('/', '\').TrimEnd([char[]]@('\'))
        $two = [System.IO.Path]::GetFullPath($Right).Replace('/', '\').TrimEnd([char[]]@('\'))
        return [string]::Equals($one, $two, [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch { return $false }
}

function Test-SwFileOpsCompletePath {
    # A path that means the same entry for every API: a drive letter with a separator, a UNC path, and on
    # hosts without drive letters a leading slash. Relative, root-relative, drive-relative and provider
    # paths (HKCU:\..., Env:Name) are not complete: Test-Path and Remove-Item resolve them against the
    # PowerShell location, GetFullPath against the working directory of the process, so the entry that was
    # checked would not be the entry that is removed.
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path.IndexOf([char]0) -ge 0) { return $false }
    if ([regex]::IsMatch($Path, '\A[A-Za-z]:[\\/]')) { return $true }
    if ($Path.StartsWith('\\', [System.StringComparison]::Ordinal)) { return $true }
    if ([System.IO.Path]::DirectorySeparatorChar -eq '/' -and $Path.StartsWith('/', [System.StringComparison]::Ordinal)) { return $true }
    return $false
}

function Get-SwFileOpsLeaf {
    # Last segment of a path, the whole text when there is none (a drive root).
    param([string]$Path)

    $leaf = [System.IO.Path]::GetFileName($Path.TrimEnd([char[]]@('\', '/')))
    if ([string]::IsNullOrEmpty($leaf)) { return $Path }
    return $leaf
}

function ConvertTo-SwFileOpsBytes {
    # A measurement as a non-negative [long]; nothing or something unusable counts as 0.
    param($Value)

    $values = @($Value)
    if ($values.Count -eq 0) { return [long]0 }
    try { $number = [long]$values[$values.Count - 1] }
    catch { return [long]0 }
    if ($number -lt 0) { return [long]0 }
    return $number
}

function ConvertTo-SwFileOpsKilobytes {
    # Whole kilobytes, rounded up: a file of one byte still shows as 1 KB.
    param([long]$Bytes)

    if ($Bytes -le 0) { return [long]0 }
    return [long][math]::Ceiling([double]$Bytes / 1024.0)
}

function Add-SwFileOpsCount {
    # Adds to the cleanup statistics. A counter that a caller removed starts at 0.
    param([long]$SizeKB, [int]$Paths, [int]$Items)

    try { $size = [long]$script:TotalSizeCleaned } catch { $size = [long]0 }
    try { $count = [int]$script:FilesCleaned } catch { $count = 0 }
    try { $total = [int]$script:TotalItems } catch { $total = 0 }
    $script:TotalSizeCleaned = $size + $SizeKB
    $script:FilesCleaned = $count + $Paths
    $script:TotalItems = $total + $Items
}

function Write-SwFileOpsOperation {
    # One line of the operations log. The writer decides about SWEEPR_NO_OPLOG and about its own
    # failures; a failure that still gets out is reported and ignored, because the line describes a
    # removal that already happened or did not.
    param([string]$Action, [string]$Path, [string]$Detail)

    try { Write-SweeprOperation -Action $Action -Path $Path -Detail $Detail }
    catch { Write-SwFileOpsDebug "operations log line not written: $($_.Exception.Message)" }
}

function Write-SwFileOpsLine {
    # One status line on the host: a success line or a preview line.
    param([string]$Kind, [string]$Message)

    try {
        if ($Kind -eq 'DryRun') { Write-DryRun $Message }
        else { Write-Success $Message }
    }
    catch { Write-SwFileOpsDebug "status line not written: $($_.Exception.Message)" }
}

function Set-SwFileOpsActivity {
    # Marks the current section as active, so it does not report "Nothing to tidy".
    try { Set-SectionActivity }
    catch { Write-SwFileOpsDebug "section activity not set: $($_.Exception.Message)" }
}

function Test-SwFileOpsCondition {
    # A guard or condition counts only when it gives exactly one [bool] true. An exception, no output,
    # several outputs or another type mean "do not remove". No block means no condition.
    param([scriptblock]$Block, [object[]]$Arguments = @())

    if ($null -eq $Block) { return $true }
    try {
        $ErrorActionPreference = 'Stop'
        $answer = @(& $Block @Arguments)
    }
    catch {
        Write-SwFileOpsDebug "condition not met: $($_.Exception.Message)"
        return $false
    }
    return (Test-SwFileOpsExactTrue $answer)
}

function Test-SwFileOpsSafe {
    # Test-SwSafePath with a strict reading of the answer: only exactly one $true allows the path.
    param([string]$Path, [object]$State)

    try { $answer = @(Test-SwSafePath -Path $Path -WhitelistState $State) }
    catch {
        Write-SwFileOpsDebug "safety question failed for ${Path}: $($_.Exception.Message)"
        return $false
    }
    return (Test-SwFileOpsExactTrue $answer)
}

function Test-SwFileOpsUnchanged {
    # Test-SwPathSnapshot with a strict reading of the answer: only exactly one $true counts.
    param([object]$Snapshot)

    try { $answer = @(Test-SwPathSnapshot -Snapshot $Snapshot) }
    catch {
        Write-SwFileOpsDebug "identity test failed: $($_.Exception.Message)"
        return $false
    }
    return (Test-SwFileOpsExactTrue $answer)
}

function Get-SwFileOpsWalkBudget {
    # Seconds one walk may take. An unusable value falls back to the default, a negative one stops walks.
    try { $value = [double]$script:SwWalkBudgetSeconds }
    catch { $value = 15.0 }
    if ($value -lt 0) { return 0.0 }
    return $value
}

# ============================================================================
# Native helper: file identity and the Recycle Bin
# ============================================================================

function Initialize-SwFileOpsNative {
    # Compiles the small Windows wrapper on first use (never at load). False when that is not possible,
    # for example in constrained language mode; callers then treat the path as having no identity.
    try { $state = $script:SwFileOpsNativeState } catch { $state = $null }
    if ($state -eq $true) { return $true }
    if ($state -eq $false) { return $false }

    $source = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Threading;

[ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface SwFileOpsShellItem
{
    void BindToHandler(IntPtr bindContext, ref Guid handlerId, ref Guid interfaceId, out IntPtr result);
    void GetParent(out SwFileOpsShellItem parent);
    void GetDisplayName(uint nameType, out IntPtr name);
    void GetAttributes(uint mask, out uint attributes);
    void Compare(SwFileOpsShellItem other, uint hint, out int order);
}

// Only the methods up to RecycleItem are declared: the order of the table is what counts, and nothing
// after it is called.
[ComImport, Guid("00adb003-bde9-45c6-8e29-d09f9353e108"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface SwFileOpsTransferSource
{
    [PreserveSig] int Advise(IntPtr sink, out uint cookie);
    [PreserveSig] int Unadvise(uint cookie);
    [PreserveSig] int SetProperties(IntPtr properties);
    [PreserveSig] int OpenItem(SwFileOpsShellItem item, uint flags, ref Guid interfaceId, out IntPtr result);
    [PreserveSig] int MoveItem(SwFileOpsShellItem item, SwFileOpsShellItem parentDestination, [MarshalAs(UnmanagedType.LPWStr)] string newName, uint flags, out SwFileOpsShellItem newItem);
    [PreserveSig] int RecycleItem(SwFileOpsShellItem source, SwFileOpsShellItem parentDestination, uint flags, out SwFileOpsShellItem newItem);
}

public static class SwFileOpsNative
{
    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public FILETIME CreationTime;
        public FILETIME LastAccessTime;
        public FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFileW(string fileName, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(IntPtr file, out ByHandleFileInformation information);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    private static extern void SHCreateItemFromParsingName(string path, IntPtr bindContext, ref Guid interfaceId, out SwFileOpsShellItem item);

    [DllImport("shell32.dll", PreserveSig = false)]
    private static extern void SHGetKnownFolderItem(ref Guid folderId, uint flags, IntPtr token, ref Guid interfaceId, out SwFileOpsShellItem item);

    // The extended prefix switches off the system's own path rewriting, so a path is used as given.
    private static string ToNative(string path)
    {
        while (path.Length > 3 && path[path.Length - 1] == '\\')
        {
            path = path.Substring(0, path.Length - 1);
        }
        return "\\\\?\\" + path;
    }

    // Volume serial number and file index of the entry itself. The handle asks for attributes only, allows
    // every other process to read, write and delete meanwhile, does not follow a link and is closed before
    // returning, so it never blocks a rename or a removal.
    public static bool Query(string path, out string identity, out bool isLink)
    {
        identity = null;
        isLink = false;
        // 0x80 read attributes; share 7; open existing; 0x02000000 backup semantics (folders) and
        // 0x00200000 open the reparse point itself.
        IntPtr handle = CreateFileW(ToNative(path), 0x80, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        if (handle == new IntPtr(-1)) { return false; }
        try
        {
            ByHandleFileInformation information;
            if (!GetFileInformationByHandle(handle, out information)) { return false; }
            isLink = (information.FileAttributes & 0x400) != 0;
            identity = information.VolumeSerialNumber.ToString("x8") + ":" + information.FileIndexHigh.ToString("x8") + information.FileIndexLow.ToString("x8");
            return true;
        }
        finally
        {
            CloseHandle(handle);
        }
    }

    private static string GetItemName(SwFileOpsShellItem item)
    {
        IntPtr text;
        try { item.GetDisplayName(0x80058000, out text); }
        catch (Exception) { return "(Recycle Bin)"; }
        string value = Marshal.PtrToStringUni(text);
        Marshal.FreeCoTaskMem(text);
        return value;
    }

    private static string RecycleOnThisThread(string path)
    {
        Guid shellItemId = new Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe");
        SwFileOpsShellItem source;
        SHCreateItemFromParsingName(path, IntPtr.Zero, ref shellItemId, out source);

        Guid binFolderId = new Guid("b7534046-3ecb-4c18-be4e-64cd4cb7d6ac");
        SwFileOpsShellItem bin;
        SHGetKnownFolderItem(ref binFolderId, 0, IntPtr.Zero, ref shellItemId, out bin);

        Guid handlerId = new Guid("d5e346a1-f753-4932-b403-4574800e2498");
        Guid transferId = new Guid("00adb003-bde9-45c6-8e29-d09f9353e108");
        IntPtr pointer;
        source.BindToHandler(IntPtr.Zero, ref handlerId, ref transferId, out pointer);
        SwFileOpsTransferSource transfer;
        try { transfer = (SwFileOpsTransferSource)Marshal.GetObjectForIUnknown(pointer); }
        finally { Marshal.Release(pointer); }

        SwFileOpsShellItem recycled;
        int result = transfer.RecycleItem(source, bin, 0, out recycled);
        if (result < 0) { Marshal.ThrowExceptionForHR(result); }
        if (recycled == null) { throw new IOException("The shell did not report where the item went."); }
        return GetItemName(recycled);
    }

    // The shell needs a single-threaded apartment, so the call runs on a thread of its own and is
    // waited for. The result is the name of the new place, or an exception.
    public static string RecycleItem(string path)
    {
        string result = null;
        Exception failure = null;
        Thread worker = new Thread(delegate ()
        {
            try { result = RecycleOnThisThread(path); }
            catch (Exception exception) { failure = exception; }
        });
        worker.SetApartmentState(ApartmentState.STA);
        worker.Start();
        worker.Join();
        if (failure != null) { throw new IOException(failure.Message, failure); }
        return result;
    }
}
'@
    try {
        if (-not ('SwFileOpsNative' -as [type])) { Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop }
        $script:SwFileOpsNativeState = $true
    }
    catch {
        Write-SwFileOpsDebug "native file identity helper not available: $($_.Exception.Message)"
        $script:SwFileOpsNativeState = $false
    }
    return [bool]$script:SwFileOpsNativeState
}

# ============================================================================
# Test-SwSafePath
# ============================================================================

function Test-SwSafePath {
    <#
    .SYNOPSIS
        True when the path may be touched: it is neither protected nor kept by the whitelist.
    .DESCRIPTION
        The polarity is the opposite of Test-SwProtectedPath. Two spellings are judged: the typed one
        (normalized, links not resolved) and the final one (links, 8.3 short names and aliases
        resolved), the typed one first and, when they differ, both; the protection question comes
        before the whitelist question for each. The first hit gives $false. A path that cannot be
        resolved, an empty one and every unexpected error give $false. Without -WhitelistState the
        state is read once per call, after the path was not refused before. Looks at this one path
        only; its descendants and parents are the business of the tree checks. Changes nothing.
    #>
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Path,
        [object]$WhitelistState = $null
    )

    $ErrorActionPreference = 'Stop'
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

        $lexical = $null
        try { if ($Path.IndexOf([char]0) -lt 0) { $lexical = [System.IO.Path]::GetFullPath($Path) } }
        catch { $lexical = $null }

        $final = Resolve-SwSafePath -Path $Path
        if ($null -eq $final) { return $false }

        $spellings = [System.Collections.Generic.List[string]]::new()
        if ($null -ne $lexical) { $spellings.Add($lexical) }
        if ($null -eq $lexical -or -not (Test-SwFileOpsSamePath -Left $lexical -Right ([string]$final))) { $spellings.Add([string]$final) }

        if ($null -eq $WhitelistState) { $WhitelistState = Get-SwWhitelistState }
        foreach ($spelling in $spellings) {
            if (Test-SwProtectedPath -Path $spelling -AlreadyResolved) { return $false }
            if (Test-SwWhitelisted -Path $spelling -State $WhitelistState) { return $false }
        }
        return $true
    }
    catch {
        Write-SwFileOpsDebug "path is not safe to touch, the check failed for ${Path}: $($_.Exception.Message)"
        return $false
    }
}

# ============================================================================
# File identity (snapshots)
# ============================================================================

function Get-SwPathSnapshot {
    <#
    .SYNOPSIS
        The file identity of an existing path and of every folder above it, or $null.
    .DESCRIPTION
        The result is a table: Path (normalized), Entries (the full path of every component from the
        drive root to the entry, each with its identity as text: volume serial number and file index)
        and AllowLeafLink. The identities are read without opening content, without following links
        and without holding a handle. $null, without an exception, for an empty or incomplete path
        (only drive-letter paths count; UNC, device and provider paths do not), for an entry or
        component that is missing or not readable, for a link above the entry, for the entry itself
        when it is a link and -AllowLeafLink is missing, and on hosts without the Windows file API
        (nothing is removable there).
    #>
    param(
        [Parameter(Position = 0)][string]$Path,
        [switch]$AllowLeafLink
    )

    try {
        if (-not (Test-SwBaseWindows)) { return $null }
        if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
        if ($Path.IndexOf([char]0) -ge 0) { return $null }
        if (-not [regex]::IsMatch($Path, '\A[A-Za-z]:[\\/]')) { return $null }
        if (-not (Initialize-SwFileOpsNative)) { return $null }

        $full = [System.IO.Path]::GetFullPath($Path)
        if ($full.Length -gt 3) { $full = $full.TrimEnd([char[]]@('\')) }

        $entries = @{}
        $current = $full
        $leaf = $true
        while (-not [string]::IsNullOrEmpty($current)) {
            [string]$identity = ''
            [bool]$isLink = $false
            if (-not [SwFileOpsNative]::Query($current, [ref]$identity, [ref]$isLink)) { return $null }
            # A link may be the entry (it is then unlinked, never entered), never one of its parents.
            if ($isLink -and ((-not $leaf) -or (-not $AllowLeafLink))) { return $null }
            $entries[$current] = $identity
            $leaf = $false
            $current = [System.IO.Path]::GetDirectoryName($current)
        }
        return @{ Path = $full; Entries = $entries; AllowLeafLink = [bool]$AllowLeafLink }
    }
    catch {
        Write-SwFileOpsDebug "no identity for ${Path}: $($_.Exception.Message)"
        return $null
    }
}

function Test-SwPathSnapshot {
    <#
    .SYNOPSIS
        True when the identity chain of a snapshot is still the same.
    .DESCRIPTION
        Forms one fresh snapshot with the same path and the same -AllowLeafLink, through one call of
        Get-SwPathSnapshot. True only when both exist and have the same keys with the same values.
        A $null snapshot, one without a path or entries, a fresh one that cannot be formed and every
        error give $false.
    #>
    param([Parameter(Position = 0)][object]$Snapshot)

    try {
        if ($null -eq $Snapshot) { return $false }
        $path = Get-SwFileOpsField $Snapshot 'Path'
        if ([string]::IsNullOrEmpty([string]$path)) { return $false }
        $old = Get-SwFileOpsField $Snapshot 'Entries'
        if ($old -isnot [System.Collections.IDictionary]) { return $false }
        $allow = [bool](Get-SwFileOpsField $Snapshot 'AllowLeafLink')

        $fresh = Get-SwPathSnapshot -Path ([string]$path) -AllowLeafLink:$allow
        if ($null -eq $fresh) { return $false }
        $now = Get-SwFileOpsField $fresh 'Entries'
        if ($now -isnot [System.Collections.IDictionary]) { return $false }
        if ($old.Count -ne $now.Count) { return $false }
        foreach ($key in $old.Keys) {
            if (-not $now.Contains($key)) { return $false }
            if (-not [string]::Equals([string]$old[$key], [string]$now[$key], [System.StringComparison]::Ordinal)) { return $false }
        }
        return $true
    }
    catch {
        Write-SwFileOpsDebug "identity test failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-SwFileOpsChildSnapshot {
    # The snapshot of a direct child of a folder whose snapshot is known: the entries of the parent plus
    # the identity of the child, without opening the parents again. Equal to what Get-SwPathSnapshot
    # -AllowLeafLink gives for the child. $null when that is not possible (a test double without
    # entries, a path that is not a direct child, no Windows file API); the caller then asks
    # Get-SwPathSnapshot.
    param($Parent, [string]$Path)

    try {
        $entries = Get-SwFileOpsField $Parent 'Entries'
        $parentPath = [string](Get-SwFileOpsField $Parent 'Path')
        if ($entries -isnot [System.Collections.IDictionary] -or [string]::IsNullOrEmpty($parentPath)) { return $null }
        if (-not (Test-SwBaseWindows)) { return $null }
        if (-not (Initialize-SwFileOpsNative)) { return $null }

        $full = [System.IO.Path]::GetFullPath($Path)
        if ($full.Length -gt 3) { $full = $full.TrimEnd([char[]]@('\')) }
        $above = [System.IO.Path]::GetDirectoryName($full)
        if ($null -eq $above -or -not (Test-SwFileOpsSamePath -Left $above -Right $parentPath)) { return $null }

        [string]$identity = ''
        [bool]$isLink = $false
        if (-not [SwFileOpsNative]::Query($full, [ref]$identity, [ref]$isLink)) { return $null }

        $copy = @{}
        foreach ($key in $entries.Keys) { $copy[$key] = $entries[$key] }
        $copy[$full] = $identity
        return @{ Path = $full; Entries = $copy; AllowLeafLink = $true }
    }
    catch { return $null }
}

function Test-SwReparsePoint {
    <#
    .SYNOPSIS
        True when the path exists and is a link (junction, symbolic link, mounted folder, cloud placeholder).
    .DESCRIPTION
        $false for an ordinary entry and for a path that is missing or not readable. The path is literal.
        Never throws.
    #>
    param([string]$Path)

    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
        $attributes = [System.IO.File]::GetAttributes($Path)
        return (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    }
    catch { return $false }
}

# ============================================================================
# Tree walk and sizes
# ============================================================================

function Get-SwTreeItems {
    <#
    .SYNOPSIS
        Every entry below a folder, one by one, hidden and system entries included.
    .DESCRIPTION
        The walk is its own: links (junctions, folder symbolic links) are listed but never entered, and
        Get-ChildItem -Recurse is not used because Windows PowerShell 5.1 follows links with it. An
        entry comes before its descendants. Each entry carries SweeprPathSnapshot, its identity
        (derived from the snapshot of its folder where possible). Every entered folder, the root
        included, is tested once with Test-SwPathSnapshot before it is listed.

        Throws, with the path and the reason, when the root has no identity or is not a folder or is
        a link, when an entered folder was replaced, when an entry has no identity, when the name of
        an entry changes under normalization (trailing dot or space), when the time budget
        ($script:SwWalkBudgetSeconds, default 15) is used up (checked before every folder and entry;
        0 stops every walk), and, without -SkipUnreadable, when a folder cannot be listed. With
        -SkipUnreadable such a folder stays empty. Entries given before the error stay given.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$SkipUnreadable
    )

    $ErrorActionPreference = 'Stop'
    $budget = Get-SwFileOpsWalkBudget
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $linkAttribute = [System.IO.FileAttributes]::ReparsePoint

    # The comparison is >= so that a budget of 0 stops every walk, also one over an empty folder.
    if ($clock.Elapsed.TotalSeconds -ge $budget) { throw "Cannot walk '$Path': the time budget of $budget seconds is used up." }
    if (-not [System.IO.Directory]::Exists($Path)) { throw "Cannot walk '$Path': it is not a folder." }
    if (Test-SwReparsePoint -Path $Path) { throw "Cannot walk '$Path': it is a link." }
    $rootSnapshot = Get-SwPathSnapshot -Path $Path
    if ($null -eq $rootSnapshot) { throw "Cannot walk '$Path': its identity is not available (it is not readable, or this host has no file identity)." }

    $pending = [System.Collections.Generic.Stack[object]]::new()
    $pending.Push(@{ Path = $Path; Snapshot = $rootSnapshot })
    while ($pending.Count -gt 0) {
        $folder = $pending.Pop()
        $folderPath = [string]$folder.Path
        if ($clock.Elapsed.TotalSeconds -ge $budget) { throw "Cannot walk '$folderPath': the time budget of $budget seconds is used up." }
        if (-not (Test-SwFileOpsUnchanged -Snapshot $folder.Snapshot)) { throw "Cannot walk '$folderPath': the folder was replaced during the walk." }

        try { $children = @(Get-ChildItem -LiteralPath $folderPath -Force -ErrorAction Stop) }
        catch {
            if ($SkipUnreadable) { continue }
            throw "Cannot list '$folderPath': $($_.Exception.Message)"
        }

        foreach ($child in $children) {
            if ($clock.Elapsed.TotalSeconds -ge $budget) { throw "Cannot walk '$folderPath': the time budget of $budget seconds is used up." }
            $childPath = [string]$child.FullName

            # An entry whose name does not survive normalization is not reachable under its own path.
            try { $normalizedName = [System.IO.Path]::GetFileName([System.IO.Path]::GetFullPath($childPath)) }
            catch { throw "Cannot walk '$childPath': its path cannot be normalized: $($_.Exception.Message)" }
            if (-not [string]::Equals($normalizedName, [string]$child.Name, [System.StringComparison]::Ordinal)) {
                throw "Cannot walk '$childPath': its name changes when the path is normalized."
            }

            $snapshot = Get-SwFileOpsChildSnapshot -Parent $folder.Snapshot -Path $childPath
            if ($null -eq $snapshot) { $snapshot = Get-SwPathSnapshot -Path $childPath -AllowLeafLink }
            if ($null -eq $snapshot) { throw "Cannot walk '$childPath': its identity is not available." }
            Add-Member -InputObject $child -NotePropertyName SweeprPathSnapshot -NotePropertyValue $snapshot -Force

            $child
            if ($child.PSIsContainer -and (($child.Attributes -band $linkAttribute) -eq 0)) {
                $pending.Push(@{ Path = $childPath; Snapshot = $snapshot })
            }
        }
    }
}

function Get-SwSafeDirectoryTreeItems {
    <#
    .SYNOPSIS
        Checks a folder before it is removed and gives its entries.
    .DESCRIPTION
        The result always has Success, Items, RootSnapshot and Reason. A folder that is a link gives
        Success with no items: it is removed as a link and nothing below it is listed. Otherwise every
        entry (the root is the caller's business) must pass Test-SwSafePath; the first one that does
        not stops the check and is named in Reason. The whitelist state is read once for the whole
        tree, or not at all when -WhitelistState is given. A folder without identity, a file, a walk
        that fails (including the time budget) and every error give Success $false. Never throws.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [object]$WhitelistState = $null
    )

    $failed = @{ Success = $false; Items = @(); RootSnapshot = $null; Reason = '' }
    try {
        $ErrorActionPreference = 'Stop'
        $snapshot = Get-SwPathSnapshot -Path $Path -AllowLeafLink
        if ($null -eq $snapshot) {
            $failed.Reason = "${Path}: the file identity is not available"
            return $failed
        }
        if (-not [System.IO.Directory]::Exists($Path)) {
            $failed.Reason = "${Path}: not a folder"
            return $failed
        }
        if (Test-SwReparsePoint -Path $Path) {
            return @{ Success = $true; Items = @(); RootSnapshot = $snapshot; Reason = '' }
        }

        try { $items = @(Get-SwTreeItems -Path $Path) }
        catch {
            $failed.Reason = "${Path}: the folder cannot be listed completely: $($_.Exception.Message)"
            return $failed
        }

        if ($null -eq $WhitelistState) { $WhitelistState = Get-SwWhitelistState }
        foreach ($item in $items) {
            $entry = [string]$item.FullName
            if (-not (Test-SwFileOpsSafe -Path $entry -State $WhitelistState)) {
                $failed.Reason = "protected or whitelisted entry inside: $entry"
                return $failed
            }
        }
        return @{ Success = $true; Items = $items; RootSnapshot = $snapshot; Reason = '' }
    }
    catch {
        $failed.Items = @()
        $failed.RootSnapshot = $null
        $failed.Reason = "${Path}: $($_.Exception.Message)"
        return $failed
    }
}

function Get-SwValidatedTreeSize {
    <#
    .SYNOPSIS
        Sum of the lengths of the files in the items of a validated tree, as a [long].
    .DESCRIPTION
        Folders and $null entries count nothing; a missing or empty Items gives 0. Touches no file and
        walks nothing: the removal paths measure a folder only this way, so that a spent time budget
        cannot turn into "0 bytes" for a folder that is about to be removed.
    #>
    param([hashtable]$Tree)

    try {
        if ($null -eq $Tree -or -not $Tree.ContainsKey('Items')) { return [long]0 }
        $sum = [long]0
        foreach ($item in @($Tree['Items'])) {
            if ($null -eq $item) { continue }
            if ((Get-SwFileOpsField $item 'PSIsContainer') -eq $true) { continue }
            $length = Get-SwFileOpsField $item 'Length'
            if ($null -eq $length) { continue }
            $sum += [long]$length
        }
        return $sum
    }
    catch { return [long]0 }
}

function Get-SwPathSize {
    <#
    .SYNOPSIS
        Bytes of a file, or of all files below a folder (logical length, not space on disk).
    .DESCRIPTION
        0 means empty or not measurable: a missing path, a link (a link is not Sweepr's data and is never
        followed), and every failure of the walk (time budget, replaced folder, no identity, no Windows
        file API) all give 0 without an exception. A folder is measured by one walk that skips folders it
        cannot read; folders and links inside count 0.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        if ([System.IO.Directory]::Exists($Path)) {
            if (Test-SwReparsePoint -Path $Path) { return [long]0 }
            $sum = [long]0
            foreach ($item in @(Get-SwTreeItems -Path $Path -SkipUnreadable)) {
                if ($null -eq $item) { continue }
                if ((Get-SwFileOpsField $item 'PSIsContainer') -eq $true) { continue }
                $attributes = Get-SwFileOpsField $item 'Attributes'
                if ($null -ne $attributes -and (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) { continue }
                $length = Get-SwFileOpsField $item 'Length'
                if ($null -ne $length) { $sum += [long]$length }
            }
            return $sum
        }
        if ([System.IO.File]::Exists($Path)) {
            if (Test-SwReparsePoint -Path $Path) { return [long]0 }
            return [long]([System.IO.FileInfo]::new($Path)).Length
        }
        return [long]0
    }
    catch {
        Write-SwFileOpsDebug "size of ${Path} not measured: $($_.Exception.Message)"
        return [long]0
    }
}

function Get-SwPathSizeKB {
    <#
    .SYNOPSIS
        Get-SwPathSize in whole kilobytes, rounded up. 0 for empty or not measurable.
    #>
    param([string]$Path)

    try { return (ConvertTo-SwFileOpsKilobytes -Bytes (Get-SwPathSize -Path $Path)) }
    catch { return [long]0 }
}

function Add-SwNotMeasured {
    <#
    .SYNOPSIS
        Notes in the collector that something could not be measured, once per name.
    .DESCRIPTION
        Does nothing without $script:NotMeasuredCollector. The entry has Section (the current section),
        Name and Reason. Never throws.
    #>
    param([string]$Name, [string]$Reason)

    try {
        try { $collector = $script:NotMeasuredCollector } catch { $collector = $null }
        if ($null -eq $collector -or $collector -isnot [System.Collections.IList]) { return }
        # Not @($collector): a list made with New-Object cannot be wrapped that way.
        foreach ($entry in $collector) {
            if ($null -ne $entry -and [string]::Equals([string](Get-SwFileOpsField $entry 'Name'), $Name, [System.StringComparison]::Ordinal)) { return }
        }
        try { $section = [string]$script:CurrentSection.Name } catch { $section = '' }
        [void]$collector.Add([pscustomobject]@{ Section = $section; Name = $Name; Reason = $Reason })
    }
    catch { Write-SwFileOpsDebug "not-measured note lost: $($_.Exception.Message)" }
}

# ============================================================================
# Dry-run state and cleanup statistics
# ============================================================================

function Set-SwDryRunMode {
    <#
    .SYNOPSIS
        Switches the dry-run state on or off. Without a value it switches off.
    #>
    param([Parameter(Position = 0)][bool]$Enabled = $false)

    $script:SweeprDryRunMode = $Enabled
}

function Test-SwDryRunMode {
    <#
    .SYNOPSIS
        True while nothing may be changed.
    .DESCRIPTION
        Read at every call, whether it was set here or directly. A state that is missing, $null or not
        readable counts as dry run: unknown means do not remove.
    #>
    try { $value = $script:SweeprDryRunMode }
    catch { return $true }
    if ($null -eq $value) { return $true }
    try { return [bool]$value }
    catch { return $true }
}

function Get-SwCleanupStats {
    <#
    .SYNOPSIS
        The statistics as one table: TotalSizeKB, TotalSizeHuman, FilesCleaned, TotalItems, OwnerCleanups.
    .DESCRIPTION
        A counter that is missing counts as 0. Dry-run results are counted like real ones, so the summary
        matches the preview.
    #>
    try { $kilobytes = [long]$script:TotalSizeCleaned } catch { $kilobytes = [long]0 }
    try { $files = [int]$script:FilesCleaned } catch { $files = 0 }
    try { $items = [int]$script:TotalItems } catch { $items = 0 }
    try { $owners = [int]$script:OwnerCleanups } catch { $owners = 0 }
    return @{
        TotalSizeKB    = $kilobytes
        TotalSizeHuman = (Format-SwByteSize -Bytes ($kilobytes * 1024))
        FilesCleaned   = $files
        TotalItems     = $items
        OwnerCleanups  = $owners
    }
}

function Reset-SwCleanupStats {
    <#
    .SYNOPSIS
        Sets the four counters to 0. Dry-run state, collectors and list file stay as they are.
    #>
    $script:TotalSizeCleaned = 0
    $script:FilesCleaned = 0
    $script:TotalItems = 0
    $script:OwnerCleanups = 0
}

function Add-SwDryRunListEntries {
    <#
    .SYNOPSIS
        Notes what a preview would remove: in the collector when there is one, else in the list file.
    .DESCRIPTION
        Without paths nothing happens. With $script:DryRunCollector set to a list, one entry per path is
        added (Section, Description, Path, SizeBytes, Count; a missing size is 0, a missing count 1) and
        the file stays alone. Otherwise, when $script:ExportListFile names a file that exists, a block is
        appended: "# <description>", one line per path, an empty line; CRLF, UTF-8 without a byte order
        mark, so a line can be copied into the whitelist. The file is never created or shortened. A
        write failure is reported through Write-Debug and nothing else. Never throws.
    #>
    param(
        [string]$Description,
        [AllowNull()][AllowEmptyCollection()][string[]]$Paths,
        [long[]]$SizeBytes = @(),
        [int[]]$FileCounts = @()
    )

    try {
        $list = @($Paths | Where-Object { $null -ne $_ })
        if ($list.Count -eq 0) { return }

        try { $collector = $script:DryRunCollector } catch { $collector = $null }
        if ($collector -is [System.Collections.Generic.List[object]]) {
            try { $section = [string]$script:CurrentSection.Name } catch { $section = '' }
            for ($index = 0; $index -lt $list.Count; $index++) {
                $bytes = [long]0
                if ($index -lt @($SizeBytes).Count) { $bytes = [long]@($SizeBytes)[$index] }
                $count = 1
                if ($index -lt @($FileCounts).Count) { $count = [int]@($FileCounts)[$index] }
                $collector.Add([pscustomobject]@{
                        Section     = [string]$section
                        Description = [string]$Description
                        Path        = [string]$list[$index]
                        SizeBytes   = [long]$bytes
                        Count       = [int]$count
                    })
            }
            return
        }

        try { $file = [string]$script:ExportListFile } catch { $file = '' }
        if ([string]::IsNullOrEmpty($file)) { return }
        if (-not [System.IO.File]::Exists($file)) { return }

        $text = '# ' + $Description + "`r`n" + (($list | ForEach-Object { [string]$_ }) -join "`r`n") + "`r`n`r`n"
        [System.IO.File]::AppendAllText($file, $text, [System.Text.UTF8Encoding]::new($false))
    }
    catch { Write-SwFileOpsDebug "preview list not written: $($_.Exception.Message)" }
}

# ============================================================================
# Removal of single entries and trees
# ============================================================================

function Remove-SwTreeEntry {
    <#
    .SYNOPSIS
        Removes exactly one entry, never recursively. Throws when the entry was not removed.
    .DESCRIPTION
        The kind is decided at the moment of the call. A folder (a link included) loses its read-only
        attribute if it has one and is then removed with Directory.Delete(path, $false): a folder with
        entries fails and keeps them, a link loses only the link. Remove-Item is never used on a folder:
        on a folder with entries it asks, and a Yes removes content nobody checked. A file (a file link
        included) goes through Remove-Item -LiteralPath -Force. There is no retry and no fallback. In a
        dry run nothing is removed and it throws.
    #>
    param([string]$Path)

    $ErrorActionPreference = 'Stop'
    if (Test-SwDryRunMode) { throw "Not removing '$Path': this is a dry run." }
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Not removing: no path given.' }

    $attributes = [System.IO.File]::GetAttributes($Path)
    $isFolder = ((($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) -or [System.IO.Directory]::Exists($Path))
    if ($isFolder) {
        if (($attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
            $writable = [int]$attributes -band (-bnot [int][System.IO.FileAttributes]::ReadOnly)
            [System.IO.File]::SetAttributes($Path, [System.IO.FileAttributes]$writable)
        }
        # Other hosts unlink a folder link with File.Delete; on Windows Directory.Delete removes the link.
        if ((($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) -and -not (Test-SwBaseWindows)) {
            [System.IO.File]::Delete($Path)
        }
        else {
            [System.IO.Directory]::Delete($Path, $false)
        }
        return
    }
    Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
}

function Remove-SwDirectoryTree {
    <#
    .SYNOPSIS
        Removes a folder with everything in it, after every entry was checked. Gives $true only when the
        folder and all its entries are gone.
    .DESCRIPTION
        With -ValidatedTree (the result of Get-SwSafeDirectoryTreeItems) nothing is listed again,
        otherwise the folder is listed and checked here; the whitelist state is read once unless given.
        Before the first removal the folder is refused (false, Report.Reason starts with "refused: ")
        when the tree is not successful, the root is not safe, or the root identity changed. A
        -CanRemove that does not give exactly one true leaves everything in place and sets
        Report.OwnerHeld. Entries go longest path first, each through Remove-SwTreeEntry and only right
        after Test-SwSafePath and Test-SwPathSnapshot passed for it; the first failure stops everything
        (Report.Reason "stopped at <path>: <message>"). The root goes last, after both checks passed
        again. An entry that appeared after the validation is not in the tree and is never removed; the
        root then cannot be removed and stays. -Report gets Removed, Total (both without the root), Reason
        and OwnerHeld. Writes no operations log line; the callers do.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [hashtable]$ValidatedTree,
        [hashtable]$Report,
        [object]$WhitelistState,
        [scriptblock]$CanRemove
    )

    $ErrorActionPreference = 'Stop'
    if ($null -eq $Report) { $Report = @{} }
    $Report['Removed'] = 0
    $Report['Total'] = 0
    $Report['Reason'] = ''
    $Report['OwnerHeld'] = $false

    try {
        if (Test-SwDryRunMode) {
            $Report['Reason'] = 'refused: this is a dry run, nothing is removed'
            return $false
        }
        if (-not [System.IO.Directory]::Exists($Path)) {
            $Report['Reason'] = "refused: not a folder: $Path"
            return $false
        }
        if ($null -eq $WhitelistState) { $WhitelistState = Get-SwWhitelistState }

        $tree = $ValidatedTree
        if ($null -eq $tree) { $tree = Get-SwSafeDirectoryTreeItems -Path $Path -WhitelistState $WhitelistState }
        if ((Get-SwFileOpsField $tree 'Success') -ne $true) {
            $reason = [string](Get-SwFileOpsField $tree 'Reason')
            if ([string]::IsNullOrEmpty($reason)) { $reason = "$Path could not be checked" }
            $Report['Reason'] = "refused: $reason"
            return $false
        }

        $rootSnapshot = Get-SwFileOpsField $tree 'RootSnapshot'
        $snapshotPath = [string](Get-SwFileOpsField $rootSnapshot 'Path')
        if ($snapshotPath.Length -gt 0 -and -not (Test-SwFileOpsSamePath -Left $snapshotPath -Right $Path)) {
            $Report['Reason'] = "refused: the checked tree belongs to $snapshotPath, not to $Path"
            return $false
        }
        if (-not (Test-SwFileOpsSafe -Path $Path -State $WhitelistState)) {
            $Report['Reason'] = "refused: protected or whitelisted: $Path"
            return $false
        }
        if (-not (Test-SwFileOpsUnchanged -Snapshot $rootSnapshot)) {
            $Report['Reason'] = "refused: $Path is not the folder that was checked"
            return $false
        }

        $items = @(@(Get-SwFileOpsField $tree 'Items') | Where-Object { $null -ne $_ })
        $Report['Total'] = $items.Count

        # Asked once, after the checks and before the first removal: what the owner of the folder is
        # doing now decides, not what it was doing when the list was made.
        if ($null -ne $CanRemove -and -not (Test-SwFileOpsCondition -Block $CanRemove)) {
            $Report['OwnerHeld'] = $true
            $Report['Reason'] = "refused: the owner of $Path is active or unknown"
            return $false
        }

        # Longest path first: a child is always longer than its parent, so every folder is empty by
        # the time it is reached.
        $ordered = @($items | Sort-Object -Property { ([string]$_.FullName).Length } -Descending)
        foreach ($item in $ordered) {
            $entry = [string]$item.FullName
            $snapshot = Get-SwFileOpsField $item 'SweeprPathSnapshot'
            if (-not (Test-SwFileOpsSafe -Path $entry -State $WhitelistState)) {
                $Report['Reason'] = "stopped at ${entry}: it is protected or whitelisted now"
                return $false
            }
            if (-not (Test-SwFileOpsUnchanged -Snapshot $snapshot)) {
                $Report['Reason'] = "stopped at ${entry}: it is not the entry that was checked"
                return $false
            }
            try { Remove-SwTreeEntry -Path $entry }
            catch {
                $Report['Reason'] = "stopped at ${entry}: $($_.Exception.Message)"
                return $false
            }
            $Report['Removed'] = [int]$Report['Removed'] + 1
        }

        if (-not (Test-SwFileOpsSafe -Path $Path -State $WhitelistState) -or -not (Test-SwFileOpsUnchanged -Snapshot $rootSnapshot)) {
            $Report['Reason'] = "kept the folder ${Path}: it changed or is protected now"
            return $false
        }
        try { Remove-SwTreeEntry -Path $Path }
        catch {
            $Report['Reason'] = "kept the folder ${Path}: $($_.Exception.Message)"
            return $false
        }
        return $true
    }
    catch {
        $Report['Reason'] = "stopped at ${Path}: $($_.Exception.Message)"
        return $false
    }
}

function Move-SwItemToRecycleBin {
    <#
    .SYNOPSIS
        Moves a checked entry to the Recycle Bin. Throws on any failure and never deletes for good.
    .DESCRIPTION
        Always checks first, before any shell call: the path of the snapshot (the entry that was
        verified) must pass Test-SwSafePath with a freshly read whitelist state and Test-SwPathSnapshot;
        for a folder a new tree check (same state) and the identity test again follow, so a protected
        or whitelisted entry that appeared meanwhile refuses the whole folder. Then the entry must be on
        a local fixed drive; the move is the shell operation ITransferSource.RecycleItem on a thread of
        its own. It counts as done only when the shell reports the new place and the source path no
        longer exists. There is no fallback to a route that deletes or asks.
    #>
    param([string]$Path, [object]$Snapshot)

    $ErrorActionPreference = 'Stop'
    $target = [string](Get-SwFileOpsField $Snapshot 'Path')
    if ([string]::IsNullOrWhiteSpace($target)) { throw "Not moving '$Path' to the Recycle Bin: there is no checked snapshot of it." }
    if (-not [string]::IsNullOrWhiteSpace($Path) -and -not (Test-SwFileOpsSamePath -Left $Path -Right $target)) {
        throw "Not moving '$Path' to the Recycle Bin: the snapshot belongs to '$target'."
    }

    $state = Get-SwWhitelistState
    if (-not (Test-SwFileOpsSafe -Path $target -State $state)) { throw "Not moving '$target' to the Recycle Bin: it is protected or whitelisted." }
    if (-not (Test-SwFileOpsUnchanged -Snapshot $Snapshot)) { throw "Not moving '$target' to the Recycle Bin: it is not the entry that was checked." }
    if ([System.IO.Directory]::Exists($target)) {
        $tree = Get-SwSafeDirectoryTreeItems -Path $target -WhitelistState $state
        if ((Get-SwFileOpsField $tree 'Success') -ne $true) {
            throw "Not moving '$target' to the Recycle Bin: $([string](Get-SwFileOpsField $tree 'Reason'))"
        }
        if (-not (Test-SwFileOpsUnchanged -Snapshot $Snapshot)) { throw "Not moving '$target' to the Recycle Bin: it changed while it was checked." }
    }

    if (-not (Test-SwBaseWindows)) { throw 'The Recycle Bin is available on Windows only.' }
    try { $drive = [System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($target)) }
    catch { throw "Not moving '$target' to the Recycle Bin: it is not on a local drive." }
    if ($drive.DriveType -ne [System.IO.DriveType]::Fixed) {
        throw "Not moving '$target' to the Recycle Bin: only a fixed local drive has one that can take it."
    }
    if (-not (Initialize-SwFileOpsNative)) { throw 'The Recycle Bin call is not available in this session.' }

    $place = [SwFileOpsNative]::RecycleItem($target)
    if ([string]::IsNullOrEmpty($place)) { throw "The shell did not say where '$target' went." }
    if ([System.IO.File]::Exists($target) -or [System.IO.Directory]::Exists($target)) {
        throw "The move of '$target' to the Recycle Bin was not completed: the entry is still there."
    }
}

# ============================================================================
# Remove-SwItem, Remove-SwItems and the helpers they share
# ============================================================================

function Get-SwFileOpsCandidate {
    # The checks that come before a removal or a preview of one path, in this order: complete path,
    # safe, exists, identity, tree check for a folder (a refusal is logged as SKIPPED in a real run),
    # measurement, safe and identity again, the guard or condition, identity once more. Gives a table
    # (Path, Snapshot, IsFolder, Tree, Bytes, FileCount) or $null when the path is to be left alone.
    param([string]$Path, [object]$State, [bool]$Recycle, [scriptblock]$Condition, [bool]$ConditionTakesPath)

    if (-not (Test-SwFileOpsCompletePath -Path $Path)) { return $null }
    if (-not (Test-SwFileOpsSafe -Path $Path -State $State)) { return $null }
    if (-not ([System.IO.File]::Exists($Path) -or [System.IO.Directory]::Exists($Path))) { return $null }

    # A link may be removed as a link; the Recycle Bin path refuses links, so it asks without the switch.
    if ($Recycle) { $snapshot = Get-SwPathSnapshot -Path $Path }
    else { $snapshot = Get-SwPathSnapshot -Path $Path -AllowLeafLink }
    if ($null -eq $snapshot) { return $null }

    $isFolder = [System.IO.Directory]::Exists($Path)
    $tree = $null
    if ($isFolder) {
        $tree = Get-SwSafeDirectoryTreeItems -Path $Path -WhitelistState $State
        if ((Get-SwFileOpsField $tree 'Success') -ne $true) {
            if (-not (Test-SwDryRunMode)) {
                $reason = [string](Get-SwFileOpsField $tree 'Reason')
                if ([string]::IsNullOrEmpty($reason)) { $reason = 'the folder could not be checked' }
                Write-SwFileOpsOperation -Action 'SKIPPED' -Path $Path -Detail "refused: $reason"
            }
            return $null
        }
        # A folder is measured from the entries that were checked, never by a second walk.
        $bytes = ConvertTo-SwFileOpsBytes (Get-SwValidatedTreeSize -Tree $tree)
        $fileCount = 0
        foreach ($item in @(Get-SwFileOpsField $tree 'Items')) {
            if ($null -ne $item -and (Get-SwFileOpsField $item 'PSIsContainer') -ne $true) { $fileCount++ }
        }
    }
    else {
        $bytes = ConvertTo-SwFileOpsBytes (Get-SwPathSize -Path $Path)
        $fileCount = 1
    }

    # The measurement takes time; what was true before it is asked again.
    if (-not (Test-SwFileOpsSafe -Path $Path -State $State)) { return $null }
    if (-not (Test-SwFileOpsUnchanged -Snapshot $snapshot)) { return $null }

    if ($null -ne $Condition) {
        if ($ConditionTakesPath) { $allowed = Test-SwFileOpsCondition -Block $Condition -Arguments @($Path) }
        else { $allowed = Test-SwFileOpsCondition -Block $Condition }
        if (-not $allowed) { return $null }
    }
    # The condition may take a while and run code of its own: the identity is asked once more.
    if (-not (Test-SwFileOpsUnchanged -Snapshot $snapshot)) { return $null }

    return @{ Path = $Path; Snapshot = $snapshot; IsFolder = $isFolder; Tree = $tree; Bytes = $bytes; FileCount = $fileCount }
}

function Invoke-SwFileOpsRemoval {
    # Removes one path that passed Get-SwFileOpsCandidate, in a real run, and writes the log line of the
    # result. Gives a table: Removed ($true only for a complete removal) and Skipped ($true when a
    # folder was refused before its first removal). Never throws.
    param($Candidate, [object]$State, [scriptblock]$CanRemove)

    $path = [string]$Candidate.Path
    $result = @{ Removed = $false; Skipped = $false }
    try {
        if (-not $Candidate.IsFolder) {
            # Unmatched kind or identity right before the removal: a folder or link took the place.
            if ([System.IO.Directory]::Exists($path)) { return $result }
            if (-not (Test-SwFileOpsUnchanged -Snapshot $Candidate.Snapshot)) { return $result }
            try { Remove-SwTreeEntry -Path $path }
            catch {
                Write-SwFileOpsOperation -Action 'FAILED' -Path $path -Detail ([string]$_.Exception.Message)
                return $result
            }
            Write-SwFileOpsOperation -Action 'REMOVED' -Path $path -Detail (Format-SwByteSize -Bytes $Candidate.Bytes)
            $result.Removed = $true
            return $result
        }

        $report = @{ Removed = 0; Total = 0; Reason = ''; OwnerHeld = $false }
        $arguments = @{ Path = $path; ValidatedTree = $Candidate.Tree; Report = $report; WhitelistState = $State }
        if ($null -ne $CanRemove) { $arguments['CanRemove'] = $CanRemove }
        $outcome = @(Remove-SwDirectoryTree @arguments)
        if ($outcome.Count -ge 1 -and $outcome[$outcome.Count - 1] -is [bool] -and $outcome[$outcome.Count - 1] -eq $true) {
            Write-SwFileOpsOperation -Action 'REMOVED' -Path $path -Detail (Format-SwByteSize -Bytes $Candidate.Bytes)
            $result.Removed = $true
            return $result
        }

        $reason = [string]$report['Reason']
        $refused = ($report['OwnerHeld'] -eq $true) -or (([int]$report['Removed'] -eq 0) -and $reason.StartsWith('refused: ', [System.StringComparison]::Ordinal))
        if ($refused) {
            # Nothing was removed: the folder was refused, not broken.
            Write-SwFileOpsOperation -Action 'SKIPPED' -Path $path -Detail $reason
            $result.Skipped = $true
            return $result
        }
        $detail = "incomplete: removed $([int]$report['Removed']) of $([int]$report['Total']) entries"
        if ($reason.Length -gt 0) { $detail += "; $reason" }
        Write-SwFileOpsOperation -Action 'FAILED' -Path $path -Detail $detail
        return $result
    }
    catch {
        Write-SwFileOpsDebug "removal of ${path} ended with an error: $($_.Exception.Message)"
        return $result
    }
}

function Remove-SwItem {
    <#
    .SYNOPSIS
        Removes one file or folder, or moves it to the Recycle Bin, or in a dry run only previews it.
    .DESCRIPTION
        Gives exactly one [bool]: $true for removed, recycled or previewed, $false for everything else, and
        writes nothing else to the pipeline. The checks run in this order and every refusal before the
        removal is silent: complete path, Test-SwSafePath (whitelist state read once), exists, identity
        (-AllowLeafLink unless -Recycle), tree check for a folder (a refusal is a SKIPPED log line in a
        real run), measurement (Get-SwValidatedTreeSize for a folder, Get-SwPathSize for a file), safety
        and identity again, -Guard (exactly one [bool] true, also in a dry run), identity again. Then a
        dry run counts and previews; a real run removes (a folder through Remove-SwDirectoryTree) or, with
        -Recycle, hands the entry to Move-SwItemToRecycleBin, which has no fallback to deleting. The log
        lines are REMOVED, RECYCLED, FAILED and SKIPPED; the counters grow only for a complete success.
        -Force and -Recurse are accepted for old callers and change nothing: a folder is always checked
        and never removed recursively.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Description = "",
        [switch]$Force,
        [switch]$Recurse,
        [switch]$Recycle,
        [scriptblock]$Guard
    )

    try {
        $ErrorActionPreference = 'Stop'
        if (-not (Test-SwFileOpsCompletePath -Path $Path)) { return $false }
        $state = Get-SwWhitelistState
        $candidate = Get-SwFileOpsCandidate -Path $Path -State $state -Recycle ([bool]$Recycle) -Condition $Guard -ConditionTakesPath $true
        if ($null -eq $candidate) { return $false }

        $name = $Description
        if ([string]::IsNullOrEmpty($name)) { $name = Get-SwFileOpsLeaf -Path $Path }
        $size = Format-SwByteSize -Bytes $candidate.Bytes
        $kilobytes = [long]0
        if (-not $Recycle) { $kilobytes = ConvertTo-SwFileOpsKilobytes -Bytes $candidate.Bytes }

        if (Test-SwDryRunMode) {
            if ($Recycle -and $candidate.IsFolder) {
                # The preview refuses what the real Recycle Bin path would refuse: it takes the whole folder.
                $again = Get-SwSafeDirectoryTreeItems -Path $Path -WhitelistState $state
                if ((Get-SwFileOpsField $again 'Success') -ne $true) { return $false }
                if (-not (Test-SwFileOpsUnchanged -Snapshot $candidate.Snapshot)) { return $false }
            }
            Add-SwFileOpsCount -SizeKB $kilobytes -Paths 1 -Items 1
            Write-SwFileOpsLine -Kind 'DryRun' -Message "$name ($size), preview"
            Set-SwFileOpsActivity
            try { Add-SwDryRunListEntries -Description $name -Paths @($Path) -SizeBytes @([long]$candidate.Bytes) -FileCounts @([int]$candidate.FileCount) }
            catch { Write-SwFileOpsDebug "preview list not written: $($_.Exception.Message)" }
            return $true
        }

        if ($Recycle) {
            try { Move-SwItemToRecycleBin -Path $Path -Snapshot $candidate.Snapshot }
            catch {
                $message = [string]$_.Exception.Message
                try { Write-Warning "Sweepr could not move '$Path' to the Recycle Bin and left it where it is. Check by hand what is left of it." }
                catch { Write-SwFileOpsDebug "warning not shown: $($_.Exception.Message)" }
                Write-SwFileOpsOperation -Action 'FAILED' -Path $Path -Detail $message
                return $false
            }
            Write-SwFileOpsOperation -Action 'RECYCLED' -Path $Path -Detail $size
            Add-SwFileOpsCount -SizeKB 0 -Paths 1 -Items 1
            Write-SwFileOpsLine -Kind 'Success' -Message "$name ($size), moved to the Recycle Bin"
            Set-SwFileOpsActivity
            return $true
        }

        $outcome = Invoke-SwFileOpsRemoval -Candidate $candidate -State $state -CanRemove $null
        if (-not $outcome.Removed) { return $false }
        Add-SwFileOpsCount -SizeKB $kilobytes -Paths 1 -Items 1
        Write-SwFileOpsLine -Kind 'Success' -Message "$name ($size)"
        Set-SwFileOpsActivity
        return $true
    }
    catch {
        Write-SwFileOpsDebug "nothing removed for ${Path}: $($_.Exception.Message)"
        return $false
    }
}

function Remove-SwItems {
    <#
    .SYNOPSIS
        Removes a list of files and folders, or previews them. Writes nothing to the pipeline.
    .DESCRIPTION
        The same checks as Remove-SwItem for every path, in the order of the list, with the whitelist
        state read once per call. Empty and incomplete paths, protected or whitelisted paths, paths that
        do not exist or have no identity and paths that fail a re-check or -CanRemove are skipped silently
        and not counted. -CanRemove (exactly one [bool] true) is asked after the measurement, also in a
        dry run, and never for a path the safety checks refused. A folder with a protected or whitelisted
        entry inside is a SKIPPED log line in a real run; an owner that holds a folder, too. A folder
        that breaks halfway is a FAILED line and the next path goes on. When at least one path was
        removed (or, in a dry run, noted), one summary follows: the sum of the bytes rounded up to
        kilobytes, one count per path, one item, one console line, and in a dry run one set of list
        entries under the description as given.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Paths,
        [string]$Description = 'Items',
        [scriptblock]$CanRemove
    )

    try {
        $ErrorActionPreference = 'Stop'
        $state = Get-SwWhitelistState
        $dry = Test-SwDryRunMode
        $hits = [System.Collections.Generic.List[object]]::new()

        foreach ($path in @($Paths)) {
            try {
                if ([string]::IsNullOrWhiteSpace($path)) { continue }
                $candidate = Get-SwFileOpsCandidate -Path $path -State $state -Recycle $false -Condition $CanRemove -ConditionTakesPath $false
                if ($null -eq $candidate) { continue }
                if (-not $dry) {
                    $outcome = Invoke-SwFileOpsRemoval -Candidate $candidate -State $state -CanRemove $CanRemove
                    if (-not $outcome.Removed) { continue }
                }
                $hits.Add([pscustomobject]@{ Path = $path; Bytes = [long]$candidate.Bytes; FileCount = [int]$candidate.FileCount })
            }
            catch { Write-SwFileOpsDebug "skipped ${path}: $($_.Exception.Message)" }
        }
        if ($hits.Count -eq 0) { return }

        [long]$bytes = 0
        foreach ($hit in $hits) { $bytes += $hit.Bytes }
        Add-SwFileOpsCount -SizeKB (ConvertTo-SwFileOpsKilobytes -Bytes $bytes) -Paths $hits.Count -Items 1

        $noun = 'items'
        if ($hits.Count -eq 1) { $noun = 'item' }
        $summary = "${Description}: $($hits.Count) $noun ($(Format-SwByteSize -Bytes $bytes))"
        if ($dry) { Write-SwFileOpsLine -Kind 'DryRun' -Message "$summary, preview" }
        else { Write-SwFileOpsLine -Kind 'Success' -Message $summary }
        Set-SwFileOpsActivity

        if ($dry) {
            try {
                Add-SwDryRunListEntries -Description $Description -Paths ([string[]]@($hits | ForEach-Object { $_.Path })) `
                    -SizeBytes ([long[]]@($hits | ForEach-Object { $_.Bytes })) -FileCounts ([int[]]@($hits | ForEach-Object { $_.FileCount }))
            }
            catch { Write-SwFileOpsDebug "preview list not written: $($_.Exception.Message)" }
        }
    }
    catch { Write-SwFileOpsDebug "removal list ended with an error: $($_.Exception.Message)" }
}

# ============================================================================
# Clear-SwDirectoryContents and Remove-SwOldFiles
# ============================================================================

function Clear-SwDirectoryContents {
    <#
    .SYNOPSIS
        Empties a folder and keeps it. Writes nothing to the pipeline.
    .DESCRIPTION
        Does nothing, silently, for a path that is not complete, does not exist, is a file or is a link, for
        a root that is not safe, for a -CanRemove that does not give exactly one [bool] true (asked once,
        before anything is listed), for a root without identity (asked without -AllowLeafLink), when the
        listing fails or the root changed while it was listed. The direct children, hidden ones included,
        go to Remove-SwItems with the description (empty means the name of the folder) and -CanRemove;
        protected children are skipped there, children with protected content are refused.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Description = "",
        [scriptblock]$CanRemove
    )

    try {
        $ErrorActionPreference = 'Stop'
        if (-not (Test-SwFileOpsCompletePath -Path $Path)) { return }
        if (-not [System.IO.Directory]::Exists($Path)) { return }
        if (Test-SwReparsePoint -Path $Path) { return }

        $state = Get-SwWhitelistState
        if (-not (Test-SwFileOpsSafe -Path $Path -State $state)) { return }
        if ($null -ne $CanRemove -and -not (Test-SwFileOpsCondition -Block $CanRemove)) { return }

        $snapshot = Get-SwPathSnapshot -Path $Path
        if ($null -eq $snapshot) { return }

        $children = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)
        if (-not (Test-SwFileOpsUnchanged -Snapshot $snapshot)) { return }
        if ($children.Count -eq 0) { return }

        $name = $Description
        if ([string]::IsNullOrEmpty($name)) { $name = Get-SwFileOpsLeaf -Path $Path }
        $arguments = @{ Paths = [string[]]@($children | ForEach-Object { [string]$_.FullName }); Description = $name }
        if ($null -ne $CanRemove) { $arguments['CanRemove'] = $CanRemove }
        Remove-SwItems @arguments
    }
    catch { Write-SwFileOpsDebug "folder not emptied: $($_.Exception.Message)" }
}

function Remove-SwOldFiles {
    <#
    .SYNOPSIS
        Removes the files directly in a folder that are older than a number of days. Writes nothing to the
        pipeline.
    .DESCRIPTION
        Only files, not folders and not below them, whose last write time is strictly before now minus
        -DaysOld days (now from Get-Date); -Filter is a name filter; hidden and system files count. A
        negative -DaysOld removes nothing. The root must be complete, existing, a folder and not a link,
        and have an identity (asked without -AllowLeafLink) that still holds after the listing; the root
        itself is not asked about Test-SwSafePath, every file is. The files go to Remove-SwItems with the
        description plus the days.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$DaysOld = 7,
        [string]$Filter = '*',
        [string]$Description = 'Old files'
    )

    try {
        $ErrorActionPreference = 'Stop'
        if ($DaysOld -lt 0) { return }
        if (-not (Test-SwFileOpsCompletePath -Path $Path)) { return }
        if (-not [System.IO.Directory]::Exists($Path)) { return }
        if (Test-SwReparsePoint -Path $Path) { return }
        $snapshot = Get-SwPathSnapshot -Path $Path
        if ($null -eq $snapshot) { return }

        $cutoff = (Get-Date).AddDays(-$DaysOld)
        # The provider filter alone matches more than its pattern in Windows PowerShell 5.1 (short names),
        # so the name is matched again.
        $files = @(Get-ChildItem -LiteralPath $Path -Filter $Filter -Force -ErrorAction Stop |
                Where-Object { (-not $_.PSIsContainer) -and ($_.Name -like $Filter) -and ($_.LastWriteTime -lt $cutoff) })
        if (-not (Test-SwFileOpsUnchanged -Snapshot $snapshot)) { return }
        if ($files.Count -eq 0) { return }

        Remove-SwItems -Paths ([string[]]@($files | ForEach-Object { [string]$_.FullName })) -Description "$Description (>${DaysOld}d old)"
    }
    catch { Write-SwFileOpsDebug "old files not removed: $($_.Exception.Message)" }
}

# ============================================================================
# Old names, kept as forwarding functions (not aliases, so a test mock of either name behaves) until the
# callers move to the new ones. They forward exactly what was bound.
# ============================================================================

function Test-SafePath {
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Path,
        [object]$WhitelistState = $null
    )
    Test-SwSafePath @PSBoundParameters
}

function Get-SweeprPathSnapshot {
    param(
        [Parameter(Position = 0)][string]$Path,
        [switch]$AllowLeafLink
    )
    Get-SwPathSnapshot @PSBoundParameters
}

function Test-SweeprPathSnapshot {
    param([Parameter(Position = 0)][object]$Snapshot)
    Test-SwPathSnapshot @PSBoundParameters
}

function Test-IsReparsePoint {
    param([string]$Path)
    Test-SwReparsePoint @PSBoundParameters
}

function Get-TreeItemsNoFollow {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$SkipUnreadable
    )
    Get-SwTreeItems @PSBoundParameters
}

function Get-SafeDirectoryTreeItems {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [object]$WhitelistState = $null
    )
    Get-SwSafeDirectoryTreeItems @PSBoundParameters
}

function Get-ValidatedTreeSize {
    param([hashtable]$Tree)
    Get-SwValidatedTreeSize @PSBoundParameters
}

function Get-PathSize {
    param([Parameter(Mandatory = $true)][string]$Path)
    Get-SwPathSize @PSBoundParameters
}

function Get-PathSizeKB {
    param([string]$Path)
    Get-SwPathSizeKB @PSBoundParameters
}

function Add-SweeprNotMeasured {
    param([string]$Name, [string]$Reason)
    Add-SwNotMeasured @PSBoundParameters
}

function Remove-TreeEntry {
    param([string]$Path)
    Remove-SwTreeEntry @PSBoundParameters
}

function Remove-SafeDirectoryTree {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [hashtable]$ValidatedTree,
        [hashtable]$Report,
        [object]$WhitelistState,
        [scriptblock]$CanRemove
    )
    Remove-SwDirectoryTree @PSBoundParameters
}

function Move-SweeprItemToRecycleBin {
    param([string]$Path, [object]$Snapshot)
    Move-SwItemToRecycleBin @PSBoundParameters
}

function Remove-SafeItem {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Description = "",
        [switch]$Force,
        [switch]$Recurse,
        [switch]$Recycle,
        [scriptblock]$Guard
    )
    Remove-SwItem @PSBoundParameters
}

function Remove-SafeItems {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Paths,
        [string]$Description = 'Items',
        [scriptblock]$CanRemove
    )
    Remove-SwItems @PSBoundParameters
}

function Remove-OldFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$DaysOld = 7,
        [string]$Filter = '*',
        [string]$Description = 'Old files'
    )
    Remove-SwOldFiles @PSBoundParameters
}

function Clear-DirectoryContents {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Description = "",
        [scriptblock]$CanRemove
    )
    Clear-SwDirectoryContents @PSBoundParameters
}

function Add-DryRunListEntries {
    param(
        [string]$Description,
        [AllowNull()][AllowEmptyCollection()][string[]]$Paths,
        [long[]]$SizeBytes = @(),
        [int[]]$FileCounts = @()
    )
    Add-SwDryRunListEntries @PSBoundParameters
}

function Get-CleanupStats { Get-SwCleanupStats }

function Reset-CleanupStats { Reset-SwCleanupStats }

function Set-DryRunMode {
    param([Parameter(Position = 0)][bool]$Enabled = $false)
    Set-SwDryRunMode @PSBoundParameters
}

function Test-DryRunMode { Test-SwDryRunMode }

# ============================================================================
# State, evaluated once per load (see the header)
# ============================================================================

$script:SwFileOpsNativeState = $null

# Only the value 1 switches the dry run on at load; any other value, or none, is a real run. The state
# is read again at every call, so a later change of the variable does nothing until the next reload.
$script:SweeprDryRunMode = ([System.Environment]::GetEnvironmentVariable('SWEEPR_DRY_RUN') -ceq '1')

$script:TotalSizeCleaned = 0
$script:FilesCleaned = 0
$script:TotalItems = 0
$script:OwnerCleanups = 0
$script:DryRunCollector = $null
$script:NotMeasuredCollector = $null
$script:SwWalkBudgetSeconds = 15

$script:SWEEPR_FILEOPS_LOADED = $true

# Other modules rely on these for the rest of their run.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
