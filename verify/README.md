# Mitigation verifier — CVE-2026-109618 / CVE-2026-109619 ("php2shell")

A small, **controlled, non-destructive** validator to confirm a build is
patched on the real SAPI (mod_php / PHP-FPM) **after** you deploy the fix.

Compatible with **all PHP versions from 5.4 up to 8.5** and supports both
**minimal** and **enhanced-universal** patch flavors.

It is **not an exploit**. It does not attempt code execution. It probes the
observable behaviour that the patch changes and reports observations and inconclusive results. Run it only
against systems you are authorised to test.

## Files

| File | Purpose |
|---|---|
| `cvecheck.php` | Temporary endpoint. Reports build info and exposes three safe probes. Token-gated. |
| `run-cvecheck.sh` | Driver for Linux/macOS (bash + curl). Prints PASS/FAIL per check. |
| `run-cvecheck.ps1` | Driver for Windows PowerShell (5.1+ or 7+). |

## What it observes

The endpoint reports SAPI metadata, multipart field counts, request-local OOM
behaviour and follow-up availability. None of these observations individually
proves coverage of the allocator, upload-progress UAF and serializer mismatch.
An enabled progress setting is not evidence of an enhanced patch. Multipart
caps may come from older `max_input_vars` protection. A missing error body or
HTTP 500/502 may originate in a proxy. See [CHECKER.md](CHECKER.md) for verdicts.

## Usage

1. Open `cvecheck.php` and set `$CVECHECK_TOKEN = 'your_random_secret';`.
2. Copy `cvecheck.php` to your web root or an isolated path:
   ```bash
   cp verify/cvecheck.php /var/www/html/cvecheck.php
   ```
3. Run the driver:

   **Linux / macOS:**
   ```bash
   ./verify/run-cvecheck.sh https://your-site.com/cvecheck.php your_random_secret
   # For virtual hosts tested over localhost:
   ./verify/run-cvecheck.sh http://127.0.0.1/cvecheck.php your_random_secret your-site.com
   ```

   **Windows PowerShell:**
   ```powershell
   .\verify\run-cvecheck.ps1 -Url https://your-site.com/cvecheck.php -Token your_random_secret
   ```

4. **IMPORTANT: Delete `cvecheck.php` immediately after testing!**
   ```bash
   rm /var/www/html/cvecheck.php
   ```

## Interpretation limits

Read [CHECKER.md](CHECKER.md) before interpreting results. Multipart limits, enabled
upload progress, empty HTTP bodies and proxy errors do not prove a security fix.
The diagnostic drivers return 1 for an explicit failed probe and 2 when the
observations still require patch provenance or security regression tests. They
do not return a blanket security PASS. The OOM probe now verifies its local
32M limit and uses a single bounded allocation rather than an unbounded loop.
