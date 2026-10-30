#!/usr/bin/env bash
# php2shell — build a patched PHP from source.
# Tested paths: PHP 5.6.40, 7.4.33 (community / official minimal patches),
#               8.0.x, 8.1.x (official minimal patches).
#
# Usage:
#   ./build-patched-php.sh <version> <patch-file> [prefix] [configure-options...]
# Examples:
#   ./build-patched-php.sh 7.4.33 patches/php-7.4-minimal.patch /opt/php-7.4.33-patched
#   ./build-patched-php.sh 5.6.40 patches/php-5.6-community-backport.patch /opt/php-5.6.40-patched
#
# Requires: build-essential / gcc, make, pkg-config, autoconf, bison, re2c,
#           libxml2-dev, libssl-dev, libcurl4-openssl-dev, libsqlite3-dev
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:?Usage: $0 <version> <patch-file> [prefix] [configure-options...]}"
PATCH_FILE="${2:?Usage: $0 <version> <patch-file> [prefix] [configure-options...]}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: invalid PHP version" >&2; exit 1; }
shift 2
PREFIX="/opt/php-${VERSION}-patched"
if [ "$#" -gt 0 ] && [[ "$1" != --* ]]; then PREFIX="$1"; shift; fi
case "$PREFIX" in /*) ;; *) PREFIX="$(pwd)/$PREFIX" ;; esac
[ -f "$PATCH_FILE" ] || { echo "ERROR: patch file not found: $PATCH_FILE" >&2; exit 1; }
PATCH_FILE="$(cd "$(dirname "$PATCH_FILE")" && pwd)/$(basename "$PATCH_FILE")"
BUILD_DIR="$(pwd)/.php2shell-build"
SRC_TAR="php-${VERSION}.tar.gz"
SRC_URL="https://www.php.net/distributions/${SRC_TAR}"
NPROC="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"
if [ -f /proc/meminfo ]; then
    mem_kb=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || awk '/MemFree/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    if [ "$mem_kb" -gt 0 ]; then
        ram_jobs=$(( mem_kb / 1048576 ))
        [ "$ram_jobs" -lt 1 ] && ram_jobs=1
        [ "$ram_jobs" -lt "$NPROC" ] && NPROC="$ram_jobs"
    fi
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

if [ ! -f "$SRC_TAR" ]; then
    echo "==> Downloading PHP ${VERSION}..."
    curl -fL "$SRC_URL" -o "$SRC_TAR.part"
    mv "$SRC_TAR.part" "$SRC_TAR"
fi

# Always start from pristine sources: a failed/partial previous patch must
# never be treated as an already verified build.
rm -rf "php-${VERSION}"
echo "==> Extracting..."
tar xzf "$SRC_TAR"
cd "php-${VERSION}"

echo "==> Applying patch ${PATCH_FILE}..."
# Dry-run first; do not retry against a tree partially changed by patch.
patch -p1 --forward --dry-run < "$PATCH_FILE"
patch -p1 --forward < "$PATCH_FILE"

echo "==> Configuring (minimal CLI + FPM build)..."
# Adjust --enable flags to taste. This set is deliberately small so the
# build succeeds on stock Debian/Ubuntu. Add extensions as needed.
if [ ! -x ./configure ]; then ./buildconf --force; fi
./configure \
    --prefix="$PREFIX" \
    --with-config-file-path="$PREFIX/etc" \
    --with-config-file-scan-dir="$PREFIX/etc/conf.d" \
    --disable-cgi \
    --enable-fpm \
    --with-fpm-user=www-data \
    --with-fpm-group=www-data \
    --with-openssl \
    --with-curl \
    --with-zlib \
    --enable-mbstring \
    --with-mysqli \
    --with-pdo-mysql \
    --with-pdo-sqlite \
    --with-sqlite3 \
    --enable-sockets \
    --enable-opcache \
    "$@"

echo "==> Building (${NPROC} jobs)..."
make -j"${NPROC}"

echo "==> Verifying built CLI before installation..."
"$HERE/verify-exit-oom.sh" "$(pwd)/sapi/cli/php"

echo "==> Installing to ${PREFIX}..."
make install
"$HERE/verify-exit-oom.sh" "${PREFIX}/bin/php"

echo
echo "============================================================"
echo " Patched PHP ${VERSION} installed to ${PREFIX}"
echo
echo " Binary:  ${PREFIX}/bin/php"
echo " Verify:  ${PREFIX}/bin/php -v"
echo
echo " IMPORTANT: run the PHP test suite before production use:"
echo "   cd ${BUILD_DIR}/php-${VERSION} && make test"
echo "============================================================"
