# Sweepr - tests for the removal half of lib\core\file_ops.ps1: the removal of single entries and of
# trees, the Recycle Bin path, Remove-SwItem, Remove-SwItems, Clear-SwDirectoryContents,
# Remove-SwOldFiles, dry-run state and preview list, statistics, the operations log lines and the
# safety invariants of every removal path.
#
# The rule numbers in the test names (G-, F- and S-) number the rules and the safety invariants of the
# module's behavior; each rule and invariant has at least one test.
#
# Interface pinned here (new names; each old name stays as a forwarding function, not an alias):
#   Remove-SwTreeEntry -Path                         removes one entry, never recursive, throws on failure
#   Remove-SwDirectoryTree -Path [-ValidatedTree] [-Report] [-WhitelistState] [-CanRemove]   $true/$false
#   Move-SwItemToRecycleBin -Path -Snapshot          the only Recycle Bin call, throws on any failure
#   Remove-SwItem -Path [-Description] [-Force] [-Recurse] [-Recycle] [-Guard]   one $true/$false
#   Remove-SwItems -Paths [-Description] [-CanRemove]          nothing to the pipeline
#   Clear-SwDirectoryContents -Path [-Description] [-CanRemove]   nothing to the pipeline
#   Remove-SwOldFiles -Path [-DaysOld] [-Filter] [-Description]   nothing to the pipeline
#   Add-SwDryRunListEntries -Description -Paths [-SizeBytes] [-FileCounts]
#   Get-SwCleanupStats / Reset-SwCleanupStats / Set-SwDryRunMode -Enabled / Test-SwDryRunMode
# Variables that tests replace: $script:SweeprDryRunMode, $script:TotalSizeCleaned, $script:FilesCleaned,
# $script:TotalItems, $script:OwnerCleanups, $script:DryRunCollector, $script:NotMeasuredCollector,
# $script:ExportListFile (may be missing), $script:SwWalkBudgetSeconds, $script:CurrentSection.
#
# Seams used with Mock:
#   Get-SwPathSnapshot, Test-SwPathSnapshot          replaced by fakes with substitute objects
#   Get-SwSafeDirectoryTreeItems, Get-SwValidatedTreeSize, Get-SwPathSize
#   Remove-SwTreeEntry, Remove-SwDirectoryTree, Move-SwItemToRecycleBin, Remove-Item, Get-Date
#   Get-SwWhitelistState, Test-SwWhitelisted, Test-SwSafePath, Read-SwListBytes
#   Write-SweeprOperation, Write-DryRun, Write-Success, Write-Warning, Write-Debug, Set-SectionActivity,
#   Add-SwDryRunListEntries
#
# Platform notes:
#   - Paths are built from $TestDrive with the separator of the host. Hosts without the Windows file API
#     give no identity, so the removal tests replace the identity functions by fakes that answer like the
#     real ones (existing path, link rules, one identity text per path, changeable to simulate a replaced
#     entry). Whitelist lines name entries of the tree exactly. The real identity is exercised by the
#     tests marked [W].
#   - Tests marked [W] need real Windows (file identities, junctions, 8.3 names, the Recycle Bin shell
#     operation). They are meant to fail on Linux and belong in tests/linux-known-failures.txt.
#   - Real removals happen only below $TestDrive. Links are junctions on Windows and symbolic links
#     elsewhere; every test removes its links itself, and no test follows a link to delete.
#   - Nothing else real is touched: no registry, no network, no real operations.log (the writer is
#     mocked or pointed into the test drive), no real Recycle Bin outside the [W] test of the shell call.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    $script:Forwarders = @(
        @{ Old = 'Remove-TreeEntry'; New = 'Remove-SwTreeEntry'; Pass = $false
            Invoke = { Remove-TreeEntry -Path 'Example-Path' }
            Filter = { $Path -eq 'Example-Path' } }
        @{ Old = 'Remove-SafeDirectoryTree'; New = 'Remove-SwDirectoryTree'; Pass = $true
            Invoke = { Remove-SafeDirectoryTree -Path 'Example-Path' -ValidatedTree @{ Success = $true; Items = @() } -Report @{} -WhitelistState 'state-object' -CanRemove { $true } }
            Filter = { $Path -eq 'Example-Path' -and $ValidatedTree -is [hashtable] -and $Report -is [hashtable] -and $WhitelistState -eq 'state-object' -and $CanRemove -is [scriptblock] } }
        @{ Old = 'Move-SweeprItemToRecycleBin'; New = 'Move-SwItemToRecycleBin'; Pass = $false
            Invoke = { Move-SweeprItemToRecycleBin -Path 'Example-Path' -Snapshot 'snapshot-object' }
            Filter = { $Path -eq 'Example-Path' -and $Snapshot -eq 'snapshot-object' } }
        @{ Old = 'Remove-SafeItem'; New = 'Remove-SwItem'; Pass = $true
            Invoke = { Remove-SafeItem -Path 'Example-Path' -Description 'Example description' -Force -Recurse -Recycle -Guard { $true } }
            Filter = { $Path -eq 'Example-Path' -and $Description -eq 'Example description' -and $Force -and $Recurse -and $Recycle -and $Guard -is [scriptblock] } }
        @{ Old = 'Remove-SafeItems'; New = 'Remove-SwItems'; Pass = $false
            Invoke = { Remove-SafeItems -Paths @('Example-One', 'Example-Two') -Description 'Example description' -CanRemove { $true } }
            Filter = { @($Paths).Count -eq 2 -and $Description -eq 'Example description' -and $CanRemove -is [scriptblock] } }
        @{ Old = 'Remove-OldFiles'; New = 'Remove-SwOldFiles'; Pass = $false
            Invoke = { Remove-OldFiles -Path 'Example-Path' -DaysOld 9 -Filter '*.log' -Description 'Example description' }
            Filter = { $Path -eq 'Example-Path' -and $DaysOld -eq 9 -and $Filter -eq '*.log' -and $Description -eq 'Example description' } }
        @{ Old = 'Clear-DirectoryContents'; New = 'Clear-SwDirectoryContents'; Pass = $false
            Invoke = { Clear-DirectoryContents -Path 'Example-Path' -Description 'Example description' -CanRemove { $true } }
            Filter = { $Path -eq 'Example-Path' -and $Description -eq 'Example description' -and $CanRemove -is [scriptblock] } }
        @{ Old = 'Add-DryRunListEntries'; New = 'Add-SwDryRunListEntries'; Pass = $false
            Invoke = { Add-DryRunListEntries -Description 'Example description' -Paths @('Example-One', 'Example-Two') -SizeBytes @(1, 2) -FileCounts @(3, 4) }
            Filter = { $Description -eq 'Example description' -and @($Paths).Count -eq 2 -and @($SizeBytes).Count -eq 2 -and @($FileCounts).Count -eq 2 } }
        @{ Old = 'Get-CleanupStats'; New = 'Get-SwCleanupStats'; Pass = $true
            Invoke = { Get-CleanupStats }
            Filter = { $true } }
        @{ Old = 'Reset-CleanupStats'; New = 'Reset-SwCleanupStats'; Pass = $false
            Invoke = { Reset-CleanupStats }
            Filter = { $true } }
        @{ Old = 'Set-DryRunMode'; New = 'Set-SwDryRunMode'; Pass = $false
            Invoke = { Set-DryRunMode $true }
            Filter = { $Enabled -eq $true } }
        @{ Old = 'Test-DryRunMode'; New = 'Test-SwDryRunMode'; Pass = $true
            Invoke = { Test-DryRunMode }
            Filter = { $true } }
    )

    # F-23, F-30: results that do not count as one boolean true.
    $script:NotTrue = @(
        @{ Label = 'false'; Block = { $false } }
        @{ Label = 'an exception'; Block = { throw 'condition-canary' } }
        @{ Label = 'the number 1'; Block = { 1 } }
        @{ Label = 'a non-empty string'; Block = { 'yes' } }
        @{ Label = 'no output'; Block = { } }
        @{ Label = 'two true values'; Block = { $true; $true } }
        @{ Label = 'null'; Block = { $null } }
        @{ Label = 'true and false'; Block = { $true; $false } }
        @{ Label = 'the string True'; Block = { 'True' } }
    )

    # F-22 point 1: paths that are not complete.
    $script:IncompleteForms = @(
        @{ Label = 'a bare name'; Form = 'relative' }
        @{ Label = 'a dot-relative name'; Form = 'dot' }
        @{ Label = 'a parent-relative name'; Form = 'parent' }
        @{ Label = 'a root-relative path'; Form = 'rootrelative' }
        @{ Label = 'a drive-relative path'; Form = 'driverelative' }
        @{ Label = 'a registry provider path'; Form = 'registry' }
        @{ Label = 'an environment provider path'; Form = 'environment' }
    )

    # G-6, S-15: names with characters that have a meaning for wildcards or the shell.
    $script:OddNames = @(
        @{ Label = 'brackets'; Name = 'Cache [1]' }
        @{ Label = 'a closing bracket'; Name = 'x]y' }
        @{ Label = 'a backtick'; Name = ('a' + [char]96 + 'b') }
        @{ Label = 'a dollar sign'; Name = '$HOME' }
        @{ Label = 'an apostrophe'; Name = 'it''s' }
        @{ Label = 'braces'; Name = '{a}' }
        @{ Label = 'a percent sign'; Name = '100%' }
        @{ Label = 'a semicolon'; Name = 'a;b' }
        @{ Label = 'parentheses'; Name = 'Tools (x86)' }
    )

    # F-31: byte sums and the kilobytes the sum rounds up to.
    $script:SumCases = @(
        @{ Sizes = @(4096, 6144); Expected = 10 }
        @{ Sizes = @(1000, 1000); Expected = 2 }
        @{ Sizes = @(1, 1, 1); Expected = 1 }
        @{ Sizes = @(1024, 1); Expected = 2 }
        @{ Sizes = @(0, 0); Expected = 0 }
    )


    # E36: the new names with their parameters (Mandatory ones are named, Position 0 where given).
    $script:Interface = @(
        @{ Name = 'Remove-SwTreeEntry'; Parameters = @('Path'); Mandatory = @(); Position0 = '' }
        @{ Name = 'Remove-SwDirectoryTree'; Parameters = @('Path', 'ValidatedTree', 'Report', 'WhitelistState', 'CanRemove'); Mandatory = @('Path'); Position0 = '' }
        @{ Name = 'Move-SwItemToRecycleBin'; Parameters = @('Path', 'Snapshot'); Mandatory = @(); Position0 = '' }
        @{ Name = 'Remove-SwItem'; Parameters = @('Path', 'Description', 'Force', 'Recurse', 'Recycle', 'Guard'); Mandatory = @('Path'); Position0 = '' }
        @{ Name = 'Remove-SwItems'; Parameters = @('Paths', 'Description', 'CanRemove'); Mandatory = @('Paths'); Position0 = '' }
        @{ Name = 'Remove-SwOldFiles'; Parameters = @('Path', 'DaysOld', 'Filter', 'Description'); Mandatory = @('Path'); Position0 = '' }
        @{ Name = 'Clear-SwDirectoryContents'; Parameters = @('Path', 'Description', 'CanRemove'); Mandatory = @('Path'); Position0 = '' }
        @{ Name = 'Add-SwDryRunListEntries'; Parameters = @('Description', 'Paths', 'SizeBytes', 'FileCounts'); Mandatory = @(); Position0 = '' }
        @{ Name = 'Get-SwCleanupStats'; Parameters = @(); Mandatory = @(); Position0 = '' }
        @{ Name = 'Reset-SwCleanupStats'; Parameters = @(); Mandatory = @(); Position0 = '' }
        @{ Name = 'Set-SwDryRunMode'; Parameters = @('Enabled'); Mandatory = @(); Position0 = 'Enabled' }
        @{ Name = 'Test-SwDryRunMode'; Parameters = @(); Mandatory = @(); Position0 = '' }
    )

    $script:Preferences = @('Stop', 'Continue', 'SilentlyContinue')
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:CoreDir = [System.IO.Path]::Combine($script:RepoRoot, 'lib', 'core')
    $script:FileOpsFile = [System.IO.Path]::Combine($script:CoreDir, 'file_ops.ps1')
    $script:OnWindows = [System.IO.Path]::DirectorySeparatorChar -eq '\'
    $script:IsDesktop = $PSVersionTable['PSEdition'] -eq 'Desktop'
    $script:Sep = [string][System.IO.Path]::DirectorySeparatorChar
    $script:WorkCounter = 0
    $script:Links = New-Object System.Collections.Generic.List[string]

    # ---- environment and script variables ---------------------------------------------------------

    function script:Save-Env([string[]]$Names) {
        $saved = @{}
        foreach ($name in $Names) { $saved[$name] = [System.Environment]::GetEnvironmentVariable($name) }
        $saved
    }
    function script:Restore-Env([hashtable]$Saved) {
        foreach ($name in @($Saved.Keys)) {
            $value = $Saved[$name]
            if ($null -eq $value) { $value = [NullString]::Value }
            [System.Environment]::SetEnvironmentVariable($name, $value)
        }
    }
    # An empty value removes the variable. Since .NET 10 SetEnvironmentVariable(name, "") keeps the
    # variable with an empty value, and PowerShell 7.6 passes a plain $null to the method as "";
    # only [NullString]::Value is a real null.
    function script:Set-Env([string]$Name, [AllowNull()][AllowEmptyString()][string]$Value) {
        if ([string]::IsNullOrEmpty($Value)) { [System.Environment]::SetEnvironmentVariable($Name, [NullString]::Value) }
        else { [System.Environment]::SetEnvironmentVariable($Name, $Value) }
    }

    $script:EnvNames = @('SWEEPR_DRY_RUN', 'SWEEPR_NO_OPLOG', 'SWEEPR_DEBUG', 'SWEEPR_DATA_DIR', '_SWEEPR_OPLOG_RUN_COMMAND', '_SWEEPR_OPLOG_RUN_ID', 'SWEEPR_TEST_PROVIDER_VARIABLE')
    $script:StateNames = @('Config', 'ProtectedPaths', 'ExactProtectedPaths', 'DefaultWhitelistPatterns', 'SweeprCleanPathGuard',
        'SweeprDryRunMode', 'TotalSizeCleaned', 'FilesCleaned', 'TotalItems', 'OwnerCleanups', 'DryRunCollector', 'NotMeasuredCollector',
        'ExportListFile', 'SwWalkBudgetSeconds', 'CurrentSection', 'SweeprOperationsLogFile', 'SweeprOperationsLogStarted',
        'SWEEPR_FILEOPS_LOADED', 'FakeIdentity', 'FakeNoIdentity')
    function script:Save-State {
        $state = @{}
        foreach ($name in $script:StateNames) {
            $variable = Get-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue
            if ($null -eq $variable) { $state[$name] = @{ Exists = $false; Value = $null }; continue }
            $value = $variable.Value
            if ($value -is [hashtable]) { $value = $value.Clone() }
            elseif ($value -is [array]) { $value = @($value) }
            $state[$name] = @{ Exists = $true; Value = $value }
        }
        $state
    }
    function script:Restore-State([hashtable]$State) {
        foreach ($name in $script:StateNames) {
            $entry = $State[$name]
            if ($entry.Exists) {
                $value = $entry.Value
                if ($value -is [hashtable]) { $value = $value.Clone() }
                elseif ($value -is [array]) { $value = @($value) }
                Set-Variable -Name $name -Scope Script -Value $value
            }
            else { Remove-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue }
        }
    }

    # ---- file system helpers ----------------------------------------------------------------------

    function script:P {
        param([string]$Base, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Parts)
        $result = $Base
        foreach ($part in $Parts) { $result = [System.IO.Path]::Combine($result, $part) }
        $result
    }
    function script:New-Dir([string]$Path) { [void][System.IO.Directory]::CreateDirectory($Path); $Path }
    function script:New-File([string]$Path, [int]$Bytes = 3) {
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path))
        $data = New-Object byte[] $Bytes
        for ($i = 0; $i -lt $Bytes; $i++) { $data[$i] = 65 }
        [System.IO.File]::WriteAllBytes($Path, $data)
        $Path
    }
    function script:New-Work {
        $script:WorkCounter++
        New-Dir (P $TestDrive ('w' + $script:WorkCounter))
    }
    # Name, kind and length of everything below a folder (no time stamps: Windows moves folder times).
    function script:Get-Listing([string]$Root) {
        if (-not [System.IO.Directory]::Exists($Root)) { return @('<missing>') }
        $rows = New-Object System.Collections.Generic.List[string]
        foreach ($item in @(Get-ChildItem -LiteralPath $Root -Recurse -Force)) {
            $rel = Get-Rel $item.FullName $Root
            if ($item.PSIsContainer) { $rows.Add("D $rel") } else { $rows.Add("F $rel $($item.Length)") }
        }
        , @($rows | Sort-Object)
    }
    function script:Same-Listing($Left, $Right) { (@($Left) -join '|') -ceq (@($Right) -join '|') }
    # Comparison form of a path: normalized like the module does (Windows PowerShell 5.1 spells a short
    # 8.3 name of the temp folder out), one separator kind, no trailing separator, no case.
    function script:Fold([string]$Path) {
        $text = $Path
        try { if ([System.IO.Path]::IsPathRooted($text)) { $text = [System.IO.Path]::GetFullPath($text) } } catch { $null = $_ }
        $text.Replace('/', '\').TrimEnd('\').ToLowerInvariant()
    }
    # The path below a root, in the spelling of the host (both sides normalized).
    function script:Get-Rel([string]$Path, [string]$Root) {
        $full = [System.IO.Path]::GetFullPath($Path)
        $base = [System.IO.Path]::GetFullPath($Root)
        $full.Substring($base.Length).TrimStart('\', '/')
    }
    # The last segments of a path: how a message names an entry whatever the spelling of the folder above.
    function script:Get-Tail([string]$Path, [int]$Segments = 2) {
        $parts = @($Path.Replace('/', '\').TrimEnd('\').Split('\') | Where-Object { $_.Length -gt 0 })
        $take = [math]::Min($Segments, $parts.Count)
        ($parts[($parts.Count - $take)..($parts.Count - 1)]) -join $script:Sep
    }
    # 'stopped at <path>: <message>' with the path compared in its normalized form.
    function script:Assert-Stopped([string]$Text, [string]$Path, [string]$Message) {
        $m = [regex]::Match($Text, '^stopped at (.+?): (.*)$')
        $m.Success | Should -BeTrue -Because "'$Text' must read: stopped at <path>: <message>"
        (Fold $m.Groups[1].Value) | Should -BeExactly (Fold $Path)
        if ($Message) { $m.Groups[2].Value | Should -BeLike $Message }
    }
    # 'incomplete: removed <n> of <m> entries; stopped at <path>: <message>'.
    function script:Assert-Incomplete([string]$Text, [int]$Removed, [int]$Total, [string]$Path, [string]$Message) {
        $m = [regex]::Match($Text, '^incomplete: removed (\d+) of (\d+) entries; (stopped at .+)$')
        $m.Success | Should -BeTrue -Because "'$Text' must read: incomplete: removed <n> of <m> entries; stopped at <path>: <message>"
        $m.Groups[1].Value | Should -BeExactly ([string]$Removed)
        $m.Groups[2].Value | Should -BeExactly ([string]$Total)
        Assert-Stopped $m.Groups[3].Value $Path $Message
    }
    # Action, path and detail of one log record.
    function script:ConvertFrom-LogRecord([string]$Line) {
        $m = [regex]::Match($Line, '^\[[^\]]+\] \[[^\]]+\] ([A-Z]+) (.+) \(([^()]*)\)$')
        if (-not $m.Success) { return $null }
        [pscustomobject]@{ Action = $m.Groups[1].Value; Path = $m.Groups[2].Value; Detail = $m.Groups[3].Value }
    }
    function script:Exists([string]$Path) { [System.IO.File]::Exists($Path) -or [System.IO.Directory]::Exists($Path) }
    function script:Leaf([string]$Path) { [System.IO.Path]::GetFileName($Path.TrimEnd('\', '/')) }

    function script:New-TestLink([string]$Link, [string]$Target) {
        if ($script:OnWindows -and [System.IO.Directory]::Exists($Target)) { [void](New-Item -ItemType Junction -Path $Link -Target $Target) }
        else { [void](New-Item -ItemType SymbolicLink -Path $Link -Target $Target) }
        $script:Links.Add($Link)
    }
    # Removes only the link itself, never anything it points to.
    function script:Remove-TestLink([string]$Link) {
        try {
            if ($script:OnWindows -and [System.IO.Directory]::Exists($Link)) { [System.IO.Directory]::Delete($Link, $false) }
            else { [System.IO.File]::Delete($Link) }
        }
        catch { $null = $_ }
    }
    function script:Clear-TestLinks {
        foreach ($link in @($script:Links)) { Remove-TestLink $link }
        $script:Links.Clear()
    }

    # A tree: folder 'root' below the work folder with the given relative file paths (3 bytes each, or
    # name=bytes). Gives the root path.
    function script:New-Tree([string]$Name, [string[]]$Files) {
        $root = New-Dir (P $script:Work $Name)
        foreach ($file in $Files) {
            $size = 3
            $relative = $file
            if ($file.Contains('=')) { $relative = $file.Substring(0, $file.LastIndexOf('=')); $size = [int]$file.Substring($file.LastIndexOf('=') + 1) }
            New-File (P $root $relative.Replace('/', $script:Sep)) $size | Out-Null
        }
        $root
    }

    function script:Set-Whitelist([string[]]$Lines) {
        $file = $script:Config.WhitelistFile
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($file))
        [System.IO.File]::WriteAllText($file, (($Lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding $false))
    }

    function script:Get-Field($Object, [string]$Name) {
        if ($null -eq $Object) { return $null }
        if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] }; return $null }
        $property = $Object.PSObject.Properties[$Name]
        if ($null -eq $property) { return $null }
        $property.Value
    }
    # Runs a block and gives its output; an exception fails the test. (A plain assignment inside a block
    # that Should invokes does not reach the test, so results are taken through this function.)
    function script:Get-Result([scriptblock]$Block) {
        try { & $Block }
        catch { throw ('unexpected exception: ' + $_.Exception.Message) }
    }
    # Runs a block that must throw and gives the error record. A block that does not throw fails the test,
    # and so does a block that only fails because a function does not exist.
    function script:Assert-Throws([scriptblock]$Block) {
        $failure = $null
        try { $null = & $Block } catch { $failure = $_ }
        if ($null -eq $failure) { throw 'expected an exception, but there was none' }
        if ($failure.Exception -is [System.Management.Automation.CommandNotFoundException]) { throw ('the function does not exist: ' + $failure.Exception.Message) }
        $failure
    }

    function script:Assert-Result($Actual, [bool]$Expected, [string]$Because) {
        $Actual | Should -BeOfType [bool] -Because $Because
        $Actual | Should -Be $Expected -Because $Because
    }

    # A test that only reads the source needs a module that defines its functions first.
    function script:Assert-Defined([string[]]$Names) {
        foreach ($name in $Names) {
            ($null -ne (Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue)) | Should -BeTrue -Because "$name must be defined after loading"
        }
    }
    # True when the expected events appear in this order, not necessarily next to each other.
    function script:Test-Subsequence([string[]]$Events, [string[]]$Expected) {
        $index = 0
        foreach ($event in $Events) {
            if ($index -lt $Expected.Count -and $event -ceq $Expected[$index]) { $index++ }
        }
        $index -eq $Expected.Count
    }

    function script:Import-FileOps {
        $script:SWEEPR_FILEOPS_LOADED = $false
        . $script:FileOpsFile
    }

    # ---- fakes for the identity functions ---------------------------------------------------------

    # Identity text of a path for the fakes: the texts of all components joined, $null for a missing path,
    # for a link above the entry and for a link as the entry without -AllowLeafLink. Components above the
    # fixture folder are taken as they are. $script:FakeIdentity overrides the text of one component
    # (case-insensitive key), which simulates a replaced entry; $script:FakeNoIdentity lists full paths
    # that have no identity at all.
    function script:Get-FakeIdentityText([string]$Path, [bool]$AllowLeafLink) {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
        $full = $null
        try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return $null }
        $texts = New-Object System.Collections.Generic.List[string]
        $current = $full
        $leaf = $true
        while (-not [string]::IsNullOrEmpty($current)) {
            $attributes = $null
            try { $attributes = [System.IO.File]::GetAttributes($current) } catch { return $null }
            $below = $current.StartsWith([System.IO.Path]::GetFullPath($script:Work), [System.StringComparison]::OrdinalIgnoreCase)
            if ($below -and (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
                if (-not $leaf -or -not $AllowLeafLink) { return $null }
            }
            foreach ($listed in @($script:FakeNoIdentity)) { if ([System.IO.Path]::GetFullPath([string]$listed) -ieq $current) { return $null } }
            $overridden = $false
            foreach ($key in @($script:FakeIdentity.Keys)) {
                if ([System.IO.Path]::GetFullPath([string]$key) -ieq $current) { $texts.Add([string]$script:FakeIdentity[$key]); $overridden = $true; break }
            }
            if (-not $overridden) { $texts.Add('id:' + $current) }
            $leaf = $false
            $current = [System.IO.Path]::GetDirectoryName($current)
        }
        $texts -join '|'
    }
    # Answers like the real functions, with substitute objects (Path, Identity, AllowLeafLink; no Entries,
    # so the module cannot derive a child snapshot and asks for each one). With $script:EventLogging the
    # identity test notes 'snap:<path>' in $script:Events.
    function script:Use-FakeIdentity {
        $script:FakeIdentity = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $script:FakeNoIdentity = @()
        if ($null -eq (Get-Command -Name Get-SwPathSnapshot -CommandType Function -ErrorAction SilentlyContinue)) { return }
        Mock Get-SwPathSnapshot {
            $text = Get-FakeIdentityText $Path ([bool]$AllowLeafLink)
            if ($null -eq $text) { return $null }
            [pscustomobject]@{ Path = $Path; Identity = $text; AllowLeafLink = [bool]$AllowLeafLink }
        }
        Mock Test-SwPathSnapshot {
            if ($script:EventLogging) { $script:Events.Add('snap:' + (Fold ([string](Get-Field $Snapshot 'Path')))) }
            if ($null -eq $Snapshot) { return $false }
            $path = Get-Field $Snapshot 'Path'
            if ([string]::IsNullOrEmpty([string]$path)) { return $false }
            $now = Get-FakeIdentityText ([string]$path) ([bool](Get-Field $Snapshot 'AllowLeafLink'))
            if ($null -eq $now) { return $false }
            [string](Get-Field $Snapshot 'Identity') -eq $now
        }
    }

    # Spies for everything the module says: operations, console lines, list entries, section activity.
    function script:Use-Spies([switch]$RealWriter, [switch]$RealOutput) {
        $script:Ops = New-Object System.Collections.Generic.List[object]
        $script:Said = New-Object System.Collections.Generic.List[string]
        $script:DrySaid = New-Object System.Collections.Generic.List[string]
        if (-not $RealWriter) {
            Mock Write-SweeprOperation { $script:Ops.Add([pscustomobject]@{ Action = $Action; Path = $Path; Detail = $Detail }) }
        }
        if (-not $RealOutput) {
            Mock Write-Success { $script:Said.Add([string]$Message) }
            Mock Write-DryRun { $script:DrySaid.Add([string]$Message) }
            Mock Set-SectionActivity { }
        }
    }

    # Replaces the removal of one entry by a spy that removes like the real function (not recursive) and
    # can fail for one path or run a hook just before removing.
    function script:Use-TreeEntrySpy {
        $script:FailOn = $null
        $script:FailMessage = 'locked-canary'
        $script:BeforeRemove = $null
        $script:LastError = ''
        Mock Remove-SwTreeEntry {
            $script:Events.Add('remove:' + (Fold $Path))
            if ($null -ne $script:FailOn -and (Fold $Path) -eq (Fold $script:FailOn)) { throw $script:FailMessage }
            if ($null -ne $script:BeforeRemove) { & $script:BeforeRemove $Path }
            try {
                if ([System.IO.Directory]::Exists($Path)) { [System.IO.Directory]::Delete($Path, $false) } else { [System.IO.File]::Delete($Path) }
            }
            catch { $script:LastError = $_.Exception.Message; throw }
            $script:Removed.Add($Path)
        }
    }

    # What the whole removal tests may change per test.
    function script:Initialize-Case([switch]$RealWriter, [switch]$RealOutput, [switch]$RealIdentity) {
        Start-Case
        $script:Work = New-Work
        $script:Target = New-Dir (P $script:Work 'target')
        $script:Prot = New-Dir (P $script:Work 'protected')
        $script:Data = P $script:Work 'appdata'
        $script:Config = @{ ConfigPath = (P $script:Data 'config'); CachePath = (P $script:Data 'cache'); WhitelistFile = (P $script:Data 'config' 'whitelist.txt') }
        $script:DefaultWhitelistPatterns = @()
        $script:ProtectedPaths = @($script:Prot)
        $script:ExactProtectedPaths = @()
        $script:SweeprCleanPathGuard = $false
        $script:SweeprDryRunMode = $false
        $script:TotalSizeCleaned = 0
        $script:FilesCleaned = 0
        $script:TotalItems = 0
        $script:OwnerCleanups = 0
        $script:DryRunCollector = $null
        $script:NotMeasuredCollector = $null
        Remove-Variable -Name ExportListFile -Scope Script -ErrorAction SilentlyContinue
        $script:SwWalkBudgetSeconds = 15
        $script:SweeprOperationsLogFile = P $script:Work 'oplog' 'operations.log'
        $script:SweeprOperationsLogStarted = $false
        $script:CurrentSection = @{ Active = $false; Activity = $false; Name = 'Example section' }
        $script:Events = New-Object System.Collections.Generic.List[string]
        $script:Removed = New-Object System.Collections.Generic.List[string]
        $script:EventLogging = $false
        $script:FailOn = $null
        $script:BeforeRemove = $null
        Set-Env 'SWEEPR_NO_OPLOG' '1'
        Set-Env 'SWEEPR_DRY_RUN' $null
        $script:FakeIdentity = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        $script:FakeNoIdentity = @()
        if (-not $RealIdentity) { Use-FakeIdentity }
        Use-Spies -RealWriter:$RealWriter -RealOutput:$RealOutput
    }

    function script:Start-Case {
        $script:SavedState = Save-State
        $script:SavedEnv = Save-Env $script:EnvNames
    }
    function script:Stop-Case {
        Clear-TestLinks
        Restore-Env $script:SavedEnv
        Restore-State $script:SavedState
    }

    # The body of a function as it is now, or $null when the function does not exist (the tests that need
    # it then fail on their own).
    function script:Get-OriginalBlock([string]$Name) {
        $command = Get-Command -Name $Name -CommandType Function -ErrorAction SilentlyContinue
        if ($null -eq $command) { return $null }
        $command.ScriptBlock
    }

    function script:Get-ParamSignature([string]$Name) {
        $command = Get-Command -Name $Name -CommandType Function -ErrorAction Stop
        $common = @('Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable',
            'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable', 'WhatIf', 'Confirm', 'ProgressAction')
        $ast = $command.ScriptBlock.Ast
        $declared = @()
        if ($ast -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            if ($ast.Parameters) { $declared = @($ast.Parameters) }
            elseif ($ast.Body.ParamBlock) { $declared = @($ast.Body.ParamBlock.Parameters) }
        }
        elseif ($ast.ParamBlock) { $declared = @($ast.ParamBlock.Parameters) }
        $lines = @()
        foreach ($parameter in $declared) {
            $paramName = $parameter.Name.VariablePath.UserPath
            if ($paramName -in $common) { continue }
            $meta = $command.Parameters[$paramName]
            $attribute = $meta.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | Select-Object -First 1
            $position = 'none'
            $mandatory = $false
            if ($null -ne $attribute) { $position = [string]$attribute.Position; $mandatory = [bool]$attribute.Mandatory }
            $default = ''
            if ($null -ne $parameter.DefaultValue) { $default = $parameter.DefaultValue.Extent.Text }
            $lines += ('{0}|{1}|pos={2}|mandatory={3}|default={4}' -f $paramName, $meta.ParameterType.FullName, $position, $mandatory, $default)
        }
        , $lines
    }

    # The log lines the real writer appended, without the empty line and the session marker.
    function script:Get-LogRecords {
        $file = $script:SweeprOperationsLogFile
        if (-not [System.IO.File]::Exists($file)) { return }
        [System.IO.File]::ReadAllText($file) -split "`r?`n" | Where-Object { $_.Length -gt 0 -and -not $_.StartsWith('# ==========') }
    }
    function script:Get-LogMarkers {
        $file = $script:SweeprOperationsLogFile
        if (-not [System.IO.File]::Exists($file)) { return }
        [System.IO.File]::ReadAllText($file) -split "`r?`n" | Where-Object { $_.StartsWith('# ==========') }
    }
    # Each removal or recycle event needs a Test-SwSafePath answer for the same path after the previous
    # removal and before itself (events 'safe:<path>', 'remove:<path>', 'move:<path>').
    function script:Assert-SafeBeforeEach([string[]]$Events) {
        $lastRemoval = -1
        $removals = 0
        for ($i = 0; $i -lt $Events.Count; $i++) {
            $event = $Events[$i]
            if (-not ($event.StartsWith('remove:') -or $event.StartsWith('move:'))) { continue }
            $removals++
            $path = $event.Substring($event.IndexOf(':') + 1)
            $lastSafe = -1
            for ($j = $i - 1; $j -ge 0; $j--) { if ($Events[$j] -ceq ('safe:' + $path)) { $lastSafe = $j; break } }
            $lastSafe | Should -BeGreaterThan $lastRemoval -Because "the safety question for $path must come after the previous removal and before this one"
            $lastRemoval = $i
        }
        $removals | Should -BeGreaterThan 0 -Because 'the scenario must remove something'
    }

    # The real functions, for tests that count calls and pass them on, taken before any test mocks them.
    $script:RootState = Save-State
    $script:RootEnv = Save-Env $script:EnvNames
    $script:RootDirectory = [System.Environment]::CurrentDirectory
    . $script:FileOpsFile
    $script:RealSafeTree = Get-OriginalBlock 'Get-SwSafeDirectoryTreeItems'
    $script:RealTreeSize = Get-OriginalBlock 'Get-SwValidatedTreeSize'
    $script:RealTreeEntry = Get-OriginalBlock 'Remove-SwTreeEntry'
    $script:RealDirectoryTree = Get-OriginalBlock 'Remove-SwDirectoryTree'
    $script:RealWhitelistState = Get-OriginalBlock 'Get-SwWhitelistState'
    $script:RealGet = Get-OriginalBlock 'Get-SwPathSnapshot'
    $script:RealTest = Get-OriginalBlock 'Test-SwPathSnapshot'
    $script:RealRemoveItem = Get-Command -Name Remove-Item -CommandType Cmdlet
    $script:RealGetDate = Get-Command -Name Get-Date -CommandType Cmdlet
}

AfterAll {
    Clear-TestLinks
    Restore-State $script:RootState
    Restore-Env $script:RootEnv
    [System.Environment]::CurrentDirectory = $script:RootDirectory
}

# ============================================================================
# Remove-SwTreeEntry
# ============================================================================

Describe 'Remove-SwTreeEntry' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
    }
    AfterEach { Stop-Case }

    It 'F-18 removes a file' {
        $file = New-File (P $script:Target 'a.txt') 10
        Remove-SwTreeEntry -Path $file
        Exists $file | Should -BeFalse
    }

    It 'F-18 writes nothing to the pipeline' {
        $file = New-File (P $script:Target 'a.txt') 10
        @(Remove-SwTreeEntry -Path $file).Count | Should -Be 0
    }

    It 'F-18 throws for an entry that does not exist' {
        $null = Assert-Throws { Remove-SwTreeEntry -Path (P $script:Target 'missing.txt') }
        $null = Assert-Throws { Remove-SwTreeEntry -Path (P $script:Target 'missing-folder') }
    }

    It 'F-18 removes an empty folder' {
        $dir = New-Dir (P $script:Target 'empty')
        Remove-SwTreeEntry -Path $dir
        Exists $dir | Should -BeFalse
    }

    It 'F-18 clears the read-only attribute of a folder and then removes it' {
        $dir = New-Dir (P $script:Target 'readonly')
        [System.IO.File]::SetAttributes($dir, ([System.IO.FileAttributes]::Directory -bor [System.IO.FileAttributes]::ReadOnly))
        Remove-SwTreeEntry -Path $dir
        Exists $dir | Should -BeFalse
    }

    It 'F-18 throws for a folder with entries and removes none of them (also hidden ones)' {
        $dir = New-Tree 'full' @('late.txt', 'nested/deeper/x.txt', '.hidden')
        $before = Get-Listing $dir
        $null = Assert-Throws { Remove-SwTreeEntry -Path $dir }
        Same-Listing (Get-Listing $dir) $before | Should -BeTrue
    }

    It 'F-18 never calls Remove-Item for a folder, with entries or without, and never with -Recurse' {
        $script:RemoveCalls = New-Object System.Collections.Generic.List[string]
        Mock Remove-Item {
            $target = ''
            if ($null -ne $LiteralPath) { $target = [string]@($LiteralPath)[0] } elseif ($null -ne $Path) { $target = [string]@($Path)[0] }
            $script:RemoveCalls.Add($target + '|' + [bool]$Recurse)
            & $script:RealRemoveItem @PesterBoundParameters
        }
        $empty = New-Dir (P $script:Target 'empty')
        $full = New-Tree 'full' @('late.txt')
        Remove-SwTreeEntry -Path $empty
        $null = Assert-Throws { Remove-SwTreeEntry -Path $full }
        $script:RemoveCalls.Count | Should -Be 0 -Because 'the empty folder goes through Directory.Delete and the full one is not removed'
        $folders = @($script:RemoveCalls | Where-Object { (Fold $_.Split('|')[0]) -in @((Fold $empty), (Fold $full)) })
        $folders.Count | Should -Be 0
        @($script:RemoveCalls | Where-Object { $_.EndsWith('|True') }).Count | Should -Be 0
    }

    It 'F-18 removes a file with Remove-Item -LiteralPath -Force and without -Recurse' {
        $script:Seen = New-Object System.Collections.Generic.List[string]
        Mock Remove-Item {
            $script:Seen.Add([string]@($LiteralPath)[0] + '|' + [bool]$Force + '|' + [bool]$Recurse)
            & $script:RealRemoveItem @PesterBoundParameters
        }
        $file = New-File (P $script:Target 'a.txt') 10
        Remove-SwTreeEntry -Path $file
        @($script:Seen).Count | Should -Be 1
        $script:Seen[0] | Should -BeExactly ($file + '|True|False')
    }

    It 'F-18 passes the exception of a failed file removal on, without a retry and without a fallback' {
        $script:Calls = 0
        Mock Remove-Item { $script:Calls++; throw 'access-denied-canary' }
        $file = New-File (P $script:Target 'a.txt') 10
        { Remove-SwTreeEntry -Path $file } | Should -Throw -ExpectedMessage '*access-denied-canary*'
        $script:Calls | Should -Be 1
        Exists $file | Should -BeTrue
    }

    It 'F-18 treats the path literally: only the entry with brackets in its name goes' {
        $odd = New-File (P $script:Target 'a[1].txt') 4
        $decoy = New-File (P $script:Target 'a1.txt') 4
        Remove-SwTreeEntry -Path $odd
        Exists $odd | Should -BeFalse
        Exists $decoy | Should -BeTrue
        $null = Assert-Throws { Remove-SwTreeEntry -Path (P $script:Target 'a*.txt') }
        Exists $decoy | Should -BeTrue
    }

    It 'F-18 removes an entry whose name contains <Label>' -ForEach $script:OddNames {
        $file = New-File (P $script:Target $Name) 4
        $dir = New-Dir (P $script:Target ($Name + ' dir'))
        Remove-SwTreeEntry -Path $file
        Remove-SwTreeEntry -Path $dir
        Exists $file | Should -BeFalse
        Exists $dir | Should -BeFalse
    }

    It 'F-18 [W] removes a folder link and leaves the folder it points to and its files' {
        $target = New-Tree 'link-target' @('a.txt', 'nested/b.txt')
        $before = Get-Listing $target
        $link = P $script:Target 'link'
        New-TestLink $link $target
        Remove-SwTreeEntry -Path $link
        Exists $link | Should -BeFalse
        Same-Listing (Get-Listing $target) $before | Should -BeTrue
    }

    It 'F-18 removes a link to a file and leaves the file' {
        $file = New-File (P $script:Work 'real.txt') 5
        $link = P $script:Target 'filelink.txt'
        try { New-TestLink $link $file }
        catch { Set-ItResult -Skipped -Because 'this host does not allow file links for this user'; return }
        Remove-SwTreeEntry -Path $link
        Exists $link | Should -BeFalse
        Exists $file | Should -BeTrue
    }

    It 'G-5 still throws for a failed removal under every error preference (<Preference>)' -ForEach @(
        @{ Preference = 'Stop' }
        @{ Preference = 'Continue' }
        @{ Preference = 'SilentlyContinue' }
    ) {
        $full = New-Tree 'full' @('x.txt')
        $ErrorActionPreference = $Preference
        $null = Assert-Throws { Remove-SwTreeEntry -Path $full }
        $null = Assert-Throws { Remove-SwTreeEntry -Path (P $script:Target 'missing.txt') }
        Exists (P $full 'x.txt') | Should -BeTrue
    }
}

# ============================================================================
# Remove-SwDirectoryTree
# ============================================================================

Describe 'Remove-SwDirectoryTree' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
    }
    AfterEach { Stop-Case }

    It 'F-19 removes a folder with six files in a nested folder, gives true, and reads the whitelist state once' {
        $root = New-Tree 'full' @('top.txt', 'nested/a.txt', 'nested/b.txt', 'nested/c.txt', 'nested/d.txt', 'nested/e.txt')
        $script:RealState = Get-SwWhitelistState
        Mock Get-SwWhitelistState { $script:RealState }
        $result = @(Remove-SwDirectoryTree -Path $root)
        $result.Count | Should -Be 1
        Assert-Result $result[0] $true 'a complete removal'
        Exists $root | Should -BeFalse
        Should -Invoke -CommandName Get-SwWhitelistState -Times 1 -Exactly
    }

    It 'F-19 gives true and Total 0 for an empty folder' {
        $root = New-Dir (P $script:Target 'empty')
        $report = @{}
        Assert-Result (Remove-SwDirectoryTree -Path $root -Report $report) $true 'empty folder'
        Exists $root | Should -BeFalse
        $report['Total'] | Should -Be 0
        $report['Removed'] | Should -Be 0
    }

    It 'F-19 sets all four keys of the report: Removed, Total, an empty Reason and OwnerHeld false' {
        $root = New-Tree 'full' @('a.txt', 'nested/b.txt')
        $report = @{}
        Assert-Result (Remove-SwDirectoryTree -Path $root -Report $report) $true 'complete'
        $report['Total'] | Should -Be 3
        $report['Removed'] | Should -Be 3
        [string]$report['Reason'] | Should -BeNullOrEmpty
        $report['OwnerHeld'] | Should -BeFalse
    }

    It 'F-19 resets a report that holds old values when it starts' {
        $root = New-Tree 'full' @('a.txt')
        $report = @{ Removed = 99; Total = 99; Reason = 'old reason'; OwnerHeld = $true }
        Assert-Result (Remove-SwDirectoryTree -Path $root -Report $report) $true 'complete'
        $report['Removed'] | Should -Be 1
        $report['Total'] | Should -Be 1
        [string]$report['Reason'] | Should -BeNullOrEmpty
        $report['OwnerHeld'] | Should -BeFalse
    }

    It 'F-19 works without a report' {
        $root = New-Tree 'full' @('a.txt')
        Assert-Result (Remove-SwDirectoryTree -Path $root) $true 'no report'
        Exists $root | Should -BeFalse
    }

    It 'F-19 refuses a tree with a whitelisted entry, removes nothing, and reads the state once' {
        $root = New-Tree 'full' @('keep/kept.txt', 'other.txt', 'nested/x.txt')
        Set-Whitelist @((P $root 'keep'))
        $script:RealState = Get-SwWhitelistState
        Mock Get-SwWhitelistState { $script:RealState }
        $before = Get-Listing $root
        $report = @{}
        Assert-Result (Remove-SwDirectoryTree -Path $root -Report $report) $false 'whitelisted entry'
        Same-Listing (Get-Listing $root) $before | Should -BeTrue
        Exists (P $root 'keep' 'kept.txt') | Should -BeTrue
        [string]$report['Reason'] | Should -BeLike 'refused: *'
        $report['Removed'] | Should -Be 0
        Should -Invoke -CommandName Get-SwWhitelistState -Times 1 -Exactly
    }

    It 'F-19 does not list again when it is given a validated tree' {
        $root = New-Tree 'full' @('a.txt', 'nested/b.txt')
        $tree = Get-SwSafeDirectoryTreeItems -Path $root
        $tree['Success'] | Should -BeTrue
        Mock Get-SwSafeDirectoryTreeItems { throw 'must not list again' }
        Assert-Result (Remove-SwDirectoryTree -Path $root -ValidatedTree $tree) $true 'given tree'
        Should -Invoke -CommandName Get-SwSafeDirectoryTreeItems -Times 0 -Exactly
        Exists $root | Should -BeFalse
    }

    It 'F-19 lists through Get-SwSafeDirectoryTreeItems with the path and a whitelist state when it is given no tree' {
        $root = New-Tree 'full' @('a.txt')
        Mock Get-SwSafeDirectoryTreeItems { & $script:RealSafeTree -Path $Path -WhitelistState $WhitelistState }
        Assert-Result (Remove-SwDirectoryTree -Path $root) $true 'listed here'
        Should -Invoke -CommandName Get-SwSafeDirectoryTreeItems -Times 1 -Exactly -ParameterFilter { (Fold $Path) -eq (Fold $root) -and $null -ne $WhitelistState }
    }

    It 'F-19 uses the whitelist state it is given and never reads one' {
        $root = New-Tree 'full' @('a.txt')
        $state = Get-SwWhitelistState
        Mock Get-SwWhitelistState { throw 'the state must not be read' }
        Assert-Result (Remove-SwDirectoryTree -Path $root -WhitelistState $state) $true 'given state'
        Should -Invoke -CommandName Get-SwWhitelistState -Times 0 -Exactly
    }

    It 'F-19 refuses with the reason of a validated tree that is not successful, and does not evaluate -CanRemove' {
        $root = New-Tree 'full' @('a.txt')
        $script:Probe = 0
        $report = @{}
        $tree = @{ Success = $false; Items = @(); RootSnapshot = $null; Reason = 'tree-canary' }
        Assert-Result (Remove-SwDirectoryTree -Path $root -ValidatedTree $tree -Report $report -CanRemove { $script:Probe++; $true }) $false 'refused tree'
        [string]$report['Reason'] | Should -BeLike 'refused: *tree-canary*'
        $report['OwnerHeld'] | Should -BeFalse
        $script:Probe | Should -Be 0
        Exists (P $root 'a.txt') | Should -BeTrue
    }

    It 'F-19 understands a test double of the tree that only has Success and Items' {
        $root = New-Tree 'full' @('a.txt')
        Mock Test-SwPathSnapshot { $true }
        $item = Get-Item -LiteralPath (P $root 'a.txt')
        Assert-Result (Remove-SwDirectoryTree -Path $root -ValidatedTree @{ Success = $true; Items = @($item) }) $true 'double'
        Exists $root | Should -BeFalse
    }

    It 'F-19 refuses when Test-SwSafePath rejects the root' {
        $root = New-Tree 'full' @('a.txt')
        $tree = Get-SwSafeDirectoryTreeItems -Path $root
        $script:Root = $root
        Mock Test-SwSafePath { (Fold $Path) -ne (Fold $script:Root) }
        $report = @{}
        Assert-Result (Remove-SwDirectoryTree -Path $root -ValidatedTree $tree -Report $report) $false 'root rejected'
        [string]$report['Reason'] | Should -BeLike 'refused: *'
        Exists (P $root 'a.txt') | Should -BeTrue
    }

    It 'F-19 refuses when the root is not the validated folder any more' {
        $root = New-Tree 'full' @('a.txt', 'b.txt')
        $tree = Get-SwSafeDirectoryTreeItems -Path $root
        $script:FakeIdentity[$root] = 'replaced'
        $before = Get-Listing $root
        $report = @{}
        Assert-Result (Remove-SwDirectoryTree -Path $root -ValidatedTree $tree -Report $report) $false 'replaced root'
        [string]$report['Reason'] | Should -BeLike 'refused: *'
        Same-Listing (Get-Listing $root) $before | Should -BeTrue
    }

    It 'F-19 gives false for a path that is not a folder and changes nothing' {
        $file = New-File (P $script:Target 'a.txt') 5
        Assert-Result (Remove-SwDirectoryTree -Path $file) $false 'a file'
        Exists $file | Should -BeTrue
        Assert-Result (Remove-SwDirectoryTree -Path (P $script:Target 'missing')) $false 'a missing path'
    }

    It 'F-19 counts the entries without the root in Total' {
        $root = New-Tree 'full' @('a.txt', 'nested/b.txt', 'nested/deeper/c.txt')
        $report = @{}
        $null = Remove-SwDirectoryTree -Path $root -Report $report
        $report['Total'] | Should -Be 5
    }

    It 'F-19 evaluates -CanRemove once, after the validation and before the first removal' {
        $root = New-Tree 'full' @('a.txt', 'nested/b.txt')
        Use-TreeEntrySpy
        Mock Get-SwSafeDirectoryTreeItems { $script:Events.Add('validate'); & $script:RealSafeTree -Path $Path -WhitelistState $WhitelistState }
        Assert-Result (Remove-SwDirectoryTree -Path $root -CanRemove { $script:Events.Add('can'); $true }) $true 'allowed'
        @($script:Events | Where-Object { $_ -ceq 'can' }).Count | Should -Be 1
        $script:Events.IndexOf('validate') | Should -BeLessThan $script:Events.IndexOf('can')
        $script:Events.IndexOf('can') | Should -BeLessThan @($script:Events | Where-Object { $_.StartsWith('remove:') } | ForEach-Object { $script:Events.IndexOf($_) })[0]
    }

    It 'F-19 does not remove anything when -CanRemove gives <Label>, and reports that the owner holds the folder' -ForEach $script:NotTrue {
        $root = New-Tree 'full' @('a.txt', 'nested/b.txt')
        Use-TreeEntrySpy
        $before = Get-Listing $root
        $report = @{}
        Assert-Result (Remove-SwDirectoryTree -Path $root -Report $report -CanRemove $Block) $false $Label
        $report['OwnerHeld'] | Should -BeTrue
        [string]$report['Reason'] | Should -Match '(?i)owner'
        Same-Listing (Get-Listing $root) $before | Should -BeTrue
        Should -Invoke -CommandName Remove-SwTreeEntry -Times 0 -Exactly
    }

    It 'F-19 removes the entries longest path first, every child before its parent' {
        $root = New-Tree 'full' @('a/b/c/deep.txt', 'a/f.txt', 'z.txt', 'x/y/w.txt')
        Use-TreeEntrySpy
        Assert-Result (Remove-SwDirectoryTree -Path $root) $true 'complete'
        $order = @($script:Removed)
        $order.Count | Should -Be 10
        foreach ($entry in $order) {
            if ((Fold $entry) -eq (Fold $root)) { continue }
            $parent = [System.IO.Path]::GetDirectoryName($entry)
            if ((Fold $parent) -eq (Fold $root)) { continue }
            $order.IndexOf($parent) | Should -BeGreaterThan $order.IndexOf($entry) -Because "$entry must go before $parent"
        }
        (Fold $order[$order.Count - 1]) | Should -BeExactly (Fold $root)
        for ($i = 1; $i -lt $order.Count; $i++) { $order[$i].Length | Should -BeLessOrEqual $order[$i - 1].Length }
    }

    It 'S-1 checks Test-SwSafePath and Test-SwPathSnapshot right before every entry and before the root' {
        $root = New-Tree 'full' @('a/f.txt', 'b.txt')
        $tree = Get-SwSafeDirectoryTreeItems -Path $root
        $script:EventLogging = $true
        Use-TreeEntrySpy
        Mock Test-SwSafePath { $script:Events.Add('safe:' + (Fold $Path)); $true }
        Assert-Result (Remove-SwDirectoryTree -Path $root -ValidatedTree $tree) $true 'complete'
        $events = @($script:Events)
        for ($i = 0; $i -lt $events.Count; $i++) {
            if (-not $events[$i].StartsWith('remove:')) { continue }
            $entry = $events[$i].Substring(7)
            $before = @($events[($i - 2)], $events[($i - 1)])
            $before | Should -Contain ('safe:' + $entry) -Because "the safety question comes right before removing $entry"
            $before | Should -Contain ('snap:' + $entry) -Because "the identity test comes right before removing $entry"
        }
    }

    It 'F-19 stops at the first entry that cannot be removed: false, Removed counts the earlier ones, the rest stays' {
        $root = New-Tree 'full' @('aaaaaaaa.txt', 'bbbbbbbb.txt', 'lock.txt')
        Use-TreeEntrySpy
        $script:FailOn = P $root 'lock.txt'
        $script:FailMessage = 'lock-canary'
        $report = @{}
        Assert-Result (Remove-SwDirectoryTree -Path $root -Report $report) $false 'a locked file'
        $report['Total'] | Should -Be 3
        $report['Removed'] | Should -Be 2
        Assert-Stopped ([string]$report['Reason']) (P $root 'lock.txt') 'lock-canary'
        Exists (P $root 'lock.txt') | Should -BeTrue
        Exists (P $root 'aaaaaaaa.txt') | Should -BeFalse
        Exists (P $root 'bbbbbbbb.txt') | Should -BeFalse
        Exists $root | Should -BeTrue
        @($script:Events | Where-Object { $_.StartsWith('remove:') }).Count | Should -Be 3 -Because 'the root is not tried after a failure'
    }

    It 'F-19 does not continue after a failure: the entries after the locked one stay' {
        $root = New-Tree 'full' @('locked-with-a-long-name.txt', 'a.txt', 'b.txt')
        Use-TreeEntrySpy
        $script:FailOn = P $root 'locked-with-a-long-name.txt'
        $script:FailMessage = 'lock-canary'
        $report = @{}
        Assert-Result (Remove-SwDirectoryTree -Path $root -Report $report) $false 'locked first'
        $report['Removed'] | Should -Be 0
        @($script:Events | Where-Object { $_.StartsWith('remove:') }).Count | Should -Be 1
        Exists (P $root 'a.txt') | Should -BeTrue
        Exists (P $root 'b.txt') | Should -BeTrue
    }

    It 'F-19 stops at an entry that is no longer safe right before its removal (<Kind>)' -ForEach @(
        @{ Kind = 'protected now'; Change = 'safe' }
        @{ Kind = 'replaced since the validation'; Change = 'identity' }
    ) {
        $root = New-Tree 'full' @('victim-with-a-long-name.txt', 'a.txt')
        $tree = Get-SwSafeDirectoryTreeItems -Path $root
        $script:Victim = P $root 'victim-with-a-long-name.txt'
        if ($Change -eq 'safe') { Mock Test-SwSafePath { (Fold $Path) -ne (Fold $script:Victim) } }
        else { $script:FakeIdentity[$script:Victim] = 'replaced' }
        Use-TreeEntrySpy
        $report = @{}
        Assert-Result (Remove-SwDirectoryTree -Path $root -ValidatedTree $tree -Report $report) $false $Kind
        Assert-Stopped ([string]$report['Reason']) $script:Victim '*'
        Exists $script:Victim | Should -BeTrue
        Exists (P $root 'a.txt') | Should -BeTrue
        $report['Removed'] | Should -Be 0
        Should -Invoke -CommandName Remove-SwTreeEntry -Times 0 -Exactly
    }

    It 'F-19 keeps the root when it is no longer safe after the entries were removed, and gives a reason' {
        $root = New-Tree 'full' @('a.txt', 'nested/b.txt')
        $tree = Get-SwSafeDirectoryTreeItems -Path $root
        $script:Root = $root
        $script:RootAsked = 0
        Mock Test-SwSafePath { if ((Fold $Path) -eq (Fold $script:Root)) { $script:RootAsked++; return ($script:RootAsked -lt 2) }; $true }
        $report = @{}
        Assert-Result (Remove-SwDirectoryTree -Path $root -ValidatedTree $tree -Report $report) $false 'root protected late'
        Exists $root | Should -BeTrue
        Exists (P $root 'a.txt') | Should -BeFalse
        $report['Removed'] | Should -Be $report['Total']
        [string]$report['Reason'] | Should -Not -BeNullOrEmpty
        [string]$report['Reason'] | Should -Not -BeLike 'stopped at *'
    }

    It 'F-19 keeps the root when its identity changed after the entries were removed, and gives a reason' {
        $root = New-Tree 'full' @('a.txt')
        $tree = Get-SwSafeDirectoryTreeItems -Path $root
        $script:Root = $root
        $script:RootChecked = 0
        Mock Test-SwPathSnapshot {
            if ((Fold ([string](Get-Field $Snapshot 'Path'))) -eq (Fold $script:Root)) { $script:RootChecked++; return ($script:RootChecked -lt 2) }
            $true
        }
        $report = @{}
        Assert-Result (Remove-SwDirectoryTree -Path $root -ValidatedTree $tree -Report $report) $false 'root replaced late'
        Exists $root | Should -BeTrue
        [string]$report['Reason'] | Should -Not -BeNullOrEmpty
    }

    It 'F-19 keeps a root that gained an entry and reports the message of the exception' {
        $root = New-Tree 'full' @('a.txt', 'nested/b.txt')
        $tree = Get-SwSafeDirectoryTreeItems -Path $root
        Use-TreeEntrySpy
        $script:LateRoot = $root
        $script:LateMade = $false
        $script:BeforeRemove = {
            param($p)
            if (-not $script:LateMade) { $script:LateMade = $true; New-File (P $script:LateRoot 'late.txt') 1 | Out-Null }
        }
        $report = @{}
        Assert-Result (Remove-SwDirectoryTree -Path $root -ValidatedTree $tree -Report $report) $false 'late entry'
        Exists (P $root 'late.txt') | Should -BeTrue
        Exists $root | Should -BeTrue
        $script:LastError | Should -Not -BeNullOrEmpty
        [string]$report['Reason'] | Should -BeLike ('*' + $script:LastError + '*')
        $report['Removed'] | Should -Be $report['Total']
    }

    It 'F-19 writes no operations log line itself' {
        $root = New-Tree 'full' @('a.txt', 'nested/b.txt')
        $null = Remove-SwDirectoryTree -Path $root
        $locked = New-Tree 'locked' @('c.txt')
        Use-TreeEntrySpy
        $script:FailOn = P $locked 'c.txt'
        $null = Remove-SwDirectoryTree -Path $locked
        $script:Ops.Count | Should -Be 0
        Should -Invoke -CommandName Write-SweeprOperation -Times 0 -Exactly
    }

    It 'F-19 does not throw when a removal fails (<Preference>)' -ForEach @(
        @{ Preference = 'Stop' }
        @{ Preference = 'Continue' }
        @{ Preference = 'SilentlyContinue' }
    ) {
        $root = New-Tree 'full' @('a.txt')
        Use-TreeEntrySpy
        $script:FailOn = P $root 'a.txt'
        $ErrorActionPreference = $Preference
        $result = $null
        $records = @(& { Remove-SwDirectoryTree -Path $root } 2>&1)
        @($records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count | Should -Be 0
        $records.Count | Should -Be 1
        $records[0] | Should -BeFalse
    }

    It 'F-19 [W] removes a folder link as the root and leaves the target with its files' {
        $target = New-Tree 'link-target' @('a.txt', 'nested/b.txt')
        $before = Get-Listing $target
        $link = P $script:Target 'link'
        New-TestLink $link $target
        $report = @{}
        Assert-Result (Remove-SwDirectoryTree -Path $link -Report $report) $true 'link root'
        Exists $link | Should -BeFalse
        Same-Listing (Get-Listing $target) $before | Should -BeTrue
        $report['Total'] | Should -Be 0
    }
}

