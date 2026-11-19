# Sweepr - tests for Get-SwBoundedFileScan in lib\clean\dev.ps1: the bounded search of the file rows
# (Stack, conda, Office, Drive and game media): its result table, filters, age rule, time budget, links,
# unreadable folders and the old name Get-FilesWithinBudget.
#
# The rule numbers in the test names (CD-, CA-, S- and so on) number the rules and the safety invariants
# of the behavior of the developer tool and application cleanup; each rule and invariant has at least one test.
# The other files of this slice are SwCleanDevGroups, SwCleanDevLoad, SwCleanDevOwnerPath, SwCleanDevOwnerRun,
# SwCleanDevProcess, SwCleanDevEditors, SwCleanAppsGroups, SwCleanAppsMedia and SwCleanDevAppsSafety.
#
# Interface pinned here (lib\clean\dev.ps1, loaded by dot-sourcing):
#   Get-SwBoundedFileScan -Root <string> [-Filter <string> = '*'] [-Extensions <string[]>] [-OlderThan <datetime>]
#                         [-TimeoutSeconds <int>] [-NoRecurse]
#       gives one table with the keys Files (string[] of full paths, files only) and Complete (bool); both keys
#       are always there; Files is empty when Complete is $false; never throws, writes nothing else.
#   Old name: Get-FilesWithinBudget -Root -Filter -TimeoutSeconds (positions 0 to 2, default 15)
#
# Seams used with Mock: Test-SwSafePath and the removal helpers (they must not be called by the search), Get-Date is
# not mocked; ages are set on real files below $TestDrive. $script:SwWalkBudgetSeconds is replaced per case.
#
# Platform notes:
#   - On Linux the creation time of a file follows its write time, so a file whose creation time and write
#     time differ cannot be made there: the cases for the newer of the two times are marked [W].
#   - Links are symbolic links on Linux and junctions on Windows; a case that cannot create one is skipped.
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
    # The system folder variables of this process, read before any case points them at a fake folder: Windows
    # PowerShell 5.1 does not start without them, so every child PowerShell gets the real values.
    $script:RealSystemEnv = @{}
    foreach ($systemName in 'SystemRoot', 'windir') {
        $systemValue = [System.Environment]::GetEnvironmentVariable($systemName)
        if (-not [string]::IsNullOrEmpty($systemValue)) { $script:RealSystemEnv[$systemName] = $systemValue }
    }

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
    # Name, kind, length, attributes and time stamps of everything below a folder. The first pass only lets
    # every folder be opened and closed once: Windows brings the entry of a folder in its parent up to date
    # when the folder is closed, so a listing made right after a fixture was built can differ from the next
    # one although nothing was changed. The rows of the second pass count.
    $script:ListingRoot = ''
    function script:Get-Listing([string]$Root) {
        if (-not [System.IO.Directory]::Exists($Root)) { return , @('<missing>') }
        $script:ListingRoot = $Root
        $rows = $null
        foreach ($pass in 1, 2) {
            $rows = [System.Collections.Generic.List[string]]::new()
            foreach ($item in @(Get-ChildItem -LiteralPath $Root -Recurse -Force)) {
                $rel = $item.FullName.Substring($Root.Length)
                if ($item.PSIsContainer) { $rows.Add(('D {0} {1} {2}' -f $rel, [int]$item.Attributes, $item.LastWriteTimeUtc.Ticks)) }
                else { $rows.Add(('F {0} {1} {2} {3}' -f $rel, $item.Length, [int]$item.Attributes, $item.LastWriteTimeUtc.Ticks)) }
            }
        }
        , @($rows | Sort-Object)
    }
    # True when both listings are the same. Otherwise it throws and names the rows that differ and what a
    # new listing of the folder shows, so a failure tells a change of the tree from a late update.
    function script:Same-Listing($Left, $Right) {
        $after = @($Left)
        $before = @($Right)
        if (($after -join '|') -ceq ($before -join '|')) { return $true }
        $gone = @($before | Where-Object { $after -cnotcontains $_ })
        $new = @($after | Where-Object { $before -cnotcontains $_ })
        $again = 'not asked'
        if (-not [string]::IsNullOrEmpty($script:ListingRoot)) {
            $third = Get-Listing $script:ListingRoot
            if (($third -join '|') -ceq ($after -join '|')) { $again = 'a new listing equals the listing after' }
            elseif (($third -join '|') -ceq ($before -join '|')) { $again = 'a new listing equals the listing before' }
            else { $again = 'a new listing differs from both' }
        }
        throw ('The file tree is not as it was. Rows only before: [' + ($gone -join ' ## ') + ']. Rows only after: [' + ($new -join ' ## ') + ']. ' + $again + '.')
    }
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
        if ($RealProcess) { foreach ($systemName in @($script:RealSystemEnv.Keys)) { Set-Env $systemName $script:RealSystemEnv[$systemName] } }
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
        foreach ($name in @($script:RealSystemEnv.Keys)) { $psi.EnvironmentVariables[$name] = [string]$script:RealSystemEnv[$name] }
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

    function script:Get-ScanFiles($Result) { @($Result.Files | ForEach-Object { [string]$_ }) }
    function script:Get-Names($Result) { @(Get-ScanFiles $Result | ForEach-Object { [System.IO.Path]::GetFileName($_) } | Sort-Object) }
    function script:New-ScanTree {
        $script:Root = New-Dir (P $script:Work 'scan root')
        $null = New-File (P $script:Root 'a.tmp') 5
        $null = New-File (P $script:Root 'pkg' 'b.tmp') 5
        $null = New-File (P $script:Root 'pkg' 'c.tar.gz') 5
        $null = New-File (P $script:Root 'pkg' 'deep' 'd.TMP') 5
        $null = New-Dir (P $script:Root 'folder.tmp')
        $script:Root
    }
}

