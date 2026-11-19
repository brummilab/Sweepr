# Sweepr - application cleanup of sw clean: the sections "Applications" and "Game media"
#
# Caches and logs of Office, cloud drives, Adobe and game launchers, and on request old recordings of game
# programs. Loaded by dot-sourcing; it loads cache_guard.ps1 and dev.ps1 (which holds the bounded file
# search). Loading writes nothing, creates no file or folder and starts no process; it only defines
# functions. A second load in the same scope changes nothing. Setting $script:SWEEPR_CLEAN_APPS_LOADED to
# $false makes the next load define everything again.
#
# This file never removes anything itself: a folder goes to Clear-SwDirectoryContents or, while its owner
# may be working, to Clear-SwAppCache; old log files go to Remove-SwOldFiles; single files go to
# Remove-SwItems. It starts no process and asks neither the registry nor the network. Documents, Pictures
# and Videos as such, game libraries and saved games are never in a table; the recordings of game programs
# are only touched on request.

if ($(try { [bool]$script:SWEEPR_CLEAN_APPS_LOADED } catch { $false })) { return }

# The dependencies come from the folder of this file, never from the working directory.
. ([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PSScriptRoot), 'core', 'base.ps1'))
. ([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PSScriptRoot), 'core', 'log.ps1'))
. ([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PSScriptRoot), 'core', 'file_ops.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'cache_guard.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'dev.ps1'))

# ============================================================================
# Rows
# ============================================================================

function Invoke-SwAppOldFilesRow {
    # One row that removes the old files directly in a folder.
    param([string]$Path, [int]$DaysOld, [string]$Description)

    try { $null = Remove-SwOldFiles -Path $Path -DaysOld $DaysOld -Filter '*' -Description $Description }
    catch { Write-SwDebug "row not offered, ${Path}: $($_.Exception.Message)" }
}

function Invoke-SwAppTempFilesRow {
    # One row for the old *.tmp files directly in several folders: one list over all folders, offered once,
    # and only while the owner is idle (asked afresh at every evaluation). A folder whose search is not
    # complete adds nothing and is noted; the others still count.
    param([string[]]$Roots, [string]$Description, [string[]]$Processes, [datetime]$Cutoff)

    try {
        $files = [System.Collections.Generic.List[string]]::new()
        foreach ($root in $Roots) {
            try {
                $found = Read-SwDevScan -Answer (Get-SwBoundedFileScan -Root $root -Filter '*.tmp' -NoRecurse -OlderThan $Cutoff) -Name $Description -Root $root
                if ($null -ne $found) { foreach ($file in $found) { $files.Add($file) } }
            }
            catch { Write-SwDebug "folder not searched, ${root}: $($_.Exception.Message)" }
        }
        if ($files.Count -eq 0) { return }
        $names = (@($Processes | ForEach-Object { ConvertTo-SwPsLiteral -Value ([string]$_) }) -join ', ')
        $source = '$answer = @(Test-SwCacheOwnerIdle -Names @(' + $names + ')); ($answer.Count -eq 1) -and ($answer[0] -is [bool]) -and ($answer[0] -eq $true)'
        $null = Remove-SwItems -Paths ([string[]]$files.ToArray()) -Description $Description -CanRemove ([scriptblock]::Create($source))
    }
    catch { Write-SwDebug "temp files not offered, ${Description}: $($_.Exception.Message)" }
}

# ============================================================================
# Groups
# ============================================================================

function Clear-SwOfficeCache {
    <#
    .SYNOPSIS
        The Office add-in cache, the Outlook address book cache and the old temporary Office files, each
        only while no Office program is working.
    .DESCRIPTION
        The temporary files are the *.tmp files directly in the four Office folders of APPDATA that are
        older than seven days (the newer of creation and last write time decides).
    #>
    $ErrorActionPreference = 'Stop'
    try {
        $office = @('WINWORD', 'EXCEL', 'POWERPNT', 'OUTLOOK', 'ONENOTE')
        $local = Get-SwDevBase -Name 'LOCALAPPDATA'
        if ($null -ne $local) {
            Invoke-SwDevGuardedRow -Path (Join-SwCleanPath -Base $local -Rest @('Microsoft', 'Office', '16.0', 'Wef')) -Description 'Office Wef' -Processes $office
            Invoke-SwDevGuardedRow -Path (Join-SwCleanPath -Base $local -Rest @('Microsoft', 'Outlook', 'Offline Address Books')) -Description 'Office Offline Address Books' -Processes @('OUTLOOK')
        }
        $roaming = Get-SwDevBase -Name 'APPDATA'
        if ($null -ne $roaming) {
            $cutoff = (Get-Date).AddDays(-7)
            $roots = [System.Collections.Generic.List[string]]::new()
            foreach ($leaf in 'Templates', 'Word', 'Excel', 'PowerPoint') { $roots.Add((Join-SwCleanPath -Base $roaming -Rest @('Microsoft', $leaf))) }
            Invoke-SwAppTempFilesRow -Roots $roots.ToArray() -Description 'Office temp files' -Processes $office -Cutoff $cutoff
        }
    }
    catch { Write-SwDebug "office caches not handled: $($_.Exception.Message)" }
}

