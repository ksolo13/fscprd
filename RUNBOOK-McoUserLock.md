# Runbook: MCO User Lock / Restore

| Item | Value |
|---|---|
| Script | `Set-McoUserLock.ps1` |
| Purpose | Temporarily disable all active MCO users (option 1) and restore them to their original values afterwards (option 2) |
| Database | Oracle 11g, host `10.152.218.205`, port `1526`, SID `MCODEV` |
| Table | `MCO001.UTILISATEUR` |
| Excluded users (never changed) | `PATKE01`, `CICAM01`, `KHARI01` |
| Credential file | `MCODEV.cred` (next to the script) |
| Backup file | `UTILISATEUR_locked_users.csv` (next to the script) |
| Runtime | Windows PowerShell 5.1 |

---

## 1. What the script does

### 1.1 Option 1 — Disable active users

An **active user** is one where `NBRE_TENTATIVE = 0` **and** `COMPTE_VEROUILLE = 0`.

| Step | Action |
|---|---|
| 1 | Checks that the backup file does **not** already exist. If it does, the script stops, so original values are never overwritten |
| 2 | Connects to `10.152.218.205:1526/MCODEV` and starts a transaction |
| 3 | Selects and locks (`FOR UPDATE`) every active user except the excluded codes |
| 4 | Lists the users and asks **Disable N user(s) listed above?** (default **No**) |
| 5 | On **Yes**: writes the original values to the backup CSV **before** saving any change |
| 6 | Sets `NBRE_TENTATIVE = 3` and `COMPTE_VEROUILLE = 1` for each listed user |
| 7 | Commits only if the number of rows updated matches the number listed; otherwise rolls back and deletes the backup |

```sql
-- Selection
SELECT CODE_UTILISATEUR, NOM_UTILISATEUR, PRENOM_UTILISATEUR, NBRE_TENTATIVE, COMPTE_VEROUILLE
  FROM MCO001.UTILISATEUR
 WHERE NBRE_TENTATIVE = 0 AND COMPTE_VEROUILLE = 0
   AND UPPER(TRIM(CODE_UTILISATEUR)) NOT IN ('PATKE01', 'CICAM01', 'KHARI01')
   FOR UPDATE;

-- Update (per user)
UPDATE MCO001.UTILISATEUR
   SET NBRE_TENTATIVE = 3, COMPTE_VEROUILLE = 1
 WHERE CODE_UTILISATEUR = :code AND NBRE_TENTATIVE = 0 AND COMPTE_VEROUILLE = 0;
```

### 1.2 Option 2 — Restore users

| Step | Action |
|---|---|
| 1 | Checks that the backup file exists |
| 2 | Lists the users in the backup and asks **Restore N user(s) listed above to their original values?** (default **No**) |
| 3 | For each user, sets `NBRE_TENTATIVE` and `COMPTE_VEROUILLE` back to their original values, **only if** they still hold `3` and `1` |
| 4 | Users changed by someone else since the lock are **skipped** and listed in a warning |
| 5 | Commits all restores in one transaction |
| 6 | Renames the backup to `UTILISATEUR_locked_users.restored_yyyyMMdd_HHmmss.csv` so it can't be applied twice |

```sql
UPDATE MCO001.UTILISATEUR
   SET NBRE_TENTATIVE = :origN, COMPTE_VEROUILLE = :origC
 WHERE CODE_UTILISATEUR = :code AND NBRE_TENTATIVE = 3 AND COMPTE_VEROUILLE = 1;
```

### 1.3 Backup file format

CSV with a header row, UTF-8. One row per user changed by option 1.

| Column | Content |
|---|---|
| `CODE_UTILISATEUR` | User code |
| `NOM_UTILISATEUR` / `PRENOM_UTILISATEUR` | Last name / first name |
| `ORIG_NBRE_TENTATIVE` / `NEW_NBRE_TENTATIVE` | Value before (`0`) / after (`3`) |
| `NBRE_TENTATIVE_CHG` | `Y` if the column was changed |
| `ORIG_COMPTE_VEROUILLE` / `NEW_COMPTE_VEROUILLE` | Value before (`0`) / after (`1`) |
| `COMPTE_VEROUILLE_CHG` | `Y` if the column was changed |
| `CHANGED_AT` | Timestamp of the lock run |

> **Do not edit, move or delete the backup file between option 1 and option 2.** It is the only record of the original values.

---

## 2. Prerequisites

| # | Requirement | How to check |
|---|---|---|
| 1 | Windows PowerShell 5.1 | `$PSVersionTable.PSVersion` |
| 2 | Network access to `10.152.218.205` on port `1526` | `Test-NetConnection 10.152.218.205 -Port 1526`, which should return `TcpTestSucceeded : True` |
| 3 | Oracle account with `SELECT` and `UPDATE` on `MCO001.UTILISATEUR` | The same login can run an `UPDATE` in SQL Developer |
| 4 | `Oracle.ManagedDataAccess.dll` **version 19.18.0** in the same folder as the script | See section 3.1 |

---

## 3. One-time setup

### 3.1 Install the Oracle driver (19.18.0)

