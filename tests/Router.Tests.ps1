# Sweepr Windows - command router tests
# sweepr.ps1 turns --flags into parameters of bin\<command>.ps1. A flag the
# command does not declare must be refused, never passed on: a script without
# [CmdletBinding()] ignores unknown parameters, and `sw remove --help` used to
# uninstall Sweepr.

BeforeAll {
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:WindowsDir "sweepr.ps1"), [ref]$null, [ref]$null)
    foreach ($name in @("Resolve-CommandParameterName", "Invoke-SweeprCommand")) {
        $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        Set-Item -Path "function:script:$name" -Value (Get-Item "function:$name").ScriptBlock
    }
    function Write-SweeprError { param($Message) }
    function Get-SweeprDebugHeader { param($CommandLine) "header: $CommandLine" }
    function Start-SweeprDebugSession { param($Header) $script:DebugSessionCalls += "start:$($Header -join '|')" }
    function Complete-SweeprDebugSession { $script:DebugSessionCalls += "complete" }

    $script:SWEEPR_BIN = Join-Path $TestDrive "bin"
    New-Item -ItemType Directory -Path $script:SWEEPR_BIN -Force | Out-Null
    # Shaped like bin\remove.ps1 before it gained [CmdletBinding()].
    Set-Content -Path (Join-Path $script:SWEEPR_BIN "fake.ps1") -Value @'
param(
    [Alias('h')]
    [switch]$ShowHelp,
    [Alias('dry-run')]
    [switch]$DryRun,
    [Alias('d')]
    [switch]$DebugMode
)
if ($ShowHelp) { "HELP" } elseif ($DryRun) { "DRYRUN" } elseif ($DebugMode) { "DEBUG" } else { "ACTED" }
'@
}

Describe "sweepr.ps1 command router" {
    BeforeEach {
        $script:SweeprExitCode = 0
        $script:DebugSessionCalls = @()
    }

    It "Maps <Flag> to the command's own parameter" -ForEach @(
        @{ Flag = "--help"; Expected = "HELP" },
        @{ Flag = "-h"; Expected = "HELP" },
        @{ Flag = "--dry-run"; Expected = "DRYRUN" },
        @{ Flag = "--debug"; Expected = "DEBUG" }
    ) {
        Invoke-SweeprCommand -CommandName "fake" -Arguments @($Flag) | Should -Be $Expected
    }

    It "Opens one debug session around a --debug command and closes it" {
        Invoke-SweeprCommand -CommandName "fake" -Arguments @("--debug") | Should -Be "DEBUG"
        $script:DebugSessionCalls | Should -Be @("start:header: fake --debug", "complete")
    }

    It "Leaves the debug session alone without --debug" {
        Invoke-SweeprCommand -CommandName "fake" -Arguments @("--dry-run") | Should -Be "DRYRUN"
        Invoke-SweeprCommand -CommandName "fake" -Arguments @() | Should -Be "ACTED"
        $script:DebugSessionCalls | Should -BeNullOrEmpty
    }

    It "Refuses an unknown option without running the command" {
        $output = @(Invoke-SweeprCommand -CommandName "fake" -Arguments @("--bogus"))
        $output | Should -Not -Contain "ACTED"
        $script:SweeprExitCode | Should -Be 2
    }

    It "Preserves a literal trailing apostrophe in positional and named paths" {
        Set-Content -LiteralPath (Join-Path $script:SWEEPR_BIN "path.ps1") -Value 'param([string]$Path) $Path'
        $literal = "C:\fixture\reports'"
        Invoke-SweeprCommand -CommandName "path" -Arguments @($literal) | Should -BeExactly $literal
        Invoke-SweeprCommand -CommandName "path" -Arguments @("--path=$literal") | Should -BeExactly $literal
    }

    It "Gives a value flag the next word as <Case>" -ForEach @(
        @{ Case = "two words"; Arguments = @("--watch", "--interval", "1s"); Expected = "watch=True interval=1s json=False" },
        @{ Case = "one word"; Arguments = @("--watch", "--interval=1s"); Expected = "watch=True interval=1s json=False" },
        @{ Case = "a value before a switch"; Arguments = @("--interval", "2s", "--json"); Expected = "watch=False interval=2s json=True" },
        @{ Case = "switches alone"; Arguments = @("--watch", "--json"); Expected = "watch=True interval= json=True" }
    ) {
        # Shaped like bin\status.ps1: switches beside one [string] option.
        Set-Content -LiteralPath (Join-Path $script:SWEEPR_BIN "watch.ps1") -Value @'
[CmdletBinding()]
param([switch]$Json, [switch]$Watch, [string]$Interval)
"watch=$Watch interval=$Interval json=$Json"
'@
        Invoke-SweeprCommand -CommandName "watch" -Arguments $Arguments | Should -BeExactly $Expected
        $script:SweeprExitCode | Should -Be 0
    }

    It "Refuses an unknown command with a failure exit code" {
        Invoke-SweeprCommand -CommandName "missing" -Arguments @()
        $script:SweeprExitCode | Should -Be 2
    }

    It "Preserves native TUI exit codes and resets stale results for help" {
        Set-Content -LiteralPath (Join-Path $script:SWEEPR_BIN "status.ps1") -Value 'param([switch]$ShowHelp) if ($ShowHelp) { return }; & $env:ComSpec /d /c exit 7; exit $LASTEXITCODE'
        Invoke-SweeprCommand -CommandName "status" -Arguments @()
        $script:SweeprExitCode | Should -Be 7
        Invoke-SweeprCommand -CommandName "status" -Arguments @("--help")
        $script:SweeprExitCode | Should -Be 0
    }

    It "Maps <Flag> to <Expected> on the real <Name> command" -ForEach @(
        @{ Name = "uninstall"; Flag = "list"; Expected = "List" },
        @{ Name = "analyze"; Flag = "json"; Expected = "Json" }
    ) {
        $declared = (Get-Command -Name (Join-Path $script:WindowsDir "bin\$Name.ps1") -CommandType ExternalScript).Parameters
        Resolve-CommandParameterName -Parameters $declared -Flag $Flag | Should -Be $Expected
    }

    It "Shows help for every real command" -ForEach @(
        "clean", "uninstall", "optimize", "analyze", "status", "purge", "update", "remove"
    ) {
        $declared = (Get-Command -Name (Join-Path $script:WindowsDir "bin\$_.ps1") -CommandType ExternalScript).Parameters
        Resolve-CommandParameterName -Parameters $declared -Flag "help" | Should -Be "ShowHelp"
    }
}

