BeforeAll {
    $script:SavedDryRun = $env:SWEEPR_DRY_RUN
    $script:ProjectRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:ProjectRoot 'lib\core\update_check.ps1')
    function Get-CachePath { $TestDrive }
    function Test-SweeprInteractiveOutput { $false }
}

AfterAll { $env:SWEEPR_DRY_RUN = $script:SavedDryRun }

Describe 'Automatic update notices' {
    BeforeEach {
        $env:SWEEPR_DRY_RUN = $null
        $script:CacheFile = Join-Path $TestDrive 'update-check.json'
        $script:Context = @{ Path = $script:CacheFile; Key = 'fixture|1.9.0|Source'; Version = '1.9.0'; Method = 'Source' }
        $script:State = @{ Schema = 1; Key = $script:Context.Key; CheckedTicks = [DateTime]::UtcNow.Ticks; Interval = 86400; Latest = '1.10.0' }
        Write-SweeprUpdateState -Path $script:CacheFile -State $script:State
    }

    It 'Selects published Windows stable tags numerically, never names or the latest marker' {
        Mock Invoke-RestMethod {
            @(
                @{ tag_name = 'V9.99.0'; draft = $false; prerelease = $false },
                @{ tag_name = 'V1.99.0-windows'; draft = $true; prerelease = $false },
                @{ tag_name = 'V1.98.0-windows'; draft = $false; prerelease = $true },
                @{ tag_name = 'V1.97.0-beta-windows'; draft = $false; prerelease = $false },
                @{ tag_name = 'V1.9.0-windows'; draft = $false; prerelease = $false },
                @{ tag_name = 'V1.10.0-windows'; name = 'Horizon'; draft = $false; prerelease = $false }
            )
        }
        Get-SweeprAvailableVersion -Method Source | Should -Be '1.10.0'
        Should -Invoke Invoke-RestMethod -Exactly 1 -ParameterFilter { $Uri -eq 'https://api.github.com/repos/brummilab/sweepr/releases?per_page=100' -and $TimeoutSec -eq 10 }
    }

    It 'Reads Scoop version from its published manifest' {
        Mock Invoke-RestMethod { @{ version = '1.8.0' } }
        Get-SweeprAvailableVersion -Method Scoop | Should -Be '1.8.0'
        Should -Invoke Invoke-RestMethod -Exactly 1 -ParameterFilter { $Uri -like '*ScoopInstaller/Main/*/bucket/sweepr.json' }
    }

    It 'Reads winget published version directories and ignores preview entries' {
        Mock Invoke-RestMethod { @(@{ type = 'dir'; name = '1.9.0' }, @{ type = 'dir'; name = '1.10.0' }, @{ type = 'dir'; name = '1.11.0-beta' }, @{ type = 'file'; name = '9.0.0' }) }
        Get-SweeprAvailableVersion -Method winget | Should -Be '1.10.0'
    }

    It 'Uses the channel-specific update action for <Method>' -ForEach @(
        @{ Method = 'Source'; Action = 'run sw update' },
        @{ Method = 'winget'; Action = 'run winget upgrade brummilab.Sweepr' },
        @{ Method = 'Scoop'; Action = 'run scoop update sweepr' },
        @{ Method = 'Copy'; Action = 'download https://github.com/brummilab/sweepr/releases/tag/V1.10.0-windows' }
    ) {
        $script:Context.Method = $Method
        Get-SweeprUpdateNotice -Context $script:Context | Should -Be "Update 1.10.0 available, $Action"
    }

    # F-01b / Design Rev 2, section 9: a portable copy gets its own download hint
    # that names the portable asset; the plain Copy hint must not.
    It 'Gives Portable its own download hint with the portable asset name' {
        $script:Context.Method = 'Portable'
        $notice = Get-SweeprUpdateNotice -Context $script:Context
        $notice | Should -Match '^Update 1\.10\.0 available, '
        $notice | Should -Match 'download '
        $notice | Should -Match 'https://github\.com/brummilab/sweepr/releases'
        $notice | Should -Match ([regex]::Escape('sweepr-1.10.0-x64-portable.zip'))
    }

    It 'Does not mention the portable asset in the notice for a plain Copy' {
        $script:Context.Method = 'Copy'
        Get-SweeprUpdateNotice -Context $script:Context | Should -Not -Match 'portable'
    }

    It 'Builds the portable asset name from the advertised version only' {
        $script:Context.Method = 'Portable'
        $script:State.Latest = '2.0.7'
        Write-SweeprUpdateState -Path $script:CacheFile -State $script:State
        $notice = Get-SweeprUpdateNotice -Context $script:Context
        $notice | Should -Match ([regex]::Escape('sweepr-2.0.7-x64-portable.zip'))
        $notice | Should -Not -Match '1\.10\.0'
    }

    It 'Never advertises an equal, older, prerelease or invalid version <Latest>' -ForEach @(
        @{ Latest = '1.9.0' }, @{ Latest = '1.8.9' }, @{ Latest = '1.10.0-beta' }, @{ Latest = "1.10.0`nrun something" }
    ) {
        $script:State.Latest = $Latest
        Write-SweeprUpdateState -Path $script:CacheFile -State $script:State
        Get-SweeprUpdateNotice -Context $script:Context | Should -BeNullOrEmpty
    }

    It 'Invalidates notices for a changed installation, version or channel' {
        $script:Context.Key = 'other|1.10.0|Scoop'
        Get-SweeprUpdateNotice -Context $script:Context | Should -BeNullOrEmpty
    }

    It 'Ignores corrupt cache data without affecting the command' {
        [IO.File]::WriteAllText($script:CacheFile, '{broken')
        { Show-SweeprUpdateNotice -Context $script:Context } | Should -Not -Throw
        Get-SweeprUpdateNotice -Context $script:Context | Should -BeNullOrEmpty
    }

    It 'Suppresses expired and future-dated notices' {
        foreach ($days in @(-2, 1)) {
            $script:State.CheckedTicks = [DateTime]::UtcNow.AddDays($days).Ticks
            Write-SweeprUpdateState -Path $script:CacheFile -State $script:State
            Get-SweeprUpdateNotice -Context $script:Context | Should -BeNullOrEmpty
        }
    }

    It 'Does not perform network work while reading a fresh cached notice' {
        Mock Invoke-RestMethod { throw 'unexpected network request' }
        $script:State.Key = 'fixture|1.9.0|Source'
        $context = Start-SweeprUpdateCheck -RootDir fixture -Version '1.9.0' -Method Source
        Get-SweeprUpdateNotice -Context $context | Should -Match '1.10.0'
        Should -Invoke Invoke-RestMethod -Exactly 0
    }

    It 'Keeps a failed lookup quiet and retains its one-hour retry interval' {
        $script:State.Interval = 3600
        $script:State.Latest = ''
        Write-SweeprUpdateState -Path $script:CacheFile -State $script:State
        Mock Invoke-RestMethod { throw 'offline' }
        { Invoke-SweeprUpdateLookup -Path $script:CacheFile -Key $script:Context.Key -Method Source } | Should -Not -Throw
        (Read-SweeprUpdateState -Path $script:CacheFile -Key $script:Context.Key).Interval | Should -Be 3600
        Get-SweeprUpdateNotice -Context $script:Context | Should -BeNullOrEmpty
    }

    It 'Caches a successful lookup for a day' {
        Mock Get-SweeprAvailableVersion { '1.11.0' }
        Invoke-SweeprUpdateLookup -Path $script:CacheFile -Key $script:Context.Key -Method Source
        $state = Read-SweeprUpdateState -Path $script:CacheFile -Key $script:Context.Key
        $state.Interval | Should -Be 86400
        $state.Latest | Should -Be '1.11.0'
    }

    It 'Never enables automatic checks for redirected commands' {
        Mock Test-SweeprInteractiveOutput { $false }
        Test-SweeprUpdateNoticeAllowed -CommandName clean -Arguments @() | Should -BeFalse
    }

    It 'Allows an interactive menu and ordinary clean command' {
        Mock Test-SweeprInteractiveOutput { $true }
        # This predicate does not substitute a redirected stderr for a terminal.
        if (-not [Console]::IsErrorRedirected) {
            Test-SweeprUpdateNoticeAllowed -CommandName '' -Arguments @() | Should -BeTrue
            Test-SweeprUpdateNoticeAllowed -CommandName clean -Arguments @() | Should -BeTrue
        }
        else {
            Test-SweeprUpdateNoticeAllowed -CommandName clean -Arguments @() | Should -BeFalse
        }
    }

    It 'Keeps an environment-selected preview read-only' {
        Mock Test-SweeprInteractiveOutput { $true }
        $env:SWEEPR_DRY_RUN = '1'
        Test-SweeprUpdateNoticeAllowed -CommandName clean -Arguments @() | Should -BeFalse
    }

    It 'Keeps automation, previews and explicit update paths quiet for <CommandName> <Argument>' -ForEach @(
        @{ CommandName = 'status'; Argument = '--json' },
        @{ CommandName = 'status'; Argument = '--ndjson' },
        @{ CommandName = 'status'; Argument = '--watch=3' },
        @{ CommandName = 'clean'; Argument = '--help' },
        @{ CommandName = 'clean'; Argument = '--dry-run' },
        @{ CommandName = 'clean'; Argument = '--whitelist' },
        @{ CommandName = 'update'; Argument = '' },
        @{ CommandName = 'remove'; Argument = '' },
        @{ CommandName = 'history'; Argument = '--json' }
    ) {
        Mock Test-SweeprInteractiveOutput { $true }
        Test-SweeprUpdateNoticeAllowed -CommandName $CommandName -Arguments @($Argument) | Should -BeFalse
    }
}
