# Sweepr - tests for lib\core\tui_binaries.ps1, part 2: Restore-SwTuiRelease (query the release,
# read the checksum file, download to a temporary file, verify, install).
#
# The rule numbers in the test names (TB- and S) number the rules and the safety invariants of the
# module's behavior; each testable rule and invariant has at least one test.
#
# Interface pinned here: Restore-SwTuiRelease -Name -WindowsDir -DestinationPath -Version returns
# exactly one of the strings ok, unavailable, mismatch.
#
# Platform notes:
#   - The network is replaced: Invoke-WebRequest is a mock that tells a request for the checksum file
#     (no -OutFile) from a download (-OutFile) and serves fake release files. Invoke-RestMethod,
#     Start-Process and Invoke-SwNativeTool are mocks that fail the test when called.
#   - Paths are built from $TestDrive. Nothing real is touched: no network, no process, no profile.
#   - Tests marked [W] describe a Windows fact and are meant to fail on Linux where it does not hold.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:TuiFile = Join-Path (Join-Path (Join-Path $script:RepoRoot 'lib') 'core') 'tui_binaries.ps1'
    $script:IsWin = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
    $script:DownloadRoot = 'https://github.com/brummilab/sweepr/releases/download'
    $script:OriginalProgress = $global:ProgressPreference
    $script:OriginalProtocol = [System.Net.ServicePointManager]::SecurityProtocol

    . $script:TuiFile

    function script:New-Dir([string]$Path) {
        [void][System.IO.Directory]::CreateDirectory($Path)
        return $Path
    }
    function script:Get-Sha256Text([byte[]]$Bytes) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return (([BitConverter]::ToString($sha.ComputeHash($Bytes))) -replace '-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
    }
    function script:Get-DirectoryFiles([string]$Path) {
        if (-not [System.IO.Directory]::Exists($Path)) { return @() }
        return @([System.IO.Directory]::GetFileSystemEntries($Path) | ForEach-Object { [System.IO.Path]::GetFileName($_) } | Sort-Object)
    }

    # Serves a release under $Tag: the checksum file (for the programs in $Files) and the programs.
    # $Files maps an asset name to its bytes; $Hashes may override the published hash of an asset.
    function script:Add-Release {
        param([string]$Tag, [hashtable]$Files, [hashtable]$Hashes = @{}, [switch]$AsBytes, [switch]$WithBom)
        $base = "$($script:DownloadRoot)/$Tag/"
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add((('0' * 64) + '  sweepr-9.9.9-x64.zip'))
        foreach ($name in $Files.Keys) {
            $hash = Get-Sha256Text $Files[$name]
            if ($Hashes.ContainsKey($name)) { $hash = $Hashes[$name] }
            $lines.Add("$hash  $name")
            $script:Net[$base + $name] = @{ Bytes = $Files[$name] }
        }
        $text = ($lines -join "`n") + "`n"
        if ($AsBytes) {
            $bytes = $script:Utf8.GetBytes($text)
            if ($WithBom) { $bytes = [byte[]]([byte[]]@(0xEF, 0xBB, 0xBF) + $bytes) }
            $script:Net[$base + 'SHA256SUMS.txt'] = @{ Content = $bytes }
        }
        else {
            if ($WithBom) { $text = [string][char]0xFEFF + $text }
            $script:Net[$base + 'SHA256SUMS.txt'] = @{ Content = $text }
        }
    }
    function script:Get-ProgramCalls { return @($script:Calls | Where-Object { -not [string]::IsNullOrEmpty([string]$_.OutFile) }) }
    function script:Get-SumsCalls { return @($script:Calls | Where-Object { [string]::IsNullOrEmpty([string]$_.OutFile) }) }
}

AfterAll {
    $global:ProgressPreference = $script:OriginalProgress
    try { [System.Net.ServicePointManager]::SecurityProtocol = $script:OriginalProtocol } catch { $null = $_ }
}

