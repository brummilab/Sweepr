# Sweepr - terminal building blocks
#
# Console size, display width of text in terminal cells, one row of a size list, the logo and the
# result frame at the end of a command. Loaded by dot-sourcing; it loads its own dependencies
# (base.ps1 for the colour table, log.ps1 for the spinner and the interactive-output check) from its
# own folder, so it also works when loaded alone. Loading writes nothing.

. ([System.IO.Path]::Combine($PSScriptRoot, 'base.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'log.ps1'))

# ============================================================================
# Console size
# ============================================================================

function Get-SwConsoleSize {
    <#
    .SYNOPSIS
        Width and height of the console window in cells; 80 x 24 when they cannot be read.
    .DESCRIPTION
        The other functions of this file take the width from here, so tests can set a terminal width
        by replacing this one function. Some hosts report 0 instead of failing; that counts as
        unreadable too.
    #>
    $width = 0
    $height = 0
    try {
        $rawUi = $Host.UI.RawUI
        if ($null -ne $rawUi) {
            $window = $rawUi.WindowSize
            $width = [int]$window.Width
            $height = [int]$window.Height
        }
    }
    catch {
        $width = 0
        $height = 0
    }
    if ($width -le 0 -or $height -le 0) { return @{ Width = [int]80; Height = [int]24 } }
    return @{ Width = $width; Height = $height }
}

# ============================================================================
# Display width
# ============================================================================

# Code point ranges that take two terminal cells. log.ps1's spinner uses the same ranges, so a
# spinner line and a size list agree on where a column ends.
$script:SwWideRanges = @(
    @(0x1100, 0x115F), @(0x2329, 0x232A), @(0x2E80, 0x303E), @(0x3040, 0xA4CF),
    @(0xAC00, 0xD7A3), @(0xF900, 0xFAFF), @(0xFE10, 0xFE19), @(0xFE30, 0xFE6F),
    @(0xFF00, 0xFF60), @(0xFFE0, 0xFFE6), @(0x1F300, 0x1FAFF), @(0x20000, 0x3FFFD)
)

function Get-SwElementCells {
    # Cells of the text element that starts at Index, judged by its first code point.
    param([string]$Text, [int]$Index)

    $first = $Text[$Index]
    $codePoint = [int]$first
    if ([char]::IsHighSurrogate($first)) {
        if ($Index + 1 -lt $Text.Length -and [char]::IsLowSurrogate($Text[$Index + 1])) {
            $codePoint = [char]::ConvertToUtf32($first, $Text[$Index + 1])
        }
        else { return 1 }
    }
    elseif ([char]::IsLowSurrogate($first)) {
        # A lone surrogate can occur in NTFS file names; it must never throw.
        return 1
    }

    $category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($Text, $Index)
    switch ($category) {
        ([System.Globalization.UnicodeCategory]::NonSpacingMark) { return 0 }
        ([System.Globalization.UnicodeCategory]::EnclosingMark) { return 0 }
        ([System.Globalization.UnicodeCategory]::Format) { return 0 }
        ([System.Globalization.UnicodeCategory]::Control) { return 0 }
    }
    foreach ($range in $script:SwWideRanges) {
        if ($codePoint -ge $range[0] -and $codePoint -le $range[1]) { return 2 }
    }
    return 1
}

function Split-SwTextElements {
    # The text elements of Text with their cell widths, as two parallel lists.
    param([AllowNull()][AllowEmptyString()][string]$Text)

    $parts = New-Object System.Collections.Generic.List[string]
    $cells = New-Object System.Collections.Generic.List[int]
    if ([string]::IsNullOrEmpty($Text)) { return @{ Parts = $parts; Cells = $cells } }

    $starts = [System.Globalization.StringInfo]::ParseCombiningCharacters($Text)
    for ($i = 0; $i -lt $starts.Length; $i++) {
        $start = $starts[$i]
        $end = $Text.Length
        if ($i + 1 -lt $starts.Length) { $end = $starts[$i + 1] }
        $parts.Add($Text.Substring($start, $end - $start))
        $cells.Add((Get-SwElementCells -Text $Text -Index $start))
    }
    return @{ Parts = $parts; Cells = $cells }
}

function Measure-SwDisplayWidth {
    <#
    .SYNOPSIS
        Number of terminal cells Text takes (CJK and emoji two, combining marks none).
    .DESCRIPTION
        Counted by own rules on purpose: the console host's buffer-cell helper and .NET format widths
        count CJK as one cell on Windows.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)

    $elements = Split-SwTextElements -Text $Text
    $total = 0
    foreach ($cell in $elements.Cells) { $total += $cell }
    return [int]$total
}

# ============================================================================
# Size list row
# ============================================================================

function Format-SwSizeRow {
    <#
    .SYNOPSIS
        One row of a size list: name column, a space, the size right-aligned in 10, the suffix.
    .DESCRIPTION
        The name column is measured in cells, so rows with ASCII, CJK and cut names all end at the
        same cell. 18 cells of the terminal stay reserved: 6 for the caller's selection prefix,
        1 separator, 10 for the size and the last column, which would wrap when written to.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Name,
        [AllowNull()][AllowEmptyString()][string]$Size,
        [AllowNull()][AllowEmptyString()][string]$Suffix = '',
        [int]$NameWidth = 42,
        [switch]$KeepEnd
    )

    if ($null -eq $Suffix) { $Suffix = '' }
    if ($null -eq $Size) { $Size = '' }

    $console = Get-SwConsoleSize
    $room = [int]$console.Width - 18 - (Measure-SwDisplayWidth -Text $Suffix)
    if ($room -lt 1) { $room = 1 }
    $column = [Math]::Min($NameWidth, $room)
    if ($column -lt 1) { $column = 1 }

    # Tabs, line breaks and escape characters in a name would break the row.
    $clean = [regex]::Replace([string]$Name, '[\x00-\x1F\x7F]', ' ')
    $elements = Split-SwTextElements -Text $clean
    $total = 0
    foreach ($cell in $elements.Cells) { $total += $cell }

    if ($total -le $column) {
        $nameColumn = $clean + (' ' * ($column - $total))
    }
    else {
        $dots = [Math]::Min(3, $column)
        $space = $column - $dots
        $used = 0
        $count = $elements.Parts.Count
        $builder = New-Object System.Text.StringBuilder
        if ($KeepEnd) {
            # Paths differ at their end, so keep that and cut the start.
            $first = $count
            while ($first -gt 0 -and $used + $elements.Cells[$first - 1] -le $space) {
                $first--
                $used += $elements.Cells[$first]
            }
            [void]$builder.Append('.' * $dots)
            for ($i = $first; $i -lt $count; $i++) { [void]$builder.Append($elements.Parts[$i]) }
        }
        else {
            $last = 0
            while ($last -lt $count -and $used + $elements.Cells[$last] -le $space) {
                $used += $elements.Cells[$last]
                $last++
            }
            for ($i = 0; $i -lt $last; $i++) { [void]$builder.Append($elements.Parts[$i]) }
            [void]$builder.Append('.' * $dots)
        }
        # A wide character that no longer fits leaves a gap; fill it so the column stays exact.
        [void]$builder.Append(' ' * ($space - $used))
        $nameColumn = $builder.ToString()
    }

    return [string]($nameColumn + ' ' + $Size.PadLeft(10) + $Suffix)
}

