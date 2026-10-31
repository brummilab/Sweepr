# Sweepr - tests for what the router shows and reads: the version lines, the help, the menu and its keys,
# the debug header, the architecture, and the install method read from the folder (RT-13, RT-18, RT-19,
# RT-20, RT-23, S10).
#
# The rule numbers in the test names (RT- and S) number the rules and the safety invariants of the
# router's behavior; each testable rule and invariant has at least one test. The other router files are
# SwRouterLoad (RT-1 to RT-3), SwRouterArgs (RT-5 to RT-10, RT-24), SwRouterCommand (RT-11 to RT-15),
# SwRouterMain (RT-4, RT-16, RT-17, RT-21) and SwRouterProcess (the two call forms).
#
# Interface pinned here (sweepr.ps1 is loaded by dot-sourcing):
#   Show-SwVersion, Show-SwHelp (host lines only), Show-SwMenu -UpdateContext (returns 'clean',
#   'uninstall', 'optimize', 'analyze', 'status', 'help', 'version' or $null), Read-SwMenuKey (object with
#   VirtualKeyCode and Character; the only key source of the menu), Get-SwNativeArchitecture,
#   Get-SwDebugHeader -CommandLine (string[]), Get-SwInstallMethod -RootDir, Get-SwInstallDescription
#   -RootDir, Get-SwSourceCommit -RootDir.
#
# Platform notes:
#   - The host lines are read from the information stream. Modules are mocked where a test needs to
#     control or see them. A program called git that leaves a mark when it runs stands first in PATH
#     during the install tests, to show that nothing starts git. Nothing real is touched.
#   - Tests marked [W] describe a Windows fact and are meant to fail on Linux where it does not hold.
#   - Non-ASCII text is built from code points, so this file stays ASCII.

BeforeDiscovery {
    $script:IsWindowsHost = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:RouterFile = Join-Path $script:RepoRoot 'sweepr.ps1'
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
    $script:IsWin = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
    $script:EnvNames = @('SWEEPR_DATA_DIR', 'SWEEPR_DRY_RUN', 'SWEEPR_DEBUG', '_SWEEPR_OPLOG_RUN_COMMAND', '_SWEEPR_OPLOG_RUN_ID', 'USERPROFILE', 'HOME', 'SWEEPR_NO_OPLOG', 'PROCESSOR_ARCHITECTURE', 'PATH')
    $script:SavedEnv = @{}
    foreach ($envName in $script:EnvNames) { $script:SavedEnv[$envName] = [System.Environment]::GetEnvironmentVariable($envName) }
    $script:SavedCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture

    $script:HomeDir = Join-Path $TestDrive 'screens-home'
    [void][System.IO.Directory]::CreateDirectory($script:HomeDir)
    $env:USERPROFILE = $script:HomeDir
    $env:HOME = $script:HomeDir
    $env:SWEEPR_DATA_DIR = Join-Path $script:HomeDir 'data'
    $env:SWEEPR_NO_OPLOG = '1'

    . $script:RouterFile

    # The real functions, kept to put them back after a mock of the same name.
    $script:Real = @{}
    foreach ($name in 'Get-SwRuntimeInfo', 'Get-SwWindowsVersion', 'Get-SwNativeArchitecture', 'Get-SwFreeSpace', 'Get-SwInstallMethod', 'Get-SwInstallDescription', 'Show-SwLogo') {
        $script:Real[$name] = (Get-Command -Name $name -CommandType Function).ScriptBlock
    }

    # An unset variable is removed: .NET 8 treats an empty value as unset, newer .NET keeps it as an empty value.
    function script:Set-EnvValue {
        param([string]$Name, $Value)
        if ($null -eq $Value) { [System.Environment]::SetEnvironmentVariable($Name, [NullString]::Value) }
        else { [System.Environment]::SetEnvironmentVariable($Name, [string]$Value) }
    }

    function script:Remove-Ansi([string]$Text) { return [regex]::Replace($Text, '\x1b\[[0-9;?]*[A-Za-z]', '') }
    # The host lines of the block as records: Text, Color (the console colour name or '') and NoNewLine.
    function script:Invoke-Records([scriptblock]$Block) {
        $thrown = $null
        $records = @()
        try { $records = @(& $Block 6>&1) } catch { $thrown = $_ }
        $out = New-Object System.Collections.Generic.List[object]
        $lines = New-Object System.Collections.Generic.List[object]
        foreach ($record in $records) {
            if ($record -is [System.Management.Automation.InformationRecord]) {
                $message = $record.MessageData
                $color = ''
                $noNewLine = $false
                if ($message -is [System.Management.Automation.HostInformationMessage]) {
                    if ($null -ne $message.ForegroundColor) { $color = [string]$message.ForegroundColor }
                    $noNewLine = [bool]$message.NoNewLine
                    $text = [string]$message.Message
                }
                else { $text = [string]$message }
                $lines.Add([pscustomobject]@{ Text = $text; Color = $color; NoNewLine = $noNewLine })
            }
            else { $out.Add($record) }
        }
        return [pscustomobject]@{ Output = $out.ToArray(); Records = $lines.ToArray(); Thrown = $thrown }
    }
    # Joins the segments written without a line end into lines; keeps the colours seen in a line.
    function script:Get-ScreenLines($Result) {
        $lines = New-Object System.Collections.Generic.List[object]
        $buffer = ''
        $colors = New-Object System.Collections.Generic.List[string]
        foreach ($record in @($Result.Records)) {
            $buffer += $record.Text
            if ($record.Color -ne '' -and $record.Color -ne '-1') { $colors.Add($record.Color) }
            if (-not $record.NoNewLine) {
                $lines.Add([pscustomobject]@{ Raw = $buffer; Text = (Remove-Ansi $buffer); Colors = $colors.ToArray() })
                $buffer = ''
                $colors = New-Object System.Collections.Generic.List[string]
            }
        }
        if ($buffer -ne '') { $lines.Add([pscustomobject]@{ Raw = $buffer; Text = (Remove-Ansi $buffer); Colors = $colors.ToArray() }) }
        return $lines.ToArray()
    }
    function script:Get-Texts($Lines) { return @($Lines | ForEach-Object { $_.Text }) }
}

