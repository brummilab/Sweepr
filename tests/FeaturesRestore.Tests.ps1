# Sweepr Windows - sw features --restore tests (F-02c, Design Rev 3 section 16, decisions E18, E19)
#
# Platform neutral: the command functions are lifted out of bin\features.ps1 by AST extraction.
# Every Windows cmdlet and winget is a stub plus a Mock, menu keys and the y/N answer come from
# mockable helpers, the operations log and the restore list go to $TestDrive. Nothing real changes.
#
# Interface fixed by these tests (the implementer builds exactly this):
#
#   bin\features.ps1
#     param block gets  [switch]$Restore  (flag --restore); the script ends with
#       Invoke-FeaturesCommand -DryRun:$DryRun -List:$List -AllUsersFuture:$AllUsersFuture -Restore:$Restore -ShowHelp:$ShowHelp
#     Invoke-FeaturesCommand gets -Restore. Show-FeaturesHelp documents --restore.
#     New mockable helpers (top-level functions):
#       Test-FeaturesWingetAvailable                 -> [bool], true when winget can be run
#       Invoke-FeaturesWinget -Arguments <string[]>  -> [int] exit code; the only place that runs winget
#   sweepr.ps1: --restore resolves to -Restore (no more "Unknown option"), Show-MainHelp lists
#     "sw features --restore".
#   lib\core\history.ps1: RESTORED is counted as its own action `restored` ("restored N" in the text,
#     sessions[].actions.restored in JSON), not under `other`.
#   install.ps1: Get-SweeprInstallNestedFiles lists tests\FeaturesRestore.Tests.ps1; the uninstall keeps
#     features-removed.json next to operations.log (see tests\Install.Tests.ps1).
#
# The restore list (file name features-removed.json):
#   Path: Join-Path $script:Config.ConfigPath 'features-removed.json' (Get-ConfigPath; so Profile,
#   Portable and SWEEPR_DATA_DIR are followed automatically). The folder is created when missing.
#   Content: {"version":1,"items":[ <record>, ... ]}. A record is
#     { Id, Kind ('App'|'OptionalFeature'), Title, Target (Appx full name | feature name),
#       ProvisionedName (only when the provisioned package was removed in the same step, else absent or null),
#       Restore { Type 'Store', StoreId (may be null) | Type 'Enable', Feature }, RemovedAt (ISO 8601) }
#   Restore is copied from the fresh catalog entry (its Restore property). New records are appended.
#   The list is read as: missing file, empty file or {"items":[]} = no records; anything that is not
#   JSON of that shape = unreadable. A file is never deleted (bin\features.ps1 has no Remove-Item): when
#   the last record goes, {"version":1,"items":[]} stays (tests accept a missing file too).
#
# Removal side (sw features, real run), per entry, after the re-check passed and BEFORE the Remove-*/Disable-*
# cmdlet is called: the record is saved (no duplicate for the same Id + Target).
#   - fail-closed: when the list is unreadable or cannot be saved, the entry is NOT touched, FAILED is
#     logged (detail names features-removed.json) and the console shows the same text. The file is never
#     changed in that case (no overwrite, no backup needed: it is left alone). The run goes on with the
#     next entry (which fails the same way); exit code stays 0.
#   - a failing removal (Remove-AppxPackage / Disable-WindowsOptionalFeature throws) takes its record back
#     (nothing was removed). A failing provisioned step after the user package went keeps the record.
#   - SKIPPED entries, dry run, cancel and "n" write no record.
#
# Restore side, sw features --restore (all of it works from the list alone, not from the catalog):
#   Order: help; --all-users-future or --list together with --restore -> error text naming --restore, exit 2,
#   nothing read or changed; read the list (nothing to restore -> message "Nothing to restore", exit 0;
#   unreadable -> error naming features-removed.json, exit 1, file untouched, no menu); no interactive
#   console -> exit 2; records that are invalid (see below) are not offered but stay in the file;
#   without administrator rights OptionalFeature records are not offered and the notice
#   "Run Sweepr in an administrator PowerShell for optional Windows features." is in the head of the menu
#   (all records need admin and none left -> notice, no menu, exit 0).
#   Invalid record: Id/Kind/Target missing, Kind unknown, Target or StoreId with characters outside
#   [A-Za-z0-9._~-], Restore.Type not matching the Kind (Store for App, Enable for OptionalFeature),
#   Restore.Feature different from Target.
#   Menu: Show-FeaturesMenu with the records (file order), one row per record, Title shown, nothing
#   preselected, head says restore (not "remove"). Esc/Q -> "Cancelled", empty selection -> "Nothing
#   selected", both without prompt or change.
#   Commands (exact text, used for the dry-run preview, the log and the call):
#     OptionalFeature: Enable-WindowsOptionalFeature -Online -FeatureName <Name> -NoRestart
#     App with StoreId and winget: winget install --id <StoreId> --source msstore --accept-package-agreements --accept-source-agreements
#         run as Invoke-FeaturesWinget -Arguments @('install','--id',<StoreId>,'--source','msstore','--accept-package-agreements','--accept-source-agreements')
#         exit code 0 = success, anything else (or a throw) = FAILED
#     App without StoreId, or without winget: no command; the text names the "Microsoft Store" and the Title
#   Dry run (-DryRun or Test-DryRunMode): menu, then one line per selected record with the command (or
#   Store hint); no cmdlet, no winget, no log line, the list file byte-identical.
#   Real run: lists the selection, Read-Host prompt containing "(y/N)", only y/Y goes on. Then per record in
#   menu order: RESTORED on success (the record is removed from the list and the file saved right away),
#   FAILED (detail: command + "failed: " + error text or "exit code N"; the record stays), SKIPPED (Store hint
#   or administrator rights gone before an OptionalFeature; the record stays). The administrator check is
#   repeated right before each OptionalFeature. Log paths: appx:<Target>, feature:<Name>. RestartNeeded -eq $true
#   on an Enable result -> detail ends "; restart needed" and, once at the end, "Restart Windows to finish.".
#   No Restart-Computer, no Start-Process.

