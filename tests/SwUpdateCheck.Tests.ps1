# Sweepr - tests for lib\core\update_check.ps1
#
# Written from the spec only. Covers rules V-1 to V-24, the security invariants (spec 4) and the transition
# names (L7-1: old names stay as forwarding functions, not aliases).
#
# Interface pinned here (spec 2.2, L7-2, L7-4):
#   Test-SwUpdateHintAllowed -CommandName <s> -Arguments <s[]>    $true/$false (V-1 to V-5)
#   Start-SwUpdateProbe -RootDir <path> -Version <s> -Method <s>  opaque context or $null (V-6 to V-11, V-15, V-16, V-19, V-20)
#   Get-SwUpdateHint -Context <ctx>                               hint text or nothing (V-21, V-22)
#   Write-SwUpdateHint -Context <ctx>                             at most one yellow host line (V-23, V-24)
#   Start-SwBackgroundProcess                                     the only process start (mocked everywhere here)
#   Invoke-SwUpdateLookup                                         what the background command calls (V-15)
#   Old names: Test-SweeprUpdateNoticeAllowed, Start-SweeprUpdateCheck, Show-SweeprUpdateNotice
#
# Assumptions these tests make where the spec leaves the mechanism open (listed as questions for the lead):
#   - Start-SwBackgroundProcess gets the start data as parameters (any names): the absolute path of
#     powershell.exe and the arguments with -EncodedCommand <base64>. The tests search all bound values.
#   - V-1 "stderr not redirected" is asked through a mockable function Test-SwStdErrRedirected ($true when
#     redirected); "interactive" through Test-SweeprInteractiveOutput (log.ps1).
#   - The current time comes from Get-Date (mocked to move the clock), the cache folder from Get-CachePath
#     (base.ps1, mocked), the network from Invoke-RestMethod or Invoke-WebRequest (both mocked).
#
# The background lookup is run in this process: the captured -EncodedCommand is decoded and executed with the
# repository as installation root (so it loads this repository's update_check.ps1), with the network mocked.
# The quoting tests (V-16) also run the command in a child PowerShell against a fixture update_check.ps1.

