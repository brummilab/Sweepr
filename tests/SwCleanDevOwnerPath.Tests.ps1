# Sweepr - tests for the query side of the owner paths in lib\clean\dev.ps1: Get-SwOwnerCachePath (the query, the
# switch $script:SweeprSkipExternalTools, the form of the answer), the plausibility, characteristic and never-list
# checks of the cache folder that the owner commands act on, the one-offer-per-run rule and the list of tools.
#
# The rule numbers in the test names (CD-, CA-, S- and so on) number the rules and the safety invariants
# of the behavior of the developer tool and application cleanup; each rule and invariant has at least one test.
# The other files of this slice are SwCleanDevGroups, SwCleanDevLoad, SwCleanDevScan, SwCleanDevOwnerRun,
# SwCleanDevProcess, SwCleanDevEditors, SwCleanAppsGroups, SwCleanAppsMedia and SwCleanDevAppsSafety.
#
# Interface pinned here (lib\clean\dev.ps1):
#   Get-SwOwnerCachePath -Name <string> -Arguments <string[]>
#       the cache folder of a tool as a full, canonical path ([string]) or $null; honors $script:SweeprSkipExternalTools
#   Invoke-SwOwnerCacheCleanup -Name <string> -Query <string[]> -Arguments <string[]> -Description <string>
#       the owner path of one tool; in these tests only the checks before the command are looked at
#   Invoke-SwOwnerCommand -Name -Arguments [-TimeoutSeconds 5] [-Outcome] [-Mutation]        (mocked here)
#
# Seams used with Mock: Invoke-SwOwnerCommand (the only process start; here a stand-in that records the call),
# Get-SwOwnerCachePath (answers per call or per tool), New-SwOwnerProcess and Start-Process (they must not run),
# Get-SwPathSnapshot and Test-SwPathSnapshot (substitute objects), Get-SwWhitelistState and
# Get-SwSafeDirectoryTreeItems (counting stand-ins that call the real function), Get-SwValidatedTreeSize (must not
# be called), the removal helpers (spies that must not be called), the log writers, Add-SwNotMeasured.
# The preview mode is set with $script:SweeprDryRunMode; most checks here run in a preview, where a folder that
# passes every check is counted in $script:OwnerCleanups and listed, and a refused one is not.
#
# Platform notes:
#   - Paths are host paths below $TestDrive. The known-folder cases need real Windows folders and are marked [W].
#   - Tests marked [W] need real Windows. They are meant to fail on Linux and belong in
#     tests/linux-known-failures.txt.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    # What the query output must not be accepted as: a text that is not one full, canonical path on one line.
    $script:BadOutputs = @(
        @{ Label = 'an error message'; Text = 'npm ERR! missing script' }
        @{ Label = 'two lines'; Text = ('/first/folder' + "`n" + '/second/folder') }
        @{ Label = 'two lines with a carriage return'; Text = ('/first/folder' + "`r" + '/second/folder') }
        @{ Label = 'a UNC path'; Text = '\\server\share\c' }
        @{ Label = 'a relative path'; Text = '..\cache' }
        @{ Label = 'a relative path with a folder'; Text = 'cache/inner' }
        @{ Label = 'a drive path with forward slashes'; Text = 'C:/Users/Example/cache' }
        @{ Label = 'a path that goes up'; Text = 'C:\a\..\..' }
        @{ Label = 'a host path that goes up'; Text = '/tmp/a/../b' }
        @{ Label = 'an empty text'; Text = '' }
        @{ Label = 'blanks only'; Text = '   ' }
    )
    $script:SkipValues = @(
        @{ Label = '$true'; Value = $true }
        @{ Label = 'the number 1'; Value = 1 }
        @{ Label = 'the number 0'; Value = 0 }
        @{ Label = 'the text false'; Value = 'false' }
        @{ Label = 'an empty text'; Value = '' }
        @{ Label = 'the text yes'; Value = 'yes' }
        @{ Label = '$null'; Value = $null }
    )
    # Tool, query, mutation, description (the table of the tools).
    $script:Tools = @(
        @{ Tool = 'npm'; Query = 'config get cache'; Mutation = 'cache clean --force'; Description = 'npm cache' }
        @{ Tool = 'pnpm'; Query = 'store path'; Mutation = 'store prune'; Description = 'pnpm store' }
        @{ Tool = 'pip'; Query = 'cache dir'; Mutation = 'cache purge'; Description = 'pip cache' }
        @{ Tool = 'go'; Query = 'env GOCACHE'; Mutation = 'clean -cache'; Description = 'Go build cache' }
        @{ Tool = 'mise'; Query = 'cache path'; Mutation = 'cache clear'; Description = 'mise cache' }
    )
    # Folders that the never-list covers (relative to the profile, roaming or local folder): equal, below or above.
    $script:NeverCases = @(
        @{ Label = '.m2 below'; Base = 'Profile'; Rest = @('.m2', 'repository') }
        @{ Label = '.m2 itself'; Base = 'Profile'; Rest = @('.m2') }
        @{ Label = '.gradle itself'; Base = 'Profile'; Rest = @('.gradle') }
        @{ Label = '.gradle caches'; Base = 'Profile'; Rest = @('.gradle', 'caches') }
        @{ Label = '.nuget below'; Base = 'Profile'; Rest = @('.nuget', 'packages') }
        @{ Label = '.cargo below'; Base = 'Profile'; Rest = @('.cargo', 'registry') }
        @{ Label = '.rustup below'; Base = 'Profile'; Rest = @('.rustup', 'toolchains') }
        @{ Label = '.cabal below'; Base = 'Profile'; Rest = @('.cabal', 'store') }
        @{ Label = '.stack programs'; Base = 'Profile'; Rest = @('.stack', 'programs') }
        @{ Label = '.stack above programs'; Base = 'Profile'; Rest = @('.stack') }
        @{ Label = '.hex packages'; Base = 'Profile'; Rest = @('.hex', 'packages') }
        @{ Label = '.hex above packages'; Base = 'Profile'; Rest = @('.hex') }
        @{ Label = '.mix below'; Base = 'Profile'; Rest = @('.mix', 'archives') }
        @{ Label = '.aws below'; Base = 'Profile'; Rest = @('.aws', 'cli') }
        @{ Label = '.azure below'; Base = 'Profile'; Rest = @('.azure', 'x') }
        @{ Label = '.kube below'; Base = 'Profile'; Rest = @('.kube', 'cache') }
        @{ Label = '.docker below'; Base = 'Profile'; Rest = @('.docker', 'x') }
        @{ Label = '.ssh below'; Base = 'Profile'; Rest = @('.ssh', 'x') }
        @{ Label = '.claude below'; Base = 'Profile'; Rest = @('.claude', 'x') }
        @{ Label = '.codex below'; Base = 'Profile'; Rest = @('.codex', 'x') }
        @{ Label = 'npm roaming below'; Base = 'Roam'; Rest = @('npm', 'node_modules') }
        @{ Label = 'Docker roaming below'; Base = 'Roam'; Rest = @('Docker', 'x') }
        @{ Label = 'Docker local below'; Base = 'Local'; Rest = @('Docker', 'x') }
        @{ Label = 'Code User below'; Base = 'Roam'; Rest = @('Code', 'User', 'History') }
        @{ Label = 'Code above User'; Base = 'Roam'; Rest = @('Code') }
        @{ Label = 'Code workspaceStorage below'; Base = 'Roam'; Rest = @('Code', 'workspaceStorage', 'w') }
        @{ Label = 'JetBrains local below'; Base = 'Local'; Rest = @('JetBrains', 'IntelliJ') }
        @{ Label = 'JetBrains roaming below'; Base = 'Roam'; Rest = @('JetBrains', 'IntelliJ') }
        @{ Label = 'Poetry virtualenvs below'; Base = 'Local'; Rest = @('pypoetry', 'Cache', 'virtualenvs', 'project') }
        @{ Label = 'Poetry above virtualenvs'; Base = 'Local'; Rest = @('pypoetry', 'Cache') }
        @{ Label = 'Adobe Team Projects below'; Base = 'Roam'; Rest = @('Adobe', 'Common', 'Team Projects Cache', 'p') }
        @{ Label = 'Adobe above Team Projects'; Base = 'Roam'; Rest = @('Adobe', 'Common') }
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

    # ---- identity: a fake for Get-SwPathSnapshot and Test-SwPathSnapshot (Linux has none, file-ops F-8) --

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
            $script:ScanCalls.Add([pscustomobject]@{ Root = $Root; Filter = $Filter; Extensions = @($Extensions); OlderThan = $OlderThan; NoRecurse = [bool]$NoRecurse; TimeoutSeconds = $TimeoutSeconds; HasTimeout = $PesterBoundParameters.ContainsKey('TimeoutSeconds'); HasOlderThan = $PesterBoundParameters.ContainsKey('OlderThan') })
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

    # The tool table as the groups give it to the owner path.
    function script:Get-ToolArgs([string]$Tool) {
        $row = $script:ToolTable[$Tool]
        @{ Name = $Tool; Query = @($row.Query -split ' '); Arguments = @($row.Mutation -split ' '); Description = $row.Description }
    }
    $script:ToolTable = @{
        npm  = @{ Query = 'config get cache'; Mutation = 'cache clean --force'; Description = 'npm cache' }
        pnpm = @{ Query = 'store path'; Mutation = 'store prune'; Description = 'pnpm store' }
        pip  = @{ Query = 'cache dir'; Mutation = 'cache purge'; Description = 'pip cache' }
        go   = @{ Query = 'env GOCACHE'; Mutation = 'clean -cache'; Description = 'Go build cache' }
        mise = @{ Query = 'cache path'; Mutation = 'cache clear'; Description = 'mise cache' }
    }
    function script:Invoke-ToolCleanup([string]$Tool) {
        $arguments = Get-ToolArgs $Tool
        Invoke-SwOwnerCacheCleanup -Name $arguments.Name -Query $arguments.Query -Arguments $arguments.Arguments -Description $arguments.Description
    }
    # A preview run of one tool over one answer; true when the folder was accepted (counted, listed, no command).
    function script:Test-Accepted([string]$Tool, [string]$Answer) {
        $script:OwnerCleanups = 0
        $script:SweeprDryRunMode = $true
        $script:QueryAnswers = @($Answer)
        Invoke-ToolCleanup $Tool
        [int]$script:OwnerCleanups -eq 1
    }
    function script:Get-BaseFolder([string]$Base) {
        switch ($Base) { 'Profile' { $script:Profile } 'Roam' { $script:Roam } 'Local' { $script:Local } }
    }
}

