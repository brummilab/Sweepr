# Sweepr - tests for lib\clean\caches.ps1: the sections "Browser caches", "Application caches" and
# "GPU shader caches" with their target tables, the neighbours that must stay, path building from the
# environment, one-time offers, isolation of targets and the old names.
#
# The rule numbers in the test names (CL-, SI-, S-, K- and so on) number the rules and the
# safety invariants of the cleanup core's behavior; each rule and invariant has at least one test.
# The other clean test files are SwCleanMain, SwCleanRun, SwCleanEditor (the command script),
# SwCleanGuard, SwCleanUser, SwCleanSystem and SwCleanSafety (static and cross checks).
#
# Interface pinned here (new names; the old names stay as forwarding functions, not aliases):
#   Clear-SwBrowserCaches                   section "Browser caches"        (CL-33)
#   Clear-SwAppCaches                       section "Application caches"    (CL-34)
#   Clear-SwGpuShaderCaches                 section "GPU shader caches"     (CL-35)
#   Old names: Clear-BrowserCaches, Clear-AppCaches, Clear-GPUShaderCaches
# caches.ps1 loads cache_guard.ps1, so Clear-SwAppCache and Get-SwCacheProfiles exist after loading it.
#
# Seams used with Mock: Clear-SwAppCache (spy), the removal helpers (spies; in the end-to-end tests the
# real ones), Get-SwCacheProfiles (real, or a fixed answer), Get-Item, Get-Process, Get-SwPathSnapshot and
# Test-SwPathSnapshot (substitute objects), Add-SwNotMeasured, Start-SwSection and Stop-SwSection, the
# writers of the log module, Write-SweeprOperation.
#
# Platform notes:
#   - Paths are built from $TestDrive with the separator of the host (host paths).
#     The Teams web view leaves are released by the protection rules only while the clean guard is on,
#     which every case here sets; their names are compared with one separator kind, so Linux checks them.
#     Real removals happen only below $TestDrive; no real process list and no real operations log.
#   - Tests marked [W] need real Windows. They are meant to fail on Linux and belong in
#     tests/linux-known-failures.txt.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    $script:RunModes = @(
        @{ Mode = 'a preview'; Dry = $true }
        @{ Mode = 'a real run'; Dry = $false }
    )
    $script:BadValues = @(
        @{ Label = 'not set'; Value = $null }
        @{ Label = 'blank'; Value = '   ' }
        @{ Label = 'a relative name'; Value = 'Local' }
        @{ Label = 'a drive-relative path'; Value = 'C:Temp' }
        @{ Label = 'a root-relative path'; Value = '\x' }
        @{ Label = 'a UNC path'; Value = '\\server\x' }
    )
    # B-1 to B-4: browser, process, leaves at the root (the leaves in every profile are Cache, Code Cache, GPUCache).
    $script:Chromium = @(
        @{ Browser = 'Chrome'; Process = 'chrome'; RootLeaves = @('ShaderCache', 'GrShaderCache') }
        @{ Browser = 'Edge'; Process = 'msedge'; RootLeaves = @('ShaderCache') }
        @{ Browser = 'Brave'; Process = 'brave'; RootLeaves = @() }
        @{ Browser = 'Vivaldi'; Process = 'vivaldi'; RootLeaves = @() }
    )
    # A-1 to A-5: folder below APPDATA, leaves, process, description.
    $script:AppRows = @(
        @{ Folder = 'discord'; Leaves = @('Cache', 'Code Cache', 'GPUCache'); Process = 'discord'; Description = 'Discord cache' }
        @{ Folder = 'Slack'; Leaves = @('Cache', 'Code Cache', 'GPUCache'); Process = 'slack'; Description = 'Slack cache' }
        @{ Folder = 'Cursor'; Leaves = @('Cache', 'Code Cache', 'GPUCache'); Process = 'Cursor'; Description = 'Cursor cache' }
        @{ Folder = 'Windsurf'; Leaves = @('Cache', 'Code Cache', 'GPUCache'); Process = 'Windsurf'; Description = 'Windsurf cache' }
        @{ Folder = 'Obsidian'; Leaves = @('Cache', 'Code Cache', 'GPUCache'); Process = 'Obsidian'; Description = 'Obsidian cache' }
        @{ Folder = 'Notion'; Leaves = @('Cache', 'Code Cache', 'GPUCache'); Process = 'Notion'; Description = 'Notion cache' }
    )
    # G-1 to G-12: base variable, folders below it, description.
    $script:GpuRows = @(
        @{ Id = 'G-1'; Base = 'LOCALAPPDATA'; Rest = @('NVIDIA', 'DXCache'); Description = 'NVIDIA shader cache' }
        @{ Id = 'G-2'; Base = 'LOCALAPPDATA'; Rest = @('NVIDIA', 'GLCache'); Description = 'NVIDIA shader cache' }
        @{ Id = 'G-3'; Base = 'LOCALAPPDATA'; Rest = @('NVIDIA Corporation', 'NV_Cache'); Description = 'NVIDIA shader cache' }
        @{ Id = 'G-4'; Base = 'TEMP'; Rest = @('NVIDIA Corporation', 'NV_Cache'); Description = 'NVIDIA shader cache' }
        @{ Id = 'G-5'; Base = 'LOCALAPPDATA'; Rest = @('AMD', 'DXCache'); Description = 'AMD shader cache' }
        @{ Id = 'G-6'; Base = 'LOCALAPPDATA'; Rest = @('AMD', 'GLCache'); Description = 'AMD shader cache' }
        @{ Id = 'G-7'; Base = 'LOCALAPPDATA'; Rest = @('AMD', 'VkCache'); Description = 'AMD shader cache' }
        @{ Id = 'G-8'; Base = 'LOCALAPPDATA'; Rest = @('Intel', 'ShaderCache'); Description = 'Intel shader cache' }
        @{ Id = 'G-9'; Base = 'APPDATA'; Rest = @('Intel', 'ShaderCache'); Description = 'Intel shader cache' }
        @{ Id = 'G-10'; Base = 'LOCALAPPDATA'; Rest = @('D3DSCache'); Description = 'DirectX shader cache' }
        @{ Id = 'G-11'; Base = 'LOCALAPPDATA'; Rest = @('Microsoft', 'DirectX Shader Cache'); Description = 'DirectX pipeline cache' }
        @{ Id = 'G-12'; Base = 'LOCALAPPDATA'; Rest = @('VulkanCache'); Description = 'Vulkan pipeline cache' }
    )
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:CoreDir = [System.IO.Path]::Combine($script:RepoRoot, 'lib', 'core')
    $script:CleanDir = [System.IO.Path]::Combine($script:RepoRoot, 'lib', 'clean')
    $script:BinDir = [System.IO.Path]::Combine($script:RepoRoot, 'bin')
    $script:OnWindows = [System.IO.Path]::DirectorySeparatorChar -eq '\'
    $script:IsDesktop = $PSVersionTable['PSEdition'] -eq 'Desktop'
    $script:Sep = [string][System.IO.Path]::DirectorySeparatorChar
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
    $script:WorkCounter = 0
    $script:Links = [System.Collections.Generic.List[string]]::new()

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
    # An empty value removes the variable (an empty value would stay set on newer .NET versions).
    function script:Set-Env([string]$Name, [AllowNull()][AllowEmptyString()][string]$Value) {
        if ([string]::IsNullOrEmpty($Value)) { [System.Environment]::SetEnvironmentVariable($Name, [NullString]::Value) }
        else { [System.Environment]::SetEnvironmentVariable($Name, $Value) }
    }

    $script:EnvNames = @('SWEEPR_DRY_RUN', 'SWEEPR_NO_OPLOG', 'SWEEPR_DEBUG', 'SWEEPR_DATA_DIR', '_SWEEPR_OPLOG_RUN_COMMAND',
        '_SWEEPR_OPLOG_RUN_ID', 'USERPROFILE', 'LOCALAPPDATA', 'APPDATA', 'TEMP', 'PROGRAMDATA', 'WINDIR', 'SYSTEMROOT')
    $script:StateNames = @('Config', 'ProtectedPaths', 'ExactProtectedPaths', 'DefaultWhitelistPatterns', 'SweeprCleanPathGuard',
        'SweeprDryRunMode', 'TotalSizeCleaned', 'FilesCleaned', 'TotalItems', 'OwnerCleanups', 'DryRunCollector',
        'NotMeasuredCollector', 'SectionCollector', 'ExportListFile', 'SwWalkBudgetSeconds', 'SwProbeBudgetSeconds',
        'CurrentSection', 'SweeprOperationsLogFile', 'SweeprOperationsLogStarted', 'SpinnerDisabled', 'SweeprSkipExternalTools')
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
    function script:Exists([string]$Path) { [System.IO.File]::Exists($Path) -or [System.IO.Directory]::Exists($Path) }
    # Comparison form of a path: normalized, one separator kind, no trailing separator, no case.
    function script:Fold([string]$Path) {
        $text = $Path
        try { if ([System.IO.Path]::IsPathRooted($text)) { $text = [System.IO.Path]::GetFullPath($text) } } catch { $null = $_ }
        $text.Replace('/', '\').TrimEnd('\').ToLowerInvariant()
    }
    function script:Test-Under([string]$Path, [string]$Root) {
        $one = Fold $Path
        $two = Fold $Root
        $one.StartsWith($two + '\', [System.StringComparison]::Ordinal)
    }
    function script:Test-SameOrUnder([string]$Path, [string]$Root) { ((Fold $Path) -eq (Fold $Root)) -or (Test-Under $Path $Root) }
    function script:New-Work {
        $script:WorkCounter++
        New-Dir (P $TestDrive ('w' + $script:WorkCounter))
    }
    # Time stamps of a file or folder: creation and last write, days in the past. Windows-only tests set the
    # two apart; on other hosts the creation time follows the write time.
    function script:Set-Age([string]$Path, [double]$Days) {
        $time = [datetime]::Now.AddDays(-$Days)
        if ([System.IO.Directory]::Exists($Path)) {
            [System.IO.Directory]::SetCreationTime($Path, $time)
            [System.IO.Directory]::SetLastWriteTime($Path, $time)
        }
        else {
            [System.IO.File]::SetCreationTime($Path, $time)
            [System.IO.File]::SetLastWriteTime($Path, $time)
        }
    }
    # Ages everything below a folder (deepest entries first, so that a folder keeps its time) and the folder.
    function script:Set-TreeAge([string]$Root, [double]$Days) {
        $items = @(Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object { $_.FullName.Length } -Descending)
        foreach ($item in $items) { Set-Age $item.FullName $Days }
        Set-Age $Root $Days
    }
    function script:New-OldFile([string]$Path, [double]$Days = 30, [int]$Bytes = 3) {
        $null = New-File $Path $Bytes
        Set-Age $Path $Days
        $Path
    }
    # A file that counts as hidden for the host: the Hidden attribute on Windows, a leading dot elsewhere.
    function script:New-HiddenFile([string]$Folder, [string]$Name, [double]$Days = 0) {
        if ($script:OnWindows) {
            $path = New-File (P $Folder $Name)
            [System.IO.File]::SetAttributes($path, [System.IO.FileAttributes]::Hidden)
        }
        else { $path = New-File (P $Folder ('.' + $Name)) }
        if ($Days -gt 0) { Set-Age $path $Days }
        $path
    }
    # Name, kind, length, attributes and time stamps of everything below a folder.
    function script:Get-Listing([string]$Root) {
        if (-not [System.IO.Directory]::Exists($Root)) { return , @('<missing>') }
        $rows = [System.Collections.Generic.List[string]]::new()
        foreach ($item in @(Get-ChildItem -LiteralPath $Root -Recurse -Force)) {
            $rel = $item.FullName.Substring($Root.Length)
            if ($item.PSIsContainer) { $rows.Add(('D {0} {1} {2}' -f $rel, [int]$item.Attributes, $item.LastWriteTimeUtc.Ticks)) }
            else { $rows.Add(('F {0} {1} {2} {3}' -f $rel, $item.Length, [int]$item.Attributes, $item.LastWriteTimeUtc.Ticks)) }
        }
        , @($rows | Sort-Object)
    }
    function script:Same-Listing($Left, $Right) { (@($Left) -join '|') -ceq (@($Right) -join '|') }
    function script:Get-FileText([string]$Path) { [System.IO.File]::ReadAllText($Path, $script:Utf8) }
    function script:Get-FileLines([string]$Path) {
        $text = Get-FileText $Path
        , @($text -split "`r?`n")
    }
    # Non-ASCII text is built from code points, so the test files stay ASCII.
    function script:S([int[]]$CodePoints) {
        $sb = New-Object System.Text.StringBuilder
        foreach ($cp in $CodePoints) { [void]$sb.Append([char]::ConvertFromUtf32($cp)) }
        $sb.ToString()
    }
    function script:Remove-Ansi([string]$Text) { [regex]::Replace($Text, "$([char]27)\[[0-9;]*[A-Za-z]", '') }

    function script:New-TestLink([string]$Link, [string]$Target) {
        try {
            if ($script:OnWindows -and [System.IO.Directory]::Exists($Target)) { [void](New-Item -ItemType Junction -Path $Link -Target $Target) }
            else { [void](New-Item -ItemType SymbolicLink -Path $Link -Target $Target) }
        }
        catch { return $false }
        $script:Links.Add($Link)
        $true
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

    # Runs a block that must throw and gives the error record. A block that does not throw fails the test,
    # and so does a block that only fails because a function does not exist.
    function script:Assert-Throws([scriptblock]$Block) {
        $failure = $null
        try { $null = & $Block } catch { $failure = $_ }
        if ($null -eq $failure) { throw 'expected an exception, but there was none' }
        if ($failure.Exception -is [System.Management.Automation.CommandNotFoundException]) { throw ('the function does not exist: ' + $failure.Exception.Message) }
        $failure
    }
    function script:Assert-Defined([string[]]$Names) {
        foreach ($name in $Names) {
            ($null -ne (Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue)) | Should -BeTrue -Because "$name must be defined after loading"
        }
    }
    # Parameters of a function: name, type, position, mandatory flag and default text, one line each.
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
            if ($position -eq '-2147483648') { $position = 'none' }
            $default = ''
            if ($null -ne $parameter.DefaultValue) { $default = $parameter.DefaultValue.Extent.Text }
            $lines += ('{0}|{1}|pos={2}|mandatory={3}|default={4}' -f $paramName, $meta.ParameterType.FullName, $position, $mandatory, $default)
        }
        , $lines
    }
    function script:Get-ParamLine([string]$Function, [string]$Parameter) {
        $all = Get-ParamSignature $Function
        $line = $all | Where-Object { $_.StartsWith($Parameter + '|', [System.StringComparison]::Ordinal) } | Select-Object -First 1
        $line
    }

    # ---- fakes for the identity functions ---------------------------------------------------------

    # Answers like the real functions, with substitute objects: an existing path inside the case folder has
    # an identity, a link as the entry only with -AllowLeafLink, a link above the entry never. Paths in
    # $script:FakeNoIdentity have none; paths in $script:FakeReplaced fail the identity test.
    function script:Test-FakeLinkAbove([string]$Path, [bool]$Leaf, [bool]$AllowLeafLink) {
        $work = [System.IO.Path]::GetFullPath($script:Work)
        $current = [System.IO.Path]::GetFullPath($Path)
        while (-not [string]::IsNullOrEmpty($current) -and $current.StartsWith($work, [System.StringComparison]::OrdinalIgnoreCase)) {
            $attributes = $null
            try { $attributes = [System.IO.File]::GetAttributes($current) } catch { return $true }
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                if (-not $Leaf -or -not $AllowLeafLink) { return $true }
            }
            $Leaf = $false
            $current = [System.IO.Path]::GetDirectoryName($current)
        }
        $false
    }
    function script:Use-FakeIdentity {
        $script:FakeNoIdentity = [System.Collections.Generic.List[string]]::new()
        $script:FakeReplaced = [System.Collections.Generic.List[string]]::new()
        $script:SnapshotCalls = [System.Collections.Generic.List[object]]::new()
        $script:SnapshotTests = [System.Collections.Generic.List[string]]::new()
        if ($null -eq (Get-Command -Name Get-SwPathSnapshot -CommandType Function -ErrorAction SilentlyContinue)) { return }
        Mock Get-SwPathSnapshot {
            $script:SnapshotCalls.Add([pscustomobject]@{ Path = $Path; AllowLeafLink = [bool]$AllowLeafLink })
            if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
            if (-not (Exists $Path)) { return $null }
            foreach ($listed in @($script:FakeNoIdentity)) { if ((Fold $listed) -eq (Fold $Path)) { return $null } }
            if (Test-FakeLinkAbove $Path $true ([bool]$AllowLeafLink)) { return $null }
            [pscustomobject]@{ Path = $Path; AllowLeafLink = [bool]$AllowLeafLink }
        }
        Mock Test-SwPathSnapshot {
            if ($null -eq $Snapshot) { return $false }
            $path = [string]$Snapshot.Path
            $script:SnapshotTests.Add($path)
            if ([string]::IsNullOrEmpty($path)) { return $false }
            if (-not (Exists $path)) { return $false }
            foreach ($listed in @($script:FakeReplaced)) { if ((Fold $listed) -eq (Fold $path)) { return $false } }
            $true
        }
    }

    # ---- spies --------------------------------------------------------------------------------------

    # Everything the code says on the host through the writers of the log module, the sections it opens
    # and closes, and what it notes as not measured.
    function script:Use-Spies {
        $script:Log = [System.Collections.Generic.List[string]]::new()
        $script:HostLines = [System.Collections.Generic.List[string]]::new()
        $script:Sections = [System.Collections.Generic.List[string]]::new()
        $script:NotMeasured = [System.Collections.Generic.List[object]]::new()
        Mock Write-SwInfo { $script:Log.Add('INFO|' + (Remove-Ansi ([string]$Message))) }
        Mock Write-SwSuccess { $script:Log.Add('SUCCESS|' + (Remove-Ansi ([string]$Message))) }
        Mock Write-SwWarning { $script:Log.Add('WARN|' + (Remove-Ansi ([string]$Message))) }
        Mock Write-SwError { $script:Log.Add('ERROR|' + (Remove-Ansi ([string]$Message))) }
        Mock Write-SwDebug { $script:Log.Add('DEBUG|' + (Remove-Ansi ([string]$Message))) }
        Mock Write-Host { $script:HostLines.Add((Remove-Ansi (@($Object | ForEach-Object { [string]$_ }) -join ' '))) }
        Mock Start-SwSection { $script:Sections.Add('start:' + $Title) }
        Mock Stop-SwSection { $script:Sections.Add('stop') }
        Mock Add-SwNotMeasured { $script:NotMeasured.Add([pscustomobject]@{ Name = $Name; Reason = $Reason }) }
        Mock Write-SweeprOperation { $script:Ops.Add([pscustomobject]@{ Action = $Action; Path = $Path; Detail = $Detail }) }
        $script:Ops = [System.Collections.Generic.List[object]]::new()
    }
    # All text a code path wrote: writer lines and host lines.
    function script:Get-AllText { (@($script:Log) + @($script:HostLines)) -join "`n" }
    function script:Get-LogLines([string]$Level) {
        @($script:Log | Where-Object { $_.StartsWith($Level + '|', [System.StringComparison]::Ordinal) } | ForEach-Object { $_.Substring($Level.Length + 1) })
    }

    # The three removal helpers as spies. They record and remove nothing.
    function script:Use-HelperSpies {
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        Mock Remove-SwItems {
            $script:Calls.Add([pscustomobject]@{ Fn = 'Remove-SwItems'; Path = $null; Paths = @($Paths); Description = $Description; CanRemove = $CanRemove; DaysOld = $null; Filter = $null })
        }
        Mock Clear-SwDirectoryContents {
            $script:Calls.Add([pscustomobject]@{ Fn = 'Clear-SwDirectoryContents'; Path = $Path; Paths = @(); Description = $Description; CanRemove = $CanRemove; DaysOld = $null; Filter = $null })
        }
        Mock Remove-SwOldFiles {
            $script:Calls.Add([pscustomobject]@{ Fn = 'Remove-SwOldFiles'; Path = $Path; Paths = @(); Description = $Description; CanRemove = $null; DaysOld = $DaysOld; Filter = $Filter })
        }
        Mock Remove-SwItem { $script:Calls.Add([pscustomobject]@{ Fn = 'Remove-SwItem'; Path = $Path; Paths = @(); Description = $Description; CanRemove = $null; DaysOld = $null; Filter = $null }); $true }
    }
    function script:Get-Calls([string]$Fn) { @($script:Calls | Where-Object { $_.Fn -eq $Fn }) }
    # Every path a helper spy was given, whatever the helper.
    function script:Get-CallPaths {
        $paths = [System.Collections.Generic.List[string]]::new()
        foreach ($call in @($script:Calls)) {
            if (-not [string]::IsNullOrEmpty([string]$call.Path)) { $paths.Add([string]$call.Path) }
            foreach ($path in @($call.Paths)) { $paths.Add([string]$path) }
        }
        $paths.ToArray()
    }
    function script:Test-AnyUnder([string[]]$Paths, [string]$Root) {
        foreach ($path in @($Paths)) { if (Test-SameOrUnder $path $Root) { return $true } }
        $false
    }
    # True when no path in the list equals another or lies below another (one section run, CL-22).
    function script:Test-Disjoint([string[]]$Paths) {
        $list = @($Paths)
        for ($i = 0; $i -lt $list.Count; $i++) {
            for ($j = 0; $j -lt $list.Count; $j++) {
                if ($i -eq $j) { continue }
                if (Test-SameOrUnder $list[$i] $list[$j]) { return $false }
            }
        }
        $true
    }

    # ---- one case: a fake profile below the test drive --------------------------------------------

    function script:Initialize-Case {
        param([switch]$RealProcess, [switch]$RealIdentity)
        $script:SavedState = Save-State
        $script:SavedEnv = Save-Env $script:EnvNames
        $script:SavedCwd = [System.Environment]::CurrentDirectory
        $script:SavedLocation = (Get-Location).Path
        $script:Work = New-Work
        $script:Profile = New-Dir (P $script:Work 'profile')
        $script:Local = New-Dir (P $script:Profile 'AppData' 'Local')
        $script:Roam = New-Dir (P $script:Profile 'AppData' 'Roaming')
        $script:Scratch = New-Dir (P $script:Work 'scratch')
        $script:ProgramData = New-Dir (P $script:Work 'programdata')
        $script:WinDir = New-Dir (P $script:Work 'windows')
        $script:Data = P $script:Work 'appdata'
        Set-Env 'USERPROFILE' $script:Profile
        Set-Env 'LOCALAPPDATA' $script:Local
        Set-Env 'APPDATA' $script:Roam
        Set-Env 'TEMP' $script:Scratch
        Set-Env 'PROGRAMDATA' $script:ProgramData
        Set-Env 'WINDIR' $script:WinDir
        Set-Env 'SYSTEMROOT' $script:WinDir
        Set-Env 'SWEEPR_NO_OPLOG' '1'
        Set-Env 'SWEEPR_DRY_RUN' $null
        Set-Env 'SWEEPR_DEBUG' $null
        Set-Env 'SWEEPR_DATA_DIR' $null
        $script:Config = @{ ConfigPath = (P $script:Data 'config'); CachePath = (P $script:Data 'cache'); WhitelistFile = (P $script:Data 'config' 'whitelist.txt') }
        $script:DefaultWhitelistPatterns = @()
        $script:ProtectedPaths = @($script:WinDir)
        $script:ExactProtectedPaths = @($script:Profile)
        $script:SweeprCleanPathGuard = $true
        $script:SweeprDryRunMode = $true
        $script:TotalSizeCleaned = 0
        $script:FilesCleaned = 0
        $script:TotalItems = 0
        $script:OwnerCleanups = 0
        $script:DryRunCollector = $null
        $script:NotMeasuredCollector = $null
        $script:SectionCollector = $null
        $script:SpinnerDisabled = $true
        Remove-Variable -Name ExportListFile -Scope Script -ErrorAction SilentlyContinue
        $script:SwWalkBudgetSeconds = 15
        $script:SwProbeBudgetSeconds = 2
        $script:CurrentSection = @{ Active = $false; Activity = $false; Name = 'Example section' }
        $script:SweeprOperationsLogFile = P $script:Work 'oplog' 'operations.log'
        $script:SweeprOperationsLogStarted = $false
        if (-not $RealIdentity) { Use-FakeIdentity }
        Use-Spies
        if (-not $RealProcess) { Mock Get-Process { @() } }
    }
    function script:Stop-Case {
        Clear-TestLinks
        Restore-Env $script:SavedEnv
        Restore-State $script:SavedState
        [System.Environment]::CurrentDirectory = $script:SavedCwd
        try { Set-Location -LiteralPath $script:SavedLocation } catch { $null = $_ }
    }
    function script:Set-Whitelist([string[]]$Lines) {
        $file = $script:Config.WhitelistFile
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($file))
        [System.IO.File]::WriteAllText($file, (($Lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding $false))
    }
    # Counts every host line of a block: writer lines and host lines together, the block's own output apart.
    function script:Invoke-Captured([scriptblock]$Block) {
        $values = [System.Collections.Generic.List[object]]::new()
        foreach ($item in @(& $Block)) { $values.Add($item) }
        , @($values)
    }

    # Command names of the paths that start the environment of a plain run in a child process.
    function script:ConvertTo-TestLiteral([string]$Value) { "'" + $Value.Replace("'", "''") + "'" }
    function script:Invoke-ChildPowerShell {
        param([string]$Script, [string]$WorkingDirectory = $TestDrive, [hashtable]$Environment = @{}, [string[]]$RemoveEnvironment = @(), [string]$Executable = '')
        $exe = $Executable
        if ([string]::IsNullOrEmpty($exe)) { $exe = (Get-Process -Id $PID).Path }
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Script))
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.WorkingDirectory = $WorkingDirectory
        foreach ($name in $RemoveEnvironment) { if ($psi.EnvironmentVariables.ContainsKey($name)) { $psi.EnvironmentVariables.Remove($name) } }
        foreach ($name in $Environment.Keys) { $psi.EnvironmentVariables[$name] = [string]$Environment[$name] }
        $process = [System.Diagnostics.Process]::Start($psi)
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(180000)) { $process.Kill(); throw 'child PowerShell timed out' }
        [pscustomobject]@{ ExitCode = $process.ExitCode; Out = $stdout.Result; Err = $stderr.Result }
    }
    # Windows PowerShell serializes progress records into redirected stderr as CLIXML: drop that envelope.
    function script:Get-ChildStderr([string]$Text) {
        if ([string]::IsNullOrEmpty($Text)) { return '' }
        $clean = [regex]::Replace($Text, '(?s)<Obj S="progress".*?</Obj>', '')
        $clean = [regex]::Replace($clean, '<Objs[^>]*>|</Objs>|#< CLIXML', '')
        $clean.Trim()
    }

    # What the whole file changes in the process is put back after the last test. The core modules are
    # loaded here, so that a test never depends on what the file under test loads itself.
    $script:RootState = Save-State
    $script:RootEnv = Save-Env $script:EnvNames
    $script:RootDirectory = [System.Environment]::CurrentDirectory
    . ([System.IO.Path]::Combine($script:CoreDir, 'base.ps1'))
    . ([System.IO.Path]::Combine($script:CoreDir, 'log.ps1'))
    . ([System.IO.Path]::Combine($script:CoreDir, 'file_ops.ps1'))
    . ([System.IO.Path]::Combine($script:CoreDir, 'ui.ps1'))

    $script:CachesFile = [System.IO.Path]::Combine($script:CleanDir, 'caches.ps1')
    . $script:CachesFile
    $script:RealGetItem = Get-Command -Name Get-Item -CommandType Cmdlet
    $script:RealTreeSizeBlock = $null
    $treeSize = Get-Command -Name Get-SwValidatedTreeSize -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $treeSize) { $script:RealTreeSizeBlock = $treeSize.ScriptBlock }

    function script:Use-AppCacheSpy {
        $script:AppCalls = [System.Collections.Generic.List[object]]::new()
        Mock Clear-SwAppCache {
            $script:AppCalls.Add([pscustomobject]@{ Path = $Path; Description = $Description; Processes = @($Processes); LockPath = $LockPath })
        }
    }
    function script:Use-ProcessSpy([string[]]$Running = @()) {
        $script:ProcCalls = [System.Collections.Generic.List[object]]::new()
        $script:ProcRunning = @($Running)
        Mock Get-Process {
            $script:ProcCalls.Add(1)
            @($script:ProcRunning | ForEach-Object { [pscustomobject]@{ ProcessName = $_ } })
        }
    }
    function script:Use-Collector { $script:DryRunCollector = [System.Collections.Generic.List[object]]::new() }
    # The calls of the cache cleaner at or below a folder, as comparable lines: path, description, process, lock.
    function script:Get-AppLines([string]$Root) {
        @($script:AppCalls | Where-Object { Test-SameOrUnder $_.Path $Root } | ForEach-Object {
                '{0}|{1}|{2}|{3}' -f $_.Path, $_.Description, (@($_.Processes) -join ','), $_.LockPath
            } | Sort-Object)
    }
    function script:ConvertTo-AppLine([string]$Path, [string]$Description, [string]$Process, [string]$Lock = '') {
        '{0}|{1}|{2}|{3}' -f $Path, $Description, $Process, $Lock
    }
    function script:Get-AppPaths { @($script:AppCalls | ForEach-Object { $_.Path }) }
    # Every folder offered to any helper by the section (cache cleaner and directory helper).
    function script:Get-Offered { @(@(Get-AppPaths) + @(Get-CallPaths)) }
    function script:Get-BrowserRoot([string]$Browser) {
        switch ($Browser) {
            'Chrome' { Get-ChromeRoot }
            'Edge' { Get-EdgeRoot }
            'Brave' { Get-BraveRoot }
            'Vivaldi' { Get-VivaldiRoot }
        }
    }
    # Expected lines of one Chromium browser for the given profiles.
    function script:Get-ChromiumLines([string]$Browser, [string]$Process, [string[]]$RootLeaves, [string[]]$Profiles) {
        $root = Get-BrowserRoot $Browser
        $lock = P $root 'lockfile'
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($leaf in $RootLeaves) { $lines.Add((ConvertTo-AppLine (P $root $leaf) "$Browser $leaf" $Process $lock)) }
        foreach ($profile in $Profiles) {
            foreach ($leaf in 'Cache', 'Code Cache', 'GPUCache') { $lines.Add((ConvertTo-AppLine (P $root $profile $leaf) "$Browser $leaf" $Process $lock)) }
        }
        , @($lines | Sort-Object)
    }
    # Get-Item that fails for the folders (full paths) named in $script:ItemFails and reads like the real one otherwise.
    function script:Use-ItemFailure([string[]]$Paths) {
        $script:ItemFails = @($Paths)
        Mock Get-Item {
            $leaf = [System.IO.Path]::GetFileName(([string]$LiteralPath).TrimEnd('\', '/'))
            foreach ($failing in $script:ItemFails) { if ((Fold $failing) -eq (Fold ([string]$LiteralPath))) { throw 'access denied (test)' } }
            & $script:RealGetItem -LiteralPath $LiteralPath -Force -ErrorAction Stop
        }
    }


    # ---- a rich profile: every catalog target, neighbours that must stay, nested decoys ----------------

    # A cache folder with one entry in it; gives the folder.
    function script:New-Leaf([string]$Folder, [int]$Bytes = 10) {
        $null = New-File (P $Folder 'entry') $Bytes
        $Folder
    }
    # Names that belong to the user and that no section may offer.
    $script:ChromiumPrivate = @('Cookies', 'Login Data', 'Web Data', 'Local Storage', 'Session Storage', 'IndexedDB', 'Sessions', 'Sync Data', 'Local Extension Settings')
    function script:New-ChromiumRoot([string]$Root, [string[]]$Profiles = @('Default', 'Profile 2', 'Profile [work]')) {
        $null = New-Dir $Root
        foreach ($leaf in 'ShaderCache', 'GrShaderCache') { $null = New-Leaf (P $Root $leaf) }
        $null = New-File (P $Root 'ShaderCache' 'GPUCache' 'entry') 10
        $null = New-File (P $Root 'Local State') 10
        foreach ($profile in $Profiles) {
            foreach ($leaf in 'Cache', 'Code Cache', 'GPUCache') { $null = New-Leaf (P $Root $profile $leaf) }
            foreach ($private in $script:ChromiumPrivate) { $null = New-File (P $Root $profile $private 'keep.dat') 10 }
            $null = New-File (P $Root $profile 'Service Worker' 'CacheStorage' 'offline') 10
        }
        $Root
    }
    function script:Get-ChromeRoot { P $script:Local 'Google' 'Chrome' 'User Data' }
    function script:Get-EdgeRoot { P $script:Local 'Microsoft' 'Edge' 'User Data' }
    function script:Get-BraveRoot { P $script:Local 'BraveSoftware' 'Brave-Browser' 'User Data' }
    function script:Get-VivaldiRoot { P $script:Local 'Vivaldi' 'User Data' }
    function script:Get-TeamsNewRoot { P $script:Local 'Packages' 'MSTeams_8wekyb3d8bbwe' 'LocalCache' 'Microsoft' 'MSTeams' 'EBWebView' }
    function script:New-RichFixture([string[]]$Only = @('Browser', 'Apps', 'Gpu')) {
        if ($Only -contains 'Browser') { New-RichBrowserFixture }
        if ($Only -contains 'Apps') { New-RichAppFixture }
        if ($Only -contains 'Gpu') { New-RichGpuFixture }
    }
    function script:New-RichBrowserFixture {
        foreach ($root in (Get-ChromeRoot), (Get-EdgeRoot), (Get-BraveRoot), (Get-VivaldiRoot)) { $null = New-ChromiumRoot $root }
        # Firefox: caches in the local profile, shader cache and profile data in the roaming profile
        $ffLocal = P $script:Local 'Mozilla' 'Firefox' 'Profiles' 'p.default'
        $ffRoam = P $script:Roam 'Mozilla' 'Firefox' 'Profiles' 'p.default'
        foreach ($leaf in 'cache2', 'startupCache') { $null = New-Leaf (P $ffLocal $leaf) }
        $null = New-File (P $ffLocal 'storage' 'keep.dat') 10
        $null = New-Leaf (P $ffRoam 'shader-cache')
        $null = New-Leaf (P $ffRoam 'cache2')
        $null = New-File (P $ffRoam 'prefs.js') 10
        # Opera: two roots, the old layout keeps the leaves in the root itself
        foreach ($root in (P $script:Roam 'Opera Software' 'Opera Stable'), (P $script:Local 'Opera Software' 'Opera Stable')) {
            foreach ($leaf in 'Cache', 'Code Cache', 'GPUCache') { $null = New-Leaf (P $root $leaf) }
            foreach ($leaf in 'Cache', 'Code Cache', 'GPUCache') { $null = New-Leaf (P $root 'Default' $leaf) }
            $null = New-File (P $root 'Default' 'Cookies' 'keep.dat') 10
        }
    }
    function script:New-RichAppFixture {
        # Application caches and the neighbours that stay
        foreach ($name in 'discord', 'Slack', 'Cursor', 'Windsurf', 'Obsidian', 'Notion') {
            foreach ($leaf in 'Cache', 'Code Cache', 'GPUCache') { $null = New-Leaf (P $script:Roam $name $leaf) }
            $null = New-File (P $script:Roam $name 'Local Storage' 'keep.dat') 10
            $null = New-File (P $script:Roam $name 'Service Worker' 'CacheStorage' 'offline') 10
        }
        foreach ($leaf in 'Cache', 'GPUCache') { $null = New-Leaf (P $script:Roam 'Microsoft' 'Teams' $leaf) }
        foreach ($other in 'blob_storage', 'tmp', 'IndexedDB', 'Local Storage', 'databases') { $null = New-File (P $script:Roam 'Microsoft' 'Teams' $other 'keep.dat') 10 }
        foreach ($profile in 'Default', 'Profile 1') {
            foreach ($leaf in 'Cache', 'Code Cache', 'GPUCache') { $null = New-Leaf (P (Get-TeamsNewRoot) $profile $leaf) }
            $null = New-File (P (Get-TeamsNewRoot) $profile 'IndexedDB' 'state') 10
        }
        foreach ($leaf in 'Cache', 'Code Cache', 'GPUCache') { $null = New-Leaf (P (Get-TeamsNewRoot) $leaf) }
        $null = New-File (P $script:Local 'Packages' 'Other_app' 'LocalCache' 'Default' 'Cache' 'entry') 10
        $null = New-File (P $script:Roam 'Spotify' 'Data' 'offline.dat') 10
        $null = New-File (P $script:Roam 'Spotify' 'Storage' 'offline.dat') 10
        $null = New-File (P $script:Roam 'Zoom' 'data' 'keep.dat') 10
        # Caches that belong to another section or no longer exist
        foreach ($other in (P $script:Roam 'Code' 'Cache'), (P $script:Roam 'Code - Insiders' 'Cache'), (P $script:Roam 'Sublime Text' 'Cache'),
            (P $script:Local 'Sublime Text' 'Cache'), (P $script:Local 'Zed' 'Cache'), (P $script:Local 'Microsoft' 'vscode-cpptools'),
            (P $script:Local 'EpicGamesLauncher' 'Saved' 'webcache'), (P $script:Roam 'Adobe' 'Common' 'Media Cache Files'), (P $script:Local 'Steam' 'htmlcache')) {
            $null = New-Leaf $other
        }
    }
    function script:New-RichGpuFixture {
        # GPU shader caches
        foreach ($folder in (P $script:Local 'NVIDIA' 'DXCache'), (P $script:Local 'NVIDIA' 'GLCache'), (P $script:Local 'NVIDIA Corporation' 'NV_Cache'),
            (P $script:Scratch 'NVIDIA Corporation' 'NV_Cache'), (P $script:Local 'AMD' 'DXCache'), (P $script:Local 'AMD' 'GLCache'),
            (P $script:Local 'AMD' 'VkCache'), (P $script:Local 'Intel' 'ShaderCache'), (P $script:Roam 'Intel' 'ShaderCache'),
            (P $script:Local 'D3DSCache'), (P $script:Local 'Microsoft' 'DirectX Shader Cache'), (P $script:Local 'VulkanCache')) {
            $null = New-Leaf $folder
        }
    }
}

AfterAll {
    Clear-TestLinks
    Restore-State $script:RootState
    Restore-Env $script:RootEnv
    [System.Environment]::CurrentDirectory = $script:RootDirectory
}

# ============================================================================
# Interface, loading and old names
# ============================================================================

Describe 'caches.ps1 interface' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
    }

    It 'CL-33 CL-34 CL-35 defines the three sections and their old names' {
        Assert-Defined @('Clear-SwBrowserCaches', 'Clear-SwAppCaches', 'Clear-SwGpuShaderCaches', 'Clear-BrowserCaches', 'Clear-AppCaches', 'Clear-GPUShaderCaches')
    }

    It 'SI-7 loads cache_guard.ps1 itself, so the shared functions exist after loading caches.ps1 alone' {
        Assert-Defined @('Clear-SwBrowserCaches', 'Clear-SwAppCache', 'Get-SwCacheProfiles', 'Test-SwCacheOwnerIdle')
    }

    It 'gives the three old names no parameters' -ForEach @(
        @{ Name = 'Clear-BrowserCaches' }
        @{ Name = 'Clear-AppCaches' }
        @{ Name = 'Clear-GPUShaderCaches' }
    ) {
        (Get-ParamSignature $Name).Count | Should -Be 0
    }

    It 'SI-1 CL-33 CL-34 CL-35 the old name <Old> calls <New> once' -ForEach @(
        @{ Old = 'Clear-BrowserCaches'; New = 'Clear-SwBrowserCaches' }
        @{ Old = 'Clear-AppCaches'; New = 'Clear-SwAppCaches' }
        @{ Old = 'Clear-GPUShaderCaches'; New = 'Clear-SwGpuShaderCaches' }
    ) {
        Initialize-Case
        try {
            $script:Seen = 0
            Mock $New { $script:Seen++ }
            & $Old
            $script:Seen | Should -Be 1
        }
        finally { Stop-Case }
    }
}

