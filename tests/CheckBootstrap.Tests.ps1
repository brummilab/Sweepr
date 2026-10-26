# Sweepr Windows - tests for the one-liner bootstrap check.ps1 (repository root), Design Rev 4 §18/§21.
#
# check.ps1 is run as `iwr -useb .../check.ps1 | iex`, so these tests run its text the same way: as one
# script in the global scope of a fresh runspace of this process (in-process, so environment changes
# are visible here). Test seam the implementation must honour:
#
#   Downloads   Only through the command name `Invoke-WebRequest` (not module-qualified, not WebClient,
#               not BITS), one call per file, e.g. `Invoke-WebRequest -Uri <url> -OutFile <file>
#               -UseBasicParsing`. The tests define a global function Invoke-WebRequest in the runspace
#               that serves files from a local fake release and records every URI; it also returns
#               an object with .Content when -OutFile is missing.
#   Policy      The group-policy execution policy is read through the command name `Get-ExecutionPolicy`
#               (-Scope MachinePolicy / UserPolicy or -List); the tests stub it the same way.
#   Child run   The executable that replaces Windows PowerShell for the child run is taken from the
#               environment variable SWEEPR_CHECK_RUNNER when it is set; otherwise it is Windows
#               PowerShell (powershell.exe). The arguments stay the same:
#               -NoProfile -ExecutionPolicy Bypass -File <dir>\sweepr.ps1 check --report
#               The tests point it at the host running Pester, so the fake sweepr.ps1 from the fake
#               release really runs as a child process and records what it received.
#   Temp root   %TEMP% ($env:TEMP; falling back to [IO.Path]::GetTempPath() only when it is empty).
#               The own folder is <temp>\sweepr-check-<random> (letters, digits, '.', '_' or '-').
#   Messages    Written with Write-Host, Write-Warning or Write-Output, never only to [Console].
#
# CLM is simulated by switching the runspace to ConstrainedLanguage before the script runs; the GPO
# execution policy by the Get-ExecutionPolicy stub. Everything here is platform-neutral.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:CheckPath = Join-Path $script:RepoRoot "check.ps1"
    $script:NewZip = Join-Path $script:RepoRoot "scripts/new-release-zip.ps1"
    $script:Runner = (Get-Process -Id $PID).Path
    $script:LatestBase = "https://github.com/brummilab/Sweepr/releases/latest/download/"
    $script:OneLiner = '[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; iwr -useb https://raw.githubusercontent.com/brummilab/Sweepr/main/check.ps1 | iex'

    # Stand-in for the released sweepr.ps1: records its arguments, command line and environment.
    $script:FakeSweepr = @'
