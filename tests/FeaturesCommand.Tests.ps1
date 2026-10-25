# Sweepr Windows - sw features command tests (F-02b, Design Rev 3 sections 15 and 17, decisions E15-E19, L1)
#
# Platform neutral: the command functions are lifted out of bin\features.ps1 by AST extraction, so
# its top level never runs. Every Windows cmdlet is a stub plus a Mock, menu keys and the y/N
# answer come from mockable helpers, the operations log goes to $TestDrive. Nothing real changes.
#
# Interface fixed by these tests (the implementer builds exactly this in bin\features.ps1,
# sweepr.ps1 and lib\core\history.ps1):
#
#   bin\features.ps1 param block ([CmdletBinding()], no -Restore until F-02c):
#       [Alias('dry-run')] [switch]$DryRun, [Alias('d')] [switch]$DebugMode, [switch]$List,
#       [Alias('all-users-future')] [switch]$AllUsersFuture, [Alias('h')] [switch]$ShowHelp
#   Plain ASCII. Dot-sources base, log, ui, file_ops and features. The script ends with
#       try { Invoke-FeaturesCommand -DryRun:$DryRun -List:$List -AllUsersFuture:$AllUsersFuture -ShowHelp:$ShowHelp ... }
#       finally { Stop-Spinner }
#   followed by `exit $script:FeaturesExitCode` when that is not 0. Debug mode is enabled like in
#   bin\uninstall.ps1 (Enable-DebugMode); the tests do not exercise it.
#
#   Top-level functions (all lifted by the tests):
#     Show-FeaturesHelp                    usage text: --dry-run, --list, --all-users-future, --help; no --restore
#     Test-FeaturesListAsJson              [Console]::IsOutputRedirected (mocked)
#     Read-FeaturesMenuKey                 [Console]::ReadKey($true) -> ConsoleKeyInfo (mocked)
#     Get-FeaturesWindowHeight             console window height in lines (mocked; the menu pages by it)
#     Show-FeaturesMenu -Items <rows> [...]  rows are Get-SweeprFeatureInventory items, shown in the given
#                                          order, ASCII only, output through Write-Host. Every redraw starts
#                                          with Clear-Host and is one SCREEN. A screen has at most
#                                          Get-FeaturesWindowHeight lines (a Write-Host string counts one line
#                                          per newline), also with the header and a notice. One line per row:
#                                          "<pointer> [ ] <Title>" (pointer ">" on the cursor row, "[x]" when
#                                          checked; a warning sign is allowed). The Description and the Warning
#                                          (if any) are shown ONLY for the cursor row, below the list. When
#                                          the rows do not fit, the menu shows a window of rows that follows
#                                          the cursor (arrow keys scroll past the page end; PageUp/PageDown
#                                          are optional and not tested). Nothing is checked at the start (E16),
#                                          the cursor starts on the first row, UpArrow/DownArrow move (no wrap),
#                                          Spacebar toggles (the check survives scrolling), Enter returns the
#                                          checked rows in menu order (an empty array, not $null, when none
#                                          are checked), Escape or Q returns $null. The administrator notice
#                                          for optional features is part of the head of EVERY screen (so it is
#                                          visible after each Clear-Host), however Invoke-FeaturesCommand
#                                          passes it in.
#     Invoke-FeaturesCommand [-DryRun] [-List] [-AllUsersFuture] [-ShowHelp]
#                                          the whole command. Sets $script:FeaturesExitCode (0 ok,
#                                          1 aborted by the administrator rule, 2 usage) at the start of
#                                          every call. Does not check for a console itself; if it wants
#                                          to, it does that behind a mockable Test-FeaturesInteractive.
#
#   Flow of a real run: -ShowHelp prints the help and stops. Otherwise the hint "Reading Windows
#   features, this can take a few seconds..." is written BEFORE the first Get-AppxPackage call, then
#   Get-SweeprFeatureInventory (default catalog) is read. -List: JSON object
#   {"items":[{id,kind,title,description,warning,target,provisioned}],"features_need_admin":bool}
#   on the success stream when Test-FeaturesListAsJson is true, readable lines otherwise; never a
#   menu, a prompt or a change. Else: -AllUsersFuture without administrator rights in a real run
#   writes "Run Sweepr in an administrator PowerShell for --all-users-future." and ends with exit code 1
#   before anything is read, asked or changed (a dry run still previews). When the inventory says
#   FeaturesNeedAdmin, "Run Sweepr in an administrator PowerShell for optional Windows features." is
#   written (in the menu head, see above) and the features are simply not offered. Nothing to offer -> message, no menu, exit 0.
#   Menu -> Escape/Q cancels, an empty selection stops with a message, both without a prompt.
#   Dry run (-DryRun or Test-DryRunMode already true, e.g. SWEEPR_DRY_RUN=1): sets the dry-run mode,
#   prints one exact Get-SweeprFeatureCommand line per selected row (with -AllUsersFuture when
#   given), calls no changing cmdlet, writes no operations.log line, no features-removed.json. It may
#   or may not ask for a confirmation (the tests answer "y"). Real run: lists the selection with
#   Warning text, asks Read-Host with a prompt containing "(y/N)"; only "y"/"Y" go on.
#   Per item, right before touching it: re-read the inventory and require the same Id and Target
#   (and the entry still in Get-SweeprFeatureCatalog); otherwise log SKIPPED and go on.
#   Per item, right before touching it: Get-SweeprFeatureInventory -Catalog @(<the one fresh catalog entry
#   with this Id>) (the entry comes from a fresh Get-SweeprFeatureCatalog; not in it -> SKIPPED), so only
#   that entry is read again. With -AllUsersFuture the administrator rights are checked again too (lost ->
#   SKIPPED, no Remove-* call).
#     App:     Remove-AppxPackage -Package <FullName> (no -AllUsers); with -AllUsersFuture and
#              Provisioned also Remove-AppxProvisionedPackage -Online -PackageName <ProvisionedName>,
#              user package first. Each step has its own log line: REMOVED appx:<FullName> (detail has
#              the Remove-AppxPackage command) and, with the option, REMOVED appx-provisioned:<ProvisionedName>
#              (detail has the Remove-AppxProvisionedPackage command). A failing user step: one line
#              FAILED appx:<FullName> with the error text and no provisioned step. A failing provisioned
#              step after the user package went: REMOVED appx:<FullName> plus FAILED
#              appx-provisioned:<ProvisionedName> whose detail has the command and the error text.
#   --list as JSON never calls Write-Host (the hint, notices and everything else stay off the console).
#     Feature: Disable-WindowsOptionalFeature -Online -FeatureName <Name> -NoRestart (never -Remove).
#              Success: DISABLED feature:<Name>, detail has the command and "restart needed" when the
#              result has RestartNeeded -eq $true. A throw: FAILED feature:<Name>.
#   At the end, if any result needed a restart: "Restart Windows to finish." No restart, no
#   elevation, no Start-Process.
#
#   lib\core\history.ps1: DISABLED is counted as its own action `disabled` (sessions[].actions.disabled,
#   "disabled N" in the text), no longer under `other`. appx-provisioned: lines count like any other path.

