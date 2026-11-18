# Sweepr - tests for lib\clean\user.ps1: the section "User essentials" (old temp files, error reports,
# old log files), the report rule that system.ps1 shares, the plausibility of the roots of file targets,
# path building from environment variables, age rules, limits and the notes for what was left out.
#
# The rule numbers in the test names (CL-, SI-, S-, K- and so on) number the rules and the
# safety invariants of the cleanup core's behavior; each rule and invariant has at least one test.
# The other clean test files are SwCleanMain, SwCleanRun, SwCleanEditor (the command script),
# SwCleanGuard, SwCleanCaches, SwCleanSystem and SwCleanSafety (static and cross checks).
#
# Interface pinned here (new names; the old names stay as forwarding functions, not aliases):
#   Invoke-SwUserCleanup [-TempDaysOld] [-LogDaysOld]       the section, nothing to the pipeline
#   Clear-SwUserTempFiles [-DaysOld]                        target U-1
#   Clear-SwErrorReports [-DaysOld]                         targets U-3, U-4, U-5
#   Clear-SwUserLogs [-DaysOld]                             targets U-6, U-7
#   Clear-SwReportRoot -Root -DaysOld -Description [-DumpOnly]   one report root (also used by system.ps1)
#   Old names: Invoke-UserCleanup, Clear-UserTempFiles, Clear-ErrorReports, Clear-UserLogs
#
# Seams used with Mock: the removal helpers Remove-SwOldFiles, Remove-SwItems, Clear-SwDirectoryContents,
# Remove-SwItem (spies; in the end-to-end tests the real ones), Get-SwPathSnapshot and
# Test-SwPathSnapshot (substitute objects), Resolve-SwSafePath, Get-Date, Get-SwValidatedTreeSize,
# Add-SwNotMeasured, Start-SwSection and Stop-SwSection, the writers of the log module,
# Write-SweeprOperation. The variable $script:SwProbeBudgetSeconds is the time budget seam.
#
# Platform notes:
#   - Paths are built from $TestDrive with the separator of the host (host paths).
#     Real removals happen only below $TestDrive; nothing real is touched.
#   - Host creation time follows the write time on Linux, so a test that needs the two apart is
#     marked [W]. A hidden file is a file with the Hidden attribute on Windows and a dot file elsewhere.
#   - Known folders (Desktop, Documents) cannot be mocked; the test that uses them is marked [W].
#   - Tests marked [W] need real Windows. They are meant to fail on Linux and belong in
#     tests/linux-known-failures.txt.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    $script:RunModes = @(
        @{ Mode = 'a preview'; Dry = $true }
        @{ Mode = 'a real run'; Dry = $false }
    )
    # CL-21, S-12: values of an environment variable that name no usable target.
    $script:BadValues = @(
        @{ Label = 'not set'; Value = $null }
        @{ Label = 'blank'; Value = '   ' }
        @{ Label = 'a relative name'; Value = 'Local' }
        @{ Label = 'a drive-relative path'; Value = 'C:Temp' }
        @{ Label = 'a root-relative path'; Value = '\x' }
        @{ Label = 'a UNC path'; Value = '\\server\x' }
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
    # Compile the Windows wrappers now. Windows PowerShell 5.1 writes the files of the compiler to TEMP, which the
    # cases point into their work folder, so a first compile in the middle of a case would show up in its listing.
    if ($script:OnWindows) { $null = Initialize-SwBaseNative; $null = Initialize-SwFileOpsNative }
    . ([System.IO.Path]::Combine($script:CoreDir, 'ui.ps1'))

    $script:UserFile = [System.IO.Path]::Combine($script:CleanDir, 'user.ps1')
    . $script:UserFile

    function script:Set-Time([string]$Path, [datetime]$Time) {
        if ([System.IO.Directory]::Exists($Path)) {
            [System.IO.Directory]::SetCreationTime($Path, $Time)
            [System.IO.Directory]::SetLastWriteTime($Path, $Time)
        }
        else {
            [System.IO.File]::SetCreationTime($Path, $Time)
            [System.IO.File]::SetLastWriteTime($Path, $Time)
        }
    }
    # A report: a folder below the root with the given files, everything aged by days.
    function script:New-Report([string]$Root, [string]$Name, [double]$Days = 10, [string[]]$Files = @('Report.wer')) {
        $dir = New-Dir (P $Root $Name)
        foreach ($file in $Files) { $null = New-File (P $dir $file) 20 }
        Set-TreeAge $dir $Days
        $dir
    }
    function script:New-ManyFiles([string]$Folder, [int]$Count) {
        $null = New-Dir $Folder
        for ($i = 1; $i -le $Count; $i++) { [System.IO.File]::Create((P $Folder ('f' + $i + '.dat'))).Dispose() }
    }
    function script:Get-WerArchive { P $script:Local 'Microsoft' 'Windows' 'WER' 'ReportArchive' }
    function script:Get-WerQueue { P $script:Local 'Microsoft' 'Windows' 'WER' 'ReportQueue' }
    function script:Get-CrashDumps { P $script:Local 'CrashDumps' }
    function script:Get-LocalTemp { P $script:Local 'Temp' }
    function script:Get-NotMeasuredNames { @($script:NotMeasured | ForEach-Object { $_.Name }) }
    # The paths of every Remove-SwItems call, flattened.
    function script:Get-OfferedPaths { @(Get-Calls 'Remove-SwItems' | ForEach-Object { $_.Paths }) }
    # The three section parts as spies that record their arguments.
    function script:Use-PartSpies {
        $script:Parts = [System.Collections.Generic.List[string]]::new()
        Mock Clear-SwUserTempFiles { $script:Parts.Add('temp:' + $DaysOld) }
        Mock Clear-SwErrorReports { $script:Parts.Add('reports:' + $DaysOld) }
        Mock Clear-SwUserLogs { $script:Parts.Add('logs:' + $DaysOld) }
    }
    # A collector that takes the preview entries.
    function script:Use-Collector { $script:DryRunCollector = [System.Collections.Generic.List[object]]::new() }
}

AfterAll {
    Clear-TestLinks
    Restore-State $script:RootState
    Restore-Env $script:RootEnv
    [System.Environment]::CurrentDirectory = $script:RootDirectory
}

# ============================================================================
# Interface and old names
# ============================================================================

Describe 'user.ps1 interface' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
    }

    It 'CL-30 defines the section, its parts, the report function and the old names' {
        Assert-Defined @('Invoke-SwUserCleanup', 'Clear-SwUserTempFiles', 'Clear-SwErrorReports', 'Clear-SwUserLogs', 'Clear-SwReportRoot',
            'Invoke-UserCleanup', 'Clear-UserTempFiles', 'Clear-ErrorReports', 'Clear-UserLogs')
    }

    It 'CL-30 gives the section and the parts the days with the default 7' {
        (Get-ParamLine 'Invoke-SwUserCleanup' 'TempDaysOld') | Should -BeLike 'TempDaysOld|System.Int32|*|default=7'
        (Get-ParamLine 'Invoke-SwUserCleanup' 'LogDaysOld') | Should -BeLike 'LogDaysOld|System.Int32|*|default=7'
        foreach ($name in 'Clear-SwUserTempFiles', 'Clear-SwErrorReports', 'Clear-SwUserLogs') {
            (Get-ParamLine $name 'DaysOld') | Should -BeLike 'DaysOld|System.Int32|*|default=7' -Because $name
        }
    }

    It 'CL-31 gives Clear-SwReportRoot Root, DaysOld, Description and the switch DumpOnly' {
        (Get-ParamLine 'Clear-SwReportRoot' 'Root') | Should -BeLike 'Root|System.String|*'
        (Get-ParamLine 'Clear-SwReportRoot' 'DaysOld') | Should -BeLike 'DaysOld|System.Int32|*'
        (Get-ParamLine 'Clear-SwReportRoot' 'Description') | Should -BeLike 'Description|System.String|*'
        (Get-ParamLine 'Clear-SwReportRoot' 'DumpOnly') | Should -BeLike 'DumpOnly|System.Management.Automation.SwitchParameter|*'
    }

    It 'keeps the old signature of Invoke-UserCleanup, with the removed switches accepted' {
        (Get-ParamLine 'Invoke-UserCleanup' 'TempDaysOld') | Should -Be 'TempDaysOld|System.Int32|pos=0|mandatory=False|default=7'
        (Get-ParamLine 'Invoke-UserCleanup' 'DownloadsDaysOld') | Should -Be 'DownloadsDaysOld|System.Int32|pos=1|mandatory=False|default=30'
        (Get-ParamLine 'Invoke-UserCleanup' 'LogDaysOld') | Should -Be 'LogDaysOld|System.Int32|pos=2|mandatory=False|default=7'
        (Get-ParamLine 'Invoke-UserCleanup' 'IncludeDownloads') | Should -BeLike 'IncludeDownloads|System.Management.Automation.SwitchParameter|*'
        (Get-ParamLine 'Invoke-UserCleanup' 'IncludeRecycleBin') | Should -BeLike 'IncludeRecycleBin|System.Management.Automation.SwitchParameter|*'
    }

    It 'keeps the old signature of the three parts (DaysOld at position 0, default 7)' {
        foreach ($name in 'Clear-UserTempFiles', 'Clear-ErrorReports', 'Clear-UserLogs') {
            (Get-ParamLine $name 'DaysOld') | Should -Be 'DaysOld|System.Int32|pos=0|mandatory=False|default=7' -Because $name
        }
    }

    It 'does not define the removed targets' {
        Assert-Defined @('Invoke-SwUserCleanup')
        foreach ($name in 'Clear-OldDownloads', 'Test-SweeprOldErrorReport') {
            Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because $name
        }
    }
}

