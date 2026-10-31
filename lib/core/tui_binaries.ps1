# Sweepr - native tools: finding, downloading, verifying and building analyze.exe and status.exe
#
# Loaded by dot-sourcing, by install.ps1 and by the two starters bin\status.ps1 and bin\analyze.ps1. It
# needs no other Sweepr module than version.ps1, which it takes from its own folder (never from the
# working directory). Loading writes nothing, creates no file or folder, starts no process and uses no
# network; it only defines functions and fills the script variables below. It leaves the strict mode and
# the error preference of the caller alone; the functions are written to work under strict mode.
#
# Order of the sources for a tool: a file that is there, a release file whose SHA-256 matches the
# published checksum of the same release, a build with Go. A downloaded file is never started before it
# is verified and in place, a mismatch ends the search (no silent build of something else), and nothing is
# written outside the folder of the destination file.
#
# Every status line goes through Write-SwTuiStatus. The functions return their result as one value and
# write nothing else to the pipeline, so a caller can capture it.

function Get-SwTuiPathCollision {
    # Windows PowerShell 5.1 reads [ ] * ? in a path it loads or starts as a pattern, so a folder called d[1]
    # also matches a folder called d1 and the file of the wrong folder could be used. Returns a message when
    # the pattern matches anything but the literal file, otherwise $null. PowerShell 7 reads the path as it is.
    param([string]$Path, [string]$Edition = $PSVersionTable.PSEdition)

    if ($Edition -cne 'Desktop') { return $null }
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
            return ('Sweepr cannot use the folder ' + [System.IO.Path]::GetDirectoryName($Path) + ': a folder name with [ ] * or ? is read as a pattern by Windows PowerShell 5.1, and here it also matches ' +
                [System.IO.Path]::GetDirectoryName([string]$item) + '. Rename or move the installation to a folder without these characters.')
        }
    }
    return $null
}

$swTuiVersionFile = [System.IO.Path]::Combine($PSScriptRoot, 'version.ps1')
$swTuiCollision = Get-SwTuiPathCollision -Path $swTuiVersionFile
if ($null -ne $swTuiCollision) { throw $swTuiCollision }
. $swTuiVersionFile
Remove-Variable -Name swTuiVersionFile, swTuiCollision -ErrorAction SilentlyContinue

# Fixed source of the release files; nothing in the address comes from input except a checked version.
$script:SwTuiReleaseRoot = 'https://github.com/brummilab/sweepr/releases/download'
$script:SwTuiIssuesUrl = 'https://github.com/brummilab/sweepr/issues'
$script:SwTuiUserAgent = 'Sweepr (+https://github.com/brummilab/sweepr)'

# Git variables that move the repository, the index or the configuration away from the installation
# folder. With any of them set, a comparison with a release says nothing about this folder.
$script:SwTuiGitEnvironment = @(
    'GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY',
    'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_CONFIG', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS'
)

# ============================================================================
# Small helpers
# ============================================================================

function Test-SwTuiName {
    # True for exactly analyze or status, spelled in lower case.
    param([AllowNull()][AllowEmptyString()][string]$Name)

    return ($Name -ceq 'analyze' -or $Name -ceq 'status')
}

function Test-SwTuiVersion {
    # True for a version that is safe inside a tag name and an address: starts with a letter or digit,
    # then letters, digits, dot, plus and hyphen. Anchored on both ends so a line end cannot slip in.
    param([AllowNull()][AllowEmptyString()][string]$Version)

    if ([string]::IsNullOrEmpty($Version)) { return $false }
    return [regex]::IsMatch($Version, '\A[0-9A-Za-z][0-9A-Za-z.+-]*\z')
}

