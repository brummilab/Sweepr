# Sweepr - cross checks of the cleanup core: the static test over the five files (the forbidden list of
# S-1, S-3, S-4, S-5, S-6, S-9 and the rules for loading and variables), real runs of every section with
# mocked helpers (only the allowed helpers are called), the preview over all sections with a before and
# after comparison of the file tree, the list file against the statistics, isolation, one-time offers,
# silence in the pipeline, titles of the sections and loading in a fresh process.
#
# The rule numbers in the test names (CL-, SI-, S-, K- and so on) number the rules and the
# safety invariants of the cleanup core's behavior; each rule and invariant has at least one test.
# The other clean test files are SwCleanMain, SwCleanRun, SwCleanEditor (the command script),
# SwCleanGuard, SwCleanUser, SwCleanCaches and SwCleanSystem.
#
# Files looked at: bin\clean.ps1, lib\clean\user.ps1, caches.ps1, cache_guard.ps1, system.ps1. The test
# parses them and never runs them in the static part. Real runs happen below $TestDrive only.
#
# Seams used with Mock: the removal helpers as spies, Get-SwPathSnapshot and Test-SwPathSnapshot
# (substitute objects), Test-SwAdmin, Get-Process, Write-SwOperation and Write-SweeprOperation, and
# throwing mocks of every cmdlet that a section must never call.
#
# Platform notes:
#   - Paths are built from $TestDrive with the separator of the host. The creation time follows the write
#     time on hosts that are not Windows; the fixtures age both together.
#   - Tests marked [W] need real Windows. They are meant to fail on Linux and belong in
#     tests/linux-known-failures.txt.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    $script:RunModes = @(
        @{ Mode = 'a preview'; Dry = $true }
        @{ Mode = 'a real run'; Dry = $false }
    )
    # The five files: name, relative path, expected new functions, expected loads (file names that its dot-source lines name).
    $script:Files = @(
        @{ Name = 'bin\clean.ps1'; Parts = @('bin', 'clean.ps1'); Lib = $false
            Functions = @('Invoke-SwCleanMain', 'Start-SwCleanRun', 'Get-SwPathCollision', 'Show-SwCleanSummary', 'Show-SwCleanHelp', 'Edit-SwWhitelist'); Extra = @(); Loads = @('base.ps1', 'log.ps1', 'file_ops.ps1') }
        @{ Name = 'lib\clean\user.ps1'; Parts = @('lib', 'clean', 'user.ps1'); Lib = $true
            Functions = @('Invoke-SwUserCleanup', 'Clear-SwUserTempFiles', 'Clear-SwErrorReports', 'Clear-SwUserLogs', 'Clear-SwReportRoot'); Extra = @(); Loads = @('base.ps1', 'log.ps1', 'file_ops.ps1') }
        @{ Name = 'lib\clean\caches.ps1'; Parts = @('lib', 'clean', 'caches.ps1'); Lib = $true
            Functions = @('Clear-SwBrowserCaches', 'Clear-SwAppCaches', 'Clear-SwGpuShaderCaches'); Extra = @('Clear-SwAppCache', 'Get-SwCacheProfiles', 'Test-SwCacheOwnerIdle'); Loads = @('base.ps1', 'log.ps1', 'file_ops.ps1', 'cache_guard.ps1') }
        @{ Name = 'lib\clean\cache_guard.ps1'; Parts = @('lib', 'clean', 'cache_guard.ps1'); Lib = $true
            Functions = @('Test-SwCacheOwnerIdle', 'Clear-SwAppCache', 'Get-SwCacheProfiles'); Extra = @(); Loads = @('base.ps1', 'log.ps1', 'file_ops.ps1') }
        @{ Name = 'lib\clean\system.ps1'; Parts = @('lib', 'clean', 'system.ps1'); Lib = $true
            Functions = @('Invoke-SwSystemCleanup'); Extra = @('Clear-SwReportRoot', 'Invoke-SwUserCleanup'); Loads = @('base.ps1', 'log.ps1', 'file_ops.ps1', 'user.ps1') }
    )
    $script:LibFiles = @($script:Files | Where-Object { $_.Lib })
    $script:Sections = @(
        @{ Section = 'Invoke-SwUserCleanup'; Title = 'User essentials'; Admin = $false }
        @{ Section = 'Clear-SwBrowserCaches'; Title = 'Browser caches'; Admin = $false }
        @{ Section = 'Clear-SwAppCaches'; Title = 'Application caches'; Admin = $false }
        @{ Section = 'Clear-SwGpuShaderCaches'; Title = 'GPU shader caches'; Admin = $false }
        @{ Section = 'Invoke-SwSystemCleanup'; Title = 'System cleanup'; Admin = $true }
    )
    $script:RemovedNames = @(
        'Clear-OldDownloads', 'Clear-SystemTempFiles', 'Clear-WindowsLogs', 'Clear-InstallerCache', 'Clear-MemoryDumps',
        'Invoke-ComponentStoreCleanup', 'Invoke-DiskCleanupTool', 'Test-SweeprOldErrorReport', 'Get-SweeprCacheProfiles'
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

    foreach ($name in 'user.ps1', 'caches.ps1', 'system.ps1') { . ([System.IO.Path]::Combine($script:CleanDir, $name)) }
    $script:SectionNames = @('Invoke-SwUserCleanup', 'Clear-SwBrowserCaches', 'Clear-SwAppCaches', 'Clear-SwGpuShaderCaches', 'Invoke-SwSystemCleanup')
    $script:Pwsh = (Get-Process -Id $PID).Path
    $script:FileParts = @(@('bin', 'clean.ps1'), @('lib', 'clean', 'user.ps1'), @('lib', 'clean', 'caches.ps1'), @('lib', 'clean', 'cache_guard.ps1'), @('lib', 'clean', 'system.ps1'))

    # ---- the static test: the five files as syntax trees ----------------------------------------------

    function script:Get-FilePath([string[]]$Parts) {
        $path = $script:RepoRoot
        foreach ($part in $Parts) { $path = [System.IO.Path]::Combine($path, $part) }
        $path
    }
    function script:Get-AstOf([string[]]$Parts) {
        $tokens = $null
        $errors = $null
        $path = Get-FilePath $Parts
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        if (@($errors).Count -gt 0) { throw ('syntax errors in ' + $path + ': ' + $errors[0].Message) }
        $ast
    }
    function script:Get-EnclosingFunction($Node) {
        $parent = $Node.Parent
        while ($null -ne $parent) {
            if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return [string]$parent.Name }
            $parent = $parent.Parent
        }
        ''
    }
    function script:Find-Commands($Ast, [string[]]$Names) {
        $found = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
        @($found | Where-Object { $name = $_.GetCommandName(); ($null -ne $name) -and ($Names -contains $name) } |
                ForEach-Object { [pscustomobject]@{ Name = $_.GetCommandName(); Line = $_.Extent.StartLineNumber; Function = (Get-EnclosingFunction $_) } })
    }
    # Static member calls (Type::Member) and instance calls (.Member) by member name.
    function script:Find-MemberCalls($Ast, [string[]]$Members, [string]$TypePattern = '') {
        $found = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)
        @($found | Where-Object {
                $member = $_.Member.Extent.Text
                if ($Members -notcontains $member) { return $false }
                if ($TypePattern -eq '') { return $true }
                $_.Static -and ($_.Expression -is [System.Management.Automation.Language.TypeExpressionAst]) -and ($_.Expression.TypeName.FullName -match $TypePattern)
            } | ForEach-Object { [pscustomobject]@{ Name = ($_.Expression.Extent.Text + '.' + $_.Member.Extent.Text); Line = $_.Extent.StartLineNumber; Function = (Get-EnclosingFunction $_) } })
    }
    function script:Find-TypeUses($Ast, [string]$Pattern) {
        $found = $Ast.FindAll({ param($n) ($n -is [System.Management.Automation.Language.TypeExpressionAst]) -or ($n -is [System.Management.Automation.Language.TypeConstraintAst]) }, $true)
        @($found | Where-Object { $_.TypeName.FullName -match $Pattern } | ForEach-Object { [pscustomobject]@{ Name = $_.TypeName.FullName; Line = $_.Extent.StartLineNumber; Function = (Get-EnclosingFunction $_) } })
    }
    function script:Find-Strings($Ast, [string]$Pattern) {
        $found = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)
        @($found | Where-Object { $_.Value -match $Pattern } | ForEach-Object { [pscustomobject]@{ Name = $_.Value; Line = $_.Extent.StartLineNumber; Function = (Get-EnclosingFunction $_) } })
    }
    function script:Format-Violations($Violations) { (@($Violations | Where-Object { $null -ne $_ }) | ForEach-Object { '{0}:{1} {2}' -f $_.Name, $_.Line, $_.Function }) -join '; ' }
    function script:Assert-NoViolations($Violations, [string]$Because = '') {
        $list = @($Violations | Where-Object { $null -ne $_ })
        $list.Count | Should -Be 0 -Because ($Because + ' ' + (Format-Violations $list))
    }
    function script:Get-DefinedFunctions($Ast) {
        @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { [string]$_.Name })
    }

    # ---- fixtures for the cross checks --------------------------------------------------------------

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
    function script:New-Report([string]$Root, [string]$Name, [double]$Days = 10, [string[]]$Files = @('Report.wer')) {
        $dir = New-Dir (P $Root $Name)
        foreach ($file in $Files) { $null = New-File (P $dir $file) 20 }
        Set-TreeAge $dir $Days
        $dir
    }
    # Everything the five sections can offer, plus neighbours that must stay.
    function script:New-FullFixture {
        New-RichFixture
        $null = New-OldFile (P $script:Scratch 'old.tmp') 30 100
        $null = New-File (P $script:Scratch 'new.tmp') 100
        $null = New-OldFile (P $script:Scratch 'folder' 'inner.tmp') 30 100
        $null = New-OldFile (P $script:Local 'Temp' 'x.log') 30 100
        $null = New-OldFile (P $script:Roam 'old.log') 30 100
        $null = New-OldFile (P $script:Roam 'keep.txt') 30 100
        $null = New-Report (P $script:Local 'Microsoft' 'Windows' 'WER' 'ReportArchive') 'old'
        $null = New-Report (P $script:Local 'Microsoft' 'Windows' 'WER' 'ReportQueue') 'old'
        $null = New-OldFile (P $script:Local 'CrashDumps' 'old.dmp') 10 100
        $null = New-Report (P $script:ProgramData 'Microsoft' 'Windows' 'WER' 'ReportQueue') 'old'
        $null = New-Report (P $script:ProgramData 'Microsoft' 'Windows' 'WER' 'ReportArchive') 'old'
        $null = New-OldFile (P $script:WinDir 'Temp' 'old.tmp') 30
        $null = New-OldFile (P $script:WinDir 'Minidump' 'a.dmp') 30
    }
    function script:Use-AdminAnswer([bool]$Answer) {
        $script:AdminAnswer = $Answer
        Mock Test-SwAdmin { $script:AdminAnswer }
    }
    # Every cmdlet that no section may call, as a mock that throws.
    function script:Use-ThrowingCmdlets {
        foreach ($name in 'Remove-Item', 'Move-Item', 'Copy-Item', 'Rename-Item', 'Invoke-Item', 'New-Item', 'Set-Content', 'Add-Content', 'Out-File', 'Clear-Content',
            'Start-Process', 'Stop-Process', 'Stop-Service', 'Set-Service', 'Restart-Service', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty',
            'Invoke-WebRequest', 'Invoke-RestMethod', 'Get-CimInstance', 'Get-WmiObject', 'Clear-Host', 'Read-Host', 'Start-Job', 'Clear-RecycleBin') {
            if ($null -eq (Get-Command -Name $name -ErrorAction SilentlyContinue)) { Set-Item -Path ('function:script:' + $name) -Value { } }
            Mock $name { throw 'a section must never call this (test)' }
        }
        Mock Move-SwItemToRecycleBin { throw 'the Recycle Bin must never be used (test)' }
        Mock Write-SwOperation { throw 'a section never writes the operations log (test)' }
        $script:ThrowingNames = @('Remove-Item', 'Move-Item', 'Copy-Item', 'Rename-Item', 'Invoke-Item', 'New-Item', 'Set-Content', 'Add-Content', 'Out-File', 'Clear-Content',
            'Start-Process', 'Stop-Process', 'Stop-Service', 'Set-Service', 'Restart-Service', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty',
            'Invoke-WebRequest', 'Invoke-RestMethod', 'Get-CimInstance', 'Get-WmiObject', 'Clear-Host', 'Read-Host', 'Start-Job', 'Clear-RecycleBin',
            'Move-SwItemToRecycleBin', 'Write-SwOperation')
    }
    function script:Use-GetProcessSpy {
        $script:ProcCalls = 0
        Mock Get-Process { $script:ProcCalls++; @() }
    }
    function script:Invoke-Section([string]$Section) { & $Section }
    function script:Use-Collector { $script:DryRunCollector = [System.Collections.Generic.List[object]]::new() }
}

