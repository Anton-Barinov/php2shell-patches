# php2shell emergency patches

Emergency backports and hardening for **CVE-2026-109618** and **CVE-2026-109619**
("php2shell") — two critical unauthenticated RCE vulnerabilities in PHP,
CVSS v4.0 **9.2**. Patches released upstream 21 Oct 2026.

> **There is no complete mitigation. Updating to a fixed release is the only
> safe choice.** Everything here either (a) packages the official PHP-group
> EOL backports, (b) is a clearly-labelled community backport for PHP 5.6,
> or (c) is emergency hardening that only blocks known attack paths.

---

## Which fix do you need?

| Your PHP | Official fix? | What to do |
|---|---|---|
| 8.5.x < 8.5.12 | ✅ official | `apt upgrade` / distro package, or build from source |
| 8.4.x < 8.4.27 | ✅ official | same |
| 8.3.x < 8.3.36 | ✅ official | same |
| 8.2.x < 8.2.35 | ✅ official | same (note: 8.2 EOL 31 Dec 2026 — plan upgrade) |
| 8.1.x | ⚠️ official *minimal* backport | `patches/php-8.1-minimal.patch` (PHP group) |
| 8.0.x | ⚠️ official *minimal* backport | `patches/php-8.0-minimal.patch` (PHP group) |
| 7.4.x | ⚠️ official *minimal* backport | `patches/php-7.4-minimal.patch` (PHP group) |
| 7.0 – 7.3 | ❌ none | **migrate**, or apply hardening + consider the 7.4 patch after testing |
| 5.6.x | ❌ none | **migrate**. Community backport available: `patches/php-5.6-community-backport.patch` (UNTESTED IN PRODUCTION — test first) |

The "minimal" backports come from the PHP team's own
`PHP-{7.4,8.0,8.1}-CVE-2026-109618-109619` branches. They are a reduced
fix (≈200–300 LOC, not the full ~400-file rewrite shipped to supported
branches) and disable session upload progress outright as a side effect.

---

## What each patch does (minimal / community backports)

All of these follow the same approach as the official PHP-group EOL
backports:

1. **Kill the OOM bailout** (`Zend/zend_alloc.c`) — replace
   `zend_error_noreturn()` + `longjmp()`/`zend_bailout()` on
   out-of-memory with a direct `fprintf(stderr, ...)` + `_exit(1)`.
   The process dies immediately; partially-initialised request state is
   never consumed. This is the core fix for CVE-2026-109618.
2. **Force-disable session upload progress**
   (`ext/session/session.c`) — the confirmed early consumer path for
   CVE-2026-109619. One-line change: `if (!PS(rfc1867_enabled) || 1)`.
3. **Limit retained multipart headers** (`main/rfc1867.c`) — only keep
   `Content-Disposition` and `Content-Type`; drop everything else so an
   attacker cannot exhaust `memory_limit` with hundreds of thousands of
   headers inside a small `post_max_size`.
4. **Reset globals between requests** (`main/main.c`,
   `Zend/zend_execute_API.c`) — clear error handlers, exception handlers,
   `http_globals`, object store, and last-error state at shutdown so a
   dangling pointer cannot survive into the next request on the same
   worker (CVE-2026-109619).

The PHP 5.6 community backport implements the same four changes adapted
for the TSRM-era codebase. **It has been verified to apply cleanly
against `php-5.6.40` source. It has NOT been compile-tested or
production-tested by the PHP Group. Treat it as a last resort and test
thoroughly.**

---

## How to apply

### A. You are on a supported branch (8.2–8.5) — just update

```bash
# Debian / Ubuntu (HestiaCP default)
apt-get update
apt-get install --only-upgrade 'php8.*' php-fpm
systemctl restart 'php8.*-fpm'

# Also update the HestiaCP panel's own PHP:
v-update-sys-hestia hestia-php   # or: apt-get install hestia-php
systemctl restart hestia
```

If your distro has not shipped the package yet, either wait (check
`apt-cache policy php8.4-fpm`) or build from source with the official
tarball + no patch needed (the release already contains the fix).

### B. You are on 7.4 / 8.0 / 8.1 — build a patched PHP

The official minimal patches are in `patches/`. Build like this:

```bash
# Install build deps (Debian/Ubuntu)
apt-get install -y build-essential autoconf bison re2c pkg-config \
    libxml2-dev libssl-dev libcurl4-openssl-dev libsqlite3-dev \
    libonig-dev libzip-dev

# Build
./build/build-patched-php.sh 7.4.33 patches/php-7.4-minimal.patch /opt/php-7.4-patched
#   or 8.1.31 with patches/php-8.1-minimal.patch, etc.

# Verify
/opt/php-7.4-patched/bin/php -v
```

