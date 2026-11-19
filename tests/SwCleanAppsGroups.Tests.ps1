# Sweepr - tests for lib\clean\apps.ps1, the section "Applications": the order of the five groups, the rows of every
# group (sink, path, description, process names), Office and Drive files with an age and an owner check, OneDrive
# and Google Drive logs, Adobe, the game launchers, path building from the environment, loading, the old names and
# the end-to-end behavior with real removal helpers below $TestDrive.
#
# The rule numbers in the test names (CD-, CA-, S- and so on) number the rules and the safety invariants
# of the behavior of the developer tool and application cleanup; each rule and invariant has at least one test.
# The other files of this slice are SwCleanDevGroups, SwCleanDevLoad, SwCleanDevScan, SwCleanDevOwnerPath,
# SwCleanDevOwnerRun, SwCleanDevProcess, SwCleanDevEditors, SwCleanAppsMedia and SwCleanDevAppsSafety.
#
# Interface pinned here (new names, lib\clean\apps.ps1, loaded by dot-sourcing after dev.ps1, as preview.ps1 does):
#   Invoke-SwAppCleanup [-IncludeGameMedia] [-GameMediaDaysOld <int> = 90]    the section "Applications" (CA-1)
#   Clear-SwOfficeCache, Clear-SwOneDriveCache, Clear-SwGoogleDriveCache, Clear-SwAdobeCaches, Clear-SwGamePlatformCaches
#   Clear-SwGameMedia [-DaysOld <int> = 90]                                   the section "Game media (>Nd old)" (SwCleanAppsMedia)
#   Old names: Invoke-AppCleanup (-IncludeOrphaned accepted and ignored), Clear-OfficeCache, Clear-OneDriveCache,
#   Clear-GoogleDriveCache, Clear-AdobeData, Clear-GamingPlatformCaches, Clear-GameMediaFiles
#
# Seams used with Mock: Clear-SwDirectoryContents, Remove-SwItems, Remove-SwOldFiles and Clear-SwAppCache (spies that
# record every call in order), Get-SwBoundedFileScan (spy with answers per root), Test-SwCacheOwnerIdle, Get-Date
# (fixed, counted), Get-Process, Get-SwPathSnapshot and Test-SwPathSnapshot (substitute objects), the log writers,
# Write-SwOperation, Start-SwSection and Stop-SwSection.
#
# Platform notes:
#   - Paths are built from $TestDrive with the separator of the host. Real removals happen only below $TestDrive,
#     only in the end-to-end cases, with substitute identities.
#   - On Linux the creation time of a file follows its write time (see SwCleanDevScan).
#   - Tests marked [W] need real Windows. They are meant to fail on Linux and belong in
#     tests/linux-known-failures.txt.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    $script:AppGroups = @(
        @{ Group = 'Clear-SwOfficeCache' }, @{ Group = 'Clear-SwOneDriveCache' }, @{ Group = 'Clear-SwGoogleDriveCache' }
        @{ Group = 'Clear-SwAdobeCaches' }, @{ Group = 'Clear-SwGamePlatformCaches' }
    )
    $script:BadValues = @(
        @{ Label = 'not set'; Value = $null }
        @{ Label = 'blank'; Value = '   ' }
        @{ Label = 'a relative path'; Value = 'rel/x' }
        @{ Label = 'a drive-relative path'; Value = 'C:Temp' }
        @{ Label = 'a UNC path'; Value = '\\server\x' }
    )
    # Variable, a group whose targets all lie below it.
    $script:RootCases = @(
        @{ Variable = 'LOCALAPPDATA'; Group = 'Clear-SwOneDriveCache' }
        @{ Variable = 'APPDATA'; Group = 'Clear-SwAdobeCaches' }
    )
    $script:Forwards = @(
        @{ Old = 'Clear-OfficeCache'; New = 'Clear-SwOfficeCache' }
        @{ Old = 'Clear-OneDriveCache'; New = 'Clear-SwOneDriveCache' }
        @{ Old = 'Clear-GoogleDriveCache'; New = 'Clear-SwGoogleDriveCache' }
        @{ Old = 'Clear-AdobeData'; New = 'Clear-SwAdobeCaches' }
        @{ Old = 'Clear-GamingPlatformCaches'; New = 'Clear-SwGamePlatformCaches' }
    )
    $script:GoneNames = @(
        @{ Name = 'Clear-AutodeskData' }, @{ Name = 'Clear-SwAutodeskCaches' }, @{ Name = 'Find-OrphanedAppData' }
        @{ Name = 'Clear-OrphanedAppData' }, @{ Name = 'Get-InstalledPrograms' }, @{ Name = 'Find-SwOrphanedAppData' }, @{ Name = 'Clear-SwOrphanedAppData' }
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

    # ---- identity: a fake for Get-SwPathSnapshot and Test-SwPathSnapshot (Linux has no file identity) --

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
            $script:ScanCalls.Add([pscustomobject]@{ Root = $Root; Filter = $Filter; Extensions = @($Extensions | Where-Object { $null -ne $_ }); OlderThan = $OlderThan; NoRecurse = [bool]$NoRecurse; TimeoutSeconds = $TimeoutSeconds; HasTimeout = $PesterBoundParameters.ContainsKey('TimeoutSeconds'); HasOlderThan = $PesterBoundParameters.ContainsKey('OlderThan') })
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
    . ([System.IO.Path]::Combine($script:CleanDir, 'apps.ps1'))

    # ---- the owner path: one cache folder, a query answer, a command that acts on it ----------------

    # The real functions behind the counting stand-ins (captured before any case mocks them).
    $script:RealTree = (Get-Command -Name Get-SwSafeDirectoryTreeItems -CommandType Function).ScriptBlock
    $script:RealWhitelist = (Get-Command -Name Get-SwWhitelistState -CommandType Function).ScriptBlock

    # A cache folder like the one of npm: _cacache\gone.bin (4096 bytes) and kept.bin (2048 bytes).
    function script:New-NpmCache([string]$Root) {
        $null = New-File (P $Root '_cacache' 'gone.bin') 4096
        $null = New-File (P $Root 'kept.bin') 2048
        $Root
    }
    # What the query of every tool answers (per call number, the last answer repeats; or per tool name through
    # $script:QueryByName), what the mutation does ($script:OnCommand gets the outcome table and gives the result),
    # and counters for the whitelist reads and the tree listings. Nothing here starts a process.
    function script:Use-OwnerRun {
        param([AllowNull()][string[]]$Answers = @())
        $script:QueryCalls = [System.Collections.Generic.List[object]]::new()
        $script:QueryAnswers = @($Answers)
        $script:QueryByName = @{}
        $script:OnQuery = $null
        $script:Commands = [System.Collections.Generic.List[object]]::new()
        $script:TreeCalls = 0
        $script:WlReads = 0
        $script:OnCommand = {
            param($Outcome)
            $gone = P $script:Cache '_cacache' 'gone.bin'
            if ([System.IO.File]::Exists($gone)) { [System.IO.File]::Delete($gone) }
            [pscustomobject]@{ Output = '' }
        }
        Mock Get-SwOwnerCachePath {
            $script:QueryCalls.Add([pscustomobject]@{ Name = $Name; Arguments = @($Arguments) })
            if ($null -ne $script:OnQuery) { & $script:OnQuery $script:QueryCalls.Count }
            if ($script:QueryByName.ContainsKey($Name)) { return $script:QueryByName[$Name] }
            $answers = @($script:QueryAnswers)
            if ($answers.Count -eq 0) { return $null }
            $index = [Math]::Min($script:QueryCalls.Count - 1, $answers.Count - 1)
            return $answers[$index]
        }
        Mock Invoke-SwOwnerCommand {
            $script:Commands.Add([pscustomobject]@{ Name = $Name; Arguments = @($Arguments); Mutation = [bool]$Mutation; TimeoutSeconds = $TimeoutSeconds
                    HasTimeout = $PesterBoundParameters.ContainsKey('TimeoutSeconds'); Outcome = $Outcome })
            & $script:OnCommand $Outcome
        }
        Mock Get-SwWhitelistState { $script:WlReads++; & $script:RealWhitelist }
        Mock Get-SwSafeDirectoryTreeItems { $script:TreeCalls++; & $script:RealTree -Path $Path -WhitelistState $WhitelistState }
        Mock Get-SwValidatedTreeSize { throw 'Get-SwValidatedTreeSize must not be used by the owner path' }
    }
    function script:Get-Mutations { @($script:Commands | Where-Object { $_.Mutation }) }
    function script:Invoke-NpmCleanup {
        Invoke-SwOwnerCacheCleanup -Name 'npm' -Query @('config', 'get', 'cache') -Arguments @('cache', 'clean', '--force') -Description 'npm cache'
    }
    function script:Get-NpmNotMeasured { @(Get-NotMeasuredFor 'npm') }
    function script:Get-OpsOf([string]$Action) { @($script:Ops | Where-Object { $_.Action -ceq $Action }) }
    # A folder with one file and the folder _cacache, so that every characteristic can be added on top.
    function script:New-PlainCache([string]$Root) {
        $null = New-File (P $Root 'file.bin') 2048
        $Root
    }
    # Items of a tree as a stand-in gives them; each property can be left out.
    function script:New-TreeItem([string]$Path, [hashtable]$Leave = @{}) {
        $props = [ordered]@{}
        if (-not $Leave.ContainsKey('FullName')) { $props['FullName'] = $Path }
        if (-not $Leave.ContainsKey('PSIsContainer')) { $props['PSIsContainer'] = $false }
        if (-not $Leave.ContainsKey('Attributes')) { $props['Attributes'] = [System.IO.FileAttributes]::Archive }
        if (-not $Leave.ContainsKey('Length')) { $props['Length'] = [long]100 }
        if (-not $Leave.ContainsKey('SweeprPathSnapshot')) { $props['SweeprPathSnapshot'] = [pscustomobject]@{ Path = $Path; AllowLeafLink = $true } }
        [pscustomobject]$props
    }
    function script:Use-FixedTree([object[]]$Items) {
        $script:FixedItems = @($Items)
        Mock Get-SwSafeDirectoryTreeItems {
            $script:TreeCalls++
            @{ Success = $true; Items = @($script:FixedItems); RootSnapshot = [pscustomobject]@{ Path = $Path; AllowLeafLink = $true }; Reason = '' }
        }
    }
    $script:AppsFile = [System.IO.Path]::Combine($script:CleanDir, 'apps.ps1')
    $script:OfficeNames = @('WINWORD', 'EXCEL', 'POWERPNT', 'OUTLOOK', 'ONENOTE')

    function script:ED([string]$Path, [string]$Description) { 'D|' + (Fold $Path) + '|' + $Description }
    function script:EA([string]$Path, [string]$Description, [string]$Processes) { 'A|' + (Fold $Path) + '|' + $Description + '|' + $Processes }
    function script:ER([string[]]$Paths, [string]$Description) { 'R|' + ((@($Paths) | ForEach-Object { Fold $_ }) -join ';') + '|' + $Description }
    function script:EO([string]$Path, [int]$Days, [string]$Description) { 'O|' + (Fold $Path) + '|' + $Days + '|*|' + $Description }
    function script:Format-Calls {
        @($script:Calls | ForEach-Object {
                $call = $_
                switch ($call.Fn) {
                    'Clear-SwDirectoryContents' { 'D|' + (Fold $call.Path) + '|' + $call.Description }
                    'Clear-SwAppCache' { 'A|' + (Fold $call.Path) + '|' + $call.Description + '|' + (@($call.Processes) -join ',') }
                    'Remove-SwItems' { 'R|' + ((@($call.Paths) | ForEach-Object { Fold $_ }) -join ';') + '|' + $call.Description }
                    'Remove-SwOldFiles' { 'O|' + (Fold $call.Path) + '|' + $call.DaysOld + '|' + $call.Filter + '|' + $call.Description }
                    default { $call.Fn + '|' + $call.Path }
                }
            })
    }
    function script:Show([string[]]$Lines) { (@($Lines) -join "`n") }

    $script:Templates = $null
    function script:Get-OfficeBases { @((P $script:Roam 'Microsoft' 'Templates'), (P $script:Roam 'Microsoft' 'Word'), (P $script:Roam 'Microsoft' 'Excel'), (P $script:Roam 'Microsoft' 'PowerPoint')) }
    function script:Get-ExpectedAppRows([string]$Group) {
        switch ($Group) {
            'Clear-SwOfficeCache' {
                @(
                    (EA (P $script:Local 'Microsoft' 'Office' '16.0' 'Wef') 'Office Wef' 'WINWORD,EXCEL,POWERPNT,OUTLOOK,ONENOTE')
                    (EA (P $script:Local 'Microsoft' 'Outlook' 'Offline Address Books') 'Office Offline Address Books' 'OUTLOOK')
                    (ER @((P $script:Roam 'Microsoft' 'Templates' 'a.tmp'), (P $script:Roam 'Microsoft' 'Excel' 'e.tmp')) 'Office temp files')
                )
            }
            'Clear-SwOneDriveCache' { @((EO (P $script:Local 'Microsoft' 'OneDrive' 'setup' 'logs') 7 'OneDrive logs')) }
            'Clear-SwGoogleDriveCache' {
                @(
                    (EO (P $script:Local 'Google' 'DriveFS' 'Logs') 7 'Google Drive logs')
                    (ER @((P $script:Local 'Google' 'DriveFS' 'g.tmp')) 'Google Drive temp')
                )
            }
            'Clear-SwAdobeCaches' {
                @(
                    (ED (P $script:Roam 'Adobe' 'Common' 'Media Cache Files') 'Adobe cache')
                    (ED (P $script:Roam 'Adobe' 'Common' 'Peak Files') 'Adobe cache')
                )
            }
            'Clear-SwGamePlatformCaches' {
                @(
                    (ED (P $script:Local 'EpicGamesLauncher' 'Saved' 'webcache') 'Epic Games webcache')
                    (ED (P $script:Local 'EpicGamesLauncher' 'Saved' 'Logs') 'Epic Games Logs')
                    (ED (P $script:Local 'Electronic Arts' 'EA Desktop' 'cache') 'EA/Origin cache')
                    (ED (P $script:Local 'GOG.com' 'Galaxy' 'webcache') 'GOG Galaxy webcache')
                    (ED (P $script:ProgramData 'GOG.com' 'Galaxy' 'logs') 'GOG Galaxy logs')
                    (ED (P $script:Local 'Ubisoft Game Launcher' 'cache') 'Ubisoft cache')
                    (ED (P $script:Local 'Ubisoft Game Launcher' 'logs') 'Ubisoft logs')
                    (ED (P $script:Roam 'Battle.net' 'Cache') 'Battle.net Cache')
                    (ED (P $script:Roam 'Battle.net' 'Logs') 'Battle.net Logs')
                )
            }
        }
    }
    # The answers of the file search for the rows with files: Templates and Excel hold one file, DriveFS holds one.
    function script:Initialize-AppFixture([string]$Group) {
        Use-ScanSpy
        $script:ScanAnswers[(P $script:Roam 'Microsoft' 'Templates')] = @{ Files = @((P $script:Roam 'Microsoft' 'Templates' 'a.tmp')); Complete = $true }
        $script:ScanAnswers[(P $script:Roam 'Microsoft' 'Excel')] = @{ Files = @((P $script:Roam 'Microsoft' 'Excel' 'e.tmp')); Complete = $true }
        $script:ScanAnswers[(P $script:Local 'Google' 'DriveFS')] = @{ Files = @((P $script:Local 'Google' 'DriveFS' 'g.tmp')); Complete = $true }
    }
    # Every Applications group as a spy, in order, the way Invoke-SwAppCleanup calls them.
    $script:AppGroupOrder = @('Clear-SwOfficeCache', 'Clear-SwOneDriveCache', 'Clear-SwGoogleDriveCache', 'Clear-SwAdobeCaches', 'Clear-SwGamePlatformCaches')
    function script:Use-AppGroupSpies([string]$ThrowIn = '') {
        foreach ($name in $script:AppGroupOrder) {
            $body = '$script:Sections.Add(' + [char]39 + 'group:' + $name + [char]39 + ')'
            if ($name -eq $ThrowIn) { $body += '; throw ' + [char]39 + 'boom of ' + $name + [char]39 }
            Mock $name ([scriptblock]::Create($body))
        }
        Mock Clear-SwGameMedia { $script:Sections.Add('media:' + $DaysOld) }
    }
    function script:Use-FixedNow {
        $script:FixedNow = [datetime]::new(2026, 6, 15, 12, 0, 0)
        $script:DateCalls = 0
        Mock Get-Date { $script:DateCalls++; $script:FixedNow }
    }
}

