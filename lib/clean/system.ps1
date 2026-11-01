# Sweepr - system section of sw clean: old Windows error reports below ProgramData
#
# The section "System cleanup", only for a caller that already runs with administrator rights. Loaded
# by dot-sourcing; it loads user.ps1 for the report rule. Loading writes nothing, creates no file or
# folder and starts no process; it only defines functions. A second load in the same scope changes
# nothing.
#
# Sweepr never asks for administrator rights and never raises them. Everything under the Windows
# folder and Program Files is protected and is not a target; what is left is the two report folders
# below ProgramData, handled by the same rule as the reports of the user.

# The dependencies come from the folder of this file, never from the working directory.
. ([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PSScriptRoot), 'core', 'base.ps1'))
. ([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PSScriptRoot), 'core', 'log.ps1'))
. ([System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PSScriptRoot), 'core', 'file_ops.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'user.ps1'))

function Invoke-SwSystemCleanup {
    <#
    .SYNOPSIS
        The section "System cleanup": old error reports below ProgramData. Administrator only.
    .DESCRIPTION
        Without administrator rights, also when the query itself fails, the section warns once and
        offers nothing. Only exactly one [bool] true counts as administrator. Writes nothing to the
        pipeline; a failing report folder stops only itself.
    #>
    $ErrorActionPreference = 'Stop'
    Start-SwSection 'System cleanup'
    try {
        $isAdmin = $false
        try {
            $answer = @(Test-SwAdmin)
            $isAdmin = (($answer.Count -eq 1) -and ($answer[0] -is [bool]) -and ($answer[0] -eq $true))
        }
        catch { $isAdmin = $false }
        if (-not $isAdmin) {
            Write-SwWarning 'The system part needs administrator rights. Start Sweepr from a PowerShell window that runs as administrator; Sweepr does not raise its own rights.'
            return
        }

        $programData = Get-SwCleanEnvRoot -Name 'PROGRAMDATA'
        if ($null -eq $programData) { return }
        $queue = Join-SwCleanPath -Base $programData -Rest @('Microsoft', 'Windows', 'WER', 'ReportQueue')
        $archive = Join-SwCleanPath -Base $programData -Rest @('Microsoft', 'Windows', 'WER', 'ReportArchive')
        try { $null = Clear-SwReportRoot -Root $queue -DaysOld 7 -Description 'Error reports' }
        catch { Write-SwDebug "system error reports not handled, ${queue}: $($_.Exception.Message)" }
        try { $null = Clear-SwReportRoot -Root $archive -DaysOld 7 -Description 'Error reports' }
        catch { Write-SwDebug "system error reports not handled, ${archive}: $($_.Exception.Message)" }
    }
    finally { Stop-SwSection }
}

# ============================================================================
# Old name, kept as a forwarding function (not an alias, so a test mock of either name behaves) until
# the caller moves to the new one. The switches of the removed targets are accepted and do nothing.
# ============================================================================

function Invoke-SystemCleanup {
    param(
        [switch]$IncludeComponentStore,
        [switch]$IncludeDiskCleanup
    )
    Invoke-SwSystemCleanup
}

# Other modules rely on these for the rest of their run.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
