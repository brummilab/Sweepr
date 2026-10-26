# Sweepr Windows - installer PATH editing and folder removal tests (B-03)
#
# Platform neutral: functions are loaded from install.ps1 / bin/update.ps1 by AST extraction and the
# registry is never touched. Interface fixed by these tests (the implementer builds exactly this):
#
#   Get-SweeprUserPathRaw
#       Returns [PSCustomObject]@{ Value = <string>; Kind = <string> }: the RAW user PATH value
#       (RegistryKey.GetValue(..., DoNotExpandEnvironmentNames), so %VAR% stays text) and the
#       RegistryValueKind name ('String' or 'ExpandString'). No PATH value: Value = '', Kind = 'ExpandString'.
#   Set-SweeprUserPathRaw -Value <string> -Kind <string>
#       Writes the value with exactly that kind and broadcasts WM_SETTINGCHANGE.
#   Add-ToUserPath / Remove-FromUserPath / Test-InstallDirOnUserPath (install.ps1) and
#   Test-InstallDirOnUserPath (bin/update.ps1) read and write only through these two functions
#   (update.ps1 may define its own copy of the reader). Foreign entries keep their exact raw text,
#   the kind is kept, and nothing is written when nothing changes. Entries match when, after
#   ExpandEnvironmentVariables and TrimEnd('\'), they are equal without regard to case.
#
#   Folder removal: the three places in Remove-SweeprNestedFiles / Uninstall-Sweepr delete a folder
#   after the empty check with [IO.Directory]::Delete($path, $false) (never Remove-Item). A folder
#   that gained an entry in the meantime stays with that entry; nothing is asked, no recursion.
#   Remove-SweeprNestedFiles then keeps the folder without throwing; Uninstall-Sweepr reports through
#   Write-SweeprError (install folder) or Write-SweeprWarning "Failed to remove config..." (config folder).

BeforeAll {
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $script:InstallAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:WindowsDir "install.ps1"), [ref]$null, [ref]$null)
    $script:UpdateAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:WindowsDir "bin\update.ps1"), [ref]$null, [ref]$null)

    function Get-FunctionAst {
        param($Ast, [string]$Name)
        $Ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true)
    }

    # Every top-level function of install.ps1 (definitions only, no side effects), so helpers the
    # implementation adds next to the PATH functions load too. Output stubs are defined below.
    foreach ($definition in @($script:InstallAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })) {
        if ($definition.Name -match '^(Write-|Main$|Show-)') { continue }
        . ([scriptblock]::Create($definition.Extent.Text))
        Set-Item -Path "function:script:$($definition.Name)" -Value (Get-Item "function:$($definition.Name)").ScriptBlock
    }
    foreach ($name in @("Remove-SweeprNestedFiles", "Remove-SweeprConfigEntry", "Uninstall-Sweepr", "Add-ToUserPath", "Remove-FromUserPath", "Test-InstallDirOnUserPath")) {
        if (-not (Get-FunctionAst -Ast $script:InstallAst -Name $name)) { throw "$name not found in install.ps1" }
    }
    # Stand-ins so Mock has something to replace until install.ps1 has the registry layer; it is always mocked.
    if (-not (Get-Command Get-SweeprUserPathRaw -CommandType Function -ErrorAction SilentlyContinue)) {
        function Get-SweeprUserPathRaw { [PSCustomObject]@{ Value = ''; Kind = 'ExpandString' } }
    }
    if (-not (Get-Command Set-SweeprUserPathRaw -CommandType Function -ErrorAction SilentlyContinue)) {
        function Set-SweeprUserPathRaw { param([string]$Value, [string]$Kind) }
    }

    # update.ps1 is a separate script: its helpers load too (except names install.ps1 already has),
    # and its Test-InstallDirOnUserPath under another name so both copies can be tested side by side.
    foreach ($definition in @($script:UpdateAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })) {
        if ($definition.Name -match '^(Write-|Main$|Show-)') { continue }
        $text = $definition.Extent.Text
        $name = $definition.Name
        if ($name -eq 'Test-InstallDirOnUserPath') {
            $name = 'Test-UpdateDirOnUserPath'
            $text = $text -replace 'function\s+Test-InstallDirOnUserPath', 'function Test-UpdateDirOnUserPath'
        }
        elseif (Get-Command $name -CommandType Function -ErrorAction SilentlyContinue) { continue }
        . ([scriptblock]::Create($text))
        Set-Item -Path "function:script:$name" -Value (Get-Item "function:$name").ScriptBlock
    }
    if (-not (Get-Command Test-UpdateDirOnUserPath -CommandType Function -ErrorAction SilentlyContinue)) { throw "Test-InstallDirOnUserPath not found in bin/update.ps1" }

    function Write-Info { param($Message) }
    function Write-Success { param($Message) }
    function Write-SweeprWarning { param($Message) }
    function Write-SweeprError { param($Message) }
    function Remove-StartMenuShortcut { param($InstallDir) $true }

    # Without the registry layer the old code would write the real user PATH; stop before that.
    function Assert-PathLayer {
        foreach ($name in @("Add-ToUserPath", "Remove-FromUserPath", "Test-InstallDirOnUserPath")) {
            ((Get-Item "function:$name").ScriptBlock.ToString() -match 'Get-SweeprUserPathRaw') |
                Should -BeTrue -Because "$name must read the raw PATH through Get-SweeprUserPathRaw"
        }
        foreach ($name in @('Get-SweeprUserPathRaw', 'Set-SweeprUserPathRaw')) {
            Get-FunctionAst -Ast $script:InstallAst -Name $name | Should -Not -BeNullOrEmpty -Because "install.ps1 must define $name"
        }
    }

    function Use-RawPath {
        param([string]$Value, [string]$Kind = 'ExpandString')
        $script:RawPath = [PSCustomObject]@{ Value = $Value; Kind = $Kind }
    }
}

