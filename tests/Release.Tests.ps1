# Sweepr Windows - release tooling tests
# Covers the checksum writer, the release zip and the package-manager update hint.

BeforeAll {
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $script:ScriptsDir = Join-Path $script:WindowsDir "scripts"
}

Describe "write-checksums.ps1" {
    It "Writes one LF-terminated checksum line per file without a BOM" {
        $dir = Join-Path $TestDrive "sums"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -Path (Join-Path $dir "a.zip") -Value "zip"
        Set-Content -Path (Join-Path $dir "b.exe") -Value "exe"

        & (Join-Path $script:ScriptsDir "write-checksums.ps1") -Directory $dir -Files @("a.zip", "b.exe") 6>$null

        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $dir "SHA256SUMS.txt"))
        $bytes[0] | Should -Not -Be 0xEF
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        $text | Should -Not -Match "`r"
        $lines = @($text.TrimEnd("`n") -split "`n")
        $lines.Count | Should -Be 2
        $expected = (Get-FileHash (Join-Path $dir "a.zip") -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines[0] | Should -Be "$expected  a.zip"
    }

    It "Fails when a listed file is missing" {
        $dir = Join-Path $TestDrive "missing"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        { & (Join-Path $script:ScriptsDir "write-checksums.ps1") -Directory $dir -Files @("absent.zip") } | Should -Throw "*absent.zip*"
    }
}

Describe "sw update for package-manager installs" {
    BeforeAll {
        $updateScript = Join-Path $script:WindowsDir "bin\update.ps1"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($updateScript, [ref]$null, [ref]$null)
        $function = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Get-PackageManagerUpgradeCommand"
            }, $true)
        . ([scriptblock]::Create($function.Extent.Text))
    }

    It "Names the upgrade command for <Manager>" -ForEach @(
        @{ Manager = "winget"; Dir = "C:\Users\me\AppData\Local\Microsoft\WinGet\Packages\brummilab.Sweepr_Microsoft.Winget.Source_8wekyb3d8bbwe"; Expected = "winget upgrade brummilab.Sweepr" },
        @{ Manager = "Scoop"; Dir = "C:\Users\me\scoop\apps\sweepr\1.31.0"; Expected = "scoop update sweepr" }
    ) {
        Get-PackageManagerUpgradeCommand -InstallDir $Dir | Should -Be $Expected
    }

    It "Returns nothing for a plain folder" {
        Get-PackageManagerUpgradeCommand -InstallDir "C:\Users\me\AppData\Local\Sweepr" | Should -BeNullOrEmpty
    }
}

