# Sweepr - tests for the data paths, system information, colour and icon tables, size format and
# literal quoting of lib\core\base.ps1, plus its load contract.
#
# Interface pinned here (new names, each old name stays as a forwarding function, not an alias):
#   ConvertTo-SwPsLiteral -Value                  single-quoted PowerShell literal
#   Get-SwColor -Name / Get-SwIcon -Name          table lookup with fallback to the defaults
#   Get-SwDefaultColors / Get-SwDefaultIcons      new hashtable on every call
#   Initialize-SwVisualDefaults                   fills missing keys of $script:Colors and $script:Icons
#   Test-SwPortable -RootDir                      marker file sweepr.portable in the program folder
#   Resolve-SwDataPaths -RootDir                  hashtable Mode, ConfigPath, CachePath (no side effects)
#   Assert-SwDataWritable -Path                   creates the folder, writes and deletes a probe file
#   Get-SwConfigPath / Get-SwCachePath            current folders from $script:Config, created on demand
#   Test-SwAdmin, Get-SwFreeSpace -Drive, Get-SwWindowsVersion, Format-SwByteSize -Bytes
#   Variables that callers replace: $script:Config, $script:Colors, $script:Icons,
#   $script:SWEEPR_BASE_LOADED
#
# Platform notes:
#   - Paths are built from $TestDrive. Expected and actual paths are compared with both separators
#     folded and without case, so the tests run on Windows and on Linux.
#   - Tests marked [W] need real Windows (drive letters, registry, identity, Windows PowerShell 5.1).
#     They are meant to fail on Linux and belong in tests/linux-known-failures.txt.
#   - Loading tests run in a child PowerShell against a copy of base.ps1 in a fake installation root, so
#     the location of the file decides the program folder (not the working directory).
#   - Nothing real is touched: data folders live in $TestDrive, the profile is a fake folder, no
#     process is started by the functions under test.

BeforeDiscovery {
    $esc = [string][char]27
    $script:ColorCases = @(
        @{ Name = 'Green'; Code = '[0;32m' }
        @{ Name = 'Blue'; Code = '[0;34m' }
        @{ Name = 'Cyan'; Code = '[0;36m' }
        @{ Name = 'Yellow'; Code = '[0;33m' }
        @{ Name = 'Purple'; Code = '[0;35m' }
        @{ Name = 'PurpleBold'; Code = '[1;35m' }
        @{ Name = 'Red'; Code = '[0;31m' }
        @{ Name = 'Gray'; Code = '[0;90m' }
        @{ Name = 'White'; Code = '[0;37m' }
        @{ Name = 'NC'; Code = '[0m' }
    )
    $script:IconCases = @(
        @{ Name = 'Confirm'; CodePoint = 0x25CE }
        @{ Name = 'Admin'; CodePoint = 0x2699 }
        @{ Name = 'Success'; CodePoint = 0x2713 }
        @{ Name = 'Error'; CodePoint = 0x263B }
        @{ Name = 'Warning'; CodePoint = 0x25CF }
        @{ Name = 'Empty'; CodePoint = 0x25CB }
        @{ Name = 'Solid'; CodePoint = 0x25CF }
        @{ Name = 'List'; CodePoint = 0x2022 }
        @{ Name = 'NavUp'; CodePoint = 0x2191 }
        @{ Name = 'NavDown'; CodePoint = 0x2193 }
        @{ Name = 'Folder'; CodePoint = 0x25A0 }
        @{ Name = 'File'; CodePoint = 0x25A1 }
        @{ Name = 'Trash'; CodePoint = 0x2718 }
        @{ Name = 'Arrow'; CodePoint = 0x27A4 }
        @{ Name = 'DryRun'; CodePoint = 0x2192 }
    )
    $script:QuoteCases = @(
        @{ Name = 'U+0027 apostrophe'; CodePoint = 0x27 }
        @{ Name = 'U+2018 left single quotation mark'; CodePoint = 0x2018 }
        @{ Name = 'U+2019 right single quotation mark'; CodePoint = 0x2019 }
        @{ Name = 'U+201A single low-9 quotation mark'; CodePoint = 0x201A }
        @{ Name = 'U+201B single high-reversed-9 quotation mark'; CodePoint = 0x201B }
    )
    $script:SizeCases = @(
        @{ Bytes = 1099511627776; Expected = '1.00TB' }
        @{ Bytes = 1073741824; Expected = '1.00GB' }
        @{ Bytes = 1572864; Expected = '1.5MB' }
        @{ Bytes = 1048576; Expected = '1.0MB' }
        @{ Bytes = 1536; Expected = '2KB' }
        @{ Bytes = 1024; Expected = '1KB' }
        @{ Bytes = 1023; Expected = '1023B' }
        @{ Bytes = 1; Expected = '1B' }
        @{ Bytes = 0; Expected = '0B' }
        @{ Bytes = 1048575; Expected = '1,024KB' }
        @{ Bytes = 1073741823; Expected = '1,024.0MB' }
        @{ Bytes = 1099511627775; Expected = '1,024.00GB' }
        @{ Bytes = -1; Expected = '-1B' }
    )
    $script:Forwarders = @(
        @{ Old = 'ConvertTo-SweeprPsLiteral'; New = 'ConvertTo-SwPsLiteral'; Pass = $true
            Invoke = { ConvertTo-SweeprPsLiteral -Value 'it''s' }; Filter = { $Value -eq 'it''s' } }
        @{ Old = 'Get-SweeprColor'; New = 'Get-SwColor'; Pass = $true
            Invoke = { Get-SweeprColor 'Green' }; Filter = { $Name -eq 'Green' } }
        @{ Old = 'Get-SweeprIcon'; New = 'Get-SwIcon'; Pass = $true
            Invoke = { Get-SweeprIcon 'Solid' }; Filter = { $Name -eq 'Solid' } }
        @{ Old = 'Get-SweeprDefaultColors'; New = 'Get-SwDefaultColors'; Pass = $true
            Invoke = { Get-SweeprDefaultColors }; Filter = { $true } }
        @{ Old = 'Get-SweeprDefaultIcons'; New = 'Get-SwDefaultIcons'; Pass = $true
            Invoke = { Get-SweeprDefaultIcons }; Filter = { $true } }
        @{ Old = 'Initialize-SweeprVisualDefaults'; New = 'Initialize-SwVisualDefaults'; Pass = $false
            Invoke = { Initialize-SweeprVisualDefaults }; Filter = { $true } }
        @{ Old = 'Test-SweeprPortable'; New = 'Test-SwPortable'; Pass = $true
            Invoke = { Test-SweeprPortable -RootDir 'Example-Root' }; Filter = { $RootDir -eq 'Example-Root' } }
        @{ Old = 'Resolve-SweeprDataPaths'; New = 'Resolve-SwDataPaths'; Pass = $true
            Invoke = { Resolve-SweeprDataPaths -RootDir 'Example-Root' }; Filter = { $RootDir -eq 'Example-Root' } }
        @{ Old = 'Assert-SweeprDataWritable'; New = 'Assert-SwDataWritable'; Pass = $false
            Invoke = { Assert-SweeprDataWritable -Path 'Example-Path' }; Filter = { $Path -eq 'Example-Path' } }
        @{ Old = 'Get-ConfigPath'; New = 'Get-SwConfigPath'; Pass = $true
            Invoke = { Get-ConfigPath }; Filter = { $true } }
        @{ Old = 'Get-CachePath'; New = 'Get-SwCachePath'; Pass = $true
            Invoke = { Get-CachePath }; Filter = { $true } }
        @{ Old = 'Test-IsAdmin'; New = 'Test-SwAdmin'; Pass = $true
            Invoke = { Test-IsAdmin }; Filter = { $true } }
        @{ Old = 'Get-FreeSpace'; New = 'Get-SwFreeSpace'; Pass = $true
            Invoke = { Get-FreeSpace -Drive 'Q:' }; Filter = { $Drive -eq 'Q:' } }
        @{ Old = 'Get-WindowsVersion'; New = 'Get-SwWindowsVersion'; Pass = $true
            Invoke = { Get-WindowsVersion }; Filter = { $true } }
        @{ Old = 'Format-ByteSize'; New = 'Format-SwByteSize'; Pass = $true
            Invoke = { Format-ByteSize 1024 }; Filter = { $Bytes -eq 1024 } }
    )
    $script:NastyValues = @(
        @{ Name = 'apostrophe in a word'; Value = 'it''s' }
        @{ Name = 'only quotes'; Value = '''''''' }
        @{ Name = 'leading and trailing apostrophe'; Value = '''x''' }
        @{ Name = 'statement separator after a quote'; Value = '''; Write-Output pwned; ''' }
        @{ Name = 'typographic quote then statement'; Value = ([string][char]0x2019 + '; Write-Output pwned; ' + [string][char]0x2018) }
        @{ Name = 'subexpression'; Value = '$(Get-Date)' }
        @{ Name = 'variable'; Value = '$env:USERPROFILE' }
        @{ Name = 'double quote'; Value = 'a"b' }
        @{ Name = 'backtick'; Value = 'a`b`n' }
        @{ Name = 'line break'; Value = "line1`r`nline2" }
        @{ Name = 'brackets and parentheses'; Value = '[a](b){c}' }
        @{ Name = 'all five quote characters'; Value = ([string][char]0x27 + [char]0x2018 + [char]0x2019 + [char]0x201A + [char]0x201B) }
        @{ Name = 'here-string terminator'; Value = "x`n'@`ny" }
    )
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:BaseFile = [System.IO.Path]::Combine($script:RepoRoot, 'lib', 'core', 'base.ps1')
    $script:OnWindows = [System.IO.Path]::DirectorySeparatorChar -eq '\'
    $script:Esc = [string][char]27

    # Both separators folded, no case, no trailing separator: the comparison form of a path.
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

    # Variables of the module that tests change or replace; saved and restored around each test.
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

    # Loads base.ps1 again the way a test does after it changed the environment.
    function script:Import-Base {
        $script:SWEEPR_BASE_LOADED = $false
        . $script:BaseFile
    }

    function script:Invoke-WithCulture([string]$Name, [scriptblock]$Script) {
        $thread = [System.Threading.Thread]::CurrentThread
        $old = $thread.CurrentCulture
        try {
            $thread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($Name)
            & $Script
        }
        finally { $thread.CurrentCulture = $old }
    }

    # A drive letter that no drive of this host uses.
    function script:Get-UnusedDrive {
        $used = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpperInvariant() })
        foreach ($letter in 'Z', 'Y', 'X', 'W', 'V', 'U', 'T', 'S', 'R', 'Q') {
            if ($letter -notin $used) { return ($letter + ':') }
        }
        return 'Z:'
    }

    function script:Invoke-ChildPowerShell {
        param([string]$Script, [string]$WorkingDirectory = $TestDrive, [hashtable]$Environment = @{}, [string[]]$RemoveEnvironment = @(), [string]$Executable = '')
        $exe = $Executable
        if (-not $exe) { $exe = (Get-Process -Id $PID).Path }
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
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Out = $stdout.Result; Err = $stderr.Result }
    }

    # Windows PowerShell serializes progress records into redirected stderr as CLIXML ("Preparing modules
    # for first use"). That is the host talking, not the loaded file: drop the progress records and the
    # envelope and keep whatever else was written.
    function script:Get-ChildStderr([string]$Text) {
        if ([string]::IsNullOrEmpty($Text)) { return '' }
        $clean = [regex]::Replace($Text, '(?s)<Obj S="progress".*?</Obj>', '')
        $clean = [regex]::Replace($clean, '<Objs[^>]*>|</Objs>|#< CLIXML', '')
        return $clean.Trim()
    }

    function script:ConvertTo-TestLiteral([string]$Value) { "'" + $Value.Replace("'", "''") + "'" }

    # A fake installation root holding only base.ps1 at <root>\lib\core\base.ps1.
    function script:New-FakeRoot([string]$Name, [switch]$Portable) {
        $root = [System.IO.Path]::Combine($TestDrive, $Name)
        $core = [System.IO.Path]::Combine($root, 'lib', 'core')
        [void][System.IO.Directory]::CreateDirectory($core)
        [System.IO.File]::Copy($script:BaseFile, [System.IO.Path]::Combine($core, 'base.ps1'), $true)
        if ($Portable) { [System.IO.File]::WriteAllText([System.IO.Path]::Combine($root, 'sweepr.portable'), 'x') }
        $root
    }

    # Parses a PowerShell literal without running it; reports what it is.
    function script:Read-Literal([string]$Literal) {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Literal, [ref]$tokens, [ref]$errors)
        $result = [ordered]@{ Errors = @($errors).Count; Statements = 0; IsString = $false; Value = $null; Quote = '' }
        $statements = @($ast.EndBlock.Statements)
        $result.Statements = $statements.Count
        if ($statements.Count -eq 1 -and $statements[0] -is [System.Management.Automation.Language.PipelineAst]) {
            $elements = @($statements[0].PipelineElements)
            if ($elements.Count -eq 1 -and $elements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
                $expression = $elements[0].Expression
                if ($expression -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $result.IsString = $true
                    $result.Value = $expression.Value
                    $result.Quote = [string]$expression.StringConstantType
                }
            }
        }
        [pscustomobject]$result
    }

    # Parameter names, types, positions, mandatory flags and default texts, in declaration order.
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
    $script:PathsRootState = Save-BaseState
    . $script:BaseFile

    $script:SavedState = $null
    $script:SavedEnv = $null

    # What the whole file may change in the process, put back after the last test.
    $script:PathsRootEnv = Save-Env @('SWEEPR_DATA_DIR', 'USERPROFILE', 'SystemDrive', 'PROCESSOR_ARCHITECTURE', 'NO_COLOR', 'HOME', 'LOCALAPPDATA', 'APPDATA')
    $script:PathsRootDirectory = [System.Environment]::CurrentDirectory

    # Called from the BeforeEach / AfterEach of every block: variables and environment of the module under
    # test are saved before and put back after each test.
    function script:Start-Case {
        $script:SavedState = Save-BaseState
        $script:SavedEnv = Save-Env @('SWEEPR_DATA_DIR', 'USERPROFILE', 'SystemDrive', 'PROCESSOR_ARCHITECTURE', 'NO_COLOR', 'HOME')
    }
    function script:Stop-Case {
        Restore-Env $script:SavedEnv
        Restore-BaseState $script:SavedState
    }
}

