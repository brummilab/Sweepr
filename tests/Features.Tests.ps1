# Sweepr Windows - sw features: allowlist catalog, protection lock, read-only inventory, command text
# (F-02a, design Rev 3 sections 13, 14, 15, 17). Every Windows cmdlet is mocked; nothing here changes a system.

BeforeAll {
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $script:FeaturesFile = Join-Path $script:WindowsDir "lib\core\features.ps1"

    . "$script:WindowsDir\lib\core\base.ps1"
    . $script:FeaturesFile

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
        function Remove-AppxPackage { [CmdletBinding()] param([string]$Package) }
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

    # Catalog entries may be hashtables or objects; read both the same way.
    function script:Get-Field {
        param($Object, [string]$Name)
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $null
        }
        $prop = $Object.PSObject.Properties[$Name]
        if ($prop) { return $prop.Value }
        return $null
    }
    function script:Test-Field {
        param($Object, [string]$Name)
        if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
        return [bool]$Object.PSObject.Properties[$Name]
    }

    function script:New-TestEntry {
        param([string]$Id, [string]$Kind, [string[]]$Match, [string]$Warning = $null)
        $restore = if ($Kind -eq 'App') { @{ Type = 'Store'; StoreId = $null } } else { @{ Type = 'Enable'; Feature = $Match[0] } }
        return @{ Id = $Id; Kind = $Kind; Match = $Match; Title = "Example $Id"; Description = "Example description for $Id"; Warning = $Warning; Restore = $restore }
    }

    function script:New-TestPackage {
        param([string]$Name, [string]$Version = '1.0.0.0', [string]$SignatureKind = 'Store', [string]$InstallLocation = 'C:\Program Files\WindowsApps\Example', [bool]$IsFramework = $false)
        return [pscustomobject]@{
            Name              = $Name
            PackageFullName   = "${Name}_${Version}_x64__examplepublisher"
            SignatureKind     = $SignatureKind
            InstallLocation   = $InstallLocation
            IsFramework       = $IsFramework
            IsResourcePackage = $false
            IsBundle          = $false
        }
    }
}

Describe "Features module file" {
    It "Exists at lib/core/features.ps1 and is plain ASCII" {
        Test-Path -LiteralPath $script:FeaturesFile | Should -BeTrue
        $bytes = [IO.File]::ReadAllBytes($script:FeaturesFile)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It "Uses a load guard variable like the other lib files" {
        (Get-Content -LiteralPath $script:FeaturesFile -Raw) | Should -Match 'SWEEPR_\w+_LOADED'
    }

    It "Can be dot-sourced twice without error" {
        { . $script:FeaturesFile } | Should -Not -Throw
        { . $script:FeaturesFile } | Should -Not -Throw
    }

    It "Loads on its own and brings base.ps1 along" {
        $pwshPath = (Get-Process -Id $PID).Path
        $command = ". '$($script:FeaturesFile)'; (Get-Command Get-SweeprFeatureCatalog).Name; (Get-Command Test-IsAdmin).Name"
        $out = @(& $pwshPath -NoProfile -NonInteractive -Command $command 2>&1 | ForEach-Object { "$_" })
        $out | Should -Contain 'Get-SweeprFeatureCatalog'
        $out | Should -Contain 'Test-IsAdmin'
    }

    It "Contains no state-changing cmdlet calls (read-only module)" {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:FeaturesFile, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        $forbidden = @(
            'Remove-AppxPackage', 'Remove-AppxProvisionedPackage', 'Add-AppxPackage', 'Add-AppxProvisionedPackage',
            'Disable-WindowsOptionalFeature', 'Enable-WindowsOptionalFeature', 'Remove-WindowsCapability',
            'Add-WindowsCapability', 'Remove-Item', 'Set-Item', 'Set-ItemProperty', 'New-ItemProperty',
            'Remove-ItemProperty', 'Set-Service', 'Stop-Service', 'Start-Service', 'Stop-Process', 'Start-Process',
            'Restart-Computer', 'Stop-Computer', 'Disable-ScheduledTask', 'Unregister-ScheduledTask', 'Invoke-Expression', 'iex'
        )
        $calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
        $hits = @($calls | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -and ($forbidden -contains $_) })
        $hits | Should -BeNullOrEmpty
    }
}