Describe "new-release-zip.ps1" {
    It "Includes every README language linked by the packaged English README" {
        $build = Get-Content (Join-Path $script:ScriptsDir "build-release.ps1") -Raw
        $start = $build.IndexOf('# Copy all necessary files')
        $end = $build.IndexOf('$zipSize =', $start)
        $start | Should -BeGreaterThan -1
        $end | Should -BeGreaterThan $start

        # Execute the real staging and archive steps, without builds or signing.
        $projectRoot = $script:WindowsDir
        $scriptDir = $script:ScriptsDir
        $releaseDir = Join-Path $TestDrive "readme-release"
        $tempBuildDir = Join-Path $releaseDir "stage"
        $archiveName = "readme-fixture"
        New-Item -ItemType Directory -Path $tempBuildDir -Force | Out-Null
        . ([scriptblock]::Create($build.Substring($start, $end - $start))) 6>$null

        $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            $english = [System.IO.File]::ReadAllText((Join-Path $projectRoot "README.md"))
            $languages = @([regex]::Matches($english, 'href="(README(?:_[A-Z]+|\.[a-z]{2})\.md)"') | ForEach-Object { $_.Groups[1].Value })
            foreach ($name in @("README.md") + $languages) {
                $entry = $archive.GetEntry($name)
                $entry | Should -Not -BeNullOrEmpty -Because "$name must ship with its language link"
                $reader = New-Object System.IO.StreamReader($entry.Open())
                try { $reader.ReadToEnd() | Should -BeExactly ([System.IO.File]::ReadAllText((Join-Path $projectRoot $name))) }
                finally { $reader.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }

    It "Stores entry names with forward slashes, as winget's archive check requires" {
        $source = Join-Path $TestDrive "zip-source"
        New-Item -ItemType Directory -Path (Join-Path $source "bin\nested") -Force | Out-Null
        Set-Content -Path (Join-Path $source "sweepr.ps1") -Value "#"
        Set-Content -Path (Join-Path $source "bin\nested\tool.ps1") -Value "#"
        $zip = Join-Path $TestDrive "release.zip"

        & (Join-Path $script:ScriptsDir "new-release-zip.ps1") -SourceDir $source -Destination $zip

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
        try {
            $names = @($archive.Entries | ForEach-Object { $_.FullName })
        }
        finally {
            $archive.Dispose()
        }
        $names | Should -Contain "bin/nested/tool.ps1"
        $names | Should -Contain "sweepr.ps1"
        @($names | Where-Object { $_.Contains('\') }).Count | Should -Be 0
    }

    It "Is the only way the release scripts build a zip" {
        $text = Get-Content (Join-Path $script:ScriptsDir "build-release.ps1") -Raw
        $text | Should -Not -Match 'Compress-Archive|CreateFromDirectory'
        $text | Should -Match 'new-release-zip\.ps1'
    }
}

Describe "portable release asset" {
    BeforeAll {
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem

        $build = Get-Content (Join-Path $script:ScriptsDir "build-release.ps1") -Raw
        $start = $build.IndexOf('# Copy all necessary files')
        $end = $build.IndexOf('# Summary', $start)
        $start | Should -BeGreaterThan -1
        $end | Should -BeGreaterThan $start

        # Execute the real staging, archive and checksum steps (5 and 6) with fake binaries.
        $projectRoot = $script:WindowsDir
        $scriptDir = $script:ScriptsDir
        $releaseDir = Join-Path $TestDrive "portable-release"
        $tempBuildDir = Join-Path $releaseDir "temp-build"
        $launcherDir = Join-Path $releaseDir "launcher"
        $binDir = Join-Path $TestDrive "portable-bin"
        New-Item -ItemType Directory -Path $tempBuildDir, $launcherDir, $binDir -Force | Out-Null
        Set-Content -Path (Join-Path $launcherDir "sw.exe") -Value "fake"
        Set-Content -Path (Join-Path $binDir "analyze.exe") -Value "fake"
        Set-Content -Path (Join-Path $binDir "status.exe") -Value "fake"
        $archiveName = "sweepr-9.9.9-x64"
        . ([scriptblock]::Create($build.Substring($start, $end - $start))) 6>$null

        $script:ReleaseDir = $releaseDir
        $script:NormalZip = Join-Path $releaseDir "sweepr-9.9.9-x64.zip"
        $script:PortableZip = Join-Path $releaseDir "sweepr-9.9.9-x64-portable.zip"

        # One BeforeAll per block: Pester 5 runs only the last one (the Linux runner ships Pester 5).
        function script:Get-ZipNames([string]$Path) {
            $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
            try { return @($archive.Entries | ForEach-Object { $_.FullName }) }
            finally { $archive.Dispose() }
        }
    }

    It "Creates the portable zip next to the normal zip" {
        Test-Path $script:NormalZip | Should -BeTrue
        Test-Path $script:PortableZip | Should -BeTrue
    }

    It "Puts sweepr.portable at the root of the portable zip" {
        Get-ZipNames $script:PortableZip | Should -Contain "sweepr.portable"
    }

    It "Keeps sweepr.portable out of the normal zip" {
        Get-ZipNames $script:NormalZip | Should -Not -Contain "sweepr.portable"
    }

    It "Ships every entry of the normal zip in the portable zip, and nothing else but the marker" {
        $normal = @(Get-ZipNames $script:NormalZip | Sort-Object)
        $portable = @(Get-ZipNames $script:PortableZip | Where-Object { $_ -ne "sweepr.portable" } | Sort-Object)
        $normal.Count | Should -BeGreaterThan 0
        $portable | Should -Be $normal
    }

    It "Stores the same content for every shared entry" {
        $a = [System.IO.Compression.ZipFile]::OpenRead($script:NormalZip)
        $b = [System.IO.Compression.ZipFile]::OpenRead($script:PortableZip)
        try {
            foreach ($entry in @($a.Entries | Where-Object { $_.Length -gt 0 })) {
                $other = $b.GetEntry($entry.FullName)
                $other | Should -Not -BeNullOrEmpty -Because "$($entry.FullName) must be in both zips"
                $other.Length | Should -Be $entry.Length
            }
        }
        finally { $a.Dispose(); $b.Dispose() }
    }

    It "Writes an ASCII English explanation into sweepr.portable" {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($script:PortableZip)
        try {
            $entry = $archive.GetEntry("sweepr.portable")
            $entry | Should -Not -BeNullOrEmpty
            $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::ASCII)
            try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
        finally { $archive.Dispose() }
        $text.Trim().Length | Should -BeGreaterThan 20
        $text | Should -Match '(?i)portable mode'
        $text | Should -Match '(?i)data folder'
        $text | Should -Match '(?i)delete this file'
        $text | Should -Not -Match '[^\x09\x0A\x0D\x20-\x7E]'
    }

    It "Lists both zips in SHA256SUMS.txt with matching hashes" {
        $lines = @(Get-Content (Join-Path $script:ReleaseDir "SHA256SUMS.txt"))
        foreach ($name in @("sweepr-9.9.9-x64.zip", "sweepr-9.9.9-x64-portable.zip")) {
            $expected = (Get-FileHash (Join-Path $script:ReleaseDir $name) -Algorithm SHA256).Hash.ToLowerInvariant()
            $lines | Should -Contain "$expected  $name"
        }
    }
}

Describe "release workflow portable asset" {
    BeforeAll {
        $script:WorkflowText = Get-Content (Join-Path $script:WindowsDir ".github/workflows/release-windows.yml") -Raw
        $script:Asset = 'release/sweepr-${{ steps.version.outputs.VERSION }}-x64-portable.zip'
    }

    It "Uploads the portable zip as a workflow artifact" {
        $uploads = [regex]::Matches($script:WorkflowText, '(?ms)uses: actions/upload-artifact@.*?(?=^\s*- name:|\z)')
        @($uploads | Where-Object { $_.Value.Contains($script:Asset) }).Count | Should -BeGreaterThan 0
    }

    It "Attaches the portable zip to the release" {
        # The release job lists the files it attaches under "files:" of the release action.
        $release = [regex]::Match($script:WorkflowText, '(?ms)uses: softprops/action-gh-release@.*?files: \|(?<files>.*?)^\s*draft:')
        $release.Success | Should -BeTrue
        $files = $release.Groups['files'].Value
        $files | Should -Match ([regex]::Escape('release/sweepr-${{ needs.build-windows.outputs.version }}-x64-portable.zip'))
        $files | Should -Match ([regex]::Escape('release/sweepr-${{ needs.build-windows.outputs.version }}-x64.zip'))
    }
}
