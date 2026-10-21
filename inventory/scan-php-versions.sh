#!/usr/bin/env bash
# php2shell — inventory PHP versions across HestiaCP servers.
# Run on each server (or via ansible/ssh fan-out).
# Prints every PHP binary found, its version, and whether it is patched.
set -u

FIXED_82="8.2.35"; FIXED_83="8.3.36"; FIXED_84="8.4.27"; FIXED_85="8.5.12"

ver_ge() { # true if $1 >= $2 (loose numeric compare on x.y.z)
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

is_patched() {
    local v="$1" major minor
    major=$(echo "$v" | cut -d. -f1)
    minor=$(echo "$v" | cut -d. -f2)
    case "$major" in
        8)
            case "$minor" in
                5) ver_ge "$v" "$FIXED_85" ;;
                4) ver_ge "$v" "$FIXED_84" ;;
                3) ver_ge "$v" "$FIXED_83" ;;
                2) ver_ge "$v" "$FIXED_82" ;;
                *) return 1 ;;  # 8.0 / 8.1 = EOL, never patched upstream
            esac
            ;;
        *) return 1 ;;  # 5.x / 7.x = EOL, never patched upstream
    esac
}

echo "=== php2shell PHP inventory: $(hostname) ==="
echo

# Common locations on HestiaCP / Debian / Ubuntu
CANDIDATES=(
    /usr/bin/php
    /usr/local/bin/php
    /usr/local/hestia/php/bin/php          # hestia-php (panel)
    /usr/bin/php5.6 /usr/bin/php7.0 /usr/bin/php7.1
    /usr/bin/php7.2 /usr/bin/php7.3 /usr/bin/php7.4
    /usr/bin/php8.0 /usr/bin/php8.1 /usr/bin/php8.2
    /usr/bin/php8.3 /usr/bin/php8.4 /usr/bin/php8.5
)

# Also glob any /usr/bin/php* we might have missed
while IFS= read -r p; do CANDIDATES+=("$p"); done < <(ls /usr/bin/php[0-9]* 2>/dev/null || true)

declare -A SEEN
for bin in "${CANDIDATES[@]}"; do
    [ -x "$bin" ] || continue
    [ -n "${SEEN[$bin]:-}" ] && continue
    SEEN[$bin]=1
    v=$("$bin" -r 'echo PHP_VERSION;' 2>/dev/null) || continue
    if is_patched "$v"; then
        status="PATCHED"
    else
        status="VULNERABLE"
    fi
    printf '%-45s %-12s %s\n' "$bin" "$v" "$status"
done

echo
echo "--- PHP-FPM services ---"
systemctl list-units --type=service --state=running 2>/dev/null \
    | grep -E 'php.*-fpm|hestia' || echo "(none found via systemctl)"

echo
echo "--- session.upload_progress status (should be Off until patched) ---"
for bin in "${!SEEN[@]}"; do
    val=$("$bin" -i 2>/dev/null | grep '^session.upload_progress.enabled' | head -1)
    [ -n "$val" ] && printf '%-45s %s\n' "$bin" "$val"
done

echo
echo "=== Summary ==="
echo "Any VULNERABLE above = needs update or hardening NOW."
echo "EOL versions (<=8.1) will NEVER get an official patch."
echo "See harden/ in this repo for emergency mitigations."
