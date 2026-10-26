# Sweepr - the whitelist and purge_paths.txt are read robustly (B-02, bugs-core H1/H2)
# H1: Windows PowerShell 5.1 reads a file without BOM through the ANSI code page. Notepad and
#     VS Code save UTF-8 without BOM, so an entry with an umlaut matched nothing and protected
#     nothing. The files must be read explicitly as UTF-8 (BOM tolerant, UTF-16 BOM too) and
#     written as UTF-8 with BOM.
# H2: Entries as the Explorer copies them ("C:\path" in quotes) or typed with / , %VAR% or ~
#     protected nothing. They are normalized when read.
# Decisions pinned here:
#   - The reading code never calls Get-Content without -Encoding (or uses a .NET reader with UTF-8).
#   - Edit-Whitelist and Edit-SearchPaths write UTF-8 with BOM.
#   - ~ stands for $env:USERPROFILE; an undefined %VAR% stays literal and protects nothing else.
#   - purge_paths.txt gets the same normalization as the whitelist (it has its own reading code).
# Platform neutral: Windows-style strings through the matchers; no real paths are touched.
# Get-Content is mocked to behave like Windows PowerShell 5.1 when called without -Encoding.
# LOCALAPPDATA and USERPROFILE are restored afterwards.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:RepoRoot 'lib/core/base.ps1')
    . (Join-Path $script:RepoRoot 'lib/core/log.ps1')
    . (Join-Path $script:RepoRoot 'lib/core/file_ops.ps1')
    $script:SavedWhitelistFile = $script:Config.WhitelistFile
    $script:SavedLocalAppData = $env:LOCALAPPDATA
    $script:SavedUserProfile = $env:USERPROFILE
    $script:SavedAppData = $env:APPDATA
    $script:SavedConfigPath = $script:Config.ConfigPath
    $script:SavedCachePath = $script:Config.CachePath

    function script:Get-FunctionAst {
        param([string]$RelativePath, [string]$Name)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot $RelativePath), [ref]$null, [ref]$null)
        return $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true)
    }

    function script:Import-ScriptFunction {
        param([string]$RelativePath, [string]$Name)
        $definition = Get-FunctionAst -RelativePath $RelativePath -Name $Name
        $definition | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($definition.Extent.Text))
        Set-Item -Path "function:script:$Name" -Value (Get-Item "function:$Name").ScriptBlock
    }

    # Bytes of a text file in one of the encodings an editor may produce.
    function script:Write-EncodedFile {
        param([string]$Path, [string[]]$Lines, [ValidateSet('utf8', 'utf8bom', 'utf16le', 'utf32le', 'utf32be')][string]$Kind)
        $text = ($Lines -join "`r`n") + "`r`n"
        switch ($Kind) {
            'utf8' { $encoding = New-Object System.Text.UTF8Encoding($false); $bom = @() }
            'utf8bom' { $encoding = New-Object System.Text.UTF8Encoding($true); $bom = $encoding.GetPreamble() }
            'utf16le' { $encoding = New-Object System.Text.UnicodeEncoding($false, $true); $bom = $encoding.GetPreamble() }
            'utf32le' { $encoding = New-Object System.Text.UTF32Encoding($false, $true); $bom = $encoding.GetPreamble() }
            'utf32be' { $encoding = New-Object System.Text.UTF32Encoding($true, $true); $bom = $encoding.GetPreamble() }
        }
        [System.IO.File]::WriteAllBytes($Path, [byte[]](@($bom) + @($encoding.GetBytes($text))))
    }

    # Default mock body: pass the few parameters the code under test uses to the real cmdlet.
    function script:Invoke-RealCmdlet {
        param([string]$Name, [string]$LiteralPath, [string]$PathType, [string]$Encoding, $ErrorAction = 'Stop')
        $forward = @{ LiteralPath = $LiteralPath; ErrorAction = $ErrorAction }
        if ($PathType) { $forward['PathType'] = $PathType }
        if ($Encoding) { $forward['Encoding'] = $Encoding }
        & (Get-Command -CommandType Cmdlet -Name $Name) @forward
    }

    # Get-Content as Windows PowerShell 5.1 behaves: a BOM is honoured, a file without BOM
    # is decoded through the ANSI code page (Latin-1 stands in for it). An explicit
    # -Encoding goes to the real cmdlet.
    function script:Invoke-LegacyGetContent {
        param([string]$LiteralPath)
        $bytes = [System.IO.File]::ReadAllBytes($LiteralPath)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
        }
        elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            $text = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
        }
        else {
            $text = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
        }
        $lines = $text -split "`r?`n"
        if ($lines.Length -gt 0 -and $lines[-1] -eq '') { $lines = $lines[0..($lines.Length - 2)] }
        return $lines
    }

    # All Get-Content calls below a node: does each one pass -Encoding?
    function script:Get-ContentUse {
        param($Node)
        $commands = $Node.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Get-Content', 'gc', 'cat', 'type')
            }, $true)
        foreach ($command in $commands) {
            $names = @($command.CommandElements |
                    Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
                    ForEach-Object { $_.ParameterName })
            [pscustomobject]@{ Line = $command.Extent.StartLineNumber; HasEncoding = [bool]($names | Where-Object { 'Encoding'.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) -and $_.Length -ge 2 }) }
        }
    }

    # True when the node (syntax tree, comments and strings do not count) reads the bytes of
    # the file (Read-SweeprListBytes or [IO.File]::ReadAll*) AND decodes them through
    # ConvertFrom-SweeprListBytes (BOM aware, UTF-8 by default).
    function script:Test-ExplicitUtf8Read {
        param($Node)
        $reads = $Node.FindAll({
                param($n)
                ($n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Read-SweeprListBytes') -or
                ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                $n.Member.Extent.Text -in @('ReadAllBytes', 'ReadAllLines', 'ReadAllText') -and
                $n.Expression.Extent.Text -match 'IO\.File\]$')
            }, $true)
        $decodes = $Node.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'ConvertFrom-SweeprListBytes'
            }, $true)
        return (@($reads).Count -gt 0) -and (@($decodes).Count -gt 0)
    }
}

