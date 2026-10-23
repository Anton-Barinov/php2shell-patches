#!/bin/bash
# Tests verify/cvecheck.php and verify/run-cvecheck.sh validator.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
FAIL=0

pass() { echo "PASS: $1"; }
tfaill() { echo "FAIL: $1"; FAIL=1; }

assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else tfaill "$1 — expected [$2], got [$3]"; fi
}

# 1. Shell script syntax check
if bash -n "$REPO/verify/run-cvecheck.sh"; then
  pass "T1 run-cvecheck.sh bash syntax valid"
else
  tfaill "T1 run-cvecheck.sh bash syntax error"
fi

# 2. Driver parameter validation
USAGE_OUT=$("$REPO/verify/run-cvecheck.sh" 2>&1 || true)
if echo "$USAGE_OUT" | grep -q "usage:"; then
  pass "T2 run-cvecheck.sh validates arguments and prints usage"
else
  tfaill "T2 run-cvecheck.sh argument validation failed"
fi

# 3. PHP file syntax and logic check
if command -v php >/dev/null 2>&1; then
  # PHP lint check
  if php -l "$REPO/verify/cvecheck.php" >/dev/null 2>&1; then
    pass "T3 cvecheck.php php syntax valid"
  else
    tfaill "T3 cvecheck.php php syntax error"
  fi

  # Missing token returns forbidden
  UNAUTH_OUT=$(php -r "\$_GET = array(); include '$REPO/verify/cvecheck.php';" 2>/dev/null || true)
  if echo "$UNAUTH_OUT" | grep -q "forbidden"; then
    pass "T4 missing token returns forbidden"
  else
    tfaill "T4 missing token did not return forbidden"
  fi

  # Wrong token returns forbidden
  WRONG_OUT=$(php -r "\$_GET = array('k' => 'wrong_token'); include '$REPO/verify/cvecheck.php';" 2>/dev/null || true)
  if echo "$WRONG_OUT" | grep -q "forbidden"; then
    pass "T5 wrong token returns forbidden"
  else
    tfaill "T5 wrong token did not return forbidden"
  fi

  # Valid token with t=info returns build metadata and ok marker
  INFO_OUT=$(php -r "\$_GET = array('k' => 'CHANGE_ME', 't' => 'info'); include '$REPO/verify/cvecheck.php';" 2>/dev/null || true)
  if echo "$INFO_OUT" | grep -q "^ok$" && echo "$INFO_OUT" | grep -q "php="; then
    pass "T6 valid token returns info with ok marker and php version"
  else
    tfaill "T6 valid token did not return ok marker in info"
  fi

  # Valid token with t=multipart returns parsed post count
  MP_OUT=$(php -r "\$_GET = array('k' => 'CHANGE_ME', 't' => 'multipart'); \$_POST = array('a' => '1', 'b' => '2'); include '$REPO/verify/cvecheck.php';" 2>/dev/null || true)
  if echo "$MP_OUT" | grep -q "POST_count=2" && echo "$MP_OUT" | grep -q "^ok$"; then
    pass "T7 valid token multipart probe counts post fields accurately"
  else
    tfaill "T7 multipart probe failed"
  fi
else
  echo "PHP CLI not available; skipped PHP execution probes."
fi

if [ "$FAIL" -eq 0 ]; then
  echo "ALL CVECHECK VALIDATOR TESTS PASSED (7 checks)"
  exit 0
else
  echo "SOME CVECHECK VALIDATOR TESTS FAILED"
  exit 1
fi