BeforeAll {
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $script:LibDir = Join-Path $script:WindowsDir "lib"
    $script:BinFile = Join-Path $script:WindowsDir "bin\features.ps1"
    $script:LibFile = Join-Path $script:LibDir "core\features.ps1"
    $script:SweeprFile = Join-Path $script:WindowsDir "sweepr.ps1"
    $script:InstallFile = Join-Path $script:WindowsDir "install.ps1"

    . "$script:LibDir\core\base.ps1"
    . "$script:LibDir\core\log.ps1"
    . "$script:LibDir\core\ui.ps1"
    . "$script:LibDir\core\file_ops.ps1"
    . "$script:LibDir\core\features.ps1"
    . "$script:LibDir\core\history.ps1"

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
    # A direct call of winget (instead of through Invoke-FeaturesWinget) must fail loudly.
    function script:winget { throw 'winget must only be run through Invoke-FeaturesWinget' }

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
    if (-not (Test-Path -Path 'function:Test-FeaturesInteractive')) { function script:Test-FeaturesInteractive { throw 'bin\features.ps1 is missing Test-FeaturesInteractive' } }
    if (-not (Test-Path -Path 'function:Test-FeaturesWingetAvailable')) { function script:Test-FeaturesWingetAvailable { throw 'bin\features.ps1 is missing Test-FeaturesWingetAvailable' } }
    if (-not (Test-Path -Path 'function:Invoke-FeaturesWinget')) { function script:Invoke-FeaturesWinget { param([string[]]$Arguments) throw 'bin\features.ps1 is missing Invoke-FeaturesWinget' } }
    $script:RealInventory = (Get-Command -Name Get-SweeprFeatureInventory -CommandType Function).ScriptBlock
    Import-ScriptFunction -Script $script:SweeprFile -Names @("Resolve-CommandParameterName", "Invoke-SweeprCommand", "Show-MainHelp")

    # ---- fixtures -------------------------------------------------------------------------------

    $script:StoreIdExample = '9NEXAMPLE001'
    $script:StoreIdThird = '9NEXAMPLE003'
    $script:WingetInstallExample = 'winget install --id 9NEXAMPLE001 --source msstore --accept-package-agreements --accept-source-agreements'
    $script:WingetInstallThird = 'winget install --id 9NEXAMPLE003 --source msstore --accept-package-agreements --accept-source-agreements'

    function script:New-CatalogEntry {
        param([string]$Id, [string]$Kind, [string]$Match, [string]$Title, [string]$StoreId = $null)
        $restore = if ($Kind -eq 'App') { @{ Type = 'Store'; StoreId = $StoreId } } else { @{ Type = 'Enable'; Feature = $Match } }
        return @{ Id = $Id; Kind = $Kind; Match = @($Match); Title = $Title; Description = "Example description of $Title."; Warning = $null; Restore = $restore }
    }

    function script:Get-TestCatalog {
        return @(
            (New-CatalogEntry 'app.example' 'App' 'Contoso.Example' 'Example App' $script:StoreIdExample)
            (New-CatalogEntry 'app.other' 'App' 'Contoso.Other' 'Other App')
            (New-CatalogEntry 'app.third' 'App' 'Contoso.Third' 'Third App' $script:StoreIdThird)
            (New-CatalogEntry 'feature.legacy' 'OptionalFeature' 'Contoso-Legacy' 'Legacy Feature')
            (New-CatalogEntry 'feature.second' 'OptionalFeature' 'Contoso-Second' 'Second Feature')
        )
    }

    function script:New-AppPackage {
        param([string]$Name, [string]$Version = '2.5.0.0')
        return [pscustomobject]@{
            Name = $Name; PackageFullName = "${Name}_${Version}_x64__examplepublisher"; SignatureKind = 'Store'
            InstallLocation = 'C:\Program Files\WindowsApps\Example'; IsFramework = $false; IsResourcePackage = $false; IsBundle = $false
        }
    }
    function script:Get-FullName { param([string]$Name, [string]$Version = '2.5.0.0') "${Name}_${Version}_x64__examplepublisher" }

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
    function script:Get-KeyEscape { New-Key -Key Escape -Char ([char]27) }
    function script:Get-KeyQ { New-Key -Key Q -Char 'q' }
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

    # ---- the restore list ---------------------------------------------------------------------

    function script:Get-RemovedFilePath { return (Join-Path $script:Config.ConfigPath 'features-removed.json') }

    function script:New-RemovedRecord {
        param([string]$Id, [string]$Kind, [string]$Target, [string]$Title, [string]$StoreId = $null, [string]$ProvisionedName = $null)
        $restore = if ($Kind -eq 'App') { [ordered]@{ Type = 'Store'; StoreId = $(if ($StoreId) { $StoreId } else { $null }) } } else { [ordered]@{ Type = 'Enable'; Feature = $Target } }
        $record = [ordered]@{ Id = $Id; Kind = $Kind; Title = $Title; Target = $Target; Restore = $restore; RemovedAt = '2026-10-25T10:00:00Z' }
        if ($ProvisionedName) { $record['ProvisionedName'] = $ProvisionedName }
        return [pscustomobject]$record
    }

    # Five records, same order and kinds as the five rows of the removal menu.
    function script:Get-DefaultRecords {
        return @(
            (New-RemovedRecord 'app.example' 'App' (Get-FullName 'Contoso.Example') 'Example App' $script:StoreIdExample)
            (New-RemovedRecord 'app.other' 'App' (Get-FullName 'Contoso.Other') 'Other App')
            (New-RemovedRecord 'app.third' 'App' (Get-FullName 'Contoso.Third') 'Third App' $script:StoreIdThird)
            (New-RemovedRecord 'feature.legacy' 'OptionalFeature' 'Contoso-Legacy' 'Legacy Feature')
            (New-RemovedRecord 'feature.second' 'OptionalFeature' 'Contoso-Second' 'Second Feature')
        )
    }

    function script:Write-RemovedFile {
        param([object[]]$Records = (Get-DefaultRecords))
        $path = Get-RemovedFilePath
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $json = ([ordered]@{ version = 1; items = @($Records) } | ConvertTo-Json -Depth 8)
        [System.IO.File]::WriteAllText($path, $json)
        return $json
    }

    # The records currently in the file; none when the file is missing or empty.
    function script:Read-RemovedItems {
        $path = Get-RemovedFilePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
        $raw = [System.IO.File]::ReadAllText($path)
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $doc = $raw | ConvertFrom-Json
        $prop = $doc.PSObject.Properties['items']
        if (-not $prop -or $null -eq $prop.Value) { return @() }
        return @($prop.Value)
    }
    function script:Get-RemovedIds { return @(Read-RemovedItems | ForEach-Object { [string]$_.Id }) }
    # What the dry run printed after the menu (the menu itself shows the description of the cursor row).
    function script:Get-PreviewText {
        param($Result)
        $index = $Result.Text.LastIndexOf('Dry run')
        if ($index -lt 0) { return '' }
        return $Result.Text.Substring($index)
    }
    function script:Get-FileText { param([string]$Path) return [System.IO.File]::ReadAllText($Path) }

    # ---- environment --------------------------------------------------------------------------

    function script:Initialize-FeatureEnvironment {
        param([switch]$ThrowOnChange)

        $script:Saved = @{
            SystemRoot = $env:SystemRoot; NoOplog = $env:SWEEPR_NO_OPLOG; DryRun = $env:SWEEPR_DRY_RUN
            RunCommand = $env:_SWEEPR_OPLOG_RUN_COMMAND; RunId = $env:_SWEEPR_OPLOG_RUN_ID
            LogFile = $script:SweeprOperationsLogFile; LogStarted = $script:SweeprOperationsLogStarted
            ConfigPath = $script:Config.ConfigPath
        }
        $env:SystemRoot = 'C:\Windows'
        $env:SWEEPR_NO_OPLOG = $null
        $env:SWEEPR_DRY_RUN = $null
        $env:_SWEEPR_OPLOG_RUN_COMMAND = 'features'
        $env:_SWEEPR_OPLOG_RUN_ID = 'testrun'
        $script:ConfigDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
        $script:Config.ConfigPath = $script:ConfigDir
        $script:LogFile = Join-Path $script:ConfigDir 'operations.log'
        $script:SweeprOperationsLogFile = $script:LogFile
        $script:SweeprOperationsLogStarted = $false
        Set-DryRunMode -Enabled $false

        $script:Packages = @{}
        $script:Provisioned = @()
        $script:Features = @{}
        $script:IsAdmin = $true
        $script:WingetAvailable = $true
        $script:WingetExitCode = 0
        $script:ListAsJson = $false
        $script:Interactive = $true
        $script:Answer = 'y'
        $script:KeyQueue = [System.Collections.Queue]::new()
        $script:Transcript = [System.Collections.Generic.List[string]]::new()
        $script:HostBuffer = ''
        $script:Calls = [System.Collections.Generic.List[string]]::new()
        $script:Prompts = [System.Collections.Generic.List[string]]::new()
        $script:FirstScreen = $null
        $script:LinesAtLastKey = 0
        $script:ConfirmScreen = $null
        $script:OnAppRemove = $null
        $script:OnProvisionedRemove = $null
        $script:OnFeatureDisable = $null
        $script:OnFeatureEnable = $null
        $script:OnWinget = $null
        $script:OnPrompt = $null
        $script:DisableResult = [pscustomobject]@{ RestartNeeded = $false }
        $script:EnableResult = [pscustomobject]@{ RestartNeeded = $false }
        $script:ThrowOnChange = [bool]$ThrowOnChange
        $script:FeaturesExitCode = 0

        $script:Catalog = @(Get-TestCatalog)
        Mock Get-SweeprFeatureCatalog { return @($script:Catalog) }
        Mock Test-IsAdmin { return $script:IsAdmin }
        Mock Test-FeaturesListAsJson { return $script:ListAsJson }
        Mock Test-FeaturesInteractive { return $script:Interactive }
        Mock Test-FeaturesWingetAvailable { return $script:WingetAvailable }
        Mock Clear-Host { $script:Transcript.Add('CLEAR') }
        Mock Get-FeaturesWindowHeight { return 40 }
        Mock Write-Host {
            $text = ($Object | ForEach-Object { [string]$_ }) -join ' '
            $script:HostBuffer += $text
            if (-not $NoNewline) {
                $script:Transcript.Add($script:HostBuffer)
                $script:HostBuffer = ''
            }
        }
        Mock Read-FeaturesMenuKey {
            $clear = $script:Transcript.LastIndexOf('CLEAR')
            $since = @($script:Transcript | Select-Object -Skip ($clear + 1) | Where-Object { $_ -cnotmatch '^(READ|CALL):' })
            if ($script:HostBuffer) { $since += $script:HostBuffer }
            if ($null -eq $script:FirstScreen) { $script:FirstScreen = ($since -join "`n") }
            $script:LinesAtLastKey = $script:Transcript.Count
            if ($script:KeyQueue.Count -eq 0) { throw 'Test: menu asked for more keys than the test queued' }
            return $script:KeyQueue.Dequeue()
        }
        Mock Read-Host {
            $script:Prompts.Add([string]$Prompt)
            $script:ConfirmScreen = (@($script:Transcript | Select-Object -Skip $script:LinesAtLastKey | Where-Object { $_ -notmatch '^(READ|CALL|CLEAR):' }) -join "`n")
            if ($script:OnPrompt) { & $script:OnPrompt }
            return $script:Answer
        }

        Mock Get-AppxPackage {
            if ($script:Packages.ContainsKey($Name)) { return $script:Packages[$Name] }
            return $null
        }
        Mock Get-AppxProvisionedPackage { return @($script:Provisioned) }
        Mock Get-WindowsOptionalFeature {
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
            if ($script:ThrowOnChange) { throw 'Disable-WindowsOptionalFeature must not run' }
            if ($script:OnFeatureDisable) { & $script:OnFeatureDisable $FeatureName }
            return $script:DisableResult
        }
        Mock Enable-WindowsOptionalFeature {
            $script:Calls.Add("Enable-WindowsOptionalFeature $FeatureName online=$($Online.IsPresent) norestart=$($NoRestart.IsPresent)")
            if ($script:ThrowOnChange) { throw 'Enable-WindowsOptionalFeature must not run' }
            if ($script:OnFeatureEnable) { & $script:OnFeatureEnable $FeatureName }
            return $script:EnableResult
        }
        Mock Invoke-FeaturesWinget {
            $script:Calls.Add('winget ' + (@($Arguments) -join ' '))
            if ($script:ThrowOnChange) { throw 'winget must not run' }
            if ($script:OnWinget) { & $script:OnWinget $Arguments }
            return $script:WingetExitCode
        }
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
        $script:Config.ConfigPath = $script:Saved.ConfigPath
    }

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

    # Restore run over the five default records; Select = indexes of the rows to check.
    function script:Invoke-Restore {
        param([int[]]$Select = @(), [hashtable]$Params = @{}, [string]$Answer = 'y')
        $all = @{ Restore = $true } + $Params
        return (Invoke-Features -Params $all -Keys (New-SelectionKeys -Select $Select -Rows 5) -Answer $Answer)
    }

    function script:Get-LogRecords {
        if (-not (Test-Path -LiteralPath $script:LogFile)) { return @() }
        return @(Get-Content -LiteralPath $script:LogFile | Where-Object { $_ -match '\] (REMOVED|DISABLED|RESTORED|FAILED|SKIPPED) ' })
    }

    function script:Invoke-SweeprChild {
        param([string[]]$Arguments, $ListContent = $null)
        $profileDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        $dataDir = Join-Path $profileDir 'data'
        if ($null -ne $ListContent) {
            New-Item -ItemType Directory -Path (Join-Path $dataDir 'config') -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $dataDir 'config\features-removed.json'), $ListContent)
        }
        $saved = @{ Profile = $env:USERPROFILE; Data = $env:SWEEPR_DATA_DIR }
        try {
            $env:USERPROFILE = $profileDir
            $env:SWEEPR_DATA_DIR = $dataDir
            $pwshPath = (Get-Process -Id $PID).Path
            $text = & { $ErrorActionPreference = 'Continue'; & $pwshPath -NoProfile -NonInteractive -File $script:SweeprFile @Arguments 2>&1 | Out-String }
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = $text; DataDir = $dataDir }
        }
        finally {
            $env:USERPROFILE = $saved.Profile
            $env:SWEEPR_DATA_DIR = $saved.Data
        }
    }
}