# ============================================================================
# Browser caches: the calls (CL-33, CL-22, CL-20, S-17)
# ============================================================================

Describe 'Clear-SwBrowserCaches calls' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-AppCacheSpy
        Use-HelperSpies
        New-RichFixture -Only Browser
    }
    AfterEach { Stop-Case }

    It 'SI-1 opens the section Browser caches once and closes it once' {
        Clear-SwBrowserCaches
        @($script:Sections) | Should -Be @('start:Browser caches', 'stop')
    }

    It 'SI-1 opens and closes the section when no browser is installed' {
        Remove-Item -LiteralPath $script:Profile -Recurse -Force
        $null = New-Dir $script:Local
        $null = New-Dir $script:Roam
        Clear-SwBrowserCaches
        @($script:Sections) | Should -Be @('start:Browser caches', 'stop')
    }

    It 'B-1 to B-4 offers the leaves of <Browser> through the cache cleaner with description, process and lock file, and nothing else under its root' -ForEach $script:Chromium {
        Clear-SwBrowserCaches
        $expected = Get-ChromiumLines $Browser $Process $RootLeaves @('Default', 'Profile 2', 'Profile [work]')
        @(Get-AppLines (Get-BrowserRoot $Browser)) | Should -Be @($expected)
    }

    It 'CL-33 offers the root leaves of a Chromium browser before any profile leaf' {
        Clear-SwBrowserCaches
        $paths = @(Get-AppPaths)
        $root = Get-ChromeRoot
        $shader = [array]::IndexOf($paths, (P $root 'ShaderCache'))
        $first = -1
        for ($i = 0; $i -lt $paths.Count; $i++) { if ($paths[$i] -ceq (P $root 'Default' 'Cache')) { $first = $i; break } }
        $shader | Should -BeGreaterOrEqual 0
        $first | Should -BeGreaterThan $shader
    }

    It 'CL-33 offers the root leaves even when profile discovery gives nothing, and no profile leaf then' {
        Mock Get-SwCacheProfiles { }
        Clear-SwBrowserCaches
        $chrome = @(Get-AppLines (Get-ChromeRoot))
        $chrome.Count | Should -Be 2
        @(Get-AppPaths) | Should -Contain (P (Get-ChromeRoot) 'ShaderCache')
        @(Get-AppPaths) | Should -Not -Contain (P (Get-ChromeRoot) 'Default' 'Cache')
    }

    It 'CL-33 asks Get-SwCacheProfiles once for each Chromium root' {
        Mock Get-SwCacheProfiles { }
        Clear-SwBrowserCaches
        foreach ($root in (Get-ChromeRoot), (Get-EdgeRoot), (Get-BraveRoot), (Get-VivaldiRoot)) {
            $rootCopy = $root
            Should -Invoke Get-SwCacheProfiles -Times 1 -Exactly -ParameterFilter { (Fold $Root) -eq (Fold $rootCopy) }
        }
    }

    It 'CL-22 CL-33 offers ShaderCache but not the GPUCache folder inside it (profile discovery gives ShaderCache back)' {
        Mock Get-SwCacheProfiles {
            if ((Fold $Root) -eq (Fold (Get-ChromeRoot))) {
                [System.IO.DirectoryInfo]::new((P (Get-ChromeRoot) 'ShaderCache'))
                [System.IO.DirectoryInfo]::new((P (Get-ChromeRoot) 'Default'))
            }
        }
        Clear-SwBrowserCaches
        $paths = @(Get-AppPaths)
        @($paths | Where-Object { $_ -ceq (P (Get-ChromeRoot) 'ShaderCache') }).Count | Should -Be 1
        Test-AnyUnder @($paths | Where-Object { $_ -cne (P (Get-ChromeRoot) 'ShaderCache') }) (P (Get-ChromeRoot) 'ShaderCache') | Should -BeFalse
    }

    It 'CL-22 CL-33 offers ShaderCache but not the GPUCache folder inside it (real profile discovery)' {
        Clear-SwBrowserCaches
        $paths = @(Get-AppPaths)
        $paths | Should -Contain (P (Get-ChromeRoot) 'ShaderCache')
        $paths | Should -Not -Contain (P (Get-ChromeRoot) 'ShaderCache' 'GPUCache')
        $paths | Should -Not -Contain (P (Get-ChromeRoot) 'ShaderCache' 'Cache')
    }

    It 'CL-22 offers every path once, and none below another, in one run' {
        Clear-SwBrowserCaches
        $paths = @(Get-Offered)
        $paths.Count | Should -BeGreaterThan 20
        Test-Disjoint $paths | Should -BeTrue
    }

    It 'CL-22 offers every path once with TEMP set to the local Temp folder' {
        Set-Env 'TEMP' (P $script:Local 'Temp')
        Clear-SwBrowserCaches
        Test-Disjoint @(Get-Offered) | Should -BeTrue
    }

    It 'CL-33 B-1 discards every profile of a Chromium root when one profile cannot be read, but keeps the root leaves and the other roots' {
        Use-ItemFailure @((P (Get-ChromeRoot) 'Profile 2'))
        Clear-SwBrowserCaches
        $chrome = @(Get-AppPaths | Where-Object { Test-SameOrUnder $_ (Get-ChromeRoot) })
        $chrome | Should -Contain (P (Get-ChromeRoot) 'ShaderCache')
        $chrome | Should -Not -Contain (P (Get-ChromeRoot) 'Default' 'Cache')
        $chrome.Count | Should -Be 2
        $edge = @(Get-AppPaths | Where-Object { Test-SameOrUnder $_ (Get-EdgeRoot) })
        $edge | Should -Contain (P (Get-EdgeRoot) 'Default' 'Cache')
    }

    It 'B-5 offers the local Firefox cache leaves with the roaming lock file and Firefox cache as description' {
        Clear-SwBrowserCaches
        $local = P $script:Local 'Mozilla' 'Firefox' 'Profiles' 'p.default'
        $lock = P $script:Roam 'Mozilla' 'Firefox' 'Profiles' 'p.default' 'parent.lock'
        $expected = @(
            (ConvertTo-AppLine (P $local 'cache2') 'Firefox cache' 'firefox' $lock)
            (ConvertTo-AppLine (P $local 'startupCache') 'Firefox cache' 'firefox' $lock)
        ) | Sort-Object
        @(Get-AppLines (P $script:Local 'Mozilla')) | Should -Be @($expected)
    }

    It 'B-6 offers the shader cache of the roaming Firefox profile with the lock file of that profile and never its cache2' {
        Clear-SwBrowserCaches
        $roam = P $script:Roam 'Mozilla' 'Firefox' 'Profiles' 'p.default'
        $expected = @(ConvertTo-AppLine (P $roam 'shader-cache') 'Firefox cache' 'firefox' (P $roam 'parent.lock'))
        @(Get-AppLines (P $script:Roam 'Mozilla')) | Should -Be @($expected)
        @(Get-AppPaths) | Should -Not -Contain (P $roam 'cache2')
    }

    It 'B-7 offers the Opera leaves in both roots, in the root itself and in each profile, with the lock file of the root' {
        Clear-SwBrowserCaches
        foreach ($root in (P $script:Roam 'Opera Software' 'Opera Stable'), (P $script:Local 'Opera Software' 'Opera Stable')) {
            $lock = P $root 'lockfile'
            $expected = New-Object System.Collections.Generic.List[string]
            foreach ($candidate in $root, (P $root 'Default')) {
                foreach ($leaf in 'Cache', 'Code Cache', 'GPUCache') { $expected.Add((ConvertTo-AppLine (P $candidate $leaf) 'Opera cache' 'opera' $lock)) }
            }
            @(Get-AppLines $root) | Should -Be @($expected | Sort-Object)
        }
    }

    It 'CL-33 offers nothing outside the table: the user data next to the leaves is never named' {
        Clear-SwBrowserCaches
        $offered = @(Get-Offered)
        foreach ($root in (Get-ChromeRoot), (Get-EdgeRoot), (Get-BraveRoot), (Get-VivaldiRoot)) {
            foreach ($profile in 'Default', 'Profile 2', 'Profile [work]') {
                foreach ($private in $script:ChromiumPrivate) { Test-AnyUnder $offered (P $root $profile $private) | Should -BeFalse -Because "$root $profile $private" }
                Test-AnyUnder $offered (P $root $profile 'Service Worker') | Should -BeFalse
            }
            $offered | Should -Not -Contain (P $root 'Local State')
            $offered | Should -Not -Contain $root
        }
        Test-AnyUnder $offered (P $script:Roam 'Mozilla' 'Firefox' 'Profiles' 'p.default' 'prefs.js') | Should -BeFalse
        Test-AnyUnder $offered (P $script:Local 'Mozilla' 'Firefox' 'Profiles' 'p.default' 'storage') | Should -BeFalse
        Test-AnyUnder $offered (P $script:Roam 'Opera Software' 'Opera Stable' 'Default' 'Cookies') | Should -BeFalse
    }

    It 'CL-33 offers nothing at a root that is not in the table for Brave and Vivaldi (no root leaves)' {
        Clear-SwBrowserCaches
        @(Get-AppPaths) | Should -Not -Contain (P (Get-BraveRoot) 'ShaderCache')
        @(Get-AppPaths) | Should -Not -Contain (P (Get-VivaldiRoot) 'GrShaderCache')
        @(Get-AppPaths) | Should -Not -Contain (P (Get-EdgeRoot) 'GrShaderCache')
    }

    It 'CL-20 offers the other leaves, closes the section once and does not throw when the cache cleaner throws for the first leaf' {
        Mock Clear-SwAppCache { $script:AppCalls.Add([pscustomobject]@{ Path = $Path; Description = $Description; Processes = @($Processes); LockPath = $LockPath }); throw 'failure (test)' }
        { Clear-SwBrowserCaches } | Should -Not -Throw
        $script:AppCalls.Count | Should -BeGreaterThan 20
        @($script:Sections | Where-Object { $_ -eq 'stop' }).Count | Should -Be 1
    }

    It 'CL-20 closes the section once and does not throw when profile discovery throws' {
        Mock Get-SwCacheProfiles { throw 'failure (test)' }
        { Clear-SwBrowserCaches } | Should -Not -Throw
        @($script:Sections | Where-Object { $_ -eq 'stop' }).Count | Should -Be 1
        $script:AppCalls.Count | Should -BeGreaterThan 0
    }

    It 'SI-6 writes nothing to the pipeline' {
        Mock Clear-SwAppCache { 'noise'; $true }
        @(Clear-SwBrowserCaches).Count | Should -Be 0
    }

    It 'SI-2 removes nothing itself and calls no removal helper directly' {
        Clear-SwBrowserCaches
        $script:Calls.Count | Should -Be 0
    }

    It 'SI-4 asks the cache cleaner the same way in <Mode>' -ForEach $script:RunModes {
        Set-SwDryRunMode -Enabled $Dry
        Clear-SwBrowserCaches
        @(Get-AppLines (Get-ChromeRoot)).Count | Should -Be 11
    }
}

