# Sweepr - tests for the path guard half of lib\core\file_ops.ps1: loading, Test-SwSafePath, path
# snapshots (identity), the tree walk, the validated tree and size measurement, plus the list of
# measurements that were not possible.
#
# The rule numbers in the test names (G-, F- and S-) number the rules and the safety invariants of the
# module's behavior; each rule and invariant has at least one test.
#
# Interface pinned here (new names; each old name stays as a forwarding function, not an alias):
#   Test-SwSafePath -Path [-WhitelistState]          $true = may be touched; protection and whitelist
#   Get-SwPathSnapshot -Path [-AllowLeafLink]        hashtable Path, Entries, AllowLeafLink, or $null
#   Test-SwPathSnapshot -Snapshot                    $true only when the identity chain is unchanged
#   Test-SwReparsePoint -Path                        $true for links and other reparse points
#   Get-SwTreeItems -Path [-SkipUnreadable]          entries one by one, each with SweeprPathSnapshot
#   Get-SwSafeDirectoryTreeItems -Path [-WhitelistState]   hashtable Success, Items, RootSnapshot, Reason
#   Get-SwValidatedTreeSize -Tree                    sum of the file lengths of Tree['Items']
#   Get-SwPathSize -Path / Get-SwPathSizeKB -Path    bytes (0 = empty or not measurable) / kilobytes
#   Add-SwNotMeasured -Name -Reason                  one entry per name in $script:NotMeasuredCollector
# Variables that tests replace: $script:SweeprDryRunMode, $script:SwWalkBudgetSeconds,
# $script:NotMeasuredCollector, $script:SWEEPR_FILEOPS_LOADED and the counters.
#
# Seams used with Mock:
#   Get-SwPathSnapshot, Test-SwPathSnapshot          every identity question of the module
#   Get-SwWhitelistState, Test-SwWhitelisted, Test-SwProtectedPath, Resolve-SwSafePath
#   Read-SwListBytes                                 the only read of the whitelist file
#   Get-SwTreeItems, Get-ChildItem, Add-Type         call counts and arguments
#
# Platform notes:
#   - Paths are built from $TestDrive with the separator of the host. On hosts without the Windows file
#     API Get-SwPathSnapshot always gives $null; the tests that exercise the walk and the sizes there
#     replace the identity functions by fakes that answer like the real ones (existing path, link
#     rules, identity text per path). Whitelist lines name entries of the tree exactly.
#   - Tests marked [W] need real Windows (file identities, junctions, 8.3 names, trailing dots). They
#     are meant to fail on Linux and belong in tests/linux-known-failures.txt.
#   - Links are junctions on Windows and symbolic links elsewhere; every test removes its links itself.
#   - Nothing real is touched: everything lives in $TestDrive, no registry, no network, no real
#     operations.log (the writer is mocked or pointed into the test drive).
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    $script:Forwarders = @(
        @{ Old = 'Test-SafePath'; New = 'Test-SwSafePath'; Pass = $true
            Invoke = { Test-SafePath -Path 'Example-Path' -WhitelistState 'state-object' }
            Filter = { $Path -eq 'Example-Path' -and $WhitelistState -eq 'state-object' } }
        @{ Old = 'Get-SweeprPathSnapshot'; New = 'Get-SwPathSnapshot'; Pass = $true
            Invoke = { Get-SweeprPathSnapshot -Path 'Example-Path' -AllowLeafLink }
            Filter = { $Path -eq 'Example-Path' -and $AllowLeafLink } }
        @{ Old = 'Test-SweeprPathSnapshot'; New = 'Test-SwPathSnapshot'; Pass = $true
            Invoke = { Test-SweeprPathSnapshot -Snapshot 'snapshot-object' }
            Filter = { $Snapshot -eq 'snapshot-object' } }
        @{ Old = 'Test-IsReparsePoint'; New = 'Test-SwReparsePoint'; Pass = $true
            Invoke = { Test-IsReparsePoint -Path 'Example-Path' }
            Filter = { $Path -eq 'Example-Path' } }
        @{ Old = 'Get-TreeItemsNoFollow'; New = 'Get-SwTreeItems'; Pass = $true
            Invoke = { Get-TreeItemsNoFollow -Path 'Example-Path' -SkipUnreadable }
            Filter = { $Path -eq 'Example-Path' -and $SkipUnreadable } }
        @{ Old = 'Get-SafeDirectoryTreeItems'; New = 'Get-SwSafeDirectoryTreeItems'; Pass = $true
            Invoke = { Get-SafeDirectoryTreeItems -Path 'Example-Path' -WhitelistState 'state-object' }
            Filter = { $Path -eq 'Example-Path' -and $WhitelistState -eq 'state-object' } }
        @{ Old = 'Get-ValidatedTreeSize'; New = 'Get-SwValidatedTreeSize'; Pass = $true
            Invoke = { Get-ValidatedTreeSize -Tree @{ Items = @() } }
            Filter = { $Tree -is [hashtable] -and $Tree.ContainsKey('Items') } }
        @{ Old = 'Get-PathSize'; New = 'Get-SwPathSize'; Pass = $true
            Invoke = { Get-PathSize -Path 'Example-Path' }
            Filter = { $Path -eq 'Example-Path' } }
        @{ Old = 'Get-PathSizeKB'; New = 'Get-SwPathSizeKB'; Pass = $true
            Invoke = { Get-PathSizeKB -Path 'Example-Path' }
            Filter = { $Path -eq 'Example-Path' } }
        @{ Old = 'Add-SweeprNotMeasured'; New = 'Add-SwNotMeasured'; Pass = $false
            Invoke = { Add-SweeprNotMeasured -Name 'Example-Name' -Reason 'Example-Reason' }
            Filter = { $Name -eq 'Example-Name' -and $Reason -eq 'Example-Reason' } }
    )

    # G-6 and S-15: names that contain characters with a meaning for wildcards or the shell.
    $script:OddNames = @(
        @{ Label = 'brackets'; Name = 'Cache [1]' }
        @{ Label = 'a closing bracket'; Name = 'x]y' }
        @{ Label = 'a backtick'; Name = ('a' + [char]96 + 'b') }
        @{ Label = 'a dollar sign'; Name = '$HOME' }
        @{ Label = 'an apostrophe'; Name = 'it''s' }
        @{ Label = 'braces'; Name = '{a}' }
        @{ Label = 'a percent sign'; Name = '100%' }
        @{ Label = 'a semicolon'; Name = 'a;b' }
        @{ Label = 'parentheses'; Name = 'Tools (x86)' }
    )

    # F-16: sizes whose kilobyte value rounds up.
    $script:KbCases = @(
        @{ Bytes = 0; Expected = 0 }
        @{ Bytes = 1; Expected = 1 }
        @{ Bytes = 1023; Expected = 1 }
        @{ Bytes = 1024; Expected = 1 }
        @{ Bytes = 1025; Expected = 2 }
        @{ Bytes = 8000; Expected = 8 }
        @{ Bytes = 2048; Expected = 2 }
    )

    # F-23 style evaluation does not apply here; F-10 and F-11 substitute objects.
    $script:SubstituteSnapshots = @(
        @{ Label = 'an object with only Path'; Make = { param($p) [pscustomobject]@{ Path = $p } } }
        @{ Label = 'a hashtable with only Path'; Make = { param($p) @{ Path = $p } } }
        @{ Label = 'an empty object'; Make = { param($p) [pscustomobject]@{} } }
        @{ Label = 'an empty hashtable'; Make = { param($p) @{} } }
        @{ Label = 'a string'; Make = { param($p) 'not a snapshot' } }
        @{ Label = 'a number'; Make = { param($p) 42 } }
        @{ Label = 'Entries that is not a table'; Make = { param($p) @{ Path = $p; Entries = 'x'; AllowLeafLink = $false } } }
    )

    # G-8: input that must never make a function that does not throw, throw.
    $script:HostileText = @(
        @{ Label = 'a NUL character'; Text = ('a' + [char]0 + 'b') }
        @{ Label = 'a line break'; Text = ("a" + [char]10 + "b") }
        @{ Label = 'white space only'; Text = '   ' }
        @{ Label = 'a provider path'; Text = 'HKCU:\Software\Example' }
        @{ Label = 'a device path'; Text = '\\?\C:\Example\x' }
        @{ Label = 'a UNC path'; Text = '\\server\share\x' }
        @{ Label = 'a very long name'; Text = ('x' * 5000) }
        @{ Label = 'wildcards'; Text = '*?[]' }
    )


    # E36: the new names with their parameters (Mandatory ones are named, Position 0 where given).
    $script:Interface = @(
        @{ Name = 'Test-SwSafePath'; Parameters = @('Path', 'WhitelistState'); Mandatory = @('Path'); Position0 = 'Path' }
        @{ Name = 'Get-SwPathSnapshot'; Parameters = @('Path', 'AllowLeafLink'); Mandatory = @(); Position0 = 'Path' }
        @{ Name = 'Test-SwPathSnapshot'; Parameters = @('Snapshot'); Mandatory = @(); Position0 = 'Snapshot' }
        @{ Name = 'Test-SwReparsePoint'; Parameters = @('Path'); Mandatory = @(); Position0 = '' }
        @{ Name = 'Get-SwTreeItems'; Parameters = @('Path', 'SkipUnreadable'); Mandatory = @('Path'); Position0 = '' }
        @{ Name = 'Get-SwSafeDirectoryTreeItems'; Parameters = @('Path', 'WhitelistState'); Mandatory = @('Path'); Position0 = '' }
        @{ Name = 'Get-SwValidatedTreeSize'; Parameters = @('Tree'); Mandatory = @(); Position0 = '' }
        @{ Name = 'Get-SwPathSize'; Parameters = @('Path'); Mandatory = @('Path'); Position0 = '' }
        @{ Name = 'Get-SwPathSizeKB'; Parameters = @('Path'); Mandatory = @(); Position0 = '' }
        @{ Name = 'Add-SwNotMeasured'; Parameters = @('Name', 'Reason'); Mandatory = @(); Position0 = '' }
    )

    $script:Preferences = @('Stop', 'Continue', 'SilentlyContinue')
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:CoreDir = [System.IO.Path]::Combine($script:RepoRoot, 'lib', 'core')
    $script:FileOpsFile = [System.IO.Path]::Combine($script:CoreDir, 'file_ops.ps1')
    $script:OnWindows = [System.IO.Path]::DirectorySeparatorChar -eq '\'
    $script:IsDesktop = $PSVersionTable['PSEdition'] -eq 'Desktop'
    $script:Sep = [string][System.IO.Path]::DirectorySeparatorChar
    $script:WorkCounter = 0
    $script:Links = New-Object System.Collections.Generic.List[string]

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
    # An empty value removes the variable. Since .NET 10 SetEnvironmentVariable(name, "") keeps the
    # variable with an empty value, and PowerShell 7.6 passes a plain $null to the method as "";
    # only [NullString]::Value is a real null.
    function script:Set-Env([string]$Name, [AllowNull()][AllowEmptyString()][string]$Value) {
        if ([string]::IsNullOrEmpty($Value)) { [System.Environment]::SetEnvironmentVariable($Name, [NullString]::Value) }
        else { [System.Environment]::SetEnvironmentVariable($Name, $Value) }
    }

    $script:EnvNames = @('SWEEPR_DRY_RUN', 'SWEEPR_NO_OPLOG', 'SWEEPR_DEBUG', 'SWEEPR_DATA_DIR', '_SWEEPR_OPLOG_RUN_COMMAND', '_SWEEPR_OPLOG_RUN_ID')
    $script:StateNames = @('Config', 'ProtectedPaths', 'ExactProtectedPaths', 'DefaultWhitelistPatterns', 'SweeprCleanPathGuard',
        'SweeprDryRunMode', 'TotalSizeCleaned', 'FilesCleaned', 'TotalItems', 'OwnerCleanups', 'DryRunCollector', 'NotMeasuredCollector',
        'ExportListFile', 'SwWalkBudgetSeconds', 'CurrentSection', 'SweeprOperationsLogFile', 'SweeprOperationsLogStarted',
        'SWEEPR_FILEOPS_LOADED', 'FakeIdentity')
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
    function script:New-Work {
        $script:WorkCounter++
        New-Dir (P $TestDrive ('w' + $script:WorkCounter))
    }
    # Name, kind and length of everything below a folder (no time stamps: Windows moves folder times).
    function script:Get-Listing([string]$Root) {
        if (-not [System.IO.Directory]::Exists($Root)) { return @('<missing>') }
        $rows = New-Object System.Collections.Generic.List[string]
        foreach ($item in @(Get-ChildItem -LiteralPath $Root -Recurse -Force)) {
            $rel = Get-Rel $item.FullName $Root
            if ($item.PSIsContainer) { $rows.Add("D $rel") } else { $rows.Add("F $rel $($item.Length)") }
        }
        , @($rows | Sort-Object)
    }
    function script:Get-Chain([string]$Path) {
        $list = New-Object System.Collections.Generic.List[string]
        $current = [System.IO.Path]::GetFullPath($Path)
        while (-not [string]::IsNullOrEmpty($current)) { $list.Add($current); $current = [System.IO.Path]::GetDirectoryName($current) }
        $list.ToArray()
    }
    # Comparison form of a path: normalized like the module does (Windows PowerShell 5.1 spells a short
    # 8.3 name of the temp folder out), one separator kind, no trailing separator, no case.
    function script:Fold([string]$Path) {
        $text = $Path
        try { if ([System.IO.Path]::IsPathRooted($text)) { $text = [System.IO.Path]::GetFullPath($text) } } catch { $null = $_ }
        $text.Replace('/', '\').TrimEnd('\').ToLowerInvariant()
    }
    # The path below a root, in the spelling of the host (both sides normalized).
    function script:Get-Rel([string]$Path, [string]$Root) {
        $full = [System.IO.Path]::GetFullPath($Path)
        $base = [System.IO.Path]::GetFullPath($Root)
        $full.Substring($base.Length).TrimStart('\', '/')
    }
    # The last segments of a path: how a message names an entry whatever the spelling of the folder above.
    function script:Get-Tail([string]$Path, [int]$Segments = 2) {
        $parts = @($Path.Replace('/', '\').TrimEnd('\').Split('\') | Where-Object { $_.Length -gt 0 })
        $take = [math]::Min($Segments, $parts.Count)
        ($parts[($parts.Count - $take)..($parts.Count - 1)]) -join $script:Sep
    }

    function script:New-TestLink([string]$Link, [string]$Target) {
        if ($script:OnWindows -and [System.IO.Directory]::Exists($Target)) { [void](New-Item -ItemType Junction -Path $Link -Target $Target) }
        else { [void](New-Item -ItemType SymbolicLink -Path $Link -Target $Target) }
        $script:Links.Add($Link)
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

    function script:Set-Whitelist([string[]]$Lines) {
        $file = $script:Config.WhitelistFile
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($file))
        [System.IO.File]::WriteAllText($file, (($Lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding $false))
    }

    function script:Import-FileOps {
        $script:SWEEPR_FILEOPS_LOADED = $false
        . $script:FileOpsFile
    }

    # ---- fakes for the identity functions ---------------------------------------------------------

    # Identity text of a path for the fakes: the texts of all components joined, $null for a missing path,
    # for a link above the entry and for a link as the entry without -AllowLeafLink. Components above the
    # fixture folder are taken as they are. $script:FakeIdentity overrides the text of one component
    # (case-insensitive key), which simulates a replaced entry.
    function script:Get-FakeIdentityText([string]$Path, [bool]$AllowLeafLink) {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
        $full = $null
        try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return $null }
        $texts = New-Object System.Collections.Generic.List[string]
        $current = $full
        $leaf = $true
        while (-not [string]::IsNullOrEmpty($current)) {
            $attributes = $null
            try { $attributes = [System.IO.File]::GetAttributes($current) } catch { return $null }
            $below = $current.StartsWith([System.IO.Path]::GetFullPath($script:Work), [System.StringComparison]::OrdinalIgnoreCase)
            if ($below -and (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
                if (-not $leaf -or -not $AllowLeafLink) { return $null }
            }
            if ($script:FakeIdentity.ContainsKey($current)) { $texts.Add([string]$script:FakeIdentity[$current]) }
            else { $texts.Add('id:' + $current) }
            $leaf = $false
            $current = [System.IO.Path]::GetDirectoryName($current)
        }
        $texts -join '|'
    }
    # Answers like the real functions, with substitute objects (Path, Identity, AllowLeafLink; no Entries,
    # so the module cannot derive a child snapshot and asks for each one).
    function script:Use-FakeIdentity {
        $script:FakeIdentity = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        if ($null -eq (Get-Command -Name Get-SwPathSnapshot -CommandType Function -ErrorAction SilentlyContinue)) { return }
        Mock Get-SwPathSnapshot {
            $text = Get-FakeIdentityText $Path ([bool]$AllowLeafLink)
            if ($null -eq $text) { return $null }
            [pscustomobject]@{ Path = $Path; Identity = $text; AllowLeafLink = [bool]$AllowLeafLink }
        }
        Mock Test-SwPathSnapshot {
            if ($null -eq $Snapshot) { return $false }
            $path = Get-Field $Snapshot 'Path'
            if ([string]::IsNullOrEmpty([string]$path)) { return $false }
            $now = Get-FakeIdentityText ([string]$path) ([bool](Get-Field $Snapshot 'AllowLeafLink'))
            if ($null -eq $now) { return $false }
            [string](Get-Field $Snapshot 'Identity') -eq $now
        }
    }
    # Substitute objects that carry only a path, and an identity test that always agrees.
    function script:Use-SubstituteIdentity {
        Mock Get-SwPathSnapshot { [pscustomobject]@{ Path = $Path } }
        Mock Test-SwPathSnapshot { $true }
    }

    function script:Get-Field($Object, [string]$Name) {
        if ($null -eq $Object) { return $null }
        if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] }; return $null }
        $property = $Object.PSObject.Properties[$Name]
        if ($null -eq $property) { return $null }
        $property.Value
    }
    function script:Test-SameSnapshot($Left, $Right) {
        if ($null -eq $Left -or $null -eq $Right) { return $false }
        if ((Fold ([string]$Left['Path'])) -ne (Fold ([string]$Right['Path']))) { return $false }
        if ([bool]$Left['AllowLeafLink'] -ne [bool]$Right['AllowLeafLink']) { return $false }
        $a = $Left['Entries']; $b = $Right['Entries']
        if ($a.Count -ne $b.Count) { return $false }
        $foldedB = @{}
        foreach ($key in $b.Keys) { $foldedB[(Fold ([string]$key))] = [string]$b[$key] }
        foreach ($key in $a.Keys) {
            $folded = Fold ([string]$key)
            if (-not $foldedB.ContainsKey($folded)) { return $false }
            if ($foldedB[$folded] -ne [string]$a[$key]) { return $false }
        }
        $true
    }

    # Runs a block and gives its output; an exception fails the test. (A plain assignment inside a block
    # that Should invokes does not reach the test, so results are taken through this function.)
    function script:Get-Result([scriptblock]$Block) {
        try { & $Block }
        catch { throw ('unexpected exception: ' + $_.Exception.Message) }
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

    function script:Assert-Result($Actual, [bool]$Expected, [string]$Because) {
        $Actual | Should -BeOfType [bool] -Because $Because
        $Actual | Should -Be $Expected -Because $Because
    }

    # A test that only looks at what loading leaves behind first needs the functions to exist.
    function script:Assert-Defined([string[]]$Names) {
        foreach ($name in $Names) {
            ($null -ne (Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue)) | Should -BeTrue -Because "$name must be defined after loading"
        }
    }

    # The body of a function as it is now, or $null when the function does not exist (the tests that need
    # it then fail on their own).
    function script:Get-OriginalBlock([string]$Name) {
        $command = Get-Command -Name $Name -CommandType Function -ErrorAction SilentlyContinue
        if ($null -eq $command) { return $null }
        $command.ScriptBlock
    }

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
            $default = ''
            if ($null -ne $parameter.DefaultValue) { $default = $parameter.DefaultValue.Extent.Text }
            $lines += ('{0}|{1}|pos={2}|mandatory={3}|default={4}' -f $paramName, $meta.ParameterType.FullName, $position, $mandatory, $default)
        }
        , $lines
    }

    # ---- child processes --------------------------------------------------------------------------

    function script:Invoke-ChildPowerShell {
        param([string]$Script, [string]$WorkingDirectory = $TestDrive, [hashtable]$Environment = @{}, [string[]]$RemoveEnvironment = @())
        $exe = (Get-Process -Id $PID).Path
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Script))
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.WorkingDirectory = $WorkingDirectory
        foreach ($name in $RemoveEnvironment) { if ($psi.EnvironmentVariables.ContainsKey($name)) { $psi.EnvironmentVariables.Remove($name) } }
        foreach ($name in $Environment.Keys) { $psi.EnvironmentVariables[$name] = [string]$Environment[$name] }
        $process = [System.Diagnostics.Process]::Start($psi)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { $process.Kill(); throw 'child PowerShell timed out' }
        [pscustomobject]@{ ExitCode = $process.ExitCode; Out = $stdout.Result; Err = $stderr.Result }
    }
    # Windows PowerShell serializes progress records into redirected stderr as CLIXML. That is the host
    # talking, not the loaded file: drop the progress records and the envelope, keep anything else.
    function script:Get-ChildStderr([string]$Text) {
        if ([string]::IsNullOrEmpty($Text)) { return '' }
        $clean = [regex]::Replace($Text, '(?s)<Obj S="progress".*?</Obj>', '')
        $clean = [regex]::Replace($clean, '<Objs[^>]*>|</Objs>|#< CLIXML', '')
        $clean.Trim()
    }
    function script:ConvertTo-TestLiteral([string]$Value) { "'" + $Value.Replace("'", "''") + "'" }

    # ---- per-test state ---------------------------------------------------------------------------

    function script:Start-Case {
        $script:SavedState = Save-State
        $script:SavedEnv = Save-Env $script:EnvNames
    }
    function script:Stop-Case {
        Clear-TestLinks
        Restore-Env $script:SavedEnv
        Restore-State $script:SavedState
    }

    # What the whole file changes in the process, put back after the last test.
    $script:RootState = Save-State
    $script:RootEnv = Save-Env $script:EnvNames
    $script:RootDirectory = [System.Environment]::CurrentDirectory
    . $script:FileOpsFile
    # The real identity functions, for tests that count calls and pass them on.
    $script:RealGet = Get-OriginalBlock 'Get-SwPathSnapshot'
    $script:RealTest = Get-OriginalBlock 'Test-SwPathSnapshot'
}