# ================================================================================================
Describe "sw features --restore files, router and help" {
    BeforeEach { Initialize-FeatureEnvironment }
    AfterEach { Restore-FeatureEnvironment }

    It "Declares -Restore as a switch of bin/features.ps1 and keeps the other parameters" {
        $script:FeaturesAst | Should -Not -BeNullOrEmpty
        $declared = @($script:FeaturesAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Restore' })
        $declared.Count | Should -Be 1
        $declared[0].StaticType.Name | Should -Be 'SwitchParameter'
        $names = @($script:FeaturesAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        foreach ($name in @('DryRun', 'DebugMode', 'List', 'AllUsersFuture', 'ShowHelp')) { $names | Should -Contain $name }
    }

    It "Passes -Restore from the script's top level to Invoke-FeaturesCommand" {
        (Get-Content -LiteralPath $script:BinFile -Raw) | Should -Match 'Invoke-FeaturesCommand\s+[^\r\n]*-Restore:\$Restore'
    }

    It "Defines the winget helpers" {
        Test-Path -Path 'function:Test-FeaturesWingetAvailable' | Should -BeTrue
        Test-Path -Path 'function:Invoke-FeaturesWinget' | Should -BeTrue
        $script:FeaturesAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-FeaturesWinget' }, $true) | Should -Not -BeNullOrEmpty
    }

    It "Maps the flag --restore to the parameter Restore" {
        $declared = (Get-Command -Name $script:BinFile -CommandType ExternalScript).Parameters
        Resolve-CommandParameterName -Parameters $declared -Flag 'restore' | Should -Be 'Restore'
    }

    It "Documents --restore in the features help" {
        Show-FeaturesHelp
        $help = $script:Transcript -join "`n"
        $help | Should -Match '--restore'
        foreach ($option in @('--dry-run', '--list', '--all-users-future', '--help')) { $help | Should -Match ([regex]::Escape($option)) }
    }

    It "Lists sw features --restore in the main help" {
        Show-MainHelp
        ($script:Transcript -join "`n") | Should -Match 'sw features --restore'
    }

    It "Accepts --restore through sweepr.ps1: no Unknown option, a corrupt list ends with exit code 1 and names the file" {
        $result = Invoke-SweeprChild -Arguments @('features', '--restore') -ListContent '{ this is not json'
        $result.Text | Should -Not -Match 'Unknown option'
        $result.ExitCode | Should -Be 1
        $result.Text | Should -Match 'features-removed\.json'
        Get-FileText (Join-Path $result.DataDir 'config\features-removed.json') | Should -Be '{ this is not json'
    }

    It "Reads the list from the data folder given by SWEEPR_DATA_DIR: no list means nothing to restore, exit code 0, no file created" {
        $result = Invoke-SweeprChild -Arguments @('features', '--restore')
        $result.ExitCode | Should -Be 0
        $result.Text | Should -Match '(?i)nothing to restore'
        Test-Path -LiteralPath (Join-Path $result.DataDir 'config\features-removed.json') | Should -BeFalse
    }

    It "Prints --restore in the help through sweepr.ps1" {
        $result = Invoke-SweeprChild -Arguments @('features', '--help')
        $result.ExitCode | Should -Be 0
        $result.Text | Should -Match '--restore'
    }

    It "Lists this test file for the installer inventory" {
        (Get-Content -LiteralPath $script:InstallFile -Raw) | Should -Match ([regex]::Escape('"tests\FeaturesRestore.Tests.ps1"'))
    }

    It "Names features-removed.json in install.ps1 so the uninstall can keep it" {
        (Get-Content -LiteralPath $script:InstallFile -Raw) | Should -Match ([regex]::Escape('features-removed.json'))
    }

    It "Builds the list path from the configured data folder, never from the user profile" {
        foreach ($file in @($script:BinFile, $script:LibFile)) {
            $code = (Get-Content -LiteralPath $file -Raw) -replace '(?m)^\s*#.*$', ''
            $code | Should -Not -Match '(?i)USERPROFILE'
            $code | Should -Not -Match '(?i)\.config\\sweepr'
        }
        ((Get-Content -LiteralPath $script:BinFile -Raw) + (Get-Content -LiteralPath $script:LibFile -Raw)) | Should -Match 'features-removed\.json'
    }

    It "Never runs Enable-WindowsOptionalFeature without -NoRestart" {
        $code = ((Get-Content -LiteralPath $script:BinFile -Raw) + (Get-Content -LiteralPath $script:LibFile -Raw)) -replace '(?m)^\s*#.*$', ''
        $lines = @($code -split "`n" | Where-Object { $_ -match 'Enable-WindowsOptionalFeature' })
        $lines.Count | Should -BeGreaterThan 0
        foreach ($line in $lines) { $line | Should -Match '-NoRestart' }
    }
}

# ================================================================================================
Describe "sw features saves a restore record before it removes" {
    BeforeEach { Initialize-FeatureEnvironment }
    AfterEach { Restore-FeatureEnvironment }

    It "Writes one record per removed entry with Id, Kind, Title, Target, Restore and a time" {
        Set-AllInstalled
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0, 1, 3 -Rows 5)
        $items = @(Read-RemovedItems)
        $items.Count | Should -Be 3
        $app = $items[0]
        $app.Id | Should -Be 'app.example'
        $app.Kind | Should -Be 'App'
        $app.Title | Should -Be 'Example App'
        $app.Target | Should -Be (Get-FullName 'Contoso.Example')
        $app.Restore.Type | Should -Be 'Store'
        $app.Restore.StoreId | Should -Be $script:StoreIdExample
        { [datetime]$app.RemovedAt } | Should -Not -Throw
        ([datetime]$app.RemovedAt) | Should -BeGreaterThan ((Get-Date).AddDays(-1))
        ([datetime]$app.RemovedAt) | Should -BeLessThan ((Get-Date).AddDays(1))
        $items[1].Id | Should -Be 'app.other'
        $items[1].Restore.Type | Should -Be 'Store'
        $items[1].Restore.StoreId | Should -BeNullOrEmpty
        $feature = $items[2]
        $feature.Id | Should -Be 'feature.legacy'
        $feature.Kind | Should -Be 'OptionalFeature'
        $feature.Target | Should -Be 'Contoso-Legacy'
        $feature.Restore.Type | Should -Be 'Enable'
        $feature.Restore.Feature | Should -Be 'Contoso-Legacy'
    }

    It "Saves the record before Remove-AppxPackage runs" {
        Set-AllInstalled
        $script:OnAppRemove = { $script:SeenAtRemove = @(Get-RemovedIds) }
        $script:SeenAtRemove = $null
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0 -Rows 5)
        $script:SeenAtRemove | Should -Be @('app.example')
    }

    It "Saves the record before Disable-WindowsOptionalFeature runs" {
        Set-AllInstalled
        $script:OnFeatureDisable = { $script:SeenAtRemove = @(Get-RemovedIds) }
        $script:SeenAtRemove = $null
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 3 -Rows 5)
        $script:SeenAtRemove | Should -Be @('feature.legacy')
    }

    It "Saves each record before its own removal, so the first record is there when the second entry goes" {
        Set-AllInstalled
        $script:Seen = [System.Collections.Generic.List[string]]::new()
        $script:OnAppRemove = { param($Package) $script:Seen.Add(((Get-RemovedIds) -join ',')) }
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0, 1 -Rows 5)
        @($script:Seen) | Should -Be @('app.example', 'app.example,app.other')
    }

    It "Records the provisioned package name when --all-users-future removes it, and only then" {
        Set-AllInstalled
        $script:Provisioned = @([pscustomobject]@{ DisplayName = 'Contoso.Example'; PackageName = 'Contoso.Example_2.5.0.0_neutral_~_examplepublisher' })
        $null = Invoke-Features -Params @{ AllUsersFuture = $true } -Keys (New-SelectionKeys -Select 0 -Rows 5)
        $with = @(Read-RemovedItems)
        $with.Count | Should -Be 1
        $with[0].ProvisionedName | Should -Be 'Contoso.Example_2.5.0.0_neutral_~_examplepublisher'

        Remove-Item -LiteralPath (Get-RemovedFilePath) -Force
        Set-AllInstalled
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0 -Rows 5)
        $without = @(Read-RemovedItems)
        $without.Count | Should -Be 1
        $without[0].PSObject.Properties['ProvisionedName'] | Should -BeNullOrEmpty
    }

    It "Appends to the records that are already there and keeps them as they were" {
        Set-AllInstalled
        $old = New-RemovedRecord 'app.old' 'App' (Get-FullName 'Contoso.Old') 'Old App' '9NEXAMPLE099'
        $null = Write-RemovedFile -Records @($old)
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 1 -Rows 5)
        $items = @(Read-RemovedItems)
        @($items | ForEach-Object Id) | Should -Be @('app.old', 'app.other')
        $items[0].Title | Should -Be 'Old App'
        $items[0].Restore.StoreId | Should -Be '9NEXAMPLE099'
    }

    It "Does not add a second record for the same Id and Target" {
        Set-AllInstalled
        $null = Write-RemovedFile -Records @((New-RemovedRecord 'app.example' 'App' (Get-FullName 'Contoso.Example') 'Example App' $script:StoreIdExample))
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0 -Rows 5)
        @(Get-RemovedIds) | Should -Be @('app.example')
    }

    It "Takes the record back when the removal of the app fails (nothing was removed)" {
        Set-AllInstalled
        $old = New-RemovedRecord 'app.old' 'App' (Get-FullName 'Contoso.Old') 'Old App'
        $null = Write-RemovedFile -Records @($old)
        $script:OnAppRemove = { throw 'app boom' }
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0 -Rows 5)
        @(Get-RemovedIds) | Should -Be @('app.old')
    }

    It "Takes the record back when disabling the feature fails" {
        Set-AllInstalled
        $script:OnFeatureDisable = { throw 'feature boom' }
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 3 -Rows 5)
        @(Get-RemovedIds) | Should -Be @()
    }

    It "Keeps the record when only the provisioned step fails after the user package went" {
        Set-AllInstalled
        $script:Provisioned = @([pscustomobject]@{ DisplayName = 'Contoso.Example'; PackageName = 'Contoso.Example_2.5.0.0_neutral_~_examplepublisher' })
        $script:OnProvisionedRemove = { throw 'provisioned boom' }
        $null = Invoke-Features -Params @{ AllUsersFuture = $true } -Keys (New-SelectionKeys -Select 0 -Rows 5)
        @(Get-RemovedIds) | Should -Be @('app.example')
    }

    It "Writes no record for an entry that is skipped by the re-check" {
        Set-AllInstalled
        $script:OnPrompt = { $script:Packages.Remove('Contoso.Other') }
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0, 1 -Rows 5)
        @(Get-RemovedIds) | Should -Be @('app.example')
    }

    It "Writes no record when the confirmation is answered with <Answer>" -ForEach @(
        @{ Answer = 'n' }, @{ Answer = '' }, @{ Answer = 'no' }
    ) {
        Set-AllInstalled
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0, 3 -Rows 5) -Answer $Answer
        Test-Path -LiteralPath (Get-RemovedFilePath) | Should -BeFalse
        $script:Calls.Count | Should -Be 0
    }

    It "Writes no record when the selection is cancelled" {
        Set-AllInstalled
        $null = Invoke-Features -Keys @((Get-KeyEscape))
        Test-Path -LiteralPath (Get-RemovedFilePath) | Should -BeFalse
    }

    It "Creates the data folder when it does not exist yet (first use in a portable folder)" {
        Set-AllInstalled
        $script:Config.ConfigPath = Join-Path $TestDrive 'fresh\data\config'
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0 -Rows 5)
        Test-Path -LiteralPath (Join-Path $TestDrive 'fresh\data\config\features-removed.json') | Should -BeTrue
        @(Get-RemovedIds) | Should -Be @('app.example')
    }

    It "Treats an empty file as no records and writes a valid list" {
        Set-AllInstalled
        [System.IO.File]::WriteAllText((Get-RemovedFilePath), '')
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0 -Rows 5)
        @(Get-RemovedIds) | Should -Be @('app.example')
        $script:Calls.Count | Should -Be 1
    }

    It "Puts the list into the active data folder: <Shape>" -ForEach @(
        @{ Shape = 'profile'; Dir = 'home\.config\sweepr' }
        @{ Shape = 'portable'; Dir = 'app\data\config' }
        @{ Shape = 'override'; Dir = 'elsewhere\config' }
    ) {
        Set-AllInstalled
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Config.ConfigPath = Join-Path $root $Dir
        $null = Invoke-Features -Keys (New-SelectionKeys -Select 0 -Rows 5)
        Test-Path -LiteralPath (Join-Path $root "$Dir\features-removed.json") | Should -BeTrue
        @(Get-ChildItem -LiteralPath $root -Recurse -Force -Filter 'features-removed.json').Count | Should -Be 1
    }
}

