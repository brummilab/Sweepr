# Sweepr - tests for lib\core\tui_binaries.ps1, part 1: loading, finding a program, asset names,
# checksum file, SHA-256, finding go and git, starting a native tool, status lines, old names.
#
# The rule numbers in the test names (TB- and S) number the rules and the safety invariants of the
# module's behavior; each testable rule and invariant has at least one test. Parts 2 and 3 are
# SwTuiBinariesRelease.Tests.ps1 (download, verify, install) and SwTuiBinariesResolve.Tests.ps1
# (decision, build, source check, return value).
#
# Interface pinned here (new names; the two old names stay as forwarding functions, not aliases):
#   Resolve-SwTuiBinary -Name -WindowsDir -DestinationPath -SourcePath [-Version] [-Refresh]
#   Find-SwTuiBinary -WindowsDir -Name            Get-SwTuiAssetName -Name
#   Get-SwPublishedChecksum -SumsText -AssetName  Get-SwFileSha256 -Path
#   Restore-SwTuiRelease, Build-SwTuiBinary, Test-SwSourceMatchesRelease
#   Get-SwToolPath -Name go|git [-RootDir]
#   Invoke-SwNativeTool -FilePath -ArgumentList -WorkingDirectory -TimeoutSeconds
#   Write-SwTuiStatus -Message [-Color]           Test-SwTuiOutputRedirected
#   Ensure-TuiBinary, Get-SweeprVersionFromScriptFile   (forwarding functions)
#
# Platform notes:
#   - Paths are built from $TestDrive. Nothing real is touched: no network, no real go or git run,
#     no profile folder. Programs that stand in for go and git are scripts (Linux) or copies of the
#     test PowerShell (Windows) in a folder of the test drive.
#   - Tests marked [W] describe a Windows fact and are meant to fail on Linux where it does not hold.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    $script:IsWindowsHost = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:CoreDir = Join-Path (Join-Path $script:RepoRoot 'lib') 'core'
    $script:TuiFile = Join-Path $script:CoreDir 'tui_binaries.ps1'
    $script:IsWin = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
    $script:Pwsh = (Get-Process -Id $PID).Path
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
    $script:SavedLocation = (Get-Location).Path
    $script:SavedProcessDirectory = [System.Environment]::CurrentDirectory
    $script:SavedPath = $env:PATH

    . $script:TuiFile

    $script:NewNames = @(
        'Resolve-SwTuiBinary', 'Find-SwTuiBinary', 'Get-SwTuiAssetName', 'Get-SwPublishedChecksum', 'Get-SwFileSha256',
        'Restore-SwTuiRelease', 'Build-SwTuiBinary', 'Test-SwSourceMatchesRelease', 'Get-SwToolPath', 'Invoke-SwNativeTool',
        'Write-SwTuiStatus', 'Test-SwTuiOutputRedirected'
    )

    function script:New-Dir([string]$Path) {
        [void][System.IO.Directory]::CreateDirectory($Path)
        return $Path
    }
    function script:New-TextFile([string]$Path, [string]$Text) {
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path))
        [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8)
        return $Path
    }
    function script:ConvertTo-TestLiteral([string]$Value) { "'" + $Value.Replace("'", "''") + "'" }
    function script:Get-Sha256Text([byte[]]$Bytes) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return (([BitConverter]::ToString($sha.ComputeHash($Bytes))) -replace '-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
    }
    function script:Set-TestLocation([string]$Path) {
        Set-Location -LiteralPath $Path
        [System.Environment]::CurrentDirectory = $Path
    }
    function script:Restore-TestLocation {
        Set-Location -LiteralPath $script:SavedLocation
        [System.Environment]::CurrentDirectory = $script:SavedProcessDirectory
        $env:PATH = $script:SavedPath
    }

    # A program called $Name in $Dir that file lookup finds: a shell script on Linux, a copy of the
    # test PowerShell as <Name>.exe on Windows.
    function script:New-FakeTool([string]$Dir, [string]$Name) {
        [void][System.IO.Directory]::CreateDirectory($Dir)
        if ($script:IsWin) {
            $path = [System.IO.Path]::Combine($Dir, $Name + '.exe')
            [System.IO.File]::Copy($script:Pwsh, $path, $true)
        }
        else {
            $path = [System.IO.Path]::Combine($Dir, $Name)
            [System.IO.File]::WriteAllText($path, "#!/bin/sh`nexit 0`n", $script:Utf8)
            & chmod 755 $path
        }
        return $path
    }

    function script:Invoke-ChildPowerShell {
        param([string]$Script, [string]$WorkingDirectory = $TestDrive, [hashtable]$Environment = @{}, [string[]]$RemoveEnvironment = @())
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Script))
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $script:Pwsh
        $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.WorkingDirectory = $WorkingDirectory
        foreach ($name in $RemoveEnvironment) { if ($psi.EnvironmentVariables.ContainsKey($name)) { $psi.EnvironmentVariables.Remove($name) } }
        foreach ($name in $Environment.Keys) { $psi.EnvironmentVariables[$name] = [string]$Environment[$name] }
        $process = [System.Diagnostics.Process]::Start($psi)
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { $process.Kill(); throw 'child PowerShell timed out' }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Out = $stdout.Result; Err = $stderr.Result }
    }
    # Windows PowerShell serializes progress records into redirected stderr as CLIXML. That is the host
    # talking, not the loaded file: drop the progress records and the envelope.
    function script:Get-ChildStderr([string]$Text) {
        if ([string]::IsNullOrEmpty($Text)) { return '' }
        $clean = [regex]::Replace($Text, '(?s)<Obj S="progress".*?</Obj>', '')
        $clean = [regex]::Replace($clean, '<Objs[^>]*>|</Objs>|#< CLIXML', '')
        return $clean.Trim()
    }
    function script:Get-FileListing([string]$Root) {
        if (-not [System.IO.Directory]::Exists($Root)) { return @() }
        return @([System.IO.Directory]::GetFileSystemEntries($Root, '*', [System.IO.SearchOption]::AllDirectories) | Sort-Object)
    }
}

