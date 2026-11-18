# Sweepr - Clean Command
# Frees up space: old temp files, error reports and log files, browser, application and (on request)
# GPU shader caches, developer tool caches, application leftovers and, for an administrator on
# request, old Windows error reports. --dry-run shows what a real run would remove and writes the
# list to a file. This script holds the options, the help, the whitelist editor, the run (header,
# preview list, system hint, summary) and the exit code; the sections are in lib\clean, and every
# removal goes through the helpers of lib\core\file_ops.ps1.
#
# Dot-sourcing the file (. .\clean.ps1) defines the functions and loads the modules and returns: no
# run, no exit, no output, no file. Otherwise it runs. Exit codes: 0 the help was shown, the whitelist
# editor ended, or the run reached its summary (single targets that could not be removed do not
# change that); 1 the run could not start or a section broke off with an unexpected error. The
# router returns 2 for an option it does not know.

#Requires -Version 5.1
[CmdletBinding(PositionalBinding = $false)]
param(
    [Alias('dry-run')]
    [switch]$DryRun,

    [Alias('s')]
    [switch]$System,

    [Alias('game-media')]
    [switch]$GameMedia,

    [Alias('gpu-shaders')]
    [switch]$GpuShaders,

    [Alias('d')]
    [switch]$DebugMode,

    [Alias('w')]
    [switch]$Whitelist,

    [Alias('h')]
    [switch]$ShowHelp
)

# ============================================================================
# Loading check
# ============================================================================

function Get-SwPathCollision {
    <#
    .SYNOPSIS
        A message when Windows PowerShell 5.1 would take another folder than Path, otherwise $null.
    .DESCRIPTION
        Windows PowerShell 5.1 reads [ ] * ? in a path that is loaded as a pattern, so a folder called
        Tools [USB] also matches a folder called Tools U, and the files of the wrong folder could be
        used. PowerShell 7 takes an existing path literally. Only the edition Desktop (the running
        edition when none is given) and only a path with one of these characters can collide: the path
        is resolved as a pattern, and a match other than the literal folder is a collision. A path
        that cannot be resolved is used as it is, so it is no collision. Never throws.
    #>
    param([string]$Path, [string]$Edition)

    try {
        if ([string]::IsNullOrEmpty($Edition)) { $Edition = [string]$PSVersionTable.PSEdition }
        if ($Edition -cne 'Desktop') { return $null }
        if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
        if ($Path.IndexOfAny([char[]]'[]*?') -lt 0) { return $null }

        $found = @()
        try {
            $provider = $null
            $found = @($ExecutionContext.SessionState.Path.GetResolvedProviderPathFromPSPath($Path, [ref]$provider))
        }
        catch { return $null }

        $literal = [System.IO.Path]::GetFullPath($Path)
        foreach ($item in $found) {
            if (-not [string]::Equals([System.IO.Path]::GetFullPath([string]$item), $literal, [System.StringComparison]::OrdinalIgnoreCase)) {
                $text = 'Sweepr cannot use the folder ' + $Path + ': a folder name with [ ] * or ? is read as a pattern by Windows PowerShell 5.1, and here it also matches ' +
                    [string]$item + '. Rename or move the installation to a folder without these characters.'
                return [regex]::Replace($text, '[\x00-\x1F\x7F-\x9F]', ' ')
            }
        }
        return $null
    }
    catch { return $null }
}

# ============================================================================
# Small helpers
# ============================================================================

function Test-SwCleanFullPath {
    # A path that means the same place for every API: a drive letter with a separator, and on hosts
    # without drive letters a leading slash. Relative, root-relative, drive-relative and UNC paths are
    # not full paths.
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path.IndexOf([char]0) -ge 0) { return $false }
    if ([regex]::IsMatch($Path, '\A[A-Za-z]:[\\/]')) { return $true }
    if ([System.IO.Path]::DirectorySeparatorChar -eq '/' -and $Path.StartsWith('/', [System.StringComparison]::Ordinal)) { return $true }
    return $false
}

