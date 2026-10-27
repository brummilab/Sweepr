# Sweepr - tests for lib\core\ui.ps1
#
# Written from the spec only. Covers the load contract (2.1), rules V-1 to V-27 and the transition names
# (L7-1: the five old names stay as forwarding functions, not aliases).
#
# Interface pinned here (spec 2.2):
#   Get-SwConsoleSize                         hashtable Width, Height (V-1 to V-3; L7-6: width 0 = unreadable)
#   Measure-SwDisplayWidth -Text <s>          cells (V-4 to V-7)
#   Format-SwSizeRow -Name -Size [-Suffix] [-NameWidth] [-KeepEnd]   one string (V-8 to V-16)
#   Show-SwResultFrame -Heading [-Details]    frame on the host (V-17 to V-22)
#   Show-SwLogo                               logo on the host (V-23 to V-26)
#   Old names: Get-TerminalSize, Get-TerminalTextWidth, Format-SizeListEntry, Show-SummaryBlock, Show-Banner
#
# Seams used: Get-SwConsoleSize is mocked to set the terminal width (the other functions must ask it).
# Show-SwResultFrame is checked with mocks of Stop-Spinner and Test-SweeprInteractiveOutput (log.ps1) and
# Start-Sleep (the pause of V-18). Host output is captured from the information stream (6>&1).
# All non-ASCII test text is built from code points, so this file stays ASCII.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:UiFile = Join-Path $script:RepoRoot 'lib\core\ui.ps1'
    # Loaded alone on purpose: ui.ps1 loads base.ps1 and log.ps1 itself (2.1).
    . $script:UiFile

    $script:Palette = Get-SweeprDefaultColors

    function script:S {
        param([int[]]$CodePoints)
        $sb = New-Object System.Text.StringBuilder
        foreach ($cp in $CodePoints) {
            if ($cp -ge 0xD800 -and $cp -le 0xDFFF) { [void]$sb.Append([char]$cp) }
            else { [void]$sb.Append([char]::ConvertFromUtf32($cp)) }
        }
        $sb.ToString()
    }

    function script:Repeat([string]$Text, [int]$Count) { -join (@($Text) * $Count) }

    # Rebuild the text written with Write-Host from captured information records.
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

    function script:Remove-Ansi([string]$Text) { [regex]::Replace($Text, "$([char]27)\[[0-9;]*m", '') }

    # Removes every colour value of the shared table; what is left must hold no escape character (V-27).
    function script:Remove-PaletteCodes([string]$Text) {
        foreach ($value in @($script:Palette.Values | Sort-Object { $_.Length } -Descending)) { $Text = $Text.Replace([string]$value, '') }
        $Text
    }

    # Independent cell count for the test data (only BMP CJK and ASCII are used with it).
    function script:Get-TestCells([string]$Text) {
        $cells = 0
        foreach ($ch in $Text.ToCharArray()) {
            $code = [int]$ch
            if ($code -ge 0x4E00 -and $code -le 0x9FFF) { $cells += 2 } else { $cells += 1 }
        }
        $cells
    }
}

Describe 'Sw ui module loading' {
    It 'Loads alone in a fresh session, twice, without output (2.1)' {
        $file = "'" + $script:UiFile.Replace("'", "''") + "'"
        $script = @"
. $file
. $file
'##RESULT##'
[bool](Get-Command Format-SwSizeRow -ErrorAction SilentlyContinue)
"@
        $exe = (Get-Process -Id $PID).Path
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script))
        $out = & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1 | Out-String
        $parts = $out -split '##RESULT##'
        $parts[0].Trim() | Should -BeNullOrEmpty
        $parts[1].Trim() | Should -Be 'True'
    }
}

