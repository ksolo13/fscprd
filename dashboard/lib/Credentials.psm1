#Requires -Version 5.1
<#
    Credentials.psm1 - DPAPI-backed secret store.

    Uses Export-Clixml / Import-Clixml, which encrypt the SecureString with
    Windows DPAPI: readable only by the same Windows user on the same machine
    (the same pattern Export-AgphData.ps1 and RUNBOOK.md 3.2 already rely on).
    Use it for SSH key passphrases, password-auth SSH, or an Oracle credential.

    Store location: %USERPROFILE%\.taskdashboard\<name>.cred
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

function Get-CredStoreDir {
    $d = Join-Path $env:USERPROFILE '.taskdashboard'
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    return $d
}

function Get-CredPath {
    param([Parameter(Mandatory)][string]$Name)
    Join-Path (Get-CredStoreDir) ("{0}.cred" -f ($Name -replace '[^\w\.-]', '_'))
}

function Save-DashboardCredential {
    param(
        [Parameter(Mandatory)][string]$Name,
        [System.Management.Automation.PSCredential]$Credential
    )
    if (-not $Credential) { $Credential = Get-Credential -Message "Credential to store as '$Name'" }
    $Credential | Export-Clixml -LiteralPath (Get-CredPath -Name $Name)
    Write-Host "Saved credential '$Name'."
}

function Get-DashboardCredential {
    param([Parameter(Mandatory)][string]$Name)
    $p = Get-CredPath -Name $Name
    if (-not (Test-Path -LiteralPath $p)) { throw "No stored credential named '$Name'. Use Save-DashboardCredential first." }
    Import-Clixml -LiteralPath $p
}

function Test-DashboardCredential {
    param([Parameter(Mandatory)][string]$Name)
    Test-Path -LiteralPath (Get-CredPath -Name $Name)
}

function Remove-DashboardCredential {
    param([Parameter(Mandatory)][string]$Name)
    $p = Get-CredPath -Name $Name
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; Write-Host "Removed credential '$Name'." }
}

Export-ModuleMember -Function Save-DashboardCredential, Get-DashboardCredential, Test-DashboardCredential, Remove-DashboardCredential
