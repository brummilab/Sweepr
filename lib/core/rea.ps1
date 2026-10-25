# freeMole - REA bridge
# Read-only application inspection through REA (https://github.com/morluto/rea).
# freeMole never bundles REA: it runs an installed `rea` command, or
# `npx -y rea-agents@latest` when only Node.js is present.

#Requires -Version 5.1
Set-StrictMode -Version Latest

if ((Get-Variable -Name 'MOLE_REA_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:MOLE_REA_LOADED) {
    return
}
$script:MOLE_REA_LOADED = $true

$script:MoleReaPackage = "rea-agents@latest"

# How to start REA: @{ File; Prefix; Description }, or $null when neither REA
# nor npx is on PATH. MOLE_REA_COMMAND names an explicit rea executable.
function Get-MoleReaInvocation {
    if ($env:MOLE_REA_COMMAND) {
        if (-not (Test-Path -LiteralPath $env:MOLE_REA_COMMAND -PathType Leaf)) { return $null }
        return @{ File = $env:MOLE_REA_COMMAND; Prefix = @(); Description = $env:MOLE_REA_COMMAND }
    }

    $rea = Get-Command -Name "rea" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($rea) {
        return @{ File = $rea.Source; Prefix = @(); Description = "rea ($($rea.Source))" }
    }

    $npx = Get-Command -Name "npx" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($npx) {
        return @{ File = $npx.Source; Prefix = @("-y", $script:MoleReaPackage); Description = "npx $($script:MoleReaPackage)" }
    }

    return $null
}

# The text an REA error object carries: its first issue's message, else the
# top-level message.
function Get-MoleReaErrorMessage {
    param($Data)

    if ($null -eq $Data) { return $null }
    $details = $Data.PSObject.Properties['details']
    if ($details -and $details.Value -and $details.Value.PSObject.Properties['issues']) {
        foreach ($issue in @($details.Value.issues)) {
            if ($issue -and $issue.PSObject.Properties['message'] -and $issue.message) { return [string]$issue.message }
        }
    }
    if ($Data.PSObject.Properties['message'] -and $Data.message) { return [string]$Data.message }
    return $null
}

# Runs one REA CLI operation with --json and returns
# @{ ExitCode; Data; Error }. Data is the parsed Evidence object, or $null.
function Invoke-MoleRea {
    param(
        [Parameter(Mandatory)] [hashtable]$Invocation,
        [Parameter(Mandatory)] [string[]]$Arguments
    )

    $allArgs = @($Invocation.Prefix) + @($Arguments) + @("--json")
    $stdout = $null
    $exitCode = 1
    try {
        # npm notices and REA progress go to stderr; only stdout is Evidence.
        $stdout = (& $Invocation.File @allArgs 2>$null) -join "`n"
        $exitCode = $LASTEXITCODE
    }
    catch {
        return @{ ExitCode = 1; Data = $null; Error = "Could not start REA: $($_.Exception.Message)" }
    }

    $data = $null
    if ($stdout) {
        try { $data = $stdout | ConvertFrom-Json }
        catch { $data = $null }
    }

    if ($exitCode -ne 0 -or $null -eq $data) {
        $message = Get-MoleReaErrorMessage -Data $data
        if (-not $message) { $message = "REA exited with code $exitCode" }
        return @{ ExitCode = $(if ($exitCode -eq 0) { 1 } else { $exitCode }); Data = $null; Error = $message }
    }
    return @{ ExitCode = 0; Data = $data; Error = $null }
}

# Registry uninstall entries that name an install folder or an icon file.
function Get-MoleInspectAppEntries {
    $roots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    $entries = @()
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if (-not $props) { continue }
            $name = if ($props.PSObject.Properties['DisplayName']) { [string]$props.DisplayName } else { "" }
            if (-not $name) { continue }
            $location = if ($props.PSObject.Properties['InstallLocation']) { [string]$props.InstallLocation } else { "" }
            $icon = if ($props.PSObject.Properties['DisplayIcon']) { [string]$props.DisplayIcon } else { "" }
            $entries += [pscustomobject]@{ Name = $name; InstallLocation = $location; DisplayIcon = $icon }
        }
    }
    return $entries
}