# ============================================================================
# Browser caches: the environment (CL-21, S-12, S-13, )
# ============================================================================

Describe 'Clear-SwBrowserCaches environment' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-AppCacheSpy
        New-RichFixture -Only Browser
    }
    AfterEach { Stop-Case }

    It 'CL-21 S-12 offers nothing below LOCALAPPDATA when it is <Label>, and the roaming targets still run' -ForEach $script:BadValues {
        Set-Env 'LOCALAPPDATA' $Value
        Clear-SwBrowserCaches
        $paths = @(Get-AppPaths)
        $paths.Count | Should -BeGreaterThan 0
        Test-AnyUnder $paths $script:Local | Should -BeFalse
        $paths | Should -Contain (P $script:Roam 'Opera Software' 'Opera Stable' 'Cache')
        $paths | Should -Contain (P $script:Roam 'Mozilla' 'Firefox' 'Profiles' 'p.default' 'shader-cache')
    }

    It 'CL-21 offers no Firefox leaf at all when APPDATA is <Label>, and Chrome still runs' -ForEach $script:BadValues {
        Set-Env 'APPDATA' $Value
        Clear-SwBrowserCaches
        $paths = @(Get-AppPaths)
        Test-AnyUnder $paths (P $script:Local 'Mozilla') | Should -BeFalse
        $paths | Should -Contain (P (Get-ChromeRoot) 'Default' 'Cache')
        $paths | Should -Contain (P (Get-ChromeRoot) 'ShaderCache')
    }

    It 'CL-21 builds every path from the trimmed value, with one separator, and starts it with that value' {
        Set-Env 'LOCALAPPDATA' ('  ' + $script:Local + $script:Sep + ' ')
        Set-Env 'APPDATA' (' ' + $script:Roam + $script:Sep)
        Clear-SwBrowserCaches
        $paths = @(Get-AppPaths)
        $paths | Should -Contain (P (Get-ChromeRoot) 'ShaderCache')
        $paths | Should -Contain (P $script:Roam 'Opera Software' 'Opera Stable' 'Cache')
        foreach ($path in $paths) {
            ($path.StartsWith($script:Local) -or $path.StartsWith($script:Roam)) | Should -BeTrue -Because $path
            $path.Contains($script:Sep + $script:Sep) | Should -BeFalse -Because $path
        }
    }

    It 'CL-21 S-13 takes LOCALAPPDATA literally: Max [A] never mixes with Max A' {
        $bracket = New-Dir (P $script:Work 'Max [A]' 'Local')
        $decoy = New-Dir (P $script:Work 'Max A' 'Local')
        $null = New-ChromiumRoot (P $bracket 'Google' 'Chrome' 'User Data') @('Default')
        $null = New-ChromiumRoot (P $decoy 'Google' 'Chrome' 'User Data') @('Default', 'Decoy')
        Set-Env 'LOCALAPPDATA' $bracket
        Clear-SwBrowserCaches
        $paths = @(Get-AppPaths)
        $paths | Should -Contain (P $bracket 'Google' 'Chrome' 'User Data' 'Default' 'Cache')
        Test-AnyUnder $paths $decoy | Should -BeFalse
    }

    It 'CL-21 S-13 takes APPDATA literally for the roaming Firefox profile' {
        $bracket = New-Dir (P $script:Work 'Max [A]' 'Roaming')
        $decoy = New-Dir (P $script:Work 'Max A' 'Roaming')
        $null = New-Leaf (P $bracket 'Mozilla' 'Firefox' 'Profiles' 'p.default' 'shader-cache')
        $null = New-Leaf (P $decoy 'Mozilla' 'Firefox' 'Profiles' 'p.default' 'shader-cache')
        Set-Env 'APPDATA' $bracket
        Clear-SwBrowserCaches
        Test-AnyUnder @(Get-AppPaths) $decoy | Should -BeFalse
        @(Get-AppPaths) | Should -Contain (P $bracket 'Mozilla' 'Firefox' 'Profiles' 'p.default' 'shader-cache')
    }
}