Describe 'user.ps1 forwarders' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        $script:Seen = [System.Collections.Generic.List[object]]::new()
    }
    AfterEach { Stop-Case }

    It 'Invoke-UserCleanup calls Invoke-SwUserCleanup once with the two day values, also by position' {
        Mock Invoke-SwUserCleanup { $script:Seen.Add([pscustomobject]@{ Temp = $TempDaysOld; Log = $LogDaysOld }) }
        Invoke-UserCleanup 3 9 4
        $script:Seen.Count | Should -Be 1
        $script:Seen[0].Temp | Should -Be 3
        $script:Seen[0].Log | Should -Be 4
    }

    It 'Invoke-UserCleanup accepts the removed switches and they change nothing' {
        Use-HelperSpies
        Mock Start-Process { throw 'no process may start (test)' }
        Mock Invoke-SwUserCleanup { $script:Seen.Add([pscustomobject]@{ Temp = $TempDaysOld; Log = $LogDaysOld }) }
        { Invoke-UserCleanup -TempDaysOld 2 -DownloadsDaysOld 5 -LogDaysOld 6 -IncludeDownloads -IncludeRecycleBin } | Should -Not -Throw
        $script:Seen.Count | Should -Be 1
        $script:Seen[0].Temp | Should -Be 2
        $script:Seen[0].Log | Should -Be 6
        $script:Calls.Count | Should -Be 0
    }

    It '<Old> calls <New> once with the days given' -ForEach @(
        @{ Old = 'Clear-UserTempFiles'; New = 'Clear-SwUserTempFiles' }
        @{ Old = 'Clear-ErrorReports'; New = 'Clear-SwErrorReports' }
        @{ Old = 'Clear-UserLogs'; New = 'Clear-SwUserLogs' }
    ) {
        Mock $New { $script:Seen.Add([pscustomobject]@{ Days = $DaysOld }) }
        & $Old 13
        $script:Seen.Count | Should -Be 1
        $script:Seen[0].Days | Should -Be 13
    }
}

# ============================================================================
# Invoke-SwUserCleanup: structure (CL-30, SI-1, SI-6, CL-20)
# ============================================================================

Describe 'Invoke-SwUserCleanup structure' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-PartSpies
    }
    AfterEach { Stop-Case }

    It 'CL-30 runs temp files, error reports and logs between the section start and stop, once each' {
        Invoke-SwUserCleanup -TempDaysOld 5 -LogDaysOld 6
        @($script:Parts) | Should -Be @('temp:5', 'reports:7', 'logs:6')
        @($script:Sections) | Should -Be @('start:User essentials', 'stop')
    }

    It 'CL-30 opens the section before the first part and closes it after the last' {
        $script:Order = [System.Collections.Generic.List[string]]::new()
        Mock Start-SwSection { $script:Order.Add('start:' + $Title) }
        Mock Stop-SwSection { $script:Order.Add('stop') }
        Mock Clear-SwUserTempFiles { $script:Order.Add('temp') }
        Mock Clear-SwErrorReports { $script:Order.Add('reports') }
        Mock Clear-SwUserLogs { $script:Order.Add('logs') }
        Invoke-SwUserCleanup
        @($script:Order) | Should -Be @('start:User essentials', 'temp', 'reports', 'logs', 'stop')
    }

    It 'CL-30 uses 7 days for both when no value is given' {
        Invoke-SwUserCleanup
        @($script:Parts) | Should -Be @('temp:7', 'reports:7', 'logs:7')
    }

    It 'CL-30 keeps the error reports at 7 days whatever TempDaysOld is' {
        Invoke-SwUserCleanup -TempDaysOld 30 -LogDaysOld 2
        @($script:Parts) | Should -Contain 'reports:7'
        @($script:Parts) | Should -Contain 'temp:30'
        @($script:Parts) | Should -Contain 'logs:2'
    }

    It 'SI-1 SI-6 writes nothing to the pipeline' {
        Mock Clear-SwUserTempFiles { 'noise'; $true }
        Mock Clear-SwErrorReports { 42 }
        Mock Clear-SwUserLogs { $null; 'more noise' }
        @(Invoke-SwUserCleanup).Count | Should -Be 0
    }

    It 'CL-20 closes the section once and does not throw when a part throws, and the other parts still run' -ForEach @(
        @{ Failing = 'Clear-SwUserTempFiles' }
        @{ Failing = 'Clear-SwErrorReports' }
        @{ Failing = 'Clear-SwUserLogs' }
    ) {
        Mock $Failing { throw 'failure (test)' }
        { Invoke-SwUserCleanup } | Should -Not -Throw
        @($script:Sections | Where-Object { $_ -eq 'stop' }).Count | Should -Be 1
        @($script:Sections | Where-Object { $_ -like 'start:*' }).Count | Should -Be 1
        $others = @('temp:7', 'reports:7', 'logs:7') | Where-Object { $_ -notlike ('*' + $Failing) }
        @($script:Parts).Count | Should -Be 2
    }

    It 'S-16 closes the section and does not throw when every part throws' {
        Mock Clear-SwUserTempFiles { throw 'one' }
        Mock Clear-SwErrorReports { throw 'two' }
        Mock Clear-SwUserLogs { throw 'three' }
        { Invoke-SwUserCleanup } | Should -Not -Throw
        @($script:Sections | Where-Object { $_ -eq 'stop' }).Count | Should -Be 1
    }
}

# ============================================================================
# Clear-SwUserTempFiles: U-1 (CL-21, CL-21a, CL-26, SI-2, SI-4, )
# ============================================================================

# ============================================================================
# The text rule for a canonical folder, run for both kinds of host
# ============================================================================

Describe 'Test-SwCleanCanonicalText' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
    }

    It 'rules a Windows path with the rules of Windows, whatever the host: <Text> is <Expected>' -ForEach @(
        @{ Text = 'C:\a\..\b'; Expected = $false }
        @{ Text = 'C:\a\.\b'; Expected = $false }
        @{ Text = 'C:\a\..'; Expected = $false }
        @{ Text = 'C:\a\\b'; Expected = $false }
        @{ Text = 'C:/a/b'; Expected = $false }
        @{ Text = 'C:\a/b'; Expected = $false }
        @{ Text = 'C:\a\b'; Expected = $true }
        @{ Text = 'C:\a\b\'; Expected = $true }
        @{ Text = 'C:\a\.b\..c'; Expected = $true }
    ) {
        (Test-SwCleanCanonicalText -Text $Text -Windows $true) | Should -Be $Expected
    }

    It 'rules a path of a host with the slash only: <Text> is <Expected>' -ForEach @(
        @{ Text = '/a/../b'; Expected = $false }
        @{ Text = '/a/./b'; Expected = $false }
        @{ Text = '/a//b'; Expected = $false }
        @{ Text = '/a/b'; Expected = $true }
        @{ Text = '/a/b/'; Expected = $true }
        @{ Text = '/a\b'; Expected = $true }
    ) {
        (Test-SwCleanCanonicalText -Text $Text -Windows $false) | Should -Be $Expected
    }

    It 'asks the host when no kind of host is given' {
        $windows = ([System.IO.Path]::DirectorySeparatorChar -eq '\')
        $text = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'x') + [System.IO.Path]::DirectorySeparatorChar + '..' + [System.IO.Path]::DirectorySeparatorChar + 'y'
        (Test-SwCleanCanonicalText -Text $text) | Should -BeFalse
        (Test-SwCleanCanonicalText -Text $text -Windows $windows) | Should -BeFalse
    }
}

