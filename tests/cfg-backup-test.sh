#!/bin/bash
# Unit-tests the cfg-backup block of deploy/swap-system-php.sh.
# Extracts the block between the BEGIN/END markers and runs it against
# throw-away files. Works on macOS bash 3.2 and Linux bash. Exit != 0 on any
# failure.
set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/deploy/swap-system-php.sh"
BLOCK="$(sed -n '/# BEGIN cfg-backup/,/# END cfg-backup/p' "$SCRIPT")"
[ -n "$BLOCK" ] || { echo "FATAL: cfg-backup block not found in $SCRIPT"; exit 2; }

FAIL=0
pass() { echo "PASS: $1"; }
tfaill() { echo "FAIL: $1"; FAIL=1; }

assert_eq() { # desc expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else tfaill "$1 — expected [$2], got [$3]"; fi
}
assert_exists() { # desc path
  if [ -f "$2" ]; then pass "$1"; else tfaill "$1 — missing: $2"; fi
}
assert_gone() { # desc path
  if [ -e "$2" ]; then tfaill "$1 — still exists: $2"; else pass "$1"; fi
}

new_sandbox() { mktemp -d "${TMPDIR:-/tmp}/cfgbak.XXXXXX"; }

# $1=sandbox root; prints the block (needs no root rewriting: cfg_backup
# takes arbitrary paths)
block_for() { printf '%s\n' "$BLOCK"; }
run() { bash -c "$(block_for)"; }

# --- T1: existing file, no .swapbak → byte-identical backup created --------
T="$(new_sandbox)"
printf 'extension=json.so\nzend.enable_gc=1\n' > "$T/pkg.ini"
eval "$(block_for)"
cfg_backup "$T/pkg.ini"
assert_exists "T1 .swapbak created" "$T/pkg.ini.swapbak"
assert_eq "T1 backup is byte-identical to original" \
  "$(cat "$T/pkg.ini")" "$(cat "$T/pkg.ini.swapbak")"
rm -rf "$T"

# --- T2: .swapbak exists → first swap owns it, never clobbered -------------
T="$(new_sandbox)"
printf 'ORIGINAL DISTRO STATE\n' > "$T/pkg.ini"
cfg_backup "$T/pkg.ini"
printf 'extension=json.so\n;disabled-by-swap extension=json.so\n' > "$T/pkg.ini"
cfg_backup "$T/pkg.ini"   # second swap: must NOT overwrite the backup
cfg_backup "$T/pkg.ini"   # third swap: still must not
assert_eq "T2 rerun keeps the first backup" \
  "ORIGINAL DISTRO STATE" "$(cat "$T/pkg.ini.swapbak")"
rm -rf "$T"

# --- T3: missing file → no-op, exit 0, no side effects ---------------------
T="$(new_sandbox)"
run && rc=0 || rc=$?
assert_eq "T3 missing file exits 0" "0" "$rc"
assert_gone "T3 no backup for absent file" "$T/absent.ini.swapbak"
rm -rf "$T"

# --- T4: unit-style call (second arg path in another dir) ------------------
T="$(new_sandbox)"
mkdir -p "$T/lib"
printf '[Unit]\nType=notify\n' > "$T/lib/php-fpm.service"
eval "$(block_for)"
cfg_backup "$T/lib/php-fpm.service"
sed -i.baktest 's/^Type=notify/Type=exec/' "$T/lib/php-fpm.service" 2>/dev/null \
  || sed -i '' 's/^Type=notify/Type=exec/' "$T/lib/php-fpm.service"
cfg_backup "$T/lib/php-fpm.service"
assert_eq "T4 unit backup keeps Type=notify" \
  "notify" "$(sed -n 's/^Type=//p' "$T/lib/php-fpm.service.swapbak")"
rm -rf "$T"

if [ "$FAIL" -eq 0 ]; then
  echo "ALL CFG-BACKUP TESTS PASSED (4 scenarios)"
else
  echo "CFG-BACKUP TESTS FAILED"
fi
exit "$FAIL"