# ============================================================================
# Browser caches and application caches with the real helpers (CL-24, CL-33, CL-34, S-2, S-4, S-8, S-10)
# ============================================================================

Describe 'Browser caches with the real helpers' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-Collector
        Use-ProcessSpy
        New-RichFixture -Only Browser
    }
    AfterEach { Stop-Case }

    It 'CL-33 empties the leaves of every profile and keeps offline data and cookies in a real run' {
        Set-SwDryRunMode -Enabled $false
        Clear-SwBrowserCaches
        $root = Get-ChromeRoot
        foreach ($profile in 'Default', 'Profile 2', 'Profile [work]') {
            foreach ($leaf in 'Cache', 'Code Cache', 'GPUCache') {
                Exists (P $root $profile $leaf 'entry') | Should -BeFalse -Because "$profile $leaf"
                [System.IO.Directory]::Exists((P $root $profile $leaf)) | Should -BeTrue
            }
            Exists (P $root $profile 'Cookies' 'keep.dat') | Should -BeTrue
            Exists (P $root $profile 'Service Worker' 'CacheStorage' 'offline') | Should -BeTrue
            Exists (P $root $profile 'Local Storage' 'keep.dat') | Should -BeTrue
        }
        Exists (P $root 'ShaderCache' 'entry') | Should -BeFalse
        Exists (P $root 'GrShaderCache' 'entry') | Should -BeFalse
        Exists (P $root 'Local State') | Should -BeTrue
    }

    It 'CL-33 empties the local Firefox caches and the roaming shader cache and keeps the roaming cache2 and the profile data' {
        Set-SwDryRunMode -Enabled $false
        Clear-SwBrowserCaches
        $local = P $script:Local 'Mozilla' 'Firefox' 'Profiles' 'p.default'
        $roam = P $script:Roam 'Mozilla' 'Firefox' 'Profiles' 'p.default'
        Exists (P $local 'cache2' 'entry') | Should -BeFalse
        Exists (P $local 'startupCache' 'entry') | Should -BeFalse
        Exists (P $roam 'shader-cache' 'entry') | Should -BeFalse
        Exists (P $roam 'cache2' 'entry') | Should -BeTrue
        Exists (P $roam 'prefs.js') | Should -BeTrue
        Exists (P $local 'storage' 'keep.dat') | Should -BeTrue
    }

    It 'CL-33 empties the Opera leaves of both roots' {
        Set-SwDryRunMode -Enabled $false
        Clear-SwBrowserCaches
        Exists (P $script:Roam 'Opera Software' 'Opera Stable' 'Cache' 'entry') | Should -BeFalse
        Exists (P $script:Local 'Opera Software' 'Opera Stable' 'Default' 'Code Cache' 'entry') | Should -BeFalse
        Exists (P $script:Local 'Opera Software' 'Opera Stable' 'Default' 'Cookies' 'keep.dat') | Should -BeTrue
    }

    It 'S-10 keeps every leaf of the running browser and still cleans the others, in <Mode> ' -ForEach $script:RunModes {
        Set-SwDryRunMode -Enabled $Dry
        Use-ProcessSpy @('chrome')
        Clear-SwBrowserCaches
        Exists (P (Get-ChromeRoot) 'Default' 'Cache' 'entry') | Should -BeTrue
        Exists (P (Get-ChromeRoot) 'ShaderCache' 'entry') | Should -BeTrue
        if ($Dry) {
            $listed = @($script:DryRunCollector | ForEach-Object { $_.Path })
            Test-AnyUnder $listed (Get-ChromeRoot) | Should -BeFalse
            Test-AnyUnder $listed (Get-EdgeRoot) | Should -BeTrue
        }
        else { Exists (P (Get-EdgeRoot) 'Default' 'Cache' 'entry') | Should -BeFalse }
    }

    It 'S-10 keeps every leaf of every browser when the process list cannot be read' {
        Mock Get-Process { throw 'process list not readable (test)' }
        Set-SwDryRunMode -Enabled $false
        Clear-SwBrowserCaches
        Exists (P (Get-ChromeRoot) 'Default' 'Cache' 'entry') | Should -BeTrue
        Exists (P $script:Roam 'Opera Software' 'Opera Stable' 'Cache' 'entry') | Should -BeTrue
        (Get-SwCleanupStats).FilesCleaned | Should -Be 0
    }

    It 'CL-33 S-7 leaves the profiles of a Chromium root when one profile cannot be read, and Edge stays unaffected' {
        Set-SwDryRunMode -Enabled $false
        Use-ItemFailure @((P (Get-ChromeRoot) 'Profile 2'))
        Clear-SwBrowserCaches
        Exists (P (Get-ChromeRoot) 'Default' 'Cache' 'entry') | Should -BeTrue
        Exists (P (Get-ChromeRoot) 'ShaderCache' 'entry') | Should -BeFalse
        Exists (P (Get-EdgeRoot) 'Default' 'Cache' 'entry') | Should -BeFalse
    }

    It 'S-4 lists in a preview and changes nothing, in the same run that the real run removes' {
        $before = Get-Listing $script:Work
        Mock Remove-Item { throw 'Remove-Item must not run in a preview (test)' }
        Clear-SwBrowserCaches
        Same-Listing (Get-Listing $script:Work) $before | Should -BeTrue
        @($script:DryRunCollector).Count | Should -BeGreaterThan 20
        $script:Ops.Count | Should -Be 0
    }

    It 'S-8 counts exactly the paths it lists, and lists no path below another' {
        Clear-SwBrowserCaches
        (Get-SwCleanupStats).FilesCleaned | Should -Be @($script:DryRunCollector).Count
        Test-Disjoint @($script:DryRunCollector | ForEach-Object { $_.Path }) | Should -BeTrue
    }

    It 'S-2 removes nothing from a leaf that a whitelist line holds' {
        Set-SwDryRunMode -Enabled $false
        Set-Whitelist @((P (Get-ChromeRoot) 'Default' 'Cache'))
        Clear-SwBrowserCaches
        Exists (P (Get-ChromeRoot) 'Default' 'Cache' 'entry') | Should -BeTrue
        Exists (P (Get-ChromeRoot) 'Default' 'GPUCache' 'entry') | Should -BeFalse
    }
}

