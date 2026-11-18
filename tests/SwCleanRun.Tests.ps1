# Sweepr - tests for the run of bin\clean.ps1: Start-SwCleanRun (dry-run state, path guard, header,
# preview list file, administrator decision for --system, section runner call, error handling) and
# Show-SwCleanSummary (heading and detail lines).
#
# The rule numbers in the test names (CL-, SI-, S-, K- and so on) number the rules and the
# safety invariants of the cleanup core's behavior; each rule and invariant has at least one test.
# The other clean test files are SwCleanMain (loading, collision check, options), SwCleanEditor (help and
# whitelist editor), SwCleanGuard, SwCleanUser, SwCleanCaches, SwCleanSystem and SwCleanSafety.
#
# Interface pinned here (functions of bin\clean.ps1, loaded by dot-sourcing):
#   Start-SwCleanRun -IsDryRun [-IncludeSystem] [-IncludeGameMedia] [-IncludeGpuShaders]   one [int]
#   Show-SwCleanSummary -Stats -IsDryRun                                                  nothing
#
# Seams used with Mock: Invoke-SweeprCleanSections (the section runner; a stand-in is defined when it is
# not loaded), Show-SwResultFrame, Clear-Host, Test-SwOutputRedirected, Test-SwAdmin (no test asks the real
# system), Get-SwWindowsVersion, Get-SwFreeSpace, Stop-SwSpinner, Get-Date, Start-Process and the cmdlets
# of the forbidden list (all throw), the writers of the log module and Write-Host. Script variables set
# by tests: ExportListFile, Config, SweeprCleanPathGuard, CurrentSection and the statistics.
#
# Platform notes:
#   - Paths are built from $TestDrive with the separator of the host. A link is a junction on Windows
#     (folders) and a symbolic link elsewhere; a test that cannot create one is skipped.
#   - Tests marked [W] need real Windows. They are meant to fail on Linux and belong in
#     tests/linux-known-failures.txt.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    $script:RunModes = @(
        @{ Mode = 'a preview'; Dry = $true }
        @{ Mode = 'a real run'; Dry = $false }
    )
    # CL-10: the lines of the table, one case each.
    $script:SystemCases = @(
        @{ Label = 'real run, no administrator'; Dry = $false; Admin = 'false'; Warn = 1; AdminInfo = $false; Include = $false }
        @{ Label = 'real run, administrator'; Dry = $false; Admin = 'true'; Warn = 0; AdminInfo = $true; Include = $true }
        @{ Label = 'real run, the query throws'; Dry = $false; Admin = 'throws'; Warn = 1; AdminInfo = $false; Include = $false }
        @{ Label = 'preview, no administrator'; Dry = $true; Admin = 'false'; Warn = 0; AdminInfo = $true; Include = $false }
        @{ Label = 'preview, administrator'; Dry = $true; Admin = 'true'; Warn = 0; AdminInfo = $false; Include = $true }
        @{ Label = 'preview, the query throws'; Dry = $true; Admin = 'throws'; Warn = 0; AdminInfo = $true; Include = $false }
    )
    # CL-9: values of ExportListFile that give no list.
    $script:NoList = @(
        @{ Label = 'not set'; Mode = 'unset' }
        @{ Label = 'empty'; Mode = 'empty' }
        @{ Label = '$null'; Mode = 'null' }
        @{ Label = 'a relative file name'; Mode = 'relative' }
        @{ Label = 'a root-relative path'; Mode = 'rootrelative' }
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

    $script:CleanScript = [System.IO.Path]::Combine($script:BinDir, 'clean.ps1')
    . $script:CleanScript
    if ($null -eq (Get-Command -Name Invoke-SweeprCleanSections -CommandType Function -ErrorAction SilentlyContinue)) {
        function script:Invoke-SweeprCleanSections { param([bool]$IncludeSystem, [bool]$IncludeGameMedia, [bool]$IncludeGpuShaders) }
    }
    # Commands of the forbidden list that this host may not have: stand-ins, so that they can be mocked.
    foreach ($name in 'Stop-Service', 'Set-Service', 'Restart-Service', 'Get-CimInstance', 'Get-WmiObject', 'Clear-RecycleBin', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Invoke-WebRequest', 'Invoke-RestMethod', 'Start-Job', 'Stop-Process') {
        if ($null -eq (Get-Command -Name $name -ErrorAction SilentlyContinue)) { Set-Item -Path ('function:script:' + $name) -Value { } }
    }
    $script:Forbidden = @('Start-Process', 'Stop-Process', 'Stop-Service', 'Set-Service', 'Restart-Service', 'Set-ItemProperty', 'New-ItemProperty',
        'Remove-ItemProperty', 'Invoke-WebRequest', 'Invoke-RestMethod', 'Get-CimInstance', 'Get-WmiObject', 'Remove-Item', 'Move-Item', 'Copy-Item',
        'Rename-Item', 'Invoke-Item', 'Start-Job', 'Clear-RecycleBin')

    # The environment of a run: the section runner, the console and the system queries as spies.
    function script:Use-RunSpies([string]$Admin = 'false') {
        $script:Order = [System.Collections.Generic.List[string]]::new()
        $script:RunnerCalls = [System.Collections.Generic.List[object]]::new()
        $script:Frames = [System.Collections.Generic.List[object]]::new()
        $script:ClearCalls = 0
        $script:SpinnerStops = 0
        $script:AdminCalls = 0
        $script:AdminMode = $Admin
        $script:Redirected = $false
        $script:RunnerBehavior = $null
        Mock Invoke-SweeprCleanSections {
            $script:Order.Add('runner')
            $script:RunnerCalls.Add([pscustomobject]@{ System = $IncludeSystem; GameMedia = $IncludeGameMedia; Gpu = $IncludeGpuShaders
                    DryMode = (Test-SwDryRunMode); Guard = $script:SweeprCleanPathGuard; Files = $script:FilesCleaned })
            if ($null -ne $script:RunnerBehavior) { & $script:RunnerBehavior }
        }
        Mock Get-SwWindowsVersion { @{ Name = 'Windows Contoso 11 Pro'; Version = '10.0'; Build = '1'; Arch = 'x64' } }
        Mock Get-SwFreeSpace { '123GB' }
        Mock Test-SwOutputRedirected { $script:Redirected }
        Mock Clear-Host { $script:ClearCalls++; $script:Order.Add('clear') }
        Mock Stop-SwSpinner { $script:SpinnerStops++ }
        Mock Show-SwResultFrame { $script:Order.Add('frame'); $script:Frames.Add([pscustomobject]@{ Heading = (Remove-Ansi ([string]$Heading)); Details = @($Details | ForEach-Object { Remove-Ansi ([string]$_) }) }) }
        Mock Test-SwAdmin {
            $script:AdminCalls++
            if ($script:AdminMode -eq 'throws') { throw 'identity not readable (test)' }
            $script:AdminMode -eq 'true'
        }
    }
    function script:Use-NoProgram { foreach ($name in $script:Forbidden) { Mock $name { throw 'must not run (test)' } } }
    function script:Get-Details { @($script:Frames[$script:Frames.Count - 1].Details) }
    function script:Get-ListPath { P $script:Work 'config' 'clean-list.txt' }
    function script:Get-StatsTable([long]$KB, [int]$Files, [int]$Owner) { @{ TotalSizeKB = $KB; FilesCleaned = $Files; TotalItems = 1; OwnerCleanups = $Owner } }
}

