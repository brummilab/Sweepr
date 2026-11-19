# Sweepr - safety checks over lib\clean\dev.ps1 and lib\clean\apps.ps1 as syntax trees (what these files may call, which
# variables they may read, how they load, what is compatible with Windows PowerShell 5.1) and as whole runs (nothing is
# removed outside the removal helpers, one offer per place, the never-list and the dropped rows, the preview changes
# nothing, the ownership of paths between the sections).
#
# The rule numbers in the test names (CD-, CA-, S- and so on) number the rules and the safety invariants
# of the behavior of the developer tool and application cleanup; each rule and invariant has at least one test.
# The other files of this slice are SwCleanDevGroups, SwCleanDevLoad, SwCleanDevScan, SwCleanDevOwnerPath,
# SwCleanDevOwnerRun, SwCleanDevProcess, SwCleanDevEditors, SwCleanAppsGroups and SwCleanAppsMedia.
#
# Interface pinned here: the two files themselves (as text and as syntax trees), Invoke-SwDevCleanup,
# Invoke-SwAppCleanup -IncludeGameMedia, and the section functions of caches.ps1 and user.ps1 for the ownership check
# (Clear-SwBrowserCaches, Clear-SwAppCaches, Clear-SwGpuShaderCaches, Invoke-SwUserCleanup).
#
# Seams used with Mock: the removal helpers (spies), Get-SwBoundedFileScan (spy, or a counting stand-in that calls the real
# search), Get-SwOwnerCachePath (finds no tool), Get-Process, Get-SwPathSnapshot and Test-SwPathSnapshot (substitute objects),
# and, for the whole-run checks, every cmdlet that must never be called as a mock that throws.
#
# Platform notes:
#   - Real removals happen only in the case that names it, below $TestDrive, with substitute identities.
#   - Tests marked [W] need real Windows. They are meant to fail on Linux and belong in
#     tests/linux-known-failures.txt.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    $script:Files = @(
        @{ Name = 'lib\clean\dev.ps1'; Leaf = 'dev.ps1'; Loads = @('base.ps1', 'log.ps1', 'file_ops.ps1', 'cache_guard.ps1')
            Functions = @('Invoke-SwDevCleanup', 'Clear-SwNpmFamilyCaches', 'Clear-SwNodeBuildCaches', 'Clear-SwPythonCaches', 'Clear-SwDotNetCaches', 'Clear-SwGoCaches',
                'Clear-SwMiseCache', 'Clear-SwElixirCaches', 'Clear-SwHaskellCaches', 'Clear-SwOCamlCaches', 'Clear-SwCloudCliCaches', 'Clear-SwEditorCaches', 'Clear-SwIdeCaches',
                'Invoke-SwOwnerCacheCleanup', 'Get-SwOwnerCachePath', 'Invoke-SwOwnerCommand', 'New-SwOwnerProcess', 'Get-SwBoundedFileScan') }
        @{ Name = 'lib\clean\apps.ps1'; Leaf = 'apps.ps1'; Loads = @('base.ps1', 'log.ps1', 'file_ops.ps1', 'cache_guard.ps1')
            Functions = @('Invoke-SwAppCleanup', 'Clear-SwOfficeCache', 'Clear-SwOneDriveCache', 'Clear-SwGoogleDriveCache', 'Clear-SwAdobeCaches', 'Clear-SwGamePlatformCaches', 'Clear-SwGameMedia') }
    )
    # Folders that the dropped rows used to clear (relative to USERPROFILE, APPDATA, LOCALAPPDATA).
    $script:DroppedRows = @(
        @{ Label = 'D02 .yarn\cache'; Base = 'Profile'; Rest = @('.yarn', 'cache') }
        @{ Label = 'D11 .pytest_cache'; Base = 'Profile'; Rest = @('.pytest_cache') }
        @{ Label = 'D24 Atom compile-cache'; Base = 'Roam'; Rest = @('.atom', 'compile-cache') }
        @{ Label = 'D15 the Go module cache'; Base = 'Profile'; Rest = @('go', 'pkg', 'mod', 'cache') }
        @{ Label = 'D23 GitHub CLI'; Base = 'Roam'; Rest = @('GitHub CLI') }
        @{ Label = 'D25 cargo registry'; Base = 'Profile'; Rest = @('.cargo', 'registry') }
        @{ Label = 'D27 rustup downloads'; Base = 'Profile'; Rest = @('.rustup', 'downloads') }
        @{ Label = 'D28 JetBrains caches'; Base = 'Local'; Rest = @('JetBrains', 'IntelliJIdea2025.1', 'caches') }
        @{ Label = 'A09 Adobe product caches'; Base = 'Local'; Rest = @('Adobe', 'Premiere Pro', 'Cache') }
        @{ Label = 'A10 Temp\Adobe'; Base = 'Local'; Rest = @('Temp', 'Adobe') }
        @{ Label = 'A11 Autodesk local'; Base = 'Local'; Rest = @('Autodesk', 'Maya', 'cache') }
        @{ Label = 'A12 Autodesk roaming'; Base = 'Roam'; Rest = @('Autodesk', 'Maya', 'Cache') }
        @{ Label = 'A16 Origin'; Base = 'Roam'; Rest = @('Origin', 'Logs', 'cache') }
        @{ Label = 'G04 Videos\Captures'; Base = 'Profile'; Rest = @('Videos', 'Captures') }
        @{ Label = 'G05 Steam screenshots'; Base = 'Profile'; Rest = @('Pictures', 'Steam Screenshots') }
        @{ Label = 'G06 Videos\OBS'; Base = 'Profile'; Rest = @('Videos', 'OBS') }
        @{ Label = 'G12 League of Legends replays'; Base = 'Profile'; Rest = @('Documents', 'League of Legends', 'Replays') }
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
    . ([System.IO.Path]::Combine($script:CleanDir, 'user.ps1'))
    . ([System.IO.Path]::Combine($script:CleanDir, 'caches.ps1'))

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
    $script:RealScan = (Get-Command -Name Get-SwBoundedFileScan -CommandType Function).ScriptBlock

    # ---- the files as syntax trees ----------------------------------------------------------------

    function script:Get-FilePath([string]$Leaf) { [System.IO.Path]::Combine($script:CleanDir, $Leaf) }
    function script:Get-AstOf([string]$Leaf) {
        $tokens = $null
        $errors = $null
        $path = Get-FilePath $Leaf
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        if (@($errors).Count -gt 0) { throw ('syntax errors in ' + $path + ': ' + $errors[0].Message) }
        $script:LastTokens = $tokens
        $ast
    }
    function script:Get-TokensOf([string]$Leaf) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile((Get-FilePath $Leaf), [ref]$tokens, [ref]$errors)
        $tokens
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
    function script:Find-Variables($Ast, [string[]]$Names) {
        $found = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)
        @($found | Where-Object { $Names -contains $_.VariablePath.UserPath } | ForEach-Object { [pscustomobject]@{ Name = $_.VariablePath.UserPath; Line = $_.Extent.StartLineNumber; Function = (Get-EnclosingFunction $_) } })
    }
    function script:Format-Violations($Violations) { (@($Violations | Where-Object { $null -ne $_ }) | ForEach-Object { '{0}:{1} {2}' -f $_.Name, $_.Line, $_.Function }) -join '; ' }
    function script:Assert-NoViolations($Violations, [string]$Because = '') {
        $list = @($Violations | Where-Object { $null -ne $_ })
        $list.Count | Should -Be 0 -Because ($Because + ' ' + (Format-Violations $list))
    }
    function script:Get-DefinedFunctions($Ast) {
        @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { [string]$_.Name })
    }

    # ---- whole runs --------------------------------------------------------------------------------

    # Cmdlets that none of the sections may call, as mocks that throw; the names that exist on this host.
    $script:NeverCalled = @('Remove-Item', 'Move-Item', 'Copy-Item', 'Rename-Item', 'Invoke-Item', 'New-Item', 'Set-Content', 'Add-Content', 'Out-File', 'Clear-Content',
        'Start-Process', 'Stop-Process', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Invoke-WebRequest', 'Invoke-RestMethod', 'Start-Job', 'Clear-Host', 'Read-Host')
    function script:Use-ThrowingCmdlets {
        foreach ($name in $script:NeverCalled) {
            if ($null -ne (Get-Command -Name $name -ErrorAction SilentlyContinue)) { Mock $name { throw 'a section must never call this (test)' } }
        }
        Mock Move-SwItemToRecycleBin { throw 'the Recycle Bin must never be used (test)' }
        Mock Remove-SwItem { throw 'a section must use the list helper, not the single-item helper (test)' }
    }
    # A scan stand-in that records the root and then calls the real search.
    function script:Use-RecordingScan {
        $script:ScanCalls = [System.Collections.Generic.List[object]]::new()
        Mock Get-SwBoundedFileScan {
            $script:ScanCalls.Add([pscustomobject]@{ Root = $Root })
            $arguments = @{}
            foreach ($key in $PesterBoundParameters.Keys) { $arguments[$key] = $PesterBoundParameters[$key] }
            & $script:RealScan @arguments
        }
    }
    # Folders that the placeholder rows need, so that every row of the tables is offered.
    function script:New-PlaceholderFolders {
        foreach ($name in 'temp', 'TempFiles') { $null = New-Dir (P $script:Local 'Microsoft' 'MSBuild' $name) }
        foreach ($name in 'cache-1', 'default') { $null = New-Dir (P $script:Profile '.opam' 'repo' $name) }
        foreach ($name in '16.0_def', '17.0_abc') { $null = New-Dir (P $script:Local 'Microsoft' 'VisualStudio' $name) }
    }
    # Every path a run offered: what the helpers got and the roots of the recursive searches. A search that lists only the files
    # directly in its root (-NoRecurse) offers those files, not the folder: its root may lie above the folder of another row
    # (DriveFS above DriveFS\Logs), so such a root is looked at apart (Get-FileRowRoots).
    function script:Get-Offered { @(@(Get-CallPaths) + @($script:ScanCalls | Where-Object { -not $_.NoRecurse } | ForEach-Object { [string]$_.Root })) }
    function script:Get-AllOffered { @(@(Get-CallPaths) + @(Get-ScanRoots)) }
    function script:Get-FileRowRoots { @($script:ScanCalls | Where-Object { $_.NoRecurse } | ForEach-Object { [string]$_.Root }) }
    function script:Test-CrossDisjoint([string[]]$Left, [string[]]$Right) {
        foreach ($a in @($Left)) {
            foreach ($b in @($Right)) {
                if ((Test-SameOrUnder $a $b) -or (Test-SameOrUnder $b $a)) { return ('{0} <-> {1}' -f $a, $b) }
            }
        }
        $null
    }
    function script:Get-NeverList {
        $profileRoot = $script:Profile
        $paths = [System.Collections.Generic.List[string]]::new()
        foreach ($rest in @('.m2'), @('.gradle'), @('.nuget'), @('.cargo'), @('.rustup'), @('.cabal'), @('.stack', 'programs'), @('.hex', 'packages'), @('.mix'), @('.aws'), @('.azure'), @('.kube'),
            @('.docker'), @('.ssh'), @('.claude'), @('.codex'), @('.gitconfig'), @('.gitconfig.lock')) {
            $path = $profileRoot
            foreach ($segment in $rest) { $path = P $path $segment }
            $paths.Add($path)
        }
        foreach ($rest in @('npm'), @('Docker'), @('Code', 'User'), @('Code', 'workspaceStorage'), @('JetBrains'), @('Adobe', 'Common', 'Team Projects Cache')) {
            $path = $script:Roam
            foreach ($segment in $rest) { $path = P $path $segment }
            $paths.Add($path)
        }
        foreach ($rest in @('Docker'), @('JetBrains'), @('pypoetry', 'Cache', 'virtualenvs')) {
            $path = $script:Local
            foreach ($segment in $rest) { $path = P $path $segment }
            $paths.Add($path)
        }
        $paths.ToArray()
    }
    function script:Get-BaseFolder([string]$Base) { switch ($Base) { 'Profile' { $script:Profile } 'Roam' { $script:Roam } 'Local' { $script:Local } } }
}

