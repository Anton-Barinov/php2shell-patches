#!/usr/bin/env bash
#
# swap-aapanel-php.sh: In-place patch deployer and builder for aaPanel / Baota (BT Panel)
# Fixes PHP2Shell (CVE-2026-109618 / CVE-2026-109619) on aaPanel PHP installations:
#   /www/server/php/{54,55,56,70,71,72,73,74,80,81}
#
# Preserves:
#   - php.ini configuration and php-fpm pool settings
#   - Pre-installed third-party extensions (ionCube, redis, swoole, opcache, etc.)
#   - Exact original build flags and custom library linkages (/usr/local/openssl, etc.)
#
# Usage:
#   ./swap-aapanel-php.sh status   <ver>               # Check patch status and FPM state
#   ./swap-aapanel-php.sh build    <ver> [patch-file]  # Step 1: Offline build & verification
#   ./swap-aapanel-php.sh install  <ver>               # Step 2: Backup -> swap -> restart (auto-rollback)
#   ./swap-aapanel-php.sh rollback <ver>               # Roll back to pre-swap state
#
# Examples:
#   ./swap-aapanel-php.sh status 74
#   ./swap-aapanel-php.sh build  74 patches/php-7.4-enhanced-universal.patch
#   ./swap-aapanel-php.sh install 74
#
set -uo pipefail

ACTION="${1:-}"
VER="${2:-}"
PATCH_ARG="${3:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

STATE_DIR="/www/server/php-cve2026"
LOG_DIR="$STATE_DIR/logs"

red()   { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
info()  { echo -e "\033[36m==> $*\033[0m"; }
die()   { red "FATAL: $*"; exit 1; }

usage() {
    echo "Usage: $0 {build|install|rollback|status} <ver> [patch-file]"
    echo "  ver: 54, 55, 56, 70, 71, 72, 73, 74, 80, 81"
    exit 1
}

[ -n "$ACTION" ] && [ -n "$VER" ] || usage

case "$VER" in
    54) PHP_FULL="5.4.45"; DEF_PATCH="patches/php-5.4-enhanced-universal.patch" ;;
    55) PHP_FULL="5.5.38"; DEF_PATCH="patches/php-5.5-enhanced-universal.patch" ;;
    56) PHP_FULL="5.6.40"; DEF_PATCH="patches/php-5.6-enhanced-universal.patch" ;;
    70) PHP_FULL="7.0.33"; DEF_PATCH="patches/php-7.0-enhanced-universal.patch" ;;
    71) PHP_FULL="7.1.33"; DEF_PATCH="patches/php-7.1-enhanced-universal.patch" ;;
    72) PHP_FULL="7.2.34"; DEF_PATCH="patches/php-7.2-enhanced-universal.patch" ;;
    73) PHP_FULL="7.3.33"; DEF_PATCH="patches/php-7.3-enhanced-universal.patch" ;;
    74) PHP_FULL="7.4.33"; DEF_PATCH="patches/php-7.4-enhanced-universal.patch" ;;
    80) PHP_FULL="8.0.30"; DEF_PATCH="patches/php-8.0-enhanced-universal.patch" ;;
    81) PHP_FULL="8.1.34"; DEF_PATCH="patches/php-8.1-enhanced-universal.patch" ;;
    *)  die "Unsupported version '$VER'. Valid versions: 54 55 56 70 71 72 73 74 80 81" ;;
esac

PREFIX="/www/server/php/$VER"
INIT="/etc/init.d/php-fpm-$VER"
SRC_TGZ="$STATE_DIR/php-$PHP_FULL.tar.gz"
BUILD_ROOT="$STATE_DIR/build-$VER"
SRC_DIR="$BUILD_ROOT/php-$PHP_FULL"
BACKUP_PTR="$STATE_DIR/last-backup-$VER"
PID_FILE="$PREFIX/var/run/php-fpm.pid"

mkdir -p "$LOG_DIR"

