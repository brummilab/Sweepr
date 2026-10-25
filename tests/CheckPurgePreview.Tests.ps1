# Sweepr - F-03a: project artifacts as data (Get-SweeprPurgePreview)
#
# Fixes the interface that `sw check` builds on, before it exists. The discovery of `sw purge`
# (Find-Projects and its helpers) moves from bin/purge.ps1 to
#   lib/clean/projects.ps1  Get-SweeprPurgePreview -SearchPaths <string[]>
#                             [-MaxDepth <int> = 4] [-MaxSecondsPerRoot <int> = 15] [-MaxTotalSeconds <int>]
#                             [-MaxSizeFiles <int>]
#
# Result (one object, no prompt, no menu, no console output, nothing is removed):
#   Projects     [array]  sorted by TotalBytes, largest first:
#                         Path, Name, DisplayPath, Marker, TotalBytes [long], SizeComplete [bool],
#                         Artifacts: Path, Name, Type (Directory|File), Language, SizeBytes [long], SizeComplete [bool]
#   TotalBytes   [long]   sum over all projects
#   Roots        [array]  one per search root, in the given order: Path, Exists [bool], TimedOut [bool]
#   SkippedUnverified [int]  candidates left out because a safety check (Git) could not confirm them
#   Complete     [bool]   $false as soon as a time limit cut the search, a size is only a lower bound
#                         (-MaxSizeFiles) or a candidate stayed unverified
#
# Limits: -MaxDepth n searches n levels below a root (the root is level 0); a project at level n is
# found, one at level n+1 is not. A time limit of 0 seconds means the budget is already used up: the
# search of that root (or of all roots) does not start. -MaxSizeFiles n stops measuring one artifact
# after n files; SizeBytes is then what was counted and SizeComplete is $false.
# Without -SearchPaths the built-in default folders are searched, never the user's purge_paths.txt.
# Platform neutral: path identity checks and every changing cmdlet are mocked.

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:LibDir = Join-Path $script:Root 'lib'
    foreach ($module in @('core\base', 'core\log', 'core\ui', 'core\file_ops')) {
        . (Join-Path $script:LibDir "$module.ps1")
    }
    # Missing until F-03a is implemented: the tests then fail on the missing function, not on loading.
    $projectsScript = Join-Path $script:LibDir 'clean\projects.ps1'
    if (Test-Path -LiteralPath $projectsScript) { . $projectsScript }

    foreach ($name in @('Remove-AppxPackage', 'Stop-Service', 'Set-Service', 'Restart-Service', 'Remove-ItemProperty', 'Set-ItemProperty')) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:script:$name" -Value { param() }
        }
    }
    $script:ChangingCommands = @(
        'New-Item', 'Set-Content', 'Add-Content', 'Out-File', 'Move-Item', 'Copy-Item', 'Rename-Item', 'Clear-Content', 'New-ItemProperty', 'Stop-Service', 'Set-Service', 'Restart-Service',
        'Remove-Item', 'Start-Process', 'Stop-Process', 'Set-ItemProperty', 'Remove-ItemProperty',
        'Remove-SafeItem', 'Remove-SafeItems', 'Remove-SafeDirectoryTree', 'Clear-DirectoryContents', 'Clear-Host', 'Read-Host'
    )

    function script:Write-Bytes {
        param([string]$Path, [int]$Count)
        # Forward slashes work on every platform; a backslash is a file name character on Linux.
        $Path = $Path.Replace('\', '/')
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
        [IO.File]::WriteAllBytes($Path, (New-Object byte[] $Count))
    }
    # Loads one lib file in a brand-new PowerShell process, with nothing loaded before it.
    function script:Invoke-FreshLoad {
        param([string]$File, [string[]]$Functions)
        $dataDir = Join-Path $TestDrive 'fresh-data'
        [void][IO.Directory]::CreateDirectory($dataDir)
        $checks = ($Functions | ForEach-Object { "if (Get-Command $_ -CommandType Function -ErrorAction SilentlyContinue) { 'FOUND $_' } else { 'MISSING $_' }" }) -join '; '
        $command = "`$ErrorActionPreference = 'Stop'; . '" + $File.Replace("'", "''") + "'; $checks"
        $start = New-Object System.Diagnostics.ProcessStartInfo
        $start.FileName = (Get-Process -Id $PID).Path
        $start.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.EnvironmentVariables['SWEEPR_DATA_DIR'] = $dataDir
        $start.EnvironmentVariables['SWEEPR_NO_OPLOG'] = '1'
        $process = [System.Diagnostics.Process]::Start($start)
        try {
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(120000)) { $process.Kill(); throw 'fresh process timed out' }
            [void]$stdout.Wait(5000); [void]$stderr.Wait(5000)
            return [pscustomobject]@{ ExitCode = $process.ExitCode; Out = $stdout.Result; Err = $stderr.Result }
        }
        finally { $process.Dispose() }
    }

    function script:Find-Hit {
        param($Result, [string]$ProjectPath)
        @($Result.Projects | Where-Object { $_.Path -eq $ProjectPath })
    }
}

