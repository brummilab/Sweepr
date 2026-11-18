# Sweepr - tests for lib\clean\cache_guard.ps1: the owner probe, the cache cleaner for one folder and
# the profile discovery that browser, application and developer-tool caches share.
#
# The rule numbers in the test names (CL-, SI-, S-, K- and so on) number the rules and the
# safety invariants of the cleanup core's behavior; each rule and invariant has at least one test.
# The other clean test files are SwCleanMain, SwCleanRun, SwCleanEditor (the command script),
# SwCleanUser, SwCleanCaches, SwCleanSystem (the sections) and SwCleanSafety (static and cross checks).
#
# Interface pinned here (new names; each old name that still has a caller stays as a forwarding
# function, not an alias; Get-SweeprCacheProfiles has no forwarder):
#   Test-SwCacheOwnerIdle -Names [-LockPath]                       one [bool], never throws
#   Clear-SwAppCache -Path -Description -Processes [-LockPath]     nothing to the pipeline, never throws
#   Get-SwCacheProfiles -Root                                      zero or more [System.IO.DirectoryInfo], one by one
#   Old names: Test-SweeprCacheOwnerIdle, Clear-SweeprAppCache
#
# Seams used with Mock: Get-Process (one call per owner evaluation), Get-SwPathSnapshot and
# Test-SwPathSnapshot (substitute objects, as the real ones give nothing on this host), Test-SwSafePath,
# Test-SwCacheOwnerIdle, Clear-SwDirectoryContents, Get-Item (the profile read), Get-SwValidatedTreeSize
# (a hook between measuring and removing), Add-SwNotMeasured, the writers of the log module and
# Write-SweeprOperation (the operations log writer the helpers use).
#
# Platform notes:
#   - Paths are built from $TestDrive with the separator of the host (host paths).
#   - Real removals happen only below $TestDrive, with the identity functions replaced by fakes; the
#     removal helpers themselves are the real ones. Nothing real is touched: no registry, no network,
#     no real processes (Get-Process is mocked except in the two tests that say so), no real operations log.
#   - Tests marked [W] need real Windows (real file identity, a handle that holds a file with
#     FileShare.None, junctions). They are meant to fail on Linux and belong in
#     tests/linux-known-failures.txt.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    $script:RunModes = @(
        @{ Mode = 'a preview'; Dry = $true }
        @{ Mode = 'a real run'; Dry = $false }
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

    $script:GuardFile = [System.IO.Path]::Combine($script:CleanDir, 'cache_guard.ps1')
    . $script:GuardFile
    $script:RealGetItem = Get-Command -Name Get-Item -CommandType Cmdlet
    $script:RealTreeSizeBlock = $null
    $treeSize = Get-Command -Name Get-SwValidatedTreeSize -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $treeSize) { $script:RealTreeSizeBlock = $treeSize.ScriptBlock }

    # A profile root with the given folders; gives the root path.
    function script:New-ProfileRoot([string[]]$Names, [string]$Root = '') {
        if ([string]::IsNullOrEmpty($Root)) { $Root = P $script:Local 'Google' 'Chrome' 'User Data' }
        $null = New-Dir $Root
        foreach ($name in $Names) { $null = New-Dir (P $Root $name) }
        $Root
    }
    function script:Get-Profiles([string]$Root) { , @(Get-SwCacheProfiles -Root $Root) }
    function script:Get-ProfileNames($Profiles) { , @($Profiles | ForEach-Object { $_.Name } | Sort-Object) }
    # Get-Item as a spy that reads like the real one; $script:ItemBehavior maps a folder name to
    # 'throw', 'noattr' (a result without Attributes) or 'reparse' (a result with the link attribute).
    function script:Use-ItemSpy {
        $script:ItemCalls = [System.Collections.Generic.List[object]]::new()
        $script:ItemBehavior = @{}
        Mock Get-Item {
            $leaf = [System.IO.Path]::GetFileName(([string]$LiteralPath).TrimEnd('\', '/'))
            $script:ItemCalls.Add([pscustomobject]@{ LiteralPath = [string]$LiteralPath; Name = $leaf })
            $behavior = $script:ItemBehavior[$leaf]
            if ($behavior -eq 'throw') { throw 'access denied (test)' }
            if ($behavior -eq 'noattr') { return [pscustomobject]@{ FullName = [string]$LiteralPath; Name = $leaf; PSIsContainer = $true } }
            if ($behavior -eq 'reparse') { return [pscustomobject]@{ FullName = [string]$LiteralPath; Name = $leaf; PSIsContainer = $true; Attributes = ([System.IO.FileAttributes]'Directory, ReparsePoint') } }
            & $script:RealGetItem -LiteralPath $LiteralPath -Force -ErrorAction Stop
        }
    }
    # The idle probe as a spy with a fixed answer.
    function script:Use-IdleSpy([bool]$Answer) {
        $script:IdleAnswer = $Answer
        $script:IdleCalls = [System.Collections.Generic.List[object]]::new()
        Mock Test-SwCacheOwnerIdle {
            $script:IdleCalls.Add([pscustomobject]@{ Names = @($Names); LockPath = $LockPath })
            $script:IdleAnswer
        }
    }
    # The process list as a spy. Mode Always: the named processes run from the first call; Never: nothing
    # runs; Deferred: they run once $script:OwnerActive is set (a hook does that); From: they run from the
    # FromCall-th call on; Throws: the list cannot be read.
    function script:Use-ProcessSpy([string[]]$Running = @(), [string]$Mode = 'Always', [int]$FromCall = 0) {
        $script:ProcCalls = [System.Collections.Generic.List[object]]::new()
        $script:ProcRunning = @($Running)
        $script:ProcMode = $Mode
        $script:ProcFrom = $FromCall
        $script:OwnerActive = $false
        Mock Get-Process {
            $script:ProcCalls.Add(@($PSBoundParameters.Keys))
            if ($script:ProcMode -eq 'Throws') { throw 'process list not readable (test)' }
            $active = $false
            if ($script:ProcMode -eq 'Always') { $active = $true }
            if ($script:ProcMode -eq 'Deferred') { $active = $script:OwnerActive }
            if ($script:ProcMode -eq 'From') { $active = ($script:ProcCalls.Count -ge $script:ProcFrom) }
            if (-not $active) { return @() }
            @($script:ProcRunning | ForEach-Object { [pscustomobject]@{ ProcessName = $_ } })
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
# Interface and old names
# ============================================================================

Describe 'cache_guard.ps1 interface' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
    }

    It 'defines the three shared functions and the two forwarding names' {
        Assert-Defined @('Test-SwCacheOwnerIdle', 'Clear-SwAppCache', 'Get-SwCacheProfiles', 'Test-SweeprCacheOwnerIdle', 'Clear-SweeprAppCache')
    }

    It 'CL-25 gives Get-SweeprCacheProfiles no forwarder' {
        Assert-Defined @('Get-SwCacheProfiles')
        Get-Command -Name Get-SweeprCacheProfiles -CommandType Function -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'CL-23 Test-SwCacheOwnerIdle takes Names (string[]) and LockPath (string, default empty)' {
        (Get-ParamLine 'Test-SwCacheOwnerIdle' 'Names').StartsWith('Names|System.String[]|') | Should -BeTrue
        $lock = Get-ParamLine 'Test-SwCacheOwnerIdle' 'LockPath'
        $lock.StartsWith('LockPath|System.String|') | Should -BeTrue
        $lock.EndsWith("|default=''") | Should -BeTrue
    }

    It 'CL-24 Clear-SwAppCache takes Path, Description, Processes and LockPath (default empty)' {
        (Get-ParamLine 'Clear-SwAppCache' 'Path').StartsWith('Path|System.String|') | Should -BeTrue
        (Get-ParamLine 'Clear-SwAppCache' 'Description').StartsWith('Description|System.String|') | Should -BeTrue
        (Get-ParamLine 'Clear-SwAppCache' 'Processes').StartsWith('Processes|System.String[]|') | Should -BeTrue
        $lock = Get-ParamLine 'Clear-SwAppCache' 'LockPath'
        $lock.StartsWith('LockPath|System.String|') | Should -BeTrue
        $lock.EndsWith("|default=''") | Should -BeTrue
    }

    It 'CL-25 Get-SwCacheProfiles takes Root (string)' {
        (Get-ParamLine 'Get-SwCacheProfiles' 'Root').StartsWith('Root|System.String|') | Should -BeTrue
    }

    It 'keeps the old signature of Test-SweeprCacheOwnerIdle (Names at 0, LockPath at 1 with an empty default)' {
        (Get-ParamLine 'Test-SweeprCacheOwnerIdle' 'Names') | Should -Be 'Names|System.String[]|pos=0|mandatory=False|default='
        (Get-ParamLine 'Test-SweeprCacheOwnerIdle' 'LockPath') | Should -Be "LockPath|System.String|pos=1|mandatory=False|default=''"
    }

    It 'keeps the old signature of Clear-SweeprAppCache (positions 0 to 3, LockPath default empty)' {
        (Get-ParamLine 'Clear-SweeprAppCache' 'Path') | Should -Be 'Path|System.String|pos=0|mandatory=False|default='
        (Get-ParamLine 'Clear-SweeprAppCache' 'Description') | Should -Be 'Description|System.String|pos=1|mandatory=False|default='
        (Get-ParamLine 'Clear-SweeprAppCache' 'Processes') | Should -Be 'Processes|System.String[]|pos=2|mandatory=False|default='
        (Get-ParamLine 'Clear-SweeprAppCache' 'LockPath') | Should -Be "LockPath|System.String|pos=3|mandatory=False|default=''"
    }
}

Describe 'cache_guard.ps1 forwarders' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
    }
    AfterEach { Stop-Case }

    It 'Test-SweeprCacheOwnerIdle calls Test-SwCacheOwnerIdle once with what was given and returns its answer' {
        $script:Seen = [System.Collections.Generic.List[object]]::new()
        Mock Test-SwCacheOwnerIdle { $script:Seen.Add([pscustomobject]@{ Names = @($Names); LockPath = $LockPath }); $true }
        $answer = Test-SweeprCacheOwnerIdle @('Example', 'Other') (P $script:Work 'lock')
        $answer | Should -BeTrue
        $script:Seen.Count | Should -Be 1
        $script:Seen[0].Names | Should -Be @('Example', 'Other')
        $script:Seen[0].LockPath | Should -BeExactly (P $script:Work 'lock')
    }

    It 'Test-SweeprCacheOwnerIdle returns a $false answer unchanged' {
        Mock Test-SwCacheOwnerIdle { $false }
        $answer = @(Test-SweeprCacheOwnerIdle -Names @('Example'))
        $answer.Count | Should -Be 1
        $answer[0] | Should -BeFalse
    }

    It 'Clear-SweeprAppCache calls Clear-SwAppCache once with what was given' {
        $script:Seen = [System.Collections.Generic.List[object]]::new()
        Mock Clear-SwAppCache { $script:Seen.Add([pscustomobject]@{ Path = $Path; Description = $Description; Processes = @($Processes); LockPath = $LockPath }) }
        Clear-SweeprAppCache (P $script:Work 'cache') 'Example cache' @('example') (P $script:Work 'lock')
        $script:Seen.Count | Should -Be 1
        $script:Seen[0].Path | Should -BeExactly (P $script:Work 'cache')
        $script:Seen[0].Description | Should -BeExactly 'Example cache'
        $script:Seen[0].Processes | Should -Be @('example')
        $script:Seen[0].LockPath | Should -BeExactly (P $script:Work 'lock')
    }
}

# ============================================================================
# Test-SwCacheOwnerIdle (CL-23, S-10)
# ============================================================================

Describe 'Test-SwCacheOwnerIdle' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-ProcessSpy -Mode Never
        $script:Names = @('sweepr-fixture-' + [guid]::NewGuid().ToString('N'))
    }
    AfterEach { Stop-Case }

    It 'CL-23 step 1 gives $false for no names and does not ask for processes' -ForEach @(
        @{ Label = 'an empty array'; Value = @() }
        @{ Label = 'null'; Value = $null }
    ) {
        $answer = @(Test-SwCacheOwnerIdle -Names $Value)
        $answer.Count | Should -Be 1
        $answer[0] | Should -BeOfType [bool]
        $answer[0] | Should -BeFalse
        $script:ProcCalls.Count | Should -Be 0
    }

    It 'CL-23 step 2 asks Get-Process once, with -ErrorAction Stop and nothing else' {
        $null = Test-SwCacheOwnerIdle -Names $script:Names
        $script:ProcCalls.Count | Should -Be 1
        @($script:ProcCalls[0]).Count | Should -Be 0
        Should -Invoke Get-Process -Times 1 -Exactly -ParameterFilter { $ErrorAction -eq 'Stop' }
    }

    It 'CL-23 step 4 asks again at every evaluation (nothing is kept)' {
        $null = Test-SwCacheOwnerIdle -Names $script:Names
        $null = Test-SwCacheOwnerIdle -Names $script:Names
        $null = Test-SwCacheOwnerIdle -Names $script:Names
        $script:ProcCalls.Count | Should -Be 3
    }

    It 'CL-23 gives $true for an empty, complete process list' {
        $answer = @(Test-SwCacheOwnerIdle -Names $script:Names)
        $answer.Count | Should -Be 1
        $answer[0] | Should -BeOfType [bool]
        $answer[0] | Should -BeTrue
    }

    It 'S-10 gives $false when the process list cannot be read' {
        Use-ProcessSpy -Mode Throws
        Test-SwCacheOwnerIdle -Names $script:Names | Should -BeFalse
    }

    It 'CL-23 gives $false for a running process named like a name, whatever the case' -ForEach @(
        @{ Running = 'CURSOR'; Names = @('Cursor') }
        @{ Running = 'cursor'; Names = @('Cursor') }
        @{ Running = 'Cursor'; Names = @('cursor') }
        @{ Running = 'slack'; Names = @('discord', 'Slack') }
    ) {
        Use-ProcessSpy -Running @($Running) -Mode Always
        Test-SwCacheOwnerIdle -Names $Names | Should -BeFalse
    }

    It 'CL-23 gives $true when only other processes run' {
        Use-ProcessSpy -Running @('explorer', 'pwsh', 'Code - Insiders') -Mode Always
        Test-SwCacheOwnerIdle -Names @('Code') | Should -BeTrue
    }

    It 'CL-23 does not count a process named Code - Insiders for the name Code' {
        Use-ProcessSpy -Running @('Code - Insiders') -Mode Always
        Test-SwCacheOwnerIdle -Names @('Code') | Should -BeTrue
    }

    It 'CL-23 gives $false when reading ProcessName throws' {
        # PowerShell hands a failing property getter over as $null: the name is then unknown.
        Mock Get-Process {
            $broken = New-Object psobject
            $broken | Add-Member -MemberType ScriptProperty -Name ProcessName -Value { throw 'access denied (test)' }
            @($broken)
        }
        Test-SwCacheOwnerIdle -Names $script:Names | Should -BeFalse
    }

    It 'CL-23 gives $false for a process entry with an empty ProcessName (unknown is not idle)' {
        Mock Get-Process { @([pscustomobject]@{ ProcessName = '' }) }
        Test-SwCacheOwnerIdle -Names $script:Names | Should -BeFalse
    }

    It 'CL-23 gives $false for a process entry without a ProcessName' {
        Mock Get-Process { @([pscustomobject]@{ Id = 7 }) }
        Test-SwCacheOwnerIdle -Names $script:Names | Should -BeFalse
    }

    It 'CL-23 step 3 gives $true for a lock path that does not exist and creates nothing' {
        $lock = P $script:Work 'nofolder' 'lockfile'
        Test-SwCacheOwnerIdle -Names $script:Names -LockPath $lock | Should -BeTrue
        Exists $lock | Should -BeFalse
        Exists (P $script:Work 'nofolder') | Should -BeFalse
    }

    It 'CL-23 step 3 gives $true for a lock file nobody holds and leaves it as it was' {
        $lock = New-File (P $script:Work 'lockfile') 11
        $before = [System.IO.File]::ReadAllBytes($lock)
        $time = [System.IO.File]::GetLastWriteTimeUtc($lock)
        Test-SwCacheOwnerIdle -Names $script:Names -LockPath $lock | Should -BeTrue
        [System.IO.File]::Exists($lock) | Should -BeTrue
        (@([System.IO.File]::ReadAllBytes($lock)) -join ',') | Should -BeExactly (@($before) -join ',')
        [System.IO.File]::GetLastWriteTimeUtc($lock) | Should -Be $time
    }

    It 'CL-23 step 3 holds no handle on the lock file afterwards' {
        $lock = New-File (P $script:Work 'lockfile') 5
        $null = Test-SwCacheOwnerIdle -Names $script:Names -LockPath $lock
        $stream = [System.IO.File]::Open($lock, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $stream.Dispose()
    }

    It 'S-10 gives $false when the lock path is a folder' {
        $lock = New-Dir (P $script:Work 'lockfile')
        Test-SwCacheOwnerIdle -Names $script:Names -LockPath $lock | Should -BeFalse
    }

    It 'CL-23 step 4 checks the processes before the lock file' {
        $lock = New-Dir (P $script:Work 'lockfile')
        $null = Test-SwCacheOwnerIdle -Names $script:Names -LockPath $lock
        $script:ProcCalls.Count | Should -Be 1
    }

    It 'S-10 gives $false when the lock path is a link' {
        $target = New-File (P $script:Work 'real-lock') 4
        $link = P $script:Work 'lockfile'
        if (-not (New-TestLink $link $target)) { Set-ItResult -Skipped -Because 'this account cannot create a file link'; return }
        Test-SwCacheOwnerIdle -Names $script:Names -LockPath $link | Should -BeFalse
    }

    It 'CL-23 gives $false when the lock path cannot be read (a NUL character in the path)' {
        $lock = (P $script:Work 'lock') + [string][char]0 + 'file'
        $answer = @(Test-SwCacheOwnerIdle -Names $script:Names -LockPath $lock)
        $answer.Count | Should -Be 1
        $answer[0] | Should -BeFalse
    }

    It 'CL-23 treats an empty lock path as no lock file' {
        Test-SwCacheOwnerIdle -Names $script:Names -LockPath '' | Should -BeTrue
    }

    It 'CL-23 never throws, also for unusable names and paths' {
        { $null = Test-SwCacheOwnerIdle -Names @('', ' ') -LockPath "a$([char]0)b" } | Should -Not -Throw
        { $null = Test-SwCacheOwnerIdle -Names $script:Names -LockPath (P $script:Work 'x' 'lockfile') } | Should -Not -Throw
    }

    It 'CL-23 opens the lock file for reading with FileMode.Open and FileShare.None, never with a mode that creates' {
        $function = (Get-Command -Name Test-SwCacheOwnerIdle -CommandType Function).ScriptBlock.Ast.Extent.Text
        $function | Should -Match 'FileMode\]::Open\b'
        $function | Should -Match 'FileShare\]::None\b'
        $function | Should -Not -Match 'FileMode\]::(Create|CreateNew|OpenOrCreate|Append|Truncate)\b'
    }

    It 'CL-23 [W] gives $false while another handle holds the lock file with FileShare.None and $true after it is closed' {
        $lock = New-File (P $script:Work 'lockfile') 6
        $holder = [System.IO.File]::Open($lock, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try { $held = Test-SwCacheOwnerIdle -Names $script:Names -LockPath $lock }
        finally { $holder.Dispose() }
        $held | Should -BeFalse
        Test-SwCacheOwnerIdle -Names $script:Names -LockPath $lock | Should -BeTrue
    }
}

Describe 'Test-SwCacheOwnerIdle with real processes' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -RealProcess
    }
    AfterEach { Stop-Case }

    It 'CL-23 gives $true for a name that no real process carries (no mock)' {
        Test-SwCacheOwnerIdle -Names @('sweepr-fixture-' + [guid]::NewGuid().ToString('N')) | Should -BeTrue
    }

    It 'CL-23 gives $false for the name of the running test process (no mock)' {
        $own = (Get-Process -Id $PID).ProcessName
        Test-SwCacheOwnerIdle -Names @($own) | Should -BeFalse
    }
}

