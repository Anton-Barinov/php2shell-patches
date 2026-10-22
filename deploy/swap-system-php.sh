#!/usr/bin/env bash
# swap-system-php.sh <full-version> [enhanced-patch-file]
#
# Builds one PHP version from the official php.net tarball (optionally
# applying a php2shell patch) and swaps the *system* binaries
#   /usr/bin/phpX.Y, /usr/sbin/php-fpmX.Y, /usr/bin/php-cgiX.Y
# in place, keeping dated backups. Packaged extensions keep loading from the
# distro scan dir (/etc/php/X.Y/mods-available) as .so files.
#
# This script encodes the pitfalls we hit while deploying php2shell patches
# over a distro PHP on live hosting (see deploy/DEPLOYMENT.md):
#
#  * --disable-all strips extensions the distro keeps *compiled in*
#    (filter => fatal `Undefined constant "INPUT_GET"` on WordPress/
#    OpenCart => HTTP 500). --enable-filter is mandatory; every other module
#    the new build lacks is caught by the baseline module check below.
#  * packaged .so files reference pcre_exec (<=7.3) / pcre2_* (>=7.4) and
#    other internals; configure adds -fvisibility=hidden *after* user
#    CFLAGS, so bundled symbols must be un-hidden and PCRE linked externally
#    before 7.4.
#  * a broken extension_dir in the swap ini makes every packaged .so unload:
#    fpm starts, all pools die, nginx returns 502/500.
#  * distro fpm units are Type=notify; vanilla php-fpm never sends
#    sd_notify, so systemd kills/hangs the unit => Type=exec.
#  * static modules that also have a packaged *.ini must have the
#    `extension=` line disabled, otherwise "module already loaded".
#
# Usage:
#   ./swap-system-php.sh 7.3.33 php-7.3-enhanced-universal.patch
#   ./swap-system-php.sh 8.2.35            # vanilla (8.2.35+ is patched upstream)
#
# Layout expected (adapt as needed):
#   /opt/build/php-<ver>.tar.xz   official tarball (php.net/distributions)
#   /opt/build/patches/<patch>    php2shell patch file
#
# Requires: gcc/make pkg-config libxml2-dev libssl-dev libcurl4-openssl-dev
#           libmagic-dev (fileinfo) zlib1g-dev, plus for a closer parity with
#           the distro build: libonig-dev (8.0+ mbstring), libsodium-dev,
#           libpng-dev libjpeg-dev libfreetype6-dev (gd), libicu-dev (intl),
#           libpcre3-dev (<=7.3 external PCRE), libreadline-dev.
set -euo pipefail

VER="${1:?usage: swap-system-php.sh <ver> [patch-file]}"
PATCH="${2:-}"
XY="${VER%.*}"
SRC="/opt/build/src-$VER"
BUILD_ROOT="${BUILD_ROOT:-/opt/build}"
CRITICAL_MODULES="filter ctype json mbstring tokenizer phar fileinfo session hash openssl curl mysqli pdo pdo_mysql zip iconv"

cd "$BUILD_ROOT"
test -f "php-$VER.tar.xz" || { echo "FATAL: php-$VER.tar.xz missing in $BUILD_ROOT"; exit 1; }

EXTDIR="$(php"$XY" -r 'echo ini_get("extension_dir");' 2>/dev/null || true)"
API="${EXTDIR##*/}"   # /usr/lib/php/20131226 -> 20131226  (never ${VAR##*-}!)
echo "packaged extension_dir=${EXTDIR:-<unset>} api=$API"

# baseline: module list of the currently installed (distro) binary, used as
# the acceptance criterion after the swap
BASELINE="$BUILD_ROOT/baseline-$XY.modules"
if [ -x "/usr/bin/php$XY" ]; then
  php"$XY" -m 2>/dev/null | tr -d '*' | tr '[:upper:]' '[:lower:]' | sort > "$BASELINE" || true
fi

rm -rf "$SRC"; mkdir -p "$SRC"
tar -xJf "php-$VER.tar.xz" -C "$SRC" --strip-components=1
cd "$SRC"

if [ -n "$PATCH" ]; then
  test -f "$BUILD_ROOT/patches/$PATCH" || { echo "FATAL: patch $PATCH missing"; exit 1; }
  patch -p1 --no-backup-if-mismatch < "$BUILD_ROOT/patches/$PATCH"
fi

# --- PCRE / visibility ------------------------------------------------------
# <=7.3: distro PHP links external libpcre, packaged .so expect `pcre_exec`.
#   `--with-pcre-regex=/usr` needs the lib in /usr/lib (multiarch symlink).
# >=7.4: bundled pcre2 keeps the pcre2_* names; un-hide it instead.
MAJ="${XY%%.*}"
if [ "$MAJ" -lt 7 ] || { [ "$MAJ" -eq 7 ] && [ "${XY#7.}" -lt 4 ]; }; then
  if [ ! -e /usr/lib/libpcre.so ] && [ -e /usr/lib/x86_64-linux-gnu/libpcre.so ]; then
    ln -sfn x86_64-linux-gnu/libpcre.so /usr/lib/libpcre.so
  fi
  PCRE_OPT="--with-pcre-regex=/usr"
else
  PCRE_OPT="--with-pcre-jit"
fi

# --- extensions -------------------------------------------------------------
# Keep --disable-all (a small, auditable build that matches the packaged
# .so ABI), but re-enable everything the distro compiles in and that cannot
# be loaded from a packaged .so.
EXTRA_OPT="--enable-filter"
if pkg-config --exists libsodium 2>/dev/null; then
  EXTRA_OPT="$EXTRA_OPT --with-sodium"
fi