AfterAll {
    Restore-BaseState $script:PathsRootState
    Restore-Env $script:PathsRootEnv
    [System.Environment]::CurrentDirectory = $script:PathsRootDirectory
}

# ============================================================================
# G: load contract
# ============================================================================

Describe 'Load contract' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
    }
    AfterEach { Stop-Case }
    BeforeAll {
        $script:FakeProfile = [System.IO.Path]::Combine($TestDrive, 'fake-profile')
        $script:Elsewhere = [System.IO.Path]::Combine($TestDrive, 'elsewhere')
        [void][System.IO.Directory]::CreateDirectory($script:FakeProfile)
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::Combine($script:Elsewhere, 'lib', 'core'))
        $script:PortableRoot = New-FakeRoot -Name 'fake-portable' -Portable
        $script:PlainRoot = New-FakeRoot -Name 'fake-plain'
        # Decoys in the working directory: a marker and a lib\core folder that must not be used.
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($script:Elsewhere, 'sweepr.portable'), 'x')

        $names = "'ConvertTo-SwPsLiteral','Get-SwColor','Get-SwIcon','Get-SwDefaultColors','Get-SwDefaultIcons','Initialize-SwVisualDefaults'," +
            "'Test-SwPortable','Resolve-SwDataPaths','Assert-SwDataWritable','Get-SwConfigPath','Get-SwCachePath','Test-SwAdmin'," +
            "'Get-SwFreeSpace','Get-SwWindowsVersion','Format-SwByteSize','Test-SwProtectedPath','Resolve-SwSafePath'," +
            "'Get-SwWhitelistState','Test-SwWhitelisted','Read-SwListBytes','ConvertFrom-SwListBytes','ConvertFrom-SwListEntry'"
        $reportScript = @"
