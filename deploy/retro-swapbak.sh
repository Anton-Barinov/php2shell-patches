#!/usr/bin/env bash
# retro-swapbak.sh <X.Y>
#
# Backfills the .swapbak config backups on hosts that were ALREADY swapped
# by an older swap-system-php.sh version (which kept no config backups), so
# that deploy/restore-system-php.sh can roll the version back completely.
#
# Reconstructs the pre-swap state from the current state — the old script's
# edits were one-way, deterministic seds, so reversing them is exact:
#   mods-available/*.ini : `;disabled-by-swap extension=` -> `extension=`
#   php-fpm unit         : Type=exec -> Type=notify
#
# WARNING about the unit: only run this on hosts where the swap script
# actually performed that sed (its guard was `Type=notify`, and every
# Debian/sury php-fpm unit ships Type=notify — that is the only reason
# `Type=exec` in the unit means "we changed it"). On a host whose unit was
# Type=exec before any swap, the backfilled .swapbak would be wrong and
# restoring it would hang systemd against a vanilla php-fpm — delete that
# one .swapbak in this case.
#
# Never overwrites an existing .swapbak (the first swap owns it) → idempotent.
set -euo pipefail

XY="${1:?usage: retro-swapbak.sh <X.Y>}"
case "$XY" in *.*.*) XY="${XY%.*}";; esac   # accept 7.3.33 too
[[ "$XY" =~ ^[0-9]+\.[0-9]+$ ]] || { echo "FATAL: invalid PHP version" >&2; exit 1; }
n=0

shopt -s nullglob
for ini in /etc/php/"$XY"/mods-available/*.ini; do
  grep -q '^;disabled-by-swap extension=' "$ini" || continue
  [ -e "$ini.swapbak" ] && { echo "keep:  $ini.swapbak exists"; continue; }
  sed 's/^;disabled-by-swap extension=/extension=/' "$ini" > "$ini.swapbak"
  echo "swapbak: $ini.swapbak"
  n=$((n + 1))
done

UNIT="/lib/systemd/system/php$XY-fpm.service"
if [ -f "$UNIT" ] && grep -q '^Type=exec' "$UNIT"; then
  if [ -e "$UNIT.swapbak" ]; then
    echo "keep:  $UNIT.swapbak exists"
  else
    sed 's/^Type=exec/Type=notify/' "$UNIT" > "$UNIT.swapbak"
    echo "swapbak: $UNIT.swapbak"
    n=$((n + 1))
  fi
fi

echo "retro-swapbak php$XY: $n file(s) backfilled"
