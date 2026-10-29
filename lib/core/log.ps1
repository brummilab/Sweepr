# Sweepr - log: operations log, debug session log, console messages, sections, spinner and progress
#
# The one place where commands write operations.log (who removed, recycled, uninstalled, skipped or
# failed on which path), keep the debug session log, print status lines, open and close sections and
# run the waiting spinner. Loaded by dot-sourcing, by the router and by every command module. Loading
# writes nothing, creates no file or folder, starts no process, uses no network and compiles no native
# code (that happens at the first use of the spinner); it only defines functions and fills the script
# variables below. A second load in the same scope changes nothing: paths, the session marker, the
# debug state, the section, the collector and the spinner switch that a caller changed stay as they
# are. Setting $script:SWEEPR_LOG_LOADED to $false makes the next load work out the folder, read
# SWEEPR_DEBUG and put every variable back to its starting value.
#
# Script variables that callers read or replace (read at every call, nothing is cached):
# SweeprOperationsLogFile, SweeprOperationsLogMaxBytes, SweeprOperationsLogStarted, SweeprDebugLogFile,
# LogConfig (DebugEnabled, LogFile), CurrentSection (Active, Activity, Name), SectionCollector and
# SpinnerDisabled.
#
# A log line that cannot be written is lost, never an error for the caller: every writer here swallows
# its failures. The old function names stay at the end of the file as forwarding functions.

if ($(try { [bool]$script:SWEEPR_LOG_LOADED } catch { $false })) {
    # Callers rely on these for the rest of their run, also when the module was loaded already.
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    return
}

# The dependency comes from the folder of this file, never from the working directory.
. ([System.IO.Path]::Combine($PSScriptRoot, 'base.ps1'))

# ============================================================================
# Small helpers
# ============================================================================

function Get-SwLogEnv {
    # Value of an environment variable; an unset variable is an empty string.
    param([string]$Name)

    $value = [System.Environment]::GetEnvironmentVariable($Name)
    if ($null -eq $value) { return '' }
    return [string]$value
}