AfterAll {
    Clear-TestLinks
    Restore-Env $script:RootEnv
    Restore-State $script:RootState
    [System.Environment]::CurrentDirectory = $script:RootDirectory
    try { Set-Location -LiteralPath $script:RootLocation } catch { $null = $_ }
}
Describe 'S-1 S-3 S-4 S-5 S-13 the forbidden list over <Name>' -ForEach $script:Files {
    BeforeAll {
        $script:Ast = Get-AstOf $Leaf
        $script:LeafName = $Leaf
    }
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        foreach ($function in $Functions) { (Get-DefinedFunctions $script:Ast) | Should -Contain $function -Because "$Name must define $function" }
    }

    It 'CD-1 parses without errors and defines the functions of the slice' {
        Assert-Defined $Functions
    }

    It 'CD-5 S-1 calls none of Remove-Item, Move-Item, Copy-Item, Rename-Item, Invoke-Item, Clear-RecycleBin, Start-Job, cmd, cmd.exe, schtasks, taskkill, Invoke-Expression' {
        Assert-NoViolations (Find-Commands $script:Ast @('Remove-Item', 'Move-Item', 'Copy-Item', 'Rename-Item', 'Invoke-Item', 'Clear-RecycleBin', 'Start-Job', 'cmd', 'cmd.exe', 'schtasks', 'schtasks.exe', 'taskkill', 'taskkill.exe', 'runas', 'Invoke-Expression', 'iex'))
    }

    It 'CD-5 S-1 calls no low-level removal, no Recycle Bin function, no single-item helper and no old name of a helper: only the four sinks remove' {
        Assert-NoViolations (Find-Commands $script:Ast @('Remove-SwTreeEntry', 'Remove-SwDirectoryTree', 'Move-SwItemToRecycleBin', 'Remove-SwItem', 'Remove-SafeItem', 'Remove-SafeItems', 'Remove-OldFiles',
                'Clear-DirectoryContents', 'Remove-TreeEntry', 'Remove-SafeDirectoryTree', 'Move-SweeprItemToRecycleBin'))
    }

    It 'S-1 passes -Recycle to no command' {
        $found = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandParameterAst] -and $n.ParameterName -eq 'Recycle' }, $true)
        @($found).Count | Should -Be 0
    }

    It 'CD-5 S-1 calls no member that deletes, moves, copies, replaces or writes with .NET, and none that changes attributes or times' {
        Assert-NoViolations (Find-MemberCalls $script:Ast @('Delete', 'Move', 'Copy', 'Replace', 'MoveTo', 'CopyTo', 'SetAttributes', 'SetLastWriteTime', 'SetCreationTime', 'SetLastAccessTime', 'SetLastWriteTimeUtc', 'SetCreationTimeUtc',
                'SetAccessControl', 'WriteAllText', 'WriteAllBytes', 'WriteAllLines', 'AppendAllText', 'AppendAllLines', 'CreateDirectory', 'Create', 'CreateText', 'AppendText', 'OpenWrite') '(?i)(^|\.)(File|Directory|FileSystem|FileInfo|DirectoryInfo|Microsoft\.VisualBasic\.FileIO\.FileSystem)$')
        Assert-NoViolations @(Find-MemberCalls $script:Ast @('Delete', 'MoveTo', 'CopyTo') | Where-Object { $_.Name -notmatch '^\[' })
        $modes = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and $n.Expression.TypeName.FullName -match '(?i)FileMode$' }, $true)
        @($modes | Where-Object { $_.Member.Extent.Text -in @('Create', 'CreateNew', 'OpenOrCreate', 'Append', 'Truncate') }).Count | Should -Be 0
    }

    It 'S-1 writes no file: no New-Item, Set-Content, Add-Content, Out-File, Clear-Content, Tee-Object, Export-Csv, Set-Clipboard' {
        Assert-NoViolations (Find-Commands $script:Ast @('New-Item', 'Set-Content', 'Add-Content', 'Out-File', 'Clear-Content', 'Tee-Object', 'Export-Csv', 'Export-Clixml', 'Set-Clipboard'))
    }

    It 'CD-5 S-3 starts a process only in Invoke-SwOwnerCommand through New-SwOwnerProcess: no Start-Process, no Stop-Process, no Process.Start, and Process types only inside New-SwOwnerProcess' {
        Assert-NoViolations (Find-Commands $script:Ast @('Start-Process', 'Stop-Process', 'Wait-Process', 'Start-Job', 'Start-ThreadJob', 'Invoke-Command', 'Invoke-WmiMethod', 'Invoke-CimMethod'))
        Assert-NoViolations (Find-MemberCalls $script:Ast @('Start') '(?i)Process$')
        $types = @(Find-TypeUses $script:Ast '(?i)^(System\.)?Diagnostics\.Process(StartInfo)?$|^Process(StartInfo)?$')
        foreach ($use in $types) { $use.Function | Should -Be 'New-SwOwnerProcess' -Because ($use.Name + ' at line ' + $use.Line) }
        $named = @(Find-Strings $script:Ast '(?i)Diagnostics\.Process')
        foreach ($use in $named) { $use.Function | Should -Be 'New-SwOwnerProcess' -Because ($use.Name + ' at line ' + $use.Line) }
        if ($script:LeafName -eq 'apps.ps1') {
            $types.Count | Should -Be 0
            @(Find-MemberCalls $script:Ast @('Start', 'Kill', 'WaitForExit')).Count | Should -Be 0
        }
    }

    It 'S-13 reads no process list and no service list: Get-Process is the business of the owner probe in cache_guard.ps1' {
        Assert-NoViolations (Find-Commands $script:Ast @('Get-Process', 'Get-Service', 'Stop-Service', 'Set-Service', 'Restart-Service', 'Start-Service', 'Get-WmiObject', 'Get-CimInstance', 'Get-CimClass'))
    }

    It 'S-13 reads neither registry nor Appx and uses no network and no COM object' {
        Assert-NoViolations (Find-Commands $script:Ast @('Get-ItemProperty', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Get-ItemPropertyValue', 'Get-AppxPackage', 'Get-AppxProvisionedPackage', 'Get-Package',
                'Invoke-WebRequest', 'Invoke-RestMethod', 'Start-BitsTransfer', 'Test-Connection', 'Resolve-DnsName', 'Get-NetAdapter', 'Register-ScheduledTask', 'New-ScheduledTask'))
        Assert-NoViolations (Find-Strings $script:Ast '(?i)^(HKLM|HKCU|HKCR|HKU|HKCC):|^Registry::|Shell\.Application|^(runas|schtasks)(\.exe)?$|^RunAs$')
        Assert-NoViolations (Find-TypeUses $script:Ast '(?i)Win32\.Registry|^(System\.)?Net\.|^WebClient$|^Registry$')
        $verbs = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandParameterAst] -and $n.ParameterName -in @('Verb', 'ComObject', 'Credential') }, $true)
        @($verbs).Count | Should -Be 0
    }

    It 'CD-8 uses no Get-ChildItem -Recurse (Windows PowerShell 5.1 follows links with it), and no Get-ChildItem on a provider path of the registry' {
        $calls = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Get-ChildItem', 'gci', 'dir', 'ls') }, $true)
        foreach ($call in @($calls)) {
            $recurse = @($call.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -like 'r*' })
            $recurse.Count | Should -Be 0 -Because ('Get-ChildItem -Recurse at line ' + $call.Extent.StartLineNumber)
        }
    }

    It 'S-4 S-5 writes to the host only through the writers of the log module: no Write-Host, Write-Output, Write-Warning, Write-Error, Write-Verbose, Write-Information, Out-Host, Out-Default, Write-Progress, Clear-Host, Read-Host' {
        Assert-NoViolations (Find-Commands $script:Ast @('Write-Host', 'Write-Output', 'Write-Warning', 'Write-Error', 'Write-Verbose', 'Write-Information', 'Out-Host', 'Out-Default', 'Write-Progress', 'Clear-Host', 'Read-Host', 'Write-Debug'))
    }

    It 'S-13 sets no alias: the old names are functions' {
        Assert-NoViolations (Find-Commands $script:Ast @('Set-Alias', 'New-Alias', 'sal', 'nal'))
    }

    It 'CD-2 uses no old name of the base, log, ui and file modules' {
        $old = @('Test-IsAdmin', 'Get-FreeSpace', 'Get-WindowsVersion', 'Format-ByteSize', 'Test-ProtectedPath', 'Resolve-SafePath', 'Get-WhitelistState', 'Test-Whitelisted',
            'Write-Info', 'Write-Success', 'Write-SweeprWarning', 'Write-SweeprError', 'Write-DryRun', 'Start-Section', 'Stop-Section', 'Set-SectionActivity', 'Start-Spinner',
            'Stop-Spinner', 'Update-Spinner', 'Enable-DebugMode', 'Test-SafePath', 'Get-SweeprPathSnapshot', 'Test-SweeprPathSnapshot', 'Test-IsReparsePoint', 'Get-PathSize',
            'Get-PathSizeKB', 'Add-SweeprNotMeasured', 'Add-DryRunListEntries', 'Get-CleanupStats', 'Reset-CleanupStats', 'Set-DryRunMode', 'Test-DryRunMode', 'Write-SweeprOperation',
            'Get-SweeprColor', 'Get-SweeprIcon', 'Get-ConfigPath', 'Get-CachePath', 'Test-SweeprCacheOwnerIdle', 'Clear-SweeprAppCache', 'Get-SweeprCacheProfiles', 'Get-SafeDirectoryTreeItems',
            'Get-ValidatedTreeSize', 'ConvertTo-SweeprPsLiteral', 'Get-TreeItemsNoFollow')
        Assert-NoViolations (Find-Commands $script:Ast $old)
    }

    It 'CD-1 loads its dependencies from its own folder: every dot-source line names $PSScriptRoot, and the files are named' {
        $dots = @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot }, $true))
        $dots.Count | Should -BeGreaterThan 0
        foreach ($dot in $dots) { $dot.Extent.Text | Should -Match 'PSScriptRoot' -Because $dot.Extent.Text }
        $text = [System.IO.File]::ReadAllText((Get-FilePath $Leaf), $script:Utf8)
        foreach ($load in $Loads) { $text | Should -Match ([regex]::Escape($load)) -Because $load }
    }

    It 'CD-1 assigns at the top level only to script variables and loads nothing into the scope of the caller: no global variable, no loop, no Set-StrictMode, no error preference, no Set-Location' {
        $assignments = @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) | Where-Object { (Get-EnclosingFunction $_) -eq '' })
        foreach ($assignment in $assignments) {
            $target = $assignment.Left
            if ($target -is [System.Management.Automation.Language.ConvertExpressionAst]) { $target = $target.Child }
            $target | Should -BeOfType [System.Management.Automation.Language.VariableExpressionAst] -Because $assignment.Extent.Text
            $target.VariablePath.UserPath | Should -Not -Be 'ErrorActionPreference' -Because 'the core modules set the preference, these files do not change it'
            $target.VariablePath.IsScript | Should -BeTrue -Because $assignment.Extent.Text
        }
        @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.IsGlobal }, $true)).Count | Should -Be 0
        $loops = @($script:Ast.FindAll({ param($n) ($n -is [System.Management.Automation.Language.ForEachStatementAst]) -or ($n -is [System.Management.Automation.Language.ForStatementAst]) -or ($n -is [System.Management.Automation.Language.WhileStatementAst]) }, $true) | Where-Object { (Get-EnclosingFunction $_) -eq '' })
        $loops.Count | Should -Be 0
        $topCommands = @(Find-Commands $script:Ast @('Set-StrictMode', 'Set-Variable', 'New-Variable', 'Remove-Variable', 'Set-Location', 'Push-Location', 'Pop-Location') | Where-Object { $_.Function -eq '' })
        Assert-NoViolations $topCommands
        Assert-NoViolations (Find-Commands $script:Ast @('Set-Variable', 'New-Variable', 'Remove-Variable', 'Set-Location', 'Push-Location', 'Pop-Location'))
    }

    It 'CD-1 changes neither the environment of the process nor its working directory: no assignment to $env:, no SetEnvironmentVariable, no CurrentDirectory assignment' {
        $envAssign = @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.DriveName -eq 'env' }, $true))
        $envAssign.Count | Should -Be 0
        Assert-NoViolations (Find-MemberCalls $script:Ast @('SetEnvironmentVariable', 'SetCurrentDirectory'))
        $cwd = @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.Left.Member.Extent.Text -eq 'CurrentDirectory' }, $true))
        $cwd.Count | Should -Be 0
    }

    It 'CD-2 2.1 reads only USERPROFILE, LOCALAPPDATA, APPDATA, PROGRAMDATA and PATH from the environment: no SystemRoot, no ProgramFiles(x86), no variable of a tool' {
        $allowed = @('USERPROFILE', 'LOCALAPPDATA', 'APPDATA', 'PROGRAMDATA', 'PATH')
        $reads = @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Extent.Text -eq 'GetEnvironmentVariable' }, $true))
        foreach ($read in $reads) {
            foreach ($argument in @($read.Arguments | Where-Object { $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] })) {
                $argument.Value | Should -BeIn $allowed -Because ('line ' + $read.Extent.StartLineNumber)
            }
        }
        $envVars = @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.DriveName -eq 'env' }, $true))
        foreach ($variable in $envVars) { $variable.VariablePath.UserPath.Substring(4) | Should -BeIn $allowed -Because ('line ' + $variable.Extent.StartLineNumber) }
        Assert-NoViolations (Find-Strings $script:Ast '(?i)SystemRoot|ProgramFiles|GOPATH|GOMODCACHE|MISE_CACHE_DIR|NPM_CONFIG_CACHE')
        Assert-NoViolations (Find-Variables $script:Ast @('IsWindows', 'IsLinux', 'IsMacOS', 'IsCoreCLR'))
    }

    It 'CD-2 uses nothing that only PowerShell 7 knows: no ??, ?., ?[, ternary, -Parallel, ForEach-Object -Parallel, no automatic variable IsWindows' {
        $kinds = @(Get-TokensOf $Leaf | ForEach-Object { $_.Kind.ToString() })
        foreach ($kind in 'QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'Question') { $kinds | Should -Not -Contain $kind -Because $kind }
        $parallel = $script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandParameterAst] -and $n.ParameterName -eq 'Parallel' }, $true)
        @($parallel).Count | Should -Be 0
        $script:Ast.FindAll({ param($n) $n.GetType().Name -in @('TernaryExpressionAst', 'PipelineChainAst', 'NullConditionalMemberAccessAst') }, $true).Count | Should -Be 0
        Assert-NoViolations (Find-Commands $script:Ast @('Get-WmiObject', 'Get-CimInstance'))
    }

    It 'CD-2 is ASCII or UTF-8 with a byte order mark' {
        $bytes = [System.IO.File]::ReadAllBytes((Get-FilePath $Leaf))
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count
        if ($nonAscii -gt 0) { $hasBom | Should -BeTrue -Because 'non-ASCII text needs the byte order mark for Windows PowerShell 5.1' }
        $bytes.Length | Should -BeGreaterThan 0
    }

    It 'CD-6 does not read the preview mode itself: the variable SweeprDryRunMode is read nowhere, and apps.ps1 does not ask Test-SwDryRunMode at all (only the owner path of dev.ps1 may)' {
        Assert-NoViolations (Find-Variables $script:Ast @('SweeprDryRunMode'))
        Assert-NoViolations (Find-Commands $script:Ast @('Test-DryRunMode'))
        if ($script:LeafName -eq 'apps.ps1') { Assert-NoViolations (Find-Commands $script:Ast @('Test-SwDryRunMode')) }
    }
}