AfterAll {
    Clear-TestLinks
    Restore-Env $script:RootEnv
    Restore-State $script:RootState
    [System.Environment]::CurrentDirectory = $script:RootDirectory
    try { Set-Location -LiteralPath $script:RootLocation } catch { $null = $_ }
}
Describe 'CA-1 the section of Invoke-SwAppCleanup' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -NoNet
    }
    AfterEach { Stop-Case }

    It 'CA-1 defines the section function, the five groups and the game media function' {
        Assert-Defined (@('Invoke-SwAppCleanup', 'Clear-SwGameMedia') + $script:AppGroupOrder)
    }

    It 'CA-1 opens "Applications" once, runs the five groups in the order of the table, closes the section once and starts no game media without the switch' {
        Use-AppGroupSpies
        Invoke-SwAppCleanup
        $expected = @('start:Applications') + @($script:AppGroupOrder | ForEach-Object { 'group:' + $_ }) + @('stop')
        (Show $script:Sections) | Should -Be (Show $expected)
    }

    It 'CA-1 runs Clear-SwGameMedia -DaysOld 30 once after the section was closed when -IncludeGameMedia and -GameMediaDaysOld 30 are given' {
        Use-AppGroupSpies
        Invoke-SwAppCleanup -IncludeGameMedia -GameMediaDaysOld 30
        $expected = @('start:Applications') + @($script:AppGroupOrder | ForEach-Object { 'group:' + $_ }) + @('stop', 'media:30')
        (Show $script:Sections) | Should -Be (Show $expected)
    }

    It 'CA-1 gives Clear-SwGameMedia 90 days when only the switch is given' {
        Use-AppGroupSpies
        Invoke-SwAppCleanup -IncludeGameMedia
        @($script:Sections | Where-Object { $_ -like 'media:*' }) | Should -Be @('media:90')
    }

    It 'CA-1 gives the parameters IncludeGameMedia (switch) and GameMediaDaysOld (int, default 90), and no IncludeOrphaned' {
        (Get-ParamLine 'Invoke-SwAppCleanup' 'IncludeGameMedia') | Should -BeLike 'IncludeGameMedia|System.Management.Automation.SwitchParameter|*'
        (Get-ParamLine 'Invoke-SwAppCleanup' 'GameMediaDaysOld') | Should -BeLike 'GameMediaDaysOld|System.Int32|*|default=90'
        (Get-Command -Name Invoke-SwAppCleanup).Parameters.ContainsKey('IncludeOrphaned') | Should -BeFalse
    }

    It 'CA-1 CD-4 runs the other four groups and closes the section once when <Group> throws, and does not throw' -ForEach $script:AppGroups {
        Use-AppGroupSpies $Group
        { Invoke-SwAppCleanup } | Should -Not -Throw
        $expected = @('start:Applications') + @($script:AppGroupOrder | ForEach-Object { 'group:' + $_ }) + @('stop')
        (Show $script:Sections) | Should -Be (Show $expected)
        (@(Get-LogLines 'DEBUG') -join "`n") | Should -Match ([regex]::Escape('boom of ' + $Group))
    }

    It 'CD-4 throws nothing and still runs the groups and the game media when the section cannot be opened or closed' {
        Use-AppGroupSpies
        Mock Start-SwSection { throw 'no section' }
        Mock Stop-SwSection { throw 'no section end' }
        { Invoke-SwAppCleanup -IncludeGameMedia -GameMediaDaysOld 30 } | Should -Not -Throw
        @($script:Sections) | Should -Be (@($script:AppGroupOrder | ForEach-Object { 'group:' + $_ }) + @('media:30'))
    }

    It 'CD-4 S-14 writes nothing to the pipeline with the real groups, also when every sink writes a value, and throws nothing' {
        $script:SinkLeak = $true
        (Invoke-Captured { Invoke-SwAppCleanup }).Count | Should -Be 0
        (Invoke-Captured { Invoke-SwAppCleanup -IncludeGameMedia }).Count | Should -Be 0
    }

    It 'CA-1 CA-7 touches no path of the game media table without -IncludeGameMedia, with the real groups' {
        Use-ScanSpy
        Invoke-SwAppCleanup
        $paths = @(Get-CallPaths) + @(Get-ScanRoots)
        foreach ($root in (P $script:Profile 'Videos'), (P $script:Profile 'Pictures'), (P $script:Local 'FortniteGame'), (P $script:Local 'VALORANT'), (P $script:Profile 'Saved Games')) {
            Test-AnyUnder $paths $root | Should -BeFalse -Because $root
        }
    }

    It 'CA-1 CA-14 gives no orphaned app data and no Autodesk: no search of installed programs, no registry or Appx command, no scan of other roots' {
        Use-ScanSpy
        Mock Get-ItemProperty { throw 'the registry must not be read' }
        Invoke-SwAppCleanup -IncludeGameMedia
        Should -Invoke Get-ItemProperty -Times 0 -Exactly
        Test-AnyUnder (@(Get-CallPaths) + @(Get-ScanRoots)) (P $script:Local 'Autodesk') | Should -BeFalse
        Test-AnyUnder (@(Get-CallPaths) + @(Get-ScanRoots)) (P $script:Roam 'Autodesk') | Should -BeFalse
    }

    It 'CA-14 has no functions for orphaned app data, installed programs or Autodesk, also no forwarding function: <Name>' -ForEach $script:GoneNames {
        $null -eq (Get-Command -Name $Name -ErrorAction SilentlyContinue) | Should -BeTrue
    }
}

