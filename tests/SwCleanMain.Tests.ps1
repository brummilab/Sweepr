# Sweepr - tests for bin\clean.ps1 as a script: the parameter block, loading and dot-sourcing, the
# check of the installation path (Get-SwPathCollision), the order of the options (Invoke-SwCleanMain),
# the dry-run switch from SWEEPR_DRY_RUN and the behavior of the whole script in a child process.
#
# The rule numbers in the test names (CL-, SI-, S-, K- and so on) number the rules and the
# safety invariants of the cleanup core's behavior; each rule and invariant has at least one test.
# The other clean test files are SwCleanRun (Start-SwCleanRun, Show-SwCleanSummary), SwCleanEditor (help and
# whitelist editor), SwCleanGuard, SwCleanUser, SwCleanCaches, SwCleanSystem and SwCleanSafety.
#
# Interface pinned here (bin\clean.ps1):
#   Parameter block: [CmdletBinding(PositionalBinding = $false)], seven [switch] parameters DryRun (dry-run),
#   System (s), GameMedia (game-media), GpuShaders (gpu-shaders), DebugMode (d), Whitelist (w), ShowHelp (h).
#   Invoke-SwCleanMain -DryRun -System -GameMedia -GpuShaders -DebugMode -Whitelist -ShowHelp   one [int]
#   Get-SwPathCollision -Path [-Edition]                                                       message or $null
#
# Seams used with Mock: Start-SwCleanRun, Show-SwCleanHelp, Edit-SwWhitelist, Enable-SwDebugMode and
# Set-SwDryRunMode (in-process tests of Invoke-SwCleanMain), the writers of the log module.
# Child-process tests copy the script and the core modules into a fake installation below $TestDrive and
# replace the section files (preview, dev, apps, projects) by a stand-in runner that prints what it was
# given; USERPROFILE, LOCALAPPDATA, APPDATA, TEMP and SWEEPR_DATA_DIR of the child point into $TestDrive,
# no editor is ever started and nothing real is cleaned.
#
# Platform notes:
#   - Paths are built from $TestDrive with the separator of the host. The collision check is called with
#     the edition Desktop on every host (the pattern rules of pwsh 7 are enough); the real Windows
#     PowerShell 5.1 case is marked [W].
#   - Tests marked [W] need real Windows. They are meant to fail on Linux and belong in
#     tests/linux-known-failures.txt.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    $script:Preferences = @('Stop', 'Continue', 'SilentlyContinue')
    $script:DryValues = @(
        @{ Label = 'the value 1'; Value = '1'; Dry = $true }
        @{ Label = 'the value 1 with a trailing space'; Value = '1 '; Dry = $true }
        @{ Label = 'the value true'; Value = 'true'; Dry = $true }
        @{ Label = 'the value yes'; Value = 'yes'; Dry = $true }
        @{ Label = 'the value TRUE'; Value = 'TRUE'; Dry = $true }
        @{ Label = 'the value 0'; Value = '0'; Dry = $false }
        @{ Label = 'the value 0 with spaces'; Value = ' 0 '; Dry = $false }
        @{ Label = 'blank'; Value = '   '; Dry = $false }
        @{ Label = 'not set'; Value = $null; Dry = $false }
    )
    $script:Aliases = @(
        @{ Alias = '-dry-run'; Expect = 'dry=True' }
        @{ Alias = '-s'; Expect = 'system=False' }
        @{ Alias = '-game-media'; Expect = 'media=True' }
        @{ Alias = '-gpu-shaders'; Expect = 'gpu=True' }
        @{ Alias = '-d'; Expect = 'debug=1' }
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
    $script:Pwsh = (Get-Process -Id $PID).Path
    . $script:CleanScript

    # ---- the script as an abstract syntax tree -------------------------------------------------------

    function script:Get-ScriptAst {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:CleanScript, [ref]$tokens, [ref]$errors)
    }

    # ---- a fake installation: the script, the core modules and a stand-in section runner ------------

    $script:RunnerStub = @'