Describe 'S-3 the variable SweeprSkipExternalTools belongs to the owner paths of dev.ps1' {
    It 'S-3 apps.ps1 never reads SweeprSkipExternalTools, and dev.ps1 does' {
        $apps = Get-AstOf 'apps.ps1'
        @(Find-Variables $apps @('SweeprSkipExternalTools')).Count | Should -Be 0
        @(Find-Strings $apps '^SweeprSkipExternalTools$').Count | Should -Be 0
        $dev = Get-AstOf 'dev.ps1'
        $uses = @(Find-Variables $dev @('SweeprSkipExternalTools')) + @(Find-Strings $dev '^SweeprSkipExternalTools$')
        $uses.Count | Should -BeGreaterThan 0
    }
}

Describe 'CD-5 S-1 S-4 a whole run in a real run with throwing cmdlets and spy helpers removes nothing on its own' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-ScanSpy
        $script:SweeprDryRunMode = $false
    }
    AfterEach { Stop-Case }

    It 'CD-5 offers its rows only to the four sinks: a real run of both sections leaves every fixture file in place and calls no forbidden cmdlet' {
        New-PlaceholderFolders
        $files = [System.Collections.Generic.List[string]]::new()
        foreach ($rest in @('Local', 'Yarn', 'Cache', 'a.bin'), @('Profile', '.bun', 'install', 'cache', 'b.bin'), @('Roam', 'Code', 'Cache', 'c.bin'), @('Roam', 'Adobe', 'Common', 'Media Cache Files', 'd.cache'),
            @('Local', 'EpicGamesLauncher', 'Saved', 'webcache', 'e.bin'), @('Profile', 'Videos', 'Medal', 'f.mp4'), @('Local', 'Microsoft', 'MSBuild', 'temp', 'g.bin')) {
            $path = Get-BaseFolder $rest[0]
            foreach ($segment in $rest[1..($rest.Count - 1)]) { $path = P $path $segment }
            $files.Add((New-OldFile $path 200))
        }
        Use-ThrowingCmdlets
        { Invoke-SwDevCleanup } | Should -Not -Throw
        { Invoke-SwAppCleanup -IncludeGameMedia } | Should -Not -Throw
        foreach ($file in $files) { [System.IO.File]::Exists($file) | Should -BeTrue -Because $file }
        foreach ($name in $script:NeverCalled) {
            if ($null -ne (Get-Command -Name $name -ErrorAction SilentlyContinue)) { Should -Invoke $name -Times 0 -Exactly }
        }
        Should -Invoke Move-SwItemToRecycleBin -Times 0 -Exactly
        Should -Invoke Remove-SwItem -Times 0 -Exactly
        $script:Calls.Count | Should -BeGreaterThan 10 -Because 'the helpers were offered the rows'
    }
}

