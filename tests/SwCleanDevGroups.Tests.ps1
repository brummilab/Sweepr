# Sweepr - tests for lib\clean\dev.ps1, the section "Developer tools": the order of the twelve groups, the
# rows of every group with the sink, path and description of the target table, path building from the
# environment, rows with a placeholder folder, the search in the Stack snapshots and the isolation of rows.
#
# The rule numbers in the test names (CD-, CA-, S- and so on) number the rules and the safety invariants
# of the behavior of the developer tool and application cleanup; each rule and invariant has at least one test.
# The other files of this slice are SwCleanDevLoad, SwCleanDevScan, SwCleanDevOwnerPath, SwCleanDevOwnerRun,
# SwCleanDevProcess, SwCleanDevEditors, SwCleanAppsGroups, SwCleanAppsMedia and SwCleanDevAppsSafety.
#
# Interface pinned here (new names, lib\clean\dev.ps1, loaded by dot-sourcing):
#   Invoke-SwDevCleanup                     the section "Developer tools"                 (CD-9)
#   Clear-SwNpmFamilyCaches, Clear-SwNodeBuildCaches, Clear-SwPythonCaches, Clear-SwDotNetCaches,
#   Clear-SwGoCaches, Clear-SwMiseCache, Clear-SwElixirCaches, Clear-SwHaskellCaches, Clear-SwOCamlCaches,
#   Clear-SwCloudCliCaches, Clear-SwEditorCaches, Clear-SwIdeCaches            (one group each, CD-23 to CD-29)
#   Invoke-SwOwnerCacheCleanup              the owner path of one tool (called by the groups for npm, pnpm, pip, go, mise)
#   Get-SwBoundedFileScan                   the bounded search of the groups with file rows (D10, D17)
#
# Seams used with Mock: Clear-SwDirectoryContents, Remove-SwItems, Remove-SwOldFiles, Clear-SwAppCache and
# Invoke-SwOwnerCacheCleanup (spies that record every call in order), Get-SwBoundedFileScan (spy with answers
# per root), Get-SwCacheProfiles (real, or a fixed answer), Get-SwOwnerCachePath, Invoke-SwOwnerCommand and
# New-SwOwnerProcess (a net that finds no tool and starts nothing), Get-SwPathSnapshot and Test-SwPathSnapshot
# (substitute objects), Get-Process, the writers of the log module, Add-SwNotMeasured, Write-SwOperation.
#
# Platform notes:
#   - Paths are built from $TestDrive with the separator of the host (host paths). The tables write Windows
#     paths; the expected values here join the same parts with the separator of the host.
#   - Real removals happen only below $TestDrive and only in the end-to-end cases, with substitute identities.
#   - Tests marked [W] need real Windows. They are meant to fail on Linux and belong in
#     tests/linux-known-failures.txt.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    $script:Groups = @(
        @{ Group = 'Clear-SwNpmFamilyCaches' }
        @{ Group = 'Clear-SwNodeBuildCaches' }
        @{ Group = 'Clear-SwPythonCaches' }
        @{ Group = 'Clear-SwDotNetCaches' }
        @{ Group = 'Clear-SwGoCaches' }
        @{ Group = 'Clear-SwMiseCache' }
        @{ Group = 'Clear-SwElixirCaches' }
        @{ Group = 'Clear-SwHaskellCaches' }
        @{ Group = 'Clear-SwOCamlCaches' }
        @{ Group = 'Clear-SwCloudCliCaches' }
        @{ Group = 'Clear-SwEditorCaches' }
        @{ Group = 'Clear-SwIdeCaches' }
    )
    $script:BadValues = @(
        @{ Label = 'not set'; Value = $null }
        @{ Label = 'blank'; Value = '   ' }
        @{ Label = 'a relative path'; Value = 'rel/x' }
        @{ Label = 'a drive-relative path'; Value = 'C:Temp' }
        @{ Label = 'a root-relative path on Windows'; Value = '\x' }
        @{ Label = 'a UNC path'; Value = '\\server\x' }
    )
    # Variable, the group that has targets only below it (and no other variable).
    $script:RootCases = @(
        @{ Variable = 'LOCALAPPDATA'; Group = 'Clear-SwNodeBuildCaches' }
        @{ Variable = 'USERPROFILE'; Group = 'Clear-SwElixirCaches' }
        @{ Variable = 'APPDATA'; Group = 'Clear-SwCloudCliCaches' }
    )
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:CoreDir = [System.IO.Path]::Combine($script:RepoRoot, 'lib', 'core')
    $script:CleanDir = [System.IO.Path]::Combine($script:RepoRoot, 'lib', 'clean')
    $script:OnWindows = [System.IO.Path]::DirectorySeparatorChar -eq '\'
    $script:IsDesktop = $PSVersionTable['PSEdition'] -eq 'Desktop'
    $script:Sep = [string][System.IO.Path]::DirectorySeparatorChar
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
    $script:WorkCounter = 0
    $script:Links = [System.Collections.Generic.List[string]]::new()
    # The path of this PowerShell, read before any case mocks Get-Process.
    $script:HostExe = (Get-Process -Id $PID).Path

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
        '_SWEEPR_OPLOG_RUN_ID', 'USERPROFILE', 'HOME', 'LOCALAPPDATA', 'APPDATA', 'TEMP', 'PROGRAMDATA', 'WINDIR', 'SYSTEMROOT', 'PATH')
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
    # Time stamps of a file or folder: creation and last write, days in the past.
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
    # Creation and write time apart (days in the past each); where the host keeps the creation time of a file
    # fixed, the case that needs it is marked [W].
    function script:Set-Times([string]$Path, [double]$CreatedDays, [double]$WrittenDays) {
        [System.IO.File]::SetCreationTime($Path, [datetime]::Now.AddDays(-$CreatedDays))
        [System.IO.File]::SetLastWriteTime($Path, [datetime]::Now.AddDays(-$WrittenDays))
    }
    function script:New-OldFile([string]$Path, [double]$Days = 30, [int]$Bytes = 3) {
        $null = New-File $Path $Bytes
        Set-Age $Path $Days
        $Path
    }
    function script:Get-Listing([string]$Root) {
        if (-not [System.IO.Directory]::Exists($Root)) { return , @('<missing>') }
        $rows = [System.Collections.Generic.List[string]]::new()
        foreach ($item in @(Get-ChildItem -LiteralPath $Root -Recurse -Force)) {
            $rel = $item.FullName.Substring($Root.Length)
            if ($item.PSIsContainer) { $rows.Add(('D {0} {1}' -f $rel, $item.LastWriteTimeUtc.Ticks)) }
            else { $rows.Add(('F {0} {1} {2}' -f $rel, $item.Length, $item.LastWriteTimeUtc.Ticks)) }
        }
        , @($rows | Sort-Object)
    }
    function script:Same-Listing($Left, $Right) { (@($Left) -join '|') -ceq (@($Right) -join '|') }
    function script:Get-FileText([string]$Path) { [System.IO.File]::ReadAllText($Path, $script:Utf8) }
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

    # Runs a block that must throw and gives the error record; a missing function does not count as the throw.
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
    function script:Get-ParamCount([string]$Name) { $signature = Get-ParamSignature $Name; @($signature).Count }
    function script:Get-ParamLine([string]$Function, [string]$Parameter) {
        $all = Get-ParamSignature $Function
        $all | Where-Object { $_.StartsWith($Parameter + '|', [System.StringComparison]::Ordinal) } | Select-Object -First 1
    }

    # ---- identity: a fake for Get-SwPathSnapshot and Test-SwPathSnapshot (Linux has none, file-ops F-8) --

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
    # Paths in $script:FakeNoIdentity have no identity; paths in $script:FakeReplaced fail the identity test.
    function script:Use-FakeIdentity {
        $script:FakeNoIdentity = [System.Collections.Generic.List[string]]::new()
        $script:FakeReplaced = [System.Collections.Generic.List[string]]::new()
        $script:SnapshotCalls = [System.Collections.Generic.List[object]]::new()
        $script:SnapshotTests = [System.Collections.Generic.List[string]]::new()
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
    # and closes, what it notes as not measured and what it would write to the operations log.
    function script:Use-Spies([switch]$RealSections) {
        $script:Log = [System.Collections.Generic.List[string]]::new()
        $script:HostLines = [System.Collections.Generic.List[string]]::new()
        $script:Sections = [System.Collections.Generic.List[string]]::new()
        $script:NotMeasured = [System.Collections.Generic.List[object]]::new()
        $script:Ops = [System.Collections.Generic.List[object]]::new()
        Mock Write-SwInfo { $script:Log.Add('INFO|' + (Remove-Ansi ([string]$Message))) }
        Mock Write-SwSuccess { $script:Log.Add('SUCCESS|' + (Remove-Ansi ([string]$Message))) }
        Mock Write-SwWarning { $script:Log.Add('WARN|' + (Remove-Ansi ([string]$Message))) }
        Mock Write-SwError { $script:Log.Add('ERROR|' + (Remove-Ansi ([string]$Message))) }
        Mock Write-SwDryRun { $script:Log.Add('DRYRUN|' + (Remove-Ansi ([string]$Message))) }
        Mock Write-SwDebug { $script:Log.Add('DEBUG|' + (Remove-Ansi ([string]$Message))) }
        Mock Write-Host { $script:HostLines.Add((Remove-Ansi (@($Object | ForEach-Object { [string]$_ }) -join ' '))) }
        if (-not $RealSections) {
            Mock Start-SwSection { $script:Sections.Add('start:' + $Title) }
            Mock Stop-SwSection { $script:Sections.Add('stop') }
        }
        Mock Add-SwNotMeasured { $script:NotMeasured.Add([pscustomobject]@{ Name = $Name; Reason = $Reason; Section = [string]$script:CurrentSection.Name }) }
        Mock Write-SwOperation { $script:Ops.Add([pscustomobject]@{ Action = $Action; Path = $Path; Detail = $Detail }) }
    }
    function script:Get-AllText { (@($script:Log) + @($script:HostLines)) -join "`n" }
    function script:Get-LogLines([string]$Level) {
        @($script:Log | Where-Object { $_.StartsWith($Level + '|', [System.StringComparison]::Ordinal) } | ForEach-Object { $_.Substring($Level.Length + 1) })
    }
    function script:Get-NotMeasuredFor([string]$Name) { @($script:NotMeasured | Where-Object { $_.Name -ceq $Name }) }

    # One recorded sink call; fields that a sink does not have stay $null.
    function script:Add-Call([string]$Fn, [hashtable]$Fields) {
        $record = [ordered]@{ Fn = $Fn; Path = $null; Paths = @(); Description = $null; CanRemove = $null; DaysOld = $null; Filter = $null; Processes = $null; Name = $null; Query = $null; Arguments = $null }
        foreach ($key in $Fields.Keys) { $record[$key] = $Fields[$key] }
        $script:Calls.Add([pscustomobject]$record)
    }
    # The removal helpers as spies; every call is recorded in order and removes nothing.
    function script:Use-HelperSpies {
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $script:SinkLeak = $false
        Mock Remove-SwItems { Add-Call 'Remove-SwItems' @{ Paths = @($Paths); Description = $Description; CanRemove = $CanRemove }; if ($script:SinkLeak) { 'leak' } }
        Mock Clear-SwDirectoryContents { Add-Call 'Clear-SwDirectoryContents' @{ Path = $Path; Description = $Description; CanRemove = $CanRemove }; if ($script:SinkLeak) { 'leak' } }
        Mock Remove-SwOldFiles { Add-Call 'Remove-SwOldFiles' @{ Path = $Path; Description = $Description; DaysOld = $DaysOld; Filter = $Filter }; if ($script:SinkLeak) { 'leak' } }
        Mock Remove-SwItem { Add-Call 'Remove-SwItem' @{ Path = $Path; Description = $Description }; $true }
    }
    # Clear-SwAppCache as a spy (the owner-guarded row sink); recorded in the same list as the helpers.
    function script:Use-AppCacheSpy {
        Mock Clear-SwAppCache { Add-Call 'Clear-SwAppCache' @{ Path = $Path; Description = $Description; Processes = @($Processes) }; if ($script:SinkLeak) { 'leak' } }
    }
    # The owner cleanup of one tool (what the groups call for npm, pnpm, pip, go, mise) as a spy.
    function script:Use-OwnerCleanupSpy {
        Mock Invoke-SwOwnerCacheCleanup { Add-Call 'Invoke-SwOwnerCacheCleanup' @{ Name = $Name; Query = @($Query); Arguments = @($Arguments); Description = $Description }; if ($script:SinkLeak) { 'leak' } }
    }
    function script:Get-Calls([string]$Fn) { @($script:Calls | Where-Object { $_.Fn -eq $Fn }) }
    # Every path a sink spy was given, whatever the sink.
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
    # True when no path in the list equals another or lies below another (one section run).
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
    function script:Get-Rows([string]$Fn, [string]$Description) { @(Get-Calls $Fn | Where-Object { $_.Description -ceq $Description }) }

    # The scan as a spy with answers per root: $script:ScanAnswers[<root>] = @{ Files = ...; Complete = ... }.
    # A root without an answer gives no files and Complete $true. Every call is recorded.
    function script:Use-ScanSpy {
        $script:ScanCalls = [System.Collections.Generic.List[object]]::new()
        $script:ScanAnswers = @{}
        Mock Get-SwBoundedFileScan {
            $script:ScanCalls.Add([pscustomobject]@{ Root = $Root; Filter = $Filter; Extensions = @($Extensions); OlderThan = $OlderThan; NoRecurse = [bool]$NoRecurse; TimeoutSeconds = $TimeoutSeconds; HasTimeout = $PesterBoundParameters.ContainsKey('TimeoutSeconds'); HasOlderThan = $PesterBoundParameters.ContainsKey('OlderThan') })
            foreach ($key in @($script:ScanAnswers.Keys)) { if ((Fold $key) -eq (Fold $Root)) { return $script:ScanAnswers[$key] } }
            @{ Files = @(); Complete = $true }
        }
    }
    function script:Get-ScanRoots { @($script:ScanCalls | ForEach-Object { [string]$_.Root }) }

    # The owner paths as a net: no query finds a tool, no command starts, no process is created. Every call is recorded.
    function script:Use-OwnerNet {
        $script:OwnerQueries = [System.Collections.Generic.List[object]]::new()
        $script:OwnerCommands = [System.Collections.Generic.List[object]]::new()
        $script:OwnerCleanups = [System.Collections.Generic.List[object]]::new()
        Mock Get-SwOwnerCachePath { $script:OwnerQueries.Add([pscustomobject]@{ Name = $Name; Arguments = @($Arguments) }); $null }
        Mock Invoke-SwOwnerCommand {
            $script:OwnerCommands.Add([pscustomobject]@{ Name = $Name; Arguments = @($Arguments); Mutation = [bool]$Mutation; TimeoutSeconds = $TimeoutSeconds })
            $null
        }
        Mock New-SwOwnerProcess { throw 'a process must not be created in this test' }
        Mock Start-Process { throw 'Start-Process must not run in this test' }
    }

    # ---- one case: a fake profile below the test drive --------------------------------------------

    function script:Initialize-Case {
        param([switch]$RealProcess, [switch]$RealIdentity, [switch]$NoNet, [switch]$Real, [switch]$RealSections, [switch]$OwnerSpy)
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
        $script:EmptyBin = New-Dir (P $script:Work 'emptybin')
        $script:Data = P $script:Work 'appdata'
        Set-Env 'USERPROFILE' $script:Profile
        Set-Env 'HOME' $script:Profile
        Set-Env 'LOCALAPPDATA' $script:Local
        Set-Env 'APPDATA' $script:Roam
        Set-Env 'TEMP' $script:Scratch
        Set-Env 'PROGRAMDATA' $script:ProgramData
        Set-Env 'WINDIR' $script:WinDir
        Set-Env 'SYSTEMROOT' $script:WinDir
        Set-Env 'PATH' $script:EmptyBin
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
        $script:SweeprSkipExternalTools = $false
        Remove-Variable -Name ExportListFile -Scope Script -ErrorAction SilentlyContinue
        $script:SwWalkBudgetSeconds = 15
        $script:SwProbeBudgetSeconds = 2
        $script:CurrentSection = @{ Active = $false; Activity = $false; Name = 'Example section' }
        $script:SweeprOperationsLogFile = P $script:Work 'oplog' 'operations.log'
        $script:SweeprOperationsLogStarted = $false
        if (-not $RealIdentity) { Use-FakeIdentity }
        Use-Spies -RealSections:$RealSections
        if (-not $RealProcess) { Mock Get-Process { @() } }
        if (-not $NoNet) { Use-OwnerNet }
        if (-not $Real) { Use-HelperSpies; Use-AppCacheSpy }
        if ($OwnerSpy) { Use-OwnerCleanupSpy }
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
    # Every value a block gives to the pipeline (the block's own output apart from the writers).
    function script:Invoke-Captured([scriptblock]$Block) {
        $values = [System.Collections.Generic.List[object]]::new()
        foreach ($item in @(& $Block)) { $values.Add($item) }
        , @($values)
    }
    # Starts the dry-run collector and the not-measured collector and gives both.
    function script:Use-Collectors {
        $script:DryRunCollector = [System.Collections.Generic.List[object]]::new()
        $script:NotMeasuredCollector = [System.Collections.Generic.List[object]]::new()
    }

    # A child PowerShell for the tests that need a fresh session (loading, the real command search).
    function script:ConvertTo-TestLiteral([string]$Value) { "'" + $Value.Replace("'", "''") + "'" }
    function script:Invoke-ChildPowerShell {
        param([string]$Script, [string]$WorkingDirectory = $TestDrive, [hashtable]$Environment = @{}, [string[]]$RemoveEnvironment = @())
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Script))
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:HostExe
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
    function script:Get-ChildStderr([string]$Text) {
        if ([string]::IsNullOrEmpty($Text)) { return '' }
        $clean = [regex]::Replace($Text, '(?s)<Obj S="progress".*?</Obj>', '')
        $clean = [regex]::Replace($clean, '<Objs[^>]*>|</Objs>|#< CLIXML', '')
        $clean.Trim()
    }
    # The lines of a child that loads the core modules and then the file under test.
    function script:Get-LoadScript([string[]]$Files) {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('$ErrorActionPreference = ''Stop''')
        foreach ($name in 'base.ps1', 'log.ps1', 'file_ops.ps1') { $lines.Add('. ' + (ConvertTo-TestLiteral (P $script:CoreDir $name))) }
        foreach ($file in $Files) { $lines.Add('. ' + (ConvertTo-TestLiteral (P $script:CleanDir $file))) }
        $lines -join "`n"
    }

    # What the whole file changes in the process is put back after the last test. The core modules are
    # loaded here, so that a test never depends on what the file under test loads itself.
    $script:RootState = Save-State
    $script:RootEnv = Save-Env $script:EnvNames
    $script:RootDirectory = [System.Environment]::CurrentDirectory
    $script:RootLocation = (Get-Location).Path
    . ([System.IO.Path]::Combine($script:CoreDir, 'base.ps1'))
    . ([System.IO.Path]::Combine($script:CoreDir, 'log.ps1'))
    . ([System.IO.Path]::Combine($script:CoreDir, 'file_ops.ps1'))
    # Compile the Windows wrappers now: Windows PowerShell 5.1 writes the compiler files to TEMP, which the
    # cases point into their work folder.
    if ($script:OnWindows) { $null = Initialize-SwBaseNative; $null = Initialize-SwFileOpsNative }
    . ([System.IO.Path]::Combine($script:CoreDir, 'ui.ps1'))
    . ([System.IO.Path]::Combine($script:CleanDir, 'dev.ps1'))

    # ---- expected sink calls, as one text per call --------------------------------------------------

    function script:ED([string]$Path, [string]$Description) { 'D|' + (Fold $Path) + '|' + $Description }
    function script:EA([string]$Path, [string]$Description, [string]$Processes) { 'A|' + (Fold $Path) + '|' + $Description + '|' + $Processes }
    function script:ER([string[]]$Paths, [string]$Description) { 'R|' + ((@($Paths) | ForEach-Object { Fold $_ }) -join ';') + '|' + $Description }
    function script:EW([string]$Name, [string]$Query, [string]$Arguments, [string]$Description) { 'W|' + $Name + '|' + $Query + '|' + $Arguments + '|' + $Description }
    function script:Format-Calls {
        @($script:Calls | ForEach-Object {
                $call = $_
                switch ($call.Fn) {
                    'Clear-SwDirectoryContents' { 'D|' + (Fold $call.Path) + '|' + $call.Description }
                    'Clear-SwAppCache' { 'A|' + (Fold $call.Path) + '|' + $call.Description + '|' + (@($call.Processes) -join ',') }
                    'Remove-SwItems' { 'R|' + ((@($call.Paths) | ForEach-Object { Fold $_ }) -join ';') + '|' + $call.Description }
                    'Remove-SwOldFiles' { 'O|' + (Fold $call.Path) + '|' + $call.DaysOld + '|' + $call.Filter + '|' + $call.Description }
                    'Invoke-SwOwnerCacheCleanup' { 'W|' + $call.Name + '|' + (@($call.Query) -join ' ') + '|' + (@($call.Arguments) -join ' ') + '|' + $call.Description }
                    default { $call.Fn + '|' + $call.Path }
                }
            })
    }
    function script:Show([string[]]$Lines) { (@($Lines) -join "`n") }

    # The profile folders the placeholder rows find, and the answers of the file search.
    function script:Initialize-GroupFixture([string]$Group) {
        switch ($Group) {
            'Clear-SwPythonCaches' {
                Use-ScanSpy
                $script:ScanAnswers[(P $script:Profile '.conda' 'pkgs')] = @{ Files = @((P $script:Profile '.conda' 'pkgs' 'a.tmp')); Complete = $true }
                $script:ScanAnswers[(P $script:Profile 'miniconda3' 'pkgs')] = @{ Files = @((P $script:Profile 'miniconda3' 'pkgs' 'm.tmp')); Complete = $true }
            }
            'Clear-SwHaskellCaches' {
                Use-ScanSpy
                $script:ScanAnswers[(P $script:Profile '.stack' 'snapshots')] = @{ Files = @((P $script:Profile '.stack' 'snapshots' 'pkg' 'download.tmp')); Complete = $true }
            }
            'Clear-SwDotNetCaches' {
                foreach ($name in 'Logs', 'temp', 'TempFiles', 'Packages') { $null = New-Dir (P $script:Local 'Microsoft' 'MSBuild' $name) }
            }
            'Clear-SwOCamlCaches' {
                foreach ($name in 'default', 'cache-1', 'MyCache') { $null = New-Dir (P $script:Profile '.opam' 'repo' $name) }
            }
            'Clear-SwIdeCaches' {
                foreach ($name in '16.0_def', '17.0_abc') { $null = New-Dir (P $script:Local 'Microsoft' 'VisualStudio' $name) }
            }
        }
    }
    function script:Get-ExpectedRows([string]$Group) {
        switch ($Group) {
            'Clear-SwNpmFamilyCaches' {
                @(
                    (EW 'npm' 'config get cache' 'cache clean --force' 'npm cache')
                    (EW 'pnpm' 'store path' 'store prune' 'pnpm store')
                    (ED (P $script:Local 'Yarn' 'Cache') 'Yarn cache')
                    (ED (P $script:Profile '.bun' 'install' 'cache') 'Bun cache')
                )
            }
            'Clear-SwNodeBuildCaches' {
                @(
                    (ED (P $script:Local 'node-gyp' 'Cache') 'node-gyp cache')
                    (ED (P $script:Local 'electron' 'Cache') 'Electron cache')
                    (ED (P $script:Local 'TypeScript') 'TypeScript cache')
                )
            }
            'Clear-SwPythonCaches' {
                @(
                    (EW 'pip' 'cache dir' 'cache purge' 'pip cache')
                    (ED (P $script:Profile '.pyenv' 'cache') 'pyenv cache')
                    (EA (P $script:Local 'pypoetry' 'Cache' 'artifacts') 'Poetry cache' 'python,pythonw,poetry')
                    (EA (P $script:Local 'pypoetry' 'Cache' 'cache') 'Poetry cache' 'python,pythonw,poetry')
                    (ER @((P $script:Profile '.conda' 'pkgs' 'a.tmp'), (P $script:Profile 'miniconda3' 'pkgs' 'm.tmp')) 'Conda temp files')
                )
            }
            'Clear-SwDotNetCaches' {
                @(
                    (ED (P $script:Local 'NuGet' 'v3-cache') 'NuGet HTTP cache')
                    (ED (P $script:Local 'NuGet' 'plugins-cache') 'NuGet plugins cache')
                    (ED (P $script:Local 'Microsoft' 'MSBuild' 'temp') 'MSBuild temp')
                    (ED (P $script:Local 'Microsoft' 'MSBuild' 'TempFiles') 'MSBuild temp')
                )
            }
            'Clear-SwGoCaches' { @((EW 'go' 'env GOCACHE' 'clean -cache' 'Go build cache')) }
            'Clear-SwMiseCache' { @((EW 'mise' 'cache path' 'cache clear' 'mise cache')) }
            'Clear-SwElixirCaches' { @((ED (P $script:Profile '.hex' 'cache') 'Hex cache')) }
            'Clear-SwHaskellCaches' { @((ER @((P $script:Profile '.stack' 'snapshots' 'pkg' 'download.tmp')) 'Stack temp files')) }
            'Clear-SwOCamlCaches' {
                @(
                    (ED (P $script:Profile '.opam' 'download-cache') 'Opam download cache')
                    (ED (P $script:Profile '.opam' 'repo' 'cache-1') 'Opam repo cache')
                    (ED (P $script:Profile '.opam' 'repo' 'MyCache') 'Opam repo cache')
                )
            }
            'Clear-SwCloudCliCaches' {
                @(
                    (ED (P $script:Roam 'gcloud' 'logs') 'gcloud logs')
                    (ED (P $script:Roam 'terraform.d' 'plugin-cache') 'Terraform plugin cache')
                )
            }
            'Clear-SwEditorCaches' {
                $rows = [System.Collections.Generic.List[string]]::new()
                foreach ($leaf in 'Cache', 'CachedData', 'CachedExtensions', 'CachedExtensionVSIXs', 'Code Cache', 'GPUCache') {
                    $rows.Add((EA (P $script:Roam 'Code' $leaf) 'VS Code cache' 'Code'))
                }
                $rows.Add((EA (P $script:Local 'Microsoft' 'vscode-cpptools') 'VS Code cache' 'Code,cpptools,cpptools-srv'))
                foreach ($leaf in 'Cache', 'CachedData', 'CachedExtensions', 'CachedExtensionVSIXs', 'Code Cache', 'GPUCache') {
                    $rows.Add((EA (P $script:Roam 'Code - Insiders' $leaf) 'VS Code Insiders cache' 'Code - Insiders'))
                }
                $rows.Add((EA (P $script:Local 'Zed' 'cache') 'Zed cache' 'zed'))
                $rows.Add((EA (P $script:Roam 'Zed' 'cache') 'Zed cache' 'zed'))
                $rows.Add((EA (P $script:Local 'Sublime Text' 'Cache') 'Sublime Text cache' 'sublime_text,plugin_host'))
                $rows.Add((EA (P $script:Roam 'Sublime Text' 'Cache') 'Sublime Text cache' 'sublime_text,plugin_host'))
                $rows.ToArray()
            }
            'Clear-SwIdeCaches' {
                @(
                    (EA (P $script:Local 'Microsoft' 'VisualStudio' '16.0_def' 'ComponentModelCache') 'Visual Studio cache' 'devenv')
                    (EA (P $script:Local 'Microsoft' 'VisualStudio' '16.0_def' 'ImageCache') 'Visual Studio cache' 'devenv')
                    (EA (P $script:Local 'Microsoft' 'VisualStudio' '17.0_abc' 'ComponentModelCache') 'Visual Studio cache' 'devenv')
                    (EA (P $script:Local 'Microsoft' 'VisualStudio' '17.0_abc' 'ImageCache') 'Visual Studio cache' 'devenv')
                )
            }
        }
    }
    # The twelve groups in the order of the section.
    $script:GroupOrder = @('Clear-SwNpmFamilyCaches', 'Clear-SwNodeBuildCaches', 'Clear-SwPythonCaches', 'Clear-SwDotNetCaches', 'Clear-SwGoCaches',
        'Clear-SwMiseCache', 'Clear-SwElixirCaches', 'Clear-SwHaskellCaches', 'Clear-SwOCamlCaches', 'Clear-SwCloudCliCaches', 'Clear-SwEditorCaches', 'Clear-SwIdeCaches')
    function script:Use-GroupSpies {
        foreach ($name in $script:GroupOrder) {
            Mock $name ([scriptblock]::Create('$script:Sections.Add(' + [char]39 + 'group:' + $name + [char]39 + ')'))
        }
    }
    function script:Use-ThrowingGroup([string]$Group) {
        foreach ($name in $script:GroupOrder) {
            if ($name -eq $Group) { Mock $name ([scriptblock]::Create('$script:Sections.Add(' + [char]39 + 'group:' + $name + [char]39 + '); throw ' + [char]39 + 'boom of ' + $name + [char]39)) }
            else { Mock $name ([scriptblock]::Create('$script:Sections.Add(' + [char]39 + 'group:' + $name + [char]39 + ')')) }
        }
    }
}

