# Sweepr - developer tool cleanup of sw clean: the section "Developer tools"
#
# Package manager, build and editor caches. Loaded by dot-sourcing; it loads cache_guard.ps1 for the owner
# probe and the cache cleaner. Loading writes nothing, creates no file or folder and starts no process;
# it only defines functions. A second load in the same scope changes nothing. Setting
# $script:SWEEPR_CLEAN_DEV_LOADED to $false makes the next load define everything again.
#
# This file never removes anything itself. A cache folder goes to Clear-SwDirectoryContents or, while an
# owner may be working, to Clear-SwAppCache; single files go to Remove-SwItems. Five tools (npm, pnpm,
# pip, go, mise) clean their own cache: Invoke-SwOwnerCacheCleanup asks the tool where its cache is,
# checks that folder against the rules of the clean module, and only then starts the tool's own command,
# bounded in time and never in a preview. The only other process it starts is taskkill for the process
# tree of a tool that ran too long.
#
# Script variables that callers read or replace:
#   SweeprSkipExternalTools  any value but exactly $false skips the tools (created as $false when missing)
#   TotalSizeCleaned, OwnerCleanups  raised by the owner path only
#   SwWalkBudgetSeconds  seconds a file search or a re-check may take (15 when missing; 0 is used up)

if ($(try { [bool]$script:SWEEPR_CLEAN_DEV_LOADED } catch { $false })) { return }

# The dependencies come from the folder of this file, never from the working directory.
. ([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PSScriptRoot), 'core', 'base.ps1'))
. ([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PSScriptRoot), 'core', 'log.ps1'))
. ([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PSScriptRoot), 'core', 'file_ops.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'cache_guard.ps1'))

# The installation folder (the parent of lib): a program found below it is not a tool of the user.
$script:SwDevInstallRoot = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetDirectoryName($PSScriptRoot))

# ============================================================================
# Small helpers
# ============================================================================

