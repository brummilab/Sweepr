# Sweepr - tests for Clear-SwGameMedia in lib\clean\apps.ps1, the opt-in section "Game media (>Nd old)": the title
# and the cutoff, the roots and the extension sets of the table, one removal call per file with a fresh age check,
# the folders that are never chosen, links and placeholders, incomplete searches, the preview and the old name.
#
# The rule numbers in the test names (CD-, CA-, S- and so on) number the rules and the safety invariants
# of the behavior of the developer tool and application cleanup; each rule and invariant has at least one test.
# The other files of this slice are SwCleanDevGroups, SwCleanDevLoad, SwCleanDevScan, SwCleanDevOwnerPath,
# SwCleanDevOwnerRun, SwCleanDevProcess, SwCleanDevEditors, SwCleanAppsGroups and SwCleanDevAppsSafety.
#
# Interface pinned here (lib\clean\apps.ps1, loaded after lib\clean\dev.ps1):
#   Clear-SwGameMedia [-DaysOld <int> = 90]
#       Start-SwSection "Game media (>Nd old)", one Get-SwBoundedFileScan -Root -Extensions -OlderThan per root of the
#       table, one Remove-SwItems -Paths @(<file>) -Description '<Name> (>Nd)' -CanRemove <block> per delivered file,
#       Stop-SwSection; Get-Date is read once; a negative number opens and closes the section and does nothing else
#   Old name: Clear-GameMediaFiles -DaysOld (position 0, default 90)
#
# Seams used with Mock: Get-SwBoundedFileScan (spy with answers per root, or the real search over files below $TestDrive),
# Remove-SwItems (spy; the real helper in the end-to-end cases), Get-Date (fixed, counted), Test-Path (must not be
# called), Get-SwPathSnapshot and Test-SwPathSnapshot (substitute objects), the log writers, Add-SwNotMeasured.
#
# Platform notes:
#   - On Linux the creation time of a file follows its write time, so the case for the newer of the two times is
#     marked [W], and so is the cloud placeholder case (the reparse point attribute cannot be set there).
#   - Tests marked [W] need real Windows. They are meant to fail on Linux and belong in
#     tests/linux-known-failures.txt.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    $script:BadValues = @(
        @{ Label = 'not set'; Value = $null }
        @{ Label = 'blank'; Value = '   ' }
        @{ Label = 'a relative path'; Value = 'rel/x' }
        @{ Label = 'a drive-relative path'; Value = 'C:Temp' }
    )
    # Source, description (without the days), the roots below USERPROFILE or LOCALAPPDATA, and the extension set.
    $script:Sources = @(
        @{ Name = 'NVIDIA recordings'; Roots = @('Videos/NVIDIA', 'Videos/ShadowPlay', 'Videos/GeForce Experience') }
        @{ Name = 'AMD ReLive recordings'; Roots = @('Videos/Radeon ReLive', 'Videos/AMD', 'Videos/Radeon') }
        @{ Name = 'Medal.tv clips'; Roots = @('Videos/Medal') }
        @{ Name = 'Overwolf/Outplayed recordings'; Roots = @('Videos/Overwolf', 'Videos/Outplayed') }
        @{ Name = 'Fortnite replays'; Roots = @('FortniteGame/Saved/Demos') }
        @{ Name = 'VALORANT logs'; Roots = @('VALORANT/Saved/Logs') }
        @{ Name = 'Apex Legends temp files'; Roots = @('Saved Games/Respawn/Apex/assets/temp') }
    )
    # Folders that hold personal media or replays and are never chosen (relative to USERPROFILE).
    $script:NeverFolders = @(
        @{ Folder = 'Pictures/Screenshots' }, @{ Folder = 'Videos/Screen Recordings' }, @{ Folder = 'Videos/Captures' }, @{ Folder = 'Videos/OBS' }
        @{ Folder = 'Pictures/Steam Screenshots' }, @{ Folder = 'Documents/League of Legends/Replays' }, @{ Folder = 'Documents/Rocket League/Replays' }
        @{ Folder = 'Videos' }, @{ Folder = 'Pictures' }, @{ Folder = 'Documents' }
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

    $script:MediaSet = @('.mp4', '.mkv', '.avi', '.mov', '.wmv', '.webm', '.png', '.jpg', '.jpeg', '.bmp', '.gif')
    # The twelve roots of the table with the base that builds them.
    function script:Get-MediaRoots {
        $roots = [System.Collections.Generic.List[object]]::new()
        foreach ($name in 'NVIDIA', 'ShadowPlay', 'GeForce Experience', 'Radeon ReLive', 'AMD', 'Radeon', 'Medal', 'Overwolf', 'Outplayed') {
            $roots.Add([pscustomobject]@{ Path = (P $script:Profile 'Videos' $name); Set = $true })
        }
        $roots.Add([pscustomobject]@{ Path = (P $script:Local 'FortniteGame' 'Saved' 'Demos'); Set = $false })
        $roots.Add([pscustomobject]@{ Path = (P $script:Local 'VALORANT' 'Saved' 'Logs'); Set = $false })
        $roots.Add([pscustomobject]@{ Path = (P $script:Profile 'Saved Games' 'Respawn' 'Apex' 'assets' 'temp'); Set = $false })
        $roots.ToArray()
    }
    function script:Get-SourceRoot([string]$Relative) {
        $base = $script:Profile
        if ($Relative -like 'FortniteGame*' -or $Relative -like 'VALORANT*') { $base = $script:Local }
        $path = $base
        foreach ($segment in ($Relative -split '/')) { $path = P $path $segment }
        $path
    }
    function script:Use-FixedNow {
        $script:FixedNow = [datetime]::new(2026, 6, 15, 12, 0, 0)
        $script:DateCalls = 0
        Mock Get-Date { $script:DateCalls++; $script:FixedNow }
    }
    function script:Get-MediaCalls { @(Get-Calls 'Remove-SwItems') }
    function script:Get-MediaPaths { @(Get-MediaCalls | ForEach-Object { @($_.Paths) } | ForEach-Object { Fold $_ }) }
}