Describe 'Clear-SwUserTempFiles' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-HelperSpies
    }
    AfterEach { Stop-Case }

    It 'U-1 passes the temp folder, the days, the filter * and the description to Remove-SwOldFiles, once' {
        Clear-SwUserTempFiles -DaysOld 7
        $script:Calls.Count | Should -Be 1
        $call = (Get-Calls 'Remove-SwOldFiles')[0]
        $call.Path | Should -BeExactly $script:Scratch
        $call.DaysOld | Should -Be 7
        $call.Filter | Should -BeExactly '*'
        $call.Description | Should -BeExactly 'User temp files'
    }

    It 'CL-30 uses 7 days when no value is given' {
        Clear-SwUserTempFiles
        (Get-Calls 'Remove-SwOldFiles')[0].DaysOld | Should -Be 7
    }

    It 'CL-26 passes the days as given, 0 included (older than now)' -ForEach @(
        @{ Days = 0 }
        @{ Days = 1 }
        @{ Days = 30 }
    ) {
        Clear-SwUserTempFiles -DaysOld $Days
        (Get-Calls 'Remove-SwOldFiles')[0].DaysOld | Should -Be $Days
    }

    It 'CL-26 S-20 calls no helper for negative days' -ForEach @(
        @{ Days = -1 }
        @{ Days = -30 }
    ) {
        Clear-SwUserTempFiles -DaysOld $Days
        $script:Calls.Count | Should -Be 0
    }

    It 'SI-4 asks the helper the same way in a preview and in a real run' -ForEach $script:RunModes {
        Set-SwDryRunMode -Enabled $Dry
        Clear-SwUserTempFiles -DaysOld 7
        $script:Calls.Count | Should -Be 1
        (Get-Calls 'Remove-SwOldFiles')[0].Path | Should -BeExactly $script:Scratch
    }

    It 'CL-21 trims the value of TEMP and uses it unchanged as the path' {
        Set-Env 'TEMP' ('  ' + $script:Scratch + '  ')
        Clear-SwUserTempFiles
        (Get-Calls 'Remove-SwOldFiles')[0].Path | Should -BeExactly $script:Scratch
    }

    It 'CL-21 keeps a trailing separator of TEMP, as nothing is appended' {
        Set-Env 'TEMP' ($script:Scratch + $script:Sep)
        Clear-SwUserTempFiles
        $script:Calls.Count | Should -Be 1
        (Get-Calls 'Remove-SwOldFiles')[0].Path | Should -BeExactly ($script:Scratch + $script:Sep)
    }

    It 'CL-21 S-12 offers nothing when TEMP is <Label>' -ForEach $script:BadValues {
        Set-Env 'TEMP' $Value
        Clear-SwUserTempFiles
        $script:Calls.Count | Should -Be 0
    }

    It 'CL-21 does not offer a TEMP folder that does not exist, and says nothing' {
        Set-Env 'TEMP' (P $script:Work 'no-such-temp')
        Clear-SwUserTempFiles
        $script:Calls.Count | Should -Be 0
        $script:NotMeasured.Count | Should -Be 0
    }

    It 'CL-21 does not offer a TEMP that is a file' {
        Set-Env 'TEMP' (New-File (P $script:Work 'a-file') 3)
        Clear-SwUserTempFiles
        $script:Calls.Count | Should -Be 0
    }

    It 'CL-21 S-13 takes the folder literally: TEMP below Apps [x] never mixes with Apps x' {
        $bracket = New-Dir (P $script:Work 'Apps [x]' 'tmp')
        $null = New-Dir (P $script:Work 'Apps x' 'tmp')
        Set-Env 'TEMP' $bracket
        Clear-SwUserTempFiles
        (Get-Calls 'Remove-SwOldFiles')[0].Path | Should -BeExactly $bracket
    }

    It 'S-19 CL-21a offers a TEMP below the local application data folder' {
        $temp = New-Dir (P $script:Local 'Temp')
        Set-Env 'TEMP' $temp
        Clear-SwUserTempFiles
        @(Get-Calls 'Remove-SwOldFiles').Count | Should -Be 1
    }

    It 'S-19 CL-21a, CL-28 leaves out an implausible TEMP and notes it as not verified: <Label>' -ForEach @(
        @{ Label = 'the user profile'; Make = { $script:Profile } }
        @{ Label = 'a drive root'; Make = { [System.IO.Path]::GetPathRoot($script:Work) } }
        @{ Label = 'the local application data folder'; Make = { $script:Local } }
        @{ Label = 'the roaming application data folder'; Make = { $script:Roam } }
        @{ Label = 'a path with a parent segment'; Make = { $null = New-Dir (P $script:Profile 'y'); $script:Profile + $script:Sep + 'x' + $script:Sep + '..' + $script:Sep + 'y' } }
        @{ Label = 'a path with a dot segment'; Make = { $null = New-Dir (P $script:Profile 'y'); $script:Profile + $script:Sep + '.' + $script:Sep + 'y' } }
        @{ Label = 'a parent of the profile'; Make = { $script:Work } }
        @{ Label = 'a parent of the application data folders'; Make = { P $script:Profile 'AppData' } }
    ) {
        Set-Env 'TEMP' (& $Make)
        Clear-SwUserTempFiles
        $script:Calls.Count | Should -Be 0
        $script:NotMeasured.Count | Should -Be 1
        $script:NotMeasured[0].Name | Should -BeExactly 'User temp files'
        $script:NotMeasured[0].Reason | Should -BeExactly 'not verified'
    }

    It 'leaves out a TEMP with a doubled separator, and notes it as not verified' {
        $null = New-Dir (P $script:Profile 'AppData' 'Local' 'Temp')
        Set-Env 'TEMP' ($script:Profile + $script:Sep + 'AppData' + $script:Sep + $script:Sep + 'Local' + $script:Sep + 'Temp')
        Clear-SwUserTempFiles
        $script:Calls.Count | Should -Be 0
        $script:NotMeasured.Count | Should -Be 1
        $script:NotMeasured[0].Name | Should -BeExactly 'User temp files'
        $script:NotMeasured[0].Reason | Should -BeExactly 'not verified'
    }

    It 'offers a TEMP with one trailing separator below the local application data folder' {
        $temp = New-Dir (P $script:Local 'Temp')
        Set-Env 'TEMP' ($temp + $script:Sep)
        Clear-SwUserTempFiles
        @(Get-Calls 'Remove-SwOldFiles').Count | Should -Be 1
        $script:NotMeasured.Count | Should -Be 0
    }

    It '[W] offers a TEMP written as an 8.3 short name when the long form is plausible' {
        $long = New-Dir (P $script:Local 'Temp')
        $short = $null
        try {
            $text = @(& cmd.exe /c ('for %I in ("' + $long + '") do @echo %~sI') 2>$null) -join ''
            $short = $text.Trim()
        }
        catch { $short = $null }
        if ([string]::IsNullOrEmpty($short) -or $short -eq $long) { Set-ItResult -Skipped -Because 'this host has no 8.3 short name for the folder'; return }
        Set-Env 'TEMP' $short
        Clear-SwUserTempFiles
        $script:NotMeasured.Count | Should -Be 0
        @(Get-Calls 'Remove-SwOldFiles').Count | Should -Be 1
    }

    It 'CL-21a [W] leaves out a known folder (Documents, Desktop) as TEMP' -ForEach @(
        @{ Folder = 'MyDocuments' }
        @{ Folder = 'Desktop' }
    ) {
        $known = [System.Environment]::GetFolderPath($Folder)
        if ([string]::IsNullOrEmpty($known)) { Set-ItResult -Skipped -Because ('this host has no ' + $Folder + ' folder'); return }
        Set-Env 'TEMP' $known
        Clear-SwUserTempFiles
        $script:Calls.Count | Should -Be 0
    }

    It 'CL-21a leaves out a TEMP whose final spelling is the profile (a link), also when the typed spelling is fine' {
        Mock Resolve-SwSafePath { if ((Fold $Path) -eq (Fold $script:Scratch)) { $script:Profile } else { $Path } }
        Clear-SwUserTempFiles
        $script:Calls.Count | Should -Be 0
        $script:NotMeasured.Count | Should -Be 1
    }

    It 'CL-21a judges only the typed spelling when Resolve-SwSafePath gives $null' {
        Mock Resolve-SwSafePath { $null }
        Clear-SwUserTempFiles
        $script:Calls.Count | Should -Be 1
    }

    It 'CL-28 notes nothing for a missing environment variable or a missing folder' {
        Set-Env 'TEMP' $null
        Clear-SwUserTempFiles
        $script:NotMeasured.Count | Should -Be 0
    }

    It 'SI-6 writes nothing to the pipeline' {
        Mock Remove-SwOldFiles { 'noise'; $true }
        @(Clear-SwUserTempFiles).Count | Should -Be 0
    }

    It 'CL-20 does not throw when the helper throws' {
        Mock Remove-SwOldFiles { throw 'failure (test)' }
        { Clear-SwUserTempFiles } | Should -Not -Throw
    }
}