BeforeAll {
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $script:LibDir = Join-Path $script:WindowsDir "lib"
    $script:BinFile = Join-Path $script:WindowsDir "bin\features.ps1"
    $script:SweeprFile = Join-Path $script:WindowsDir "sweepr.ps1"
    $script:InstallFile = Join-Path $script:WindowsDir "install.ps1"

    . "$script:LibDir\core\base.ps1"
    . "$script:LibDir\core\log.ps1"
    . "$script:LibDir\core\ui.ps1"
    . "$script:LibDir\core\file_ops.ps1"
    . "$script:LibDir\core\features.ps1"
    . "$script:LibDir\core\history.ps1"

    # Stubs so Mock works on hosts without the Windows modules (Linux gate). Real cmdlets win on Windows.
    if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
        function Get-AppxPackage { [CmdletBinding()] param([string]$Name, [switch]$AllUsers) }
    }
    if (-not (Get-Command Get-AppxProvisionedPackage -ErrorAction SilentlyContinue)) {
        function Get-AppxProvisionedPackage { [CmdletBinding()] param([switch]$Online) }
    }
    if (-not (Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue)) {
        function Get-WindowsOptionalFeature { [CmdletBinding()] param([switch]$Online, [string]$FeatureName) }
    }
    if (-not (Get-Command Remove-AppxPackage -ErrorAction SilentlyContinue)) {
        function Remove-AppxPackage { [CmdletBinding()] param([string]$Package, [switch]$AllUsers) }
    }
    if (-not (Get-Command Remove-AppxProvisionedPackage -ErrorAction SilentlyContinue)) {
        function Remove-AppxProvisionedPackage { [CmdletBinding()] param([switch]$Online, [string]$PackageName) }
    }
    if (-not (Get-Command Disable-WindowsOptionalFeature -ErrorAction SilentlyContinue)) {
        function Disable-WindowsOptionalFeature { [CmdletBinding()] param([switch]$Online, [string]$FeatureName, [switch]$NoRestart, [switch]$Remove) }
    }
    if (-not (Get-Command Enable-WindowsOptionalFeature -ErrorAction SilentlyContinue)) {
        function Enable-WindowsOptionalFeature { [CmdletBinding()] param([switch]$Online, [string]$FeatureName, [switch]$NoRestart) }
    }
    if (-not (Get-Command Restart-Computer -ErrorAction SilentlyContinue)) {
        function Restart-Computer { [CmdletBinding()] param([switch]$Force) }
    }

    # Lift the functions of a script by name, without running its top level.
    function script:Import-AllScriptFunctions {
        param([string]$Script)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$null)
        $definitions = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
        foreach ($definition in $definitions) {
            . ([scriptblock]::Create($definition.Extent.Text))
            Set-Item -Path "function:script:$($definition.Name)" -Value (Get-Item "function:$($definition.Name)").ScriptBlock
        }
        return $ast
    }
    function script:Import-ScriptFunction {
        param([string]$Script, [string[]]$Names)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$null)
        foreach ($name in $Names) {
            $definition = $ast.Find({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
                }, $true)
            if (-not $definition) { throw "$name not found in $Script" }
            . ([scriptblock]::Create($definition.Extent.Text))
            Set-Item -Path "function:script:$name" -Value (Get-Item "function:$name").ScriptBlock
        }
    }

    $script:FeaturesAst = $null
    if (Test-Path -LiteralPath $script:BinFile) {
        $script:FeaturesAst = Import-AllScriptFunctions -Script $script:BinFile
    }
    # Placeholders so Mock still works while bin\features.ps1 does not define them yet.
    if (-not (Test-Path -Path 'function:Read-FeaturesMenuKey')) { function script:Read-FeaturesMenuKey { throw 'bin\features.ps1 is missing Read-FeaturesMenuKey' } }
    if (-not (Test-Path -Path 'function:Test-FeaturesListAsJson')) { function script:Test-FeaturesListAsJson { throw 'bin\features.ps1 is missing Test-FeaturesListAsJson' } }
    if (-not (Test-Path -Path 'function:Get-FeaturesWindowHeight')) { function script:Get-FeaturesWindowHeight { throw 'bin\features.ps1 is missing Get-FeaturesWindowHeight' } }
    # The real inventory, so a spy Mock can call through and record how it was called.
    $script:RealInventory = (Get-Command -Name Get-SweeprFeatureInventory -CommandType Function).ScriptBlock
    Import-ScriptFunction -Script $script:SweeprFile -Names @("Resolve-CommandParameterName", "Invoke-SweeprCommand", "Show-MainHelp")

    # ---- fixtures -------------------------------------------------------------------------------

    function script:New-CatalogEntry {
        param([string]$Id, [string]$Kind, [string]$Match, [string]$Title, [string]$Warning = $null)
        $restore = if ($Kind -eq 'App') { @{ Type = 'Store'; StoreId = $null } } else { @{ Type = 'Enable'; Feature = $Match } }
        return @{ Id = $Id; Kind = $Kind; Match = @($Match); Title = $Title; Description = "Example description of $Title."; Warning = $Warning; Restore = $restore }
    }

    function script:Get-TestCatalog {
        return @(
            (New-CatalogEntry 'app.example' 'App' 'Contoso.Example' 'Example App' 'Sign-in may need this.')
            (New-CatalogEntry 'app.other' 'App' 'Contoso.Other' 'Other App')
            (New-CatalogEntry 'app.third' 'App' 'Contoso.Third' 'Third App')
            (New-CatalogEntry 'feature.legacy' 'OptionalFeature' 'Contoso-Legacy' 'Legacy Feature')
            (New-CatalogEntry 'feature.second' 'OptionalFeature' 'Contoso-Second' 'Second Feature')
        )
    }

    function script:New-AppPackage {
        param([string]$Name, [string]$Version = '2.5.0.0', [string]$SignatureKind = 'Store', [string]$InstallLocation = 'C:\Program Files\WindowsApps\Example')
        return [pscustomobject]@{
            Name = $Name; PackageFullName = "${Name}_${Version}_x64__examplepublisher"; SignatureKind = $SignatureKind
            InstallLocation = $InstallLocation; IsFramework = $false; IsResourcePackage = $false; IsBundle = $false
        }
    }

    function script:Get-FullName { param([string]$Name, [string]$Version = '2.5.0.0') "${Name}_${Version}_x64__examplepublisher" }

    # Everything installed: three apps and two enabled features, administrator rights.
    function script:Set-AllInstalled {
        foreach ($name in @('Contoso.Example', 'Contoso.Other', 'Contoso.Third')) { $script:Packages[$name] = New-AppPackage -Name $name }
        foreach ($name in @('Contoso-Legacy', 'Contoso-Second')) { $script:Features[$name] = [pscustomobject]@{ FeatureName = $name; State = 'Enabled' } }
    }

    function script:New-Key {
        param([System.ConsoleKey]$Key, [char]$Char = [char]0)
        [System.ConsoleKeyInfo]::new($Char, $Key, $false, $false, $false)
    }
    function script:Get-KeySpace { New-Key -Key Spacebar -Char ' ' }
    function script:Get-KeyEnter { New-Key -Key Enter -Char "`r" }
    function script:Get-KeyDown { New-Key -Key DownArrow }
    function script:Get-KeyUp { New-Key -Key UpArrow }
    function script:Get-KeyEscape { New-Key -Key Escape -Char ([char]27) }
    function script:Get-KeyQ { New-Key -Key Q -Char 'q' }

    # Keys that check the given row indexes (0-based) of a menu with $Rows rows and press Enter.
    function script:New-SelectionKeys {
        param([int[]]$Select, [int]$Rows)
        $keys = @()
        for ($i = 0; $i -lt $Rows; $i++) {
            if ($Select -contains $i) { $keys += , (Get-KeySpace) }
            if ($i -lt $Rows - 1) { $keys += , (Get-KeyDown) }
        }
        $keys += , (Get-KeyEnter)
        return , $keys
    }

    function script:New-MenuRow {
        param([string]$Id, [string]$Kind, [string]$Title, [string]$Target, [string]$Warning = $null)
        return [pscustomobject]@{ Id = $Id; Kind = $Kind; Title = $Title; Description = "Example description of $Title."; Warning = $Warning; Target = $Target; Provisioned = $false; ProvisionedName = $null }
    }

    function script:New-ManyRows {
        param([int]$Count, [int]$WarnAt = 0)
        foreach ($n in 1..$Count) {
            $warning = if ($n -eq $WarnAt) { 'Row warning text.' } else { $null }
            New-MenuRow -Id ("app.r{0:00}" -f $n) -Kind App -Title ("Row {0:00}" -f $n) -Target ("Contoso.Row{0:00}_1.0.0.0_x64__examplepublisher" -f $n) -Warning $warning
        }
    }
    function script:New-RepeatedKeys {
        param([scriptblock]$Key, [int]$Count)
        $keys = @()
        for ($i = 0; $i -lt $Count; $i++) { $keys += , (& $Key) }
        return , $keys
    }

    # Mocks, state and a private operations log for one test. Called from BeforeEach (one per block).
    function script:Initialize-FeatureEnvironment {
        param([switch]$ThrowOnChange)

        $script:Saved = @{
            SystemRoot = $env:SystemRoot; NoOplog = $env:SWEEPR_NO_OPLOG; DryRun = $env:SWEEPR_DRY_RUN
            RunCommand = $env:_SWEEPR_OPLOG_RUN_COMMAND; RunId = $env:_SWEEPR_OPLOG_RUN_ID
            LogFile = $script:SweeprOperationsLogFile; LogStarted = $script:SweeprOperationsLogStarted
        }
        $env:SystemRoot = 'C:\Windows'
        $env:SWEEPR_NO_OPLOG = $null
        $env:SWEEPR_DRY_RUN = $null
        $env:_SWEEPR_OPLOG_RUN_COMMAND = 'features'
        $env:_SWEEPR_OPLOG_RUN_ID = 'testrun'
        $script:ConfigDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
        $script:LogFile = Join-Path $script:ConfigDir 'operations.log'
        $script:SweeprOperationsLogFile = $script:LogFile
        $script:SweeprOperationsLogStarted = $false
        Set-DryRunMode -Enabled $false

        $script:Packages = @{}
        $script:Provisioned = @()
        $script:Features = @{}
        $script:IsAdmin = $true
        $script:ListAsJson = $false
        $script:Answer = 'y'
        $script:KeyQueue = [System.Collections.Queue]::new()
        $script:Transcript = [System.Collections.Generic.List[string]]::new()
        $script:HostBuffer = ''
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        $script:Prompts = [System.Collections.Generic.List[string]]::new()
        $script:FirstScreen = $null
        $script:Screens = [System.Collections.Generic.List[object]]::new()
        $script:WindowHeight = 40
        $script:InventoryCalls = [System.Collections.Generic.List[string]]::new()
        $script:LinesAtLastKey = 0
        $script:ConfirmScreen = $null
        $script:OnAppRemove = $null
        $script:OnProvisionedRemove = $null
        $script:OnFeatureDisable = $null
        $script:OnPrompt = $null
        $script:DisableResult = [pscustomobject]@{ RestartNeeded = $false }
        $script:ThrowOnChange = [bool]$ThrowOnChange
        $script:FeaturesExitCode = 0

        Mock Get-SweeprFeatureCatalog { return @($script:Catalog) }
        $script:Catalog = @(Get-TestCatalog)

        Mock Test-IsAdmin { return $script:IsAdmin }
        Mock Test-FeaturesListAsJson { return $script:ListAsJson }
        if (Get-Command Test-FeaturesInteractive -ErrorAction SilentlyContinue) {
            Mock Test-FeaturesInteractive { return $true }
        }
        Mock Clear-Host { $script:Transcript.Add('CLEAR') }
        Mock Get-FeaturesWindowHeight { return $script:WindowHeight }
        Mock Get-SweeprFeatureInventory {
            $count = if ($null -eq $Catalog) { -1 } else { @($Catalog).Count }
            $ids = if ($null -eq $Catalog) { '' } else { (@($Catalog) | ForEach-Object { Get-SweeprFeatureProperty $_ 'Id' }) -join ',' }
            $script:InventoryCalls.Add("${count}:$ids")
            return (& $script:RealInventory @PSBoundParameters)
        }
        Mock Write-Host {
            $text = ($Object | ForEach-Object { [string]$_ }) -join ' '
            $script:HostBuffer += $text
            if (-not $NoNewline) {
                $script:Transcript.Add($script:HostBuffer)
                $script:HostBuffer = ''
            }
        }
        Mock Read-FeaturesMenuKey {
            # One screen = the lines written since the last Clear-Host (markers left out).
            $clear = $script:Transcript.LastIndexOf('CLEAR')
            $since = @($script:Transcript | Select-Object -Skip ($clear + 1) | Where-Object { $_ -cnotmatch '^(READ|CALL):' })
            if ($script:HostBuffer) { $since += $script:HostBuffer }
            $lineCount = 0
            foreach ($l in $since) { $lineCount += @($l -split "`n").Count }
            $script:Screens.Add([pscustomobject]@{ Text = ($since -join "`n"); Lines = $lineCount })
            if ($null -eq $script:FirstScreen) { $script:FirstScreen = ($since -join "`n") }
            $script:LinesAtLastKey = $script:Transcript.Count
            if ($script:KeyQueue.Count -eq 0) { throw 'Test: menu asked for more keys than the test queued' }
            return $script:KeyQueue.Dequeue()
        }
        Mock Read-Host {
            $script:Prompts.Add([string]$Prompt)
            $script:InventoryCalls.Add('PROMPT')
            $script:ConfirmScreen = (@($script:Transcript | Select-Object -Skip $script:LinesAtLastKey | Where-Object { $_ -notmatch '^(READ|CALL|CLEAR):' }) -join "`n")
            if ($script:OnPrompt) { & $script:OnPrompt }
            return $script:Answer
        }

        Mock Get-AppxPackage {
            $script:Transcript.Add("READ:Get-AppxPackage $Name")
            if ($script:Packages.ContainsKey($Name)) { return $script:Packages[$Name] }
            return $null
        }
        Mock Get-AppxProvisionedPackage {
            $script:Transcript.Add('READ:Get-AppxProvisionedPackage')
            return @($script:Provisioned)
        }
        Mock Get-WindowsOptionalFeature {
            $script:Transcript.Add("READ:Get-WindowsOptionalFeature $FeatureName")
            if ($FeatureName) {
                if ($script:Features.ContainsKey($FeatureName)) { return $script:Features[$FeatureName] }
                throw "Feature name $FeatureName is unknown."
            }
            return @($script:Features.Values)
        }

        Mock Remove-AppxPackage {
            $script:Calls.Add("Remove-AppxPackage $Package")
            if ($script:ThrowOnChange) { throw 'Remove-AppxPackage must not run' }
            if ($script:OnAppRemove) { & $script:OnAppRemove $Package }
        }
        Mock Remove-AppxProvisionedPackage {
            $script:Calls.Add("Remove-AppxProvisionedPackage $PackageName")
            if ($script:ThrowOnChange) { throw 'Remove-AppxProvisionedPackage must not run' }
            if ($script:OnProvisionedRemove) { & $script:OnProvisionedRemove $PackageName }
        }
        Mock Disable-WindowsOptionalFeature {
            $script:Calls.Add("Disable-WindowsOptionalFeature $FeatureName")
            $script:Transcript.Add("CALL:Disable-WindowsOptionalFeature $FeatureName")
            if ($script:ThrowOnChange) { throw 'Disable-WindowsOptionalFeature must not run' }
            if ($script:OnFeatureDisable) { & $script:OnFeatureDisable $FeatureName }
            return $script:DisableResult
        }
        Mock Enable-WindowsOptionalFeature { throw 'Enable-WindowsOptionalFeature belongs to F-02c' }
        Mock Restart-Computer { throw 'Sweepr must never restart Windows' }
        Mock Start-Process { throw 'Sweepr must never start a process or elevate' }
    }

    function script:Restore-FeatureEnvironment {
        Set-DryRunMode -Enabled $false
        $env:SystemRoot = $script:Saved.SystemRoot
        $env:SWEEPR_NO_OPLOG = $script:Saved.NoOplog
        $env:SWEEPR_DRY_RUN = $script:Saved.DryRun
        $env:_SWEEPR_OPLOG_RUN_COMMAND = $script:Saved.RunCommand
        $env:_SWEEPR_OPLOG_RUN_ID = $script:Saved.RunId
        $script:SweeprOperationsLogFile = $script:Saved.LogFile
        $script:SweeprOperationsLogStarted = $script:Saved.LogStarted
    }

    # Runs the command with queued keys; returns what it wrote and its exit code.
    function script:Invoke-Features {
        param([hashtable]$Params = @{}, [object[]]$Keys = @(), [string]$Answer = 'y')
        foreach ($key in $Keys) { $script:KeyQueue.Enqueue($key) }
        $script:Answer = $Answer
        $script:FeaturesExitCode = 0
        $output = @(Invoke-FeaturesCommand @Params)
        if ($script:HostBuffer) { $script:Transcript.Add($script:HostBuffer); $script:HostBuffer = '' }
        $host_ = @($script:Transcript | Where-Object { $_ -notmatch '^(READ|CALL|CLEAR):' })
        return [pscustomobject]@{
            Output = $output
            Text   = (($host_ + @($output | ForEach-Object { [string]$_ })) -join "`n")
            Exit   = $script:FeaturesExitCode
        }
    }

    function script:Get-LogRecords {
        if (-not (Test-Path -LiteralPath $script:LogFile)) { return @() }
        return @(Get-Content -LiteralPath $script:LogFile | Where-Object { $_ -match '\] (REMOVED|DISABLED|FAILED|SKIPPED|RECYCLED|OPTIMIZED|UNINSTALLED) ' })
    }

    # Runs the real sweepr.ps1 in a child with a private profile and data folder (help-only calls).
    function script:Invoke-SweeprChild {
        param([string[]]$Arguments)
        $profileDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        $saved = @{ Profile = $env:USERPROFILE; Data = $env:SWEEPR_DATA_DIR }
        try {
            $env:USERPROFILE = $profileDir
            $env:SWEEPR_DATA_DIR = Join-Path $profileDir 'data'
            $pwshPath = (Get-Process -Id $PID).Path
            $text = & { $ErrorActionPreference = 'Continue'; & $pwshPath -NoProfile -NonInteractive -File $script:SweeprFile @Arguments 2>&1 | Out-String }
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = $text }
        }
        finally {
            $env:USERPROFILE = $saved.Profile
            $env:SWEEPR_DATA_DIR = $saved.Data
        }
    }

    function script:Get-ChangeCallCount { return $script:Calls.Count }
}

