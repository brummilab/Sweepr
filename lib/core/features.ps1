# Sweepr - Windows features module
# Allowlist catalog, protection lock, read-only inventory and command text for sw features.
# Nothing in this file changes the system: removal belongs to the command that calls it.

#Requires -Version 5.1
Set-StrictMode -Version Latest

if ((Get-Variable -Name 'SWEEPR_FEATURES_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:SWEEPR_FEATURES_LOADED) { return }
$script:SWEEPR_FEATURES_LOADED = $true

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\base.ps1"

# ============================================================================
# Protection lock
# ============================================================================

# Mirrors the protection logic of sw uninstall (bin/uninstall.ps1) without sharing
# state with it: a catalog entry that hits any of these is never offered.
$script:SweeprFeatureProtectedPackages = @(
    "Microsoft.WindowsStore"
    "Microsoft.StorePurchaseApp"
    "Microsoft.DesktopAppInstaller"
    "Microsoft.SecHealthUI"
    "Microsoft.GetHelp"
    "Microsoft.XboxGamingOverlay"
)

# Names that stand for Edge, WebView2 and the runtimes other apps load.
$script:SweeprFeatureProtectedPatterns = @(
    "Microsoft Windows"
    "Windows Feature Experience Pack"
    "Microsoft Edge"
    "Microsoft Edge WebView2"
    "Windows Security"
    "Microsoft Visual C++ *"
    "Microsoft .NET *"
    ".NET Desktop Runtime*"
    "Microsoft Update Health Tools"
    "Microsoft.MicrosoftEdge*"
    "Microsoft.Edge*"
    "*WebView2*"
    "Microsoft.VCLibs*"
    "Microsoft.NET.*"
    "Microsoft.UI.Xaml*"
    "Microsoft.WindowsAppRuntime*"
    # Optional features that other Windows parts depend on.
    "NetFx*"
    "SMB*"
    "Printing-PrintToPDF*"
    "Microsoft-Hyper-V*"
    "VirtualMachinePlatform"
    "HypervisorPlatform"
    "Containers*"
    "Microsoft-Windows-Subsystem-Linux"
)

function Get-SweeprFeatureProperty {
    param($Object, [string]$Name)

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

# Same shape as Get-NormalizedFolderPath in sw uninstall: a rooted drive path with
# no empty or dot segments, otherwise $null.
function ConvertTo-SweeprFeatureFolderPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $text = [Environment]::ExpandEnvironmentVariables($Path).Trim().Trim('"', "'").Trim()
    $text = $text.Replace('/', '\').TrimEnd('\')
    if ($text -notmatch '^[A-Za-z]:\\') { return $null }
    foreach ($segment in $text.Split('\')) {
        if ($segment -eq '' -or $segment -eq '.' -or $segment -eq '..') { return $null }
    }
    return $text
}

function Test-SweeprFeatureProtected {
    <#
    .SYNOPSIS
        True when a package or feature name (and optionally its package object) is locked.
    .DESCRIPTION
        Fails closed: an empty name, or a package whose install location cannot be read,
        counts as protected.
    #>
    param(
        [string]$Name,
        $Package
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return $true }
    $Name = $Name.Trim()

    if ($Name.StartsWith('Microsoft.Windows.', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($script:SweeprFeatureProtectedPackages -contains $Name) { return $true }
    foreach ($pattern in $script:SweeprFeatureProtectedPatterns) {
        if ($Name -like $pattern) { return $true }
    }

    if ($null -ne $Package) {
        if ((Get-SweeprFeatureProperty $Package 'IsFramework') -eq $true) { return $true }
        if ((Get-SweeprFeatureProperty $Package 'IsResourcePackage') -eq $true) { return $true }
        if ((Get-SweeprFeatureProperty $Package 'IsBundle') -eq $true) { return $true }
        if ([string](Get-SweeprFeatureProperty $Package 'SignatureKind') -eq 'System') { return $true }

        $location = ConvertTo-SweeprFeatureFolderPath -Path ([string](Get-SweeprFeatureProperty $Package 'InstallLocation'))
        $windows = ConvertTo-SweeprFeatureFolderPath -Path $env:SystemRoot
        if (-not $location -or -not $windows) { return $true }
        if ($location -eq $windows -or $location.StartsWith($windows + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

# ============================================================================
# Catalog
# ============================================================================

function New-SweeprFeatureApp {
    param([string]$Id, [string]$Name, [string]$Title, [string]$Description, [string]$Warning = $null, $StoreId = $null)

    return [pscustomobject]@{
        Id          = $Id
        Kind        = 'App'
        Match       = @($Name)
        Title       = $Title
        Description = $Description
        Warning     = $Warning
        Restore     = [pscustomobject]@{ Type = 'Store'; StoreId = $StoreId }
    }
}

function New-SweeprFeatureOptional {
    param([string]$Id, [string]$Name, [string]$Title, [string]$Description, [string]$Warning = $null)

    return [pscustomobject]@{
        Id          = $Id
        Kind        = 'OptionalFeature'
        Match       = @($Name)
        Title       = $Title
        Description = $Description
        Warning     = $Warning
        Restore     = [pscustomobject]@{ Type = 'Enable'; Feature = $Name }
    }
}

function Get-SweeprFeatureCatalog {
    <#
    .SYNOPSIS
        The fixed allowlist of apps and optional features sw features may offer.
    .DESCRIPTION
        A StoreId is entered only after it was confirmed with winget show on a real
        Windows PC; until then it stays $null and restore only points to the Store. Teams, Copilot, OneDrive, Recall, Widgets and
        capabilities are deliberately not part of this list.
    #>
    $xboxWarning = 'Xbox games, Game Pass and Minecraft sign-in may need this.'
    return @(
        (New-SweeprFeatureApp 'app.weather' 'Microsoft.BingWeather' 'Weather' 'Weather app with forecasts for your locations.' $null '9WZDNCRFJ3Q2')
        (New-SweeprFeatureApp 'app.news' 'Microsoft.BingNews' 'News' 'News app that shows headlines from Microsoft News.')
        (New-SweeprFeatureApp 'app.tips' 'Microsoft.Getstarted' 'Tips' 'Tips app with hints for getting started with Windows.')
        (New-SweeprFeatureApp 'app.office-hub' 'Microsoft.MicrosoftOfficeHub' 'Microsoft 365 (Office hub)' 'Launcher and ad surface for Microsoft 365; Office itself is not affected.')
        (New-SweeprFeatureApp 'app.solitaire' 'Microsoft.MicrosoftSolitaireCollection' 'Solitaire Collection' 'Microsoft Solitaire card games.')
        (New-SweeprFeatureApp 'app.people' 'Microsoft.People' 'People' 'Contacts app.')
        (New-SweeprFeatureApp 'app.feedback-hub' 'Microsoft.WindowsFeedbackHub' 'Feedback Hub' 'App for sending feedback and bug reports to Microsoft.')
        (New-SweeprFeatureApp 'app.maps' 'Microsoft.WindowsMaps' 'Maps' 'Maps and navigation app.')
        (New-SweeprFeatureApp 'app.movies-tv' 'Microsoft.ZuneVideo' 'Movies & TV' 'Video player and store app.')
        (New-SweeprFeatureApp 'app.skype' 'Microsoft.SkypeApp' 'Skype' 'Skype messaging app (consumer version).')
        (New-SweeprFeatureApp 'app.3d-builder' 'Microsoft.3DBuilder' '3D Builder' '3D model editor and printing app.')
        (New-SweeprFeatureApp 'app.3d-viewer' 'Microsoft.Microsoft3DViewer' '3D Viewer' 'Viewer for 3D model files.')
        (New-SweeprFeatureApp 'app.print-3d' 'Microsoft.Print3D' 'Print 3D' 'App for preparing and sending 3D prints.')
        (New-SweeprFeatureApp 'app.mixed-reality-portal' 'Microsoft.MixedReality.Portal' 'Mixed Reality Portal' 'Setup and portal app for Windows Mixed Reality headsets.')
        (New-SweeprFeatureApp 'app.phone-link' 'Microsoft.YourPhone' 'Phone Link' 'Links an Android phone or iPhone to this PC.' $null '9NMPJ99VJBWV')
        (New-SweeprFeatureApp 'app.clipchamp' 'Clipchamp.Clipchamp' 'Clipchamp' 'Video editor app.')
        (New-SweeprFeatureApp 'app.todo' 'Microsoft.Todos' 'Microsoft To Do' 'Task list app.')
        (New-SweeprFeatureApp 'app.power-automate' 'Microsoft.PowerAutomateDesktop' 'Power Automate' 'Desktop automation app for flows and macros.')
        (New-SweeprFeatureApp 'app.xbox' 'Microsoft.XboxApp' 'Xbox (legacy app)' 'Older Xbox companion app.' $xboxWarning)
        (New-SweeprFeatureApp 'app.xbox-tcui' 'Microsoft.Xbox.TCUI' 'Xbox TCUI' 'Xbox sign-in and social dialogs used by games.' $xboxWarning)
        (New-SweeprFeatureApp 'app.xbox-identity' 'Microsoft.XboxIdentityProvider' 'Xbox Identity Provider' 'Signs you in to Xbox services for games and apps.' $xboxWarning '9WZDNCRD1HKW')
        (New-SweeprFeatureApp 'app.xbox-speech' 'Microsoft.XboxSpeechToTextOverlay' 'Xbox Speech To Text Overlay' 'Speech-to-text overlay for Xbox game chat.' $xboxWarning)
        (New-SweeprFeatureOptional 'feature.powershell2' 'MicrosoftWindowsPowerShellV2' 'Windows PowerShell 2.0' 'The legacy PowerShell 2.0 engine itself, an old downgrade-attack path. Windows PowerShell 5.1 is not affected.')
        (New-SweeprFeatureOptional 'feature.powershell2-root' 'MicrosoftWindowsPowerShellV2Root' 'Windows PowerShell 2.0 (root)' 'Parent (root) feature of the PowerShell 2.0 engine; turning it off also turns off the engine. Windows PowerShell 5.1 is not affected.')
        (New-SweeprFeatureOptional 'feature.work-folders' 'WorkFolders-Client' 'Work Folders client' 'Client for syncing work files from a company Work Folders server.')
        (New-SweeprFeatureOptional 'feature.xps-services' 'Printing-XPSServices-Features' 'XPS Services' 'Microsoft XPS Document Writer for printing to XPS files; the XPS viewer is not affected.')
        (New-SweeprFeatureOptional 'feature.internet-explorer' 'Internet-Explorer-Optional-amd64' 'Internet Explorer 11' 'Legacy Internet Explorer 11 application.' 'Internet Explorer mode in Microsoft Edge depends on it and stops working.')
        (New-SweeprFeatureOptional 'feature.media-player' 'WindowsMediaPlayer' 'Windows Media Player (legacy)' 'Legacy Windows Media Player application.')
    )
}

# ============================================================================
# Inventory (read-only)
# ============================================================================

function Get-SweeprFeatureInventory {
    <#
    .SYNOPSIS
        Rows for catalog entries that are present and active on this system.
    .OUTPUTS
        Object with Items and FeaturesNeedAdmin. Anything unreadable, ambiguous or
        protected is left out rather than offered.
    #>
    param([object[]]$Catalog)

    if ($null -eq $Catalog) { $Catalog = @(Get-SweeprFeatureCatalog) }
    $Catalog = @($Catalog)

    $items = [System.Collections.Generic.List[object]]::new()
    $featuresNeedAdmin = $false
    $provisionedRead = $false
    $provisioned = @()
    $provisionedLoaded = $false
    $featureEntries = @($Catalog | Where-Object { (Get-SweeprFeatureProperty $_ 'Kind') -eq 'OptionalFeature' })

    foreach ($entry in $Catalog) {
        $kind = [string](Get-SweeprFeatureProperty $entry 'Kind')
        if ($kind -ne 'App') { continue }

        foreach ($matchName in @(Get-SweeprFeatureProperty $entry 'Match')) {
            $name = [string]$matchName
            if (Test-SweeprFeatureProtected -Name $name) { continue }

            $found = @()
            try {
                $found = @(Get-AppxPackage -Name ([WildcardPattern]::Escape($name)) -ErrorAction Stop |
                    Where-Object { $_ -and [string](Get-SweeprFeatureProperty $_ 'Name') -eq $name })
            } catch {
                continue
            }
            if ($found.Count -ne 1) { continue }
            $package = $found[0]
            if (Test-SweeprFeatureProtected -Name $name -Package $package) { continue }
            $fullName = [string](Get-SweeprFeatureProperty $package 'PackageFullName')
            if ([string]::IsNullOrWhiteSpace($fullName)) { continue }

            # The provisioned list needs administrator rights; unreadable never means provisioned.
            if (-not $provisionedLoaded) {
                $provisionedLoaded = $true
                try {
                    $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)
                    $provisionedRead = $true
                } catch {
                    $provisionedRead = $false
                }
            }
            $isProvisioned = $false
            $provisionedName = $null
            if ($provisionedRead) {
                $hits = @($provisioned | Where-Object { $_ -and [string](Get-SweeprFeatureProperty $_ 'DisplayName') -eq $name })
                if ($hits.Count -eq 1) {
                    $candidate = [string](Get-SweeprFeatureProperty $hits[0] 'PackageName')
                    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                        $isProvisioned = $true
                        $provisionedName = $candidate
                    }
                }
            }

            $items.Add([pscustomobject]@{
                Id              = [string](Get-SweeprFeatureProperty $entry 'Id')
                Kind            = 'App'
                Title           = [string](Get-SweeprFeatureProperty $entry 'Title')
                Description     = [string](Get-SweeprFeatureProperty $entry 'Description')
                Warning         = Get-SweeprFeatureProperty $entry 'Warning'
                Target          = $fullName
                Provisioned     = $isProvisioned
                ProvisionedName = $provisionedName
            })
            break
        }
    }

    if ($featureEntries.Count -gt 0) {
        $isAdmin = $false
        try { $isAdmin = [bool](Test-IsAdmin) } catch { $isAdmin = $false }
        if (-not $isAdmin) {
            $featuresNeedAdmin = $true
        } else {
            # One plain listing: a per-name query throws for names this Windows does not know
            # (removed or other-architecture features), which would hide every other feature.
            $enabled = $null
            try {
                $enabled = @(Get-WindowsOptionalFeature -Online -ErrorAction Stop | Where-Object { $_ })
            } catch {
                $featuresNeedAdmin = $true
            }
            if (-not $featuresNeedAdmin) {
                foreach ($entry in $featureEntries) {
                    foreach ($matchName in @(Get-SweeprFeatureProperty $entry 'Match')) {
                        $name = [string]$matchName
                        if (Test-SweeprFeatureProtected -Name $name) { continue }
                        # Unknown names are left out silently.
                        $hits = @($enabled | Where-Object { [string](Get-SweeprFeatureProperty $_ 'FeatureName') -eq $name })
                        if ($hits.Count -ne 1) { continue }
                        if ([string](Get-SweeprFeatureProperty $hits[0] 'State') -ne 'Enabled') { continue }

                        $items.Add([pscustomobject]@{
                            Id              = [string](Get-SweeprFeatureProperty $entry 'Id')
                            Kind            = 'OptionalFeature'
                            Title           = [string](Get-SweeprFeatureProperty $entry 'Title')
                            Description     = [string](Get-SweeprFeatureProperty $entry 'Description')
                            Warning         = Get-SweeprFeatureProperty $entry 'Warning'
                            Target          = $name
                            Provisioned     = $false
                            ProvisionedName = $null
                        })
                        break
                    }
                }
            }
        }
    }

    return [pscustomobject]@{
        Items             = @($items)
        FeaturesNeedAdmin = $featuresNeedAdmin
    }
}

# ============================================================================
# Command text (preview and log only; never executed here)
# ============================================================================

function Get-SweeprFeatureCommand {
    <#
    .SYNOPSIS
        Exact command text for an inventory row, for dry-run output and the log.
    #>
    param(
        [Parameter(Mandatory)]$Item,
        [switch]$AllUsersFuture
    )

    $kind = [string](Get-SweeprFeatureProperty $Item 'Kind')
    $target = [string](Get-SweeprFeatureProperty $Item 'Target')
    # Names are package full names or feature names; anything else could smuggle text into the log.
    if ($target -notmatch '^[A-Za-z0-9][A-Za-z0-9._~-]*$') {
        throw "Refusing to build a command for an unexpected target: $target"
    }

    if ($kind -eq 'OptionalFeature') {
        return "Disable-WindowsOptionalFeature -Online -FeatureName $target -NoRestart"
    }
    if ($kind -ne 'App') {
        throw "Unknown feature kind: $kind"
    }

    $text = "Remove-AppxPackage -Package $target"
    if ($AllUsersFuture -and (Get-SweeprFeatureProperty $Item 'Provisioned') -eq $true) {
        $provisionedName = [string](Get-SweeprFeatureProperty $Item 'ProvisionedName')
        if ($provisionedName -notmatch '^[A-Za-z0-9][A-Za-z0-9._~-]*$') {
            throw "Refusing to build a command for an unexpected provisioned package: $provisionedName"
        }
        $text += "; Remove-AppxProvisionedPackage -Online -PackageName $provisionedName"
    }
    return $text
}


# ============================================================================
# Restore list (features-removed.json) and restore command text
# ============================================================================

# Names that may reach a command line or the log: package full names, feature names,
# Store ids and catalog ids. Anything else in the file is treated as tampered.
function Test-SweeprFeatureSafeName {
    param($Value)

    if ($Value -isnot [string]) { return $false }
    # \z, not $: a trailing newline must not pass.
    return ($Value -cmatch '^[A-Za-z0-9][A-Za-z0-9._~-]*\z')
}

# The list lives in the active data folder (profile, portable or override).
function Get-SweeprFeaturesRemovedPath {
    return (Join-Path $script:Config.ConfigPath 'features-removed.json')
}

function Read-SweeprFeaturesRemoved {
    <#
    .SYNOPSIS
        Reads the restore list.
    .OUTPUTS
        Object with Ok, Items (all records in file order, valid or not) and Error.
        A missing or empty file is an empty list; anything that is not
        {"items":[ ... ]} with objects inside is unreadable (Ok = $false).
    #>
    $path = Get-SweeprFeaturesRemovedPath
    $result = [pscustomobject]@{ Ok = $true; Items = @(); Error = $null }
    try {
        if (-not [System.IO.File]::Exists($path)) { return $result }
        $raw = [System.IO.File]::ReadAllText($path)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $result }

        $document = $raw | ConvertFrom-Json -ErrorAction Stop
        $itemsProperty = $null
        if ($document -is [pscustomobject]) { $itemsProperty = $document.PSObject.Properties['items'] }
        if (-not $itemsProperty -or $itemsProperty.Value -isnot [System.Array]) {
            throw 'it does not hold an "items" list'
        }
        $items = @()
        foreach ($item in $itemsProperty.Value) {
            if ($item -isnot [pscustomobject]) { throw 'an entry is not an object' }
            # Newer PowerShell turns ISO times into dates; keep the text form so a rewrite stays stable.
            $removedAt = $item.PSObject.Properties['RemovedAt']
            if ($removedAt -and $removedAt.Value -is [datetime]) {
                $removedAt.Value = $removedAt.Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            }
            $items += $item
        }
        $result.Items = @($items)
    }
    catch {
        $result.Ok = $false
        $result.Items = @()
        $result.Error = "Cannot read the restore list $path ($($_.Exception.Message))"
    }
    return $result
}

# Writes the whole list; throws when it cannot. The new text is written beside the file and
# moved over it, so an interrupted write never leaves a half-written list.
function Save-SweeprFeaturesRemoved {
    param([object[]]$Items)

    $path = Get-SweeprFeaturesRemovedPath
    $directory = Split-Path -Parent $path
    if (-not [System.IO.Directory]::Exists($directory)) { [void][System.IO.Directory]::CreateDirectory($directory) }

    $document = [ordered]@{ version = 1; items = @($Items) }
    $json = ConvertTo-Json -InputObject $document -Depth 8
    $temp = "$path.tmp"
    try {
        [System.IO.File]::WriteAllText($temp, $json, (New-Object System.Text.UTF8Encoding($false)))
        if ([System.IO.File]::Exists($path)) { [System.IO.File]::Replace($temp, $path, [NullString]::Value) }
        else { [System.IO.File]::Move($temp, $path) }
    }
    catch {
        # Only our own temporary file is cleaned up here.
        try { if ([System.IO.File]::Exists($temp)) { [System.IO.File]::Delete($temp) } } catch { }
        throw
    }
}

function New-SweeprFeatureRemovedRecord {
    <#
    .SYNOPSIS
        The restore record for a row that is about to be removed. Restore comes from the catalog entry.
    #>
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)]$CatalogEntry, [string]$ProvisionedName)

    $kind = [string](Get-SweeprFeatureProperty $Item 'Kind')
    $target = [string](Get-SweeprFeatureProperty $Item 'Target')
    $catalogRestore = Get-SweeprFeatureProperty $CatalogEntry 'Restore'
    if ($kind -eq 'App') {
        $storeId = [string](Get-SweeprFeatureProperty $catalogRestore 'StoreId')
        $restore = [ordered]@{ Type = 'Store'; StoreId = $(if ($storeId) { $storeId } else { $null }) }
    }
    else {
        $restore = [ordered]@{ Type = 'Enable'; Feature = $target }
    }
    $record = [ordered]@{
        Id        = [string](Get-SweeprFeatureProperty $Item 'Id')
        Kind      = $kind
        Title     = [string](Get-SweeprFeatureProperty $Item 'Title')
        Target    = $target
        Restore   = $restore
        RemovedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
    if (-not [string]::IsNullOrWhiteSpace($ProvisionedName)) { $record['ProvisionedName'] = $ProvisionedName }
    return [pscustomobject]$record
}

function Add-SweeprFeatureRemovedRecord {
    <#
    .SYNOPSIS
        Appends a record unless the same Id and Target is already there.
    .OUTPUTS
        Object with Ok, Added (a new record was written) and Error. Nothing is written when the list is unreadable.
    #>
    param([Parameter(Mandatory)]$Record)

    $list = Read-SweeprFeaturesRemoved
    if (-not $list.Ok) { return [pscustomobject]@{ Ok = $false; Added = $false; Error = $list.Error } }

    $id = [string](Get-SweeprFeatureProperty $Record 'Id')
    $target = [string](Get-SweeprFeatureProperty $Record 'Target')
    foreach ($existing in $list.Items) {
        if ([string](Get-SweeprFeatureProperty $existing 'Id') -ceq $id -and [string](Get-SweeprFeatureProperty $existing 'Target') -ceq $target) {
            return [pscustomobject]@{ Ok = $true; Added = $false; Error = $null }
        }
    }
    try {
        Save-SweeprFeaturesRemoved -Items (@($list.Items) + @($Record))
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Added = $false; Error = "Cannot save the restore list $(Get-SweeprFeaturesRemovedPath) ($($_.Exception.Message))" }
    }
    return [pscustomobject]@{ Ok = $true; Added = $true; Error = $null }
}

function Remove-SweeprFeatureRemovedRecord {
    <#
    .SYNOPSIS
        Takes the records with this Id and Target out of the list; all other records stay as they are.
    #>
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Target)

    $list = Read-SweeprFeaturesRemoved
    if (-not $list.Ok) { return [pscustomobject]@{ Ok = $false; Error = $list.Error } }

    $kept = @($list.Items | Where-Object {
            -not ([string](Get-SweeprFeatureProperty $_ 'Id') -ceq $Id -and [string](Get-SweeprFeatureProperty $_ 'Target') -ceq $Target)
        })
    if ($kept.Count -eq @($list.Items).Count) { return [pscustomobject]@{ Ok = $true; Error = $null } }
    try {
        Save-SweeprFeaturesRemoved -Items $kept
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Error = "Cannot save the restore list $(Get-SweeprFeaturesRemovedPath) ($($_.Exception.Message))" }
    }
    return [pscustomobject]@{ Ok = $true; Error = $null }
}

function Test-SweeprFeatureRemovedRecord {
    <#
    .SYNOPSIS
        True when a record from the file is complete and safe to turn into a command.
    .DESCRIPTION
        The file is user-writable, so every field that reaches a command line is checked again here.
    #>
    param($Record)

    if ($null -eq $Record) { return $false }
    $kind = Get-SweeprFeatureProperty $Record 'Kind'
    $target = Get-SweeprFeatureProperty $Record 'Target'
    if (-not (Test-SweeprFeatureSafeName (Get-SweeprFeatureProperty $Record 'Id'))) { return $false }
    if (-not (Test-SweeprFeatureSafeName $target)) { return $false }

    $restore = Get-SweeprFeatureProperty $Record 'Restore'
    $type = Get-SweeprFeatureProperty $restore 'Type'
    if ($kind -ceq 'App') {
        if ($type -cne 'Store') { return $false }
        $storeId = Get-SweeprFeatureProperty $restore 'StoreId'
        if ($null -ne $storeId -and $storeId -ne '' -and -not (Test-SweeprFeatureSafeName $storeId)) { return $false }
        return $true
    }
    if ($kind -ceq 'OptionalFeature') {
        if ($type -cne 'Enable') { return $false }
        return ((Get-SweeprFeatureProperty $restore 'Feature') -ceq $target)
    }
    return $false
}

# Text for the console and the log: no control characters from a hand-edited file.
function Get-SweeprFeatureRecordTitle {
    param($Record)

    $title = ([string](Get-SweeprFeatureProperty $Record 'Title')) -replace '[\x00-\x1F\x7F]', ' '
    $title = $title.Trim()
    if (-not $title) { $title = [string](Get-SweeprFeatureProperty $Record 'Id') }
    return $title
}

function Get-SweeprFeatureWingetArguments {
    param([Parameter(Mandatory)][string]$StoreId)

    if (-not (Test-SweeprFeatureSafeName $StoreId)) { throw "Refusing to build a command for an unexpected Store id: $StoreId" }
    return @('install', '--id', $StoreId, '--source', 'msstore', '--accept-package-agreements', '--accept-source-agreements')
}

function Get-SweeprFeatureCatalogEntryForRecord {
    <#
    .SYNOPSIS
        The current catalog entry a saved record is bound to, or $null.
    .DESCRIPTION
        The restore list is user-writable, so what it asks for must also be allowed today.
        An entry needs the same Id and Kind. An optional feature also needs its Target
        (case sensitive) among the entry's Match names; an app needs the package name
        from its Target (the part before the first underscore) there.
    #>
    param([Parameter(Mandatory)]$Record, [object[]]$Catalog)

    $id = [string](Get-SweeprFeatureProperty $Record 'Id')
    $kind = [string](Get-SweeprFeatureProperty $Record 'Kind')
    $target = [string](Get-SweeprFeatureProperty $Record 'Target')
    $entries = @($Catalog | Where-Object {
            [string](Get-SweeprFeatureProperty $_ 'Id') -ceq $id -and [string](Get-SweeprFeatureProperty $_ 'Kind') -ceq $kind
        })
    if ($entries.Count -ne 1) { return $null }

    $name = if ($kind -eq 'App') { $target.Split('_')[0] } else { $target }
    $known = @(@(Get-SweeprFeatureProperty $entries[0] 'Match') | Where-Object { [string]$_ -ceq $name })
    if ($known.Count -eq 0) { return $null }
    return $entries[0]
}

# True when the catalog knows the Id of a record under another Kind: such a record is forged or stale and is never offered.
function Test-SweeprFeatureRecordKindClash {
    param([Parameter(Mandatory)]$Record, [object[]]$Catalog)

    $id = [string](Get-SweeprFeatureProperty $Record 'Id')
    $kind = [string](Get-SweeprFeatureProperty $Record 'Kind')
    $clash = @($Catalog | Where-Object {
            [string](Get-SweeprFeatureProperty $_ 'Id') -ceq $id -and [string](Get-SweeprFeatureProperty $_ 'Kind') -cne $kind
        })
    return ($clash.Count -gt 0)
}

function Get-SweeprFeatureCatalogStoreId {
    <#
    .SYNOPSIS
        The Store id of a catalog entry when it is well formed, otherwise $null. The id in the saved file is never used.
    #>
    param($CatalogEntry)

    if ($null -eq $CatalogEntry) { return $null }
    $storeId = Get-SweeprFeatureProperty (Get-SweeprFeatureProperty $CatalogEntry 'Restore') 'StoreId'
    if (Test-SweeprFeatureSafeName $storeId) { return $storeId }
    return $null
}

function Get-SweeprFeatureRestoreCommand {
    <#
    .SYNOPSIS
        Exact command text to restore a record, for the preview and the log; never executed here.
    .OUTPUTS
        The text, or $null for an app without a Store id in the current catalog entry
        (only a Store hint is possible).
    #>
    param([Parameter(Mandatory)]$Record, $CatalogEntry)

    $kind = [string](Get-SweeprFeatureProperty $Record 'Kind')
    $target = [string](Get-SweeprFeatureProperty $Record 'Target')
    if (-not (Test-SweeprFeatureSafeName $target)) { throw "Refusing to build a command for an unexpected target: $target" }

    if ($kind -eq 'OptionalFeature') {
        return "Enable-WindowsOptionalFeature -Online -FeatureName $target -NoRestart"
    }
    if ($kind -ne 'App') { throw "Unknown feature kind: $kind" }

    $storeId = Get-SweeprFeatureCatalogStoreId -CatalogEntry $CatalogEntry
    if (-not $storeId) { return $null }
    return ('winget ' + ((Get-SweeprFeatureWingetArguments -StoreId $storeId) -join ' '))
}