Describe 'CA-1 CA-2 CA-3 CA-4 CA-6 the rows of every group' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -NoNet
        Use-FixedNow
    }
    AfterEach { Stop-Case }

    It 'CA-1 <Group> offers exactly the rows of its table, in order, with sink, path, description and process names' -ForEach $script:AppGroups {
        Initialize-AppFixture $Group
        & $Group
        (Show (Format-Calls)) | Should -Be (Show (Get-ExpectedAppRows $Group))
    }

    It 'CA-1 <Group> offers the same rows in a real run and in a preview' -ForEach $script:AppGroups {
        Initialize-AppFixture $Group
        $script:SweeprDryRunMode = $true
        & $Group
        $preview = Show (Format-Calls)
        $script:Calls.Clear()
        $script:SweeprDryRunMode = $false
        & $Group
        (Show (Format-Calls)) | Should -Be $preview
    }

    It 'CD-4 <Group> writes nothing to the pipeline, also when every sink writes a value, and throws nothing' -ForEach $script:AppGroups {
        Initialize-AppFixture $Group
        $script:SinkLeak = $true
        { & $Group } | Should -Not -Throw
        (Invoke-Captured { & $Group }).Count | Should -Be 0
    }

    It 'CD-23 calls no sink for a folder that is missing: no Test-Path before it' {
        Mock Test-Path { throw 'Test-Path must not run for a row' }
        Clear-SwAdobeCaches
        Clear-SwOneDriveCache
        Clear-SwGamePlatformCaches
        @(Get-Calls 'Clear-SwDirectoryContents').Count | Should -Be 11
        @(Get-Calls 'Remove-SwOldFiles').Count | Should -Be 1
    }

    It 'CD-4 a sink that throws for the first Adobe row does not stop the second' {
        Mock Clear-SwDirectoryContents {
            Add-Call 'Clear-SwDirectoryContents' @{ Path = $Path; Description = $Description }
            if ($Path -like '*Media Cache Files') { throw 'boom of the first row' }
        }
        { Clear-SwAdobeCaches } | Should -Not -Throw
        (Show (Format-Calls)) | Should -Be (Show (Get-ExpectedAppRows 'Clear-SwAdobeCaches'))
    }

    It 'CD-4 an owner-guarded row that throws for Wef does not stop the Outlook row and the Office temp files' {
        Initialize-AppFixture 'Clear-SwOfficeCache'
        Mock Clear-SwAppCache {
            Add-Call 'Clear-SwAppCache' @{ Path = $Path; Description = $Description; Processes = @($Processes) }
            if ($Path -like '*Wef') { throw 'boom of Wef' }
        }
        { Clear-SwOfficeCache } | Should -Not -Throw
        (Show (Format-Calls)) | Should -Be (Show (Get-ExpectedAppRows 'Clear-SwOfficeCache'))
    }

    It 'CA-2 A03 scans the four Office bases once each, in order, for direct *.tmp files older than seven days, with the standard budget' {
        Initialize-AppFixture 'Clear-SwOfficeCache'
        Clear-SwOfficeCache
        $script:ScanCalls.Count | Should -Be 4
        @($script:ScanCalls | ForEach-Object { Fold $_.Root }) | Should -Be @((Get-OfficeBases | ForEach-Object { Fold $_ }))
        foreach ($call in $script:ScanCalls) {
            $call.Filter | Should -Be '*.tmp'
            $call.NoRecurse | Should -BeTrue
            $call.HasOlderThan | Should -BeTrue
            $call.OlderThan | Should -Be $script:FixedNow.AddDays(-7)
            $call.HasTimeout | Should -BeFalse
        }
        $script:DateCalls | Should -Be 1 -Because 'Get-Date is read once for the call'
    }

    It 'CA-2 A03 hands one list to one Remove-SwItems with a condition that asks Test-SwCacheOwnerIdle for the five Office programs afresh at every call' {
        Initialize-AppFixture 'Clear-SwOfficeCache'
        $script:IdleNames = [System.Collections.Generic.List[string]]::new()
        $script:IdleAnswer = $true
        Mock Test-SwCacheOwnerIdle { $script:IdleNames.Add((@($Names) -join ',')); $script:IdleAnswer }
        Clear-SwOfficeCache
        $rows = @(Get-Rows 'Remove-SwItems' 'Office temp files')
        $rows.Count | Should -Be 1
        $block = $rows[0].CanRemove
        $block | Should -BeOfType [scriptblock]
        $first = @(& $block)
        $first.Count | Should -Be 1
        $first[0] | Should -BeOfType [bool]
        $first[0] | Should -BeTrue
        $script:IdleAnswer = $false
        $second = @(& $block)
        $second.Count | Should -Be 1
        $second[0] | Should -BeFalse
        $script:IdleNames.Count | Should -Be 2 -Because 'every evaluation asks the probe again'
        foreach ($names in $script:IdleNames) { $names | Should -Be 'WINWORD,EXCEL,POWERPNT,OUTLOOK,ONENOTE' }
    }

    It 'CA-2 A03 calls Remove-SwItems not at all when no base has a file' {
        Use-ScanSpy
        Clear-SwOfficeCache
        @(Get-Calls 'Remove-SwItems').Count | Should -Be 0
    }

    It 'CA-2 CD-31 A03 offers nothing of an incomplete base, notes "incomplete scan" for the row and still offers the files of the other bases' {
        Initialize-AppFixture 'Clear-SwOfficeCache'
        $script:ScanAnswers[(P $script:Roam 'Microsoft' 'Templates')] = @{ Files = @(); Complete = $false }
        Clear-SwOfficeCache
        $rows = @(Get-Rows 'Remove-SwItems' 'Office temp files')
        $rows.Count | Should -Be 1
        @($rows[0].Paths | ForEach-Object { Fold $_ }) | Should -Be @((Fold (P $script:Roam 'Microsoft' 'Excel' 'e.tmp')))
        $note = @(Get-NotMeasuredFor 'Office temp files')
        $note.Count | Should -Be 1
        $note[0].Reason | Should -Be 'incomplete scan'
    }

    It 'CA-2 gives the rows A01 and A02 the owner check, in a preview and in a real run, and never a plain content sink' {
        Initialize-AppFixture 'Clear-SwOfficeCache'
        Clear-SwOfficeCache
        @(Get-Calls 'Clear-SwDirectoryContents').Count | Should -Be 0
        @(Get-Calls 'Clear-SwAppCache').Count | Should -Be 2
    }

    It 'CA-2 CA-4 chooses no Office folder that holds user content: OfficeFileCache, RoamCache, Recent and Templates themselves' {
        Initialize-AppFixture 'Clear-SwOfficeCache'
        Clear-SwOfficeCache
        $paths = @(Get-CallPaths) + @(Get-ScanRoots)
        foreach ($forbidden in (P $script:Local 'Microsoft' 'Office' '16.0' 'OfficeFileCache'), (P $script:Local 'Microsoft' 'Office' 'RoamCache'), (P $script:Roam 'Microsoft' 'Office' 'Recent'), (P $script:Local 'Microsoft' 'Outlook')) {
            @($paths | Where-Object { (Fold $_) -eq (Fold $forbidden) }).Count | Should -Be 0 -Because $forbidden
        }
        foreach ($call in @(Get-Calls 'Remove-SwItems')) {
            foreach ($path in @($call.Paths)) { [System.IO.Path]::GetExtension($path) | Should -Be '.tmp' }
        }
    }

    It 'CA-3 A04 gives only the logs of OneDrive setup to Remove-SwOldFiles with 7 days and the filter *, and never OneDrive\logs' {
        Clear-SwOneDriveCache
        $rows = @(Get-Calls 'Remove-SwOldFiles')
        $rows.Count | Should -Be 1
        $rows[0].DaysOld | Should -Be 7
        $rows[0].Filter | Should -Be '*'
        Test-AnyUnder @($rows[0].Path) (P $script:Local 'Microsoft' 'OneDrive' 'logs') | Should -BeFalse
        (Fold $rows[0].Path) | Should -Be (Fold (P $script:Local 'Microsoft' 'OneDrive' 'setup' 'logs'))
    }

    It 'CA-3 A06 scans DriveFS once for direct *.tmp files older than seven days and keeps the owner check for GoogleDriveFS' {
        Initialize-AppFixture 'Clear-SwGoogleDriveCache'
        $script:IdleNames = [System.Collections.Generic.List[string]]::new()
        Mock Test-SwCacheOwnerIdle { $script:IdleNames.Add((@($Names) -join ',')); $true }
        Clear-SwGoogleDriveCache
        $script:ScanCalls.Count | Should -Be 1
        $call = $script:ScanCalls[0]
        (Fold $call.Root) | Should -Be (Fold (P $script:Local 'Google' 'DriveFS'))
        $call.Filter | Should -Be '*.tmp'
        $call.NoRecurse | Should -BeTrue
        $call.OlderThan | Should -Be $script:FixedNow.AddDays(-7)
        $script:DateCalls | Should -Be 1
        $rows = @(Get-Rows 'Remove-SwItems' 'Google Drive temp')
        $rows.Count | Should -Be 1
        $answer = @(& $rows[0].CanRemove)
        $answer.Count | Should -Be 1
        $answer[0] | Should -BeTrue
        $script:IdleNames[0] | Should -Be 'GoogleDriveFS'
    }

    It 'CA-3 CD-31 A06 removes nothing, remembers nothing and notes "incomplete scan" when the DriveFS search is incomplete' {
        Use-ScanSpy
        $script:ScanAnswers[(P $script:Local 'Google' 'DriveFS')] = @{ Files = @(); Complete = $false }
        Clear-SwGoogleDriveCache
        @(Get-Calls 'Remove-SwItems').Count | Should -Be 0
        $note = @(Get-NotMeasuredFor 'Google Drive temp')
        $note.Count | Should -Be 1
        $note[0].Reason | Should -Be 'incomplete scan'
        @(Get-Calls 'Remove-SwOldFiles').Count | Should -Be 1 -Because 'the log row does not depend on the search'
    }

    It 'CA-4 chooses only the two Adobe folders: never Common itself, the Adobe folder in LOCALAPPDATA or a folder named Team Projects Cache' {
        Clear-SwAdobeCaches
        $paths = @(Get-CallPaths)
        $paths.Count | Should -Be 2
        foreach ($forbidden in (P $script:Roam 'Adobe' 'Common'), (P $script:Roam 'Adobe'), (P $script:Local 'Adobe'), (P $script:Roam 'Adobe' 'Common' 'Team Projects Cache'), (P $script:Roam 'Adobe' 'Common' 'Team Projects Cache Backup')) {
            @($paths | Where-Object { (Fold $_) -eq (Fold $forbidden) }).Count | Should -Be 0 -Because $forbidden
        }
        foreach ($path in $paths) { [System.IO.Path]::GetFileName($path) | Should -Not -Be 'Team Projects Cache' }
    }

    It 'CA-6 gives every launcher row the plain content sink with the description of the table, and no row for steamapps, games or userdata' {
        Clear-SwGamePlatformCaches
        @(Get-Calls 'Clear-SwDirectoryContents').Count | Should -Be 9
        @(Get-Calls 'Clear-SwAppCache').Count | Should -Be 0
        @(Get-Rows 'Clear-SwDirectoryContents' 'Epic Games webcache').Count | Should -Be 1
        foreach ($path in @(Get-CallPaths)) { (Fold $path) | Should -Not -Match 'steamapps|userdata|\\common\\|\\games\\|saved games' }
    }

    It 'CA-6 does not read ProgramFiles(x86): a Steam folder there is not offered' {
        $steam = P $script:Work 'pf86' 'Steam'
        $null = New-File (P $steam 'appcache' 'httpcache' 'x') 3
        Set-Env 'ProgramFiles(x86)' (P $script:Work 'pf86')
        try {
            Clear-SwGamePlatformCaches
            Test-AnyUnder @(Get-CallPaths) $steam | Should -BeFalse
            Test-AnyUnder @(Get-CallPaths) (P $script:Work 'pf86') | Should -BeFalse
        }
        finally { Set-Env 'ProgramFiles(x86)' $null }
    }
}