Then point your HestiaCP PHP-FPM template / pool at the new binary, or
install it alongside the system PHP and switch domains over one at a
time. **Run `make test` in the build directory before production.**

### C. You are on 5.6 — last resort

```bash
./build/build-patched-php.sh 5.6.40 patches/php-5.6-community-backport.patch /opt/php-5.6-patched
```

**This patch is a community adaptation of the official minimal approach.
It applies cleanly to php-5.6.40 but has not been validated by the PHP
Group.** You must:

1. `make test` and fix any test fallout.
2. Smoke-test every application that runs on 5.6 (file uploads especially
   — session upload progress is now force-disabled).
3. Have a rollback plan (keep the unpatched binary).

Realistically, **migrating off 5.6 is the right answer.** This patch is
a stopgap for legacy apps you cannot move today.

### D. You cannot update right now — harden

```bash
sudo ./harden/apply-hardening.sh
```

This appends `php_admin_value`/`php_admin_flag` mitigations to every
PHP-FPM pool and to `hestia-php`'s `php.ini`, then restarts services:

- `memory_limit = -1` (removes the controllable OOM trigger)
- `session.upload_progress.enabled = 0`
- conservative `post_max_size` / `upload_max_filesize`
- reduced `max_input_nesting_level` / `max_input_vars`

**This is not a complete mitigation.** PHP's own advisory says so. It
blocks the confirmed attack paths and buys time.

For nginx/Apache edge control, also consider:

```nginx
# Block multipart POSTs on routes that do not need file uploads
# (e.g. your API endpoints, wp-admin/admin-ajax.php if unused, etc.)
location /api/ {
    if ($content_type ~* "multipart/form-data") { return 403; }
    proxy_pass ...;
}
```

Do **not** blanket-block `PHPSESSID` cookies — that breaks normal
sessions and does not stop the multipart parser.

### E. Inventory your fleet first

```bash
sudo ./inventory/scan-php-versions.sh
```

Prints every PHP binary on the host, its version, and whether it is
patched. Run this on every HestiaCP server before you start updating.

---

## After updating — check for compromise

Exploitation leaves anomalous child processes spawned by PHP workers
(`php-fpm`, `apache2`, `httpd`):

```bash
# Look for shells / recon spawned by web workers (last 7 days)
ausexport --interpret 2>/dev/null | grep -E 'php-fpm|apache2' | grep -E '/bin/(ba)?sh|python|curl|wget|nc ' || true

# Web shells in common drop points
find /var/www /tmp /var/tmp /dev/shm -type f \( -name '*.php' -o -name '*.phtml' \) \
    -newer /etc/hostname -size -200k 2>/dev/null | head

# Multipart probes in access logs
grep -l 'multipart/form-data' /var/log/nginx/*access* /var/log/apache2/*access* 2>/dev/null | head
```

If you find indicators: isolate the host, preserve logs, rotate
credentials (DB, panel, SSH keys), and rebuild from known-good.

---

## File layout

```
patches/
  php-7.4-minimal.patch          # official PHP-group minimal backport
  php-8.0-minimal.patch          # official PHP-group minimal backport
  php-8.1-minimal.patch          # official PHP-group minimal backport
  php-5.6-community-backport.patch  # community adaptation — TEST FIRST
harden/
  php.ini-mitigations            # annotated php.ini snippet
  fpm-pool-snippet.conf          # lines to append to FPM pools
  apply-hardening.sh             # automated, idempotent, backs up originals
build/
  build-patched-php.sh           # download + patch + configure + make install
inventory/
  scan-php-versions.sh            # per-host PHP version inventory
```

---

## Credits & sources

- PHP security advisory: <https://www.php.net> (banner: "Critical remote
  code execution vulnerabilities, update now", 21 Oct 2026)
- [GHSA-w8hw-w9fx-j79w](https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w)
  — CVE-2026-109618 (RCE via OOM corruption)
- [GHSA-6wmf-4rv5-p3rp](https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp)
  — CVE-2026-109619 (RCE via stale global state)
- Official minimal backports: php-src branches
  `PHP-7.4-CVE-2026-109618-109619`, `PHP-8.0-CVE-2026-109618-109619`,
  `PHP-8.1-CVE-2026-109618-109619` by arnaud-lb / iluuu1994.
- The 5.6 community backport adapts the same approach. **Not affiliated
  with or endorsed by the PHP Group.**

## Licence

Patches derived from php-src are under the PHP License v3.01.
Original hardening/scripts in this repo: MIT.
