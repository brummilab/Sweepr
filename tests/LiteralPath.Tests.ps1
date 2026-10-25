# Sweepr - own data paths are literal paths (F-01h)
# With the portable/override modes the data folder can have any name, also with
# [ and ]. Those characters are wildcards for -Path, so every access to Sweepr's
# own folders and files has to use -LiteralPath.
# Platform neutral: only TestDrive, environment variables and AST-loaded functions.
# USERPROFILE and SWEEPR_DATA_DIR are restored afterwards.

BeforeAll {
    $script:ProjectRoot = Split-Path -Parent $PSScriptRoot
    $script:SavedProfile = $env:USERPROFILE
    $script:SavedDataDir = $env:SWEEPR_DATA_DIR
    $script:SavedConfig = $null
    if (Get-Variable -Name Config -Scope Script -ErrorAction SilentlyContinue) { $script:SavedConfig = $script:Config }

    function script:Get-Ast {
        param([string]$RelativePath)
        $file = Join-Path $script:ProjectRoot $RelativePath
        return [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
    }

    function script:Get-FunctionAst {
        param($Ast, [string]$Name)
        return $Ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true)
    }

    # All commands with the given name below a node, with their parameter names.
    function script:Get-CommandUse {
        param($Node, [string[]]$Name)
        $commands = $Node.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in $Name
            }, $true)
        foreach ($command in $commands) {
            $parameters = @($command.CommandElements |
                    Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } |
                    ForEach-Object { $_.ParameterName })
            $literal = $false
            foreach ($p in $parameters) {
                if ($p.Length -ge 2 -and 'LiteralPath'.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) { $literal = $true }
            }
            [pscustomobject]@{
                Name       = $command.GetCommandName()
                Line       = $command.Extent.StartLineNumber
                Text       = $command.Extent.Text
                Parameters = $parameters
                Literal    = $literal
            }
        }
    }

    function script:Import-ScriptFunction {
        param([string]$RelativePath, [string]$Name)
        $definition = Get-FunctionAst -Ast (Get-Ast $RelativePath) -Name $Name
        $definition | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($definition.Extent.Text))
        Set-Item -Path "function:script:$Name" -Value (Get-Item "function:$Name").ScriptBlock
    }

    function script:Reset-BaseWithDataDir {
        param([string]$DataDir)
        $env:SWEEPR_DATA_DIR = $DataDir
        $script:SWEEPR_BASE_LOADED = $false
        . (Join-Path $script:ProjectRoot 'lib\core\base.ps1')
    }

    $script:SWEEPR_BASE_LOADED = $false
    . (Join-Path $script:ProjectRoot 'lib\core\base.ps1')
}

AfterAll {
    $env:USERPROFILE = $script:SavedProfile
    $env:SWEEPR_DATA_DIR = $script:SavedDataDir
    $script:SWEEPR_BASE_LOADED = $false
    if ($null -ne $script:SavedConfig) { $script:Config = $script:SavedConfig }
}

Describe 'Get-ConfigPath and Get-CachePath with brackets in the data folder' {
    BeforeEach {
        $script:Case = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:UserHome = Join-Path $script:Case 'home'
        New-Item -ItemType Directory -Path $script:UserHome -Force | Out-Null
        $env:USERPROFILE = $script:UserHome
        $script:Data = Join-Path $script:Case 'Apps [x]'
        $script:Lookalike = Join-Path $script:Case 'Apps x'
    }

    AfterEach {
        $env:USERPROFILE = $script:SavedProfile
        $env:SWEEPR_DATA_DIR = $script:SavedDataDir
    }

    It 'Creates the config folder when the data folder has brackets' {
        Reset-BaseWithDataDir -DataDir $script:Data
        $path = Get-ConfigPath
        $path | Should -BeExactly $script:Config.ConfigPath
        Test-Path -LiteralPath $path -PathType Container | Should -BeTrue
    }

    It 'Creates the cache folder when the data folder has brackets' {
        Reset-BaseWithDataDir -DataDir $script:Data
        $path = Get-CachePath
        $path | Should -BeExactly $script:Config.CachePath
        Test-Path -LiteralPath $path -PathType Container | Should -BeTrue
    }

    It 'Still creates the config folder when a wildcard look-alike folder exists' {
        New-Item -ItemType Directory -Path (Join-Path $script:Lookalike 'config') -Force | Out-Null
        Reset-BaseWithDataDir -DataDir $script:Data
        Test-Path -LiteralPath $script:Config.ConfigPath | Should -BeFalse
        Get-ConfigPath | Out-Null
        Test-Path -LiteralPath $script:Config.ConfigPath -PathType Container | Should -BeTrue
    }

    It 'Still creates the cache folder when a wildcard look-alike folder exists' {
        New-Item -ItemType Directory -Path (Join-Path $script:Lookalike 'cache') -Force | Out-Null
        Reset-BaseWithDataDir -DataDir $script:Data
        Test-Path -LiteralPath $script:Config.CachePath | Should -BeFalse
        Get-CachePath | Out-Null
        Test-Path -LiteralPath $script:Config.CachePath -PathType Container | Should -BeTrue
    }

    It 'Does not write into the look-alike folder' {
        New-Item -ItemType Directory -Path (Join-Path $script:Lookalike 'config') -Force | Out-Null
        Reset-BaseWithDataDir -DataDir $script:Data
        Get-ConfigPath | Out-Null
        Get-CachePath | Out-Null
        @(Get-ChildItem -LiteralPath (Join-Path $script:Lookalike 'config') -Force).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:Lookalike 'cache') | Should -BeFalse
    }
}