# Stand-in for the section runner: prints what it was given, and does what the test asks through SWEEPR_TEST_RUNNER.
function Invoke-SweeprCleanSections {
    param([bool]$IncludeSystem, [bool]$IncludeGameMedia, [bool]$IncludeGpuShaders)
    $mode = [System.Environment]::GetEnvironmentVariable('SWEEPR_TEST_RUNNER')
    $list = ''
    try { $list = [string]$script:ExportListFile } catch { $list = '' }
    try { $null = $undefinedVariableForTest; $strict = 'False' } catch { $strict = 'True' }
    [System.Console]::Out.WriteLine('RUNNER system=' + $IncludeSystem + ' media=' + $IncludeGameMedia + ' gpu=' + $IncludeGpuShaders +
        ' dry=' + (Test-SwDryRunMode) + ' guard=' + $script:SweeprCleanPathGuard + ' env=' + [System.Environment]::GetEnvironmentVariable('SWEEPR_DRY_RUN') +
        ' debug=' + [System.Environment]::GetEnvironmentVariable('SWEEPR_DEBUG') + ' eap=' + $ErrorActionPreference + ' strict=' + $strict + ' list=' + $list)
    if ($mode -eq 'throw') { throw 'runner boom' }
    if ($mode -eq 'hit') {
        $script:TotalSizeCleaned = 4
        $script:FilesCleaned = 1
        Add-SwDryRunListEntries -Description 'Fake hits' -Paths @('/fake/path') -SizeBytes @(4096) -FileCounts @(1)
    }
}
'@
    $script:InstallCounter = 0
    function script:New-FakeInstall {
        $script:InstallCounter++
        $root = New-Dir (P $TestDrive ('install' + $script:InstallCounter))
        $null = New-Dir (P $root 'bin')
        $null = New-Dir (P $root 'lib' 'core')
        $null = New-Dir (P $root 'lib' 'clean')
        Copy-Item -LiteralPath $script:CleanScript -Destination (P $root 'bin' 'clean.ps1')
        foreach ($file in Get-ChildItem -LiteralPath $script:CoreDir -Filter '*.ps1' -File) { Copy-Item -LiteralPath $file.FullName -Destination (P $root 'lib' 'core' $file.Name) }
        foreach ($name in 'user.ps1', 'caches.ps1', 'cache_guard.ps1', 'system.ps1') {
            $source = P $script:CleanDir $name
            if ([System.IO.File]::Exists($source)) { Copy-Item -LiteralPath $source -Destination (P $root 'lib' 'clean' $name) }
        }
        [System.IO.File]::WriteAllText((P $root 'lib' 'clean' 'preview.ps1'), $script:RunnerStub, $script:Utf8)
        foreach ($name in 'dev.ps1', 'apps.ps1', 'projects.ps1') { [System.IO.File]::WriteAllText((P $root 'lib' 'clean' $name), '# stand-in', $script:Utf8) }
        $version = P $script:RepoRoot 'VERSION'
        if ([System.IO.File]::Exists($version)) { Copy-Item -LiteralPath $version -Destination (P $root 'VERSION') }
        $root
    }
    # Runs the script of a fake installation as a file, like powershell -File bin\clean.ps1.
    function script:Invoke-CleanScript {
        param([string]$Install, [string]$Arguments = '', [hashtable]$Environment = @{}, [string[]]$RemoveEnvironment = @())
        $profileDir = New-Dir (P $TestDrive 'childprofile')
        $childEnv = @{
            USERPROFILE = $profileDir; HOME = $profileDir; LOCALAPPDATA = (P $profileDir 'AppData' 'Local'); APPDATA = (P $profileDir 'AppData' 'Roaming')
            TEMP = (New-Dir (P $TestDrive 'childtemp')); PROGRAMDATA = (P $TestDrive 'childprogramdata'); SWEEPR_DATA_DIR = (P $TestDrive 'childdata')
            SWEEPR_NO_OPLOG = '1'
        }
        foreach ($key in $Environment.Keys) { $childEnv[$key] = $Environment[$key] }
        $remove = @('SWEEPR_DRY_RUN', 'SWEEPR_DEBUG', 'SWEEPR_TEST_RUNNER', '_SWEEPR_OPLOG_RUN_COMMAND', '_SWEEPR_OPLOG_RUN_ID') + @($RemoveEnvironment)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:Pwsh
        $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (P $Install 'bin' 'clean.ps1') + '" ' + $Arguments
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.WorkingDirectory = (New-Dir (P $TestDrive 'childcwd'))
        foreach ($name in $remove) { if ($psi.EnvironmentVariables.ContainsKey($name)) { $psi.EnvironmentVariables.Remove($name) } }
        foreach ($key in $childEnv.Keys) { if ($null -ne $childEnv[$key]) { $psi.EnvironmentVariables[$key] = [string]$childEnv[$key] } }
        $process = [System.Diagnostics.Process]::Start($psi)
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(180000)) { $process.Kill(); throw 'child PowerShell timed out' }
        [pscustomobject]@{ ExitCode = $process.ExitCode; Out = $stdout.Result; Err = (Get-ChildStderr $stderr.Result); Install = $Install }
    }
    function script:Get-RunnerLine([string]$Text) {
        $line = @($Text -split "`r?`n" | Where-Object { $_.StartsWith('RUNNER ') })
        if ($line.Count -eq 0) { return $null }
        $line[0]
    }
    function script:Get-ChildListPath { P $TestDrive 'childdata' 'config' 'clean-list.txt' }
    function script:Use-MainSpies {
        $script:Order = [System.Collections.Generic.List[string]]::new()
        $script:RunCalls = [System.Collections.Generic.List[object]]::new()
        $script:RunResult = 0
        $script:EditFails = $false
        $script:DryModeCalls = 0
        Mock Start-SwCleanRun {
            $script:Order.Add('run')
            $script:RunCalls.Add([pscustomobject]@{ Dry = $IsDryRun; System = $IncludeSystem; Media = $IncludeGameMedia; Gpu = $IncludeGpuShaders; Env = [System.Environment]::GetEnvironmentVariable('SWEEPR_DRY_RUN') })
            $script:RunResult
        }
        Mock Show-SwCleanHelp { $script:Order.Add('help') }
        Mock Edit-SwWhitelist { $script:Order.Add('edit'); if ($script:EditFails) { throw 'edit failed (test)' } }
        Mock Enable-SwDebugMode { $script:Order.Add('debug') }
        Mock Set-SwDryRunMode { $script:DryModeCalls++ }
    }

    # True when the node lies inside a function definition.
    function script:Test-InsideFunction($Node) {
        $parent = $Node.Parent
        while ($null -ne $parent) {
            if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $true }
            $parent = $parent.Parent
        }
        $false
    }
}

