# Only entrypoint functions run here; all maintenance work is mocked.
BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    # The command script defines Invoke-SwCleanMain and Start-SwCleanRun; dot-sourcing it runs nothing.
    # It comes first so that the stubs below win over the modules it loads.
    . (Join-Path $script:Root 'bin\clean.ps1')
    $script:SavedGuard = $script:SweeprCleanPathGuard
    function Import-EntryMain([string]$Name) {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root "bin\$Name.ps1"),[ref]$null,[ref]$null)
        $definition = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Main'},$true)
        Set-Item function:script:Main ([scriptblock]::Create($definition.Body.Extent.Text.TrimStart('{').TrimEnd('}')))
    }
    function Get-SystemHealth { @{} }
    function Start-Spinner { param($Message) }
    function Stop-Spinner {}
    function Show-SystemHealth { param($Health) }
    function Optimize-DiskDrive {}
    function Clear-DnsCache {}
    function Optimize-Network {}
    function Get-StartupPrograms {}
    function Test-DiskHealth { $true }
    function Test-WindowsUpdate {}
    function Test-SystemImage {}
    function Test-IsAdmin { $false }
    function Show-OptimizeSummary {}
}
Describe 'Environment dry-run at command entrypoints' {
    BeforeEach {
        $script:SavedDryRun=$env:SWEEPR_DRY_RUN
        $DebugMode=$false; $ShowHelp=$false; $Whitelist=$false; $System=$false; $GameMedia=$false; $GpuShaders=$false
        $script:Icons=@{DryRun='preview'}
        Mock Clear-Host {}
    }
    AfterEach { $env:SWEEPR_DRY_RUN=$script:SavedDryRun }
    AfterAll { $script:SweeprCleanPathGuard = $script:SavedGuard }
    It 'Keeps environment-only clean in preview mode' {
        $DryRun=$false; $env:SWEEPR_DRY_RUN='1'
        Mock Start-SwCleanRun {}
        Invoke-SwCleanMain -DryRun $DryRun -GpuShaders $GpuShaders
        Should -Invoke Start-SwCleanRun -Times 1 -Exactly -ParameterFilter { $IsDryRun }
        $env:SWEEPR_DRY_RUN | Should -Be '1'
    }
    It 'Keeps explicit clean preview when the environment says zero' {
        $DryRun=$true; $env:SWEEPR_DRY_RUN='0'
        Mock Start-SwCleanRun {}
        Invoke-SwCleanMain -DryRun $DryRun -GpuShaders $GpuShaders
        Should -Invoke Start-SwCleanRun -Times 1 -Exactly -ParameterFilter { $IsDryRun }
    }
    It 'Keeps ordinary clean outside preview' {
        $DryRun=$false; $env:SWEEPR_DRY_RUN=$null
        Mock Start-SwCleanRun {}
        Invoke-SwCleanMain -DryRun $DryRun -GpuShaders $GpuShaders
        Should -Invoke Start-SwCleanRun -Times 1 -Exactly -ParameterFilter { -not $IsDryRun }
    }
    It 'Passes GPU shader caches through only when asked' {
        $DryRun=$true; $env:SWEEPR_DRY_RUN=$null
        Mock Start-SwCleanRun {}
        Invoke-SwCleanMain -DryRun $DryRun -GpuShaders $GpuShaders
        Should -Invoke Start-SwCleanRun -Times 1 -Exactly -ParameterFilter { -not $IncludeGpuShaders }
        $GpuShaders=$true
        Invoke-SwCleanMain -DryRun $DryRun -GpuShaders $GpuShaders
        Should -Invoke Start-SwCleanRun -Times 1 -Exactly -ParameterFilter { $IncludeGpuShaders }
    }
    It 'Keeps environment-only optimize in preview mode' {
        Import-EntryMain optimize
        $DryRun=$false; $env:SWEEPR_DRY_RUN='1'
        Mock Optimize-DiskDrive { $script:ObservedDryRun=$script:DryRun }
        Main 6>$null
        $script:ObservedDryRun | Should -BeTrue
    }
}
Describe 'GPU shader caches wait for --gpu-shaders' {
    BeforeAll { $script:SavedDryRunMode = Test-SwDryRunMode }
    AfterAll {
        $script:SweeprCleanPathGuard = $script:SavedGuard
        Set-SwDryRunMode -Enabled $script:SavedDryRunMode
    }
    BeforeEach {
        Mock Clear-Host {}
        Mock Test-SwOutputRedirected { $false }
        Mock Get-SwWindowsVersion { @{ Name = 'Windows' } }
        Mock Show-SwCleanSummary {}
        Mock Clear-SwGpuShaderCaches {}
        Mock Invoke-SwUserCleanup {}
        Mock Clear-SwBrowserCaches {}
        Mock Clear-SwAppCaches {}
        Mock Invoke-DevToolsCleanup {}
        Mock Invoke-AppCleanup {}
    }
    It 'Skips them in an ordinary clean and keeps the other sections' {
        Start-SwCleanRun -IsDryRun $false -IncludeSystem $false -IncludeGameMedia $false -IncludeGpuShaders $false 6>$null
        Should -Invoke Clear-SwGpuShaderCaches -Times 0 -Exactly
        Should -Invoke Invoke-SwUserCleanup -Times 1 -Exactly
        Should -Invoke Clear-SwAppCaches -Times 1 -Exactly
    }
    It 'Cleans them when asked' {
        Start-SwCleanRun -IsDryRun $false -IncludeSystem $false -IncludeGameMedia $false -IncludeGpuShaders $true 6>$null
        Should -Invoke Clear-SwGpuShaderCaches -Times 1 -Exactly
    }
}