Describe 'Entries that appear after the validation' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
    }
    AfterEach { Stop-Case }

    It 'F-21 never removes an entry that was created after the validation (<Kind>): the removal fails and the entry stays' -ForEach @(
        @{ Kind = 'an ordinary file'; Name = 'late.txt' }
        @{ Kind = 'a whitelisted entry'; Name = 'keep.txt' }
        @{ Kind = 'a protected folder'; Name = 'protected-late' }
    ) {
        $root = New-Tree 'full' @('a.txt', 'nested/b.txt')
        if ($Name -eq 'keep.txt') { Set-Whitelist @((P $root 'keep.txt')) }
        if ($Name -eq 'protected-late') { $script:ProtectedPaths = @((P $root 'protected-late')) }
        $script:LateRoot = $root
        $script:LateName = $Name
        Mock Get-SwValidatedTreeSize {
            if ($script:LateName -eq 'protected-late') { New-File (P $script:LateRoot $script:LateName 'x.txt') 1 | Out-Null }
            else { New-File (P $script:LateRoot $script:LateName) 1 | Out-Null }
            & $script:RealTreeSize -Tree $Tree
        }
        Assert-Result (Remove-SwItem -Path $root) $false $Kind
        Exists (P $root $Name) | Should -BeTrue
        Exists $root | Should -BeTrue
        Exists (P $root 'a.txt') | Should -BeFalse -Because 'the validated entries are removed'
        $script:FilesCleaned | Should -Be 0
        $script:TotalItems | Should -Be 0
        $script:TotalSizeCleaned | Should -Be 0
    }

    It 'F-21 reports the failure of such a folder as FAILED with the number of entries and the reason' {
        $root = New-Tree 'full' @('a.txt', 'nested/b.txt')
        $script:LateRoot = $root
        Mock Get-SwValidatedTreeSize { New-File (P $script:LateRoot 'late.txt') 1 | Out-Null; & $script:RealTreeSize -Tree $Tree }
        Assert-Result (Remove-SwItem -Path $root) $false 'late entry'
        $script:Ops.Count | Should -Be 1
        $script:Ops[0].Action | Should -BeExactly 'FAILED'
        $script:Ops[0].Path | Should -BeExactly $root
        $script:Ops[0].Detail | Should -Match '^incomplete: removed 3 of 3 entries; .+'
    }

    It 'S-10 leaves a nested entry that was created after the validation in place' {
        $root = New-Tree 'full' @('nested/b.txt')
        $script:LateRoot = $root
        Mock Get-SwValidatedTreeSize { New-File (P $script:LateRoot 'nested' 'late.txt') 1 | Out-Null; & $script:RealTreeSize -Tree $Tree }
        Assert-Result (Remove-SwItem -Path $root) $false 'late nested entry'
        Exists (P $root 'nested' 'late.txt') | Should -BeTrue
        Exists (P $root 'nested') | Should -BeTrue
    }
}