AfterAll {
    Clear-TestLinks
    Restore-State $script:RootState
    Restore-Env $script:RootEnv
    [System.Environment]::CurrentDirectory = $script:RootDirectory
}

# ============================================================================
# The parameter block (CL-1, 2.1, router)
# ============================================================================

Describe 'bin\clean.ps1 parameter block' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        $script:Ast = Get-ScriptAst
        $script:Block = $script:Ast.ParamBlock
    }

    It 'CL-1 declares a param block' {
        $script:Block | Should -Not -BeNullOrEmpty
    }

    It 'CL-1 declares exactly the seven options as [switch] parameters' {
        $names = @($script:Block.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        @($names | Sort-Object) | Should -Be @('DebugMode', 'DryRun', 'GameMedia', 'GpuShaders', 'ShowHelp', 'System', 'Whitelist')
        foreach ($parameter in $script:Block.Parameters) {
            $parameter.StaticType.FullName | Should -Be 'System.Management.Automation.SwitchParameter' -Because $parameter.Name.VariablePath.UserPath
        }
    }

    It 'CL-1 gives each option its alias: <Parameter> as <Alias>' -ForEach @(
        @{ Parameter = 'DryRun'; Alias = 'dry-run' }
        @{ Parameter = 'System'; Alias = 's' }
        @{ Parameter = 'GameMedia'; Alias = 'game-media' }
        @{ Parameter = 'GpuShaders'; Alias = 'gpu-shaders' }
        @{ Parameter = 'DebugMode'; Alias = 'd' }
        @{ Parameter = 'Whitelist'; Alias = 'w' }
        @{ Parameter = 'ShowHelp'; Alias = 'h' }
    ) {
        $parameter = @($script:Block.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $Parameter })[0]
        $aliases = @($parameter.Attributes | Where-Object { $_.TypeName.Name -eq 'Alias' } | ForEach-Object { $_.PositionalArguments | ForEach-Object { $_.Value } })
        $aliases | Should -Be @($Alias)
    }

    It 'CL-1 gives no option a fixed position' {
        foreach ($parameter in $script:Block.Parameters) {
            foreach ($attribute in @($parameter.Attributes | Where-Object { $_.TypeName.Name -eq 'Parameter' })) {
                @($attribute.NamedArguments | Where-Object { $_.ArgumentName -eq 'Position' }).Count | Should -Be 0 -Because $parameter.Name.VariablePath.UserPath
            }
        }
    }

    It 'CL-1 turns positional binding off for the script' {
        $binding = @($script:Block.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' })
        $binding.Count | Should -Be 1
        $named = @($binding[0].NamedArguments | Where-Object { $_.ArgumentName -eq 'PositionalBinding' })
        $named.Count | Should -Be 1
        $named[0].Argument.Extent.Text | Should -BeExactly '$false'
    }
}

# ============================================================================
# Get-SwPathCollision (CL-6, , S-15)
# ============================================================================