Describe 'CD-7 S-11 one offer per place: the rows of the tables do not overlap' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-ScanSpy
        New-PlaceholderFolders
    }
    AfterEach { Stop-Case }

    It 'CD-7 offers no path twice and none below another in the section Developer tools' {
        Invoke-SwDevCleanup
        $paths = @(Get-Offered)
        $paths.Count | Should -BeGreaterThan 30
        Test-Disjoint $paths | Should -BeTrue
    }

    It 'CD-7 offers no path twice and none below another in the section Applications with the game media' {
        Invoke-SwAppCleanup -IncludeGameMedia
        $paths = @(Get-Offered)
        $paths.Count | Should -BeGreaterThan 20
        Test-Disjoint $paths | Should -BeTrue
        $fileRoots = @(Get-FileRowRoots)
        $fileRoots.Count | Should -Be 5 -Because 'four Office bases and DriveFS'
        (@($fileRoots | ForEach-Object { Fold $_ } | Select-Object -Unique)).Count | Should -Be 5
        foreach ($root in $fileRoots) { @($paths | Where-Object { (Fold $_) -eq (Fold $root) }).Count | Should -Be 0 -Because $root }
    }

    It 'CD-7 offers no path of one section below or above a path of the other: Developer tools against Applications and game media' {
        Invoke-SwDevCleanup
        $dev = @(Get-Offered)
        $script:Calls.Clear()
        $script:ScanCalls.Clear()
        Invoke-SwAppCleanup -IncludeGameMedia
        $apps = @(Get-Offered)
        $clash = Test-CrossDisjoint $dev $apps
        $null -eq $clash | Should -BeTrue -Because $clash
    }

    It 'CD-7 S-11 leaves to caches.ps1, user.ps1 and these two files each their own places: no path is offered by both' {
        Invoke-SwDevCleanup
        Invoke-SwAppCleanup -IncludeGameMedia
        $ours = @(Get-Offered)
        $script:Calls.Clear()
        $script:ScanCalls.Clear()
        foreach ($section in 'Clear-SwBrowserCaches', 'Clear-SwAppCaches') { try { & $section } catch { $null = $_ } }
        try { Invoke-SwUserCleanup -TempDaysOld 7 -LogDaysOld 7 } catch { $null = $_ }
        $theirs = @(Get-Offered)
        $theirs.Count | Should -BeGreaterThan 0
        $clash = Test-CrossDisjoint $ours $theirs
        $null -eq $clash | Should -BeTrue -Because $clash
    }

    It 'S-11 gives the browser and application cache section no row for VS Code, Zed, Sublime, cpptools, the Epic webcache or Steam' {
        foreach ($section in 'Clear-SwBrowserCaches', 'Clear-SwAppCaches') { try { & $section } catch { $null = $_ } }
        $paths = @(Get-Offered)
        foreach ($forbidden in (P $script:Roam 'Code'), (P $script:Roam 'Code - Insiders'), (P $script:Roam 'Zed'), (P $script:Local 'Zed'), (P $script:Roam 'Sublime Text'), (P $script:Local 'Sublime Text'),
            (P $script:Local 'Microsoft' 'vscode-cpptools'), (P $script:Local 'EpicGamesLauncher'), (P $script:Local 'Steam')) {
            Test-AnyUnder $paths $forbidden | Should -BeFalse -Because $forbidden
        }
    }
}

