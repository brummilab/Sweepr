# Real sinks run only inside Pester's isolated fixture tree.
BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    . "$repo\lib\clean\caches.ps1"
    . "$repo\lib\clean\dev.ps1"
    . "$repo\lib\clean\user.ps1"
    . "$repo\lib\clean\apps.ps1"
    . "$repo\lib\clean\system.ps1"
    $script:SavedCacheEnvironment = @{}
    foreach ($name in @('USERPROFILE', 'LOCALAPPDATA', 'APPDATA', 'WINDIR', 'SWEEPR_NO_OPLOG')) {
        $script:SavedCacheEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    $script:SavedCacheWhitelist = $script:Config.WhitelistFile
    $script:SavedCacheGuard = $script:SweeprCleanPathGuard
    $script:SavedCacheDryRun = $script:SweeprDryRunMode
    function New-CacheFile([string]$Path) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
        [IO.File]::WriteAllText($Path, 'cache fixture')
        return $Path
    }
}
AfterAll {
    foreach ($name in $script:SavedCacheEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $script:SavedCacheEnvironment[$name])
    }
    $script:Config.WhitelistFile = $script:SavedCacheWhitelist
    $script:SweeprCleanPathGuard = $script:SavedCacheGuard
    $script:SweeprDryRunMode = $script:SavedCacheDryRun
}