# ============================================================================
# Clear-SwAppCache: the decisions (CL-24)
# ============================================================================

Describe 'Clear-SwAppCache decisions' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-HelperSpies
        Use-IdleSpy $true
        $script:SafeAnswer = $true
        $script:SafeCalls = [System.Collections.Generic.List[string]]::new()
        Mock Test-SwSafePath { $script:SafeCalls.Add([string]$Path); $script:SafeAnswer }
        $script:Cache = New-Dir (P $script:Roam 'Example' 'Cache')
    }
    AfterEach { Stop-Case }

    It 'CL-24 step 1 does nothing, silently, when the folder does not exist' {
        Clear-SwAppCache -Path (P $script:Roam 'Example' 'Missing') -Description 'Example cache' -Processes @('example')
        $script:Calls.Count | Should -Be 0
        $script:NotMeasured.Count | Should -Be 0
    }

    It 'CL-24 step 1 does nothing, silently, when the path is a file' {
        $file = New-File (P $script:Roam 'Example' 'a-file') 3
        Clear-SwAppCache -Path $file -Description 'Example cache' -Processes @('example')
        $script:Calls.Count | Should -Be 0
        $script:NotMeasured.Count | Should -Be 0
    }

    It 'CL-24 step 2 passes the path to Test-SwSafePath' {
        Clear-SwAppCache -Path $script:Cache -Description 'Example cache' -Processes @('example')
        $script:SafeCalls | Should -Contain $script:Cache
    }

    It 'CL-24, CL-28 leaves the folder when Test-SwSafePath says no and notes it as not verified' {
        $script:SafeAnswer = $false
        Clear-SwAppCache -Path $script:Cache -Description 'Example cache' -Processes @('example')
        $script:Calls.Count | Should -Be 0
        $script:NotMeasured.Count | Should -Be 1
        $script:NotMeasured[0].Name | Should -BeExactly 'Example cache'
        $script:NotMeasured[0].Reason | Should -BeExactly 'not verified'
    }

    It 'CL-24, CL-28 leaves the folder when it has no identity and notes it as not verified' {
        $script:FakeNoIdentity.Add($script:Cache)
        Clear-SwAppCache -Path $script:Cache -Description 'Example cache' -Processes @('example')
        $script:Calls.Count | Should -Be 0
        $script:NotMeasured.Count | Should -Be 1
        $script:NotMeasured[0].Name | Should -BeExactly 'Example cache'
        $script:NotMeasured[0].Reason | Should -BeExactly 'not verified'
    }

    It 'CL-24 step 3 makes exactly one Clear-SwDirectoryContents call with the path, the description and a condition' {
        Clear-SwAppCache -Path $script:Cache -Description 'Example cache' -Processes @('example') -LockPath (P $script:Roam 'Example' 'lockfile')
        $calls = @(Get-Calls 'Clear-SwDirectoryContents')
        $calls.Count | Should -Be 1
        $script:Calls.Count | Should -Be 1
        $calls[0].Path | Should -BeExactly $script:Cache
        $calls[0].Description | Should -BeExactly 'Example cache'
        $calls[0].CanRemove | Should -BeOfType [scriptblock]
        $script:NotMeasured.Count | Should -Be 0
    }

    It 'CL-24 asks Test-SwCacheOwnerIdle in the condition with the processes and the lock path' {
        $lock = P $script:Roam 'Example' 'lockfile'
        Clear-SwAppCache -Path $script:Cache -Description 'Example cache' -Processes @('example', 'example-helper') -LockPath $lock
        $block = (Get-Calls 'Clear-SwDirectoryContents')[0].CanRemove
        $null = & $block
        $script:IdleCalls.Count | Should -Be 1
        $script:IdleCalls[0].Names | Should -Be @('example', 'example-helper')
        $script:IdleCalls[0].LockPath | Should -BeExactly $lock
    }

    It 'CL-24 passes no lock path as empty' {
        Clear-SwAppCache -Path $script:Cache -Description 'Example cache' -Processes @('example')
        $block = (Get-Calls 'Clear-SwDirectoryContents')[0].CanRemove
        $null = & $block
        [string]::IsNullOrEmpty([string]$script:IdleCalls[0].LockPath) | Should -BeTrue
    }

    It 'CL-24 the condition gives exactly one [bool] that follows the probe' -ForEach @(
        @{ Idle = $true }
        @{ Idle = $false }
    ) {
        Use-IdleSpy $Idle
        Clear-SwAppCache -Path $script:Cache -Description 'Example cache' -Processes @('example')
        $block = (Get-Calls 'Clear-SwDirectoryContents')[0].CanRemove
        $answer = @(& $block)
        $answer.Count | Should -Be 1
        $answer[0] | Should -BeOfType [bool]
        $answer[0] | Should -Be $Idle
    }

    It 'CL-24 the condition evaluates the probe afresh at every call' {
        Clear-SwAppCache -Path $script:Cache -Description 'Example cache' -Processes @('example')
        $block = (Get-Calls 'Clear-SwDirectoryContents')[0].CanRemove
        $null = & $block
        Use-IdleSpy $false
        $second = & $block
        $second | Should -BeFalse
        $script:IdleCalls.Count | Should -Be 1
        $null = & $block
        $null = & $block
        $script:IdleCalls.Count | Should -Be 3
    }

    It 'CL-24 asks for processes only through Test-SwCacheOwnerIdle (no Get-Process call of its own)' {
        Use-ProcessSpy -Mode Never
        Clear-SwAppCache -Path $script:Cache -Description 'Example cache' -Processes @('example')
        $block = (Get-Calls 'Clear-SwDirectoryContents')[0].CanRemove
        $null = & $block
        $script:ProcCalls.Count | Should -Be 0
    }

    It 'CL-24 never throws, whatever fails below it' -ForEach @(
        @{ Failing = 'Clear-SwDirectoryContents' }
        @{ Failing = 'Test-SwSafePath' }
        @{ Failing = 'Get-SwPathSnapshot' }
    ) {
        Mock $Failing { throw 'failure (test)' }
        { Clear-SwAppCache -Path $script:Cache -Description 'Example cache' -Processes @('example') } | Should -Not -Throw
    }

    It 'CL-24 writes nothing to the pipeline' {
        Mock Clear-SwDirectoryContents { 'noise'; $true }
        @(Clear-SwAppCache -Path $script:Cache -Description 'Example cache' -Processes @('example')).Count | Should -Be 0
    }
}

