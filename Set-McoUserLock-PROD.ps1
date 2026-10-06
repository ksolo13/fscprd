<#
.SYNOPSIS
    PRODUCTION - Locks (option 1) or restores (option 2) MCO001.UTILISATEUR accounts.

.DESCRIPTION
    Connects to Oracle 172.20.3.16:1526 (SID MCOPROD) using the ODP.NET Managed Driver
    (Oracle.ManagedDataAccess.dll).

    Option 1 - Disable active users
        Active user = NBRE_TENTATIVE = 0 AND COMPTE_VEROUILLE = 0.
        For every active user except the excluded codes (default PATKE01, CICAM01, KHARI01):
            NBRE_TENTATIVE   = 3
            COMPTE_VEROUILLE = 1
        Original values of every changed row are written to the backup CSV BEFORE commit.
        Refuses to run if the backup file already exists (would lose original values).

    Option 2 - Restore users
        Reads the backup CSV and sets each changed column back to its original value.
        Only columns that option 1 actually changed are restored, and only if they all still
        hold the values option 1 set (rows changed since by someone else are skipped and reported).
        On success the backup file is renamed to *.restored_<timestamp>.csv.

    Each option runs in a single transaction: all rows commit or none do.

    Production safeguard: after answering Yes, you must also type the database name
    (MCOPROD) before any change is saved.

    Credentials
        Stored in a .cred file (default MCOPROD.cred next to the script) via Export-Clixml.
        The password is encrypted with Windows DPAPI: only the same Windows user on the
        same machine can decrypt it. First run prompts and saves; later runs load silently.
        Use -ResetCred to re-prompt and overwrite (e.g. after a password change).

.EXAMPLE
    .\Set-McoUserLock-PROD.ps1 -UserName MCO001
    (menu prompts for option 1 or 2; password prompted once, then saved to MCOPROD.cred)

.EXAMPLE
    .\Set-McoUserLock-PROD.ps1 -ResetCred
    (re-prompt for credentials and overwrite the .cred file)

.EXAMPLE
    .\Set-McoUserLock-PROD.ps1 -Option 1 -UserName MCO001 -BackupFile D:\Backup\UTILISATEUR_locked.csv
#>
[CmdletBinding()]
param(
    [ValidateSet('1', '2')]
    [string]$Option,
    [string]$DbHost     = '172.20.3.16',
    [int]   $Port       = 1526,
    [string]$Sid        = 'MCOPROD',
    [switch]$UseServiceName,                       # use SERVICE_NAME instead of SID
    [string]$Schema     = 'MCO001',
    [string]$UserName,
    [System.Management.Automation.PSCredential]$Credential,
    [string]$CredFile   = "$PSScriptRoot\MCOPROD.cred",
    [switch]$ResetCred,                            # re-prompt and overwrite the .cred file
    [string[]]$ExcludeUsers = @('PATKE01', 'CICAM01', 'KHARI01'),
    [string]$BackupFile = "$PSScriptRoot\UTILISATEUR_locked_users_PROD.csv",
    [string]$DllPath    = "$PSScriptRoot\Oracle.ManagedDataAccess.dll"
)

$ErrorActionPreference = 'Stop'
$table = "$Schema.UTILISATEUR"

# --- Menu ---------------------------------------------------------------------
if (-not $Option) {
    Write-Host ''
    Write-Host "  *** PRODUCTION ***" -ForegroundColor Red
    Write-Host "  $table on $DbHost`:$Port/$Sid"
    Write-Host "  1) Disable all active users (except $($ExcludeUsers -join ', '))"
    Write-Host "  2) Restore users from $BackupFile"
    Write-Host ''
    do { $Option = Read-Host 'Select option (1/2)' } until ($Option -in '1', '2')
}

# Pre-checks before asking for a password
if ($Option -eq '1' -and (Test-Path -LiteralPath $BackupFile)) {
    throw "Backup file '$BackupFile' already exists. Run option 2 first, or pass a different -BackupFile. Overwriting it would lose the original values."
}
if ($Option -eq '2' -and -not (Test-Path -LiteralPath $BackupFile)) {
    throw "Backup file '$BackupFile' not found. Nothing to restore."
}

# --- Credentials -------------------------------------------------------------
if (-not $Credential -and -not $ResetCred -and (Test-Path -LiteralPath $CredFile)) {
    try {
        $Credential = Import-Clixml -LiteralPath $CredFile
        if ($Credential -isnot [System.Management.Automation.PSCredential]) { throw 'not a credential' }
        Write-Host "Using credentials for $($Credential.UserName) from $CredFile"
    }
    catch {
        throw "Cannot read '$CredFile' ($($_.Exception.Message)). It can only be decrypted by the Windows user/machine that created it. Run with -ResetCred."
    }
}
if (-not $Credential) {
    if (-not $UserName) { $UserName = Read-Host 'Oracle user name' }
    $Credential = Get-Credential -UserName $UserName -Message "Password for $UserName@$Sid"
    if (-not $Credential) { throw 'No credentials entered.' }
    $Credential | Export-Clixml -LiteralPath $CredFile -Force
    Write-Host "Credentials saved to $CredFile (DPAPI-encrypted, this Windows user/machine only)"
}
$plainPwd = $Credential.GetNetworkCredential().Password