Describe 'CD-3 target paths of the application rows' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -NoNet
        Use-FixedNow
    }
    AfterEach { Stop-Case }

    It 'CD-3 calls no sink for the OneDrive row when LOCALAPPDATA is <Label>' -ForEach $script:BadValues {
        Set-Env 'LOCALAPPDATA' $Value
        { Clear-SwOneDriveCache } | Should -Not -Throw
        $script:Calls.Count | Should -Be 0
    }

    It 'CD-3 calls no sink or scan for the group when <Variable> is the root of a drive' -ForEach $script:RootCases {
        Set-Env $Variable ([System.IO.Path]::GetPathRoot($script:Work))
        & $Group
        $script:Calls.Count | Should -Be 0
    }

    It 'CD-3 leaves out the GOG log row when PROGRAMDATA is not usable and keeps the other eight launcher rows' -ForEach @(
        @{ Value = $null }, @{ Value = '  ' }, @{ Value = 'programdata' }, @{ Value = '__ROOT__' }) {
        $effective = if ($Value -eq '__ROOT__') { [System.IO.Path]::GetPathRoot($script:Work) } else { $Value }
        Set-Env 'PROGRAMDATA' $effective
        Clear-SwGamePlatformCaches
        @(Get-Calls 'Clear-SwDirectoryContents').Count | Should -Be 8
        @(Get-Rows 'Clear-SwDirectoryContents' 'GOG Galaxy logs').Count | Should -Be 0
    }

    It 'CD-3 drops the Office temp scans when APPDATA is not complete and keeps the rows of LOCALAPPDATA' {
        Use-ScanSpy
        Set-Env 'APPDATA' 'Roaming'
        Clear-SwOfficeCache
        $script:ScanCalls.Count | Should -Be 0
        @(Get-Calls 'Clear-SwAppCache').Count | Should -Be 2
    }

    It 'CD-3 trims the value and joins with one separator, also for a base that ends with a separator' {
        Set-Env 'APPDATA' ('  ' + $script:Roam + $script:Sep + ' ')
        Clear-SwAdobeCaches
        @(Get-Calls 'Clear-SwDirectoryContents')[0].Path | Should -BeExactly ($script:Roam + $script:Sep + 'Adobe' + $script:Sep + 'Common' + $script:Sep + 'Media Cache Files')
    }

    It 'CD-3 reads names literally: a base with brackets goes to the sink with its brackets' {
        $bracket = New-Dir (P $script:Work 'Ex [1]' 'Roaming')
        $null = New-Dir (P $script:Work 'Ex 1' 'Roaming')
        Set-Env 'APPDATA' $bracket
        Clear-SwAdobeCaches
        foreach ($path in @(Get-CallPaths)) { Test-SameOrUnder $path $bracket | Should -BeTrue -Because $path }
    }

    It 'CD-3 gives an error nowhere when every variable is missing, for every group' {
        foreach ($name in 'USERPROFILE', 'LOCALAPPDATA', 'APPDATA', 'PROGRAMDATA') { Set-Env $name $null }
        foreach ($group in $script:AppGroupOrder) {
            { & $group } | Should -Not -Throw -Because $group
            (Invoke-Captured { & $group }).Count | Should -Be 0 -Because $group
        }
        $script:Calls.Count | Should -Be 0
    }

    It 'CD-2 gives the same rows of <Group> under Stop, Continue and SilentlyContinue' -ForEach $script:AppGroups {
        Initialize-AppFixture $Group
        $seen = @{}
        foreach ($preference in 'Stop', 'Continue', 'SilentlyContinue') {
            $ErrorActionPreference = $preference
            $script:Calls.Clear()
            & $Group
            $seen[$preference] = Show (Format-Calls)
        }
        $ErrorActionPreference = 'Stop'
        $seen['Continue'] | Should -Be $seen['Stop']
        $seen['SilentlyContinue'] | Should -Be $seen['Stop']
    }
}

