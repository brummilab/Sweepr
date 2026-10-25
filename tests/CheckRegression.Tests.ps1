# Sweepr - F-03a: sw clean, sw purge and sw optimize behave as before
#
# F-03a moves logic out of bin/clean.ps1, bin/purge.ps1 and bin/optimize.ps1 into lib/. These tests pin
# what the commands show and return today, and must be green before and after the move. Each function is
# taken from wherever it lives: if a lib file defines it, that definition is used, otherwise it is lifted
# from the command script (so no menu or Main runs). Signatures and results of these functions stay.
# Platform neutral: path identity checks, the system version and every query are mocked.

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:LibDir = Join-Path $script:Root 'lib'
    foreach ($module in @('core\base', 'core\log', 'core\ui', 'core\file_ops', 'clean\user', 'clean\caches', 'clean\dev', 'clean\apps', 'clean\system')) {
        . (Join-Path $script:LibDir "$module.ps1")
    }
    # New lib files of F-03a, when they exist; the lifted command functions then use their helpers.
    foreach ($optional in @('clean\preview.ps1', 'clean\projects.ps1', 'core\health.ps1')) {
        $file = Join-Path $script:LibDir $optional
        if (Test-Path -LiteralPath $file) { . $file }
    }
    $script:LibScripts = @(Get-ChildItem -LiteralPath $script:LibDir -Recurse -Filter '*.ps1' -File | ForEach-Object FullName)

    function script:Import-CommandFunction {
        param([string]$Name, [string[]]$Files)
        if (Get-Command $Name -CommandType Function -ErrorAction SilentlyContinue) { return }
        foreach ($file in $Files) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
            $definition = $ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
                }, $true)
            if ($definition) {
                . ([scriptblock]::Create($definition.Extent.Text))
                Set-Item -Path "function:script:$Name" -Value (Get-Item "function:$Name").ScriptBlock
                return
            }
        }
        throw "$Name not found in the command script or in lib/"
    }
    function script:Import-CommandVariable {
        param([string]$Name, [string[]]$Files)
        if (Test-Path "variable:script:$Name") { return }
        foreach ($file in $Files) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
            $assignment = $ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq "`$script:$Name"
                }, $true)
            if ($assignment) {
                Set-Variable -Name $Name -Scope Script -Value (& ([scriptblock]::Create($assignment.Right.Extent.Text)))
                return
            }
        }
        throw "`$script:$Name not found in the command script or in lib/"
    }
    # The text a command wrote with Write-Host, ANSI colours removed; other output is left to the caller.
    function script:Get-HostText {
        param($Captured)
        $builder = New-Object System.Text.StringBuilder
        foreach ($record in @($Captured)) {
            if ($record -isnot [System.Management.Automation.InformationRecord]) { continue }
            [void]$builder.Append([string]$record.MessageData)
            if (-not $record.MessageData.NoNewLine) { [void]$builder.Append("`n") }
        }
        return ($builder.ToString() -replace '\x1b\[[0-9;]*m', '')
    }
    function script:Write-Bytes {
        param([string]$Path, [int]$Count, [int]$DaysOld = 0)
        # Forward slashes work on every platform; a backslash is a file name character on Linux.
        $Path = $Path.Replace('\', '/')
        New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
        [IO.File]::WriteAllBytes($Path, (New-Object byte[] $Count))
        if ($DaysOld -gt 0) { (Get-Item -LiteralPath $Path).LastWriteTime = (Get-Date).AddDays(-$DaysOld) }
    }

    $script:CleanFiles = @(Join-Path $script:Root 'bin\clean.ps1') + $script:LibScripts
    $script:PurgeFiles = @(Join-Path $script:Root 'bin\purge.ps1') + $script:LibScripts
    $script:OptimizeFiles = @(Join-Path $script:Root 'bin\optimize.ps1') + $script:LibScripts

    foreach ($name in @('Start-Cleanup', 'Show-CleanupSummary')) { Import-CommandFunction -Name $name -Files $script:CleanFiles }
    foreach ($name in @('Find-Projects', 'Find-ProjectArtifacts', 'Get-PurgeProjectDirectories', 'Get-PurgeDisplayPath', 'Test-PurgeArtifactKind', 'Test-PurgeArtifactContent', 'Invoke-PurgeGit')) {
        Import-CommandFunction -Name $name -Files $script:PurgeFiles
    }
    Import-CommandVariable -Name 'ArtifactPatterns' -Files $script:PurgeFiles
    foreach ($name in @('Test-DiskHealth', 'Get-SystemHealth', 'Show-SystemHealth', 'Get-SystemDriveLetter')) {
        Import-CommandFunction -Name $name -Files $script:OptimizeFiles
    }

    # Storage and WMI/CIM cmdlets: plain functions so Pester can mock them everywhere.
    function script:Get-PhysicalDisk { [CmdletBinding()] param() }
    function script:Get-Partition { [CmdletBinding()] param([string]$DriveLetter) }
    function script:Get-Disk { [CmdletBinding()] param([Parameter(ValueFromPipeline)]$InputObject, $Number) process { } }
    function script:Get-CimInstance { [CmdletBinding()] param([Parameter(Position = 0)][string]$ClassName, [string]$Filter, [string]$Query) }
    function script:Get-WmiObject { [CmdletBinding()] param([Parameter(Position = 0)][string]$Class, [string]$Filter) }
    function script:Get-FakeCim {
        param([string]$ClassName, [string]$Filter)
        if ($ClassName -match 'Win32_OperatingSystem') { return $script:FakeOs }
        if ($ClassName -match 'Win32_LogicalDisk') {
            $disks = @($script:FakeDisks)
            if ($Filter -match "DeviceID\s*=\s*'([A-Za-z]:)'") { $id = $Matches[1]; $disks = @($disks | Where-Object { $_.DeviceID -eq $id }) }
            return $disks
        }
        if ($ClassName -match 'Win32_Processor') { return [pscustomobject]@{ Name = 'Example CPU'; NumberOfLogicalProcessors = 8 } }
        return @()
    }

    $script:SavedEnv = @{}
    foreach ($name in @('TEMP', 'TMP', 'LOCALAPPDATA', 'APPDATA', 'USERPROFILE', 'ProgramData', 'WINDIR', 'SystemDrive')) {
        $script:SavedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
    }
}

