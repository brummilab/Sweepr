# Sweepr Windows - one-time read-only PC check without installing anything.
#
#   iwr -useb https://raw.githubusercontent.com/brummilab/Sweepr/main/check.ps1 | iex
#
# Downloads the latest portable release into its own folder under %TEMP%,
# verifies its SHA-256 checksum, runs `sweepr.ps1 check --report` in a child
# Windows PowerShell and removes the folder again. Only the HTML report stays
# in %TEMP%. Everything runs inside one script block and never calls exit, so
# the caller's session (variables, preferences, environment) stays as it was.

& {
    # CLM blocks the .NET calls below; stop before anything is downloaded.
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        Write-Host "Sweepr check cannot run here: PowerShell is in Constrained Language Mode ($($ExecutionContext.SessionState.LanguageMode))."
        return
    }
    # A group policy overrides -ExecutionPolicy Bypass for the child run.
    # Releases are unsigned, so Restricted and AllSigned both block them.
    foreach ($scope in @('MachinePolicy', 'UserPolicy')) {
        $policy = [string](Get-ExecutionPolicy -Scope $scope)
        if ($policy -eq 'Restricted' -or $policy -eq 'AllSigned') {
            Write-Host "Sweepr check cannot run here: the $scope execution policy is $policy (set by group policy)."
            return
        }
    }

    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $base = 'https://github.com/brummilab/Sweepr/releases/latest/download/'
    $runner = 'powershell.exe'
    if ($env:SWEEPR_CHECK_RUNNER) { $runner = $env:SWEEPR_CHECK_RUNNER }

    # Removes one entry without following links: a junction or symlink is
    # deleted as a link, never its target (pattern from quick-install.ps1).
    function Remove-CheckEntry([System.IO.FileSystemInfo]$Item) {
        if ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            if ($Item.Attributes -band [System.IO.FileAttributes]::Directory) { [System.IO.Directory]::Delete($Item.FullName, $false) }
            else { [System.IO.File]::Delete($Item.FullName) }
            return
        }
        if ($Item.Attributes -band [System.IO.FileAttributes]::Directory) {
            foreach ($child in @(Get-ChildItem -LiteralPath $Item.FullName -Force)) { Remove-CheckEntry $child }
            [System.IO.Directory]::Delete($Item.FullName, $false)
            return
        }
        Remove-Item -LiteralPath $Item.FullName -Force
    }

    $temp = $env:TEMP
    if (-not $temp) { $temp = [System.IO.Path]::GetTempPath() }
    $dir = Join-Path $temp ('sweepr-check-' + [System.IO.Path]::GetRandomFileName())

    # TLS 1.2 for older Windows PowerShell; restored in finally because the
    # setting is process-wide.
    $oldProtocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $oldProtocol -bor 3072
        $null = New-Item -ItemType Directory -Path $dir

        Write-Host 'Downloading the latest Sweepr portable release...'
        $sums = Join-Path $dir 'SHA256SUMS.txt'
        Invoke-WebRequest -Uri ($base + 'SHA256SUMS.txt') -OutFile $sums -UseBasicParsing
        $expected = $null; $zipName = $null
        foreach ($line in [System.IO.File]::ReadAllLines($sums)) {
            if ($line.Trim() -match '^([0-9a-fA-F]{64}) +\*?(sweepr-[0-9A-Za-z.-]+-x64-portable\.zip)$') {
                $expected = $Matches[1].ToLowerInvariant(); $zipName = $Matches[2]
                break
            }
        }
        if (-not $zipName) {
            Write-Warning 'The latest release lists no portable zip in SHA256SUMS.txt. Nothing was run.'
            return
        }

        $zip = Join-Path $dir $zipName
        Invoke-WebRequest -Uri ($base + $zipName) -OutFile $zip -UseBasicParsing
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $stream = [System.IO.File]::OpenRead($zip)
        try { $actual = ([System.BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant() }
        finally { $stream.Dispose(); $sha.Dispose() }
        if ($actual -ne $expected) {
            Write-Warning "SHA-256 checksum mismatch for $zipName. The download was discarded and nothing was run."
            return
        }

        $app = Join-Path $dir 'sweepr'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $app)
        if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $app 'bin') 'check.ps1') -PathType Leaf)) {
            Write-Warning "$zipName has no 'check' command; it needs Sweepr 0.2 or newer. Nothing was run."
            return
        }

        # The data folder and the no-oplog switch go only to the child, so
        # the caller's environment never changes.
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $runner
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $app 'sweepr.ps1') + '" check --report'
        $psi.UseShellExecute = $false
        $psi.EnvironmentVariables['SWEEPR_DATA_DIR'] = Join-Path $app 'data'
        $psi.EnvironmentVariables['SWEEPR_NO_OPLOG'] = '1'
        Write-Host "Running sweepr check --report from $zipName (read-only)..."
        $process = [System.Diagnostics.Process]::Start($psi)
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { Write-Warning "sweepr check ended with exit code $($process.ExitCode)." }
    }
    catch {
        Write-Warning "Sweepr check failed: $($_.Exception.Message)"
    }
    finally {
        [Net.ServicePointManager]::SecurityProtocol = $oldProtocol
        try {
            $item = Get-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
            if ($item -is [System.IO.DirectoryInfo] -and -not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                Remove-CheckEntry $item
            }
        }
        catch {
            Write-Warning "Could not remove the temporary folder completely: $dir"
        }
    }
}