Describe 'Get-SwPathCollision' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        $script:Install = New-Dir (P $script:Work 'Tools [USB]' 'sweepr')
        $script:Decoy = New-Dir (P $script:Work 'Tools U' 'sweepr')
    }
    AfterEach { Stop-Case }

    It 'CL-6 is defined with Path and Edition (both strings)' {
        Assert-Defined @('Get-SwPathCollision')
        (Get-ParamLine 'Get-SwPathCollision' 'Path') | Should -BeLike 'Path|System.String|*'
        (Get-ParamLine 'Get-SwPathCollision' 'Edition') | Should -BeLike 'Edition|System.String|*'
    }

    It 'CL-6 gives a message that names the folder when a pattern folder lies beside it (Desktop)' {
        $message = Get-SwPathCollision -Path $script:Install -Edition 'Desktop'
        $message | Should -Not -BeNullOrEmpty
        $message | Should -BeOfType [string]
        $message.Contains($script:Install) | Should -BeTrue
        $message.Length | Should -BeGreaterThan ($script:Install.Length + 10)
    }

    It 'CL-6 gives $null without the lookalike folder (Desktop)' {
        Remove-Item -LiteralPath (P $script:Work 'Tools U') -Recurse -Force
        Get-SwPathCollision -Path $script:Install -Edition 'Desktop' | Should -BeNullOrEmpty
    }

    It 'CL-6 gives $null for the edition Core, also with the lookalike folder' {
        Get-SwPathCollision -Path $script:Install -Edition 'Core' | Should -BeNullOrEmpty
    }

    It 'CL-6 gives $null for a folder without a pattern character, and resolves nothing' {
        $plain = New-Dir (P $script:Work 'Plain' 'sweepr')
        Get-SwPathCollision -Path $plain -Edition 'Desktop' | Should -BeNullOrEmpty
        Get-SwPathCollision -Path 'C:\Sweepr' -Edition 'Desktop' | Should -BeNullOrEmpty
    }

    It 'CL-6 gives $null for the pattern characters * and ? as well when nothing else matches' {
        Get-SwPathCollision -Path (P $script:Work 'No*Match' 'sweepr') -Edition 'Desktop' | Should -BeNullOrEmpty
    }

    It 'CL-6 replaces control characters of the path in the message by spaces' {
        $tabbed = New-Dir (P $script:Work ('Tools [US' + [char]9 + [char]10 + 'B]') 'sweepr')
        $null = New-Dir (P $script:Work 'Tools S' 'sweepr')
        $message = Get-SwPathCollision -Path $tabbed -Edition 'Desktop'
        $message | Should -Not -BeNullOrEmpty
        [regex]::IsMatch($message, '[\x00-\x1f\x7f]') | Should -BeFalse
    }

    It 'counts an exception while resolving as no collision' {
        Get-SwPathCollision -Path (P $script:Work 'Tools [' 'sweepr') -Edition 'Desktop' | Should -BeNullOrEmpty
        Get-SwPathCollision -Path (P $script:Work 'Tools [z-a]' 'sweepr') -Edition 'Desktop' | Should -BeNullOrEmpty
    }

    It 'CL-6 never throws, also for an empty or odd path' -ForEach @(
        @{ Value = '' }
        @{ Value = '   ' }
        @{ Value = 'C:\Tools [USB]\sweepr' }
        @{ Value = '[' }
    ) {
        { $null = Get-SwPathCollision -Path $Value -Edition 'Desktop' } | Should -Not -Throw
    }

    It 'CL-6 takes the running edition when none is given' {
        $message = Get-SwPathCollision -Path $script:Install
        if ($script:IsDesktop) { $message | Should -Not -BeNullOrEmpty } else { $message | Should -BeNullOrEmpty }
    }

    It 'CL-6 checks the installation folder before it loads the first module, and calls the check once' {
        $ast = Get-ScriptAst
        $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-SwPathCollision' }, $true) |
                Where-Object { $null -eq $_.Parent.Parent -or -not (Test-InsideFunction $_) })
        $calls.Count | Should -Be 1
        $dots = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot }, $true) |
                Where-Object { -not (Test-InsideFunction $_) })
        $dots.Count | Should -BeGreaterThan 0
        $first = ($dots | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1)
        $calls[0].Extent.StartOffset | Should -BeLessThan $first.Extent.StartOffset
    }

    It 'CL-6 S-15 [W] stops Windows PowerShell 5.1 with exit 1 and an empty standard output when a pattern folder lies beside the installation' {
        $install = New-Dir (P $TestDrive 'Tools [USB]' 'sweepr')
        $null = New-Dir (P $TestDrive 'Tools U' 'sweepr')
        foreach ($name in 'bin', 'lib') { Copy-Item -LiteralPath (P $script:RepoRoot $name) -Destination (P $install $name) -Recurse }
        $null = Copy-Item -LiteralPath (P $script:RepoRoot 'bin') -Destination (P $TestDrive 'Tools U' 'sweepr' 'bin') -Recurse
        $null = Copy-Item -LiteralPath (P $script:RepoRoot 'lib') -Destination (P $TestDrive 'Tools U' 'sweepr' 'lib') -Recurse
        $powershell = (Get-Command -Name powershell.exe -ErrorAction Stop).Source
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $powershell
        $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (P $install 'bin' 'clean.ps1') + '" -ShowHelp'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        # the case set fake values for some variables; the child gets the real ones
        foreach ($name in @($script:SavedEnv.Keys)) {
            if ($null -eq $script:SavedEnv[$name]) { if ($psi.EnvironmentVariables.ContainsKey($name)) { $psi.EnvironmentVariables.Remove($name) } }
            else { $psi.EnvironmentVariables[$name] = [string]$script:SavedEnv[$name] }
        }
        $process = [System.Diagnostics.Process]::Start($psi)
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit(120000) | Should -BeTrue
        $process.ExitCode | Should -Be 1
        $stdout.Result.Trim() | Should -BeExactly ''
        (Get-ChildStderr $stderr.Result).Length | Should -BeGreaterThan 0
    }
}

# ============================================================================
# Invoke-SwCleanMain (CL-2, CL-3, CL-15, CL-16, )
# ============================================================================