Describe 'CD-30 S-12 the never-list and the dropped rows' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-ScanSpy
        New-PlaceholderFolders
    }
    AfterEach { Stop-Case }

    It 'CD-30 S-12 offers no path that is equal to, below or above a path of the never-list, in the developer tool section and the Applications section with game media' {
        Invoke-SwDevCleanup
        Invoke-SwAppCleanup -IncludeGameMedia
        $paths = @(Get-AllOffered)
        $paths.Count | Should -BeGreaterThan 40
        foreach ($never in (Get-NeverList)) {
            foreach ($path in $paths) {
                (Test-SameOrUnder $path $never) | Should -BeFalse -Because ($path + ' is not allowed under ' + $never)
                (Test-Under $never $path) | Should -BeFalse -Because ($path + ' must not lie above ' + $never)
            }
        }
    }

    It 'CD-30 S-12 offers none of the dropped rows: <Label>' -ForEach $script:DroppedRows {
        Invoke-SwDevCleanup
        Invoke-SwAppCleanup -IncludeGameMedia
        $dropped = Get-BaseFolder $Base
        foreach ($segment in @($Rest)) { $dropped = P $dropped $segment }
        $paths = @(Get-AllOffered)
        foreach ($path in $paths) {
            (Test-SameOrUnder $path $dropped) | Should -BeFalse -Because ($path + ' is under ' + $dropped)
            (Test-Under $dropped $path) | Should -BeFalse -Because ($path + ' is above ' + $dropped)
        }
    }

    It 'CD-30 reads no Steam folder: ProgramFiles(x86) set to a folder with Steam in it changes nothing in what is offered' {
        $steam = P $script:Work 'pf86' 'Steam' 'appcache' 'httpcache'
        $null = New-File (P $steam 'x') 3
        Invoke-SwDevCleanup
        Invoke-SwAppCleanup -IncludeGameMedia
        $without = @(Get-AllOffered | Sort-Object)
        $script:Calls.Clear()
        $script:ScanCalls.Clear()
        Set-Env 'ProgramFiles(x86)' (P $script:Work 'pf86')
        try {
            Invoke-SwDevCleanup
            Invoke-SwAppCleanup -IncludeGameMedia
            $with = @(Get-AllOffered | Sort-Object)
        }
        finally { Set-Env 'ProgramFiles(x86)' $null }
        $with | Should -Be $without
        Test-AnyUnder $with (P $script:Work 'pf86') | Should -BeFalse
    }
}

