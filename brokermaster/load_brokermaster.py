#!/usr/bin/env python3
"""
Load 'Master Broker Channel List.XLSX' into BROKERMASTER (upsert on CPSCODE).

Run from cron; see README.md. Exit codes:
    0  loaded, or nothing to do (file unchanged / missing / still being written)
    1  failed, nothing committed
    2  loaded, but some rows were rejected (see exceptions CSV in the log folder)
"""
import argparse
import hashlib
import logging
import os
import re
import shutil
import sys
import time
from datetime import date, datetime
from pathlib import Path

import pandas as pd
from sqlalchemy import create_engine, text

# --- Configuration (override with environment variables) ---------------------
SRC_DIR = Path(os.environ.get("BROKER_SRC_DIR", "/usr/local/mos/brokerinformation"))
SRC_FILE = os.environ.get("BROKER_SRC_FILE", "Master Broker Channel List.XLSX")
ARCHIVE_DIR = Path(os.environ.get("BROKER_ARCHIVE_DIR", str(SRC_DIR / "archive")))
STATE_FILE = Path(os.environ.get("BROKER_STATE_FILE", str(SRC_DIR / ".last_loaded.sha256")))
LOG_DIR = Path(os.environ.get("BROKER_LOG_DIR", "/var/log/mos"))
TABLE = os.environ.get("BROKER_TABLE", "BROKERMASTER")  # e.g. MYSCHEMA.BROKERMASTER
# How ID is set on insert:
#   identity -> ID column is IDENTITY / auto-increment; omit it
#   max      -> MAX(ID)+1, MAX(ID)+2, ... (only safe if nothing else inserts at the same time)
#   anything else is used as a SQL expression, e.g. BROKERMASTER_SEQ.NEXTVAL (Oracle)
#   or NEXT VALUE FOR dbo.BROKERMASTER_SEQ (SQL Server)
ID_MODE = os.environ.get("BROKER_ID_MODE", "identity")
MIN_FILE_AGE_SEC = int(os.environ.get("BROKER_MIN_FILE_AGE_SEC", "120"))

# Excel header (line breaks / extra spaces ignored, case-insensitive) -> BROKERMASTER column
COLUMN_MAP = {
    "CPS Agent or Dealer Code": "CPSCODE",
    "MATD Dealer Name or PMPP Dealer Name": "BROKERFIRM",
    "PMPP AGENT Name": "AGENT",
    "MOS Channel": "BROKERCHANNEL",
    "Date added to PMPP or Mortgage Broker Agreement Date": "ADDED",
    "Date Removed from PMPP": "REMOVED",
}
TEXT_COLS = ["CPSCODE", "BROKERFIRM", "AGENT", "BROKERCHANNEL"]
DATE_COLS = ["ADDED", "REMOVED"]
DATA_COLS = ["BROKERFIRM", "AGENT", "BROKERCHANNEL", "ADDED", "REMOVED"]  # all but the key

log = logging.getLogger("brokermaster")


# --- Helpers -----------------------------------------------------------------
def norm_header(h) -> str:
    return " ".join(str(h).split()).casefold()


def is_blank(v) -> bool:
    return v is None or (isinstance(v, float) and pd.isna(v)) or v is pd.NaT or (isinstance(v, str) and not v.strip())


def clean_text(v):
    if is_blank(v):
        return None
    if isinstance(v, float) and v.is_integer():  # 12345.0 -> "12345"
        v = int(v)
    return str(v).strip()


def to_date(v):
    """Return a date, None for blank; raise ValueError if not a date."""
    if is_blank(v):
        return None
    if isinstance(v, datetime):  # includes pd.Timestamp
        return v.date()
    if isinstance(v, date):
        return v
    if isinstance(v, (int, float)) and 1 <= v < 2958466:  # Excel serial date stored as a number
        return (pd.Timestamp("1899-12-30") + pd.Timedelta(days=float(v))).date()
    if isinstance(v, str):
        ts = pd.to_datetime(v.strip(), errors="raise")
        if pd.isna(ts):  # "N/A", "NaT", etc.
            raise ValueError(f"not a date: {v!r}")
        return ts.date()
    raise ValueError(f"not a date: {v!r}")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# --- Read, clean, de-duplicate -----------------------------------------------
