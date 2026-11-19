# Sweepr - tests for the run of Invoke-SwOwnerCacheCleanup in lib\clean\dev.ps1: the checks of a real run, the
# preview branch, a successful command, a failed command, the statistics and the operations log lines OWNER and
# FAILED, and the number of whitelist reads and tree listings.
#
# The rule numbers in the test names (CD-, CA-, S- and so on) number the rules and the safety invariants
# of the behavior of the developer tool and application cleanup; each rule and invariant has at least one test.
# The other files of this slice are SwCleanDevGroups, SwCleanDevLoad, SwCleanDevScan, SwCleanDevOwnerPath,
# SwCleanDevProcess, SwCleanDevEditors, SwCleanAppsGroups, SwCleanAppsMedia and SwCleanDevAppsSafety.
#
# Interface pinned here (lib\clean\dev.ps1):
#   Invoke-SwOwnerCacheCleanup -Name -Query -Arguments -Description
#       1 query, 2 plausibility and safety of the root, 3 tree check, 4 preview branch, 5 checks again in a real run,
#       6 measure before, 7 the command (Invoke-SwOwnerCommand -Mutation -TimeoutSeconds 120 -Outcome), 8 success or failure
#   Write-SwOperation -Action OWNER|FAILED -Path <root> -Detail <command line>   (the only log lines of these files)
#   Counters: $script:OwnerCleanups (+1 per successful command), $script:TotalSizeCleaned (KB, rounded down, only after a
#   complete before and after measurement); $script:FilesCleaned and $script:TotalItems are not changed by the owner path
#
# Seams used with Mock: Get-SwOwnerCachePath (answers per call), Invoke-SwOwnerCommand (stand-in whose action is set
# per case), Get-SwPathSnapshot and Test-SwPathSnapshot (substitute objects), Get-SwWhitelistState and
# Get-SwSafeDirectoryTreeItems (counting stand-ins that call the real function), Get-SwValidatedTreeSize (must not be
# called), Write-SwOperation, Write-SwSuccess, Write-SwDryRun, Set-SwSectionActivity, the removal helpers (must not be
# called), Test-SwSafePath is the real one.
#
# Platform notes:
#   - The stand-in command removes files below $TestDrive; nothing else is removed or started.
#   - Tests marked [W] need real Windows. They are meant to fail on Linux and belong in
#     tests/linux-known-failures.txt.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

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

    # One cache folder, the query answering it, and the mode.
    function script:Initialize-OwnerCase([bool]$Dry, [switch]$Collector) {
        $script:Cache = New-NpmCache (P $script:Work 'npm-cache')
        Use-OwnerRun @($script:Cache)
        $script:SweeprDryRunMode = $Dry
        if ($Collector) { Use-Collectors }
    }
    function script:Get-Kilobytes { [long]$script:TotalSizeCleaned }
}

