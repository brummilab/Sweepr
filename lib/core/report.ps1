# Sweepr - HTML report of `sw check --report`
# Turns the result object of `sw check` into one self-contained HTML document and writes it to the
# temp folder. The document has no script and no external resource: a strict Content-Security-Policy
# meta element forbids everything but inline style, and every value is HTML-encoded. Only properties
# of the result are shown, never anything taken from the environment.
# This file defines functions only; loading it does nothing.

# Largest number of paths shown per list. The result is a first look, not an inventory.
$script:SweeprReportMaxPaths = 20

# Reads a property that may be missing. The result comes from a fixed allowlist, but a failed area
# carries fewer properties, and strict mode would throw on a missing one.
function Get-SweeprReportValue {
    param($Object, [string]$Name)

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

# Value as invariant text: numbers without a locale, dates in one fixed shape.
function ConvertTo-SweeprReportPlain {
    param($Value)

    if ($null -eq $Value) { return '' }
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd HH:mm', $invariant) }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) { return $Value.ToString('0.##', $invariant) }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte] -or $Value -is [uint32] -or $Value -is [uint64]) {
        return $Value.ToString($invariant)
    }
    return [string]$Value
}

# The one way a value enters the document.
function ConvertTo-SweeprReportText {
    param($Value)

    return [System.Net.WebUtility]::HtmlEncode((ConvertTo-SweeprReportPlain -Value $Value))
}

function ConvertTo-SweeprReportSize {
    param($Value)

    if ($null -eq $Value) { return '' }
    try { return [System.Net.WebUtility]::HtmlEncode((Format-ByteSize ([long]$Value))) }
    catch { return '' }
}

function Get-SweeprReportList {
    param($Value, [int]$Max = 0)

    $items = @($Value | Where-Object { $null -ne $_ })
    if ($Max -gt 0 -and $items.Count -gt $Max) { $items = @($items | Select-Object -First $Max) }
    return $items
}

function Test-SweeprReportError {
    param($Section)

    if ($null -eq $Section) { return $true }
    return ([string](Get-SweeprReportValue $Section 'Status') -eq 'error')
}

function Get-SweeprReportErrorBody {
    # Deliberately no message and no exception text: they can hold paths and names.
    return '<p class="bad"><strong>error</strong> - this area could not be read.</p>'
}

function Get-SweeprReportTable {
    param([string[]]$Headers, $Rows)

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('<table>')
    $head = ($Headers | ForEach-Object { '<th>' + $_ + '</th>' }) -join ''
    [void]$lines.Add('<thead><tr>' + $head + '</tr></thead>')
    [void]$lines.Add('<tbody>')
    foreach ($row in @($Rows)) { [void]$lines.Add($row) }
    [void]$lines.Add('</tbody>')
    [void]$lines.Add('</table>')
    return ($lines -join "`n")
}

function Get-SweeprReportCleanBody {
    param($Section)

    if (Test-SweeprReportError $Section) { return (Get-SweeprReportErrorBody) }
    $lines = New-Object System.Collections.ArrayList
    $total = ConvertTo-SweeprReportSize (Get-SweeprReportValue $Section 'TotalBytes')
    $count = ConvertTo-SweeprReportText (Get-SweeprReportValue $Section 'Count')
    [void]$lines.Add("<p><strong>$total</strong> can be freed, $count items.</p>")

    $groups = @(Get-SweeprReportList (Get-SweeprReportValue $Section 'Groups'))
    if ($groups.Count -gt 0) {
        $rows = foreach ($g in $groups) {
            '<tr><td>' + (ConvertTo-SweeprReportText (Get-SweeprReportValue $g 'Name')) + '</td><td>' +
            (ConvertTo-SweeprReportSize (Get-SweeprReportValue $g 'TotalBytes')) + '</td><td>' +
            (ConvertTo-SweeprReportText (Get-SweeprReportValue $g 'Count')) + '</td></tr>'
        }
        [void]$lines.Add((Get-SweeprReportTable -Headers @('Group', 'Size', 'Items') -Rows $rows))
    }

    $top = @(Get-SweeprReportList (Get-SweeprReportValue $Section 'Top') $script:SweeprReportMaxPaths)
    if ($top.Count -gt 0) {
        $rows = foreach ($t in $top) {
            '<tr><td><code>' + (ConvertTo-SweeprReportText (Get-SweeprReportValue $t 'Path')) + '</code></td><td>' +
            (ConvertTo-SweeprReportText (Get-SweeprReportValue $t 'Section')) + '</td><td>' +
            (ConvertTo-SweeprReportSize (Get-SweeprReportValue $t 'SizeBytes')) + '</td></tr>'
        }
        [void]$lines.Add('<details>')
        [void]$lines.Add('<summary>Biggest paths (' + $top.Count + ')</summary>')
        [void]$lines.Add((Get-SweeprReportTable -Headers @('Path', 'Group', 'Size') -Rows $rows))
        [void]$lines.Add('</details>')
    }
    return ($lines -join "`n")
}