AfterAll {
    Clear-TestLinks
    Restore-State $script:RootState
    Restore-Env $script:RootEnv
    [System.Environment]::CurrentDirectory = $script:RootDirectory
}

# ============================================================================
# Loading
# ============================================================================

Describe 'Loading file_ops.ps1' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        $script:Work = New-Work
        $script:SweeprOperationsLogFile = P $script:Work 'oplog' 'operations.log'
        Set-Env 'SWEEPR_NO_OPLOG' '1'
    }
    AfterEach { Stop-Case }

    It 'G-1 keeps dry-run state, statistics, collectors and variables on a second load without the marker' {
        $collector = New-Object 'System.Collections.Generic.List[object]'
        $script:SweeprDryRunMode = $true
        $script:FilesCleaned = 5
        $script:TotalSizeCleaned = 7
        $script:TotalItems = 3
        $script:OwnerCleanups = 2
        $script:DryRunCollector = $collector
        $script:SwWalkBudgetSeconds = 99
        . $script:FileOpsFile
        Assert-Defined 'Test-SwDryRunMode', 'Get-SwCleanupStats'
        $script:SweeprDryRunMode | Should -BeTrue
        $script:FilesCleaned | Should -Be 5
        $script:TotalSizeCleaned | Should -Be 7
        $script:TotalItems | Should -Be 3
        $script:OwnerCleanups | Should -Be 2
        [object]::ReferenceEquals($script:DryRunCollector, $collector) | Should -BeTrue
        $script:SwWalkBudgetSeconds | Should -Be 99
    }

    It 'G-1 evaluates SWEEPR_DRY_RUN again when the marker is $false and the value is 1' {
        Set-Env 'SWEEPR_DRY_RUN' '1'
        $script:SweeprDryRunMode = $false
        Import-FileOps
        Assert-Result (Test-SwDryRunMode) $true 'value 1'
    }

    It 'G-1 gives a real run for every value of SWEEPR_DRY_RUN other than 1 (<Value>)' -ForEach @(
        @{ Name = 'empty'; Value = '' }
        @{ Name = 'zero'; Value = '0' }
        @{ Name = 'true'; Value = 'true' }
        @{ Name = 'yes'; Value = 'yes' }
        @{ Name = 'two'; Value = '2' }
        @{ Name = 'one with a blank'; Value = '1 ' }
    ) {
        Set-Env 'SWEEPR_DRY_RUN' $Value
        $script:SweeprDryRunMode = $true
        Import-FileOps
        Assert-Result (Test-SwDryRunMode) $false "value '$Value'"
    }

    It 'G-1 gives a real run when SWEEPR_DRY_RUN is not set' {
        Set-Env 'SWEEPR_DRY_RUN' $null
        $script:SweeprDryRunMode = $true
        Import-FileOps
        Assert-Result (Test-SwDryRunMode) $false 'not set'
    }

    It 'G-1 reads SWEEPR_DRY_RUN only while loading: a later change without the marker does nothing' {
        Set-Env 'SWEEPR_DRY_RUN' '0'
        Import-FileOps
        Assert-Result (Test-SwDryRunMode) $false 'after load'
        Set-Env 'SWEEPR_DRY_RUN' '1'
        . $script:FileOpsFile
        Assert-Result (Test-SwDryRunMode) $false 'after a load without the marker'
    }

    It 'G-1 resets statistics and collectors to their starting values when the marker is $false' {
        $script:FilesCleaned = 5
        $script:TotalSizeCleaned = 7
        $script:TotalItems = 3
        $script:OwnerCleanups = 2
        $script:DryRunCollector = New-Object 'System.Collections.Generic.List[object]'
        $script:NotMeasuredCollector = New-Object 'System.Collections.Generic.List[object]'
        Import-FileOps
        $script:FilesCleaned | Should -Be 0
        $script:TotalSizeCleaned | Should -Be 0
        $script:TotalItems | Should -Be 0
        $script:OwnerCleanups | Should -Be 0
        $script:DryRunCollector | Should -BeNullOrEmpty
        $script:NotMeasuredCollector | Should -BeNullOrEmpty
    }

    It 'G-1 reloads repeatedly without failing on native helper types that are registered already' {
        # The first call compiles the helper types where the host has a Windows file API.
        $null = Get-SwPathSnapshot -Path $script:Work
        { Import-FileOps; Import-FileOps; Import-FileOps } | Should -Not -Throw
        $null = Get-SwPathSnapshot -Path $script:Work
        { Import-FileOps } | Should -Not -Throw
    }

    It 'G-3 compiles no native type and starts nothing while loading' {
        Assert-Defined 'Get-SwPathSnapshot', 'Remove-SwItem'
        Mock Add-Type { }
        Mock Start-Process { }
        Mock Invoke-WebRequest { }
        Mock Invoke-RestMethod { }
        Mock Get-ItemProperty { }
        Mock Out-File { }
        Mock Set-Content { }
        Mock Add-Content { }
        Mock New-Item { }
        Import-FileOps
        foreach ($name in 'Add-Type', 'Start-Process', 'Invoke-WebRequest', 'Invoke-RestMethod', 'Get-ItemProperty', 'Out-File', 'Set-Content', 'Add-Content', 'New-Item') {
            Should -Invoke -CommandName $name -Times 0 -Exactly -Because "loading must not call $name"
        }
    }

    It 'G-3 writes nothing to the pipeline and creates nothing when it loads' {
        Assert-Defined 'Test-SwDryRunMode', 'Remove-SwItem'
        $before = Get-Listing $script:Work
        $output = @(. $script:FileOpsFile)
        $output.Count | Should -Be 0
        $script:SWEEPR_FILEOPS_LOADED = $false
        $output = @(. $script:FileOpsFile)
        $output.Count | Should -Be 0
        (Get-Listing $script:Work) -join '|' | Should -BeExactly ($before -join '|')
        [System.IO.File]::Exists($script:SweeprOperationsLogFile) | Should -BeFalse
    }

    It 'G-3 loads in a fresh process after base.ps1 without output, error or a created folder' {
        $data = P $script:Work 'child-data'
        $code = @"
`$ErrorActionPreference = 'Stop'
. $(ConvertTo-TestLiteral (P $script:CoreDir 'base.ps1'))
. $(ConvertTo-TestLiteral $script:FileOpsFile)
if (-not (Get-Command Remove-SwItem -CommandType Function -ErrorAction SilentlyContinue)) { throw 'Remove-SwItem is not defined after loading' }
"@
        $result = Invoke-ChildPowerShell -Script $code -Environment @{ SWEEPR_DATA_DIR = $data } -RemoveEnvironment @('SWEEPR_DRY_RUN', 'SWEEPR_DEBUG')
        $result.ExitCode | Should -Be 0
        $result.Out.Trim() | Should -BeNullOrEmpty
        (Get-ChildStderr $result.Err) | Should -BeNullOrEmpty
        [System.IO.Directory]::Exists($data) | Should -BeFalse
    }

    It 'G-2 takes base.ps1 and log.ps1 from the folder of the file and not from the working directory' {
        $root = P $script:Work 'fake-root'
        $core = New-Dir (P $root 'lib' 'core')
        foreach ($name in 'file_ops.ps1', 'base.ps1', 'log.ps1') { [System.IO.File]::Copy((P $script:CoreDir $name), (P $core $name), $true) }
        $cwd = New-Dir (P $script:Work 'decoy-cwd')
        foreach ($name in 'base.ps1', 'log.ps1', 'file_ops.ps1') { [System.IO.File]::WriteAllText((P $cwd $name), "throw 'a decoy from the working directory was loaded'") }
        $decoyLib = New-Dir (P $cwd 'lib' 'core')
        foreach ($name in 'base.ps1', 'log.ps1') { [System.IO.File]::WriteAllText((P $decoyLib $name), "throw 'a decoy from the working directory was loaded'") }
        $code = @"
`$ErrorActionPreference = 'Stop'
. $(ConvertTo-TestLiteral (P $core 'file_ops.ps1'))
foreach (`$name in 'Test-SwSafePath', 'Test-SwProtectedPath', 'Resolve-SwSafePath', 'Get-SwWhitelistState', 'Test-SwWhitelisted', 'Format-SwByteSize', 'Get-SwColor', 'Write-SweeprOperation', 'Write-DryRun', 'Write-Success', 'Set-SectionActivity', 'Test-SafePath', 'Test-ProtectedPath', 'Get-SweeprColor') {
    if (-not (Get-Command `$name -ErrorAction SilentlyContinue)) { 'missing:' + `$name }
}
'done'
"@
        $result = Invoke-ChildPowerShell -Script $code -WorkingDirectory $cwd -RemoveEnvironment @('SWEEPR_DEBUG')
        (Get-ChildStderr $result.Err) | Should -BeNullOrEmpty
        $result.Out.Trim() | Should -BeExactly 'done'
        $result.ExitCode | Should -Be 0
    }

    It 'G-5 sets strict mode and the error preference Stop when it loads, and starts with a budget of 15 seconds' {
        $code = @"
`$ErrorActionPreference = 'Continue'
Set-StrictMode -Off
. $(ConvertTo-TestLiteral $script:FileOpsFile)
'eap=' + `$ErrorActionPreference
try { `$null = `$undefinedVariableForTheTest; 'strict=off' } catch { 'strict=on' }
'budget=' + `$script:SwWalkBudgetSeconds
'dry=' + (Test-SwDryRunMode)
'marker=' + `$script:SWEEPR_FILEOPS_LOADED
"@
        $result = Invoke-ChildPowerShell -Script $code -Environment @{ SWEEPR_DRY_RUN = '1' }
        $lines = @($result.Out -split "`r?`n" | Where-Object { $_ })
        $lines | Should -Contain 'eap=Stop'
        $lines | Should -Contain 'strict=on'
        $lines | Should -Contain 'budget=15'
        $lines | Should -Contain 'dry=True'
        $lines | Should -Contain 'marker=True'
    }

    It 'G-5 sets strict mode and the error preference again on a second load without the marker' {
        Assert-Defined 'Test-SwDryRunMode'
        $ErrorActionPreference = 'Continue'
        Set-StrictMode -Off
        . $script:FileOpsFile
        $ErrorActionPreference | Should -Be 'Stop'
        { $null = $undefinedVariableForTheTest } | Should -Throw
    }
}

Describe 'Source rules of file_ops.ps1' {
    BeforeAll {
        $script:SourceBytes = [System.IO.File]::ReadAllBytes($script:FileOpsFile)
        $script:SourceTokens = $null
        $script:SourceErrors = $null
        $script:SourceAst = [System.Management.Automation.Language.Parser]::ParseFile($script:FileOpsFile, [ref]$script:SourceTokens, [ref]$script:SourceErrors)
    }
    BeforeEach {
        # The rules below judge the module, so they need a module that defines its functions.
        Assert-Defined 'Test-SwSafePath', 'Get-SwTreeItems', 'Remove-SwItem'
    }

    It 'G-4 is ASCII or UTF-8 with a byte order mark' {
        $bytes = $script:SourceBytes
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count
        ($nonAscii -eq 0 -or $hasBom) | Should -BeTrue
    }

    It 'G-4 parses without errors' {
        @($script:SourceErrors).Count | Should -Be 0
    }

    It 'G-4 uses no syntax that only PowerShell 7 reads' {
        $only7 = @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark')
        $found = @($script:SourceTokens | Where-Object { $_.Kind.ToString() -in $only7 } | ForEach-Object { "$($_.Kind) at line $($_.Extent.StartLineNumber)" })
        $found | Should -BeNullOrEmpty
        $nodes = @($script:SourceAst.FindAll({ param($n) $n.GetType().Name -in @('TernaryExpressionAst', 'PipelineChainAst', 'NullConditionalMemberExpressionAst') }, $true))
        $nodes.Count | Should -Be 0
        $parallel = @($script:SourceAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandParameterAst] -and $n.ParameterName -eq 'Parallel' }, $true))
        $parallel.Count | Should -Be 0
    }

    It 'F-12 does not use the Recurse parameter of Get-ChildItem' {
        $calls = @($script:SourceAst.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Get-ChildItem', 'gci', 'dir', 'ls') -and
                    @($n.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -match '^(r|re|rec|recu|recur|recurs|recurse)$' }).Count -gt 0
                }, $true))
        $calls.Count | Should -Be 0
    }

    It 'G-4 does not call Get-WmiObject' {
        $calls = @($script:SourceAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-WmiObject' }, $true))
        $calls.Count | Should -Be 0
    }

    It 'G-4 keeps embedded C# within what the compiler of Windows PowerShell 5.1 reads (no ?., string interpolation, nameof, expression bodies)' {
        $strings = @($script:SourceAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -match '\bclass\s+\w+' -and $n.Value -match 'using\s+System' }, $true))
        foreach ($node in $strings) {
            $code = [regex]::Replace([regex]::Replace($node.Value, '(?s)/\*.*?\*/', ''), '//[^\r\n]*', '')
            $code | Should -Not -Match '\?\.' -Because 'null-conditional member access needs C# 6'
            $code | Should -Not -Match '\$@?"' -Because 'string interpolation needs C# 6'
            $code | Should -Not -Match '\bnameof\s*\(' -Because 'nameof needs C# 6'
            $code | Should -Not -Match '=>' -Because 'expression bodies need C# 6'
            $code | Should -Not -Match '\?\[' -Because 'null-conditional indexing needs C# 6'
        }
    }
}

# ============================================================================
# Test-SwSafePath
# ============================================================================

Describe 'Test-SwSafePath' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        $script:Work = New-Work
        $script:Target = New-Dir (P $script:Work 'target')
        $script:Prot = New-Dir (P $script:Work 'protected')
        $script:Data = P $script:Work 'appdata'
        $script:Config = @{ ConfigPath = (P $script:Data 'config'); CachePath = (P $script:Data 'cache'); WhitelistFile = (P $script:Data 'config' 'whitelist.txt') }
        $script:DefaultWhitelistPatterns = @()
        $script:ProtectedPaths = @($script:Prot)
        $script:ExactProtectedPaths = @()
        $script:SweeprCleanPathGuard = $false
        $script:SweeprOperationsLogFile = P $script:Work 'oplog' 'operations.log'
        Set-Env 'SWEEPR_NO_OPLOG' '1'
    }
    AfterEach { Stop-Case }

    It 'F-1 gives true when neither spelling is protected or whitelisted' {
        $path = P $script:Target 'a'
        Mock Resolve-SwSafePath { $script:Answer }
        Mock Test-SwProtectedPath { $false }
        Mock Test-SwWhitelisted { $false }
        $script:Answer = $path
        Assert-Result (Test-SwSafePath -Path $path) $true 'unprotected path'
    }

    It 'F-1 gives false when the path is protected' {
        $path = P $script:Target 'a'
        Mock Resolve-SwSafePath { $script:Answer }
        Mock Test-SwProtectedPath { $true }
        Mock Test-SwWhitelisted { $false }
        $script:Answer = $path
        Assert-Result (Test-SwSafePath -Path $path) $false 'protected path'
    }

    It 'F-1 gives false when the whitelist keeps the path' {
        $path = P $script:Target 'a'
        Mock Resolve-SwSafePath { $script:Answer }
        Mock Test-SwProtectedPath { $false }
        Mock Test-SwWhitelisted { $true }
        $script:Answer = $path
        Assert-Result (Test-SwSafePath -Path $path) $false 'whitelisted path'
    }

    It 'F-1 returns exactly one boolean to the pipeline' {
        $path = P $script:Target 'a'
        $result = @(Test-SwSafePath -Path $path)
        $result.Count | Should -Be 1
        $result[0] | Should -BeOfType [bool]
    }

    It 'F-1 uses the protection lists and the whitelist: protected folder and below, exact entry, whitelisted entry' {
        $homeDir = New-Dir (P $script:Work 'home')
        $script:ExactProtectedPaths = @($homeDir)
        $keep = New-Dir (P $script:Target 'keep')
        Set-Whitelist @($keep)
        Assert-Result (Test-SwSafePath -Path $script:Prot) $false 'the protected folder'
        Assert-Result (Test-SwSafePath -Path (P $script:Prot 'child')) $false 'below the protected folder'
        Assert-Result (Test-SwSafePath -Path $homeDir) $false 'the exactly protected folder'
        Assert-Result (Test-SwSafePath -Path (P $homeDir 'cache')) $true 'below the exactly protected folder'
        Assert-Result (Test-SwSafePath -Path $keep) $false 'the whitelisted entry'
        Assert-Result (Test-SwSafePath -Path ($keep + '2')) $true 'a sibling that only begins like the whitelisted entry'
        Assert-Result (Test-SwSafePath -Path (P $script:Target 'plain.txt')) $true 'an ordinary path'
    }

    It 'F-1 has the opposite polarity of Test-SwProtectedPath' {
        $path = P $script:Prot 'child'
        (Test-SwProtectedPath -Path $path) | Should -BeTrue
        (Test-SwSafePath -Path $path) | Should -BeFalse
        $other = P $script:Target 'x'
        (Test-SwProtectedPath -Path $other) | Should -BeFalse
        (Test-SwSafePath -Path $other) | Should -BeTrue
    }

    It 'F-1 changes nothing in the file system' {
        $file = New-File (P $script:Target 'a.txt') 10
        New-File (P $script:Target 'sub' 'b.txt') 20 | Out-Null
        $before = Get-Listing $script:Work
        $null = Test-SwSafePath -Path $file
        $null = Test-SwSafePath -Path (P $script:Target 'sub')
        $null = Test-SwSafePath -Path (P $script:Prot 'missing')
        (Get-Listing $script:Work) -join '|' | Should -BeExactly ($before -join '|')
    }

    It 'F-2 rejects an empty path with a binding error' {
        $failure = Assert-Throws { Test-SwSafePath -Path '' }
        $failure.Exception | Should -BeOfType [System.Management.Automation.ParameterBindingException]
    }

    It 'F-2 rejects a null path with a binding error' {
        $failure = Assert-Throws { Test-SwSafePath -Path $null }
        $failure.Exception | Should -BeOfType [System.Management.Automation.ParameterBindingException]
    }

    It 'F-2 gives false for a path of white space only (<Label>)' -ForEach @(
        @{ Label = 'spaces'; Text = '   ' }
        @{ Label = 'a tab'; Text = "`t" }
        @{ Label = 'a single space'; Text = ' ' }
    ) {
        Assert-Result (Test-SwSafePath -Path $Text) $false $Label
    }

    It 'F-2 gives false and asks nothing else when the path cannot be resolved' {
        Mock Resolve-SwSafePath { $null }
        Mock Test-SwProtectedPath { $false }
        Mock Test-SwWhitelisted { $false }
        Assert-Result (Test-SwSafePath -Path (P $script:Target 'a')) $false 'unresolvable'
        Should -Invoke -CommandName Test-SwProtectedPath -Times 0 -Exactly
        Should -Invoke -CommandName Test-SwWhitelisted -Times 0 -Exactly
    }

    It 'F-3 asks once for each question when both spellings are the same' {
        $path = P $script:Target 'a'
        Mock Resolve-SwSafePath { $script:Answer }
        Mock Test-SwProtectedPath { $false }
        Mock Test-SwWhitelisted { $false }
        $script:Answer = [System.IO.Path]::GetFullPath($path)
        $null = Test-SwSafePath -Path $path
        Should -Invoke -CommandName Test-SwProtectedPath -Times 1 -Exactly
        Should -Invoke -CommandName Test-SwWhitelisted -Times 1 -Exactly
    }

    It 'F-3 treats spellings that differ only in case or a trailing backslash as the same' {
        $path = P $script:Target 'a'
        Mock Resolve-SwSafePath { $script:Answer }
        Mock Test-SwProtectedPath { $false }
        Mock Test-SwWhitelisted { $false }
        $script:Answer = [System.IO.Path]::GetFullPath($path).ToUpperInvariant() + '\'
        $null = Test-SwSafePath -Path $path
        Should -Invoke -CommandName Test-SwProtectedPath -Times 1 -Exactly
        Should -Invoke -CommandName Test-SwWhitelisted -Times 1 -Exactly
    }

    It 'F-3 asks the lexical spelling first and then the final spelling, protection before whitelist for each' {
        $typed = P $script:Target 'typed'
        $lexical = [System.IO.Path]::GetFullPath($typed)
        $final = P $script:Target 'final'
        $script:Answer = $final
        $script:Events = New-Object System.Collections.Generic.List[string]
        Mock Resolve-SwSafePath { $script:Answer }
        Mock Test-SwProtectedPath { $script:Events.Add('protected:' + $Path + ':' + [bool]$AlreadyResolved); $false }
        Mock Test-SwWhitelisted { $script:Events.Add('whitelisted:' + $Path); $false }
        Assert-Result (Test-SwSafePath -Path $typed) $true 'neither spelling hit'
        @($script:Events) | Should -Be @(
            ('protected:' + $lexical + ':True'), ('whitelisted:' + $lexical),
            ('protected:' + $final + ':True'), ('whitelisted:' + $final))
    }

    It 'F-3 stops at the first hit: a protected lexical spelling ends the check' {
        $typed = P $script:Target 'typed'
        $script:Answer = P $script:Target 'final'
        Mock Resolve-SwSafePath { $script:Answer }
        Mock Test-SwProtectedPath { $true }
        Mock Test-SwWhitelisted { $false }
        Assert-Result (Test-SwSafePath -Path $typed) $false 'protected lexical spelling'
        Should -Invoke -CommandName Test-SwProtectedPath -Times 1 -Exactly
        Should -Invoke -CommandName Test-SwWhitelisted -Times 0 -Exactly
    }

    It 'F-3 stops at the first hit: a whitelisted lexical spelling ends the check before the final spelling' {
        $typed = P $script:Target 'typed'
        $script:Answer = P $script:Target 'final'
        Mock Resolve-SwSafePath { $script:Answer }
        Mock Test-SwProtectedPath { $false }
        Mock Test-SwWhitelisted { $true }
        Assert-Result (Test-SwSafePath -Path $typed) $false 'whitelisted lexical spelling'
        Should -Invoke -CommandName Test-SwProtectedPath -Times 1 -Exactly
        Should -Invoke -CommandName Test-SwWhitelisted -Times 1 -Exactly
    }

    It 'F-3 gives false when only the final spelling is protected' {
        $typed = P $script:Target 'typed'
        $final = P $script:Target 'final'
        $script:Answer = $final
        $script:FinalSpelling = $final
        Mock Resolve-SwSafePath { $script:Answer }
        Mock Test-SwProtectedPath { $Path -eq $script:FinalSpelling }
        Mock Test-SwWhitelisted { $false }
        Assert-Result (Test-SwSafePath -Path $typed) $false 'protected final spelling'
        Should -Invoke -CommandName Test-SwProtectedPath -Times 2 -Exactly
    }

    It 'F-3 gives false when only the final spelling is whitelisted' {
        $typed = P $script:Target 'typed'
        $final = P $script:Target 'final'
        $script:Answer = $final
        $script:FinalSpelling = $final
        Mock Resolve-SwSafePath { $script:Answer }
        Mock Test-SwProtectedPath { $false }
        Mock Test-SwWhitelisted { $Path -eq $script:FinalSpelling }
        Assert-Result (Test-SwSafePath -Path $typed) $false 'whitelisted final spelling'
    }

    It 'F-3 gives true for a path under a parent folder that no list names (drive root, parent of a protected folder)' {
        $root = [System.IO.Path]::GetPathRoot($script:Work)
        Assert-Result (Test-SwSafePath -Path $root) $true 'the root of the drive'
        Assert-Result (Test-SwSafePath -Path $script:Work) $true 'the parent of a protected folder'
        $inside = New-Dir (P $script:Work 'parent-of-protected')
        $script:ProtectedPaths = @((P $inside 'protected'))
        Assert-Result (Test-SwSafePath -Path (P $inside 'file.txt')) $true 'a sibling of the protected folder'
    }

    It 'F-4 reads the whitelist state once per call when none is given' {
        $script:RealState = Get-SwWhitelistState
        Mock Get-SwWhitelistState { $script:RealState }
        $null = Test-SwSafePath -Path (P $script:Target 'a')
        Should -Invoke -CommandName Get-SwWhitelistState -Times 1 -Exactly
    }

    It 'F-4 reads the state once for both spellings of a path' {
        $script:RealState = Get-SwWhitelistState
        $script:Answer = P $script:Target 'final'
        Mock Resolve-SwSafePath { $script:Answer }
        Mock Get-SwWhitelistState { $script:RealState }
        $null = Test-SwSafePath -Path (P $script:Target 'typed')
        Should -Invoke -CommandName Get-SwWhitelistState -Times 1 -Exactly
    }

    It 'F-4 never reads the state when one is given, and uses the given object for both spellings' {
        $script:Given = Get-SwWhitelistState
        $script:Answer = P $script:Target 'final'
        Mock Resolve-SwSafePath { $script:Answer }
        Mock Get-SwWhitelistState { throw 'the state must not be read' }
        Mock Test-SwWhitelisted { $false }
        $null = Test-SwSafePath -Path (P $script:Target 'typed') -WhitelistState $script:Given
        Should -Invoke -CommandName Get-SwWhitelistState -Times 0 -Exactly
        Should -Invoke -CommandName Test-SwWhitelisted -Times 2 -Exactly -ParameterFilter { [object]::ReferenceEquals($State, $script:Given) }
    }

    It 'F-4 reads no state for a path that is refused before' {
        Mock Get-SwWhitelistState { @{ KeepAll = $false; Rows = (New-Object 'System.Collections.Generic.List[object]') } }
        $null = Test-SwSafePath -Path '   '
        Should -Invoke -CommandName Get-SwWhitelistState -Times 0 -Exactly
    }

    It 'F-4 makes every path false with a keep-everything state (unreadable whitelist)' {
        New-Dir $script:Config.WhitelistFile | Out-Null
        $state = Get-SwWhitelistState
        $state['KeepAll'] | Should -BeTrue
        Assert-Result (Test-SwSafePath -Path (P $script:Target 'a') -WhitelistState $state) $false 'with the given state'
        Assert-Result (Test-SwSafePath -Path (P $script:Target 'a')) $false 'with the state read now'
    }

    It 'F-4 does not keep the state between calls: a changed whitelist file counts at the next call' {
        $entry = P $script:Target 'later'
        Assert-Result (Test-SwSafePath -Path $entry) $true 'before the entry is listed'
        Set-Whitelist @($entry)
        Assert-Result (Test-SwSafePath -Path $entry) $false 'after the entry is listed'
        Set-Whitelist @()
        Assert-Result (Test-SwSafePath -Path $entry) $true 'after the entry is removed again'
    }

    It 'F-5 looks only at the given path: a folder with a protected or whitelisted child and a child of a protected parent are judged on their own' {
        $dir = New-Dir (P $script:Target 'dir')
        $keep = New-Dir (P $dir 'keep')
        Set-Whitelist @($keep)
        Assert-Result (Test-SwSafePath -Path $dir) $true 'a folder that contains a whitelisted entry'
        Assert-Result (Test-SwSafePath -Path $keep) $false 'the whitelisted entry itself'
        $script:ProtectedPaths = @((P $dir 'inner-protected'))
        Assert-Result (Test-SwSafePath -Path $dir) $true 'a folder that contains a protected folder'
    }

    It 'F-6 gives false and does not throw when the protection question throws' {
        Mock Test-SwProtectedPath { throw 'protection-canary' }
        Assert-Result (Test-SwSafePath -Path (P $script:Target 'a')) $false 'protection throws'
    }

    It 'F-6 gives false and does not throw when the whitelist question throws' {
        Mock Test-SwWhitelisted { throw 'whitelist-canary' }
        Assert-Result (Test-SwSafePath -Path (P $script:Target 'a')) $false 'whitelist throws'
    }

    It 'F-6 gives false and does not throw when the final spelling cannot be asked' {
        Mock Resolve-SwSafePath { throw 'resolve-canary' }
        Assert-Result (Test-SwSafePath -Path (P $script:Target 'a')) $false 'resolution throws'
    }

    It 'F-6 gives false and does not throw when the whitelist state cannot be read' {
        Mock Get-SwWhitelistState { throw 'state-canary' }
        Assert-Result (Test-SwSafePath -Path (P $script:Target 'a')) $false 'state throws'
    }

    It 'F-6 does not throw for odd text (<Label>) and gives a single boolean' -ForEach $script:HostileText {
        $result = @(Get-Result { Test-SwSafePath -Path $Text })
        $result.Count | Should -Be 1
        $result[0] | Should -BeOfType [bool]
    }

    It 'F-6 gives false for a path with a NUL character' {
        Assert-Result (Test-SwSafePath -Path ('a' + [char]0 + 'b')) $false 'NUL'
    }

    It 'G-7 reads the whitelist file at each call' {
        $script:RealState = Get-SwWhitelistState
        Mock Get-SwWhitelistState { $script:RealState }
        $null = Test-SwSafePath -Path (P $script:Target 'a')
        $null = Test-SwSafePath -Path (P $script:Target 'b')
        Should -Invoke -CommandName Get-SwWhitelistState -Times 2 -Exactly
    }

    It 'G-5 gives the same answers under every error preference (<Preference>)' -ForEach @(
        @{ Preference = 'Stop' }
        @{ Preference = 'Continue' }
        @{ Preference = 'SilentlyContinue' }
    ) {
        $keep = P $script:Target 'keep'
        Set-Whitelist @($keep)
        $ErrorActionPreference = $Preference
        $records = @(& {
                Test-SwSafePath -Path (P $script:Prot 'x')
                Test-SwSafePath -Path $keep
                Test-SwSafePath -Path (P $script:Target 'free')
                Test-SwSafePath -Path ('a' + [char]0 + 'b')
            } 2>&1)
        @($records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count | Should -Be 0
        @($records | ForEach-Object { [string]$_ }) | Should -Be @('False', 'False', 'True', 'False')
    }
}

