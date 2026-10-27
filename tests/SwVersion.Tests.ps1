# Sweepr - tests for lib\core\version.ps1
#
# Written from the spec only. Covers rules V-1 to V-12, the load contract (2.1) and the transition
# names (L7-1: the old names stay as forwarding functions, not aliases).
#
# Interface pinned here (spec 2.2, L7):
#   Get-SwInstalledVersion -RootDir <path> [-DefaultVersion <text>]   version string (V-1 to V-6)
#   Repair-SwModuleSearchPath [-Edition <Desktop|Core>]               cleans $env:PSModulePath (V-7 to V-12)
#   $script:SwFallbackVersion                                          built-in fallback = repo VERSION (V-5)
#   Get-SweeprVersionString / Repair-SweeprModulePath                  old names, forwarding functions
#   L7-5: an unreadable VERSION stays an error; without SystemRoot C:\Windows is used; loading the file
#   does not switch on strict mode in the caller's scope.
#
# Platform neutral: VERSION files live in $TestDrive, PSModulePath and SystemRoot are set by the tests and
# put back right after each call (path logic with '\' is plain text processing, spec 4).

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:VersionFile = Join-Path $script:RepoRoot 'lib\core\version.ps1'
    . $script:VersionFile

    $script:RepoVersion = ([System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'VERSION'))).Trim([char]0xFEFF, ' ', "`t", "`r", "`n")
    $script:SystemModules = 'C:\Windows\System32\WindowsPowerShell\v1.0\Modules'

    function script:New-VersionRoot {
        param([string]$Name, $Content = $null, [switch]$Bytes, [byte[]]$Raw)
        $root = [System.IO.Path]::Combine($TestDrive, $Name)
        [void][System.IO.Directory]::CreateDirectory($root)
        $file = [System.IO.Path]::Combine($root, 'VERSION')
        if ($Bytes) { [System.IO.File]::WriteAllBytes($file, $Raw) }
        elseif ($null -ne $Content) { [System.IO.File]::WriteAllText($file, [string]$Content) }
        return $root
    }

    # Runs Repair-SwModuleSearchPath (or the old name) with a given PSModulePath and SystemRoot and puts both
    # back before returning the result, so the test process keeps a working module path.
    function script:Invoke-ModulePathRepair {
        param(
            [AllowNull()][string]$ModulePath,
            [AllowNull()][string]$SystemRoot = 'C:\Windows',
            [string]$Edition,
            [string]$Command = 'Repair-SwModuleSearchPath'
        )
        $savedPath = $env:PSModulePath
        $savedRoot = $env:SystemRoot
        try {
            $env:PSModulePath = $ModulePath
            $env:SystemRoot = $SystemRoot
            $output = if ($Edition) { & $Command -Edition $Edition } else { & $Command }
            return [pscustomobject]@{ Path = $env:PSModulePath; Output = @($output) }
        }
        finally {
            $env:PSModulePath = $savedPath
            $env:SystemRoot = $savedRoot
        }
    }

    function script:Invoke-ChildPowerShell {
        param([string]$Script, [string]$WorkingDirectory = $TestDrive)
        $exe = (Get-Process -Id $PID).Path
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Script))
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.WorkingDirectory = $WorkingDirectory
        $process = [System.Diagnostics.Process]::Start($psi)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { $process.Kill(); throw 'child PowerShell timed out' }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Out = $stdout.Result; Err = $stderr.Result }
    }

    function script:ConvertTo-Literal([string]$Value) { "'" + $Value.Replace("'", "''") + "'" }
}

