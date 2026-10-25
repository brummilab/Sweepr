# Sweepr - Inspect (REA bridge) Tests

BeforeAll {
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:WindowsDir "lib\core\rea.ps1")

    # Trimmed from real `rea ... --json` output (rea-agents 6.8.0).
    $script:DesktopJson = @'
{"operation":"inspect_desktop_application","normalized_result":{
 "candidates":[
  {"family":"electron","confidence":"inferred","rationale":"app.asar"},
  {"family":"dotnet","confidence":"derived","rationale":"CLI header"}],
 "next_probes":[
  {"operation":"open_binary","path":"C:/App/resources/app.asar"},
  {"operation":"analyze_javascript_application","path":"C:/App/resources/app.asar"}]}}
'@
    $script:CertificatesJson = @'
{"operation":"inspect_pe_certificates","normalized_result":{"entries":[{"certificate_type":2,"pkcs7":{
 "certificates":[
  {"serial_hex":"aa","issuer":{"text":"CN=Root","attributes":[{"oid_name":"commonName","value":"Root"}]},
   "subject":{"text":"CN=Contoso PCA","attributes":[{"oid_name":"commonName","value":"Contoso PCA"}]},"not_after":"300101000000Z"},
  {"serial_hex":"bb","issuer":{"text":"CN=Contoso PCA","attributes":[{"oid_name":"commonName","value":"Contoso PCA"}]},
   "subject":{"text":"O=Contoso Ltd, CN=Contoso App","attributes":[{"oid_name":"organizationName","value":"Contoso Ltd"},{"oid_name":"commonName","value":"Contoso App"}]},"not_after":"270415185943Z"}],
 "signers":[{"serial_hex":"bb","issuer":{"text":"CN=Contoso PCA"}}]}}]}}
'@
    $script:UnsignedJson = '{"operation":"inspect_pe_certificates","normalized_result":{"table":null,"entries":[]}}'
    $script:ImportsJson = @'
{"operation":"inspect_pe_imports","normalized_result":{"architecture":"amd64",
 "imports":[{"name":"kernel32.dll"},{"name":"user32.dll"},{"name":"kernel32.dll"}],
 "delay_imports":null}}
'@
    $script:ManagedJson = @'
{"operation":"inspect_managed_artifact","normalized_result":{
 "classification":{"status":"managed","runtime_family":"dotnet-framework"},
 "assembly":{"name":"NuGet","version":"7.9.0.83"},
 "target_frameworks":[".NETFramework,Version=v4.7.2"]}}
'@
}

Describe "ConvertFrom-SweeprDisplayIcon" {
    It "Reads a quoted path with an icon index" {
        ConvertFrom-SweeprDisplayIcon -DisplayIcon '"C:\Program Files\App\app.exe",0' | Should -Be 'C:\Program Files\App\app.exe'
    }

    It "Reads a bare path with an icon index" {
        ConvertFrom-SweeprDisplayIcon -DisplayIcon 'C:\Apps\Tool\tool.exe,-101' | Should -Be 'C:\Apps\Tool\tool.exe'
    }

    It "Returns null for an empty value" {
        ConvertFrom-SweeprDisplayIcon -DisplayIcon '' | Should -BeNullOrEmpty
    }
}