# Deterministic patch check probe: exits 1 with empty stdout on patched build
is_patched() {
    local target="${1:-$PREFIX/bin/php}"
    [ -x "$target" ] || return 1
    local out rc
    out=$("$target" -n -d memory_limit=8M -d display_errors=1 -r '$a = str_repeat("x", 32 * 1024 * 1024);' 2>/dev/null)
    rc=$?
    [ "$rc" -eq 1 ] && [ -z "$out" ]
}

linked_libs() {
    ldd "$1" 2>/dev/null | awk '/=> \//{print $3}' | sed 's#/lib/[^/]*-linux-gnu/#/lib/ARCH/#' | sort -u
}

fpm_running() {
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null
}

fpm_stop() {
    if [ -x "$INIT" ]; then "$INIT" stop >/dev/null 2>&1 || true; fi
    for _ in $(seq 1 20); do fpm_running || return 0; sleep 0.5; done
    if fpm_running; then kill -QUIT "$(cat "$PID_FILE")" 2>/dev/null; fi
    for _ in $(seq 1 20); do fpm_running || return 0; sleep 0.5; done
    return 1
}

fpm_start() {
    "$INIT" start >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do fpm_running && return 0; sleep 0.5; done
    return 1
}

do_status() {
    [ -x "$PREFIX/bin/php" ] || die "$PREFIX/bin/php does not exist"
    "$PREFIX/bin/php" -v | head -n1
    if is_patched "$PREFIX/bin/php"; then
        green "STATUS: Patched against CVE-2026-109618 / CVE-2026-109619"
    else
        red "STATUS: VULNERABLE (unpatched against CVE-2026-109618 / CVE-2026-109619)"
    fi
    if fpm_running; then
        echo "php-fpm-$VER: RUNNING (pid $(cat "$PID_FILE"))"
    else
        echo "php-fpm-$VER: STOPPED"
    fi
}