AfterAll {
    Clear-TestLinks
    Restore-Env $script:RootEnv
    Restore-State $script:RootState
    [System.Environment]::CurrentDirectory = $script:RootDirectory
    try { Set-Location -LiteralPath $script:RootLocation } catch { $null = $_ }
}
Describe 'CD-8 Get-SwBoundedFileScan: result table, filters and recursion' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -NoNet -Real
        $null = New-ScanTree
    }
    AfterEach { Stop-Case }

    It 'CD-8 gives the function with the parameters Root, Filter (default *), Extensions, OlderThan, TimeoutSeconds and the switch NoRecurse' {
        Assert-Defined @('Get-SwBoundedFileScan')
        (Get-ParamLine 'Get-SwBoundedFileScan' 'Root') | Should -BeLike 'Root|System.String|*'
        (Get-ParamLine 'Get-SwBoundedFileScan' 'Filter') | Should -BeLike "Filter|System.String|*|default='*'"
        (Get-ParamLine 'Get-SwBoundedFileScan' 'Extensions') | Should -BeLike 'Extensions|System.String`[`]|*'
        (Get-ParamLine 'Get-SwBoundedFileScan' 'OlderThan') | Should -BeLike 'OlderThan|System.DateTime|*'
        (Get-ParamLine 'Get-SwBoundedFileScan' 'TimeoutSeconds') | Should -BeLike 'TimeoutSeconds|System.Int32|*'
        (Get-ParamLine 'Get-SwBoundedFileScan' 'NoRecurse') | Should -BeLike 'NoRecurse|System.Management.Automation.SwitchParameter|*'
    }

    It 'CD-8 gives one table with Files and Complete, Files as strings with full paths, Complete as a bool' {
        $result = Get-SwBoundedFileScan -Root $script:Root
        $result | Should -BeOfType [hashtable]
        $result.ContainsKey('Files') | Should -BeTrue
        $result.ContainsKey('Complete') | Should -BeTrue
        $result.Complete | Should -BeOfType [bool]
        $result.Complete | Should -BeTrue
        foreach ($file in @($result.Files)) {
            $file | Should -BeOfType [string]
            [System.IO.Path]::IsPathRooted($file) | Should -BeTrue
            [System.IO.File]::Exists($file) | Should -BeTrue
        }
    }

    It 'CD-8 lists every file below the root with the default filter, and no folder' {
        $result = Get-SwBoundedFileScan -Root $script:Root
        (Get-Names $result) | Should -Be @('a.tmp', 'b.tmp', 'c.tar.gz', 'd.TMP')
        foreach ($file in (Get-ScanFiles $result)) { [System.IO.Directory]::Exists($file) | Should -BeFalse -Because $file }
    }

    It 'CD-8 uses the filter as a name filter without regard to case: *.tmp gives a.tmp, b.tmp and d.TMP, not c.tar.gz' {
        $result = Get-SwBoundedFileScan -Root $script:Root -Filter '*.tmp'
        (Get-Names $result) | Should -Be @('a.tmp', 'b.tmp', 'd.TMP')
        $result.Complete | Should -BeTrue
    }

    It 'CD-8 gives the example of the table: pkg\a.tmp and pkg\b.tar.gz with the filter *.tmp give only a.tmp' {
        $root = New-Dir (P $script:Work 'example')
        $tmp = New-File (P $root 'pkg' 'a.tmp') 3
        $null = New-File (P $root 'pkg' 'b.tar.gz') 3
        $result = Get-SwBoundedFileScan -Root $root -Filter '*.tmp'
        @(Get-ScanFiles $result | ForEach-Object { Fold $_ }) | Should -Be @((Fold $tmp))
        $result.Complete | Should -BeTrue
    }

    It 'CD-8 lists a folder named like the filter never: a folder x.tmp is not delivered, its files are when they match' {
        $null = New-File (P $script:Root 'x.tmp' 'inside.tmp') 3
        $result = Get-SwBoundedFileScan -Root $script:Root -Filter '*.tmp'
        @(Get-ScanFiles $result | Where-Object { [System.IO.Directory]::Exists($_) }).Count | Should -Be 0
        (Get-Names $result) | Should -Contain 'inside.tmp'
    }

    It 'CD-8 with -NoRecurse lists only the files directly in the root' {
        $result = Get-SwBoundedFileScan -Root $script:Root -Filter '*.tmp' -NoRecurse
        (Get-Names $result) | Should -Be @('a.tmp')
        $result.Complete | Should -BeTrue
    }

    It 'CD-8 counts hidden files: a hidden file directly in the root is delivered' {
        $name = '.hidden.tmp'
        $path = New-File (P $script:Root $name) 3
        if ($script:OnWindows) { [System.IO.File]::SetAttributes($path, [System.IO.FileAttributes]::Hidden) }
        (Get-Names (Get-SwBoundedFileScan -Root $script:Root -Filter '*.tmp' -NoRecurse)) | Should -Contain $name
    }

    It 'CD-8 reads names literally: brackets and wildcard characters in a folder name are part of the name' {
        $root = New-Dir (P $script:Work 'Ex [1]')
        $null = New-File (P $root 'a.tmp') 3
        $null = New-Dir (P $script:Work 'Ex 1')
        $null = New-File (P $script:Work 'Ex 1' 'other.tmp') 3
        $result = Get-SwBoundedFileScan -Root $root -Filter '*.tmp'
        (Get-Names $result) | Should -Be @('a.tmp')
        foreach ($file in (Get-ScanFiles $result)) { Test-Under $file $root | Should -BeTrue }
    }

    It 'CD-8 limits to the extensions, with a leading dot and without regard to case: .MP4 matches clip.mp4 and clip2.MP4, not clip.txt' {
        $root = New-Dir (P $script:Work 'media')
        foreach ($name in 'clip.mp4', 'clip2.MP4', 'photo.JPG', 'notes.txt', 'noext') { $null = New-File (P $root 'sub' $name) 3 }
        $result = Get-SwBoundedFileScan -Root $root -Extensions @('.MP4', '.jpg')
        (Get-Names $result) | Should -Be @('clip.mp4', 'clip2.MP4', 'photo.JPG')
        (Get-Names (Get-SwBoundedFileScan -Root $root)) | Should -Be @('clip.mp4', 'clip2.MP4', 'noext', 'notes.txt', 'photo.JPG') -Because 'no extension filter means all files'
    }

    It 'CD-8 combines the name filter and the extensions: both must match' {
        $root = New-Dir (P $script:Work 'media2')
        foreach ($name in 'clip.mp4', 'clip.png', 'other.mp4') { $null = New-File (P $root $name) 3 }
        (Get-Names (Get-SwBoundedFileScan -Root $root -Filter 'clip*' -Extensions @('.mp4'))) | Should -Be @('clip.mp4')
    }

    It 'CD-8 writes nothing to the pipeline besides the table, throws nothing and changes nothing on disk' {
        $before = Get-Listing $script:Root
        $out = Invoke-Captured { Get-SwBoundedFileScan -Root $script:Root -Filter '*.tmp' }
        $out.Count | Should -Be 1
        Same-Listing (Get-Listing $script:Root) $before | Should -BeTrue
    }

    It 'CD-8 CD-5 checks no protection rule and removes nothing: no call of Test-SwSafePath and no removal helper' {
        Mock Test-SwSafePath { throw 'the search must not ask the protection rules' }
        Mock Remove-SwItems { throw 'the search must not remove' }
        Mock Remove-SwOldFiles { throw 'the search must not remove' }
        Mock Clear-SwDirectoryContents { throw 'the search must not remove' }
        $result = Get-SwBoundedFileScan -Root $script:Root -Filter '*.tmp'
        $result.Complete | Should -BeTrue
        Should -Invoke Test-SwSafePath -Times 0 -Exactly
    }
}

