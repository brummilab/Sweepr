# Sweepr - tests for the help text and the whitelist editor of bin\clean.ps1 (Show-SwCleanHelp,
# Edit-SwWhitelist): the template, its encoding, the literal folder handling, FileMode.CreateNew,
# links, the editor call with one quoted argument, and the failure paths.
#
# The rule numbers in the test names (CL-, SI-, S-, K- and so on) number the rules and the
# safety invariants of the cleanup core's behavior; each rule and invariant has at least one test.
# The other clean test files are SwCleanMain, SwCleanRun (the rest of the command script), SwCleanGuard,
# SwCleanUser, SwCleanCaches, SwCleanSystem and SwCleanSafety (static and cross checks).
#
# Interface pinned here (functions of bin\clean.ps1, loaded by dot-sourcing):
#   Show-SwCleanHelp                        host lines only, nothing to the pipeline, no data folder needed
#   Edit-SwWhitelist                        creates the file from the template when it is missing, starts
#                                           the editor, throws with path and reason on failure
#
# Seams used with Mock: Start-Process (the editor never starts), Test-Path (the "file is missing" answer
# of an earlier check), the writers of the log module and Write-Host. $script:Config is replaced by a
# table with only the key WhitelistFile, as the tests need.
#
# Platform notes:
#   - Paths are built from $TestDrive with the separator of the host. [Environment]::SystemDirectory is
#     empty on hosts that are not Windows, so the editor path is checked against it only when it is set.
#   - A link is a junction on Windows (folders) and a symbolic link elsewhere; a test that cannot create
#     one is skipped. A link case that needs real Windows is marked [W]; the others run wherever a link can be made.
#   - Tests marked [W] need real Windows. They are meant to fail on Linux and belong in
#     tests/linux-known-failures.txt.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    $script:Preferences = @('Stop', 'Continue', 'SilentlyContinue')
    $script:BadFiles = @(
        @{ Label = 'empty'; Value = '' }
        @{ Label = 'blank'; Value = '   ' }
        @{ Label = 'a bare name'; Value = 'w.txt' }
        @{ Label = 'a relative path'; Value = 'Local\w.txt' }
        @{ Label = 'a root-relative path'; Value = '\config\w.txt' }
        @{ Label = 'a drive-relative path'; Value = 'C:w.txt' }
        @{ Label = 'a UNC path'; Value = '\\server\share\w.txt' }
    )
    $script:Options = @('--dry-run', '--system', '--game-media', '--gpu-shaders', '--whitelist', '--debug', '--help')
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

    function script:Use-EditorSpies {
        $script:Started = [System.Collections.Generic.List[object]]::new()
        Mock Start-Process {
            $script:Started.Add([pscustomobject]@{ FilePath = $FilePath; ArgumentList = @($ArgumentList); Wait = [bool]$Wait; Verb = $Verb })
        }
    }
    function script:Get-FileBytes([string]$Path) { [System.IO.File]::ReadAllBytes($Path) }
    function script:Test-Bom([byte[]]$Bytes) { $Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF }
    function script:Get-TemplateText([string]$Path) {
        $bytes = Get-FileBytes $Path
        $script:Utf8.GetString($bytes, 3, $bytes.Length - 3)
    }
    function script:Set-WhitelistFile([string]$Path) { $script:Config = @{ WhitelistFile = $Path } }
    function script:Get-ListFile { P $script:Work 'config' 'whitelist.txt' }
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

Describe 'bin\clean.ps1 help and editor interface' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
    }

    It 'CL-7 CL-8 defines Show-SwCleanHelp and Edit-SwWhitelist after loading the script by dot-sourcing' {
        Assert-Defined @('Show-SwCleanHelp', 'Edit-SwWhitelist')
    }

    It 'CL-7 CL-8 gives both functions no parameters' {
        Assert-Defined @('Show-SwCleanHelp', 'Edit-SwWhitelist')
        (Get-ParamSignature 'Show-SwCleanHelp').Count | Should -Be 0
        (Get-ParamSignature 'Edit-SwWhitelist').Count | Should -Be 0
    }
}

# ============================================================================
# Show-SwCleanHelp (CL-7, K-13, )
# ============================================================================

