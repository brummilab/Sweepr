# Sweepr Windows - installer component selection tests (F-01e, Design Rev 2 section 12)
#
# Platform neutral: pure functions loaded from install.ps1 by AST extraction, so the
# installer itself never runs. Two small checks start a child pwsh on install.ps1 with an
# unknown component name, which must exit 2 before anything is installed.
#
# Interface fixed by these tests (the implementer builds exactly this in install.ps1):
#
#   ConvertTo-InstallComponents -Text <string>
#       Splits on commas and whitespace, trims, lower-cases, removes duplicates and returns a
#       sorted array of names. Allowed names: analyze, path, shortcut, status.
#       Throws on an unknown name; the message lists all allowed names.
#       Empty or whitespace text returns an empty array.
#
#   Get-InstallComponentSelection -Components <string> -EnvComponents <string>
#                                 -AddToPath <bool> -CreateShortcut <bool> -Interactive <bool>
#       Rule 1: -Components not empty -> exactly those.
#       Rule 2: -EnvComponents not empty (value of SWEEPR_COMPONENTS) -> exactly those.
#       Rule 3: -Interactive $true -> Show-InstallComponentMenu -Default <rule 4 list>;
#               returns its result, which is $null when the menu was cancelled.
#       Rule 4: analyze and status always, path if AddToPath, shortcut if CreateShortcut.
#       Returns a sorted array; throws for unknown names (through ConvertTo-InstallComponents).
#
#   Test-InstallInteractive -NoPrompt <bool> -Uninstall <bool>
#                           [-InputRedirected <bool>] [-OutputRedirected <bool>] [-UserInteractive <bool>]
#       Returns $true only for a real console: nothing redirected, UserInteractive, not NoPrompt,
#       not Uninstall. The three optional parameters default to [Console]::IsInputRedirected,
#       [Console]::IsOutputRedirected and [Environment]::UserInteractive; tests pass them explicitly.
#
#   Read-InstallMenuKey
#       Returns [System.ConsoleKeyInfo] from [Console]::ReadKey($true). Mocked in tests.
#
#   Show-InstallComponentMenu -Default <string[]>
#       Lists path, shortcut, analyze, status as [x]/[ ] (ASCII, output only through Write-Host,
#       no cursor positioning). The cursor starts on "path". UpArrow/DownArrow move it, Spacebar
#       toggles, Enter confirms and returns the sorted selection, Escape or Q returns $null.
#
#   Ensure-OptionalTuiTools -RootDir <string> -Tools <string[]>
#       Prepares only the listed tools (analyze, status); an empty list prepares none.
#
#   install.ps1 param block: -Components [string] and -NoPrompt [switch] are the LAST two
#   parameters (the legacy decoder depends on positions). Show-InstallerHelp documents both.
#   Unknown component: error with the allowed names, exit code 2, nothing installed.
#   bin/update.ps1 passes -NoPrompt to install.ps1.
#
# F-01g additions (interface fixed by the tests at the end of this file):
#
#   Legacy call (v1.30.0: & install.ps1 @("-InstallDir", $dir, "-AddToPath")): -Components is ignored,
#   the menu never shows, SWEEPR_COMPONENTS is ignored, and the PATH intent is not taken from the
#   switches but derived live: Resolve-InstallInvocation calls Test-InstallDirOnUserPath -Path <SourceDir>
#   (a function in install.ps1, same logic as in bin/update.ps1) and sets AddToPath from it.
#   Menu cancelled: Main prints "Installation cancelled", installs nothing and exits with code 3
#   (1 stays "failed", 2 stays "bad arguments").
#   quick-install.ps1: exit code 3 from install.ps1 is reported as "Installation cancelled", never as
#   "Installation failed: Installer exited with code 3". A folder this very run cloned (the install
#   directory did not exist before) is removed again; a folder that already existed is kept and its path
#   named in the output. Any other non-zero code still reports "Installation failed" and keeps the folder.
#   $script:InstallComponentNames is the only list of the four names in install.ps1 and is really read.

