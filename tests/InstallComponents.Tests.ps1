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

    # Functions that must exist. A missing one is a test failure, not a load failure.
    $script:Loaded = @{}
    foreach ($name in @("ConvertTo-InstallComponents", "Get-InstallComponentSelection", "Test-InstallInteractive",
            "Show-InstallComponentMenu", "Read-InstallMenuKey", "Ensure-OptionalTuiTools", "Resolve-InstallInvocation")) {
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