AfterAll {
    foreach ($envName in $script:SavedEnv.Keys) { Set-EnvValue -Name $envName -Value $script:SavedEnv[$envName] }
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $script:SavedCulture
}

Describe 'Show-SwVersion (RT-18)' {
    BeforeEach {
        Mock Get-SwRuntimeInfo { @{ Version = '1.2.3'; PowerShell = '7.4.6'; Windows = '10.0.22631' } }
        Mock Get-SwWindowsVersion { @{ Name = 'Windows Example'; Version = '10.0.22631'; Build = '22631'; Arch = 'x64' } }
        Mock Get-SwNativeArchitecture { 'ARM64' }
        Mock Get-SwFreeSpace { '12.3 GB' }
        Mock Get-SwInstallDescription { 'Source (abc1234)' }
        Mock Start-SwUpdateProbe { throw 'no update lookup' }
        Mock Write-SwUpdateHint { throw 'no update hint' }
        Mock Initialize-SwDataFolders { throw 'no data folder' }
        Mock Start-Process { throw 'no process' }
        Mock Invoke-WebRequest { throw 'no network' }
    }

    It 'Writes exactly these six lines in this order, each starting with its label' {
        $result = Invoke-Records { Show-SwVersion }
        $result.Thrown | Should -BeNullOrEmpty
        @($result.Output).Count | Should -Be 0
        $lines = @(Get-ScreenLines $result | ForEach-Object { $_.Text.Trim() })
        $lines.Count | Should -Be 6
        $lines[0] | Should -MatchExactly '^Sweepr version 1\.2\.3$'
        $lines[1] | Should -MatchExactly '^Windows: Windows Example 10\.0\.22631$'
        $lines[2] | Should -MatchExactly '^Architecture: ARM64$'
        $lines[3] | Should -MatchExactly '^PowerShell: 7\.4\.6$'
        $lines[4] | Should -MatchExactly '^Disk Free: 12\.3 GB$'
        $lines[5] | Should -MatchExactly '^Install: Source \(abc1234\)$'
    }

    It 'Asks for the install description of this installation' {
        $null = Invoke-Records { Show-SwVersion }
        Should -Invoke Get-SwInstallDescription -Times 1 -Exactly -ParameterFilter { $RootDir -eq $script:SWEEPR_ROOT }
    }

    It 'Starts no update lookup, shows no hint, makes no data folder, starts no process and uses no network' {
        $null = Invoke-Records { Show-SwVersion }
        Should -Invoke Start-SwUpdateProbe -Times 0 -Exactly
        Should -Invoke Write-SwUpdateHint -Times 0 -Exactly
        Should -Invoke Initialize-SwDataFolders -Times 0 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'Shows the real values in the expected shape, without a user or machine name' {
        Mock Get-SwRuntimeInfo { & $script:Real['Get-SwRuntimeInfo'] }
        Mock Get-SwWindowsVersion { & $script:Real['Get-SwWindowsVersion'] }
        Mock Get-SwNativeArchitecture { & $script:Real['Get-SwNativeArchitecture'] }
        Mock Get-SwFreeSpace { & $script:Real['Get-SwFreeSpace'] }
        Mock Get-SwInstallDescription { & $script:Real['Get-SwInstallDescription'] @PesterBoundParameters }
        $result = Invoke-Records { Show-SwVersion }
        $result.Thrown | Should -BeNullOrEmpty
        $text = (Get-Texts (Get-ScreenLines $result)) -join "`n"
        $text | Should -Match '(?m)^Sweepr version \d+\.\d+\.\d+'
        $text | Should -Match '(?m)^Windows: '
        $text | Should -Match '(?m)^Architecture: \S+'
        $text | Should -Match '(?m)^PowerShell: \d'
        $text | Should -Match '(?m)^Disk Free: '
        $text | Should -Match '(?m)^Install: (Source|Portable|winget|Scoop|Copy)'
        foreach ($forbidden in @([System.Environment]::UserName, [System.Environment]::MachineName)) {
            if ($forbidden.Length -ge 4) { $text.IndexOf($forbidden, [System.StringComparison]::OrdinalIgnoreCase) | Should -BeLessThan 0 }
        }
    }

    It 'Passes an error of the runtime information to the caller, which gives exit 1' {
        Mock Get-SwRuntimeInfo { throw 'the runtime information is not available' }
        $result = Invoke-Records { Show-SwVersion }
        $result.Thrown | Should -Not -BeNullOrEmpty
        $result.Thrown.Exception.Message | Should -Match 'runtime information'
    }
}

Describe 'Get-SwNativeArchitecture (RT-18)' {
    BeforeEach {
        Set-EnvValue -Name 'PROCESSOR_ARCHITECTURE' -Value $null
    }
    AfterEach {
        Set-EnvValue -Name 'PROCESSOR_ARCHITECTURE' -Value $script:SavedEnv['PROCESSOR_ARCHITECTURE']
    }

    It 'Falls back to the environment variable when the registry value cannot be read' -Skip:$script:IsWindowsHost {
        $env:PROCESSOR_ARCHITECTURE = 'ARM64'
        Mock Get-ItemProperty { throw 'the registry value cannot be read' }
        Get-SwNativeArchitecture | Should -BeExactly 'ARM64'
    }

    It 'Returns Unknown when neither the registry nor the environment gives a value' -Skip:$script:IsWindowsHost {
        Mock Get-ItemProperty { throw 'the registry value cannot be read' }
        Get-SwNativeArchitecture | Should -BeExactly 'Unknown'
    }

    It 'Never throws' {
        Mock Get-ItemProperty { throw 'the registry value cannot be read' }
        $thrown = $null
        try { $null = Get-SwNativeArchitecture } catch { $thrown = $_ }
        $thrown | Should -BeNullOrEmpty
    }

    It 'Returns a non-empty string' {
        $value = Get-SwNativeArchitecture
        $value | Should -BeOfType [string]
        $value | Should -Not -BeNullOrEmpty
    }

    It '[W] Takes the machine architecture from the system-wide registry value, not from the process' {
        $registry = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name 'PROCESSOR_ARCHITECTURE').PROCESSOR_ARCHITECTURE
        $env:PROCESSOR_ARCHITECTURE = 'PROCESS-VALUE'
        Get-SwNativeArchitecture | Should -BeExactly $registry
    }
}