function Clear-SwOneDriveCache {
    <#
    .SYNOPSIS
        The OneDrive setup logs older than seven days (never the main logs in OneDrive\logs).
    #>
    $ErrorActionPreference = 'Stop'
    try {
        $local = Get-SwDevBase -Name 'LOCALAPPDATA'
        if ($null -eq $local) { return }
        Invoke-SwAppOldFilesRow -Path (Join-SwCleanPath -Base $local -Rest @('Microsoft', 'OneDrive', 'setup', 'logs')) -DaysOld 7 -Description 'OneDrive logs'
    }
    catch { Write-SwDebug "onedrive caches not handled: $($_.Exception.Message)" }
}

function Clear-SwGoogleDriveCache {
    <#
    .SYNOPSIS
        The Google Drive logs and the temporary files directly in DriveFS, both older than seven days; the
        temporary files only while Google Drive is idle.
    #>
    $ErrorActionPreference = 'Stop'
    try {
        $local = Get-SwDevBase -Name 'LOCALAPPDATA'
        if ($null -eq $local) { return }
        $drive = Join-SwCleanPath -Base $local -Rest @('Google', 'DriveFS')
        Invoke-SwAppOldFilesRow -Path (Join-SwCleanPath -Base $drive -Rest @('Logs')) -DaysOld 7 -Description 'Google Drive logs'
        $cutoff = (Get-Date).AddDays(-7)
        Invoke-SwAppTempFilesRow -Roots @($drive) -Description 'Google Drive temp' -Processes @('GoogleDriveFS') -Cutoff $cutoff
    }
    catch { Write-SwDebug "google drive caches not handled: $($_.Exception.Message)" }
}

function Clear-SwAdobeCaches {
    <#
    .SYNOPSIS
        The Adobe media cache and peak files (never Common itself or the Team Projects Cache).
    #>
    $ErrorActionPreference = 'Stop'
    try {
        $roaming = Get-SwDevBase -Name 'APPDATA'
        if ($null -eq $roaming) { return }
        Invoke-SwDevContentRow -Path (Join-SwCleanPath -Base $roaming -Rest @('Adobe', 'Common', 'Media Cache Files')) -Description 'Adobe cache'
        Invoke-SwDevContentRow -Path (Join-SwCleanPath -Base $roaming -Rest @('Adobe', 'Common', 'Peak Files')) -Description 'Adobe cache'
    }
    catch { Write-SwDebug "adobe caches not handled: $($_.Exception.Message)" }
}

