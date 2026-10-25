# Sweepr - F-03b: the sw check command (Design Rev 4 sections 19 and 21, decisions E23-E30)
#
# `sw check` looks at the PC once and reports; it never changes anything. This file pins the
# command without the HTML report (F-03c): --report only calls a hook.
#
# Platform neutral: the command functions are lifted out of bin\check.ps1 by AST extraction, so its
# top level never runs. The four data sources (Get-SweeprCleanPreview, Get-SweeprPurgePreview,
# Get-SweeprHealth, Get-SweeprFeatureInventory) are mocks, every changing cmdlet is a mock that
# throws, the profile is a fake one (C:\Users\Alice), nothing real is read or changed.
#
# Interface fixed by these tests (the implementer builds exactly this in bin\check.ps1, sweepr.ps1,
# install.ps1):
#
#   bin\check.ps1 param block ([CmdletBinding()], plain ASCII):
#       [switch]$Json, [switch]$Report, [Alias('no-open')] [switch]$NoOpen, [Alias('dry-run')] [switch]$DryRun,
#       [Alias('d')] [switch]$DebugMode, [Alias('h')] [switch]$ShowHelp
#   Dot-sources core\base, core\log, core\ui, core\file_ops, core\features, core\health, clean\preview and
#   clean\projects. Never core\update_check.ps1, never another bin\*.ps1 (no Main of a command script).
#   The script ends with
#       try { Invoke-CheckCommand -Json:$Json -Report:$Report -NoOpen:$NoOpen -DryRun:$DryRun -ShowHelp:$ShowHelp }
#       finally { Stop-Spinner }
#   followed by `exit $script:CheckExitCode` when that is not 0.
#
#   Top-level functions (all lifted by the tests):
#     Show-CheckHelp                usage text: --json, --report, --no-open, --dry-run, --debug, --help
#     Test-CheckOutputAsJson        [Console]::IsOutputRedirected (mocked)
#     Get-CheckVersion              the Sweepr version string (mocked; the lifted code has no script path)
#     Invoke-CheckCommand [-Json] [-Report] [-NoOpen] [-DryRun] [-ShowHelp]   the whole command
#
#   Report hook (F-03c builds it, in lib; this command only calls it):
#       Invoke-SweeprCheckReport -Result <object> [-NoOpen]    returns the path of the report (or nothing)
#     Called once, only with --report, after all four areas ran, with the result object below.
#     -NoOpen is passed as $true exactly when --no-open was given (the hook opens the browser, not the
#     command). If the function does not exist (F-03c not there yet) the command does not crash: it says
#     exactly "The report is not available in this version." and ends with exit code 1. (A hook that exists
#     but throws gives another message and exit code 1 as well.)
#
#   Options: --json is JSON only when the output is redirected (Test-CheckOutputAsJson); on a console it
#   shows the normal summary. --report asks for the HTML report. --no-open is accepted everywhere, it only
#   means something with --report. --dry-run is accepted and has no effect: sw check is always a dry run.
#   An unknown option is refused by the router with exit code 2 (nothing runs).
#
#   Exit codes ($script:CheckExitCode, set to 0 at the start of every call):
#     0  the check ran; an area that failed is marked "error" in the result, the others still ran
#     1  --report was requested and the report could not be made (hook throws or does not exist)
#     2  usage (unknown option), set by the router
#
#   Flow: the command switches the global dry-run mode on for the whole run (Set-DryRunMode $true), sets
#   $env:SWEEPR_NO_OPLOG = '1' and puts both back to what they were in a finally. Then, each area in its own
#   try/catch, so one failing area never stops the others:
#     Clean     Get-SweeprCleanPreview -SkipExternalTools [-System]   (-System only when Test-IsAdmin; GameMedia
#               and GpuShaders are not asked for)
#     Apps      Get-SweeprFeatureInventory                            (no arguments)
#     System    Get-SweeprHealth
#     Projects  Get-SweeprPurgePreview with the limits bound explicitly and no -SearchPaths (the built-in
#               folders): -MaxDepth 1..4, -MaxSecondsPerRoot 1..15, -MaxTotalSeconds 1..60 (and not less than
#               the per-root limit), -MaxSizeFiles 1..50000
#   No self-elevation, no Start-Process, no operations log, no update notice or update-check.json, no
#   clean-list.txt, no network, no clear-screen, no prompt.
#
#   Result object (ONE object; the JSON document, the object handed to the report hook and the source of the
#   console summary are the same data). Every property is on a fixed allowlist, nothing is copied by wildcard:
#     Version        string  from Get-CheckVersion
#     GeneratedAt    string  ISO 8601 (yyyy-MM-ddTHH:mm:ss...)
#     IsAdmin        bool
#     Sections       object  Clean, Apps, System, Projects (each below)
#     NotMeasured    array   { Section, Name, Reason }   Section is Clean, Apps, System or Projects
#   Every section has Status ('ok' or 'error') and Reason ($null, or 'error' when the area failed). An area
#   that failed has ONLY Status and Reason.
#     Clean     IncludesSystem [bool: the -System preview ran], TotalBytes [long], Count [int: files],
#               Groups [ { Name, TotalBytes, Count } ] per cleanup section in run order,
#               Top [ { Section, Path, SizeBytes, Count } ] the 20 biggest hits, biggest first
#     Apps      Count, NeedsAdmin [bool: optional features could not be read], Items [ { Id, Kind, Title } ]
#     System    Disks { Measured, Drives [ { Drive, SizeBytes, FreeBytes, FreePercent, IsSystem, Health } ] },
#               Memory { Measured, TotalBytes, FreeBytes, UsedBytes, UsedPercent },
#               Uptime { Measured, LastBoot [ISO string], UptimeDays },
#               Updates { Measured, LastInstalledOn [ISO string], Recent [ { Id, InstalledOn } ] },
#               PendingUpdates { Measured, Total, Important },
#               Startup { Measured, Count, Entries [ { Name, Source } ] }       (never the command line)
#     Projects  Count, TotalBytes, Complete [bool], TimedOut [bool: any search root ran out of time],
#               SkippedUnverified [int], Top [ { Path, Name, TotalBytes, SizeComplete } ] the 20 biggest projects
#   Arrays stay JSON arrays with one element and with none.
#   NOT in the result: user, computer or domain name, IP addresses, volume labels, file system, serials,
#   startup command lines, the descriptions of hits, package names/targets, raw exception messages, search roots.
#   Paths (normalized first: a leading `\\?\` or `\\?\UNC\` is dropped, `/` counts as `\`): below the profile
#   as `~\...`; below another user's folder `C:\Users\<user>\...`; a network path `\\<host>\<share>\...`
#   (host and share are always replaced); EVERY path part equal to $env:USERNAME (any case) becomes `<user>`
#   (e.g. a redirected %APPDATA% on `\\srv01\home$\Alice\AppData` -> `\\<host>\<share>\<user>\AppData`);
#   anything else (C:\Windows\Temp\x) unchanged. Neither user nor computer name appears in the JSON, the
#   console or the object handed to the report hook.
#   Reason texts come from a fixed list only: 'external tool', 'needs administrator', 'time limit',
#   'incomplete', 'not available', 'error'. A source text of 'external tool' or 'needs administrator' is kept,
#   one starting with 'error' becomes 'error', every other text becomes 'not available'.
#   NotMeasured entries: the preview's own (tools, 'error'), the System cleanup entry when -System was not asked
#   because the run is not elevated (Section Clean, Name 'System cleanup', 'needs administrator'), 'Optional
#   Windows features' (Section Apps, 'needs administrator') when the inventory says FeaturesNeedAdmin, every
#   health part with Measured = $false (Section System, Name = the part, Reason cleaned), and for projects
#   when Complete is $false: Section Projects, Name 'Project artifacts', Reason 'time limit' if a root timed
#   out, else 'incomplete'.
#
#   Console (Write-Host only, nothing on the success stream), one block per area, then a closing line:
#     Cleanup potential: <size> in <n> files               (area failed: "Cleanup potential: error")
#     Apps and features: <n> can be removed with sw features
#     System health:                                       (area failed: "System health: error")
#       Disk C: <free> free of <size>
#       Memory: 62.5% used
#       Uptime: 5.2 days
#       Startup programs: 3
#     Project artifacts: <size> in <n> projects            (incomplete: "at least <size> ... (incomplete)")
#     Not measured: npm, pip (external tool)               (only when there are entries)
#     Run Sweepr in an administrator PowerShell to also check system cleanup and optional Windows features.
#                                                          (only without administrator rights)
#     Report: <path>                                       (only when the hook returned a path)
#     Nothing was changed.
#   Sizes come from Format-ByteSize.