AfterAll {
    Clear-TestLinks
    Restore-State $script:RootState
    Restore-Env $script:RootEnv
    [System.Environment]::CurrentDirectory = $script:RootDirectory
}

# ============================================================================
# Interface
# ============================================================================

Describe 'Start-SwCleanRun and Show-SwCleanSummary interface' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
    }

    It 'CL-14 CL-3 defines both functions after loading the script by dot-sourcing' {
        Assert-Defined @('Start-SwCleanRun', 'Show-SwCleanSummary')
    }

    It 'makes -IsDryRun a mandatory [bool]' {
        Assert-Defined @('Start-SwCleanRun')
        (Get-ParamLine 'Start-SwCleanRun' 'IsDryRun') | Should -BeLike 'IsDryRun|System.Boolean|*|mandatory=True|default='
    }

    It 'CL-13 gives the three include parameters as [bool] with the default $false' {
        Assert-Defined @('Start-SwCleanRun')
        foreach ($name in 'IncludeSystem', 'IncludeGameMedia', 'IncludeGpuShaders') {
            $line = Get-ParamLine 'Start-SwCleanRun' $name
            $line | Should -BeLike "$name|System.Boolean|*|mandatory=False|default=`$false" -Because $name
        }
    }

    It 'CL-14 gives Show-SwCleanSummary Stats (hashtable) and IsDryRun (bool)' {
        Assert-Defined @('Show-SwCleanSummary')
        (Get-ParamLine 'Show-SwCleanSummary' 'Stats') | Should -BeLike 'Stats|System.Collections.Hashtable|*'
        (Get-ParamLine 'Show-SwCleanSummary' 'IsDryRun') | Should -BeLike 'IsDryRun|System.Boolean|*'
    }
}

# ============================================================================
# Start-SwCleanRun: state, guard, runner (CL-3, CL-4, CL-12, CL-13, CL-15, S-11)
# ============================================================================