# ============================================================================
# Clear-SwUserLogs: U-6, U-7 (CL-32, CL-21a, CL-22, CL-26)
# ============================================================================

Describe 'Clear-SwUserLogs' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-HelperSpies
        $script:Temp6 = New-Dir (Get-LocalTemp)
    }
    AfterEach { Stop-Case }

    It 'CL-32 offers only the old .log files in the roaming folder, in one call' {
        $old = New-OldFile (P $script:Roam 'old.log') 30
        $null = New-File (P $script:Roam 'new.log')
        $null = New-OldFile (P $script:Roam 'old.log1') 30
        $null = New-OldFile (P $script:Roam 'old.logfile') 30
        $null = New-OldFile (P $script:Roam 'old.txt') 30
        Clear-SwUserLogs
        $calls = @(Get-Calls 'Remove-SwItems')
        $calls.Count | Should -Be 1
        @($calls[0].Paths) | Should -Be @($old)
        $calls[0].Description | Should -BeExactly 'Old log files'
        @($calls[0].Paths).GetType().IsArray | Should -BeTrue
    }

    It 'CL-32 matches the ending .log without regard to case' {
        $lower = New-OldFile (P $script:Roam 'a.log') 30
        $upper = New-OldFile (P $script:Roam 'B.LOG') 30
        Clear-SwUserLogs
        @((Get-Calls 'Remove-SwItems')[0].Paths | Sort-Object) | Should -Be @(@($lower, $upper) | Sort-Object)
    }

    It 'CL-32 offers the files of both folders, the local Temp folder first' {
        $local = New-OldFile (P $script:Temp6 'y.log') 30
        $roam = New-OldFile (P $script:Roam 'x.log') 30
        Clear-SwUserLogs
        $calls = @(Get-Calls 'Remove-SwItems')
        $calls.Count | Should -Be 2
        @($calls[0].Paths) | Should -Be @($local)
        @($calls[1].Paths) | Should -Be @($roam)
        $calls[0].Description | Should -BeExactly 'Old log files'
        $calls[1].Description | Should -BeExactly 'Old log files'
    }

    It 'CL-32 makes no call when a folder has no old log file' {
        $null = New-File (P $script:Roam 'new.log')
        $null = New-OldFile (P $script:Roam 'old.txt') 30
        Clear-SwUserLogs
        $script:Calls.Count | Should -Be 0
    }

    It 'CL-32 does not offer folders or files inside folders' {
        $null = New-Dir (P $script:Roam 'dir.log')
        $null = New-OldFile (P $script:Roam 'sub' 'inner.log') 30
        $keep = New-OldFile (P $script:Roam 'top.log') 30
        Clear-SwUserLogs
        @((Get-Calls 'Remove-SwItems')[0].Paths) | Should -Be @($keep)
    }

    It 'CL-32 does not offer hidden log files' {
        $null = New-HiddenFile $script:Roam 'secret.log' 30
        $shown = New-OldFile (P $script:Roam 'shown.log') 30
        Clear-SwUserLogs
        @((Get-Calls 'Remove-SwItems')[0].Paths) | Should -Be @($shown)
    }

    It 'CL-26 offers a file older than now when LogDaysOld is 0 and a younger one never' {
        $minutes = P $script:Roam 'five-minutes.log'
        $null = New-File $minutes
        Set-Age $minutes (5 / 1440)
        $future = P $script:Roam 'future.log'
        $null = New-File $future
        Set-Time $future ([datetime]::Now.AddDays(1))
        Clear-SwUserLogs -DaysOld 0
        @((Get-Calls 'Remove-SwItems')[0].Paths) | Should -Be @($minutes)
    }

    It 'CL-26 uses strictly older: a file exactly at the cut-off stays, one second older goes' {
        $script:FakeNow = [datetime]'2026-10-31T12:00:00'
        Mock Get-Date { $script:FakeNow }
        $edge = P $script:Roam 'edge.log'
        $past = P $script:Roam 'past.log'
        $null = New-File $edge
        $null = New-File $past
        Set-Time $edge $script:FakeNow.AddDays(-7)
        Set-Time $past $script:FakeNow.AddDays(-7).AddSeconds(-1)
        Clear-SwUserLogs -DaysOld 7
        @((Get-Calls 'Remove-SwItems')[0].Paths) | Should -Be @($past)
    }

    It 'CL-26 S-20 calls no helper for negative days' {
        $null = New-OldFile (P $script:Roam 'old.log') 30
        $null = New-OldFile (P $script:Temp6 'old.log') 30
        Clear-SwUserLogs -DaysOld -1
        $script:Calls.Count | Should -Be 0
    }

    It 'CL-30 uses 7 days when no value is given' {
        $null = New-OldFile (P $script:Roam 'eight.log') 8
        $null = New-OldFile (P $script:Roam 'six.log') 6
        Clear-SwUserLogs
        @((Get-Calls 'Remove-SwItems')[0].Paths | ForEach-Object { [System.IO.Path]::GetFileName($_) }) | Should -Be @('eight.log')
    }

    It 'CL-22 leaves the local Temp folder to U-1 when TEMP is the same folder' {
        Set-Env 'TEMP' $script:Temp6
        $null = New-OldFile (P $script:Temp6 'x.log') 30
        Clear-SwUserLogs
        $script:Calls.Count | Should -Be 0
    }

    It 'CL-22 recognizes the same folder with a trailing separator in TEMP' {
        Set-Env 'TEMP' ($script:Temp6 + $script:Sep)
        $null = New-OldFile (P $script:Temp6 'x.log') 30
        Clear-SwUserLogs
        $script:Calls.Count | Should -Be 0
    }

    It 'leaves the local Temp folder to the temp target when TEMP only resolves to the same folder' {
        $script:TypedTemp = New-Dir (P $script:Work 'temp-spelled-differently')
        Set-Env 'TEMP' $script:TypedTemp
        $null = New-OldFile (P $script:Temp6 'x.log') 30
        Mock Resolve-SwSafePath {
            if ((Fold $Path) -eq (Fold $script:TypedTemp) -or (Fold $Path) -eq (Fold $script:Temp6)) { $script:Temp6 } else { $Path }
        }
        Clear-SwUserLogs
        @(Get-OfferedPaths | Where-Object { Test-SameOrUnder $_ $script:Temp6 }).Count | Should -Be 0
        $script:NotMeasured.Count | Should -Be 0
    }

    It 'counts only the typed spelling when Resolve-SwSafePath gives $null for one of the two folders' -ForEach @(
        @{ Which = 'TEMP' }
        @{ Which = 'the local Temp folder' }
    ) {
        $script:TypedTemp = New-Dir (P $script:Work 'temp-spelled-differently')
        Set-Env 'TEMP' $script:TypedTemp
        $keep = New-OldFile (P $script:Temp6 'x.log') 30
        $script:NullFor = if ($Which -eq 'TEMP') { $script:TypedTemp } else { $script:Temp6 }
        Mock Resolve-SwSafePath {
            if ((Fold $Path) -eq (Fold $script:NullFor)) { $null }
            elseif ((Fold $Path) -eq (Fold $script:TypedTemp)) { $script:Temp6 }
            else { $Path }
        }
        Clear-SwUserLogs
        @(Get-OfferedPaths) | Should -Contain $keep
    }

    It 'leaves the local Temp folder to the temp target when only the typed spelling can be compared' {
        Set-Env 'TEMP' $script:Temp6
        $null = New-OldFile (P $script:Temp6 'x.log') 30
        Mock Resolve-SwSafePath { $null }
        Clear-SwUserLogs
        @(Get-OfferedPaths | Where-Object { Test-SameOrUnder $_ $script:Temp6 }).Count | Should -Be 0
    }

    It 'CL-22 still offers the local Temp folder when TEMP is another folder' {
        $keep = New-OldFile (P $script:Temp6 'y.log') 30
        Clear-SwUserLogs
        @((Get-Calls 'Remove-SwItems')[0].Paths) | Should -Be @($keep)
    }

    It 'CL-32 offers nothing for a local Temp folder that does not exist, and says nothing' {
        Remove-Item -LiteralPath $script:Temp6 -Recurse -Force
        Clear-SwUserLogs
        $script:Calls.Count | Should -Be 0
        $script:NotMeasured.Count | Should -Be 0
    }

    It 'CL-21 S-12 takes nothing below LOCALAPPDATA when it is <Label>, and still offers the roaming files' -ForEach $script:BadValues {
        Set-Env 'LOCALAPPDATA' $Value
        $roam = New-OldFile (P $script:Roam 'x.log') 30
        Clear-SwUserLogs
        $calls = @(Get-Calls 'Remove-SwItems')
        $calls.Count | Should -Be 1
        @($calls[0].Paths) | Should -Be @($roam)
    }

    It 'CL-21 S-12 takes nothing from APPDATA when it is <Label>, and still offers the local Temp files' -ForEach $script:BadValues {
        Set-Env 'APPDATA' $Value
        $local = New-OldFile (P $script:Temp6 'y.log') 30
        Clear-SwUserLogs
        $calls = @(Get-Calls 'Remove-SwItems')
        $calls.Count | Should -Be 1
        @($calls[0].Paths) | Should -Be @($local)
    }

    It 'CL-21 S-13 takes APPDATA literally: Max [A] never mixes with Max A' {
        $bracket = New-Dir (P $script:Work 'Max [A]' 'Roaming')
        $decoy = New-Dir (P $script:Work 'Max A' 'Roaming')
        Set-Env 'APPDATA' $bracket
        $keep = New-OldFile (P $bracket 'old.log') 30
        $null = New-OldFile (P $decoy 'old.log') 30
        Clear-SwUserLogs
        @(Get-OfferedPaths) | Should -Be @($keep)
    }

    It 'CL-21 keeps a trailing separator out of the paths of the files' {
        Set-Env 'APPDATA' ($script:Roam + $script:Sep)
        $null = New-OldFile (P $script:Roam 'old.log') 30
        Clear-SwUserLogs
        @(Get-OfferedPaths) | Should -Be @(P $script:Roam 'old.log')
    }

    It 'S-19 CL-21a, CL-28 leaves out APPDATA when it is <Label>, and notes it as not verified' -ForEach @(
        @{ Label = 'the user profile'; Make = { $script:Profile } }
        @{ Label = 'a drive root'; Make = { [System.IO.Path]::GetPathRoot($script:Work) } }
        @{ Label = 'the local application data folder'; Make = { $script:Local } }
        @{ Label = 'a parent of the profile'; Make = { $script:Work } }
        @{ Label = 'a path with a parent segment'; Make = { $null = New-Dir (P $script:Profile 'y'); $script:Profile + $script:Sep + 'x' + $script:Sep + '..' + $script:Sep + 'y' } }
    ) {
        $value = & $Make
        Set-Env 'APPDATA' $value
        # never write outside the test drive: a drive root gets no fixture file
        if (Test-Under $value $TestDrive) { $null = New-OldFile (P $value 'old.log') 30 }
        Clear-SwUserLogs
        @(Get-OfferedPaths | Where-Object { Test-SameOrUnder $_ $value }).Count | Should -Be 0
        $script:NotMeasured.Count | Should -Be 1
        $script:NotMeasured[0].Name | Should -BeExactly 'Old log files'
        $script:NotMeasured[0].Reason | Should -BeExactly 'not verified'
    }

    It 'offers APPDATA although it equals APPDATA (that is no reason to refuse U-7)' {
        $keep = New-OldFile (P $script:Roam 'old.log') 30
        Clear-SwUserLogs
        @(Get-OfferedPaths) | Should -Contain $keep
        $script:NotMeasured.Count | Should -Be 0
    }

    It 'S-19 CL-21a leaves out the local Temp folder when the profile lies below it' {
        Set-Env 'USERPROFILE' (P $script:Temp6 'profile')
        $null = New-Dir (P $script:Temp6 'profile')
        $null = New-OldFile (P $script:Temp6 'y.log') 30
        Clear-SwUserLogs
        @(Get-OfferedPaths | Where-Object { Test-SameOrUnder $_ $script:Temp6 }).Count | Should -Be 0
    }

    It 'S-19 CL-21a leaves out the local Temp folder when LOCALAPPDATA is not canonical' {
        Set-Env 'LOCALAPPDATA' ($script:Profile + $script:Sep + 'AppData' + $script:Sep + 'x' + $script:Sep + '..' + $script:Sep + 'Local')
        $null = New-OldFile (P $script:Temp6 'y.log') 30
        Clear-SwUserLogs
        @(Get-OfferedPaths | Where-Object { Test-SameOrUnder $_ $script:Temp6 }).Count | Should -Be 0
    }

    It 'SI-4 asks the helper the same way in <Mode>' -ForEach $script:RunModes {
        Set-SwDryRunMode -Enabled $Dry
        $null = New-OldFile (P $script:Roam 'old.log') 30
        Clear-SwUserLogs
        @(Get-Calls 'Remove-SwItems').Count | Should -Be 1
    }

    It 'SI-6 writes nothing to the pipeline' {
        $null = New-OldFile (P $script:Roam 'old.log') 30
        Mock Remove-SwItems { 'noise' }
        @(Clear-SwUserLogs).Count | Should -Be 0
    }

    It 'CL-20 offers the second folder when the helper throws for the first' {
        $null = New-OldFile (P $script:Temp6 'y.log') 30
        $null = New-OldFile (P $script:Roam 'x.log') 30
        $script:Attempts = [System.Collections.Generic.List[string]]::new()
        Mock Remove-SwItems { $script:Attempts.Add([string]$Paths[0]); throw 'failure (test)' }
        { Clear-SwUserLogs } | Should -Not -Throw
        $script:Attempts.Count | Should -Be 2
    }
}