BeforeAll {
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $script:LibDir = Join-Path $script:WindowsDir 'lib'
    $script:BinFile = Join-Path $script:WindowsDir 'bin\check.ps1'
    $script:SweeprFile = Join-Path $script:WindowsDir 'sweepr.ps1'
    $script:InstallFile = Join-Path $script:WindowsDir 'install.ps1'

    foreach ($module in @('core\base', 'core\log', 'core\ui', 'core\file_ops', 'core\features', 'core\health', 'core\update_check',
            'clean\user', 'clean\caches', 'clean\dev', 'clean\apps', 'clean\system', 'clean\preview', 'clean\projects')) {
        . (Join-Path $script:LibDir "$module.ps1")
    }

    # Commands that exist on Windows only get a stub so that Pester can mock them everywhere.
    foreach ($name in @('Remove-AppxPackage', 'Remove-AppxProvisionedPackage', 'Disable-WindowsOptionalFeature', 'Enable-WindowsOptionalFeature',
            'Restart-Computer', 'Stop-Service', 'Set-Service', 'Restart-Service', 'Clear-RecycleBin', 'Remove-ItemProperty', 'Set-ItemProperty', 'New-ItemProperty')) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:script:$name" -Value { param() }
        }
    }
    # The report hook belongs to F-03c. A stub (global, so that it can be removed again) lets the tests mock it;
    # Initialize-CheckEnvironment defines it, Restore-CheckEnvironment removes it.
    function script:Remove-HookStub {
        # Not Remove-Item: that cmdlet is a throwing mock inside the tests.
        if (Test-Path -Path 'Function:\Invoke-SweeprCheckReport') {
            $ExecutionContext.SessionState.InvokeProvider.Item.Remove('Function:\Invoke-SweeprCheckReport', $false)
        }
    }

    # Every cmdlet that changes the PC, the profile, the log or the network, or that asks the user. All throw.
    $script:ChangingCommands = @(
        'New-Item', 'Set-Content', 'Add-Content', 'Out-File', 'Move-Item', 'Copy-Item', 'Rename-Item', 'Clear-Content', 'New-ItemProperty',
        'Remove-Item', 'Clear-RecycleBin', 'Remove-AppxPackage', 'Remove-AppxProvisionedPackage', 'Disable-WindowsOptionalFeature',
        'Enable-WindowsOptionalFeature', 'Start-Process', 'Stop-Process', 'Stop-Service', 'Set-Service', 'Restart-Service', 'Restart-Computer',
        'Set-ItemProperty', 'Remove-ItemProperty', 'Remove-SafeItem', 'Remove-SafeItems', 'Remove-SafeDirectoryTree', 'Remove-OldFiles',
        'Clear-DirectoryContents', 'Clear-Host', 'Read-Host', 'Invoke-RestMethod', 'Invoke-WebRequest',
        'Start-SweeprUpdateCheck', 'Show-SweeprUpdateNotice'
    )
    $script:ReasonList = @('external tool', 'needs administrator', 'time limit', 'incomplete', 'not available', 'error')
    $script:AllowedPaths = @(
        'Version', 'GeneratedAt', 'IsAdmin', 'Sections', 'NotMeasured', 'NotMeasured.Section', 'NotMeasured.Name', 'NotMeasured.Reason',
        'Sections.Clean', 'Sections.Clean.Status', 'Sections.Clean.Reason', 'Sections.Clean.IncludesSystem', 'Sections.Clean.TotalBytes', 'Sections.Clean.Count',
        'Sections.Clean.Groups', 'Sections.Clean.Groups.Name', 'Sections.Clean.Groups.TotalBytes', 'Sections.Clean.Groups.Count',
        'Sections.Clean.Top', 'Sections.Clean.Top.Section', 'Sections.Clean.Top.Path', 'Sections.Clean.Top.SizeBytes', 'Sections.Clean.Top.Count',
        'Sections.Apps', 'Sections.Apps.Status', 'Sections.Apps.Reason', 'Sections.Apps.Count', 'Sections.Apps.NeedsAdmin',
        'Sections.Apps.Items', 'Sections.Apps.Items.Id', 'Sections.Apps.Items.Kind', 'Sections.Apps.Items.Title',
        'Sections.System', 'Sections.System.Status', 'Sections.System.Reason',
        'Sections.System.Disks', 'Sections.System.Disks.Measured', 'Sections.System.Disks.Drives', 'Sections.System.Disks.Drives.Drive',
        'Sections.System.Disks.Drives.SizeBytes', 'Sections.System.Disks.Drives.FreeBytes', 'Sections.System.Disks.Drives.FreePercent',
        'Sections.System.Disks.Drives.IsSystem', 'Sections.System.Disks.Drives.Health',
        'Sections.System.Memory', 'Sections.System.Memory.Measured', 'Sections.System.Memory.TotalBytes', 'Sections.System.Memory.FreeBytes',
        'Sections.System.Memory.UsedBytes', 'Sections.System.Memory.UsedPercent',
        'Sections.System.Uptime', 'Sections.System.Uptime.Measured', 'Sections.System.Uptime.LastBoot', 'Sections.System.Uptime.UptimeDays',
        'Sections.System.Updates', 'Sections.System.Updates.Measured', 'Sections.System.Updates.LastInstalledOn', 'Sections.System.Updates.Recent',
        'Sections.System.Updates.Recent.Id', 'Sections.System.Updates.Recent.InstalledOn',
        'Sections.System.PendingUpdates', 'Sections.System.PendingUpdates.Measured', 'Sections.System.PendingUpdates.Total', 'Sections.System.PendingUpdates.Important',
        'Sections.System.Startup', 'Sections.System.Startup.Measured', 'Sections.System.Startup.Count', 'Sections.System.Startup.Entries',
        'Sections.System.Startup.Entries.Name', 'Sections.System.Startup.Entries.Source',
        'Sections.Projects', 'Sections.Projects.Status', 'Sections.Projects.Reason', 'Sections.Projects.Count', 'Sections.Projects.TotalBytes',
        'Sections.Projects.Complete', 'Sections.Projects.TimedOut', 'Sections.Projects.SkippedUnverified',
        'Sections.Projects.Top', 'Sections.Projects.Top.Path', 'Sections.Projects.Top.Name', 'Sections.Projects.Top.TotalBytes', 'Sections.Projects.Top.SizeComplete'
    )

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

    $script:CheckExitCode = 0
    $script:CheckAst = $null
    if (Test-Path -LiteralPath $script:BinFile) {
        $script:CheckAst = Import-AllScriptFunctions -Script $script:BinFile
    }
    # Placeholders so Mock still works while bin\check.ps1 does not define them yet.
    foreach ($name in @('Test-CheckOutputAsJson', 'Get-CheckVersion', 'Invoke-CheckCommand', 'Show-CheckHelp')) {
        if (-not (Test-Path -Path "function:$name")) {
            Set-Item -Path "function:script:$name" -Value ([scriptblock]::Create("throw 'bin\check.ps1 is missing $name'"))
        }
    }
    Import-ScriptFunction -Script $script:SweeprFile -Names @('Resolve-CommandParameterName', 'Show-MainHelp')

    # ---- fixtures: what the four data sources return --------------------------------------------

    function script:New-Hit {
        param([string]$Section, [string]$Description, [string]$Path, [long]$Size, [int]$Count = 1)
        return [pscustomobject]@{ Section = $Section; Description = $Description; Path = $Path; SizeBytes = $Size; Count = $Count }
    }

    function script:New-CleanPreview {
        param([object[]]$Hits, [object[]]$NotMeasured = @(), [bool]$Admin = $true)
        $names = @($Hits | ForEach-Object { $_.Section } | Select-Object -Unique)
        $sections = @(foreach ($n in $names) {
                $h = @($Hits | Where-Object { $_.Section -eq $n })
                [pscustomobject]@{
                    Name = $n; Hits = $h
                    TotalBytes = [long](($h | Measure-Object -Property SizeBytes -Sum).Sum)
                    Count = [int](($h | Measure-Object -Property Count -Sum).Sum)
                }
            })
        return [pscustomobject]@{
            DryRun = $true; IsAdmin = $Admin; Sections = $sections; Hits = @($Hits)
            TotalBytes = [long](($Hits | Measure-Object -Property SizeBytes -Sum).Sum)
            Count = [int](($Hits | Measure-Object -Property Count -Sum).Sum)
            NotMeasured = @($NotMeasured)
        }
    }

    function script:New-AppItem {
        param([string]$Id, [string]$Kind, [string]$Title)
        return [pscustomobject]@{
            Id = $Id; Kind = $Kind; Title = $Title; Description = "Example description of $Title."; Warning = 'Sign-in may need this.'
            Target = "Contoso.$Id`_2.5.0.0_x64__examplepublisher"; Provisioned = $true; ProvisionedName = "Contoso.$Id`_2.5.0.0_neutral_~_examplepublisher"
        }
    }

    function script:New-Project {
        param([string]$Display, [long]$Bytes, [bool]$SizeComplete = $true)
        $raw = $Display.Replace('~', 'C:\Users\Alice')
        return [pscustomobject]@{
            Path = $raw; Name = ($Display -split '\\')[-1]; DisplayPath = $Display; Marker = 'package.json'
            TotalBytes = $Bytes; SizeComplete = $SizeComplete
            Artifacts = @([pscustomobject]@{ Path = "$raw\node_modules"; Name = 'node_modules'; Type = 'Directory'; Language = 'JavaScript/Node.js'; SizeBytes = $Bytes; SizeComplete = $SizeComplete })
        }
    }

    function script:New-PurgePreview {
        param([object[]]$Projects, [bool]$Complete = $true, [bool]$TimedOut = $false, [int]$Skipped = 0)
        return [pscustomobject]@{
            Projects = @($Projects)
            TotalBytes = [long](($Projects | Measure-Object -Property TotalBytes -Sum).Sum)
            Roots = @([pscustomobject]@{ Path = 'C:\Users\Alice\Code'; Exists = $true; TimedOut = $TimedOut })
            SkippedUnverified = $Skipped
            Complete = $Complete
        }
    }

    # Parts carry extra properties a careless copy would pass on (host name, address, serial).
    function script:New-HealthData {
        return [pscustomobject]@{
            IsAdmin = $true
            Disks = [pscustomobject]@{
                Measured = $true; Reason = $null
                Drives = @([pscustomobject]@{
                        Drive = 'C:'; Label = 'ALICE-DATA'; FileSystem = 'NTFS'; SizeBytes = [long](500GB); FreeBytes = [long](120GB)
                        FreePercent = 24; IsSystem = $true; Health = 'Healthy'; Serial = 'SN-0042'
                    })
            }
            Memory = [pscustomobject]@{
                Measured = $true; Reason = $null; TotalBytes = [long](16GB); FreeBytes = [long](6GB); UsedBytes = [long](10GB)
                UsedPercent = 62.5; ComputerName = 'CONTOSO-PC01'; IpAddress = '10.1.2.3'
            }
            Uptime = [pscustomobject]@{ Measured = $true; Reason = $null; LastBoot = [datetime]'2026-10-20T08:00:00'; UptimeDays = 5.2 }
            Updates = [pscustomobject]@{
                Measured = $true; Reason = $null; LastInstalledOn = [datetime]'2026-10-14T00:00:00'
                Recent = @([pscustomobject]@{ Id = 'KB5000001'; Description = 'Security Update'; InstalledOn = [datetime]'2026-10-14T00:00:00' })
            }
            PendingUpdates = [pscustomobject]@{ Measured = $true; Reason = $null; Total = 2; Important = 1 }
            Startup = [pscustomobject]@{
                Measured = $true; Reason = $null; Count = 3; Missing = @()
                Entries = @(
                    [pscustomobject]@{ Name = 'ExampleSync'; Command = '"C:\Users\Alice\AppData\Local\ExampleSync\sync.exe" --token=SECRET123'; Source = 'HKCU Run' }
                    [pscustomobject]@{ Name = 'Helper'; Command = 'C:\Program Files\Helper\h.exe'; Source = 'HKLM Run' }
                    [pscustomobject]@{ Name = 'start.lnk'; Command = 'C:\Users\Alice\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\start.lnk'; Source = 'Startup folder' }
                )
            }
            NotMeasured = @()
        }
    }

    function script:Set-DefaultData {
        $script:CleanData = New-CleanPreview -Hits @(
            (New-Hit 'User essentials' 'Alice temp files' 'C:\Users\Alice\AppData\Local\Temp\a' 200MB 40)
            (New-Hit 'User essentials' 'Windows temp' 'C:\Windows\Temp\old' 100MB 5)
            (New-Hit 'Browser cache' 'Chrome cache of Alice' 'C:\Users\Alice\AppData\Local\Google\Chrome\User Data\Default\Cache' 700MB 500)
            (New-Hit 'Developer tools' 'Go build cache' 'C:\Users\Alice\.cache\go-build' 1536MB 300)
        ) -NotMeasured @(
            [pscustomobject]@{ Section = 'Developer tools'; Name = 'npm'; Reason = 'external tool' }
            [pscustomobject]@{ Section = 'Developer tools'; Name = 'pip'; Reason = 'external tool' }
        )
        $script:AppsData = [pscustomobject]@{
            Items = @((New-AppItem 'app.example' 'App' 'Example App'), (New-AppItem 'app.other' 'App' 'Other App'), (New-AppItem 'feature.legacy' 'OptionalFeature' 'Legacy Feature'))
            FeaturesNeedAdmin = $false
        }
        $script:HealthData = New-HealthData
        $script:PurgeData = New-PurgePreview -Projects @(
            (New-Project '~\Code\app' 800MB)
            (New-Project '~\Code\api' 300MB)
            (New-Project 'D:\Projects\site' 100MB)
        )
    }

    # Mocks, state and private data folders for one test. Called from BeforeEach (one per block).
    function script:Initialize-CheckEnvironment {
        param([switch]$SkipHook)
        $script:Saved = @{
            UserProfile = $env:USERPROFILE; UserName = $env:USERNAME; ComputerName = $env:COMPUTERNAME
            NoOplog = $env:SWEEPR_NO_OPLOG; DryRun = $env:SWEEPR_DRY_RUN
            LogFile = $script:SweeprOperationsLogFile; LogStarted = $script:SweeprOperationsLogStarted
            ConfigPath = $script:Config.ConfigPath; CachePath = $script:Config.CachePath; Exit = $script:CheckExitCode
        }
        $env:USERPROFILE = 'C:\Users\Alice'
        $env:USERNAME = 'Alice'
        $env:COMPUTERNAME = 'CONTOSO-PC01'
        $env:SWEEPR_NO_OPLOG = $null
        $env:SWEEPR_DRY_RUN = $null
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:ConfigDir = Join-Path $root 'config'
        $script:CacheDir = Join-Path $root 'cache'
        [void][IO.Directory]::CreateDirectory($script:ConfigDir)
        [void][IO.Directory]::CreateDirectory($script:CacheDir)
        $script:Config.ConfigPath = $script:ConfigDir
        $script:Config.CachePath = $script:CacheDir
        $script:SweeprOperationsLogFile = Join-Path $script:ConfigDir 'operations.log'
        $script:SweeprOperationsLogStarted = $false
        Set-DryRunMode -Enabled $false

        $script:IsAdmin = $true
        $script:AsJson = $false
        $script:Seen = [System.Collections.Generic.List[string]]::new()
        $script:Order = [System.Collections.Generic.List[string]]::new()
        $script:Transcript = [System.Collections.Generic.List[string]]::new()
        $script:HostBuffer = ''
        $script:PreviewArgs = $null
        $script:PurgeArgs = $null
        $script:InventoryCatalog = $null
        $script:HookArgs = $null
        $script:HookResult = 'C:\Users\Alice\AppData\Local\Temp\sweepr-check-2026-10-25.html'
        $script:HookFails = $false
        $script:Fail = @{ Clean = $null; Apps = $null; System = $null; Projects = $null }
        $script:CheckExitCode = 0
        Set-DefaultData

        Mock Test-IsAdmin { return $script:IsAdmin }
        Mock Test-CheckOutputAsJson { return $script:AsJson }
        Mock Get-CheckVersion { return '9.8.7' }
        Mock Write-Host {
            $text = ($Object | ForEach-Object { [string]$_ }) -join ' '
            $script:HostBuffer += $text
            if (-not $NoNewline) {
                $script:Transcript.Add($script:HostBuffer)
                $script:HostBuffer = ''
            }
        }
        Mock Get-SweeprCleanPreview {
            $script:Order.Add('Clean')
            $script:Seen.Add("Clean dry=$(Test-DryRunMode) oplog=$($env:SWEEPR_NO_OPLOG)")
            $script:PreviewArgs = @{
                System = $System.IsPresent; Skip = $SkipExternalTools.IsPresent; GameMedia = $GameMedia.IsPresent; GpuShaders = $GpuShaders.IsPresent
            }
            if ($script:Fail.Clean) { throw $script:Fail.Clean }
            return $script:CleanData
        }
        Mock Get-SweeprFeatureInventory {
            $script:InventoryCatalog = $Catalog
            $script:Order.Add('Apps')
            $script:Seen.Add("Apps dry=$(Test-DryRunMode) oplog=$($env:SWEEPR_NO_OPLOG)")
            if ($script:Fail.Apps) { throw $script:Fail.Apps }
            return $script:AppsData
        }
        Mock Get-SweeprHealth {
            $script:Order.Add('System')
            $script:Seen.Add("System dry=$(Test-DryRunMode) oplog=$($env:SWEEPR_NO_OPLOG)")
            if ($script:Fail.System) { throw $script:Fail.System }
            return $script:HealthData
        }
        Mock Get-SweeprPurgePreview {
            $script:Order.Add('Projects')
            $script:Seen.Add("Projects dry=$(Test-DryRunMode) oplog=$($env:SWEEPR_NO_OPLOG)")
            $script:PurgeArgs = @{
                SearchPaths = $SearchPaths; MaxDepth = $MaxDepth; MaxSecondsPerRoot = $MaxSecondsPerRoot
                MaxTotalSeconds = $MaxTotalSeconds; MaxSizeFiles = $MaxSizeFiles
            }
            if ($script:Fail.Projects) { throw $script:Fail.Projects }
            return $script:PurgeData
        }
        Remove-HookStub
        if (-not $SkipHook) {
            function global:Invoke-SweeprCheckReport { param($Result, [switch]$NoOpen) throw 'stub of the F-03c hook' }
            Mock Invoke-SweeprCheckReport {
                $script:Order.Add('Report')
                $script:Seen.Add("Report dry=$(Test-DryRunMode) oplog=$($env:SWEEPR_NO_OPLOG)")
                $script:HookArgs = @{ Result = $Result; NoOpen = [bool]$NoOpen.IsPresent }
                if ($script:HookFails) { throw 'report failed for C:\Users\Alice on CONTOSO-PC01' }
                return $script:HookResult
            }
        }
        Mock Write-SweeprOperation { }
        foreach ($name in $script:ChangingCommands) { Mock $name ([scriptblock]::Create("throw '$name must not run in sw check'")) }
    }

    function script:Restore-CheckEnvironment {
        Remove-HookStub
        Set-DryRunMode -Enabled $false
        $env:USERPROFILE = $script:Saved.UserProfile
        $env:USERNAME = $script:Saved.UserName
        $env:COMPUTERNAME = $script:Saved.ComputerName
        $env:SWEEPR_NO_OPLOG = $script:Saved.NoOplog
        $env:SWEEPR_DRY_RUN = $script:Saved.DryRun
        $script:SweeprOperationsLogFile = $script:Saved.LogFile
        $script:SweeprOperationsLogStarted = $script:Saved.LogStarted
        $script:Config.ConfigPath = $script:Saved.ConfigPath
        $script:Config.CachePath = $script:Saved.CachePath
        $script:CheckExitCode = $script:Saved.Exit
    }

    # Runs the command; returns what it wrote and its exit code. -AsJson makes the output look redirected.
    function script:Invoke-Check {
        param([hashtable]$Params = @{}, [switch]$AsJson)
        $script:AsJson = [bool]$AsJson
        $script:CheckExitCode = 0
        $output = @(Invoke-CheckCommand @Params)
        if ($script:HostBuffer) { $script:Transcript.Add($script:HostBuffer); $script:HostBuffer = '' }
        $raw = ($output | ForEach-Object { [string]$_ }) -join "`n"
        return [pscustomobject]@{
            Output = $output
            Raw = $raw
            Text = ((@($script:Transcript) + @($output | ForEach-Object { [string]$_ })) -join "`n")
            Host = (@($script:Transcript) -join "`n")
            Exit = $script:CheckExitCode
        }
    }

    function script:Get-CheckJson {
        param([hashtable]$Params = @{ Json = $true })
        $run = Invoke-Check -Params $Params -AsJson
        $json = $null
        try { $json = $run.Raw | ConvertFrom-Json } catch { $json = $null }
        return [pscustomobject]@{ Run = $run; Json = $json; Raw = $run.Raw }
    }

    # Dotted names of every property in a parsed JSON document; arrays are looked through.
    function script:Get-JsonPaths {
        param($Node, [string]$Prefix = '')
        if ($null -eq $Node) { return }
        if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
            foreach ($item in $Node) { Get-JsonPaths -Node $item -Prefix $Prefix }
            return
        }
        if ($Node -is [pscustomobject]) {
            foreach ($property in $Node.PSObject.Properties) {
                $path = if ($Prefix) { "$Prefix.$($property.Name)" } else { $property.Name }
                $path
                Get-JsonPaths -Node $property.Value -Prefix $path
            }
        }
    }

    function script:Get-HitList {
        param([int]$Count)
        # Sizes are all different and not in order: (n * 7 mod 25) + 1 MB for n = 1..Count (Count <= 25).
        foreach ($n in 1..$Count) { New-Hit 'Browser cache' "Cache $n" ("C:\Windows\Temp\hit{0:00}" -f $n) ((($n * 7) % 25 + 1) * 1MB) $n }
    }

    # Runs the real sweepr.ps1 in a child with a private profile and data folder (help and refusals only).
    function script:Invoke-SweeprChild {
        param([string[]]$Arguments)
        $profileDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($profileDir)
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
}