AfterAll {
    Clear-TestLinks
    Restore-State $script:RootState
    Restore-Env $script:RootEnv
    [System.Environment]::CurrentDirectory = $script:RootDirectory
}

# ============================================================================
# The five files as syntax trees (, S-1, S-3, S-4, S-5, S-6, S-9, SI-7)
# ============================================================================

Describe 'The five files are parsed and define the new functions' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
    }

    It 'parses <Name> without errors and finds the functions of the slice in it' -ForEach $script:Files {
        $ast = Get-AstOf $Parts
        $defined = Get-DefinedFunctions $ast
        foreach ($function in $Functions) { $defined | Should -Contain $function -Because "$Name must define $function" }
    }
}

Describe 'S-1 S-3 S-4 S-5 S-6 S-9 the forbidden list over <Name>' -ForEach $script:Files {
    BeforeAll {
        $script:Ast = Get-AstOf $Parts
        $script:FileName = $Name
        $script:IsLib = $Lib
    }
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        # a file that defines nothing would pass every check below, so it must define its functions first
        foreach ($function in $Functions) { (Get-DefinedFunctions $script:Ast) | Should -Contain $function -Because "$Name must define $function" }
    }

    It 'S-1 calls none of Remove-Item, Move-Item, Copy-Item, Rename-Item, Invoke-Item, Clear-RecycleBin, Start-Job, cmd, cmd.exe, schtasks' {
        Assert-NoViolations (Find-Commands $script:Ast @('Remove-Item', 'Move-Item', 'Copy-Item', 'Rename-Item', 'Invoke-Item', 'Clear-RecycleBin', 'Start-Job', 'cmd', 'cmd.exe', 'schtasks', 'taskkill', 'taskkill.exe', 'runas', 'Invoke-Expression'))
        (Get-DefinedFunctions $script:Ast).Count | Should -BeGreaterThan 0 -Because 'the file must define functions'
    }

    It 'S-1 calls no low-level removal and no Recycle Bin function of the file helpers, and no old name of a helper' {
        Assert-NoViolations (Find-Commands $script:Ast @('Remove-SwTreeEntry', 'Remove-SwDirectoryTree', 'Move-SwItemToRecycleBin', 'Remove-SafeItem', 'Remove-SafeItems', 'Remove-OldFiles',
                'Clear-DirectoryContents', 'Remove-TreeEntry', 'Remove-SafeDirectoryTree', 'Move-SweeprItemToRecycleBin'))
    }

    It 'S-6 passes -Recycle to no command' {
        $found = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandParameterAst] -and $n.ParameterName -eq 'Recycle' }, $true)
        @($found).Count | Should -Be 0
    }

    It 'S-1 SI-2 calls no member that deletes, moves, copies or replaces, and none that changes attributes or times' {
        Assert-NoViolations (Find-MemberCalls $script:Ast @('Delete', 'Move', 'Copy', 'Replace', 'MoveTo', 'CopyTo', 'SetAttributes', 'SetLastWriteTime', 'SetCreationTime', 'SetLastAccessTime', 'SetLastWriteTimeUtc', 'SetCreationTimeUtc', 'SetAccessControl', 'DeleteFile', 'DeleteDirectory') '(?i)(^|\.)(File|Directory|FileSystem|FileInfo|DirectoryInfo|Microsoft\.VisualBasic\.FileIO\.FileSystem)$')
        Assert-NoViolations @(Find-MemberCalls $script:Ast @('Delete', 'MoveTo', 'CopyTo', 'Kill') | Where-Object { $_.Name -notmatch '^\[' })
    }

    It 'S-3 starts no process: no Start-Process outside Edit-SwWhitelist, no Process or ProcessStartInfo type, no Process.Start, no Stop-Process' {
        $starts = @(Find-Commands $script:Ast @('Start-Process', 'Stop-Process'))
        if ($script:FileName -eq 'bin\clean.ps1') {
            foreach ($use in $starts) {
                $use.Name | Should -Be 'Start-Process'
                $use.Function | Should -Be 'Edit-SwWhitelist'
            }
        }
        else { Assert-NoViolations $starts }
        Assert-NoViolations (Find-TypeUses $script:Ast '(?i)^(System\.)?Diagnostics\.Process(StartInfo)?$|^Process(StartInfo)?$')
    }

    It 'S-3 S-5 uses no service command, no registry command or path, no web command, no WMI command, no COM object and no elevation' {
        Assert-NoViolations (Find-Commands $script:Ast @('Stop-Service', 'Set-Service', 'Restart-Service', 'Start-Service', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty',
                'Invoke-WebRequest', 'Invoke-RestMethod', 'Get-CimInstance', 'Get-WmiObject', 'Invoke-CimMethod', 'Register-ScheduledTask', 'New-ScheduledTask'))
        Assert-NoViolations (Find-Strings $script:Ast '(?i)^(HKLM|HKCU|HKCR|HKU|HKCC):|^Registry::|Shell\.Application|^(runas|taskkill|schtasks)(\.exe)?$|^RunAs$')
        Assert-NoViolations (Find-TypeUses $script:Ast '(?i)Win32\.Registry|^(System\.)?Net\.|^WebClient$|^Registry$')
        $verbs = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandParameterAst] -and $n.ParameterName -in @('Verb', 'ComObject', 'Credential') }, $true)
        @($verbs).Count | Should -Be 0
    }

    It 'S-4 calls none of New-Item, Set-Content, Add-Content, Out-File, Clear-Content, Read-Host and Write-Progress where it must not' {
        $names = @('Set-Content', 'Add-Content', 'Out-File', 'Clear-Content', 'Read-Host', 'Write-Progress', 'New-Item')
        if (-not $script:IsLib) { $names = @('Set-Content', 'Add-Content', 'Out-File', 'Clear-Content', 'Read-Host', 'Write-Progress', 'New-Item') }
        Assert-NoViolations (Find-Commands $script:Ast $names)
    }

    It 'S-4 SI-6 clears the screen only in Start-SwCleanRun and writes to the host only through the writers of the log module in the sections' {
        $clear = @(Find-Commands $script:Ast @('Clear-Host'))
        if ($script:IsLib) {
            Assert-NoViolations $clear
            Assert-NoViolations (Find-Commands $script:Ast @('Write-Host', 'Write-Output', 'Write-Warning', 'Write-Error', 'Write-Verbose', 'Write-Information', 'Out-Host', 'Out-Default'))
        }
        else { foreach ($use in $clear) { $use.Function | Should -Be 'Start-SwCleanRun' } }
    }

    It 'S-1 S-4 writes, creates, truncates or opens for writing with .NET only in the places that write by design' {
        $writers = @('WriteAllText', 'WriteAllBytes', 'WriteAllLines', 'AppendAllText', 'AppendAllLines', 'CreateDirectory', 'Create', 'CreateText', 'AppendText', 'OpenWrite')
        $calls = @(Find-MemberCalls $script:Ast $writers '(?i)(^|\.)(File|Directory)$')
        if ($script:IsLib) { Assert-NoViolations $calls }
        else {
            $outside = @($calls | Where-Object { $_.Function -in @('', 'Show-SwCleanSummary', 'Show-SwCleanHelp', 'Invoke-SwCleanMain', 'Get-SwPathCollision') })
            Assert-NoViolations $outside
        }
        $modes = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and $n.Expression.TypeName.FullName -match '(?i)FileMode$' }, $true)
        if ($script:IsLib) {
            @($modes | Where-Object { $_.Member.Extent.Text -in @('Create', 'CreateNew', 'OpenOrCreate', 'Append', 'Truncate') }).Count | Should -Be 0
        }
    }

    It 'S-9 never writes to the operations log' {
        Assert-NoViolations (Find-Commands $script:Ast @('Write-SwOperation', 'Write-SweeprOperation', 'Add-SwOperationText', 'Add-SweeprOperationText'))
    }

    It 'calls no old name from the base, log, ui and file modules' {
        $old = @('Test-IsAdmin', 'Get-FreeSpace', 'Get-WindowsVersion', 'Format-ByteSize', 'Test-ProtectedPath', 'Resolve-SafePath', 'Get-WhitelistState', 'Test-Whitelisted',
            'Write-Info', 'Write-Success', 'Write-SweeprWarning', 'Write-SweeprError', 'Write-DryRun', 'Start-Section', 'Stop-Section', 'Set-SectionActivity', 'Start-Spinner',
            'Stop-Spinner', 'Update-Spinner', 'Enable-DebugMode', 'Test-SafePath', 'Get-SweeprPathSnapshot', 'Test-SweeprPathSnapshot', 'Test-IsReparsePoint', 'Get-PathSize',
            'Get-PathSizeKB', 'Add-SweeprNotMeasured', 'Add-DryRunListEntries', 'Get-CleanupStats', 'Reset-CleanupStats', 'Set-DryRunMode', 'Test-DryRunMode', 'Show-SummaryBlock',
            'Show-Banner', 'Get-TerminalSize', 'Get-ConfigPath', 'Get-CachePath', 'Get-SweeprColor', 'Get-SweeprIcon', 'Write-Debug')
        Assert-NoViolations (Find-Commands $script:Ast $old)
    }

    It 'SI-7 loads its dependencies from its own folder: every dot-source line names $PSScriptRoot' {
        $dots = @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot }, $true))
        $dots.Count | Should -BeGreaterThan 0
        foreach ($dot in $dots) { $dot.Extent.Text | Should -Match 'PSScriptRoot' -Because $dot.Extent.Text }
    }

    It 'SI-7 names the files it loads: <Loads>' {
        $text = [System.IO.File]::ReadAllText((Get-FilePath $Parts), $script:Utf8)
        foreach ($load in $Loads) { $text | Should -Match ([regex]::Escape($load)) -Because $load }
    }
}

