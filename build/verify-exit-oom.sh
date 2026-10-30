#!/usr/bin/env bash
# Verify the repository's _exit(1) allocator behaviour, not complete CVE coverage.
# Runs only an isolated CLI process: no ini, extensions or application code.
set -eu
PHP_BIN="${1:?usage: verify-exit-oom.sh <php-cli>}"
[ -x "$PHP_BIN" ] || { echo "ERROR: PHP CLI is not executable: $PHP_BIN" >&2; exit 1; }
ERR_FILE=$(mktemp)
trap 'rm -f "$ERR_FILE"' EXIT
rc=0
out=$("$PHP_BIN" -n -d memory_limit=8M -d display_errors=stderr -d log_errors=0 -r '
register_shutdown_function(function () { echo "OOM_SHUTDOWN\n"; });
echo "OOM_BEFORE\n";
str_repeat("x", 32 * 1024 * 1024);
echo "OOM_AFTER\n";
' 2>"$ERR_FILE") || rc=$?
if [ "$rc" -ne 1 ] || [ "$out" != OOM_BEFORE ] || ! grep -q 'Allowed memory size' "$ERR_FILE"; then
    echo "ERROR: _exit OOM verification failed (exit=$rc); expected entry marker, allocation diagnostic and immediate exit 1 without request shutdown." >&2
    exit 1
fi
echo "OK: observed _exit(1) allocator behaviour"