# --- Load driver --------------------------------------------------------------
if (-not (Test-Path $DllPath)) {
    throw "Oracle.ManagedDataAccess.dll not found at '$DllPath'. Get it from NuGet package Oracle.ManagedDataAccess 19.18.0 (lib\net40) or pass -DllPath."
}
[void][System.Reflection.Assembly]::LoadFrom((Resolve-Path $DllPath).Path)

# --- Connection ---------------------------------------------------------------
$connectKey = if ($UseServiceName) { 'SERVICE_NAME' } else { 'SID' }
$dataSource = "(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=$DbHost)(PORT=$Port))(CONNECT_DATA=($connectKey=$Sid)))"
$connString = "User Id=$($Credential.UserName);Password=`"$plainPwd`";Data Source=$dataSource"

function Confirm-Action([string]$Message) {
    if ($Host.UI.PromptForChoice('Confirm', $Message,
        [System.Management.Automation.Host.ChoiceDescription[]]@('&Yes', '&No'), 1) -ne 0) { return $false }
    # Production: second confirmation by typing the database name
    Write-Host "*** PRODUCTION: $DbHost`:$Port/$Sid ***" -ForegroundColor Red
    (Read-Host "Type $Sid to confirm") -ceq $Sid
}

function New-Cmd($Connection, $Transaction, [string]$Sql) {
    $cmd = $Connection.CreateCommand()
    $cmd.Transaction = $Transaction
    $cmd.BindByName  = $true
    $cmd.CommandText = $Sql
    $cmd
}

function Get-Str($Reader, [int]$i) {
    if ($Reader.IsDBNull($i)) { '' } else { [string]$Reader.GetValue($i) }
}

# --- Option 1: lock -----------------------------------------------------------
function Invoke-Lock($Connection) {
    $tx = $Connection.BeginTransaction()
    $backupWritten = $false
    try {
        # Bind exclusion list as :ex0, :ex1, ...
        $exNames = for ($i = 0; $i -lt $ExcludeUsers.Count; $i++) { ":ex$i" }
        $where = "NBRE_TENTATIVE = 0 AND COMPTE_VEROUILLE = 0"
        if ($exNames) { $where += " AND UPPER(TRIM(CODE_UTILISATEUR)) NOT IN ($($exNames -join ', '))" }

        # Lock candidate rows so nothing changes between read and update
        $sel = New-Cmd $Connection $tx @"
SELECT CODE_UTILISATEUR, NOM_UTILISATEUR, PRENOM_UTILISATEUR, NBRE_TENTATIVE, COMPTE_VEROUILLE
  FROM $table
 WHERE $where
 ORDER BY CODE_UTILISATEUR
   FOR UPDATE
"@
        for ($i = 0; $i -lt $ExcludeUsers.Count; $i++) {
            [void]$sel.Parameters.Add("ex$i", $ExcludeUsers[$i].Trim().ToUpper())
        }

        $rows = New-Object System.Collections.Generic.List[object]
        $reader = $sel.ExecuteReader()
        try {
            while ($reader.Read()) {
                $rows.Add([pscustomobject]@{
                    CODE_UTILISATEUR      = Get-Str $reader 0
                    NOM_UTILISATEUR       = Get-Str $reader 1
                    PRENOM_UTILISATEUR    = Get-Str $reader 2
                    ORIG_NBRE_TENTATIVE   = Get-Str $reader 3
                    NEW_NBRE_TENTATIVE    = '3'
                    NBRE_TENTATIVE_CHG    = 'Y'
                    ORIG_COMPTE_VEROUILLE = Get-Str $reader 4
                    NEW_COMPTE_VEROUILLE  = '1'
                    COMPTE_VEROUILLE_CHG  = 'Y'
                    CHANGED_AT            = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                })
            }
        }
        finally { $reader.Dispose(); $sel.Dispose() }

        if ($rows.Count -eq 0) {
            Write-Host 'No active users to disable.'
            $tx.Rollback(); return
        }

        $rows | Format-Table CODE_UTILISATEUR, NOM_UTILISATEUR, PRENOM_UTILISATEUR, ORIG_NBRE_TENTATIVE, ORIG_COMPTE_VEROUILLE -AutoSize | Out-Host
        if (-not (Confirm-Action "Disable $($rows.Count) user(s) listed above?")) {
            Write-Host 'Cancelled. No changes made.'
            $tx.Rollback(); return
        }

        # Write backup BEFORE committing so originals are never lost
        $dir = Split-Path -Parent $BackupFile
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        $rows | Export-Csv -LiteralPath $BackupFile -NoTypeInformation -Encoding UTF8
        $backupWritten = $true

        $upd = New-Cmd $Connection $tx @"
UPDATE $table
   SET NBRE_TENTATIVE = 3, COMPTE_VEROUILLE = 1
 WHERE CODE_UTILISATEUR = :code AND NBRE_TENTATIVE = 0 AND COMPTE_VEROUILLE = 0
"@
        $p = $upd.Parameters.Add('code', [Oracle.ManagedDataAccess.Client.OracleDbType]::Varchar2)
        $updated = 0
        foreach ($r in $rows) {
            $p.Value = $r.CODE_UTILISATEUR
            $updated += $upd.ExecuteNonQuery()
        }
        $upd.Dispose()

        if ($updated -ne $rows.Count) {
            throw "Expected $($rows.Count) rows updated, got $updated. Rolled back."
        }
        $tx.Commit()
        Write-Host "Disabled $updated user(s). Originals saved to $BackupFile" -ForegroundColor Green
    }
    catch {
        $tx.Rollback()
        if ($backupWritten) { Remove-Item -LiteralPath $BackupFile }   # nothing committed, backup not valid
        throw
    }
    finally { $tx.Dispose() }
}

