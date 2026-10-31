# Sweepr - router: help, version, menu and the start of the command scripts in bin\
#
# Entry point of sw, sweepr, sw.exe, sw.cmd and sweepr.cmd. It reads the words, answers --help and
# --version, shows the main menu, matches --options to the parameters of the command script, rejects what
# it does not understand before anything starts, prepares the data folder, the run for the operations log
# and the debug session, starts the script and hands its exit code on.
#
# The file has no param block and no [CmdletBinding()] on purpose. Windows PowerShell binds words such as
# -s, -w, -p, -v, -Debug and --verbose to parameters of its own as soon as a script declares any, and
# the installed launchers start the router with -File. Every word arrives in $args as data and is
# interpreted here, with the same result under -File and under -Command.
#
# Dot-sourcing the file (. .\sweepr.ps1) defines the functions and loads the modules and returns: no run,
# no exit, no output and no change to the environment. Otherwise the file runs Invoke-SwRouter with its
# words and ends with the exit code, but only for a code other than 0.
#
# Exit codes: 0 success; 1 an error of the router, a missing command script or a data folder that cannot
# be written; 2 a word the router rejects (unknown command, unknown option, extra word, missing or
# unwanted option value); any other value is the code of the command script's own exit statement.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SwDotSourced = ($MyInvocation.InvocationName -eq '.')