AfterAll {
    Clear-TestLinks
    Restore-Env $script:RootEnv
    Restore-State $script:RootState
    [System.Environment]::CurrentDirectory = $script:RootDirectory
    try { Set-Location -LiteralPath $script:RootLocation } catch { $null = $_ }
}
Describe 'CD-11 Get-SwOwnerCachePath with the switch SweeprSkipExternalTools' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -RealSections -RealNotMeasured -ProcessNetOnly
        Use-Collectors
        Start-SwSection 'Developer tools'
    }
    AfterEach { Stop-Case }

    It 'CD-11 starts no command and no process, gives $null and notes the tool as "external tool" when the switch is <Label>' -ForEach $script:SkipValues {
        $script:SweeprSkipExternalTools = $Value
        $result = Get-SwOwnerCachePath -Name 'npm' -Arguments @('config', 'get', 'cache')
        $null -eq $result | Should -BeTrue
        Should -Invoke Invoke-SwOwnerCommand -Times 0 -Exactly
        Should -Invoke New-SwOwnerProcess -Times 0 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly
        $notes = @($script:NotMeasuredCollector)
        $notes.Count | Should -Be 1
        $notes[0].Name | Should -Be 'npm'
        $notes[0].Reason | Should -Be 'external tool'
        $notes[0].Section | Should -Be 'Developer tools'
    }

    It 'CD-11 skips in a real run and in a preview alike' {
        foreach ($dry in $true, $false) {
            $script:NotMeasuredCollector.Clear()
            $script:SweeprDryRunMode = $dry
            $script:SweeprSkipExternalTools = $true
            $null = Get-SwOwnerCachePath -Name 'go' -Arguments @('env', 'GOCACHE')
            Should -Invoke Invoke-SwOwnerCommand -Times 0 -Exactly
            @($script:NotMeasuredCollector).Count | Should -Be 1
        }
    }

    It 'CD-11 notes a tool once even when it is asked twice (the collector removes the repeat)' {
        $script:SweeprSkipExternalTools = $true
        $null = Get-SwOwnerCachePath -Name 'npm' -Arguments @('config', 'get', 'cache')
        $null = Get-SwOwnerCachePath -Name 'npm' -Arguments @('config', 'get', 'cache')
        @($script:NotMeasuredCollector | Where-Object { $_.Name -eq 'npm' }).Count | Should -Be 1
    }

    It 'CD-11 runs the query when the switch is exactly $false' {
        $script:SweeprSkipExternalTools = $false
        $null = Get-SwOwnerCachePath -Name 'npm' -Arguments @('config', 'get', 'cache')
        Should -Invoke Invoke-SwOwnerCommand -Times 1 -Exactly
        @($script:NotMeasuredCollector).Count | Should -Be 0
    }

    It 'CD-11 runs the query when the variable does not exist, and a read under strict mode does not fail' {
        Remove-Variable -Name SweeprSkipExternalTools -Scope Script -ErrorAction SilentlyContinue
        { $null = Get-SwOwnerCachePath -Name 'npm' -Arguments @('config', 'get', 'cache') } | Should -Not -Throw
        Should -Invoke Invoke-SwOwnerCommand -Times 1 -Exactly
    }

    It 'CD-11 reads the switch at every call: a change between two calls is seen' {
        $script:SweeprSkipExternalTools = $false
        $null = Get-SwOwnerCachePath -Name 'npm' -Arguments @('x')
        $script:SweeprSkipExternalTools = $true
        $null = Get-SwOwnerCachePath -Name 'go' -Arguments @('x')
        Should -Invoke Invoke-SwOwnerCommand -Times 1 -Exactly
    }

    It 'CD-11 leaves the rows without a tool alone when the tools are skipped: Yarn and Bun still go to the sink, npm, pnpm and go are noted once each' {
        Use-HelperSpies
        $script:SweeprSkipExternalTools = $true
        Clear-SwNpmFamilyCaches
        Clear-SwGoCaches
        Should -Invoke Invoke-SwOwnerCommand -Times 0 -Exactly
        Should -Invoke New-SwOwnerProcess -Times 0 -Exactly
        @(Get-Calls 'Clear-SwDirectoryContents' | ForEach-Object { $_.Description }) | Should -Be @('Yarn cache', 'Bun cache')
        $notes = @($script:NotMeasuredCollector)
        @($notes | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('go', 'npm', 'pnpm')
        foreach ($note in $notes) {
            $note.Reason | Should -Be 'external tool'
            $note.Section | Should -Be 'Developer tools'
        }
    }

    It 'CD-11 CD-21 notes all five tools when the whole section runs with the tools skipped, and starts nothing' {
        $script:SweeprSkipExternalTools = $true
        Invoke-SwDevCleanup
        Should -Invoke Invoke-SwOwnerCommand -Times 0 -Exactly
        Should -Invoke New-SwOwnerProcess -Times 0 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly
        @($script:NotMeasuredCollector | Where-Object { $_.Reason -eq 'external tool' } | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('go', 'mise', 'npm', 'pip', 'pnpm')
    }

    It 'CD-11 keeps "external tool" for the skip alone: a missing tool or an empty query answer notes nothing' {
        $script:SweeprSkipExternalTools = $false
        Mock Invoke-SwOwnerCommand { $null }
        $null = Get-SwOwnerCachePath -Name 'npm' -Arguments @('config', 'get', 'cache')
        @($script:NotMeasuredCollector).Count | Should -Be 0
    }
}

Describe 'CD-11 Get-SwOwnerCachePath: the query and the form of its answer' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -ProcessNetOnly
        $script:QueryText = $null
        $script:Queries = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-SwOwnerCommand {
            $script:Queries.Add([pscustomobject]@{ Name = $Name; Arguments = @($Arguments); Mutation = [bool]$Mutation; HasTimeout = $PesterBoundParameters.ContainsKey('TimeoutSeconds'); HasOutcome = $PesterBoundParameters.ContainsKey('Outcome') })
            if ($null -eq $script:QueryText) { return $null }
            [pscustomobject]@{ Output = [string]$script:QueryText }
        }
    }
    AfterEach { Stop-Case }

    It 'CD-11 asks Invoke-SwOwnerCommand once with the tool name and the query arguments, with the standard limit and without -Mutation' {
        $script:QueryText = P $script:Work 'npm-cache'
        $null = Get-SwOwnerCachePath -Name 'npm' -Arguments @('config', 'get', 'cache')
        $script:Queries.Count | Should -Be 1
        $script:Queries[0].Name | Should -Be 'npm'
        ($script:Queries[0].Arguments -join ' ') | Should -Be 'config get cache'
        $script:Queries[0].Mutation | Should -BeFalse
        $script:Queries[0].HasTimeout | Should -BeFalse -Because 'the standard limit of 5 seconds applies'
    }

    It 'CD-11 gives the folder as one string that equals the answer of the query' {
        $folder = P $script:Work 'npm-cache'
        $script:QueryText = $folder
        $result = @(Get-SwOwnerCachePath -Name 'npm' -Arguments @('config', 'get', 'cache'))
        $result.Count | Should -Be 1
        $result[0] | Should -BeOfType [string]
        $result[0] | Should -BeExactly $folder
    }

    It 'CD-11 trims blanks and a line break around the answer and gives the trimmed text' {
        $folder = P $script:Work 'npm-cache'
        $script:QueryText = '  ' + $folder + "  `n"
        (Get-SwOwnerCachePath -Name 'npm' -Arguments @('x')) | Should -BeExactly $folder
    }

    It 'CD-11 gives $null, one debug line, no log line, no count and no note for an answer that is <Label>' -ForEach $script:BadOutputs {
        $script:QueryText = $Text
        $result = Get-SwOwnerCachePath -Name 'npm' -Arguments @('x')
        $null -eq $result | Should -BeTrue
        @(Get-LogLines 'DEBUG').Count | Should -BeGreaterThan 0
        $script:Ops.Count | Should -Be 0
        [int]$script:OwnerCleanups | Should -Be 0
        $script:NotMeasured.Count | Should -Be 0
        $script:Calls.Count | Should -Be 0
    }

    It 'CD-11 gives $null when the command gives nothing, an object without Output, or throws' {
        $script:QueryText = $null
        $null -eq (Get-SwOwnerCachePath -Name 'npm' -Arguments @('x')) | Should -BeTrue
        Mock Invoke-SwOwnerCommand { [pscustomobject]@{ Other = 'x' } }
        { $script:R = Get-SwOwnerCachePath -Name 'npm' -Arguments @('x') } | Should -Not -Throw
        $null -eq $script:R | Should -BeTrue
        Mock Invoke-SwOwnerCommand { throw 'the command failed' }
        { $script:R = Get-SwOwnerCachePath -Name 'npm' -Arguments @('x') } | Should -Not -Throw
        $null -eq $script:R | Should -BeTrue
        @(Get-LogLines 'DEBUG').Count | Should -BeGreaterThan 0
    }

    It 'CD-6 CD-11 runs the query in a preview, because a query only reads' {
        $script:SweeprDryRunMode = $true
        $script:QueryText = P $script:Work 'npm-cache'
        $null -ne (Get-SwOwnerCachePath -Name 'npm' -Arguments @('config', 'get', 'cache')) | Should -BeTrue
        $script:Queries.Count | Should -Be 1
    }

    It 'CD-11 CD-4 writes nothing to the pipeline besides the answer, also for a failed query' {
        $script:QueryText = $null
        $failed = Invoke-Captured { Get-SwOwnerCachePath -Name 'npm' -Arguments @('x') }
        @($failed | Where-Object { $null -ne $_ }).Count | Should -Be 0
        $script:QueryText = P $script:Work 'npm-cache'
        $found = Invoke-Captured { Get-SwOwnerCachePath -Name 'npm' -Arguments @('x') }
        @($found | Where-Object { $null -ne $_ }).Count | Should -Be 1
    }

    It 'CD-11 gives the same answer under Stop, Continue and SilentlyContinue' {
        $folder = P $script:Work 'npm-cache'
        $script:QueryText = $folder
        foreach ($preference in 'Stop', 'Continue', 'SilentlyContinue') {
            $ErrorActionPreference = $preference
            (Get-SwOwnerCachePath -Name 'npm' -Arguments @('x')) | Should -BeExactly $folder
        }
        $ErrorActionPreference = 'Stop'
    }

    It 'CD-11 gives the parameters Name (string) and Arguments (string[]) and no more' {
        (Get-ParamLine 'Get-SwOwnerCachePath' 'Name') | Should -BeLike 'Name|System.String|*'
        (Get-ParamLine 'Get-SwOwnerCachePath' 'Arguments') | Should -BeLike 'Arguments|System.String`[`]|*'
        (Get-ParamCount 'Get-SwOwnerCachePath') | Should -Be 2
    }
}