# ================================================================================================
Describe "sw features safety of the restore list on removal (fail-closed)" {
    BeforeEach { Initialize-FeatureEnvironment }
    AfterEach { Restore-FeatureEnvironment }

    It "Removes nothing and logs FAILED naming the file when the list cannot be saved" {
        Set-AllInstalled
        # The data folder is a file, so nothing can be written below it.
        $blocker = Join-Path $TestDrive 'not-a-folder'
        [System.IO.File]::WriteAllText($blocker, 'x')
        $script:Config.ConfigPath = $blocker
        $result = Invoke-Features -Keys (New-SelectionKeys -Select 0, 3 -Rows 5)
        $script:Calls.Count | Should -Be 0
        Should -Invoke Remove-AppxPackage -Times 0
        Should -Invoke Disable-WindowsOptionalFeature -Times 0
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 2
        $records[0] | Should -Match 'FAILED appx:Contoso\.Example_2\.5\.0\.0_x64__examplepublisher \(.*features-removed\.json.*\)$'
        $records[1] | Should -Match 'FAILED feature:Contoso-Legacy \(.*features-removed\.json.*\)$'
        $records | ForEach-Object { $_ | Should -Not -Match '(REMOVED|DISABLED) ' }
        $result.Text | Should -Match 'features-removed\.json'
    }

    It "Removes nothing and leaves the file as it was when it is not valid JSON: <Name>" -ForEach @(
        @{ Name = 'text'; Content = 'this is not json' }
        @{ Name = 'truncated'; Content = '{"version":1,"items":[{"Id":"app.old","Kind":' }
        @{ Name = 'wrong shape'; Content = '{"foo":1}' }
    ) {
        Set-AllInstalled
        [System.IO.File]::WriteAllText((Get-RemovedFilePath), $Content)
        $result = Invoke-Features -Keys (New-SelectionKeys -Select 0, 3 -Rows 5)
        $script:Calls.Count | Should -Be 0
        Get-FileText (Get-RemovedFilePath) | Should -Be $Content
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 2
        foreach ($record in $records) { $record | Should -Match 'FAILED (appx|feature):.*features-removed\.json' }
        $result.Text | Should -Match 'features-removed\.json'
        @(Get-ChildItem -LiteralPath $script:ConfigDir -Force | ForEach-Object Name | Where-Object { $_ -like 'features-removed*' }) | Should -Be @('features-removed.json')
    }

    It "Writes no record and removes nothing in a dry run, and leaves an existing list byte for byte" {
        Set-AllInstalled
        $script:ThrowOnChange = $true
        $before = Write-RemovedFile -Records @((New-RemovedRecord 'app.old' 'App' (Get-FullName 'Contoso.Old') 'Old App'))
        $null = Invoke-Features -Params @{ DryRun = $true } -Keys (New-SelectionKeys -Select 0, 1, 3 -Rows 5)
        Get-FileText (Get-RemovedFilePath) | Should -Be $before
        $script:Calls.Count | Should -Be 0
    }
}