Describe 'CA-2 CA-3 CA-4 end to end with the real removal helpers' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -Real -NoNet
    }
    AfterEach { Stop-Case }

    It 'CA-2 lists in a preview only the old *.tmp files directly in the four Office bases: a.tmp (10 days) yes, b.tmp (1 day), c.docx (30 days) and a folder d.tmp no' {
        $a = New-OldFile (P $script:Roam 'Microsoft' 'Templates' 'a.tmp') 10
        $null = New-OldFile (P $script:Roam 'Microsoft' 'Word' 'b.tmp') 1
        $null = New-OldFile (P $script:Roam 'Microsoft' 'Word' 'c.docx') 30
        $null = New-File (P $script:Roam 'Microsoft' 'Excel' 'd.tmp' 'inner.tmp') 3
        $script:SweeprDryRunMode = $true
        Use-Collectors
        Clear-SwOfficeCache
        @($script:DryRunCollector | ForEach-Object { Fold $_.Path }) | Should -Be @((Fold $a))
    }

    It 'CA-2 lists nothing, not even a.tmp, when the owner check says "not idle"' {
        $null = New-OldFile (P $script:Roam 'Microsoft' 'Templates' 'a.tmp') 10
        Mock Test-SwCacheOwnerIdle { $false }
        $script:SweeprDryRunMode = $true
        Use-Collectors
        Clear-SwOfficeCache
        $script:DryRunCollector.Count | Should -Be 0
    }

    It 'CA-2 chooses nothing and counts nothing when the process list cannot be read (the real owner check)' {
        $path = New-OldFile (P $script:Roam 'Microsoft' 'Templates' 'a.tmp') 10
        $wef = New-File (P $script:Local 'Microsoft' 'Office' '16.0' 'Wef' 'x.bin') 3
        Mock Get-Process { throw 'unavailable' }
        $script:SweeprDryRunMode = $false
        Clear-SwOfficeCache
        $script:FilesCleaned | Should -Be 0
        [System.IO.File]::Exists($path) | Should -BeTrue
        [System.IO.File]::Exists($wef) | Should -BeTrue
    }

    It 'CA-2 removes in a real run the old *.tmp files and keeps the others, a recent *.tmp and a document with another extension' {
        $old = New-OldFile (P $script:Roam 'Microsoft' 'Templates' 'a.tmp') 10
        $new = New-OldFile (P $script:Roam 'Microsoft' 'Word' 'b.tmp') 1
        $doc = New-OldFile (P $script:Roam 'Microsoft' 'Word' 'c.docx') 30
        $normal = New-OldFile (P $script:Roam 'Microsoft' 'Templates' 'Normal.dotm') 400
        $script:SweeprDryRunMode = $false
        Clear-SwOfficeCache
        [System.IO.File]::Exists($old) | Should -BeFalse
        foreach ($keep in $new, $doc, $normal) { [System.IO.File]::Exists($keep) | Should -BeTrue -Because $keep }
        $script:FilesCleaned | Should -Be 1
    }

    It 'CA-2 removes the children of Wef except a folder with a protected descendant, which is skipped as a whole with one SKIPPED line' {
        $plain = New-File (P $script:Local 'Microsoft' 'Office' '16.0' 'Wef' 'addin1' 'manifest.xml') 5
        $guarded = New-File (P $script:Local 'Microsoft' 'Office' '16.0' 'Wef' 'addin2' 'Local Storage' 'leveldb' 'x.ldb') 5
        $script:SweeprDryRunMode = $false
        Clear-SwOfficeCache
        [System.IO.File]::Exists($plain) | Should -BeFalse
        [System.IO.File]::Exists($guarded) | Should -BeTrue
        @(Get-OpsOf 'SKIPPED').Count | Should -Be 1
    }

    It 'CA-3 lists only the old file directly in setup\logs: old.log (10 days) yes, new.log (1 day) and x\old.log (30 days) no' {
        $old = New-OldFile (P $script:Local 'Microsoft' 'OneDrive' 'setup' 'logs' 'old.log') 10
        $null = New-OldFile (P $script:Local 'Microsoft' 'OneDrive' 'setup' 'logs' 'new.log') 1
        $null = New-OldFile (P $script:Local 'Microsoft' 'OneDrive' 'setup' 'logs' 'x' 'old.log') 30
        $script:SweeprDryRunMode = $true
        Use-Collectors
        Clear-SwOneDriveCache
        @($script:DryRunCollector | ForEach-Object { Fold $_.Path }) | Should -Be @((Fold $old))
        @($script:DryRunCollector)[0].Description | Should -Be 'OneDrive logs (>7d old)'
    }

    It 'CA-3 never offers OneDrive\logs: an old file there stays, also in a real run' {
        $main = New-OldFile (P $script:Local 'Microsoft' 'OneDrive' 'logs' 'main.log') 100
        $null = New-OldFile (P $script:Local 'Microsoft' 'OneDrive' 'setup' 'logs' 'old.log') 10
        $script:SweeprDryRunMode = $false
        Clear-SwOneDriveCache
        [System.IO.File]::Exists($main) | Should -BeTrue
        $script:FilesCleaned | Should -Be 1
    }

    It 'CA-3 lists the old Google Drive logs and the old DriveFS *.tmp files, and keeps the rest of DriveFS' {
        $log = New-OldFile (P $script:Local 'Google' 'DriveFS' 'Logs' 'drive.log') 10
        $tmp = New-OldFile (P $script:Local 'Google' 'DriveFS' 'upload.tmp') 10
        $fresh = New-OldFile (P $script:Local 'Google' 'DriveFS' 'fresh.tmp') 1
        $data = New-OldFile (P $script:Local 'Google' 'DriveFS' 'metadata_sqlite_db') 300
        $folder = New-File (P $script:Local 'Google' 'DriveFS' 'dir.tmp' 'inner') 3
        $script:SweeprDryRunMode = $true
        Use-Collectors
        Clear-SwGoogleDriveCache
        @($script:DryRunCollector | ForEach-Object { Fold $_.Path } | Sort-Object) | Should -Be @((Fold $log), (Fold $tmp) | Sort-Object)
        foreach ($keep in $fresh, $data, $folder) { [System.IO.File]::Exists($keep) | Should -BeTrue -Because $keep }
    }

    It 'CA-3 lists nothing of the DriveFS *.tmp files while GoogleDriveFS runs' {
        $null = New-OldFile (P $script:Local 'Google' 'DriveFS' 'upload.tmp') 10
        Mock Test-SwCacheOwnerIdle { $false }
        $script:SweeprDryRunMode = $true
        Use-Collectors
        Clear-SwGoogleDriveCache
        @($script:DryRunCollector | Where-Object { $_.Description -like 'Google Drive temp*' }).Count | Should -Be 0
    }

    It 'CA-4 keeps Team Projects Cache in a preview and a real run, while Media Cache Files and Peak Files go' {
        $clip = New-File (P $script:Roam 'Adobe' 'Common' 'Media Cache Files' 'clip.cache') 10
        $peak = New-File (P $script:Roam 'Adobe' 'Common' 'Peak Files' 'p.pk') 10
        $project = New-File (P $script:Roam 'Adobe' 'Common' 'Team Projects Cache' 'project.db') 10
        $backup = New-File (P $script:Roam 'Adobe' 'Common' 'Team Projects Cache Backup' 'entry') 10
        $script:SweeprDryRunMode = $true
        Use-Collectors
        Clear-SwAdobeCaches
        @($script:DryRunCollector | ForEach-Object { Fold $_.Path } | Sort-Object) | Should -Be @((Fold $clip), (Fold $peak) | Sort-Object)
        Test-AnyUnder @($script:DryRunCollector | ForEach-Object { $_.Path }) (P $script:Roam 'Adobe' 'Common' 'Team Projects Cache') | Should -BeFalse
        $script:SweeprDryRunMode = $false
        Clear-SwAdobeCaches
        [System.IO.File]::Exists($clip) | Should -BeFalse
        [System.IO.File]::Exists($peak) | Should -BeFalse
        [System.IO.File]::Exists($project) | Should -BeTrue
        [System.IO.File]::Exists($backup) | Should -BeTrue
    }

    It 'CA-6 empties the launcher folders and keeps the folders themselves and a game library beside them' {
        $web = New-File (P $script:Local 'EpicGamesLauncher' 'Saved' 'webcache' 'a.bin') 10
        $game = New-File (P $script:Local 'EpicGamesLauncher' 'Saved' 'Config' 'settings.ini') 10
        $steam = New-File (P $script:Profile 'steamapps' 'common' 'Game' 'game.exe') 10
        $gog = New-File (P $script:ProgramData 'GOG.com' 'Galaxy' 'logs' 'galaxy.log') 10
        $script:SweeprDryRunMode = $false
        Clear-SwGamePlatformCaches
        [System.IO.File]::Exists($web) | Should -BeFalse
        [System.IO.File]::Exists($gog) | Should -BeFalse
        [System.IO.Directory]::Exists((P $script:Local 'EpicGamesLauncher' 'Saved' 'webcache')) | Should -BeTrue
        [System.IO.File]::Exists($game) | Should -BeTrue
        [System.IO.File]::Exists($steam) | Should -BeTrue
    }
}