Describe "User PATH editing keeps foreign entries raw" {
    BeforeEach {
        $script:SavedPath = $env:PATH
        Use-RawPath -Value ''
        Mock Get-SweeprUserPathRaw { [PSCustomObject]@{ Value = $script:RawPath.Value; Kind = $script:RawPath.Kind } }
        Mock Set-SweeprUserPathRaw {}
    }

    AfterEach {
        $env:PATH = $script:SavedPath
    }

    It "Defines the raw registry layer in install.ps1" {
        Assert-PathLayer
    }

    It "Adds Sweepr after %VAR% entries without touching their text" {
        Assert-PathLayer
        Use-RawPath -Value '%JAVA_HOME%\bin;%USERPROFILE%\x'
        Add-ToUserPath -Directory 'C:\Example\Programs\sweepr-cli' | Should -BeTrue
        Should -Invoke Set-SweeprUserPathRaw -Times 1 -Exactly -ParameterFilter {
            $Value -ceq '%JAVA_HOME%\bin;%USERPROFILE%\x;C:\Example\Programs\sweepr-cli'
        }
    }

    It "Keeps REG_EXPAND_SZ when adding" {
        Assert-PathLayer
        Use-RawPath -Value '%JAVA_HOME%\bin' -Kind 'ExpandString'
        $null = Add-ToUserPath -Directory 'C:\Example\Programs\sweepr-cli'
        Should -Invoke Set-SweeprUserPathRaw -Times 1 -Exactly -ParameterFilter { $Kind -eq 'ExpandString' }
    }

    It "Keeps REG_SZ when adding to a plain string value" {
        Assert-PathLayer
        Use-RawPath -Value 'C:\Example\Tools' -Kind 'String'
        $null = Add-ToUserPath -Directory 'C:\Example\Programs\sweepr-cli'
        Should -Invoke Set-SweeprUserPathRaw -Times 1 -Exactly -ParameterFilter { $Kind -eq 'String' -and $Value -ceq 'C:\Example\Tools;C:\Example\Programs\sweepr-cli' }
    }

    It "Adds to an empty PATH as the only entry" {
        Assert-PathLayer
        Use-RawPath -Value ''
        Add-ToUserPath -Directory 'C:\Example\Programs\sweepr-cli' | Should -BeTrue
        Should -Invoke Set-SweeprUserPathRaw -Times 1 -Exactly -ParameterFilter { $Value -ceq 'C:\Example\Programs\sweepr-cli' }
    }

    It "Does not add a second entry or write when Sweepr is already listed" {
        Assert-PathLayer
        Use-RawPath -Value '%JAVA_HOME%\bin;C:\Example\Programs\sweepr-cli'
        Add-ToUserPath -Directory 'C:\Example\Programs\sweepr-cli' | Should -BeTrue
        Should -Invoke Set-SweeprUserPathRaw -Times 0 -Exactly
    }

    It "Removes only the Sweepr entry and leaves %VAR% entries byte for byte" {
        Assert-PathLayer
        Use-RawPath -Value '%JAVA_HOME%\bin;C:\Example\Programs\sweepr-cli;%USERPROFILE%\x'
        Remove-FromUserPath -Directory 'C:\Example\Programs\sweepr-cli' | Should -BeTrue
        Should -Invoke Set-SweeprUserPathRaw -Times 1 -Exactly -ParameterFilter { $Value -ceq '%JAVA_HOME%\bin;%USERPROFILE%\x' }
    }

    It "Keeps REG_EXPAND_SZ when removing" {
        Assert-PathLayer
        Use-RawPath -Value '%JAVA_HOME%\bin;C:\Example\Programs\sweepr-cli' -Kind 'ExpandString'
        $null = Remove-FromUserPath -Directory 'C:\Example\Programs\sweepr-cli'
        Should -Invoke Set-SweeprUserPathRaw -Times 1 -Exactly -ParameterFilter { $Kind -eq 'ExpandString' }
    }

    It "Keeps REG_SZ when removing from a plain string value" {
        Assert-PathLayer
        Use-RawPath -Value 'C:\Example\Tools;C:\Example\Programs\sweepr-cli' -Kind 'String'
        $null = Remove-FromUserPath -Directory 'C:\Example\Programs\sweepr-cli'
        Should -Invoke Set-SweeprUserPathRaw -Times 1 -Exactly -ParameterFilter { $Kind -eq 'String' -and $Value -ceq 'C:\Example\Tools' }
    }

    It "Does not write when Sweepr is not on the PATH" {
        Assert-PathLayer
        Use-RawPath -Value '%JAVA_HOME%\bin;%USERPROFILE%\x'
        Remove-FromUserPath -Directory 'C:\Example\Programs\sweepr-cli' | Should -BeTrue
        Should -Invoke Set-SweeprUserPathRaw -Times 0 -Exactly
    }

    It "Does not write when the PATH is empty" {
        Assert-PathLayer
        Use-RawPath -Value ''
        Remove-FromUserPath -Directory 'C:\Example\Programs\sweepr-cli' | Should -BeTrue
        Should -Invoke Set-SweeprUserPathRaw -Times 0 -Exactly
    }

    It "Reports failure when the registry write throws" {
        Assert-PathLayer
        Use-RawPath -Value 'C:\Example\Programs\sweepr-cli'
        Mock Set-SweeprUserPathRaw { throw "denied" }
        Remove-FromUserPath -Directory 'C:\Example\Programs\sweepr-cli' | Should -BeFalse
    }
}