Describe 'sw check files and interface' {
    It 'Has bin/check.ps1 as plain ASCII' {
        Test-Path -LiteralPath $script:BinFile | Should -BeTrue
        $bytes = [IO.File]::ReadAllBytes($script:BinFile)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'Declares <Parameter> with the alias <Alias>' -ForEach @(
        @{ Parameter = 'Json'; Alias = 'json' }
        @{ Parameter = 'Report'; Alias = 'report' }
        @{ Parameter = 'NoOpen'; Alias = 'no-open' }
        @{ Parameter = 'DryRun'; Alias = 'dry-run' }
        @{ Parameter = 'DebugMode'; Alias = 'd' }
        @{ Parameter = 'ShowHelp'; Alias = 'h' }
    ) {
        $script:CheckAst | Should -Not -BeNullOrEmpty
        $declared = @($script:CheckAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $Parameter })
        $declared.Count | Should -Be 1
        $declared[0].StaticType.Name | Should -Be 'SwitchParameter'
        $aliases = @($declared[0].Attributes | Where-Object { $_.TypeName.Name -eq 'Alias' } | ForEach-Object { $_.PositionalArguments | ForEach-Object { $_.Value } })
        ($aliases + @($Parameter)) | Should -Contain $Alias
    }

    It 'Is an advanced script' {
        $script:CheckAst | Should -Not -BeNullOrEmpty
        @($script:CheckAst.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }).Count | Should -Be 1
    }

    It 'Defines <Name>' -ForEach @(
        @{ Name = 'Invoke-CheckCommand' }, @{ Name = 'Show-CheckHelp' }, @{ Name = 'Test-CheckOutputAsJson' }, @{ Name = 'Get-CheckVersion' }
    ) {
        $script:CheckAst | Should -Not -BeNullOrEmpty
        $found = $script:CheckAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
        $found | Should -Not -BeNullOrEmpty
    }

    It 'Loads the shared modules, never the update check or another command script, and calls the command from its top level' {
        $text = Get-Content -LiteralPath $script:BinFile -Raw
        foreach ($module in @('core\\base\.ps1', 'core\\file_ops\.ps1', 'core\\features\.ps1', 'core\\health\.ps1', 'clean\\preview\.ps1', 'clean\\projects\.ps1')) {
            $text | Should -Match $module
        }
        $code = $text -replace '(?m)^\s*#.*$', ''
        $code | Should -Not -Match 'update_check'
        $code | Should -Not -Match 'bin\\+(clean|purge|optimize|status|features|uninstall|analyze)\.ps1'
        $text | Should -Match 'Invoke-CheckCommand\s+-Json:\$Json'
        $text | Should -Match 'exit\s+\$script:CheckExitCode'
    }

    It 'Contains no self-elevation, restart, service, registry or file-writing cmdlet' {
        $code = (Get-Content -LiteralPath $script:BinFile -Raw) -replace '(?m)^\s*#.*$', ''
        $code | Should -Not -Match '(?i)-Verb\s+RunAs'
        $code | Should -Not -Match '(?i)\bStart-Process\b'
        $code | Should -Not -Match '(?i)\b(Restart-Computer|Stop-Computer|shutdown(\.exe)?)\b'
        $code | Should -Not -Match '(?i)\b(Set-Service|Stop-Service|Set-ItemProperty|New-ItemProperty|Remove-ItemProperty|Disable-ScheduledTask|Unregister-ScheduledTask)\b'
        $code | Should -Not -Match '(?i)\b(Remove-Item|Set-Content|Add-Content|Out-File|New-Item|Move-Item|Copy-Item)\b'
        $code | Should -Not -Match '(?i)\b(Invoke-RestMethod|Invoke-WebRequest|Start-BitsTransfer)\b'
        $code | Should -Not -Match '(?i)\b(Remove-SafeItem|Remove-SafeItems|Remove-SafeDirectoryTree|Clear-DirectoryContents)\b'
    }

    It 'Lists this test file and bin/check.ps1 for the installer inventory (sw remove removes only listed files)' {
        $install = Get-Content -LiteralPath $script:InstallFile -Raw
        $install.Contains('"tests\CheckCommand.Tests.ps1"') | Should -BeTrue
        $install.Contains('"bin\check.ps1"') | Should -BeTrue
    }
}

