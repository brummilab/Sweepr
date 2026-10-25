# Sweepr - the active data folder is protected from Sweepr's own cleanup (F-01i)
# A data folder (profile, portable <Root>\data or SWEEPR_DATA_DIR) can sit below a
# cleanup target, e.g. an override below the temp folder. Config.ConfigPath and
# Config.CachePath must then count as protected like a literal whitelist directory:
# descendants covered, no prefix siblings, brackets literal.
# The first Describe is platform neutral (Windows-style strings only, no filesystem).
# The deletion Describe blocks need Windows path rules and only touch TestDrive.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    . "$script:RepoRoot\lib\core\base.ps1"
    . "$script:RepoRoot\lib\core\log.ps1"
    . "$script:RepoRoot\lib\core\file_ops.ps1"
    $script:SavedConfigPath = $script:Config.ConfigPath
    $script:SavedCachePath = $script:Config.CachePath
    $script:SavedWhitelistFile = $script:Config.WhitelistFile
}

AfterAll {
    $script:Config.ConfigPath = $script:SavedConfigPath
    $script:Config.CachePath = $script:SavedCachePath
    $script:Config.WhitelistFile = $script:SavedWhitelistFile
    Set-DryRunMode -Enabled $true
}

Describe 'Data folder protection in the whitelist state' {
    BeforeEach {
        $script:Config.ConfigPath = 'C:\Scratch\Example\data'
        $script:Config.CachePath = 'C:\Scratch\Example\cache'
        # No whitelist file (absent is empty): the protection must not depend on a user rule.
        $script:Config.WhitelistFile = Join-Path $TestDrive 'absent-whitelist.txt'
    }

    AfterEach {
        $script:Config.ConfigPath = $script:SavedConfigPath
        $script:Config.CachePath = $script:SavedCachePath
        $script:Config.WhitelistFile = $script:SavedWhitelistFile
    }

    It 'Protects the config folder itself and its descendants' {
        Test-Whitelisted -Path 'C:\Scratch\Example\data' | Should -BeTrue
        Test-Whitelisted -Path 'C:\Scratch\Example\data\' | Should -BeTrue
        Test-Whitelisted -Path 'C:\Scratch\Example\data\whitelist.txt' | Should -BeTrue
        Test-Whitelisted -Path 'C:\Scratch\Example\data\nested\operations.log' | Should -BeTrue
    }

    It 'Protects the cache folder itself and its descendants' {
        Test-Whitelisted -Path 'C:\Scratch\Example\cache' | Should -BeTrue
        Test-Whitelisted -Path 'C:\Scratch\Example\cache\update-check.json' | Should -BeTrue
        Test-Whitelisted -Path 'C:\Scratch\Example\cache\a\b\c.bin' | Should -BeTrue
    }

    It 'Compares case-insensitively like every other protected path' {
        Test-Whitelisted -Path 'c:\scratch\EXAMPLE\DATA\Whitelist.txt' | Should -BeTrue
        Test-Whitelisted -Path 'C:\SCRATCH\example\Cache\x' | Should -BeTrue
    }

    It 'Does not protect prefix siblings or the parent folder' {
        Test-Whitelisted -Path 'C:\Scratch\Example\data2' | Should -BeFalse
        Test-Whitelisted -Path 'C:\Scratch\Example\data2\file.tmp' | Should -BeFalse
        Test-Whitelisted -Path 'C:\Scratch\Example\data-old\file.tmp' | Should -BeFalse
        Test-Whitelisted -Path 'C:\Scratch\Example\cache2\file.tmp' | Should -BeFalse
        Test-Whitelisted -Path 'C:\Scratch\Example' | Should -BeFalse
        Test-Whitelisted -Path 'C:\Scratch\Example\other.tmp' | Should -BeFalse
    }

    It 'Reads brackets in the data folder name literally' {
        $script:Config.ConfigPath = 'C:\Scratch\Example\[x]\data'
        $script:Config.CachePath = 'C:\Scratch\Example\[x]\cache'
        Test-Whitelisted -Path 'C:\Scratch\Example\[x]\data\whitelist.txt' | Should -BeTrue
        Test-Whitelisted -Path 'C:\Scratch\Example\[x]\cache\item' | Should -BeTrue
        # As a wildcard [x] would match the folder named "x"; it must not.
        Test-Whitelisted -Path 'C:\Scratch\Example\x\data\whitelist.txt' | Should -BeFalse
        Test-Whitelisted -Path 'C:\Scratch\Example\x\cache\item' | Should -BeFalse
    }

    It 'Reads wildcard characters in the data folder name literally' {
        $script:Config.ConfigPath = 'C:\Scratch\Example\d*ta'
        Test-Whitelisted -Path 'C:\Scratch\Example\d*ta\whitelist.txt' | Should -BeTrue
        Test-Whitelisted -Path 'C:\Scratch\Example\data\whitelist.txt' | Should -BeFalse
    }

    It 'Exposes the protection through a state read once and passed on' {
        $state = Get-WhitelistState
        Test-Whitelisted -Path 'C:\Scratch\Example\data\whitelist.txt' -State $state | Should -BeTrue
        Test-Whitelisted -Path 'C:\Scratch\Example\cache\x' -State $state | Should -BeTrue
        Test-Whitelisted -Path 'C:\Scratch\Example\data2\x' -State $state | Should -BeFalse
    }

    It 'Follows the active paths instead of a value cached at load time' {
        $script:Config.ConfigPath = 'C:\Scratch\Example\moved'
        Test-Whitelisted -Path 'C:\Scratch\Example\moved\whitelist.txt' | Should -BeTrue
        Test-Whitelisted -Path 'C:\Scratch\Example\data\whitelist.txt' | Should -BeFalse
    }

    It 'Ignores an empty path setting instead of protecting or exposing everything' {
        $script:Config.ConfigPath = ''
        $script:Config.CachePath = $null
        { Get-WhitelistState } | Should -Not -Throw
        Test-Whitelisted -Path 'C:\Scratch\Example\other.tmp' | Should -BeFalse
        Test-Whitelisted -Path 'C:\' | Should -BeFalse
    }

    It 'Keeps user whitelist rules working next to the data folder rule' {
        $script:RulesRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:RulesRoot | Out-Null
        $script:Config.WhitelistFile = Join-Path $script:RulesRoot 'whitelist.txt'
        Set-Content -LiteralPath $script:Config.WhitelistFile -Value 'C:\Scratch\Example\keep-me'
        Test-Whitelisted -Path 'C:\Scratch\Example\keep-me\file' | Should -BeTrue
        Test-Whitelisted -Path 'C:\Scratch\Example\data\file' | Should -BeTrue
        Test-Whitelisted -Path 'C:\Scratch\Example\keep-me-not\file' | Should -BeFalse
    }
}