AfterAll {
    Clear-TestLinks
    Restore-Env $script:RootEnv
    Restore-State $script:RootState
    [System.Environment]::CurrentDirectory = $script:RootDirectory
    try { Set-Location -LiteralPath $script:RootLocation } catch { $null = $_ }
}
Describe 'CD-9 the section of Invoke-SwDevCleanup' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
    }
    AfterEach { Stop-Case }

    It 'CD-9 defines the section function and the twelve group functions' {
        Assert-Defined (@('Invoke-SwDevCleanup') + $script:GroupOrder)
    }

    It 'CD-9 opens "Developer tools" once, runs the twelve groups in the order of the table and closes the section once' {
        Use-GroupSpies
        Invoke-SwDevCleanup
        $expected = @('start:Developer tools') + @($script:GroupOrder | ForEach-Object { 'group:' + $_ }) + @('stop')
        (Show $script:Sections) | Should -Be (Show $expected)
    }

    It 'CD-9 CD-4 runs the other eleven groups and closes the section once when <Group> throws' -ForEach $script:Groups {
        Use-ThrowingGroup $Group
        { Invoke-SwDevCleanup } | Should -Not -Throw
        $expected = @('start:Developer tools') + @($script:GroupOrder | ForEach-Object { 'group:' + $_ }) + @('stop')
        (Show $script:Sections) | Should -Be (Show $expected)
        (@(Get-LogLines 'DEBUG') -join "`n") | Should -Match ([regex]::Escape('boom of ' + $Group))
    }

    It 'CD-4 S-14 throws nothing and writes nothing to the pipeline with the real groups, also when every sink writes a value' {
        $script:SinkLeak = $true
        $out = Invoke-Captured { Invoke-SwDevCleanup }
        $out.Count | Should -Be 0
        @(Invoke-SwDevCleanup).Count | Should -Be 0
        (@($script:Sections | Where-Object { $_ -eq 'stop' })).Count | Should -Be 2
    }

    It 'CD-9 gives the section a fixed title that sw check can use (Developer tools)' {
        Use-GroupSpies
        Use-Collectors
        $script:CurrentSection = @{ Active = $false; Activity = $false; Name = 'Example section' }
        Invoke-SwDevCleanup
        @($script:Sections | Where-Object { $_ -like 'start:*' }) | Should -Be @('start:Developer tools')
    }
}

