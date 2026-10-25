# Sweepr - F-03a: read-only cleanup potential as data (Get-SweeprCleanPreview)
#
# Fixes the interface that `sw check` builds on, before it exists:
#   lib/clean/preview.ps1  Get-SweeprCleanPreview [-System] [-SkipExternalTools] [-GameMedia] [-GpuShaders]
#
# Result (one object, nothing else on the pipeline, nothing on the console):
#   DryRun       [bool]   always $true
#   IsAdmin      [bool]
#   Sections     [array]  one per cleanup section that ran, in run order:
#                         Name, Hits, TotalBytes [long], Count [int]
#   Hits         [array]  all hits of all sections, in discovery order:
#                         Section, Description, Path, SizeBytes [long], Count [int]
#                         (Count = files below the path, 1 for a file)
#   TotalBytes   [long]   sum over all hits
#   Count        [int]    sum over all hits
#   NotMeasured  [array]  Section, Name, Reason; Reason is 'external tool' (skipped on request,
#                         Name = npm, pnpm, pip, go, mise) or 'needs administrator' (-System without admin,
#                         Section = Name = 'System cleanup')
#
# The function switches dry-run mode on for its own duration and restores the previous mode. It never
# writes the clean-list file, never clears the screen and never asks anything. Platform neutral:
# path identity checks and every changing cmdlet are mocked; the temp fixtures live in $TestDrive.

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:LibDir = Join-Path $script:Root 'lib'
    foreach ($module in @('core\base', 'core\log', 'core\ui', 'core\file_ops', 'clean\user', 'clean\caches', 'clean\dev', 'clean\apps', 'clean\system')) {
        . (Join-Path $script:LibDir "$module.ps1")
    }
    # Missing until F-03a is implemented: the tests then fail on the missing function, not on loading.
    $previewScript = Join-Path $script:LibDir 'clean\preview.ps1'
    if (Test-Path -LiteralPath $previewScript) { . $previewScript }

    # Commands that exist on Windows only get a stub so that Pester can mock them everywhere.
    foreach ($name in @('Remove-AppxPackage', 'Stop-Service', 'Set-Service', 'Restart-Service', 'Disable-WindowsOptionalFeature', 'Remove-ItemProperty', 'Set-ItemProperty')) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:script:$name" -Value { param() }
        }
    }
    $script:ChangingCommands = @(
        'New-Item', 'Set-Content', 'Add-Content', 'Out-File', 'Move-Item', 'Copy-Item', 'Rename-Item', 'Clear-Content', 'New-ItemProperty',
        'Remove-Item', 'Clear-RecycleBin', 'Remove-AppxPackage', 'Start-Process', 'Stop-Process', 'Stop-Service',
        'Set-Service', 'Restart-Service', 'Disable-WindowsOptionalFeature', 'Set-ItemProperty', 'Remove-ItemProperty',
        'Remove-SafeDirectoryTree', 'Clear-Host', 'Read-Host'
    )
    # The real section functions, kept before any test replaces them with a mock.
    $script:RealInvokeUserCleanup = ${function:Invoke-UserCleanup}
    $script:RealInvokeDevToolsCleanup = ${function:Invoke-DevToolsCleanup}
    $script:RealInvokeSystemCleanup = ${function:Invoke-SystemCleanup}

    # A section as the real cleanup modules run it: titled, removing through the shared dry-run sink.
    function script:Invoke-FakeSection {
        param([string]$Title, [string]$Description, [string[]]$Paths)
        Start-Section $Title
        if ($Paths) { Remove-SafeItems -Paths $Paths -Description $Description }
        Stop-Section
    }
    function script:Write-Bytes {
        param([string]$Path, [int]$Count, [int]$DaysOld = 0)
        # Forward slashes work on every platform; a backslash is a file name character on Linux.
        $Path = $Path.Replace('\', '/')
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
        [IO.File]::WriteAllBytes($Path, (New-Object byte[] $Count))
        if ($DaysOld -gt 0) { (Get-Item -LiteralPath $Path).LastWriteTime = (Get-Date).AddDays(-$DaysOld) }
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

    $script:SavedEnv = @{}
    foreach ($name in @('TEMP', 'TMP', 'LOCALAPPDATA', 'APPDATA', 'USERPROFILE', 'ProgramData', 'WINDIR')) {
        $script:SavedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
    }
}

AfterAll {
    foreach ($name in $script:SavedEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $script:SavedEnv[$name]) }
    Set-DryRunMode -Enabled $false
}