Describe 'sw check router and help' {
    BeforeEach { Initialize-CheckEnvironment }
    AfterEach { Restore-CheckEnvironment }

    It "Lists check in the router's validCommands" {
        $text = Get-Content -LiteralPath $script:SweeprFile -Raw
        $text | Should -Match '\$validCommands\s*=\s*@\([^)]*"check"[^)]*\)'
    }

    It 'Keeps the exit code of check (the router reads it for the same commands as for features)' {
        $text = Get-Content -LiteralPath $script:SweeprFile -Raw
        ([regex]::Matches($text, '-in @\("analyze", "status", "history", "features"[^)]*"check"')).Count | Should -BeGreaterOrEqual 2
    }

    It 'Shows sw check in the main help' {
        Show-MainHelp
        $help = $script:Transcript -join "`n"
        $help | Should -Match 'sw check\s+\S'
        $help | Should -Match 'sw check --report'
    }

    It 'Maps <Flag> to the parameter <Parameter> of bin/check.ps1' -ForEach @(
        @{ Flag = 'json'; Parameter = 'Json' }
        @{ Flag = 'report'; Parameter = 'Report' }
        @{ Flag = 'no-open'; Parameter = 'NoOpen' }
        @{ Flag = 'dry-run'; Parameter = 'DryRun' }
        @{ Flag = 'help'; Parameter = 'ShowHelp' }
        @{ Flag = 'h'; Parameter = 'ShowHelp' }
        @{ Flag = 'debug'; Parameter = 'DebugMode' }
    ) {
        $declared = (Get-Command -Name $script:BinFile -CommandType ExternalScript).Parameters
        Resolve-CommandParameterName -Parameters $declared -Flag $Flag | Should -Be $Parameter
    }

    It 'Does not know an option the router would let through by mistake' -ForEach @(
        @{ Flag = 'system' }, @{ Flag = 'all' }, @{ Flag = 'bogus' }
    ) {
        $declared = (Get-Command -Name $script:BinFile -CommandType ExternalScript).Parameters
        Resolve-CommandParameterName -Parameters $declared -Flag $Flag | Should -BeNullOrEmpty
    }

    It 'Prints the check help through sweepr.ps1 with exit code 0' {
        $result = Invoke-SweeprChild -Arguments @('check', '--help')
        $result.ExitCode | Should -Be 0
        $result.Text | Should -Match '--report'
        $result.Text | Should -Match '--json'
        $result.Text | Should -Not -Match 'Unknown command'
    }

    It 'Refuses an unknown option through sweepr.ps1 with exit code 2' {
        $result = Invoke-SweeprChild -Arguments @('check', '--bogus')
        $result.ExitCode | Should -Be 2
        $result.Text | Should -Match 'Unknown option for sw check'
    }

    It 'Documents every option' {
        Show-CheckHelp
        $help = $script:Transcript -join "`n"
        foreach ($option in @('--json', '--report', '--no-open', '--dry-run', '--help')) { $help | Should -Match ([regex]::Escape($option)) }
        $help | Should -Match 'sw check'
        $help | Should -Match '(?i)administrator'
    }

    It 'Prints the help for -ShowHelp and reads or changes nothing' {
        $run = Invoke-Check -Params @{ ShowHelp = $true }
        $run.Text | Should -Match '--report'
        $run.Exit | Should -Be 0
        Should -Invoke Get-SweeprCleanPreview -Times 0 -Exactly
        Should -Invoke Get-SweeprPurgePreview -Times 0 -Exactly
        Should -Invoke Get-SweeprHealth -Times 0 -Exactly
        Should -Invoke Get-SweeprFeatureInventory -Times 0 -Exactly
        Should -Invoke Invoke-SweeprCheckReport -Times 0 -Exactly
    }

    It 'Does not offer the update notice for check' {
        $code = (Get-Content -LiteralPath (Join-Path $script:LibDir 'core\update_check.ps1') -Raw) -replace '(?m)^\s*#.*$', ''
        $line = @($code -split "`n" | Where-Object { $_ -match '\$CommandName -notin @\(' })
        $line.Count | Should -Be 1
        $line[0] | Should -Not -Match "'check'"
    }
}

