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
#  * packaged .so files resolve pcre_exec / pcre2_match_8 from the *binary's*
#    link scope (they carry no DT_NEEDED of their own) and reference other
#    internals; configure adds -fvisibility=hidden after user CFLAGS, so
#    internal symbols must stay exported. PCRE must be linked exactly like
#    the distro build does (see the PCRE block).
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
# Requires: gcc/make pkg-config libxml2-dev libssl-dev (openssl is compiled
#           into the distro binary, so it must be enabled here too)
#           zlib1g-dev, libpcre3-dev (5.6-7.2 external PCRE1),
#           libpcre2-dev (7.3+ external PCRE2; pkg-config libpcre2-8),
#           libsodium-dev, and optionally: libreadline-dev.
set -euo pipefail

VER="${1:?usage: swap-system-php.sh <ver> [patch-file]}"
PATCH="${2:-}"
XY="${VER%.*}"
SRC="/opt/build/src-$VER"
BUILD_ROOT="${BUILD_ROOT:-/opt/build}"
CRITICAL_MODULES="filter ctype json mbstring tokenizer phar fileinfo session hash openssl curl mysqli pdo pdo_mysql zip iconv"

# php -m also prints section headers and loader banner lines
# ("[Zend Modules]", "the ioncube php loader + ioncube24", "Zend OPcache") —
# keep only bare module identifiers for baseline/after comparisons.
# `--static` adds -n (ignore every ini) to list *compiled-in* modules only:
# without it php -m also shows modules loaded from packaged .ini files, and
# a static/packaged distinction made from that list disables the wrong inis.
modules_of() {
  local flags=()
  [ "${1:-}" = "--static" ] && { flags=(-n); shift; }
  "$@" ${flags[@]+"${flags[@]}"} -m 2>/dev/null | tr -d '*' | tr '[:upper:]' '[:lower:]' | grep -E '^[a-z0-9_]+$' | sort -u
}

# BEGIN cfg-backup (harnessed by tests/cfg-backup-test.sh)
# Keep the first pre-swap state of every config this script rewrites:
#   packaged ini -> <file>.swapbak  (extension= disable marking)
#   fpm unit     -> <file>.swapbak  (Type=notify -> Type=exec)
# The .swapbak name is fixed on purpose: the FIRST swap owns it, later
# swaps must never clobber the original state — restore-system-php.sh
# rolls back from these files. (00-swap-extension-dir.ini and the ioncube
# mirror are 100% ours by name: no backup, restore removes them.)
cfg_backup() {
  local f="$1"
  [ -f "$f" ] || return 0
  [ -f "$f.swapbak" ] && return 0
  cp -a "$f" "$f.swapbak"
}
# END cfg-backup

cd "$BUILD_ROOT"
test -f "php-$VER.tar.xz" || { echo "FATAL: php-$VER.tar.xz missing in $BUILD_ROOT"; exit 1; }

EXTDIR="$(php"$XY" -r 'echo ini_get("extension_dir");' 2>/dev/null || true)"
API="${EXTDIR##*/}"   # /usr/lib/php/20131226 -> 20131226  (never ${VAR##*-}!)
echo "packaged extension_dir=${EXTDIR:-<unset>} api=$API"

# baseline: module list of the currently installed (distro) binary, used as
# the acceptance criterion after the swap
BASELINE="$BUILD_ROOT/baseline-$XY.modules"
if [ -x "/usr/bin/php$XY" ]; then
  modules_of php"$XY" > "$BASELINE" || true
fi

rm -rf "$SRC"; mkdir -p "$SRC"
tar -xJf "php-$VER.tar.xz" -C "$SRC" --strip-components=1
cd "$SRC"

if [ -n "$PATCH" ]; then
  test -f "$BUILD_ROOT/patches/$PATCH" || { echo "FATAL: patch $PATCH missing"; exit 1; }
  patch -p1 --no-backup-if-mismatch < "$BUILD_ROOT/patches/$PATCH"
fi

