# freeMole Windows - git system proxy tests
# Git does not read the Windows system proxy, so a machine that reaches GitHub
# only through it fails to clone or pull while PowerShell downloads work.

BeforeAll {
    $script:WindowsDir = Split-Path -Parent $PSScriptRoot
    function git { }

    function Get-FunctionText {
        param([string]$Path, [string]$Name)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true)
        if (-not $definition) { throw "$Name not found in $Path" }
        return $definition.Extent.Text
    }

    $script:Updater = Join-Path $script:WindowsDir "bin\update.ps1"
    $script:QuickInstall = Join-Path $script:WindowsDir "quick-install.ps1"
    foreach ($name in @("Get-MoleSystemProxy", "Get-GitProxyArguments")) {
        . ([scriptblock]::Create((Get-FunctionText -Path $script:Updater -Name $name)))
    }
}

Describe "Get-GitProxyArguments" {
    BeforeEach {
        $script:MoleGitProxyArguments = $null
        $script:SavedProxyEnv = @{}
        foreach ($name in @("HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "https_proxy", "http_proxy", "all_proxy")) {
            $script:SavedProxyEnv[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $null)
        }
        $global:MoleTestGitConfigProxy = $null
        Mock git {
            if ($args[0] -eq "config" -and $global:MoleTestGitConfigProxy) { return $global:MoleTestGitConfigProxy }
            $global:LASTEXITCODE = 1
        }
        Mock Get-MoleSystemProxy { "http://127.0.0.1:7890" }
    }

    AfterEach {
        foreach ($name in $script:SavedProxyEnv.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:SavedProxyEnv[$name])
        }
    }

    It "Passes the system proxy to git when GitHub goes through it" {
        $result = @(Get-GitProxyArguments)
        $result | Should -Be @("-c", "http.proxy=http://127.0.0.1:7890")
    }

    It "Adds nothing when GitHub is reached directly" {
        Mock Get-MoleSystemProxy { $null }
        @(Get-GitProxyArguments).Count | Should -Be 0
    }

    It "Keeps a proxy the user set through the environment" {
        [Environment]::SetEnvironmentVariable("HTTPS_PROXY", "http://10.0.0.1:3128")
        @(Get-GitProxyArguments).Count | Should -Be 0
        Should -Invoke Get-MoleSystemProxy -Times 0
    }

    It "Keeps a proxy the user configured for git" {
        $global:MoleTestGitConfigProxy = "socks5://127.0.0.1:1080"
        @(Get-GitProxyArguments).Count | Should -Be 0
        Should -Invoke Get-MoleSystemProxy -Times 0
    }

    It "Looks the proxy up once per run" {
        $null = Get-GitProxyArguments
        $null = Get-GitProxyArguments
        Should -Invoke Get-MoleSystemProxy -Times 1 -Exactly
    }
}

Describe "Git proxy helpers stay identical in the installer and the updater" {
    It "Defines <_> the same way in both scripts" -ForEach @("Get-MoleSystemProxy", "Get-GitProxyArguments") {
        Get-FunctionText -Path $script:QuickInstall -Name $_ | Should -BeExactly (Get-FunctionText -Path $script:Updater -Name $_)
    }

    It "Sends the proxy arguments with every git call in <_>" -ForEach @("bin\update.ps1", "quick-install.ps1") {
        $text = Get-FunctionText -Path (Join-Path $script:WindowsDir $_) -Name "Invoke-GitCommand"
        $text | Should -Match ([regex]::Escape('$gitArguments += @(Get-GitProxyArguments)'))
    }
}