# ============================================================================
# Application caches: the calls (CL-34, CL-22, CL-20, S-17)
# ============================================================================

Describe 'Clear-SwAppCaches calls' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-AppCacheSpy
        Use-HelperSpies
        New-RichFixture -Only Apps
    }
    AfterEach { Stop-Case }

    It 'SI-1 opens the section Application caches once and closes it once' {
        Clear-SwAppCaches
        @($script:Sections) | Should -Be @('start:Application caches', 'stop')
    }

    It 'A-1 A-2 A-5 offers the three leaves of <Folder> through the cache cleaner, with description and process and no lock file, and no folder root' -ForEach $script:AppRows {
        Clear-SwAppCaches
        $root = P $script:Roam $Folder
        $expected = @($Leaves | ForEach-Object { ConvertTo-AppLine (P $root $_) $Description $Process '' } | Sort-Object)
        @(Get-AppLines $root) | Should -Be @($expected)
    }

    It 'A-3 offers Cache and GPUCache of the classic Teams client as Teams cache for the process Teams' {
        Clear-SwAppCaches
        $root = P $script:Roam 'Microsoft' 'Teams'
        $expected = @(
            (ConvertTo-AppLine (P $root 'Cache') 'Teams cache' 'Teams' '')
            (ConvertTo-AppLine (P $root 'GPUCache') 'Teams cache' 'Teams' '')
        ) | Sort-Object
        @(Get-AppLines $root) | Should -Be @($expected)
    }

    It 'A-3 keeps blob_storage, tmp, databases, IndexedDB and Local Storage of Teams out of every call' {
        Clear-SwAppCaches
        foreach ($name in 'blob_storage', 'tmp', 'databases', 'IndexedDB', 'Local Storage') {
            Test-AnyUnder @(Get-Offered) (P $script:Roam 'Microsoft' 'Teams' $name) | Should -BeFalse -Because $name
        }
    }

    It 'A-4 offers Cache, Code Cache and GPUCache of every profile of the new Teams, with the lock file of the root, and no root leaf' {
        Clear-SwAppCaches
        $root = Get-TeamsNewRoot
        $lock = P $root 'lockfile'
        $expected = New-Object System.Collections.Generic.List[string]
        foreach ($profile in 'Default', 'Profile 1') {
            foreach ($leaf in 'Cache', 'Code Cache', 'GPUCache') { $expected.Add((ConvertTo-AppLine (P $root $profile $leaf) 'Teams cache' 'ms-teams' $lock)) }
        }
        @(Get-AppLines $root) | Should -Be @($expected | Sort-Object)
        @(Get-AppPaths) | Should -Not -Contain (P $root 'Cache')
        Test-AnyUnder @(Get-Offered) (P $root 'Default' 'IndexedDB') | Should -BeFalse
    }

    It 'A-4 never offers the Teams package folder or another package' {
        Clear-SwAppCaches
        $offered = @(Get-Offered)
        $offered | Should -Not -Contain (P $script:Local 'Packages' 'MSTeams_8wekyb3d8bbwe')
        $offered | Should -Not -Contain (P (Get-TeamsNewRoot))
        Test-AnyUnder $offered (P $script:Local 'Packages' 'Other_app') | Should -BeFalse
    }

    It 'S-17 never names the offline data of any application: Spotify, Zoom, Local Storage, CacheStorage' {
        Clear-SwAppCaches
        $offered = @(Get-Offered)
        foreach ($path in (P $script:Roam 'Spotify'), (P $script:Roam 'Zoom')) { Test-AnyUnder $offered $path | Should -BeFalse -Because $path }
        foreach ($folder in 'discord', 'Slack', 'Cursor', 'Windsurf', 'Obsidian', 'Notion') {
            Test-AnyUnder $offered (P $script:Roam $folder 'Local Storage') | Should -BeFalse -Because $folder
            Test-AnyUnder $offered (P $script:Roam $folder 'Service Worker') | Should -BeFalse -Because $folder
        }
    }

    It 'SI-9 never offers what another section owns or what was removed: VS Code, Sublime, Zed, cpptools, Epic, Adobe, Steam' {
        Clear-SwAppCaches
        $offered = @(Get-Offered)
        foreach ($path in (P $script:Roam 'Code'), (P $script:Roam 'Code - Insiders'), (P $script:Roam 'Sublime Text'), (P $script:Local 'Sublime Text'),
            (P $script:Local 'Zed'), (P $script:Local 'Microsoft' 'vscode-cpptools'), (P $script:Local 'EpicGamesLauncher'), (P $script:Roam 'Adobe'), (P $script:Local 'Steam')) {
            Test-AnyUnder $offered $path | Should -BeFalse -Because $path
        }
    }

    It 'CL-34 never offers the root folder of an application, only the named leaves' {
        Clear-SwAppCaches
        $offered = @(Get-Offered)
        foreach ($folder in 'discord', 'Slack', 'Cursor', 'Windsurf', 'Obsidian', 'Notion') { $offered | Should -Not -Contain (P $script:Roam $folder) }
        $offered | Should -Not -Contain (P $script:Roam 'Microsoft' 'Teams')
    }

    It 'CL-22 offers every path once, and none below another, in one run' {
        Clear-SwAppCaches
        $paths = @(Get-Offered)
        $paths.Count | Should -Be (6 * 3 + 2 + 6)
        Test-Disjoint $paths | Should -BeTrue
    }

    It 'CL-34 asks Get-SwCacheProfiles once, for the root of the new Teams' {
        Mock Get-SwCacheProfiles { }
        Clear-SwAppCaches
        Should -Invoke Get-SwCacheProfiles -Times 1 -Exactly
        Should -Invoke Get-SwCacheProfiles -Times 1 -Exactly -ParameterFilter { (Fold $Root) -eq (Fold (Get-TeamsNewRoot)) }
    }

    It 'CL-20 offers the other leaves, closes the section once and does not throw when the cache cleaner throws for the first leaf' {
        Mock Clear-SwAppCache { $script:AppCalls.Add([pscustomobject]@{ Path = $Path; Description = $Description; Processes = @($Processes); LockPath = $LockPath }); throw 'failure (test)' }
        { Clear-SwAppCaches } | Should -Not -Throw
        $script:AppCalls.Count | Should -Be 26
        @($script:Sections | Where-Object { $_ -eq 'stop' }).Count | Should -Be 1
    }

    It 'SI-6 writes nothing to the pipeline' {
        Mock Clear-SwAppCache { 'noise'; $true }
        @(Clear-SwAppCaches).Count | Should -Be 0
    }

    It 'SI-2 removes nothing itself' {
        Clear-SwAppCaches
        $script:Calls.Count | Should -Be 0
    }
}

