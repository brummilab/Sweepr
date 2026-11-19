# Sweepr - tests for the process side of the owner paths in lib\clean\dev.ps1: Invoke-SwOwnerCommand (the only
# process start of these files: search for the program, one helper process with an encoded command, argument
# literals, time limits, the end of the process tree, the reasons) and New-SwOwnerProcess (the finished start
# information).
#
# The rule numbers in the test names (CD-, CA-, S- and so on) number the rules and the safety invariants
# of the behavior of the developer tool and application cleanup; each rule and invariant has at least one test.
# The other files of this slice are SwCleanDevGroups, SwCleanDevLoad, SwCleanDevScan, SwCleanDevOwnerPath,
# SwCleanDevOwnerRun, SwCleanDevEditors, SwCleanAppsGroups, SwCleanAppsMedia and SwCleanDevAppsSafety.
#
# Interface pinned here (lib\clean\dev.ps1):
#   Invoke-SwOwnerCommand -Name <string> -Arguments <string[]> [-TimeoutSeconds <int> = 5] [-Outcome <hashtable>] [-Mutation]
#       gives an object with Output (string, trimmed stdout) or $null; sets $Outcome['Reason'] (empty at the start); a
#       mutation in a preview or with $script:SweeprSkipExternalTools starts nothing ('mutation not allowed')
#   New-SwOwnerProcess -FilePath <string> -Arguments <string>
#       a System.Diagnostics.Process that is not started, with StartInfo set completely
#   Reasons: 'tool not found', 'host not found: <file>', 'mutation not allowed', 'start failed: <message>',
#   'timed out after <n> s', 'output not read', 'exit code <n>', 'process tree <id> terminated',
#   'taskkill unconfirmed: <code, timeout or message>' (joined with '; ')
#
# Seams used with Mock: New-SwOwnerProcess (a stand-in process with StartInfo, Id, HasExited, ExitCode, StandardInput,
# StandardOutput, StandardError with ReadToEndAsync, Start, WaitForExit, Kill and Dispose; the order of the calls is
# recorded), the log writers. Real helper processes run only for stand-in tools (.ps1 files below $TestDrive) and only
# in the cases that name it. Nothing but those stand-ins and the process of this PowerShell is started.
#
# Platform notes:
#   - The stand-in tool is a .ps1 file, which every host can run. Cases for .cmd and .exe programs, folders with
#     & and % in the name, PATHEXT, the real taskkill and the end of a real process tree are marked [W].
#   - [Environment]::SystemDirectory is empty on hosts that are not Windows; taskkill.exe is then only a name.
#   - Tests marked [W] need real Windows. They are meant to fail on Linux and belong in
#     tests/linux-known-failures.txt.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    # Arguments that must reach a tool unchanged. Each is a list; U+2018 to U+201B are typographic single quotes.
    $script:ArgumentSets = @(
        @{ Label = 'plain words'; Values = @('cache', 'clean', '--force') }
        @{ Label = 'a space'; Values = @('with space') }
        @{ Label = 'a semicolon'; Values = @('a;b') }
        @{ Label = 'double quotes'; Values = @('say "hi" there') }
        @{ Label = 'single quotes'; Values = @("it's") }
        @{ Label = 'a dollar sign and a subexpression'; Values = @('$env:PATH', '$(Get-Date)') }
        @{ Label = 'a backtick'; Values = @('a`b`n') }
        @{ Label = 'parentheses and braces'; Values = @('(a)', '{b}', '[c]') }
        @{ Label = 'an ampersand and a pipe'; Values = @('a & b', 'a | b', 'a > b') }
        @{ Label = 'a percent sign'; Values = @('%PATH%', '100%') }
        @{ Label = 'an empty argument'; Values = @('a', '', 'b') }
        @{ Label = 'the example of the rule'; Values = @('first', 'it''s "q" ; & calc') }
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

    # ---- a stand-in tool and a stand-in process ---------------------------------------------------

    $script:FixtureBody = @'
foreach ($argument in $args) { 'ARG:' + (($argument.ToCharArray() | ForEach-Object { [int]$_ }) -join ',') }
'COUNT:' + @($args).Count
'ENV:' + $env:GOTOOLCHAIN + '|' + $env:COREPACK_ENABLE_DOWNLOAD_PROMPT + '|' + $env:COREPACK_ENABLE_NETWORK + '|' + $env:NPM_CONFIG_UPDATE_NOTIFIER
'@
    # A folder on PATH with the stand-in tool owner-fixture.ps1; the body can be replaced.
    function script:New-ToolFolder([string]$Name = 'owner tools 1', [string]$Body = $script:FixtureBody, [string]$Tool = 'owner-fixture') {
        $folder = New-Dir (P $script:Work $Name)
        [System.IO.File]::WriteAllText((P $folder ($Tool + '.ps1')), $Body, $script:Utf8)
        $folder
    }
    function script:Get-CodePoints([string]$Text) { (($Text.ToCharArray() | ForEach-Object { [int]$_ }) -join ',') }

    # A process that is not started. Calls are recorded in $script:Events in order.
    function script:New-FakeProcess {
        param(
            [string]$Label = 'owner', [int]$Id = 42, [bool]$Waits = $true, [int]$ExitCode = 0, [string]$Out = '', [string]$Err = '',
            [bool]$OutReadable = $true, [bool]$ErrReadable = $true, [bool]$StartThrows = $false, [bool]$WaitThrows = $false, [bool]$ExitsWhenKillStarts = $false
        )
        $stdout = [pscustomobject]@{ Text = $Out; Readable = $OutReadable; Label = $Label; Kind = 'Out' }
        $stderr = [pscustomobject]@{ Text = $Err; Readable = $ErrReadable; Label = $Label; Kind = 'Err' }
        foreach ($stream in $stdout, $stderr) {
            Add-Member -InputObject $stream -MemberType ScriptMethod -Name ReadToEndAsync -Value {
                $script:Events.Add($this.Label + ':Read' + $this.Kind)
                $task = [pscustomobject]@{ Result = $this.Text; Readable = $this.Readable; Label = $this.Label; Kind = $this.Kind }
                Add-Member -InputObject $task -MemberType ScriptMethod -Name Wait -Value {
                    param($Milliseconds)
                    $script:ReadWaits.Add($Milliseconds)
                    [bool]$this.Readable
                }
                $task
            }
        }
        $stdin = [pscustomobject]@{ Label = $Label }
        Add-Member -InputObject $stdin -MemberType ScriptMethod -Name Close -Value { $script:Events.Add($this.Label + ':StdinClose') }
        $process = [pscustomobject]@{
            Label = $Label; Id = $Id; Waits = $Waits; Code = $ExitCode; StartThrows = $StartThrows; WaitThrows = $WaitThrows; ExitsWhenKillStarts = $ExitsWhenKillStarts
            StartInfo = [pscustomobject]@{ FileName = ''; Arguments = '' }; StandardInput = $stdin; StandardOutput = $stdout; StandardError = $stderr
            Started = $false; Killed = $false; Disposed = $false; WaitedMs = -1
        }
        Add-Member -InputObject $process -MemberType ScriptProperty -Name ExitCode -Value { $this.Code }
        Add-Member -InputObject $process -MemberType ScriptProperty -Name HasExited -Value { $this.Waits -or ($this.ExitsWhenKillStarts -and $script:KillStarted) }
        Add-Member -InputObject $process -MemberType ScriptMethod -Name Start -Value {
            $script:Events.Add($this.Label + ':Start')
            if ($this.Label -eq 'kill') { $script:KillStarted = $true }
            if ($this.StartThrows) { throw 'cannot start the process' }
            $this.Started = $true
            $true
        }
        Add-Member -InputObject $process -MemberType ScriptMethod -Name WaitForExit -Value {
            param($Milliseconds)
            $script:Events.Add($this.Label + ':Wait')
            $this.WaitedMs = $Milliseconds
            if ($this.WaitThrows) { throw 'the wait failed' }
            [bool]$this.Waits
        }
        Add-Member -InputObject $process -MemberType ScriptMethod -Name Kill -Value { $script:Events.Add($this.Label + ':Kill'); $this.Killed = $true }
        Add-Member -InputObject $process -MemberType ScriptMethod -Name Dispose -Value { $script:Events.Add($this.Label + ':Dispose'); $this.Disposed = $true }
        $process
    }
    # New-SwOwnerProcess gives the stand-ins one after the other; an empty queue throws like a process that cannot be made.
    function script:Use-FakeProcesses([object[]]$Processes) {
        $script:Events = [System.Collections.Generic.List[string]]::new()
        $script:ReadWaits = [System.Collections.Generic.List[int]]::new()
        $script:Created = [System.Collections.Generic.List[object]]::new()
        $script:Queue = [System.Collections.Generic.Queue[object]]::new()
        $script:KillStarted = $false
        foreach ($process in $Processes) { $script:Queue.Enqueue($process) }
        Mock New-SwOwnerProcess {
            $script:Created.Add([pscustomobject]@{ FilePath = $FilePath; Arguments = $Arguments })
            $next = $script:Queue.Dequeue()
            $next.StartInfo.FileName = $FilePath
            $next.StartInfo.Arguments = $Arguments
            $script:Events.Add($next.Label + ':Created')
            $next
        }
    }
    # The events of the four calls the order rule names.
    function script:Get-OrderEvents { @($script:Events | Where-Object { $_ -in @('owner:Start', 'kill:Start', 'owner:Dispose', 'kill:Dispose') }) }
    function script:Get-Encoded([string]$Arguments) {
        $match = [regex]::Match($Arguments, '-EncodedCommand (\S+)$')
        if (-not $match.Success) { return $null }
        [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($match.Groups[1].Value))
    }
    # A tool that exists as a file; the call uses its absolute path (the form that tests may use).
    function script:Get-ToolPath { P (New-ToolFolder) 'owner-fixture.ps1' }
}