function Test-SwTuiDestination {
    # True when the file name of the destination is <name>.exe (any letter case).
    param([string]$Name, [AllowNull()][AllowEmptyString()][string]$DestinationPath)

    if ([string]::IsNullOrWhiteSpace($DestinationPath)) { return $false }
    try { $leaf = [System.IO.Path]::GetFileName($DestinationPath) }
    catch { return $false }
    return [string]::Equals($leaf, ($Name + '.exe'), [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-SwTuiSourceInstall {
    # True when the installation folder has a .git folder or file (a work tree link is a file).
    param([string]$WindowsDir)

    if ([string]::IsNullOrWhiteSpace($WindowsDir)) { return $false }
    try {
        $git = [System.IO.Path]::Combine($WindowsDir, '.git')
        return ([System.IO.Directory]::Exists($git) -or [System.IO.File]::Exists($git))
    }
    catch { return $false }
}

function ConvertTo-SwTuiText {
    # Text for a status line: control characters other than tab, line feed and carriage return, and the
    # range U+007F to U+009F, become a space. A file name or a message from a tool must not be able to
    # send a terminal sequence.
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return [regex]::Replace($Text, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]', ' ')
}

function Get-SwTuiErrorText {
    # Message of an error record without the wrapper of a method call.
    param($ErrorRecord)

    $exception = $ErrorRecord.Exception
    while ($exception -is [System.Management.Automation.MethodInvocationException] -and $null -ne $exception.InnerException) {
        $exception = $exception.InnerException
    }
    return [string]$exception.Message
}

function Test-SwTuiOutputRedirected {
    # True when standard output goes to a file or a pipe. A host that cannot tell counts as not redirected.
    try { return [bool][Console]::IsOutputRedirected }
    catch { return $false }
}

function Write-SwTuiStatus {
    <#
    .SYNOPSIS
        One status line of the provisioning, in the given console colour.
    .DESCRIPTION
        Both launchers run a child PowerShell whose host output ends up in its standard output, and a
        caller may capture that output as data (sw analyze --json). With redirected output the line
        therefore goes to standard error, past the PowerShell streams; otherwise it is a host line.
        Nothing reaches the pipeline and a failure to write is ignored.
    #>
    param(
        [Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Message,
        [string]$Color = 'Gray'
    )

    $text = ConvertTo-SwTuiText -Text $Message
    try {
        if (Test-SwTuiOutputRedirected) {
            [Console]::Error.WriteLine($text)
            return
        }
        $shown = 'Gray'
        if (-not [string]::IsNullOrEmpty($Color) -and [System.Enum]::IsDefined([System.ConsoleColor], $Color)) { $shown = $Color }
        Write-Host $text -ForegroundColor $shown
    }
    catch { $null = $_ }
}

function Get-SwTuiAssetName {
    # Name of the release file of a tool.
    param([string]$Name)

    return ($Name + '-windows-x64.exe')
}

function Get-SwPublishedChecksum {
    <#
    .SYNOPSIS
        Lower-case SHA-256 that SHA256SUMS.txt lists for the file AssetName, or $null.
    .DESCRIPTION
        A line is 64 hexadecimal characters, blanks or tabs, an optional star and the file name. The name
        must equal AssetName character for character. A file listed twice with different hashes counts
        as not listed, because nothing says which one is right.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$SumsText,
        [string]$AssetName
    )

    if ([string]::IsNullOrEmpty($SumsText) -or [string]::IsNullOrEmpty($AssetName)) { return $null }
    $text = $SumsText.TrimStart([char]0xFEFF)

    $hashes = New-Object System.Collections.Generic.List[string]
    foreach ($line in [regex]::Split($text, '\r\n|\n|\r')) {
        $match = [regex]::Match($line, '\A([0-9A-Fa-f]{64})[ \t]+\*?(.+?)[ \t]*\z')
        if (-not $match.Success) { continue }
        if ($match.Groups[2].Value -cne $AssetName) { continue }
        $hash = $match.Groups[1].Value.ToLowerInvariant()
        if (-not $hashes.Contains($hash)) { $hashes.Add($hash) }
    }
    if ($hashes.Count -ne 1) { return $null }
    return [string]$hashes[0]
}

function Get-SwFileSha256 {
    <#
    .SYNOPSIS
        SHA-256 of a file as 64 lower-case hexadecimal characters.
    .DESCRIPTION
        Uses .NET directly: under Windows PowerShell 5.1 Get-FileHash lives in a module that a pwsh 7
        module path can break. The path is literal and the file is opened for reading only.
    #>
    param([string]$Path)

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $builder = New-Object System.Text.StringBuilder
            foreach ($byte in $sha.ComputeHash($stream)) { [void]$builder.Append($byte.ToString('x2')) }
            return $builder.ToString()
        }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Find-SwTuiBinary {
    # The first existing file of <root>\bin\<name>.exe and <root>\<name>.exe, or $null. A folder of that
    # name does not count, and the root is taken literally.
    param([string]$WindowsDir, [string]$Name)

    if ([string]::IsNullOrWhiteSpace($WindowsDir) -or -not (Test-SwTuiName -Name $Name)) { return $null }
    try {
        foreach ($candidate in @(
                [System.IO.Path]::Combine($WindowsDir, 'bin', ($Name + '.exe')),
                [System.IO.Path]::Combine($WindowsDir, ($Name + '.exe'))
            )) {
            if ([System.IO.File]::Exists($candidate)) { return [string]$candidate }
        }
    }
    catch { return $null }
    return $null
}

function Install-SwTuiFile {
    # Puts SourcePath at DestinationPath. An existing destination is replaced in one step, so a failure
    # leaves the old file as it was.
    param([string]$SourcePath, [string]$DestinationPath)

    if ([System.IO.File]::Exists($DestinationPath)) {
        # [NullString]::Value: a plain $null reaches the method as an empty string.
        [System.IO.File]::Replace($SourcePath, $DestinationPath, [NullString]::Value)
    }
    else {
        [System.IO.File]::Move($SourcePath, $DestinationPath)
    }
}

function Remove-SwTuiTemporary {
    # Deletes a file this module created itself; never anything else, and never an error.
    param([AllowNull()][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return }
    try {
        if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Delete($Path) }
    }
    catch { $null = $_ }
}

# ============================================================================
# Finding go and git, starting a native tool
# ============================================================================

function Get-SwToolPath {
    <#
    .SYNOPSIS
        Absolute path of go or git found through the normal command search, or $null.
    .DESCRIPTION
        Windows starts a program given without a path from the folder of the caller, then the working
        folder, before it looks in PATH. So the tool is always started by the absolute path found here,
        and a match in the working folder or in the installation folder (RootDir, also below it) is not
        accepted: whatever sits there is not the developer tool the user installed. A drive root as
        RootDir covers only the files directly in it. PATH entries that are not absolute are ignored. On Windows only a
        .exe counts, since cmd.exe takes .cmd and .bat apart in its own way. Never throws.
    #>
    param([string]$Name, [string]$RootDir)

    try {
        if ($Name -cne 'go' -and $Name -cne 'git') { return $null }
        $onWindows = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
        $comparison = [System.StringComparison]::Ordinal
        $comparer = [System.StringComparer]::Ordinal
        if ($onWindows) {
            $comparison = [System.StringComparison]::OrdinalIgnoreCase
            $comparer = [System.StringComparer]::OrdinalIgnoreCase
        }
        $separator = [string][System.IO.Path]::DirectorySeparatorChar

        # A folder as a full path with one closing separator, so that a prefix test compares whole segments.
        $normalize = {
            param([string]$Folder)
            $full = [System.IO.Path]::GetFullPath($Folder)
            if ($full.EndsWith($separator, [System.StringComparison]::Ordinal)) { return $full }
            return ($full + $separator)
        }

        $working = New-Object System.Collections.Generic.List[string]
        $working.Add((& $normalize ([System.Environment]::CurrentDirectory)))
        try { $working.Add((& $normalize ((Get-Location -PSProvider FileSystem).ProviderPath))) }
        catch { $null = $_ }

        # Only an absolute PATH entry counts: a relative one means a different folder whenever the working
        # folder changes. Drive-relative (C:tools) and rooted-without-drive (\tools) entries are relative too.
        $absolute = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList $comparer
        foreach ($entry in @(([string][System.Environment]::GetEnvironmentVariable('PATH')).Split([System.IO.Path]::PathSeparator))) {
            $entry = $entry.Trim().Trim('"')
            if ($entry.Length -eq 0) { continue }
            if ($onWindows) { if (-not [regex]::IsMatch($entry, '\A(?:[A-Za-z]:[\\/]|\\\\|//)')) { continue } }
            elseif (-not $entry.StartsWith('/', [System.StringComparison]::Ordinal)) { continue }
            try { [void]$absolute.Add((& $normalize $entry)) }
            catch { $null = $_ }
        }

        $root = ''
        $rootIsDrive = $false
        if (-not [string]::IsNullOrWhiteSpace($RootDir)) {
            $root = & $normalize $RootDir
            $rootIsDrive = [string]::Equals([System.IO.Path]::GetPathRoot($root), $root, $comparison)
        }

        foreach ($command in @(Get-Command -Name $Name -CommandType Application -All -ErrorAction SilentlyContinue)) {
            $source = [string]$command.Source
            if ([string]::IsNullOrWhiteSpace($source)) { continue }
            if (-not [System.IO.Path]::IsPathRooted($source)) { continue }
            if (-not [System.IO.File]::Exists($source)) { continue }
            if ($onWindows -and -not [string]::Equals([System.IO.Path]::GetExtension($source), '.exe', [System.StringComparison]::OrdinalIgnoreCase)) { continue }

            $folder = & $normalize ([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($source)))
            if (-not $absolute.Contains($folder)) { continue }
            $skip = $false
            foreach ($current in $working) {
                if ([string]::Equals($folder, $current, $comparison)) { $skip = $true }
            }
            if ($root.Length -gt 0) {
                # A drive root as installation folder only covers the files directly in it: everything else on
                # the drive is not part of the installation.
                if ([string]::Equals($folder, $root, $comparison)) { $skip = $true }
                elseif (-not $rootIsDrive -and $folder.StartsWith($root, $comparison)) { $skip = $true }
            }
            if ($skip) { continue }
            return $source
        }
    }
    catch { return $null }
    return $null
}

function ConvertTo-SwTuiArgument {
    # One argument as the text CommandLineToArgvW reads back as that same argument: quotes around it
    # when it is empty or holds a blank or a quote, backslashes doubled before a quote or the end.
    param([AllowNull()][AllowEmptyString()][string]$Argument)

    if ($null -eq $Argument) { $Argument = '' }
    if ($Argument.Length -gt 0 -and $Argument.IndexOfAny([char[]]@(' ', "`t", "`n", [char]11, '"')) -lt 0) { return $Argument }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $i = 0
    while ($i -lt $Argument.Length) {
        $slashes = 0
        while ($i -lt $Argument.Length -and $Argument[$i] -eq [char]92) { $slashes++; $i++ }
        if ($i -eq $Argument.Length) {
            [void]$builder.Append([char]92, $slashes * 2)
            break
        }
        if ($Argument[$i] -eq [char]34) {
            [void]$builder.Append([char]92, $slashes * 2 + 1)
            [void]$builder.Append([char]34)
        }
        else {
            [void]$builder.Append([char]92, $slashes)
            [void]$builder.Append($Argument[$i])
        }
        $i++
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Stop-SwTuiProcessTree {
    # Ends a process and the processes it started. .NET Core can do it directly; Windows PowerShell 5.1
    # (.NET Framework) has no such overload and uses taskkill from the system folder.
    param([System.Diagnostics.Process]$Process)

    try {
        $method = $Process.GetType().GetMethod('Kill', [type[]]@([bool]))
        if ($null -ne $method) {
            [void]$method.Invoke($Process, [object[]]@($true))
            return
        }
        $taskkill = [System.IO.Path]::Combine([System.Environment]::SystemDirectory, 'taskkill.exe')
        if ([System.IO.File]::Exists($taskkill)) {
            $info = New-Object System.Diagnostics.ProcessStartInfo
            $info.FileName = $taskkill
            $info.Arguments = '/PID ' + $Process.Id + ' /T /F'
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            $killer = [System.Diagnostics.Process]::Start($info)
            try {
                $null = $killer.StandardOutput.ReadToEndAsync()
                $null = $killer.StandardError.ReadToEndAsync()
                [void]$killer.WaitForExit(15000)
            }
            finally { $killer.Dispose() }
        }
    }
    catch { $null = $_ }
    try { if (-not $Process.HasExited) { $Process.Kill() } }
    catch { $null = $_ }
}

function Invoke-SwNativeTool {
    <#
    .SYNOPSIS
        Runs a program by its absolute path and returns ExitCode, StdOut, StdErr and TimedOut.
    .DESCRIPTION
        The only place that starts go or git. No shell, no window and no input: the arguments are quoted
        one by one into the command line, so a blank, a quote or a shell character in one of them stays
        part of that argument. Both output streams are read at the same time, so a large output cannot
        block the program. After TimeoutSeconds the program and the processes it started are ended and
        TimedOut is true. A program that cannot be started is an error for the caller.
    #>
    param(
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds = 60
    )

    if ([string]::IsNullOrWhiteSpace($FilePath) -or -not [System.IO.Path]::IsPathRooted($FilePath)) {
        throw "A native tool must be started by an absolute path: $FilePath"
    }

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    $info.Arguments = [string]::Join(' ', @(@($ArgumentList) | ForEach-Object { ConvertTo-SwTuiArgument -Argument ([string]$_) }))
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    if (-not [string]::IsNullOrEmpty($WorkingDirectory)) { $info.WorkingDirectory = $WorkingDirectory }

    $process = [System.Diagnostics.Process]::Start($info)
    try {
        $process.StandardInput.Close()
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()

        $milliseconds = [int][Math]::Min([long][Math]::Max(1, $TimeoutSeconds) * 1000, [long][int]::MaxValue)
        $timedOut = $false
        if (-not $process.WaitForExit($milliseconds)) {
            $timedOut = $true
            Stop-SwTuiProcessTree -Process $process
            [void]$process.WaitForExit(10000)
        }

        # A child that outlives the program may still hold the pipes; do not wait for it for ever.
        [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($outTask, $errTask), 10000)
        $stdOut = ''
        $stdErr = ''
        if ($outTask.IsCompleted -and -not $outTask.IsFaulted) { $stdOut = [string]$outTask.Result }
        if ($errTask.IsCompleted -and -not $errTask.IsFaulted) { $stdErr = [string]$errTask.Result }

        $exitCode = -1
        if ($process.HasExited) { $exitCode = [int]$process.ExitCode }
        return [pscustomobject]@{ ExitCode = $exitCode; StdOut = $stdOut; StdErr = $stdErr; TimedOut = $timedOut }
    }
    finally { $process.Dispose() }
}

# ============================================================================
# Download
# ============================================================================

function Restore-SwTuiRelease {
    <#
    .SYNOPSIS
        Downloads the release file of a tool, verifies it and puts it at DestinationPath.
    .DESCRIPTION
        Returns ok, unavailable or mismatch. The fixed download addresses are used (never the GitHub API,
        which allows 60 requests per hour and address), the tags V<version>-windows and then
        v<version>-windows; the first tag whose SHA256SUMS.txt answers decides, and the file must be
        listed there. The download goes to a uniquely named temporary file next to the destination, that
        file is hashed, and only a match is moved into place; a mismatch deletes it. Nothing is started.
        Without a published checksum nothing is downloaded.
    #>
    param(
        [string]$Name,
        [string]$WindowsDir,
        [string]$DestinationPath,
        [AllowNull()][AllowEmptyString()][string]$Version
    )

    if (-not (Test-SwTuiName -Name $Name)) { return 'unavailable' }
    if (-not (Test-SwTuiDestination -Name $Name -DestinationPath $DestinationPath)) { return 'unavailable' }
    if (-not (Test-SwTuiVersion -Version $Version)) { return 'unavailable' }

    $asset = Get-SwTuiAssetName -Name $Name
    $temporary = $null
    $result = 'unavailable'
    # Windows PowerShell 5.1 slows a download down a lot when it draws progress.
    $previousProgress = $global:ProgressPreference
    $global:ProgressPreference = 'SilentlyContinue'
    try {
        # Older Windows PowerShell does not offer TLS 1.2 by itself; add it, never take a protocol away.
        # SystemDefault (0) lets the system choose, and adding a flag would replace that choice.
        try {
            $protocol = [System.Net.ServicePointManager]::SecurityProtocol
            if ([int]$protocol -ne 0) {
                [System.Net.ServicePointManager]::SecurityProtocol = ($protocol -bor [System.Net.SecurityProtocolType]::Tls12)
            }
        }
        catch { $null = $_ }

        $sums = $null
        $base = $null
        foreach ($tag in @(('V' + $Version + '-windows'), ('v' + $Version + '-windows'))) {
            $candidate = $script:SwTuiReleaseRoot + '/' + $tag
            try {
                $response = Invoke-WebRequest -Uri ($candidate + '/SHA256SUMS.txt') -UseBasicParsing -UserAgent $script:SwTuiUserAgent -TimeoutSec 20
                if ($null -eq $response) { continue }
                $content = $response.Content
                # A file served as application/octet-stream arrives as bytes.
                if ($content -is [byte[]]) { $sums = [System.Text.Encoding]::UTF8.GetString($content) }
                else { $sums = [string]$content }
                $base = $candidate
                break
            }
            catch { $null = $_ }
        }
        if ($null -eq $base) { return 'unavailable' }

        $expected = Get-SwPublishedChecksum -SumsText $sums -AssetName $asset
        if ($null -eq $expected) { return 'unavailable' }

        $folder = [System.IO.Path]::GetDirectoryName($DestinationPath)
        if ([string]::IsNullOrEmpty($folder)) { $folder = '.' }
        try { $null = [System.IO.Directory]::CreateDirectory($folder) }
        catch {
            Write-SwTuiStatus ('Cannot create the folder for the ' + $Name + ' program: ' + $folder + ' (' + (Get-SwTuiErrorText $_) + ')') -Color 'Yellow'
            return 'unavailable'
        }

        $temporary = [System.IO.Path]::Combine($folder, '.sweepr-' + $Name + '-' + [guid]::NewGuid().ToString('N') + '.download')
        Write-SwTuiStatus ('Downloading the ' + $Name + ' program for version ' + $Version + '...')
        try {
            $null = Invoke-WebRequest -Uri ($base + '/' + $asset) -OutFile $temporary -UseBasicParsing -UserAgent $script:SwTuiUserAgent -TimeoutSec 120
            $actual = ([string](Get-SwFileSha256 -Path $temporary)).ToLowerInvariant()
            if ($actual -cne $expected) {
                $result = 'mismatch'
            }
            else {
                Install-SwTuiFile -SourcePath $temporary -DestinationPath $DestinationPath
                $result = 'ok'
            }
        }
        catch {
            Write-SwTuiStatus ('Could not download the ' + $Name + ' program: ' + (Get-SwTuiErrorText $_)) -Color 'Yellow'
            $result = 'unavailable'
        }
    }
    finally {
        Remove-SwTuiTemporary -Path $temporary
        $global:ProgressPreference = $previousProgress
    }
    return $result
}

# ============================================================================
# Build
# ============================================================================

function Build-SwTuiBinary {
    <#
    .SYNOPSIS
        Builds a tool with Go and puts the result at DestinationPath; true on success.
    .DESCRIPTION
        SourcePath must be ./cmd/<name>/ (the closing slash is optional), so no option or other package
        can be smuggled into the go command. Go is started by its absolute path with an argument list, in
        the installation folder, with a limit of 600 seconds. The output goes to a uniquely named file
        next to the destination and replaces the destination only after a successful build. A failure
        shows the exit code or the time limit and the output of go; the old file stays and nothing else
        is left behind. The Go environment of the user is not changed.
    #>
    param([string]$Name, [string]$WindowsDir, [string]$DestinationPath, [string]$SourcePath)

    if (-not (Test-SwTuiName -Name $Name)) {
        Write-SwTuiStatus 'Cannot build: the tool name is not analyze or status.' -Color 'Red'
        return $false
    }
    if (-not (Test-SwTuiDestination -Name $Name -DestinationPath $DestinationPath)) {
        Write-SwTuiStatus ('Cannot build ' + $Name + ': the destination file must be called ' + $Name + '.exe.') -Color 'Red'
        return $false
    }
    if (-not [regex]::IsMatch([string]$SourcePath, '\A\./cmd/' + $Name + '/?\z')) {
        Write-SwTuiStatus ('Cannot build ' + $Name + ': the source path is not ./cmd/' + $Name + '/.') -Color 'Red'
        return $false
    }

    $go = Get-SwToolPath -Name 'go' -RootDir $WindowsDir
    if ([string]::IsNullOrEmpty($go)) {
        Write-SwTuiStatus ('Cannot build ' + $Name + ': Go was not found.') -Color 'Red'
        return $false
    }

    $folder = [System.IO.Path]::GetDirectoryName($DestinationPath)
    if ([string]::IsNullOrEmpty($folder)) { $folder = '.' }
    try { $null = [System.IO.Directory]::CreateDirectory($folder) }
    catch {
        Write-SwTuiStatus ('Cannot create the folder for the ' + $Name + ' program: ' + $folder + ' (' + (Get-SwTuiErrorText $_) + ')') -Color 'Red'
        return $false
    }

    $output = [System.IO.Path]::Combine($folder, '.sweepr-' + $Name + '-' + [guid]::NewGuid().ToString('N') + '.exe')
    $built = $false
    try {
        Write-SwTuiStatus ('Building ' + $Name + ' with Go...')
        $run = $null
        try {
            $run = Invoke-SwNativeTool -FilePath $go -ArgumentList @('build', '-o', $output, $SourcePath) -WorkingDirectory $WindowsDir -TimeoutSeconds 600
        }
        catch {
            Write-SwTuiStatus ('Building ' + $Name + ' failed: go could not be started (' + (Get-SwTuiErrorText $_) + ')') -Color 'Red'
            return $false
        }

        if ($run.TimedOut) {
            Write-SwTuiStatus ('Building ' + $Name + ' failed: go did not finish within 600 seconds (time limit).') -Color 'Red'
            return $false
        }
        if ([int]$run.ExitCode -ne 0 -or -not [System.IO.File]::Exists($output)) {
            $text = ((([string]$run.StdOut) + "`n" + ([string]$run.StdErr)).Trim())
            if ($text.Length -gt 4000) { $text = $text.Substring($text.Length - 4000) }
            Write-SwTuiStatus ('Building ' + $Name + ' failed (exit code ' + [int]$run.ExitCode + '): ' + (ConvertTo-SwTuiText -Text $text)) -Color 'Red'
            return $false
        }

        try {
            Install-SwTuiFile -SourcePath $output -DestinationPath $DestinationPath
            $built = $true
        }
        catch {
            Write-SwTuiStatus ('Could not put the built ' + $Name + ' program in place: ' + (Get-SwTuiErrorText $_)) -Color 'Red'
        }
    }
    finally { Remove-SwTuiTemporary -Path $output }
    return $built
}

function Test-SwSourceMatchesRelease {
    <#
    .SYNOPSIS
        True when cmd/<name>, go.mod and go.sum of a source installation equal the release of Version.
    .DESCRIPTION
        Only then may a source installation take the verified release file instead of building. True
        requires a .git folder or file, a git program, none of the git variables that move the repository,
        no change and no new or ignored file below cmd/<name> or in go.mod and go.sum, and an empty difference to the
        tag V<version>-windows or v<version>-windows. Anything else, an error, an unusable version and a
        git that fails or times out included, is false. Git only reads here and is limited to 30 seconds
        per call.
    #>
    param([string]$WindowsDir, [string]$Name, [AllowNull()][AllowEmptyString()][string]$Version)

    try {
        if (-not (Test-SwTuiName -Name $Name)) { return $false }
        if (-not (Test-SwTuiVersion -Version $Version)) { return $false }
        if (-not (Test-SwTuiSourceInstall -WindowsDir $WindowsDir)) { return $false }
        foreach ($variable in $script:SwTuiGitEnvironment) {
            if (-not [string]::IsNullOrEmpty([System.Environment]::GetEnvironmentVariable($variable))) { return $false }
        }

        $git = Get-SwToolPath -Name 'git' -RootDir $WindowsDir
        if ([string]::IsNullOrEmpty($git)) { return $false }

        $paths = @(('cmd/' + $Name), 'go.mod', 'go.sum')
        # No optional locks: the status must not rewrite the index of the installation.
        $prefix = @('-C', $WindowsDir, '-c', 'core.fsmonitor=false', '--no-optional-locks')

        $status = Invoke-SwNativeTool -FilePath $git -ArgumentList ($prefix + @('status', '--porcelain=v1', '--untracked-files=all', '--ignored=matching', '--') + $paths) -WorkingDirectory $WindowsDir -TimeoutSeconds 30
        if ($status.TimedOut -or [int]$status.ExitCode -ne 0) { return $false }
        if (-not [string]::IsNullOrWhiteSpace([string]$status.StdOut)) { return $false }

        foreach ($tag in @(('V' + $Version + '-windows'), ('v' + $Version + '-windows'))) {
            $diff = Invoke-SwNativeTool -FilePath $git -ArgumentList ($prefix + @('diff', '--name-only', '--no-renames', '--no-ext-diff', '--no-textconv', ('refs/tags/' + $tag), '--') + $paths) -WorkingDirectory $WindowsDir -TimeoutSeconds 30
            if ($diff.TimedOut -or [int]$diff.ExitCode -ne 0) { continue }
            if ([string]::IsNullOrWhiteSpace([string]$diff.StdOut)) { return $true }
        }
    }
    catch { return $false }
    return $false
}

# ============================================================================
# Provisioning
# ============================================================================

function Resolve-SwTuiBinary {
    <#
    .SYNOPSIS
        Path of the program Name (analyze or status), provided by the best way available, or $null.
    .DESCRIPTION
        A file that is there (Find-SwTuiBinary) is final: nothing else is done, nothing is checked and
        nothing is written, unless -Refresh asks for a new one. Otherwise: a source installation (a .git
        folder or file) takes the release file only when its source equals the release, any other
        installation takes it unless -Refresh is given; a checksum mismatch ends the search without a
        build; everything else falls back to a build with Go. The result is one string or $null, with
        a status line for every failure, and nothing but DestinationPath's folder is written.
    #>
    param(
        [string]$Name,
        [string]$WindowsDir,
        [string]$DestinationPath,
        [string]$SourcePath,
        [AllowNull()][AllowEmptyString()][string]$Version,
        [switch]$Refresh
    )

    if (-not (Test-SwTuiName -Name $Name)) {
        Write-SwTuiStatus 'Cannot provide the program: the name is not analyze or status.' -Color 'Red'
        return $null
    }

    if (-not $Refresh) {
        $existing = Find-SwTuiBinary -WindowsDir $WindowsDir -Name $Name
        if (-not [string]::IsNullOrEmpty($existing)) { return [string]$existing }
    }
    if (-not (Test-SwTuiDestination -Name $Name -DestinationPath $DestinationPath)) {
        Write-SwTuiStatus ('Cannot provide ' + $Name + ': the destination file must be called ' + $Name + '.exe.') -Color 'Red'
        return $null
    }

    if ([string]::IsNullOrEmpty($Version)) {
        # An unreadable version only rules the download out; the build does not need it.
        try { $Version = [string](Get-SwInstalledVersion -RootDir $WindowsDir) }
        catch { $Version = '' }
    }

    $source = Test-SwTuiSourceInstall -WindowsDir $WindowsDir
    $download = $false
    if (Test-SwTuiVersion -Version $Version) {
        if ($source) { $download = [bool](Test-SwSourceMatchesRelease -WindowsDir $WindowsDir -Name $Name -Version $Version) }
        else { $download = (-not $Refresh) }
    }

    if ($download) {
        $restored = 'unavailable'
        try { $restored = [string](Restore-SwTuiRelease -Name $Name -WindowsDir $WindowsDir -DestinationPath $DestinationPath -Version $Version) }
        catch { Write-SwTuiStatus ('Could not download the ' + $Name + ' program: ' + (Get-SwTuiErrorText $_)) -Color 'Yellow' }
        if ($restored -ceq 'ok') { return [string]$DestinationPath }
        if ($restored -ceq 'mismatch') {
            Write-SwTuiStatus ('The downloaded ' + $Name + ' file does not match the published checksum and was deleted.') -Color 'Red'
            Write-SwTuiStatus ('Run sw update to try again; if it keeps happening, report it at ' + $script:SwTuiIssuesUrl) -Color 'Red'
            return $null
        }
    }

    if (Build-SwTuiBinary -Name $Name -WindowsDir $WindowsDir -DestinationPath $DestinationPath -SourcePath $SourcePath) {
        return [string]$DestinationPath
    }
    return $null
}

# ============================================================================
# Old names (forwarding functions until install.ps1 uses the new ones)
# ============================================================================
# Functions, not aliases: tests mock the old names, and an alias would bypass or confuse those mocks.

function Ensure-TuiBinary {
    param(
        [string]$Name,
        [string]$WindowsDir,
        [string]$DestinationPath,
        [string]$SourcePath,
        [AllowNull()][AllowEmptyString()][string]$Version,
        [switch]$Refresh
    )

    Resolve-SwTuiBinary @PSBoundParameters
}

function Get-SweeprVersionFromScriptFile {
    param([string]$WindowsDir)

    Get-SwInstalledVersion -RootDir $WindowsDir
}
