#!/usr/bin/env bash
# php2shell — build a patched PHP from source.
# Tested paths: PHP 5.6.40, 7.4.33 (community / official minimal patches),
#               8.0.x, 8.1.x (official minimal patches).
#
# Usage:
#   ./build-patched-php.sh <version> <patch-file> [prefix]
# Examples:
#   ./build-patched-php.sh 7.4.33 patches/php-7.4-minimal.patch /opt/php-7.4.33-patched
#   ./build-patched-php.sh 5.6.40 patches/php-5.6-community-backport.patch /opt/php-5.6.40-patched
#
# Requires: build-essential / gcc, make, pkg-config, autoconf, bison, re2c,
#           libxml2-dev, libssl-dev, libcurl4-openssl-dev, libsqlite3-dev
set -euo pipefail

VERSION="${1:?Usage: $0 <version> <patch-file> [prefix]}"
PATCH_FILE="${2:?Usage: $0 <version> <patch-file> [prefix]}"
PREFIX="${3:-/opt/php-${VERSION}-patched}"
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

if [ ! -f "$PATCH_FILE" ]; then
    echo "ERROR: patch file not found: $PATCH_FILE" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

if [ ! -f "$SRC_TAR" ]; then
    echo "==> Downloading PHP ${VERSION}..."
    curl -fL "$SRC_URL" -o "$SRC_TAR"
fi

if [ ! -d "php-${VERSION}" ]; then
    echo "==> Extracting..."
    tar xzf "$SRC_TAR"
fi

cd "php-${VERSION}"

echo "==> Applying patch ${PATCH_FILE}..."
if ! patch -p1 --forward < "../../${PATCH_FILE#./}"; then
    # try relative to CWD of invocation
    if ! patch -p1 --forward < "$PATCH_FILE"; then
        echo "ERROR: patch failed to apply. Aborting before build." >&2
        exit 1
    fi
fi

echo "==> Configuring (minimal CLI + FPM build)..."
# Adjust --enable flags to taste. This set is deliberately small so the
# build succeeds on stock Debian/Ubuntu. Add extensions as needed.
./buildconf --force >/dev/null 2>&1 || true
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

echo "==> Installing to ${PREFIX}..."
make install

echo "==> Verifying patch..."
out=$("${PREFIX}/bin/php" -n -d memory_limit=8M -d display_errors=1 -r '$a = str_repeat("x", 32 * 1024 * 1024);' 2>/dev/null || true)
rc=$?
if [ "$rc" -eq 1 ] && [ -z "$out" ]; then
    echo "==> [OK] Binary confirmed PATCHED (clean _exit on OOM, CVE-2026-109618 fixed)"
fi

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