AfterAll {
    Clear-TestLinks
    Restore-Env $script:RootEnv
    Restore-State $script:RootState
    [System.Environment]::CurrentDirectory = $script:RootDirectory
    try { Set-Location -LiteralPath $script:RootLocation } catch { $null = $_ }
}
Describe 'CD-15 the preview branch of an owner path' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -NoNet
        Initialize-OwnerCase $true
        $script:FilesCleaned = 3
        $script:TotalItems = 4
    }
    AfterEach { Stop-Case }

    It 'CD-15 lists the folder, counts one owner cleanup, estimates nothing and starts nothing: list file, counters, no log line' {
        $list = P $script:Work 'clean-list.txt'
        [System.IO.File]::WriteAllText($list, '', $script:Utf8)
        $script:ExportListFile = $list
        $script:DryRunCollector = $null
        Invoke-NpmCleanup
        @(Get-Mutations).Count | Should -Be 0
        $script:Commands.Count | Should -Be 0
        (Get-FileText $list) | Should -Match ([regex]::Escape($script:Cache))
        (Get-FileText $list) | Should -Match '# npm cache'
        [int]$script:OwnerCleanups | Should -Be 1
        (Get-Kilobytes) | Should -Be 0
        $script:Ops.Count | Should -Be 0
        $script:FilesCleaned | Should -Be 3
        $script:TotalItems | Should -Be 4
        [System.IO.File]::Exists((P $script:Cache '_cacache' 'gone.bin')) | Should -BeTrue
    }

    It 'CD-15 gives the collector exactly one entry with the folder, size 0 and count 0 and the description' {
        Use-Collectors
        Invoke-NpmCleanup
        $entries = @($script:DryRunCollector)
        $entries.Count | Should -Be 1
        $entries[0].Path | Should -BeExactly $script:Cache
        $entries[0].SizeBytes | Should -Be 0
        $entries[0].Count | Should -Be 0
        $entries[0].Description | Should -Be 'npm cache'
    }

    It 'CD-15 writes one preview line that names the description, marks the section as active, and does not ask a second time' {
        Invoke-NpmCleanup
        $lines = @(Get-LogLines 'DRYRUN')
        $lines.Count | Should -Be 1
        $lines[0] | Should -Match 'npm cache'
        $script:Activity | Should -BeGreaterThan 0
        $script:QueryCalls.Count | Should -Be 1
        @(Get-LogLines 'SUCCESS').Count | Should -Be 0
    }

    It 'CD-15 CD-20 reads the whitelist twice and lists the tree once in a preview, and never measures with Get-SwValidatedTreeSize' {
        foreach ($name in 1..8) { $null = New-File (P $script:Cache '_cacache' ('f' + $name + '.bin')) 100 }
        Invoke-NpmCleanup
        $script:WlReads | Should -Be 2
        $script:TreeCalls | Should -Be 1
        Should -Invoke Get-SwValidatedTreeSize -Times 0 -Exactly
    }

    It 'CD-15 CD-19 adds to the counter: 5 becomes 6, a missing counter becomes 1, a counter that is not a number counts as 0' {
        $script:OwnerCleanups = 5
        Invoke-NpmCleanup
        $script:OwnerCleanups | Should -Be 6
        Remove-Variable -Name OwnerCleanups -Scope Script
        Invoke-NpmCleanup
        $script:OwnerCleanups | Should -Be 1
        $script:OwnerCleanups = 'abc'
        Invoke-NpmCleanup
        $script:OwnerCleanups | Should -Be 1
    }

    It 'CD-6 CD-15 writes nothing to the operations log in a preview and nothing to the pipeline' {
        $out = Invoke-Captured { Invoke-NpmCleanup }
        $out.Count | Should -Be 0
        $script:Ops.Count | Should -Be 0
        Should -Invoke Write-SwOperation -Times 0 -Exactly
    }

    It 'CD-15 gives the folder of the query unchanged, also when the folder name has brackets' {
        $bracket = New-NpmCache (P $script:Work 'npm [cache]')
        $script:QueryAnswers = @($bracket)
        Use-Collectors
        Invoke-NpmCleanup
        @($script:DryRunCollector)[0].Path | Should -BeExactly $bracket
    }

    It 'CD-15 the preview follows the same checks as a real run: a refused root is not listed' {
        Set-Whitelist @($script:Cache)
        Use-Collectors
        Invoke-NpmCleanup
        $script:DryRunCollector.Count | Should -Be 0
        [int]$script:OwnerCleanups | Should -Be 0
    }
}

