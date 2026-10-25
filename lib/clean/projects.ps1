# Sweepr - Project Discovery Module
# Finds project build artifacts (node_modules, venv, target ...) for sw purge and the read-only preview

#Requires -Version 5.1
Set-StrictMode -Version Latest

# Prevent multiple sourcing
if ((Get-Variable -Name 'SWEEPR_CLEAN_PROJECTS_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:SWEEPR_CLEAN_PROJECTS_LOADED) { return }
$script:SWEEPR_CLEAN_PROJECTS_LOADED = $true

# Import dependencies
# $PSScriptRoot, not a variable the loaded modules overwrite: each of them sets its own $scriptDir.
. "$PSScriptRoot\..\core\base.ps1"
. "$PSScriptRoot\..\core\log.ps1"
. "$PSScriptRoot\..\core\file_ops.ps1"

# ============================================================================
# Configuration
# ============================================================================

$script:DefaultSearchPaths = @(
    "$env:USERPROFILE\Documents"
    "$env:USERPROFILE\Projects"
    "$env:USERPROFILE\Code"
    "$env:USERPROFILE\Development"
    "$env:USERPROFILE\workspace"
    "$env:USERPROFILE\github"
    "$env:USERPROFILE\repos"
    "$env:USERPROFILE\src"
    "D:\Projects"
    "D:\Code"
    "D:\Development"
)

# Artifact patterns to clean
$script:ArtifactPatterns = @(
    @{ Name = "node_modules"; Type = "Directory"; Language = "JavaScript/Node.js" }
    @{ Name = "vendor"; Type = "Directory"; Language = "PHP/Go" }
    @{ Name = ".venv"; Type = "Directory"; Language = "Python" }
    @{ Name = "venv"; Type = "Directory"; Language = "Python" }
    @{ Name = "__pycache__"; Type = "Directory"; Language = "Python" }
    @{ Name = ".pytest_cache"; Type = "Directory"; Language = "Python" }
    @{ Name = "target"; Type = "Directory"; Language = "Rust/Java" }
    @{ Name = "build"; Type = "Directory"; Language = "General" }
    @{ Name = "dist"; Type = "Directory"; Language = "General" }
    @{ Name = ".next"; Type = "Directory"; Language = "Next.js" }
    @{ Name = ".nuxt"; Type = "Directory"; Language = "Nuxt.js" }
    @{ Name = ".turbo"; Type = "Directory"; Language = "Turborepo" }
    @{ Name = ".parcel-cache"; Type = "Directory"; Language = "Parcel" }
    @{ Name = "bin"; Type = "Directory"; Language = ".NET" }
    @{ Name = "obj"; Type = "Directory"; Language = ".NET" }
    @{ Name = ".gradle"; Type = "Directory"; Language = "Java/Gradle" }
    @{ Name = "*.log"; Type = "File"; Language = "Logs" }
)

# Candidates a safety check (Git) could not confirm; Get-SweeprPurgePreview reports them.
$script:PurgeUnverified = 0

# ============================================================================
# Project Discovery
# ============================================================================

# Run only read-only Git queries. The child must not inherit a redirected index,
# repository, pathspec mode, configuration or fsmonitor hook from the caller.
function Invoke-PurgeGit {
    param([string]$ProjectPath, [string[]]$Arguments)
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $git) { return $null }
    $quote = {
        param([string]$Value)
        $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
        $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
        return '"' + $escaped + '"'
    }
    $words = @('-c', 'core.fsmonitor=false', '-C', $ProjectPath) + $Arguments
    $process = New-Object Diagnostics.Process
    $process.StartInfo = New-Object Diagnostics.ProcessStartInfo
    $process.StartInfo.FileName = $git.Source
    $process.StartInfo.Arguments = ($words | ForEach-Object { & $quote $_ }) -join ' '
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $process.StartInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($key in @($process.StartInfo.EnvironmentVariables.Keys)) {
        if ($key -like 'GIT_*') { $process.StartInfo.EnvironmentVariables.Remove($key) }
    }
    $process.StartInfo.EnvironmentVariables['GIT_CONFIG_NOSYSTEM'] = '1'
    $process.StartInfo.EnvironmentVariables['GIT_CONFIG_GLOBAL'] = '/dev/null'
    $process.StartInfo.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(5000)) {
            $process.Kill()
            return $null
        }
        if (-not $stdout.Wait(1000) -or -not $stderr.Wait(1000) -or $process.ExitCode -ne 0) { return $null }
        return @{ Output = $stdout.Result }
    }
    catch { return $null }
    finally { $process.Dispose() }
}