# ============================================================================
# Clear-SwAppCache with the real removal helpers (CL-24, S-2, S-10)
# ============================================================================

Describe 'Clear-SwAppCache with the real helpers' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        $script:DryRunCollector = [System.Collections.Generic.List[object]]::new()
        $script:Cache = New-Dir (P $script:Roam 'Cursor' 'Cache')
        $script:Entry = P $script:Cache 'entry'
    }
    AfterEach { Stop-Case }

    It 'CL-24 offers the contents of an idle cache in <Mode> ' -ForEach $script:RunModes {
        $script:SweeprDryRunMode = $Dry
        $null = New-File (P $script:Entry 'data.bin') 2048
        Use-ProcessSpy -Mode Never
        Clear-SwAppCache -Path $script:Cache -Description 'Cursor cache' -Processes @('Cursor')
        (Get-SwCleanupStats).FilesCleaned | Should -Be 1
        [System.IO.Directory]::Exists($script:Cache) | Should -BeTrue
        if ($Dry) {
            Exists $script:Entry | Should -BeTrue
            @($script:DryRunCollector).Count | Should -Be 1
            $script:DryRunCollector[0].Path | Should -BeExactly $script:Entry
            $script:DryRunCollector[0].Description | Should -BeExactly 'Cursor cache'
        }
        else { Exists $script:Entry | Should -BeFalse }
    }

    It 'S-10 keeps the cache while the owner runs, in <Mode> ' -ForEach $script:RunModes {
        $script:SweeprDryRunMode = $Dry
        $null = New-File (P $script:Entry 'data.bin') 2048
        Use-ProcessSpy -Running @('Cursor') -Mode Always
        Clear-SwAppCache -Path $script:Cache -Description 'Cursor cache' -Processes @('Cursor')
        (Get-SwCleanupStats).FilesCleaned | Should -Be 0
        @($script:DryRunCollector).Count | Should -Be 0
        Exists (P $script:Entry 'data.bin') | Should -BeTrue
    }

    It 'S-10 keeps the cache when the process list cannot be read, in <Mode> ' -ForEach $script:RunModes {
        $script:SweeprDryRunMode = $Dry
        $null = New-File (P $script:Entry 'data.bin') 2048
        Use-ProcessSpy -Mode Throws
        Clear-SwAppCache -Path $script:Cache -Description 'Cursor cache' -Processes @('Cursor')
        (Get-SwCleanupStats).FilesCleaned | Should -Be 0
        @($script:DryRunCollector).Count | Should -Be 0
        Exists (P $script:Entry 'data.bin') | Should -BeTrue
    }

    It 'S-10 keeps the cache when no process is named at all, in <Mode> ' -ForEach $script:RunModes {
        $script:SweeprDryRunMode = $Dry
        $null = New-File (P $script:Entry 'data.bin') 2048
        Use-ProcessSpy -Mode Never
        Clear-SwAppCache -Path $script:Cache -Description 'Cursor cache' -Processes @()
        (Get-SwCleanupStats).FilesCleaned | Should -Be 0
        Exists (P $script:Entry 'data.bin') | Should -BeTrue
    }

    It 'S-10 keeps the cache while the lock path is a folder, in <Mode> ' -ForEach $script:RunModes {
        $script:SweeprDryRunMode = $Dry
        $null = New-File (P $script:Entry 'data.bin') 2048
        Use-ProcessSpy -Mode Never
        $lock = New-Dir (P $script:Roam 'Cursor' 'lockfile')
        Clear-SwAppCache -Path $script:Cache -Description 'Cursor cache' -Processes @('Cursor') -LockPath $lock
        (Get-SwCleanupStats).FilesCleaned | Should -Be 0
        Exists (P $script:Entry 'data.bin') | Should -BeTrue
    }

    It 'CL-24 keeps the cache when the owner appears after the measurement of a folder, in <Mode> ' -ForEach $script:RunModes {
        $script:SweeprDryRunMode = $Dry
        $null = New-File (P $script:Entry 'data.bin') 2048
        Use-ProcessSpy -Running @('Cursor') -Mode Deferred
        $script:SizeCalls = 0
        Mock Get-SwValidatedTreeSize {
            $script:SizeCalls++
            $script:OwnerActive = $true
            & $script:RealTreeSizeBlock -Tree $Tree
        }
        Clear-SwAppCache -Path $script:Cache -Description 'Cursor cache' -Processes @('Cursor')
        $script:SizeCalls | Should -Be 1
        (Get-SwCleanupStats).FilesCleaned | Should -Be 0
        @($script:DryRunCollector).Count | Should -Be 0
        Exists (P $script:Entry 'data.bin') | Should -BeTrue
    }

    It 'CL-24 asks for the processes <Real> times for a folder child and <File> times for a file child in <Mode> ' -ForEach @(
        @{ Mode = 'a preview'; Dry = $true; Real = 2; File = 2 }
        @{ Mode = 'a real run'; Dry = $false; Real = 3; File = 2 }
    ) {
        $script:SweeprDryRunMode = $Dry
        $null = New-File (P $script:Entry 'data.bin') 100
        Use-ProcessSpy -Mode Never
        Clear-SwAppCache -Path $script:Cache -Description 'Cursor cache' -Processes @('Cursor')
        $script:ProcCalls.Count | Should -Be $Real

        $other = New-Dir (P $script:Roam 'Cursor' 'Code Cache')
        $null = New-File (P $other 'single.bin') 100
        Use-ProcessSpy -Mode Never
        Clear-SwAppCache -Path $other -Description 'Cursor cache' -Processes @('Cursor')
        $script:ProcCalls.Count | Should -Be $File
    }

    It 'CL-24 logs exactly one SKIPPED line and removes nothing when the owner shows up before the removal of a folder (real run)' {
        $script:SweeprDryRunMode = $false
        $null = New-File (P $script:Entry 'inner' 'data.bin') 100
        Use-ProcessSpy -Running @('Cursor') -Mode From -FromCall 3
        Clear-SwAppCache -Path $script:Cache -Description 'Cursor cache' -Processes @('Cursor')
        $script:ProcCalls.Count | Should -BeGreaterOrEqual 3
        Exists (P $script:Entry 'inner' 'data.bin') | Should -BeTrue
        $skipped = @($script:Ops | Where-Object { $_.Action -eq 'SKIPPED' })
        $skipped.Count | Should -Be 1
        @($script:Ops | Where-Object { $_.Action -in @('REMOVED', 'FAILED') }).Count | Should -Be 0
    }

    It 'CL-24 writes no SKIPPED line in a preview, whatever the owner does' {
        $script:SweeprDryRunMode = $true
        $null = New-File (P $script:Entry 'inner' 'data.bin') 100
        Use-ProcessSpy -Running @('Cursor') -Mode From -FromCall 2
        Clear-SwAppCache -Path $script:Cache -Description 'Cursor cache' -Processes @('Cursor')
        @($script:Ops).Count | Should -Be 0
        (Get-SwCleanupStats).FilesCleaned | Should -Be 0
    }

    It 'S-2 offers a sibling of the Sweepr data folder and keeps the data folder with its content in <Mode> ' -ForEach $script:RunModes {
        $script:SweeprDryRunMode = $Dry
        $slack = New-Dir (P $script:Roam 'Slack' 'Cache')
        $script:Config = @{ ConfigPath = (P $slack 'data'); CachePath = (P $slack 'data' 'cache'); WhitelistFile = (P $slack 'data' 'whitelist.txt') }
        $null = New-File (P $slack 'data' 'keep.txt') 5
        $null = New-File (P $slack 'data2' 'x.bin') 5
        Use-ProcessSpy -Mode Never
        Clear-SwAppCache -Path $slack -Description 'Slack cache' -Processes @('slack')
        (Get-SwCleanupStats).FilesCleaned | Should -Be 1
        Exists (P $slack 'data' 'keep.txt') | Should -BeTrue
        if ($Dry) {
            Exists (P $slack 'data2' 'x.bin') | Should -BeTrue
            @($script:DryRunCollector | ForEach-Object { $_.Path }) | Should -Contain (P $slack 'data2')
        }
        else { Exists (P $slack 'data2') | Should -BeFalse }
    }

    It 'S-2 removes nothing from a folder that a whitelist line holds, in <Mode> ' -ForEach $script:RunModes {
        $script:SweeprDryRunMode = $Dry
        $null = New-File (P $script:Entry 'data.bin') 100
        Set-Whitelist @($script:Cache)
        Use-ProcessSpy -Mode Never
        Clear-SwAppCache -Path $script:Cache -Description 'Cursor cache' -Processes @('Cursor')
        (Get-SwCleanupStats).FilesCleaned | Should -Be 0
        Exists (P $script:Entry 'data.bin') | Should -BeTrue
    }

    It 'CL-24 does nothing for a folder that does not exist' {
        $script:SweeprDryRunMode = $false
        Use-ProcessSpy -Mode Never
        Clear-SwAppCache -Path (P $script:Roam 'Cursor' 'Nothing') -Description 'Cursor cache' -Processes @('Cursor')
        $script:ProcCalls.Count | Should -Be 0
        (Get-SwCleanupStats).FilesCleaned | Should -Be 0
    }
}