# Folder of this file, never the working directory and never a variable of the caller.
$script:SWEEPR_ROOT = $PSScriptRoot
if ([string]::IsNullOrEmpty($script:SWEEPR_ROOT)) { $script:SWEEPR_ROOT = [System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path) }
$script:SWEEPR_ROOT = $script:SWEEPR_ROOT.TrimEnd([char[]]@('\', '/'))
$script:SWEEPR_BIN = [System.IO.Path]::Combine($script:SWEEPR_ROOT, 'bin')
$script:SWEEPR_LIB = [System.IO.Path]::Combine($script:SWEEPR_ROOT, 'lib')
$script:SWEEPR_CORE = [System.IO.Path]::Combine($script:SWEEPR_LIB, 'core')

try {
    . ([System.IO.Path]::Combine($script:SWEEPR_CORE, 'version.ps1'))
    # Before common.ps1: the modules loaded there must not come from pwsh 7 module folders.
    Repair-SwModuleSearchPath
    $script:SWEEPR_VER = Get-SwInstalledVersion -RootDir $script:SWEEPR_ROOT
    . ([System.IO.Path]::Combine($script:SWEEPR_CORE, 'common.ps1'))
    . ([System.IO.Path]::Combine($script:SWEEPR_CORE, 'update_check.ps1'))
}
catch {
    if ($script:SwDotSourced) { throw }
    [Console]::Error.WriteLine('Sweepr cannot start: ' + $_.Exception.Message)
    exit 1
}

# The commands the router starts, in the order the hints name them.
$script:SwCommands = @('clean', 'uninstall', 'analyze', 'status', 'optimize', 'purge', 'history', 'features', 'check', 'update', 'remove')

# Parameters (and with them their aliases) that every script with [CmdletBinding()] gets from
# PowerShell. They are never options of a command: --verbose is an unknown option, not a request
# that PowerShell would act on.
$script:SwCommonParameters = @(
    'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ProgressAction', 'ErrorVariable',
    'WarningVariable', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable', 'WhatIf', 'Confirm'
)

# The menu entries: command, description.
$script:SwMenuEntries = @(
    @('clean', 'Free up disk space'),
    @('uninstall', 'Remove apps and their leftovers'),
    @('optimize', 'Refresh and tune the system'),
    @('analyze', 'Find out what takes the space'),
    @('status', 'Live CPU, memory and disk view')
)

# ============================================================================
# Small helpers
# ============================================================================

function Set-SwEnvironmentValue {
    # Sets an environment variable of this process, or removes it for a null value. A plain $null would
    # reach the .NET call as an empty string and leave an empty variable behind.
    param([string]$Name, [AllowNull()]$Value)

    if ($null -eq $Value) { [System.Environment]::SetEnvironmentVariable($Name, [NullString]::Value) }
    else { [System.Environment]::SetEnvironmentVariable($Name, [string]$Value) }
}

function Get-SwErrorMessage {
    # Message of an error record without the wrapper of a method call.
    param($ErrorRecord)

    $exception = $ErrorRecord.Exception
    while ($exception -is [System.Management.Automation.MethodInvocationException] -and $null -ne $exception.InnerException) {
        $exception = $exception.InnerException
    }
    return [string]$exception.Message
}

function New-SwResolution {
    # The result object of Resolve-SwCommandArguments. ExitCode is what the router ends with when the
    # result is not valid: 2 for a word it rejects, 1 for a damaged installation.
    param(
        [bool]$Valid,
        [hashtable]$Splat = @{},
        [string[]]$Words = @(),
        [string]$Message,
        [string]$Hint,
        [int]$ExitCode = 0,
        [string]$ScriptPath
    )

    # A typed parameter turns $null back into an empty string, so the object gets separate values.
    $messageValue = $null
    $hintValue = $null
    if (-not [string]::IsNullOrEmpty($Message)) { $messageValue = $Message }
    if (-not [string]::IsNullOrEmpty($Hint)) { $hintValue = $Hint }
    return [pscustomobject]@{
        Valid      = $Valid
        Splat      = $Splat
        Words      = [string[]]$Words
        Message    = $messageValue
        Hint       = $hintValue
        ExitCode   = $ExitCode
        ScriptPath = $ScriptPath
    }
}

function Write-SwRejection {
    # The message of a rejection through Write-SwError (which makes control characters harmless) and
    # its hint as a plain line.
    param($Resolution)

    Write-SwError -Message ([string]$Resolution.Message)
    if (-not [string]::IsNullOrEmpty([string]$Resolution.Hint)) { Write-Host ('  ' + [string]$Resolution.Hint) }
}

function New-SwUnknownCommand {
    param([string]$Name)

    return (New-SwResolution -Valid $false -ExitCode 2 -Message ('Unknown command: ' + $Name) `
            -Hint ('Commands: ' + ($script:SwCommands -join ', ') + '. Run sw --help for details.'))
}

# ============================================================================
# Install method and source commit
# ============================================================================

function Get-SwInstallMethod {
    <#
    .SYNOPSIS
        How this installation came to be: Portable, winget, Scoop, Source or Copy.
    .DESCRIPTION
        From the folder only: the marker file, the package folders of winget and Scoop, a .git folder or
        file. Nothing is started and nothing is read from the network.
    #>
    param([string]$RootDir)

    if (Test-SwPortable -RootDir $RootDir) { return 'Portable' }

    # Both separators count, and a closing one is added so that a folder name must match whole.
    $path = ([string]$RootDir).Replace('/', '\')
    if (-not $path.EndsWith('\')) { $path += '\' }
    if ($path.IndexOf('\Microsoft\WinGet\Packages\brummilab.Sweepr_', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return 'winget' }
    if ($path.IndexOf('\scoop\apps\sweepr\', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return 'Scoop' }

    try {
        $git = [System.IO.Path]::Combine($RootDir, '.git')
        if ([System.IO.Directory]::Exists($git) -or [System.IO.File]::Exists($git)) { return 'Source' }
    }
    catch { $null = $_ }
    return 'Copy'
}

function Get-SwSourceCommit {
    <#
    .SYNOPSIS
        The first seven characters of the commit a source installation is on, or $null.
    .DESCRIPTION
        Read from .git\HEAD, the loose file of a branch and packed-refs, without starting git. A .git
        file (a work tree link), a ref with a parent step, an unreadable or invalid file and every read
        error give $null, never an exception.
    #>
    param([string]$RootDir)

    try {
        $gitDir = [System.IO.Path]::Combine($RootDir, '.git')
        if (-not [System.IO.Directory]::Exists($gitDir)) { return $null }

        $hash = '\A[0-9a-fA-F]{40}\z'
        $head = ([System.IO.File]::ReadAllText([System.IO.Path]::Combine($gitDir, 'HEAD'))).Trim()
        if ([regex]::IsMatch($head, $hash)) { return $head.Substring(0, 7) }

        $match = [regex]::Match($head, '\Aref:[ \t]+(refs/\S+)\z')
        if (-not $match.Success) { return $null }
        $ref = $match.Groups[1].Value
        if ($ref.IndexOfAny([char[]]@('\', ':')) -ge 0) { return $null }
        $loose = $gitDir
        foreach ($segment in $ref.Split('/')) {
            if ($segment.Length -eq 0 -or $segment -eq '.' -or $segment -eq '..') { return $null }
            $loose = [System.IO.Path]::Combine($loose, $segment)
        }

        if ([System.IO.File]::Exists($loose)) {
            $text = ([System.IO.File]::ReadAllText($loose)).Trim()
            if ([regex]::IsMatch($text, $hash)) { return $text.Substring(0, 7) }
            return $null
        }

        $packed = [System.IO.Path]::Combine($gitDir, 'packed-refs')
        if ([System.IO.File]::Exists($packed)) {
            foreach ($line in [System.IO.File]::ReadAllLines($packed)) {
                $entry = [regex]::Match($line.Trim(), '\A([0-9a-fA-F]{40}) (.+)\z')
                if ($entry.Success -and $entry.Groups[2].Value -ceq $ref) { return $entry.Groups[1].Value.Substring(0, 7) }
            }
        }
    }
    catch { return $null }
    return $null
}

function Get-SwInstallDescription {
    # The install method; a source installation with a readable commit adds it: Source (abc1234).
    param([string]$RootDir)

    $method = Get-SwInstallMethod -RootDir $RootDir
    if ($method -ceq 'Source') {
        $commit = Get-SwSourceCommit -RootDir $RootDir
        if (-not [string]::IsNullOrEmpty($commit)) { return ('Source (' + $commit + ')') }
    }
    return $method
}

# ============================================================================
# Version and debug header
# ============================================================================

function Get-SwNativeArchitecture {
    <#
    .SYNOPSIS
        Architecture of the computer, not of this process, or Unknown. Never throws.
    .DESCRIPTION
        An x64 process on Windows on Arm sees AMD64 in its own environment, so the system-wide value in
        the registry comes first and the environment variable is only the fallback.
    #>
    try {
        $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
        $value = [string](Get-ItemProperty -LiteralPath $key -Name 'PROCESSOR_ARCHITECTURE' -ErrorAction Stop).PROCESSOR_ARCHITECTURE
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }
    catch { $null = $_ }
    try {
        $value = [System.Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE')
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }
    catch { $null = $_ }
    return 'Unknown'
}

function Show-SwVersion {
    <#
    .SYNOPSIS
        Six lines: Sweepr version, Windows, Architecture, PowerShell, Disk Free and Install.
    .DESCRIPTION
        No user or computer name, no network, no data folder. An error of the runtime information
        reaches the caller, which ends with exit code 1.
    #>
    $runtime = Get-SwRuntimeInfo
    $windows = Get-SwWindowsVersion
    $architecture = Get-SwNativeArchitecture
    $free = Get-SwFreeSpace
    $install = Get-SwInstallDescription -RootDir $script:SWEEPR_ROOT

    Write-Host ('Sweepr version ' + [string]$runtime['Version'])
    Write-Host ('Windows: ' + [string]$windows['Name'] + ' ' + [string]$windows['Version'])
    Write-Host ('Architecture: ' + [string]$architecture)
    Write-Host ('PowerShell: ' + [string]$runtime['PowerShell'])
    Write-Host ('Disk Free: ' + [string]$free)
    Write-Host ('Install: ' + [string]$install)
}

function Get-SwDebugHeader {
    <#
    .SYNOPSIS
        The header lines of a debug session: a title with the time, the command line, the environment.
    .DESCRIPTION
        CommandLine is the command and its words. When a query for the environment fails, one line says
        so and the first two lines stay. No user, computer or folder name appears except in the words
        the user typed. Never throws.
    #>
    param([AllowNull()][AllowEmptyString()][string]$CommandLine)

    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('Sweepr debug session ' + $stamp)
    $lines.Add('Command: sw ' + [string]$CommandLine)
    try {
        $runtime = Get-SwRuntimeInfo
        $windows = Get-SwWindowsVersion
        $architecture = Get-SwNativeArchitecture
        $install = Get-SwInstallDescription -RootDir $script:SWEEPR_ROOT
        $details = @(
            ('Sweepr: ' + [string]$runtime['Version']),
            ('Windows: ' + [string]$windows['Name'] + ' ' + [string]$windows['Version']),
            ('Architecture: ' + [string]$architecture),
            ('PowerShell: ' + [string]$runtime['PowerShell'] + ' (' + [string]$PSVersionTable['PSEdition'] + ')'),
            ('Install: ' + [string]$install)
        )
        foreach ($line in $details) { $lines.Add([string]$line) }
    }
    catch { $lines.Add('Environment details are not available.') }
    return [string[]]$lines.ToArray()
}

# ============================================================================
# Help and menu
# ============================================================================

function Show-SwHelp {
    <#
    .SYNOPSIS
        The help of the router: commands, examples and the --debug option.
    #>
    $heading = Get-SwColor -Name 'Yellow'
    $form = Get-SwColor -Name 'Cyan'
    $reset = Get-SwColor -Name 'NC'

    Show-SwLogo
    Write-Host ($heading + 'COMMANDS' + $reset)
    $commands = @(
        @('sw', 'Open the interactive menu'),
        @('sw clean', 'Free up disk space: temporary files, caches, logs'),
        @('sw uninstall', 'Remove apps and their leftover folders'),
        @('sw features', 'Remove or restore preinstalled apps and optional features'),
        @('sw check', 'Check this PC and write a report, nothing is changed'),
        @('sw optimize', 'Refresh caches and services, check the disk'),
        @('sw analyze', 'Disk explorer: find what takes the space'),
        @('sw status', 'Live view of CPU, memory, disks and network'),
        @('sw purge', 'Remove old build artifacts of your projects'),
        @('sw history', 'Show what Sweepr removed, recycled or skipped'),
        @('sw update', 'Update a source installation'),
        @('sw remove', 'Remove Sweepr from this computer'),
        @('sw --help', 'Show this help'),
        @('sw --version', 'Show the version and the environment')
    )
    foreach ($entry in $commands) {
        Write-Host ('  ' + $form + ([string]$entry[0]).PadRight(24) + $reset + [string]$entry[1])
    }
    Write-Host ''
    $examples = @(
        @('sw clean --dry-run', 'Preview what clean would remove'),
        @('sw clean --whitelist', 'Manage protected paths'),
        @('sw clean --system', 'Include system cleanup (as administrator)'),
        @('sw optimize --dry-run', 'Preview what optimize would do'),
        @('sw uninstall --dry-run', 'Preview an uninstall without running it'),
        @('sw uninstall --list', 'List installed apps (JSON when redirected)'),
        @('sw features --dry-run', 'Show the exact commands, change nothing'),
        @('sw features --restore', 'Restore what was removed earlier'),
        @('sw check --report', 'Also write an HTML report'),
        @('sw purge --dry-run', 'Preview which build artifacts would go'),
        @('sw purge --paths', 'Set the folders to search'),
        @('sw history --json', 'The operations log as JSON'),
        @('sw analyze D:\', 'Explore another drive'),
        @('sw analyze --json', 'Sizes as JSON'),
        @('sw status --json', 'One measurement as JSON')
    )
    foreach ($entry in $examples) {
        Write-Host ('  ' + $form + ([string]$entry[0]).PadRight(24) + $reset + [string]$entry[1])
    }
    Write-Host ''
    Write-Host ($heading + 'OPTIONS' + $reset)
    Write-Host ('  ' + $form + '--debug'.PadRight(24) + $reset + 'Write a debug log (not for status, history and remove)')
    Write-Host ('  ' + $form + '-h, --help'.PadRight(24) + $reset + 'With a command: show the help of that command')
    Write-Host ''
}

function Read-SwMenuKey {
    <#
    .SYNOPSIS
        Waits for one key and returns it (VirtualKeyCode and Character); the only key source of the menu.
    .DESCRIPTION
        With redirected input or without a console there is no key to wait for. That is an error with a
        message, never a wait that does not end.
    #>
    try {
        if ([System.Console]::IsInputRedirected) { throw 'the input is redirected' }
        return $Host.UI.RawUI.ReadKey([System.Management.Automation.Host.ReadKeyOptions]'NoEcho,IncludeKeyDown')
    }
    catch {
        throw ('Cannot read a key: ' + (Get-SwErrorMessage $_) + '. Run a command directly, for example sw clean --dry-run.')
    }
}

function Write-SwMenuFrame {
    # One complete drawing of the menu: blank line, logo, the entries, blank line, controls, hint.
    param([int]$Selected, $UpdateContext)

    $cyan = Get-SwColor -Name 'Cyan'
    $gray = Get-SwColor -Name 'Gray'
    $reset = Get-SwColor -Name 'NC'
    $arrow = Get-SwIcon -Name 'Arrow'

    Write-Host ''
    Show-SwLogo
    for ($i = 0; $i -lt $script:SwMenuEntries.Count; $i++) {
        $entry = $script:SwMenuEntries[$i]
        $text = [string]($i + 1) + '  ' + ([string]$entry[0]).PadRight(11) + [string]$entry[1]
        if ($i -eq $Selected) { Write-Host ('  ' + $cyan + $arrow + ' ' + $text + $reset) }
        else { Write-Host ('    ' + $text) }
    }
    Write-Host ''
    $up = Get-SwIcon -Name 'NavUp'
    $down = Get-SwIcon -Name 'NavDown'
    Write-Host ('  ' + $gray + $up + $down + ' Move   Enter Select   1-5 Run   M More   V Version   Q Quit' + $reset)
    Write-SwUpdateHint -Context $UpdateContext
}

function Show-SwMenu {
    <#
    .SYNOPSIS
        The main menu. Returns clean, uninstall, optimize, analyze, status, help, version or $null.
    .DESCRIPTION
        The whole menu is drawn before the first key is read and again after every key. On a real
        console the drawing goes back to where it started instead of clearing the screen; with
        redirected output it simply continues below. The cursor is hidden while the menu is open and
        shown again in every case. A key source that fails is an error, not a wait.
    #>
    param($UpdateContext)

    # Cursor control only on a real console; a redirected stream must stay a plain sequence of lines.
    $canMove = $false
    $top = 0
    $reserve = 20
    try {
        if (-not [System.Console]::IsOutputRedirected -and -not [System.Console]::IsInputRedirected) {
            $top = [System.Console]::CursorTop
            # Room for the whole drawing below the start, so that it can never scroll the start away.
            if ($top + $reserve -ge [System.Console]::BufferHeight) {
                [System.Console]::Out.Write(("`n" * $reserve))
                $top = [System.Console]::CursorTop - $reserve
                if ($top -lt 0) { $top = 0 }
                [System.Console]::SetCursorPosition(0, $top)
            }
            [System.Console]::CursorVisible = $false
            $canMove = $true
        }
    }
    catch { $canMove = $false }

    $selected = 0
    $drawn = $false
    try {
        while ($true) {
            if ($drawn -and $canMove) {
                try {
                    [System.Console]::SetCursorPosition(0, $top)
                    [System.Console]::Out.Write(([string][char]27 + '[J'))
                }
                catch { $canMove = $false }
            }
            Write-SwMenuFrame -Selected $selected -UpdateContext $UpdateContext
            $drawn = $true

            $key = Read-SwMenuKey
            $code = [int]$key.VirtualKeyCode
            $character = ([string]$key.Character).ToLowerInvariant()

            if ($code -eq 13) { return [string]$script:SwMenuEntries[$selected][0] }
            if ($code -eq 27 -or $character -eq 'q') { return $null }
            if ($code -eq 38 -or $character -eq 'k') { if ($selected -gt 0) { $selected-- }; continue }
            if ($code -eq 40 -or $character -eq 'j') { if ($selected -lt ($script:SwMenuEntries.Count - 1)) { $selected++ }; continue }
            if ($character -eq 'm') { return 'help' }
            if ($character -eq 'v') { return 'version' }
            if ($character.Length -eq 1) {
                $digit = [int][char]$character[0] - 48
                if ($digit -ge 1 -and $digit -le $script:SwMenuEntries.Count) { return [string]$script:SwMenuEntries[$digit - 1][0] }
            }
        }
    }
    finally {
        if ($canMove) {
            try { [System.Console]::CursorVisible = $true } catch { $null = $_ }
        }
    }
}