AfterAll {
    Clear-TestLinks
    Restore-Env $script:RootEnv
    Restore-State $script:RootState
    [System.Environment]::CurrentDirectory = $script:RootDirectory
    try { Set-Location -LiteralPath $script:RootLocation } catch { $null = $_ }
}
Describe 'CA-8 Clear-SwGameMedia: section, cutoff and roots' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -NoNet
        Use-ScanSpy
        Use-FixedNow
    }
    AfterEach { Stop-Case }

    It 'CA-8 gives the function with the parameter DaysOld (int, default 90, position 0)' {
        Assert-Defined @('Clear-SwGameMedia')
        (Get-ParamLine 'Clear-SwGameMedia' 'DaysOld') | Should -Be 'DaysOld|System.Int32|pos=0|mandatory=False|default=90'
        (Get-ParamCount 'Clear-SwGameMedia') | Should -Be 1
    }

    It 'CA-8 opens the section with the number of days in the title, once, and closes it once: 90 by default' {
        Clear-SwGameMedia
        @($script:Sections) | Should -Be @('start:Game media (>90d old)', 'stop')
    }

    It 'CA-8 names the days that were given in the title: <Days>' -ForEach @(@{ Days = 30 }, @{ Days = 7 }, @{ Days = 0 }, @{ Days = 365 }) {
        Clear-SwGameMedia -DaysOld $Days
        @($script:Sections) | Should -Be @(('start:Game media (>' + $Days + 'd old)'), 'stop')
    }

    It 'CA-8 opens and closes the section and does nothing else for a negative number: <Days>' -ForEach @(@{ Days = -1 }, @{ Days = -90 }) {
        Clear-SwGameMedia -DaysOld $Days
        @($script:Sections) | Should -Be @(('start:Game media (>' + $Days + 'd old)'), 'stop')
        $script:ScanCalls.Count | Should -Be 0
        @(Get-MediaCalls).Count | Should -Be 0
        $script:Calls.Count | Should -Be 0
    }

    It 'CA-8 reads Get-Date once and uses now minus the days as the cutoff for every root: 90 days' {
        Clear-SwGameMedia -DaysOld 90
        $script:DateCalls | Should -Be 1
        $script:ScanCalls.Count | Should -Be 12
        foreach ($call in $script:ScanCalls) { $call.OlderThan | Should -Be $script:FixedNow.AddDays(-90) }
    }

    It 'CA-8 uses now as the cutoff for 0 days: everything that is older than now' {
        Clear-SwGameMedia -DaysOld 0
        $script:ScanCalls.Count | Should -Be 12
        foreach ($call in $script:ScanCalls) { $call.OlderThan | Should -Be $script:FixedNow }
    }

    It 'CA-9 scans each of the twelve roots of the table once, in the order of the table, without a Test-Path before it' {
        Mock Test-Path { throw 'Test-Path must not run for a root' }
        Clear-SwGameMedia -DaysOld 90
        $expected = @(Get-MediaRoots | ForEach-Object { Fold $_.Path })
        @($script:ScanCalls | ForEach-Object { Fold $_.Root }) | Should -Be $expected
    }

    It 'CA-9 gives the video and picture roots the extension set and the other three roots no extension filter, recursive, with the standard budget' {
        Clear-SwGameMedia -DaysOld 90
        $roots = @(Get-MediaRoots)
        for ($i = 0; $i -lt 12; $i++) {
            $call = $script:ScanCalls[$i]
            if ($roots[$i].Set) { @($call.Extensions | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object) | Should -Be @($script:MediaSet | Sort-Object) -Because $roots[$i].Path }
            else { @($call.Extensions).Count | Should -Be 0 -Because $roots[$i].Path }
            $call.NoRecurse | Should -BeFalse
            $call.HasTimeout | Should -BeFalse
            $call.HasOlderThan | Should -BeTrue
        }
    }

    It 'CA-9 CD-3 scans the roots below LOCALAPPDATA only when it is usable, the roots below USERPROFILE only when it is: <Label>' -ForEach $script:BadValues {
        Set-Env 'USERPROFILE' $Value
        Clear-SwGameMedia -DaysOld 90
        $script:ScanCalls.Count | Should -Be 2
        foreach ($call in $script:ScanCalls) { Test-SameOrUnder $call.Root $script:Local | Should -BeTrue }
        $script:ScanCalls.Clear()
        Set-Env 'USERPROFILE' $script:Profile
        Set-Env 'LOCALAPPDATA' $Value
        Clear-SwGameMedia -DaysOld 90
        $script:ScanCalls.Count | Should -Be 10
        foreach ($call in $script:ScanCalls) { Test-SameOrUnder $call.Root $script:Profile | Should -BeTrue }
        @($script:Sections | Where-Object { $_ -eq 'stop' }).Count | Should -Be 2
    }

    It 'CA-9 CD-3 scans no root when a variable is the root of a drive, and still opens and closes the section' {
        $driveRoot = [System.IO.Path]::GetPathRoot($script:Work)
        Set-Env 'USERPROFILE' $driveRoot
        Set-Env 'LOCALAPPDATA' $driveRoot
        Clear-SwGameMedia -DaysOld 90
        $script:ScanCalls.Count | Should -Be 0
        @($script:Sections) | Should -Be @('start:Game media (>90d old)', 'stop')
    }

    It 'CA-9 CD-3 reads a base with brackets literally and trims the value' {
        $bracket = New-Dir (P $script:Work 'Ex [1]' 'Profile')
        Set-Env 'USERPROFILE' ('  ' + $bracket + '  ')
        Clear-SwGameMedia -DaysOld 90
        foreach ($call in @($script:ScanCalls | Where-Object { $_.Root -like '*Videos*' })) { Test-SameOrUnder $call.Root $bracket | Should -BeTrue -Because $call.Root }
    }

    It 'CD-4 throws nothing and scans nothing when the cutoff cannot be computed: 2147483647 days, also through the old name' {
        { Clear-SwGameMedia -DaysOld 2147483647 } | Should -Not -Throw
        @($script:Sections) | Should -Be @('start:Game media (>2147483647d old)', 'stop')
        $script:ScanCalls.Count | Should -Be 0
        @(Get-MediaCalls).Count | Should -Be 0
        $script:Sections.Clear()
        { Clear-GameMediaFiles 2147483647 } | Should -Not -Throw
        @($script:Sections) | Should -Be @('start:Game media (>2147483647d old)', 'stop')
        (Invoke-Captured { Clear-SwGameMedia -DaysOld 2147483647 }).Count | Should -Be 0
    }

    It 'CD-4 throws nothing when the section cannot be opened or closed' {
        Mock Start-SwSection { throw 'no section' }
        { Clear-SwGameMedia -DaysOld 90 } | Should -Not -Throw
        Mock Stop-SwSection { throw 'no section end' }
        { Clear-SwGameMedia -DaysOld 90 } | Should -Not -Throw
        $script:ScanCalls.Count | Should -BeGreaterThan 0
    }

    It 'CA-9 asks no Remove-SwItems when the search finds no file, and uses no other removal helper at all' {
        Clear-SwGameMedia -DaysOld 90
        $script:Calls.Count | Should -Be 0
    }

    It 'CA-9 gives every delivered file its own Remove-SwItems call with a list of one path, the description with the source name and the days, and a condition' {
        $script:ScanAnswers[(P $script:Profile 'Videos' 'ShadowPlay')] = @{ Files = @((P $script:Profile 'Videos' 'ShadowPlay' 'a.mp4'), (P $script:Profile 'Videos' 'ShadowPlay' 'b.png')); Complete = $true }
        $script:ScanAnswers[(P $script:Profile 'Videos' 'Medal')] = @{ Files = @((P $script:Profile 'Videos' 'Medal' 'm.mp4')); Complete = $true }
        $script:ScanAnswers[(P $script:Local 'FortniteGame' 'Saved' 'Demos')] = @{ Files = @((P $script:Local 'FortniteGame' 'Saved' 'Demos' 'r.replay')); Complete = $true }
        Clear-SwGameMedia -DaysOld 90
        $calls = @(Get-MediaCalls)
        $calls.Count | Should -Be 4
        @($calls | ForEach-Object { @($_.Paths).Count }) | Should -Be @(1, 1, 1, 1)
        @($calls | ForEach-Object { $_.Description }) | Should -Be @('NVIDIA recordings (>90d)', 'NVIDIA recordings (>90d)', 'Medal.tv clips (>90d)', 'Fortnite replays (>90d)')
        foreach ($call in $calls) { $call.CanRemove | Should -BeOfType [scriptblock] }
    }

    It 'CA-9 puts the days that were given into the description: (>30d)' {
        $script:ScanAnswers[(P $script:Profile 'Videos' 'AMD')] = @{ Files = @((P $script:Profile 'Videos' 'AMD' 'x.mkv')); Complete = $true }
        Clear-SwGameMedia -DaysOld 30
        @(Get-MediaCalls)[0].Description | Should -Be 'AMD ReLive recordings (>30d)'
    }

    It 'CA-9 gives each source of the table its description: <Name>' -ForEach $script:Sources {
        $first = @($Roots)[0]
        $root = Get-SourceRoot $first
        $script:ScanAnswers[$root] = @{ Files = @((P $root 'file.mp4')); Complete = $true }
        Clear-SwGameMedia -DaysOld 90
        $calls = @(Get-MediaCalls)
        $calls.Count | Should -Be 1
        $calls[0].Description | Should -Be ($Name + ' (>90d)')
    }

    It 'CD-7 S-11 chooses a file once in a run, also when two roots deliver it' {
        $same = P $script:Profile 'Videos' 'ShadowPlay' 'same.mp4'
        $script:ScanAnswers[(P $script:Profile 'Videos' 'NVIDIA')] = @{ Files = @($same); Complete = $true }
        $script:ScanAnswers[(P $script:Profile 'Videos' 'ShadowPlay')] = @{ Files = @($same); Complete = $true }
        Clear-SwGameMedia -DaysOld 90
        @(Get-MediaCalls).Count | Should -Be 1
    }

    It 'CA-9 CD-31 chooses nothing from an incomplete root, notes the source as "incomplete scan" and goes on with the other roots' {
        $script:ScanAnswers[(P $script:Profile 'Videos' 'Medal')] = @{ Files = @(); Complete = $false }
        $script:ScanAnswers[(P $script:Profile 'Videos' 'Overwolf')] = @{ Files = @((P $script:Profile 'Videos' 'Overwolf' 'o.mp4')); Complete = $true }
        Clear-SwGameMedia -DaysOld 90
        $note = @(Get-NotMeasuredFor 'Medal.tv clips')
        $note.Count | Should -Be 1
        $note[0].Reason | Should -Be 'incomplete scan'
        @(Get-MediaCalls).Count | Should -Be 1
        @(Get-MediaCalls)[0].Description | Should -Be 'Overwolf/Outplayed recordings (>90d)'
        $script:ScanCalls.Count | Should -Be 12
        @($script:Sections) | Should -Be @('start:Game media (>90d old)', 'stop')
    }

    It 'CA-9 CD-4 goes on with the other roots and closes the section when a search throws, and throws nothing' {
        Mock Get-SwBoundedFileScan {
            $script:ScanCalls.Add([pscustomobject]@{ Root = $Root })
            if ($Root -like '*ShadowPlay') { throw 'the search failed' }
            @{ Files = @(); Complete = $true }
        }
        { Clear-SwGameMedia -DaysOld 90 } | Should -Not -Throw
        $script:ScanCalls.Count | Should -Be 12
        @($script:Sections) | Should -Be @('start:Game media (>90d old)', 'stop')
    }

    It 'CD-4 writes nothing to the pipeline, also when Remove-SwItems writes a value' {
        $script:SinkLeak = $true
        $script:ScanAnswers[(P $script:Profile 'Videos' 'Medal')] = @{ Files = @((P $script:Profile 'Videos' 'Medal' 'm.mp4')); Complete = $true }
        (Invoke-Captured { Clear-SwGameMedia -DaysOld 90 }).Count | Should -Be 0
        (Invoke-Captured { Clear-SwGameMedia -DaysOld -1 }).Count | Should -Be 0
    }

    It 'CA-7 CA-10 never scans a general picture or video folder: Pictures, Videos and their general subfolders, Documents and the Steam folders' {
        Clear-SwGameMedia -DaysOld 90
        foreach ($call in $script:ScanCalls) {
            foreach ($forbidden in (P $script:Profile 'Pictures'), (P $script:Profile 'Documents'), (P $script:Profile 'Videos' 'Captures'), (P $script:Profile 'Videos' 'OBS'), (P $script:Profile 'Videos' 'Screen Recordings'), (P $script:Profile 'Videos' 'Desktop')) {
                Test-SameOrUnder $call.Root $forbidden | Should -BeFalse -Because ($call.Root + ' vs ' + $forbidden)
            }
            (Fold $call.Root) | Should -Not -Be (Fold (P $script:Profile 'Videos')) -Because 'Videos itself is never a root'
            (Fold $call.Root) | Should -Not -Match 'steam'
        }
    }
}