# --- Option 2: restore ---------------------------------------------------------
function Invoke-Restore($Connection) {
    $rows = @(Import-Csv -LiteralPath $BackupFile)
    if ($rows.Count -eq 0) { Write-Host 'Backup file is empty.'; return }

    $rows | Format-Table CODE_UTILISATEUR, NOM_UTILISATEUR, PRENOM_UTILISATEUR, ORIG_NBRE_TENTATIVE, ORIG_COMPTE_VEROUILLE -AutoSize | Out-Host
    if (-not (Confirm-Action "Restore $($rows.Count) user(s) listed above to their original values?")) {
        Write-Host 'Cancelled. No changes made.'; return
    }

    $tx = $Connection.BeginTransaction()
    try {
        $restored = 0
        $skipped  = New-Object System.Collections.Generic.List[string]
        foreach ($r in $rows) {
            $set = @()
            # Plain SET (no CASE): CASE needs matching datatypes, while plain SET/compare lets
            # Oracle convert the string bind to the column type (NUMBER or CHAR) implicitly.
            if ($r.NBRE_TENTATIVE_CHG   -eq 'Y') { $set += 'NBRE_TENTATIVE = :origN' }
            if ($r.COMPTE_VEROUILLE_CHG -eq 'Y') { $set += 'COMPTE_VEROUILLE = :origC' }
            if (-not $set) { continue }

            # Only touch the row if every changed column still holds the value option 1 set
            $cond = @()
            if ($r.NBRE_TENTATIVE_CHG   -eq 'Y') { $cond += 'NBRE_TENTATIVE = :newN' }
            if ($r.COMPTE_VEROUILLE_CHG -eq 'Y') { $cond += 'COMPTE_VEROUILLE = :newC' }

            $cmd = New-Cmd $Connection $tx "UPDATE $table SET $($set -join ', ') WHERE CODE_UTILISATEUR = :code AND $($cond -join ' AND ')"
            if ($r.NBRE_TENTATIVE_CHG -eq 'Y') {
                [void]$cmd.Parameters.Add('newN',  $r.NEW_NBRE_TENTATIVE)
                [void]$cmd.Parameters.Add('origN', $r.ORIG_NBRE_TENTATIVE)
            }
            if ($r.COMPTE_VEROUILLE_CHG -eq 'Y') {
                [void]$cmd.Parameters.Add('newC',  $r.NEW_COMPTE_VEROUILLE)
                [void]$cmd.Parameters.Add('origC', $r.ORIG_COMPTE_VEROUILLE)
            }
            [void]$cmd.Parameters.Add('code', $r.CODE_UTILISATEUR)

            $n = $cmd.ExecuteNonQuery()
            $cmd.Dispose()
            if ($n -eq 1) { $restored++ } else { $skipped.Add($r.CODE_UTILISATEUR) }
        }

        $tx.Commit()
        Write-Host "Restored $restored user(s)." -ForegroundColor Green
        if ($skipped.Count) {
            Write-Warning ("Skipped $($skipped.Count) user(s) - not found or values changed since lock: " + ($skipped -join ', '))
        }

        $done = [IO.Path]::ChangeExtension($BackupFile, $null).TrimEnd('.') + ".restored_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
        Move-Item -LiteralPath $BackupFile -Destination $done
        Write-Host "Backup archived to $done"
    }
    catch { $tx.Rollback(); throw }
    finally { $tx.Dispose() }
}

# --- Main ----------------------------------------------------------------------
$conn = New-Object Oracle.ManagedDataAccess.Client.OracleConnection($connString)
try {
    $conn.Open()
    Write-Host "Connected to PRODUCTION $DbHost`:$Port/$Sid" -ForegroundColor Red
    if ($Option -eq '1') { Invoke-Lock $conn } else { Invoke-Restore $conn }
}
catch {
    Write-Error "Failed: $($_.Exception.Message)"
    if ($_.Exception.Message -match 'ORA-01017') { Write-Warning "Invalid user/password. Run with -ResetCred to update $CredFile." }
    exit 1
}
finally {
    $conn.Dispose()
    $plainPwd = $null
}
exit 0
