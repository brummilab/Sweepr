BeforeAll {
    $script:RunnerSource = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\test.ps1'
    $script:PowerShellExe = (Get-Process -Id $PID).Path

    function Invoke-FixtureRunner {
        param([string]$TestBody, [switch]$OnlyGo, [string]$GoBody, [switch]$TwoGo)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $scripts = New-Item -ItemType Directory -Path (Join-Path $root 'scripts')
        $tests = New-Item -ItemType Directory -Path (Join-Path $root 'tests')
        $runner = Join-Path $scripts.FullName 'test.ps1'
        Copy-Item -LiteralPath $script:RunnerSource -Destination $runner
        if ($TestBody) {
            Set-Content -LiteralPath (Join-Path $tests.FullName 'Fixture.Tests.ps1') -Value $TestBody -Encoding UTF8
        }
        $oldPath = $env:PATH
        # A failing child is the fixture result, not a failure of this helper.
        $ErrorActionPreference = 'Continue'
        try {
            if ($OnlyGo) {
                $env:PATH = $root
                if ($GoBody) {
                    Set-Content -LiteralPath (Join-Path $root 'go.cmd') -Value $GoBody -Encoding ASCII
                }
                if ($TwoGo) {
                    # A hosted runner can carry its preinstalled Go and the one setup-go added.
                    $second = New-Item -ItemType Directory -Path (Join-Path $root 'second')
                    Copy-Item -LiteralPath (Join-Path $root 'go.cmd') -Destination (Join-Path $second.FullName 'go.cmd')
                    $env:PATH = "$root;$($second.FullName)"
                }
                $output = & $script:PowerShellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runner -NoPester 2>&1
            }
            else {
                $output = & $script:PowerShellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runner -NoGo 2>&1
            }
            $code = $LASTEXITCODE
            [pscustomobject]@{ ExitCode = $code; Output = ($output | Out-String) }
        }
        finally {
            $env:PATH = $oldPath
        }
    }
}

Describe 'Test runner exit status' {
    It 'fails when an actual Pester assertion fails' {
        $result = Invoke-FixtureRunner -TestBody "Describe 'fixture' { It 'fails' { 1 | Should -Be 2 } }"
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Not -Match 'All Pester tests passed'
    }

    It 'passes when an actual Pester assertion passes' {
        $result = Invoke-FixtureRunner -TestBody "Describe 'fixture' { It 'passes' { 1 | Should -Be 1 } }"
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'All Pester tests passed'
    }

    It 'fails when Pester discovers no tests' {
        $result = Invoke-FixtureRunner
        $result.ExitCode | Should -Be 1
    }

    It 'does not count an entirely skipped Pester suite as passed' {
        $result = Invoke-FixtureRunner -TestBody "Describe 'fixture' { It 'skipped' -Skip { 1 | Should -Be 1 } }"
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Not -Match 'All Pester tests passed'
    }

    It 'fails when Go is unavailable unless NoGo was requested' {
        $result = Invoke-FixtureRunner -OnlyGo
        $result.ExitCode | Should -Be 1
    }

    It 'fails when the Go version probe exits unsuccessfully' {
        $result = Invoke-FixtureRunner -OnlyGo -GoBody "@echo off`r`nexit /b 7"
        $result.ExitCode | Should -Be 1
    }

    It 'preserves failure from native go test' {
        $result = Invoke-FixtureRunner -OnlyGo -GoBody "@echo off`r`nif `%1==version exit /b 0`r`nexit /b 7"
        $result.ExitCode | Should -Be 1
    }

    It 'passes when the native Go checks pass' {
        $result = Invoke-FixtureRunner -OnlyGo -GoBody "@echo off`r`nexit /b 0"
        $result.ExitCode | Should -Be 0
    }

    It 'passes when two Go installs are on PATH' {
        $result = Invoke-FixtureRunner -OnlyGo -TwoGo -GoBody "@echo off`r`nexit /b 0"
        $result.ExitCode | Should -Be 0
    }
}