# ============================================================================
# Get-SwCacheProfiles (CL-25, S-7, S-13, S-18)
# ============================================================================

Describe 'Get-SwCacheProfiles' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-ItemSpy
    }
    AfterEach { Stop-Case }

    It 'CL-25 gives the folders below the root, one by one, as DirectoryInfo objects with the full path' {
        $root = New-ProfileRoot @('Default', 'Profile 1')
        $profiles = Get-Profiles $root
        $profiles.Count | Should -Be 2
        foreach ($profile in $profiles) { $profile | Should -BeOfType [System.IO.DirectoryInfo] }
        (Get-ProfileNames $profiles) | Should -Be @('Default', 'Profile 1')
        @($profiles | ForEach-Object { $_.FullName } | Sort-Object) | Should -Be @(@((P $root 'Default'), (P $root 'Profile 1')) | Sort-Object)
    }

    It 'CL-25 puts a single profile into the pipeline as the object, not as an array' {
        $root = New-ProfileRoot @('Default')
        $one = Get-SwCacheProfiles -Root $root
        $one | Should -BeOfType [System.IO.DirectoryInfo]
        $one.Name | Should -BeExactly 'Default'
    }

    It 'CL-25 counts the brackets in Profile [work] as part of the name' {
        $root = New-ProfileRoot @('Default', 'Profile [work]')
        (Get-ProfileNames (Get-Profiles $root)) | Should -Be @('Default', 'Profile [work]')
    }

    It 'CL-25 leaves out the folders that are named like a root leaf, whatever the case, and keeps Crashpad' {
        $root = New-ProfileRoot @('Default', 'ShaderCache', 'GrShaderCache', 'Crashpad', 'Cache', 'Code Cache', 'GPUCache', 'gpucache')
        (Get-ProfileNames (Get-Profiles $root)) | Should -Be @('Crashpad', 'Default')
        @($script:NotMeasured).Count | Should -Be 0
    }

    It 'CL-25 keeps Guest Profile and Crashpad as profiles' {
        $root = New-ProfileRoot @('Guest Profile', 'Crashpad')
        (Get-ProfileNames (Get-Profiles $root)) | Should -Be @('Crashpad', 'Guest Profile')
    }

    It 'CL-25 ignores files in the root and does not count them for the limit' {
        $root = New-ProfileRoot @('Default', 'Profile 1')
        for ($i = 1; $i -le 140; $i++) { $null = New-File (P $root ('file' + $i + '.txt')) 1 }
        (Get-ProfileNames (Get-Profiles $root)) | Should -Be @('Default', 'Profile 1')
        @($script:NotMeasured).Count | Should -Be 0
    }

    It 'CL-25 gives nothing and says nothing for a root that does not exist' {
        $profiles = Get-Profiles (P $script:Local 'Google' 'Chrome' 'User Data')
        $profiles.Count | Should -Be 0
        @($script:NotMeasured).Count | Should -Be 0
    }

    It 'CL-25 gives nothing and says nothing for a root that is a file' {
        $file = New-File (P $script:Local 'Google' 'Chrome' 'User Data') 3
        (Get-Profiles $file).Count | Should -Be 0
        @($script:NotMeasured).Count | Should -Be 0
    }

    It 'CL-25 reads each subfolder with one Get-Item -LiteralPath with -Force and -ErrorAction Stop, and nothing else' {
        $root = New-ProfileRoot @('Default', 'Profile 1', 'Profile [work]', 'ShaderCache')
        $null = Get-Profiles $root
        $script:ItemCalls.Count | Should -Be 4
        Should -Invoke Get-Item -Times 4 -Exactly -ParameterFilter { $ErrorAction -eq 'Stop' -and $Force }
        @($script:ItemCalls | ForEach-Object { $_.LiteralPath } | Sort-Object) | Should -Be @(@((P $root 'Default'), (P $root 'Profile 1'), (P $root 'Profile [work]'), (P $root 'ShaderCache')) | Sort-Object)
    }

    It 'CL-25 asks Get-SwPathSnapshot for the root without -AllowLeafLink and tests it again after the listing' {
        $root = New-ProfileRoot @('Default')
        $null = Get-Profiles $root
        $calls = @($script:SnapshotCalls | Where-Object { (Fold $_.Path) -eq (Fold $root) })
        $calls.Count | Should -BeGreaterOrEqual 1
        @($calls | Where-Object { $_.AllowLeafLink }).Count | Should -Be 0
        @($script:SnapshotTests | Where-Object { (Fold $_) -eq (Fold $root) }).Count | Should -BeGreaterOrEqual 1
    }

    It 'CL-25 discards everything when the snapshot of the root is $null and notes it as not verified' {
        $root = New-ProfileRoot @('Default', 'Profile 1')
        $script:FakeNoIdentity.Add($root)
        (Get-Profiles $root).Count | Should -Be 0
        $script:NotMeasured.Count | Should -Be 1
        $script:NotMeasured[0].Name | Should -BeLike '*User Data*'
        $script:NotMeasured[0].Reason | Should -BeExactly 'not verified'
    }

    It 'S-7 discards a root that is a link' {
        $target = New-Dir (P $script:Work 'elsewhere')
        $null = New-Dir (P $target 'Default')
        $root = P $script:Local 'Google' 'Chrome' 'User Data'
        $null = New-Dir (P $script:Local 'Google' 'Chrome')
        if (-not (New-TestLink $root $target)) { Set-ItResult -Skipped -Because 'this account cannot create a folder link'; return }
        (Get-Profiles $root).Count | Should -Be 0
        @($script:NotMeasured).Count | Should -Be 1
    }

    It 'S-7 discards a root below a linked folder' {
        $target = New-Dir (P $script:Work 'elsewhere')
        $null = New-Dir (P $target 'User Data' 'Default')
        $linked = P $script:Local 'Linked'
        if (-not (New-TestLink $linked $target)) { Set-ItResult -Skipped -Because 'this account cannot create a folder link'; return }
        (Get-Profiles (P $linked 'User Data')).Count | Should -Be 0
        @($script:NotMeasured).Count | Should -Be 1
    }

    It 'CL-25 discards everything when the identity of the root changed during the listing' {
        $root = New-ProfileRoot @('Default', 'Profile 1')
        $script:FakeReplaced.Add($root)
        (Get-Profiles $root).Count | Should -Be 0
        $script:NotMeasured.Count | Should -Be 1
        $script:NotMeasured[0].Reason | Should -BeIn @('incomplete scan', 'not verified')
    }

    It 'CL-25 gives all 128 folders when there are exactly 128' {
        $names = @(1..128 | ForEach-Object { 'Profile ' + $_ })
        $root = New-ProfileRoot $names
        (Get-Profiles $root).Count | Should -Be 128
        @($script:NotMeasured).Count | Should -Be 0
    }

    It 'CL-25 discards everything, Default included, for 129 folders and notes incomplete scan' {
        $names = @('Default') + @(1..128 | ForEach-Object { 'Profile ' + $_ })
        $root = New-ProfileRoot $names
        (Get-Profiles $root).Count | Should -Be 0
        $script:NotMeasured.Count | Should -Be 1
        $script:NotMeasured[0].Name | Should -BeLike '*User Data*'
        $script:NotMeasured[0].Reason | Should -BeExactly 'incomplete scan'
    }

    It 'CL-25 counts the folders named like a root leaf for the limit of 128' {
        $names = @(1..128 | ForEach-Object { 'Profile ' + $_ }) + @('ShaderCache')
        $root = New-ProfileRoot $names
        (Get-Profiles $root).Count | Should -Be 0
        $script:NotMeasured.Count | Should -Be 1
        $script:NotMeasured[0].Reason | Should -BeExactly 'incomplete scan'
    }

    It 'S-18 discards everything when the time budget is 0 and notes incomplete scan' {
        $root = New-ProfileRoot @('Default')
        $script:SwProbeBudgetSeconds = 0
        (Get-Profiles $root).Count | Should -Be 0
        $script:NotMeasured.Count | Should -Be 1
        $script:NotMeasured[0].Reason | Should -BeExactly 'incomplete scan'
    }

    It 'uses 2 seconds when the budget variable is missing' {
        $root = New-ProfileRoot @('Default', 'Profile 1')
        Remove-Variable -Name SwProbeBudgetSeconds -Scope Script
        (Get-Profiles $root).Count | Should -Be 2
        @($script:NotMeasured).Count | Should -Be 0
    }

    It 'uses 2 seconds when the budget variable is not a number' {
        $root = New-ProfileRoot @('Default', 'Profile 1')
        $script:SwProbeBudgetSeconds = 'soon'
        (Get-Profiles $root).Count | Should -Be 2
        @($script:NotMeasured).Count | Should -Be 0
    }

    It 'CL-25 does not create the budget variable' {
        $root = New-ProfileRoot @('Default')
        Remove-Variable -Name SwProbeBudgetSeconds -Scope Script
        $null = Get-Profiles $root
        Get-Variable -Name SwProbeBudgetSeconds -Scope Script -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'CL-25 discards the whole root when one subfolder cannot be read and notes incomplete scan' {
        $root = New-ProfileRoot @('Default', 'Profile 1', 'Profile 2')
        $script:ItemBehavior['Profile 2'] = 'throw'
        (Get-Profiles $root).Count | Should -Be 0
        @($script:ItemCalls | Where-Object { $_.Name -eq 'Profile 2' }).Count | Should -Be 1
        $script:NotMeasured.Count | Should -Be 1
        $script:NotMeasured[0].Reason | Should -BeExactly 'incomplete scan'
    }

    It 'CL-25 does not touch the roots of other browsers when one root is discarded' {
        $chrome = New-ProfileRoot @('Default', 'Profile 2')
        $edge = New-ProfileRoot @('Default') (P $script:Local 'Microsoft' 'Edge' 'User Data')
        $script:ItemBehavior['Profile 2'] = 'throw'
        (Get-Profiles $chrome).Count | Should -Be 0
        (Get-ProfileNames (Get-Profiles $edge)) | Should -Be @('Default')
    }

    It 'treats an entry without Attributes as a link: left out, the rest stays' {
        $root = New-ProfileRoot @('Default', 'Profile 2')
        $script:ItemBehavior['Profile 2'] = 'noattr'
        (Get-ProfileNames (Get-Profiles $root)) | Should -Be @('Default')
        @($script:NotMeasured).Count | Should -Be 0
    }

    It 'CL-25 leaves out an entry with the link attribute without discarding the rest' {
        $root = New-ProfileRoot @('Default', 'Profile 2')
        $script:ItemBehavior['Profile 2'] = 'reparse'
        (Get-ProfileNames (Get-Profiles $root)) | Should -Be @('Default')
        @($script:NotMeasured).Count | Should -Be 0
    }

    It 'S-7 leaves out a profile folder that is a link and keeps the other profiles' {
        $root = New-ProfileRoot @('Default')
        $target = New-Dir (P $script:Work 'elsewhere')
        $null = New-File (P $target 'outside.txt') 3
        if (-not (New-TestLink (P $root 'Profile 2') $target)) { Set-ItResult -Skipped -Because 'this account cannot create a folder link'; return }
        (Get-ProfileNames (Get-Profiles $root)) | Should -Be @('Default')
        Exists (P $target 'outside.txt') | Should -BeTrue
    }

    It 'S-13 enumerates literally: a root below Apps [x] never mixes with the folder Apps x' {
        $bracket = New-ProfileRoot @('Default') (P $script:Work 'Apps [x]' 'User Data')
        $null = New-ProfileRoot @('Default', 'Decoy') (P $script:Work 'Apps x' 'User Data')
        (Get-ProfileNames (Get-Profiles $bracket)) | Should -Be @('Default')
    }

    It 'CL-25 never throws and gives nothing for an unusable root' -ForEach @(
        @{ Label = 'an empty root'; Root = '' }
        @{ Label = 'a relative root'; Root = 'User Data' }
        @{ Label = 'a NUL character'; Root = "a$([char]0)b" }
    ) {
        { $script:Result = @(Get-SwCacheProfiles -Root $Root) } | Should -Not -Throw
        $script:Result.Count | Should -Be 0
    }
}

