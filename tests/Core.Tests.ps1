# Sweepr Windows - Core Module Tests
# Pester tests for lib/core functionality

BeforeAll {
    # Get the windows directory path (tests are in windows/tests/)
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $script:LibDir = Join-Path $script:WindowsDir "lib"
    $script:VersionFile = Join-Path $script:WindowsDir "VERSION"

    # Import core modules
    . "$script:LibDir\core\base.ps1"
    . "$script:LibDir\core\log.ps1"
    . "$script:LibDir\core\ui.ps1"
    . "$script:LibDir\core\file_ops.ps1"
    . "$script:LibDir\core\version.ps1"
    . "$script:LibDir\core\tui_binaries.ps1"
}

Describe "Base Module" {
    Context "Color Definitions" {
        It "Should define color codes" {
            $script:Colors | Should -Not -BeNullOrEmpty
            $script:Colors.Cyan | Should -Not -BeNullOrEmpty
            $script:Colors.Green | Should -Not -BeNullOrEmpty
            $script:Colors.Red | Should -Not -BeNullOrEmpty
            $script:Colors.NC | Should -Not -BeNullOrEmpty
        }

        It "Should define icon set" {
            $script:Icons | Should -Not -BeNullOrEmpty
            $script:Icons.Success | Should -Not -BeNullOrEmpty
            $script:Icons.Error | Should -Not -BeNullOrEmpty
            $script:Icons.Warning | Should -Not -BeNullOrEmpty
            $script:Icons.Solid | Should -Not -BeNullOrEmpty
            $script:Icons.Admin | Should -Not -BeNullOrEmpty
            $script:Icons.Trash | Should -Not -BeNullOrEmpty
        }

        It "Should expose the full icon table in Windows PowerShell" {
            $basePath = (Join-Path $script:LibDir "core\base.ps1").Replace("'", "''")
            $psCommand = "& { . '$basePath'; `$icons = Get-SweeprDefaultIcons; [pscustomobject]@{ Count = `$icons.Count; HasSolid = `$icons.ContainsKey('Solid'); HasAdmin = `$icons.ContainsKey('Admin'); HasSuccess = `$icons.ContainsKey('Success') } | ConvertTo-Json -Compress }"
            $result = & powershell -NoProfile -ExecutionPolicy Bypass -Command $psCommand
            $iconInfo = $result | ConvertFrom-Json

            $iconInfo.Count | Should -Be 15
            $iconInfo.HasSolid | Should -Be $true
            $iconInfo.HasAdmin | Should -Be $true
            $iconInfo.HasSuccess | Should -Be $true
        }
    }

    Context "Visual Defaults Initialization" {
        BeforeEach {
            $script:OriginalColors = $script:Colors.Clone()
            $script:OriginalIcons = $script:Icons.Clone()
        }

        AfterEach {
            $script:Colors = $script:OriginalColors.Clone()
            $script:Icons = $script:OriginalIcons.Clone()
        }

        It "Should initialize missing visual tables under strict mode" {
            Remove-Variable -Name Colors -Scope Script -ErrorAction SilentlyContinue
            Remove-Variable -Name Icons -Scope Script -ErrorAction SilentlyContinue

            { Initialize-SweeprVisualDefaults } | Should -Not -Throw
            $script:Colors.Cyan | Should -Not -BeNullOrEmpty
            $script:Colors.Green | Should -Not -BeNullOrEmpty
            $script:Icons.Solid | Should -Not -BeNullOrEmpty
            $script:Icons.Trash | Should -Not -BeNullOrEmpty
        }

        It "Should preserve existing values while filling missing defaults" {
            $script:Colors = @{ Cyan = "custom-cyan" }
            $script:Icons = @{ Solid = "*" }

            Initialize-SweeprVisualDefaults

            $script:Colors.Cyan | Should -Be "custom-cyan"
            $script:Colors.Green | Should -Not -BeNullOrEmpty
            $script:Icons.Solid | Should -Be "*"
            $script:Icons.Admin | Should -Not -BeNullOrEmpty
        }

        It "Should restore missing icon entries on demand" {
            $script:Icons = @{ Solid = "*" }

            (Get-SweeprIcon -Name "Error") | Should -Not -BeNullOrEmpty
            $script:Icons.Error | Should -Not -BeNullOrEmpty
            $script:Icons.Solid | Should -Be "*"
        }
    }

    Context "Test-IsAdmin" {
        It "Should return a boolean" {
            $result = Test-IsAdmin
            $result | Should -BeOfType [bool]
        }
    }

    Context "Get-WindowsVersion" {
        It "Should return version info" {
            $result = Get-WindowsVersion
            $result | Should -Not -BeNullOrEmpty
            $result.Name | Should -Not -BeNullOrEmpty
            $result.Version | Should -Not -BeNullOrEmpty
            $result.Build | Should -Not -BeNullOrEmpty
        }
    }

    Context "Get-FreeSpace" {
        It "Should return free space string" {
            $result = Get-FreeSpace
            $result | Should -Not -BeNullOrEmpty
            # Format is like "100.00GB" or "50.5MB" (no space between number and unit)
            $result | Should -Match "\d+(\.\d+)?(B|KB|MB|GB|TB)"
        }

        It "Should accept drive parameter" {
            $result = Get-FreeSpace -Drive "C:"
            $result | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "File Operations Module" {
    BeforeAll {
        # Create temp test directory
        $script:TestDir = Join-Path $env:TEMP "sweepr_test_$(Get-Random)"
        New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
    }

    AfterAll {
        # Cleanup test directory
        if (Test-Path $script:TestDir) {
            Remove-Item -Path $script:TestDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context "Format-ByteSize" {
        It "Should format bytes correctly" {
            # Actual format: no space, uses N0/N1/N2 formatting
            Format-ByteSize -Bytes 0 | Should -Be "0B"
            Format-ByteSize -Bytes 1024 | Should -Be "1KB"
            Format-ByteSize -Bytes 1048576 | Should -Be "1.0MB"
            Format-ByteSize -Bytes 1073741824 | Should -Be "1.00GB"
        }

        It "Should handle large numbers" {
            Format-ByteSize -Bytes 1099511627776 | Should -Be "1.00TB"
        }
    }

    Context "Get-PathSize" {
        BeforeEach {
            # Create test file
            $testFile = Join-Path $script:TestDir "testfile.txt"
            "Hello World" | Set-Content -Path $testFile
        }

        It "Should return size for file" {
            $testFile = Join-Path $script:TestDir "testfile.txt"
            $result = Get-PathSize -Path $testFile
            $result | Should -BeGreaterThan 0
        }

        It "Should return size for directory" {
            $result = Get-PathSize -Path $script:TestDir
            $result | Should -BeGreaterThan 0
        }

        It "Should return 0 for non-existent path" {
            $result = Get-PathSize -Path "C:\NonExistent\Path\12345"
            $result | Should -Be 0
        }
    }

    Context "Test-ProtectedPath" {
        It "Should protect Windows directory" {
            Test-ProtectedPath -Path "C:\Windows" | Should -Be $true
            Test-ProtectedPath -Path "C:\Windows\System32" | Should -Be $true
        }

        It "Should protect the user profile root exactly" {
            $userProfile = [System.IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
            $userProfileChild = Join-Path $userProfile "AppData\Local\Temp"

            Test-ProtectedPath -Path $userProfile | Should -Be $true
            Test-ProtectedPath -Path $userProfileChild | Should -Be $false
        }

        It "Should protect Windows Defender paths" {
            Test-ProtectedPath -Path "C:\Program Files\Windows Defender" | Should -Be $true
            Test-ProtectedPath -Path "C:\ProgramData\Microsoft\Windows Defender" | Should -Be $true
        }

        It "Should protect the 8.3 short-name spelling of a protected tree" {
            if (-not (Test-Path -LiteralPath "C:\PROGRA~1")) {
                Set-ItResult -Skipped -Because "8.3 short names are not created on this volume"
                return
            }
            Test-ProtectedPath -Path "C:\PROGRA~1" | Should -Be $true
        }

        It "Should protect a final path when the list stores a short-name spelling" {
            if (-not (Test-Path -LiteralPath "C:\PROGRA~1")) {
                Set-ItResult -Skipped -Because "8.3 short names are not created on this volume"
                return
            }
            $savedProtectedPaths = $script:ProtectedPaths
            try {
                $script:ProtectedPaths = @("C:\PROGRA~1")
                Test-ProtectedPath -Path ([System.IO.Path]::GetFullPath($env:ProgramFiles)) | Should -Be $true
            }
            finally {
                $script:ProtectedPaths = $savedProtectedPaths
            }
        }

        It "Should protect a trailing-dot alias of a protected tree" {
            $alias = $env:SystemRoot + ".\System32"
            if (-not (Test-Path -LiteralPath $alias)) {
                Set-ItResult -Skipped -Because "the trailing-dot alias does not resolve on this volume"
                return
            }
            Test-ProtectedPath -Path $alias | Should -Be $true
        }

        It "Should keep a planned path under an unprotected parent safe" {
            $planned = Join-Path $env:TEMP ("sweepr-planned-" + [guid]::NewGuid().ToString("N"))
            Test-ProtectedPath -Path $planned | Should -Be $false
        }

        It "Should resolve an existing short-name alias to its final path" {
            if (-not (Test-Path -LiteralPath "C:\PROGRA~1")) {
                Set-ItResult -Skipped -Because "8.3 short names are not created on this volume"
                return
            }
            Resolve-SafePath -Path "C:\PROGRA~1" |
                Should -Be ([System.IO.Path]::GetFullPath($env:ProgramFiles))
        }

        It "Should protect a path reached through a junction into a protected tree" {
            $link = Join-Path $TestDrive ("win-link-" + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Junction -Path $link -Target $env:SystemRoot | Out-Null
            try {
                Test-ProtectedPath -Path (Join-Path $link "System32") | Should -Be $true
            }
            finally {
                if (Test-Path -LiteralPath $link) {
                    [System.IO.Directory]::Delete($link, $false)
                }
            }
        }
        It "Should not protect temp directories" {
            Test-ProtectedPath -Path $env:TEMP | Should -Be $false
        }
    }

    Context "Test-SafePath" {
        It "Should return false for protected paths" {
            Test-SafePath -Path "C:\Windows" | Should -Be $false
            Test-SafePath -Path "C:\Windows\System32" | Should -Be $false
        }

        It "Should return false for the user profile root" {
            Test-SafePath -Path $env:USERPROFILE | Should -Be $false
        }

        It "Should return true for safe paths" {
            Test-SafePath -Path $env:TEMP | Should -Be $true
        }

        It "Should return false for empty paths" {
            # Test-SafePath has mandatory path parameter, so empty/null throws
            # But internally it should handle empty strings gracefully
            { Test-SafePath -Path "" } | Should -Throw
        }
    }

    Context "Operation log" {
        BeforeEach {
            $script:OriginalOperationsLog = $script:SweeprOperationsLogFile
            $script:OriginalOperationsMax = $script:SweeprOperationsLogMaxBytes
            $script:OriginalNoOplog = $env:SWEEPR_NO_OPLOG
            $script:OriginalRunCommand = $env:_SWEEPR_OPLOG_RUN_COMMAND
            $script:OriginalRunId = $env:_SWEEPR_OPLOG_RUN_ID
            $env:SWEEPR_NO_OPLOG = $null
            $env:_SWEEPR_OPLOG_RUN_COMMAND = "clean"
            $env:_SWEEPR_OPLOG_RUN_ID = "run-canary"
            $script:SweeprOperationsLogFile = Join-Path (Join-Path $TestDrive ("oplog-" + [guid]::NewGuid().ToString("N"))) "operations.log"
            $script:SweeprOperationsLogStarted = $false
            $script:OplogFile = Join-Path $script:TestDir "oplog_target.txt"
            "Test content" | Set-Content -Path $script:OplogFile
        }

        AfterEach {
            $script:SweeprOperationsLogFile = $script:OriginalOperationsLog
            $script:SweeprOperationsLogMaxBytes = $script:OriginalOperationsMax
            $script:SweeprOperationsLogStarted = $false
            $env:SWEEPR_NO_OPLOG = $script:OriginalNoOplog
            $env:_SWEEPR_OPLOG_RUN_COMMAND = $script:OriginalRunCommand
            $env:_SWEEPR_OPLOG_RUN_ID = $script:OriginalRunId
            Set-DryRunMode -Enabled $false
        }

        It "Records each removed item under one session marker" {
            $second = Join-Path $script:TestDir "oplog_second.txt"
            "Test content" | Set-Content -Path $second
            Remove-SafeItem -Path $script:OplogFile | Should -Be $true
            Remove-SafeItems -Paths @($second) -Description "Second"

            $lines = @(Get-Content -LiteralPath $script:SweeprOperationsLogFile | Where-Object { $_ })
            @($lines | Where-Object { $_.StartsWith("# ========== clean run=run-canary session started at ") }).Count | Should -Be 1
            @($lines | Where-Object { $_.Contains("[clean run=run-canary] REMOVED $($script:OplogFile) (") }).Count | Should -Be 1
            @($lines | Where-Object { $_.Contains("[clean run=run-canary] REMOVED $second (") }).Count | Should -Be 1
        }

        It "Writes nothing for a dry run or with SWEEPR_NO_OPLOG=1" {
            Set-DryRunMode -Enabled $true
            Remove-SafeItem -Path $script:OplogFile | Should -Be $true
            Set-DryRunMode -Enabled $false
            $env:SWEEPR_NO_OPLOG = "1"
            Remove-SafeItem -Path $script:OplogFile | Should -Be $true
            Test-Path -LiteralPath $script:SweeprOperationsLogFile | Should -BeFalse
        }

        It "Records a removal that failed" {
            Mock Remove-Item { throw "access-denied-canary" }
            Remove-SafeItem -Path $script:OplogFile | Should -Be $false
            Get-Content -LiteralPath $script:SweeprOperationsLogFile -Raw | Should -Match ("FAILED " + [regex]::Escape($script:OplogFile) + " \(access-denied-canary\)")
        }

        It "Keeps one record per line whatever the name holds" {
            $name = "C:\dir\x" + [char]9 + "name" + [char]10 + "forged" + [char]27
            ConvertTo-SweeprLogValue $name | Should -BeExactly 'C:\dir\x\tname\nforged\x1b'
        }

        It "Retries a line while another run holds the log" {
            $dir = Split-Path -Parent $script:SweeprOperationsLogFile
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $script:HeldLog = [System.IO.File]::Open($script:SweeprOperationsLogFile, 'OpenOrCreate', 'ReadWrite', 'None')
            try {
                Mock Start-Sleep { $script:HeldLog.Dispose() }
                Write-SweeprOperation -Action "REMOVED" -Path "C:\held\file.txt" -Detail "1 KB"
                Should -Invoke Start-Sleep -Times 1 -Exactly
            }
            finally { $script:HeldLog.Dispose() }
            Get-Content -LiteralPath $script:SweeprOperationsLogFile -Raw | Should -Match "REMOVED C:\\held\\file\.txt \(1 KB\)"
        }

        It "Says on the debug stream when a line could not be written" {
            $dir = Split-Path -Parent $script:SweeprOperationsLogFile
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $held = [System.IO.File]::Open($script:SweeprOperationsLogFile, 'OpenOrCreate', 'ReadWrite', 'None')
            try {
                Mock Start-Sleep { }
                Mock Write-SwDebug { }
                Write-SweeprOperation -Action "REMOVED" -Path "C:\held\file.txt"
                Should -Invoke Start-Sleep -Times 4 -Exactly
            }
            finally { $held.Dispose() }
            Should -Invoke Write-SwDebug -Times 1 -Exactly -ParameterFilter { $Message -like "operations.log not written: *" }
        }

        It "Records why a folder was refused before anything was removed" {
            $dir = Join-Path $script:TestDir ("refused-" + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Mock Get-SwSafeDirectoryTreeItems { @{ Success = $false; Items = @(); Reason = "protected or whitelisted entry inside: C:\x\keep" } }

            Remove-SafeItem -Path $dir -Recurse | Should -Be $false
            Remove-SafeItems -Paths @($dir) -Description "Refused"

            $lines = @(Get-Content -LiteralPath $script:SweeprOperationsLogFile | Where-Object { $_.Contains("SKIPPED $dir (refused: protected or whitelisted entry inside: C:\x\keep)") })
            $lines.Count | Should -Be 2
        }

        It "Never deletes a folder recursively when it gained entries after the walk" {
            $dir = Join-Path $script:TestDir ("grown-" + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir "late.txt") -Value "x"
            # Remove-Item without -Recurse prompts to delete these children; the
            # canary stands in for a user answering Yes.
            Mock Remove-Item {} -ParameterFilter { Test-Path -LiteralPath $LiteralPath -PathType Container }

            { Remove-TreeEntry -Path $dir } | Should -Throw
            Should -Invoke Remove-Item -Times 0 -Exactly -ParameterFilter { Test-Path -LiteralPath $LiteralPath -PathType Container }
            Test-Path -LiteralPath (Join-Path $dir "late.txt") | Should -BeTrue
        }

        It "Removes an empty read-only folder" {
            $dir = Join-Path $script:TestDir ("readonly-" + [guid]::NewGuid().ToString("N"))
            $folder = New-Item -ItemType Directory -Path $dir -Force
            $folder.Attributes = $folder.Attributes -bor [System.IO.FileAttributes]::ReadOnly

            Remove-TreeEntry -Path $dir
            Test-Path -LiteralPath $dir | Should -BeFalse
        }

        It "Records how far a partial folder removal got" {
            $dir = Join-Path $script:TestDir ("partial-" + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            foreach ($name in @("a.txt", "b.txt", "locked.txt")) { Set-Content -LiteralPath (Join-Path $dir $name) -Value "x" }
            # Match by leaf: %TEMP% can be an 8.3 short path while the tree walk returns long names.
            Mock Remove-SwTreeEntry { if ((Split-Path -Leaf $Path) -eq "locked.txt") { throw "in-use-canary" } else { Remove-Item -LiteralPath $Path -Force } }

            Remove-SafeItem -Path $dir -Recurse | Should -Be $false

            $text = Get-Content -LiteralPath $script:SweeprOperationsLogFile -Raw
            $text | Should -Match ("FAILED " + [regex]::Escape($dir) + " \(incomplete: removed \d of 3 entries; stopped at [^()]*\\locked\.txt: in-use-canary\)")
        }

        It "Moves a log over its size limit aside before the next session" {
            $dir = Split-Path -Parent $script:SweeprOperationsLogFile
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath $script:SweeprOperationsLogFile -Value ("x" * 64)
            $script:SweeprOperationsLogMaxBytes = 16
            Remove-SafeItem -Path $script:OplogFile | Should -Be $true
            Get-Content -LiteralPath "$($script:SweeprOperationsLogFile).old" -Raw | Should -Match "x{64}"
            Get-Content -LiteralPath $script:SweeprOperationsLogFile -Raw | Should -Not -Match "x{64}"
        }
    }

    Context "Remove-SafeItem" {
        BeforeEach {
            $script:TestFile = Join-Path $script:TestDir "safe_remove_test.txt"
            "Test content" | Set-Content -Path $script:TestFile
        }

        It "Should remove file successfully" {
            $result = Remove-SafeItem -Path $script:TestFile
            $result | Should -Be $true
            Test-Path $script:TestFile | Should -Be $false
        }

        It "Should respect DryRun mode" {
            $env:SWEEPR_DRY_RUN = "1"
            try {
                # Reset the module's DryRun state
                Set-DryRunMode -Enabled $true
                $result = Remove-SafeItem -Path $script:TestFile
                $result | Should -Be $true
                Test-Path $script:TestFile | Should -Be $true  # File should still exist
            }
            finally {
                $env:SWEEPR_DRY_RUN = $null
                Set-DryRunMode -Enabled $false
            }
        }

        It "Should not remove protected paths" {
            $result = Remove-SafeItem -Path "C:\Windows\System32"
            $result | Should -Be $false
        }

        It "Should remove empty directories successfully" {
            $emptyDir = Join-Path $script:TestDir "empty_remove_test"
            New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null

            $result = Remove-SafeItem -Path $emptyDir -Description "Empty directory" -Recurse

            $result | Should -Be $true
            Test-Path $emptyDir | Should -Be $false
        }

        It "Sizes a directory from its validated walk instead of walking it again (dry run: <DryRun>)" -TestCases @(@{ DryRun = $false }, @{ DryRun = $true }) {
            param($DryRun)
            $treeRoot = Join-Path $script:TestDir ("sized_tree_" + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path (Join-Path $treeRoot "nested") -Force | Out-Null
            [System.IO.File]::WriteAllBytes((Join-Path $treeRoot "a.bin"), (New-Object byte[] 3000))
            [System.IO.File]::WriteAllBytes((Join-Path $treeRoot "nested\b.bin"), (New-Object byte[] 5000))
            Mock Get-SwPathSize { throw "second walk of an already validated tree" }
            Reset-CleanupStats
            try {
                Set-DryRunMode -Enabled $DryRun
                Remove-SafeItem -Path $treeRoot -Description "Sized tree" -Recurse | Should -Be $true
                (Get-CleanupStats).TotalSizeKB | Should -Be ([Math]::Ceiling(8000 / 1024))
                Test-Path -LiteralPath $treeRoot | Should -Be $DryRun
            }
            finally {
                Set-DryRunMode -Enabled $false
                Reset-CleanupStats
                if (Test-Path $treeRoot) {
                    Remove-Item -Path $treeRoot -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }

        It "Sizes each directory of a batch from its validated walk (dry run: <DryRun>)" -TestCases @(@{ DryRun = $false }, @{ DryRun = $true }) {
            param($DryRun)
            $first = Join-Path $script:TestDir ("batch_tree_" + [guid]::NewGuid().ToString("N"))
            $second = Join-Path $script:TestDir ("batch_tree_" + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $first, $second -Force | Out-Null
            [System.IO.File]::WriteAllBytes((Join-Path $first "a.bin"), (New-Object byte[] 4096))
            [System.IO.File]::WriteAllBytes((Join-Path $second "b.bin"), (New-Object byte[] 6144))
            Mock Get-SwPathSize { throw "second walk of an already validated tree" }
            Reset-CleanupStats
            try {
                Set-DryRunMode -Enabled $DryRun
                Remove-SafeItems -Paths @($first, $second) -Description "Batch trees"
                (Get-CleanupStats).TotalSizeKB | Should -Be 10
                (Get-CleanupStats).FilesCleaned | Should -Be 2
                Test-Path -LiteralPath $first | Should -Be $DryRun
            }
            finally {
                Set-DryRunMode -Enabled $false
                Reset-CleanupStats
                foreach ($path in @($first, $second)) {
                    if (Test-Path $path) { Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue }
                }
            }
        }

        It "Reads the whitelist once for a whole tree removal through <_>" -ForEach @("Remove-SafeDirectoryTree", "Remove-SafeItem", "Remove-SafeItems") {
            # Every rule resolves through the filesystem; once per child made a
            # large cache folder pay that lookup for each of its entries.
            $treeRoot = Join-Path $script:TestDir ("whitelist_once_" + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path (Join-Path $treeRoot "nested") -Force | Out-Null
            foreach ($i in 1..6) { Set-Content -LiteralPath (Join-Path $treeRoot "nested\file$i.txt") -Value "x" }
            $script:FixtureWhitelistState = Get-WhitelistState
            Mock Get-SwWhitelistState { $script:FixtureWhitelistState }
            try {
                switch ($_) {
                    "Remove-SafeDirectoryTree" { Remove-SafeDirectoryTree -Path $treeRoot | Should -BeTrue }
                    "Remove-SafeItem" { Remove-SafeItem -Path $treeRoot -Description "Tree" | Should -BeTrue }
                    "Remove-SafeItems" { Remove-SafeItems -Paths @($treeRoot) -Description "Tree" }
                }
                Test-Path -LiteralPath $treeRoot | Should -BeFalse
                Should -Invoke Get-SwWhitelistState -Times 1 -Exactly
            }
            finally {
                if (Test-Path $treeRoot) { Remove-Item -Path $treeRoot -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }

        It "Still refuses a whitelisted child with the single whitelist read" {
            $treeRoot = Join-Path $script:TestDir ("whitelist_child_" + [guid]::NewGuid().ToString("N"))
            $kept = Join-Path $treeRoot "keep\kept.txt"
            New-Item -ItemType Directory -Path (Split-Path -Parent $kept) -Force | Out-Null
            Set-Content -LiteralPath $kept -Value "keep"
            Set-Content -LiteralPath (Join-Path $treeRoot "other.txt") -Value "x"
            $savedWhitelist = $script:Config.WhitelistFile
            try {
                $script:Config.WhitelistFile = Join-Path $script:TestDir ("whitelist_" + [guid]::NewGuid().ToString("N") + ".txt")
                Set-Content -LiteralPath $script:Config.WhitelistFile -Value (Split-Path -Parent $kept)
                $script:FixtureWhitelistState = Get-WhitelistState
                Mock Get-SwWhitelistState { $script:FixtureWhitelistState }

                Remove-SafeDirectoryTree -Path $treeRoot | Should -BeFalse
                Test-Path -LiteralPath $kept | Should -BeTrue
                Should -Invoke Get-SwWhitelistState -Times 1 -Exactly
            }
            finally {
                $script:Config.WhitelistFile = $savedWhitelist
                if (Test-Path $treeRoot) { Remove-Item -Path $treeRoot -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }

        It "Should not partially remove a directory tree when a protected child is present" {
            $treeRoot = Join-Path $script:TestDir "protected_child_tree"
            $safeFile = Join-Path $treeRoot "safe.txt"
            $protectedDir = Join-Path $treeRoot "protected"
            $protectedFile = Join-Path $protectedDir "secret.txt"
            $originalProtectedPaths = $script:ProtectedPaths

            New-Item -ItemType Directory -Path $protectedDir -Force | Out-Null
            "safe" | Set-Content -Path $safeFile
            "secret" | Set-Content -Path $protectedFile

            try {
                $script:ProtectedPaths = @($script:ProtectedPaths + $protectedDir)

                $result = Remove-SafeItem -Path $treeRoot -Description "Protected child tree" -Recurse

                $result | Should -Be $false
                Test-Path $safeFile | Should -Be $true
                Test-Path $protectedFile | Should -Be $true
            }
            finally {
                $script:ProtectedPaths = $originalProtectedPaths
                if (Test-Path $treeRoot) {
                    Remove-Item -Path $treeRoot -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }

        It "Should reject dry-run previews when a directory tree contains a protected child" {
            $treeRoot = Join-Path $script:TestDir "protected_child_dry_run_tree"
            $safeFile = Join-Path $treeRoot "safe.txt"
            $protectedDir = Join-Path $treeRoot "protected"
            $protectedFile = Join-Path $protectedDir "secret.txt"
            $originalProtectedPaths = $script:ProtectedPaths

            New-Item -ItemType Directory -Path $protectedDir -Force | Out-Null
            "safe" | Set-Content -Path $safeFile
            "secret" | Set-Content -Path $protectedFile

            try {
                $script:ProtectedPaths = @($script:ProtectedPaths + $protectedDir)
                Set-DryRunMode -Enabled $true

                $result = Remove-SafeItem -Path $treeRoot -Description "Protected child dry-run tree" -Recurse

                $result | Should -Be $false
                Test-Path $safeFile | Should -Be $true
                Test-Path $protectedFile | Should -Be $true
            }
            finally {
                Set-DryRunMode -Enabled $false
                $script:ProtectedPaths = $originalProtectedPaths
                if (Test-Path $treeRoot) {
                    Remove-Item -Path $treeRoot -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
}

Describe "Logging Module" {
    Context "Write-Log Functions" {
        It "Should have Write-Info function" {
            { Write-Info "Test message" } | Should -Not -Throw
        }

        It "Should have Write-Success function" {
            { Write-Success "Test message" } | Should -Not -Throw
        }

        It "Should have Write-SweeprWarning function" {
            # Note: The actual function is Write-SweeprWarning
            { Write-SweeprWarning "Test message" } | Should -Not -Throw
        }

        It "Should have Write-SweeprError function" {
            # Note: The actual function is Write-SweeprError
            { Write-SweeprError "Test message" } | Should -Not -Throw
        }

        It "Should log errors even when the icon table is partial" {
            $originalIcons = $script:Icons.Clone()

            try {
                $script:Icons = @{ Solid = "*" }
                { Write-SweeprError "Test message" } | Should -Not -Throw
                $script:Icons.Error | Should -Not -BeNullOrEmpty
            }
            finally {
                $script:Icons = $originalIcons
            }
        }
    }

    Context "Debug session log" {
        BeforeEach {
            $script:OriginalDebugLogFile = $script:SweeprDebugLogFile
            $script:OriginalLogConfig = $script:LogConfig.Clone()
            $script:OriginalSweeprDebug = $env:SWEEPR_DEBUG
            $script:SweeprDebugLogFile = Join-Path $TestDrive "config\sweepr\sweepr_debug_session.log"
        }

        AfterEach {
            $script:SweeprDebugLogFile = $script:OriginalDebugLogFile
            $script:LogConfig = $script:OriginalLogConfig
            $env:SWEEPR_DEBUG = $script:OriginalSweeprDebug
        }

        It "Starts a fresh log with its header and records debug and message lines" {
            New-Item -ItemType Directory -Path (Split-Path -Parent $script:SweeprDebugLogFile) -Force | Out-Null
            Set-Content -LiteralPath $script:SweeprDebugLogFile -Value "previous session"

            Start-SweeprDebugSession -Header @("Sweepr Debug Session", "Command: sw clean --debug")
            Write-Debug "probe-debug-line"
            Write-SweeprWarning "probe-warning-line"
            Complete-SweeprDebugSession

            $log = Get-Content -LiteralPath $script:SweeprDebugLogFile -Raw
            $log | Should -Not -Match "previous session"
            $log | Should -Match "Command: sw clean --debug"
            $log | Should -Match "\[DEBUG\] probe-debug-line"
            $log | Should -Match "\[WARN\] probe-warning-line"
            $env:SWEEPR_DEBUG | Should -Be "1"
        }

        It "Keeps working when the log cannot be written" {
            $blocker = Join-Path $TestDrive "blocked"
            Set-Content -LiteralPath $blocker -Value "a file, not a folder"
            $script:SweeprDebugLogFile = Join-Path $blocker "sweepr_debug_session.log"

            { Start-SweeprDebugSession -Header @("header") } | Should -Not -Throw
            { Write-Debug "still printed" } | Should -Not -Throw
            $script:LogConfig.LogFile | Should -BeNullOrEmpty
        }

        It "Loads when USERPROFILE is empty" {
            # Every command loads this module; a throwing path there stops them all.
            $logPath = (Join-Path $script:LibDir "core\log.ps1").Replace("'", "''")
            $psCommand = "& { `$env:USERPROFILE = `$null; . '$logPath'; 'loaded' }"
            $result = & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -Command $psCommand 2>&1 | Out-String
            $result | Should -Match "loaded"
        }

        It "Writes a command script's own lines when the router already set SWEEPR_DEBUG" {
            # Command scripts load the log module afresh in their own scope after
            # the router set SWEEPR_DEBUG; reading it only in Main was too late.
            $profileDir = Join-Path $TestDrive "profile"
            New-Item -ItemType Directory -Path (Join-Path $profileDir ".config\sweepr") -Force | Out-Null
            $logPath = (Join-Path $script:LibDir "core\log.ps1").Replace("'", "''")
            $psCommand = "& { . '$logPath'; Write-Debug 'child-debug-line'; Write-SweeprWarning 'child-warning-line' }"
            $originalProfile = $env:USERPROFILE
            try {
                $env:USERPROFILE = $profileDir
                $env:SWEEPR_DEBUG = "1"
                & powershell -NoProfile -ExecutionPolicy Bypass -Command $psCommand | Out-Null
            }
            finally {
                $env:USERPROFILE = $originalProfile
            }

            $log = Get-Content -LiteralPath (Join-Path $profileDir ".config\sweepr\sweepr_debug_session.log") -Raw
            $log | Should -Match "\[DEBUG\] child-debug-line"
            $log | Should -Match "\[WARN\] child-warning-line"
        }
    }

    Context "Section Functions" {
        It "Should start and stop sections without error" {
            { Start-Section -Title "Test Section" } | Should -Not -Throw
            { Stop-Section } | Should -Not -Throw
        }
    }
}

Describe "Version Helpers" {
    Context "Shared VERSION Source" {
        It "Should keep TUI release lookup aligned with VERSION" {
            $expected = (Get-Content $script:VersionFile -Raw).Trim()
            Get-SweeprVersionFromScriptFile -WindowsDir $script:WindowsDir | Should -Be $expected
        }
    }
}