./configure --prefix=/usr \
  --with-config-file-path="/etc/php/$XY/cli" \
  --with-config-file-scan-dir="/etc/php/$XY/mods-available" \
  --enable-cli --enable-fpm --enable-cgi --disable-phpdbg --without-pear \
  --disable-all --enable-session \
  --enable-libxml --with-libxml $PCRE_OPT --enable-hash \
  --with-mysqlnd --enable-mysqlnd --enable-pdo --enable-xml --enable-dom \
  $EXTRA_OPT

# configure appends -fvisibility=hidden after user CFLAGS; drop it so the
# static mysqlnd/pcre/libxml symbols stay exported for packaged .so files
sed -i 's/-fvisibility=hidden//g' Makefile

make -j"$(nproc)"

# --- sanity check BEFORE touching the system --------------------------------
# Every module of the installed build must be either (a) compiled into the
# new binary, or (b) present as a packaged .so (*.ini in the scan dir).
# If neither — e.g. `filter`, which the distro keeps compiled in while
# --disable-all turns it off — the swap breaks every site on that PHP
# (fatal `Undefined constant "INPUT_GET"` on WordPress/OpenCart => HTTP 500).
NEW_MODULES="$(sapi/cli/php -m 2>/dev/null | tr -d '*' | tr '[:upper:]' '[:lower:]' | sort)"
UNAVAILABLE=""
if [ -s "$BASELINE" ]; then
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    printf '%s\n' "$NEW_MODULES" | grep -qx "$m" && continue
    [ -f "/etc/php/$XY/mods-available/$m.ini" ] && continue
    case " $UNAVAILABLE " in *" $m "*) continue ;; esac
    UNAVAILABLE="$UNAVAILABLE $m"
  done < "$BASELINE"
  UNAVAILABLE="${UNAVAILABLE# }"
fi
if [ -n "${UNAVAILABLE// /}" ]; then
  echo "FATAL: modules of the installed build are neither compiled into the" >&2
  echo "       new binary nor available as packaged .so: $UNAVAILABLE" >&2
  echo "       Add the matching configure flag (usually --enable-filter and" >&2
  echo "       friends) and re-run." >&2
  exit 1
fi

# --- swap -------------------------------------------------------------------
TS="$(date +%Y%m%d%H%M%S)"
cp -a "/usr/bin/php$XY" "/usr/bin/php$XY.bak-$TS"
[ -f "/usr/sbin/php-fpm$XY" ] && cp -a "/usr/sbin/php-fpm$XY" "/usr/sbin/php-fpm$XY.bak-$TS"
[ -f "/usr/bin/php-cgi$XY" ] && cp -a "/usr/bin/php-cgi$XY" "/usr/bin/php-cgi$XY.bak-$TS"
install -m 755 sapi/cli/php "/usr/bin/php$XY"
install -m 755 sapi/fpm/php-fpm "/usr/sbin/php-fpm$XY"
install -m 755 sapi/cgi/php-cgi "/usr/bin/php-cgi$XY"

# compiled ini path is /etc/php/X.Y/cli in every binary; repoint fpm/cgi
# (same length: cli -> fpm / cgi)
perl -pi -e "s#/etc/php/\Q$XY\E/cli#/etc/php/$XY/fpm#" "/usr/sbin/php-fpm$XY"
perl -pi -e "s#/etc/php/\Q$XY\E/cli#/etc/php/$XY/cgi#" "/usr/bin/php-cgi$XY"

# packaged .so files live in /usr/lib/php/<api>; pin it via scan-dir
# (overrides php.ini). Watch the expansion: it must be ${EXTDIR##*/} only.
printf 'extension_dir=/usr/lib/php/%s\n' "$API" > "/etc/php/$XY/mods-available/00-swap-extension-dir.ini"

# modules compiled into the new binary: disable the `extension=` line of the
# packaged .ini (keep other directives) so nothing loads twice
for m in $(sapi/cli/php -m 2>/dev/null | tr -d '*' | tr '[:upper:]' '[:lower:]'); do
  ini="/etc/php/$XY/mods-available/$m.ini"
  [ -f "$ini" ] || continue
  grep -q '^extension=' "$ini" || continue
  sed -i 's/^extension=/;disabled-by-swap extension=/' "$ini"
done

# sury/debian units are Type=notify; vanilla php-fpm does not send sd_notify
UNIT="/lib/systemd/system/php$XY-fpm.service"
if [ -f "$UNIT" ] && grep -q '^Type=notify' "$UNIT"; then
  sed -i 's/^Type=notify/Type=exec/' "$UNIT"
  systemctl daemon-reload
fi

systemctl restart "php$XY-fpm"
sleep 1
systemctl is-active --quiet "php$XY-fpm" || { echo "FATAL: php$XY-fpm not active"; exit 1; }

# --- final verification -----------------------------------------------------
AFTER="$(php"$XY" -m 2>/dev/null | tr -d '*' | tr '[:upper:]' '[:lower:]' | sort)"
for m in $CRITICAL_MODULES; do
  printf '%s\n' "$AFTER" | grep -qx "$m" && continue
  case "$XY" in
    5.*|7.[0-3]) [ "$m" = json ] && continue ;;   # json exists as ext before 8.0 only
  esac
  [ "$m" = zip ] && [ ! -f "/etc/php/$XY/mods-available/zip.ini" ] && continue
  echo "FATAL: critical module '$m' is not loaded after swap (packaged .so did not start?)" >&2
  exit 1
done
if [ -s "$BASELINE" ]; then
  LOST="$(comm -23 "$BASELINE" <(printf '%s\n' "$AFTER") | tr '\n' ' ')"
  [ -n "${LOST// /}" ] && echo "WARN: modules lost vs distro build: $LOST"
fi
php"$XY" -v | head -1

echo "SWAPPED $VER OK"
