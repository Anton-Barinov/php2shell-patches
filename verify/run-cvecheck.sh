#!/usr/bin/env bash
#
# run-cvecheck.sh — drive cvecheck.php and report PASS/FAIL for the
# CVE-2026-109618 / 109619 mitigation. Behavioural validation, not an exploit.
#
# Usage:
#   ./run-cvecheck.sh <base-url-of-cvecheck.php> <token> [host-header]
#
# Examples:
#   ./run-cvecheck.sh https://app.example.com/_cvecheck/cvecheck.php s3cr3t
#   ./run-cvecheck.sh http://localhost/_cvecheck/cvecheck.php s3cr3t app.example.com
#
# The third argument sets an explicit Host: header, useful when probing
# http://localhost on a name-based virtual host.
#
# Requires: curl.

set -u

URL="${1:-}"
TOKEN="${2:-}"
HOSTHDR="${3:-}"

if [ -z "$URL" ] || [ -z "$TOKEN" ]; then
  echo "usage: $0 <base-url-of-cvecheck.php> <token> [host-header]" >&2
  exit 2
fi

CURL=(curl -sS --max-time 30)
[ -n "$HOSTHDR" ] && CURL+=(-H "Host: $HOSTHDR")

pass=0; fail=0; unknown=0
ok()   { echo "  PASS - $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL - $1"; fail=$((fail+1)); }
uncertain() { unknown=$((unknown+1)); echo "  UNKNOWN - $1"; }
info() { echo "  info - $1"; }

echo "== CVE-2026-109618 / 109619 ("php2shell") mitigation check =="
echo "target: $URL"
echo

# ---- Test 1: build info + fix marker --------------------------------------
echo "[1] build info / fix marker"
INFO="$("${CURL[@]}" "$URL?k=$TOKEN&t=info" 2>/dev/null)"
if ! echo "$INFO" | grep -q '^ok$'; then
  bad "endpoint did not respond as expected (token wrong? not deployed?)"
  echo "$INFO" | sed 's/^/       /'
  echo; echo "cannot continue without the endpoint."; exit 1
fi
echo "$INFO" | sed 's/^/     /'
PHPVER=$(echo "$INFO"   | sed -n 's/^php=//p')
MARKER=$(echo "$INFO"   | sed -n 's/^fix_marker=//p')
UPROG=$(echo "$INFO"    | sed -n 's/^session.upload_progress.enabled=//p')
if [ "$MARKER" = "PRESENT" ]; then
  info "multipart limit directive exists; does not establish allocator/session safety"
else
  info "max_multipart_body_parts not in ini (evaluating behavioural probes 2 and 3)"
fi

if [ -z "$UPROG" ] || [ "$UPROG" = "0" ] || [ "$UPROG" = "Off" ]; then
  ok "session.upload_progress.enabled is off (minimal patch flavor or disabled via ini)"
else
  uncertain "upload progress enabled; this setting does not prove an enhanced patch"
fi
echo

# ---- Test 2: multipart part limit -----------------------------------------
echo "[2] multipart part cap (sending 3000 parts)"
BODY=$(mktemp 2>/dev/null || mktemp -t 'cvecheck')
trap 'rm -f "$BODY"' EXIT
B="----cvecheck$$"
{ for i in $(seq 1 3000); do
    printf -- '--%s\r\n' "$B"
    printf 'Content-Disposition: form-data; name="f%d"\r\n\r\n%d\r\n' "$i" "$i"
  done
  printf -- '--%s--\r\n' "$B"
} > "$BODY"
MP="$("${CURL[@]}" -X POST -H "Content-Type: multipart/form-data; boundary=$B" \
      --data-binary "@$BODY" "$URL?k=$TOKEN&t=multipart" 2>/dev/null)"
echo "$MP" | sed 's/^/     /'
PC=$(echo "$MP" | sed -n 's/^POST_count=//p')
if [ -n "$PC" ] && [ "$PC" -lt 3000 ] 2>/dev/null; then
  ok "parser capped parts at $PC (< 3000 sent)"
elif [ -n "$PC" ]; then
  info "parser accepted $PC parts (relies on Test 3 for memory safety)"
else
  bad "multipart probe failed to respond"
fi
echo

# ---- Test 3: OOM ends the worker (no graceful fatal) ----------------------
echo "[3] OOM handling (request-local 32M limit, CVE-2026-109618)"
OOUT=$(mktemp 2>/dev/null || mktemp -t 'cvecheck_out')
OERR=$(mktemp 2>/dev/null || mktemp -t 'cvecheck_err')
HTTP=$("${CURL[@]}" -o "$OOUT" -w '%{http_code}' "$URL?k=$TOKEN&t=oom" 2>"$OERR")
RC=$?
OOMBODY="$(cat "$OOUT")"
echo "     curl_exit=$RC http_code=$HTTP"
echo "$OOMBODY" | sed 's/^/     body> /'
if echo "$OOMBODY" | grep -qi 'Allowed memory size'; then
  uncertain "graceful 'Allowed memory size' fatal returned (verify legacy bailout versus vendor soft-OOM behaviour)"
elif echo "$OOMBODY" | grep -q 'AFTER_OOM_SHOULD_NOT_PRINT'; then
  bad "execution continued past the OOM loop (unexpected)"
elif echo "$OOMBODY" | grep -q 'OOM_PROBE_UNAVAILABLE'; then
  uncertain "request memory limit could not be set safely"
elif echo "$OOMBODY" | grep -q 'graceful_shutdown'; then
  uncertain "graceful shutdown observed; verify vendor soft-OOM fix or legacy bailout"
elif echo "$OOMBODY" | grep -q 'before_oom'; then
  uncertain "OOM endpoint entered and response ended; a dropped response alone cannot prove allocator safety"
else
  uncertain "no OOM entry marker; proxy errors or network failures do not prove a patch"
fi
rm -f "$OOUT" "$OERR"
echo

# ---- Test 4: worker pool healthy after the OOM ----------------------------
echo "[4] server healthy after OOM (3 follow-up requests, CVE-2026-109619)"
SAPI=$(echo "$INFO" | sed -n 's/^sapi=//p')
good=0
for n in 1 2 3; do
  C=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$URL?k=$TOKEN&t=info" 2>/dev/null)
  echo "     request $n -> HTTP $C"
  [ "$C" = "200" ] && good=$((good+1))
done
if [ "$good" -eq 3 ]; then
  ok "all follow-up requests returned 200 (no wedge / stale state)"
elif [ "$SAPI" = "cli-server" ] && [ "$good" -eq 0 ]; then
  ok "single-process cli-server exited on OOM as expected (in PHP-FPM / Apache, master pool respawns workers)"
else
  bad "only $good/3 follow-up requests OK"
fi
echo

# ---- Summary --------------------------------------------------------------
echo "== summary: PASS=$pass FAIL=$fail UNKNOWN=$unknown  (PHP $PHPVER) =="
echo "Reminder: delete cvecheck.php from the server when finished."
if [ "$fail" -gt 0 ]; then exit 1; fi
# This diagnostic does not exercise UAF or serializer object-injection chains.
echo "Allocator/session security still requires vendor patch provenance or controlled regression tests."
exit 2
