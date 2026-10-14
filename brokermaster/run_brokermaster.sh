#!/bin/bash
# Runs the BROKERMASTER loader with Java 8 (the default "java" on this server is Java 7, which cannot run it).
# Usage: run_brokermaster.sh [--dry-run] [--force] [--file PATH]
set -eu
APP_DIR="$(cd "$(dirname "$0")" && pwd)"

set -a; . "$APP_DIR/.env"; set +a

JAVA="${JAVA_BIN:-}"
if [ -z "$JAVA" ]; then
    for j in /usr/java/jre1.8.0_291-amd64/bin/java /usr/java/jdk1.8.0_291-amd64/bin/java /usr/java/latest/bin/java; do
        if [ -x "$j" ]; then JAVA="$j"; break; fi
    done
fi
if [ -z "$JAVA" ]; then
    echo "Java 8 not found; set JAVA_BIN in $APP_DIR/.env" >&2
    exit 1
fi

# flock: skip this run if the previous one is still going
exec flock -n /tmp/brokermaster.lock "$JAVA" -cp "$APP_DIR/classes:$APP_DIR/lib/*" BrokerMasterLoader "$@"