function Test-PurgeArtifactKind {
    param([string]$ProjectPath, [string]$Name)
    try {
        $files = @(Get-ChildItem -LiteralPath $ProjectPath -File -Force -ErrorAction Stop)
        $names = @($files | ForEach-Object Name)
        switch ($Name) {
            '.idea' { return $false }
            'bin' { return @($names -match '\.(cs|fs|vb)proj$').Count -gt 0 }
            'obj' { return @($names -match '\.(cs|fs|vb)proj$').Count -gt 0 }
            'target' { return $names -contains 'Cargo.toml' -or $names -contains 'pom.xml' }
            'vendor' { return $names -contains 'go.mod' -or $names -contains 'composer.json' }
            { $_ -eq 'build' -or $_ -eq 'dist' } {
                if ($Name -eq 'build' -and ($names -contains 'build.gradle' -or $names -contains 'build.gradle.kts' -or $names -contains 'CMakeLists.txt')) { return $true }
                if ($names -contains 'setup.py') { return $true }
                if ($names -contains 'pyproject.toml') {
                    if ((Get-Content -LiteralPath (Join-Path $ProjectPath 'pyproject.toml') -Raw -ErrorAction Stop) -match '(?m)^\s*\[build-system\]') { return $true }
                }
                if ($names -contains 'package.json') {
                    $package = Get-Content -LiteralPath (Join-Path $ProjectPath 'package.json') -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    if ($package.PSObject.Properties['scripts'] -and $package.scripts -and $package.scripts.PSObject.Properties['build']) {
                        return $package.scripts.build -is [string] -and -not [string]::IsNullOrWhiteSpace($package.scripts.build)
                    }
                }
                return $false
            }
            default { return $true }
        }
    }
    catch { return $false }
}