Describe "PATH entries are compared as folders, not as text" {
    BeforeEach {
        $script:SavedPath = $env:PATH
        $script:SavedLocal = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = 'C:\Example\Local'
        Use-RawPath -Value ''
        Mock Get-SweeprUserPathRaw { [PSCustomObject]@{ Value = $script:RawPath.Value; Kind = $script:RawPath.Kind } }
        Mock Set-SweeprUserPathRaw {}
    }

    AfterEach {
        $env:PATH = $script:SavedPath
        $env:LOCALAPPDATA = $script:SavedLocal
    }

    It "Recognizes <Name> as the install folder in Remove, Add and both PATH checks" -ForEach @(
        @{ Name = 'a trailing backslash'; Entry = 'C:\Example\Local\Programs\sweepr-cli\' }
        @{ Name = 'another letter case'; Entry = 'c:\EXAMPLE\local\programs\SWEEPR-CLI' }
        @{ Name = 'another letter case with a trailing backslash'; Entry = 'c:\example\LOCAL\Programs\Sweepr-Cli\' }
        @{ Name = 'a %LOCALAPPDATA% form'; Entry = '%LOCALAPPDATA%\Programs\sweepr-cli' }
        @{ Name = 'a %LOCALAPPDATA% form with a trailing backslash'; Entry = '%LOCALAPPDATA%\Programs\sweepr-cli\' }
    ) {
        Assert-PathLayer
        $dir = 'C:\Example\Local\Programs\sweepr-cli'
        $other = '%JAVA_HOME%\bin'

        Use-RawPath -Value "$other;$($Entry);C:\Example\Tools"
        [bool](Test-InstallDirOnUserPath -Path $dir) | Should -BeTrue
        [bool](Test-UpdateDirOnUserPath -Path $dir) | Should -BeTrue

        Add-ToUserPath -Directory $dir | Should -BeTrue
        Should -Invoke Set-SweeprUserPathRaw -Times 0 -Exactly

        Remove-FromUserPath -Directory $dir | Should -BeTrue
        Should -Invoke Set-SweeprUserPathRaw -Times 1 -Exactly -ParameterFilter { $Value -ceq "$other;C:\Example\Tools" }
    }

    It "Recognizes a directory given with a trailing backslash against a plain entry" {
        Assert-PathLayer
        Use-RawPath -Value '%JAVA_HOME%\bin;C:\Example\Local\Programs\sweepr-cli'
        [bool](Test-InstallDirOnUserPath -Path 'C:\Example\Local\Programs\sweepr-cli\') | Should -BeTrue
        [bool](Test-UpdateDirOnUserPath -Path 'C:\Example\Local\Programs\sweepr-cli\') | Should -BeTrue
        Add-ToUserPath -Directory 'C:\Example\Local\Programs\sweepr-cli\' | Should -BeTrue
        Should -Invoke Set-SweeprUserPathRaw -Times 0 -Exactly
    }

    It "Does not match a different folder with the same prefix" {
        Assert-PathLayer
        Use-RawPath -Value 'C:\Example\Local\Programs\sweepr-cli2;C:\Example\Local\Programs'
        [bool](Test-InstallDirOnUserPath -Path 'C:\Example\Local\Programs\sweepr-cli') | Should -BeFalse
        [bool](Test-UpdateDirOnUserPath -Path 'C:\Example\Local\Programs\sweepr-cli') | Should -BeFalse
        Remove-FromUserPath -Directory 'C:\Example\Local\Programs\sweepr-cli' | Should -BeTrue
        Should -Invoke Set-SweeprUserPathRaw -Times 0 -Exactly
    }

    It "Reports false when the PATH is empty" {
        Assert-PathLayer
        Use-RawPath -Value ''
        [bool](Test-InstallDirOnUserPath -Path 'C:\Example\Local\Programs\sweepr-cli') | Should -BeFalse
        [bool](Test-UpdateDirOnUserPath -Path 'C:\Example\Local\Programs\sweepr-cli') | Should -BeFalse
    }

    It "Reads the PATH raw in bin/update.ps1 too" {
        ((Get-Item "function:Test-UpdateDirOnUserPath").ScriptBlock.ToString() -match 'Get-SweeprUserPathRaw') | Should -BeTrue
    }
}

Describe "Folder removal never recurses after the empty check" {
    BeforeEach {
        $script:SavedLocal = $env:LOCALAPPDATA
        $script:SavedProfile = $env:USERPROFILE
        $script:SavedData = $env:SWEEPR_DATA_DIR
        $env:LOCALAPPDATA = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
        $env:USERPROFILE = Join-Path $TestDrive ("profile-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $env:USERPROFILE -Force | Out-Null
        $env:SWEEPR_DATA_DIR = $null
        $script:InstallDirGiven = $true
        $script:SourceDir = $null
        $script:Intruded = $false
        Mock Write-SweeprError {}
        # A folder must never go through Remove-Item (it would ask, or recurse, on a non-empty one).
        Mock Remove-Item { [System.IO.File]::Delete($LiteralPath) }
        Mock Remove-Item {} -ParameterFilter { Test-Path -LiteralPath $LiteralPath -PathType Container }
        Mock Write-SweeprWarning {}
        Mock Remove-FromUserPath {}
    }

    AfterEach {
        $env:LOCALAPPDATA = $script:SavedLocal
        $env:USERPROFILE = $script:SavedProfile
        $env:SWEEPR_DATA_DIR = $script:SavedData
    }

    It "Remove-SweeprNestedFiles keeps a folder that gained a file after the empty check" {
        $install = Join-Path $TestDrive ("nested-" + [guid]::NewGuid().ToString("N"))
        $bin = Join-Path $install "bin"
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $bin "analyze.ps1") -Value "#"
        $script:RaceFolder = $bin
        Mock Get-ChildItem {
            if (-not $script:Intruded) {
                $script:Intruded = $true
                Set-Content -LiteralPath (Join-Path $script:RaceFolder "late.txt") -Value "mine"
            }
            @()
        } -ParameterFilter { $LiteralPath -eq $script:RaceFolder }

        { Remove-SweeprNestedFiles -InstallPath $install -Root "bin" } | Should -Not -Throw

        $script:Intruded | Should -BeTrue
        Should -Invoke Remove-Item -Times 0 -Exactly -ParameterFilter { Test-Path -LiteralPath $LiteralPath -PathType Container }
        Test-Path -LiteralPath (Join-Path $bin "analyze.ps1") | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $bin "late.txt") | Should -Be "mine"
    }

    It "Uninstall-Sweepr keeps an install folder that gained a file after its entries were removed" {
        $install = Join-Path $env:LOCALAPPDATA "Tools"
        New-Item -ItemType Directory -Path (Join-Path $install "lib\core"), (Join-Path $install "bin") -Force | Out-Null
        Set-Content -Path (Join-Path $install "sweepr.ps1") -Value "#"
        Set-Content -Path (Join-Path $install "lib\core\base.ps1") -Value "#"
        Set-Content -Path (Join-Path $install "sw.cmd") -Value "@echo off"
        Set-Content -Path (Join-Path $install "VERSION") -Value "1.0.0"
        $InstallDir = $install
        $script:RaceFolder = $install
        # Fires while the entries are removed, after the entry list was read.
        Mock Assert-InstallPhysicalPath {
            if (-not $script:Intruded -and $Path -like '*VERSION') {
                $script:Intruded = $true
                Set-Content -LiteralPath (Join-Path $script:RaceFolder "late.txt") -Value "mine"
            }
        }

        { Uninstall-Sweepr } | Should -Not -Throw

        $script:Intruded | Should -BeTrue
        Should -Invoke Remove-Item -Times 0 -Exactly -ParameterFilter { Test-Path -LiteralPath $LiteralPath -PathType Container }
        Get-Content -LiteralPath (Join-Path $install "late.txt") | Should -Be "mine"
        Should -Invoke Write-SweeprError -Times 1 -Exactly
    }

    It "Uninstall-Sweepr keeps a config folder that gained a file after the listing" {
        $install = Join-Path $env:LOCALAPPDATA "Tools"
        New-Item -ItemType Directory -Path (Join-Path $install "lib\core") -Force | Out-Null
        Set-Content -Path (Join-Path $install "sweepr.ps1") -Value "#"
        Set-Content -Path (Join-Path $install "lib\core\base.ps1") -Value "#"
        $InstallDir = $install
        $config = Join-Path $env:USERPROFILE ".config\sweepr"
        New-Item -ItemType Directory -Path $config -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $config "settings.json") -Value "{}"
        $script:RaceFolder = $config
        Mock Read-Host { "y" }
        Mock Remove-SweeprConfigEntry {
            [System.IO.File]::Delete($Item.FullName)
            $script:Intruded = $true
            Set-Content -LiteralPath (Join-Path $script:RaceFolder "status_prefs") -Value "mine"
        }

        { Uninstall-Sweepr } | Should -Not -Throw

        $script:Intruded | Should -BeTrue
        Should -Invoke Remove-Item -Times 0 -Exactly -ParameterFilter { Test-Path -LiteralPath $LiteralPath -PathType Container }
        Get-Content -LiteralPath (Join-Path $config "status_prefs") | Should -Be "mine"
        Should -Invoke Write-SweeprWarning -Times 1 -Exactly -ParameterFilter { "$Message" -like 'Failed to remove config*' }
    }

    It "Uses no Remove-Item on a directory in the three removal places" {
        $offenders = @()
        foreach ($name in @("Remove-SweeprNestedFiles", "Uninstall-Sweepr", "Remove-SweeprConfigEntry")) {
            $function = Get-FunctionAst -Ast $script:InstallAst -Name $name
            $calls = $function.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Remove-Item'
                }, $true)
            foreach ($call in $calls) {
                $target = ''
                for ($i = 0; $i -lt $call.CommandElements.Count - 1; $i++) {
                    $element = $call.CommandElements[$i]
                    if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and $element.ParameterName -in @('LiteralPath', 'Path')) {
                        $target = $call.CommandElements[$i + 1].Extent.Text
                    }
                }
                $inFolderLoop = $false
                $parent = $call.Parent
                while ($parent) {
                    if ($parent -is [System.Management.Automation.Language.ForEachStatementAst] -and $parent.Condition.Extent.Text -match 'folders') { $inFolderLoop = $true }
                    $parent = $parent.Parent
                }
                if ($target -in @('$installPath', '$configDir') -or ($target -eq '$path' -and $inFolderLoop)) {
                    $offenders += "$name line $($call.Extent.StartLineNumber): $($call.Extent.Text)"
                }
            }
        }
        $offenders | Should -BeNullOrEmpty
    }
}
