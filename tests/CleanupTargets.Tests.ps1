# Cleanup target selection must preserve stores and Explorer presentation state.
BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    . "$root\lib\clean\user.ps1"
    . "$root\lib\clean\caches.ps1"
    . "$root\lib\clean\system.ps1"
    function Clear-Prefetch {}
    $script:SavedAppData = $env:APPDATA
    $script:SavedLocalAppData = $env:LOCALAPPDATA
    $env:APPDATA = Join-Path $TestDrive 'Roaming'
    $env:LOCALAPPDATA = Join-Path $TestDrive 'Local'
    foreach ($leaf in @('Cache', 'GPUCache', 'blob_storage', 'tmp')) {
        New-Item -ItemType Directory -Path "$env:APPDATA\Microsoft\Teams\$leaf" -Force | Out-Null
    }
    New-Item -ItemType Directory -Path "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" -Force | Out-Null
    Set-Content "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_32.db" 'fixture'
    Set-Content "$env:LOCALAPPDATA\IconCache.db" 'fixture'
}

AfterAll {
    $env:APPDATA = $script:SavedAppData
    $env:LOCALAPPDATA = $script:SavedLocalAppData
}

Describe 'Conservative cleanup targets' {
    BeforeEach {
        Mock Clear-SwAppCache {}
        Mock Clear-SwDirectoryContents {}
        Mock Remove-SwItems {}
        Mock Remove-SwItem { $true }
        Mock Clear-SwUserTempFiles {}
        Mock Clear-SwErrorReports {}
        Mock Clear-SwUserLogs {}
        Mock Clear-Prefetch {}
        $script:AppData = $env:APPDATA.Replace('\', '/')
    }

    # Paths are compared with forward slashes, so the same check holds where the separator is a backslash.
    It 'Keeps Teams <Leaf> while still cleaning its exact cache leaves' -TestCases @(
        @{ Leaf = 'blob_storage' }
        @{ Leaf = 'tmp' }
    ) {
        param($Leaf)
        Clear-SwAppCaches
        Should -Invoke Clear-SwAppCache -Times 0 -Exactly -ParameterFilter { $Path.Replace('\', '/') -eq "$script:AppData/Microsoft/Teams/$Leaf" }
        Should -Invoke Clear-SwAppCache -Times 1 -Exactly -ParameterFilter { $Path.Replace('\', '/') -eq "$script:AppData/Microsoft/Teams/Cache" }
        Should -Invoke Clear-SwAppCache -Times 1 -Exactly -ParameterFilter { $Path.Replace('\', '/') -eq "$script:AppData/Microsoft/Teams/GPUCache" }
    }

    It 'Keeps Spotify offline stores during automatic cleanup' {
        foreach ($leaf in @('Data', 'Storage')) {
            New-Item -ItemType Directory -Path "$env:LOCALAPPDATA\Spotify\$leaf" -Force | Out-Null
        }
        Clear-SwAppCaches
        Should -Invoke Clear-SwAppCache -Times 0 -Exactly -ParameterFilter { $Path -like '*Spotify*' }
        Should -Invoke Clear-SwDirectoryContents -Times 0 -Exactly -ParameterFilter { $Path -like '*Spotify*' }
        Should -Invoke Clear-SwAppCache -Times 1 -Exactly -ParameterFilter { $Path.Replace('\', '/') -eq "$script:AppData/Microsoft/Teams/Cache" }
    }
    It 'Leaves Adobe caches to the Applications section so a run counts them once' {
        foreach ($dir in @("$env:APPDATA\Adobe\Common\Media Cache Files", "$env:LOCALAPPDATA\Adobe\Premiere\Cache")) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Clear-SwAppCaches
        Should -Invoke Clear-SwDirectoryContents -Times 0 -Exactly -ParameterFilter { $Description -eq 'Adobe cache' }
        Should -Invoke Clear-SwAppCache -Times 0 -Exactly -ParameterFilter { $Description -eq 'Adobe cache' }
    }
    It 'Keeps Explorer thumbnails and icons during ordinary user cleanup' {
        Invoke-SwUserCleanup
        Should -Invoke Clear-SwUserTempFiles -Times 1 -Exactly
        Should -Invoke Clear-Prefetch -Times 0 -Exactly
        Should -Invoke Remove-SwItems -Times 0 -Exactly
        Should -Invoke Remove-SwItem -Times 0 -Exactly
    }
}


Describe 'Protected system cleanup does not disturb services' {
    BeforeAll {
        # Windows-only commands get a stub so that Pester can mock them everywhere.
        foreach ($name in @('Get-Service', 'Start-Service', 'Stop-Service', 'Restart-Service', 'Set-Service')) {
            if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { Set-Item -Path "function:script:$name" -Value { param() } }
        }
    }
    BeforeEach {
        Mock Test-SwAdmin { $true }
        Mock Test-SwDryRunMode { $false }
        Mock Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Mock Stop-Service {}
        Mock Start-Service {}
        Mock Restart-Service {}
        Mock Set-Service {}
        Mock Clear-SwDirectoryContents {}
        Mock Remove-SwOldFiles {}
        Mock Remove-SwItems {}
        Mock Remove-SwItem { $true }
        Mock Start-Process {}
    }
    It 'Never stops, starts or restarts FontCache or Windows Update during system cleanup' {
        Invoke-SwSystemCleanup
        Should -Invoke Stop-Service -Times 0 -Exactly
        Should -Invoke Start-Service -Times 0 -Exactly
        Should -Invoke Restart-Service -Times 0 -Exactly
        Should -Invoke Set-Service -Times 0 -Exactly
    }
}

Describe 'Game media scope' {
    BeforeAll { . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/clean/apps.ps1') }
    It 'Keeps generic captures while still selecting old game captures' {
        $savedProfile = $env:USERPROFILE
        $savedPrograms = ${env:ProgramFiles(x86)}
        try {
            $env:USERPROFILE = Join-Path $TestDrive 'media-profile'
            ${env:ProgramFiles(x86)} = Join-Path $TestDrive 'media-programs'
            $videos = Join-Path $env:USERPROFILE 'Videos'
            # General capture folders hold the user's own recordings and are never chosen, whatever
            # their age; only the folders a capture program creates itself are in scope.
            $paths = @(
                (Join-Path (Join-Path $env:USERPROFILE 'Pictures') (Join-Path 'Screenshots' 'receipt.png')),
                (Join-Path $videos (Join-Path 'Screen Recordings' 'training.mp4')),
                (Join-Path $videos (Join-Path 'Captures' 'game.mp4')),
                (Join-Path $videos (Join-Path 'NVIDIA' 'game.mp4')),
                (Join-Path $videos (Join-Path 'NVIDIA' 'recent.mp4'))
            )
            foreach ($path in $paths) {
                New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
                Set-Content -LiteralPath $path -Value 'fixture'
                [System.IO.File]::SetCreationTime($path, [datetime]::Now.AddDays(-100))
                [System.IO.File]::SetLastWriteTime($path, [datetime]::Now.AddDays(-100))
            }
            $script:GamePath = $paths[3]
            [System.IO.File]::SetLastWriteTime($paths[4], [datetime]::Now)
            Mock Start-SwSection {}
            Mock Stop-SwSection {}
            Mock Remove-SwItems {}
            Clear-SwGameMedia -DaysOld 90
            Should -Invoke Remove-SwItems -Exactly -Times 0 -ParameterFilter { @($Paths | Where-Object { $_ -like '*Screenshots?*' -or $_ -like '*Screen Recordings?*' -or $_ -like '*Captures?*' }).Count -gt 0 }
            Should -Invoke Remove-SwItems -Exactly -Times 1 -ParameterFilter { @($Paths).Count -eq 1 -and @($Paths)[0] -eq $script:GamePath }
            Should -Invoke Remove-SwItems -Exactly -Times 1
        }
        finally { $env:USERPROFILE = $savedProfile; ${env:ProgramFiles(x86)} = $savedPrograms }
    }
}
