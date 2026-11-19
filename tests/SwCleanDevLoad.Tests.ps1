# Sweepr - tests for loading lib\clean\dev.ps1: dot-sourcing, the markers and the script variable
# $script:SweeprSkipExternalTools, dependencies from the folder of the file, no side effects, no variables in
# the scope of the caller, and the old names (forwarding functions) of the developer tool functions.
#
# The rule numbers in the test names (CD-, CA-, S- and so on) number the rules and the safety invariants
# of the behavior of the developer tool and application cleanup; each rule and invariant has at least one test.
# The other files of this slice are SwCleanDevGroups, SwCleanDevScan, SwCleanDevOwnerPath, SwCleanDevOwnerRun,
# SwCleanDevProcess, SwCleanDevEditors, SwCleanAppsGroups, SwCleanAppsMedia and SwCleanDevAppsSafety.
#
# Interface pinned here (lib\clean\dev.ps1):
#   $script:SWEEPR_CLEAN_DEV_LOADED         marker; set to $false, the next load defines everything again
#   $script:SweeprSkipExternalTools         created as $false by the first load when it does not exist, never changed by a later load
#   Old names, kept as forwarding functions (no aliases) with the old parameter lists:
#     Invoke-DevToolsCleanup, Clear-NpmCache, Clear-NodeBuildCaches, Clear-PythonCaches, Clear-DotNetDevCaches,
#     Clear-GoCaches, Clear-MiseCache, Clear-ElixirCaches, Clear-HaskellCaches, Clear-OCamlCaches, Clear-CloudCliCaches,
#     Clear-EditorCaches, Clear-IdeCaches, Invoke-SweeprOwnerCacheCleanup, Get-SweeprOwnerCachePath,
#     Invoke-SweeprOwnerProcess, Get-FilesWithinBudget (the last one is covered in SwCleanDevScan)
#
# Seams used with Mock: the new functions behind the forwarding functions. Loading is checked in child
# PowerShell processes, so that the state of this session does not matter; they run with -NonInteractive,
# without input, and with the environment variables pointing below $TestDrive.
#
# Platform notes:
#   - Tests marked [W] need real Windows. They are meant to fail on Linux and belong in
#     tests/linux-known-failures.txt.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    # Old name, new name.
    $script:Forwards = @(
        @{ Old = 'Invoke-DevToolsCleanup'; New = 'Invoke-SwDevCleanup' }
        @{ Old = 'Clear-NpmCache'; New = 'Clear-SwNpmFamilyCaches' }
        @{ Old = 'Clear-NodeBuildCaches'; New = 'Clear-SwNodeBuildCaches' }
        @{ Old = 'Clear-PythonCaches'; New = 'Clear-SwPythonCaches' }
        @{ Old = 'Clear-DotNetDevCaches'; New = 'Clear-SwDotNetCaches' }
        @{ Old = 'Clear-GoCaches'; New = 'Clear-SwGoCaches' }
        @{ Old = 'Clear-MiseCache'; New = 'Clear-SwMiseCache' }
        @{ Old = 'Clear-ElixirCaches'; New = 'Clear-SwElixirCaches' }
        @{ Old = 'Clear-HaskellCaches'; New = 'Clear-SwHaskellCaches' }
        @{ Old = 'Clear-OCamlCaches'; New = 'Clear-SwOCamlCaches' }
        @{ Old = 'Clear-CloudCliCaches'; New = 'Clear-SwCloudCliCaches' }
        @{ Old = 'Clear-EditorCaches'; New = 'Clear-SwEditorCaches' }
        @{ Old = 'Clear-IdeCaches'; New = 'Clear-SwIdeCaches' }
    )
    $script:GoneNames = @(
        @{ Name = 'Clear-RustCaches' }, @{ Name = 'Clear-DockerCaches' }, @{ Name = 'Clear-GitCaches' }
        @{ Name = 'Clear-SwRustCaches' }, @{ Name = 'Clear-SwDockerCaches' }, @{ Name = 'Clear-SwGitCaches' }
        @{ Name = 'Clear-SwJetBrainsCaches' }, @{ Name = 'Clear-SwJvmCaches' }, @{ Name = 'Clear-SwCabalCaches' }
    )
    $script:Preferences = @(@{ Preference = 'Stop' }, @{ Preference = 'Continue' }, @{ Preference = 'SilentlyContinue' })
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
    function script:Use-Spies([switch]$RealSections, [switch]$RealNotMeasured) {
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
        if (-not $RealNotMeasured) { Mock Add-SwNotMeasured { $script:NotMeasured.Add([pscustomobject]@{ Name = $Name; Reason = $Reason; Section = [string]$script:CurrentSection.Name }) } }
        $script:Activity = 0
        Mock Set-SwSectionActivity { $script:Activity++ }
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

    # The process side of the owner paths as a net: no command starts, no process is created. Every command call is recorded.
    function script:Use-ProcessNet {
        $script:OwnerCommands = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-SwOwnerCommand {
            $script:OwnerCommands.Add([pscustomobject]@{ Name = $Name; Arguments = @($Arguments); Mutation = [bool]$Mutation; TimeoutSeconds = $TimeoutSeconds })
            $null
        }
        Mock New-SwOwnerProcess { throw 'a process must not be created in this test' }
        Mock Start-Process { throw 'Start-Process must not run in this test' }
    }
    # The owner paths as a net: no query finds a tool (Get-SwOwnerCachePath gives $null) and nothing starts.
    function script:Use-OwnerNet {
        $script:OwnerQueries = [System.Collections.Generic.List[object]]::new()
        Mock Get-SwOwnerCachePath { $script:OwnerQueries.Add([pscustomobject]@{ Name = $Name; Arguments = @($Arguments) }); $null }
        Use-ProcessNet
    }

    # ---- one case: a fake profile below the test drive --------------------------------------------

    function script:Initialize-Case {
        param([switch]$RealProcess, [switch]$RealIdentity, [switch]$NoNet, [switch]$Real, [switch]$RealSections, [switch]$OwnerSpy, [switch]$RealNotMeasured, [switch]$ProcessNetOnly)
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
        Use-Spies -RealSections:$RealSections -RealNotMeasured:$RealNotMeasured
        if (-not $RealProcess) { Mock Get-Process { @() } }
        if ($ProcessNetOnly) { Use-ProcessNet }
        elseif (-not $NoNet) { Use-OwnerNet }
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
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
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

    $script:DevFile = [System.IO.Path]::Combine($script:CleanDir, 'dev.ps1')
    # Runs a child that loads the core modules and dev.ps1, then the extra lines, and gives its output lines.
    function script:Invoke-LoadChild([string]$Extra, [hashtable]$Environment = @{}, [string]$WorkingDirectory = $TestDrive, [switch]$SkipCore) {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('$ErrorActionPreference = ''Stop''')
        if (-not $SkipCore) { foreach ($name in 'base.ps1', 'log.ps1', 'file_ops.ps1') { $lines.Add('. ' + (ConvertTo-TestLiteral (P $script:CoreDir $name))) } }
        $lines.Add($Extra)
        $result = Invoke-ChildPowerShell -Script ($lines -join "`n") -WorkingDirectory $WorkingDirectory -Environment $Environment
        $result
    }
    function script:Get-ChildLines($Result) { @(($Result.Out -split "`r?`n") | Where-Object { $_ -ne '' }) }
    $script:LoadDev = '. ' + (ConvertTo-TestLiteral $script:DevFile)
}

AfterAll {
    Clear-TestLinks
    Restore-Env $script:RootEnv
    Restore-State $script:RootState
    [System.Environment]::CurrentDirectory = $script:RootDirectory
    try { Set-Location -LiteralPath $script:RootLocation } catch { $null = $_ }
}
Describe 'CD-1 loading dev.ps1' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        $script:SavedEnvLoad = Save-Env $script:EnvNames
        $script:Work = New-Work
        foreach ($name in 'USERPROFILE', 'HOME', 'LOCALAPPDATA', 'APPDATA', 'TEMP', 'PROGRAMDATA') { Set-Env $name (New-Dir (P $script:Work $name)) }
        $script:ChildEnv = @{ USERPROFILE = (P $script:Work 'USERPROFILE'); HOME = (P $script:Work 'HOME'); LOCALAPPDATA = (P $script:Work 'LOCALAPPDATA')
            APPDATA = (P $script:Work 'APPDATA'); TEMP = (P $script:Work 'TEMP'); PROGRAMDATA = (P $script:Work 'PROGRAMDATA'); SWEEPR_NO_OPLOG = '1' }
    }
    AfterEach { Restore-Env $script:SavedEnvLoad }

    It 'CD-1 gives the file lib\clean\dev.ps1, ASCII or with a byte order mark, and the functions of the section after loading' {
        [System.IO.File]::Exists($script:DevFile) | Should -BeTrue
        Assert-Defined @('Invoke-SwDevCleanup', 'Get-SwBoundedFileScan', 'Invoke-SwOwnerCacheCleanup', 'Get-SwOwnerCachePath', 'Invoke-SwOwnerCommand', 'New-SwOwnerProcess')
    }

    It 'CD-1 writes nothing to the output or the error stream when the file is loaded after the core modules, and defines the section function' {
        $result = Invoke-LoadChild ($script:LoadDev + "`n" + 'if (Get-Command Invoke-SwDevCleanup -CommandType Function -ErrorAction SilentlyContinue) { ''defined'' }') $script:ChildEnv
        (Get-ChildLines $result) | Should -Be @('defined')
        (Get-ChildStderr $result.Err) | Should -Be ''
        $result.ExitCode | Should -Be 0
    }

    It 'CD-1 loads without the core modules loaded first: its own dependencies come from its own folder' {
        $extra = $script:LoadDev + "`n" + 'foreach ($n in ''Write-SwDebug'', ''Remove-SwItems'', ''Clear-SwDirectoryContents'', ''Test-SwProtectedPath'', ''Clear-SwAppCache'', ''Get-SwCacheProfiles'', ''Invoke-SwDevCleanup'') { if (Get-Command $n -CommandType Function -ErrorAction SilentlyContinue) { $n } }'
        $result = Invoke-LoadChild $extra $script:ChildEnv -SkipCore
        (Get-ChildLines $result) | Should -Be @('Write-SwDebug', 'Remove-SwItems', 'Clear-SwDirectoryContents', 'Test-SwProtectedPath', 'Clear-SwAppCache', 'Get-SwCacheProfiles', 'Invoke-SwDevCleanup')
        (Get-ChildStderr $result.Err) | Should -Be ''
    }

    It 'CD-1 takes its dependencies from its own folder, not from the working directory and not from variables of the caller' {
        $decoy = New-Dir (P $script:Work 'decoy')
        foreach ($folder in @($decoy, (P $decoy 'lib' 'core'), (P $decoy 'lib' 'clean'), (P $decoy 'core'), (P $decoy 'clean'))) {
            foreach ($name in 'base.ps1', 'log.ps1', 'file_ops.ps1', 'cache_guard.ps1', 'dev.ps1') {
                $null = New-File (P $folder $name) 1
                [System.IO.File]::WriteAllText((P $folder $name), "'DECOY ' + `$PSCommandPath`r`n", $script:Utf8)
            }
        }
        $extra = '$scriptDir = ' + (ConvertTo-TestLiteral $decoy) + '; $script:scriptDir = $scriptDir; $root = $scriptDir; $PSScriptRootCaller = $scriptDir' + "`n" +
        $script:LoadDev + "`n" + 'if (Get-Command Invoke-SwDevCleanup -CommandType Function -ErrorAction SilentlyContinue) { ''defined'' }'
        $result = Invoke-LoadChild $extra $script:ChildEnv -WorkingDirectory $decoy -SkipCore
        (Get-ChildLines $result) | Should -Be @('defined')
    }

    It 'CD-1 starts no process, creates no file or folder and asks neither the registry nor the network while it loads' {
        # The shell itself writes below HOME when it starts; the folders the section works with must stay as they are.
        $watched = @('USERPROFILE', 'LOCALAPPDATA', 'APPDATA', 'TEMP', 'PROGRAMDATA')
        $before = @($watched | ForEach-Object { (Get-Listing (P $script:Work $_)) -join '|' })
        $extra = 'function Start-Process { ''START-PROCESS'' }' + "`n" + 'function Invoke-WebRequest { ''WEB'' }' + "`n" + 'function Get-ItemProperty { ''REGISTRY'' }' + "`n" +
        'function Get-AppxPackage { ''APPX'' }' + "`n" + 'function Get-CimInstance { ''CIM'' }' + "`n" + $script:LoadDev + "`n" + '''done'''
        $result = Invoke-LoadChild $extra $script:ChildEnv
        (Get-ChildLines $result) | Should -Be @('done')
        $after = @($watched | ForEach-Object { (Get-Listing (P $script:Work $_)) -join '|' })
        ($after -join "`n") | Should -BeExactly ($before -join "`n")
    }

    It 'CD-1 creates $script:SweeprSkipExternalTools as $false when it does not exist' {
        $extra = $script:LoadDev + "`n" + '$v = Get-Variable -Name SweeprSkipExternalTools -Scope Script -ErrorAction SilentlyContinue; if ($null -eq $v) { ''missing'' } else { $v.Value.GetType().Name + '':'' + $v.Value }'
        $result = Invoke-LoadChild $extra $script:ChildEnv
        (Get-ChildLines $result) | Should -Be @('Boolean:False')
    }

    It 'CD-1 leaves $script:SweeprSkipExternalTools as it is on the first load when the variable exists: <Label>' -ForEach @(
        @{ Label = '$true'; Literal = '$true'; Expected = 'Boolean:True' }
        @{ Label = '$false'; Literal = '$false'; Expected = 'Boolean:False' }
        @{ Label = 'the number 1'; Literal = '1'; Expected = 'Int32:1' }
        @{ Label = 'the text yes'; Literal = '''yes'''; Expected = 'String:yes' }
        @{ Label = '$null'; Literal = '$null'; Expected = 'null' }
    ) {
        $extra = '$script:SweeprSkipExternalTools = ' + $Literal + "`n" + $script:LoadDev + "`n" +
        '$v = $script:SweeprSkipExternalTools; if ($null -eq $v) { ''null'' } else { $v.GetType().Name + '':'' + $v }'
        $result = Invoke-LoadChild $extra $script:ChildEnv
        (Get-ChildLines $result) | Should -Be @($Expected)
    }

    It 'CD-1 changes nothing on a second load in the same scope, also not after the marker was set to $false: variables set by a test stay' {
        $extra = $script:LoadDev + "`n" +
        '$script:SweeprSkipExternalTools = $true; $script:TotalSizeCleaned = 7; $script:OwnerCleanups = 3; $script:SwWalkBudgetSeconds = 5' + "`n" +
        $script:LoadDev + "`n" + '$script:SWEEPR_CLEAN_DEV_LOADED = $false' + "`n" + $script:LoadDev + "`n" +
        '[string]$script:SweeprSkipExternalTools + '':'' + $script:TotalSizeCleaned + '':'' + $script:OwnerCleanups + '':'' + $script:SwWalkBudgetSeconds'
        $result = Invoke-LoadChild $extra $script:ChildEnv
        (Get-ChildLines $result) | Should -Be @('True:7:3:5')
        (Get-ChildStderr $result.Err) | Should -Be ''
    }

    It 'CD-1 defines nothing again on a second load: a function replaced after the first load stays replaced' {
        $extra = $script:LoadDev + "`n" + 'function Clear-SwGoCaches { ''sentinel'' }' + "`n" + $script:LoadDev + "`n" + '(Get-Command Clear-SwGoCaches -CommandType Function).ScriptBlock.ToString().Trim()'
        $result = Invoke-LoadChild $extra $script:ChildEnv
        (Get-ChildLines $result) | Should -Be @('''sentinel''')
    }

    It 'CD-1 defines everything again when the marker was set to $false: the replaced function is the real one afterwards' {
        $extra = $script:LoadDev + "`n" + 'function Clear-SwGoCaches { ''sentinel'' }' + "`n" + '$script:SWEEPR_CLEAN_DEV_LOADED = $false' + "`n" + $script:LoadDev + "`n" +
        '$text = (Get-Command Clear-SwGoCaches -CommandType Function).ScriptBlock.ToString(); if ($text -match ''sentinel'') { ''still the sentinel'' } else { ''redefined'' }'
        $result = Invoke-LoadChild $extra $script:ChildEnv
        (Get-ChildLines $result) | Should -Be @('redefined')
    }

    It 'CD-1 sets the marker $script:SWEEPR_CLEAN_DEV_LOADED to $true when it has loaded' {
        $extra = $script:LoadDev + "`n" + '$v = Get-Variable -Name SWEEPR_CLEAN_DEV_LOADED -Scope Script -ErrorAction SilentlyContinue; if ($null -eq $v) { ''missing'' } else { [string]$v.Value }'
        $result = Invoke-LoadChild $extra $script:ChildEnv
        (Get-ChildLines $result) | Should -Be @('True')
    }

    It 'CD-1 creates no variable in the scope of the caller: loading into a function scope after the core modules adds nothing there, and no scriptDir' {
        $extra = 'function Test-Scope {' + "`n" +
        '. ' + (ConvertTo-TestLiteral (P $script:CleanDir 'cache_guard.ps1')) + "`n" +
        '$names0 = @(Get-Variable -Scope 0 | ForEach-Object { $_.Name }); $names0 += ''names0''' + "`n" +
        $script:LoadDev + "`n" +
        '$added = @(Get-Variable -Scope 0 | ForEach-Object { $_.Name } | Where-Object { $names0 -notcontains $_ -and $_ -ne ''added'' })' + "`n" +
        '''added=['' + ($added -join '','') + '']''' + "`n" +
        'if (Get-Variable -Name scriptDir -ErrorAction SilentlyContinue) { ''scriptDir exists'' }' + "`n" +
        '}' + "`n" + 'Test-Scope'
        $result = Invoke-LoadChild $extra $script:ChildEnv
        (Get-ChildLines $result) | Should -Be @('added=[]')
    }

    It 'CD-1 changes neither the strict mode nor the error preference after the core modules set them: Latest and Stop stay' {
        $extra = $script:LoadDev + "`n" + '$ErrorActionPreference' + "`n" +
        'try { $null = $undefinedVariableForStrictMode; ''strict off'' } catch { ''strict on'' }'
        $result = Invoke-LoadChild $extra $script:ChildEnv
        (Get-ChildLines $result) | Should -Be @('Stop', 'strict on')
    }

    It 'CD-1 loads under every error preference of the caller before the core modules: <Preference>' -ForEach $script:Preferences {
        $extra = '$ErrorActionPreference = ' + (ConvertTo-TestLiteral $Preference) + "`n" + $script:LoadDev + "`n" + '''loaded'''
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add($extra)
        $result = Invoke-ChildPowerShell -Script ($lines -join "`n") -WorkingDirectory $TestDrive -Environment $script:ChildEnv
        (Get-ChildLines $result) | Should -Be @('loaded')
        (Get-ChildStderr $result.Err) | Should -Be ''
    }

    It 'CD-1 loads in a scope that is already loaded in this session (dot-sourced twice) without a message' {
        $out = Invoke-Captured { . $script:DevFile }
        $out.Count | Should -Be 0
    }
}

