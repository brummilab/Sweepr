# freeMole Windows - History Tests
# fm history reads the operation log Write-MoleOperation appends.

BeforeAll {
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $script:LibDir = Join-Path $script:WindowsDir "lib"
    . "$script:LibDir\core\base.ps1"
    . "$script:LibDir\core\log.ps1"
    . "$script:LibDir\core\history.ps1"

    function Write-Fixture([string[]]$Lines) {
        $path = Join-Path (Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))) "operations.log"
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [System.IO.File]::WriteAllLines($path, $Lines)
        return $path
    }
}

Describe "fm history log reader" {
    It "Groups records by run and counts each action" {
        $path = Write-Fixture @(
            "",
            "# ========== clean run=a1 session started at 2026-10-15 10:00:00 ==========",
            "[2026-10-15 10:00:01] [clean run=a1] REMOVED C:\Temp\one (1.0KB)",
            "[2026-10-15 10:00:02] [clean run=a1] FAILED C:\Temp\two (access denied)",
            "[2026-10-15 10:00:03] [clean run=a1] SKIPPED C:\Temp\three (refused: protected or whitelisted entry inside: C:\Temp\three\keep)",
            "",
            "# ========== uninstall run=b2 session started at 2026-10-15 11:00:00 ==========",
            "[2026-10-15 11:00:01] [uninstall run=b2] UNINSTALLED Fixture App (exit code 0)",
            "[2026-10-15 11:00:02] [uninstall run=b2] RECYCLED C:\Program Files (x86)\Fixture App (2.0MB)"
        )
        $history = Read-MoleHistory -Path $path

        @($history.Sessions).Count | Should -Be 2
        $history.Sessions[0].command | Should -Be "clean"
        $history.Sessions[0].run_id | Should -Be "a1"
        $history.Sessions[0].actions.removed | Should -Be 1
        $history.Sessions[0].actions.failed | Should -Be 1
        $history.Sessions[0].actions.skipped | Should -Be 1
        $history.Sessions[0].actions.other | Should -Be 0
        $history.Sessions[1].actions.uninstalled | Should -Be 1
        $history.Sessions[1].actions.recycled | Should -Be 1
        @($history.Operations).Count | Should -Be 5
        $history.Operations[4].path | Should -BeExactly "C:\Program Files (x86)\Fixture App"
        $history.Operations[4].detail | Should -BeExactly "2.0MB"
    }

    It "Reads back what the writer recorded, parentheses included" {
        $script:OriginalOperationsLog = $script:MoleOperationsLogFile
        $originalNoOplog = $env:MO_NO_OPLOG
        try {
            $env:MO_NO_OPLOG = $null
            $script:MoleOperationsLogFile = Join-Path (Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))) "operations.log"
            $script:MoleOperationsLogStarted = $false
            Write-MoleOperation -Action "FAILED" -Path "C:\Program Files (x86)\App (old)" -Detail "error (5)"
            Write-MoleOperation -Action "REMOVED" -Path "C:\Temp\plain"

            $history = Read-MoleHistory -Path $script:MoleOperationsLogFile
            @($history.Operations).Count | Should -Be 2
            $history.Operations[0].path | Should -BeExactly "C:\Program Files (x86)\App (old)"
            $history.Operations[0].detail | Should -BeExactly "error [5]"
            $history.Operations[1].detail | Should -BeExactly ""
        }
        finally {
            $script:MoleOperationsLogFile = $script:OriginalOperationsLog
            $script:MoleOperationsLogStarted = $false
            $env:MO_NO_OPLOG = $originalNoOplog
        }
    }

    It "Gives a record whose session marker was rotated away its own session" {
        $path = Write-Fixture @("[2026-10-15 10:00:01] [purge run=c3] REMOVED C:\Code\app\node_modules (5.0MB)")
        $history = Read-MoleHistory -Path $path
        @($history.Sessions).Count | Should -Be 1
        $history.Sessions[0].command | Should -Be "purge"
        $history.Sessions[0].started_at | Should -Be "2026-10-15 10:00:01"
    }

    It "Lists the newest entries first within the limit" {
        $newest = @(Select-MoleHistoryNewest -Items @(1, 2, 3, 4) -Limit 2)
        $newest | Should -Be @(4, 3)
        @(Select-MoleHistoryNewest -Items @() -Limit 5).Count | Should -Be 0
    }

    It "Accepts limits from 1 to 200 only" {
        ConvertTo-MoleHistoryLimit "1" | Should -Be 1
        ConvertTo-MoleHistoryLimit "200" | Should -Be 200
        foreach ($bad in @("0", "201", "-1", "abc", "", "1000")) {
            ConvertTo-MoleHistoryLimit $bad | Should -BeNullOrEmpty
        }
    }

    It "Keeps sessions and operations as JSON arrays, empty or with one entry" {
        $empty = ConvertTo-MoleHistoryJson -History (Read-MoleHistory -Path (Join-Path $TestDrive "missing.log")) -Limit 20 -LogPath "x" | ConvertFrom-Json
        $empty.limit | Should -Be 20
        @($empty.sessions).Count | Should -Be 0
        $empty.PSObject.Properties.Name | Should -Contain "operations"

        $path = Write-Fixture @("[2026-10-15 10:00:01] [clean run=a1] REMOVED C:\Temp\one (1.0KB)")
        $text = ConvertTo-MoleHistoryJson -History (Read-MoleHistory -Path $path) -Limit 20 -LogPath $path
        $text | Should -Match '"sessions":\s*\['
        $text | Should -Match '"operations":\s*\['
        ($text | ConvertFrom-Json).operations[0].action | Should -Be "removed"
    }
}