Describe 'Get-SwConsoleSize' {
    It 'Returns positive integers Width and Height (V-1)' {
        $size = Get-SwConsoleSize
        $size | Should -BeOfType [hashtable]
        $size.Width | Should -BeOfType [int]
        $size.Height | Should -BeOfType [int]
        $size.Width | Should -BeGreaterThan 0
        $size.Height | Should -BeGreaterThan 0
    }

    It 'Falls back to 80 x 24 in a host without a console window and never throws (V-2, L7-6)' {
        $ps = [PowerShell]::Create()
        try {
            $null = $ps.AddScript(". '$($script:UiFile.Replace("'", "''"))'; Get-SwConsoleSize")
            $result = @($ps.Invoke())
            $ps.Streams.Error.Count | Should -Be 0
        }
        finally { $ps.Dispose() }
        $result.Count | Should -Be 1
        $result[0].Width | Should -Be 80
        $result[0].Height | Should -Be 24
    }

    It 'Writes nothing (V-3)' {
        $records = @(& { $null = Get-SwConsoleSize } *>&1)
        $records.Count | Should -Be 0
        @(Get-SwConsoleSize 6>&1 | Where-Object { $_ -is [System.Management.Automation.InformationRecord] }).Count | Should -Be 0
    }
}

Describe 'Measure-SwDisplayWidth' {
    It 'Measures <Name> as <Expected> cells (V-7)' -ForEach @(
        @{ Name = 'abc'; CodePoints = @(0x61, 0x62, 0x63); Expected = 3 }
        @{ Name = 'two CJK characters'; CodePoints = @(0x4E2D, 0x6587); Expected = 4 }
        @{ Name = 'precomposed e-acute editor'; CodePoints = @(0xE9, 0x64, 0x69, 0x74, 0x6F, 0x72); Expected = 6 }
        @{ Name = 'e plus combining acute'; CodePoints = @(0x65, 0x301); Expected = 1 }
        @{ Name = 'grinning face emoji'; CodePoints = @(0x1F600); Expected = 2 }
    ) {
        Measure-SwDisplayWidth -Text (S $CodePoints) | Should -Be $Expected
    }

    It 'Measures empty text and null as 0 (V-7)' {
        Measure-SwDisplayWidth -Text '' | Should -Be 0
        Measure-SwDisplayWidth -Text $null | Should -Be 0
    }

    It 'Returns an integer' {
        Measure-SwDisplayWidth -Text 'x' | Should -BeOfType [int]
    }

    It 'Counts U+<Hex> as <Expected> (V-4 zero-width categories)' -ForEach @(
        @{ Hex = '0301'; Expected = 0 }   # NonSpacingMark
        @{ Hex = '20DD'; Expected = 0 }   # EnclosingMark
        @{ Hex = '200B'; Expected = 0 }   # Format
        @{ Hex = '0007'; Expected = 0 }   # Control
        @{ Hex = '001B'; Expected = 0 }   # Control
    ) {
        Measure-SwDisplayWidth -Text (S @([Convert]::ToInt32($Hex, 16))) | Should -Be $Expected
    }

    It 'Counts U+<Hex> as <Expected> (V-5 wide ranges and their edges)' -ForEach @(
        @{ Hex = '10FF'; Expected = 1 }
        @{ Hex = '1100'; Expected = 2 }
        @{ Hex = '115F'; Expected = 2 }
        @{ Hex = '1160'; Expected = 1 }
        @{ Hex = '2328'; Expected = 1 }
        @{ Hex = '2329'; Expected = 2 }
        @{ Hex = '232A'; Expected = 2 }
        @{ Hex = '232B'; Expected = 1 }
        @{ Hex = '2E7F'; Expected = 1 }
        @{ Hex = '2E80'; Expected = 2 }
        @{ Hex = '3000'; Expected = 2 }
        @{ Hex = '303E'; Expected = 2 }
        @{ Hex = '303F'; Expected = 1 }
        @{ Hex = '3040'; Expected = 2 }
        @{ Hex = '4E00'; Expected = 2 }
        @{ Hex = 'A4C6'; Expected = 2 }
        @{ Hex = 'A4D0'; Expected = 1 }
        @{ Hex = 'ABFF'; Expected = 1 }
        @{ Hex = 'AC00'; Expected = 2 }
        @{ Hex = 'D7A3'; Expected = 2 }
        @{ Hex = 'D7A4'; Expected = 1 }
        @{ Hex = 'F8FF'; Expected = 1 }
        @{ Hex = 'F900'; Expected = 2 }
        @{ Hex = 'FAFF'; Expected = 2 }
        @{ Hex = 'FB00'; Expected = 1 }
        @{ Hex = 'FE10'; Expected = 2 }
        @{ Hex = 'FE19'; Expected = 2 }
        @{ Hex = 'FE30'; Expected = 2 }
        @{ Hex = 'FE6F'; Expected = 2 }
        @{ Hex = 'FE70'; Expected = 1 }
        @{ Hex = 'FF01'; Expected = 2 }
        @{ Hex = 'FF60'; Expected = 2 }
        @{ Hex = 'FF61'; Expected = 1 }
        @{ Hex = 'FFE0'; Expected = 2 }
        @{ Hex = 'FFE6'; Expected = 2 }
        @{ Hex = 'FFE8'; Expected = 1 }
        @{ Hex = '1F2FF'; Expected = 1 }
        @{ Hex = '1F300'; Expected = 2 }
        @{ Hex = '1FAFF'; Expected = 2 }
        @{ Hex = '1FB00'; Expected = 1 }
        @{ Hex = '1FFFD'; Expected = 1 }
        @{ Hex = '20000'; Expected = 2 }
        @{ Hex = '3FFFD'; Expected = 2 }
    ) {
        Measure-SwDisplayWidth -Text (S @([Convert]::ToInt32($Hex, 16))) | Should -Be $Expected
    }

    It 'Counts a lone <Kind> surrogate as one cell without throwing (V-6)' -ForEach @(
        @{ Kind = 'high'; Unit = 0xD83D }
        @{ Kind = 'low'; Unit = 0xDE00 }
    ) {
        $text = 'a' + [char]$Unit + 'b'
        { Measure-SwDisplayWidth -Text $text } | Should -Not -Throw
        Measure-SwDisplayWidth -Text $text | Should -Be 3
        Measure-SwDisplayWidth -Text ([string][char]$Unit) | Should -Be 1
    }

    It 'Counts a reversed surrogate pair as two cells without throwing (V-6)' {
        $text = [string][char]0xDE00 + [char]0xD83D
        Measure-SwDisplayWidth -Text $text | Should -Be 2
    }
}

Describe 'Format-SwSizeRow' {
    BeforeEach {
        $script:ConsoleWidth = 60
        Mock Get-SwConsoleSize { @{ Width = $script:ConsoleWidth; Height = 24 } }
    }

    Context 'Spec examples (V-14)' {
        It 'Pads an ASCII name at width 60' {
            Format-SwSizeRow -Name 'Clash Party' -Size '443.4MB' |
                Should -BeExactly ('Clash Party' + (' ' * 31) + ' ' + '   443.4MB')
        }

        It 'Pads a CJK name by cells at width 60' {
            $name = S @(0x5FAE, 0x4FE1, 0x8F93, 0x5165, 0x6CD5)
            Format-SwSizeRow -Name $name -Size '443.4MB' |
                Should -BeExactly ($name + (' ' * 32) + ' ' + '   443.4MB')
        }

        It 'Cuts a long CJK name to whole characters and fills the gap at width 60' {
            $unit = S @(0x4E2D, 0x6587, 0x5E94, 0x7528)
            $name = Repeat $unit 20
            Format-SwSizeRow -Name $name -Size '1MB' |
                Should -BeExactly ($name.Substring(0, 19) + '...' + ' ' + ' ' + '       1MB')
        }

        It 'Shrinks the column for the suffix at width 40' {
            $script:ConsoleWidth = 40
            $unit = S @(0x4E2D, 0x6587, 0x9879, 0x76EE)
            $name = Repeat $unit 20
            $row = Format-SwSizeRow -Name $name -Size '12MB' -Suffix ' (3 items)' -NameWidth 32
            $row | Should -BeExactly ($unit + '...' + ' ' + ' ' + '      12MB' + ' (3 items)')
            Get-TestCells $row | Should -Be 33
        }

        It 'Keeps the end of a path with -KeepEnd' {
            Format-SwSizeRow -Name '~\Projects\client-work\storefront-redesign\frontend' -Size '1.2GB' -NameWidth 30 -KeepEnd |
                Should -BeExactly ('...torefront-redesign\frontend' + ' ' + '     1.2GB')
        }

        It 'Pads a short path with -KeepEnd' {
            Format-SwSizeRow -Name '~\shop\frontend' -Size '1MB' -NameWidth 30 -KeepEnd |
                Should -BeExactly ('~\shop\frontend' + (' ' * 15) + ' ' + '       1MB')
        }

        It 'Uses fewer dots when the column is narrower than three cells' {
            $script:ConsoleWidth = 20
            Format-SwSizeRow -Name 'Example' -Size '5MB' | Should -BeExactly ('..' + ' ' + '       5MB')
        }
    }

    Context 'Column width (V-8, V-9)' {
        It 'Uses the default name width 42 on a wide terminal' {
            $script:ConsoleWidth = 200
            Format-SwSizeRow -Name 'abc' -Size '1KB' | Should -BeExactly ('abc' + (' ' * 39) + ' ' + '       1KB')
        }

        It 'Uses -NameWidth when it is smaller than the terminal allows' {
            $script:ConsoleWidth = 200
            Format-SwSizeRow -Name 'abc' -Size '1KB' -NameWidth 10 | Should -BeExactly ('abc       ' + ' ' + '       1KB')
        }

        It 'Subtracts 18 cells and the suffix width from the terminal width' {
            $script:ConsoleWidth = 60
            $row = Format-SwSizeRow -Name 'abc' -Size '1KB' -Suffix ' (3 items)'
            $row | Should -BeExactly ('abc' + (' ' * 29) + ' ' + '       1KB' + ' (3 items)')
        }

        It 'Keeps a column of at least one cell on a tiny terminal' {
            $script:ConsoleWidth = 10
            Format-SwSizeRow -Name 'Example' -Size '5MB' | Should -BeExactly ('.' + ' ' + '       5MB')
        }

        It 'Never cuts the size and appends the suffix unchanged' {
            $script:ConsoleWidth = 200
            Format-SwSizeRow -Name 'a' -Size '123456789012B' -Suffix ' [x]' -NameWidth 3 |
                Should -BeExactly ('a  ' + ' ' + '123456789012B' + ' [x]')
        }

        It 'Accepts an omitted suffix as empty' {
            $script:ConsoleWidth = 200
            (Format-SwSizeRow -Name 'a' -Size '1B' -NameWidth 2) | Should -BeExactly ('a ' + ' ' + '        1B')
        }
    }

    Context 'Names (V-10 to V-13, V-15)' {
        It 'Replaces control characters with spaces (V-10)' {
            $script:ConsoleWidth = 200
            $name = 'a' + [char]9 + 'b' + [char]10 + 'c' + [char]27 + 'd' + [char]127 + 'e' + [char]0 + 'f' + [char]13
            Format-SwSizeRow -Name $name -Size '1B' -NameWidth 12 |
                Should -BeExactly ('a b c d e f ' + ' ' + '        1B')
        }

        It 'Cuts the end of an ASCII name without -KeepEnd (V-12)' {
            Format-SwSizeRow -Name 'abcdefghijklmnopqrstuvwxyz' -Size '1B' -NameWidth 10 |
                Should -BeExactly ('abcdefg...' + ' ' + '        1B')
        }

        It 'Cuts the start of a CJK name with -KeepEnd and keeps the column exact (V-12)' {
            $unit = S @(0x4E2D, 0x6587, 0x5E94, 0x7528)
            $name = 'x' + (Repeat $unit 5)
            $row = Format-SwSizeRow -Name $name -Size '1B' -NameWidth 10 -KeepEnd
            $column = $row.Substring(0, $row.Length - 11)
            Get-TestCells $column | Should -Be 10
            $column.StartsWith('...') | Should -BeTrue
            $column.Replace('.', '').Trim() | Should -BeExactly $name.Substring($name.Length - 3)
            $row.EndsWith(' ' + '        1B') | Should -BeTrue
        }

        It 'Ends every row at the same cell for ASCII, CJK, mixed and cut names (V-13)' {
            $cjk = S @(0x4E2D, 0x6587, 0x5E94, 0x7528)
            $rows = @(
                Format-SwSizeRow -Name 'Clash Party' -Size '443.4MB'
                Format-SwSizeRow -Name $cjk -Size '1MB'
                Format-SwSizeRow -Name ('App ' + $cjk + ' Pro') -Size '12KB'
                Format-SwSizeRow -Name (Repeat $cjk 20) -Size '9GB'
                Format-SwSizeRow -Name ('x' + (Repeat $cjk 20)) -Size '9GB'
                Format-SwSizeRow -Name (Repeat 'abcdefgh' 20) -Size '9GB' -KeepEnd
            )
            foreach ($row in $rows) { Get-TestCells $row | Should -Be 53 }
        }

        It 'Handles a lone surrogate in a <Kind> name without throwing (V-15)' -ForEach @(
            @{ Kind = 'short'; Repeat = 1 }
            @{ Kind = 'cut'; Repeat = 30 }
        ) {
            $name = Repeat ('ab' + [char]0xD800 + 'cd') $Repeat
            { Format-SwSizeRow -Name $name -Size '1MB' -NameWidth 20 } | Should -Not -Throw
            $row = Format-SwSizeRow -Name $name -Size '1MB' -NameWidth 20
            $row.Length | Should -Be 31
        }
    }

    Context 'Output (V-16)' {
        It 'Returns one string and writes nothing to the host' {
            $records = @(Format-SwSizeRow -Name 'abc' -Size '1MB' 6>&1)
            $records.Count | Should -Be 1
            $records[0] | Should -BeOfType [string]
        }

        It 'Contains no colour codes' {
            (Format-SwSizeRow -Name 'abc' -Size '1MB' -Suffix ' (2 items)').Contains([string][char]27) | Should -BeFalse
        }

        It 'Asks Get-SwConsoleSize for the terminal width' {
            Format-SwSizeRow -Name 'abc' -Size '1MB' | Out-Null
            Should -Invoke Get-SwConsoleSize -Scope It
        }
    }
}

Describe 'Show-SwResultFrame' {
    BeforeEach {
        $script:ConsoleWidth = 40
        $script:Interactive = $false
        Mock Get-SwConsoleSize { @{ Width = $script:ConsoleWidth; Height = 24 } }
        Mock Test-SweeprInteractiveOutput { $script:Interactive }
        Mock Stop-Spinner { }
        Mock Start-Sleep { }
    }

    BeforeAll {
        function script:Get-FrameText {
            param([string]$Heading, [AllowNull()][object[]]$Details, [switch]$NoDetails)
            $records = if ($NoDetails) { @(Show-SwResultFrame -Heading $Heading 6>&1) } else { @(Show-SwResultFrame -Heading $Heading -Details $Details 6>&1) }
            $script:FrameSuccessOutput = @($records | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
            ConvertTo-HostText $records
        }
    }

    It 'Writes blank line, rule, blue heading, details, rule, blank line (V-19)' {
        $text = Get-FrameText -Heading 'Cleanup complete' -Details @('Freed: 1.2GB', 'Items: 42')
        $rule = '=' * 40
        $heading = $script:Palette.Blue + 'Cleanup complete' + $script:Palette.NC
        $text | Should -BeExactly ("`n" + $rule + "`n" + $heading + "`n" + "Freed: 1.2GB`n" + "Items: 42`n" + $rule + "`n" + "`n")
        $script:FrameSuccessOutput.Count | Should -Be 0
    }

    It 'Makes the rule <Expected> characters long at width <Width> (V-20)' -ForEach @(
        @{ Width = 40; Expected = 40 }
        @{ Width = 70; Expected = 70 }
        @{ Width = 120; Expected = 70 }
        @{ Width = 1; Expected = 1 }
    ) {
        $script:ConsoleWidth = $Width
        $lines = (Get-FrameText -Heading 'Done' -NoDetails) -split "`n"
        $lines[1] | Should -BeExactly ('=' * $Expected)
        $lines[3] | Should -BeExactly ('=' * $Expected)
    }

    It 'Shows only the heading between the rules without details (V-21)' {
        $rule = '=' * 40
        $expected = "`n$rule`n" + $script:Palette.Blue + 'Done' + $script:Palette.NC + "`n$rule`n`n"
        Get-FrameText -Heading 'Done' -NoDetails | Should -BeExactly $expected
        Get-FrameText -Heading 'Done' -Details @() | Should -BeExactly $expected
    }

    It 'Skips empty and null details (V-21)' {
        $text = Get-FrameText -Heading 'Done' -Details @('', 'Would uninstall: 0', $null, '')
        $lines = $text -split "`n"
        $lines.Count | Should -Be 7
        $lines[3] | Should -BeExactly 'Would uninstall: 0'
    }

    It 'Writes details unchanged (V-22)' {
        $detail = '  Path: C:\Users\Example\[x] $(Get-Date) 100%'
        $lines = (Get-FrameText -Heading 'Done' -Details @($detail)) -split "`n"
        $lines[3] | Should -BeExactly $detail
    }

    It 'Stops a running spinner first (V-17)' {
        $null = Get-FrameText -Heading 'Done' -NoDetails
        Should -Invoke Stop-Spinner -Scope It
    }

    It 'Pauses shortly before the frame on interactive output (V-18)' {
        $script:Interactive = $true
        $null = Get-FrameText -Heading 'Done' -NoDetails
        Should -Invoke Start-Sleep -Scope It -Times 1 -Exactly -ParameterFilter {
            ($Milliseconds -gt 0 -and $Milliseconds -lt 250) -or ($Seconds -gt 0 -and $Seconds -lt 0.25)
        }
    }

    It 'Does not pause on redirected output (V-18)' {
        $script:Interactive = $false
        $null = Get-FrameText -Heading 'Done' -NoDetails
        Should -Invoke Start-Sleep -Scope It -Times 0 -Exactly
    }

    It 'Uses only colours of the shared table (V-27)' {
        $text = Get-FrameText -Heading 'Done' -Details @('a')
        (Remove-PaletteCodes $text).Contains([string][char]27) | Should -BeFalse
    }
}

Describe 'Show-SwLogo' {
    BeforeAll {
        $script:LogoText = ConvertTo-HostText @(Show-SwLogo 6>&1)
        $script:LogoPlain = Remove-Ansi $script:LogoText
    }

    It 'Shows the project URL (V-24)' {
        $script:LogoPlain | Should -Match ([regex]::Escape('https://github.com/brummilab/sweepr'))
    }

    It 'Colours the logo green and the URL blue (V-23)' {
        $script:LogoText.Contains($script:Palette.Green) | Should -BeTrue
        $pattern = [regex]::Escape($script:Palette.Blue) + '[^' + [char]27 + ']*' + [regex]::Escape('https://github.com/brummilab/sweepr')
        $script:LogoText | Should -Match $pattern
    }

    It 'Is at most 7 lines high and ends with a blank line (V-23, V-26)' {
        $plain = $script:LogoPlain
        ([regex]::Matches($plain, "`n")).Count | Should -BeLessOrEqual 7
        $plain.EndsWith("`n`n") | Should -BeTrue
        ([regex]::Matches($plain, "`n")).Count | Should -BeGreaterThan 2
    }

    It 'Uses only printable ASCII (V-23)' {
        foreach ($ch in $script:LogoPlain.ToCharArray()) {
            ([int]$ch -eq 10 -or ([int]$ch -ge 32 -and [int]$ch -le 126)) | Should -BeTrue -Because "U+$('{0:X4}' -f [int]$ch) is not printable ASCII"
        }
    }

    It 'Writes nothing to the output stream' {
        @(Show-SwLogo 6>$null).Count | Should -Be 0
    }

    It 'Uses only colours of the shared table (V-27)' {
        (Remove-PaletteCodes $script:LogoText).Contains([string][char]27) | Should -BeFalse
    }

    It 'Never throws in a host without a console (V-25)' {
        $ps = [PowerShell]::Create()
        try {
            $null = $ps.AddScript(". '$($script:UiFile.Replace("'", "''"))'; Show-SwLogo; Show-SwResultFrame -Heading 'Done' -Details @('a'); 'finished'")
            $result = @($ps.Invoke())
            $ps.Streams.Error.Count | Should -Be 0
        }
        finally { $ps.Dispose() }
        $result[-1] | Should -Be 'finished'
    }
}

Describe 'Sw ui transition names (L7-1)' {
    It 'Keeps <Name> as a function, not an alias' -ForEach @(
        @{ Name = 'Get-TerminalSize' }
        @{ Name = 'Get-TerminalTextWidth' }
        @{ Name = 'Format-SizeListEntry' }
        @{ Name = 'Show-SummaryBlock' }
        @{ Name = 'Show-Banner' }
    ) {
        (Get-Command -Name $Name -ErrorAction Stop).CommandType | Should -Be 'Function'
        Get-Alias -Name $Name -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'Get-TerminalSize forwards to Get-SwConsoleSize' {
        Mock Get-SwConsoleSize { @{ Width = 99; Height = 33 } }
        $size = Get-TerminalSize
        $size.Width | Should -Be 99
        $size.Height | Should -Be 33
    }

    It 'Get-TerminalTextWidth gives the same widths as Measure-SwDisplayWidth' {
        foreach ($text in @('abc', (S @(0x4E2D, 0x6587)), (S @(0x65, 0x301)), '', ('a' + [char]0xD800))) {
            Get-TerminalTextWidth -Text $text | Should -Be (Measure-SwDisplayWidth -Text $text)
        }
    }

    It 'Format-SizeListEntry gives the same row as Format-SwSizeRow' {
        Mock Get-SwConsoleSize { @{ Width = 60; Height = 24 } }
        $name = '~\Projects\client-work\storefront-redesign\frontend'
        Format-SizeListEntry -Name $name -Size '1.2GB' -Suffix ' (2 items)' -NameWidth 30 -KeepEnd |
            Should -BeExactly (Format-SwSizeRow -Name $name -Size '1.2GB' -Suffix ' (2 items)' -NameWidth 30 -KeepEnd)
        Format-SizeListEntry -Name 'Clash Party' -Size '443.4MB' |
            Should -BeExactly (Format-SwSizeRow -Name 'Clash Party' -Size '443.4MB')
    }

    It 'Show-SummaryBlock forwards heading and details to Show-SwResultFrame' {
        Mock Show-SwResultFrame { }
        Show-SummaryBlock -Heading 'Uninstall complete' -Details @('Would uninstall: 0', 'x')
        Should -Invoke Show-SwResultFrame -Times 1 -Exactly -ParameterFilter {
            $Heading -eq 'Uninstall complete' -and @($Details).Count -eq 2 -and $Details[0] -eq 'Would uninstall: 0'
        }
    }

    It 'Show-SummaryBlock writes the same frame as Show-SwResultFrame' {
        Mock Get-SwConsoleSize { @{ Width = 50; Height = 24 } }
        Mock Test-SweeprInteractiveOutput { $false }
        Mock Stop-Spinner { }
        $old = ConvertTo-HostText @(Show-SummaryBlock -Heading 'Done' -Details @('a', 'b') 6>&1)
        $new = ConvertTo-HostText @(Show-SwResultFrame -Heading 'Done' -Details @('a', 'b') 6>&1)
        $old | Should -BeExactly $new
    }

    It 'Show-Banner writes the same logo as Show-SwLogo' {
        $old = ConvertTo-HostText @(Show-Banner 6>&1)
        $new = ConvertTo-HostText @(Show-SwLogo 6>&1)
        $old | Should -BeExactly $new
    }
}