Describe 'Section 6 old names of the developer tool functions are forwarding functions' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
    }
    AfterEach { Stop-Case }

    It 'Section 6 <Old> is a function with no parameters and no CmdletBinding, not an alias, and calls <New> once' -ForEach $script:Forwards {
        (Get-Command -Name $Old -ErrorAction Stop).CommandType | Should -Be 'Function'
        @(Get-Alias -Name $Old -ErrorAction SilentlyContinue).Count | Should -Be 0
        (Get-Command -Name $Old).CmdletBinding | Should -BeFalse
        (Get-ParamCount $Old) | Should -Be 0
        $script:Forwarded = [System.Collections.Generic.List[string]]::new()
        Mock $New ([scriptblock]::Create('$script:Forwarded.Add(' + [char]39 + $New + [char]39 + ')'))
        $out = Invoke-Captured { & $Old }
        $out.Count | Should -Be 0
        $script:Forwarded.Count | Should -Be 1
        $script:Forwarded[0] | Should -Be $New
    }

    It 'Section 6 gives the return value of the new function back unchanged: Invoke-DevToolsCleanup passes it on' {
        $script:Marker = [pscustomobject]@{ Name = 'same' }
        Mock Invoke-SwDevCleanup { $script:Marker }
        $result = Invoke-DevToolsCleanup
        [object]::ReferenceEquals($result, $script:Marker) | Should -BeTrue
    }

    It 'Section 6 Invoke-SweeprOwnerCacheCleanup keeps Name, Query, Arguments and Description at positions 0 to 3 without defaults' {
        (Get-ParamLine 'Invoke-SweeprOwnerCacheCleanup' 'Name') | Should -Be 'Name|System.String|pos=0|mandatory=False|default='
        (Get-ParamLine 'Invoke-SweeprOwnerCacheCleanup' 'Query') | Should -Be 'Query|System.String[]|pos=1|mandatory=False|default='
        (Get-ParamLine 'Invoke-SweeprOwnerCacheCleanup' 'Arguments') | Should -Be 'Arguments|System.String[]|pos=2|mandatory=False|default='
        (Get-ParamLine 'Invoke-SweeprOwnerCacheCleanup' 'Description') | Should -Be 'Description|System.String|pos=3|mandatory=False|default='
        (Get-ParamCount 'Invoke-SweeprOwnerCacheCleanup') | Should -Be 4
        (Get-Command -Name Invoke-SweeprOwnerCacheCleanup).CmdletBinding | Should -BeFalse
    }

    It 'Section 6 Invoke-SweeprOwnerCacheCleanup calls Invoke-SwOwnerCacheCleanup once with the four bound values' {
        $script:Seen = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-SwOwnerCacheCleanup { $script:Seen.Add([pscustomobject]@{ Name = $Name; Query = @($Query); Arguments = @($Arguments); Description = $Description }) }
        Invoke-SweeprOwnerCacheCleanup 'npm' @('config', 'get', 'cache') @('cache', 'clean', '--force') 'npm cache'
        $script:Seen.Count | Should -Be 1
        $script:Seen[0].Name | Should -Be 'npm'
        ($script:Seen[0].Query -join ' ') | Should -Be 'config get cache'
        ($script:Seen[0].Arguments -join ' ') | Should -Be 'cache clean --force'
        $script:Seen[0].Description | Should -Be 'npm cache'
    }

    It 'Section 6 Get-SweeprOwnerCachePath keeps Name and Arguments at positions 0 and 1 and gives the string of the new function back' {
        (Get-ParamLine 'Get-SweeprOwnerCachePath' 'Name') | Should -Be 'Name|System.String|pos=0|mandatory=False|default='
        (Get-ParamLine 'Get-SweeprOwnerCachePath' 'Arguments') | Should -Be 'Arguments|System.String[]|pos=1|mandatory=False|default='
        (Get-ParamCount 'Get-SweeprOwnerCachePath') | Should -Be 2
        $script:Seen = [System.Collections.Generic.List[object]]::new()
        Mock Get-SwOwnerCachePath { $script:Seen.Add([pscustomobject]@{ Name = $Name; Arguments = @($Arguments) }); (P $script:Work 'npm-cache') }
        $result = Get-SweeprOwnerCachePath 'npm' @('config', 'get', 'cache')
        $result | Should -BeExactly (P $script:Work 'npm-cache')
        $script:Seen.Count | Should -Be 1
        $script:Seen[0].Name | Should -Be 'npm'
        ($script:Seen[0].Arguments -join ' ') | Should -Be 'config get cache'
    }

    It 'Section 6 Get-SweeprOwnerCachePath gives $null back when the new function does' {
        Mock Get-SwOwnerCachePath { $null }
        $null -eq (Get-SweeprOwnerCachePath 'npm' @('x')) | Should -BeTrue
    }

    It 'Section 6 Invoke-SweeprOwnerProcess keeps Name, Arguments, TimeoutSeconds (default 5) and Outcome at positions 0 to 3' {
        (Get-ParamLine 'Invoke-SweeprOwnerProcess' 'Name') | Should -Be 'Name|System.String|pos=0|mandatory=False|default='
        (Get-ParamLine 'Invoke-SweeprOwnerProcess' 'Arguments') | Should -Be 'Arguments|System.String[]|pos=1|mandatory=False|default='
        (Get-ParamLine 'Invoke-SweeprOwnerProcess' 'TimeoutSeconds') | Should -Be 'TimeoutSeconds|System.Int32|pos=2|mandatory=False|default=5'
        (Get-ParamLine 'Invoke-SweeprOwnerProcess' 'Outcome') | Should -Be 'Outcome|System.Collections.Hashtable|pos=3|mandatory=False|default=$null'
        (Get-ParamCount 'Invoke-SweeprOwnerProcess') | Should -Be 4
    }

    It 'Section 6 Invoke-SweeprOwnerProcess calls Invoke-SwOwnerCommand once without -Mutation and passes -Outcome only when given' {
        $script:Seen = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-SwOwnerCommand {
            $script:Seen.Add([pscustomobject]@{ Name = $Name; Arguments = @($Arguments); TimeoutSeconds = $TimeoutSeconds; Mutation = [bool]$Mutation; Bound = @($PesterBoundParameters.Keys) })
            [pscustomobject]@{ Output = 'x' }
        }
        $outcome = @{ Reason = '' }
        $result = Invoke-SweeprOwnerProcess 'npm' @('config', 'get', 'cache') 9 $outcome
        $result.Output | Should -Be 'x'
        $null = Invoke-SweeprOwnerProcess 'npm' @('a')
        $script:Seen.Count | Should -Be 2
        $script:Seen[0].Mutation | Should -BeFalse
        $script:Seen[0].TimeoutSeconds | Should -Be 9
        $script:Seen[0].Bound | Should -Contain 'Outcome'
        $script:Seen[1].Mutation | Should -BeFalse
        $script:Seen[1].TimeoutSeconds | Should -Be 5
        $script:Seen[1].Bound | Should -Not -Contain 'Outcome'
    }

    It 'Section 6 CD-9 3.7 gives no function and no forwarding function for Rust, Docker, Git, JetBrains, JVM or Cabal: <Name>' -ForEach $script:GoneNames {
        $null -eq (Get-Command -Name $Name -ErrorAction SilentlyContinue) | Should -BeTrue
    }
}
