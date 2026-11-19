# Real file mutations below are restricted to Pester's temporary TestDrive.
BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    . "$script:RepoRoot\lib\core\base.ps1"
    . "$script:RepoRoot\lib\core\log.ps1"
    . "$script:RepoRoot\lib\core\file_ops.ps1"
    . "$script:RepoRoot\lib\clean\dev.ps1"
    function Set-SectionActivity { }
}

Describe 'Cleanup physical boundaries' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Root | Out-Null
        $script:SavedWhitelist = $script:Config.WhitelistFile
        $script:Config.WhitelistFile = Join-Path $script:Root 'whitelist.txt'
        Set-DryRunMode -Enabled $false
    }
    AfterEach {
        $script:Config.WhitelistFile = $script:SavedWhitelist
        Set-DryRunMode -Enabled $true
    }
    It 'Keeps the contents of a junction used as a cache root' {
        $target = Join-Path $script:Root 'target'
        New-Item -ItemType Directory -Path $target | Out-Null
        $sentinel = Join-Path $target 'keep.txt'
        Set-Content -LiteralPath $sentinel -Value 'keep'
        $link = Join-Path $script:Root 'cache'
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        Clear-DirectoryContents -Path $link
        Test-Path -LiteralPath $sentinel | Should -BeTrue
    }
    It 'Keeps a file reached through a junction ancestor' {
        $target = Join-Path $script:Root 'target'
        New-Item -ItemType Directory -Path $target | Out-Null
        $sentinel = Join-Path $target 'keep.txt'
        Set-Content -LiteralPath $sentinel -Value 'keep'
        $link = Join-Path $script:Root 'cache'
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        Remove-SafeItem -Path (Join-Path $link 'keep.txt') | Should -BeFalse
        Test-Path -LiteralPath $sentinel | Should -BeTrue
    }
    It 'Retains every candidate when a bounded cache scan times out' {
        $bounded = Join-Path $script:Root 'bounded'
        New-Item -ItemType Directory -Path $bounded | Out-Null
        Set-Content -LiteralPath (Join-Path $bounded 'a.lastUpdated') -Value 'x'
        $scan = Get-SwBoundedFileScan -Root $bounded -Filter '*.lastUpdated' -TimeoutSeconds 0
        $scan.Complete | Should -BeFalse
        @($scan.Files).Count | Should -Be 0
    }
    It 'Keeps an old file reached through a junction cleanup root' {
        $target = Join-Path $script:Root 'target'
        New-Item -ItemType Directory -Path $target | Out-Null
        $sentinel = Join-Path $target 'keep.txt'
        Set-Content -LiteralPath $sentinel -Value 'keep'
        (Get-Item -LiteralPath $sentinel).LastWriteTime = (Get-Date).AddDays(-30)
        $link = Join-Path $script:Root 'cache'
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        Remove-OldFiles -Path $link
        Test-Path -LiteralPath $sentinel | Should -BeTrue
    }
    It 'Keeps a replacement directory installed during sizing' {
        $script:Cache = Join-Path $script:Root 'cache'
        New-Item -ItemType Directory -Path $script:Cache | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Cache 'same.txt') -Value 'original'
        Mock Get-SwValidatedTreeSize {
            Move-Item -LiteralPath $script:Cache -Destination (Join-Path $script:Root 'original')
            New-Item -ItemType Directory -Path $script:Cache | Out-Null
            Set-Content -LiteralPath (Join-Path $script:Cache 'same.txt') -Value 'replacement'
            return 8
        }
        Remove-SafeItem -Path $script:Cache -Recurse | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $script:Cache 'same.txt') | Should -Be 'replacement'
    }
    It 'Keeps a deletion target when an existing whitelist cannot be read' {
        $cache = Join-Path $script:Root 'retained.txt'
        Set-Content -LiteralPath $cache -Value 'keep'
        # The file names nothing, so only the read error can keep the target.
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value '# present but unreadable'
        Mock Read-SwListBytes { throw 'Access denied' } -ParameterFilter {
            $Path -eq $script:Config.WhitelistFile
        }
        Remove-SafeItem -Path $cache | Should -BeFalse
        Test-Path -LiteralPath $cache | Should -BeTrue
    }
    It 'Refuses unknown whitelist metadata rather than treating it as missing' {
        Mock Get-Item { throw [System.UnauthorizedAccessException]::new('denied') } -ParameterFilter {
            $LiteralPath -eq $script:Config.WhitelistFile
        }
        Test-SafePath -Path (Join-Path $script:Root 'cache.bin') | Should -BeFalse
    }
    It 'Reads a literal bracket-containing whitelist filename' {
        $script:Config.WhitelistFile = Join-Path $script:Root '[rules].txt'
        $cache = Join-Path $script:Root 'cache'
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value $cache
        Test-SafePath -Path (Join-Path $cache 'keep.txt') | Should -BeFalse
    }
    It 'Still removes an ordinary cache directory' {
        $cache = Join-Path $script:Root 'cache'
        New-Item -ItemType Directory -Path $cache | Out-Null
        Set-Content -LiteralPath (Join-Path $cache 'data.bin') -Value 'cache'
        Remove-SafeItem -Path $cache -Recurse | Should -BeTrue
        Test-Path -LiteralPath $cache | Should -BeFalse
    }
    It 'Reads the whitelist once for a whole tree, not once per child' {
        $tree = Join-Path $script:Root 'tree'
        New-Item -ItemType Directory -Path $tree | Out-Null
        1..12 | ForEach-Object { Set-Content -LiteralPath (Join-Path $tree "f$_.txt") -Value 'x' }
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value '# no exclusions'
        $script:WhitelistReads = 0
        Mock Read-SwListBytes { $script:WhitelistReads++; , [Text.Encoding]::UTF8.GetBytes('# no exclusions') } -ParameterFilter {
            $Path -eq $script:Config.WhitelistFile
        }
        (Get-SafeDirectoryTreeItems -Path $tree).Success | Should -BeTrue
        $script:WhitelistReads | Should -Be 1
    }
    It 'Still retains a whole tree when the whitelist cannot be read' {
        $tree = Join-Path $script:Root 'tree'
        New-Item -ItemType Directory -Path $tree | Out-Null
        Set-Content -LiteralPath (Join-Path $tree 'a.txt') -Value 'x'
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value '# present but unreadable'
        Mock Read-SwListBytes { throw 'Access denied' } -ParameterFilter {
            $Path -eq $script:Config.WhitelistFile
        }
        (Get-SafeDirectoryTreeItems -Path $tree).Success | Should -BeFalse
    }
    It 'Protects children of a literal directory whitelist without covering a prefix sibling' {
        $cache = Join-Path $script:Root 'cache'
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value $cache
        Test-Whitelisted -Path (Join-Path $cache 'nested\data.bin') | Should -BeTrue
        Test-Whitelisted -Path (Join-Path $script:Root 'cache-other\data.bin') | Should -BeFalse
    }
}