Describe 'CD-14 CD-16 CD-19 a successful command in a real run' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -NoNet
        Initialize-OwnerCase $false
        $script:FilesCleaned = 0
        $script:TotalItems = 0
    }
    AfterEach { Stop-Case }

    It 'CD-16 counts the cleanup and the removed bytes: gone.bin of 4096 bytes gives 4 KB, FilesCleaned and TotalItems stay 0, kept.bin stays' {
        Invoke-NpmCleanup
        [int]$script:OwnerCleanups | Should -Be 1
        (Get-Kilobytes) | Should -Be 4
        $script:FilesCleaned | Should -Be 0
        $script:TotalItems | Should -Be 0
        [System.IO.File]::Exists((P $script:Cache 'kept.bin')) | Should -BeTrue
        [System.IO.File]::Exists((P $script:Cache '_cacache' 'gone.bin')) | Should -BeFalse
        [System.IO.Directory]::Exists($script:Cache) | Should -BeTrue -Because 'the function does not remove the folder'
    }

    It 'CD-16 writes exactly one OWNER line with the unchanged folder and the command line' {
        Invoke-NpmCleanup
        $owner = @(Get-OpsOf 'OWNER')
        $owner.Count | Should -Be 1
        $owner[0].Path | Should -BeExactly $script:Cache
        $owner[0].Detail | Should -BeExactly 'npm cache clean --force'
        @(Get-OpsOf 'FAILED').Count | Should -Be 0
        $script:Ops.Count | Should -Be 1
    }

    It 'CD-16 writes a success line that names the description, marks the section active, and writes nothing to the pipeline' {
        $out = Invoke-Captured { Invoke-NpmCleanup }
        $out.Count | Should -Be 0
        $lines = @(Get-LogLines 'SUCCESS')
        $lines.Count | Should -Be 1
        $lines[0] | Should -Match 'npm cache'
        $script:Activity | Should -BeGreaterThan 0
        @(Get-LogLines 'DRYRUN').Count | Should -Be 0
    }

    It 'CD-14 CD-16 runs the mutation once with the name, the arguments of the table, the flag -Mutation, the limit 120 and an outcome table' {
        Invoke-NpmCleanup
        $commands = @(Get-Mutations)
        $commands.Count | Should -Be 1
        $script:Commands.Count | Should -Be 1 -Because 'the query is answered by Get-SwOwnerCachePath, the command runs once and is never repeated'
        $commands[0].Name | Should -Be 'npm'
        ($commands[0].Arguments -join ' ') | Should -Be 'cache clean --force'
        $commands[0].TimeoutSeconds | Should -Be 120
        $commands[0].Outcome | Should -BeOfType [hashtable]
    }

    It 'CD-14 asks the query twice with the same name and arguments and reads the whitelist four times, lists the tree three times' {
        foreach ($name in 1..8) { $null = New-File (P $script:Cache '_cacache' ('f' + $name + '.bin')) 100 }
        Invoke-NpmCleanup
        $script:QueryCalls.Count | Should -Be 2
        foreach ($call in $script:QueryCalls) {
            $call.Name | Should -Be 'npm'
            ($call.Arguments -join ' ') | Should -Be 'config get cache'
        }
        $script:WlReads | Should -Be 4
        $script:TreeCalls | Should -Be 3
        Should -Invoke Get-SwValidatedTreeSize -Times 0 -Exactly
    }

    It 'CD-16 counts the cleanup but no bytes when the command changes nothing, and does not call it "already clean"' {
        $script:OnCommand = { param($Outcome) [pscustomobject]@{ Output = '' } }
        Invoke-NpmCleanup
        [int]$script:OwnerCleanups | Should -Be 1
        (Get-Kilobytes) | Should -Be 0
        @(Get-OpsOf 'OWNER').Count | Should -Be 1
        $script:Activity | Should -BeGreaterThan 0
    }

    It 'CD-16 counts the cleanup but no bytes when the tree cannot be listed after the command (Success $false)' {
        $script:AfterCommand = $false
        $script:OnCommand = { param($Outcome) $script:AfterCommand = $true; [pscustomobject]@{ Output = '' } }
        Mock Get-SwSafeDirectoryTreeItems {
            $script:TreeCalls++
            if ($script:AfterCommand) { return @{ Success = $false; Items = @(); RootSnapshot = $null; Reason = 'cannot list' } }
            & $script:RealTree -Path $Path -WhitelistState $WhitelistState
        }
        Invoke-NpmCleanup
        [int]$script:OwnerCleanups | Should -Be 1
        (Get-Kilobytes) | Should -Be 0
        @(Get-OpsOf 'OWNER').Count | Should -Be 1
    }

    It 'CD-16 counts no bytes when the folder was replaced during the command: a replaced folder is not the folder that was measured' {
        $script:OnCommand = {
            param($Outcome)
            $gone = P $script:Cache '_cacache' 'gone.bin'
            [System.IO.File]::Delete($gone)
            $script:FakeReplaced.Add($script:Cache)
            [pscustomobject]@{ Output = '' }
        }
        Invoke-NpmCleanup
        [int]$script:OwnerCleanups | Should -Be 1
        (Get-Kilobytes) | Should -Be 0
        $script:TreeCalls | Should -Be 2 -Because 'no third listing is made for a folder that is no longer the checked one'
    }

    It 'CD-16 counts no bytes when the folder is gone after the command: an unmeasurable tree is never empty' {
        $script:OnCommand = {
            param($Outcome)
            [System.IO.Directory]::Delete($script:Cache, $true)
            [pscustomobject]@{ Output = '' }
        }
        Invoke-NpmCleanup
        [int]$script:OwnerCleanups | Should -Be 1
        (Get-Kilobytes) | Should -Be 0
    }

    It 'CD-16 rounds the kilobytes down: 1500 removed bytes are 1 KB, 1023 removed bytes are 0 KB' -ForEach @(
        @{ Bytes = 1500; Expected = 1 }, @{ Bytes = 1023; Expected = 0 }, @{ Bytes = 2048; Expected = 2 }, @{ Bytes = 5000; Expected = 4 }) {
        $folder = P $script:Work ('round-' + $Bytes)
        $null = New-File (P $folder '_cacache' 'gone.bin') $Bytes
        $null = New-File (P $folder 'kept.bin') 100
        $script:Cache = $folder
        $script:QueryAnswers = @($folder)
        Invoke-NpmCleanup
        [int]$script:OwnerCleanups | Should -Be 1
        (Get-Kilobytes) | Should -Be $Expected
    }

    It 'CD-16 never counts a negative amount: a command that makes the folder larger adds 0 KB' {
        $script:OnCommand = {
            param($Outcome)
            $null = New-File (P $script:Cache '_cacache' 'more.bin') 8192
            [pscustomobject]@{ Output = '' }
        }
        Invoke-NpmCleanup
        [int]$script:OwnerCleanups | Should -Be 1
        (Get-Kilobytes) | Should -Be 0
    }

    It 'CD-19 adds to the counters instead of setting them: 10 KB and 2 cleanups become 14 KB and 3, a missing counter counts as 0, a text counts as 0' {
        $script:TotalSizeCleaned = 10
        $script:OwnerCleanups = 2
        Invoke-NpmCleanup
        (Get-Kilobytes) | Should -Be 14
        $script:OwnerCleanups | Should -Be 3
        $null = New-File (P $script:Cache '_cacache' 'gone.bin') 4096
        Remove-Variable -Name TotalSizeCleaned, OwnerCleanups -Scope Script
        Invoke-NpmCleanup
        (Get-Kilobytes) | Should -Be 4
        $script:OwnerCleanups | Should -Be 1
        $null = New-File (P $script:Cache '_cacache' 'gone.bin') 4096
        $script:TotalSizeCleaned = 'abc'
        $script:OwnerCleanups = 'abc'
        Invoke-NpmCleanup
        (Get-Kilobytes) | Should -Be 4
        $script:OwnerCleanups | Should -Be 1
    }

    It 'CD-19 leaves FilesCleaned and TotalItems as they are, whatever the removed bytes' {
        $script:FilesCleaned = 7
        $script:TotalItems = 9
        Invoke-NpmCleanup
        $script:FilesCleaned | Should -Be 7
        $script:TotalItems | Should -Be 9
    }

    It 'CD-16 names the tool without path and extension in the command line when the name has a path, and gives the name unchanged to the command' {
        # A folder that carries the characteristic of every tool, so that the name of the tool does not matter for the checks.
        $every = New-NpmCache (P $script:Local 'v3')
        $null = New-File (P $every 'http' 'a.bin') 10
        $null = New-File (P $every 'README') 10
        $script:Cache = $every
        $script:QueryAnswers = @($every)
        foreach ($case in @(@{ Name = (P $script:Work 'tools' 'npm.cmd') }, @{ Name = (P $script:Work 'tools' 'npm.ps1') }, @{ Name = (P $script:Work 'tools' 'npm.exe') })) {
            $script:Ops.Clear()
            $script:Commands.Clear()
            $null = New-File (P $script:Cache '_cacache' 'gone.bin') 4096
            Invoke-SwOwnerCacheCleanup -Name $case.Name -Query @('config', 'get', 'cache') -Arguments @('cache', 'clean', '--force') -Description 'npm cache'
            (Get-OpsOf 'OWNER')[0].Detail | Should -BeExactly 'npm cache clean --force'
            (Get-Mutations)[0].Name | Should -BeExactly $case.Name
        }
    }

    It 'CD-16 gives the name unchanged when it has no path: pnpm runs "pnpm store prune"' {
        $store = New-PlainCache (P $script:Work 'pnpm' 'store' 'v3')
        $script:QueryAnswers = @($store)
        Invoke-SwOwnerCacheCleanup -Name 'pnpm' -Query @('store', 'path') -Arguments @('store', 'prune') -Description 'pnpm store'
        (Get-OpsOf 'OWNER')[0].Detail | Should -BeExactly 'pnpm store prune'
    }

    It 'CD-16 a failing log writer changes neither the result nor the statistics' {
        Mock Write-SwOperation { throw 'the log is locked' }
        { Invoke-NpmCleanup } | Should -Not -Throw
        [int]$script:OwnerCleanups | Should -Be 1
        (Get-Kilobytes) | Should -Be 4
    }
}