Describe 'CA-13 CA-12 the list and the count of the whole section agree' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -Real -NoNet
        $null = New-File (P $script:Roam 'Adobe' 'Common' 'Media Cache Files' 'clip.cache') 10
        $null = New-File (P $script:Roam 'Adobe' 'Common' 'Peak Files' 'p.pk') 10
        $null = New-File (P $script:Local 'EpicGamesLauncher' 'Saved' 'webcache' 'a.bin') 10
        $null = New-File (P $script:Local 'Electronic Arts' 'EA Desktop' 'cache' 'b.bin') 10
        $null = New-File (P $script:Local 'GOG.com' 'Galaxy' 'webcache' 'c.bin') 10
        $null = New-File (P $script:ProgramData 'GOG.com' 'Galaxy' 'logs' 'd.log') 10
        $null = New-File (P $script:Roam 'Battle.net' 'Cache' 'e.bin') 10
        $null = New-OldFile (P $script:Local 'Microsoft' 'OneDrive' 'setup' 'logs' 'old.log') 10
        $null = New-OldFile (P $script:Local 'Google' 'DriveFS' 'Logs' 'old.log') 10
        $null = New-OldFile (P $script:Local 'Google' 'DriveFS' 'up.tmp') 10
        $null = New-OldFile (P $script:Roam 'Microsoft' 'Templates' 'o.tmp') 10
        $null = New-File (P $script:Local 'Microsoft' 'Office' '16.0' 'Wef' 'w1' 'f.bin') 10
        $null = New-File (P $script:Local 'Microsoft' 'Outlook' 'Offline Address Books' 'oab.bin') 10
        $null = New-OldFile (P $script:Profile 'Videos' 'Medal' 'clip.mp4') 120
        $null = New-OldFile (P $script:Local 'FortniteGame' 'Saved' 'Demos' 'replay.bin') 120
    }
    AfterEach { Stop-Case }

    It 'CA-13 gives one counted file for every listed line: FilesCleaned of a real run equals the lines of the preview' {
        $script:SweeprDryRunMode = $true
        Use-Collectors
        Invoke-SwAppCleanup -IncludeGameMedia
        $lines = $script:DryRunCollector.Count
        $lines | Should -BeGreaterThan 10
        $script:SweeprDryRunMode = $false
        $script:FilesCleaned = 0
        Invoke-SwAppCleanup -IncludeGameMedia
        $script:FilesCleaned | Should -Be $lines
    }

    It 'CA-12 CD-6 writes no counter besides the helpers: OwnerCleanups stays 0 and a preview changes nothing on disk and writes no log line' {
        $before = @((Get-Listing $script:Profile), (Get-Listing $script:ProgramData))
        $script:SweeprDryRunMode = $true
        Use-Collectors
        Invoke-SwAppCleanup -IncludeGameMedia
        [int]$script:OwnerCleanups | Should -Be 0
        Same-Listing (Get-Listing $script:Profile) $before[0] | Should -BeTrue
        Same-Listing (Get-Listing $script:ProgramData) $before[1] | Should -BeTrue
        $script:Ops.Count | Should -Be 0
    }

    It 'CA-12 counts one item per call of a helper: TotalItems of a real run is the number of helper calls that removed something' {
        $script:SweeprDryRunMode = $false
        Invoke-SwAppCleanup -IncludeGameMedia
        $script:TotalItems | Should -BeGreaterThan 0
        $script:TotalItems | Should -BeLessOrEqual $script:FilesCleaned
    }
}

