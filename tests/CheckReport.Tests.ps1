# Sweepr - F-03c: the HTML report of sw check (Design Rev 4 section 20, decisions E24, E25, E28, E30)
#
# `sw check --report` hands the result object to Invoke-SweeprCheckReport. This file pins that report.
# Platform neutral: nothing real is read or changed. The folder of the report is a TestDrive folder, the
# browser opener is a mock, the child process of the integration test has a private profile and temp folder.
#
# Interface fixed by these tests (the implementer builds exactly this in lib\core\report.ps1, plain ASCII,
# loaded by bin\check.ps1 after core\ui.ps1, listed in install.ps1):
#
#   ConvertTo-SweeprCheckHtml -Result <object>          pure: returns ONE string, the whole HTML document. It
#       depends only on -Result (no clock, no environment, no file access): same input, same output. Sizes are
#       written with Format-ByteSize (core\base.ps1), counts and numbers as plain invariant text (1234, 62.5).
#   Get-SweeprCheckReportDir                            the folder of the report: $env:TEMP, else the .NET temp
#       path. A function so that tests can mock it.
#   Open-SweeprCheckReport -Path <string>               opens the file in the default browser. The ONLY place
#       that starts a program. A function so that tests can mock it.
#   Invoke-SweeprCheckReport -Result <object> [-NoOpen] makes <dir>\sweepr-check-<yyyy-MM-dd-HHmmss>.html (local
#       time of "now"), UTF-8, with exactly the text of ConvertTo-SweeprCheckHtml; opens it with
#       Open-SweeprCheckReport unless -NoOpen; returns the path as ONE string and nothing else.
#       It creates no folder: a missing or unusable folder or any write error is thrown (bin\check.ps1 then says
#       "could not be created"). When only the opening fails, the report exists and counts as made: the path is
#       returned and nothing is thrown. A $null -Result is refused (mandatory parameter).
#
#   Document: <!doctype html>, <meta charset="utf-8">, the meta element
#       <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
#       before any <style>/<body>; no script, no external resource, no link/form/iframe/img. Only these elements
#       occur: html head meta title style body header main section footer h1 h2 h3 p ul ol li table thead tbody
#       tr th td details summary div span code strong em br, and a with an href that starts with "#". Every value
#       goes through [System.Net.WebUtility]::HtmlEncode. Only properties of the result are shown, nothing from
#       the environment (no user, computer or domain name, no report path).
#   Structure (ids are fixed; sections do not nest):
#       <section id="clean">     heading "Cleanup potential": total size, file count, every group (name, size,
#                                count), ONE <details> with the top paths (at most 20, in the given order).
#       <section id="apps">      heading "Apps and features": count and the titles of the items.
#       <section id="system">    heading "System health": drives (letter, free, size), memory used percent,
#                                uptime days, last update and recent update ids, pending updates, startup entries
#                                (name, source); a part with Measured = $false says "not measured".
#       <section id="projects">  heading "Project artifacts": total size, count, the word "incomplete" when
#                                Complete is $false, ONE <details> with the top paths (at most 20).
#       <section id="not-measured"> (only with entries) every entry: name and reason.
#       <p id="admin-hint">      only when IsAdmin is $false; says to run Sweepr in an administrator PowerShell.
#       The version and the GeneratedAt text of the result appear in the document.
#   A section whose Status is 'error' shows the word "error", no <details>, no other text of that section.

