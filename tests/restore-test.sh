#!/bin/bash
# Unit-tests deploy/restore-system-php.sh end-to-end: rewrites the absolute
# system paths (/usr/bin, /usr/sbin, /etc/php, /lib/systemd/system) into a
# throw-away sandbox, runs the REAL script (including its `set -euo
# pipefail` and argument handling) against prepared fake binaries, fake
# configs and a fake systemctl. Works on macOS bash 3.2 and Linux bash.
# Exit != 0 on any failure.
set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/deploy/restore-system-php.sh"
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
assert_hasnt() { # desc needle file
  if grep -q -- "$2" "$3"; then tfaill "$1 — [$2] unexpectedly present"; else pass "$1"; fi
}
assert_exists() { # desc path
  if [ -e "$2" ]; then pass "$1"; else tfaill "$1 — missing: $2"; fi
}
assert_gone() { # desc path
  if [ -e "$2" ]; then tfaill "$1 — still exists: $2"; else pass "$1"; fi
}

XY=7.3
D_OLD=distro-binary-contents
D_NEW=swapped-binary-contents
INI_ORIG='extension=mysqli.so'
INI_MARKED=';disabled-by-swap extension=mysqli.so'
UNIT_ORIG='[Service]
Type=notify
ExecStart=/usr/sbin/php-fpm7.3 --nodaemonize'
UNIT_SWAPPED='[Service]
Type=exec
ExecStart=/usr/sbin/php-fpm7.3 --nodaemonize'

# new_sandbox: fake system tree + fake systemctl + restored-path copy of the
# script. Env knobs consumed by the fakes:
#   FAKE_FPM_RC             -t exit code (default 0)
#   FAKE_ISACTIVE_CALL1_RC  exit of the 1st is-active call (default 0)
#   FAKE_ISACTIVE_CALL2_RC  exit of the 2nd is-active call (default 0)
new_sandbox() {
  local t
  t="$(mktemp -d "${TMPDIR:-/tmp}/rst.XXXXXX")"
  mkdir -p "$t/usr/bin" "$t/usr/sbin" "$t/etc/php/$XY/mods-available" \
           "$t/lib/systemd/system" "$t/bin"
  # binaries: newest bak = first swap, oldest bak = untouched distro.
  # php/php-cgi stay plain text (the script never executes them); php-fpm IS
  # executed at section 3 (`php-fpm -t`) — first as the "current" fake, then
  # as the restored backup — so every fpm file must be executable with a
  # shebang and honour FAKE_FPM_RC.
  printf '%s\n' "$D_NEW" > "$t/usr/bin/php$XY"
  printf '%s\n' "$D_NEW" > "$t/usr/bin/php-cgi$XY"
  printf '%s\n' "$D_OLD" > "$t/usr/bin/php$XY.bak-20260101000000"
  printf '%s\n' "$D_NEW#first-swap" > "$t/usr/bin/php$XY.bak-20261022000000"
  printf '%s\n' "$D_OLD" > "$t/usr/sbin/php-fpm$XY.bak-20260101000000"
  printf '%s\n' "$D_OLD" > "$t/usr/bin/php-cgi$XY.bak-20260101000000"
  # fpm -t / cgi -v fakes (the "current" binaries)
  printf '#!/bin/sh\n# fake-current-fpm\nexit "${FAKE_FPM_RC:-0}"\n' > "$t/usr/sbin/php-fpm$XY"
  printf '#!/bin/sh\nexit 0\n' > "$t/usr/bin/php-cgi$XY"
  printf '#!/bin/sh\n# distro-fpm\nexit "${FAKE_FPM_RC:-0}"\n' > "$t/usr/sbin/php-fpm$XY.bak-20260101000000"
  printf '#!/bin/sh\n# first-swap-fpm\nexit 0\n' > "$t/usr/sbin/php-fpm$XY.bak-20261022000000"
  chmod +x "$t/usr/sbin/php-fpm$XY" "$t/usr/bin/php-cgi$XY" \
           "$t"/usr/sbin/php-fpm$XY.bak-*
  # configs
  printf '%s\n' "$INI_MARKED" > "$t/etc/php/$XY/mods-available/mysqli.ini"
  printf '%s\n' "$INI_ORIG"   > "$t/etc/php/$XY/mods-available/mysqli.ini.swapbak"
  printf 'extension_dir=/usr/lib/php/x\n' > "$t/etc/php/$XY/mods-available/00-swap-extension-dir.ini"
  printf 'zend_extension=/x.so\n' > "$t/etc/php/$XY/mods-available/10-ioncube-loader.ini"
  # fpm unit (swapped) + its backup
  printf '%s\n' "$UNIT_SWAPPED" > "$t/lib/systemd/system/php$XY-fpm.service"
  printf '%s\n' "$UNIT_ORIG"    > "$t/lib/systemd/system/php$XY-fpm.service.swapbak"
  # fake systemctl: logs every call; is-active exit is phase-controlled
  cat > "$t/bin/systemctl" <<'EOF'
#!/bin/sh
echo "$@" >> "$FAKE_LOG"
if [ "$1" = "is-active" ]; then
  n=$(cat "$FAKE_COUNT" 2>/dev/null || echo 0); n=$((n + 1))
  echo "$n" > "$FAKE_COUNT"
  case "$n" in
    1) exit "${FAKE_ISACTIVE_CALL1_RC:-0}" ;;
    2) exit "${FAKE_ISACTIVE_CALL2_RC:-0}" ;;
    *) exit 0 ;;
  esac