def read_file(path: Path):
    """Return (clean DataFrame one row per CPSCODE, exceptions DataFrame)."""
    # pandas reads placeholders like "N/A", "NA", "NULL" as blank (-> NULL); other non-date text is rejected
    raw = pd.read_excel(path, sheet_name=0, dtype=object, engine="openpyxl")
    headers = {norm_header(c): c for c in raw.columns}
    missing = [h for h in COLUMN_MAP if norm_header(h) not in headers]
    if missing:
        raise ValueError(f"Missing column(s) in {path.name}: {missing}. Found: {list(raw.columns)}")

    df = pd.DataFrame({db: raw[headers[norm_header(x)]] for x, db in COLUMN_MAP.items()})
    df.insert(0, "EXCEL_ROW", raw.index + 2)  # header is row 1
    df = df[~df[list(COLUMN_MAP.values())].map(is_blank).all(axis=1)]  # drop fully empty rows

    exceptions = []
    for c in TEXT_COLS:
        df[c] = df[c].map(clean_text)

    bad = []
    for idx, row in df.iterrows():
        for c in DATE_COLS:
            try:
                df.at[idx, c] = to_date(row[c])
            except (ValueError, TypeError):
                bad.append(idx)
                exceptions.append({**row.to_dict(), "REASON": f"Invalid {c} date: {row[c]!r}"})
                break
    df = df.drop(index=bad)

    no_code = df["CPSCODE"].isna()
    for _, row in df[no_code].iterrows():
        exceptions.append({**row.to_dict(), "REASON": "Missing CPS Agent or Dealer Code"})
    df = df[~no_code]

    # Duplicate CPSCODE: keep ADDED populated + REMOVED empty first, then latest ADDED, then first in file
    df["_active"] = df["ADDED"].notna() & df["REMOVED"].isna()
    df["_added"] = pd.to_datetime(df["ADDED"])
    df = df.sort_values(["CPSCODE", "_active", "_added", "EXCEL_ROW"],
                        ascending=[True, False, False, True], na_position="last")
    dup = df.duplicated("CPSCODE", keep="first")
    for _, row in df[dup].iterrows():
        kept = df[(df["CPSCODE"] == row["CPSCODE"]) & ~dup]["EXCEL_ROW"].iloc[0]
        exceptions.append({**row.drop(["_active", "_added"]).to_dict(),
                           "REASON": f"Duplicate CPSCODE; kept Excel row {kept}"})
    df = df[~dup].drop(columns=["_active", "_added"]).sort_values("EXCEL_ROW")

    return df, pd.DataFrame(exceptions)


# --- Database ----------------------------------------------------------------
def make_engine():
    url = os.environ.get("DB_URL")
    if not url:
        raise RuntimeError("DB_URL is not set (see .env.example)")
    kwargs = {"fast_executemany": True} if url.startswith("mssql+pyodbc") else {}
    return create_engine(url, **kwargs)


def norm_db(col, v):
    """Normalise a DB value the same way as the file value, so unchanged rows compare equal."""
    return to_date(v) if col in DATE_COLS else clean_text(v)


