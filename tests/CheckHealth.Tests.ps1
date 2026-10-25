# Sweepr - F-03a: system state as data (lib/core/health.ps1)
#
# Fixes the interface that `sw check` builds on, before it exists. The data collection of
# `sw optimize` (Get-SystemHealth, Get-StartupPrograms, Test-DiskHealth, Test-WindowsUpdate) moves to
# lib/core/health.ps1 as functions that return data; optimize only renders them. Every function:
#   - is read-only and never needs administrator rights for what it can read
#   - never throws for missing data, never writes to the console, never starts a spinner
#   - returns one object with Measured [bool] and Reason [string]. What could not be read is marked
#     (Measured = $false, values $null), never reported as zero or as healthy.
# Data comes from Get-CimInstance (not Get-WmiObject), the Storage cmdlets, Get-HotFix and the Run keys.
#
#   Get-SweeprDiskInfo        Drives: Drive ('C:'), Label, FileSystem, SizeBytes, FreeBytes [long],
#                             FreePercent [double, 1 decimal], IsSystem [bool], Health (Healthy|Warning|Unhealthy|Unknown)
#                             fixed disks only; Health Unknown when the Storage cmdlets fail, sizes stay
#   Get-SweeprMemoryInfo      TotalBytes, FreeBytes, UsedBytes [long], UsedPercent [double, 1 decimal]
#   Get-SweeprUptimeInfo      [-Now <datetime>]  LastBoot [datetime], UptimeDays [double, 1 decimal]
#   Get-SweeprUpdateInfo      [-Count <int> = 5]  LastInstalledOn [datetime], Recent: Id, Description, InstalledOn
#                             (newest first, entries without a date are ignored)
#   Get-SweeprPendingUpdates  [-TimeoutSeconds <int> = 5]  Total, Important [int]; local catalog only,
#                             in a bounded job that is always stopped and removed; unknown is never 0
#   Get-SweeprStartupEntries  Entries: Name, Command, Source (HKCU Run|HKLM Run|HKLM Run (32-bit)|Startup folder);
#                             Count [int]; Missing [string[]] = sources that could not be read (Measured stays $true
#                             while at least one source was read)
#   Get-SweeprHealth          one object: IsAdmin, Disks, Memory, Uptime, Updates, PendingUpdates, Startup (the results
#                             of the functions above) and NotMeasured: Name, Reason for every part with Measured = $false.
#                             Calls every part, also without administrator rights; one failing part never hides the others.

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:LibDir = Join-Path $script:Root 'lib'
    foreach ($module in @('core\base', 'core\log', 'core\ui', 'core\file_ops')) {
        . (Join-Path $script:LibDir "$module.ps1")
    }
    # Missing until F-03a is implemented: the tests then fail on the missing functions, not on loading.
    $healthScript = Join-Path $script:LibDir 'core\health.ps1'
    if (Test-Path -LiteralPath $healthScript) { . $healthScript }

    # Plain functions shadow the Storage/CIM cmdlets so that Pester can mock them on every platform
    # (CDXML cmdlets cannot be mocked on Windows PowerShell 5.1, and Linux has none of them).
    function script:Get-CimInstance { [CmdletBinding()] param([Parameter(Position = 0)][string]$ClassName, [string]$Namespace, [string]$Filter, [string]$Query, [string[]]$Property) }
    function script:Get-HotFix { [CmdletBinding()] param() }
    function script:Get-PhysicalDisk { [CmdletBinding()] param() }
    function script:Get-Partition { [CmdletBinding()] param([string]$DriveLetter) }
    function script:Get-Disk { [CmdletBinding()] param([Parameter(ValueFromPipeline)]$InputObject, $Number) process { } }
    function script:Get-Volume { [CmdletBinding()] param([string]$DriveLetter) }
    function script:Optimize-Volume { [CmdletBinding()] param($DriveLetter) }
    function script:Repair-Volume { [CmdletBinding()] param($DriveLetter) }
    function script:Clear-DnsClientCache { [CmdletBinding()] param() }
    foreach ($name in @('Stop-Service', 'Set-Service', 'Restart-Service')) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { Set-Item -Path "function:script:$name" -Value { param() } }
    }
    $script:ChangingCommands = @(
        'New-Item', 'Set-Content', 'Add-Content', 'Out-File', 'Move-Item', 'Copy-Item', 'Rename-Item', 'Clear-Content', 'New-ItemProperty',
        'Remove-Item', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Start-Process', 'Stop-Service',
        'Set-Service', 'Restart-Service', 'Optimize-Volume', 'Repair-Volume', 'Clear-DnsClientCache', 'Clear-Host', 'Read-Host'
    )
    # Job cmdlets coerce their typed Job[] argument before Pester's mock runs; untyped seams avoid a real worker.
    function script:Wait-Job { param($Job, $Timeout) throw 'Wait-Job must be mocked' }
    function script:Receive-Job { param($Job, $ErrorAction) throw 'Receive-Job must be mocked' }
    function script:Stop-Job { param($Job, $ErrorAction) throw 'Stop-Job must be mocked' }
    function script:Remove-Job { param($Job, [switch]$Force, $ErrorAction) throw 'Remove-Job must be mocked' }

    # One CIM answer for every class a health function may ask for; honours the filters it might send.
    function script:Get-FakeCim {
        param([string]$ClassName, [string]$Query, [string]$Filter)
        $what = "$ClassName $Query"
        if ($what -match 'Win32_OperatingSystem') { return $script:FakeOs }
        if ($what -match 'Win32_LogicalDisk') {
            $disks = @($script:FakeDisks)
            if ("$Filter $Query" -match 'DriveType\s*=\s*3') { $disks = @($disks | Where-Object { $_.DriveType -eq 3 }) }
            if ("$Filter $Query" -match "DeviceID\s*=\s*'([A-Za-z]:)'") { $id = $Matches[1]; $disks = @($disks | Where-Object { $_.DeviceID -eq $id }) }
            return $disks
        }
        if ($what -match 'Win32_Processor') { return [pscustomobject]@{ Name = 'Example CPU'; NumberOfLogicalProcessors = 8 } }
        return @()
    }
    function script:Set-RunKeys {
        # Run keys and Startup folder as the registry provider and the file system would return them.
        Mock Test-Path { $true }
        Mock Get-ItemProperty {
            $location = "$Path$LiteralPath"
            $psProps = @{ PSPath = 'x'; PSParentPath = 'y'; PSChildName = 'Run'; PSDrive = 'HKCU'; PSProvider = 'Registry' }
            if ($location -like '*WOW6432Node*') { return [pscustomobject]($psProps + @{ ExampleUpdater = '"C:\Example\updater.exe" /silent' }) }
            if ($location -like '*HKLM*') { return [pscustomobject]($psProps + @{ SecurityTray = 'C:\Example\tray.exe' }) }
            if ($location -like '*HKCU*') { return [pscustomobject]($psProps + @{ NotesSync = '"C:\Example\sync.exe" --background'; ChatApp = 'C:\Example\chat.exe' }) }
            throw "unexpected registry location $location"
        }
        Mock Get-ChildItem { [pscustomobject]@{ Name = 'Example Tool.lnk'; FullName = 'C:\Example\Startup\Example Tool.lnk'; PSIsContainer = $false } }
    }

    # Loads one lib file in a brand-new PowerShell process, with nothing loaded before it.
    function script:Invoke-FreshLoad {
        param([string]$File, [string[]]$Functions)
        $dataDir = Join-Path $TestDrive 'fresh-data'
        [void][IO.Directory]::CreateDirectory($dataDir)
        $checks = ($Functions | ForEach-Object { "if (Get-Command $_ -CommandType Function -ErrorAction SilentlyContinue) { 'FOUND $_' } else { 'MISSING $_' }" }) -join '; '
        # Windows PowerShell 5.1 writes progress records (e.g. "Preparing modules for first use.")
        # to a redirected stderr as CLIXML. Progress is not an error, so silence it; real errors
        # still reach stderr and fail the check.
        $command = "`$ProgressPreference = 'SilentlyContinue'; `$ErrorActionPreference = 'Stop'; . '" + $File.Replace("'", "''") + "'; $checks"
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

    $script:SavedSystemDrive = $env:SystemDrive
}