Describe 'CD-1 loading apps.ps1' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        $script:SavedEnvLoad = Save-Env $script:EnvNames
        $script:Work = New-Work
        foreach ($name in 'USERPROFILE', 'HOME', 'LOCALAPPDATA', 'APPDATA', 'TEMP', 'PROGRAMDATA') { Set-Env $name (New-Dir (P $script:Work $name)) }
        $script:ChildEnv = @{ USERPROFILE = (P $script:Work 'USERPROFILE'); HOME = (P $script:Work 'HOME'); LOCALAPPDATA = (P $script:Work 'LOCALAPPDATA')
            APPDATA = (P $script:Work 'APPDATA'); TEMP = (P $script:Work 'TEMP'); PROGRAMDATA = (P $script:Work 'PROGRAMDATA'); SWEEPR_NO_OPLOG = '1' }
        $script:LoadApps = '. ' + (ConvertTo-TestLiteral $script:AppsFile)
        $script:LoadDevToo = '. ' + (ConvertTo-TestLiteral (P $script:CleanDir 'dev.ps1'))
    }
    AfterEach { Restore-Env $script:SavedEnvLoad }

    It 'CD-1 writes nothing to the output or the error stream when apps.ps1 is loaded, with or without the core modules before, and defines the section function' {
        foreach ($withCore in $true, $false) {
            $lines = [System.Collections.Generic.List[string]]::new()
            if ($withCore) { foreach ($name in 'base.ps1', 'log.ps1', 'file_ops.ps1') { $lines.Add('. ' + (ConvertTo-TestLiteral (P $script:CoreDir $name))) } }
            $lines.Add($script:LoadApps)
            $lines.Add('foreach ($n in ''Invoke-SwAppCleanup'', ''Clear-SwGameMedia'', ''Clear-SwOfficeCache'', ''Clear-SwAppCache'') { if (Get-Command $n -CommandType Function -ErrorAction SilentlyContinue) { $n } }')
            $result = Invoke-ChildPowerShell -Script ($lines -join "`n") -Environment $script:ChildEnv
            @(($result.Out -split "`r?`n") | Where-Object { $_ -ne '' }) | Should -Be @('Invoke-SwAppCleanup', 'Clear-SwGameMedia', 'Clear-SwOfficeCache', 'Clear-SwAppCache')
            (Get-ChildStderr $result.Err) | Should -Be ''
        }
    }

    It 'CD-1 loads together with dev.ps1 into one scope in either order, as the preview module does, without a message' {
        foreach ($order in @($script:LoadDevToo, $script:LoadApps), @($script:LoadApps, $script:LoadDevToo)) {
            $script = ($order -join "`n") + "`n" + 'foreach ($n in ''Invoke-SwAppCleanup'', ''Invoke-SwDevCleanup'', ''Get-SwBoundedFileScan'') { if (Get-Command $n -CommandType Function -ErrorAction SilentlyContinue) { $n } }'
            $result = Invoke-ChildPowerShell -Script $script -Environment $script:ChildEnv
            @(($result.Out -split "`r?`n") | Where-Object { $_ -ne '' }) | Should -Be @('Invoke-SwAppCleanup', 'Invoke-SwDevCleanup', 'Get-SwBoundedFileScan')
            (Get-ChildStderr $result.Err) | Should -Be ''
        }
    }

    It 'CD-1 changes nothing on a second load, also after the marker $false is set again: a replaced function stays replaced, and with the marker $false it is defined again' {
        $extra = $script:LoadApps + "`n" + 'function Clear-SwAdobeCaches { ''sentinel'' }' + "`n" + $script:LoadApps + "`n" +
        '(Get-Command Clear-SwAdobeCaches -CommandType Function).ScriptBlock.ToString().Trim()' + "`n" +
        '$script:SWEEPR_CLEAN_APPS_LOADED = $false' + "`n" + $script:LoadApps + "`n" +
        'if ((Get-Command Clear-SwAdobeCaches -CommandType Function).ScriptBlock.ToString() -match ''sentinel'') { ''still sentinel'' } else { ''redefined'' }'
        $result = Invoke-ChildPowerShell -Script $extra -Environment $script:ChildEnv
        @(($result.Out -split "`r?`n") | Where-Object { $_ -ne '' }) | Should -Be @('''sentinel''', 'redefined')
    }

    It 'CD-1 keeps the marker of apps.ps1 apart from the marker of dev.ps1: both are $true after both loads' {
        $script = $script:LoadDevToo + "`n" + $script:LoadApps + "`n" + '[string]$script:SWEEPR_CLEAN_DEV_LOADED + '':'' + [string]$script:SWEEPR_CLEAN_APPS_LOADED'
        $result = Invoke-ChildPowerShell -Script $script -Environment $script:ChildEnv
        @(($result.Out -split "`r?`n") | Where-Object { $_ -ne '' }) | Should -Be @('True:True')
    }

    It 'CD-1 does not touch the variables of dev.ps1 and the counters: they keep the values a test set before the load' {
        $script = $script:LoadDevToo + "`n" + '$script:SweeprSkipExternalTools = $true; $script:TotalSizeCleaned = 7; $script:OwnerCleanups = 3' + "`n" + $script:LoadApps + "`n" +
        '[string]$script:SweeprSkipExternalTools + '':'' + $script:TotalSizeCleaned + '':'' + $script:OwnerCleanups'
        $result = Invoke-ChildPowerShell -Script $script -Environment $script:ChildEnv
        @(($result.Out -split "`r?`n") | Where-Object { $_ -ne '' }) | Should -Be @('True:7:3')
    }

    It 'CD-1 creates no variable in the scope of the caller, and no scriptDir, when dev.ps1 and apps.ps1 are loaded one after the other into one function scope' {
        $extra = 'function Test-Scope {' + "`n" + '. ' + (ConvertTo-TestLiteral (P $script:CleanDir 'cache_guard.ps1')) + "`n" +
        '$names0 = @(Get-Variable -Scope 0 | ForEach-Object { $_.Name }); $names0 += ''names0''' + "`n" +
        $script:LoadDevToo + "`n" + $script:LoadApps + "`n" +
        '$added = @(Get-Variable -Scope 0 | ForEach-Object { $_.Name } | Where-Object { $names0 -notcontains $_ -and $_ -ne ''added'' })' + "`n" +
        '''added=['' + ($added -join '','') + '']''' + "`n" + '}' + "`n" + 'Test-Scope'
        $result = Invoke-ChildPowerShell -Script $extra -Environment $script:ChildEnv
        @(($result.Out -split "`r?`n") | Where-Object { $_ -ne '' }) | Should -Be @('added=[]')
    }

    It 'CD-1 starts no process, creates nothing and asks neither registry nor network when apps.ps1 loads' {
        $watched = @('USERPROFILE', 'LOCALAPPDATA', 'APPDATA', 'TEMP', 'PROGRAMDATA')
        $before = @($watched | ForEach-Object { (Get-Listing (P $script:Work $_)) -join '|' })
        $extra = 'function Start-Process { ''START-PROCESS'' }; function Invoke-WebRequest { ''WEB'' }; function Get-ItemProperty { ''REGISTRY'' }; function Get-AppxPackage { ''APPX'' }' + "`n" +
        $script:LoadApps + "`n" + '''done'''
        $result = Invoke-ChildPowerShell -Script $extra -Environment $script:ChildEnv
        @(($result.Out -split "`r?`n") | Where-Object { $_ -ne '' }) | Should -Be @('done')
        $after = @($watched | ForEach-Object { (Get-Listing (P $script:Work $_)) -join '|' })
        ($after -join "`n") | Should -BeExactly ($before -join "`n")
    }
}

