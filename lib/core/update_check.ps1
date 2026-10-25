# Optional, bounded update notices. Never install anything from this path.
#Requires -Version 5.1

function Test-SweeprUpdateNoticeAllowed {
    param([string]$CommandName, [string[]]$Arguments)
    if (-not (Test-SweeprInteractiveOutput) -or [Console]::IsErrorRedirected) { return $false }
    if ($env:SWEEPR_DRY_RUN -eq '1') { return $false }
    if ($CommandName -and $CommandName -notin @('clean', 'uninstall', 'optimize', 'purge', 'analyze', 'status')) { return $false }
    foreach ($argument in $Arguments) {
        if ($argument -match '^--?(json|ndjson|watch|help|h|version|v|list|dry-run|whitelist)([=:]|$)') { return $false }
    }
    return $true
}

function Get-SweeprAvailableVersion {
    param([string]$Method)
    # Check the install's own channel: a GitHub release need not be in winget yet.
    $headers = @{ 'User-Agent' = 'Sweepr-CLI-Windows'; Accept = 'application/vnd.github+json' }
    if ($Method -eq 'Scoop') {
        $data = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/sweepr.json' -TimeoutSec 10 -Headers $headers
        $versions = @($data.version)
    }
    elseif ($Method -eq 'winget') {
        $data = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests/t/brummilab/Sweepr' -TimeoutSec 10 -Headers $headers
        $versions = @($data | Where-Object { $_.type -eq 'dir' } | ForEach-Object { $_.name })
    }
    else {
        $data = Invoke-RestMethod -Uri 'https://api.github.com/repos/brummilab/sweepr/releases?per_page=100' -TimeoutSec 10 -Headers $headers
        $versions = @(foreach ($release in $data) {
            if (-not $release.draft -and -not $release.prerelease -and $release.tag_name -cmatch '^V([0-9]+\.[0-9]+\.[0-9]+)-windows$') {
                $Matches[1]
            }
        })
    }
    return $versions | Where-Object { $_ -match '^[0-9]{1,5}\.[0-9]{1,5}\.[0-9]{1,5}$' } |
        Sort-Object { [version]$_ } -Descending | Select-Object -First 1
}

function Read-SweeprUpdateState {
    param([string]$Path, [string]$Key)
    try {
        $state = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
        if ($state.Schema -ne 1 -or $state.Key -ne $Key) { return $null }
        $age = [DateTime]::UtcNow.Ticks - [long]$state.CheckedTicks
        if ($age -lt 0 -or $state.Interval -notin @(3600, 86400)) { return $null }
        return $state
    }
    catch { return $null }
}

function Write-SweeprUpdateState {
    param([string]$Path, $State)
    # Do not follow a redirected cache location, including an elevated invocation.
    $parent = [IO.DirectoryInfo](Split-Path -Parent $Path)
    while ($null -ne $parent) {
        if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked update cache' }
        $parent = $parent.Parent
    }
    if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Linked update cache' }
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($State | ConvertTo-Json -Compress))
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
    }
    finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Invoke-SweeprUpdateLookup {
    param([string]$Path, [string]$Key, [string]$Method)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $latest = Get-SweeprAvailableVersion -Method $Method
        if (-not $latest) { return }
        $state = Read-SweeprUpdateState -Path $Path -Key $Key
        if ($null -eq $state) { return }
        $state.Latest = $latest
        $state.CheckedTicks = [DateTime]::UtcNow.Ticks
        $state.Interval = 86400
        Write-SweeprUpdateState -Path $Path -State $state
    }
    catch { } # Offline, rate-limited and unavailable channels remain quiet.
}

function Start-SweeprUpdateCheck {
    param([string]$RootDir, [string]$Version, [string]$Method)
    try {
        if ($Version -notmatch '^[0-9]{1,5}\.[0-9]{1,5}\.[0-9]{1,5}$') { return $null }
        $path = Join-Path (Get-CachePath) 'update-check.json'
        $key = "$RootDir|$Version|$Method"
        $context = @{ Path = $path; Key = $key; Version = $Version; Method = $Method }
        $state = Read-SweeprUpdateState -Path $path -Key $key
        if ($null -ne $state -and ([DateTime]::UtcNow.Ticks - [long]$state.CheckedTicks) -lt ([long]$state.Interval * [TimeSpan]::TicksPerSecond)) { return $context }
        Write-SweeprUpdateState -Path $path -State @{ Schema = 1; Key = $key; CheckedTicks = [DateTime]::UtcNow.Ticks; Interval = 3600; Latest = '' }
        # A short-lived hidden worker survives a quick menu exit; the foreground
        # never waits for networking. Every argument is a quoted literal.
        $module = Join-Path $RootDir 'lib\core\update_check.ps1'
        $quoted = @($module, $path, $key, $Method) | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }
        $command = "`$ErrorActionPreference='Stop'; `$ProgressPreference='SilentlyContinue'; . $($quoted[0]); Invoke-SweeprUpdateLookup -Path $($quoted[1]) -Key $($quoted[2]) -Method $($quoted[3])"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $start.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $process = [Diagnostics.Process]::Start($start)
        $process.Dispose()
        return $context
    }
    catch { return $null }
}

function Get-SweeprUpdateNotice {
    param($Context)
    if ($null -eq $Context) { return }
    $state = Read-SweeprUpdateState -Path $Context.Path -Key $Context.Key
    if ($null -eq $state -or $state.Latest -notmatch '^[0-9]{1,5}\.[0-9]{1,5}\.[0-9]{1,5}$') { return }
    if (([DateTime]::UtcNow.Ticks - [long]$state.CheckedTicks) -ge [TimeSpan]::TicksPerDay) { return }
    if ([version]$state.Latest -le [version]$Context.Version) { return }
    switch ($Context.Method) {
        'winget' { $action = 'run winget upgrade brummilab.Sweepr' }
        'Scoop' { $action = 'run scoop update sweepr' }
        'Source' { $action = 'run sw update' }
        default { $action = "download https://github.com/brummilab/sweepr/releases/tag/V$($state.Latest)-windows" }
    }
    return "Update $($state.Latest) available, $action"
}

function Show-SweeprUpdateNotice {
    param($Context)
    try {
        $notice = Get-SweeprUpdateNotice -Context $Context
        if ($notice) { Write-Host $notice -ForegroundColor Yellow }
    }
    catch { }
}
