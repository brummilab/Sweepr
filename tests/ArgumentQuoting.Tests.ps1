# B-01: values that lib code embeds as '...' literals into PowerShell source for a
# child process (-EncodedCommand) must arrive as exactly one unchanged value.
# PowerShell reads U+2018, U+2019, U+201A and U+201B as single quotes too, so a
# path or argument holding one must not end the literal or run a command.
# Not affected: the sw.cmd / sweepr.cmd launchers in install.ps1 (they pass %* to
# powershell -File, no PowerShell source is built) and the Go sw.exe, which has its
# own tests in cmd/sw/launcher_test.go.
# The update check's background command is covered in SwUpdateCheck.Tests.ps1 (V-16).

# Hostile values, defined at discovery time because they feed -ForEach. Windows file
# names cannot hold " : \ /, so path positions get a sanitised copy (ConvertTo-SafeName
# in BeforeAll); the quote-like characters, ;, $, backtick and space stay in.
$hostileValues = @(
    "it's"
    "Rock$([char]0x2019)n$([char]0x2019)Roll"
    "a$([char]0x2018)b"
    "a$([char]0x201A)b"
    "a$([char]0x201B)b"
    "$([char]0x2019)x$([char]0x2019)"
    "x$([char]0x2019); New-Item marker; $([char]0x2019)"
    "x$([char]0x2018); New-Item marker; $([char]0x2018)"
    "x$([char]0x201A); New-Item marker; $([char]0x201A)"
    "x$([char]0x201B); New-Item marker; $([char]0x201B)"
    "x'; New-Item marker; '"
    "$([char]0x2019)`$(New-Item marker)$([char]0x2019)"
    'a b;c'
    '$env:PATH $(Get-Date)'
    'back`tick'
    'say "hi"'
    'C:\Music\'
    "O$([char]0x2019)Neil's $([char]0x2018)x$([char]0x201A) $([char]0x201B)y; `$z ``w\ `"q`" \"
)

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:RepoRoot 'lib\clean\dev.ps1')

    # The current host runs the decoded command: pwsh 7 or Windows PowerShell 5.1.
    $script:HostPath = (Get-Process -Id $PID).Path

    # Prints each argument as hex UTF-16 units into the file named by the
    # environment, so no console encoding is involved.
    $script:EchoBody = @'
$lines = foreach ($a in $args) { ($a.ToCharArray() | ForEach-Object { '{0:X4}' -f [int]$_ }) -join '' }
[IO.File]::WriteAllText($env:SWEEPR_TEST_ARGS_OUT, ($lines -join "`n"))
'@
    function ConvertTo-HexUnits([string]$Value) { (($Value.ToCharArray() | ForEach-Object { '{0:X4}' -f [int]$_ }) -join '') }
    function ConvertTo-SafeName([string]$Value) { $Value -replace '[\\/:"]', '_' }

    # Writes the echo script as a command on PATH; Unix command discovery needs the x bit.
    function New-EchoCommand([string]$Path) {
        Set-Content -LiteralPath $Path -Value $script:EchoBody -Encoding UTF8
        if ([IO.Path]::DirectorySeparatorChar -eq '/') { & chmod +x $Path }
    }

    # Runs a recorded "... -EncodedCommand <b64>" argument string with the current host.
    function Invoke-RecordedEncodedCommand {
        param([string]$Arguments, [string]$WorkDir)
        $encoded = ($Arguments -split ' ')[-1]
        Push-Location -LiteralPath $WorkDir
        try {
            $output = & $script:HostPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1
            return @($output | ForEach-Object { "$_" })
        }
        finally {
            Pop-Location
        }
    }

    $script:SavedPath = $env:PATH
    $script:SavedOut = $env:SWEEPR_TEST_ARGS_OUT
}

AfterAll {
    $env:PATH = $script:SavedPath
    $env:SWEEPR_TEST_ARGS_OUT = $script:SavedOut
}