AfterAll {
    foreach ($name in $script:SavedEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $script:SavedEnv[$name]) }
    Set-DryRunMode -Enabled $false
}

Describe 'sw clean console output in a dry run' {
    BeforeEach {
        $script:FakeHome = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $env:USERPROFILE = $script:FakeHome
        $env:TEMP = Join-Path $script:FakeHome 'tmp'
        $env:TMP = $env:TEMP
        $env:LOCALAPPDATA = Join-Path $script:FakeHome 'Local'
        $env:APPDATA = Join-Path $script:FakeHome 'Roaming'
        $env:ProgramData = Join-Path $script:FakeHome 'ProgramData'
        $env:WINDIR = Join-Path $script:FakeHome 'Windows'
        $script:OldFile = Join-Path $env:TEMP 'old.tmp'
        Write-Bytes -Path $script:OldFile -Count 4096 -DaysOld 30
        $script:ExportListFile = Join-Path $script:FakeHome 'config/clean-list.txt'
        $script:StartCleanupParameters = @{ IsDryRun = $true; IncludeSystem = $false; IncludeGameMedia = $false; IncludeGpuShaders = $false }

        Set-DryRunMode -Enabled $false
        Mock Get-SweeprPathSnapshot { [pscustomobject]@{ Path = $Path } }
        Mock Test-SweeprPathSnapshot { $true }
        Mock Test-IsAdmin { $false }
        Mock Clear-Host {}
        Mock Get-WindowsVersion { [pscustomobject]@{ Name = 'Example OS' } }
        Mock Get-FreeSpace { '10.0GB' }
        Mock Clear-BrowserCaches {}
        Mock Clear-AppCaches {}
        Mock Invoke-DevToolsCleanup {}
        Mock Invoke-AppCleanup {}
        Mock Invoke-SystemCleanup {}
        Mock Remove-Item { throw 'Remove-Item must not run in a dry run' }
    }

    It 'Shows the dry-run banner, the potential space and the summary, and clears the screen once' {
        $output = Get-HostText (Start-Cleanup @script:StartCleanupParameters 6>&1)
        $output | Should -Match 'Clean Your Windows'
        $output | Should -Match 'Dry Run Mode'
        $output | Should -Match 'Preview only, no deletions'
        $output | Should -Match 'Example OS'
        $output | Should -Match 'User essentials'
        $output | Should -Match 'User temp files'
        $output | Should -Match 'Dry run complete - no changes made'
        $output | Should -Match 'Potential space: 4KB \| Items: 1'
        $output | Should -Match 'Free space: 10.0GB'
        $output | Should -Match 'Detailed file list: '
        Should -Invoke Clear-Host -Times 1 -Exactly
    }

    It 'Keeps the file, writes the preview list with header, description and path, and stays in dry-run mode' {
        $null = Start-Cleanup @script:StartCleanupParameters 6>&1
        Test-Path -LiteralPath $script:OldFile | Should -BeTrue
        $list = Get-Content -LiteralPath $script:ExportListFile
        $list | Should -Contain '# User temp files (>7d old)'
        $list | Should -Contain $script:OldFile
        ($list | Select-Object -First 1) | Should -Match '^# Sweepr Cleanup Preview - '
        Test-DryRunMode | Should -BeTrue
    }

    It 'Runs the system cleanup in a dry run only for an administrator who asked for it' {
        $script:StartCleanupParameters.IncludeSystem = $true
        $null = Start-Cleanup @script:StartCleanupParameters 6>&1
        Should -Invoke Invoke-SystemCleanup -Times 0 -Exactly
        Mock Test-IsAdmin { $true }
        $null = Start-Cleanup @script:StartCleanupParameters 6>&1
        Should -Invoke Invoke-SystemCleanup -Times 1 -Exactly
    }

    It 'Passes game media and GPU shader requests on to their sections' {
        Mock Clear-GPUShaderCaches {}
        $script:StartCleanupParameters.IncludeGameMedia = $true
        $script:StartCleanupParameters.IncludeGpuShaders = $true
        $null = Start-Cleanup @script:StartCleanupParameters 6>&1
        Should -Invoke Clear-GPUShaderCaches -Times 1 -Exactly
        Should -Invoke Invoke-AppCleanup -Times 1 -Exactly -ParameterFilter { $IncludeGameMedia }
    }
}