Describe 'Clear-SwAppCaches environment' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-AppCacheSpy
        New-RichFixture -Only Apps
    }
    AfterEach { Stop-Case }

    It 'CL-21 S-12 offers nothing below APPDATA when it is <Label>, and the new Teams still runs' -ForEach $script:BadValues {
        Set-Env 'APPDATA' $Value
        Clear-SwAppCaches
        $paths = @(Get-AppPaths)
        Test-AnyUnder $paths $script:Roam | Should -BeFalse
        $paths | Should -Contain (P (Get-TeamsNewRoot) 'Default' 'Cache')
    }

    It 'CL-21 S-12 offers nothing below LOCALAPPDATA when it is <Label>, and the roaming applications still run' -ForEach $script:BadValues {
        Set-Env 'LOCALAPPDATA' $Value
        Clear-SwAppCaches
        $paths = @(Get-AppPaths)
        Test-AnyUnder $paths $script:Local | Should -BeFalse
        $paths | Should -Contain (P $script:Roam 'Slack' 'Cache')
    }

    It 'CL-21 builds every path from the trimmed value, with one separator' {
        Set-Env 'LOCALAPPDATA' ('  ' + $script:Local + $script:Sep + ' ')
        Set-Env 'APPDATA' (' ' + $script:Roam + $script:Sep)
        Clear-SwAppCaches
        $paths = @(Get-AppPaths)
        $paths | Should -Contain (P $script:Roam 'Slack' 'Cache')
        $paths | Should -Contain (P (Get-TeamsNewRoot) 'Default' 'Cache')
        foreach ($path in $paths) { $path.Contains($script:Sep + $script:Sep) | Should -BeFalse -Because $path }
    }

    It 'CL-21 S-13 takes APPDATA literally: Max [A] never mixes with Max A' {
        $bracket = New-Dir (P $script:Work 'Max [A]' 'Roaming')
        $decoy = New-Dir (P $script:Work 'Max A' 'Roaming')
        $null = New-Leaf (P $bracket 'Slack' 'Cache')
        $null = New-Leaf (P $decoy 'Slack' 'Cache')
        Set-Env 'APPDATA' $bracket
        Clear-SwAppCaches
        @(Get-AppPaths) | Should -Contain (P $bracket 'Slack' 'Cache')
        Test-AnyUnder @(Get-AppPaths) $decoy | Should -BeFalse
    }

    It 'CL-21 S-13 takes LOCALAPPDATA literally for the profiles of the new Teams' {
        $bracket = New-Dir (P $script:Work 'Max [A]' 'Local')
        $decoy = New-Dir (P $script:Work 'Max A' 'Local')
        foreach ($base in $bracket, $decoy) {
            $root = P $base 'Packages' 'MSTeams_8wekyb3d8bbwe' 'LocalCache' 'Microsoft' 'MSTeams' 'EBWebView'
            $null = New-Leaf (P $root 'Default' 'Cache')
        }
        $null = New-Leaf (P $decoy 'Packages' 'MSTeams_8wekyb3d8bbwe' 'LocalCache' 'Microsoft' 'MSTeams' 'EBWebView' 'Decoy' 'Cache')
        Set-Env 'LOCALAPPDATA' $bracket
        Clear-SwAppCaches
        Test-AnyUnder @(Get-AppPaths) $decoy | Should -BeFalse
    }
}