Describe 'Restore-SwTuiRelease' {
    BeforeEach {
        $script:Root = New-Dir (Join-Path $TestDrive ('rel-' + [guid]::NewGuid().ToString('N')))
        $script:BinDir = Join-Path $script:Root 'bin'
        $script:Dest = Join-Path $script:BinDir 'status.exe'
        # Release addresses differ in the case of one letter (V and v): the table compares ordinally.
        $script:Net = New-Object System.Collections.Hashtable ([System.StringComparer]::Ordinal)
        $script:Calls = New-Object System.Collections.Generic.List[object]
        $script:Order = New-Object System.Collections.Generic.List[string]
        $script:Status = New-Object System.Collections.Generic.List[object]
        $script:Program = [byte[]](1..200)
        $script:Other = [byte[]](201..255)
        $global:ProgressPreference = 'Continue'

        Mock Invoke-WebRequest {
            # PowerShell 7.4 and later call -TimeoutSec -ConnectionTimeoutSeconds (the old name is an alias).
            $timeout = $null
            foreach ($timeoutName in 'TimeoutSec', 'ConnectionTimeoutSeconds') {
                if ($PesterBoundParameters.ContainsKey($timeoutName)) { $timeout = $PesterBoundParameters[$timeoutName] }
            }
            $script:Calls.Add([pscustomobject]@{
                    Uri             = [string]$Uri
                    OutFile         = $OutFile
                    UseBasicParsing = [bool]$UseBasicParsing
                    TimeoutSec      = $timeout
                    UserAgent       = [string]$UserAgent
                    Progress        = [string]$ProgressPreference
                    Keys            = @($PesterBoundParameters.Keys)
                })
            $entry = $script:Net[[string]$Uri]
            if ($OutFile) { $script:Order.Add('program') } else { $script:Order.Add('sums') }
            if ($null -eq $entry) { throw [System.Net.WebException]::new('The remote server returned an error: (404) Not Found.') }
            if ($entry.ContainsKey('Throw')) {
                if ($entry.ContainsKey('Partial') -and $OutFile) { [System.IO.File]::WriteAllBytes($OutFile, [byte[]]@(9, 9, 9)) }
                throw $entry.Throw
            }
            if ($OutFile) {
                [System.IO.File]::WriteAllBytes($OutFile, $entry.Bytes)
                return
            }
            return [pscustomobject]@{ StatusCode = 200; Content = $entry.Content }
        }
        Mock Invoke-RestMethod { throw 'Invoke-RestMethod must not be used' }
        Mock Start-Process { throw 'Start-Process must not be used' }
        Mock Invoke-SwNativeTool { throw 'a downloaded program must not be started' }
        Mock Write-SwTuiStatus {
            $script:Order.Add('status')
            $script:Status.Add([pscustomobject]@{ Message = [string]$Message; Color = [string]$Color })
        }
    }

    Context 'the requests (TB-7, S6)' {
        It 'Asks for the checksum file first and then for the program, at the fixed release address' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9' | Should -BeExactly 'ok'
            $script:Calls.Count | Should -Be 2
            $script:Calls[0].Uri | Should -BeExactly "$($script:DownloadRoot)/V9.9.9-windows/SHA256SUMS.txt"
            $script:Calls[0].OutFile | Should -BeNullOrEmpty
            $script:Calls[1].Uri | Should -BeExactly "$($script:DownloadRoot)/V9.9.9-windows/status-windows-x64.exe"
            $script:Calls[1].OutFile | Should -Not -BeNullOrEmpty
        }

        It 'Uses only Invoke-WebRequest, never Invoke-RestMethod' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9' | Should -BeExactly 'ok'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
            Should -Invoke Invoke-WebRequest -Times 2 -Exactly
        }

        It 'Sends every request with -UseBasicParsing, a Sweepr user agent and no credentials, token or headers' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            $null = Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9'
            $script:Calls.Count | Should -BeGreaterThan 0
            foreach ($call in $script:Calls) {
                $call.UseBasicParsing | Should -BeTrue
                $call.UserAgent | Should -Match '(?i)sweepr'
                foreach ($forbidden in 'Headers', 'Credential', 'Token', 'Authentication', 'WebSession', 'Proxy', 'ProxyCredential', 'UseDefaultCredentials', 'SkipCertificateCheck', 'Method', 'Body') {
                    $call.Keys | Should -Not -Contain $forbidden
                }
            }
        }

        It 'Gives the checksum file 20 seconds and the program 120 seconds' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            $null = Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9'
            (Get-SumsCalls)[0].TimeoutSec | Should -Be 20
            (Get-ProgramCalls)[0].TimeoutSec | Should -Be 120
        }

        It 'Asks only the fixed host and path prefix, for the two files of the release' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            $null = Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9'
            foreach ($call in $script:Calls) {
                $call.Uri | Should -Match '^https://github\.com/brummilab/sweepr/releases/download/[Vv]9\.9\.9-windows/(SHA256SUMS\.txt|status-windows-x64\.exe)$'
            }
        }

        It 'Asks for the asset of the other program when the name is analyze' {
            Add-Release 'V9.9.9-windows' @{ 'analyze-windows-x64.exe' = $script:Other }
            $dest = Join-Path $script:BinDir 'analyze.exe'
            Restore-SwTuiRelease -Name 'analyze' -WindowsDir $script:Root -DestinationPath $dest -Version '9.9.9' | Should -BeExactly 'ok'
            (Get-ProgramCalls)[0].Uri | Should -BeExactly "$($script:DownloadRoot)/V9.9.9-windows/analyze-windows-x64.exe"
            [System.IO.File]::ReadAllBytes($dest) | Should -Be $script:Other
        }

        It 'Asks for nothing twice: no retry' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            $script:Net["$($script:DownloadRoot)/V9.9.9-windows/status-windows-x64.exe"] = @{ Throw = 'connection reset' }
            $null = Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9'
            @($script:Calls | Group-Object Uri | Where-Object { $_.Count -gt 1 }).Count | Should -Be 0
        }

        It 'Adds TLS 1.2 to the protocols before the first request and takes none away' {
            $original = [System.Net.ServicePointManager]::SecurityProtocol
            $set = $true
            try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls11 }
            catch { $set = $false }
            if (-not $set) { Set-ItResult -Skipped -Because 'the host does not let a test set the protocols'; return }
            try {
                Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
                $null = Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9'
                $now = [System.Net.ServicePointManager]::SecurityProtocol
                ($now -band [System.Net.SecurityProtocolType]::Tls12) | Should -Be ([System.Net.SecurityProtocolType]::Tls12)
                ($now -band [System.Net.SecurityProtocolType]::Tls11) | Should -Be ([System.Net.SecurityProtocolType]::Tls11)
            }
            finally { [System.Net.ServicePointManager]::SecurityProtocol = $original }
        }

        It 'Leaves the protocols alone when the system chooses them (SystemDefault)' {
            $original = [System.Net.ServicePointManager]::SecurityProtocol
            $set = $true
            try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::SystemDefault }
            catch { $set = $false }
            if (-not $set) { Set-ItResult -Skipped -Because 'the host does not let a test set the protocols'; return }
            try {
                Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
                $null = Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9'
                [int][System.Net.ServicePointManager]::SecurityProtocol | Should -Be 0
            }
            finally { [System.Net.ServicePointManager]::SecurityProtocol = $original }
        }

        It 'Adds TLS 1.2 to an explicit list of older protocols' {
            $original = [System.Net.ServicePointManager]::SecurityProtocol
            $older = [System.Net.SecurityProtocolType]::Ssl3 -bor [System.Net.SecurityProtocolType]::Tls
            $set = $true
            try { [System.Net.ServicePointManager]::SecurityProtocol = $older }
            catch { $set = $false }
            if (-not $set) { Set-ItResult -Skipped -Because 'the host does not let a test set the protocols'; return }
            try {
                Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
                $null = Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9'
                [System.Net.ServicePointManager]::SecurityProtocol | Should -Be ($older -bor [System.Net.SecurityProtocolType]::Tls12)
            }
            finally { [System.Net.ServicePointManager]::SecurityProtocol = $original }
        }

        It 'Suppresses the progress display during the requests and restores the previous value' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            $global:ProgressPreference = 'Continue'
            $null = Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9'
            foreach ($call in $script:Calls) { $call.Progress | Should -Be 'SilentlyContinue' }
            $global:ProgressPreference | Should -Be 'Continue'
        }

        It 'Restores the progress preference also when a request fails' {
            $global:ProgressPreference = 'Continue'
            $null = Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9'
            $global:ProgressPreference | Should -Be 'Continue'
        }
    }

    Context 'which release answers (TB-7)' {
        It 'Takes the program from the lower-case tag when the upper-case tag does not answer' {
            Add-Release 'v9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9' | Should -BeExactly 'ok'
            @(Get-SumsCalls | ForEach-Object { $_.Uri }) | Should -Be @(
                "$($script:DownloadRoot)/V9.9.9-windows/SHA256SUMS.txt"
                "$($script:DownloadRoot)/v9.9.9-windows/SHA256SUMS.txt"
            )
            # @(): a single call is unrolled by the function, and Windows PowerShell 5.1 gives a custom object no Count.
            @(Get-ProgramCalls).Count | Should -Be 1
            (Get-ProgramCalls)[0].Uri | Should -BeExactly "$($script:DownloadRoot)/v9.9.9-windows/status-windows-x64.exe"
        }

        It 'Also tries the lower-case tag when the first request fails for another reason: <Reason>' -ForEach @(
            @{ Reason = 'timeout'; Failure = 'The operation has timed out.' }
            @{ Reason = 'forbidden'; Failure = 'The remote server returned an error: (403) Forbidden.' }
            @{ Reason = 'connection'; Failure = 'Unable to connect to the remote server' }
        ) {
            Add-Release 'v9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            $script:Net["$($script:DownloadRoot)/V9.9.9-windows/SHA256SUMS.txt"] = @{ Throw = $Failure }
            Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9' | Should -BeExactly 'ok'
        }

        It 'Does not ask for the lower-case tag when the upper-case tag answers' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            Add-Release 'v9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Other }
            Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9' | Should -BeExactly 'ok'
            @($script:Calls | Where-Object { $_.Uri -cmatch '/v9\.9\.9-windows/' }).Count | Should -Be 0
            [System.IO.File]::ReadAllBytes($script:Dest) | Should -Be $script:Program
        }

        It 'Lets the first tag with a checksum file decide, even when it does not list the program' {
            Add-Release 'V9.9.9-windows' @{ 'analyze-windows-x64.exe' = $script:Other }
            Add-Release 'v9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9' | Should -BeExactly 'unavailable'
            @(Get-ProgramCalls).Count | Should -Be 0
            @($script:Calls | Where-Object { $_.Uri -cmatch '/v9\.9\.9-windows/' }).Count | Should -Be 0
        }

        It 'Returns unavailable, without a status line and without a file or folder, when no tag answers' {
            Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9' | Should -BeExactly 'unavailable'
            $script:Calls.Count | Should -Be 2
            $script:Status.Count | Should -Be 0
            [System.IO.File]::Exists($script:Dest) | Should -BeFalse
            [System.IO.Directory]::Exists($script:BinDir) | Should -BeFalse
        }
    }

    Context 'the checksum file (TB-8)' {
        It 'Returns unavailable and downloads nothing when the file has no line for the program' {
            Add-Release 'V9.9.9-windows' @{ 'analyze-windows-x64.exe' = $script:Other }
            Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9' | Should -BeExactly 'unavailable'
            @(Get-ProgramCalls).Count | Should -Be 0
            [System.IO.File]::Exists($script:Dest) | Should -BeFalse
        }

        It 'Returns unavailable and downloads nothing when the program is listed with two different hashes' {
            $base = "$($script:DownloadRoot)/V9.9.9-windows/"
            $script:Net[$base + 'SHA256SUMS.txt'] = @{ Content = (("a" * 64) + "  status-windows-x64.exe`n" + ("b" * 64) + "  status-windows-x64.exe`n") }
            $script:Net[$base + 'status-windows-x64.exe'] = @{ Bytes = $script:Program }
            Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9' | Should -BeExactly 'unavailable'
            @(Get-ProgramCalls).Count | Should -Be 0
        }

        It 'Reads a checksum file that arrives as bytes with a byte order mark' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program } -AsBytes -WithBom
            Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9' | Should -BeExactly 'ok'
        }

        It 'Reads a checksum file that arrives as bytes without a byte order mark' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program } -AsBytes
            Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9' | Should -BeExactly 'ok'
        }

        It 'Reads a checksum file that arrives as text with a byte order mark' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program } -WithBom
            Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9' | Should -BeExactly 'ok'
        }

        It 'Reads a published hash in upper case' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program } @{ 'status-windows-x64.exe' = (Get-Sha256Text $script:Program).ToUpperInvariant() }
            Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9' | Should -BeExactly 'ok'
        }
    }

    Context 'download, verification and installation (TB-9, S5, S8)' {
        It 'Installs the verified program at the destination and returns ok' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            $result = @(Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9')
            $result.Count | Should -Be 1
            $result[0] | Should -BeExactly 'ok'
            [System.IO.File]::ReadAllBytes($script:Dest) | Should -Be $script:Program
        }

        It 'Creates the destination folder when it is missing and leaves only the program in it' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            [System.IO.Directory]::Exists($script:BinDir) | Should -BeFalse
            $null = Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9'
            Get-DirectoryFiles $script:BinDir | Should -Be @('status.exe')
        }

        It 'Announces the download with a status line that names the program, before the download starts' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            $null = Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9'
            @($script:Status | Where-Object { $_.Message -match 'status' }).Count | Should -BeGreaterThan 0
            $script:Order.IndexOf('status') | Should -BeGreaterOrEqual 0
            $script:Order.IndexOf('status') | Should -BeLessThan $script:Order.IndexOf('program')
        }

        It 'Downloads into a uniquely named temporary file next to the destination that does not end in .exe' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            $null = Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9'
            $temporary = [string](Get-ProgramCalls)[0].OutFile
            [System.IO.Path]::GetDirectoryName($temporary) | Should -BeExactly $script:BinDir
            $name = [System.IO.Path]::GetFileName($temporary)
            $name | Should -Not -BeExactly 'status.exe'
            $name | Should -Not -Match '(?i)\.exe$'
            $name | Should -Match '(?i)[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}'
        }

        It 'Uses a different temporary name in every run' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            $null = Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9'
            $null = Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9'
            $names = @(Get-ProgramCalls | ForEach-Object { [System.IO.Path]::GetFileName([string]$_.OutFile) })
            $names.Count | Should -Be 2
            $names[0] | Should -Not -BeExactly $names[1]
        }

        It 'Hashes the downloaded file itself, not a copy' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            $script:Hashed = New-Object System.Collections.Generic.List[string]
            Mock Get-SwFileSha256 {
                $script:Hashed.Add([string]$Path)
                Get-Sha256Text ([System.IO.File]::ReadAllBytes($Path))
            }
            $null = Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9'
            $script:Hashed.Count | Should -Be 1
            $script:Hashed[0] | Should -BeExactly ([string](Get-ProgramCalls)[0].OutFile)
        }

        It 'Does not depend on Get-FileHash' {
            Mock Get-FileHash { throw [System.Management.Automation.CommandNotFoundException]::new('Get-FileHash is not available') }
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9' | Should -BeExactly 'ok'
        }

        It 'Replaces an existing destination' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            New-Dir $script:BinDir | Out-Null
            [System.IO.File]::WriteAllBytes($script:Dest, [byte[]]@(7, 7, 7))
            Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9' | Should -BeExactly 'ok'
            [System.IO.File]::ReadAllBytes($script:Dest) | Should -Be $script:Program
            Get-DirectoryFiles $script:BinDir | Should -Be @('status.exe')
        }

        It 'Returns mismatch, deletes the download and creates no destination when the hash differs' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program } @{ 'status-windows-x64.exe' = (Get-Sha256Text $script:Other) }
            $result = @(Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9')
            $result.Count | Should -Be 1
            $result[0] | Should -BeExactly 'mismatch'
            [System.IO.File]::Exists($script:Dest) | Should -BeFalse
            Get-DirectoryFiles $script:BinDir | Should -BeNullOrEmpty
        }

        It 'Leaves an existing destination unchanged when the hash differs' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program } @{ 'status-windows-x64.exe' = (Get-Sha256Text $script:Other) }
            New-Dir $script:BinDir | Out-Null
            [System.IO.File]::WriteAllBytes($script:Dest, [byte[]]@(7, 7, 7))
            Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9' | Should -BeExactly 'mismatch'
            [System.IO.File]::ReadAllBytes($script:Dest) | Should -Be ([byte[]]@(7, 7, 7))
            Get-DirectoryFiles $script:BinDir | Should -Be @('status.exe')
        }

        It 'Never starts the program, neither before nor after installing it' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            $null = Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9'
            Should -Invoke Invoke-SwNativeTool -Times 0 -Exactly
            Should -Invoke Start-Process -Times 0 -Exactly
        }

        It 'Deletes only its own temporary file and keeps every other file in the destination folder' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program } @{ 'status-windows-x64.exe' = (Get-Sha256Text $script:Other) }
            New-Dir $script:BinDir | Out-Null
            $neighbours = @('readme.txt', 'analyze.exe', '.sweepr-status-0123456789abcdef0123456789abcdef.exe', 'status.exe.old', 'status-windows-x64.exe')
            foreach ($neighbour in $neighbours) { [System.IO.File]::WriteAllText((Join-Path $script:BinDir $neighbour), 'keep') }
            $null = Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9'
            Get-DirectoryFiles $script:BinDir | Should -Be @($neighbours | Sort-Object)
            foreach ($neighbour in $neighbours) { [System.IO.File]::ReadAllText((Join-Path $script:BinDir $neighbour)) | Should -BeExactly 'keep' }
        }

        It 'Keeps the neighbours after a successful installation too' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            New-Dir $script:BinDir | Out-Null
            foreach ($neighbour in 'readme.txt', 'analyze.exe') { [System.IO.File]::WriteAllText((Join-Path $script:BinDir $neighbour), 'keep') }
            $null = Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9'
            Get-DirectoryFiles $script:BinDir | Should -Be @('analyze.exe', 'readme.txt', 'status.exe')
        }

        It 'Returns unavailable with a yellow status line naming the program and the cause when the download fails' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            $script:Net["$($script:DownloadRoot)/V9.9.9-windows/status-windows-x64.exe"] = @{ Throw = 'connection reset'; Partial = $true }
            $result = @(Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9')
            $result.Count | Should -Be 1
            $result[0] | Should -BeExactly 'unavailable'
            $failure = @($script:Status | Where-Object { $_.Message -match 'connection reset' })
            $failure.Count | Should -BeGreaterThan 0
            $failure[0].Message | Should -Match 'status'
            $failure[0].Color | Should -Be 'Yellow'
            [System.IO.File]::Exists($script:Dest) | Should -BeFalse
            Get-DirectoryFiles $script:BinDir | Should -BeNullOrEmpty
        }

        It 'Keeps an existing destination when the download fails' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            $script:Net["$($script:DownloadRoot)/V9.9.9-windows/status-windows-x64.exe"] = @{ Throw = 'connection reset'; Partial = $true }
            New-Dir $script:BinDir | Out-Null
            [System.IO.File]::WriteAllBytes($script:Dest, [byte[]]@(7, 7, 7))
            Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9' | Should -BeExactly 'unavailable'
            [System.IO.File]::ReadAllBytes($script:Dest) | Should -Be ([byte[]]@(7, 7, 7))
            Get-DirectoryFiles $script:BinDir | Should -Be @('status.exe')
        }

        It 'Returns unavailable, removes the download and reports the cause when hashing fails' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            Mock Get-SwFileSha256 { throw 'disk read error' }
            Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9' | Should -BeExactly 'unavailable'
            @($script:Status | Where-Object { $_.Message -match 'disk read error' }).Count | Should -BeGreaterThan 0
            Get-DirectoryFiles $script:BinDir | Should -BeNullOrEmpty
        }

        It 'Returns unavailable with the folder and the cause when the destination folder cannot be created' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            [System.IO.File]::WriteAllText($script:BinDir, 'a file where the folder should be')
            $result = @(Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9')
            $result.Count | Should -Be 1
            $result[0] | Should -BeExactly 'unavailable'
            @($script:Status | Where-Object { $_.Color -eq 'Yellow' }).Count | Should -BeGreaterThan 0
            [System.IO.File]::ReadAllText($script:BinDir) | Should -BeExactly 'a file where the folder should be'
        }

        It 'Treats brackets, quotes and blanks in the destination folder literally' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            $parent = New-Dir (Join-Path $TestDrive ('lit-' + [guid]::NewGuid().ToString('N')))
            # A sibling folder that the bracket pattern would match, holding a file of the same name.
            $decoy = New-Dir (Join-Path $parent 'Tools x64\sweepr\bin')
            [System.IO.File]::WriteAllBytes((Join-Path $decoy 'status.exe'), [byte[]]@(7, 7, 7))
            $root = [System.IO.Path]::Combine($parent, "Tools [x64] it's", 'sweepr')
            $dest = [System.IO.Path]::Combine($root, 'bin', 'status.exe')
            Restore-SwTuiRelease -Name 'status' -WindowsDir $root -DestinationPath $dest -Version '9.9.9' | Should -BeExactly 'ok'
            [System.IO.File]::ReadAllBytes($dest) | Should -Be $script:Program
            [System.IO.File]::ReadAllBytes((Join-Path $decoy 'status.exe')) | Should -Be ([byte[]]@(7, 7, 7))
            Get-DirectoryFiles ([System.IO.Path]::GetDirectoryName($dest)) | Should -Be @('status.exe')
            Get-DirectoryFiles $decoy | Should -Be @('status.exe')
        }

        It '[W] Returns unavailable and keeps the old program when the destination is locked' {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            New-Dir $script:BinDir | Out-Null
            [System.IO.File]::WriteAllBytes($script:Dest, [byte[]]@(7, 7, 7))
            $lock = [System.IO.File]::Open($script:Dest, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
            try {
                Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version '9.9.9' | Should -BeExactly 'unavailable'
            }
            finally { $lock.Dispose() }
            [System.IO.File]::ReadAllBytes($script:Dest) | Should -Be ([byte[]]@(7, 7, 7))
            Get-DirectoryFiles $script:BinDir | Should -Be @('status.exe')
        }
    }

    Context 'the version (TB-5, S6)' {
        It 'Returns unavailable without a request for the unusable version <Case>' -ForEach @(
            @{ Case = 'empty'; Version = '' }
            @{ Case = 'blank'; Version = ' ' }
            @{ Case = 'null'; Version = $null }
            @{ Case = 'with path steps'; Version = '0.2.0/../x' }
            @{ Case = 'two dots'; Version = '..' }
            @{ Case = 'relative path'; Version = '../x' }
            @{ Case = 'with a slash'; Version = '1/2' }
            @{ Case = 'with a backslash'; Version = '1\2' }
            @{ Case = 'with a question mark'; Version = 'a?b' }
            @{ Case = 'with a hash'; Version = 'a#b' }
            @{ Case = 'with a blank'; Version = 'a b' }
            @{ Case = 'with a colon'; Version = 'a:b' }
            @{ Case = 'with an at sign'; Version = 'a@b' }
            @{ Case = 'with a percent sign'; Version = '1%2F' }
            @{ Case = 'with a semicolon'; Version = '1;2' }
            @{ Case = 'with a line end'; Version = "1.0`n2" }
            @{ Case = 'starting with a dot'; Version = '.5' }
            @{ Case = 'starting with a hyphen'; Version = '-1' }
            @{ Case = 'starting with a plus'; Version = '+1' }
        ) {
            Add-Release 'V9.9.9-windows' @{ 'status-windows-x64.exe' = $script:Program }
            Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version $Version | Should -BeExactly 'unavailable'
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            [System.IO.Directory]::Exists($script:BinDir) | Should -BeFalse
        }

        It 'Puts the usable version <Version> into both tag spellings' -ForEach @(
            @{ Version = '0.2.0' }
            @{ Version = '1.0.0-rc.1' }
            @{ Version = '1.2.3+build5' }
            @{ Version = '10' }
            @{ Version = 'Abc' }
        ) {
            Restore-SwTuiRelease -Name 'status' -WindowsDir $script:Root -DestinationPath $script:Dest -Version $Version | Should -BeExactly 'unavailable'
            @(Get-SumsCalls | ForEach-Object { $_.Uri }) | Should -Be @(
                "$($script:DownloadRoot)/V$Version-windows/SHA256SUMS.txt"
                "$($script:DownloadRoot)/v$Version-windows/SHA256SUMS.txt"
            )
        }
    }
}