BeforeAll {
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $script:InstallScript = Join-Path $script:WindowsDir "install.ps1"
    $script:InstallAst = [System.Management.Automation.Language.Parser]::ParseFile($script:InstallScript, [ref]$null, [ref]$null)

    function Get-InstallFunctionAst {
        param([string]$Name)
        $script:InstallAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true)
    }

    # The one list of component names, when install.ps1 keeps it in a script variable.
    $nameAssignment = $script:InstallAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$script:InstallComponentNames'
        }, $true)
    if ($nameAssignment) {
        $script:InstallComponentNames = @(& ([scriptblock]::Create($nameAssignment.Right.Extent.Text)))
    }

    # Stand-in so Mock has a command to replace; the real function from install.ps1 wins when it exists.
    function Test-InstallDirOnUserPath { param([string]$Path) return $false }

    # Functions that must exist. A missing one is a test failure, not a load failure.
    $script:Loaded = @{}
    foreach ($name in @("ConvertTo-InstallComponents", "Get-InstallComponentSelection", "Test-InstallInteractive",
            "Show-InstallComponentMenu", "Read-InstallMenuKey", "Ensure-OptionalTuiTools", "Resolve-InstallInvocation",
            "Test-InstallDirOnUserPath")) {
        $definition = Get-InstallFunctionAst -Name $name
        if ($definition) {
            . ([scriptblock]::Create($definition.Extent.Text))
            Set-Item -Path "function:script:$name" -Value (Get-Item "function:$name").ScriptBlock
            $script:Loaded[$name] = $true
        }
    }

    function Write-Info { param($Message) }
    function Write-Success { param($Message) }
    function Write-SweeprWarning { param($Message) }
    function Write-SweeprError { param($Message) }
    function Get-SweeprVersionFromScriptFile { param($WindowsDir) "0.0.0" }
    function Ensure-TuiBinary { param($Name, $WindowsDir, $DestinationPath, $SourcePath, $Version, [switch]$Refresh) "ok" }

    function New-Key {
        param([System.ConsoleKey]$Key, [char]$Char = [char]0)
        [System.ConsoleKeyInfo]::new($Char, $Key, $false, $false, $false)
    }

    function Use-MenuKeys {
        param([object[]]$Keys)
        $script:KeyQueue = [System.Collections.Queue]::new()
        foreach ($k in $Keys) { $script:KeyQueue.Enqueue($k) }
    }

    function Invoke-Installer {
        param([string[]]$Arguments)
        $pwshPath = (Get-Process -Id $PID).Path
        $output = & $pwshPath -NoProfile -NonInteractive -File $script:InstallScript @Arguments 2>&1 | Out-String
        [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }

    # Exit code install.ps1 uses when the component menu was cancelled.
    $script:CancelExitCode = 3

    # A sandbox folder holding a copy of the real install.ps1 plus the two library files it dot-sources.
    # -StubInstall makes Install-Sweepr print the effective choices and return, so nothing is installed,
    # no PATH is touched and no network is used. -MenuEscape pretends to be a real console and presses
    # Escape in the component menu (-NoPrompt and -Uninstall are still honored). The rest of install.ps1
    # (parameter binding, legacy decoder, Main, exit codes) is the real code.
    function New-InstallSandbox {
        param([string]$Name, [switch]$StubInstall, [switch]$MenuEscape)

        $root = Join-Path $TestDrive $Name
        $core = Join-Path $root "lib/core"
        New-Item -ItemType Directory -Path $core -Force | Out-Null
        foreach ($file in "version.ps1", "tui_binaries.ps1") {
            Copy-Item -LiteralPath (Join-Path $script:WindowsDir "lib/core/$file") -Destination $core
        }
        Set-Content -LiteralPath (Join-Path $root "VERSION") -Value "1.0.0"

        $text = Get-Content -LiteralPath $script:InstallScript -Raw
        if ($StubInstall) {
            $stub = @'
function Install-Sweepr {
    Write-Host "HARNESS install reached"
    Write-Host "HARNESS dir=$InstallDir"
    Write-Host "HARNESS path=$($script:AddToPath.IsPresent)"
    Write-Host "HARNESS shortcut=$($script:CreateShortcut.IsPresent)"
    Write-Host "HARNESS tools=$(@($script:InstallTools) -join ',')"
    return $true
    # (the original body follows and is never reached)
'@
            $patched = $text.Replace("function Install-Sweepr {", $stub)
            if ($patched -ceq $text) { throw "Install-Sweepr not found in install.ps1" }
            $text = $patched
        }
        if ($MenuEscape) {
            $override = @'
function Test-InstallInteractive { param([bool]$NoPrompt, [bool]$Uninstall) return ((-not $NoPrompt) -and (-not $Uninstall)) }
function Read-InstallMenuKey { return [System.ConsoleKeyInfo]::new([char]27, [System.ConsoleKey]::Escape, $false, $false, $false) }
# Run
'@
            $patched = $text.Replace("`n# Run", "`n" + $override)
            if ($patched -ceq $text) { throw "'# Run' marker not found in install.ps1" }
            $text = $patched
        }
        Set-Content -LiteralPath (Join-Path $root "install.ps1") -Value $text -Encoding UTF8
        return $root
    }

    # Runs a script body in a child pwsh and returns exit code and output. A terminating error while the
    # arguments are bound (as opposed to an exit code of the script) shows up as exit code 99.
    function Invoke-ChildScript {
        param([string]$Body, [hashtable]$Environment = @{})

        $wrapper = Join-Path $TestDrive ("wrapper-" + [guid]::NewGuid().ToString("N") + ".ps1")
        Set-Content -LiteralPath $wrapper -Encoding UTF8 -Value @"
try {
$Body
    if (`$null -eq `$LASTEXITCODE) { exit 0 }
    exit `$LASTEXITCODE
}
catch {
    Write-Output "BINDING-ERROR: `$(`$_.Exception.Message)"
    exit 99
}
"@
        $saved = @{}
        foreach ($key in $Environment.Keys) { $saved[$key] = [Environment]::GetEnvironmentVariable($key) }
        try {
            foreach ($key in $Environment.Keys) { [Environment]::SetEnvironmentVariable($key, $Environment[$key]) }
            $pwshPath = (Get-Process -Id $PID).Path
            $output = & $pwshPath -NoProfile -NonInteractive -File $wrapper 2>&1 | Out-String
            [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = $output }
        }
        finally {
            foreach ($key in $Environment.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
        }
    }

    # The v1.30.0 updater call: the argument array is splatted, so every element binds positionally.
    function Invoke-LegacyInstall {
        param([string]$Sandbox, [switch]$WithAddToPath, [hashtable]$Environment = @{})

        $elements = "'-InstallDir', '$Sandbox'"
        if ($WithAddToPath) { $elements += ", '-AddToPath'" }
        $installScript = Join-Path $Sandbox "install.ps1"
        $childEnvironment = @{ SWEEPR_COMPONENTS = $null }
        foreach ($key in $Environment.Keys) { $childEnvironment[$key] = $Environment[$key] }
        Invoke-ChildScript -Environment $childEnvironment -Body @"
    `$legacyArguments = @($elements)
    & '$installScript' @legacyArguments
"@
    }

    # quick-install.ps1 with a fake git and a fake powershell.exe, so there is no clone, no network and no real
    # install. The fake installer exits with $InstallerExit. A function wins over an executable, so the real
    # quick-install.ps1 runs unchanged on any platform.
    function Invoke-QuickInstall {
        param([string]$Target, [int]$InstallerExit, [switch]$PreExisting)

        if ($PreExisting) {
            New-Item -ItemType Directory -Path (Join-Path $Target ".git") -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Target "install.ps1") -Value "# fake installer"
        }
        $quick = Join-Path $script:WindowsDir "quick-install.ps1"
        Invoke-ChildScript -Environment @{ HTTPS_PROXY = "http://proxy.example:3128" } -Body @"
    function git {
        `$global:LASTEXITCODE = 0
        if (`$args -contains 'clone') {
            New-Item -ItemType Directory -Path (Join-Path `$args[-1] '.git') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path `$args[-1] 'install.ps1') -Value '# fake installer'
        }
    }
    function powershell.exe { `$global:LASTEXITCODE = $InstallerExit }
    & '$quick' -InstallDir '$Target'
"@
    }
}

Describe "install.ps1 interface" {
    It "Declares -Components and -NoPrompt as the last two parameters" {
        $params = @($script:InstallAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $params.Count | Should -BeGreaterThan 2
        $params[-2] | Should -Be "Components"
        $params[-1] | Should -Be "NoPrompt"
    }

    It "Types -Components as string and -NoPrompt as switch" {
        $byName = @{}
        foreach ($p in $script:InstallAst.ParamBlock.Parameters) {
            $byName[$p.Name.VariablePath.UserPath] = ($p.StaticType.Name)
        }
        $byName["Components"] | Should -Be "String"
        $byName["NoPrompt"] | Should -Be "SwitchParameter"
    }

    It "Documents -Components and -NoPrompt in the help text" {
        $help = Get-InstallFunctionAst -Name "Show-InstallerHelp"
        $help | Should -Not -BeNullOrEmpty
        $help.Extent.Text | Should -Match "-Components"
        $help.Extent.Text | Should -Match "-NoPrompt"
        $help.Extent.Text | Should -Match "SWEEPR_COMPONENTS"
    }

    It "Asks for the selection before the install starts" {
        $main = Get-InstallFunctionAst -Name "Main"
        $calls = $main.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -in @("Get-InstallComponentSelection", "Install-Sweepr")
            }, $true)
        $names = @($calls | Sort-Object { $_.Extent.StartOffset } | ForEach-Object { $_.GetCommandName() })
        $names | Should -Contain "Get-InstallComponentSelection"
        $names.IndexOf("Get-InstallComponentSelection") | Should -BeLessThan $names.IndexOf("Install-Sweepr")
    }

    It "Exits with code 2 and installs nothing for an unknown component" {
        $target = Join-Path $TestDrive "unknown-component-target"
        $result = Invoke-Installer -Arguments @("-InstallDir", $target, "-Components", "path,bogus", "-NoPrompt")
        $result.ExitCode | Should -Be 2
        $result.Output | Should -Match "bogus"
        foreach ($allowed in "analyze", "path", "shortcut", "status") { $result.Output | Should -Match $allowed }
        Test-Path -LiteralPath $target | Should -BeFalse
    }

    It "Exits with code 2 for an unknown name in SWEEPR_COMPONENTS" {
        $target = Join-Path $TestDrive "unknown-env-target"
        $saved = $env:SWEEPR_COMPONENTS
        $env:SWEEPR_COMPONENTS = "nonsense"
        try { $result = Invoke-Installer -Arguments @("-InstallDir", $target, "-NoPrompt") }
        finally { $env:SWEEPR_COMPONENTS = $saved }
        $result.ExitCode | Should -Be 2
        Test-Path -LiteralPath $target | Should -BeFalse
    }
}

Describe "ConvertTo-InstallComponents" {
    BeforeEach { $script:Loaded["ConvertTo-InstallComponents"] | Should -BeTrue }

    It "Parses a comma separated list into a sorted list" {
        @(ConvertTo-InstallComponents -Text "status,path") | Should -Be @("path", "status")
    }

    It "Accepts spaces around names and as separators" {
        @(ConvertTo-InstallComponents -Text " path , shortcut ") | Should -Be @("path", "shortcut")
        @(ConvertTo-InstallComponents -Text "analyze status") | Should -Be @("analyze", "status")
    }

    It "Ignores case" {
        @(ConvertTo-InstallComponents -Text "PATH,Shortcut,ANALYZE") | Should -Be @("analyze", "path", "shortcut")
    }

    It "Removes duplicates" {
        @(ConvertTo-InstallComponents -Text "path,PATH,path").Count | Should -Be 1
    }

    It "Returns an empty list for empty text" {
        @(ConvertTo-InstallComponents -Text "").Count | Should -Be 0
        @(ConvertTo-InstallComponents -Text "   ").Count | Should -Be 0
    }

    It "Accepts all four known names" {
        @(ConvertTo-InstallComponents -Text "path,shortcut,analyze,status") | Should -Be @("analyze", "path", "shortcut", "status")
    }

    It "Throws for an unknown name and lists the allowed names" {
        $message = ""
        try { ConvertTo-InstallComponents -Text "path,bogus" } catch { $message = $_.Exception.Message }
        $message | Should -Match "bogus"
        foreach ($allowed in "analyze", "path", "shortcut", "status") { $message | Should -Match $allowed }
    }

    It "Does not treat the core as a selectable component" {
        { ConvertTo-InstallComponents -Text "core" } | Should -Throw
    }
}

Describe "Get-InstallComponentSelection" {
    BeforeEach {
        $script:Loaded["Get-InstallComponentSelection"] | Should -BeTrue
        $script:Loaded["Show-InstallComponentMenu"] | Should -BeTrue
        Mock Show-InstallComponentMenu { @("status") }
    }

    It "Uses -Components before everything else" {
        $result = Get-InstallComponentSelection -Components "shortcut" -EnvComponents "path" -AddToPath $true -CreateShortcut $false -Interactive $true
        @($result) | Should -Be @("shortcut")
        Should -Invoke Show-InstallComponentMenu -Times 0 -Exactly
    }

    It "Uses SWEEPR_COMPONENTS when -Components is empty" {
        $result = Get-InstallComponentSelection -Components "" -EnvComponents "Path, status" -AddToPath $false -CreateShortcut $false -Interactive $true
        @($result) | Should -Be @("path", "status")
        Should -Invoke Show-InstallComponentMenu -Times 0 -Exactly
    }

    It "Treats a null -Components like an empty one" {
        $result = Get-InstallComponentSelection -Components $null -EnvComponents "analyze" -AddToPath $true -CreateShortcut $true -Interactive $false
        @($result) | Should -Be @("analyze")
    }

    It "Shows the menu when interactive and nothing was given" {
        $result = Get-InstallComponentSelection -Components "" -EnvComponents "" -AddToPath $false -CreateShortcut $false -Interactive $true
        Should -Invoke Show-InstallComponentMenu -Times 1 -Exactly
        @($result) | Should -Be @("status")
    }

    It "Preselects the legacy default in the menu" {
        Get-InstallComponentSelection -Components "" -EnvComponents "" -AddToPath $true -CreateShortcut $false -Interactive $true | Out-Null
        Should -Invoke Show-InstallComponentMenu -Times 1 -Exactly -ParameterFilter {
            (@($Default | Sort-Object) -join ",") -eq "analyze,path,status"
        }
    }

    It "Returns null when the menu was cancelled" {
        Mock Show-InstallComponentMenu { $null }
        $result = Get-InstallComponentSelection -Components "" -EnvComponents "" -AddToPath $true -CreateShortcut $true -Interactive $true
        $null -eq $result | Should -BeTrue
    }

    It "Does not show the menu when not interactive" {
        Get-InstallComponentSelection -Components "" -EnvComponents "" -AddToPath $false -CreateShortcut $false -Interactive $false | Out-Null
        Should -Invoke Show-InstallComponentMenu -Times 0 -Exactly
    }

    It "Defaults to analyze and status only without the old switches" {
        $result = Get-InstallComponentSelection -Components "" -EnvComponents "" -AddToPath $false -CreateShortcut $false -Interactive $false
        @($result) | Should -Be @("analyze", "status")
    }

    It "Adds path for -AddToPath" {
        $result = Get-InstallComponentSelection -Components "" -EnvComponents "" -AddToPath $true -CreateShortcut $false -Interactive $false
        @($result) | Should -Be @("analyze", "path", "status")
    }

    It "Adds shortcut for -CreateShortcut" {
        $result = Get-InstallComponentSelection -Components "" -EnvComponents "" -AddToPath $false -CreateShortcut $true -Interactive $false
        @($result) | Should -Be @("analyze", "shortcut", "status")
    }

    It "Returns all four with both old switches" {
        $result = Get-InstallComponentSelection -Components "" -EnvComponents "" -AddToPath $true -CreateShortcut $true -Interactive $false
        @($result) | Should -Be @("analyze", "path", "shortcut", "status")
    }

    It "Honors an explicit selection without path even when -AddToPath is set" {
        $result = Get-InstallComponentSelection -Components "analyze" -EnvComponents "" -AddToPath $true -CreateShortcut $true -Interactive $false
        @($result) | Should -Be @("analyze")
    }

    It "Throws for an unknown name in -Components" {
        { Get-InstallComponentSelection -Components "bogus" -EnvComponents "" -AddToPath $false -CreateShortcut $false -Interactive $false } | Should -Throw "*bogus*"
    }

    It "Throws for an unknown name in the environment value" {
        { Get-InstallComponentSelection -Components "" -EnvComponents "bogus" -AddToPath $false -CreateShortcut $false -Interactive $false } | Should -Throw "*bogus*"
    }
}

Describe "Test-InstallInteractive" {
    BeforeEach { $script:Loaded["Test-InstallInteractive"] | Should -BeTrue }

    It "Is true for a real console" {
        Test-InstallInteractive -NoPrompt $false -Uninstall $false -InputRedirected $false -OutputRedirected $false -UserInteractive $true | Should -BeTrue
    }

    It "Is false with -NoPrompt" {
        Test-InstallInteractive -NoPrompt $true -Uninstall $false -InputRedirected $false -OutputRedirected $false -UserInteractive $true | Should -BeFalse
    }

    It "Is false with -Uninstall" {
        Test-InstallInteractive -NoPrompt $false -Uninstall $true -InputRedirected $false -OutputRedirected $false -UserInteractive $true | Should -BeFalse
    }

    It "Is false when input is redirected" {
        Test-InstallInteractive -NoPrompt $false -Uninstall $false -InputRedirected $true -OutputRedirected $false -UserInteractive $true | Should -BeFalse
    }

    It "Is false when output is redirected" {
        Test-InstallInteractive -NoPrompt $false -Uninstall $false -InputRedirected $false -OutputRedirected $true -UserInteractive $true | Should -BeFalse
    }

    It "Is false when the session is not user interactive" {
        Test-InstallInteractive -NoPrompt $false -Uninstall $false -InputRedirected $false -OutputRedirected $false -UserInteractive $false | Should -BeFalse
    }
}

Describe "Show-InstallComponentMenu" {
    BeforeEach {
        $script:Loaded["Show-InstallComponentMenu"] | Should -BeTrue
        $script:Loaded["Read-InstallMenuKey"] | Should -BeTrue
        $script:MenuOutput = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:MenuOutput.Add(($Object -join " ")) }
        Mock Read-InstallMenuKey { $script:KeyQueue.Dequeue() }
    }

    It "Confirms the default selection with Enter" {
        Use-MenuKeys @((New-Key Enter))
        $result = Show-InstallComponentMenu -Default @("analyze", "status")
        @($result) | Should -Be @("analyze", "status")
    }

    It "Toggles the first entry (path) with Space" {
        Use-MenuKeys @((New-Key Spacebar " "), (New-Key Enter))
        $result = Show-InstallComponentMenu -Default @("analyze", "status")
        @($result) | Should -Be @("analyze", "path", "status")
    }

    It "Clears an entry with Space when it was selected" {
        Use-MenuKeys @((New-Key Spacebar " "), (New-Key Enter))
        $result = Show-InstallComponentMenu -Default @("path", "analyze", "status")
        @($result) | Should -Be @("analyze", "status")
    }

    It "Moves down to the shortcut entry" {
        Use-MenuKeys @((New-Key DownArrow), (New-Key Spacebar " "), (New-Key Enter))
        $result = Show-InstallComponentMenu -Default @("analyze", "status")
        @($result) | Should -Be @("analyze", "shortcut", "status")
    }

    It "Moves down three times to the status entry" {
        Use-MenuKeys @((New-Key DownArrow), (New-Key DownArrow), (New-Key DownArrow), (New-Key Spacebar " "), (New-Key Enter))
        $result = Show-InstallComponentMenu -Default @("analyze", "status")
        @($result) | Should -Be @("analyze")
    }

    It "Moves back up with the arrow up key" {
        Use-MenuKeys @((New-Key DownArrow), (New-Key DownArrow), (New-Key UpArrow), (New-Key Spacebar " "), (New-Key Enter))
        $result = Show-InstallComponentMenu -Default @("analyze", "status")
        @($result) | Should -Be @("analyze", "shortcut", "status")
    }

    It "Can clear everything" {
        Use-MenuKeys @(
            (New-Key Spacebar " "), (New-Key DownArrow), (New-Key DownArrow), (New-Key Spacebar " "),
            (New-Key DownArrow), (New-Key Spacebar " "), (New-Key Enter))
        $result = Show-InstallComponentMenu -Default @("path", "analyze", "status")
        @($result).Count | Should -Be 0
        $null -eq $result | Should -BeFalse
    }

    It "Cancels with Escape" {
        Use-MenuKeys @((New-Key Spacebar " "), (New-Key Escape))
        $result = Show-InstallComponentMenu -Default @("analyze", "status")
        $null -eq $result | Should -BeTrue
    }

    It "Cancels with Q" {
        Use-MenuKeys @((New-Key Q "q"))
        $result = Show-InstallComponentMenu -Default @("analyze", "status")
        $null -eq $result | Should -BeTrue
    }

    It "Cancels with an upper case Q" {
        Use-MenuKeys @((New-Key Q "Q"))
        $result = Show-InstallComponentMenu -Default @("analyze", "status")
        $null -eq $result | Should -BeTrue
    }

    It "Ignores unrelated keys" {
        Use-MenuKeys @((New-Key A "a"), (New-Key Tab), (New-Key Enter))
        $result = Show-InstallComponentMenu -Default @("path")
        @($result) | Should -Be @("path")
    }

    It "Renders ASCII only with [x] and [ ] markers for all four components" {
        Use-MenuKeys @((New-Key Enter))
        Show-InstallComponentMenu -Default @("path", "status") | Out-Null
        $text = $script:MenuOutput -join "`n"
        $text | Should -Match "\[x\]\s+path"
        $text | Should -Match "\[ \]\s+shortcut"
        $text | Should -Match "\[ \]\s+analyze"
        $text | Should -Match "\[x\]\s+status"
        $text | Should -Not -Match "[^\x00-\x7F]"
    }
}

Describe "Ensure-OptionalTuiTools" {
    BeforeEach {
        $script:Loaded["Ensure-OptionalTuiTools"] | Should -BeTrue
        $script:Root = Join-Path $TestDrive ("root-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        Mock Ensure-TuiBinary { "ok" }
    }

    It "Declares a -Tools parameter" {
        (Get-Command Ensure-OptionalTuiTools).Parameters.Keys | Should -Contain "Tools"
    }

    It "Prepares nothing without analyze and status" {
        Ensure-OptionalTuiTools -RootDir $script:Root -Tools @()
        Should -Invoke Ensure-TuiBinary -Times 0 -Exactly
    }

    It "Prepares only analyze when only analyze is selected" {
        Ensure-OptionalTuiTools -RootDir $script:Root -Tools @("analyze")
        Should -Invoke Ensure-TuiBinary -Times 1 -Exactly
        Should -Invoke Ensure-TuiBinary -Times 1 -Exactly -ParameterFilter { $Name -eq "analyze" }
    }

    It "Prepares only status when only status is selected" {
        Ensure-OptionalTuiTools -RootDir $script:Root -Tools @("status")
        Should -Invoke Ensure-TuiBinary -Times 1 -Exactly -ParameterFilter { $Name -eq "status" }
        Should -Invoke Ensure-TuiBinary -Times 0 -Exactly -ParameterFilter { $Name -eq "analyze" }
    }

    It "Prepares both tools when both are selected" {
        Ensure-OptionalTuiTools -RootDir $script:Root -Tools @("analyze", "status")
        Should -Invoke Ensure-TuiBinary -Times 2 -Exactly
    }

    It "Is only called with the selected tools from Install-Sweepr" {
        $install = Get-InstallFunctionAst -Name "Install-Sweepr"
        $call = $install.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq "Ensure-OptionalTuiTools"
            }, $true)
        @($call).Count | Should -BeGreaterThan 0
        $call[0].Extent.Text | Should -Match "-Tools"
    }
}

Describe "Legacy invocation from v1.30.0" {
    BeforeEach { $script:Loaded["Resolve-InstallInvocation"] | Should -BeTrue }

    It "Still decodes the positional legacy shape" {
        # AddToPath is derived live from the user PATH, so the lookup is mocked.
        Mock Test-InstallDirOnUserPath { $true }
        $result = Resolve-InstallInvocation -SourceDir "C:\Example\Source" -RequestedInstallDir "-InstallDir" -RequestedAddToPath:$true -RequestedCreateShortcut:$true
        $result.InstallDir | Should -Be "C:\Example\Source"
        $result.AddToPath | Should -BeTrue
        $result.CreateShortcut | Should -BeFalse
    }

    It "Keeps the first four parameters in their legacy positions" {
        $params = @($script:InstallAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        ($params[0..3] -join ",") | Should -Be "InstallDir,AddToPath,CreateShortcut,Uninstall"
    }
}

Describe "sw update" {
    It "Passes -NoPrompt to install.ps1" {
        $updateScript = Join-Path $script:WindowsDir "bin\update.ps1"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($updateScript, [ref]$null, [ref]$null)
        $assignments = $ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $n.Left.Extent.Text -match "installParams"
            }, $true)
        $text = (@($assignments | ForEach-Object { $_.Extent.Text }) -join "`n")
        $text | Should -Match "NoPrompt"
    }
}