Describe 'CD-13 CD-14 the folder must be plausible, carry the characteristic of its tool and stay out of the never-list' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -NoNet
        Use-OwnerRun
        $script:SweeprDryRunMode = $true
        $script:Cache = New-NpmCache (P $script:Work 'npm-cache')
    }
    AfterEach { Stop-Case }

    It 'CD-13 accepts a folder with the folder _cacache for npm: the preview counts it' {
        (Test-Accepted 'npm' $script:Cache) | Should -BeTrue
    }

    It 'CD-14 asks first and gives up silently, without note, when the answer is $null or empty: <Answer>' -ForEach @(@{ Answer = $null }, @{ Answer = '' }) {
        $script:QueryAnswers = @($Answer)
        Invoke-NpmCleanup
        [int]$script:OwnerCleanups | Should -Be 0
        $script:NotMeasured.Count | Should -Be 0
        @(Get-Mutations).Count | Should -Be 0
        $script:Calls.Count | Should -Be 0
        $script:TreeCalls | Should -Be 0
    }

    It 'CD-13 refuses the root of a drive: no command, no count, no removal, "not verified" for npm' {
        $script:QueryAnswers = @([System.IO.Path]::GetPathRoot($script:Work))
        $script:SweeprDryRunMode = $false
        Invoke-NpmCleanup
        @(Get-Mutations).Count | Should -Be 0
        [int]$script:OwnerCleanups | Should -Be 0
        $script:Calls.Count | Should -Be 0
        $script:Ops.Count | Should -Be 0
        $note = Get-NpmNotMeasured
        $note.Count | Should -Be 1
        $note[0].Reason | Should -Be 'not verified'
    }

    It 'CD-13 refuses a folder that resolves to the root of a drive' {
        $root = [System.IO.Path]::GetPathRoot($script:Work)
        $script:QueryAnswers = @($root)
        Invoke-NpmCleanup
        [int]$script:OwnerCleanups | Should -Be 0
    }

    It 'CD-13 refuses USERPROFILE, APPDATA and LOCALAPPDATA themselves, with the characteristic present: <Name>' -ForEach @(
        @{ Name = 'USERPROFILE'; Folder = 'Profile' }, @{ Name = 'APPDATA'; Folder = 'Roam' }, @{ Name = 'LOCALAPPDATA'; Folder = 'Local' }) {
        $folder = Get-BaseFolder $Folder
        $null = New-File (P $folder '_cacache' 'x.bin') 3
        $script:QueryAnswers = @($folder)
        Invoke-NpmCleanup
        [int]$script:OwnerCleanups | Should -Be 0
        @(Get-Mutations).Count | Should -Be 0
        (Get-NpmNotMeasured)[0].Reason | Should -Be 'not verified'
    }

    It 'CD-13 refuses an ancestor of USERPROFILE: the work folder and the test drive' {
        foreach ($folder in $script:Work, $TestDrive) {
            $null = New-File (P $folder '_cacache' 'x.bin') 3
            $script:OwnerCleanups = 0
            $script:QueryAnswers = @($folder)
            Invoke-NpmCleanup
            [int]$script:OwnerCleanups | Should -Be 0 -Because $folder
        }
        @(Get-Mutations).Count | Should -Be 0
    }

    It 'CD-13 [W] refuses the known folders of the account: Desktop, Documents, Pictures, Music and Videos' -ForEach @(
        @{ Folder = 'Desktop' }, @{ Folder = 'MyDocuments' }, @{ Folder = 'MyPictures' }, @{ Folder = 'MyMusic' }, @{ Folder = 'MyVideos' }) {
        $path = [Environment]::GetFolderPath($Folder)
        [string]::IsNullOrEmpty($path) | Should -BeFalse -Because 'the account has this known folder on Windows'
        $script:OwnerCleanups = 0
        $script:QueryAnswers = @($path)
        Invoke-NpmCleanup
        [int]$script:OwnerCleanups | Should -Be 0
        @(Get-Mutations).Count | Should -Be 0
    }

    It 'CD-13 refuses an ancestor of a known folder of the account [W]' {
        $documents = [Environment]::GetFolderPath('MyDocuments')
        [string]::IsNullOrEmpty($documents) | Should -BeFalse
        $parent = [System.IO.Path]::GetDirectoryName($documents)
        $script:QueryAnswers = @($parent)
        Invoke-NpmCleanup
        [int]$script:OwnerCleanups | Should -Be 0
    }

    It 'CD-13 CD-14 npm: a folder without _cacache but with other files is refused, "not verified"' {
        $other = New-PlainCache (P $script:Work 'other-cache')
        $script:QueryAnswers = @($other)
        Invoke-NpmCleanup
        [int]$script:OwnerCleanups | Should -Be 0
        (Get-NpmNotMeasured)[0].Reason | Should -Be 'not verified'
        $script:TreeCalls | Should -BeLessOrEqual 0 -Because 'the characteristic is read before the tree is'
    }

    It 'CD-13 pnpm: a folder whose leaf is v and digits is accepted (<Leaf>), the folder above it is not' -ForEach @(
        @{ Leaf = 'v3' }, @{ Leaf = 'v10' }) {
        $store = P $script:Work 'pnpm' 'store'
        $v = New-PlainCache (P $store $Leaf)
        (Test-Accepted 'pnpm' $v) | Should -BeTrue
        (Test-Accepted 'pnpm' $store) | Should -BeFalse
        (@(Get-NotMeasuredFor 'pnpm') | Where-Object { $_.Reason -eq 'not verified' }).Count | Should -Be 1
    }

    It 'CD-13 pnpm: a leaf that is only v or v followed by a letter is refused' -ForEach @(@{ Leaf = 'v' }, @{ Leaf = 'vx' }, @{ Leaf = 'v3x' }, @{ Leaf = 'store' }) {
        $folder = New-PlainCache (P $script:Work 'pnpm' $Leaf)
        (Test-Accepted 'pnpm' $folder) | Should -BeFalse
    }

    It 'CD-13 pip: a folder with http or wheels in it is accepted, one with other entries only is not' {
        $withHttp = P $script:Work 'pip-http'
        $null = New-File (P $withHttp 'http' 'x.bin') 100
        $withWheels = P $script:Work 'pip-wheels'
        $null = New-File (P $withWheels 'wheels' 'x.whl') 100
        $other = New-PlainCache (P $script:Work 'pip-other')
        (Test-Accepted 'pip' $withHttp) | Should -BeTrue
        (Test-Accepted 'pip' $withWheels) | Should -BeTrue
        (Test-Accepted 'pip' $other) | Should -BeFalse
    }

    It 'CD-13 go: a folder with the file README is accepted, one without it is not' {
        $withReadme = P $script:Work 'go-build'
        $null = New-File (P $withReadme 'README') 10
        $null = New-File (P $withReadme '01' 'x') 10
        $other = New-PlainCache (P $script:Work 'go-other')
        (Test-Accepted 'go' $withReadme) | Should -BeTrue
        (Test-Accepted 'go' $other) | Should -BeFalse
    }

    It 'CD-13 mise: a folder below LOCALAPPDATA is accepted, one elsewhere with content is not' {
        $inside = New-PlainCache (P $script:Local 'mise')
        $outside = New-PlainCache (P $script:Work 'mise-out')
        (Test-Accepted 'mise' $inside) | Should -BeTrue
        (Test-Accepted 'mise' $outside) | Should -BeFalse
    }

    It 'CD-13 CD-30 refuses a folder that is equal to, below or above a never-list path: <Label>' -ForEach $script:NeverCases {
        $folder = Get-BaseFolder $Base
        foreach ($segment in @($Rest)) { $folder = P $folder $segment }
        $null = New-File (P $folder '_cacache' 'x.bin') 10
        (Test-Accepted 'npm' $folder) | Should -BeFalse
        (Get-NpmNotMeasured)[0].Reason | Should -Be 'not verified'
        @(Get-Mutations).Count | Should -Be 0
    }

    It 'CD-30 does not refuse a sibling whose name only starts like a never-list entry: .m2-copy and .gradle2 are plain folders' {
        foreach ($name in '.m2-copy', '.gradle2', '.cargo-old') {
            $folder = P $script:Profile $name 'cache'
            $null = New-File (P $folder '_cacache' 'x.bin') 10
            (Test-Accepted 'npm' $folder) | Should -BeTrue -Because $name
        }
    }

    It 'CD-14 refuses a folder that the whitelist keeps, and one with a whitelisted descendant: "not verified", no command' {
        Set-Whitelist @($script:Cache)
        (Test-Accepted 'npm' $script:Cache) | Should -BeFalse
        (Get-NpmNotMeasured)[0].Reason | Should -Be 'not verified'
        Set-Whitelist @((P $script:Cache 'kept.bin'))
        $script:NotMeasured.Clear()
        (Test-Accepted 'npm' $script:Cache) | Should -BeFalse
        (Get-NpmNotMeasured)[0].Reason | Should -Be 'not verified'
        @(Get-Mutations).Count | Should -Be 0
    }

    It 'CD-14 refuses a folder without a file identity' {
        $script:FakeNoIdentity.Add($script:Cache)
        (Test-Accepted 'npm' $script:Cache) | Should -BeFalse
        (Get-NpmNotMeasured)[0].Reason | Should -Be 'not verified'
    }

    It 'CD-14 refuses a folder that is a link' {
        $link = P $script:Work 'npm-link'
        if (-not (New-TestLink $link $script:Cache)) { Set-ItResult -Skipped -Because 'this host cannot create a link here'; return }
        (Test-Accepted 'npm' $link) | Should -BeFalse
    }

    It 'CD-14 refuses a folder with a link inside: nothing is started and "not verified" is noted' {
        $target = New-Dir (P $script:Work 'elsewhere')
        if (-not (New-TestLink (P $script:Cache 'inner-link') $target)) { Set-ItResult -Skipped -Because 'this host cannot create a link here'; return }
        (Test-Accepted 'npm' $script:Cache) | Should -BeFalse
        (Get-NpmNotMeasured)[0].Reason | Should -Be 'not verified'
    }

    It 'CD-14 refuses a folder whose tree cannot be listed completely: Success $false' {
        Mock Get-SwSafeDirectoryTreeItems { @{ Success = $false; Items = @(); RootSnapshot = $null; Reason = 'cannot list' } }
        (Test-Accepted 'npm' $script:Cache) | Should -BeFalse
        (Get-NpmNotMeasured)[0].Reason | Should -Be 'not verified'
    }

    It 'CD-14 refuses a folder whose identity changed while the tree was read' {
        Mock Get-SwSafeDirectoryTreeItems {
            $tree = & $script:RealTree -Path $Path -WhitelistState $WhitelistState
            $script:FakeReplaced.Add($Path)
            $tree
        }
        (Test-Accepted 'npm' $script:Cache) | Should -BeFalse
        (Get-NpmNotMeasured)[0].Reason | Should -Be 'not verified'
    }

    It 'CD-14 N-4 refuses when one item has no Attributes, or has the reparse point attribute: such an item counts as a link' {
        $item = P $script:Cache 'kept.bin'
        Use-FixedTree @((New-TreeItem $item @{ Attributes = $true }))
        (Test-Accepted 'npm' $script:Cache) | Should -BeFalse -Because 'no Attributes'
        Use-FixedTree @((New-TreeItem $item @{}), (New-TreeItem (P $script:Cache '_cacache' 'gone.bin') @{}))
        $script:FixedItems[1].Attributes = [System.IO.FileAttributes]::ReparsePoint
        (Test-Accepted 'npm' $script:Cache) | Should -BeFalse -Because 'reparse point'
        (Get-NpmNotMeasured)[0].Reason | Should -Be 'not verified'
    }

    It 'CD-14 N-4 refuses when one item has no FullName or no SweeprPathSnapshot' {
        $item = P $script:Cache 'kept.bin'
        Use-FixedTree @((New-TreeItem $item @{ FullName = $true }))
        (Test-Accepted 'npm' $script:Cache) | Should -BeFalse -Because 'no FullName'
        Use-FixedTree @((New-TreeItem $item @{ SweeprPathSnapshot = $true }))
        (Test-Accepted 'npm' $script:Cache) | Should -BeFalse -Because 'no snapshot'
    }

    It 'CD-14 N-4 accepts an item without Length (counts 0) or without PSIsContainer (counts as a file), and does not throw' {
        $item = P $script:Cache 'kept.bin'
        Use-FixedTree @((New-TreeItem $item @{ Length = $true }))
        { $null = Test-Accepted 'npm' $script:Cache } | Should -Not -Throw
        (Test-Accepted 'npm' $script:Cache) | Should -BeTrue -Because 'no Length'
        Use-FixedTree @((New-TreeItem $item @{ PSIsContainer = $true }))
        (Test-Accepted 'npm' $script:Cache) | Should -BeTrue -Because 'no PSIsContainer'
    }

    It 'CD-14 ends silently when the tree holds no file: an empty folder, and one with only folders, are not counted or listed' {
        $empty = New-Dir (P $script:Work 'npm-empty')
        $onlyFolders = New-Dir (P $script:Work 'npm-folders' '_cacache' 'inner')
        Use-Collectors
        foreach ($folder in $empty, (P $script:Work 'npm-folders')) {
            $script:QueryAnswers = @($folder)
            Invoke-NpmCleanup
        }
        [int]$script:OwnerCleanups | Should -Be 0
        $script:DryRunCollector.Count | Should -Be 0
        @(Get-Mutations).Count | Should -Be 0
        $script:Ops.Count | Should -Be 0
    }

    It 'CD-5 CD-18 never falls back to direct removal: no sink is called for a refused folder, in a real run either' {
        $script:SweeprDryRunMode = $false
        $script:QueryAnswers = @([System.IO.Path]::GetPathRoot($script:Work))
        Invoke-NpmCleanup
        Set-Whitelist @($script:Cache)
        $script:QueryAnswers = @($script:Cache)
        Invoke-NpmCleanup
        $script:Calls.Count | Should -Be 0
        @(Get-Mutations).Count | Should -Be 0
        [System.IO.File]::Exists((P $script:Cache '_cacache' 'gone.bin')) | Should -BeTrue
    }
}