Describe 'Tree walk snapshots' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path "$script:Root\a\b\c", "$script:Root\d" -Force | Out-Null
        'x' | Set-Content "$script:Root\a\f.txt"
        'x' | Set-Content "$script:Root\a\b\c\deep.txt"
        New-Item -ItemType Junction -Path "$script:Root\link" -Target "$script:Root\d" | Out-Null
    }
    It 'Binds every item to the same chain a fresh snapshot of its path would' {
        $items = @(Get-TreeItemsNoFollow -Path $script:Root)
        $items.Count | Should -BeGreaterThan 5
        foreach ($item in $items) {
            $fresh = Get-SweeprPathSnapshot -Path $item.FullName -AllowLeafLink
            $bound = $item.SweeprPathSnapshot
            $bound.Path | Should -Be $fresh.Path
            $bound.AllowLeafLink | Should -Be $fresh.AllowLeafLink
            @($bound.Entries.Keys | Sort-Object) | Should -Be @($fresh.Entries.Keys | Sort-Object) -Because $item.FullName
            foreach ($key in $fresh.Entries.Keys) { $bound.Entries[$key] | Should -Be $fresh.Entries[$key] -Because $key }
        }
    }
    It 'Binds the root once and each child from its parent instead of reopening every ancestor' {
        $script:RealSnapshot = ${function:Get-SwPathSnapshot}
        $script:SnapshotCalls = 0
        Mock Get-SwPathSnapshot {
            $script:SnapshotCalls++
            & $script:RealSnapshot -Path $Path -AllowLeafLink:$AllowLeafLink
        }
        $items = @(Get-TreeItemsNoFollow -Path $script:Root)
        $items.Count | Should -BeGreaterThan 5
        # The root once, plus the recheck of each directory entered; no call per child.
        $entered = 1 + @($items | Where-Object { $_.PSIsContainer -and ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 }).Count
        $script:SnapshotCalls | Should -Be (1 + $entered)
    }
    It 'Lists a junction as a link and does not walk into it' {
        $items = @(Get-TreeItemsNoFollow -Path $script:Root)
        @($items | Where-Object { $_.FullName -like "$script:Root\link*" }).Count | Should -Be 1
    }
    It 'Fails the recheck when a directory is replaced after the walk' {
        $items = @(Get-TreeItemsNoFollow -Path $script:Root)
        $target = $items | Where-Object { $_.FullName -eq "$script:Root\a\b\c\deep.txt" }
        Test-SweeprPathSnapshot $target.SweeprPathSnapshot | Should -BeTrue
        Rename-Item "$script:Root\a\b" 'b-old'
        New-Item -ItemType Directory -Path "$script:Root\a\b\c" -Force | Out-Null
        'x' | Set-Content "$script:Root\a\b\c\deep.txt"
        Test-SweeprPathSnapshot $target.SweeprPathSnapshot | Should -BeFalse
    }
}