# DisplayIcon is `"C:\path\app.exe",0` or a bare path; return the file path.
function ConvertFrom-MoleDisplayIcon {
    param([string]$DisplayIcon)

    if (-not $DisplayIcon) { return $null }
    $value = $DisplayIcon.Trim()
    if ($value -match '^"([^"]+)"') { $value = $Matches[1] }
    elseif ($value -match '^(.+?\.(exe|dll|ico))(,\s*-?\d+)?$') { $value = $Matches[1] }
    return $value.Trim()
}

# Resolves a path or an installed app name. Returns
# @{ Path; Kind = "Directory"|"File"; Name; MainExecutable } or
# @{ Error; Matches } when nothing or more than one app matches.
function Resolve-MoleInspectTarget {
    param(
        [Parameter(Mandatory)] [string]$Target,
        [object[]]$Entries = $null
    )

    if (Test-Path -LiteralPath $Target) {
        $item = Get-Item -LiteralPath $Target -Force
        if ($item.PSIsContainer) {
            return @{ Path = $item.FullName; Kind = "Directory"; Name = $item.Name; MainExecutable = $null }
        }
        return @{ Path = $item.FullName; Kind = "File"; Name = $item.Name; MainExecutable = $item.FullName }
    }

    if ($null -eq $Entries) { $Entries = @(Get-MoleInspectAppEntries) }
    $candidates = @()
    foreach ($entry in $Entries) {
        $icon = ConvertFrom-MoleDisplayIcon -DisplayIcon $entry.DisplayIcon
        $folder = $null
        if ($entry.InstallLocation -and (Test-Path -LiteralPath $entry.InstallLocation -PathType Container)) {
            $folder = $entry.InstallLocation
        }
        elseif ($icon -and (Test-Path -LiteralPath $icon -PathType Leaf)) {
            $folder = Split-Path -Parent $icon
        }
        if (-not $folder) { continue }
        $candidates += [pscustomobject]@{ Name = $entry.Name; Folder = $folder; Icon = $icon }
    }

    $exact = @($candidates | Where-Object { $_.Name -ieq $Target })
    $found = if ($exact.Count -gt 0) { $exact } else { @($candidates | Where-Object { $_.Name -like "*$Target*" }) }
    # The same app is often registered twice (per-user and machine, x86 and x64).
    $found = @($found | Sort-Object -Property Folder -Unique)

    if ($found.Count -eq 0) {
        return @{ Error = "No installed app or path matches '$Target'"; Matches = @() }
    }
    if ($found.Count -gt 1) {
        return @{ Error = "'$Target' matches $($found.Count) installed apps; name one exactly or pass its folder"; Matches = @($found | ForEach-Object { $_.Name }) }
    }

    $app = $found[0]
    $main = $null
    if ($app.Icon -and $app.Icon -like "*.exe" -and (Test-Path -LiteralPath $app.Icon -PathType Leaf)) { $main = $app.Icon }
    return @{ Path = (Get-Item -LiteralPath $app.Folder -Force).FullName; Kind = "Directory"; Name = $app.Name; MainExecutable = $main }
}

# The executable REA should read in an install folder: the largest top-level
# .exe that is not an uninstaller or updater.
function Get-MoleInspectMainExecutable {
    param([Parameter(Mandatory)] [string]$Directory)

    $exes = @(Get-ChildItem -LiteralPath $Directory -Filter "*.exe" -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '^(unins|uninst|uninstall|update|updater|squirrel|crashpad|elevate)' })
    if ($exes.Count -eq 0) { return $null }
    return ($exes | Sort-Object -Property Length -Descending | Select-Object -First 1).FullName
}

# One value from an X.509 name: the first attribute with that oid_name.
function Get-MoleReaNameAttribute {
    param($Name, [string]$Attribute)

    if ($null -eq $Name -or -not $Name.PSObject.Properties['attributes']) { return $null }
    foreach ($attr in @($Name.attributes)) {
        if ($attr -and $attr.PSObject.Properties['oid_name'] -and $attr.oid_name -eq $Attribute) { return [string]$attr.value }
    }
    return $null
}