Describe 'Invoke-SwCleanMain' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-MainSpies
    }
    AfterEach { Stop-Case }

    It 'CL-2 is defined with the seven switches as [bool] parameters with the default $false' {
        Assert-Defined @('Invoke-SwCleanMain')
        foreach ($name in 'DryRun', 'System', 'GameMedia', 'GpuShaders', 'DebugMode', 'Whitelist', 'ShowHelp') {
            (Get-ParamLine 'Invoke-SwCleanMain' $name) | Should -BeLike "$name|System.Boolean|*|mandatory=False|default=`$false" -Because $name
        }
    }

    It 'CL-2 gives exactly one [int] and writes nothing else to the pipeline' {
        $result = @(Invoke-SwCleanMain)
        $result.Count | Should -Be 1
        $result[0] | Should -BeOfType [int]
        $result[0] | Should -Be 0
    }

    It 'CL-2 shows only the help for -ShowHelp and touches nothing else' {
        Set-Env 'SWEEPR_DRY_RUN' 'keep'
        $result = Invoke-SwCleanMain -ShowHelp $true
        $result | Should -Be 0
        @($script:Order) | Should -Be @('help')
        [System.Environment]::GetEnvironmentVariable('SWEEPR_DRY_RUN') | Should -BeExactly 'keep'
        $script:DryModeCalls | Should -Be 0
    }

    It 'CL-2 shows only the help for -ShowHelp together with -Whitelist, and never starts the editor' {
        $result = Invoke-SwCleanMain -ShowHelp $true -Whitelist $true
        $result | Should -Be 0
        @($script:Order) | Should -Be @('help')
    }

    It 'CL-2 shows only the help for -ShowHelp together with -DryRun and runs nothing' {
        $null = Invoke-SwCleanMain -ShowHelp $true -DryRun $true
        @($script:Order) | Should -Be @('help')
    }

    It 'CL-2 starts the editor for -Whitelist, runs nothing and leaves SWEEPR_DRY_RUN alone, also with -DryRun' {
        Set-Env 'SWEEPR_DRY_RUN' 'keep'
        $result = Invoke-SwCleanMain -Whitelist $true -DryRun $true
        $result | Should -Be 0
        @($script:Order) | Should -Be @('edit')
        [System.Environment]::GetEnvironmentVariable('SWEEPR_DRY_RUN') | Should -BeExactly 'keep'
        $script:DryModeCalls | Should -Be 0
    }

    It 'CL-2 CL-8 gives 1 with one error line that names the reason, and runs nothing, when the editor fails' {
        $script:EditFails = $true
        $result = @(Invoke-SwCleanMain -Whitelist $true)
        $result.Count | Should -Be 1
        $result[0] | Should -Be 1
        $errors = @(Get-LogLines 'ERROR')
        $errors.Count | Should -Be 1
        $errors[0] | Should -BeLike '*edit failed (test)*'
        @($script:Order) | Should -Be @('edit')
    }

    It 'CL-2 enables debug mode once before the help' {
        $null = Invoke-SwCleanMain -DebugMode $true -ShowHelp $true
        @($script:Order) | Should -Be @('debug', 'help')
    }

    It 'CL-2 enables debug mode once before the run, and before the editor' {
        $null = Invoke-SwCleanMain -DebugMode $true
        @($script:Order) | Should -Be @('debug', 'run')
        $script:Order.Clear()
        $null = Invoke-SwCleanMain -DebugMode $true -Whitelist $true
        @($script:Order) | Should -Be @('debug', 'edit')
    }

    It 'CL-2 does not enable debug mode without the switch' {
        $null = Invoke-SwCleanMain
        Should -Invoke Enable-SwDebugMode -Times 0 -Exactly
    }

    It 'CL-2 leaves $DebugPreference as it was' {
        $before = $DebugPreference
        $null = Invoke-SwCleanMain -DebugMode $true
        $DebugPreference | Should -Be $before
    }

    It 'CL-2 starts the run once, with IsDryRun as [bool], and nothing before it' {
        $null = Invoke-SwCleanMain
        @($script:Order) | Should -Be @('run')
        $script:RunCalls[0].Dry | Should -BeOfType [bool]
    }

    It 'CL-2 passes the three include switches on as [bool]: <Label>' -ForEach @(
        @{ Label = 'none'; System = $false; Media = $false; Gpu = $false }
        @{ Label = 'system'; System = $true; Media = $false; Gpu = $false }
        @{ Label = 'game media'; System = $false; Media = $true; Gpu = $false }
        @{ Label = 'gpu shaders'; System = $false; Media = $false; Gpu = $true }
        @{ Label = 'all'; System = $true; Media = $true; Gpu = $true }
    ) {
        $null = Invoke-SwCleanMain -System $System -GameMedia $Media -GpuShaders $Gpu
        $call = $script:RunCalls[0]
        $call.System | Should -BeOfType [bool]
        $call.System | Should -Be $System
        $call.Media | Should -Be $Media
        $call.Gpu | Should -Be $Gpu
    }

    It 'CL-3 makes the run a preview and sets SWEEPR_DRY_RUN to 1 with -DryRun, although the variable said 0' {
        Set-Env 'SWEEPR_DRY_RUN' '0'
        $null = Invoke-SwCleanMain -DryRun $true
        $script:RunCalls[0].Dry | Should -BeTrue
        [System.Environment]::GetEnvironmentVariable('SWEEPR_DRY_RUN') | Should -BeExactly '1'
        $script:RunCalls[0].Env | Should -BeExactly '1'
    }

    It 'CL-3 reads SWEEPR_DRY_RUN trimmed: <Label> gives a dry run: <Dry>' -ForEach $script:DryValues {
        Set-Env 'SWEEPR_DRY_RUN' $Value
        $null = Invoke-SwCleanMain
        $script:RunCalls[0].Dry | Should -Be $Dry
        $expected = '0'
        if ($Dry) { $expected = '1' }
        [System.Environment]::GetEnvironmentVariable('SWEEPR_DRY_RUN') | Should -BeExactly $expected
    }

    It 'CL-3 sets the variable before the run starts' {
        Set-Env 'SWEEPR_DRY_RUN' $null
        $null = Invoke-SwCleanMain
        $script:RunCalls[0].Env | Should -BeExactly '0'
    }

    It 'CL-2 gives what the run gives: <Result>' -ForEach @(
        @{ Result = 0 }
        @{ Result = 1 }
    ) {
        $script:RunResult = $Result
        (@(Invoke-SwCleanMain))[0] | Should -Be $Result
    }

    It 'CL-15 gives 1 with one error line that names the reason, and does not throw, when a part fails: <Part>' -ForEach @(
        @{ Part = 'Start-SwCleanRun' }
        @{ Part = 'Show-SwCleanHelp' }
        @{ Part = 'Enable-SwDebugMode' }
    ) {
        Mock $Part { throw 'part failed (test)' }
        $result = @(Invoke-SwCleanMain -ShowHelp ($Part -eq 'Show-SwCleanHelp') -DebugMode ($Part -eq 'Enable-SwDebugMode'))
        $result.Count | Should -Be 1
        $result[0] | Should -Be 1
        @(Get-LogLines 'ERROR' | Where-Object { $_ -like '*part failed (test)*' }).Count | Should -Be 1
    }

    It 'CL-5 CL-15 gives the same results whatever error preference the caller has: <_>' -ForEach $script:Preferences {
        $script:EditFails = $true
        $ErrorActionPreference = $_
        $failed = @(Invoke-SwCleanMain -Whitelist $true)
        $script:EditFails = $false
        $fine = @(Invoke-SwCleanMain -ShowHelp $true)
        $ErrorActionPreference = 'Stop'
        $failed[0] | Should -Be 1
        $fine[0] | Should -Be 0
    }

    It 'CL-16 changes no environment variable but SWEEPR_DRY_RUN, and not the working directory' {
        $before = @{}
        foreach ($entry in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) { $before[[string]$entry.Key] = [string]$entry.Value }
        $cwd = [System.Environment]::CurrentDirectory
        $null = Invoke-SwCleanMain -DryRun $true -System $true -GameMedia $true
        $null = Invoke-SwCleanMain -ShowHelp $true
        $after = @{}
        foreach ($entry in [System.Environment]::GetEnvironmentVariables().GetEnumerator()) { $after[[string]$entry.Key] = [string]$entry.Value }
        $changed = @($after.Keys + $before.Keys | Sort-Object -Unique | Where-Object { $before[$_] -cne $after[$_] })
        @($changed | Where-Object { $_ -ne 'SWEEPR_DRY_RUN' }).Count | Should -Be 0
        [System.Environment]::CurrentDirectory | Should -BeExactly $cwd
    }
}