AfterAll {
    Clear-TestLinks
    Restore-Env $script:RootEnv
    Restore-State $script:RootState
    [System.Environment]::CurrentDirectory = $script:RootDirectory
    try { Set-Location -LiteralPath $script:RootLocation } catch { $null = $_ }
}
Describe 'CD-12 the search for the program' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -NoNet
        Use-FakeProcesses @((New-FakeProcess))
        $script:Neutral = New-Dir (P $script:Work 'neutral cwd')
        [System.Environment]::CurrentDirectory = $script:Neutral
        Set-Location -LiteralPath $script:Neutral
    }
    AfterEach { Stop-Case }

    It 'CD-12 finds a stand-in script in an absolute PATH folder by its bare name and starts one process: the helper PowerShell of this host' {
        $folder = New-ToolFolder
        Set-Env 'PATH' $folder
        $outcome = @{}
        $result = Invoke-SwOwnerCommand -Name 'owner-fixture' -Arguments @('x') -Outcome $outcome
        $result | Should -Not -BeNullOrEmpty
        $script:Created.Count | Should -Be 1
        $script:Created[0].FilePath | Should -Be (Join-Path $PSHOME ([System.IO.Path]::GetFileName($script:Created[0].FilePath)))
        [System.IO.Path]::GetFileName($script:Created[0].FilePath) | Should -BeIn @('powershell.exe', 'pwsh.exe', 'pwsh')
        $outcome['Reason'] | Should -Be ''
    }

    It 'CD-12 accepts the absolute path of an existing file as the name (the form for tests)' {
        $path = Get-ToolPath
        $result = Invoke-SwOwnerCommand -Name $path -Arguments @('x')
        $result | Should -Not -BeNullOrEmpty
        $script:Created.Count | Should -Be 1
        (Get-Encoded $script:Created[0].Arguments) | Should -Match ([regex]::Escape($path))
    }

    It 'CD-12 finds nothing, starts nothing and gives "tool not found" when no PATH folder has the program' {
        Set-Env 'PATH' $script:EmptyBin
        $outcome = @{}
        $result = Invoke-SwOwnerCommand -Name 'owner-fixture' -Arguments @('x') -Outcome $outcome
        $null -eq $result | Should -BeTrue
        $outcome['Reason'] | Should -Be 'tool not found'
        Should -Invoke New-SwOwnerProcess -Times 0 -Exactly
    }

    It 'CD-12 gives "tool not found" for a name with a path that does not exist, and for a relative path to an existing file' {
        $folder = New-ToolFolder
        $outcome = @{}
        $null = Invoke-SwOwnerCommand -Name (P $folder 'missing.ps1') -Arguments @('x') -Outcome $outcome
        $outcome['Reason'] | Should -Be 'tool not found'
        [System.Environment]::CurrentDirectory = $folder
        Set-Location -LiteralPath $folder
        $outcome = @{}
        $null = Invoke-SwOwnerCommand -Name 'owner-fixture.ps1' -Arguments @('x') -Outcome $outcome
        $outcome['Reason'] | Should -Be 'tool not found' -Because 'without PATH a program in the working folder is not found'
        $outcome = @{}
        $null = Invoke-SwOwnerCommand -Name ('.' + $script:Sep + 'owner-fixture.ps1') -Arguments @('x') -Outcome $outcome
        $outcome['Reason'] | Should -Be 'tool not found'
        Should -Invoke New-SwOwnerProcess -Times 0 -Exactly
    }

    It 'CD-12 ignores a relative PATH entry: a program in the folder it names is not found, <Entry>' -ForEach @(
        @{ Entry = 'bin' }, @{ Entry = '.' }, @{ Entry = ('.' + [System.IO.Path]::DirectorySeparatorChar + 'bin') }) {
        $folder = New-ToolFolder 'rel work'
        $null = New-Dir (P $folder 'bin')
        [System.IO.File]::WriteAllText((P $folder 'bin' 'owner-fixture.ps1'), $script:FixtureBody, $script:Utf8)
        [System.IO.File]::WriteAllText((P $folder 'owner-fixture.ps1'), $script:FixtureBody, $script:Utf8)
        [System.Environment]::CurrentDirectory = $folder
        Set-Location -LiteralPath $folder
        Set-Env 'PATH' $Entry
        $outcome = @{}
        $null = Invoke-SwOwnerCommand -Name 'owner-fixture' -Arguments @('x') -Outcome $outcome
        $outcome['Reason'] | Should -Be 'tool not found'
        Should -Invoke New-SwOwnerProcess -Times 0 -Exactly
    }

    It 'CD-12 rejects a hit in the working directory of the process, also when PATH names it with an absolute entry' {
        $folder = New-ToolFolder 'cwd tools'
        [System.Environment]::CurrentDirectory = $folder
        Set-Env 'PATH' $folder
        $outcome = @{}
        $null = Invoke-SwOwnerCommand -Name 'owner-fixture' -Arguments @('x') -Outcome $outcome
        $outcome['Reason'] | Should -Be 'tool not found'
        Should -Invoke New-SwOwnerProcess -Times 0 -Exactly
    }

    It 'CD-12 rejects a hit below the working directory of the process' {
        $top = New-Dir (P $script:Work 'cwd top')
        $folder = New-ToolFolder 'cwd top/inner tools'
        [System.Environment]::CurrentDirectory = $top
        Set-Env 'PATH' $folder
        $outcome = @{}
        $null = Invoke-SwOwnerCommand -Name 'owner-fixture' -Arguments @('x') -Outcome $outcome
        $outcome['Reason'] | Should -Be 'tool not found'
    }

    It 'CD-12 rejects a hit in or below the location of PowerShell (Get-Location), which can differ from the working directory' {
        $folder = New-ToolFolder 'location tools'
        Set-Location -LiteralPath $folder
        [System.Environment]::CurrentDirectory = $script:Neutral
        Set-Env 'PATH' $folder
        $outcome = @{}
        $null = Invoke-SwOwnerCommand -Name 'owner-fixture' -Arguments @('x') -Outcome $outcome
        $outcome['Reason'] | Should -Be 'tool not found'
        Should -Invoke New-SwOwnerProcess -Times 0 -Exactly
    }

    It 'CD-12 S-3 ignores a relative PATH entry that leads out of the working folder and the location into a sibling folder' {
        $parent = New-Dir (P $script:Work 'rel parent')
        $cwd = New-Dir (P $parent 'cwd')
        $null = New-ToolFolder 'rel parent/tools'
        [System.Environment]::CurrentDirectory = $cwd
        Set-Location -LiteralPath $cwd
        Set-Env 'PATH' ('..' + $script:Sep + 'tools')
        $outcome = @{}
        $null = Invoke-SwOwnerCommand -Name 'owner-fixture' -Arguments @('x') -Outcome $outcome
        $outcome['Reason'] | Should -Be 'tool not found'
        Should -Invoke New-SwOwnerProcess -Times 0 -Exactly
    }

    It 'CD-12 does not take an alias, a function or a cmdlet of the same name for a program' {
        function global:owner-shadow-probe { 'function' }
        Set-Alias -Name 'owner-alias-probe' -Value 'Get-Date' -Scope Global
        try {
            Set-Env 'PATH' $script:EmptyBin
            foreach ($name in 'owner-shadow-probe', 'owner-alias-probe', 'Get-Date') {
                $outcome = @{}
                $null = Invoke-SwOwnerCommand -Name $name -Arguments @('x') -Outcome $outcome
                $outcome['Reason'] | Should -Be 'tool not found' -Because $name
            }
        }
        finally {
            Remove-Item -Path 'Function:\owner-shadow-probe' -ErrorAction SilentlyContinue
            Remove-Item -Path 'Alias:\owner-alias-probe' -ErrorAction SilentlyContinue
        }
        Should -Invoke New-SwOwnerProcess -Times 0 -Exactly
    }

    It 'CD-12 takes the first PATH folder that has the program, in the order of PATH' {
        $first = New-ToolFolder 'first tools' 'first'
        $second = New-ToolFolder 'second tools' 'second'
        Set-Env 'PATH' ($first + [System.IO.Path]::PathSeparator + $second)
        $null = Invoke-SwOwnerCommand -Name 'owner-fixture' -Arguments @('x')
        (Get-Encoded $script:Created[0].Arguments) | Should -Match ([regex]::Escape((P $first 'owner-fixture.ps1')))
        (Get-Encoded $script:Created[0].Arguments) | Should -Not -Match ([regex]::Escape((P $second 'owner-fixture.ps1')))
    }

    It 'CD-12 skips an entry that is rejected and takes the next one: a relative entry before an absolute one' {
        $good = New-ToolFolder 'good tools'
        Set-Env 'PATH' ('relative-entry' + [System.IO.Path]::PathSeparator + $good)
        $null = Invoke-SwOwnerCommand -Name 'owner-fixture' -Arguments @('x')
        $script:Created.Count | Should -Be 1
    }

    It 'CD-12 S-3 does not take a hit in the installation folder of Sweepr: a copy of the program files finds nothing below its own folder, and finds the same tool elsewhere' {
        $install = New-Dir (P $script:Work 'install copy')
        Copy-Item -LiteralPath (P $script:RepoRoot 'lib') -Destination (P $install 'lib') -Recurse
        $inside = New-ToolFolder 'install copy/tools'
        $outside = New-ToolFolder 'outside tools'
        $loader = '. ' + (ConvertTo-TestLiteral (P $install 'lib' 'clean' 'dev.ps1')) + "`n" +
        'function New-SwOwnerProcess { param($FilePath, $Arguments) throw ''created'' }' + "`n" +
        '$o = @{}; $r = Invoke-SwOwnerCommand -Name ''owner-fixture'' -Arguments @(''x'') -Outcome $o; $o[''Reason'']'
        $env1 = @{ PATH = $inside; USERPROFILE = $script:Profile; LOCALAPPDATA = $script:Local; APPDATA = $script:Roam; SWEEPR_NO_OPLOG = '1' }
        $result = Invoke-ChildPowerShell -Script $loader -WorkingDirectory $script:Neutral -Environment $env1
        ($result.Out.Trim()) | Should -Be 'tool not found'
        $env2 = @{ PATH = $outside; USERPROFILE = $script:Profile; LOCALAPPDATA = $script:Local; APPDATA = $script:Roam; SWEEPR_NO_OPLOG = '1' }
        $control = Invoke-ChildPowerShell -Script $loader -WorkingDirectory $script:Neutral -Environment $env2
        ($control.Out.Trim()) | Should -Not -Be 'tool not found'
        ($control.Out.Trim()) | Should -Match 'created|start failed|error'
    }

    It 'CD-12 [W] takes .exe before .cmd before .ps1 in the same folder, and rejects a .cmd whose folder has one of the characters percent, caret, ampersand, pipe, angle brackets, quote or exclamation mark' {
        $folder = New-Dir (P $script:Work 'owner & tools')
        [System.IO.File]::WriteAllText((P $folder 'owner-fixture.cmd'), "@echo off`r`n", $script:Utf8)
        Set-Env 'PATH' $folder
        $outcome = @{}
        $null = Invoke-SwOwnerCommand -Name 'owner-fixture' -Arguments @('x') -Outcome $outcome
        $outcome['Reason'] | Should -Be 'tool not found'
        $script:Created.Count | Should -Be 0
        $plain = New-Dir (P $script:Work 'owner tools 2')
        [System.IO.File]::WriteAllText((P $plain 'owner-fixture.cmd'), "@echo off`r`n", $script:Utf8)
        [System.IO.File]::WriteAllText((P $plain 'owner-fixture.ps1'), $script:FixtureBody, $script:Utf8)
        Set-Env 'PATH' $plain
        $null = Invoke-SwOwnerCommand -Name 'owner-fixture' -Arguments @('x')
        (Get-Encoded $script:Created[0].Arguments) | Should -Match 'owner-fixture\.cmd'
        $script:OnWindows | Should -BeTrue -Because 'this case needs a host that runs .cmd programs'
    }
}