# ============================================================================
# Remove-SwItem
# ============================================================================

Describe 'Remove-SwItem checks in order' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
    }
    AfterEach { Stop-Case }

    It 'F-22 refuses a path that is not complete (<Label>): false, nothing asked, nothing logged, nothing changed' -ForEach $script:IncompleteForms {
        $file = New-File (P $script:Target 'rel-file.txt') 5
        Set-Env 'SWEEPR_TEST_PROVIDER_VARIABLE' 'present'
        $path = switch ($Form) {
            'relative' { 'rel-file.txt' }
            'dot' { '.' + $script:Sep + 'rel-file.txt' }
            'parent' { '..' + $script:Sep + 'target' + $script:Sep + 'rel-file.txt' }
            'rootrelative' { '\target\rel-file.txt' }
            'driverelative' { 'C:rel-file.txt' }
            'registry' { 'HKCU:\Software\SweeprTestDoesNotExist' }
            'environment' { 'Env:SWEEPR_TEST_PROVIDER_VARIABLE' }
        }
        Mock Test-SwSafePath { $true }
        Use-TreeEntrySpy
        Mock Remove-SwDirectoryTree { $true }
        $before = Get-Listing $script:Target
        $oldLocation = Get-Location
        $oldDirectory = [System.Environment]::CurrentDirectory
        try {
            Set-Location -LiteralPath $script:Target
            [System.Environment]::CurrentDirectory = $script:Target
            $result = @(Remove-SwItem -Path $path)
        }
        finally {
            Set-Location -LiteralPath $oldLocation.Path
            [System.Environment]::CurrentDirectory = $oldDirectory
        }
        $result.Count | Should -Be 1
        Assert-Result $result[0] $false $Label
        Same-Listing (Get-Listing $script:Target) $before | Should -BeTrue
        [System.Environment]::GetEnvironmentVariable('SWEEPR_TEST_PROVIDER_VARIABLE') | Should -BeExactly 'present'
        Should -Invoke -CommandName Test-SwSafePath -Times 0 -Exactly
        Should -Invoke -CommandName Get-SwPathSnapshot -Times 0 -Exactly
        Should -Invoke -CommandName Remove-SwTreeEntry -Times 0 -Exactly
        Should -Invoke -CommandName Remove-SwDirectoryTree -Times 0 -Exactly
        $script:Ops.Count | Should -Be 0
        $script:Said.Count | Should -Be 0
        $script:DrySaid.Count | Should -Be 0
        $script:FilesCleaned | Should -Be 0
    }

    It 'F-22 accepts a complete path written with forward slashes and logs it as it was written' {
        $file = New-File (P $script:Target 'a.txt') 10
        $written = $file.Replace('\', '/')
        Assert-Result (Remove-SwItem -Path $written) $true 'forward slashes'
        Exists $file | Should -BeFalse
        $script:Ops.Count | Should -Be 1
        $script:Ops[0].Path | Should -BeExactly $written
    }

    It 'F-22 gives false without a trace for a path that Test-SwSafePath rejects (<Kind>)' -ForEach @(
        @{ Kind = 'a protected path'; Whitelist = $false }
        @{ Kind = 'a whitelisted path'; Whitelist = $true }
    ) {
        if ($Whitelist) { $file = New-File (P $script:Target 'keep.txt') 5; Set-Whitelist @($file) }
        else { $file = New-File (P $script:Prot 'x.txt') 5 }
        Use-TreeEntrySpy
        $result = @(Remove-SwItem -Path $file)
        $result.Count | Should -Be 1
        Assert-Result $result[0] $false $Kind
        Exists $file | Should -BeTrue
        Should -Invoke -CommandName Get-SwPathSnapshot -Times 0 -Exactly
        Should -Invoke -CommandName Remove-SwTreeEntry -Times 0 -Exactly
        $script:Ops.Count | Should -Be 0
        $script:Said.Count | Should -Be 0
        $script:DrySaid.Count | Should -Be 0
        $script:FilesCleaned | Should -Be 0
        $script:TotalItems | Should -Be 0
    }

    It 'F-22 reads the whitelist state once for a file and once for a tree' {
        $script:RealState = Get-SwWhitelistState
        Mock Get-SwWhitelistState { $script:RealState }
        $file = New-File (P $script:Target 'a.txt') 10
        Assert-Result (Remove-SwItem -Path $file) $true 'file'
        Should -Invoke -CommandName Get-SwWhitelistState -Times 1 -Exactly
        $root = New-Tree 'full' @('a.txt', 'nested/b.txt')
        Assert-Result (Remove-SwItem -Path $root) $true 'tree'
        Should -Invoke -CommandName Get-SwWhitelistState -Times 2 -Exactly
    }

    It 'F-22 gives false and stays silent for a path that does not exist, and asks for no identity' {
        $result = @(Remove-SwItem -Path (P $script:Target 'missing.txt'))
        $result.Count | Should -Be 1
        Assert-Result $result[0] $false 'missing'
        Should -Invoke -CommandName Get-SwPathSnapshot -Times 0 -Exactly
        $script:Ops.Count | Should -Be 0
        $script:Said.Count | Should -Be 0
    }

    It 'F-22 gives false and stays silent when the entry has no identity' {
        $file = New-File (P $script:Target 'a.txt') 5
        $dir = New-Tree 'full' @('b.txt')
        Mock Get-SwPathSnapshot { $null }
        Use-TreeEntrySpy
        Assert-Result (Remove-SwItem -Path $file) $false 'file'
        Assert-Result (Remove-SwItem -Path $dir) $false 'folder'
        Exists $file | Should -BeTrue
        Exists (P $dir 'b.txt') | Should -BeTrue
        $script:Ops.Count | Should -Be 0
        $script:Said.Count | Should -Be 0
        Should -Invoke -CommandName Remove-SwTreeEntry -Times 0 -Exactly
    }

    It 'F-22 asks for the identity with -AllowLeafLink, but not with -Recycle' {
        $file = New-File (P $script:Target 'a.txt') 5
        Mock Move-SwItemToRecycleBin { }
        Assert-Result (Remove-SwItem -Path $file) $true 'removal'
        Should -Invoke -CommandName Get-SwPathSnapshot -Times 1 -ParameterFilter { (Fold $Path) -eq (Fold $file) -and $AllowLeafLink }
        $other = New-File (P $script:Target 'b.txt') 5
        Assert-Result (Remove-SwItem -Path $other -Recycle) $true 'recycling'
        Should -Invoke -CommandName Get-SwPathSnapshot -Times 1 -ParameterFilter { (Fold $Path) -eq (Fold $other) -and -not $AllowLeafLink }
        Should -Invoke -CommandName Get-SwPathSnapshot -Times 0 -Exactly -ParameterFilter { (Fold $Path) -eq (Fold $other) -and $AllowLeafLink }
    }

    It 'F-22 refuses a folder that holds a protected entry: SKIPPED with refused and the reason, false, nothing removed (real run)' {
        $root = New-Tree 'proj' @('a.txt', 'keep/k.txt', 'nested/b.txt')
        Set-Whitelist @((P $root 'keep'))
        $before = Get-Listing $root
        $result = @(Remove-SwItem -Path $root)
        $result.Count | Should -Be 1
        Assert-Result $result[0] $false 'refused folder'
        Same-Listing (Get-Listing $root) $before | Should -BeTrue
        $script:Ops.Count | Should -Be 1
        $script:Ops[0].Action | Should -BeExactly 'SKIPPED'
        $script:Ops[0].Path | Should -BeExactly $root
        $script:Ops[0].Detail | Should -BeLike 'refused: *'
        $script:Ops[0].Detail | Should -BeLike ('*' + (Get-Tail (P $root 'keep')) + '*')
        $script:FilesCleaned | Should -Be 0
        $script:Said.Count | Should -Be 0
    }

    It 'F-22 refuses such a folder in a dry run without writing anything' {
        $root = New-Tree 'proj' @('a.txt', 'keep/k.txt')
        Set-Whitelist @((P $root 'keep'))
        $script:SweeprDryRunMode = $true
        Assert-Result (Remove-SwItem -Path $root) $false 'refused folder in a dry run'
        $script:Ops.Count | Should -Be 0
        $script:DrySaid.Count | Should -Be 0
        $script:FilesCleaned | Should -Be 0
        $script:TotalItems | Should -Be 0
    }

    It 'F-22 measures a folder with one call of Get-SwValidatedTreeSize and never with Get-SwPathSize (<Mode>)' -ForEach @(
        @{ Mode = 'real run'; Dry = $false }
        @{ Mode = 'dry run'; Dry = $true }
    ) {
        $root = New-Tree 'full' @('a.txt=100', 'nested/b.txt=200')
        $script:SweeprDryRunMode = $Dry
        Mock Get-SwPathSize { throw 'Get-SwPathSize must not measure a folder' }
        Mock Get-SwValidatedTreeSize { & $script:RealTreeSize -Tree $Tree }
        Assert-Result (Remove-SwItem -Path $root) $true $Mode
        Should -Invoke -CommandName Get-SwValidatedTreeSize -Times 1 -Exactly
        Should -Invoke -CommandName Get-SwPathSize -Times 0 -Exactly
    }

    It 'F-22 measures a file with Get-SwPathSize and reports that size' {
        $file = New-File (P $script:Target 'a.txt') 10
        Mock Get-SwPathSize { 4096 }
        Assert-Result (Remove-SwItem -Path $file) $true 'file'
        Should -Invoke -CommandName Get-SwPathSize -Times 1 -Exactly -ParameterFilter { (Fold $Path) -eq (Fold $file) }
        $script:Ops[0].Detail | Should -BeExactly (Format-SwByteSize -Bytes 4096)
        $script:TotalSizeCleaned | Should -Be 4
    }

    It 'F-22 asks in this order: safety, tree, measurement, safety, identity, guard, identity (folder)' {
        $root = New-Tree 'full' @('a.txt', 'nested/b.txt')
        $script:SweeprDryRunMode = $true
        $script:EventLogging = $true
        Mock Test-SwSafePath { $script:Events.Add('safe:' + (Fold $Path)); $true }
        Mock Get-SwSafeDirectoryTreeItems { $script:Events.Add('tree'); & $script:RealSafeTree -Path $Path -WhitelistState $WhitelistState }
        Mock Get-SwValidatedTreeSize { $script:Events.Add('measure'); & $script:RealTreeSize -Tree $Tree }
        Assert-Result (Remove-SwItem -Path $root -Guard { $script:Events.Add('guard'); $true }) $true 'folder'
        $r = 'safe:' + (Fold $root)
        $s = 'snap:' + (Fold $root)
        Test-Subsequence @($script:Events) @($r, 'tree', 'measure', $r, $s, 'guard', $s) | Should -BeTrue -Because ($script:Events -join ' ; ')
    }

    It 'F-22 asks in this order: safety, measurement, safety, identity, guard, identity (file)' {
        $file = New-File (P $script:Target 'a.txt') 10
        $script:SweeprDryRunMode = $true
        $script:EventLogging = $true
        Mock Test-SwSafePath { $script:Events.Add('safe:' + (Fold $Path)); $true }
        Mock Get-SwPathSize { $script:Events.Add('measure'); 10 }
        Assert-Result (Remove-SwItem -Path $file -Guard { $script:Events.Add('guard'); $true }) $true 'file'
        $r = 'safe:' + (Fold $file)
        $s = 'snap:' + (Fold $file)
        Test-Subsequence @($script:Events) @($r, 'measure', $r, $s, 'guard', $s) | Should -BeTrue -Because ($script:Events -join ' ; ')
    }

    It 'F-22 gives false and writes nothing when the folder is replaced while it is measured' {
        $root = New-Tree 'full' @('a.txt', 'nested/b.txt')
        $script:Swap = $root
        Use-TreeEntrySpy
        Mock Remove-SwDirectoryTree { throw 'must not remove' }
        Mock Move-SwItemToRecycleBin { throw 'must not recycle' }
        Mock Get-SwValidatedTreeSize {
            [System.IO.Directory]::Move($script:Swap, $script:Swap + '.orig')
            [void][System.IO.Directory]::CreateDirectory($script:Swap)
            [System.IO.File]::WriteAllText((Join-Path $script:Swap 'replacement.txt'), 'new')
            $script:FakeIdentity[$script:Swap] = 'replaced'
            & $script:RealTreeSize -Tree $Tree
        }
        Assert-Result (Remove-SwItem -Path $root) $false 'replaced folder'
        Exists (P $root 'replacement.txt') | Should -BeTrue
        Exists (P ($root + '.orig') 'a.txt') | Should -BeTrue
        Exists (P ($root + '.orig') 'nested' 'b.txt') | Should -BeTrue
        Should -Invoke -CommandName Remove-SwTreeEntry -Times 0 -Exactly
        Should -Invoke -CommandName Remove-SwDirectoryTree -Times 0 -Exactly
        Should -Invoke -CommandName Move-SwItemToRecycleBin -Times 0 -Exactly
        $script:Ops.Count | Should -Be 0
        $script:FilesCleaned | Should -Be 0
    }

    It 'F-22 gives false and writes nothing when the file is replaced while it is measured' {
        $file = New-File (P $script:Target 'a.txt') 10
        $script:Swap = $file
        Use-TreeEntrySpy
        Mock Get-SwPathSize { $script:FakeIdentity[$script:Swap] = 'replaced'; 10 }
        Assert-Result (Remove-SwItem -Path $file) $false 'replaced file'
        Exists $file | Should -BeTrue
        Should -Invoke -CommandName Remove-SwTreeEntry -Times 0 -Exactly
        $script:Ops.Count | Should -Be 0
    }

    It 'F-22 gives false and writes nothing when the path is no longer safe after the measurement (<Kind>)' -ForEach @(
        @{ Kind = 'file'; IsFolder = $false }
        @{ Kind = 'folder'; IsFolder = $true }
    ) {
        if ($IsFolder) { $path = New-Tree 'full' @('a.txt') } else { $path = New-File (P $script:Target 'a.txt') 10 }
        $script:Asked = 0
        $script:Subject = $path
        Mock Test-SwSafePath { if ((Fold $Path) -eq (Fold $script:Subject)) { $script:Asked++; return ($script:Asked -lt 2) }; $true }
        Use-TreeEntrySpy
        Assert-Result (Remove-SwItem -Path $path) $false $Kind
        Exists $path | Should -BeTrue
        Should -Invoke -CommandName Remove-SwTreeEntry -Times 0 -Exactly
        $script:Ops.Count | Should -Be 0
        $script:FilesCleaned | Should -Be 0
    }

    It 'F-23 removes with a guard that gives exactly one boolean true' {
        $file = New-File (P $script:Target 'a.txt') 10
        Assert-Result (Remove-SwItem -Path $file -Guard { $true }) $true 'true'
        Exists $file | Should -BeFalse
    }

    It 'F-23 does not remove when the guard gives <Label>: false, nothing removed, nothing logged' -ForEach $script:NotTrue {
        $file = New-File (P $script:Target 'a.txt') 10
        Use-TreeEntrySpy
        $result = @(Remove-SwItem -Path $file -Guard $Block)
        $result.Count | Should -Be 1
        Assert-Result $result[0] $false $Label
        Exists $file | Should -BeTrue
        Should -Invoke -CommandName Remove-SwTreeEntry -Times 0 -Exactly
        $script:Ops.Count | Should -Be 0
        $script:Said.Count | Should -Be 0
        $script:FilesCleaned | Should -Be 0
    }

    It 'F-23 hands the path to the guard as its argument' {
        $file = New-File (P $script:Target 'a.txt') 10
        $script:Given = $null
        Assert-Result (Remove-SwItem -Path $file -Guard { param($p) $script:Given = $p; $true }) $true 'removed'
        $script:Given | Should -BeExactly $file
    }

    It 'F-23 evaluates the guard in a dry run too, so the preview names only what a real run would remove' {
        $keep = New-File (P $script:Target 'keep.txt') 10
        $go = New-File (P $script:Target 'go.txt') 10
        $script:SweeprDryRunMode = $true
        $script:Probe = 0
        Assert-Result (Remove-SwItem -Path $keep -Guard { $script:Probe++; $false }) $false 'guard says no'
        $script:DrySaid.Count | Should -Be 0
        $script:FilesCleaned | Should -Be 0
        Assert-Result (Remove-SwItem -Path $go -Guard { $script:Probe++; $true }) $true 'guard says yes'
        $script:Probe | Should -Be 2
        $script:DrySaid.Count | Should -Be 1
        $script:FilesCleaned | Should -Be 1
        Exists $go | Should -BeTrue
    }

    It 'F-23 does not evaluate the guard for a path that the checks refuse (<Kind>)' -ForEach @(
        @{ Kind = 'protected'; Setup = 'protected' }
        @{ Kind = 'missing'; Setup = 'missing' }
        @{ Kind = 'without identity'; Setup = 'noidentity' }
        @{ Kind = 'a folder that holds a protected entry'; Setup = 'tree' }
        @{ Kind = 'not complete'; Setup = 'relative' }
    ) {
        $script:Probe = 0
        switch ($Setup) {
            'protected' { $path = New-File (P $script:Prot 'x.txt') 5 }
            'missing' { $path = P $script:Target 'missing.txt' }
            'noidentity' { $path = New-File (P $script:Target 'a.txt') 5; Mock Get-SwPathSnapshot { $null } }
            'tree' { $path = New-Tree 'proj' @('a.txt', 'keep/k.txt'); Set-Whitelist @((P $path 'keep')) }
            'relative' { $path = 'relative-file.txt' }
        }
        Assert-Result (Remove-SwItem -Path $path -Guard { $script:Probe++; $true }) $false $Kind
        $script:Probe | Should -Be 0
    }

    It 'F-23 gives false and stays silent when the guard changes the identity of the entry' {
        $file = New-File (P $script:Target 'a.txt') 10
        $script:Subject = $file
        Use-TreeEntrySpy
        Assert-Result (Remove-SwItem -Path $file -Guard { $script:FakeIdentity[$script:Subject] = 'replaced'; $true }) $false 'identity changed by the guard'
        Exists $file | Should -BeTrue
        Should -Invoke -CommandName Remove-SwTreeEntry -Times 0 -Exactly
        $script:Ops.Count | Should -Be 0
    }

    It 'F-24 gives exactly one boolean and nothing else to the pipeline (<Case>)' -ForEach @(
        @{ Case = 'a real removal'; Setup = 'real' }
        @{ Case = 'a failed removal'; Setup = 'failed' }
        @{ Case = 'a preview'; Setup = 'dry' }
        @{ Case = 'a refused path'; Setup = 'refused' }
        @{ Case = 'a folder'; Setup = 'folder' }
    ) {
        switch ($Setup) {
            'real' { $path = New-File (P $script:Target 'a.txt') 10; $expected = $true }
            'failed' { $path = New-File (P $script:Target 'a.txt') 10; Mock Remove-Item { throw 'access-denied-canary' }; $expected = $false }
            'dry' { $path = New-File (P $script:Target 'a.txt') 10; $script:SweeprDryRunMode = $true; $expected = $true }
            'refused' { $path = New-File (P $script:Prot 'a.txt') 10; $expected = $false }
            'folder' { $path = New-Tree 'full' @('a.txt'); $expected = $true }
        }
        $result = @(Remove-SwItem -Path $path)
        $result.Count | Should -Be 1
        $result[0] | Should -BeOfType [bool]
        $result[0] | Should -Be $expected
    }
}