Describe 'Start-SwCleanRun state and runner' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-RunSpies
    }
    AfterEach { Stop-Case }

    It 'CL-3 fails to bind without -IsDryRun and starts no run' {
        Assert-Defined @('Start-SwCleanRun')
        if (-not ([System.Console]::IsInputRedirected -or [System.Environment]::GetCommandLineArgs() -contains '-NonInteractive')) {
            Set-ItResult -Skipped -Because 'the host could prompt for the missing parameter'
            return
        }
        { Start-SwCleanRun } | Should -Throw
        $script:RunnerCalls.Count | Should -Be 0
    }

    It 'CL-3 gives exactly one [int] with the value 0 for a run that ends well' {
        $result = @(Start-SwCleanRun -IsDryRun $true)
        $result.Count | Should -Be 1
        $result[0] | Should -BeOfType [int]
        $result[0] | Should -Be 0
    }

    It 'CL-3 CL-12 switches the dry-run state to the value given and leaves it after the run: <Mode>' -ForEach $script:RunModes {
        $script:SweeprDryRunMode = -not $Dry
        $null = Start-SwCleanRun -IsDryRun $Dry
        Test-SwDryRunMode | Should -Be $Dry
        $script:RunnerCalls[0].DryMode | Should -Be $Dry
    }

    It 'CL-12 resets the statistics before the runner starts' {
        $script:TotalSizeCleaned = 50
        $script:FilesCleaned = 5
        $script:TotalItems = 3
        $script:OwnerCleanups = 2
        $null = Start-SwCleanRun -IsDryRun $true
        $script:RunnerCalls[0].Files | Should -Be 0
    }

    It 'CL-12 puts the statistics reset before the dry-run state and both before the runner' {
        Mock Reset-SwCleanupStats { $script:Order.Add('reset') }
        Mock Set-SwDryRunMode { $script:Order.Add('mode:' + $Enabled) }
        $null = Start-SwCleanRun -IsDryRun $true
        $reset = $script:Order.IndexOf('reset')
        $mode = $script:Order.IndexOf('mode:True')
        $runner = $script:Order.IndexOf('runner')
        $reset | Should -BeGreaterOrEqual 0
        $mode | Should -BeGreaterThan $reset
        $runner | Should -BeGreaterThan $mode
    }

    It 'CL-4 S-11 sets the path guard before the runner, also when a test had switched it off, and leaves it on' {
        $script:SweeprCleanPathGuard = $false
        $null = Start-SwCleanRun -IsDryRun $true
        $script:RunnerCalls[0].Guard | Should -BeTrue
        $script:SweeprCleanPathGuard | Should -BeTrue
    }

    It 'CL-13 calls the section runner exactly once' {
        $null = Start-SwCleanRun -IsDryRun $false
        $script:RunnerCalls.Count | Should -Be 1
    }

    It 'CL-13 gives the runner the three flags as [bool] exactly as passed: <Label>' -ForEach @(
        @{ Label = 'none'; GameMedia = $false; Gpu = $false }
        @{ Label = 'game media'; GameMedia = $true; Gpu = $false }
        @{ Label = 'gpu shaders'; GameMedia = $false; Gpu = $true }
        @{ Label = 'both'; GameMedia = $true; Gpu = $true }
    ) {
        $null = Start-SwCleanRun -IsDryRun $true -IncludeGameMedia $GameMedia -IncludeGpuShaders $Gpu
        $call = $script:RunnerCalls[0]
        $call.GameMedia | Should -BeOfType [bool]
        $call.Gpu | Should -BeOfType [bool]
        $call.GameMedia | Should -Be $GameMedia
        $call.Gpu | Should -Be $Gpu
        $call.System | Should -BeFalse
    }

    It 'CL-13 gives the runner no game media and no shaders when they are not asked for' {
        $null = Start-SwCleanRun -IsDryRun $false
        $script:RunnerCalls[0].GameMedia | Should -BeFalse
        $script:RunnerCalls[0].Gpu | Should -BeFalse
    }

    It 'CL-13 reports an exception of the runner, finishes with the summary and gives 1' {
        $script:RunnerBehavior = { throw 'boom' }
        $script:CurrentSection.Active = $true
        $result = @(Start-SwCleanRun -IsDryRun $false)
        $result.Count | Should -Be 1
        $result[0] | Should -Be 1
        @(Get-LogLines 'ERROR' | Where-Object { $_ -like '*boom*' }).Count | Should -Be 1
        $script:Frames.Count | Should -Be 1
        $script:CurrentSection.Active | Should -BeFalse
        $script:SpinnerStops | Should -BeGreaterOrEqual 1
    }

    It 'CL-13 closes the open section and stops the spinner after a run that ends well' {
        $script:CurrentSection.Active = $true
        $null = Start-SwCleanRun -IsDryRun $false
        $script:CurrentSection.Active | Should -BeFalse
        $script:SpinnerStops | Should -BeGreaterOrEqual 1
    }

    It 'CL-15 gives 1 with an error line, and does not throw, when the summary fails' {
        Mock Show-SwResultFrame { throw 'frame broke (test)' }
        $result = @(Start-SwCleanRun -IsDryRun $true)
        $result.Count | Should -Be 1
        $result[0] | Should -Be 1
        @(Get-LogLines 'ERROR' | Where-Object { $_ -like '*frame broke (test)*' }).Count | Should -Be 1
    }

    It 'CL-15 gives 1 with an error line, and does not throw, when the system query for the header fails' {
        Mock Get-SwFreeSpace { throw 'no free space (test)' }
        $result = @(Start-SwCleanRun -IsDryRun $true)
        $result[0] | Should -Be 1
        @(Get-LogLines 'ERROR' | Where-Object { $_ -like '*no free space (test)*' }).Count | Should -Be 1
    }

    It 'CL-15 gives 0 when single targets failed in the operations log' {
        $script:RunnerBehavior = { Write-SweeprOperation -Action 'FAILED' -Path 'x' -Detail 'y'; Write-SweeprOperation -Action 'SKIPPED' -Path 'z' -Detail 'w' }
        (@(Start-SwCleanRun -IsDryRun $false))[0] | Should -Be 0
    }

    It 'CL-16 changes no environment variable and not the working directory' {
        $before = @{}
        foreach ($entry in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) { $before[[string]$entry.Key] = [string]$entry.Value }
        $cwd = [System.Environment]::CurrentDirectory
        $null = Start-SwCleanRun -IsDryRun $true
        $null = Start-SwCleanRun -IsDryRun $false
        $after = @{}
        foreach ($entry in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) { $after[[string]$entry.Key] = [string]$entry.Value }
        (@($before.Keys | Sort-Object) -join '|') | Should -BeExactly (@($after.Keys | Sort-Object) -join '|')
        foreach ($key in $before.Keys) { $after[$key] | Should -BeExactly $before[$key] -Because $key }
        [System.Environment]::CurrentDirectory | Should -BeExactly $cwd
    }

    It 'S-3 starts nothing and calls none of the forbidden cmdlets, in <Mode>' -ForEach $script:RunModes {
        Use-NoProgram
        $script:Config = @{ ConfigPath = (P $script:Work 'config'); CachePath = (P $script:Work 'cache'); WhitelistFile = (P $script:Work 'config' 'whitelist.txt') }
        $script:ExportListFile = Get-ListPath
        $result = @(Start-SwCleanRun -IsDryRun $Dry -IncludeSystem $true)
        $result[0] | Should -Be 0
        foreach ($name in $script:Forbidden) { Should -Invoke $name -Times 0 -Exactly }
    }
}