# ============================================================================
# Result frame and logo
# ============================================================================

function Show-SwResultFrame {
    <#
    .SYNOPSIS
        Writes the closing frame of a command: rule, blue heading, detail lines, rule.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$Heading,
        [AllowNull()][AllowEmptyCollection()][string[]]$Details
    )

    # A running spinner would mix its animation line into the frame.
    Stop-Spinner
    # Leave the last result on screen for a moment; redirected output gets no pause.
    if (Test-SweeprInteractiveOutput) { Start-Sleep -Milliseconds 180 }

    $width = [int](Get-SwConsoleSize).Width
    $length = [Math]::Max(1, [Math]::Min(70, $width))
    $rule = '=' * $length
    $blue = Get-SweeprColor -Name 'Blue'
    $reset = Get-SweeprColor -Name 'NC'

    Write-Host -Object ''
    Write-Host -Object $rule
    Write-Host -Object ([string]$blue + $Heading + [string]$reset)
    foreach ($line in @($Details)) {
        if (-not [string]::IsNullOrEmpty($line)) { Write-Host -Object $line }
    }
    Write-Host -Object $rule
    # Keeps the shell prompt off the rule.
    Write-Host -Object ''
}

function Show-SwLogo {
    <#
    .SYNOPSIS
        Writes the Sweepr logo with the project address and a short slogan.
    .DESCRIPTION
        Plain ASCII only (code page safe under Windows PowerShell 5.1) and at most 7 lines with the
        blank line, because the main menu redraws logo, entries and update hint in a 24-line window.
    #>
    try {
        $green = [string](Get-SweeprColor -Name 'Green')
        $blue = [string](Get-SweeprColor -Name 'Blue')
        $reset = [string](Get-SweeprColor -Name 'NC')
        $art = @(
            '  ___  _ _ _  ___  ___  ___  ___ ',
            ' / __|| | | || __|| __|| _ \| _ \',
            ' \__ \| V V || _| | _| |  _/|   /',
            ' |___/ \_/\_/ |___||___||_|  |_|_\'
        )
        $side = @(
            '',
            ($blue + '   https://github.com/brummilab/sweepr' + $reset),
            ($green + '   Keeps Windows tidy, safely.' + $reset),
            ''
        )
        for ($i = 0; $i -lt $art.Count; $i++) {
            Write-Host -Object ($green + $art[$i] + $reset + $side[$i])
        }
        Write-Host -Object ''
    }
    catch {
        # The logo is decoration; a host without a console must never fail a command over it.
        $null = $_
    }
}

# ============================================================================
# Old names (forwarding functions until their callers are rewritten)
# ============================================================================
# Functions, not aliases: tests mock the old names, and an alias would bypass or confuse those mocks.

function Get-TerminalSize { Get-SwConsoleSize }

function Get-TerminalTextWidth {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    Measure-SwDisplayWidth @PSBoundParameters
}

function Format-SizeListEntry {
    param(
        [AllowNull()][AllowEmptyString()][string]$Name,
        [AllowNull()][AllowEmptyString()][string]$Size,
        [AllowNull()][AllowEmptyString()][string]$Suffix = '',
        [int]$NameWidth = 42,
        [switch]$KeepEnd
    )
    Format-SwSizeRow @PSBoundParameters
}

function Show-SummaryBlock {
    param(
        [AllowNull()][AllowEmptyString()][string]$Heading,
        [AllowNull()][AllowEmptyCollection()][string[]]$Details
    )
    Show-SwResultFrame @PSBoundParameters
}

function Show-Banner { Show-SwLogo }