Describe 'Owner process command (dev.ps1 Invoke-SweeprOwnerProcess)' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:Work -Force
        $script:BinDir = Join-Path $script:Work 'bin'
        $null = New-Item -ItemType Directory -Path $script:BinDir -Force
        $script:Out = Join-Path $script:Work 'args.txt'
        $env:SWEEPR_TEST_ARGS_OUT = $script:Out
        $env:PATH = $script:BinDir + [IO.Path]::PathSeparator + $script:SavedPath
        $script:Recorded = $null
        # Fake Process object: records the StartInfo, never starts anything.
        Mock New-Object { [Diagnostics.ProcessStartInfo]::new() }
        Mock New-Object -ParameterFilter { $TypeName -eq 'Diagnostics.Process' } -MockWith {
            $fake = [pscustomobject]@{ StartInfo = $null; ExitCode = 0; HasExited = $true; Id = 1 }
            $reader = [pscustomobject]@{}
            $reader | Add-Member -MemberType ScriptMethod -Name ReadToEndAsync -Value {
                $task = [pscustomobject]@{ Result = '' }
                $task | Add-Member -MemberType ScriptMethod -Name Wait -Value { param($ms) $true }
                $task
            }
            $fake | Add-Member -NotePropertyName StandardOutput -NotePropertyValue $reader
            $fake | Add-Member -NotePropertyName StandardError -NotePropertyValue $reader
            $fake | Add-Member -MemberType ScriptMethod -Name Start -Value { $true }
            $fake | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $true }
            $fake | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
            $script:Recorded = $fake
            $fake
        }
    }

    It 'Passes one unchanged argument and runs no injected command: <_>' -ForEach $hostileValues {
        $value = $_
        New-EchoCommand (Join-Path $script:BinDir 'owner-fixture.ps1')
        $null = Invoke-SweeprOwnerProcess -Name 'owner-fixture.ps1' -Arguments @('first', $value)
        $script:Recorded | Should -Not -BeNullOrEmpty
        $log = Invoke-RecordedEncodedCommand -Arguments $script:Recorded.StartInfo.Arguments -WorkDir $script:Work
        $script:Out | Should -Exist -Because ($log -join ' | ')
        $expected = (@('first', $value) | ForEach-Object { ConvertTo-HexUnits $_ }) -join "`n"
        (Get-Content -LiteralPath $script:Out -Raw) | Should -BeExactly $expected
        (Join-Path $script:Work 'marker') | Should -Not -Exist
    }

    It 'Runs an executable whose path holds quote-like characters, spaces and semicolons: <_>' -ForEach $hostileValues {
        $name = "own$(ConvertTo-SafeName $_) x.ps1"
        New-EchoCommand (Join-Path $script:BinDir $name)
        $null = Invoke-SweeprOwnerProcess -Name $name -Arguments @('ok')
        $script:Recorded | Should -Not -BeNullOrEmpty
        $log = Invoke-RecordedEncodedCommand -Arguments $script:Recorded.StartInfo.Arguments -WorkDir $script:Work
        $script:Out | Should -Exist -Because ($log -join ' | ')
        (Get-Content -LiteralPath $script:Out -Raw) | Should -BeExactly (ConvertTo-HexUnits 'ok')
        (Join-Path $script:Work 'marker') | Should -Not -Exist
    }

    It 'Runs an executable inside a folder whose name holds U+<_>' -ForEach @('2018', '2019', '201A', '201B') {
        $folder = Join-Path $script:Work ("D$([char][Convert]::ToInt32($_, 16))Angelo")
        $null = New-Item -ItemType Directory -Path $folder -Force
        $env:PATH = $folder + [IO.Path]::PathSeparator + $script:SavedPath
        New-EchoCommand (Join-Path $folder 'owner-fixture.ps1')
        $null = Invoke-SweeprOwnerProcess -Name 'owner-fixture.ps1' -Arguments @('ok')
        $script:Recorded | Should -Not -BeNullOrEmpty
        $log = Invoke-RecordedEncodedCommand -Arguments $script:Recorded.StartInfo.Arguments -WorkDir $script:Work
        $script:Out | Should -Exist -Because ($log -join ' | ')
        (Get-Content -LiteralPath $script:Out -Raw) | Should -BeExactly (ConvertTo-HexUnits 'ok')
    }
}