Describe 'Show-SwCleanHelp' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-EditorSpies
        $script:HelpResult = @(Show-SwCleanHelp)
        $script:HelpText = Get-AllText
        $script:HelpLines = @($script:HelpText -split "`n")
    }
    AfterEach { Stop-Case }

    It 'CL-7 writes only host lines, nothing to the pipeline' {
        $script:HelpResult.Count | Should -Be 0
        $script:HelpText.Length | Should -BeGreaterThan 100
    }

    It 'K-13 names the command as sw clean and no other product name' {
        $script:HelpText | Should -Match 'sw clean'
        $script:HelpText | Should -Not -Match '(?i)\bmo(le)? clean\b'
        $script:HelpText | Should -Not -Match '(?i)sweepr clean'
    }

    It 'K-13 names the option <_>' -ForEach $script:Options {
        $script:HelpText.Contains($_) | Should -BeTrue
    }

    It 'CL-7 names the short forms -s, -d, -w and -h' {
        foreach ($short in '-s', '-d', '-w', '-h') {
            @($script:HelpLines | Where-Object { $_ -match ('(^|[\s,/(])' + [regex]::Escape($short) + '([\s,/)]|$)') }).Count | Should -BeGreaterOrEqual 1 -Because $short
        }
    }

    It 'CL-7 gives at least three example calls, among them sw clean --dry-run' {
        $examples = @($script:HelpLines | Where-Object { $_ -match 'sw clean\s+-' })
        @($examples | ForEach-Object { $_.Trim() } | Sort-Object -Unique).Count | Should -BeGreaterOrEqual 3
        @($script:HelpLines | Where-Object { $_ -match 'sw clean --dry-run(\s|$)' }).Count | Should -BeGreaterOrEqual 1
    }

    It 'K-13 states in the line of --system that it cleans only old Windows error reports below ProgramData and only as an administrator' {
        $lines = @($script:HelpLines | Where-Object { $_.Contains('--system') -and $_ -match '(?i)programdata' -and $_ -match '(?i)administrator' -and $_ -match '(?i)error report' })
        $lines.Count | Should -BeGreaterOrEqual 1
    }

    It 'says that an elevated run cleans the caches of the elevated account' {
        $script:HelpText | Should -Match '(?i)elevated'
    }

    It 'CL-7 says in one line that --whitelist and the dry run belong together' {
        @($script:HelpLines | Where-Object { $_ -match '(?i)whitelist' -and $_ -match '(?i)dry' }).Count | Should -BeGreaterOrEqual 1
    }

    It 'CL-7 needs no data folder and creates nothing' {
        Remove-Item -LiteralPath $script:Work -Recurse -Force
        $script:Config = $null
        $null = New-Dir $script:Work
        $before = Get-Listing $script:Work
        { Show-SwCleanHelp } | Should -Not -Throw
        $script:Config = @{}
        { Show-SwCleanHelp } | Should -Not -Throw
        Same-Listing (Get-Listing $script:Work) $before | Should -BeTrue
    }

    It 'CL-2 CL-7 touches neither SWEEPR_DRY_RUN nor the dry-run state nor the path guard nor the exit status' {
        Set-Env 'SWEEPR_DRY_RUN' 'keep'
        $script:SweeprDryRunMode = $false
        $script:SweeprCleanPathGuard = $false
        $global:LASTEXITCODE = 77
        $null = Show-SwCleanHelp
        [System.Environment]::GetEnvironmentVariable('SWEEPR_DRY_RUN') | Should -BeExactly 'keep'
        $script:SweeprDryRunMode | Should -BeFalse
        $script:SweeprCleanPathGuard | Should -BeFalse
        $global:LASTEXITCODE | Should -Be 77
    }

    It 'S-3 starts no process' {
        Should -Invoke Start-Process -Times 0 -Exactly
    }
}

# ============================================================================
# Edit-SwWhitelist: creating the file (CL-8, 2.6, S-13, S-14, K-12)
# ============================================================================