Describe 'CA-9 CA-10 S-10 which files are chosen, with the real search' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -NoNet
    }
    AfterEach { Stop-Case }

    It 'CA-9 chooses the picture and video files of a program folder with the extension set, without regard to case, and never notes.txt' {
        $clip = New-OldFile (P $script:Profile 'Videos' 'ShadowPlay' 'clip.mp4') 120
        $photo = New-OldFile (P $script:Profile 'Videos' 'ShadowPlay' 'photo.JPG') 120
        $null = New-OldFile (P $script:Profile 'Videos' 'ShadowPlay' 'notes.txt') 120
        Clear-SwGameMedia -DaysOld 90
        $calls = @(Get-MediaCalls)
        $calls.Count | Should -Be 2
        @($calls | ForEach-Object { Fold $_.Paths[0] } | Sort-Object) | Should -Be @((Fold $clip), (Fold $photo) | Sort-Object)
        foreach ($call in $calls) {
            $answer = @(& $call.CanRemove)
            $answer.Count | Should -Be 1
            $answer[0] | Should -BeOfType [bool]
            $answer[0] | Should -BeTrue
        }
    }

    It 'CA-9 chooses every file of a replay or log root, whatever its extension' {
        $replay = New-OldFile (P $script:Local 'FortniteGame' 'Saved' 'Demos' 'match.replay') 120
        $log = New-OldFile (P $script:Local 'VALORANT' 'Saved' 'Logs' 'VALORANT.log') 120
        $temp = New-OldFile (P $script:Profile 'Saved Games' 'Respawn' 'Apex' 'assets' 'temp' 'cache.bin') 120
        Clear-SwGameMedia -DaysOld 90
        @(Get-MediaPaths | Sort-Object) | Should -Be @((Fold $replay), (Fold $log), (Fold $temp) | Sort-Object)
    }

    It 'CA-9 goes below the root: a file two folders down is chosen' {
        $deep = New-OldFile (P $script:Profile 'Videos' 'Medal' 'game' 'session' 'clip.mp4') 120
        Clear-SwGameMedia -DaysOld 90
        @(Get-MediaPaths) | Should -Be @((Fold $deep))
    }

    It 'CA-9 chooses only files strictly older than the cutoff: 100 days yes, 80 days no, today no' {
        $old = New-OldFile (P $script:Profile 'Videos' 'Medal' 'old.mp4') 100
        $null = New-OldFile (P $script:Profile 'Videos' 'Medal' 'recent.mp4') 80
        $null = New-File (P $script:Profile 'Videos' 'Medal' 'today.mp4') 3
        Clear-SwGameMedia -DaysOld 90
        @(Get-MediaPaths) | Should -Be @((Fold $old))
    }

    It 'CA-9 chooses a file of 30 days for 7 days and not for 90 days' {
        $file = New-OldFile (P $script:Profile 'Videos' 'Medal' 'thirty.mp4') 30
        Clear-SwGameMedia -DaysOld 90
        @(Get-MediaCalls).Count | Should -Be 0
        $script:Calls.Clear()
        Clear-SwGameMedia -DaysOld 7
        @(Get-MediaPaths) | Should -Be @((Fold $file))
    }

    It 'CA-9 never chooses a folder, and leaves an empty folder where it is' {
        $null = New-OldFile (P $script:Profile 'Videos' 'Medal' 'old clip.mp4') 120
        $folder = New-Dir (P $script:Profile 'Videos' 'Medal' 'empty folder')
        Set-Age $folder 200
        Clear-SwGameMedia -DaysOld 90
        foreach ($path in (Get-MediaPaths)) { [System.IO.Directory]::Exists($path) | Should -BeFalse }
        [System.IO.Directory]::Exists($folder) | Should -BeTrue
    }

    It 'CA-10 S-10 never chooses a file in the general folders, whatever its age: <Folder>' -ForEach $script:NeverFolders {
        $path = $script:Profile
        foreach ($segment in ($Folder -split '/')) { $path = P $path $segment }
        $null = New-OldFile (P $path 'old.mp4') 200
        $null = New-OldFile (P $path 'old.png') 200
        $null = New-OldFile (P $path 'old.bin') 200
        Clear-SwGameMedia -DaysOld 90
        @(Get-MediaCalls).Count | Should -Be 0
    }

    It 'CA-10 chooses the program folder file and leaves the general folders beside it: the same run over both' {
        $mine = New-OldFile (P $script:Profile 'Videos' 'ShadowPlay' 'clip.mp4') 120
        foreach ($other in 'Pictures/Screenshots/s.png', 'Videos/Screen Recordings/r.mp4', 'Videos/Captures/game.mp4', 'Videos/OBS/o.mkv', 'Documents/League of Legends/Replays/l.rofl') {
            $path = $script:Profile
            foreach ($segment in ($other -split '/')) { $path = P $path $segment }
            $null = New-OldFile $path 200
        }
        Clear-SwGameMedia -DaysOld 90
        @(Get-MediaPaths) | Should -Be @((Fold $mine))
    }

    It 'CA-9 CD-8 does not deliver a file that is a link' {
        $real = New-OldFile (P $script:Work 'elsewhere' 'real.mp4') 200
        $null = New-Dir (P $script:Profile 'Videos' 'Medal')
        if (-not (New-TestLink (P $script:Profile 'Videos' 'Medal' 'linked.mp4') $real)) { Set-ItResult -Skipped -Because 'this host cannot create a file link here'; return }
        Clear-SwGameMedia -DaysOld 90
        @(Get-MediaCalls).Count | Should -Be 0
    }

    It 'CA-9 CD-8 does not enter a folder that is a link' {
        $target = New-Dir (P $script:Work 'media target')
        $null = New-OldFile (P $target 'inside.mp4') 200
        $null = New-Dir (P $script:Profile 'Videos' 'Medal')
        if (-not (New-TestLink (P $script:Profile 'Videos' 'Medal' 'link') $target)) { Set-ItResult -Skipped -Because 'this host cannot create a link here'; return }
        Clear-SwGameMedia -DaysOld 90
        @(Get-MediaCalls).Count | Should -Be 0
    }

    It 'CA-9 CA-10 [W] does not deliver a cloud placeholder file, which has the reparse point attribute' {
        $path = New-OldFile (P $script:Profile 'Videos' 'Medal' 'placeholder.mp4') 200
        [System.IO.File]::SetAttributes($path, [System.IO.File]::GetAttributes($path) -bor [System.IO.FileAttributes]::ReparsePoint)
        Clear-SwGameMedia -DaysOld 90
        @(Get-MediaCalls).Count | Should -Be 0
    }

    It 'CA-9 [W] does not choose a file that was written 120 days ago and created yesterday: the newer of the two times counts' {
        $path = New-File (P $script:Profile 'Videos' 'Medal' 'restored.mp4') 3
        Set-Times $path 1 120
        [System.IO.File]::GetCreationTime($path) | Should -BeGreaterThan ([datetime]::Now.AddDays(-5)) -Because 'the fixture needs a creation time of yesterday'
        Clear-SwGameMedia -DaysOld 90
        @(Get-MediaCalls).Count | Should -Be 0
    }

    It 'CA-9 changes nothing on disk itself: a run with the spy helper leaves every file where it is' {
        $null = New-OldFile (P $script:Profile 'Videos' 'Medal' 'a.mp4') 200
        $null = New-OldFile (P $script:Local 'FortniteGame' 'Saved' 'Demos' 'b.replay') 200
        $before = Get-Listing $script:Profile
        Clear-SwGameMedia -DaysOld 90
        Same-Listing (Get-Listing $script:Profile) $before | Should -BeTrue
    }
}