BeforeAll {
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    $script:LibDir = Join-Path $script:WindowsDir 'lib'
    $script:ReportFile = Join-Path $script:LibDir 'core\report.ps1'
    $script:BinFile = Join-Path $script:WindowsDir 'bin\check.ps1'
    $script:SweeprFile = Join-Path $script:WindowsDir 'sweepr.ps1'
    $script:InstallFile = Join-Path $script:WindowsDir 'install.ps1'

    foreach ($module in @('core\base', 'core\log', 'core\ui', 'core\file_ops')) { . (Join-Path $script:LibDir "$module.ps1") }
    if (Test-Path -LiteralPath $script:ReportFile) { . $script:ReportFile }

    $script:Gb = [long]1073741824

    function script:Enc([string]$Text) { return [System.Net.WebUtility]::HtmlEncode($Text) }

    # A hostile value: script tag, both quote characters, ampersands (also an entity), an image with a handler.
    function script:Evil([string]$Tag) {
        return "<script>alert('$Tag')</script>`"&amp;&<img src=x onerror=alert(`"$Tag`")>'"
    }

    function script:New-TopPaths([int]$Count, [string]$Prefix) {
        $list = New-Object System.Collections.ArrayList
        for ($n = 1; $n -le $Count; $n++) {
            [void]$list.Add([pscustomobject][ordered]@{
                    Section   = 'User caches'
                    Path      = ('~\{0}\Item{1:00}' -f $Prefix, $n)
                    SizeBytes = [long](($Count - $n + 1) * 1048576)
                    Count     = $n
                })
        }
        return $list.ToArray()
    }

    function script:New-TestResult {
        $projectTop = @(
            [pscustomobject][ordered]@{ Path = '~\Documents\ExampleApp'; Name = 'ExampleApp'; TotalBytes = [long](1.5 * $script:Gb); SizeComplete = $true }
            [pscustomobject][ordered]@{ Path = '~\Source\SampleTool'; Name = 'SampleTool'; TotalBytes = [long](0.5 * $script:Gb); SizeComplete = $true }
        )
        return [pscustomobject][ordered]@{
            Version     = '9.8.7-test'
            GeneratedAt = '2026-10-26T10:11:12+01:00'
            IsAdmin     = $true
            Sections    = [pscustomobject][ordered]@{
                Clean    = [pscustomobject][ordered]@{
                    Status = 'ok'; Reason = $null; IncludesSystem = $false
                    TotalBytes = [long](5 * $script:Gb); Count = 1234
                    Groups = @(
                        [pscustomobject][ordered]@{ Name = 'User essentials'; TotalBytes = [long]$script:Gb; Count = 100 }
                        [pscustomobject][ordered]@{ Name = 'Browser caches'; TotalBytes = [long](4 * $script:Gb); Count = 1134 }
                    )
                    Top = @(New-TopPaths 20 'AppData\Local\Example')
                }
                Apps     = [pscustomobject][ordered]@{
                    Status = 'ok'; Reason = $null; Count = 2; NeedsAdmin = $false
                    Items = @(
                        [pscustomobject][ordered]@{ Id = 'Contoso.Sample'; Kind = 'Appx'; Title = 'Contoso Sample App' }
                        [pscustomobject][ordered]@{ Id = 'Fabrikam.Demo'; Kind = 'Feature'; Title = 'Fabrikam Demo Feature' }
                    )
                }
                System   = [pscustomobject][ordered]@{
                    Status = 'ok'; Reason = $null
                    Disks = [pscustomobject][ordered]@{
                        Measured = $true
                        Drives = @([pscustomobject][ordered]@{ Drive = 'C:'; SizeBytes = [long](500 * $script:Gb); FreeBytes = [long](125 * $script:Gb); FreePercent = 25; IsSystem = $true; Health = 'Healthy' })
                    }
                    Memory = [pscustomobject][ordered]@{ Measured = $true; TotalBytes = [long](16 * $script:Gb); FreeBytes = [long](6 * $script:Gb); UsedBytes = [long](10 * $script:Gb); UsedPercent = 62.5 }
                    Uptime = [pscustomobject][ordered]@{ Measured = $true; LastBoot = '2026-10-21T08:00:00'; UptimeDays = 5.2 }
                    Updates = [pscustomobject][ordered]@{
                        Measured = $true; LastInstalledOn = '2026-10-14T03:00:00'
                        Recent = @([pscustomobject][ordered]@{ Id = 'KB5000001'; InstalledOn = '2026-10-14T03:00:00' })
                    }
                    PendingUpdates = [pscustomobject][ordered]@{ Measured = $true; Total = 7; Important = 3 }
                    Startup = [pscustomobject][ordered]@{
                        Measured = $true; Count = 2
                        Entries = @(
                            [pscustomobject][ordered]@{ Name = 'ExampleSync'; Source = 'HKCU Run' }
                            [pscustomobject][ordered]@{ Name = 'SampleUpdater'; Source = 'Startup folder' }
                        )
                    }
                }
                Projects = [pscustomobject][ordered]@{
                    Status = 'ok'; Reason = $null; Count = 2; TotalBytes = [long](2 * $script:Gb)
                    Complete = $true; TimedOut = $false; SkippedUnverified = 0
                    Top = $projectTop
                }
            }
            NotMeasured = @(
                [pscustomobject][ordered]@{ Section = 'Clean'; Name = 'npm'; Reason = 'external tool' }
                [pscustomobject][ordered]@{ Section = 'System'; Name = 'PendingUpdates'; Reason = 'not available' }
            )
        }
    }

    function script:Get-Section([string]$Html, [string]$Id) {
        $m = [regex]::Match($Html, '(?s)<section\s+id="' + $Id + '"[^>]*>(.*?)</section>')
        if (-not $m.Success) { throw "no section '$Id' in the report" }
        return $m.Groups[1].Value
    }

    function script:Get-TagNames([string]$Html) {
        return @([regex]::Matches($Html, '<\s*/?\s*([A-Za-z][A-Za-z0-9]*)') | ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() })
    }

    function script:Read-Utf8Strict([string]$Path) {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $encoding = New-Object System.Text.UTF8Encoding($false, $true)
        return $encoding.GetString($bytes)
    }
}