Describe "Feature catalog" {
    BeforeAll {
        $script:Catalog = @(Get-SweeprFeatureCatalog)
    }

    It "Returns a non-trivial fixed list" {
        $script:Catalog.Count | Should -BeGreaterThan 15
    }

    It "Returns the same ids on every call" {
        $first = @(Get-SweeprFeatureCatalog | ForEach-Object { Get-Field $_ 'Id' })
        $second = @(Get-SweeprFeatureCatalog | ForEach-Object { Get-Field $_ 'Id' })
        ($first -join '|') | Should -BeExactly ($second -join '|')
    }

    It "Allows only the kinds App and OptionalFeature" {
        foreach ($entry in $script:Catalog) {
            (Get-Field $entry 'Kind') | Should -BeIn @('App', 'OptionalFeature') -Because "entry $(Get-Field $entry 'Id')"
        }
    }

    It "Has a unique, stable id per entry that names its kind" {
        $ids = @($script:Catalog | ForEach-Object { [string](Get-Field $_ 'Id') })
        foreach ($id in $ids) { $id | Should -Match '^(app|feature)\.[a-z0-9][a-z0-9.-]*$' }
        @($ids | Select-Object -Unique).Count | Should -Be $ids.Count
        foreach ($entry in $script:Catalog) {
            $id = [string](Get-Field $entry 'Id')
            $expected = if ((Get-Field $entry 'Kind') -eq 'App') { 'app.' } else { 'feature.' }
            $id.StartsWith($expected) | Should -BeTrue -Because "$id must start with $expected"
        }
    }

    It "Has at least one exact, wildcard-free Match name per entry" {
        foreach ($entry in $script:Catalog) {
            $match = @(Get-Field $entry 'Match')
            $match.Count | Should -BeGreaterThan 0 -Because (Get-Field $entry 'Id')
            foreach ($name in $match) {
                ([string]$name) | Should -Match '^[A-Za-z0-9][A-Za-z0-9._-]*$' -Because "Match of $(Get-Field $entry 'Id') must be an exact name"
            }
        }
    }

    It "Gives every entry a title and a description" {
        foreach ($entry in $script:Catalog) {
            ([string](Get-Field $entry 'Title')).Trim() | Should -Not -BeNullOrEmpty -Because (Get-Field $entry 'Id')
            ([string](Get-Field $entry 'Description')).Trim().Length | Should -BeGreaterThan 10 -Because (Get-Field $entry 'Id')
        }
    }

    It "Gives every entry a Restore hint of the right type" {
        foreach ($entry in $script:Catalog) {
            $id = Get-Field $entry 'Id'
            $restore = Get-Field $entry 'Restore'
            $restore | Should -Not -BeNullOrEmpty -Because $id
            $type = Get-Field $restore 'Type'
            if ((Get-Field $entry 'Kind') -eq 'App') {
                $type | Should -BeExactly 'Store' -Because $id
                Test-Field $restore 'StoreId' | Should -BeTrue -Because "$id must carry a StoreId field (may be null)"
                $storeId = Get-Field $restore 'StoreId'
                if ($null -ne $storeId) { ([string]$storeId) | Should -Match '^[A-Z0-9]{12}$' -Because $id }
            } else {
                $type | Should -BeExactly 'Enable' -Because $id
                ([string](Get-Field $restore 'Feature')) | Should -BeIn @(Get-Field $entry 'Match') -Because $id
            }
        }
    }

    It "Keeps Warning optional but a string when present" {
        foreach ($entry in $script:Catalog) {
            $warning = Get-Field $entry 'Warning'
            if ($null -ne $warning) { $warning | Should -BeOfType [string] }
        }
    }

    It "Warns on the Xbox entries" {
        $xbox = @($script:Catalog | Where-Object { @(Get-Field $_ 'Match') -match '^Microsoft\.Xbox' })
        $xbox.Count | Should -BeGreaterThan 0
        foreach ($entry in $xbox) {
            ([string](Get-Field $entry 'Warning')).Trim() | Should -Not -BeNullOrEmpty -Because (Get-Field $entry 'Id')
        }
    }

    It "Offers the PowerShell 2.0 optional feature" {
        $names = @($script:Catalog | Where-Object { (Get-Field $_ 'Kind') -eq 'OptionalFeature' } | ForEach-Object { @(Get-Field $_ 'Match') })
        $names | Should -Contain 'MicrosoftWindowsPowerShellV2'
    }

    It "Leaves out the items deferred by decision E13" {
        $all = @($script:Catalog | ForEach-Object { @(Get-Field $_ 'Match') })
        foreach ($name in $all) {
            ([string]$name) | Should -Not -Match 'Teams|Copilot|OneDrive|Recall|Widget|Capability' -Because "$name is out of scope for v1"
        }
    }

    It "Never matches the protection lock (Store, Installer, Security, Get Help, Game Bar, runtimes, Hyper-V, SMB, PDF printer, WSL ...)" {
        foreach ($entry in $script:Catalog) {
            foreach ($name in @(Get-Field $entry 'Match')) {
                Test-SweeprFeatureProtected -Name ([string]$name) | Should -BeFalse -Because "$name ($(Get-Field $entry 'Id')) must not be protected"
            }
        }
    }

    It "Does not contain any name from the never-offer list" {
        $never = @(
            'Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.DesktopAppInstaller', 'Microsoft.SecHealthUI',
            'Microsoft.GetHelp', 'Microsoft.XboxGamingOverlay', 'Microsoft.MicrosoftEdge', 'Microsoft.MicrosoftEdge.Stable',
            'Microsoft.WebView2', 'Microsoft.VCLibs.140.00', 'Microsoft.NET.Native.Runtime.2.2', 'Microsoft.UI.Xaml.2.8',
            'Microsoft-Hyper-V', 'Microsoft-Hyper-V-All', 'VirtualMachinePlatform', 'HypervisorPlatform', 'Containers',
            'Microsoft-Windows-Subsystem-Linux', 'SMB1Protocol', 'SmbDirect', 'Printing-PrintToPDFServices-Features',
            'NetFx3', 'NetFx4-AdvSrvs', 'Microsoft.Windows.ShellExperienceHost'
        )
        $all = @($script:Catalog | ForEach-Object { @(Get-Field $_ 'Match') })
        foreach ($name in $never) { $all | Should -Not -Contain $name }
        foreach ($name in $all) {
            ([string]$name).StartsWith('Microsoft.Windows.', [StringComparison]::OrdinalIgnoreCase) | Should -BeFalse -Because $name
            ([string]$name) | Should -Not -Match '^(NetFx|SMB|Containers|Microsoft-Hyper-V)|VCLibs|WebView|Edge|PrintToPDF' -Because $name
        }
    }
}