Describe 'CA-9 the condition that checks the age again right before the removal' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -NoNet
        $script:One = New-OldFile (P $script:Profile 'Videos' 'Medal' 'one.mp4') 200
        $script:Two = New-OldFile (P $script:Profile 'Videos' 'Medal' 'two.mp4') 200
        Clear-SwGameMedia -DaysOld 90
        $script:Blocks = @{}
        foreach ($call in @(Get-MediaCalls)) { $script:Blocks[(Fold $call.Paths[0])] = $call.CanRemove }
    }
    AfterEach { Stop-Case }

    It 'CA-9 gives each file its own condition: a file that became new does not hold the other one back, and the other way round' {
        Set-Age $script:One 0
        $one = @(& $script:Blocks[(Fold $script:One)])
        $two = @(& $script:Blocks[(Fold $script:Two)])
        $one.Count | Should -Be 1
        $two.Count | Should -Be 1
        $one[0] | Should -BeFalse
        $two[0] | Should -BeTrue
    }

    It 'CA-9 answers $false when the file is gone, and exactly one bool' {
        [System.IO.File]::Delete($script:Two)
        $answer = @(& $script:Blocks[(Fold $script:Two)])
        $answer.Count | Should -Be 1
        $answer[0] | Should -BeOfType [bool]
        $answer[0] | Should -BeFalse
    }

    It 'CA-9 answers $false when the file became a link' {
        $target = New-File (P $script:Work 'link target.mp4') 3
        Set-Age $target 300
        [System.IO.File]::Delete($script:One)
        if (-not (New-TestLink $script:One $target)) { Set-ItResult -Skipped -Because 'this host cannot create a file link here'; return }
        $answer = @(& $script:Blocks[(Fold $script:One)])
        $answer.Count | Should -Be 1
        $answer[0] | Should -BeFalse
    }

    It 'CA-9 asks the file at every evaluation: old gives $true, new gives $false, old again gives $true' {
        $block = $script:Blocks[(Fold $script:One)]
        (@(& $block))[0] | Should -BeTrue
        Set-Age $script:One 0
        (@(& $block))[0] | Should -BeFalse
        Set-Age $script:One 200
        (@(& $block))[0] | Should -BeTrue
    }

    It 'CA-9 [W] answers $false when the creation time changed to now between the search and the removal: the newer of both times counts' {
        $block = $script:Blocks[(Fold $script:One)]
        [System.IO.File]::SetCreationTime($script:One, [datetime]::Now)
        [System.IO.File]::GetLastWriteTime($script:One) | Should -BeLessThan ([datetime]::Now.AddDays(-150)) -Because 'the fixture needs the write time to stay old'
        (@(& $block))[0] | Should -BeFalse
    }
}

