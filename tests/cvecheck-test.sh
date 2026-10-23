#!/bin/bash
# Tests the verify/cvecheck.php and verify/run-cvecheck.sh validator.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
FAIL=0

pass() { echo "PASS: $1"; }
tfaill() { echo "FAIL: $1"; FAIL=1; }

assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else tfaill "$1 — expected [$2], got [$3]"; fi
}

if ! command -v php >/dev/null 2>&1; then
  echo "PHP CLI not available; skipping live server test."
  exit 0
fi

PORT=18991
TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'cvecheck_test')
trap 'rm -rf "$TMP_DIR"; [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null || true' EXIT

# Prepare test cvecheck.php with known token
TOKEN_VAL="cvecheck_token_dummy"
sed "s/CHANGE_ME/$TOKEN_VAL/" "$REPO/verify/cvecheck.php" > "$TMP_DIR/cvecheck.php"

# Start built-in server in background
php -S "127.0.0.1:$PORT" -t "$TMP_DIR" >/dev/null 2>&1 &
PID=$!
sleep 1

# T1: Unauthorized request without token
HTTP_UNAUTH=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/cvecheck.php")
assert_eq "T1 wrong/missing token returns 403" "403" "$HTTP_UNAUTH"

# T2: Authorized request with token returns 200 and ok
INFO_BODY=$(curl -s "http://127.0.0.1:$PORT/cvecheck.php?k=$TOKEN_VAL&t=info")
if echo "$INFO_BODY" | grep -q "^ok$"; then
  pass "T2 valid token returns info with ok marker"
else
  tfaill "T2 valid token did not return ok marker"
fi

# T3: Driver script execution
OUTPUT=$("$REPO/verify/run-cvecheck.sh" "http://127.0.0.1:$PORT/cvecheck.php" "$TOKEN_VAL" 2>&1 || true)
if echo "$OUTPUT" | grep -q "PASS - session.upload_progress.enabled"; then
  pass "T3 driver correctly reports session.upload_progress status"
else
  tfaill "T3 driver failed to parse session.upload_progress"
fi

if echo "$OUTPUT" | grep -q "PASS - parser capped parts"; then
  pass "T3 driver correctly tests multipart probe"
else
  tfaill "T3 driver failed multipart probe"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "ALL CVECHECK VALIDATOR TESTS PASSED"
  exit 0
else
  echo "SOME CVECHECK VALIDATOR TESTS FAILED"
  exit 1
fi