Describe "sw features files and interface" {
    It "Has bin/features.ps1 as plain ASCII" {
        Test-Path -LiteralPath $script:BinFile | Should -BeTrue
        $bytes = [IO.File]::ReadAllBytes($script:BinFile)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It "Declares <Parameter> with the alias <Alias>" -ForEach @(
        @{ Parameter = 'DryRun'; Alias = 'dry-run'; Type = 'SwitchParameter' }
        @{ Parameter = 'DebugMode'; Alias = 'd'; Type = 'SwitchParameter' }
        @{ Parameter = 'AllUsersFuture'; Alias = 'all-users-future'; Type = 'SwitchParameter' }
        @{ Parameter = 'ShowHelp'; Alias = 'h'; Type = 'SwitchParameter' }
        @{ Parameter = 'List'; Alias = 'List'; Type = 'SwitchParameter' }
    ) {
        $script:FeaturesAst | Should -Not -BeNullOrEmpty
        $declared = @($script:FeaturesAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $Parameter })
        $declared.Count | Should -Be 1
        $declared[0].StaticType.Name | Should -Be $Type
        $aliases = @($declared[0].Attributes | Where-Object { $_.TypeName.Name -eq 'Alias' } | ForEach-Object { $_.PositionalArguments | ForEach-Object { $_.Value } })
        ($aliases + @($Parameter)) | Should -Contain $Alias
    }

    It "Is an advanced script and has no -Restore parameter before F-02c" {
        $script:FeaturesAst | Should -Not -BeNullOrEmpty
        @($script:FeaturesAst.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }).Count | Should -Be 1
        $names = @($script:FeaturesAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $names | Should -Not -Contain 'Restore'
    }

    It "Defines <Name>" -ForEach @(
        @{ Name = 'Invoke-FeaturesCommand' }, @{ Name = 'Show-FeaturesHelp' }, @{ Name = 'Show-FeaturesMenu' },
        @{ Name = 'Read-FeaturesMenuKey' }, @{ Name = 'Test-FeaturesListAsJson' }
    ) {
        Test-Path -Path "function:$Name" | Should -BeTrue
    }

    It "Loads the shared modules and calls the command from its top level" {
        $text = Get-Content -LiteralPath $script:BinFile -Raw
        $text | Should -Match 'core\\features\.ps1'
        $text | Should -Match 'core\\file_ops\.ps1'
        $text | Should -Match 'core\\log\.ps1'
        $text | Should -Match 'Invoke-FeaturesCommand\s+-DryRun:\$DryRun'
    }

    It "Contains no self-elevation, restart, service, registry or scheduled-task change (E19)" {
        $code = (Get-Content -LiteralPath $script:BinFile -Raw) -replace '(?m)^\s*#.*$', ''
        $code | Should -Not -Match '(?i)-Verb\s+RunAs'
        $code | Should -Not -Match '(?i)\bStart-Process\b'
        $code | Should -Not -Match '(?i)\b(Restart-Computer|Stop-Computer|shutdown(\.exe)?)\b'
        $code | Should -Not -Match '(?i)\b(Set-Service|Stop-Service|Set-ItemProperty|New-ItemProperty|Remove-ItemProperty|Disable-ScheduledTask|Unregister-ScheduledTask)\b'
        $code | Should -Not -Match '(?i)\bRemove-Item\b'
    }

    It "Never asks Disable-WindowsOptionalFeature to remove payload files" {
        $code = (Get-Content -LiteralPath $script:BinFile -Raw) -replace '(?m)^\s*#.*$', ''
        $code | Should -Not -Match '(?i)Disable-WindowsOptionalFeature[^\r\n]*-Remove\b'
    }
}

Describe "sw features router and help" {
    BeforeEach { Initialize-FeatureEnvironment }
    AfterEach { Restore-FeatureEnvironment }

    It "Lists features in the router's validCommands" {
        $text = Get-Content -LiteralPath $script:SweeprFile -Raw
        $text | Should -Match '\$validCommands\s*=\s*@\([^)]*"features"[^)]*\)'
    }

    It "Does not add --restore anywhere before F-02c" {
        (Get-Content -LiteralPath $script:SweeprFile -Raw) | Should -Not -Match '(?i)restore'
    }

    It "Shows sw features in the main help" {
        Show-MainHelp
        $help = $script:Transcript -join "`n"
        $help | Should -Match 'sw features\s+\S'
        $help | Should -Not -Match '--restore'
    }

    It "Maps <Flag> to the parameter <Parameter> of bin/features.ps1" -ForEach @(
        @{ Flag = 'dry-run'; Parameter = 'DryRun' }
        @{ Flag = 'list'; Parameter = 'List' }
        @{ Flag = 'all-users-future'; Parameter = 'AllUsersFuture' }
        @{ Flag = 'help'; Parameter = 'ShowHelp' }
        @{ Flag = 'h'; Parameter = 'ShowHelp' }
        @{ Flag = 'debug'; Parameter = 'DebugMode' }
    ) {
        $declared = (Get-Command -Name $script:BinFile -CommandType ExternalScript).Parameters
        Resolve-CommandParameterName -Parameters $declared -Flag $Flag | Should -Be $Parameter
    }

    It "Refuses --restore through sweepr.ps1 with exit code 2 and runs nothing" {
        $result = Invoke-SweeprChild -Arguments @('features', '--restore')
        $result.ExitCode | Should -Be 2
        $result.Text | Should -Match 'Unknown option for sw features: --restore'
    }

    It "Prints the features help through sweepr.ps1 with exit code 0" {
        $result = Invoke-SweeprChild -Arguments @('features', '--help')
        $result.ExitCode | Should -Be 0
        $result.Text | Should -Match '--dry-run'
        $result.Text | Should -Match '--all-users-future'
        $result.Text | Should -Not -Match 'Unknown command'
    }
}