Describe 'Edit-SwWhitelist creates the file' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-EditorSpies
        Set-WhitelistFile (Get-ListFile)
    }
    AfterEach { Stop-Case }

    It 'CL-8 creates the folder and the file from the template when both are missing' {
        Edit-SwWhitelist
        [System.IO.File]::Exists((Get-ListFile)) | Should -BeTrue
    }

    It 'CL-8 K-12 writes the template as UTF-8 with a byte order mark and names Sweepr Whitelist in it' {
        Edit-SwWhitelist
        Test-Bom (Get-FileBytes (Get-ListFile)) | Should -BeTrue
        (Get-TemplateText (Get-ListFile)) | Should -Match 'Sweepr Whitelist'
    }

    It 'CL-8 writes a template in which every line is empty or a comment' {
        Edit-SwWhitelist
        $lines = @((Get-TemplateText (Get-ListFile)) -split "`r?`n")
        $lines.Count | Should -BeGreaterThan 5
        foreach ($line in $lines) { ($line.Length -eq 0 -or $line.StartsWith('#')) | Should -BeTrue -Because "'$line'" }
    }

    It 'CL-8 explains the written forms: quotes, a slash, a variable in percent signs, a tilde and a star' {
        Edit-SwWhitelist
        $text = Get-TemplateText (Get-ListFile)
        foreach ($mark in '"', '/', '%', '~', '*') { $text.Contains($mark) | Should -BeTrue -Because $mark }
    }

    It 'CL-8 writes exactly one example line for the folder CriticalApp, a comment with the resolved LOCALAPPDATA' {
        $local = 'C:\Users\Example\AppData\Local'
        Set-Env 'LOCALAPPDATA' $local
        Edit-SwWhitelist
        $lines = @((Get-TemplateText (Get-ListFile)) -split "`r?`n" | Where-Object { $_.Contains('CriticalApp') })
        $lines.Count | Should -Be 1
        $lines[0] | Should -BeExactly ('# ' + $local + '\CriticalApp')
    }

    It 'CL-8 keeps non-ASCII characters of LOCALAPPDATA unchanged in the example line' {
        $local = 'C:\Users\M' + (S 0xFC) + 'ller\AppData\Local'
        Set-Env 'LOCALAPPDATA' $local
        Edit-SwWhitelist
        $bytes = Get-FileBytes (Get-ListFile)
        Test-Bom $bytes | Should -BeTrue
        $lines = @((Get-TemplateText (Get-ListFile)) -split "`r?`n" | Where-Object { $_.Contains('CriticalApp') })
        $lines.Count | Should -Be 1
        $lines[0] | Should -BeExactly ('# ' + $local + '\CriticalApp')
    }

    It 'CL-8 writes the unresolved example when LOCALAPPDATA is not set' {
        Set-Env 'LOCALAPPDATA' $null
        Edit-SwWhitelist
        $lines = @((Get-TemplateText (Get-ListFile)) -split "`r?`n" | Where-Object { $_.Contains('CriticalApp') })
        $lines.Count | Should -Be 1
        $lines[0] | Should -BeExactly '# %LOCALAPPDATA%\CriticalApp'
    }

    It 'CL-8 writes a template whose examples protect nothing' {
        Edit-SwWhitelist
        Test-SwWhitelisted -Path (P $script:Local 'CriticalApp') | Should -BeFalse
        Test-SwWhitelisted -Path (P $script:Roam 'Example' 'Cache') | Should -BeFalse
        Test-SwWhitelisted -Path (P $script:Scratch 'old.tmp') | Should -BeFalse
    }

    It 'CL-8 S-13 creates the data folder literally: Apps [x] never touches the folder Apps x' {
        $bracket = P $script:Work 'Apps [x]' 'config' 'whitelist.txt'
        $decoy = New-File (P $script:Work 'Apps x' 'config' 'whitelist.txt') 5
        [System.IO.File]::WriteAllText($decoy, 'other')
        Set-WhitelistFile $bracket
        Edit-SwWhitelist
        [System.IO.File]::Exists($bracket) | Should -BeTrue
        Get-FileText $decoy | Should -BeExactly 'other'
        @(Get-ChildItem -LiteralPath (P $script:Work 'Apps x' 'config') -Force).Count | Should -Be 1
    }

    It 'S-14 leaves an existing file as it was, byte for byte' {
        $null = New-Dir (Split-Path -Parent (Get-ListFile))
        [System.IO.File]::WriteAllText((Get-ListFile), 'keep me', $script:Utf8)
        $before = Get-FileBytes (Get-ListFile)
        Edit-SwWhitelist
        (@(Get-FileBytes (Get-ListFile)) -join ',') | Should -BeExactly (@($before) -join ',')
    }

    It 'S-14 never shortens an existing empty file or fills it with the template' {
        $null = New-Dir (Split-Path -Parent (Get-ListFile))
        [System.IO.File]::WriteAllBytes((Get-ListFile), [byte[]]@())
        Edit-SwWhitelist
        ([System.IO.FileInfo]::new((Get-ListFile))).Length | Should -Be 0
        $script:Started.Count | Should -Be 1
    }

    It 'S-14 CL-8 leaves the file alone and opens the editor when an earlier existence check said it was missing' {
        $null = New-Dir (Split-Path -Parent (Get-ListFile))
        [System.IO.File]::WriteAllText((Get-ListFile), 'keep me', $script:Utf8)
        Mock Test-Path { $false }
        Edit-SwWhitelist
        Get-FileText (Get-ListFile) | Should -BeExactly 'keep me'
        $script:Started.Count | Should -Be 1
    }

    It 'S-14 CL-8 writes nothing through a link to a missing file and still opens the editor' {
        $null = New-Dir (Split-Path -Parent (Get-ListFile))
        $target = P $script:Work 'elsewhere' 'target.txt'
        if (-not (New-TestLink (Get-ListFile) $target)) { Set-ItResult -Skipped -Because 'this account cannot create a file link'; return }
        Edit-SwWhitelist
        [System.IO.File]::Exists($target) | Should -BeFalse
        $script:Started.Count | Should -Be 1
    }

    It 'S-14 CL-8 does not write through a link to a file with content' {
        $null = New-Dir (Split-Path -Parent (Get-ListFile))
        $target = P $script:Work 'elsewhere' 'target.txt'
        $null = New-Dir (Split-Path -Parent $target)
        [System.IO.File]::WriteAllText($target, 'precious', $script:Utf8)
        if (-not (New-TestLink (Get-ListFile) $target)) { Set-ItResult -Skipped -Because 'this account cannot create a file link'; return }
        Edit-SwWhitelist
        Get-FileText $target | Should -BeExactly 'precious'
        $script:Started.Count | Should -Be 1
    }

    It 'CL-8 trims the path: a padded value gives the file at the trimmed path' {
        Set-WhitelistFile ('  ' + (Get-ListFile) + '  ')
        Edit-SwWhitelist
        [System.IO.File]::Exists((Get-ListFile)) | Should -BeTrue
        $script:Started[0].ArgumentList[0] | Should -BeExactly ('"' + (Get-ListFile) + '"')
    }

    It 'CL-4 leaves the path guard as it was' {
        $script:SweeprCleanPathGuard = $false
        Edit-SwWhitelist
        $script:SweeprCleanPathGuard | Should -BeFalse
    }

    It 'CL-8 S-4 writes the file and starts the editor also in dry-run mode and with SWEEPR_DRY_RUN set' {
        Set-SwDryRunMode -Enabled $true
        Set-Env 'SWEEPR_DRY_RUN' '1'
        Edit-SwWhitelist
        [System.IO.File]::Exists((Get-ListFile)) | Should -BeTrue
        $script:Started.Count | Should -Be 1
    }
}