# ============================================================================
# Words of a command
# ============================================================================

function Resolve-SwCommandParameter {
    <#
    .SYNOPSIS
        The parameter of a script that the option Flag (without hyphens) stands for, or $null.
    .DESCRIPTION
        The first declared parameter whose name or alias equals Flag, in any letter case. The common
        parameters and their aliases never match, whether or not the script has [CmdletBinding()].
        After that help means ShowHelp and debug means DebugMode, but only for a script that declares
        that parameter. Never throws.
    #>
    param([System.Collections.IDictionary]$Parameters, [string]$Flag)

    try {
        if ([string]::IsNullOrWhiteSpace($Flag) -or $null -eq $Parameters) { return $null }
        $declared = New-Object System.Collections.Generic.List[string]
        foreach ($parameter in $Parameters.Values) {
            if ($script:SwCommonParameters -contains [string]$parameter.Name) { continue }
            $declared.Add([string]$parameter.Name)
            if ([string]::Equals([string]$parameter.Name, $Flag, [System.StringComparison]::OrdinalIgnoreCase)) { return [string]$parameter.Name }
            foreach ($alias in @($parameter.Aliases)) {
                if ([string]::Equals([string]$alias, $Flag, [System.StringComparison]::OrdinalIgnoreCase)) { return [string]$parameter.Name }
            }
        }
        if ($Flag -ieq 'help' -and $declared -contains 'ShowHelp') { return 'ShowHelp' }
        if ($Flag -ieq 'debug' -and $declared -contains 'DebugMode') { return 'DebugMode' }
    }
    catch { return $null }
    return $null
}