Describe 'CD-8 Get-SwBoundedFileScan: age' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -NoNet -Real
        $script:Root = New-Dir (P $script:Work 'age')
    }
    AfterEach { Stop-Case }

    It 'CD-8 delivers with -OlderThan only the files whose time is strictly before the limit' {
        $null = New-OldFile (P $script:Root 'old.bin') 200
        $null = New-OldFile (P $script:Root 'sub' 'older.bin') 100
        $null = New-OldFile (P $script:Root 'fresh.bin') 1
        $result = Get-SwBoundedFileScan -Root $script:Root -OlderThan ([datetime]::Now.AddDays(-90))
        (Get-Names $result) | Should -Be @('old.bin', 'older.bin')
        $result.Complete | Should -BeTrue
    }

    It 'CD-8 delivers no age filter without -OlderThan: a file of today is delivered' {
        $null = New-OldFile (P $script:Root 'old.bin') 200
        $null = New-File (P $script:Root 'fresh.bin') 3
        (Get-Names (Get-SwBoundedFileScan -Root $script:Root)) | Should -Be @('fresh.bin', 'old.bin')
    }

    It 'CD-8 treats a file exactly at the limit as not old: the time must be strictly smaller' {
        $path = New-File (P $script:Root 'edge.bin') 3
        $time = [datetime]::Now.AddDays(-30)
        [System.IO.File]::SetCreationTime($path, $time)
        [System.IO.File]::SetLastWriteTime($path, $time)
        $stamp = [System.IO.File]::GetLastWriteTime($path)
        @(Get-Names (Get-SwBoundedFileScan -Root $script:Root -OlderThan $stamp)).Count | Should -Be 0
        (Get-Names (Get-SwBoundedFileScan -Root $script:Root -OlderThan $stamp.AddSeconds(2))) | Should -Be @('edge.bin')
    }

    It 'CD-8 [W] uses the newer of CreationTime and LastWriteTime: written 200 days ago and created yesterday is not old' {
        $path = New-File (P $script:Root 'copied.bin') 3
        Set-Times $path 1 200
        [System.IO.File]::GetLastWriteTime($path) | Should -BeLessThan ([datetime]::Now.AddDays(-150)) -Because 'the fixture needs a write time of 200 days ago'
        [System.IO.File]::GetCreationTime($path) | Should -BeGreaterThan ([datetime]::Now.AddDays(-5)) -Because 'the fixture needs a creation time of yesterday'
        @(Get-Names (Get-SwBoundedFileScan -Root $script:Root -OlderThan ([datetime]::Now.AddDays(-90)))).Count | Should -Be 0
    }

    It 'CD-8 [W] delivers a file whose creation time and write time are both old' {
        $path = New-File (P $script:Root 'both.bin') 3
        Set-Times $path 200 150
        (Get-Names (Get-SwBoundedFileScan -Root $script:Root -OlderThan ([datetime]::Now.AddDays(-90)))) | Should -Be @('both.bin')
    }
}