Describe 'Source of lib\core\report.ps1' {
    It 'Exists and parses' {
        Test-Path -LiteralPath $script:ReportFile | Should -BeTrue
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:ReportFile, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }

    It 'Is plain ASCII' {
        Test-Path -LiteralPath $script:ReportFile | Should -BeTrue
        $bytes = [IO.File]::ReadAllBytes($script:ReportFile)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'Defines the four functions of the interface' {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ReportFile, [ref]$tokens, [ref]$errors)
        foreach ($name in @('ConvertTo-SweeprCheckHtml', 'Get-SweeprCheckReportDir', 'Open-SweeprCheckReport', 'Invoke-SweeprCheckReport')) {
            $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) |
                Should -Not -BeNullOrEmpty -Because "$name must be defined"
        }
    }

    It 'Uses no syntax that Windows PowerShell 5.1 does not know' {
        Test-Path -LiteralPath $script:ReportFile | Should -BeTrue
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ReportFile, [ref]$tokens, [ref]$errors)
        @($ast.FindAll({ param($n) $n.GetType().Name -match 'Ternary|NullConditional|PipelineChain|NullCoalescing' }, $true)).Count | Should -Be 0
    }

    It 'Takes nothing from the environment but the temp folder, and starts no network access' {
        $code = (Get-Content -LiteralPath $script:ReportFile -Raw) -replace '(?m)^\s*#.*$', ''
        $code | Should -Not -Match '(?i)COMPUTERNAME|USERNAME|USERDOMAIN|USERPROFILE|\bHOME\b|HOSTNAME|MachineName|UserName\b|Get-ComputerInfo|Get-CimInstance|Get-WmiObject|\[(System\.)?Net\.Dns\]|GetHostName'
        $code | Should -Not -Match '(?i)Invoke-WebRequest|Invoke-RestMethod|Net\.WebClient|HttpClient|Start-BitsTransfer|\biwr\b|\birm\b|Test-Connection|Resolve-DnsName'
        $code | Should -Not -Match '(?i)https?://'
    }

    It 'Writes no script into the document and evaluates nothing' {
        $code = (Get-Content -LiteralPath $script:ReportFile -Raw)
        $code | Should -Not -Match '(?i)<\s*script|javascript:|Invoke-Expression|\biex\b'
    }

    It 'Deletes and changes nothing but the one report file' {
        $code = (Get-Content -LiteralPath $script:ReportFile -Raw) -replace '(?m)^\s*#.*$', ''
        $code | Should -Not -Match '(?i)Remove-Item|Remove-Safe|Clear-DirectoryContents|Set-ItemProperty|New-ItemProperty|Remove-ItemProperty|\[Environment\]::SetEnvironmentVariable|Set-ExecutionPolicy|Stop-Process|Stop-Service|Restart-Service'
        $code | Should -Not -Match '(?i)\$env:\w+\s*='
    }

    It 'Starts a program only inside Open-SweeprCheckReport' {
        Test-Path -LiteralPath $script:ReportFile | Should -BeTrue
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ReportFile, [ref]$tokens, [ref]$errors)
        $starters = $ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Start-Process', 'start', 'saps', 'Invoke-Item', 'ii', 'explorer', 'explorer.exe', 'xdg-open', 'open', 'cmd', 'cmd.exe', 'powershell', 'powershell.exe', 'pwsh')
            }, $true)
        foreach ($call in $starters) {
            $owner = $call.Parent
            while ($owner -and $owner -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $owner = $owner.Parent }
            $owner | Should -Not -BeNullOrEmpty -Because 'a program is started outside any function'
            $owner.Name | Should -BeExactly 'Open-SweeprCheckReport'
        }
    }

    It 'Has no top-level code: loading the file prints nothing and writes nothing' {
        $before = @(Get-ChildItem -LiteralPath $TestDrive -Recurse -Force -ErrorAction SilentlyContinue).Count
        $output = & { . $script:ReportFile }
        @($output).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $TestDrive -Recurse -Force -ErrorAction SilentlyContinue).Count | Should -Be $before
    }
}

Describe 'ConvertTo-SweeprCheckHtml document' {
    BeforeEach {
        $script:Result = New-TestResult
        $script:Html = ConvertTo-SweeprCheckHtml -Result $script:Result
    }

    It 'Returns one string that is a complete HTML document' {
        @($script:Html).Count | Should -Be 1
        $script:Html | Should -BeOfType ([string])
        $script:Html | Should -Match '(?is)^\s*<!doctype html>'
        $script:Html | Should -Match '(?is)<html[\s>].*</html>\s*$'
        $script:Html | Should -Match '(?is)<title>[^<]*Sweepr[^<]*</title>'
        $script:Html | Should -Match '(?i)<meta\s+charset="utf-8"\s*/?>'
    }

    It 'Is a pure function of the result' {
        (ConvertTo-SweeprCheckHtml -Result $script:Result) | Should -BeExactly $script:Html
        (ConvertTo-SweeprCheckHtml -Result (New-TestResult)) | Should -BeExactly $script:Html
    }

    It 'Shows the version and the time of the result' {
        $script:Html | Should -Match ([regex]::Escape('9.8.7-test'))
        $script:Html | Should -Match ([regex]::Escape('2026-10-26T10:11:12+01:00'))
    }

    It 'Has the Content-Security-Policy meta element, before the style and the body' {
        $csp = [regex]::Match($script:Html, '(?i)<meta http-equiv="Content-Security-Policy" content="default-src ''none''; style-src ''unsafe-inline''"\s*/?>')
        $csp.Success | Should -BeTrue
        [regex]::Matches($script:Html, '(?i)Content-Security-Policy').Count | Should -Be 1
        $styleAt = $script:Html.IndexOf('<style', [StringComparison]::OrdinalIgnoreCase)
        $bodyAt = $script:Html.IndexOf('<body', [StringComparison]::OrdinalIgnoreCase)
        $bodyAt | Should -BeGreaterThan -1
        $csp.Index | Should -BeLessThan $bodyAt
        if ($styleAt -ge 0) { $csp.Index | Should -BeLessThan $styleAt }
    }

    It 'Has no script, no external resource and no element outside the allowed set' {
        $script:Html | Should -Not -Match '(?i)<\s*script'
        $script:Html | Should -Not -Match '(?i)javascript:|\bsrc\s*=|https?:|//[a-z0-9.-]+\.[a-z]{2,}|url\(|@import|<\s*link|<\s*iframe|<\s*form|<\s*img|<\s*object|<\s*embed|<\s*svg|<\s*base'
        $allowed = @('html', 'head', 'meta', 'title', 'style', 'body', 'header', 'main', 'section', 'footer', 'h1', 'h2', 'h3', 'p', 'ul', 'ol', 'li',
            'table', 'thead', 'tbody', 'tr', 'th', 'td', 'details', 'summary', 'div', 'span', 'code', 'strong', 'em', 'br', 'a')
        foreach ($tag in (Get-TagNames $script:Html | Select-Object -Unique)) {
            $allowed | Should -Contain $tag -Because "<$tag> is not an allowed element"
        }
    }

    It 'Has no event handler attribute and only anchors as links' {
        foreach ($tag in [regex]::Matches($script:Html, '<[A-Za-z][^>]*>')) {
            $tag.Value | Should -Not -Match '(?i)\son[a-z]+\s*=' -Because $tag.Value
            if ($tag.Value -match '(?i)\bhref\s*=') {
                $tag.Value | Should -Match '(?i)^<a\s' -Because $tag.Value
                $tag.Value | Should -Match '(?i)href\s*=\s*["'']#' -Because $tag.Value
            }
        }
    }

    It 'Opens and closes its sections and details elements evenly' {
        foreach ($name in @('section', 'details', 'table', 'ul')) {
            ([regex]::Matches($script:Html, "(?i)<$name[\s>]")).Count | Should -Be ([regex]::Matches($script:Html, "(?i)</$name>")).Count -Because $name
        }
    }

    It 'Has the four area sections with their headings, not nested' {
        $expected = [ordered]@{ clean = 'Cleanup potential'; apps = 'Apps and features'; system = 'System health'; projects = 'Project artifacts' }
        foreach ($id in $expected.Keys) {
            $body = Get-Section $script:Html $id
            $body | Should -Match ([regex]::Escape($expected[$id])) -Because $id
            $body | Should -Not -Match '(?i)<section' -Because "$id must not hold another section"
        }
    }
}