Describe 'SI-7 the lib\clean files create no variables outside the script scope' -ForEach $script:LibFiles {
    BeforeAll { $script:Ast = Get-AstOf $Parts }
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        foreach ($function in $Functions) { (Get-DefinedFunctions $script:Ast) | Should -Contain $function -Because "$Name must define $function" }
    }

    It 'CL-16 assigns at the top level only to script variables, never to a global one, and has no top-level loop' {
        $assignments = @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) |
                Where-Object { (Get-EnclosingFunction $_) -eq '' })
        foreach ($assignment in $assignments) {
            $target = $assignment.Left
            if ($target -is [System.Management.Automation.Language.ConvertExpressionAst]) { $target = $target.Child }
            $target | Should -BeOfType [System.Management.Automation.Language.VariableExpressionAst] -Because $assignment.Extent.Text
            # the loading scope gets the error preference Stop (SI-7); every other variable is a script variable
            if ($target.VariablePath.UserPath -eq 'ErrorActionPreference') { continue }
            $target.VariablePath.IsScript | Should -BeTrue -Because $assignment.Extent.Text
        }
        $global = @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.IsGlobal }, $true))
        $global.Count | Should -Be 0
        $loops = @($script:Ast.FindAll({ param($n) ($n -is [System.Management.Automation.Language.ForEachStatementAst]) -or ($n -is [System.Management.Automation.Language.ForStatementAst]) }, $true) |
                Where-Object { (Get-EnclosingFunction $_) -eq '' })
        $loops.Count | Should -Be 0
    }

    It 'SI-7 uses no Set-Variable or New-Variable' {
        Assert-NoViolations (Find-Commands $script:Ast @('Set-Variable', 'New-Variable', 'Remove-Variable', 'Set-Location', 'Push-Location', 'Pop-Location'))
    }
}

