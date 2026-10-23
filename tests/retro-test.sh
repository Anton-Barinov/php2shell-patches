#!/bin/bash
# Unit-tests deploy/retro-swapbak.sh: rewrites the absolute paths
# (/etc/php, /lib/systemd/system) into a throw-away sandbox and runs the
# real script against prepared configs. Works on macOS bash 3.2 and Linux
# bash. Exit != 0 on any failure.
set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/deploy/retro-swapbak.sh"
[ -f "$SCRIPT" ] || { echo "FATAL: $SCRIPT not found"; exit 2; }

FAIL=0
pass() { echo "PASS: $1"; }
tfaill() { echo "FAIL: $1"; FAIL=1; }

assert_rc() { # desc expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else tfaill "$1 — expected rc $2, got $3"; fi
}
assert_eq() { # desc expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else tfaill "$1 — expected [$2], got [$3]"; fi
}
assert_has() { # desc needle file
  if grep -q -- "$2" "$3"; then pass "$1"; else tfaill "$1 — [$2] not found in $3"; fi
}
assert_exists() { # desc path
  if [ -e "$2" ]; then pass "$1"; else tfaill "$1 — missing: $2"; fi
}
assert_gone() { # desc path
  if [ -e "$2" ]; then tfaill "$1 — still exists: $2"; else pass "$1"; fi
}

XY=7.3

# new_sandbox $1=mode: marked  — 4 disabled inis + exec unit (swapped host)
#                      clean   — untouched distro configs
new_sandbox() {
  local t mode="$1"
  t="$(mktemp -d "${TMPDIR:-/tmp}/retro.XXXXXX")"
  mkdir -p "$t/etc/php/$XY/mods-available" "$t/lib/systemd/system"
  if [ "$mode" = "marked" ]; then
    local m
    for m in dom mysqlnd pdo xml; do
      printf ';disabled-by-swap extension=%s.so\nzend.enable_gc=1\n' "$m" \
        > "$t/etc/php/$XY/mods-available/$m.ini"
    done
    printf '[Unit]\nDescription=x\n\n[Service]\nType=exec\nExecStart=/sbin/php-fpm\n' \
      > "$t/lib/systemd/system/php$XY-fpm.service"
  else
    printf 'extension=dom.so\n' > "$t/etc/php/$XY/mods-available/dom.ini"
    printf '[Service]\nType=notify\n' > "$t/lib/systemd/system/php$XY-fpm.service"
  fi
  printf '%s\n' "$t"
}

run() { # $1=root, rest = args
  local t="$1"; shift
  sed -e "s|/etc/php|$t/etc/php|g" -e "s|/lib/systemd/system|$t/lib/systemd/system|g" \
    "$SCRIPT" | bash -s -- "$@"
}

# --- T1: swapped host → inis + unit backfilled, exact reversal --------------
T="$(new_sandbox marked)"
run "$T" "$XY" > "$T/out" 2>&1; rc=$?
assert_rc "T1 exit 0" 0 "$rc"
assert_eq "T1 mysqli-style reversal (extension= line)" \
  "extension=dom.so
zend.enable_gc=1" \
  "$(cat "$T/etc/php/$XY/mods-available/dom.ini.swapbak")"
assert_eq "T1 current ini untouched" \
  ";disabled-by-swap extension=dom.so
zend.enable_gc=1" \
  "$(cat "$T/etc/php/$XY/mods-available/dom.ini")"
assert_eq "T1 unit backfilled to Type=notify" "notify" \
  "$(sed -n 's/^Type=//p' "$T/lib/systemd/system/php$XY-fpm.service.swapbak")"
assert_eq "T1 current unit untouched" "exec" \
  "$(sed -n 's/^Type=//p' "$T/lib/systemd/system/php$XY-fpm.service")"
assert_has "T1 counts 5 files" "5 file(s) backfilled" "$T/out"
rm -rf "$T"

# --- T2: rerun is idempotent — first state wins, "keep" reported -----------
T="$(new_sandbox marked)"
run "$T" "$XY" > /dev/null 2>&1
# tamper with the current state so a wrong rerun would be visible
printf ';disabled-by-swap extension=dom.so\nCHANGED=LATER\n' \
  > "$T/etc/php/$XY/mods-available/dom.ini"
run "$T" "$XY" > "$T/out" 2>&1; rc=$?
assert_rc "T2 rerun exit 0" 0 "$rc"
assert_has "T2 reports keep" "keep:" "$T/out"
assert_has "T2 nothing backfilled" "0 file(s) backfilled" "$T/out"
assert_eq "T2 first backup not clobbered" \
  "extension=dom.so
zend.enable_gc=1" \
  "$(cat "$T/etc/php/$XY/mods-available/dom.ini.swapbak")"
rm -rf "$T"

# --- T3: distro host (unmarked inis, notify unit) → no-op ------------------
T="$(new_sandbox clean)"
run "$T" "$XY" > "$T/out" 2>&1; rc=$?
assert_rc "T3 clean host exit 0" 0 "$rc"
assert_has "T3 nothing backfilled" "0 file(s) backfilled" "$T/out"
assert_gone "T3 no ini swapbak" "$T/etc/php/$XY/mods-available/dom.ini.swapbak"
assert_gone "T3 no unit swapbak" "$T/lib/systemd/system/php$XY-fpm.service.swapbak"
rm -rf "$T"

# --- T4: version without installs → no-op, no crash ------------------------
T="$(new_sandbox marked)"
rm -rf "$T/etc/php/9.9"
run "$T" "9.9" > "$T/out" 2>&1; rc=$?
assert_rc "T4 absent version exit 0" 0 "$rc"
assert_has "T4 nothing backfilled" "0 file(s) backfilled" "$T/out"
rm -rf "$T"

# --- T5: full-version argument (7.3.33) is normalized ----------------------
T="$(new_sandbox marked)"
run "$T" "$XY.33" > "$T/out" 2>&1; rc=$?
assert_rc "T5 '7.3.33' arg exit 0" 0 "$rc"
assert_exists "T5 backfilled into 7.3 tree" "$T/etc/php/$XY/mods-available/dom.ini.swapbak"
rm -rf "$T"

# --- T6: unit without Type=exec (Type=notify) → left alone -----------------
T="$(new_sandbox clean)"
printf 'extension=dom.so\n;disabled-by-swap extension=dom.so\n' \
  > "$T/etc/php/$XY/mods-available/dom.ini"   # marked ini, notify unit
run "$T" "$XY" > "$T/out" 2>&1; rc=$?
assert_rc "T6 exit 0" 0 "$rc"
assert_has "T6 only 1 file backfilled" "1 file(s) backfilled" "$T/out"
assert_gone "T6 notify unit gets no swapbak" "$T/lib/systemd/system/php$XY-fpm.service.swapbak"
rm -rf "$T"

if [ "$FAIL" -eq 0 ]; then
  echo "ALL RETRO-SWAPBAK TESTS PASSED (6 scenarios)"
else
  echo "RETRO-SWAPBAK TESTS FAILED"
fi
exit "$FAIL"
