# Runbook: AGPH Data Integrity Extract

| Item | Value |
|---|---|
| Script | `Export-AgphData.ps1` |
| Purpose | Extract HYP and MCH records from AGPHPROD to pipe-delimited files and copy them to the SharePoint *Data integrity reports* folder |
| Database | Oracle, host `10.153.128.14`, port `1526`, SID `AGPHPROD` |
| Output | `HYP_yyyyMMdd.csv`, `MCH_yyyyMMdd.csv` |
| SharePoint destination | [Tremblant Data integrity reports › Documents partagés › Data integrity reports](https://banquelaurentienne.sharepoint.com/sites/TremblantDataintegrityreports/Documents%20partages/Data%20integrity%20reports) |
| Runtime | Windows PowerShell 5.1 |
| Typical volume | HYP ≈ 41,200 rows; MCH ≈ 13,300 rows (1 Oct 2026) |

---

## 1. What the script does

| Step | Action |
|---|---|
| 1 | Loads the Oracle driver (`Oracle.ManagedDataAccess.dll`) from the script folder |
| 2 | Connects to `10.153.128.14:1526/AGPHPROD` using the supplied credential |
| 3 | Runs the HYP query and writes `HYP_yyyyMMdd.csv` |
| 4 | Runs the MCH query and writes `MCH_yyyyMMdd.csv` |
| 5 | Prints the row count and path for each file |
| 6 | Asks **Copy these files to SharePoint?** (default **No**) |
| 7 | On **Yes**: copies both files to the OneDrive-synced SharePoint folder. It asks before overwriting a file that already exists. |

**Queries**

```sql
-- HYP
SELECT HYP003_NO_PRET, DGA003_NO_DOSSIER, HYP006_STATUT, HYP054_NO_PRET_SEQ, HYP023_CMPT_DEB
FROM AGPH_SYST.HYP h WHERE HYP054_NO_PRET_SEQ = 0

-- MCH
SELECT MCH003_NO_MARGE, DGA003_NO_DOSSIER, MCH004_NO_MARGE_SEQ, MCH016_STATUT
FROM AGPH_SYST.MCH m WHERE MCH004_NO_MARGE_SEQ = 0
```

**File format**

| Property | Value |
|---|---|
| Delimiter | Pipe `\|` |
| Header row | None |
| Encoding | UTF-8, no BOM |
| Line ending | CRLF (Windows) |
| NULL values | Empty field, e.g. `123\|\|A` |
| Numbers | Invariant culture (`.` as the decimal separator) |

---

## 2. Prerequisites

| # | Requirement | How to check |
|---|---|---|
| 1 | Windows PowerShell 5.1 | `$PSVersionTable.PSVersion` |
| 2 | Network access to `10.153.128.14` on port `1526` | `Test-NetConnection 10.153.128.14 -Port 1526`, which should return `TcpTestSucceeded : True` |
| 3 | Oracle account with `SELECT` on `AGPH_SYST.HYP` and `AGPH_SYST.MCH` | The same login works in SQL Developer |
| 4 | `Oracle.ManagedDataAccess.dll` **version 19.18.0** in the same folder as the script | See section 3.1 |
| 5 | SharePoint library synced through OneDrive (needed only for the copy step) | See section 3.3 |

---

## 3. One-time setup

Use a **new** PowerShell window for every step below.

### 3.1 Install the Oracle driver (19.18.0)

```powershell
cd $env:USERPROFILE\Downloads
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest https://www.nuget.org/api/v2/package/Oracle.ManagedDataAccess/19.18.0 -OutFile odp.zip
Expand-Archive odp.zip -DestinationPath odp -Force
Copy-Item .\odp\lib\net40\Oracle.ManagedDataAccess.dll .
Unblock-File .\Oracle.ManagedDataAccess.dll
Unblock-File .\Export-AgphData.ps1
```

> **Use 19.18.0, not 23.x.** Version 23.x needs six extra .NET files that aren't on a standard Windows PC. Versions 19.24 and later need two or three.
> If nuget.org is blocked, download the `.nupkg` file in a browser, rename it to `.zip`, then continue from `Expand-Archive`.

### 3.2 Save the Oracle credential

```powershell
Get-Credential -UserName <oracle_user> -Message "AGPHPROD password" |
    Export-Clixml C:\Users\<you>\Downloads\agph.cred
```

| Rule | Reason |
|---|---|
| Create the file as the Windows user who will run the script | Windows encrypts the file so only that user, on that machine, can decrypt it |
| Recreate it whenever the Oracle password changes | Otherwise you get `ORA-01017` |
| Never store the password in plain text | Bank security policy |

### 3.3 Sync the SharePoint folder

1. Open the [Data integrity reports](https://banquelaurentienne.sharepoint.com/sites/TremblantDataintegrityreports/Documents%20partages/Data%20integrity%20reports) folder in a browser.
2. Click **Sync** (or **Add shortcut to My files**).
3. In File Explorer, confirm that a local **Data integrity reports** folder appears, usually under `C:\Users\<you>\Banque Laurentienne\...` or `OneDrive - Banque Laurentienne\...`.
4. *(Optional)* Shift + right-click the folder, choose **Copy as path**, and keep the path for `-SharePointSyncFolder`.

---

## 4. Run procedure

### 4.1 Standard run (interactive)

```powershell
cd $env:USERPROFILE\Downloads
.\Export-AgphData.ps1 -Credential (Import-Clixml .\agph.cred) -OutputDir .\Extracts
```

Expected output:

```
Connected to 10.153.128.14:1526/AGPHPROD
HYP: 41,224 rows -> C:\Users\<you>\Downloads\Extracts\HYP_20261001.csv
MCH: 13,276 rows -> C:\Users\<you>\Downloads\Extracts\MCH_20261001.csv

SharePoint
Copy these files to SharePoint 'Data integrity reports'?
  HYP_20261001.csv
  MCH_20261001.csv
[Y] Yes  [N] No  [?] Help (default is "N"): Y
Copied -> ...\Data integrity reports\HYP_20261001.csv
Copied -> ...\Data integrity reports\MCH_20261001.csv
OneDrive will upload the files to SharePoint in the background.
```

### 4.2 With an explicit SharePoint folder

```powershell
.\Export-AgphData.ps1 -Credential (Import-Clixml .\agph.cred) -OutputDir .\Extracts `
    -SharePointSyncFolder "C:\Users\<you>\...\Data integrity reports"
```

### 4.3 Unattended or scheduled run (no prompt, no copy)

Task Scheduler action. Program: `powershell.exe`. Arguments:

```
-NoProfile -ExecutionPolicy Bypass -Command "& 'C:\Scripts\Export-AgphData.ps1' -Credential (Import-Clixml 'C:\Scripts\agph.cred') -OutputDir 'C:\Scripts\Extracts' -SkipUpload; exit $LASTEXITCODE"
```

> Use `-Command`, not `-File`. With `-File`, PowerShell passes arguments as plain text, so `(Import-Clixml ...)` is never run and the credential fails. Run the task as the same Windows account that created the `.cred` file.

### 4.4 Parameters

| Parameter | Default | Use |
|---|---|---|
| `-Credential` | *(prompt)* | `(Import-Clixml <path>.cred)` |
| `-UserName` | *(prompt)* | Prompts for the password only |
| `-OutputDir` | Current folder | Where the CSV files are written; created if missing |
| `-DbHost` | `10.153.128.14` | Database host |
| `-Port` | `1526` | Listener port |
| `-Sid` | `AGPHPROD` | SID, or the service name when used with `-UseServiceName` |
| `-UseServiceName` | Off | Connect with `SERVICE_NAME` instead of `SID` |
| `-DllPath` | `<script folder>\Oracle.ManagedDataAccess.dll` | Driver location |
| `-SharePointSyncFolder` | Auto-detected under `%USERPROFILE%` | Local synced *Data integrity reports* folder |
| `-SkipUpload` | Off | Skips the SharePoint prompt and copy |
| `-FetchSizeMB` | `16` | Oracle fetch buffer size |

---

## 5. Post-run verification

| Check | Command or action | Pass criteria |
|---|---|---|
| Files exist | `Get-ChildItem .\Extracts\*_$(Get-Date -f yyyyMMdd).csv` | 2 files, size > 0 |
| Format | `Get-Content .\Extracts\HYP_$(Get-Date -f yyyyMMdd).csv -TotalCount 3` | Pipe-delimited, no header |
| Row count | `(Get-Content .\Extracts\HYP_$(Get-Date -f yyyyMMdd).csv).Count` | Matches `SELECT COUNT(*) ...` with the same `WHERE` clause in SQL Developer |
| Volume | Compare with the previous run | Within the normal range (see the summary table at the top) |
| SharePoint | Open the SharePoint folder in a browser | Both files appear with today's date; the OneDrive icon shows a green check |

---

## 6. Exit codes

| Code | Meaning |
|---|---|
| `0` | Export finished (copy done, declined, or skipped) |
| `1` | Failed. The error is printed, e.g. `Export failed: ORA-...`, a missing DLL, or a copy error |

---

## 7. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Oracle.ManagedDataAccess.dll not found at ...` | Driver missing from the script folder | Follow section 3.1, or pass `-DllPath` |
| `Add-Type : Unable to load one or more of the requested types` | Older script version loading a 23.x driver | Use the current script and driver 19.18.0 |
| `Could not load file or assembly ... System.Text.Json` (or similar) | 23.x or 19.24+ driver in use | Replace it with 19.18.0 (section 3.1) |
| `Copy-Item : The process cannot access the file ... being used by another process` | The DLL is loaded in the current PowerShell window | Close **all** PowerShell windows, open a new one, retry |
| `NuGet\Install-Package : The module 'NuGet' could not be loaded` | That command works only in Visual Studio | Use the `Invoke-WebRequest` steps in section 3.1 |
| `Get-Credential` prompts for `Message:` | PowerShell needs `-Message` when `-UserName` is used | Add `-Message "AGPHPROD password"`, or type any text |
| `ORA-12505: listener does not currently know of SID` | Wrong host, or the name is a service name rather than a SID | Confirm host `10.153.128.14` (not `172.20.3.16`); otherwise try `-UseServiceName` |
| `ORA-12514: listener does not know of service` | Wrong service name | Get the exact name from SQL Developer, `tnsnames.ora`, or the DBA |
| `ORA-12170` / `ORA-12541` / connection timeout | Network or firewall | `Test-NetConnection 10.153.128.14 -Port 1526`; check VPN; raise a firewall request |
| `ORA-01017: invalid username/password` | Wrong or expired password | Recreate the `.cred` file (section 3.2) |
| `ORA-28000: account is locked` | Account locked | Ask the DBA to unlock it |
| `ORA-00942: table or view does not exist` | No grant on `AGPH_SYST.HYP` or `MCH` | Ask the DBA for `SELECT` access |
| `Import-Clixml : Key not valid for use in specified state` | `.cred` file created by another user or on another PC | Recreate it as the account running the script |
| `Invalid -SharePointSyncFolder path` / `Illegal characters in path` | Placeholder (e.g. `<library>`) or a typo in the path | Use **Copy as path** on the real synced folder (section 3.3) |
| `Synced SharePoint folder not found`, then the browser opens | Library not synced on this PC | Sync it (section 3.3), or drag the files into the browser window that opens |
| `... cannot be loaded because running scripts is disabled` | Execution policy | `Unblock-File .\Export-AgphData.ps1`, or run with `powershell.exe -ExecutionPolicy Bypass -File ...` |
| Files are in Downloads, not Extracts | `-OutputDir` not supplied | Add `-OutputDir .\Extracts` |
| Row count is zero or far below normal | Data issue or wrong environment | Re-run the query in SQL Developer; escalate to the data owner before you upload |

---

## 8. Security and housekeeping

| Item | Guidance |
|---|---|
| Credentials | Keep them only in the encrypted `.cred` file; never in the script, command history, or email |
| Extract files | They contain loan and account identifiers. Store them only on bank-managed drives and SharePoint |
| Local copies | Delete old files in `Extracts` after you confirm the SharePoint upload, per the retention policy |
| Script changes | Keep the script under version control (`ksolo13/fscprd`); test changes before production use |

---

## 9. Contacts and escalation

| Issue | Contact |
|---|---|
| Database access, account lock, grants | DBA team — *TBD* |
| Network or firewall to `10.153.128.14:1526` | Network / Infrastructure — *TBD* |
| SharePoint site access | Site owner, Tremblant Data integrity reports — *TBD* |
| Script defects | Application Development — *TBD* |

---

## 10. Change log

| Date | Change |
|---|---|
| 2026-10-01 | Initial version: Oracle extract to pipe-delimited files |
| 2026-10-01 | Driver now loaded with `Assembly.LoadFrom`; standardised on ODP.NET 19.18.0 |
| 2026-10-01 | Default host corrected to `10.153.128.14` |
| 2026-10-01 | Added the SharePoint copy prompt (OneDrive sync) |
| 2026-10-01 | An invalid SharePoint path is handled without crashing; `-LiteralPath` used |