Describe 'Data folder below a cleanup target' {
    BeforeEach {
        $script:Case = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        # Simulated cleanup target (think of a temp folder) with the override data folder inside.
        $script:Target = Join-Path $script:Case 'Temp'
        $script:Data = Join-Path $script:Target 'data'
        $script:Cache = Join-Path $script:Target 'cache'
        $script:Sibling = Join-Path $script:Target 'data2'
        New-Item -ItemType Directory -Path $script:Data, $script:Cache, $script:Sibling -Force | Out-Null
        $script:DataFile = Join-Path $script:Data 'whitelist.txt'
        $script:LogFile = Join-Path $script:Data 'operations.log'
        $script:CacheFile = Join-Path $script:Cache 'update-check.json'
        $script:SiblingFile = Join-Path $script:Sibling 'junk.tmp'
        $script:LooseFile = Join-Path $script:Target 'loose.tmp'
        foreach ($file in $script:DataFile, $script:LogFile, $script:CacheFile, $script:SiblingFile, $script:LooseFile) {
            Set-Content -LiteralPath $file -Value 'x'
            (Get-Item -LiteralPath $file).LastWriteTime = (Get-Date).AddDays(-30)
        }
        $script:Config.ConfigPath = $script:Data
        $script:Config.CachePath = $script:Cache
        # The user whitelist lives elsewhere and is empty: only the data folder rule can protect.
        $script:Config.WhitelistFile = Join-Path $script:Case 'elsewhere-whitelist.txt'
        Set-DryRunMode -Enabled $false
    }

    AfterEach {
        $script:Config.ConfigPath = $script:SavedConfigPath
        $script:Config.CachePath = $script:SavedCachePath
        $script:Config.WhitelistFile = $script:SavedWhitelistFile
        Set-DryRunMode -Enabled $true
    }

    It 'Reports Test-SafePath false for the data and cache folders and their files' {
        Test-SafePath -Path $script:DataFile | Should -BeFalse
        Test-SafePath -Path $script:LogFile | Should -BeFalse
        Test-SafePath -Path $script:Data | Should -BeFalse
        Test-SafePath -Path $script:CacheFile | Should -BeFalse
        Test-SafePath -Path $script:Cache | Should -BeFalse
    }

    It 'Keeps Test-SafePath true for a prefix sibling and a loose file' {
        Test-SafePath -Path $script:SiblingFile | Should -BeTrue
        Test-SafePath -Path $script:Sibling | Should -BeTrue
        Test-SafePath -Path $script:LooseFile | Should -BeTrue
    }

    It 'Remove-SafeItem keeps a file inside the data folder' {
        Remove-SafeItem -Path $script:DataFile -Force | Should -BeFalse
        Remove-SafeItem -Path $script:LogFile -Force | Should -BeFalse
        Test-Path -LiteralPath $script:DataFile | Should -BeTrue
        Test-Path -LiteralPath $script:LogFile | Should -BeTrue
    }

    It 'Remove-SafeItem keeps the data and cache folders when asked to remove them' {
        Remove-SafeItem -Path $script:Data -Recurse -Force | Should -BeFalse
        Remove-SafeItem -Path $script:Cache -Recurse -Force | Should -BeFalse
        Test-Path -LiteralPath $script:DataFile | Should -BeTrue
        Test-Path -LiteralPath $script:CacheFile | Should -BeTrue
    }

    It 'Remove-SafeItem refuses the whole cleanup target that contains the data folder' {
        Remove-SafeItem -Path $script:Target -Recurse -Force | Should -BeFalse
        Test-Path -LiteralPath $script:DataFile | Should -BeTrue
        Test-Path -LiteralPath $script:CacheFile | Should -BeTrue
        Test-Path -LiteralPath $script:SiblingFile | Should -BeTrue
    }

    It 'Remove-SafeItem still removes a prefix sibling of the data folder' {
        Remove-SafeItem -Path $script:SiblingFile -Force | Should -BeTrue
        Test-Path -LiteralPath $script:SiblingFile | Should -BeFalse
        Test-Path -LiteralPath $script:DataFile | Should -BeTrue
    }

    It 'Remove-SafeItems keeps data and cache files and removes the rest of a batch' {
        Remove-SafeItems -Paths @($script:DataFile, $script:LogFile, $script:CacheFile, $script:SiblingFile, $script:LooseFile) -Description 'Mixed batch'
        Test-Path -LiteralPath $script:DataFile | Should -BeTrue
        Test-Path -LiteralPath $script:LogFile | Should -BeTrue
        Test-Path -LiteralPath $script:CacheFile | Should -BeTrue
        Test-Path -LiteralPath $script:SiblingFile | Should -BeFalse
        Test-Path -LiteralPath $script:LooseFile | Should -BeFalse
    }

    It 'Remove-OldFiles keeps old files inside the data folder' {
        Remove-OldFiles -Path $script:Data -DaysOld 7 -Description 'Old data'
        Remove-OldFiles -Path $script:Cache -DaysOld 7 -Description 'Old cache'
        Test-Path -LiteralPath $script:DataFile | Should -BeTrue
        Test-Path -LiteralPath $script:LogFile | Should -BeTrue
        Test-Path -LiteralPath $script:CacheFile | Should -BeTrue
    }

    It 'Remove-OldFiles still removes old files in the cleanup target itself' {
        Remove-OldFiles -Path $script:Target -DaysOld 7 -Description 'Old temp'
        Test-Path -LiteralPath $script:LooseFile | Should -BeFalse
        Test-Path -LiteralPath $script:DataFile | Should -BeTrue
        Test-Path -LiteralPath $script:CacheFile | Should -BeTrue
    }

    It 'Clear-DirectoryContents keeps the data folder when clearing its parent' {
        Clear-DirectoryContents -Path $script:Target -Description 'Temp'
        Test-Path -LiteralPath $script:DataFile | Should -BeTrue
        Test-Path -LiteralPath $script:LogFile | Should -BeTrue
        Test-Path -LiteralPath $script:CacheFile | Should -BeTrue
        Test-Path -LiteralPath $script:Data -PathType Container | Should -BeTrue
    }

    It 'Clear-DirectoryContents does not clear the data folder itself' {
        Clear-DirectoryContents -Path $script:Data -Description 'Data'
        Clear-DirectoryContents -Path $script:Cache -Description 'Cache'
        Test-Path -LiteralPath $script:DataFile | Should -BeTrue
        Test-Path -LiteralPath $script:LogFile | Should -BeTrue
        Test-Path -LiteralPath $script:CacheFile | Should -BeTrue
    }

    It 'Clear-DirectoryContents still clears a prefix sibling of the data folder' {
        Clear-DirectoryContents -Path $script:Sibling -Description 'Sibling'
        Test-Path -LiteralPath $script:SiblingFile | Should -BeFalse
        Test-Path -LiteralPath $script:Data -PathType Container | Should -BeTrue
    }
}