do_build() {
    [ "$(id -u)" -eq 0 ] || die "Root privileges required"
    [ -x "$PREFIX/bin/php" ] || die "$PREFIX/bin/php not found (verify aaPanel PHP $VER is installed)"

    local patch_path=""
    if [ -n "$PATCH_ARG" ]; then
        if [ -f "$PATCH_ARG" ]; then
            patch_path="$PATCH_ARG"
        elif [ -f "$REPO_ROOT/$PATCH_ARG" ]; then
            patch_path="$REPO_ROOT/$PATCH_ARG"
        else
            die "Specified patch file '$PATCH_ARG' not found"
        fi
    else
        if [ -f "$REPO_ROOT/$DEF_PATCH" ]; then
            patch_path="$REPO_ROOT/$DEF_PATCH"
        else
            die "Default patch $REPO_ROOT/$DEF_PATCH not found"
        fi
    fi

    info "Using patch: $patch_path"

    # Fetch official PHP source if missing
    if [ ! -f "$SRC_TGZ" ]; then
        info "Downloading official php-$PHP_FULL source tarball..."
        local url="https://www.php.net/distributions/php-$PHP_FULL.tar.gz"
        curl -fSL "$url" -o "$SRC_TGZ" || curl -fSL "https://museum.php.net/php5/php-$PHP_FULL.tar.gz" -o "$SRC_TGZ" || die "Failed to download $url"
    fi

    # Read original configure flags from running installation
    local raw
    raw=$("$PREFIX/bin/php" -n -i | sed -n 's/^Configure Command =>  *//p')
    [ -n "$raw" ] || die "Could not retrieve original Configure Command from $PREFIX/bin/php"
    local -a ARGS
    eval "ARGS=($raw)" || die "Failed to parse configure arguments"
    [ "${ARGS[0]}" = "./configure" ] || die "Unrecognized configure format: $raw"

    # Avoid pear rebuild hang during automated install
    if ! printf '%s\n' "${ARGS[@]:1}" | grep -q -- "pear"; then
        ARGS+=("--without-pear")
    fi

    # Detect custom library paths from ldd and populate PKG_CONFIG_PATH
    local d pcp=""
    for d in $(ldd "$PREFIX/sbin/php-fpm" 2>/dev/null | awk '/=> \/usr\/local\//{print $3}' | xargs -r -n1 dirname | sort -u); do
        local cand="$d/pkgconfig"
        [ -d "$cand" ] && pcp="${pcp:+$pcp:}$cand"
        [ -d "$d/../lib/pkgconfig" ] && pcp="${pcp:+$pcp:}$(cd "$d/../lib/pkgconfig" && pwd)"
    done
    if [ -n "$pcp" ]; then
        export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:+$PKG_CONFIG_PATH:}$pcp"
        info "Discovered PKG_CONFIG_PATH: $PKG_CONFIG_PATH"
    fi

    info "Unpacking source tree..."
    rm -rf "$SRC_DIR"
    mkdir -p "$BUILD_ROOT"
    tar -xzf "$SRC_TGZ" -C "$BUILD_ROOT"

    cd "$SRC_DIR"

    info "Applying security patch..."
    patch -p1 --no-backup-if-mismatch < "$patch_path" || die "Patch application failed"

    info "Configuring PHP $PHP_FULL with original flags..."
    "${ARGS[@]}" > "$LOG_DIR/configure-$VER.log" 2>&1 || {
        tail -n 30 "$LOG_DIR/configure-$VER.log"
        die "configure failed. Check $LOG_DIR/configure-$VER.log"
    }

    # RAM-aware build concurrency calculation
    local jobs
    jobs="$(nproc 2>/dev/null || echo 2)"
    if [ -f /proc/meminfo ]; then
        local mem_kb ram_jobs
        mem_kb=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || awk '/MemFree/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
        if [ "$mem_kb" -gt 0 ]; then
            ram_jobs=$(( mem_kb / 1048576 ))
            [ "$ram_jobs" -lt 1 ] && ram_jobs=1
            [ "$ram_jobs" -lt "$jobs" ] && jobs="$ram_jobs"
        fi
    fi
    info "Compiling with make -j$jobs (RAM safe)..."
    make -j"$jobs" > "$LOG_DIR/build-$VER.log" 2>&1 || {
        tail -n 30 "$LOG_DIR/build-$VER.log"
        die "Compilation failed. Check $LOG_DIR/build-$VER.log"
    }

    # Binary patch verification
    [ -x "$SRC_DIR/sapi/cli/php" ] || die "sapi/cli/php not created"
    if ! is_patched "$SRC_DIR/sapi/cli/php"; then
        die "Post-build verification failed: sapi/cli/php does not respond as patched"
    fi

    # Dynamic library comparison
    local libdiff
    libdiff=$(comm -3 <(linked_libs "$PREFIX/sbin/php-fpm") <(linked_libs "$SRC_DIR/sapi/fpm/php-fpm") | sed -e 's/^\t/> /' -e 't' -e 's/^/< /')
    if [ -n "$libdiff" ]; then
        echo "$libdiff" | tee "$LOG_DIR/libdiff-$VER.txt"
        if [ "${FORCE:-0}" != 1 ]; then
            die "Dynamic library dependencies differ between existing and newly built php-fpm (set FORCE=1 to bypass if intended)"
        fi
    fi

    green "Build successful and verified! Run: $0 install $VER"
}

restore() {
    local backup="$1"
    local start="$2"
    fpm_stop || true
    rm -rf "$PREFIX.failed" && mv "$PREFIX" "$PREFIX.failed" && cp -a "$backup" "$PREFIX" || die "Automated rollback failed! Manually restore: rm -rf $PREFIX && cp -a $backup $PREFIX"
    rm -rf "$PREFIX.failed"
    if [ "$start" -eq 1 ]; then
        fpm_start || red "Warning: php-fpm restart failed after rollback"
    fi
    "$PREFIX/bin/php" -v | head -n1
    green "Rollback to $backup completed."
}