AfterAll {
    $script:Config.WhitelistFile = $script:SavedWhitelistFile
    $script:Config.ConfigPath = $script:SavedConfigPath
    $script:Config.CachePath = $script:SavedCachePath
    $env:LOCALAPPDATA = $script:SavedLocalAppData
    $env:USERPROFILE = $script:SavedUserProfile
    $env:APPDATA = $script:SavedAppData
}

Describe 'Whitelist file is read as UTF-8 (H1)' {
    BeforeEach {
        $script:Case = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Case | Out-Null
        $script:Config.WhitelistFile = Join-Path $script:Case 'whitelist.txt'
        # Both are real data folders in production; keep them away from the candidates.
        $script:Config.ConfigPath = 'C:\Scratch\Example\data'
        $script:Config.CachePath = 'C:\Scratch\Example\cache'
        Mock Get-Content { Invoke-RealCmdlet -Name Get-Content -LiteralPath $LiteralPath -Encoding $Encoding -ErrorAction $ErrorActionPreference }
        Mock Get-Content { Invoke-LegacyGetContent -LiteralPath $LiteralPath } -ParameterFilter { -not $PSBoundParameters.ContainsKey('Encoding') }
    }

    AfterEach {
        $script:Config.WhitelistFile = $script:SavedWhitelistFile
        $script:Config.ConfigPath = $script:SavedConfigPath
        $script:Config.CachePath = $script:SavedCachePath
    }

    It 'Protects an umlaut path from a file saved as <Kind>' -ForEach @(
        @{ Kind = 'utf8' }
        @{ Kind = 'utf8bom' }
        @{ Kind = 'utf16le' }
    ) {
        # The path is the first line: a BOM left in the text would spoil exactly this entry.
        Write-EncodedFile -Path $script:Config.WhitelistFile -Kind $Kind -Lines @('C:\Daten\Übersicht', 'C:\Daten\Straße')
        Test-Whitelisted -Path 'C:\Daten\Übersicht' | Should -BeTrue
        Test-Whitelisted -Path 'C:\Daten\Übersicht\Unterordner\datei.tmp' | Should -BeTrue
        Test-Whitelisted -Path 'C:\Daten\Straße\x' | Should -BeTrue
    }

    It 'Does not protect look-alike spellings of an umlaut entry (<Kind>)' -ForEach @(
        @{ Kind = 'utf8' }
        @{ Kind = 'utf8bom' }
        @{ Kind = 'utf16le' }
    ) {
        Write-EncodedFile -Path $script:Config.WhitelistFile -Kind $Kind -Lines @('C:\Daten\Übersicht')
        Test-Whitelisted -Path 'C:\Daten\Ubersicht\x' | Should -BeFalse
        Test-Whitelisted -Path 'C:\Daten\Übersicht2\x' | Should -BeFalse
        Test-Whitelisted -Path 'C:\Daten\ÃœÂ¬bersicht\x' | Should -BeFalse
    }

    It 'Keeps ASCII entries working in every encoding (<Kind>)' -ForEach @(
        @{ Kind = 'utf8' }
        @{ Kind = 'utf8bom' }
        @{ Kind = 'utf16le' }
    ) {
        Write-EncodedFile -Path $script:Config.WhitelistFile -Kind $Kind -Lines @('# comment with Übung', 'C:\Plain\Keep')
        Test-Whitelisted -Path 'C:\Plain\Keep\x' | Should -BeTrue
        Test-Whitelisted -Path 'C:\Plain\Other' | Should -BeFalse
    }

    It 'Treats an unreadable file as protect-everything, not as empty' {
        # A directory in place of the file: it exists, but reading it fails.
        New-Item -ItemType Directory -Path $script:Config.WhitelistFile | Out-Null
        Test-Whitelisted -Path 'C:\Anything\else' | Should -BeTrue
    }
}

