#!/bin/bash
# Unit-tests the ioncube-mirror block of deploy/swap-system-php.sh.
# Extracts the block between the BEGIN/END markers, rewrites the real roots
# (/etc/php, /usr/lib/php) into a throw-away sandbox and runs it against
# prepared scenarios. Works on macOS bash 3.2 and Linux bash. Exit != 0 on
# any failure.
set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/deploy/swap-system-php.sh"
BLOCK="$(sed -n '/# BEGIN ioncube-mirror/,/# END ioncube-mirror/p' "$SCRIPT")"
[ -n "$BLOCK" ] || { echo "FATAL: ioncube-mirror block not found in $SCRIPT"; exit 2; }

FAIL=0
pass() { echo "PASS: $1"; }
tfaill() { echo "FAIL: $1"; FAIL=1; }

assert_eq() { # desc expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else tfaill "$1 — expected [$2], got [$3]"; fi
}
assert_gone() { # desc path
  if [ -e "$2" ]; then tfaill "$1 — still exists: $2"; else pass "$1"; fi
}
assert_exists() { # desc path
  if [ -f "$2" ]; then pass "$1"; else tfaill "$1 — missing: $2"; fi
}

new_sandbox() { mktemp -d "${TMPDIR:-/tmp}/ionmirror.XXXXXX"; }

# $1=sandbox root; prints the block with roots rewritten into the sandbox
block_for() {
  printf '%s\n' "$BLOCK" | sed "s|/etc/php|$1/etc/php|g; s|/usr/lib/php|$1/usr/lib/php|g"
}

run() { # $1=sandbox root, $2=version, $3=api
  XY="$2" API="$3" bash -c "$(block_for "$1")"
}

XY=7.3 API=20180731
INI_REL='zend_extension=ioncube_loader_lin_7.3.so'

# --- T1: relative path + .so exists → absolute mirror, idempotent ---------
T="$(new_sandbox)"
mkdir -p "$T/etc/php/$XY/cli/conf.d" "$T/etc/php/$XY/mods-available" "$T/usr/lib/php/$API"
printf '%s\n' "$INI_REL" > "$T/etc/php/$XY/cli/conf.d/00-ioncube-loader.ini"
touch "$T/usr/lib/php/$API/ioncube_loader_lin_7.3.so"
run "$T" "$XY" "$API" || tfaill "T1 run exited non-zero"
assert_eq "T1 mirror created with absolute path" \
  "zend_extension=$T/usr/lib/php/$API/ioncube_loader_lin_7.3.so" \
  "$(cat "$T/etc/php/$XY/mods-available/10-ioncube-loader.ini" 2>/dev/null)"
run "$T" "$XY" "$API" || tfaill "T1 rerun exited non-zero"
assert_eq "T1 idempotent rerun keeps content" \
  "zend_extension=$T/usr/lib/php/$API/ioncube_loader_lin_7.3.so" \
  "$(cat "$T/etc/php/$XY/mods-available/10-ioncube-loader.ini" 2>/dev/null)"
rm -rf "$T"

# --- T2: absolute non-standard loader location, file exists → kept as is --
T="$(new_sandbox)"
mkdir -p "$T/etc/php/$XY/cli/conf.d" "$T/etc/php/$XY/mods-available" "$T/usr/local/ioncube"
ABS="$T/usr/local/ioncube/loader.so"
printf 'zend_extension=%s\n' "$ABS" > "$T/etc/php/$XY/cli/conf.d/00-ioncube-loader.ini"
touch "$ABS"
run "$T" "$XY" "$API" || tfaill "T2 run exited non-zero"
assert_eq "T2 absolute non-standard path mirrored verbatim" \
  "zend_extension=$ABS" \
  "$(cat "$T/etc/php/$XY/mods-available/10-ioncube-loader.ini" 2>/dev/null)"
rm -rf "$T"