do_install() {
    [ "$(id -u)" -eq 0 ] || die "Root privileges required"
    [ -x "$SRC_DIR/sapi/cli/php" ] && [ -x "$SRC_DIR/sapi/fpm/php-fpm" ] || die "Build artifacts missing. Run: $0 build $VER first"
    is_patched "$SRC_DIR/sapi/cli/php" || die "Built binary failed patch verification. Re-run build."
    [ -x "$INIT" ] || die "Service init script $INIT not found"

    local stamp backup was_running=0
    stamp=$(date +%Y%m%d-%H%M%S)
    backup="/www/server/php/$VER.bak-$stamp"
    fpm_running && was_running=1

    # Snapshot baseline modules
    "$PREFIX/bin/php" -m 2>/dev/null | grep -v '^\[' | grep -v '^$' | sort > "$LOG_DIR/modules-before-$VER.txt"
    "$PREFIX/bin/php" -v | head -n1 > "$LOG_DIR/version-before-$VER.txt"

    info "Backing up $PREFIX -> $backup"
    cp -a "$PREFIX" "$backup" || die "Failed to create backup"
    echo "$backup" > "$BACKUP_PTR"

    info "Stopping php-fpm-$VER..."
    fpm_stop || { red "Failed to gracefully stop php-fpm"; fpm_start; exit 1; }

    info "Installing patched PHP binaries into $PREFIX..."
    if ! (cd "$SRC_DIR" && make install > "$LOG_DIR/install-$VER.log" 2>&1); then
        tail -n 20 "$LOG_DIR/install-$VER.log"
        red "make install failed. Rolling back..."
        restore "$backup" "$was_running"
        exit 1
    fi

    info "Testing php-fpm configuration..."
    if ! "$PREFIX/sbin/php-fpm" -t > "$LOG_DIR/fpm-test-$VER.log" 2>&1; then
        cat "$LOG_DIR/fpm-test-$VER.log"
        red "php-fpm -t configuration test failed. Rolling back..."
        restore "$backup" "$was_running"
        exit 1
    fi

    if [ "$was_running" -eq 1 ]; then
        info "Starting php-fpm-$VER..."
        if ! fpm_start; then
            red "php-fpm failed to start. Rolling back..."
            restore "$backup" "$was_running"
            exit 1
        fi
    fi

    # Verification post-install
    local fail=0
    "$PREFIX/bin/php" -m 2>/dev/null | grep -v '^\[' | grep -v '^$' | sort > "$LOG_DIR/modules-after-$VER.txt"
    if ! is_patched "$PREFIX/bin/php"; then
        red "Verification failed: installed binary is not patched"
        fail=1
    fi
    local missing
    missing=$(comm -23 "$LOG_DIR/modules-before-$VER.txt" "$LOG_DIR/modules-after-$VER.txt")
    if [ -n "$missing" ]; then
        red "Verification failed: missing modules after upgrade: $missing"
        fail=1
    fi
    if "$PREFIX/bin/php" -v 2>&1 | grep -qiE "warning|error"; then
        "$PREFIX/bin/php" -v
        red "Verification failed: php reports warnings/errors on startup"
        fail=1
    fi

    if [ "$fail" -eq 1 ]; then
        red "Post-install verification failed. Rolling back..."
        restore "$backup" "$was_running"
        exit 1
    fi

    echo
    echo "Previous version: $(cat "$LOG_DIR/version-before-$VER.txt")"
    echo "Patched version:  $("$PREFIX/bin/php" -v | head -n1)"
    echo "Modules:          $(wc -l < "$LOG_DIR/modules-after-$VER.txt") (matches pre-swap baseline)"
    if [ "$was_running" -eq 1 ]; then
        echo "php-fpm-$VER:     RUNNING (pid $(cat "$PID_FILE"))"
    fi
    green "Upgrade completed successfully! Backup saved at: $backup"
}

do_rollback() {
    [ "$(id -u)" -eq 0 ] || die "Root privileges required"
    [ -f "$BACKUP_PTR" ] || die "No backup pointer found at $BACKUP_PTR"
    local backup
    backup=$(cat "$BACKUP_PTR")
    [ -x "$backup/bin/php" ] || die "Backup directory $backup is invalid or missing"
    local was_running=0
    fpm_running && was_running=1
    info "Rolling back $PREFIX <- $backup"
    restore "$backup" "$was_running"
}

case "$ACTION" in
    build)    do_build ;;
    install)  do_install ;;
    rollback) do_rollback ;;
    status)   do_status ;;
    *)        usage ;;
esac
