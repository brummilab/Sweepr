# Sweepr - end-to-end tests for the rows of the developer tool section that are guarded by their owner
# (editors, Poetry, Visual Studio) and for the neighbors that must stay: real cache guard (Clear-SwAppCache and
# Test-SwCacheOwnerIdle), real removal helpers, real directory walk, with substitute file identities and a
# substitute process list. Everything that is removed lives below $TestDrive.
#
# The rule numbers in the test names (CD-, CA-, S- and so on) number the rules and the safety invariants
# of the behavior of the developer tool and application cleanup; each rule and invariant has at least one test.
# The other files of this slice are SwCleanDevGroups, SwCleanDevLoad, SwCleanDevScan, SwCleanDevOwnerPath,
# SwCleanDevOwnerRun, SwCleanDevProcess, SwCleanAppsGroups, SwCleanAppsMedia and SwCleanDevAppsSafety.
#
# Interface pinned here (lib\clean\dev.ps1 with lib\clean\cache_guard.ps1):
#   Clear-SwEditorCaches, Clear-SwPythonCaches, Clear-SwIdeCaches        (rows with an owner check, CD-24, CD-25, CD-27)
#   Clear-SwAppCache -Path -Description -Processes                       (the row sink; the guard re-asks after measuring)
#   Test-SwCacheOwnerIdle -Names                                         (true only for an owner that is sure to be idle)
#
# Seams used with Mock: Get-Process (the process list), Get-SwPathSnapshot and Test-SwPathSnapshot (substitute
# objects), Get-SwValidatedTreeSize (starts the owner after measuring, in one case), Test-SwCacheOwnerIdle (counts
# its calls, in one case), the log writers, Write-SwOperation, Get-SwOwnerCachePath (finds no tool).
# Not mocked: the removal helpers, Test-SwSafePath, the tree walk, the cache guard.
#
# Platform notes:
#   - The fake identity is what Linux needs for real removals (there the identity is always missing).
#     Real Windows identities are covered by the Windows run of the other test files.
#   - Tests marked [W] need real Windows. They are meant to fail on Linux and belong in
#     tests/linux-known-failures.txt.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    # Process name, the rows it holds (by description), the rows that must still run.
    $script:Owners = @(
        @{ Process = 'Code'; Held = @('VS Code cache', 'cpptools'); Free = @('VS Code Insiders cache', 'Zed cache', 'Sublime Text cache') }
        @{ Process = 'code'; Held = @('VS Code cache', 'cpptools'); Free = @('VS Code Insiders cache', 'Zed cache', 'Sublime Text cache') }
        @{ Process = 'Code - Insiders'; Held = @('VS Code Insiders cache'); Free = @('VS Code cache', 'Zed cache', 'Sublime Text cache') }
        @{ Process = 'zed'; Held = @('Zed cache'); Free = @('VS Code cache', 'VS Code Insiders cache', 'Sublime Text cache') }
        @{ Process = 'sublime_text'; Held = @('Sublime Text cache'); Free = @('VS Code cache', 'VS Code Insiders cache', 'Zed cache') }
        @{ Process = 'plugin_host'; Held = @('Sublime Text cache'); Free = @('VS Code cache', 'VS Code Insiders cache', 'Zed cache') }
        @{ Process = 'cpptools'; Held = @('cpptools'); Free = @('Zed cache', 'Sublime Text cache') }
        @{ Process = 'cpptools-srv'; Held = @('cpptools'); Free = @('Zed cache', 'Sublime Text cache') }
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

    $script:CodeLeaves = @('Cache', 'CachedData', 'CachedExtensions', 'CachedExtensionVSIXs', 'Code Cache', 'GPUCache')
    # Every cache folder of the editor table with one file in it, and the neighbors that must stay.
    function script:New-EditorFixture {
        foreach ($leaf in $script:CodeLeaves) {
            $null = New-File (P $script:Roam 'Code' $leaf 'entry.bin') 10
            $null = New-File (P $script:Roam 'Code - Insiders' $leaf 'entry.bin') 10
        }
        $null = New-File (P $script:Local 'Microsoft' 'vscode-cpptools' 'entry.bin') 10
        $null = New-File (P $script:Local 'Zed' 'cache' 'entry.bin') 10
        $null = New-File (P $script:Roam 'Zed' 'cache' 'entry.bin') 10
        $null = New-File (P $script:Local 'Sublime Text' 'Cache' 'entry.bin') 10
        $null = New-File (P $script:Roam 'Sublime Text' 'Cache' 'entry.bin') 10
        # what must stay
        foreach ($root in 'Code', 'Code - Insiders') {
            $null = New-File (P $script:Roam $root 'User' 'settings.json') 10
            $null = New-File (P $script:Roam $root 'User' 'History' 'h1' 'entry.txt') 10
            $null = New-File (P $script:Roam $root 'workspaceStorage' 'w1' 'state.vscdb') 10
            $null = New-File (P $script:Roam $root 'Backups' 'b1') 10
            $null = New-File (P $script:Roam $root 'logs' 'main.log') 10
            $null = New-File (P $script:Roam $root 'Local Storage' 'leveldb' 'x.ldb') 10
            $null = New-File (P $script:Roam $root 'Session Storage' 'x.ldb') 10
            $null = New-File (P $script:Roam $root 'Service Worker' 'CacheStorage' 'x') 10
        }
        $null = New-File (P $script:Roam 'Sublime Text' 'Packages' 'User' 'settings') 10
        $null = New-File (P $script:Roam 'Sublime Text' 'Local' 'Session.sublime_session') 10
        $null = New-File (P $script:Profile '.vscode' 'extensions' 'ext' 'package.json') 10
    }
    function script:Get-Keepers {
        $keep = [System.Collections.Generic.List[string]]::new()
        foreach ($root in 'Code', 'Code - Insiders') {
            foreach ($rest in @('User/settings.json', 'User/History/h1/entry.txt', 'workspaceStorage/w1/state.vscdb', 'Backups/b1', 'logs/main.log',
                    'Local Storage/leveldb/x.ldb', 'Session Storage/x.ldb', 'Service Worker/CacheStorage/x')) {
                $path = P $script:Roam $root
                foreach ($segment in ($rest -split '/')) { $path = P $path $segment }
                $keep.Add($path)
            }
        }
        $keep.Add((P $script:Roam 'Sublime Text' 'Packages' 'User' 'settings'))
        $keep.Add((P $script:Roam 'Sublime Text' 'Local' 'Session.sublime_session'))
        $keep.Add((P $script:Profile '.vscode' 'extensions' 'ext' 'package.json'))
        $keep.ToArray()
    }
    function script:Get-CacheFiles {
        $files = [System.Collections.Generic.List[string]]::new()
        foreach ($leaf in $script:CodeLeaves) { $files.Add((P $script:Roam 'Code' $leaf 'entry.bin')); $files.Add((P $script:Roam 'Code - Insiders' $leaf 'entry.bin')) }
        $files.Add((P $script:Local 'Microsoft' 'vscode-cpptools' 'entry.bin'))
        $files.Add((P $script:Local 'Zed' 'cache' 'entry.bin'))
        $files.Add((P $script:Roam 'Zed' 'cache' 'entry.bin'))
        $files.Add((P $script:Local 'Sublime Text' 'Cache' 'entry.bin'))
        $files.Add((P $script:Roam 'Sublime Text' 'Cache' 'entry.bin'))
        $files.ToArray()
    }
    function script:Get-DescriptionOf([string]$Path) {
        $p = Fold $Path
        if ($p.Contains('vscode-cpptools')) { return 'cpptools' }
        if ($p.Contains('code - insiders')) { return 'VS Code Insiders cache' }
        if ($p.Contains((Fold (P $script:Roam 'Code')) + '\')) { return 'VS Code cache' }
        if ($p.Contains('\zed\')) { return 'Zed cache' }
        if ($p.Contains('\sublime text\')) { return 'Sublime Text cache' }
        'other'
    }
    # The rows the collector holds, by the editor they belong to.
    function script:Get-ListedEditors { @($script:DryRunCollector | ForEach-Object { Get-DescriptionOf $_.Path } | Select-Object -Unique | Sort-Object) }
    function script:Use-Running([string[]]$Names) {
        $script:RunningNames = @($Names)
        Mock Get-Process { foreach ($name in @($script:RunningNames)) { [pscustomobject]@{ ProcessName = $name } } }
    }
}

AfterAll {
    Clear-TestLinks
    Restore-Env $script:RootEnv
    Restore-State $script:RootState
    [System.Environment]::CurrentDirectory = $script:RootDirectory
    try { Set-Location -LiteralPath $script:RootLocation } catch { $null = $_ }
}
Describe 'CD-25 an editor row stays while its owner runs, in a preview and in a real run' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -Real
        Mock Invoke-SwOwnerCacheCleanup { }
        New-EditorFixture
    }
    AfterEach { Stop-Case }

    It 'CD-25 keeps the rows of <Process> and runs the others in a preview' -ForEach $script:Owners {
        Use-Running @($Process)
        $script:SweeprDryRunMode = $true
        Use-Collectors
        Clear-SwEditorCaches
        $listed = @(Get-ListedEditors)
        foreach ($row in $Held) { $listed | Should -Not -Contain $row -Because "$Process holds $row" }
        foreach ($row in $Free) { $listed | Should -Contain $row -Because "$Process does not hold $row" }
    }

    It 'CD-25 keeps the cache files of <Process> and removes the others in a real run, and keeps everything else of every editor' -ForEach $script:Owners {
        Use-Running @($Process)
        $script:SweeprDryRunMode = $false
        Clear-SwEditorCaches
        foreach ($file in (Get-CacheFiles)) {
            $description = Get-DescriptionOf $file
            if ($Held -contains $description) { [System.IO.File]::Exists($file) | Should -BeTrue -Because $file }
            else { [System.IO.File]::Exists($file) | Should -BeFalse -Because $file }
        }
        foreach ($file in (Get-Keepers)) { [System.IO.File]::Exists($file) | Should -BeTrue -Because $file }
    }

    It 'CD-25 CD-6 chooses the same rows in a preview and a real run for the same process list' {
        Use-Running @('Code')
        $script:SweeprDryRunMode = $true
        Use-Collectors
        Clear-SwEditorCaches
        $preview = @($script:DryRunCollector | ForEach-Object { Fold $_.Path } | Sort-Object)
        $script:SweeprDryRunMode = $false
        $script:FilesCleaned = 0
        Clear-SwEditorCaches
        $script:FilesCleaned | Should -Be $preview.Count
    }

    It 'CD-25 keeps all editor caches and counts nothing when the process list cannot be read (Get-Process throws), in a preview and a real run' {
        Mock Get-Process { throw 'unavailable' }
        foreach ($dry in $true, $false) {
            $script:SweeprDryRunMode = $dry
            Use-Collectors
            $script:FilesCleaned = 0
            Clear-SwEditorCaches
            $script:DryRunCollector.Count | Should -Be 0
            $script:FilesCleaned | Should -Be 0
        }
        foreach ($file in (Get-CacheFiles)) { [System.IO.File]::Exists($file) | Should -BeTrue -Because $file }
    }

    It 'CD-25 removes the cache of every editor and keeps the user data and the settings when nothing runs' {
        Use-Running @()
        $script:SweeprDryRunMode = $false
        Clear-SwEditorCaches
        foreach ($file in (Get-CacheFiles)) { [System.IO.File]::Exists($file) | Should -BeFalse -Because $file }
        foreach ($file in (Get-Keepers)) { [System.IO.File]::Exists($file) | Should -BeTrue -Because $file }
        $script:FilesCleaned | Should -Be 17
        @(Get-OpsOf 'SKIPPED').Count | Should -Be 0
    }

    It 'CD-25 CD-6 lists the same files in the preview that a real run removes, and the preview leaves everything on disk' {
        Use-Running @()
        $script:SweeprDryRunMode = $true
        Use-Collectors
        Clear-SwEditorCaches
        $listed = @($script:DryRunCollector | ForEach-Object { Fold $_.Path } | Sort-Object)
        $listed | Should -Be @((Get-CacheFiles | ForEach-Object { Fold $_ } | Sort-Object))
        foreach ($file in (Get-CacheFiles)) { [System.IO.File]::Exists($file) | Should -BeTrue -Because $file }
        $script:Ops.Count | Should -Be 0
    }

    It 'CD-25 keeps Code - Insiders when only Code runs, and the other way round: the name must match exactly' {
        Use-Running @('Code')
        $script:SweeprDryRunMode = $true
        Use-Collectors
        Clear-SwEditorCaches
        @($script:DryRunCollector | Where-Object { (Fold $_.Path).Contains('code - insiders') }).Count | Should -Be 6
        @($script:DryRunCollector | Where-Object { (Fold $_.Path).StartsWith((Fold (P $script:Roam 'Code')) + '\') }).Count | Should -Be 0
    }
}

Describe 'CD-25 the owner is asked again after the measurement' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -Real
        Mock Invoke-SwOwnerCacheCleanup { }
        $script:Nested = New-File (P $script:Local 'Zed' 'cache' 'nested' 'inner.bin') 100
    }
    AfterEach { Stop-Case }

    It 'CD-25 removes nothing and counts nothing when the owner starts while the cache is measured, in a real run' {
        $script:OwnerRunning = $false
        Mock Get-Process { if ($script:OwnerRunning) { [pscustomobject]@{ ProcessName = 'zed' } } else { @() } }
        Mock Get-SwValidatedTreeSize { $script:OwnerRunning = $true; [long]100 }
        $script:SweeprDryRunMode = $false
        Clear-SwEditorCaches
        [System.IO.File]::Exists($script:Nested) | Should -BeTrue
        $script:FilesCleaned | Should -Be 0
        $script:TotalItems | Should -Be 0
    }

    It 'CD-25 lists nothing and notes nothing for the row when the owner starts while the cache is measured, in a preview' {
        $script:OwnerRunning = $false
        Mock Get-Process { if ($script:OwnerRunning) { [pscustomobject]@{ ProcessName = 'zed' } } else { @() } }
        Mock Get-SwValidatedTreeSize { $script:OwnerRunning = $true; [long]100 }
        $script:SweeprDryRunMode = $true
        Use-Collectors
        Clear-SwEditorCaches
        $script:DryRunCollector.Count | Should -Be 0
        $script:FilesCleaned | Should -Be 0
    }

    It 'CD-25 writes exactly one SKIPPED line and counts no file when the check turns to "active" from its third call and the cache has one folder as its only child' {
        $script:IdleCalls = 0
        Mock Test-SwCacheOwnerIdle { $script:IdleCalls++; $script:IdleCalls -lt 3 }
        $script:SweeprDryRunMode = $false
        Clear-SwEditorCaches
        @(Get-OpsOf 'SKIPPED').Count | Should -Be 1
        $script:FilesCleaned | Should -Be 0
        [System.IO.File]::Exists($script:Nested) | Should -BeTrue
        $script:IdleCalls | Should -BeGreaterOrEqual 3
    }

    It 'CD-25 removes a file child without a third check and writes no SKIPPED line, also when the check would turn to "active" from its third call' {
        $null = Remove-Item -LiteralPath (P $script:Local 'Zed' 'cache' 'nested') -Recurse -Force
        $file = New-File (P $script:Local 'Zed' 'cache' 'a.bin') 100
        $script:IdleCalls = 0
        Mock Test-SwCacheOwnerIdle { $script:IdleCalls++; $script:IdleCalls -lt 3 }
        $script:SweeprDryRunMode = $false
        Clear-SwEditorCaches
        @(Get-OpsOf 'SKIPPED').Count | Should -Be 0
        $script:IdleCalls | Should -BeLessThan 3
        [System.IO.File]::Exists($file) | Should -BeFalse
        $script:FilesCleaned | Should -Be 1
    }
}

Describe 'CD-3 CD-23 an editor row below a base with brackets in its name' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -Real
        Mock Invoke-SwOwnerCacheCleanup { }
        Use-Running @()
    }
    AfterEach { Stop-Case }

    It 'CD-3 removes the cache below Ex [1] and leaves the same-looking folder Ex 1 alone' {
        $roam = New-Dir (P $script:Work 'Ex [1]' 'Roaming')
        $null = New-Dir (P $script:Work 'Ex 1' 'Roaming')
        $mine = New-File (P $roam 'Zed' 'cache' 'entry.bin') 10
        $other = New-File (P $script:Work 'Ex 1' 'Roaming' 'Zed' 'cache' 'entry.bin') 10
        Set-Env 'APPDATA' $roam
        $script:SweeprDryRunMode = $false
        Clear-SwEditorCaches
        [System.IO.File]::Exists($mine) | Should -BeFalse
        [System.IO.File]::Exists($other) | Should -BeTrue
    }
}

Describe 'CD-24 Poetry: artifacts and cache go, virtualenvs stay' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -Real
        Mock Invoke-SwOwnerCacheCleanup { }
        $script:PoetryRoot = P $script:Local 'pypoetry' 'Cache'
        $script:Env = New-File (P $script:PoetryRoot 'virtualenvs' 'project' 'Scripts' 'python.exe') 20
        $script:Wheel = New-File (P $script:PoetryRoot 'artifacts' 'a.whl') 20
        $script:Repo = New-File (P $script:PoetryRoot 'cache' 'repo' 'entry') 20
    }
    AfterEach { Stop-Case }

    It 'CD-24 lists in a preview the direct children of artifacts and cache, never anything below virtualenvs' {
        Use-Running @()
        $script:SweeprDryRunMode = $true
        Use-Collectors
        Clear-SwPythonCaches
        @($script:DryRunCollector | ForEach-Object { Fold $_.Path } | Sort-Object) | Should -Be @(
            (Fold $script:Wheel), (Fold (P $script:PoetryRoot 'cache' 'repo')) | Sort-Object)
        Test-AnyUnder @($script:DryRunCollector | ForEach-Object { $_.Path }) (P $script:PoetryRoot 'virtualenvs') | Should -BeFalse
        [System.IO.File]::Exists($script:Env) | Should -BeTrue
    }

    It 'CD-24 removes artifacts and cache in a real run and keeps the virtual environment' {
        Use-Running @()
        $script:SweeprDryRunMode = $false
        Clear-SwPythonCaches
        [System.IO.File]::Exists($script:Wheel) | Should -BeFalse
        [System.IO.Directory]::Exists((P $script:PoetryRoot 'cache' 'repo')) | Should -BeFalse
        [System.IO.File]::Exists($script:Env) | Should -BeTrue
        [System.IO.Directory]::Exists($script:PoetryRoot) | Should -BeTrue
        [System.IO.Directory]::Exists((P $script:PoetryRoot 'artifacts')) | Should -BeTrue -Because 'the folder of the row stays, its content goes'
    }

    It 'CD-24 removes nothing and lists nothing while a process named <Process> runs' -ForEach @(@{ Process = 'python' }, @{ Process = 'pythonw' }, @{ Process = 'poetry' }) {
        Use-Running @($Process)
        $script:SweeprDryRunMode = $true
        Use-Collectors
        Clear-SwPythonCaches
        $script:DryRunCollector.Count | Should -Be 0
        $script:SweeprDryRunMode = $false
        Clear-SwPythonCaches
        $script:FilesCleaned | Should -Be 0
        [System.IO.File]::Exists($script:Wheel) | Should -BeTrue
        [System.IO.File]::Exists((P $script:PoetryRoot 'cache' 'repo' 'entry')) | Should -BeTrue
    }

    It 'CD-24 keeps everything when the process list cannot be read' {
        Mock Get-Process { throw 'unavailable' }
        $script:SweeprDryRunMode = $false
        Clear-SwPythonCaches
        $script:FilesCleaned | Should -Be 0
        [System.IO.File]::Exists($script:Wheel) | Should -BeTrue
    }

    It 'CD-24 CD-30 keeps the virtualenvs even with an owner that is idle and the whole section run' {
        Use-Running @()
        $script:SweeprDryRunMode = $false
        Mock Invoke-SwOwnerCacheCleanup { }
        Invoke-SwDevCleanup
        [System.IO.File]::Exists($script:Env) | Should -BeTrue
        [System.IO.File]::Exists($script:Wheel) | Should -BeFalse
    }
}

Describe 'CD-27 Visual Studio: the cache folders of every profile folder, while devenv is not running' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -Real
        Mock Invoke-SwOwnerCacheCleanup { }
        $studio = P $script:Local 'Microsoft' 'VisualStudio'
        $script:Hit = New-File (P $studio '17.0_abc' 'ComponentModelCache' 'a.bin') 10
        $script:Hit2 = New-File (P $studio '17.0_abc' 'ImageCache' 'b.bin') 10
        $script:Hit3 = New-File (P $studio '16.0_def' 'ComponentModelCache' 'c.bin') 10
        $script:Stay = New-File (P $studio '17.0_abc' 'Settings' 'user.config') 10
        $script:Stay2 = New-File (P $studio 'Cache' 'ComponentModelCache' 'blatt.bin') 10
    }
    AfterEach { Stop-Case }

    It 'CD-27 removes the two cache folders of each profile and keeps the settings and a folder that is named like a cache leaf' {
        Use-Running @()
        $script:SweeprDryRunMode = $false
        Clear-SwIdeCaches
        foreach ($file in $script:Hit, $script:Hit2, $script:Hit3) { [System.IO.File]::Exists($file) | Should -BeFalse -Because $file }
        foreach ($file in $script:Stay, $script:Stay2) { [System.IO.File]::Exists($file) | Should -BeTrue -Because $file }
    }

    It 'CD-27 keeps everything while devenv runs and when the process list cannot be read' {
        foreach ($case in @(@{ Names = @('devenv') }, @{ Names = $null })) {
            if ($null -eq $case.Names) { Mock Get-Process { throw 'unavailable' } } else { Use-Running $case.Names }
            $script:SweeprDryRunMode = $false
            Clear-SwIdeCaches
            foreach ($file in $script:Hit, $script:Hit2, $script:Hit3) { [System.IO.File]::Exists($file) | Should -BeTrue -Because $file }
        }
    }

    It 'CD-27 CD-6 lists the same files in a preview' {
        Use-Running @()
        $script:SweeprDryRunMode = $true
        Use-Collectors
        Clear-SwIdeCaches
        @($script:DryRunCollector | ForEach-Object { Fold $_.Path } | Sort-Object) | Should -Be @((Fold $script:Hit), (Fold $script:Hit2), (Fold $script:Hit3) | Sort-Object)
    }

    It 'CD-27 gives a profile root with more than 128 folders no row at all: an incomplete listing is not used' {
        Use-Running @()
        $studio = P $script:Local 'Microsoft' 'VisualStudio'
        foreach ($number in 1..130) { $null = New-Dir (P $studio ('p' + $number)) }
        $script:SweeprDryRunMode = $false
        Clear-SwIdeCaches
        foreach ($file in $script:Hit, $script:Hit2, $script:Hit3) { [System.IO.File]::Exists($file) | Should -BeTrue -Because $file }
    }

    It 'CD-27 gives no row when the profile listing exceeds its time budget (SwProbeBudgetSeconds 0)' {
        Use-Running @()
        $script:SwProbeBudgetSeconds = 0
        $script:SweeprDryRunMode = $false
        Clear-SwIdeCaches
        foreach ($file in $script:Hit, $script:Hit2, $script:Hit3) { [System.IO.File]::Exists($file) | Should -BeTrue -Because $file }
    }

    It 'CD-27 does not enter a link below VisualStudio: the link is no profile folder, and nothing behind it is removed' {
        $target = New-Dir (P $script:Work 'junction target')
        $null = New-File (P $target 'ComponentModelCache' 'x.bin') 10
        $link = P $script:Local 'Microsoft' 'VisualStudio' '18.0_x'
        if (-not (New-TestLink $link $target)) { Set-ItResult -Skipped -Because 'this host cannot create a link here'; return }
        Use-Running @()
        $script:SweeprDryRunMode = $false
        Clear-SwIdeCaches
        [System.IO.File]::Exists((P $target 'ComponentModelCache' 'x.bin')) | Should -BeTrue
    }
}