# Eligibility is checked at discovery and again after the delete helper sizes
# the candidate. Neither a familiar directory name nor Git ignore state proves
# that its contents are disposable.
function Test-PurgeArtifactContent {
    param([string]$ProjectPath, [string]$Path)
    try {
        $snapshot = Get-SweeprPathSnapshot -Path $Path
        if (-not $snapshot -or -not (Test-PurgeArtifactKind $ProjectPath ([IO.Path]::GetFileName($Path)))) { return $false }
        $project = [IO.Path]::GetFullPath($ProjectPath).TrimEnd('\')
        if (-not [string]::Equals([IO.Path]::GetDirectoryName($snapshot.Path), $project, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        if (Test-Path -LiteralPath $Path -PathType Container) {
            foreach ($child in Get-TreeItemsNoFollow -Path $Path) {
                if ($child.Name -eq '.git') { return $false }
            }
        }
        # Determine repository membership without turning a failed Git command
        # into evidence that this is an unversioned directory.
        $ancestor = $project
        $hasRepository = $false
        while ($ancestor) {
            if (-not (Get-SweeprPathSnapshot -Path $ancestor)) { return $false }
            try {
                # PS 5.1's provider can return null without an error for a
                # missing literal child of a bracket-named directory. Read the
                # filesystem attribute directly, preserving unknown failures.
                $null = [IO.File]::GetAttributes((Join-Path $ancestor '.git'))
                $hasRepository = $true
                break
            }
            catch {
                $failure = $_.Exception
                while ($failure.InnerException) { $failure = $failure.InnerException }
                $code = $failure.HResult -band 0xFFFF
                if ($code -ne 2 -and $code -ne 3) { $script:PurgeUnverified++; return $false }
            }
            $ancestor = [IO.Path]::GetDirectoryName($ancestor)
        }
        if ($hasRepository) {
            $root = Invoke-PurgeGit $project @('rev-parse', '--show-toplevel')
            if (-not $root) { $script:PurgeUnverified++; return $false }
            $repository = $root.Output.Trim().Replace('/', '\').TrimEnd('\')
            $prefix = $repository + '\'
            if (-not $snapshot.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $false }
            $relative = $snapshot.Path.Substring($prefix.Length).Replace('\', '/')
            $tracked = Invoke-PurgeGit $project @('ls-files', '-z', '--', (':(top,literal,icase)' + $relative))
            if (-not $tracked) { $script:PurgeUnverified++; return $false }
            if ($tracked.Output.Length -gt 0) { return $false }
        }
        return Test-SweeprPathSnapshot $snapshot
    }
    catch {
        Write-Debug "Could not verify purge artifact: $Path - $_"
        $script:PurgeUnverified++
        return $false
    }
}

function Get-PurgeProjectDirectories {
    # MaxDepth counts levels below the root (the root is level 0). A cut by the time limit
    # is reported in $State.TimedOut, so the preview can say the search is incomplete.
    param([string]$Root, [int]$MaxDepth = 4, [double]$MaxSeconds = 15, [hashtable]$State = $null)
    $pending = New-Object System.Collections.Generic.Stack[object]
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $pending.Push(@{ Path = $Root; Depth = 0 })
    $excluded = @($script:ArtifactPatterns | Where-Object { $_.Type -eq 'Directory' } | ForEach-Object Name) + @('.git', '.idea')
    while ($pending.Count -gt 0) {
        if ($timer.Elapsed.TotalSeconds -ge $MaxSeconds) { if ($null -ne $State) { $State.TimedOut = $true }; return }
        $directory = $pending.Pop()
        $snapshot = Get-SweeprPathSnapshot -Path $directory.Path
        if (-not $snapshot) { continue }
        try { $children = @(Get-ChildItem -LiteralPath $directory.Path -Force -ErrorAction Stop) }
        catch { continue }
        if (-not (Test-SweeprPathSnapshot $snapshot)) { continue }
        $marker = $children | Where-Object {
            -not $_.PSIsContainer -and ($_.Name -match '^(package\.json|composer\.json|Cargo\.toml|go\.mod|pom\.xml|build\.gradle(\.kts)?|requirements\.txt|pyproject\.toml|.+\.(csproj|fsproj|vbproj|sln))$')
        } | Select-Object -First 1
        if ($marker) { [pscustomobject]@{ Path = $directory.Path; Marker = $marker.Name } }
        if ($directory.Depth -ge $MaxDepth) { continue }
        foreach ($child in $children) {
            if ($timer.Elapsed.TotalSeconds -ge $MaxSeconds) { if ($null -ne $State) { $State.TimedOut = $true }; return }
            if ($child.PSIsContainer -and $excluded -notcontains $child.Name -and
                ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                $pending.Push(@{ Path = $child.FullName; Depth = $directory.Depth + 1 })
            }
        }
    }
}

# Projects often share a folder name (frontend, backend, api), so lists show
# the path, from ~ when it is under the profile. A search root keeps the form
# written in the config (C:/code, ~\code), so only this label is normalized;
# the project Path that removal checks stays as discovered.
function Get-PurgeDisplayPath {
    param([string]$Path)
    try { $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
    catch { Write-Debug "Could not normalize purge label: $Path - $_" }
    $userHome = "$env:USERPROFILE".TrimEnd('\')
    if (-not $userHome) { return $Path }
    if ($Path.Equals($userHome, [StringComparison]::OrdinalIgnoreCase)) { return '~' }
    if ($Path.StartsWith("$userHome\", [StringComparison]::OrdinalIgnoreCase)) {
        return '~' + $Path.Substring($userHome.Length)
    }
    return $Path
}

function Find-Projects {
    param([string[]]$SearchPaths)
    $projects = @()
    $seen = @{}
    $pathCount = 0
    $totalPaths = @($SearchPaths).Count
    foreach ($searchPath in $SearchPaths) {
        $pathCount++
        Write-Progress -Activity "Scanning for projects" `
            -Status "Searching: $searchPath" `
            -PercentComplete (($pathCount / $totalPaths) * 100)
        foreach ($project in Get-PurgeProjectDirectories -Root $searchPath) {
            if ($seen.ContainsKey($project.Path)) { continue }
            $seen[$project.Path] = $true
            $artifacts = @(Find-ProjectArtifacts -ProjectPath $project.Path)
            if ($artifacts.Count -eq 0) { continue }
            $totalSize = ($artifacts | Measure-Object -Property SizeKB -Sum).Sum
            $projects += [pscustomobject]@{
                Path = $project.Path
                Name = Split-Path -Leaf $project.Path
                DisplayPath = Get-PurgeDisplayPath $project.Path
                Marker = $project.Marker
                Artifacts = $artifacts
                TotalSizeKB = $totalSize
                TotalSizeHuman = Format-ByteSize -Bytes ($totalSize * 1024)
            }
        }
    }
    Write-Progress -Activity "Scanning for projects" -Completed
    return $projects | Sort-Object -Property TotalSizeKB -Descending
}

# Bytes of the files below a folder, stopping after MaxFiles files (0 = no limit). A linked
# folder counts as empty, like Get-PathSize. Complete is $false when the count was cut or the
# walk failed or timed out; Bytes is then what was counted.
function Measure-PurgeArtifactBytes {
    param([string]$Path, [int]$MaxFiles = 0)

    $state = @{ Bytes = [long]0; Files = 0; Complete = $true }
    try {
        if (Test-IsReparsePoint -Path $Path) { return [pscustomobject]@{ Bytes = [long]0; Complete = $true } }
        $cap = if ($MaxFiles -gt 0) { $MaxFiles + 1 } else { [int]::MaxValue }
        Get-TreeItemsNoFollow -Path $Path -SkipUnreadable |
            Where-Object { -not $_.PSIsContainer } |
            Select-Object -First $cap |
            ForEach-Object {
                if ($MaxFiles -gt 0 -and $state.Files -ge $MaxFiles) { $state.Complete = $false; return }
                $state.Bytes += [long]$_.Length
                $state.Files++
            }
    }
    catch { $state.Complete = $false }
    return [pscustomobject]@{ Bytes = [long]$state.Bytes; Complete = [bool]$state.Complete }
}

function Find-ProjectArtifacts {
    <#
    .SYNOPSIS
        Find cleanable artifacts in a project directory
    #>
    # Without -MaxSizeFiles the size comes from Get-PathSize as before. With it, one artifact
    # is measured only up to that many files (0 = no limit) and SizeComplete says whether the
    # size is exact; a time-out or a cut leaves a lower bound, never a silent zero.
    param([string]$ProjectPath, [int]$MaxSizeFiles = -1)

    $measure = $MaxSizeFiles -ge 0
    $artifacts = @()

    foreach ($pattern in $script:ArtifactPatterns) {
        $items = Get-ChildItem -LiteralPath $ProjectPath -Filter $pattern.Name -Force -ErrorAction SilentlyContinue

        foreach ($item in $items) {
            if (-not (Test-PurgeArtifactKind $ProjectPath $item.Name)) { continue }
            $snapshot = Get-SweeprPathSnapshot -Path $item.FullName
            if (-not $snapshot) { continue }
            if ($pattern.Type -eq "Directory" -and $item.PSIsContainer) {
                $sizeBytes = [long]0
                $sizeComplete = $true
                if ($measure) {
                    $measured = Measure-PurgeArtifactBytes -Path $item.FullName -MaxFiles $MaxSizeFiles
                    $sizeBytes = $measured.Bytes
                    $sizeComplete = $measured.Complete
                }
                else { $sizeBytes = [long](Get-PathSize -Path $item.FullName) }
                $sizeKB = [Math]::Ceiling($sizeBytes / 1024)

                if (-not (Test-SweeprPathSnapshot $snapshot) -or
                    -not (Test-PurgeArtifactContent $ProjectPath $item.FullName)) { continue }
                $artifacts += [PSCustomObject]@{
                    Snapshot = $snapshot
                    Path = $item.FullName
                    Name = $item.Name
                    Type = "Directory"
                    Language = $pattern.Language
                    SizeBytes = $sizeBytes
                    SizeComplete = $sizeComplete
                    SizeKB = $sizeKB
                    SizeHuman = Format-ByteSize -Bytes ($sizeKB * 1024)
                }
            }
            elseif ($pattern.Type -eq "File" -and -not $item.PSIsContainer) {
                $sizeBytes = [long]$item.Length
                $sizeKB = [Math]::Ceiling($sizeBytes / 1024)

                if (-not (Test-SweeprPathSnapshot $snapshot) -or
                    -not (Test-PurgeArtifactContent $ProjectPath $item.FullName)) { continue }
                $artifacts += [PSCustomObject]@{
                    Snapshot = $snapshot
                    Path = $item.FullName
                    Name = $item.Name
                    Type = "File"
                    Language = $pattern.Language
                    SizeBytes = $sizeBytes
                    SizeComplete = $true
                    SizeKB = $sizeKB
                    SizeHuman = Format-ByteSize -Bytes ($sizeKB * 1024)
                }
            }
        }
    }

    return $artifacts
}

# ============================================================================
# Read-only preview as data
# ============================================================================

function Get-SweeprPurgePreview {
    <#
    .SYNOPSIS
        The project artifacts `sw purge` would offer, as one data object
    .DESCRIPTION
        Never asks, prints or removes anything. Without -SearchPaths the built-in default folders
        are searched, never the purge_paths.txt of the user. The search is bounded in depth and
        time per root and in total, and one artifact is measured only up to -MaxSizeFiles files;
        Complete is $false when any of these limits (or an unconfirmed candidate) cut the result.
    #>
    [CmdletBinding()]
    param(
        [string[]]$SearchPaths,
        [int]$MaxDepth = 4,
        [int]$MaxSecondsPerRoot = 15,
        [int]$MaxTotalSeconds = 120,
        [int]$MaxSizeFiles = 50000
    )

    $roots = if ($PSBoundParameters.ContainsKey('SearchPaths')) { @($SearchPaths) } else { @($script:DefaultSearchPaths) }
    $total = [Diagnostics.Stopwatch]::StartNew()
    $unverifiedBefore = $script:PurgeUnverified
    $projects = New-Object System.Collections.Generic.List[object]
    $rootResults = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $complete = $true

    foreach ($root in $roots) {
        $exists = [bool](Test-Path -LiteralPath $root -PathType Container)
        $timedOut = $false
        if ($exists) {
            $budget = [Math]::Min([double]$MaxSecondsPerRoot, [double]$MaxTotalSeconds - $total.Elapsed.TotalSeconds)
            if ($budget -le 0) { $timedOut = $true }
            else {
                $state = @{ TimedOut = $false }
                $found = @(Get-PurgeProjectDirectories -Root $root -MaxDepth $MaxDepth -MaxSeconds $budget -State $state)
                $timedOut = [bool]$state.TimedOut
                foreach ($project in $found) {
                    if ($seen.ContainsKey($project.Path)) { continue }
                    if ($total.Elapsed.TotalSeconds -ge $MaxTotalSeconds) { $timedOut = $true; break }
                    $seen[$project.Path] = $true
                    $artifacts = @(Find-ProjectArtifacts -ProjectPath $project.Path -MaxSizeFiles $MaxSizeFiles)
                    if ($artifacts.Count -eq 0) { continue }
                    [long]$bytes = 0
                    $sizeComplete = $true
                    $items = New-Object System.Collections.Generic.List[object]
                    foreach ($artifact in $artifacts) {
                        $bytes += $artifact.SizeBytes
                        if (-not $artifact.SizeComplete) { $sizeComplete = $false }
                        $items.Add([pscustomobject]@{
                                Path         = $artifact.Path
                                Name         = $artifact.Name
                                Type         = $artifact.Type
                                Language     = $artifact.Language
                                SizeBytes    = [long]$artifact.SizeBytes
                                SizeComplete = [bool]$artifact.SizeComplete
                            })
                    }
                    if (-not $sizeComplete) { $complete = $false }
                    $projects.Add([pscustomobject]@{
                            Path         = $project.Path
                            Name         = Split-Path -Leaf $project.Path
                            DisplayPath  = Get-PurgeDisplayPath $project.Path
                            Marker       = $project.Marker
                            TotalBytes   = $bytes
                            SizeComplete = $sizeComplete
                            Artifacts    = $items.ToArray()
                        })
                }
            }
        }
        if ($timedOut) { $complete = $false }
        $rootResults.Add([pscustomobject]@{ Path = $root; Exists = $exists; TimedOut = $timedOut })
    }

    $skipped = [int]($script:PurgeUnverified - $unverifiedBefore)
    if ($skipped -gt 0) { $complete = $false }
    [long]$totalBytes = 0
    foreach ($project in $projects.ToArray()) { $totalBytes += $project.TotalBytes }

    return [pscustomobject]@{
        Projects          = @($projects.ToArray() | Sort-Object -Property TotalBytes -Descending)
        TotalBytes        = $totalBytes
        Roots             = $rootResults.ToArray()
        SkippedUnverified = $skipped
        Complete          = $complete
    }
}