Describe 'ConvertTo-SweeprCheckHtml content' {
    BeforeEach {
        $script:Result = New-TestResult
        $script:Html = ConvertTo-SweeprCheckHtml -Result $script:Result
    }

    It 'Shows the total, the count and every group of the cleanup area' {
        $clean = Get-Section $script:Html 'clean'
        $clean | Should -Match ([regex]::Escape((Format-ByteSize (5 * $script:Gb))))
        $clean | Should -Match '\b1234\b'
        $clean | Should -Match 'User essentials'
        $clean | Should -Match 'Browser caches'
        $clean | Should -Match ([regex]::Escape((Format-ByteSize (4 * $script:Gb))))
        $clean | Should -Match '\b1134\b'
    }

    It 'Puts the 20 biggest cleanup paths into one details element, biggest first' {
        $clean = Get-Section $script:Html 'clean'
        ([regex]::Matches($clean, '(?i)<details[\s>]')).Count | Should -Be 1
        ([regex]::Matches($clean, '(?i)<summary[\s>]')).Count | Should -BeGreaterOrEqual 1
        $details = [regex]::Match($clean, '(?is)<details[\s>].*?</details>').Value
        $last = -1
        for ($n = 1; $n -le 20; $n++) {
            $path = '~\AppData\Local\Example\Item{0:00}' -f $n
            $at = $details.IndexOf($path)
            $at | Should -BeGreaterThan -1 -Because "$path must be inside the details element"
            $at | Should -BeGreaterThan $last -Because 'the order of the result is kept'
            $last = $at
        }
        $details | Should -Match ([regex]::Escape((Format-ByteSize 20MB)))
    }

    It 'Shows at most 20 paths per list even when given more' {
        $script:Result.Sections.Clean.Top = @(New-TopPaths 25 'AppData\Local\Example')
        $script:Result.Sections.Projects.Top = @(1..25 | ForEach-Object { [pscustomobject][ordered]@{ Path = ('~\Source\Proj{0:00}' -f $_); Name = "Proj$_"; TotalBytes = [long](26 - $_) * 1048576; SizeComplete = $true } })
        $script:Result.Sections.Projects.Count = 25
        $html = ConvertTo-SweeprCheckHtml -Result $script:Result
        $html | Should -Match ([regex]::Escape('AppData\Local\Example\Item20'))
        $html | Should -Not -Match ([regex]::Escape('AppData\Local\Example\Item21'))
        $html | Should -Match ([regex]::Escape('Source\Proj20'))
        $html | Should -Not -Match ([regex]::Escape('Source\Proj21'))
    }

    It 'Has no details element when a list is empty' {
        $script:Result.Sections.Clean.Top = @()
        $script:Result.Sections.Projects.Top = @()
        $script:Result.Sections.Projects.Count = 0
        $html = ConvertTo-SweeprCheckHtml -Result $script:Result
        (Get-Section $html 'clean') | Should -Not -Match '(?i)<details'
        (Get-Section $html 'projects') | Should -Not -Match '(?i)<details'
    }

    It 'Shows the apps: count and titles' {
        $apps = Get-Section $script:Html 'apps'
        $apps | Should -Match '\b2\b'
        $apps | Should -Match 'Contoso Sample App'
        $apps | Should -Match 'Fabrikam Demo Feature'
    }

    It 'Shows the system health values' {
        $system = Get-Section $script:Html 'system'
        $system | Should -Match 'C:'
        $system | Should -Match ([regex]::Escape((Format-ByteSize (125 * $script:Gb))))
        $system | Should -Match ([regex]::Escape((Format-ByteSize (500 * $script:Gb))))
        $system | Should -Match '62\.5'
        $system | Should -Match '5\.2'
        $system | Should -Match 'KB5000001'
        $system | Should -Match 'ExampleSync'
        $system | Should -Match 'SampleUpdater'
        $system | Should -Match 'HKCU Run'
        $system | Should -Not -Match 'not measured'
    }

    It 'Says "not measured" for each health part that has Measured = $false' {
        foreach ($part in @('Disks', 'Memory', 'Uptime', 'Updates', 'PendingUpdates', 'Startup')) {
            $result = New-TestResult
            $result.Sections.System.$part = [pscustomobject][ordered]@{ Measured = $false }
            $html = ConvertTo-SweeprCheckHtml -Result $result
            (Get-Section $html 'system') | Should -Match '(?i)not measured' -Because $part
        }
        $result = New-TestResult
        foreach ($part in @('Disks', 'Memory', 'Uptime', 'Updates', 'PendingUpdates', 'Startup')) { $result.Sections.System.$part = [pscustomobject][ordered]@{ Measured = $false } }
        { ConvertTo-SweeprCheckHtml -Result $result } | Should -Not -Throw
    }

    It 'Shows the projects: total, count, top paths in one details element' {
        $projects = Get-Section $script:Html 'projects'
        $projects | Should -Match ([regex]::Escape((Format-ByteSize (2 * $script:Gb))))
        $projects | Should -Match '\b2\b'
        ([regex]::Matches($projects, '(?i)<details[\s>]')).Count | Should -Be 1
        $details = [regex]::Match($projects, '(?is)<details[\s>].*?</details>').Value
        $details | Should -Match ([regex]::Escape('~\Documents\ExampleApp'))
        $details | Should -Match ([regex]::Escape('~\Source\SampleTool'))
        $projects | Should -Not -Match '(?i)incomplete'
    }

    It 'Says "incomplete" when the project search was not complete' {
        $script:Result.Sections.Projects.Complete = $false
        $script:Result.Sections.Projects.TimedOut = $true
        $html = ConvertTo-SweeprCheckHtml -Result $script:Result
        (Get-Section $html 'projects') | Should -Match '(?i)incomplete'
    }

    It 'Lists what was not measured, with name and reason' {
        $list = Get-Section $script:Html 'not-measured'
        $list | Should -Match 'npm'
        $list | Should -Match 'external tool'
        $list | Should -Match 'PendingUpdates'
        $list | Should -Match 'not available'
    }

    It 'Has no not-measured section when nothing is missing' {
        $script:Result.NotMeasured = @()
        $html = ConvertTo-SweeprCheckHtml -Result $script:Result
        $html | Should -Not -Match 'id="not-measured"'
    }

    It 'Shows the administrator hint only without administrator rights' {
        $script:Result.IsAdmin = $false
        $without = ConvertTo-SweeprCheckHtml -Result $script:Result
        $without | Should -Match 'id="admin-hint"'
        $hint = [regex]::Match($without, '(?is)id="admin-hint"[^>]*>(.*?)</').Groups[1].Value
        $hint | Should -Match '(?i)administrator'
        $script:Html | Should -Not -Match 'id="admin-hint"'
    }

    It 'Marks a failed <Area> area as error, shows nothing else of it and keeps the others' -ForEach @(
        @{ Area = 'Clean'; Id = 'clean'; Other = 'apps'; OtherText = 'Contoso Sample App' }
        @{ Area = 'Apps'; Id = 'apps'; Other = 'clean'; OtherText = 'User essentials' }
        @{ Area = 'System'; Id = 'system'; Other = 'projects'; OtherText = 'SampleTool' }
        @{ Area = 'Projects'; Id = 'projects'; Other = 'system'; OtherText = 'ExampleSync' }
    ) {
        $trap = [pscustomobject][ordered]@{ Status = 'error'; Reason = 'error'; Message = 'SECRET-ERROR-TEXT C:\Users\AliceTrap\x'; Exception = 'System.IO.IOException at CONTOSO-PC-TRAP' }
        $script:Result.Sections.$Area = $trap
        $html = ConvertTo-SweeprCheckHtml -Result $script:Result
        $section = Get-Section $html $Id
        $section | Should -Match '(?i)\berror\b'
        $section | Should -Not -Match '(?i)<details'
        $section | Should -Not -Match 'SECRET-ERROR-TEXT|AliceTrap|CONTOSO-PC-TRAP'
        $html | Should -Not -Match 'SECRET-ERROR-TEXT|AliceTrap|CONTOSO-PC-TRAP'
        (Get-Section $html $Other) | Should -Match ([regex]::Escape($OtherText))
    }

    It 'Still makes a report when every area failed' {
        foreach ($area in @('Clean', 'Apps', 'System', 'Projects')) {
            $script:Result.Sections.$area = [pscustomobject][ordered]@{ Status = 'error'; Reason = 'error' }
        }
        $script:Result.NotMeasured = @()
        $html = ConvertTo-SweeprCheckHtml -Result $script:Result
        foreach ($id in @('clean', 'apps', 'system', 'projects')) { (Get-Section $html $id) | Should -Match '(?i)\berror\b' }
        $html | Should -Not -Match '(?i)<details'
    }

    It 'Copies no property that is not on the list of the result' {
        $script:Result | Add-Member -NotePropertyName ComputerName -NotePropertyValue 'CONTOSO-PC-77'
        $script:Result | Add-Member -NotePropertyName UserName -NotePropertyValue 'alice77'
        $script:Result.Sections.Clean | Add-Member -NotePropertyName Extra -NotePropertyValue 'EXTRA-SECTION-VALUE'
        $script:Result.Sections.Clean.Top[0] | Add-Member -NotePropertyName Description -NotePropertyValue 'EXTRA-HIT-DESCRIPTION'
        $script:Result.Sections.Apps.Items[0] | Add-Member -NotePropertyName Command -NotePropertyValue 'EXTRA-APP-COMMAND'
        $script:Result.Sections.System.Startup.Entries[0] | Add-Member -NotePropertyName Command -NotePropertyValue 'C:\EXTRA-STARTUP-COMMAND.exe --token'
        $script:Result.Sections.System.Disks.Drives[0] | Add-Member -NotePropertyName Label -NotePropertyValue 'EXTRA-DRIVE-LABEL'
        $script:Result.NotMeasured[0] | Add-Member -NotePropertyName Detail -NotePropertyValue 'EXTRA-DETAIL'
        $html = ConvertTo-SweeprCheckHtml -Result $script:Result
        $html | Should -Not -Match 'CONTOSO-PC-77|alice77|EXTRA-'
    }

    It 'Takes no user, computer or domain name from the environment' {
        $names = 'COMPUTERNAME', 'USERNAME', 'USERDOMAIN', 'USERPROFILE', 'HOSTNAME', 'LOGNAME', 'USER'
        $saved = @{}
        foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
        try {
            foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, "envmarker-$($name.ToLowerInvariant())-zq") }
            $html = ConvertTo-SweeprCheckHtml -Result (New-TestResult)
            $html | Should -Not -Match 'envmarker'
            $html | Should -BeExactly $script:Html
        }
        finally { foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) } }
    }
}