Describe 'Get-SweeprPurgePreview' {
    BeforeEach {
        $script:Base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:App = Join-Path $script:Base 'app'
        $script:Py = Join-Path $script:Base 'py'
        # app: Node project with 1500 bytes of node_modules; py: Python project with 3000 bytes of .venv
        Write-Bytes -Path (Join-Path $script:App 'package.json') -Count 10
        Write-Bytes -Path (Join-Path $script:App 'node_modules/a.js') -Count 1000
        Write-Bytes -Path (Join-Path $script:App 'node_modules\lib\b.js') -Count 500
        Write-Bytes -Path (Join-Path $script:Py 'requirements.txt') -Count 10
        Write-Bytes -Path (Join-Path $script:Py '.venv/bin/python') -Count 3000

        Mock Get-SweeprPathSnapshot { [pscustomobject]@{ Path = $Path } }
        Mock Test-SweeprPathSnapshot { $true }
        foreach ($name in $script:ChangingCommands) { Mock $name ([scriptblock]::Create("throw '$name must not run in a preview'")) }
    }

    Context 'Interface' {
        It 'Exists in lib/clean/projects.ps1 with the documented parameters' {
            $command = Get-Command Get-SweeprPurgePreview -ErrorAction SilentlyContinue
            $command | Should -Not -BeNullOrEmpty
            foreach ($parameter in @('SearchPaths', 'MaxDepth', 'MaxSecondsPerRoot', 'MaxTotalSeconds', 'MaxSizeFiles')) {
                $command.Parameters.Keys | Should -Contain $parameter
            }
        }
    }

    Context 'Result shape' {
        It 'Describes a project with its artifacts, sizes in bytes and language' {
            $result = Get-SweeprPurgePreview -SearchPaths @($script:Base)
            $project = Find-Hit $result $script:App
            $project.Count | Should -Be 1
            $project[0].Name | Should -Be 'app'
            $project[0].Marker | Should -Be 'package.json'
            $project[0].DisplayPath | Should -Not -BeNullOrEmpty
            $project[0].TotalBytes | Should -BeOfType [long]
            $project[0].TotalBytes | Should -Be 1500
            $project[0].SizeComplete | Should -BeTrue
            $artifacts = @($project[0].Artifacts)
            $artifacts.Count | Should -Be 1
            $artifacts[0].Name | Should -Be 'node_modules'
            $artifacts[0].Path | Should -Be (Join-Path $script:App 'node_modules')
            $artifacts[0].Type | Should -Be 'Directory'
            $artifacts[0].Language | Should -Be 'JavaScript/Node.js'
            $artifacts[0].SizeBytes | Should -BeOfType [long]
            $artifacts[0].SizeBytes | Should -Be 1500
            $artifacts[0].SizeComplete | Should -BeTrue
        }

        It 'Lists the largest project first and sums the total' {
            $result = Get-SweeprPurgePreview -SearchPaths @($script:Base)
            @($result.Projects | ForEach-Object Name) | Should -Be @('py', 'app')
            $result.TotalBytes | Should -BeOfType [long]
            $result.TotalBytes | Should -Be 4500
        }

        It 'Reports a file artifact such as a log file with its type and size' {
            Write-Bytes -Path (Join-Path $script:App 'debug.log') -Count 200
            $result = Get-SweeprPurgePreview -SearchPaths @($script:Base)
            $project = (Find-Hit $result $script:App)[0]
            $log = @($project.Artifacts | Where-Object Name -eq 'debug.log')
            $log.Count | Should -Be 1
            $log[0].Type | Should -Be 'File'
            $log[0].SizeBytes | Should -Be 200
            $project.TotalBytes | Should -Be 1700
        }

        It 'Does not list a folder without a project marker, and not a project without artifacts' {
            Write-Bytes -Path (Join-Path $script:Base 'plain\node_modules\x.js') -Count 100
            Write-Bytes -Path (Join-Path $script:Base 'clean\package.json') -Count 10
            $result = Get-SweeprPurgePreview -SearchPaths @($script:Base)
            @($result.Projects | ForEach-Object Name) | Should -Not -Contain 'plain'
            @($result.Projects | ForEach-Object Name) | Should -Not -Contain 'clean'
        }

        It 'Lists a project once when search roots overlap' {
            $result = Get-SweeprPurgePreview -SearchPaths @($script:Base, $script:App)
            @($result.Projects | Where-Object Path -eq $script:App).Count | Should -Be 1
            $result.TotalBytes | Should -Be 4500
            @($result.Roots).Count | Should -Be 2
        }

        It 'Reports every search root, also a missing one, without failing' {
            $missing = Join-Path $script:Base 'does-not-exist'
            $result = Get-SweeprPurgePreview -SearchPaths @($missing, $script:Base)
            @($result.Roots | ForEach-Object Path) | Should -Be @($missing, $script:Base)
            $result.Roots[0].Exists | Should -BeFalse
            $result.Roots[0].TimedOut | Should -BeFalse
            $result.Roots[1].Exists | Should -BeTrue
            $result.Roots[1].TimedOut | Should -BeFalse
            $result.Complete | Should -BeTrue
            $result.SkippedUnverified | Should -Be 0
        }
    }

    Context 'Limits' {
        BeforeEach {
            # Below a root: app and py are at level 1, depth1 at level 2, deep at level 3.
            Write-Bytes -Path (Join-Path $script:Base 'level1\depth1\package.json') -Count 10
            Write-Bytes -Path (Join-Path $script:Base 'level1\depth1\node_modules\a') -Count 100
            Write-Bytes -Path (Join-Path $script:Base 'x\y\deep\package.json') -Count 10
            Write-Bytes -Path (Join-Path $script:Base 'x\y\deep\node_modules\a') -Count 100
        }

        It 'Searches down to level <Depth> below a root' -TestCases @(
            @{ Depth = 1; Expected = @('app', 'py') }
            @{ Depth = 2; Expected = @('app', 'depth1', 'py') }
            @{ Depth = 3; Expected = @('app', 'deep', 'depth1', 'py') }
        ) {
            param($Depth, $Expected)
            $result = Get-SweeprPurgePreview -SearchPaths @($script:Base) -MaxDepth $Depth
            @($result.Projects | ForEach-Object Name | Sort-Object) | Should -Be $Expected
        }

        It 'Finds the deep project by default (depth 4)' {
            $result = Get-SweeprPurgePreview -SearchPaths @($script:Base)
            @($result.Projects | ForEach-Object Name) | Should -Contain 'deep'
        }

        It 'Does not start a root whose time budget is already used up' {
            $result = Get-SweeprPurgePreview -SearchPaths @($script:Base) -MaxSecondsPerRoot 0
            @($result.Projects).Count | Should -Be 0
            $result.Roots[0].TimedOut | Should -BeTrue
            $result.Complete | Should -BeFalse
        }

        It 'Does not start any root once the total time budget is used up' {
            $second = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            Write-Bytes -Path (Join-Path $second 'other\package.json') -Count 10
            Write-Bytes -Path (Join-Path $second 'other\node_modules\a') -Count 100
            $result = Get-SweeprPurgePreview -SearchPaths @($script:Base, $second) -MaxTotalSeconds 0
            @($result.Projects).Count | Should -Be 0
            @($result.Roots).Count | Should -Be 2
            @($result.Roots | Where-Object TimedOut).Count | Should -Be 2
            $result.Complete | Should -BeFalse
        }

        It 'Keeps a normal run complete and unlimited by time within the defaults' {
            $result = Get-SweeprPurgePreview -SearchPaths @($script:Base)
            $result.Complete | Should -BeTrue
            @($result.Roots | Where-Object TimedOut).Count | Should -Be 0
        }

        It 'Measures an artifact only up to the file limit and says the size is a lower bound' {
            foreach ($index in 1..10) { Write-Bytes -Path (Join-Path $script:Py "venv\file$index") -Count 100 }
            $result = Get-SweeprPurgePreview -SearchPaths @($script:Py) -MaxSizeFiles 3
            $project = (Find-Hit $result $script:Py)[0]
            $venv = @($project.Artifacts | Where-Object Name -eq 'venv')[0]
            $venv | Should -Not -BeNullOrEmpty -Because 'a truncated measurement still reports the artifact'
            $venv.SizeComplete | Should -BeFalse
            $venv.SizeBytes | Should -BeGreaterThan 0
            $venv.SizeBytes | Should -BeLessThan 1000
            $project.SizeComplete | Should -BeFalse
            $result.Complete | Should -BeFalse
        }

        It 'Measures the full size when the limit is not reached' {
            foreach ($index in 1..10) { Write-Bytes -Path (Join-Path $script:Py "venv\file$index") -Count 100 }
            $result = Get-SweeprPurgePreview -SearchPaths @($script:Py) -MaxSizeFiles 50
            $venv = @((Find-Hit $result $script:Py)[0].Artifacts | Where-Object Name -eq 'venv')[0]
            $venv.SizeComplete | Should -BeTrue
            $venv.SizeBytes | Should -Be 1000
            $result.Complete | Should -BeTrue
        }
    }

    Context 'Unverified candidates' {
        It 'Leaves out an artifact in a repository when Git cannot confirm it, and says so' {
            [void][IO.Directory]::CreateDirectory((Join-Path $script:App '.git'))
            Mock Invoke-PurgeGit { $null }
            $result = Get-SweeprPurgePreview -SearchPaths @($script:App)
            @($result.Projects).Count | Should -Be 0
            $result.SkippedUnverified | Should -BeGreaterThan 0
            $result.Complete | Should -BeFalse
        }
    }

    Context 'Search folders' {
        It 'Searches the built-in default folders, not the purge_paths.txt of the user' {
            # The defaults are replaced by an empty folder of the test, so no real folder is searched.
            $defaults = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($defaults)
            $config = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($config)
            [IO.File]::WriteAllText((Join-Path $config 'purge_paths.txt'), $script:Base)
            $script:ConfigFile = Join-Path $config 'purge_paths.txt'
            $savedConfigPath = $script:Config.ConfigPath
            $savedDefaults = $script:DefaultSearchPaths
            try {
                $script:Config.ConfigPath = $config
                $script:DefaultSearchPaths = @($defaults)
                $result = Get-SweeprPurgePreview
            }
            finally {
                $script:Config.ConfigPath = $savedConfigPath
                $script:DefaultSearchPaths = $savedDefaults
            }
            @($result.Roots | ForEach-Object Path) | Should -Be @($defaults)
            @($result.Projects | ForEach-Object Path) | Should -Not -Contain $script:App
        }
    }

    Context 'Read-only and non-interactive' {
        It 'Returns one object and writes nothing to the console' {
            $all = @(Get-SweeprPurgePreview -SearchPaths @($script:Base) *>&1)
            @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }).Count | Should -Be 0
            @($all | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] }).Count | Should -Be 1
        }

        It 'Removes nothing, calls no changing cmdlet, asks nothing and never clears the screen' {
            Set-DryRunMode -Enabled $false
            $null = Get-SweeprPurgePreview -SearchPaths @($script:Base)
            Test-Path -LiteralPath (Join-Path $script:App 'node_modules/a.js') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $script:Py '.venv/bin/python') | Should -BeTrue
            foreach ($name in $script:ChangingCommands) {
                Should -Invoke -CommandName $name -Times 0 -Exactly
            }
        }
    }
}

Describe 'lib/clean/projects.ps1 on its own' {
    It 'Loads on its own in a new process and defines its functions' {
        $result = Invoke-FreshLoad -File (Join-Path $script:LibDir 'clean\projects.ps1') -Functions @('Get-SweeprPurgePreview', 'Find-Projects')
        $result.Err | Should -BeNullOrEmpty
        $result.ExitCode | Should -Be 0
        foreach ($name in @('Get-SweeprPurgePreview', 'Find-Projects')) {
            $result.Out | Should -Match "FOUND $name"
        }
    }
}
