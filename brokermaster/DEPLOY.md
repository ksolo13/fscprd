# BROKERMASTER loader – deployment (RHEL 6.10)

Run as `root` unless a step says otherwise. Deploy to UAT (`NC100DITDEVAPPUAT`) first, then repeat for PROD.

## 0. Before you start

| Item | Who | How |
|---|---|---|
| SQL login for the loader | DBA | `GRANT SELECT, INSERT, UPDATE ON dbo.BROKERMASTER TO [BROKER_LOADER];` |
| Backup of the table | DBA | `SELECT * INTO dbo.BROKERMASTER_BAK_20261014 FROM dbo.BROKERMASTER;` |
| New `DATEMODIFIED` column (after the backup) | DBA | `ALTER TABLE dbo.BROKERMASTER ADD DATEMODIFIED DATETIME NULL;` Existing rows stay NULL. First confirm no other code inserts into this table without a column list |
| Firewall: app server → SQL Server port (1433) | Network | Tested in step 6 |
| Current delete/reload job identified | Load owner | It is turned off in step 10 |
| JDBC driver downloaded on your workstation | You | `https://repo1.maven.org/maven2/com/microsoft/sqlserver/mssql-jdbc/12.8.1.jre8/mssql-jdbc-12.8.1.jre8.jar` |

Check the driver on your workstation (PowerShell): `Get-FileHash .\mssql-jdbc-12.8.1.jre8.jar` must be
`44F217B1D67D22442002EE2D1C4AB8E86358606A787B95EEB5301F235482A2AB`.

## 1. Create the service account

```bash
useradd -m -s /bin/bash mosetl
```

## 2. Create folders

```bash
mkdir -p /opt/mos/brokermaster/{classes,lib,archive} /var/log/mos
chown -R mosetl:mosetl /opt/mos/brokermaster /var/log/mos
chmod 750 /opt/mos/brokermaster
```

## 3. Copy the files to the server

With WinSCP (or `scp`), copy into `/opt/mos/brokermaster/`:

| File | Destination |
|---|---|
| `run_brokermaster.sh` | `/opt/mos/brokermaster/` |
| `.env.example` | `/opt/mos/brokermaster/` (rename if the download dropped the leading dot) |
| `brokermaster-loader.jar` (pre-compiled for Java 8) | `/opt/mos/brokermaster/lib/` |
| `mssql-jdbc-12.8.1.jre8.jar` | `/opt/mos/brokermaster/lib/` |

Then fix Windows line endings and ownership, and check both jars:

```bash
cd /opt/mos/brokermaster
sed -i 's/\r$//' run_brokermaster.sh .env.example
chown -R mosetl:mosetl /opt/mos/brokermaster
chmod 750 run_brokermaster.sh
sha256sum lib/*.jar
```

| Jar | SHA-256 |
|---|---|
| `brokermaster-loader.jar` | `23d78f0bc7450a823c44a2e5ec042c88805f49923b15dfe191184c382ad56ea9` |
| `mssql-jdbc-12.8.1.jre8.jar` | `44f217b1d67d22442002ee2d1c4ab8e86358606a787b95eeb5301f235482a2ab` |

## 4. Check Java 8

Nothing to compile on the server: the loader jar is already built for Java 8 (`javac` is not executable on this server).

On this server `/usr/java/latest` and `/usr/java/default` point to **Java 6** and the default `java` is Java 7. Neither can run the loader. The Java 8 runtimes are:

```bash
ls -l /usr/java/jdk1.8.0_291-amd64/jre/bin/java /usr/java/jdk1.8.0_291-amd64/bin/java /usr/java/jre1.8.0_281/bin/java
su - mosetl -c '/usr/java/jdk1.8.0_291-amd64/jre/bin/java -version'   # expect java version "1.8.0_291"
su - mosetl -c '/usr/java/jre1.8.0_281/bin/java -version'             # expect java version "1.8.0_281"
```

At least one must print a `1.8.0_…` version. `run_brokermaster.sh` checks them in that order, uses the first that runs and reports 1.8, and never falls back to Java 6/7. If you want to pin one, set it as `JAVA_BIN` in `.env` (step 5). If all give `Permission denied`, ask the Linux team for execute access to a Java 8 runtime.

## 5. Create `.env`

```bash
cd /opt/mos/brokermaster
cp .env.example .env
chown mosetl:mosetl .env && chmod 600 .env
vi .env
```

Set (keep the single quotes):

| Setting | Value |
|---|---|
| `DB_URL` | `'jdbc:sqlserver://<server>:1433;databaseName=<database>;encrypt=true;trustServerCertificate=true'` |
| `DB_USER` / `DB_PASSWORD` | The SQL login from step 0 |
| `BROKER_TABLE` | `'dbo.BROKERMASTER'` |
| `BROKER_ID_MODE` | `'identity'` (confirmed: `ID` is IDENTITY) |
| `BROKER_MODIFIED_COLUMN` | `'DATEMODIFIED'`, only once the column exists (step 0). Leave empty to turn the feature off |
| `BROKER_ARCHIVE_DIR` / `BROKER_STATE_FILE` | Leave as in the example (`/opt/mos/brokermaster/...`) |

## 6. Check access