Describe "Feature protection lock" {
    BeforeAll {
        $script:SavedSystemRoot = $env:SystemRoot
        $env:SystemRoot = 'C:\Windows'
    }

    AfterAll {
        $env:SystemRoot = $script:SavedSystemRoot
    }

    It "Protects the Store packages and Windows security / help / game bar by name" -ForEach @(
        @{ Name = 'Microsoft.WindowsStore' }
        @{ Name = 'Microsoft.StorePurchaseApp' }
        @{ Name = 'Microsoft.DesktopAppInstaller' }
        @{ Name = 'Microsoft.SecHealthUI' }
        @{ Name = 'Microsoft.GetHelp' }
        @{ Name = 'Microsoft.XboxGamingOverlay' }
    ) {
        Test-SweeprFeatureProtected -Name $Name | Should -BeTrue
    }

    It "Matches protected package names case-insensitively" {
        Test-SweeprFeatureProtected -Name 'microsoft.windowsstore' | Should -BeTrue
    }

    It "Protects Microsoft.Windows.* shell packages" -ForEach @(
        @{ Name = 'Microsoft.Windows.ShellExperienceHost' }
        @{ Name = 'Microsoft.Windows.StartMenuExperienceHost' }
    ) {
        Test-SweeprFeatureProtected -Name $Name | Should -BeTrue
    }

    It "Protects Edge, WebView2 and .NET / Visual C++ runtimes by application name" -ForEach @(
        @{ Name = 'Microsoft Edge' }
        @{ Name = 'Microsoft Edge WebView2' }
        @{ Name = 'Microsoft .NET Runtime' }
        @{ Name = 'Microsoft Visual C++ 2015-2022 Redistributable' }
        @{ Name = 'Windows Security' }
    ) {
        Test-SweeprFeatureProtected -Name $Name | Should -BeTrue
    }

    It "Protects the locked optional features (.NET, SMB, PDF printer, Hyper-V, VM platform, containers, WSL)" -ForEach @(
        @{ Name = 'NetFx3' }
        @{ Name = 'NetFx4-AdvSrvs' }
        @{ Name = 'SMB1Protocol' }
        @{ Name = 'SMB1Protocol-Client' }
        @{ Name = 'SmbDirect' }
        @{ Name = 'Printing-PrintToPDFServices-Features' }
        @{ Name = 'Microsoft-Hyper-V' }
        @{ Name = 'Microsoft-Hyper-V-All' }
        @{ Name = 'Microsoft-Hyper-V-Hypervisor' }
        @{ Name = 'VirtualMachinePlatform' }
        @{ Name = 'HypervisorPlatform' }
        @{ Name = 'Containers' }
        @{ Name = 'Containers-DisposableClientVM' }
        @{ Name = 'Microsoft-Windows-Subsystem-Linux' }
    ) {
        Test-SweeprFeatureProtected -Name $Name | Should -BeTrue
    }

    It "Does not protect ordinary removable apps and features" -ForEach @(
        @{ Name = 'Microsoft.BingWeather' }
        @{ Name = 'Microsoft.WindowsMaps' }
        @{ Name = 'Microsoft.WindowsFeedbackHub' }
        @{ Name = 'Microsoft.ZuneMusic' }
        @{ Name = 'MicrosoftWindowsPowerShellV2' }
        @{ Name = 'MicrosoftWindowsPowerShellV2Root' }
        @{ Name = 'WorkFolders-Client' }
        @{ Name = 'Printing-XPSServices-Features' }
        @{ Name = 'WindowsMediaPlayer' }
    ) {
        Test-SweeprFeatureProtected -Name $Name | Should -BeFalse
    }

    It "Does not protect a plain store package object" {
        $pkg = New-TestPackage -Name 'Contoso.Example'
        Test-SweeprFeatureProtected -Name 'Contoso.Example' -Package $pkg | Should -BeFalse
    }

    It "Protects framework, resource and bundle packages and system-signed ones" {
        $framework = New-TestPackage -Name 'Contoso.Runtime' -IsFramework $true
        $resource = New-TestPackage -Name 'Contoso.Lang'; $resource.IsResourcePackage = $true
        $bundle = New-TestPackage -Name 'Contoso.Bundle'; $bundle.IsBundle = $true
        $system = New-TestPackage -Name 'Contoso.Inbox' -SignatureKind 'System'
        foreach ($pkg in @($framework, $resource, $bundle, $system)) {
            Test-SweeprFeatureProtected -Name $pkg.Name -Package $pkg | Should -BeTrue -Because $pkg.Name
        }
    }

    It "Protects a package that lives under the Windows folder" {
        $pkg = New-TestPackage -Name 'Contoso.InboxApp' -InstallLocation 'C:\Windows\SystemApps\Contoso.InboxApp'
        Test-SweeprFeatureProtected -Name $pkg.Name -Package $pkg | Should -BeTrue
    }

    It "Does not treat a sibling folder with the same prefix as the Windows folder" {
        $pkg = New-TestPackage -Name 'Contoso.Example' -InstallLocation 'C:\WindowsApps2\Contoso.Example'
        Test-SweeprFeatureProtected -Name $pkg.Name -Package $pkg | Should -BeFalse
    }
}

