#!/bin/bash
# Unit-tests the post-swap-smoke block of deploy/swap-system-php.sh.
# Extracts the block between the BEGIN/END markers, rewrites the absolute
# binary paths (/usr/sbin, /usr/bin) into a throw-away sandbox, runs it
# under the same `set -euo pipefail` the real script uses, and drives it
# with fake php-fpm/php-cgi/php binaries. Works on macOS bash 3.2 and
# Linux bash. Exit != 0 on any failure.
set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/deploy/swap-system-php.sh"
BLOCK="$(sed -n '/# BEGIN post-swap-smoke/,/# END post-swap-smoke/p' "$SCRIPT")"
[ -n "$BLOCK" ] || { echo "FATAL: post-swap-smoke block not found in $SCRIPT"; exit 2; }

FAIL=0
pass() { echo "PASS: $1"; }
tfaill() { echo "FAIL: $1"; FAIL=1; }

assert_rc() { # desc expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else tfaill "$1 — expected rc $2, got $3"; fi
}
assert_has() { # desc needle file
  if grep -q "$2" "$3"; then pass "$1"; else tfaill "$1 — [$2] not found in $3"; fi
}
assert_hasnt() { # desc needle file
  if grep -q "$2" "$3"; then tfaill "$1 — [$2] unexpectedly present"; else pass "$1"; fi
}

XY=7.3

new_sandbox() { # $1=no-socket(0|1) → prints root; lays out fake binaries
  local t
  t="$(mktemp -d "${TMPDIR:-/tmp}/smoke.XXXXXX")"
  mkdir -p "$t/usr/sbin" "$t/usr/bin" "$t/var/run/mysqld" "$t/etc/php/$XY/mods-available"
  cat > "$t/usr/sbin/php-fpm$XY" <<'EOF'
#!/bin/sh
echo "fpm -t: $* (rc=$FAKE_FPM_RC)"
exit "${FAKE_FPM_RC:-0}"
EOF
  cat > "$t/usr/bin/php-cgi$XY" <<'EOF'
#!/bin/sh
exit "${FAKE_CGI_RC:-0}"
EOF
  cat > "$t/usr/bin/php$XY" <<'EOF'
#!/bin/sh
case "$*" in
  *ini_get*) printf '%s\n' "$FAKE_SOCK" ;;
  *-m*)      if [ "${FAKE_IONCUBE:-1}" = 1 ]; then echo "ioncube"; else echo "core"; fi ;;
esac
exit 0
EOF
  chmod +x "$t/usr/sbin/php-fpm$XY" "$t/usr/bin/php-cgi$XY" "$t/usr/bin/php$XY"
  printf '%s\n' "$t"
}

# $1=sandbox root → prints the block with the absolute paths rewritten
block_for() {
  printf '%s\n' "$BLOCK" \
    | sed "s|/usr/sbin/php-fpm|$1/usr/sbin/php-fpm|g; s|/usr/bin/php-cgi|$1/usr/bin/php-cgi|g; s|/var/run/mysqld|$1/var/run/mysqld|g"
}

run() { # $1=root, $2=output-file; remaining env via caller's exports
  local t="$1" out="$2" ion="$3"
  PATH="$t/usr/bin:$PATH" XY="$XY" ION_DST="$ion" FAKE_SOCK="$t/var/run/mysqld/mysqld.sock" \
    bash -c "set -euo pipefail; $(block_for "$t")" > "$out" 2>&1
}

sock_up() { # $1=root — a real unix socket so `[ -S ]` passes
  FAKE_SOCK="$1/var/run/mysqld/mysqld.sock" python3 - "$1" <<'EOF' 2>/dev/null || true
import socket, sys, os
p = os.path.join(sys.argv[1], "var/run/mysqld/mysqld.sock")
try: os.unlink(p)
except OSError: pass
s = socket.socket(socket.AF_UNIX); s.bind(p)
EOF
}