Describe "sw --help and --version" {
    BeforeAll {
        $script:Sweepr = Join-Path $script:WindowsDir "sweepr.ps1"
    }

    It "Shows the logo with the website and the command layout" {
        $output = (& powershell -NoProfile -ExecutionPolicy Bypass -Command "& '$($script:Sweepr)' '--help'" 2>&1 | Out-String)
        $output | Should -Match "https://github\.com/brummilab/sweepr"
        $output | Should -Match "COMMANDS"
        $output | Should -Match "sw uninstall --dry-run"
    }

    It "Returns failure for an unknown command from the installed File entrypoint" {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $script:Sweepr not-a-command 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 2
    }

    It "Reports the version, platform and install method" {
        $output = (& powershell -NoProfile -ExecutionPolicy Bypass -Command "& '$($script:Sweepr)' '--version'" 2>&1 | Out-String)
        $output | Should -Match "Sweepr version \d+\.\d+\.\d+"
        $output | Should -Match "Architecture: "
        $output | Should -Match "Install: (Source|Portable|winget|Scoop)"
    }
}

Describe "sw remove" {
    BeforeAll {
        $script:Fake = Join-Path $TestDrive "fake-install"
        New-Item -ItemType Directory -Path (Join-Path $script:Fake "bin") -Force | Out-Null
        Copy-Item (Join-Path $script:WindowsDir "bin\remove.ps1") (Join-Path $script:Fake "bin\remove.ps1")
        # Stands in for the real installer: records that removal was requested.
        Set-Content -Path (Join-Path $script:Fake "install.ps1") -Value 'param([string]$InstallDir, [switch]$Uninstall) Set-Content -Path (Join-Path $InstallDir "uninstall-called.txt") -Value $InstallDir'
    }

    It "Removes nothing when the answer is not y" {
        $output = ("n" | & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Fake "bin\remove.ps1") 2>&1 | Out-String)
        $output | Should -Match "Cancelled"
        Test-Path (Join-Path $script:Fake "uninstall-called.txt") | Should -BeFalse
    }

    It "Sends a <Manager> install to its package manager instead of removing files" -ForEach @(
        @{ Manager = "Scoop"; Dir = "scoop\apps\sweepr\1.36.0"; Expected = "scoop uninstall sweepr" },
        @{ Manager = "winget"; Dir = "Microsoft\WinGet\Packages\brummilab.Sweepr_Microsoft.Winget.Source_8wekyb3d8bbwe"; Expected = "winget uninstall brummilab.Sweepr" }
    ) {
        $managed = Join-Path $TestDrive $Dir
        New-Item -ItemType Directory -Path (Join-Path $managed "bin") -Force | Out-Null
        Copy-Item (Join-Path $script:WindowsDir "bin\remove.ps1") (Join-Path $managed "bin\remove.ps1")
        Copy-Item (Join-Path $script:Fake "install.ps1") (Join-Path $managed "install.ps1")

        $output = ("y" | & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $managed "bin\remove.ps1") 2>&1 | Out-String)
        $LASTEXITCODE | Should -Be 1
        $output | Should -Match ([regex]::Escape($Expected))
        Test-Path (Join-Path $managed "uninstall-called.txt") | Should -BeFalse
    }

    It "Asks with the install path and removes on y" {
        $output = ("y" | & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Fake "bin\remove.ps1") 2>&1 | Out-String)
        $output | Should -Not -Match "cannot be retrieved"
        Test-Path (Join-Path $script:Fake "uninstall-called.txt") | Should -BeTrue
    }
}