Describe 'CA-11 the preview and the real run of the game media with the real removal helper' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -Real -NoNet
        $script:Clip = New-OldFile (P $script:Profile 'Videos' 'ShadowPlay' 'clip.mp4') 120
        $script:Fresh = New-OldFile (P $script:Profile 'Videos' 'ShadowPlay' 'fresh.mp4') 10
        $script:Screen = New-OldFile (P $script:Profile 'Pictures' 'Screenshots' 'shot.png') 300
    }
    AfterEach { Stop-Case }

    It 'CA-11 lists in a preview only the old file of the program folder, with the days in the description, and changes nothing' {
        $before = Get-Listing $script:Profile
        $script:SweeprDryRunMode = $true
        Use-Collectors
        Clear-SwGameMedia -DaysOld 90
        $entries = @($script:DryRunCollector)
        $entries.Count | Should -Be 1
        (Fold $entries[0].Path) | Should -Be (Fold $script:Clip)
        $entries[0].Description | Should -Be 'NVIDIA recordings (>90d)'
        Same-Listing (Get-Listing $script:Profile) $before | Should -BeTrue
        $script:Ops.Count | Should -Be 0
    }

    It 'CA-11 removes in a real run only the old file of the program folder: the fresh file and the screenshot stay' {
        $script:SweeprDryRunMode = $false
        Clear-SwGameMedia -DaysOld 90
        [System.IO.File]::Exists($script:Clip) | Should -BeFalse
        [System.IO.File]::Exists($script:Fresh) | Should -BeTrue
        [System.IO.File]::Exists($script:Screen) | Should -BeTrue
        $script:FilesCleaned | Should -Be 1
    }

    It 'CA-11 CA-12 counts a file per helper call: three old files are three files, three items, and the preview lists three lines' {
        $null = New-OldFile (P $script:Profile 'Videos' 'Medal' 'a.mp4') 200
        $null = New-OldFile (P $script:Local 'FortniteGame' 'Saved' 'Demos' 'r.replay') 200
        $script:SweeprDryRunMode = $true
        Use-Collectors
        Clear-SwGameMedia -DaysOld 90
        $script:DryRunCollector.Count | Should -Be 3
        $script:SweeprDryRunMode = $false
        $script:FilesCleaned = 0
        $script:TotalItems = 0
        Clear-SwGameMedia -DaysOld 90
        $script:FilesCleaned | Should -Be 3
        $script:TotalItems | Should -Be 3
    }

    It 'CA-11 applies the age check also in a preview and in a real run: a file that the search reports but that is new is not listed and not removed' {
        Mock Get-SwBoundedFileScan { @{ Files = @($script:Fresh); Complete = $true } }
        $script:SweeprDryRunMode = $true
        Use-Collectors
        Clear-SwGameMedia -DaysOld 90
        $script:DryRunCollector.Count | Should -Be 0
        $script:SweeprDryRunMode = $false
        Clear-SwGameMedia -DaysOld 90
        [System.IO.File]::Exists($script:Fresh) | Should -BeTrue
        $script:FilesCleaned | Should -Be 0
    }

    It 'CA-11 removes nothing for a negative number of days and for a preview of it' {
        $script:SweeprDryRunMode = $false
        Clear-SwGameMedia -DaysOld -1
        [System.IO.File]::Exists($script:Clip) | Should -BeTrue
        $script:FilesCleaned | Should -Be 0
    }

    It 'CA-7 chooses game media only through the explicit call or the switch: the Applications section alone does not touch the folder' {
        $script:SweeprDryRunMode = $false
        Invoke-SwAppCleanup
        [System.IO.File]::Exists($script:Clip) | Should -BeTrue
        Invoke-SwAppCleanup -IncludeGameMedia
        [System.IO.File]::Exists($script:Clip) | Should -BeFalse
    }
}

Describe 'The old name Clear-GameMediaFiles' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -NoNet
    }
    AfterEach { Stop-Case }

    It 'Old name keeps DaysOld (int, position 0, default 90), has no CmdletBinding, is no alias and calls Clear-SwGameMedia -DaysOld once' {
        (Get-ParamLine 'Clear-GameMediaFiles' 'DaysOld') | Should -Be 'DaysOld|System.Int32|pos=0|mandatory=False|default=90'
        (Get-Command -Name Clear-GameMediaFiles).CommandType | Should -Be 'Function'
        (Get-Command -Name Clear-GameMediaFiles).CmdletBinding | Should -BeFalse
        $script:Seen = [System.Collections.Generic.List[int]]::new()
        Mock Clear-SwGameMedia { $script:Seen.Add($DaysOld) }
        Clear-GameMediaFiles 12
        Clear-GameMediaFiles -DaysOld 34
        Clear-GameMediaFiles
        @($script:Seen) | Should -Be @(12, 34, 90)
    }
}