'##RESULT##'
`$r = [ordered]@{}
`$r.Eap = [string]`$ErrorActionPreference
`$r.Strict = try { `$null = `$notDefinedAnywhere; 'off' } catch { 'on' }
`$r.ConfigPath = [string]`$script:Config.ConfigPath
`$r.CachePath = [string]`$script:Config.CachePath
`$r.WhitelistFile = [string]`$script:Config.WhitelistFile
`$r.ConfigKeys = @(`$script:Config.Keys | Sort-Object)
`$r.ColorCount = @(`$script:Colors.Keys).Count
`$r.IconCount = @(`$script:Icons.Keys).Count
`$r.Blue = [string]`$script:Colors.Blue
`$r.DefaultPatterns = @(`$script:DefaultWhitelistPatterns).Count
`$r.Missing = @(foreach (`$n in @($names)) { if (-not (Get-Command `$n -CommandType Function -ErrorAction SilentlyContinue)) { `$n } })
`$r | ConvertTo-Json -Compress
"@
        function script:Get-Tree([string[]]$Roots) {
            @($Roots | ForEach-Object { Get-ChildItem -LiteralPath $_ -Force -Recurse | ForEach-Object { $_.FullName } } | Sort-Object)
        }
        function script:Read-Result($Run) {
            $parts = $Run.Out -split '##RESULT##'
            [pscustomobject]@{
                ExitCode = $Run.ExitCode
                Output   = $parts[0]
                Err      = (Get-ChildStderr $Run.Err)
                Data     = if ($parts.Count -gt 1) { $parts[1].Trim() | ConvertFrom-Json } else { $null }
            }
        }

        $baseOf = { param($root) ConvertTo-TestLiteral ([System.IO.Path]::Combine($root, 'lib', 'core', 'base.ps1')) }
        $script:TreeBefore = Get-Tree @($script:FakeProfile, $script:PortableRoot, $script:PlainRoot)
        $portableBase = & $baseOf $script:PortableRoot
        $script:PortableRun = Read-Result (Invoke-ChildPowerShell -WorkingDirectory $script:Elsewhere -RemoveEnvironment @('SWEEPR_DATA_DIR') -Environment @{
                USERPROFILE = $script:FakeProfile; HOME = $script:FakeProfile
            } -Script @"
Set-StrictMode -Off
`$ErrorActionPreference = 'Continue'
. $portableBase
. $portableBase
$reportScript
"@)
        $plainBase = & $baseOf $script:PlainRoot
        $script:PlainRun = Read-Result (Invoke-ChildPowerShell -WorkingDirectory $script:Elsewhere -RemoveEnvironment @('SWEEPR_DATA_DIR') -Environment @{
                USERPROFILE = $script:FakeProfile; HOME = $script:FakeProfile; NO_COLOR = '1'
            } -Script @"
Set-StrictMode -Off
`$ErrorActionPreference = 'Continue'
. $plainBase
$reportScript
"@)
        $script:TreeAfter = Get-Tree @($script:FakeProfile, $script:PortableRoot, $script:PlainRoot)

        $emptyProfileBase = & $baseOf $script:PlainRoot
        $script:EmptyProfileRun = Read-Result (Invoke-ChildPowerShell -WorkingDirectory $script:Elsewhere -RemoveEnvironment @('SWEEPR_DATA_DIR') -Environment @{
                USERPROFILE = ''; HOME = $script:FakeProfile
            } -Script @"
. $emptyProfileBase
`$dotnet = [string][System.Environment]::GetFolderPath('UserProfile')
'##RESULT##'
`$r = [ordered]@{ ConfigPath = [string]`$script:Config.ConfigPath; CachePath = [string]`$script:Config.CachePath; DotNetProfile = `$dotnet; Threw = `$false }
if (-not `$dotnet) { `$r.Threw = try { Get-SwConfigPath | Out-Null; `$false } catch { `$true } }
`$r | ConvertTo-Json -Compress
"@)

        $script:MissingDrive = Get-UnusedDrive
        $missingHome = $script:MissingDrive + '\Users\Example'
        $script:MissingProfileRun = Read-Result (Invoke-ChildPowerShell -WorkingDirectory $script:Elsewhere -RemoveEnvironment @('SWEEPR_DATA_DIR') -Environment @{
                USERPROFILE = $missingHome; HOME = $script:FakeProfile; LOCALAPPDATA = ($missingHome + '\AppData\Local'); APPDATA = ($missingHome + '\AppData\Roaming')
            } -Script @"
Set-StrictMode -Off
`$ErrorActionPreference = 'Continue'
. $plainBase
$reportScript
"@)
        $script:MissingDriveRun = Read-Result (Invoke-ChildPowerShell -WorkingDirectory $script:Elsewhere -Environment @{
                USERPROFILE = $script:FakeProfile; HOME = $script:FakeProfile; SWEEPR_DATA_DIR = ($script:MissingDrive + '\x')
            } -Script @"
. $plainBase
'##RESULT##'
@{ ConfigPath = [string]`$script:Config.ConfigPath } | ConvertTo-Json -Compress
"@)
    }

    It 'G-1 does not touch tables a caller changed when the file is loaded a second time' {
        $script:Colors['Green'] = 'changed-green'
        $script:Config['ConfigPath'] = 'changed-config'
        $script:ProtectedPaths = @('changed-protected')
        $before = $script:SWEEPR_BASE_LOADED
        $before | Should -BeTrue
        . $script:BaseFile
        $script:Colors['Green'] | Should -BeExactly 'changed-green'
        $script:Config['ConfigPath'] | Should -BeExactly 'changed-config'
        @($script:ProtectedPaths) | Should -Be @('changed-protected')
    }

    It 'G-1 evaluates the data paths again from the environment after the marker is reset' {
        $dir = [System.IO.Path]::Combine($TestDrive, 'reload-data')
        $env:SWEEPR_DATA_DIR = $dir
        Import-Base
        Assert-Path $script:Config.ConfigPath ([System.IO.Path]::Combine($dir, 'config'))
        Assert-Path $script:Config.CachePath ([System.IO.Path]::Combine($dir, 'cache'))
    }

    It 'G-1 keeps the old configuration when the environment changed but the marker did not' {
        $old = $script:Config.ConfigPath
        $env:SWEEPR_DATA_DIR = [System.IO.Path]::Combine($TestDrive, 'not-picked-up')
        . $script:BaseFile
        $script:Config.ConfigPath | Should -BeExactly $old
    }

    It 'G-2 loads without output, without starting a process and without network or file writes' {
        Mock Start-Process { }
        Mock Invoke-WebRequest { }
        Mock Invoke-RestMethod { }
        Mock New-Item { }
        Mock Set-Content { }
        Mock Add-Content { }
        Mock Out-File { }
        $env:SWEEPR_DATA_DIR = [System.IO.Path]::Combine($TestDrive, 'load-quiet')
        $records = @(& { Import-Base } *>&1)
        $records.Count | Should -Be 0
        foreach ($name in 'Start-Process', 'Invoke-WebRequest', 'Invoke-RestMethod', 'New-Item', 'Set-Content', 'Add-Content', 'Out-File') {
            Should -Invoke -CommandName $name -Times 0 -Exactly
        }
        [System.IO.Directory]::Exists($env:SWEEPR_DATA_DIR) | Should -BeFalse
    }

    It 'G-2 creates no file or folder in a fresh process (loading twice, both data modes)' {
        $script:PortableRun.ExitCode | Should -Be 0
        $script:PlainRun.ExitCode | Should -Be 0
        $new = @($script:TreeAfter | Where-Object { $_ -notin $script:TreeBefore })
        # PowerShell itself may create its own folders in the profile; Sweepr must not create any.
        @($new | Where-Object { $_ -match '(?i)sweepr' }).Count | Should -Be 0
        [System.IO.Directory]::Exists([System.IO.Path]::Combine($script:PortableRoot, 'data')) | Should -BeFalse
        [System.IO.Directory]::Exists([System.IO.Path]::Combine($script:PlainRoot, 'data')) | Should -BeFalse
        [System.IO.Directory]::Exists([System.IO.Path]::Combine($script:FakeProfile, '.config', 'sweepr')) | Should -BeFalse
        [System.IO.Directory]::Exists([System.IO.Path]::Combine($script:FakeProfile, '.cache', 'sweepr')) | Should -BeFalse
    }

    It 'G-1 loading twice in one fresh scope gives no error and no output' {
        $script:PortableRun.Data | Should -Not -BeNullOrEmpty
        $script:PortableRun.Output.Trim() | Should -BeNullOrEmpty
        $script:PortableRun.Err.Trim() | Should -BeNullOrEmpty
    }

    It 'G-3 takes the program folder from the location of the loaded file (portable marker in that folder)' {
        $data = $script:PortableRun.Data
        Assert-Path $data.ConfigPath ([System.IO.Path]::Combine($script:PortableRoot, 'data', 'config'))
        Assert-Path $data.CachePath ([System.IO.Path]::Combine($script:PortableRoot, 'data', 'cache'))
        Assert-Path $data.WhitelistFile ([System.IO.Path]::Combine($script:PortableRoot, 'data', 'config', 'whitelist.txt'))
    }

    It 'G-3 ignores a marker in the working directory when the program folder has none' {
        $data = $script:PlainRun.Data
        Assert-Path $data.ConfigPath ([System.IO.Path]::Combine($script:FakeProfile, '.config', 'sweepr'))
        Assert-Path $data.CachePath ([System.IO.Path]::Combine($script:FakeProfile, '.cache', 'sweepr'))
    }

    It 'A-12 builds the configuration from the data paths: ConfigPath, CachePath and WhitelistFile only' {
        $data = $script:PlainRun.Data
        @($data.ConfigKeys) | Should -Be @('CachePath', 'ConfigPath', 'WhitelistFile')
        Assert-Path $data.WhitelistFile ([System.IO.Path]::Combine($script:FakeProfile, '.config', 'sweepr', 'whitelist.txt'))
    }

    It 'A-7 fills the colour and icon tables while loading (10 colours, 15 icons, Blue is an escape sequence)' {
        $data = $script:PlainRun.Data
        $data.ColorCount | Should -Be 10
        $data.IconCount | Should -Be 15
        $data.Blue | Should -BeExactly ($script:Esc + '[0;34m')
    }

    It 'G-6 leaves Stop and strict mode Latest in the loading scope' {
        $script:PlainRun.Data.Eap | Should -Be 'Stop'
        $script:PlainRun.Data.Strict | Should -Be 'on'
    }

    It 'A-8 keeps the ANSI colour values when NO_COLOR is set and the output is redirected' {
        $script:PlainRun.Data.Blue | Should -BeExactly ($script:Esc + '[0;34m')
    }

    It 'G-4 defines every new function at load' {
        @($script:PlainRun.Data.Missing) | Should -BeNullOrEmpty
    }

    It 'G-4 loads without error and without output when USERPROFILE is empty' {
        $script:EmptyProfileRun.ExitCode | Should -Be 0
        $script:EmptyProfileRun.Output.Trim() | Should -BeNullOrEmpty
        $script:EmptyProfileRun.Err.Trim() | Should -BeNullOrEmpty
        $script:EmptyProfileRun.Data | Should -Not -BeNullOrEmpty
    }

    It 'A-10 falls back to the .NET profile folder for an empty USERPROFILE, or stops in Get-SwConfigPath when that is empty too' {
        $data = $script:EmptyProfileRun.Data
        if ($data.DotNetProfile) {
            Assert-Path $data.ConfigPath ([System.IO.Path]::Combine($data.DotNetProfile, '.config', 'sweepr'))
            Assert-Path $data.CachePath ([System.IO.Path]::Combine($data.DotNetProfile, '.cache', 'sweepr'))
        }
        else {
            $data.Threw | Should -BeTrue
        }
    }

    It 'G-4 loads without error and without output when the profile and application data folders are on a drive that does not exist' {
        $run = $script:MissingProfileRun
        $run.ExitCode | Should -Be 0
        $run.Output.Trim() | Should -BeNullOrEmpty
        $run.Err.Trim() | Should -BeNullOrEmpty
        $run.Data | Should -Not -BeNullOrEmpty
        (Get-Cmp ([string]$run.Data.ConfigPath)).EndsWith('/.config/sweepr') | Should -BeTrue
        (Get-Cmp ([string]$run.Data.ConfigPath)).StartsWith((Get-Cmp ($script:MissingDrive + '\Users\Example'))) | Should -BeTrue
        $run.Data.DefaultPatterns | Should -Be 11
    }

    It 'G-4 loads without error when SWEEPR_DATA_DIR points to a drive that does not exist' {
        $script:MissingDriveRun.ExitCode | Should -Be 0
        $script:MissingDriveRun.Output.Trim() | Should -BeNullOrEmpty
        $script:MissingDriveRun.Data | Should -Not -BeNullOrEmpty
        (Get-Cmp ([string]$script:MissingDriveRun.Data.ConfigPath)).EndsWith('x/config') | Should -BeTrue
    }

    It 'G-4 [W] loads in a fresh Windows PowerShell 5.1 process and gives 15 icons without output' {
        $ps51 = Get-Command -Name 'powershell.exe' -ErrorAction Stop
        $base = ConvertTo-TestLiteral $script:BaseFile
        $run = Invoke-ChildPowerShell -Executable $ps51.Source -WorkingDirectory $TestDrive -Environment @{
            SWEEPR_DATA_DIR = [System.IO.Path]::Combine($TestDrive, 'ps51-data')
        } -Script @"
. $base
'##RESULT##'
`$names = @(`$script:Icons.Keys | Sort-Object)
(@(`$names).Count).ToString() + '|' + [int][char]`$script:Icons.Solid + '|' + [int][char]`$script:Icons.Admin + '|' + [int][char]`$script:Icons.Success + '|' + (Get-SwDefaultIcons).Count + '|' + `$PSVersionTable.PSVersion.Major
"@
        $run.ExitCode | Should -Be 0
        $parts = $run.Out -split '##RESULT##'
        $parts[0].Trim() | Should -BeNullOrEmpty
        $parts[1].Trim() | Should -Be '15|9679|9881|10003|15|5'
    }

    It 'G-5 contains no PowerShell 7 syntax and none of the WMI v1 cmdlets' {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:BaseFile, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        $only7 = @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'QuestionMark', 'AndAnd', 'OrOr')
        @($tokens | Where-Object { [string]$_.Kind -in $only7 }).Count | Should -Be 0
        @($tokens | Where-Object { [string]$_.Kind -eq 'Parameter' -and $_.ParameterName -eq 'Parallel' }).Count | Should -Be 0
        $wmi = @('Get-WmiObject', 'Invoke-WmiMethod', 'Set-WmiInstance', 'Remove-WmiObject', 'Register-WmiEvent')
        $commands = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
        @($commands | Where-Object { $_.GetCommandName() -in $wmi }).Count | Should -Be 0
    }

    It 'G-7 keeps the source ASCII or UTF-8 with BOM, and builds symbols from code points' {
        $bytes = [System.IO.File]::ReadAllBytes($script:BaseFile)
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count
        if ($nonAscii -gt 0) { $hasBom | Should -BeTrue }
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:BaseFile, [ref]$tokens, [ref]$errors)
        $literals = @($tokens | Where-Object { [string]$_.Kind -in @('StringLiteral', 'StringExpandable', 'HereStringLiteral', 'HereStringExpandable') })
        @($literals | Where-Object { $_.Text -match '[^\x00-\x7F]' }).Count | Should -Be 0
    }

    It 'G-8 reads the colour table, icon table and configuration at every call' {
        $script:Colors = @{ Green = 'first' }
        Get-SwColor -Name Green | Should -BeExactly 'first'
        $script:Colors = @{ Green = 'second' }
        Get-SwColor -Name Green | Should -BeExactly 'second'
        $script:Icons = @{ Solid = '1' }
        Get-SwIcon -Name Solid | Should -BeExactly '1'
        $script:Icons = @{ Solid = '2' }
        Get-SwIcon -Name Solid | Should -BeExactly '2'
        $one = [System.IO.Path]::Combine($TestDrive, 'g8-one')
        $two = [System.IO.Path]::Combine($TestDrive, 'g8-two')
        $script:Config.ConfigPath = $one
        Get-SwConfigPath | Should -BeExactly $one
        $script:Config.ConfigPath = $two
        Get-SwConfigPath | Should -BeExactly $two
    }
}

# ============================================================================
# A: literal quoting
# ============================================================================

Describe 'ConvertTo-SwPsLiteral' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
    }
    AfterEach { Stop-Case }
    It 'A-1 doubles an apostrophe: it''s becomes ''it''''s''' {
        ConvertTo-SwPsLiteral -Value 'it''s' | Should -BeExactly '''it''''s'''
    }

    It 'A-1 doubles <Name>' -ForEach $script:QuoteCases {
        $quote = [string][char]$CodePoint
        ConvertTo-SwPsLiteral -Value ('a' + $quote + 'b') | Should -BeExactly ('''a' + $quote + $quote + 'b''')
    }

    It 'A-1 wraps the value in apostrophes even when the value consists only of a typographic quote' {
        $quote = [string][char]0x2019
        ConvertTo-SwPsLiteral -Value $quote | Should -BeExactly ('''' + $quote + $quote + '''')
    }

    It 'A-1 doubles every quote character of a value and the parsed literal gives the value back' {
        $value = 'x' + [char]0x2019 + 'y' + [char]0x2018 + 'z'
        $literal = ConvertTo-SwPsLiteral -Value $value
        $literal | Should -BeExactly ('''x' + [char]0x2019 + [char]0x2019 + 'y' + [char]0x2018 + [char]0x2018 + 'z''')
        $read = Read-Literal $literal
        $read.IsString | Should -BeTrue
        $read.Value | Should -BeExactly $value
    }

    It 'A-1 turns $null into an empty literal' {
        ConvertTo-SwPsLiteral -Value $null | Should -BeExactly ''''''
        ConvertTo-SwPsLiteral $null | Should -BeExactly ''''''
    }

    It 'A-1 turns an empty string into an empty literal' {
        ConvertTo-SwPsLiteral -Value '' | Should -BeExactly ''''''
    }

    It 'A-1 leaves a path with spaces unchanged inside the quotes' {
        ConvertTo-SwPsLiteral -Value 'C:\Users\Example\My Files' | Should -BeExactly '''C:\Users\Example\My Files'''
    }

    It 'A-1 takes the value as the first positional parameter' {
        ConvertTo-SwPsLiteral 'abc' | Should -BeExactly '''abc'''
    }

    It 'A-1 keeps a double quote as it is' {
        ConvertTo-SwPsLiteral -Value 'a"b' | Should -BeExactly '''a"b'''
    }

    It 'A-1 keeps $(Get-Date) as text and does not evaluate it' {
        ConvertTo-SwPsLiteral -Value '$(Get-Date)' | Should -BeExactly '''$(Get-Date)'''
    }

    It 'A-1 keeps backtick, dollar sign, parentheses and brackets unchanged' {
        $value = 'a`b$c(d)[e]{f}'
        ConvertTo-SwPsLiteral -Value $value | Should -BeExactly ('''' + $value + '''')
    }

    It 'A-1 keeps line breaks unchanged' {
        ConvertTo-SwPsLiteral -Value "a`r`nb`nc" | Should -BeExactly ('''' + "a`r`nb`nc" + '''')
    }

    It 'A-1 never throws, also for a very long value' {
        $long = 'x' * 100000
        { ConvertTo-SwPsLiteral -Value $long } | Should -Not -Throw
        (ConvertTo-SwPsLiteral -Value $long).Length | Should -Be 100002
    }

    It 'S-A3 parses back to exactly one string equal to the input for: <Name>' -ForEach $script:NastyValues {
        $literal = ConvertTo-SwPsLiteral -Value $Value
        $read = Read-Literal $literal
        $read.Errors | Should -Be 0
        $read.Statements | Should -Be 1
        $read.IsString | Should -BeTrue
        $read.Quote | Should -Be 'SingleQuoted'
        $read.Value | Should -BeExactly $Value
    }
}

# ============================================================================
# A: colours and icons
# ============================================================================

Describe 'Colour and icon tables' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
    }
    AfterEach { Stop-Case }
    It 'A-2 holds exactly the ten colours' {
        $colors = Get-SwDefaultColors
        $colors | Should -BeOfType [hashtable]
        $colors.Count | Should -Be 10
    }

    It 'A-2 gives <Name> the value ESC<Code>' -ForEach $script:ColorCases {
        (Get-SwDefaultColors)[$Name] | Should -BeExactly ([string][char]27 + $Code)
    }

    It 'A-3 holds exactly the 15 icons' {
        $icons = Get-SwDefaultIcons
        $icons | Should -BeOfType [hashtable]
        $icons.Count | Should -Be 15
    }

    It 'A-3 gives <Name> one character with the expected code point' -ForEach $script:IconCases {
        $icon = (Get-SwDefaultIcons)[$Name]
        $icon | Should -BeOfType [string]
        $icon.Length | Should -Be 1
        [int][char]$icon | Should -Be $CodePoint
    }

    It 'A-4 returns a new colour table on every call' {
        $first = Get-SwDefaultColors
        $first['Green'] = 'changed'
        $first['Extra'] = 'added'
        $first.Remove('Red')
        $second = Get-SwDefaultColors
        $second.Count | Should -Be 10
        $second['Green'] | Should -BeExactly ([string][char]27 + '[0;32m')
        $second['Red'] | Should -BeExactly ([string][char]27 + '[0;31m')
        [object]::ReferenceEquals($first, $second) | Should -BeFalse
    }

    It 'A-4 returns a new icon table on every call' {
        $first = Get-SwDefaultIcons
        $first['Solid'] = '*'
        $first['Extra'] = 'added'
        $first.Remove('Admin')
        $second = Get-SwDefaultIcons
        $second.Count | Should -Be 15
        [int][char]$second['Solid'] | Should -Be 0x25CF
        [int][char]$second['Admin'] | Should -Be 0x2699
        [object]::ReferenceEquals($first, $second) | Should -BeFalse
    }

    It 'A-5 returns an entry of the table as it is, also when it differs from the default' {
        $script:Colors = @{ Cyan = 'custom-cyan' }
        Get-SwColor -Name Cyan | Should -BeExactly 'custom-cyan'
        $script:Icons = @{ Solid = '*' }
        Get-SwIcon -Name Solid | Should -BeExactly '*'
    }

    It 'A-5 returns the default for a missing entry and takes it into the table, leaving other entries alone' {
        $script:Icons = @{ Solid = '*' }
        $icon = Get-SwIcon -Name Error
        [int][char]$icon | Should -Be 0x263B
        [int][char]$script:Icons['Error'] | Should -Be 0x263B
        $script:Icons['Solid'] | Should -BeExactly '*'
        $script:Colors = @{ Cyan = 'custom-cyan' }
        Get-SwColor -Name Green | Should -BeExactly ([string][char]27 + '[0;32m')
        $script:Colors['Green'] | Should -BeExactly ([string][char]27 + '[0;32m')
        $script:Colors['Cyan'] | Should -BeExactly 'custom-cyan'
    }

    It 'A-5 returns $null for an unknown colour name without an error' {
        $result = Get-SwColor -Name 'Nope'
        $null -eq $result | Should -BeTrue
    }

    It 'A-5 returns $null for an unknown icon name without an error' {
        $result = Get-SwIcon -Name 'Nope'
        $null -eq $result | Should -BeTrue
    }

    It 'A-5 does not add an unknown name to the table' {
        $null = Get-SwColor -Name 'Nope'
        $null = Get-SwIcon -Name 'Nope'
        $script:Colors.ContainsKey('Nope') | Should -BeFalse
        $script:Icons.ContainsKey('Nope') | Should -BeFalse
    }

    It 'A-5 looks names up like a hashtable, without regard to case' {
        Get-SwColor -Name 'green' | Should -BeExactly ([string][char]27 + '[0;32m')
        Get-SwColor -Name 'GREEN' | Should -BeExactly ([string][char]27 + '[0;32m')
        [int][char](Get-SwIcon -Name 'solid') | Should -Be 0x25CF
    }

    It 'A-5 takes the name as the first positional parameter' {
        Get-SwColor 'Blue' | Should -BeExactly ([string][char]27 + '[0;34m')
        [int][char](Get-SwIcon 'Success') | Should -Be 0x2713
    }

    It 'A-5 rejects an empty name with a binding error' {
        { Get-SwColor -Name '' } | Should -Throw
        { Get-SwIcon -Name '' } | Should -Throw
        { Get-SwColor -Name $null } | Should -Throw
    }

    It 'A-6 fills missing keys of both tables and keeps existing values' {
        $script:Colors = @{ Cyan = 'custom' }
        $script:Icons = @{ Solid = '*' }
        Initialize-SwVisualDefaults
        $script:Colors['Cyan'] | Should -BeExactly 'custom'
        $script:Colors['Green'] | Should -BeExactly ([string][char]27 + '[0;32m')
        $script:Colors.Count | Should -Be 10
        $script:Icons['Solid'] | Should -BeExactly '*'
        [int][char]$script:Icons['Error'] | Should -Be 0x263B
        $script:Icons.Count | Should -Be 15
    }

    It 'A-6 creates tables that are missing or are not hashtables' {
        $script:Colors = 'not a table'
        $script:Icons = $null
        Initialize-SwVisualDefaults
        $script:Colors | Should -BeOfType [hashtable]
        $script:Icons | Should -BeOfType [hashtable]
        $script:Colors.Count | Should -Be 10
        $script:Icons.Count | Should -Be 15
        $script:Colors = @('a', 'b')
        $script:Icons = 42
        Initialize-SwVisualDefaults
        $script:Colors | Should -BeOfType [hashtable]
        $script:Icons | Should -BeOfType [hashtable]
    }

    It 'A-6 fills both tables when the variables were removed, under strict mode' {
        Remove-Variable -Name Colors -Scope Script
        Remove-Variable -Name Icons -Scope Script
        Set-StrictMode -Version Latest
        { Initialize-SwVisualDefaults } | Should -Not -Throw
        $script:Colors.Count | Should -Be 10
        $script:Icons.Count | Should -Be 15
    }

    It 'A-6 can be repeated and gives the same tables' {
        $script:Colors = @{ Cyan = 'custom' }
        Initialize-SwVisualDefaults
        $firstColors = $script:Colors.Clone()
        $firstIcons = $script:Icons.Clone()
        Initialize-SwVisualDefaults
        Initialize-SwVisualDefaults
        $script:Colors.Count | Should -Be $firstColors.Count
        $script:Icons.Count | Should -Be $firstIcons.Count
        foreach ($key in $firstColors.Keys) { $script:Colors[$key] | Should -BeExactly $firstColors[$key] }
        foreach ($key in $firstIcons.Keys) { $script:Icons[$key] | Should -BeExactly $firstIcons[$key] }
    }

    It 'A-6 writes nothing to the pipeline' {
        @(Initialize-SwVisualDefaults *>&1).Count | Should -Be 0
    }

    It 'A-7 has the default tables filled right after loading, without Initialize-SwVisualDefaults' {
        $esc = [string][char]27
        $script:Colors['Blue'] | Should -BeExactly ($esc + '[0;34m')
        $script:Colors.Count | Should -BeGreaterOrEqual 10
        $script:Icons.Count | Should -BeGreaterOrEqual 15
    }

    It 'A-8 keeps ANSI colours when NO_COLOR is set' {
        $env:NO_COLOR = '1'
        (Get-SwDefaultColors)['Green'] | Should -BeExactly ([string][char]27 + '[0;32m')
        Get-SwColor -Name Green | Should -BeExactly ([string][char]27 + '[0;32m')
        Import-Base
        $script:Colors['Green'] | Should -BeExactly ([string][char]27 + '[0;32m')
    }
}

