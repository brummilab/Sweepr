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
        StoreId stays $null until verified on a real Windows PC; restore then only
        points to the Store. Teams, Copilot, OneDrive, Recall, Widgets and
        capabilities are deliberately not part of this list.
    #>
    $xboxWarning = 'Xbox games, Game Pass and Minecraft sign-in may need this.'
    return @(
        (New-SweeprFeatureApp 'app.weather' 'Microsoft.BingWeather' 'Weather' 'Weather app with forecasts for your locations.')
        (New-SweeprFeatureApp 'app.news' 'Microsoft.BingNews' 'News' 'News app that shows headlines from Microsoft News.')
        (New-SweeprFeatureApp 'app.tips' 'Microsoft.Getstarted' 'Tips' 'Tips app with hints for getting started with Windows.')
        (New-SweeprFeatureApp 'app.office-hub' 'Microsoft.MicrosoftOfficeHub' 'Microsoft 365 (Office hub)' 'Launcher and ad surface for Microsoft 365; Office itself is not affected.')
        (New-SweeprFeatureApp 'app.solitaire' 'Microsoft.MicrosoftSolitaireCollection' 'Solitaire Collection' 'Microsoft Solitaire card games.')
        (New-SweeprFeatureApp 'app.people' 'Microsoft.People' 'People' 'Contacts app.')
        (New-SweeprFeatureApp 'app.feedback-hub' 'Microsoft.WindowsFeedbackHub' 'Feedback Hub' 'App for sending feedback and bug reports to Microsoft.')
        (New-SweeprFeatureApp 'app.maps' 'Microsoft.WindowsMaps' 'Maps' 'Maps and navigation app.')
        (New-SweeprFeatureApp 'app.groove-music' 'Microsoft.ZuneMusic' 'Groove Music' 'Music player app.')
        (New-SweeprFeatureApp 'app.movies-tv' 'Microsoft.ZuneVideo' 'Movies & TV' 'Video player and store app.')
        (New-SweeprFeatureApp 'app.skype' 'Microsoft.SkypeApp' 'Skype' 'Skype messaging app (consumer version).')
        (New-SweeprFeatureApp 'app.3d-builder' 'Microsoft.3DBuilder' '3D Builder' '3D model editor and printing app.')
        (New-SweeprFeatureApp 'app.3d-viewer' 'Microsoft.Microsoft3DViewer' '3D Viewer' 'Viewer for 3D model files.')
        (New-SweeprFeatureApp 'app.print-3d' 'Microsoft.Print3D' 'Print 3D' 'App for preparing and sending 3D prints.')
        (New-SweeprFeatureApp 'app.mixed-reality-portal' 'Microsoft.MixedReality.Portal' 'Mixed Reality Portal' 'Setup and portal app for Windows Mixed Reality headsets.')
        (New-SweeprFeatureApp 'app.phone-link' 'Microsoft.YourPhone' 'Phone Link' 'Links an Android phone or iPhone to this PC.')
        (New-SweeprFeatureApp 'app.clipchamp' 'Clipchamp.Clipchamp' 'Clipchamp' 'Video editor app.')
        (New-SweeprFeatureApp 'app.todo' 'Microsoft.Todos' 'Microsoft To Do' 'Task list app.')
        (New-SweeprFeatureApp 'app.power-automate' 'Microsoft.PowerAutomateDesktop' 'Power Automate' 'Desktop automation app for flows and macros.')
        (New-SweeprFeatureApp 'app.xbox' 'Microsoft.XboxApp' 'Xbox (legacy app)' 'Older Xbox companion app.' $xboxWarning)
        (New-SweeprFeatureApp 'app.xbox-tcui' 'Microsoft.Xbox.TCUI' 'Xbox TCUI' 'Xbox sign-in and social dialogs used by games.' $xboxWarning)
        (New-SweeprFeatureApp 'app.xbox-identity' 'Microsoft.XboxIdentityProvider' 'Xbox Identity Provider' 'Signs you in to Xbox services for games and apps.' $xboxWarning)
        (New-SweeprFeatureApp 'app.xbox-speech' 'Microsoft.XboxSpeechToTextOverlay' 'Xbox Speech To Text Overlay' 'Speech-to-text overlay for Xbox game chat.' $xboxWarning)
        (New-SweeprFeatureOptional 'feature.powershell2' 'MicrosoftWindowsPowerShellV2' 'Windows PowerShell 2.0' 'Legacy PowerShell 2.0 engine, an old downgrade-attack path. Windows PowerShell 5.1 is not affected.')
        (New-SweeprFeatureOptional 'feature.powershell2-root' 'MicrosoftWindowsPowerShellV2Root' 'Windows PowerShell 2.0 (root)' 'Parent feature of the legacy PowerShell 2.0 engine. Windows PowerShell 5.1 is not affected.')
        (New-SweeprFeatureOptional 'feature.work-folders' 'WorkFolders-Client' 'Work Folders client' 'Client for syncing work files from a company Work Folders server.')
        (New-SweeprFeatureOptional 'feature.xps-services' 'Printing-XPSServices-Features' 'XPS Services' 'Support for printing to and viewing XPS documents.')
        (New-SweeprFeatureOptional 'feature.internet-explorer' 'Internet-Explorer-Optional-amd64' 'Internet Explorer 11' 'Legacy Internet Explorer 11 application.')
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
    $featureRows = [System.Collections.Generic.List[object]]::new()
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
        if (-not (Test-IsAdmin)) {
            $featuresNeedAdmin = $true
        } else {
            foreach ($entry in $featureEntries) {
                foreach ($matchName in @(Get-SweeprFeatureProperty $entry 'Match')) {
                    $name = [string]$matchName
                    if (Test-SweeprFeatureProtected -Name $name) { continue }
                    $feature = $null
                    try {
                        $feature = Get-WindowsOptionalFeature -Online -FeatureName $name -ErrorAction Stop
                    } catch {
                        $featuresNeedAdmin = $true
                        break
                    }
                    $feature = @($feature | Where-Object { $_ })
                    if ($feature.Count -ne 1) { continue }
                    if ([string](Get-SweeprFeatureProperty $feature[0] 'FeatureName') -ne $name) { continue }
                    if ([string](Get-SweeprFeatureProperty $feature[0] 'State') -ne 'Enabled') { continue }

                    $featureRows.Add([pscustomobject]@{
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
                if ($featuresNeedAdmin) { break }
            }
            # A failed query means the feature state is unknown: offer none of them.
            if (-not $featuresNeedAdmin) {
                foreach ($row in $featureRows) { $items.Add($row) }
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