Describe 'sw purge discovery result' {
    BeforeEach {
        $script:Base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Write-Bytes -Path (Join-Path $script:Base 'app/package.json') -Count 10
        Write-Bytes -Path (Join-Path $script:Base 'app/node_modules/a.js') -Count 1500
        Write-Bytes -Path (Join-Path $script:Base 'py/requirements.txt') -Count 10
        Write-Bytes -Path (Join-Path $script:Base 'py/.venv/bin/python') -Count 3000
        Mock Get-SweeprPathSnapshot { [pscustomobject]@{ Path = $Path } }
        Mock Test-SweeprPathSnapshot { $true }
        Mock Write-Progress {}
        Mock Remove-Item { throw 'Remove-Item must not run in a discovery' }
    }

    It 'Keeps the project and artifact objects that the selection menu and the removal use' {
        $projects = @(Find-Projects -SearchPaths @($script:Base))
        $projects.Count | Should -Be 2
        @($projects | ForEach-Object Name) | Should -Be @('py', 'app')
        $app = $projects | Where-Object Name -eq 'app'
        $app.Path | Should -Be (Join-Path $script:Base 'app')
        $app.Marker | Should -Be 'package.json'
        $app.DisplayPath | Should -Not -BeNullOrEmpty
        $app.TotalSizeKB | Should -Be 2
        $app.TotalSizeHuman | Should -Not -BeNullOrEmpty
        $artifact = @($app.Artifacts)[0]
        $artifact.Name | Should -Be 'node_modules'
        $artifact.Type | Should -Be 'Directory'
        $artifact.Language | Should -Be 'JavaScript/Node.js'
        $artifact.SizeKB | Should -Be 2
        $artifact.SizeHuman | Should -Not -BeNullOrEmpty
        $artifact.Snapshot | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $script:Base 'app/node_modules/a.js') | Should -BeTrue
    }
}