# ================================================================================================
Describe "sw features --restore: nothing to restore, bad list and usage" {
    BeforeEach { Initialize-FeatureEnvironment -ThrowOnChange }
    AfterEach { Restore-FeatureEnvironment }

    It "Says there is nothing to restore when the list is missing: no menu, no change, no file, exit 0" {
        $result = Invoke-Features -Params @{ Restore = $true }
        $result.Text | Should -Match '(?i)nothing to restore'
        $result.Exit | Should -Be 0
        Should -Invoke Read-FeaturesMenuKey -Times 0
        Should -Invoke Read-Host -Times 0
        $script:Calls.Count | Should -Be 0
        Test-Path -LiteralPath (Get-RemovedFilePath) | Should -BeFalse
    }

    It "Says there is nothing to restore for an empty file and for an empty list" -ForEach @(
        @{ Content = '' }, @{ Content = "  `r`n" }, @{ Content = '{"version":1,"items":[]}' }
    ) {
        [System.IO.File]::WriteAllText((Get-RemovedFilePath), $Content)
        $result = Invoke-Features -Params @{ Restore = $true }
        $result.Text | Should -Match '(?i)nothing to restore'
        $result.Exit | Should -Be 0
        Should -Invoke Read-FeaturesMenuKey -Times 0
        Get-FileText (Get-RemovedFilePath) | Should -Be $Content
    }

    It "Reports an unreadable list by name, exits with 1 and leaves the file alone: <Name>" -ForEach @(
        @{ Name = 'text'; Content = 'garbage' }
        @{ Name = 'truncated'; Content = '{"version":1,"items":[' }
        @{ Name = 'wrong shape'; Content = '{"foo":1}' }
        @{ Name = 'a number'; Content = '42' }
    ) {
        [System.IO.File]::WriteAllText((Get-RemovedFilePath), $Content)
        $result = Invoke-Features -Params @{ Restore = $true }
        $result.Text | Should -Match 'features-removed\.json'
        $result.Exit | Should -Be 1
        Should -Invoke Read-FeaturesMenuKey -Times 0
        Should -Invoke Read-Host -Times 0
        $script:Calls.Count | Should -Be 0
        Get-FileText (Get-RemovedFilePath) | Should -Be $Content
    }

    It "Refuses --restore together with --all-users-future: error naming --restore, exit 2, nothing read or changed" {
        $before = Write-RemovedFile
        $result = Invoke-Features -Params @{ Restore = $true; AllUsersFuture = $true }
        $result.Exit | Should -Be 2
        $result.Text | Should -Match '--restore'
        Should -Invoke Read-FeaturesMenuKey -Times 0
        Should -Invoke Read-Host -Times 0
        $script:Calls.Count | Should -Be 0
        Get-FileText (Get-RemovedFilePath) | Should -Be $before
    }

    It "Refuses --restore together with --list: error naming --restore, exit 2" {
        $before = Write-RemovedFile
        $result = Invoke-Features -Params @{ Restore = $true; List = $true }
        $result.Exit | Should -Be 2
        $result.Text | Should -Match '--restore'
        Should -Invoke Read-FeaturesMenuKey -Times 0
        Get-FileText (Get-RemovedFilePath) | Should -Be $before
    }

    It "Needs an interactive console: exit 2 and no change" {
        $before = Write-RemovedFile
        $script:Interactive = $false
        $result = Invoke-Features -Params @{ Restore = $true }
        $result.Exit | Should -Be 2
        Should -Invoke Read-FeaturesMenuKey -Times 0
        $script:Calls.Count | Should -Be 0
        Get-FileText (Get-RemovedFilePath) | Should -Be $before
    }

    It "Shows the help for -Restore -ShowHelp and reads nothing" {
        $result = Invoke-Features -Params @{ Restore = $true; ShowHelp = $true }
        $result.Text | Should -Match '--restore'
        $result.Exit | Should -Be 0
        Should -Invoke Read-FeaturesMenuKey -Times 0
    }
}

# ================================================================================================
Describe "sw features --restore menu" {
    BeforeEach { Initialize-FeatureEnvironment -ThrowOnChange }
    AfterEach { Restore-FeatureEnvironment }

    It "Offers the saved records in file order with nothing preselected, and says restore" {
        $null = Write-RemovedFile
        $null = Invoke-Restore -Select @()
        $screen = $script:FirstScreen
        $screen | Should -Match '(?i)restore'
        $screen | Should -Not -Match 'Select what to remove'
        $screen | Should -Not -Match '\[x\]'
        $last = -1
        foreach ($title in @('Example App', 'Other App', 'Third App', 'Legacy Feature', 'Second Feature')) {
            $index = $screen.IndexOf($title)
            $index | Should -BeGreaterThan $last
            $last = $index
        }
    }

    It "Offers the records even when the catalog no longer has them" {
        $null = Write-RemovedFile
        $script:Catalog = @()
        $null = Invoke-Restore -Select @()
        $script:FirstScreen | Should -Match 'Example App'
        $script:FirstScreen | Should -Match 'Legacy Feature'
    }

    It "Offers what was saved, not what is installed now" {
        Set-AllInstalled
        $null = Write-RemovedFile -Records @((New-RemovedRecord 'app.old' 'App' (Get-FullName 'Contoso.Old') 'Old App'))
        $null = Invoke-Features -Params @{ Restore = $true } -Keys @((Get-KeyEscape))
        $script:FirstScreen | Should -Match 'Old App'
        $script:FirstScreen | Should -Not -Match 'Example App'
        $script:FirstScreen | Should -Not -Match 'Legacy Feature'
    }

    It "Cancels with Esc and with Q: no prompt, no change, list untouched" -ForEach @(
        @{ Name = 'Esc' }, @{ Name = 'Q' }
    ) {
        $before = Write-RemovedFile
        $key = if ($Name -eq 'Esc') { Get-KeyEscape } else { Get-KeyQ }
        $result = Invoke-Features -Params @{ Restore = $true } -Keys @($key)
        $result.Text | Should -Match 'Cancelled'
        Should -Invoke Read-Host -Times 0
        $script:Calls.Count | Should -Be 0
        Get-FileText (Get-RemovedFilePath) | Should -Be $before
    }

    It "Stops with a message and no prompt when nothing is selected" {
        $before = Write-RemovedFile
        $result = Invoke-Restore -Select @()
        $result.Text | Should -Match 'Nothing selected'
        Should -Invoke Read-Host -Times 0
        $script:Calls.Count | Should -Be 0
        Get-FileText (Get-RemovedFilePath) | Should -Be $before
    }

    It "Does not offer features without administrator rights, shows the notice in the menu head, and offers the apps" {
        $null = Write-RemovedFile
        $script:IsAdmin = $false
        $null = Invoke-Features -Params @{ Restore = $true } -Keys @((Get-KeyEscape))
        $script:FirstScreen | Should -Match 'Run Sweepr in an administrator PowerShell for optional Windows features'
        $script:FirstScreen | Should -Match 'Example App'
        $script:FirstScreen | Should -Not -Match 'Legacy Feature'
        $script:FirstScreen | Should -Not -Match 'Second Feature'
    }

    It "Shows the notice without a menu when only features are saved and the rights are missing" {
        $records = @(
            (New-RemovedRecord 'feature.legacy' 'OptionalFeature' 'Contoso-Legacy' 'Legacy Feature')
        )
        $before = Write-RemovedFile -Records $records
        $script:IsAdmin = $false
        $result = Invoke-Features -Params @{ Restore = $true }
        $result.Text | Should -Match 'Run Sweepr in an administrator PowerShell for optional Windows features'
        $result.Exit | Should -Be 0
        Should -Invoke Read-FeaturesMenuKey -Times 0
        Should -Invoke Enable-WindowsOptionalFeature -Times 0
        Get-FileText (Get-RemovedFilePath) | Should -Be $before
    }

    It "Does not offer an invalid record, keeps it in the file and still offers the valid ones: <Name>" -ForEach @(
        @{ Name = 'feature name with a command'; Bad = @{ Id = 'feature.bad'; Kind = 'OptionalFeature'; Target = 'Contoso-Bad; calc'; Type = 'Enable'; Feature = 'Contoso-Bad; calc'; StoreId = $null } }
        @{ Name = 'feature other than target'; Bad = @{ Id = 'feature.bad'; Kind = 'OptionalFeature'; Target = 'Contoso-Bad'; Type = 'Enable'; Feature = 'Contoso-Other'; StoreId = $null } }
        @{ Name = 'store id with a space'; Bad = @{ Id = 'app.bad'; Kind = 'App'; Target = 'Contoso.Bad_1.0.0.0_x64__examplepublisher'; Type = 'Store'; Feature = $null; StoreId = '9N EXAMPLE; calc' } }
        @{ Name = 'restore type of the wrong kind'; Bad = @{ Id = 'app.bad'; Kind = 'App'; Target = 'Contoso.Bad_1.0.0.0_x64__examplepublisher'; Type = 'Enable'; Feature = 'Contoso.Bad_1.0.0.0_x64__examplepublisher'; StoreId = $null } }
        @{ Name = 'unknown kind'; Bad = @{ Id = 'thing.bad'; Kind = 'Driver'; Target = 'Contoso-Bad'; Type = 'Enable'; Feature = 'Contoso-Bad'; StoreId = $null } }
        @{ Name = 'target with a path'; Bad = @{ Id = 'app.bad'; Kind = 'App'; Target = '..\Contoso'; Type = 'Store'; Feature = $null; StoreId = $null } }
    ) {
        $bad = [pscustomobject][ordered]@{
            Id = $Bad.Id; Kind = $Bad.Kind; Title = 'Tampered Entry'; Target = $Bad.Target
            Restore = $(if ($Bad.Type -eq 'Store') { [ordered]@{ Type = 'Store'; StoreId = $Bad.StoreId } } else { [ordered]@{ Type = $Bad.Type; Feature = $Bad.Feature } })
            RemovedAt = '2026-10-25T10:00:00Z'
        }
        $good = New-RemovedRecord 'app.example' 'App' (Get-FullName 'Contoso.Example') 'Example App' $script:StoreIdExample
        $null = Write-RemovedFile -Records @($bad, $good)
        $null = Invoke-Features -Params @{ Restore = $true } -Keys @((Get-KeyEscape))
        $script:FirstScreen | Should -Not -Match 'Tampered Entry'
        $script:FirstScreen | Should -Match 'Example App'
        @(Get-RemovedIds) | Should -Be @($Bad.Id, 'app.example')
    }
}