Describe 'Get-SweeprCleanPreview' {
    BeforeEach {
        # A private profile per test; nothing below points at the real machine.
        $script:FakeHome = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $env:USERPROFILE = $script:FakeHome
        $env:TEMP = Join-Path $script:FakeHome 'tmp'
        $env:TMP = $env:TEMP
        $env:LOCALAPPDATA = Join-Path $script:FakeHome 'Local'
        $env:APPDATA = Join-Path $script:FakeHome 'Roaming'
        $env:ProgramData = Join-Path $script:FakeHome 'ProgramData'
        $env:WINDIR = Join-Path $script:FakeHome 'Windows'
        [void][IO.Directory]::CreateDirectory($env:TEMP)

        $script:FileA = Join-Path $script:FakeHome 'work\a.log'
        $script:FileB = Join-Path $script:FakeHome 'work\b.bin'
        $script:CacheDir = Join-Path $script:FakeHome 'work\cache'
        $script:SysFile = Join-Path $script:FakeHome 'work\system.tmp'
        Write-Bytes -Path $script:FileA -Count 1000
        Write-Bytes -Path $script:FileB -Count 2000
        Write-Bytes -Path (Join-Path $script:CacheDir 'one') -Count 10
        Write-Bytes -Path (Join-Path $script:CacheDir 'two') -Count 20
        Write-Bytes -Path (Join-Path $script:CacheDir 'sub/three') -Count 30
        Write-Bytes -Path $script:SysFile -Count 4000

        # The clean command would announce this list; a preview must not create it.
        $script:ExportListFile = Join-Path $script:FakeHome 'clean-list.txt'
        $script:SeenDryRun = $null
        Set-DryRunMode -Enabled $false
        Reset-CleanupStats

        # Identity checks use Win32 file IDs; the paths themselves stay real.
        Mock Get-SweeprPathSnapshot { [pscustomobject]@{ Path = $Path } }
        Mock Test-SweeprPathSnapshot { $true }
        Mock Test-IsAdmin { $false }
        foreach ($name in $script:ChangingCommands) { Mock $name ([scriptblock]::Create("throw '$name must not run in a preview'")) }

        Mock Invoke-SweeprOwnerProcess { $null }
        Mock Invoke-UserCleanup {
            $script:SeenDryRun = Test-DryRunMode
            Invoke-FakeSection 'User essentials' 'User temp files' @($script:FileA, $script:FileB)
        }
        Mock Clear-BrowserCaches { Invoke-FakeSection 'Browser caches' 'Browser cache' @($script:CacheDir) }
        Mock Clear-AppCaches { Invoke-FakeSection 'Application caches' 'Application cache' @() }
        Mock Invoke-DevToolsCleanup { Invoke-FakeSection 'Developer tools' 'Developer cache' @() }
        Mock Invoke-AppCleanup { Invoke-FakeSection 'Applications' 'Application data' @() }
        Mock Clear-GPUShaderCaches { Invoke-FakeSection 'GPU shader caches' 'Shader cache' @() }
        Mock Invoke-SystemCleanup { Invoke-FakeSection 'System cleanup' 'Windows temp files' @($script:SysFile) }
    }

    Context 'Interface' {
        It 'Exists in lib/clean/preview.ps1 with the documented switches' {
            $command = Get-Command Get-SweeprCleanPreview -ErrorAction SilentlyContinue
            $command | Should -Not -BeNullOrEmpty
            foreach ($parameter in @('System', 'SkipExternalTools', 'GameMedia', 'GpuShaders')) {
                $command.Parameters.Keys | Should -Contain $parameter
                $command.Parameters[$parameter].SwitchParameter | Should -BeTrue -Because "-$parameter is a switch"
            }
        }
    }

    Context 'Result shape' {
        It 'Returns exactly one object and writes nothing to the console' {
            $all = @(Get-SweeprCleanPreview *>&1)
            @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }).Count | Should -Be 0
            @($all | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] }).Count | Should -Be 1
            $result = $all | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] }
            foreach ($property in @('DryRun', 'IsAdmin', 'Sections', 'Hits', 'TotalBytes', 'Count', 'NotMeasured')) {
                $result.PSObject.Properties.Name | Should -Contain $property
            }
            $result.DryRun | Should -BeTrue
            $result.IsAdmin | Should -BeFalse
        }

        It 'Lists every section that ran, in run order, and none that did not' {
            $result = Get-SweeprCleanPreview
            @($result.Sections | ForEach-Object Name) | Should -Be @('User essentials', 'Browser caches', 'Application caches', 'Developer tools', 'Applications')
        }

        It 'Describes a file hit with section, description, full path, size in bytes and count' {
            $result = Get-SweeprCleanPreview
            $hit = @($result.Hits | Where-Object { $_.Path -eq $script:FileA })
            $hit.Count | Should -Be 1
            $hit[0].Section | Should -Be 'User essentials'
            $hit[0].Description | Should -Be 'User temp files'
            $hit[0].SizeBytes | Should -BeOfType [long]
            $hit[0].SizeBytes | Should -Be 1000
            $hit[0].Count | Should -Be 1
        }

        It 'Measures a folder hit as the bytes and the number of files below it' {
            $result = Get-SweeprCleanPreview
            $hit = @($result.Hits | Where-Object { $_.Path -eq $script:CacheDir })
            $hit.Count | Should -Be 1
            $hit[0].Section | Should -Be 'Browser caches'
            $hit[0].SizeBytes | Should -Be 60
            $hit[0].Count | Should -Be 3
        }

        It 'Sums bytes and counts per section' {
            $result = Get-SweeprCleanPreview
            $user = $result.Sections | Where-Object Name -eq 'User essentials'
            $user.TotalBytes | Should -BeOfType [long]
            $user.TotalBytes | Should -Be 3000
            $user.Count | Should -Be 2
            @($user.Hits).Count | Should -Be 2
            $browser = $result.Sections | Where-Object Name -eq 'Browser caches'
            $browser.TotalBytes | Should -Be 60
            $browser.Count | Should -Be 3
        }

        It 'Reports a section without hits as zero, not as missing' {
            $result = Get-SweeprCleanPreview
            foreach ($name in @('Application caches', 'Developer tools', 'Applications')) {
                $section = $result.Sections | Where-Object Name -eq $name
                $section | Should -Not -BeNullOrEmpty -Because "$name ran"
                $section.TotalBytes | Should -Be 0
                $section.Count | Should -Be 0
                @($section.Hits).Count | Should -Be 0
            }
        }

        It 'Adds up all sections into the totals and a flat hit list' {
            $result = Get-SweeprCleanPreview
            $result.TotalBytes | Should -Be 3060
            $result.Count | Should -Be 5
            @($result.Hits).Count | Should -Be 3
            @($result.NotMeasured).Count | Should -Be 0
        }

        It 'Gives the same answer when called twice (no accumulation in the global statistics)' {
            $first = Get-SweeprCleanPreview
            $second = Get-SweeprCleanPreview
            $second.TotalBytes | Should -Be $first.TotalBytes
            @($second.Hits).Count | Should -Be @($first.Hits).Count
        }
    }

    Context 'Read-only guarantee' {
        It 'Runs in dry-run mode even when the caller is not, and restores the caller mode' {
            Set-DryRunMode -Enabled $false
            $null = Get-SweeprCleanPreview
            $script:SeenDryRun | Should -BeTrue
            Test-DryRunMode | Should -BeFalse
        }

        It 'Leaves the caller dry-run mode on when it was on' {
            Set-DryRunMode -Enabled $true
            $null = Get-SweeprCleanPreview
            Test-DryRunMode | Should -BeTrue
        }

        It 'Removes nothing and calls no changing cmdlet' {
            $null = Get-SweeprCleanPreview
            foreach ($path in @($script:FileA, $script:FileB, $script:SysFile)) {
                Test-Path -LiteralPath $path | Should -BeTrue
            }
            Test-Path -LiteralPath (Join-Path $script:CacheDir 'sub/three') | Should -BeTrue
            foreach ($name in $script:ChangingCommands) {
                Should -Invoke -CommandName $name -Times 0 -Exactly
            }
        }

        It 'Neither writes the clean-list file nor clears the screen, and leaves the list location as it was' {
            $before = $script:ExportListFile
            $null = Get-SweeprCleanPreview
            Test-Path -LiteralPath $script:ExportListFile | Should -BeFalse
            $script:ExportListFile | Should -Be $before
            Should -Invoke Clear-Host -Times 0 -Exactly
            Should -Invoke Read-Host -Times 0 -Exactly
        }
    }

    Context 'Real user cleanup' {
        It 'Counts an old file in the temp folder and ignores a fresh one' {
            # The user section runs unmocked; the other sections stay empty.
            Mock Invoke-UserCleanup { & $script:RealInvokeUserCleanup @PSBoundParameters }
            $old = Join-Path $env:TEMP 'old.tmp'
            $fresh = Join-Path $env:TEMP 'fresh.tmp'
            Write-Bytes -Path $old -Count 100 -DaysOld 30
            Write-Bytes -Path $fresh -Count 500
            $result = Get-SweeprCleanPreview
            $hits = @($result.Hits | Where-Object { $_.Section -eq 'User essentials' })
            @($hits | ForEach-Object Path) | Should -Contain $old
            @($hits | ForEach-Object Path) | Should -Not -Contain $fresh
            ($hits | Where-Object Path -eq $old).SizeBytes | Should -Be 100
            ($hits | Where-Object Path -eq $old).Count | Should -Be 1
            Test-Path -LiteralPath $old | Should -BeTrue
        }
    }

    Context '-System' {
        It 'Leaves the system section out by default' {
            Mock Test-IsAdmin { $true }
            $result = Get-SweeprCleanPreview
            Should -Invoke Invoke-SystemCleanup -Times 0 -Exactly
            @($result.Sections | ForEach-Object Name) | Should -Not -Contain 'System cleanup'
            @($result.NotMeasured).Count | Should -Be 0
            $result.IsAdmin | Should -BeTrue
        }

        It 'Adds the system section as an administrator, still read-only' {
            Mock Test-IsAdmin { $true }
            Set-DryRunMode -Enabled $false
            $result = Get-SweeprCleanPreview -System
            Should -Invoke Invoke-SystemCleanup -Times 1 -Exactly
            $section = $result.Sections | Where-Object Name -eq 'System cleanup'
            $section.TotalBytes | Should -Be 4000
            ($result.Hits | Where-Object Path -eq $script:SysFile).Section | Should -Be 'System cleanup'
            $result.TotalBytes | Should -Be 7060
            @($result.NotMeasured).Count | Should -Be 0
            Test-Path -LiteralPath $script:SysFile | Should -BeTrue
        }

        It 'Marks the system section as not measured without administrator rights, and does not elevate' {
            $result = Get-SweeprCleanPreview -System
            Should -Invoke Invoke-SystemCleanup -Times 0 -Exactly
            Should -Invoke Start-Process -Times 0 -Exactly
            $entry = @($result.NotMeasured | Where-Object Section -eq 'System cleanup')
            $entry.Count | Should -Be 1
            $entry[0].Name | Should -Be 'System cleanup'
            $entry[0].Reason | Should -Be 'needs administrator'
            $result.IsAdmin | Should -BeFalse
            @($result.Sections | ForEach-Object Name) | Should -Contain 'User essentials'
            $result.TotalBytes | Should -Be 3060
        }
    }

    Context '-System with the optional system tools' {
        It 'Does not list DISM or Disk Cleanup for -System, because sw clean never runs them' {
            Mock Test-IsAdmin { $true }
            Mock Invoke-SystemCleanup { & $script:RealInvokeSystemCleanup @PSBoundParameters }
            foreach ($name in @('Clear-SystemTempFiles', 'Clear-WindowsLogs', 'Clear-InstallerCache', 'Clear-MemoryDumps', 'Invoke-ComponentStoreCleanup', 'Invoke-DiskCleanupTool')) {
                Mock $name {}
            }
            $result = Get-SweeprCleanPreview -System
            Should -Invoke Invoke-ComponentStoreCleanup -Times 0 -Exactly
            Should -Invoke Invoke-DiskCleanupTool -Times 0 -Exactly
            Should -Invoke Start-Process -Times 0 -Exactly
            @($result.NotMeasured | Where-Object { $_.Name -in @('Component Store cleanup', 'Disk Cleanup tool') }).Count | Should -Be 0
            @($result.NotMeasured).Count | Should -Be 0
        }

        It 'Reports the optional DISM and Disk Cleanup parts as not previewable in a dry run and starts nothing' {
            # Called directly with the options, as a future caller could: the real tool functions run their dry-run path.
            Mock Test-IsAdmin { $true }
            foreach ($name in @('Clear-SystemTempFiles', 'Clear-WindowsLogs', 'Clear-InstallerCache', 'Clear-MemoryDumps')) { Mock $name {} }
            $collected = New-Object System.Collections.Generic.List[object]
            Set-DryRunMode -Enabled $true
            $script:NotMeasuredCollector = $collected
            try { & $script:RealInvokeSystemCleanup -IncludeComponentStore -IncludeDiskCleanup 6>$null }
            finally { $script:NotMeasuredCollector = $null; Set-DryRunMode -Enabled $false }
            Should -Invoke Start-Process -Times 0 -Exactly
            foreach ($name in @('Component Store cleanup', 'Disk Cleanup tool')) {
                $entry = @($collected.ToArray() | Where-Object Name -eq $name)
                $entry.Count | Should -Be 1
                $entry[0].Section | Should -Be 'System cleanup'
                $entry[0].Reason | Should -Be 'not previewable'
            }
        }

        It 'Does not mention them without -System' {
            Mock Test-IsAdmin { $true }
            $result = Get-SweeprCleanPreview
            @($result.NotMeasured).Count | Should -Be 0
        }
    }

    Context 'A section that throws' {
        It 'Puts mode, statistics and collector back, keeps the earlier hits and reports the error' {
            $script:ExportListFile = $null
            Set-DryRunMode -Enabled $true
            Remove-SafeItems -Paths @($script:FileA) -Description 'caller work'
            $statsBefore = Get-CleanupStats
            Set-DryRunMode -Enabled $false
            Mock Clear-BrowserCaches { throw 'boom' }

            $result = Get-SweeprCleanPreview -SkipExternalTools

            Test-DryRunMode | Should -BeFalse
            $statsAfter = Get-CleanupStats
            foreach ($key in @('TotalSizeKB', 'FilesCleaned', 'TotalItems')) { $statsAfter[$key] | Should -Be $statsBefore[$key] }
            @($result.NotMeasured | Where-Object { $_.Reason -match 'boom' }).Count | Should -Be 1
            ($result.Sections | Where-Object Name -eq 'User essentials').TotalBytes | Should -Be 3000
            Test-Path -LiteralPath $script:FileA | Should -BeTrue

            # Nothing of the failed run is left behind for the next one.
            Mock Clear-BrowserCaches { Invoke-FakeSection 'Browser caches' 'Browser cache' @($script:CacheDir) }
            $next = Get-SweeprCleanPreview
            $next.TotalBytes | Should -Be 3060
            @($next.NotMeasured).Count | Should -Be 0
        }

        It 'Leaves a caller that is in a dry run in that dry run' {
            Set-DryRunMode -Enabled $true
            Mock Invoke-UserCleanup { throw 'boom' }
            $null = Get-SweeprCleanPreview
            Test-DryRunMode | Should -BeTrue
        }
    }

    Context '-GameMedia and -GpuShaders follow sw clean' {
        It 'Runs neither GPU shader caches nor game media by default' {
            $result = Get-SweeprCleanPreview
            Should -Invoke Clear-GPUShaderCaches -Times 0 -Exactly
            Should -Invoke Invoke-AppCleanup -Times 1 -Exactly -ParameterFilter { -not $IncludeGameMedia }
            @($result.Sections | ForEach-Object Name) | Should -Not -Contain 'GPU shader caches'
        }

        It 'Adds the GPU shader section on request' {
            $result = Get-SweeprCleanPreview -GpuShaders
            Should -Invoke Clear-GPUShaderCaches -Times 1 -Exactly
            @($result.Sections | ForEach-Object Name) | Should -Contain 'GPU shader caches'
        }

        It 'Passes game media on to the application section' {
            $null = Get-SweeprCleanPreview -GameMedia
            Should -Invoke Invoke-AppCleanup -Times 1 -Exactly -ParameterFilter { $IncludeGameMedia }
        }
    }

    Context '-SkipExternalTools' {
        BeforeEach {
            # Tool caches run through the real developer section; nothing else is needed from it.
            Mock Invoke-DevToolsCleanup { & $script:RealInvokeDevToolsCleanup }
        }

        It 'Asks the installed tools for their cache folder when the switch is absent' {
            $result = Get-SweeprCleanPreview
            foreach ($tool in @('npm', 'pnpm', 'pip', 'go', 'mise')) {
                Should -Invoke Invoke-SweeprOwnerProcess -Times 1 -ParameterFilter { $Name -eq $tool }
            }
            @($result.NotMeasured).Count | Should -Be 0
        }

        It 'Starts no external program with the switch and names the skipped tools as not measured' {
            $result = Get-SweeprCleanPreview -SkipExternalTools
            Should -Invoke Invoke-SweeprOwnerProcess -Times 0 -Exactly
            Should -Invoke Start-Process -Times 0 -Exactly
            $names = @($result.NotMeasured | ForEach-Object Name)
            foreach ($tool in @('npm', 'pnpm', 'pip', 'go', 'mise')) {
                $names | Should -Contain $tool
            }
            foreach ($entry in @($result.NotMeasured)) {
                $entry.Section | Should -Be 'Developer tools'
                $entry.Reason | Should -Be 'external tool'
            }
        }

        It 'Lists each skipped tool once, even when it has several queries' {
            $result = Get-SweeprCleanPreview -SkipExternalTools
            $go = @($result.NotMeasured | Where-Object Name -eq 'go')
            $go.Count | Should -Be 1
        }

        It 'Still measures the folders that need no external program' {
            # Written the way the module builds the path, so the same string works on any platform.
            $yarn = "$env:LOCALAPPDATA\Yarn\Cache"
            [void][IO.Directory]::CreateDirectory($yarn.Replace('\', '/'))
            [IO.File]::WriteAllBytes((Join-Path $yarn 'package'), (New-Object byte[] 700))
            $result = Get-SweeprCleanPreview -SkipExternalTools
            $hit = @($result.Hits | Where-Object { $_.Section -eq 'Developer tools' -and $_.Description -eq 'Yarn cache' })
            $hit.Count | Should -Be 1
            $hit[0].SizeBytes | Should -Be 700
        }
    }
}

Describe 'lib/clean/preview.ps1 on its own' {
    It 'Loads on its own in a new process and defines its functions' {
        $result = Invoke-FreshLoad -File (Join-Path $script:LibDir 'clean\preview.ps1') -Functions @('Get-SweeprCleanPreview', 'Invoke-UserCleanup', 'Invoke-SystemCleanup')
        $result.Err | Should -BeNullOrEmpty
        $result.ExitCode | Should -Be 0
        foreach ($name in @('Get-SweeprCleanPreview', 'Invoke-UserCleanup', 'Invoke-SystemCleanup')) {
            $result.Out | Should -Match "FOUND $name"
        }
    }
}
