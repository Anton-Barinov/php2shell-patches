#!/usr/bin/env bash
# php2shell — apply emergency hardening to PHP-FPM pools on this server.
# Run as root. Re-run safe. Does NOT replace an actual PHP update.
set -euo pipefail

SNIPPET="$(dirname "$0")/fpm-pool-snippet.conf"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root" >&2
    exit 1
fi

if [ ! -f "$SNIPPET" ]; then
    echo "ERROR: fpm-pool-snippet.conf not found next to this script" >&2
    exit 1
fi

echo "=== php2shell hardening ==="
echo

# 1. hestia-php (panel) — its php.ini
HESTIA_PHP_INI="/usr/local/hestia/php/etc/php.ini"
if [ -f "$HESTIA_PHP_INI" ]; then
    if ! grep -q 'php2shell' "$HESTIA_PHP_INI"; then
        echo "--> Hardening $HESTIA_PHP_INI"
        cp -a "$HESTIA_PHP_INI" "${HESTIA_PHP_INI}.bak-php2shell-$(date +%s)"
        cat >> "$HESTIA_PHP_INI" << 'EOF'

; --- php2shell emergency hardening (CVE-2026-109618 / CVE-2026-109619) ---
; REMOVE after upgrading to a patched PHP release.
memory_limit = -1
session.upload_progress.enabled = 0
post_max_size = 32M
EOF
        systemctl restart hestia >/dev/null 2>&1 || true
        echo "    done (hestia restarted)"
    else
        echo "--> $HESTIA_PHP_INI already hardened, skipping"
    fi
else
    echo "--> hestia-php ini not found, skipping"
fi

echo

# 2. System PHP-FPM pools
shopt -s nullglob
POOLS=(/etc/php/*/fpm/pool.d/*.conf)
if [ ${#POOLS[@]} -eq 0 ]; then
    echo "--> No PHP-FPM pools found under /etc/php/*/fpm/pool.d/"
fi

for pool in "${POOLS[@]}"; do
    if grep -q 'php2shell' "$pool"; then
        echo "--> $pool already hardened, skipping"
        continue
    fi
    echo "--> Hardening $pool"
    cp -a "$pool" "${pool}.bak-php2shell-$(date +%s)"
    {
        echo ""
        echo "; --- php2shell emergency hardening (CVE-2026-109618 / CVE-2026-109619) ---"
        echo "; REMOVE after upgrading to a patched PHP release."
        cat "$SNIPPET" | grep -E '^php_admin'
    } >> "$pool"
    # restart the matching fpm service
    ver=$(echo "$pool" | grep -oE '[0-9]+\.[0-9]+' | head -1)
    if [ -n "$ver" ]; then
        systemctl restart "php${ver}-fpm" 2>/dev/null && echo "    restarted php${ver}-fpm" \
            || echo "    WARNING: could not restart php${ver}-fpm, restart manually"
    fi
done

echo
echo "=== Done. Verify with: ==="
echo "  grep -r 'php2shell' /etc/php/*/fpm/pool.d/ /usr/local/hestia/php/etc/php.ini 2>/dev/null"
echo
echo "REMINDER: this is NOT a complete fix. Upgrade PHP to:"
echo "  8.2.35 / 8.3.36 / 8.4.27 / 8.5.12"