# --- T1: everything healthy → rc 0, no WARN/FATAL --------------------------
T="$(new_sandbox)"; sock_up "$T"
ION="$T/etc/php/$XY/mods-available/10-ioncube-loader.ini"; printf 'zend_extension=x.so\n' > "$ION"
run "$T" "$T/out" "$ION"; rc=$?
assert_rc "T1 healthy smoke exits 0" 0 "$rc"
assert_hasnt "T1 no FATAL" "FATAL" "$T/out"
assert_hasnt "T1 no WARN" "WARN" "$T/out"
rm -rf "$T"

# --- T2: php-fpm -t fails → FATAL emitted, non-zero ------------------------
T="$(new_sandbox)"; sock_up "$T"
ION="$T/etc/php/$XY/mods-available/10-ioncube-loader.ini"; printf 'zend_extension=x.so\n' > "$ION"
FAKE_FPM_RC=1 run "$T" "$T/out" "$ION"; rc=$?
assert_rc "T2 failing fpm -t exits non-zero" 1 "$rc"
assert_has "T2 FATAL names fpm -t" "FATAL: php-fpm$XY -t" "$T/out"
rm -rf "$T"

# --- T3: php-cgi -v fails → FATAL ------------------------------------------
T="$(new_sandbox)"; sock_up "$T"
ION="$T/etc/php/$XY/mods-available/10-ioncube-loader.ini"; printf 'zend_extension=x.so\n' > "$ION"
FAKE_CGI_RC=1 run "$T" "$T/out" "$ION"; rc=$?
assert_rc "T3 failing php-cgi -v exits non-zero" 1 "$rc"
assert_has "T3 FATAL names php-cgi" "FATAL: php-cgi$XY does not run" "$T/out"
rm -rf "$T"

# --- T4: mysqli.default_socket not applied → FATAL (P10 regression) --------
T="$(new_sandbox)"; sock_up "$T"
ION="$T/etc/php/$XY/mods-available/10-ioncube-loader.ini"; printf 'zend_extension=x.so\n' > "$ION"
PATH="$T/usr/bin:$PATH" XY="$XY" ION_DST="$ION" FAKE_SOCK="/tmp/bogus.sock" \
  bash -c "set -euo pipefail; $(block_for "$T")" > "$T/out" 2>&1
rc=$?
assert_rc "T4 wrong socket exits non-zero" 1 "$rc"
assert_has "T4 FATAL names mysqli.default_socket" "FATAL: mysqli.default_socket" "$T/out"
rm -rf "$T"

# --- T5: loader ini present but php -m shows no ioncube → WARN, rc 0 ------
T="$(new_sandbox)"; sock_up "$T"
ION="$T/etc/php/$XY/mods-available/10-ioncube-loader.ini"; printf 'zend_extension=x.so\n' > "$ION"
FAKE_IONCUBE=0 run "$T" "$T/out" "$ION"; rc=$?
assert_rc "T5 missing loader in php -m still exits 0" 0 "$rc"
assert_has "T5 WARN mentions ionCube" "shows no ionCube loader" "$T/out"
rm -rf "$T"

# --- T6: no loader configured at all → no ioncube check, rc 0 -------------
T="$(new_sandbox)"; sock_up "$T"
ION="$T/etc/php/$XY/mods-available/10-ioncube-loader.ini"   # absent by design
FAKE_IONCUBE=0 run "$T" "$T/out" "$ION"; rc=$?
assert_rc "T6 no loader configured exits 0" 0 "$rc"
assert_hasnt "T6 no ioncube WARN" "ionCube" "$T/out"
rm -rf "$T"

if [ "$FAIL" -eq 0 ]; then
  echo "ALL POST-SWAP-SMOKE TESTS PASSED (6 scenarios)"
else
  echo "POST-SWAP-SMOKE TESTS FAILED"
fi
exit "$FAIL"