Describe 'CD-14 the checks of a real run before the command' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -NoNet
        Initialize-OwnerCase $false
    }
    AfterEach { Stop-Case }

    It 'CD-14 starts no command when the second query gives another folder or nothing: "not verified", no log line, no count' -ForEach @(
        @{ Label = 'another folder'; Second = 'other' }, @{ Label = 'nothing'; Second = '' }) {
        $other = if ($Second -eq 'other') { New-NpmCache (P $script:Work 'npm-other') } else { $null }
        $script:QueryAnswers = @($script:Cache, $other)
        Invoke-NpmCleanup
        @(Get-Mutations).Count | Should -Be 0
        $script:Ops.Count | Should -Be 0
        [int]$script:OwnerCleanups | Should -Be 0
        (Get-Kilobytes) | Should -Be 0
        (Get-NpmNotMeasured)[0].Reason | Should -Be 'not verified'
        [System.IO.File]::Exists((P $script:Cache '_cacache' 'gone.bin')) | Should -BeTrue
    }

    It 'CD-14 goes on when the second query differs only in case' {
        $script:QueryAnswers = @($script:Cache, $script:Cache.ToUpperInvariant())
        Invoke-NpmCleanup
        @(Get-Mutations).Count | Should -Be 1
    }

    It 'CD-14 starts no command when a file appeared between the two listings: an entry that was not in the first listing ends the run' {
        $script:TreeRuns = 0
        Mock Get-SwSafeDirectoryTreeItems {
            $script:TreeCalls++
            $script:TreeRuns++
            if ($script:TreeRuns -eq 2) { $null = New-File (P $script:Cache '_cacache' 'late.bin') 10 }
            & $script:RealTree -Path $Path -WhitelistState $WhitelistState
        }
        Invoke-NpmCleanup
        @(Get-Mutations).Count | Should -Be 0
        $script:Ops.Count | Should -Be 0
        [int]$script:OwnerCleanups | Should -Be 0
    }

    It 'CD-14 starts no command when the fresh listing fails (Success $false)' {
        $script:TreeRuns = 0
        Mock Get-SwSafeDirectoryTreeItems {
            $script:TreeCalls++
            $script:TreeRuns++
            if ($script:TreeRuns -eq 2) { return @{ Success = $false; Items = @(); RootSnapshot = $null; Reason = 'cannot list' } }
            & $script:RealTree -Path $Path -WhitelistState $WhitelistState
        }
        Invoke-NpmCleanup
        @(Get-Mutations).Count | Should -Be 0
        [int]$script:OwnerCleanups | Should -Be 0
    }

    It 'CD-14 starts no command when an entry was replaced after the first listing (identity of an item)' {
        $script:OnQuery = { param($count) if ($count -eq 2) { $script:FakeReplaced.Add((P $script:Cache 'kept.bin')) } }
        Invoke-NpmCleanup
        @(Get-Mutations).Count | Should -Be 0
        [int]$script:OwnerCleanups | Should -Be 0
    }

    It 'CD-14 starts no command when the folder itself was replaced after the first check (identity of the root)' {
        $script:OnQuery = { param($count) if ($count -eq 2) { $script:FakeReplaced.Add($script:Cache) } }
        Invoke-NpmCleanup
        @(Get-Mutations).Count | Should -Be 0
        [int]$script:OwnerCleanups | Should -Be 0
    }

    It 'CD-14 starts no command when the whitelist grew between the checks: the state is read again for the real run' {
        $script:OnQuery = { param($count) if ($count -eq 2) { Set-Whitelist @((P $script:Cache 'kept.bin')) } }
        Invoke-NpmCleanup
        @(Get-Mutations).Count | Should -Be 0
        [int]$script:OwnerCleanups | Should -Be 0
        $script:Ops.Count | Should -Be 0
    }

    It 'CD-14 CD-31 starts no command and notes "incomplete scan" when the time budget of the second check is used up' {
        $items = @((New-TreeItem (P $script:Cache 'kept.bin')), (New-TreeItem (P $script:Cache '_cacache' 'gone.bin')))
        Use-FixedTree $items
        $script:SwWalkBudgetSeconds = 0
        Invoke-NpmCleanup
        @(Get-Mutations).Count | Should -Be 0
        [int]$script:OwnerCleanups | Should -Be 0
        $note = Get-NpmNotMeasured
        $note.Count | Should -Be 1
        $note[0].Reason | Should -Be 'incomplete scan'
    }

    It 'CD-14 runs the command with the same checks when the budget is long enough (control for the budget case)' {
        $items = @((New-TreeItem (P $script:Cache 'kept.bin')), (New-TreeItem (P $script:Cache '_cacache' 'gone.bin')))
        Use-FixedTree $items
        $script:SwWalkBudgetSeconds = 15
        Invoke-NpmCleanup
        @(Get-Mutations).Count | Should -Be 1
    }

    It 'CD-14 CD-5 asks Test-SwSafePath for the root and for every item with one whitelist state in the real run' {
        $script:Checked = [System.Collections.Generic.List[object]]::new()
        $real = (Get-Command -Name Test-SwSafePath -CommandType Function).ScriptBlock
        $script:RealSafe = $real
        Mock Test-SwSafePath {
            $script:Checked.Add([pscustomobject]@{ Path = $Path; HasState = $PesterBoundParameters.ContainsKey('WhitelistState') })
            & $script:RealSafe -Path $Path -WhitelistState $WhitelistState
        }
        Invoke-NpmCleanup
        $withState = @($script:Checked | Where-Object { $_.HasState })
        @($withState | ForEach-Object { Fold $_.Path }) | Should -Contain (Fold $script:Cache)
        @($withState | ForEach-Object { Fold $_.Path }) | Should -Contain (Fold (P $script:Cache 'kept.bin'))
        @($withState | ForEach-Object { Fold $_.Path }) | Should -Contain (Fold (P $script:Cache '_cacache' 'gone.bin'))
        $script:WlReads | Should -Be 4
    }
}

