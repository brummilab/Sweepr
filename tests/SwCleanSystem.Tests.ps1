# Sweepr - tests for lib\clean\system.ps1: the section "System cleanup" (only for an administrator, only
# old Windows error reports below ProgramData), its loading of user.ps1 and the removed targets.
#
# The rule numbers in the test names (CL-, SI-, S-, K- and so on) number the rules and the
# safety invariants of the cleanup core's behavior; each rule and invariant has at least one test.
# The other clean test files are SwCleanMain, SwCleanRun, SwCleanEditor (the command script),
# SwCleanGuard, SwCleanUser, SwCleanCaches and SwCleanSafety (static and cross checks).
#
# Interface pinned here (new name; the old name stays as a forwarding function, not an alias):
#   Invoke-SwSystemCleanup                                  the section, nothing to the pipeline
#   Old name: Invoke-SystemCleanup (-IncludeComponentStore, -IncludeDiskCleanup accepted, no effect)
#   system.ps1 loads user.ps1, so Clear-SwReportRoot exists after loading system.ps1 alone.
#
# Seams used with Mock: Test-SwAdmin ($true, $false or an exception; no test asks the real system),
# Clear-SwReportRoot and the removal helpers as spies (in the end-to-end tests the real ones),
# Get-SwPathSnapshot and Test-SwPathSnapshot (substitute objects), Start-Process (throws: nothing may
# start), Start-SwSection and Stop-SwSection, the writers of the log module, Write-SweeprOperation.
#
# Platform notes:
#   - Paths are built from $TestDrive with the separator of the host (host paths).
#     Real removals happen only below $TestDrive; nothing real is touched.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    $script:RunModes = @(
        @{ Mode = 'a preview'; Dry = $true }
        @{ Mode = 'a real run'; Dry = $false }
    )
    $script:BadValues = @(
        @{ Label = 'not set'; Value = $null }
        @{ Label = 'blank'; Value = '   ' }
        @{ Label = 'a relative name'; Value = 'ProgramData' }
        @{ Label = 'a drive-relative path'; Value = 'C:ProgramData' }
        @{ Label = 'a root-relative path'; Value = '\x' }
        @{ Label = 'a UNC path'; Value = '\\server\x' }
    )
    $script:RemovedNames = @(
        'Clear-SystemTempFiles', 'Clear-WindowsLogs', 'Clear-InstallerCache', 'Clear-MemoryDumps',
        'Invoke-ComponentStoreCleanup', 'Invoke-DiskCleanupTool', 'Clear-OldDownloads', 'Test-SweeprOldErrorReport'
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

    $script:SystemFile = [System.IO.Path]::Combine($script:CleanDir, 'system.ps1')
    . $script:SystemFile

    function script:New-Report([string]$Root, [string]$Name, [double]$Days = 10, [string[]]$Files = @('Report.wer')) {
        $dir = New-Dir (P $Root $Name)
        foreach ($file in $Files) { $null = New-File (P $dir $file) 20 }
        Set-TreeAge $dir $Days
        $dir
    }
    function script:Get-WerQueue { P $script:ProgramData 'Microsoft' 'Windows' 'WER' 'ReportQueue' }
    function script:Get-WerArchive { P $script:ProgramData 'Microsoft' 'Windows' 'WER' 'ReportArchive' }
    function script:Use-AdminAnswer($Answer) {
        $script:AdminCalls = 0
        $script:AdminAnswer = $Answer
        Mock Test-SwAdmin {
            $script:AdminCalls++
            if ($script:AdminAnswer -is [scriptblock]) { & $script:AdminAnswer } else { $script:AdminAnswer }
        }
    }
    function script:Use-RootSpy {
        $script:Roots = [System.Collections.Generic.List[object]]::new()
        Mock Clear-SwReportRoot {
            $script:Roots.Add([pscustomobject]@{ Root = $Root; DaysOld = $DaysOld; Description = $Description; DumpOnly = [bool]$DumpOnly })
        }
    }
    function script:Use-NoProcess { Mock Start-Process { throw 'no process may start (test)' } }
}