# ============================================================================
# Edit-SwWhitelist: the editor call (CL-8, S-3, )
# ============================================================================

Describe 'Edit-SwWhitelist starts the editor' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-EditorSpies
        Set-WhitelistFile (Get-ListFile)
    }
    AfterEach { Stop-Case }

    It 'CL-8 starts the editor once, with -Wait, and without a verb' {
        Edit-SwWhitelist
        $script:Started.Count | Should -Be 1
        $script:Started[0].Wait | Should -BeTrue
        $script:Started[0].Verb | Should -BeNullOrEmpty
    }

    It 'starts notepad.exe from the system folder, not from the search path' {
        Edit-SwWhitelist
        $file = [string]$script:Started[0].FilePath
        [System.IO.Path]::GetFileName($file) | Should -BeExactly 'notepad.exe'
        $system = [System.Environment]::SystemDirectory
        if (-not [string]::IsNullOrEmpty($system)) {
            [System.IO.Path]::GetDirectoryName($file) | Should -BeExactly $system.TrimEnd('\', '/')
        }
    }

    It 'CL-8 gives the editor exactly one argument: the full path in double quotes' {
        Edit-SwWhitelist
        @($script:Started[0].ArgumentList).Count | Should -Be 1
        $script:Started[0].ArgumentList[0] | Should -BeExactly ('"' + (Get-ListFile) + '"')
    }

    It 'CL-8 quotes a path with spaces, parentheses and brackets as one argument' {
        $path = P $script:Work 'Max Muster (old) [x]' 'config' 'whitelist.txt'
        Set-WhitelistFile $path
        Edit-SwWhitelist
        @($script:Started[0].ArgumentList).Count | Should -Be 1
        $script:Started[0].ArgumentList[0] | Should -BeExactly ('"' + $path + '"')
        [System.IO.File]::Exists($path) | Should -BeTrue
    }

    It 'CL-8 opens an existing file, as it is' {
        $null = New-Dir (Split-Path -Parent (Get-ListFile))
        [System.IO.File]::WriteAllText((Get-ListFile), 'keep me', $script:Utf8)
        Edit-SwWhitelist
        $script:Started.Count | Should -Be 1
        $script:Started[0].ArgumentList[0] | Should -BeExactly ('"' + (Get-ListFile) + '"')
    }

    It 'CL-8 says something afterwards and never claims that anything was saved' {
        Edit-SwWhitelist
        $text = Get-AllText
        $text.Trim().Length | Should -BeGreaterThan 0
        $text | Should -Not -Match '(?i)\bsaved\b'
    }

    It 'CL-8 writes nothing to the pipeline' {
        @(Edit-SwWhitelist).Count | Should -Be 0
    }

    It 'S-3 starts nothing else: one call of Start-Process in total' {
        Edit-SwWhitelist
        Should -Invoke Start-Process -Times 1 -Exactly
    }
}