# ============================================================================
# The script in a child process (CL-1, CL-5, CL-9, CL-13, CL-15, S-11, SI-7)
# ============================================================================

Describe 'bin\clean.ps1 as a file in a child process' {
    BeforeAll {
        $script:Fake = New-FakeInstall
    }

    It 'CL-7 CL-5 shows the help and ends with exit 0, without a run and without a message on the error output' {
        $run = Invoke-CleanScript $script:Fake '-ShowHelp'
        $run.ExitCode | Should -Be 0
        $run.Out | Should -Match 'sw clean'
        $run.Out | Should -Not -Match 'RUNNER '
        $run.Err | Should -BeExactly ''
    }

    It 'CL-5 runs a preview: exit 0, the runner sees the dry-run state, the guard and SWEEPR_DRY_RUN=1' {
        $run = Invoke-CleanScript $script:Fake '-DryRun'
        $run.ExitCode | Should -Be 0
        $line = Get-RunnerLine $run.Out
        $line | Should -Not -BeNullOrEmpty
        $line | Should -Match 'dry=True guard=True env=1 '
        $run.Out | Should -Match 'Clean Your Windows'
        $run.Out | Should -Match 'Dry run complete - no changes made'
        $run.Err | Should -BeExactly ''
    }

    It 'CL-1 runs under StrictMode Latest and with the error preference Stop' {
        $run = Invoke-CleanScript $script:Fake '-DryRun'
        (Get-RunnerLine $run.Out) | Should -Match ' eap=Stop strict=True '
    }

    It 'CL-5 CL-9 sets ExportListFile to clean-list.txt in the configuration folder and writes the list in a preview' {
        $run = Invoke-CleanScript $script:Fake '-DryRun'
        $line = Get-RunnerLine $run.Out
        $line.EndsWith(' list=' + (Get-ChildListPath)) | Should -BeTrue
        [System.IO.File]::Exists((Get-ChildListPath)) | Should -BeTrue
        (Get-FileLines (Get-ChildListPath))[0] | Should -BeLike '# Sweepr Cleanup Preview - *'
    }

    It 'CL-5 runs a real run without the list: exit 0, dry=False, guard=True, SWEEPR_DRY_RUN=0' {
        Remove-Item -LiteralPath (Get-ChildListPath) -Force -ErrorAction SilentlyContinue
        $run = Invoke-CleanScript $script:Fake ''
        $run.ExitCode | Should -Be 0
        (Get-RunnerLine $run.Out) | Should -Match 'dry=False guard=True env=0 '
        $run.Out | Should -Match 'Cleanup complete'
        [System.IO.File]::Exists((Get-ChildListPath)) | Should -BeFalse
    }

    It 'CL-3 reads SWEEPR_DRY_RUN in the script: <Label> gives a dry run: <Dry>' -ForEach $script:DryValues {
        $environment = @{}
        $remove = @()
        if ($null -eq $Value) { $remove = @('SWEEPR_DRY_RUN') } else { $environment['SWEEPR_DRY_RUN'] = $Value }
        $run = Invoke-CleanScript $script:Fake '' $environment $remove
        $run.ExitCode | Should -Be 0
        $expected = 'dry=False'
        $envText = 'env=0'
        if ($Dry) { $expected = 'dry=True'; $envText = 'env=1' }
        (Get-RunnerLine $run.Out) | Should -Match ([regex]::Escape($expected) + '.*' + [regex]::Escape($envText) + ' ')
    }

    It 'CL-1 binds the alias <Alias> to its option' -ForEach $script:Aliases {
        $run = Invoke-CleanScript $script:Fake $Alias
        $run.ExitCode | Should -Be 0
        $run.Out.Contains($Expect) | Should -BeTrue
        $run.Out | Should -Not -Match 'positional parameter'
    }

    It 'CL-1 binds -game-media and -gpu-shaders to the runner flags' {
        $run = Invoke-CleanScript $script:Fake '-game-media -gpu-shaders'
        (Get-RunnerLine $run.Out) | Should -Match 'media=True gpu=True'
    }

    It 'CL-1 binds -h to the help' {
        $run = Invoke-CleanScript $script:Fake '-h'
        $run.ExitCode | Should -Be 0
        $run.Out | Should -Match 'sw clean'
        $run.Out | Should -Not -Match 'RUNNER '
    }

    It 'CL-10 does not ask for administrator rights: -System without them runs the rest and gives exit 0' {
        $run = Invoke-CleanScript $script:Fake '-System'
        $run.ExitCode | Should -Be 0
        (Get-RunnerLine $run.Out) | Should -Match 'system=False'
    }

    It 'CL-1 accepts no words: a word is a binding error and nothing runs' {
        $run = Invoke-CleanScript $script:Fake 'surplus'
        $run.ExitCode | Should -Not -Be 0
        $run.Out | Should -Not -Match 'RUNNER '
    }

    It 'CL-13 ends with exit 1 after the summary when the runner throws, and names the reason' {
        $run = Invoke-CleanScript $script:Fake '-DryRun' @{ SWEEPR_TEST_RUNNER = 'throw' }
        $run.ExitCode | Should -Be 1
        ($run.Out + $run.Err).Contains('runner boom') | Should -BeTrue
        $run.Out | Should -Match 'Dry run complete - no changes made'
    }

    It 'CL-14 K-6 K-10 shows the potential space and the list file after a preview with a hit, and the hit is in the file' {
        $run = Invoke-CleanScript $script:Fake '-DryRun' @{ SWEEPR_TEST_RUNNER = 'hit' }
        $run.ExitCode | Should -Be 0
        $run.Out.Contains('Potential space: ' + (Format-SwByteSize -Bytes 4096) + ' | Items: 1') | Should -BeTrue
        $run.Out.Contains('Detailed file list: ' + (Get-ChildListPath)) | Should -BeTrue
        $text = Get-FileText (Get-ChildListPath)
        $text | Should -Match '# Fake hits'
        $text | Should -Match '/fake/path'
    }

    It 'CL-5 CL-9 makes no list file and no data folder for -ShowHelp' {
        $install = New-FakeInstall
        $data = P $TestDrive 'childdata-help'
        $run = Invoke-CleanScript $install '-ShowHelp' @{ SWEEPR_DATA_DIR = $data }
        $run.ExitCode | Should -Be 0
        $run.Out | Should -Match 'sw clean'
        [System.IO.Directory]::Exists($data) | Should -BeFalse
    }

    It 'CL-5 stops with exit 1, a reason on the error output and nothing run, when a module file is missing' {
        $install = New-FakeInstall
        Remove-Item -LiteralPath (P $install 'lib' 'core' 'file_ops.ps1') -Force
        $run = Invoke-CleanScript $install '-DryRun'
        $run.ExitCode | Should -Be 1
        $run.Err.Length | Should -BeGreaterThan 0
        $run.Out | Should -Not -Match 'Clean Your Windows'
        $run.Out | Should -Not -Match 'RUNNER '
    }

    It 'CL-5 stops with exit 1 and a reason on the error output when a module file has a syntax error' {
        $install = New-FakeInstall
        [System.IO.File]::WriteAllText((P $install 'lib' 'core' 'log.ps1'), "function Broken {`n if ( {`n", $script:Utf8)
        $run = Invoke-CleanScript $install '-DryRun'
        $run.ExitCode | Should -Be 1
        $run.Err.Length | Should -BeGreaterThan 0
        $run.Out | Should -Not -Match 'RUNNER '
    }

    It 'CL-5 S-14 does not change an existing list file in a real run, and replaces it in a preview' {
        $install = New-FakeInstall
        $data = P $TestDrive 'childdata-keep'
        $list = P $data 'config' 'clean-list.txt'
        $null = New-Dir (P $data 'config')
        [System.IO.File]::WriteAllText($list, 'earlier list', $script:Utf8)
        $null = Invoke-CleanScript $install '' @{ SWEEPR_DATA_DIR = $data }
        Get-FileText $list | Should -BeExactly 'earlier list'
        $null = Invoke-CleanScript $install '-DryRun' @{ SWEEPR_DATA_DIR = $data }
        (Get-FileLines $list)[0] | Should -BeLike '# Sweepr Cleanup Preview - *'
    }
}