Describe "sw features --help" {
    BeforeEach { Initialize-FeatureEnvironment }
    AfterEach { Restore-FeatureEnvironment }

    It "Documents every option and no --restore" {
        Show-FeaturesHelp
        $help = $script:Transcript -join "`n"
        foreach ($option in @('--dry-run', '--list', '--all-users-future', '--help')) { $help | Should -Match ([regex]::Escape($option)) }
        $help | Should -Match 'sw features'
        $help | Should -Not -Match '--restore'
    }

    It "Prints the help for -ShowHelp and reads or changes nothing" {
        $result = Invoke-Features -Params @{ ShowHelp = $true }
        $result.Text | Should -Match '--all-users-future'
        $result.Exit | Should -Be 0
        Should -Invoke Get-AppxPackage -Times 0
        Should -Invoke Get-WindowsOptionalFeature -Times 0
        Should -Invoke Read-Host -Times 0
        $script:Calls.Count | Should -Be 0
    }
}

Describe "sw features --list" {
    BeforeEach { Initialize-FeatureEnvironment }
    AfterEach { Restore-FeatureEnvironment }

    It "Writes JSON with items and features_need_admin when the output is redirected" {
        Set-AllInstalled
        $script:ListAsJson = $true
        $result = Invoke-Features -Params @{ List = $true }
        $json = ($result.Output | ForEach-Object { [string]$_ }) -join "`n" | ConvertFrom-Json
        @($json.items).Count | Should -Be 5
        $json.features_need_admin | Should -BeFalse
        $example = @($json.items | Where-Object { $_.id -eq 'app.example' })[0]
        $example.kind | Should -BeExactly 'App'
        $example.title | Should -BeExactly 'Example App'
        $example.description | Should -BeExactly 'Example description of Example App.'
        $example.warning | Should -BeExactly 'Sign-in may need this.'
        $example.target | Should -BeExactly 'Contoso.Example_2.5.0.0_x64__examplepublisher'
        $example.provisioned | Should -BeFalse
        $legacy = @($json.items | Where-Object { $_.id -eq 'feature.legacy' })[0]
        $legacy.kind | Should -BeExactly 'OptionalFeature'
        $legacy.target | Should -BeExactly 'Contoso-Legacy'
        $legacy.warning | Should -BeNullOrEmpty
    }

    It "Keeps the success stream pure JSON, whatever else it prints" {
        Set-AllInstalled
        $script:ListAsJson = $true
        $result = Invoke-Features -Params @{ List = $true }
        { ($result.Output | ForEach-Object { [string]$_ }) -join "`n" | ConvertFrom-Json } | Should -Not -Throw
    }

    It "Never calls Write-Host in the JSON form, with or without admin and items" {
        $script:ListAsJson = $true
        $null = Invoke-Features -Params @{ List = $true }
        Set-AllInstalled
        $null = Invoke-Features -Params @{ List = $true }
        $script:IsAdmin = $false
        $result = Invoke-Features -Params @{ List = $true }
        ($result.Output -join "`n") | Should -Match '"features_need_admin"\s*:\s*true'
        Should -Invoke Write-Host -Times 0
    }

    It "Reports provisioned apps and an empty list as an empty JSON array" {
        $script:ListAsJson = $true
        $result = Invoke-Features -Params @{ List = $true }
        (($result.Output | ForEach-Object { [string]$_ }) -join "`n") | Should -Match '"items"\s*:\s*\[\s*\]'

        $script:Packages['Contoso.Example'] = New-AppPackage -Name 'Contoso.Example'
        $script:Provisioned = @([pscustomobject]@{ DisplayName = 'Contoso.Example'; PackageName = 'Contoso.Example_2.5.0.0_neutral_~_examplepublisher' })
        $result = Invoke-Features -Params @{ List = $true }
        $json = ($result.Output | ForEach-Object { [string]$_ }) -join "`n" | ConvertFrom-Json
        @($json.items)[0].provisioned | Should -BeTrue
    }

    It "Says features need an administrator in the JSON without admin rights" {
        Set-AllInstalled
        $script:IsAdmin = $false
        $script:ListAsJson = $true
        $result = Invoke-Features -Params @{ List = $true }
        $json = ($result.Output | ForEach-Object { [string]$_ }) -join "`n" | ConvertFrom-Json
        $json.features_need_admin | Should -BeTrue
        @($json.items | Where-Object { $_.kind -eq 'OptionalFeature' }).Count | Should -Be 0
        @($json.items | Where-Object { $_.kind -eq 'App' }).Count | Should -Be 3
    }

    It "Lists titles as text on a console, with the administrator hint when features are unreadable" {
        Set-AllInstalled
        $script:IsAdmin = $false
        $result = Invoke-Features -Params @{ List = $true }
        $result.Text | Should -Match 'Example App'
        $result.Text | Should -Match 'Other App'
        $result.Text | Should -Not -Match 'Legacy Feature'
        $result.Text | Should -Match 'Run Sweepr in an administrator PowerShell for optional Windows features'
    }

    It "Lists apps and features as text with admin rights" {
        Set-AllInstalled
        $result = Invoke-Features -Params @{ List = $true }
        foreach ($title in @('Example App', 'Other App', 'Third App', 'Legacy Feature', 'Second Feature')) { $result.Text | Should -Match $title }
        $result.Text | Should -Not -Match 'Run Sweepr in an administrator PowerShell'
    }

    It "Changes nothing and asks nothing: no key, no prompt, no change, no log line" {
        Set-AllInstalled
        $result = Invoke-Features -Params @{ List = $true }
        $result.Exit | Should -Be 0
        Should -Invoke Read-FeaturesMenuKey -Times 0
        Should -Invoke Read-Host -Times 0
        $script:Calls.Count | Should -Be 0
        Test-Path -LiteralPath $script:LogFile | Should -BeFalse
    }

    It "Writes the reading hint before the first Windows query" {
        Set-AllInstalled
        $result = Invoke-Features -Params @{ List = $true }
        $lines = @($script:Transcript)
        $hint = [array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match 'Reading Windows features, this can take a few seconds' })
        $read = [array]::FindIndex($lines, [Predicate[string]] { param($l) $l -like 'READ:*' })
        $hint | Should -BeGreaterOrEqual 0
        $read | Should -BeGreaterThan $hint
    }
}