AfterAll {
    $env:SystemDrive = $script:SavedSystemDrive
}

Describe 'System state data' {
    BeforeEach {
        $env:SystemDrive = 'C:'
        $script:Boot = [datetime]'2026-10-20T08:00:00'
        $script:FakeOs = [pscustomobject]@{ Caption = 'Example OS'; TotalVisibleMemorySize = 8388608; FreePhysicalMemory = 2097152; LastBootUpTime = $script:Boot }
        $script:FakeDisks = @(
            [pscustomobject]@{ DeviceID = 'C:'; DriveType = 3; Size = 107374182400; FreeSpace = 26843545600; VolumeName = 'System'; FileSystem = 'NTFS' }
            [pscustomobject]@{ DeviceID = 'D:'; DriveType = 3; Size = 214748364800; FreeSpace = 161061273600; VolumeName = 'Data'; FileSystem = 'NTFS' }
            [pscustomobject]@{ DeviceID = 'E:'; DriveType = 5; Size = 0; FreeSpace = 0; VolumeName = ''; FileSystem = '' }
        )
        Mock Get-CimInstance { Get-FakeCim -ClassName $ClassName -Query $Query -Filter $Filter }
        Mock Get-Partition { [pscustomobject]@{ DriveLetter = $DriveLetter; DiskNumber = 0 } }
        Mock Get-Disk { [pscustomobject]@{ Number = 0; FriendlyName = 'Example Disk'; HealthStatus = $script:DiskHealth } }
        Mock Get-PhysicalDisk { [pscustomobject]@{ FriendlyName = 'Example Disk'; HealthStatus = $script:DiskHealth } }
        $script:DiskHealth = 'Healthy'
        Mock Test-IsAdmin { $false }
        Mock Start-Spinner {}
        Mock Stop-Spinner {}
        foreach ($name in $script:ChangingCommands) { Mock $name ([scriptblock]::Create("throw '$name must not run'")) }
    }

    Context 'Interface' {
        It 'Defines the data functions in lib/core/health.ps1' {
            foreach ($name in @('Get-SweeprDiskInfo', 'Get-SweeprMemoryInfo', 'Get-SweeprUptimeInfo', 'Get-SweeprUpdateInfo', 'Get-SweeprPendingUpdates', 'Get-SweeprStartupEntries', 'Get-SweeprHealth')) {
                Get-Command $name -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because "$name belongs to lib/core/health.ps1"
            }
        }
    }

    Context 'Get-SweeprDiskInfo' {
        It 'Returns the fixed disks with size, free space, label, file system and system flag' {
            $info = Get-SweeprDiskInfo
            $info.Measured | Should -BeTrue
            $drives = @($info.Drives)
            @($drives | ForEach-Object Drive) | Should -Be @('C:', 'D:')
            $c = $drives[0]
            $c.Label | Should -Be 'System'
            $c.FileSystem | Should -Be 'NTFS'
            $c.SizeBytes | Should -BeOfType [long]
            $c.SizeBytes | Should -Be 107374182400
            $c.FreeBytes | Should -Be 26843545600
            $c.FreePercent | Should -Be 25
            $c.IsSystem | Should -BeTrue
            $drives[1].FreePercent | Should -Be 75
            $drives[1].IsSystem | Should -BeFalse
        }

        It 'Reports the disk health <Status> of the drive' -TestCases @(
            @{ Status = 'Healthy' }, @{ Status = 'Warning' }, @{ Status = 'Unhealthy' }
        ) {
            param($Status)
            $script:DiskHealth = $Status
            $info = Get-SweeprDiskInfo
            foreach ($drive in @($info.Drives)) { $drive.Health | Should -Be $Status }
        }

        It 'Keeps sizes and marks the health Unknown when the Storage cmdlets are not allowed' {
            Mock Get-Partition { throw 'Access is denied' }
            Mock Get-Disk { throw 'Access is denied' }
            Mock Get-PhysicalDisk { throw 'Access is denied' }
            $info = Get-SweeprDiskInfo
            $info.Measured | Should -BeTrue
            @($info.Drives).Count | Should -Be 2
            foreach ($drive in @($info.Drives)) {
                $drive.Health | Should -Be 'Unknown'
                $drive.SizeBytes | Should -BeGreaterThan 0
            }
        }

        It 'Reports an empty or unrecognised health status as Unknown, not as Healthy' {
            $script:DiskHealth = $null
            foreach ($drive in @((Get-SweeprDiskInfo).Drives)) { $drive.Health | Should -Be 'Unknown' }
        }

        It 'Marks the disks as not measured when CIM fails' {
            Mock Get-CimInstance { throw 'CIM is not available' }
            $info = Get-SweeprDiskInfo
            $info.Measured | Should -BeFalse
            $info.Reason | Should -Not -BeNullOrEmpty
            @($info.Drives).Count | Should -Be 0
        }
    }

    Context 'Get-SweeprMemoryInfo' {
        It 'Converts the kilobyte counters of the operating system to bytes' {
            $info = Get-SweeprMemoryInfo
            $info.Measured | Should -BeTrue
            $info.TotalBytes | Should -BeOfType [long]
            $info.TotalBytes | Should -Be 8589934592
            $info.FreeBytes | Should -Be 2147483648
            $info.UsedBytes | Should -Be 6442450944
            $info.UsedPercent | Should -Be 75
        }

        It 'Marks memory as not measured when CIM fails, with no zero values' {
            Mock Get-CimInstance { throw 'CIM is not available' }
            $info = Get-SweeprMemoryInfo
            $info.Measured | Should -BeFalse
            $info.Reason | Should -Not -BeNullOrEmpty
            $info.TotalBytes | Should -BeNullOrEmpty
            $info.UsedPercent | Should -BeNullOrEmpty
        }
    }

    Context 'Get-SweeprUptimeInfo' {
        It 'Returns the last boot and the uptime in days relative to -Now' {
            $info = Get-SweeprUptimeInfo -Now ($script:Boot.AddDays(2.5))
            $info.Measured | Should -BeTrue
            $info.LastBoot | Should -Be $script:Boot
            $info.UptimeDays | Should -Be 2.5
        }

        It 'Uses the current time when -Now is not given' {
            $script:FakeOs.LastBootUpTime = (Get-Date).AddDays(-1)
            $info = Get-SweeprUptimeInfo
            $info.UptimeDays | Should -BeGreaterOrEqual 1
            $info.UptimeDays | Should -BeLessThan 1.1
        }

        It 'Marks the uptime as not measured when CIM fails' {
            Mock Get-CimInstance { throw 'CIM is not available' }
            $info = Get-SweeprUptimeInfo
            $info.Measured | Should -BeFalse
            $info.Reason | Should -Not -BeNullOrEmpty
            $info.LastBoot | Should -BeNullOrEmpty
            $info.UptimeDays | Should -BeNullOrEmpty
        }
    }

    Context 'Get-SweeprUpdateInfo' {
        BeforeEach {
            Mock Get-HotFix {
                [pscustomobject]@{ HotFixID = 'KB5000001'; Description = 'Update'; InstalledOn = [datetime]'2026-08-12' }
                [pscustomobject]@{ HotFixID = 'KB5000003'; Description = 'Security Update'; InstalledOn = [datetime]'2026-10-08' }
                [pscustomobject]@{ HotFixID = 'KB5000000'; Description = 'Update'; InstalledOn = $null }
                [pscustomobject]@{ HotFixID = 'KB5000002'; Description = 'Update'; InstalledOn = [datetime]'2026-09-10' }
            }
        }

        It 'Returns the newest installation date and the recent updates, newest first' {
            $info = Get-SweeprUpdateInfo
            $info.Measured | Should -BeTrue
            $info.LastInstalledOn.Date | Should -Be ([datetime]'2026-10-08')
            @($info.Recent | ForEach-Object Id) | Should -Be @('KB5000003', 'KB5000002', 'KB5000001')
            $info.Recent[0].Description | Should -Be 'Security Update'
            $info.Recent[0].InstalledOn.Date | Should -Be ([datetime]'2026-10-08')
        }

        It 'Limits the list with -Count' {
            $info = Get-SweeprUpdateInfo -Count 2
            @($info.Recent).Count | Should -Be 2
            $info.LastInstalledOn.Date | Should -Be ([datetime]'2026-10-08')
        }

        It 'Marks the updates as not measured when the query fails' {
            Mock Get-HotFix { throw 'Access is denied' }
            $info = Get-SweeprUpdateInfo
            $info.Measured | Should -BeFalse
            $info.Reason | Should -Not -BeNullOrEmpty
            $info.LastInstalledOn | Should -BeNullOrEmpty
        }
    }

    Context 'Get-SweeprPendingUpdates' {
        BeforeEach {
            $script:UpdateJob = [pscustomobject]@{ State = 'Completed' }
            $script:UpdateResult = [pscustomobject]@{ Total = 3; Important = 1 }
            Mock Start-Job { $script:UpdateJob }
            Mock Wait-Job { $script:UpdateJob }
            Mock Receive-Job { $script:UpdateResult }
            Mock Stop-Job {}
            Mock Remove-Job {}
            # An in-process COM query could stall or go online; it has to run in the bounded job.
            Mock New-Object { throw 'COM must run in the isolated job' } -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' }
        }

        It 'Returns the counts of a complete local-catalog query and removes the job' {
            $info = Get-SweeprPendingUpdates
            $info.Measured | Should -BeTrue
            $info.Total | Should -Be 3
            $info.Important | Should -Be 1
            Should -Invoke Wait-Job -Exactly -Times 1 -ParameterFilter { $Timeout -eq 5 }
            Should -Invoke Receive-Job -Exactly -Times 1
            Should -Invoke Remove-Job -Exactly -Times 1
            Should -Invoke Start-Spinner -Exactly -Times 0
        }

        It 'Reports a complete empty catalog as zero' {
            $script:UpdateResult = [pscustomobject]@{ Total = 0; Important = 0 }
            $info = Get-SweeprPendingUpdates
            $info.Measured | Should -BeTrue
            $info.Total | Should -Be 0
            $info.Important | Should -Be 0
        }

        It 'Honours -TimeoutSeconds' {
            $null = Get-SweeprPendingUpdates -TimeoutSeconds 2
            Should -Invoke Wait-Job -Exactly -Times 1 -ParameterFilter { $Timeout -eq 2 }
        }

        It 'Keeps a timed-out query unknown (not zero) and reclaims its worker' {
            $script:UpdateJob.State = 'Running'
            Mock Wait-Job { $null }
            $info = Get-SweeprPendingUpdates
            $info.Measured | Should -BeFalse
            $info.Reason | Should -Not -BeNullOrEmpty
            $info.Total | Should -BeNullOrEmpty
            $info.Important | Should -BeNullOrEmpty
            Should -Invoke Receive-Job -Exactly -Times 0
            Should -Invoke Stop-Job -Exactly -Times 1
            Should -Invoke Remove-Job -Exactly -Times 1
        }

        It 'Does not turn a job that <Case> into a verdict' -TestCases @(
            @{ Case = 'failed' }, @{ Case = 'returned nothing' }, @{ Case = 'returned inconsistent counts' }
        ) {
            param($Case)
            switch ($Case) {
                'failed' { $script:UpdateJob.State = 'Failed' }
                'returned nothing' { Mock Receive-Job { } }
                'returned inconsistent counts' { $script:UpdateResult = [pscustomobject]@{ Total = 1; Important = 2 } }
            }
            $info = Get-SweeprPendingUpdates
            $info.Measured | Should -BeFalse
            $info.Total | Should -BeNullOrEmpty
            Should -Invoke Remove-Job -Exactly -Times 1
        }

        It 'Does not throw when the worker cannot be started' {
            Mock Start-Job { throw 'Cannot start' }
            $info = Get-SweeprPendingUpdates
            $info.Measured | Should -BeFalse
            $info.Reason | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Get-SweeprStartupEntries' {
        It 'Collects Run key and Startup folder entries with name, command and source' {
            Set-RunKeys
            $info = Get-SweeprStartupEntries
            $info.Measured | Should -BeTrue
            $info.Count | Should -Be 5
            @($info.Entries).Count | Should -Be 5
            @($info.Missing).Count | Should -Be 0
            $bySource = $info.Entries | Group-Object Source -AsHashTable -AsString
            @($bySource['HKCU Run']).Count | Should -Be 2
            @($bySource['HKLM Run']).Count | Should -Be 1
            @($bySource['HKLM Run (32-bit)']).Count | Should -Be 1
            @($bySource['Startup folder']).Count | Should -Be 1
            $sync = $info.Entries | Where-Object Name -eq 'NotesSync'
            $sync.Command | Should -Be '"C:\Example\sync.exe" --background'
            $sync.Source | Should -Be 'HKCU Run'
        }

        It 'Does not count the provider properties of a registry key as entries' {
            Set-RunKeys
            $info = Get-SweeprStartupEntries
            @($info.Entries | ForEach-Object Name) | Should -Not -Contain 'PSPath'
            @($info.Entries | ForEach-Object Name) | Should -Not -Contain 'PSChildName'
        }

        It 'Returns what it can read and names the sources it could not' {
            Set-RunKeys
            Mock Get-ItemProperty {
                $location = "$Path$LiteralPath"
                if ($location -like '*HKLM*') { throw 'Requested registry access is not allowed' }
                [pscustomobject]@{ NotesSync = 'C:\Example\sync.exe'; PSPath = 'x' }
            }
            $info = Get-SweeprStartupEntries
            $info.Measured | Should -BeTrue
            @($info.Entries | Where-Object Source -eq 'HKCU Run').Count | Should -Be 1
            @($info.Entries | Where-Object Source -eq 'Startup folder').Count | Should -Be 1
            @($info.Missing) | Should -Contain 'HKLM Run'
            @($info.Missing) | Should -Contain 'HKLM Run (32-bit)'
            $info.Count | Should -Be 2
        }

        It 'Is not measured when no source can be read, and not an empty list' {
            Mock Test-Path { $true }
            Mock Get-ItemProperty { throw 'Requested registry access is not allowed' }
            Mock Get-ChildItem { throw 'Access is denied' }
            $info = Get-SweeprStartupEntries
            $info.Measured | Should -BeFalse
            $info.Reason | Should -Not -BeNullOrEmpty
            @($info.Missing).Count | Should -Be 4
        }

        It 'Counts a missing key as empty, not as unreadable' {
            Mock Test-Path { $false }
            $info = Get-SweeprStartupEntries
            $info.Measured | Should -BeTrue
            $info.Count | Should -Be 0
            @($info.Missing).Count | Should -Be 0
        }
    }

    Context 'Get-SweeprHealth' {
        It 'Combines the parts and lists nothing as not measured when all parts are' {
            Mock Get-SweeprDiskInfo { [pscustomobject]@{ Measured = $true; Reason = $null; Drives = @() } }
            Mock Get-SweeprMemoryInfo { [pscustomobject]@{ Measured = $true; Reason = $null; TotalBytes = 123L } }
            Mock Get-SweeprUptimeInfo { [pscustomobject]@{ Measured = $true; Reason = $null; UptimeDays = 2.5 } }
            Mock Get-SweeprUpdateInfo { [pscustomobject]@{ Measured = $true; Reason = $null; Recent = @() } }
            Mock Get-SweeprPendingUpdates { [pscustomobject]@{ Measured = $true; Reason = $null; Total = 0; Important = 0 } }
            Mock Get-SweeprStartupEntries { [pscustomobject]@{ Measured = $true; Reason = $null; Entries = @(); Count = 0; Missing = @() } }
            $health = Get-SweeprHealth
            foreach ($property in @('IsAdmin', 'Disks', 'Memory', 'Uptime', 'Updates', 'PendingUpdates', 'Startup', 'NotMeasured')) {
                $health.PSObject.Properties.Name | Should -Contain $property
            }
            $health.Memory.TotalBytes | Should -Be 123
            $health.Uptime.UptimeDays | Should -Be 2.5
            @($health.NotMeasured).Count | Should -Be 0
        }

        It 'Lists every part that is not measured, with its reason, and still returns the others' {
            Mock Get-SweeprDiskInfo { [pscustomobject]@{ Measured = $true; Reason = $null; Drives = @() } }
            Mock Get-SweeprMemoryInfo { [pscustomobject]@{ Measured = $false; Reason = 'CIM is not available'; TotalBytes = $null } }
            Mock Get-SweeprUptimeInfo { [pscustomobject]@{ Measured = $false; Reason = 'CIM is not available'; UptimeDays = $null } }
            Mock Get-SweeprUpdateInfo { [pscustomobject]@{ Measured = $true; Reason = $null; Recent = @() } }
            Mock Get-SweeprPendingUpdates { [pscustomobject]@{ Measured = $false; Reason = 'timed out'; Total = $null; Important = $null } }
            Mock Get-SweeprStartupEntries { [pscustomobject]@{ Measured = $true; Reason = $null; Entries = @(); Count = 0; Missing = @() } }
            $health = Get-SweeprHealth
            $names = @($health.NotMeasured | ForEach-Object Name | Sort-Object)
            $names | Should -Be @('Memory', 'PendingUpdates', 'Uptime')
            ($health.NotMeasured | Where-Object Name -eq 'PendingUpdates').Reason | Should -Be 'timed out'
            ($health.NotMeasured | Where-Object Name -eq 'Memory').Reason | Should -Be 'CIM is not available'
            $health.Disks.Measured | Should -BeTrue
        }

        It 'Survives a part that throws and reports it as not measured' {
            Mock Get-SweeprDiskInfo { throw 'unexpected failure' }
            Mock Get-SweeprMemoryInfo { [pscustomobject]@{ Measured = $true; Reason = $null; TotalBytes = 1L } }
            Mock Get-SweeprUptimeInfo { [pscustomobject]@{ Measured = $true; Reason = $null; UptimeDays = 1 } }
            Mock Get-SweeprUpdateInfo { [pscustomobject]@{ Measured = $true; Reason = $null; Recent = @() } }
            Mock Get-SweeprPendingUpdates { [pscustomobject]@{ Measured = $true; Reason = $null; Total = 0; Important = 0 } }
            Mock Get-SweeprStartupEntries { [pscustomobject]@{ Measured = $true; Reason = $null; Entries = @(); Count = 0; Missing = @() } }
            { Get-SweeprHealth } | Should -Not -Throw
            $health = Get-SweeprHealth
            @($health.NotMeasured | ForEach-Object Name) | Should -Be @('Disks')
            ($health.NotMeasured | Where-Object Name -eq 'Disks').Reason | Should -Match 'unexpected failure'
            $health.Memory.TotalBytes | Should -Be 1
        }
    }

    Context 'Whole collection against mocked CIM, Storage and registry' {
        BeforeEach {
            Set-RunKeys
            Mock Get-HotFix { [pscustomobject]@{ HotFixID = 'KB5000003'; Description = 'Security Update'; InstalledOn = [datetime]'2026-10-08' } }
            $script:UpdateJob = [pscustomobject]@{ State = 'Completed' }
            Mock Start-Job { $script:UpdateJob }
            Mock Wait-Job { $script:UpdateJob }
            Mock Receive-Job { [pscustomobject]@{ Total = 2; Important = 0 } }
            Mock Stop-Job {}
            Mock Remove-Job {}
        }

        It 'Measures every part as a standard user and changes nothing' {
            $health = Get-SweeprHealth
            $health.IsAdmin | Should -BeFalse
            @($health.NotMeasured).Count | Should -Be 0
            @($health.Disks.Drives).Count | Should -Be 2
            $health.Memory.UsedPercent | Should -Be 75
            $health.Updates.LastInstalledOn.Date | Should -Be ([datetime]'2026-10-08')
            $health.PendingUpdates.Total | Should -Be 2
            $health.Startup.Count | Should -Be 5
            foreach ($name in $script:ChangingCommands) {
                Should -Invoke -CommandName $name -Times 0 -Exactly
            }
        }

        It 'Writes nothing to the console' {
            $all = @(Get-SweeprHealth *>&1)
            @($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }).Count | Should -Be 0
            @($all | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] }).Count | Should -Be 1
            Should -Invoke Start-Spinner -Times 0 -Exactly
        }

        It 'Returns what it can without administrator rights and marks the rest' {
            Mock Get-Partition { throw 'Access is denied' }
            Mock Get-Disk { throw 'Access is denied' }
            Mock Get-PhysicalDisk { throw 'Access is denied' }
            Mock Get-HotFix { throw 'Access is denied' }
            Mock Get-ItemProperty {
                $location = "$Path$LiteralPath"
                if ($location -like '*HKLM*') { throw 'Requested registry access is not allowed' }
                [pscustomobject]@{ NotesSync = 'C:\Example\sync.exe'; PSPath = 'x' }
            }
            $health = Get-SweeprHealth
            $health.IsAdmin | Should -BeFalse
            @($health.NotMeasured | ForEach-Object Name) | Should -Be @('Updates')
            foreach ($drive in @($health.Disks.Drives)) {
                $drive.Health | Should -Be 'Unknown'
                $drive.SizeBytes | Should -BeGreaterThan 0
            }
            $health.Memory.Measured | Should -BeTrue
            $health.Startup.Measured | Should -BeTrue
            @($health.Startup.Missing) | Should -Contain 'HKLM Run'
            Should -Invoke Start-Process -Times 0 -Exactly
        }
    }
}

Describe 'lib/core/health.ps1 on its own' {
    It 'Loads on its own in a new process and defines its functions' {
        $result = Invoke-FreshLoad -File (Join-Path $script:LibDir 'core\health.ps1') -Functions @('Get-SweeprHealth', 'Get-SweeprDiskInfo', 'Get-SweeprStartupEntries')
        $result.Err | Should -BeNullOrEmpty
        $result.ExitCode | Should -Be 0
        foreach ($name in @('Get-SweeprHealth', 'Get-SweeprDiskInfo', 'Get-SweeprStartupEntries')) {
            $result.Out | Should -Match "FOUND $name"
        }
    }
}