# ============================================================================
# A: portable marker and data paths
# ============================================================================

Describe 'Test-SwPortable' {
    AfterEach { Stop-Case }
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        $script:Root = [System.IO.Path]::Combine($TestDrive, ('portable-' + [guid]::NewGuid().ToString('N')))
        [void][System.IO.Directory]::CreateDirectory($script:Root)
    }

    It 'A-9 is true when a file sweepr.portable is in the folder' {
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($script:Root, 'sweepr.portable'), '')
        $result = Test-SwPortable -RootDir $script:Root
        $result | Should -BeOfType [bool]
        $result | Should -BeTrue
    }

    It 'A-9 does not care about the content of the marker file' {
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($script:Root, 'sweepr.portable'), 'anything at all')
        Test-SwPortable -RootDir $script:Root | Should -BeTrue
    }

    It 'A-9 is false when the marker is a folder' {
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::Combine($script:Root, 'sweepr.portable'))
        $result = Test-SwPortable -RootDir $script:Root
        $result | Should -BeOfType [bool]
        $result | Should -BeFalse
    }

    It 'A-9 is false without a marker' {
        Test-SwPortable -RootDir $script:Root | Should -BeFalse
    }

    It 'A-9 is false for a folder that does not exist' {
        Test-SwPortable -RootDir ([System.IO.Path]::Combine($script:Root, 'missing')) | Should -BeFalse
    }

    It 'A-9 is false for an empty, blank or null root' {
        Test-SwPortable -RootDir '' | Should -BeFalse
        Test-SwPortable -RootDir '   ' | Should -BeFalse
        Test-SwPortable -RootDir $null | Should -BeFalse
    }

    It 'A-9 never throws for a path the system cannot resolve' {
        { Test-SwPortable -RootDir ("bad" + [char]0 + "path") } | Should -Not -Throw
        Test-SwPortable -RootDir ("bad" + [char]0 + "path") | Should -BeFalse
    }

    It 'A-9 reads folder names with brackets literally' {
        $bracket = [System.IO.Path]::Combine($script:Root, '[r]')
        $plain = [System.IO.Path]::Combine($script:Root, 'r')
        [void][System.IO.Directory]::CreateDirectory($bracket)
        [void][System.IO.Directory]::CreateDirectory($plain)
        Test-SwPortable -RootDir $bracket | Should -BeFalse
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($plain, 'sweepr.portable'), '')
        Test-SwPortable -RootDir $bracket | Should -BeFalse
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($bracket, 'sweepr.portable'), '')
        Test-SwPortable -RootDir $bracket | Should -BeTrue
    }

    It 'A-9 [W] is false without an error for a folder on a drive that does not exist' {
        $drive = Get-UnusedDrive
        $result = Test-SwPortable -RootDir ($drive + '\x')
        $result | Should -BeFalse
    }
}