Describe 'Application caches with the real helpers' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-Collector
        Use-ProcessSpy
        New-RichFixture -Only Apps
    }
    AfterEach { Stop-Case }

    It 'A-2 empties the Slack leaves and keeps its offline data and local storage in a real run' {
        Set-SwDryRunMode -Enabled $false
        Clear-SwAppCaches
        foreach ($leaf in 'Cache', 'Code Cache', 'GPUCache') { Exists (P $script:Roam 'Slack' $leaf 'entry') | Should -BeFalse -Because $leaf }
        Exists (P $script:Roam 'Slack' 'Service Worker' 'CacheStorage' 'offline') | Should -BeTrue
        Exists (P $script:Roam 'Slack' 'Local Storage' 'keep.dat') | Should -BeTrue
        [System.IO.Directory]::Exists((P $script:Roam 'Slack')) | Should -BeTrue
    }

    It 'A-3 empties Cache and GPUCache of classic Teams and keeps blob_storage and tmp' {
        Set-SwDryRunMode -Enabled $false
        Clear-SwAppCaches
        Exists (P $script:Roam 'Microsoft' 'Teams' 'Cache' 'entry') | Should -BeFalse
        Exists (P $script:Roam 'Microsoft' 'Teams' 'GPUCache' 'entry') | Should -BeFalse
        Exists (P $script:Roam 'Microsoft' 'Teams' 'blob_storage' 'keep.dat') | Should -BeTrue
        Exists (P $script:Roam 'Microsoft' 'Teams' 'tmp' 'keep.dat') | Should -BeTrue
    }

    It 'A-4 empties the profile leaves of the new Teams with the guard on and keeps its state, root leaves and other packages' {
        Set-SwDryRunMode -Enabled $false
        Clear-SwAppCaches
        $root = Get-TeamsNewRoot
        foreach ($profile in 'Default', 'Profile 1') {
            foreach ($leaf in 'Cache', 'Code Cache', 'GPUCache') { Exists (P $root $profile $leaf 'entry') | Should -BeFalse -Because "$profile $leaf" }
            Exists (P $root $profile 'IndexedDB' 'state') | Should -BeTrue
        }
        Exists (P $root 'Cache' 'entry') | Should -BeTrue
        Exists (P $script:Local 'Packages' 'Other_app' 'LocalCache' 'Default' 'Cache' 'entry') | Should -BeTrue
    }

    It 'A-4 leaves the new Teams leaves alone when the clean guard is off' {
        Set-SwDryRunMode -Enabled $false
        $script:SweeprCleanPathGuard = $false
        Clear-SwAppCaches
        Exists (P (Get-TeamsNewRoot) 'Default' 'Cache' 'entry') | Should -BeTrue
    }

    It 'S-2 A-4 keeps the new Teams leaves that a whitelist line holds' {
        Set-SwDryRunMode -Enabled $false
        Set-Whitelist @((P (Get-TeamsNewRoot) 'Default' 'Cache'))
        Clear-SwAppCaches
        Exists (P (Get-TeamsNewRoot) 'Default' 'Cache' 'entry') | Should -BeTrue
        Exists (P (Get-TeamsNewRoot) 'Default' 'GPUCache' 'entry') | Should -BeFalse
    }

    It 'S-2 A-4 [W] keeps all new Teams leaves when the whitelist names the Packages folder with a wildcard' {
        Set-SwDryRunMode -Enabled $false
        $null = Set-Whitelist @($script:Local + '\Packages\*')
        Clear-SwAppCaches
        Exists (P (Get-TeamsNewRoot) 'Default' 'Cache' 'entry') | Should -BeTrue
        Exists (P (Get-TeamsNewRoot) 'Default' 'GPUCache' 'entry') | Should -BeTrue
    }

    It 'S-10 A-5 keeps the Cursor cache while Cursor runs, in <Mode> ' -ForEach $script:RunModes {
        Set-SwDryRunMode -Enabled $Dry
        Use-ProcessSpy @('Cursor')
        Clear-SwAppCaches
        Exists (P $script:Roam 'Cursor' 'Cache' 'entry') | Should -BeTrue
        Exists (P $script:Roam 'Slack' 'Cache' 'entry') | Should -Be $Dry
        if ($Dry) { Test-AnyUnder @($script:DryRunCollector | ForEach-Object { $_.Path }) (P $script:Roam 'Cursor') | Should -BeFalse }
    }

    It 'S-10 A-5 keeps the Cursor cache when the process list cannot be read, and removes it when nobody runs it' {
        Set-SwDryRunMode -Enabled $false
        Mock Get-Process { throw 'process list not readable (test)' }
        Clear-SwAppCaches
        Exists (P $script:Roam 'Cursor' 'Cache' 'entry') | Should -BeTrue
        Use-ProcessSpy
        Clear-SwAppCaches
        Exists (P $script:Roam 'Cursor' 'Cache' 'entry') | Should -BeFalse
    }

    It 'S-4 lists in a preview and changes nothing' {
        $before = Get-Listing $script:Work
        Mock Remove-Item { throw 'Remove-Item must not run in a preview (test)' }
        Clear-SwAppCaches
        Same-Listing (Get-Listing $script:Work) $before | Should -BeTrue
        @($script:DryRunCollector).Count | Should -BeGreaterThan 15
        $script:Ops.Count | Should -Be 0
    }

    It 'S-8 counts exactly the paths it lists, and lists no path below another' {
        Clear-SwAppCaches
        (Get-SwCleanupStats).FilesCleaned | Should -Be @($script:DryRunCollector).Count
        Test-Disjoint @($script:DryRunCollector | ForEach-Object { $_.Path }) | Should -BeTrue
    }
}

# ============================================================================
# GPU shader caches (CL-35, CL-21, CL-21a, CL-22, CL-28)
# ============================================================================