# ============================================================================
# Clear-SwReportRoot: the report rule (CL-31, CL-26, CL-27, CL-28, S-7, S-18)
# ============================================================================

Describe 'Clear-SwReportRoot' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-HelperSpies
        $script:Root = New-Dir (P $script:Local 'Reports')
    }
    AfterEach { Stop-Case }

    It 'CL-31 offers an old report once with the path as the only element, the description and a condition' {
        $old = New-Report $script:Root 'old'
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        $calls = @(Get-Calls 'Remove-SwItems')
        $calls.Count | Should -Be 1
        $script:Calls.Count | Should -Be 1
        @($calls[0].Paths) | Should -Be @($old)
        $calls[0].Description | Should -BeExactly 'Error reports'
        $calls[0].CanRemove | Should -BeOfType [scriptblock]
    }

    It 'CL-31 passes the description it was given' {
        $null = New-Report $script:Root 'old'
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Example reports'
        (Get-Calls 'Remove-SwItems')[0].Description | Should -BeExactly 'Example reports'
    }

    It 'CL-31 never offers a recent report' {
        $null = New-Report $script:Root 'recent' 0
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        $script:Calls.Count | Should -Be 0
    }

    It 'CL-31 makes one call per old report and none for a recent one' {
        $a = New-Report $script:Root 'old-a'
        $b = New-Report $script:Root 'old-b' 12
        $null = New-Report $script:Root 'recent' 0
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        $calls = @(Get-Calls 'Remove-SwItems')
        $calls.Count | Should -Be 2
        foreach ($call in $calls) { @($call.Paths).Count | Should -Be 1 }
        @($calls | ForEach-Object { $_.Paths[0] } | Sort-Object) | Should -Be @(@($a, $b) | Sort-Object)
    }

    It 'CL-31 offers a loose old file as a report and never a recent one' {
        $old = New-OldFile (P $script:Root 'old.wer') 10
        $null = New-File (P $script:Root 'new.wer')
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        @(Get-OfferedPaths) | Should -Be @($old)
    }

    It 'CL-31 keeps a report with a young attachment, also when its folder looks old' {
        $dir = New-Report $script:Root 'mixed'
        $null = New-File (P $dir 'attachment.dmp')
        Set-Age $dir 10
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        $script:Calls.Count | Should -Be 0
    }

    It 'CL-31 keeps a report with a young hidden file inside' {
        $dir = New-Report $script:Root 'mixed'
        $null = New-HiddenFile $dir 'young.tmp' 0
        Set-Age $dir 10
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        $script:Calls.Count | Should -Be 0
    }

    It 'CL-31 offers a report whose old files include a hidden old file' {
        $dir = New-Report $script:Root 'old'
        $null = New-HiddenFile $dir 'old.tmp' 10
        Set-Age $dir 10
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        @(Get-OfferedPaths) | Should -Be @($dir)
    }

    It 'CL-31 keeps a report whose own folder is young, although every file in it is old' {
        $dir = New-Report $script:Root 'touched'
        Set-Age $dir 0
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        $script:Calls.Count | Should -Be 0
    }

    It 'CL-31 ignores the time stamp of the root folder itself' {
        $old = New-Report $script:Root 'old'
        Set-Age $script:Root 0
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        @(Get-OfferedPaths) | Should -Be @($old)
    }

    It 'CL-31 [W] keeps a report when its creation time is recent although its write time is old' {
        $file = New-File (P $script:Root 'young-creation.wer') 5
        [System.IO.File]::SetLastWriteTime($file, [datetime]::Now.AddDays(-10))
        [System.IO.File]::SetCreationTime($file, [datetime]::Now)
        [System.IO.File]::GetCreationTime($file) | Should -BeGreaterThan ([datetime]::Now.AddDays(-1)) -Because 'this host cannot set the two time stamps apart'
        [System.IO.File]::GetLastWriteTime($file) | Should -BeLessThan ([datetime]::Now.AddDays(-9)) -Because 'this host cannot set the two time stamps apart'
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        $script:Calls.Count | Should -Be 0
    }

    It 'CL-31 keeps a report with a link inside' {
        $dir = New-Report $script:Root 'linked'
        $target = New-OldFile (P $script:Work 'elsewhere' 'outside.dat') 30
        if (-not (New-TestLink (P $dir 'link.dat') $target)) { Set-ItResult -Skipped -Because 'this account cannot create a file link'; return }
        Set-Age $dir 10
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        $script:Calls.Count | Should -Be 0
        Exists $target | Should -BeTrue
    }

    It 'CL-31 keeps a report that is itself a link' {
        $target = New-Report (P $script:Work 'elsewhere') 'real' 30
        if (-not (New-TestLink (P $script:Root 'linked-report') $target)) { Set-ItResult -Skipped -Because 'this account cannot create a folder link'; return }
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        $script:Calls.Count | Should -Be 0
    }

    It 'CL-26 uses strictly older: a report exactly at the cut-off stays, one second older goes' {
        $script:FakeNow = [datetime]'2026-10-31T12:00:00'
        Mock Get-Date { $script:FakeNow }
        $edge = P $script:Root 'edge.wer'
        $past = P $script:Root 'past.wer'
        $null = New-File $edge
        $null = New-File $past
        Set-Time $edge $script:FakeNow.AddDays(-7)
        Set-Time $past $script:FakeNow.AddDays(-7).AddSeconds(-1)
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        @(Get-OfferedPaths) | Should -Be @($past)
    }

    It 'CL-31 fixes the cut-off once per call, whatever the clock does afterwards' {
        $script:Clock = [datetime]'2026-10-31T12:00:00'
        $script:Ticks = 0
        Mock Get-Date { $script:Ticks++; $script:Clock.AddDays(2 * ($script:Ticks - 1)) }
        $young = P $script:Root 'six-days.wer'
        $old = P $script:Root 'eight-days.wer'
        $null = New-File $young
        $null = New-File $old
        Set-Time $young $script:Clock.AddDays(-6)
        Set-Time $old $script:Clock.AddDays(-8)
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        @(Get-OfferedPaths) | Should -Be @($old)
    }

    It 'CL-26 offers a report older than now for 0 days' {
        $old = New-Report $script:Root 'old'
        Clear-SwReportRoot -Root $script:Root -DaysOld 0 -Description 'Error reports'
        @(Get-OfferedPaths) | Should -Be @($old)
    }

    It 'CL-26 S-20 calls no helper for negative days' {
        $null = New-Report $script:Root 'old'
        Clear-SwReportRoot -Root $script:Root -DaysOld -1 -Description 'Error reports'
        $script:Calls.Count | Should -Be 0
    }

    It 'CL-31 offers hidden old entries in the root' {
        $hidden = New-HiddenFile $script:Root 'hidden.wer' 10
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        @(Get-OfferedPaths) | Should -Be @($hidden)
    }

    It 'CL-31 -DumpOnly offers only the old files that end in .dmp, whatever the case' {
        $dump = New-OldFile (P $script:Root 'old.dmp') 10
        $upper = New-OldFile (P $script:Root 'OLD2.DMP') 10
        $null = New-File (P $script:Root 'recent.dmp')
        $null = New-OldFile (P $script:Root 'old-notes.txt') 10
        $null = New-OldFile (P $script:Root 'old-folder' 'inner.dmp') 10
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports' -DumpOnly
        @(Get-OfferedPaths | Sort-Object) | Should -Be @(@($dump, $upper) | Sort-Object)
    }

    It 'CL-31 without -DumpOnly offers old folders and files of every kind' {
        $a = New-OldFile (P $script:Root 'old-notes.txt') 10
        $b = New-Report $script:Root 'old-folder'
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        @(Get-OfferedPaths | Sort-Object) | Should -Be @(@($a, $b) | Sort-Object)
    }

    It 'CL-31 step 1 does nothing and says nothing for a root that does not exist' {
        Clear-SwReportRoot -Root (P $script:Local 'NoSuchReports') -DaysOld 7 -Description 'Error reports'
        $script:Calls.Count | Should -Be 0
        $script:NotMeasured.Count | Should -Be 0
    }

    It 'CL-31 step 1 does nothing for a root that is a file' {
        $file = New-File (P $script:Local 'a-file') 3
        Clear-SwReportRoot -Root $file -DaysOld 7 -Description 'Error reports'
        $script:Calls.Count | Should -Be 0
    }

    It 'CL-31 step 1 asks for the snapshot of the root without -AllowLeafLink' {
        $null = New-Report $script:Root 'old'
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        $calls = @($script:SnapshotCalls | Where-Object { (Fold $_.Path) -eq (Fold $script:Root) })
        $calls.Count | Should -BeGreaterOrEqual 1
        @($calls | Where-Object { $_.AllowLeafLink }).Count | Should -Be 0
    }

    It 'CL-31 CL-28 leaves the whole root when its snapshot is $null and notes it as not verified' {
        $null = New-Report $script:Root 'old'
        $script:FakeNoIdentity.Add($script:Root)
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        $script:Calls.Count | Should -Be 0
        $script:NotMeasured.Count | Should -Be 1
        $script:NotMeasured[0].Reason | Should -BeExactly 'not verified'
        ($script:NotMeasured[0].Name -like '*Error reports*' -or $script:NotMeasured[0].Name -like '*Reports*') | Should -BeTrue
    }

    It 'names the root by its whole path, so that the roots of the user and of the system stay apart' {
        $user = New-Dir (Get-WerQueue)
        $system = New-Dir (P $script:ProgramData 'Microsoft' 'Windows' 'WER' 'ReportQueue')
        $null = New-Report $user 'old'
        $null = New-Report $system 'old'
        $script:FakeNoIdentity.Add($user)
        $script:FakeNoIdentity.Add($system)
        Clear-SwReportRoot -Root $user -DaysOld 7 -Description 'Error reports'
        Clear-SwReportRoot -Root $system -DaysOld 7 -Description 'Error reports'
        $script:Calls.Count | Should -Be 0
        $names = @(Get-NotMeasuredNames)
        $names.Count | Should -Be 2
        $names | Should -Contain ('Error reports (' + $user + ')')
        $names | Should -Contain ('Error reports (' + $system + ')')
    }

    It 'S-7 leaves a root that is a link and does not enter it' {
        $target = New-Report (P $script:Work 'elsewhere') 'old' 30
        $link = P $script:Local 'LinkedReports'
        if (-not (New-TestLink $link (Split-Path -Parent $target))) { Set-ItResult -Skipped -Because 'this account cannot create a folder link'; return }
        Clear-SwReportRoot -Root $link -DaysOld 7 -Description 'Error reports'
        $script:Calls.Count | Should -Be 0
        $script:NotMeasured.Count | Should -Be 1
    }

    It 'CL-31 step 3 leaves the whole root when its identity changed during the listing' {
        $null = New-Report $script:Root 'old'
        $script:FakeReplaced.Add($script:Root)
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        $script:Calls.Count | Should -Be 0
        $script:NotMeasured.Count | Should -Be 1
        $script:NotMeasured[0].Reason | Should -BeIn @('incomplete scan', 'not verified')
        @($script:SnapshotTests | Where-Object { (Fold $_) -eq (Fold $script:Root) }).Count | Should -BeGreaterOrEqual 1
    }

    It 'S-18 CL-27 leaves the whole root when the time budget is 0 and notes incomplete scan' {
        $null = New-Report $script:Root 'old'
        $script:SwProbeBudgetSeconds = 0
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        $script:Calls.Count | Should -Be 0
        $script:NotMeasured.Count | Should -Be 1
        $script:NotMeasured[0].Reason | Should -BeExactly 'incomplete scan'
    }

    It 'works with 2 seconds when the budget variable is missing or not a number' -ForEach @(
        @{ Case = 'missing'; Value = $null }
        @{ Case = 'not a number'; Value = 'soon' }
    ) {
        $old = New-Report $script:Root 'old'
        if ($null -eq $Value) { Remove-Variable -Name SwProbeBudgetSeconds -Scope Script } else { $script:SwProbeBudgetSeconds = $Value }
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        @(Get-OfferedPaths) | Should -Be @($old)
        $script:NotMeasured.Count | Should -Be 0
    }

    It 'CL-27 leaves the whole root, offering nothing, when it holds 5000 entries, and notes incomplete scan' {
        New-ManyFiles $script:Root 5000
        Set-TreeAge $script:Root 10
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        $script:Calls.Count | Should -Be 0
        $script:NotMeasured.Count | Should -Be 1
        $script:NotMeasured[0].Reason | Should -BeExactly 'incomplete scan'
    }

    It 'CL-27 offers the reports of a root with 10 entries' {
        New-ManyFiles $script:Root 10
        Set-TreeAge $script:Root 10
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        @(Get-Calls 'Remove-SwItems').Count | Should -Be 10
        $script:NotMeasured.Count | Should -Be 0
    }

    It 'CL-27 keeps a report that holds 5000 entries and still offers its small sibling' {
        $big = New-Dir (P $script:Root 'big')
        New-ManyFiles $big 5000
        Set-TreeAge $big 10
        $small = New-Report $script:Root 'small'
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        @(Get-OfferedPaths) | Should -Be @($small)
    }

    It 'CL-31 step 4 gives the condition exactly one [bool] true while the report is unchanged' {
        $null = New-Report $script:Root 'old'
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        $block = (Get-Calls 'Remove-SwItems')[0].CanRemove
        $answer = @(& $block)
        $answer.Count | Should -Be 1
        $answer[0] | Should -BeOfType [bool]
        $answer[0] | Should -BeTrue
    }

    It 'CL-31 step 4 gives $false from the condition when a new file appeared in the report after the offer' {
        $dir = New-Report $script:Root 'old'
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        $block = (Get-Calls 'Remove-SwItems')[0].CanRemove
        $null = New-File (P $dir 'new.dmp')
        Set-Age $dir 10
        $answer = @(& $block)
        $answer.Count | Should -Be 1
        $answer[0] | Should -BeFalse
    }

    It 'CL-31 step 4 reads the times afresh: a report touched after the offer is not removed' {
        $dir = New-Report $script:Root 'old'
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        $block = (Get-Calls 'Remove-SwItems')[0].CanRemove
        Set-TreeAge $dir 0
        (@(& $block))[0] | Should -BeFalse
    }

    It 'CL-31 step 4 gives $false from the condition, and does not throw, when the report is gone' {
        $dir = New-Report $script:Root 'old'
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        $block = (Get-Calls 'Remove-SwItems')[0].CanRemove
        Remove-Item -LiteralPath $dir -Recurse -Force
        $answer = @(& $block)
        $answer.Count | Should -Be 1
        $answer[0] | Should -BeFalse
    }

    It 'CL-31 step 4 gives $false from the condition when the root has another identity' {
        $null = New-Report $script:Root 'old'
        Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports'
        $block = (Get-Calls 'Remove-SwItems')[0].CanRemove
        $script:FakeReplaced.Add($script:Root)
        (@(& $block))[0] | Should -BeFalse
    }

    It 'CL-21 S-13 reads the root literally: Max [A] never mixes with Max A' {
        $bracket = New-Dir (P $script:Work 'Max [A]' 'Reports')
        $decoy = New-Dir (P $script:Work 'Max A' 'Reports')
        $keep = New-Report $bracket 'old'
        $null = New-Report $decoy 'olddecoy'
        Clear-SwReportRoot -Root $bracket -DaysOld 7 -Description 'Error reports'
        @(Get-OfferedPaths) | Should -Be @($keep)
    }

    It 'CL-20 offers the next report when the helper throws for the first' {
        $null = New-Report $script:Root 'old-a'
        $null = New-Report $script:Root 'old-b'
        $script:Attempts = [System.Collections.Generic.List[string]]::new()
        Mock Remove-SwItems { $script:Attempts.Add([string]$Paths[0]); throw 'failure (test)' }
        { Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports' } | Should -Not -Throw
        $script:Attempts.Count | Should -Be 2
    }

    It 'CL-31 never throws and offers nothing for an unusable root' -ForEach @(
        @{ Label = 'an empty root'; Root = '' }
        @{ Label = 'a relative root'; Root = 'Reports' }
        @{ Label = 'a NUL character'; Root = "a$([char]0)b" }
    ) {
        { Clear-SwReportRoot -Root $Root -DaysOld 7 -Description 'Error reports' } | Should -Not -Throw
        $script:Calls.Count | Should -Be 0
    }

    It 'SI-6 writes nothing to the pipeline' {
        $null = New-Report $script:Root 'old'
        Mock Remove-SwItems { 'noise' }
        @(Clear-SwReportRoot -Root $script:Root -DaysOld 7 -Description 'Error reports').Count | Should -Be 0
    }
}