AfterAll {
    Clear-TestLinks
    Restore-State $script:RootState
    Restore-Env $script:RootEnv
    [System.Environment]::CurrentDirectory = $script:RootDirectory
}

# ============================================================================
# Interface, loading and removed targets
# ============================================================================

Describe 'system.ps1 interface' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
    }

    It 'CL-36 defines the section and its old name' {
        Assert-Defined @('Invoke-SwSystemCleanup', 'Invoke-SystemCleanup')
    }

    It 'SI-7 loads user.ps1 itself, so Clear-SwReportRoot exists after loading system.ps1 alone' {
        Assert-Defined @('Invoke-SwSystemCleanup', 'Clear-SwReportRoot')
    }

    It 'keeps the old signature of Invoke-SystemCleanup, with the removed switches accepted' {
        (Get-ParamLine 'Invoke-SystemCleanup' 'IncludeComponentStore') | Should -BeLike 'IncludeComponentStore|System.Management.Automation.SwitchParameter|*'
        (Get-ParamLine 'Invoke-SystemCleanup' 'IncludeDiskCleanup') | Should -BeLike 'IncludeDiskCleanup|System.Management.Automation.SwitchParameter|*'
    }

    It 'does not define the removed target <_>' -ForEach $script:RemovedNames {
        Assert-Defined @('Invoke-SwSystemCleanup')
        Get-Command -Name $_ -CommandType Function -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'S-6 defines no function named Clear-RecycleBin' {
        Assert-Defined @('Invoke-SwSystemCleanup')
        Get-Command -Name Clear-RecycleBin -CommandType Function -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

Describe 'system.ps1 forwarder' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-HelperSpies
        Use-NoProcess
        $script:Seen = 0
        Mock Invoke-SwSystemCleanup { $script:Seen++ }
    }
    AfterEach { Stop-Case }

    It 'Invoke-SystemCleanup calls Invoke-SwSystemCleanup once' {
        Invoke-SystemCleanup
        $script:Seen | Should -Be 1
    }

    It 'Invoke-SystemCleanup accepts the removed switches and they change nothing' {
        { Invoke-SystemCleanup -IncludeComponentStore -IncludeDiskCleanup } | Should -Not -Throw
        $script:Seen | Should -Be 1
        $script:Calls.Count | Should -Be 0
    }
}

# ============================================================================
# Invoke-SwSystemCleanup: the administrator gate (CL-36, S-5, CL-10)
# ============================================================================

Describe 'Invoke-SwSystemCleanup administrator gate' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-HelperSpies
        Use-RootSpy
        Use-NoProcess
    }
    AfterEach { Stop-Case }

    It 'CL-36 S-5 calls no helper, starts nothing and warns exactly once when the caller is no administrator' {
        Use-AdminAnswer $false
        Invoke-SwSystemCleanup
        $script:Roots.Count | Should -Be 0
        $script:Calls.Count | Should -Be 0
        Should -Invoke Start-Process -Times 0 -Exactly
        @(Get-LogLines 'WARN').Count | Should -Be 1
        @($script:Sections) | Should -Be @('start:System cleanup', 'stop')
    }

    It 'treats an exception of the administrator query as no administrator' {
        Use-AdminAnswer { throw 'identity not readable (test)' }
        { Invoke-SwSystemCleanup } | Should -Not -Throw
        $script:Roots.Count | Should -Be 0
        $script:Calls.Count | Should -Be 0
        @(Get-LogLines 'WARN').Count | Should -Be 1
        @($script:Sections) | Should -Be @('start:System cleanup', 'stop')
    }

    It 'S-5 does not run for an answer that is not $true' -ForEach @(
        @{ Label = 'nothing'; Answer = { } }
        @{ Label = '$null'; Answer = { $null } }
    ) {
        Use-AdminAnswer $Answer
        Invoke-SwSystemCleanup
        $script:Roots.Count | Should -Be 0
    }

    It 'CL-36 gives no warning when the caller is an administrator' {
        Use-AdminAnswer $true
        Invoke-SwSystemCleanup
        @(Get-LogLines 'WARN').Count | Should -Be 0
    }

    It 'S-5 never starts a process, in any case' -ForEach @(
        @{ Label = 'an administrator'; Answer = $true }
        @{ Label = 'no administrator'; Answer = $false }
    ) {
        Use-AdminAnswer $Answer
        Invoke-SwSystemCleanup
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'SI-1 opens the section with the title System cleanup before the first report root and closes it after the last' {
        Use-AdminAnswer $true
        $script:Order = [System.Collections.Generic.List[string]]::new()
        Mock Start-SwSection { $script:Order.Add('start:' + $Title) }
        Mock Stop-SwSection { $script:Order.Add('stop') }
        Mock Clear-SwReportRoot { $script:Order.Add('root') }
        Invoke-SwSystemCleanup
        @($script:Order) | Should -Be @('start:System cleanup', 'root', 'root', 'stop')
    }
}