Describe 'ConvertTo-SweeprCheckHtml escaping' {
    BeforeEach {
        $r = New-TestResult
        $script:Fields = [ordered]@{}
        $mark = {
            param([string]$Key)
            $value = Evil $Key
            $script:Fields[$Key] = $value
            return $value
        }
        $r.Version = & $mark 'version'
        $r.GeneratedAt = & $mark 'generated'
        $r.Sections.Clean.Groups[0].Name = & $mark 'group'
        $r.Sections.Clean.Top[0].Section = Evil 'topsection'
        $r.Sections.Clean.Top[0].Path = & $mark 'toppath'
        $r.Sections.Apps.Items[0].Id = Evil 'appid'
        $r.Sections.Apps.Items[0].Kind = Evil 'appkind'
        $r.Sections.Apps.Items[0].Title = & $mark 'apptitle'
        $r.Sections.System.Disks.Drives[0].Drive = & $mark 'drive'
        $r.Sections.System.Disks.Drives[0].Health = Evil 'health'
        $r.Sections.System.Updates.Recent[0].Id = Evil 'updateid'
        $r.Sections.System.Startup.Entries[0].Name = & $mark 'startupname'
        $r.Sections.System.Startup.Entries[0].Source = Evil 'startupsource'
        $r.Sections.Projects.Top[0].Path = & $mark 'projectpath'
        $r.Sections.Projects.Top[0].Name = Evil 'projectname'
        $r.NotMeasured[0].Section = Evil 'nmsection'
        $r.NotMeasured[0].Name = & $mark 'nmname'
        $r.NotMeasured[0].Reason = & $mark 'nmreason'
        $script:Html = ConvertTo-SweeprCheckHtml -Result $r
    }

    It 'Writes every shown value HTML-encoded' {
        foreach ($key in $script:Fields.Keys) {
            $script:Html.Contains((Enc $script:Fields[$key])) | Should -BeTrue -Because "the value '$key' must appear as HtmlEncode(value)"
        }
    }

    It 'Leaves no raw markup, quote or script from any value in the document' {
        $script:Html | Should -Not -Match '(?i)<\s*script'
        $script:Html | Should -Not -Match '(?i)<\s*img'
        $script:Html | Should -Not -Match '(?i)alert\([^)]*\)\s*<'
        foreach ($key in $script:Fields.Keys) {
            $script:Html.Contains($script:Fields[$key]) | Should -BeFalse -Because "the raw value '$key' must not appear"
        }
        $allowed = @('html', 'head', 'meta', 'title', 'style', 'body', 'header', 'main', 'section', 'footer', 'h1', 'h2', 'h3', 'p', 'ul', 'ol', 'li',
            'table', 'thead', 'tbody', 'tr', 'th', 'td', 'details', 'summary', 'div', 'span', 'code', 'strong', 'em', 'br', 'a')
        foreach ($tag in (Get-TagNames $script:Html | Select-Object -Unique)) { $allowed | Should -Contain $tag }
        foreach ($tag in [regex]::Matches($script:Html, '<[A-Za-z][^>]*>')) { $tag.Value | Should -Not -Match '(?i)\son[a-z]+\s*=' -Because $tag.Value }
    }

    It 'Encodes a double quote, a single quote and an ampersand on their own' {
        $r = New-TestResult
        $r.Sections.Clean.Top[0].Path = '~\a"b''c&d<e>f'
        $html = ConvertTo-SweeprCheckHtml -Result $r
        $html.Contains((Enc '~\a"b''c&d<e>f')) | Should -BeTrue
        $html.Contains('a"b''c') | Should -BeFalse
        $html.Contains('c&d<e') | Should -BeFalse
    }
}