fi
exit 0
EOF
  chmod +x "$t/bin/systemctl"
  : > "$t/log"
  # sandboxed copy of the real script
  sed -e "s|/usr/bin/php|$t/usr/bin/php|g" \
      -e "s|/usr/sbin/php-fpm|$t/usr/sbin/php-fpm|g" \
      -e "s|/etc/php|$t/etc/php|g" \
      -e "s|/lib/systemd/system|$t/lib/systemd/system|g" \
      -e "s|sleep 1|sleep 0|" \
      "$SCRIPT" > "$t/restore.sh"
  printf '%s\n' "$t"
}

run() { # $1=root, rest = args for the script
  local t="$1"; shift
  PATH="$t/bin:$PATH" FAKE_LOG="$t/log" FAKE_COUNT="$t/count" \
    bash "$t/restore.sh" "$@"
}

# --- T1: full happy path — oldest bak wins, configs/unit restored -----------
T="$(new_sandbox)"
run "$T" "$XY" > "$T/out" 2>&1; rc=$?
assert_rc "T1 exit 0" 0 "$rc"
assert_eq "T1 php binary restored from OLDEST bak (distro)" "$D_OLD" "$(cat "$T/usr/bin/php$XY")"
assert_has "T1 fpm restored from oldest (distro) bak" "# distro-fpm" "$T/usr/sbin/php-fpm$XY"
assert_hasnt "T1 fpm NOT taken from the newer first-swap bak" "# first-swap-fpm" "$T/usr/sbin/php-fpm$XY"
assert_eq "T1 cgi binary restored from oldest bak" "$D_OLD" "$(cat "$T/usr/bin/php-cgi$XY")"
assert_eq "T1 ini restored from .swapbak" "$INI_ORIG" "$(cat "$T/etc/php/$XY/mods-available/mysqli.ini")"
assert_eq "T1 unit restored to Type=notify" "notify" "$(sed -n 's/^Type=//p' "$T/lib/systemd/system/php$XY-fpm.service")"
assert_gone "T1 ours 00-swap ini removed" "$T/etc/php/$XY/mods-available/00-swap-extension-dir.ini"
assert_gone "T1 ours ioncube mirror removed" "$T/etc/php/$XY/mods-available/10-ioncube-loader.ini"
assert_has "T1 stopped fpm before cp" "stop php$XY-fpm" "$T/log"
assert_has "T1 daemon-reloaded" "daemon-reload" "$T/log"
assert_has "T1 restarted fpm" "restart php$XY-fpm" "$T/log"
assert_has "T1 printed RESTORED" "RESTORED php$XY" "$T/out"
rm -rf "$T"

# --- T2: no backups at all → refuse, nothing touched ------------------------
T="$(new_sandbox)"
rm -f "$T"/usr/bin/php$XY.bak-* "$T"/usr/sbin/php-fpm$XY.bak-* "$T"/usr/bin/php-cgi$XY.bak-*
run "$T" "$XY" > "$T/out" 2>&1; rc=$?
assert_rc "T2 no-backup exit 1" 1 "$rc"
assert_has "T2 FATAL message" "nothing to restore" "$T/out"
assert_eq "T2 php binary untouched" "$D_NEW" "$(cat "$T/usr/bin/php$XY")"
assert_hasnt "T2 no systemctl call at all (not even stop)" "is-active" "$T/log"
assert_hasnt "T2 no RESTORED" "RESTORED" "$T/out"
rm -rf "$T"