function Get-SwDevField {
    # One field of a table or an object, $null when it is not there (also under strict mode).
    param($Object, [string]$Name)

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-SwDevTrue {
    # True only for exactly one [bool] $true: a missing, different or repeated answer is "no".
    param($Answer)

    $values = @($Answer)
    return (($values.Count -eq 1) -and ($values[0] -is [bool]) -and ($values[0] -eq $true))
}

function Test-SwDevDriveRoot {
    param([string]$Path)

    $separators = [char[]]@('\', '/')
    $root = [System.IO.Path]::GetPathRoot($Path)
    if ($null -eq $root) { $root = '' }
    return [string]::Equals($Path.TrimEnd($separators), $root.TrimEnd($separators), [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-SwDevBase {
    # The folder an environment variable names, or $null when the variable is unusable for a target:
    # empty, not a complete path, or the root of a drive (typed or with links resolved).
    param([string]$Name)

    $value = Get-SwCleanEnvRoot -Name $Name
    if ($null -eq $value) { return $null }
    try {
        $full = [System.IO.Path]::GetFullPath($value)
        if (Test-SwDevDriveRoot -Path $full) { return $null }
        $resolved = Resolve-SwSafePath -Path $full
        if (-not [string]::IsNullOrEmpty([string]$resolved) -and (Test-SwDevDriveRoot -Path ([string]$resolved))) { return $null }
    }
    catch { return $null }
    return $value
}

function Get-SwDevWalkBudget {
    # Seconds a file search or a re-check may take. Missing or unusable gives 15, a negative value 0.
    try { $value = [double]$script:SwWalkBudgetSeconds }
    catch { $value = [double]15 }
    if ($value -lt 0) { return [double]0 }
    return $value
}

function Test-SwDevSkipExternal {
    # The tools are skipped for every value but exactly $false. A variable that does not exist means "run".
    try { $value = $script:SweeprSkipExternalTools }
    catch { return $false }
    if (($value -is [bool]) -and ($value -eq $false)) { return $false }
    return $true
}

function Get-SwDevToolName {
    # The name of a tool for lists and log lines: the file name without extension when the name has a
    # path, the name as it is otherwise.
    param([string]$Name)

    if ([string]::IsNullOrEmpty($Name)) { return '' }
    if ($Name.IndexOfAny([char[]]@('\', '/')) -lt 0) { return $Name }
    return [System.IO.Path]::GetFileNameWithoutExtension($Name)
}

function Add-SwDevOwnerCounters {
    # Raises the counters of the owner path. A counter that is missing or not a number counts as 0.
    param([long]$Cleanups, [long]$Kilobytes)

    if ($Cleanups -ne 0) {
        try { $count = [long]$script:OwnerCleanups } catch { $count = [long]0 }
        $script:OwnerCleanups = $count + $Cleanups
    }
    if ($Kilobytes -ne 0) {
        try { $size = [long]$script:TotalSizeCleaned } catch { $size = [long]0 }
        $script:TotalSizeCleaned = $size + $Kilobytes
    }
}

# The roots offered in the running section: a root at or below one of them is not offered again.
function Enter-SwDevRun {
    # True when this call opened the set, which then has to close it.
    $existing = $null
    try { $existing = $script:SwDevOffered }
    catch { $existing = $null }
    if ($null -ne $existing) { return $false }
    $script:SwDevOffered = [System.Collections.Generic.List[object]]::new()
    return $true
}

function Exit-SwDevRun {
    $script:SwDevOffered = $null
}

function Get-SwDevOffered {
    try { return , $script:SwDevOffered }
    catch { return , $null }
}

# ============================================================================
# The bounded search for files
# ============================================================================

function Get-SwBoundedFileScan {
    <#
    .SYNOPSIS
        Lists the files below a folder within a time budget. Removes nothing and checks no protection rule.
    .DESCRIPTION
        The result is a table with Files (full paths of files only) and Complete. The budget is checked
        first (0 is always used up: not complete), then the root: missing is complete and empty, a file or
        a link is not complete. The walk is its own (.NET listing, Get-ChildItem -Recurse is not used
        because Windows PowerShell 5.1 follows links with it); a folder that is a link is not entered and
        a file that is a link, a cloud placeholder included, is not listed. -Filter is a name filter,
        -Extensions limits to the extensions given with a leading dot, -OlderThan keeps only files whose
        newer time of creation and last write is strictly before it. Whenever the walk cannot finish
        (budget, an unreadable folder or attribute, any error) the result is not complete and Files is
        empty: a tree that was read halfway is unknown. Never throws.
    #>
    param(
        [string]$Root,
        [string]$Filter = '*',
        [string[]]$Extensions = @(),
        [datetime]$OlderThan,
        [int]$TimeoutSeconds,
        [switch]$NoRecurse
    )

    $failed = @{ Files = @(); Complete = $false }
    try {
        $ErrorActionPreference = 'Stop'
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        if ($PSBoundParameters.ContainsKey('TimeoutSeconds')) { $budget = [double][Math]::Max(0, $TimeoutSeconds) }
        else { $budget = Get-SwDevWalkBudget }
        if ($clock.Elapsed.TotalSeconds -ge $budget) { return $failed }

        if (-not (Test-SwCleanCompletePath -Path $Root)) { return $failed }
        try { $attributes = [System.IO.File]::GetAttributes($Root) }
        catch [System.IO.FileNotFoundException] { return @{ Files = @(); Complete = $true } }
        catch [System.IO.DirectoryNotFoundException] { return @{ Files = @(); Complete = $true } }
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $failed }
        if (($attributes -band [System.IO.FileAttributes]::Directory) -eq 0) { return $failed }

        if ([string]::IsNullOrEmpty($Filter)) { $Filter = '*' }
        $wanted = @($Extensions | Where-Object { -not [string]::IsNullOrEmpty($_) })
        $useAge = $PSBoundParameters.ContainsKey('OlderThan')
        $found = [System.Collections.Generic.List[string]]::new()
        $pending = [System.Collections.Generic.Stack[string]]::new()
        $pending.Push($Root)
        while ($pending.Count -gt 0) {
            $folder = $pending.Pop()
            if ($clock.Elapsed.TotalSeconds -ge $budget) { return $failed }
            foreach ($entry in [System.IO.DirectoryInfo]::new($folder).EnumerateFileSystemInfos()) {
                if ($clock.Elapsed.TotalSeconds -ge $budget) { return $failed }
                $entryAttributes = $entry.Attributes
                if (($entryAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                if (($entryAttributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                    if (-not $NoRecurse) { $pending.Push([string]$entry.FullName) }
                    continue
                }
                $name = [string]$entry.Name
                if (-not ($name -like $Filter)) { continue }
                if ($wanted.Count -gt 0 -and -not ($wanted -contains [System.IO.Path]::GetExtension($name))) { continue }
                if ($useAge) {
                    $time = $entry.CreationTime
                    if ($entry.LastWriteTime -gt $time) { $time = $entry.LastWriteTime }
                    if (-not ($time -lt $OlderThan)) { continue }
                }
                $found.Add([string]$entry.FullName)
            }
        }
        $files = $found.ToArray()
        [System.Array]::Sort($files, [System.StringComparer]::OrdinalIgnoreCase)
        return @{ Files = $files; Complete = $true }
    }
    catch {
        Write-SwDebug "file search failed, ${Root}: $($_.Exception.Message)"
        return $failed
    }
}

function Read-SwDevScan {
    # The files of one search answer, or $null when the answer is not complete. The reason goes to the
    # debug writer and to the list of what could not be measured under the given name.
    param($Answer, [string]$Name, [string]$Root)

    $complete = Get-SwDevField -Object $Answer -Name 'Complete'
    if (-not (($complete -is [bool]) -and ($complete -eq $true))) {
        Write-SwDebug "file search of $Root is not complete: $Name stays as it is"
        Add-SwCleanNotMeasured -Name $Name -Reason 'incomplete scan'
        return $null
    }
    return , @(@(Get-SwDevField -Object $Answer -Name 'Files') | Where-Object { -not [string]::IsNullOrEmpty([string]$_) } | ForEach-Object { [string]$_ })
}

# ============================================================================
# The process of an owner command
# ============================================================================

function New-SwOwnerProcess {
    <#
    .SYNOPSIS
        A process that is not started yet, with its start information set completely.
    .DESCRIPTION
        No shell, no window, input, output and error redirected (UTF-8), the system folder as working
        folder, and four variables only in the child that keep a tool from loading anything or asking.
        The variables of this process stay as they are.
    #>
    param([string]$FilePath, [string]$Arguments)

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    $info.Arguments = $Arguments
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $info.WorkingDirectory = [System.Environment]::SystemDirectory
    $info.EnvironmentVariables['GOTOOLCHAIN'] = 'local'
    $info.EnvironmentVariables['COREPACK_ENABLE_DOWNLOAD_PROMPT'] = '0'
    $info.EnvironmentVariables['COREPACK_ENABLE_NETWORK'] = '0'
    $info.EnvironmentVariables['NPM_CONFIG_UPDATE_NOTIFIER'] = 'false'
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    return $process
}

function Find-SwOwnerProgram {
    <#
    .SYNOPSIS
        The absolute path of a tool, or $null.
    .DESCRIPTION
        The name is the absolute path of an existing file (for tests) or a program name without a path.
        A name is looked up in PATH by hand: only absolute PATH entries count, and not a folder that is, or
        lies below, the working folder, the PowerShell location or the installation folder, because
        Windows starts a program from there before it looks in PATH. In each folder .exe comes before .cmd
        before .ps1; a .cmd path with one of the characters % ^ & | < > " ! is refused, because cmd.exe
        reads its command line again.
    #>
    param([string]$Name)

    try {
        if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
        if ($Name.IndexOfAny([char[]]@('\', '/', ':')) -ge 0) {
            if ((Test-SwCleanCompletePath -Path $Name) -and [System.IO.File]::Exists($Name)) { return $Name }
            return $null
        }

        $blocked = [System.Collections.Generic.List[string]]::new()
        $blocked.Add((ConvertTo-SwCleanCompare -Path ([System.Environment]::CurrentDirectory)))
        try { $blocked.Add((ConvertTo-SwCleanCompare -Path ((Get-Location -PSProvider FileSystem).ProviderPath))) }
        catch { $null = $_ }
        try { $blocked.Add((ConvertTo-SwCleanCompare -Path ([string]$script:SwDevInstallRoot))) }
        catch { $null = $_ }

        $dangerous = [char[]]@('%', '^', '&', '|', '<', '>', '"', '!')
        $entries = ([string][System.Environment]::GetEnvironmentVariable('PATH')).Split([System.IO.Path]::PathSeparator)
        foreach ($raw in $entries) {
            $entry = $raw.Trim().Trim('"')
            if ($entry.Length -eq 0) { continue }
            if (-not (Test-SwCleanCompletePath -Path $entry)) { continue }
            $form = ConvertTo-SwCleanCompare -Path $entry
            $skip = $false
            foreach ($other in $blocked) {
                if (Test-SwCleanSameOrUnder -Child $form -Parent $other) { $skip = $true }
            }
            if ($skip) { continue }
            foreach ($extension in '.exe', '.cmd', '.ps1') {
                $candidate = Join-SwCleanPath -Base $entry -Rest @($Name + $extension)
                if (-not [System.IO.File]::Exists($candidate)) { continue }
                if ($extension -eq '.cmd' -and $candidate.IndexOfAny($dangerous) -ge 0) { continue }
                return $candidate
            }
        }
        return $null
    }
    catch {
        Write-SwDebug "tool search failed for ${Name}: $($_.Exception.Message)"
        return $null
    }
}

function Get-SwDevHostFile {
    # The PowerShell file of the running host that runs a tool: powershell.exe, pwsh.exe or pwsh in $PSHOME.
    $names = @('powershell.exe', 'pwsh.exe', 'pwsh')
    foreach ($name in $names) {
        $path = [System.IO.Path]::Combine($PSHOME, $name)
        if ([System.IO.File]::Exists($path)) { return [pscustomobject]@{ Path = $path; Name = $name } }
    }
    $missing = 'pwsh.exe'
    if ($PSVersionTable['PSEdition'] -eq 'Desktop') { $missing = 'powershell.exe' }
    return [pscustomobject]@{ Path = $null; Name = $missing }
}

function Get-SwDevHelperCommand {
    # The text the helper PowerShell runs: UTF-8 output, the tool called with & by its absolute path,
    # every argument its own literal, and the exit code of the tool as the exit code of the helper. A native
    # call runs under the preference Continue, so that text on the error stream is no failure. The two
    # encodings are set apart, because setting the console one fails without a console. A call that throws
    # (program gone, not executable, script that does not load, blocked by a policy) ends the helper with
    # the fixed exit code 125; a script that ends without exit and without an exception gives 0.
    param([string]$Program, [string[]]$Arguments)

    $call = '& ' + (ConvertTo-SwPsLiteral -Value $Program)
    foreach ($argument in @($Arguments)) { $call += ' ' + (ConvertTo-SwPsLiteral -Value ([string]$argument)) }
    $lines = @(
        '$ErrorActionPreference = ''Continue'''
        '$utf8 = New-Object System.Text.UTF8Encoding($false)'
        'try { $OutputEncoding = $utf8 } catch { $null = $_ }'
        'try { [Console]::OutputEncoding = $utf8 } catch { $null = $_ }'
        '$code = 0'
        'try {'
        $call
        'if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE }'
        '} catch { $code = 125 }'
        'exit $code'
    )
    return ($lines -join "`n")
}

function Close-SwDevInput {
    # Closes the input of a process at once, without writing anything. The writer of the input is never
    # asked to close or flush: under .NET Framework it would put its encoding preamble (a UTF-8 byte order
    # mark under Windows PowerShell 5.1) into the pipe first, and the tool would read that as data. The
    # stream below the writer is closed instead; releasing the process later may report that the writer
    # cannot flush into it, which the callers ignore.
    param($Process)

    $Process.StandardInput.BaseStream.Close()
}

function Wait-SwDevRead {
    # True when the read task finishes within what is left of the one second both channels share.
    param($Task, $Clock)

    try {
        $left = [int][Math]::Max(0, 1000 - $Clock.ElapsedMilliseconds)
        return [bool]$Task.Wait($left)
    }
    catch { return $false }
}

function Stop-SwDevProcessTree {
    # Ends the whole process tree of a process this file started, with taskkill from the system folder, and
    # says in the reasons whether that is confirmed. A process that still runs afterwards gets Kill() as the
    # last resort. Gives the taskkill process, which the caller releases after the process itself.
    param($Process, $Reasons)

    $killer = $null
    $id = 0
    try { $id = [int]$Process.Id }
    catch { $id = 0 }
    try {
        $killFile = [System.IO.Path]::Combine([System.Environment]::SystemDirectory, 'taskkill.exe')
        $killer = New-SwOwnerProcess -FilePath $killFile -Arguments ('/PID ' + $id + ' /T /F')
        $null = $killer.Start()
        try { Close-SwDevInput -Process $killer }
        catch { $null = $_ }
        $null = $killer.StandardOutput.ReadToEndAsync()
        $null = $killer.StandardError.ReadToEndAsync()
        if ([bool]$killer.WaitForExit(5000)) {
            $killCode = [int]$killer.ExitCode
            if ($killCode -eq 0) { $Reasons.Add('process tree ' + $id + ' terminated') }
            else { $Reasons.Add('taskkill unconfirmed: ' + $killCode) }
        }
        else { $Reasons.Add('taskkill unconfirmed: timed out after 5 s') }
    }
    catch { $Reasons.Add('taskkill unconfirmed: ' + $_.Exception.Message) }
    try { if (-not [bool]$Process.HasExited) { $Process.Kill() } }
    catch { $null = $_ }
    return $killer
}

function Invoke-SwOwnerCommand {
    <#
    .SYNOPSIS
        Starts a tool, bounded in time. The only place where these files start a program.
    .DESCRIPTION
        Gives an object with Output (trimmed standard output) on success and $null otherwise;
        $Outcome['Reason'] (empty at the start) says why not, with markers joined by "; ". Success is:
        the program was found, started, ended within the limit with exit code 0 and, for a query, its
        output was read within one second. -Mutation (a command that changes something) starts nothing in
        a preview or while the tools are skipped. A process that runs on after the limit, or after an
        error while reading or waiting, has its whole process tree ended with taskkill from the system
        folder; the process is released only afterwards. Never throws.
    #>
    param(
        [string]$Name,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 5,
        [hashtable]$Outcome = $null,
        [switch]$Mutation
    )

    $ErrorActionPreference = 'Stop'
    $reasons = [System.Collections.Generic.List[string]]::new()
    $process = $null
    $killer = $null
    $killed = $false
    try {
        if ($null -ne $Outcome) { $Outcome['Reason'] = '' }
        if ($Mutation -and ((Test-SwDryRunMode) -or (Test-SwDevSkipExternal))) {
            $reasons.Add('mutation not allowed')
            return $null
        }

        $program = Find-SwOwnerProgram -Name $Name
        if ($null -eq $program) {
            $reasons.Add('tool not found')
            return $null
        }
        $hostFile = Get-SwDevHostFile
        if ($null -eq $hostFile.Path) {
            $reasons.Add('host not found: ' + $hostFile.Name)
            return $null
        }

        $list = @($Arguments | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        $commandText = Get-SwDevHelperCommand -Program $program -Arguments $list
        $argumentText = '-NoProfile -NonInteractive '
        if ($program.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) { $argumentText += '-ExecutionPolicy Bypass ' }
        $argumentText += '-EncodedCommand ' + [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($commandText))

        try {
            $process = New-SwOwnerProcess -FilePath $hostFile.Path -Arguments $argumentText
            $null = $process.Start()
        }
        catch {
            $reasons.Add('start failed: ' + $_.Exception.Message)
            return $null
        }

        $exited = $false
        $errored = $false
        $outTask = $null
        $errTask = $null
        try {
            Close-SwDevInput -Process $process
            $outTask = $process.StandardOutput.ReadToEndAsync()
            $errTask = $process.StandardError.ReadToEndAsync()
            $exited = [bool]$process.WaitForExit($TimeoutSeconds * 1000)
        }
        catch {
            $errored = $true
            $reasons.Add('error: ' + $_.Exception.Message)
        }

        $needKill = $false
        $outRead = $false
        if ($errored) { $needKill = $true }
        elseif (-not $exited) {
            $needKill = $true
            $reasons.Add('timed out after ' + $TimeoutSeconds + ' s')
        }
        else {
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            $outRead = Wait-SwDevRead -Task $outTask -Clock $clock
            $errRead = Wait-SwDevRead -Task $errTask -Clock $clock
            if ($errRead) {
                try {
                    $errText = ([string]$errTask.Result).Trim()
                    if ($errText.Length -gt 0) { Write-SwDebug "error output of ${Name}: $errText" }
                }
                catch { $null = $_ }
            }
            $code = [int]$process.ExitCode
            if ($code -ne 0) { $reasons.Add('exit code ' + $code) }
            if (-not $Mutation -and -not $outRead) { $reasons.Add('output not read') }
        }

        if ($needKill) {
            $killed = $true
            $killer = Stop-SwDevProcessTree -Process $process -Reasons $reasons
        }

        if ($reasons.Count -gt 0) { return $null }
        $text = ''
        if ($outRead) {
            try { $text = ([string]$outTask.Result).Trim() }
            catch { $text = '' }
        }
        return [pscustomobject]@{ Output = $text }
    }
    catch {
        $reasons.Add('error: ' + $_.Exception.Message)
        if ($null -ne $process -and -not $killed) {
            $running = $true
            try { $running = -not [bool]$process.HasExited }
            catch { $running = $true }
            if ($running) { $killer = Stop-SwDevProcessTree -Process $process -Reasons $reasons }
        }
        return $null
    }
    finally {
        # The owner process is released only after taskkill ran: while its handle is open, its id stays reserved.
        if ($null -ne $process) {
            try { $process.Dispose() }
            catch { $null = $_ }
        }
        if ($null -ne $killer) {
            try { $killer.Dispose() }
            catch { $null = $_ }
        }
        if ($null -ne $Outcome) {
            try { $Outcome['Reason'] = ($reasons -join '; ') }
            catch { $null = $_ }
        }
    }
}

# ============================================================================
# The owner path: a tool cleans its own cache
# ============================================================================

function Get-SwOwnerCachePath {
    <#
    .SYNOPSIS
        The cache folder a tool names, as a full, canonical path, or $null.
    .DESCRIPTION
        Asks the tool with a read-only query (five seconds). With the tools skipped nothing is asked and
        the tool is noted as "external tool". The answer must be one line that is a complete path, written
        canonically (no . or .. segment, no doubled separator, nothing that GetFullPath would change);
        anything else, an error message included, gives $null. Never throws.
    #>
    param([string]$Name, [string[]]$Arguments)

    try {
        $ErrorActionPreference = 'Stop'
        if (Test-SwDevSkipExternal) {
            Add-SwCleanNotMeasured -Name (Get-SwDevToolName -Name $Name) -Reason 'external tool'
            return $null
        }
        $answer = Invoke-SwOwnerCommand -Name $Name -Arguments $Arguments
        $output = Get-SwDevField -Object $answer -Name 'Output'
        if ($null -eq $output) {
            Write-SwDebug "no cache folder from $Name"
            return $null
        }
        $text = ([string]$output).Trim()
        if ($text.Length -eq 0 -or $text.IndexOf([char]13) -ge 0 -or $text.IndexOf([char]10) -ge 0) {
            Write-SwDebug "the answer of $Name is not one line with a folder"
            return $null
        }
        if (-not (Test-SwCleanCompletePath -Path $text) -or -not (Test-SwCleanCanonicalText -Text $text)) {
            Write-SwDebug "the answer of $Name is not a complete, canonical path"
            return $null
        }
        if (-not [string]::Equals([System.IO.Path]::GetFullPath($text), $text, [System.StringComparison]::Ordinal)) {
            Write-SwDebug "the answer of $Name is not a canonical path"
            return $null
        }
        return $text
    }
    catch {
        Write-SwDebug "cache folder of $Name not read: $($_.Exception.Message)"
        return $null
    }
}

function Get-SwDevNeverList {
    # Folders that no cleanup may touch, offer, or contain (the user's data and the state of tools).
    $list = [System.Collections.Generic.List[string]]::new()
    $separators = [char[]]@('\')
    $profileRoot = Get-SwCleanEnvRoot -Name 'USERPROFILE'
    if ($null -ne $profileRoot) {
        foreach ($rest in '.m2', '.gradle', '.nuget', '.cargo', '.rustup', '.cabal', '.stack\programs', '.hex\packages', '.mix', '.aws', '.azure', '.kube',
            '.docker', '.ssh', '.claude', '.codex', '.gitconfig', '.gitconfig.lock') {
            $list.Add((Join-SwCleanPath -Base $profileRoot -Rest $rest.Split($separators)))
        }
    }
    $roaming = Get-SwCleanEnvRoot -Name 'APPDATA'
    if ($null -ne $roaming) {
        foreach ($rest in 'npm', 'Docker', 'Code\User', 'Code\workspaceStorage', 'JetBrains', 'Adobe\Common\Team Projects Cache') {
            $list.Add((Join-SwCleanPath -Base $roaming -Rest $rest.Split($separators)))
        }
    }
    $local = Get-SwCleanEnvRoot -Name 'LOCALAPPDATA'
    if ($null -ne $local) {
        foreach ($rest in 'Docker', 'JetBrains', 'pypoetry\Cache\virtualenvs') {
            $list.Add((Join-SwCleanPath -Base $local -Rest $rest.Split($separators)))
        }
    }
    return $list.ToArray()
}

function Test-SwDevNever {
    # True when the folder is, lies below or contains a folder of the never-list, in either spelling.
    param([string]$Path)

    $own = Get-SwCleanPathForms -Path $Path
    $ownForms = @($own.Typed)
    if ($own.Resolved.Length -gt 0) { $ownForms += $own.Resolved }
    foreach ($never in (Get-SwDevNeverList)) {
        $other = Get-SwCleanPathForms -Path $never
        $otherForms = @($other.Typed)
        if ($other.Resolved.Length -gt 0) { $otherForms += $other.Resolved }
        foreach ($left in $ownForms) {
            foreach ($right in $otherForms) {
                if (Test-SwCleanSameOrUnder -Child $left -Parent $right) { return $true }
                if (Test-SwCleanSameOrUnder -Child $right -Parent $left) { return $true }
            }
        }
    }
    return $false
}

function Test-SwDevFeature {
    # True when the folder looks like the cache of the tool: its direct entries (or its own name) carry
    # the mark of that tool, or the folder is empty where the tool allows it. Fail closed for any other tool.
    param([string]$Tool, [string]$Path)

    try {
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($Path)) {
            $names.Add([System.IO.Path]::GetFileName([string]$entry))
        }
        $empty = ($names.Count -eq 0)
        $has = { param($Wanted) foreach ($item in $names) { if ([string]::Equals($item, $Wanted, [System.StringComparison]::OrdinalIgnoreCase)) { return $true } }; return $false }
        switch ($Tool.ToLowerInvariant()) {
            'npm' { return ($empty -or (& $has '_cacache')) }
            'pnpm' { return [regex]::IsMatch([System.IO.Path]::GetFileName($Path.TrimEnd([char[]]@('\', '/'))), '\Av[0-9]+\z') }
            'pip' { return ($empty -or (& $has 'http') -or (& $has 'wheels')) }
            'go' { return ($empty -or ((& $has 'README') -and [System.IO.File]::Exists((Join-SwCleanPath -Base $Path -Rest @('README'))))) }
            'mise' {
                if ($empty) { return $true }
                $local = Get-SwCleanEnvRoot -Name 'LOCALAPPDATA'
                if ($null -eq $local) { return $false }
                $form = ConvertTo-SwCleanCompare -Path $Path
                return $form.StartsWith((ConvertTo-SwCleanCompare -Path $local) + '\', [System.StringComparison]::OrdinalIgnoreCase)
            }
            default { return $false }
        }
    }
    catch { return $false }
}

function Test-SwDevTreeItem {
    # What the owner path needs of one entry of a tree listing: a full name, an identity and attributes
    # that say it is no link. Anything missing or unreadable is "not usable" (a missing Attributes counts
    # as a link).
    param($Item)

    if ($null -eq $Item) { return $false }
    if ([string]::IsNullOrEmpty([string](Get-SwDevField -Object $Item -Name 'FullName'))) { return $false }
    if ($null -eq (Get-SwDevField -Object $Item -Name 'SweeprPathSnapshot')) { return $false }
    $attributes = Get-SwDevField -Object $Item -Name 'Attributes'
    if ($null -eq $attributes) { return $false }
    try {
        if (([System.IO.FileAttributes]$attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    }
    catch { return $false }
    return $true
}

function Get-SwDevTreeBytes {
    # The sum of the lengths of the files in a tree listing. A missing length counts 0.
    param($Items)

    [long]$sum = 0
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        if ([bool](Get-SwDevField -Object $item -Name 'PSIsContainer')) { continue }
        try { $length = [long](Get-SwDevField -Object $item -Name 'Length') }
        catch { $length = [long]0 }
        if ($length -gt 0) { $sum += $length }
    }
    return $sum
}

function Invoke-SwOwnerCacheCleanup {
    <#
    .SYNOPSIS
        Lets a tool clean its own cache: asks where it is, checks the folder, runs the tool's command.
    .DESCRIPTION
        Everything is checked before the command, and a "no" ends the function without a log line or a
        count: the folder must come from the query, be plausible (no drive root, no profile or known folder
        or ancestor of one, nothing of the never-list), carry the mark of the tool, pass the safety check,
        have a file identity, and hold no link, protected or kept entry. A preview lists the folder with
        size 0 and counts one cleanup. A real run asks again, reads the whitelist once, lists the tree
        afresh (a new entry ends it), checks every entry again within the walk budget, measures, starts
        the command once (120 seconds) and writes one OWNER or FAILED line. A failed command is never
        followed by direct removal. Only the removed bytes, rounded down, and the count of cleanups are
        added to the statistics. Never throws.
    #>
    param(
        [string]$Name,
        [string[]]$Query,
        [string[]]$Arguments,
        [string]$Description
    )

    $owned = $false
    try {
        $ErrorActionPreference = 'Stop'
        $owned = Enter-SwDevRun
        $tool = Get-SwDevToolName -Name $Name
        $key = [System.IO.Path]::GetFileNameWithoutExtension($Name)

        # 1. the folder the tool names
        $answers = @(Get-SwOwnerCachePath -Name $Name -Arguments $Query)
        if ($answers.Count -ne 1 -or [string]::IsNullOrEmpty([string]$answers[0])) { return }
        $path = [string]$answers[0]
        if (-not (Test-SwCleanDirectory -Path $path)) {
            Write-SwDebug "the cache folder of $tool does not exist: $path"
            return
        }
        $offered = Get-SwDevOffered
        if ($null -ne $offered -and (Test-SwCleanOffered -Path $path -Offered $offered)) {
            Write-SwDebug "the cache folder of $tool was offered already: $path"
            return
        }

        # 2. plausible root, mark of the tool, safety, identity
        if (-not (Test-SwCleanRootPlausible -Root $path) -or (Test-SwDevNever -Path $path) -or -not (Test-SwDevFeature -Tool $key -Path $path)) {
            Write-SwDebug "the cache folder of $tool is not plausible: $path"
            Add-SwCleanNotMeasured -Name $tool -Reason 'not verified'
            return
        }
        if (-not (Test-SwDevTrue -Answer (Test-SwSafePath -Path $path))) {
            Write-SwDebug "the cache folder of $tool is not safe to touch: $path"
            Add-SwCleanNotMeasured -Name $tool -Reason 'not verified'
            return
        }
        $snapshot = Get-SwPathSnapshot -Path $path
        if ($null -eq $snapshot) {
            Write-SwDebug "the cache folder of $tool has no file identity: $path"
            Add-SwCleanNotMeasured -Name $tool -Reason 'not verified'
            return
        }

        # 3. the whole tree: nothing protected, kept or linked inside, and a file to clean
        $tree = Get-SwSafeDirectoryTreeItems -Path $path
        $items = @(Get-SwDevField -Object $tree -Name 'Items' | Where-Object { $null -ne $_ })
        $success = Get-SwDevField -Object $tree -Name 'Success'
        $valid = (($success -is [bool]) -and ($success -eq $true)) -and (Test-SwDevTrue -Answer (Test-SwPathSnapshot -Snapshot $snapshot)) -and -not (Test-SwReparsePoint -Path $path)
        if ($valid) {
            foreach ($item in $items) {
                if (-not (Test-SwDevTreeItem -Item $item)) { $valid = $false }
            }
        }
        if (-not $valid) {
            Write-SwDebug "the cache folder of $tool is not valid: $path"
            Add-SwCleanNotMeasured -Name $tool -Reason 'not verified'
            return
        }
        $hasFile = $false
        foreach ($item in $items) {
            if (-not [bool](Get-SwDevField -Object $item -Name 'PSIsContainer')) { $hasFile = $true }
        }
        if (-not $hasFile) {
            Write-SwDebug "the cache folder of $tool holds no file: $path"
            return
        }
        if ($null -ne $offered) { Add-SwCleanOffered -Path $path -Offered $offered }

        # 4. a preview lists the folder and stops
        if (Test-SwDryRunMode) {
            Add-SwDryRunListEntries -Description $Description -Paths @($path) -SizeBytes @([long]0) -FileCounts @([int]0)
            Add-SwDevOwnerCounters -Cleanups 1 -Kilobytes 0
            Write-SwDryRun "Would let $tool clean its own cache: $Description ($path)"
            Set-SwSectionActivity
            return
        }

        # 5. the checks of a real run, with one whitelist state
        $again = @(Get-SwOwnerCachePath -Name $Name -Arguments $Query)
        if ($again.Count -ne 1 -or -not [string]::Equals([string]$again[0], $path, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-SwDebug "the cache folder of $tool changed between the queries: $path"
            Add-SwCleanNotMeasured -Name $tool -Reason 'not verified'
            return
        }
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $budget = Get-SwDevWalkBudget
        $state = Get-SwWhitelistState
        $recheck = (Test-SwDevTrue -Answer (Test-SwSafePath -Path $path -WhitelistState $state)) -and (Test-SwDevTrue -Answer (Test-SwPathSnapshot -Snapshot $snapshot))
        $fresh = $null
        if ($recheck) {
            $fresh = Get-SwSafeDirectoryTreeItems -Path $path -WhitelistState $state
            $freshSuccess = Get-SwDevField -Object $fresh -Name 'Success'
            if (-not (($freshSuccess -is [bool]) -and ($freshSuccess -eq $true))) { $recheck = $false }
        }
        $freshItems = @()
        if ($recheck) {
            $freshItems = @(Get-SwDevField -Object $fresh -Name 'Items' | Where-Object { $null -ne $_ })
            $known = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($item in $items) { [void]$known.Add([string](Get-SwDevField -Object $item -Name 'FullName')) }
            foreach ($item in $freshItems) {
                if (-not $known.Contains([string](Get-SwDevField -Object $item -Name 'FullName'))) { $recheck = $false }
            }
        }
        if (-not $recheck) {
            Write-SwDebug "the cache folder of $tool changed before the command: $path"
            Add-SwCleanNotMeasured -Name $tool -Reason 'not verified'
            return
        }
        if ($clock.Elapsed.TotalSeconds -ge $budget) { $recheck = $null }
        foreach ($item in $items) {
            if ($null -eq $recheck) { break }
            if ($clock.Elapsed.TotalSeconds -ge $budget) { $recheck = $null; break }
            $safe = Test-SwDevTrue -Answer (Test-SwSafePath -Path ([string](Get-SwDevField -Object $item -Name 'FullName')) -WhitelistState $state)
            if (-not ($safe -and (Test-SwDevTrue -Answer (Test-SwPathSnapshot -Snapshot (Get-SwDevField -Object $item -Name 'SweeprPathSnapshot'))))) { $recheck = $false; break }
        }
        if ($null -eq $recheck) {
            Write-SwDebug "the check of the cache folder of $tool took too long: $path"
            Add-SwCleanNotMeasured -Name $tool -Reason 'incomplete scan'
            return
        }
        if (-not $recheck) {
            Write-SwDebug "an entry of the cache folder of $tool changed before the command: $path"
            Add-SwCleanNotMeasured -Name $tool -Reason 'not verified'
            return
        }

        # 6. to 8. measure, run the command once, count what it did
        $before = Get-SwDevTreeBytes -Items $freshItems
        $outcome = @{ Reason = '' }
        $result = Invoke-SwOwnerCommand -Name $Name -Arguments $Arguments -Mutation -TimeoutSeconds 120 -Outcome $outcome
        $commandLine = (@($tool) + @($Arguments | Where-Object { $null -ne $_ })) -join ' '

        if ($null -eq $result) {
            $reason = ''
            try { $reason = [string]$outcome['Reason'] }
            catch { $reason = '' }
            $detail = $commandLine + ': incomplete'
            if (-not [string]::IsNullOrEmpty($reason)) { $detail += '; ' + $reason }
            Write-SwDebug "the command of $tool did not succeed: $detail"
            try { Write-SwOperation -Action 'FAILED' -Path $path -Detail $detail }
            catch { Write-SwDebug "log line not written: $($_.Exception.Message)" }
            return
        }

        try { Write-SwOperation -Action 'OWNER' -Path $path -Detail $commandLine }
        catch { Write-SwDebug "log line not written: $($_.Exception.Message)" }
        [long]$kilobytes = 0
        if (Test-SwDevTrue -Answer (Test-SwPathSnapshot -Snapshot $snapshot)) {
            $after = Get-SwSafeDirectoryTreeItems -Path $path
            $afterSuccess = Get-SwDevField -Object $after -Name 'Success'
            if ((($afterSuccess -is [bool]) -and ($afterSuccess -eq $true)) -and (Test-SwDevTrue -Answer (Test-SwPathSnapshot -Snapshot $snapshot))) {
                $removed = $before - (Get-SwDevTreeBytes -Items (Get-SwDevField -Object $after -Name 'Items'))
                if ($removed -gt 0) { $kilobytes = [long][Math]::Floor($removed / 1024) }
            }
        }
        Add-SwDevOwnerCounters -Cleanups 1 -Kilobytes $kilobytes
        Write-SwSuccess "Let $tool clean its own cache: $Description"
        Set-SwSectionActivity
    }
    catch { Write-SwDebug "owner cleanup of $Name failed: $($_.Exception.Message)" }
    finally {
        if ($owned) { Exit-SwDevRun }
    }
}

# ============================================================================
# Rows
# ============================================================================

function Invoke-SwDevContentRow {
    # One row that empties a folder.
    param([string]$Path, [string]$Description)

    try { $null = Clear-SwDirectoryContents -Path $Path -Description $Description }
    catch { Write-SwDebug "row not offered, ${Path}: $($_.Exception.Message)" }
}

function Invoke-SwDevGuardedRow {
    # One row that empties a folder only while its owner is sure to be idle.
    param([string]$Path, [string]$Description, [string[]]$Processes)

    try { $null = Clear-SwAppCache -Path $Path -Description $Description -Processes $Processes }
    catch { Write-SwDebug "row not offered, ${Path}: $($_.Exception.Message)" }
}

function Invoke-SwDevOwnerRow {
    # One tool that cleans its own cache.
    param([string]$Name, [string[]]$Query, [string[]]$Arguments, [string]$Description)

    try { $null = Invoke-SwOwnerCacheCleanup -Name $Name -Query $Query -Arguments $Arguments -Description $Description }
    catch { Write-SwDebug "owner cleanup not run for ${Name}: $($_.Exception.Message)" }
}

function Get-SwDevProfileFolders {
    # The full paths of the profile folders below a root whose name fits the pattern, in the order of the
    # listing. Nothing when the listing gives nothing.
    param([string]$Root, [string]$Like = '*')

    $folders = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($profileFolder in @(Get-SwCacheProfiles -Root $Root)) {
            if ($null -eq $profileFolder) { continue }
            if (-not ([string]$profileFolder.Name -like $Like)) { continue }
            $folders.Add([string]$profileFolder.FullName)
        }
    }
    catch { Write-SwDebug "profile folders not listed, ${Root}: $($_.Exception.Message)" }
    return , $folders.ToArray()
}

# ============================================================================
# Groups
# ============================================================================

function Clear-SwNpmFamilyCaches {
    <#
    .SYNOPSIS
        npm and pnpm clean their own caches; the Yarn (Classic) and Bun caches are emptied.
    #>
    $ErrorActionPreference = 'Stop'
    $owned = Enter-SwDevRun
    try {
        Invoke-SwDevOwnerRow -Name 'npm' -Query @('config', 'get', 'cache') -Arguments @('cache', 'clean', '--force') -Description 'npm cache'
        Invoke-SwDevOwnerRow -Name 'pnpm' -Query @('store', 'path') -Arguments @('store', 'prune') -Description 'pnpm store'
        $local = Get-SwDevBase -Name 'LOCALAPPDATA'
        if ($null -ne $local) { Invoke-SwDevContentRow -Path (Join-SwCleanPath -Base $local -Rest @('Yarn', 'Cache')) -Description 'Yarn cache' }
        $profileRoot = Get-SwDevBase -Name 'USERPROFILE'
        if ($null -ne $profileRoot) { Invoke-SwDevContentRow -Path (Join-SwCleanPath -Base $profileRoot -Rest @('.bun', 'install', 'cache')) -Description 'Bun cache' }
    }
    catch { Write-SwDebug "npm family caches not handled: $($_.Exception.Message)" }
    finally { if ($owned) { Exit-SwDevRun } }
}

function Clear-SwNodeBuildCaches {
    <#
    .SYNOPSIS
        The node-gyp, Electron and TypeScript caches.
    #>
    $ErrorActionPreference = 'Stop'
    try {
        $local = Get-SwDevBase -Name 'LOCALAPPDATA'
        if ($null -eq $local) { return }
        Invoke-SwDevContentRow -Path (Join-SwCleanPath -Base $local -Rest @('node-gyp', 'Cache')) -Description 'node-gyp cache'
        Invoke-SwDevContentRow -Path (Join-SwCleanPath -Base $local -Rest @('electron', 'Cache')) -Description 'Electron cache'
        Invoke-SwDevContentRow -Path (Join-SwCleanPath -Base $local -Rest @('TypeScript')) -Description 'TypeScript cache'
    }
    catch { Write-SwDebug "node build caches not handled: $($_.Exception.Message)" }
}

function Clear-SwPythonCaches {
    <#
    .SYNOPSIS
        pip cleans its own cache; the pyenv and Poetry caches (never the virtual environments) and the
        temporary files directly in the conda package folders.
    #>
    $ErrorActionPreference = 'Stop'
    $owned = Enter-SwDevRun
    try {
        Invoke-SwDevOwnerRow -Name 'pip' -Query @('cache', 'dir') -Arguments @('cache', 'purge') -Description 'pip cache'
        $profileRoot = Get-SwDevBase -Name 'USERPROFILE'
        if ($null -ne $profileRoot) { Invoke-SwDevContentRow -Path (Join-SwCleanPath -Base $profileRoot -Rest @('.pyenv', 'cache')) -Description 'pyenv cache' }
        $local = Get-SwDevBase -Name 'LOCALAPPDATA'
        if ($null -ne $local) {
            $processes = @('python', 'pythonw', 'poetry')
            Invoke-SwDevGuardedRow -Path (Join-SwCleanPath -Base $local -Rest @('pypoetry', 'Cache', 'artifacts')) -Description 'Poetry cache' -Processes $processes
            Invoke-SwDevGuardedRow -Path (Join-SwCleanPath -Base $local -Rest @('pypoetry', 'Cache', 'cache')) -Description 'Poetry cache' -Processes $processes
        }
        if ($null -ne $profileRoot) {
            $files = [System.Collections.Generic.List[string]]::new()
            foreach ($rest in @('.conda', 'pkgs'), @('anaconda3', 'pkgs'), @('miniconda3', 'pkgs')) {
                try {
                    $base = Join-SwCleanPath -Base $profileRoot -Rest $rest
                    $found = Read-SwDevScan -Answer (Get-SwBoundedFileScan -Root $base -Filter '*.tmp' -NoRecurse) -Name 'Conda temp files' -Root $base
                    if ($null -ne $found) { foreach ($file in $found) { $files.Add($file) } }
                }
                catch { Write-SwDebug "conda folder not searched: $($_.Exception.Message)" }
            }
            if ($files.Count -gt 0) {
                try { $null = Remove-SwItems -Paths ([string[]]$files.ToArray()) -Description 'Conda temp files' }
                catch { Write-SwDebug "conda temp files not offered: $($_.Exception.Message)" }
            }
        }
    }
    catch { Write-SwDebug "python caches not handled: $($_.Exception.Message)" }
    finally { if ($owned) { Exit-SwDevRun } }
}

function Clear-SwDotNetCaches {
    <#
    .SYNOPSIS
        The NuGet web and plugin caches and the temporary folders of MSBuild.
    #>
    $ErrorActionPreference = 'Stop'
    try {
        $local = Get-SwDevBase -Name 'LOCALAPPDATA'
        if ($null -eq $local) { return }
        Invoke-SwDevContentRow -Path (Join-SwCleanPath -Base $local -Rest @('NuGet', 'v3-cache')) -Description 'NuGet HTTP cache'
        Invoke-SwDevContentRow -Path (Join-SwCleanPath -Base $local -Rest @('NuGet', 'plugins-cache')) -Description 'NuGet plugins cache'
        $msbuild = Join-SwCleanPath -Base $local -Rest @('Microsoft', 'MSBuild')
        foreach ($folder in (Get-SwDevProfileFolders -Root $msbuild -Like '*temp*')) {
            Invoke-SwDevContentRow -Path $folder -Description 'MSBuild temp'
        }
    }
    catch { Write-SwDebug "dotnet caches not handled: $($_.Exception.Message)" }
}

function Clear-SwGoCaches {
    <#
    .SYNOPSIS
        The go tool cleans its own build cache.
    #>
    $ErrorActionPreference = 'Stop'
    $owned = Enter-SwDevRun
    try { Invoke-SwDevOwnerRow -Name 'go' -Query @('env', 'GOCACHE') -Arguments @('clean', '-cache') -Description 'Go build cache' }
    catch { Write-SwDebug "go caches not handled: $($_.Exception.Message)" }
    finally { if ($owned) { Exit-SwDevRun } }
}

function Clear-SwMiseCache {
    <#
    .SYNOPSIS
        mise cleans its own cache.
    #>
    $ErrorActionPreference = 'Stop'
    $owned = Enter-SwDevRun
    try { Invoke-SwDevOwnerRow -Name 'mise' -Query @('cache', 'path') -Arguments @('cache', 'clear') -Description 'mise cache' }
    catch { Write-SwDebug "mise cache not handled: $($_.Exception.Message)" }
    finally { if ($owned) { Exit-SwDevRun } }
}

function Clear-SwElixirCaches {
    <#
    .SYNOPSIS
        The Hex download cache (never the Hex packages).
    #>
    $ErrorActionPreference = 'Stop'
    try {
        $profileRoot = Get-SwDevBase -Name 'USERPROFILE'
        if ($null -eq $profileRoot) { return }
        Invoke-SwDevContentRow -Path (Join-SwCleanPath -Base $profileRoot -Rest @('.hex', 'cache')) -Description 'Hex cache'
    }
    catch { Write-SwDebug "elixir caches not handled: $($_.Exception.Message)" }
}

function Clear-SwHaskellCaches {
    <#
    .SYNOPSIS
        The temporary files in the Stack snapshots (never the Stack programs or the Cabal store).
    #>
    $ErrorActionPreference = 'Stop'
    try {
        $profileRoot = Get-SwDevBase -Name 'USERPROFILE'
        if ($null -eq $profileRoot) { return }
        $root = Join-SwCleanPath -Base $profileRoot -Rest @('.stack', 'snapshots')
        $found = Read-SwDevScan -Answer (Get-SwBoundedFileScan -Root $root -Filter '*.tmp') -Name 'Stack temp files' -Root $root
        if ($null -eq $found -or @($found).Count -eq 0) { return }
        $null = Remove-SwItems -Paths ([string[]]@($found)) -Description 'Stack temp files'
    }
    catch { Write-SwDebug "haskell caches not handled: $($_.Exception.Message)" }
}

function Clear-SwOCamlCaches {
    <#
    .SYNOPSIS
        The Opam download cache and the cache folders of the Opam repositories.
    #>
    $ErrorActionPreference = 'Stop'
    try {
        $profileRoot = Get-SwDevBase -Name 'USERPROFILE'
        if ($null -eq $profileRoot) { return }
        Invoke-SwDevContentRow -Path (Join-SwCleanPath -Base $profileRoot -Rest @('.opam', 'download-cache')) -Description 'Opam download cache'
        $repos = Join-SwCleanPath -Base $profileRoot -Rest @('.opam', 'repo')
        foreach ($folder in (Get-SwDevProfileFolders -Root $repos -Like '*cache*')) {
            Invoke-SwDevContentRow -Path $folder -Description 'Opam repo cache'
        }
    }
    catch { Write-SwDebug "ocaml caches not handled: $($_.Exception.Message)" }
}

function Clear-SwCloudCliCaches {
    <#
    .SYNOPSIS
        The gcloud logs and the Terraform plugin cache (never credentials or configuration).
    #>
    $ErrorActionPreference = 'Stop'
    try {
        $roaming = Get-SwDevBase -Name 'APPDATA'
        if ($null -eq $roaming) { return }
        Invoke-SwDevContentRow -Path (Join-SwCleanPath -Base $roaming -Rest @('gcloud', 'logs')) -Description 'gcloud logs'
        Invoke-SwDevContentRow -Path (Join-SwCleanPath -Base $roaming -Rest @('terraform.d', 'plugin-cache')) -Description 'Terraform plugin cache'
    }
    catch { Write-SwDebug "cloud cli caches not handled: $($_.Exception.Message)" }
}

function Clear-SwEditorCaches {
    <#
    .SYNOPSIS
        The caches of VS Code, VS Code Insiders, Zed and Sublime Text, each only while its editor is idle.
    #>
    $ErrorActionPreference = 'Stop'
    try {
        $roaming = Get-SwDevBase -Name 'APPDATA'
        $local = Get-SwDevBase -Name 'LOCALAPPDATA'
        $leaves = @('Cache', 'CachedData', 'CachedExtensions', 'CachedExtensionVSIXs', 'Code Cache', 'GPUCache')
        if ($null -ne $roaming) {
            foreach ($leaf in $leaves) {
                Invoke-SwDevGuardedRow -Path (Join-SwCleanPath -Base $roaming -Rest @('Code', $leaf)) -Description 'VS Code cache' -Processes @('Code')
            }
        }
        if ($null -ne $local) {
            Invoke-SwDevGuardedRow -Path (Join-SwCleanPath -Base $local -Rest @('Microsoft', 'vscode-cpptools')) -Description 'VS Code cache' -Processes @('Code', 'cpptools', 'cpptools-srv')
        }
        if ($null -ne $roaming) {
            foreach ($leaf in $leaves) {
                Invoke-SwDevGuardedRow -Path (Join-SwCleanPath -Base $roaming -Rest @('Code - Insiders', $leaf)) -Description 'VS Code Insiders cache' -Processes @('Code - Insiders')
            }
        }
        if ($null -ne $local) { Invoke-SwDevGuardedRow -Path (Join-SwCleanPath -Base $local -Rest @('Zed', 'cache')) -Description 'Zed cache' -Processes @('zed') }
        if ($null -ne $roaming) { Invoke-SwDevGuardedRow -Path (Join-SwCleanPath -Base $roaming -Rest @('Zed', 'cache')) -Description 'Zed cache' -Processes @('zed') }
        if ($null -ne $local) { Invoke-SwDevGuardedRow -Path (Join-SwCleanPath -Base $local -Rest @('Sublime Text', 'Cache')) -Description 'Sublime Text cache' -Processes @('sublime_text', 'plugin_host') }
        if ($null -ne $roaming) { Invoke-SwDevGuardedRow -Path (Join-SwCleanPath -Base $roaming -Rest @('Sublime Text', 'Cache')) -Description 'Sublime Text cache' -Processes @('sublime_text', 'plugin_host') }
    }
    catch { Write-SwDebug "editor caches not handled: $($_.Exception.Message)" }
}

function Clear-SwIdeCaches {
    <#
    .SYNOPSIS
        The component and image caches of every Visual Studio version, each only while devenv is idle.
    #>
    $ErrorActionPreference = 'Stop'
    try {
        $local = Get-SwDevBase -Name 'LOCALAPPDATA'
        if ($null -eq $local) { return }
        $root = Join-SwCleanPath -Base $local -Rest @('Microsoft', 'VisualStudio')
        foreach ($folder in (Get-SwDevProfileFolders -Root $root)) {
            foreach ($leaf in 'ComponentModelCache', 'ImageCache') {
                Invoke-SwDevGuardedRow -Path (Join-SwCleanPath -Base $folder -Rest @($leaf)) -Description 'Visual Studio cache' -Processes @('devenv')
            }
        }
    }
    catch { Write-SwDebug "ide caches not handled: $($_.Exception.Message)" }
}

# ============================================================================
# The section
# ============================================================================

function Invoke-SwDevCleanup {
    <#
    .SYNOPSIS
        The section "Developer tools": the twelve groups in a fixed order. Writes nothing to the pipeline;
        a failing group stops only itself.
    #>
    $ErrorActionPreference = 'Stop'
    try { Start-SwSection 'Developer tools' }
    catch { Write-SwDebug "section not opened: $($_.Exception.Message)" }
    $owned = Enter-SwDevRun
    try {
        foreach ($group in 'Clear-SwNpmFamilyCaches', 'Clear-SwNodeBuildCaches', 'Clear-SwPythonCaches', 'Clear-SwDotNetCaches', 'Clear-SwGoCaches', 'Clear-SwMiseCache',
            'Clear-SwElixirCaches', 'Clear-SwHaskellCaches', 'Clear-SwOCamlCaches', 'Clear-SwCloudCliCaches', 'Clear-SwEditorCaches', 'Clear-SwIdeCaches') {
            try { $null = & $group }
            catch { Write-SwDebug "$group failed: $($_.Exception.Message)" }
        }
    }
    finally {
        if ($owned) { Exit-SwDevRun }
        try { Stop-SwSection }
        catch { Write-SwDebug "section not closed: $($_.Exception.Message)" }
    }
}

# ============================================================================
# Old names, kept as forwarding functions (not aliases, so a test mock of either name behaves) until the
# callers move to the new ones.
# ============================================================================

function Invoke-DevToolsCleanup { Invoke-SwDevCleanup }
function Clear-NpmCache { Clear-SwNpmFamilyCaches }
function Clear-NodeBuildCaches { Clear-SwNodeBuildCaches }
function Clear-PythonCaches { Clear-SwPythonCaches }
function Clear-DotNetDevCaches { Clear-SwDotNetCaches }
function Clear-GoCaches { Clear-SwGoCaches }
function Clear-MiseCache { Clear-SwMiseCache }
function Clear-ElixirCaches { Clear-SwElixirCaches }
function Clear-HaskellCaches { Clear-SwHaskellCaches }
function Clear-OCamlCaches { Clear-SwOCamlCaches }
function Clear-CloudCliCaches { Clear-SwCloudCliCaches }
function Clear-EditorCaches { Clear-SwEditorCaches }
function Clear-IdeCaches { Clear-SwIdeCaches }

function Invoke-SweeprOwnerCacheCleanup {
    param(
        [string]$Name,
        [string[]]$Query,
        [string[]]$Arguments,
        [string]$Description
    )
    Invoke-SwOwnerCacheCleanup @PSBoundParameters
}

function Get-SweeprOwnerCachePath {
    param(
        [string]$Name,
        [string[]]$Arguments
    )
    Get-SwOwnerCachePath @PSBoundParameters
}

function Invoke-SweeprOwnerProcess {
    param(
        [string]$Name,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 5,
        [hashtable]$Outcome = $null
    )
    if ($PSBoundParameters.ContainsKey('Outcome')) { Invoke-SwOwnerCommand -Name $Name -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds -Outcome $Outcome }
    else { Invoke-SwOwnerCommand -Name $Name -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds }
}

function Get-FilesWithinBudget {
    param(
        [string]$Root,
        [string]$Filter,
        [int]$TimeoutSeconds = 15
    )
    if ([string]::IsNullOrEmpty($Filter)) { $Filter = '*' }
    Get-SwBoundedFileScan -Root $Root -Filter $Filter -TimeoutSeconds $TimeoutSeconds
}

# The switch that skips the tools: created as $false only when it does not exist yet, never changed by a load.
if ($null -eq (Get-Variable -Name 'SweeprSkipExternalTools' -Scope Script -ErrorAction SilentlyContinue)) { $script:SweeprSkipExternalTools = $false }
$script:SWEEPR_CLEAN_DEV_LOADED = $true