Describe 'purge_paths.txt in a data folder with brackets' {
    BeforeAll {
        Import-ScriptFunction -RelativePath 'bin\purge.ps1' -Name 'Get-SearchPaths'
        Import-ScriptFunction -RelativePath 'bin\purge.ps1' -Name 'Edit-SearchPaths'
        function script:Write-Info { param($Message) }
        function script:Write-Success { param($Message) }
    }

    BeforeEach {
        $script:Case = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:ConfigDir = Join-Path $script:Case 'Apps [x]/config'
        $script:LookalikeDir = Join-Path $script:Case 'Apps x/config'
        New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
        $script:ConfigFile = Join-Path $script:ConfigDir 'purge_paths.txt'
        $script:DefaultSearchPaths = @()
        Mock Start-Process {}
    }

    It 'Creates purge_paths.txt in the bracket folder' {
        Edit-SearchPaths
        Test-Path -LiteralPath $script:ConfigFile -PathType Leaf | Should -BeTrue
        (Get-Content -LiteralPath $script:ConfigFile -Raw) | Should -Match 'Sweepr Purge - Custom Search Paths'
    }

    It 'Creates purge_paths.txt even when a look-alike folder has one' {
        New-Item -ItemType Directory -Path $script:LookalikeDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:LookalikeDir 'purge_paths.txt') -Value 'other'
        Edit-SearchPaths
        Test-Path -LiteralPath $script:ConfigFile -PathType Leaf | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $script:LookalikeDir 'purge_paths.txt') -Raw).Trim() | Should -BeExactly 'other'
    }

    It 'Keeps an existing purge_paths.txt untouched' {
        Set-Content -LiteralPath $script:ConfigFile -Value 'keep me'
        Edit-SearchPaths
        (Get-Content -LiteralPath $script:ConfigFile -Raw).Trim() | Should -BeExactly 'keep me'
    }

    It 'Reads the search paths from purge_paths.txt in the bracket folder' {
        $project = Join-Path $script:Case 'projects'
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        Set-Content -LiteralPath $script:ConfigFile -Value @('# comment', $project)
        @(Get-SearchPaths) | Should -Be @($project)
    }

    It 'Ignores a look-alike purge_paths.txt when the real one is missing' {
        $other = Join-Path $script:Case 'other-projects'
        New-Item -ItemType Directory -Path $script:LookalikeDir, $other -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:LookalikeDir 'purge_paths.txt') -Value $other
        @(Get-SearchPaths).Count | Should -Be 0
    }

    It 'Accepts a custom search path that has brackets in its name' {
        $project = Join-Path $script:Case 'Code [old]'
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        Set-Content -LiteralPath $script:ConfigFile -Value $project
        @(Get-SearchPaths) | Should -Be @($project)
    }
}

Describe 'Own data paths use -LiteralPath in the source' {
    It 'Writes clean-list.txt with Set-Content -LiteralPath' {
        $ast = Get-Ast 'bin\clean.ps1'
        $uses = @(Get-CommandUse -Node $ast -Name 'Set-Content' | Where-Object { $_.Text -match 'ExportListFile' })
        $uses.Count | Should -BeGreaterThan 0
        foreach ($use in $uses) { $use.Literal | Should -BeTrue -Because "bin/clean.ps1:$($use.Line) writes clean-list.txt" }
    }

    It 'Checks the clean-list.txt folder with Test-Path -LiteralPath' {
        $ast = Get-Ast 'bin\clean.ps1'
        $uses = @(Get-CommandUse -Node $ast -Name 'Test-Path' | Where-Object { $_.Text -match 'exportDir' })
        $uses.Count | Should -BeGreaterThan 0
        foreach ($use in $uses) { $use.Literal | Should -BeTrue -Because "bin/clean.ps1:$($use.Line)" }
    }

    It 'Accesses purge_paths.txt with -LiteralPath in Get-SearchPaths and Edit-SearchPaths' {
        $ast = Get-Ast 'bin\purge.ps1'
        foreach ($name in 'Get-SearchPaths', 'Edit-SearchPaths') {
            $function = Get-FunctionAst -Ast $ast -Name $name
            $uses = @(Get-CommandUse -Node $function -Name 'Test-Path', 'Get-Content', 'Set-Content')
            $uses.Count | Should -BeGreaterThan 0
            foreach ($use in $uses) {
                $use.Literal | Should -BeTrue -Because "bin/purge.ps1:$($use.Line) in ${name}: $($use.Text)"
            }
        }
    }

    It 'Uses -LiteralPath for the config and cache folder checks in base.ps1' {
        $ast = Get-Ast 'lib\core\base.ps1'
        foreach ($name in 'Get-ConfigPath', 'Get-CachePath') {
            $function = Get-FunctionAst -Ast $ast -Name $name
            $uses = @(Get-CommandUse -Node $function -Name 'Test-Path')
            $uses.Count | Should -BeGreaterThan 0
            foreach ($use in $uses) {
                $use.Literal | Should -BeTrue -Because "lib/core/base.ps1:$($use.Line) in ${name}: $($use.Text)"
            }
        }
    }
}