BeforeDiscovery {
    $script:OnWindows = [System.IO.Path]::DirectorySeparatorChar -eq '\'
    $q = [string][char]0x27
    $lq = [string][char]0x2018
    $rq = [string][char]0x2019
    $lowq = [string][char]0x201A
    $revq = [string][char]0x201B
    $all = $q + $lq + $rq + $lowq + $revq
    $script:PathCases = @(
        @{ Name = 'apostrophe'; Value = "it's" }
        @{ Name = 'right single quotes'; Value = "Rock${rq}n${rq}Roll" }
        @{ Name = 'left single quote'; Value = "a${lq}b" }
        @{ Name = 'low single quote'; Value = "a${lowq}b" }
        @{ Name = 'reversed single quote'; Value = "a${revq}b" }
        @{ Name = 'quoted name'; Value = "${rq}x${rq}" }
        @{ Name = 'all five quotes with a command'; Value = "x$all; New-Item marker; $all" }
        @{ Name = 'subexpression'; Value = "${rq}`$(New-Item marker)${rq}" }
        @{ Name = 'space and semicolon'; Value = 'a b;c' }
        @{ Name = 'backtick'; Value = 'back`tick' }
    )
    # Colon and double quote are not allowed in Windows file names.
    $script:UnixPathCases = @(
        @{ Name = 'variable and subexpression'; Value = '$env:PATH $(Get-Date)' }
        @{ Name = 'double quotes'; Value = 'say "hi"' }
        @{ Name = 'combination'; Value = ("it's Rock${rq}n${rq}Roll a${lq}b a${lowq}b a${revq}b ${rq}x${rq} x$all; New-Item marker; $all " +
                "${rq}`$(New-Item marker)${rq} a b;c `$env:PATH `$(Get-Date) back``tick say `"hi`"") }
    )
    $script:MethodCases = @($script:PathCases + $script:UnixPathCases + @(@{ Name = 'trailing backslash path'; Value = 'C:\Music\' }))
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:CoreDir = Join-Path $script:RepoRoot 'lib\core'
    . (Join-Path $script:CoreDir 'base.ps1')
    . (Join-Path $script:CoreDir 'log.ps1')
    . (Join-Path $script:CoreDir 'update_check.ps1')

    $script:Palette = Get-SweeprDefaultColors
    $script:OnWindows = [System.IO.Path]::DirectorySeparatorChar -eq '\'
    $script:SavedSystemRoot = $env:SystemRoot
    if (-not $script:OnWindows) { $env:SystemRoot = 'C:\Windows' }

    $script:ReleasesUrl = 'https://api.github.com/repos/brummilab/sweepr/releases?per_page=100'
    $script:WingetUrl = 'https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests/b/brummilab/Sweepr'
    $script:ScoopUrl = 'https://raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/sweepr.json'

    $script:ReleasesJson = @'
[
  {"tag_name":"V9.99.0","draft":false,"prerelease":false,"name":"no suffix"},
  {"tag_name":"V1.99.0-windows","draft":true,"prerelease":false,"name":"draft"},
  {"tag_name":"V1.98.0-windows","draft":false,"prerelease":true,"name":"pre-release"},
  {"tag_name":"V1.97.0-beta-windows","draft":false,"prerelease":false,"name":"beta"},
  {"tag_name":"V1.9.0-windows","draft":false,"prerelease":false,"name":"V5.0.0-windows"},
  {"tag_name":"V1.10.0-windows","draft":false,"prerelease":false,"name":"Horizon"},
  {"tag_name":"v3.0.0-windows","draft":false,"prerelease":false,"name":"lower-case v"},
  {"tag_name":"V4.0.0-Windows","draft":false,"prerelease":false,"name":"upper-case W"},
  {"tag_name":"V123456.0.0-windows","draft":false,"prerelease":false,"name":"six digits"}
]
'@
    $script:WingetJson = @'
[
  {"name":"1.9.0","type":"dir"},
  {"name":"1.10.0","type":"dir"},
  {"name":"1.11.0-beta","type":"dir"},
  {"name":"9.0.0","type":"file"},
  {"name":"100000.0.0","type":"dir"}
]
'@
    $script:ScoopJson = '{"version":"1.8.0","url":"https://example.invalid/sweepr.zip"}'

    function script:Set-StandardResponses {
        $script:Responses[$script:ReleasesUrl] = $script:ReleasesJson
        $script:Responses[$script:WingetUrl] = $script:WingetJson
        $script:Responses[$script:ScoopUrl] = $script:ScoopJson
    }

    function script:Set-LatestEverywhere([string]$Version) {
        $script:Responses[$script:ReleasesUrl] = "[{`"tag_name`":`"V$Version-windows`",`"draft`":false,`"prerelease`":false,`"name`":`"x`"},{`"tag_name`":`"V0.0.1-windows`",`"draft`":false,`"prerelease`":false,`"name`":`"y`"}]"
        $script:Responses[$script:WingetUrl] = "[{`"name`":`"$Version`",`"type`":`"dir`"},{`"name`":`"0.0.1`",`"type`":`"dir`"}]"
        $script:Responses[$script:ScoopUrl] = "{`"version`":`"$Version`"}"
    }

    function script:Copy-Bound($Bound) {
        $copy = @{}
        if ($null -ne $Bound) { foreach ($key in @($Bound.Keys)) { $copy[$key] = $Bound[$key] } }
        $copy
    }

    function script:Add-FlatValue {
        param($List, $Value)
        if ($null -eq $Value) { return }
        if ($Value -is [string]) { $List.Add($Value); return }
        if ($Value -is [System.Diagnostics.ProcessStartInfo]) {
            $List.Add([string]$Value.FileName)
            $List.Add([string]$Value.Arguments)
            if ($Value.PSObject.Properties['ArgumentList']) { foreach ($a in @($Value.ArgumentList)) { $List.Add([string]$a) } }
            return
        }
        if ($Value -is [System.Collections.IDictionary]) { foreach ($v in @($Value.Values)) { Add-FlatValue -List $List -Value $v }; return }
        if ($Value -is [System.Collections.IEnumerable]) { foreach ($v in $Value) { Add-FlatValue -List $List -Value $v }; return }
        $List.Add([string]$Value)
    }

    # Everything one call of Start-SwBackgroundProcess got, plus the decoded -EncodedCommand.
    function script:Get-StartInfo {
        param([int]$Index = -1)
        $call = $script:StartCalls[$Index]
        $values = New-Object System.Collections.Generic.List[string]
        foreach ($v in @($call.Bound.Values)) { Add-FlatValue -List $values -Value $v }
        foreach ($v in @($call.Args)) { Add-FlatValue -List $values -Value $v }
        $joined = $values -join ' '
        $b64 = $null
        if ($joined -match '(?i)-EncodedCommand\s+"?([A-Za-z0-9+/=]+)') { $b64 = $Matches[1] }
        $text = $null
        if ($b64) { $text = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($b64)) }
        [pscustomobject]@{ Values = $values; Joined = $joined; Base64 = $b64; CommandText = $text }
    }

    function script:Get-CommandAst([string]$Text) {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
        [pscustomobject]@{ Ast = $ast; Errors = @($errors) }
    }

    # Runs the captured background command here, with exit turned into return.
    function script:Invoke-CapturedLookup {
        param([int]$Index = -1)
        $text = (Get-StartInfo -Index $Index).CommandText
        if (-not $text) { throw 'no -EncodedCommand captured' }
        $parsed = Get-CommandAst $text
        $exits = @($parsed.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true) |
                Sort-Object { $_.Extent.StartOffset } -Descending)
        foreach ($e in $exits) {
            $text = $text.Remove($e.Extent.StartOffset, $e.Extent.EndOffset - $e.Extent.StartOffset).Insert($e.Extent.StartOffset, 'return')
        }
        $script:LookupError = $null
        try { $null = & ([scriptblock]::Create($text)) *>&1 }
        catch { $script:LookupError = $_ }
    }

    function script:Invoke-Probe {
        param([string]$Version = '1.0.0', [string]$Method = 'Source', [string]$Root = $script:RepoRoot)
        Start-SwUpdateProbe -RootDir $Root -Version $Version -Method $Method
    }

    # Probe, then run the background lookup it started; returns the context.
    function script:Invoke-ProbeAndLookup {
        param([string]$Version = '1.0.0', [string]$Method = 'Source')
        $ctx = Invoke-Probe -Version $Version -Method $Method
        Invoke-CapturedLookup
        $ctx
    }

    function script:Get-FileBytes([string]$Path) {
        if (-not [System.IO.File]::Exists($Path)) { return $null }
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path))
    }

    function script:ConvertTo-HostText {
        param([object[]]$Records)
        $sb = New-Object System.Text.StringBuilder
        foreach ($record in $Records) {
            if ($record -is [System.Management.Automation.InformationRecord]) {
                $data = $record.MessageData
                if ($data -is [System.Management.Automation.HostInformationMessage]) {
                    [void]$sb.Append($data.Message)
                    if (-not $data.NoNewLine) { [void]$sb.Append("`n") }
                }
                else { [void]$sb.Append("$data`n") }
            }
        }
        $sb.ToString()
    }

    function script:New-DirLink([string]$Link, [string]$Target) {
        if ($script:OnWindows) { New-Item -ItemType Junction -Path $Link -Target $Target | Out-Null }
        else { New-Item -ItemType SymbolicLink -Path $Link -Target $Target | Out-Null }
    }

    function script:ConvertTo-Hex([string]$Text) { -join ($Text.ToCharArray() | ForEach-Object { '{0:X4}' -f [int]$_ }) }
}

AfterAll {
    $env:SystemRoot = $script:SavedSystemRoot
}