# ============================================================================
# Invoke-SwSystemCleanup: targets SY-1 and SY-2 (CL-36, CL-21, S-12)
# ============================================================================

Describe 'Invoke-SwSystemCleanup targets' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-HelperSpies
        Use-RootSpy
        Use-NoProcess
        Use-AdminAnswer $true
    }
    AfterEach { Stop-Case }

    It 'SY-1 SY-2 asks Clear-SwReportRoot for the report queue and then the report archive below ProgramData, 7 days, Error reports' {
        Invoke-SwSystemCleanup
        $script:Roots.Count | Should -Be 2
        $script:Roots[0].Root | Should -BeExactly (Get-WerQueue)
        $script:Roots[1].Root | Should -BeExactly (Get-WerArchive)
        foreach ($call in $script:Roots) {
            $call.DaysOld | Should -Be 7
            $call.Description | Should -BeExactly 'Error reports'
            $call.DumpOnly | Should -BeFalse
        }
    }

    It 'CL-36 offers nothing else: no direct helper call, no other root' {
        Invoke-SwSystemCleanup
        $script:Calls.Count | Should -Be 0
    }

    It 'CL-21 trims PROGRAMDATA and keeps a trailing separator out of the roots' {
        Set-Env 'PROGRAMDATA' ('  ' + $script:ProgramData + $script:Sep + ' ')
        Invoke-SwSystemCleanup
        $script:Roots[0].Root | Should -BeExactly (Get-WerQueue)
        $script:Roots[1].Root | Should -BeExactly (Get-WerArchive)
    }

    It 'CL-21 S-12 builds no root when PROGRAMDATA is <Label>, and does not throw' -ForEach $script:BadValues {
        Set-Env 'PROGRAMDATA' $Value
        { Invoke-SwSystemCleanup } | Should -Not -Throw
        $script:Roots.Count | Should -Be 0
        @($script:Sections | Where-Object { $_ -eq 'stop' }).Count | Should -Be 1
    }

    It 'CL-21 S-13 builds the roots literally below a folder with brackets' {
        $bracket = New-Dir (P $script:Work 'Data [x]' 'ProgramData')
        Set-Env 'PROGRAMDATA' $bracket
        Invoke-SwSystemCleanup
        $script:Roots[0].Root | Should -BeExactly (P $bracket 'Microsoft' 'Windows' 'WER' 'ReportQueue')
    }

    It 'CL-20 asks for the second root when the first call throws, closes the section once and does not throw' {
        Mock Clear-SwReportRoot { $script:Roots.Add([pscustomobject]@{ Root = $Root }); throw 'failure (test)' }
        { Invoke-SwSystemCleanup } | Should -Not -Throw
        $script:Roots.Count | Should -Be 2
        @($script:Sections | Where-Object { $_ -eq 'stop' }).Count | Should -Be 1
    }

    It 'SI-6 writes nothing to the pipeline' {
        Mock Clear-SwReportRoot { 'noise'; 7 }
        @(Invoke-SwSystemCleanup).Count | Should -Be 0
    }
}