Describe 'Resolve-SwDataPaths' {
    AfterEach { Stop-Case }
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        $script:Program = [System.IO.Path]::Combine($TestDrive, ('program-' + [guid]::NewGuid().ToString('N')))
        $script:FakeHome = [System.IO.Path]::Combine($TestDrive, ('home-' + [guid]::NewGuid().ToString('N')))
        [void][System.IO.Directory]::CreateDirectory($script:Program)
        [void][System.IO.Directory]::CreateDirectory($script:FakeHome)
        $env:USERPROFILE = $script:FakeHome
        Remove-Item Env:SWEEPR_DATA_DIR -ErrorAction SilentlyContinue
    }

    It 'A-10 returns a hashtable with Mode, ConfigPath and CachePath' {
        $paths = Resolve-SwDataPaths -RootDir $script:Program
        $paths | Should -BeOfType [hashtable]
        foreach ($key in 'Mode', 'ConfigPath', 'CachePath') { $paths.ContainsKey($key) | Should -BeTrue }
    }

    It 'A-10 uses the profile when there is neither an override nor a marker' {
        $paths = Resolve-SwDataPaths -RootDir $script:Program
        $paths.Mode | Should -BeExactly 'Profile'
        Assert-Path $paths.ConfigPath ([System.IO.Path]::Combine($script:FakeHome, '.config', 'sweepr'))
        Assert-Path $paths.CachePath ([System.IO.Path]::Combine($script:FakeHome, '.cache', 'sweepr'))
    }

    It 'A-10 uses the program folder data folder when the marker file exists' {
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($script:Program, 'sweepr.portable'), '')
        $paths = Resolve-SwDataPaths -RootDir $script:Program
        $paths.Mode | Should -BeExactly 'Portable'
        Assert-Path $paths.ConfigPath ([System.IO.Path]::Combine($script:Program, 'data', 'config'))
        Assert-Path $paths.CachePath ([System.IO.Path]::Combine($script:Program, 'data', 'cache'))
    }

    It 'A-10 uses SWEEPR_DATA_DIR before the marker and the profile' {
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($script:Program, 'sweepr.portable'), '')
        $dir = [System.IO.Path]::Combine($TestDrive, 'override-wins')
        $env:SWEEPR_DATA_DIR = $dir
        $paths = Resolve-SwDataPaths -RootDir $script:Program
        $paths.Mode | Should -BeExactly 'Override'
        Assert-Path $paths.ConfigPath ([System.IO.Path]::Combine($dir, 'config'))
        Assert-Path $paths.CachePath ([System.IO.Path]::Combine($dir, 'cache'))
    }

    It 'A-10 ignores blanks around SWEEPR_DATA_DIR' {
        $dir = [System.IO.Path]::Combine($TestDrive, 'padded-data')
        $env:SWEEPR_DATA_DIR = '   ' + $dir + '  '
        $paths = Resolve-SwDataPaths -RootDir $script:Program
        $paths.Mode | Should -BeExactly 'Override'
        Assert-Path $paths.ConfigPath ([System.IO.Path]::Combine($dir, 'config'))
    }

    It 'A-10 treats <Name> as not set' -ForEach @(
        @{ Name = 'an empty SWEEPR_DATA_DIR'; Value = '' }
        @{ Name = 'a blank SWEEPR_DATA_DIR'; Value = '   ' }
    ) {
        $env:SWEEPR_DATA_DIR = $Value
        (Resolve-SwDataPaths -RootDir $script:Program).Mode | Should -BeExactly 'Profile'
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($script:Program, 'sweepr.portable'), '')
        (Resolve-SwDataPaths -RootDir $script:Program).Mode | Should -BeExactly 'Portable'
    }

    It 'A-10 makes a relative SWEEPR_DATA_DIR absolute against the PowerShell location' {
        $work = [System.IO.Path]::Combine($TestDrive, 'work')
        [void][System.IO.Directory]::CreateDirectory($work)
        $env:SWEEPR_DATA_DIR = 'data'
        Push-Location -LiteralPath $work
        try { $paths = Resolve-SwDataPaths -RootDir $script:Program }
        finally { Pop-Location }
        $paths.Mode | Should -BeExactly 'Override'
        Assert-Path $paths.ConfigPath ([System.IO.Path]::Combine($work, 'data', 'config'))
        Assert-Path $paths.CachePath ([System.IO.Path]::Combine($work, 'data', 'cache'))
    }

    It 'A-10 resolves dot segments of SWEEPR_DATA_DIR' {
        $base = [System.IO.Path]::Combine($TestDrive, 'dots')
        $env:SWEEPR_DATA_DIR = $base + [System.IO.Path]::DirectorySeparatorChar + 'a' + [System.IO.Path]::DirectorySeparatorChar + '..' + [System.IO.Path]::DirectorySeparatorChar + 'b'
        $paths = Resolve-SwDataPaths -RootDir $script:Program
        Assert-Path $paths.ConfigPath ([System.IO.Path]::Combine($base, 'b', 'config'))
        Assert-Path $paths.CachePath ([System.IO.Path]::Combine($base, 'b', 'cache'))
    }

    It 'A-10 gives Mode as exactly one of the strings Override, Portable, Profile' {
        $modes = @()
        $modes += (Resolve-SwDataPaths -RootDir $script:Program).Mode
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($script:Program, 'sweepr.portable'), '')
        $modes += (Resolve-SwDataPaths -RootDir $script:Program).Mode
        $env:SWEEPR_DATA_DIR = [System.IO.Path]::Combine($TestDrive, 'modes')
        $modes += (Resolve-SwDataPaths -RootDir $script:Program).Mode
        $modes | Should -BeExactly @('Profile', 'Portable', 'Override')
    }

    It 'A-10 creates no folder, even for a data folder that does not exist yet' {
        $dir = [System.IO.Path]::Combine($TestDrive, 'not-created', 'deep')
        $env:SWEEPR_DATA_DIR = $dir
        $null = Resolve-SwDataPaths -RootDir $script:Program
        [System.IO.Directory]::Exists([System.IO.Path]::Combine($TestDrive, 'not-created')) | Should -BeFalse
        Remove-Item Env:SWEEPR_DATA_DIR
        $null = Resolve-SwDataPaths -RootDir $script:Program
        [System.IO.Directory]::Exists([System.IO.Path]::Combine($script:FakeHome, '.config')) | Should -BeFalse
        [System.IO.Directory]::Exists([System.IO.Path]::Combine($script:FakeHome, '.cache')) | Should -BeFalse
        [System.IO.Directory]::Exists([System.IO.Path]::Combine($script:Program, 'data')) | Should -BeFalse
    }

    It 'A-10 [W] gives Override and the paths as text for a drive that does not exist, without an error' {
        $drive = Get-UnusedDrive
        $env:SWEEPR_DATA_DIR = $drive + '\x'
        $paths = Resolve-SwDataPaths -RootDir $script:Program
        $paths.Mode | Should -BeExactly 'Override'
        $paths.ConfigPath | Should -BeExactly ($drive + '\x\config')
        $paths.CachePath | Should -BeExactly ($drive + '\x\cache')
    }

    It 'A-10 [W] trims and normalizes a drive-letter SWEEPR_DATA_DIR' {
        $env:SWEEPR_DATA_DIR = '  D:\Daten\Sweepr  '
        $paths = Resolve-SwDataPaths -RootDir $script:Program
        $paths.Mode | Should -BeExactly 'Override'
        $paths.ConfigPath | Should -BeExactly 'D:\Daten\Sweepr\config'
        $env:SWEEPR_DATA_DIR = 'D:\a\..\b'
        (Resolve-SwDataPaths -RootDir $script:Program).ConfigPath | Should -BeExactly 'D:\b\config'
    }

    It 'A-11 gives Portable the same paths as Override with SWEEPR_DATA_DIR set to the data folder of the program folder' {
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($script:Program, 'sweepr.portable'), '')
        $portable = Resolve-SwDataPaths -RootDir $script:Program
        $portable.Mode | Should -BeExactly 'Portable'
        $env:SWEEPR_DATA_DIR = [System.IO.Path]::Combine($script:Program, 'data')
        $override = Resolve-SwDataPaths -RootDir $script:Program
        $override.Mode | Should -BeExactly 'Override'
        Assert-Path $override.ConfigPath $portable.ConfigPath
        Assert-Path $override.CachePath $portable.CachePath
    }

    It 'S-A1 never gives the profile when an override or a marker is present' {
        $env:SWEEPR_DATA_DIR = [System.IO.Path]::Combine($TestDrive, 'no-fallback')
        $paths = Resolve-SwDataPaths -RootDir $script:Program
        $paths.Mode | Should -Not -BeExactly 'Profile'
        (Get-Cmp $paths.ConfigPath).StartsWith((Get-Cmp $script:FakeHome) + '/') | Should -BeFalse
        Remove-Item Env:SWEEPR_DATA_DIR
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($script:Program, 'sweepr.portable'), '')
        $paths = Resolve-SwDataPaths -RootDir $script:Program
        $paths.Mode | Should -Not -BeExactly 'Profile'
        (Get-Cmp $paths.ConfigPath).StartsWith((Get-Cmp $script:FakeHome) + '/') | Should -BeFalse
    }
}