Describe "sw features menu" {
    BeforeEach { Initialize-FeatureEnvironment }
    AfterEach { Restore-FeatureEnvironment }

    BeforeAll {
        $script:Rows = @(
            (New-MenuRow -Id 'app.example' -Kind App -Title 'Example App' -Target 'Contoso.Example_2.5.0.0_x64__examplepublisher' -Warning 'Sign-in may need this.')
            (New-MenuRow -Id 'app.other' -Kind App -Title 'Other App' -Target 'Contoso.Other_2.5.0.0_x64__examplepublisher')
            (New-MenuRow -Id 'feature.legacy' -Kind OptionalFeature -Title 'Legacy Feature' -Target 'Contoso-Legacy')
        )
    }

    It "Starts with nothing selected (E16): Enter at once returns an empty array" {
        $script:KeyQueue.Enqueue((Get-KeyEnter))
        $selected = Show-FeaturesMenu -Items $script:Rows
        $null -eq $selected | Should -BeFalse
        @($selected).Count | Should -Be 0
        $script:FirstScreen | Should -Not -Match '\[x\]'
        ([regex]::Matches($script:FirstScreen, '\[ \]')).Count | Should -Be 3
    }

    It "Shows one line per row, but description and warning only for the cursor row" {
        $script:KeyQueue.Enqueue((Get-KeyEnter))
        $null = Show-FeaturesMenu -Items $script:Rows
        foreach ($title in @('Example App', 'Other App', 'Legacy Feature')) { $script:FirstScreen | Should -Match $title }
        $script:FirstScreen | Should -Match '(?m)^\s*>\s+\[ \]\s+Example App'
        $script:FirstScreen | Should -Match 'Example description of Example App\.'
        $script:FirstScreen | Should -Match 'Sign-in may need this\.'
        $script:FirstScreen | Should -Not -Match 'Example description of Other App'
        $script:FirstScreen | Should -Not -Match 'Example description of Legacy Feature'
        $boxLines = @($script:FirstScreen -split "`n" | Where-Object { $_ -match '\[ \]' })
        $boxLines.Count | Should -Be 3
        $boxLines[1] | Should -Match 'Other App'
        $boxLines[2] | Should -Match 'Legacy Feature'
    }

    It "Moves the description and the warning with the cursor" {
        foreach ($key in @((Get-KeyDown), (Get-KeyUp), (Get-KeyEnter))) { $script:KeyQueue.Enqueue($key) }
        $null = Show-FeaturesMenu -Items $script:Rows
        $script:Screens.Count | Should -Be 3
        $script:Screens[1].Text | Should -Match '(?m)^\s*>\s+\[ \]\s+Other App'
        $script:Screens[1].Text | Should -Match 'Example description of Other App\.'
        $script:Screens[1].Text | Should -Not -Match 'Example description of Example App'
        $script:Screens[1].Text | Should -Not -Match 'Sign-in may need this'
        $script:Screens[2].Text | Should -Match 'Sign-in may need this\.'
    }

    It "Shows a screen of at most <Height> lines and follows the cursor through 28 rows" -ForEach @(@{ Height = 14 }, @{ Height = 20 }) {
        $script:WindowHeight = $Height
        $rows = @(New-ManyRows -Count 28)
        foreach ($key in ((New-RepeatedKeys -Key { Get-KeyDown } -Count 27) + @((Get-KeyEnter)))) { $script:KeyQueue.Enqueue($key) }
        $null = Show-FeaturesMenu -Items $rows
        $script:Screens.Count | Should -Be 28
        foreach ($screen in $script:Screens) { $screen.Lines | Should -BeLessOrEqual $Height }
        $script:Screens[0].Text | Should -Match 'Row 01'
        $script:Screens[0].Text | Should -Not -Match 'Row 28'
        for ($n = 1; $n -le 28; $n++) {
            $script:Screens[$n - 1].Text | Should -Match ("(?m)^\s*>\s+\[ \]\s+Row {0:00}\b" -f $n)
        }
    }

    It "Scrolls back up to the first row" {
        $script:WindowHeight = 14
        $rows = @(New-ManyRows -Count 28)
        foreach ($key in ((New-RepeatedKeys -Key { Get-KeyDown } -Count 27) + (New-RepeatedKeys -Key { Get-KeyUp } -Count 27) + @((Get-KeyEnter)))) { $script:KeyQueue.Enqueue($key) }
        $null = Show-FeaturesMenu -Items $rows
        foreach ($screen in $script:Screens) { $screen.Lines | Should -BeLessOrEqual 14 }
        $script:Screens[$script:Screens.Count - 1].Text | Should -Match '(?m)^\s*>\s+\[ \]\s+Row 01\b'
    }

    It "Keeps checks made on another page and returns them in menu order" {
        $script:WindowHeight = 14
        $rows = @(New-ManyRows -Count 28)
        foreach ($key in (@((Get-KeySpace)) + (New-RepeatedKeys -Key { Get-KeyDown } -Count 27) + @((Get-KeySpace), (Get-KeyEnter)))) { $script:KeyQueue.Enqueue($key) }
        $selected = Show-FeaturesMenu -Items $rows
        @($selected | ForEach-Object { $_.Title }) | Should -Be @('Row 01', 'Row 28')
    }

    It "Shows the warning only while the cursor is on the warned row, also when paged" {
        $script:WindowHeight = 14
        $rows = @(New-ManyRows -Count 28 -WarnAt 20)
        foreach ($key in ((New-RepeatedKeys -Key { Get-KeyDown } -Count 22) + @((Get-KeyEnter)))) { $script:KeyQueue.Enqueue($key) }
        $null = Show-FeaturesMenu -Items $rows
        for ($n = 1; $n -le 23; $n++) {
            if ($n -eq 20) { $script:Screens[$n - 1].Text | Should -Match 'Row warning text\.' }
            else { $script:Screens[$n - 1].Text | Should -Not -Match 'Row warning text\.' }
        }
    }

    It "Writes ASCII only" {
        foreach ($key in (New-SelectionKeys -Select 0, 2 -Rows 3)) { $script:KeyQueue.Enqueue($key) }
        $null = Show-FeaturesMenu -Items $script:Rows
        $everything = $script:Transcript -join "`n"
        @($everything.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count | Should -Be 0
    }

    It "Toggles the row under the cursor with Space and returns the checked rows in menu order" {
        foreach ($key in (New-SelectionKeys -Select 0, 2 -Rows 3)) { $script:KeyQueue.Enqueue($key) }
        $selected = Show-FeaturesMenu -Items $script:Rows
        $selected = @($selected)
        $selected.Count | Should -Be 2
        $selected[0].Id | Should -Be 'app.example'
        $selected[1].Id | Should -Be 'feature.legacy'
    }

    It "Moves the cursor with Down and Up and unchecks with a second Space" {
        foreach ($key in @((Get-KeyDown), (Get-KeySpace), (Get-KeyUp), (Get-KeySpace), (Get-KeyDown), (Get-KeySpace), (Get-KeyEnter))) { $script:KeyQueue.Enqueue($key) }
        $selected = Show-FeaturesMenu -Items $script:Rows
        $selected = @($selected)
        $selected.Count | Should -Be 1
        $selected[0].Id | Should -Be 'app.example'
    }

    It "Does not move past the first or last row" {
        foreach ($key in @((Get-KeyUp), (Get-KeySpace), (Get-KeyDown), (Get-KeyDown), (Get-KeyDown), (Get-KeyDown), (Get-KeySpace), (Get-KeyEnter))) { $script:KeyQueue.Enqueue($key) }
        $selected = Show-FeaturesMenu -Items $script:Rows
        $selected = @($selected)
        @($selected | ForEach-Object { $_.Id }) | Should -Be @('app.example', 'feature.legacy')
    }

    It "Shows a checked row as [x]" {
        foreach ($key in @((Get-KeySpace), (Get-KeyDown), (Get-KeyEnter))) { $script:KeyQueue.Enqueue($key) }
        $null = Show-FeaturesMenu -Items $script:Rows
        ($script:Transcript -join "`n") | Should -Match '\[x\]\s+Example App'
    }

    It "Returns `$null on <Name>, even with rows checked" -ForEach @(
        @{ Name = 'Escape'; Key = { Get-KeyEscape } }
        @{ Name = 'Q'; Key = { Get-KeyQ } }
    ) {
        foreach ($key in @((Get-KeySpace), (& $Key))) { $script:KeyQueue.Enqueue($key) }
        $selected = Show-FeaturesMenu -Items $script:Rows
        $null -eq $selected | Should -BeTrue
    }
}

Describe "sw features interactive run" {
    BeforeEach { Initialize-FeatureEnvironment }
    AfterEach { Restore-FeatureEnvironment }

    It "Shows the reading hint before it reads the system, then the menu without a preselection" {
        Set-AllInstalled
        $null = Invoke-Features -Keys @((Get-KeyEscape))
        $lines = @($script:Transcript)
        $hint = [array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match 'Reading Windows features, this can take a few seconds' })
        $read = [array]::FindIndex($lines, [Predicate[string]] { param($l) $l -like 'READ:*' })
        $hint | Should -BeGreaterOrEqual 0
        $read | Should -BeGreaterThan $hint
        $script:FirstScreen | Should -Match 'Example App'
        $script:FirstScreen | Should -Match 'Legacy Feature'
        $script:FirstScreen | Should -Not -Match '\[x\]'
    }

    It "Offers installed catalog entries only, apps before features, in catalog order" {
        Set-AllInstalled
        $script:Packages.Remove('Contoso.Other')
        $script:Features.Remove('Contoso-Second')
        $script:Packages['Contoso.Unlisted'] = New-AppPackage -Name 'Contoso.Unlisted'
        $null = Invoke-Features -Keys @((Get-KeyEscape))
        $screen = $script:FirstScreen
        $screen.IndexOf('Example App') | Should -BeGreaterOrEqual 0
        $screen.IndexOf('Third App') | Should -BeGreaterThan $screen.IndexOf('Example App')
        $screen.IndexOf('Legacy Feature') | Should -BeGreaterThan $screen.IndexOf('Third App')
        $screen | Should -Not -Match 'Other App'
        $screen | Should -Not -Match 'Second Feature'
        $screen | Should -Not -Match 'Unlisted'
    }

    It "Shows no menu and changes nothing when there is nothing to offer" {
        $result = Invoke-Features
        $result.Exit | Should -Be 0
        Should -Invoke Read-FeaturesMenuKey -Times 0
        Should -Invoke Read-Host -Times 0
        $script:Calls.Count | Should -Be 0
    }

    It "Cancels with <Name> without a prompt, a change or a log line" -ForEach @(
        @{ Name = 'Escape'; Key = { Get-KeyEscape } }
        @{ Name = 'Q'; Key = { Get-KeyQ } }
    ) {
        Set-AllInstalled
        $null = Invoke-Features -Keys @((Get-KeySpace), (& $Key))
        Should -Invoke Read-Host -Times 0
        $script:Calls.Count | Should -Be 0
        Test-Path -LiteralPath $script:LogFile | Should -BeFalse
    }

    It "Stops without a prompt or a change when nothing is selected" {
        Set-AllInstalled
        $result = Invoke-Features -Keys @((Get-KeyEnter))
        $result.Exit | Should -Be 0
        Should -Invoke Read-Host -Times 0
        $script:Calls.Count | Should -Be 0
        Test-Path -LiteralPath $script:LogFile | Should -BeFalse
    }

    It "Asks y/N after the selection and shows what is selected, with its warning" {
        Set-AllInstalled
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0, 3 -Rows 5) -Answer 'n'
        Should -Invoke Read-Host -Times 1 -Exactly
        $script:Prompts[0] | Should -Match '\(y/N\)'
        $script:ConfirmScreen | Should -Match 'Example App'
        $script:ConfirmScreen | Should -Match 'Legacy Feature'
        $script:ConfirmScreen | Should -Match 'Sign-in may need this\.'
    }

    It "Does not list unselected entries on the confirmation screen" {
        Set-AllInstalled
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 1 -Rows 5) -Answer 'n'
        $script:ConfirmScreen | Should -Match 'Other App'
        $script:ConfirmScreen | Should -Not -Match 'Third App'
        $script:ConfirmScreen | Should -Not -Match 'Example App'
        $script:ConfirmScreen | Should -Not -Match 'Legacy Feature'
    }

    It "Takes <Answer> as no: nothing is removed and nothing is logged" -ForEach @(
        @{ Answer = '' }, @{ Answer = 'n' }, @{ Answer = 'N' }, @{ Answer = 'no' }, @{ Answer = 'x' }
    ) {
        Set-AllInstalled
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0, 3 -Rows 5) -Answer $Answer
        $script:Calls.Count | Should -Be 0
        Test-Path -LiteralPath $script:LogFile | Should -BeFalse
    }

    It "Removes only the selected app and feature after <Answer>" -ForEach @(
        @{ Answer = 'y' }, @{ Answer = 'Y' }
    ) {
        Set-AllInstalled
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0, 3 -Rows 5) -Answer $Answer
        @($script:Calls) | Should -Be @('Remove-AppxPackage Contoso.Example_2.5.0.0_x64__examplepublisher', 'Disable-WindowsOptionalFeature Contoso-Legacy')
    }

    It "Removes an app for the current user only, by exact full name" {
        Set-AllInstalled
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 1 -Rows 5)
        Should -Invoke Remove-AppxPackage -Times 1 -Exactly -ParameterFilter { $Package -eq 'Contoso.Other_2.5.0.0_x64__examplepublisher' -and -not $AllUsers }
        Should -Invoke Remove-AppxProvisionedPackage -Times 0
    }

    It "Disables a feature with -Online -NoRestart and never with -Remove" {
        Set-AllInstalled
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 3 -Rows 5)
        Should -Invoke Disable-WindowsOptionalFeature -Times 1 -Exactly -ParameterFilter { $FeatureName -eq 'Contoso-Legacy' -and $Online -and $NoRestart -and -not $Remove }
    }

    It "Never touches Enable-WindowsOptionalFeature, Restart-Computer or Start-Process" {
        Set-AllInstalled
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0, 1, 2, 3, 4 -Rows 5)
        Should -Invoke Enable-WindowsOptionalFeature -Times 0
        Should -Invoke Restart-Computer -Times 0
        Should -Invoke Start-Process -Times 0
    }

    It "Leaves the provisioned package alone without --all-users-future, even if there is one" {
        Set-AllInstalled
        $script:Provisioned = @([pscustomobject]@{ DisplayName = 'Contoso.Example'; PackageName = 'Contoso.Example_2.5.0.0_neutral_~_examplepublisher' })
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0 -Rows 5)
        Should -Invoke Remove-AppxPackage -Times 1 -Exactly
        Should -Invoke Remove-AppxProvisionedPackage -Times 0
    }
}