Describe 'CD-7 one offer per place in a section run' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -NoNet
        Use-OwnerRun
        $script:SweeprDryRunMode = $false
        $script:Cache = New-NpmCache (P $script:Work 'store' 'v3')
        $null = New-File (P $script:Work 'store' 'v3' 'extra.bin') 100
    }
    AfterEach { Stop-Case }

    It 'CD-7 runs only the command of npm when npm and pnpm give the same folder, and notes nothing for pnpm' {
        $script:QueryByName['npm'] = $script:Cache
        $script:QueryByName['pnpm'] = $script:Cache
        Clear-SwNpmFamilyCaches
        @(Get-Mutations | ForEach-Object { $_.Name }) | Should -Be @('npm')
        @(Get-NotMeasuredFor 'pnpm').Count | Should -Be 0
        [int]$script:OwnerCleanups | Should -Be 1
    }

    It 'CD-7 skips a second tool whose folder lies below the folder that was already offered' {
        $outer = Split-Path -Parent $script:Cache
        $null = New-Dir (P $outer '_cacache')
        $null = New-File (P $outer '_cacache' 'o.bin') 100
        $script:QueryByName['npm'] = $outer
        $script:QueryByName['pnpm'] = $script:Cache
        Clear-SwNpmFamilyCaches
        @(Get-Mutations | ForEach-Object { $_.Name }) | Should -Be @('npm')
    }

    It 'CD-7 compares without regard to case and without a closing separator' {
        $script:QueryByName['npm'] = $script:Cache
        $script:QueryByName['pnpm'] = $script:Cache.ToUpperInvariant() + $script:Sep
        Clear-SwNpmFamilyCaches
        @(Get-Mutations | ForEach-Object { $_.Name }) | Should -Be @('npm')
    }

    It 'CD-7 runs both commands when the two folders are different places' {
        $second = P $script:Work 'pnpm' 'store' 'v3'
        $null = New-File (P $second 'a.bin') 100
        $script:QueryByName['npm'] = $script:Cache
        $script:QueryByName['pnpm'] = $second
        Clear-SwNpmFamilyCaches
        @(Get-Mutations | ForEach-Object { $_.Name }) | Should -Be @('npm', 'pnpm')
    }

    It 'CD-7 starts the set again with every call of a group that is called alone: two calls run npm twice' {
        $script:QueryByName['npm'] = $script:Cache
        Clear-SwNpmFamilyCaches
        $null = New-File (P $script:Cache '_cacache' 'gone.bin') 4096
        Clear-SwNpmFamilyCaches
        @(Get-Mutations | ForEach-Object { $_.Name }).Count | Should -Be 2
    }

    It 'CD-7 holds the set for the whole section: npm and go with the same folder start one command in Invoke-SwDevCleanup' {
        $null = New-File (P $script:Cache 'README') 10
        $script:QueryByName['npm'] = $script:Cache
        $script:QueryByName['go'] = $script:Cache
        Invoke-SwDevCleanup
        @(Get-Mutations | ForEach-Object { $_.Name }) | Should -Be @('npm')
    }
}