# ================================================================================================
Describe "sw features --restore dry run" {
    BeforeEach { Initialize-FeatureEnvironment -ThrowOnChange }
    AfterEach { Restore-FeatureEnvironment }

    It "Previews the exact command of every selected record and runs nothing" {
        $before = Write-RemovedFile
        $result = Invoke-Restore -Select 0, 2, 3 -Params @{ DryRun = $true }
        $preview = Get-PreviewText $result
        $preview | Should -Match ([regex]::Escape($script:WingetInstallExample))
        $preview | Should -Match ([regex]::Escape($script:WingetInstallThird))
        $preview | Should -Match 'Enable-WindowsOptionalFeature -Online -FeatureName Contoso-Legacy -NoRestart'
        Should -Invoke Enable-WindowsOptionalFeature -Times 0
        Should -Invoke Invoke-FeaturesWinget -Times 0
        Should -Invoke Disable-WindowsOptionalFeature -Times 0
        Should -Invoke Remove-AppxPackage -Times 0
        Should -Invoke Restart-Computer -Times 0
        Should -Invoke Start-Process -Times 0
        $script:Calls.Count | Should -Be 0
        Get-FileText (Get-RemovedFilePath) | Should -Be $before
    }

    It "Does not preview records that were not selected" {
        $null = Write-RemovedFile
        $result = Invoke-Restore -Select 3 -Params @{ DryRun = $true }
        $preview = Get-PreviewText $result
        $preview | Should -Match 'Contoso-Legacy'
        $preview | Should -Not -Match 'Contoso-Second'
        $preview | Should -Not -Match 'winget install'
    }

    It "Names the Microsoft Store and the title for an app without a store id, with no winget command" {
        $null = Write-RemovedFile
        $result = Invoke-Restore -Select 1 -Params @{ DryRun = $true }
        $preview = Get-PreviewText $result
        $preview | Should -Match 'Microsoft Store'
        $preview | Should -Match 'Other App'
        $preview | Should -Not -Match 'winget install'
    }

    It "Names the Microsoft Store and the title when winget is not available, with no winget command" {
        $null = Write-RemovedFile
        $script:WingetAvailable = $false
        $result = Invoke-Restore -Select 0 -Params @{ DryRun = $true }
        $preview = Get-PreviewText $result
        $preview | Should -Match 'Microsoft Store'
        $preview | Should -Match 'Example App'
        $preview | Should -Not -Match 'winget install'
    }

    It "Writes no operations.log line and leaves the list untouched" {
        $before = Write-RemovedFile
        $null = Invoke-Restore -Select 0, 1, 2, 3, 4 -Params @{ DryRun = $true }
        Test-Path -LiteralPath $script:LogFile | Should -BeFalse
        Get-FileText (Get-RemovedFilePath) | Should -Be $before
    }

    It "Leaves the dry-run mode on while it runs" {
        $null = Write-RemovedFile
        $null = Invoke-Features -Params @{ Restore = $true; DryRun = $true } -Keys @((Get-KeyEscape))
        Test-DryRunMode | Should -BeTrue
    }

    It "Previews instead of restoring when the dry-run mode is already on (SWEEPR_DRY_RUN)" {
        $before = Write-RemovedFile
        Set-DryRunMode -Enabled $true
        $result = Invoke-Restore -Select 0, 3
        (Get-PreviewText $result) | Should -Match 'Enable-WindowsOptionalFeature -Online -FeatureName Contoso-Legacy -NoRestart'
        $script:Calls.Count | Should -Be 0
        Test-Path -LiteralPath $script:LogFile | Should -BeFalse
        Get-FileText (Get-RemovedFilePath) | Should -Be $before
    }

    It "Offers the same records as a real run: no features without administrator rights" {
        $null = Write-RemovedFile
        $script:IsAdmin = $false
        $null = Invoke-Features -Params @{ Restore = $true; DryRun = $true } -Keys @((Get-KeyEscape))
        $script:FirstScreen | Should -Not -Match 'Legacy Feature'
        $script:FirstScreen | Should -Match 'Example App'
    }
}