# --- T3: --dry-run changes nothing ------------------------------------------
T="$(new_sandbox)"
run "$T" "$XY" --dry-run > "$T/out" 2>&1; rc=$?
assert_rc "T3 dry-run exit 0" 0 "$rc"
assert_eq "T3 binary untouched" "$D_NEW" "$(cat "$T/usr/bin/php$XY")"
assert_eq "T3 ini untouched" "$INI_MARKED" "$(cat "$T/etc/php/$XY/mods-available/mysqli.ini")"
assert_eq "T3 unit untouched" "exec" "$(sed -n 's/^Type=//p' "$T/lib/systemd/system/php$XY-fpm.service")"
assert_exists "T3 00-swap still present" "$T/etc/php/$XY/mods-available/00-swap-extension-dir.ini"
assert_exists "T3 ioncube mirror still present" "$T/etc/php/$XY/mods-available/10-ioncube-loader.ini"
assert_hasnt "T3 no stop" "stop php$XY-fpm" "$T/log"
assert_hasnt "T3 no restart" "restart php$XY-fpm" "$T/log"
assert_hasnt "T3 no daemon-reload" "daemon-reload" "$T/log"
assert_has "T3 DRY-RUN OK" "DRY-RUN OK" "$T/out"
rm -rf "$T"

# --- T4: missing fpm backup aborts the entire rollback before changes -----------------
T="$(new_sandbox)"
rm -f "$T"/usr/sbin/php-fpm$XY.bak-*
run "$T" "$XY" > "$T/out" 2>&1; rc=$?
assert_rc "T4 missing fpm bak exit 1" 1 "$rc"
assert_has "T4 fpm binary untouched (still the fake)" "# fake-current-fpm" "$T/usr/sbin/php-fpm$XY"
assert_eq "T4 php binary untouched" "$D_NEW" "$(cat "$T/usr/bin/php$XY")"
assert_has "T4 refusal message" "rollback aborted before changes" "$T/out"
assert_hasnt "T4 no service stop" "stop php$XY-fpm" "$T/log"
rm -rf "$T"

# --- T5: service was not running → no stop, but restart + active ------------
T="$(new_sandbox)"
FAKE_ISACTIVE_CALL1_RC=3 run "$T" "$XY" > "$T/out" 2>&1; rc=$?
assert_rc "T5 exit 0 (was stopped, ends active)" 0 "$rc"
assert_hasnt "T5 no stop for a non-running service" "stop php$XY-fpm" "$T/log"
assert_has "T5 still restarted" "restart php$XY-fpm" "$T/log"
assert_has "T5 RESTORED" "RESTORED php$XY" "$T/out"
rm -rf "$T"

# --- T6: full-version argument (7.3.33) is normalized -----------------------
T="$(new_sandbox)"
run "$T" "$XY.33" > "$T/out" 2>&1; rc=$?
assert_rc "T6 '7.3.33' arg exit 0" 0 "$rc"
assert_eq "T6 restored the 7.3 binary" "$D_OLD" "$(cat "$T/usr/bin/php$XY")"
rm -rf "$T"

# --- T7: unit not active after restore → FATAL ------------------------------
T="$(new_sandbox)"
FAKE_ISACTIVE_CALL2_RC=3 run "$T" "$XY" > "$T/out" 2>&1; rc=$?
assert_rc "T7 inactive-after-restore exit 1" 1 "$rc"
assert_has "T7 FATAL message" "not active after restore" "$T/out"
rm -rf "$T"

# --- T8: fpm -t fails → best-effort start, then FATAL -----------------------
T="$(new_sandbox)"
FAKE_FPM_RC=1 run "$T" "$XY" > "$T/out" 2>&1; rc=$?
assert_rc "T8 failing fpm -t exit 1" 1 "$rc"
assert_has "T8 WARN best-effort start" "trying to start anyway" "$T/out"
assert_has "T8 start was attempted" "start php$XY-fpm" "$T/log"
assert_has "T8 FATAL reports fpm -t" "php-fpm$XY -t failed after restore" "$T/out"
rm -rf "$T"

# --- T9: a deleted binary with a valid backup is restored ------------------
T="$(new_sandbox)"
rm "$T/usr/bin/php-cgi$XY"
run "$T" "$XY" > "$T/out" 2>&1; rc=$?
assert_rc "T9 deleted binary restored exit 0" 0 "$rc"
assert_eq "T9 cgi recreated from backup" "$D_OLD" "$(cat "$T/usr/bin/php-cgi$XY")"
rm -rf "$T"

if [ "$FAIL" -eq 0 ]; then
  echo "ALL RESTORE-SYSTEM-PHP TESTS PASSED (9 scenarios)"
else
  echo "RESTORE-SYSTEM-PHP TESTS FAILED"
fi
exit "$FAIL"