```bash
# Source file readable by the service account
su - mosetl -c 'test -r "/usr/local/mos/brokerinformation/Master Broker Channel List.XLSX" && echo FILE OK'

# SQL Server port reachable (replace host)
timeout 5 bash -c '</dev/tcp/<server>/1433' && echo PORT OK
```

If the file check fails: `ls -l /usr/local/mos/brokerinformation/` and give `mosetl` read access, e.g. add it to the folder's group (`usermod -a -G <group> mosetl`) and make sure the file is group-readable.

## 7. Dry run (changes nothing)

```bash
su - mosetl -c '/opt/mos/brokermaster/run_brokermaster.sh --dry-run --force; echo "exit=$?"'
tail -20 /var/log/mos/brokermaster_load.log
ls -t /var/log/mos/brokermaster_exceptions_*.csv | head -1
```

| Check | Expect |
|---|---|
| Exit code | `0`, or `2` if rows went to the exceptions CSV |
| `Read ...: N unique CPSCODE rows` | About 1,550 |
| `section heading 'REMOVED FROM PMPP' skipped` | Present |
| `DRY RUN (rolled back) ... inserted=, updated=, unchanged=` | `inserted` small; `unchanged` + `updated` ≈ rows in table |
| `in_db_not_in_file` | Close to 0 |
| Exceptions CSV | Review the duplicates and rejected rows |

Stop here if the numbers look wrong; nothing has been changed.

## 8. First real run

```bash
su - mosetl -c '/opt/mos/brokermaster/run_brokermaster.sh --force; echo "exit=$?"'
tail -5 /var/log/mos/brokermaster_load.log
```

Verify in SQL:

```sql
SELECT COUNT(*) AS total_rows, COUNT(DISTINCT CPSCODE) AS unique_codes FROM dbo.BROKERMASTER;  -- must be equal
SELECT TOP 20 * FROM dbo.BROKERMASTER ORDER BY ID DESC;                                        -- newly inserted rows
SELECT DATEMODIFIED, COUNT(*) AS row_count FROM dbo.BROKERMASTER GROUP BY DATEMODIFIED ORDER BY DATEMODIFIED DESC;
-- one timestamp per run that changed rows; NULL = not changed since tracking started
```

Run it again without `--force`: the log should say `unchanged since last load; nothing to do`.

## 9. Schedule

```bash
crontab -u mosetl -e
```

Add (weekdays at 6:15 AM; change the time to suit):

```cron
MAILTO=your.email@bank.com
15 6 * * 1-5  /opt/mos/brokermaster/run_brokermaster.sh
```

Cron only emails when there are warnings or errors. Confirm the server can send external mail (`echo test | mail -s test your.email@bank.com`); if not, check the log daily or ask the Linux team to set up a mail relay.

## 10. Turn off the old process

Disable the existing delete/reload job so the two loads don't overwrite each other.

## 11. Log rotation

```bash
cat > /etc/logrotate.d/brokermaster <<'EOF'
/var/log/mos/brokermaster_load.log {
    monthly
    rotate 12
    compress
    missingok
    notifempty
    create 0640 mosetl mosetl
}
EOF
```

Optional: clean up old exceptions CSVs and archive copies by adding this line to the same crontab:

```cron
30 6 * * 0  find /var/log/mos -name 'brokermaster_exceptions_*.csv' -mtime +90 -delete; find /opt/mos/brokermaster/archive -mtime +365 -delete
```

## Rollback

| Step | Command |
|---|---|
| Stop the job | `crontab -u mosetl -e` and comment out the line |
| Restore data (DBA) | Restore `dbo.BROKERMASTER` from `dbo.BROKERMASTER_BAK_20261014` |
| Re-enable the old process | As before |

## Troubleshooting

| Error in the log | Fix |
|---|---|
| `UnsupportedClassVersionError` | Ran with Java 7. Set `JAVA_BIN` in `.env` to the Java 8 path |
| `Permission denied` running `java` | See step 4 |
| `Could not find or load main class BrokerMasterLoader` | `brokermaster-loader.jar` is missing from `lib/` |
| `/bin/bash^M: bad interpreter` | Windows line endings: rerun the `sed` command in step 3 |
| `DB_URL is not set` | `.env` missing or not readable by `mosetl` |
| `The TCP/IP connection to the host ... has failed` | Wrong server/port, or firewall. Recheck step 6 |
| `Login failed for user` | Wrong `DB_USER`/`DB_PASSWORD`, or SQL authentication disabled on the server |
| `SSL` / `TLS` / `PKIX` errors | Keep `trustServerCertificate=true`, or ask the DBA whether the server supports TLS 1.2 |
| `Missing column(s)` | A heading in the Excel file changed. The error lists the headings found |
| `appears more than once (check hidden columns)` | Duplicate heading, often in hidden columns J–P |
| `already has duplicate CPSCODE` | Clean up duplicates in `BROKERMASTER` first |
| `already has duplicate CPSCODE` but the table looks empty in DBeaver | The loader is connected elsewhere. Compare the log's `Connected to server=… database=…` with `SELECT @@SERVERNAME, DB_NAME()` in DBeaver. For a named instance (`HOST\INSTANCE`), put that instance's port in `DB_URL`, or use `;instanceName=…` |
| Job never runs | `grep CROND /var/log/cron`; check `crontab -u mosetl -l` |