Describe 'CL-24 the process list is read in one place' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
    }

    It 'calls Get-Process nowhere in the five files but in Test-SwCacheOwnerIdle, and once there' {
        $all = New-Object System.Collections.Generic.List[object]
        foreach ($parts in $script:FileParts) {
            foreach ($use in @(Find-Commands (Get-AstOf $parts) @('Get-Process', 'Get-WmiObject', 'Get-CimInstance'))) { $all.Add($use) }
        }
        $all.Count | Should -Be 1
        $all[0].Name | Should -Be 'Get-Process'
        $all[0].Function | Should -Be 'Test-SwCacheOwnerIdle'
    }
}

# ============================================================================
# Real runs of every section with mocked helpers (S-1 a, S-3, S-6, S-9)
# ============================================================================

Describe 'S-1 S-3 S-6 S-9 section <Section> calls only the allowed helpers, in <Mode>' -ForEach @(
    foreach ($section in $script:Sections) { foreach ($mode in $script:RunModes) { @{ Section = $section.Section; Admin = $section.Admin; Mode = $mode.Mode; Dry = $mode.Dry } } }
) {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-HelperSpies
        Use-GetProcessSpy
        New-FullFixture
        Use-AdminAnswer $Admin
        Mock Remove-SwItem { if ($Recycle) { throw 'the Recycle Bin must never be used (test)' }; $script:Calls.Add([pscustomobject]@{ Fn = 'Remove-SwItem'; Path = $Path; Paths = @() }); $true }
        Use-ThrowingCmdlets
        Set-SwDryRunMode -Enabled $Dry
    }
    AfterEach { Stop-Case }

    It 'S-1 offers work to Remove-SwItems, Clear-SwDirectoryContents and Remove-SwOldFiles only, at least once' {
        $null = Invoke-Section $Section
        $script:Calls.Count | Should -BeGreaterThan 0
        foreach ($call in $script:Calls) { $call.Fn | Should -BeIn @('Remove-SwItems', 'Clear-SwDirectoryContents', 'Remove-SwOldFiles', 'Remove-SwItem') }
    }

    It 'S-3 S-6 S-9 calls none of the cmdlets that throw, no Recycle Bin function, no operations log writer and no Get-Process' {
        $null = Invoke-Section $Section
        foreach ($name in $script:ThrowingNames) { Should -Invoke $name -Times 0 -Exactly }
        $script:Ops.Count | Should -Be 0
        $script:ProcCalls | Should -Be 0
    }

    It 'SI-6 writes nothing to the pipeline' {
        @(Invoke-Section $Section).Count | Should -Be 0
    }
}

