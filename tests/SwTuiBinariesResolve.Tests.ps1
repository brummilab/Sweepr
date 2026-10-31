# Sweepr - tests for lib\core\tui_binaries.ps1, part 3: Resolve-SwTuiBinary (existing file, inputs,
# version, decision, mismatch, exceptions, return value), Build-SwTuiBinary, Test-SwSourceMatchesRelease.
#
# The rule numbers in the test names (TB- and S) number the rules and the safety invariants of the
# module's behavior; each testable rule and invariant has at least one test.
#
# Platform notes:
#   - The network is replaced: Invoke-WebRequest is a mock that serves fake release files.
#     Invoke-SwNativeTool and Get-SwToolPath are mocks, so no real go build runs. The only real
#     program is git in the source-equivalence tests, on a repository made in $TestDrive; those
#     tests are skipped when git is not installed.
#   - Paths are built from $TestDrive. USERPROFILE and SWEEPR_DATA_DIR point into $TestDrive while
#     the tests run, so a write outside the destination folder would be seen.
#   - Tests marked [W] describe a Windows fact and are meant to fail on Linux where it does not hold.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    $script:HasGit = [bool](Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue)
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:CoreDir = Join-Path (Join-Path $script:RepoRoot 'lib') 'core'
    $script:TuiFile = Join-Path $script:CoreDir 'tui_binaries.ps1'
    $script:IsWin = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
    $script:Pwsh = (Get-Process -Id $PID).Path
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
    $script:DownloadRoot = 'https://github.com/brummilab/sweepr/releases/download'
    $script:GitNames = @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_CONFIG', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS')
    $script:EnvNames = @('USERPROFILE', 'HOME', 'SWEEPR_DATA_DIR', 'GOFLAGS', 'GOOS', 'GOARCH', 'GOTOOLCHAIN', 'GOPROXY', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM') + $script:GitNames

    . $script:TuiFile

    # The real function, kept to run git for real while recording the calls.
    $script:RealNative = (Get-Command -Name Invoke-SwNativeTool -CommandType Function).ScriptBlock
    $script:RealStatus = (Get-Command -Name Write-SwTuiStatus -CommandType Function).ScriptBlock

    # An unset variable is removed: .NET 8 treats an empty value as unset, newer .NET keeps it as an empty value.
    function script:Set-EnvValue {
        param([string]$Name, $Value)
        if ($null -eq $Value) { [System.Environment]::SetEnvironmentVariable($Name, [NullString]::Value) }
        else { [System.Environment]::SetEnvironmentVariable($Name, [string]$Value) }
    }

    function script:New-Dir([string]$Path) {
        [void][System.IO.Directory]::CreateDirectory($Path)
        return $Path
    }
    function script:Save-Env([string[]]$Names) {
        $saved = @{}
        foreach ($name in $Names) { $saved[$name] = [System.Environment]::GetEnvironmentVariable($name) }
        return $saved
    }
    function script:Restore-Env([hashtable]$Saved) {
        foreach ($name in $Saved.Keys) { Set-EnvValue -Name $name -Value $Saved[$name] }
    }
    function script:Get-Sha256Text([byte[]]$Bytes) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return (([BitConverter]::ToString($sha.ComputeHash($Bytes))) -replace '-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
    }
    function script:Get-Listing([string]$Root) {
        if (-not [System.IO.Directory]::Exists($Root)) { return @() }
        return @([System.IO.Directory]::GetFileSystemEntries($Root, '*', [System.IO.SearchOption]::AllDirectories) | Sort-Object)
    }
    function script:Get-DirectoryFiles([string]$Path) {
        if (-not [System.IO.Directory]::Exists($Path)) { return @() }
        return @([System.IO.Directory]::GetFileSystemEntries($Path) | ForEach-Object { [System.IO.Path]::GetFileName($_) } | Sort-Object)
    }
    function script:Get-StatusText { return (@($script:Status | ForEach-Object { $_.Message }) -join "`n") }

    # Serves a release under the upper-case tag of version 9.9.9 for the given programs.
    function script:Add-Release {
        param([hashtable]$Files, [string]$Tag = 'V9.9.9-windows')
        $base = "$($script:DownloadRoot)/$Tag/"
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($name in $Files.Keys) {
            $lines.Add((Get-Sha256Text $Files[$name]) + "  $name")
            $script:Net[$base + $name] = @{ Bytes = $Files[$name] }
        }
        $script:Net[$base + 'SHA256SUMS.txt'] = @{ Content = (($lines -join "`n") + "`n") }
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
    function script:Get-ChildStderr([string]$Text) {
        if ([string]::IsNullOrEmpty($Text)) { return '' }
        $clean = [regex]::Replace($Text, '(?s)<Obj S="progress".*?</Obj>', '')
        $clean = [regex]::Replace($clean, '<Objs[^>]*>|</Objs>|#< CLIXML', '')
        return $clean.Trim()
    }
    function script:ConvertTo-TestLiteral([string]$Value) { "'" + $Value.Replace("'", "''") + "'" }

    # Common set-up of the Resolve and Build tests: one installation root, its destination, the mocks.
    function script:Initialize-Case {
        param([string]$RootName = 'sweepr')
        $script:HomeDir = New-Dir (Join-Path $TestDrive ('home-' + [guid]::NewGuid().ToString('N')))
        $env:USERPROFILE = $script:HomeDir
        $env:HOME = $script:HomeDir
        $env:SWEEPR_DATA_DIR = (Join-Path $script:HomeDir 'data')
        $parent = New-Dir (Join-Path $TestDrive ('case-' + [guid]::NewGuid().ToString('N')))
        $script:Root = New-Dir ([System.IO.Path]::Combine($parent, $RootName))
        $script:BinDir = New-Dir ([System.IO.Path]::Combine($script:Root, 'bin'))
        $script:Dest = [System.IO.Path]::Combine($script:BinDir, 'status.exe')
        $script:Net = New-Object System.Collections.Hashtable ([System.StringComparer]::Ordinal)
        $script:Calls = New-Object System.Collections.Generic.List[object]
        $script:Native = New-Object System.Collections.Generic.List[object]
        $script:Status = New-Object System.Collections.Generic.List[object]
        $script:GoPath = [System.IO.Path]::Combine($TestDrive, 'fakego', 'go')
        $script:GitPath = $null
        $script:NativeResult = @{ ExitCode = 0; StdOut = ''; StdErr = ''; TimedOut = $false }
        $script:NativeWrites = $true
        $script:NativePartial = $false
        $script:NativeThrows = $false
        $script:NativeContent = 'built'
        $script:Program = [byte[]](1..200)
    }
    function script:Register-Mocks {
        Mock Invoke-WebRequest {
            $script:Calls.Add([pscustomobject]@{ Uri = [string]$Uri; OutFile = $OutFile })
            $entry = $script:Net[[string]$Uri]
            if ($null -eq $entry) { throw [System.Net.WebException]::new('The remote server returned an error: (404) Not Found.') }
            if ($OutFile) {
                [System.IO.File]::WriteAllBytes($OutFile, $entry.Bytes)
                return
            }
            return [pscustomobject]@{ StatusCode = 200; Content = $entry.Content }
        }
        Mock Invoke-RestMethod { throw 'Invoke-RestMethod must not be used' }
        Mock Start-Process { throw 'Start-Process must not be used' }
        Mock Write-SwTuiStatus { $script:Status.Add([pscustomobject]@{ Message = [string]$Message; Color = [string]$Color }) }
        Mock Get-SwToolPath { if ($Name -eq 'go') { return $script:GoPath } else { return $script:GitPath } }
        Mock Invoke-SwNativeTool {
            $list = @($ArgumentList)
            $script:Native.Add([pscustomobject]@{
                    FilePath       = $FilePath
                    ArgumentList   = $list
                    WorkingDirectory = $WorkingDirectory
                    TimeoutSeconds = $TimeoutSeconds
                    Goflags        = $env:GOFLAGS
                    Goos           = $env:GOOS
                    Goarch         = $env:GOARCH
                    Gotoolchain    = $env:GOTOOLCHAIN
                    Goproxy        = $env:GOPROXY
                })
            if ($script:NativeThrows) { throw 'the build tool could not be started' }
            $at = [array]::IndexOf($list, '-o')
            if ($at -ge 0 -and ($script:NativeWrites -or $script:NativePartial)) {
                $content = $script:NativeContent
                if ($script:NativePartial) { $content = 'partial' }
                [System.IO.File]::WriteAllText([string]$list[$at + 1], $content)
            }
            return [pscustomobject]@{
                ExitCode = [int]$script:NativeResult.ExitCode
                StdOut   = [string]$script:NativeResult.StdOut
                StdErr   = [string]$script:NativeResult.StdErr
                TimedOut = [bool]$script:NativeResult.TimedOut
            }
        }
    }
}

Describe 'Resolve-SwTuiBinary' {
    BeforeEach {
        $script:SavedEnv = Save-Env $script:EnvNames
        Initialize-Case
        Register-Mocks
    }
    AfterEach {
        Restore-Env $script:SavedEnv
    }

    Context 'an existing file is final (TB-3)' {
        It 'Returns the path of an existing file in bin and does nothing else' {
            [System.IO.File]::WriteAllText($script:Dest, 'existing')
            Mock Get-SwInstalledVersion { '9.9.9' }
            Mock Restore-SwTuiRelease { 'ok' }
            Mock Build-SwTuiBinary { $true }
            $before = Get-Listing $TestDrive
            $result = @(Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/')
            $result.Count | Should -Be 1
            $result[0] | Should -BeExactly $script:Dest
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            Should -Invoke Get-SwToolPath -Times 0 -Exactly
            Should -Invoke Invoke-SwNativeTool -Times 0 -Exactly
            Should -Invoke Get-SwInstalledVersion -Times 0 -Exactly
            Should -Invoke Restore-SwTuiRelease -Times 0 -Exactly
            Should -Invoke Build-SwTuiBinary -Times 0 -Exactly
            $script:Status.Count | Should -Be 0
            Get-Listing $TestDrive | Should -Be $before
            [System.IO.File]::ReadAllText($script:Dest) | Should -BeExactly 'existing'
        }

        It 'Returns the path of an existing file in the installation root' {
            $file = Join-Path $script:Root 'analyze.exe'
            [System.IO.File]::WriteAllText($file, 'existing')
            $result = @(Resolve-SwTuiBinary -Name 'analyze' -WindowsDir $script:Root -DestinationPath (Join-Path $script:BinDir 'analyze.exe') -SourcePath './cmd/analyze/')
            $result.Count | Should -Be 1
            $result[0] | Should -BeExactly $file
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }

        It 'Does not check an existing file against a checksum' {
            [System.IO.File]::WriteAllText($script:Dest, 'not what any release holds')
            Mock Get-SwFileSha256 { throw 'an existing program must not be hashed' }
            Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' | Should -BeExactly $script:Dest
            Should -Invoke Get-SwFileSha256 -Times 0 -Exactly
        }

        It 'Replaces an existing file from the release when -Refresh is given and the source equals the release' {
            [System.IO.File]::WriteAllText($script:Dest, 'old')
            New-Dir (Join-Path $script:Root '.git') | Out-Null
            Mock Test-SwSourceMatchesRelease { $true }
            Add-Release @{ 'status-windows-x64.exe' = $script:Program }
            $result = @(Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' -Version '9.9.9' -Refresh)
            $result.Count | Should -Be 1
            $result[0] | Should -BeExactly $script:Dest
            [System.IO.File]::ReadAllBytes($script:Dest) | Should -Be $script:Program
            Should -Invoke Invoke-WebRequest -Times 2 -Exactly
        }
    }

    Context 'the inputs (TB-4)' {
        It 'Returns $null with a status line and no network access for the name <Name>' -ForEach @(
            @{ Name = 'foo' }
            @{ Name = '' }
            @{ Name = 'status.exe' }
            @{ Name = '..\status' }
            @{ Name = 'status;calc' }
        ) {
            $before = Get-Listing $TestDrive
            $result = @(Resolve-SwTuiBinary -Name $Name -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' -Version '9.9.9')
            $result.Count | Should -Be 1
            $null -eq $result[0] | Should -BeTrue
            $script:Status.Count | Should -BeGreaterThan 0
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            Should -Invoke Invoke-SwNativeTool -Times 0 -Exactly
            Get-Listing $TestDrive | Should -Be $before
        }

        It 'Returns $null with a status line and no network access when the destination file is called <File>' -ForEach @(
            @{ File = 'other.exe' }
            @{ File = 'analyze.exe' }
            @{ File = 'status' }
            @{ File = 'status.exe.bak' }
            @{ File = 'status.cmd' }
        ) {
            $dest = [System.IO.Path]::Combine($script:BinDir, $File)
            $before = Get-Listing $TestDrive
            $result = @(Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $dest -SourcePath './cmd/status/' -Version '9.9.9')
            $result.Count | Should -Be 1
            $null -eq $result[0] | Should -BeTrue
            $script:Status.Count | Should -BeGreaterThan 0
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            Should -Invoke Invoke-SwNativeTool -Times 0 -Exactly
            Get-Listing $TestDrive | Should -Be $before
        }

        It 'Accepts the destination file name in any letter case' {
            Add-Release @{ 'status-windows-x64.exe' = $script:Program }
            $dest = [System.IO.Path]::Combine($script:BinDir, 'STATUS.EXE')
            Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $dest -SourcePath './cmd/status/' -Version '9.9.9' | Should -BeExactly $dest
        }

        It 'Does not build and returns $null when the source path is <Case>' -ForEach @(
            @{ Case = 'for the other program'; Source = './cmd/analyze/' }
            @{ Case = 'absolute'; Source = '/cmd/status/' }
            @{ Case = 'with a parent step'; Source = './cmd/status/../analyze' }
            @{ Case = 'an option'; Source = '-v' }
            @{ Case = 'followed by an option'; Source = './cmd/status/ -toolexec x' }
        ) {
            $result = @(Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath $Source -Version '9.9.9')
            $result.Count | Should -Be 1
            $null -eq $result[0] | Should -BeTrue
            Should -Invoke Invoke-SwNativeTool -Times 0 -Exactly
        }
    }

    Context 'the version (TB-5)' {
        It 'Reads the version of the installation root when none is given' {
            [System.IO.File]::WriteAllText((Join-Path $script:Root 'VERSION'), "9.9.9`r`n")
            Add-Release @{ 'status-windows-x64.exe' = $script:Program }
            Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' | Should -BeExactly $script:Dest
            $script:Calls[0].Uri | Should -BeExactly "$($script:DownloadRoot)/V9.9.9-windows/SHA256SUMS.txt"
        }

        It 'Asks Get-SwInstalledVersion for the installation root' {
            Mock Get-SwInstalledVersion { '9.9.9' }
            Add-Release @{ 'status-windows-x64.exe' = $script:Program }
            $null = Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/'
            Should -Invoke Get-SwInstalledVersion -Times 1 -Exactly -ParameterFilter { $RootDir -eq $script:Root }
        }

        It 'Prefers the given version over the one in the installation root' {
            [System.IO.File]::WriteAllText((Join-Path $script:Root 'VERSION'), '1.1.1')
            Add-Release @{ 'status-windows-x64.exe' = $script:Program }
            Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' -Version '9.9.9' | Should -BeExactly $script:Dest
        }

        It 'Counts an unreadable version as unknown: no download attempt, then the build' {
            Mock Get-SwInstalledVersion { throw 'the version file cannot be read' }
            $result = @(Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/')
            $result.Count | Should -Be 1
            $result[0] | Should -BeExactly $script:Dest
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            Should -Invoke Invoke-SwNativeTool -Times 1 -Exactly
        }

        It 'Makes no request for the unusable version <Version> and goes on to the build' -ForEach @(
            @{ Version = '0.2.0/../x' }
            @{ Version = 'a b' }
            @{ Version = '1?x' }
        ) {
            $result = @(Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' -Version $Version)
            $result[0] | Should -BeExactly $script:Dest
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            Should -Invoke Invoke-SwNativeTool -Times 1 -Exactly
        }
    }

    Context 'the decision between download and build (TB-6)' {
        BeforeEach {
            Mock Restore-SwTuiRelease { return $script:RestoreResult }
            $script:RestoreResult = 'unavailable'
        }

        It 'Downloads when there is no Git folder and no -Refresh, and returns the destination' {
            $script:RestoreResult = 'ok'
            $result = @(Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' -Version '9.9.9')
            $result.Count | Should -Be 1
            $result[0] | Should -BeExactly $script:Dest
            Should -Invoke Restore-SwTuiRelease -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'status' -and $WindowsDir -eq $script:Root -and $DestinationPath -eq $script:Dest -and $Version -eq '9.9.9'
            }
            Should -Invoke Invoke-SwNativeTool -Times 0 -Exactly
        }

        It 'Builds with Go when the download is unavailable' {
            $result = @(Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' -Version '9.9.9')
            $result.Count | Should -Be 1
            $result[0] | Should -BeExactly $script:Dest
            Should -Invoke Invoke-SwNativeTool -Times 1 -Exactly
            [System.IO.File]::ReadAllText($script:Dest) | Should -BeExactly 'built'
        }

        It 'Returns $null with a status line and starts no build when the download is unavailable and Go is missing' {
            $script:GoPath = $null
            $result = @(Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' -Version '9.9.9')
            $result.Count | Should -Be 1
            $null -eq $result[0] | Should -BeTrue
            $script:Status.Count | Should -BeGreaterThan 0
            Should -Invoke Invoke-SwNativeTool -Times 0 -Exactly
            [System.IO.File]::Exists($script:Dest) | Should -BeFalse
        }

        It 'Never downloads for a source install whose source differs from the release: <Kind>' -ForEach @(
            @{ Kind = 'Git folder' }
            @{ Kind = 'Git file' }
        ) {
            if ($Kind -eq 'Git folder') { New-Dir (Join-Path $script:Root '.git') | Out-Null }
            else { [System.IO.File]::WriteAllText((Join-Path $script:Root '.git'), 'gitdir: ../elsewhere') }
            Mock Test-SwSourceMatchesRelease { $false }
            $result = @(Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' -Version '9.9.9')
            $result[0] | Should -BeExactly $script:Dest
            Should -Invoke Restore-SwTuiRelease -Times 0 -Exactly
            Should -Invoke Invoke-SwNativeTool -Times 1 -Exactly
        }

        It 'Returns $null for a source install with changed source and no Go, and never downloads' {
            New-Dir (Join-Path $script:Root '.git') | Out-Null
            Mock Test-SwSourceMatchesRelease { $false }
            $script:GoPath = $null
            $result = @(Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' -Version '9.9.9')
            $null -eq $result[0] | Should -BeTrue
            Should -Invoke Restore-SwTuiRelease -Times 0 -Exactly
            Should -Invoke Invoke-SwNativeTool -Times 0 -Exactly
        }

        It 'Downloads for a source install whose source equals the release' {
            New-Dir (Join-Path $script:Root '.git') | Out-Null
            Mock Test-SwSourceMatchesRelease { $true }
            $script:RestoreResult = 'ok'
            Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' -Version '9.9.9' | Should -BeExactly $script:Dest
            Should -Invoke Restore-SwTuiRelease -Times 1 -Exactly
            Should -Invoke Invoke-SwNativeTool -Times 0 -Exactly
        }

        It 'Asks Test-SwSourceMatchesRelease about this installation, program and version' {
            New-Dir (Join-Path $script:Root '.git') | Out-Null
            Mock Test-SwSourceMatchesRelease { $true }
            $script:RestoreResult = 'ok'
            $null = Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' -Version '9.9.9'
            Should -Invoke Test-SwSourceMatchesRelease -Times 1 -Exactly -ParameterFilter {
                $WindowsDir -eq $script:Root -and $Name -eq 'status' -and $Version -eq '9.9.9'
            }
        }

        It 'Downloads with -Refresh for a source install whose source equals the release, instead of building' {
            New-Dir (Join-Path $script:Root '.git') | Out-Null
            Mock Test-SwSourceMatchesRelease { $true }
            $script:RestoreResult = 'ok'
            Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' -Version '9.9.9' -Refresh | Should -BeExactly $script:Dest
            Should -Invoke Restore-SwTuiRelease -Times 1 -Exactly
            Should -Invoke Invoke-SwNativeTool -Times 0 -Exactly
        }

        It 'Builds with -Refresh for a source install whose source differs from the release' {
            New-Dir (Join-Path $script:Root '.git') | Out-Null
            Mock Test-SwSourceMatchesRelease { $false }
            Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' -Version '9.9.9' -Refresh | Should -BeExactly $script:Dest
            Should -Invoke Restore-SwTuiRelease -Times 0 -Exactly
            Should -Invoke Invoke-SwNativeTool -Times 1 -Exactly
        }

        It 'Builds with -Refresh when there is no Git folder, and does not download' {
            $result = @(Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' -Version '9.9.9' -Refresh)
            $result[0] | Should -BeExactly $script:Dest
            Should -Invoke Restore-SwTuiRelease -Times 0 -Exactly
            Should -Invoke Invoke-SwNativeTool -Times 1 -Exactly
        }

        It 'Returns $null when the build fails, and leaves no program behind' {
            $script:NativeResult = @{ ExitCode = 1; StdOut = ''; StdErr = 'compile error'; TimedOut = $false }
            $result = @(Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' -Version '9.9.9')
            $result.Count | Should -Be 1
            $null -eq $result[0] | Should -BeTrue
            [System.IO.File]::Exists($script:Dest) | Should -BeFalse
            Get-DirectoryFiles $script:BinDir | Should -BeNullOrEmpty
        }
    }

    Context 'a checksum mismatch (TB-10, S5)' {
        BeforeEach {
            Mock Restore-SwTuiRelease { 'mismatch' }
        }

        It 'Returns $null, does not build and reports in red with the name, sw update and the issues address' {
            $result = @(Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' -Version '9.9.9')
            $result.Count | Should -Be 1
            $null -eq $result[0] | Should -BeTrue
            Should -Invoke Invoke-SwNativeTool -Times 0 -Exactly
            @($script:Status | Where-Object { $_.Color -eq 'Red' }).Count | Should -BeGreaterThan 0
            $text = Get-StatusText
            $text | Should -Match 'status'
            $text | Should -Match 'sw update'
            $text | Should -Match ([regex]::Escape('https://github.com/brummilab/sweepr/issues'))
        }

        It 'Does not build for a source install either' {
            New-Dir (Join-Path $script:Root '.git') | Out-Null
            Mock Test-SwSourceMatchesRelease { $true }
            $null -eq (Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' -Version '9.9.9') | Should -BeTrue
            Should -Invoke Invoke-SwNativeTool -Times 0 -Exactly
        }

        It 'Leaves no program at the destination' {
            $null = Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' -Version '9.9.9'
            [System.IO.File]::Exists($script:Dest) | Should -BeFalse
        }
    }

    Context 'an exception while restoring (TB-11)' {
        BeforeEach {
            Mock Restore-SwTuiRelease { throw 'unexpected restore failure' }
        }

        It 'Reports it in yellow with the name and the cause, and builds when Go is found' {
            $result = @(Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' -Version '9.9.9')
            $result.Count | Should -Be 1
            $result[0] | Should -BeExactly $script:Dest
            $failure = @($script:Status | Where-Object { $_.Message -match 'unexpected restore failure' })
            $failure.Count | Should -BeGreaterThan 0
            $failure[0].Color | Should -Be 'Yellow'
            $failure[0].Message | Should -Match 'status'
            Should -Invoke Invoke-SwNativeTool -Times 1 -Exactly
        }

        It 'Returns $null when Go is missing' {
            $script:GoPath = $null
            $result = @(Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' -Version '9.9.9')
            $result.Count | Should -Be 1
            $null -eq $result[0] | Should -BeTrue
        }
    }

    Context 'the return value and where it writes (TB-16, S4)' {
        It 'Returns exactly one string after a download, with nothing else in the pipeline' {
            Add-Release @{ 'status-windows-x64.exe' = $script:Program }
            $result = @(Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' -Version '9.9.9')
            $result.Count | Should -Be 1
            $result[0] | Should -BeOfType [string]
            $result[0] | Should -BeExactly $script:Dest
        }

        It 'Returns exactly one string after a build, with nothing else in the pipeline' {
            $result = @(Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' -Version '9.9.9')
            $result.Count | Should -Be 1
            $result[0] | Should -BeOfType [string]
        }

        It 'Returns exactly one $null when nothing can be provided, not $false and not an array' {
            $script:GoPath = $null
            $result = @(Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' -Version '9.9.9')
            $result.Count | Should -Be 1
            $null -eq $result[0] | Should -BeTrue
            $result[0] -is [bool] | Should -BeFalse
        }

        It 'Does not throw for the expected failures: <Case>' -ForEach @(
            @{ Case = 'no network, no Go'; Go = $false; Exit = 0 }
            @{ Case = 'a failing build'; Go = $true; Exit = 2 }
        ) {
            if (-not $Go) { $script:GoPath = $null }
            $script:NativeResult = @{ ExitCode = $Exit; StdOut = ''; StdErr = 'failed'; TimedOut = $false }
            if ($Exit -ne 0) { $script:NativeWrites = $false }
            { Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' -Version '9.9.9' } | Should -Not -Throw
        }

        It 'Returns $null and names the folder when the destination folder cannot be written, for the download and the build' -ForEach @(
            @{ Way = 'download' }
            @{ Way = 'build' }
        ) {
            [System.IO.Directory]::Delete($script:BinDir)
            [System.IO.File]::WriteAllText($script:BinDir, 'a file where the folder should be')
            if ($Way -eq 'download') { Add-Release @{ 'status-windows-x64.exe' = $script:Program } }
            $result = @()
            $thrown = $null
            try { $result = @(Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' -Version '9.9.9') }
            catch { $thrown = $_ }
            $thrown | Should -BeNullOrEmpty
            $result.Count | Should -Be 1
            $null -eq $result[0] | Should -BeTrue
            Get-StatusText | Should -Match ([regex]::Escape($script:BinDir))
            [System.IO.File]::ReadAllText($script:BinDir) | Should -BeExactly 'a file where the folder should be'
        }

        It 'Writes only into the folder of the destination: not into the profile, the data folder or elsewhere in the test drive' -ForEach @(
            @{ Way = 'download' }
            @{ Way = 'build' }
        ) {
            if ($Way -eq 'download') { Add-Release @{ 'status-windows-x64.exe' = $script:Program } }
            $tempBefore = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Force -Filter '*sweepr*' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
            $outside = @(Get-Listing $TestDrive | Where-Object { -not $_.StartsWith($script:BinDir) })
            $null = Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' -Version '9.9.9'
            @(Get-Listing $TestDrive | Where-Object { -not $_.StartsWith($script:BinDir) }) | Should -Be $outside
            @(Get-Listing $script:HomeDir).Count | Should -Be 0
            $tempAfter = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Force -Filter '*sweepr*' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
            $tempAfter | Should -Be $tempBefore
            Get-DirectoryFiles $script:BinDir | Should -Be @('status.exe')
        }

        It 'Treats brackets, quotes and blanks in the installation root literally, for the download and the build' -ForEach @(
            @{ Way = 'download' }
            @{ Way = 'build' }
        ) {
            Initialize-Case -RootName "Tools [x64] it's"
            if ($Way -eq 'download') { Add-Release @{ 'status-windows-x64.exe' = $script:Program } }
            $result = @(Resolve-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' -Version '9.9.9')
            $result.Count | Should -Be 1
            $result[0] | Should -BeExactly $script:Dest
            [System.IO.File]::Exists($script:Dest) | Should -BeTrue
            Get-DirectoryFiles $script:BinDir | Should -Be @('status.exe')
        }
    }

    Context 'the output channel (TB-15)' {
        It 'Keeps standard output clean: the progress and failure lines go to standard error' {
            $root = New-Dir (Join-Path $TestDrive ('child-' + [guid]::NewGuid().ToString('N')))
            $bin = New-Dir (Join-Path $root 'bin')
            $dest = Join-Path $bin 'status.exe'
            $bytes = [byte[]](1..200)
            $hash = Get-Sha256Text $bytes
            $tui = ConvertTo-TestLiteral $script:TuiFile
            $run = Invoke-ChildPowerShell -RemoveEnvironment @('SWEEPR_DATA_DIR') -Environment @{ USERPROFILE = $script:HomeDir; HOME = $script:HomeDir } -Script @"
`$ErrorActionPreference = 'Stop'
. $tui
function Invoke-WebRequest {
    param([uri]`$Uri, [string]`$OutFile, [switch]`$UseBasicParsing, [string]`$UserAgent, [int]`$TimeoutSec)
    if ([string]::IsNullOrEmpty(`$OutFile)) { return [pscustomobject]@{ Content = '$hash  status-windows-x64.exe' + "`n" } }
    [System.IO.File]::WriteAllBytes(`$OutFile, [byte[]](1..200))
}
function Get-SwToolPath { return `$null }
`$first = Resolve-SwTuiBinary -Name status -WindowsDir $(ConvertTo-TestLiteral $root) -DestinationPath $(ConvertTo-TestLiteral $dest) -SourcePath './cmd/status/' -Version '9.9.9'
Remove-Item -LiteralPath $(ConvertTo-TestLiteral $dest) -Force
function Invoke-WebRequest { throw 'offline' }
`$second = Resolve-SwTuiBinary -Name status -WindowsDir $(ConvertTo-TestLiteral $root) -DestinationPath $(ConvertTo-TestLiteral $dest) -SourcePath './cmd/status/' -Version '9.9.9'
[Console]::Out.WriteLine('FIRST=[' + `$first + ']')
[Console]::Out.WriteLine('SECOND=[' + `$second + ']' + (`$null -eq `$second))
"@
            $run.ExitCode | Should -Be 0
            $stdout = @($run.Out -split "`r?`n" | Where-Object { $_ -ne '' })
            $stdout | Should -Be @("FIRST=[$dest]", 'SECOND=[]True')
            $stderr = Get-ChildStderr $run.Err
            $stderr | Should -Match 'status'
            @($stderr -split "`r?`n" | Where-Object { $_.Trim() -ne '' }).Count | Should -BeGreaterThan 1
        }
    }
}

Describe 'Build-SwTuiBinary (TB-14, S7, S8)' {
    BeforeEach {
        $script:SavedEnv = Save-Env $script:EnvNames
        Initialize-Case -RootName "Tools [x64] it's"
        Register-Mocks
    }
    AfterEach {
        Restore-Env $script:SavedEnv
    }

    Context 'the call of go' {
        It 'Starts go by its absolute path with an argument list, in the installation root, with a limit of 600 seconds' {
            Build-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' | Should -BeTrue
            $script:Native.Count | Should -Be 1
            $call = $script:Native[0]
            $call.FilePath | Should -BeExactly $script:GoPath
            $call.WorkingDirectory | Should -BeExactly $script:Root
            $call.TimeoutSeconds | Should -Be 600
            $call.ArgumentList.Count | Should -Be 4
            $call.ArgumentList[0] | Should -BeExactly 'build'
            $call.ArgumentList[1] | Should -BeExactly '-o'
            $call.ArgumentList[3] | Should -BeExactly './cmd/status/'
        }

        It 'Asks Get-SwToolPath for go in the installation root' {
            $null = Build-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/'
            Should -Invoke Get-SwToolPath -Times 1 -Exactly -ParameterFilter { $Name -eq 'go' -and $RootDir -eq $script:Root }
        }

        It 'Builds into a uniquely named .sweepr-<name>-<id>.exe file next to the destination' {
            $null = Build-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/'
            $output = [string]$script:Native[0].ArgumentList[2]
            [System.IO.Path]::GetDirectoryName($output) | Should -BeExactly $script:BinDir
            [System.IO.Path]::GetFileName($output) | Should -Match '(?i)^\.sweepr-status-[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}\.exe$'
        }

        It 'Uses a different output name in every run' {
            $null = Build-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/'
            $null = Build-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/'
            [string]$script:Native[0].ArgumentList[2] | Should -Not -BeExactly ([string]$script:Native[1].ArgumentList[2])
        }

        It 'Accepts the source path with and without the closing slash' -ForEach @(
            @{ Source = './cmd/status/' }
            @{ Source = './cmd/status' }
        ) {
            Build-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath $Source | Should -BeTrue
            $script:Native[0].ArgumentList[3] | Should -BeExactly $Source
        }

        It 'Builds the other program for the name analyze' {
            $dest = [System.IO.Path]::Combine($script:BinDir, 'analyze.exe')
            Build-SwTuiBinary -Name 'analyze' -WindowsDir $script:Root -DestinationPath $dest -SourcePath './cmd/analyze/' | Should -BeTrue
            $script:Native[0].ArgumentList[3] | Should -BeExactly './cmd/analyze/'
            [System.IO.File]::Exists($dest) | Should -BeTrue
        }

        It 'Does not use Start-Process' {
            $null = Build-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/'
            Should -Invoke Start-Process -Times 0 -Exactly
        }

        It 'Does not change the Go environment of the user, set or not set' -ForEach @(
            @{ Set = $true }
            @{ Set = $false }
        ) {
            foreach ($name in 'GOFLAGS', 'GOOS', 'GOARCH', 'GOTOOLCHAIN', 'GOPROXY') {
                if ($Set) { Set-EnvValue -Name $name -Value "user-$name" }
                else { Set-EnvValue -Name $name -Value $null }
            }
            $null = Build-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/'
            $seen = @{ GOFLAGS = $script:Native[0].Goflags; GOOS = $script:Native[0].Goos; GOARCH = $script:Native[0].Goarch; GOTOOLCHAIN = $script:Native[0].Gotoolchain; GOPROXY = $script:Native[0].Goproxy }
            foreach ($name in 'GOFLAGS', 'GOOS', 'GOARCH', 'GOTOOLCHAIN', 'GOPROXY') {
                $expected = $null
                if ($Set) { $expected = "user-$name" }
                $seen[$name] | Should -BeExactly $expected -Because "$name while go runs"
                [System.Environment]::GetEnvironmentVariable($name) | Should -BeExactly $expected -Because "$name afterwards"
            }
        }
    }

    Context 'the result' {
        It 'Puts the built file at the destination and leaves only the destination in the folder' {
            $result = @(Build-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/')
            $result.Count | Should -Be 1
            $result[0] | Should -BeTrue
            $result[0] | Should -BeOfType [bool]
            [System.IO.File]::ReadAllText($script:Dest) | Should -BeExactly 'built'
            Get-DirectoryFiles $script:BinDir | Should -Be @('status.exe')
        }

        It 'Replaces an existing program on success' {
            [System.IO.File]::WriteAllText($script:Dest, 'old')
            Build-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' | Should -BeTrue
            [System.IO.File]::ReadAllText($script:Dest) | Should -BeExactly 'built'
            Get-DirectoryFiles $script:BinDir | Should -Be @('status.exe')
        }

        It 'Returns false, keeps the old program and removes the partial output when go exits with an error' {
            [System.IO.File]::WriteAllText($script:Dest, 'old')
            $script:NativePartial = $true
            $script:NativeResult = @{ ExitCode = 1; StdOut = 'some output'; StdErr = 'boom'; TimedOut = $false }
            $result = @(Build-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/')
            $result.Count | Should -Be 1
            $result[0] | Should -BeFalse
            $result[0] | Should -BeOfType [bool]
            [System.IO.File]::ReadAllText($script:Dest) | Should -BeExactly 'old'
            Get-DirectoryFiles $script:BinDir | Should -Be @('status.exe')
        }

        It 'Reports a failed build in red with the name, the exit code and the output of go' {
            $script:NativeResult = @{ ExitCode = 1; StdOut = 'some output'; StdErr = 'boom'; TimedOut = $false }
            $null = Build-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/'
            @($script:Status | Where-Object { $_.Color -eq 'Red' }).Count | Should -BeGreaterThan 0
            $text = Get-StatusText
            $text | Should -Match 'status'
            $text | Should -Match '\b1\b'
            $text | Should -Match 'boom'
        }

        It 'Returns false, removes the leftovers and reports the time limit when go does not finish' {
            $script:NativePartial = $true
            $script:NativeResult = @{ ExitCode = -1; StdOut = ''; StdErr = ''; TimedOut = $true }
            Build-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' | Should -BeFalse
            Get-StatusText | Should -Match '(?i)time'
            [System.IO.File]::Exists($script:Dest) | Should -BeFalse
            Get-DirectoryFiles $script:BinDir | Should -BeNullOrEmpty
        }

        It 'Returns false, removes the leftovers and keeps the old program when go cannot be started' {
            [System.IO.File]::WriteAllText($script:Dest, 'old')
            $script:NativeThrows = $true
            Build-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' | Should -BeFalse
            [System.IO.File]::ReadAllText($script:Dest) | Should -BeExactly 'old'
            Get-DirectoryFiles $script:BinDir | Should -Be @('status.exe')
            $script:Status.Count | Should -BeGreaterThan 0
        }

        It 'Keeps every other file in the destination folder' {
            $neighbours = @('readme.txt', 'analyze.exe', '.sweepr-status-0123456789abcdef0123456789abcdef.exe')
            foreach ($neighbour in $neighbours) { [System.IO.File]::WriteAllText((Join-Path $script:BinDir $neighbour), 'keep') }
            $script:NativeResult = @{ ExitCode = 1; StdOut = ''; StdErr = 'boom'; TimedOut = $false }
            $script:NativePartial = $true
            $null = Build-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/'
            Get-DirectoryFiles $script:BinDir | Should -Be @($neighbours | Sort-Object)
        }

        It 'Replaces control characters in the output of go before it is shown' {
            Mock Test-SwTuiOutputRedirected { $true }
            Mock Write-SwTuiStatus { & $script:RealStatus @PesterBoundParameters }
            $original = [Console]::Error
            $writer = New-Object System.IO.StringWriter
            [Console]::SetError($writer)
            try {
                $esc = [string][char]27
                $script:NativeResult = @{ ExitCode = 1; StdOut = ''; StdErr = ('line1' + $esc + '[31m red' + [char]0 + [char]7 + "`nboom"); TimedOut = $false }
                $null = Build-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/'
            }
            finally { [Console]::SetError($original) }
            $text = $writer.ToString()
            $text | Should -Match 'boom'
            foreach ($code in 0, 7, 27) { $text.Contains([string][char]$code) | Should -BeFalse -Because "character $code" }
        }
    }

    Context 'the requirements' {
        It 'Returns false without a process start for the name <Name>' -ForEach @(
            @{ Name = 'foo' }
            @{ Name = '' }
            @{ Name = 'status.exe' }
        ) {
            Build-SwTuiBinary -Name $Name -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' | Should -BeFalse
            Should -Invoke Invoke-SwNativeTool -Times 0 -Exactly
        }

        It 'Returns false without a process start for the source path <Source>' -ForEach @(
            @{ Source = './cmd/status/ -toolexec x' }
            @{ Source = '-v' }
            @{ Source = '../x' }
            @{ Source = './cmd/status/../analyze' }
            @{ Source = './cmd/analyze/' }
            @{ Source = './cmd/status/..' }
            @{ Source = 'cmd/status/' }
            @{ Source = '/cmd/status/' }
            @{ Source = 'C:\cmd\status\' }
            @{ Source = './cmd/status/;calc' }
            @{ Source = './cmd/status/&calc' }
            @{ Source = './cmd/status/|calc' }
            @{ Source = './cmd/status/"x' }
            @{ Source = './cmd/status/`x' }
            @{ Source = "./cmd/status/`nx" }
            @{ Source = "./cmd/status/`tx" }
            @{ Source = '' }
        ) {
            Build-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath $Source | Should -BeFalse
            Should -Invoke Invoke-SwNativeTool -Times 0 -Exactly
        }

        It 'Returns false with a status line and no process start when go is not found' {
            $script:GoPath = $null
            Build-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/' | Should -BeFalse
            Should -Invoke Invoke-SwNativeTool -Times 0 -Exactly
            $script:Status.Count | Should -BeGreaterThan 0
        }

        It 'Announces the build with a status line that names the program' {
            $null = Build-SwTuiBinary -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -SourcePath './cmd/status/'
            @($script:Status | Where-Object { $_.Message -match 'status' }).Count | Should -BeGreaterThan 0
        }
    }
}

Describe 'Test-SwSourceMatchesRelease (TB-12, S7)' {
    BeforeAll {
        $script:GitHome = New-Dir (Join-Path $TestDrive 'git-home')
        $script:EmptyConfig = Join-Path $script:GitHome 'empty-gitconfig'
        [System.IO.File]::WriteAllText($script:EmptyConfig, '')

        function script:Invoke-Git([string]$Dir, [string[]]$Arguments) {
            $output = & git -C $Dir -c user.name=Example -c user.email=example@example.invalid -c commit.gpgsign=false -c core.autocrlf=false @Arguments 2>&1
            if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $output" }
            return , @($output | ForEach-Object { [string]$_ })
        }
        function script:Write-RepoFile([string]$Root, [string]$Relative, [string]$Text) {
            $path = [System.IO.Path]::Combine($Root, $Relative.Replace('/', [string][System.IO.Path]::DirectorySeparatorChar))
            [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($path))
            [System.IO.File]::WriteAllText($path, $Text, $script:Utf8)
        }
        # A repository with a commit of the Go sources and the tag V9.9.9-windows on that commit.
        function script:New-GitFixture([string]$Root) {
            [void][System.IO.Directory]::CreateDirectory($Root)
            Invoke-Git $Root @('init', '-q') | Out-Null
            Write-RepoFile $Root 'cmd/analyze/main.go' "package main`n"
            Write-RepoFile $Root 'cmd/status/main.go' "package main`n"
            Write-RepoFile $Root 'go.mod' "module example`n"
            Write-RepoFile $Root 'go.sum' "`n"
            Write-RepoFile $Root 'README.md' "readme`n"
            Invoke-Git $Root @('add', '-A') | Out-Null
            $tree = (Invoke-Git $Root @('write-tree'))[0].Trim()
            $commit = (Invoke-Git $Root @('commit-tree', $tree, '-m', 'sources'))[0].Trim()
            Invoke-Git $Root @('update-ref', 'HEAD', $commit) | Out-Null
            Invoke-Git $Root @('update-ref', 'refs/tags/V9.9.9-windows', $commit) | Out-Null
            return $commit
        }
        function script:Get-RepoState([string]$Root) {
            return ((Invoke-Git $Root @('for-each-ref')) + (Invoke-Git $Root @('rev-parse', 'HEAD')) + (Invoke-Git $Root @('status', '--porcelain'))) -join "`n"
        }
    }

    BeforeEach {
        $script:SavedEnv = Save-Env $script:EnvNames
        foreach ($name in $script:GitNames) { Set-EnvValue -Name $name -Value $null }
        $env:GIT_CONFIG_GLOBAL = $script:EmptyConfig
        $env:GIT_CONFIG_NOSYSTEM = '1'
        $env:HOME = $script:GitHome
        $script:Native = New-Object System.Collections.Generic.List[object]
        $script:Spy = New-Object System.Collections.Generic.List[object]
    }
    AfterEach {
        Restore-Env $script:SavedEnv
    }

    Context 'with a real repository' -Skip:(-not $script:HasGit) {
        BeforeEach {
            $script:Fixture = [System.IO.Path]::Combine($TestDrive, ('git-' + [guid]::NewGuid().ToString('N')), "Tools [x64] it's")
            $script:Commit = New-GitFixture $script:Fixture
            Mock Invoke-SwNativeTool {
                $script:Spy.Add([pscustomobject]@{ FilePath = $FilePath; ArgumentList = $ArgumentList; WorkingDirectory = $WorkingDirectory; TimeoutSeconds = $TimeoutSeconds })
                & $script:RealNative @PesterBoundParameters
            }
        }

        It 'Returns true when cmd/<name>, go.mod and go.sum equal the tagged release' {
            Test-SwSourceMatchesRelease -WindowsDir $script:Fixture -Name 'analyze' -Version '9.9.9' | Should -BeTrue
            Test-SwSourceMatchesRelease -WindowsDir $script:Fixture -Name 'status' -Version '9.9.9' | Should -BeTrue
        }

        It 'Returns a boolean and nothing else' {
            $result = @(Test-SwSourceMatchesRelease -WindowsDir $script:Fixture -Name 'analyze' -Version '9.9.9')
            $result.Count | Should -Be 1
            $result[0] | Should -BeOfType [bool]
        }

        It 'Ignores a changed or new file elsewhere in the tree' {
            Write-RepoFile $script:Fixture 'README.md' "changed readme`n"
            Write-RepoFile $script:Fixture 'NOTES.txt' "new file`n"
            Test-SwSourceMatchesRelease -WindowsDir $script:Fixture -Name 'analyze' -Version '9.9.9' | Should -BeTrue
        }

        It 'Finds the release by the lower-case tag too' {
            Invoke-Git $script:Fixture @('update-ref', 'refs/tags/v9.9.9-windows', $script:Commit) | Out-Null
            Invoke-Git $script:Fixture @('update-ref', '-d', 'refs/tags/V9.9.9-windows') | Out-Null
            Test-SwSourceMatchesRelease -WindowsDir $script:Fixture -Name 'analyze' -Version '9.9.9' | Should -BeTrue
        }

        It 'Returns false when the version has no tag' {
            Test-SwSourceMatchesRelease -WindowsDir $script:Fixture -Name 'analyze' -Version '9.9.8' | Should -BeFalse
        }

        It 'Returns false for an unusable version' -ForEach @(
            @{ Version = '' }
            @{ Version = '9.9.9/../x' }
            @{ Version = '9.9.9 -x' }
        ) {
            Test-SwSourceMatchesRelease -WindowsDir $script:Fixture -Name 'analyze' -Version $Version | Should -BeFalse
        }

        It 'Returns false when <Case>' -ForEach @(
            @{ Case = 'the program source has an uncommitted change'; Change = { Write-RepoFile $script:Fixture 'cmd/analyze/main.go' "package main // changed`n" } }
            @{ Case = 'the program source has a staged change'; Change = {
                    Write-RepoFile $script:Fixture 'cmd/analyze/main.go' "package main // staged`n"
                    Invoke-Git $script:Fixture @('add', 'cmd/analyze/main.go') | Out-Null } }
            @{ Case = 'a Go file was added to the program folder'; Change = { Write-RepoFile $script:Fixture 'cmd/analyze/extra.go' "package main`n" } }
            @{ Case = 'a program source file was deleted'; Change = { [System.IO.File]::Delete([System.IO.Path]::Combine($script:Fixture, 'cmd', 'analyze', 'main.go')) } }
            @{ Case = 'go.mod changed'; Change = { Write-RepoFile $script:Fixture 'go.mod' "module changed`n" } }
            @{ Case = 'go.sum changed'; Change = { Write-RepoFile $script:Fixture 'go.sum' "changed sum`n" } }
            @{ Case = 'a new commit changed the program after the tag'; Change = {
                    Write-RepoFile $script:Fixture 'cmd/analyze/main.go' "package main // later`n"
                    Invoke-Git $script:Fixture @('add', '-A') | Out-Null
                    $tree = (Invoke-Git $script:Fixture @('write-tree'))[0].Trim()
                    $next = (Invoke-Git $script:Fixture @('commit-tree', $tree, '-p', $script:Commit, '-m', 'later'))[0].Trim()
                    Invoke-Git $script:Fixture @('update-ref', 'HEAD', $next) | Out-Null } }
        ) {
            & $Change
            Test-SwSourceMatchesRelease -WindowsDir $script:Fixture -Name 'analyze' -Version '9.9.9' | Should -BeFalse
        }

        It 'Returns false when an ignored file was added to the program folder' {
            Write-RepoFile $script:Fixture '.gitignore' "extra.go`n"
            Write-RepoFile $script:Fixture 'cmd/analyze/extra.go' "package main`n"
            Invoke-Git $script:Fixture @('status', '--porcelain', '--ignored=matching', '--', 'cmd/analyze') | Should -Match 'extra\.go'
            Test-SwSourceMatchesRelease -WindowsDir $script:Fixture -Name 'analyze' -Version '9.9.9' | Should -BeFalse
        }

        It 'Looks only at the folder of the asked program' {
            Write-RepoFile $script:Fixture 'cmd/status/main.go' "package main // changed`n"
            Test-SwSourceMatchesRelease -WindowsDir $script:Fixture -Name 'analyze' -Version '9.9.9' | Should -BeTrue
            Test-SwSourceMatchesRelease -WindowsDir $script:Fixture -Name 'status' -Version '9.9.9' | Should -BeFalse
        }

        It 'Returns false when the environment variable <Name> is set' -ForEach @(
            @{ Name = 'GIT_DIR' }
            @{ Name = 'GIT_WORK_TREE' }
            @{ Name = 'GIT_COMMON_DIR' }
            @{ Name = 'GIT_INDEX_FILE' }
            @{ Name = 'GIT_OBJECT_DIRECTORY' }
            @{ Name = 'GIT_ALTERNATE_OBJECT_DIRECTORIES' }
            @{ Name = 'GIT_CONFIG' }
            @{ Name = 'GIT_CONFIG_COUNT' }
            @{ Name = 'GIT_CONFIG_PARAMETERS' }
        ) {
            # Values that would not change what git does, so only the check of the variable can say false.
            $values = @{
                GIT_DIR                          = [System.IO.Path]::Combine($script:Fixture, '.git')
                GIT_WORK_TREE                    = $script:Fixture
                GIT_COMMON_DIR                   = [System.IO.Path]::Combine($script:Fixture, '.git')
                GIT_INDEX_FILE                   = [System.IO.Path]::Combine($script:Fixture, '.git', 'index')
                GIT_OBJECT_DIRECTORY             = [System.IO.Path]::Combine($script:Fixture, '.git', 'objects')
                GIT_ALTERNATE_OBJECT_DIRECTORIES = [System.IO.Path]::Combine($script:Fixture, '.git', 'objects')
                GIT_CONFIG                       = $script:EmptyConfig
                GIT_CONFIG_COUNT                 = '0'
                GIT_CONFIG_PARAMETERS            = ''
            }
            $value = $values[$Name]
            if ($Name -eq 'GIT_CONFIG_PARAMETERS') { $value = "'core.quotepath'='true'" }
            Set-EnvValue -Name $Name -Value $value
            Test-SwSourceMatchesRelease -WindowsDir $script:Fixture -Name 'analyze' -Version '9.9.9' | Should -BeFalse
        }

        It 'Starts git only through Invoke-SwNativeTool, by the path from Get-SwToolPath, with an argument array' {
            $null = Test-SwSourceMatchesRelease -WindowsDir $script:Fixture -Name 'analyze' -Version '9.9.9'
            $script:Spy.Count | Should -BeGreaterThan 0
            $git = Get-SwToolPath -Name 'git' -RootDir $script:Fixture
            foreach ($call in $script:Spy) {
                $call.FilePath | Should -BeExactly $git
                ($call.ArgumentList -is [array]) | Should -BeTrue
                $call.ArgumentList.Count | Should -BeGreaterThan 1
            }
        }

        It 'Runs git with -C for the installation root, core.fsmonitor=false and a limit of 30 seconds' {
            $null = Test-SwSourceMatchesRelease -WindowsDir $script:Fixture -Name 'analyze' -Version '9.9.9'
            foreach ($call in $script:Spy) {
                $arguments = @($call.ArgumentList)
                $at = [array]::IndexOf($arguments, '-C')
                $at | Should -BeGreaterOrEqual 0
                $arguments[$at + 1] | Should -BeExactly $script:Fixture
                $config = [array]::IndexOf($arguments, '-c')
                $config | Should -BeGreaterOrEqual 0
                $arguments | Should -Contain 'core.fsmonitor=false'
                $call.TimeoutSeconds | Should -Be 30
            }
        }

        It 'Compares without external diff drivers and text conversion filters' {
            $null = Test-SwSourceMatchesRelease -WindowsDir $script:Fixture -Name 'analyze' -Version '9.9.9'
            $comparing = @($script:Spy | Where-Object { @($_.ArgumentList) -contains '--no-ext-diff' })
            $comparing.Count | Should -BeGreaterThan 0
            foreach ($call in $comparing) { @($call.ArgumentList) | Should -Contain '--no-textconv' }
        }

        It 'Only reads: the repository is the same afterwards' {
            $before = Get-RepoState $script:Fixture
            $null = Test-SwSourceMatchesRelease -WindowsDir $script:Fixture -Name 'analyze' -Version '9.9.9'
            $null = Test-SwSourceMatchesRelease -WindowsDir $script:Fixture -Name 'analyze' -Version '9.9.8'
            Get-RepoState $script:Fixture | Should -BeExactly $before
        }
    }

    Context 'without a real repository' {
        BeforeEach {
            $script:Plain = New-Dir ([System.IO.Path]::Combine($TestDrive, ('plain-' + [guid]::NewGuid().ToString('N')), 'sweepr'))
            Mock Get-SwToolPath { 'C:\Example\Git\cmd\git.exe' }
            Mock Invoke-SwNativeTool { throw 'git must not be started' }
        }

        It 'Returns false without starting git when the installation root has no .git' {
            Test-SwSourceMatchesRelease -WindowsDir $script:Plain -Name 'analyze' -Version '9.9.9' | Should -BeFalse
            Should -Invoke Invoke-SwNativeTool -Times 0 -Exactly
        }

        It 'Returns false when git is not found' {
            New-Dir (Join-Path $script:Plain '.git') | Out-Null
            Mock Get-SwToolPath { $null }
            Test-SwSourceMatchesRelease -WindowsDir $script:Plain -Name 'analyze' -Version '9.9.9' | Should -BeFalse
            Should -Invoke Invoke-SwNativeTool -Times 0 -Exactly
        }

        It 'Returns false when git fails: <Case>' -ForEach @(
            @{ Case = 'exit code 128'; Result = { [pscustomobject]@{ ExitCode = 128; StdOut = ''; StdErr = 'fatal'; TimedOut = $false } } }
            @{ Case = 'time limit'; Result = { [pscustomobject]@{ ExitCode = -1; StdOut = ''; StdErr = ''; TimedOut = $true } } }
            @{ Case = 'an exception'; Result = { throw 'git could not be started' } }
        ) {
            New-Dir (Join-Path $script:Plain '.git') | Out-Null
            $script:Failure = $Result
            Mock Invoke-SwNativeTool { & $script:Failure }
            Test-SwSourceMatchesRelease -WindowsDir $script:Plain -Name 'analyze' -Version '9.9.9' | Should -BeFalse
        }
    }
}