# ============================================================================
# Edit-SwWhitelist: failures (CL-8, )
# ============================================================================

Describe 'Edit-SwWhitelist failures' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-EditorSpies
        $script:Cwd = New-Dir (P $script:Work 'cwd')
        [System.Environment]::CurrentDirectory = $script:Cwd
        Set-Location -LiteralPath $script:Cwd
    }
    AfterEach { Stop-Case }

    It 'CL-8 throws with a reason, creates nothing and starts nothing when WhitelistFile is <Label>' -ForEach $script:BadFiles {
        Set-WhitelistFile $Value
        $failure = Assert-Throws { Edit-SwWhitelist }
        $failure.Exception.Message.Trim().Length | Should -BeGreaterThan 0
        $script:Started.Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $script:Cwd -Force -Recurse).Count | Should -Be 0
    }

    It 'CL-8 CL-5 throws whatever error preference the caller has: <_>' -ForEach $script:Preferences {
        Set-WhitelistFile ''
        $ErrorActionPreference = $_
        $failure = $null
        try { Edit-SwWhitelist } catch { $failure = $_ }
        $ErrorActionPreference = 'Stop'
        $failure | Should -Not -BeNullOrEmpty
        $failure.Exception | Should -Not -BeOfType [System.Management.Automation.CommandNotFoundException]
        $script:Started.Count | Should -Be 0
    }

    It 'CL-8 throws with the path and does not start the editor when the folder cannot be created' {
        $blocker = New-File (P $script:Work 'a-file') 3
        $path = P $blocker 'config' 'whitelist.txt'
        Set-WhitelistFile $path
        $failure = Assert-Throws { Edit-SwWhitelist }
        $failure.Exception.Message | Should -BeLike '*a-file*'
        $script:Started.Count | Should -Be 0
    }

    It 'CL-8 throws with the path and the reason when the editor cannot be started' {
        Set-WhitelistFile (Get-ListFile)
        Mock Start-Process { throw 'launch failed (test)' }
        $failure = Assert-Throws { Edit-SwWhitelist }
        $failure.Exception.Message | Should -BeLike '*launch failed (test)*'
        $failure.Exception.Message | Should -BeLike '*whitelist.txt*'
    }

    It 'CL-8 gives the failure to the caller instead of printing it: nothing on the pipeline' {
        Assert-Defined @('Edit-SwWhitelist')
        Set-WhitelistFile ''
        $out = @()
        try { $out = @(Edit-SwWhitelist) } catch { $null = $_ }
        $out.Count | Should -Be 0
    }
}