Describe 'Data folder protection in dry run' {
    BeforeEach {
        $script:Case = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Target = Join-Path $script:Case 'Temp'
        $script:Data = Join-Path $script:Target 'data'
        $script:Sibling = Join-Path $script:Target 'data2'
        New-Item -ItemType Directory -Path $script:Data, $script:Sibling -Force | Out-Null
        $script:DataFile = Join-Path $script:Data 'operations.log'
        $script:SiblingFile = Join-Path $script:Sibling 'junk.tmp'
        foreach ($file in $script:DataFile, $script:SiblingFile) {
            Set-Content -LiteralPath $file -Value 'x'
            (Get-Item -LiteralPath $file).LastWriteTime = (Get-Date).AddDays(-30)
        }
        $script:Config.ConfigPath = $script:Data
        $script:Config.CachePath = Join-Path $script:Target 'cache'
        $script:Config.WhitelistFile = Join-Path $script:Case 'elsewhere-whitelist.txt'
        Set-DryRunMode -Enabled $true
        Mock Write-DryRun { }
        $script:FilesCleaned = 0
        $script:TotalItems = 0
    }

    AfterEach {
        $script:Config.ConfigPath = $script:SavedConfigPath
        $script:Config.CachePath = $script:SavedCachePath
        $script:Config.WhitelistFile = $script:SavedWhitelistFile
        Set-DryRunMode -Enabled $true
    }

    It 'Remove-SafeItem reports a data folder file as protected and counts nothing' {
        Remove-SafeItem -Path $script:DataFile -Force | Should -BeFalse
        Should -Invoke Write-DryRun -Times 0 -Exactly -Scope It
        $script:FilesCleaned | Should -Be 0
        Test-Path -LiteralPath $script:DataFile | Should -BeTrue
    }

    It 'Remove-SafeItems leaves the data folder file out of the dry-run list' {
        Remove-SafeItems -Paths @($script:DataFile) -Description 'Data only'
        Should -Invoke Write-DryRun -Times 0 -Exactly -Scope It
        $script:FilesCleaned | Should -Be 0
    }

    It 'Remove-SafeItems still lists a prefix sibling in dry run and removes nothing' {
        Remove-SafeItems -Paths @($script:DataFile, $script:SiblingFile) -Description 'Mixed'
        Should -Invoke Write-DryRun -Times 1 -Exactly -Scope It
        $script:FilesCleaned | Should -Be 1
        Test-Path -LiteralPath $script:DataFile | Should -BeTrue
        Test-Path -LiteralPath $script:SiblingFile | Should -BeTrue
    }

    It 'Clear-DirectoryContents on the parent does not count the data folder in dry run' {
        Clear-DirectoryContents -Path $script:Target -Description 'Temp'
        $script:FilesCleaned | Should -Be 1
        Test-Path -LiteralPath $script:DataFile | Should -BeTrue
        Test-Path -LiteralPath $script:SiblingFile | Should -BeTrue
    }
}