# ============================================================================
# Sections: titles, isolation, silence (SI-1, SI-6, CL-20, S-16)
# ============================================================================

Describe 'SI-1 CL-20 S-16 SI-6 section <Section>' -ForEach $script:Sections {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-AdminAnswer $Admin
    }
    AfterEach { Stop-Case }

    It 'SI-1 opens the section <Title> once and closes it once, also when there is nothing to do' {
        Use-HelperSpies
        $null = Invoke-Section $Section
        @($script:Sections) | Should -Be @(('start:' + $Title), 'stop')
    }

    It 'SI-1 opens and closes the section once, in this order, with all targets present' {
        Use-HelperSpies
        New-FullFixture
        $null = Invoke-Section $Section
        @($script:Sections).Count | Should -Be 2
        $script:Sections[0] | Should -BeExactly ('start:' + $Title)
        $script:Sections[1] | Should -BeExactly 'stop'
    }

    It 'S-16 CL-20 does not throw and closes the section once when every helper and probe fails' {
        New-FullFixture
        foreach ($name in 'Remove-SwItems', 'Clear-SwDirectoryContents', 'Remove-SwOldFiles', 'Remove-SwItem', 'Get-SwCacheProfiles', 'Get-SwPathSnapshot', 'Test-SwSafePath', 'Test-SwPathSnapshot', 'Test-SwCacheOwnerIdle') {
            Mock $name { throw 'failure (test)' }
        }
        { $null = Invoke-Section $Section } | Should -Not -Throw
        @($script:Sections | Where-Object { $_ -eq 'stop' }).Count | Should -Be 1
        @($script:Sections | Where-Object { $_ -like 'start:*' }).Count | Should -Be 1
    }

    It 'SI-6 writes nothing to the pipeline when the helpers write something' {
        New-FullFixture
        foreach ($name in 'Remove-SwItems', 'Clear-SwDirectoryContents', 'Remove-SwOldFiles', 'Remove-SwItem', 'Add-SwNotMeasured') {
            Mock $name { 'noise'; $true; 42 }
        }
        @(Invoke-Section $Section).Count | Should -Be 0
    }

    It 'CL-22 hands the helpers no path twice and none below another, also with TEMP set to the local Temp folder' {
        Use-HelperSpies
        New-FullFixture
        Set-Env 'TEMP' (P $script:Local 'Temp')
        $null = Invoke-Section $Section
        $paths = @(Get-CallPaths)
        $paths.Count | Should -BeGreaterThan 0
        Test-Disjoint $paths | Should -BeTrue
    }

    It 'CL-22 hands the helpers no path twice and none below another with the default TEMP' {
        Use-HelperSpies
        New-FullFixture
        $null = Invoke-Section $Section
        Test-Disjoint @(Get-CallPaths) | Should -BeTrue
    }
}