def upsert(conn, df: pd.DataFrame) -> dict:
    existing = {}
    for row in conn.execute(text(f"SELECT CPSCODE, {', '.join(DATA_COLS)} FROM {TABLE}")):
        code = clean_text(row[0])
        if code in existing:
            raise RuntimeError(f"{TABLE} already has duplicate CPSCODE {code!r}; clean it up before loading")
        existing[code] = tuple(norm_db(c, v) for c, v in zip(DATA_COLS, row[1:]))

    def params(r):
        return {"p_cpscode": r.CPSCODE, "p_firm": r.BROKERFIRM, "p_agent": r.AGENT,
                "p_channel": r.BROKERCHANNEL, "p_added": r.ADDED, "p_removed": r.REMOVED}

    inserts, updates, unchanged = [], [], 0
    for r in df.itertuples(index=False):
        new_vals = tuple(getattr(r, c) for c in DATA_COLS)
        if r.CPSCODE not in existing:
            inserts.append(params(r))
        elif existing[r.CPSCODE] != new_vals:
            updates.append(params(r))
        else:
            unchanged += 1

    if updates:
        conn.execute(text(
            f"UPDATE {TABLE} SET BROKERFIRM = :p_firm, AGENT = :p_agent, BROKERCHANNEL = :p_channel, "
            f"ADDED = :p_added, REMOVED = :p_removed WHERE CPSCODE = :p_cpscode"), updates)

    if inserts:
        cols = "CPSCODE, BROKERFIRM, AGENT, BROKERCHANNEL, ADDED, REMOVED"
        vals = ":p_cpscode, :p_firm, :p_agent, :p_channel, :p_added, :p_removed"
        mode = ID_MODE.strip()
        if mode.lower() == "identity":
            sql = f"INSERT INTO {TABLE} ({cols}) VALUES ({vals})"
        elif mode.lower() == "max":
            next_id = conn.execute(text(f"SELECT COALESCE(MAX(ID), 0) FROM {TABLE}")).scalar() + 1
            for i, p in enumerate(inserts):
                p["p_id"] = next_id + i
            sql = f"INSERT INTO {TABLE} (ID, {cols}) VALUES (:p_id, {vals})"
        elif re.fullmatch(r"[\w.$# ]+", mode):
            sql = f"INSERT INTO {TABLE} (ID, {cols}) VALUES ({mode}, {vals})"
        else:
            raise RuntimeError(f"Invalid BROKER_ID_MODE: {ID_MODE!r}")
        conn.execute(text(sql), inserts)

    in_file = set(df["CPSCODE"])
    return {"inserted": len(inserts), "updated": len(updates), "unchanged": unchanged,
            "in_db_not_in_file": len(set(existing) - in_file)}


# --- Main --------------------------------------------------------------------
def setup_logging():
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
    fh = logging.FileHandler(LOG_DIR / "brokermaster_load.log")
    fh.setFormatter(fmt)
    sh = logging.StreamHandler(sys.stderr)  # cron mails stderr -> only warnings/errors
    sh.setLevel(logging.WARNING)
    sh.setFormatter(fmt)
    log.setLevel(logging.INFO)
    log.addHandler(fh)
    log.addHandler(sh)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--file", type=Path, default=SRC_DIR / SRC_FILE, help="Excel file to load")
    ap.add_argument("--force", action="store_true", help="load even if the file has not changed")
    ap.add_argument("--dry-run", action="store_true", help="validate and report, then roll back")
    args = ap.parse_args()
    setup_logging()

    path: Path = args.file
    if not path.exists():
        log.info("No file at %s; nothing to do", path)
        return 0
    if time.time() - path.stat().st_mtime < MIN_FILE_AGE_SEC:
        log.info("%s modified < %ss ago; may still be copying, will retry next run", path.name, MIN_FILE_AGE_SEC)
        return 0

    file_hash = sha256(path)
    if not args.force and STATE_FILE.exists() and STATE_FILE.read_text().strip() == file_hash:
        log.info("%s unchanged since last load; nothing to do", path.name)
        return 0

    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    try:
        df, exceptions = read_file(path)
        log.info("Read %s: %d unique CPSCODE rows, %d exceptions", path.name, len(df), len(exceptions))
        if df.empty:
            raise ValueError("No valid rows in file; refusing to load")

        engine = make_engine()
        with engine.connect() as conn:
            trans = conn.begin()
            try:
                stats = upsert(conn, df)
                if args.dry_run:
                    trans.rollback()
                else:
                    trans.commit()
            except Exception:
                trans.rollback()
                raise
        log.info("%s%s: %s", "DRY RUN (rolled back) " if args.dry_run else "", TABLE, stats)
        if stats["in_db_not_in_file"]:
            log.info("%d CPSCODE(s) in %s are not in the file; left unchanged", stats["in_db_not_in_file"], TABLE)
    except Exception:
        log.exception("Load of %s FAILED; nothing committed", path)
        return 1

    if not exceptions.empty:
        out = LOG_DIR / f"brokermaster_exceptions_{stamp}.csv"
        exceptions.to_csv(out, index=False)
        log.warning("%d row(s) rejected or de-duplicated; details in %s", len(exceptions), out)

    if not args.dry_run:
        ARCHIVE_DIR.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, ARCHIVE_DIR / f"{path.stem}_{stamp}{path.suffix}")
        STATE_FILE.write_text(file_hash)

    rejected = (~exceptions["REASON"].str.startswith("Duplicate")).sum() if not exceptions.empty else 0
    return 2 if rejected else 0


if __name__ == "__main__":
    sys.exit(main())