Describe 'CD-9 the section with the real section functions of the log module' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -RealSections
    }
    AfterEach { Stop-Case }

    It 'CD-9 closes with the "Nothing to tidy" line of the log module, written by Stop-SwSection, when no group did anything' {
        Invoke-SwDevCleanup
        @(Get-LogLines 'SUCCESS' | Where-Object { $_ -like '*Nothing to tidy*' }).Count | Should -Be 1
        @(Get-LogLines 'SUCCESS').Count | Should -Be 1 -Because 'the developer tool files write no success line of their own'
    }
}

Describe 'CD-23 CD-24 CD-26 CD-27 CD-29 the rows of every group' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -OwnerSpy
    }
    AfterEach { Stop-Case }

    It 'CD-23 <Group> offers exactly the rows of its table, in order, with the sink, path and description of the table' -ForEach $script:Groups {
        Initialize-GroupFixture $Group
        & $Group
        (Show (Format-Calls)) | Should -Be (Show (Get-ExpectedRows $Group))
    }

    It 'CD-23 <Group> offers the same rows in a real run and in a preview (the group does not decide the mode)' -ForEach $script:Groups {
        Initialize-GroupFixture $Group
        $script:SweeprDryRunMode = $true
        & $Group
        $preview = Show (Format-Calls)
        $script:Calls.Clear()
        $script:SweeprDryRunMode = $false
        & $Group
        (Show (Format-Calls)) | Should -Be $preview
    }

    It 'CD-23 <Group> writes nothing to the pipeline, also when every sink writes a value, and throws nothing' -ForEach $script:Groups {
        Initialize-GroupFixture $Group
        $script:SinkLeak = $true
        { & $Group } | Should -Not -Throw
        (Invoke-Captured { & $Group }).Count | Should -Be 0
    }

    It 'CD-23 calls no sink for a folder that is missing: the sink decides, no Test-Path before it' {
        Mock Test-Path { throw 'Test-Path must not run for a row' }
        & Clear-SwNodeBuildCaches
        @(Get-Calls 'Clear-SwDirectoryContents').Count | Should -Be 3
        [System.IO.Directory]::Exists((P $script:Local 'node-gyp' 'Cache')) | Should -BeFalse
    }

    It 'CD-23 CD-4 a sink that throws for the first row does not stop the next rows of the group' {
        $script:ThrowPath = P $script:Local 'node-gyp' 'Cache'
        Mock Clear-SwDirectoryContents {
            Add-Call 'Clear-SwDirectoryContents' @{ Path = $Path; Description = $Description }
            if ((Fold $Path) -eq (Fold $script:ThrowPath)) { throw 'boom of the first row' }
        }
        { Clear-SwNodeBuildCaches } | Should -Not -Throw
        (Show (Format-Calls)) | Should -Be (Show (Get-ExpectedRows 'Clear-SwNodeBuildCaches'))
        ((Get-LogLines 'DEBUG') -join "`n") | Should -Match 'boom of the first row'
    }

    It 'CD-4 an owner cleanup that throws for npm does not stop pnpm, Yarn and Bun' {
        Mock Invoke-SwOwnerCacheCleanup {
            Add-Call 'Invoke-SwOwnerCacheCleanup' @{ Name = $Name; Query = @($Query); Arguments = @($Arguments); Description = $Description }
            if ($Name -eq 'npm') { throw 'boom of npm' }
        }
        { Clear-SwNpmFamilyCaches } | Should -Not -Throw
        (Show (Format-Calls)) | Should -Be (Show (Get-ExpectedRows 'Clear-SwNpmFamilyCaches'))
    }

    It 'CD-4 a row sink with an owner that throws for the first Poetry row does not stop the second one and conda' {
        Initialize-GroupFixture 'Clear-SwPythonCaches'
        Mock Clear-SwAppCache {
            Add-Call 'Clear-SwAppCache' @{ Path = $Path; Description = $Description; Processes = @($Processes) }
            if ($Path -like '*artifacts') { throw 'boom of artifacts' }
        }
        { Clear-SwPythonCaches } | Should -Not -Throw
        (Show (Format-Calls)) | Should -Be (Show (Get-ExpectedRows 'Clear-SwPythonCaches'))
    }

    It 'CD-24 chooses only Poetry artifacts and cache, never the folder Cache itself or virtualenvs' {
        Initialize-GroupFixture 'Clear-SwPythonCaches'
        Clear-SwPythonCaches
        $poetry = @(Get-CallPaths | Where-Object { (Fold $_) -like '*pypoetry*' })
        $poetry.Count | Should -Be 2
        foreach ($path in $poetry) { [System.IO.Path]::GetFileName($path) | Should -BeIn @('artifacts', 'cache') }
        Test-AnyUnder (Get-CallPaths) (P $script:Local 'pypoetry' 'Cache' 'virtualenvs') | Should -BeFalse
        (@(Get-CallPaths | Where-Object { (Fold $_) -eq (Fold (P $script:Local 'pypoetry' 'Cache')) })).Count | Should -Be 0
    }

    It 'CD-24 gives both Poetry rows the three process names python, pythonw and poetry' {
        Initialize-GroupFixture 'Clear-SwPythonCaches'
        Clear-SwPythonCaches
        $rows = @(Get-Calls 'Clear-SwAppCache')
        $rows.Count | Should -Be 2
        foreach ($row in $rows) { (@($row.Processes) -join ',') | Should -Be 'python,pythonw,poetry' }
    }

    It 'CD-25 gives every editor path to Clear-SwAppCache with the process names of its row: Code does not stand for Code - Insiders' {
        Clear-SwEditorCaches
        $rows = @(Get-Calls 'Clear-SwAppCache')
        $rows.Count | Should -Be 17
        @($rows | Where-Object { $_.Path -like '*Insiders*' } | ForEach-Object { @($_.Processes) -join ',' } | Select-Object -Unique) | Should -Be @('Code - Insiders')
        @($rows | Where-Object { $_.Description -eq 'Zed cache' } | ForEach-Object { @($_.Processes) -join ',' } | Select-Object -Unique) | Should -Be @('zed')
        @($rows | Where-Object { (Fold $_.Path) -like '*vscode-cpptools' } | ForEach-Object { @($_.Processes) -join ',' }) | Should -Be @('Code,cpptools,cpptools-srv')
        @(Get-Calls 'Clear-SwDirectoryContents').Count | Should -Be 0 -Because 'an editor cache never skips the owner guard'
    }

    It 'CD-25 CD-30 offers no VS Code folder for user data: User, workspaceStorage, Backups, logs, Local Storage, Session Storage, Service Worker' {
        Clear-SwEditorCaches
        foreach ($leaf in 'User', 'workspaceStorage', 'Backups', 'logs', 'Local Storage', 'Session Storage', 'Service Worker') {
            Test-AnyUnder (Get-CallPaths) (P $script:Roam 'Code' $leaf) | Should -BeFalse -Because $leaf
            Test-AnyUnder (Get-CallPaths) (P $script:Roam 'Code - Insiders' $leaf) | Should -BeFalse -Because $leaf
        }
        Test-AnyUnder (Get-CallPaths) (P $script:Profile '.vscode' 'extensions') | Should -BeFalse
        Test-AnyUnder (Get-CallPaths) (P $script:Roam 'Sublime Text' 'Packages') | Should -BeFalse
        Test-AnyUnder (Get-CallPaths) (P $script:Roam 'Sublime Text' 'Local') | Should -BeFalse
    }

    It 'CD-26 scans the Stack snapshots once, recursive, with the filter *.tmp and the standard budget' {
        Initialize-GroupFixture 'Clear-SwHaskellCaches'
        Clear-SwHaskellCaches
        $script:ScanCalls.Count | Should -Be 1
        $call = $script:ScanCalls[0]
        (Fold $call.Root) | Should -Be (Fold (P $script:Profile '.stack' 'snapshots'))
        $call.Filter | Should -Be '*.tmp'
        $call.NoRecurse | Should -BeFalse
        $call.HasTimeout | Should -BeFalse -Because 'the standard budget applies'
    }

    It 'CD-26 hands the files of a real search to one Remove-SwItems: download.tmp goes, download.tar.gz stays' {
        $root = P $script:Profile '.stack' 'snapshots'
        $tmp = New-File (P $root 'pkg' 'download.tmp') 5
        $null = New-File (P $root 'pkg' 'download.tar.gz') 5
        Clear-SwHaskellCaches
        $rows = @(Get-Calls 'Remove-SwItems')
        $rows.Count | Should -Be 1
        @($rows[0].Paths | ForEach-Object { Fold $_ }) | Should -Be @((Fold $tmp))
        $rows[0].Description | Should -Be 'Stack temp files'
    }

    It 'CD-26 CD-31 removes nothing, remembers nothing and notes "incomplete scan" when the search is incomplete' {
        Use-ScanSpy
        $script:ScanAnswers[(P $script:Profile '.stack' 'snapshots')] = @{ Files = @(); Complete = $false }
        Clear-SwHaskellCaches
        @(Get-Calls 'Remove-SwItems').Count | Should -Be 0
        $script:Calls.Count | Should -Be 0
        $script:Ops.Count | Should -Be 0
        $note = @(Get-NotMeasuredFor 'Stack temp files')
        $note.Count | Should -Be 1
        $note[0].Reason | Should -Be 'incomplete scan'
        @(Get-LogLines 'DEBUG').Count | Should -BeGreaterThan 0
    }

    It 'CD-26 calls Remove-SwItems not at all when the search is complete and finds no file, and notes nothing' {
        Use-ScanSpy
        Clear-SwHaskellCaches
        $script:Calls.Count | Should -Be 0
        $script:NotMeasured.Count | Should -Be 0
    }

    It 'CD-26 CD-30 never scans or offers .stack\programs or the Cabal store' {
        Use-ScanSpy
        Clear-SwHaskellCaches
        foreach ($root in (Get-ScanRoots)) {
            Test-SameOrUnder $root (P $script:Profile '.stack' 'programs') | Should -BeFalse
            Test-SameOrUnder $root (P $script:Profile '.cabal') | Should -BeFalse
        }
        Test-AnyUnder (Get-CallPaths) (P $script:Profile '.cabal') | Should -BeFalse
    }

    It 'CD-23 D10 scans each of the three conda bases once, direct files only, filter *.tmp' {
        Initialize-GroupFixture 'Clear-SwPythonCaches'
        Clear-SwPythonCaches
        $script:ScanCalls.Count | Should -Be 3
        @($script:ScanCalls | ForEach-Object { Fold $_.Root }) | Should -Be @(
            (Fold (P $script:Profile '.conda' 'pkgs')), (Fold (P $script:Profile 'anaconda3' 'pkgs')), (Fold (P $script:Profile 'miniconda3' 'pkgs')))
        foreach ($call in $script:ScanCalls) {
            $call.Filter | Should -Be '*.tmp'
            $call.NoRecurse | Should -BeTrue
        }
    }

    It 'CD-23 D10 hands over only files: a folder named c.tmp is not chosen, files of two bases go in one list' {
        $null = New-File (P $script:Profile '.conda' 'pkgs' 'a.tmp') 4
        $null = New-File (P $script:Profile 'anaconda3' 'pkgs' 'b.tmp') 4
        $null = New-File (P $script:Profile 'miniconda3' 'pkgs' 'c.tmp' 'inner.bin') 4
        Clear-SwPythonCaches
        $rows = @(Get-Rows 'Remove-SwItems' 'Conda temp files')
        $rows.Count | Should -Be 1
        @($rows[0].Paths | ForEach-Object { Fold $_ }) | Should -Be @((Fold (P $script:Profile '.conda' 'pkgs' 'a.tmp')), (Fold (P $script:Profile 'anaconda3' 'pkgs' 'b.tmp')))
    }

    It 'CD-23 CD-31 D10 offers nothing of an incomplete base, notes "incomplete scan" and still offers the files of the other bases' {
        Use-ScanSpy
        $script:ScanAnswers[(P $script:Profile '.conda' 'pkgs')] = @{ Files = @(); Complete = $false }
        $script:ScanAnswers[(P $script:Profile 'anaconda3' 'pkgs')] = @{ Files = @((P $script:Profile 'anaconda3' 'pkgs' 'b.tmp')); Complete = $true }
        Clear-SwPythonCaches
        $rows = @(Get-Rows 'Remove-SwItems' 'Conda temp files')
        $rows.Count | Should -Be 1
        @($rows[0].Paths | ForEach-Object { Fold $_ }) | Should -Be @((Fold (P $script:Profile 'anaconda3' 'pkgs' 'b.tmp')))
        $note = @(Get-NotMeasuredFor 'Conda temp files')
        $note.Count | Should -Be 1
        $note[0].Reason | Should -Be 'incomplete scan'
    }

    It 'CD-27 takes the placeholder folders of D14 from Get-SwCacheProfiles with the MSBuild root and chooses only names with temp in them' {
        Initialize-GroupFixture 'Clear-SwDotNetCaches'
        Mock Get-SwCacheProfiles {
            $script:ProfileRoots.Add($Root)
            foreach ($name in 'Logs', 'TempFiles', 'temp') { [System.IO.DirectoryInfo]::new((P $Root $name)) }
        }
        $script:ProfileRoots = [System.Collections.Generic.List[string]]::new()
        Clear-SwDotNetCaches
        $script:ProfileRoots.Count | Should -Be 1
        (Fold $script:ProfileRoots[0]) | Should -Be (Fold (P $script:Local 'Microsoft' 'MSBuild'))
        $msbuild = @(Get-Rows 'Clear-SwDirectoryContents' 'MSBuild temp' | ForEach-Object { Fold $_.Path })
        $msbuild | Should -Be @((Fold (P $script:Local 'Microsoft' 'MSBuild' 'TempFiles')), (Fold (P $script:Local 'Microsoft' 'MSBuild' 'temp')))
    }

    It 'CD-27 CD-3 offers no placeholder row when Get-SwCacheProfiles gives nothing, and the fixed rows stay' {
        Mock Get-SwCacheProfiles { }
        Clear-SwDotNetCaches
        @(Get-Calls 'Clear-SwDirectoryContents' | ForEach-Object { $_.Description }) | Should -Be @('NuGet HTTP cache', 'NuGet plugins cache')
        Clear-SwIdeCaches
        @(Get-Calls 'Clear-SwAppCache').Count | Should -Be 0
        Clear-SwOCamlCaches
        @(Get-Rows 'Clear-SwDirectoryContents' 'Opam repo cache').Count | Should -Be 0
    }

    It 'CD-27 works with a single profile folder (the pipeline result is wrapped in @())' {
        Mock Get-SwCacheProfiles { [System.IO.DirectoryInfo]::new((P $Root '17.0_only')) }
        Clear-SwIdeCaches
        @(Get-Calls 'Clear-SwAppCache' | ForEach-Object { Fold $_.Path }) | Should -Be @(
            (Fold (P $script:Local 'Microsoft' 'VisualStudio' '17.0_only' 'ComponentModelCache')), (Fold (P $script:Local 'Microsoft' 'VisualStudio' '17.0_only' 'ImageCache')))
    }

    It 'CD-27 appends the rest literally: a profile folder with brackets in its name keeps them' {
        Mock Get-SwCacheProfiles { [System.IO.DirectoryInfo]::new((P $Root '17.0 [x]')) }
        Clear-SwIdeCaches
        @(Get-Calls 'Clear-SwAppCache' | ForEach-Object { $_.Path }).Count | Should -Be 2
        foreach ($call in @(Get-Calls 'Clear-SwAppCache')) { $call.Path | Should -BeLike '*17.0 `[x`]*' }
    }

    It 'CD-27 does not choose a folder that is named like a cache leaf (Cache, Code Cache, GPUCache) as a Visual Studio profile' {
        foreach ($name in 'Cache', 'Code Cache', 'GPUCache', '17.0_abc') { $null = New-Dir (P $script:Local 'Microsoft' 'VisualStudio' $name) }
        Clear-SwIdeCaches
        @(Get-Calls 'Clear-SwAppCache' | ForEach-Object { Fold $_.Path }) | Should -Be @(
            (Fold (P $script:Local 'Microsoft' 'VisualStudio' '17.0_abc' 'ComponentModelCache')), (Fold (P $script:Local 'Microsoft' 'VisualStudio' '17.0_abc' 'ImageCache')))
    }

    It 'CD-27 passes every profile of a real listing through: no more than the folders that exist, sorted as the listing gives them' {
        Initialize-GroupFixture 'Clear-SwOCamlCaches'
        Clear-SwOCamlCaches
        @(Get-Rows 'Clear-SwDirectoryContents' 'Opam repo cache').Count | Should -Be 2
    }

    It 'CD-29 chooses for the cloud tools only gcloud\logs and terraform.d\plugin-cache, as folder contents, and never .aws .azure .kube .docker or GitHub CLI' {
        Clear-SwCloudCliCaches
        @(Get-Calls 'Clear-SwDirectoryContents').Count | Should -Be 2
        @(Get-Calls 'Clear-SwAppCache').Count | Should -Be 0
        foreach ($forbidden in (P $script:Profile '.aws'), (P $script:Profile '.azure'), (P $script:Profile '.kube'), (P $script:Profile '.docker'), (P $script:Roam 'GitHub CLI'), (P $script:Roam 'gcloud'), (P $script:Roam 'terraform.d')) {
            @(Get-CallPaths | Where-Object { (Fold $_) -eq (Fold $forbidden) }).Count | Should -Be 0 -Because $forbidden
        }
        foreach ($forbidden in (P $script:Profile '.aws'), (P $script:Profile '.azure'), (P $script:Profile '.kube'), (P $script:Profile '.docker'), (P $script:Roam 'GitHub CLI')) {
            Test-AnyUnder (Get-CallPaths) $forbidden | Should -BeFalse -Because $forbidden
        }
    }

    It 'CD-21 gives docker, yarn and bun no owner cleanup: the groups ask only npm, pnpm, pip, go and mise' {
        foreach ($group in $script:GroupOrder) { & $group }
        $names = @(Get-Calls 'Invoke-SwOwnerCacheCleanup' | ForEach-Object { $_.Name } | Sort-Object)
        $names | Should -Be @('go', 'mise', 'npm', 'pip', 'pnpm')
    }

    It 'CD-30a gives no row but the editors, the Poetry rows and Visual Studio a process check, and no owner command a process check' {
        Initialize-GroupFixture 'Clear-SwIdeCaches'
        foreach ($group in $script:GroupOrder) { & $group }
        $guarded = @(Get-Calls 'Clear-SwAppCache' | ForEach-Object { $_.Description } | Select-Object -Unique | Sort-Object)
        $guarded | Should -Be @(@('Poetry cache', 'Sublime Text cache', 'VS Code Insiders cache', 'VS Code cache', 'Visual Studio cache', 'Zed cache') | Sort-Object)
        foreach ($call in @(Get-Calls 'Clear-SwDirectoryContents')) { $call.CanRemove | Should -BeNullOrEmpty -Because $call.Description }
    }
}