Describe 'Whitelisted junction roots' {
    BeforeEach {
        $script:SavedWhitelist = $script:Config.WhitelistFile
        $script:Config.WhitelistFile = Join-Path $TestDrive 'junction-whitelist.txt'
    }
    AfterEach { $script:Config.WhitelistFile = $script:SavedWhitelist }
    It 'Keeps a child of a whitelisted junction by original and final spelling' {
        $target = Join-Path $TestDrive ('cargo-target-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $target | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'registry') -Value 'x'
        $link = Join-Path $TestDrive ('cargo-link-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value $link
        Test-SafePath -Path (Join-Path $link 'registry') | Should -BeFalse
        $state = Get-WhitelistState
        Test-Whitelisted -Path (Join-Path $target 'registry') -State $state | Should -BeTrue
        Test-Whitelisted -Path (Join-Path $link 'registry') -State $state | Should -BeTrue
    }
}

Describe 'Whitelist canonical pattern associations' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Root | Out-Null
        $script:SavedWhitelist = $script:Config.WhitelistFile
        $script:SavedDefaultPatterns = $script:DefaultWhitelistPatterns
        $script:Config.WhitelistFile = Join-Path $script:Root 'whitelist.txt'
        $script:DefaultWhitelistPatterns = @()
        Set-DryRunMode -Enabled $false
    }
    AfterEach {
        $script:Config.WhitelistFile = $script:SavedWhitelist
        $script:DefaultWhitelistPatterns = $script:SavedDefaultPatterns
        Set-DryRunMode -Enabled $true
    }
    It 'Keeps empty and single-pattern states usable' {
        $candidate = Join-Path $script:Root 'keep.bin'
        Test-Whitelisted -Path $candidate | Should -BeFalse
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value (Join-Path $script:Root '*.bin')
        Test-Whitelisted -Path $candidate | Should -BeTrue
        Test-Whitelisted -Path (Join-Path $script:Root 'ordinary.tmp') | Should -BeFalse
    }
    It 'Keeps mixed junction wildcard and literal rules associated in every position' -TestCases @(
        @{ Position = 0 }, @{ Position = 1 }, @{ Position = 2 }
    ) {
        param($Position)
        $target = Join-Path $script:Root 'target'
        $literal = Join-Path $script:Root 'literal'
        New-Item -ItemType Directory -Path $target, $literal | Out-Null
        $link = Join-Path $script:Root 'link'
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        try {
            $patterns = New-Object System.Collections.Generic.List[string]
            $patterns.Add((Join-Path $script:Root '*.keep'))
            $patterns.Add($literal)
            $patterns.Insert($Position, $link)
            Set-Content -LiteralPath $script:Config.WhitelistFile -Value $patterns.ToArray()
            $state = Get-WhitelistState
            foreach ($path in @(
                (Join-Path $link 'child.bin'), (Join-Path $target 'child.bin'),
                (Join-Path $script:Root 'saved.keep'), (Join-Path $literal 'child.bin')
            )) {
                Test-Whitelisted -Path $path -State $state | Should -BeTrue -Because $path
            }
            Test-Whitelisted -Path (Join-Path $script:Root 'ordinary.tmp') -State $state | Should -BeFalse
            Test-Whitelisted -Path (Join-Path $script:Root 'literal-other\child.bin') -State $state | Should -BeFalse
        }
        finally {
            [System.IO.Directory]::Delete($link, $false)
        }
    }
    It 'Retains a final wildcard at the removal sink after an expanded junction' {
        $target = Join-Path $script:Root 'target'
        New-Item -ItemType Directory -Path $target | Out-Null
        $link = Join-Path $script:Root 'link'
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        try {
            $kept = Join-Path $script:Root 'last.keep'
            $ordinary = Join-Path $script:Root 'ordinary.tmp'
            Set-Content -LiteralPath $kept, $ordinary -Value 'fixture'
            Set-Content -LiteralPath $script:Config.WhitelistFile -Value @($link, (Join-Path $script:Root '*.keep'))
            Remove-SafeItem -Path $kept | Should -BeFalse
            Get-Content -LiteralPath $kept | Should -Be 'fixture'
            Remove-SafeItem -Path $ordinary | Should -BeTrue
            Test-Path -LiteralPath $ordinary | Should -BeFalse
        }
        finally {
            [System.IO.Directory]::Delete($link, $false)
        }
    }
}