Describe "Resolve-SweeprInspectTarget" {
    BeforeEach {
        $script:AppDir = Join-Path $TestDrive "Contoso"
        $script:OtherDir = Join-Path $TestDrive "Contoso Tools"
        New-Item -ItemType Directory -Path $script:AppDir, $script:OtherDir -Force | Out-Null
        $script:AppExe = Join-Path $script:AppDir "contoso.exe"
        Set-Content -LiteralPath $script:AppExe -Value "MZ"
    }

    It "Uses an existing folder as is" {
        $target = Resolve-SweeprInspectTarget -Target $script:AppDir -Entries @()
        $target.Kind | Should -Be "Directory"
        $target.Path | Should -Be (Get-Item -LiteralPath $script:AppDir).FullName
        $target.MainExecutable | Should -BeNullOrEmpty
    }

    It "Uses an existing file as its own executable" {
        $target = Resolve-SweeprInspectTarget -Target $script:AppExe -Entries @()
        $target.Kind | Should -Be "File"
        $target.MainExecutable | Should -Be (Get-Item -LiteralPath $script:AppExe).FullName
    }

    It "Prefers an exact app name over partial matches" {
        $entries = @(
            [pscustomobject]@{ Name = "Contoso"; InstallLocation = $script:AppDir; DisplayIcon = "`"$script:AppExe`",0" },
            [pscustomobject]@{ Name = "Contoso Tools"; InstallLocation = $script:OtherDir; DisplayIcon = "" }
        )
        $target = Resolve-SweeprInspectTarget -Target "contoso" -Entries $entries
        $target.ContainsKey("Error") | Should -BeFalse
        $target.Name | Should -Be "Contoso"
        $target.MainExecutable | Should -Be $script:AppExe
    }

    It "Refuses an ambiguous partial name and lists the matches" {
        $entries = @(
            [pscustomobject]@{ Name = "Contoso Suite"; InstallLocation = $script:AppDir; DisplayIcon = "" },
            [pscustomobject]@{ Name = "Contoso Tools"; InstallLocation = $script:OtherDir; DisplayIcon = "" }
        )
        $target = Resolve-SweeprInspectTarget -Target "Contoso" -Entries $entries
        $target.Error | Should -Match "matches 2 installed apps"
        $target.Matches | Should -Contain "Contoso Tools"
    }

    It "Collapses duplicate registrations of one folder" {
        $entries = @(
            [pscustomobject]@{ Name = "Contoso App"; InstallLocation = $script:AppDir; DisplayIcon = "" },
            [pscustomobject]@{ Name = "Contoso App (x64)"; InstallLocation = $script:AppDir; DisplayIcon = "" }
        )
        $target = Resolve-SweeprInspectTarget -Target "Contoso App" -Entries $entries
        $target.ContainsKey("Error") | Should -BeFalse
        $target.Path | Should -Be (Get-Item -LiteralPath $script:AppDir).FullName
    }

    It "Falls back to the icon's folder when InstallLocation is missing" {
        $entries = @([pscustomobject]@{ Name = "Contoso"; InstallLocation = ""; DisplayIcon = $script:AppExe })
        $target = Resolve-SweeprInspectTarget -Target "Contoso" -Entries $entries
        $target.Path | Should -Be (Get-Item -LiteralPath $script:AppDir).FullName
    }

    It "Reports when nothing matches" {
        $target = Resolve-SweeprInspectTarget -Target "Fabrikam" -Entries @()
        $target.Error | Should -Match "No installed app or path"
    }
}

Describe "Get-SweeprInspectMainExecutable" {
    It "Picks the largest exe and skips uninstallers and updaters" {
        $dir = Join-Path $TestDrive "pick"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir "app.exe") -Value ("x" * 100)
        Set-Content -LiteralPath (Join-Path $dir "unins000.exe") -Value ("x" * 5000)
        Set-Content -LiteralPath (Join-Path $dir "Update.exe") -Value ("x" * 5000)
        Set-Content -LiteralPath (Join-Path $dir "helper.exe") -Value ("x" * 10)
        Split-Path -Leaf (Get-SweeprInspectMainExecutable -Directory $dir) | Should -Be "app.exe"
    }

    It "Returns null for a folder without executables" {
        $dir = Join-Path $TestDrive "empty"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Get-SweeprInspectMainExecutable -Directory $dir | Should -BeNullOrEmpty
    }
}

Describe "Get-SweeprReaSigner" {
    It "Names the leaf certificate that matches the SignerInfo" {
        $signer = Get-SweeprReaSigner -Certificates ($script:CertificatesJson | ConvertFrom-Json)
        $signer.Subject | Should -Be "Contoso App"
        $signer.Organization | Should -Be "Contoso Ltd"
        $signer.Issuer | Should -Be "Contoso PCA"
    }

    It "Returns null for an image without a certificate table" {
        Get-SweeprReaSigner -Certificates ($script:UnsignedJson | ConvertFrom-Json) | Should -BeNullOrEmpty
    }
}

Describe "ConvertTo-SweeprInspectSummary" {
    It "Combines runtime, signer, imports and .NET facts" {
        $target = @{ Name = "Contoso"; Kind = "Directory"; Path = "C:\App"; MainExecutable = "C:\App\app.exe" }
        $summary = ConvertTo-SweeprInspectSummary -Target $target `
            -Desktop ($script:DesktopJson | ConvertFrom-Json) `
            -Certificates ($script:CertificatesJson | ConvertFrom-Json) `
            -Imports ($script:ImportsJson | ConvertFrom-Json) `
            -Managed ($script:ManagedJson | ConvertFrom-Json)

        @($summary.Runtimes.Family) | Should -Be @("electron", "dotnet")
        $summary.Signed | Should -BeTrue
        $summary.Signer.Subject | Should -Be "Contoso App"
        $summary.Architecture | Should -Be "amd64"
        @($summary.ImportedDlls) | Should -Be @("kernel32.dll", "user32.dll")
        $summary.Managed.Assembly | Should -Be "NuGet 7.9.0.83"
        $summary.Managed.TargetFrameworks | Should -Contain ".NETFramework,Version=v4.7.2"
    }

    It "Drops MCP-only follow-up probes" {
        $target = @{ Name = "Contoso"; Kind = "Directory"; Path = "C:\App"; MainExecutable = $null }
        $summary = ConvertTo-SweeprInspectSummary -Target $target -Desktop ($script:DesktopJson | ConvertFrom-Json)
        @($summary.NextProbes.Operation) | Should -Be @("analyze_javascript_application")
    }

    It "Leaves the signature unknown when it was not checked" {
        $target = @{ Name = "x"; Kind = "File"; Path = "C:\x.asar"; MainExecutable = $null }
        $summary = ConvertTo-SweeprInspectSummary -Target $target -Errors @("No main executable found")
        $summary.Signed | Should -BeNullOrEmpty
        $summary.Errors | Should -Contain "No main executable found"
    }

    It "Reports an unsigned image as not signed" {
        $target = @{ Name = "x"; Kind = "File"; Path = "C:\x.exe"; MainExecutable = "C:\x.exe" }
        $summary = ConvertTo-SweeprInspectSummary -Target $target -Certificates ($script:UnsignedJson | ConvertFrom-Json)
        $summary.Signed | Should -BeFalse
    }
}

Describe "Invoke-SweeprRea" {
    BeforeAll {
        # A stand-in REA: echoes a success record, or an REA error object.
        $script:FakeRea = Join-Path $TestDrive "fake-rea.ps1"
        Set-Content -LiteralPath $script:FakeRea -Value @'
if ($args -contains "fail") {
    '{"code":"invalid_request","message":"Analysis input is invalid.","details":{"issues":[{"message":"Selected PE image could not be read (ENOENT)"}]}}'
    exit 1
}
[Console]::Error.WriteLine("npm notice: ignored")
'{"operation":"echo","args":"' + ($args -join ' ') + '"}'
exit 0
'@
        $script:FakeInvocation = @{ File = $script:FakeRea; Prefix = @("-y", "rea-agents@latest"); Description = "fake" }
    }

    It "Appends --json, keeps the prefix and parses stdout only" {
        $run = Invoke-SweeprRea -Invocation $script:FakeInvocation -Arguments @("inspect-pe-imports", "C:/app.exe")
        $run.ExitCode | Should -Be 0
        $run.Data.args | Should -Be "-y rea-agents@latest inspect-pe-imports C:/app.exe --json"
    }

    It "Returns REA's own issue message on failure" {
        $run = Invoke-SweeprRea -Invocation $script:FakeInvocation -Arguments @("fail")
        $run.ExitCode | Should -Be 1
        $run.Data | Should -BeNullOrEmpty
        $run.Error | Should -Match "could not be read"
    }
}

Describe "Get-SweeprReaInvocation" {
    AfterEach { Remove-Item Env:SWEEPR_REA_COMMAND -ErrorAction SilentlyContinue }

    It "Honors SWEEPR_REA_COMMAND when it names a file" {
        $fake = Join-Path $TestDrive "rea.cmd"
        Set-Content -LiteralPath $fake -Value "@echo {}"
        $env:SWEEPR_REA_COMMAND = $fake
        $invocation = Get-SweeprReaInvocation
        $invocation.File | Should -Be $fake
        @($invocation.Prefix).Count | Should -Be 0
    }

    It "Returns null when SWEEPR_REA_COMMAND names a missing file" {
        $env:SWEEPR_REA_COMMAND = Join-Path $TestDrive "missing.cmd"
        Get-SweeprReaInvocation | Should -BeNullOrEmpty
    }
}

Describe "Inspect command" {
    It "Shows help without needing REA" {
        $output = & (Join-Path $script:WindowsDir "bin\inspect.ps1") -ShowHelp 6>&1 | Out-String
        $output | Should -Match "sw inspect"
        $output | Should -Match "--setup"
    }

    It "Is routed and listed in the main help" {
        $source = Get-Content (Join-Path $script:WindowsDir "sweepr.ps1") -Raw
        $source | Should -Match '"inspect"'
        $source | Should -Match 'sw inspect <app>'
    }

    It "Never deletes: the command uses no removal helper" {
        $source = (Get-Content (Join-Path $script:WindowsDir "bin\inspect.ps1") -Raw) + (Get-Content (Join-Path $script:WindowsDir "lib\core\rea.ps1") -Raw)
        $source | Should -Not -Match 'Remove-(Item|SafeItem|SafeItems|SafeDirectoryTree)|Clear-DirectoryContents'
    }
}