# --- PCRE / visibility ------------------------------------------------------
# Distro PHP links external PCRE and the packaged .so files (fileinfo & co)
# resolve pcre_exec / pcre2_match_8 from the binary's link scope:
#   5.6-7.2 : libpcre.so.3    -> --with-pcre-regex=/usr (needs the
#             /usr/lib/libpcre.so symlink: configure misses the multiarch dir)
#   7.3     : libpcre2-8       -> its configure maps DIR=/usr onto pkg-config
#             'libpcre2-8 >= 10.30' (install libpcre2-dev)
#   >=7.4   : libpcre2-8       -> --with-external-pcre (bundled pcre2 renames
#             every symbol to php_pcre2_* and would leave pcre2_match_8
#             unresolved in the packaged .so files)
MAJ="${XY%%.*}"
MINOR=""
[ "$MAJ" = 7 ] && MINOR="${XY#7.}"
if [ "$MAJ" -lt 7 ] || { [ "$MAJ" -eq 7 ] && [ "$MINOR" -lt 4 ]; }; then
  PCRE_OPT="--with-pcre-regex=/usr"
  if [ "$MAJ" -lt 7 ]; then
    if [ ! -e /usr/lib/libpcre.so ] && [ -e /usr/lib/x86_64-linux-gnu/libpcre.so ]; then
      ln -sfn x86_64-linux-gnu/libpcre.so /usr/lib/libpcre.so
    fi
    [ -e /usr/lib/libpcre.so ] || { echo "FATAL: /usr/lib/libpcre.so missing (install libpcre3-dev for external PCRE1)"; exit 1; }
  else
    pkg-config --exists 'libpcre2-8 >= 10.30' || { echo "FATAL: pkg-config libpcre2-8 >= 10.30 not found (install libpcre2-dev for PHP 7.3)"; exit 1; }
  fi
else
  pkg-config --exists 'libpcre2-8 >= 10.30' || { echo "FATAL: pkg-config libpcre2-8 >= 10.30 not found (install libpcre2-dev)"; exit 1; }
  PCRE_OPT="--with-external-pcre"
fi

# --- extensions -------------------------------------------------------------
# Keep --disable-all (a small, auditable build), but re-enable every module
# the distro compiles INTO the binary — those have no packaged *.ini and
# would be lost by a swap (filter => HTTP 500, openssl/pcntl/zlib missing).
# json <=7.4 ships as a packaged json.so; json >=8.0 is always built in.
#
# PHP 5.6's ext/openssl predates OpenSSL 1.1 (opaque EVP_MD_CTX =>
# `storage size of 'md_ctx' isn't known`). On hosts where libssl-dev is
# 1.1.x, point 5.6 at a locally built OpenSSL 1.0.2:
#   export OPENSSL_OPT=--with-openssl=/opt/ssl10
EXTRA_OPT="--enable-filter --enable-pcntl --with-zlib ${OPENSSL_OPT:---with-openssl}"
if [ "$MAJ" -eq 5 ]; then
  EXTRA_OPT="$EXTRA_OPT --with-mhash"
fi
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

JOBS="$(nproc 2>/dev/null || echo 2)"
if [ -f /proc/meminfo ]; then
  mem_kb=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || awk '/MemFree/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  if [ "$mem_kb" -gt 0 ]; then
    ram_jobs=$(( mem_kb / 1048576 ))
    [ "$ram_jobs" -lt 1 ] && ram_jobs=1
    [ "$ram_jobs" -lt "$JOBS" ] && JOBS="$ram_jobs"
  fi
fi
make -j"$JOBS"

# --- sanity check BEFORE touching the system --------------------------------
# Every module of the installed build must be either (a) compiled into the
# new binary, or (b) present as a packaged .so (*.ini in the scan dir).
# If neither — e.g. `filter`, which the distro keeps compiled in while
# --disable-all turns it off — the swap breaks every site on that PHP
# (fatal `Undefined constant "INPUT_GET"` on WordPress/OpenCart => HTTP 500).
NEW_MODULES="$(modules_of --static sapi/cli/php)"
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
# Also pin the mysql unix socket: Debian builds compile it as the binary's
# default (MYSQL_UNIX_PORT), our vanilla build does not, so 'localhost' DB
# connections would otherwise fall back to a non-existent /tmp/mysql.sock.
SWAP_INI="/etc/php/$XY/mods-available/00-swap-extension-dir.ini"
printf 'extension_dir=/usr/lib/php/%s\nmysqli.default_socket=/var/run/mysqld/mysqld.sock\npdo_mysql.default_socket=/var/run/mysqld/mysqld.sock\n' "$API" > "$SWAP_INI"