Describe 'Remove-SwItem removes and previews' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
    }
    AfterEach { Stop-Case }

    It 'F-25 removes nothing, moves nothing and logs nothing in a dry run, and gives true' {
        $file = New-File (P $script:Target 'a.txt') 4096
        $script:SweeprDryRunMode = $true
        $script:Calls = 0
        Mock Remove-Item { $script:Calls++ }
        Use-TreeEntrySpy
        Mock Remove-SwDirectoryTree { throw 'must not remove' }
        Mock Move-SwItemToRecycleBin { throw 'must not recycle' }
        Assert-Result (Remove-SwItem -Path $file) $true 'preview'
        Exists $file | Should -BeTrue
        $script:Calls | Should -Be 0
        Should -Invoke -CommandName Remove-SwTreeEntry -Times 0 -Exactly
        Should -Invoke -CommandName Remove-SwDirectoryTree -Times 0 -Exactly
        Should -Invoke -CommandName Move-SwItemToRecycleBin -Times 0 -Exactly
        $script:Ops.Count | Should -Be 0
        Should -Invoke -CommandName Write-SweeprOperation -Times 0 -Exactly
    }

    It 'F-25 counts the preview like a removal: kilobytes rounded up, one path, one item' {
        $file = New-File (P $script:Target 'a.txt') 4097
        $script:SweeprDryRunMode = $true
        Assert-Result (Remove-SwItem -Path $file) $true 'preview'
        $script:TotalSizeCleaned | Should -Be 5
        $script:FilesCleaned | Should -Be 1
        $script:TotalItems | Should -Be 1
    }

    It 'F-25 writes one preview line with the name and the size and marks section activity' {
        $file = New-File (P $script:Target 'a.txt') 4096
        $script:SweeprDryRunMode = $true
        Assert-Result (Remove-SwItem -Path $file) $true 'preview'
        $script:DrySaid.Count | Should -Be 1
        $script:DrySaid[0] | Should -BeLike '*a.txt*'
        $script:DrySaid[0] | Should -BeLike ('*' + (Format-SwByteSize -Bytes 4096) + '*')
        $script:Said.Count | Should -Be 0
        Should -Invoke -CommandName Set-SectionActivity -Times 1 -Exactly
    }

    It 'F-25 names the description instead of the leaf when a description is given' {
        $file = New-File (P $script:Target 'a.txt') 4096
        $script:SweeprDryRunMode = $true
        Assert-Result (Remove-SwItem -Path $file -Description 'Old cache') $true 'preview'
        $script:DrySaid[0] | Should -BeLike '*Old cache*'
    }

    It 'F-25 adds the list entry for a file: description, path, bytes and one file' {
        $file = New-File (P $script:Target 'a.txt') 4096
        $script:SweeprDryRunMode = $true
        Mock Add-SwDryRunListEntries { }
        Assert-Result (Remove-SwItem -Path $file) $true 'preview'
        Should -Invoke -CommandName Add-SwDryRunListEntries -Times 1 -Exactly -ParameterFilter {
            $Description -eq 'a.txt' -and @($Paths).Count -eq 1 -and (Fold @($Paths)[0]) -eq (Fold $file) -and @($SizeBytes).Count -eq 1 -and @($SizeBytes)[0] -eq 4096 -and @($FileCounts).Count -eq 1 -and @($FileCounts)[0] -eq 1
        }
    }

    It 'F-25 adds the list entry for a folder with the number of files in the validated tree and the given description' {
        $root = New-Tree 'full' @('a.txt=100', 'nested/b.txt=200', 'nested/deeper/c.txt=300')
        $script:SweeprDryRunMode = $true
        Mock Add-SwDryRunListEntries { }
        Assert-Result (Remove-SwItem -Path $root -Description 'Example cache') $true 'preview'
        Should -Invoke -CommandName Add-SwDryRunListEntries -Times 1 -Exactly -ParameterFilter {
            $Description -eq 'Example cache' -and (Fold @($Paths)[0]) -eq (Fold $root) -and @($SizeBytes)[0] -eq 600 -and @($FileCounts)[0] -eq 3
        }
    }

    It 'F-25 puts the preview into the collector when there is one' {
        $root = New-Tree 'full' @('a.txt=100', 'b.txt=200')
        $script:SweeprDryRunMode = $true
        $script:DryRunCollector = New-Object 'System.Collections.Generic.List[object]'
        Assert-Result (Remove-SwItem -Path $root -Description 'Example cache') $true 'preview'
        $script:DryRunCollector.Count | Should -Be 1
        $entry = $script:DryRunCollector[0]
        $entry.Section | Should -BeExactly 'Example section'
        $entry.Description | Should -BeExactly 'Example cache'
        (Fold $entry.Path) | Should -BeExactly (Fold $root)
        $entry.SizeBytes | Should -Be 300
        $entry.Count | Should -Be 2
    }

    It 'F-25 with -Recycle on a folder lists and validates the tree once more and then previews without kilobytes' {
        $root = New-Tree 'full' @('a.txt=2000', 'nested/b.txt=3000')
        $script:SweeprDryRunMode = $true
        Mock Move-SwItemToRecycleBin { throw 'the shell must not be called' }
        Mock Get-SwSafeDirectoryTreeItems { & $script:RealSafeTree -Path $Path -WhitelistState $WhitelistState }
        Assert-Result (Remove-SwItem -Path $root -Recycle) $true 'recycle preview'
        Should -Invoke -CommandName Get-SwSafeDirectoryTreeItems -Times 2 -Exactly
        Should -Invoke -CommandName Move-SwItemToRecycleBin -Times 0 -Exactly
        $script:TotalSizeCleaned | Should -Be 0
        $script:FilesCleaned | Should -Be 1
        $script:TotalItems | Should -Be 1
        Exists $root | Should -BeTrue
    }

    It 'F-25 with -Recycle previews a file with the same counts and no kilobytes' {
        $file = New-File (P $script:Target 'a.txt') 5000
        $script:SweeprDryRunMode = $true
        Mock Move-SwItemToRecycleBin { throw 'the shell must not be called' }
        Assert-Result (Remove-SwItem -Path $file -Recycle) $true 'recycle preview of a file'
        $script:TotalSizeCleaned | Should -Be 0
        $script:FilesCleaned | Should -Be 1
    }

    It 'F-25 gives false for a -Recycle preview of a folder that gained a whitelisted entry while it was measured' {
        $root = New-Tree 'full' @('a.txt')
        Set-Whitelist @((P $root 'keep.txt'))
        $script:SweeprDryRunMode = $true
        $script:LateRoot = $root
        Mock Move-SwItemToRecycleBin { throw 'the shell must not be called' }
        Mock Get-SwValidatedTreeSize { New-File (P $script:LateRoot 'keep.txt') 1 | Out-Null; & $script:RealTreeSize -Tree $Tree }
        Assert-Result (Remove-SwItem -Path $root -Recycle) $false 'preview of a folder with a late whitelisted entry'
        Exists (P $root 'keep.txt') | Should -BeTrue
        $script:FilesCleaned | Should -Be 0
        $script:DrySaid.Count | Should -Be 0
        Should -Invoke -CommandName Move-SwItemToRecycleBin -Times 0 -Exactly
    }

    It 'F-26 removes a file of 4096 bytes: true, one REMOVED line, 4 kilobytes, one path, one item' {
        $file = New-File (P $script:Target 'a.txt') 4096
        Assert-Result (Remove-SwItem -Path $file) $true 'removal'
        Exists $file | Should -BeFalse
        $script:Ops.Count | Should -Be 1
        $script:Ops[0].Action | Should -BeExactly 'REMOVED'
        $script:Ops[0].Path | Should -BeExactly $file
        $script:Ops[0].Detail | Should -BeExactly (Format-SwByteSize -Bytes 4096)
        $stats = Get-SwCleanupStats
        $stats['TotalSizeKB'] | Should -Be 4
        $stats['FilesCleaned'] | Should -Be 1
        $stats['TotalItems'] | Should -Be 1
    }

    It 'F-26 writes one success line with the name and the size, and marks section activity' {
        $file = New-File (P $script:Target 'a.txt') 4096
        Assert-Result (Remove-SwItem -Path $file -Description 'Old cache') $true 'removal'
        $script:Said.Count | Should -Be 1
        $script:Said[0] | Should -BeLike '*Old cache*'
        $script:Said[0] | Should -BeLike ('*' + (Format-SwByteSize -Bytes 4096) + '*')
        $script:DrySaid.Count | Should -Be 0
        Should -Invoke -CommandName Set-SectionActivity -Times 1 -Exactly
    }

    It 'F-26 removes a file through Remove-SwTreeEntry' {
        $file = New-File (P $script:Target 'a.txt') 10
        Use-TreeEntrySpy
        Assert-Result (Remove-SwItem -Path $file) $true 'removal'
        Should -Invoke -CommandName Remove-SwTreeEntry -Times 1 -Exactly -ParameterFilter { (Fold $Path) -eq (Fold $file) }
    }

    It 'F-26 removes a folder of six files without -Recurse and with every combination of the switches (<Switches>)' -ForEach @(
        @{ Switches = 'none'; Force = $false; Recurse = $false }
        @{ Switches = '-Force'; Force = $true; Recurse = $false }
        @{ Switches = '-Recurse'; Force = $false; Recurse = $true }
        @{ Switches = '-Force -Recurse'; Force = $true; Recurse = $true }
    ) {
        $root = New-Tree 'full' @('a.txt', 'nested/b.txt', 'nested/c.txt', 'nested/d.txt', 'nested/e.txt', 'nested/f.txt')
        Assert-Result (Remove-SwItem -Path $root -Force:$Force -Recurse:$Recurse) $true $Switches
        Exists $root | Should -BeFalse
        $script:Ops.Count | Should -Be 1
        $script:Ops[0].Action | Should -BeExactly 'REMOVED'
    }

    It 'F-26 removes a folder through Remove-SwDirectoryTree with the validated tree, a report and the state' {
        $root = New-Tree 'full' @('a.txt')
        Mock Remove-SwDirectoryTree { $true }
        Assert-Result (Remove-SwItem -Path $root) $true 'removal'
        Should -Invoke -CommandName Remove-SwDirectoryTree -Times 1 -Exactly -ParameterFilter {
            (Fold $Path) -eq (Fold $root) -and $ValidatedTree -is [hashtable] -and $ValidatedTree['Success'] -and $Report -is [hashtable] -and $null -ne $WhitelistState
        }
    }

    It 'F-26 never uses Remove-Item on a folder or with -Recurse' {
        $script:Seen = New-Object System.Collections.Generic.List[string]
        Mock Remove-Item {
            $target = ''
            if ($null -ne $LiteralPath) { $target = [string]@($LiteralPath)[0] } elseif ($null -ne $Path) { $target = [string]@($Path)[0] }
            $script:Seen.Add($target + '|' + [bool]$Recurse)
            & $script:RealRemoveItem @PesterBoundParameters
        }
        $root = New-Tree 'full' @('a.txt', 'nested/b.txt')
        Assert-Result (Remove-SwItem -Path $root -Recurse -Force) $true 'removal'
        @($script:Seen | Where-Object { $_.EndsWith('|True') }).Count | Should -Be 0
        foreach ($entry in $script:Seen) { [System.IO.Path]::GetExtension($entry.Split('|')[0]) | Should -BeExactly '.txt' }
    }

    It 'F-26 gives false, FAILED with the message of the exception and no count when a file cannot be removed' {
        $file = New-File (P $script:Target 'a.txt') 10
        Mock Remove-Item { throw 'access-denied-canary' }
        Assert-Result (Remove-SwItem -Path $file) $false 'failed removal'
        Exists $file | Should -BeTrue
        $script:Ops.Count | Should -Be 1
        $script:Ops[0].Action | Should -BeExactly 'FAILED'
        $script:Ops[0].Path | Should -BeExactly $file
        $script:Ops[0].Detail | Should -BeExactly 'access-denied-canary'
        $script:FilesCleaned | Should -Be 0
        $script:TotalItems | Should -Be 0
        $script:TotalSizeCleaned | Should -Be 0
        $script:Said.Count | Should -Be 0
    }

    It 'F-26 gives false and FAILED with the entry counts and the stop position when a file in a folder is locked' {
        $root = New-Tree 'full' @('aaaaaaaa.txt', 'bbbbbbbb.txt', 'lock.txt')
        Use-TreeEntrySpy
        $script:FailOn = P $root 'lock.txt'
        $script:FailMessage = 'lock-canary'
        Assert-Result (Remove-SwItem -Path $root) $false 'locked file'
        $script:Ops.Count | Should -Be 1
        $script:Ops[0].Action | Should -BeExactly 'FAILED'
        $script:Ops[0].Path | Should -BeExactly $root
        Assert-Incomplete $script:Ops[0].Detail 2 3 (P $root 'lock.txt') 'lock-canary'
        $script:FilesCleaned | Should -Be 0
        $script:TotalItems | Should -Be 0
        $script:TotalSizeCleaned | Should -Be 0
        Exists (P $root 'lock.txt') | Should -BeTrue
    }

    It 'F-26 checks the type of a file again right before removing it: a folder that took its place stays' {
        $file = New-File (P $script:Target 'a.txt') 10
        $script:Subject = $file
        Use-TreeEntrySpy
        $guard = {
            [System.IO.File]::Delete($script:Subject)
            [void][System.IO.Directory]::CreateDirectory($script:Subject)
            $true
        }
        Assert-Result (Remove-SwItem -Path $file -Guard $guard) $false 'file replaced by a folder'
        [System.IO.Directory]::Exists($file) | Should -BeTrue
        Should -Invoke -CommandName Remove-SwTreeEntry -Times 0 -Exactly
        $script:Ops.Count | Should -Be 0
    }

    It 'F-26 asks for the identity again after the guard and right before the removal' {
        $file = New-File (P $script:Target 'a.txt') 10
        $script:EventLogging = $true
        Assert-Result (Remove-SwItem -Path $file -Guard { $true }) $true 'removal'
        @($script:Events | Where-Object { $_ -ceq ('snap:' + (Fold $file)) }).Count | Should -BeGreaterOrEqual 3
    }

    It 'F-26 does not remove a file entry that became a link to a folder right before the removal' {
        $target = New-Dir (P $script:Work 'target-dir')
        $file = New-File (P $script:Target 'a.txt') 10
        $script:Subject = $file
        $script:LinkTarget = $target
        Use-TreeEntrySpy
        $guard = {
            [System.IO.File]::Delete($script:Subject)
            New-TestLink $script:Subject $script:LinkTarget
            $true
        }
        Assert-Result (Remove-SwItem -Path $file -Guard $guard) $false 'file replaced by a link'
        Should -Invoke -CommandName Remove-SwTreeEntry -Times 0 -Exactly
        Exists $target | Should -BeTrue
    }

    It 'F-27 recycles a folder through Move-SwItemToRecycleBin only: true, no kilobytes, one path, one item, no tree removal' {
        $root = New-Tree 'full' @('fixture.txt=5000')
        Mock Move-SwItemToRecycleBin { }
        Mock Remove-SwDirectoryTree { throw 'must not remove' }
        Use-TreeEntrySpy
        Assert-Result (Remove-SwItem -Path $root -Recurse -Recycle) $true 'recycle'
        Should -Invoke -CommandName Move-SwItemToRecycleBin -Times 1 -Exactly -ParameterFilter {
            (Fold $Path) -eq (Fold $root) -and $null -ne $Snapshot -and (Fold ([string](Get-Field $Snapshot 'Path'))) -eq (Fold $root)
        }
        Should -Invoke -CommandName Remove-SwDirectoryTree -Times 0 -Exactly
        Should -Invoke -CommandName Remove-SwTreeEntry -Times 0 -Exactly
        $script:TotalSizeCleaned | Should -Be 0
        $script:FilesCleaned | Should -Be 1
        $script:TotalItems | Should -Be 1
    }

    It 'F-27 writes RECYCLED with the size, a success line and section activity' {
        $root = New-Tree 'full' @('fixture.txt=5000')
        Mock Move-SwItemToRecycleBin { }
        Assert-Result (Remove-SwItem -Path $root -Recycle) $true 'recycle'
        $script:Ops.Count | Should -Be 1
        $script:Ops[0].Action | Should -BeExactly 'RECYCLED'
        $script:Ops[0].Path | Should -BeExactly $root
        $script:Ops[0].Detail | Should -BeExactly (Format-SwByteSize -Bytes 5000)
        $script:Said.Count | Should -Be 1
        Should -Invoke -CommandName Set-SectionActivity -Times 1 -Exactly
    }

    It 'F-27 gives false, FAILED, exactly one warning that names the path, no count and no further removal when the shell fails' {
        $root = New-Tree 'full' @('fixture.txt=5000')
        $script:DirTail = Get-Tail $root
        Mock Move-SwItemToRecycleBin { throw 'Recycle Bin unavailable' }
        Mock Write-Warning { }
        Mock Remove-SwDirectoryTree { throw 'must not remove' }
        Mock Remove-Item { throw 'must not remove' }
        Use-TreeEntrySpy
        Assert-Result (Remove-SwItem -Path $root -Recurse -Recycle) $false 'recycle failure'
        Exists (P $root 'fixture.txt') | Should -BeTrue
        $script:FilesCleaned | Should -Be 0
        $script:TotalItems | Should -Be 0
        $script:TotalSizeCleaned | Should -Be 0
        Should -Invoke -CommandName Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like ('*' + $script:DirTail + '*') }
        Should -Invoke -CommandName Remove-SwDirectoryTree -Times 0 -Exactly
        Should -Invoke -CommandName Remove-SwTreeEntry -Times 0 -Exactly
        Should -Invoke -CommandName Remove-Item -Times 0 -Exactly
        $script:Ops.Count | Should -Be 1
        $script:Ops[0].Action | Should -BeExactly 'FAILED'
        $script:Ops[0].Detail | Should -BeExactly 'Recycle Bin unavailable'
        $script:Said.Count | Should -Be 0
    }

    It 'F-27 previews with -Recycle in a dry run without calling the shell' {
        $root = New-Tree 'full' @('fixture.txt=5000')
        $script:SweeprDryRunMode = $true
        Mock Move-SwItemToRecycleBin { throw 'the shell must not be called' }
        Assert-Result (Remove-SwItem -Path $root -Recycle) $true 'preview'
        Should -Invoke -CommandName Move-SwItemToRecycleBin -Times 0 -Exactly
        Exists (P $root 'fixture.txt') | Should -BeTrue
        $script:Ops.Count | Should -Be 0
    }

    It 'F-27 gives false and never calls the shell when only the root is whitelisted' {
        $root = New-Tree 'full' @('fixture.txt')
        $script:Subject = $root
        Mock Test-SwWhitelisted { (Fold $Path) -eq (Fold $script:Subject) }
        Mock Move-SwItemToRecycleBin { throw 'the shell must not be called' }
        Assert-Result (Remove-SwItem -Path $root -Recycle) $false 'whitelisted root'
        Should -Invoke -CommandName Move-SwItemToRecycleBin -Times 0 -Exactly
        Exists (P $root 'fixture.txt') | Should -BeTrue
    }

    It 'F-27 refuses a link as the entry: the identity is asked without -AllowLeafLink' {
        $target = New-Tree 'link-target' @('a.txt')
        $link = P $script:Target 'link'
        New-TestLink $link $target
        Mock Move-SwItemToRecycleBin { throw 'the shell must not be called' }
        Assert-Result (Remove-SwItem -Path $link -Recycle) $false 'link'
        Should -Invoke -CommandName Move-SwItemToRecycleBin -Times 0 -Exactly
        Exists (P $target 'a.txt') | Should -BeTrue
        $script:Ops.Count | Should -Be 0
    }

    It 'F-27 never recycles a folder that gained a whitelisted entry while it was measured (real run)' {
        $root = New-Tree 'full' @('a.txt')
        Set-Whitelist @((P $root 'keep.txt'))
        $script:LateRoot = $root
        $script:Reads = 0
        Mock Get-SwWhitelistState { $script:Reads++; & $script:RealWhitelistState }
        Mock Get-SwValidatedTreeSize { New-File (P $script:LateRoot 'keep.txt') 1 | Out-Null; & $script:RealTreeSize -Tree $Tree }
        Assert-Result (Remove-SwItem -Path $root -Recycle) $false 'late whitelisted entry'
        Exists (P $root 'keep.txt') | Should -BeTrue
        Exists (P $root 'a.txt') | Should -BeTrue
        $script:FilesCleaned | Should -Be 0
        $script:Reads | Should -BeLessOrEqual 2 -Because 'the Recycle Bin path reads the whitelist state at most twice'
    }

    It 'F-27 [W] moves a folder of the test drive to the Recycle Bin: true, the folder is gone, RECYCLED, no kilobytes' {
        $root = New-Tree 'to-recycle' @('a.txt=1000', 'nested/b.txt=2000')
        Assert-Result (Remove-SwItem -Path $root -Recycle) $true 'real shell operation'
        Exists $root | Should -BeFalse
        $script:Ops.Count | Should -Be 1
        $script:Ops[0].Action | Should -BeExactly 'RECYCLED'
        $script:TotalSizeCleaned | Should -Be 0
        $script:FilesCleaned | Should -Be 1
    }

    It 'F-27 [W] moves a single file of the test drive to the Recycle Bin: true, the file is gone, RECYCLED, no kilobytes' {
        $file = New-File (P $script:Target 'single-recycle.txt') 1000
        Assert-Result (Remove-SwItem -Path $file -Recycle) $true 'real shell operation on a file'
        Exists $file | Should -BeFalse
        $script:Ops.Count | Should -Be 1
        $script:Ops[0].Action | Should -BeExactly 'RECYCLED'
        $script:Ops[0].Path | Should -BeExactly $file
        $script:TotalSizeCleaned | Should -Be 0
        $script:FilesCleaned | Should -Be 1
    }

    It 'F-28 writes REMOVED for a success, FAILED for a failure and SKIPPED for a refused folder, and nothing for the other refusals' {
        $ok = New-File (P $script:Target 'ok.txt') 10
        Assert-Result (Remove-SwItem -Path $ok) $true 'success'
        $script:Ops.Count | Should -Be 1
        $bad = New-File (P $script:Target 'bad.txt') 10
        Mock Remove-Item { throw 'access-denied-canary' }
        Assert-Result (Remove-SwItem -Path $bad) $false 'failure'
        $script:Ops.Count | Should -Be 2
        $proj = New-Tree 'proj' @('a.txt', 'keep/k.txt')
        Set-Whitelist @((P $proj 'keep'))
        Assert-Result (Remove-SwItem -Path $proj) $false 'refused folder'
        $script:Ops.Count | Should -Be 3
        @($script:Ops | ForEach-Object { $_.Action }) | Should -Be @('REMOVED', 'FAILED', 'SKIPPED')
        Assert-Result (Remove-SwItem -Path (P $script:Prot 'x.txt')) $false 'protected'
        Assert-Result (Remove-SwItem -Path (P $script:Target 'missing.txt')) $false 'missing'
        Assert-Result (Remove-SwItem -Path 'relative.txt') $false 'relative'
        $script:Ops.Count | Should -Be 3
    }

    It 'G-5 gives the same result under every error preference (<Preference>)' -ForEach @(
        @{ Preference = 'Stop' }
        @{ Preference = 'Continue' }
        @{ Preference = 'SilentlyContinue' }
    ) {
        $file = New-File (P $script:Target 'a.txt') 10
        $kept = New-File (P $script:Prot 'p.txt') 10
        $ErrorActionPreference = $Preference
        $records = @(& {
                Remove-SwItem -Path $file
                Remove-SwItem -Path $kept
                Remove-SwItem -Path (P $script:Target 'missing.txt')
            } 2>&1)
        @($records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count | Should -Be 0
        @($records | ForEach-Object { [string]$_ }) | Should -Be @('True', 'False', 'False')
        Exists $file | Should -BeFalse
        Exists $kept | Should -BeTrue
    }

    It 'G-5 gives the same results from the bulk helpers, the list and the statistics under every error preference (<Preference>)' -ForEach @(
        @{ Preference = 'Stop' }
        @{ Preference = 'Continue' }
        @{ Preference = 'SilentlyContinue' }
    ) {
        $root = New-Tree 'Temp' @('a.txt', 'nested/b.txt')
        $logs = New-Dir (P $script:Target 'Logs')
        $old = New-File (P $logs 'old.log') 10
        [System.IO.File]::SetLastWriteTime($old, (Get-Date).AddDays(-30))
        $list = New-File (P $script:Work 'clean-list.txt') 0
        $script:ExportListFile = $list
        $ErrorActionPreference = $Preference
        $records = @(& {
                Clear-SwDirectoryContents -Path $root
                Remove-SwOldFiles -Path $logs
                Add-SwDryRunListEntries -Description 'x' -Paths @('C:\a')
                Set-SwDryRunMode -Enabled $false
                Test-SwDryRunMode
                (Get-SwCleanupStats)['FilesCleaned']
                Reset-SwCleanupStats
            } 2>&1)
        @($records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count | Should -Be 0
        @($records | ForEach-Object { [string]$_ }) | Should -Be @('False', '3')
        @(Get-ChildItem -LiteralPath $root -Force).Count | Should -Be 0
        Exists $old | Should -BeFalse
    }

    It 'G-8 gives false, removes nothing and does not throw when the whitelist state cannot be read' {
        $file = New-File (P $script:Target 'a.txt') 10
        Mock Get-SwWhitelistState { throw 'state-canary' }
        $result = @(Get-Result { Remove-SwItem -Path $file })
        $result.Count | Should -Be 1
        Assert-Result $result[0] $false 'state unknown'
        Exists $file | Should -BeTrue
    }

    It 'G-8 gives false, removes nothing and does not throw when the measurement throws before the removal' {
        $root = New-Tree 'full' @('a.txt')
        Mock Get-SwValidatedTreeSize { throw 'measure-canary' }
        $result = @(Get-Result { Remove-SwItem -Path $root })
        Assert-Result $result[0] $false 'measurement throws'
        Exists (P $root 'a.txt') | Should -BeTrue
    }

    It 'F-22 [W] removes a file and a folder with their real identity' {
        Mock Get-SwPathSnapshot { & $script:RealGet -Path $Path -AllowLeafLink:$AllowLeafLink }
        Mock Test-SwPathSnapshot { & $script:RealTest -Snapshot $Snapshot }
        $file = New-File (P $script:Target 'a.txt') 4096
        $root = New-Tree 'full' @('a.txt', 'nested/b.txt')
        Assert-Result (Remove-SwItem -Path $file) $true 'file'
        Assert-Result (Remove-SwItem -Path $root) $true 'folder'
        Exists $file | Should -BeFalse
        Exists $root | Should -BeFalse
    }
}

# ============================================================================
# Remove-SwItems
# ============================================================================

Describe 'Remove-SwItems' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
    }
    AfterEach { Stop-Case }

    It 'F-29 skips empty and white-space elements and paths that are not complete, without an error' {
        $file = New-File (P $script:Target 'a.txt') 10
        { Remove-SwItems -Paths @('', '   ', 'relative.txt', ('.' + $script:Sep + 'a.txt'), $file) } | Should -Not -Throw
        Exists $file | Should -BeFalse
        $script:Ops.Count | Should -Be 1
        $script:FilesCleaned | Should -Be 1
    }

    It 'F-29 skips a protected or whitelisted path silently and does not count it' {
        $protectedFile = New-File (P $script:Prot 'x.txt') 10
        $keep = New-File (P $script:Target 'keep.txt') 10
        $file = New-File (P $script:Target 'a.txt') 10
        Set-Whitelist @($keep)
        Remove-SwItems -Paths @($protectedFile, $keep, $file)
        Exists $protectedFile | Should -BeTrue
        Exists $keep | Should -BeTrue
        Exists $file | Should -BeFalse
        $script:Ops.Count | Should -Be 1
        $script:Ops[0].Path | Should -BeExactly $file
        $script:FilesCleaned | Should -Be 1
    }

    It 'F-29 skips a path that does not exist silently and goes on' {
        $file = New-File (P $script:Target 'a.txt') 10
        Remove-SwItems -Paths @((P $script:Target 'missing.txt'), $file)
        Exists $file | Should -BeFalse
        $script:Ops.Count | Should -Be 1
    }

    It 'F-29 forms the identity with -AllowLeafLink and skips a path without identity silently' {
        $one = New-File (P $script:Target 'a.txt') 10
        $two = New-File (P $script:Target 'b.txt') 10
        $script:FakeNoIdentity = @($one)
        Remove-SwItems -Paths @($one, $two)
        Exists $one | Should -BeTrue
        Exists $two | Should -BeFalse
        $script:Ops.Count | Should -Be 1
        Should -Invoke -CommandName Get-SwPathSnapshot -Times 1 -Exactly -ParameterFilter { (Fold $Path) -eq (Fold $one) -and $AllowLeafLink }
        Should -Invoke -CommandName Get-SwPathSnapshot -Times 1 -ParameterFilter { (Fold $Path) -eq (Fold $two) -and $AllowLeafLink }
    }

    It 'F-29 refuses a folder with a protected entry (SKIPPED with the reason, real run), goes on with the next path and counts only that one' {
        $proj = New-Tree 'proj' @('a.txt', 'keep/k.txt')
        Set-Whitelist @((P $proj 'keep'))
        $file = New-File (P $script:Target 'b.txt') 10
        Remove-SwItems -Paths @($proj, $file)
        Exists (P $proj 'a.txt') | Should -BeTrue
        Exists $file | Should -BeFalse
        $script:Ops.Count | Should -Be 2
        $script:Ops[0].Action | Should -BeExactly 'SKIPPED'
        $script:Ops[0].Path | Should -BeExactly $proj
        $script:Ops[0].Detail | Should -BeLike 'refused: *'
        $script:Ops[1].Action | Should -BeExactly 'REMOVED'
        $script:FilesCleaned | Should -Be 1
    }

    It 'F-29 writes no SKIPPED line for a refused folder in a dry run' {
        $proj = New-Tree 'proj' @('a.txt', 'keep/k.txt')
        Set-Whitelist @((P $proj 'keep'))
        $script:SweeprDryRunMode = $true
        Remove-SwItems -Paths @($proj)
        $script:Ops.Count | Should -Be 0
        $script:FilesCleaned | Should -Be 0
        $script:DrySaid.Count | Should -Be 0
    }

    It 'F-29 measures each folder once with Get-SwValidatedTreeSize and each file with Get-SwPathSize' {
        $one = New-Tree 'one' @('a.txt=100')
        $two = New-Tree 'two' @('b.txt=200')
        $file = New-File (P $script:Target 'f.txt') 300
        Mock Get-SwValidatedTreeSize { & $script:RealTreeSize -Tree $Tree }
        Mock Get-SwPathSize { 300 }
        Remove-SwItems -Paths @($one, $two, $file)
        Should -Invoke -CommandName Get-SwValidatedTreeSize -Times 2 -Exactly
        Should -Invoke -CommandName Get-SwPathSize -Times 1 -Exactly -ParameterFilter { (Fold $Path) -eq (Fold $file) }
        Should -Invoke -CommandName Get-SwPathSize -Times 0 -Exactly -ParameterFilter { (Fold $Path) -eq (Fold $one) -or (Fold $Path) -eq (Fold $two) }
    }

    It 'F-29 skips a path silently that was replaced during the measurement and goes on' {
        $one = New-Tree 'one' @('a.txt')
        $two = New-File (P $script:Target 'b.txt') 10
        $script:Swap = $one
        Mock Get-SwValidatedTreeSize { $script:FakeIdentity[$script:Swap] = 'replaced'; & $script:RealTreeSize -Tree $Tree }
        Remove-SwItems -Paths @($one, $two)
        Exists (P $one 'a.txt') | Should -BeTrue
        Exists $two | Should -BeFalse
        $script:Ops.Count | Should -Be 1
        $script:FilesCleaned | Should -Be 1
    }

    It 'F-29 skips a path silently that is no longer safe after the measurement' {
        $one = New-File (P $script:Target 'a.txt') 10
        $two = New-File (P $script:Target 'b.txt') 10
        $script:Subject = $one
        $script:Asked = 0
        Mock Test-SwSafePath { if ((Fold $Path) -eq (Fold $script:Subject)) { $script:Asked++; return ($script:Asked -lt 2) }; $true }
        Remove-SwItems -Paths @($one, $two)
        Exists $one | Should -BeTrue
        Exists $two | Should -BeFalse
        $script:Ops.Count | Should -Be 1
    }

    It 'F-29 does not remove a path when -CanRemove gives <Label>, stays silent and counts nothing (real run and preview)' -ForEach $script:NotTrue {
        $one = New-File (P $script:Target 'a.txt') 10
        $two = New-Tree 'full' @('b.txt')
        foreach ($dry in @($false, $true)) {
            $script:SweeprDryRunMode = $dry
            Remove-SwItems -Paths @($one, $two) -CanRemove $Block
        }
        Exists $one | Should -BeTrue
        Exists (P $two 'b.txt') | Should -BeTrue
        $script:Ops.Count | Should -Be 0
        $script:FilesCleaned | Should -Be 0
        $script:TotalItems | Should -Be 0
        $script:Said.Count | Should -Be 0
        $script:DrySaid.Count | Should -Be 0
    }

    It 'F-29 evaluates -CanRemove after the measurement, also in a dry run, and never for a path that the checks refuse' {
        $file = New-File (P $script:Target 'a.txt') 10
        $protectedFile = New-File (P $script:Prot 'p.txt') 10
        $script:Probe = 0
        Mock Get-SwPathSize { $script:Events.Add('measure'); 10 }
        $script:SweeprDryRunMode = $true
        Remove-SwItems -Paths @($protectedFile, (P $script:Target 'missing.txt'), $file) -CanRemove { $script:Probe++; $script:Events.Add('can'); $true }
        $script:Probe | Should -Be 1
        @($script:Events) | Should -Be @('measure', 'can')
    }

    It 'F-29 asks for the identity once more after -CanRemove, also for files: an entry swapped by the condition stays' {
        $one = New-File (P $script:Target 'a.txt') 10
        $two = New-File (P $script:Target 'b.txt') 10
        $script:Subject = $one
        Remove-SwItems -Paths @($one, $two) -CanRemove { $script:FakeIdentity[$script:Subject] = 'replaced'; $true }
        Exists $one | Should -BeTrue
        Exists $two | Should -BeFalse
        $script:Ops.Count | Should -Be 1
    }

    It 'F-29 previews in a dry run: nothing changes, one list entry with every path, bytes and file count' {
        $one = New-Tree 'one' @('a.txt=100', 'nested/b.txt=200')
        $two = New-File (P $script:Target 'f.txt') 300
        $script:SweeprDryRunMode = $true
        Mock Add-SwDryRunListEntries { }
        $before = Get-Listing $script:Work
        Remove-SwItems -Paths @($one, $two) -Description 'Example cache'
        Same-Listing (Get-Listing $script:Work) $before | Should -BeTrue
        Should -Invoke -CommandName Add-SwDryRunListEntries -Times 1 -Exactly -ParameterFilter {
            $Description -eq 'Example cache' -and @($Paths).Count -eq 2 -and (Fold @($Paths)[0]) -eq (Fold $one) -and (Fold @($Paths)[1]) -eq (Fold $two) -and
            @($SizeBytes).Count -eq 2 -and @($SizeBytes)[0] -eq 300 -and @($SizeBytes)[1] -eq 300 -and
            @($FileCounts).Count -eq 2 -and @($FileCounts)[0] -eq 2 -and @($FileCounts)[1] -eq 1
        }
        $script:Ops.Count | Should -Be 0
    }

    It 'F-29 removes a file through Remove-SwTreeEntry and a folder through Remove-SwDirectoryTree with the tree, a report, the state and -CanRemove' {
        $file = New-File (P $script:Target 'f.txt') 10
        $root = New-Tree 'full' @('a.txt')
        Use-TreeEntrySpy
        Mock Remove-SwDirectoryTree { $true }
        $condition = { $true }
        Remove-SwItems -Paths @($file, $root) -CanRemove $condition
        Should -Invoke -CommandName Remove-SwTreeEntry -Times 1 -Exactly -ParameterFilter { (Fold $Path) -eq (Fold $file) }
        Should -Invoke -CommandName Remove-SwDirectoryTree -Times 1 -Exactly -ParameterFilter {
            (Fold $Path) -eq (Fold $root) -and $ValidatedTree -is [hashtable] -and $ValidatedTree['Success'] -and $Report -is [hashtable] -and $null -ne $WhitelistState -and [object]::ReferenceEquals($CanRemove, $condition)
        }
    }

    It 'F-29 writes SKIPPED with the reason of the report when the owner holds a folder, and counts it neither as removed nor as failed' {
        $one = New-Tree 'one' @('a.txt')
        $two = New-File (P $script:Target 'b.txt') 10
        Mock Remove-SwDirectoryTree { $Report['OwnerHeld'] = $true; $Report['Reason'] = 'owner-canary'; $false }
        Remove-SwItems -Paths @($one, $two) -CanRemove { $true }
        $script:Ops.Count | Should -Be 2
        $script:Ops[0].Action | Should -BeExactly 'SKIPPED'
        $script:Ops[0].Path | Should -BeExactly $one
        $script:Ops[0].Detail | Should -BeLike '*owner-canary*'
        $script:Ops[1].Action | Should -BeExactly 'REMOVED'
        $script:FilesCleaned | Should -Be 1
    }

    It 'F-20 F-29 writes FAILED for a folder that cannot be removed completely, goes on with the next path and does not count it' {
        $one = New-Tree 'one' @('aaaaaaaa.txt', 'bbbbbbbb.txt', 'lock.txt')
        $two = New-File (P $script:Target 'b.txt') 10
        Use-TreeEntrySpy
        $script:FailOn = P $one 'lock.txt'
        $script:FailMessage = 'lock-canary'
        Remove-SwItems -Paths @($one, $two)
        $script:Ops.Count | Should -Be 2
        $script:Ops[0].Action | Should -BeExactly 'FAILED'
        Assert-Incomplete $script:Ops[0].Detail 2 3 (P $one 'lock.txt') 'lock-canary'
        $script:Ops[1].Action | Should -BeExactly 'REMOVED'
        Exists (P $one 'lock.txt') | Should -BeTrue
        Exists $two | Should -BeFalse
        $script:FilesCleaned | Should -Be 1
        $script:TotalItems | Should -Be 1
    }

    It 'F-29 writes FAILED with the message of the exception for a file that cannot be removed and goes on' {
        $one = New-File (P $script:Target 'a.txt') 10
        $two = New-File (P $script:Target 'b.txt') 10
        $script:FailPath = $one
        $script:RealRemove = $script:RealRemoveItem
        Mock Remove-Item { if ((Fold ([string]@($LiteralPath)[0])) -eq (Fold $script:FailPath)) { throw 'access-denied-canary' }; & $script:RealRemoveItem @PesterBoundParameters }
        Remove-SwItems -Paths @($one, $two)
        Exists $one | Should -BeTrue
        Exists $two | Should -BeFalse
        $script:Ops.Count | Should -Be 2
        $script:Ops[0].Action | Should -BeExactly 'FAILED'
        $script:Ops[0].Path | Should -BeExactly $one
        $script:Ops[0].Detail | Should -BeExactly 'access-denied-canary'
        $script:Ops[1].Action | Should -BeExactly 'REMOVED'
        $script:FilesCleaned | Should -Be 1
    }

    It 'F-29 gives the path as the caller wrote it to the log, not a normalized one' {
        New-File (P $script:Target 'a.txt') 10 | Out-Null
        $written = $script:Target + $script:Sep + '.' + $script:Sep + 'a.txt'
        Remove-SwItems -Paths @($written)
        $script:Ops.Count | Should -Be 1
        $script:Ops[0].Path | Should -BeExactly $written
    }

    It 'F-29 reads the whitelist state once per call, whatever the number of paths and trees' {
        $script:RealState = Get-SwWhitelistState
        Mock Get-SwWhitelistState { $script:RealState }
        $one = New-Tree 'one' @('a.txt', 'nested/b.txt')
        $two = New-Tree 'two' @('c.txt')
        $file = New-File (P $script:Target 'f.txt') 10
        Remove-SwItems -Paths @($one, $two, $file)
        Should -Invoke -CommandName Get-SwWhitelistState -Times 1 -Exactly
    }

    It 'F-30 never evaluates -CanRemove for a path that the safety checks refuse' {
        $protectedFile = New-File (P $script:Prot 'p.txt') 10
        $script:Probe = 0
        Remove-SwItems -Paths @($protectedFile) -CanRemove { $script:Probe++; $true }
        $script:Probe | Should -Be 0
    }

    It 'F-31 adds the sum of all bytes rounded up once, the number of paths, and one item: <Sizes> bytes are <Expected> KB (real run and preview)' -ForEach $script:SumCases {
        foreach ($dry in @($false, $true)) {
            $script:SweeprDryRunMode = $dry
            $script:TotalSizeCleaned = 0
            $script:FilesCleaned = 0
            $script:TotalItems = 0
            $label = 'case' + [guid]::NewGuid().ToString('N')
            $paths = @()
            for ($i = 0; $i -lt $Sizes.Count; $i++) { $paths += (New-File (P $script:Target $label ('f' + $i + '.bin')) $Sizes[$i]) }
            Remove-SwItems -Paths $paths
            $script:TotalSizeCleaned | Should -Be $Expected -Because "dry run: $dry"
            $script:FilesCleaned | Should -Be $Sizes.Count
            $script:TotalItems | Should -Be 1
        }
    }

    It 'F-31 removes two folders of 4096 and 6144 bytes: 10 KB, two paths, one item, one success line' {
        $one = New-Tree 'one' @('a.bin=4096')
        $two = New-Tree 'two' @('b.bin=6144')
        Remove-SwItems -Paths @($one, $two) -Description 'Example cache'
        Exists $one | Should -BeFalse
        Exists $two | Should -BeFalse
        $stats = Get-SwCleanupStats
        $stats['TotalSizeKB'] | Should -Be 10
        $stats['FilesCleaned'] | Should -Be 2
        $stats['TotalItems'] | Should -Be 1
        $script:Said.Count | Should -Be 1
        $script:DrySaid.Count | Should -Be 0
        Should -Invoke -CommandName Set-SectionActivity -Times 1 -Exactly
    }

    It 'F-31 leaves both folders in a dry run and writes one preview line with the description, the count and the size' {
        $one = New-Tree 'one' @('a.bin=4096')
        $two = New-Tree 'two' @('b.bin=6144')
        $script:SweeprDryRunMode = $true
        Remove-SwItems -Paths @($one, $two) -Description 'Example cache'
        Exists (P $one 'a.bin') | Should -BeTrue
        Exists (P $two 'b.bin') | Should -BeTrue
        $script:DrySaid.Count | Should -Be 1
        $script:DrySaid[0] | Should -BeLike '*Example cache*'
        $script:DrySaid[0] | Should -Match '\b2\b'
        $script:DrySaid[0] | Should -BeLike ('*' + (Format-SwByteSize -Bytes 10240) + '*')
        $script:Said.Count | Should -Be 0
        $script:TotalSizeCleaned | Should -Be 10
        $script:FilesCleaned | Should -Be 2
        $script:Ops.Count | Should -Be 0
    }

    It 'F-31 uses the default description Items' {
        $file = New-File (P $script:Target 'a.txt') 10
        $script:SweeprDryRunMode = $true
        Remove-SwItems -Paths @($file)
        $script:DrySaid[0] | Should -BeLike '*Items*'
    }

    It 'F-31 writes the list entries once with the given description unchanged, only in a dry run' {
        $one = New-File (P $script:Target 'a.txt') 10
        $two = New-File (P $script:Target 'b.txt') 20
        Mock Add-SwDryRunListEntries { }
        Remove-SwItems -Paths @($one, $two) -Description 'Example cache'
        Should -Invoke -CommandName Add-SwDryRunListEntries -Times 0 -Exactly
        $three = New-File (P $script:Target 'c.txt') 10
        $four = New-File (P $script:Target 'd.txt') 20
        $script:SweeprDryRunMode = $true
        Remove-SwItems -Paths @($three, $four) -Description 'Example cache'
        Should -Invoke -CommandName Add-SwDryRunListEntries -Times 1 -Exactly -ParameterFilter { $Description -ceq 'Example cache' -and @($Paths).Count -eq 2 }
    }

    It 'F-31 gives no line, no count and no list entry when no path is removed or previewed' {
        $protectedFile = New-File (P $script:Prot 'p.txt') 10
        Mock Add-SwDryRunListEntries { }
        foreach ($dry in @($false, $true)) {
            $script:SweeprDryRunMode = $dry
            Remove-SwItems -Paths @($protectedFile, (P $script:Target 'missing.txt'), '')
        }
        $script:Said.Count | Should -Be 0
        $script:DrySaid.Count | Should -Be 0
        $script:FilesCleaned | Should -Be 0
        $script:TotalItems | Should -Be 0
        $script:TotalSizeCleaned | Should -Be 0
        Should -Invoke -CommandName Add-SwDryRunListEntries -Times 0 -Exactly
        Should -Invoke -CommandName Set-SectionActivity -Times 0 -Exactly
    }

    It 'F-31 previews only the sibling when the whitelist protects a file of a data folder, with one preview line' {
        $keep = New-File (P $script:Target 'data' 'clean-list.txt') 10
        $sibling = New-File (P $script:Target 'data2' 'x.tmp') 10
        Set-Whitelist @($keep)
        $script:SweeprDryRunMode = $true
        Remove-SwItems -Paths @($keep, $sibling) -Description 'Temp'
        $script:DrySaid.Count | Should -Be 1
        $script:FilesCleaned | Should -Be 1
        Exists $keep | Should -BeTrue
        Exists $sibling | Should -BeTrue
    }

    It 'F-32 writes nothing to the pipeline (<Case>)' -ForEach @(
        @{ Case = 'a real run'; Setup = 'real' }
        @{ Case = 'a preview'; Setup = 'dry' }
        @{ Case = 'a refused folder'; Setup = 'refused' }
        @{ Case = 'a failed removal'; Setup = 'failed' }
    ) {
        switch ($Setup) {
            'real' { $paths = @((New-File (P $script:Target 'a.txt') 10), (New-Tree 'full' @('b.txt'))) }
            'dry' { $paths = @((New-File (P $script:Target 'a.txt') 10)); $script:SweeprDryRunMode = $true }
            'refused' { $proj = New-Tree 'proj' @('keep/k.txt'); Set-Whitelist @((P $proj 'keep')); $paths = @($proj) }
            'failed' { $paths = @((New-File (P $script:Target 'a.txt') 10)); Mock Remove-Item { throw 'access-denied-canary' } }
        }
        @(Remove-SwItems -Paths $paths).Count | Should -Be 0
    }

    It 'F-41 writes one REMOVED line for each removed path, not one for each child' {
        $one = New-Tree 'one' @('a.txt', 'nested/b.txt', 'nested/c.txt')
        $two = New-File (P $script:Target 'f.txt') 10
        Remove-SwItems -Paths @($one, $two)
        @($script:Ops | ForEach-Object { $_.Action }) | Should -Be @('REMOVED', 'REMOVED')
        @($script:Ops | ForEach-Object { $_.Path }) | Should -Be @($one, $two)
    }

    It 'G-5 gives the same result under every error preference (<Preference>)' -ForEach @(
        @{ Preference = 'Stop' }
        @{ Preference = 'Continue' }
        @{ Preference = 'SilentlyContinue' }
    ) {
        $file = New-File (P $script:Target 'a.txt') 10
        $kept = New-File (P $script:Prot 'p.txt') 10
        $ErrorActionPreference = $Preference
        $records = @(& { Remove-SwItems -Paths @($file, $kept, (P $script:Target 'missing.txt')) } 2>&1)
        $records.Count | Should -Be 0
        Exists $file | Should -BeFalse
        Exists $kept | Should -BeTrue
    }
}