Describe 'Whitelist reading code names its encoding (H1)' {
    It 'Get-WhitelistState has no Get-Content call without -Encoding' {
        $ast = Get-FunctionAst -RelativePath 'lib/core/base.ps1' -Name 'Get-WhitelistState'
        $ast | Should -Not -BeNullOrEmpty
        @(Get-ContentUse -Node $ast | Where-Object { -not $_.HasEncoding }).Count | Should -Be 0
    }

    It 'Get-WhitelistState reads the file explicitly as UTF-8' {
        $ast = Get-FunctionAst -RelativePath 'lib/core/base.ps1' -Name 'Get-WhitelistState'
        Test-ExplicitUtf8Read -Node $ast | Should -BeTrue
    }

    It 'Get-SearchPaths reads purge_paths.txt explicitly as UTF-8' {
        $ast = Get-FunctionAst -RelativePath 'bin/purge.ps1' -Name 'Get-SearchPaths'
        $ast | Should -Not -BeNullOrEmpty
        @(Get-ContentUse -Node $ast | Where-Object { -not $_.HasEncoding }).Count | Should -Be 0
        Test-ExplicitUtf8Read -Node $ast | Should -BeTrue
    }
}

Describe 'Whitelist and purge_paths.txt are written as UTF-8 with BOM (H1)' {
    BeforeAll {
        Import-ScriptFunction -RelativePath 'bin/clean.ps1' -Name 'Edit-Whitelist'
        Import-ScriptFunction -RelativePath 'bin/purge.ps1' -Name 'Edit-SearchPaths'
        function script:Write-Info { param($Message) }
        function script:Write-Success { param($Message) }
    }

    BeforeEach {
        $script:Case = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Config.WhitelistFile = Join-Path $script:Case 'config/whitelist.txt'
        $script:ConfigFile = Join-Path $script:Case 'config/purge_paths.txt'
        # The templates print these variables; a non-ASCII profile name must survive.
        $env:LOCALAPPDATA = 'C:\Users\Müller\AppData\Local'
        $env:USERPROFILE = 'C:\Users\Müller'
        Mock Start-Process {}
    }

    AfterEach {
        $script:Config.WhitelistFile = $script:SavedWhitelistFile
        $env:LOCALAPPDATA = $script:SavedLocalAppData
        $env:USERPROFILE = $script:SavedUserProfile
    }

    It 'Edit-Whitelist writes a BOM and keeps the non-ASCII profile name' {
        Edit-Whitelist
        $bytes = [System.IO.File]::ReadAllBytes($script:Config.WhitelistFile)
        ($bytes[0..2] -join ',') | Should -BeExactly '239,187,191'
        [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3) | Should -Match 'C:\\Users\\Müller\\AppData\\Local\\CriticalApp'
    }

    It 'Edit-SearchPaths writes a BOM and keeps the non-ASCII profile name' {
        Edit-SearchPaths
        $bytes = [System.IO.File]::ReadAllBytes($script:ConfigFile)
        ($bytes[0..2] -join ',') | Should -BeExactly '239,187,191'
        [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3) | Should -Match 'C:\\Users\\Müller\\Documents'
    }
}