Describe 'CD-18 a command that does not succeed' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -NoNet
        Initialize-OwnerCase $false
        $script:OnCommand = { param($Outcome) $Outcome['Reason'] = 'timed out after 120 s'; $null }
    }
    AfterEach { Stop-Case }

    It 'CD-18 writes one FAILED line with the command line, incomplete and the reason, counts nothing, reports no activity and no success' {
        Invoke-NpmCleanup
        $failed = @(Get-OpsOf 'FAILED')
        $failed.Count | Should -Be 1
        $failed[0].Path | Should -BeExactly $script:Cache
        $failed[0].Detail | Should -BeExactly 'npm cache clean --force: incomplete; timed out after 120 s'
        @(Get-OpsOf 'OWNER').Count | Should -Be 0
        $script:Ops.Count | Should -Be 1
        [int]$script:OwnerCleanups | Should -Be 0
        (Get-Kilobytes) | Should -Be 0
        $script:FilesCleaned | Should -Be 0
        $script:Activity | Should -Be 0
        @(Get-LogLines 'SUCCESS').Count | Should -Be 0
        @(Get-LogLines 'DEBUG').Count | Should -BeGreaterThan 0
    }

    It 'CD-18 keeps the whole reason of a timeout with the process tree evidence' {
        $script:OnCommand = { param($Outcome) $Outcome['Reason'] = 'timed out after 120 s; process tree 4242 terminated'; $null }
        Invoke-NpmCleanup
        (Get-OpsOf 'FAILED')[0].Detail | Should -BeExactly 'npm cache clean --force: incomplete; timed out after 120 s; process tree 4242 terminated'
    }

    It 'CD-18 ends the line with ": incomplete" and no semicolon when the command gave no reason: <Label>' -ForEach @(
        @{ Label = 'the key is not set'; Set = $false }, @{ Label = 'the reason is an empty text'; Set = $true }) {
        $script:SetReason = $Set
        $script:OnCommand = { param($Outcome) if ($script:SetReason) { $Outcome['Reason'] = '' }; $null }
        Invoke-NpmCleanup
        (Get-OpsOf 'FAILED')[0].Detail | Should -BeExactly 'npm cache clean --force: incomplete'
    }

    It 'CD-18 CD-5 never falls back to removing the folder, never repeats the command and leaves the files' {
        Invoke-NpmCleanup
        $script:Calls.Count | Should -Be 0
        @(Get-Mutations).Count | Should -Be 1
        [System.IO.File]::Exists((P $script:Cache '_cacache' 'gone.bin')) | Should -BeTrue
        [System.IO.File]::Exists((P $script:Cache 'kept.bin')) | Should -BeTrue
    }

    It 'CD-18 writes no FAILED line in a preview, because a preview starts no command' {
        $script:SweeprDryRunMode = $true
        Invoke-NpmCleanup
        $script:Ops.Count | Should -Be 0
        @(Get-Mutations).Count | Should -Be 0
    }

    It 'CD-18 writes no FAILED line for a refused folder: nothing was started' {
        Set-Whitelist @($script:Cache)
        Invoke-NpmCleanup
        $script:Ops.Count | Should -Be 0
    }

    It 'CD-4 CD-18 throws nothing and gives nothing to the pipeline when the command throws, and writes no OWNER line' {
        $script:OnCommand = { param($Outcome) throw 'the command broke' }
        { Invoke-NpmCleanup } | Should -Not -Throw
        (Invoke-Captured { Invoke-NpmCleanup }).Count | Should -Be 0
        @(Get-OpsOf 'OWNER').Count | Should -Be 0
        [int]$script:OwnerCleanups | Should -Be 0
    }

    It 'CD-18 a failing log writer changes neither the result nor the statistics, and does not throw' {
        Mock Write-SwOperation { throw 'the log is locked' }
        { Invoke-NpmCleanup } | Should -Not -Throw
        [int]$script:OwnerCleanups | Should -Be 0
    }

    It 'CD-18 gives the same line for another tool: go runs "go clean -cache" and fails' {
        $folder = P $script:Work 'go-build'
        $null = New-File (P $folder 'README') 10
        $null = New-File (P $folder '01' 'x.bin') 100
        $script:QueryAnswers = @($folder)
        Invoke-SwOwnerCacheCleanup -Name 'go' -Query @('env', 'GOCACHE') -Arguments @('clean', '-cache') -Description 'Go build cache'
        (Get-OpsOf 'FAILED')[0].Detail | Should -BeExactly 'go clean -cache: incomplete; timed out after 120 s'
    }
}