function Get-SweeprReportAppsBody {
    param($Section)

    if (Test-SweeprReportError $Section) { return (Get-SweeprReportErrorBody) }
    $lines = New-Object System.Collections.ArrayList
    $count = ConvertTo-SweeprReportText (Get-SweeprReportValue $Section 'Count')
    [void]$lines.Add("<p><strong>$count</strong> apps and features can be removed.</p>")
    $items = @(Get-SweeprReportList (Get-SweeprReportValue $Section 'Items'))
    if ($items.Count -gt 0) {
        [void]$lines.Add('<ul>')
        foreach ($item in $items) {
            [void]$lines.Add('<li>' + (ConvertTo-SweeprReportText (Get-SweeprReportValue $item 'Title')) + '</li>')
        }
        [void]$lines.Add('</ul>')
    }
    return ($lines -join "`n")
}

function Test-SweeprReportMeasured {
    param($Part)

    if ($null -eq $Part) { return $false }
    return ((Get-SweeprReportValue $Part 'Measured') -eq $true)
}

function Get-SweeprReportSystemBody {
    param($Section)

    if (Test-SweeprReportError $Section) { return (Get-SweeprReportErrorBody) }
    $lines = New-Object System.Collections.ArrayList
    $missing = '<p class="muted">not measured</p>'

    [void]$lines.Add('<h3>Drives</h3>')
    $disks = Get-SweeprReportValue $Section 'Disks'
    if (Test-SweeprReportMeasured $disks) {
        $drives = @(Get-SweeprReportList (Get-SweeprReportValue $disks 'Drives'))
        $rows = foreach ($d in $drives) {
            '<tr><td>' + (ConvertTo-SweeprReportText (Get-SweeprReportValue $d 'Drive')) + '</td><td>' +
            (ConvertTo-SweeprReportSize (Get-SweeprReportValue $d 'FreeBytes')) + '</td><td>' +
            (ConvertTo-SweeprReportSize (Get-SweeprReportValue $d 'SizeBytes')) + '</td><td>' +
            (ConvertTo-SweeprReportText (Get-SweeprReportValue $d 'Health')) + '</td></tr>'
        }
        [void]$lines.Add((Get-SweeprReportTable -Headers @('Drive', 'Free', 'Size', 'Health') -Rows $rows))
    }
    else { [void]$lines.Add($missing) }

    [void]$lines.Add('<h3>Memory</h3>')
    $memory = Get-SweeprReportValue $Section 'Memory'
    if (Test-SweeprReportMeasured $memory) {
        $used = ConvertTo-SweeprReportText (Get-SweeprReportValue $memory 'UsedPercent')
        $usedSize = ConvertTo-SweeprReportSize (Get-SweeprReportValue $memory 'UsedBytes')
        $totalSize = ConvertTo-SweeprReportSize (Get-SweeprReportValue $memory 'TotalBytes')
        [void]$lines.Add("<p><strong>$used %</strong> in use ($usedSize of $totalSize).</p>")
    }
    else { [void]$lines.Add($missing) }

    [void]$lines.Add('<h3>Uptime</h3>')
    $uptime = Get-SweeprReportValue $Section 'Uptime'
    if (Test-SweeprReportMeasured $uptime) {
        $days = ConvertTo-SweeprReportText (Get-SweeprReportValue $uptime 'UptimeDays')
        [void]$lines.Add("<p><strong>$days</strong> days since the last start.</p>")
    }
    else { [void]$lines.Add($missing) }

    [void]$lines.Add('<h3>Windows updates</h3>')
    $updates = Get-SweeprReportValue $Section 'Updates'
    if (Test-SweeprReportMeasured $updates) {
        $last = ConvertTo-SweeprReportText (Get-SweeprReportValue $updates 'LastInstalledOn')
        [void]$lines.Add("<p>Last update installed: <strong>$last</strong></p>")
        $recent = @(Get-SweeprReportList (Get-SweeprReportValue $updates 'Recent'))
        if ($recent.Count -gt 0) {
            [void]$lines.Add('<ul>')
            foreach ($u in $recent) {
                [void]$lines.Add('<li><code>' + (ConvertTo-SweeprReportText (Get-SweeprReportValue $u 'Id')) + '</code> ' +
                    (ConvertTo-SweeprReportText (Get-SweeprReportValue $u 'InstalledOn')) + '</li>')
            }
            [void]$lines.Add('</ul>')
        }
    }
    else { [void]$lines.Add($missing) }

    [void]$lines.Add('<h3>Pending updates</h3>')
    $pending = Get-SweeprReportValue $Section 'PendingUpdates'
    if (Test-SweeprReportMeasured $pending) {
        $total = ConvertTo-SweeprReportText (Get-SweeprReportValue $pending 'Total')
        $important = ConvertTo-SweeprReportText (Get-SweeprReportValue $pending 'Important')
        [void]$lines.Add("<p><strong>$total</strong> pending, $important important.</p>")
    }
    else { [void]$lines.Add($missing) }

    [void]$lines.Add('<h3>Startup entries</h3>')
    $startup = Get-SweeprReportValue $Section 'Startup'
    if (Test-SweeprReportMeasured $startup) {
        $count = ConvertTo-SweeprReportText (Get-SweeprReportValue $startup 'Count')
        [void]$lines.Add("<p><strong>$count</strong> programs start with Windows.</p>")
        $entries = @(Get-SweeprReportList (Get-SweeprReportValue $startup 'Entries'))
        if ($entries.Count -gt 0) {
            $rows = foreach ($e in $entries) {
                '<tr><td>' + (ConvertTo-SweeprReportText (Get-SweeprReportValue $e 'Name')) + '</td><td>' +
                (ConvertTo-SweeprReportText (Get-SweeprReportValue $e 'Source')) + '</td></tr>'
            }
            [void]$lines.Add((Get-SweeprReportTable -Headers @('Name', 'Source') -Rows $rows))
        }
    }
    else { [void]$lines.Add($missing) }

    return ($lines -join "`n")
}