Describe 'Whitelist entry spellings (H2)' {
    BeforeEach {
        $script:Case = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Case | Out-Null
        $script:Config.WhitelistFile = Join-Path $script:Case 'whitelist.txt'
        $script:Config.ConfigPath = 'C:\Scratch\Example\data'
        $script:Config.CachePath = 'C:\Scratch\Example\cache'
        $env:LOCALAPPDATA = 'C:\Users\Example\AppData\Local'
        $env:USERPROFILE = 'C:\Users\Example'
        $env:SWEEPR_TEST_UNDEFINED = $null
        Remove-Item Env:\SWEEPR_TEST_UNDEFINED -ErrorAction SilentlyContinue
    }

    AfterEach {
        $script:Config.WhitelistFile = $script:SavedWhitelistFile
        $script:Config.ConfigPath = $script:SavedConfigPath
        $script:Config.CachePath = $script:SavedCachePath
        $env:LOCALAPPDATA = $script:SavedLocalAppData
        $env:USERPROFILE = $script:SavedUserProfile
    }

    It 'Protects the path of a <Name> entry' -ForEach @(
        @{ Name = 'double-quoted'; Entry = '"C:\Users\Example\Projekt"'; Inside = 'C:\Users\Example\Projekt\cache\x'; Outside = 'C:\Users\Example\Projekt2\x' }
        @{ Name = 'single-quoted'; Entry = "'C:\Users\Example\Projekt'"; Inside = 'C:\Users\Example\Projekt\cache\x'; Outside = 'C:\Users\Example\Projekt2\x' }
        @{ Name = 'quoted with trailing backslash'; Entry = '"C:\Users\Example\Projekt\"'; Inside = 'C:\Users\Example\Projekt\cache\x'; Outside = 'C:\Users\Example\Projekt2\x' }
        @{ Name = 'quoted with spaces around'; Entry = '  "C:\Users\Example\Projekt"  '; Inside = 'C:\Users\Example\Projekt\cache\x'; Outside = 'C:\Users\Example\Projekt2\x' }
        @{ Name = 'quoted with spaces inside the path'; Entry = '"C:\Users\Example\My Projects\App"'; Inside = 'C:\Users\Example\My Projects\App\x'; Outside = 'C:\Users\Example\My Projects\App2\x' }
        @{ Name = 'quoted with brackets'; Entry = '"C:\Apps [x]\Data"'; Inside = 'C:\Apps [x]\Data\x'; Outside = 'C:\Apps x\Data\x' }
        @{ Name = 'quoted wildcard'; Entry = '"C:\Users\*\AppData\Local\MyApp"'; Inside = 'C:\Users\Example\AppData\Local\MyApp\x'; Outside = 'C:\Users\Example\AppData\Local\Other\x' }
        @{ Name = 'forward-slash'; Entry = 'C:/Users/Example/Other'; Inside = 'C:\Users\Example\Other\x'; Outside = 'C:\Users\Example\Other2\x' }
        @{ Name = 'mixed-slash'; Entry = 'C:/Users\Example/Other'; Inside = 'C:\Users\Example\Other\x'; Outside = 'C:\Users\Example\Other2\x' }
        @{ Name = 'quoted forward-slash'; Entry = '"C:/Users/Example/Other/"'; Inside = 'C:\Users\Example\Other\x'; Outside = 'C:\Users\Example\Other2\x' }
        @{ Name = 'percent-variable'; Entry = '%LOCALAPPDATA%\Foo'; Inside = 'C:\Users\Example\AppData\Local\Foo\x'; Outside = 'C:\Users\Example\AppData\Local\Foo2\x' }
        @{ Name = 'quoted percent-variable'; Entry = '"%LOCALAPPDATA%\Foo"'; Inside = 'C:\Users\Example\AppData\Local\Foo\x'; Outside = 'C:\Users\Example\AppData\Local\Foo2\x' }
        @{ Name = 'percent-variable with forward slash'; Entry = '%LOCALAPPDATA%/Foo'; Inside = 'C:\Users\Example\AppData\Local\Foo\x'; Outside = 'C:\Users\Example\AppData\Local\Foo2\x' }
        @{ Name = 'tilde'; Entry = '~\Foo'; Inside = 'C:\Users\Example\Foo\x'; Outside = 'C:\Users\Example\Foo2\x' }
        @{ Name = 'tilde with forward slash'; Entry = '~/Foo'; Inside = 'C:\Users\Example\Foo\x'; Outside = 'C:\Users\Example\Foo2\x' }
        @{ Name = 'quoted tilde'; Entry = '"~\Foo"'; Inside = 'C:\Users\Example\Foo\x'; Outside = 'C:\Users\Example\Foo2\x' }
        @{ Name = 'padded'; Entry = "   `tC:\Users\Example\Pad  "; Inside = 'C:\Users\Example\Pad\x'; Outside = 'C:\Users\Example\Pad2\x' }
        @{ Name = 'trailing-backslash'; Entry = 'C:\Users\Example\Trail\'; Inside = 'C:\Users\Example\Trail\x'; Outside = 'C:\Users\Example\Trail2\x' }
    ) {
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value @('# first line is a comment', $Entry)
        Test-Whitelisted -Path $Inside | Should -BeTrue
        Test-Whitelisted -Path $Outside | Should -BeFalse
    }

    It 'Protects the entry folder itself, with or without a trailing backslash on the candidate' {
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value @('"C:\Users\Example\Projekt"')
        Test-Whitelisted -Path 'C:\Users\Example\Projekt' | Should -BeTrue
        Test-Whitelisted -Path 'C:\Users\Example\Projekt\' | Should -BeTrue
    }

    It 'Keeps several entries independent in one file' {
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value @('"C:\Users\Example\A"', 'C:/Users/Example/B', '%LOCALAPPDATA%\C', '~\D')
        foreach ($name in 'Users\Example\A', 'Users\Example\B', 'Users\Example\AppData\Local\C', 'Users\Example\D') {
            Test-Whitelisted -Path "C:\$name\x" | Should -BeTrue
        }
        Test-Whitelisted -Path 'C:\Users\Example\E\x' | Should -BeFalse
    }

    It 'Leaves an undefined %VAR% literal and protects nothing more' {
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value @('%SWEEPR_TEST_UNDEFINED%\Foo', '"%SWEEPR_TEST_UNDEFINED%\Bar"')
        Test-Whitelisted -Path 'C:\Foo\x' | Should -BeFalse
        Test-Whitelisted -Path 'C:\Bar\x' | Should -BeFalse
        Test-Whitelisted -Path 'C:\Users\Example\Foo\x' | Should -BeFalse
        Test-Whitelisted -Path 'C:\Users\Example' | Should -BeFalse
        Test-Whitelisted -Path 'C:\' | Should -BeFalse
        Test-Whitelisted -Path '\Foo\x' | Should -BeFalse
        Test-Whitelisted -Path '\\server\share\Foo\x' | Should -BeFalse
    }

    It 'Keeps a bare variable entry without a value from protecting the drive or the profile' {
        # An empty value cannot be set ($env:X = '' removes the variable), so this is the
        # undefined case: the entry stays literal and must not become an empty pattern.
        Remove-Item Env:\SWEEPR_TEST_EMPTY -ErrorAction SilentlyContinue
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value @('%SWEEPR_TEST_EMPTY%', '%SWEEPR_TEST_EMPTY%\')
        Test-Whitelisted -Path 'C:\Users\Example\Documents\x' | Should -BeFalse
        Test-Whitelisted -Path '\\server\share\x' | Should -BeFalse
        Test-Whitelisted -Path 'C:\x' | Should -BeFalse
    }

    It 'Ignores an empty quoted entry instead of turning it into an empty pattern' {
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value @('""', "''", '"   "')
        Test-Whitelisted -Path 'C:\Users\Example\x' | Should -BeFalse
        Test-Whitelisted -Path '\\server\share\x' | Should -BeFalse
        Test-Whitelisted -Path 'C:\' | Should -BeFalse
    }

    It 'Still ignores comment lines, also when they look like paths' {
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value @('# C:\Users\Example\Commented', '#"C:\Users\Example\Quoted"', '', '   ')
        Test-Whitelisted -Path 'C:\Users\Example\Commented\x' | Should -BeFalse
        Test-Whitelisted -Path 'C:\Users\Example\Quoted\x' | Should -BeFalse
    }

    It 'Normalizes an entry the same way as the state seen by a tree walk' {
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value @('"C:/Users/Example/Walk/"')
        $state = Get-WhitelistState
        Test-Whitelisted -Path 'C:\Users\Example\Walk\sub\file.tmp' -State $state | Should -BeTrue
        Test-Whitelisted -Path 'C:\Users\Example\Walker\file.tmp' -State $state | Should -BeFalse
    }
}

Describe 'purge_paths.txt entries (H1/H2 for the purge search paths)' {
    BeforeAll {
        Import-ScriptFunction -RelativePath 'bin/purge.ps1' -Name 'Get-SearchPaths'
    }

    BeforeEach {
        $script:Case = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Case | Out-Null
        $script:ConfigFile = Join-Path $script:Case 'purge_paths.txt'
        $script:DefaultSearchPaths = @()
        $env:LOCALAPPDATA = 'C:\Users\Example\AppData\Local'
        $env:USERPROFILE = 'C:\Users\Example'
        # Windows-style candidates "exist"; the config file itself is the real one.
        Mock Test-Path { Invoke-RealCmdlet -Name Test-Path -LiteralPath $LiteralPath -PathType $PathType -ErrorAction $ErrorActionPreference }
        Mock Test-Path { $true } -ParameterFilter { "$LiteralPath" -like 'C:\*' }
        Mock Get-Content { Invoke-RealCmdlet -Name Get-Content -LiteralPath $LiteralPath -Encoding $Encoding -ErrorAction $ErrorActionPreference }
        Mock Get-Content { Invoke-LegacyGetContent -LiteralPath $LiteralPath } -ParameterFilter { -not $PSBoundParameters.ContainsKey('Encoding') }
    }

    AfterEach {
        $env:LOCALAPPDATA = $script:SavedLocalAppData
        $env:USERPROFILE = $script:SavedUserProfile
    }

    It 'Finds an umlaut search path in a file saved as <Kind>' -ForEach @(
        @{ Kind = 'utf8' }
        @{ Kind = 'utf8bom' }
        @{ Kind = 'utf16le' }
    ) {
        Write-EncodedFile -Path $script:ConfigFile -Kind $Kind -Lines @('C:\Projekte\Übersicht')
        @(Get-SearchPaths) | Should -Be @('C:\Projekte\Übersicht')
    }

    It 'Normalizes a <Name> entry to the path it means' -ForEach @(
        @{ Name = 'double-quoted'; Entry = '"C:\Users\Example\Projekt"'; Expected = 'C:\Users\Example\Projekt' }
        @{ Name = 'single-quoted'; Entry = "'C:\Users\Example\Projekt'"; Expected = 'C:\Users\Example\Projekt' }
        @{ Name = 'forward-slash'; Entry = 'C:/Users/Example/Projekt'; Expected = 'C:\Users\Example\Projekt' }
        @{ Name = 'percent-variable'; Entry = '%LOCALAPPDATA%\Foo'; Expected = 'C:\Users\Example\AppData\Local\Foo' }
        @{ Name = 'tilde'; Entry = '~\Foo'; Expected = 'C:\Users\Example\Foo' }
        @{ Name = 'padded'; Entry = "   C:\Users\Example\Pad`t "; Expected = 'C:\Users\Example\Pad' }
    ) {
        Set-Content -LiteralPath $script:ConfigFile -Value @('# comment', $Entry)
        @(Get-SearchPaths) | Should -Be @($Expected)
    }

    It 'Does not search a path from an undefined %VAR%' {
        Remove-Item Env:\SWEEPR_TEST_UNDEFINED -ErrorAction SilentlyContinue
        Set-Content -LiteralPath $script:ConfigFile -Value @('%SWEEPR_TEST_UNDEFINED%\Foo')
        @(Get-SearchPaths).Count | Should -Be 0
    }

    It 'Ignores an empty quoted entry' {
        Set-Content -LiteralPath $script:ConfigFile -Value @('""', "''")
        @(Get-SearchPaths).Count | Should -Be 0
    }
}

Describe 'Whitelist regressions against the previous reader (B-02 review)' {
    BeforeEach {
        $script:Case = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Case | Out-Null
        $script:Config.WhitelistFile = Join-Path $script:Case 'whitelist.txt'
        $script:Config.ConfigPath = 'C:\Scratch\Example\data'
        $script:Config.CachePath = 'C:\Scratch\Example\cache'
        $env:APPDATA = 'C:\Users\Example\AppData\Roaming'
        $env:SWEEPR_TEST_DEFINED = 'Value'
    }

    AfterEach {
        $script:Config.WhitelistFile = $script:SavedWhitelistFile
        $script:Config.ConfigPath = $script:SavedConfigPath
        $script:Config.CachePath = $script:SavedCachePath
        $env:APPDATA = $script:SavedAppData
        Remove-Item Env:\SWEEPR_TEST_DEFINED -ErrorAction SilentlyContinue
    }

    It 'Protects every entry of a file with bare CR line endings' {
        $text = "# comment`rC:\Keep\A`rC:\Keep\B`r"
        [System.IO.File]::WriteAllBytes($script:Config.WhitelistFile, (New-Object System.Text.UTF8Encoding($false)).GetBytes($text))
        Test-Whitelisted -Path 'C:\Keep\A\x' | Should -BeTrue
        Test-Whitelisted -Path 'C:\Keep\B\x' | Should -BeTrue
        Test-Whitelisted -Path 'C:\Keep\C\x' | Should -BeFalse
    }

    It 'Protects a real folder name containing a defined %VAR% in its literal and expanded spelling (<Entry>)' -ForEach @(
        @{ Entry = 'C:\Users\Example\%APPDATA%\npm-cache'; Literal = 'C:\Users\Example\%APPDATA%\npm-cache\x'; Expanded = 'C:\Users\Example\C:\Users\Example\AppData\Roaming\npm-cache\x'; Other = 'C:\Users\Example\Other\x' }
        @{ Entry = 'C:\Data\%SWEEPR_TEST_DEFINED%'; Literal = 'C:\Data\%SWEEPR_TEST_DEFINED%\x'; Expanded = 'C:\Data\Value\x'; Other = 'C:\Data\Other\x' }
        @{ Entry = '"C:\Data\%SWEEPR_TEST_DEFINED%"'; Literal = 'C:\Data\%SWEEPR_TEST_DEFINED%\x'; Expanded = 'C:\Data\Value\x'; Other = 'C:\Data\Other\x' }
        @{ Entry = 'C:/Data/%SWEEPR_TEST_DEFINED%'; Literal = 'C:\Data\%SWEEPR_TEST_DEFINED%\x'; Expanded = 'C:\Data\Value\x'; Other = 'C:\Data\Other\x' }
    ) {
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value @($Entry)
        Test-Whitelisted -Path $Literal | Should -BeTrue
        Test-Whitelisted -Path $Expanded | Should -BeTrue
        Test-Whitelisted -Path $Other | Should -BeFalse
    }

    It 'Does not widen protection for a defined %VAR% in a relative entry' {
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value @('%SWEEPR_TEST_DEFINED%\Foo')
        Test-Whitelisted -Path 'C:\Foo\x' | Should -BeFalse
        Test-Whitelisted -Path 'C:\Users\Example\Foo\x' | Should -BeFalse
        Test-Whitelisted -Path 'C:\' | Should -BeFalse
    }

    It 'Reads a file with a <Kind> byte order mark' -ForEach @(
        @{ Kind = 'utf32le' }
        @{ Kind = 'utf32be' }
    ) {
        Write-EncodedFile -Path $script:Config.WhitelistFile -Kind $Kind -Lines @('C:\Daten\Übersicht', 'C:\Plain\Keep')
        Test-Whitelisted -Path 'C:\Daten\Übersicht\x' | Should -BeTrue
        Test-Whitelisted -Path 'C:\Plain\Keep\x' | Should -BeTrue
        Test-Whitelisted -Path 'C:\Plain\Other\x' | Should -BeFalse
    }

    # On Windows the default read share of File.ReadAllBytes would refuse this file; on Linux
    # the share modes are advisory, so there it passes either way.
    It 'Still reads a file that another process holds open for writing' {
        Write-EncodedFile -Path $script:Config.WhitelistFile -Kind 'utf8' -Lines @('C:\Held\Keep')
        $writer = New-Object System.IO.FileStream($script:Config.WhitelistFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try {
            Test-Whitelisted -Path 'C:\Held\Keep\x' | Should -BeTrue
            # Protected because the entry matches, not because the file counted as unreadable.
            Test-Whitelisted -Path 'C:\Held\Other\x' | Should -BeFalse
        }
        finally {
            $writer.Dispose()
        }
    }
}