# ============================================================================
# Clear-SwErrorReports: U-3, U-4, U-5
# ============================================================================

Describe 'Clear-SwErrorReports' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        $script:Roots = [System.Collections.Generic.List[object]]::new()
        Mock Clear-SwReportRoot {
            $script:Roots.Add([pscustomobject]@{ Root = $Root; DaysOld = $DaysOld; Description = $Description; DumpOnly = [bool]$DumpOnly })
        }
    }
    AfterEach { Stop-Case }

    It 'U-3 U-4 U-5 makes three calls: the archive, the queue and the crash dumps with -DumpOnly, in this order' {
        Clear-SwErrorReports
        $script:Roots.Count | Should -Be 3
        $script:Roots[0].Root | Should -BeExactly (Get-WerArchive)
        $script:Roots[1].Root | Should -BeExactly (Get-WerQueue)
        $script:Roots[2].Root | Should -BeExactly (Get-CrashDumps)
        $script:Roots[0].DumpOnly | Should -BeFalse
        $script:Roots[1].DumpOnly | Should -BeFalse
        $script:Roots[2].DumpOnly | Should -BeTrue
    }

    It 'U-3 U-4 U-5 gives every root the description Error reports and 7 days by default' {
        Clear-SwErrorReports
        foreach ($call in $script:Roots) {
            $call.Description | Should -BeExactly 'Error reports'
            $call.DaysOld | Should -Be 7
        }
    }

    It 'CL-31 passes the days it was given to every root' {
        Clear-SwErrorReports -DaysOld 12
        foreach ($call in $script:Roots) { $call.DaysOld | Should -Be 12 }
    }

    It 'CL-21 keeps a trailing separator of LOCALAPPDATA out of the roots' {
        Set-Env 'LOCALAPPDATA' ($script:Local + $script:Sep)
        Clear-SwErrorReports
        $script:Roots[0].Root | Should -BeExactly (Get-WerArchive)
        $script:Roots[2].Root | Should -BeExactly (Get-CrashDumps)
    }

    It 'CL-21 trims LOCALAPPDATA' {
        Set-Env 'LOCALAPPDATA' ('  ' + $script:Local + ' ')
        Clear-SwErrorReports
        $script:Roots[0].Root | Should -BeExactly (Get-WerArchive)
    }

    It 'CL-21 S-12 builds no root when LOCALAPPDATA is <Label>' -ForEach $script:BadValues {
        Set-Env 'LOCALAPPDATA' $Value
        Clear-SwErrorReports
        $script:Roots.Count | Should -Be 0
    }

    It 'CL-21 S-13 builds the roots literally below a folder with brackets' {
        $bracket = New-Dir (P $script:Work 'Max [A]' 'Local')
        Set-Env 'LOCALAPPDATA' $bracket
        Clear-SwErrorReports
        $script:Roots[0].Root | Should -BeExactly (P $bracket 'Microsoft' 'Windows' 'WER' 'ReportArchive')
    }

    It 'CL-20 asks for the other roots when one call throws' {
        Mock Clear-SwReportRoot { $script:Roots.Add([pscustomobject]@{ Root = $Root }); throw 'failure (test)' }
        { Clear-SwErrorReports } | Should -Not -Throw
        $script:Roots.Count | Should -Be 3
    }

    It 'SI-6 writes nothing to the pipeline' {
        Mock Clear-SwReportRoot { 'noise' }
        @(Clear-SwErrorReports).Count | Should -Be 0
    }
}