function Get-SwInvocationPath {
    <#
    .SYNOPSIS
        A file path in the form the call operator reads as exactly that file.
    .DESCRIPTION
        Windows PowerShell 5.1 reads [ ] * ? in a command path as a pattern, so a folder called d[1]
        would run a script of a folder called d1. Escaping makes the pattern match the literal name.
        PowerShell 7 takes an existing path literally and would not find the escaped form, so there
        the path stays as it is. A path without these characters is never changed.
    #>
    param([string]$Path)

    if ($PSVersionTable.PSVersion.Major -ge 6) { return $Path }
    if ($Path.IndexOfAny([char[]]'[]*?') -lt 0) { return $Path }
    return [System.Management.Automation.WildcardPattern]::Escape($Path)
}

function Get-SwScriptParameters {
    <#
    .SYNOPSIS
        The parameter table of a script file, read without starting the script.
    .DESCRIPTION
        Get-Command expands wildcards in a path, so a folder named d[1] could resolve to a folder d1.
        Instead the file is parsed from its literal path and its code is wrapped in a function that
        exists only for the moment the parameters are read.
    #>
    param([string]$Path)

    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { throw ('The script has a syntax error: ' + [string]@($errors)[0].Message) }
    # A dynamicparam block runs while the parameters are read, which must not start any of the script.
    if ($null -ne $ast.DynamicParamBlock) { throw 'The script has a dynamicparam block.' }

    $probe = 'SwProbe' + [guid]::NewGuid().ToString('N')
    Set-Item -LiteralPath ('Function:\' + $probe) -Value $ast.GetScriptBlock()
    try { return , ((Get-Command -Name $probe -CommandType Function).Parameters) }
    finally { Remove-Item -LiteralPath ('Function:\' + $probe) -ErrorAction SilentlyContinue }
}

function Resolve-SwCommandArguments {
    <#
    .SYNOPSIS
        Maps the words of a command to the parameters of its script, or rejects them. Starts nothing.
    .DESCRIPTION
        Returns Valid, Splat (parameter name to value), Words (the loose words, in order), Message and
        Hint (set for a rejection), ExitCode and ScriptPath. Writes nothing and changes nothing.

        A word is an option when it is - or -- and a name, optionally with =value or :value. Anything
        else is a loose word: a path, a single hyphen, a lone --, --name=, words with other dashes.
        A switch takes no value. Another parameter takes the value after = or :, or the next word, unless
        that looks like an option: then a string parameter is an error, and an untyped one gets $true.
        A script takes as many loose words as it has positional parameters, any number when it
        collects the rest, otherwise none. The first word over that is an error.
    #>
    param(
        [string]$CommandName,
        [AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments = @()
    )

    $name = ([string]$CommandName).ToLowerInvariant()
    if (-not [regex]::IsMatch($name, '\A[a-z][a-z0-9-]*\z')) { return (New-SwUnknownCommand -Name ([string]$CommandName)) }

    try { $scriptPath = [System.IO.Path]::Combine([string]$script:SWEEPR_BIN, ($name + '.ps1')) }
    catch { $scriptPath = '' }
    $present = $false
    if ($scriptPath.Length -gt 0) {
        try { $present = [System.IO.File]::Exists($scriptPath) } catch { $present = $false }
    }
    if (-not $present) {
        return (New-SwResolution -Valid $false -ExitCode 1 -Message ('Cannot run sw ' + $name + ': its script is missing (' + $scriptPath + '). The installation is damaged.') `
                -Hint 'Reinstall Sweepr to restore the missing file.')
    }

    try { $parameters = Get-SwScriptParameters -Path $scriptPath }
    catch {
        return (New-SwResolution -Valid $false -ExitCode 1 -Message ('Cannot run sw ' + $name + ': its script cannot be read (' + (Get-SwErrorMessage $_) + ').') `
                -Hint 'Reinstall Sweepr to restore the file.')
    }

    $help = 'Run sw ' + $name + ' --help to see the options.'
    $splat = @{}
    $words = New-Object System.Collections.Generic.List[string]
    $list = @($Arguments | ForEach-Object { [string]$_ })
    $i = 0
    while ($i -lt $list.Count) {
        $word = $list[$i]
        $i++

        $option = [regex]::Match($word, '\A-{1,2}([\w-]+)\z')
        $value = $null
        if (-not $option.Success) {
            $option = [regex]::Match($word, '(?s)\A-{1,2}([\w-]+)[=:](.+)\z')
            if ($option.Success) { $value = $option.Groups[2].Value }
        }
        # A name without a letter or digit (a lone --) is a word, not an option.
        if (-not $option.Success -or -not [regex]::IsMatch($option.Groups[1].Value, '\w')) {
            $words.Add($word)
            continue
        }

        $parameterName = Resolve-SwCommandParameter -Parameters $parameters -Flag $option.Groups[1].Value
        if ($null -eq $parameterName) {
            return (New-SwResolution -Valid $false -ExitCode 2 -Message ('Unknown option for sw ' + $name + ': ' + $word) -Hint $help)
        }
        $parameterType = $parameters[$parameterName].ParameterType

        if ($parameterType -eq [System.Management.Automation.SwitchParameter]) {
            if ($null -ne $value) {
                return (New-SwResolution -Valid $false -ExitCode 2 -Message ('Option takes no value for sw ' + $name + ': ' + $word) -Hint $help)
            }
            $splat[$parameterName] = $true
            continue
        }

        if ($null -ne $value) {
            $splat[$parameterName] = $value
            continue
        }
        if ($i -lt $list.Count -and -not [regex]::IsMatch($list[$i], '\A-{1,2}[A-Za-z]')) {
            $splat[$parameterName] = $list[$i]
            $i++
            continue
        }
        if ($parameterType -eq [object]) {
            # The script reports a missing value itself.
            $splat[$parameterName] = $true
            continue
        }
        return (New-SwResolution -Valid $false -ExitCode 2 -Message ('Option needs a value for sw ' + $name + ': ' + $word) -Hint $help)
    }

    $capacity = 0
    $unlimited = $false
    foreach ($parameter in $parameters.Values) {
        if ($script:SwCommonParameters -contains [string]$parameter.Name) { continue }
        $positional = $false
        foreach ($set in $parameter.ParameterSets.Values) {
            if ([int]$set.Position -ge 0) { $positional = $true }
            if ([bool]$set.ValueFromRemainingArguments) { $unlimited = $true }
        }
        if ($positional) { $capacity++ }
    }
    if (-not $unlimited -and $words.Count -gt $capacity) {
        return (New-SwResolution -Valid $false -ExitCode 2 -Message ('Unexpected argument for sw ' + $name + ': ' + $words[$capacity]) -Hint $help)
    }

    return (New-SwResolution -Valid $true -Splat $splat -Words $words.ToArray() -ScriptPath $scriptPath)
}

# ============================================================================
# Data folder
# ============================================================================

function Initialize-SwDataDir {
    <#
    .SYNOPSIS
        Makes SWEEPR_DATA_DIR the data folder of this run and checks that it can be written.
    .DESCRIPTION
        In portable mode SWEEPR_DATA_DIR becomes <program folder>\data, in override mode the cleaned up
        form of what the user set; in profile mode nothing changes. A portable or override folder is
        tried (config and cache) before anything is created, and when it cannot be written the run
        stops with that message. There is no fall back to another folder.
    #>
    $paths = Resolve-SwDataPaths -RootDir $script:SWEEPR_ROOT
    $mode = [string]$paths['Mode']
    if ($mode -ne 'Portable' -and $mode -ne 'Override') { return }

    $folder = [System.IO.Path]::GetDirectoryName([string]$paths['ConfigPath'])
    if (-not [string]::IsNullOrEmpty($folder)) { Set-SwEnvironmentValue -Name 'SWEEPR_DATA_DIR' -Value $folder }
    Assert-SwDataWritable -Path ([string]$paths['ConfigPath'])
    Assert-SwDataWritable -Path ([string]$paths['CachePath'])
}

# ============================================================================
# Running a command
# ============================================================================

function Invoke-SwCommand {
    <#
    .SYNOPSIS
        Starts bin\<command>.ps1 with the options and words and sets $script:SweeprExitCode.
    .DESCRIPTION
        The output of the script goes to the pipeline unchanged and the router adds nothing. The words
        are checked first (Resolve-SwCommandArguments); a rejection writes its message and hint and
        sets the code, and nothing else happens. For a run the router sets the run values for the
        operations log, starts a debug session when --debug is given and ends it afterwards in every
        case, and puts SWEEPR_DRY_RUN, SWEEPR_DEBUG and the run values back to what they were.

        The code is the value of an explicit exit statement of the script and otherwise 0. A native
        program that the script started and the old value of $LASTEXITCODE do not count: the code is set
        to 0 before the call and read after it. A false $? with a code of 0 (a script whose last
        statement wrote a non-terminating error) is still 0.
    #>
    param(
        [string]$CommandName,
        [AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments = @()
    )

    $resolution = Resolve-SwCommandArguments -CommandName $CommandName -Arguments $Arguments
    if (-not $resolution.Valid) {
        Write-SwRejection -Resolution $resolution
        $script:SweeprExitCode = $resolution.ExitCode
        return
    }

    $name = ([string]$CommandName).ToLowerInvariant()
    $splat = $resolution.Splat
    $words = $resolution.Words
    $commandLine = [string]::Join(' ', @(@($name) + @($Arguments | ForEach-Object { [string]$_ })))

    $names = @('SWEEPR_DRY_RUN', 'SWEEPR_DEBUG', '_SWEEPR_OPLOG_RUN_COMMAND', '_SWEEPR_OPLOG_RUN_ID')
    $saved = @{}
    foreach ($variable in $names) { $saved[$variable] = [System.Environment]::GetEnvironmentVariable($variable) }

    $script:SweeprExitCode = 1
    $session = $false
    try {
        $stamp = (Get-Date).ToString('yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
        $random = [string](Get-Random -Minimum 0 -Maximum 100000)
        Set-SwEnvironmentValue -Name '_SWEEPR_OPLOG_RUN_COMMAND' -Value $name
        Set-SwEnvironmentValue -Name '_SWEEPR_OPLOG_RUN_ID' -Value ($stamp + '-' + $PID + '-' + $random)
        $global:LASTEXITCODE = 0

        # The script loads the log module again and reads SWEEPR_DEBUG then, so the session comes first.
        if ($splat.ContainsKey('DebugMode')) {
            $session = $true
            Start-SwDebugSession -Header (Get-SwDebugHeader -CommandLine $commandLine)
        }

        $scriptPath = $resolution.ScriptPath
        & (Get-SwInvocationPath -Path $scriptPath) @splat @words
        $succeeded = $?
        $last = [int]$global:LASTEXITCODE
        $script:SweeprExitCode = 0
        if (-not $succeeded -and $last -ne 0) { $script:SweeprExitCode = $last }
    }
    finally {
        if ($session) { Complete-SwDebugSession }
        foreach ($variable in $names) { Set-SwEnvironmentValue -Name $variable -Value $saved[$variable] }
    }
}

function Invoke-SwDispatch {
    # What the words mean: menu, help, version, a rejection or a command. Sets $script:SweeprExitCode.
    param([string[]]$Words)

    $list = New-Object System.Collections.Generic.List[string]
    foreach ($word in $Words) { $list.Add([string]$word) }

    # Empty words before the first real one are ignored.
    $start = 0
    while ($start -lt $list.Count -and [string]::IsNullOrWhiteSpace($list[$start])) { $start++ }

    if ($start -ge $list.Count) {
        Invoke-SwMenuRun
        return
    }

    $first = $list[$start]
    $rest = New-Object System.Collections.Generic.List[string]
    for ($i = $start + 1; $i -lt $list.Count; $i++) { $rest.Add($list[$i]) }

    # A leading --debug moves behind the command, so it reaches the script as its own option.
    if ($first -imatch '\A-{1,2}debug\z' -and $rest.Count -gt 0) {
        $first = $rest[0]
        $rest.RemoveAt(0)
        $rest.Add('--debug')
    }
    elseif ($first -match '(?s)\A-{1,2}(.+)\z') {
        $flag = $Matches[1].ToLowerInvariant()
        if ($flag -ceq 'help' -or $flag -ceq 'h' -or $flag -ceq 'showhelp') {
            Show-SwHelp
            $script:SweeprExitCode = 0
            return
        }
        if ($flag -ceq 'version' -or $flag -ceq 'v') {
            Show-SwVersion
            $script:SweeprExitCode = 0
            return
        }
    }

    $name = $first.ToLowerInvariant()
    if ($script:SwCommands -cnotcontains $name) {
        Write-SwRejection -Resolution (New-SwUnknownCommand -Name $first)
        $script:SweeprExitCode = 2
        return
    }

    $arguments = $rest.ToArray()
    $resolution = Resolve-SwCommandArguments -CommandName $name -Arguments $arguments
    if (-not $resolution.Valid) {
        Write-SwRejection -Resolution $resolution
        $script:SweeprExitCode = $resolution.ExitCode
        return
    }

    Initialize-SwDataDir
    Initialize-SwDataFolders

    $allowed = [bool](Test-SwUpdateHintAllowed -CommandName $name -Arguments $arguments)
    $context = $null
    if ($allowed) { $context = Start-SwUpdateProbe -RootDir $script:SWEEPR_ROOT -Version $script:SWEEPR_VER -Method (Get-SwInstallMethod -RootDir $script:SWEEPR_ROOT) }

    Invoke-SwCommand -CommandName $name -Arguments $arguments
    if ($script:SweeprExitCode -eq 0 -and $allowed) { Write-SwUpdateHint -Context $context }
}

function Invoke-SwMenuRun {
    # The menu: one choice, one run, then the router ends (no way back into the menu).
    Initialize-SwDataDir
    Initialize-SwDataFolders

    $allowed = [bool](Test-SwUpdateHintAllowed -CommandName $null -Arguments @())
    $context = $null
    if ($allowed) { $context = Start-SwUpdateProbe -RootDir $script:SWEEPR_ROOT -Version $script:SWEEPR_VER -Method (Get-SwInstallMethod -RootDir $script:SWEEPR_ROOT) }

    $choice = Show-SwMenu -UpdateContext $context
    Clear-Host
    $script:SweeprExitCode = 0
    if ([string]::IsNullOrEmpty([string]$choice)) { return }
    if ($choice -ceq 'help') { Show-SwHelp; return }
    if ($choice -ceq 'version') { Show-SwVersion; return }

    Invoke-SwCommand -CommandName ([string]$choice) -Arguments @()
    if ($script:SweeprExitCode -eq 0 -and $allowed) { Write-SwUpdateHint -Context $context }
}

function Invoke-SwRouter {
    <#
    .SYNOPSIS
        Runs the router for the words; the output of the command goes to the pipeline.
    .DESCRIPTION
        Never throws: an exception is reported as a blank line, an error line and a blank line, with the
        code 1. Afterwards $script:SweeprExitCode and $global:LASTEXITCODE hold the result (0 after
        success, so that exit $LASTEXITCODE of the -Command form is right and an old value never gets
        through), and SWEEPR_DATA_DIR is what it was before. Nothing is returned, so a native program
        started by the command still talks to the console directly.
    #>
    param([AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments = @())

    $script:SweeprExitCode = 1
    $savedData = [System.Environment]::GetEnvironmentVariable('SWEEPR_DATA_DIR')
    try {
        Invoke-SwDispatch -Words @($Arguments)
    }
    catch {
        $message = Get-SwErrorMessage $_
        # The message of the data folder check already says everything.
        if (-not $message.StartsWith('Sweepr data folder is not writable:', [System.StringComparison]::Ordinal)) { $message = 'An error occurred: ' + $message }
        Write-Host ''
        Write-SwError -Message $message
        Write-Host ''
        $script:SweeprExitCode = 1
    }
    finally {
        Set-SwEnvironmentValue -Name 'SWEEPR_DATA_DIR' -Value $savedData
    }
    $global:LASTEXITCODE = [int]$script:SweeprExitCode
}

function Invoke-SwMain {
    <#
    .SYNOPSIS
        The router for the words in Arguments (the form of $args); returns the exit code as an [int].
    .DESCRIPTION
        The output of the command comes first, the code is the last item. Only the top level of this
        file calls exit.
    #>
    param([AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments = @())

    Invoke-SwRouter -Arguments $Arguments
    return [int]$script:SweeprExitCode
}

if (-not $script:SwDotSourced) {
    Invoke-SwRouter -Arguments $args
    $swCode = [int]$script:SweeprExitCode
    if ($swCode -ne 0) { exit $swCode }
}