function Clear-SwGamePlatformCaches {
    <#
    .SYNOPSIS
        The caches and logs of the Epic, EA, GOG, Ubisoft and Battle.net launchers. Games, saved games and
        libraries are not in this list.
    #>
    $ErrorActionPreference = 'Stop'
    try {
        $local = Get-SwDevBase -Name 'LOCALAPPDATA'
        $roaming = Get-SwDevBase -Name 'APPDATA'
        $shared = Get-SwDevBase -Name 'PROGRAMDATA'
        if ($null -ne $local) {
            Invoke-SwDevContentRow -Path (Join-SwCleanPath -Base $local -Rest @('EpicGamesLauncher', 'Saved', 'webcache')) -Description 'Epic Games webcache'
            Invoke-SwDevContentRow -Path (Join-SwCleanPath -Base $local -Rest @('EpicGamesLauncher', 'Saved', 'Logs')) -Description 'Epic Games Logs'
            Invoke-SwDevContentRow -Path (Join-SwCleanPath -Base $local -Rest @('Electronic Arts', 'EA Desktop', 'cache')) -Description 'EA/Origin cache'
            Invoke-SwDevContentRow -Path (Join-SwCleanPath -Base $local -Rest @('GOG.com', 'Galaxy', 'webcache')) -Description 'GOG Galaxy webcache'
        }
        if ($null -ne $shared) {
            Invoke-SwDevContentRow -Path (Join-SwCleanPath -Base $shared -Rest @('GOG.com', 'Galaxy', 'logs')) -Description 'GOG Galaxy logs'
        }
        if ($null -ne $local) {
            Invoke-SwDevContentRow -Path (Join-SwCleanPath -Base $local -Rest @('Ubisoft Game Launcher', 'cache')) -Description 'Ubisoft cache'
            Invoke-SwDevContentRow -Path (Join-SwCleanPath -Base $local -Rest @('Ubisoft Game Launcher', 'logs')) -Description 'Ubisoft logs'
        }
        if ($null -ne $roaming) {
            Invoke-SwDevContentRow -Path (Join-SwCleanPath -Base $roaming -Rest @('Battle.net', 'Cache')) -Description 'Battle.net Cache'
            Invoke-SwDevContentRow -Path (Join-SwCleanPath -Base $roaming -Rest @('Battle.net', 'Logs')) -Description 'Battle.net Logs'
        }
    }
    catch { Write-SwDebug "game platform caches not handled: $($_.Exception.Message)" }
}

# ============================================================================
# Game media
# ============================================================================

function Get-SwGameMediaCheck {
    # The condition that asks right before a file is removed whether it is still old: it exists, is no
    # folder and no link, and the newer of its creation and last write time is before the cutoff. Text, so
    # that it keeps the file and the cutoff when the removal helper runs it later; it needs no command.
    # Exactly one [bool] comes out, $false for anything unclear.
    param([string]$File, [datetime]$Cutoff)

    $source = '$p = ' + (ConvertTo-SwPsLiteral -Value $File) + '; $t = [long]' + $Cutoff.Ticks + '; ' +
        'try { $a = [System.IO.File]::GetAttributes($p); ' +
        'if (($a -band ([System.IO.FileAttributes]::ReparsePoint -bor [System.IO.FileAttributes]::Directory)) -ne 0) { $false } ' +
        'else { $c = [System.IO.File]::GetCreationTime($p); $w = [System.IO.File]::GetLastWriteTime($p); if ($w -gt $c) { $c = $w }; [bool]($c.Ticks -lt $t) } } ' +
        'catch { $false }'
    return [scriptblock]::Create($source)
}

