# Mitigation verifier — CVE-2026-109618 / CVE-2026-109619 ("php2shell")

A small, **controlled, non-destructive** validator to confirm a build is
patched on the real SAPI (mod_php / PHP-FPM) **after** you deploy the fix.

Compatible with **all PHP versions from 5.4 up to 8.5** and supports both
**minimal** and **enhanced-universal** patch flavors.

It is **not an exploit**. It does not attempt code execution. It probes the
observable behaviour that the patch changes and reports PASS/FAIL. Run it only
against systems you are authorised to test.

## Files

| File | Purpose |
|---|---|
| `cvecheck.php` | Temporary endpoint. Reports build info and exposes three safe probes. Token-gated. |
| `run-cvecheck.sh` | Driver for Linux/macOS (bash + curl). Prints PASS/FAIL per check. |
| `run-cvecheck.ps1` | Driver for Windows PowerShell (5.1+ or 7+). |

## What it checks

| # | Probe | Patched build | Unpatched build |
|---|---|---|---|
| 1 | `max_multipart_body_parts` INI / upload progress status | Reports presence and patch flavor (minimal or enhanced-universal) | ABSENT / insecure upload progress on EOL |
| 2 | POST with 3000 parts | parsed count capped (if `max_multipart_body_parts` active) | all 3000 accepted without limit |
| 3 | request driven to OOM | worker ends immediately (`_exit(1)`), connection dropped with no graceful fatal in HTTP body (CVE-2026-109618 core fix) | graceful `Allowed memory size … exhausted` fatal (old dangerous `longjmp` path) |
| 4 | requests after the OOM | all HTTP 200 (no stale state, clean worker recycle — CVE-2026-109619) | may wedge / serve corrupted state |

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