Describe 'CD-3 target paths of the developer tool rows' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -OwnerSpy
    }
    AfterEach { Stop-Case }

    It 'CD-3 calls no sink for the group when LOCALAPPDATA is <Label>' -ForEach $script:BadValues {
        Set-Env 'LOCALAPPDATA' $Value
        { Clear-SwNodeBuildCaches } | Should -Not -Throw
        $script:Calls.Count | Should -Be 0
        (Invoke-Captured { Clear-SwNodeBuildCaches }).Count | Should -Be 0
    }

    It 'CD-3 calls no sink for the group when <Variable> is the root of the drive' -ForEach $script:RootCases {
        Set-Env $Variable ([System.IO.Path]::GetPathRoot($script:Work))
        & $Group
        $script:Calls.Count | Should -Be 0
    }

    It 'CD-3 calls no sink when <Variable> is a folder that resolves to the root of the drive' -ForEach $script:RootCases {
        $root = [System.IO.Path]::GetPathRoot($script:Work)
        Set-Env $Variable ((P $root 'x') + $script:Sep + '..')
        & $Group
        $script:Calls.Count | Should -Be 0
    }

    It 'CD-3 leaves out only the targets of the unusable variable: no USERPROFILE keeps the Poetry rows, no LOCALAPPDATA keeps pyenv' {
        Initialize-GroupFixture 'Clear-SwPythonCaches'
        Set-Env 'USERPROFILE' $null
        Clear-SwPythonCaches
        @(Get-Calls 'Clear-SwAppCache').Count | Should -Be 2
        @(Get-Rows 'Clear-SwDirectoryContents' 'pyenv cache').Count | Should -Be 0
        @(Get-Calls 'Remove-SwItems').Count | Should -Be 0
        $script:ScanCalls.Count | Should -Be 0 -Because 'the conda bases come from USERPROFILE'
        @(Get-Calls 'Invoke-SwOwnerCacheCleanup').Count | Should -Be 1 -Because 'pip needs no variable'
        $script:Calls.Clear()
        Set-Env 'USERPROFILE' $script:Profile
        Set-Env 'LOCALAPPDATA' $null
        Clear-SwPythonCaches
        @(Get-Calls 'Clear-SwAppCache').Count | Should -Be 0
        @(Get-Rows 'Clear-SwDirectoryContents' 'pyenv cache').Count | Should -Be 1
    }

    It 'CD-3 drops the Roaming targets of the editors when APPDATA is not complete and keeps the Local ones' {
        Set-Env 'APPDATA' 'Roaming'
        Clear-SwEditorCaches
        $paths = @(Get-CallPaths)
        $paths.Count | Should -Be 3
        foreach ($path in $paths) { Test-SameOrUnder $path $script:Local | Should -BeTrue -Because $path }
    }

    It 'CD-3 trims the value of the variable' {
        Set-Env 'LOCALAPPDATA' ('  ' + $script:Local + '  ')
        Clear-SwNodeBuildCaches
        (Show (Format-Calls)) | Should -Be (Show (Get-ExpectedRows 'Clear-SwNodeBuildCaches'))
    }

    It 'CD-3 joins with exactly one separator: a trailing separator of the base goes' {
        Set-Env 'LOCALAPPDATA' ($script:Local + $script:Sep)
        Clear-SwNodeBuildCaches
        $first = @(Get-Calls 'Clear-SwDirectoryContents')[0].Path
        $first | Should -BeExactly ($script:Local + $script:Sep + 'node-gyp' + $script:Sep + 'Cache')
        foreach ($call in @(Get-Calls 'Clear-SwDirectoryContents')) { $call.Path | Should -Not -Match '[\\/]{2}' }
    }

    It 'CD-3 reads the value literally: a base with brackets goes to the sink with its brackets, a neighbor folder without them is not used' {
        $bracket = New-Dir (P $script:Work 'Ex [1]' 'Local')
        $null = New-Dir (P $script:Work 'Ex 1' 'Local')
        Set-Env 'LOCALAPPDATA' $bracket
        Clear-SwNodeBuildCaches
        $paths = @(Get-CallPaths)
        $paths.Count | Should -Be 3
        foreach ($path in $paths) {
            Test-SameOrUnder $path $bracket | Should -BeTrue -Because $path
            Test-SameOrUnder $path (P $script:Work 'Ex 1') | Should -BeFalse -Because $path
        }
    }

    It 'CD-3 CD-27 builds the profile root of a placeholder row from the base and asks Get-SwCacheProfiles with it' {
        $bracket = New-Dir (P $script:Work 'Ex [1]' 'Local')
        Set-Env 'LOCALAPPDATA' $bracket
        $script:ProfileRoots = [System.Collections.Generic.List[string]]::new()
        Mock Get-SwCacheProfiles { $script:ProfileRoots.Add($Root) }
        Clear-SwIdeCaches
        @($script:ProfileRoots | ForEach-Object { Fold $_ }) | Should -Be @((Fold (P $bracket 'Microsoft' 'VisualStudio')))
    }

    It 'CD-3 gives an error nowhere when a variable is missing under strict mode, for every group' {
        foreach ($name in 'USERPROFILE', 'LOCALAPPDATA', 'APPDATA', 'PROGRAMDATA') { Set-Env $name $null }
        foreach ($group in $script:GroupOrder) {
            { & $group } | Should -Not -Throw -Because $group
            (Invoke-Captured { & $group }).Count | Should -Be 0 -Because $group
        }
    }

    It 'CD-3 CD-6 chooses the same rows whether SWEEPR_DRY_RUN is set or not: the group does not read the mode' {
        Set-Env 'SWEEPR_DRY_RUN' '1'
        Clear-SwNodeBuildCaches
        $withVariable = Show (Format-Calls)
        $script:Calls.Clear()
        Set-Env 'SWEEPR_DRY_RUN' $null
        Clear-SwNodeBuildCaches
        (Show (Format-Calls)) | Should -Be $withVariable
    }
}

Describe 'CD-2 error preference and strict mode do not change the rows' {
    BeforeEach {
        Set-StrictMode -Version Latest
        Initialize-Case -OwnerSpy
    }
    AfterEach { Stop-Case; $ErrorActionPreference = 'Stop' }

    It 'CD-2 gives the same rows of <Group> under Stop, Continue and SilentlyContinue' -ForEach $script:Groups {
        Initialize-GroupFixture $Group
        $seen = @{}
        foreach ($preference in 'Stop', 'Continue', 'SilentlyContinue') {
            $ErrorActionPreference = $preference
            $script:Calls.Clear()
            & $Group
            $seen[$preference] = Show (Format-Calls)
        }
        $seen['Continue'] | Should -Be $seen['Stop']
        $seen['SilentlyContinue'] | Should -Be $seen['Stop']
    }

    It 'CD-2 CD-9 runs the whole section under Continue and under SilentlyContinue without a throw and without output' {
        foreach ($preference in 'Continue', 'SilentlyContinue') {
            $ErrorActionPreference = $preference
            { Invoke-SwDevCleanup } | Should -Not -Throw
            (Invoke-Captured { Invoke-SwDevCleanup }).Count | Should -Be 0
        }
    }
}
