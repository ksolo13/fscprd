#!/bin/bash
# Runs the BROKERMASTER loader with Java 8.
# On this server the default "java" is Java 7 and /usr/java/latest (and default) is Java 6; neither can run it.
# Usage: run_brokermaster.sh [--dry-run] [--force] [--file PATH]
set -eu
APP_DIR="$(cd "$(dirname "$0")" && pwd)"

set -a; . "$APP_DIR/.env"; set +a

# Executable and reports version 1.8.x
is_java8() {
    [ -x "$1" ] && "$1" -version 2>&1 | grep -q 'version "1\.8\.'
}

JAVA_ROOT="${JAVA_ROOT:-/usr/java}"
if [ -n "${JAVA_BIN:-}" ]; then
    candidates=("$JAVA_BIN")
else
    # Newest first: the JDK's runtime (8u291), then the standalone JRE (8u281)
    candidates=("$JAVA_ROOT"/jdk1.8*/jre/bin/java "$JAVA_ROOT"/jdk1.8*/bin/java "$JAVA_ROOT"/jre1.8*/bin/java)
fi

JAVA=""
for j in "${candidates[@]}"; do
    if is_java8 "$j"; then JAVA="$j"; break; fi
done
if [ -z "$JAVA" ]; then
    echo "Java 8 not found or not executable. Tried: ${candidates[*]}" >&2
    echo "Check each with: ls -l <path>; <path> -version. Then set JAVA_BIN in $APP_DIR/.env to one that works." >&2
    exit 1
fi

# flock: skip this run if the previous one is still going
exec flock -n /tmp/brokermaster.lock "$JAVA" -cp "$APP_DIR/classes:$APP_DIR/lib/*" BrokerMasterLoader "$@"