Describe 'Application cache boundaries' {
    BeforeEach {
        $env:USERPROFILE = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0,8))
        $env:LOCALAPPDATA = Join-Path $env:USERPROFILE 'Local'
        $env:APPDATA = Join-Path $env:USERPROFILE 'Roaming'
        $env:WINDIR = Join-Path $env:USERPROFILE 'Windows'
        $env:SWEEPR_NO_OPLOG = '1'
        $script:Config.WhitelistFile = Join-Path $env:USERPROFILE 'whitelist.txt'
        $script:ExportListFile = Join-Path $env:USERPROFILE 'preview.txt'
        $script:SweeprCleanPathGuard = $true
        Set-DryRunMode -Enabled $false
        Reset-CleanupStats
        Mock Get-Process { @() }
        Mock Invoke-SweeprOwnerCacheCleanup {}
        Mock Start-Section {}
        Mock Stop-Section {}
    }

    It 'Keeps recent error reports and dumps in preview and real cleanup' {
        $old = New-CacheFile "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportArchive\old\Report.wer"
        $recent = New-CacheFile "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportArchive\recent\Report.wer"
        $oldDump = New-CacheFile "$env:LOCALAPPDATA\CrashDumps\old.dmp"
        $recentDump = New-CacheFile "$env:LOCALAPPDATA\CrashDumps\recent.dmp"
        foreach ($path in @($old, (Split-Path $old), $oldDump)) {
            (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddDays(-10)
            (Get-Item -LiteralPath $path).CreationTime = (Get-Date).AddDays(-10)
        }
        Set-DryRunMode -Enabled $true
        Clear-ErrorReports -DaysOld 7
        Test-Path -LiteralPath $old | Should -BeTrue
        $preview = Get-Content -LiteralPath $script:ExportListFile -Raw
        $preview | Should -Match 'old'
        $preview | Should -Not -Match 'recent'
        Set-DryRunMode -Enabled $false
        Clear-ErrorReports -DaysOld 7
        Test-Path -LiteralPath $old | Should -BeFalse
        Test-Path -LiteralPath $oldDump | Should -BeFalse
        Test-Path -LiteralPath $recent | Should -BeTrue
        Test-Path -LiteralPath $recentDump | Should -BeTrue
    }

    It 'Keeps an old report directory with a recently written attachment' {
        $report = New-CacheFile "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportQueue\old\Report.wer"
        $fresh = New-CacheFile "$(Split-Path $report)\attachment.dmp"
        foreach ($path in @($report, (Split-Path $report))) {
            (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddDays(-10)
            (Get-Item -LiteralPath $path).CreationTime = (Get-Date).AddDays(-10)
        }
        Clear-ErrorReports
        Test-Path -LiteralPath $report | Should -BeTrue
        Test-Path -LiteralPath $fresh | Should -BeTrue
    }

    It 'Keeps a report that receives an attachment after sizing' {
        $report = New-CacheFile "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportArchive\old\Report.wer"
        foreach ($path in @($report, (Split-Path $report))) {
            (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddDays(-10)
            (Get-Item -LiteralPath $path).CreationTime = (Get-Date).AddDays(-10)
        }
        $script:ReportAttachment = "$(Split-Path $report)\new.dmp"
        Mock Get-SwValidatedTreeSize {
            [IO.File]::WriteAllText($script:ReportAttachment, 'new diagnostic')
            return 10
        }
        Clear-ErrorReports
        Test-Path -LiteralPath $report | Should -BeTrue
        Test-Path -LiteralPath $script:ReportAttachment | Should -BeTrue
        (Get-CleanupStats).FilesCleaned | Should -Be 0
    }

    It 'Cleans Sublime Local and existing Roaming caches only while the owner is idle' {
        $local = New-CacheFile "$env:LOCALAPPDATA\Sublime Text\Cache\entry"
        $roaming = New-CacheFile "$env:APPDATA\Sublime Text\Cache\entry"
        $settings = New-CacheFile "$env:APPDATA\Sublime Text\Packages\User\settings"
        Mock Get-Process { [pscustomobject]@{ProcessName='sublime_text'} }
        Clear-EditorCaches
        Test-Path -LiteralPath $local | Should -BeTrue
        Test-Path -LiteralPath $roaming | Should -BeTrue
        Mock Get-Process { @() }
        Clear-EditorCaches
        Test-Path -LiteralPath $local | Should -BeFalse
        Test-Path -LiteralPath $roaming | Should -BeFalse
        Test-Path -LiteralPath $settings | Should -BeTrue
    }

    It 'Keeps the <Editor> cache <Root>\<Leaf> while <Owner> runs and cleans it once idle' -ForEach @(
        @{Editor='VS Code'; Owner='Code'; Root='APPDATA'; Leaf='Code\Cache'}
        @{Editor='VS Code'; Owner='Code'; Root='APPDATA'; Leaf='Code\CachedData'}
        @{Editor='VS Code'; Owner='Code'; Root='APPDATA'; Leaf='Code\CachedExtensions'}
        @{Editor='VS Code'; Owner='Code'; Root='APPDATA'; Leaf='Code\CachedExtensionVSIXs'}
        @{Editor='VS Code'; Owner='Code'; Root='APPDATA'; Leaf='Code\Code Cache'}
        @{Editor='VS Code'; Owner='Code'; Root='APPDATA'; Leaf='Code\GPUCache'}
        @{Editor='cpptools'; Owner='Code'; Root='LOCALAPPDATA'; Leaf='Microsoft\vscode-cpptools'}
        @{Editor='VS Code Insiders'; Owner='Code - Insiders'; Root='APPDATA'; Leaf='Code - Insiders\Cache'}
        @{Editor='VS Code Insiders'; Owner='Code - Insiders'; Root='APPDATA'; Leaf='Code - Insiders\GPUCache'}
        @{Editor='Zed'; Owner='zed'; Root='LOCALAPPDATA'; Leaf='Zed\cache'}
        @{Editor='Zed'; Owner='zed'; Root='APPDATA'; Leaf='Zed\cache'}
    ) {
        $base = [Environment]::GetEnvironmentVariable($Root)
        $cache = (Get-Item -LiteralPath (New-CacheFile (Join-Path (Join-Path $base $Leaf) 'entry'))).FullName
        $script:EditorOwner = $Owner
        Mock Get-Process { [pscustomobject]@{ProcessName=$script:EditorOwner} }
        Set-DryRunMode -Enabled $true
        Clear-EditorCaches
        if (Test-Path -LiteralPath $script:ExportListFile) {
            Get-Content -LiteralPath $script:ExportListFile -Raw | Should -Not -Match ([regex]::Escape($cache))
        }
        Set-DryRunMode -Enabled $false
        Clear-EditorCaches
        Test-Path -LiteralPath $cache | Should -BeTrue
        (Get-CleanupStats).FilesCleaned | Should -Be 0
        Mock Get-Process { @() }
        Clear-EditorCaches
        Test-Path -LiteralPath $cache | Should -BeFalse
    }

    It 'Keeps VS Code and Zed caches when the editor process probe fails' {
        $code = New-CacheFile "$env:APPDATA\Code\Cache\entry"
        $cpptools = New-CacheFile "$env:LOCALAPPDATA\Microsoft\vscode-cpptools\ipch\entry"
        $zed = New-CacheFile "$env:LOCALAPPDATA\Zed\cache\entry"
        Mock Get-Process { throw 'unavailable' }
        Clear-EditorCaches
        Test-Path -LiteralPath $code | Should -BeTrue
        Test-Path -LiteralPath $cpptools | Should -BeTrue
        Test-Path -LiteralPath $zed | Should -BeTrue
        (Get-CleanupStats).FilesCleaned | Should -Be 0
    }

    It 'Keeps recent crash dumps and non-dump entries in system dump cleanup preview and real run' {
        $recent = New-CacheFile "$env:LOCALAPPDATA\CrashDumps\recent.dmp"
        $note = New-CacheFile "$env:LOCALAPPDATA\CrashDumps\old-notes.txt"
        $nested = New-CacheFile "$env:LOCALAPPDATA\CrashDumps\old-folder\inner.dmp"
        foreach ($path in @($note, $nested, (Split-Path $nested))) {
            (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddDays(-10)
            (Get-Item -LiteralPath $path).CreationTime = (Get-Date).AddDays(-10)
        }
        Set-DryRunMode -Enabled $true
        Clear-MemoryDumps
        if (Test-Path -LiteralPath $script:ExportListFile) {
            $preview = Get-Content -LiteralPath $script:ExportListFile -Raw
            $preview | Should -Not -Match 'recent\.dmp'
            $preview | Should -Not -Match 'old-notes'
            $preview | Should -Not -Match 'old-folder'
        }
        Set-DryRunMode -Enabled $false
        Clear-MemoryDumps
        Test-Path -LiteralPath $recent | Should -BeTrue
        Test-Path -LiteralPath $note | Should -BeTrue
        Test-Path -LiteralPath $nested | Should -BeTrue
    }

    It 'Removes only old crash dumps across user and system cleanup' {
        $old = New-CacheFile "$env:LOCALAPPDATA\CrashDumps\old.dmp"
        $recent = New-CacheFile "$env:LOCALAPPDATA\CrashDumps\recent.dmp"
        $note = New-CacheFile "$env:LOCALAPPDATA\CrashDumps\old-notes.txt"
        foreach ($path in @($old, $note)) {
            (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddDays(-10)
            (Get-Item -LiteralPath $path).CreationTime = (Get-Date).AddDays(-10)
        }
        Set-DryRunMode -Enabled $true
        Clear-ErrorReports -DaysOld 7
        Clear-MemoryDumps
        Test-Path -LiteralPath $old | Should -BeTrue
        $preview = Get-Content -LiteralPath $script:ExportListFile -Raw
        $preview | Should -Match 'old\.dmp'
        $preview | Should -Not -Match 'recent\.dmp'
        $preview | Should -Not -Match 'old-notes'
        Set-DryRunMode -Enabled $false
        Clear-ErrorReports -DaysOld 7
        Clear-MemoryDumps
        Test-Path -LiteralPath $old | Should -BeFalse
        Test-Path -LiteralPath $recent | Should -BeTrue
        Test-Path -LiteralPath $note | Should -BeTrue
    }

    It 'Keeps Adobe Team Projects state beside rebuildable media caches' {
        $state = New-CacheFile "$env:APPDATA\Adobe\Common\Team Projects Cache\project.db"
        $media = New-CacheFile "$env:APPDATA\Adobe\Common\Media Cache Files\clip.cache"
        Set-DryRunMode -Enabled $true
        Clear-AdobeData
        Get-Content -LiteralPath $script:ExportListFile -Raw | Should -Not -Match 'Team Projects Cache'
        Set-DryRunMode -Enabled $false
        Clear-AdobeData
        Test-Path -LiteralPath $state | Should -BeTrue
        Test-Path -LiteralPath $media | Should -BeFalse
    }

    It 'Protects Team Projects state at the shared clean sink including parent sweeps' {
        $state = New-CacheFile "$env:APPDATA\Adobe\Common\Team Projects Cache\project.db"
        $neighbor = New-CacheFile "$env:APPDATA\Adobe\Common\Team Projects Cache Backup\entry"
        Remove-SafeItem -Path "$env:APPDATA\Adobe\Common" -Recurse | Should -BeFalse
        Remove-SafeItem -Path $state | Should -BeFalse
        Test-Path -LiteralPath $state | Should -BeTrue
        Remove-SafeItem -Path $neighbor | Should -BeTrue
    }

    It 'Keeps Poetry virtualenvs while cleaning its two disposable children' {
        $root = "$env:LOCALAPPDATA\pypoetry\Cache"
        $venv = New-CacheFile "$root\virtualenvs\project\Scripts\python.exe"
        $artifact = New-CacheFile "$root\artifacts\a.whl"
        $cache = New-CacheFile "$root\cache\repo\entry"
        Set-DryRunMode -Enabled $true
        Clear-PythonCaches
        Test-Path -LiteralPath $artifact | Should -BeTrue
        Test-Path -LiteralPath $venv | Should -BeTrue
        Get-Content -LiteralPath $script:ExportListFile -Raw | Should -Not -Match 'virtualenvs'
        Set-DryRunMode -Enabled $false
        Clear-PythonCaches
        Test-Path -LiteralPath $venv | Should -BeTrue
        Test-Path -LiteralPath $artifact | Should -BeFalse
        Test-Path -LiteralPath $cache | Should -BeFalse
    }

    It 'Keeps offline CacheStorage beside an eligible Slack disk cache' {
        $offline = New-CacheFile "$env:APPDATA\Slack\Service Worker\CacheStorage\offline"
        $cache = New-CacheFile "$env:APPDATA\Slack\Cache\entry"
        Clear-AppCaches
        Test-Path -LiteralPath $offline | Should -BeTrue
        Test-Path -LiteralPath $cache | Should -BeFalse
    }

    It 'Cleans every Chromium profile for <Brand> and preserves offline data' -ForEach @(
        @{Brand='Chrome'; Relative='Google\Chrome\User Data'},
        @{Brand='Edge'; Relative='Microsoft\Edge\User Data'},
        @{Brand='Brave'; Relative='BraveSoftware\Brave-Browser\User Data'},
        @{Brand='Vivaldi'; Relative='Vivaldi\User Data'}
    ) {
        $root = Join-Path $env:LOCALAPPDATA $Relative
        $files = @(foreach ($profile in @('Default','Profile 2','Profile [work]')) {
            foreach ($leaf in @('Cache','Code Cache','GPUCache')) { New-CacheFile "$root\$profile\$leaf\entry" }
        })
        $offline = New-CacheFile "$root\Default\Service Worker\CacheStorage\offline"
        $cookie = New-CacheFile "$root\Profile 2\Cookies"
        Clear-BrowserCaches
        foreach ($file in $files) { Test-Path -LiteralPath $file | Should -BeFalse }
        Test-Path -LiteralPath $offline | Should -BeTrue
        Test-Path -LiteralPath $cookie | Should -BeTrue
    }

    It 'Uses Firefox local caches and keeps its roaming profile stores' {
        $cache = New-CacheFile "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles\p.default\cache2\entry"
        $shader = New-CacheFile "$env:APPDATA\Mozilla\Firefox\Profiles\p.default\shader-cache\entry"
        $profile = New-CacheFile "$env:APPDATA\Mozilla\Firefox\Profiles\p.default\cache2\kept"
        Clear-BrowserCaches
        Test-Path -LiteralPath $cache | Should -BeFalse
        Test-Path -LiteralPath $shader | Should -BeFalse
        Test-Path -LiteralPath $profile | Should -BeTrue
    }

    It 'Cleans exact application caches for <Folder> and keeps authored state' -ForEach @(
        @{Folder='Cursor'}, @{Folder='Windsurf'}, @{Folder='obsidian'}, @{Folder='Notion'}
    ) {
        $cache = New-CacheFile "$env:APPDATA\$Folder\Code Cache\entry"
        $state = New-CacheFile "$env:APPDATA\$Folder\User\workspaceStorage\state"
        $offline = New-CacheFile "$env:APPDATA\$Folder\Service Worker\CacheStorage\offline"
        Clear-AppCaches
        Test-Path -LiteralPath $cache | Should -BeFalse
        Test-Path -LiteralPath $state | Should -BeTrue
        Test-Path -LiteralPath $offline | Should -BeTrue
    }

    It 'Allows only new Teams WebView disk-cache leaves within Packages' {
        $root = "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView"
        $cache = New-CacheFile "$root\Default\Cache\entry"
        $kept = @(
            (New-CacheFile "$root\Default\IndexedDB\state"),
            (New-CacheFile "$root\Default\CacheStorage\offline"),
            (New-CacheFile "$root\Cache\entry"),
            (New-CacheFile "$env:LOCALAPPDATA\Packages\Other_app\LocalCache\Default\Cache\entry")
        )
        Clear-AppCaches
        Test-Path -LiteralPath $cache | Should -BeFalse
        foreach ($file in $kept) { Test-Path -LiteralPath $file | Should -BeTrue; Test-SafePath $file | Should -BeFalse }
        $script:SweeprCleanPathGuard = $false
        Test-SafePath "$root\Default\Cache" | Should -BeFalse
    }

    It 'Honors an explicit Packages whitelist even for Teams cache leaves' {
        $cache = New-CacheFile "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\Default\Cache\entry"
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value "$env:LOCALAPPDATA\Packages\*"
        Clear-AppCaches
        Test-Path -LiteralPath $cache | Should -BeTrue
        (Get-CleanupStats).FilesCleaned | Should -Be 0
    }

    It 'Keeps caches when the owner runs or its process probe fails for <Unknown>' -ForEach @(@{Unknown=$false},@{Unknown=$true}) {
        $cache = New-CacheFile "$env:APPDATA\Cursor\Cache\entry"
        if ($Unknown) { Mock Get-Process { throw 'unavailable' } }
        else { Mock Get-Process { [pscustomobject]@{ProcessName='Cursor'} } }
        Clear-AppCaches
        Test-Path -LiteralPath $cache | Should -BeTrue
        (Get-CleanupStats).FilesCleaned | Should -Be 0
    }

    It 'Rechecks the owner after sizing in dry-run <Dry>' -ForEach @(@{Dry=$true},@{Dry=$false}) {
        Set-DryRunMode -Enabled $Dry
        $cache = New-CacheFile "$env:APPDATA\Cursor\Cache\nested\entry"
        $script:CacheOwnerStarted = $false
        Mock Get-Process { if ($script:CacheOwnerStarted) { [pscustomobject]@{ProcessName='Cursor'} } }
        Mock Get-SwValidatedTreeSize { $script:CacheOwnerStarted = $true; return 13 }
        Clear-AppCaches
        Should -Invoke Get-SwValidatedTreeSize -Times 1 -Exactly
        Test-Path -LiteralPath $cache | Should -BeTrue
        (Get-CleanupStats).FilesCleaned | Should -Be 0
        Test-Path -LiteralPath $script:ExportListFile | Should -BeFalse
    }

    It 'Preserves protected stores even when passed to the shared sink directly' {
        $files = @(
            (New-CacheFile "$env:LOCALAPPDATA\pypoetry\Cache\virtualenvs\project\python.exe"),
            (New-CacheFile "$env:APPDATA\Slack\Service Worker\CacheStorage\offline")
        )
        $ordinary = New-CacheFile "$env:APPDATA\Slack\Cache\entry"
        Remove-SafeItems -Paths ($files + @($ordinary))
        foreach ($file in $files) { Test-Path -LiteralPath $file | Should -BeTrue }
        Test-Path -LiteralPath $ordinary | Should -BeFalse
    }

    It 'Records a last-moment busy owner as skipped with no reclaimed files' {
        $cache = New-CacheFile "$env:APPDATA\Cursor\Cache\nested\entry"
        $script:OwnerProbeCalls = 0
        Mock Get-Process {
            $script:OwnerProbeCalls++
            if ($script:OwnerProbeCalls -ge 3) { [pscustomobject]@{ProcessName='Cursor'} }
        }
        Mock Write-SweeprOperation {}
        Clear-AppCaches
        Test-Path -LiteralPath $cache | Should -BeTrue
        (Get-CleanupStats).FilesCleaned | Should -Be 0
        Should -Invoke Write-SweeprOperation -Times 1 -Exactly -ParameterFilter { $Action -eq 'SKIPPED' }
        Should -Invoke Write-SweeprOperation -Times 0 -Exactly -ParameterFilter { $Action -eq 'REMOVED' -or $Action -eq 'FAILED' }
    }

    It 'Supports Opera root and profile caches in both app-data locations' {
        $files = @(foreach ($root in @($env:APPDATA,$env:LOCALAPPDATA)) {
            New-CacheFile "$root\Opera Software\Opera Stable\Cache\entry"
            New-CacheFile "$root\Opera Software\Opera Stable\Default\Code Cache\entry"
        })
        Clear-BrowserCaches
        foreach ($file in $files) { Test-Path -LiteralPath $file | Should -BeFalse }
    }

    It 'Keeps locked new Teams caches and cleans them after the lock closes' {
        $root = "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView"
        $cache = New-CacheFile "$root\Default\Cache\entry"
        $lock = New-CacheFile "$root\lockfile"
        $handle = [IO.File]::Open($lock,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try { Clear-AppCaches; Test-Path -LiteralPath $cache | Should -BeTrue }
        finally { $handle.Dispose() }
        Clear-AppCaches
        Test-Path -LiteralPath $cache | Should -BeFalse
        Test-Path -LiteralPath $lock | Should -BeTrue
    }

    It 'Never follows a linked browser profile and still cleans a real profile' {
        $root = "$env:LOCALAPPDATA\Google\Chrome\User Data"
        $cache = New-CacheFile "$root\Default\Cache\entry"
        $outside = New-CacheFile "$env:USERPROFILE\outside\Cache\kept"
        $link = Join-Path $root 'Profile 2'
        New-Item -ItemType Junction -Path $link -Target (Join-Path $env:USERPROFILE 'outside') | Out-Null
        try {
            Clear-BrowserCaches
            Test-Path -LiteralPath $outside | Should -BeTrue
            Test-Path -LiteralPath $cache | Should -BeFalse
        }
        finally { [IO.Directory]::Delete($link,$false) }
    }

    It 'Discards all discovered profiles when one profile is unreadable' {
        $root = "$env:LOCALAPPDATA\Google\Chrome\User Data"
        $cache = New-CacheFile "$root\Default\Cache\entry"
        $unreadable = New-CacheFile "$root\Profile 2\Cache\entry"
        $other = New-CacheFile "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache\entry"
        $script:RealCacheGetItem = Get-Command Get-Item -CommandType Cmdlet
        Mock Get-Item { & $script:RealCacheGetItem -LiteralPath $LiteralPath -Force -ErrorAction Stop }
        Mock Get-Item { throw 'access denied' } -ParameterFilter { $LiteralPath -like '*\Google\Chrome\User Data\Profile 2' }
        Clear-BrowserCaches
        Should -Invoke Get-Item -Times 1 -Exactly -ParameterFilter { $LiteralPath -like '*\Google\Chrome\User Data\Profile 2' }
        Test-Path -LiteralPath $cache | Should -BeTrue
        Test-Path -LiteralPath $unreadable | Should -BeTrue
        Test-Path -LiteralPath $other | Should -BeFalse
    }

    It 'Discards an oversized profile enumeration instead of cleaning a partial list' {
        $root = "$env:LOCALAPPDATA\Google\Chrome\User Data"
        $cache = New-CacheFile "$root\Default\Cache\entry"
        foreach ($n in 1..128) { New-Item -ItemType Directory -Path "$root\Profile $n" | Out-Null }
        Clear-BrowserCaches
        Test-Path -LiteralPath $cache | Should -BeTrue
        (Get-CleanupStats).FilesCleaned | Should -Be 0
    }

    It 'Preserves all files in dry-run and lists only disposable cache paths' {
        $cache = New-CacheFile "$env:APPDATA\Cursor\Cache\entry"
        $offline = New-CacheFile "$env:APPDATA\Cursor\Service Worker\CacheStorage\offline"
        Set-DryRunMode -Enabled $true
        Clear-AppCaches
        Test-Path -LiteralPath $cache | Should -BeTrue
        Test-Path -LiteralPath $offline | Should -BeTrue
        Get-Content -LiteralPath $script:ExportListFile -Raw | Should -Match ([regex]::Escape($cache))
        Get-Content -LiteralPath $script:ExportListFile -Raw | Should -Not -Match 'CacheStorage'
        (Get-CleanupStats).FilesCleaned | Should -Be 1
    }
}

Describe 'Native cache-owner process evidence' {
    It 'Detects the current process and accepts a nonexistent owner without mocks' {
        $current = Get-Process -Id $PID
        Test-SweeprCacheOwnerIdle -Names @($current.ProcessName) | Should -BeFalse
        Test-SweeprCacheOwnerIdle -Names @('sweepr-fixture-' + [guid]::NewGuid().ToString('N')) | Should -BeTrue
    }
}