Describe 'Clear-SwErrorReports with the real report rule' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-HelperSpies
    }
    AfterEach { Stop-Case }

    It 'CL-26 S-20 calls no helper for negative days' {
        $null = New-Report (Get-WerArchive) 'old'
        $null = New-OldFile (P (Get-CrashDumps) 'old.dmp') 10
        Clear-SwErrorReports -DaysOld -1
        $script:Calls.Count | Should -Be 0
    }

    It 'U-5 offers only old dump files directly in CrashDumps' {
        $dump = New-OldFile (P (Get-CrashDumps) 'old.dmp') 10
        $null = New-File (P (Get-CrashDumps) 'recent.dmp')
        $null = New-OldFile (P (Get-CrashDumps) 'old-notes.txt') 10
        $null = New-OldFile (P (Get-CrashDumps) 'old-folder' 'inner.dmp') 10
        Clear-SwErrorReports
        @(Get-OfferedPaths) | Should -Be @($dump)
    }

    It 'U-3 U-4 offers an old report in each of the two roots, with the description Error reports' {
        $a = New-Report (Get-WerArchive) 'old'
        $b = New-Report (Get-WerQueue) 'old'
        Clear-SwErrorReports
        @(Get-OfferedPaths | Sort-Object) | Should -Be @(@($a, $b) | Sort-Object)
        foreach ($call in (Get-Calls 'Remove-SwItems')) { $call.Description | Should -BeExactly 'Error reports' }
    }

    It 'CL-31 keeps a queue report that holds a young attachment' {
        $dir = New-Report (Get-WerQueue) 'old' 10 @('Report.wer')
        $null = New-File (P $dir 'attachment.dmp')
        Set-Age $dir 10
        Clear-SwErrorReports
        $script:Calls.Count | Should -Be 0
    }
}