# The signer certificate's subject from inspect-pe-certificates: the
# embedded certificate whose serial and issuer match the first SignerInfo.
function Get-MoleReaSigner {
    param($Certificates)

    if ($null -eq $Certificates) { return $null }
    $result = $Certificates.normalized_result
    foreach ($entry in @($result.entries)) {
        if (-not $entry -or -not $entry.PSObject.Properties['pkcs7'] -or -not $entry.pkcs7) { continue }
        $pkcs7 = $entry.pkcs7
        foreach ($signer in @($pkcs7.signers)) {
            if (-not $signer) { continue }
            foreach ($cert in @($pkcs7.certificates)) {
                if (-not $cert) { continue }
                if ($cert.serial_hex -eq $signer.serial_hex -and $cert.issuer.text -eq $signer.issuer.text) {
                    $commonName = Get-MoleReaNameAttribute -Name $cert.subject -Attribute "commonName"
                    $organization = Get-MoleReaNameAttribute -Name $cert.subject -Attribute "organizationName"
                    $issuer = Get-MoleReaNameAttribute -Name $cert.issuer -Attribute "commonName"
                    return [pscustomobject]@{
                        Subject      = if ($commonName) { $commonName } else { $cert.subject.text }
                        Organization = $organization
                        Issuer       = if ($issuer) { $issuer } else { $cert.issuer.text }
                        ValidUntil   = $cert.not_after
                    }
                }
            }
        }
    }
    return $null
}

# Folds the REA Evidence records into one summary object.
function ConvertTo-MoleInspectSummary {
    param(
        [Parameter(Mandatory)] [hashtable]$Target,
        $Desktop = $null,
        $Certificates = $null,
        $Imports = $null,
        $Managed = $null,
        [string[]]$Errors = @()
    )

    $runtimes = @()
    $nextProbes = @()
    if ($Desktop) {
        foreach ($candidate in @($Desktop.normalized_result.candidates)) {
            if ($candidate) { $runtimes += [pscustomobject]@{ Family = [string]$candidate.family; Confidence = [string]$candidate.confidence } }
        }
        foreach ($probe in @($Desktop.normalized_result.next_probes)) {
            # open_binary selects an MCP session target; it has no one-shot CLI form.
            if ($probe -and $probe.operation -ne "open_binary") { $nextProbes += [pscustomobject]@{ Operation = [string]$probe.operation; Path = [string]$probe.path } }
        }
    }

    $signed = $null
    $signer = $null
    if ($Certificates) {
        $signed = @($Certificates.normalized_result.entries | Where-Object { $_ }).Count -gt 0
        $signer = Get-MoleReaSigner -Certificates $Certificates
    }

    $architecture = $null
    $dlls = @()
    if ($Imports) {
        $architecture = [string]$Imports.normalized_result.architecture
        foreach ($import in @($Imports.normalized_result.imports) + @($Imports.normalized_result.delay_imports)) {
            if ($import -and $import.PSObject.Properties['name'] -and $import.name) { $dlls += [string]$import.name }
        }
        $dlls = @($dlls | Sort-Object -Unique)
    }

    $managedInfo = $null
    if ($Managed) {
        $result = $Managed.normalized_result
        $assembly = if ($result.PSObject.Properties['assembly'] -and $result.assembly) { "$($result.assembly.name) $($result.assembly.version)" } else { $null }
        $managedInfo = [pscustomobject]@{
            RuntimeFamily    = [string]$result.classification.runtime_family
            Assembly         = $assembly
            TargetFrameworks = @($result.target_frameworks | Where-Object { $_ })
        }
    }

    return [pscustomobject]@{
        Name           = $Target.Name
        Kind           = $Target.Kind
        Path           = $Target.Path
        MainExecutable = $Target.MainExecutable
        Runtimes       = @($runtimes)
        Signed         = $signed
        Signer         = $signer
        Architecture   = $architecture
        ImportedDlls   = @($dlls)
        Managed        = $managedInfo
        NextProbes     = @($nextProbes)
        Errors         = @($Errors)
    }
}