Describe "sw features --all-users-future" {
    BeforeEach { Initialize-FeatureEnvironment }
    AfterEach { Restore-FeatureEnvironment }

    It "Also removes the provisioned package of a provisioned app, user package first" {
        Set-AllInstalled
        $script:Provisioned = @([pscustomobject]@{ DisplayName = 'Contoso.Example'; PackageName = 'Contoso.Example_2.5.0.0_neutral_~_examplepublisher' })
        $null = Invoke-Features -Params @{ AllUsersFuture = $true } -Keys (New-SelectionKeys -Select 0, 1 -Rows 5)
        @($script:Calls) | Should -Be @(
            'Remove-AppxPackage Contoso.Example_2.5.0.0_x64__examplepublisher'
            'Remove-AppxProvisionedPackage Contoso.Example_2.5.0.0_neutral_~_examplepublisher'
            'Remove-AppxPackage Contoso.Other_2.5.0.0_x64__examplepublisher'
        )
        Should -Invoke Remove-AppxProvisionedPackage -Times 1 -Exactly -ParameterFilter { $Online -and $PackageName -eq 'Contoso.Example_2.5.0.0_neutral_~_examplepublisher' }
    }

    It "Logs one REMOVED line per step: the user package and the provisioned package" {
        Set-AllInstalled
        $script:Provisioned = @([pscustomobject]@{ DisplayName = 'Contoso.Example'; PackageName = 'Contoso.Example_2.5.0.0_neutral_~_examplepublisher' })
        $null = Invoke-Features -Params @{ AllUsersFuture = $true } -Keys (New-SelectionKeys -Select 0 -Rows 5)
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 2
        $records[0] | Should -Match 'REMOVED appx:Contoso\.Example_2\.5\.0\.0_x64__examplepublisher \(.*Remove-AppxPackage -Package Contoso\.Example_2\.5\.0\.0_x64__examplepublisher'
        $records[1] | Should -Match 'REMOVED appx-provisioned:Contoso\.Example_2\.5\.0\.0_neutral_~_examplepublisher \(.*Remove-AppxProvisionedPackage -Online -PackageName Contoso\.Example_2\.5\.0\.0_neutral_~_examplepublisher'
    }

    It "Logs the partial success: REMOVED for the user package, FAILED for the provisioned step with command and error" {
        Set-AllInstalled
        $script:Provisioned = @([pscustomobject]@{ DisplayName = 'Contoso.Example'; PackageName = 'Contoso.Example_2.5.0.0_neutral_~_examplepublisher' })
        $script:OnProvisionedRemove = { throw 'provisioned boom' }
        $null = Invoke-Features -Params @{ AllUsersFuture = $true } -Keys (New-SelectionKeys -Select 0 -Rows 5)
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 2
        $records[0] | Should -Match 'REMOVED appx:Contoso\.Example_2\.5\.0\.0_x64__examplepublisher \('
        $records[1] | Should -Match 'FAILED appx-provisioned:Contoso\.Example_2\.5\.0\.0_neutral_~_examplepublisher \(.*Remove-AppxProvisionedPackage -Online -PackageName Contoso\.Example_2\.5\.0\.0_neutral_~_examplepublisher.*provisioned boom'
    }

    It "Does not try the provisioned step when the user package fails, and logs one FAILED line" {
        Set-AllInstalled
        $script:Provisioned = @([pscustomobject]@{ DisplayName = 'Contoso.Example'; PackageName = 'Contoso.Example_2.5.0.0_neutral_~_examplepublisher' })
        $script:OnAppRemove = { throw 'user boom' }
        $null = Invoke-Features -Params @{ AllUsersFuture = $true } -Keys (New-SelectionKeys -Select 0 -Rows 5)
        Should -Invoke Remove-AppxProvisionedPackage -Times 0
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 1
        $records[0] | Should -Match 'FAILED appx:Contoso\.Example_2\.5\.0\.0_x64__examplepublisher \(.*user boom'
    }

    It "Skips the app, with no Remove-* call, when the administrator rights are gone after the menu" {
        Set-AllInstalled
        $script:Provisioned = @([pscustomobject]@{ DisplayName = 'Contoso.Example'; PackageName = 'Contoso.Example_2.5.0.0_neutral_~_examplepublisher' })
        $script:OnPrompt = { $script:IsAdmin = $false }
        $null = Invoke-Features -Params @{ AllUsersFuture = $true } -Keys (New-SelectionKeys -Select 0 -Rows 5)
        Should -Invoke Remove-AppxPackage -Times 0
        Should -Invoke Remove-AppxProvisionedPackage -Times 0
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 1
        $records[0] | Should -Match 'SKIPPED appx:Contoso\.Example_2\.5\.0\.0_x64__examplepublisher \((?!-\)).+\)'
    }

    It "Skips the provisioned step for an app that is not provisioned" {
        Set-AllInstalled
        $null = Invoke-Features -Params @{ AllUsersFuture = $true } -Keys (New-SelectionKeys -Select 1 -Rows 5)
        Should -Invoke Remove-AppxPackage -Times 1 -Exactly
        Should -Invoke Remove-AppxProvisionedPackage -Times 0
    }

    It "Leaves features alone: they are disabled as without the option" {
        Set-AllInstalled
        $null = Invoke-Features -Params @{ AllUsersFuture = $true } -Keys (New-SelectionKeys -Select 3 -Rows 5)
        Should -Invoke Disable-WindowsOptionalFeature -Times 1 -Exactly -ParameterFilter { $FeatureName -eq 'Contoso-Legacy' -and $NoRestart }
        Should -Invoke Remove-AppxProvisionedPackage -Times 0
    }
}

Describe "sw features administrator rules (E19)" {
    BeforeEach { Initialize-FeatureEnvironment }
    AfterEach { Restore-FeatureEnvironment }

    It "Aborts --all-users-future without admin before reading, asking or changing anything" {
        Set-AllInstalled
        $script:IsAdmin = $false
        $result = Invoke-Features -Params @{ AllUsersFuture = $true } -Keys (New-SelectionKeys -Select 0 -Rows 5)
        $result.Exit | Should -Be 1
        $result.Text | Should -Match 'Run Sweepr in an administrator PowerShell for .*--all-users-future'
        Should -Invoke Read-FeaturesMenuKey -Times 0
        Should -Invoke Read-Host -Times 0
        Should -Invoke Get-AppxPackage -Times 0
        $script:Calls.Count | Should -Be 0
        Test-Path -LiteralPath $script:LogFile | Should -BeFalse
    }

    It "Never starts a process or elevates itself when the rights are missing" {
        Set-AllInstalled
        $script:IsAdmin = $false
        $null = Invoke-Features -Params @{ AllUsersFuture = $true }
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0 -Rows 3)
        Should -Invoke Start-Process -Times 0
    }

    It "Does not offer optional features without admin and says why" {
        Set-AllInstalled
        $script:IsAdmin = $false
        $result = Invoke-Features -Keys @((Get-KeyEscape))
        $script:FirstScreen | Should -Match 'Example App'
        $script:FirstScreen | Should -Not -Match 'Legacy Feature'
        $script:FirstScreen | Should -Not -Match 'Second Feature'
        $result.Text | Should -Match 'Run Sweepr in an administrator PowerShell for optional Windows features'
    }

    It "Keeps the administrator notice at the head of every menu screen, after each Clear-Host" {
        Set-AllInstalled
        $script:IsAdmin = $false
        $null = Invoke-Features -Keys @((Get-KeyDown), (Get-KeyDown), (Get-KeyEscape))
        $script:Screens.Count | Should -Be 3
        foreach ($screen in $script:Screens) {
            $screen.Text | Should -Match 'Run Sweepr in an administrator PowerShell for optional Windows features'
        }
    }

    It "Still keeps every screen within the window height with the notice" {
        Set-AllInstalled
        $script:IsAdmin = $false
        $script:WindowHeight = 12
        $null = Invoke-Features -Keys @((Get-KeyDown), (Get-KeyEscape))
        foreach ($screen in $script:Screens) { $screen.Lines | Should -BeLessOrEqual 12 }
    }

    It "Shows no administrator notice on the menu screens with admin rights" {
        Set-AllInstalled
        $null = Invoke-Features -Keys @((Get-KeyDown), (Get-KeyEscape))
        foreach ($screen in $script:Screens) { $screen.Text | Should -Not -Match 'administrator PowerShell' }
    }

    It "Removes an app of the current user without admin and touches no feature" {
        Set-AllInstalled
        $script:IsAdmin = $false
        $result = Invoke-Features -Keys (New-SelectionKeys -Select 0 -Rows 3)
        $result.Exit | Should -Be 0
        Should -Invoke Remove-AppxPackage -Times 1 -Exactly -ParameterFilter { $Package -eq 'Contoso.Example_2.5.0.0_x64__examplepublisher' }
        Should -Invoke Disable-WindowsOptionalFeature -Times 0
        @(Get-LogRecords)[0] | Should -Match 'REMOVED appx:'
    }

    It "Offers the features with admin and does not print the administrator hint" {
        Set-AllInstalled
        $result = Invoke-Features -Keys @((Get-KeyEscape))
        $script:FirstScreen | Should -Match 'Legacy Feature'
        $result.Text | Should -Not -Match 'Run Sweepr in an administrator PowerShell'
    }

    It "Does not disable a feature when the admin rights are gone before it is removed" {
        Set-AllInstalled
        $script:OnPrompt = { $script:IsAdmin = $false }
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 3 -Rows 5)
        Should -Invoke Disable-WindowsOptionalFeature -Times 0
        @(Get-LogRecords)[0] | Should -Match 'SKIPPED feature:Contoso-Legacy \((?!-\)).+\)'
    }

    It "Still previews --all-users-future without admin (E19: preview always)" {
        Set-AllInstalled
        $script:IsAdmin = $false
        $script:ThrowOnChange = $true
        $result = Invoke-Features -Params @{ AllUsersFuture = $true; DryRun = $true } -Keys (New-SelectionKeys -Select 0 -Rows 3)
        $result.Exit | Should -Be 0
        $result.Text | Should -Match 'Remove-AppxPackage -Package Contoso\.Example_2\.5\.0\.0_x64__examplepublisher'
        $result.Text | Should -Match '(?i)administrator'
        $script:Calls.Count | Should -Be 0
    }
}