# --- T3: distro ini present but .so missing → stale mirror removed ---------
T="$(new_sandbox)"
mkdir -p "$T/etc/php/$XY/cli/conf.d" "$T/etc/php/$XY/mods-available" "$T/usr/lib/php/$API"
printf '%s\n' "$INI_REL" > "$T/etc/php/$XY/cli/conf.d/00-ioncube-loader.ini"
printf 'zend_extension=/stale/path.so\n' > "$T/etc/php/$XY/mods-available/10-ioncube-loader.ini"
run "$T" "$XY" "$API" || tfaill "T3 run exited non-zero"
assert_gone "T3 stale mirror removed when .so missing" \
  "$T/etc/php/$XY/mods-available/10-ioncube-loader.ini"
rm -rf "$T"

# --- T4: no distro ini at all → stale mirror removed ----------------------
T="$(new_sandbox)"
mkdir -p "$T/etc/php/$XY/cli/conf.d" "$T/etc/php/$XY/mods-available"
printf 'zend_extension=/stale/path.so\n' > "$T/etc/php/$XY/mods-available/10-ioncube-loader.ini"
run "$T" "$XY" "$API" || tfaill "T4 run exited non-zero"
assert_gone "T4 mirror removed when distro has no loader ini" \
  "$T/etc/php/$XY/mods-available/10-ioncube-loader.ini"
rm -rf "$T"

# --- T5: ini only in fpm/conf.d (no cli) → still mirrored -----------------
T="$(new_sandbox)"
mkdir -p "$T/etc/php/$XY/fpm/conf.d" "$T/etc/php/$XY/mods-available" "$T/usr/lib/php/$API"
printf '%s\n' "$INI_REL" > "$T/etc/php/$XY/fpm/conf.d/00-ioncube-loader.ini"
touch "$T/usr/lib/php/$API/ioncube_loader_lin_7.3.so"
run "$T" "$XY" "$API" || tfaill "T5 run exited non-zero"
assert_eq "T5 fpm-only distro ini mirrored" \
  "zend_extension=$T/usr/lib/php/$API/ioncube_loader_lin_7.3.so" \
  "$(cat "$T/etc/php/$XY/mods-available/10-ioncube-loader.ini" 2>/dev/null)"
rm -rf "$T"

# --- T6: quoted path in distro ini → quotes stripped ----------------------
T="$(new_sandbox)"
mkdir -p "$T/etc/php/$XY/cli/conf.d" "$T/etc/php/$XY/mods-available" "$T/usr/lib/php/$API"
printf 'zend_extension="%s"\n' "ioncube_loader_lin_7.3.so" > "$T/etc/php/$XY/cli/conf.d/00-ioncube-loader.ini"
touch "$T/usr/lib/php/$API/ioncube_loader_lin_7.3.so"
run "$T" "$XY" "$API" || tfaill "T6 run exited non-zero"
assert_eq "T6 quotes stripped from path" \
  "zend_extension=$T/usr/lib/php/$API/ioncube_loader_lin_7.3.so" \
  "$(cat "$T/etc/php/$XY/mods-available/10-ioncube-loader.ini" 2>/dev/null)"
rm -rf "$T"

# --- T7: empty zend_extension value → mirror removed ----------------------
T="$(new_sandbox)"
mkdir -p "$T/etc/php/$XY/cli/conf.d" "$T/etc/php/$XY/mods-available"
printf 'zend_extension=\n' > "$T/etc/php/$XY/cli/conf.d/00-ioncube-loader.ini"
printf 'zend_extension=/stale/path.so\n' > "$T/etc/php/$XY/mods-available/10-ioncube-loader.ini"
run "$T" "$XY" "$API" || tfaill "T7 run exited non-zero"
assert_gone "T7 empty value → mirror removed" \
  "$T/etc/php/$XY/mods-available/10-ioncube-loader.ini"
rm -rf "$T"

if [ "$FAIL" -eq 0 ]; then
  echo "ALL IONCUBE-MIRROR TESTS PASSED (7 scenarios)"
else
  echo "IONCUBE-MIRROR TESTS FAILED"
fi
exit "$FAIL"