Describe 'Sw update check' {
    BeforeEach {
        $script:CacheDir = Join-Path $TestDrive ('cache-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null
        $script:CacheFile = Join-Path $script:CacheDir 'update-check.json'
        $script:StartCalls = New-Object System.Collections.Generic.List[object]
        $script:Requests = New-Object System.Collections.Generic.List[object]
        $script:Responses = @{}
        $script:Now = [DateTime]::SpecifyKind([DateTime]::UtcNow, [DateTimeKind]::Utc)
        $script:SavedDryRun = $env:SWEEPR_DRY_RUN
        $env:SWEEPR_DRY_RUN = $null

        Mock Get-CachePath { $script:CacheDir }
        Mock Start-SwBackgroundProcess {
            $script:StartCalls.Add([pscustomobject]@{
                    Bound       = (Copy-Bound $PesterBoundParameters)
                    Args        = @($args)
                    FileExisted = [System.IO.File]::Exists($script:CacheFile)
                })
        }
        Mock Start-Process { throw 'Start-Process must not be used' }
        Mock Get-Date {
            if ($PesterBoundParameters.ContainsKey('Format')) { return $script:Now.ToString($PesterBoundParameters['Format']) }
            if ($PesterBoundParameters.ContainsKey('Date')) { return [datetime]$PesterBoundParameters['Date'] }
            $script:Now
        }
        Mock Invoke-RestMethod {
            $script:Requests.Add([pscustomobject]@{ Command = 'Invoke-RestMethod'; Uri = [string]$Uri; Bound = (Copy-Bound $PesterBoundParameters) })
            $body = $script:Responses[[string]$Uri]
            if ($null -eq $body) { throw (New-Object System.Net.WebException "offline: $Uri") }
            ConvertFrom-Json -InputObject $body
        }
        Mock Invoke-WebRequest {
            $script:Requests.Add([pscustomobject]@{ Command = 'Invoke-WebRequest'; Uri = [string]$Uri; Bound = (Copy-Bound $PesterBoundParameters) })
            $body = $script:Responses[[string]$Uri]
            if ($null -eq $body) { throw (New-Object System.Net.WebException "offline: $Uri") }
            [pscustomobject]@{ StatusCode = 200; Content = $body; Headers = @{} }
        }
    }

    AfterEach {
        $env:SWEEPR_DRY_RUN = $script:SavedDryRun
    }

    Context 'When a hint is allowed (V-1 to V-5)' {
        BeforeEach {
            $script:Interactive = $true
            $script:ErrRedirected = $false
            Mock Test-SweeprInteractiveOutput { $script:Interactive }
            Mock Test-SwStdErrRedirected { $script:ErrRedirected }
        }

        It 'Allows command <Command> with arguments <Text> (V-3, V-4)' -ForEach @(
            @{ Command = ''; Arguments = @(); Text = 'none (menu)' }
            @{ Command = 'clean'; Arguments = @(); Text = 'none' }
            @{ Command = 'CLEAN'; Arguments = @(); Text = 'none, upper case' }
            @{ Command = 'uninstall'; Arguments = @(); Text = 'none' }
            @{ Command = 'optimize'; Arguments = @(); Text = 'none' }
            @{ Command = 'purge'; Arguments = @(); Text = 'none' }
            @{ Command = 'analyze'; Arguments = @('json'); Text = 'json without dashes' }
            @{ Command = 'status'; Arguments = @(); Text = 'none' }
            @{ Command = 'clean'; Arguments = @('--helpful'); Text = '--helpful' }
            @{ Command = 'clean'; Arguments = @('--debug'); Text = '--debug' }
            @{ Command = 'clean'; Arguments = @('---help'); Text = 'three dashes' }
            @{ Command = 'clean'; Arguments = @('--jsonx'); Text = '--jsonx' }
            @{ Command = 'clean'; Arguments = @('--dryrun'); Text = '--dryrun' }
        ) {
            Test-SwUpdateHintAllowed -CommandName $Command -Arguments $Arguments | Should -BeTrue
        }

        It 'Allows a missing command name (V-3)' {
            Test-SwUpdateHintAllowed -Arguments @() | Should -BeTrue
        }

        It 'Refuses command <Command> (V-3)' -ForEach @(
            @{ Command = 'check' }
            @{ Command = 'history' }
            @{ Command = 'features' }
            @{ Command = 'update' }
            @{ Command = 'remove' }
            @{ Command = 'cleanup' }
            @{ Command = 'unknown-command' }
        ) {
            Test-SwUpdateHintAllowed -CommandName $Command -Arguments @() | Should -BeFalse
        }

        It 'Refuses argument <Argument> (V-4)' -ForEach @(
            @{ Argument = '--json' }
            @{ Argument = '-json' }
            @{ Argument = '--ndjson' }
            @{ Argument = '--watch' }
            @{ Argument = '--watch=3' }
            @{ Argument = '-h' }
            @{ Argument = '--h' }
            @{ Argument = '--help' }
            @{ Argument = '-help' }
            @{ Argument = '--version' }
            @{ Argument = '-v' }
            @{ Argument = '--v' }
            @{ Argument = '--list' }
            @{ Argument = '--dry-run' }
            @{ Argument = '--whitelist' }
            @{ Argument = '--JSON:x' }
            @{ Argument = '--Help=' }
            @{ Argument = '-WATCH:5' }
        ) {
            $command = if ($Argument -match '(?i)watch|json') { 'status' } else { 'clean' }
            Test-SwUpdateHintAllowed -CommandName $command -Arguments @('--debug', $Argument) | Should -BeFalse
        }

        It 'Refuses when the output is not interactive (V-1)' {
            $script:Interactive = $false
            Test-SwUpdateHintAllowed -CommandName 'clean' -Arguments @() | Should -BeFalse
        }

        It 'Refuses when stderr is redirected (V-1)' {
            $script:ErrRedirected = $true
            Test-SwUpdateHintAllowed -CommandName 'clean' -Arguments @() | Should -BeFalse
        }

        It 'Refuses when SWEEPR_DRY_RUN is 1 (V-2)' {
            $env:SWEEPR_DRY_RUN = '1'
            Test-SwUpdateHintAllowed -CommandName 'clean' -Arguments @() | Should -BeFalse
            Test-SwUpdateHintAllowed -CommandName '' -Arguments @() | Should -BeFalse
        }

        It 'Is not blocked by SWEEPR_DRY_RUN=<Value> (V-2)' -ForEach @(
            @{ Value = '0' }
            @{ Value = 'true' }
            @{ Value = ' 1' }
        ) {
            $env:SWEEPR_DRY_RUN = $Value
            Test-SwUpdateHintAllowed -CommandName 'clean' -Arguments @() | Should -BeTrue
        }

        It 'Only checks: starts nothing, writes nothing, asks no network (V-5)' {
            $null = Test-SwUpdateHintAllowed -CommandName 'clean' -Arguments @()
            $null = Test-SwUpdateHintAllowed -CommandName 'check' -Arguments @()
            Should -Invoke Start-SwBackgroundProcess -Times 0 -Exactly -Scope It
            $script:Requests.Count | Should -Be 0
            @(Get-ChildItem -LiteralPath $script:CacheDir -Force).Count | Should -Be 0
        }

        It 'Old name Test-SweeprUpdateNoticeAllowed gives the same answers' {
            foreach ($case in @(@('clean', @()), @('check', @()), @('status', @('--json')), @('', @()))) {
                Test-SweeprUpdateNoticeAllowed -CommandName $case[0] -Arguments $case[1] |
                    Should -Be (Test-SwUpdateHintAllowed -CommandName $case[0] -Arguments $case[1])
            }
        }
    }

    Context 'Starting a probe (V-6 to V-11)' {
        It 'Returns $null and does nothing for running version <Version> (V-6)' -ForEach @(
            @{ Version = '0.2.0-beta.1' }
            @{ Version = '' }
            @{ Version = '1.2' }
            @{ Version = '1.2.3.4' }
            @{ Version = '123456.0.0' }
            @{ Version = 'v1.2.3' }
            @{ Version = ' 1.2.3' }
        ) {
            Invoke-Probe -Version $Version | Should -BeNullOrEmpty
            Should -Invoke Start-SwBackgroundProcess -Times 0 -Exactly -Scope It
            @(Get-ChildItem -LiteralPath $script:CacheDir -Force).Count | Should -Be 0
        }

        It 'Writes a pending entry, then starts the background lookup, then returns a context (V-9)' {
            $ctx = Invoke-Probe
            $ctx | Should -Not -BeNullOrEmpty
            Should -Invoke Start-SwBackgroundProcess -Times 1 -Exactly -Scope It
            $script:StartCalls[0].FileExisted | Should -BeTrue
            [System.IO.File]::Exists($script:CacheFile) | Should -BeTrue
            Get-SwUpdateHint -Context $ctx | Should -BeNullOrEmpty
        }

        It 'Returns exactly one context, writes nothing to the host and asks no network (V-11)' {
            $records = @(Invoke-Probe 6>&1)
            @($records | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }).Count | Should -Be 0
            $records.Count | Should -Be 1
            $script:Requests.Count | Should -Be 0
        }

        It 'Does not start a second lookup while the pending entry is fresh (V-8, V-9)' {
            $null = Invoke-Probe
            $before = Get-FileBytes $script:CacheFile
            $script:Now = $script:Now.AddMinutes(59)
            $ctx = Invoke-Probe
            $ctx | Should -Not -BeNullOrEmpty
            Should -Invoke Start-SwBackgroundProcess -Times 1 -Exactly -Scope It
            Get-FileBytes $script:CacheFile | Should -Be $before
        }

        It 'Retries a pending or failed lookup after one hour (V-9)' {
            $null = Invoke-Probe
            $script:Now = $script:Now.AddMinutes(61)
            $null = Invoke-Probe
            Should -Invoke Start-SwBackgroundProcess -Times 2 -Exactly -Scope It
        }

        It 'Starts again when the <Changed> changes (V-7)' -ForEach @(
            @{ Changed = 'version'; Second = @{ Version = '1.0.1' } }
            @{ Changed = 'channel'; Second = @{ Method = 'winget' } }
            @{ Changed = 'root'; Second = @{ Root = 'other-root' } }
        ) {
            $null = Invoke-Probe
            $params = @{}
            foreach ($key in $Second.Keys) { $params[$key] = $Second[$key] }
            if ($params.ContainsKey('Root')) {
                $params.Root = Join-Path $TestDrive 'other-root'
                New-Item -ItemType Directory -Path $params.Root -Force | Out-Null
            }
            $ctx = Invoke-Probe @params
            $ctx | Should -Not -BeNullOrEmpty
            Should -Invoke Start-SwBackgroundProcess -Times 2 -Exactly -Scope It
        }

        It 'Treats a cache file with <Name> as missing and replaces it (V-10)' -ForEach @(
            @{ Name = 'no JSON'; Content = 'not json at all' }
            @{ Name = 'nothing'; Content = '' }
            @{ Name = 'a JSON null'; Content = 'null' }
            @{ Name = 'a JSON array'; Content = '[1,2,3]' }
            @{ Name = 'another schema'; Content = '{"Schema":99,"Key":"x","CheckedTicks":0,"Interval":3600,"Latest":""}' }
        ) {
            [System.IO.File]::WriteAllText($script:CacheFile, $Content)
            $ctx = Invoke-Probe
            $ctx | Should -Not -BeNullOrEmpty
            Should -Invoke Start-SwBackgroundProcess -Times 1 -Exactly -Scope It
            $null = Invoke-Probe
            Should -Invoke Start-SwBackgroundProcess -Times 1 -Exactly -Scope It
        }

        It 'Treats an entry from the future as missing (V-10)' {
            $real = $script:Now
            $script:Now = $real.AddHours(2)
            $null = Invoke-Probe
            $script:Now = $real
            $null = Invoke-Probe
            Should -Invoke Start-SwBackgroundProcess -Times 2 -Exactly -Scope It
        }

        It 'Returns $null without throwing when the cache folder cannot be found (V-11)' {
            Mock Get-CachePath { throw 'no cache folder' }
            { Invoke-Probe } | Should -Not -Throw
            Invoke-Probe | Should -BeNullOrEmpty
            Should -Invoke Start-SwBackgroundProcess -Times 0 -Exactly -Scope It
        }

        It 'Returns $null without throwing or output when the process start fails (V-11)' {
            Mock Start-SwBackgroundProcess { throw 'cannot start' }
            $records = @(Invoke-Probe *>&1 | Where-Object { $null -ne $_ })
            $records.Count | Should -Be 0
        }

        It 'Returns $null when the cache file cannot be written (V-11)' {
            New-Item -ItemType Directory -Path $script:CacheFile | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $script:CacheFile 'inner.txt'), 'keep')
            $records = @(Invoke-Probe *>&1 | Where-Object { $null -ne $_ })
            $records.Count | Should -Be 0
            Should -Invoke Start-SwBackgroundProcess -Times 0 -Exactly -Scope It
            [System.IO.File]::ReadAllText((Join-Path $script:CacheFile 'inner.txt')) | Should -Be 'keep'
        }

        It 'Never uses Start-Process (spec 4.1)' {
            $null = Invoke-Probe
            Should -Invoke Start-Process -Times 0 -Exactly -Scope It
        }
    }

    Context 'The background command (V-15)' {
        BeforeEach {
            $script:Ctx = Invoke-Probe -Version '1.0.0' -Method 'Source'
            $script:Info = Get-StartInfo
        }

        It 'Starts Windows PowerShell by its absolute path under SystemRoot' {
            $expected = (($env:SystemRoot).TrimEnd('\') + '\System32\WindowsPowerShell\v1.0\powershell.exe')
            $script:Info.Joined.IndexOf($expected, [StringComparison]::OrdinalIgnoreCase) | Should -BeGreaterOrEqual 0
        }

        It 'Uses -NoProfile, -NonInteractive and -ExecutionPolicy Bypass' {
            $script:Info.Joined | Should -Match '(?i)(^|\s|")-NoProfile(\s|"|$)'
            $script:Info.Joined | Should -Match '(?i)(^|\s|")-NonInteractive(\s|"|$)'
            $script:Info.Joined | Should -Match '(?i)-ExecutionPolicy\s+"?Bypass'
        }

        It 'Passes the command as -EncodedCommand of UTF-16LE text that parses without errors' {
            $script:Info.Base64 | Should -Not -BeNullOrEmpty
            $script:Info.CommandText | Should -Not -BeNullOrEmpty
            (Get-CommandAst $script:Info.CommandText).Errors.Count | Should -Be 0
        }

        It 'Dot-sources update_check.ps1 of the given root and calls Invoke-SwUpdateLookup' {
            $ast = (Get-CommandAst $script:Info.CommandText).Ast
            $commands = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
            @($commands | Where-Object { $_.GetCommandName() -eq 'Invoke-SwUpdateLookup' }).Count | Should -BeGreaterThan 0
            @($commands | Where-Object { $_.InvocationOperator -eq 'Dot' }).Count | Should -BeGreaterThan 0
            $script:Info.CommandText.Replace('/', '\') | Should -Match ([regex]::Escape(($script:RepoRoot.Replace('/', '\')).TrimEnd('\')))
            $script:Info.CommandText | Should -Match '(?i)update_check\.ps1'
        }

        It 'Stops on errors and shows no progress' {
            $script:Info.CommandText | Should -Match "(?i)\`$ErrorActionPreference\s*=\s*'Stop'"
            $script:Info.CommandText | Should -Match "(?i)\`$ProgressPreference\s*=\s*'SilentlyContinue'"
        }
    }

    Context 'The lookup (V-12 to V-14, V-17, V-18)' {
        BeforeEach { Set-StandardResponses }

        It 'Asks <Url> for channel <Method> (V-12)' -ForEach @(
            @{ Method = 'Source'; Url = 'releases' }
            @{ Method = 'Portable'; Url = 'releases' }
            @{ Method = 'Copy'; Url = 'releases' }
            @{ Method = 'source'; Url = 'releases' }
            @{ Method = 'Something'; Url = 'releases' }
            @{ Method = 'winget'; Url = 'winget' }
            @{ Method = 'WinGet'; Url = 'winget' }
            @{ Method = 'Scoop'; Url = 'scoop' }
            @{ Method = 'SCOOP'; Url = 'scoop' }
        ) {
            $expected = @{ releases = $script:ReleasesUrl; winget = $script:WingetUrl; scoop = $script:ScoopUrl }[$Url]
            $null = Invoke-ProbeAndLookup -Method $Method
            $script:Requests.Count | Should -BeGreaterThan 0
            foreach ($request in $script:Requests) { $request.Uri | Should -BeExactly $expected }
        }

        It 'Picks <Expected> for channel <Method> (V-13)' -ForEach @(
            @{ Method = 'Source'; Expected = '1.10.0' }
            @{ Method = 'winget'; Expected = '1.10.0' }
            @{ Method = 'Scoop'; Expected = '1.8.0' }
        ) {
            $ctx = Invoke-ProbeAndLookup -Version '1.0.0' -Method $Method
            $hint = Get-SwUpdateHint -Context $ctx
            $hint | Should -Match ([regex]::Escape($Expected))
            foreach ($other in @('9.99.0', '1.99.0', '1.98.0', '1.97.0', '1.11.0', '9.0.0', '3.0.0', '4.0.0', '123456', '100000')) {
                $hint | Should -Not -Match ([regex]::Escape($other))
            }
        }

        It 'Compares versions numerically (V-13)' {
            $script:Responses[$script:ScoopUrl] = '{"version":"1.10.0"}'
            $ctx = Invoke-ProbeAndLookup -Version '1.9.0' -Method 'Scoop'
            Get-SwUpdateHint -Context $ctx | Should -Match '1\.10\.0'
        }

        It 'Uses a 10 second timeout, a User-Agent and the GitHub Accept header (V-14)' {
            $null = Invoke-ProbeAndLookup -Method 'Source'
            $script:Requests.Count | Should -BeGreaterThan 0
            foreach ($request in $script:Requests) {
                # pwsh 7.4 binds -TimeoutSec to its alias target ConnectionTimeoutSeconds.
                $timeout = $null
                foreach ($name in 'TimeoutSec', 'ConnectionTimeoutSeconds', 'OperationTimeoutSeconds') {
                    if ($null -eq $timeout -and $request.Bound.ContainsKey($name)) { $timeout = $request.Bound[$name] }
                }
                $timeout | Should -Be 10
                $headers = $request.Bound['Headers']
                $agent = $request.Bound['UserAgent']
                if (-not $agent -and $headers) { foreach ($k in @($headers.Keys)) { if ($k -ieq 'User-Agent') { $agent = $headers[$k] } } }
                $agent | Should -Not -BeNullOrEmpty
                $accept = $null
                if ($headers) { foreach ($k in @($headers.Keys)) { if ($k -ieq 'Accept') { $accept = $headers[$k] } } }
                $accept | Should -Be 'application/vnd.github+json'
                $request.Bound.ContainsKey('Credential') | Should -BeFalse
                $request.Bound.ContainsKey('Token') | Should -BeFalse
            }
        }

        It 'Enables TLS 1.2 under Windows PowerShell and keeps the other protocols (V-14)' -Skip:($PSVersionTable.PSEdition -ne 'Desktop') {
            $saved = [System.Net.ServicePointManager]::SecurityProtocol
            try {
                [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls11
                $null = Invoke-ProbeAndLookup -Method 'Source'
                $now = [System.Net.ServicePointManager]::SecurityProtocol
                ($now -band [System.Net.SecurityProtocolType]::Tls12) | Should -Be ([System.Net.SecurityProtocolType]::Tls12)
                ($now -band [System.Net.SecurityProtocolType]::Tls11) | Should -Be ([System.Net.SecurityProtocolType]::Tls11)
            }
            finally { [System.Net.ServicePointManager]::SecurityProtocol = $saved }
        }

        It 'Stores a found version for one day (V-17, V-21)' {
            $t0 = $script:Now
            $ctx = Invoke-ProbeAndLookup -Version '1.0.0' -Method 'Scoop'
            Get-SwUpdateHint -Context $ctx | Should -Match '1\.8\.0'
            $script:Now = $t0.AddHours(23)
            $ctx2 = Invoke-Probe -Version '1.0.0' -Method 'Scoop'
            Should -Invoke Start-SwBackgroundProcess -Times 1 -Exactly -Scope It
            Get-SwUpdateHint -Context $ctx2 | Should -Match '1\.8\.0'
            $script:Now = $t0.AddHours(24).AddMinutes(1)
            Get-SwUpdateHint -Context $ctx2 | Should -BeNullOrEmpty
            $null = Invoke-Probe -Version '1.0.0' -Method 'Scoop'
            Should -Invoke Start-SwBackgroundProcess -Times 2 -Exactly -Scope It
        }

        It 'Creates no entry when the cache file was removed meanwhile (V-17)' {
            $null = Invoke-Probe -Method 'Scoop'
            Remove-Item -LiteralPath $script:CacheFile -Force
            Invoke-CapturedLookup
            [System.IO.File]::Exists($script:CacheFile) | Should -BeFalse
        }

        It 'Does not update an entry that belongs to another key (V-17)' {
            $null = Invoke-Probe -Version '1.0.0' -Method 'Scoop'
            $null = Invoke-Probe -Version '1.0.1' -Method 'Scoop'
            $before = Get-FileBytes $script:CacheFile
            Invoke-CapturedLookup -Index 0
            Get-FileBytes $script:CacheFile | Should -Be $before
        }

        It 'Leaves the entry unchanged when <Name> (V-18)' -ForEach @(
            @{ Name = 'the network fails'; Body = $null }
            @{ Name = 'the version is a pre-release'; Body = '{"version":"1.10.0-beta"}' }
            @{ Name = 'the version carries more lines'; Body = '{"version":"1.10.0\nWrite-Host pwned"}' }
            @{ Name = 'the version has an escape sequence'; Body = '{"version":"1.10.0\u001b[2J"}' }
            @{ Name = 'the version is missing'; Body = '{"name":"sweepr"}' }
            @{ Name = 'the answer is not JSON'; Body = '<html>rate limit</html>' }
        ) {
            $script:Responses[$script:ScoopUrl] = $Body
            $ctx = Invoke-Probe -Version '1.0.0' -Method 'Scoop'
            $before = Get-FileBytes $script:CacheFile
            Invoke-CapturedLookup
            Get-FileBytes $script:CacheFile | Should -Be $before
            Get-SwUpdateHint -Context $ctx | Should -BeNullOrEmpty
            $script:Now = $script:Now.AddMinutes(30)
            $null = Invoke-Probe -Version '1.0.0' -Method 'Scoop'
            Should -Invoke Start-SwBackgroundProcess -Times 1 -Exactly -Scope It
        }

        It 'Leaves the entry unchanged when the releases have no stable Windows tag (V-13, V-18)' {
            $script:Responses[$script:ReleasesUrl] = '[{"tag_name":"V2.0.0-windows","draft":true,"prerelease":false,"name":"x"},{"tag_name":"V2.0.0","draft":false,"prerelease":false,"name":"y"}]'
            $ctx = Invoke-Probe -Version '1.0.0' -Method 'Source'
            $before = Get-FileBytes $script:CacheFile
            Invoke-CapturedLookup
            Get-FileBytes $script:CacheFile | Should -Be $before
            Get-SwUpdateHint -Context $ctx | Should -BeNullOrEmpty
        }
    }

    Context 'Quoting of the background command (V-16, B-01)' {
        BeforeAll {
            $fixture = @'
$script:SwFixtureRoot = $PSScriptRoot
function Invoke-SwUpdateLookup {
    $hex = { param($t) -join ([string]$t).ToCharArray().ForEach({ '{0:X4}' -f [int]$_ }) }
    $lines = @('ROOT ' + (& $hex $script:SwFixtureRoot))
    foreach ($a in $args) { $lines += 'ARG ' + (& $hex $a) }
    [System.IO.File]::WriteAllLines($env:SW_TEST_RECORD, [string[]]$lines)
}
'@
            $script:FixtureText = $fixture

            function script:Invoke-QuotingCase {
                param([string]$Name, [string]$Value)
                $base = Join-Path $TestDrive ('q-' + [guid]::NewGuid().ToString('N'))
                $root = [System.IO.Path]::Combine($base, 'root', $Value)
                $cache = [System.IO.Path]::Combine($base, 'cache', $Value)
                $work = [System.IO.Path]::Combine($base, 'work')
                foreach ($dir in @([System.IO.Path]::Combine($root, 'lib', 'core'), $cache, $work)) { [void][System.IO.Directory]::CreateDirectory($dir) }
                [System.IO.File]::WriteAllText([System.IO.Path]::Combine($root, 'lib', 'core', 'update_check.ps1'), $script:FixtureText)
                $script:CacheDir = $cache
                $script:CacheFile = [System.IO.Path]::Combine($cache, 'update-check.json')
                $ctx = Start-SwUpdateProbe -RootDir $root -Version '1.0.0' -Method 'Source'
                [pscustomobject]@{ Base = $base; Root = $root; Cache = $cache; Work = $work; Context = $ctx }
            }

            function script:Invoke-CapturedInChild {
                param($Case)
                $info = Get-StartInfo
                $record = [System.IO.Path]::Combine($Case.Base, 'record.txt')
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = (Get-Process -Id $PID).Path
                $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $($info.Base64)"
                $psi.UseShellExecute = $false
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.WorkingDirectory = $Case.Work
                $psi.EnvironmentVariables['SW_TEST_RECORD'] = $record
                $process = [System.Diagnostics.Process]::Start($psi)
                $null = $process.StandardOutput.ReadToEndAsync()
                $null = $process.StandardError.ReadToEndAsync()
                if (-not $process.WaitForExit(120000)) { $process.Kill(); throw 'child PowerShell timed out' }
                if (-not [System.IO.File]::Exists($record)) { return $null }
                $root = $null; $argsHex = @()
                foreach ($line in [System.IO.File]::ReadAllLines($record)) {
                    if ($line.StartsWith('ROOT ')) { $root = $line.Substring(5) }
                    elseif ($line.StartsWith('ARG ')) { $argsHex += $line.Substring(4) }
                }
                [pscustomobject]@{ RootHex = $root; ArgsHex = $argsHex }
            }

            function script:Assert-NoInjection([string]$Text) {
                $parsed = Get-CommandAst $Text
                $parsed.Errors.Count | Should -Be 0
                $names = @($parsed.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
                $names | Should -Not -Contain 'New-Item'
                $names | Should -Not -Contain 'Get-Date'
                $vars = @($parsed.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.VariablePath.UserPath })
                $vars | Should -Not -Contain 'env:PATH'
            }

            function script:Get-QuotedStrings([string]$Text) {
                $ast = (Get-CommandAst $Text).Ast
                @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.StringConstantType -eq 'SingleQuoted' }, $true) |
                        ForEach-Object { $_.Value.Replace('/', '\') })
            }
        }

        It 'Keeps the root <Name> as a single literal in the command' -ForEach $script:PathCases {
            $case = Invoke-QuotingCase -Name $Name -Value $Value
            $text = (Get-StartInfo).CommandText
            Assert-NoInjection $text
            $rootNorm = $case.Root.Replace('/', '\')
            $cacheNorm = $case.Cache.Replace('/', '\')
            $strings = Get-QuotedStrings $text
            @($strings | Where-Object { $_.StartsWith($rootNorm, [StringComparison]::Ordinal) }).Count | Should -BeGreaterThan 0
            @($strings | Where-Object { $_.StartsWith($cacheNorm, [StringComparison]::Ordinal) }).Count | Should -BeGreaterThan 0
        }

        It 'Keeps the root <Name> as a single literal in the command (non-Windows names)' -ForEach $script:UnixPathCases -Skip:$script:OnWindows {
            $case = Invoke-QuotingCase -Name $Name -Value $Value
            $text = (Get-StartInfo).CommandText
            Assert-NoInjection $text
            $strings = Get-QuotedStrings $text
            @($strings | Where-Object { $_.StartsWith($case.Root.Replace('/', '\'), [StringComparison]::Ordinal) }).Count | Should -BeGreaterThan 0
            @($strings | Where-Object { $_.StartsWith($case.Cache.Replace('/', '\'), [StringComparison]::Ordinal) }).Count | Should -BeGreaterThan 0
        }

        It 'Runs no code from the channel <Name>' -ForEach $script:MethodCases {
            $null = Start-SwUpdateProbe -RootDir $script:RepoRoot -Version '1.0.0' -Method $Value
            Assert-NoInjection (Get-StartInfo).CommandText
        }

        It 'Delivers root and cache path <Name> unchanged to the background process' -ForEach $script:PathCases {
            $case = Invoke-QuotingCase -Name $Name -Value $Value
            $result = Invoke-CapturedInChild -Case $case
            $result | Should -Not -BeNullOrEmpty -Because 'the fixture update_check.ps1 in the given root must have run'
            $expectedRoot = ConvertTo-Hex ([System.IO.Path]::GetFullPath([System.IO.Path]::Combine($case.Root, 'lib', 'core')))
            $result.RootHex | Should -Be $expectedRoot
            $cacheForms = @(
                (ConvertTo-Hex ([System.IO.Path]::GetFullPath($case.Cache)))
                (ConvertTo-Hex ([System.IO.Path]::GetFullPath([System.IO.Path]::Combine($case.Cache, 'update-check.json'))))
            )
            $normalized = @(foreach ($h in $result.ArgsHex) {
                    $chars = for ($i = 0; $i -lt $h.Length; $i += 4) { [char][Convert]::ToInt32($h.Substring($i, 4), 16) }
                    $text = -join $chars
                    if ($text) {
                        if (-not $script:OnWindows) { $text = $text.Replace('\', '/') }
                        try { ConvertTo-Hex ([System.IO.Path]::GetFullPath($text)) } catch { $h }
                    }
                })
            @($normalized | Where-Object { $_ -in $cacheForms }).Count | Should -BeGreaterThan 0
            @(Get-ChildItem -LiteralPath $case.Base -Recurse -Force -Filter 'marker').Count | Should -Be 0
        }
    }

    Context 'Reparse points (V-19)' {
        It 'Does not write when the cache folder is a link' {
            $target = Join-Path $TestDrive ('link-target-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $target | Out-Null
            $link = Join-Path $TestDrive ('link-' + [guid]::NewGuid().ToString('N'))
            New-DirLink -Link $link -Target $target
            $script:CacheDir = $link
            $script:CacheFile = Join-Path $link 'update-check.json'
            Invoke-Probe | Should -BeNullOrEmpty
            @(Get-ChildItem -LiteralPath $target -Force).Count | Should -Be 0
            Should -Invoke Start-SwBackgroundProcess -Times 0 -Exactly -Scope It
        }

        It 'Does not write when a parent of the cache folder is a link' {
            $target = Join-Path $TestDrive ('parent-target-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $target 'cache') -Force | Out-Null
            $link = Join-Path $TestDrive ('parent-link-' + [guid]::NewGuid().ToString('N'))
            New-DirLink -Link $link -Target $target
            $script:CacheDir = Join-Path $link 'cache'
            $script:CacheFile = Join-Path $script:CacheDir 'update-check.json'
            Invoke-Probe | Should -BeNullOrEmpty
            @(Get-ChildItem -LiteralPath (Join-Path $target 'cache') -Force).Count | Should -Be 0
        }

        It 'Does not write through a cache file that is a link' {
            $outside = Join-Path $TestDrive ('outside-' + [guid]::NewGuid().ToString('N') + '.txt')
            [System.IO.File]::WriteAllText($outside, 'untouched')
            try { New-Item -ItemType SymbolicLink -Path $script:CacheFile -Target $outside -ErrorAction Stop | Out-Null }
            catch { Set-ItResult -Skipped -Because 'creating a file symbolic link needs a privilege here'; return }
            Invoke-Probe | Should -BeNullOrEmpty
            [System.IO.File]::ReadAllText($outside) | Should -BeExactly 'untouched'
        }

        It 'Does not let the background lookup write through a link' {
            Set-StandardResponses
            $null = Invoke-Probe -Method 'Scoop'
            $moved = $script:CacheDir + '-moved'
            Move-Item -LiteralPath $script:CacheDir -Destination $moved
            New-DirLink -Link $script:CacheDir -Target $moved
            $before = Get-FileBytes (Join-Path $moved 'update-check.json')
            Invoke-CapturedLookup
            Get-FileBytes (Join-Path $moved 'update-check.json') | Should -Be $before
        }
    }

    Context 'Writing the cache file (V-20)' {
        It 'Leaves no temporary file and keeps other files' {
            Set-StandardResponses
            foreach ($other in 'update-check.json.tmp', 'other.tmp', 'keep.txt') {
                [System.IO.File]::WriteAllText((Join-Path $script:CacheDir $other), "content of $other")
            }
            $null = Invoke-ProbeAndLookup -Method 'Scoop'
            $names = @(Get-ChildItem -LiteralPath $script:CacheDir -Force | ForEach-Object { $_.Name } | Sort-Object)
            $names | Should -Be @('keep.txt', 'other.tmp', 'update-check.json', 'update-check.json.tmp')
            foreach ($other in 'update-check.json.tmp', 'other.tmp', 'keep.txt') {
                [System.IO.File]::ReadAllText((Join-Path $script:CacheDir $other)) | Should -BeExactly "content of $other"
            }
        }

        It 'Leaves no temporary file when writing fails' {
            New-Item -ItemType Directory -Path $script:CacheFile | Out-Null
            $null = Invoke-Probe
            @(Get-ChildItem -LiteralPath $script:CacheDir -Force).Count | Should -Be 1
        }
    }

    Context 'The hint (V-21 to V-24)' {
        It 'Gives nothing for a $null context (V-21)' {
            Get-SwUpdateHint -Context $null | Should -BeNullOrEmpty
        }

        It 'Gives nothing when the known version is <Known> and <Running> runs (V-21)' -ForEach @(
            @{ Known = '1.9.0'; Running = '1.9.0' }
            @{ Known = '1.8.9'; Running = '1.9.0' }
            @{ Known = '1.9.0'; Running = '1.10.0' }
        ) {
            Set-LatestEverywhere $Known
            $ctx = Invoke-ProbeAndLookup -Version $Running -Method 'Scoop'
            Get-SwUpdateHint -Context $ctx | Should -BeNullOrEmpty
        }

        It 'Gives nothing when the cache file was broken afterwards (V-21)' {
            Set-LatestEverywhere '2.0.7'
            $ctx = Invoke-ProbeAndLookup -Version '1.0.0' -Method 'Scoop'
            [System.IO.File]::WriteAllText($script:CacheFile, '{ broken')
            { Get-SwUpdateHint -Context $ctx } | Should -Not -Throw
            Get-SwUpdateHint -Context $ctx | Should -BeNullOrEmpty
        }

        It 'Gives exactly one line for channel <Method> with <Expected> (V-22)' -ForEach @(
            @{ Method = 'winget'; Expected = 'winget upgrade brummilab.Sweepr' }
            @{ Method = 'Scoop'; Expected = 'scoop update sweepr' }
            @{ Method = 'Source'; Expected = 'sw update' }
            @{ Method = 'Portable'; Expected = 'sweepr-2.0.7-x64-portable.zip' }
            @{ Method = 'Copy'; Expected = 'https://github.com/brummilab/sweepr/releases/tag/V2.0.7-windows' }
            @{ Method = 'Unknown'; Expected = 'https://github.com/brummilab/sweepr/releases/tag/V2.0.7-windows' }
        ) {
            Set-LatestEverywhere '2.0.7'
            $ctx = Invoke-ProbeAndLookup -Version '1.9.3' -Method $Method
            $hint = @(Get-SwUpdateHint -Context $ctx)
            $hint.Count | Should -Be 1
            $hint[0] | Should -BeOfType [string]
            $hint[0] | Should -Not -Match "[`r`n]"
            $hint[0].Contains($Expected) | Should -BeTrue
            $hint[0].Contains('2.0.7') | Should -BeTrue
        }

        It 'Points Portable users to the release page and the new package (V-22)' {
            Set-LatestEverywhere '2.0.7'
            $ctx = Invoke-ProbeAndLookup -Version '1.9.3' -Method 'Portable'
            $hint = Get-SwUpdateHint -Context $ctx
            $hint.Contains('https://github.com/brummilab/sweepr/releases') | Should -BeTrue
            $hint.Contains('sweepr-1.9.3-x64-portable.zip') | Should -BeFalse
        }

        It 'Does not mention portable for channel <Method> (V-22)' -ForEach @(
            @{ Method = 'Copy' }
            @{ Method = 'Unknown' }
        ) {
            Set-LatestEverywhere '2.0.7'
            $ctx = Invoke-ProbeAndLookup -Version '1.9.3' -Method $Method
            Get-SwUpdateHint -Context $ctx | Should -Not -Match '(?i)portable'
        }

        It 'Shows the hint in the same run when the lookup has finished (V-24)' {
            Set-LatestEverywhere '1.10.0'
            $ctx = Invoke-Probe -Version '1.9.0' -Method 'Source'
            Get-SwUpdateHint -Context $ctx | Should -BeNullOrEmpty
            Invoke-CapturedLookup
            $hint = Get-SwUpdateHint -Context $ctx
            $hint | Should -Match '1\.10\.0'
            $hint | Should -Match ([regex]::Escape('sw update'))
        }

        It 'Reads only the cache: no network, no process (V-24)' {
            Set-LatestEverywhere '2.0.7'
            $ctx = Invoke-ProbeAndLookup -Version '1.0.0' -Method 'Scoop'
            $script:Requests.Clear()
            $script:StartCalls.Clear()
            $null = Get-SwUpdateHint -Context $ctx
            $null = Write-SwUpdateHint -Context $ctx 6>&1
            $script:Requests.Count | Should -Be 0
            $script:StartCalls.Count | Should -Be 0
        }

        It 'Writes one yellow line to the host (V-23)' {
            Set-LatestEverywhere '2.0.7'
            $ctx = Invoke-ProbeAndLookup -Version '1.0.0' -Method 'Scoop'
            $records = @(Write-SwUpdateHint -Context $ctx 6>&1)
            @($records | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] }).Count | Should -Be 0
            $text = ConvertTo-HostText $records
            $plain = [regex]::Replace($text, "$([char]27)\[[0-9;]*m", '').Trim("`n")
            $plain.Contains('2.0.7') | Should -BeTrue
            $plain | Should -Not -Match "`n"
            $yellowAnsi = $text.Contains($script:Palette.Yellow)
            $yellowHost = @($records | Where-Object {
                    $_ -is [System.Management.Automation.InformationRecord] -and
                    $_.MessageData -is [System.Management.Automation.HostInformationMessage] -and
                    $_.MessageData.ForegroundColor -eq [ConsoleColor]::Yellow
                }).Count -gt 0
            ($yellowAnsi -or $yellowHost) | Should -BeTrue
        }

        It 'Writes nothing for a $null context (V-23)' {
            @(Write-SwUpdateHint -Context $null *>&1 | Where-Object { $null -ne $_ }).Count | Should -Be 0
        }

        It 'Swallows a broken cache file (V-23)' {
            $ctx = Invoke-Probe -Version '1.0.0' -Method 'Scoop'
            [System.IO.File]::WriteAllText($script:CacheFile, [string][char]0 + 'garbage')
            { Write-SwUpdateHint -Context $ctx } | Should -Not -Throw
            @(Write-SwUpdateHint -Context $ctx *>&1 | Where-Object { $null -ne $_ }).Count | Should -Be 0
        }
    }

    Context 'Transition names (L7-1)' {
        It 'Keeps <Name> as a function, not an alias' -ForEach @(
            @{ Name = 'Test-SweeprUpdateNoticeAllowed' }
            @{ Name = 'Start-SweeprUpdateCheck' }
            @{ Name = 'Show-SweeprUpdateNotice' }
        ) {
            (Get-Command -Name $Name -ErrorAction Stop).CommandType | Should -Be 'Function'
            Get-Alias -Name $Name -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }

        It 'Start-SweeprUpdateCheck forwards to Start-SwUpdateProbe' {
            Mock Start-SwUpdateProbe { 'context-from-new-name' }
            Start-SweeprUpdateCheck -RootDir 'X:\Example' -Version '1.2.3' -Method 'Scoop' | Should -Be 'context-from-new-name'
            Should -Invoke Start-SwUpdateProbe -Times 1 -Exactly -Scope It -ParameterFilter {
                $RootDir -eq 'X:\Example' -and $Version -eq '1.2.3' -and $Method -eq 'Scoop'
            }
        }

        It 'Start-SweeprUpdateCheck behaves like Start-SwUpdateProbe' {
            Start-SweeprUpdateCheck -RootDir $script:RepoRoot -Version '0.2.0-beta.1' -Method 'Source' | Should -BeNullOrEmpty
            $ctx = Start-SweeprUpdateCheck -RootDir $script:RepoRoot -Version '1.0.0' -Method 'Source'
            $ctx | Should -Not -BeNullOrEmpty
            Should -Invoke Start-SwBackgroundProcess -Times 1 -Exactly -Scope It
        }

        It 'Show-SweeprUpdateNotice forwards to Write-SwUpdateHint' {
            Mock Write-SwUpdateHint { }
            Show-SweeprUpdateNotice -Context 'some-context'
            Should -Invoke Write-SwUpdateHint -Times 1 -Exactly -Scope It -ParameterFilter { $Context -eq 'some-context' }
        }

        It 'Show-SweeprUpdateNotice writes the same line as Write-SwUpdateHint' {
            Set-LatestEverywhere '2.0.7'
            $ctx = Invoke-ProbeAndLookup -Version '1.0.0' -Method 'Source'
            $old = ConvertTo-HostText @(Show-SweeprUpdateNotice -Context $ctx 6>&1)
            $new = ConvertTo-HostText @(Write-SwUpdateHint -Context $ctx 6>&1)
            $old | Should -BeExactly $new
            $old | Should -Not -BeNullOrEmpty
        }
    }
}