# ============================================================================
# Start-SwCleanRun: header (CL-11, K-1, K-2, K-3, )
# ============================================================================

Describe 'Start-SwCleanRun header' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-RunSpies
    }
    AfterEach { Stop-Case }

    It 'CL-11 clears the screen once when the output is not redirected' {
        $null = Start-SwCleanRun -IsDryRun $true
        $script:ClearCalls | Should -Be 1
    }

    It 'CL-11 never clears the screen when the output is redirected' {
        $script:Redirected = $true
        $null = Start-SwCleanRun -IsDryRun $true
        $script:ClearCalls | Should -Be 0
    }

    It 'CL-11 ignores a failure of Clear-Host and still runs' {
        Mock Clear-Host { throw 'no console (test)' }
        $result = @(Start-SwCleanRun -IsDryRun $true)
        $result[0] | Should -Be 0
        $script:RunnerCalls.Count | Should -Be 1
    }

    It 'CL-11 puts the screen clearing before the title and the title before the runner and the runner before the summary' {
        Mock Write-Host { $script:Order.Add('host:' + (Remove-Ansi (@($Object | ForEach-Object { [string]$_ }) -join ' '))) }
        $null = Start-SwCleanRun -IsDryRun $true
        $clear = $script:Order.IndexOf('clear')
        $title = -1
        for ($i = 0; $i -lt $script:Order.Count; $i++) { if ($script:Order[$i].Contains('Clean Your Windows')) { $title = $i; break } }
        $clear | Should -BeGreaterOrEqual 0
        $title | Should -BeGreaterThan $clear
        $script:Order.IndexOf('runner') | Should -BeGreaterThan $title
        $script:Order.IndexOf('frame') | Should -BeGreaterThan $script:Order.IndexOf('runner')
    }

    It 'K-1 shows Clean Your Windows in every run: <Mode>' -ForEach $script:RunModes {
        $null = Start-SwCleanRun -IsDryRun $Dry
        (Get-AllText).Contains('Clean Your Windows') | Should -BeTrue
    }

    It 'K-2 shows Dry Run Mode and Preview only, no deletions in a preview' {
        $null = Start-SwCleanRun -IsDryRun $true
        $text = Get-AllText
        $text.Contains('Dry Run Mode') | Should -BeTrue
        $text.Contains('Preview only, no deletions') | Should -BeTrue
    }

    It 'K-2 shows no preview banner in a real run' {
        $null = Start-SwCleanRun -IsDryRun $false
        (Get-AllText).Contains('Dry Run Mode') | Should -BeFalse
    }

    It 'CL-11 K-3 shows the Windows name and the free space in one line: <Mode>' -ForEach $script:RunModes {
        $null = Start-SwCleanRun -IsDryRun $Dry
        @((Get-AllText) -split "`n" | Where-Object { $_.Contains('Windows Contoso 11 Pro') -and $_.Contains('123GB') }).Count | Should -BeGreaterOrEqual 1
    }

    It 'CL-11 points a real run to --dry-run and --whitelist in one hint line' {
        $null = Start-SwCleanRun -IsDryRun $false
        @((Get-AllText) -split "`n" | Where-Object { $_.Contains('--dry-run') -and $_.Contains('--whitelist') }).Count | Should -BeGreaterOrEqual 1
    }
}

# ============================================================================
# Start-SwCleanRun: the system part (CL-10, S-5)
# ============================================================================

