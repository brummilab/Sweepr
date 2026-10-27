# Sweepr - installed version and module search path
#
# Loaded by dot-sourcing, on its own: it needs no other Sweepr module and only defines functions and
# the built-in fallback version. Loading it twice is harmless. It deliberately leaves the caller's
# strict mode and error preference alone; every caller sets its own.

# Built-in fallback when an installation has no VERSION file. A version bump changes this value and
# the VERSION file in the same commit (a test keeps both equal).
$script:SwFallbackVersion = '0.1.0'

# Transition name until the release documentation and its callers move to the new one.
$script:SweeprDefaultVersion = $script:SwFallbackVersion

function Get-SwInstalledVersion {
    <#
    .SYNOPSIS
        Version string of the installation in RootDir, read from its VERSION file.
    .DESCRIPTION
        The content is returned as it is, only stripped of surrounding blanks, line ends and a BOM;
        callers decide whether it is a valid version. RootDir is a literal path. A missing root,
        missing or blank VERSION gives the fallback; a VERSION that exists but cannot be read is an
        error, because a wrong version would mislead downloads and update checks.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$RootDir,
        [AllowNull()][AllowEmptyString()][string]$DefaultVersion
    )

    $fallback = $DefaultVersion
    if (-not $PSBoundParameters.ContainsKey('DefaultVersion')) { $fallback = $script:SwFallbackVersion }

    if ([string]::IsNullOrWhiteSpace($RootDir)) { return $fallback }

    # .NET file APIs never expand wildcards, so [ ] * ? and quotes in folder names stay literal.
    $file = [System.IO.Path]::Combine($RootDir, 'VERSION')
    $isFile = [System.IO.File]::Exists($file)
    $isFolder = [System.IO.Directory]::Exists($file)
    if (-not $isFile -and -not $isFolder) { return $fallback }
    if ($isFolder) { throw "Cannot read the version file, it is a folder: $file" }

    $text = [System.IO.File]::ReadAllText($file)
    $text = $text.Trim([char]0xFEFF, [char]0x20, [char]0x09, [char]0x0D, [char]0x0A)
    if ($text.Length -eq 0) { return $fallback }
    return [string]$text
}

function Repair-SwModuleSearchPath {
    <#
    .SYNOPSIS
        Removes PowerShell 7 module folders from PSModulePath of this Windows PowerShell process.
    .DESCRIPTION
        sw.cmd and sw.exe always start Windows PowerShell 5.1. Started from a pwsh 7 terminal it
        inherits the pwsh 7 module folders first and then loads pwsh 7 builds of shared modules,
        which breaks commands such as Get-FileHash. Only the current process changes.
    #>
    param(
        [ValidateSet('Desktop', 'Core')]
        [string]$Edition
    )

    if (-not $PSBoundParameters.ContainsKey('Edition')) {
        $Edition = 'Desktop'
        $current = $PSVersionTable['PSEdition']
        if ($null -ne $current -and [string]$current -eq 'Core') { $Edition = 'Core' }
    }
    if ($Edition -ne 'Desktop') { return }

    $original = $env:PSModulePath
    if ([string]::IsNullOrEmpty($original)) { return }

    $windowsRoot = $env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($windowsRoot)) { $windowsRoot = 'C:\Windows' }
    $systemModules = $windowsRoot.TrimEnd('\') + '\System32\WindowsPowerShell\v1.0\Modules'

    $kept = New-Object System.Collections.Generic.List[string]
    $hasSystemModules = $false
    foreach ($entry in $original.Split(';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        # A folder named exactly "PowerShell" or the Store package marks a pwsh 7 location;
        # "WindowsPowerShell" does not match because the backslash must come right before it.
        $probe = $entry + '\'
        if ($probe.IndexOf('\PowerShell\', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { continue }
        if ($entry.IndexOf('\Microsoft.PowerShell_', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { continue }
        if ([string]::Equals($entry.TrimEnd('\'), $systemModules, [System.StringComparison]::OrdinalIgnoreCase)) {
            $hasSystemModules = $true
        }
        $kept.Add($entry)
    }
    if (-not $hasSystemModules) { $kept.Add($systemModules) }

    $env:PSModulePath = [string]::Join(';', $kept.ToArray())
}

# Old names, kept as forwarding functions (not aliases, so test mocks of either name behave) until
# their callers are rewritten.
function Get-SweeprVersionString {
    param(
        [AllowNull()][AllowEmptyString()][string]$RootDir,
        [AllowNull()][AllowEmptyString()][string]$DefaultVersion
    )
    Get-SwInstalledVersion @PSBoundParameters
}

function Repair-SweeprModulePath {
    param(
        [ValidateSet('Desktop', 'Core')]
        [string]$Edition
    )
    Repair-SwModuleSearchPath @PSBoundParameters
}