Describe 'Data folder with brackets in its name' {
    BeforeEach {
        $script:Case = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Target = Join-Path $script:Case 'Temp'
        $script:Data = Join-Path $script:Target '[x] data'
        $script:Decoy = Join-Path $script:Target 'x data'
        New-Item -ItemType Directory -Path $script:Data, $script:Decoy -Force | Out-Null
        $script:DataFile = Join-Path $script:Data 'whitelist.txt'
        $script:DecoyFile = Join-Path $script:Decoy 'junk.tmp'
        foreach ($file in $script:DataFile, $script:DecoyFile) { Set-Content -LiteralPath $file -Value 'x' }
        $script:Config.ConfigPath = $script:Data
        $script:Config.CachePath = Join-Path $script:Data 'cache'
        $script:Config.WhitelistFile = Join-Path $script:Case 'elsewhere-whitelist.txt'
        Set-DryRunMode -Enabled $false
    }

    AfterEach {
        $script:Config.ConfigPath = $script:SavedConfigPath
        $script:Config.CachePath = $script:SavedCachePath
        $script:Config.WhitelistFile = $script:SavedWhitelistFile
        Set-DryRunMode -Enabled $true
    }

    It 'Keeps files in a folder named with brackets' {
        Remove-SafeItem -Path $script:DataFile -Force | Should -BeFalse
        Clear-DirectoryContents -Path $script:Target -Description 'Temp'
        Test-Path -LiteralPath $script:DataFile | Should -BeTrue
    }

    It 'Does not let the bracket name act as a wildcard that protects a lookalike folder' {
        Remove-SafeItem -Path $script:DecoyFile -Force | Should -BeTrue
        Test-Path -LiteralPath $script:DecoyFile | Should -BeFalse
    }
}