Describe 'Configuration built at load' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
    }
    AfterEach { Stop-Case }
    It 'A-12 sets ConfigPath, CachePath and WhitelistFile from the profile and has no other key' {
        $home1 = [System.IO.Path]::Combine($TestDrive, 'cfg-profile')
        $env:USERPROFILE = $home1
        Remove-Item Env:SWEEPR_DATA_DIR -ErrorAction SilentlyContinue
        Import-Base
        Assert-Path $script:Config.ConfigPath ([System.IO.Path]::Combine($home1, '.config', 'sweepr'))
        Assert-Path $script:Config.CachePath ([System.IO.Path]::Combine($home1, '.cache', 'sweepr'))
        Assert-Path $script:Config.WhitelistFile ([System.IO.Path]::Combine($home1, '.config', 'sweepr', 'whitelist.txt'))
        @($script:Config.Keys | Sort-Object) | Should -Be @('CachePath', 'ConfigPath', 'WhitelistFile')
    }

    It 'A-12 puts WhitelistFile under the config folder of the override when SWEEPR_DATA_DIR is set' {
        $dir = [System.IO.Path]::Combine($TestDrive, 'cfg-override')
        $env:SWEEPR_DATA_DIR = $dir
        Import-Base
        Assert-Path $script:Config.ConfigPath ([System.IO.Path]::Combine($dir, 'config'))
        Assert-Path $script:Config.CachePath ([System.IO.Path]::Combine($dir, 'cache'))
        Assert-Path $script:Config.WhitelistFile ([System.IO.Path]::Combine($dir, 'config', 'whitelist.txt'))
    }

    It 'A-12 creates no folder while loading' {
        $dir = [System.IO.Path]::Combine($TestDrive, 'cfg-not-created')
        $env:SWEEPR_DATA_DIR = $dir
        Import-Base
        [System.IO.Directory]::Exists($dir) | Should -BeFalse
    }
}

Describe 'Get-SwConfigPath and Get-SwCachePath' {
    AfterEach { Stop-Case }
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        $script:Data = [System.IO.Path]::Combine($TestDrive, ('data-' + [guid]::NewGuid().ToString('N')))
    }

    It 'A-14 returns <Key> as the value of the configuration and creates the folder with its parents' -ForEach @(
        @{ Key = 'ConfigPath'; Fn = 'Get-SwConfigPath' }
        @{ Key = 'CachePath'; Fn = 'Get-SwCachePath' }
    ) {
        $target = [System.IO.Path]::Combine($script:Data, 'level1', 'level2', $Key)
        $script:Config[$Key] = $target
        $result = & $Fn
        $result | Should -BeOfType [string]
        $result | Should -BeExactly $target
        [System.IO.Directory]::Exists($target) | Should -BeTrue
    }

    It 'A-14 writes nothing but the path to the pipeline for <Fn>' -ForEach @(
        @{ Key = 'ConfigPath'; Fn = 'Get-SwConfigPath' }
        @{ Key = 'CachePath'; Fn = 'Get-SwCachePath' }
    ) {
        $script:Config[$Key] = [System.IO.Path]::Combine($script:Data, $Key)
        $records = @(& $Fn *>&1)
        $records.Count | Should -Be 1
        $records[0] | Should -BeExactly $script:Config[$Key]
    }

    It 'A-14 leaves an existing folder and its content unchanged and gives the same value twice' {
        $target = [System.IO.Path]::Combine($script:Data, 'existing')
        [void][System.IO.Directory]::CreateDirectory($target)
        $file = [System.IO.Path]::Combine($target, 'whitelist.txt')
        [System.IO.File]::WriteAllText($file, 'keep me')
        $script:Config.ConfigPath = $target
        $first = Get-SwConfigPath
        $second = Get-SwConfigPath
        $second | Should -BeExactly $first
        [System.IO.File]::ReadAllText($file) | Should -BeExactly 'keep me'
        @(Get-ChildItem -LiteralPath $target -Force).Count | Should -Be 1
    }

    It 'A-14 treats brackets in the folder name literally and leaves a similar sibling alone' {
        $parent = [System.IO.Path]::Combine($script:Data, 'Apps')
        $sibling = [System.IO.Path]::Combine($script:Data, 'Apps x', 'config')
        [void][System.IO.Directory]::CreateDirectory($sibling)
        $marker = [System.IO.Path]::Combine($sibling, 'marker.txt')
        [System.IO.File]::WriteAllText($marker, 'untouched')
        $target = [System.IO.Path]::Combine($script:Data, 'Apps [x]', 'config')
        $script:Config.ConfigPath = $target
        $result = Get-SwConfigPath
        $result | Should -BeExactly $target
        [System.IO.Directory]::Exists($target) | Should -BeTrue
        @(Get-ChildItem -LiteralPath $sibling -Force).Count | Should -Be 1
        [System.IO.File]::ReadAllText($marker) | Should -BeExactly 'untouched'
        Test-Path -LiteralPath $parent | Should -BeFalse
    }

    It 'A-13 uses a replaced ConfigPath and CachePath at the next call' {
        $one = [System.IO.Path]::Combine($script:Data, 'one')
        $two = [System.IO.Path]::Combine($script:Data, 'two')
        $script:Config.ConfigPath = $one
        Get-SwConfigPath | Should -BeExactly $one
        $script:Config.ConfigPath = $two
        Get-SwConfigPath | Should -BeExactly $two
        $script:Config.CachePath = $one
        Get-SwCachePath | Should -BeExactly $one
        $script:Config.CachePath = $two
        Get-SwCachePath | Should -BeExactly $two
    }

    It 'A-14 throws a terminating error when the folder cannot be created, whatever ErrorActionPreference says (<Fn>)' -ForEach @(
        @{ Key = 'ConfigPath'; Fn = 'Get-SwConfigPath' }
        @{ Key = 'CachePath'; Fn = 'Get-SwCachePath' }
    ) {
        $blocker = [System.IO.Path]::Combine($script:Data, 'blocker')
        [void][System.IO.Directory]::CreateDirectory($script:Data)
        [System.IO.File]::WriteAllText($blocker, 'a file where a folder is needed')
        $script:Config[$Key] = [System.IO.Path]::Combine($blocker, 'config')
        $ErrorActionPreference = 'Continue'
        { & $Fn } | Should -Throw
        $ErrorActionPreference = 'SilentlyContinue'
        { & $Fn } | Should -Throw
    }

    It 'A-14 throws instead of creating anything when the configured folder is empty' {
        $script:Config.ConfigPath = ''
        { Get-SwConfigPath } | Should -Throw
        $script:Config.CachePath = ''
        { Get-SwCachePath } | Should -Throw
    }
}

Describe 'Assert-SwDataWritable' {
    AfterEach { Stop-Case }
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
        $script:Parent = [System.IO.Path]::Combine($TestDrive, ('assert-' + [guid]::NewGuid().ToString('N')))
        [void][System.IO.Directory]::CreateDirectory($script:Parent)
        $script:FakeHome = [System.IO.Path]::Combine($TestDrive, ('assert-home-' + [guid]::NewGuid().ToString('N')))
        [void][System.IO.Directory]::CreateDirectory($script:FakeHome)
        $env:USERPROFILE = $script:FakeHome
        $script:Message = { param($p) "Sweepr data folder is not writable: $p. Sweepr does not fall back to your user profile." }
    }

    It 'A-15 creates a missing folder with its parents and leaves it empty' {
        $path = [System.IO.Path]::Combine($script:Parent, 'a', 'b', 'config')
        Assert-SwDataWritable -Path $path
        [System.IO.Directory]::Exists($path) | Should -BeTrue
        @(Get-ChildItem -LiteralPath $path -Force).Count | Should -Be 0
    }

    It 'A-15 accepts an existing folder and leaves its content unchanged' {
        $path = [System.IO.Path]::Combine($script:Parent, 'existing')
        [void][System.IO.Directory]::CreateDirectory($path)
        $file = [System.IO.Path]::Combine($path, 'whitelist.txt')
        [System.IO.File]::WriteAllText($file, 'keep me')
        { Assert-SwDataWritable -Path $path } | Should -Not -Throw
        @(Get-ChildItem -LiteralPath $path -Force | ForEach-Object { $_.Name }) | Should -Be @('whitelist.txt')
        [System.IO.File]::ReadAllText($file) | Should -BeExactly 'keep me'
    }

    It 'A-15 leaves no probe file behind' {
        $path = [System.IO.Path]::Combine($script:Parent, 'probe-gone')
        Assert-SwDataWritable -Path $path
        Assert-SwDataWritable -Path $path
        @(Get-ChildItem -LiteralPath $path -Force | Where-Object { $_.Name -like '.write-test-*' }).Count | Should -Be 0
    }

    It 'S-A4 deletes no file it did not create, also not one that looks like a probe file' {
        $path = [System.IO.Path]::Combine($script:Parent, 'lookalikes')
        [void][System.IO.Directory]::CreateDirectory($path)
        $names = @('.write-test-', '.write-test-0123456789abcdef0123456789abcdef', '.write-test-other', 'keep.txt')
        foreach ($name in $names) { [System.IO.File]::WriteAllText([System.IO.Path]::Combine($path, $name), 'precious') }
        Assert-SwDataWritable -Path $path
        @(Get-ChildItem -LiteralPath $path -Force | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @($names | Sort-Object)
        foreach ($name in $names) { [System.IO.File]::ReadAllText([System.IO.Path]::Combine($path, $name)) | Should -BeExactly 'precious' }
    }

    It 'A-15 writes nothing to the pipeline' {
        @(Assert-SwDataWritable -Path ([System.IO.Path]::Combine($script:Parent, 'quiet')) *>&1).Count | Should -Be 0
    }

    It 'A-15 stops with the exact message when a file blocks a parent folder, and creates nothing in the profile' {
        $blocker = [System.IO.Path]::Combine($script:Parent, 'blocker')
        [System.IO.File]::WriteAllText($blocker, 'a file')
        $path = $blocker + [System.IO.Path]::DirectorySeparatorChar + 'config'
        $caught = $null
        try { Assert-SwDataWritable -Path $path }
        catch { $caught = $_ }
        $null -ne $caught | Should -BeTrue
        $caught.Exception.Message | Should -BeExactly (& $script:Message $path)
        @(Get-ChildItem -LiteralPath $script:FakeHome -Force).Count | Should -Be 0
        [System.IO.File]::ReadAllText($blocker) | Should -BeExactly 'a file'
    }

    It 'A-15 repeats the path unchanged in the message, also with brackets and spaces' {
        $blocker = [System.IO.Path]::Combine($script:Parent, 'block er [x]')
        [System.IO.File]::WriteAllText($blocker, 'a file')
        $path = $blocker + [System.IO.Path]::DirectorySeparatorChar + 'config'
        $caught = $null
        try { Assert-SwDataWritable -Path $path } catch { $caught = $_ }
        $null -ne $caught | Should -BeTrue
        $caught.Exception.Message | Should -BeExactly (& $script:Message $path)
    }

    It 'S-A1 aborts for an unwritable override folder and does not fall back to the profile' {
        $blocker = [System.IO.Path]::Combine($script:Parent, 'override-blocker')
        [System.IO.File]::WriteAllText($blocker, 'a file')
        $env:SWEEPR_DATA_DIR = $blocker
        $paths = Resolve-SwDataPaths -RootDir $script:Parent
        $paths.Mode | Should -BeExactly 'Override'
        { Assert-SwDataWritable -Path $paths.ConfigPath } | Should -Throw
        @(Get-ChildItem -LiteralPath $script:FakeHome -Force).Count | Should -Be 0
        (Resolve-SwDataPaths -RootDir $script:Parent).Mode | Should -BeExactly 'Override'
    }

    It 'A-15 [W] stops with the message for a folder on a drive that does not exist' {
        $drive = Get-UnusedDrive
        $path = $drive + '\x\config'
        $caught = $null
        $oldDirectory = [System.Environment]::CurrentDirectory
        Push-Location -LiteralPath $script:Parent
        try {
            [System.Environment]::CurrentDirectory = $script:Parent
            Assert-SwDataWritable -Path $path
        }
        catch { $caught = $_ }
        finally {
            [System.Environment]::CurrentDirectory = $oldDirectory
            Pop-Location
        }
        $null -ne $caught | Should -BeTrue
        $caught.Exception.Message | Should -BeExactly (& $script:Message $path)
    }

    It 'A-15 [W] stops with the message when the ACL denies writing' {
        $path = [System.IO.Path]::Combine($script:Parent, 'acl-denied')
        [void][System.IO.Directory]::CreateDirectory($path)
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'CreateFiles, AppendData, WriteData', 'ContainerInherit, ObjectInherit', 'None', 'Deny')
        $acl = Get-Acl -LiteralPath $path
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $path -AclObject $acl
        $caught = $null
        try { Assert-SwDataWritable -Path $path } catch { $caught = $_ }
        finally {
            $acl = Get-Acl -LiteralPath $path
            [void]$acl.RemoveAccessRule($rule)
            Set-Acl -LiteralPath $path -AclObject $acl
        }
        $null -ne $caught | Should -BeTrue
        $caught.Exception.Message | Should -BeExactly (& $script:Message $path)
    }
}