# BEGIN ioncube-mirror (harnessed by tests/ioncube-mirror-test.sh)
# Loaders (ionCube et al.) drop a *real* ini file into <sapi>/conf.d — our
# mods-available scan never reads it, so the loader would silently stop
# loading after the swap. Mirror it into the scan-dir:
#   - source: first existing of cli/fpm/cgi conf.d / 00-ioncube-loader.ini;
#   - content: the distro's own zend_extension= value (absolute path kept as
#     is — supports non-standard loader locations; a bare filename is resolved
#     against /usr/lib/php/$API), quotes stripped;
#   - absolute .so path in the mirror keeps it independent of ini parse order;
#   - idempotent cleanup: if the distro no longer ships the ini or the loader
#     .so is gone, drop a stale mirror so nothing warns on every request.
ION_SRC=""
for _d in cli fpm cgi; do
  _f="/etc/php/$XY/$_d/conf.d/00-ioncube-loader.ini"
  [ -f "$_f" ] && { ION_SRC="$_f"; break; }
done
ION_DST="/etc/php/$XY/mods-available/10-ioncube-loader.ini"
ION_PATH=""
if [ -n "$ION_SRC" ]; then
  ION_PATH="$(sed -n 's/^[[:space:]]*zend_extension[[:space:]]*=[[:space:]]*//p' "$ION_SRC" | head -n1 | tr -d "\"'")"
  case "$ION_PATH" in
    ""|/*) : ;;                                   # empty or already absolute
    *) ION_PATH="/usr/lib/php/$API/$ION_PATH" ;;  # bare filename → extension_dir
  esac
fi
if [ -n "$ION_PATH" ] && [ -f "$ION_PATH" ]; then
  printf 'zend_extension=%s\n' "$ION_PATH" > "$ION_DST"
else
  rm -f "$ION_DST"
fi
# END ioncube-mirror

# modules compiled into the new binary: disable the `extension=` line of the
# packaged .ini (keep other directives) so nothing loads twice
for m in $(modules_of --static sapi/cli/php); do
  ini="/etc/php/$XY/mods-available/$m.ini"
  [ -f "$ini" ] || continue
  grep -q '^extension=' "$ini" || continue
  cfg_backup "$ini"
  sed -i 's/^extension=/;disabled-by-swap extension=/' "$ini"
done

# sury/debian units are Type=notify; vanilla php-fpm does not send sd_notify
UNIT="/lib/systemd/system/php$XY-fpm.service"
if [ -f "$UNIT" ] && grep -q '^Type=notify' "$UNIT"; then
  cfg_backup "$UNIT"
  sed -i 's/^Type=notify/Type=exec/' "$UNIT"
  systemctl daemon-reload
fi

# BEGIN post-swap-smoke (harnessed by tests/smoke-test.sh)
# Catch a broken fpm config (repointed ini path), a scan-dir that stops
# applying (extension_dir/sockets), or a loader that no longer loads —
# before the restart puts every site on this PHP version at risk.
echo "--- smoke ---"
# show what fpm -t said, but let the explicit check below emit the FATAL
# (without `|| true` a failing -t would kill the script here under
# `set -e -o pipefail` before the message is printed)
"/usr/sbin/php-fpm$XY" -t 2>&1 | tail -2 || true
"/usr/sbin/php-fpm$XY" -t >/dev/null 2>&1 || { echo "FATAL: php-fpm$XY -t (fpm config test failed after swap)"; exit 1; }
"/usr/bin/php-cgi$XY" -v >/dev/null || { echo "FATAL: php-cgi$XY does not run after swap"; exit 1; }
SOCK_CFG="$(php"$XY" -d disable_functions= -r 'echo ini_get("mysqli.default_socket");' 2>/dev/null || true)"
if [ "$SOCK_CFG" != /var/run/mysqld/mysqld.sock ]; then
  echo "FATAL: mysqli.default_socket='$SOCK_CFG' (scan-dir ini not applied? P10 regression)"; exit 1
fi
[ -S "$SOCK_CFG" ] || echo "WARN: mysql socket $SOCK_CFG absent (mysqld not running on this host?)"
if [ -f "$ION_DST" ]; then
  php"$XY" -d disable_functions= -m 2>/dev/null | grep -qi ioncube \
    || echo "WARN: $ION_DST present but 'php -m' shows no ionCube loader"
fi
# END post-swap-smoke

systemctl restart "php$XY-fpm"
sleep 1
systemctl is-active --quiet "php$XY-fpm" || { echo "FATAL: php$XY-fpm not active"; exit 1; }

# --- final verification -----------------------------------------------------
AFTER="$(modules_of php"$XY")"
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
