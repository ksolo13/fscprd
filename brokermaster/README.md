# BROKERMASTER loader

Loads `/usr/local/mos/brokerinformation/Master Broker Channel List.XLSX` into `BROKERMASTER`, matching rows on `CPSCODE` (update if found, insert if new). Runs from cron on Linux.

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

Header matching ignores line breaks, extra spaces and case, so the wrapped headers in the file match.

## Rules

| Situation | Action |
|---|---|
| Duplicate `CPSCODE` in the file | Keep the row with `ADDED` filled and `REMOVED` blank; if there's still a tie, keep the latest `ADDED`, then the first row in the file. The other rows go to the exceptions CSV |
| `CPSCODE` not yet in the table | Insert |
| `CPSCODE` in the table, values changed | Update |
| `CPSCODE` in the table but not in the file | Left unchanged (count logged) |
| Blank `CPSCODE` | Rejected (exceptions CSV) |
| Date cell is `N/A`, `NA`, `NULL` or blank | Loaded as `NULL` |
| Date cell has other text (e.g. `TBD`) | Row rejected (exceptions CSV) |
| `BROKERMASTER` already has duplicate `CPSCODE`s | Load stops, nothing changed |
| File unchanged since last successful load (SHA-256) | Skipped (`--force` to reload) |
| File modified less than 2 minutes ago | Skipped until the next run (may still be copying) |
| Any error | Whole load rolled back |

## Install

```bash
sudo mkdir -p /opt/mos/brokermaster /var/log/mos
sudo cp load_brokermaster.py requirements.txt /opt/mos/brokermaster/
cd /opt/mos/brokermaster
python3 -m venv venv && venv/bin/pip install -r requirements.txt
cp /path/to/.env.example .env && chmod 600 .env   # then edit DB_URL, BROKER_ID_MODE
```

Set `BROKER_ID_MODE` to match how `ID` is generated:

| `ID` column is... | `BROKER_ID_MODE` |
|---|---|
| IDENTITY / auto-increment | `identity` |
| Filled from a sequence | `BROKERMASTER_SEQ.NEXTVAL` (Oracle) or `NEXT VALUE FOR dbo.BROKERMASTER_SEQ` (SQL Server) |
| Neither (plain number) | `max` (uses MAX(ID)+1; only safe if nothing else inserts at the same time) |

Recommended: add a unique index on `CPSCODE` so the database enforces no duplicates.

## Test, then schedule

```bash
cd /opt/mos/brokermaster
set -a; . ./.env; set +a
venv/bin/python load_brokermaster.py --dry-run --force   # validates and rolls back
tail /var/log/mos/brokermaster_load.log
```

`crontab -e` (every weekday at 6:15 AM; cron emails `MAILTO` only on warnings and errors):

```cron
MAILTO=mos-support@yourbank.com
15 6 * * 1-5  cd /opt/mos/brokermaster && set -a && . ./.env && set +a && flock -n /tmp/brokermaster.lock venv/bin/python load_brokermaster.py
```

## Outputs

| Output | Location |
|---|---|
| Run log | `/var/log/mos/brokermaster_load.log` |
| Rejected and de-duplicated rows | `/var/log/mos/brokermaster_exceptions_<timestamp>.csv` |
| Copy of each loaded file | `/usr/local/mos/brokerinformation/archive/` |
| Exit code | `0` OK or nothing to do · `1` failed (rolled back) · `2` loaded with rejected rows |