function Clear-SwGameMedia {
    <#
    .SYNOPSIS
        The section "Game media": old recordings, replays and logs of game programs.
    .DESCRIPTION
        Only the folders the programs make themselves (NVIDIA, AMD, Medal, Overwolf, Fortnite, VALORANT,
        Apex) are searched, never Pictures, Videos or Documents as such. A file counts when the newer of
        its creation and last write time is strictly before now minus the days; links and cloud
        placeholders are never listed. Every file goes to Remove-SwItems on its own with a condition that
        checks its age once more right before the removal. A folder whose search is not complete adds
        nothing and is noted; the others still run. Negative days open and close the section and do
        nothing else; 0 means older than now.
    #>
    param([int]$DaysOld = 90)

    $ErrorActionPreference = 'Stop'
    Start-SwSection ('Game media (>' + $DaysOld + 'd old)')
    try {
        if ($DaysOld -lt 0) { return }
        $cutoff = (Get-Date).AddDays(-$DaysOld)
        $media = @('.mp4', '.mkv', '.avi', '.mov', '.wmv', '.webm', '.png', '.jpg', '.jpeg', '.bmp', '.gif')
        $profileRoot = Get-SwDevBase -Name 'USERPROFILE'
        $local = Get-SwDevBase -Name 'LOCALAPPDATA'

        # Name, base, folders below the base, extensions (none: every file).
        $sources = @(
            @{ Name = 'NVIDIA recordings'; Base = $profileRoot; Rests = @(@('Videos', 'NVIDIA'), @('Videos', 'ShadowPlay'), @('Videos', 'GeForce Experience')); Extensions = $media }
            @{ Name = 'AMD ReLive recordings'; Base = $profileRoot; Rests = @(@('Videos', 'Radeon ReLive'), @('Videos', 'AMD'), @('Videos', 'Radeon')); Extensions = $media }
            @{ Name = 'Medal.tv clips'; Base = $profileRoot; Rests = @(, @('Videos', 'Medal')); Extensions = $media }
            @{ Name = 'Overwolf/Outplayed recordings'; Base = $profileRoot; Rests = @(@('Videos', 'Overwolf'), @('Videos', 'Outplayed')); Extensions = $media }
            @{ Name = 'Fortnite replays'; Base = $local; Rests = @(, @('FortniteGame', 'Saved', 'Demos')); Extensions = @() }
            @{ Name = 'VALORANT logs'; Base = $local; Rests = @(, @('VALORANT', 'Saved', 'Logs')); Extensions = @() }
            @{ Name = 'Apex Legends temp files'; Base = $profileRoot; Rests = @(, @('Saved Games', 'Respawn', 'Apex', 'assets', 'temp')); Extensions = @() }
        )

        $chosen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($source in $sources) {
            if ($null -eq $source.Base) { continue }
            $description = $source.Name + ' (>' + $DaysOld + 'd)'
            foreach ($rest in $source.Rests) {
                try {
                    $root = Join-SwCleanPath -Base $source.Base -Rest $rest
                    if (@($source.Extensions).Count -gt 0) { $answer = Get-SwBoundedFileScan -Root $root -Extensions ([string[]]$source.Extensions) -OlderThan $cutoff }
                    else { $answer = Get-SwBoundedFileScan -Root $root -OlderThan $cutoff }
                    $found = Read-SwDevScan -Answer $answer -Name $source.Name -Root $root
                    if ($null -eq $found) { continue }
                    foreach ($file in $found) {
                        # A file counts once in a run, also when two folders deliver it.
                        if (-not $chosen.Add((ConvertTo-SwCleanCompare -Path $file))) { continue }
                        try { $null = Remove-SwItems -Paths ([string[]]@($file)) -Description $description -CanRemove (Get-SwGameMediaCheck -File $file -Cutoff $cutoff) }
                        catch { Write-SwDebug "file not offered, ${file}: $($_.Exception.Message)" }
                    }
                }
                catch { Write-SwDebug "folder not handled, $($source.Name): $($_.Exception.Message)" }
            }
        }
    }
    finally { Stop-SwSection }
}

# ============================================================================
# The section
# ============================================================================

function Invoke-SwAppCleanup {
    <#
    .SYNOPSIS
        The section "Applications": five groups in a fixed order; with -IncludeGameMedia the section "Game
        media" follows, after this one was closed. Writes nothing to the pipeline; a failing group stops
        only itself.
    #>
    param(
        [switch]$IncludeGameMedia,
        [int]$GameMediaDaysOld = 90
    )

    $ErrorActionPreference = 'Stop'
    Start-SwSection 'Applications'
    try {
        foreach ($group in 'Clear-SwOfficeCache', 'Clear-SwOneDriveCache', 'Clear-SwGoogleDriveCache', 'Clear-SwAdobeCaches', 'Clear-SwGamePlatformCaches') {
            try { $null = & $group }
            catch { Write-SwDebug "$group failed: $($_.Exception.Message)" }
        }
    }
    finally { Stop-SwSection }

    if ($IncludeGameMedia) {
        try { $null = Clear-SwGameMedia -DaysOld $GameMediaDaysOld }
        catch { Write-SwDebug "game media failed: $($_.Exception.Message)" }
    }
}

# ============================================================================
# Old names, kept as forwarding functions (not aliases, so a test mock of either name behaves) until the
# callers move to the new ones. The switch of the removed search for orphaned application data is
# accepted and does nothing.
# ============================================================================

function Invoke-AppCleanup {
    param(
        [switch]$IncludeOrphaned,
        [switch]$IncludeGameMedia,
        [int]$GameMediaDaysOld = 90
    )
    $null = $IncludeOrphaned
    Invoke-SwAppCleanup -IncludeGameMedia:$IncludeGameMedia -GameMediaDaysOld $GameMediaDaysOld
}

function Clear-OfficeCache { Clear-SwOfficeCache }
function Clear-OneDriveCache { Clear-SwOneDriveCache }
function Clear-GoogleDriveCache { Clear-SwGoogleDriveCache }
function Clear-AdobeData { Clear-SwAdobeCaches }
function Clear-GamingPlatformCaches { Clear-SwGamePlatformCaches }

function Clear-GameMediaFiles {
    param([int]$DaysOld = 90)
    Clear-SwGameMedia -DaysOld $DaysOld
}

$script:SWEEPR_CLEAN_APPS_LOADED = $true