Describe 'CD-14 the owner path inside the groups: one root per run, the statistics of a whole section' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -NoNet
        Initialize-OwnerCase $false
    }
    AfterEach { Stop-Case }

    It 'CD-14 CD-16 a group run gives the same counters and log lines as a direct call: Clear-SwNpmFamilyCaches with npm only' {
        $script:QueryByName['npm'] = $script:Cache
        Clear-SwNpmFamilyCaches
        @(Get-Mutations | ForEach-Object { $_.Name }) | Should -Be @('npm')
        [int]$script:OwnerCleanups | Should -Be 1
        (Get-Kilobytes) | Should -Be 4
        @(Get-OpsOf 'OWNER').Count | Should -Be 1
    }

    It 'CD-14 CD-18 a tool that fails does not stop the tool behind it: pnpm runs after a failed npm' {
        $second = New-PlainCache (P $script:Work 'pnpm' 'store' 'v3')
        $script:QueryByName['npm'] = $script:Cache
        $script:QueryByName['pnpm'] = $second
        $script:OnCommand = {
            param($Outcome)
            if ($script:Commands[$script:Commands.Count - 1].Name -eq 'npm') { $Outcome['Reason'] = 'exit code 1'; return $null }
            [pscustomobject]@{ Output = '' }
        }
        Clear-SwNpmFamilyCaches
        @(Get-Mutations | ForEach-Object { $_.Name }) | Should -Be @('npm', 'pnpm')
        @(Get-OpsOf 'FAILED').Count | Should -Be 1
        @(Get-OpsOf 'OWNER').Count | Should -Be 1
        [int]$script:OwnerCleanups | Should -Be 1
    }

    It 'CD-6 CD-14 a section run in a preview starts no mutation and makes no log line, for npm, pip and go together' {
        $script:SweeprDryRunMode = $true
        $pip = P $script:Work 'pip-cache'
        $null = New-File (P $pip 'http' 'a.bin') 100
        $go = P $script:Work 'go-build'
        $null = New-File (P $go 'README') 10
        $script:QueryByName['npm'] = $script:Cache
        $script:QueryByName['pip'] = $pip
        $script:QueryByName['go'] = $go
        Use-Collectors
        Invoke-SwDevCleanup
        @(Get-Mutations).Count | Should -Be 0
        $script:Ops.Count | Should -Be 0
        [int]$script:OwnerCleanups | Should -Be 3
        (Get-Kilobytes) | Should -Be 0
        @($script:DryRunCollector | Where-Object { $_.Count -eq 0 -and $_.SizeBytes -eq 0 }).Count | Should -Be 3
    }
}