# ============================================================================
# A: system information
# ============================================================================

Describe 'Test-SwAdmin' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
    }
    AfterEach { Stop-Case }
    It 'A-16 [W] returns a bool that matches the elevation of the current process' {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        $expected = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        $result = Test-SwAdmin
        $result | Should -BeOfType [bool]
        $result | Should -Be $expected
    }

    It 'A-16 [W] returns the same value on every call' {
        (Test-SwAdmin) | Should -Be (Test-SwAdmin)
    }
}

Describe 'Get-SwFreeSpace' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
    }
    AfterEach { Stop-Case }
    It 'A-17 returns exactly Unknown for <Name>' -ForEach @(
        @{ Name = 'a drive letter that does not exist'; Drive = 'ZZ:' }
        @{ Name = 'an empty value'; Drive = '' }
        @{ Name = 'a blank value'; Drive = '   ' }
        @{ Name = 'a quote injection'; Drive = "C:' OR '1'='1" }
        @{ Name = 'a double quote injection'; Drive = 'C:" ; calc ; "' }
        @{ Name = 'a wildcard'; Drive = '*:' }
        @{ Name = 'a digit'; Drive = '1:' }
        @{ Name = 'two letters'; Drive = 'AB:' }
        @{ Name = 'a folder path'; Drive = 'C:\Windows' }
        @{ Name = 'a UNC path'; Drive = '\\server\share' }
        @{ Name = 'a path with a line break'; Drive = "C:`nD:" }
    ) {
        $result = Get-SwFreeSpace -Drive $Drive
        $result | Should -BeOfType [string]
        $result | Should -BeExactly 'Unknown'
    }

    It 'A-17 returns Unknown for a drive letter that no drive of this host uses, in every accepted form' {
        $drive = Get-UnusedDrive
        $letter = $drive.Substring(0, 1)
        Get-SwFreeSpace -Drive $drive | Should -BeExactly 'Unknown'
        Get-SwFreeSpace -Drive $letter | Should -BeExactly 'Unknown'
        Get-SwFreeSpace -Drive ($drive + '\') | Should -BeExactly 'Unknown'
    }

    It 'A-17 never throws, whatever ErrorActionPreference says' {
        $ErrorActionPreference = 'Stop'
        { Get-SwFreeSpace -Drive 'ZZ:' } | Should -Not -Throw
        { Get-SwFreeSpace -Drive $null } | Should -Not -Throw
        { Get-SwFreeSpace -Drive "x'; Remove-Item *; '" } | Should -Not -Throw
    }

    It 'A-17 returns Unknown by default when SystemDrive is empty or not a drive' {
        $env:SystemDrive = ''
        Get-SwFreeSpace | Should -BeExactly 'Unknown'
        $env:SystemDrive = 'ZZ:'
        Get-SwFreeSpace | Should -BeExactly 'Unknown'
    }

    It 'A-17 [W] gives the free space of <Name> as number and unit in the size format' -ForEach @(
        @{ Name = 'the default drive'; Form = 'default' }
        @{ Name = 'the drive written as letter and colon'; Form = 'colon' }
        @{ Name = 'the drive written as letter only'; Form = 'letter' }
        @{ Name = 'the drive written as letter, colon and backslash'; Form = 'root' }
        @{ Name = 'a lower-case letter'; Form = 'lower' }
    ) {
        $systemDrive = $env:SystemDrive
        $systemDrive | Should -Not -BeNullOrEmpty
        $letter = $systemDrive.Substring(0, 1)
        Invoke-WithCulture 'en-US' {
            switch ($Form) {
                'default' { $text = Get-SwFreeSpace }
                'colon' { $text = Get-SwFreeSpace -Drive ($letter + ':') }
                'letter' { $text = Get-SwFreeSpace -Drive $letter }
                'root' { $text = Get-SwFreeSpace -Drive ($letter + ':\') }
                'lower' { $text = Get-SwFreeSpace -Drive ($letter.ToLowerInvariant() + ':') }
            }
            $text | Should -BeOfType [string]
            $text | Should -Match '^[\d,]+(\.\d+)?(B|KB|MB|GB|TB)$'
        }
    }
}

Describe 'Get-SwWindowsVersion' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
    }
    AfterEach { Stop-Case }
    It 'A-18 returns a hashtable with Name, Version, Build and Arch, each a non-empty string' {
        $info = Get-SwWindowsVersion
        $info | Should -BeOfType [hashtable]
        foreach ($key in 'Name', 'Version', 'Build', 'Arch') {
            $info.ContainsKey($key) | Should -BeTrue
            $info[$key] | Should -BeOfType [string]
            $info[$key] | Should -Not -BeNullOrEmpty
        }
    }

    It 'A-18 never throws' {
        $ErrorActionPreference = 'Stop'
        { Get-SwWindowsVersion } | Should -Not -Throw
    }

    It 'A-18 takes Arch from PROCESSOR_ARCHITECTURE when the query source is not available (hosts without Windows)' {
        if ($script:OnWindows) { Set-ItResult -Skipped -Because 'Windows reads the architecture from the operating system object'; return }
        $env:PROCESSOR_ARCHITECTURE = 'ARM64'
        (Get-SwWindowsVersion).Arch | Should -BeExactly 'ARM64'
        Remove-Item Env:PROCESSOR_ARCHITECTURE
        (Get-SwWindowsVersion).Arch | Should -BeExactly 'Unknown'
    }

    It 'A-18 [W] names Windows and gives a numeric build' {
        $info = Get-SwWindowsVersion
        $info.Name | Should -Match 'Windows'
        $info.Build | Should -Match '^\d+$'
        $info.Version | Should -Match '^(10\.0\.\d+|\d{2}H\d)$'
    }
}

# ============================================================================
# A: size format
# ============================================================================

Describe 'Format-SwByteSize' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
    }
    AfterEach { Stop-Case }
    It 'A-19 formats <Bytes> as <Expected> (culture en-US)' -ForEach $script:SizeCases {
        Invoke-WithCulture 'en-US' {
            $text = Format-SwByteSize -Bytes $Bytes
            $text | Should -BeOfType [string]
            $text | Should -BeExactly $Expected
        }
    }

    It 'A-19 gives the same text in the invariant culture' {
        $values = @(1099511627776, 1073741824, 1572864, 1536, 1048575)
        $reference = Invoke-WithCulture 'en-US' { $values | ForEach-Object { Format-SwByteSize -Bytes $_ } }
        $thread = [System.Threading.Thread]::CurrentThread
        $old = $thread.CurrentCulture
        try {
            $thread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
            $invariant = $values | ForEach-Object { Format-SwByteSize -Bytes $_ }
        }
        finally { $thread.CurrentCulture = $old }
        (@($invariant) -join '|') | Should -BeExactly (@($reference) -join '|')
    }

    It 'A-19 does not write 1024 as 1.0KB or as 1 KB' {
        Invoke-WithCulture 'en-US' {
            Format-SwByteSize -Bytes 1024 | Should -Not -BeExactly '1.0KB'
            Format-SwByteSize -Bytes 1024 | Should -Not -BeExactly '1 KB'
        }
    }

    It 'A-19 puts no space between the number and the unit' {
        Invoke-WithCulture 'en-US' {
            foreach ($value in 0, 1500, 5000000, 7000000000, 3000000000000) { Format-SwByteSize -Bytes $value | Should -Match '^[\d,.]+[A-Z]+$' }
        }
    }

    It 'A-19 [W] follows the decimal and group separators of the culture (de-DE)' {
        Invoke-WithCulture 'de-DE' {
            Format-SwByteSize -Bytes 1073741824 | Should -BeExactly '1,00GB'
            Format-SwByteSize -Bytes 1048575 | Should -BeExactly '1.024KB'
            Format-SwByteSize -Bytes 1572864 | Should -BeExactly '1,5MB'
        }
    }

    It 'A-20 gives 0B for $null' {
        Invoke-WithCulture 'en-US' {
            Format-SwByteSize -Bytes $null | Should -BeExactly '0B'
        }
    }

    It 'A-20 takes the size as the first positional parameter' {
        Invoke-WithCulture 'en-US' {
            Format-SwByteSize 1536 | Should -BeExactly '2KB'
        }
    }

    It 'A-20 converts a numeric string to [long]' {
        Invoke-WithCulture 'en-US' {
            Format-SwByteSize -Bytes '1073741824' | Should -BeExactly '1.00GB'
        }
    }

    It 'A-20 rejects a value that cannot be converted with a binding error' {
        { Format-SwByteSize -Bytes 'not a number' } | Should -Throw
    }
}

# ============================================================================
# Side effects of the functions of this part
# ============================================================================