Describe 'Sw version module loading' {
    It 'Loads alone in a fresh session, twice, without output and without strict mode for the caller' {
        $file = ConvertTo-Literal $script:VersionFile
        $result = Invoke-ChildPowerShell -Script @"
Set-StrictMode -Off
`$ErrorActionPreference = 'Continue'
. $file
. $file
'##RESULT##'
`$strict = try { `$null = `$notDefinedAnywhere; 'off' } catch { 'on' }
`$has = [bool](Get-Command Get-SwInstalledVersion -ErrorAction SilentlyContinue)
`$fallback = [string]`$script:SwFallbackVersion
@{ Strict = `$strict; Eap = [string]`$ErrorActionPreference; Has = `$has; Fallback = `$fallback } | ConvertTo-Json -Compress
"@
        $result.ExitCode | Should -Be 0
        $parts = $result.Out -split '##RESULT##'
        $parts[0].Trim() | Should -BeNullOrEmpty
        $data = $parts[1].Trim() | ConvertFrom-Json
        $data.Strict | Should -Be 'off'
        $data.Eap | Should -Be 'Continue'
        $data.Has | Should -BeTrue
        $data.Fallback | Should -Be $script:RepoVersion
    }
}

Describe 'Get-SwInstalledVersion' {
    Context 'Reading the VERSION file (V-1, V-2)' {
        It 'Trims CR LF from <Name> (V-1)' -ForEach @(
            @{ Name = 'crlf'; Content = "0.1.0`r`n"; Expected = '0.1.0' }
            @{ Name = 'lf'; Content = "1.2.3`n"; Expected = '1.2.3' }
            @{ Name = 'spaces and tabs'; Content = " `t 4.5.6 `t`r`n"; Expected = '4.5.6' }
            @{ Name = 'no line end'; Content = '7.8.9'; Expected = '7.8.9' }
        ) {
            $root = New-VersionRoot -Name "v1-$Name" -Content $Content
            Get-SwInstalledVersion -RootDir $root | Should -BeExactly $Expected
        }

        It 'Strips a UTF-8 BOM (V-1)' {
            $raw = [byte[]](@(0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::ASCII.GetBytes("1.2.3`n"))
            $root = New-VersionRoot -Name 'v1-bom' -Bytes -Raw $raw
            $result = Get-SwInstalledVersion -RootDir $root
            $result | Should -BeExactly '1.2.3'
            $result.Length | Should -Be 5
        }

        It 'Returns a string' {
            $root = New-VersionRoot -Name 'v1-type' -Content "2.0.0`r`n"
            (Get-SwInstalledVersion -RootDir $root) | Should -BeOfType [string]
        }

        It 'Does not validate the content (V-2)' {
            $root = New-VersionRoot -Name 'v2-beta' -Content "0.2.0-beta.1`r`n"
            Get-SwInstalledVersion -RootDir $root | Should -BeExactly '0.2.0-beta.1'
        }
    }

    Context 'Fallback (V-3, V-5)' {
        It 'Falls back to -DefaultVersion when RootDir is <Name> (V-3)' -ForEach @(
            @{ Name = 'empty'; Root = '' }
            @{ Name = 'null'; Root = $null }
            @{ Name = 'whitespace'; Root = "  `t " }
        ) {
            Get-SwInstalledVersion -RootDir $Root -DefaultVersion '9.9.9' | Should -BeExactly '9.9.9'
        }

        It 'Falls back when the folder does not exist (V-3)' {
            $root = Join-Path $TestDrive 'no-such-folder'
            Get-SwInstalledVersion -RootDir $root -DefaultVersion '9.9.8' | Should -BeExactly '9.9.8'
        }

        It 'Falls back when VERSION is missing (V-3)' {
            $root = New-VersionRoot -Name 'v3-missing' -Content $null
            Get-SwInstalledVersion -RootDir $root -DefaultVersion '9.9.7' | Should -BeExactly '9.9.7'
        }

        It 'Falls back when VERSION is <Name> (V-3)' -ForEach @(
            @{ Name = 'empty'; Content = '' }
            @{ Name = 'whitespace only'; Content = " `t`r`n  `n" }
        ) {
            $root = New-VersionRoot -Name "v3-$Name" -Content $Content
            Get-SwInstalledVersion -RootDir $root -DefaultVersion '9.9.6' | Should -BeExactly '9.9.6'
        }

        It 'Uses the built-in fallback version without -DefaultVersion (V-3)' {
            $root = New-VersionRoot -Name 'v3-builtin' -Content $null
            Get-SwInstalledVersion -RootDir $root | Should -BeExactly $script:SwFallbackVersion
        }

        It 'Keeps the built-in fallback equal to the repository VERSION (V-5)' {
            $script:SwFallbackVersion | Should -BeExactly $script:RepoVersion
            $root = New-VersionRoot -Name 'v5-empty-root' -Content $null
            Get-SwInstalledVersion -RootDir $root | Should -BeExactly $script:RepoVersion
        }

        It 'Reads the repository root like any other root' {
            Get-SwInstalledVersion -RootDir $script:RepoRoot | Should -BeExactly $script:RepoVersion
        }
    }

    Context 'Literal paths (V-4)' {
        It 'Reads VERSION from a folder named <Name> (V-4)' -ForEach @(
            @{ Name = '[USB] Sweepr' }
            @{ Name = '[ab]' }
            @{ Name = "it's" }
            @{ Name = ('Rock' + [char]0x2019 + 'n' + [char]0x2019 + 'Roll') }
            @{ Name = ([string][char]0x201A + 'x' + [char]0x201B + [char]0x2018) }
        ) {
            $root = New-VersionRoot -Name $Name -Content "1.4.0`r`n"
            Get-SwInstalledVersion -RootDir $root -DefaultVersion '0.0.1' | Should -BeExactly '1.4.0'
        }

        It 'Does not treat <Pattern> as a wildcard for a sibling folder (V-4)' -ForEach @(
            @{ Pattern = 'Swe?pr' }
            @{ Pattern = 'Swe*' }
            @{ Pattern = '[Ss]weepr' }
        ) {
            $parent = Join-Path $TestDrive ("v4-wild-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $parent 'Sweepr') -Force | Out-Null
            [System.IO.File]::WriteAllText([System.IO.Path]::Combine($parent, 'Sweepr', 'VERSION'), '2.0.0')
            $root = [System.IO.Path]::Combine($parent, $Pattern)
            Get-SwInstalledVersion -RootDir $root -DefaultVersion '0.0.2' | Should -BeExactly '0.0.2'
        }
    }

    Context 'Unreadable VERSION (V-6, L7-5)' {
        It 'Throws when VERSION is a folder' {
            $root = New-VersionRoot -Name 'v6-folder' -Content $null
            New-Item -ItemType Directory -Path ([System.IO.Path]::Combine($root, 'VERSION')) | Out-Null
            Get-Command Get-SwInstalledVersion -CommandType Function -ErrorAction Stop | Out-Null
            { Get-SwInstalledVersion -RootDir $root -DefaultVersion '0.0.3' } | Should -Throw
        }
    }
}

Describe 'Repair-SwModuleSearchPath' {
    It 'Removes pwsh 7 folders and keeps the rest in order (V-9, V-10, example 1)' {
        $in = 'C:\Users\Example\Documents\PowerShell\Modules;C:\Program Files\PowerShell\Modules;c:\program files\powershell\7\Modules;' +
            'C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.0.0_x64__8wekyb3d8bbwe\Modules;C:\Users\Example\Documents\WindowsPowerShell\Modules;' +
            'D:\Tools\Modules;C:\Program Files\WindowsPowerShell\Modules;C:\Windows\system32\WindowsPowerShell\v1.0\Modules\'
        $expected = 'C:\Users\Example\Documents\WindowsPowerShell\Modules;D:\Tools\Modules;C:\Program Files\WindowsPowerShell\Modules;' +
            'C:\Windows\system32\WindowsPowerShell\v1.0\Modules\'
        (Invoke-ModulePathRepair -ModulePath $in -Edition Desktop).Path | Should -BeExactly $expected
    }

    It 'Appends the Windows PowerShell system modules when missing (V-11, example 2)' {
        (Invoke-ModulePathRepair -ModulePath 'C:\Program Files\PowerShell\7\Modules;D:\Tools\Modules' -Edition Desktop).Path |
            Should -BeExactly "D:\Tools\Modules;$script:SystemModules"
    }

    It 'Leaves the path unchanged for edition Core (V-7, example 3)' {
        $in = 'C:\Program Files\PowerShell\7\Modules;D:\Tools\Modules'
        (Invoke-ModulePathRepair -ModulePath $in -Edition Core).Path | Should -BeExactly $in
    }

    It 'Drops empty and blank entries (V-9, example 4)' {
        (Invoke-ModulePathRepair -ModulePath 'D:\a;;  ;D:\b' -Edition Desktop).Path |
            Should -BeExactly "D:\a;D:\b;$script:SystemModules"
    }

    It 'Uses the edition of the running process by default (V-7)' {
        $in = 'C:\Program Files\PowerShell\7\Modules;D:\Tools\Modules'
        $expected = if ($PSVersionTable.PSEdition -eq 'Desktop') { "D:\Tools\Modules;$script:SystemModules" } else { $in }
        (Invoke-ModulePathRepair -ModulePath $in).Path | Should -BeExactly $expected
    }

    It 'Leaves an empty PSModulePath empty (V-8)' {
        $result = Invoke-ModulePathRepair -ModulePath '' -Edition Desktop
        $result.Path | Should -BeNullOrEmpty
    }

    It 'Keeps WindowsPowerShell and look-alike folders (V-9)' {
        $in = 'C:\Users\Example\Documents\WindowsPowerShell\Modules;D:\MyPowerShell\Modules;D:\PowerShellTools\Modules;D:\PowerShell.Old\Modules'
        (Invoke-ModulePathRepair -ModulePath $in -Edition Desktop).Path | Should -BeExactly "$in;$script:SystemModules"
    }

    It 'Matches the PowerShell folder without regard to case (V-9)' {
        $in = 'D:\POWERSHELL\Modules;D:\x\powershell\y;E:\Apps\microsoft.powershell_7.5.0.0_x64__abc\Modules;D:\Keep'
        (Invoke-ModulePathRepair -ModulePath $in -Edition Desktop).Path | Should -BeExactly "D:\Keep;$script:SystemModules"
    }

    It 'Keeps the spelling of kept entries including a trailing backslash (V-10)' {
        $in = 'd:\Tools\MODULES\;E:\Other\Modules'
        (Invoke-ModulePathRepair -ModulePath $in -Edition Desktop).Path | Should -BeExactly "$in;$script:SystemModules"
    }

    It 'Does not append the system modules a second time when present as <Name> (V-11)' -ForEach @(
        @{ Name = 'lower case'; Entry = 'c:\windows\system32\windowspowershell\v1.0\modules' }
        @{ Name = 'trailing backslash'; Entry = 'C:\Windows\System32\WindowsPowerShell\v1.0\Modules\' }
        @{ Name = 'exact'; Entry = 'C:\Windows\System32\WindowsPowerShell\v1.0\Modules' }
    ) {
        $in = "$Entry;D:\Tools\Modules"
        (Invoke-ModulePathRepair -ModulePath $in -Edition Desktop).Path | Should -BeExactly $in
    }

    It 'Builds the appended entry from SystemRoot without a trailing backslash (V-11)' {
        (Invoke-ModulePathRepair -ModulePath 'D:\Tools' -SystemRoot 'E:\WinDir\' -Edition Desktop).Path |
            Should -BeExactly 'D:\Tools;E:\WinDir\System32\WindowsPowerShell\v1.0\Modules'
    }

    It 'Uses C:\Windows when SystemRoot is missing (L7-5)' {
        (Invoke-ModulePathRepair -ModulePath 'D:\Tools' -SystemRoot $null -Edition Desktop).Path |
            Should -BeExactly "D:\Tools;$script:SystemModules"
    }

    It 'Returns nothing and writes nothing to the host (spec 2.2)' {
        $savedPath = $env:PSModulePath
        $savedRoot = $env:SystemRoot
        try {
            $env:PSModulePath = 'C:\Program Files\PowerShell\7\Modules;D:\Tools'
            $env:SystemRoot = 'C:\Windows'
            $records = @(Repair-SwModuleSearchPath -Edition Desktop *>&1)
        }
        finally {
            $env:PSModulePath = $savedPath
            $env:SystemRoot = $savedRoot
        }
        $records.Count | Should -Be 0
    }

    It 'Changes only the current process, never the user or machine value (V-12)' {
        $before = @{}
        foreach ($target in 'User', 'Machine') {
            $before[$target] = try { [Environment]::GetEnvironmentVariable('PSModulePath', $target) } catch { '<unavailable>' }
        }
        $null = Invoke-ModulePathRepair -ModulePath 'C:\Program Files\PowerShell\7\Modules;D:\Tools' -Edition Desktop
        foreach ($target in 'User', 'Machine') {
            $after = try { [Environment]::GetEnvironmentVariable('PSModulePath', $target) } catch { '<unavailable>' }
            $after | Should -Be $before[$target]
        }
    }
}

Describe 'Sw version transition names (L7-1)' {
    It 'Keeps <Name> as a function, not an alias' -ForEach @(
        @{ Name = 'Get-SweeprVersionString' }
        @{ Name = 'Repair-SweeprModulePath' }
    ) {
        $command = Get-Command -Name $Name -ErrorAction Stop
        $command.CommandType | Should -Be 'Function'
        Get-Alias -Name $Name -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'Get-SweeprVersionString gives the same results as Get-SwInstalledVersion' {
        $root = New-VersionRoot -Name 'old-name' -Content "3.2.1`r`n"
        Get-SweeprVersionString -RootDir $root | Should -BeExactly '3.2.1'
        $missing = Join-Path $TestDrive 'old-name-missing'
        Get-SweeprVersionString -RootDir $missing -DefaultVersion '5.5.5' | Should -BeExactly '5.5.5'
        Get-SweeprVersionString -RootDir $missing | Should -BeExactly (Get-SwInstalledVersion -RootDir $missing)
    }

    It 'Get-SweeprVersionString forwards to Get-SwInstalledVersion' {
        Mock Get-SwInstalledVersion { 'forwarded' }
        Get-SweeprVersionString -RootDir 'X:\Example' -DefaultVersion '1.1.1' | Should -BeExactly 'forwarded'
        Should -Invoke Get-SwInstalledVersion -Times 1 -Exactly -ParameterFilter { $RootDir -eq 'X:\Example' -and $DefaultVersion -eq '1.1.1' }
    }

    It 'Repair-SweeprModulePath gives the same result as Repair-SwModuleSearchPath for <Edition>' -ForEach @(
        @{ Edition = 'Desktop' }
        @{ Edition = 'Core' }
    ) {
        $in = 'C:\Program Files\PowerShell\7\Modules;D:\a;;D:\b'
        $old = Invoke-ModulePathRepair -ModulePath $in -Edition $Edition -Command 'Repair-SweeprModulePath'
        $new = Invoke-ModulePathRepair -ModulePath $in -Edition $Edition
        $old.Path | Should -BeExactly $new.Path
    }

    It 'Repair-SweeprModulePath forwards to Repair-SwModuleSearchPath' {
        Mock Repair-SwModuleSearchPath { }
        Repair-SweeprModulePath -Edition Core
        Should -Invoke Repair-SwModuleSearchPath -Times 1 -Exactly -ParameterFilter { $Edition -eq 'Core' }
    }
}