Describe 'CD-14 CD-15 the calls of Invoke-SwOwnerCommand for one owner path, with the real query function' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -ProcessNetOnly
        $script:Cache = New-NpmCache (P $script:Work 'npm-cache')
        $script:Seen = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-SwOwnerCommand {
            $script:Seen.Add([pscustomobject]@{ Name = $Name; Arguments = @($Arguments); Mutation = [bool]$Mutation; HasTimeout = $PesterBoundParameters.ContainsKey('TimeoutSeconds')
                    TimeoutSeconds = $TimeoutSeconds; HasOutcome = $PesterBoundParameters.ContainsKey('Outcome') })
            if ($Mutation) {
                $gone = P $script:Cache '_cacache' 'gone.bin'
                if ([System.IO.File]::Exists($gone)) { [System.IO.File]::Delete($gone) }
                return [pscustomobject]@{ Output = '' }
            }
            [pscustomobject]@{ Output = [string]$script:Answer }
        }
        $script:Answer = $script:Cache
    }
    AfterEach { Stop-Case }

    It 'CD-14 asks the command three times in a real run: the query, the query again, then the mutation with -Mutation, the limit 120 and an outcome table' {
        $script:SweeprDryRunMode = $false
        Invoke-NpmCleanup
        $script:Seen.Count | Should -Be 3
        @($script:Seen | ForEach-Object { $_.Mutation }) | Should -Be @($false, $false, $true)
        foreach ($query in @($script:Seen[0], $script:Seen[1])) {
            $query.Name | Should -Be 'npm'
            ($query.Arguments -join ' ') | Should -Be 'config get cache'
            $query.HasTimeout | Should -BeFalse
        }
        ($script:Seen[2].Arguments -join ' ') | Should -Be 'cache clean --force'
        $script:Seen[2].TimeoutSeconds | Should -Be 120
        $script:Seen[2].HasOutcome | Should -BeTrue
        [int]$script:OwnerCleanups | Should -Be 1
    }

    It 'CD-15 asks the command once in a preview: the query only, no mutation' {
        $script:SweeprDryRunMode = $true
        Invoke-NpmCleanup
        $script:Seen.Count | Should -Be 1
        $script:Seen[0].Mutation | Should -BeFalse
        [int]$script:OwnerCleanups | Should -Be 1
    }

    It 'CD-14 asks the command once when the folder is refused before the command: a whitelisted folder' {
        Set-Whitelist @($script:Cache)
        $script:SweeprDryRunMode = $false
        Invoke-NpmCleanup
        $script:Seen.Count | Should -Be 1
        [int]$script:OwnerCleanups | Should -Be 0
    }

    It 'CD-14 asks the command once and starts nothing when the answer is not a plausible folder' {
        $script:Answer = 'npm ERR! no cache'
        $script:SweeprDryRunMode = $false
        Invoke-NpmCleanup
        $script:Seen.Count | Should -Be 1
        $script:Seen[0].Mutation | Should -BeFalse
    }
}