# ============================================================================
# Clear-SwDirectoryContents
# ============================================================================

Describe 'Clear-SwDirectoryContents' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
    }
    AfterEach { Stop-Case }

    It 'F-33 empties a folder and keeps it, with hidden entries, folders and files' {
        $root = New-Tree 'Temp' @('a.txt', 'nested/b.txt', '.hidden')
        Clear-SwDirectoryContents -Path $root
        Exists $root | Should -BeTrue
        @(Get-ChildItem -LiteralPath $root -Force).Count | Should -Be 0
    }

    It 'F-33 does nothing for a path that is not complete, does not exist, or is a file (<Case>)' -ForEach @(
        @{ Case = 'relative'; Make = 'relative' }
        @{ Case = 'missing'; Make = 'missing' }
        @{ Case = 'a file'; Make = 'file' }
    ) {
        $file = New-File (P $script:Target 'a.txt') 10
        $path = switch ($Make) { 'relative' { 'relative-folder' } 'missing' { P $script:Target 'missing' } 'file' { $file } }
        Mock Remove-SwItems { throw 'must not remove' }
        { Clear-SwDirectoryContents -Path $path } | Should -Not -Throw
        Exists $file | Should -BeTrue
        Should -Invoke -CommandName Remove-SwItems -Times 0 -Exactly
    }

    It 'F-33 does nothing for a root that is a link, and removes nothing it points to' {
        $target = New-Tree 'link-target' @('keep.txt', 'nested/deep.txt')
        $before = Get-Listing $target
        $link = P $script:Target 'rootlink'
        New-TestLink $link $target
        Clear-SwDirectoryContents -Path $link
        Same-Listing (Get-Listing $target) $before | Should -BeTrue
        Exists $link | Should -BeTrue
    }

    It 'F-33 does nothing when the root is protected or whitelisted' {
        $protectedRoot = New-Tree 'protected' @('a.txt')
        Clear-SwDirectoryContents -Path $protectedRoot
        Exists (P $protectedRoot 'a.txt') | Should -BeTrue
        $keep = New-Tree 'keep-root' @('b.txt')
        Set-Whitelist @($keep)
        Clear-SwDirectoryContents -Path $keep
        Exists (P $keep 'b.txt') | Should -BeTrue
    }

    It 'F-33 evaluates -CanRemove once before it lists anything, and does nothing when the result is <Label>' -ForEach $script:NotTrue {
        $root = New-Tree 'Temp' @('a.txt')
        Clear-SwDirectoryContents -Path $root -CanRemove $Block
        Exists (P $root 'a.txt') | Should -BeTrue
        Should -Invoke -CommandName Get-SwPathSnapshot -Times 0 -Exactly
        $script:Ops.Count | Should -Be 0
    }

    It 'F-33 forms the snapshot of the root without -AllowLeafLink and does nothing when there is none' {
        $root = New-Tree 'Temp' @('a.txt')
        Clear-SwDirectoryContents -Path $root
        Should -Invoke -CommandName Get-SwPathSnapshot -Times 1 -ParameterFilter { (Fold $Path) -eq (Fold $root) -and -not $AllowLeafLink }
        $other = New-Tree 'Other' @('b.txt')
        $script:FakeNoIdentity = @($other)
        Clear-SwDirectoryContents -Path $other
        Exists (P $other 'b.txt') | Should -BeTrue
    }

    It 'F-33 hands every direct child, hidden ones too and no deeper entry, to Remove-SwItems with the leaf name of the root as description' {
        $root = New-Tree 'Temp' @('a.txt', 'nested/b.txt', '.hidden', 'folder/c.txt')
        Mock Remove-SwItems { $script:GotPaths = @($Paths); $script:GotDescription = $Description }
        Clear-SwDirectoryContents -Path $root
        Should -Invoke -CommandName Remove-SwItems -Times 1 -Exactly
        @($script:GotPaths | ForEach-Object { Leaf $_ } | Sort-Object) -join '|' | Should -BeExactly ((@('.hidden', 'a.txt', 'folder', 'nested') | Sort-Object) -join '|')
        $script:GotDescription | Should -BeExactly 'Temp'
    }

    It 'F-33 hands the description and the condition on to Remove-SwItems' {
        $root = New-Tree 'Temp' @('a.txt')
        $condition = { $true }
        Mock Remove-SwItems { $script:GotDescription = $Description; $script:GotCondition = $CanRemove }
        Clear-SwDirectoryContents -Path $root -Description 'Example cache' -CanRemove $condition
        $script:GotDescription | Should -BeExactly 'Example cache'
        [object]::ReferenceEquals($script:GotCondition, $condition) | Should -BeTrue
    }

    It 'F-33 does not call Remove-SwItems for a folder without entries' {
        $root = New-Dir (P $script:Target 'Empty')
        Mock Remove-SwItems { throw 'must not remove' }
        Clear-SwDirectoryContents -Path $root
        Should -Invoke -CommandName Remove-SwItems -Times 0 -Exactly
    }

    It 'F-33 does nothing when the root changed after the listing' {
        $root = New-Tree 'Temp' @('a.txt')
        Mock Test-SwPathSnapshot { $false }
        Mock Remove-SwItems { throw 'must not remove' }
        Clear-SwDirectoryContents -Path $root
        Should -Invoke -CommandName Remove-SwItems -Times 0 -Exactly
        Exists (P $root 'a.txt') | Should -BeTrue
    }

    It 'F-33 leaves a data folder in place and removes its neighbor (<Mode>)' -ForEach @(
        @{ Mode = 'real run'; Dry = $false }
        @{ Mode = 'dry run'; Dry = $true }
    ) {
        $root = New-Tree 'Temp' @('data/clean-list.txt', 'data2/x.tmp')
        $script:Config = @{ ConfigPath = (P $root 'data'); CachePath = (P $script:Work 'appdata' 'cache'); WhitelistFile = (P $script:Work 'appdata' 'config' 'whitelist.txt') }
        $script:SweeprDryRunMode = $Dry
        Clear-SwDirectoryContents -Path $root
        Exists (P $root 'data' 'clean-list.txt') | Should -BeTrue
        $script:FilesCleaned | Should -Be 1
        if ($Dry) { Exists (P $root 'data2') | Should -BeTrue }
        else { Exists (P $root 'data2') | Should -BeFalse }
    }

    It 'F-33 refuses a child that holds a protected entry (SKIPPED) and removes the other children' {
        $root = New-Tree 'Temp' @('proj/a.txt', 'proj/keep/k.txt', 'plain.txt')
        Set-Whitelist @((P $root 'proj' 'keep'))
        Clear-SwDirectoryContents -Path $root
        Exists (P $root 'proj' 'a.txt') | Should -BeTrue
        Exists (P $root 'plain.txt') | Should -BeFalse
        @($script:Ops | Where-Object { $_.Action -eq 'SKIPPED' }).Count | Should -Be 1
        (Fold @($script:Ops | Where-Object { $_.Action -eq 'SKIPPED' })[0].Path) | Should -BeExactly (Fold (P $root 'proj'))
    }

    It 'F-33 [W] removes a link inside the folder as a link and leaves what it points to' {
        $target = New-Tree 'link-target' @('keep.txt')
        $root = New-Tree 'Temp' @('plain.txt')
        $link = P $root 'lnk'
        New-TestLink $link $target
        Clear-SwDirectoryContents -Path $root
        Exists (P $target 'keep.txt') | Should -BeTrue
        Exists (P $root 'plain.txt') | Should -BeFalse
    }

    It 'F-32 writes nothing to the pipeline' {
        $root = New-Tree 'Temp' @('a.txt', 'nested/b.txt')
        @(Clear-SwDirectoryContents -Path $root).Count | Should -Be 0
        $script:SweeprDryRunMode = $true
        $again = New-Tree 'Again' @('a.txt')
        @(Clear-SwDirectoryContents -Path $again).Count | Should -Be 0
        @(Clear-SwDirectoryContents -Path (P $script:Target 'missing')).Count | Should -Be 0
    }

    It 'F-30 evaluates -CanRemove three times for a folder child and twice for a file child' {
        $folderRoot = New-Tree 'FolderChild' @('nested/b.txt')
        $fileRoot = New-Tree 'FileChild' @('a.txt')
        $script:Probe = 0
        Clear-SwDirectoryContents -Path $folderRoot -CanRemove { $script:Probe++; $true }
        $script:Probe | Should -Be 3
        $script:Probe = 0
        Clear-SwDirectoryContents -Path $fileRoot -CanRemove { $script:Probe++; $true }
        $script:Probe | Should -Be 2
    }

    It 'F-30 skips a folder child with one SKIPPED line when the probe reports active from the third call on' {
        $root = New-Tree 'Temp' @('nested/b.txt')
        $script:Probe = 0
        Clear-SwDirectoryContents -Path $root -CanRemove { $script:Probe++; $script:Probe -lt 3 }
        Exists (P $root 'nested' 'b.txt') | Should -BeTrue
        @($script:Ops | Where-Object { $_.Action -eq 'SKIPPED' }).Count | Should -Be 1
        $script:Ops.Count | Should -Be 1
        $script:FilesCleaned | Should -Be 0
    }

    It 'F-30 leaves the entry standing without a log line when the probe reports active from the second call on' {
        $root = New-Tree 'Temp' @('nested/b.txt')
        $script:Probe = 0
        Clear-SwDirectoryContents -Path $root -CanRemove { $script:Probe++; $script:Probe -lt 2 }
        Exists (P $root 'nested' 'b.txt') | Should -BeTrue
        $script:Ops.Count | Should -Be 0
        $script:FilesCleaned | Should -Be 0
    }

    It 'F-30 never asks the condition about a child that is protected' {
        $root = New-Tree 'Temp' @('a.txt')
        $script:ProtectedPaths = @((P $root 'a.txt'))
        $script:Probe = 0
        Clear-SwDirectoryContents -Path $root -CanRemove { $script:Probe++; $true }
        $script:Probe | Should -Be 1 -Because 'only the check of the root asks'
        Exists (P $root 'a.txt') | Should -BeTrue
    }
}

# ============================================================================
# Remove-SwOldFiles
# ============================================================================

Describe 'Remove-SwOldFiles' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        $script:FixedNow = [datetime]'2026-01-10T12:00:00'
        Mock Get-Date { $script:FixedNow }
    }
    AfterEach { Stop-Case }

    It 'F-34 removes only the files that are older than the given days; a folder inside is not searched (<Mode>)' -ForEach @(
        @{ Mode = 'real run'; Dry = $false }
        @{ Mode = 'dry run'; Dry = $true }
    ) {
        $root = New-Dir (P $script:Target 'Logs')
        $old = New-File (P $root 'old.txt') 10
        $recent = New-File (P $root 'recent.txt') 10
        $today = New-File (P $root 'today.txt') 10
        $inner = New-File (P $root 'sub' 'inner-old.txt') 10
        [System.IO.File]::SetLastWriteTime($old, $script:FixedNow.AddDays(-30))
        [System.IO.File]::SetLastWriteTime($recent, $script:FixedNow.AddDays(-3))
        [System.IO.File]::SetLastWriteTime($today, $script:FixedNow)
        [System.IO.File]::SetLastWriteTime($inner, $script:FixedNow.AddDays(-30))
        [System.IO.Directory]::SetLastWriteTime((P $root 'sub'), $script:FixedNow.AddDays(-30))
        $script:SweeprDryRunMode = $Dry
        Remove-SwOldFiles -Path $root -DaysOld 7
        Exists $recent | Should -BeTrue
        Exists $today | Should -BeTrue
        Exists $inner | Should -BeTrue
        Exists (P $root 'sub') | Should -BeTrue
        if ($Dry) { Exists $old | Should -BeTrue } else { Exists $old | Should -BeFalse }
        $script:FilesCleaned | Should -Be 1 -Because $Mode
    }

    It 'F-34 uses 7 days when -DaysOld is not given' {
        $root = New-Dir (P $script:Target 'Logs')
        $eight = New-File (P $root 'eight.txt') 10
        $six = New-File (P $root 'six.txt') 10
        [System.IO.File]::SetLastWriteTime($eight, $script:FixedNow.AddDays(-8))
        [System.IO.File]::SetLastWriteTime($six, $script:FixedNow.AddDays(-6))
        Remove-SwOldFiles -Path $root
        Exists $eight | Should -BeFalse
        Exists $six | Should -BeTrue
    }

    It 'F-34 removes only files strictly older than the cut-off: a file at exactly the cut-off stays, one second older goes' {
        $root = New-Dir (P $script:Target 'Logs')
        $edge = New-File (P $root 'edge.txt') 10
        $older = New-File (P $root 'older.txt') 10
        [System.IO.File]::SetLastWriteTime($edge, $script:FixedNow.AddDays(-7))
        [System.IO.File]::SetLastWriteTime($older, $script:FixedNow.AddDays(-7).AddSeconds(-1))
        Remove-SwOldFiles -Path $root -DaysOld 7
        Exists $edge | Should -BeTrue
        Exists $older | Should -BeFalse
    }

    It 'F-34 takes the cut-off from Get-Date' {
        $root = New-Dir (P $script:Target 'Logs')
        $file = New-File (P $root 'a.txt') 10
        [System.IO.File]::SetLastWriteTime($file, [datetime]'2026-01-05T12:00:00')
        $script:FixedNow = [datetime]'2026-01-08T12:00:00'
        Remove-SwOldFiles -Path $root -DaysOld 7
        Exists $file | Should -BeTrue
        $script:FixedNow = [datetime]'2026-01-20T12:00:00'
        Remove-SwOldFiles -Path $root -DaysOld 7
        Exists $file | Should -BeFalse
        Should -Invoke -CommandName Get-Date -Times 1
    }

    It 'F-34 applies -Filter as a name filter, and counts hidden files' {
        $root = New-Dir (P $script:Target 'Logs')
        $log = New-File (P $root 'a.log') 10
        $txt = New-File (P $root 'a.txt') 10
        $hidden = New-File (P $root '.hidden.log') 10
        foreach ($file in @($log, $txt, $hidden)) { [System.IO.File]::SetLastWriteTime($file, $script:FixedNow.AddDays(-30)) }
        if ($script:OnWindows) { [System.IO.File]::SetAttributes($hidden, ([System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System)) }
        Remove-SwOldFiles -Path $root -DaysOld 7 -Filter '*.log'
        Exists $log | Should -BeFalse
        Exists $hidden | Should -BeFalse
        Exists $txt | Should -BeTrue
    }

    It 'F-34 removes nothing for a negative -DaysOld' {
        $root = New-Dir (P $script:Target 'Logs')
        $file = New-File (P $root 'a.txt') 10
        [System.IO.File]::SetLastWriteTime($file, $script:FixedNow.AddDays(-30))
        Remove-SwOldFiles -Path $root -DaysOld -1
        Exists $file | Should -BeTrue
        $script:FilesCleaned | Should -Be 0
    }

    It 'F-34 hands the files to Remove-SwItems with the description plus the days' {
        $root = New-Dir (P $script:Target 'Logs')
        $old = New-File (P $root 'old.txt') 10
        $recent = New-File (P $root 'recent.txt') 10
        [System.IO.File]::SetLastWriteTime($old, $script:FixedNow.AddDays(-30))
        [System.IO.File]::SetLastWriteTime($recent, $script:FixedNow.AddDays(-1))
        Mock Remove-SwItems { $script:GotPaths = @($Paths); $script:GotDescription = $Description }
        Remove-SwOldFiles -Path $root
        Should -Invoke -CommandName Remove-SwItems -Times 1 -Exactly
        $script:GotDescription | Should -BeExactly 'Old files (>7d old)'
        @($script:GotPaths).Count | Should -Be 1
        (Fold $script:GotPaths[0]) | Should -BeExactly (Fold $old)
        Remove-SwOldFiles -Path $root -DaysOld 3 -Description 'Cache'
        $script:GotDescription | Should -BeExactly 'Cache (>3d old)'
    }

    It 'F-34 does nothing for a root that is not complete, does not exist, is a file or is a link' {
        $file = New-File (P $script:Target 'a.txt') 10
        $target = New-Dir (P $script:Work 'link-target')
        $old = New-File (P $target 'old.txt') 10
        [System.IO.File]::SetLastWriteTime($old, $script:FixedNow.AddDays(-30))
        $link = P $script:Target 'rootlink'
        New-TestLink $link $target
        Mock Remove-SwItems { throw 'must not remove' }
        foreach ($path in @('relative-folder', (P $script:Target 'missing'), $file, $link)) {
            { Remove-SwOldFiles -Path $path } | Should -Not -Throw
        }
        Should -Invoke -CommandName Remove-SwItems -Times 0 -Exactly
        Exists $old | Should -BeTrue
    }

    It 'F-34 forms the snapshot of the root without -AllowLeafLink and does nothing without one' {
        $root = New-Dir (P $script:Target 'Logs')
        $old = New-File (P $root 'old.txt') 10
        [System.IO.File]::SetLastWriteTime($old, $script:FixedNow.AddDays(-30))
        $script:FakeNoIdentity = @($root)
        Remove-SwOldFiles -Path $root
        Exists $old | Should -BeTrue
        Should -Invoke -CommandName Get-SwPathSnapshot -Times 1 -ParameterFilter { (Fold $Path) -eq (Fold $root) -and -not $AllowLeafLink }
    }

    It 'F-34 does nothing when the root changed after the listing' {
        $root = New-Dir (P $script:Target 'Logs')
        $old = New-File (P $root 'old.txt') 10
        [System.IO.File]::SetLastWriteTime($old, $script:FixedNow.AddDays(-30))
        Mock Test-SwPathSnapshot { $false }
        Mock Remove-SwItems { throw 'must not remove' }
        Remove-SwOldFiles -Path $root
        Should -Invoke -CommandName Remove-SwItems -Times 0 -Exactly
        Exists $old | Should -BeTrue
    }

    It 'F-34 does not call Remove-SwItems when there is no file to remove' {
        $root = New-Dir (P $script:Target 'Logs')
        New-File (P $root 'recent.txt') 10 | Out-Null
        Mock Remove-SwItems { throw 'must not remove' }
        Remove-SwOldFiles -Path $root
        Should -Invoke -CommandName Remove-SwItems -Times 0 -Exactly
    }

    It 'F-34 does not ask Test-SwSafePath about the root, only each file is checked' {
        $root = New-Dir (P $script:Target 'Logs')
        $old = New-File (P $root 'old.txt') 10
        [System.IO.File]::SetLastWriteTime($old, $script:FixedNow.AddDays(-30))
        Mock Test-SwSafePath { $true }
        Remove-SwOldFiles -Path $root
        Should -Invoke -CommandName Test-SwSafePath -Times 0 -Exactly -ParameterFilter { (Fold $Path) -eq (Fold $root) }
        Should -Invoke -CommandName Test-SwSafePath -Times 1 -ParameterFilter { (Fold $Path) -eq (Fold $old) }
        Exists $old | Should -BeFalse
    }

    It 'F-34 leaves a protected old file in place and removes the others' {
        $root = New-Dir (P $script:Target 'Logs')
        $keep = New-File (P $root 'keep.log') 10
        $old = New-File (P $root 'old.log') 10
        foreach ($file in @($keep, $old)) { [System.IO.File]::SetLastWriteTime($file, $script:FixedNow.AddDays(-30)) }
        Set-Whitelist @($keep)
        Remove-SwOldFiles -Path $root
        Exists $keep | Should -BeTrue
        Exists $old | Should -BeFalse
    }

    It 'F-32 writes nothing to the pipeline' {
        $root = New-Dir (P $script:Target 'Logs')
        $old = New-File (P $root 'old.txt') 10
        [System.IO.File]::SetLastWriteTime($old, $script:FixedNow.AddDays(-30))
        @(Remove-SwOldFiles -Path $root).Count | Should -Be 0
        $again = New-File (P $root 'again.txt') 10
        [System.IO.File]::SetLastWriteTime($again, $script:FixedNow.AddDays(-30))
        $script:SweeprDryRunMode = $true
        @(Remove-SwOldFiles -Path $root).Count | Should -Be 0
    }
}

# ============================================================================
# Dry-run state and scope
# ============================================================================

