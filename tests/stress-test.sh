#!/usr/bin/env bash
# stress-test.sh [path-to-php]
# Drives tests/stress.php to exercise nested arrays, memory boundaries,
# and high-volume parsing under the target PHP binary.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PHP_BIN="${1:-$(command -v php 2>/dev/null || true)}"

if [ -z "$PHP_BIN" ] || [ ! -x "$PHP_BIN" ]; then
  echo "SKIP: No executable php binary found to run stress test"
  exit 0
fi

echo "Running stress test with: $PHP_BIN"
OUT="$("$PHP_BIN" -d max_input_vars=10000 "$HERE/stress.php" 2>&1)"
RC=$?

echo "$OUT"

if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "STRESS_TEST_OK"; then
  echo "PASS: stress-test (exit 0, assertions satisfied)"
  exit 0
else
  echo "FAIL: stress-test (rc=$RC)"
  exit 1
fi