# ============================================================================
# Loading by dot-sourcing (CL-5, CL-16, SI-7, )
# ============================================================================

Describe 'bin\clean.ps1 loaded by dot-sourcing' {
    BeforeAll {
        $script:FakeDot = New-FakeInstall
    }

    It 'CL-5 defines the six functions, writes nothing, sets nothing and creates nothing' {
        $data = P $TestDrive 'dotdata'
        $script = @'
$ErrorActionPreference = 'Continue'
Set-StrictMode -Off
. __CLEAN__
'DEFINED=' + (@('Invoke-SwCleanMain', 'Start-SwCleanRun', 'Get-SwPathCollision', 'Show-SwCleanSummary', 'Show-SwCleanHelp', 'Edit-SwWhitelist' | Where-Object { Get-Command -Name $_ -CommandType Function -ErrorAction SilentlyContinue }).Count)
'EXPORT=' + [bool](Get-Variable -Name ExportListFile -Scope Script -ErrorAction SilentlyContinue)
'GUARD=' + $script:SweeprCleanPathGuard
'DRYENV=[' + [System.Environment]::GetEnvironmentVariable('SWEEPR_DRY_RUN') + ']'
'DATA=' + [System.IO.Directory]::Exists('__DATA__')
'@
        $script = $script.Replace('__CLEAN__', (ConvertTo-TestLiteral (P $script:FakeDot 'bin' 'clean.ps1'))).Replace('__DATA__', $data)
        $run = Invoke-ChildPowerShell -Script $script -Environment @{ SWEEPR_DATA_DIR = $data; SWEEPR_NO_OPLOG = '1' } -RemoveEnvironment @('SWEEPR_DRY_RUN', 'SWEEPR_DEBUG')
        $run.ExitCode | Should -Be 0
        $lines = @($run.Out -split "`r?`n" | Where-Object { $_.Length -gt 0 })
        $lines | Should -Be @('DEFINED=6', 'EXPORT=False', 'GUARD=False', 'DRYENV=[]', 'DATA=False')
        (Get-ChildStderr $run.Err) | Should -BeExactly ''
    }

    It 'CL-5 leaves StrictMode Latest and the error preference Stop in the loading scope' {
        $script = @'
$ErrorActionPreference = 'Continue'
Set-StrictMode -Off
. __CLEAN__
'EAP=' + $ErrorActionPreference
try { $null = $undefinedVariableForTest; 'STRICT=False' } catch { 'STRICT=True' }
'@
        $script = $script.Replace('__CLEAN__', (ConvertTo-TestLiteral (P $script:FakeDot 'bin' 'clean.ps1')))
        $run = Invoke-ChildPowerShell -Script $script -Environment @{ SWEEPR_DATA_DIR = (P $TestDrive 'dotdata2'); SWEEPR_NO_OPLOG = '1' }
        $run.ExitCode | Should -Be 0
        $lines = @($run.Out -split "`r?`n" | Where-Object { $_.Length -gt 0 })
        $lines | Should -Be @('EAP=Stop', 'STRICT=True')
    }

    It 'CL-5 loading it a second time in the same scope is harmless and silent' {
        $script = @'
. __CLEAN__
. __CLEAN__
'LOADED=' + [bool](Get-Command -Name Invoke-SwCleanMain -CommandType Function -ErrorAction SilentlyContinue)
'@
        $script = $script.Replace('__CLEAN__', (ConvertTo-TestLiteral (P $script:FakeDot 'bin' 'clean.ps1')))
        $run = Invoke-ChildPowerShell -Script $script -Environment @{ SWEEPR_DATA_DIR = (P $TestDrive 'dotdata3'); SWEEPR_NO_OPLOG = '1' }
        $run.ExitCode | Should -Be 0
        @($run.Out -split "`r?`n" | Where-Object { $_.Length -gt 0 }) | Should -Be @('LOADED=True')
    }

    It 'CL-5 throws instead of calling exit when a module file is missing' {
        $install = New-FakeInstall
        Remove-Item -LiteralPath (P $install 'lib' 'core' 'base.ps1') -Force
        $script = @'
try { . __CLEAN__; 'RESULT=loaded' } catch { 'RESULT=threw' }
'AFTER=still running'
'@
        $script = $script.Replace('__CLEAN__', (ConvertTo-TestLiteral (P $install 'bin' 'clean.ps1')))
        $run = Invoke-ChildPowerShell -Script $script -Environment @{ SWEEPR_DATA_DIR = (P $TestDrive 'dotdata4'); SWEEPR_NO_OPLOG = '1' }
        $lines = @($run.Out -split "`r?`n" | Where-Object { $_.Length -gt 0 })
        $lines | Should -Contain 'RESULT=threw'
        $lines | Should -Contain 'AFTER=still running'
    }
}