Describe 'CD-8 Get-SwBoundedFileScan: order of the checks, budget, links and unreadable folders' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -NoNet -Real
        $script:Root = New-Dir (P $script:Work 'budget')
        $null = New-File (P $script:Root 'a.tmp') 3
    }
    AfterEach { Stop-Case }

    It 'CD-8 gives Complete $false and no files for -TimeoutSeconds 0, also for a root that does not exist (the budget is checked first)' {
        $result = Get-SwBoundedFileScan -Root $script:Root -TimeoutSeconds 0
        $result.Complete | Should -BeFalse
        @($result.Files).Count | Should -Be 0
        $missing = Get-SwBoundedFileScan -Root (P $script:Work 'does not exist') -TimeoutSeconds 0
        $missing.Complete | Should -BeFalse
        @($missing.Files).Count | Should -Be 0
    }

    It 'CD-8 uses $script:SwWalkBudgetSeconds as the budget when no -TimeoutSeconds is given: 0 means always used up' {
        $script:SwWalkBudgetSeconds = 0
        $result = Get-SwBoundedFileScan -Root $script:Root
        $result.Complete | Should -BeFalse
        @($result.Files).Count | Should -Be 0
        (Get-SwBoundedFileScan -Root (P $script:Work 'does not exist')).Complete | Should -BeFalse
    }

    It 'CD-8 lets -TimeoutSeconds win over the script variable' {
        $script:SwWalkBudgetSeconds = 0
        $result = Get-SwBoundedFileScan -Root $script:Root -TimeoutSeconds 15
        $result.Complete | Should -BeTrue
        (Get-Names $result) | Should -Be @('a.tmp')
    }

    It 'CD-8 takes 15 seconds when the script variable does not exist (strict mode must not break the read)' {
        Remove-Variable -Name SwWalkBudgetSeconds -Scope Script -ErrorAction SilentlyContinue
        $result = Get-SwBoundedFileScan -Root $script:Root
        $result.Complete | Should -BeTrue
        (Get-Names $result) | Should -Be @('a.tmp')
    }

    It 'CD-8 gives Complete $true and no files for a root that does not exist, with a budget of 15 seconds' {
        $result = Get-SwBoundedFileScan -Root (P $script:Work 'does not exist') -TimeoutSeconds 15
        $result.Complete | Should -BeTrue
        @($result.Files).Count | Should -Be 0
    }

    It 'CD-8 gives Complete $false and no files for a root that is a file' {
        $file = New-File (P $script:Work 'plain.tmp') 3
        $result = Get-SwBoundedFileScan -Root $file
        $result.Complete | Should -BeFalse
        @($result.Files).Count | Should -Be 0
    }

    It 'CD-8 gives Complete $false and no files for a root that is a link, and does not look into the target' {
        $target = New-Dir (P $script:Work 'target')
        $null = New-File (P $target 'x.tmp') 3
        $link = P $script:Work 'root link'
        if (-not (New-TestLink $link $target)) { Set-ItResult -Skipped -Because 'this host cannot create a link here'; return }
        $result = Get-SwBoundedFileScan -Root $link -Filter '*.tmp'
        $result.Complete | Should -BeFalse
        @($result.Files).Count | Should -Be 0
    }

    It 'CD-8 does not enter a folder that is a link and does not count it: x.tmp behind the link is missing, Complete stays $true' {
        $target = New-Dir (P $script:Work 'target 2')
        $null = New-File (P $target 'x.tmp') 3
        if (-not (New-TestLink (P $script:Root 'link') $target)) { Set-ItResult -Skipped -Because 'this host cannot create a link here'; return }
        $result = Get-SwBoundedFileScan -Root $script:Root -Filter '*.tmp'
        $result.Complete | Should -BeTrue
        (Get-Names $result) | Should -Be @('a.tmp')
    }

    It 'CD-8 does not deliver a file that is a link (file symbolic link, cloud placeholder)' {
        $real = New-File (P $script:Work 'elsewhere' 'real.tmp') 3
        if (-not (New-TestLink (P $script:Root 'linked.tmp') $real)) { Set-ItResult -Skipped -Because 'this host cannot create a file link here'; return }
        $result = Get-SwBoundedFileScan -Root $script:Root -Filter '*.tmp'
        (Get-Names $result) | Should -Be @('a.tmp')
        $result.Complete | Should -BeTrue
    }

    It 'CD-8 [W] does not deliver a cloud placeholder file, which has the reparse point attribute, and keeps Complete $true' {
        $path = New-File (P $script:Root 'placeholder.tmp') 3
        [System.IO.File]::SetAttributes($path, [System.IO.File]::GetAttributes($path) -bor [System.IO.FileAttributes]::ReparsePoint)
        if (([System.IO.File]::GetAttributes($path) -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) { Set-ItResult -Skipped -Because 'this host does not let a script set the reparse point attribute of a file'; return }
        $result = Get-SwBoundedFileScan -Root $script:Root -Filter '*.tmp'
        (Get-Names $result) | Should -Be @('a.tmp')
        $result.Complete | Should -BeTrue
    }

    It 'CD-8 gives no beginning of the tree: when a folder cannot be read the result is Complete $false and Files is empty' {
        if ($script:OnWindows) { Set-ItResult -Skipped -Because 'the folder permission is set through the Unix file mode'; return }
        $blocked = New-Dir (P $script:Root 'blocked')
        $null = New-File (P $blocked 'hidden.tmp') 3
        [System.IO.File]::SetUnixFileMode($blocked, [System.IO.UnixFileMode]::None)
        try {
            $readable = $true
            try { $null = [System.IO.Directory]::GetFiles($blocked) } catch { $readable = $false }
            if ($readable) { Set-ItResult -Skipped -Because 'this account can read a folder without permission'; return }
            $result = Get-SwBoundedFileScan -Root $script:Root -Filter '*.tmp'
            $result.Complete | Should -BeFalse
            @($result.Files).Count | Should -Be 0 -Because 'an incompletely read tree is unknown, a beginning is never delivered'
        }
        finally { [System.IO.File]::SetUnixFileMode($blocked, ([System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite -bor [System.IO.UnixFileMode]::UserExecute)) }
    }

    It 'CD-8 never throws for a root that is blank, relative or has a NUL character, and always gives both keys' {
        foreach ($root in '   ', 'relative/folder', ('bad' + [char]0 + 'name')) {
            $result = $null
            { $script:Out = Get-SwBoundedFileScan -Root $root } | Should -Not -Throw -Because ([string]$root)
            $result = $script:Out
            $result.ContainsKey('Files') | Should -BeTrue
            $result.ContainsKey('Complete') | Should -BeTrue
            @($result.Files).Count | Should -Be 0
        }
    }

    It 'CD-8 gives the same table under Stop, Continue and SilentlyContinue' {
        $tables = @{}
        foreach ($preference in 'Stop', 'Continue', 'SilentlyContinue') {
            $ErrorActionPreference = $preference
            $result = Get-SwBoundedFileScan -Root $script:Root -Filter '*.tmp'
            $tables[$preference] = ((Get-Names $result) -join ',') + '|' + $result.Complete
        }
        $tables['Continue'] | Should -Be $tables['Stop']
        $tables['SilentlyContinue'] | Should -Be $tables['Stop']
        $ErrorActionPreference = 'Stop'
    }
}

Describe 'CD-8 the old name Get-FilesWithinBudget forwards to Get-SwBoundedFileScan' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -NoNet -Real
        $script:Root = New-Dir (P $script:Work 'forward')
        $null = New-File (P $script:Root 'a.tmp') 3
        $null = New-File (P $script:Root 'b.log') 3
    }
    AfterEach { Stop-Case }

    It 'CD-8 keeps the old signature: Root, Filter and TimeoutSeconds at positions 0 to 2, TimeoutSeconds default 15, no switch and no other parameter' {
        (Get-ParamLine 'Get-FilesWithinBudget' 'Root') | Should -Be 'Root|System.String|pos=0|mandatory=False|default='
        (Get-ParamLine 'Get-FilesWithinBudget' 'Filter') | Should -Be 'Filter|System.String|pos=1|mandatory=False|default='
        (Get-ParamLine 'Get-FilesWithinBudget' 'TimeoutSeconds') | Should -Be 'TimeoutSeconds|System.Int32|pos=2|mandatory=False|default=15'
        (Get-ParamCount 'Get-FilesWithinBudget') | Should -Be 3
        (Get-Command -Name Get-FilesWithinBudget).CommandType | Should -Be 'Function'
    }

    It 'CD-8 calls the new function once with the bound values and gives its table back unchanged' {
        $table = @{ Files = @('x'); Complete = $true; Marker = 'same object' }
        $script:Seen = [System.Collections.Generic.List[object]]::new()
        Mock Get-SwBoundedFileScan { $script:Seen.Add([pscustomobject]@{ Root = $Root; Filter = $Filter; TimeoutSeconds = $TimeoutSeconds; Bound = @($PesterBoundParameters.Keys | Sort-Object) }); $table }
        $result = Get-FilesWithinBudget $script:Root '*.tmp' 7
        [object]::ReferenceEquals($result, $table) | Should -BeTrue
        $script:Seen.Count | Should -Be 1
        $script:Seen[0].Root | Should -Be $script:Root
        $script:Seen[0].Filter | Should -Be '*.tmp'
        $script:Seen[0].TimeoutSeconds | Should -Be 7
        $script:Seen[0].Bound | Should -Not -Contain 'NoRecurse'
        $script:Seen[0].Bound | Should -Not -Contain 'OlderThan'
        $script:Seen[0].Bound | Should -Not -Contain 'Extensions'
    }

    It 'CD-8 passes the filter * when none is given or the filter is $null, and 15 seconds as the budget' {
        $script:Seen = [System.Collections.Generic.List[object]]::new()
        Mock Get-SwBoundedFileScan { $script:Seen.Add([pscustomobject]@{ Filter = $Filter; TimeoutSeconds = $TimeoutSeconds }); @{ Files = @(); Complete = $true } }
        $null = Get-FilesWithinBudget -Root $script:Root
        $null = Get-FilesWithinBudget -Root $script:Root -Filter $null
        $script:Seen.Count | Should -Be 2
        foreach ($seen in $script:Seen) {
            $seen.Filter | Should -Be '*'
            $seen.TimeoutSeconds | Should -Be 15
        }
    }

    It 'CD-8 finds the same files as the new function when called without a mock' {
        $old = Get-FilesWithinBudget $script:Root '*.tmp'
        $new = Get-SwBoundedFileScan -Root $script:Root -Filter '*.tmp'
        (Get-Names $old) | Should -Be (Get-Names $new)
        $old.Complete | Should -Be $new.Complete
        (Get-Names (Get-FilesWithinBudget -Root $script:Root)) | Should -Be @('a.tmp', 'b.log')
    }

    It 'CD-8 gives Complete $false for TimeoutSeconds 0 through the old name, too' {
        $result = Get-FilesWithinBudget $script:Root '*.tmp' 0
        $result.Complete | Should -BeFalse
        @($result.Files).Count | Should -Be 0
    }
}