# ================================================================================================
Describe "sw features --restore run" {
    BeforeEach { Initialize-FeatureEnvironment }
    AfterEach { Restore-FeatureEnvironment }

    It "Asks y/N after listing the selection, and only y or Y goes on" -ForEach @(
        @{ Answer = 'y'; Runs = $true }, @{ Answer = 'Y'; Runs = $true }
        @{ Answer = ''; Runs = $false }, @{ Answer = 'n'; Runs = $false }, @{ Answer = 'N'; Runs = $false }
        @{ Answer = 'no'; Runs = $false }, @{ Answer = 'x'; Runs = $false }
    ) {
        $before = Write-RemovedFile
        $null = Invoke-Restore -Select 0, 3 -Answer $Answer
        $script:Prompts.Count | Should -Be 1
        $script:Prompts[0] | Should -Match '\(y/N\)'
        $script:ConfirmScreen | Should -Match 'Example App'
        $script:ConfirmScreen | Should -Match 'Legacy Feature'
        $script:ConfirmScreen | Should -Not -Match 'Other App'
        if ($Runs) {
            $script:Calls.Count | Should -Be 2
        }
        else {
            $script:Calls.Count | Should -Be 0
            Get-FileText (Get-RemovedFilePath) | Should -Be $before
            Test-Path -LiteralPath $script:LogFile | Should -BeFalse
        }
    }

    It "Enables a feature with -Online and -NoRestart, once, for the selected record only" {
        $null = Write-RemovedFile
        $result = Invoke-Restore -Select 3
        @($script:Calls) | Should -Be @('Enable-WindowsOptionalFeature Contoso-Legacy online=True norestart=True')
        Should -Invoke Disable-WindowsOptionalFeature -Times 0
        Should -Invoke Remove-AppxPackage -Times 0
        $result.Exit | Should -Be 0
    }

    It "Installs an app through winget with the exact arguments" {
        $null = Write-RemovedFile
        $null = Invoke-Restore -Select 0
        @($script:Calls) | Should -Be @($script:WingetInstallExample)
        Should -Invoke Invoke-FeaturesWinget -Times 1 -Exactly -ParameterFilter {
            ($Arguments -join '|') -eq 'install|--id|9NEXAMPLE001|--source|msstore|--accept-package-agreements|--accept-source-agreements'
        }
    }

    It "Works through the selection in menu order" {
        $null = Write-RemovedFile
        $null = Invoke-Restore -Select 0, 2, 3, 4
        @($script:Calls) | Should -Be @(
            $script:WingetInstallExample, $script:WingetInstallThird,
            'Enable-WindowsOptionalFeature Contoso-Legacy online=True norestart=True',
            'Enable-WindowsOptionalFeature Contoso-Second online=True norestart=True'
        )
    }

    It "Removes what was restored from the list and keeps the rest in order" {
        $null = Write-RemovedFile
        $null = Invoke-Restore -Select 0, 3
        @(Get-RemovedIds) | Should -Be @('app.other', 'app.third', 'feature.second')
        $items = @(Read-RemovedItems)
        $items[2].Restore.Feature | Should -Be 'Contoso-Second'
        $items[1].Restore.StoreId | Should -Be $script:StoreIdThird
    }

    It "Leaves an empty valid list (or no file) when everything was restored" {
        $null = Write-RemovedFile
        $null = Invoke-Restore -Select 0, 2, 3, 4 -Params @{}
        # row 1 (no store id) cannot be restored automatically, so it stays
        @(Get-RemovedIds) | Should -Be @('app.other')
        $null = Write-RemovedFile -Records @((New-RemovedRecord 'feature.legacy' 'OptionalFeature' 'Contoso-Legacy' 'Legacy Feature'))
        $script:Calls.Clear()
        $script:KeyQueue.Clear()
        $null = Invoke-Features -Params @{ Restore = $true } -Keys (New-SelectionKeys -Select 0 -Rows 1)
        @(Get-RemovedIds) | Should -Be @()
        $script:Calls.Count | Should -Be 1
    }

    It "Keeps a record whose restore failed and continues, and has saved the first success already" {
        $null = Write-RemovedFile
        $script:OnFeatureEnable = { param($Name) if ($Name -eq 'Contoso-Legacy') { throw 'enable boom' } }
        $result = Invoke-Restore -Select 0, 3, 4
        $script:Calls.Count | Should -Be 3
        @(Get-RemovedIds) | Should -Be @('app.other', 'app.third', 'feature.legacy')
        $result.Text | Should -Match 'enable boom'
        $result.Exit | Should -Be 0
    }

    It "Treats a winget exit code other than 0 as a failure and keeps the record" {
        $null = Write-RemovedFile
        $script:WingetExitCode = 1
        $null = Invoke-Restore -Select 0
        @(Get-RemovedIds) | Should -Contain 'app.example'
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 1
        $records[0] | Should -Match '^\[.*\] \[features run=testrun\] FAILED appx:'
        $records[0] | Should -Not -Match 'RESTORED'
    }

    It "Treats a throwing winget call as a failure and goes on with the next record" {
        $null = Write-RemovedFile
        $script:OnWinget = { throw 'winget boom' }
        $null = Invoke-Restore -Select 0, 3
        $script:Calls.Count | Should -Be 2
        @(Get-RemovedIds) | Should -Be @('app.example', 'app.other', 'app.third', 'feature.second')
        @(Get-LogRecords)[0] | Should -Match 'FAILED appx:.*winget boom'
        @(Get-LogRecords)[1] | Should -Match 'RESTORED feature:Contoso-Legacy'
    }

    It "Does not run winget for an app without a store id: hint with the title, record stays" {
        $null = Write-RemovedFile
        $result = Invoke-Restore -Select 1
        Should -Invoke Invoke-FeaturesWinget -Times 0
        $script:Calls.Count | Should -Be 0
        $result.Text | Should -Match 'Microsoft Store'
        $result.Text | Should -Match 'Other App'
        @(Get-RemovedIds) | Should -Contain 'app.other'
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 1
        $records[0] | Should -Match 'SKIPPED appx:Contoso\.Other_2\.5\.0\.0_x64__examplepublisher \((?=.*Microsoft Store)(?=.*Other App).*\)$'
    }

    It "Does not run winget when it is not available: hint with the title, record stays" {
        $null = Write-RemovedFile
        $script:WingetAvailable = $false
        $result = Invoke-Restore -Select 0
        Should -Invoke Invoke-FeaturesWinget -Times 0
        $result.Text | Should -Match 'Microsoft Store'
        $result.Text | Should -Match 'Example App'
        @(Get-RemovedIds) | Should -Contain 'app.example'
        @(Get-LogRecords)[0] | Should -Match 'SKIPPED appx:Contoso\.Example_.* \((?=.*Microsoft Store)(?=.*Example App).*\)$'
    }

    It "Needs no administrator rights for an app" {
        $null = Write-RemovedFile
        $script:IsAdmin = $false
        $null = Invoke-Restore -Select 0
        @($script:Calls) | Should -Be @($script:WingetInstallExample)
    }

    It "Skips a feature, with no Enable call, when the administrator rights are gone after the menu" {
        $null = Write-RemovedFile
        $script:OnPrompt = { $script:IsAdmin = $false }
        $null = Invoke-Restore -Select 0, 3
        @($script:Calls) | Should -Be @($script:WingetInstallExample)
        Should -Invoke Enable-WindowsOptionalFeature -Times 0
        @(Get-RemovedIds) | Should -Contain 'feature.legacy'
        $records = @(Get-LogRecords)
        $records[1] | Should -Match 'SKIPPED feature:Contoso-Legacy \((?!-\)).+\)$'
    }

    It "Calls no removal cmdlet, no restart and no process" {
        $null = Write-RemovedFile
        $null = Invoke-Restore -Select 0, 2, 3, 4
        Should -Invoke Disable-WindowsOptionalFeature -Times 0
        Should -Invoke Remove-AppxPackage -Times 0
        Should -Invoke Remove-AppxProvisionedPackage -Times 0
        Should -Invoke Restart-Computer -Times 0
        Should -Invoke Start-Process -Times 0
    }

    It "Works with the list in the active data folder: <Shape>" -ForEach @(
        @{ Shape = 'portable'; Dir = 'app\data\config' }
        @{ Shape = 'override'; Dir = 'elsewhere\config' }
    ) {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Config.ConfigPath = Join-Path $root $Dir
        $null = Write-RemovedFile
        $null = Invoke-Restore -Select 3
        @($script:Calls).Count | Should -Be 1
        @(Get-RemovedIds) | Should -Not -Contain 'feature.legacy'
        @(Get-ChildItem -LiteralPath $root -Recurse -Force -Filter 'features-removed.json').Count | Should -Be 1
    }
}

# ================================================================================================
# Lead decision on festlegung 6: an app that is already there is restored by definition.
# "Already installed" = Get-AppxPackage -Name <Target up to the first "_"> returns exactly one package.
# Then: no winget call, RESTORED with "already installed" in the detail, record removed.
# winget exit code -1978335189 (0x8A15002B, package already installed) counts the same way.
Describe "sw features --restore for apps that are already installed" {
    BeforeEach { Initialize-FeatureEnvironment }
    AfterEach { Restore-FeatureEnvironment }

    It "Does not run winget, logs RESTORED already installed and removes the record" {
        $null = Write-RemovedFile
        $script:Packages['Contoso.Example'] = New-AppPackage -Name 'Contoso.Example' -Version '2.6.0.0'
        $result = Invoke-Restore -Select 0, 2
        @($script:Calls) | Should -Be @($script:WingetInstallThird)
        Should -Invoke Invoke-FeaturesWinget -Times 1 -Exactly
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 2
        $records[0] | Should -Match 'RESTORED appx:Contoso\.Example_2\.5\.0\.0_x64__examplepublisher \(.*already installed.*\)$'
        $records[0] | Should -Not -Match 'winget install'
        @(Get-RemovedIds) | Should -Be @('app.other', 'feature.legacy', 'feature.second')
        $result.Exit | Should -Be 0
    }

    It "Counts it as installed without a store id and without winget" {
        $null = Write-RemovedFile
        $script:WingetAvailable = $false
        $script:Packages['Contoso.Other'] = New-AppPackage -Name 'Contoso.Other'
        $null = Invoke-Restore -Select 1
        Should -Invoke Invoke-FeaturesWinget -Times 0
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 1
        $records[0] | Should -Match 'RESTORED appx:Contoso\.Other_.* \(.*already installed.*\)$'
        @(Get-RemovedIds) | Should -Not -Contain 'app.other'
    }

    It "Takes the exact package name from the target before the first underscore: another package does not count" {
        $null = Write-RemovedFile
        $script:Packages['Contoso.ExampleOther'] = New-AppPackage -Name 'Contoso.ExampleOther'
        $null = Invoke-Restore -Select 0
        @($script:Calls) | Should -Be @($script:WingetInstallExample)
        Should -Invoke Get-AppxPackage -Times 1 -ParameterFilter { $Name -eq 'Contoso.Example' }
    }

    It "Runs winget when the app is not installed" {
        $null = Write-RemovedFile
        $null = Invoke-Restore -Select 0
        @($script:Calls) | Should -Be @($script:WingetInstallExample)
        @(Get-LogRecords)[0] | Should -Not -Match 'already installed'
    }

    It "Does not guess when the package list is ambiguous: two packages mean winget runs" {
        $null = Write-RemovedFile
        $script:Packages['Contoso.Example'] = @((New-AppPackage -Name 'Contoso.Example' -Version '2.6.0.0'), (New-AppPackage -Name 'Contoso.Example' -Version '2.7.0.0'))
        $null = Invoke-Restore -Select 0
        @($script:Calls) | Should -Be @($script:WingetInstallExample)
    }

    It "Checks installed apps with no administrator rights" {
        $null = Write-RemovedFile
        $script:IsAdmin = $false
        $script:Packages['Contoso.Example'] = New-AppPackage -Name 'Contoso.Example'
        $null = Invoke-Restore -Select 0
        $script:Calls.Count | Should -Be 0
        @(Get-LogRecords)[0] | Should -Match 'RESTORED appx:'
    }

    It "Counts winget's already-installed exit code (-1978335189) as RESTORED already installed and removes the record" {
        $null = Write-RemovedFile
        $script:WingetExitCode = -1978335189
        $null = Invoke-Restore -Select 0
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 1
        $records[0] | Should -Match 'RESTORED appx:Contoso\.Example_2\.5\.0\.0_x64__examplepublisher \(.*already installed.*\)$'
        $records[0] | Should -Not -Match 'FAILED'
        @(Get-RemovedIds) | Should -Not -Contain 'app.example'
    }

    It "Still fails on another negative winget exit code and keeps the record" {
        $null = Write-RemovedFile
        $script:WingetExitCode = -1978335188
        $null = Invoke-Restore -Select 0
        @(Get-LogRecords)[0] | Should -Match 'FAILED appx:.*exit code -1978335188'
        @(Get-RemovedIds) | Should -Contain 'app.example'
    }
}