Describe 'Clear-SwGpuShaderCaches' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-AppCacheSpy
        Use-HelperSpies
    }
    AfterEach { Stop-Case }

    It 'SI-1 CL-35 opens the section GPU shader caches once and closes it once, also when no folder exists' {
        Clear-SwGpuShaderCaches
        @($script:Sections) | Should -Be @('start:GPU shader caches', 'stop')
        $script:Calls.Count | Should -Be 0
    }

    It 'CL-35 <Id> offers the folder once through Clear-SwDirectoryContents with its description and without a condition' -ForEach $script:GpuRows {
        $value = [System.Environment]::GetEnvironmentVariable($Base)
        $parts = @($Rest)
        $folder = New-Leaf (P $value @parts)
        Clear-SwGpuShaderCaches
        $calls = @(Get-Calls 'Clear-SwDirectoryContents')
        $calls.Count | Should -Be 1
        $script:Calls.Count | Should -Be 1
        $calls[0].Path | Should -BeExactly $folder
        $calls[0].Description | Should -BeExactly $Description
        $calls[0].CanRemove | Should -BeNullOrEmpty
    }

    It 'CL-35 offers a folder that exists, nothing else: all twelve folders give twelve calls with these descriptions' {
        New-RichFixture -Only Gpu
        Clear-SwGpuShaderCaches
        $calls = @(Get-Calls 'Clear-SwDirectoryContents')
        $calls.Count | Should -Be 12
        @($calls | ForEach-Object { $_.Description } | Sort-Object -Unique) | Should -Be @('AMD shader cache', 'DirectX pipeline cache', 'DirectX shader cache', 'Intel shader cache', 'NVIDIA shader cache', 'Vulkan pipeline cache')
    }

    It 'CL-35 keeps the folder itself: it asks for the contents, never for the folder to be removed' {
        $null = New-Leaf (P $script:Local 'D3DSCache')
        Clear-SwGpuShaderCaches
        $script:Calls.Count | Should -Be 1
        @($script:Calls | Where-Object { $_.Fn -ne 'Clear-SwDirectoryContents' }).Count | Should -Be 0
    }

    It 'CL-35 asks for no process and uses no cache cleaner (no owner probe)' {
        New-RichFixture -Only Gpu
        Use-ProcessSpy
        Clear-SwGpuShaderCaches
        $script:ProcCalls.Count | Should -Be 0
        $script:AppCalls.Count | Should -Be 0
    }

    It 'CL-35 offers nothing and says nothing for folders that do not exist' {
        Clear-SwGpuShaderCaches
        $script:Calls.Count | Should -Be 0
        $script:NotMeasured.Count | Should -Be 0
    }

    It 'CL-21 S-12 offers nothing below LOCALAPPDATA when it is <Label>, and the other targets still run' -ForEach $script:BadValues {
        New-RichFixture -Only Gpu
        Set-Env 'LOCALAPPDATA' $Value
        Clear-SwGpuShaderCaches
        $paths = @(Get-CallPaths)
        Test-AnyUnder $paths $script:Local | Should -BeFalse
        $paths | Should -Contain (P $script:Roam 'Intel' 'ShaderCache')
        $paths | Should -Contain (P $script:Scratch 'NVIDIA Corporation' 'NV_Cache')
    }

    It 'CL-21 S-12 offers nothing below APPDATA when it is <Label>' -ForEach $script:BadValues {
        New-RichFixture -Only Gpu
        Set-Env 'APPDATA' $Value
        Clear-SwGpuShaderCaches
        $paths = @(Get-CallPaths)
        Test-AnyUnder $paths $script:Roam | Should -BeFalse
        $paths.Count | Should -Be 11
    }

    It 'CL-21 S-12 offers nothing for G-4 when TEMP is <Label>, and the other eleven folders still run' -ForEach $script:BadValues {
        New-RichFixture -Only Gpu
        Set-Env 'TEMP' $Value
        Clear-SwGpuShaderCaches
        @(Get-CallPaths).Count | Should -Be 11
    }

    It 'CL-21a CL-28 G-4 leaves out an implausible TEMP and notes NVIDIA shader cache as not verified: <Label>' -ForEach @(
        @{ Label = 'the user profile'; Make = { $script:Profile } }
        @{ Label = 'a parent of the profile'; Make = { $script:Work } }
        @{ Label = 'a path with a parent segment'; Make = { $null = New-Dir (P $script:Profile 'y'); $script:Profile + $script:Sep + 'x' + $script:Sep + '..' + $script:Sep + 'y' } }
    ) {
        New-RichFixture -Only Gpu
        $temp = & $Make
        $null = New-Leaf (P $temp 'NVIDIA Corporation' 'NV_Cache')
        Set-Env 'TEMP' $temp
        Clear-SwGpuShaderCaches
        $offered = @(Get-CallPaths)
        $offered.Count | Should -Be 11
        Test-AnyUnder $offered (P $temp 'NVIDIA Corporation') | Should -BeFalse
        $script:NotMeasured.Count | Should -Be 1
        $script:NotMeasured[0].Name | Should -BeExactly 'NVIDIA shader cache'
        $script:NotMeasured[0].Reason | Should -BeExactly 'not verified'
    }

    It 'CL-22 offers every path once, and none below another, also with TEMP set to the local Temp folder' {
        New-RichFixture -Only Gpu
        Set-Env 'TEMP' (P $script:Local 'Temp')
        $null = New-Leaf (P $script:Local 'Temp' 'NVIDIA Corporation' 'NV_Cache')
        Clear-SwGpuShaderCaches
        $paths = @(Get-CallPaths)
        $paths.Count | Should -Be 12
        Test-Disjoint $paths | Should -BeTrue
    }

    It 'CL-21 builds every path from the trimmed value, with one separator' {
        New-RichFixture -Only Gpu
        Set-Env 'LOCALAPPDATA' ('  ' + $script:Local + $script:Sep + ' ')
        Set-Env 'APPDATA' (' ' + $script:Roam + $script:Sep)
        Clear-SwGpuShaderCaches
        $paths = @(Get-CallPaths)
        $paths | Should -Contain (P $script:Local 'D3DSCache')
        $paths | Should -Contain (P $script:Roam 'Intel' 'ShaderCache')
        foreach ($path in $paths) { $path.Contains($script:Sep + $script:Sep) | Should -BeFalse -Because $path }
    }

    It 'CL-21 S-13 takes LOCALAPPDATA literally: Max [A] never mixes with Max A' {
        $bracket = New-Dir (P $script:Work 'Max [A]' 'Local')
        $decoy = New-Dir (P $script:Work 'Max A' 'Local')
        $null = New-Leaf (P $bracket 'D3DSCache')
        $null = New-Leaf (P $decoy 'D3DSCache')
        Set-Env 'LOCALAPPDATA' $bracket
        Clear-SwGpuShaderCaches
        @(Get-CallPaths) | Should -Be @((P $bracket 'D3DSCache'))
    }

    It 'CL-20 offers the other folders, closes the section once and does not throw when the helper throws for the first folder' {
        New-RichFixture -Only Gpu
        $script:Seen = [System.Collections.Generic.List[string]]::new()
        Mock Clear-SwDirectoryContents { $script:Seen.Add([string]$Path); throw 'failure (test)' }
        { Clear-SwGpuShaderCaches } | Should -Not -Throw
        $script:Seen.Count | Should -Be 12
        @($script:Sections | Where-Object { $_ -eq 'stop' }).Count | Should -Be 1
    }

    It 'SI-6 writes nothing to the pipeline' {
        New-RichFixture -Only Gpu
        Mock Clear-SwDirectoryContents { 'noise'; $true }
        @(Clear-SwGpuShaderCaches).Count | Should -Be 0
    }

    It 'SI-4 asks the helper the same way in <Mode>' -ForEach $script:RunModes {
        New-RichFixture -Only Gpu
        Set-SwDryRunMode -Enabled $Dry
        Clear-SwGpuShaderCaches
        (Get-Calls 'Clear-SwDirectoryContents').Count | Should -Be 12
    }
}

Describe 'Clear-SwGpuShaderCaches with the real helpers' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-Collector
        New-RichFixture -Only Gpu
    }
    AfterEach { Stop-Case }

    It 'CL-35 empties the folders and keeps the folders themselves in a real run' {
        Set-SwDryRunMode -Enabled $false
        Clear-SwGpuShaderCaches
        foreach ($folder in (P $script:Local 'NVIDIA' 'DXCache'), (P $script:Local 'D3DSCache'), (P $script:Roam 'Intel' 'ShaderCache'), (P $script:Scratch 'NVIDIA Corporation' 'NV_Cache')) {
            Exists (P $folder 'entry') | Should -BeFalse -Because $folder
            [System.IO.Directory]::Exists($folder) | Should -BeTrue -Because $folder
        }
        (Get-SwCleanupStats).FilesCleaned | Should -Be 12
    }

    It 'S-4 lists the twelve folders in a preview and changes nothing' {
        $before = Get-Listing $script:Work
        Mock Remove-Item { throw 'Remove-Item must not run in a preview (test)' }
        Clear-SwGpuShaderCaches
        Same-Listing (Get-Listing $script:Work) $before | Should -BeTrue
        @($script:DryRunCollector).Count | Should -Be 12
        (Get-SwCleanupStats).FilesCleaned | Should -Be 12
    }

    It 'S-2 keeps a folder that a whitelist line holds' {
        Set-SwDryRunMode -Enabled $false
        Set-Whitelist @((P $script:Local 'D3DSCache'))
        Clear-SwGpuShaderCaches
        Exists (P $script:Local 'D3DSCache' 'entry') | Should -BeTrue
        Exists (P $script:Local 'VulkanCache' 'entry') | Should -BeFalse
    }
}

# ============================================================================
# All three sections: paths and the catalog (S-12, S-17)
# ============================================================================

Describe 'caches.ps1 paths' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-AppCacheSpy
        Use-HelperSpies
        New-RichFixture
    }
    AfterEach { Stop-Case }

    It 'S-12 hands every path to a helper starting with the trimmed value of one of the variables' {
        Set-Env 'LOCALAPPDATA' ('  ' + $script:Local + '  ')
        Set-Env 'APPDATA' ('  ' + $script:Roam + '  ')
        Set-Env 'TEMP' ('  ' + $script:Scratch + '  ')
        Clear-SwBrowserCaches
        Clear-SwAppCaches
        Clear-SwGpuShaderCaches
        $roots = @($script:Local, $script:Roam, $script:Scratch)
        $paths = @(Get-Offered)
        $paths.Count | Should -BeGreaterThan 60
        foreach ($path in $paths) {
            @($roots | Where-Object { $path.StartsWith($_, [System.StringComparison]::Ordinal) }).Count | Should -BeGreaterOrEqual 1 -Because $path
        }
    }

    It 'S-17 offers nothing that is not in the tables: the number of calls of the three sections is fixed by the fixture' {
        Clear-SwBrowserCaches
        Clear-SwAppCaches
        Clear-SwGpuShaderCaches
        @(Get-AppPaths).Count | Should -Be 80
        @(Get-CallPaths).Count | Should -Be 12
    }
}