$link = 'NONE'
if ($env:SWEEPR_CHECK_TEST_LINK) {
    try {
        $dataDir = Join-Path $PSScriptRoot 'data'
        if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
        $type = 'SymbolicLink'
        if ([IO.Path]::DirectorySeparatorChar -eq '\') { $type = 'Junction' }
        New-Item -ItemType $type -Path (Join-Path $dataDir 'outside') -Target $env:SWEEPR_CHECK_TEST_LINK -ErrorAction Stop | Out-Null
        $link = 'LINKED'
    }
    catch { $link = 'LINK-FAILED' }
}
$data = [ordered]@{
    Args        = @($args)
    CommandLine = @([Environment]::GetCommandLineArgs())
    ScriptRoot  = $PSScriptRoot
    DataDir     = $env:SWEEPR_DATA_DIR
    NoOplog     = $env:SWEEPR_NO_OPLOG
    Link        = $link
}
[IO.File]::WriteAllText($env:SWEEPR_CHECK_TEST_RECORD, (ConvertTo-Json -InputObject $data -Depth 3))
Write-Output 'FAKE-SWEEPR-RAN'
'@

    function New-FakeRelease {
        param(
            [string]$Name,
            [switch]$WithoutCheck,
            [switch]$BadHash,
            [switch]$WithoutPortableLine
        )
        $root = Join-Path $TestDrive "release-$Name"
        $src = Join-Path $root "src"
        $out = Join-Path $root "out"
        New-Item -ItemType Directory -Path (Join-Path $src "bin"), (Join-Path $src "lib/core"), $out -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $src "sweepr.ps1") -Value $script:FakeSweepr -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $src "sweepr.portable") -Value "portable" -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $src "lib/core/version.ps1") -Value '$script:SWEEPR_VERSION = "9.9.9"' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $src "bin/clean.ps1") -Value "# clean" -Encoding ASCII
        if (-not $WithoutCheck) {
            Set-Content -LiteralPath (Join-Path $src "bin/check.ps1") -Value "# check" -Encoding ASCII
        }
        $zipName = "sweepr-9.9.9-x64-portable.zip"
        & $script:NewZip -SourceDir $src -Destination (Join-Path $out $zipName)
        Set-Content -LiteralPath (Join-Path $out "sweepr-9.9.9-x64.zip") -Value "installer zip" -Encoding ASCII
        $hash = (Get-FileHash -LiteralPath (Join-Path $out $zipName) -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($BadHash) { $hash = "0" * 64 }
        $lines = @(
            ("1" * 64) + "  sweepr-9.9.9-x64.zip"
        )
        if (-not $WithoutPortableLine) { $lines += "$hash  $zipName" }
        $lines += ("2" * 64) + "  analyze-windows-x64.exe"
        $lines += ("3" * 64) + "  status-windows-x64.exe"
        [IO.File]::WriteAllText((Join-Path $out "SHA256SUMS.txt"), (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding $false))
        return $out
    }

    $script:ReleaseOk = New-FakeRelease -Name "ok"
    $script:ReleaseBadHash = New-FakeRelease -Name "badhash" -BadHash
    $script:ReleaseNoCheck = New-FakeRelease -Name "nocheck" -WithoutCheck
    $script:ReleaseNoPortable = New-FakeRelease -Name "noportable" -WithoutPortableLine

    $script:Stubs = @'