Describe 'Dry-run state' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
    }
    AfterEach { Stop-Case }

    It 'F-35 sets the state with Set-SwDryRunMode -Enabled and gives it back as one boolean' {
        Set-SwDryRunMode -Enabled $true
        $script:SweeprDryRunMode | Should -BeTrue
        $result = @(Test-SwDryRunMode)
        $result.Count | Should -Be 1
        Assert-Result $result[0] $true 'enabled'
        Set-SwDryRunMode $false
        Assert-Result (Test-SwDryRunMode) $false 'disabled'
        Set-SwDryRunMode -Enabled $true
        Assert-Result (Test-SwDryRunMode) $true 'enabled again'
    }

    It 'F-35 switches the state off when Set-SwDryRunMode gets no value' {
        Set-SwDryRunMode -Enabled $true
        Set-SwDryRunMode
        Assert-Result (Test-SwDryRunMode) $false 'default'
    }

    It 'F-35 treats a value set directly like a value from Set-SwDryRunMode' {
        $script:SweeprDryRunMode = $true
        Assert-Result (Test-SwDryRunMode) $true 'direct true'
        $file = New-File (P $script:Target 'a.txt') 10
        Assert-Result (Remove-SwItem -Path $file) $true 'preview'
        Exists $file | Should -BeTrue
        $script:SweeprDryRunMode = $false
        Assert-Result (Test-SwDryRunMode) $false 'direct false'
        Assert-Result (Remove-SwItem -Path $file) $true 'removal'
        Exists $file | Should -BeFalse
    }

    It 'G-7 reads the state at each call' {
        $one = New-File (P $script:Target 'a.txt') 10
        $two = New-File (P $script:Target 'b.txt') 10
        $script:SweeprDryRunMode = $true
        $null = Remove-SwItem -Path $one
        Exists $one | Should -BeTrue
        $script:SweeprDryRunMode = $false
        $null = Remove-SwItem -Path $one
        Exists $one | Should -BeFalse
        $script:SweeprDryRunMode = $true
        $null = Remove-SwItem -Path $two
        Exists $two | Should -BeTrue
    }

    It 'F-35 counts a missing or null state as a dry run (<Case>)' -ForEach @(
        @{ Case = 'the variable is removed'; Mode = 'removed' }
        @{ Case = 'the variable is null'; Mode = 'null' }
    ) {
        if ($Mode -eq 'removed') { Remove-Variable -Name SweeprDryRunMode -Scope Script } else { $script:SweeprDryRunMode = $null }
        Assert-Result (Test-SwDryRunMode) $true $Case
        $file = New-File (P $script:Target 'a.txt') 10
        Assert-Result (Remove-SwItem -Path $file) $true 'preview'
        Exists $file | Should -BeTrue
        $script:DrySaid.Count | Should -Be 1
        $script:Ops.Count | Should -Be 0
    }

    It 'S-5 removes nothing in any removal path when the state is missing (<Case>)' -ForEach @(
        @{ Case = 'the variable is removed'; Mode = 'removed' }
        @{ Case = 'the variable is null'; Mode = 'null' }
    ) {
        $file = New-File (P $script:Target 'a.txt') 10
        $tree = New-Tree 'full' @('b.txt', 'nested/c.txt')
        $clearRoot = New-Tree 'Temp' @('d.txt')
        $logs = New-Dir (P $script:Target 'Logs')
        $old = New-File (P $logs 'old.log') 10
        [System.IO.File]::SetLastWriteTime($old, (Get-Date).AddDays(-30))
        $before = Get-Listing $script:Work
        if ($Mode -eq 'removed') { Remove-Variable -Name SweeprDryRunMode -Scope Script } else { $script:SweeprDryRunMode = $null }
        $null = Remove-SwItem -Path $file
        $null = Remove-SwItem -Path $tree
        Remove-SwItems -Paths @($file, $tree)
        Clear-SwDirectoryContents -Path $clearRoot
        Remove-SwOldFiles -Path $logs
        Same-Listing (Get-Listing $script:Work) $before | Should -BeTrue
        $script:Ops.Count | Should -Be 0
    }

    It 'F-36 changes nothing in a dry run in any removal path: no entry, no attribute, no operation, no removal call, no shell call (<Name>)' -ForEach @(
        @{ Name = 'Remove-SwItem on a file'; Run = { param($f, $t, $c, $l) $null = Remove-SwItem -Path $f } }
        @{ Name = 'Remove-SwItem on a folder'; Run = { param($f, $t, $c, $l) $null = Remove-SwItem -Path $t } }
        @{ Name = 'Remove-SwItem -Recycle on a file'; Run = { param($f, $t, $c, $l) $null = Remove-SwItem -Path $f -Recycle } }
        @{ Name = 'Remove-SwItem -Recycle on a folder'; Run = { param($f, $t, $c, $l) $null = Remove-SwItem -Path $t -Recycle } }
        @{ Name = 'Remove-SwItems'; Run = { param($f, $t, $c, $l) Remove-SwItems -Paths @($f, $t) } }
        @{ Name = 'Clear-SwDirectoryContents'; Run = { param($f, $t, $c, $l) Clear-SwDirectoryContents -Path $c } }
        @{ Name = 'Remove-SwOldFiles'; Run = { param($f, $t, $c, $l) Remove-SwOldFiles -Path $l } }
    ) {
        $file = New-File (P $script:Target 'a.txt') 10
        $tree = New-Tree 'full' @('b.txt', 'nested/c.txt')
        $clearRoot = New-Tree 'Temp' @('d.txt', 'sub/e.txt')
        $logs = New-Dir (P $script:Target 'Logs')
        $old = New-File (P $logs 'old.log') 10
        [System.IO.File]::SetLastWriteTime($old, (Get-Date).AddDays(-30))
        [System.IO.File]::SetAttributes($file, [System.IO.FileAttributes]::ReadOnly)
        $before = Get-Listing $script:Work
        $script:SweeprDryRunMode = $true
        Mock Remove-Item { throw 'Remove-Item must not run in a dry run' }
        Mock Remove-SwTreeEntry { throw 'no removal in a dry run' }
        Mock Remove-SwDirectoryTree { throw 'no removal in a dry run' }
        Mock Move-SwItemToRecycleBin { throw 'no shell call in a dry run' }
        try {
            & $Run $file $tree $clearRoot $logs
            Same-Listing (Get-Listing $script:Work) $before | Should -BeTrue
            [int]([System.IO.File]::GetAttributes($file) -band [System.IO.FileAttributes]::ReadOnly) | Should -Be 1
        }
        finally { [System.IO.File]::SetAttributes($file, [System.IO.FileAttributes]::Normal) }
        Should -Invoke -CommandName Remove-Item -Times 0 -Exactly
        Should -Invoke -CommandName Remove-SwTreeEntry -Times 0 -Exactly
        Should -Invoke -CommandName Remove-SwDirectoryTree -Times 0 -Exactly
        Should -Invoke -CommandName Move-SwItemToRecycleBin -Times 0 -Exactly
        Should -Invoke -CommandName Write-SweeprOperation -Times 0 -Exactly
        $script:Ops.Count | Should -Be 0
    }

    It 'F-36 gives true only for what a real run would accept: preview and real run agree (<Case>)' -ForEach @(
        @{ Case = 'a plain file'; Setup = 'file' }
        @{ Case = 'a plain folder'; Setup = 'folder' }
        @{ Case = 'a protected file'; Setup = 'protected' }
        @{ Case = 'a folder with a whitelisted entry'; Setup = 'whitelisted' }
        @{ Case = 'a path that does not exist'; Setup = 'missing' }
        @{ Case = 'a refusing guard'; Setup = 'guard' }
        @{ Case = 'a path without identity'; Setup = 'noidentity' }
    ) {
        $results = @()
        foreach ($dry in @($true, $false)) {
            $script:SweeprDryRunMode = $dry
            $name = 'case-' + [guid]::NewGuid().ToString('N')
            $guard = { $true }
            switch ($Setup) {
                'file' { $path = New-File (P $script:Target $name 'a.txt') 10 }
                'folder' { $path = New-Tree $name @('a.txt', 'nested/b.txt') }
                'protected' { $path = New-File (P $script:Prot $name) 10 }
                'whitelisted' { $path = New-Tree $name @('a.txt', 'keep/k.txt'); Set-Whitelist @((P $path 'keep')) }
                'missing' { $path = P $script:Target $name }
                'guard' { $path = New-File (P $script:Target $name 'a.txt') 10; $guard = { $false } }
                'noidentity' { $path = New-File (P $script:Target $name 'a.txt') 10; $script:FakeNoIdentity = @($path) }
            }
            $results += [bool](Remove-SwItem -Path $path -Guard $guard)
        }
        $results[0] | Should -Be $results[1] -Because $Case
    }

    It 'F-36 lets a dry run write only to the console, the statistics, the collector and the list file' {
        $file = New-File (P $script:Target 'a.txt') 4096
        $script:SweeprDryRunMode = $true
        $script:DryRunCollector = New-Object 'System.Collections.Generic.List[object]'
        $null = Remove-SwItem -Path $file
        $script:DrySaid.Count | Should -Be 1
        $script:FilesCleaned | Should -Be 1
        $script:DryRunCollector.Count | Should -Be 1
        $list = New-File (P $script:Work 'clean-list.txt') 0
        $script:DryRunCollector = $null
        $script:ExportListFile = $list
        $null = Remove-SwItem -Path $file
        ([System.IO.File]::ReadAllText($list)) | Should -BeLike ('*' + (Get-Tail $file) + '*')
        Exists $file | Should -BeTrue
    }
}

# ============================================================================
# Preview list
# ============================================================================

Describe 'Add-SwDryRunListEntries' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        # The list belongs to the preview, so the state is a dry run; the rules do not depend on it.
        $script:SweeprDryRunMode = $true
        $script:ListFile = New-File (P $script:Work 'lists' 'clean-list.txt') 0
        [System.IO.File]::WriteAllBytes($script:ListFile, [System.Text.Encoding]::ASCII.GetBytes("header`r`n"))
        $script:ExportListFile = $script:ListFile
        $script:Utf8 = New-Object System.Text.UTF8Encoding $false
    }
    AfterEach { Stop-Case }

    It 'F-37 appends a description line, one line per path and an empty line, with CRLF' {
        Add-SwDryRunListEntries -Description 'Test cache' -Paths @('C:\Cache\a.tmp')
        [System.IO.File]::ReadAllText($script:ListFile) | Should -BeExactly "header`r`n# Test cache`r`nC:\Cache\a.tmp`r`n`r`n"
    }

    It 'F-37 appends every path on its own line and keeps appending at the next call' {
        Add-SwDryRunListEntries -Description 'First' -Paths @('C:\Cache\a.tmp', 'C:\Cache\b.tmp')
        Add-SwDryRunListEntries -Description 'Second' -Paths @('C:\Other\c.tmp')
        [System.IO.File]::ReadAllText($script:ListFile) | Should -BeExactly "header`r`n# First`r`nC:\Cache\a.tmp`r`nC:\Cache\b.tmp`r`n`r`n# Second`r`nC:\Other\c.tmp`r`n`r`n"
    }

    It 'F-37 writes UTF-8 without a byte order mark, so that a path with a non-ASCII letter can be copied into the whitelist' {
        $path = 'C:\Cache\M' + [char]0xFC + 'nchen.tmp'
        Add-SwDryRunListEntries -Description ('Caf' + [char]0xE9) -Paths @($path)
        $expected = $script:Utf8.GetBytes("# Caf" + [char]0xE9 + "`r`n" + $path + "`r`n`r`n")
        $all = [System.IO.File]::ReadAllBytes($script:ListFile)
        $head = [System.Text.Encoding]::ASCII.GetBytes("header`r`n")
        $all.Length | Should -Be ($head.Length + $expected.Length)
        $tail = New-Object byte[] $expected.Length
        [System.Array]::Copy($all, $head.Length, $tail, 0, $expected.Length)
        ($tail -join ',') | Should -BeExactly ($expected -join ',')
    }

    It 'F-37 only appends: it neither shortens nor creates the file' {
        $missing = P $script:Work 'lists' 'missing-list.txt'
        $script:ExportListFile = $missing
        Add-SwDryRunListEntries -Description 'x' -Paths @('C:\a')
        [System.IO.File]::Exists($missing) | Should -BeFalse
        $script:ExportListFile = $script:ListFile
        Add-SwDryRunListEntries -Description 'x' -Paths @('C:\a')
        [System.IO.File]::ReadAllText($script:ListFile) | Should -BeLike "header`r`n*"
    }

    It 'F-37 does nothing without paths (<Case>)' -ForEach @(
        @{ Case = 'an empty list'; Mode = 'empty' }
        @{ Case = 'null'; Mode = 'null' }
    ) {
        $script:DryRunCollector = New-Object 'System.Collections.Generic.List[object]'
        if ($Mode -eq 'empty') { Add-SwDryRunListEntries -Description 'x' -Paths @() } else { Add-SwDryRunListEntries -Description 'x' -Paths $null }
        $script:DryRunCollector.Count | Should -Be 0
        $script:DryRunCollector = $null
        if ($Mode -eq 'empty') { Add-SwDryRunListEntries -Description 'x' -Paths @() } else { Add-SwDryRunListEntries -Description 'x' -Paths $null }
        [System.IO.File]::ReadAllText($script:ListFile) | Should -BeExactly "header`r`n"
    }

    It 'F-37 collects one entry per path when the collector is a list, and leaves the file alone' {
        $script:DryRunCollector = New-Object 'System.Collections.Generic.List[object]'
        Add-SwDryRunListEntries -Description 'Example cache' -Paths @('C:\a', 'C:\b', 'C:\c') -SizeBytes @(10, 20, 30) -FileCounts @(1, 2, 3)
        $script:DryRunCollector.Count | Should -Be 3
        @($script:DryRunCollector | ForEach-Object { $_.Path }) | Should -Be @('C:\a', 'C:\b', 'C:\c')
        @($script:DryRunCollector | ForEach-Object { $_.SizeBytes }) | Should -Be @(10, 20, 30)
        @($script:DryRunCollector | ForEach-Object { $_.Count }) | Should -Be @(1, 2, 3)
        @($script:DryRunCollector | ForEach-Object { $_.Description } | Select-Object -Unique) | Should -Be @('Example cache')
        @($script:DryRunCollector | ForEach-Object { $_.Section } | Select-Object -Unique) | Should -Be @('Example section')
        [System.IO.File]::ReadAllText($script:ListFile) | Should -BeExactly "header`r`n"
    }

    It 'F-37 types the collector entries: Section string, SizeBytes long, Count int' {
        $script:DryRunCollector = New-Object 'System.Collections.Generic.List[object]'
        Add-SwDryRunListEntries -Description 'x' -Paths @('C:\a') -SizeBytes @(10) -FileCounts @(2)
        $entry = $script:DryRunCollector[0]
        $entry.Section | Should -BeOfType [string]
        $entry.Description | Should -BeOfType [string]
        $entry.Path | Should -BeOfType [string]
        $entry.SizeBytes | Should -BeOfType [long]
        $entry.Count | Should -BeOfType [int]
    }

    It 'F-37 uses 0 bytes and 1 file when the size or the count for an index is missing' {
        $script:DryRunCollector = New-Object 'System.Collections.Generic.List[object]'
        Add-SwDryRunListEntries -Description 'x' -Paths @('C:\a', 'C:\b', 'C:\c') -SizeBytes @(10) -FileCounts @(4, 5)
        @($script:DryRunCollector | ForEach-Object { $_.SizeBytes }) | Should -Be @(10, 0, 0)
        @($script:DryRunCollector | ForEach-Object { $_.Count }) | Should -Be @(4, 5, 1)
        $script:DryRunCollector.Clear()
        Add-SwDryRunListEntries -Description 'x' -Paths @('C:\a')
        $script:DryRunCollector[0].SizeBytes | Should -Be 0
        $script:DryRunCollector[0].Count | Should -Be 1
    }

    It 'F-37 takes the section name from the current section' {
        $script:DryRunCollector = New-Object 'System.Collections.Generic.List[object]'
        $script:CurrentSection = @{ Active = $true; Activity = $false; Name = 'Browser caches' }
        Add-SwDryRunListEntries -Description 'x' -Paths @('C:\a')
        $script:DryRunCollector[0].Section | Should -BeExactly 'Browser caches'
    }

    It 'F-37 treats the path of the list file literally: the lines go to the folder with brackets, not to its neighbor' {
        $odd = New-File (P $script:Work 'Apps [x]' 'clean-list.txt') 0
        $decoy = New-File (P $script:Work 'Apps x' 'clean-list.txt') 0
        $script:ExportListFile = $odd
        Add-SwDryRunListEntries -Description 'x' -Paths @('C:\a')
        [System.IO.File]::ReadAllText($odd) | Should -BeLike '*C:\a*'
        [System.IO.File]::ReadAllText($decoy) | Should -BeExactly ''
    }

    It 'F-37 does nothing and does not fail when the list file variable is not set, null or empty (<Case>)' -ForEach @(
        @{ Case = 'removed'; Mode = 'removed' }
        @{ Case = 'null'; Mode = 'null' }
        @{ Case = 'empty'; Mode = 'empty' }
    ) {
        switch ($Mode) {
            'removed' { Remove-Variable -Name ExportListFile -Scope Script }
            'null' { $script:ExportListFile = $null }
            'empty' { $script:ExportListFile = '' }
        }
        { Add-SwDryRunListEntries -Description 'x' -Paths @('C:\a') } | Should -Not -Throw
        [System.IO.File]::ReadAllText($script:ListFile) | Should -BeExactly "header`r`n"
    }

    It 'F-37 does nothing when there is neither a collector nor a list file' {
        Remove-Variable -Name ExportListFile -Scope Script
        $script:DryRunCollector = $null
        $before = Get-Listing $script:Work
        { Add-SwDryRunListEntries -Description 'x' -Paths @('C:\a') } | Should -Not -Throw
        Same-Listing (Get-Listing $script:Work) $before | Should -BeTrue
    }

    It 'F-37 reports a write failure through Write-Debug and does not throw' {
        Mock Write-Debug { }
        $stream = [System.IO.FileStream]::new($script:ListFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            { Add-SwDryRunListEntries -Description 'x' -Paths @('C:\a') } | Should -Not -Throw
        }
        finally { $stream.Dispose() }
        Should -Invoke -CommandName Write-Debug -Times 1
    }

    It 'F-37 writes nothing to the pipeline' {
        @(Add-SwDryRunListEntries -Description 'x' -Paths @('C:\a')).Count | Should -Be 0
        $script:DryRunCollector = New-Object 'System.Collections.Generic.List[object]'
        @(Add-SwDryRunListEntries -Description 'x' -Paths @('C:\a')).Count | Should -Be 0
    }

    It 'F-37 gets the list entries of a preview from the removal functions, matching the preview line' {
        $script:SweeprDryRunMode = $true
        $one = New-File (P $script:Target 'a.txt') 10
        $two = New-Tree 'full' @('b.txt=20', 'nested/c.txt=30')
        Remove-SwItems -Paths @($one, $two) -Description 'Example cache'
        $lines = @([System.IO.File]::ReadAllText($script:ListFile) -split "`r`n")
        $lines.Count | Should -Be 6
        $lines[0] | Should -BeExactly 'header'
        $lines[1] | Should -BeExactly '# Example cache'
        (Fold $lines[2]) | Should -BeExactly (Fold $one)
        (Fold $lines[3]) | Should -BeExactly (Fold $two)
        $lines[4] | Should -BeExactly ''
        $lines[5] | Should -BeExactly ''
    }
}

# ============================================================================
# Statistics
# ============================================================================

Describe 'Cleanup statistics' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
    }
    AfterEach { Stop-Case }

    It 'F-39 gives the statistics as one table with the five keys and their types' {
        $script:TotalSizeCleaned = 3
        $script:FilesCleaned = 4
        $script:TotalItems = 2
        $script:OwnerCleanups = 1
        $result = @(Get-SwCleanupStats)
        $result.Count | Should -Be 1
        $stats = $result[0]
        $stats | Should -BeOfType [hashtable]
        @($stats.Keys | Sort-Object) -join ',' | Should -BeExactly 'FilesCleaned,OwnerCleanups,TotalItems,TotalSizeHuman,TotalSizeKB'
        $stats['TotalSizeKB'] | Should -BeOfType [long]
        $stats['TotalSizeKB'] | Should -Be 3
        $stats['TotalSizeHuman'] | Should -BeExactly (Format-SwByteSize -Bytes (3 * 1024))
        $stats['FilesCleaned'] | Should -Be 4
        $stats['TotalItems'] | Should -Be 2
        $stats['OwnerCleanups'] | Should -Be 1
    }

    It 'F-39 sets the four counters to 0 with Reset-SwCleanupStats, and the readable size is 0B' {
        $script:TotalSizeCleaned = 9
        $script:FilesCleaned = 9
        $script:TotalItems = 9
        $script:OwnerCleanups = 9
        @(Reset-SwCleanupStats).Count | Should -Be 0
        $stats = Get-SwCleanupStats
        $stats['TotalSizeKB'] | Should -Be 0
        $stats['FilesCleaned'] | Should -Be 0
        $stats['TotalItems'] | Should -Be 0
        $stats['OwnerCleanups'] | Should -Be 0
        $stats['TotalSizeHuman'] | Should -BeExactly '0B'
    }

    It 'G-8 does not throw when a counter is missing: the statistics can be read and reset' {
        foreach ($name in 'TotalSizeCleaned', 'FilesCleaned', 'TotalItems', 'OwnerCleanups') { Remove-Variable -Name $name -Scope Script }
        $stats = $null
        $stats = Get-Result { Get-SwCleanupStats }
        $stats | Should -BeOfType [hashtable]
        Get-Result { Reset-SwCleanupStats }
        $again = Get-SwCleanupStats
        $again['TotalSizeKB'] | Should -Be 0
        $again['FilesCleaned'] | Should -Be 0
        $again['TotalItems'] | Should -Be 0
        $again['OwnerCleanups'] | Should -Be 0
    }

    It 'F-39 leaves the dry-run state, the collectors and the list file alone when it resets' {
        $collector = New-Object 'System.Collections.Generic.List[object]'
        $script:SweeprDryRunMode = $true
        $script:DryRunCollector = $collector
        $script:NotMeasuredCollector = $collector
        $script:ExportListFile = 'C:\Example\clean-list.txt'
        Reset-SwCleanupStats
        $script:SweeprDryRunMode | Should -BeTrue
        [object]::ReferenceEquals($script:DryRunCollector, $collector) | Should -BeTrue
        [object]::ReferenceEquals($script:NotMeasuredCollector, $collector) | Should -BeTrue
        $script:ExportListFile | Should -BeExactly 'C:\Example\clean-list.txt'
    }

    It 'F-39 counts a folder of 3000 and 5000 bytes as 8 KB, in a real run and in a preview' {
        foreach ($dry in @($false, $true)) {
            $script:SweeprDryRunMode = $dry
            Reset-SwCleanupStats
            $root = New-Tree ('full' + $dry) @('a.bin=3000', 'nested/b.bin=5000')
            Assert-Result (Remove-SwItem -Path $root) $true "dry run: $dry"
            (Get-SwCleanupStats)['TotalSizeKB'] | Should -Be 8
        }
    }

    It 'F-39 adds to a counter that was set from the outside' {
        $script:TotalSizeCleaned = 10
        $script:FilesCleaned = 5
        $script:TotalItems = 7
        $script:OwnerCleanups = 2
        $file = New-File (P $script:Target 'a.txt') 2048
        $null = Remove-SwItem -Path $file
        $script:TotalSizeCleaned | Should -Be 12
        $script:FilesCleaned | Should -Be 6
        $script:TotalItems | Should -Be 8
        $script:OwnerCleanups | Should -Be 2
    }

    It 'F-39 counts a folder as one path, whatever the number of files in it' {
        $root = New-Tree 'full' @('a.txt', 'b.txt', 'nested/c.txt', 'nested/d.txt', 'nested/deeper/e.txt')
        $null = Remove-SwItem -Path $root
        $script:FilesCleaned | Should -Be 1
        $script:TotalItems | Should -Be 1
    }

    It 'F-39 rounds the kilobytes up for each path of Remove-SwItem and once for the sum of Remove-SwItems' {
        $one = New-File (P $script:Target 'a.bin') 1
        $two = New-File (P $script:Target 'b.bin') 1
        $null = Remove-SwItem -Path $one
        $null = Remove-SwItem -Path $two
        $script:TotalSizeCleaned | Should -Be 2
        Reset-SwCleanupStats
        $three = New-File (P $script:Target 'c.bin') 1
        $four = New-File (P $script:Target 'd.bin') 1
        Remove-SwItems -Paths @($three, $four)
        $script:TotalSizeCleaned | Should -Be 1
    }

    It 'F-39 counts nothing for a recycled folder except one path and one item' {
        $root = New-Tree 'full' @('a.bin=5000')
        Mock Move-SwItemToRecycleBin { }
        Assert-Result (Remove-SwItem -Path $root -Recycle) $true 'recycle'
        $stats = Get-SwCleanupStats
        $stats['TotalSizeKB'] | Should -Be 0
        $stats['FilesCleaned'] | Should -Be 1
        $stats['TotalItems'] | Should -Be 1
    }

    It 'F-39 counts nothing when the removal of the second file fails: false and every counter 0' {
        $root = New-Tree 'full' @('long-name-one.txt', 'two.txt')
        Use-TreeEntrySpy
        $script:FailOn = P $root 'two.txt'
        Assert-Result (Remove-SwItem -Path $root) $false 'failure at the second file'
        $stats = Get-SwCleanupStats
        $stats['TotalSizeKB'] | Should -Be 0
        $stats['FilesCleaned'] | Should -Be 0
        $stats['TotalItems'] | Should -Be 0
        $stats['OwnerCleanups'] | Should -Be 0
        Exists (P $root 'long-name-one.txt') | Should -BeFalse -Because 'the first file was removed, and is still not counted'
    }

    It 'F-39 counts nothing for a refusal, a skipped path, a missing path, a failure or a recycle failure' {
        $proj = New-Tree 'proj' @('a.txt', 'keep/k.txt')
        Set-Whitelist @((P $proj 'keep'))
        $null = Remove-SwItem -Path $proj
        $null = Remove-SwItem -Path (P $script:Prot 'x.txt')
        $null = Remove-SwItem -Path (P $script:Target 'missing.txt')
        Remove-SwItems -Paths @($proj)
        $file = New-File (P $script:Target 'a.txt') 10
        Mock Remove-Item { throw 'access-denied-canary' }
        $null = Remove-SwItem -Path $file
        $dir = New-Tree 'full' @('b.txt')
        Mock Move-SwItemToRecycleBin { throw 'Recycle Bin unavailable' }
        Mock Write-Warning { }
        $null = Remove-SwItem -Path $dir -Recycle
        $stats = Get-SwCleanupStats
        $stats['TotalSizeKB'] | Should -Be 0
        $stats['FilesCleaned'] | Should -Be 0
        $stats['TotalItems'] | Should -Be 0
    }

    It 'F-39 leaves OwnerCleanups to the callers: no removal path changes it' {
        $script:OwnerCleanups = 3
        $file = New-File (P $script:Target 'a.txt') 10
        $null = Remove-SwItem -Path $file
        Remove-SwItems -Paths @((New-File (P $script:Target 'b.txt') 10))
        $script:SweeprDryRunMode = $true
        Remove-SwItems -Paths @((New-File (P $script:Target 'c.txt') 10))
        $script:OwnerCleanups | Should -Be 3
    }

    It 'F-39 gives the readable size of the kilobytes in the table' {
        $script:TotalSizeCleaned = 2048
        (Get-SwCleanupStats)['TotalSizeHuman'] | Should -BeExactly (Format-SwByteSize -Bytes (2048 * 1024))
    }
}

# ============================================================================
# Operations log
# ============================================================================

Describe 'Operations log lines of the removal paths' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -RealWriter
        Set-Env 'SWEEPR_NO_OPLOG' $null
        Set-Env '_SWEEPR_OPLOG_RUN_COMMAND' 'clean'
        Set-Env '_SWEEPR_OPLOG_RUN_ID' 'a1'
    }
    AfterEach { Stop-Case }

    It 'F-41 writes one marker and one REMOVED line per path when Remove-SwItem and Remove-SwItems run one after the other' {
        $one = New-File (P $script:Target 'a.txt') 10
        $two = New-File (P $script:Target 'b.txt') 10
        $null = Remove-SwItem -Path $one
        Remove-SwItems -Paths @($two)
        @(Get-LogMarkers).Count | Should -Be 1
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 2
        $records[0] | Should -Match ('^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] \[clean run=a1\] REMOVED ' + [regex]::Escape($one) + ' \(10B\)$')
        $records[1] | Should -Match ('^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] \[clean run=a1\] REMOVED ' + [regex]::Escape($two) + ' \(10B\)$')
    }

    It 'F-42 gives the measured size as the detail of REMOVED and RECYCLED' {
        $one = New-File (P $script:Target 'a.bin') 1536
        $dir = New-Tree 'full' @('b.bin=2048', 'nested/c.bin=1024')
        Mock Move-SwItemToRecycleBin { }
        $null = Remove-SwItem -Path $one
        $null = Remove-SwItem -Path $dir -Recycle
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 2
        $records[0] | Should -Match (' REMOVED ' + [regex]::Escape($one) + ' \(' + [regex]::Escape((Format-SwByteSize -Bytes 1536)) + '\)$')
        $records[1] | Should -Match (' RECYCLED ' + [regex]::Escape($dir) + ' \(' + [regex]::Escape((Format-SwByteSize -Bytes 3072)) + '\)$')
    }

    It 'F-42 passes path and detail on unchanged: parentheses in the path stay, parentheses in the message become brackets' {
        $dir = New-Dir (P $script:Target 'Tools (x86)')
        $file = New-File (P $dir 'a.txt') 10
        Mock Remove-Item { throw 'denied (code 5)' }
        $null = Remove-SwItem -Path $file
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 1
        $records[0] | Should -Match (' FAILED ' + [regex]::Escape($file) + ' \(denied \[code 5\]\)$')
    }

    It 'F-40 writes each path and each result exactly once, only the four actions, and nothing for rejections' {
        $ok = New-File (P $script:Target 'ok.txt') 10
        $bad = New-File (P $script:Target 'bad.txt') 10
        $proj = New-Tree 'proj' @('a.txt', 'keep/k.txt')
        Set-Whitelist @((P $proj 'keep'))
        $recycled = New-Tree 'recycled' @('f.txt')
        $script:FailPath = $bad
        Mock Remove-Item { if ((Fold ([string]@($LiteralPath)[0])) -eq (Fold $script:FailPath)) { throw 'access-denied-canary' }; & $script:RealRemoveItem @PesterBoundParameters }
        Mock Move-SwItemToRecycleBin { }
        Remove-SwItems -Paths @($ok, $bad, $proj, (P $script:Prot 'x.txt'), (P $script:Target 'missing.txt'), 'relative.txt')
        $null = Remove-SwItem -Path $recycled -Recycle
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 4
        $actions = @($records | ForEach-Object { if ($_ -match '\] ([A-Z]+) ') { $Matches[1] } })
        $actions | Should -Be @('REMOVED', 'FAILED', 'SKIPPED', 'RECYCLED')
        @($records | Where-Object { $_ -match 'SKIPPED' })[0] | Should -Match ('SKIPPED ' + [regex]::Escape($proj) + ' \(refused: ')
    }

    It 'F-40 writes SKIPPED for a folder that was refused before the first removal with the prefix refused: and the reason' {
        $proj = New-Tree 'proj' @('a.txt', 'keep/k.txt')
        Set-Whitelist @((P $proj 'keep'))
        $null = Remove-SwItem -Path $proj
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 1
        $records[0] | Should -Match ('\] SKIPPED ' + [regex]::Escape($proj) + ' \(refused: .+\)$')
    }

    It 'F-40 writes FAILED for a folder with the entry counts and the stop position' {
        $root = New-Tree 'full' @('aaaaaaaa.txt', 'bbbbbbbb.txt', 'lock.txt')
        Use-TreeEntrySpy
        $script:FailOn = P $root 'lock.txt'
        $script:FailMessage = 'lock-canary'
        $null = Remove-SwItem -Path $root
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 1
        $record = ConvertFrom-LogRecord $records[0]
        $record.Action | Should -BeExactly 'FAILED'
        $record.Path | Should -BeExactly $root
        Assert-Incomplete $record.Detail 2 3 (P $root 'lock.txt') 'lock-canary'
    }

    It 'F-40 writes the path of a child as its full name when Clear-SwDirectoryContents removes it' {
        $root = New-Tree 'Temp' @('a.txt', 'nested/b.txt')
        Clear-SwDirectoryContents -Path $root
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 2
        $parsed = @($records | ForEach-Object { ConvertFrom-LogRecord $_ })
        @($parsed | ForEach-Object { $_.Action } | Select-Object -Unique) | Should -Be @('REMOVED')
        foreach ($child in @((P $root 'a.txt'), (P $root 'nested'))) {
            @($parsed | Where-Object { (Fold $_.Path) -eq (Fold $child) }).Count | Should -Be 1
        }
    }

    It 'F-40 writes nothing in a dry run, for none of the four actions' {
        $script:SweeprDryRunMode = $true
        $proj = New-Tree 'proj' @('a.txt', 'keep/k.txt')
        Set-Whitelist @((P $proj 'keep'))
        $ok = New-File (P $script:Target 'ok.txt') 10
        $null = Remove-SwItem -Path $ok
        $null = Remove-SwItem -Path $proj
        Remove-SwItems -Paths @($ok, $proj)
        [System.IO.File]::Exists($script:SweeprOperationsLogFile) | Should -BeFalse
    }

    It 'F-40 leaves SWEEPR_NO_OPLOG to the writer: with the variable set nothing is written, the module calls the writer all the same' {
        Set-Env 'SWEEPR_NO_OPLOG' '1'
        $file = New-File (P $script:Target 'a.txt') 10
        $null = Remove-SwItem -Path $file
        [System.IO.File]::Exists($script:SweeprOperationsLogFile) | Should -BeFalse
        Mock Write-SweeprOperation { }
        $other = New-File (P $script:Target 'b.txt') 10
        $null = Remove-SwItem -Path $other
        Should -Invoke -CommandName Write-SweeprOperation -Times 1 -Exactly
    }

    It 'F-43 does not change the result or the count when the writer throws: the file stays removed and the call gives true' {
        $file = New-File (P $script:Target 'a.txt') 10
        Mock Write-SweeprOperation { throw 'writer-canary' }
        Mock Write-Debug { }
        $result = @(Get-Result { Remove-SwItem -Path $file })
        $result.Count | Should -Be 1
        Assert-Result $result[0] $true 'removed although the line was lost'
        Exists $file | Should -BeFalse
        $script:FilesCleaned | Should -Be 1
        Should -Invoke -CommandName Write-Debug -Times 1
    }

    It 'F-43 does not report a failed removal as removed and does not change false when the FAILED line cannot be written' {
        $file = New-File (P $script:Target 'a.txt') 10
        Mock Write-SweeprOperation { throw 'writer-canary' }
        Mock Remove-Item { throw 'access-denied-canary' }
        $result = @(Get-Result { Remove-SwItem -Path $file })
        Assert-Result $result[0] $false 'failed removal'
        Exists $file | Should -BeTrue
        $script:FilesCleaned | Should -Be 0
    }

    It 'F-43 goes on with the next path of Remove-SwItems when the writer throws, and counts what was removed' {
        $one = New-File (P $script:Target 'a.txt') 10
        $two = New-Tree 'full' @('b.txt')
        $proj = New-Tree 'proj' @('keep/k.txt')
        Set-Whitelist @((P $proj 'keep'))
        Mock Write-SweeprOperation { throw 'writer-canary' }
        Mock Write-Debug { }
        { Remove-SwItems -Paths @($proj, $one, $two) } | Should -Not -Throw
        Exists $one | Should -BeFalse
        Exists $two | Should -BeFalse
        $script:FilesCleaned | Should -Be 2
    }

    It 'F-43 does not change the result when the real writer cannot write (the log path is a folder)' {
        [void][System.IO.Directory]::CreateDirectory($script:SweeprOperationsLogFile)
        $file = New-File (P $script:Target 'a.txt') 10
        Assert-Result (Remove-SwItem -Path $file) $true 'writer cannot write'
        Exists $file | Should -BeFalse
        $script:FilesCleaned | Should -Be 1
    }

    It 'S-6 writes every removal, recycle, failure and refusal exactly once, and nothing in a dry run or with the writer switched off' {
        $ok = New-File (P $script:Target 'ok.txt') 10
        $bad = New-File (P $script:Target 'bad.txt') 10
        $proj = New-Tree 'proj' @('a.txt', 'keep/k.txt')
        Set-Whitelist @((P $proj 'keep'))
        $dir = New-Tree 'recycled' @('f.txt')
        $script:FailPath = $bad
        Mock Remove-Item { if ((Fold ([string]@($LiteralPath)[0])) -eq (Fold $script:FailPath)) { throw 'access-denied-canary' }; & $script:RealRemoveItem @PesterBoundParameters }
        Mock Move-SwItemToRecycleBin { }
        $null = Remove-SwItem -Path $ok
        $null = Remove-SwItem -Path $bad
        $null = Remove-SwItem -Path $proj
        $null = Remove-SwItem -Path $dir -Recycle
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 4
        @($records | ForEach-Object { if ($_ -match '\] ([A-Z]+) ') { $Matches[1] } }) | Should -Be @('REMOVED', 'FAILED', 'SKIPPED', 'RECYCLED')
        @(Get-LogMarkers).Count | Should -Be 1
    }
}