# ================================================================================================
Describe "sw features --restore restart notice" {
    BeforeEach { Initialize-FeatureEnvironment }
    AfterEach { Restore-FeatureEnvironment }

    It "Tells once to restart Windows when a result needs it, and does not restart" {
        $null = Write-RemovedFile
        $script:EnableResult = [pscustomobject]@{ RestartNeeded = $true }
        $result = Invoke-Restore -Select 3, 4
        ([regex]::Matches($result.Text, 'Restart Windows to finish\.')).Count | Should -Be 1
        Should -Invoke Restart-Computer -Times 0
        Should -Invoke Start-Process -Times 0
    }

    It "Says nothing about a restart when no result needs one" {
        $null = Write-RemovedFile
        $result = Invoke-Restore -Select 0, 3
        $result.Text | Should -Not -Match 'Restart Windows'
    }

    It "Says nothing about a restart when the enabling failed" {
        $null = Write-RemovedFile
        $script:OnFeatureEnable = { throw 'enable boom' }
        $script:EnableResult = [pscustomobject]@{ RestartNeeded = $true }
        $result = Invoke-Restore -Select 3
        $result.Text | Should -Not -Match 'Restart Windows'
    }

    It "Says nothing about a restart when the result has no RestartNeeded property" {
        $null = Write-RemovedFile
        $script:EnableResult = [pscustomobject]@{ Path = 'x' }
        $result = Invoke-Restore -Select 3
        $result.Text | Should -Not -Match 'Restart Windows'
    }
}

# ================================================================================================
Describe "sw features --restore operations log" {
    BeforeEach { Initialize-FeatureEnvironment }
    AfterEach { Restore-FeatureEnvironment }

    It "Logs RESTORED for an app as appx: plus the target, with the winget command" {
        $null = Write-RemovedFile
        $null = Invoke-Restore -Select 0
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 1
        $records[0] | Should -Match '\[features run=testrun\] RESTORED appx:Contoso\.Example_2\.5\.0\.0_x64__examplepublisher \(.*winget install --id 9NEXAMPLE001 --source msstore --accept-package-agreements --accept-source-agreements\)$'
    }

    It "Logs RESTORED for a feature as feature: plus the name, with the command" {
        $null = Write-RemovedFile
        $null = Invoke-Restore -Select 3
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 1
        $records[0] | Should -Match 'RESTORED feature:Contoso-Legacy \(.*Enable-WindowsOptionalFeature -Online -FeatureName Contoso-Legacy -NoRestart\)$'
        $records[0] | Should -Not -Match 'restart needed'
    }

    It "Adds restart needed to the RESTORED detail when the result says so" {
        $null = Write-RemovedFile
        $script:EnableResult = [pscustomobject]@{ RestartNeeded = $true }
        $null = Invoke-Restore -Select 3
        @(Get-LogRecords)[0] | Should -Match 'RESTORED feature:Contoso-Legacy \(.*restart needed.*\)$'
    }

    It "Logs FAILED with the command and the error text for a feature" {
        $null = Write-RemovedFile
        $script:OnFeatureEnable = { throw 'feature boom' }
        $null = Invoke-Restore -Select 3
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 1
        $records[0] | Should -Match 'FAILED feature:Contoso-Legacy \(.*Enable-WindowsOptionalFeature -Online -FeatureName Contoso-Legacy -NoRestart failed: .*feature boom.*\)$'
        $records[0] | Should -Not -Match 'RESTORED'
    }

    It "Logs FAILED with the command and the exit code for winget" {
        $null = Write-RemovedFile
        $script:WingetExitCode = 3
        $null = Invoke-Restore -Select 0
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 1
        $records[0] | Should -Match 'FAILED appx:Contoso\.Example_2\.5\.0\.0_x64__examplepublisher \(.*winget install --id 9NEXAMPLE001 .* failed: .*exit code 3.*\)$'
    }

    It "Writes one line per selected record, in menu order" {
        $null = Write-RemovedFile
        $script:OnFeatureEnable = { param($Name) if ($Name -eq 'Contoso-Second') { throw 'boom' } }
        $null = Invoke-Restore -Select 0, 1, 3, 4
        $records = @(Get-LogRecords)
        $records.Count | Should -Be 4
        $records[0] | Should -Match 'RESTORED appx:Contoso\.Example_'
        $records[1] | Should -Match 'SKIPPED appx:Contoso\.Other_'
        $records[2] | Should -Match 'RESTORED feature:Contoso-Legacy'
        $records[3] | Should -Match 'FAILED feature:Contoso-Second'
    }

    It "Writes nothing to the log for a cancelled or empty selection" {
        $null = Write-RemovedFile
        $null = Invoke-Features -Params @{ Restore = $true } -Keys @((Get-KeyEscape))
        $null = Invoke-Features -Params @{ Restore = $true } -Keys @((Get-KeyEnter))
        Test-Path -LiteralPath $script:LogFile | Should -BeFalse
    }
}

# ================================================================================================
Describe "sw history counts the RESTORED action" {
    BeforeAll {
        function script:Write-HistoryFixture([string[]]$Lines) {
            $path = Join-Path (Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))) "operations.log"
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            [System.IO.File]::WriteAllLines($path, $Lines)
            return $path
        }
        $script:RestoreLogLines = @(
            "",
            "# ========== features run=r1 session started at 2026-10-25 11:00:00 ==========",
            "[2026-10-25 11:00:01] [features run=r1] RESTORED appx:Contoso.Example_2.5.0.0_x64__examplepublisher (winget install --id 9NEXAMPLE001 --source msstore --accept-package-agreements --accept-source-agreements)",
            "[2026-10-25 11:00:02] [features run=r1] RESTORED feature:Contoso-Legacy (Enable-WindowsOptionalFeature -Online -FeatureName Contoso-Legacy -NoRestart; restart needed)",
            "[2026-10-25 11:00:03] [features run=r1] FAILED appx:Contoso.Other_2.5.0.0_x64__examplepublisher (winget install failed: exit code 1)",
            "[2026-10-25 11:00:04] [features run=r1] SKIPPED appx:Contoso.Third_2.5.0.0_x64__examplepublisher (install it from the Microsoft Store)"
        )
    }

    It "Counts RESTORED, FAILED and SKIPPED of a restore session, nothing under other" {
        $history = Read-SweeprHistory -Path (Write-HistoryFixture $script:RestoreLogLines)
        @($history.Sessions).Count | Should -Be 1
        $actions = $history.Sessions[0].actions
        $actions.restored | Should -Be 2
        $actions.failed | Should -Be 1
        $actions.skipped | Should -Be 1
        $actions.other | Should -Be 0
        $actions.removed | Should -Be 0
        $history.Sessions[0].operation_count | Should -Be 4
    }

    It "Keeps the action name restored and the appx:/feature: paths" {
        $history = Read-SweeprHistory -Path (Write-HistoryFixture $script:RestoreLogLines)
        $history.Operations[0].action | Should -Be 'restored'
        $history.Operations[0].path | Should -BeExactly 'appx:Contoso.Example_2.5.0.0_x64__examplepublisher'
        $history.Operations[1].path | Should -BeExactly 'feature:Contoso-Legacy'
        $history.Operations[1].detail | Should -Match 'restart needed'
    }

    It "Shows restored in the text summary and in the JSON" {
        $path = Write-HistoryFixture $script:RestoreLogLines
        $history = Read-SweeprHistory -Path $path
        Format-SweeprHistoryActions $history.Sessions[0].actions | Should -Match 'restored 2'
        $json = ConvertTo-SweeprHistoryJson -History $history -Limit 20 -LogPath $path | ConvertFrom-Json
        $json.sessions[0].actions.restored | Should -Be 2
    }

    It "Does not call a session with only a RESTORED line empty" {
        $path = Write-HistoryFixture @("[2026-10-25 11:00:02] [features run=r2] RESTORED feature:Contoso-Legacy (Enable-WindowsOptionalFeature -Online -FeatureName Contoso-Legacy -NoRestart)")
        $history = Read-SweeprHistory -Path $path
        Format-SweeprHistoryActions $history.Sessions[0].actions | Should -Be 'restored 1'
    }

    It "Counts restored as 0 for the sessions of the other commands" {
        $path = Write-HistoryFixture @(
            "[2026-10-25 10:00:01] [clean run=c1] REMOVED C:\Temp\one (1.0KB)"
        )
        (Read-SweeprHistory -Path $path).Sessions[0].actions.restored | Should -Be 0
    }
}