# ============================================================================
# F-01g: legacy call from v1.30.0
# ============================================================================

Describe "Legacy v1.30.0 call under the real parameter binding" {
    # The real install.ps1 runs in a child pwsh (7 on CI and here); only Install-Sweepr is replaced by a
    # stub that prints the effective choices. The call is the updater's own shape.

    It "Binds the splatted array and reaches the install without exit code 2 (<Name>)" -ForEach @(
        @{ Name = "with -AddToPath"; WithAddToPath = $true },
        @{ Name = "without -AddToPath"; WithAddToPath = $false }
    ) {
        $sandbox = New-InstallSandbox -Name "legacy-bind-$($WithAddToPath)" -StubInstall
        $result = Invoke-LegacyInstall -Sandbox $sandbox -WithAddToPath:$WithAddToPath
        $result.Output | Should -Not -Match "BINDING-ERROR"
        $result.Output | Should -Not -Match "Unknown component"
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match "HARNESS install reached"
    }

    It "Installs the folder the script lives in and treats the path as -InstallDir, not as a component list" {
        $sandbox = New-InstallSandbox -Name "legacy-dir" -StubInstall
        $result = Invoke-LegacyInstall -Sandbox $sandbox -WithAddToPath
        $result.ExitCode | Should -Be 0
        $dirLine = @($result.Output -split "\r?\n" | Where-Object { $_ -match "HARNESS dir=" })[0]
        $dirLine | Should -Not -BeNullOrEmpty
        ($dirLine -replace ".*HARNESS dir=", "").Trim().TrimEnd('\', '/') | Should -Be $sandbox.TrimEnd('\', '/')
    }

    It "Never shows the component menu, even on a console" {
        $sandbox = New-InstallSandbox -Name "legacy-nomenu" -StubInstall -MenuEscape
        $result = Invoke-LegacyInstall -Sandbox $sandbox -WithAddToPath
        $result.Output | Should -Not -Match "Select components"
        $result.Output | Should -Not -Match "Installation cancelled"
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match "HARNESS install reached"
    }

    It "Ignores SWEEPR_COMPONENTS with an unknown name" {
        $sandbox = New-InstallSandbox -Name "legacy-env-bogus" -StubInstall
        $result = Invoke-LegacyInstall -Sandbox $sandbox -WithAddToPath -Environment @{ SWEEPR_COMPONENTS = "nonsense" }
        $result.Output | Should -Not -Match "Unknown component"
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match "HARNESS install reached"
    }

    It "Ignores SWEEPR_COMPONENTS with valid names" {
        $sandbox = New-InstallSandbox -Name "legacy-env-valid" -StubInstall
        $result = Invoke-LegacyInstall -Sandbox $sandbox -WithAddToPath -Environment @{ SWEEPR_COMPONENTS = "shortcut" }
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match "HARNESS tools=analyze,status"
        $result.Output | Should -Match "HARNESS shortcut=False"
    }

    It "Takes the PATH intent from the live user PATH, not from the switches (folder not on PATH, <Name>)" -ForEach @(
        @{ Name = "with -AddToPath"; WithAddToPath = $true },
        @{ Name = "without -AddToPath"; WithAddToPath = $false }
    ) {
        $sandbox = New-InstallSandbox -Name "legacy-path-$($WithAddToPath)" -StubInstall
        $result = Invoke-LegacyInstall -Sandbox $sandbox -WithAddToPath:$WithAddToPath
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match "HARNESS path=False"
        $result.Output | Should -Match "HARNESS shortcut=False"
    }

    It "Leaves the regular call alone: -AddToPath is honored without a PATH lookup" {
        $sandbox = New-InstallSandbox -Name "regular-path" -StubInstall
        $installScript = Join-Path $sandbox "install.ps1"
        $target = Join-Path $sandbox "target"
        $result = Invoke-ChildScript -Environment @{ SWEEPR_COMPONENTS = $null } -Body "    & '$installScript' -InstallDir '$target' -AddToPath -NoPrompt"
        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match "HARNESS path=True"
    }
}

Describe "Legacy call: live PATH intent in Resolve-InstallInvocation" {
    It "Defines Test-InstallDirOnUserPath in install.ps1" {
        $script:Loaded["Test-InstallDirOnUserPath"] | Should -BeTrue
    }

    It "Sets AddToPath when the source folder is on the user PATH, whatever the switches say" {
        Mock Test-InstallDirOnUserPath { $true }
        $result = Resolve-InstallInvocation -SourceDir "C:\Example\Source" -RequestedInstallDir "-InstallDir" -RequestedAddToPath:$false -RequestedCreateShortcut:$false
        $result.InstallDir | Should -Be "C:\Example\Source"
        $result.AddToPath | Should -BeTrue
        $result.CreateShortcut | Should -BeFalse
        Should -Invoke Test-InstallDirOnUserPath -Times 1 -Exactly -ParameterFilter { $Path -eq "C:\Example\Source" }
    }

    It "Clears AddToPath when the source folder is not on the user PATH, even with both legacy switch values set" {
        Mock Test-InstallDirOnUserPath { $false }
        $result = Resolve-InstallInvocation -SourceDir "C:\Example\Source" -RequestedInstallDir "-InstallDir" -RequestedAddToPath:$true -RequestedCreateShortcut:$true
        $result.AddToPath | Should -BeFalse
        $result.CreateShortcut | Should -BeFalse
        Should -Invoke Test-InstallDirOnUserPath -Times 1 -Exactly -ParameterFilter { $Path -eq "C:\Example\Source" }
    }

    It "Accepts the truthy non-boolean result the update.ps1 helper style returns" {
        Mock Test-InstallDirOnUserPath { "C:\Example\Source" }
        $result = Resolve-InstallInvocation -SourceDir "C:\Example\Source" -RequestedInstallDir "-InstallDir" -RequestedAddToPath:$false -RequestedCreateShortcut:$false
        $result.AddToPath | Should -BeTrue
    }

    It "Does not look at the PATH for a regular call" {
        Mock Test-InstallDirOnUserPath { $true }
        $result = Resolve-InstallInvocation -SourceDir "C:\Example\Source" -RequestedInstallDir "C:\Example\Target" -RequestedAddToPath:$false -RequestedCreateShortcut:$true
        $result.InstallDir | Should -Be "C:\Example\Target"
        $result.AddToPath | Should -BeFalse
        $result.CreateShortcut | Should -BeTrue
        Should -Invoke Test-InstallDirOnUserPath -Times 0 -Exactly
    }
}

# ============================================================================
# F-01g: cancelled menu
# ============================================================================

Describe "install.ps1 with a cancelled component menu" {
    It "Says the installation was cancelled and exits with the cancel code, not 1 or 2" {
        $sandbox = New-InstallSandbox -Name "cancel-menu" -StubInstall -MenuEscape
        $target = Join-Path $TestDrive "cancel-menu-target"
        $installScript = Join-Path $sandbox "install.ps1"
        $result = Invoke-ChildScript -Environment @{ SWEEPR_COMPONENTS = $null } -Body "    & '$installScript' -InstallDir '$target'"
        $result.Output | Should -Match "Select components"
        $result.Output | Should -Match "Installation cancelled"
        $result.Output | Should -Not -Match "Installation failed"
        $result.ExitCode | Should -Be $script:CancelExitCode
    }

    It "Installs nothing when the menu is cancelled" {
        $sandbox = New-InstallSandbox -Name "cancel-nothing" -StubInstall -MenuEscape
        $target = Join-Path $TestDrive "cancel-nothing-target"
        $installScript = Join-Path $sandbox "install.ps1"
        $result = Invoke-ChildScript -Environment @{ SWEEPR_COMPONENTS = $null } -Body "    & '$installScript' -InstallDir '$target'"
        $result.Output | Should -Not -Match "HARNESS install reached"
        Test-Path -LiteralPath $target | Should -BeFalse
    }

    It "Keeps exit code 2 for an unknown component and 0 for a finished selection" {
        $sandbox = New-InstallSandbox -Name "cancel-others" -StubInstall -MenuEscape
        $target = Join-Path $TestDrive "cancel-others-target"
        $installScript = Join-Path $sandbox "install.ps1"
        $bad = Invoke-ChildScript -Environment @{ SWEEPR_COMPONENTS = $null } -Body "    & '$installScript' -InstallDir '$target' -Components bogus"
        $bad.ExitCode | Should -Be 2
        $good = Invoke-ChildScript -Environment @{ SWEEPR_COMPONENTS = $null } -Body "    & '$installScript' -InstallDir '$target' -Components status"
        $good.ExitCode | Should -Be 0
        $good.Output | Should -Match "HARNESS tools=status"
    }
}

Describe "quick-install.ps1 after the installer was cancelled" {
    # Fake git and a fake powershell.exe; the real quick-install.ps1 runs. The fake installer exits with the
    # cancel code, as install.ps1 does when the menu is cancelled.

    It "Reports a cancellation, not a failure" {
        $target = Join-Path $TestDrive "qi-cancel-message"
        $result = Invoke-QuickInstall -Target $target -InstallerExit $script:CancelExitCode
        $result.Output | Should -Match "Installation cancelled"
        $result.Output | Should -Not -Match "Installation failed"
        $result.Output | Should -Not -Match "Installer exited with code"
        $result.ExitCode | Should -Be 1
    }

    It "Removes the folder this run cloned, because the installer has installed nothing" {
        $target = Join-Path $TestDrive "qi-cancel-fresh"
        Test-Path -LiteralPath $target | Should -BeFalse
        $result = Invoke-QuickInstall -Target $target -InstallerExit $script:CancelExitCode
        $result.Output | Should -Match "Installation cancelled"
        Test-Path -LiteralPath $target | Should -BeFalse
    }

    It "Keeps a source install that already existed and names its folder" {
        $target = Join-Path $TestDrive "qi-cancel-existing"
        $result = Invoke-QuickInstall -Target $target -InstallerExit $script:CancelExitCode -PreExisting
        $result.Output | Should -Match "Installation cancelled"
        $result.Output | Should -Not -Match "Installation failed"
        Test-Path -LiteralPath (Join-Path $target "install.ps1") | Should -BeTrue
        $result.Output | Should -Match ([regex]::Escape($target))
    }

    It "Still reports a real installer failure as a failure and keeps the folder" {
        $target = Join-Path $TestDrive "qi-failed"
        $result = Invoke-QuickInstall -Target $target -InstallerExit 1
        $result.Output | Should -Match "Installation failed: Installer exited with code 1"
        $result.Output | Should -Not -Match "Installation cancelled"
        $result.ExitCode | Should -Be 1
        Test-Path -LiteralPath (Join-Path $target "install.ps1") | Should -BeTrue
    }

    It "Reports success without any message about failure or cancellation" {
        $target = Join-Path $TestDrive "qi-ok"
        $result = Invoke-QuickInstall -Target $target -InstallerExit 0
        $result.Output | Should -Not -Match "Installation failed"
        $result.Output | Should -Not -Match "Installation cancelled"
        $result.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $target "install.ps1") | Should -BeTrue
    }
}