Describe 'Get-SweeprCheckReportDir' {
    It 'Is the temp folder of the environment' {
        $saved = $env:TEMP
        try {
            $env:TEMP = Join-Path $TestDrive 'mytemp'
            Get-SweeprCheckReportDir | Should -BeExactly (Join-Path $TestDrive 'mytemp')
        }
        finally { $env:TEMP = $saved }
    }
}

Describe 'Open-SweeprCheckReport' {
    It 'Exists with a Path parameter' {
        $command = Get-Command -Name 'Open-SweeprCheckReport' -ErrorAction SilentlyContinue
        $command | Should -Not -BeNullOrEmpty
        $command.Parameters.Keys | Should -Contain 'Path'
    }
}

Describe 'Invoke-SweeprCheckReport' {
    BeforeEach {
        $script:ReportDir = Join-Path $TestDrive ('reports' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($script:ReportDir)
        Mock Get-SweeprCheckReportDir { return $script:ReportDir }
        Mock Open-SweeprCheckReport { }
        # Nothing but the one file: network, deleting and starting programs would throw.
        Mock Invoke-WebRequest { throw 'network access' }
        Mock Invoke-RestMethod { throw 'network access' }
        Mock Start-Process { throw 'Start-Process' }
        Mock Invoke-Item { throw 'Invoke-Item' }
        Mock Remove-Item { throw 'Remove-Item' }
        Mock Stop-Process { throw 'Stop-Process' }
    }

    It 'Writes sweepr-check-DATE.html into the folder and returns exactly that path as one string' {
        $out = @(Invoke-SweeprCheckReport -Result (New-TestResult) -NoOpen)
        $out.Count | Should -Be 1
        $out[0] | Should -BeOfType ([string])
        $out[0] | Should -BeExactly (Join-Path $script:ReportDir ([IO.Path]::GetFileName($out[0])))
        [IO.Path]::GetFileName($out[0]) | Should -Match '^sweepr-check-\d{4}-\d{2}-\d{2}-\d{6}\.html$'
        Test-Path -LiteralPath $out[0] -PathType Leaf | Should -BeTrue
        @(Get-ChildItem -LiteralPath $script:ReportDir -Force).Count | Should -Be 1
    }

    It 'Names the file after the local time of now' {
        $out = Invoke-SweeprCheckReport -Result (New-TestResult) -NoOpen
        $stamp = [IO.Path]::GetFileNameWithoutExtension($out).Substring('sweepr-check-'.Length)
        $time = [datetime]::ParseExact($stamp, 'yyyy-MM-dd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
        [Math]::Abs(((Get-Date) - $time).TotalMinutes) | Should -BeLessThan 5
    }

    It 'Writes the text of ConvertTo-SweeprCheckHtml as strict UTF-8' {
        $result = New-TestResult
        $result.Sections.Clean.Top[0].Path = '~\Docs\Gr' + [char]0x00F6 + [char]0x00DF + 'e ' + [char]0x20AC + ' ' + [char]0x4E2D + [char]0x6587
        $out = Invoke-SweeprCheckReport -Result $result -NoOpen
        $bytes = [IO.File]::ReadAllBytes($out)
        ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) | Should -BeFalse -Because 'not UTF-16'
        $text = Read-Utf8Strict $out
        [System.Net.WebUtility]::HtmlDecode($text) | Should -Match ([regex]::Escape('Gr' + [char]0x00F6 + [char]0x00DF + 'e ' + [char]0x20AC + ' ' + [char]0x4E2D + [char]0x6587))
        $expected = ConvertTo-SweeprCheckHtml -Result $result
        $text.TrimStart([char]0xFEFF) | Should -BeExactly $expected
    }

    It 'Opens the report once with its path' {
        $out = Invoke-SweeprCheckReport -Result (New-TestResult)
        Should -Invoke Open-SweeprCheckReport -Times 1 -Exactly -ParameterFilter { $Path -eq $out }
    }

    It 'Does not open the report with -NoOpen, and still returns the path' {
        $out = Invoke-SweeprCheckReport -Result (New-TestResult) -NoOpen
        Should -Invoke Open-SweeprCheckReport -Times 0 -Exactly
        Test-Path -LiteralPath $out | Should -BeTrue
    }

    It 'Counts the report as made when only the opening fails' {
        Mock Open-SweeprCheckReport { throw 'no browser' }
        $out = @(Invoke-SweeprCheckReport -Result (New-TestResult))
        $out.Count | Should -Be 1
        Test-Path -LiteralPath $out[0] | Should -BeTrue
    }

    It 'Changes nothing but the report file' {
        $before = @(Get-ChildItem -LiteralPath $TestDrive -Recurse -Force | ForEach-Object { $_.FullName })
        $savedDry = Test-DryRunMode
        $savedOplog = $env:SWEEPR_NO_OPLOG
        $out = Invoke-SweeprCheckReport -Result (New-TestResult)
        $after = @(Get-ChildItem -LiteralPath $TestDrive -Recurse -Force | ForEach-Object { $_.FullName })
        @($after | Where-Object { $before -notcontains $_ }) | Should -Be @($out)
        @($before | Where-Object { $after -notcontains $_ }).Count | Should -Be 0
        Test-DryRunMode | Should -Be $savedDry
        $env:SWEEPR_NO_OPLOG | Should -Be $savedOplog
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke Remove-Item -Times 0 -Exactly
    }

    It 'Leaves neither the folder path nor the environment names in the document' {
        $names = 'COMPUTERNAME', 'USERNAME', 'USERDOMAIN'
        $saved = @{}
        foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
        try {
            foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, "envmarker-$($name.ToLowerInvariant())-zq") }
            $out = Invoke-SweeprCheckReport -Result (New-TestResult) -NoOpen
            $text = Read-Utf8Strict $out
            $text | Should -Not -Match 'envmarker'
            $text.Contains($script:ReportDir) | Should -BeFalse
            $text.Contains([IO.Path]::GetFileName($out)) | Should -BeFalse
        }
        finally { foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) } }
    }

    It 'Throws when the folder is not a folder, and opens nothing' {
        $notAFolder = Join-Path $TestDrive 'a-file'
        [IO.File]::WriteAllText($notAFolder, 'x')
        $script:ReportDir = $notAFolder
        { Invoke-SweeprCheckReport -Result (New-TestResult) } | Should -Throw
        Should -Invoke Open-SweeprCheckReport -Times 0 -Exactly
    }

    It 'Throws when the folder does not exist, and does not create it' {
        $script:ReportDir = Join-Path $TestDrive 'missing\deeper'
        { Invoke-SweeprCheckReport -Result (New-TestResult) -NoOpen } | Should -Throw
        Test-Path -LiteralPath (Join-Path $TestDrive 'missing') | Should -BeFalse
        Should -Invoke Open-SweeprCheckReport -Times 0 -Exactly
    }

    It 'Refuses a missing result and writes nothing' {
        { Invoke-SweeprCheckReport -Result $null -NoOpen } | Should -Throw
        @(Get-ChildItem -LiteralPath $script:ReportDir -Force).Count | Should -Be 0
        Should -Invoke Open-SweeprCheckReport -Times 0 -Exactly
    }

    It 'Makes a report for a result whose areas all failed' {
        $result = New-TestResult
        foreach ($area in @('Clean', 'Apps', 'System', 'Projects')) { $result.Sections.$area = [pscustomobject][ordered]@{ Status = 'error'; Reason = 'error' } }
        $out = Invoke-SweeprCheckReport -Result $result -NoOpen
        (Read-Utf8Strict $out) | Should -Match 'Content-Security-Policy'
    }
}