function Get-SweeprReportProjectsBody {
    param($Section)

    if (Test-SweeprReportError $Section) { return (Get-SweeprReportErrorBody) }
    $lines = New-Object System.Collections.ArrayList
    $total = ConvertTo-SweeprReportSize (Get-SweeprReportValue $Section 'TotalBytes')
    $count = ConvertTo-SweeprReportText (Get-SweeprReportValue $Section 'Count')
    [void]$lines.Add("<p><strong>$total</strong> in build artifacts of $count projects.</p>")
    if ((Get-SweeprReportValue $Section 'Complete') -eq $false) {
        [void]$lines.Add('<p class="bad"><strong>incomplete</strong> - the search did not finish, there may be more.</p>')
    }
    $top = @(Get-SweeprReportList (Get-SweeprReportValue $Section 'Top') $script:SweeprReportMaxPaths)
    if ($top.Count -gt 0) {
        $rows = foreach ($p in $top) {
            '<tr><td><code>' + (ConvertTo-SweeprReportText (Get-SweeprReportValue $p 'Path')) + '</code></td><td>' +
            (ConvertTo-SweeprReportText (Get-SweeprReportValue $p 'Name')) + '</td><td>' +
            (ConvertTo-SweeprReportSize (Get-SweeprReportValue $p 'TotalBytes')) + '</td></tr>'
        }
        [void]$lines.Add('<details>')
        [void]$lines.Add('<summary>Biggest projects (' + $top.Count + ')</summary>')
        [void]$lines.Add((Get-SweeprReportTable -Headers @('Path', 'Project', 'Size') -Rows $rows))
        [void]$lines.Add('</details>')
    }
    return ($lines -join "`n")
}