Describe 'Test-SwSafePath on Windows file names [W]' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        $script:Work = New-Work
        $script:Data = P $script:Work 'appdata'
        $script:Config = @{ ConfigPath = (P $script:Data 'config'); CachePath = (P $script:Data 'cache'); WhitelistFile = (P $script:Data 'config' 'whitelist.txt') }
        $script:DefaultWhitelistPatterns = @()
        $script:ExactProtectedPaths = @()
        $script:SweeprCleanPathGuard = $false
    }
    AfterEach { Stop-Case }

    It 'F-3 [W] refuses the 8.3 spelling of an existing protected folder and of its child' {
        $long = New-Dir (P $script:Work 'Protected Long Folder Name')
        New-File (P $long 'child.txt') 1 | Out-Null
        $fso = New-Object -ComObject Scripting.FileSystemObject
        $short = $fso.GetFolder($long).ShortPath
        if ($short -ieq $long) { Set-ItResult -Skipped -Because '8.3 names are disabled on this volume'; return }
        $script:ProtectedPaths = @($long)
        Assert-Result (Test-SwSafePath -Path $short) $false 'the short spelling of the folder'
        Assert-Result (Test-SwSafePath -Path (P $short 'child.txt')) $false 'the short spelling with an existing child'
    }

    It 'F-3 [W] refuses a path whose list entry uses the other spelling of the same temp folder' {
        $prot = New-Dir (P $script:Work 'prot-spelling')
        New-File (P $prot 'child.txt') 1 | Out-Null
        $final = Resolve-SwSafePath -Path $prot
        $script:ProtectedPaths = @($final)
        Assert-Result (Test-SwSafePath -Path (P $prot 'child.txt')) $false 'typed spelling below a list entry in final spelling'
        $script:ProtectedPaths = @($prot)
        Assert-Result (Test-SwSafePath -Path (P $final 'child.txt')) $false 'final spelling below a list entry in typed spelling'
    }

    It 'F-3 [W] accepts a path in the temp folder as the host spells it, including an 8.3 spelling' {
        $script:ProtectedPaths = @((P $script:Work 'protected-elsewhere'))
        Assert-Result (Test-SwSafePath -Path $env:TEMP) $true 'the TEMP folder as set'
        Assert-Result (Test-SwSafePath -Path (P $env:TEMP 'Example' 'child.txt')) $true 'a planned child below TEMP'
        $existing = New-File (P $script:Work 'free' 'a.txt') 1
        Assert-Result (Test-SwSafePath -Path $existing) $true 'an existing file in the test drive'
    }

    It 'F-3 [W] refuses a path with a trailing dot in a segment of a protected folder' {
        $prot = New-Dir (P $script:Work 'prot-dot')
        $script:ProtectedPaths = @($prot)
        Assert-Result (Test-SwSafePath -Path ($prot + '.\child')) $false 'trailing dot in the folder name'
        Assert-Result (Test-SwSafePath -Path ($prot + '.')) $false 'trailing dot on the folder itself'
    }

    It 'F-3 [W] refuses a path below a junction to a protected folder' {
        $prot = New-Dir (P $script:Work 'prot-target')
        New-File (P $prot 'child.txt') 1 | Out-Null
        $script:ProtectedPaths = @($prot)
        $link = P $script:Work 'J'
        New-TestLink $link $prot
        try {
            Assert-Result (Test-SwSafePath -Path (P $link 'child.txt')) $false 'file below the junction'
            Assert-Result (Test-SwSafePath -Path $link) $false 'the junction itself'
        }
        finally { Remove-TestLink $link }
    }

    It 'F-3 [W] keeps the segment rule for a typed path and drops it for the final spelling of a junction named like a secret folder' {
        $parent = New-Dir (P $script:Work 'home' 'AppData' 'Roaming' 'Microsoft')
        $target = New-Dir (P $script:Work 'cred-target')
        New-File (P $target 'blob') 1 | Out-Null
        $script:ProtectedPaths = @((P $script:Work 'unrelated'))
        $link = P $parent 'Credentials'
        New-TestLink $link $target
        try {
            Assert-Result (Test-SwSafePath -Path (P $link 'blob')) $false 'typed spelling carries the segment'
            Assert-Result (Test-SwSafePath -Path (P $target 'blob')) $true 'plain target spelling has no protected segment'
        }
        finally { Remove-TestLink $link }
    }

    It 'F-3 [W] keeps a whitelisted junction row in both spellings' {
        $script:ProtectedPaths = @((P $script:Work 'unrelated'))
        $target = New-Dir (P $script:Work 'T')
        New-File (P $target 'registry') 1 | Out-Null
        $link = P $script:Work 'L'
        New-TestLink $link $target
        try {
            Set-Whitelist @($link)
            Assert-Result (Test-SwSafePath -Path (P $link 'registry')) $false 'below the junction row'
            Assert-Result (Test-SwSafePath -Path (P $target 'registry')) $false 'below its target'
        }
        finally { Remove-TestLink $link }
    }

    It 'F-3 [W] refuses a whitelisted entry named in the final spelling when the path is typed with the 8.3 temp folder' {
        $dir = New-Dir (P $script:Work 'wl-spelling')
        $keep = New-File (P $dir 'keep.txt') 1
        $script:ProtectedPaths = @((P $script:Work 'unrelated'))
        Set-Whitelist @((Resolve-SwSafePath -Path $keep))
        Assert-Result (Test-SwSafePath -Path $keep) $false 'typed spelling of a whitelist line in final spelling'
        Assert-Result (Test-SwSafePath -Path (P $dir 'other.txt')) $true 'an entry beside it'
    }
}