function Join-SwLogPath {
    # Base plus one separator plus Child, as plain text. Unlike Path.Combine and Join-Path it never
    # throws for odd characters or a drive that does not exist.
    param([string]$Base, [string]$Child)

    return $Base.TrimEnd([char[]]@('\', '/')) + [string][System.IO.Path]::DirectorySeparatorChar + $Child
}

function Get-SwLogErrorText {
    # The message of the innermost exception: a method call wraps the real cause in "Exception calling ...".
    param($ErrorRecord)

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception.InnerException) { $exception = $exception.InnerException }
    return [string]$exception.Message
}

function Test-SwLogExceptionKind {
    # True when the exception or one of its inner exceptions is of the type.
    param($Exception, [type]$Type)

    $current = $Exception
    while ($null -ne $current) {
        if ($Type.IsInstanceOfType($current)) { return $true }
        $current = $current.InnerException
    }
    return $false
}

function Get-SwLogConfigTable {
    # The live LogConfig table. A caller that removed or replaced it with something else gets a fresh
    # one, so no writer has to deal with a missing table.
    try { $table = $script:LogConfig } catch { $table = $null }
    if ($table -isnot [System.Collections.IDictionary]) {
        $table = @{ DebugEnabled = $false; LogFile = $null }
        $script:LogConfig = $table
    }
    return $table
}

function Get-SwSectionTable {
    # The live CurrentSection table, created again when a caller removed it.
    try { $table = $script:CurrentSection } catch { $table = $null }
    if ($table -isnot [System.Collections.IDictionary]) {
        $table = @{ Active = $false; Activity = $false; Name = '' }
        $script:CurrentSection = $table
    }
    return $table
}

function Test-SwSectionActive {
    # True while a section is open; the spinner belongs to the open section.
    try { $table = $script:CurrentSection } catch { return $false }
    if ($table -isnot [System.Collections.IDictionary]) { return $false }
    try { return ($table['Active'] -eq $true) }
    catch { return $false }
}

function Test-SwDebugEnabled {
    try { $table = $script:LogConfig } catch { return $false }
    if ($table -isnot [System.Collections.IDictionary]) { return $false }
    try { return ($table['DebugEnabled'] -eq $true) }
    catch { return $false }
}

function Get-SwDebugFilePath {
    # The file the message lines go to, or an empty string when there is none.
    try { $table = $script:LogConfig } catch { return '' }
    if ($table -isnot [System.Collections.IDictionary]) { return '' }
    try { $file = $table['LogFile'] } catch { return '' }
    if ($null -eq $file) { return '' }
    return [string]$file
}

function Get-SwLogMark {
    # A colour sequence or a symbol from the tables of base.ps1, asked for at each call so a table that
    # a caller emptied or filled partly is repaired by the lookup. Nothing found counts as empty text.
    param([ValidateSet('Color', 'Icon')][string]$Kind, [string]$Name)

    try {
        if ($Kind -eq 'Color') { $value = Get-SwColor -Name $Name }
        else { $value = Get-SwIcon -Name $Name }
    }
    catch { return '' }
    if ($null -eq $value) { return '' }
    return [string]$value
}

function ConvertTo-SwConsoleText {
    # Text for the console: control characters other than tab, line feed and carriage return, and the
    # C1 range U+007F to U+009F, become a space. A file name with an escape character must not be able
    # to send a terminal sequence.
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return [regex]::Replace($Text, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]', ' ')
}

function ConvertTo-SwSpinnerText {
    # Label of the spinner: like console text, and also single-line, so a frame stays one line.
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return [regex]::Replace($Text, '[\x00-\x1F\x7F-\x9F]', ' ')
}

function ConvertTo-SwLogValue {
    <#
    .SYNOPSIS
        Text with every control character written out, so it fits on one line of a log.
    .DESCRIPTION
        U+0000 to U+001F and U+007F: tab as \t, line feed as \n, carriage return as \r, every other one
        as \x and two lower-case hexadecimal digits. Everything else, backslashes, brackets and
        non-ASCII text included, stays. $null gives an empty string.
    #>
    param([string]$Value)

    if ([string]::IsNullOrEmpty($Value)) { return '' }
    if (-not [regex]::IsMatch($Value, '[\x00-\x1F\x7F]')) { return $Value }

    $builder = New-Object System.Text.StringBuilder
    foreach ($char in $Value.ToCharArray()) {
        $code = [int]$char
        if ($code -eq 9) { [void]$builder.Append('\t') }
        elseif ($code -eq 10) { [void]$builder.Append('\n') }
        elseif ($code -eq 13) { [void]$builder.Append('\r') }
        elseif ($code -lt 32 -or $code -eq 127) {
            [void]$builder.Append('\x' + $code.ToString('x2', [System.Globalization.CultureInfo]::InvariantCulture))
        }
        else { [void]$builder.Append($char) }
    }
    return $builder.ToString()
}

# ============================================================================
# Files: appending text, and moving a large log aside
# ============================================================================

function Open-SwLogAppendOnly {
    # Windows: opens the file with the right to append and no other write right. The system then puts
    # every write at the current end of the file, whatever another process wrote since the open (a plain
    # write behind a file pointer would overwrite a line that was added in between, for example by
    # analyze.exe). Gives $null when this host cannot open the file that way, whatever the reason; the
    # caller then uses the plain open, which reports the real error (a sharing violation, a missing
    # folder) itself. Only the open is judged here: what happens to the stream afterwards is not.
    param([string]$File)

    try {
        $mode = [System.IO.FileMode]::OpenOrCreate
        $rights = [System.Security.AccessControl.FileSystemRights]::AppendData
        $share = [System.IO.FileShare]::ReadWrite
        $options = [System.IO.FileOptions]::None
        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            # Windows PowerShell: the constructor of the .NET Framework takes the rights.
            return [System.IO.FileStream]::new($File, $mode, $rights, $share, 4096, $options)
        }
        # PowerShell 7: an extension method takes them. The exact overload is looked up, because an
        # older assembly loaded by another module may lack it.
        $extension = 'System.IO.FileSystemAclExtensions' -as [type]
        if ($null -eq $extension) { return $null }
        $signature = [type[]]@([System.IO.FileInfo], [System.IO.FileMode], [System.Security.AccessControl.FileSystemRights],
            [System.IO.FileShare], [int], [System.IO.FileOptions], [System.Security.AccessControl.FileSecurity])
        if ($null -eq $extension.GetMethod('Create', $signature)) { return $null }
        return $extension::Create([System.IO.FileInfo]::new($File), $mode, $rights, $share, 4096, $options, $null)
    }
    catch { return $null }
}

function Write-SwLogFileText {
    # One write of the complete text as UTF-8 without a byte order mark: appended to the file, or with
    # -Replace as its new content. The file is opened for reading and writing by others, so sw history
    # can read it and a second writer is not locked out. The text goes out in a single call, so a line
    # is in the file completely or not at all. Throws when the file cannot be opened or written.
    param([string]$File, [string]$Text, [switch]$Replace)

    # A character that cannot be encoded (a lone surrogate) becomes a replacement character.
    $bytes = ([System.Text.UTF8Encoding]::new($false)).GetBytes($Text)

    if (-not $Replace -and (Test-SwBaseWindows)) {
        $stream = Open-SwLogAppendOnly -File $File
        if ($null -ne $stream) {
            # An error from here on is passed on, so the caller's retry runs and a line is never written twice.
            try {
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush()
            }
            finally { $stream.Dispose() }
            return
        }
    }

    if ($Replace) { $mode = [System.IO.FileMode]::Create }
    else { $mode = [System.IO.FileMode]::Append }
    $stream = [System.IO.FileStream]::new($File, $mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    try {
        # Without the append right a writer can only seek: write behind whatever was added since the open.
        if (-not $Replace) { [void]$stream.Seek(0, [System.IO.SeekOrigin]::End) }
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    }
    finally { $stream.Dispose() }
}

function Add-SwOperationText {
    <#
    .SYNOPSIS
        Appends text to the operations log, up to five attempts.
    .DESCRIPTION
        An IOException (typically a sharing violation, because another run holds the file for a moment)
        is retried after a short, growing pause: 20, 40, 60 and 80 ms. Any other error, such as a path
        that is a folder, is passed on at once. The last error is passed on after the fifth attempt.
    #>
    param([string]$File, [string]$Text)

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            Write-SwLogFileText -File $File -Text $Text
            return
        }
        catch {
            $failure = $_
            $retry = (Test-SwLogExceptionKind -Exception $failure.Exception -Type ([System.IO.IOException])) -and
                -not (Test-SwLogExceptionKind -Exception $failure.Exception -Type ([System.UnauthorizedAccessException]))
            if (-not $retry -or $attempt -ge 5) { throw }
        }
        Start-Sleep -Milliseconds (20 * $attempt)
    }
}