Describe 'Start-SwCleanRun system part' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-RunSpies
        Use-NoProgram
    }
    AfterEach { Stop-Case }

    It 'CL-10 handles <Label> as the table says' -ForEach $script:SystemCases {
        $script:AdminMode = $Admin
        $result = @(Start-SwCleanRun -IsDryRun $Dry -IncludeSystem $true)
        $result.Count | Should -Be 1
        $result[0] | Should -Be 0
        $script:RunnerCalls.Count | Should -Be 1
        $script:RunnerCalls[0].System | Should -Be $Include
        @(Get-LogLines 'WARN').Count | Should -Be $Warn
        $adminLines = @(@($script:HostLines) + @(Get-LogLines 'INFO') + @(Get-LogLines 'SUCCESS') | Where-Object { $_ -match '(?i)administrator' })
        if ($AdminInfo) { $adminLines.Count | Should -BeGreaterOrEqual 1 } else { $adminLines.Count | Should -Be 0 }
        if ($Warn -gt 0) { @(Get-LogLines 'WARN')[0] | Should -Match '(?i)administrator' }
    }

    It 'CL-10 asks Test-SwAdmin exactly once when the system part is asked for' -ForEach $script:RunModes {
        $null = Start-SwCleanRun -IsDryRun $Dry -IncludeSystem $true
        $script:AdminCalls | Should -Be 1
    }

    It 'CL-10 does not ask Test-SwAdmin and says nothing about the system part without -IncludeSystem: <Mode>' -ForEach $script:RunModes {
        $null = Start-SwCleanRun -IsDryRun $Dry
        $script:AdminCalls | Should -Be 0
        @(@($script:HostLines) + @($script:Log) | Where-Object { $_ -match '(?i)administrator' }).Count | Should -Be 0
        $script:RunnerCalls[0].System | Should -BeFalse
    }

    It 'S-5 never starts a process to get administrator rights, whatever the answer: <Admin>' -ForEach @(
        @{ Admin = 'true' }
        @{ Admin = 'false' }
        @{ Admin = 'throws' }
    ) {
        $script:AdminMode = $Admin
        $null = Start-SwCleanRun -IsDryRun $false -IncludeSystem $true
        Should -Invoke Start-Process -Times 0 -Exactly
    }
}

# ============================================================================
# Start-SwCleanRun: the preview list (CL-9, S-14, )
# ============================================================================