Describe 'Profile mode stays unchanged' {
    BeforeEach {
        $script:Case = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:UserHome = Join-Path $script:Case 'home'
        $script:Config.ConfigPath = Join-Path $script:UserHome '.config\sweepr'
        $script:Config.CachePath = Join-Path $script:UserHome '.cache\sweepr'
        $script:Config.WhitelistFile = Join-Path $script:Config.ConfigPath 'whitelist.txt'
        $script:TempDir = Join-Path $script:UserHome 'AppData\Local\Temp'
        New-Item -ItemType Directory -Path $script:TempDir, $script:Config.ConfigPath, $script:Config.CachePath -Force | Out-Null
        $script:TempFile = Join-Path $script:TempDir 'junk.tmp'
        $script:ConfigFile = Join-Path $script:Config.ConfigPath 'operations.log'
        $script:CacheFile = Join-Path $script:Config.CachePath 'update-check.json'
        foreach ($file in $script:TempFile, $script:ConfigFile, $script:CacheFile) { Set-Content -LiteralPath $file -Value 'x' }
        Set-DryRunMode -Enabled $false
    }

    AfterEach {
        $script:Config.ConfigPath = $script:SavedConfigPath
        $script:Config.CachePath = $script:SavedCachePath
        $script:Config.WhitelistFile = $script:SavedWhitelistFile
        Set-DryRunMode -Enabled $true
    }

    It 'Still cleans an ordinary temp folder that is not the data folder' {
        Clear-DirectoryContents -Path $script:TempDir -Description 'Temp'
        Test-Path -LiteralPath $script:TempFile | Should -BeFalse
    }

    It 'Protects the profile data and cache folders the same way' {
        Test-Whitelisted -Path $script:ConfigFile | Should -BeTrue
        Test-Whitelisted -Path $script:CacheFile | Should -BeTrue
        Remove-SafeItem -Path $script:ConfigFile -Force | Should -BeFalse
        Test-Path -LiteralPath $script:ConfigFile | Should -BeTrue
        Test-Path -LiteralPath $script:CacheFile | Should -BeTrue
    }
}