Describe 'Linked protected segments' {
    BeforeEach {
        $script:SavedWhitelist = $script:Config.WhitelistFile
        $script:Config.WhitelistFile = Join-Path $TestDrive 'segment-whitelist.txt'
    }
    AfterEach { $script:Config.WhitelistFile = $script:SavedWhitelist }
    It 'Refuses a child of a protected segment that is a junction elsewhere' {
        $target = Join-Path $TestDrive ('cred-target-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $target | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'blob') -Value 'x'
        $parent = Join-Path $TestDrive ('profile-' + [guid]::NewGuid().ToString('N') + '\Microsoft')
        New-Item -ItemType Directory -Path $parent | Out-Null
        $link = Join-Path $parent 'Credentials'
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        try {
            Test-SafePath -Path (Join-Path $link 'blob') | Should -BeFalse
            Test-SafePath -Path (Join-Path $target 'blob') | Should -BeTrue
        }
        finally {
            [System.IO.Directory]::Delete($link, $false)
        }
    }
}

Describe 'Owner cache cleanup whitelist' {
    BeforeEach {
        $script:OwnerRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:OwnerRoot | Out-Null
        $script:SavedOwnerWhitelist = $script:Config.WhitelistFile
        $script:SavedOwnerLocal = $env:LOCALAPPDATA
        $script:SavedOwnerProfile = $env:USERPROFILE
        $script:SavedOwnerApp = $env:APPDATA
        $env:LOCALAPPDATA = $script:OwnerRoot
        $env:USERPROFILE = $script:OwnerRoot
        $env:APPDATA = $script:OwnerRoot
        $script:Config.WhitelistFile = Join-Path $script:OwnerRoot 'whitelist.txt'
        # One folder that carries the mark of every owner tool (npm _cacache, pip http, go README,
        # pnpm leaf v<n>, mise below LOCALAPPDATA) and holds files, so only the whitelist decides.
        $script:OwnerCache = Join-Path $script:OwnerRoot 'store\v3'
        New-Item -ItemType Directory -Path (Join-Path $script:OwnerCache '_cacache'), (Join-Path $script:OwnerCache 'http') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:OwnerCache '_cacache\index.bin') -Value 'x'
        Set-Content -LiteralPath (Join-Path $script:OwnerCache 'http\entry.bin') -Value 'x'
        Set-Content -LiteralPath (Join-Path $script:OwnerCache 'README') -Value 'x'
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value $script:OwnerCache
        Mock Get-SwOwnerCachePath { $script:OwnerCache }
        Mock Invoke-SwOwnerCommand { [pscustomobject]@{ Output = '' } }
        Set-DryRunMode -Enabled $false
    }
    AfterEach {
        $script:Config.WhitelistFile = $script:SavedOwnerWhitelist
        $env:LOCALAPPDATA = $script:SavedOwnerLocal
        $env:USERPROFILE = $script:SavedOwnerProfile
        $env:APPDATA = $script:SavedOwnerApp
        Set-DryRunMode -Enabled $true
    }
    It 'Does not invoke npm or pnpm mutations for a whitelisted resolved root' {
        Clear-SwNpmFamilyCaches
        Should -Invoke Get-SwOwnerCachePath -Times 1 -ParameterFilter { $Name -eq 'npm' }
        Should -Invoke Invoke-SwOwnerCommand -Times 0 -ParameterFilter { $Mutation }
    }
    It 'Does not invoke pip purge for a whitelisted resolved root' {
        Clear-SwPythonCaches
        Should -Invoke Get-SwOwnerCachePath -Times 1 -ParameterFilter { $Name -eq 'pip' }
        Should -Invoke Invoke-SwOwnerCommand -Times 0 -ParameterFilter { $Mutation }
    }
    It 'Does not invoke go clean for a whitelisted resolved root' {
        Clear-SwGoCaches
        Should -Invoke Get-SwOwnerCachePath -Times 1 -ParameterFilter { $Name -eq 'go' }
        Should -Invoke Invoke-SwOwnerCommand -Times 0 -ParameterFilter { $Mutation }
    }
    It 'Does not invoke mise clear for a whitelisted resolved root' {
        Clear-SwMiseCache
        Should -Invoke Get-SwOwnerCachePath -Times 1 -ParameterFilter { $Name -eq 'mise' }
        Should -Invoke Invoke-SwOwnerCommand -Times 0 -ParameterFilter { $Mutation }
    }
    It 'Runs an owner for a known unprotected ordinary cache' {
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value '# no exclusions'
        Invoke-SwOwnerCacheCleanup -Name 'npm' -Query @('config','get','cache') -Arguments @('cache','clean','--force') -Description 'npm cache'
        Should -Invoke Invoke-SwOwnerCommand -Times 1 -Exactly -ParameterFilter { $Mutation -and $TimeoutSeconds -eq 120 }
    }
    It 'Reads the whitelist once for the boundary recheck, not once per cache entry' {
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value '# no exclusions'
        foreach ($i in 1..8) { Set-Content -LiteralPath (Join-Path $script:OwnerCache "entry$i.bin") -Value 'x' }
        $script:FixtureWhitelistState = Get-SwWhitelistState
        Mock Get-SwWhitelistState { $script:FixtureWhitelistState }
        Invoke-SwOwnerCacheCleanup -Name 'npm' -Query @('config','get','cache') -Arguments @('cache','clean','--force') -Description 'npm cache'
        Should -Invoke Invoke-SwOwnerCommand -Times 1 -Exactly -ParameterFilter { $Mutation }
        # The root check, the tree walk, the boundary recheck and the walk that
        # measures what the owner removed: one per pass, never one per entry.
        Should -Invoke Get-SwWhitelistState -Times 4 -Exactly
    }
    It 'Keeps a cache containing a specifically whitelisted child' {
        $child = Join-Path $script:OwnerCache 'keep.txt'
        Set-Content -LiteralPath $child -Value 'keep'
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value $child
        Invoke-SwOwnerCacheCleanup -Name 'npm' -Query @('config','get','cache') -Arguments @('cache','clean','--force') -Description 'npm cache'
        Should -Invoke Invoke-SwOwnerCommand -Times 0 -ParameterFilter { $Mutation }
    }
    It 'Keeps a cache when its owner cannot resolve the root' {
        Mock Get-SwOwnerCachePath { $null }
        Clear-SwNpmFamilyCaches
        Should -Invoke Invoke-SwOwnerCommand -Times 0 -ParameterFilter { $Mutation }
    }
    It 'Preserves Gradle transaction locks' {
        $lock = Join-Path $env:USERPROFILE '.gradle\caches\build-cache-1\build-cache-1.lock'
        New-Item -ItemType Directory -Path (Split-Path -Parent $lock) -Force | Out-Null
        Set-Content -LiteralPath $lock -Value 'lock'
        Invoke-SwDevCleanup
        Test-Path -LiteralPath $lock | Should -BeTrue
    }
}