# ============================================================================
# Path snapshots
# ============================================================================

Describe 'Path snapshots' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        $script:Work = New-Work
        $script:Dir = New-Dir (P $script:Work 'a' 'b')
        $script:Config = @{ ConfigPath = (P $script:Work 'appdata' 'config'); CachePath = (P $script:Work 'appdata' 'cache'); WhitelistFile = (P $script:Work 'appdata' 'config' 'whitelist.txt') }
    }
    AfterEach { Stop-Case }

    It 'F-7 [W] holds Path, Entries and AllowLeafLink for an existing folder, with one identity text per component up to the root' {
        $snapshot = Get-SwPathSnapshot -Path $script:Dir
        $snapshot | Should -Not -BeNullOrEmpty
        $snapshot | Should -BeOfType [hashtable]
        (Fold ([string]$snapshot['Path'])) | Should -BeExactly (Fold ([System.IO.Path]::GetFullPath($script:Dir)))
        $snapshot['AllowLeafLink'] | Should -BeFalse
        $expected = @(Get-Chain $script:Dir | ForEach-Object { Fold $_ } | Sort-Object)
        $actual = @($snapshot['Entries'].Keys | ForEach-Object { Fold ([string]$_) } | Sort-Object)
        $actual -join '|' | Should -BeExactly ($expected -join '|')
        foreach ($key in $snapshot['Entries'].Keys) { [string]$snapshot['Entries'][$key] | Should -Not -BeNullOrEmpty }
    }

    It 'F-7 [W] mirrors the AllowLeafLink switch' {
        (Get-SwPathSnapshot -Path $script:Dir -AllowLeafLink)['AllowLeafLink'] | Should -BeTrue
        (Get-SwPathSnapshot -Path $script:Dir)['AllowLeafLink'] | Should -BeFalse
    }

    It 'F-7 [W] gives the same identity text for the same entry and different texts for different entries' {
        $other = New-Dir (P $script:Work 'a' 'c')
        $one = Get-SwPathSnapshot -Path $script:Dir
        $again = Get-SwPathSnapshot -Path $script:Dir
        Test-SameSnapshot $one $again | Should -BeTrue
        $second = Get-SwPathSnapshot -Path $other
        $leafKeyOne = @($one['Entries'].Keys | Where-Object { (Fold $_) -eq (Fold ([System.IO.Path]::GetFullPath($script:Dir))) })[0]
        $leafKeyTwo = @($second['Entries'].Keys | Where-Object { (Fold $_) -eq (Fold ([System.IO.Path]::GetFullPath($other))) })[0]
        [string]$one['Entries'][$leafKeyOne] | Should -Not -BeExactly ([string]$second['Entries'][$leafKeyTwo])
    }

    It 'F-7 [W] also binds a file' {
        $file = New-File (P $script:Dir 'f.txt') 5
        $snapshot = Get-SwPathSnapshot -Path $file
        $snapshot | Should -Not -BeNullOrEmpty
        @($snapshot['Entries'].Keys).Count | Should -Be (@(Get-Chain $file).Count)
    }

    It 'F-7 [W] closes its handles: the entry can be renamed and removed right after the snapshot' {
        $snapshot = Get-SwPathSnapshot -Path $script:Dir
        $snapshot | Should -Not -BeNullOrEmpty
        $moved = P $script:Work 'a' 'moved'
        { [System.IO.Directory]::Move($script:Dir, $moved) } | Should -Not -Throw
        { [System.IO.Directory]::Delete($moved, $false) } | Should -Not -Throw
    }

    It 'F-7 [W] keeps no handle on a file either: it can be overwritten and deleted right after the snapshot' {
        $file = New-File (P $script:Dir 'f.txt') 5
        $null = Get-SwPathSnapshot -Path $file
        { [System.IO.File]::WriteAllText($file, 'changed') } | Should -Not -Throw
        { [System.IO.File]::Delete($file) } | Should -Not -Throw
    }

    It 'F-7 [W] treats brackets and wildcard characters of the name literally' {
        $odd = New-Dir (P $script:Work 'Cache [1]')
        $decoy = New-Dir (P $script:Work 'Cache 1')
        $one = Get-SwPathSnapshot -Path $odd
        $one | Should -Not -BeNullOrEmpty
        (Fold ([string]$one['Path'])) | Should -BeExactly (Fold $odd)
        $two = Get-SwPathSnapshot -Path $decoy
        Test-SameSnapshot $one $two | Should -BeFalse
    }

    It 'F-7 [W] accepts a complete path written with forward slashes and gives the path in its normalized form' {
        $written = $script:Dir.Replace('\', '/')
        $snapshot = Get-SwPathSnapshot -Path $written
        $snapshot | Should -Not -BeNullOrEmpty
        (Fold ([string]$snapshot['Path'])) | Should -BeExactly (Fold ([System.IO.Path]::GetFullPath($script:Dir)))
    }

    It 'F-8 gives $null for an empty path, white space and $null without an exception' {
        $null -eq (Get-SwPathSnapshot -Path '') | Should -BeTrue
        $null -eq (Get-SwPathSnapshot -Path '   ') | Should -BeTrue
        $null -eq (Get-SwPathSnapshot -Path $null) | Should -BeTrue
    }

    It 'F-8 gives $null for a missing entry and for a missing component' {
        $null -eq (Get-SwPathSnapshot -Path (P $script:Work 'missing')) | Should -BeTrue
        $null -eq (Get-SwPathSnapshot -Path (P $script:Work 'missing' 'deeper')) | Should -BeTrue
        $null -eq (Get-SwPathSnapshot -Path (P $script:Work 'missing') -AllowLeafLink) | Should -BeTrue
    }

    It 'F-8 gives $null for a path that cannot be normalized or is not a drive path (<Label>)' -ForEach @(
        @{ Label = 'a NUL character'; Text = ('a' + [char]0 + 'b') }
        @{ Label = 'a UNC path'; Text = '\\server\share\x' }
        @{ Label = 'a device path'; Text = '\\?\C:\Example\x' }
        @{ Label = 'a registry provider path'; Text = 'HKCU:\Software\Example' }
        @{ Label = 'an environment provider path'; Text = 'Env:Path' }
        @{ Label = 'a root-relative path'; Text = '\Example\x' }
        @{ Label = 'a drive-relative path'; Text = 'C:Example' }
    ) {
        $null -eq (Get-SwPathSnapshot -Path $Text) | Should -BeTrue
        $null -eq (Get-SwPathSnapshot -Path $Text -AllowLeafLink) | Should -BeTrue
    }

    It 'F-8 gives $null for every path on a host without the Windows file API' {
        if ($script:OnWindows) { Set-ItResult -Skipped -Because 'this host has the Windows file API'; return }
        $null -eq (Get-SwPathSnapshot -Path $script:Dir) | Should -BeTrue
        $null -eq (Get-SwPathSnapshot -Path $script:Work -AllowLeafLink) | Should -BeTrue
        $null -eq (Get-SwPathSnapshot -Path (New-File (P $script:Dir 'f.txt') 1)) | Should -BeTrue
    }

    It 'F-8 [W] gives $null for a path below a link' {
        $target = New-Dir (P $script:Work 'target')
        New-File (P $target 'cache' 'f.txt') 1 | Out-Null
        $link = P $script:Work 'Link'
        New-TestLink $link $target
        try {
            $null -eq (Get-SwPathSnapshot -Path (P $link 'cache')) | Should -BeTrue
            $null -eq (Get-SwPathSnapshot -Path (P $link 'cache') -AllowLeafLink) | Should -BeTrue
            $null -eq (Get-SwPathSnapshot -Path (P $link 'cache' 'f.txt') -AllowLeafLink) | Should -BeTrue
        }
        finally { Remove-TestLink $link }
    }

    It 'F-8 [W] gives $null for a link as the entry without -AllowLeafLink' {
        $target = New-Dir (P $script:Work 'target')
        $link = P $script:Work 'Cache'
        New-TestLink $link $target
        try { $null -eq (Get-SwPathSnapshot -Path $link) | Should -BeTrue }
        finally { Remove-TestLink $link }
    }

    It 'F-9 [W] gives a snapshot for a link as the entry with -AllowLeafLink, and never follows it' {
        $target = New-Dir (P $script:Work 'target')
        New-File (P $target 'f.txt') 1 | Out-Null
        $link = P $script:Work 'Cache'
        New-TestLink $link $target
        try {
            $snapshot = Get-SwPathSnapshot -Path $link -AllowLeafLink
            $snapshot | Should -Not -BeNullOrEmpty
            $snapshot['AllowLeafLink'] | Should -BeTrue
            (Fold ([string]$snapshot['Path'])) | Should -BeExactly (Fold $link)
            $targetSnapshot = Get-SwPathSnapshot -Path $target
            Test-SameSnapshot $snapshot $targetSnapshot | Should -BeFalse
        }
        finally { Remove-TestLink $link }
    }

    It 'F-8 never throws and never writes an error record, also under Continue (<Label>)' -ForEach $script:HostileText {
        $ErrorActionPreference = 'Continue'
        $records = @(& { Get-SwPathSnapshot -Path $Text; Get-SwPathSnapshot -Path $Text -AllowLeafLink } 2>&1)
        @($records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count | Should -Be 0
        @($records | Where-Object { $null -ne $_ }).Count | Should -Be 0
    }

    It 'F-10 gives false for a $null snapshot without asking for a fresh one' {
        Mock Get-SwPathSnapshot { @{ Path = $Path; Entries = @{ x = '1' }; AllowLeafLink = $false } }
        Assert-Result (Test-SwPathSnapshot -Snapshot $null) $false 'null'
        Should -Invoke -CommandName Get-SwPathSnapshot -Times 0 -Exactly
    }

    It 'F-10 gives false when the fresh snapshot is $null' {
        $old = @{ Path = (P $script:Work 'x'); Entries = @{ a = '1' }; AllowLeafLink = $false }
        Mock Get-SwPathSnapshot { $null }
        Assert-Result (Test-SwPathSnapshot -Snapshot $old) $false 'no fresh snapshot'
    }

    It 'F-10 gives true when the fresh snapshot has the same keys and values' {
        $old = @{ Path = (P $script:Work 'x'); Entries = @{ a = '1'; b = '2' }; AllowLeafLink = $false }
        Mock Get-SwPathSnapshot { @{ Path = $Path; Entries = @{ a = '1'; b = '2' }; AllowLeafLink = [bool]$AllowLeafLink } }
        Assert-Result (Test-SwPathSnapshot -Snapshot $old) $true 'same identity'
    }

    It 'F-10 gives false when one value differs' {
        $old = @{ Path = (P $script:Work 'x'); Entries = @{ a = '1'; b = '2' }; AllowLeafLink = $false }
        Mock Get-SwPathSnapshot { @{ Path = $Path; Entries = @{ a = '1'; b = 'other' }; AllowLeafLink = $false } }
        Assert-Result (Test-SwPathSnapshot -Snapshot $old) $false 'changed value'
    }

    It 'F-10 gives false when a key is missing in the fresh snapshot' {
        $old = @{ Path = (P $script:Work 'x'); Entries = @{ a = '1'; b = '2' }; AllowLeafLink = $false }
        Mock Get-SwPathSnapshot { @{ Path = $Path; Entries = @{ a = '1' }; AllowLeafLink = $false } }
        Assert-Result (Test-SwPathSnapshot -Snapshot $old) $false 'missing key'
    }

    It 'F-10 gives false when the fresh snapshot has an additional key' {
        $old = @{ Path = (P $script:Work 'x'); Entries = @{ a = '1' }; AllowLeafLink = $false }
        Mock Get-SwPathSnapshot { @{ Path = $Path; Entries = @{ a = '1'; b = '2' }; AllowLeafLink = $false } }
        Assert-Result (Test-SwPathSnapshot -Snapshot $old) $false 'additional key'
    }

    It 'F-10 asks for exactly one fresh snapshot, with the old Path and the old AllowLeafLink (<Allow>)' -ForEach @(
        @{ Allow = $true }
        @{ Allow = $false }
    ) {
        $script:Expected = P $script:Work 'x'
        $old = @{ Path = $script:Expected; Entries = @{ a = '1' }; AllowLeafLink = $Allow }
        $script:ExpectAllow = $Allow
        Mock Get-SwPathSnapshot { @{ Path = $Path; Entries = @{ a = '1' }; AllowLeafLink = [bool]$AllowLeafLink } }
        Assert-Result (Test-SwPathSnapshot -Snapshot $old) $true 'same'
        Should -Invoke -CommandName Get-SwPathSnapshot -Times 1 -Exactly -ParameterFilter { $Path -eq $script:Expected -and ([bool]$AllowLeafLink) -eq $script:ExpectAllow }
    }

    It 'F-10 gives false and does not throw when the fresh snapshot cannot be formed' {
        $old = @{ Path = (P $script:Work 'x'); Entries = @{ a = '1' }; AllowLeafLink = $false }
        Mock Get-SwPathSnapshot { throw 'snapshot-canary' }
        Assert-Result (Test-SwPathSnapshot -Snapshot $old) $false 'throwing snapshot'
    }

    It 'F-11 never throws for a substitute object (<Label>) and gives false against a complete fresh snapshot' -ForEach $script:SubstituteSnapshots {
        $snapshot = & $Make (P $script:Work 'x')
        Mock Get-SwPathSnapshot { @{ Path = $Path; Entries = @{ a = '1' }; AllowLeafLink = $false } }
        $result = Get-Result { Test-SwPathSnapshot -Snapshot $snapshot }
        Assert-Result $result $false $Label
    }

    It 'F-11 lets the tree functions work with substitute snapshots (<Label>)' -ForEach @(
        @{ Label = 'objects with only Path'; Kind = 'object' }
        @{ Label = 'tables with only Path'; Kind = 'table' }
    ) {
        $root = New-Dir (P $script:Work 'tree')
        New-File (P $root 'a.txt') 4 | Out-Null
        New-File (P $root 'sub' 'b.txt') 6 | Out-Null
        if ($Kind -eq 'object') { Mock Get-SwPathSnapshot { [pscustomobject]@{ Path = $Path } } }
        else { Mock Get-SwPathSnapshot { @{ Path = $Path } } }
        Mock Test-SwPathSnapshot { $true }
        $items = @(Get-Result { Get-SwTreeItems -Path $root })
        $items.Count | Should -Be 3
        $tree = Get-SwSafeDirectoryTreeItems -Path $root
        $tree['Success'] | Should -BeTrue
        (Get-SwPathSize -Path $root) | Should -Be 10
    }
}

# ============================================================================
# Tree walk
# ============================================================================

Describe 'Get-SwTreeItems' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        $script:Work = New-Work
        $script:Config = @{ ConfigPath = (P $script:Work 'appdata' 'config'); CachePath = (P $script:Work 'appdata' 'cache'); WhitelistFile = (P $script:Work 'appdata' 'config' 'whitelist.txt') }
        $script:SwWalkBudgetSeconds = 15
        $script:Root = New-Dir (P $script:Work 'root')
    }
    AfterEach { Stop-Case }

    It 'F-12 lists every entry at every depth, including hidden files' {
        Use-FakeIdentity
        New-File (P $script:Root 'a' 'f.txt') 1 | Out-Null
        New-File (P $script:Root 'a' 'b' 'c' 'deep.txt') 1 | Out-Null
        New-Dir (P $script:Root 'd') | Out-Null
        $hidden = New-File (P $script:Root 'a' '.hidden') 1
        if ($script:OnWindows) { [System.IO.File]::SetAttributes($hidden, ([System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System)) }
        $names = @(Get-SwTreeItems -Path $script:Root | ForEach-Object { Get-Rel $_.FullName $script:Root } | Sort-Object)
        $expected = @('a', (P 'a' 'b'), (P 'a' 'b' 'c'), (P 'a' 'b' 'c' 'deep.txt'), (P 'a' '.hidden'), (P 'a' 'f.txt'), 'd') | Sort-Object
        $names -join '|' | Should -BeExactly ($expected -join '|')
        if ($script:OnWindows) { [System.IO.File]::SetAttributes($hidden, [System.IO.FileAttributes]::Normal) }
    }

    It 'F-12 gives the entries one by one into the pipeline, as file system objects' {
        Use-FakeIdentity
        New-File (P $script:Root 'a.txt') 7 | Out-Null
        New-File (P $script:Root 'sub' 'b.txt') 9 | Out-Null
        $count = 0
        $kinds = New-Object System.Collections.Generic.List[string]
        Get-SwTreeItems -Path $script:Root | ForEach-Object {
            $count++
            $kinds.Add($_.GetType().IsArray.ToString())
            $_.FullName | Should -Not -BeNullOrEmpty
            $null -ne $_.PSObject.Properties['PSIsContainer'] | Should -BeTrue
            $null -ne $_.PSObject.Properties['Attributes'] | Should -BeTrue
            $null -ne $_.PSObject.Properties['Length'] -or $_.PSIsContainer | Should -BeTrue
        }
        $count | Should -Be 3
        @($kinds | Where-Object { $_ -eq 'True' }).Count | Should -Be 0
        ((Get-SwTreeItems -Path $script:Root | Where-Object { -not $_.PSIsContainer } | Measure-Object -Property Length -Sum).Sum) | Should -Be 16
    }

    It 'F-12 outputs an entry before its descendants' {
        Use-FakeIdentity
        New-File (P $script:Root 'a' 'b' 'c' 'deep.txt') 1 | Out-Null
        New-File (P $script:Root 'a' 'f.txt') 1 | Out-Null
        New-File (P $script:Root 'z' 'y' 'x.txt') 1 | Out-Null
        $order = @(Get-SwTreeItems -Path $script:Root | ForEach-Object { $_.FullName })
        foreach ($entry in $order) {
            $parent = [System.IO.Path]::GetDirectoryName($entry)
            if ((Fold $parent) -eq (Fold $script:Root)) { continue }
            $order.IndexOf($parent) | Should -BeLessThan $order.IndexOf($entry) -Because "$parent must come before $entry"
            $order.IndexOf($parent) | Should -BeGreaterOrEqual 0
        }
    }

    It 'F-12 gives every entry a SweeprPathSnapshot with its own Path and AllowLeafLink' {
        Use-FakeIdentity
        New-File (P $script:Root 'a' 'f.txt') 1 | Out-Null
        New-File (P $script:Root 'g.txt') 1 | Out-Null
        $items = @(Get-SwTreeItems -Path $script:Root)
        $items.Count | Should -Be 3
        foreach ($item in $items) {
            $snapshot = $item.SweeprPathSnapshot
            $snapshot | Should -Not -BeNullOrEmpty
            (Fold ([string](Get-Field $snapshot 'Path'))) | Should -BeExactly (Fold $item.FullName)
            [bool](Get-Field $snapshot 'AllowLeafLink') | Should -BeTrue
        }
    }

    It 'F-12 lists a link once and does not enter it' {
        Use-FakeIdentity
        $target = New-Dir (P $script:Work 'target')
        New-File (P $target 'inside.txt') 11 | Out-Null
        New-File (P $script:Root 'plain.txt') 1 | Out-Null
        $link = P $script:Root 'link'
        New-TestLink $link $target
        try {
            $names = @(Get-SwTreeItems -Path $script:Root | ForEach-Object { $_.FullName })
            @($names | Where-Object { (Fold $_) -eq (Fold $link) }).Count | Should -Be 1
            @($names | Where-Object { (Fold $_).StartsWith((Fold $link) + '\') -or (Fold $_).StartsWith((Fold $link) + '/') }).Count | Should -Be 0
            $names.Count | Should -Be 2
        }
        finally { Remove-TestLink $link }
    }

    It 'F-12 lists a file link as an entry' {
        Use-FakeIdentity
        $file = New-File (P $script:Work 'real.txt') 5
        $link = P $script:Root 'filelink.txt'
        try { New-TestLink $link $file }
        catch { Set-ItResult -Skipped -Because 'this host does not allow file links for this user'; return }
        try {
            $names = @(Get-SwTreeItems -Path $script:Root | ForEach-Object { $_.FullName })
            @($names | Where-Object { (Fold $_) -eq (Fold $link) }).Count | Should -Be 1
        }
        finally { Remove-TestLink $link }
    }

    It 'F-12 never walks with Get-ChildItem -Recurse' {
        Use-FakeIdentity
        New-File (P $script:Root 'a' 'b' 'f.txt') 1 | Out-Null
        $script:RealGci = Get-Command -Name Get-ChildItem -CommandType Cmdlet
        Mock Get-ChildItem { & $script:RealGci @PesterBoundParameters }
        Mock Get-ChildItem { throw 'Get-ChildItem -Recurse is not allowed' } -ParameterFilter { $Recurse }
        $items = @(Get-SwTreeItems -Path $script:Root)
        $items.Count | Should -Be 3
        Should -Invoke -CommandName Get-ChildItem -Times 0 -Exactly -ParameterFilter { $Recurse }
    }

    It 'F-12 forms the snapshot of the root once, checks every entered folder once and asks nothing for the files (substitute objects)' {
        $script:GetCalls = New-Object System.Collections.Generic.List[string]
        $script:GetLinkFlags = New-Object System.Collections.Generic.List[bool]
        $script:TestCalls = 0
        Mock Get-SwPathSnapshot { $script:GetCalls.Add([string]$Path); $script:GetLinkFlags.Add([bool]$AllowLeafLink); [pscustomobject]@{ Path = $Path } }
        Mock Test-SwPathSnapshot { $script:TestCalls++; $true }
        New-File (P $script:Root 'a' 'f.txt') 1 | Out-Null
        New-Dir (P $script:Root 'b') | Out-Null
        New-File (P $script:Root 'c.txt') 1 | Out-Null
        $items = @(Get-SwTreeItems -Path $script:Root)
        $items.Count | Should -Be 4
        $script:TestCalls | Should -Be 3 -Because 'the root and the two folders a and b are entered once each'
        @($script:GetCalls | Where-Object { (Fold $_) -eq (Fold $script:Root) }).Count | Should -Be 1
        for ($i = 0; $i -lt $script:GetCalls.Count; $i++) {
            if ((Fold $script:GetCalls[$i]) -eq (Fold $script:Root)) { continue }
            $script:GetLinkFlags[$i] | Should -BeTrue -Because "the snapshot of the entry $($script:GetCalls[$i]) is formed with -AllowLeafLink"
        }
    }

    It 'F-12 [W] gives every entry the snapshot a fresh Get-SwPathSnapshot -AllowLeafLink gives, and links appear once without content' {
        New-File (P $script:Root 'a' 'f.txt') 1 | Out-Null
        New-File (P $script:Root 'a' 'b' 'c' 'deep.txt') 1 | Out-Null
        $d = New-Dir (P $script:Root 'd')
        $link = P $script:Root 'link'
        New-TestLink $link $d
        try {
            $items = @(Get-SwTreeItems -Path $script:Root)
            @($items | Where-Object { (Fold $_.FullName) -eq (Fold $link) }).Count | Should -Be 1
            foreach ($item in $items) {
                $fresh = Get-SwPathSnapshot -Path $item.FullName -AllowLeafLink
                $fresh | Should -Not -BeNullOrEmpty -Because $item.FullName
                Test-SameSnapshot $item.SweeprPathSnapshot $fresh | Should -BeTrue -Because $item.FullName
            }
            $items.Count | Should -Be 7
        }
        finally { Remove-TestLink $link }
    }

    It 'F-12 [W] needs 1 + d calls of Get-SwPathSnapshot for a tree with d entered folders' {
        New-File (P $script:Root 'a' 'f.txt') 1 | Out-Null
        New-File (P $script:Root 'a' 'b' 'c' 'deep.txt') 1 | Out-Null
        $d = New-Dir (P $script:Root 'd')
        $link = P $script:Root 'link'
        New-TestLink $link $d
        $script:GetCalls = New-Object System.Collections.Generic.List[string]
        Mock Get-SwPathSnapshot { $script:GetCalls.Add([string]$Path); & $script:RealGet -Path $Path -AllowLeafLink:$AllowLeafLink }
        try {
            $items = @(Get-SwTreeItems -Path $script:Root)
            $items.Count | Should -Be 7
            # root, a, b, c and d are entered; the link is listed but not entered.
            $script:GetCalls.Count | Should -Be 6
        }
        finally { Remove-TestLink $link }
    }

    It 'G-6 walks a folder whose name contains <Label> and lists only what is inside it' -ForEach $script:OddNames {
        Use-FakeIdentity
        $folder = New-Dir (P $script:Work $Name)
        New-File (P $folder 'inside.txt') 5 | Out-Null
        New-File (P $folder 'sub' 'deeper.txt') 5 | Out-Null
        New-File (P $script:Work 'outside.txt') 5 | Out-Null
        $names = @(Get-SwTreeItems -Path $folder | ForEach-Object { Get-Rel $_.FullName $folder } | Sort-Object)
        $names -join '|' | Should -BeExactly ((@('inside.txt', 'sub', (P 'sub' 'deeper.txt')) | Sort-Object) -join '|')
    }

    It 'G-6 does not read a folder name with brackets as a pattern for its neighbor' {
        Use-FakeIdentity
        $odd = New-Dir (P $script:Work 'Cache [1]')
        $decoy = New-Dir (P $script:Work 'Cache 1')
        New-File (P $odd 'mine.txt') 1 | Out-Null
        New-File (P $decoy 'theirs.txt') 1 | Out-Null
        $names = @(Get-SwTreeItems -Path $odd | ForEach-Object { $_.Name })
        $names | Should -Be @('mine.txt')
        $null = Assert-Throws { @(Get-SwTreeItems -Path (P $script:Work 'Cache [*]')) }
    }

    It 'F-13 throws when the root is a file' {
        Use-SubstituteIdentity
        $file = New-File (P $script:Work 'file.txt') 1
        $null = Assert-Throws { @(Get-SwTreeItems -Path $file) }
    }

    It 'F-13 throws when the root does not exist' {
        Use-FakeIdentity
        $null = Assert-Throws { @(Get-SwTreeItems -Path (P $script:Work 'missing')) }
    }

    It 'F-13 throws, naming the path, when the root gives no snapshot (also with -SkipUnreadable)' {
        Mock Get-SwPathSnapshot { $null }
        Mock Test-SwPathSnapshot { $true }
        { @(Get-SwTreeItems -Path $script:Root) } | Should -Throw -ExpectedMessage ('*' + (Get-Tail $script:Root) + '*')
        $null = Assert-Throws { @(Get-SwTreeItems -Path $script:Root -SkipUnreadable) }
    }

    It 'F-13 throws for a link as the root' {
        Use-FakeIdentity
        $target = New-Dir (P $script:Work 'target')
        New-File (P $target 'f.txt') 1 | Out-Null
        $link = P $script:Work 'rootlink'
        New-TestLink $link $target
        try { $null = Assert-Throws { @(Get-SwTreeItems -Path $link) } }
        finally { Remove-TestLink $link }
    }

    It 'F-13 throws when an entered folder fails the identity test, and keeps what it gave before' {
        New-File (P $script:Root 'sub' 'f.txt') 1 | Out-Null
        New-File (P $script:Root 'a.txt') 1 | Out-Null
        $script:TestCalls = 0
        Mock Get-SwPathSnapshot { [pscustomobject]@{ Path = $Path } }
        Mock Test-SwPathSnapshot { $script:TestCalls++; $script:TestCalls -lt 2 }
        $script:Got = New-Object System.Collections.Generic.List[string]
        $failure = $null
        try { Get-SwTreeItems -Path $script:Root | ForEach-Object { $script:Got.Add([string]$_.FullName) } }
        catch { $failure = $_ }
        $failure | Should -Not -BeNullOrEmpty
        $script:Got.Count | Should -BeGreaterThan 0
    }

    It 'F-13 throws when a child gives no snapshot' {
        New-File (P $script:Root 'a.txt') 1 | Out-Null
        $script:Missing = P $script:Root 'a.txt'
        Mock Get-SwPathSnapshot { if ((Fold $Path) -eq (Fold $script:Missing)) { return $null }; [pscustomobject]@{ Path = $Path } }
        Mock Test-SwPathSnapshot { $true }
        $null = Assert-Throws { @(Get-SwTreeItems -Path $script:Root) }
    }

    It 'F-13 throws for every walk with a budget of 0 seconds' {
        Use-FakeIdentity
        New-File (P $script:Root 'a.txt') 1 | Out-Null
        $script:SwWalkBudgetSeconds = 0
        $null = Assert-Throws { @(Get-SwTreeItems -Path $script:Root) }
        $null = Assert-Throws { @(Get-SwTreeItems -Path $script:Root -SkipUnreadable) }
    }

    It 'F-13 throws for an empty folder with a budget of 0 seconds' {
        Use-FakeIdentity
        $script:SwWalkBudgetSeconds = 0
        $null = Assert-Throws { @(Get-SwTreeItems -Path $script:Root) }
    }

    It 'F-13 reads the budget at each walk' {
        Use-FakeIdentity
        New-File (P $script:Root 'a.txt') 1 | Out-Null
        $script:SwWalkBudgetSeconds = 0
        $null = Assert-Throws { @(Get-SwTreeItems -Path $script:Root) }
        $script:SwWalkBudgetSeconds = 15
        @(Get-SwTreeItems -Path $script:Root).Count | Should -Be 1
        $script:SwWalkBudgetSeconds = 0
        $null = Assert-Throws { @(Get-SwTreeItems -Path $script:Root) }
    }

    It 'F-13 throws when a folder cannot be listed, and stays silent with -SkipUnreadable' {
        New-File (P $script:Root 'top.txt') 1 | Out-Null
        $sub = P $script:Root 'sub'
        New-File (P $sub 'x.txt') 1 | Out-Null
        $script:Vanishing = $sub
        Mock Get-SwPathSnapshot { [pscustomobject]@{ Path = $Path } }
        Mock Test-SwPathSnapshot {
            if ((Fold ([string]$Snapshot.Path)) -eq (Fold $script:Vanishing) -and [System.IO.Directory]::Exists($script:Vanishing) -and (Fold $script:Vanishing).StartsWith((Fold $script:Work))) {
                [System.IO.Directory]::Delete($script:Vanishing, $true)
            }
            $true
        }
        $null = Assert-Throws { @(Get-SwTreeItems -Path $script:Root) }
        New-File (P $sub 'x.txt') 1 | Out-Null
        $names = @(Get-Result { Get-SwTreeItems -Path $script:Root -SkipUnreadable | ForEach-Object { $_.FullName } })
        @($names | Where-Object { (Fold $_) -eq (Fold $sub) }).Count | Should -Be 1
        @($names | Where-Object { (Fold $_) -eq (Fold (P $sub 'x.txt')) }).Count | Should -Be 0
        @($names | Where-Object { (Fold $_) -eq (Fold (P $script:Root 'top.txt')) }).Count | Should -Be 1
    }

    It 'F-13 keeps the other reasons for a failure also with -SkipUnreadable: a changed folder still throws' {
        New-File (P $script:Root 'sub' 'f.txt') 1 | Out-Null
        $script:TestCalls = 0
        Mock Get-SwPathSnapshot { [pscustomobject]@{ Path = $Path } }
        Mock Test-SwPathSnapshot { $script:TestCalls++; $script:TestCalls -lt 2 }
        $null = Assert-Throws { @(Get-SwTreeItems -Path $script:Root -SkipUnreadable) }
    }

    It 'F-13 [W] throws when an entered folder is replaced during the walk' {
        New-File (P $script:Root 'a' 'f.txt') 1 | Out-Null
        New-File (P $script:Root 'a' 'g.txt') 1 | Out-Null
        $script:ReplacedDir = P $script:Root 'a'
        $script:Replaced = $false
        Mock Test-SwPathSnapshot {
            if (-not $script:Replaced -and (Fold ([string](Get-Field $Snapshot 'Path'))) -eq (Fold $script:ReplacedDir)) {
                $script:Replaced = $true
                [System.IO.Directory]::Move($script:ReplacedDir, ($script:ReplacedDir + '-old'))
                [void][System.IO.Directory]::CreateDirectory($script:ReplacedDir)
            }
            & $script:RealTest -Snapshot $Snapshot
        }
        $null = Assert-Throws { @(Get-SwTreeItems -Path $script:Root) }
        $script:Replaced | Should -BeTrue
    }

    It 'F-13 [W] throws when the name of an entry changes under normalization (trailing dot)' {
        $name = 'trailing.'
        $extended = '\\?\' + (P $script:Root $name)
        try { [System.IO.File]::WriteAllText($extended, 'x') }
        catch { Set-ItResult -Skipped -Because 'this host cannot create a file with a trailing dot'; return }
        try { $null = Assert-Throws { @(Get-SwTreeItems -Path $script:Root) } }
        finally { [System.IO.File]::Delete($extended) }
    }

    It 'F-13 gives the same answers under every error preference (<Preference>)' -ForEach @(
        @{ Preference = 'Stop' }
        @{ Preference = 'Continue' }
        @{ Preference = 'SilentlyContinue' }
    ) {
        Use-FakeIdentity
        New-File (P $script:Root 'a.txt') 1 | Out-Null
        $ErrorActionPreference = $Preference
        $null = Assert-Throws { @(Get-SwTreeItems -Path (P $script:Work 'missing')) }
        @(Get-SwTreeItems -Path $script:Root).Count | Should -Be 1
    }
}

Describe 'Test-SwReparsePoint' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        $script:Work = New-Work
    }
    AfterEach { Stop-Case }

    It 'F-14 gives true for a link to a folder' {
        $target = New-Dir (P $script:Work 'target')
        $link = P $script:Work 'link'
        New-TestLink $link $target
        try { Assert-Result (Test-SwReparsePoint -Path $link) $true 'folder link' }
        finally { Remove-TestLink $link }
    }

    It 'F-14 gives true for a link to a file' {
        $file = New-File (P $script:Work 'real.txt') 3
        $link = P $script:Work 'filelink.txt'
        try { New-TestLink $link $file }
        catch { Set-ItResult -Skipped -Because 'this host does not allow file links for this user'; return }
        try { Assert-Result (Test-SwReparsePoint -Path $link) $true 'file link' }
        finally { Remove-TestLink $link }
    }

    It 'F-14 gives false for an ordinary file and an ordinary folder' {
        Assert-Result (Test-SwReparsePoint -Path (New-File (P $script:Work 'a.txt') 1)) $false 'file'
        Assert-Result (Test-SwReparsePoint -Path (New-Dir (P $script:Work 'dir'))) $false 'folder'
    }

    It 'F-14 gives false for a missing path and for an empty one' {
        Assert-Result (Test-SwReparsePoint -Path (P $script:Work 'missing')) $false 'missing'
        Assert-Result (Test-SwReparsePoint -Path '') $false 'empty'
        Assert-Result (Test-SwReparsePoint -Path $null) $false 'null'
    }

    It 'F-14 treats the path literally: a name with brackets is not a pattern for its neighbor' {
        $plain = New-Dir (P $script:Work 'Cache 1')
        $target = New-Dir (P $script:Work 'target')
        $link = P $script:Work 'Cache [1]'
        New-TestLink $link $target
        try {
            Assert-Result (Test-SwReparsePoint -Path $link) $true 'the link with brackets'
            Assert-Result (Test-SwReparsePoint -Path $plain) $false 'the plain neighbor'
            Assert-Result (Test-SwReparsePoint -Path (P $script:Work 'Cache [*]')) $false 'a pattern is no path'
        }
        finally { Remove-TestLink $link }
    }

    It 'F-14 never throws for odd text (<Label>)' -ForEach $script:HostileText {
        $result = Get-Result { Test-SwReparsePoint -Path $Text }
        Assert-Result $result $false $Label
    }

    It 'F-14 returns a single boolean' {
        @(Test-SwReparsePoint -Path $script:Work).Count | Should -Be 1
    }
}

# ============================================================================
# Validated tree
# ============================================================================

Describe 'Get-SwSafeDirectoryTreeItems' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        $script:Work = New-Work
        $script:Prot = New-Dir (P $script:Work 'protected')
        $script:Data = P $script:Work 'appdata'
        $script:Config = @{ ConfigPath = (P $script:Data 'config'); CachePath = (P $script:Data 'cache'); WhitelistFile = (P $script:Data 'config' 'whitelist.txt') }
        $script:DefaultWhitelistPatterns = @()
        $script:ProtectedPaths = @($script:Prot)
        $script:ExactProtectedPaths = @()
        $script:SweeprCleanPathGuard = $false
        $script:SwWalkBudgetSeconds = 15
        $script:Root = New-Dir (P $script:Work 'root')
        Use-FakeIdentity
    }
    AfterEach { Stop-Case }

    It 'F-15 gives all four keys, Success and every entry for a tree that may be removed' {
        New-File (P $script:Root 'safe.txt') 5 | Out-Null
        New-File (P $script:Root 'nested' 'deep' 'x.txt') 5 | Out-Null
        $tree = Get-SwSafeDirectoryTreeItems -Path $script:Root
        $tree | Should -BeOfType [hashtable]
        @($tree.Keys | Sort-Object) -join ',' | Should -BeExactly 'Items,Reason,RootSnapshot,Success'
        $tree['Success'] | Should -BeTrue
        @($tree['Items']).Count | Should -Be 4
        $tree['RootSnapshot'] | Should -Not -BeNullOrEmpty
        (Get-Field $tree['RootSnapshot'] 'AllowLeafLink') | Should -BeTrue
        (Fold ([string](Get-Field $tree['RootSnapshot'] 'Path'))) | Should -BeExactly (Fold $script:Root)
        [string]$tree['Reason'] | Should -BeNullOrEmpty
    }

    It 'F-15 gives Success true and no items for an empty folder' {
        $tree = Get-SwSafeDirectoryTreeItems -Path $script:Root
        $tree['Success'] | Should -BeTrue
        @($tree['Items']).Count | Should -Be 0
    }

    It 'F-15 refuses the whole tree for a protected folder inside, names its path and changes nothing' {
        New-File (P $script:Root 'safe.txt') 5 | Out-Null
        $protectedDir = P $script:Root 'sub'
        $script:ProtectedPaths = @($protectedDir)
        New-File (P $protectedDir 'secret.txt') 5 | Out-Null
        $before = Get-Listing $script:Root
        $tree = Get-SwSafeDirectoryTreeItems -Path $script:Root
        $tree['Success'] | Should -BeFalse
        @($tree['Items']).Count | Should -Be 0
        $tree['RootSnapshot'] | Should -BeNullOrEmpty
        [string]$tree['Reason'] | Should -BeLike ('*' + (Get-Tail $protectedDir) + '*')
        (Get-Listing $script:Root) -join '|' | Should -BeExactly ($before -join '|')
        @($tree.Keys | Sort-Object) -join ',' | Should -BeExactly 'Items,Reason,RootSnapshot,Success'
    }

    It 'F-15 refuses the tree for a whitelisted entry inside and names the entry' {
        $keep = New-File (P $script:Root 'keep') 5
        New-File (P $script:Root 'other.txt') 5 | Out-Null
        Set-Whitelist @($keep)
        $tree = Get-SwSafeDirectoryTreeItems -Path $script:Root
        $tree['Success'] | Should -BeFalse
        @($tree['Items']).Count | Should -Be 0
        [string]$tree['Reason'] | Should -BeLike ('*' + (Get-Tail $keep) + '*')
    }

    It 'F-15 is not stopped by a whitelisted sibling whose name only begins like an entry of the tree' {
        New-File (P $script:Root 'keep2') 5 | Out-Null
        Set-Whitelist @((P $script:Root 'keep'))
        (Get-SwSafeDirectoryTreeItems -Path $script:Root)['Success'] | Should -BeTrue
    }

    It 'F-15 gives Success false when the root has no snapshot' {
        Mock Get-SwPathSnapshot { $null }
        $tree = Get-SwSafeDirectoryTreeItems -Path $script:Root
        $tree['Success'] | Should -BeFalse
        @($tree['Items']).Count | Should -Be 0
        $tree['RootSnapshot'] | Should -BeNullOrEmpty
        [string]$tree['Reason'] | Should -Not -BeNullOrEmpty
    }

    It 'F-15 asks for the root snapshot with -AllowLeafLink' {
        $null = Get-SwSafeDirectoryTreeItems -Path $script:Root
        Should -Invoke -CommandName Get-SwPathSnapshot -Times 1 -ParameterFilter { (Fold $Path) -eq (Fold $script:Root) -and $AllowLeafLink }
    }

    It 'F-15 gives Success true, no items and the root snapshot for a root that is a link, without listing anything' {
        $target = New-Dir (P $script:Work 'target')
        New-File (P $target 'content.txt') 5 | Out-Null
        $link = P $script:Work 'rootlink'
        New-TestLink $link $target
        Mock Get-SwTreeItems { throw 'a link must not be listed' }
        try {
            $tree = Get-SwSafeDirectoryTreeItems -Path $link
            $tree['Success'] | Should -BeTrue
            @($tree['Items']).Count | Should -Be 0
            $tree['RootSnapshot'] | Should -Not -BeNullOrEmpty
            Should -Invoke -CommandName Get-SwTreeItems -Times 0 -Exactly
        }
        finally { Remove-TestLink $link }
    }

    It 'F-15 gives Success false when the root is a file' {
        $file = New-File (P $script:Work 'file.txt') 5
        $tree = Get-SwSafeDirectoryTreeItems -Path $file
        $tree['Success'] | Should -BeFalse
        @($tree['Items']).Count | Should -Be 0
    }

    It 'F-15 gives Success false with the message of the exception when the walk fails' {
        New-File (P $script:Root 'a.txt') 5 | Out-Null
        Mock Get-SwTreeItems { throw 'walk-canary' }
        $tree = Get-SwSafeDirectoryTreeItems -Path $script:Root
        $tree['Success'] | Should -BeFalse
        @($tree['Items']).Count | Should -Be 0
        [string]$tree['Reason'] | Should -BeLike '*walk-canary*'
    }

    It 'F-15 gives Success false when the walk runs out of time' {
        New-File (P $script:Root 'a.txt') 5 | Out-Null
        $script:SwWalkBudgetSeconds = 0
        $tree = Get-SwSafeDirectoryTreeItems -Path $script:Root
        $tree['Success'] | Should -BeFalse
        @($tree['Items']).Count | Should -Be 0
    }

    It 'F-15 walks without -SkipUnreadable' {
        New-File (P $script:Root 'a.txt') 5 | Out-Null
        Mock Get-SwTreeItems { @() }
        $null = Get-SwSafeDirectoryTreeItems -Path $script:Root
        Should -Invoke -CommandName Get-SwTreeItems -Times 1 -Exactly -ParameterFilter { -not $SkipUnreadable }
    }

    It 'F-15 checks every entry with its path and the state, and does not check the root' {
        New-File (P $script:Root 'a.txt') 5 | Out-Null
        New-File (P $script:Root 'sub' 'b.txt') 5 | Out-Null
        $script:RealState = Get-SwWhitelistState
        Mock Test-SwSafePath { $true }
        $null = Get-SwSafeDirectoryTreeItems -Path $script:Root -WhitelistState $script:RealState
        foreach ($entry in @((P $script:Root 'a.txt'), (P $script:Root 'sub'), (P $script:Root 'sub' 'b.txt'))) {
            $script:Entry = $entry
            Should -Invoke -CommandName Test-SwSafePath -Times 1 -Exactly -ParameterFilter { (Fold $Path) -eq (Fold $script:Entry) -and [object]::ReferenceEquals($WhitelistState, $script:RealState) }
        }
        Should -Invoke -CommandName Test-SwSafePath -Times 0 -Exactly -ParameterFilter { (Fold $Path) -eq (Fold $script:Root) }
    }

    It 'F-15 reads the whitelist state once for the whole tree' {
        for ($i = 0; $i -lt 12; $i++) { New-File (P $script:Root ('d' + ($i % 3)) ('f' + $i + '.txt')) 4 | Out-Null }
        Set-Whitelist @((P $script:Work 'unrelated'))
        $script:Reads = 0
        Mock Read-SwListBytes { $script:Reads++; , [System.IO.File]::ReadAllBytes($Path) }
        $tree = Get-SwSafeDirectoryTreeItems -Path $script:Root
        $tree['Success'] | Should -BeTrue
        @($tree['Items']).Count | Should -Be 15
        $script:Reads | Should -Be 1
    }

    It 'F-15 reads no whitelist state when one is given' {
        New-File (P $script:Root 'a.txt') 4 | Out-Null
        $state = Get-SwWhitelistState
        Mock Get-SwWhitelistState { throw 'the state must not be read' }
        $tree = Get-SwSafeDirectoryTreeItems -Path $script:Root -WhitelistState $state
        $tree['Success'] | Should -BeTrue
        Should -Invoke -CommandName Get-SwWhitelistState -Times 0 -Exactly
    }

    It 'F-15 never throws and gives Success false when the identity function throws' {
        Mock Get-SwPathSnapshot { throw 'snapshot-canary' }
        $tree = Get-Result { Get-SwSafeDirectoryTreeItems -Path $script:Root }
        $tree['Success'] | Should -BeFalse
    }

    It 'F-15 never throws for odd text (<Label>) and gives Success false' -ForEach $script:HostileText {
        $tree = Get-Result { Get-SwSafeDirectoryTreeItems -Path $Text }
        $tree['Success'] | Should -BeFalse
        @($tree.Keys | Sort-Object) -join ',' | Should -BeExactly 'Items,Reason,RootSnapshot,Success'
    }
}