AfterAll {
    Restore-TestLocation
}

Describe 'Sw TUI binaries: interface exists' {
    It 'Defines <_> as a function' -ForEach @(
        'Resolve-SwTuiBinary', 'Find-SwTuiBinary', 'Get-SwTuiAssetName', 'Get-SwPublishedChecksum', 'Get-SwFileSha256',
        'Restore-SwTuiRelease', 'Build-SwTuiBinary', 'Test-SwSourceMatchesRelease', 'Get-SwToolPath', 'Invoke-SwNativeTool',
        'Write-SwTuiStatus', 'Test-SwTuiOutputRedirected', 'Ensure-TuiBinary', 'Get-SweeprVersionFromScriptFile'
    ) {
        (Get-Command -Name $_ -CommandType Function -ErrorAction Stop).Name | Should -Be $_
    }

    It 'Gives <Name> the parameters of the interface' -ForEach @(
        @{ Name = 'Resolve-SwTuiBinary'; Parameters = @('Name', 'WindowsDir', 'DestinationPath', 'SourcePath', 'Version', 'Refresh') }
        @{ Name = 'Find-SwTuiBinary'; Parameters = @('WindowsDir', 'Name') }
        @{ Name = 'Get-SwTuiAssetName'; Parameters = @('Name') }
        @{ Name = 'Get-SwPublishedChecksum'; Parameters = @('SumsText', 'AssetName') }
        @{ Name = 'Get-SwFileSha256'; Parameters = @('Path') }
        @{ Name = 'Restore-SwTuiRelease'; Parameters = @('Name', 'WindowsDir', 'DestinationPath', 'Version') }
        @{ Name = 'Build-SwTuiBinary'; Parameters = @('Name', 'WindowsDir', 'DestinationPath', 'SourcePath') }
        @{ Name = 'Test-SwSourceMatchesRelease'; Parameters = @('WindowsDir', 'Name', 'Version') }
        @{ Name = 'Get-SwToolPath'; Parameters = @('Name', 'RootDir') }
        @{ Name = 'Invoke-SwNativeTool'; Parameters = @('FilePath', 'ArgumentList', 'WorkingDirectory', 'TimeoutSeconds') }
        @{ Name = 'Write-SwTuiStatus'; Parameters = @('Message', 'Color') }
        @{ Name = 'Test-SwTuiOutputRedirected'; Parameters = @() }
    ) {
        $command = Get-Command -Name $Name -CommandType Function -ErrorAction Stop
        foreach ($parameter in $Parameters) { $command.Parameters.ContainsKey($parameter) | Should -BeTrue -Because "$Name has -$parameter" }
    }

    It 'Takes the status message at position 0 of Write-SwTuiStatus' {
        (Get-Command Write-SwTuiStatus).Parameters['Message'].Attributes.Where({ $_ -is [System.Management.Automation.ParameterAttribute] }).Position | Should -Be 0
    }

    It 'Makes Resolve-SwTuiBinary -Refresh a switch' {
        (Get-Command Resolve-SwTuiBinary).Parameters['Refresh'].ParameterType | Should -Be ([switch])
    }
}