Describe 'Old names of the application functions are forwarding functions' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -NoNet
    }
    AfterEach { Stop-Case }

    It 'Old name <Old> is a function with no parameters and no CmdletBinding, not an alias, and calls <New> once' -ForEach $script:Forwards {
        (Get-Command -Name $Old -ErrorAction Stop).CommandType | Should -Be 'Function'
        @(Get-Alias -Name $Old -ErrorAction SilentlyContinue).Count | Should -Be 0
        (Get-Command -Name $Old).CmdletBinding | Should -BeFalse
        (Get-ParamCount $Old) | Should -Be 0
        $script:Forwarded = [System.Collections.Generic.List[string]]::new()
        Mock $New ([scriptblock]::Create('$script:Forwarded.Add(' + [char]39 + $New + [char]39 + ')'))
        (Invoke-Captured { & $Old }).Count | Should -Be 0
        $script:Forwarded.Count | Should -Be 1
        $script:Forwarded[0] | Should -Be $New
    }

    It 'Old name CA-14 Invoke-AppCleanup keeps the switches IncludeOrphaned and IncludeGameMedia and GameMediaDaysOld (default 90)' {
        (Get-ParamLine 'Invoke-AppCleanup' 'IncludeOrphaned') | Should -BeLike 'IncludeOrphaned|System.Management.Automation.SwitchParameter|*'
        (Get-ParamLine 'Invoke-AppCleanup' 'IncludeGameMedia') | Should -BeLike 'IncludeGameMedia|System.Management.Automation.SwitchParameter|*'
        (Get-ParamLine 'Invoke-AppCleanup' 'GameMediaDaysOld') | Should -BeLike 'GameMediaDaysOld|System.Int32|*|mandatory=False|default=90'
        (Get-ParamCount 'Invoke-AppCleanup') | Should -Be 3
        (Get-Command -Name Invoke-AppCleanup).CmdletBinding | Should -BeFalse
    }

    It 'Old name Invoke-AppCleanup calls Invoke-SwAppCleanup once with the media switch and the days, and ignores -IncludeOrphaned' {
        $script:Seen = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-SwAppCleanup { $script:Seen.Add([pscustomobject]@{ Media = [bool]$IncludeGameMedia; Days = $GameMediaDaysOld; Bound = @($PesterBoundParameters.Keys | Sort-Object) }) }
        Invoke-AppCleanup -IncludeOrphaned -IncludeGameMedia -GameMediaDaysOld 30
        Invoke-AppCleanup
        $script:Seen.Count | Should -Be 2
        $script:Seen[0].Media | Should -BeTrue
        $script:Seen[0].Days | Should -Be 30
        $script:Seen[0].Bound | Should -Not -Contain 'IncludeOrphaned'
        $script:Seen[1].Media | Should -BeFalse
    }

    It 'Old name Clear-GameMediaFiles keeps DaysOld (int, position 0, default 90) and calls Clear-SwGameMedia -DaysOld once' {
        (Get-ParamLine 'Clear-GameMediaFiles' 'DaysOld') | Should -Be 'DaysOld|System.Int32|pos=0|mandatory=False|default=90'
        (Get-ParamCount 'Clear-GameMediaFiles') | Should -Be 1
        $script:Seen = [System.Collections.Generic.List[object]]::new()
        Mock Clear-SwGameMedia { $script:Seen.Add($DaysOld) }
        Clear-GameMediaFiles 45
        Clear-GameMediaFiles
        @($script:Seen) | Should -Be @(45, 90)
    }
}