Describe 'Get-SwCacheProfiles with real identities' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -RealIdentity
    }
    AfterEach { Stop-Case }

    It 'CL-25 [W] leaves out a junction as a profile, keeps the others and the files behind the junction' {
        $root = New-ProfileRoot @('Default', 'Profile 1')
        $target = New-Dir (P $script:Work 'elsewhere')
        $null = New-File (P $target 'outside.txt') 3
        $null = New-Item -ItemType Junction -Path (P $root 'Profile 2') -Target $target
        $script:Links.Add((P $root 'Profile 2'))
        (Get-ProfileNames (Get-Profiles $root)) | Should -Be @('Default', 'Profile 1')
        Exists (P $target 'outside.txt') | Should -BeTrue
    }

    It 'S-7 [W] discards a root that is a junction' {
        $target = New-Dir (P $script:Work 'elsewhere')
        $null = New-Dir (P $target 'Default')
        $null = New-Dir (P $script:Local 'Google' 'Chrome')
        $root = P $script:Local 'Google' 'Chrome' 'User Data'
        $null = New-Item -ItemType Junction -Path $root -Target $target
        $script:Links.Add($root)
        (Get-Profiles $root).Count | Should -Be 0
    }

    It 'CL-25 [W] gives the profiles of an ordinary root when identities are real' {
        $root = New-ProfileRoot @('Default', 'Profile 1')
        (Get-ProfileNames (Get-Profiles $root)) | Should -Be @('Default', 'Profile 1')
    }
}