# ============================================================================
# Output of the removal functions with the real console functions
# ============================================================================

Describe 'Output of the removal functions with the real console functions' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -RealOutput
    }
    AfterEach { Stop-Case }

    It 'F-24 gives one boolean to the pipeline and keeps the status lines on the host (<Mode>)' -ForEach @(
        @{ Mode = 'real run'; Dry = $false }
        @{ Mode = 'dry run'; Dry = $true }
    ) {
        $script:SweeprDryRunMode = $Dry
        $file = New-File (P $script:Target 'a.txt') 10
        $output = @(Remove-SwItem -Path $file 6>$null)
        $output.Count | Should -Be 1
        $output[0] | Should -BeOfType [bool]
        $output[0] | Should -BeTrue
    }

    It 'F-32 writes nothing to the pipeline from Remove-SwItems, Clear-SwDirectoryContents and Remove-SwOldFiles (<Mode>)' -ForEach @(
        @{ Mode = 'real run'; Dry = $false }
        @{ Mode = 'dry run'; Dry = $true }
    ) {
        $script:SweeprDryRunMode = $Dry
        $one = New-File (P $script:Target 'a.txt') 10
        $root = New-Tree 'Temp' @('b.txt', 'nested/c.txt')
        $logs = New-Dir (P $script:Target 'Logs')
        $old = New-File (P $logs 'old.log') 10
        [System.IO.File]::SetLastWriteTime($old, (Get-Date).AddDays(-30))
        @(Remove-SwItems -Paths @($one) 6>$null).Count | Should -Be 0
        @(Clear-SwDirectoryContents -Path $root 6>$null).Count | Should -Be 0
        @(Remove-SwOldFiles -Path $logs 6>$null).Count | Should -Be 0
    }

    It 'F-31 names the description, the count and the size in the console line of Remove-SwItems' {
        $one = New-File (P $script:Target 'a.txt') 4096
        $two = New-File (P $script:Target 'b.txt') 6144
        $records = @(& { Remove-SwItems -Paths @($one, $two) -Description 'Example cache' } 6>&1)
        $text = (@($records | ForEach-Object {
                    if ($_ -is [System.Management.Automation.InformationRecord]) {
                        if ($_.MessageData -is [System.Management.Automation.HostInformationMessage]) { $_.MessageData.Message } else { [string]$_.MessageData }
                    }
                    else { [string]$_ }
                }) -join "`n")
        $text | Should -BeLike '*Example cache*'
        $text | Should -BeLike ('*' + (Format-SwByteSize -Bytes 10240) + '*')
    }
}

# ============================================================================
# Safety invariants
# ============================================================================

Describe 'Safety invariants of the removal paths' {
    BeforeAll {
        $script:SourceTokens = $null
        $script:SourceErrors = $null
        $script:SourceAst = [System.Management.Automation.Language.Parser]::ParseFile($script:FileOpsFile, [ref]$script:SourceTokens, [ref]$script:SourceErrors)
    }
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
    }
    AfterEach { Stop-Case }

    It 'S-1 asks Test-SwSafePath for an entry right before every removal in every path (<Name>)' -ForEach @(
        @{ Name = 'Remove-SwItem on a file'; Run = { $null = Remove-SwItem -Path (New-File (P $script:Target 'a.txt') 10) } }
        @{ Name = 'Remove-SwItem on a folder'; Run = { $null = Remove-SwItem -Path (New-Tree 'full' @('a.txt', 'nested/b.txt')) } }
        @{ Name = 'Remove-SwItem -Recycle'; Run = { $null = Remove-SwItem -Path (New-Tree 'full' @('a.txt')) -Recycle } }
        @{ Name = 'Remove-SwItems'; Run = { Remove-SwItems -Paths @((New-File (P $script:Target 'a.txt') 10), (New-Tree 'full' @('b.txt', 'nested/c.txt'))) } }
        @{ Name = 'Clear-SwDirectoryContents'; Run = { Clear-SwDirectoryContents -Path (New-Tree 'Temp' @('a.txt', 'nested/b.txt')) } }
        @{ Name = 'Remove-SwOldFiles'; Run = { $f = New-File (P $script:Target 'Logs' 'old.log') 10; [System.IO.File]::SetLastWriteTime($f, (Get-Date).AddDays(-30)); Remove-SwOldFiles -Path (P $script:Target 'Logs') } }
        @{ Name = 'Remove-SwDirectoryTree'; Run = { $null = Remove-SwDirectoryTree -Path (New-Tree 'full' @('a.txt', 'nested/b.txt')) } }
    ) {
        Use-TreeEntrySpy
        Mock Test-SwSafePath { $script:Events.Add('safe:' + (Fold $Path)); $true }
        Mock Move-SwItemToRecycleBin { $script:Events.Add('move:' + (Fold $Path)) }
        & $Run
        Assert-SafeBeforeEach @($script:Events)
    }

    It 'S-1 removes nothing in any path when Test-SwSafePath says no' {
        $file = New-File (P $script:Target 'a.txt') 10
        $tree = New-Tree 'full' @('b.txt', 'nested/c.txt')
        $clearRoot = New-Tree 'Temp' @('d.txt')
        $logs = New-Dir (P $script:Target 'Logs')
        $old = New-File (P $logs 'old.log') 10
        [System.IO.File]::SetLastWriteTime($old, (Get-Date).AddDays(-30))
        $before = Get-Listing $script:Work
        Mock Test-SwSafePath { $false }
        Mock Move-SwItemToRecycleBin { throw 'must not recycle' }
        $null = Remove-SwItem -Path $file
        $null = Remove-SwItem -Path $tree
        $null = Remove-SwItem -Path $tree -Recycle
        Remove-SwItems -Paths @($file, $tree)
        Clear-SwDirectoryContents -Path $clearRoot
        Remove-SwOldFiles -Path $logs
        $null = Remove-SwDirectoryTree -Path $tree
        Same-Listing (Get-Listing $script:Work) $before | Should -BeTrue
        Should -Invoke -CommandName Move-SwItemToRecycleBin -Times 0 -Exactly
    }

    It 'S-2 never removes recursively while removing trees in any path: Remove-Item gets no folder and no -Recurse' {
        $script:Seen = New-Object System.Collections.Generic.List[string]
        Mock Remove-Item {
            $target = ''
            if ($null -ne $LiteralPath) { $target = [string]@($LiteralPath)[0] } elseif ($null -ne $Path) { $target = [string]@($Path)[0] }
            $script:Seen.Add($target + '|' + [bool]$Recurse)
            & $script:RealRemoveItem @PesterBoundParameters
        }
        $null = Remove-SwItem -Path (New-Tree 'one' @('a.txt', 'nested/b.txt')) -Recurse -Force
        Remove-SwItems -Paths @((New-Tree 'two' @('c.txt', 'nested/d.txt')))
        Clear-SwDirectoryContents -Path (New-Tree 'Temp' @('e.txt', 'nested/f.txt'))
        $null = Remove-SwDirectoryTree -Path (New-Tree 'three' @('g.txt', 'nested/h.txt'))
        $script:Seen.Count | Should -BeGreaterThan 0
        foreach ($entry in $script:Seen) {
            $parts = $entry.Split('|')
            $parts[1] | Should -BeExactly 'False'
            [System.IO.Directory]::Exists($parts[0]) | Should -BeFalse
        }
    }

    It 'S-2 leaves a new entry in a folder in place: a folder is only removed empty' {
        $root = New-Tree 'full' @('a.txt')
        $tree = Get-SwSafeDirectoryTreeItems -Path $root
        New-File (P $root 'late.txt') 1 | Out-Null
        Assert-Result (Remove-SwDirectoryTree -Path $root -ValidatedTree $tree) $false 'folder with a new entry'
        Exists (P $root 'late.txt') | Should -BeTrue
    }

    It 'S-2 has no call of Remove-Item with -Recurse in the source' {
        Assert-Defined 'Remove-SwItem', 'Remove-SwDirectoryTree', 'Move-SwItemToRecycleBin'
        $names = @('Remove-Item', 'rm', 'ri', 'del', 'erase', 'rd', 'rmdir')
        $calls = @($script:SourceAst.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in $names -and
                    @($n.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -match '^(r|re|rec|recu|recur|recurs|recurse)$' }).Count -gt 0
                }, $true))
        $calls.Count | Should -Be 0
    }

    It 'S-2 has no recursive Delete call in the source' {
        Assert-Defined 'Remove-SwItem', 'Remove-SwDirectoryTree', 'Move-SwItemToRecycleBin'
        $calls = @($script:SourceAst.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Extent.Text -eq 'Delete' -and
                    $null -ne $n.Arguments -and $n.Arguments.Count -ge 2 -and $n.Arguments[1].Extent.Text -notmatch '^\$false$'
                }, $true))
        $calls.Count | Should -Be 0
        $strings = @($script:SourceAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -match 'Delete\s*\(' }, $true))
        foreach ($node in $strings) {
            $code = [regex]::Replace([regex]::Replace($node.Value, '(?s)/\*.*?\*/', ''), '//[^\r\n]*', '')
            $code | Should -Not -Match 'Delete\s*\([^)]*,\s*true\s*\)'
        }
    }

    It 'S-3 does not remove an entry below a link, in any path' {
        $target = New-Tree 'link-target' @('f.txt', 'sub/g.txt')
        $before = Get-Listing $target
        $link = P $script:Target 'link'
        New-TestLink $link $target
        $null = Remove-SwItem -Path (P $link 'f.txt')
        $null = Remove-SwItem -Path (P $link 'sub')
        Remove-SwItems -Paths @((P $link 'f.txt'), (P $link 'sub'))
        Clear-SwDirectoryContents -Path (P $link 'sub')
        Remove-SwOldFiles -Path $link -DaysOld 0
        Same-Listing (Get-Listing $target) $before | Should -BeTrue
    }

    It 'S-3 does not list a link as a source for a size or for a tree of a folder that is removed' {
        $target = New-Tree 'link-target' @('big.bin=4000')
        $root = New-Tree 'full' @('own.bin=100')
        $link = P $root 'link'
        New-TestLink $link $target
        $tree = Get-SwSafeDirectoryTreeItems -Path $root
        $tree['Success'] | Should -BeTrue
        (Get-SwValidatedTreeSize -Tree $tree) | Should -Be 100
        @($tree['Items'] | Where-Object { (Fold $_.FullName).StartsWith((Fold $link) + '\') }).Count | Should -Be 0
    }

    It 'S-3 [W] removes a link inside a folder as a link and never the target (<Path>)' -ForEach @(
        @{ Path = 'Remove-SwItem' }
        @{ Path = 'Remove-SwItems' }
        @{ Path = 'Remove-SwDirectoryTree' }
    ) {
        $target = New-Tree 'link-target' @('keep.txt', 'nested/deep.txt')
        $before = Get-Listing $target
        $root = New-Tree 'full' @('own.txt')
        New-TestLink (P $root 'lnk') $target
        switch ($Path) {
            'Remove-SwItem' { Assert-Result (Remove-SwItem -Path $root) $true 'folder with a link' }
            'Remove-SwItems' { Remove-SwItems -Paths @($root) }
            'Remove-SwDirectoryTree' { Assert-Result (Remove-SwDirectoryTree -Path $root) $true 'folder with a link' }
        }
        Exists $root | Should -BeFalse
        Same-Listing (Get-Listing $target) $before | Should -BeTrue
    }

    It 'S-4 removes nothing when the identity changed during the measurement (<Path>)' -ForEach @(
        @{ Path = 'Remove-SwItem' }
        @{ Path = 'Remove-SwItems' }
    ) {
        $file = New-File (P $script:Target 'a.txt') 10
        $script:Swap = $file
        Mock Get-SwPathSize { $script:FakeIdentity[$script:Swap] = 'replaced'; 10 }
        if ($Path -eq 'Remove-SwItem') { $null = Remove-SwItem -Path $file } else { Remove-SwItems -Paths @($file) }
        Exists $file | Should -BeTrue
        $script:Ops.Count | Should -Be 0
    }

    It 'S-4 removes nothing when the identity changed while the condition was evaluated (<Path>)' -ForEach @(
        @{ Path = 'Remove-SwItem' }
        @{ Path = 'Remove-SwItems' }
    ) {
        $file = New-File (P $script:Target 'a.txt') 10
        $script:Swap = $file
        $change = { $script:FakeIdentity[$script:Swap] = 'replaced'; $true }
        if ($Path -eq 'Remove-SwItem') { $null = Remove-SwItem -Path $file -Guard $change } else { Remove-SwItems -Paths @($file) -CanRemove $change }
        Exists $file | Should -BeTrue
        $script:Ops.Count | Should -Be 0
    }

    It 'S-4 stops a tree removal at an entry whose identity changed after the validation, and keeps it' {
        $root = New-Tree 'full' @('long-name-removed-first.txt', 'second.txt')
        $tree = Get-SwSafeDirectoryTreeItems -Path $root
        Use-TreeEntrySpy
        $script:SecondPath = P $root 'second.txt'
        $script:BeforeRemove = { param($p) $script:FakeIdentity[$script:SecondPath] = 'replaced' }
        $report = @{}
        Assert-Result (Remove-SwDirectoryTree -Path $root -ValidatedTree $tree -Report $report) $false 'changed entry'
        Exists $script:SecondPath | Should -BeTrue
        Exists (P $root 'long-name-removed-first.txt') | Should -BeFalse
        Assert-Stopped ([string]$report['Reason']) $script:SecondPath '*'
    }

    It 'S-4 removes nothing without a bindable identity in any path' {
        $file = New-File (P $script:Target 'a.txt') 10
        $tree = New-Tree 'full' @('b.txt')
        $clearRoot = New-Tree 'Temp' @('c.txt')
        $logs = New-Dir (P $script:Target 'Logs')
        $old = New-File (P $logs 'old.log') 10
        [System.IO.File]::SetLastWriteTime($old, (Get-Date).AddDays(-30))
        Mock Get-SwPathSnapshot { $null }
        Mock Test-SwPathSnapshot { $false }
        $before = Get-Listing $script:Work
        Assert-Result (Remove-SwItem -Path $file) $false 'file'
        Assert-Result (Remove-SwItem -Path $tree) $false 'folder'
        Remove-SwItems -Paths @($file, $tree)
        Clear-SwDirectoryContents -Path $clearRoot
        Remove-SwOldFiles -Path $logs
        Same-Listing (Get-Listing $script:Work) $before | Should -BeTrue
        $script:Ops.Count | Should -Be 0
    }

    It 'S-7 never removes anything permanently on the Recycle Bin path when the shell fails: nothing is deleted by another route' {
        $root = New-Tree 'full' @('fixture.txt=5000', 'nested/b.txt=100')
        $before = Get-Listing $root
        Mock Move-SwItemToRecycleBin { throw 'Recycle Bin unavailable' }
        Mock Write-Warning { }
        Mock Remove-Item { throw 'no permanent deletion' }
        Mock Remove-SwTreeEntry { throw 'no permanent deletion' }
        Mock Remove-SwDirectoryTree { throw 'no permanent deletion' }
        Assert-Result (Remove-SwItem -Path $root -Recycle -Recurse -Force) $false 'shell failure'
        Same-Listing (Get-Listing $root) $before | Should -BeTrue
        Should -Invoke -CommandName Remove-Item -Times 0 -Exactly
        Should -Invoke -CommandName Remove-SwTreeEntry -Times 0 -Exactly
        Should -Invoke -CommandName Remove-SwDirectoryTree -Times 0 -Exactly
    }

    It 'S-7 [L] Move-SwItemToRecycleBin throws and leaves the folder when the identity test fails' {
        $root = New-Tree 'full' @('fixture.txt=5000')
        $before = Get-Listing $root
        $snapshot = [pscustomobject]@{ Path = $root; Identity = 'x'; AllowLeafLink = $false }
        Mock Test-SwPathSnapshot { $false }
        $null = Assert-Throws { Move-SwItemToRecycleBin -Path $root -Snapshot $snapshot }
        Same-Listing (Get-Listing $root) $before | Should -BeTrue
    }

    It 'S-7 [L] Move-SwItemToRecycleBin throws and leaves the folder when the entry is no longer safe' {
        $root = New-Tree 'full' @('fixture.txt=5000')
        $before = Get-Listing $root
        $snapshot = [pscustomobject]@{ Path = $root; Identity = 'x'; AllowLeafLink = $false }
        Mock Test-SwSafePath { $false }
        $null = Assert-Throws { Move-SwItemToRecycleBin -Path $root -Snapshot $snapshot }
        Same-Listing (Get-Listing $root) $before | Should -BeTrue
    }

    It 'S-7 [L] Move-SwItemToRecycleBin throws and leaves the folder when a protected entry is inside' {
        $root = New-Tree 'full' @('fixture.txt=5000', 'keep.txt')
        Set-Whitelist @((P $root 'keep.txt'))
        $before = Get-Listing $root
        $snapshot = Get-SwPathSnapshot -Path $root
        $null = Assert-Throws { Move-SwItemToRecycleBin -Path $root -Snapshot $snapshot }
        Same-Listing (Get-Listing $root) $before | Should -BeTrue
    }

    It 'S-7 [L] Move-SwItemToRecycleBin throws for a snapshot that is $null or has no path, and removes nothing' {
        $root = New-Tree 'full' @('fixture.txt=5000')
        $before = Get-Listing $root
        $null = Assert-Throws { Move-SwItemToRecycleBin -Path $root -Snapshot $null }
        $null = Assert-Throws { Move-SwItemToRecycleBin -Path $root -Snapshot ([pscustomobject]@{}) }
        Same-Listing (Get-Listing $root) $before | Should -BeTrue
    }

    It 'S-7 does not use a shell route that deletes permanently or asks (source scan)' {
        Assert-Defined 'Remove-SwItem', 'Remove-SwDirectoryTree', 'Move-SwItemToRecycleBin'
        $pattern = 'SHFileOperation|FOF_ALLOWUNDO|SHFILEOPSTRUCT|IFileOperation|\bDeleteItem\b|VisualBasic|RecycleOption'
        $strings = @($script:SourceAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true))
        foreach ($node in $strings) {
            $code = [regex]::Replace([regex]::Replace([string]$node.Value, '(?s)/\*.*?\*/', ''), '//[^\r\n]*', '')
            $code | Should -Not -Match $pattern
        }
        $others = @($script:SourceAst.FindAll({ param($n)
                    ($n -is [System.Management.Automation.Language.TypeExpressionAst] -or $n -is [System.Management.Automation.Language.TypeConstraintAst] -or $n -is [System.Management.Automation.Language.CommandAst]) -and
                    $n.Extent.Text -match $pattern
                }, $true))
        $others.Count | Should -Be 0
    }

    It 'S-8 gives a binding error for an empty path and false for unclear ones, and removes nothing' {
        $failure = Assert-Throws { Remove-SwItem -Path '' }
        $failure.Exception | Should -BeOfType [System.Management.Automation.ParameterBindingException]
        $file = New-File (P $script:Target 'a.txt') 10
        foreach ($path in @('   ', 'relative.txt', 'HKCU:\Software\SweeprTestDoesNotExist', 'Env:SWEEPR_TEST_PROVIDER_VARIABLE')) {
            Assert-Result (Remove-SwItem -Path $path) $false $path
        }
        Exists $file | Should -BeTrue
    }

    It 'S-8 removes nothing in any path when it cannot decide (<Label>)' -ForEach @(
        @{ Label = 'the whitelist cannot be read'; Break = 'whitelist' }
        @{ Label = 'the protection question throws'; Break = 'protection' }
        @{ Label = 'the whitelist state cannot be built'; Break = 'state' }
        @{ Label = 'the whitelist question throws'; Break = 'whitelisted' }
        @{ Label = 'the final spelling cannot be found'; Break = 'resolve' }
        @{ Label = 'the identity function throws'; Break = 'snapshot' }
        @{ Label = 'the identity test throws'; Break = 'identity' }
        @{ Label = 'the safety question gives no answer'; Break = 'nosafe' }
    ) {
        $file = New-File (P $script:Target 'a.txt') 10
        $tree = New-Tree 'full' @('b.txt', 'nested/c.txt')
        $clearRoot = New-Tree 'Temp' @('d.txt')
        $logs = New-Dir (P $script:Target 'Logs')
        $old = New-File (P $logs 'old.log') 10
        [System.IO.File]::SetLastWriteTime($old, (Get-Date).AddDays(-30))
        switch ($Break) {
            'whitelist' { New-Dir $script:Config.WhitelistFile | Out-Null }
            'protection' { Mock Test-SwProtectedPath { throw 'protection-canary' } }
            'state' { Mock Get-SwWhitelistState { throw 'state-canary' } }
            'whitelisted' { Mock Test-SwWhitelisted { throw 'whitelist-canary' } }
            'resolve' { Mock Resolve-SwSafePath { $null } }
            'snapshot' { Mock Get-SwPathSnapshot { throw 'snapshot-canary' } }
            'identity' { Mock Test-SwPathSnapshot { throw 'identity-canary' } }
            'nosafe' { Mock Test-SwSafePath { } }
        }
        $before = Get-Listing $script:Work
        Assert-Result (Get-Result { Remove-SwItem -Path $file }) $false $Label
        Assert-Result (Get-Result { Remove-SwItem -Path $tree }) $false $Label
        Get-Result { Remove-SwItems -Paths @($file, $tree) }
        Get-Result { Clear-SwDirectoryContents -Path $clearRoot }
        Get-Result { Remove-SwOldFiles -Path $logs }
        Same-Listing (Get-Listing $script:Work) $before | Should -BeTrue
    }

    It 'S-9 removes nothing when a descendant is protected or whitelisted, however deep (<Kind>)' -ForEach @(
        @{ Kind = 'protected by path'; Mode = 'protected' }
        @{ Kind = 'whitelisted'; Mode = 'whitelisted' }
    ) {
        $root = New-Tree 'full' @('a.txt', 'nested/b.txt', 'nested/deeper/secret/s.txt', 'z.txt')
        $inner = P $root 'nested' 'deeper' 'secret'
        if ($Mode -eq 'protected') { $script:ProtectedPaths = @($inner) } else { Set-Whitelist @($inner) }
        $before = Get-Listing $root
        Assert-Result (Remove-SwItem -Path $root) $false 'Remove-SwItem'
        Remove-SwItems -Paths @($root)
        Assert-Result (Remove-SwDirectoryTree -Path $root) $false 'Remove-SwDirectoryTree'
        Same-Listing (Get-Listing $root) $before | Should -BeTrue
        Clear-SwDirectoryContents -Path (Split-Path -Parent $root)
        Same-Listing (Get-Listing $root) $before | Should -BeTrue
    }

    It 'S-11 stops a tree removal at the first failure and counts nothing that was not removed completely (<Path>)' -ForEach @(
        @{ Path = 'Remove-SwItem' }
        @{ Path = 'Remove-SwItems' }
    ) {
        $root = New-Tree 'full' @('aaaaaaaa.txt', 'bbbbbbbb.txt', 'lock.txt')
        Use-TreeEntrySpy
        $script:FailOn = P $root 'lock.txt'
        if ($Path -eq 'Remove-SwItem') { $null = Remove-SwItem -Path $root } else { Remove-SwItems -Paths @($root) }
        @($script:Events | Where-Object { $_.StartsWith('remove:') }).Count | Should -Be 3
        $script:FilesCleaned | Should -Be 0
        $script:TotalItems | Should -Be 0
        $script:TotalSizeCleaned | Should -Be 0
        @($script:Ops | ForEach-Object { $_.Action }) | Should -Be @('FAILED')
    }

    It 'S-12 removes only files directly in the folder and strictly older than the cut-off: no folder, no recursion, nothing for a negative age' {
        $root = New-Dir (P $script:Target 'Logs')
        $fixed = [datetime]'2026-01-10T12:00:00'
        $script:FixedNow = $fixed
        Mock Get-Date { $script:FixedNow }
        $old = New-File (P $root 'old.txt') 10
        $oldFolder = New-Dir (P $root 'old-folder')
        $inner = New-File (P $oldFolder 'inner.txt') 10
        $young = New-File (P $root 'young.txt') 10
        foreach ($entry in @($old, $inner)) { [System.IO.File]::SetLastWriteTime($entry, $fixed.AddDays(-30)) }
        [System.IO.Directory]::SetLastWriteTime($oldFolder, $fixed.AddDays(-30))
        [System.IO.File]::SetLastWriteTime($young, $fixed.AddDays(-1))
        Remove-SwOldFiles -Path $root -DaysOld -5
        Exists $old | Should -BeTrue
        Remove-SwOldFiles -Path $root -DaysOld 7
        Exists $old | Should -BeFalse
        Exists $oldFolder | Should -BeTrue
        Exists $inner | Should -BeTrue
        Exists $young | Should -BeTrue
    }

    It 'S-13 does not remove or preview when the condition gives two true values, in every function that takes one' {
        $two = { $true; $true }
        $file = New-File (P $script:Target 'a.txt') 10
        $tree = New-Tree 'full' @('b.txt')
        $clearRoot = New-Tree 'Temp' @('c.txt')
        foreach ($dry in @($false, $true)) {
            $script:SweeprDryRunMode = $dry
            Assert-Result (Remove-SwItem -Path $file -Guard $two) $false "Remove-SwItem, dry run $dry"
            Remove-SwItems -Paths @($file, $tree) -CanRemove $two
            Clear-SwDirectoryContents -Path $clearRoot -CanRemove $two
            $report = @{}
            Assert-Result (Remove-SwDirectoryTree -Path $tree -Report $report -CanRemove $two) $false "Remove-SwDirectoryTree, dry run $dry"
        }
        Exists $file | Should -BeTrue
        Exists (P $tree 'b.txt') | Should -BeTrue
        Exists (P $clearRoot 'c.txt') | Should -BeTrue
        $script:FilesCleaned | Should -Be 0
        $script:DrySaid.Count | Should -Be 0
    }

    It 'S-13 asks the condition only for paths that passed the safety checks, and also in a dry run' {
        $protectedFile = New-File (P $script:Prot 'p.txt') 10
        $file = New-File (P $script:Target 'a.txt') 10
        $script:Probe = 0
        $script:SweeprDryRunMode = $true
        Remove-SwItems -Paths @($protectedFile, $file) -CanRemove { $script:Probe++; $true }
        $script:Probe | Should -Be 1
        $null = Remove-SwItem -Path $protectedFile -Guard { $script:Probe++; $true }
        $script:Probe | Should -Be 1
        $null = Remove-SwItem -Path $file -Guard { $script:Probe++; $true }
        $script:Probe | Should -Be 2
    }

    It 'S-14 never removes the data folders of Sweepr (<Mode>)' -ForEach @(
        @{ Mode = 'real run'; Dry = $false }
        @{ Mode = 'dry run'; Dry = $true }
    ) {
        $temp = New-Dir (P $script:Work 'Temp')
        $configPath = P $temp 'sweepr' 'config'
        $cachePath = P $temp 'sweepr' 'cache'
        $script:Config = @{ ConfigPath = $configPath; CachePath = $cachePath; WhitelistFile = (P $configPath 'whitelist.txt') }
        New-File (P $configPath 'settings.json') 10 | Out-Null
        New-File (P $cachePath 'blob.bin') 10 | Out-Null
        $junk = New-File (P $temp 'junk.tmp') 10
        $before = Get-Listing $temp
        $script:SweeprDryRunMode = $Dry
        Assert-Result (Remove-SwItem -Path $configPath) $false 'config folder'
        Assert-Result (Remove-SwItem -Path $cachePath) $false 'cache folder'
        Assert-Result (Remove-SwItem -Path (P $temp 'sweepr')) $false 'parent of both'
        Remove-SwItems -Paths @($configPath, $cachePath, (P $temp 'sweepr'))
        Clear-SwDirectoryContents -Path $configPath
        Clear-SwDirectoryContents -Path $cachePath
        Same-Listing (Get-Listing $temp) $before | Should -BeTrue
        @($script:Ops | Where-Object { $_.Action -ne 'SKIPPED' }).Count | Should -Be 0 -Because 'the parent holds protected entries and is only refused, in a real run with SKIPPED'
    }

    It 'S-14 leaves the data folders in place when the folder above them is cleared, and removes the rest' {
        $temp = New-Dir (P $script:Work 'Temp')
        $configPath = P $temp 'sweepr' 'config'
        $cachePath = P $temp 'sweepr' 'cache'
        $script:Config = @{ ConfigPath = $configPath; CachePath = $cachePath; WhitelistFile = (P $configPath 'whitelist.txt') }
        New-File (P $configPath 'settings.json') 10 | Out-Null
        New-File (P $cachePath 'blob.bin') 10 | Out-Null
        $junk = New-File (P $temp 'junk.tmp') 10
        Clear-SwDirectoryContents -Path $temp
        Exists (P $configPath 'settings.json') | Should -BeTrue
        Exists (P $cachePath 'blob.bin') | Should -BeTrue
        Exists $junk | Should -BeFalse
        @($script:Ops | Where-Object { $_.Action -eq 'SKIPPED' }).Count | Should -Be 1
    }

    It 'S-14 [W] never removes a file inside the data folders' {
        $temp = New-Dir (P $script:Work 'Temp')
        $configPath = P $temp 'sweepr' 'config'
        $script:Config = @{ ConfigPath = $configPath; CachePath = (P $temp 'sweepr' 'cache'); WhitelistFile = (P $configPath 'whitelist.txt') }
        $settings = New-File (P $configPath 'settings.json') 10
        Assert-Result (Remove-SwItem -Path $settings) $false 'file inside the config folder'
        Remove-SwItems -Paths @($settings)
        Exists $settings | Should -BeTrue
    }

    It 'S-15 removes only the entry with <Label> in its name, never a neighbor that a wildcard reading would match (<Function>)' -ForEach @(
        @{ Label = 'brackets'; Name = 'Cache [1]'; Function = 'Remove-SwItem' }
        @{ Label = 'brackets'; Name = 'Cache [1]'; Function = 'Remove-SwItems' }
        @{ Label = 'brackets'; Name = 'Cache [1]'; Function = 'Clear-SwDirectoryContents' }
        @{ Label = 'brackets'; Name = 'Cache [1]'; Function = 'Remove-SwOldFiles' }
        @{ Label = 'a backtick'; Name = ('Cache' + [char]96 + '1'); Function = 'Remove-SwItems' }
        @{ Label = 'a closing bracket'; Name = 'Cache]'; Function = 'Remove-SwItems' }
    ) {
        $decoy = New-Tree 'Cache 1' @('decoy.txt')
        $named = New-Tree $Name @('mine.txt')
        $old = [datetime]'2020-01-01T00:00:00'
        [System.IO.File]::SetLastWriteTime((P $named 'mine.txt'), $old)
        [System.IO.File]::SetLastWriteTime((P $decoy 'decoy.txt'), $old)
        switch ($Function) {
            'Remove-SwItem' { $null = Remove-SwItem -Path $named }
            'Remove-SwItems' { Remove-SwItems -Paths @($named) }
            'Clear-SwDirectoryContents' { Clear-SwDirectoryContents -Path $named }
            'Remove-SwOldFiles' { Remove-SwOldFiles -Path $named -DaysOld 7 }
        }
        Exists (P $decoy 'decoy.txt') | Should -BeTrue
        Exists (P $named 'mine.txt') | Should -BeFalse
    }

    It 'S-15 does not read a pattern as a path: nothing goes for <Pattern>' -ForEach @(
        @{ Pattern = '*' }
        @{ Pattern = '*.txt' }
        @{ Pattern = 'a?.txt' }
        @{ Pattern = '[ab].txt' }
        @{ Pattern = 'Cache [*]' }
    ) {
        $root = New-Tree 'Temp' @('a.txt', 'b.txt', 'ab.txt', 'Cache 1/x.txt')
        $before = Get-Listing $root
        $full = P $root $Pattern
        Assert-Result (Remove-SwItem -Path $full) $false 'Remove-SwItem'
        Remove-SwItems -Paths @($full)
        Clear-SwDirectoryContents -Path $full
        Remove-SwOldFiles -Path $full -DaysOld 0
        Same-Listing (Get-Listing $root) $before | Should -BeTrue
    }

    It 'S-15 removes a file whose name contains * or ? and not its neighbors (not on Windows, where such names do not exist)' {
        if ($script:OnWindows) { Set-ItResult -Skipped -Because 'Windows does not allow * or ? in a file name'; return }
        $star = New-File (P $script:Target 'a*b.txt') 10
        $question = New-File (P $script:Target 'a?c.txt') 10
        $neighbors = @((New-File (P $script:Target 'aXb.txt') 10), (New-File (P $script:Target 'aXc.txt') 10), (New-File (P $script:Target 'ab.txt') 10))
        Remove-SwItems -Paths @($star, $question)
        Exists $star | Should -BeFalse
        Exists $question | Should -BeFalse
        foreach ($neighbor in $neighbors) { Exists $neighbor | Should -BeTrue }
    }

    It 'S-15 removes entries whose names contain <Label>, and only those' -ForEach $script:OddNames {
        $decoy = New-File (P $script:Target 'decoy.txt') 10
        $file = New-File (P $script:Target ($Name + '.txt')) 10
        $folder = New-Tree ($Name + ' folder') @('x.txt', 'nested/y.txt')
        Remove-SwItems -Paths @($file, $folder)
        Exists $file | Should -BeFalse
        Exists $folder | Should -BeFalse
        Exists $decoy | Should -BeTrue
        $again = New-File (P $script:Target ($Name + '-b.txt')) 10
        Assert-Result (Remove-SwItem -Path $again) $true 'Remove-SwItem'
        Exists $again | Should -BeFalse
    }

    It 'S-16 touches neither registry nor services nor processes nor the network in any removal path' {
        foreach ($name in 'Start-Process', 'Invoke-WebRequest', 'Invoke-RestMethod', 'Get-ItemProperty', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Stop-Process', 'Start-Job') {
            Mock -CommandName $name -MockWith { throw 'must not be called' }
        }
        $file = New-File (P $script:Target 'a.txt') 10
        $tree = New-Tree 'full' @('b.txt', 'nested/c.txt')
        $clearRoot = New-Tree 'Temp' @('d.txt')
        $logs = New-Dir (P $script:Target 'Logs')
        $old = New-File (P $logs 'old.log') 10
        [System.IO.File]::SetLastWriteTime($old, (Get-Date).AddDays(-30))
        Mock Move-SwItemToRecycleBin { }
        foreach ($dry in @($true, $false)) {
            $script:SweeprDryRunMode = $dry
            $null = Remove-SwItem -Path $file
            $null = Remove-SwItem -Path $tree -Recycle
            Remove-SwItems -Paths @($file, $tree)
            Clear-SwDirectoryContents -Path $clearRoot
            Remove-SwOldFiles -Path $logs
        }
        foreach ($name in 'Start-Process', 'Invoke-WebRequest', 'Invoke-RestMethod', 'Get-ItemProperty', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Stop-Process', 'Start-Job') {
            Should -Invoke -CommandName $name -Times 0 -Exactly
        }
    }

    It 'S-16 rejects a path outside the file system in every path and leaves what it names' {
        Set-Env 'SWEEPR_TEST_PROVIDER_VARIABLE' 'present'
        $path = 'Env:SWEEPR_TEST_PROVIDER_VARIABLE'
        Assert-Result (Remove-SwItem -Path $path) $false 'Remove-SwItem'
        Remove-SwItems -Paths @($path)
        Clear-SwDirectoryContents -Path 'Env:'
        Remove-SwOldFiles -Path 'Env:' -DaysOld 0
        [System.Environment]::GetEnvironmentVariable('SWEEPR_TEST_PROVIDER_VARIABLE') | Should -BeExactly 'present'
    }

    It 'S-17 lets no exception out after something was removed (<Cause>)' -ForEach @(
        @{ Cause = 'the writer throws'; Mode = 'writer' }
        @{ Cause = 'the writer and the debug output throw'; Mode = 'writer-debug' }
        @{ Cause = 'the success line throws'; Mode = 'success' }
        @{ Cause = 'the preview line throws'; Mode = 'dryrun' }
        @{ Cause = 'the section activity throws'; Mode = 'activity' }
        @{ Cause = 'the list entries throw'; Mode = 'list' }
    ) {
        switch ($Mode) {
            'writer' { Mock Write-SweeprOperation { throw 'writer-canary' } }
            'writer-debug' { Mock Write-SweeprOperation { throw 'writer-canary' }; Mock Write-Debug { throw 'debug-canary' } }
            'success' { Mock Write-Success { throw 'success-canary' } }
            'dryrun' { Mock Write-DryRun { throw 'dryrun-canary' } }
            'activity' { Mock Set-SectionActivity { throw 'activity-canary' } }
            'list' { Mock Add-SwDryRunListEntries { throw 'list-canary' } }
        }
        $file = New-File (P $script:Target 'a.txt') 10
        $tree = New-Tree 'full' @('b.txt', 'nested/c.txt')
        $clearRoot = New-Tree 'Temp' @('d.txt')
        $logs = New-Dir (P $script:Target 'Logs')
        $old = New-File (P $logs 'old.log') 10
        [System.IO.File]::SetLastWriteTime($old, (Get-Date).AddDays(-30))
        foreach ($dry in @($false, $true)) {
            $script:SweeprDryRunMode = $dry
            Get-Result { $null = Remove-SwItem -Path $file }
            Get-Result { $null = Remove-SwItem -Path $tree }
            Get-Result { Remove-SwItems -Paths @($file, $tree) }
            Get-Result { Clear-SwDirectoryContents -Path $clearRoot }
            Get-Result { Remove-SwOldFiles -Path $logs }
        }
        Exists $file | Should -BeFalse -Because 'what was removed stays removed'
    }

    It 'S-17 lets no exception out when a removal fails halfway through a tree (<Path>)' -ForEach @(
        @{ Path = 'Remove-SwItem' }
        @{ Path = 'Remove-SwItems' }
        @{ Path = 'Clear-SwDirectoryContents' }
        @{ Path = 'Remove-SwDirectoryTree' }
    ) {
        $root = New-Tree 'full' @('aaaaaaaa.txt', 'bbbbbbbb.txt', 'lock.txt')
        Use-TreeEntrySpy
        $script:FailOn = P $root 'lock.txt'
        switch ($Path) {
            'Remove-SwItem' { Get-Result { $null = Remove-SwItem -Path $root } }
            'Remove-SwItems' { Get-Result { Remove-SwItems -Paths @($root) } }
            'Clear-SwDirectoryContents' { Get-Result { Clear-SwDirectoryContents -Path $script:Work } }
            'Remove-SwDirectoryTree' { Get-Result { $null = Remove-SwDirectoryTree -Path $root } }
        }
        Exists (P $root 'lock.txt') | Should -BeTrue
    }
}

Describe 'Removal on a host without a Windows file API' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -RealIdentity
    }
    AfterEach { Stop-Case }

    It 'S-4 [L] removes nothing in any removal path, because no identity can be bound' {
        if ($script:OnWindows) { Set-ItResult -Skipped -Because 'this host has the Windows file API'; return }
        $file = New-File (P $script:Target 'a.txt') 10
        $tree = New-Tree 'full' @('b.txt', 'nested/c.txt')
        $clearRoot = New-Tree 'Temp' @('d.txt')
        $logs = New-Dir (P $script:Target 'Logs')
        $old = New-File (P $logs 'old.log') 10
        [System.IO.File]::SetLastWriteTime($old, (Get-Date).AddDays(-30))
        $before = Get-Listing $script:Work
        Assert-Result (Remove-SwItem -Path $file) $false 'file'
        Assert-Result (Remove-SwItem -Path $tree) $false 'folder'
        Remove-SwItems -Paths @($file, $tree)
        Clear-SwDirectoryContents -Path $clearRoot
        Remove-SwOldFiles -Path $logs
        Assert-Result (Remove-SwDirectoryTree -Path $tree) $false 'Remove-SwDirectoryTree'
        Same-Listing (Get-Listing $script:Work) $before | Should -BeTrue
        $script:Ops.Count | Should -Be 0
    }
}