Describe "Feature inventory" {
    BeforeAll {
        $script:SavedSystemRoot = $env:SystemRoot
        $env:SystemRoot = 'C:\Windows'
        $script:ModifyingCmdlets = @('Remove-AppxPackage', 'Remove-AppxProvisionedPackage', 'Disable-WindowsOptionalFeature', 'Enable-WindowsOptionalFeature')
    }

    AfterAll {
        $env:SystemRoot = $script:SavedSystemRoot
    }

    BeforeEach {
        $script:Packages = @{}
        $script:Provisioned = @()
        $script:ProvisionedFails = $false
        $script:Features = @{}
        $script:AppsFail = $false
        $script:FeaturesFail = $false
        $script:IsAdmin = $true

        Mock Test-IsAdmin { return $script:IsAdmin }
        Mock Get-AppxPackage {
            if ($script:AppsFail) { throw 'Access denied' }
            if ($script:Packages.ContainsKey($Name)) { return $script:Packages[$Name] }
            return $null
        }
        Mock Get-AppxProvisionedPackage {
            if ($script:ProvisionedFails) { throw 'Elevation required' }
            return $script:Provisioned
        }
        Mock Get-WindowsOptionalFeature {
            if ($script:FeaturesFail) { throw 'Elevation required' }
            if ($script:Features.ContainsKey($FeatureName)) { return $script:Features[$FeatureName] }
            return $null
        }
        Mock Remove-AppxPackage { throw 'inventory must not remove anything' }
        Mock Remove-AppxProvisionedPackage { throw 'inventory must not remove anything' }
        Mock Disable-WindowsOptionalFeature { throw 'inventory must not change features' }
        Mock Enable-WindowsOptionalFeature { throw 'inventory must not change features' }
    }

    It "Returns an object with Items and FeaturesNeedAdmin" {
        $result = Get-SweeprFeatureInventory -Catalog @(New-TestEntry -Id 'app.example' -Kind App -Match @('Contoso.Example'))
        Test-Field $result 'Items' | Should -BeTrue
        Test-Field $result 'FeaturesNeedAdmin' | Should -BeTrue
        @($result.Items).Count | Should -Be 0
        $result.FeaturesNeedAdmin | Should -BeFalse
    }

    It "Lists an installed app with the design fields" {
        $pkg = New-TestPackage -Name 'Contoso.Example' -Version '2.5.0.0'
        $script:Packages['Contoso.Example'] = $pkg
        $entry = New-TestEntry -Id 'app.example' -Kind App -Match @('Contoso.Example') -Warning 'Needed for sign-in.'
        $result = Get-SweeprFeatureInventory -Catalog @($entry)
        $items = @($result.Items)
        $items.Count | Should -Be 1
        $items[0].Id | Should -BeExactly 'app.example'
        $items[0].Kind | Should -BeExactly 'App'
        $items[0].Title | Should -BeExactly 'Example app.example'
        $items[0].Description | Should -BeExactly 'Example description for app.example'
        $items[0].Warning | Should -BeExactly 'Needed for sign-in.'
        $items[0].Target | Should -BeExactly 'Contoso.Example_2.5.0.0_x64__examplepublisher'
    }

    It "Skips apps that are not installed" {
        $result = Get-SweeprFeatureInventory -Catalog @(New-TestEntry -Id 'app.example' -Kind App -Match @('Contoso.Example'))
        @($result.Items).Count | Should -Be 0
    }

    It "Queries only exact catalog names, never other packages" {
        $script:Packages['Contoso.Other'] = New-TestPackage -Name 'Contoso.Other'
        $result = Get-SweeprFeatureInventory -Catalog @(New-TestEntry -Id 'app.example' -Kind App -Match @('Contoso.Example'))
        @($result.Items).Count | Should -Be 0
        Should -Invoke Get-AppxPackage -Times 0 -ParameterFilter { $Name -eq 'Contoso.Other' }
    }

    It "Ignores a returned package whose Name is not exactly the catalog name" {
        $script:Packages['Contoso.Example'] = New-TestPackage -Name 'Contoso.ExampleExtra'
        $result = Get-SweeprFeatureInventory -Catalog @(New-TestEntry -Id 'app.example' -Kind App -Match @('Contoso.Example'))
        @($result.Items).Count | Should -Be 0
    }

    It "Does not offer an ambiguous match (more than one package for one name)" {
        $script:Packages['Contoso.Example'] = @(
            (New-TestPackage -Name 'Contoso.Example' -Version '1.0.0.0'),
            (New-TestPackage -Name 'Contoso.Example' -Version '2.0.0.0')
        )
        $result = Get-SweeprFeatureInventory -Catalog @(New-TestEntry -Id 'app.example' -Kind App -Match @('Contoso.Example'))
        @($result.Items).Count | Should -Be 0
    }

    It "Does not offer anything when the app inventory is unreadable" {
        $script:AppsFail = $true
        $catalog = @(New-TestEntry -Id 'app.example' -Kind App -Match @('Contoso.Example'))
        { Get-SweeprFeatureInventory -Catalog $catalog } | Should -Not -Throw
        @((Get-SweeprFeatureInventory -Catalog $catalog).Items).Count | Should -Be 0
    }

    It "Does not deliver a protected package even when its name is in the catalog" {
        $script:Packages['Microsoft.WindowsStore'] = New-TestPackage -Name 'Microsoft.WindowsStore'
        $result = Get-SweeprFeatureInventory -Catalog @(New-TestEntry -Id 'app.store' -Kind App -Match @('Microsoft.WindowsStore'))
        @($result.Items).Count | Should -Be 0
    }

    It "Does not deliver a system-signed or framework package that carries a catalog name" {
        $script:Packages['Contoso.Inbox'] = New-TestPackage -Name 'Contoso.Inbox' -SignatureKind 'System'
        $script:Packages['Contoso.Runtime'] = New-TestPackage -Name 'Contoso.Runtime' -IsFramework $true
        $script:Packages['Contoso.InWindows'] = New-TestPackage -Name 'Contoso.InWindows' -InstallLocation 'C:\Windows\SystemApps\Contoso.InWindows'
        $catalog = @(
            (New-TestEntry -Id 'app.inbox' -Kind App -Match @('Contoso.Inbox')),
            (New-TestEntry -Id 'app.runtime' -Kind App -Match @('Contoso.Runtime')),
            (New-TestEntry -Id 'app.inwindows' -Kind App -Match @('Contoso.InWindows'))
        )
        $result = Get-SweeprFeatureInventory -Catalog $catalog
        @($result.Items).Count | Should -Be 0
    }

    It "Marks Provisioned true only when the provisioned list is readable and holds the app" {
        $script:Packages['Contoso.Example'] = New-TestPackage -Name 'Contoso.Example'
        $script:Provisioned = @([pscustomobject]@{ DisplayName = 'Contoso.Example'; PackageName = 'Contoso.Example_1.0.0.0_neutral_~_examplepublisher' })
        $entry = New-TestEntry -Id 'app.example' -Kind App -Match @('Contoso.Example')
        $item = @((Get-SweeprFeatureInventory -Catalog @($entry)).Items)[0]
        $item.Provisioned | Should -BeTrue
        $item.ProvisionedName | Should -BeExactly 'Contoso.Example_1.0.0.0_neutral_~_examplepublisher'
        $item.ProvisionedName | Should -Not -BeExactly $item.Target
    }

    It "Marks Provisioned false when readable but the app is not provisioned" {
        $script:Packages['Contoso.Example'] = New-TestPackage -Name 'Contoso.Example'
        $script:Provisioned = @([pscustomobject]@{ DisplayName = 'Contoso.Different'; PackageName = 'Contoso.Different_1.0.0.0_neutral_~_examplepublisher' })
        $entry = New-TestEntry -Id 'app.example' -Kind App -Match @('Contoso.Example')
        $item = @((Get-SweeprFeatureInventory -Catalog @($entry)).Items)[0]
        $item.Provisioned | Should -BeFalse
        $item.ProvisionedName | Should -BeNullOrEmpty
    }

    It "Never claims Provisioned when the provisioned list is unreadable, and still lists the app" {
        $script:Packages['Contoso.Example'] = New-TestPackage -Name 'Contoso.Example'
        $script:ProvisionedFails = $true
        $entry = New-TestEntry -Id 'app.example' -Kind App -Match @('Contoso.Example')
        $items = @((Get-SweeprFeatureInventory -Catalog @($entry)).Items)
        $items.Count | Should -Be 1
        $items[0].Provisioned | Should -Not -BeTrue
        $items[0].ProvisionedName | Should -BeNullOrEmpty
    }

    It "Does not claim Provisioned when the provisioned list has more than one entry for the app" {
        $script:Packages['Contoso.Example'] = New-TestPackage -Name 'Contoso.Example'
        $script:Provisioned = @(
            [pscustomobject]@{ DisplayName = 'Contoso.Example'; PackageName = 'Contoso.Example_1.0.0.0_neutral_~_examplepublisher' },
            [pscustomobject]@{ DisplayName = 'Contoso.Example'; PackageName = 'Contoso.Example_2.0.0.0_neutral_~_examplepublisher' }
        )
        $entry = New-TestEntry -Id 'app.example' -Kind App -Match @('Contoso.Example')
        $items = @((Get-SweeprFeatureInventory -Catalog @($entry)).Items)
        $items.Count | Should -Be 1
        $items[0].Provisioned | Should -Not -BeTrue
        $items[0].ProvisionedName | Should -BeNullOrEmpty
    }

    It "Lists an enabled optional feature by its feature name" {
        $script:Features['ExampleFeature'] = [pscustomobject]@{ FeatureName = 'ExampleFeature'; State = 'Enabled' }
        $entry = New-TestEntry -Id 'feature.example' -Kind OptionalFeature -Match @('ExampleFeature')
        $result = Get-SweeprFeatureInventory -Catalog @($entry)
        $result.FeaturesNeedAdmin | Should -BeFalse
        $items = @($result.Items)
        $items.Count | Should -Be 1
        $items[0].Id | Should -BeExactly 'feature.example'
        $items[0].Kind | Should -BeExactly 'OptionalFeature'
        $items[0].Target | Should -BeExactly 'ExampleFeature'
    }

    It "Skips optional features that are disabled or absent" {
        $script:Features['ExampleFeature'] = [pscustomobject]@{ FeatureName = 'ExampleFeature'; State = 'Disabled' }
        $catalog = @(
            (New-TestEntry -Id 'feature.example' -Kind OptionalFeature -Match @('ExampleFeature')),
            (New-TestEntry -Id 'feature.missing' -Kind OptionalFeature -Match @('MissingFeature'))
        )
        $result = Get-SweeprFeatureInventory -Catalog $catalog
        @($result.Items).Count | Should -Be 0
        $result.FeaturesNeedAdmin | Should -BeFalse
    }

    It "Reports FeaturesNeedAdmin and delivers no feature rows without administrator rights" {
        $script:IsAdmin = $false
        $script:Features['ExampleFeature'] = [pscustomobject]@{ FeatureName = 'ExampleFeature'; State = 'Enabled' }
        $result = Get-SweeprFeatureInventory -Catalog @(New-TestEntry -Id 'feature.example' -Kind OptionalFeature -Match @('ExampleFeature'))
        $result.FeaturesNeedAdmin | Should -BeTrue
        @($result.Items).Count | Should -Be 0
    }

    It "Reports FeaturesNeedAdmin when the feature query fails, without throwing" {
        $script:FeaturesFail = $true
        $entry = New-TestEntry -Id 'feature.example' -Kind OptionalFeature -Match @('ExampleFeature')
        { Get-SweeprFeatureInventory -Catalog @($entry) } | Should -Not -Throw
        $result = Get-SweeprFeatureInventory -Catalog @($entry)
        $result.FeaturesNeedAdmin | Should -BeTrue
        @($result.Items).Count | Should -Be 0
    }

    It "Still lists apps for the current user without administrator rights" {
        $script:IsAdmin = $false
        $script:Packages['Contoso.Example'] = New-TestPackage -Name 'Contoso.Example'
        $script:Features['ExampleFeature'] = [pscustomobject]@{ FeatureName = 'ExampleFeature'; State = 'Enabled' }
        $catalog = @(
            (New-TestEntry -Id 'app.example' -Kind App -Match @('Contoso.Example')),
            (New-TestEntry -Id 'feature.example' -Kind OptionalFeature -Match @('ExampleFeature'))
        )
        $result = Get-SweeprFeatureInventory -Catalog $catalog
        $result.FeaturesNeedAdmin | Should -BeTrue
        @($result.Items).Count | Should -Be 1
        @($result.Items)[0].Id | Should -BeExactly 'app.example'
    }

    It "Does not deliver a locked feature even when it is enabled and in the catalog" {
        $script:Features['Microsoft-Hyper-V-All'] = [pscustomobject]@{ FeatureName = 'Microsoft-Hyper-V-All'; State = 'Enabled' }
        $script:Features['VirtualMachinePlatform'] = [pscustomobject]@{ FeatureName = 'VirtualMachinePlatform'; State = 'Enabled' }
        $catalog = @(
            (New-TestEntry -Id 'feature.hyperv' -Kind OptionalFeature -Match @('Microsoft-Hyper-V-All')),
            (New-TestEntry -Id 'feature.vmp' -Kind OptionalFeature -Match @('VirtualMachinePlatform'))
        )
        $result = Get-SweeprFeatureInventory -Catalog $catalog
        @($result.Items).Count | Should -Be 0
    }

    It "Uses the built-in catalog by default" {
        $first = @(Get-SweeprFeatureCatalog | Where-Object { (Get-Field $_ 'Kind') -eq 'App' })[0]
        $name = @(Get-Field $first 'Match')[0]
        $script:Packages[$name] = New-TestPackage -Name $name
        $result = Get-SweeprFeatureInventory
        @($result.Items | ForEach-Object { $_.Id }) | Should -Contain (Get-Field $first 'Id')
    }

    It "Never calls a state-changing cmdlet" {
        $script:Packages['Contoso.Example'] = New-TestPackage -Name 'Contoso.Example'
        $script:Features['ExampleFeature'] = [pscustomobject]@{ FeatureName = 'ExampleFeature'; State = 'Enabled' }
        $catalog = @(
            (New-TestEntry -Id 'app.example' -Kind App -Match @('Contoso.Example')),
            (New-TestEntry -Id 'feature.example' -Kind OptionalFeature -Match @('ExampleFeature'))
        )
        { Get-SweeprFeatureInventory -Catalog $catalog } | Should -Not -Throw
        foreach ($cmdlet in $script:ModifyingCmdlets) {
            Should -Invoke $cmdlet -Times 0 -Exactly
        }
    }
}