Describe 'Get-SwSafeDirectoryTreeItems with real identities [W]' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        $script:Work = New-Work
        $script:Prot = New-Dir (P $script:Work 'protected')
        $script:Config = @{ ConfigPath = (P $script:Work 'appdata' 'config'); CachePath = (P $script:Work 'appdata' 'cache'); WhitelistFile = (P $script:Work 'appdata' 'config' 'whitelist.txt') }
        $script:DefaultWhitelistPatterns = @()
        $script:ProtectedPaths = @($script:Prot)
        $script:ExactProtectedPaths = @()
        $script:SweeprCleanPathGuard = $false
        $script:SwWalkBudgetSeconds = 15
        $script:Root = New-Dir (P $script:Work 'root')
    }
    AfterEach { Stop-Case }

    It 'F-15 [W] gives the snapshot of the root that a fresh Get-SwPathSnapshot -AllowLeafLink gives' {
        New-File (P $script:Root 'a.txt') 5 | Out-Null
        $tree = Get-SwSafeDirectoryTreeItems -Path $script:Root
        $tree['Success'] | Should -BeTrue
        @($tree['Items']).Count | Should -Be 1
        Test-SameSnapshot $tree['RootSnapshot'] (Get-SwPathSnapshot -Path $script:Root -AllowLeafLink) | Should -BeTrue
    }

    It 'F-15 [W] refuses a tree with a junction whose target is protected (the final spelling of the link counts)' {
        $prot = New-Dir (P $script:Work 'prot-target')
        New-File (P $prot 'f.txt') 1 | Out-Null
        $script:ProtectedPaths = @($prot)
        New-File (P $script:Root 'safe.txt') 1 | Out-Null
        $link = P $script:Root 'link'
        New-TestLink $link $prot
        try {
            $tree = Get-SwSafeDirectoryTreeItems -Path $script:Root
            $tree['Success'] | Should -BeFalse
            [string]$tree['Reason'] | Should -BeLike ('*' + (Get-Tail $link) + '*')
        }
        finally { Remove-TestLink $link }
    }

    It 'F-15 [W] gives Success true and no items for a root that is a junction to a folder with content' {
        $target = New-Dir (P $script:Work 'target')
        New-File (P $target 'content.txt') 5 | Out-Null
        $link = P $script:Work 'rootlink'
        New-TestLink $link $target
        try {
            $tree = Get-SwSafeDirectoryTreeItems -Path $link
            $tree['Success'] | Should -BeTrue
            @($tree['Items']).Count | Should -Be 0
            $tree['RootSnapshot'] | Should -Not -BeNullOrEmpty
        }
        finally { Remove-TestLink $link }
    }

    It 'F-15 [W] refuses a protected folder inside a tree below the 8.3 spelling of the temp folder' {
        New-File (P $script:Root 'safe.txt') 5 | Out-Null
        $inner = New-Dir (P $script:Root 'inner')
        New-File (P $inner 'secret.txt') 5 | Out-Null
        $script:ProtectedPaths = @((Resolve-SwSafePath -Path $inner))
        $tree = Get-SwSafeDirectoryTreeItems -Path $script:Root
        $tree['Success'] | Should -BeFalse
        [string]$tree['Reason'] | Should -BeLike ('*' + (Get-Tail $inner) + '*')
    }
}