function Get-SweeprReportStyle {
    $css = @(
        ':root { color-scheme: light dark; --bg: #f6f7f9; --fg: #1d2330; --card: #ffffff; --line: #d9dde5; --muted: #5d6677; --accent: #1f5fbf; --bad: #a32020; }'
        '@media (prefers-color-scheme: dark) { :root { --bg: #14171d; --fg: #e4e8f0; --card: #1c2029; --line: #333a48; --muted: #9aa3b5; --accent: #7fb0ff; --bad: #ff8a8a; } }'
        'body { margin: 0; background: var(--bg); color: var(--fg); font: 15px/1.5 system-ui, "Segoe UI", sans-serif; }'
        'header, main, footer { max-width: 60rem; margin: 0 auto; padding: 0 1rem; }'
        'header { padding-top: 1.5rem; }'
        'h1 { margin: 0 0 .25rem; font-size: 1.6rem; }'
        'h2 { margin: 0 0 .5rem; font-size: 1.2rem; }'
        'h3 { margin: 1rem 0 .25rem; font-size: 1rem; color: var(--muted); }'
        'section { background: var(--card); border: 1px solid var(--line); border-radius: 8px; padding: 1rem; margin: 1rem 0; }'
        'a { color: var(--accent); }'
        'table { border-collapse: collapse; width: 100%; margin: .5rem 0; }'
        'th, td { text-align: left; padding: .25rem .5rem; border-bottom: 1px solid var(--line); vertical-align: top; overflow-wrap: anywhere; }'
        'th { color: var(--muted); font-weight: 600; }'
        'code { font-family: ui-monospace, Consolas, monospace; font-size: .9em; }'
        'summary { cursor: pointer; color: var(--accent); }'
        '.muted { color: var(--muted); }'
        '.bad { color: var(--bad); }'
        'footer { padding-bottom: 2rem; color: var(--muted); font-size: .85rem; }'
    )
    return ($css -join "`n")
}