Describe "Feature command text" {
    # Contract: one string. App = Remove-AppxPackage by full name; with -AllUsersFuture and a provisioned
    # app, the provisioned removal is appended after "; ". Features = Disable without -Remove and with -NoRestart.
    BeforeAll {
        $script:AppRow = [pscustomobject]@{
            Id = 'app.example'; Kind = 'App'; Title = 'Example'; Description = 'Example app'; Warning = $null
            Target = 'Contoso.Example_1.0.0.0_x64__examplepublisher'; Provisioned = $true; ProvisionedName = 'Contoso.Example_1.0.0.0_neutral_~_examplepublisher'
        }
        $script:AppRowPlain = [pscustomobject]@{
            Id = 'app.example'; Kind = 'App'; Title = 'Example'; Description = 'Example app'; Warning = $null
            Target = 'Contoso.Example_1.0.0.0_x64__examplepublisher'; Provisioned = $false; ProvisionedName = $null
        }
        $script:FeatureRow = [pscustomobject]@{
            Id = 'feature.example'; Kind = 'OptionalFeature'; Title = 'Example feature'; Description = 'Example'; Warning = $null
            Target = 'ExampleFeature'; Provisioned = $false; ProvisionedName = $null
        }
    }

    It "Builds the exact app removal command" {
        Get-SweeprFeatureCommand -Item $script:AppRow |
            Should -BeExactly 'Remove-AppxPackage -Package Contoso.Example_1.0.0.0_x64__examplepublisher'
    }

    It "Appends the provisioned removal for a provisioned app with -AllUsersFuture" {
        Get-SweeprFeatureCommand -Item $script:AppRow -AllUsersFuture |
            Should -BeExactly 'Remove-AppxPackage -Package Contoso.Example_1.0.0.0_x64__examplepublisher; Remove-AppxProvisionedPackage -Online -PackageName Contoso.Example_1.0.0.0_neutral_~_examplepublisher'
    }

    It "Adds no provisioned removal when the app is not provisioned" {
        Get-SweeprFeatureCommand -Item $script:AppRowPlain -AllUsersFuture |
            Should -BeExactly 'Remove-AppxPackage -Package Contoso.Example_1.0.0.0_x64__examplepublisher'
    }

    It "Uses the provisioned PackageName, never the installed FullName, for the provisioned removal" {
        $text = Get-SweeprFeatureCommand -Item $script:AppRow -AllUsersFuture
        $text | Should -Match '-PackageName Contoso\.Example_1\.0\.0\.0_neutral_~_examplepublisher$'
        $text | Should -Not -Match '-PackageName Contoso\.Example_1\.0\.0\.0_x64__'
    }

    It "Builds the exact feature disable command without -Remove and without restart" {
        Get-SweeprFeatureCommand -Item $script:FeatureRow |
            Should -BeExactly 'Disable-WindowsOptionalFeature -Online -FeatureName ExampleFeature -NoRestart'
    }

    It "Ignores -AllUsersFuture for optional features" {
        Get-SweeprFeatureCommand -Item $script:FeatureRow -AllUsersFuture |
            Should -BeExactly 'Disable-WindowsOptionalFeature -Online -FeatureName ExampleFeature -NoRestart'
    }

    It "Never produces a command that removes feature payload or restarts" {
        foreach ($row in @($script:AppRow, $script:FeatureRow)) {
            $text = Get-SweeprFeatureCommand -Item $row -AllUsersFuture
            $text | Should -Not -Match '-Remove\b'
            $text | Should -Not -Match 'Restart-Computer'
        }
    }

    It "Does not execute anything while building the text" {
        Mock Remove-AppxPackage { throw 'must not run' }
        Mock Remove-AppxProvisionedPackage { throw 'must not run' }
        Mock Disable-WindowsOptionalFeature { throw 'must not run' }
        { Get-SweeprFeatureCommand -Item $script:AppRow -AllUsersFuture } | Should -Not -Throw
        { Get-SweeprFeatureCommand -Item $script:FeatureRow } | Should -Not -Throw
        Should -Invoke Remove-AppxPackage -Times 0 -Exactly
        Should -Invoke Remove-AppxProvisionedPackage -Times 0 -Exactly
        Should -Invoke Disable-WindowsOptionalFeature -Times 0 -Exactly
    }
}