Describe "fm history command" {
    BeforeAll {
        $script:freeMole = Join-Path $script:WindowsDir "freemole.ps1"
        $script:Profile = Join-Path $TestDrive "profile"
        New-Item -ItemType Directory -Path (Join-Path $script:Profile ".config\freemole") -Force | Out-Null
        [System.IO.File]::WriteAllLines((Join-Path $script:Profile ".config\freemole\operations.log"), @(
                "# ========== clean run=a1 session started at 2026-10-15 10:00:00 ==========",
                "[2026-10-15 10:00:01] [clean run=a1] REMOVED C:\Temp\one (1.0KB)",
                "[2026-10-15 10:00:02] [clean run=a1] REMOVED C:\Temp\two (2.0KB)"
            ))
        function Invoke-History([string[]]$Arguments) {
            $original = $env:USERPROFILE
            try {
                $env:USERPROFILE = $script:Profile
                $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:freeMole history @Arguments 2>&1 | Out-String
                return @{ Output = $output; ExitCode = $LASTEXITCODE }
            }
            finally { $env:USERPROFILE = $original }
        }
    }

    It "Takes the limit as <Form>" -ForEach @(
        @{ Form = "two words"; Arguments = @("--limit", "1", "--json") },
        @{ Form = "one word"; Arguments = @("--limit=1", "--json") }
    ) {
        $result = Invoke-History $Arguments
        $result.ExitCode | Should -Be 0
        $report = $result.Output | ConvertFrom-Json
        @($report.operations).Count | Should -Be 1
        $report.operations[0].path | Should -BeExactly "C:\Temp\two"
    }

    It "Prints sessions and operations as text" {
        $result = Invoke-History @()
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match "clean\s+2026-10-15 10:00:00, removed 2"
        $result.Output | Should -Match "removed\s+C:\\Temp\\two \(2\.0KB\)"
    }

    It "Refuses <Case> with exit code 2" -ForEach @(
        @{ Case = "a limit out of range"; Arguments = @("--limit", "0") },
        @{ Case = "a missing limit"; Arguments = @("--limit") },
        @{ Case = "a stray argument"; Arguments = @("extra") }
    ) {
        (Invoke-History $Arguments).ExitCode | Should -Be 2
    }
}