Describe 'Interface of the removal functions' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
    }

    It 'E36 offers <Name> as a function with exactly the documented parameters' -ForEach $script:Interface {
        $command = Get-Command -Name $Name -CommandType Function -ErrorAction Stop
        $common = [System.Management.Automation.Cmdlet]::CommonParameters + [System.Management.Automation.Cmdlet]::OptionalCommonParameters
        $declared = @($command.Parameters.Keys | Where-Object { $_ -notin $common } | Sort-Object)
        ($declared -join ',') | Should -BeExactly ((@($Parameters) | Sort-Object) -join ',')
        foreach ($parameter in $Parameters) {
            $attribute = $command.Parameters[$parameter].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | Select-Object -First 1
            $mandatory = ($null -ne $attribute -and [bool]$attribute.Mandatory)
            if ($parameter -in @($Mandatory)) { $mandatory | Should -BeTrue -Because "-$parameter is mandatory" }
        }
        if ($Position0) {
            $attribute = $command.Parameters[$Position0].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | Select-Object -First 1
            $attribute.Position | Should -Be 0 -Because "-$Position0 is the first positional parameter"
        }
    }

    It 'E36 gives the removal functions the documented types and default values' {
        $item = Get-Command Remove-SwItem
        foreach ($name in 'Force', 'Recurse', 'Recycle') { $item.Parameters[$name].ParameterType | Should -Be ([System.Management.Automation.SwitchParameter]) }
        $item.Parameters['Guard'].ParameterType | Should -Be ([scriptblock])
        (Get-Command Remove-SwItems).Parameters['Paths'].ParameterType | Should -Be ([string[]])
        (Get-Command Remove-SwItems).Parameters['CanRemove'].ParameterType | Should -Be ([scriptblock])
        (Get-Command Remove-SwOldFiles).Parameters['DaysOld'].ParameterType | Should -Be ([int])
        (Get-Command Add-SwDryRunListEntries).Parameters['SizeBytes'].ParameterType | Should -Be ([long[]])
        (Get-Command Add-SwDryRunListEntries).Parameters['FileCounts'].ParameterType | Should -Be ([int[]])
        (Get-Command Set-SwDryRunMode).Parameters['Enabled'].ParameterType | Should -Be ([bool])
        (Get-Command Remove-SwDirectoryTree).Parameters['ValidatedTree'].ParameterType | Should -Be ([hashtable])
        (Get-Command Remove-SwDirectoryTree).Parameters['Report'].ParameterType | Should -Be ([hashtable])
    }

    It 'E36 gives the optional parameters their documented default values' {
        $defaults = @{}
        foreach ($name in 'Remove-SwItem', 'Remove-SwItems', 'Remove-SwOldFiles', 'Clear-SwDirectoryContents', 'Set-SwDryRunMode') {
            $ast = (Get-Command $name).ScriptBlock.Ast
            $parameters = @()
            if ($ast -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                if ($ast.Parameters) { $parameters = @($ast.Parameters) } elseif ($ast.Body.ParamBlock) { $parameters = @($ast.Body.ParamBlock.Parameters) }
            }
            foreach ($parameter in $parameters) {
                if ($null -ne $parameter.DefaultValue) { $defaults[$name + '.' + $parameter.Name.VariablePath.UserPath] = $parameter.DefaultValue.Extent.Text.Trim('''', '"') }
            }
        }
        $defaults['Remove-SwItem.Description'] | Should -BeExactly ''
        $defaults['Remove-SwItems.Description'] | Should -BeExactly 'Items'
        $defaults['Remove-SwOldFiles.DaysOld'] | Should -BeExactly '7'
        $defaults['Remove-SwOldFiles.Filter'] | Should -BeExactly '*'
        $defaults['Remove-SwOldFiles.Description'] | Should -BeExactly 'Old files'
        $defaults['Clear-SwDirectoryContents.Description'] | Should -BeExactly ''
        $defaults['Set-SwDryRunMode.Enabled'] | Should -BeExactly '$false'
    }
}

# ============================================================================
# Old names (forwarding functions) of the removal half
# ============================================================================

Describe 'Transition names of the removal functions' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
    }
    AfterEach { Stop-Case }

    It 'Keeps <Old> as a function, not an alias' -ForEach $script:Forwarders {
        (Get-Command -Name $Old -ErrorAction Stop).CommandType | Should -Be 'Function'
        Get-Alias -Name $Old -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        (Get-Command -Name $New -ErrorAction Stop).CommandType | Should -Be 'Function'
    }

    It 'Gives <Old> the same parameters as <New> (names, types, positions, mandatory flags, defaults)' -ForEach $script:Forwarders {
        $old = Get-ParamSignature $Old
        $new = Get-ParamSignature $New
        (@($old) -join "`n") | Should -BeExactly (@($new) -join "`n")
    }

    It 'Forwards <Old> to <New> with the same arguments' -ForEach $script:Forwarders {
        Mock -CommandName $New -MockWith { 'forwarded' }
        $result = & $Invoke
        if ($Pass) { $result | Should -Be 'forwarded' }
        Should -Invoke -CommandName $New -Times 1 -Exactly -ParameterFilter $Filter
    }

    It 'Remove-SafeItem removes and previews like Remove-SwItem' {
        $one = New-File (P $script:Target 'a.txt') 10
        $two = New-File (P $script:Target 'b.txt') 10
        Assert-Result (Remove-SafeItem -Path $one -Description 'Old name') $true 'removal'
        Exists $one | Should -BeFalse
        $script:SweeprDryRunMode = $true
        Assert-Result (Remove-SafeItem -Path $two -Force -Recurse) $true 'preview'
        Exists $two | Should -BeTrue
        Assert-Result (Remove-SafeItem -Path $two -Guard { $false }) $false 'guard'
    }

    It 'Remove-SafeItems, Clear-DirectoryContents and Remove-OldFiles act like their new names' {
        $file = New-File (P $script:Target 'a.txt') 10
        $root = New-Tree 'Temp' @('b.txt', 'nested/c.txt')
        $logs = New-Dir (P $script:Target 'Logs')
        $old = New-File (P $logs 'old.log') 10
        [System.IO.File]::SetLastWriteTime($old, (Get-Date).AddDays(-30))
        Remove-SafeItems -Paths @($file) -Description 'Old name'
        Clear-DirectoryContents -Path $root
        Remove-OldFiles -Path $logs -DaysOld 7 -Filter '*.log'
        Exists $file | Should -BeFalse
        @(Get-ChildItem -LiteralPath $root -Force).Count | Should -Be 0
        Exists $old | Should -BeFalse
    }

    It 'Remove-SafeDirectoryTree, Remove-TreeEntry and Move-SweeprItemToRecycleBin act like their new names' {
        $root = New-Tree 'full' @('a.txt', 'nested/b.txt')
        $report = @{}
        Assert-Result (Remove-SafeDirectoryTree -Path $root -Report $report) $true 'tree'
        $report['Removed'] | Should -Be 3
        Exists $root | Should -BeFalse
        $file = New-File (P $script:Target 'a.txt') 10
        Remove-TreeEntry -Path $file
        Exists $file | Should -BeFalse
        $dir = New-Tree 'recycle-me' @('a.txt')
        Mock Test-SwPathSnapshot { $false }
        $null = Assert-Throws { Move-SweeprItemToRecycleBin -Path $dir -Snapshot ([pscustomobject]@{ Path = $dir }) }
        Exists (P $dir 'a.txt') | Should -BeTrue
    }

    It 'Get-CleanupStats, Reset-CleanupStats, Set-DryRunMode, Test-DryRunMode and Add-DryRunListEntries act like their new names' {
        $script:TotalSizeCleaned = 3
        $script:FilesCleaned = 2
        (Get-CleanupStats)['TotalSizeKB'] | Should -Be 3
        Reset-CleanupStats
        (Get-CleanupStats)['FilesCleaned'] | Should -Be 0
        Set-DryRunMode $true
        Assert-Result (Test-DryRunMode) $true 'enabled'
        Assert-Result (Test-SwDryRunMode) $true 'new name agrees'
        Set-DryRunMode -Enabled $false
        Assert-Result (Test-DryRunMode) $false 'disabled'
        $script:DryRunCollector = New-Object 'System.Collections.Generic.List[object]'
        Add-DryRunListEntries -Description 'Old name' -Paths @('C:\a') -SizeBytes @(5) -FileCounts @(2)
        $script:DryRunCollector.Count | Should -Be 1
        $script:DryRunCollector[0].SizeBytes | Should -Be 5
    }

    It 'Does not let a mock of an old name reach into the module: calls inside the module use the new names' {
        Mock Remove-TreeEntry { throw 'old removal name used inside the module' }
        Mock Remove-SafeDirectoryTree { throw 'old tree name used inside the module' }
        Mock Move-SweeprItemToRecycleBin { throw 'old recycle name used inside the module' }
        Mock Get-ValidatedTreeSize { throw 'old measurement name used inside the module' }
        Mock Get-SafeDirectoryTreeItems { throw 'old tree listing name used inside the module' }
        Mock Get-PathSize { throw 'old size name used inside the module' }
        Mock Get-SweeprPathSnapshot { throw 'old snapshot name used inside the module' }
        Mock Test-SweeprPathSnapshot { $false }
        Mock Test-SafePath { $false }
        Mock Remove-SafeItems { throw 'old name used inside the module' }
        Mock Add-DryRunListEntries { throw 'old list name used inside the module' }
        Mock Test-DryRunMode { $true }
        $file = New-File (P $script:Target 'a.txt') 10
        $tree = New-Tree 'full' @('b.txt', 'nested/c.txt')
        $clearRoot = New-Tree 'Temp' @('d.txt', 'nested/e.txt')
        Assert-Result (Remove-SwItem -Path $file) $true 'file'
        Assert-Result (Remove-SwItem -Path $tree) $true 'tree'
        Clear-SwDirectoryContents -Path $clearRoot
        Exists $file | Should -BeFalse
        Exists $tree | Should -BeFalse
        @(Get-ChildItem -LiteralPath $clearRoot -Force).Count | Should -Be 0
        $script:SweeprDryRunMode = $true
        Remove-SwItems -Paths @((New-File (P $script:Target 'f.txt') 10))
        $script:FilesCleaned | Should -BeGreaterThan 0
    }
}

# ============================================================================
# Removal with real identities
# ============================================================================

Describe 'Removal with real identities [W]' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -RealIdentity
    }
    AfterEach { Stop-Case }

    It 'F-22 [W] removes a file and a folder with their real identity, writes REMOVED lines and counts them' {
        $file = New-File (P $script:Target 'a.txt') 4096
        $root = New-Tree 'full' @('a.txt=100', 'nested/b.txt=200')
        Assert-Result (Remove-SwItem -Path $file) $true 'file'
        Assert-Result (Remove-SwItem -Path $root) $true 'folder'
        Exists $file | Should -BeFalse
        Exists $root | Should -BeFalse
        @($script:Ops | ForEach-Object { $_.Action }) | Should -Be @('REMOVED', 'REMOVED')
        $script:FilesCleaned | Should -Be 2
        $script:TotalSizeCleaned | Should -Be 5
    }

    It 'F-22 [W] does not remove a folder that was replaced during the measurement: the replacement and the original stay' {
        $root = New-Tree 'full' @('a.txt', 'nested/b.txt')
        $script:Swap = $root
        Mock Get-SwValidatedTreeSize {
            [System.IO.Directory]::Move($script:Swap, $script:Swap + '.orig')
            [void][System.IO.Directory]::CreateDirectory($script:Swap)
            [System.IO.File]::WriteAllText((Join-Path $script:Swap 'replacement.txt'), 'new')
            & $script:RealTreeSize -Tree $Tree
        }
        Assert-Result (Remove-SwItem -Path $root) $false 'replaced folder'
        Exists (P $root 'replacement.txt') | Should -BeTrue
        Exists (P ($root + '.orig') 'a.txt') | Should -BeTrue
        Exists (P ($root + '.orig') 'nested' 'b.txt') | Should -BeTrue
        $script:Ops.Count | Should -Be 0
    }

    It 'F-22 [W] does not remove a file that was replaced during the measurement' {
        $file = New-File (P $script:Target 'a.txt') 10
        $script:Swap = $file
        Mock Get-SwPathSize {
            [System.IO.File]::Move($script:Swap, $script:Swap + '.orig')
            [System.IO.File]::WriteAllText($script:Swap, 'new')
            10
        }
        Assert-Result (Remove-SwItem -Path $file) $false 'replaced file'
        Exists $file | Should -BeTrue
        Exists ($file + '.orig') | Should -BeTrue
    }

    It 'F-29 [W] removes the paths of a list with real identities, and F-33 empties a folder' {
        $one = New-Tree 'one' @('a.txt')
        $two = New-File (P $script:Target 'b.txt') 10
        Remove-SwItems -Paths @($one, $two)
        Exists $one | Should -BeFalse
        Exists $two | Should -BeFalse
        $root = New-Tree 'Temp' @('c.txt', 'nested/d.txt')
        Clear-SwDirectoryContents -Path $root
        Exists $root | Should -BeTrue
        @(Get-ChildItem -LiteralPath $root -Force).Count | Should -Be 0
    }

    It 'F-34 [W] removes old files with real identities' {
        $root = New-Dir (P $script:Target 'Logs')
        $old = New-File (P $root 'old.log') 10
        $young = New-File (P $root 'young.log') 10
        [System.IO.File]::SetLastWriteTime($old, (Get-Date).AddDays(-30))
        Remove-SwOldFiles -Path $root -DaysOld 7
        Exists $old | Should -BeFalse
        Exists $young | Should -BeTrue
    }

    It 'S-3 [W] removes a junction as a link and not what it points to, with Remove-SwItem and as a child of a cleared folder' {
        $target = New-Tree 'link-target' @('keep.txt', 'nested/deep.txt')
        $before = Get-Listing $target
        $link = P $script:Target 'link'
        New-TestLink $link $target
        Assert-Result (Remove-SwItem -Path $link) $true 'the link'
        Exists $link | Should -BeFalse
        Same-Listing (Get-Listing $target) $before | Should -BeTrue
        $root = New-Tree 'Temp' @('plain.txt')
        New-TestLink (P $root 'lnk') $target
        Clear-SwDirectoryContents -Path $root
        Exists (P $root 'lnk') | Should -BeFalse
        Same-Listing (Get-Listing $target) $before | Should -BeTrue
    }

    It 'S-3 [W] does nothing for a root that is a junction: Clear-SwDirectoryContents and Remove-SwOldFiles leave the target alone' {
        $target = New-Tree 'link-target' @('keep.txt')
        [System.IO.File]::SetLastWriteTime((P $target 'keep.txt'), (Get-Date).AddDays(-30))
        $before = Get-Listing $target
        $link = P $script:Target 'rootlink'
        New-TestLink $link $target
        Clear-SwDirectoryContents -Path $link
        Remove-SwOldFiles -Path $link -DaysOld 7
        Same-Listing (Get-Listing $target) $before | Should -BeTrue
    }

    It 'S-3 [W] does not remove anything below a junction' {
        $target = New-Tree 'link-target' @('keep.txt', 'sub/deep.txt')
        $before = Get-Listing $target
        $link = P $script:Target 'link'
        New-TestLink $link $target
        Assert-Result (Remove-SwItem -Path (P $link 'keep.txt')) $false 'file below a junction'
        Assert-Result (Remove-SwItem -Path (P $link 'sub')) $false 'folder below a junction'
        Remove-SwItems -Paths @((P $link 'keep.txt'))
        Same-Listing (Get-Listing $target) $before | Should -BeTrue
    }

    It 'S-9 [W] keeps a folder whose whitelisted child is named in the other spelling of the temp folder' {
        $root = New-Tree 'full' @('a.txt', 'keep/k.txt')
        $keep = P $root 'keep'
        Set-Whitelist @((Resolve-SwSafePath -Path $keep))
        $before = Get-Listing $root
        Assert-Result (Remove-SwItem -Path $root) $false 'folder with a whitelisted child'
        Same-Listing (Get-Listing $root) $before | Should -BeTrue
        Remove-SwItems -Paths @($root)
        Same-Listing (Get-Listing $root) $before | Should -BeTrue
        $parent = Split-Path -Parent $root
        Clear-SwDirectoryContents -Path $parent
        Same-Listing (Get-Listing $root) $before | Should -BeTrue
    }

    It 'S-9 [W] keeps a folder whose whitelist line uses the 8.3 spelling of the folder' {
        $long = New-Tree 'Long Folder Name For Short Names' @('a.txt', 'Keep This Folder/k.txt')
        $fso = New-Object -ComObject Scripting.FileSystemObject
        $short = $fso.GetFolder((P $long 'Keep This Folder')).ShortPath
        if ($short -ieq (P $long 'Keep This Folder')) { Set-ItResult -Skipped -Because '8.3 names are disabled on this volume'; return }
        Set-Whitelist @($short)
        $before = Get-Listing $long
        Assert-Result (Remove-SwItem -Path $long) $false 'whitelist line in the 8.3 spelling'
        Same-Listing (Get-Listing $long) $before | Should -BeTrue
    }

    It 'S-10 [W] never recycles a folder that gained a whitelisted entry before the shell call, and keeps its content' {
        $root = New-Tree 'full' @('a.txt')
        Set-Whitelist @((P $root 'keep.txt'))
        $script:LateRoot = $root
        Mock Get-SwValidatedTreeSize { New-File (P $script:LateRoot 'keep.txt') 1 | Out-Null; & $script:RealTreeSize -Tree $Tree }
        Assert-Result (Remove-SwItem -Path $root -Recycle) $false 'late whitelisted entry'
        Exists (P $root 'keep.txt') | Should -BeTrue
        Exists (P $root 'a.txt') | Should -BeTrue
    }

    It 'F-27 [W] refuses a link as the entry of the Recycle Bin path with real identities' {
        $target = New-Tree 'link-target' @('a.txt')
        $link = P $script:Target 'link'
        New-TestLink $link $target
        Assert-Result (Remove-SwItem -Path $link -Recycle) $false 'link'
        Exists (P $target 'a.txt') | Should -BeTrue
        Exists $link | Should -BeTrue
    }

    It 'F-19 [W] stops at a locked file with a real lock and leaves the rest' {
        $root = New-Tree 'full' @('aaaaaaaa.txt', 'bbbbbbbb.txt', 'lock.txt')
        $stream = [System.IO.File]::Open((P $root 'lock.txt'), [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            $report = @{}
            Assert-Result (Remove-SwDirectoryTree -Path $root -Report $report) $false 'locked file'
            Assert-Stopped ([string]$report['Reason']) (P $root 'lock.txt') '*'
            Exists (P $root 'lock.txt') | Should -BeTrue
            Exists $root | Should -BeTrue
        }
        finally { $stream.Dispose() }
    }
}