Describe 'sw optimize health output' {
    BeforeEach {
        $env:SystemDrive = 'C:'
        $script:IssuesFound = 0
        $script:DiskHealth = 'Healthy'
        $script:FakeBoot = (Get-Date).AddDays(-2.5)
        $script:FakeOs = [pscustomobject]@{ Caption = 'Example OS'; TotalVisibleMemorySize = 8388608; FreePhysicalMemory = 2097152; LastBootUpTime = $script:FakeBoot }
        $script:FakeDisks = @([pscustomobject]@{ DeviceID = 'C:'; DriveType = 3; Size = 107374182400; FreeSpace = 26843545600; VolumeName = 'System'; FileSystem = 'NTFS' })
        Mock Start-Spinner {}
        Mock Stop-Spinner {}
        Mock Get-PhysicalDisk { [pscustomobject]@{ FriendlyName = 'Example SSD'; HealthStatus = $script:DiskHealth } }
        Mock Get-Partition { [pscustomobject]@{ DriveLetter = 'C'; DiskNumber = 0 } }
        Mock Get-Disk { [pscustomobject]@{ Number = 0; FriendlyName = 'Example SSD'; HealthStatus = $script:DiskHealth } }
        Mock Get-CimInstance { Get-FakeCim -ClassName $ClassName -Filter $Filter }
        Mock Get-WmiObject { Get-FakeCim -ClassName $Class -Filter $Filter }
    }

    It 'Collects the health metrics that Show-SystemHealth renders' {
        $health = Get-SystemHealth
        $health.MemoryTotalGB | Should -Be 8
        $health.MemoryUsedGB | Should -Be 6
        $health.MemoryUsedPercent | Should -Be 75
        $health.DiskTotalGB | Should -Be 100
        $health.DiskUsedGB | Should -Be 75
        $health.DiskUsedPercent | Should -Be 75
        $health.UptimeDays | Should -BeGreaterOrEqual 2.5
        $health.UptimeDays | Should -BeLessThan 2.7
        $health.CPUName | Should -Be 'Example CPU'
        $health.CPUCores | Should -Be 8
    }

    It 'Renders the health line' {
        $output = Get-HostText (Show-SystemHealth -Health @{ MemoryUsedGB = 6; MemoryTotalGB = 8; DiskUsedGB = 75; DiskTotalGB = 100; UptimeDays = 2.5 } 6>&1)
        $output | Should -Match '6/8GB RAM \| 75/100GB Disk \| Uptime 2\.5d'
    }

    It 'Reports a healthy disk and allows optimization' {
        $captured = @(Test-DiskHealth 6>&1)
        $text = Get-HostText $captured
        $text | Should -Match 'Disk Health'
        $text | Should -Match 'Example SSD - Healthy'
        $text | Should -Not -Match 'back up'
        @($captured | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[-1] | Should -BeTrue
        $script:IssuesFound | Should -Be 0
    }

    It 'Warns about a <Status> disk, counts an issue and keeps optimization off' -TestCases @(
        @{ Status = 'Warning'; Message = 'consider backing up data' }
        @{ Status = 'Unhealthy'; Message = 'back up data immediately' }
    ) {
        param($Status, $Message)
        $script:DiskHealth = $Status
        $captured = @(Test-DiskHealth 6>&1)
        $text = Get-HostText $captured
        $text | Should -Match "Example SSD - $Status"
        $text | Should -Match $Message
        ($captured | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[-1] | Should -BeFalse
        $script:IssuesFound | Should -Be 1
    }

    It 'Says so and does not block optimization when the health cannot be read' {
        Mock Get-PhysicalDisk { throw 'Access is denied' }
        Mock Get-Partition { throw 'Access is denied' }
        $captured = @(Test-DiskHealth 6>&1)
        $text = Get-HostText $captured
        $text | Should -Match 'Could not check disk health'
        ($captured | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })[-1] | Should -BeTrue
        $script:IssuesFound | Should -Be 0
    }
}
