<#
.SYNOPSIS
    Exports AGPH_SYST.HYP and AGPH_SYST.MCH rows to pipe-delimited files (no header).

.DESCRIPTION
    Connects to Oracle 172.20.3.16:1526 (SID AGPHPROD) using the ODP.NET Managed Driver
    (Oracle.ManagedDataAccess.dll) and writes:
        HYP_<yyyyMMdd>.csv
        MCH_<yyyyMMdd>.csv

.EXAMPLE
    .\Export-AgphData.ps1 -UserName myuser -OutputDir D:\Extracts
    (prompts for password)

.EXAMPLE
    .\Export-AgphData.ps1 -Credential (Get-Credential) -DllPath "C:\oracle\odp.net\managed\common\Oracle.ManagedDataAccess.dll"
#>
[CmdletBinding()]
param(
    [string]$DbHost     = '172.20.3.16',
    [int]   $Port       = 1526,
    [string]$Sid        = 'AGPHPROD',
    [switch]$UseServiceName,                       # use SERVICE_NAME instead of SID
    [string]$UserName,
    [System.Management.Automation.PSCredential]$Credential,
    [string]$OutputDir  = (Get-Location).Path,
    [string]$DllPath    = "$PSScriptRoot\Oracle.ManagedDataAccess.dll",
    [int]   $FetchSizeMB = 16
)

$ErrorActionPreference = 'Stop'

# --- Credentials -------------------------------------------------------------
if (-not $Credential) {
    if (-not $UserName) { $UserName = Read-Host 'Oracle user name' }
    $Credential = Get-Credential -UserName $UserName -Message "Password for $UserName@$Sid"
}
$plainPwd = $Credential.GetNetworkCredential().Password

# --- Load driver --------------------------------------------------------------
if (-not (Test-Path $DllPath)) {
    throw "Oracle.ManagedDataAccess.dll not found at '$DllPath'. Get it from NuGet package Oracle.ManagedDataAccess 19.18.0 (lib\net40) or pass -DllPath."
}
# LoadFrom (not Add-Type): Add-Type enumerates every type and fails if optional dependencies are missing
[void][System.Reflection.Assembly]::LoadFrom((Resolve-Path $DllPath).Path)

# --- Connection ---------------------------------------------------------------
$connectKey = if ($UseServiceName) { 'SERVICE_NAME' } else { 'SID' }
$dataSource = "(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=$DbHost)(PORT=$Port))(CONNECT_DATA=($connectKey=$Sid)))"
$connString = "User Id=$($Credential.UserName);Password=`"$plainPwd`";Data Source=$dataSource"

$queries = [ordered]@{
    'HYP' = 'SELECT HYP003_NO_PRET, DGA003_NO_DOSSIER, HYP006_STATUT, HYP054_NO_PRET_SEQ, HYP023_CMPT_DEB FROM AGPH_SYST.HYP h WHERE HYP054_NO_PRET_SEQ = 0'
    'MCH' = 'SELECT MCH003_NO_MARGE, DGA003_NO_DOSSIER, MCH004_NO_MARGE_SEQ, MCH016_STATUT FROM AGPH_SYST.MCH m WHERE MCH004_NO_MARGE_SEQ = 0'
}

if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }
$stamp     = Get-Date -Format 'yyyyMMdd'
$encoding  = New-Object System.Text.UTF8Encoding($false)   # UTF-8, no BOM
$culture   = [System.Globalization.CultureInfo]::InvariantCulture

function Export-Query {
    param($Connection, [string]$Sql, [string]$Path)

    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = $Sql
    $cmd.FetchSize   = $FetchSizeMB * 1MB
    $reader = $cmd.ExecuteReader()
    $writer = New-Object System.IO.StreamWriter($Path, $false, $encoding)
    $writer.NewLine = "`r`n"
    $rows = 0
    try {
        $fieldCount = $reader.FieldCount
        $values = New-Object string[] $fieldCount
        while ($reader.Read()) {
            for ($i = 0; $i -lt $fieldCount; $i++) {
                if ($reader.IsDBNull($i)) { $values[$i] = '' }
                else {
                    $v = $reader.GetValue($i)
                    $values[$i] = if ($v -is [IFormattable]) { $v.ToString($null, $culture) } else { [string]$v }
                }
            }
            $writer.WriteLine([string]::Join('|', $values))
            $rows++
        }
    }
    finally {
        $writer.Dispose()
        $reader.Dispose()
        $cmd.Dispose()
    }
    return $rows
}

$conn = New-Object Oracle.ManagedDataAccess.Client.OracleConnection($connString)
try {
    $conn.Open()
    Write-Host "Connected to $DbHost`:$Port/$Sid"

    foreach ($name in $queries.Keys) {
        $file = Join-Path $OutputDir "$($name)_$stamp.csv"
        $count = Export-Query -Connection $conn -Sql $queries[$name] -Path $file
        Write-Host ("{0}: {1:N0} rows -> {2}" -f $name, $count, $file)
    }
}
catch {
    Write-Error "Export failed: $($_.Exception.Message)"
    exit 1
}
finally {
    $conn.Dispose()
    $plainPwd = $null
}
exit 0