# ============================================================================
# The section with the real removal helpers (CL-22, CL-31, S-4, S-8, S-17, SI-4)
# ============================================================================

Describe 'Invoke-SwUserCleanup with the real helpers' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case
        Use-Collector
        $script:OldTemp = New-OldFile (P $script:Scratch 'old.tmp') 30 100
        $script:NewTemp = New-File (P $script:Scratch 'new.tmp') 100
        $script:TempDirFile = New-OldFile (P $script:Scratch 'folder' 'inner.tmp') 30 100
        $script:LocalLog = New-OldFile (P (Get-LocalTemp) 'y.log') 30 100
        $script:RoamLog = New-OldFile (P $script:Roam 'old.log') 30 100
        $script:RoamKeep = New-OldFile (P $script:Roam 'keep.txt') 30 100
        $script:Report = New-Report (Get-WerArchive) 'old' 10 @('Report.wer', 'extra.bin')
        $script:RecentReport = New-Report (Get-WerArchive) 'recent' 0
        $script:Dump = New-OldFile (P (Get-CrashDumps) 'old.dmp') 10 100
    }
    AfterEach { Stop-Case }

    It 'S-4 SI-4 lists in a preview what a real run would remove, and changes nothing' {
        $before = Get-Listing $script:Work
        Mock Remove-Item { throw 'Remove-Item must not run in a preview (test)' }
        Invoke-SwUserCleanup
        Same-Listing (Get-Listing $script:Work) $before | Should -BeTrue
        $descriptions = @($script:DryRunCollector | ForEach-Object { $_.Description })
        $descriptions | Should -Contain 'User temp files (>7d old)'
        $descriptions | Should -Contain 'Old log files'
        $descriptions | Should -Contain 'Error reports'
        @($script:DryRunCollector | ForEach-Object { $_.Path }) | Should -Contain $script:OldTemp
        @($script:DryRunCollector | ForEach-Object { $_.Path }) | Should -Contain $script:Report
        $script:Ops.Count | Should -Be 0
    }

    It 'starts every run with an empty table of report offers' {
        (Get-SwReportChecks)['stale-entry'] = @{ Snapshot = $null; Cutoff = [datetime]::Now }
        Invoke-SwUserCleanup
        (Get-SwReportChecks).ContainsKey('stale-entry') | Should -BeFalse
        (Get-SwReportChecks).Count | Should -BeLessOrEqual 2
    }

    It 'does not let the table grow when the section runs twice' {
        Invoke-SwUserCleanup
        $first = (Get-SwReportChecks).Count
        Invoke-SwUserCleanup
        (Get-SwReportChecks).Count | Should -Be $first
    }

    It 'lists a log of a TEMP that only resolves to the local Temp folder once, and none from the local Temp folder itself' {
        $script:TypedTemp = New-Dir (P $script:Work 'temp-spelled-differently')
        Set-Env 'TEMP' $script:TypedTemp
        $inTyped = New-OldFile (P $script:TypedTemp 'x.log') 30 100
        Mock Resolve-SwSafePath {
            if ((Fold $Path) -eq (Fold $script:TypedTemp) -or (Fold $Path) -eq (Fold (Get-LocalTemp))) { Get-LocalTemp } else { $Path }
        }
        Invoke-SwUserCleanup
        @($script:DryRunCollector | Where-Object { $_.Path -ceq $inTyped }).Count | Should -Be 1
        @($script:DryRunCollector | Where-Object { $_.Path -ceq $script:LocalLog }).Count | Should -Be 0
        @($script:DryRunCollector | Where-Object { $_.Description -ceq 'Old log files' -and (Test-SameOrUnder $_.Path (Get-LocalTemp)) }).Count | Should -Be 0
    }

    It 'S-8 counts exactly the paths it lists' {
        Invoke-SwUserCleanup
        (Get-SwCleanupStats).FilesCleaned | Should -Be @($script:DryRunCollector).Count
        (Get-SwCleanupStats).FilesCleaned | Should -Be 5
    }

    It 'CL-22 S-8 lists no path below another listed path' {
        Invoke-SwUserCleanup
        Test-Disjoint @($script:DryRunCollector | ForEach-Object { $_.Path }) | Should -BeTrue
    }

    It 'U-1 offers no folder of TEMP and nothing inside one' {
        Invoke-SwUserCleanup
        Test-AnyUnder @($script:DryRunCollector | ForEach-Object { $_.Path }) (P $script:Scratch 'folder') | Should -BeFalse
    }

    It 'CL-31 U-3 removes the old report and the old dump file and keeps the recent report in a real run' {
        Set-SwDryRunMode -Enabled $false
        Invoke-SwUserCleanup
        Exists $script:OldTemp | Should -BeFalse
        Exists $script:NewTemp | Should -BeTrue
        Exists $script:TempDirFile | Should -BeTrue
        Exists $script:LocalLog | Should -BeFalse
        Exists $script:RoamLog | Should -BeFalse
        Exists $script:RoamKeep | Should -BeTrue
        Exists $script:Report | Should -BeFalse
        Exists $script:RecentReport | Should -BeTrue
        Exists $script:Dump | Should -BeFalse
        [System.IO.Directory]::Exists((Get-WerArchive)) | Should -BeTrue
        [System.IO.Directory]::Exists($script:Scratch) | Should -BeTrue
        (Get-SwCleanupStats).FilesCleaned | Should -Be 5
    }

    It 'CL-22 lists a log in the local Temp folder once, under the temp target, when TEMP is that folder' {
        Set-Env 'TEMP' (Get-LocalTemp)
        $x = New-OldFile (P (Get-LocalTemp) 'x.log') 30 100
        Invoke-SwUserCleanup
        @($script:DryRunCollector | Where-Object { $_.Path -ceq $x }).Count | Should -Be 1
        @($script:DryRunCollector | Where-Object { $_.Path -ceq $x })[0].Description | Should -BeExactly 'User temp files (>7d old)'
    }

    It 'CL-22 lists a log in the local Temp folder under Old log files when TEMP is another folder' {
        Invoke-SwUserCleanup
        $hit = @($script:DryRunCollector | Where-Object { $_.Path -ceq $script:LocalLog })
        $hit.Count | Should -Be 1
        $hit[0].Description | Should -BeExactly 'Old log files'
    }

    It 'S-17 offers nothing outside the catalog: thumbnails, icon cache, prefetch, profile root files, recent items' {
        $outside = @(
            (New-OldFile (P $script:Local 'Microsoft' 'Windows' 'Explorer' 'thumbcache_32.db') 30)
            (New-OldFile (P $script:Local 'IconCache.db') 30)
            (New-OldFile (P $script:WinDir 'Prefetch' 'APP.EXE-1234.pf') 30)
            (New-OldFile (P $script:Profile 'memory.dmp') 30)
            (New-OldFile (P $script:Profile 'install.log') 30)
            (New-OldFile (P $script:Profile '.gitconfig.lock') 30)
            (New-OldFile (P $script:Roam 'Microsoft' 'Windows' 'Recent' 'x.lnk') 30)
            (New-OldFile (P $script:Local 'Downloads' 'old.zip') 30)
        )
        Invoke-SwUserCleanup
        $listed = @($script:DryRunCollector | ForEach-Object { $_.Path })
        foreach ($path in $outside) { $listed | Should -Not -Contain $path }
    }

    It 'S-2 removes nothing that a whitelist line holds' {
        Set-SwDryRunMode -Enabled $false
        Set-Whitelist @($script:OldTemp, $script:Report)
        Invoke-SwUserCleanup
        Exists $script:OldTemp | Should -BeTrue
        Exists $script:Report | Should -BeTrue
        Exists $script:RoamLog | Should -BeFalse
        Exists $script:Dump | Should -BeFalse
    }
}