function Get-SwCleanConfigValue {
    # One entry of the configuration table, trimmed, or an empty string when the table or the entry is
    # missing. Tests replace the table by one that holds only some keys.
    param([string]$Key)

    try {
        $config = $script:Config
        if ($config -is [System.Collections.IDictionary] -and $config.Contains($Key) -and $null -ne $config[$Key]) { return ([string]$config[$Key]).Trim() }
    }
    catch { $null = $_ }
    return ''
}

function Get-SwCleanListFile {
    # The file of the preview list for this run, or an empty string when there is none.
    try {
        $variable = Get-Variable -Name 'ExportListFile' -Scope Script -ErrorAction SilentlyContinue
        if ($null -eq $variable -or $null -eq $variable.Value) { return '' }
        return ([string]$variable.Value)
    }
    catch { return '' }
}

# ============================================================================
# Help
# ============================================================================

function Show-SwCleanHelp {
    <#
    .SYNOPSIS
        Writes the help of sw clean to the host. Touches no state and needs no data folder.
    #>
    $yellow = [string](Get-SwColor -Name 'Yellow')
    $purple = [string](Get-SwColor -Name 'PurpleBold')
    $gray = [string](Get-SwColor -Name 'Gray')
    $reset = [string](Get-SwColor -Name 'NC')

    Write-Host ''
    Write-Host ($purple + 'sw clean' + $reset + ' - Free up disk space')
    Write-Host ''
    Write-Host ($yellow + 'Usage:' + $reset + ' sw clean [options]')
    Write-Host ''
    Write-Host ($yellow + 'Options:' + $reset)
    Write-Host '  --dry-run           Show what would be removed and write the list to a file; nothing is changed'
    Write-Host '  -s, --system        Also remove old Windows error reports below ProgramData (administrator only)'
    Write-Host '  --game-media        Also remove old game recordings (older than 90 days)'
    Write-Host '  --gpu-shaders       Also empty GPU shader caches (games compile their shaders again at the next start)'
    Write-Host '  -w, --whitelist     Open the whitelist, the list of paths that are never cleaned; ignores --dry-run'
    Write-Host '  -d, --debug         Show diagnostic lines'
    Write-Host '  -h, --help          Show this help'
    Write-Host ''
    Write-Host ($yellow + 'Examples:' + $reset)
    Write-Host '  sw clean --dry-run                 Preview, change nothing'
    Write-Host '  sw clean                           Clean'
    Write-Host '  sw clean --gpu-shaders --dry-run   Preview including GPU shader caches'
    Write-Host '  sw clean --whitelist               Edit the list of protected paths'
    Write-Host '  sw clean -s                        Include the system part (needs administrator rights)'
    Write-Host ''
    Write-Host ($gray + 'Sweepr never asks for administrator rights. An elevated run cleans the caches of the elevated account,' + $reset)
    Write-Host ($gray + 'which is another account when you elevate with the credentials of another administrator.' + $reset)
    Write-Host ($gray + 'Run sw clean --dry-run first: it lists every path, and a path in the whitelist is never touched.' + $reset)
    Write-Host ''
}

# ============================================================================
# Whitelist editor
# ============================================================================