Describe 'Show-SwHelp (RT-19)' {
    BeforeAll {
        $script:Forms = @('sw', 'sw clean', 'sw uninstall', 'sw features', 'sw check', 'sw optimize', 'sw analyze', 'sw status', 'sw purge', 'sw history', 'sw update', 'sw remove', 'sw --help', 'sw --version')
        $script:Examples = @('sw clean --dry-run', 'sw clean --whitelist', 'sw clean --system', 'sw optimize --dry-run', 'sw uninstall --dry-run', 'sw features --dry-run', 'sw features --restore', 'sw check --report', 'sw purge --dry-run', 'sw purge --paths', 'sw history --json', 'sw analyze D:\')
        $script:Subcommands = 'clean|uninstall|features|check|optimize|analyze|status|purge|history|update|remove'
    }
    BeforeEach {
        Mock Show-SwLogo { Write-Host '##LOGO##' }
        Mock Start-SwUpdateProbe { throw 'no update lookup' }
        Mock Write-SwUpdateHint { throw 'no update hint' }
        Mock Initialize-SwDataFolders { throw 'no data folder' }
        Mock Clear-Host { throw 'no clear' }
        Mock Start-Process { throw 'no process' }
        Mock Invoke-WebRequest { throw 'no network' }
        $script:Result = Invoke-Records { Show-SwHelp }
        $script:Lines = @(Get-ScreenLines $script:Result)
        $script:Texts = @(Get-Texts $script:Lines | ForEach-Object { $_.Trim() })
    }

    It 'Writes only host lines and gives no exit code or object' {
        $script:Result.Thrown | Should -BeNullOrEmpty
        @($script:Result.Output).Count | Should -Be 0
        $script:Lines.Count | Should -BeGreaterThan 20
    }

    It 'Starts with the logo, then the heading COMMANDS' {
        $script:Texts.IndexOf('##LOGO##') | Should -BeGreaterOrEqual 0
        $script:Texts.IndexOf('COMMANDS') | Should -BeGreaterThan $script:Texts.IndexOf('##LOGO##')
        Should -Invoke Show-SwLogo -Times 1 -Exactly
    }

    It 'Has a line with a description for the form <Form>' -ForEach @(
        @('sw', 'sw clean', 'sw uninstall', 'sw features', 'sw check', 'sw optimize', 'sw analyze', 'sw status', 'sw purge', 'sw history', 'sw update', 'sw remove', 'sw --help', 'sw --version') | ForEach-Object { @{ Form = $_ } }
    ) {
        $pattern = '^' + [regex]::Escape($Form) + '(?:\s{2,}|\s+(?!-|(?:' + $script:Subcommands + ')\b))\S'
        @($script:Texts | Where-Object { $_ -match $pattern }).Count | Should -BeGreaterThan 0
    }

    It 'Lists the forms after COMMANDS, then a blank line, then the examples, then OPTIONS with a line for --debug' {
        $commands = $script:Texts.IndexOf('COMMANDS')
        $options = $script:Texts.IndexOf('OPTIONS')
        $commands | Should -BeGreaterOrEqual 0
        $options | Should -BeGreaterThan $commands
        $lastForm = -1
        foreach ($form in $script:Forms) {
            $pattern = '^' + [regex]::Escape($form) + '(?:\s{2,}|\s+(?!-|(?:' + $script:Subcommands + ')\b))\S'
            $at = -1
            for ($i = $commands + 1; $i -lt $options; $i++) { if ($script:Texts[$i] -match $pattern) { $at = $i; break } }
            $at | Should -BeGreaterThan $commands -Because $form
            if ($at -gt $lastForm) { $lastForm = $at }
        }
        $firstExample = -1
        foreach ($example in $script:Examples) {
            $at = -1
            for ($i = $commands + 1; $i -lt $options; $i++) { if ($script:Texts[$i].StartsWith($example)) { $at = $i; break } }
            $at | Should -BeGreaterThan $lastForm -Because $example
            if ($firstExample -eq -1 -or $at -lt $firstExample) { $firstExample = $at }
        }
        # A blank line between the last form and the first example.
        $blank = $false
        for ($i = $lastForm + 1; $i -lt $firstExample; $i++) { if ($script:Texts[$i] -eq '') { $blank = $true } }
        $blank | Should -BeTrue
        $debug = -1
        for ($i = $options + 1; $i -lt $script:Texts.Count; $i++) { if ($script:Texts[$i] -match '^--debug\b') { $debug = $i; break } }
        $debug | Should -BeGreaterThan $options
    }

    It 'Names every one of the eleven commands as sw <name>' -ForEach @(
        @('clean', 'uninstall', 'analyze', 'status', 'optimize', 'purge', 'history', 'features', 'check', 'update', 'remove') | ForEach-Object { @{ Command = $_ } }
    ) {
        ($script:Texts -join "`n") | Should -Match "sw $Command\b"
    }

    It 'Mentions neither inspect nor REA' {
        $text = $script:Texts -join "`n"
        $text | Should -Not -Match '(?i)inspect'
        $text | Should -Not -CMatch '\bREA\b'
    }

    It 'Uses only the colours of the colour table' {
        $allowed = @($script:Colors.Values)
        foreach ($line in ($script:Lines | Where-Object { $_.Raw -match '\x1b' })) {
            foreach ($match in [regex]::Matches($line.Raw, '\x1b\[[0-9;]*m')) { $allowed | Should -Contain $match.Value }
        }
    }

    It 'Shows the real logo with the address of the project' {
        Mock Show-SwLogo { & $script:Real['Show-SwLogo'] }
        $result = Invoke-Records { Show-SwHelp }
        $result.Thrown | Should -BeNullOrEmpty
        (Get-Texts (Get-ScreenLines $result)) -join "`n" | Should -Match ([regex]::Escape('https://github.com/brummilab/sweepr'))
    }

    It 'Starts no update lookup, shows no hint, makes no data folder, does not clear the screen and uses no network' {
        Should -Invoke Start-SwUpdateProbe -Times 0 -Exactly
        Should -Invoke Write-SwUpdateHint -Times 0 -Exactly
        Should -Invoke Initialize-SwDataFolders -Times 0 -Exactly
        Should -Invoke Clear-Host -Times 0 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }
}

Describe 'Show-SwMenu (RT-20)' {
    BeforeAll {
        function script:New-Key($Token) {
            switch ($Token) {
                'Up' { return [pscustomobject]@{ VirtualKeyCode = 38; Character = [char]0 } }
                'Down' { return [pscustomobject]@{ VirtualKeyCode = 40; Character = [char]0 } }
                'Enter' { return [pscustomobject]@{ VirtualKeyCode = 13; Character = [char]13 } }
                'Esc' { return [pscustomobject]@{ VirtualKeyCode = 27; Character = [char]27 } }
                'Left' { return [pscustomobject]@{ VirtualKeyCode = 37; Character = [char]0 } }
                'Tab' { return [pscustomobject]@{ VirtualKeyCode = 9; Character = [char]9 } }
                default { return [pscustomobject]@{ VirtualKeyCode = [int][char]([string]$Token).ToUpperInvariant()[0]; Character = [char]([string]$Token)[0] } }
            }
        }
        # Runs the menu with the given keys; returns the choice, the host lines and the key count.
        function script:Invoke-Menu([string[]]$Keys, $Context = 'ctx') {
            $script:Keys = @($Keys | ForEach-Object { New-Key $_ })
            $script:KeyIndex = 0
            $script:HintContexts = New-Object System.Collections.Generic.List[object]
            $script:MenuContext = $Context
            $result = Invoke-Records { Show-SwMenu -UpdateContext $script:MenuContext }
            $result | Add-Member -NotePropertyName Lines -NotePropertyValue @(Get-ScreenLines $result) -Force
            $result | Add-Member -NotePropertyName Choice -NotePropertyValue $(if (@($result.Output | Where-Object { $null -ne $_ }).Count -gt 0) { @($result.Output | Where-Object { $null -ne $_ })[0] } else { $null }) -Force
            return $result
        }
        function script:Split-Draws($Result) {
            $draws = New-Object System.Collections.Generic.List[object]
            $current = New-Object System.Collections.Generic.List[object]
            foreach ($line in $Result.Lines) {
                if ($line.Text.Trim() -eq '##KEY##') { $draws.Add($current.ToArray()); $current = New-Object System.Collections.Generic.List[object]; continue }
                $current.Add($line)
            }
            if ($current.Count -gt 0) { $draws.Add($current.ToArray()) }
            return $draws.ToArray()
        }
    }
    BeforeEach {
        Mock Show-SwLogo { Write-Host '##LOGO##' }
        Mock Write-SwUpdateHint { Write-Host '##HINT##'; $script:HintContexts.Add($Context) }
        Mock Clear-Host { throw 'the menu does not clear the screen' }
        Mock Read-SwMenuKey {
            Write-Host '##KEY##'
            $i = $script:KeyIndex
            $script:KeyIndex++
            if ($i -ge $script:Keys.Count) { throw 'the test has no more keys' }
            return $script:Keys[$i]
        }
    }

    It 'Returns <Expected> for the keys <Keys>' -ForEach @(
        @{ Keys = @('Down', 'Down', 'Enter'); Expected = 'optimize' }
        @{ Keys = @('Enter'); Expected = 'clean' }
        @{ Keys = @('Down', 'Enter'); Expected = 'uninstall' }
        @{ Keys = @('Down', 'Down', 'Down', 'Enter'); Expected = 'analyze' }
        @{ Keys = @('Up', 'Up', 'Enter'); Expected = 'clean' }
        @{ Keys = @('Up', 'Down', 'Enter'); Expected = 'uninstall' }
        @{ Keys = @('Down', 'Down', 'Down', 'Down', 'Down', 'Down', 'Down', 'Down', 'Down', 'Down', 'Enter'); Expected = 'status' }
        @{ Keys = @('Down', 'Down', 'Down', 'Down', 'Down', 'Up', 'Enter'); Expected = 'analyze' }
        @{ Keys = @('j', 'j', 'Enter'); Expected = 'optimize' }
        @{ Keys = @('J', 'J', 'Enter'); Expected = 'optimize' }
        @{ Keys = @('j', 'k', 'Enter'); Expected = 'clean' }
        @{ Keys = @('K', 'Enter'); Expected = 'clean' }
        @{ Keys = @('1'); Expected = 'clean' }
        @{ Keys = @('2'); Expected = 'uninstall' }
        @{ Keys = @('3'); Expected = 'optimize' }
        @{ Keys = @('4'); Expected = 'analyze' }
        @{ Keys = @('5'); Expected = 'status' }
        @{ Keys = @('Down', '1'); Expected = 'clean' }
        @{ Keys = @('m'); Expected = 'help' }
        @{ Keys = @('M'); Expected = 'help' }
        @{ Keys = @('v'); Expected = 'version' }
        @{ Keys = @('V'); Expected = 'version' }
        @{ Keys = @('x', 'Left', 'Tab', '6', '0', '7', ' ', 'Enter'); Expected = 'clean' }
        @{ Keys = @('Down', 'x', 'Enter'); Expected = 'uninstall' }
    ) {
        $result = Invoke-Menu $Keys
        $result.Thrown | Should -BeNullOrEmpty
        $result.Choice | Should -BeExactly $Expected
        @($result.Output | Where-Object { $null -ne $_ }).Count | Should -Be 1
    }

    It 'Returns $null for the keys <Keys>' -ForEach @(
        @{ Keys = @('q') }
        @{ Keys = @('Q') }
        @{ Keys = @('Esc') }
        @{ Keys = @('Down', 'Down', 'q') }
        @{ Keys = @('x', 'Esc') }
    ) {
        $result = Invoke-Menu $Keys
        $result.Thrown | Should -BeNullOrEmpty
        @($result.Output | Where-Object { $null -ne $_ }).Count | Should -Be 0
    }

    It 'Reads no more keys after the choice' {
        $result = Invoke-Menu @('Enter', 'Down', 'Down')
        $result.Choice | Should -BeExactly 'clean'
        $script:KeyIndex | Should -Be 1
    }

    It 'Draws the menu completely before it reads the first key: blank line, logo, five entries, blank line, controls, hint' {
        $result = Invoke-Menu @('q')
        $draws = @(Split-Draws $result)
        $draws.Count | Should -BeGreaterOrEqual 1
        $first = @($draws[0] | ForEach-Object { $_.Text })
        $first[0].Trim() | Should -BeExactly ''
        $first[1].Trim() | Should -BeExactly '##LOGO##'
        $entryIndex = @()
        foreach ($name in 'clean', 'uninstall', 'optimize', 'analyze', 'status') {
            $at = -1
            for ($i = 2; $i -lt $first.Count; $i++) { if ($first[$i] -match "\b$name\b") { $at = $i; break } }
            $at | Should -BeGreaterThan 1 -Because $name
            $entryIndex += $at
        }
        for ($i = 1; $i -lt 5; $i++) { $entryIndex[$i] | Should -BeGreaterThan $entryIndex[$i - 1] }
        for ($i = 0; $i -lt 5; $i++) { $first[$entryIndex[$i]] | Should -Match "\b$($i + 1)\b" }
        $first[$entryIndex[0]] | Should -Match 'Free up disk space'
        $control = -1
        for ($i = $entryIndex[4] + 1; $i -lt $first.Count; $i++) { if ($first[$i] -match 'Q Quit') { $control = $i; break } }
        $control | Should -BeGreaterThan $entryIndex[4]
        $first[$entryIndex[4] + 1].Trim() | Should -BeExactly ''
        foreach ($text in 'Enter', 'M More', 'V Version', 'Q Quit') { $first[$control] | Should -Match ([regex]::Escape($text)) }
        ($first[$control].Contains($script:Icons['NavUp']) -or $first[$control] -match 'Up') | Should -BeTrue
        $hint = -1
        for ($i = $control + 1; $i -lt $first.Count; $i++) { if ($first[$i].Trim() -eq '##HINT##') { $hint = $i; break } }
        $hint | Should -BeGreaterThan $control
    }

    It 'Draws again after every key and shows the hint with every drawing' {
        $result = Invoke-Menu @('Down', 'x', 'Down', 'q')
        $draws = @(Split-Draws $result)
        $draws.Count | Should -BeGreaterOrEqual 4
        @($result.Lines | Where-Object { $_.Text -match 'Q Quit' }).Count | Should -BeGreaterOrEqual 4
        @($result.Lines | Where-Object { $_.Text.Trim() -eq '##HINT##' }).Count | Should -Be @($result.Lines | Where-Object { $_.Text -match 'Q Quit' }).Count
    }

    It 'Gives the update context to the hint' {
        $null = Invoke-Menu @('q') -Context 'the-context'
        $script:HintContexts.Count | Should -BeGreaterThan 0
        foreach ($context in $script:HintContexts) { $context | Should -BeExactly 'the-context' }
    }

    It 'Marks the chosen entry with the arrow symbol and the colour cyan, and moves the mark with the keys' {
        $result = Invoke-Menu @('Down', 'Down', 'q')
        $draws = @(Split-Draws $result)
        $arrow = [string]$script:Icons['Arrow']
        $arrow | Should -Not -BeNullOrEmpty
        $expected = @('clean', 'uninstall', 'optimize')
        for ($d = 0; $d -lt 3; $d++) {
            $marked = @($draws[$d] | Where-Object { $_.Text.Contains($arrow) })
            $marked.Count | Should -Be 1 -Because "drawing $d"
            $marked[0].Text | Should -Match "\b$($expected[$d])\b"
            ($marked[0].Colors -contains 'Cyan' -or $marked[0].Raw.Contains([string]$script:Colors['Cyan'])) | Should -BeTrue -Because "drawing $d"
        }
    }

    It 'Marks only one entry and leaves the others without the arrow' {
        $result = Invoke-Menu @('q')
        $arrow = [string]$script:Icons['Arrow']
        @($result.Lines | Where-Object { $_.Text.Contains($arrow) }).Count | Should -Be 1
    }

    It 'Does not clear the screen' {
        $null = Invoke-Menu @('Down', 'q')
        Should -Invoke Clear-Host -Times 0 -Exactly
    }

    It 'Lets an error of the key source through instead of waiting' {
        $result = Invoke-Menu @()
        $result.Thrown | Should -Not -BeNullOrEmpty
        $script:KeyIndex | Should -Be 1
    }
}

Describe 'Get-SwDebugHeader (RT-13)' {
    BeforeEach {
        Mock Get-Date {
            $moment = [datetime]'2026-10-15 10:00:00'
            if ($PesterBoundParameters.ContainsKey('Format')) { return $moment.ToString([string]$PesterBoundParameters['Format'], [System.Globalization.CultureInfo]::InvariantCulture) }
            return $moment
        }
        Mock Get-SwRuntimeInfo { @{ Version = '1.2.3'; PowerShell = '7.4.6'; Windows = '10.0.22631' } }
        Mock Get-SwWindowsVersion { @{ Name = 'Windows Example'; Version = '10.0.22631'; Build = '22631'; Arch = 'x64' } }
        Mock Get-SwNativeArchitecture { 'ARM64' }
        Mock Get-SwInstallMethod { 'Portable' }
        Mock Get-SwInstallDescription { 'Portable' }
    }

    It 'Starts with a title line that has the time, then the command line' {
        $header = @(Get-SwDebugHeader -CommandLine 'clean --debug')
        $header.Count | Should -BeGreaterThan 2
        $header[0] | Should -Match '2026-10-15 10:00:00'
        $header[1] | Should -BeExactly 'Command: sw clean --debug'
    }

    It 'Returns strings' {
        $header = Get-SwDebugHeader -CommandLine 'clean --debug'
        foreach ($line in @($header)) { $line | Should -BeOfType [string] }
    }

    It 'Names the Sweepr version, Windows with name and version, the architecture, PowerShell with version and edition, and the install method' {
        $text = (@(Get-SwDebugHeader -CommandLine 'clean --debug') | Select-Object -Skip 2) -join "`n"
        $text | Should -Match '1\.2\.3'
        $text | Should -Match 'Windows Example'
        $text | Should -Match '10\.0\.22631'
        $text | Should -Match 'ARM64'
        $text | Should -Match '7\.4\.6'
        $text | Should -Match ([regex]::Escape([string]$PSVersionTable['PSEdition']))
        $text | Should -Match 'Portable'
    }

    It 'Keeps the first two lines and adds one replacement line when a query fails' {
        Mock Get-SwWindowsVersion { throw 'the query failed' }
        $thrown = $null
        $header = @()
        try { $header = @(Get-SwDebugHeader -CommandLine 'clean --debug') } catch { $thrown = $_ }
        $thrown | Should -BeNullOrEmpty
        $header.Count | Should -Be 3
        $header[0] | Should -Match '2026-10-15 10:00:00'
        $header[1] | Should -BeExactly 'Command: sw clean --debug'
        $header[2].Trim() | Should -Not -BeNullOrEmpty
    }

    It 'Does the same for a failing <Query>' -ForEach @(
        @{ Query = 'Get-SwRuntimeInfo' }
        @{ Query = 'Get-SwNativeArchitecture' }
    ) {
        Mock -CommandName $Query -MockWith { throw 'the query failed' }
        $header = @(Get-SwDebugHeader -CommandLine 'status')
        $header.Count | Should -Be 3
        $header[1] | Should -BeExactly 'Command: sw status'
    }

    It 'Writes the time with ASCII digits and the Gregorian year in a culture with another calendar' {
        $culture = $null
        try { $culture = [System.Globalization.CultureInfo]::new('ar-SA') } catch { $culture = $null }
        if ($null -eq $culture -or $culture.Name -ne 'ar-SA') { Set-ItResult -Skipped -Because 'the culture ar-SA is not available on this host'; return }
        Mock Get-Date { [datetime]::new(2026, 10, 15, 10, 0, 0) }
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $culture
        try { $header = @(Get-SwDebugHeader -CommandLine 'clean --debug') }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $script:SavedCulture }
        $header[0] | Should -Match '2026-10-15 10:00:00'
    }

    It 'Holds no user, machine or folder name apart from the words of the command line' {
        Mock Get-SwRuntimeInfo { & $script:Real['Get-SwRuntimeInfo'] }
        Mock Get-SwWindowsVersion { & $script:Real['Get-SwWindowsVersion'] }
        Mock Get-SwNativeArchitecture { & $script:Real['Get-SwNativeArchitecture'] }
        Mock Get-SwInstallMethod { & $script:Real['Get-SwInstallMethod'] @PesterBoundParameters }
        Mock Get-SwInstallDescription { & $script:Real['Get-SwInstallDescription'] @PesterBoundParameters }
        $header = @(Get-SwDebugHeader -CommandLine 'clean --debug')
        $rest = ($header[2..($header.Count - 1)]) -join "`n"
        foreach ($forbidden in @([System.Environment]::UserName, [System.Environment]::MachineName, $script:HomeDir, $script:SWEEPR_ROOT)) {
            if ($forbidden.Length -ge 4) { $rest.IndexOf($forbidden, [System.StringComparison]::OrdinalIgnoreCase) | Should -BeLessThan 0 }
        }
    }
}

