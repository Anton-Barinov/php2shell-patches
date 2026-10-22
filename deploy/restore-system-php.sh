#!/usr/bin/env bash
# restore-system-php.sh <X.Y> [--dry-run]
#
# Rolls back the php2shell swap of one PHP version, undoing exactly what
# deploy/swap-system-php.sh changed (see deploy/DEPLOYMENT.md P7/P5):
#
#   1. binaries: /usr/bin/phpX.Y, /usr/sbin/php-fpmX.Y, /usr/bin/php-cgiX.Y
#      from the EARLIEST *.bak-<timestamp> on disk. The first swap backed up
#      the untouched distro binary; every later swap would only back up an
#      already-swapped one, so "oldest == distro". If no binary backup exists
#      the version was never swapped by us → refuse to touch it.
#   2. configs: every <file>.swapbak written by the cfg-backup block
#      (`extension=` disable marks in mods-available/*.ini, fpm unit
#      Type=notify). Files we created over nothing (00-swap-extension-dir.ini,
#      the ioncube mirror 10-ioncube-loader.ini) have no .swapbak by design
#      and are simply removed — both are no-ops for the distro build anyway
#      (same compiled extension_dir/socket paths, the distro conf.d loader
#      ini still loads the loader on its own).
#   3. restart: systemctl daemon-reload (if the unit was restored),
#      php-fpm -t, restart, is-active.
#
# On hosts swapped by an older script version (no config backups kept)
# run deploy/retro-swapbak.sh <X.Y> first to backfill the .swapbak files.
#
# Usage:
#   ./restore-system-php.sh 7.3          # full rollback of 7.3
#   ./restore-system-php.sh 7.3 --dry-run
set -euo pipefail

XY="${1:?usage: restore-system-php.sh <X.Y> [--dry-run]}"
case "$XY" in *.*.*) XY="${XY%.*}";; esac   # accept 7.3.33 too
DRY=0
[ "${2:-}" = "--dry-run" ] && DRY=1

run() { if [ "$DRY" -eq 1 ]; then echo "DRY: $*"; else "$@"; fi; }
fail() { echo "FATAL: $*" >&2; exit 1; }

# earliest backup: expand the glob, keep existing matches, sort by the
# stamped suffix (oldest swap = distro state). Prints nothing when there is
# no match — safe under `set -e -o pipefail`.
earliest() { # "path/prefix*" -> oldest existing match
  local m
  for m in $1; do
    [ -e "$m" ] && printf '%s\n' "$m"
  done | LC_ALL=C sort | head -1
  return 0
}

echo "--- restore php$XY (dry=$DRY) ---"

# --- 1. binaries ------------------------------------------------------------
# Pre-check before touching anything: refuse a version we never swapped.
MAIN_BAK="$(earliest "/usr/bin/php$XY.bak-*")"
[ -n "$MAIN_BAK" ] || fail "no /usr/bin/php$XY.bak-* — nothing to restore for php$XY"
echo "oldest backup: $MAIN_BAK (distro state)"

# A running fpm master holds its binary open → `cp -a` fails with
# `Text file busy` (DEPLOYMENT.md P7); stop it first, restart comes last.
if command -v systemctl >/dev/null 2>&1 \
   && systemctl is-active --quiet "php$XY-fpm" 2>/dev/null; then
  echo "stop php$XY-fpm before overwriting its binary"
  run systemctl stop "php$XY-fpm"
fi

for cur in "/usr/bin/php$XY" "/usr/sbin/php-fpm$XY" "/usr/bin/php-cgi$XY"; do
  [ -e "$cur" ] || { echo "skip: $cur absent"; continue; }
  bak="$(earliest "$cur.bak-*")"
  if [ -z "$bak" ]; then
    echo "skip: no backup for $cur"
    continue
  fi
  echo "binary: $bak -> $cur"
  run cp -a "$bak" "$cur"
done

# --- 2. configs -------------------------------------------------------------
shopt -s nullglob
for bak in /etc/php/"$XY"/mods-available/*.swapbak; do
  dst="${bak%.swapbak}"
  echo "config: $bak -> $dst"
  run cp -a "$bak" "$dst"
done

# files 100% ours by name (created over nothing) → no .swapbak means
# "remove", a .swapbak means the host really had its own file → restore it
# (the *.swapbak glob above already handled that case).
for ours in /etc/php/"$XY"/mods-available/00-swap-extension-dir.ini \
            /etc/php/"$XY"/mods-available/10-ioncube-loader.ini; do
  if [ -e "$ours" ] && [ ! -e "$ours.swapbak" ]; then
    echo "config: remove ours $ours"
    run rm -f "$ours"
  fi
done

UNIT="/lib/systemd/system/php$XY-fpm.service"
if [ -e "$UNIT.swapbak" ]; then
  echo "unit: $UNIT.swapbak -> $UNIT"
  run cp -a "$UNIT.swapbak" "$UNIT"
  UNIT_RESTORED=1
  run systemctl daemon-reload
fi

# --- 3. restart + verify ----------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
  if [ "$DRY" -eq 1 ]; then
    run "/usr/sbin/php-fpm$XY" -t
    run systemctl restart "php$XY-fpm"
  elif ! "/usr/sbin/php-fpm$XY" -t; then
    # never leave the version down because of a failed config test:
    # best-effort start of the restored (distro) config, then report
    echo "WARN: php-fpm$XY -t failed after restore — trying to start anyway"
    systemctl start "php$XY-fpm" || true
    fail "php-fpm$XY -t failed after restore"
  else
    run systemctl restart "php$XY-fpm"
    sleep 1
    systemctl is-active --quiet "php$XY-fpm" || fail "php$XY-fpm not active after restore"
    echo "unit: php$XY-fpm active"
  fi
else
  echo "WARN: no systemctl — restart php$XY-fpm manually"
fi

[ "$DRY" -eq 1 ] && echo "DRY-RUN OK (nothing changed)" || echo "RESTORED php$XY"