# ============================================================================
# The preview over all sections (S-4, S-8, CL-22)
# ============================================================================

Describe 'S-4 S-8 CL-22 a preview over all five sections' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-AdminAnswer $true
        New-FullFixture
        $script:ListFile = P $TestDrive ('list' + $script:WorkCounter) 'clean-list.txt'
        $null = New-Dir (Split-Path -Parent $script:ListFile)
        [System.IO.File]::WriteAllText($script:ListFile, "# Sweepr Cleanup Preview - 2026-01-01 00:00:00`r`n`r`n", $script:Utf8)
        $script:ExportListFile = $script:ListFile
        Set-SwDryRunMode -Enabled $true
        $script:Before = Get-Listing $script:Work
    }
    AfterEach { Stop-Case }

    It 'S-4 leaves the file tree as it was and the operations log untouched, and the list holds the findings' {
        Mock Remove-Item { throw 'Remove-Item must not run in a preview (test)' }
        foreach ($section in $script:SectionNames) { $null = Invoke-Section $section }
        Same-Listing (Get-Listing $script:Work) $script:Before | Should -BeTrue
        $script:Ops.Count | Should -Be 0
        @((Get-FileLines $script:ListFile) | Where-Object { $_.Length -gt 0 -and -not $_.StartsWith('#') }).Count | Should -BeGreaterThan 30
    }

    It 'S-8 lists exactly as many paths as the statistics count, and no path below another' {
        foreach ($section in $script:SectionNames) { $null = Invoke-Section $section }
        $paths = @((Get-FileLines $script:ListFile) | Where-Object { $_.Length -gt 0 -and -not $_.StartsWith('#') })
        $paths.Count | Should -Be (Get-SwCleanupStats).FilesCleaned
        Test-Disjoint $paths | Should -BeTrue
    }

    It 'S-8 lists exactly as many paths as the statistics count, and no path below another, with TEMP set to the local Temp folder' {
        Set-Env 'TEMP' (P $script:Local 'Temp')
        foreach ($section in $script:SectionNames) { $null = Invoke-Section $section }
        $paths = @((Get-FileLines $script:ListFile) | Where-Object { $_.Length -gt 0 -and -not $_.StartsWith('#') })
        $paths.Count | Should -Be (Get-SwCleanupStats).FilesCleaned
        Test-Disjoint $paths | Should -BeTrue
    }

    It 'S-17 lists nothing of what the catalog does not name' {
        foreach ($section in $script:SectionNames) { $null = Invoke-Section $section }
        $paths = @((Get-FileLines $script:ListFile) | Where-Object { $_.Length -gt 0 -and -not $_.StartsWith('#') })
        foreach ($root in (P $script:Roam 'Spotify'), (P $script:Roam 'Zoom'), (P $script:Roam 'Code'), (P $script:Roam 'Code - Insiders'), (P $script:Roam 'Sublime Text'),
            (P $script:Local 'Zed'), (P $script:Local 'EpicGamesLauncher'), (P $script:Roam 'Adobe'), (P $script:Local 'Steam'), (P $script:WinDir 'Temp'), (P $script:WinDir 'Minidump'),
            (P $script:Roam 'Microsoft' 'Teams' 'blob_storage'), (P $script:Local 'Packages' 'Other_app')) {
            Test-AnyUnder $paths $root | Should -BeFalse -Because $root
        }
        foreach ($path in $paths) {
            $path | Should -Not -Match '[\\/](Cookies|Login Data|Local Storage|IndexedDB|Service Worker|Local State|prefs\.js)([\\/]|$)'
        }
    }
}