Describe 'Install method and source commit (RT-23, S10)' {
    BeforeAll {
        $script:Tools = Join-Path $TestDrive 'screens-fake-git'
        [void][System.IO.Directory]::CreateDirectory($script:Tools)
        $script:GitMarker = Join-Path $TestDrive 'screens-git-ran.txt'
        if ($script:IsWin) {
            [System.IO.File]::WriteAllText((Join-Path $script:Tools 'git.cmd'), "@echo ran> `"$($script:GitMarker)`"`r`n@exit /b 1`r`n")
        }
        else {
            [System.IO.File]::WriteAllText((Join-Path $script:Tools 'git'), "#!/bin/sh`necho ran > '$($script:GitMarker)'`nexit 1`n", $script:Utf8)
            & chmod 755 (Join-Path $script:Tools 'git')
        }
        $script:Hex = '0123456789abcdef0123456789abcdef01234567'
        $script:Other = 'fedcba9876543210fedcba9876543210fedcba98'

        function script:New-Root([string]$Name, [switch]$Portable, [string]$GitKind = '') {
            $root = [System.IO.Path]::Combine($TestDrive, ('root-' + [guid]::NewGuid().ToString('N')), $Name)
            [void][System.IO.Directory]::CreateDirectory($root)
            if ($Portable) { [System.IO.File]::WriteAllText([System.IO.Path]::Combine($root, 'sweepr.portable'), '') }
            if ($GitKind -eq 'dir') { [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::Combine($root, '.git')) }
            if ($GitKind -eq 'file') { [System.IO.File]::WriteAllText([System.IO.Path]::Combine($root, '.git'), 'gitdir: ../elsewhere/.git') }
            return $root
        }
        function script:Set-GitFile([string]$Root, [string]$Relative, [string]$Text) {
            $path = [System.IO.Path]::Combine([string[]](@($Root, '.git') + @($Relative.Split('/'))))
            [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($path))
            [System.IO.File]::WriteAllText($path, $Text, $script:Utf8)
        }
    }
    BeforeEach {
        if ([System.IO.File]::Exists($script:GitMarker)) { [System.IO.File]::Delete($script:GitMarker) }
        $env:PATH = $script:Tools
        Mock Start-Process { throw 'no process may be started' }
    }
    AfterEach {
        $env:PATH = $script:SavedEnv['PATH']
    }

    Context 'Get-SwInstallMethod' {
        It 'Returns winget for a folder below Microsoft\WinGet\Packages\brummilab.Sweepr_*: <Path>' -ForEach @(
            @{ Path = 'C:\Users\Example\AppData\Local\Microsoft\WinGet\Packages\brummilab.Sweepr_Fixture' }
            @{ Path = 'C:\Users\Example\AppData\Local\Microsoft\WinGet\Packages\brummilab.Sweepr_Fixture\' }
            @{ Path = 'C:/Users/Example/AppData/Local/Microsoft/WinGet/Packages/brummilab.Sweepr_Fixture' }
            @{ Path = 'c:\users\example\appdata\local\microsoft\winget\packages\BRUMMILAB.SWEEPR_fixture' }
            @{ Path = 'C:\Users\Example\AppData\Local\Microsoft\WinGet\Packages\brummilab.Sweepr_Fixture\sub' }
        ) {
            Get-SwInstallMethod -RootDir $Path | Should -BeExactly 'winget'
        }

        It 'Returns Scoop for a folder below scoop\apps\sweepr: <Path>' -ForEach @(
            @{ Path = 'C:\Users\Example\scoop\apps\sweepr\current' }
            @{ Path = 'C:\Users\Example\scoop\apps\sweepr' }
            @{ Path = 'C:\Users\Example\scoop\apps\sweepr\' }
            @{ Path = 'C:/Users/Example/scoop/apps/sweepr/current' }
            @{ Path = 'C:\USERS\EXAMPLE\SCOOP\APPS\SWEEPR\1.0.0' }
        ) {
            Get-SwInstallMethod -RootDir $Path | Should -BeExactly 'Scoop'
        }

        It 'Does not take a similar path for winget or Scoop: <Path>' -ForEach @(
            @{ Path = 'C:\Users\Example\AppData\Local\Microsoft\WinGet\Packages\brummilab.Sweepr' }
            @{ Path = 'C:\Users\Example\AppData\Local\Microsoft\WinGet\Packages\other.Sweepr_Fixture' }
            @{ Path = 'C:\Users\Example\scoop\apps\sweepr2\current' }
            @{ Path = 'C:\Users\Example\scoop\apps\notsweepr\current' }
            @{ Path = 'C:\Users\Example\scoop\sweepr\current' }
        ) {
            Get-SwInstallMethod -RootDir $Path | Should -BeExactly 'Copy'
        }

        It 'Returns Portable for a folder with the marker file, before winget, Scoop and Source' {
            $deep = New-Root -Name 'Microsoft\WinGet\Packages\brummilab.Sweepr_Fixture' -Portable -GitKind 'dir'
            Get-SwInstallMethod -RootDir $deep | Should -BeExactly 'Portable'
            $scoop = New-Root -Name 'scoop\apps\sweepr\current' -Portable
            Get-SwInstallMethod -RootDir $scoop | Should -BeExactly 'Portable'
        }

        It 'Returns winget and Scoop before Source for a folder that also has a .git folder' {
            $winget = New-Root -Name 'Microsoft\WinGet\Packages\brummilab.Sweepr_Fixture' -GitKind 'dir'
            Get-SwInstallMethod -RootDir $winget | Should -BeExactly 'winget'
            $scoop = New-Root -Name 'scoop\apps\sweepr\current' -GitKind 'dir'
            Get-SwInstallMethod -RootDir $scoop | Should -BeExactly 'Scoop'
        }

        It 'Returns Source for a folder with a .git folder or a .git file' -ForEach @(
            @{ Kind = 'dir' }
            @{ Kind = 'file' }
        ) {
            Get-SwInstallMethod -RootDir (New-Root -Name 'sweepr' -GitKind $Kind) | Should -BeExactly 'Source'
        }

        It 'Returns Copy for a folder without a marker and without .git' {
            Get-SwInstallMethod -RootDir (New-Root -Name 'sweepr') | Should -BeExactly 'Copy'
        }

        It 'Does not count a folder named sweepr.portable as the marker' {
            $root = New-Root -Name 'sweepr'
            [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::Combine($root, 'sweepr.portable'))
            Get-SwInstallMethod -RootDir $root | Should -BeExactly 'Copy'
        }

        It 'Looks at a folder with brackets, quotes and blanks in its name literally' {
            $parent = Join-Path $TestDrive ('literal-' + [guid]::NewGuid().ToString('N'))
            # A sibling the bracket pattern would match, with a .git folder of its own.
            [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::Combine($parent, 'Tools x64 USB', 'sweepr', '.git'))
            $root = [System.IO.Path]::Combine($parent, "Tools [x64 USB] it's", 'sweepr')
            [void][System.IO.Directory]::CreateDirectory($root)
            Get-SwInstallMethod -RootDir $root | Should -BeExactly 'Copy'
            [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::Combine($root, '.git'))
            Get-SwInstallMethod -RootDir $root | Should -BeExactly 'Source'
        }

        It 'Returns a string and nothing else' {
            $result = @(Get-SwInstallMethod -RootDir (New-Root -Name 'sweepr'))
            $result.Count | Should -Be 1
            $result[0] | Should -BeOfType [string]
        }
    }

    Context 'Get-SwSourceCommit' {
        It 'Takes the first seven characters of a HEAD with 40 hexadecimal characters' {
            $root = New-Root -Name 'sweepr' -GitKind 'dir'
            Set-GitFile $root 'HEAD' "$($script:Hex)`n"
            Get-SwSourceCommit -RootDir $root | Should -BeExactly '0123456'
        }

        It 'Reads a HEAD with a CRLF line end' {
            $root = New-Root -Name 'sweepr' -GitKind 'dir'
            Set-GitFile $root 'HEAD' "$($script:Hex)`r`n"
            Get-SwSourceCommit -RootDir $root | Should -BeExactly '0123456'
        }

        It 'Follows a branch to its loose file' {
            $root = New-Root -Name 'sweepr' -GitKind 'dir'
            Set-GitFile $root 'HEAD' "ref: refs/heads/windows`n"
            Set-GitFile $root 'refs/heads/windows' "$($script:Hex)`n"
            Get-SwSourceCommit -RootDir $root | Should -BeExactly '0123456'
        }

        It 'Follows a branch to the packed refs when there is no loose file' {
            $root = New-Root -Name 'sweepr' -GitKind 'dir'
            Set-GitFile $root 'HEAD' "ref: refs/heads/windows`n"
            Set-GitFile $root 'packed-refs' "# pack-refs with: peeled fully-peeled sorted`n$($script:Other) refs/heads/main`n$($script:Hex) refs/heads/windows`n^$($script:Other)`n"
            Get-SwSourceCommit -RootDir $root | Should -BeExactly '0123456'
        }

        It 'Prefers the loose file over the packed refs' {
            $root = New-Root -Name 'sweepr' -GitKind 'dir'
            Set-GitFile $root 'HEAD' "ref: refs/heads/windows`n"
            Set-GitFile $root 'refs/heads/windows' "$($script:Hex)`n"
            Set-GitFile $root 'packed-refs' "$($script:Other) refs/heads/windows`n"
            Get-SwSourceCommit -RootDir $root | Should -BeExactly '0123456'
        }

        It 'Returns $null for <Case>' -ForEach @(
            @{ Case = 'a branch with no file and no packed entry'; Head = "ref: refs/heads/windows`n"; Loose = $null; Packed = $null }
            @{ Case = 'a ref with a parent step'; Head = "ref: refs/../../etc/x`n"; Loose = $null; Packed = $null }
            @{ Case = 'a ref with a parent step in the middle'; Head = "ref: refs/heads/../../HEAD`n"; Loose = $null; Packed = $null }
            @{ Case = 'a HEAD of 39 characters'; Head = "0123456789abcdef0123456789abcdef0123456`n"; Loose = $null; Packed = $null }
            @{ Case = 'a HEAD of 41 characters'; Head = "0123456789abcdef0123456789abcdef012345678`n"; Loose = $null; Packed = $null }
            @{ Case = 'a HEAD that is no hash'; Head = "not a head`n"; Loose = $null; Packed = $null }
            @{ Case = 'an empty HEAD'; Head = ''; Loose = $null; Packed = $null }
            @{ Case = 'a loose file that holds no hash'; Head = "ref: refs/heads/windows`n"; Loose = "garbage`n"; Packed = $null }
        ) {
            $root = New-Root -Name 'sweepr' -GitKind 'dir'
            Set-GitFile $root 'HEAD' $Head
            if ($null -ne $Loose) { Set-GitFile $root 'refs/heads/windows' $Loose }
            if ($null -ne $Packed) { Set-GitFile $root 'packed-refs' $Packed }
            $null -eq (Get-SwSourceCommit -RootDir $root) | Should -BeTrue
        }

        It 'Returns $null and does not throw for <Case>' -ForEach @(
            @{ Case = 'a .git file that points to a work tree'; Kind = 'file' }
            @{ Case = 'a folder without .git'; Kind = '' }
            @{ Case = 'a .git folder without HEAD'; Kind = 'dir' }
        ) {
            $root = New-Root -Name 'sweepr' -GitKind $Kind
            $thrown = $null
            $result = 'unset'
            try { $result = Get-SwSourceCommit -RootDir $root } catch { $thrown = $_ }
            $thrown | Should -BeNullOrEmpty
            $null -eq $result | Should -BeTrue
        }

        It 'Returns $null and does not throw when HEAD is a folder or the root does not exist' {
            $root = New-Root -Name 'sweepr' -GitKind 'dir'
            [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::Combine($root, '.git', 'HEAD'))
            $null -eq (Get-SwSourceCommit -RootDir $root) | Should -BeTrue
            $null -eq (Get-SwSourceCommit -RootDir (Join-Path $TestDrive 'does-not-exist')) | Should -BeTrue
        }

        It 'Reads a folder with brackets, quotes and blanks literally' {
            $root = New-Root -Name "Tools [x64] it's" -GitKind 'dir'
            Set-GitFile $root 'HEAD' "$($script:Hex)`n"
            Get-SwSourceCommit -RootDir $root | Should -BeExactly '0123456'
        }
    }

    Context 'Get-SwInstallDescription' {
        It 'Adds the seven characters of the commit to Source' {
            $root = New-Root -Name 'sweepr' -GitKind 'dir'
            Set-GitFile $root 'HEAD' "$($script:Hex)`n"
            Get-SwInstallDescription -RootDir $root | Should -BeExactly 'Source (0123456)'
        }

        It 'Resolves a branch for the description, loose or packed' {
            $root = New-Root -Name 'sweepr' -GitKind 'dir'
            Set-GitFile $root 'HEAD' "ref: refs/heads/windows`n"
            Set-GitFile $root 'packed-refs' "$($script:Hex) refs/heads/windows`n"
            Get-SwInstallDescription -RootDir $root | Should -BeExactly 'Source (0123456)'
        }

        It 'Gives only Source when the commit cannot be read, also for a ref with a parent step' -ForEach @(
            @{ Head = "ref: refs/heads/windows`n" }
            @{ Head = "ref: refs/../../etc/x`n" }
            @{ Head = "garbage`n" }
        ) {
            $root = New-Root -Name 'sweepr' -GitKind 'dir'
            Set-GitFile $root 'HEAD' $Head
            Get-SwInstallDescription -RootDir $root | Should -BeExactly 'Source'
        }

        It 'Gives only Source for a .git file' {
            Get-SwInstallDescription -RootDir (New-Root -Name 'sweepr' -GitKind 'file') | Should -BeExactly 'Source'
        }

        It 'Gives the method for every other install: <Method>' -ForEach @(
            @{ Method = 'Portable' }
            @{ Method = 'Copy' }
        ) {
            $root = New-Root -Name 'sweepr' -Portable:($Method -eq 'Portable')
            Get-SwInstallDescription -RootDir $root | Should -BeExactly $Method
        }

        It 'Gives winget and Scoop without a commit' {
            Get-SwInstallDescription -RootDir 'C:\Users\Example\AppData\Local\Microsoft\WinGet\Packages\brummilab.Sweepr_Fixture' | Should -BeExactly 'winget'
            Get-SwInstallDescription -RootDir 'C:\Users\Example\scoop\apps\sweepr\current' | Should -BeExactly 'Scoop'
        }
    }

    Context 'no process (S10)' {
        It 'Never starts git, the method and the commit come from the files' {
            $root = New-Root -Name 'sweepr' -GitKind 'dir'
            Set-GitFile $root 'HEAD' "$($script:Hex)`n"
            $null = Get-SwInstallMethod -RootDir $root
            $null = Get-SwSourceCommit -RootDir $root
            $null = Get-SwInstallDescription -RootDir $root
            [System.IO.File]::Exists($script:GitMarker) | Should -BeFalse
            Should -Invoke Start-Process -Times 0 -Exactly
        }
    }
}