# ============================================================================
# Sizes
# ============================================================================

Describe 'Size measurement' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        $script:Work = New-Work
        $script:Config = @{ ConfigPath = (P $script:Work 'appdata' 'config'); CachePath = (P $script:Work 'appdata' 'cache'); WhitelistFile = (P $script:Work 'appdata' 'config' 'whitelist.txt') }
        $script:SwWalkBudgetSeconds = 15
        $script:Root = New-Dir (P $script:Work 'root')
    }
    AfterEach { Stop-Case }

    It 'F-16 gives the length of a file' {
        $file = New-File (P $script:Work 'f.bin') 3000
        (Get-SwPathSize -Path $file) | Should -Be 3000
    }

    It 'F-16 gives a single [long] value' {
        $file = New-File (P $script:Work 'f.bin') 12
        $result = @(Get-SwPathSize -Path $file)
        $result.Count | Should -Be 1
        $result[0] | Should -BeOfType [long]
    }

    It 'F-16 gives 0 for a path that does not exist' {
        (Get-SwPathSize -Path (P $script:Work 'NonExistent' 'Path' '12345')) | Should -Be 0
        (Get-SwPathSize -Path (P $script:Work 'missing')) | Should -Be 0
    }

    It 'F-16 gives the sum of all files below a folder, counting no folder' {
        Use-FakeIdentity
        New-File (P $script:Root 'a.bin') 3000 | Out-Null
        New-File (P $script:Root 'nested' 'b.bin') 5000 | Out-Null
        New-Dir (P $script:Root 'empty') | Out-Null
        (Get-SwPathSize -Path $script:Root) | Should -Be 8000
    }

    It 'F-16 gives 0 for an empty folder' {
        Use-FakeIdentity
        (Get-SwPathSize -Path $script:Root) | Should -Be 0
    }

    It 'F-16 measures with one walk that skips unreadable folders' {
        Use-FakeIdentity
        New-File (P $script:Root 'a.bin') 10 | Out-Null
        Mock Get-SwTreeItems { @() }
        $null = Get-SwPathSize -Path $script:Root
        Should -Invoke -CommandName Get-SwTreeItems -Times 1 -Exactly -ParameterFilter { $SkipUnreadable }
    }

    It 'F-16 gives 0 for a folder that is a link, without walking' {
        Use-FakeIdentity
        $target = New-Dir (P $script:Work 'target')
        New-File (P $target 'big.bin') 4000 | Out-Null
        $link = P $script:Work 'link'
        New-TestLink $link $target
        Mock Get-SwTreeItems { throw 'a link must not be walked' }
        try {
            (Get-SwPathSize -Path $link) | Should -Be 0
            Should -Invoke -CommandName Get-SwTreeItems -Times 0 -Exactly
        }
        finally { Remove-TestLink $link }
    }

    It 'F-16 counts a link inside a folder as 0 and does not count what it points to' {
        Use-FakeIdentity
        $target = New-Dir (P $script:Work 'target')
        New-File (P $target 'big.bin') 4000 | Out-Null
        New-File (P $script:Root 'own.bin') 100 | Out-Null
        $link = P $script:Root 'link'
        New-TestLink $link $target
        try { (Get-SwPathSize -Path $script:Root) | Should -Be 100 }
        finally { Remove-TestLink $link }
    }

    It 'F-16 counts a file that is a link as 0' {
        $file = New-File (P $script:Work 'real.bin') 3000
        $link = P $script:Work 'filelink.bin'
        try { New-TestLink $link $file }
        catch { Set-ItResult -Skipped -Because 'this host does not allow file links for this user'; return }
        try { (Get-SwPathSize -Path $link) | Should -Be 0 }
        finally { Remove-TestLink $link }
    }

    It 'F-16 gives 0 and no exception when the time budget is used up' {
        Use-FakeIdentity
        New-File (P $script:Root 'a.bin') 3000 | Out-Null
        $script:SwWalkBudgetSeconds = 0
        $result = Get-Result { Get-SwPathSize -Path $script:Root }
        $result | Should -Be 0
    }

    It 'F-16 gives 0 and no exception when the folder has no identity' {
        Mock Get-SwPathSnapshot { $null }
        Mock Test-SwPathSnapshot { $true }
        New-File (P $script:Root 'a.bin') 3000 | Out-Null
        $result = Get-Result { Get-SwPathSize -Path $script:Root }
        $result | Should -Be 0
    }

    It 'F-16 gives 0 and no exception when the folder was replaced during the walk' {
        New-File (P $script:Root 'a.bin') 3000 | Out-Null
        Mock Get-SwPathSnapshot { [pscustomobject]@{ Path = $Path } }
        Mock Test-SwPathSnapshot { $false }
        $result = Get-Result { Get-SwPathSize -Path $script:Root }
        $result | Should -Be 0
    }

    It 'F-16 gives 0 when the walk throws' {
        New-File (P $script:Root 'a.bin') 3000 | Out-Null
        Mock Get-SwTreeItems { throw 'walk-canary' }
        (Get-SwPathSize -Path $script:Root) | Should -Be 0
    }

    It 'F-16 treats a path with brackets literally and measures only that folder' {
        Use-FakeIdentity
        $odd = New-Dir (P $script:Work 'Cache [1]')
        $decoy = New-Dir (P $script:Work 'Cache 1')
        New-File (P $odd 'f.bin') 123 | Out-Null
        New-File (P $decoy 'f.bin') 999 | Out-Null
        (Get-SwPathSize -Path $odd) | Should -Be 123
        (Get-SwPathSize -Path $decoy) | Should -Be 999
        (Get-SwPathSize -Path (P $script:Work 'Cache [*]')) | Should -Be 0
    }

    It 'G-6 measures a folder and a file whose name contains <Label>' -ForEach $script:OddNames {
        Use-FakeIdentity
        $folder = New-Dir (P $script:Work $Name)
        New-File (P $folder 'f.bin') 77 | Out-Null
        (Get-SwPathSize -Path $folder) | Should -Be 77
        $file = New-File (P $script:Work ($Name + '.bin')) 55
        (Get-SwPathSize -Path $file) | Should -Be 55
    }

    It 'F-16 [W] gives the sum of all files below a folder with real identities' {
        New-File (P $script:Root 'a.bin') 3000 | Out-Null
        New-File (P $script:Root 'nested' 'b.bin') 5000 | Out-Null
        (Get-SwPathSize -Path $script:Root) | Should -Be 8000
        (Get-SwPathSizeKB -Path $script:Root) | Should -Be 8
    }

    It 'F-16 [W] gives 0 for a junction to a folder with files and for a folder that holds it' {
        $target = New-Dir (P $script:Work 'target')
        New-File (P $target 'big.bin') 4000 | Out-Null
        $link = P $script:Root 'link'
        New-TestLink $link $target
        try {
            (Get-SwPathSize -Path $link) | Should -Be 0
            (Get-SwPathSize -Path $script:Root) | Should -Be 0
        }
        finally { Remove-TestLink $link }
    }

    It 'F-16 gives ceil(bytes / 1024) kilobytes as a whole number: <Bytes> bytes are <Expected> KB' -ForEach $script:KbCases {
        $file = New-File (P $script:Work ('kb' + $Bytes + '.bin')) $Bytes
        $actual = Get-SwPathSizeKB -Path $file
        $actual | Should -Be $Expected
        @($actual).Count | Should -Be 1
        ($actual -is [int] -or $actual -is [long]) | Should -BeTrue
    }

    It 'F-16 gives 0 kilobytes for a path that does not exist' {
        (Get-SwPathSizeKB -Path (P $script:Work 'missing')) | Should -Be 0
    }

    It 'F-16 gives the kilobytes of a folder from the same measurement' {
        Use-FakeIdentity
        New-File (P $script:Root 'a.bin') 3000 | Out-Null
        New-File (P $script:Root 'nested' 'b.bin') 5000 | Out-Null
        (Get-SwPathSizeKB -Path $script:Root) | Should -Be 8
        New-File (P $script:Root 'c.bin') 1 | Out-Null
        (Get-SwPathSizeKB -Path $script:Root) | Should -Be 8
        New-File (P $script:Root 'd.bin') 1000 | Out-Null
        (Get-SwPathSizeKB -Path $script:Root) | Should -Be 9
    }

    It 'F-16 never throws for odd text (<Label>) and gives 0' -ForEach $script:HostileText {
        $size = Get-Result { Get-SwPathSize -Path $Text }
        $kb = Get-Result { Get-SwPathSizeKB -Path $Text }
        $size | Should -Be 0
        $kb | Should -Be 0
    }

    It 'F-17 adds the length of the files and ignores folders' {
        $items = @(
            [pscustomobject]@{ FullName = 'x\a'; PSIsContainer = $false; Length = 3000 }
            [pscustomobject]@{ FullName = 'x\b'; PSIsContainer = $false; Length = 5000 }
            [pscustomobject]@{ FullName = 'x\dir'; PSIsContainer = $true; Length = 99999 }
        )
        $size = Get-SwValidatedTreeSize -Tree @{ Items = $items }
        $size | Should -Be 8000
        $size | Should -BeOfType [long]
        @($size).Count | Should -Be 1
    }

    It 'F-17 gives 0 for an empty list, an empty table, a table without Items and a $null table' {
        (Get-SwValidatedTreeSize -Tree @{ Items = @() }) | Should -Be 0
        (Get-SwValidatedTreeSize -Tree @{}) | Should -Be 0
        (Get-SwValidatedTreeSize -Tree @{ Items = $null }) | Should -Be 0
        (Get-SwValidatedTreeSize -Tree $null) | Should -Be 0
    }

    It 'F-17 skips $null entries' {
        $items = @($null, [pscustomobject]@{ FullName = 'x\a'; PSIsContainer = $false; Length = 10 }, $null)
        (Get-SwValidatedTreeSize -Tree @{ Items = $items }) | Should -Be 10
    }

    It 'F-17 accepts a single entry that is not wrapped in an array' {
        $item = [pscustomobject]@{ FullName = 'x\a'; PSIsContainer = $false; Length = 42 }
        (Get-SwValidatedTreeSize -Tree @{ Items = $item }) | Should -Be 42
    }

    It 'F-17 touches neither the file system nor a second walk' {
        Mock Get-SwTreeItems { throw 'no walk' }
        Mock Get-SwPathSize { throw 'no measurement' }
        Mock Get-ChildItem { throw 'no listing' }
        Mock Get-SwPathSnapshot { throw 'no identity' }
        $items = @([pscustomobject]@{ FullName = (P $script:Work 'does' 'not' 'exist.bin'); PSIsContainer = $false; Length = 5 })
        (Get-SwValidatedTreeSize -Tree @{ Items = $items }) | Should -Be 5
        Should -Invoke -CommandName Get-SwTreeItems -Times 0 -Exactly
        Should -Invoke -CommandName Get-SwPathSize -Times 0 -Exactly
        Should -Invoke -CommandName Get-ChildItem -Times 0 -Exactly
    }

    It 'F-17 does not throw for entries without a length' {
        $items = @([pscustomobject]@{ FullName = 'x\a'; PSIsContainer = $false })
        { $null = Get-SwValidatedTreeSize -Tree @{ Items = $items } } | Should -Not -Throw
    }

    It 'G-5 gives the same sizes under every error preference (<Preference>)' -ForEach @(
        @{ Preference = 'Stop' }
        @{ Preference = 'Continue' }
        @{ Preference = 'SilentlyContinue' }
    ) {
        $file = New-File (P $script:Work 'f.bin') 2048
        $ErrorActionPreference = $Preference
        $records = @(& {
                Get-SwPathSize -Path $file
                Get-SwPathSizeKB -Path $file
                Get-SwPathSize -Path (P $script:Work 'missing')
                Get-SwPathSize -Path ('a' + [char]0 + 'b')
                Get-SwValidatedTreeSize -Tree @{ Items = @() }
            } 2>&1)
        @($records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count | Should -Be 0
        @($records | ForEach-Object { [string]$_ }) | Should -Be @('2048', '2', '0', '0', '0')
    }
}