Describe 'sw check run' {
    BeforeEach { Initialize-CheckEnvironment }
    AfterEach { Restore-CheckEnvironment }

    It 'Asks each of the four sources exactly once, and the report hook not at all without --report' {
        $run = Invoke-Check
        $run.Exit | Should -Be 0
        Should -Invoke Get-SweeprCleanPreview -Times 1 -Exactly
        Should -Invoke Get-SweeprFeatureInventory -Times 1 -Exactly
        Should -Invoke Get-SweeprHealth -Times 1 -Exactly
        Should -Invoke Get-SweeprPurgePreview -Times 1 -Exactly
        Should -Invoke Invoke-SweeprCheckReport -Times 0 -Exactly
    }

    It 'Previews the cleanup without starting installed tools, with -System as administrator only' {
        $script:IsAdmin = $true
        $null = Invoke-Check
        $script:PreviewArgs.Skip | Should -BeTrue
        $script:PreviewArgs.System | Should -BeTrue
        $script:PreviewArgs.GameMedia | Should -BeFalse
        $script:PreviewArgs.GpuShaders | Should -BeFalse

        $script:IsAdmin = $false
        $script:PreviewArgs = $null
        $null = Invoke-Check
        $script:PreviewArgs.Skip | Should -BeTrue
        $script:PreviewArgs.System | Should -BeFalse
    }

    It 'Asks the feature inventory without arguments (the default catalog)' {
        $null = Invoke-Check
        Should -Invoke Get-SweeprFeatureInventory -Times 1 -Exactly
        $script:InventoryCatalog | Should -BeNullOrEmpty
    }

    It 'Bounds the project search in depth and in time per root and in total, and the size measurement' {
        $null = Invoke-Check
        $args_ = $script:PurgeArgs
        $args_.SearchPaths | Should -BeNullOrEmpty
        $args_.MaxDepth | Should -BeGreaterOrEqual 1
        $args_.MaxDepth | Should -BeLessOrEqual 4
        $args_.MaxSecondsPerRoot | Should -BeGreaterOrEqual 1
        $args_.MaxSecondsPerRoot | Should -BeLessOrEqual 15
        $args_.MaxTotalSeconds | Should -BeGreaterOrEqual 1
        $args_.MaxTotalSeconds | Should -BeLessOrEqual 60
        $args_.MaxTotalSeconds | Should -BeGreaterOrEqual $args_.MaxSecondsPerRoot
        $args_.MaxSizeFiles | Should -BeGreaterOrEqual 1
        $args_.MaxSizeFiles | Should -BeLessOrEqual 50000
    }

    It 'Never elevates and never calls a changing cmdlet, as administrator or not' {
        foreach ($admin in @($true, $false)) {
            $script:IsAdmin = $admin
            $run = Invoke-Check -Params @{ Report = $true }
            $run.Exit | Should -Be 0
        }
        foreach ($name in $script:ChangingCommands) {
            Should -Invoke -CommandName $name -Times 0 -Exactly
        }
    }

    It 'Says what is missing without administrator rights' {
        $script:IsAdmin = $false
        $script:AppsData.FeaturesNeedAdmin = $true
        $run = Invoke-Check
        $run.Text | Should -Match 'Run Sweepr in an administrator PowerShell'
        $run.Text | Should -Match '(?i)system cleanup'
        $run.Text | Should -Match '(?i)optional Windows features'
    }

    It 'Gives no administrator hint to an administrator' {
        $run = Invoke-Check
        $run.Text | Should -Not -Match 'administrator PowerShell'
    }

    It 'Marks the system cleanup and optional features as not measured without administrator rights' {
        $script:IsAdmin = $false
        $script:AppsData.FeaturesNeedAdmin = $true
        $r = Get-CheckJson
        $r.Json.IsAdmin | Should -BeFalse
        $r.Json.Sections.Clean.IncludesSystem | Should -BeFalse
        $r.Json.Sections.Apps.NeedsAdmin | Should -BeTrue
        $system = @($r.Json.NotMeasured | Where-Object { $_.Section -eq 'Clean' -and $_.Name -eq 'System cleanup' })
        $system.Count | Should -Be 1
        $system[0].Reason | Should -BeExactly 'needs administrator'
        $features = @($r.Json.NotMeasured | Where-Object { $_.Section -eq 'Apps' -and $_.Name -eq 'Optional Windows features' })
        $features.Count | Should -Be 1
        $features[0].Reason | Should -BeExactly 'needs administrator'
    }

    It 'Includes the system cleanup as administrator and reports nothing missing for it' {
        $r = Get-CheckJson
        $r.Json.IsAdmin | Should -BeTrue
        $r.Json.Sections.Clean.IncludesSystem | Should -BeTrue
        $r.Json.Sections.Apps.NeedsAdmin | Should -BeFalse
        @($r.Json.NotMeasured | Where-Object { $_.Name -eq 'System cleanup' -or $_.Name -eq 'Optional Windows features' }).Count | Should -Be 0
    }
}

