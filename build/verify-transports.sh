#!/usr/bin/env bash
# Preserve SSL/TLS stream availability across a PHP CLI replacement.
# Only lists registered transports; does not connect to any host.
set -euo pipefail
MODE="${1:?usage: verify-transports.sh snapshot|check <php-cli> <baseline-file>}"
PHP_BIN="${2:?missing PHP CLI}"
BASELINE="${3:?missing baseline file}"
case "$MODE" in snapshot|check) ;; *) echo "ERROR: unknown mode: $MODE" >&2; exit 1 ;; esac
output=$("$PHP_BIN" -r 'echo "P2S_TRANSPORTS:" . implode(",", array_intersect(array("ssl", "tls"), stream_get_transports())) . "\n";' 2>/dev/null) || {
    echo "ERROR: cannot inspect PHP stream transports: $PHP_BIN" >&2; exit 1;
}
transports=$(printf '%s\n' "$output" | sed -n 's/^P2S_TRANSPORTS://p')
# An empty list is valid, but a missing marker or arbitrary output is not.
if ! printf '%s\n' "$output" | grep -E '^P2S_TRANSPORTS:(ssl,tls|ssl|tls)?$' >/dev/null; then
    echo "ERROR: invalid transport probe response: $PHP_BIN" >&2; exit 1
fi
if [ "$MODE" = snapshot ]; then
    printf 'P2S_TRANSPORTS:%s\n' "$transports" > "$BASELINE"
else
    [ -f "$BASELINE" ] || { echo "ERROR: transport baseline missing: $BASELINE" >&2; exit 1; }
    before=$(cat "$BASELINE")
    case "$before" in P2S_TRANSPORTS:|P2S_TRANSPORTS:ssl|P2S_TRANSPORTS:tls|P2S_TRANSPORTS:ssl,tls) ;; *) echo "ERROR: invalid transport baseline" >&2; exit 1 ;; esac
    for transport in ssl tls; do
        if [[ ",${before#P2S_TRANSPORTS:}," == *",$transport,"* ]] && [[ ",$transports," != *",$transport,"* ]]; then
            echo "ERROR: replacement PHP lost the $transport stream transport" >&2
            exit 1
        fi
    done
fi