Describe 'Sw TUI binaries: loading (TB-1)' {
    BeforeAll {
        # A fake lib\core with the two files the loader may use. There is no base.ps1 and no log.ps1.
        $script:Fake = New-Dir (Join-Path $TestDrive 'tb1\root\lib\core')
        Copy-Item -LiteralPath (Join-Path $script:CoreDir 'version.ps1') -Destination $script:Fake
        Copy-Item -LiteralPath $script:TuiFile -Destination $script:Fake
        $script:FakeTui = Join-Path $script:Fake 'tui_binaries.ps1'
        $script:FakeRoot = Join-Path $TestDrive 'tb1\root'
        $script:Cwd = New-Dir (Join-Path $TestDrive 'tb1\cwd')
        # A decoy version.ps1 in the working directory must not be loaded.
        New-TextFile (Join-Path $script:Cwd 'lib\core\version.ps1') "function Get-SwInstalledVersion { 'decoy' }`n" | Out-Null
        New-TextFile (Join-Path $script:Cwd 'version.ps1') "function Get-SwInstalledVersion { 'decoy' }`n" | Out-Null
        $script:ProfileDir = New-Dir (Join-Path $TestDrive 'tb1\profile')
        $script:Marker = Join-Path $TestDrive 'tb1\network-or-process-marker.txt'

        $tui = ConvertTo-TestLiteral $script:FakeTui
        $marker = ConvertTo-TestLiteral $script:Marker
        $names = ($script:NewNames + @('Ensure-TuiBinary', 'Get-SweeprVersionFromScriptFile') | ForEach-Object { "'$_'" }) -join ','
        $script:RootBefore = @(Get-FileListing $script:FakeRoot)
        $script:CwdBefore = @(Get-FileListing $script:Cwd)
        $script:Load = Invoke-ChildPowerShell -WorkingDirectory $script:Cwd -RemoveEnvironment @('SWEEPR_DATA_DIR') -Environment @{
            USERPROFILE = $script:ProfileDir
            HOME        = $script:ProfileDir
        } -Script @"
Set-StrictMode -Off
`$ErrorActionPreference = 'Continue'
function Invoke-WebRequest { Set-Content -LiteralPath $marker -Value 'network'; throw 'network' }
function Invoke-RestMethod { Set-Content -LiteralPath $marker -Value 'network'; throw 'network' }
function Start-Process { Set-Content -LiteralPath $marker -Value 'process'; throw 'process' }
`$envBefore = (Get-ChildItem Env: | Sort-Object Name | ForEach-Object { `$_.Name + '=' + `$_.Value }) -join '|'
. $tui
. $tui
'##RESULT##'
`$r = [ordered]@{}
`$r.Eap = [string]`$ErrorActionPreference
`$r.Strict = try { `$null = `$notDefinedAnywhere; 'off' } catch { 'on' }
`$r.Missing = @(foreach (`$n in @($names)) { if (-not (Get-Command `$n -CommandType Function -ErrorAction SilentlyContinue)) { `$n } })
`$r.VersionFile = [string](Get-Command Get-SwInstalledVersion -CommandType Function).ScriptBlock.File
`$r.BaseLoaded = @(foreach (`$n in @('Get-SwBaseEnv','Write-SwError','Start-SwDebugSession')) { if (Get-Command `$n -ErrorAction SilentlyContinue) { `$n } })
`$r.EnvSame = (((Get-ChildItem Env: | Sort-Object Name | ForEach-Object { `$_.Name + '=' + `$_.Value }) -join '|') -eq `$envBefore)
`$r | ConvertTo-Json -Compress
"@
        $parts = $script:Load.Out -split '##RESULT##'
        $script:LoadOutput = $parts[0]
        $script:LoadData = $null
        if ($parts.Count -gt 1) { $script:LoadData = $parts[1].Trim() | ConvertFrom-Json }
    }

    It 'Loads twice in one scope without error' {
        $script:Load.ExitCode | Should -Be 0
        $script:LoadData | Should -Not -BeNullOrEmpty
    }

    It 'Writes nothing while loading' {
        $script:LoadOutput.Trim() | Should -BeNullOrEmpty
        (Get-ChildStderr $script:Load.Err) | Should -BeNullOrEmpty
    }

    It 'Defines every function of the interface and the two old names' {
        @($script:LoadData.Missing) | Should -BeNullOrEmpty
    }

    It 'Takes version.ps1 from its own folder, not from the working directory' {
        $script:LoadData.VersionFile | Should -BeExactly $script:FakeTui.Replace('tui_binaries.ps1', 'version.ps1')
    }

    It 'Needs neither base.ps1 nor log.ps1' {
        @($script:LoadData.BaseLoaded) | Should -BeNullOrEmpty
    }

    It 'Neither sets strict mode nor changes the error preference of the caller' {
        $script:LoadData.Eap | Should -Be 'Continue'
        $script:LoadData.Strict | Should -Be 'off'
    }

    It 'Starts no process, uses no network and changes no environment variable' {
        [System.IO.File]::Exists($script:Marker) | Should -BeFalse
        $script:LoadData.EnvSame | Should -BeTrue
    }

    It 'Creates no file or folder anywhere in the fake installation, the working directory or the profile' {
        # PowerShell itself may create its own folders in the profile; Sweepr must create none.
        @(Get-FileListing $script:ProfileDir | Where-Object { $_ -match '(?i)sweepr|[\\/]\.config' }).Count | Should -Be 0
        @(Get-FileListing $script:FakeRoot) | Should -Be $script:RootBefore
        @(Get-FileListing $script:Cwd) | Should -Be $script:CwdBefore
    }
}

Describe 'Find-SwTuiBinary (TB-2)' {
    BeforeEach {
        $script:Root = New-Dir (Join-Path $TestDrive ('find-' + [guid]::NewGuid().ToString('N')))
    }

    It 'Finds bin\<name>.exe' {
        $file = New-TextFile (Join-Path $script:Root 'bin\analyze.exe') 'x'
        Find-SwTuiBinary -WindowsDir $script:Root -Name 'analyze' | Should -BeExactly $file
    }

    It 'Finds <name>.exe in the installation root' {
        $file = New-TextFile (Join-Path $script:Root 'status.exe') 'x'
        Find-SwTuiBinary -WindowsDir $script:Root -Name 'status' | Should -BeExactly $file
    }

    It 'Prefers the file in bin over the one in the root' {
        New-TextFile (Join-Path $script:Root 'analyze.exe') 'root' | Out-Null
        $inBin = New-TextFile (Join-Path $script:Root 'bin\analyze.exe') 'bin'
        Find-SwTuiBinary -WindowsDir $script:Root -Name 'analyze' | Should -BeExactly $inBin
    }

    It 'Returns $null when there is no file' {
        Find-SwTuiBinary -WindowsDir $script:Root -Name 'analyze' | Should -BeNullOrEmpty
        $null -eq (Find-SwTuiBinary -WindowsDir $script:Root -Name 'status') | Should -BeTrue
    }

    It 'Returns $null for an installation root that does not exist' {
        $null -eq (Find-SwTuiBinary -WindowsDir (Join-Path $script:Root 'missing') -Name 'analyze') | Should -BeTrue
    }

    It 'Does not count a folder named analyze.exe' {
        New-Dir (Join-Path $script:Root 'bin\analyze.exe') | Out-Null
        $null -eq (Find-SwTuiBinary -WindowsDir $script:Root -Name 'analyze') | Should -BeTrue
    }

    It 'Falls through from a folder in bin to the file in the root' {
        New-Dir (Join-Path $script:Root 'bin\analyze.exe') | Out-Null
        $file = New-TextFile (Join-Path $script:Root 'analyze.exe') 'x'
        Find-SwTuiBinary -WindowsDir $script:Root -Name 'analyze' | Should -BeExactly $file
    }

    It 'Does not mix up the two programs' {
        New-TextFile (Join-Path $script:Root 'bin\analyze.exe') 'x' | Out-Null
        $null -eq (Find-SwTuiBinary -WindowsDir $script:Root -Name 'status') | Should -BeTrue
    }

    It 'Treats brackets, quotes and spaces in the root literally' {
        $parent = New-Dir (Join-Path $TestDrive ('literal-' + [guid]::NewGuid().ToString('N')))
        # A sibling that the bracket pattern would match as a wildcard, holding a program of its own.
        New-TextFile (Join-Path $parent 'Tools x64\sweepr\bin\analyze.exe') 'decoy' | Out-Null
        $root = [System.IO.Path]::Combine($parent, "Tools [x64] it's\sweepr")
        $file = New-TextFile ([System.IO.Path]::Combine($root, 'bin', 'analyze.exe')) 'real'
        Find-SwTuiBinary -WindowsDir $root -Name 'analyze' | Should -BeExactly $file
    }

    It 'Returns one string and nothing else' {
        New-TextFile (Join-Path $script:Root 'bin\status.exe') 'x' | Out-Null
        $result = @(Find-SwTuiBinary -WindowsDir $script:Root -Name 'status')
        $result.Count | Should -Be 1
        $result[0] | Should -BeOfType [string]
    }
}

Describe 'Get-SwTuiAssetName' {
    It 'Names the release asset <Name>-windows-x64.exe' -ForEach @(
        @{ Name = 'analyze'; Expected = 'analyze-windows-x64.exe' }
        @{ Name = 'status'; Expected = 'status-windows-x64.exe' }
    ) {
        Get-SwTuiAssetName -Name $Name | Should -BeExactly $Expected
    }
}

Describe 'Get-SwPublishedChecksum (TB-8)' {
    BeforeAll {
        $script:HashA = ('0123456789abcdef' * 4)
        $script:HashB = ('fedcba9876543210' * 4)
        $script:HashUpper = $script:HashA.ToUpperInvariant()
        $script:Bom = [string][char]0xFEFF
    }

    It 'Returns the hash of the line for the asset' {
        $text = "$($script:HashA)  status-windows-x64.exe`n$($script:HashB)  analyze-windows-x64.exe`n"
        Get-SwPublishedChecksum -SumsText $text -AssetName 'status-windows-x64.exe' | Should -BeExactly $script:HashA
        Get-SwPublishedChecksum -SumsText $text -AssetName 'analyze-windows-x64.exe' | Should -BeExactly $script:HashB
    }

    It 'Returns the hash in lower case, also when it is published in upper case' {
        $text = "$($script:HashUpper)  status-windows-x64.exe`n"
        Get-SwPublishedChecksum -SumsText $text -AssetName 'status-windows-x64.exe' | Should -BeExactly $script:HashA
    }

    It 'Reads CRLF line ends and a star before the name' {
        $text = "$($script:HashB)  sweepr-1.0.0-x64.zip`r`n$($script:HashUpper) *status-windows-x64.exe`r`n"
        Get-SwPublishedChecksum -SumsText $text -AssetName 'status-windows-x64.exe' | Should -BeExactly $script:HashA
    }

    It 'Reads a single blank and a tab between hash and name' {
        Get-SwPublishedChecksum -SumsText "$($script:HashA) status-windows-x64.exe" -AssetName 'status-windows-x64.exe' | Should -BeExactly $script:HashA
        Get-SwPublishedChecksum -SumsText "$($script:HashA)`tstatus-windows-x64.exe" -AssetName 'status-windows-x64.exe' | Should -BeExactly $script:HashA
    }

    It 'Ignores a byte order mark at the start of the text' {
        $text = $script:Bom + "$($script:HashA)  status-windows-x64.exe`n"
        Get-SwPublishedChecksum -SumsText $text -AssetName 'status-windows-x64.exe' | Should -BeExactly $script:HashA
    }

    It 'Ignores blanks around the name' {
        Get-SwPublishedChecksum -SumsText "$($script:HashA)  status-windows-x64.exe   `n" -AssetName 'status-windows-x64.exe' | Should -BeExactly $script:HashA
    }

    It 'Returns $null when the asset has no line' {
        $text = "$($script:HashB)  analyze-windows-x64.exe`n"
        $null -eq (Get-SwPublishedChecksum -SumsText $text -AssetName 'status-windows-x64.exe') | Should -BeTrue
    }

    It 'Matches the file name exactly, character for character, not as a suffix, prefix or pattern' -ForEach @(
        @{ Line = 'status-windows-x64.exe.sig' }
        @{ Line = 'xstatus-windows-x64.exe' }
        @{ Line = 'status-windows-x64.exe2' }
        @{ Line = 'STATUS-WINDOWS-X64.EXE' }
        @{ Line = 'statusXwindows-x64.exe' }
        @{ Line = 'dir/status-windows-x64.exe' }
        @{ Line = 'status-windows-x64.ex*' }
    ) {
        $null -eq (Get-SwPublishedChecksum -SumsText "$($script:HashA)  $Line`n" -AssetName 'status-windows-x64.exe') | Should -BeTrue
    }

    It 'Does not take a hash that is not 64 hexadecimal characters' -ForEach @(
        @{ Hash = ('0123456789abcdef' * 4).Substring(1) }
        @{ Hash = ('0123456789abcdef' * 4) + '0' }
        @{ Hash = ('g123456789abcdef' * 4) }
    ) {
        $null -eq (Get-SwPublishedChecksum -SumsText "$Hash  status-windows-x64.exe`n" -AssetName 'status-windows-x64.exe') | Should -BeTrue
    }

    It 'Returns the hash when the same file is listed twice with the same hash' {
        $text = "$($script:HashA)  status-windows-x64.exe`n$($script:HashUpper)  status-windows-x64.exe`n"
        Get-SwPublishedChecksum -SumsText $text -AssetName 'status-windows-x64.exe' | Should -BeExactly $script:HashA
    }

    It 'Returns $null when the same file is listed with different hashes' {
        $text = "$($script:HashA)  status-windows-x64.exe`n$($script:HashB)  status-windows-x64.exe`n"
        $null -eq (Get-SwPublishedChecksum -SumsText $text -AssetName 'status-windows-x64.exe') | Should -BeTrue
    }

    It 'Returns $null for empty text' -ForEach @(
        @{ Text = '' }
        @{ Text = "`n`n" }
        @{ Text = 'not a checksum file' }
    ) {
        $null -eq (Get-SwPublishedChecksum -SumsText $Text -AssetName 'status-windows-x64.exe') | Should -BeTrue
    }

    It 'Returns a string' {
        (Get-SwPublishedChecksum -SumsText "$($script:HashA)  status-windows-x64.exe`n" -AssetName 'status-windows-x64.exe') | Should -BeOfType [string]
    }
}

Describe 'Get-SwFileSha256 (TB-9)' {
    It 'Returns the known hash of an empty file' {
        $file = Join-Path $TestDrive 'sha-empty.bin'
        [System.IO.File]::WriteAllBytes($file, [byte[]]@())
        Get-SwFileSha256 -Path $file | Should -BeExactly 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
    }

    It 'Returns the known hash of the text abc, in lower case and 64 characters' {
        $file = Join-Path $TestDrive 'sha-abc.bin'
        [System.IO.File]::WriteAllBytes($file, [System.Text.Encoding]::ASCII.GetBytes('abc'))
        $hash = Get-SwFileSha256 -Path $file
        $hash | Should -BeExactly 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
        $hash.Length | Should -Be 64
    }

    It 'Hashes a path with brackets, quotes and blanks literally' {
        $folder = New-Dir (Join-Path $TestDrive "sha [x64] it's")
        $file = Join-Path $folder 'a[1].bin'
        [System.IO.File]::WriteAllBytes($file, [System.Text.Encoding]::ASCII.GetBytes('abc'))
        # A file the bracket pattern would match must not be hashed instead.
        [System.IO.File]::WriteAllBytes((Join-Path $folder 'a1.bin'), [byte[]]@(1, 2, 3))
        Get-SwFileSha256 -Path $file | Should -BeExactly 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
    }

    It 'Does not depend on Get-FileHash' {
        Mock Get-FileHash { throw [System.Management.Automation.CommandNotFoundException]::new('Get-FileHash is not available') }
        $file = Join-Path $TestDrive 'sha-nofilehash.bin'
        [System.IO.File]::WriteAllBytes($file, [System.Text.Encoding]::ASCII.GetBytes('abc'))
        Get-SwFileSha256 -Path $file | Should -BeExactly 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
        Should -Invoke Get-FileHash -Times 0 -Exactly
    }

    It 'Hashes a file that another process holds open for reading' {
        $file = Join-Path $TestDrive 'sha-shared.bin'
        [System.IO.File]::WriteAllBytes($file, [System.Text.Encoding]::ASCII.GetBytes('abc'))
        $stream = [System.IO.File]::Open($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try { Get-SwFileSha256 -Path $file | Should -BeExactly 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' }
        finally { $stream.Dispose() }
    }
}

Describe 'Get-SwToolPath (TB-13, S7)' {
    BeforeEach {
        $script:Tools = New-Dir (Join-Path $TestDrive ('tools-' + [guid]::NewGuid().ToString('N')))
        $script:Elsewhere = New-Dir (Join-Path $TestDrive ('elsewhere-' + [guid]::NewGuid().ToString('N')))
    }
    AfterEach {
        Restore-TestLocation
    }

    It 'Returns the absolute path of the program found through PATH' {
        $go = New-FakeTool (Join-Path $script:Tools 'bin') 'go'
        $env:PATH = (Join-Path $script:Tools 'bin')
        Set-TestLocation $script:Elsewhere
        $found = Get-SwToolPath -Name 'go'
        $found | Should -BeExactly $go
        [System.IO.Path]::IsPathRooted($found) | Should -BeTrue
        [System.IO.File]::Exists($found) | Should -BeTrue
    }

    It 'Finds git as well' {
        $git = New-FakeTool (Join-Path $script:Tools 'bin') 'git'
        $env:PATH = (Join-Path $script:Tools 'bin')
        Set-TestLocation $script:Elsewhere
        Get-SwToolPath -Name 'git' | Should -BeExactly $git
    }

    It 'Returns $null when the program is nowhere in PATH' {
        $env:PATH = $script:Tools
        Set-TestLocation $script:Elsewhere
        $null -eq (Get-SwToolPath -Name 'go') | Should -BeTrue
    }

    It 'Returns $null when PATH is empty and never throws' {
        $env:PATH = ''
        Set-TestLocation $script:Elsewhere
        { Get-SwToolPath -Name 'git' } | Should -Not -Throw
        $null -eq (Get-SwToolPath -Name 'git') | Should -BeTrue
    }

    It 'Does not return a program in the current working directory' {
        New-FakeTool $script:Tools 'go' | Out-Null
        $env:PATH = $script:Tools
        Set-TestLocation $script:Tools
        $null -eq (Get-SwToolPath -Name 'go') | Should -BeTrue
    }

    It 'Does not return a program in the working directory reached through the relative PATH entry .' {
        New-FakeTool $script:Tools 'go' | Out-Null
        $env:PATH = '.'
        Set-TestLocation $script:Tools
        $null -eq (Get-SwToolPath -Name 'go') | Should -BeTrue
    }

    It 'Does not return a program in the installation root or below it' {
        $root = New-Dir (Join-Path $script:Tools 'sweepr')
        New-FakeTool $root 'go' | Out-Null
        New-FakeTool (Join-Path $root 'bin') 'git' | Out-Null
        $env:PATH = ($root, (Join-Path $root 'bin')) -join [System.IO.Path]::PathSeparator
        Set-TestLocation $script:Elsewhere
        $null -eq (Get-SwToolPath -Name 'go' -RootDir $root) | Should -BeTrue
        $null -eq (Get-SwToolPath -Name 'git' -RootDir $root) | Should -BeTrue
    }

    It 'Returns a program in a folder that only shares a name prefix with the installation root' {
        $root = New-Dir (Join-Path $script:Tools 'sweepr')
        $sibling = Join-Path $script:Tools 'sweepr2\bin'
        $go = New-FakeTool $sibling 'go'
        $env:PATH = $sibling
        Set-TestLocation $script:Elsewhere
        Get-SwToolPath -Name 'go' -RootDir $root | Should -BeExactly $go
    }

    It 'Skips the working directory and returns the next match in PATH' {
        $first = New-Dir (Join-Path $script:Tools 'first')
        New-FakeTool $first 'go' | Out-Null
        $second = New-FakeTool (Join-Path $script:Tools 'second') 'go'
        $env:PATH = ($first, (Join-Path $script:Tools 'second')) -join [System.IO.Path]::PathSeparator
        Set-TestLocation $first
        Get-SwToolPath -Name 'go' | Should -BeExactly $second
    }

    It 'Ignores a relative PATH entry, also when the program is found below the working folder' {
        $go = New-FakeTool (Join-Path $script:Tools 'rel/bin') 'go'
        $env:PATH = (Join-Path 'rel' 'bin')
        Set-TestLocation $script:Tools
        $null -eq (Get-SwToolPath -Name 'go') | Should -BeTrue
        # The same folder as an absolute entry is accepted.
        $env:PATH = (Join-Path 'rel' 'bin'), (Join-Path $script:Tools 'rel/bin') -join [System.IO.Path]::PathSeparator
        Set-TestLocation $script:Elsewhere
        [System.IO.Path]::GetFullPath((Get-SwToolPath -Name 'go')) | Should -BeExactly ([System.IO.Path]::GetFullPath($go))
    }

    It 'Accepts a program outside the files of a drive root given as the installation root' {
        $go = New-FakeTool (Join-Path $script:Tools 'bin') 'go'
        $env:PATH = (Join-Path $script:Tools 'bin')
        Set-TestLocation $script:Elsewhere
        $driveRoot = [System.IO.Path]::GetPathRoot($script:Tools)
        Get-SwToolPath -Name 'go' -RootDir $driveRoot | Should -BeExactly $go
    }

    It 'Still excludes the subtree of an installation folder that is not a drive root' {
        $root = New-Dir (Join-Path $script:Tools 'sweepr')
        New-FakeTool (Join-Path $root 'deep/er') 'go' | Out-Null
        $env:PATH = (Join-Path $root 'deep/er')
        Set-TestLocation $script:Elsewhere
        $null -eq (Get-SwToolPath -Name 'go' -RootDir $root) | Should -BeTrue
    }

    It '[W] Returns only a .exe: a .cmd or .bat of that name is not used' {
        $folder = New-Dir (Join-Path $script:Tools 'cmdonly')
        [System.IO.File]::WriteAllText((Join-Path $folder 'go.cmd'), "@exit /b 0`r`n")
        [System.IO.File]::WriteAllText((Join-Path $folder 'git.bat'), "@exit /b 0`r`n")
        $env:PATH = $folder
        Set-TestLocation $script:Elsewhere
        $null -eq (Get-SwToolPath -Name 'go') | Should -BeTrue
        $null -eq (Get-SwToolPath -Name 'git') | Should -BeTrue
        # The same folder with a real .exe is accepted.
        $exe = [System.IO.Path]::Combine($folder, 'go.exe')
        [System.IO.File]::Copy($script:Pwsh, $exe, $true)
        Get-SwToolPath -Name 'go' | Should -BeExactly $exe
    }
}

Describe 'Invoke-SwNativeTool (the only process start)' {
    BeforeAll {
        $script:ShowArgs = New-TextFile (Join-Path $TestDrive 'native\show-args.ps1') @'
foreach ($a in $args) { [Console]::Out.WriteLine('[' + $a + ']') }
'@
        $script:ShowLocation = New-TextFile (Join-Path $TestDrive 'native\show-location.ps1') @'
[Console]::Out.WriteLine('[' + [System.Environment]::CurrentDirectory + ']')
'@
        $script:Work = New-Dir (Join-Path $TestDrive 'native\work')
        $script:Quiet = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass')
    }

    It 'Returns the exit code, standard output and standard error, and TimedOut false' {
        $script = '[Console]::Out.Write("out1"); [Console]::Error.Write("err1"); exit 3'
        $result = Invoke-SwNativeTool -FilePath $script:Pwsh -ArgumentList ($script:Quiet + @('-Command', $script)) -WorkingDirectory $script:Work -TimeoutSeconds 60
        $result.ExitCode | Should -Be 3
        $result.ExitCode | Should -BeOfType [int]
        $result.StdOut.Trim() | Should -BeExactly 'out1'
        (Get-ChildStderr $result.StdErr) | Should -BeExactly 'err1'
        $result.StdOut | Should -BeOfType [string]
        $result.TimedOut | Should -BeFalse
    }

    It 'Returns exit code 0 for a program that succeeds' {
        $result = Invoke-SwNativeTool -FilePath $script:Pwsh -ArgumentList ($script:Quiet + @('-Command', 'exit 0')) -WorkingDirectory $script:Work -TimeoutSeconds 60
        $result.ExitCode | Should -Be 0
        $result.TimedOut | Should -BeFalse
    }

    It 'Passes every argument as one argument: blanks, quotes and trailing backslashes stay' {
        $arguments = $script:Quiet + @('-File', $script:ShowArgs, 'a b', 'c"d', 'e\', 'D:\dir with space\', 'x;y&z|w', '$(calc)', '*.*')
        $result = Invoke-SwNativeTool -FilePath $script:Pwsh -ArgumentList $arguments -WorkingDirectory $script:Work -TimeoutSeconds 60
        $result.ExitCode | Should -Be 0
        $lines = @($result.StdOut -split "`r?`n" | Where-Object { $_ -ne '' })
        $lines | Should -Be @('[a b]', '[c"d]', '[e\]', '[D:\dir with space\]', '[x;y&z|w]', '[$(calc)]', '[*.*]')
    }

    It 'Starts the program in the working directory, also with blanks and brackets in its name' {
        $folder = New-Dir (Join-Path $TestDrive "native\work [x64] it's")
        $result = Invoke-SwNativeTool -FilePath $script:Pwsh -ArgumentList ($script:Quiet + @('-File', $script:ShowLocation)) -WorkingDirectory $folder -TimeoutSeconds 60
        $result.ExitCode | Should -Be 0
        $reported = $result.StdOut.Trim().TrimStart('[').TrimEnd(']')
        [System.IO.Path]::GetFullPath($reported).TrimEnd('\', '/') | Should -BeExactly ([System.IO.Path]::GetFullPath($folder).TrimEnd('\', '/'))
    }

    It 'Stops a program that runs longer than the time limit and reports TimedOut' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-SwNativeTool -FilePath $script:Pwsh -ArgumentList ($script:Quiet + @('-Command', 'Start-Sleep -Seconds 120')) -WorkingDirectory $script:Work -TimeoutSeconds 2
        $watch.Stop()
        $result.TimedOut | Should -BeTrue
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 60
    }

    It 'Ends the child processes of a program that timed out' {
        $pidFile = Join-Path $TestDrive 'native\grandchild.pid'
        $inner = ConvertTo-TestLiteral $script:Pwsh
        $script = New-TextFile (Join-Path $TestDrive 'native\spawn.ps1') @"
`$p = Start-Process -FilePath $inner -ArgumentList '-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 120' -PassThru
[System.IO.File]::WriteAllText($(ConvertTo-TestLiteral $pidFile), [string]`$p.Id)
Start-Sleep -Seconds 120
"@
        $result = Invoke-SwNativeTool -FilePath $script:Pwsh -ArgumentList ($script:Quiet + @('-File', $script)) -WorkingDirectory $script:Work -TimeoutSeconds 10
        $result.TimedOut | Should -BeTrue
        [System.IO.File]::Exists($pidFile) | Should -BeTrue -Because 'the program started its child before the limit'
        $childId = [int][System.IO.File]::ReadAllText($pidFile)
        $alive = $true
        for ($i = 0; $i -lt 50 -and $alive; $i++) {
            try {
                $process = [System.Diagnostics.Process]::GetProcessById($childId)
                $alive = -not $process.HasExited
                $process.Dispose()
            }
            catch { $alive = $false }
            if ($alive) { Start-Sleep -Milliseconds 100 }
        }
        $alive | Should -BeFalse
    }

    It 'Reads large output on both streams without blocking' {
        $script = '$s = "x" * 100000; 1..30 | ForEach-Object { [Console]::Out.Write($s); [Console]::Error.Write($s) }'
        $result = Invoke-SwNativeTool -FilePath $script:Pwsh -ArgumentList ($script:Quiet + @('-Command', $script)) -WorkingDirectory $script:Work -TimeoutSeconds 90
        $result.TimedOut | Should -BeFalse
        $result.ExitCode | Should -Be 0
        $result.StdOut.Length | Should -Be 3000000
        (Get-ChildStderr $result.StdErr).Length | Should -Be 3000000
    }

    It 'Does not use Start-Process or Invoke-Expression' {
        Mock Start-Process { throw 'Start-Process must not be used' }
        Mock Invoke-Expression { throw 'Invoke-Expression must not be used' }
        $result = Invoke-SwNativeTool -FilePath $script:Pwsh -ArgumentList ($script:Quiet + @('-Command', 'exit 0')) -WorkingDirectory $script:Work -TimeoutSeconds 60
        $result.ExitCode | Should -Be 0
        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke Invoke-Expression -Times 0 -Exactly
    }
}

Describe 'Write-SwTuiStatus (TB-15, S9)' {
    BeforeEach {
        $script:HostCalls = New-Object System.Collections.Generic.List[object]
        Mock Write-Host { $script:HostCalls.Add([pscustomobject]@{ Text = ($Object -join ' '); Color = [string]$ForegroundColor }) }
        $script:OriginalError = [Console]::Error
        $script:ErrorWriter = New-Object System.IO.StringWriter
        [Console]::SetError($script:ErrorWriter)
    }
    AfterEach {
        [Console]::SetError($script:OriginalError)
    }

    It 'Writes a host line in the given colour when the output is not redirected' {
        Mock Test-SwTuiOutputRedirected { $false }
        Write-SwTuiStatus 'building status' -Color 'Yellow'
        $script:HostCalls.Count | Should -Be 1
        $script:HostCalls[0].Text | Should -BeExactly 'building status'
        $script:HostCalls[0].Color | Should -Be 'Yellow'
        $script:ErrorWriter.ToString() | Should -BeNullOrEmpty
    }

    It 'Uses Gray when no colour is given' {
        Mock Test-SwTuiOutputRedirected { $false }
        Write-SwTuiStatus -Message 'plain'
        $script:HostCalls[0].Color | Should -Be 'Gray'
    }

    It 'Writes the line to the standard error stream of the process when the output is redirected' {
        Mock Test-SwTuiOutputRedirected { $true }
        Write-SwTuiStatus -Message 'building status' -Color 'Red'
        $script:HostCalls.Count | Should -Be 0
        $script:ErrorWriter.ToString().Trim() | Should -BeExactly 'building status'
    }

    It 'Writes nothing to the output pipeline or the PowerShell error stream' -ForEach @(
        @{ Redirected = $true }
        @{ Redirected = $false }
    ) {
        $script:RedirectedValue = $Redirected
        Mock Test-SwTuiOutputRedirected { $script:RedirectedValue }
        $records = @(& { Write-SwTuiStatus -Message 'quiet' } 2>&1 3>&1)
        $records.Count | Should -Be 0
    }

    It 'Replaces control characters other than line end and tab, in both channels' -ForEach @(
        @{ Redirected = $false }
        @{ Redirected = $true }
    ) {
        $script:RedirectedValue = $Redirected
        Mock Test-SwTuiOutputRedirected { $script:RedirectedValue }
        $esc = [string][char]27
        $message = 'a' + $esc + '[31mred' + $esc + '[0m' + 'b' + [char]0 + 'c' + [char]7 + 'd' + "`te"
        Write-SwTuiStatus -Message $message
        $written = ''
        if ($Redirected) { $written = $script:ErrorWriter.ToString() } else { $written = ($script:HostCalls | ForEach-Object { $_.Text }) -join "`n" }
        foreach ($code in 0, 7, 27) { $written.Contains([string][char]$code) | Should -BeFalse -Because "character $code" }
        $written | Should -Match 'red'
        $written | Should -Match "d`te"
    }

    It 'Keeps a line end inside the message' {
        Mock Test-SwTuiOutputRedirected { $false }
        Write-SwTuiStatus -Message "first`nsecond"
        $script:HostCalls[0].Text | Should -Match "first\r?\nsecond"
    }
}

Describe 'Test-SwTuiOutputRedirected (TB-15)' {
    It 'Returns true in a process whose output is redirected' {
        $tui = ConvertTo-TestLiteral $script:TuiFile
        $run = Invoke-ChildPowerShell -Script ". $tui; `$r = Test-SwTuiOutputRedirected; [Console]::Out.Write(`$r.GetType().Name + ':' + `$r)"
        $run.Out.Trim() | Should -BeExactly 'Boolean:True'
    }

    It 'Returns a boolean in this process' {
        Test-SwTuiOutputRedirected | Should -BeOfType [bool]
    }
}

Describe 'Old names (TB-17)' {
    It 'Keeps <Name> as a function, not an alias' -ForEach @(
        @{ Name = 'Ensure-TuiBinary' }
        @{ Name = 'Get-SweeprVersionFromScriptFile' }
    ) {
        (Get-Command -Name $Name -ErrorAction Stop).CommandType | Should -Be 'Function'
        Get-Alias -Name $Name -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'Forwards Ensure-TuiBinary to Resolve-SwTuiBinary with the same arguments' {
        Mock Resolve-SwTuiBinary { 'resolved-path' }
        $result = Ensure-TuiBinary -Name 'status' -WindowsDir 'C:\Example\sweepr' -DestinationPath 'C:\Example\sweepr\bin\status.exe' -SourcePath './cmd/status/' -Version '1.2.3' -Refresh
        $result | Should -BeExactly 'resolved-path'
        Should -Invoke Resolve-SwTuiBinary -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'status' -and $WindowsDir -eq 'C:\Example\sweepr' -and $DestinationPath -eq 'C:\Example\sweepr\bin\status.exe' -and
            $SourcePath -eq './cmd/status/' -and $Version -eq '1.2.3' -and $Refresh
        }
    }

    It 'Forwards without -Refresh when the switch is not given' {
        Mock Resolve-SwTuiBinary { $null }
        $null = Ensure-TuiBinary -Name 'analyze' -WindowsDir 'C:\Example\sweepr' -DestinationPath 'C:\Example\sweepr\bin\analyze.exe' -SourcePath './cmd/analyze/'
        Should -Invoke Resolve-SwTuiBinary -Times 1 -Exactly -ParameterFilter { -not $Refresh -and $Name -eq 'analyze' }
    }

    It 'Returns what Resolve-SwTuiBinary returns, including $null' {
        Mock Resolve-SwTuiBinary { $null }
        $result = @(Ensure-TuiBinary -Name 'analyze' -WindowsDir 'C:\Example\sweepr' -DestinationPath 'C:\Example\sweepr\bin\analyze.exe' -SourcePath './cmd/analyze/')
        $result.Count | Should -Be 1
        $null -eq $result[0] | Should -BeTrue
    }

    It 'Forwards Get-SweeprVersionFromScriptFile to Get-SwInstalledVersion for the installation root' {
        Mock Get-SwInstalledVersion { 'forwarded-version' }
        Get-SweeprVersionFromScriptFile -WindowsDir 'C:\Example\sweepr' | Should -BeExactly 'forwarded-version'
        Should -Invoke Get-SwInstalledVersion -Times 1 -Exactly -ParameterFilter { $RootDir -eq 'C:\Example\sweepr' }
    }

    It 'Defines none of the other old names' -ForEach @(
        @{ Name = 'Resolve-TuiBinaryPath' }
        @{ Name = 'Get-TuiBinaryAssetName' }
        @{ Name = 'Get-ChecksumFromSums' }
        @{ Name = 'Get-SweeprFileSha256' }
        @{ Name = 'Restore-PrebuiltTuiBinary' }
        @{ Name = 'Build-TuiBinary' }
        @{ Name = 'Test-TuiSourceMatchesRelease' }
        @{ Name = 'Write-TuiBinaryStatus' }
    ) {
        Get-Command -Name $Name -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}