function Get-SwWhitelistTemplate {
    # The text of a new whitelist file. Every line is a comment or empty, so the examples protect
    # nothing until the user takes the # away. The example folder is spelled with the resolved value
    # of LOCALAPPDATA, or with the variable when it is not set.
    $local = [System.Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    if ([string]::IsNullOrWhiteSpace($local)) { $example = '%LOCALAPPDATA%\CriticalApp' }
    else { $example = $local.Trim().TrimEnd([char[]]@('\', '/')) + '\CriticalApp' }

    $lines = @(
        '# Sweepr Whitelist'
        '#'
        '# Paths listed here are never cleaned by Sweepr, not in a preview and not in a real run.'
        '# One path per line. Lines that start with # are comments; empty lines are ignored.'
        '# A listed folder protects everything below it.'
        '#'
        '# Forms that are understood:'
        '#   a full path                         C:\Users\Name\Projects\Keep'
        '#   a path in quotes                    "C:\Program Files\Tool\Cache"'
        '#   / instead of \                      C:/Users/Name/Projects/Keep'
        '#   an environment variable in %...%    %LOCALAPPDATA%\MyTool'
        '#   ~ for your profile folder           ~\Documents\Keep'
        '#   * as a wildcard                     %LOCALAPPDATA%\Packages\*'
        '#'
        '# The lines below are examples. Remove the # at the start of a line to use it.'
        '#'
        '# C:\Users\Name\Projects\Keep'
        '# ~\Documents\Keep'
        ('# ' + $example)
        ''
    )
    return (($lines -join "`r`n"))
}

function Edit-SwWhitelist {
    <#
    .SYNOPSIS
        Creates the whitelist file from the template when it is missing and opens it in Notepad.
    .DESCRIPTION
        Throws, with the path and the reason, when the file path is empty or not a full path, when the
        folder or the file cannot be created and when Notepad cannot be started. A file that exists is
        never written to, not even when it is empty or a link; it is opened as it is. The file is
        created with FileMode.CreateNew, so it can never replace anything. Every path access is
        literal. Notepad comes from the system folder and gets exactly one argument, the quoted path.
    #>
    $ErrorActionPreference = 'Stop'
    $path = Get-SwCleanConfigValue -Key 'WhitelistFile'
    if ($path.Length -eq 0) { throw 'The path of the whitelist file is not set.' }
    if (-not (Test-SwCleanFullPath -Path $path)) { throw "The path of the whitelist file is not a full path: $path" }

    $folder = [System.IO.Path]::GetDirectoryName($path)
    try { [void][System.IO.Directory]::CreateDirectory($folder) }
    catch { throw "Cannot create the folder of the whitelist file: $folder ($($_.Exception.Message))" }

    # An existing entry, a link included, is left as it is; only a name that is free gets the template.
    $exists = $false
    try {
        [void][System.IO.File]::GetAttributes($path)
        $exists = $true
    }
    catch [System.IO.FileNotFoundException] { $exists = $false }
    catch [System.IO.DirectoryNotFoundException] { $exists = $false }
    if (-not $exists) {
        $utf8 = New-Object System.Text.UTF8Encoding($true)
        $bytes = [byte[]]($utf8.GetPreamble() + $utf8.GetBytes((Get-SwWhitelistTemplate)))
        try {
            $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try { $stream.Write($bytes, 0, $bytes.Length) }
            finally { $stream.Dispose() }
        }
        catch [System.IO.IOException] {
            # Created by someone else in the meantime: that file is the whitelist, it stays as it is.
            if (-not [System.IO.File]::Exists($path)) { throw "Cannot create the whitelist file: $path ($($_.Exception.Message))" }
        }
        catch { throw "Cannot create the whitelist file: $path ($($_.Exception.Message))" }
    }

    # The editor comes from the system folder, not from PATH, and the path is one quoted argument, so
    # a space, a parenthesis or a bracket in it cannot split it.
    $editor = [System.IO.Path]::Combine([System.Environment]::SystemDirectory, 'notepad.exe')
    try { Start-Process -FilePath $editor -ArgumentList ('"' + $path + '"') -Wait }
    catch { throw "Cannot start the editor for the whitelist file: $path ($($_.Exception.Message))" }
    Write-SwInfo "The editor was closed. The whitelist is read at the start of every run: $path"
}

# ============================================================================
# Summary
# ============================================================================

function Get-SwCleanStat {
    # One number of the statistics; a key that is missing or not a number counts as 0.
    param($Stats, [string]$Key)

    try {
        if ($Stats -is [System.Collections.IDictionary] -and $Stats.Contains($Key) -and $null -ne $Stats[$Key]) { return [long]$Stats[$Key] }
    }
    catch { $null = $_ }
    return [long]0
}

function Show-SwCleanSummary {
    <#
    .SYNOPSIS
        The closing frame of a run: the result, the free space and, after a preview, the list file.
    .DESCRIPTION
        One call of Show-SwResultFrame. Stats is the table of Get-SwCleanupStats; a missing key counts as
        0. A preview names the potential space and the number of entries, a real run what was freed;
        only tool commands are told apart from nothing at all. A preview that found something names the
        list file, when there is one.
    #>
    param([hashtable]$Stats, [bool]$IsDryRun)

    $kilobytes = Get-SwCleanStat -Stats $Stats -Key 'TotalSizeKB'
    $entries = Get-SwCleanStat -Stats $Stats -Key 'FilesCleaned'
    $owner = Get-SwCleanStat -Stats $Stats -Key 'OwnerCleanups'

    $details = [System.Collections.Generic.List[string]]::new()
    if ($kilobytes -gt 0) {
        $size = Format-SwByteSize -Bytes ($kilobytes * 1024)
        if ($IsDryRun) { $details.Add("Potential space: $size | Items: $entries") }
        else { $details.Add("Space freed: $size | Items: $entries") }
    }
    elseif ($owner -gt 0) {
        if ($IsDryRun) { $details.Add('Tool caches are listed for review') }
        else { $details.Add('Tool cache cleanup completed') }
    }
    else {
        if ($IsDryRun) { $details.Add('No notable space found') }
        else { $details.Add('Nothing to remove, your system is already clean') }
    }
    $details.Add('Free space: ' + (Get-SwFreeSpace))

    $listFile = Get-SwCleanListFile
    if ($IsDryRun -and ($kilobytes -gt 0 -or $owner -gt 0) -and $listFile.Length -gt 0) {
        $details.Add('Detailed file list: ' + $listFile)
    }

    $heading = 'Cleanup complete'
    if ($IsDryRun) { $heading = 'Dry run complete - no changes made' }
    Show-SwResultFrame -Heading $heading -Details ([string[]]$details.ToArray())
}

# ============================================================================
# The run
# ============================================================================

function Initialize-SwCleanPreviewList {
    # Prepares the file of the preview list: the folder, and the file new or emptied, with the header.
    # Without a usable file the run goes on without a list: ExportListFile is then $null, so the helpers
    # append nothing and the summary names no file. An existing file is replaced only here, in a preview.
    $path = Get-SwCleanListFile
    if (-not (Test-SwCleanFullPath -Path $path)) {
        $script:ExportListFile = $null
        Write-SwInfo 'No file list is written: the Sweepr data folder is not known.'
        return
    }

    $kind = ''
    try {
        $attributes = [System.IO.File]::GetAttributes($path)
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { $kind = 'a link' }
        elseif (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) { $kind = 'a folder' }
    }
    catch [System.IO.FileNotFoundException] { $kind = '' }
    catch [System.IO.DirectoryNotFoundException] { $kind = '' }
    catch {
        $script:ExportListFile = $null
        Write-SwWarning "Cannot prepare the file list $path ($($_.Exception.Message)). The preview continues without it."
        return
    }
    if ($kind.Length -gt 0) {
        $script:ExportListFile = $null
        Write-SwWarning "The file list $path is $kind and is left as it is. The preview continues without a list."
        return
    }

    $time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
    $whitelistFile = Get-SwCleanConfigValue -Key 'WhitelistFile'
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Sweepr Cleanup Preview - ' + $time)
    $lines.Add('#')
    $lines.Add('# Every path below would be removed by a real run. Nothing was removed.')
    $lines.Add('# To keep a path, copy it into the whitelist file and run the preview again.')
    if ($whitelistFile.Length -gt 0) { $lines.Add('# Whitelist file: ' + $whitelistFile) }
    else { $lines.Add('# The whitelist file is in the Sweepr data folder.') }
    $lines.Add('# Open it with: sw clean --whitelist')
    $lines.Add('')
    try {
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($path))
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($path, (($lines -join "`r`n") + "`r`n"), $utf8)
    }
    catch {
        $script:ExportListFile = $null
        Write-SwWarning "Cannot prepare the file list $path ($($_.Exception.Message)). The preview continues without it."
    }
}

function Start-SwCleanRun {
    <#
    .SYNOPSIS
        One run: header, preview list, system hint, the sections, the summary. Gives 0 or 1.
    .DESCRIPTION
        Never throws. The dry-run state and the path guard are set here, before the first section, so a
        direct call is safe too. An exception of a section is reported and gives 1, and the summary
        still follows. An exception anywhere else (header, summary) is reported and gives 1.
    #>
    param(
        [Parameter(Mandatory = $true)][bool]$IsDryRun,
        [bool]$IncludeSystem = $false,
        [bool]$IncludeGameMedia = $false,
        [bool]$IncludeGpuShaders = $false
    )

    $ErrorActionPreference = 'Stop'
    $result = 0
    try {
        $redirected = $false
        try { $redirected = [bool](Test-SwOutputRedirected) }
        catch { $redirected = $false }
        if (-not $redirected) {
            try { Clear-Host }
            catch { $null = $_ }
        }

        $purple = [string](Get-SwColor -Name 'PurpleBold')
        $yellow = [string](Get-SwColor -Name 'Yellow')
        $gray = [string](Get-SwColor -Name 'Gray')
        $reset = [string](Get-SwColor -Name 'NC')
        Write-Host ''
        Write-Host ($purple + 'Clean Your Windows' + $reset)
        Write-Host ''

        if ($IsDryRun) {
            Write-Host ($yellow + 'Dry Run Mode' + $reset + ' - Preview only, no deletions')
            Initialize-SwCleanPreviewList
        }
        else {
            Write-Host ($gray + 'Tip: sw clean --dry-run shows what would be removed; sw clean --whitelist protects paths.' + $reset)
        }

        # The system part runs only for a caller that already has administrator rights; it is never asked for.
        if ($IncludeSystem) {
            $isAdmin = $false
            try {
                $answer = @(Test-SwAdmin)
                $isAdmin = (($answer.Count -eq 1) -and ($answer[0] -is [bool]) -and ($answer[0] -eq $true))
            }
            catch { $isAdmin = $false }
            if ($isAdmin) {
                if (-not $IsDryRun) { Write-SwInfo 'Running with administrator rights: the system part is included.' }
            }
            else {
                $IncludeSystem = $false
                if ($IsDryRun) { Write-SwInfo 'The system part is not in this preview because administrator rights are missing.' }
                else { Write-SwWarning 'The system part (--system) needs administrator rights, so it is skipped. Start Sweepr from a PowerShell window that runs as administrator to include it.' }
            }
        }

        $windows = Get-SwWindowsVersion
        Write-Host ($gray + [string]$windows['Name'] + ' | Free space: ' + (Get-SwFreeSpace) + $reset)

        $null = Reset-SwCleanupStats
        $null = Set-SwDryRunMode -Enabled $IsDryRun
        # The guard adds the stricter rules of sw clean (browser profile and key folders, the Teams web
        # view exception); it stays on after the run.
        $script:SweeprCleanPathGuard = $true
        try {
            $null = Invoke-SweeprCleanSections -IncludeSystem $IncludeSystem -IncludeGameMedia $IncludeGameMedia -IncludeGpuShaders $IncludeGpuShaders
        }
        catch {
            Write-SwError "A cleanup section stopped with an error: $($_.Exception.Message)"
            $result = 1
        }
        finally {
            try { $script:CurrentSection['Active'] = $false }
            catch { $null = $_ }
            $null = Stop-SwSpinner
        }

        Show-SwCleanSummary -Stats (Get-SwCleanupStats) -IsDryRun $IsDryRun
    }
    catch {
        Write-SwError "The cleanup run failed: $($_.Exception.Message)"
        $result = 1
    }
    return [int]$result
}

# ============================================================================
# Options
# ============================================================================

function Invoke-SwCleanMain {
    <#
    .SYNOPSIS
        Works through the options in a fixed order and gives the exit code as one [int].
    .DESCRIPTION
        Debug mode first, then the help (nothing else happens), then the whitelist editor (no run),
        otherwise the run. SWEEPR_DRY_RUN decides the mode too: every value but empty and 0 means a
        preview. Never throws; an unexpected error is reported and gives 1.
    #>
    param(
        [bool]$DryRun = $false,
        [bool]$System = $false,
        [bool]$GameMedia = $false,
        [bool]$GpuShaders = $false,
        [bool]$DebugMode = $false,
        [bool]$Whitelist = $false,
        [bool]$ShowHelp = $false
    )

    $ErrorActionPreference = 'Stop'
    try {
        if ($DebugMode) { $null = Enable-SwDebugMode }
        if ($ShowHelp) {
            $null = Show-SwCleanHelp
            return 0
        }
        if ($Whitelist) {
            $null = Edit-SwWhitelist
            return 0
        }

        $preview = $DryRun
        if (-not $preview) {
            $setting = [System.Environment]::GetEnvironmentVariable('SWEEPR_DRY_RUN')
            if ($null -ne $setting) {
                $setting = $setting.Trim()
                if ($setting.Length -gt 0 -and $setting -ne '0') { $preview = $true }
            }
        }
        $value = '0'
        if ($preview) { $value = '1' }
        [System.Environment]::SetEnvironmentVariable('SWEEPR_DRY_RUN', $value)

        $answer = @(Start-SwCleanRun -IsDryRun $preview -IncludeSystem $System -IncludeGameMedia $GameMedia -IncludeGpuShaders $GpuShaders)
        if ($answer.Count -eq 0) { return 0 }
        return [int]$answer[$answer.Count - 1]
    }
    catch {
        Write-SwError "sw clean failed: $($_.Exception.Message)"
        return 1
    }
}

# ============================================================================
# Start
# ============================================================================

$script:SwCleanDotSourced = ($MyInvocation.InvocationName -eq '.')

if (-not $script:SwCleanDotSourced) {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
}

# The installation folder is checked before the first module is loaded: under Windows PowerShell 5.1 a
# folder name with [ ] * ? could make the load take the files of another folder.
try {
    $script:SwCleanProblem = Get-SwPathCollision -Path ([System.IO.Path]::GetDirectoryName($PSScriptRoot))
    if ($null -ne $script:SwCleanProblem) { throw $script:SwCleanProblem }
    . ([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PSScriptRoot), 'lib', 'core', 'base.ps1'))
    . ([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PSScriptRoot), 'lib', 'core', 'log.ps1'))
    . ([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PSScriptRoot), 'lib', 'core', 'file_ops.ps1'))
    . ([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PSScriptRoot), 'lib', 'core', 'ui.ps1'))
    . ([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PSScriptRoot), 'lib', 'clean', 'preview.ps1'))
}
catch {
    if ($script:SwCleanDotSourced) { throw }
    # The writers of the log module may not be loaded, so the message goes straight to the error output,
    # without control characters.
    [Console]::Error.WriteLine([regex]::Replace('Sweepr cannot start: ' + $_.Exception.Message, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]', ' '))
    exit 1
}

if (-not $script:SwCleanDotSourced) {
    # The list of a preview is clean-list.txt in the configuration folder, which is not created here.
    $script:ExportListFile = $null
    $script:SwCleanConfigFolder = Get-SwCleanConfigValue -Key 'ConfigPath'
    if (Test-SwCleanFullPath -Path $script:SwCleanConfigFolder) { $script:ExportListFile = [System.IO.Path]::Combine($script:SwCleanConfigFolder, 'clean-list.txt') }

    $script:SwCleanExit = Invoke-SwCleanMain -DryRun $DryRun.IsPresent -System $System.IsPresent -GameMedia $GameMedia.IsPresent `
        -GpuShaders $GpuShaders.IsPresent -DebugMode $DebugMode.IsPresent -Whitelist $Whitelist.IsPresent -ShowHelp $ShowHelp.IsPresent
    if ($script:SwCleanExit -ne 0) { exit $script:SwCleanExit }
}