Describe "sw features dry run" {
    BeforeEach { Initialize-FeatureEnvironment -ThrowOnChange }
    AfterEach { Restore-FeatureEnvironment }

    It "Previews the exact command of every selected entry and calls no changing cmdlet" {
        Set-AllInstalled
        $result = Invoke-Features -Params @{ DryRun = $true } -Keys (New-SelectionKeys -Select 0, 3 -Rows 5)
        $result.Text | Should -Match '(?i)dry.?run'
        $result.Text | Should -Match 'Remove-AppxPackage -Package Contoso\.Example_2\.5\.0\.0_x64__examplepublisher'
        $result.Text | Should -Match 'Disable-WindowsOptionalFeature -Online -FeatureName Contoso-Legacy -NoRestart'
        Should -Invoke Remove-AppxPackage -Times 0
        Should -Invoke Remove-AppxProvisionedPackage -Times 0
        Should -Invoke Disable-WindowsOptionalFeature -Times 0
        Should -Invoke Enable-WindowsOptionalFeature -Times 0
        Should -Invoke Restart-Computer -Times 0
        Should -Invoke Start-Process -Times 0
    }

    It "Does not preview entries that were not selected" {
        Set-AllInstalled
        $result = Invoke-Features -Params @{ DryRun = $true } -Keys (New-SelectionKeys -Select 1 -Rows 5)
        $result.Text | Should -Match 'Contoso\.Other_2\.5\.0\.0_x64__examplepublisher'
        $result.Text | Should -Not -Match 'Contoso\.Third_'
        $result.Text | Should -Not -Match 'Contoso-Legacy'
        $result.Text | Should -Not -Match 'Contoso\.Example_'
    }

    It "Shows the provisioned removal in the command with --all-users-future" {
        Set-AllInstalled
        $script:Provisioned = @([pscustomobject]@{ DisplayName = 'Contoso.Example'; PackageName = 'Contoso.Example_2.5.0.0_neutral_~_examplepublisher' })
        $result = Invoke-Features -Params @{ DryRun = $true; AllUsersFuture = $true } -Keys (New-SelectionKeys -Select 0 -Rows 5)
        $result.Text | Should -Match 'Remove-AppxPackage -Package Contoso\.Example_2\.5\.0\.0_x64__examplepublisher; Remove-AppxProvisionedPackage -Online -PackageName Contoso\.Example_2\.5\.0\.0_neutral_~_examplepublisher'
        Should -Invoke Remove-AppxProvisionedPackage -Times 0
    }

    It "Writes no operations.log line and creates no restore record" {
        Set-AllInstalled
        $null = Invoke-Features -Params @{ DryRun = $true } -Keys (New-SelectionKeys -Select 0, 1, 2, 3, 4 -Rows 5)
        Test-Path -LiteralPath $script:LogFile | Should -BeFalse
        @(Get-ChildItem -LiteralPath $TestDrive -Recurse -Force -Filter 'features-removed.json').Count | Should -Be 0
    }

    It "Leaves the dry-run mode on while it runs" {
        Set-AllInstalled
        $null = Invoke-Features -Params @{ DryRun = $true } -Keys @((Get-KeyEscape))
        Test-DryRunMode | Should -BeTrue
    }

    It "Previews instead of removing when the dry-run mode is already on (SWEEPR_DRY_RUN)" {
        Set-AllInstalled
        Set-DryRunMode -Enabled $true
        $result = Invoke-Features -Keys (New-SelectionKeys -Select 0, 3 -Rows 5)
        $result.Text | Should -Match 'Remove-AppxPackage -Package Contoso\.Example_2\.5\.0\.0_x64__examplepublisher'
        $script:Calls.Count | Should -Be 0
        Test-Path -LiteralPath $script:LogFile | Should -BeFalse
    }

    It "Changes nothing when the selection is cancelled or empty" {
        Set-AllInstalled
        $null = Invoke-Features -Params @{ DryRun = $true } -Keys @((Get-KeyEscape))
        $null = Invoke-Features -Params @{ DryRun = $true } -Keys @((Get-KeyEnter))
        $script:Calls.Count | Should -Be 0
        Test-Path -LiteralPath $script:LogFile | Should -BeFalse
    }

    It "Offers the same entries as a real run: no features without admin" {
        Set-AllInstalled
        $script:IsAdmin = $false
        $result = Invoke-Features -Params @{ DryRun = $true } -Keys @((Get-KeyEscape))
        $script:FirstScreen | Should -Not -Match 'Legacy Feature'
        $result.Text | Should -Match 'Run Sweepr in an administrator PowerShell for optional Windows features'
    }
}

Describe "sw features check right before the removal" {
    BeforeEach { Initialize-FeatureEnvironment }
    AfterEach { Restore-FeatureEnvironment }

    It "Skips an app that is gone after the prompt and goes on with the rest" {
        Set-AllInstalled
        $script:OnPrompt = { $script:Packages.Remove('Contoso.Other') }
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0, 1, 2 -Rows 5)
        @($script:Calls) | Should -Be @('Remove-AppxPackage Contoso.Example_2.5.0.0_x64__examplepublisher', 'Remove-AppxPackage Contoso.Third_2.5.0.0_x64__examplepublisher')
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 3
        $records[1] | Should -Match 'SKIPPED appx:Contoso\.Other_2\.5\.0\.0_x64__examplepublisher \((?!-\)).+\)'
    }

    It "Skips an app that was updated meanwhile: the reviewed full name is not the installed one" {
        Set-AllInstalled
        $script:OnPrompt = { $script:Packages['Contoso.Example'] = New-AppPackage -Name 'Contoso.Example' -Version '2.6.0.0' }
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0 -Rows 5)
        $script:Calls.Count | Should -Be 0
        @(Get-LogRecords)[0] | Should -Match 'SKIPPED appx:Contoso\.Example_2\.5\.0\.0_x64__examplepublisher '
    }

    It "Skips an app that turned protected meanwhile" {
        Set-AllInstalled
        $script:OnPrompt = { $script:Packages['Contoso.Example'] = New-AppPackage -Name 'Contoso.Example' -SignatureKind 'System' }
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0 -Rows 5)
        $script:Calls.Count | Should -Be 0
        @(Get-LogRecords)[0] | Should -Match 'SKIPPED appx:'
    }

    It "Skips a feature that is no longer enabled" {
        Set-AllInstalled
        $script:OnPrompt = { $script:Features['Contoso-Legacy'] = [pscustomobject]@{ FeatureName = 'Contoso-Legacy'; State = 'Disabled' } }
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 3 -Rows 5)
        Should -Invoke Disable-WindowsOptionalFeature -Times 0
        @(Get-LogRecords)[0] | Should -Match 'SKIPPED feature:Contoso-Legacy \((?!-\)).+\)'
    }

    It "Skips an entry that is no longer in the catalog" {
        Set-AllInstalled
        $script:OnPrompt = { $script:Catalog = @($script:Catalog | Where-Object { $_.Id -ne 'app.other' -and $_.Id -ne 'feature.legacy' }) }
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 1, 3 -Rows 5)
        $script:Calls.Count | Should -Be 0
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 2
        $records[0] | Should -Match 'SKIPPED appx:Contoso\.Other_'
        $records[1] | Should -Match 'SKIPPED feature:Contoso-Legacy'
    }

    It "Re-reads only the one catalog entry of each selected row, after the prompt" {
        Set-AllInstalled
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0, 3 -Rows 5)
        $calls = @($script:InventoryCalls)
        $prompt = $calls.IndexOf('PROMPT')
        $prompt | Should -BeGreaterThan 0
        $calls[0] | Should -Be '-1:'
        @($calls | Select-Object -Skip ($prompt + 1)) | Should -Be @('1:app.example', '1:feature.legacy')
    }

    It "Checks each entry right before its own removal, not once for the whole batch" {
        Set-AllInstalled
        $script:OnAppRemove = { param($Package) if ($Package -like 'Contoso.Example_*') { $script:Packages.Remove('Contoso.Other') } }
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0, 1 -Rows 5)
        @($script:Calls) | Should -Be @('Remove-AppxPackage Contoso.Example_2.5.0.0_x64__examplepublisher')
        $records = @(Get-LogRecords)
        $records[0] | Should -Match 'REMOVED appx:Contoso\.Example_'
        $records[1] | Should -Match 'SKIPPED appx:Contoso\.Other_'
    }
}

Describe "sw features restart notice" {
    BeforeEach { Initialize-FeatureEnvironment }
    AfterEach { Restore-FeatureEnvironment }

    It "Says Restart Windows to finish. after a feature reports RestartNeeded, and restarts nothing" {
        Set-AllInstalled
        $script:DisableResult = [pscustomobject]@{ RestartNeeded = $true }
        $result = Invoke-Features -Keys (New-SelectionKeys -Select 3 -Rows 5)
        $result.Text | Should -Match 'Restart Windows to finish\.'
        $lines = @($script:Transcript)
        $disabled = [array]::FindIndex($lines, [Predicate[string]] { param($l) $l -like 'CALL:Disable-WindowsOptionalFeature*' })
        $notice = [array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match 'Restart Windows to finish\.' })
        $notice | Should -BeGreaterThan $disabled
        Should -Invoke Restart-Computer -Times 0
    }

    It "Says it once even when several features need a restart" {
        Set-AllInstalled
        $script:DisableResult = [pscustomobject]@{ RestartNeeded = $true }
        $result = Invoke-Features -Keys (New-SelectionKeys -Select 3, 4 -Rows 5)
        ([regex]::Matches($result.Text, 'Restart Windows to finish\.')).Count | Should -Be 1
    }

    It "Stays silent when no result needs a restart" {
        Set-AllInstalled
        $result = Invoke-Features -Keys (New-SelectionKeys -Select 0, 3 -Rows 5)
        $result.Text | Should -Not -Match 'Restart Windows'
    }

    It "Stays silent after apps only" {
        Set-AllInstalled
        $result = Invoke-Features -Keys (New-SelectionKeys -Select 0, 1 -Rows 5)
        $result.Text | Should -Not -Match 'Restart Windows'
    }

    It "Treats a result without a RestartNeeded property as no restart" {
        Set-AllInstalled
        $script:DisableResult = $null
        $result = Invoke-Features -Keys (New-SelectionKeys -Select 3 -Rows 5)
        $result.Text | Should -Not -Match 'Restart Windows'
        @(Get-LogRecords)[0] | Should -Match 'DISABLED feature:Contoso-Legacy'
    }

    It "Does not announce a restart for a feature that failed" {
        Set-AllInstalled
        $script:DisableResult = [pscustomobject]@{ RestartNeeded = $true }
        $script:OnFeatureDisable = { throw 'disable boom' }
        $result = Invoke-Features -Keys (New-SelectionKeys -Select 3 -Rows 5)
        $result.Text | Should -Not -Match 'Restart Windows'
    }
}