Describe 'S-1 S-2 S-17 a real run over all five sections' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-AdminAnswer $true
        New-FullFixture
        Set-SwDryRunMode -Enabled $false
    }
    AfterEach { Stop-Case }

    It 'S-1 removes the offered caches, files and reports, and keeps everything the catalog does not name' {
        foreach ($section in $script:SectionNames) { $null = Invoke-Section $section }
        foreach ($gone in (P (Get-ChromeRoot) 'Default' 'Cache' 'entry'), (P (Get-EdgeRoot) 'ShaderCache' 'entry'), (P $script:Roam 'Slack' 'Cache' 'entry'),
            (P (Get-TeamsNewRoot) 'Default' 'Cache' 'entry'), (P $script:Local 'D3DSCache' 'entry'), (P $script:Scratch 'old.tmp'), (P $script:Local 'Temp' 'x.log'), (P $script:Roam 'old.log'),
            (P $script:Local 'Microsoft' 'Windows' 'WER' 'ReportArchive' 'old'), (P $script:Local 'CrashDumps' 'old.dmp'),
            (P $script:ProgramData 'Microsoft' 'Windows' 'WER' 'ReportQueue' 'old')) {
            Exists $gone | Should -BeFalse -Because $gone
        }
        foreach ($kept in (P (Get-ChromeRoot) 'Default' 'Cookies' 'keep.dat'), (P (Get-ChromeRoot) 'Default' 'Service Worker' 'CacheStorage' 'offline'), (P (Get-ChromeRoot) 'Local State'),
            (P $script:Roam 'Slack' 'Local Storage' 'keep.dat'), (P $script:Roam 'Spotify' 'Data' 'offline.dat'), (P $script:Roam 'Zoom' 'data' 'keep.dat'), (P $script:Roam 'Code' 'Cache' 'entry'),
            (P $script:Local 'EpicGamesLauncher' 'Saved' 'webcache' 'entry'), (P $script:Roam 'Microsoft' 'Teams' 'blob_storage' 'keep.dat'), (P (Get-TeamsNewRoot) 'Default' 'IndexedDB' 'state'),
            (P (Get-TeamsNewRoot) 'Cache' 'entry'), (P $script:Local 'Packages' 'Other_app' 'LocalCache' 'Default' 'Cache' 'entry'), (P $script:Scratch 'new.tmp'),
            (P $script:Scratch 'folder' 'inner.tmp'), (P $script:Roam 'keep.txt'), (P $script:WinDir 'Temp' 'old.tmp'), (P $script:WinDir 'Minidump' 'a.dmp')) {
            Exists $kept | Should -BeTrue -Because $kept
        }
    }

    It 'S-2 removes nothing a whitelist line holds, whatever section names it' {
        Set-Whitelist @((P $script:Roam 'Slack' 'Cache'), (P $script:Scratch 'old.tmp'), (P $script:Roam 'old.log'))
        foreach ($section in $script:SectionNames) { $null = Invoke-Section $section }
        Exists (P $script:Roam 'Slack' 'Cache' 'entry') | Should -BeTrue
        Exists (P $script:Scratch 'old.tmp') | Should -BeTrue
        Exists (P $script:Roam 'old.log') | Should -BeTrue
        Exists (P $script:Roam 'Slack' 'GPUCache' 'entry') | Should -BeFalse
    }
}