# ============================================================================
# F-01g: one list of component names
# ============================================================================

Describe "Component list in install.ps1" {
    It "Has exactly one literal list of the four component names" {
        $wanted = "analyze,path,shortcut,status"
        $lists = $script:InstallAst.FindAll({
                param($node)
                if ($node -isnot [System.Management.Automation.Language.ArrayLiteralAst]) { return $false }
                $values = @($node.Elements | Where-Object { $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] } |
                        ForEach-Object { $_.Value } | Sort-Object)
                return (($values -join ",") -eq $wanted -and $values.Count -eq $node.Elements.Count)
            }, $true)
        @($lists).Count | Should -Be 1
    }

    It "Reads `$script:InstallComponentNames somewhere when it is defined" {
        $uses = @($script:InstallAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $node.VariablePath.UserPath -match "InstallComponentNames$"
                }, $true))
        $reads = @($uses | Where-Object {
                -not ($_.Parent -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Parent.Left -eq $_)
            })
        if ($uses.Count -gt 0) { $reads.Count | Should -BeGreaterThan 0 }
    }

    It "Takes the allowed names of ConvertTo-InstallComponents from that one list" {
        $definition = Get-InstallFunctionAst -Name "ConvertTo-InstallComponents"
        $literal = $definition.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -in @("analyze", "path", "shortcut", "status")
            }, $true)
        @($literal).Count | Should -Be 0
    }
}