Describe "sw features operations log" {
    BeforeEach { Initialize-FeatureEnvironment }
    AfterEach { Restore-FeatureEnvironment }

    It "Logs REMOVED for an app as appx: plus the full name, with the command" {
        Set-AllInstalled
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0 -Rows 5)
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 1
        $records[0] | Should -Match '\[features run=testrun\] REMOVED appx:Contoso\.Example_2\.5\.0\.0_x64__examplepublisher \(.*Remove-AppxPackage -Package Contoso\.Example_2\.5\.0\.0_x64__examplepublisher\)$'
    }

    It "Logs DISABLED for a feature as feature: plus the name, with the command" {
        Set-AllInstalled
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 3 -Rows 5)
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 1
        $records[0] | Should -Match 'DISABLED feature:Contoso-Legacy \(.*Disable-WindowsOptionalFeature -Online -FeatureName Contoso-Legacy -NoRestart\)$'
        $records[0] | Should -Not -Match 'restart needed'
    }

    It "Adds restart needed to the DISABLED detail when the result says so" {
        Set-AllInstalled
        $script:DisableResult = [pscustomobject]@{ RestartNeeded = $true }
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 3 -Rows 5)
        @(Get-LogRecords)[0] | Should -Match 'DISABLED feature:Contoso-Legacy \(.*restart needed.*\)$'
    }

    It "Logs FAILED with the error text for an app and for a feature, and goes on" {
        Set-AllInstalled
        $script:OnAppRemove = { throw 'app boom' }
        $script:OnFeatureDisable = { throw 'feature boom' }
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0, 1, 3 -Rows 5)
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 3
        $records[0] | Should -Match 'FAILED appx:Contoso\.Example_2\.5\.0\.0_x64__examplepublisher \(.*app boom.*\)$'
        $records[1] | Should -Match 'FAILED appx:Contoso\.Other_2\.5\.0\.0_x64__examplepublisher \(.*app boom.*\)$'
        $records[2] | Should -Match 'FAILED feature:Contoso-Legacy \(.*feature boom.*\)$'
        $script:Calls.Count | Should -Be 3
    }

    It "Never logs a REMOVED or DISABLED line for something that failed" {
        Set-AllInstalled
        $script:OnAppRemove = { throw 'app boom' }
        $script:OnFeatureDisable = { throw 'feature boom' }
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0, 3 -Rows 5)
        @(Get-LogRecords | Where-Object { $_ -match '\] (REMOVED|DISABLED) ' }).Count | Should -Be 0
    }

    It "Logs all four outcomes of one run in selection order" {
        Set-AllInstalled
        $script:OnAppRemove = { param($Package) if ($Package -like 'Contoso.Other_*') { throw 'app boom' } }
        $script:OnPrompt = { $script:Packages.Remove('Contoso.Third') }
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0, 1, 2, 3 -Rows 5)
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 4
        $records[0] | Should -Match '\] REMOVED appx:Contoso\.Example_'
        $records[1] | Should -Match '\] FAILED appx:Contoso\.Other_'
        $records[2] | Should -Match '\] SKIPPED appx:Contoso\.Third_'
        $records[3] | Should -Match '\] DISABLED feature:Contoso-Legacy'
    }

    It "Records the run under the features command so sw history groups it" {
        Set-AllInstalled
        $script:OnAppRemove = { param($Package) if ($Package -like 'Contoso.Other_*') { throw 'app boom' } }
        $script:OnPrompt = { $script:Packages.Remove('Contoso.Third') }
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0, 1, 2, 3 -Rows 5)
        $history = Read-SweeprHistory -Path $script:LogFile
        @($history.Sessions).Count | Should -Be 1
        $session = $history.Sessions[0]
        $session.command | Should -Be 'features'
        $session.actions.removed | Should -Be 1
        $session.actions.failed | Should -Be 1
        $session.actions.skipped | Should -Be 1
        $session.actions.disabled | Should -Be 1
        $session.actions.other | Should -Be 0
        @($history.Operations | ForEach-Object { $_.path }) | Should -Be @(
            'appx:Contoso.Example_2.5.0.0_x64__examplepublisher'
            'appx:Contoso.Other_2.5.0.0_x64__examplepublisher'
            'appx:Contoso.Third_2.5.0.0_x64__examplepublisher'
            'feature:Contoso-Legacy'
        )
    }

    It "Writes nothing when SWEEPR_NO_OPLOG=1" {
        Set-AllInstalled
        $env:SWEEPR_NO_OPLOG = '1'
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0 -Rows 5)
        Should -Invoke Remove-AppxPackage -Times 1 -Exactly
        Test-Path -LiteralPath $script:LogFile | Should -BeFalse
    }
}

Describe "sw history counts the features actions" {
    BeforeAll {
        function script:Write-HistoryFixture([string[]]$Lines) {
            $path = Join-Path (Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))) "operations.log"
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            [System.IO.File]::WriteAllLines($path, $Lines)
            return $path
        }
        $script:FeatureLogLines = @(
            "",
            "# ========== features run=f1 session started at 2026-10-25 10:00:00 ==========",
            "[2026-10-25 10:00:01] [features run=f1] REMOVED appx:Contoso.Example_2.5.0.0_x64__examplepublisher (Remove-AppxPackage -Package Contoso.Example_2.5.0.0_x64__examplepublisher)",
            "[2026-10-25 10:00:02] [features run=f1] DISABLED feature:Contoso-Legacy (Disable-WindowsOptionalFeature -Online -FeatureName Contoso-Legacy -NoRestart; restart needed)",
            "[2026-10-25 10:00:03] [features run=f1] FAILED appx:Contoso.Other_2.5.0.0_x64__examplepublisher (Access is denied)",
            "[2026-10-25 10:00:04] [features run=f1] SKIPPED feature:Contoso-Second (no longer enabled)"
        )
    }

    It "Counts REMOVED, DISABLED, FAILED and SKIPPED of a features session, nothing under other" {
        $history = Read-SweeprHistory -Path (Write-HistoryFixture $script:FeatureLogLines)
        @($history.Sessions).Count | Should -Be 1
        $actions = $history.Sessions[0].actions
        $history.Sessions[0].command | Should -Be 'features'
        $actions.removed | Should -Be 1
        $actions.disabled | Should -Be 1
        $actions.failed | Should -Be 1
        $actions.skipped | Should -Be 1
        $actions.other | Should -Be 0
        $history.Sessions[0].operation_count | Should -Be 4
    }

    It "Keeps the appx: and feature: identifiers as paths" {
        $history = Read-SweeprHistory -Path (Write-HistoryFixture $script:FeatureLogLines)
        $history.Operations[0].path | Should -BeExactly 'appx:Contoso.Example_2.5.0.0_x64__examplepublisher'
        $history.Operations[1].path | Should -BeExactly 'feature:Contoso-Legacy'
        $history.Operations[1].action | Should -Be 'disabled'
        $history.Operations[1].detail | Should -Match 'restart needed'
    }

    It "Shows disabled in the text summary and in the JSON" {
        $path = Write-HistoryFixture $script:FeatureLogLines
        $history = Read-SweeprHistory -Path $path
        Format-SweeprHistoryActions $history.Sessions[0].actions | Should -Match 'disabled 1'
        $json = ConvertTo-SweeprHistoryJson -History $history -Limit 20 -LogPath $path | ConvertFrom-Json
        $json.sessions[0].actions.disabled | Should -Be 1
        $json.sessions[0].actions.removed | Should -Be 1
    }

    It "Does not call a session with only a DISABLED line empty" {
        $path = Write-HistoryFixture @("[2026-10-25 10:00:02] [features run=f2] DISABLED feature:Contoso-Legacy (Disable-WindowsOptionalFeature -Online -FeatureName Contoso-Legacy -NoRestart)")
        $history = Read-SweeprHistory -Path $path
        Format-SweeprHistoryActions $history.Sessions[0].actions | Should -Be 'disabled 1'
    }

    It "Counts appx-provisioned: lines like any other path" {
        $path = Write-HistoryFixture @(
            "[2026-10-25 10:00:01] [features run=f3] REMOVED appx:Contoso.Example_2.5.0.0_x64__examplepublisher (Remove-AppxPackage -Package Contoso.Example_2.5.0.0_x64__examplepublisher)",
            "[2026-10-25 10:00:02] [features run=f3] REMOVED appx-provisioned:Contoso.Example_2.5.0.0_neutral_~_examplepublisher (Remove-AppxProvisionedPackage -Online -PackageName Contoso.Example_2.5.0.0_neutral_~_examplepublisher)",
            "[2026-10-25 10:00:03] [features run=f3] FAILED appx-provisioned:Contoso.Other_2.5.0.0_neutral_~_examplepublisher (Remove-AppxProvisionedPackage -Online -PackageName Contoso.Other_2.5.0.0_neutral_~_examplepublisher; boom)"
        )
        $history = Read-SweeprHistory -Path $path
        $history.Sessions[0].actions.removed | Should -Be 2
        $history.Sessions[0].actions.failed | Should -Be 1
        $history.Sessions[0].actions.other | Should -Be 0
        $history.Operations[1].path | Should -BeExactly 'appx-provisioned:Contoso.Example_2.5.0.0_neutral_~_examplepublisher'
    }

    It "Still counts the actions of the other commands as before" {
        $path = Write-HistoryFixture @(
            "[2026-10-25 10:00:01] [clean run=c1] REMOVED C:\Temp\one (1.0KB)",
            "[2026-10-25 10:00:02] [clean run=c1] SKIPPED C:\Temp\two (refused)"
        )
        $actions = (Read-SweeprHistory -Path $path).Sessions[0].actions
        $actions.removed | Should -Be 1
        $actions.skipped | Should -Be 1
        $actions.disabled | Should -Be 0
    }
}

Describe "sw features shipping" {
    It "Lists this test file and the new command file for the installer inventory" {
        $install = Get-Content -LiteralPath $script:InstallFile -Raw
        $install | Should -Match ([regex]::Escape('"tests\FeaturesCommand.Tests.ps1"'))
        $install | Should -Match ([regex]::Escape('"lib\core\features.ps1"'))
    }

    It "Lists bin/features.ps1 for the installer inventory (sw remove removes only listed files)" {
        $install = Get-Content -LiteralPath $script:InstallFile -Raw
        $install | Should -Match ([regex]::Escape('"bin\features.ps1"'))
    }
}