Describe 'Invoke-SweeprCheckReport with the default folder' {
    BeforeEach {
        Mock Open-SweeprCheckReport { }
    }

    It 'Writes into $env:TEMP' {
        $saved = $env:TEMP
        try {
            $env:TEMP = Join-Path $TestDrive 'envtemp'
            [void][IO.Directory]::CreateDirectory($env:TEMP)
            $out = Invoke-SweeprCheckReport -Result (New-TestResult) -NoOpen
            [IO.Path]::GetDirectoryName($out) | Should -BeExactly $env:TEMP
            Test-Path -LiteralPath $out | Should -BeTrue
        }
        finally { $env:TEMP = $saved }
    }
}

Describe 'sw check --report wiring' {
    It 'Loads report.ps1 in bin\check.ps1 after the user interface module' {
        $text = Get-Content -LiteralPath $script:BinFile -Raw
        $code = $text -replace '(?m)^\s*#.*$', ''
        $code | Should -Match 'core\\+report\.ps1'
        $code.IndexOf('core\ui.ps1') | Should -BeLessThan ($code.IndexOf('report.ps1'))
        $code | Should -Not -Match 'update_check'
    }

    It 'Lists the report module and this test file for the installer' {
        $text = Get-Content -LiteralPath $script:InstallFile -Raw
        $text.Contains('"lib\core\report.ps1"') | Should -BeTrue -Because 'lib\core\report.ps1 belongs in Get-SweeprInstallNestedFiles'
        $text.Contains('"tests\CheckReport.Tests.ps1"') | Should -BeTrue -Because 'tests\CheckReport.Tests.ps1 belongs in Get-SweeprInstallNestedFiles'
    }

    It 'Runs sw check --report --no-open in a child process and leaves one safe report in the temp folder' {
        $profileDir = Join-Path $TestDrive 'reportchild'
        $project = Join-Path $profileDir 'Documents/proj'
        [void][IO.Directory]::CreateDirectory((Join-Path $project 'node_modules'))
        [IO.File]::WriteAllBytes((Join-Path $project 'package.json'), (New-Object byte[] 10))
        [IO.File]::WriteAllBytes((Join-Path $project 'node_modules/a.js'), (New-Object byte[] 100))
        foreach ($folder in @('data', 'tmp', 'local', 'roaming', 'programdata')) { [void][IO.Directory]::CreateDirectory((Join-Path $profileDir $folder)) }
        $tmp = Join-Path $profileDir 'tmp'

        $command = '$ProgressPreference = ''SilentlyContinue''; & ''' + $script:SweeprFile.Replace("'", "''") + ''' check --report --no-open; exit $LASTEXITCODE'
        $start = New-Object System.Diagnostics.ProcessStartInfo
        $start.FileName = (Get-Process -Id $PID).Path
        $start.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.EnvironmentVariables['USERPROFILE'] = $profileDir
        $start.EnvironmentVariables['HOME'] = $profileDir
        $start.EnvironmentVariables['TEMP'] = $tmp
        $start.EnvironmentVariables['TMP'] = $tmp
        $start.EnvironmentVariables['TMPDIR'] = $tmp
        $start.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $profileDir 'local'
        $start.EnvironmentVariables['APPDATA'] = Join-Path $profileDir 'roaming'
        $start.EnvironmentVariables['ProgramData'] = Join-Path $profileDir 'programdata'
        $start.EnvironmentVariables['SWEEPR_DATA_DIR'] = Join-Path $profileDir 'data'
        $start.EnvironmentVariables['SWEEPR_NO_OPLOG'] = '1'
        $process = [System.Diagnostics.Process]::Start($start)
        try {
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(280000)) { $process.Kill(); throw 'sw check --report timed out' }
            [void]$stdout.Wait(5000); [void]$stderr.Wait(5000)
            $out = $stdout.Result
            $err = $stderr.Result
            $exitCode = $process.ExitCode
        }
        finally { $process.Dispose() }

        ($out + $err) | Should -Not -Match 'report is not available'
        ($out + $err) | Should -Not -Match 'could not be created'
        $exitCode | Should -Be 0
        $files = @(Get-ChildItem -LiteralPath $tmp -Filter 'sweepr-check-*.html' -File)
        $files.Count | Should -Be 1
        $files[0].Name | Should -Match '^sweepr-check-\d{4}-\d{2}-\d{2}-\d{6}\.html$'
        $out | Should -Match ('Report: ' + [regex]::Escape($files[0].FullName))
        $html = Read-Utf8Strict $files[0].FullName
        $html | Should -Match 'default-src ''none''; style-src ''unsafe-inline'''
        $html | Should -Not -Match '(?i)<\s*script'
        foreach ($id in @('clean', 'apps', 'system', 'projects')) { $html | Should -Match "id=`"$id`"" }
        $html | Should -Not -Match 'reportchild'
        $html.Contains($profileDir) | Should -BeFalse
    }
}