# ============================================================================
# Loading each file alone in a fresh process (SI-7, CL-16, )
# ============================================================================

Describe 'SI-7 loading <Name> alone in a fresh process' -ForEach $script:LibFiles {
    BeforeAll {
        $script:Sandbox = New-Dir (P $TestDrive ('sandbox-' + [guid]::NewGuid().ToString('N')))
        $script:LoadData = P $script:Sandbox 'data'
        $script:LoadScript = @'
$ErrorActionPreference = 'Continue'
Set-StrictMode -Off
Set-Location -LiteralPath __SANDBOX__
$envBefore = (([System.Environment]::GetEnvironmentVariables().GetEnumerator() | Sort-Object Key | ForEach-Object { $_.Key + '=' + $_.Value }) -join '|')
$prefBefore = (@($DebugPreference, $VerbosePreference, $WarningPreference, $InformationPreference, $ConfirmPreference, $WhatIfPreference) -join '|')
$treeBefore = @(Get-ChildItem -LiteralPath __SANDBOX__ -Recurse -Force).Count
$variablesBefore = @(Get-Variable | ForEach-Object { $_.Name })
. __FILE__
. __FILE__
'EAP=' + $ErrorActionPreference
try { $null = $undefinedVariableForTest; 'STRICT=False' } catch { 'STRICT=True' }
'ENV=' + ((([System.Environment]::GetEnvironmentVariables().GetEnumerator() | Sort-Object Key | ForEach-Object { $_.Key + '=' + $_.Value }) -join '|') -ceq $envBefore)
'PREF=' + (((@($DebugPreference, $VerbosePreference, $WarningPreference, $InformationPreference, $ConfirmPreference, $WhatIfPreference) -join '|')) -ceq $prefBefore)
'TREE=' + (@(Get-ChildItem -LiteralPath __SANDBOX__ -Recurse -Force).Count -eq $treeBefore)
'CWD=' + ((Get-Location).Path -ceq __SANDBOX__)
'CORE=' + (@('Test-SwAdmin', 'Write-SwInfo', 'Remove-SwItems', 'Add-SwNotMeasured' | Where-Object { Get-Command -Name $_ -CommandType Function -ErrorAction SilentlyContinue }).Count)
'FUNCTIONS=' + (@(__NAMES__ | Where-Object { Get-Command -Name $_ -CommandType Function -ErrorAction SilentlyContinue }).Count)
'@
    }

    It 'SI-7 defines its functions, writes nothing, changes nothing but StrictMode and the error preference, and a second load is harmless' {
        $file = Get-FilePath $Parts
        $expectedNames = @($Functions) + @($Extra)
        $names = ($expectedNames | ForEach-Object { "'" + $_ + "'" }) -join ', '
        $script = $script:LoadScript.Replace('__FILE__', (ConvertTo-TestLiteral $file)).Replace('__SANDBOX__', (ConvertTo-TestLiteral $script:Sandbox)).Replace('__NAMES__', $names)
        $run = Invoke-ChildPowerShell -Script $script -WorkingDirectory $script:Sandbox -Environment @{
            SWEEPR_DATA_DIR = $script:LoadData; SWEEPR_NO_OPLOG = '1'; USERPROFILE = (P $script:Sandbox 'profile'); LOCALAPPDATA = (P $script:Sandbox 'profile' 'Local')
            APPDATA = (P $script:Sandbox 'profile' 'Roaming'); TEMP = (P $script:Sandbox 'temp') } -RemoveEnvironment @('SWEEPR_DRY_RUN', 'SWEEPR_DEBUG')
        $run.ExitCode | Should -Be 0
        (Get-ChildStderr $run.Err) | Should -BeExactly ''
        $lines = @($run.Out -split "`r?`n" | Where-Object { $_.Length -gt 0 })
        $lines | Should -Be @('EAP=Stop', 'STRICT=True', 'ENV=True', 'PREF=True', 'TREE=True', 'CWD=True', 'CORE=4', ('FUNCTIONS=' + $expectedNames.Count))
        [System.IO.Directory]::Exists($script:LoadData) | Should -BeFalse
    }
}

Describe 'the removed functions are not defined' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
    }

    It 'does not define <_>' -ForEach $script:RemovedNames {
        Assert-Defined @('Invoke-SwUserCleanup', 'Clear-SwAppCaches', 'Invoke-SwSystemCleanup')
        Get-Command -Name $_ -CommandType Function -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}
