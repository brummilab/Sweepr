# Sweepr - tests for the protection rules, the whitelist, the list-file readers and the safe path
# resolution of lib\core\base.ps1.
#
# Interface pinned here (new names, each old name stays as a forwarding function, not an alias):
#   Test-SwProtectedPath -Path [-AlreadyResolved]   $true = must not be changed; fails closed
#   Resolve-SwSafePath -Path                        final spelling of the path, or $null
#   Get-SwWhitelistState                            opaque state for any number of candidates
#   Test-SwWhitelisted -Path [-State]               $true = protected
#   Read-SwListBytes -Path                          bytes of a list file, read with shared access
#   ConvertFrom-SwListBytes -Bytes                  lines (BOM removed, CRLF/CR/LF)
#   ConvertFrom-SwListEntry -Line [-IncludeRaw]     the path an entry means, or $null
# Variables that tests replace: $script:ProtectedPaths, $script:ExactProtectedPaths,
# $script:DefaultWhitelistPatterns, $script:SweeprCleanPathGuard and $script:Config.
#
# Seams used with Mock:
#   Read-SwListBytes   the only way Get-SwWhitelistState reads the whitelist file
#   Get-Item           called with -LiteralPath for the existence and metadata of the whitelist file
#
# Platform notes:
#   - Paths are built from $TestDrive, with a backslash appended for the child part. The comparison
#     treats both separators alike, so the rules run on Windows and on Linux.
#   - Whitelist candidates are plain text such as C:\Data\Cache; nothing is looked up on disk for them.
#   - Tests marked [W] need real Windows (drive letters of the system folders, junctions, 8.3 names,
#     trailing-dot aliases, Windows PowerShell 5.1 path rules). They are meant to fail on Linux and
#     belong in tests/linux-known-failures.txt.
#   - Nothing real is touched: junction tests link folders of $TestDrive only and remove each link
#     before the test ends; no function under test writes, deletes or starts a process.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    $script:SegmentsAll = @(
        @{ Segment = 'Microsoft\Credentials' }
        @{ Segment = 'Microsoft\Protect' }
        @{ Segment = 'Microsoft\Crypto' }
        @{ Segment = 'Microsoft\Vault' }
        @{ Segment = 'Microsoft\SystemCertificates' }
        @{ Segment = 'Microsoft\Windows\Start Menu' }
    )
    $script:SegmentsClean = foreach ($segment in @(
            '.ssh', '.gnupg', '.aws', '.azure', '.kube', '.docker', 'Login Data', 'Cookies', 'Web Data', 'Local Storage',
            'Session Storage', 'IndexedDB', 'Sessions', 'Local Extension Settings', 'Sync Data', 'Service Worker\CacheStorage',
            'Adobe\Common\Team Projects Cache', 'pypoetry\Cache\virtualenvs', 'User\History', '.claude\projects',
            '.claude\file-history', '.claude\history.jsonl', '.codex\sessions', '.codex\archived_sessions', '.codex\history.jsonl')) {
        @{ Segment = $segment }
    }
    $script:FixedPrefixEntries = foreach ($entry in @(
            'C:\Windows', 'C:\Windows\System32', 'C:\Windows\SysWOW64', 'C:\Program Files', 'C:\Program Files (x86)',
            'C:\Program Files\Windows Defender', 'C:\Program Files (x86)\Windows Defender', 'C:\ProgramData\Microsoft\Windows Defender')) {
        @{ Entry = $entry }
    }
    $script:DefaultEntries = @(
        @{ Name = 'Explorer'; Template = '{L}\Microsoft\Windows\Explorer'; Child = 'iconcache.db'; Sibling = 'Explorer-old' }
        @{ Name = 'Fonts'; Template = '{L}\Microsoft\Windows\Fonts'; Child = 'a.ttf'; Sibling = 'Fonts2' }
        @{ Name = 'Recent'; Template = '{R}\Microsoft\Windows\Recent'; Child = 'a.lnk'; Sibling = 'Recent2' }
        @{ Name = 'vscode extensions'; Template = '{U}\.vscode\extensions'; Child = 'x\package.json'; Sibling = 'extensions-old' }
        @{ Name = 'nuget'; Template = '{U}\.nuget'; Child = 'packages\x.nupkg'; Sibling = '.nuget-old' }
        @{ Name = 'cargo'; Template = '{U}\.cargo'; Child = 'registry\x'; Sibling = '.cargo-old' }
        @{ Name = 'rustup'; Template = '{U}\.rustup'; Child = 'toolchains\x'; Sibling = '.rustup2' }
        @{ Name = 'm2 repository'; Template = '{U}\.m2\repository'; Child = 'org\x.jar'; Sibling = 'repository-old' }
        @{ Name = 'gradle modules'; Template = '{U}\.gradle\caches\modules-2\files-*'; Child = ''; Sibling = '' }
        @{ Name = 'ollama models'; Template = '{U}\.ollama\models'; Child = 'blobs\x'; Sibling = 'models-old' }
        @{ Name = 'JetBrains'; Template = '{L}\JetBrains'; Child = 'IntelliJ\x'; Sibling = 'JetBrains2' }
    )

    # B-26: one whitelist line, one candidate, the expected answer.
    $patternRows = @(
        @('C:\Data\*\tmp', 'C:\Data\a\tmp', $true),
        @('C:\Data\*\tmp', 'C:\Data\a\b\tmp', $true),
        @('C:\Data\*\tmp', 'C:\Data\a\tmp\x', $true),
        @('C:\Data\*\tmp', 'C:\Data\a\tmpx', $false),
        @('C:\Data\a?c', 'C:\Data\abc', $true),
        @('C:\Data\a?c', 'C:\Data\abc\x', $true),
        @('C:\Data\a?c', 'C:\Data\ac', $false),
        @('C:\Data\a?c', 'C:\Data\abcd', $false),
        @('C:\Data\[a]b', 'C:\Data\[a]b', $true),
        @('C:\Data\[a]b', 'C:\Data\[a]b\x', $true),
        @('C:\Data\[a]b', 'C:\Data\ab', $true),
        @('C:\Data\[a]b', 'C:\Data\ab\x', $false),
        @('C:\Data\x`tick', 'C:\Data\x`tick', $true),
        @('C:\Data\x`tick', 'C:\Data\x`tick\child', $true),
        @('C:\Data\x`tick', 'C:\Data\y`tick', $false),
        @('C:\Data\x`tick', 'C:\Data\x`tickextra', $false),
        @('C:\Data\Cache*', 'C:\Data\Cache', $true),
        @('C:\Data\Cache*', 'C:\Data\Cache2\x', $true),
        @('C:\Data\Cache*', 'C:\Data\Cach', $false),
        @('c:\data\MIXED case', 'C:\DATA\mixed CASE\x', $true),
        @('C:\', 'C:\x', $true),
        @('C:\', 'D:\x', $false),
        @('   C:\Data\Padded   ', 'C:\Data\Padded\x', $true),
        @('\\srv\share\x', '\\srv\share\x\y', $true),
        @('\\srv\share\x', '\\SRV\share\x', $true),
        @('\\srv\share\x', '\\srv\share\xy', $false),
        @('C:\Data\Cache', 'C:\Data\Cache', $true),
        @('C:\Data\Cache', 'C:\Data\Cache\', $true),
        @('C:\Data\Cache', 'C:\Data\Cache\nested\data.bin', $true),
        @('C:\Data\Cache', 'C:\Data\Cache-other\data.bin', $false),
        @('C:\Data\Cache\', 'C:\Data\Cache\nested\data.bin', $true),
        @('C:\Data\Cache\', 'C:\Data\Cache-other\data.bin', $false),
        @('C:\Data\Cache', 'C:\Data', $false),
        @('C:\Data\Cache', 'C:\Data\Cache\..\Other', $true),
        @('C:\Data\[x]\cache', 'C:\Data\[x]\cache', $true),
        @('C:\Data\[x]\cache', 'C:\Data\[x]\cache\keep.txt', $true),
        @('C:\Data\[x]\cache', 'C:\Data\[x]\cache-other\keep.txt', $false),
        @('C:\Data\*\cache', 'C:\Data\other\cache', $true),
        @('C:\Data\*\cache', 'C:\Data\other\cache\keep.txt', $true),
        @('C:\Data\*\cache', 'C:\Data\other\cache-other', $false)
    )
    $script:PatternCases = foreach ($row in $patternRows) { @{ Line = $row[0]; Candidate = $row[1]; Expected = $row[2] } }

    # B-22: line, result without -IncludeRaw (null = no path), result with -IncludeRaw (list of strings).
    $entryRows = @(
        @('"C:\Users\Example\Projekt"', 'C:\Users\Example\Projekt', @('C:\Users\Example\Projekt')),
        @("'C:\Users\Example\Projekt'", 'C:\Users\Example\Projekt', @('C:\Users\Example\Projekt')),
        @('  "C:\Users\Example\Projekt"  ', 'C:\Users\Example\Projekt', @('C:\Users\Example\Projekt')),
        @('"  C:\Users\Example\Projekt  "', 'C:\Users\Example\Projekt', @('C:\Users\Example\Projekt')),
        @('C:/Users/Example/Other', 'C:\Users\Example\Other', @('C:\Users\Example\Other')),
        @('C:/Users\Example/Other', 'C:\Users\Example\Other', @('C:\Users\Example\Other')),
        @('"C:/Users/Example/Other/"', 'C:\Users\Example\Other\', @('C:\Users\Example\Other\')),
        @('~\Foo', 'C:\Users\Example\Foo', @('C:\Users\Example\Foo')),
        @('~/Foo', 'C:\Users\Example\Foo', @('C:\Users\Example\Foo')),
        @('"~\Foo"', 'C:\Users\Example\Foo', @('C:\Users\Example\Foo')),
        @('~', 'C:\Users\Example', @('C:\Users\Example')),
        @('~name', '~name', @('~name')),
        @('%LOCALAPPDATA%\Foo', 'C:\Users\Example\AppData\Local\Foo', @('C:\Users\Example\AppData\Local\Foo', '%LOCALAPPDATA%\Foo')),
        @('%LOCALAPPDATA%/Foo', 'C:\Users\Example\AppData\Local\Foo', @('C:\Users\Example\AppData\Local\Foo', '%LOCALAPPDATA%\Foo')),
        @('%SWTEST_D%\x', 'C:\Data\x', @('C:\Data\x', '%SWTEST_D%\x')),
        @('%SWTEST_R%\x', $null, @('%SWTEST_R%\x')),
        @('%SWTEST_ROOTREL%\x', $null, @('%SWTEST_ROOTREL%\x')),
        @('%SWTEST_U%\x', '\\srv\share\x', @('\\srv\share\x', '%SWTEST_U%\x')),
        @('%SWTEST_NEVER_DEFINED%\Foo', '%SWTEST_NEVER_DEFINED%\Foo', @('%SWTEST_NEVER_DEFINED%\Foo')),
        @('C:\Users\Example\%APPDATA%\npm-cache', 'C:\Users\Example\C:\Users\Example\AppData\Roaming\npm-cache', @('C:\Users\Example\C:\Users\Example\AppData\Roaming\npm-cache', 'C:\Users\Example\%APPDATA%\npm-cache')),
        @('/usr/x', '/usr/x', @('/usr/x')),
        @('//server/share', '\\server\share', @('\\server\share')),
        @('""', $null, @()),
        @("''", $null, @()),
        @('"   "', $null, @()),
        @('#c', $null, @()),
        @('# C:\x', $null, @()),
        @('#"C:\x"', $null, @()),
        @('', $null, @()),
        @('   ', $null, @()),
        @('"''x''"', '''x''', @('''x''')),
        @('C:\100%\x', 'C:\100%\x', @('C:\100%\x')),
        @('C:\x # c', 'C:\x # c', @('C:\x # c'))
    )
    $script:EntryCases = foreach ($row in $entryRows) { @{ Line = $row[0]; Plain = $row[1]; Raw = $row[2] } }

    $script:Forwarders = @(
        @{ Old = 'Test-ProtectedPath'; New = 'Test-SwProtectedPath'; Pass = $true
            Invoke = { Test-ProtectedPath 'Example-Path' -AlreadyResolved }; Filter = { $Path -eq 'Example-Path' -and $AlreadyResolved } }
        @{ Old = 'Resolve-SafePath'; New = 'Resolve-SwSafePath'; Pass = $true
            Invoke = { Resolve-SafePath -Path 'Example-Path' }; Filter = { $Path -eq 'Example-Path' } }
        @{ Old = 'Get-WhitelistState'; New = 'Get-SwWhitelistState'; Pass = $true
            Invoke = { Get-WhitelistState }; Filter = { $true } }
        @{ Old = 'Test-Whitelisted'; New = 'Test-SwWhitelisted'; Pass = $true
            Invoke = { Test-Whitelisted -Path 'Example-Path' -State 'state-object' }; Filter = { $Path -eq 'Example-Path' -and $State -eq 'state-object' } }
        @{ Old = 'Read-SweeprListBytes'; New = 'Read-SwListBytes'; Pass = $true
            Invoke = { Read-SweeprListBytes -Path 'Example-Path' }; Filter = { $Path -eq 'Example-Path' } }
        @{ Old = 'ConvertFrom-SweeprListBytes'; New = 'ConvertFrom-SwListBytes'; Pass = $true
            Invoke = { ConvertFrom-SweeprListBytes -Bytes ([byte[]](65, 66)) }; Filter = { @($Bytes).Count -eq 2 } }
        @{ Old = 'ConvertFrom-SweeprListEntry'; New = 'ConvertFrom-SwListEntry'; Pass = $true
            Invoke = { ConvertFrom-SweeprListEntry -Line 'C:\x' -IncludeRaw }; Filter = { $Line -eq 'C:\x' -and $IncludeRaw } }
    )

    $script:Encodings = @(
        @{ Kind = 'UTF-8 with BOM' }
        @{ Kind = 'UTF-8 without BOM' }
        @{ Kind = 'UTF-16 LE with BOM' }
        @{ Kind = 'UTF-16 BE with BOM' }
        @{ Kind = 'UTF-32 LE with BOM' }
        @{ Kind = 'UTF-32 BE with BOM' }
    )
    $script:AnyBytes = @(
        @{ Name = 'a lone 0xFF'; Bytes = [byte[]](0xFF) }
        @{ Name = 'a lone 0xFE'; Bytes = [byte[]](0xFE) }
        @{ Name = 'a truncated UTF-8 BOM'; Bytes = [byte[]](0xEF, 0xBB) }
        @{ Name = 'a UTF-16 BOM with an odd number of bytes'; Bytes = [byte[]](0xFF, 0xFE, 0x41) }
        @{ Name = 'a UTF-32 BOM and a partial character'; Bytes = [byte[]](0xFF, 0xFE, 0, 0, 0x41, 0) }
        @{ Name = 'invalid UTF-8'; Bytes = [byte[]](0x43, 0x3A, 0x5C, 0xC3, 0x28, 0x0A) }
        @{ Name = 'an unpaired UTF-16 surrogate'; Bytes = [byte[]](0xFF, 0xFE, 0x00, 0xD8, 0x41, 0x00) }
        @{ Name = 'only NUL bytes'; Bytes = [byte[]](0, 0, 0, 0, 0) }
        @{ Name = 'all byte values'; Bytes = [byte[]](0..255) }
    )
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:BaseFile = [System.IO.Path]::Combine($script:RepoRoot, 'lib', 'core', 'base.ps1')
    $script:OnWindows = [System.IO.Path]::DirectorySeparatorChar -eq '\'
    $script:IsDesktop = $PSVersionTable['PSEdition'] -eq 'Desktop'

    function script:Get-Cmp([string]$Path) { $Path.Replace('\', '/').TrimEnd('/').ToLowerInvariant() }

    function script:Get-Full([string]$Path) { Get-Cmp ([System.IO.Path]::GetFullPath($Path)) }

    # A path equals the expected one as typed or as .NET normalizes it (which may expand 8.3 names of the
    # temporary folder on Windows).
    function script:Assert-Path([string]$Actual, [string]$Expected) {
        $actualCmp = Get-Cmp $Actual
        $ok = ($actualCmp -eq (Get-Cmp $Expected)) -or ($actualCmp -eq (Get-Full $Expected))
        $ok | Should -BeTrue -Because "expected $Expected but got $Actual"
    }

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

    $script:StateNames = @('Config', 'Colors', 'Icons', 'ProtectedPaths', 'ExactProtectedPaths', 'DefaultWhitelistPatterns', 'SweeprCleanPathGuard', 'SWEEPR_BASE_LOADED')
    function script:Save-BaseState {
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
    function script:Restore-BaseState([hashtable]$State) {
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
    function script:Import-Base {
        $script:SWEEPR_BASE_LOADED = $false
        . $script:BaseFile
    }

    # Per-test save and restore of the module variables and the environment values the tests touch.
    function script:Start-Case {
        $script:SavedState = Save-BaseState
        $script:SavedEnv = Save-Env @('SWEEPR_DATA_DIR', 'USERPROFILE', 'LOCALAPPDATA', 'APPDATA', 'SYSTEMROOT', 'WINDIR')
    }
    function script:Stop-Case {
        Restore-Env $script:SavedEnv
        Restore-BaseState $script:SavedState
    }

    # Fixture for a block: fake profile and application data folders in the environment, then a fresh load.
    function script:Use-Fixture([string]$UserProfile, [string]$Local, [string]$Roaming, [hashtable]$Extra = @{}) {
        $script:FixtureNames = @('SWEEPR_DATA_DIR', 'USERPROFILE', 'LOCALAPPDATA', 'APPDATA') + @($Extra.Keys)
        $script:FixtureEnv = Save-Env $script:FixtureNames
        Set-Env 'SWEEPR_DATA_DIR' $null
        Set-Env 'USERPROFILE' $UserProfile
        Set-Env 'LOCALAPPDATA' $Local
        Set-Env 'APPDATA' $Roaming
        foreach ($name in $Extra.Keys) { Set-Env $name ([string]$Extra[$name]) }
        Import-Base
    }
    function script:Restore-Fixture { Restore-Env $script:FixtureEnv }

    # Path text with a backslash between the parts, whatever the host's separator is.
    function script:Win([string]$Base, [string]$Relative) { $Base.TrimEnd('\', '/') + '\' + $Relative }

    function script:Assert-Result($Actual, [bool]$Expected, [string]$Because) {
        $Actual | Should -BeOfType [bool] -Because $Because
        $Actual | Should -Be $Expected -Because $Because
    }

    function script:Test-Prot([string]$Path, [switch]$AlreadyResolved) {
        if ($AlreadyResolved) { return Test-SwProtectedPath -Path $Path -AlreadyResolved }
        Test-SwProtectedPath -Path $Path
    }

    function script:Use-ProcessDirectory([string]$Directory, [scriptblock]$Script) {
        $old = [System.Environment]::CurrentDirectory
        try {
            [System.Environment]::CurrentDirectory = $Directory
            & $Script
        }
        finally { [System.Environment]::CurrentDirectory = $old }
    }

    function script:New-TestJunction([string]$Link, [string]$Target) {
        [void](New-Item -ItemType Junction -Path $Link -Target $Target)
    }
    # Removes only the link itself, never anything it points to.
    function script:Remove-TestJunction([string]$Link) {
        if (-not [System.IO.Directory]::Exists($Link)) { return }
        try { [System.IO.Directory]::Delete($Link, $false) }
        catch { [System.IO.File]::Delete($Link) }
    }

    function script:Get-EncodedBytes([string]$Kind, [string]$Text) {
        switch ($Kind) {
            'UTF-8 with BOM' { $bom = [byte[]](0xEF, 0xBB, 0xBF); $body = [System.Text.Encoding]::UTF8.GetBytes($Text) }
            'UTF-8 without BOM' { $bom = [byte[]]@(); $body = [System.Text.Encoding]::UTF8.GetBytes($Text) }
            'UTF-16 LE with BOM' { $bom = [byte[]](0xFF, 0xFE); $body = [System.Text.Encoding]::Unicode.GetBytes($Text) }
            'UTF-16 BE with BOM' { $bom = [byte[]](0xFE, 0xFF); $body = [System.Text.Encoding]::BigEndianUnicode.GetBytes($Text) }
            'UTF-32 LE with BOM' { $bom = [byte[]](0xFF, 0xFE, 0, 0); $body = (New-Object System.Text.UTF32Encoding($false, $false)).GetBytes($Text) }
            'UTF-32 BE with BOM' { $bom = [byte[]](0, 0, 0xFE, 0xFF); $body = (New-Object System.Text.UTF32Encoding($true, $false)).GetBytes($Text) }
        }
        $all = New-Object System.Collections.Generic.List[byte]
        $all.AddRange([byte[]]$bom)
        $all.AddRange([byte[]]$body)
        , $all.ToArray()
    }

    # The items of a result that may be nothing, one string or an array of strings.
    function script:Get-Items($Result) {
        $items = New-Object System.Collections.Generic.List[string]
        foreach ($entry in @($Result)) {
            if ($entry -is [array]) { foreach ($inner in $entry) { $items.Add([string]$inner) } }
            elseif ($null -ne $entry) { $items.Add([string]$entry) }
        }
        , $items.ToArray()
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

    # The module variables as they were before this file loaded the module; put back after the last test.
    $script:ProtectionRootState = Save-BaseState
    . $script:BaseFile

    $script:SavedState = $null
    $script:SavedEnv = $null

    # What the whole file may change in the process, put back after the last test.
    $script:ProtectionRootEnv = Save-Env @('SWEEPR_DATA_DIR', 'USERPROFILE', 'LOCALAPPDATA', 'APPDATA', 'SYSTEMROOT', 'WINDIR', 'SWEEPR_DRY_RUN')
    $script:ProtectionRootDirectory = [System.Environment]::CurrentDirectory
}

AfterAll {
    Restore-BaseState $script:ProtectionRootState
    Restore-Env $script:ProtectionRootEnv
    [System.Environment]::CurrentDirectory = $script:ProtectionRootDirectory
}

# ============================================================================
# Protection rules (paths of $TestDrive)
# ============================================================================

Describe 'Test-SwProtectedPath rules' {
    BeforeAll {
        $script:FxRoot = [System.IO.Path]::Combine($TestDrive, 'prot-fixture')
        $script:FxHome = [System.IO.Path]::Combine($script:FxRoot, 'Users', 'Example')
        $script:FxLocal = Win $script:FxHome 'AppData\Local'
        $script:FxRoaming = Win $script:FxHome 'AppData\Roaming'
        $script:FxProt = [System.IO.Path]::Combine($script:FxRoot, 'protected')
        Use-Fixture -UserProfile $script:FxHome -Local $script:FxLocal -Roaming $script:FxRoaming
    }
    AfterAll { Restore-Fixture }
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        $script:ProtectedPaths = @($script:FxProt)
        $script:ExactProtectedPaths = @($script:FxHome)
        $script:SweeprCleanPathGuard = $false
    }
    AfterEach { Stop-Case }

    It 'B-2 protects an empty, blank or null path' {
        Assert-Result (Test-Prot '') $true 'empty'
        Assert-Result (Test-Prot '   ') $true 'blank'
        Assert-Result (Test-SwProtectedPath -Path $null) $true 'null'
        Assert-Result (Test-SwProtectedPath $null) $true 'null, positional'
        Assert-Result (Test-SwProtectedPath -Path '' -AlreadyResolved) $true 'empty with AlreadyResolved'
        Assert-Result (Test-SwProtectedPath -Path $null -AlreadyResolved) $true 'null with AlreadyResolved'
    }

    It 'B-2 protects a path that cannot be normalized, without throwing' {
        $bad = $script:FxRoot + '\bad' + [char]0 + 'name'
        { Test-SwProtectedPath -Path $bad } | Should -Not -Throw
        Assert-Result (Test-SwProtectedPath -Path $bad) $true 'NUL character'
        Assert-Result (Test-SwProtectedPath -Path $bad -AlreadyResolved) $true 'NUL character, AlreadyResolved'
    }

    It 'B-2 [W] protects a path with | or < under Windows PowerShell 5.1' {
        if (-not $script:IsDesktop) { Set-ItResult -Skipped -Because 'only Windows PowerShell 5.1 rejects these characters in a full path'; return }
        Assert-Result (Test-SwProtectedPath -Path 'C:\Users\Example\a|b') $true 'pipe'
        Assert-Result (Test-SwProtectedPath -Path 'C:\Users\Example\a<b') $true 'less-than'
    }

    It 'S-B1 gives a bool and never throws under ErrorActionPreference Stop' {
        $ErrorActionPreference = 'Stop'
        foreach ($path in @('', '   ', $null, ($script:FxRoot + '\x' + [char]0), (Win $script:FxProt 'child'), (Win $script:FxRoot 'other'))) {
            { Test-SwProtectedPath -Path $path } | Should -Not -Throw
            Test-SwProtectedPath -Path $path | Should -BeOfType [bool]
        }
    }

    It 'B-3 resolves a relative path against the working directory of the process, not the PowerShell location' {
        [void][System.IO.Directory]::CreateDirectory($script:FxRoot)
        $elsewhere = [System.IO.Path]::Combine($script:FxRoot, 'elsewhere')
        [void][System.IO.Directory]::CreateDirectory($elsewhere)
        Push-Location -LiteralPath $elsewhere
        try {
            Use-ProcessDirectory $script:FxRoot {
                Assert-Result (Test-SwProtectedPath -Path 'protected\child') $true 'relative below the entry'
                Assert-Result (Test-SwProtectedPath -Path 'protected') $true 'relative entry itself'
                Assert-Result (Test-SwProtectedPath -Path 'other\child') $false 'relative elsewhere'
            }
        }
        finally { Pop-Location }
    }

    It 'B-3 ignores a trailing backslash on the candidate and on the entry' {
        Assert-Result (Test-Prot ($script:FxProt + '\')) $true 'candidate with backslash'
        Assert-Result (Test-Prot (Win $script:FxProt 'child\')) $true 'child with backslash'
        $script:ProtectedPaths = @($script:FxProt + '\')
        Assert-Result (Test-Prot $script:FxProt) $true 'entry with backslash, candidate without'
        Assert-Result (Test-Prot (Win $script:FxProt 'child')) $true 'entry with backslash, child'
    }

    It 'B-3 compares without regard to case' {
        Assert-Result (Test-Prot $script:FxProt.ToUpperInvariant()) $true 'upper-case entry'
        Assert-Result (Test-Prot (Win $script:FxProt 'CHILD').ToUpperInvariant()) $true 'upper-case child'
        Assert-Result (Test-Prot (Win $script:FxProt 'child').ToLowerInvariant()) $true 'lower-case child'
    }

    It 'B-3 compares whole segments: a name that only begins like an entry is not protected' {
        Assert-Result (Test-Prot ($script:FxProt + '2\x')) $false 'protected2'
        Assert-Result (Test-Prot ($script:FxProt + '-old\x')) $false 'protected-old'
        Assert-Result (Test-Prot ($script:FxProt + 'ed')) $false 'protectedprotected'
        Assert-Result (Test-Prot ($script:FxProt + '.old')) $false 'protected.old'
    }

    It 'B-4 protects the profile root itself, with and without a trailing backslash and in any case' {
        Assert-Result (Test-Prot $script:FxHome) $true 'root'
        Assert-Result (Test-Prot ($script:FxHome + '\')) $true 'root with backslash'
        Assert-Result (Test-Prot $script:FxHome.ToUpperInvariant()) $true 'root upper-case'
    }

    It 'B-4 does not protect children of the profile root, a similar name or the parent' {
        Assert-Result (Test-Prot (Win $script:FxHome 'AppData\Local\Temp')) $false 'temp below the profile'
        Assert-Result (Test-Prot (Win $script:FxHome 'Documents')) $false 'documents'
        Assert-Result (Test-Prot ($script:FxHome + '2')) $false 'profile2'
        Assert-Result (Test-Prot (Win $script:FxRoot 'Users')) $false 'parent of the profile'
        Assert-Result (Test-Prot $script:FxRoot) $false 'grandparent'
    }

    It 'B-5 protects an entry of the prefix list, everything below it and a path below it that does not exist' {
        Assert-Result (Test-Prot $script:FxProt) $true 'entry'
        Assert-Result (Test-Prot (Win $script:FxProt 'System32')) $true 'child'
        Assert-Result (Test-Prot (Win $script:FxProt 'Does\Not\Exist\x')) $true 'deep nonexistent child'
        Assert-Result (Test-Prot (Win $script:FxProt 'a\b\c\d\e\f')) $true 'six levels down'
    }

    It 'B-5 does not protect an unrelated path, the temp folder or the parent of an entry' {
        Assert-Result (Test-Prot (Win $script:FxRoot 'other\x')) $false 'sibling folder'
        Assert-Result (Test-Prot ([System.IO.Path]::GetTempPath())) $false 'temp folder'
        Assert-Result (Test-Prot $script:FxRoot) $false 'parent of the entry'
    }

    It 'B-5 reads the prefix list at every call (an entry added or replaced takes effect at once)' {
        $other = Win $script:FxRoot 'second-entry'
        Assert-Result (Test-Prot (Win $other 'x')) $false 'before'
        $script:ProtectedPaths = @($script:FxProt, $other)
        Assert-Result (Test-Prot (Win $other 'x')) $true 'after adding'
        $script:ProtectedPaths = @($other)
        Assert-Result (Test-Prot (Win $script:FxProt 'x')) $false 'after replacing'
        $script:ProtectedPaths = @()
        Assert-Result (Test-Prot (Win $other 'x')) $false 'empty list'
    }

    It 'B-4 reads the exact list at every call' {
        $script:ExactProtectedPaths = @()
        Assert-Result (Test-Prot $script:FxHome) $false 'empty list'
        $script:ExactProtectedPaths = @((Win $script:FxRoot 'exact-one'))
        Assert-Result (Test-Prot (Win $script:FxRoot 'exact-one')) $true 'new entry'
        Assert-Result (Test-Prot (Win $script:FxRoot 'exact-one\child')) $false 'child of an exact entry'
    }

    It 'B-L1 skips empty entries and entries that cannot be normalized, without affecting the others' {
        $script:ProtectedPaths = @('', '   ', ($script:FxRoot + '\bad' + [char]0 + 'entry'), $script:FxProt)
        { Test-Prot (Win $script:FxProt 'child') } | Should -Not -Throw
        Assert-Result (Test-Prot (Win $script:FxProt 'child')) $true 'real entry still works'
        Assert-Result (Test-Prot (Win $script:FxRoot 'unrelated')) $false 'unrelated path'
        Use-ProcessDirectory $script:FxRoot {
            Assert-Result (Test-SwProtectedPath -Path 'anything\below\the\working\directory') $false 'an empty entry must not protect the working directory'
        }
    }

    It 'B-6 matches an entry and a candidate written differently (case, trailing backslash)' {
        $script:ProtectedPaths = @(($script:FxProt.ToUpperInvariant() + '\'))
        Assert-Result (Test-Prot (Win $script:FxProt 'child')) $true 'child'
        Assert-Result (Test-Prot $script:FxProt.ToLowerInvariant()) $true 'entry itself'
    }

    It 'B-12 does not protect drive roots or parents of entries through the lists' {
        $root = [System.IO.Path]::GetPathRoot($script:FxProt)
        Assert-Result (Test-Prot $root) $false 'drive root'
        Assert-Result (Test-Prot (Split-Path -Parent $script:FxHome)) $false 'parent of the profile'
        Assert-Result (Test-Prot (Split-Path -Parent $script:FxProt)) $false 'parent of a prefix entry'
    }

    It 'B-7 protects <Segment> at any depth, in any case, as the last segment and with a trailing backslash' -ForEach $script:SegmentsAll {
        $base = Win $script:FxRoaming $Segment
        $forms = @(
            @($base, 'as the last segment'),
            @(($base + '\'), 'with a trailing backslash'),
            @((Win $base 'ABCDEF'), 'one level below'),
            @((Win $base 'a\b\c\key'), 'several levels below'),
            @($base.ToUpperInvariant(), 'upper-case'),
            @($base.ToLowerInvariant(), 'lower-case'),
            @((Win $script:FxLocal $Segment), 'under Local'),
            @((Win $script:FxRoot ('deep\a\b\c\' + $Segment + '\x')), 'deeply nested')
        )
        foreach ($guard in $false, $true) {
            $script:SweeprCleanPathGuard = $guard
            foreach ($form in $forms) { Assert-Result (Test-Prot $form[0]) $true ("$($form[1]), guard $guard") }
        }
    }

    It 'B-7 does not match partial words or segments that are not consecutive' {
        $roaming = $script:FxRoaming
        $local = $script:FxLocal
        $negatives = @(
            (Win $roaming 'Microsoft\Cryptography\x'),
            (Win $roaming 'Microsoft\VaultCache\x'),
            (Win $roaming 'MyVault\x'),
            (Win $local 'Vault'),
            (Win $local 'Vault\x'),
            (Win $roaming 'Microsoft\Windows\Themes\Start Menu'),
            (Win $roaming 'Microsoft\x\Credentials'),
            (Win $roaming 'Microsoft\Windows\x\Start Menu'),
            (Win $roaming 'Credentials\x'),
            (Win $roaming 'Microsoft\Credentials2\x'),
            (Win $roaming 'MicrosoftX\Credentials\x'),
            (Win $roaming 'Windows\Start Menu\x')
        )
        foreach ($guard in $false, $true) {
            $script:SweeprCleanPathGuard = $guard
            foreach ($path in $negatives) { Assert-Result (Test-Prot $path) $false ("$path, guard $guard") }
        }
    }

    It 'B-7 protects the examples with Roaming, Local and Start Menu paths in any spelling' {
        $roaming = $script:FxRoaming
        $local = $script:FxLocal
        $examples = @(
            (Win $roaming 'Microsoft\Credentials\ABCDEF'),
            (Win $local 'Microsoft\Credentials'),
            (Win $roaming 'Microsoft\Protect\S-1-5-21-1\key'),
            (Win $roaming 'Microsoft\Crypto\RSA\x'),
            (Win $local 'Microsoft\Vault\4BF4C442'),
            (Win $roaming 'Microsoft\SystemCertificates\My\Certificates\c'),
            (Win $roaming 'Microsoft\Windows\Start Menu\Programs\App.lnk'),
            ($roaming.ToLowerInvariant() + '\microsoft\credentials\lower-case')
        )
        foreach ($path in $examples) { Assert-Result (Test-Prot $path) $true $path }
    }

    It 'B-8 protects <Segment> when the clean guard is on, in every spelling' -ForEach $script:SegmentsClean {
        $script:SweeprCleanPathGuard = $true
        $base = Win $script:FxRoaming $Segment
        Assert-Result (Test-Prot $base) $true 'as the last segment'
        Assert-Result (Test-Prot ($base + '\')) $true 'with a trailing backslash'
        Assert-Result (Test-Prot (Win $base 'child\deep.bin')) $true 'below'
        Assert-Result (Test-Prot $base.ToUpperInvariant()) $true 'upper-case'
        Assert-Result (Test-Prot (Win $script:FxHome $Segment)) $true 'directly below the profile'
        Assert-Result (Test-Prot (Win $script:FxRoot ('a\b\c\d\' + $Segment + '\x'))) $true 'deeply nested'
    }

    It 'S-B6 leaves <Segment> unprotected when the clean guard is off' -ForEach $script:SegmentsClean {
        $script:SweeprCleanPathGuard = $false
        $base = Win $script:FxRoaming $Segment
        Assert-Result (Test-Prot $base) $false 'as the last segment'
        Assert-Result (Test-Prot (Win $base 'child\deep.bin')) $false 'below'
        Assert-Result (Test-Prot $base.ToUpperInvariant()) $false 'upper-case'
    }

    It 'B-8 treats a guard that was never set as off, under strict mode' {
        Remove-Variable -Name SweeprCleanPathGuard -Scope Script -ErrorAction SilentlyContinue
        Set-StrictMode -Version Latest
        Assert-Result (Test-Prot (Win $script:FxHome '.ssh\id_ed25519')) $false 'ssh key without a guard'
        Assert-Result (Test-Prot (Win $script:FxRoot 'project\node_modules\cookies\index.js')) $false 'node_modules cookies'
        Assert-Result (Test-Prot (Win $script:FxRoaming 'Microsoft\Credentials\x')) $true 'all-command segment still applies'
    }

    It 'S-B6 reads the guard at every call' {
        $path = Win $script:FxHome '.ssh\id_ed25519'
        $script:SweeprCleanPathGuard = $true
        Assert-Result (Test-Prot $path) $true 'first, on'
        $script:SweeprCleanPathGuard = $false
        Assert-Result (Test-Prot $path) $false 'then off'
        $script:SweeprCleanPathGuard = $true
        Assert-Result (Test-Prot $path) $true 'on again'
    }

    It 'B-8 keeps node_modules\cookies and the ssh folder deletable without the guard' {
        Assert-Result (Test-Prot (Win $script:FxRoot 'project\node_modules\cookies\index.js')) $false 'cookies in a project'
        Assert-Result (Test-Prot (Win $script:FxHome '.ssh\id')) $false 'ssh without guard'
    }

    It 'B-8 does not match look-alike names with the guard on' {
        $script:SweeprCleanPathGuard = $true
        $roaming = $script:FxRoaming
        $negatives = @(
            (Win $script:FxHome '.awsome\cache\x'),
            (Win $script:FxHome '.sshd-cache\x'),
            (Win $script:FxHome '.claude\statsig\x'),
            (Win $script:FxHome '.codex\cache\x'),
            (Win $script:FxLocal 'Google\Chrome\User Data\Default\Cache\Cache_Data\f_000001'),
            (Win $roaming 'CookiesBackup\x'),
            (Win $roaming 'Code\CachedData\User\x'),
            (Win $roaming 'Code\User\HistoryOld\x'),
            (Win $script:FxHome '.claude\projects2\x'),
            (Win $script:FxHome '.codex\history.json')
        )
        foreach ($path in $negatives) { Assert-Result (Test-Prot $path) $false $path }
    }

    It 'B-8 protects the browser and tool examples with the guard on' {
        $script:SweeprCleanPathGuard = $true
        $home1 = $script:FxHome
        $roaming = $script:FxRoaming
        $local = $script:FxLocal
        $examples = @(
            (Win $home1 '.ssh\id_ed25519'), (Win $home1 '.SSH'), (Win $home1 '.gnupg\private-keys-v1.d\k.key'),
            (Win $home1 '.aws\cli\cache\token.json'), (Win $home1 '.azure\logs\az.log'), (Win $home1 '.kube\cache\discovery\x.json'),
            (Win $home1 '.docker\config.json'), (Win $local 'Google\Chrome\User Data\Default\Login Data'),
            (Win $local 'Google\Chrome\User Data\Default\Network\Cookies'), (Win $local 'Google\Chrome\User Data\Default\Web Data'),
            (Win $local 'Google\Chrome\User Data\Default\Local Storage\leveldb\000003.log'), (Win $local 'Google\Chrome\User Data\Default\local storage'),
            (Win $local 'Google\Chrome\User Data\Default\Session Storage\x'),
            (Win $local 'Google\Chrome\User Data\Default\IndexedDB\https_example.com_0.indexeddb.leveldb\1.log'),
            (Win $local 'Google\Chrome\User Data\Default\Sessions\Session_1'),
            (Win $local 'Google\Chrome\User Data\Default\Local Extension Settings\abc\000001.log'),
            (Win $local 'Google\Chrome\User Data\Default\Sync Data\LevelDB\x'),
            (Win $roaming 'Code\User\History\-1a2b\entries.json'),
            (Win $home1 '.claude\projects\proj\session.jsonl'), (Win $home1 '.claude\file-history\x'), (Win $home1 '.claude\history.jsonl'),
            (Win $home1 '.codex\sessions\2026\10\rollout.jsonl'), (Win $home1 '.codex\archived_sessions\rollout.jsonl'), (Win $home1 '.codex\history.jsonl')
        )
        foreach ($path in $examples) { Assert-Result (Test-Prot $path) $true $path }
    }

    It 'B-8 applies the segment rule to UNC paths as well' {
        $script:SweeprCleanPathGuard = $true
        Assert-Result (Test-SwProtectedPath -Path '\\srv\share\Users\Example\.ssh\id') $true 'clean segment'
        Assert-Result (Test-SwProtectedPath -Path '\\srv\share\Users\Example\AppData\Roaming\Microsoft\Credentials\x') $true 'all-command segment'
        Assert-Result (Test-SwProtectedPath -Path '\\srv\share\Users\Example\Documents') $false 'ordinary UNC path'
    }

    It 'B-11 with -AlreadyResolved applies the same rules to the given text' {
        $script:SweeprCleanPathGuard = $true
        Assert-Result (Test-Prot (Win $script:FxProt 'child') -AlreadyResolved) $true 'prefix list'
        Assert-Result (Test-Prot $script:FxHome -AlreadyResolved) $true 'exact list'
        Assert-Result (Test-Prot (Win $script:FxRoaming 'Microsoft\Credentials\x') -AlreadyResolved) $true 'all-command segment'
        Assert-Result (Test-Prot (Win $script:FxHome '.ssh\id') -AlreadyResolved) $true 'clean segment'
        Assert-Result (Test-Prot (Win $script:FxRoot 'other\x') -AlreadyResolved) $false 'ordinary path'
        Assert-Result (Test-Prot (Win $script:FxLocal 'Packages\Other_app\x') -AlreadyResolved) $true 'package folder'
    }

    It 'S-B5 cannot be bypassed by case, trailing backslash or deeper nesting' {
        foreach ($segment in 'Microsoft\Credentials', 'Microsoft\Vault') {
            $variants = @(
                (Win $script:FxRoaming $segment),
                ((Win $script:FxRoaming $segment).ToUpperInvariant()),
                ((Win $script:FxRoaming $segment) + '\'),
                ((Win $script:FxRoaming $segment) + '\\'),
                (Win $script:FxRoaming ($segment + '\a\b\c\d\e\f\g\h'))
            )
            foreach ($variant in $variants) { Assert-Result (Test-Prot $variant) $true $variant }
        }
    }
}

# ============================================================================
# Package folder rule
# ============================================================================

Describe 'Test-SwProtectedPath package folder' {
    BeforeAll {
        $script:FxRoot = [System.IO.Path]::Combine($TestDrive, 'pkg-fixture')
        $script:FxHome = [System.IO.Path]::Combine($script:FxRoot, 'Users', 'Example')
        $script:FxLocal = Win $script:FxHome 'AppData\Local'
        $script:FxRoaming = Win $script:FxHome 'AppData\Roaming'
        Use-Fixture -UserProfile $script:FxHome -Local $script:FxLocal -Roaming $script:FxRoaming
        $script:Packages = Win $script:FxLocal 'Packages'
        $script:Teams = $script:Packages + '\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView'
    }
    AfterAll { Restore-Fixture }
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        $script:ProtectedPaths = @()
        $script:ExactProtectedPaths = @()
        $script:SweeprCleanPathGuard = $false
    }
    AfterEach { Stop-Case }

    It 'B-9 protects the Packages folder and everything below it for all commands' {
        Assert-Result (Test-Prot $script:Packages) $true 'folder'
        Assert-Result (Test-Prot ($script:Packages + '\')) $true 'folder with backslash'
        Assert-Result (Test-Prot (Win $script:Packages 'Some.App_8wekyb3d8bbwe')) $true 'package'
        Assert-Result (Test-Prot (Win $script:Packages 'Some.App_8wekyb3d8bbwe\LocalCache\x.bin')) $true 'file in a package'
        Assert-Result (Test-Prot $script:Packages.ToUpperInvariant()) $true 'upper-case'
        Assert-Result (Test-Prot $script:Packages.ToLowerInvariant()) $true 'lower-case'
    }

    It 'B-9 does not protect a sibling whose name begins like Packages' {
        Assert-Result (Test-Prot (Win $script:FxLocal 'PackagesExtra\x')) $false 'PackagesExtra'
        Assert-Result (Test-Prot (Win $script:FxLocal 'Package\x')) $false 'Package'
        Assert-Result (Test-Prot (Win $script:FxLocal 'Temp')) $false 'Temp'
    }

    It 'B-9 does not apply, and does not break, when LOCALAPPDATA is empty' {
        Set-Env 'LOCALAPPDATA' ''
        Import-Base
        $script:ProtectedPaths = @()
        $script:ExactProtectedPaths = @()
        { Test-Prot (Win $script:FxRoot 'Packages\x') } | Should -Not -Throw
        Assert-Result (Test-Prot (Win $script:FxRoot 'Packages\x')) $false 'Packages below an unrelated folder'
        Assert-Result (Test-Prot '\Packages\x') $false 'root-relative Packages'
    }

    It 'B-9 lets the guard release only Teams WebView cache leaves: <Leaf>' -ForEach @(
        @{ Leaf = 'Default\Cache\entry' }
        @{ Leaf = 'Default\Cache\a\b\c\entry' }
        @{ Leaf = 'Default\Code Cache\js\x' }
        @{ Leaf = 'Default\GPUCache\data_0' }
        @{ Leaf = 'Profile 1\Cache\entry' }
        @{ Leaf = 'default\cache\entry' }
    ) {
        $path = $script:Teams + '\' + $Leaf
        $script:SweeprCleanPathGuard = $true
        Assert-Result (Test-Prot $path) $false 'with the guard'
        $script:SweeprCleanPathGuard = $false
        Assert-Result (Test-Prot $path) $true 'without the guard'
    }

    It 'B-9 keeps everything else under Packages protected with the guard on: <Path>' -ForEach @(
        @{ Path = '{T}\Default\IndexedDB\state' }
        @{ Path = '{T}\Default\CacheStorage\offline' }
        @{ Path = '{T}\Cache\entry' }
        @{ Path = '{T}\Default\Network\Cache\x' }
        @{ Path = '{T}\Default\Cache2\x' }
        @{ Path = '{T}\Default\Extensions\Cache\x' }
        @{ Path = '{P}\Other_app\LocalCache\Default\Cache\entry' }
        @{ Path = '{P}\MSTeams_8wekyb3d8bbwe\LocalCache\Default\Cache\entry' }
        @{ Path = '{P}\MSTeams_8wekyb3d8bbwe\LocalState\x' }
        @{ Path = '{P}\MSTeams_8wekyb3d8bbwe' }
        @{ Path = '{P}' }
    ) {
        $script:SweeprCleanPathGuard = $true
        $text = $Path.Replace('{T}', $script:Teams).Replace('{P}', $script:Packages)
        Assert-Result (Test-Prot $text) $true $text
    }

    It 'B-9 does not lift the other rules for a Teams cache leaf' {
        $script:SweeprCleanPathGuard = $true
        $leaf = $script:Teams + '\Default\Cache'
        Assert-Result (Test-Prot ($leaf + '\Local Storage\x')) $true 'clean segment inside the leaf'
        Assert-Result (Test-Prot ($leaf + '\Microsoft\Credentials\x')) $true 'all-command segment inside the leaf'
        $script:ProtectedPaths = @($leaf)
        Assert-Result (Test-Prot ($leaf + '\entry')) $true 'prefix entry covering the leaf'
        $script:ProtectedPaths = @()
        $script:ExactProtectedPaths = @($leaf)
        Assert-Result (Test-Prot $leaf) $true 'exact entry equal to the leaf'
    }
}

# ============================================================================
# Default lists after loading
# ============================================================================

Describe 'Default protection lists' {
    BeforeAll {
        $script:FxRoot = [System.IO.Path]::Combine($TestDrive, 'lists-fixture')
        $script:FxHome = [System.IO.Path]::Combine($script:FxRoot, 'Users', 'Example')
        Use-Fixture -UserProfile $script:FxHome -Local (Win $script:FxHome 'AppData\Local') -Roaming (Win $script:FxHome 'AppData\Roaming')
    }
    AfterAll { Restore-Fixture }
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
    }
    AfterEach { Stop-Case }

    It 'B-L2 holds the profile root as the only exact entry' {
        $entries = @($script:ExactProtectedPaths)
        $entries.Count | Should -Be 1
        Get-Cmp $entries[0] | Should -BeExactly (Get-Cmp $script:FxHome)
    }

    It 'B-L1 holds the eight system folders plus the values of SYSTEMROOT and WINDIR' {
        $saved = Save-Env @('SYSTEMROOT', 'WINDIR')
        try {
            Set-Env 'SYSTEMROOT' (Win $script:FxRoot 'sysroot')
            Set-Env 'WINDIR' (Win $script:FxRoot 'windir')
            Import-Base
            $expected = @('C:\Windows', 'C:\Windows\System32', 'C:\Windows\SysWOW64', 'C:\Program Files', 'C:\Program Files (x86)',
                'C:\Program Files\Windows Defender', 'C:\Program Files (x86)\Windows Defender', 'C:\ProgramData\Microsoft\Windows Defender',
                (Win $script:FxRoot 'sysroot'), (Win $script:FxRoot 'windir'))
            $actual = @($script:ProtectedPaths | ForEach-Object { Get-Cmp $_ } | Sort-Object)
            $actual.Count | Should -Be 10
            ($actual -join '|') | Should -BeExactly (@($expected | ForEach-Object { Get-Cmp $_ } | Sort-Object) -join '|')
            Assert-Result (Test-SwProtectedPath -Path (Win $script:FxRoot 'sysroot\System32\x')) $true 'below SYSTEMROOT'
            Assert-Result (Test-SwProtectedPath -Path (Win $script:FxRoot 'windir\x')) $true 'below WINDIR'
        }
        finally { Restore-Env $saved }
    }

    It 'B-L1 skips empty SYSTEMROOT and WINDIR values without protecting the working directory' {
        $saved = Save-Env @('SYSTEMROOT', 'WINDIR')
        try {
            Set-Env 'SYSTEMROOT' ''
            Set-Env 'WINDIR' ''
            Set-Env 'USERPROFILE' ''
            Import-Base
            { Test-SwProtectedPath -Path (Win $script:FxRoot 'some\folder') } | Should -Not -Throw
            [void][System.IO.Directory]::CreateDirectory($script:FxRoot)
            Use-ProcessDirectory $script:FxRoot {
                Assert-Result (Test-SwProtectedPath -Path 'some\folder') $false 'relative path in the working directory'
                Assert-Result (Test-SwProtectedPath -Path (Win $script:FxRoot 'some\folder')) $false 'absolute path in the working directory'
            }
        }
        finally { Restore-Env $saved }
    }

    It 'B-5 [W] protects <Entry> in every spelling and everything below it (default lists)' -ForEach $script:FixedPrefixEntries {
        Import-Base
        $forms = @($Entry, ($Entry + '\'), $Entry.ToUpperInvariant(), $Entry.ToLowerInvariant(), ($Entry + '\x'), ($Entry + '\Does\Not\Exist\x'), ($Entry + '\x\'))
        foreach ($form in $forms) { Assert-Result (Test-SwProtectedPath -Path $form) $true $form }
    }

    It 'B-5 [W] protects the system root and its children (default lists)' {
        Import-Base
        $root = $env:SYSTEMROOT
        $root | Should -Not -BeNullOrEmpty
        Assert-Result (Test-SwProtectedPath -Path $root) $true 'SYSTEMROOT'
        Assert-Result (Test-SwProtectedPath -Path ($root + '\System32\drivers')) $true 'drivers'
        Assert-Result (Test-SwProtectedPath -Path $env:WINDIR) $true 'WINDIR'
    }

    It 'B-5 [W] does not protect folders that only begin like a system folder (default lists)' {
        Import-Base
        Assert-Result (Test-SwProtectedPath -Path 'C:\Windows.old\x') $false 'Windows.old'
        Assert-Result (Test-SwProtectedPath -Path 'C:\Program Files Extra\x') $false 'Program Files Extra'
        Assert-Result (Test-SwProtectedPath -Path 'C:\Program Files (x86)2\x') $false 'Program Files (x86)2'
    }

    It 'B-12 [W] does not protect C:\, C:\Users or C:\ProgramData (default lists)' {
        Import-Base
        Assert-Result (Test-SwProtectedPath -Path 'C:\') $false 'C:\'
        Assert-Result (Test-SwProtectedPath -Path 'C:\Users') $false 'C:\Users'
        Assert-Result (Test-SwProtectedPath -Path 'C:\ProgramData') $false 'C:\ProgramData'
    }

    It 'B-10 [W] protects a path with a trailing dot in a segment of a system folder' {
        Import-Base
        Assert-Result (Test-SwProtectedPath -Path 'C:\Windows.\System32') $true 'Windows.'
        Assert-Result (Test-SwProtectedPath -Path ($env:SYSTEMROOT + '.\System32')) $true 'SYSTEMROOT with a dot'
    }

    It 'B-10 [W] protects the short name of a system folder' {
        Import-Base
        if (-not [System.IO.Directory]::Exists('C:\PROGRA~1')) { Set-ItResult -Skipped -Because '8.3 names are disabled on this volume'; return }
        Assert-Result (Test-SwProtectedPath -Path 'C:\PROGRA~1') $true 'C:\PROGRA~1'
        Assert-Result (Test-SwProtectedPath -Path 'C:\PROGRA~1\Windows Defender') $true 'short name with an existing child'
    }

    It 'B-6 [W] protects the long path when the list entry is a short name' {
        if (-not [System.IO.Directory]::Exists('C:\PROGRA~1')) { Set-ItResult -Skipped -Because '8.3 names are disabled on this volume'; return }
        $script:ProtectedPaths = @('C:\PROGRA~1')
        Assert-Result (Test-SwProtectedPath -Path 'C:\Program Files') $true 'long path'
        Assert-Result (Test-SwProtectedPath -Path 'C:\Program Files\Windows Defender') $true 'child of the long path'
    }
}

# ============================================================================
# Links and aliases (Windows file system)
# ============================================================================

Describe 'Test-SwProtectedPath links and aliases [W]' {
    BeforeAll {
        $script:FxRoot = [System.IO.Path]::Combine($TestDrive, 'link-fixture')
        $script:FxHome = [System.IO.Path]::Combine($script:FxRoot, 'Users', 'Example')
        $script:FxProt = [System.IO.Path]::Combine($script:FxRoot, 'protected')
        $script:FxOpen = [System.IO.Path]::Combine($script:FxRoot, 'open')
        Use-Fixture -UserProfile $script:FxHome -Local (Win $script:FxHome 'AppData\Local') -Roaming (Win $script:FxHome 'AppData\Roaming')
        $script:Links = New-Object System.Collections.Generic.List[string]
        $docs = [System.IO.Path]::Combine($script:FxHome, 'Docs')
        foreach ($dir in @($script:FxHome, $script:FxProt, $script:FxOpen, [System.IO.Path]::Combine($script:FxProt, 'child'), $docs)) { [void][System.IO.Directory]::CreateDirectory($dir) }
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($script:FxProt, 'file.txt'), 'x')
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($docs, 'file.txt'), 'x')
    }
    AfterAll {
        Restore-Fixture
        foreach ($link in $script:Links) { try { Remove-TestJunction $link } catch { $null = $_ } }
    }
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        $script:ProtectedPaths = @($script:FxProt)
        $script:ExactProtectedPaths = @($script:FxHome)
        $script:SweeprCleanPathGuard = $false
    }
    AfterEach { Stop-Case }

    It 'B-10 protects an existing path below a junction into a protected folder' {
        $link = Join-Path $script:FxRoot 'link-to-protected'
        New-TestJunction $link $script:FxProt
        $script:Links.Add($link)
        try {
            Assert-Result (Test-SwProtectedPath -Path (Join-Path $link 'child')) $true 'folder below the junction'
            Assert-Result (Test-SwProtectedPath -Path (Join-Path $link 'file.txt')) $true 'file below the junction'
            Assert-Result (Test-SwProtectedPath -Path $link) $true 'the junction itself'
        }
        finally { Remove-TestJunction $link }
    }

    It 'B-10 protects an existing path below a junction when the final spelling hits a segment rule' {
        $script:SweeprCleanPathGuard = $true
        $ssh = Join-Path $script:FxHome '.ssh'
        [void][System.IO.Directory]::CreateDirectory($ssh)
        [System.IO.File]::WriteAllText((Join-Path $ssh 'id'), 'x')
        $link = Join-Path $script:FxRoot 'link-to-ssh'
        New-TestJunction $link $ssh
        $script:Links.Add($link)
        try { Assert-Result (Test-SwProtectedPath -Path (Join-Path $link 'id')) $true 'file below a junction to .ssh' }
        finally { Remove-TestJunction $link }
    }

    It 'S-B4 protects the descendants of a junction named like a protected segment, but not the plain target spelling' {
        $parent = Join-Path $script:FxHome 'AppData\Roaming\Microsoft'
        [void][System.IO.Directory]::CreateDirectory($parent)
        $target = Join-Path $script:FxRoot 'cred-target'
        [void][System.IO.Directory]::CreateDirectory($target)
        [System.IO.File]::WriteAllText((Join-Path $target 'blob'), 'x')
        $link = Join-Path $parent 'Credentials'
        New-TestJunction $link $target
        $script:Links.Add($link)
        try {
            Assert-Result (Test-SwProtectedPath -Path (Join-Path $link 'blob')) $true 'typed spelling carries the segment'
            Assert-Result (Test-SwProtectedPath -Path (Join-Path $target 'blob')) $false 'plain target spelling'
        }
        finally { Remove-TestJunction $link }
    }

    It 'B-10 does not protect a junction into an unprotected folder of the profile' {
        $link = Join-Path $script:FxRoot 'link-to-docs'
        New-TestJunction $link (Join-Path $script:FxHome 'Docs')
        $script:Links.Add($link)
        try {
            Assert-Result (Test-SwProtectedPath -Path (Join-Path $link 'file.txt')) $false 'file below the junction'
            Assert-Result (Test-SwProtectedPath -Path $link) $false 'the junction itself'
        }
        finally { Remove-TestJunction $link }
    }

    It 'B-10 protects a junction to the profile root itself but not what lies below the target' {
        $link = Join-Path $script:FxRoot 'link-to-profile'
        New-TestJunction $link $script:FxHome
        $script:Links.Add($link)
        try {
            Assert-Result (Test-SwProtectedPath -Path $link) $true 'the junction to the exact entry'
            Assert-Result (Test-SwProtectedPath -Path (Join-Path $link 'Docs\file.txt')) $false 'file below the exact entry'
        }
        finally { Remove-TestJunction $link }
    }

    It 'B-10 gives a nonexistent path below a junction only the lexical answer' {
        $link = Join-Path $script:FxRoot 'link-nonexistent'
        New-TestJunction $link $script:FxProt
        $script:Links.Add($link)
        try { Assert-Result (Test-SwProtectedPath -Path (Join-Path $link 'NewFolder')) $false 'planned folder below a junction' }
        finally { Remove-TestJunction $link }
    }

    It 'B-10 protects a path that carries a trailing dot after the normalization' {
        Assert-Result (Test-SwProtectedPath -Path ($script:FxProt + '.\child')) $true 'trailing dot in a segment'
        Assert-Result (Test-SwProtectedPath -Path ($script:FxProt + '.')) $true 'trailing dot on the entry'
    }

    It 'B-10 protects the short name of an existing protected folder' {
        $long = Join-Path $script:FxRoot 'LongProtectedFolderName'
        [void][System.IO.Directory]::CreateDirectory($long)
        [System.IO.File]::WriteAllText((Join-Path $long 'f.txt'), 'x')
        $fso = New-Object -ComObject Scripting.FileSystemObject
        $short = $fso.GetFolder($long).ShortPath
        if ($short -ieq $long) { Set-ItResult -Skipped -Because '8.3 names are disabled on this volume'; return }
        $script:ProtectedPaths = @($long)
        Assert-Result (Test-SwProtectedPath -Path $short) $true 'short name'
        Assert-Result (Test-SwProtectedPath -Path (Join-Path $short 'f.txt')) $true 'file below the short name'
    }

    It 'B-11 with -AlreadyResolved does not look at the file system for the candidate' {
        $link = Join-Path $script:FxRoot 'link-resolved'
        New-TestJunction $link $script:FxProt
        $script:Links.Add($link)
        try {
            Assert-Result (Test-SwProtectedPath -Path (Join-Path $link 'child') -AlreadyResolved) $false 'junction candidate, typed text unprotected'
            Assert-Result (Test-SwProtectedPath -Path (Join-Path $script:FxProt 'child') -AlreadyResolved) $true 'typed text protected'
        }
        finally { Remove-TestJunction $link }
    }

    It 'B-11 still compares list entries in their typed and final spelling with -AlreadyResolved' {
        $link = Join-Path $script:FxRoot 'link-entry'
        New-TestJunction $link $script:FxOpen
        $script:Links.Add($link)
        try {
            $script:ProtectedPaths = @($link)
            Assert-Result (Test-SwProtectedPath -Path (Join-Path $script:FxOpen 'x') -AlreadyResolved) $true 'candidate in the final spelling of the entry'
            Assert-Result (Test-SwProtectedPath -Path (Join-Path $link 'x') -AlreadyResolved) $true 'candidate in the typed spelling of the entry'
        }
        finally { Remove-TestJunction $link }
    }

    It 'B-9 protects what lies below the final spelling of a Packages folder that is a junction' {
        $local = Join-Path $script:FxHome 'AppData\Local'
        [void][System.IO.Directory]::CreateDirectory($local)
        $target = Join-Path $script:FxRoot 'packages-target'
        $app = Join-Path $target 'Some.App_8wekyb3d8bbwe'
        [void][System.IO.Directory]::CreateDirectory($app)
        [System.IO.File]::WriteAllText((Join-Path $app 'data.bin'), 'x')
        $link = Join-Path $local 'Packages'
        New-TestJunction $link $target
        $script:Links.Add($link)
        try {
            Assert-Result (Test-SwProtectedPath -Path (Join-Path $link 'Some.App_8wekyb3d8bbwe\data.bin')) $true 'typed spelling'
            Assert-Result (Test-SwProtectedPath -Path (Join-Path $app 'data.bin')) $true 'final spelling'
        }
        finally { Remove-TestJunction $link }
    }

    It 'B-6 protects the target of a junction that is spelled as an exact list entry' {
        $link = Join-Path $script:FxRoot 'link-exact-entry'
        New-TestJunction $link $script:FxOpen
        $script:Links.Add($link)
        try {
            $script:ProtectedPaths = @()
            $script:ExactProtectedPaths = @($link)
            Assert-Result (Test-SwProtectedPath -Path $script:FxOpen) $true 'final spelling of the entry'
            Assert-Result (Test-SwProtectedPath -Path $link) $true 'typed spelling of the entry'
            Assert-Result (Test-SwProtectedPath -Path (Join-Path $script:FxOpen 'child')) $false 'a child of an exact entry'
        }
        finally { Remove-TestJunction $link }
    }

    It 'S-B3 [W] Resolve-SwSafePath gives the final spelling of a junction and the target of a short name' {
        $link = Join-Path $script:FxRoot 'link-resolve'
        New-TestJunction $link $script:FxOpen
        $script:Links.Add($link)
        try {
            $resolved = Resolve-SwSafePath -Path $link
            $direct = Resolve-SwSafePath -Path $script:FxOpen
            $resolved | Should -Not -BeNullOrEmpty
            $resolved | Should -BeExactly $direct
            Resolve-SwSafePath -Path (Join-Path $link 'x-missing') | Should -Not -BeNullOrEmpty
        }
        finally { Remove-TestJunction $link }
        if ([System.IO.Directory]::Exists('C:\PROGRA~1')) {
            (Resolve-SwSafePath -Path 'C:\PROGRA~1') | Should -Be $env:ProgramFiles
        }
    }
}

# ============================================================================
# Resolve-SwSafePath
# ============================================================================

Describe 'Resolve-SwSafePath' {
    BeforeAll {
        $script:FxRoot = [System.IO.Path]::Combine($TestDrive, 'resolve-fixture')
        [void][System.IO.Directory]::CreateDirectory($script:FxRoot)
    }
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
    }
    AfterEach { Stop-Case }

    It 'B-13 gives $null for an empty or blank path' {
        $null -eq (Resolve-SwSafePath -Path '') | Should -BeTrue
        $null -eq (Resolve-SwSafePath -Path $null) | Should -BeTrue
    }

    It 'B-13 gives $null for a path with an invalid character, without throwing' {
        $bad = $script:FxRoot + '\bad' + [char]0 + 'name'
        { Resolve-SwSafePath -Path $bad } | Should -Not -Throw
        $null -eq (Resolve-SwSafePath -Path $bad) | Should -BeTrue
    }

    It 'B-13 gives the normalized path for a path that does not exist' {
        $path = [System.IO.Path]::Combine($script:FxRoot, 'gibt-es-nicht', 'x')
        $result = Resolve-SwSafePath -Path $path
        $result | Should -BeOfType [string]
        Get-Cmp $result | Should -BeExactly (Get-Cmp ([System.IO.Path]::GetFullPath($path)))
    }

    It 'B-13 normalizes dot segments of a path that does not exist' {
        $path = [System.IO.Path]::Combine($script:FxRoot, 'a', '..', 'b')
        Assert-Path (Resolve-SwSafePath -Path $path) ([System.IO.Path]::Combine($script:FxRoot, 'b'))
    }

    It 'B-13 keeps a trailing backslash that was typed for a path that does not exist' {
        $path = [System.IO.Path]::Combine($script:FxRoot, 'missing-folder') + [System.IO.Path]::DirectorySeparatorChar
        $result = Resolve-SwSafePath -Path $path
        ($result.EndsWith('\') -or $result.EndsWith('/')) | Should -BeTrue
    }

    It 'B-13 resolves a relative path against the working directory of the process' {
        Use-ProcessDirectory $script:FxRoot {
            $result = Resolve-SwSafePath -Path 'relative-missing\child'
            Get-Cmp $result | Should -BeExactly (Get-Cmp ([System.IO.Path]::GetFullPath('relative-missing\child')))
            (Get-Cmp $result).StartsWith((Get-Cmp $script:FxRoot)) | Should -BeTrue
        }
    }

    It 'B-13 gives a path for an existing folder and an existing file that names the same item' {
        $folder = [System.IO.Path]::Combine($script:FxRoot, 'existing-folder')
        [void][System.IO.Directory]::CreateDirectory($folder)
        $file = [System.IO.Path]::Combine($folder, 'item.txt')
        [System.IO.File]::WriteAllText($file, 'x')
        $resolvedFolder = Resolve-SwSafePath -Path $folder
        $resolvedFile = Resolve-SwSafePath -Path $file
        $resolvedFolder | Should -Not -BeNullOrEmpty
        [System.IO.Directory]::Exists($resolvedFolder) | Should -BeTrue
        [System.IO.File]::Exists($resolvedFile) | Should -BeTrue
        [System.IO.Path]::GetFileName($resolvedFile) | Should -BeExactly 'item.txt'
    }

    It 'B-13 treats brackets in an existing path literally' {
        $folder = [System.IO.Path]::Combine($script:FxRoot, 'br [a]')
        [void][System.IO.Directory]::CreateDirectory($folder)
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::Combine($script:FxRoot, 'br a'))
        $result = Resolve-SwSafePath -Path $folder
        $result | Should -Not -BeNullOrEmpty
        [System.IO.Path]::GetFileName($result) | Should -BeExactly 'br [a]'
    }

    It 'B-13 [W] gives the on-disk spelling of the case of an existing folder' {
        $folder = [System.IO.Path]::Combine($script:FxRoot, 'CaseSpelling')
        [void][System.IO.Directory]::CreateDirectory($folder)
        $result = Resolve-SwSafePath -Path ([System.IO.Path]::Combine($script:FxRoot, 'casespelling'))
        [System.IO.Path]::GetFileName($result) | Should -BeExactly 'CaseSpelling'
    }

    It 'B-13 [W] gives the drive root form C:\ for a drive root' {
        Resolve-SwSafePath -Path 'C:\' | Should -BeExactly 'C:\'
        Resolve-SwSafePath -Path 'C:' | Should -Not -BeNullOrEmpty
    }
}

# ============================================================================
# Reading and decoding list files
# ============================================================================

Describe 'Read-SwListBytes' {
    BeforeAll {
        $script:Dir = [System.IO.Path]::Combine($TestDrive, 'read-fixture')
        [void][System.IO.Directory]::CreateDirectory($script:Dir)
    }
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
    }
    AfterEach { Stop-Case }

    It 'B-30 returns exactly the bytes of the file' {
        $path = [System.IO.Path]::Combine($script:Dir, 'bytes.txt')
        $bytes = [byte[]](0xEF, 0xBB, 0xBF, 0x43, 0x3A, 0x5C, 0x0D, 0x0A, 0x00, 0xFF)
        [System.IO.File]::WriteAllBytes($path, $bytes)
        $result = Read-SwListBytes -Path $path
        $result | Should -BeOfType [byte]
        ($result -join ',') | Should -BeExactly ($bytes -join ',')
    }

    It 'B-30 returns an empty byte array, never $null, for an empty file' {
        $path = [System.IO.Path]::Combine($script:Dir, 'empty.txt')
        [System.IO.File]::WriteAllBytes($path, [byte[]]@())
        $result = Read-SwListBytes -Path $path
        ($null -ne $result) | Should -BeTrue
        $result -is [byte[]] | Should -BeTrue
        $result.Length | Should -Be 0
    }

    It 'B-30 throws for a missing file' {
        { Read-SwListBytes -Path ([System.IO.Path]::Combine($script:Dir, 'missing.txt')) } | Should -Throw
    }

    It 'B-30 throws when the path is a folder' {
        { Read-SwListBytes -Path $script:Dir } | Should -Throw
    }

    It 'B-30 requires a path' {
        { Read-SwListBytes -Path '' } | Should -Throw
    }

    It 'B-30 reads a file name with brackets literally' {
        $bracket = [System.IO.Path]::Combine($script:Dir, '[rules].txt')
        $decoy = [System.IO.Path]::Combine($script:Dir, 'r.txt')
        [System.IO.File]::WriteAllBytes($bracket, [byte[]](65, 65))
        [System.IO.File]::WriteAllBytes($decoy, [byte[]](66, 66, 66))
        (Read-SwListBytes -Path $bracket) -join ',' | Should -BeExactly '65,65'
    }

    It 'B-21 reads a file that another process holds open for writing' {
        $path = [System.IO.Path]::Combine($script:Dir, 'held-open.txt')
        [System.IO.File]::WriteAllBytes($path, [byte[]](67, 58, 92))
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $writer = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, $share)
        try { $result = Read-SwListBytes -Path $path }
        finally { $writer.Dispose() }
        ($result -join ',') | Should -BeExactly '67,58,92'
    }

    It 'B-30 never changes the file' {
        $path = [System.IO.Path]::Combine($script:Dir, 'unchanged.txt')
        [System.IO.File]::WriteAllBytes($path, [byte[]](1, 2, 3))
        $before = [System.IO.File]::GetLastWriteTimeUtc($path)
        $null = Read-SwListBytes -Path $path
        [System.IO.File]::GetLastWriteTimeUtc($path) | Should -Be $before
        ([System.IO.File]::ReadAllBytes($path) -join ',') | Should -BeExactly '1,2,3'
    }
}

Describe 'ConvertFrom-SwListBytes' {
    BeforeAll {
        $script:Uuml = [string][char]0xDC
        $script:Folder = 'C:\Daten\' + $script:Uuml + 'bersicht'
    }
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
    }
    AfterEach { Stop-Case }

    It 'B-21 decodes <Kind> and removes the BOM' -ForEach $script:Encodings {
        $bytes = Get-EncodedBytes $Kind ($script:Folder + "`r`n")
        $lines = Get-Items (ConvertFrom-SwListBytes -Bytes $bytes)
        $lines[0] | Should -BeExactly $script:Folder
        $lines[0].Contains([string][char]0xFEFF) | Should -BeFalse
    }

    It 'B-21 checks UTF-32 LE before UTF-16 LE' {
        $bytes = [byte[]](0xFF, 0xFE, 0, 0, 0x41, 0, 0, 0, 0x42, 0, 0, 0)
        $lines = Get-Items (ConvertFrom-SwListBytes -Bytes $bytes)
        $lines[0] | Should -BeExactly 'AB'
    }

    It 'B-21 splits lines at CRLF, single CR and single LF' {
        $crlf = Get-Items (ConvertFrom-SwListBytes -Bytes ([System.Text.Encoding]::UTF8.GetBytes("a`r`nb`r`nc")))
        ($crlf | Where-Object { $_ -ne '' }) -join '|' | Should -BeExactly 'a|b|c'
        $cr = Get-Items (ConvertFrom-SwListBytes -Bytes ([System.Text.Encoding]::UTF8.GetBytes("a`rb`rc")))
        ($cr | Where-Object { $_ -ne '' }) -join '|' | Should -BeExactly 'a|b|c'
        $lf = Get-Items (ConvertFrom-SwListBytes -Bytes ([System.Text.Encoding]::UTF8.GetBytes("a`nb`nc")))
        ($lf | Where-Object { $_ -ne '' }) -join '|' | Should -BeExactly 'a|b|c'
        $mixed = Get-Items (ConvertFrom-SwListBytes -Bytes ([System.Text.Encoding]::UTF8.GetBytes("a`rb`nc`r`nd")))
        ($mixed | Where-Object { $_ -ne '' }) -join '|' | Should -BeExactly 'a|b|c|d'
    }

    It 'B-21 reads text with only CR as line end: both entries are present' {
        $text = "# c`rC:\Keep\A`rC:\Keep\B`r"
        $lines = Get-Items (ConvertFrom-SwListBytes -Bytes ([System.Text.Encoding]::UTF8.GetBytes($text)))
        $lines | Should -Contain 'C:\Keep\A'
        $lines | Should -Contain 'C:\Keep\B'
    }

    It 'B-21 may give empty lines, and every item is a string' {
        $lines = Get-Items (ConvertFrom-SwListBytes -Bytes ([System.Text.Encoding]::UTF8.GetBytes("a`r`n`r`nb`r`n")))
        foreach ($line in $lines) { $line | Should -BeOfType [string] }
        (@($lines | Where-Object { $_ -ne '' }) -join '|') | Should -BeExactly 'a|b'
    }

    It 'B-30 gives no line with content for an empty array' {
        $lines = Get-Items (ConvertFrom-SwListBytes -Bytes ([byte[]]@()))
        @($lines | Where-Object { -not [string]::IsNullOrEmpty($_) }).Count | Should -Be 0
    }

    It 'B-21 [W] decodes a file without BOM that is not valid UTF-8 with the ANSI code page (Windows PowerShell 5.1)' {
        if (-not $script:IsDesktop) { Set-ItResult -Skipped -Because 'the ANSI fallback differs under PowerShell 7'; return }
        $bytes = [byte[]](0x43, 0x3A, 0x5C, 0x44, 0xFC, 0x62, 0x65, 0x72)
        $lines = Get-Items (ConvertFrom-SwListBytes -Bytes $bytes)
        $expected = [System.Text.Encoding]::Default.GetString($bytes)
        $lines[0] | Should -BeExactly $expected
    }

    It 'B-21 never throws for arbitrary bytes: <Name>' -ForEach $script:AnyBytes {
        { ConvertFrom-SwListBytes -Bytes $Bytes } | Should -Not -Throw
        $lines = Get-Items (ConvertFrom-SwListBytes -Bytes $Bytes)
        foreach ($line in $lines) { $line | Should -BeOfType [string] }
    }

    It 'B-21 does not decode UTF-8 bytes with the standard encoding of the platform (an umlaut stays one character)' {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($script:Folder)
        $lines = Get-Items (ConvertFrom-SwListBytes -Bytes $bytes)
        $lines[0] | Should -BeExactly $script:Folder
        $lines[0].Length | Should -Be $script:Folder.Length
    }
}

# ============================================================================
# One entry of a list file
# ============================================================================

Describe 'ConvertFrom-SwListEntry' {
    BeforeAll {
        $script:EnvNames = @('USERPROFILE', 'LOCALAPPDATA', 'APPDATA', 'SWTEST_D', 'SWTEST_R', 'SWTEST_U', 'SWTEST_ROOTREL', 'SWTEST_NEVER_DEFINED')
        $script:EntryEnvBefore = Save-Env $script:EnvNames
        Set-Env 'USERPROFILE' 'C:\Users\Example'
        Set-Env 'LOCALAPPDATA' 'C:\Users\Example\AppData\Local'
        Set-Env 'APPDATA' 'C:\Users\Example\AppData\Roaming'
        Set-Env 'SWTEST_D' 'C:\Data'
        Set-Env 'SWTEST_R' 'rel'
        Set-Env 'SWTEST_U' '\\srv\share'
        Set-Env 'SWTEST_ROOTREL' '\foo'
        Set-Env 'SWTEST_NEVER_DEFINED' $null
    }
    AfterAll { Restore-Env $script:EntryEnvBefore }
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
    }
    AfterEach { Stop-Case }

    It 'B-22 turns the line <Line> into the path it means (without -IncludeRaw)' -ForEach $script:EntryCases {
        $result = ConvertFrom-SwListEntry -Line $Line
        if ($null -eq $Plain) { $null -eq $result | Should -BeTrue -Because 'the line means no path' }
        else {
            @($result).Count | Should -Be 1
            $result | Should -BeOfType [string]
            $result | Should -BeExactly $Plain
        }
    }

    It 'B-22 gives the unexpanded spelling as well for the line <Line> (with -IncludeRaw)' -ForEach $script:EntryCases {
        $items = Get-Items (ConvertFrom-SwListEntry -Line $Line -IncludeRaw)
        $items.Count | Should -Be @($Raw).Count
        for ($i = 0; $i -lt $items.Count; $i++) { $items[$i] | Should -BeExactly $Raw[$i] }
    }

    It 'B-22 gives $null for a null line' {
        $null -eq (ConvertFrom-SwListEntry -Line $null) | Should -BeTrue
        $null -eq (ConvertFrom-SwListEntry -Line $null -IncludeRaw) | Should -BeTrue
    }

    It 'B-22 takes only one enclosing pair of quotes' {
        ConvertFrom-SwListEntry -Line '"''x''"' | Should -BeExactly '''x'''
        ConvertFrom-SwListEntry -Line '''"x"''' | Should -BeExactly '"x"'
    }

    It 'B-22 does not treat text after a path as a comment' {
        ConvertFrom-SwListEntry -Line 'C:\x # c' | Should -BeExactly 'C:\x # c'
    }

    It 'B-22 keeps a leading single slash and turns a leading double slash into a UNC path' {
        ConvertFrom-SwListEntry -Line '/usr/x' | Should -BeExactly '/usr/x'
        ConvertFrom-SwListEntry -Line '//server/share' | Should -BeExactly '\\server\share'
    }

    It 'B-22 replaces ~ with USERPROFILE without a trailing backslash' {
        Set-Env 'USERPROFILE' 'C:\Users\Example\'
        ConvertFrom-SwListEntry -Line '~\Foo' | Should -BeExactly 'C:\Users\Example\Foo'
        ConvertFrom-SwListEntry -Line '~' | Should -BeExactly 'C:\Users\Example'
    }

    It 'B-22 gives $null for ~ when USERPROFILE is empty, and leaves ~name alone' {
        Set-Env 'USERPROFILE' ''
        $null -eq (ConvertFrom-SwListEntry -Line '~') | Should -BeTrue
        $null -eq (ConvertFrom-SwListEntry -Line '~\Foo') | Should -BeTrue
        ConvertFrom-SwListEntry -Line '~name' | Should -BeExactly '~name'
    }

    It 'B-22 never throws' {
        foreach ($line in @('%', '%%', '%a', 'a%', '~~', '"', "'", ('bad' + [char]0 + 'x'), '%' + ('x' * 5000) + '%')) {
            { ConvertFrom-SwListEntry -Line $line } | Should -Not -Throw
            { ConvertFrom-SwListEntry -Line $line -IncludeRaw } | Should -Not -Throw
        }
    }

    It 'S-B8 gives no pattern for an entry that expands to a relative or root-relative rest' {
        $null -eq (ConvertFrom-SwListEntry -Line '%SWTEST_R%\x') | Should -BeTrue
        $null -eq (ConvertFrom-SwListEntry -Line '%SWTEST_ROOTREL%\x') | Should -BeTrue
        $null -eq (ConvertFrom-SwListEntry -Line '""') | Should -BeTrue
        $null -eq (ConvertFrom-SwListEntry -Line "''") | Should -BeTrue
    }

    It 'B-29 gives a path with an umlaut from a UTF-8 file without BOM through the three list functions' {
        $uuml = [string][char]0xDC
        $text = '"C:\Projekte\' + $uuml + 'bersicht"' + "`r`n" + '%SWTEST_NEVER_DEFINED%\Foo' + "`r`n" + '""' + "`r`n"
        $path = [System.IO.Path]::Combine($TestDrive, 'purge_paths.txt')
        [System.IO.File]::WriteAllBytes($path, ([System.Text.Encoding]::UTF8.GetBytes($text)))
        $entries = @(foreach ($line in (Get-Items (ConvertFrom-SwListBytes -Bytes (Read-SwListBytes -Path $path)))) {
                $entry = ConvertFrom-SwListEntry -Line $line
                if ($null -ne $entry) { $entry }
            })
        $entries[0] | Should -BeExactly ('C:\Projekte\' + $uuml + 'bersicht')
        $entries | Should -Not -Contain ''
        # An undefined variable stays literal and is not a rooted path, so no search path comes out of it.
        @($entries | Where-Object { $_ -match '^(?:[A-Za-z]:\\|\\\\[^\\])' }).Count | Should -Be 1
    }

    It 'B-29 emits the lines one by one so they can be piped into ConvertFrom-SwListEntry and its old name' {
        $uuml = [string][char]0xDC
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('C:\Projekte\' + $uuml + 'bersicht' + "`r`n" + 'D:\Zwei' + "`r`n")
        foreach ($pair in @(@('ConvertFrom-SwListBytes', 'ConvertFrom-SwListEntry'), @('ConvertFrom-SweeprListBytes', 'ConvertFrom-SweeprListEntry'))) {
            $decode = $pair[0]
            $convert = $pair[1]
            $entries = @(& $decode -Bytes $bytes | ForEach-Object { & $convert -Line $_ } | Where-Object { $_ })
            $entries.Count | Should -Be 2 -Because $decode
            $entries[0] | Should -BeExactly ('C:\Projekte\' + $uuml + 'bersicht')
            $entries[1] | Should -BeExactly 'D:\Zwei'
        }
        @(ConvertFrom-SwListBytes -Bytes ([byte[]]@())).Count | Should -Be 0
        @(ConvertFrom-SweeprListEntry -Line '%SWTEST_D%\x' -IncludeRaw).Count | Should -Be 2
        @(ConvertFrom-SwListEntry -Line '%SWTEST_D%\x' -IncludeRaw).Count | Should -Be 2
    }
}

# ============================================================================
# Whitelist
# ============================================================================

Describe 'Whitelist' {
    BeforeAll {
        $script:FxRoot = [System.IO.Path]::Combine($TestDrive, 'wl-fixture')
        $script:FxHome = 'C:\Users\Example'
        Use-Fixture -UserProfile $script:FxHome -Local 'C:\Users\Example\AppData\Local' -Roaming 'C:\Users\Example\AppData\Roaming'

        function script:Set-WlBytes([byte[]]$Bytes) {
            [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($script:Config.WhitelistFile))
            [System.IO.File]::WriteAllBytes($script:Config.WhitelistFile, $Bytes)
        }
        function script:Set-WlLines([string[]]$Lines) {
            $text = ($Lines -join "`r`n") + "`r`n"
            Set-WlBytes (Get-EncodedBytes 'UTF-8 with BOM' $text)
        }
        function script:Test-Wl([string]$Path) { Test-SwWhitelisted -Path $Path }
    }
    AfterAll { Restore-Fixture }
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        $script:Case = [System.IO.Path]::Combine($script:FxRoot, [guid]::NewGuid().ToString('N'))
        $script:WlFile = [System.IO.Path]::Combine($script:Case, 'whitelist.txt')
        $script:WlCmp = Get-Cmp $script:WlFile
        $script:Config = @{
            ConfigPath    = ''
            CachePath     = ''
            WhitelistFile = $script:WlFile
        }
        $script:DefaultWhitelistPatterns = @()
    }
    AfterEach { Stop-Case }

    It 'B-20 gives a state that is never $null and can be used for many candidates' {
        Set-WlLines @('C:\Keep\A', 'C:\Keep\B')
        $state = Get-SwWhitelistState
        $null -ne $state | Should -BeTrue
        Assert-Result (Test-SwWhitelisted -Path 'C:\Keep\A\x' -State $state) $true 'first entry'
        Assert-Result (Test-SwWhitelisted -Path 'C:\Keep\B\x' -State $state) $true 'second entry'
        Assert-Result (Test-SwWhitelisted -Path 'C:\Keep\C\x' -State $state) $false 'other path'
        Assert-Result (Test-SwWhitelisted -Path 'C:\Keep\A\y' -State $state) $true 'again'
    }

    It 'B-20 treats a missing file as no user entries (not as keep everything)' {
        Assert-Result (Test-Wl 'C:\Scratch\x') $false 'ordinary path'
        $state = Get-SwWhitelistState
        $null -ne $state | Should -BeTrue
        Assert-Result (Test-SwWhitelisted -Path 'D:\Other\y' -State $state) $false 'state of a missing file'
    }

    It 'S-B7 treats an empty file as no entries (not as keep everything)' {
        Set-WlBytes ([byte[]]@())
        Assert-Result (Test-Wl 'C:\Scratch\x') $false 'empty file'
        Set-WlLines @('# only a comment', '', '   ')
        Assert-Result (Test-Wl 'C:\Scratch\x') $false 'comments and blanks only'
    }

    It 'S-B7 keeps every path when a folder stands where the file should be' {
        [void][System.IO.Directory]::CreateDirectory($script:WlFile)
        Assert-Result (Test-Wl 'C:\Scratch\x') $true 'ordinary path'
        Assert-Result (Test-Wl 'D:\Other\y') $true 'another path'
    }

    It 'S-B7 keeps every path when reading the file fails' {
        Set-WlLines @('C:\Keep\A')
        Mock Read-SwListBytes { throw 'read failed' }
        Assert-Result (Test-Wl 'C:\Scratch\x') $true 'ordinary path'
        Assert-Result (Test-Wl 'D:\Other\y') $true 'another path'
        $state = Get-SwWhitelistState
        $null -ne $state | Should -BeTrue
        Assert-Result (Test-SwWhitelisted -Path 'E:\Third\z' -State $state) $true 'state built from a failed read'
    }

    It 'S-B7 keeps every path when decoding fails' {
        Set-WlLines @('C:\Keep\A')
        Mock ConvertFrom-SwListBytes { throw 'decode failed' }
        Assert-Result (Test-Wl 'C:\Scratch\x') $true 'ordinary path'
    }

    It 'S-B7 keeps every path when the metadata of the file cannot be read (access denied)' {
        Mock Get-Item { throw ([System.UnauthorizedAccessException]::new('denied')) } -ParameterFilter { ([string]$LiteralPath).Replace('\', '/').ToLowerInvariant() -eq $script:WlCmp }
        Assert-Result (Test-Wl 'C:\Scratch\x') $true 'ordinary path'
        Assert-Result (Test-Wl 'D:\Other\y') $true 'another path'
    }

    It 'S-B7 keeps every path when the metadata query fails with any other error' {
        Mock Get-Item { throw ([System.IO.IOException]::new('i/o error')) } -ParameterFilter { ([string]$LiteralPath).Replace('\', '/').ToLowerInvariant() -eq $script:WlCmp }
        Assert-Result (Test-Wl 'C:\Scratch\x') $true 'ordinary path'
    }

    It 'B-20 takes ItemNotFoundException from Get-Item as a missing file, even when a file exists' {
        Set-WlLines @('C:\Keep\A')
        Mock Get-Item { throw (New-Object System.Management.Automation.ItemNotFoundException 'not found') } -ParameterFilter { ([string]$LiteralPath).Replace('\', '/').ToLowerInvariant() -eq $script:WlCmp }
        Assert-Result (Test-Wl 'C:\Keep\A\x') $false 'entry of a file that is reported missing'
        Assert-Result (Test-Wl 'C:\Scratch\x') $false 'ordinary path'
    }

    It 'B-20 asks for the whitelist file with Get-Item -LiteralPath' {
        Set-WlLines @('C:\Keep\A')
        Mock Get-Item { throw ([System.UnauthorizedAccessException]::new('denied')) } -ParameterFilter { ([string]$LiteralPath).Replace('\', '/').ToLowerInvariant() -eq $script:WlCmp }
        $null = Get-SwWhitelistState
        Should -Invoke Get-Item -Times 1 -Exactly -ParameterFilter { ([string]$LiteralPath).Replace('\', '/').ToLowerInvariant() -eq $script:WlCmp }
    }

    It 'B-20 reads a whitelist file named like a wildcard pattern literally' {
        $case = [System.IO.Path]::Combine($script:Case, 'wild')
        [void][System.IO.Directory]::CreateDirectory($case)
        $script:Config.WhitelistFile = [System.IO.Path]::Combine($case, '[rules].txt')
        [System.IO.File]::WriteAllBytes([System.IO.Path]::Combine($case, 'e.txt'), (Get-EncodedBytes 'UTF-8 with BOM' "C:\Decoy\Y`r`n"))
        Set-WlLines @('C:\Wild\X')
        Assert-Result (Test-Wl 'C:\Wild\X\child') $true 'entry of the bracket file'
        Assert-Result (Test-Wl 'C:\Decoy\Y\child') $false 'entry of a file the pattern would match'
    }

    It 'B-20 reads the file again at every call' {
        Set-WlLines @('C:\First\A')
        Assert-Result (Test-Wl 'C:\First\A\x') $true 'first content'
        Set-WlLines @('C:\Second\B')
        Assert-Result (Test-Wl 'C:\First\A\x') $false 'old entry after a change'
        Assert-Result (Test-Wl 'C:\Second\B\x') $true 'new entry after a change'
    }

    It 'B-2.4 reads the file through Read-SwListBytes with the whitelist file path, once per state' {
        Set-WlLines @('C:\Keep\A')
        Mock Read-SwListBytes { , [System.IO.File]::ReadAllBytes($Path) }
        $null = Get-SwWhitelistState
        Should -Invoke Read-SwListBytes -Times 1 -Exactly -ParameterFilter { ([string]$Path).Replace('\', '/').ToLowerInvariant() -eq $script:WlCmp }
    }

    It 'B-2.4 takes the entries from the bytes that Read-SwListBytes returns' {
        Set-WlLines @('C:\OnDisk\A')
        $other = Get-EncodedBytes 'UTF-8 with BOM' "C:\FromMock\B`r`n"
        Mock Read-SwListBytes { , $other }
        Assert-Result (Test-Wl 'C:\FromMock\B\x') $true 'entry of the mocked bytes'
        Assert-Result (Test-Wl 'C:\OnDisk\A\x') $false 'entry on disk'
    }

    It 'B-2.4 does not call Read-SwListBytes when the file is missing' {
        Mock Read-SwListBytes { , [byte[]]@() }
        $null = Get-SwWhitelistState
        $null = Test-Wl 'C:\Scratch\x'
        Should -Invoke Read-SwListBytes -Times 0 -Exactly
    }

    It 'B-2.4 reads once per call of Test-SwWhitelisted without a state, and never with a state' {
        Set-WlLines @('C:\Keep\A')
        Mock Read-SwListBytes { , [System.IO.File]::ReadAllBytes($Path) }
        $state = Get-SwWhitelistState
        Should -Invoke Read-SwListBytes -Times 1 -Exactly
        $null = Test-SwWhitelisted -Path 'C:\Keep\A\x' -State $state
        $null = Test-SwWhitelisted -Path 'C:\Other\x' -State $state
        $null = Test-SwWhitelisted -Path 'C:\Keep\A\y' -State $state
        Should -Invoke Read-SwListBytes -Times 1 -Exactly
        $null = Test-SwWhitelisted -Path 'C:\Keep\A\x'
        Should -Invoke Read-SwListBytes -Times 2 -Exactly
        $null = Test-SwWhitelisted -Path 'C:\Keep\A\x'
        Should -Invoke Read-SwListBytes -Times 3 -Exactly
    }

    It 'B-21 protects <Kind> encoded entries with an umlaut, and not look-alikes' -ForEach $script:Encodings {
        $uuml = [string][char]0xDC
        $folder = 'C:\Daten\' + $uuml + 'bersicht'
        Set-WlBytes (Get-EncodedBytes $Kind ($folder + "`r`n"))
        Assert-Result (Test-Wl ($folder + '\Unterordner\datei.tmp')) $true 'child of the entry'
        Assert-Result (Test-Wl 'C:\Daten\Ubersicht\x') $false 'without the umlaut'
        Assert-Result (Test-Wl ($folder + '2\x')) $false 'longer name'
        $misdecoded = 'C:\Daten\' + [char]0xC3 + [char]0x9C + 'bersicht\x'
        Assert-Result (Test-Wl $misdecoded) $false 'UTF-8 bytes read as Latin-1'
    }

    It 'B-21 uses both entries of a file with CR as the only line end' {
        Set-WlBytes ([System.Text.Encoding]::UTF8.GetBytes("# c`rC:\Keep\A`rC:\Keep\B`r"))
        Assert-Result (Test-Wl 'C:\Keep\A\x') $true 'first entry'
        Assert-Result (Test-Wl 'C:\Keep\B\x') $true 'second entry'
        Assert-Result (Test-Wl 'C:\Keep\C\x') $false 'not listed'
    }

    It 'B-21 reads a whitelist that another process holds open for writing' {
        Set-WlLines @('C:\Keep\A')
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $writer = New-Object System.IO.FileStream($script:WlFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, $share)
        try { $result = Test-Wl 'C:\Keep\A\x' }
        finally { $writer.Dispose() }
        Assert-Result $result $true 'file held open by an editor'
    }

    It 'S-B14 keeps every path for text with a NUL character, such as UTF-16 without a BOM' {
        Set-WlBytes ([System.Text.Encoding]::Unicode.GetBytes("C:\Keep\A`r`n"))
        Assert-Result (Test-Wl 'C:\Scratch\x') $true 'ordinary path'
        Assert-Result (Test-Wl 'C:\Keep\A\x') $true 'listed path'
    }

    It 'S-B8 lets lines that mean nothing protect nothing: <Line>' -ForEach @(
        @{ Line = '""' }
        @{ Line = "''" }
        @{ Line = '"   "' }
        @{ Line = '   ' }
        @{ Line = '#' }
        @{ Line = '# C:\Scratch' }
        @{ Line = '%SWTEST_WL_REL%\x' }
    ) {
        Set-Env 'SWTEST_WL_REL' 'rel'
        try {
            Set-WlLines @($Line)
            Assert-Result (Test-Wl 'C:\Scratch\x') $false 'ordinary path'
            Assert-Result (Test-Wl 'D:\rel\x') $false 'path that ends like the relative rest'
            Assert-Result (Test-Wl 'C:\x') $false 'short path'
        }
        finally { Set-Env 'SWTEST_WL_REL' $null }
    }

    It 'S-B8 keeps a real folder named like an undefined variable protected' {
        Set-WlLines @('C:\Data\%SWTEST_WL_NEVER%')
        Assert-Result (Test-Wl 'C:\Data\%SWTEST_WL_NEVER%') $true 'the folder'
        Assert-Result (Test-Wl 'C:\Data\%SWTEST_WL_NEVER%\x') $true 'below the folder'
        Assert-Result (Test-Wl 'C:\Data\other') $false 'another folder'
    }

    It 'S-B8 protects the expanded and the unexpanded spelling of an entry with a defined variable' {
        Set-Env 'SWTEST_WL_DEFINED' 'resolved'
        try {
            Set-WlLines @('C:\Data\%SWTEST_WL_DEFINED%')
            Assert-Result (Test-Wl 'C:\Data\resolved\x') $true 'expanded spelling'
            Assert-Result (Test-Wl 'C:\Data\%SWTEST_WL_DEFINED%\x') $true 'a real folder with the variable name'
            Assert-Result (Test-Wl 'C:\Data\other\x') $false 'another folder'
        }
        finally { Set-Env 'SWTEST_WL_DEFINED' $null }
    }

    It 'B-22 uses ~ and quotes in whitelist lines' {
        Set-WlLines @('"~\Keep"', "'C:/Slash/Keep'")
        Assert-Result (Test-Wl 'C:\Users\Example\Keep\x') $true 'tilde entry'
        Assert-Result (Test-Wl 'C:\Slash\Keep\x') $true 'slash entry'
    }

    It 'B-26 protects <Candidate> for the line <Line>: <Expected>' -ForEach $script:PatternCases {
        Set-WlLines @($Line)
        Assert-Result (Test-Wl $Candidate) $Expected "line $Line, candidate $Candidate"
    }

    It 'B-26 lets a bracket directory protect its content and a wildcard row protect another folder with the same last name' {
        Set-WlLines @('C:\Scratch\[demo]\cache', 'C:\Scratch\*\cache')
        Assert-Result (Test-Wl 'C:\Scratch\[demo]\cache') $true 'the folder'
        Assert-Result (Test-Wl 'C:\Scratch\[demo]\cache\keep.txt') $true 'file below it'
        Assert-Result (Test-Wl 'C:\Scratch\other\cache') $true 'wildcard row'
        Set-WlLines @('C:\Scratch\[demo]\cache')
        Assert-Result (Test-Wl 'C:\Scratch\[demo]\cache-other\keep.txt') $false 'prefix sibling'
        Assert-Result (Test-Wl 'C:\Scratch\other\cache') $false 'no wildcard row without the second line'
    }

    It 'B-26 combines several lines: any line may protect' {
        Set-WlLines @('C:\One\*', 'C:\Two', '# C:\Three', 'C:\Four\[x]')
        Assert-Result (Test-Wl 'C:\One\a\b') $true 'wildcard line'
        Assert-Result (Test-Wl 'C:\Two\a') $true 'literal line'
        Assert-Result (Test-Wl 'C:\Three\a') $false 'comment'
        Assert-Result (Test-Wl 'C:\Four\[x]\a') $true 'bracket line, literal below'
        Assert-Result (Test-Wl 'C:\Four\x') $true 'bracket line, wildcard meaning'
        Assert-Result (Test-Wl 'C:\Four\x\a') $false 'bracket line, nothing below the wildcard match'
    }

    It 'S-B9 keeps a literal folder with brackets protecting every descendant and no prefix sibling' {
        Set-WlLines @('C:\Data\[a]b')
        Assert-Result (Test-Wl 'C:\Data\[a]b\deep\er\file') $true 'descendant'
        Assert-Result (Test-Wl 'C:\Data\[a]bc') $false 'prefix sibling'
        Assert-Result (Test-Wl 'C:\Data\[a]b-other\x') $false 'prefix sibling with a dash'
    }

    It 'B-27 compares the candidate as given: no normalization, trailing backslash ignored for equality' {
        Set-WlLines @('C:\Data\Cache')
        Assert-Result (Test-Wl 'C:\Data\Cache\') $true 'trailing backslash'
        Assert-Result (Test-Wl 'c:\data\cache') $true 'case'
        Assert-Result (Test-Wl 'C:\Data\Cache\..\Other') $true 'dot segments are not resolved'
        Assert-Result (Test-Wl 'C:\Data') $false 'parent'
    }

    It 'B-27 protects an empty or null candidate' {
        Set-WlLines @('C:\Keep\A')
        Assert-Result (Test-SwWhitelisted -Path '') $true 'empty'
        Assert-Result (Test-SwWhitelisted -Path $null) $true 'null'
        $state = Get-SwWhitelistState
        Assert-Result (Test-SwWhitelisted -Path '' -State $state) $true 'empty with a state'
        Assert-Result (Test-SwWhitelisted -Path $null -State $state) $true 'null with a state'
    }

    It 'B-27 gives a bool and never throws' {
        $ErrorActionPreference = 'Stop'
        foreach ($path in @('', $null, 'C:\x', ('C:\bad' + [char]0 + 'x'), 'relative\path', '\\srv\share')) {
            { Test-SwWhitelisted -Path $path } | Should -Not -Throw
            Test-SwWhitelisted -Path $path | Should -BeOfType [bool]
        }
    }

    It 'B-27 protects every path with a keep-everything state, also one built earlier' {
        [void][System.IO.Directory]::CreateDirectory($script:WlFile)
        $state = Get-SwWhitelistState
        foreach ($path in @('C:\a', 'D:\b\c', '\\srv\share\x', 'relative')) { Assert-Result (Test-SwWhitelisted -Path $path -State $state) $true $path }
    }

    It 'B-28 puts the order of the lines out of play for literal and wildcard lines' {
        $rows = @('C:\Wild\*.keep', 'C:\Lit\Folder', 'C:\Other\Root')
        foreach ($order in @(@(0, 1, 2), @(2, 1, 0), @(1, 0, 2), @(1, 2, 0))) {
            Set-WlLines @($order | ForEach-Object { $rows[$_] })
            Assert-Result (Test-Wl 'C:\Wild\saved.keep') $true "wildcard line, order $($order -join '')"
            Assert-Result (Test-Wl 'C:\Lit\Folder\child.bin') $true "literal line, order $($order -join '')"
            Assert-Result (Test-Wl 'C:\Other\Root\child.bin') $true "third line, order $($order -join '')"
            Assert-Result (Test-Wl 'C:\Wild\ordinary.tmp') $false "ordinary file, order $($order -join '')"
            Assert-Result (Test-Wl 'C:\Lit\Folder-other\child.bin') $false "prefix sibling, order $($order -join '')"
        }
    }

    It 'B-28 protects the full path of an existing folder written relative to the working directory' {
        $folder = [System.IO.Path]::Combine($script:Case, 'rel-root')
        $sibling = [System.IO.Path]::Combine($script:Case, 'rel-root-other')
        [void][System.IO.Directory]::CreateDirectory($folder)
        [void][System.IO.Directory]::CreateDirectory($sibling)
        $full = Resolve-SwSafePath -Path $folder
        $fullSibling = Resolve-SwSafePath -Path $sibling
        Use-ProcessDirectory $script:Case {
            Set-WlLines @('rel-root')
            Assert-Result (Test-Wl $full) $true 'the folder'
            Assert-Result (Test-Wl ($full + '\child.txt')) $true 'a file below it'
            Assert-Result (Test-Wl ($fullSibling + '\child.txt')) $false 'prefix sibling'
            Assert-Result (Test-Wl (Win $script:Case 'elsewhere\x')) $false 'unrelated path'
        }
    }

    It 'B-28 protects nothing more for a relative line that names no existing folder' {
        [void][System.IO.Directory]::CreateDirectory($script:Case)
        Use-ProcessDirectory $script:Case {
            Set-WlLines @('rel-missing')
            Assert-Result (Test-Wl (Win $script:Case 'rel-missing\x')) $false 'path below the missing folder'
            Assert-Result (Test-Wl (Win $script:Case 'rel-missing')) $false 'the missing folder itself'
        }
    }

    It 'B-28 [W] protects the full path of an existing folder written without a drive (root-relative)' {
        if (-not $script:OnWindows) { Set-ItResult -Skipped -Because 'a root-relative path needs a drive letter'; return }
        $folder = [System.IO.Path]::Combine($script:Case, 'rooted-rel')
        $sibling = [System.IO.Path]::Combine($script:Case, 'rooted-rel-other')
        [void][System.IO.Directory]::CreateDirectory($folder)
        [void][System.IO.Directory]::CreateDirectory($sibling)
        $full = Resolve-SwSafePath -Path $folder
        $fullSibling = Resolve-SwSafePath -Path $sibling
        $rootRelative = [System.IO.Path]::GetFullPath($folder).Substring(2)
        Use-ProcessDirectory $script:Case {
            Set-WlLines @($rootRelative)
            Assert-Result (Test-Wl ($full + '\child.txt')) $true 'a file below it'
            Assert-Result (Test-Wl ($fullSibling + '\child.txt')) $false 'prefix sibling'
        }
    }

    It 'B-24 keeps a default pattern from an empty environment value without effect, also for an existing folder of that name' {
        $folder = [System.IO.Path]::Combine($script:Case, 'rel-default')
        [void][System.IO.Directory]::CreateDirectory($folder)
        $full = Resolve-SwSafePath -Path $folder
        $script:DefaultWhitelistPatterns = @('rel-default')
        Use-ProcessDirectory $script:Case {
            Assert-Result (Test-Wl ($full + '\child.txt')) $false 'below the folder'
        }
    }

    It 'B-22 trims the expanded value before it checks for a drive: <Value>' -ForEach @(
        @{ Value = ' C:\Data ' }
        @{ Value = "`tC:\Data`t" }
    ) {
        Set-Env 'SWTEST_WL_PAD' $Value
        try {
            ConvertFrom-SwListEntry -Line '%SWTEST_WL_PAD%' | Should -BeExactly 'C:\Data'
            $items = Get-Items (ConvertFrom-SwListEntry -Line '%SWTEST_WL_PAD%' -IncludeRaw)
            $items.Count | Should -Be 2
            $items[0] | Should -BeExactly 'C:\Data'
            $items[1] | Should -BeExactly '%SWTEST_WL_PAD%'
            Set-WlLines @('%SWTEST_WL_PAD%')
            Assert-Result (Test-Wl 'C:\Data\x') $true 'below the folder'
            Assert-Result (Test-Wl 'C:\Data2\x') $false 'prefix sibling'
        }
        finally { Set-Env 'SWTEST_WL_PAD' $null }
    }

    It 'B-26 keeps every path for an invalid wildcard pattern and says why in the debug stream' {
        Set-WlLines @('C:\Data\[b-a]')
        Assert-Result (Test-Wl 'D:\Other\y') $true 'ordinary path'
        $previous = $DebugPreference
        try {
            $DebugPreference = 'Continue'
            $records = @(Get-SwWhitelistState 5>&1 | Where-Object { $_ -is [System.Management.Automation.DebugRecord] })
        }
        finally { $DebugPreference = $previous }
        $records.Count | Should -BeGreaterOrEqual 1
        ($records | Select-Object -First 1).Message | Should -Match 'not valid'
        ($records | Select-Object -First 1).Message | Should -Not -Match 'cannot be read'
    }

    It 'B-28 resolves a relative line against the PowerShell location when the process working directory differs' {
        $processFolder = [System.IO.Path]::Combine($script:Case, 'process-folder')
        $shellFolder = [System.IO.Path]::Combine($script:Case, 'shell-folder')
        $item = [System.IO.Path]::Combine($shellFolder, 'only-in-shell')
        $sibling = [System.IO.Path]::Combine($shellFolder, 'only-in-shell-other')
        foreach ($dir in $processFolder, $item, $sibling) { [void][System.IO.Directory]::CreateDirectory($dir) }
        $full = Resolve-SwSafePath -Path $item
        $fullSibling = Resolve-SwSafePath -Path $sibling
        Push-Location -LiteralPath $shellFolder
        try {
            Use-ProcessDirectory $processFolder {
                Set-WlLines @('only-in-shell')
                Assert-Result (Test-Wl $full) $true 'the folder under the PowerShell location'
                Assert-Result (Test-Wl ($full + '\child.txt')) $true 'a file below it'
                Assert-Result (Test-Wl ($fullSibling + '\child.txt')) $false 'prefix sibling'
            }
        }
        finally { Pop-Location }
    }

    It 'B-28 resolves a relative line against the process working directory when the PowerShell location differs' {
        $processFolder = [System.IO.Path]::Combine($script:Case, 'process-two')
        $shellFolder = [System.IO.Path]::Combine($script:Case, 'shell-two')
        $item = [System.IO.Path]::Combine($processFolder, 'only-in-process')
        foreach ($dir in $item, $shellFolder) { [void][System.IO.Directory]::CreateDirectory($dir) }
        $full = Resolve-SwSafePath -Path $item
        Push-Location -LiteralPath $shellFolder
        try {
            Use-ProcessDirectory $processFolder {
                Set-WlLines @('only-in-process')
                Assert-Result (Test-Wl ($full + '\child.txt')) $true 'a file below the folder under the process directory'
            }
        }
        finally { Pop-Location }
    }

    It 'B-28 [W] treats a drive-relative line like a relative one' {
        if (-not $script:OnWindows) { Set-ItResult -Skipped -Because 'a drive-relative path needs a drive letter'; return }
        $folder = [System.IO.Path]::Combine($script:Case, 'drive-rel')
        $sibling = [System.IO.Path]::Combine($script:Case, 'drive-rel-other')
        [void][System.IO.Directory]::CreateDirectory($folder)
        [void][System.IO.Directory]::CreateDirectory($sibling)
        $full = Resolve-SwSafePath -Path $folder
        $fullSibling = Resolve-SwSafePath -Path $sibling
        $drive = [System.IO.Path]::GetPathRoot($full).Substring(0, 2)
        Push-Location -LiteralPath $script:Case
        try {
            Use-ProcessDirectory $script:Case {
                Set-WlLines @($drive + 'drive-rel')
                Assert-Result (Test-Wl ($full + '\child.txt')) $true 'a file below it'
                Assert-Result (Test-Wl ($fullSibling + '\child.txt')) $false 'prefix sibling'
            }
        }
        finally { Pop-Location }
    }

    It 'B-22 never resolves a whitelist line with a single leading slash, against either working folder' {
        $name = 'slash-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $processFolder = [System.IO.Path]::Combine($script:Case, 'process-slash')
        $shellFolder = [System.IO.Path]::Combine($script:Case, 'shell-slash')
        foreach ($dir in [System.IO.Path]::Combine($processFolder, $name), [System.IO.Path]::Combine($shellFolder, $name)) { [void][System.IO.Directory]::CreateDirectory($dir) }
        $underProcess = Resolve-SwSafePath -Path ([System.IO.Path]::Combine($processFolder, $name))
        $underShell = Resolve-SwSafePath -Path ([System.IO.Path]::Combine($shellFolder, $name))
        Push-Location -LiteralPath $shellFolder
        try {
            Use-ProcessDirectory $processFolder {
                Set-WlLines @('/' + $name)
                Assert-Result (Test-Wl ($underShell + '\f')) $false 'below the folder under the PowerShell location'
                Assert-Result (Test-Wl ($underProcess + '\f')) $false 'below the folder under the process directory'
                Assert-Result (Test-Wl ('/' + $name + '\f')) $true 'the text as written stays protected'
                if ($script:OnWindows) {
                    $drive = [System.IO.Path]::GetPathRoot($underShell).Substring(0, 2)
                    Assert-Result (Test-Wl ($drive + '\' + $name + '\f')) $false 'the same name at the root of the current drive'
                }
            }
        }
        finally { Pop-Location }
    }

    It 'B-28 protects a candidate in the normalized form of a line that holds dot segments' {
        $keep = [System.IO.Path]::Combine($script:Case, 'keep-dots')
        $keepOther = [System.IO.Path]::Combine($script:Case, 'keep-dot-slash')
        $dotted = [System.IO.Path]::Combine($script:Case, 'a', '..', 'keep-dots')
        $current = [System.IO.Path]::Combine($script:Case, '.', 'keep-dot-slash')
        Set-WlLines @($dotted, $current)
        $normalized = [System.IO.Path]::GetFullPath($keep)
        $normalizedOther = [System.IO.Path]::GetFullPath($keepOther)
        Assert-Result (Test-Wl (Win $normalized 'f')) $true 'below the normalized form of the .. line'
        Assert-Result (Test-Wl (Win $normalizedOther 'f')) $true 'below the normalized form of the . line'
        Assert-Result (Test-Wl (Win ($normalized + '-other') 'f')) $false 'prefix sibling'
        Assert-Result (Test-Wl (Win $script:Case 'keep-else\f')) $false 'unrelated path'
    }

    It 'B-28 [W] protects a candidate in the long spelling below a line written with 8.3 short names' {
        if (-not $script:OnWindows) { Set-ItResult -Skipped -Because 'short names exist only on Windows'; return }
        if (-not ('SwTest.ShortName' -as [type])) {
            Add-Type -Namespace SwTest -Name ShortName -MemberDefinition '[DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern uint GetShortPathNameW(string longPath, System.Text.StringBuilder shortPath, uint length);'
        }
        $long = [System.IO.Path]::Combine($script:Case, 'LongFolderNameForShortForm', 'keep-this-folder')
        $other = [System.IO.Path]::Combine($script:Case, 'LongFolderNameForShortForm', 'keep-this-folder-other')
        [void][System.IO.Directory]::CreateDirectory($long)
        [void][System.IO.Directory]::CreateDirectory($other)
        $buffer = New-Object System.Text.StringBuilder 1024
        $length = [SwTest.ShortName]::GetShortPathNameW($long, $buffer, 1024)
        $short = $buffer.ToString()
        if ($length -eq 0 -or $short -ieq $long) { Set-ItResult -Skipped -Because '8.3 names are disabled on this volume'; return }
        Set-WlLines @($short)
        Assert-Result (Test-Wl ($long + '\f')) $true 'long spelling below the folder'
        Assert-Result (Test-Wl ($short + '\f')) $true 'short spelling below the folder'
        Assert-Result (Test-Wl ($other + '\f')) $false 'prefix sibling in long spelling'
    }
}

# ============================================================================
# Whitelist: junction roots and file placement (Windows file system)
# ============================================================================

Describe 'Whitelist junction roots [W]' {
    BeforeAll {
        $script:FxRoot = [System.IO.Path]::Combine($TestDrive, 'wl-junction')
        Use-Fixture -UserProfile 'C:\Users\Example' -Local 'C:\Users\Example\AppData\Local' -Roaming 'C:\Users\Example\AppData\Roaming'
        $script:Target = Join-Path $script:FxRoot 'target'
        $script:Wild = Join-Path $script:FxRoot 'wild'
        $script:Literal = Join-Path $script:FxRoot 'literal'
        foreach ($dir in @($script:Target, $script:Wild, $script:Literal)) { [void][System.IO.Directory]::CreateDirectory($dir) }
        $script:Link = Join-Path $script:FxRoot 'link'
        New-TestJunction $script:Link $script:Target
    }
    AfterAll {
        Restore-Fixture
        try { Remove-TestJunction $script:Link } catch { $null = $_ }
    }
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        $script:Config = @{ ConfigPath = ''; CachePath = ''; WhitelistFile = (Join-Path $script:FxRoot 'whitelist.txt') }
        $script:DefaultWhitelistPatterns = @()
    }
    AfterEach { Stop-Case }

    It 'B-28 protects a candidate in the typed and in the final spelling below a junction root' {
        [System.IO.File]::WriteAllBytes($script:Config.WhitelistFile, (Get-EncodedBytes 'UTF-8 with BOM' ($script:Link + "`r`n")))
        Assert-Result (Test-SwWhitelisted -Path (Join-Path $script:Link 'registry')) $true 'typed spelling'
        Assert-Result (Test-SwWhitelisted -Path (Join-Path $script:Target 'registry')) $true 'final spelling'
        Assert-Result (Test-SwWhitelisted -Path ($script:Target + '-other\registry')) $false 'sibling of the target'
    }

    It 'S-B11 keeps protecting both spellings when more lines are added in any order' {
        $lines = @($script:Link, (Join-Path $script:Wild '*.keep'), $script:Literal)
        foreach ($order in @(@(0, 1, 2), @(1, 0, 2), @(1, 2, 0), @(2, 1, 0))) {
            [System.IO.File]::WriteAllBytes($script:Config.WhitelistFile, (Get-EncodedBytes 'UTF-8 with BOM' ((($order | ForEach-Object { $lines[$_] }) -join "`r`n") + "`r`n")))
            $tag = "order $($order -join '')"
            Assert-Result (Test-SwWhitelisted -Path (Join-Path $script:Link 'child.bin')) $true "typed junction, $tag"
            Assert-Result (Test-SwWhitelisted -Path (Join-Path $script:Target 'child.bin')) $true "final junction, $tag"
            Assert-Result (Test-SwWhitelisted -Path (Join-Path $script:Wild 'saved.keep')) $true "wildcard line, $tag"
            Assert-Result (Test-SwWhitelisted -Path (Join-Path $script:Literal 'child.bin')) $true "literal folder, $tag"
            Assert-Result (Test-SwWhitelisted -Path (Join-Path $script:Wild 'ordinary.tmp')) $false "ordinary file, $tag"
            Assert-Result (Test-SwWhitelisted -Path ($script:Literal + '-other\child.bin')) $false "prefix sibling, $tag"
        }
    }

    It 'B-28 does not resolve wildcard lines' {
        [System.IO.File]::WriteAllBytes($script:Config.WhitelistFile, (Get-EncodedBytes 'UTF-8 with BOM' ((Join-Path $script:Link '*.keep') + "`r`n")))
        Assert-Result (Test-SwWhitelisted -Path (Join-Path $script:Link 'a.keep')) $true 'typed spelling'
        Assert-Result (Test-SwWhitelisted -Path (Join-Path $script:Target 'a.keep')) $false 'final spelling of a wildcard line'
    }

    It 'B-28 protects the final spelling of a junction used as the data folder' {
        $script:Config.ConfigPath = $script:Link
        Assert-Result (Test-SwWhitelisted -Path (Join-Path $script:Target 'operations.log')) $true 'final spelling'
        Assert-Result (Test-SwWhitelisted -Path (Join-Path $script:Link 'operations.log')) $true 'typed spelling'
    }
}

# ============================================================================
# Whitelist: data folders and default entries
# ============================================================================

Describe 'Whitelist data folders' {
    BeforeAll {
        $script:FxRoot = [System.IO.Path]::Combine($TestDrive, 'ds-fixture')
        Use-Fixture -UserProfile 'C:\Users\Example' -Local 'C:\Users\Example\AppData\Local' -Roaming 'C:\Users\Example\AppData\Roaming'
    }
    AfterAll { Restore-Fixture }
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        $script:Config = @{ ConfigPath = ''; CachePath = ''; WhitelistFile = [System.IO.Path]::Combine($script:FxRoot, [guid]::NewGuid().ToString('N'), 'whitelist.txt') }
        $script:DefaultWhitelistPatterns = @()
    }
    AfterEach { Stop-Case }

    It 'B-25 protects the <Key> folder, its content and nothing that only begins like it' -ForEach @(
        @{ Key = 'ConfigPath' }
        @{ Key = 'CachePath' }
    ) {
        $script:Config[$Key] = 'C:\Scratch\Example\data'
        Assert-Result (Test-SwWhitelisted -Path 'C:\Scratch\Example\data') $true 'folder'
        Assert-Result (Test-SwWhitelisted -Path 'C:\Scratch\Example\data\') $true 'folder with backslash'
        Assert-Result (Test-SwWhitelisted -Path 'C:\Scratch\Example\data\nested\operations.log') $true 'nested file'
        Assert-Result (Test-SwWhitelisted -Path 'C:\Scratch\Example\DATA\Whitelist.txt') $true 'upper-case'
        Assert-Result (Test-SwWhitelisted -Path 'C:\Scratch\Example\data2') $false 'data2'
        Assert-Result (Test-SwWhitelisted -Path 'C:\Scratch\Example\data2\file.tmp') $false 'data2 child'
        Assert-Result (Test-SwWhitelisted -Path 'C:\Scratch\Example\data-old\file.tmp') $false 'data-old'
        Assert-Result (Test-SwWhitelisted -Path 'C:\Scratch\Example') $false 'parent'
        Assert-Result (Test-SwWhitelisted -Path 'C:\Scratch\Example\other.tmp') $false 'sibling file'
    }

    It 'B-25 reads brackets in the <Key> folder name literally' -ForEach @(
        @{ Key = 'ConfigPath' }
        @{ Key = 'CachePath' }
    ) {
        $script:Config[$Key] = 'C:\Scratch\Example\[x]\data'
        Assert-Result (Test-SwWhitelisted -Path 'C:\Scratch\Example\[x]\data\whitelist.txt') $true 'literal folder'
        Assert-Result (Test-SwWhitelisted -Path 'C:\Scratch\Example\x\data\whitelist.txt') $false 'folder the brackets would match as a wildcard'
    }

    It 'B-25 reads a star in the <Key> folder name literally' -ForEach @(
        @{ Key = 'ConfigPath' }
        @{ Key = 'CachePath' }
    ) {
        $script:Config[$Key] = 'C:\Scratch\Example\d*ta'
        Assert-Result (Test-SwWhitelisted -Path 'C:\Scratch\Example\d*ta\whitelist.txt') $true 'literal folder'
        Assert-Result (Test-SwWhitelisted -Path 'C:\Scratch\Example\data\whitelist.txt') $false 'folder the star would match as a wildcard'
        Assert-Result (Test-SwWhitelisted -Path 'C:\Scratch\Example\dxxta') $false 'another wildcard match'
    }

    It 'B-25 protects both folders at the same time' {
        $script:Config.ConfigPath = 'C:\Scratch\Example\config'
        $script:Config.CachePath = 'C:\Scratch\Example\cache'
        Assert-Result (Test-SwWhitelisted -Path 'C:\Scratch\Example\config\whitelist.txt') $true 'config'
        Assert-Result (Test-SwWhitelisted -Path 'C:\Scratch\Example\cache\x.bin') $true 'cache'
        Assert-Result (Test-SwWhitelisted -Path 'C:\Scratch\Example\other\x.bin') $false 'other folder'
    }

    It 'B-25 lets an empty or null <Key> value protect nothing and cause no error' -ForEach @(
        @{ Key = 'ConfigPath' }
        @{ Key = 'CachePath' }
    ) {
        foreach ($value in '', '   ', $null) {
            $script:Config[$Key] = $value
            { Get-SwWhitelistState } | Should -Not -Throw
            Assert-Result (Test-SwWhitelisted -Path 'C:\Scratch\x') $false "value '$value'"
            Assert-Result (Test-SwWhitelisted -Path 'D:\Other\y') $false "value '$value', other drive"
        }
    }

    It 'B-25 reads both values when the state is built (A-13)' {
        $script:Config.ConfigPath = 'C:\First\data'
        $first = Get-SwWhitelistState
        $script:Config.ConfigPath = 'C:\Second\data'
        $second = Get-SwWhitelistState
        Assert-Result (Test-SwWhitelisted -Path 'C:\First\data\x' -State $first) $true 'old state, old folder'
        Assert-Result (Test-SwWhitelisted -Path 'C:\Second\data\x' -State $first) $false 'old state, new folder'
        Assert-Result (Test-SwWhitelisted -Path 'C:\Second\data\x' -State $second) $true 'new state, new folder'
        Assert-Result (Test-SwWhitelisted -Path 'C:\First\data\x' -State $second) $false 'new state, old folder'
        Assert-Result (Test-SwWhitelisted -Path 'C:\Second\data\x') $true 'no state given'
    }

    It 'S-B10 keeps the data folders protected even when the user file lists other entries or is empty' {
        $script:Config.ConfigPath = 'C:\Scratch\Example\data'
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($script:Config.WhitelistFile))
        [System.IO.File]::WriteAllBytes($script:Config.WhitelistFile, (Get-EncodedBytes 'UTF-8 with BOM' "C:\Other\Only`r`n"))
        Assert-Result (Test-SwWhitelisted -Path 'C:\Scratch\Example\data\operations.log') $true 'with another entry'
        [System.IO.File]::WriteAllBytes($script:Config.WhitelistFile, [byte[]]@())
        Assert-Result (Test-SwWhitelisted -Path 'C:\Scratch\Example\data\operations.log') $true 'with an empty file'
    }
}

Describe 'Default whitelist' {
    BeforeAll {
        $script:FxRoot = [System.IO.Path]::Combine($TestDrive, 'default-fixture')
        $script:U = 'C:\Users\Example'
        $script:L = 'C:\Users\Example\AppData\Local'
        $script:R = 'C:\Users\Example\AppData\Roaming'
        Use-Fixture -UserProfile $script:U -Local $script:L -Roaming $script:R
        function script:Expand-Template([string]$Template) { $Template.Replace('{L}', $script:L).Replace('{R}', $script:R).Replace('{U}', $script:U) }
    }
    AfterAll { Restore-Fixture }
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        $script:Config = @{ ConfigPath = ''; CachePath = ''; WhitelistFile = [System.IO.Path]::Combine($script:FxRoot, [guid]::NewGuid().ToString('N'), 'whitelist.txt') }
    }
    AfterEach { Stop-Case }

    It 'B-L6 holds exactly eleven default patterns' {
        @($script:DefaultWhitelistPatterns).Count | Should -Be 11
    }

    It 'B-L6 holds the default pattern for <Name>, built from the environment' -ForEach $script:DefaultEntries {
        @($script:DefaultWhitelistPatterns) | Should -Contain (Expand-Template $Template)
    }

    It 'B-24 protects <Name> with no whitelist file, and everything below it' -ForEach $script:DefaultEntries {
        $entry = Expand-Template $Template
        if ($Child -ne '') {
            Assert-Result (Test-SwWhitelisted -Path $entry) $true 'the entry'
            Assert-Result (Test-SwWhitelisted -Path ($entry + '\')) $true 'the entry with a backslash'
            Assert-Result (Test-SwWhitelisted -Path ($entry + '\' + $Child)) $true 'a child'
            Assert-Result (Test-SwWhitelisted -Path ($entry.ToUpperInvariant() + '\' + $Child)) $true 'upper-case'
            $parent = $entry.Substring(0, $entry.LastIndexOf('\'))
            Assert-Result (Test-SwWhitelisted -Path $parent) $false 'the parent'
            Assert-Result (Test-SwWhitelisted -Path ($parent + '\' + $Sibling + '\x')) $false 'a sibling with a similar name'
        }
        else {
            $concrete = $entry.Replace('files-*', 'files-2.1')
            Assert-Result (Test-SwWhitelisted -Path $concrete) $true 'a folder the wildcard matches'
            Assert-Result (Test-SwWhitelisted -Path ($concrete + '\x\y.jar')) $true 'a file below it'
            Assert-Result (Test-SwWhitelisted -Path ($entry.Replace('files-*', 'metadata-2.1') + '\x')) $false 'a sibling folder'
        }
    }

    It 'S-B13 keeps the default entries when the user file is empty or lists other entries' {
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($script:Config.WhitelistFile))
        [System.IO.File]::WriteAllBytes($script:Config.WhitelistFile, [byte[]]@())
        Assert-Result (Test-SwWhitelisted -Path ($script:U + '\.cargo\registry')) $true 'empty file'
        [System.IO.File]::WriteAllBytes($script:Config.WhitelistFile, (Get-EncodedBytes 'UTF-8 with BOM' "# nothing of the defaults`r`nC:\Other`r`n"))
        Assert-Result (Test-SwWhitelisted -Path ($script:U + '\.cargo\registry')) $true 'file with another entry'
        Assert-Result (Test-SwWhitelisted -Path ($script:L + '\JetBrains\x')) $true 'JetBrains'
        Assert-Result (Test-SwWhitelisted -Path 'C:\Scratch\x') $false 'ordinary path'
    }

    It 'B-24 follows a replaced list from the next state on' {
        $script:DefaultWhitelistPatterns = @()
        Assert-Result (Test-SwWhitelisted -Path ($script:U + '\.cargo\registry')) $false 'empty list'
        $script:DefaultWhitelistPatterns = @('C:\Custom\Keep')
        Assert-Result (Test-SwWhitelisted -Path 'C:\Custom\Keep\x') $true 'custom entry'
        Assert-Result (Test-SwWhitelisted -Path ($script:U + '\.cargo\registry')) $false 'old default'
    }

    It 'B-24 gives a pattern without effect, and no error, when an environment variable is empty' {
        Set-Env 'USERPROFILE' ''
        Set-Env 'LOCALAPPDATA' ''
        Set-Env 'APPDATA' ''
        Import-Base
        $script:Config = @{ ConfigPath = ''; CachePath = ''; WhitelistFile = [System.IO.Path]::Combine($script:FxRoot, 'none', 'whitelist.txt') }
        { Get-SwWhitelistState } | Should -Not -Throw
        foreach ($path in 'C:\Scratch\x', 'C:\.nuget\x', 'C:\Users\Example\.nuget', 'C:\JetBrains\x', 'C:\Microsoft\Windows\Explorer\x', 'D:\.cargo\registry') {
            Assert-Result (Test-SwWhitelisted -Path $path) $false $path
        }
    }
}

# ============================================================================
# Read-only behaviour of part B
# ============================================================================

Describe 'Side effects of part B functions' {
    BeforeAll {
        $script:FxRoot = [System.IO.Path]::Combine($TestDrive, 'readonly-fixture')
        Use-Fixture -UserProfile 'C:\Users\Example' -Local 'C:\Users\Example\AppData\Local' -Roaming 'C:\Users\Example\AppData\Roaming'
    }
    AfterAll { Restore-Fixture }
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
    }
    AfterEach { Stop-Case }

    It 'S-B12 leaves the file system unchanged and starts no process, also in a dry-run environment' {
        Mock Start-Process { }
        Mock Start-Job { }
        Mock Invoke-WebRequest { }
        Mock Invoke-RestMethod { }
        $env:SWEEPR_DRY_RUN = '1'
        try {
            $dir = [System.IO.Path]::Combine($script:FxRoot, 'tree')
            [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::Combine($dir, 'sub'))
            $file = [System.IO.Path]::Combine($dir, 'sub', 'file.txt')
            [System.IO.File]::WriteAllText($file, 'content')
            $list = [System.IO.Path]::Combine($dir, 'whitelist.txt')
            [System.IO.File]::WriteAllBytes($list, (Get-EncodedBytes 'UTF-8 with BOM' "$dir`r`n"))
            $script:Config = @{ ConfigPath = [System.IO.Path]::Combine($dir, 'config'); CachePath = [System.IO.Path]::Combine($dir, 'cache'); WhitelistFile = $list }
            $snapshot = {
                @(Get-ChildItem -LiteralPath $script:FxRoot -Force -Recurse | ForEach-Object {
                        # Folder timestamps can move on their own under Windows; folders are compared by name only.
                        if ($_.PSIsContainer) { '{0}|folder' -f $_.FullName } else { '{0}|{1}|{2}' -f $_.FullName, $_.LastWriteTimeUtc.Ticks, $_.Length }
                    } | Sort-Object)
            }
            $before = & $snapshot
            $null = Test-SwProtectedPath -Path $file
            $null = Test-SwProtectedPath -Path $dir -AlreadyResolved
            $null = Resolve-SwSafePath -Path $file
            $null = Resolve-SwSafePath -Path ([System.IO.Path]::Combine($dir, 'missing', 'x'))
            $state = Get-SwWhitelistState
            $null = Test-SwWhitelisted -Path $file -State $state
            $null = Test-SwWhitelisted -Path $file
            $bytes = Read-SwListBytes -Path $list
            $null = ConvertFrom-SwListBytes -Bytes $bytes
            $null = ConvertFrom-SwListEntry -Line $dir
            $after = & $snapshot
            ($after -join "`n") | Should -BeExactly ($before -join "`n")
            foreach ($name in 'Start-Process', 'Start-Job', 'Invoke-WebRequest', 'Invoke-RestMethod') {
                Should -Invoke -CommandName $name -Times 0 -Exactly
            }
        }
        finally { Remove-Item Env:SWEEPR_DRY_RUN -ErrorAction SilentlyContinue }
    }

    It 'S-B12 returns only its value and writes nothing else for <Name>' -ForEach @(
        @{ Name = 'Test-SwProtectedPath'; Call = { Test-SwProtectedPath -Path 'C:\x' } }
        @{ Name = 'Resolve-SwSafePath'; Call = { Resolve-SwSafePath -Path 'C:\x' } }
        @{ Name = 'Get-SwWhitelistState'; Call = { Get-SwWhitelistState } }
        @{ Name = 'Test-SwWhitelisted'; Call = { Test-SwWhitelisted -Path 'C:\x' } }
        @{ Name = 'ConvertFrom-SwListEntry'; Call = { ConvertFrom-SwListEntry -Line 'C:\x' } }
    ) {
        $script:Config = @{ ConfigPath = ''; CachePath = ''; WhitelistFile = [System.IO.Path]::Combine($script:FxRoot, 'none', 'whitelist.txt') }
        $records = @(& $Call *>&1)
        $records.Count | Should -Be 1
    }
}

# ============================================================================
# Old names (forwarding functions)
# ============================================================================

Describe 'Transition names of part B' {
    BeforeAll {
        $script:FxRoot = [System.IO.Path]::Combine($TestDrive, 'forward-fixture')
        $script:FxHome = [System.IO.Path]::Combine($script:FxRoot, 'Users', 'Example')
        $script:FxProt = [System.IO.Path]::Combine($script:FxRoot, 'protected')
        Use-Fixture -UserProfile $script:FxHome -Local (Win $script:FxHome 'AppData\Local') -Roaming (Win $script:FxHome 'AppData\Roaming')
    }
    AfterAll { Restore-Fixture }
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
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

    It 'Test-ProtectedPath gives the same answers as Test-SwProtectedPath' {
        $script:ProtectedPaths = @($script:FxProt)
        $script:ExactProtectedPaths = @($script:FxHome)
        $script:SweeprCleanPathGuard = $true
        foreach ($path in @('', '   ', $null, $script:FxProt, (Win $script:FxProt 'child'), $script:FxHome, (Win $script:FxHome 'Docs'), (Win $script:FxHome '.ssh\id'), (Win $script:FxRoot 'other'))) {
            Test-ProtectedPath -Path $path | Should -Be (Test-SwProtectedPath -Path $path)
            Test-ProtectedPath -Path $path -AlreadyResolved | Should -Be (Test-SwProtectedPath -Path $path -AlreadyResolved)
        }
        Test-ProtectedPath (Win $script:FxProt 'child') | Should -BeTrue
    }

    It 'Resolve-SafePath gives the same results as Resolve-SwSafePath' {
        [void][System.IO.Directory]::CreateDirectory($script:FxRoot)
        foreach ($path in @('', $script:FxRoot, (Win $script:FxRoot 'missing\x'), ($script:FxRoot + '\bad' + [char]0 + 'x'))) {
            $old = Resolve-SafePath -Path $path
            $new = Resolve-SwSafePath -Path $path
            if ($null -eq $new) { $null -eq $old | Should -BeTrue } else { $old | Should -BeExactly $new }
        }
    }

    It 'Get-WhitelistState and Test-Whitelisted give the same answers as the new functions' {
        $listFile = [System.IO.Path]::Combine($script:FxRoot, 'forward-list', 'whitelist.txt')
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($listFile))
        [System.IO.File]::WriteAllBytes($listFile, (Get-EncodedBytes 'UTF-8 with BOM' "C:\Keep\A`r`n"))
        $script:Config = @{ ConfigPath = ''; CachePath = ''; WhitelistFile = $listFile }
        $script:DefaultWhitelistPatterns = @()
        $oldState = Get-WhitelistState
        $newState = Get-SwWhitelistState
        foreach ($path in @('C:\Keep\A\x', 'C:\Keep\B\x', 'D:\Other', '')) {
            Test-Whitelisted -Path $path -State $oldState | Should -Be (Test-SwWhitelisted -Path $path -State $newState)
            Test-Whitelisted -Path $path | Should -Be (Test-SwWhitelisted -Path $path)
        }
    }

    It 'Read-SweeprListBytes, ConvertFrom-SweeprListBytes and ConvertFrom-SweeprListEntry give the same results as the new functions' {
        $path = [System.IO.Path]::Combine($script:FxRoot, 'forward-bytes.txt')
        [void][System.IO.Directory]::CreateDirectory($script:FxRoot)
        $bytes = Get-EncodedBytes 'UTF-8 with BOM' "C:\Keep\A`r`n# comment`r`n"
        [System.IO.File]::WriteAllBytes($path, $bytes)
        ((Read-SweeprListBytes -Path $path) -join ',') | Should -BeExactly ((Read-SwListBytes -Path $path) -join ',')
        ((Get-Items (ConvertFrom-SweeprListBytes -Bytes $bytes)) -join '|') | Should -BeExactly ((Get-Items (ConvertFrom-SwListBytes -Bytes $bytes)) -join '|')
        foreach ($line in @('C:\Keep\A', '"C:/Keep/B"', '#c', '', '%SWTEST_FORWARD_UNDEFINED%\x')) {
            $old = Get-Items (ConvertFrom-SweeprListEntry -Line $line -IncludeRaw)
            $new = Get-Items (ConvertFrom-SwListEntry -Line $line -IncludeRaw)
            ($old -join '|') | Should -BeExactly ($new -join '|')
            $oldPlain = ConvertFrom-SweeprListEntry -Line $line
            $newPlain = ConvertFrom-SwListEntry -Line $line
            if ($null -eq $newPlain) { $null -eq $oldPlain | Should -BeTrue } else { $oldPlain | Should -BeExactly $newPlain }
        }
    }

    It 'Read-SweeprListBytes throws for a folder like Read-SwListBytes' {
        { Read-SweeprListBytes -Path $TestDrive } | Should -Throw
    }
}