# ============================================================================
# Not measured
# ============================================================================

Describe 'Add-SwNotMeasured' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        $script:NotMeasuredCollector = $null
        $script:CurrentSection = @{ Active = $false; Activity = $false; Name = 'Example section' }
    }
    AfterEach { Stop-Case }

    It 'F-38 does nothing without a collector' {
        $script:NotMeasuredCollector = $null
        { Add-SwNotMeasured -Name 'Disk Cleanup tool' -Reason 'not previewable' } | Should -Not -Throw
        $script:NotMeasuredCollector | Should -BeNullOrEmpty
    }

    It 'F-38 adds an entry with the section, the name and the reason' {
        $script:NotMeasuredCollector = New-Object 'System.Collections.Generic.List[object]'
        Add-SwNotMeasured -Name 'Disk Cleanup tool' -Reason 'not previewable'
        $script:NotMeasuredCollector.Count | Should -Be 1
        $entry = $script:NotMeasuredCollector[0]
        $entry.Section | Should -BeExactly 'Example section'
        $entry.Name | Should -BeExactly 'Disk Cleanup tool'
        $entry.Reason | Should -BeExactly 'not previewable'
    }

    It 'F-38 adds at most one entry per name, whatever the reason' {
        $script:NotMeasuredCollector = New-Object 'System.Collections.Generic.List[object]'
        Add-SwNotMeasured -Name 'Disk Cleanup tool' -Reason 'not previewable'
        Add-SwNotMeasured -Name 'Disk Cleanup tool' -Reason 'not previewable'
        Add-SwNotMeasured -Name 'Disk Cleanup tool' -Reason 'another reason'
        $script:NotMeasuredCollector.Count | Should -Be 1
        $script:NotMeasuredCollector[0].Reason | Should -BeExactly 'not previewable'
    }

    It 'F-38 adds a second entry for a second name' {
        $script:NotMeasuredCollector = New-Object 'System.Collections.Generic.List[object]'
        Add-SwNotMeasured -Name 'First' -Reason 'a'
        Add-SwNotMeasured -Name 'Second' -Reason 'b'
        @($script:NotMeasuredCollector | ForEach-Object { $_.Name }) | Should -Be @('First', 'Second')
    }

    It 'F-38 takes the section name from the current section at the time of the call' {
        $script:NotMeasuredCollector = New-Object 'System.Collections.Generic.List[object]'
        $script:CurrentSection = @{ Active = $true; Activity = $false; Name = 'One' }
        Add-SwNotMeasured -Name 'A' -Reason 'r'
        $script:CurrentSection = @{ Active = $true; Activity = $false; Name = 'Two' }
        Add-SwNotMeasured -Name 'B' -Reason 'r'
        @($script:NotMeasuredCollector | ForEach-Object { $_.Section }) | Should -Be @('One', 'Two')
    }

    It 'F-38 never throws and writes nothing to the pipeline' {
        $script:NotMeasuredCollector = New-Object 'System.Collections.Generic.List[object]'
        $output = @(Add-SwNotMeasured -Name 'A' -Reason 'r')
        $output.Count | Should -Be 0
        $script:NotMeasuredCollector = $null
        @(Add-SwNotMeasured -Name 'A' -Reason 'r').Count | Should -Be 0
    }
}