# ============================================================================
# Invoke-SwSystemCleanup with the real report rule and the real helpers (CL-36, S-2, S-4)
# ============================================================================

Describe 'Invoke-SwSystemCleanup with the real helpers' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-NoProcess
        Use-AdminAnswer $true
        $script:DryRunCollector = [System.Collections.Generic.List[object]]::new()
        $script:Old = New-Report (Get-WerQueue) 'old'
        $script:Recent = New-Report (Get-WerQueue) 'recent' 0
        $script:Archived = New-Report (Get-WerArchive) 'archived' 12
        $script:WinTemp = New-OldFile (P $script:WinDir 'Temp' 'old.tmp') 30
        $script:WinDump = New-OldFile (P $script:WinDir 'Minidump' 'a.dmp') 30
    }
    AfterEach { Stop-Case }

    It 'CL-36 S-4 lists the old reports in a preview and changes nothing' {
        $before = Get-Listing $script:Work
        Mock Remove-Item { throw 'Remove-Item must not run in a preview (test)' }
        Invoke-SwSystemCleanup
        Same-Listing (Get-Listing $script:Work) $before | Should -BeTrue
        $listed = @($script:DryRunCollector | ForEach-Object { $_.Path })
        $listed | Should -Contain $script:Old
        $listed | Should -Contain $script:Archived
        $listed | Should -Not -Contain $script:Recent
        (Get-SwCleanupStats).FilesCleaned | Should -Be 2
        $script:Ops.Count | Should -Be 0
    }

    It 'lists nothing below the Windows folder and offers nothing for it' {
        Invoke-SwSystemCleanup
        Test-AnyUnder @($script:DryRunCollector | ForEach-Object { $_.Path }) $script:WinDir | Should -BeFalse
    }

    It 'CL-36 removes the old reports and keeps the recent one and the Windows folder files in a real run' {
        Set-SwDryRunMode -Enabled $false
        Invoke-SwSystemCleanup
        Exists $script:Old | Should -BeFalse
        Exists $script:Archived | Should -BeFalse
        Exists $script:Recent | Should -BeTrue
        Exists $script:WinTemp | Should -BeTrue
        Exists $script:WinDump | Should -BeTrue
        [System.IO.Directory]::Exists((Get-WerQueue)) | Should -BeTrue
        (Get-SwCleanupStats).FilesCleaned | Should -Be 2
    }

    It 'CL-36 does nothing for a caller that is no administrator, in <Mode> ' -ForEach $script:RunModes {
        Use-AdminAnswer $false
        Set-SwDryRunMode -Enabled $Dry
        Invoke-SwSystemCleanup
        Exists $script:Old | Should -BeTrue
        (Get-SwCleanupStats).FilesCleaned | Should -Be 0
        @($script:DryRunCollector).Count | Should -Be 0
    }

    It 'S-2 removes nothing below a protected folder, whatever target names it' {
        Set-SwDryRunMode -Enabled $false
        $protectedData = New-Dir (P $script:WinDir 'ProgramData')
        Set-Env 'PROGRAMDATA' $protectedData
        $inside = New-Report (P $protectedData 'Microsoft' 'Windows' 'WER' 'ReportQueue') 'old'
        Invoke-SwSystemCleanup
        Exists $inside | Should -BeTrue
        (Get-SwCleanupStats).FilesCleaned | Should -Be 0
    }

    It 'S-2 removes nothing that a whitelist line holds' {
        Set-SwDryRunMode -Enabled $false
        Set-Whitelist @($script:Old)
        Invoke-SwSystemCleanup
        Exists $script:Old | Should -BeTrue
        Exists $script:Archived | Should -BeFalse
    }

    It 'CL-31 keeps a report with a young file inside in a real run' {
        Set-SwDryRunMode -Enabled $false
        $null = New-File (P $script:Old 'attachment.dmp')
        Set-Age $script:Old 10
        Invoke-SwSystemCleanup
        Exists $script:Old | Should -BeTrue
        Exists $script:Archived | Should -BeFalse
    }
}