Describe 'CD-12 CD-18 a tool script that does not load ends in a FAILED line with the real command' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -NoNet -RealProcess
        $script:SweeprDryRunMode = $false
        $script:Cache = New-NpmCache (P $script:Work 'npm-cache')
        Mock Get-SwOwnerCachePath { $script:Cache }
        $folder = New-Dir (P $script:Work 'broken tools')
        [System.IO.File]::WriteAllText((P $folder 'npm.ps1'), 'if ( {', $script:Utf8)
        $script:Broken = P $folder 'npm.ps1'
    }
    AfterEach { Stop-Case }

    It 'CD-18 writes one FAILED line with "exit code", no OWNER line and counts nothing' {
        Invoke-SwOwnerCacheCleanup -Name $script:Broken -Query @('config', 'get', 'cache') -Arguments @('cache', 'clean', '--force') -Description 'npm cache'
        $failed = @($script:Ops | Where-Object { $_.Action -ceq 'FAILED' })
        $failed.Count | Should -Be 1
        $failed[0].Detail | Should -Match '^npm cache clean --force: incomplete; exit code [1-9]'
        @($script:Ops | Where-Object { $_.Action -ceq 'OWNER' }).Count | Should -Be 0
        [int]$script:OwnerCleanups | Should -Be 0
        [System.IO.File]::Exists((P $script:Cache '_cacache' 'gone.bin')) | Should -BeTrue
    }
}