# Pure: the whole document for one result, the same text for the same input.
function ConvertTo-SweeprCheckHtml {
    param(
        [Parameter(Mandatory = $true)]
        $Result
    )

    $sections = Get-SweeprReportValue $Result 'Sections'
    $version = ConvertTo-SweeprReportText (Get-SweeprReportValue $Result 'Version')
    $generated = ConvertTo-SweeprReportText (Get-SweeprReportValue $Result 'GeneratedAt')

    $out = New-Object System.Collections.ArrayList
    [void]$out.Add('<!doctype html>')
    [void]$out.Add('<html lang="en">')
    [void]$out.Add('<head>')
    [void]$out.Add('<meta charset="utf-8">')
    # Before any style or body: nothing but inline style may load, so a stray value cannot run or fetch.
    [void]$out.Add('<meta http-equiv="Content-Security-Policy" content="default-src ''none''; style-src ''unsafe-inline''">')
    [void]$out.Add('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$out.Add('<title>Sweepr check report</title>')
    [void]$out.Add('<style>')
    [void]$out.Add((Get-SweeprReportStyle))
    [void]$out.Add('</style>')
    [void]$out.Add('</head>')
    [void]$out.Add('<body>')
    [void]$out.Add('<header>')
    [void]$out.Add('<h1>Sweepr check report</h1>')
    [void]$out.Add("<p class=""muted"">Version <span>$version</span>, created <span>$generated</span>. Nothing was changed on this PC.</p>")
    [void]$out.Add('<p><a href="#clean">Cleanup potential</a> | <a href="#apps">Apps and features</a> | <a href="#system">System health</a> | <a href="#projects">Project artifacts</a></p>')
    [void]$out.Add('</header>')
    [void]$out.Add('<main>')

    if ((Get-SweeprReportValue $Result 'IsAdmin') -eq $false) {
        [void]$out.Add('<p id="admin-hint" class="muted">Some values need more rights. Run Sweepr in an administrator PowerShell for a complete check.</p>')
    }

    $areas = @(
        @{ Id = 'clean'; Title = 'Cleanup potential'; Name = 'Clean'; Body = 'Get-SweeprReportCleanBody' }
        @{ Id = 'apps'; Title = 'Apps and features'; Name = 'Apps'; Body = 'Get-SweeprReportAppsBody' }
        @{ Id = 'system'; Title = 'System health'; Name = 'System'; Body = 'Get-SweeprReportSystemBody' }
        @{ Id = 'projects'; Title = 'Project artifacts'; Name = 'Projects'; Body = 'Get-SweeprReportProjectsBody' }
    )
    foreach ($area in $areas) {
        $section = Get-SweeprReportValue $sections $area.Name
        $body = & $area.Body $section
        [void]$out.Add('<section id="' + $area.Id + '">')
        [void]$out.Add('<h2>' + $area.Title + '</h2>')
        [void]$out.Add($body)
        [void]$out.Add('</section>')
    }

    $notMeasured = @(Get-SweeprReportList (Get-SweeprReportValue $Result 'NotMeasured'))
    if ($notMeasured.Count -gt 0) {
        $rows = foreach ($n in $notMeasured) {
            '<tr><td>' + (ConvertTo-SweeprReportText (Get-SweeprReportValue $n 'Section')) + '</td><td>' +
            (ConvertTo-SweeprReportText (Get-SweeprReportValue $n 'Name')) + '</td><td>' +
            (ConvertTo-SweeprReportText (Get-SweeprReportValue $n 'Reason')) + '</td></tr>'
        }
        [void]$out.Add('<section id="not-measured">')
        [void]$out.Add('<h2>Not measured</h2>')
        [void]$out.Add('<p>These values are missing from the numbers above.</p>')
        [void]$out.Add((Get-SweeprReportTable -Headers @('Area', 'Name', 'Reason') -Rows $rows))
        [void]$out.Add('</section>')
    }

    [void]$out.Add('</main>')
    [void]$out.Add('<footer>')
    [void]$out.Add('<p>Made by Sweepr. This report is a snapshot and stays on this PC.</p>')
    [void]$out.Add('</footer>')
    [void]$out.Add('</body>')
    [void]$out.Add('</html>')
    return (($out -join "`n") + "`n")
}

# The folder of the report. A function so that tests can replace it.
function Get-SweeprCheckReportDir {
    $temp = $env:TEMP
    if ([string]::IsNullOrWhiteSpace($temp)) { $temp = [System.IO.Path]::GetTempPath() }
    return $temp
}

# The only place that starts a program: the default browser opens the file.
function Open-SweeprCheckReport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Start-Process -FilePath $Path
}

# Writes the report and (unless -NoOpen) opens it. Returns the path. A folder or write problem is
# thrown; a browser that does not start is not: the report exists and its path is still returned.
function Invoke-SweeprCheckReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Result,

        [switch]$NoOpen
    )

    $html = ConvertTo-SweeprCheckHtml -Result $Result
    $dir = Get-SweeprCheckReportDir
    # No folder is created: a missing temp folder is a broken setup, not something to repair here.
    if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir -PathType Container)) {
        throw "Report folder not found."
    }
    $name = 'sweepr-check-{0}.html' -f (Get-Date).ToString('yyyy-MM-dd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    $path = Join-Path $dir $name
    [System.IO.File]::WriteAllText($path, $html, (New-Object System.Text.UTF8Encoding($false)))

    if (-not $NoOpen) {
        try { Open-SweeprCheckReport -Path $path }
        catch { Write-Debug "sw check: report not opened: $($_.Exception.Message)" }
    }
    return [string]$path
}