Describe 'Side effects of part A functions' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Start-Case
    }
    AfterEach { Stop-Case }
    It 'S-A2 returns only its value and writes nothing else for <Name>' -ForEach @(
        @{ Name = 'ConvertTo-SwPsLiteral'; Call = { ConvertTo-SwPsLiteral -Value 'x' }; Count = 1 }
        @{ Name = 'Get-SwColor'; Call = { Get-SwColor -Name 'Green' }; Count = 1 }
        @{ Name = 'Get-SwIcon'; Call = { Get-SwIcon -Name 'Solid' }; Count = 1 }
        @{ Name = 'Get-SwDefaultColors'; Call = { Get-SwDefaultColors }; Count = 1 }
        @{ Name = 'Get-SwDefaultIcons'; Call = { Get-SwDefaultIcons }; Count = 1 }
        @{ Name = 'Initialize-SwVisualDefaults'; Call = { Initialize-SwVisualDefaults }; Count = 0 }
        @{ Name = 'Test-SwPortable'; Call = { Test-SwPortable -RootDir $TestDrive }; Count = 1 }
        @{ Name = 'Resolve-SwDataPaths'; Call = { Resolve-SwDataPaths -RootDir $TestDrive }; Count = 1 }
        @{ Name = 'Get-SwFreeSpace'; Call = { Get-SwFreeSpace -Drive 'ZZ:' }; Count = 1 }
        @{ Name = 'Get-SwWindowsVersion'; Call = { Get-SwWindowsVersion }; Count = 1 }
        @{ Name = 'Format-SwByteSize'; Call = { Format-SwByteSize -Bytes 5 }; Count = 1 }
    ) {
        $records = @(& $Call *>&1)
        $records.Count | Should -Be $Count
    }

    It 'S-A2 changes nothing in the file system when Resolve-SwDataPaths, Test-SwPortable, Get-SwFreeSpace and the tables run' {
        $before = @(Get-ChildItem -LiteralPath $TestDrive -Force -Recurse | ForEach-Object { $_.FullName })
        $env:SWEEPR_DATA_DIR = [System.IO.Path]::Combine($TestDrive, 'nothing-here')
        $null = Resolve-SwDataPaths -RootDir $TestDrive
        $null = Test-SwPortable -RootDir $TestDrive
        $null = Get-SwFreeSpace -Drive 'ZZ:'
        $null = Get-SwWindowsVersion
        $null = Get-SwColor -Name 'Green'
        $null = Get-SwIcon -Name 'Solid'
        $null = Format-SwByteSize -Bytes 1
        $after = @(Get-ChildItem -LiteralPath $TestDrive -Force -Recurse | ForEach-Object { $_.FullName })
        @($after | Where-Object { $_ -notin $before }).Count | Should -Be 0
    }

    It 'S-A5 starts no process and uses no network in any function of part A' {
        Mock Start-Process { }
        Mock Start-Job { }
        Mock Invoke-WebRequest { }
        Mock Invoke-RestMethod { }
        $env:SWEEPR_DATA_DIR = [System.IO.Path]::Combine($TestDrive, 's-a5')
        $null = ConvertTo-SwPsLiteral -Value 'x'
        $null = Get-SwColor -Name 'Green'
        $null = Get-SwIcon -Name 'Solid'
        $null = Get-SwDefaultColors
        $null = Get-SwDefaultIcons
        Initialize-SwVisualDefaults
        $null = Test-SwPortable -RootDir $TestDrive
        $null = Resolve-SwDataPaths -RootDir $TestDrive
        Assert-SwDataWritable -Path ([System.IO.Path]::Combine($TestDrive, 's-a5-writable'))
        $script:Config.ConfigPath = [System.IO.Path]::Combine($TestDrive, 's-a5-config')
        $script:Config.CachePath = [System.IO.Path]::Combine($TestDrive, 's-a5-cache')
        $null = Get-SwConfigPath
        $null = Get-SwCachePath
        try { $null = Test-SwAdmin } catch { $null = $_ }
        $null = Get-SwFreeSpace -Drive 'ZZ:'
        $null = Get-SwWindowsVersion
        $null = Format-SwByteSize -Bytes 1
        foreach ($name in 'Start-Process', 'Start-Job', 'Invoke-WebRequest', 'Invoke-RestMethod') {
            Should -Invoke -CommandName $name -Times 0 -Exactly
        }
    }
}

# ============================================================================
# Old names (forwarding functions)
# ============================================================================

Describe 'Transition names of part A' {
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

    It 'Forwards Get-FreeSpace without arguments to Get-SwFreeSpace with the system drive' {
        $env:SystemDrive = 'Q:'
        Mock Get-SwFreeSpace { 'forwarded' }
        Get-FreeSpace | Should -Be 'forwarded'
        Should -Invoke Get-SwFreeSpace -Times 1 -Exactly
    }

    It 'ConvertTo-SweeprPsLiteral gives the same literal as ConvertTo-SwPsLiteral' {
        foreach ($value in @('it''s', ('a' + [char]0x2019 + 'b'), '', 'C:\Users\Example\My Files', '$(Get-Date)')) {
            ConvertTo-SweeprPsLiteral -Value $value | Should -BeExactly (ConvertTo-SwPsLiteral -Value $value)
        }
        ConvertTo-SweeprPsLiteral -Value $null | Should -BeExactly (ConvertTo-SwPsLiteral -Value $null)
    }

    It 'Get-SweeprColor and Get-SweeprIcon give the same values as the new functions, also for unknown names' {
        foreach ($name in 'Green', 'NC', 'Gray') { Get-SweeprColor -Name $name | Should -BeExactly (Get-SwColor -Name $name) }
        foreach ($name in 'Solid', 'Error', 'DryRun') { Get-SweeprIcon -Name $name | Should -BeExactly (Get-SwIcon -Name $name) }
        $null -eq (Get-SweeprColor -Name 'Nope') | Should -BeTrue
        $null -eq (Get-SweeprIcon -Name 'Nope') | Should -BeTrue
    }

    It 'Get-SweeprDefaultColors and Get-SweeprDefaultIcons give the same tables as the new functions' {
        $oldColors = Get-SweeprDefaultColors
        $newColors = Get-SwDefaultColors
        $oldColors.Count | Should -Be $newColors.Count
        foreach ($key in $newColors.Keys) { $oldColors[$key] | Should -BeExactly $newColors[$key] }
        $oldIcons = Get-SweeprDefaultIcons
        $newIcons = Get-SwDefaultIcons
        $oldIcons.Count | Should -Be $newIcons.Count
        foreach ($key in $newIcons.Keys) { $oldIcons[$key] | Should -BeExactly $newIcons[$key] }
    }

    It 'Initialize-SweeprVisualDefaults fills the tables like Initialize-SwVisualDefaults' {
        $script:Colors = @{ Cyan = 'custom' }
        $script:Icons = @{ Solid = '*' }
        Initialize-SweeprVisualDefaults
        $script:Colors['Cyan'] | Should -BeExactly 'custom'
        $script:Colors.Count | Should -Be 10
        $script:Icons['Solid'] | Should -BeExactly '*'
        $script:Icons.Count | Should -Be 15
    }

    It 'Test-SweeprPortable and Resolve-SweeprDataPaths give the same results as the new functions' {
        $program = [System.IO.Path]::Combine($TestDrive, 'forward-program')
        [void][System.IO.Directory]::CreateDirectory($program)
        $env:USERPROFILE = [System.IO.Path]::Combine($TestDrive, 'forward-home')
        Remove-Item Env:SWEEPR_DATA_DIR -ErrorAction SilentlyContinue
        Test-SweeprPortable -RootDir $program | Should -Be (Test-SwPortable -RootDir $program)
        $old = Resolve-SweeprDataPaths -RootDir $program
        $new = Resolve-SwDataPaths -RootDir $program
        foreach ($key in 'Mode', 'ConfigPath', 'CachePath') { $old[$key] | Should -BeExactly $new[$key] }
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($program, 'sweepr.portable'), '')
        Test-SweeprPortable -RootDir $program | Should -BeTrue
        (Resolve-SweeprDataPaths -RootDir $program).Mode | Should -BeExactly 'Portable'
        $env:SWEEPR_DATA_DIR = [System.IO.Path]::Combine($TestDrive, 'forward-override')
        (Resolve-SweeprDataPaths -RootDir $program).Mode | Should -BeExactly 'Override'
    }

    It 'Assert-SweeprDataWritable creates the folder and stops with the same message as Assert-SwDataWritable' {
        $path = [System.IO.Path]::Combine($TestDrive, 'forward-assert', 'config')
        Assert-SweeprDataWritable -Path $path
        [System.IO.Directory]::Exists($path) | Should -BeTrue
        $blocker = [System.IO.Path]::Combine($TestDrive, 'forward-blocker')
        [System.IO.File]::WriteAllText($blocker, 'a file')
        $bad = $blocker + [System.IO.Path]::DirectorySeparatorChar + 'config'
        $oldMessage = $null
        $newMessage = $null
        try { Assert-SweeprDataWritable -Path $bad } catch { $oldMessage = $_.Exception.Message }
        try { Assert-SwDataWritable -Path $bad } catch { $newMessage = $_.Exception.Message }
        $null -ne $oldMessage | Should -BeTrue
        $oldMessage | Should -BeExactly $newMessage
    }

    It 'Get-ConfigPath and Get-CachePath give the same folders as the new functions' {
        $script:Config.ConfigPath = [System.IO.Path]::Combine($TestDrive, 'forward-config')
        $script:Config.CachePath = [System.IO.Path]::Combine($TestDrive, 'forward-cache')
        Get-ConfigPath | Should -BeExactly (Get-SwConfigPath)
        Get-CachePath | Should -BeExactly (Get-SwCachePath)
        [System.IO.Directory]::Exists($script:Config.ConfigPath) | Should -BeTrue
        [System.IO.Directory]::Exists($script:Config.CachePath) | Should -BeTrue
    }

    It 'Test-IsAdmin, Get-FreeSpace, Get-WindowsVersion and Format-ByteSize give the same results as the new functions' {
        $oldAdmin = $null
        $newAdmin = $null
        $oldThrew = $false
        $newThrew = $false
        try { $oldAdmin = Test-IsAdmin } catch { $oldThrew = $true }
        try { $newAdmin = Test-SwAdmin } catch { $newThrew = $true }
        $oldThrew | Should -Be $newThrew
        $oldAdmin | Should -Be $newAdmin
        Get-FreeSpace -Drive 'ZZ:' | Should -BeExactly 'Unknown'
        Get-FreeSpace -Drive 'ZZ:' | Should -BeExactly (Get-SwFreeSpace -Drive 'ZZ:')
        $oldVersion = Get-WindowsVersion
        $newVersion = Get-SwWindowsVersion
        foreach ($key in 'Name', 'Version', 'Build', 'Arch') { $oldVersion[$key] | Should -BeExactly $newVersion[$key] }
        Invoke-WithCulture 'en-US' {
            foreach ($value in 0, 1023, 1024, 1572864, 1073741824) {
                Format-ByteSize -Bytes $value | Should -BeExactly (Format-SwByteSize -Bytes $value)
            }
            Format-ByteSize $null | Should -BeExactly '0B'
        }
    }
}