Describe 'CD-10 CD-21 the five tools and nothing else' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -ProcessNetOnly
        Mock Invoke-SwOwnerCommand {
            $script:Seen.Add([pscustomobject]@{ Name = $Name; Arguments = @($Arguments); Mutation = [bool]$Mutation; HasTimeout = $PesterBoundParameters.ContainsKey('TimeoutSeconds') })
            $null
        }
        $script:Seen = [System.Collections.Generic.List[object]]::new()
    }
    AfterEach { Stop-Case }

    It 'CD-10 CD-21 asks the five tools with the queries of the table, in order, once each, and starts nothing else, also in a real run' {
        foreach ($dry in $true, $false) {
            $script:Seen.Clear()
            $script:SweeprDryRunMode = $dry
            Invoke-SwDevCleanup
            @($script:Seen | ForEach-Object { $_.Name + ':' + ($_.Arguments -join ' ') }) | Should -Be @(
                'npm:config get cache', 'pnpm:store path', 'pip:cache dir', 'go:env GOCACHE', 'mise:cache path')
            foreach ($call in $script:Seen) {
                $call.Mutation | Should -BeFalse
                $call.HasTimeout | Should -BeFalse
            }
            Should -Invoke New-SwOwnerProcess -Times 0 -Exactly
            Should -Invoke Start-Process -Times 0 -Exactly
        }
    }

    It 'CD-21 never asks docker, yarn, bun, cargo, conda, gcloud, terraform, git or gh' {
        Invoke-SwDevCleanup
        foreach ($forbidden in 'docker', 'yarn', 'bun', 'cargo', 'conda', 'gcloud', 'terraform', 'git', 'gh', 'go mod') {
            @($script:Seen | Where-Object { $_.Name -eq $forbidden }).Count | Should -Be 0 -Because $forbidden
        }
    }

    It 'CD-10 asks go only for GOCACHE: there is no second query for the module cache' {
        Clear-SwGoCaches
        @($script:Seen | ForEach-Object { $_.Arguments -join ' ' }) | Should -Be @('env GOCACHE')
    }

    It 'CD-10 gives each tool its mutation and its limit of 120 seconds: <Tool> runs <Mutation>' -ForEach $script:Tools {
        $answer = P $script:Work ($Tool + '-cache')
        if ($Tool -eq 'npm') { $null = New-File (P $answer '_cacache' 'a.bin') 100 }
        if ($Tool -eq 'pnpm') { $answer = P $script:Work 'pnpm' 'v3'; $null = New-File (P $answer 'a.bin') 100 }
        if ($Tool -eq 'pip') { $null = New-File (P $answer 'http' 'a.bin') 100 }
        if ($Tool -eq 'go') { $null = New-File (P $answer 'README') 100 }
        if ($Tool -eq 'mise') { $answer = P $script:Local 'mise'; $null = New-File (P $answer 'a.bin') 100 }
        $script:Answer = $answer
        Mock Get-SwOwnerCachePath { $script:Answer }
        $script:SweeprDryRunMode = $false
        $script:Mutations = [System.Collections.Generic.List[object]]::new()
        Mock Invoke-SwOwnerCommand {
            $script:Mutations.Add([pscustomobject]@{ Name = $Name; Arguments = @($Arguments); Mutation = [bool]$Mutation; TimeoutSeconds = $TimeoutSeconds })
            [pscustomobject]@{ Output = '' }
        }
        Invoke-ToolCleanup $Tool
        $script:Mutations.Count | Should -Be 1
        $script:Mutations[0].Name | Should -Be $Tool
        ($script:Mutations[0].Arguments -join ' ') | Should -Be $Mutation
        $script:Mutations[0].Mutation | Should -BeTrue
        $script:Mutations[0].TimeoutSeconds | Should -Be 120
    }
}