Describe 'Interface of the guard functions' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
    }

    It 'E36 offers <Name> as a function with exactly the documented parameters' -ForEach $script:Interface {
        $command = Get-Command -Name $Name -CommandType Function -ErrorAction Stop
        $common = [System.Management.Automation.Cmdlet]::CommonParameters + [System.Management.Automation.Cmdlet]::OptionalCommonParameters
        $declared = @($command.Parameters.Keys | Where-Object { $_ -notin $common } | Sort-Object)
        ($declared -join ',') | Should -BeExactly ((@($Parameters) | Sort-Object) -join ',')
        foreach ($parameter in $Parameters) {
            $attribute = $command.Parameters[$parameter].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | Select-Object -First 1
            $mandatory = ($null -ne $attribute -and [bool]$attribute.Mandatory)
            if ($parameter -in @($Mandatory)) { $mandatory | Should -BeTrue -Because "-$parameter is mandatory" }
        }
        if ($Position0) {
            $attribute = $command.Parameters[$Position0].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } | Select-Object -First 1
            $attribute.Position | Should -Be 0 -Because "-$Position0 is the first positional parameter"
        }
    }

    It 'E36 gives the switch parameters of the guard functions the type switch' {
        (Get-Command Get-SwPathSnapshot).Parameters['AllowLeafLink'].ParameterType | Should -Be ([System.Management.Automation.SwitchParameter])
        (Get-Command Get-SwTreeItems).Parameters['SkipUnreadable'].ParameterType | Should -Be ([System.Management.Automation.SwitchParameter])
    }
}

# ============================================================================
# Old names (forwarding functions) of the guard half
# ============================================================================

Describe 'Transition names of the guard functions' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        $script:Work = New-Work
        $script:Config = @{ ConfigPath = (P $script:Work 'appdata' 'config'); CachePath = (P $script:Work 'appdata' 'cache'); WhitelistFile = (P $script:Work 'appdata' 'config' 'whitelist.txt') }
        $script:DefaultWhitelistPatterns = @()
        $script:ProtectedPaths = @((P $script:Work 'protected'))
        $script:ExactProtectedPaths = @()
        $script:SweeprCleanPathGuard = $false
        $script:SwWalkBudgetSeconds = 15
    }
    AfterEach { Stop-Case }

    It 'Keeps <Old> as a function, not an alias' -ForEach $script:Forwarders {
        (Get-Command -Name $Old -ErrorAction Stop).CommandType | Should -Be 'Function'
        Get-Alias -Name $Old -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        (Get-Command -Name $New -ErrorAction Stop).CommandType | Should -Be 'Function'
    }

    It 'Gives <Old> the same parameters as <New> (names, types, positions, mandatory flags, defaults)' -ForEach $script:Forwarders {
        $old = Get-ParamSignature $Old
        $new = Get-ParamSignature $New
        (@($old) -join "`n") | Should -BeExactly (@($new) -join "`n")
    }

    It 'Forwards <Old> to <New> with the same arguments' -ForEach $script:Forwarders {
        Mock -CommandName $New -MockWith { 'forwarded' }
        $result = & $Invoke
        if ($Pass) { $result | Should -Be 'forwarded' }
        Should -Invoke -CommandName $New -Times 1 -Exactly -ParameterFilter $Filter
    }

    It 'Test-SafePath gives the same answers as Test-SwSafePath' {
        $keep = P $script:Work 'keep'
        Set-Whitelist @($keep)
        foreach ($path in @((P $script:Work 'protected' 'child'), $keep, (P $script:Work 'free'), '   ')) {
            Test-SafePath -Path $path | Should -Be (Test-SwSafePath -Path $path)
        }
        Test-SafePath (P $script:Work 'free') | Should -BeTrue
    }

    It 'Get-PathSize, Get-PathSizeKB and Get-ValidatedTreeSize give the same results as the new functions' {
        $file = New-File (P $script:Work 'f.bin') 1500
        Get-PathSize -Path $file | Should -Be (Get-SwPathSize -Path $file)
        Get-PathSizeKB -Path $file | Should -Be (Get-SwPathSizeKB -Path $file)
        $tree = @{ Items = @([pscustomobject]@{ FullName = 'x'; PSIsContainer = $false; Length = 9 }) }
        Get-ValidatedTreeSize -Tree $tree | Should -Be (Get-SwValidatedTreeSize -Tree $tree)
    }

    It 'Test-IsReparsePoint and Get-SweeprPathSnapshot give the same results as the new functions' {
        $dir = New-Dir (P $script:Work 'dir')
        Test-IsReparsePoint -Path $dir | Should -Be (Test-SwReparsePoint -Path $dir)
        $old = Get-SweeprPathSnapshot -Path $dir
        $new = Get-SwPathSnapshot -Path $dir
        ($null -eq $old) | Should -Be ($null -eq $new)
        Test-SweeprPathSnapshot -Snapshot $null | Should -Be (Test-SwPathSnapshot -Snapshot $null)
    }

    It 'Add-SweeprNotMeasured adds the same entry as Add-SwNotMeasured' {
        $script:NotMeasuredCollector = New-Object 'System.Collections.Generic.List[object]'
        Add-SweeprNotMeasured -Name 'Old name' -Reason 'because'
        $script:NotMeasuredCollector.Count | Should -Be 1
        $script:NotMeasuredCollector[0].Name | Should -BeExactly 'Old name'
        $script:NotMeasuredCollector[0].Reason | Should -BeExactly 'because'
    }

    It 'Get-TreeItemsNoFollow and Get-SafeDirectoryTreeItems give the same results as the new functions' {
        Use-FakeIdentity
        $root = New-Dir (P $script:Work 'root')
        New-File (P $root 'a.txt') 5 | Out-Null
        New-File (P $root 'sub' 'b.txt') 5 | Out-Null
        $oldNames = @(Get-TreeItemsNoFollow -Path $root | ForEach-Object { $_.FullName } | Sort-Object)
        $newNames = @(Get-SwTreeItems -Path $root | ForEach-Object { $_.FullName } | Sort-Object)
        $oldNames -join '|' | Should -BeExactly ($newNames -join '|')
        $oldTree = Get-SafeDirectoryTreeItems -Path $root
        $newTree = Get-SwSafeDirectoryTreeItems -Path $root
        $oldTree['Success'] | Should -Be $newTree['Success']
        @($oldTree['Items']).Count | Should -Be @($newTree['Items']).Count
    }

    It 'Does not let a mock of an old name reach into the module: calls inside the module use the new names' {
        Use-FakeIdentity
        $root = New-Dir (P $script:Work 'root')
        New-File (P $root 'a.txt') 5 | Out-Null
        New-File (P $root 'sub' 'b.txt') 5 | Out-Null
        Mock Get-SweeprPathSnapshot { throw 'old snapshot name used inside the module' }
        Mock Test-SweeprPathSnapshot { $false }
        Mock Test-SafePath { $false }
        Mock Get-TreeItemsNoFollow { throw 'old walk name used inside the module' }
        Mock Get-PathSize { throw 'old size name used inside the module' }
        Mock Get-ValidatedTreeSize { throw 'old measurement name used inside the module' }
        Mock Test-IsReparsePoint { throw 'old reparse name used inside the module' }
        $tree = Get-SwSafeDirectoryTreeItems -Path $root
        $tree['Success'] | Should -BeTrue
        @($tree['Items']).Count | Should -Be 3
        (Get-SwPathSize -Path $root) | Should -Be 10
        (Get-SwPathSize -Path (P $root 'a.txt')) | Should -Be 5
        (Test-SwPathSnapshot -Snapshot (Get-SwPathSnapshot -Path $root)) | Should -BeTrue
        (Test-SwSafePath -Path (P $root 'a.txt')) | Should -BeTrue
    }
}