Describe 'Start-SwCleanRun preview list' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-RunSpies
        $script:Config = @{ ConfigPath = (P $script:Work 'config'); CachePath = (P $script:Work 'cache'); WhitelistFile = (P $script:Work 'config' 'whitelist.txt') }
        $script:ExportListFile = Get-ListPath
    }
    AfterEach { Stop-Case }

    It 'CL-9 creates the list with the folder in a preview, before the runner starts' {
        $script:RunnerBehavior = { $script:ListExistedAtRun = [System.IO.File]::Exists((Get-ListPath)) }
        $script:ListExistedAtRun = $false
        $null = Start-SwCleanRun -IsDryRun $true
        [System.IO.File]::Exists((Get-ListPath)) | Should -BeTrue
        $script:ListExistedAtRun | Should -BeTrue
    }

    It 'CL-9 K-11 starts the list with # Sweepr Cleanup Preview - and the time in the fixed form' {
        Mock Get-Date { [datetime]'2026-10-31T12:34:56' }
        $null = Start-SwCleanRun -IsDryRun $true
        (Get-FileLines (Get-ListPath))[0] | Should -BeExactly '# Sweepr Cleanup Preview - 2026-10-31 12:34:56'
    }

    It 'CL-9 writes the time in the fixed form whatever the culture' {
        Mock Get-Date { [datetime]'2026-10-31T12:34:56' }
        $saved = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            try { [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new('th-TH') }
            catch { Set-ItResult -Skipped -Because 'this host has no culture data for th-TH'; return }
            $null = Start-SwCleanRun -IsDryRun $true
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $saved }
        (Get-FileLines (Get-ListPath))[0] | Should -BeExactly '# Sweepr Cleanup Preview - 2026-10-31 12:34:56'
    }

    It 'CL-9 writes CRLF line ends, UTF-8 without a byte order mark, comment lines only and an empty line after them' {
        $null = Start-SwCleanRun -IsDryRun $true
        $bytes = [System.IO.File]::ReadAllBytes((Get-ListPath))
        $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $bom | Should -BeFalse
        $text = Get-FileText (Get-ListPath)
        $text | Should -Match "`r`n"
        ([regex]::Matches($text, "(?<!`r)`n")).Count | Should -Be 0
        $lines = @($text -split "`r`n")
        $lines[0] | Should -BeLike '# Sweepr Cleanup Preview - *'
        $firstEmpty = [array]::IndexOf($lines, '')
        $firstEmpty | Should -BeGreaterThan 1
        for ($i = 0; $i -lt $firstEmpty; $i++) { $lines[$i].StartsWith('#') | Should -BeTrue -Because "line $i '$($lines[$i])'" }
        foreach ($line in $lines[($firstEmpty + 1)..($lines.Count - 1)]) { $line | Should -BeExactly '' }
    }

    It 'CL-9 names the full path of the whitelist file and the command sw clean --whitelist in the comment' {
        $null = Start-SwCleanRun -IsDryRun $true
        $text = Get-FileText (Get-ListPath)
        $text.Contains($script:Config.WhitelistFile) | Should -BeTrue
        $text.Contains('sw clean --whitelist') | Should -BeTrue
    }

    It 'CL-9 writes a general comment without a path when the whitelist file is not known' {
        $script:Config = @{ ConfigPath = (P $script:Work 'config'); CachePath = (P $script:Work 'cache'); WhitelistFile = '' }
        $null = Start-SwCleanRun -IsDryRun $true
        $lines = @((Get-FileText (Get-ListPath)) -split "`r`n")
        $lines[0] | Should -BeLike '# Sweepr Cleanup Preview - *'
        $text = Get-FileText (Get-ListPath)
        $text.Contains('sw clean --whitelist') | Should -BeTrue
        $text.Contains((P $script:Work 'config')) | Should -BeFalse
    }

    It 'CL-9 replaces what an earlier list held' {
        $null = New-Dir (P $script:Work 'config')
        [System.IO.File]::WriteAllText((Get-ListPath), "OLD CONTENT`r`nmore", $script:Utf8)
        $null = Start-SwCleanRun -IsDryRun $true
        (Get-FileText (Get-ListPath)).Contains('OLD CONTENT') | Should -BeFalse
        (Get-FileLines (Get-ListPath))[0] | Should -BeLike '# Sweepr Cleanup Preview - *'
    }

    It 'CL-9 S-14 does not create, shorten or change the list in a real run' {
        $null = Start-SwCleanRun -IsDryRun $false
        [System.IO.File]::Exists((Get-ListPath)) | Should -BeFalse
        $null = New-Dir (P $script:Work 'config')
        [System.IO.File]::WriteAllText((Get-ListPath), 'earlier list', $script:Utf8)
        $before = [System.IO.File]::ReadAllBytes((Get-ListPath))
        $null = Start-SwCleanRun -IsDryRun $false
        (@([System.IO.File]::ReadAllBytes((Get-ListPath))) -join ',') | Should -BeExactly (@($before) -join ',')
    }

    It 'CL-9 S-13 creates the list literally: Apps [x] never touches the folder Apps x' {
        $bracket = P $script:Work 'Apps [x]' 'config' 'clean-list.txt'
        $decoyFile = New-File (P $script:Work 'Apps x' 'config' 'clean-list.txt') 3
        [System.IO.File]::WriteAllText($decoyFile, 'decoy', $script:Utf8)
        $script:ExportListFile = $bracket
        $null = Start-SwCleanRun -IsDryRun $true
        [System.IO.File]::Exists($bracket) | Should -BeTrue
        Get-FileText $decoyFile | Should -BeExactly 'decoy'
    }

    It 'CL-9 writes a path with a non-ASCII letter in a form that reads back as UTF-8' {
        $white = P $script:Work ('M' + (S 0xFC) + 'ller') 'config' 'whitelist.txt'
        $script:Config = @{ ConfigPath = (P $script:Work 'config'); CachePath = (P $script:Work 'cache'); WhitelistFile = $white }
        $null = Start-SwCleanRun -IsDryRun $true
        (Get-FileText (Get-ListPath)).Contains($white) | Should -BeTrue
        $bytes = [System.IO.File]::ReadAllBytes((Get-ListPath))
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
    }

    It 'CL-9 gives no list, writes no file, notes it once as information and goes on, when ExportListFile is <Label>' -ForEach $script:NoList {
        switch ($Mode) {
            'unset' { Remove-Variable -Name ExportListFile -Scope Script }
            'empty' { $script:ExportListFile = '' }
            'null' { $script:ExportListFile = $null }
            'relative' { $script:ExportListFile = 'clean-list.txt' }
            'rootrelative' { $script:ExportListFile = '\clean-list.txt' }
        }
        $cwd = New-Dir (P $script:Work 'cwd')
        [System.Environment]::CurrentDirectory = $cwd
        $result = @(Start-SwCleanRun -IsDryRun $true)
        $result[0] | Should -Be 0
        @(Get-ChildItem -LiteralPath $cwd -Force).Count | Should -Be 0
        [System.IO.File]::Exists((Get-ListPath)) | Should -BeFalse
        @(Get-LogLines 'WARN').Count | Should -Be 0
        @(Get-LogLines 'INFO' | Where-Object { $_ -match '(?i)list' }).Count | Should -Be 1
        $script:Frames.Count | Should -Be 1
        @(Get-Details | Where-Object { $_ -match 'Detailed file list' }).Count | Should -Be 0
    }

    It 'CL-9 leaves the dry run to the list that is a folder: a warning with the path, no list, result 0' {
        $null = New-Dir (Get-ListPath)
        $result = @(Start-SwCleanRun -IsDryRun $true)
        $result[0] | Should -Be 0
        $warnings = @(Get-LogLines 'WARN')
        $warnings.Count | Should -Be 1
        $warnings[0].Contains((Get-ListPath)) | Should -BeTrue
        $script:ExportListFile | Should -BeNullOrEmpty
        $script:RunnerCalls.Count | Should -Be 1
    }

    It 'CL-9 leaves the list that is a link alone: a warning with the path, the target unchanged, result 0' {
        $null = New-Dir (P $script:Work 'config')
        $target = P $script:Work 'elsewhere' 'target.txt'
        $null = New-Dir (Split-Path -Parent $target)
        [System.IO.File]::WriteAllText($target, 'precious', $script:Utf8)
        if (-not (New-TestLink (Get-ListPath) $target)) { Set-ItResult -Skipped -Because 'this account cannot create a file link'; return }
        $result = @(Start-SwCleanRun -IsDryRun $true)
        $result[0] | Should -Be 0
        Get-FileText $target | Should -BeExactly 'precious'
        @(Get-LogLines 'WARN').Count | Should -Be 1
        $script:ExportListFile | Should -BeNullOrEmpty
    }

    It 'CL-9 warns with the path and the reason when the list cannot be prepared, and goes on without a list' {
        $blocker = New-File (P $script:Work 'a-file') 3
        $script:ExportListFile = P $blocker 'clean-list.txt'
        $result = @(Start-SwCleanRun -IsDryRun $true)
        $result[0] | Should -Be 0
        $warnings = @(Get-LogLines 'WARN')
        $warnings.Count | Should -Be 1
        $warnings[0] | Should -BeLike '*a-file*'
        $script:ExportListFile | Should -BeNullOrEmpty
        $script:RunnerCalls.Count | Should -Be 1
        @(Get-Details | Where-Object { $_ -match 'Detailed file list' }).Count | Should -Be 0
    }

    It 'CL-9 lets the helpers append their blocks after the header' {
        $script:RunnerBehavior = { Add-SwDryRunListEntries -Description 'Example target' -Paths @('/example/path-one', '/example/path-two') -SizeBytes @(1, 2) -FileCounts @(1, 1) }
        $null = Start-SwCleanRun -IsDryRun $true
        $lines = @((Get-FileText (Get-ListPath)) -split "`r`n")
        $at = [array]::IndexOf($lines, '# Example target')
        $at | Should -BeGreaterThan 2
        $lines[$at + 1] | Should -BeExactly '/example/path-one'
        $lines[$at + 2] | Should -BeExactly '/example/path-two'
        $lines[$at + 3] | Should -BeExactly ''
    }

    It 'CL-14 K-10 names the full path of the list file in the summary of a preview that found something' {
        $script:RunnerBehavior = { $script:TotalSizeCleaned = 4; $script:FilesCleaned = 2 }
        $null = Start-SwCleanRun -IsDryRun $true
        $details = @(Get-Details)
        $details.Count | Should -Be 3
        $details[0] | Should -BeExactly ('Potential space: {0} | Items: 2' -f (Format-SwByteSize -Bytes 4096))
        $details[2] | Should -BeExactly ('Detailed file list: ' + (Get-ListPath))
    }
}

