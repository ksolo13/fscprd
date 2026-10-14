# BROKERMASTER loader

Loads `/usr/local/mos/brokerinformation/Master Broker Channel List.XLSX` into the SQL Server table `BROKERMASTER`, matching rows on `CPSCODE` (update if found, insert if new).

Built for the RHEL 6.10 app server: **Java 8** (already installed), no OS packages, no root. The only dependency is the Microsoft SQL Server JDBC driver jar.

## Column mapping

| Excel column | BROKERMASTER |
|---|---|
| CPS Agent or Dealer Code | `CPSCODE` (match key) |
| MATD Dealer Name or PMPP Dealer Name | `BROKERFIRM` |
| PMPP AGENT Name | `AGENT` |
| MOS Channel | `BROKERCHANNEL` |
| Date added to PMPP or Mortgage Broker Agreement Date | `ADDED` |
| Date Removed from PMPP | `REMOVED` |
| PMPP - BDM, Filler, FIRM ID, Filler, PMPP Comments | Not loaded |
| (none) | `ID`: see `BROKER_ID_MODE` |

Header matching ignores line breaks, extra spaces and case.

## Rules

| Situation | Action |
|---|---|
| Duplicate `CPSCODE` in the file | Keep the row with `ADDED` filled and `REMOVED` blank; if there's still a tie, keep the latest `ADDED`, then the first row in the file. The others go to the exceptions CSV |
| `CPSCODE` not yet in the table | Insert |
| `CPSCODE` in the table, values changed | Update |
| `CPSCODE` in the table but not in the file | Left unchanged (count logged) |
| Blank `CPSCODE` | Rejected (exceptions CSV) |
| Text cell is `N/A`, `NA`, `NULL`, `#N/A` or blank | Loaded as empty string `''` (matches existing data) |
| Date cell is `N/A`, `NA`, `NULL`, `#N/A` or blank | Loaded as `NULL` |
| Date as text | Accepted: `2023-03-15`, `2023/03/15`, `3/15/2023` (month first), `15-Mar-2023`, `15 Mar 2023`, `Mar 15, 2023`, `20230315` |
| Date cell with other text (e.g. `TBD`) | Row rejected (exceptions CSV) |
| `BROKERMASTER` already has duplicate `CPSCODE`s | Load stops, nothing changed |
| File unchanged since last successful load (SHA-256) | Skipped (`--force` to reload) |
| File modified less than 2 minutes ago | Skipped until the next run (may still be copying) |
| Any error | Whole load rolled back |

## Install (as the service account, not root)

1. Check where Java 8 is installed: `ls -d /usr/java/*1.8*`
2. On a workstation with internet, download the JDBC driver and copy it to the server:
   `https://repo1.maven.org/maven2/com/microsoft/sqlserver/mssql-jdbc/12.8.1.jre8/mssql-jdbc-12.8.1.jre8.jar`
   (SHA-256 `44f217b1d67d22442002ee2d1c4ab8e86358606a787b95eeb5301f235482a2ab`)
3. On the server:

```bash
mkdir -p /opt/mos/brokermaster/lib /opt/mos/brokermaster/classes /var/log/mos
cd /opt/mos/brokermaster
# copy in: BrokerMasterLoader.java, run_brokermaster.sh, .env.example, and lib/mssql-jdbc-12.8.1.jre8.jar
/usr/java/jdk1.8.0_291-amd64/bin/javac -d classes BrokerMasterLoader.java   # compile with the Java 8 JDK
cp .env.example .env && chmod 600 .env && chmod 750 run_brokermaster.sh       # then edit .env
```

Set `BROKER_ID_MODE` to match how `ID` is generated:

| `ID` column is... | `BROKER_ID_MODE` |
|---|---|
| IDENTITY | `identity` |
| Filled from a sequence | `NEXT VALUE FOR dbo.BROKERMASTER_SEQ` |
| Neither (plain number) | `max` (uses MAX(ID)+1; only safe if nothing else inserts at the same time) |

Recommended: a unique index on `CPSCODE` so the database enforces no duplicates.

The service account needs read access to `/usr/local/mos/brokerinformation`, write access to its `archive/` subfolder and `.last_loaded.sha256`, and write access to `/var/log/mos`. Its database login needs `SELECT, INSERT, UPDATE` on `BROKERMASTER`.

## Test, then schedule

```bash
/opt/mos/brokermaster/run_brokermaster.sh --dry-run --force   # validates and rolls back
tail /var/log/mos/brokermaster_load.log
```

`crontab -e` for the service account (weekdays at 6:15 AM; cron emails `MAILTO` only on warnings and errors):

```cron
MAILTO=mos-support@yourbank.com
15 6 * * 1-5  /opt/mos/brokermaster/run_brokermaster.sh
```

## Outputs

| Output | Location |
|---|---|
| Run log | `/var/log/mos/brokermaster_load.log` |
| Rejected and de-duplicated rows | `/var/log/mos/brokermaster_exceptions_<timestamp>.csv` |
| Copy of each loaded file | `/usr/local/mos/brokerinformation/archive/` |
| Exit code | `0` OK or nothing to do · `1` failed (rolled back) · `2` loaded with rejected rows |