Describe 'sw check guarantees' {
    BeforeEach { Initialize-CheckEnvironment }
    AfterEach { Restore-CheckEnvironment }

    It 'Runs every source in dry-run mode and with the operations log off, and puts both back (before: off)' {
        Set-DryRunMode -Enabled $false
        $null = Invoke-Check -Params @{ Report = $true }
        $script:Seen.Count | Should -Be 5
        foreach ($entry in $script:Seen) {
            $entry | Should -Match 'dry=True'
            $entry | Should -Match 'oplog=1$'
        }
        Test-DryRunMode | Should -BeFalse
        $env:SWEEPR_NO_OPLOG | Should -BeNullOrEmpty
    }

    It 'Puts the dry-run mode and the log switch back to what they were (before: on / set)' {
        Set-DryRunMode -Enabled $true
        $env:SWEEPR_NO_OPLOG = '0'
        $null = Invoke-Check
        Test-DryRunMode | Should -BeTrue
        $env:SWEEPR_NO_OPLOG | Should -BeExactly '0'
    }

    It 'Does not leave SWEEPR_DRY_RUN behind' {
        $env:SWEEPR_DRY_RUN = $null
        $null = Invoke-Check
        $env:SWEEPR_DRY_RUN | Should -BeNullOrEmpty
    }

    It 'Puts the modes back when an area fails' -ForEach @(
        @{ Area = 'Clean' }, @{ Area = 'Apps' }, @{ Area = 'System' }, @{ Area = 'Projects' }
    ) {
        $script:Fail[$Area] = 'boom'
        $null = Invoke-Check
        Test-DryRunMode | Should -BeFalse
        $env:SWEEPR_NO_OPLOG | Should -BeNullOrEmpty
    }

    It 'Puts the modes back when the report hook fails' {
        $script:HookFails = $true
        $null = Invoke-Check -Params @{ Report = $true }
        Test-DryRunMode | Should -BeFalse
        $env:SWEEPR_NO_OPLOG | Should -BeNullOrEmpty
    }

    It 'Writes no operations log, no update check file, no clean list and nothing else into the data folders' {
        $null = Invoke-Check -Params @{ Report = $true }
        Should -Invoke Write-SweeprOperation -Times 0 -Exactly
        Test-Path -LiteralPath (Join-Path $script:ConfigDir 'operations.log') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:CacheDir 'update-check.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:ConfigDir 'clean-list.txt') | Should -BeFalse
        @([IO.Directory]::GetFileSystemEntries($script:ConfigDir)).Count | Should -Be 0
        @([IO.Directory]::GetFileSystemEntries($script:CacheDir)).Count | Should -Be 0
    }

    It 'Starts no update lookup and shows no update notice' {
        $null = Invoke-Check
        Should -Invoke Start-SweeprUpdateCheck -Times 0 -Exactly
        Should -Invoke Show-SweeprUpdateNotice -Times 0 -Exactly
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'Does not clear the screen and does not ask anything' {
        $null = Invoke-Check
        Should -Invoke Clear-Host -Times 0 -Exactly
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'Calls no changing cmdlet, with --dry-run, --json and --no-open too' {
        $null = Invoke-Check -Params @{ DryRun = $true }
        $null = Invoke-Check -Params @{ Json = $true } -AsJson
        $null = Invoke-Check -Params @{ NoOpen = $true }
        foreach ($name in $script:ChangingCommands) {
            Should -Invoke -CommandName $name -Times 0 -Exactly
        }
    }

    It 'Treats --dry-run as accepted and without effect' {
        $plain = Get-CheckJson -Params @{ Json = $true }
        $withDryRun = Get-CheckJson -Params @{ Json = $true; DryRun = $true }
        $withDryRun.Run.Exit | Should -Be 0
        ($withDryRun.Json.Sections | ConvertTo-Json -Depth 10 -Compress) | Should -BeExactly ($plain.Json.Sections | ConvertTo-Json -Depth 10 -Compress)
        ($withDryRun.Json.NotMeasured | ConvertTo-Json -Depth 10 -Compress) | Should -BeExactly ($plain.Json.NotMeasured | ConvertTo-Json -Depth 10 -Compress)
    }
}

Describe 'sw check result' {
    BeforeEach { Initialize-CheckEnvironment }
    AfterEach { Restore-CheckEnvironment }

    It 'Has the top-level properties, the version, an ISO time and the four sections' {
        $r = Get-CheckJson
        $r.Json | Should -Not -BeNullOrEmpty
        $r.Raw | Should -Match '"Version"\s*:\s*"9\.8\.7"'
        $r.Raw | Should -Match '"GeneratedAt"\s*:\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
        $r.Json.IsAdmin | Should -BeTrue
        foreach ($area in @('Clean', 'Apps', 'System', 'Projects')) {
            $r.Json.Sections.$area | Should -Not -BeNullOrEmpty
            $r.Json.Sections.$area.Status | Should -BeExactly 'ok'
            $r.Json.Sections.$area.Reason | Should -BeNullOrEmpty
        }
    }

    It 'Has only allowlisted properties, with and without administrator rights' -ForEach @(
        @{ Admin = $true }, @{ Admin = $false }
    ) {
        $script:IsAdmin = $Admin
        $r = Get-CheckJson
        $paths = @(Get-JsonPaths -Node $r.Json | Select-Object -Unique)
        $paths.Count | Should -BeGreaterThan 30
        $unexpected = @($paths | Where-Object { $script:AllowedPaths -cnotcontains $_ })
        $unexpected | Should -BeNullOrEmpty
    }

    It 'Carries no user name, computer name, address, label, command line or description' {
        $r = Get-CheckJson
        foreach ($forbidden in @('Alice', 'CONTOSO', '10\.1\.2\.3', 'SECRET123', 'sync\.exe', 'ALICE-DATA', 'SN-0042', 'NTFS', 'examplepublisher', 'Example description', 'Sign-in may need this', 'Security Update', 'Go build cache')) {
            $r.Raw | Should -Not -Match $forbidden
        }
    }

    It 'Writes paths below the profile as ~\... and leaves other paths alone' {
        $r = Get-CheckJson
        $paths = @($r.Json.Sections.Clean.Top | ForEach-Object { $_.Path })
        $paths | Should -Contain '~\AppData\Local\Temp\a'
        $paths | Should -Contain '~\.cache\go-build'
        $paths | Should -Contain '~\AppData\Local\Google\Chrome\User Data\Default\Cache'
        $paths | Should -Contain 'C:\Windows\Temp\old'
    }

    It 'Matches the profile folder without regard to case and keeps a lookalike sibling' {
        $script:CleanData = New-CleanPreview -Hits @(
            (New-Hit 'User essentials' 'x' 'c:\users\ALICE\Downloads\x' 3MB)
            (New-Hit 'User essentials' 'x' 'C:\Users\Alice2\Downloads\y' 2MB)
            (New-Hit 'User essentials' 'x' 'C:\Users\Alice' 1MB)
        )
        $r = Get-CheckJson
        $paths = @($r.Json.Sections.Clean.Top | ForEach-Object { $_.Path })
        $paths | Should -Contain '~\Downloads\x'
        $paths | Should -Contain '~'
        $paths | Should -Not -Contain 'C:\Users\Alice2\Downloads\y'
        ($paths | Where-Object { $_ -like '*Downloads\y' }) | Should -Be 'C:\Users\<user>\Downloads\y'
    }

    It 'Hides the name of another user and the host and share of a network path' {
        $script:CleanData = New-CleanPreview -Hits @(
            (New-Hit 'User essentials' 'x' 'C:\Users\Bob\AppData\Local\Temp\b' 3MB)
            (New-Hit 'User essentials' 'x' '\\fileserver01\share\cache\c' 2MB)
        )
        $r = Get-CheckJson
        $r.Raw | Should -Not -Match 'Bob'
        $r.Raw | Should -Not -Match 'fileserver01'
        $paths = @($r.Json.Sections.Clean.Top | ForEach-Object { $_.Path })
        $paths | Should -Contain 'C:\Users\<user>\AppData\Local\Temp\b'
        $paths | Should -Contain '\\<host>\<share>\cache\c'
    }

    It 'Normalizes <Name>' -ForEach @(
        @{ Name = 'a redirected AppData on a file server'; In = '\\srv01\home$\Alice\AppData\Roaming\Slack\Cache'; Out = '\\<host>\<share>\<user>\AppData\Roaming\Slack\Cache' }
        @{ Name = 'a user name part in any case, anywhere'; In = 'D:\Data\aLiCe\Cache'; Out = 'D:\Data\<user>\Cache' }
        @{ Name = 'a part that only starts with the user name'; In = 'D:\Data\Alice2\Cache'; Out = 'D:\Data\Alice2\Cache' }
        @{ Name = 'an extended-length local path of the profile'; In = '\\?\C:\Users\Alice\AppData\Local\x'; Out = '~\AppData\Local\x' }
        @{ Name = 'an extended-length local path of another user'; In = '\\?\C:\Users\Bob\AppData\Local\x'; Out = 'C:\Users\<user>\AppData\Local\x' }
        @{ Name = 'an extended-length network path'; In = '\\?\UNC\srv\share\Alice\Roaming\y'; Out = '\\<host>\<share>\<user>\Roaming\y' }
        @{ Name = 'a profile path with forward slashes'; In = 'C:/Users/Alice/AppData/z'; Out = '~\AppData\z' }
        @{ Name = 'another user with forward slashes'; In = 'C:/Users/Bob/AppData/z'; Out = 'C:\Users\<user>\AppData\z' }
        @{ Name = 'a network path with forward slashes'; In = '//srv/share/Alice/z'; Out = '\\<host>\<share>\<user>\z' }
    ) {
        $script:CleanData = New-CleanPreview -Hits @((New-Hit 'User essentials' 'x' $In 3MB))
        $r = Get-CheckJson
        @($r.Json.Sections.Clean.Top)[0].Path | Should -BeExactly $Out
    }

    It 'Keeps user and computer names out of the JSON, the console and the report hook, whatever the path' {
        $paths = @(
            '\\fileserver01\home$\Alice\AppData\Roaming\Slack\Cache'
            '\\?\C:\Users\Bob\AppData\Local\x'
            '\\?\UNC\srv\share\Alice\y'
            'C:/Users/Bob/AppData/z'
            'C:\Users\Alice\AppData\Local\Temp\a'
        )
        $script:CleanData = New-CleanPreview -Hits @(foreach ($n in 0..($paths.Count - 1)) { New-Hit 'User essentials' 'x' $paths[$n] ((10 + $n) * 1MB) })
        $json = Get-CheckJson -Params @{ Json = $true; Report = $true }
        $console = Invoke-Check -Params @{ Report = $true }
        $hook = $script:HookArgs.Result | ConvertTo-Json -Depth 10
        foreach ($text in @($json.Raw, $console.Text, $hook)) {
            $text | Should -Not -Match 'Alice'
            $text | Should -Not -Match 'Bob'
            $text | Should -Not -Match 'fileserver01'
            $text | Should -Not -Match 'srv'
            $text | Should -Not -Match 'CONTOSO'
        }
    }

    It 'Sums the clean preview and groups it by cleanup section in run order' {
        $r = Get-CheckJson
        $clean = $r.Json.Sections.Clean
        [long]$clean.TotalBytes | Should -Be ([long]$script:CleanData.TotalBytes)
        [int]$clean.Count | Should -Be ([int]$script:CleanData.Count)
        @($clean.Groups | ForEach-Object { $_.Name }) | Should -Be @('User essentials', 'Browser cache', 'Developer tools')
        [long]@($clean.Groups)[0].TotalBytes | Should -Be ([long](300MB))
        [int]@($clean.Groups)[0].Count | Should -Be 45
        @($clean.Top).Count | Should -Be 4
        @($clean.Top)[0].Section | Should -BeExactly 'Developer tools'
    }

    It 'Lists only the 20 biggest hits, biggest first, and still sums all of them' {
        $script:CleanData = New-CleanPreview -Hits @(Get-HitList -Count 25)
        $r = Get-CheckJson
        $expected = @($script:CleanData.Hits | Sort-Object -Property SizeBytes -Descending | Select-Object -First 20 | ForEach-Object { [long]$_.SizeBytes })
        $actual = @($r.Json.Sections.Clean.Top | ForEach-Object { [long]$_.SizeBytes })
        $actual.Count | Should -Be 20
        ($actual -join ',') | Should -BeExactly ($expected -join ',')
        [long]$r.Json.Sections.Clean.TotalBytes | Should -Be ([long]$script:CleanData.TotalBytes)
        [int]$r.Json.Sections.Clean.Count | Should -Be 325
    }

    It 'Describes the apps and features with id, kind and title only' {
        $r = Get-CheckJson
        $apps = $r.Json.Sections.Apps
        [int]$apps.Count | Should -Be 3
        @($apps.Items | ForEach-Object { $_.Id }) | Should -Be @('app.example', 'app.other', 'feature.legacy')
        @($apps.Items)[2].Kind | Should -BeExactly 'OptionalFeature'
        @($apps.Items)[0].Title | Should -BeExactly 'Example App'
    }

    It 'Shows disks without labels, memory, uptime, updates and startup entries without command lines' {
        $r = Get-CheckJson
        $system = $r.Json.Sections.System
        $drive = @($system.Disks.Drives)[0]
        $drive.Drive | Should -BeExactly 'C:'
        [long]$drive.FreeBytes | Should -Be ([long](120GB))
        [long]$drive.SizeBytes | Should -Be ([long](500GB))
        $drive.Health | Should -BeExactly 'Healthy'
        $drive.IsSystem | Should -BeTrue
        $system.Memory.UsedPercent | Should -Be 62.5
        [long]$system.Memory.TotalBytes | Should -Be ([long](16GB))
        $system.Uptime.UptimeDays | Should -Be 5.2
        $r.Raw | Should -Match '"LastBoot"\s*:\s*"2026-10-20T08:00:00'
        $r.Raw | Should -Match '"LastInstalledOn"\s*:\s*"2026-10-14T'
        @($system.Updates.Recent)[0].Id | Should -BeExactly 'KB5000001'
        [int]$system.PendingUpdates.Total | Should -Be 2
        [int]$system.PendingUpdates.Important | Should -Be 1
        [int]$system.Startup.Count | Should -Be 3
        @($system.Startup.Entries | ForEach-Object { "$($_.Name)|$($_.Source)" }) | Should -Be @('ExampleSync|HKCU Run', 'Helper|HKLM Run', 'start.lnk|Startup folder')
    }

    It 'Marks a health part that could not be read as not measured, with a cleaned reason and no invented value' {
        $script:HealthData.Memory = [pscustomobject]@{ Measured = $false; Reason = 'Access denied on CONTOSO-PC01 for C:\Users\Alice\x'; TotalBytes = $null; FreeBytes = $null; UsedBytes = $null; UsedPercent = $null }
        $script:HealthData.NotMeasured = @([pscustomobject]@{ Name = 'Memory'; Reason = 'Access denied on CONTOSO-PC01 for C:\Users\Alice\x' })
        $r = Get-CheckJson
        $r.Json.Sections.System.Status | Should -BeExactly 'ok'
        $r.Json.Sections.System.Memory.Measured | Should -BeFalse
        $r.Json.Sections.System.Memory.TotalBytes | Should -BeNullOrEmpty
        $r.Json.Sections.System.Memory.UsedPercent | Should -BeNullOrEmpty
        $entry = @($r.Json.NotMeasured | Where-Object { $_.Section -eq 'System' -and $_.Name -eq 'Memory' })
        $entry.Count | Should -Be 1
        $script:ReasonList | Should -Contain $entry[0].Reason
        $r.Raw | Should -Not -Match 'Alice|CONTOSO|Access denied'
    }

    It 'Keeps the tool names of the preview as not measured with the reason external tool' {
        $r = Get-CheckJson
        $tools = @($r.Json.NotMeasured | Where-Object { $_.Section -eq 'Clean' -and $_.Reason -eq 'external tool' } | ForEach-Object { $_.Name })
        $tools | Should -Be @('npm', 'pip')
    }

    It 'Uses only reasons from the fixed list, whatever the sources say' {
        $script:CleanData.NotMeasured = @(
            [pscustomobject]@{ Section = 'Cleanup'; Name = 'Cleanup'; Reason = 'error: Cannot access C:\Users\Alice\AppData for CONTOSO-PC01' }
            [pscustomobject]@{ Section = 'Developer tools'; Name = 'go'; Reason = 'external tool' }
            [pscustomobject]@{ Section = 'X'; Name = 'Other'; Reason = 'something about C:\Users\Alice' }
            [pscustomobject]@{ Section = 'System cleanup'; Name = 'System cleanup'; Reason = 'needs administrator' }
        )
        $script:HealthData.PendingUpdates = [pscustomobject]@{ Measured = $false; Reason = 'COM failed on CONTOSO-PC01'; Total = $null; Important = $null }
        $script:HealthData.NotMeasured = @([pscustomobject]@{ Name = 'PendingUpdates'; Reason = 'COM failed on CONTOSO-PC01' })
        $r = Get-CheckJson
        $entries = @($r.Json.NotMeasured)
        $entries.Count | Should -BeGreaterOrEqual 5
        foreach ($entry in $entries) { $script:ReasonList | Should -Contain $entry.Reason }
        @($entries | Where-Object { $_.Name -eq 'Cleanup' })[0].Reason | Should -BeExactly 'error'
        @($entries | Where-Object { $_.Name -eq 'go' })[0].Reason | Should -BeExactly 'external tool'
        @($entries | Where-Object { $_.Name -eq 'Other' })[0].Reason | Should -BeExactly 'not available'
        @($entries | Where-Object { $_.Name -eq 'System cleanup' })[0].Reason | Should -BeExactly 'needs administrator'
        $r.Raw | Should -Not -Match 'Alice|CONTOSO|Cannot access|COM failed'
    }

    It 'Summarizes projects, lists the 20 biggest, and never shows the raw path' {
        $projects = @(foreach ($n in 1..25) { New-Project ("~\Code\p{0:00}" -f $n) ((($n * 7) % 25 + 1) * 1MB) })
        $script:PurgeData = New-PurgePreview -Projects $projects
        $r = Get-CheckJson
        $p = $r.Json.Sections.Projects
        [int]$p.Count | Should -Be 25
        [long]$p.TotalBytes | Should -Be ([long]$script:PurgeData.TotalBytes)
        $p.Complete | Should -BeTrue
        $p.TimedOut | Should -BeFalse
        [int]$p.SkippedUnverified | Should -Be 0
        $expected = @($projects | Sort-Object -Property TotalBytes -Descending | Select-Object -First 20 | ForEach-Object { [long]$_.TotalBytes })
        $actual = @($p.Top | ForEach-Object { [long]$_.TotalBytes })
        $actual.Count | Should -Be 20
        ($actual -join ',') | Should -BeExactly ($expected -join ',')
        @($p.Top)[0].Path | Should -Match '^~\\Code\\p\d\d$'
        @($p.Top)[0].Name | Should -Match '^p\d\d$'
        $r.Raw | Should -Not -Match 'Alice'
        $r.Raw | Should -Not -Match 'node_modules'
    }

    It 'Cleans a project label that still holds the profile path' {
        $project = New-Project '~\Code\app' 5MB
        $project.DisplayPath = 'C:\Users\Alice\Code\raw'
        $script:PurgeData = New-PurgePreview -Projects @($project)
        $r = Get-CheckJson
        @($r.Json.Sections.Projects.Top)[0].Path | Should -BeExactly '~\Code\raw'
        $r.Raw | Should -Not -Match 'Alice'
    }

    It 'Says a project search that ran out of time is incomplete, as a lower bound' {
        $script:PurgeData = New-PurgePreview -Projects @((New-Project '~\Code\app' 800MB $false)) -Complete $false -TimedOut $true
        $r = Get-CheckJson
        $r.Json.Sections.Projects.Complete | Should -BeFalse
        $r.Json.Sections.Projects.TimedOut | Should -BeTrue
        $entry = @($r.Json.NotMeasured | Where-Object { $_.Section -eq 'Projects' })
        $entry.Count | Should -Be 1
        $entry[0].Name | Should -BeExactly 'Project artifacts'
        $entry[0].Reason | Should -BeExactly 'time limit'
    }

    It 'Says an unconfirmed project search is incomplete' {
        $script:PurgeData = New-PurgePreview -Projects @((New-Project '~\Code\app' 800MB)) -Complete $false -Skipped 2
        $r = Get-CheckJson
        $r.Json.Sections.Projects.Complete | Should -BeFalse
        $r.Json.Sections.Projects.TimedOut | Should -BeFalse
        [int]$r.Json.Sections.Projects.SkippedUnverified | Should -Be 2
        $entry = @($r.Json.NotMeasured | Where-Object { $_.Section -eq 'Projects' })
        $entry.Count | Should -Be 1
        $entry[0].Reason | Should -BeExactly 'incomplete'
    }

    It 'Reports no project entry as not measured when the search was complete' {
        $r = Get-CheckJson
        @($r.Json.NotMeasured | Where-Object { $_.Section -eq 'Projects' }).Count | Should -Be 0
    }

    It 'Keeps one-element and empty lists as JSON arrays' {
        $script:CleanData = New-CleanPreview -Hits @((New-Hit 'User essentials' 'x' 'C:\Windows\Temp\only' 1MB)) -NotMeasured @()
        $script:AppsData = [pscustomobject]@{ Items = @((New-AppItem 'app.example' 'App' 'Example App')); FeaturesNeedAdmin = $false }
        $health = New-HealthData
        $health.Startup.Entries = @($health.Startup.Entries[0])
        $health.Startup.Count = 1
        $health.Updates.Recent = @()
        $script:HealthData = $health
        $script:PurgeData = New-PurgePreview -Projects @((New-Project '~\Code\app' 5MB))
        $r = Get-CheckJson
        # Top occurs twice (Clean and Projects); a count, because one array hides a flattened other.
        foreach ($case in @(@('Groups', 1), @('Top', 2), @('Items', 1), @('Drives', 1), @('Entries', 1), @('Recent', 1), @('NotMeasured', 1))) {
            ([regex]::Matches($r.Raw, '"' + $case[0] + '"\s*:\s*\[')).Count | Should -Be $case[1]
        }
    }

    It 'Gives the report hook the same data as the JSON document' {
        $r = Get-CheckJson -Params @{ Json = $true; Report = $true; NoOpen = $true }
        $script:HookArgs | Should -Not -BeNullOrEmpty
        $fromHook = $script:HookArgs.Result | ConvertTo-Json -Depth 10 -Compress | ConvertFrom-Json | ConvertTo-Json -Depth 10 -Compress
        $fromJson = $r.Json | ConvertTo-Json -Depth 10 -Compress
        $fromHook | Should -BeExactly $fromJson
    }
}

Describe 'sw check console' {
    BeforeEach { Initialize-CheckEnvironment }
    AfterEach { Restore-CheckEnvironment }

    It 'Writes a short summary per area and writes nothing to the success stream' {
        $run = Invoke-Check
        $run.Exit | Should -Be 0
        $run.Output.Count | Should -Be 0
        $text = $run.Host
        $text | Should -Match ('Cleanup potential:\s+' + [regex]::Escape((Format-ByteSize $script:CleanData.TotalBytes)) + ' in 845 files')
        $text | Should -Match 'Apps and features:\s+3 can be removed with sw features'
        $text | Should -Match 'System health:'
        $text | Should -Match ('Disk C:\s+' + [regex]::Escape((Format-ByteSize (120GB))) + ' free of ' + [regex]::Escape((Format-ByteSize (500GB))))
        $text | Should -Match 'Memory:\s+62\.5% used'
        $text | Should -Match 'Uptime:\s+5\.2 days'
        $text | Should -Match 'Startup programs:\s+3'
        $text | Should -Match ('Project artifacts:\s+' + [regex]::Escape((Format-ByteSize (1200MB))) + ' in 3 projects')
        $text | Should -Match 'Nothing was changed'
    }

    It 'Lists what was not measured' {
        $run = Invoke-Check
        $run.Host | Should -Match 'Not measured:.*npm'
        $run.Host | Should -Match 'Not measured:.*pip'
    }

    It 'Says a project result is a lower bound when the search was incomplete' {
        $script:PurgeData = New-PurgePreview -Projects @((New-Project '~\Code\app' 800MB $false)) -Complete $false -TimedOut $true
        $run = Invoke-Check
        $run.Host | Should -Match 'Project artifacts:\s+at least'
        $run.Host | Should -Match '(?i)incomplete'
    }

    It 'Shows the report path when the hook returned one, after the summary' {
        $run = Invoke-Check -Params @{ Report = $true }
        $run.Host | Should -Match 'Report:\s+C:\\Users\\Alice\\AppData\\Local\\Temp\\sweepr-check-2026-10-25\.html'
        $run.Host.IndexOf('Report:') | Should -BeGreaterThan $run.Host.IndexOf('Project artifacts:')
    }

    It 'Does not write the report line without --report' {
        $run = Invoke-Check
        $run.Host | Should -Not -Match 'Report:'
    }

    It 'Shows the summary and no JSON for --json on a console' {
        $run = Invoke-Check -Params @{ Json = $true }
        $run.Output.Count | Should -Be 0
        $run.Host | Should -Match 'Cleanup potential:'
    }

    It 'Shows the summary and no JSON for a redirected output without --json' {
        $run = Invoke-Check -AsJson
        $run.Output.Count | Should -Be 0
        $run.Host | Should -Match 'Cleanup potential:'
    }
}

Describe 'sw check --json' {
    BeforeEach { Initialize-CheckEnvironment }
    AfterEach { Restore-CheckEnvironment }

    It 'Writes exactly one JSON document to the success stream when the output is redirected' {
        $run = Invoke-Check -Params @{ Json = $true } -AsJson
        $run.Exit | Should -Be 0
        $run.Output.Count | Should -Be 1
        { $run.Raw | ConvertFrom-Json } | Should -Not -Throw
        ($run.Raw | ConvertFrom-Json).Sections.Clean.Status | Should -BeExactly 'ok'
    }

    It 'Never calls Write-Host, as administrator or not, ok or failing' {
        $null = Invoke-Check -Params @{ Json = $true } -AsJson
        $script:IsAdmin = $false
        $script:Fail.Projects = 'boom'
        $null = Invoke-Check -Params @{ Json = $true } -AsJson
        $null = Invoke-Check -Params @{ Json = $true; Report = $true } -AsJson
        Should -Invoke Write-Host -Times 0 -Exactly
    }

    It 'Keeps the document pure when --report is given too' {
        $run = Invoke-Check -Params @{ Json = $true; Report = $true } -AsJson
        $run.Output.Count | Should -Be 1
        $run.Raw | Should -Not -Match 'sweepr-check-2026'
        { $run.Raw | ConvertFrom-Json } | Should -Not -Throw
        Should -Invoke Invoke-SweeprCheckReport -Times 1 -Exactly
    }
}

Describe 'sw check --report' {
    BeforeEach { Initialize-CheckEnvironment }
    AfterEach { Restore-CheckEnvironment }

    It 'Calls the report hook once, after all four areas, with the result' {
        $run = Invoke-Check -Params @{ Report = $true }
        $run.Exit | Should -Be 0
        Should -Invoke Invoke-SweeprCheckReport -Times 1 -Exactly
        $script:Order[$script:Order.Count - 1] | Should -BeExactly 'Report'
        @($script:Order | Sort-Object) | Should -Be @('Apps', 'Clean', 'Projects', 'Report', 'System')
        $script:HookArgs.Result.Version | Should -BeExactly '9.8.7'
        $script:HookArgs.Result.Sections.Clean.Status | Should -BeExactly 'ok'
    }

    It 'Opens by default and passes -NoOpen to the hook for --no-open' {
        $null = Invoke-Check -Params @{ Report = $true }
        $script:HookArgs.NoOpen | Should -BeFalse
        $null = Invoke-Check -Params @{ Report = $true; NoOpen = $true }
        $script:HookArgs.NoOpen | Should -BeTrue
    }

    It 'Does not call the hook for --no-open alone' {
        $run = Invoke-Check -Params @{ NoOpen = $true }
        $run.Exit | Should -Be 0
        Should -Invoke Invoke-SweeprCheckReport -Times 0 -Exactly
    }

    It 'Hands the hook the allowlisted result only' {
        $null = Invoke-Check -Params @{ Report = $true }
        $text = $script:HookArgs.Result | ConvertTo-Json -Depth 10
        foreach ($forbidden in @('Alice', 'CONTOSO', '10\.1\.2\.3', 'SECRET123', 'sync\.exe', 'ALICE-DATA')) {
            $text | Should -Not -Match $forbidden
        }
    }

    It 'Ends with exit code 1 and a message when the hook throws, after the summary, and does not leak the error text' {
        $script:HookFails = $true
        $run = Invoke-Check -Params @{ Report = $true }
        $run.Exit | Should -Be 1
        $run.Host | Should -Match 'Cleanup potential:'
        $run.Host | Should -Match '(?i)report'
        $run.Host | Should -Not -Match 'CONTOSO'
    }

    It 'Keeps exit code 0 when the report works' {
        (Invoke-Check -Params @{ Report = $true }).Exit | Should -Be 0
    }
}

Describe 'sw check without the report hook' {
    BeforeEach { Initialize-CheckEnvironment -SkipHook }
    AfterEach { Restore-CheckEnvironment }

    It 'Really has no hook function' {
        Get-Command -Name Invoke-SweeprCheckReport -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'Does not crash, says the report is not available in this version and ends with exit code 1' {
        $run = Invoke-Check -Params @{ Report = $true }
        $run.Exit | Should -Be 1
        $run.Host | Should -Match 'Cleanup potential:'
        $run.Host | Should -Match ([regex]::Escape('The report is not available in this version.'))
        $run.Host | Should -Not -Match 'could not be created'
    }

    It 'Says nothing about the report in JSON mode and still ends with exit code 1' {
        $run = Invoke-Check -Params @{ Json = $true; Report = $true } -AsJson
        $run.Exit | Should -Be 1
        { $run.Raw | ConvertFrom-Json } | Should -Not -Throw
        Should -Invoke Write-Host -Times 0 -Exactly
    }

    It 'Does not mind the missing hook without --report' {
        $run = Invoke-Check
        $run.Exit | Should -Be 0
        $run.Host | Should -Not -Match 'not available in this version'
    }
}

Describe 'sw check when an area fails' {
    BeforeEach { Initialize-CheckEnvironment }
    AfterEach { Restore-CheckEnvironment }

    It 'Marks <Area> as error, runs the others, and ends with exit code 0' -ForEach @(
        @{ Area = 'Clean' }, @{ Area = 'Apps' }, @{ Area = 'System' }, @{ Area = 'Projects' }
    ) {
        $script:Fail[$Area] = 'Access denied on CONTOSO-PC01 for C:\Users\Alice\secret'
        $r = Get-CheckJson
        $r.Run.Exit | Should -Be 0
        $r.Json | Should -Not -BeNullOrEmpty
        $failed = $r.Json.Sections.$Area
        $failed.Status | Should -BeExactly 'error'
        $failed.Reason | Should -BeExactly 'error'
        @($failed.PSObject.Properties.Name | Sort-Object) | Should -Be @('Reason', 'Status')
        foreach ($other in @('Clean', 'Apps', 'System', 'Projects') | Where-Object { $_ -ne $Area }) {
            $r.Json.Sections.$other.Status | Should -BeExactly 'ok'
        }
        @($script:Order | Sort-Object) | Should -Be @('Apps', 'Clean', 'Projects', 'System')
        $r.Raw | Should -Not -Match 'Alice|CONTOSO|secret|Access denied'
    }

    It 'Shows <Area> as error in the console summary and leaves the error text out' -ForEach @(
        @{ Area = 'Clean'; Label = 'Cleanup potential' }
        @{ Area = 'Apps'; Label = 'Apps and features' }
        @{ Area = 'System'; Label = 'System health' }
        @{ Area = 'Projects'; Label = 'Project artifacts' }
    ) {
        $script:Fail[$Area] = 'Access denied on CONTOSO-PC01 for C:\Users\Alice\secret'
        $run = Invoke-Check
        $run.Exit | Should -Be 0
        $run.Host | Should -Match ($Label + ':\s+error')
        $run.Host | Should -Not -Match 'CONTOSO|secret|Access denied'
        $run.Host | Should -Match 'Nothing was changed'
    }

    It 'Still ends with exit code 0 when every area fails, and still reports' {
        foreach ($area in @('Clean', 'Apps', 'System', 'Projects')) { $script:Fail[$area] = 'boom' }
        $r = Get-CheckJson -Params @{ Json = $true; Report = $true }
        $r.Run.Exit | Should -Be 0
        foreach ($area in @('Clean', 'Apps', 'System', 'Projects')) { $r.Json.Sections.$area.Status | Should -BeExactly 'error' }
        Should -Invoke Invoke-SweeprCheckReport -Times 1 -Exactly
        Test-DryRunMode | Should -BeFalse
    }

    It 'Does not call a failed area an error when the preview only lists an error entry' {
        $script:CleanData.NotMeasured = @([pscustomobject]@{ Section = 'Cleanup'; Name = 'Cleanup'; Reason = 'error: boom' })
        $r = Get-CheckJson
        $r.Json.Sections.Clean.Status | Should -BeExactly 'ok'
        @($r.Json.NotMeasured | Where-Object { $_.Name -eq 'Cleanup' })[0].Reason | Should -BeExactly 'error'
    }
}

Describe 'sw check run through the router with the real project search' {
    It 'Runs without a PurgeUnverified (strict mode) error and returns a project result' {
        $profileDir = Join-Path $TestDrive 'routerhome'
        $project = Join-Path $profileDir 'Documents/proj'
        [void][IO.Directory]::CreateDirectory((Join-Path $project 'node_modules'))
        [IO.File]::WriteAllBytes((Join-Path $project 'package.json'), (New-Object byte[] 10))
        [IO.File]::WriteAllBytes((Join-Path $project 'node_modules/a.js'), (New-Object byte[] 100))
        foreach ($folder in @('data', 'tmp', 'local', 'roaming', 'programdata')) { [void][IO.Directory]::CreateDirectory((Join-Path $profileDir $folder)) }

        $command = '$ProgressPreference = ''SilentlyContinue''; & ''' + $script:SweeprFile.Replace("'", "''") + ''' check --json; exit $LASTEXITCODE'
        $start = New-Object System.Diagnostics.ProcessStartInfo
        $start.FileName = (Get-Process -Id $PID).Path
        $start.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.EnvironmentVariables['USERPROFILE'] = $profileDir
        $start.EnvironmentVariables['HOME'] = $profileDir
        $start.EnvironmentVariables['TEMP'] = Join-Path $profileDir 'tmp'
        $start.EnvironmentVariables['TMP'] = Join-Path $profileDir 'tmp'
        $start.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $profileDir 'local'
        $start.EnvironmentVariables['APPDATA'] = Join-Path $profileDir 'roaming'
        $start.EnvironmentVariables['ProgramData'] = Join-Path $profileDir 'programdata'
        $start.EnvironmentVariables['SWEEPR_DATA_DIR'] = Join-Path $profileDir 'data'
        $start.EnvironmentVariables['SWEEPR_NO_OPLOG'] = '1'
        $process = [System.Diagnostics.Process]::Start($start)
        try {
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(280000)) { $process.Kill(); throw 'sw check timed out' }
            [void]$stdout.Wait(5000); [void]$stderr.Wait(5000)
            $out = $stdout.Result
            $err = $stderr.Result
            $exitCode = $process.ExitCode
        }
        finally { $process.Dispose() }

        ($out + $err) | Should -Not -Match 'PurgeUnverified'
        $exitCode | Should -Be 0
        $json = $out.Substring($out.IndexOf('{')) | ConvertFrom-Json
        $json.Sections.Projects.Status | Should -BeExactly 'ok'
        # The clean area asks the Windows identity (not available off Windows), so only the project area is judged here.
    }
}