# ============================================================================
# Show-SwCleanSummary (CL-14, K-4 to K-10)
# ============================================================================

Describe 'Show-SwCleanSummary' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-RunSpies
        $script:ExportListFile = Get-ListPath
    }
    AfterEach { Stop-Case }

    It 'CL-14 calls Show-SwResultFrame exactly once with a heading and detail lines: <Mode>' -ForEach $script:RunModes {
        Show-SwCleanSummary -Stats (Get-StatsTable 4 2 0) -IsDryRun $Dry
        $script:Frames.Count | Should -Be 1
        $script:Frames[0].Heading.Length | Should -BeGreaterThan 0
        @($script:Frames[0].Details).Count | Should -BeGreaterOrEqual 2
        Should -Invoke Show-SwResultFrame -Times 1 -Exactly
    }

    It 'K-4 uses the heading Dry run complete - no changes made for a preview' {
        Show-SwCleanSummary -Stats (Get-StatsTable 4 2 0) -IsDryRun $true
        $script:Frames[0].Heading | Should -BeExactly 'Dry run complete - no changes made'
    }

    It 'K-5 uses the heading Cleanup complete for a real run' {
        Show-SwCleanSummary -Stats (Get-StatsTable 4 2 0) -IsDryRun $false
        $script:Frames[0].Heading | Should -BeExactly 'Cleanup complete'
    }

    It 'K-6 gives the potential space and the number of items in one line in a preview' {
        Show-SwCleanSummary -Stats (Get-StatsTable 4 2 0) -IsDryRun $true
        (Get-Details)[0] | Should -BeExactly ('Potential space: {0} | Items: 2' -f (Format-SwByteSize -Bytes 4096))
    }

    It 'K-6 builds the size from TotalSizeKB times 1024, not from TotalSizeHuman, also for gigabytes' {
        $stats = Get-StatsTable 3145728 7 0
        $stats['TotalSizeHuman'] = 'WRONG-TEXT'
        Show-SwCleanSummary -Stats $stats -IsDryRun $true
        (Get-Details)[0] | Should -BeExactly ('Potential space: {0} | Items: 7' -f (Format-SwByteSize -Bytes (3145728L * 1024L)))
        (Get-Details)[0] | Should -Not -Match 'WRONG-TEXT'
    }

    It 'K-9 gives the free space in the second line: <Mode>' -ForEach $script:RunModes {
        Show-SwCleanSummary -Stats (Get-StatsTable 4 2 0) -IsDryRun $Dry
        (Get-Details)[1] | Should -BeExactly 'Free space: 123GB'
    }

    It 'K-10 names the full path of the list file in the third line of a preview that found space' {
        Show-SwCleanSummary -Stats (Get-StatsTable 4 2 0) -IsDryRun $true
        $details = @(Get-Details)
        $details.Count | Should -Be 3
        $details[2] | Should -BeExactly ('Detailed file list: ' + (Get-ListPath))
    }

    It 'K-10 names the list file also for a preview with only tool commands' {
        Show-SwCleanSummary -Stats (Get-StatsTable 0 0 1) -IsDryRun $true
        $details = @(Get-Details)
        $details.Count | Should -Be 3
        $details[0] | Should -Not -Match 'Potential space'
        $details[2] | Should -BeExactly ('Detailed file list: ' + (Get-ListPath))
    }

    It 'K-10 gives no list line when nothing was found, when it is a real run, or when there is no list' -ForEach @(
        @{ Label = 'a preview that found nothing'; Dry = $true; Stats = @{ TotalSizeKB = 0; FilesCleaned = 0; TotalItems = 0; OwnerCleanups = 0 }; List = $true }
        @{ Label = 'a real run with space'; Dry = $false; Stats = @{ TotalSizeKB = 4; FilesCleaned = 2; TotalItems = 1; OwnerCleanups = 0 }; List = $true }
        @{ Label = 'a preview with space but no list'; Dry = $true; Stats = @{ TotalSizeKB = 4; FilesCleaned = 2; TotalItems = 1; OwnerCleanups = 0 }; List = $false }
    ) {
        if (-not $List) { $script:ExportListFile = $null }
        Show-SwCleanSummary -Stats $Stats -IsDryRun $Dry
        @(Get-Details | Where-Object { $_ -match 'Detailed file list' }).Count | Should -Be 0
        @(Get-Details).Count | Should -Be 2
    }

    It 'K-10 gives no list line when ExportListFile is missing or empty' -ForEach @(
        @{ Mode = 'unset' }
        @{ Mode = 'empty' }
    ) {
        if ($Mode -eq 'unset') { Remove-Variable -Name ExportListFile -Scope Script } else { $script:ExportListFile = '' }
        Show-SwCleanSummary -Stats (Get-StatsTable 4 2 0) -IsDryRun $true
        @(Get-Details).Count | Should -Be 2
    }

    It 'CL-14 says in a real run how much was freed in how many entries, and not files' {
        Show-SwCleanSummary -Stats (Get-StatsTable 4 2 0) -IsDryRun $false
        $first = (Get-Details)[0]
        $first.Contains((Format-SwByteSize -Bytes 4096)) | Should -BeTrue
        $first | Should -Match '2'
        $first | Should -Match '(?i)(items|entries)'
        $first | Should -Not -Match '(?i)files'
    }

    It 'K-7 says Tool cache cleanup completed, and not already clean, for a real run with only tool commands' {
        Show-SwCleanSummary -Stats (Get-StatsTable 0 0 1) -IsDryRun $false
        $first = (Get-Details)[0]
        $first.Contains('Tool cache cleanup completed') | Should -BeTrue
        $first.Contains('already clean') | Should -BeFalse
    }

    It 'K-8 says already clean for a real run that freed nothing and ran no tool command' {
        Show-SwCleanSummary -Stats (Get-StatsTable 0 0 0) -IsDryRun $false
        (Get-Details)[0].Contains('already clean') | Should -BeTrue
    }

    It 'CL-14 puts the size before the tool commands when both are present in a real run' {
        Show-SwCleanSummary -Stats (Get-StatsTable 4 2 3) -IsDryRun $false
        (Get-Details)[0].Contains((Format-SwByteSize -Bytes 4096)) | Should -BeTrue
    }

    It 'CL-14 counts a missing key as 0 and does not fail: <Label>' -ForEach @(
        @{ Label = 'no OwnerCleanups'; Stats = @{ TotalSizeKB = 4; FilesCleaned = 1 } }
        @{ Label = 'only TotalSizeKB'; Stats = @{ TotalSizeKB = 4 } }
        @{ Label = 'an empty table'; Stats = @{} }
        @{ Label = 'no TotalSizeKB'; Stats = @{ FilesCleaned = 1; OwnerCleanups = 1 } }
    ) {
        { Show-SwCleanSummary -Stats $Stats -IsDryRun $true } | Should -Not -Throw
        { Show-SwCleanSummary -Stats $Stats -IsDryRun $false } | Should -Not -Throw
        $script:Frames.Count | Should -Be 2
    }

    It 'CL-14 gives no Categories: and no --whitelist in any line of a preview' -ForEach @(
        @{ Stats = @{ TotalSizeKB = 4; FilesCleaned = 2; TotalItems = 1; OwnerCleanups = 0 } }
        @{ Stats = @{ TotalSizeKB = 0; FilesCleaned = 0; TotalItems = 0; OwnerCleanups = 1 } }
        @{ Stats = @{ TotalSizeKB = 0; FilesCleaned = 0; TotalItems = 0; OwnerCleanups = 0 } }
    ) {
        Show-SwCleanSummary -Stats $Stats -IsDryRun $true
        foreach ($line in (@($script:Frames[0].Heading) + @(Get-Details))) {
            $line.Contains('Categories:') | Should -BeFalse
            $line.Contains('--whitelist') | Should -BeFalse
        }
    }

    It 'CL-14 says something on the first line of a preview that found nothing, and not that space was found' {
        Show-SwCleanSummary -Stats (Get-StatsTable 0 0 0) -IsDryRun $true
        $first = (Get-Details)[0]
        $first.Length | Should -BeGreaterThan 0
        $first | Should -Not -Match 'Potential space'
    }

    It 'SI-6 writes nothing to the pipeline' {
        @(Show-SwCleanSummary -Stats (Get-StatsTable 4 2 0) -IsDryRun $true).Count | Should -Be 0
    }
}