Skip this step if the DLL is already in the folder (e.g. from the AGPH extract setup).

```powershell
cd $env:USERPROFILE\Downloads
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest https://www.nuget.org/api/v2/package/Oracle.ManagedDataAccess/19.18.0 -OutFile odp.zip
Expand-Archive odp.zip -DestinationPath odp -Force
Copy-Item .\odp\lib\net40\Oracle.ManagedDataAccess.dll .
Unblock-File .\Oracle.ManagedDataAccess.dll
Unblock-File .\Set-McoUserLock.ps1
```

> **Use 19.18.0, not 23.x.** Version 23.x needs extra .NET files that aren't on a standard Windows PC.

### 3.2 Save the Oracle credential

The script handles this itself. On the first run it asks for the Oracle user name and password and saves them to `MCODEV.cred`. Later runs load the file without prompting.

| Rule | Reason |
|---|---|
| Run the script as the Windows user who will use it from now on | The file is encrypted with Windows DPAPI: only that user, on that machine, can decrypt it |
| Run with `-ResetCred` whenever the Oracle password changes | Otherwise you get `ORA-01017` |
| Never copy the `.cred` file to another PC or user | It won't decrypt there |

---

## 4. Run procedure

### 4.1 Pre-checks (before option 1)

| Check | Action |
|---|---|
| Change approved | Confirm the change ticket / approval to lock users |
| No leftover backup | `Test-Path .\UTILISATEUR_locked_users.csv` must return `False` |
| Expected volume | In SQL Developer: `SELECT COUNT(*) FROM MCO001.UTILISATEUR WHERE NBRE_TENTATIVE = 0 AND COMPTE_VEROUILLE = 0 AND CODE_UTILISATEUR NOT IN ('PATKE01','CICAM01','KHARI01');` — note the number |
| Users informed | Users have been told they will be unable to log in |

### 4.2 Option 1 — Disable active users

```powershell
cd $env:USERPROFILE\Downloads
.\Set-McoUserLock.ps1 -Option 1
```

Expected output:

```
Using credentials for MCO001 from C:\Users\<you>\Downloads\MCODEV.cred
Connected to 10.152.218.205:1526/MCODEV

CODE_UTILISATEUR NOM_UTILISATEUR PRENOM_UTILISATEUR ORIG_NBRE_TENTATIVE ORIG_COMPTE_VEROUILLE
---------------- --------------- ------------------ ------------------- ---------------------
ABCDE01          ...             ...                0                   0
...

Confirm
Disable 157 user(s) listed above?
[Y] Yes  [N] No  [?] Help (default is "N"): Y
Disabled 157 user(s). Originals saved to C:\Users\<you>\Downloads\UTILISATEUR_locked_users.csv
```

> The count must match the pre-check count in 4.1. If it doesn't, answer **N** and investigate.

### 4.3 Option 2 — Restore users

```powershell
cd $env:USERPROFILE\Downloads
.\Set-McoUserLock.ps1 -Option 2
```

Expected output:

```
Using credentials for MCO001 from C:\Users\<you>\Downloads\MCODEV.cred
Connected to 10.152.218.205:1526/MCODEV
...
Restore 157 user(s) listed above to their original values?
[Y] Yes  [N] No  [?] Help (default is "N"): Y
Restored 157 user(s).
Backup archived to C:\Users\<you>\Downloads\UTILISATEUR_locked_users.restored_20261006_153012.csv
```

If some users were changed after the lock, you also see:

```
WARNING: Skipped 2 user(s) - not found or values changed since lock: ABCDE01, FGHIJ02
```

Review those users manually (section 5).

### 4.4 Interactive menu

Running the script with no `-Option` shows a menu:

```
  MCO001.UTILISATEUR on 10.152.218.205:1526/MCODEV
  1) Disable all active users (except PATKE01, CICAM01, KHARI01)
  2) Restore users from C:\Users\<you>\Downloads\UTILISATEUR_locked_users.csv

Select option (1/2):
```

### 4.5 Parameters

| Parameter | Default | Use |
|---|---|---|
| `-Option` | *(menu)* | `1` = disable, `2` = restore |
| `-CredFile` | `<script folder>\MCODEV.cred` | Saved credential file |
| `-ResetCred` | Off | Prompt again and overwrite the `.cred` file |
| `-UserName` | *(prompt)* | Oracle user name used when creating the `.cred` file |
| `-Credential` | *(from .cred)* | Pass a credential directly; bypasses the `.cred` file |
| `-BackupFile` | `<script folder>\UTILISATEUR_locked_users.csv` | Where option 1 writes and option 2 reads the original values |
| `-ExcludeUsers` | `PATKE01`, `CICAM01`, `KHARI01` | User codes never changed by option 1 |
| `-DbHost` | `10.152.218.205` | Database host |
| `-Port` | `1526` | Listener port |
| `-Sid` | `MCODEV` | SID, or the service name when used with `-UseServiceName` |
| `-UseServiceName` | Off | Connect with `SERVICE_NAME` instead of `SID` |
| `-Schema` | `MCO001` | Schema owning `UTILISATEUR` |
| `-DllPath` | `<script folder>\Oracle.ManagedDataAccess.dll` | Driver location |