function Move-SwOperationLogAside {
    # Moves the log to <File>.old and replaces an older .old; one generation is kept. Throws when the
    # file cannot be moved. Static file calls take the names literally, also with brackets in them.
    param([string]$File)

    $old = $File + '.old'
    if ([System.IO.File]::Exists($old)) {
        # No backup name: the previous .old is dropped by the replacement itself.
        [System.IO.File]::Replace($File, $old, [NullString]::Value)
    }
    else { [System.IO.File]::Move($File, $old) }
}

# ============================================================================
# Operations log
# ============================================================================

function Test-SwLogLabelPart {
    # A command or run id that the readers of the log can split off again: at least one character, no
    # white space (also U+0085 and the Unicode spaces that \s matches), no closing bracket, no control
    # character.
    param([string]$Value)

    return [regex]::IsMatch($Value, '\A[^\s\]\x00-\x1F\x7F]+\z', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
}

function Write-SwOperationLoss {
    # Reports a line that was not written; shown only in debug mode. Never throws.
    param([string]$File, [string]$Reason)

    try { Write-SwDebug -Message ('operations.log not written: ' + $File + ' (' + $Reason + ')') }
    catch { $null = $_ }
}

function Write-SwOperation {
    <#
    .SYNOPSIS
        Appends one line to the operations log: [time] [command run=id] ACTION path (detail).
    .DESCRIPTION
        Writes nothing when SWEEPR_NO_OPLOG is exactly 1, when the path is empty, when no log file is
        known or when the action is not made of ASCII capital letters. The dry-run decision belongs to
        the callers. The first line of a run is preceded by a session marker in the same write. A
        failure loses the line and is reported once through Write-SwDebug; it never reaches the caller.
        Path and detail are written out (control characters as escapes), and a detail has brackets
        instead of parentheses, so the line always has the shape that sw history reads.
    #>
    param([string]$Action, [string]$Path, [string]$Detail = '')

    $file = ''
    $rotationNote = ''
    try {
        if ((Get-SwLogEnv 'SWEEPR_NO_OPLOG') -ceq '1') { return }
        if ([string]::IsNullOrEmpty($Path)) { return }
        try { $file = [string]$script:SweeprOperationsLogFile } catch { $file = '' }
        if ([string]::IsNullOrEmpty($file)) { return }

        # The action is not written out, so only a plain word may pass: anything else could carry a line
        # break and forge a record.
        if (-not [regex]::IsMatch($Action, '\A[A-Z]+\z', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
            Write-SwOperationLoss -File $file -Reason 'the action is not made of capital letters A to Z'
            return
        }

        # One reading of the clock per record, so the marker and the record show the same time.
        $now = [datetime](Get-Date)
        $stamp = $now.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)

        $command = Get-SwLogEnv '_SWEEPR_OPLOG_RUN_COMMAND'
        if (-not (Test-SwLogLabelPart $command)) { $command = 'sweepr' }
        $runId = Get-SwLogEnv '_SWEEPR_OPLOG_RUN_ID'
        $label = $command
        if (Test-SwLogLabelPart $runId) { $label = $command + ' run=' + $runId }

        $pathText = ConvertTo-SwLogValue -Value $Path
        if ([string]::IsNullOrEmpty($Detail)) { $detailText = '-' }
        else { $detailText = (ConvertTo-SwLogValue -Value $Detail).Replace('(', '[').Replace(')', ']') }
        $crlf = [string][char]13 + [string][char]10
        $text = '[' + $stamp + '] [' + $label + '] ' + $Action + ' ' + $pathText + ' (' + $detailText + ')' + $crlf

        try { $started = ($script:SweeprOperationsLogStarted -eq $true) } catch { $started = $false }
        if (-not $started) {
            # The folder is made before the first line only; a folder that vanishes later is not made again.
            $folder = [System.IO.Path]::GetDirectoryName($file)
            if (-not [string]::IsNullOrEmpty($folder) -and -not [System.IO.Directory]::Exists($folder)) {
                [void][System.IO.Directory]::CreateDirectory($folder)
            }

            # A log above the limit moves to .old before the marker. When that fails the line is still
            # appended to the large file: a lost record is worse than a long file.
            try { $limit = [long]$script:SweeprOperationsLogMaxBytes } catch { $limit = [long]5242880 }
            if ([System.IO.File]::Exists($file) -and ([System.IO.FileInfo]::new($file)).Length -gt $limit) {
                try { Move-SwOperationLogAside -File $file }
                catch { $rotationNote = 'log rotation to .old failed: ' + (Get-SwLogErrorText $_) }
            }

            $text = $crlf + '# ========== ' + $label + ' session started at ' + $stamp + ' ==========' + $crlf + $text
        }

        $null = Add-SwOperationText -File $file -Text $text
        $script:SweeprOperationsLogStarted = $true
        # One note per record: the line was written, only the rotation did not happen.
        if ($rotationNote.Length -gt 0) { Write-SwOperationLoss -File $file -Reason ($rotationNote + '; the line went to the existing file') }
    }
    catch {
        $reason = Get-SwLogErrorText $_
        if ($rotationNote.Length -gt 0) { $reason = $reason + '; ' + $rotationNote }
        Write-SwOperationLoss -File $file -Reason $reason
    }
}

# ============================================================================
# Debug file and diagnostic line
# ============================================================================

function Add-SwDebugFileLine {
    # One line "HH:mm:ss [LEVEL] text" at the end of the debug file, when LogConfig names one. The text
    # is written out like a path, so a message is one line. Errors are silent and not retried: a
    # diagnostic that fails must not produce diagnostics, and it never creates a folder.
    param([string]$Level, [string]$Text)

    try {
        $file = Get-SwDebugFilePath
        if ([string]::IsNullOrEmpty($file)) { return }
        $now = [datetime](Get-Date)
        $time = $now.ToString('HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        $crlf = [string][char]13 + [string][char]10
        Write-SwLogFileText -File $file -Text ($time + ' [' + $Level + '] ' + (ConvertTo-SwLogValue -Value $Text) + $crlf)
    }
    catch { $null = $_ }
}

function Test-SwOutputRedirected {
    # True when standard output goes to a file or a pipe. A host that cannot tell counts as not redirected.
    try { return [bool][Console]::IsOutputRedirected }
    catch { return $false }
}

function Write-SwDiagnosticLine {
    # A line for the operator that must not mix into data: both launchers run a child PowerShell whose
    # host output ends up in its standard output, so with redirected output the line goes to standard
    # error, past the PowerShell streams. Otherwise it is a normal host line.
    param([string]$Message = '')

    try {
        if (Test-SwOutputRedirected) { [Console]::Error.WriteLine($Message) }
        else { Write-Host $Message }
    }
    catch { $null = $_ }
}

function Write-SwDebug {
    <#
    .SYNOPSIS
        A diagnostic line in debug mode; nothing otherwise.
    .DESCRIPTION
        In debug mode the line is "[DEBUG] text" in grey, followed by the same line in the debug file
        when there is one. The built-in Write-Debug and $DebugPreference play no part.
    #>
    param([string]$Message)

    try {
        if (-not (Test-SwDebugEnabled)) { return }
        $text = ConvertTo-SwConsoleText -Text $Message
        Stop-SwSpinner
        $gray = Get-SwLogMark -Kind Color -Name 'Gray'
        $reset = Get-SwLogMark -Kind Color -Name 'NC'
        Write-SwDiagnosticLine -Message ('  ' + $gray + '[DEBUG] ' + $text + $reset)
        if (Test-SwSectionActive) { Start-SwSpinner }
        Add-SwDebugFileLine -Level 'DEBUG' -Text $Message
    }
    catch { $null = $_ }
}

function Enable-SwDebugMode {
    # Debug mode on for this process and its children (analyze.exe inherits the variable). Creates no
    # file or folder; the debug file is made by Start-SwDebugSession.
    try {
        [System.Environment]::SetEnvironmentVariable('SWEEPR_DEBUG', '1')
        $table = Get-SwLogConfigTable
        $table['DebugEnabled'] = $true
        if ([string]::IsNullOrEmpty((Get-SwDebugFilePath))) {
            try { $file = [string]$script:SweeprDebugLogFile } catch { $file = '' }
            if ([string]::IsNullOrEmpty($file)) { $table['LogFile'] = $null }
            else { $table['LogFile'] = $file }
        }
    }
    catch { $null = $_ }
}

function Start-SwDebugSession {
    <#
    .SYNOPSIS
        Turns debug mode on and starts a new debug file: a rule of 70 hyphens, the header lines, the rule.
    .DESCRIPTION
        An existing file is replaced. Without a usable file the session goes on without one and a warning
        names the path; nothing throws. Later message and debug lines go to the same file.
    #>
    param([string[]]$Header)

    Enable-SwDebugMode
    $file = ''
    try {
        try { $file = [string]$script:SweeprDebugLogFile } catch { $file = '' }
        if ([string]::IsNullOrEmpty($file)) { throw 'no debug log file is known' }

        $folder = [System.IO.Path]::GetDirectoryName($file)
        if (-not [string]::IsNullOrEmpty($folder) -and -not [System.IO.Directory]::Exists($folder)) {
            [void][System.IO.Directory]::CreateDirectory($folder)
        }

        $crlf = [string][char]13 + [string][char]10
        $rule = ('-' * 70) + $crlf
        $text = $rule
        if ($null -ne $Header) {
            foreach ($line in $Header) { $text += (ConvertTo-SwLogValue -Value ([string]$line)) + $crlf }
        }
        $text += $rule
        Write-SwLogFileText -File $file -Text $text -Replace
    }
    catch {
        (Get-SwLogConfigTable)['LogFile'] = $null
        try { Write-SwWarning -Message ('Debug log not written: ' + $file + ' (' + (Get-SwLogErrorText $_) + ')') }
        catch { $null = $_ }
        return
    }

    (Get-SwLogConfigTable)['LogFile'] = $file
    try {
        $gray = Get-SwLogMark -Kind Color -Name 'Gray'
        $reset = Get-SwLogMark -Kind Color -Name 'NC'
        Write-SwDiagnosticLine -Message ('  ' + $gray + 'Debug log: ' + (ConvertTo-SwConsoleText -Text $file) + $reset)
    }
    catch { $null = $_ }
}

function Complete-SwDebugSession {
    # Names the debug file at the end of a run, between two empty lines. Nothing without a file.
    try {
        $file = Get-SwDebugFilePath
        if ([string]::IsNullOrEmpty($file)) { return }
        $gray = Get-SwLogMark -Kind Color -Name 'Gray'
        $reset = Get-SwLogMark -Kind Color -Name 'NC'
        Write-SwDiagnosticLine -Message ''
        Write-SwDiagnosticLine -Message ('  ' + $gray + 'Debug log: ' + (ConvertTo-SwConsoleText -Text $file) + $reset)
        Write-SwDiagnosticLine -Message ''
    }
    catch { $null = $_ }
}

# ============================================================================
# Console messages
# ============================================================================

function Write-SwConsoleMessage {
    # One status line: two spaces, colour, symbol and a space, reset, text; in a single host call. The
    # spinner is stopped around it, because its animation would mix into the line, and restarted only
    # while a section is open. The same message goes to the debug file when there is one.
    param([string]$Level, [string]$Color, [string]$Icon, [string]$Message)

    try {
        $text = ConvertTo-SwConsoleText -Text $Message
        $colorText = Get-SwLogMark -Kind Color -Name $Color
        $iconText = Get-SwLogMark -Kind Icon -Name $Icon
        $reset = Get-SwLogMark -Kind Color -Name 'NC'
        if ($iconText.Length -gt 0) { $iconText = $iconText + ' ' }
        $line = '  ' + $colorText + $iconText + $reset + $text

        Stop-SwSpinner
        Write-Host $line
        if (Test-SwSectionActive) { Start-SwSpinner }
    }
    catch { $null = $_ }
    Add-SwDebugFileLine -Level $Level -Text $Message
}

function Write-SwInfo { param([string]$Message) Write-SwConsoleMessage -Level 'INFO' -Color 'Cyan' -Icon 'List' -Message $Message }

function Write-SwSuccess { param([string]$Message) Write-SwConsoleMessage -Level 'SUCCESS' -Color 'Green' -Icon 'Success' -Message $Message }

function Write-SwWarning { param([string]$Message) Write-SwConsoleMessage -Level 'WARN' -Color 'Yellow' -Icon 'Warning' -Message $Message }

function Write-SwError { param([string]$Message) Write-SwConsoleMessage -Level 'ERROR' -Color 'Red' -Icon 'Error' -Message $Message }

function Write-SwDryRun { param([string]$Message) Write-SwConsoleMessage -Level 'DRYRUN' -Color 'Yellow' -Icon 'DryRun' -Message $Message }

# ============================================================================
# Sections
# ============================================================================

function Start-SwSection {
    # Opens a section: remembers the title, prints a blank line and the title line, starts the spinner.
    # A section that is still open is not closed and gets no message.
    param([string]$Title)

    try {
        try { $collector = $script:SectionCollector } catch { $collector = $null }
        if ($null -ne $collector) {
            # The preview collects the titles; a collector that cannot take one is ignored.
            try { [void]$collector.Add($Title) }
            catch { $null = $_ }
        }

        Stop-SwSpinner
        $section = Get-SwSectionTable
        $section['Active'] = $true
        $section['Activity'] = $false
        $section['Name'] = $Title

        $colorText = Get-SwLogMark -Kind Color -Name 'PurpleBold'
        $iconText = Get-SwLogMark -Kind Icon -Name 'Arrow'
        $reset = Get-SwLogMark -Kind Color -Name 'NC'
        Write-Host ''
        Write-Host ($colorText + $iconText + ' ' + (ConvertTo-SwConsoleText -Text $Title) + $reset)
        Start-SwSpinner
    }
    catch { $null = $_ }
}

function Set-SwSectionActivity {
    # Marks the open section as having done something, so it does not close with "Nothing to tidy".
    try {
        $section = Get-SwSectionTable
        if ($section['Active'] -eq $true) { $section['Activity'] = $true }
    }
    catch { $null = $_ }
}

function Stop-SwSection {
    # Closes the section. One that was open and had no activity says so once. No spinner runs afterwards.
    try {
        Stop-SwSpinner
        $section = Get-SwSectionTable
        $quiet = (($section['Active'] -eq $true) -and ($section['Activity'] -ne $true))
        if ($quiet) {
            try { Write-SwSuccess -Message 'Nothing to tidy' }
            catch { $null = $_ }
        }
        $section['Active'] = $false
        # The message above restarted the spinner for the section that was still open.
        Stop-SwSpinner
    }
    catch { $null = $_ }
}

# ============================================================================
# Spinner and progress
# ============================================================================

function Test-SwInteractiveOutput {
    # True only on a real console: host ConsoleHost, neither standard output nor input redirected, and
    # TERM not "dumb". Any failure of a check means no.
    try {
        if ($Host.Name -ne 'ConsoleHost') { return $false }
        if ([Console]::IsOutputRedirected) { return $false }
        if ([Console]::IsInputRedirected) { return $false }
        $term = [System.Environment]::GetEnvironmentVariable('TERM')
        if (-not [string]::IsNullOrEmpty($term) -and $term.Equals('dumb', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        return $true
    }
    catch { return $false }
}

function Initialize-SwSpinner {
    # Compiles the animation class on first use (never at load); a second call finds the type and
    # does nothing, so the compiler is never asked for the same type twice.
    if ($null -ne ('Sweepr.SwSpinner' -as [type])) { return }

    # C# 5 only (Windows PowerShell 5.1 compiles with it): no interpolation, no ?., no expression bodies.
    # The animation thread calls only the console; it never calls back into the host.
    $source = @'
using System;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Sweepr
{
    public static class SwSpinner
    {
        // Braille U+2816, U+2832, U+2834, U+2826 and the tick between two frames.
        private static readonly string[] Glyphs = new string[] { ((char)0x2816).ToString(), ((char)0x2832).ToString(), ((char)0x2834).ToString(), ((char)0x2826).ToString() };
        private const int TickMilliseconds = 80;

        // Everything below is read and changed only while holding Sync, so a frame is never drawn
        // after Stop has returned and a label change cannot tear a frame.
        private static readonly object Sync = new object();
        private static readonly TextWriter OriginalOut;
        private static string label = "";
        private static int frame;
        private static bool drawn;
        private static ManualResetEvent current;
        private static Thread worker;

        static SwSpinner()
        {
            // The writer in place when the class is first used: while it still is the console's own
            // writer, frames go straight to the console in UTF-16, which keeps the Braille characters
            // on an old code page without changing it.
            try { OriginalOut = Console.Out; }
            catch (Exception) { OriginalOut = null; }
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GetStdHandle(int handle);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool WriteConsoleW(IntPtr handle, string text, uint length, out uint written, IntPtr reserved);

        public static void Start(string message)
        {
            string clean = Clean(message);
            try
            {
                lock (Sync)
                {
                    label = clean;
                    if (current != null) { return; }
                    frame = 0;
                    drawn = false;
                    ManualResetEvent run = new ManualResetEvent(false);
                    Thread thread = new Thread(new ParameterizedThreadStart(Run));
                    thread.IsBackground = true;
                    current = run;
                    worker = thread;
                    try { thread.Start(run); }
                    catch (Exception)
                    {
                        current = null;
                        worker = null;
                    }
                }
            }
            catch (Exception) { }
        }

        public static void Stop()
        {
            ManualResetEvent run = null;
            Thread thread = null;
            try
            {
                lock (Sync)
                {
                    run = current;
                    thread = worker;
                    current = null;
                    worker = null;
                    if (drawn)
                    {
                        drawn = false;
                        Emit("\r\u001b[2K");
                    }
                }
                if (run != null) { run.Set(); }
                if (thread != null && !object.ReferenceEquals(thread, Thread.CurrentThread)) { thread.Join(1000); }
            }
            catch (Exception) { }
        }

        // The part of value that fits into the given number of terminal cells, cut between text elements.
        public static string Fit(string value, int cells)
        {
            if (string.IsNullOrEmpty(value) || cells <= 0) { return ""; }
            int[] starts = StringInfo.ParseCombiningCharacters(value);
            int sum = 0;
            int end = 0;
            for (int i = 0; i < starts.Length; i++)
            {
                int next = value.Length;
                if (i + 1 < starts.Length) { next = starts[i + 1]; }
                int width = ElementCells(value, starts[i]);
                if (sum + width > cells) { break; }
                sum += width;
                end = next;
            }
            return value.Substring(0, end);
        }

        private static void Run(object state)
        {
            ManualResetEvent mine = (ManualResetEvent)state;
            try
            {
                while (!mine.WaitOne(TickMilliseconds))
                {
                    lock (Sync)
                    {
                        if (!object.ReferenceEquals(current, mine)) { return; }
                        Draw();
                    }
                }
            }
            catch (Exception) { }
        }

        private static void Draw()
        {
            string text = "\r\u001b[2K  \u001b[34m" + Glyphs[frame % Glyphs.Length] + "\u001b[0m " + Fit(label, LabelCells());
            frame++;
            drawn = true;
            Emit(text);
        }

        // Cells left for the label: the window width minus the margin and the symbol. A window that
        // cannot be measured counts as 80.
        private static int LabelCells()
        {
            try
            {
                int width = Console.WindowWidth;
                if (width > 0) { return Math.Max(1, width - 5); }
            }
            catch (Exception) { }
            return 80;
        }

        private static void Emit(string text)
        {
            try
            {
                if (Environment.OSVersion.Platform == PlatformID.Win32NT && OriginalOut != null && object.ReferenceEquals(Console.Out, OriginalOut))
                {
                    IntPtr handle = GetStdHandle(-11);
                    uint written;
                    if (handle != IntPtr.Zero && handle != new IntPtr(-1) && WriteConsoleW(handle, text, (uint)text.Length, out written, IntPtr.Zero))
                    {
                        return;
                    }
                }
            }
            catch (Exception) { }

            try { Console.Write(text); }
            catch (Exception) { }
        }

        private static string Clean(string value)
        {
            if (value == null) { return ""; }
            StringBuilder builder = new StringBuilder(value.Length);
            foreach (char c in value)
            {
                if (c < ' ' || (c >= '\u007f' && c <= '\u009f')) { builder.Append(' '); }
                else { builder.Append(c); }
            }
            return builder.ToString();
        }

        // Cells of the text element that starts at index, judged by its first code point.
        private static int ElementCells(string text, int index)
        {
            char first = text[index];
            int codePoint = first;
            if (char.IsHighSurrogate(first))
            {
                if (index + 1 < text.Length && char.IsLowSurrogate(text[index + 1])) { codePoint = char.ConvertToUtf32(first, text[index + 1]); }
                else { return 1; }
            }
            else if (char.IsLowSurrogate(first)) { return 1; }

            UnicodeCategory category = CharUnicodeInfo.GetUnicodeCategory(text, index);
            if (category == UnicodeCategory.NonSpacingMark || category == UnicodeCategory.EnclosingMark ||
                category == UnicodeCategory.Format || category == UnicodeCategory.Control) { return 0; }

            if (Within(codePoint, 0x1100, 0x115F) || Within(codePoint, 0x2329, 0x232A) || Within(codePoint, 0x2E80, 0x303E) ||
                Within(codePoint, 0x3040, 0xA4CF) || Within(codePoint, 0xAC00, 0xD7A3) || Within(codePoint, 0xF900, 0xFAFF) ||
                Within(codePoint, 0xFE10, 0xFE19) || Within(codePoint, 0xFE30, 0xFE6F) || Within(codePoint, 0xFF00, 0xFF60) ||
                Within(codePoint, 0xFFE0, 0xFFE6) || Within(codePoint, 0x1F300, 0x1FAFF) || Within(codePoint, 0x20000, 0x3FFFD)) { return 2; }
            return 1;
        }

        private static bool Within(int value, int low, int high)
        {
            return value >= low && value <= high;
        }
    }
}
'@
    Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
}

function Start-SwSpinner {
    # Starts the animation, or only replaces its label when it runs. Nothing when the spinner is switched
    # off or the output is not a console; a host that cannot compile the class keeps the static output.
    param([string]$Message = 'Working')

    try {
        try { if ($script:SpinnerDisabled -eq $true) { return } } catch { $null = $_ }
        if (-not (Test-SwInteractiveOutput)) { return }
        Initialize-SwSpinner
        [Sweepr.SwSpinner]::Start((ConvertTo-SwSpinnerText -Text $Message))
    }
    catch { $null = $_ }
}

function Update-SwSpinner {
    param([string]$Message = 'Working')

    Start-SwSpinner -Message $Message
}

function Stop-SwSpinner {
    # Stops the animation and clears its line. Does not compile anything when the class was never used,
    # and works when the spinner is switched off, because a running one must always be stoppable.
    try {
        $type = 'Sweepr.SwSpinner' -as [type]
        if ($null -ne $type) { $type::Stop() }
    }
    catch { $null = $_ }
}

function Write-SwProgress {
    # The progress call of the commands, shown as the label of the spinner: -Message, else "Activity,
    # Status", else Activity. Percent, count and width are accepted and not shown. Nothing goes to the
    # progress stream.
    param(
        [string]$Activity = 'Working',
        [string]$Status = '',
        [int]$PercentComplete = -1,
        [switch]$Completed,
        [int]$Current = 0,
        [int]$Total = 0,
        [string]$Message = '',
        [int]$Width = 30
    )

    try {
        if ($Completed) {
            Stop-SwSpinner
            return
        }
        if (-not [string]::IsNullOrEmpty($Message)) { $label = $Message }
        elseif (-not [string]::IsNullOrEmpty($Status)) { $label = $Activity + ', ' + $Status }
        else { $label = $Activity }
        Update-SwSpinner -Message $label
    }
    catch { $null = $_ }
}

# ============================================================================
# Old names, kept as forwarding functions (not aliases, so a test mock of either name behaves) until
# the callers move to the new ones. Write-Debug and Write-Progress have no CmdletBinding on purpose:
# they replace the built-in cmdlets in the caller's scope and must not add -Debug or output of their own.
# ============================================================================

function Write-SweeprOperation {
    param([string]$Action, [string]$Path, [string]$Detail = '')
    Write-SwOperation -Action $Action -Path $Path -Detail $Detail
}

function ConvertTo-SweeprLogValue {
    param([string]$Value)
    ConvertTo-SwLogValue -Value $Value
}

function Add-SweeprOperationText {
    param([string]$File, [string]$Text)
    Add-SwOperationText -File $File -Text $Text
}

function Write-Info {
    param([string]$Message)
    Write-SwInfo -Message $Message
}

function Write-Success {
    param([string]$Message)
    Write-SwSuccess -Message $Message
}

function Write-SweeprWarning {
    param([string]$Message)
    Write-SwWarning -Message $Message
}

function Write-SweeprError {
    param([string]$Message)
    Write-SwError -Message $Message
}

function Write-DryRun {
    param([string]$Message)
    Write-SwDryRun -Message $Message
}

function Write-Debug {
    param([string]$Message)
    Write-SwDebug -Message $Message
}

function Start-Section {
    param([string]$Title)
    Start-SwSection -Title $Title
}

function Stop-Section { Stop-SwSection }

function Set-SectionActivity { Set-SwSectionActivity }

function Test-SweeprInteractiveOutput { Test-SwInteractiveOutput }

function Initialize-SweeprSpinner { Initialize-SwSpinner }

function Start-Spinner {
    param([string]$Message = 'Working')
    Start-SwSpinner -Message $Message
}

function Update-Spinner {
    param([string]$Message = 'Working')
    Update-SwSpinner -Message $Message
}

function Stop-Spinner { Stop-SwSpinner }

function Write-Progress {
    param(
        [string]$Activity = 'Working',
        [string]$Status = '',
        [int]$PercentComplete = -1,
        [switch]$Completed,
        [int]$Current = 0,
        [int]$Total = 0,
        [string]$Message = '',
        [int]$Width = 30
    )
    Write-SwProgress -Activity $Activity -Status $Status -PercentComplete $PercentComplete -Completed:$Completed -Current $Current -Total $Total -Message $Message -Width $Width
}

function Enable-DebugMode { Enable-SwDebugMode }

function Start-SweeprDebugSession {
    param([string[]]$Header)
    Start-SwDebugSession -Header $Header
}

function Complete-SweeprDebugSession { Complete-SwDebugSession }

# ============================================================================
# State, evaluated once per load (see the header)
# ============================================================================

function Get-SwLogDirectory {
    # The folder of the log files: ConfigPath of the configuration when there is a usable one, else
    # .config\sweepr under the profile, else an empty string, which switches the files off. A folder
    # is never guessed, and nothing is created here.
    try { $config = $script:Config } catch { $config = $null }
    if ($config -is [System.Collections.IDictionary]) {
        try { $path = [string]$config['ConfigPath'] } catch { $path = '' }
        if (-not [string]::IsNullOrWhiteSpace($path)) { return $path }
    }
    $profileRoot = Get-SwLogEnv 'USERPROFILE'
    if ([string]::IsNullOrWhiteSpace($profileRoot)) { return '' }
    return (Join-SwLogPath (Join-SwLogPath $profileRoot '.config') 'sweepr')
}

$script:SweeprLogDir = Get-SwLogDirectory
if ($script:SweeprLogDir.Length -eq 0) {
    $script:SweeprOperationsLogFile = ''
    $script:SweeprDebugLogFile = ''
}
else {
    $script:SweeprOperationsLogFile = Join-SwLogPath $script:SweeprLogDir 'operations.log'
    $script:SweeprDebugLogFile = Join-SwLogPath $script:SweeprLogDir 'sweepr_debug_session.log'
}

$script:SweeprOperationsLogMaxBytes = 5242880
$script:SweeprOperationsLogStarted = $false

# Only the value 1 switches debug mode on at load; it is read again only by the next full load.
$swLogDebug = ((Get-SwLogEnv 'SWEEPR_DEBUG') -ceq '1')
$swLogDebugFile = $null
if ($swLogDebug -and $script:SweeprDebugLogFile.Length -gt 0) { $swLogDebugFile = $script:SweeprDebugLogFile }
$script:LogConfig = @{ DebugEnabled = $swLogDebug; LogFile = $swLogDebugFile }
Remove-Variable -Name swLogDebug, swLogDebugFile -ErrorAction SilentlyContinue

$script:CurrentSection = @{ Active = $false; Activity = $false; Name = '' }
$script:SectionCollector = $null
$script:SpinnerDisabled = $false

$script:SWEEPR_LOG_LOADED = $true

# Other modules rely on these for the rest of their run.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