Describe 'CD-12 the helper process: encoded command, execution policy and argument literals' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -NoNet
        Use-FakeProcesses @((New-FakeProcess))
        $script:Tool = Get-ToolPath
    }
    AfterEach { Stop-Case }

    It 'CD-12 gives the helper the arguments -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand and the base64 text for a .ps1 program' {
        $null = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x')
        $script:Created[0].Arguments | Should -Match '^-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand [A-Za-z0-9+/=]+$'
    }

    It 'CD-12 [W] gives no -ExecutionPolicy Bypass for a program that is not a .ps1 file' {
        $folder = New-Dir (P $script:Work 'exe tools')
        $program = P $folder 'owner-fixture.cmd'
        [System.IO.File]::WriteAllText($program, "@echo off`r`n", $script:Utf8)
        $null = Invoke-SwOwnerCommand -Name $program -Arguments @('x')
        $script:Created[0].Arguments | Should -Match '^-NoProfile -NonInteractive -EncodedCommand [A-Za-z0-9+/=]+$'
        $script:Created[0].Arguments | Should -Not -Match 'Bypass'
    }

    It 'CD-12 puts the absolute path of the program into the command as a literal and calls it with &' {
        $null = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x')
        $text = Get-Encoded $script:Created[0].Arguments
        $text | Should -Match ('&\s*' + [regex]::Escape((ConvertTo-SwPsLiteral $script:Tool)))
    }

    It 'CD-12 sets UTF-8 for the console and the pipeline output and ends with the exit code of the program' {
        $null = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x')
        $text = Get-Encoded $script:Created[0].Arguments
        $text | Should -Match '(?i)OutputEncoding'
        $text | Should -Match '(?i)utf-?8'
        $text | Should -Match 'LASTEXITCODE'
        $text | Should -Match '(?i)exit'
    }

    It 'CD-12 lets a native call run with the error preference Continue: only the exit code counts' {
        $null = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x')
        (Get-Encoded $script:Created[0].Arguments) | Should -Match "(?i)ErrorActionPreference\s*=\s*'Continue'"
    }

    It 'CD-12 gives every argument as its own literal with doubled apostrophes: it''s becomes ''it''''s'', U+2019 is doubled too' {
        $quote = S 0x2019
        $null = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @("it's", ('a' + $quote + 'b'), 'x y')
        $text = Get-Encoded $script:Created[0].Arguments
        $text | Should -Match ([regex]::Escape("'it''s'"))
        $text | Should -Match ([regex]::Escape("'a" + $quote + $quote + "b'"))
        $text | Should -Match ([regex]::Escape("'x y'"))
    }

    It 'CD-12 does not turn the argument list into a single string: no argument is joined with a space into one literal' {
        $null = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('cache', 'clean', '--force')
        $text = Get-Encoded $script:Created[0].Arguments
        $text | Should -Match ([regex]::Escape("'cache' 'clean' '--force'"))
        $text | Should -Not -Match ([regex]::Escape("'cache clean --force'"))
    }

    It 'CD-12 hands <Label> to the program unchanged: the decoded command runs in a PowerShell and the stand-in sees exactly the arguments' -ForEach $script:ArgumentSets {
        $null = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @($Values)
        $text = Get-Encoded $script:Created[0].Arguments
        $result = Invoke-ChildPowerShell -Script $text -WorkingDirectory $script:Scratch
        $result.ExitCode | Should -Be 0
        $lines = @(($result.Out -split "`r?`n") | Where-Object { $_ -ne '' })
        @($lines | Where-Object { $_ -like 'ARG:*' } | ForEach-Object { $_.Substring(4) }) | Should -Be @($Values | ForEach-Object { Get-CodePoints $_ })
        ($lines | Where-Object { $_ -like 'COUNT:*' }) | Should -Be ('COUNT:' + @($Values).Count)
    }

    It 'CD-12 hands typographic quotes and non-ASCII text unchanged' {
        $values = @(('a' + (S 0x2018) + 'b'), ('c' + (S 0x201B) + 'd'), ((S 0x00E4) + (S 0x4E2D)), ((S 0x201C) + 'q' + (S 0x201D)))
        $null = Invoke-SwOwnerCommand -Name $script:Tool -Arguments $values
        $result = Invoke-ChildPowerShell -Script (Get-Encoded $script:Created[0].Arguments) -WorkingDirectory $script:Scratch
        $lines = @(($result.Out -split "`r?`n") | Where-Object { $_ -like 'ARG:*' } | ForEach-Object { $_.Substring(4) })
        $lines | Should -Be @($values | ForEach-Object { Get-CodePoints $_ })
    }

    It 'CD-12 starts no command that an argument smuggles in: the marker file of an injected command does not appear' {
        $marker = P $script:Work 'injected.marker'
        $evil = @(("x'; Set-Content -LiteralPath '" + $marker + "' -Value 1; '"), ('$(Set-Content -LiteralPath ''' + $marker + ''' -Value 1)'), ('`$(Set-Content -LiteralPath ''' + $marker + ''' -Value 1)'))
        $null = Invoke-SwOwnerCommand -Name $script:Tool -Arguments $evil
        $result = Invoke-ChildPowerShell -Script (Get-Encoded $script:Created[0].Arguments) -WorkingDirectory $script:Scratch
        $result.ExitCode | Should -Be 0
        [System.IO.File]::Exists($marker) | Should -BeFalse
    }

    It 'CD-12 hands the path of a program with a space, a semicolon, an apostrophe and brackets to the call unchanged' {
        $folder = New-ToolFolder "own er; tools [1] it's"
        $path = P $folder 'owner-fixture.ps1'
        $script:Events.Clear()
        Use-FakeProcesses @((New-FakeProcess))
        $null = Invoke-SwOwnerCommand -Name $path -Arguments @('a b')
        $result = Invoke-ChildPowerShell -Script (Get-Encoded $script:Created[0].Arguments) -WorkingDirectory $script:Scratch
        $result.ExitCode | Should -Be 0
        @(($result.Out -split "`r?`n") | Where-Object { $_ -like 'ARG:*' }) | Should -Be @('ARG:' + (Get-CodePoints 'a b'))
    }

    It 'CD-12 gives the exit code of the program as the exit code of the helper: 3 stays 3, and a script that ends without exit gives 0' {
        $exit = New-ToolFolder 'exit tools' 'exit 3' 'exit-fixture'
        $plain = New-ToolFolder 'plain tools' '"done"' 'plain-fixture'
        foreach ($case in @(@{ Tool = (P $exit 'exit-fixture.ps1'); Expected = 3 }, @{ Tool = (P $plain 'plain-fixture.ps1'); Expected = 0 })) {
            Use-FakeProcesses @((New-FakeProcess))
            $null = Invoke-SwOwnerCommand -Name $case.Tool -Arguments @()
            $result = Invoke-ChildPowerShell -Script (Get-Encoded $script:Created[0].Arguments) -WorkingDirectory $script:Scratch
            $result.ExitCode | Should -Be $case.Expected -Because $case.Tool
        }
    }

    It 'CD-12 does not fail the call because the program writes to the error stream: exit code 0 stays 0' {
        $noisy = New-ToolFolder 'noisy tools' "[Console]::Error.WriteLine('a warning on stderr'); 'out'" 'noisy-fixture'
        $null = Invoke-SwOwnerCommand -Name (P $noisy 'noisy-fixture.ps1') -Arguments @()
        $result = Invoke-ChildPowerShell -Script (Get-Encoded $script:Created[0].Arguments) -WorkingDirectory $script:Scratch
        $result.ExitCode | Should -Be 0
        $result.Out | Should -Match 'out'
    }

    It 'CD-12 starts the helper from $PSHOME: the file is one of powershell.exe, pwsh.exe and pwsh in the folder of the running PowerShell' {
        $null = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x')
        $file = $script:Created[0].FilePath
        [System.IO.Path]::GetDirectoryName($file) | Should -BeExactly ([System.IO.Path]::GetDirectoryName((Join-Path $PSHOME 'x')))
        [System.IO.File]::Exists($file) | Should -BeTrue
    }

    It 'CD-12 creates every process through New-SwOwnerProcess: one for a call that finishes, and the stand-in is started once' {
        $fake = New-FakeProcess
        Use-FakeProcesses @($fake)
        $null = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x')
        $script:Created.Count | Should -Be 1
        @($script:Events | Where-Object { $_ -eq 'owner:Start' }).Count | Should -Be 1
    }
}

Describe 'CD-12 CD-17 New-SwOwnerProcess' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        $script:SavedProcessEnv = Save-Env @('GOTOOLCHAIN', 'COREPACK_ENABLE_DOWNLOAD_PROMPT', 'COREPACK_ENABLE_NETWORK', 'NPM_CONFIG_UPDATE_NOTIFIER')
    }
    AfterEach { Restore-Env $script:SavedProcessEnv }

    It 'CD-12 gives a Process with the file name and the arguments as given' {
        $process = New-SwOwnerProcess -FilePath 'owner-program.exe' -Arguments '-a "b c"'
        try {
            $process | Should -BeOfType [System.Diagnostics.Process]
            $process.StartInfo.FileName | Should -Be 'owner-program.exe'
            $process.StartInfo.Arguments | Should -Be '-a "b c"'
        }
        finally { $process.Dispose() }
    }

    It 'CD-12 sets StartInfo completely: no shell, no window, all three streams redirected, UTF-8 for both outputs' {
        $process = New-SwOwnerProcess -FilePath 'owner-program.exe' -Arguments ''
        try {
            $process.StartInfo.UseShellExecute | Should -BeFalse
            $process.StartInfo.CreateNoWindow | Should -BeTrue
            $process.StartInfo.RedirectStandardOutput | Should -BeTrue
            $process.StartInfo.RedirectStandardError | Should -BeTrue
            $process.StartInfo.RedirectStandardInput | Should -BeTrue
            $process.StartInfo.StandardOutputEncoding.CodePage | Should -Be 65001
            $process.StartInfo.StandardErrorEncoding.CodePage | Should -Be 65001
        }
        finally { $process.Dispose() }
    }

    It 'CD-12 uses the system folder as the working directory, not the folder of the caller' {
        $process = New-SwOwnerProcess -FilePath 'owner-program.exe' -Arguments ''
        try { $process.StartInfo.WorkingDirectory | Should -BeExactly ([System.Environment]::SystemDirectory) }
        finally { $process.Dispose() }
    }

    It 'CD-12 sets GOTOOLCHAIN=local and the three Corepack and npm variables in the child only' {
        Set-Env 'GOTOOLCHAIN' 'auto'
        Set-Env 'COREPACK_ENABLE_DOWNLOAD_PROMPT' '1'
        Set-Env 'COREPACK_ENABLE_NETWORK' '1'
        Set-Env 'NPM_CONFIG_UPDATE_NOTIFIER' 'true'
        $process = New-SwOwnerProcess -FilePath 'owner-program.exe' -Arguments ''
        try {
            $variables = $process.StartInfo.EnvironmentVariables
            $variables['GOTOOLCHAIN'] | Should -Be 'local'
            $variables['COREPACK_ENABLE_DOWNLOAD_PROMPT'] | Should -Be '0'
            $variables['COREPACK_ENABLE_NETWORK'] | Should -Be '0'
            $variables['NPM_CONFIG_UPDATE_NOTIFIER'] | Should -Be 'false'
            [System.Environment]::GetEnvironmentVariable('GOTOOLCHAIN') | Should -Be 'auto' -Because 'the variables of this process stay'
            [System.Environment]::GetEnvironmentVariable('COREPACK_ENABLE_NETWORK') | Should -Be '1'
            [System.Environment]::GetEnvironmentVariable('NPM_CONFIG_UPDATE_NOTIFIER') | Should -Be 'true'
        }
        finally { $process.Dispose() }
    }

    It 'CD-12 leaves the rest of the environment of the child as it is: PATH and HOME of the caller are the ones of the child' {
        $process = New-SwOwnerProcess -FilePath 'owner-program.exe' -Arguments ''
        try {
            $variables = $process.StartInfo.EnvironmentVariables
            $variables['PATH'] | Should -BeExactly ([System.Environment]::GetEnvironmentVariable('PATH'))
        }
        finally { $process.Dispose() }
    }

    It 'CD-12 takes the parameters FilePath and Arguments as strings and no more' {
        (Get-ParamLine 'New-SwOwnerProcess' 'FilePath') | Should -BeLike 'FilePath|System.String|*'
        (Get-ParamLine 'New-SwOwnerProcess' 'Arguments') | Should -BeLike 'Arguments|System.String|*'
        (Get-ParamCount 'New-SwOwnerProcess') | Should -Be 2
    }
}

Describe 'CD-17 Invoke-SwOwnerCommand with stand-in processes' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -NoNet
        $script:Tool = Get-ToolPath
        $script:SweeprDryRunMode = $false
    }
    AfterEach { Stop-Case }

    It 'CD-17 gives the trimmed stdout as Output, an empty Reason and closes the input at once after the start' {
        Use-FakeProcesses @((New-FakeProcess -Out "  the output text `r`n"))
        $outcome = @{ Reason = 'old reason' }
        $result = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x') -Outcome $outcome
        $result.Output | Should -BeExactly 'the output text'
        $outcome['Reason'] | Should -Be ''
        $started = $script:Events.IndexOf('owner:Start')
        $closed = $script:Events.IndexOf('owner:StdinClose')
        $started | Should -BeGreaterOrEqual 0
        $closed | Should -BeGreaterThan $started
        $script:Events.IndexOf('owner:ReadOut') | Should -BeGreaterThan $started
        $script:Events.IndexOf('owner:ReadErr') | Should -BeGreaterThan $started
    }

    It 'CD-17 gives an empty Output (not $null) for a program that prints nothing and exits with 0' {
        Use-FakeProcesses @((New-FakeProcess -Out ''))
        $result = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x')
        $null -ne $result | Should -BeTrue
        $result.Output | Should -BeExactly ''
    }

    It 'CD-17 works without an Outcome table' {
        Use-FakeProcesses @((New-FakeProcess -Out 'x'))
        { $null = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x') } | Should -Not -Throw
    }

    It 'CD-17 reads stderr, gives it to the debug writer and never mixes it into Output' {
        Use-FakeProcesses @((New-FakeProcess -Out 'good' -Err 'npm WARN something'))
        $result = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x')
        $result.Output | Should -BeExactly 'good'
        (@(Get-LogLines 'DEBUG') -join "`n") | Should -Match 'npm WARN something'
    }

    It 'CD-17 reads both outputs asynchronously: ReadToEndAsync on stdout and stderr, before it waits for the end' {
        Use-FakeProcesses @((New-FakeProcess -Out 'x'))
        $null = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x')
        $script:Events.IndexOf('owner:ReadOut') | Should -BeLessThan $script:Events.IndexOf('owner:Wait')
        $script:Events.IndexOf('owner:ReadErr') | Should -BeLessThan $script:Events.IndexOf('owner:Wait')
    }

    It 'CD-17 waits TimeoutSeconds times 1000 milliseconds for the end: 5 s for a query, 120 s for a mutation with the limit' {
        $fake = New-FakeProcess -Out 'x'
        Use-FakeProcesses @($fake)
        $null = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x')
        $fake.WaitedMs | Should -Be 5000
        $fake = New-FakeProcess -Out 'x'
        Use-FakeProcesses @($fake)
        $null = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x') -Mutation -TimeoutSeconds 120
        $fake.WaitedMs | Should -Be 120000
    }

    It 'CD-17 gives $null and "exit code 9" for an exit code that is not 0, and no taskkill' {
        Use-FakeProcesses @((New-FakeProcess -ExitCode 9 -Out 'text'))
        $outcome = @{}
        $result = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x') -Outcome $outcome
        $null -eq $result | Should -BeTrue
        $outcome['Reason'] | Should -Match 'exit code 9'
        $script:Created.Count | Should -Be 1
        @($script:Events | Where-Object { $_ -like 'kill:*' }).Count | Should -Be 0
    }

    It 'CD-17 gives $null and "output not read" when a query finishes but stdout is not read within the read time, and each wait is at most 1000 ms' {
        Use-FakeProcesses @((New-FakeProcess -Out 'lost' -OutReadable $false))
        $outcome = @{}
        $result = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x') -Outcome $outcome
        $null -eq $result | Should -BeTrue
        $outcome['Reason'] | Should -Match 'output not read'
        $script:ReadWaits.Count | Should -BeGreaterThan 0
        foreach ($milliseconds in $script:ReadWaits) { $milliseconds | Should -BeLessOrEqual 1000 }
        $script:Created.Count | Should -Be 1 -Because 'the process ended, so no taskkill'
    }

    It 'CD-17 does not fail a mutation that ended with 0 only because its output was not read' {
        Use-FakeProcesses @((New-FakeProcess -Out '' -OutReadable $false -ErrReadable $false))
        $outcome = @{}
        $result = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('cache', 'clean') -Mutation -TimeoutSeconds 120 -Outcome $outcome
        $null -ne $result | Should -BeTrue
        $outcome['Reason'] | Should -Not -Match 'output not read'
    }

    It 'CD-17 gives $null and "start failed" when Start throws, makes exactly one process, no taskkill, and releases it' {
        $fake = New-FakeProcess -StartThrows $true
        Use-FakeProcesses @($fake)
        $outcome = @{}
        $result = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x') -Outcome $outcome
        $null -eq $result | Should -BeTrue
        $outcome['Reason'] | Should -Match 'start failed: .*cannot start the process'
        $script:Created.Count | Should -Be 1
        $fake.Disposed | Should -BeTrue
        @($script:Events | Where-Object { $_ -like 'kill:*' }).Count | Should -Be 0
    }

    It 'CD-17 ends the process tree with taskkill after the limit: $null, "timed out after 5 s", "process tree 42 terminated", and the order Start, Start, Dispose, Dispose' {
        $owner = New-FakeProcess -Waits $false -Id 42 -ExitsWhenKillStarts $true
        $kill = New-FakeProcess -Label 'kill' -Id 77 -ExitCode 0
        Use-FakeProcesses @($owner, $kill)
        $outcome = @{}
        $result = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x') -Outcome $outcome
        $null -eq $result | Should -BeTrue
        $outcome['Reason'] | Should -Match 'timed out after 5 s'
        $outcome['Reason'] | Should -Match 'process tree 42 terminated'
        (Get-OrderEvents) | Should -Be @('owner:Start', 'kill:Start', 'owner:Dispose', 'kill:Dispose')
        $script:Created.Count | Should -Be 2
        $script:Created[1].FilePath | Should -BeLike '*taskkill.exe'
        $script:Created[1].Arguments | Should -BeExactly '/PID 42 /T /F'
        $kill.WaitedMs | Should -BeLessOrEqual 5000
        $kill.WaitedMs | Should -BeGreaterThan 0
    }

    It 'CD-17 names the limit of a mutation in the reason: "timed out after 120 s"' {
        Use-FakeProcesses @((New-FakeProcess -Waits $false -ExitsWhenKillStarts $true), (New-FakeProcess -Label 'kill' -Id 77))
        $outcome = @{}
        $null = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x') -Mutation -TimeoutSeconds 120 -Outcome $outcome
        $outcome['Reason'] | Should -Match 'timed out after 120 s'
    }

    It 'CD-17 joins the reasons with "; ": the limit first, then the evidence of the end of the tree' {
        Use-FakeProcesses @((New-FakeProcess -Waits $false -ExitsWhenKillStarts $true), (New-FakeProcess -Label 'kill' -Id 77))
        $outcome = @{}
        $null = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x') -Outcome $outcome
        $outcome['Reason'] | Should -Match 'timed out after 5 s; process tree 42 terminated'
    }

    It 'CD-17 never writes "terminated" for a taskkill that ends with a code other than 0: "taskkill unconfirmed: 5", and tries Kill() on the process afterwards' {
        $owner = New-FakeProcess -Waits $false -Id 42
        $kill = New-FakeProcess -Label 'kill' -Id 77 -ExitCode 5
        Use-FakeProcesses @($owner, $kill)
        $outcome = @{}
        $null = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x') -Outcome $outcome
        $outcome['Reason'] | Should -Match 'taskkill unconfirmed: 5'
        $outcome['Reason'] | Should -Not -Match 'terminated'
        $owner.Killed | Should -BeTrue
        $script:Events.IndexOf('owner:Kill') | Should -BeGreaterThan $script:Events.IndexOf('kill:Start')
        (Get-OrderEvents) | Should -Be @('owner:Start', 'kill:Start', 'owner:Dispose', 'kill:Dispose')
    }

    It 'CD-17 never writes "terminated" when taskkill does not end within its 5 seconds: "taskkill unconfirmed"' {
        $owner = New-FakeProcess -Waits $false -Id 42
        $kill = New-FakeProcess -Label 'kill' -Id 77 -Waits $false
        Use-FakeProcesses @($owner, $kill)
        $outcome = @{}
        $null = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x') -Outcome $outcome
        $outcome['Reason'] | Should -Match 'taskkill unconfirmed'
        $outcome['Reason'] | Should -Not -Match 'terminated'
        $owner.Killed | Should -BeTrue
    }

    It 'CD-17 never writes "terminated" when taskkill cannot be started or made: "taskkill unconfirmed" with the message' {
        Use-FakeProcesses @((New-FakeProcess -Waits $false -Id 42), (New-FakeProcess -Label 'kill' -Id 77 -StartThrows $true))
        $outcome = @{}
        $null = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x') -Outcome $outcome
        $outcome['Reason'] | Should -Match 'taskkill unconfirmed: .*cannot start the process'
        $outcome['Reason'] | Should -Not -Match 'terminated'
        Use-FakeProcesses @((New-FakeProcess -Waits $false -Id 43))
        $outcome = @{}
        { $null = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x') -Outcome $outcome } | Should -Not -Throw
        $outcome['Reason'] | Should -Match 'taskkill unconfirmed'
        $outcome['Reason'] | Should -Not -Match 'terminated'
    }

    It 'CD-17 reads and discards the output channels of the taskkill process, too' {
        Use-FakeProcesses @((New-FakeProcess -Waits $false -ExitsWhenKillStarts $true), (New-FakeProcess -Label 'kill' -Id 77))
        $null = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x')
        $script:Events | Should -Contain 'kill:ReadOut'
        $script:Events | Should -Contain 'kill:ReadErr'
    }

    It 'CD-17 ends the tree also after an exception while reading or waiting, and does not throw' {
        $owner = New-FakeProcess -WaitThrows $true -Id 42 -ExitsWhenKillStarts $true
        Use-FakeProcesses @($owner, (New-FakeProcess -Label 'kill' -Id 77))
        $outcome = @{}
        $result = $null
        { $result = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x') -Outcome $outcome } | Should -Not -Throw
        $null -eq $result | Should -BeTrue
        $script:Created.Count | Should -Be 2
        $script:Created[1].Arguments | Should -BeExactly '/PID 42 /T /F'
        $owner.Disposed | Should -BeTrue
        $outcome['Reason'] | Should -Match '^error: .*the wait failed'
        $outcome['Reason'] | Should -Match 'process tree 42 terminated'
    }

    It 'CD-17 gives "error: " with the message and the evidence of the end when the input cannot be closed' {
        $owner = New-FakeProcess -Waits $false -Id 42 -ExitsWhenKillStarts $true
        Add-Member -InputObject $owner.StandardInput -MemberType ScriptMethod -Name Close -Value { throw 'input cannot be closed' } -Force
        Use-FakeProcesses @($owner, (New-FakeProcess -Label 'kill' -Id 77))
        $outcome = @{}
        $result = $null
        { $result = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x') -Outcome $outcome } | Should -Not -Throw
        $null -eq $result | Should -BeTrue
        $outcome['Reason'] | Should -Match '^error: .*input cannot be closed.*; process tree 42 terminated$'
        $owner.Disposed | Should -BeTrue
    }

    It 'CD-17 S-8 uses taskkill only for the process it started and never by name: the only argument is the id of the process' {
        Use-FakeProcesses @((New-FakeProcess -Waits $false -Id 4242 -ExitsWhenKillStarts $true), (New-FakeProcess -Label 'kill' -Id 77))
        $null = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x')
        $script:Created[1].Arguments | Should -BeExactly '/PID 4242 /T /F'
        $script:Created[1].Arguments | Should -Not -Match '/IM'
    }

    It 'CD-17 S-8 starts taskkill from the system folder with a full path, never through PATH' {
        Use-FakeProcesses @((New-FakeProcess -Waits $false -ExitsWhenKillStarts $true), (New-FakeProcess -Label 'kill' -Id 77))
        $null = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x')
        $file = $script:Created[1].FilePath
        [System.IO.Path]::GetFileName($file) | Should -Be 'taskkill.exe'
        if (-not [string]::IsNullOrEmpty([System.Environment]::SystemDirectory)) {
            $file | Should -BeExactly ([System.IO.Path]::Combine([System.Environment]::SystemDirectory, 'taskkill.exe'))
        }
    }

    It 'CD-17 releases the process in every path: after success, after an exit code, after a timeout with taskkill' {
        foreach ($case in @(
                @{ Owner = (New-FakeProcess -Out 'x'); Kill = $null }
                @{ Owner = (New-FakeProcess -ExitCode 4); Kill = $null }
                @{ Owner = (New-FakeProcess -Waits $false -ExitsWhenKillStarts $true); Kill = (New-FakeProcess -Label 'kill' -Id 77) })) {
            $queue = @($case.Owner)
            if ($null -ne $case.Kill) { $queue += $case.Kill }
            Use-FakeProcesses $queue
            $null = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x')
            $case.Owner.Disposed | Should -BeTrue
            if ($null -ne $case.Kill) { $case.Kill.Disposed | Should -BeTrue }
        }
    }
}

Describe 'CD-6 S-3 a mutation starts nothing in a preview or with the tools skipped' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -NoNet
        Mock Start-Process { throw 'Start-Process must not run in this test' }
        $script:Tool = Get-ToolPath
        Use-FakeProcesses @((New-FakeProcess -Out 'x'))
    }
    AfterEach { Stop-Case }

    It 'CD-6 gives $null and "mutation not allowed" for -Mutation in a preview, and creates no process' {
        $script:SweeprDryRunMode = $true
        $script:SweeprSkipExternalTools = $false
        $outcome = @{}
        $result = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('cache', 'clean') -Mutation -TimeoutSeconds 120 -Outcome $outcome
        $null -eq $result | Should -BeTrue
        $outcome['Reason'] | Should -Be 'mutation not allowed'
        Should -Invoke New-SwOwnerProcess -Times 0 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'CD-11 gives $null and "mutation not allowed" for -Mutation with SweeprSkipExternalTools set, in a real run too: <Label>' -ForEach @(
        @{ Label = '$true'; Value = $true }, @{ Label = 'the number 1'; Value = 1 }) {
        $script:SweeprDryRunMode = $false
        $script:SweeprSkipExternalTools = $Value
        $outcome = @{}
        $result = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('cache', 'clean') -Mutation -Outcome $outcome
        $null -eq $result | Should -BeTrue
        $outcome['Reason'] | Should -Be 'mutation not allowed'
        Should -Invoke New-SwOwnerProcess -Times 0 -Exactly
    }

    It 'CD-6 runs a mutation in a real run when the switch is $false, and a query in a preview' {
        $script:SweeprDryRunMode = $false
        $script:SweeprSkipExternalTools = $false
        $result = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x') -Mutation -TimeoutSeconds 120
        $null -ne $result | Should -BeTrue
        $script:Created.Count | Should -Be 1
        Use-FakeProcesses @((New-FakeProcess -Out 'x'))
        $script:SweeprDryRunMode = $true
        $result = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x')
        $null -ne $result | Should -BeTrue
        $script:Created.Count | Should -Be 1
    }

    It 'CD-6 sets the reason to an empty text at the start, so that an old reason does not stay' {
        $script:SweeprDryRunMode = $false
        $outcome = @{ Reason = 'left over from an earlier call' }
        $null = Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x') -Outcome $outcome
        $outcome['Reason'] | Should -Be ''
    }

    It 'CD-4 never throws and writes nothing to the pipeline besides the result object' {
        $script:SweeprDryRunMode = $false
        $out = Invoke-Captured { Invoke-SwOwnerCommand -Name $script:Tool -Arguments @('x') }
        @($out | Where-Object { $null -ne $_ }).Count | Should -Be 1
        { $null = Invoke-SwOwnerCommand -Name $null -Arguments $null } | Should -Not -Throw
    }
}

Describe 'CD-12 CD-17 real helper processes with a stand-in tool' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Initialize-Case -NoNet -RealProcess
        $script:SweeprDryRunMode = $false
        $script:Neutral = New-Dir (P $script:Work 'neutral cwd')
        [System.Environment]::CurrentDirectory = $script:Neutral
        Set-Location -LiteralPath $script:Neutral
    }
    AfterEach { Stop-Case }

    It 'CD-12 runs the stand-in through the helper and gives its stdout: the tool sees the four variables and the arguments' {
        $folder = New-ToolFolder
        Set-Env 'PATH' $folder
        $outcome = @{}
        $result = Invoke-SwOwnerCommand -Name 'owner-fixture' -Arguments @('a b', "it's") -Outcome $outcome
        $outcome['Reason'] | Should -Be ''
        $lines = @(($result.Output -split "`r?`n") | Where-Object { $_ -ne '' })
        $lines | Should -Contain ('ARG:' + (Get-CodePoints 'a b'))
        $lines | Should -Contain ('ARG:' + (Get-CodePoints "it's"))
        $lines | Should -Contain 'COUNT:2'
        $lines | Should -Contain 'ENV:local|0|0|false'
    }

    It 'CD-12 closes the input: a tool that reads standard input does not wait' {
        $body = "`$line = [Console]::In.ReadLine(); if (`$null -eq `$line) { 'stdin closed' } else { 'stdin had data' }"
        $folder = New-ToolFolder 'stdin tools' $body 'stdin-fixture'
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-SwOwnerCommand -Name (P $folder 'stdin-fixture.ps1') -Arguments @() -TimeoutSeconds 60
        $result.Output | Should -Be 'stdin closed'
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 50
    }

    It 'CD-12 gives $null and "exit code" for a stand-in script with a syntax error, for a mutation too' {
        $folder = New-ToolFolder 'syntax tools' 'if ( {' 'syntax-fixture'
        foreach ($mutation in $false, $true) {
            $outcome = @{}
            if ($mutation) { $result = Invoke-SwOwnerCommand -Name (P $folder 'syntax-fixture.ps1') -Arguments @() -Mutation -TimeoutSeconds 60 -Outcome $outcome }
            else { $result = Invoke-SwOwnerCommand -Name (P $folder 'syntax-fixture.ps1') -Arguments @() -Outcome $outcome }
            $null -eq $result | Should -BeTrue
            $outcome['Reason'] | Should -Match 'exit code [1-9]'
        }
    }

    It 'CD-12 gives $null and "exit code" for a stand-in script that throws' {
        $folder = New-ToolFolder 'throw tools' "throw 'the tool broke'" 'throw-fixture'
        $outcome = @{}
        $result = Invoke-SwOwnerCommand -Name (P $folder 'throw-fixture.ps1') -Arguments @() -Outcome $outcome
        $null -eq $result | Should -BeTrue
        $outcome['Reason'] | Should -Match 'exit code [1-9]'
    }

    It 'CD-17 gives $null and "exit code 9" for a program that exits with 9' {
        $folder = New-ToolFolder 'exit9 tools' 'exit 9' 'exit9-fixture'
        $outcome = @{}
        $result = Invoke-SwOwnerCommand -Name (P $folder 'exit9-fixture.ps1') -Arguments @() -Outcome $outcome
        $null -eq $result | Should -BeTrue
        $outcome['Reason'] | Should -Match 'exit code 9'
    }

    It 'CD-12 counts a program that writes a warning to stderr and exits with 0 as a success' {
        $folder = New-ToolFolder 'warn tools' "[Console]::Error.WriteLine('npm WARN something'); 'cache-root'" 'warn-fixture'
        $outcome = @{}
        $result = Invoke-SwOwnerCommand -Name (P $folder 'warn-fixture.ps1') -Arguments @() -Outcome $outcome
        $result.Output | Should -Be 'cache-root'
        $outcome['Reason'] | Should -Be ''
    }

    It 'CD-17 reads both outputs at the same time: 300000 characters on each of stdout and stderr do not block the program' {
        $body = "`$text = 'x' * 300000; [Console]::Error.Write(`$text); [Console]::Out.Write(`$text)"
        $folder = New-ToolFolder 'big tools' $body 'big-fixture'
        $result = Invoke-SwOwnerCommand -Name (P $folder 'big-fixture.ps1') -Arguments @() -TimeoutSeconds 60
        $null -ne $result | Should -BeTrue
        $result.Output.Length | Should -Be 300000
    }

    It 'CD-17 ends a program that runs too long, in a bounded time, with the evidence of the end in the reason, and it is gone afterwards' {
        $pidFile = P $script:Work 'fixture.pid'
        $body = "[System.IO.File]::WriteAllText('" + $pidFile + "', [string]`$PID); Start-Sleep -Seconds 120"
        $folder = New-ToolFolder 'slow tools' $body 'slow-fixture'
        $outcome = @{}
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-SwOwnerCommand -Name (P $folder 'slow-fixture.ps1') -Arguments @() -TimeoutSeconds 3 -Outcome $outcome
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 40
        $null -eq $result | Should -BeTrue
        $outcome['Reason'] | Should -Match 'timed out after 3 s'
        $outcome['Reason'] | Should -Match 'process tree \d+ terminated|taskkill unconfirmed'
        if ([System.IO.File]::Exists($pidFile)) {
            $processId = [int]([System.IO.File]::ReadAllText($pidFile).Trim())
            $deadline = [datetime]::Now.AddSeconds(8)
            $alive = $true
            while ($alive -and [datetime]::Now -lt $deadline) {
                $alive = $false
                try { $null = [System.Diagnostics.Process]::GetProcessById($processId); $alive = $true } catch { $alive = $false }
                if ($alive) { Start-Sleep -Milliseconds 200 }
            }
            $alive | Should -BeFalse -Because 'the helper that ran the tool must not outlive the call'
        }
    }

    It 'CD-17 [W] ends a child of the program together with the program: the real taskkill ends the whole process tree' {
        $childPid = P $script:Work 'child.pid'
        $body = "`$child = Start-Process -FilePath '" + $script:HostExe + "' -ArgumentList '-NoProfile','-Command','Start-Sleep 25' -PassThru; [System.IO.File]::WriteAllText('" + $childPid + "', [string]`$child.Id); Start-Sleep 60"
        $folder = New-ToolFolder 'tree tools' $body 'tree-fixture'
        $outcome = @{}
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $null = Invoke-SwOwnerCommand -Name (P $folder 'tree-fixture.ps1') -Arguments @() -TimeoutSeconds 10 -Outcome $outcome
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 20
        $outcome['Reason'] | Should -Match 'process tree \d+ terminated'
        $processId = [int]([System.IO.File]::ReadAllText($childPid).Trim())
        $deadline = [datetime]::Now.AddSeconds(5)
        $alive = $true
        while ($alive -and [datetime]::Now -lt $deadline) {
            $alive = $false
            try { $null = [System.Diagnostics.Process]::GetProcessById($processId); $alive = $true } catch { $alive = $false }
            if ($alive) { Start-Sleep -Milliseconds 200 }
        }
        $alive | Should -BeFalse
    }

    It 'CD-12 [W] runs a .cmd stand-in in a folder with a space in the name and hands stdout back, also when it writes to stderr and ends with 0' {
        $folder = New-Dir (P $script:Work 'owner tools 1')
        [System.IO.File]::WriteAllText((P $folder 'fixture.cmd'), "@echo off`r`necho fixture-cache-root`r`necho a warning 1>&2`r`nexit /b 0`r`n", $script:Utf8)
        Set-Env 'PATH' $folder
        $outcome = @{}
        $result = Invoke-SwOwnerCommand -Name 'fixture' -Arguments @() -Outcome $outcome
        $result.Output | Should -Be 'fixture-cache-root'
        $outcome['Reason'] | Should -Be ''
    }

    It 'CD-12 [W] gives $null and "exit code 9" for a .cmd stand-in that exits with 9' {
        $folder = New-Dir (P $script:Work 'owner tools 2')
        [System.IO.File]::WriteAllText((P $folder 'fixture9.cmd'), "@echo off`r`nexit /b 9`r`n", $script:Utf8)
        Set-Env 'PATH' $folder
        $outcome = @{}
        $result = Invoke-SwOwnerCommand -Name 'fixture9' -Arguments @() -Outcome $outcome
        $null -eq $result | Should -BeTrue
        $outcome['Reason'] | Should -Match 'exit code 9'
    }
}