function Invoke-WebRequest {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][uri]$Uri,
        [string]$OutFile,
        [switch]$UseBasicParsing,
        [switch]$PassThru,
        [switch]$DisableKeepAlive,
        [int]$TimeoutSec,
        [int]$MaximumRedirection,
        [string]$Method,
        [string]$UserAgent,
        $Headers,
        [Parameter(ValueFromRemainingArguments = $true)]$Rest
    )
    $null = $global:SweeprTestDownloads.Add([string]$Uri)
    if ($global:SweeprTestDownloadFails) { throw "simulated network failure" }
    $name = [string]$Uri.Segments[-1]
    $source = Join-Path $global:SweeprTestReleaseDir $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "404 Not Found: $Uri" }
    if ($OutFile) { Copy-Item -LiteralPath $source -Destination $OutFile -Force; return }
    [pscustomobject]@{ StatusCode = 200; Content = [IO.File]::ReadAllText($source) }
}
function Get-ExecutionPolicy {
    [CmdletBinding()]
    param([Parameter(Position = 0)]$Scope, [switch]$List)
    $map = $global:SweeprTestPolicies
    $scopes = @('MachinePolicy', 'UserPolicy', 'Process', 'CurrentUser', 'LocalMachine')
    if ($List) {
        foreach ($s in $scopes) {
            [pscustomobject]@{ Scope = [Microsoft.PowerShell.ExecutionPolicyScope]$s; ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]$map[$s] }
        }
        return
    }
    if ($Scope) { return [Microsoft.PowerShell.ExecutionPolicy]$map[[string]$Scope] }
    foreach ($s in $scopes) {
        if ($map[$s] -ne 'Undefined') { return [Microsoft.PowerShell.ExecutionPolicy]$map[$s] }
    }
    return [Microsoft.PowerShell.ExecutionPolicy]::Restricted
}
'@

    # Runs check.ps1 like `... | iex` in a fresh runspace and returns what happened.
    function Invoke-CheckBootstrap {
        param(
            [string]$ReleaseDir,
            [string]$LanguageMode = 'FullLanguage',
            [hashtable]$Policies = @{},
            [switch]$DownloadFails,
            [string]$LinkTarget,
            [AllowNull()][string]$CallerDataDir = $null,
            [AllowNull()][string]$CallerNoOplog = $null
        )
        $temp = Join-Path $TestDrive ("temp-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
        New-Item -ItemType Directory -Path $temp -Force | Out-Null
        $record = Join-Path $TestDrive ("record-" + [guid]::NewGuid().ToString("N") + ".json")
        $policyMap = @{ MachinePolicy = 'Undefined'; UserPolicy = 'Undefined'; Process = 'Undefined'; CurrentUser = 'Undefined'; LocalMachine = 'RemoteSigned' }
        foreach ($k in $Policies.Keys) { $policyMap[$k] = $Policies[$k] }

        $names = @('TEMP', 'TMP', 'TMPDIR', 'SWEEPR_DATA_DIR', 'SWEEPR_NO_OPLOG', 'SWEEPR_CHECK_RUNNER', 'SWEEPR_CHECK_TEST_RECORD', 'SWEEPR_CHECK_TEST_LINK')
        $saved = @{}
        foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
        $rs = $null; $ps = $null
        $result = [ordered]@{ Text = ''; Threw = $null; Downloads = @(); NewVariables = @(); NewFunctions = @(); NewAliases = @()
            ErrorActionPreference = $null; ProgressPreference = $null; DataDirAfter = $null; NoOplogAfter = $null
            Record = $null; TempRoot = $temp; Leftovers = @() }
        try {
            foreach ($n in @('TEMP', 'TMP', 'TMPDIR')) { [Environment]::SetEnvironmentVariable($n, $temp) }
            [Environment]::SetEnvironmentVariable('SWEEPR_DATA_DIR', $CallerDataDir)
            [Environment]::SetEnvironmentVariable('SWEEPR_NO_OPLOG', $CallerNoOplog)
            [Environment]::SetEnvironmentVariable('SWEEPR_CHECK_RUNNER', $script:Runner)
            [Environment]::SetEnvironmentVariable('SWEEPR_CHECK_TEST_RECORD', $record)
            if ($LinkTarget) { [Environment]::SetEnvironmentVariable('SWEEPR_CHECK_TEST_LINK', $LinkTarget) }
            else { [Environment]::SetEnvironmentVariable('SWEEPR_CHECK_TEST_LINK', $null) }

            $rs = [runspacefactory]::CreateRunspace([System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault())
            $rs.Open()
            $rs.SessionStateProxy.SetVariable('SweeprTestDownloads', (New-Object System.Collections.ArrayList))
            $rs.SessionStateProxy.SetVariable('SweeprTestReleaseDir', $ReleaseDir)
            $rs.SessionStateProxy.SetVariable('SweeprTestDownloadFails', [bool]$DownloadFails)
            $rs.SessionStateProxy.SetVariable('SweeprTestPolicies', $policyMap)
            $ps = [powershell]::Create()
            $ps.Runspace = $rs
            $null = $ps.AddScript($script:Stubs).Invoke()
            $ps.Commands.Clear()
            $snapshot = '@{ V = @(Get-Variable -Scope Global | ForEach-Object Name); F = @(Get-ChildItem function: | ForEach-Object Name); A = @(Get-ChildItem alias: | ForEach-Object Name); E = [string]$ErrorActionPreference; P = [string]$ProgressPreference }'
            $before = $ps.AddScript($snapshot).Invoke()[0]
            $ps.Commands.Clear()
            $ps.Streams.ClearStreams()
            $rs.SessionStateProxy.LanguageMode = $LanguageMode

            $output = @()
            try {
                $output = @($ps.AddScript([IO.File]::ReadAllText($script:CheckPath)).Invoke())
            }
            catch {
                $result.Threw = $_.Exception.Message
            }
            $ps.Commands.Clear()
            $text = @()
            $text += @($output | ForEach-Object { [string]$_ })
            $text += @($ps.Streams.Information | ForEach-Object { [string]$_.MessageData })
            $text += @($ps.Streams.Warning | ForEach-Object { [string]$_.Message })
            $text += @($ps.Streams.Error | ForEach-Object { [string]$_ })
            if ($result.Threw) { $text += $result.Threw }
            $result.Text = $text -join "`n"

            $result.DataDirAfter = [Environment]::GetEnvironmentVariable('SWEEPR_DATA_DIR')
            $result.NoOplogAfter = [Environment]::GetEnvironmentVariable('SWEEPR_NO_OPLOG')
            $rs.SessionStateProxy.LanguageMode = 'FullLanguage'
            $after = $ps.AddScript($snapshot).Invoke()[0]
            $ps.Commands.Clear()
            $ignored = @('?', '^', '$', '_', 'args', 'input', 'PSItem', 'Matches', 'LASTEXITCODE', 'StackTrace', 'Error', 'foreach', 'this')
            $result.NewVariables = @($after.V | Where-Object { $_ -notin $before.V -and $_ -notin $ignored })
            $result.NewFunctions = @($after.F | Where-Object { $_ -notin $before.F })
            $result.NewAliases = @($after.A | Where-Object { $_ -notin $before.A })
            $result.ErrorActionPreference = @($before.E, $after.E)
            $result.ProgressPreference = @($before.P, $after.P)
            $result.Downloads = @($rs.SessionStateProxy.GetVariable('SweeprTestDownloads'))
        }
        finally {
            if ($ps) { $ps.Dispose() }
            if ($rs) { $rs.Dispose() }
            foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
        }
        if (Test-Path -LiteralPath $record) { $result.Record = Get-Content -LiteralPath $record -Raw | ConvertFrom-Json }
        $result.Leftovers = @(Get-ChildItem -LiteralPath $temp -Force -Directory | Where-Object { $_.Name -like 'sweepr-check-*' } | ForEach-Object Name)
        return [pscustomobject]$result
    }

    function ConvertTo-ComparablePath([string]$Path) {
        [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    }
}

Describe "check.ps1 source" {
    It "Exists at the repository root" {
        Test-Path -LiteralPath $script:CheckPath -PathType Leaf | Should -BeTrue
    }

    It "Is pure ASCII without a byte order mark" {
        $bytes = [IO.File]::ReadAllBytes($script:CheckPath)
        $bytes.Count | Should -BeGreaterThan 0
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It "Parses without errors" {
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:CheckPath, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }

    It "Never calls exit" {
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:CheckPath, [ref]$tokens, [ref]$errors)
        @($tokens).Count | Should -BeGreaterThan 0
        @($tokens | Where-Object { $_.Kind -eq [System.Management.Automation.Language.TokenKind]::Exit }).Count | Should -Be 0
    }

    It "Wraps the whole body in one & { } block" {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:CheckPath, [ref]$tokens, [ref]$errors)
        $ast.ParamBlock | Should -BeNullOrEmpty
        $ast.BeginBlock | Should -BeNullOrEmpty
        $ast.ProcessBlock | Should -BeNullOrEmpty
        @($ast.EndBlock.Statements).Count | Should -Be 1
        $statement = $ast.EndBlock.Statements[0]
        $statement | Should -BeOfType ([System.Management.Automation.Language.PipelineAst])
        @($statement.PipelineElements).Count | Should -Be 1
        $command = $statement.PipelineElements[0]
        $command | Should -BeOfType ([System.Management.Automation.Language.CommandAst])
        $command.InvocationOperator | Should -Be ([System.Management.Automation.Language.TokenKind]::Ampersand)
        $command.CommandElements[0] | Should -BeOfType ([System.Management.Automation.Language.ScriptBlockExpressionAst])
    }

    It "Does not touch the execution policy, elevate or reach into global or script scope" {
        $text = [IO.File]::ReadAllText($script:CheckPath)
        $text | Should -Not -Match '(?i)Set-ExecutionPolicy'
        $text | Should -Not -Match '(?i)RunAs'
        $text | Should -Not -Match '(?i)\$(global|script):'
        $text | Should -Not -Match '(?i)function\s+(global|script):'
        $text | Should -Not -Match '(?i)-Scope\s+[''"]?(Global|Script|0)\b'
    }

    It "Extracts with System.IO.Compression.ZipFile, not Expand-Archive" {
        $text = [IO.File]::ReadAllText($script:CheckPath)
        $text | Should -Match 'System\.IO\.Compression\.ZipFile'
        $text | Should -Not -Match '(?i)Expand-Archive'
    }

    It "Downloads from the latest release of brummilab/Sweepr" {
        [IO.File]::ReadAllText($script:CheckPath) | Should -Match ([regex]::Escape($script:LatestBase))
    }
}

Describe "README one-liner" {
    It "Contains the exact check one-liner" {
        $readme = [IO.File]::ReadAllText((Join-Path $script:RepoRoot "README.md"))
        $readme.Contains($script:OneLiner) | Should -BeTrue
    }
}

Describe "check.ps1 run" {
    Context "Successful run" {
        BeforeAll {
            $script:Run = Invoke-CheckBootstrap -ReleaseDir $script:ReleaseOk -CallerNoOplog 'caller-value'
        }

        It "Downloads SHA256SUMS.txt and then the versioned portable zip from the latest release" {
            $script:Run.Downloads | Should -Be @(
                ($script:LatestBase + "SHA256SUMS.txt"),
                ($script:LatestBase + "sweepr-9.9.9-x64-portable.zip")
            )
        }

        It "Runs the extracted sweepr.ps1 with check --report" {
            $script:Run.Record | Should -Not -BeNullOrEmpty
            @($script:Run.Record.Args) | Should -Be @('check', '--report')
        }

        It "Starts the child with -NoProfile -ExecutionPolicy Bypass -File" {
            $cmd = @($script:Run.Record.CommandLine)
            $cmd | Should -Contain '-NoProfile'
            $cmd | Should -Contain '-File'
            $i = [array]::IndexOf($cmd, '-ExecutionPolicy')
            $i | Should -BeGreaterThan -1
            $cmd[$i + 1] | Should -Be 'Bypass'
        }

        It "Extracts into its own sweepr-check folder under TEMP" {
            $script:Run.Record | Should -Not -BeNullOrEmpty
            $root = ConvertTo-ComparablePath $script:Run.Record.ScriptRoot
            $temp = ConvertTo-ComparablePath $script:Run.TempRoot
            $root.StartsWith($temp + [IO.Path]::DirectorySeparatorChar) | Should -BeTrue
            $own = @($root.Substring($temp.Length + 1).Split([char[]]@('\', '/')))[0]
            $own | Should -Match '^sweepr-check-[A-Za-z0-9._-]{6,}$'
        }

        It "Gives only the child SWEEPR_DATA_DIR inside its folder and SWEEPR_NO_OPLOG=1" {
            (ConvertTo-ComparablePath $script:Run.Record.DataDir) | Should -Be (ConvertTo-ComparablePath (Join-Path $script:Run.Record.ScriptRoot 'data'))
            $script:Run.Record.NoOplog | Should -Be '1'
        }

        It "Leaves SWEEPR_DATA_DIR and SWEEPR_NO_OPLOG of the caller as they were" {
            $script:Run.Record | Should -Not -BeNullOrEmpty
            $script:Run.DataDirAfter | Should -BeNullOrEmpty
            $script:Run.NoOplogAfter | Should -Be 'caller-value'
        }

        It "Leaves no global variables, functions or aliases behind" {
            $script:Run.Record | Should -Not -BeNullOrEmpty
            $script:Run.NewVariables | Should -BeNullOrEmpty
            $script:Run.NewFunctions | Should -BeNullOrEmpty
            $script:Run.NewAliases | Should -BeNullOrEmpty
        }

        It "Restores ErrorActionPreference and ProgressPreference" {
            $script:Run.Record | Should -Not -BeNullOrEmpty
            $script:Run.ErrorActionPreference[1] | Should -Be $script:Run.ErrorActionPreference[0]
            $script:Run.ProgressPreference[1] | Should -Be $script:Run.ProgressPreference[0]
        }

        It "Does not throw to the caller" {
            $script:Run.Threw | Should -BeNullOrEmpty
        }

        It "Removes its own folder after the run" {
            $script:Run.Record | Should -Not -BeNullOrEmpty
            $script:Run.Leftovers | Should -BeNullOrEmpty
        }
    }

    It "Removes its folder without following a link inside it" {
        $outside = Join-Path $TestDrive "link-outside"
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $outside "guard.txt") -Value "guard"
        $run = Invoke-CheckBootstrap -ReleaseDir $script:ReleaseOk -LinkTarget $outside
        $run.Record | Should -Not -BeNullOrEmpty
        if ($run.Record.Link -eq 'LINK-FAILED') { Set-ItResult -Skipped -Because "links cannot be created here"; return }
        $run.Record.Link | Should -Be 'LINKED'
        Test-Path -LiteralPath (Join-Path $outside "guard.txt") | Should -BeTrue
        $run.Leftovers | Should -BeNullOrEmpty
    }

    It "Aborts on a checksum mismatch, runs nothing and removes its folder" {
        $run = Invoke-CheckBootstrap -ReleaseDir $script:ReleaseBadHash
        $run.Text | Should -Match '(?i)checksum|SHA-?256|hash'
        $run.Record | Should -BeNullOrEmpty
        $run.Leftovers | Should -BeNullOrEmpty
    }

    It "Removes its folder and runs nothing when a download fails" {
        $run = Invoke-CheckBootstrap -ReleaseDir $script:ReleaseOk -DownloadFails
        @($run.Downloads).Count | Should -BeGreaterThan 0
        $run.Text | Should -Not -BeNullOrEmpty
        $run.Record | Should -BeNullOrEmpty
        $run.Leftovers | Should -BeNullOrEmpty
    }

    It "Does not download a zip when SHA256SUMS.txt lists no portable zip" {
        $run = Invoke-CheckBootstrap -ReleaseDir $script:ReleaseNoPortable
        $run.Downloads | Should -Be @($script:LatestBase + "SHA256SUMS.txt")
        $run.Text | Should -Not -BeNullOrEmpty
        $run.Record | Should -BeNullOrEmpty
        $run.Leftovers | Should -BeNullOrEmpty
    }

    It "Says the release needs a newer Sweepr when bin\check.ps1 is missing and runs nothing" {
        $run = Invoke-CheckBootstrap -ReleaseDir $script:ReleaseNoCheck
        $run.Text | Should -Match 'needs Sweepr'
        $run.Record | Should -BeNullOrEmpty
        $run.Leftovers | Should -BeNullOrEmpty
    }

    It "Stops in Constrained Language Mode with a message before any download" {
        $run = Invoke-CheckBootstrap -ReleaseDir $script:ReleaseOk -LanguageMode 'ConstrainedLanguage'
        $run.Text | Should -Match '(?i)Constrained\s*Language'
        @($run.Downloads).Count | Should -Be 0
        $run.Record | Should -BeNullOrEmpty
        $run.Leftovers | Should -BeNullOrEmpty
    }

    It "Stops with a message before any download when the <Scope> execution policy is <Policy>" -ForEach @(
        @{ Scope = 'MachinePolicy'; Policy = 'Restricted' },
        @{ Scope = 'UserPolicy'; Policy = 'Restricted' },
        @{ Scope = 'MachinePolicy'; Policy = 'AllSigned' }
    ) {
        $run = Invoke-CheckBootstrap -ReleaseDir $script:ReleaseOk -Policies @{ $Scope = $Policy }
        $run.Text | Should -Match '(?i)execution\s*policy'
        @($run.Downloads).Count | Should -Be 0
        $run.Record | Should -BeNullOrEmpty
        $run.Leftovers | Should -BeNullOrEmpty
    }

    It "Is not stopped by a RemoteSigned group policy" {
        $run = Invoke-CheckBootstrap -ReleaseDir $script:ReleaseOk -Policies @{ MachinePolicy = 'RemoteSigned'; UserPolicy = 'RemoteSigned' }
        $run.Text | Should -Not -Match '(?i)execution\s*policy'
        @($run.Downloads).Count | Should -Be 2
        $run.Record | Should -Not -BeNullOrEmpty
        $run.Leftovers | Should -BeNullOrEmpty
    }
}