Describe 'CD-30 S-2 S-4 S-12 whole runs with real helpers: the never-list stays, a preview changes nothing' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -Real
        Use-RecordingScan
        New-PlaceholderFolders
        $script:Keep = [System.Collections.Generic.List[string]]::new()
        foreach ($path in 'Profile|.gradle/caches/build-cache-1/build-cache-1.lock', 'Profile|.gradle/caches/modules-2/x.bin', 'Profile|.m2/repository/org/a.jar', 'Profile|.cargo/registry/cache/a.crate',
            'Profile|.rustup/toolchains/t/bin', 'Profile|.cabal/store/ghc/lib.a', 'Profile|.stack/programs/ghc/bin.exe', 'Profile|.hex/packages/hexpm/phoenix/mix.exs', 'Profile|.mix/archives/x.ez',
            'Profile|.aws/cli/cache/x.json', 'Profile|.azure/c.json', 'Profile|.kube/cache/x.json', 'Profile|.docker/config.json', 'Profile|.ssh/id', 'Profile|.claude/x', 'Profile|.codex/x',
            'Profile|.gitconfig', 'Profile|.gitconfig.lock', 'Profile|.nuget/packages/p/p.nupkg', 'Roam|npm/node_modules/x', 'Roam|Docker/x', 'Local|Docker/x', 'Roam|Code/User/settings.json',
            'Roam|Code/workspaceStorage/w/state', 'Local|JetBrains/IntelliJ/x', 'Roam|JetBrains/IntelliJ/x', 'Local|pypoetry/Cache/virtualenvs/p/python', 'Roam|Adobe/Common/Team Projects Cache/project.db',
            'Roam|GitHub CLI/hosts.yml', 'Profile|Pictures/Screenshots/s.png', 'Profile|Videos/Screen Recordings/r.mp4', 'Profile|Documents/League of Legends/Replays/l.rofl') {
            $parts = $path -split '\|'
            $full = Get-BaseFolder $parts[0]
            foreach ($segment in ($parts[1] -split '/')) { $full = P $full $segment }
            $script:Keep.Add((New-OldFile $full 400))
        }
        # what the sections do clear
        $script:Gone = [System.Collections.Generic.List[string]]::new()
        foreach ($path in 'Profile|.stack/snapshots/p/x.tmp', 'Roam|gcloud/logs/old.log', 'Local|node-gyp/Cache/x', 'Roam|Adobe/Common/Media Cache Files/clip.cache', 'Local|EpicGamesLauncher/Saved/webcache/x',
            'Profile|Videos/Medal/old.mp4', 'Local|Microsoft/MSBuild/temp/t.bin') {
            $parts = $path -split '\|'
            $full = Get-BaseFolder $parts[0]
            foreach ($segment in ($parts[1] -split '/')) { $full = P $full $segment }
            $script:Gone.Add((New-OldFile $full 200))
        }
    }
    AfterEach { Stop-Case }

    It 'CD-30 S-12 removes the cache rows in a real run and keeps every file of the never-list and every neighbor, and the search is never asked about .m2 or .gradle' {
        $script:SweeprDryRunMode = $false
        Invoke-SwDevCleanup
        Invoke-SwAppCleanup -IncludeGameMedia
        foreach ($file in $script:Keep) { [System.IO.File]::Exists($file) | Should -BeTrue -Because $file }
        foreach ($file in $script:Gone) { [System.IO.File]::Exists($file) | Should -BeFalse -Because $file }
        foreach ($root in (Get-ScanRoots)) {
            Test-SameOrUnder $root (P $script:Profile '.m2') | Should -BeFalse
            Test-SameOrUnder $root (P $script:Profile '.gradle') | Should -BeFalse
        }
    }

    It 'S-4 CD-6 lists the same rows in a preview, removes nothing, writes no log line and leaves the file tree exactly as it was' {
        $before = @((Get-Listing $script:Profile), (Get-Listing $script:ProgramData))
        $script:SweeprDryRunMode = $true
        Use-Collectors
        Invoke-SwDevCleanup
        Invoke-SwAppCleanup -IncludeGameMedia
        Same-Listing (Get-Listing $script:Profile) $before[0] | Should -BeTrue
        Same-Listing (Get-Listing $script:ProgramData) $before[1] | Should -BeTrue
        $script:Ops.Count | Should -Be 0
        $listed = @($script:DryRunCollector | ForEach-Object { Fold $_.Path })
        foreach ($file in $script:Keep) { Test-AnyUnder $listed $file | Should -BeFalse -Because $file }
        foreach ($file in $script:Gone) { $listed | Should -Contain (Fold $file) }
    }

    It 'S-4 CD-6 CA-13 gives the preview the same number of lines as a real run counts files, for the rows without an owner command' {
        $script:SweeprDryRunMode = $true
        Use-Collectors
        Invoke-SwDevCleanup
        Invoke-SwAppCleanup -IncludeGameMedia
        $lines = $script:DryRunCollector.Count
        $script:SweeprDryRunMode = $false
        $script:FilesCleaned = 0
        Invoke-SwDevCleanup
        Invoke-SwAppCleanup -IncludeGameMedia
        $script:FilesCleaned | Should -Be $lines
    }
}

Describe 'S-9 S-14 a whole run writes nothing to the pipeline and throws nothing under every error preference' {
    BeforeEach {
        Set-StrictMode -Version Latest
        Initialize-Case
        Use-ScanSpy
        New-PlaceholderFolders
    }
    AfterEach { Stop-Case; $ErrorActionPreference = 'Stop' }

    It 'S-14 CD-2 writes nothing to the pipeline and throws nothing under <Preference>, for both sections, in a preview and a real run' -ForEach @(@{ Preference = 'Stop' }, @{ Preference = 'Continue' }, @{ Preference = 'SilentlyContinue' }) {
        $ErrorActionPreference = $Preference
        foreach ($dry in $true, $false) {
            $script:SweeprDryRunMode = $dry
            { Invoke-SwDevCleanup } | Should -Not -Throw
            { Invoke-SwAppCleanup -IncludeGameMedia } | Should -Not -Throw
            (Invoke-Captured { Invoke-SwDevCleanup }).Count | Should -Be 0
            (Invoke-Captured { Invoke-SwAppCleanup -IncludeGameMedia }).Count | Should -Be 0
        }
    }
}