Describe "sw --version install line" {
    BeforeAll {
        $windowsDir = Split-Path -Parent $PSScriptRoot
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $windowsDir "sweepr.ps1"), [ref]$null, [ref]$null)
        foreach ($name in @("Get-SweeprSourceCommit", "Get-SweeprInstallDescription", "Get-SweeprInstallMethod")) {
            $definition = $ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
                }, $true)
            . ([scriptblock]::Create($definition.Extent.Text))
            Set-Item -Path "function:script:$name" -Value (Get-Item "function:$name").ScriptBlock
        }
        $script:Sha = "0123456789abcdef0123456789abcdef01234567"
    }

    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path (Join-Path $script:Root ".git\refs\heads") -Force | Out-Null
    }

    It "Names the commit of a checked-out release tag" {
        Set-Content -LiteralPath (Join-Path $script:Root ".git\HEAD") -Value $script:Sha
        Get-SweeprInstallDescription -RootDir $script:Root | Should -BeExactly "Source (0123456)"
    }

    It "Follows a branch ref, loose or packed" {
        Set-Content -LiteralPath (Join-Path $script:Root ".git\HEAD") -Value "ref: refs/heads/windows"
        Set-Content -LiteralPath (Join-Path $script:Root ".git\packed-refs") -Value @("# pack-refs with: peeled", "$($script:Sha) refs/heads/windows")
        Get-SweeprInstallDescription -RootDir $script:Root | Should -BeExactly "Source (0123456)"

        Set-Content -LiteralPath (Join-Path $script:Root ".git\refs\heads\windows") -Value ("f" * 40)
        Get-SweeprInstallDescription -RootDir $script:Root | Should -BeExactly "Source (fffffff)"
    }

    It "Says Source without a commit when the metadata cannot be read" {
        Set-Content -LiteralPath (Join-Path $script:Root ".git\HEAD") -Value "ref: refs/heads/missing"
        Get-SweeprInstallDescription -RootDir $script:Root | Should -BeExactly "Source"
    }

    It "Leaves a copy without Git metadata as Portable" {
        Remove-Item -LiteralPath (Join-Path $script:Root ".git") -Recurse -Force
        Get-SweeprInstallDescription -RootDir $script:Root | Should -BeExactly "Portable"
    }
}

Describe "Debug through installed launcher call shapes" {
    It "Creates a debug session through <_>" -ForEach @("File", "Command") {
        $profile = Join-Path $TestDrive ("debug-" + $_)
        New-Item -ItemType Directory -Path $profile -Force | Out-Null
        $savedProfile = $env:USERPROFILE
        $savedDebug = $env:SWEEPR_DEBUG
        $sweepr = Join-Path (Split-Path -Parent $PSScriptRoot) "sweepr.ps1"
        try {
            $env:USERPROFILE = $profile
            $env:SWEEPR_DEBUG = $null
            # Debug lines go to stderr when stdout is redirected, and Windows
            # PowerShell turns each into an error record that a Stop
            # preference would throw on; they are what this test reads.
            if ($_ -eq "File") {
                $output = & { $ErrorActionPreference = "Continue"; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sweepr clean --help --debug 2>&1 | Out-String }
            }
            else {
                $command = "& '" + $sweepr.Replace("'", "''") + "' 'clean' '--help' '--debug'; exit `$LASTEXITCODE"
                $output = & { $ErrorActionPreference = "Continue"; & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command 2>&1 | Out-String }
            }
            $LASTEXITCODE | Should -Be 0
            $output | Should -Match 'Debug logging enabled'
            $output | Should -Match 'Debug session log saved'
            $log = Join-Path $profile ".config\sweepr\sweepr_debug_session.log"
            Test-Path -LiteralPath $log | Should -BeTrue
            [System.IO.File]::ReadAllText($log) | Should -Match 'Command: sw clean .*--debug'
        }
        finally {
            $env:USERPROFILE = $savedProfile
            $env:SWEEPR_DEBUG = $savedDebug
        }
    }
}