---

## 5. Post-run verification

| After | Check (SQL Developer) | Pass criteria |
|---|---|---|
| Option 1 | `SELECT COUNT(*) FROM MCO001.UTILISATEUR WHERE NBRE_TENTATIVE = 0 AND COMPTE_VEROUILLE = 0;` | Only the excluded users remain (≤ 3) |
| Option 1 | `SELECT CODE_UTILISATEUR, NBRE_TENTATIVE, COMPTE_VEROUILLE FROM MCO001.UTILISATEUR WHERE CODE_UTILISATEUR IN ('PATKE01','CICAM01','KHARI01');` | Unchanged |
| Option 1 | Backup file | Exists; row count (excluding header) equals the disabled count |
| Option 2 | Same `COUNT(*)` as option 1 | Equals the pre-check count from 4.1 plus the excluded active users |
| Option 2 | Skipped users (if any) | Each one reviewed and fixed manually or confirmed as intended |
| Option 2 | Backup file | Renamed to `*.restored_<timestamp>.csv` |

---

## 6. Exit codes

| Code | Meaning |
|---|---|
| `0` | Finished: changes committed, cancelled at the prompt, or nothing to do |
| `1` | Failed. The error is printed (e.g. `Failed: ORA-...`). All changes in that run are rolled back |

---

## 7. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Backup file '...' already exists` (option 1) | A previous lock has not been restored | Run option 2 first, or use `-BackupFile` with a new name if the old file is no longer needed |
| `Backup file '...' not found` (option 2) | Wrong folder, or already restored | Run from the folder holding the CSV, or pass `-BackupFile`. Check for a `*.restored_*.csv` |
| `ORA-00932: inconsistent datatypes: expected CHAR got NUMBER` (option 2) | Old script version (before 6 Oct 2026) | Download the current script and run option 2 again. Nothing was changed by the failed run |
| Script waits after `Connected to ...` | Another session holds uncommitted changes on `UTILISATEUR` rows | Ask the other session (or the DBA) to commit or roll back; or press Ctrl+C and retry later |
| `Skipped N user(s) ...` (option 2) | Those users were changed after the lock (e.g. reset by support) | Check each user in SQL Developer and fix manually if needed |
| `Expected N rows updated, got M. Rolled back.` | Rows changed between select and update | Re-run option 1; nothing was saved |
| `Cannot read '...MCODEV.cred'` / `Key not valid for use in specified state` | `.cred` created by another Windows user or PC | Run with `-ResetCred` |
| `ORA-01017: invalid username/password` | Wrong or changed password | Run with `-ResetCred` |
| `ORA-28000: account is locked` | Oracle account locked | Ask the DBA to unlock it |
| `ORA-00942: table or view does not exist` | No grant on `MCO001.UTILISATEUR`, or wrong schema | Ask the DBA for `SELECT` / `UPDATE`; check `-Schema` |
| `ORA-01031: insufficient privileges` | `SELECT` only, no `UPDATE` | Ask the DBA for `UPDATE` on `MCO001.UTILISATEUR` |
| `ORA-12505: listener does not currently know of SID` | `MCODEV` is a service name, not a SID | Add `-UseServiceName` |
| `ORA-12170` / `ORA-12541` / timeout | Network or firewall | `Test-NetConnection 10.152.218.205 -Port 1526`; check VPN |
| `Oracle.ManagedDataAccess.dll not found` | Driver missing | Section 3.1, or pass `-DllPath` |
| `... running scripts is disabled on this system` | Execution policy / downloaded file | `Unblock-File .\Set-McoUserLock.ps1`, or `powershell.exe -ExecutionPolicy Bypass -File .\Set-McoUserLock.ps1` |

---

## 8. Security and housekeeping

| Item | Guidance |
|---|---|
| Credentials | Only in the DPAPI-encrypted `MCODEV.cred`; never in the script, command history or email |
| Backup CSV | Contains user codes and names. Keep it on a bank-managed drive; never commit it to Git (it is in `.gitignore`) |
| Restored backups | Keep `*.restored_*.csv` as the audit trail per retention policy, then delete |
| Excluded users | Change only with approval; pass `-ExcludeUsers` rather than editing the script |
| Script changes | Keep under version control (`ksolo13/fscprd`); test on MCODEV before any other environment |

---

## 9. Contacts and escalation

| Issue | Contact |
|---|---|
| Database access, grants, row locks | DBA team — *TBD* |
| Network or firewall to `10.152.218.205:1526` | Network / Infrastructure — *TBD* |
| MCO application / user impact | MCO application owner — *TBD* |
| Script defects | Application Development — *TBD* |

---

## 10. Change log

| Date | Change |
|---|---|
| 2026-10-06 | Initial version: lock / restore with CSV backup |
| 2026-10-06 | Credentials saved in DPAPI-encrypted `MCODEV.cred`; `-ResetCred` added |
| 2026-10-06 | Active user redefined as `NBRE_TENTATIVE = 0` **and** `COMPTE_VEROUILLE = 0` |
| 2026-10-06 | Fixed `ORA-00932` on restore (plain `SET` instead of `CASE`) |