Describe "Analyze debug routing" {
    It "Accepts the shared debug option and starts a session before Analyze help" {
        $profile = Join-Path $TestDrive "analyze-debug"
        New-Item -ItemType Directory -Path $profile -Force | Out-Null
        $previous = $env:USERPROFILE
        try {
            $env:USERPROFILE = $profile
            $sweepr = Join-Path $script:WindowsDir 'sweepr.ps1'
            $output = & { $ErrorActionPreference = "Continue"; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sweepr analyze --help --debug 2>&1 | Out-String }
            $LASTEXITCODE | Should -Be 0
            $output | Should -Match 'Interactive disk space analyzer'
            $log = Join-Path $profile '.config\sweepr\sweepr_debug_session.log'
            [System.IO.File]::ReadAllText($log) | Should -Match 'Command: sw analyze .*--debug'
        }
        finally { $env:USERPROFILE = $previous }
    }
}

Describe "Machine-readable output through installed launcher call shapes" {
    BeforeAll {
        function Invoke-SweeprShape {
            param([string]$Shape, [string]$Sweepr, [string[]]$Arguments)
            # Assigning native output captures stdout only, the redirected
            # stream an agent reads; stderr stays out of the JSON.
            if ($Shape -eq "File") {
                $lines = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Sweepr @Arguments
            }
            else {
                $quoted = @($Arguments | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join " "
                $command = "& '" + $Sweepr.Replace("'", "''") + "' $quoted; exit `$LASTEXITCODE"
                $lines = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command
            }
            [pscustomobject]@{ Text = (@($lines) -join "`n"); ExitCode = $LASTEXITCODE }
        }
    }

    It "Prints the cached uninstall inventory as JSON through <Shape><Label>" -ForEach @(
        @{ Shape = "File"; Debug = $false; Label = "" },
        @{ Shape = "Command"; Debug = $false; Label = "" },
        @{ Shape = "File"; Debug = $true; Label = " with --debug" },
        @{ Shape = "Command"; Debug = $true; Label = " with --debug" }
    ) {
        $profile = Join-Path $TestDrive ("list-" + $Shape + $(if ($Debug) { "-debug" } else { "" }))
        $cacheDir = Join-Path $profile ".cache\sweepr"
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        # A fresh cache stands in for the registry, so the child never scans this machine.
        $cache = @(
            [ordered]@{ Name = "Cached Tool"; Publisher = "Contoso"; Version = "3.0"; SizeKB = 1024; SizeHuman = "1.0MB"; SizeChecked = $true
                InstallLocation = "C:\Tools\Cached"; RegistryKey = "HKLM-test\cached"; PackageFullName = $null; Source = "Registry" }
        )
        [System.IO.File]::WriteAllText((Join-Path $cacheDir "app_scan_cache_v6.json"), (ConvertTo-Json -InputObject $cache -Depth 3))
        $saved = $env:USERPROFILE
        try {
            $env:USERPROFILE = $profile
            $arguments = @("uninstall", "--list")
            # Debug lines and the session notes go to stderr, not into the JSON.
            if ($Debug) { $arguments += "--debug" }
            $result = Invoke-SweeprShape -Shape $Shape -Sweepr (Join-Path $script:WindowsDir "sweepr.ps1") -Arguments $arguments
        }
        finally { $env:USERPROFILE = $saved }

        $result.ExitCode | Should -Be 0
        $result.Text.TrimStart().StartsWith("[") | Should -BeTrue
        $result.Text.TrimEnd().EndsWith("]") | Should -BeTrue
        if ($Debug) {
            [System.IO.File]::ReadAllText((Join-Path $profile ".config\sweepr\sweepr_debug_session.log")) | Should -Match 'Loading from cache'
        }
        $parsed = ConvertFrom-Json -InputObject $result.Text
        @($parsed).Count | Should -Be 1
        @($parsed)[0].id | Should -BeExactly "registry:HKLM-test\cached"
        @($parsed)[0].size_bytes | Should -Be 1048576
        Test-Path -LiteralPath (Join-Path $profile ".config\sweepr\operations.log") | Should -BeFalse
    }

    It "Passes --interval with its value to the status tool through <_>" -ForEach @("File", "Command") {
        $root = Join-Path $TestDrive ("status-" + $_)
        New-Item -ItemType Directory -Path (Join-Path $root "bin") -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:WindowsDir "sweepr.ps1") -Destination $root
        Copy-Item -LiteralPath (Join-Path $script:WindowsDir "VERSION") -Destination $root
        Copy-Item -LiteralPath (Join-Path $script:WindowsDir "lib") -Destination $root -Recurse
        Copy-Item -LiteralPath (Join-Path $script:WindowsDir "bin\status.ps1") -Destination (Join-Path $root "bin")
        $stub = Join-Path $root "bin\status-stub.cmd"
        Set-Content -LiteralPath $stub -Value "@echo off`r`necho ARGS=%*" -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $root "lib\core\tui_binaries.ps1") -Value "function Ensure-TuiBinary { param(`$Name, `$WindowsDir, `$DestinationPath, `$SourcePath) '$stub' }" -Encoding ASCII

        $result = Invoke-SweeprShape -Shape $_ -Sweepr (Join-Path $root "sweepr.ps1") -Arguments @("status", "--watch", "--interval", "1s")

        $result.ExitCode | Should -Be 0
        $result.Text | Should -Match '(?m)^ARGS=--watch --interval=1s\s*$'
    }

    It "Passes --json and the path to the analyzer through <_>" -ForEach @("File", "Command") {
        $root = Join-Path $TestDrive ("analyze-" + $_)
        New-Item -ItemType Directory -Path (Join-Path $root "bin") -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:WindowsDir "sweepr.ps1") -Destination $root
        Copy-Item -LiteralPath (Join-Path $script:WindowsDir "VERSION") -Destination $root
        Copy-Item -LiteralPath (Join-Path $script:WindowsDir "lib") -Destination $root -Recurse
        Copy-Item -LiteralPath (Join-Path $script:WindowsDir "bin\analyze.ps1") -Destination (Join-Path $root "bin")
        # A stand-in analyzer that reports what it was given.
        $stub = Join-Path $root "bin\analyze-stub.cmd"
        Set-Content -LiteralPath $stub -Value "@echo off`r`necho ARGS=%*`r`necho TARGET=%SWEEPR_ANALYZE_PATH%" -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $root "lib\core\tui_binaries.ps1") -Value "function Ensure-TuiBinary { param(`$Name, `$WindowsDir, `$DestinationPath, `$SourcePath) '$stub' }" -Encoding ASCII
        $target = Join-Path $TestDrive "scan target"
        New-Item -ItemType Directory -Path $target -Force | Out-Null

        $result = Invoke-SweeprShape -Shape $_ -Sweepr (Join-Path $root "sweepr.ps1") -Arguments @("analyze", "--json", $target)

        $result.ExitCode | Should -Be 0
        $result.Text | Should -Match '(?m)^ARGS=--json\s*$'
        $result.Text | Should -Match ('(?m)^TARGET=' + [regex]::Escape($target) + '\s*$')
    }

    It "Keeps analyze --json --debug stdout to the analyzer's output through <_>" -ForEach @("File", "Command") {
        $root = Join-Path $TestDrive ("analyze-debug-" + $_)
        New-Item -ItemType Directory -Path (Join-Path $root "bin") -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:WindowsDir "sweepr.ps1") -Destination $root
        Copy-Item -LiteralPath (Join-Path $script:WindowsDir "VERSION") -Destination $root
        Copy-Item -LiteralPath (Join-Path $script:WindowsDir "lib") -Destination $root -Recurse
        Copy-Item -LiteralPath (Join-Path $script:WindowsDir "bin\analyze.ps1") -Destination (Join-Path $root "bin")
        $stub = Join-Path $root "bin\analyze-stub.cmd"
        Set-Content -LiteralPath $stub -Value "@echo off`r`necho {}" -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $root "lib\core\tui_binaries.ps1") -Value "function Ensure-TuiBinary { param(`$Name, `$WindowsDir, `$DestinationPath, `$SourcePath) '$stub' }" -Encoding ASCII
        $profile = Join-Path $TestDrive ("analyze-debug-profile-" + $_)
        New-Item -ItemType Directory -Path $profile -Force | Out-Null
        $saved = $env:USERPROFILE
        try {
            $env:USERPROFILE = $profile
            $result = Invoke-SweeprShape -Shape $_ -Sweepr (Join-Path $root "sweepr.ps1") -Arguments @("analyze", "--json", "--debug")
        }
        finally { $env:USERPROFILE = $saved }

        $result.ExitCode | Should -Be 0
        $result.Text.Trim() | Should -BeExactly "{}"
        Test-Path -LiteralPath (Join-Path $profile ".config\sweepr\sweepr_debug_session.log") | Should -BeTrue
    }
}
