# php2shell patches — CVE-2026-109618 / CVE-2026-109619 / CVE-2026-115560 for old PHP (5.4–8.1) & OpenCart / HestiaCP

[![CI](https://github.com/Anton-Barinov/php2shell-patches/actions/workflows/ci.yml/badge.svg)](https://github.com/Anton-Barinov/php2shell-patches/actions/workflows/ci.yml)

Emergency backports and hardening for **CVE-2026-109618**, **CVE-2026-109619**, and **CVE-2026-115560**
("php2shell" & session serializer attack chains) — critical unauthenticated RCE vulnerabilities in PHP.
Upstream patched CVE-2026-109618 and CVE-2026-109619 on 21 Oct 2026 (PHP 8.5.12 / 8.4.27 / 8.3.36 /
8.2.35), while the third vector (**CVE-2026-115560**) is slated for the regular release cycle with an
official recommendation to set `session.upload_progress.enabled = 0`.
**PHP 5.4, 5.5, 5.6, 7.x, 8.0, 8.1 are EOL and get no official fix** — this
repo packages complete EOL backports (official + community) plus emergency hardening
for legacy stacks: **OpenCart, WordPress, Drupal, Joomla, Magento**, any
HestiaCP / VestaCP / cPanel host still running old PHP.

> **There is no complete mitigation. Updating to a fixed release (or applying
> a real patch below) is the only safe choice.** Hardening alone only blocks
> known attack paths and buys time.

---

## 🔍 Quick Server Vulnerability Audit (`php2shell-check`)

Audit your servers for vulnerability status and verify installed patches with a single command:

```bash
curl -fsSL https://raw.githubusercontent.com/Anton-Barinov/php2shell-patches/main/php2shell-check | sudo bash
```

The zero-dependency CLI utility automatically discovers all installed PHP runtimes (CLI, FPM pools, Apache `mod_php`), detects control panel multi-PHP stacks (aaPanel, HestiaCP, Plesk, cPanel, Remi), inspects active configurations and patch signatures, and provides clear remediation steps.

Scanner verdicts describe evidence, not a complete security certification. Unknown
binaries, incomplete inspection and HTTP-only observations return exit **2**.
See [checker evidence and limitations](verify/CHECKER.md), including `--binary`
and the optional bounded CLI `--probe-oom` check.

For advanced options (deep filesystem scan, non-destructive remote URL probe, JSON export for SIEM/Zabbix/Prometheus):
```bash
chmod +x php2shell-check
./php2shell-check --help
```

---

## Two patch flavors — pick your trade-off

| | **minimal** (official PHP-group) | **enhanced-universal** (community) |
|---|---|---|
| Fixes CVE-2026-109618 (OOM → RCE) | ✅ | ✅ |
| Fixes CVE-2026-109619 (upload_progress UAF) | ✅ by **disabling** upload_progress | ✅ by **fixing the root cause** (counters as `zend_long`, no dangling `zval*`) |
| Fixes CVE-2026-115560 (serializer-mismatch RCE) | ✅ by **disabling** upload_progress | ✅ by **delimiter sanitization + `PS(serializer)` reset + `incomplete_classes_only`** |
| `multipart/form-data` file uploads | ✅ work | ✅ work |
| Session upload **progress bar** | ❌ disabled | ✅ **still works** |
| Blocks session-fixation via POST body | ❌ | ✅ (PR #22113) |
| Sanitizes filename in session file (LFI / handler-mismatch) | ❌ | ✅ |
| Resets `PS(serializer)` between FPM requests | ❌ | ✅ |
| Officially blessed by PHP Group | ✅ (7.4/8.0/8.1 branches) | ❌ (community, but combines official OOM fix + root-cause UAF fix + full serializer defense) |

**Rule of thumb:**
- Want the safest, most conservative fix and don't care about upload
  progress bars → **minimal**.
- Need working forms / progress bars (e.g. OpenCart admin product forms,
  large file uploads) and want the extra fixation/filename/serializer
  fixes → **enhanced-universal**.

Both keep normal `multipart/form-data` POST parsing intact — product forms,
image uploads, category edits, etc. all continue to work. The only functional
difference is whether the optional session-based upload-progress tracker
stays enabled.

---

## Which fix do you need?

| Your PHP | Official fix? | What to do |
|---|---|---|
| 8.5.x < 8.5.12 | ⚠️ partial (fixed 109618/19, CVE-2026-115560 pending next release) | `apt upgrade` + set `session.upload_progress.enabled = Off` in `php.ini` |
| 8.4.x < 8.4.27 | ⚠️ partial (fixed 109618/19, CVE-2026-115560 pending next release) | same |
| 8.3.x < 8.3.36 | ⚠️ partial (fixed 109618/19, CVE-2026-115560 pending next release) | same |
| 8.2.x < 8.2.35 | ⚠️ partial (fixed 109618/19, CVE-2026-115560 pending next release) | same (note: 8.2 EOL 31 Dec 2026 — plan upgrade) |
| 8.1.x | ⚠️ backport | `php-8.1-minimal.patch` (PHP group) **or** `php-8.1-enhanced-universal.patch` (vanilla php.net) **or** `php-8.1-enhanced-remicollet.patch` (for Remi's tree) |
| 8.0.x | ⚠️ backport | `php-8.0-minimal.patch` (PHP group) **or** `php-8.0-enhanced-universal.patch` (vanilla php.net) **or** `php-8.0-enhanced-remicollet.patch` (for Remi's tree) |
| 7.4.x | ⚠️ backport | `php-7.4-minimal.patch` (official) **or** `php-7.4-enhanced-universal.patch` (vanilla php.net) **or** `php-7.4-enhanced-remicollet.patch` (for Remi's tree) |
| 7.3.x | ⚠️ backport | `php-7.3-minimal.patch` **or** `php-7.3-enhanced-universal.patch` (vanilla php.net) **or** `php-7.3-enhanced-remicollet.patch` (for Remi's tree) |
| 7.2.x | ⚠️ backport | `php-7.2-minimal.patch` **or** `php-7.2-enhanced-universal.patch` (vanilla php.net) **or** `php-7.2-enhanced-remicollet.patch` (for Remi's tree) |
| 7.1.x | ⚠️ backport | `php-7.1-minimal.patch` **or** `php-7.1-enhanced-universal.patch` (vanilla php.net, contributed by @lovelock) **or** `php-7.1-enhanced-remicollet.patch` (for Remi's tree) |
| 7.0.x | ⚠️ backport | `php-7.0-enhanced-universal.patch` (pristine vanilla php.net tarball) **or** `php-7.0-enhanced-remicollet.patch` (for Remi's tree & Debian 9 `7.0.33-0+deb9u12`) |
| 5.6.x | ❌ none | **migrate**. Community backports: `php-5.6-enhanced-universal.patch` (vanilla php.net tarball) or `php-5.6-enhanced-remicollet.patch` (for [remicollet/php-src-security](https://github.com/remicollet/php-src-security) backports tree) or `php-5.6-minimal-remicollet.patch` (minimal for Remi's tree) or `php-5.6-minimal.patch` / `php-5.6-community-backport.patch` (minimal for vanilla). Verified on real builds. |
| 5.5.x | ❌ none | **migrate**. Community backports: `php-5.5-enhanced-universal.patch` (vanilla php.net tarball) or `php-5.5-community-backport.patch` (minimal). Compiled & verified on real Linux builds. |
| 5.4.x | ❌ none | **migrate**. Community backports: `php-5.4-enhanced-universal.patch` (vanilla php.net tarball) or `php-5.4-community-backport.patch` (minimal). Compiled & verified on real Linux builds. |

---

## What the patches do

### minimal (official PHP-group approach)

1. **Kill the OOM bailout** (`Zend/zend_alloc.c`) — replace
   `zend_error_noreturn()` + `longjmp()`/`zend_bailout()` on
   out-of-memory with `fprintf(stderr, ...)` + `_exit(1)`.
   The process dies immediately; partially-initialised request state is
   never consumed. Core fix for CVE-2026-109618.
2. **Force-disable session upload progress** (`ext/session/session.c`) —
   `if (!PS(rfc1867_enabled) || 1)`. One-line, breaks the confirmed
   CVE-2026-109619 consumer path.
3. **Limit retained multipart headers** (`main/rfc1867.c`) — keep only
   `Content-Disposition` and `Content-Type`; drop the rest so an attacker
   cannot exhaust `memory_limit` with hundreds of thousands of headers.
4. **Reset globals between requests** (`main/main.c`,
   `Zend/zend_execute_API.c`, `main/SAPI.c`) — clear error handlers,
   exception handlers, `http_globals`, object store, last-error state at
   shutdown (CVE-2026-109619).

### enhanced-universal (community — root-cause fix, keeps progress bars)

Takes everything from minimal **except** step 2, and replaces it with a
root-cause fix plus extra hardenings:

1. **OOM bailout → `_exit(1)`** — same as minimal (CVE-2026-109618).
2. **Counters as `zend_long` + `php_session_rfc1867_sync_counters()`**
   (`ext/session/php_session.h`, `ext/session/session.c`) — instead of
   storing raw `zval*` bucket pointers into the live progress `HashTable`
   (which dangle when the table is separated/reallocated → UAF), store
   plain `zend_long` and re-resolve each counter from the live array on
   every update. **Fixes CVE-2026-109619 at the root while keeping
   upload_progress fully functional.** (Approach from
   [eness/php2shell-...-PoC](https://github.com/eness/php2shell-CVE-2026-109618-CVE-2026-109619-PoC).)
3. **Session-fixation fix** (`ext/session/session.c`) — respect
   `session.use_only_cookies` when accepting `PHPSESSID` from POST body
   (upstream [PR #22113](https://github.com/php/php-src/pull/22113)).
4. **Filename sanitization** (`ext/session/session.c`) — strip null
   bytes, `|`, CR/LF and cap at 255 chars before storing the upload
   filename into the session file. Blocks session-file PHP-code / object
   injection via LFI and serializer-handler mismatch (attack chains from
   [ikow/php2shell-poc](https://github.com/ikow/php2shell-poc)).
5. **Reset `PS(serializer)` between requests** (`ext/session/session.c`) —
   prevents cross-request handler mismatch in PHP-FPM.
6. **Multipart header limiting + global resets** — same as minimal.
7. **Chain-C decode window closed** (`ext/standard/var.c`,
   `ext/standard/var_unserializer.re`, `php_incomplete_class.h`,
   `ext/session/session.c`) — during the session upload-progress decode
   (which runs before user code/classes can exist), never look up classes:
   no autoload, no `unserialize_callback_func`, no `__wakeup` — only
   `__PHP_Incomplete_Class`, with a lossless raw-payload round-trip for
   `C:` custom serializers. (Attack chains from
   [ikow/php2shell-poc](https://github.com/ikow/php2shell-poc).)
8. **`post_max_size` bypass fixed** (`main/rfc1867.c`) — the official
   GHSA-2cv3-554h-jpmh fix from PHP 8.2.35: stop reading the multipart
   body once `read_post_bytes` exceeds `post_max_size` when Content-Length
   is absent or lying, plus the matching "Actual POST length does not match
   Content-Length" warning. (Verified with `tests/feedpost/`: a 1 MB body
   with `post_max_size=100K` — pre-patch build accepted all 1 048 576
   bytes, patched build truncates and warns.)

> The enhanced patch does **not** close the `var_destroy`
> unserialize UAF (Chain B in ikow's research) — it is only reachable if
> the application exposes `unserialize()` to attacker data. Update to a
> fixed PHP release to close that path completely.

---

## 🛡️ CVE-2026-115560 — The 3rd PHP RCE Vector (Session Serializer Handler Mismatch)

On 23–26 October 2026, PHP assigned **CVE-2026-115560** to a third RCE vector related to session upload progress:

### 1. Root Cause & Attack Mechanism
- **The Vector:** When `session.upload_progress.enabled` is active, multipart file uploads write tracking data directly into `$_SESSION`. If an application is configured with `session.serialize_handler = php_serialize` (or `php_binary`) and at runtime switches via `ini_set('session.serialize_handler', 'php')` before calling `session_start()`, or when PHP-FPM workers retain serializer state across requests, a serializer format mismatch occurs.
- In PHP's default `php` serializer, variables are delimited by the pipe character (`|`), formatted as `<var_name>|<serialized_value>`.
- An attacker supplying a crafted upload progress key containing `|` followed by serialized objects can cause the session decoder to instantiate arbitrary objects, enabling deserialization gadget chain execution (RCE).

### 2. Status in Upstream PHP (8.2.35 / 8.3.36 / 8.4.27 / 8.5.12)
- Upstream emergency releases on 21 Oct 2026 addressed **CVE-2026-109618** and **CVE-2026-109619**, but **did not** patch CVE-2026-115560.
- The PHP team scheduled the upstream fix for the next regular monthly bugfix release.
- **Official PHP mitigation for 8.2+:**
  ```ini
  session.upload_progress.enabled = 0
  ```

### 3. Status in This Repository's Backports (PHP 5.4–8.1)
Both patch flavors in this repository already fully protect against CVE-2026-115560:
- **`minimal` patches:** **100% immune** because `session.upload_progress` is completely disabled or stripped from the engine.
- **`enhanced` patches:** **100% protected** by multi-layer defense in depth:
  1. **Delimiter Sanitization:** Strips null bytes (`\0`), pipe (`|`), `\r`, and `\n` from upload progress file and field names in `rfc1867.c` / `session.c`. An attacker cannot inject the `|` delimiter into the serialized session stream.
  2. **PHP-FPM Worker Isolation:** Resets `PS(serializer) = NULL` in `rshutdown` between requests in `session.c`, preventing serializer state leakage across requests.
  3. **Strict Decode Gate:** Enforces `incomplete_classes_only` during progress decoding, preventing autoloader execution or magic methods (`__wakeup`, `__destruct`) even if deserialization were triggered.

---

## How to apply

### A. Supported branch (8.2–8.5) — just update

```bash
apt-get update
apt-get install --only-upgrade 'php8.*' php-fpm
systemctl restart 'php8.*-fpm'
# HestiaCP panel's own PHP:
apt-get install hestia-php && systemctl restart hestia
```

### B. PHP 5.4 / 5.5 / 5.6 / 7.x / 8.0 / 8.1 — build patched

```bash
apt-get install -y build-essential autoconf bison re2c pkg-config \
    libxml2-dev libssl-dev libcurl4-openssl-dev libsqlite3-dev \
    libonig-dev libzip-dev

# Enhanced (recommended if you need working upload progress / OpenCart forms):
./build/build-patched-php.sh 7.4.33 patches/php-7.4-enhanced-universal.patch /opt/php-7.4-patched
# Or for PHP 7.3.33 / 7.2.34 / 7.1.33 / 7.0.33:
./build/build-patched-php.sh 7.3.33 patches/php-7.3-enhanced-universal.patch /opt/php-7.3-patched
./build/build-patched-php.sh 7.2.34 patches/php-7.2-enhanced-universal.patch /opt/php-7.2-patched
./build/build-patched-php.sh 7.1.33 patches/php-7.1-enhanced-universal.patch /opt/php-7.1-patched
./build/build-patched-php.sh 7.0.33 patches/php-7.0-enhanced-universal.patch /opt/php-7.0-patched
./build/build-patched-php.sh 5.6.40 patches/php-5.6-enhanced-universal.patch /opt/php-5.6-patched
./build/build-patched-php.sh 5.5.38 patches/php-5.5-enhanced-universal.patch /opt/php-5.5-patched
./build/build-patched-php.sh 5.4.45 patches/php-5.4-enhanced-universal.patch /opt/php-5.4-patched

# Or minimal (official approach, disables upload progress):
./build/build-patched-php.sh 7.4.33 patches/php-7.4-minimal.patch /opt/php-7.4-patched
./build/build-patched-php.sh 7.3.33 patches/php-7.3-minimal.patch /opt/php-7.3-patched
./build/build-patched-php.sh 7.2.34 patches/php-7.2-minimal.patch /opt/php-7.2-patched
./build/build-patched-php.sh 7.1.33 patches/php-7.1-minimal.patch /opt/php-7.1-patched
./build/build-patched-php.sh 5.6.40 patches/php-5.6-community-backport.patch /opt/php-5.6-patched
./build/build-patched-php.sh 5.5.38 patches/php-5.5-community-backport.patch /opt/php-5.5-patched
./build/build-patched-php.sh 5.4.45 patches/php-5.4-community-backport.patch /opt/php-5.4-patched
```

Then switch HestiaCP FPM pools / templates to the new binary, or install
alongside system PHP and migrate domains one at a time.
**Run `make test` before production.**

### B2. In-place swap over the distro PHP (drop-in replacement)

Replacing the distro binaries themselves (`/usr/bin/phpX.Y`,
`/usr/sbin/php-fpmX.Y`, `/usr/bin/php-cgiX.Y` while keeping the packaged
extensions from the scan dir) is where live sites get hurt — not by the
patch, but by the build configuration. Use the swap script:

```bash
./deploy/swap-system-php.sh 7.3.33 php-7.3-enhanced-universal.patch
./deploy/swap-system-php.sh 8.2.35            # vanilla 8.2.35+ already fixed
```

It refuses to swap if any module present in the installed build would end
up neither compiled into the new binary nor available as a packaged `.so`
(the `--disable-all` / missing-`filter` trap that causes
`Undefined constant "INPUT_GET"` fatals → HTTP 500 on WordPress/OpenCart),
and it handles the other traps we hit: pinned `extension_dir`, un-exported
pcre symbols (`-fvisibility=hidden`, external PCRE ≤ 7.3), `Type=notify`
fpm units, double-loaded modules, plus a post-swap module verification.

Every config the script rewrites is backed up first (a `cfg-backup` block:
fixed-name `<file>.swapbak`, first swap owns it, reruns never clobber), and
a post-swap smoke block runs `php-fpm -t`, `php-cgi -v` and asserts
`mysqli.default_socket` plus the ionCube loader **before** the restart puts
traffic on the new build.

Rollback of a single version:

```bash
./deploy/restore-system-php.sh 7.3           # --dry-run to preview
# hosts swapped before config backups existed: backfill them first
./deploy/retro-swapbak.sh 7.3
```

`restore-system-php.sh` restores the *earliest* `*.bak-*` per binary (the
oldest backup is the untouched distro — later swaps only ever backed up
already-swapped binaries), stops fpm first (a running master would fail
`cp` with `Text file busy`), restores every `*.swapbak` (extension marks,
`Type=notify` unit), drops the files we created over nothing
(`00-swap-extension-dir.ini`, the ioncube mirror), then `php-fpm -t` +
restart + `is-active`.

**Read [deploy/DEPLOYMENT.md](deploy/DEPLOYMENT.md) before deploying** —
it documents every failure mode with real symptoms and log snippets
(HTTP 500s, dead fpm pools, unloadable packaged `.so`) and the tested
rollback procedure.

### B3. aaPanel / Baota (BT Panel) deployment

On aaPanel / Baota hosting environments, PHP versions live in `/www/server/php/<ver>` (e.g., `54`, `55`, `56`, `70`, `71`, `72`, `73`, `74`, `80`, `81`). Use `deploy/swap-aapanel-php.sh` for an offline build, dependency checks, and automated zero-downtime swap with rollback:

```bash
# Check status and patch state:
./deploy/swap-aapanel-php.sh status 74

# Step 1: Offline build with RAM-safe concurrency and dynamic dependency discovery
./deploy/swap-aapanel-php.sh build 74 patches/php-7.4-enhanced-universal.patch

# Step 2: Atomic install (snapshots prefix -> stops FPM -> make install -> tests config -> restarts)
# Automatically rolls back if php-fpm -t fails, modules are missing, or patch verification fails:
./deploy/swap-aapanel-php.sh install 74

# Roll back anytime:
./deploy/swap-aapanel-php.sh rollback 74
```

### C. PHP 5.6 — last resort

```bash
# Sources: use the GitHub tag (museum.php.net may time out)
curl -L -o php-5.6.40.tar.gz https://github.com/php/php-src/archive/refs/tags/php-5.6.40.tar.gz
mkdir php-5.6 && tar xzf php-5.6.40.tar.gz -C php-5.6 --strip-components=1
cd php-5.6
./buildconf --force          # GitHub tags ship without a configure script

# Enhanced (recommended — root-cause UAF fix, keeps upload progress / forms):
# - On vanilla php.net tarballs:
patch -p1 < ../patches/php-5.6-enhanced-universal.patch
# - On Remi Collet's security backports tree (remicollet/php-src-security):
# patch -p1 < ../patches/php-5.6-enhanced-remicollet.patch

./configure --prefix=/opt/php-5.6-patched --disable-cgi --enable-fpm \
    --without-openssl --with-zlib --enable-mbstring --with-sqlite3 \
    --with-pdo-sqlite --enable-session --with-gettext --enable-sockets \
    --without-curl --without-pear --disable-phpdbg
make -j"$(nproc)"

# Or minimal (force-disables upload progress):
patch -p1 < ../patches/php-5.6-community-backport.patch
# ... same configure/make
```

### Windows Pre-built Binaries

Windows x64 and x86 binaries built and packaged with MSVC toolchains by [@Jan-E](https://github.com/Jan-E) (Apache Lounge):
- **Apache Lounge Release Thread**: [https://www.apachelounge.com/viewtopic.php?t=6359](https://www.apachelounge.com/viewtopic.php?t=6359) (Includes official updated x64/x86 NTS & TS builds for PHP 7.4, 8.0, 8.1, 8.2, 8.3, 8.4, 8.5; PHP 5.6.40 VC11 x86 NTS released; 7.2, 7.3 builds in progress)
- **PHP 5.6.40 (VC11 x86 NTS)**: [`php-5.6.40-nts-Win32-VC11-x86.zip`](https://phpdev.toolsforresearch.com/php-5.6.40-nts-Win32-VC11-x86.zip)

> **MSVC / NMake Note:** All enhanced patches (5.6 through 8.1) bundle pre-generated C diffs directly in `ext/standard/var_unserializer.c` alongside `.re`, so building under Windows NMake or older Linux distributions does not require `re2c` or specific parser toolchains.

**Build troubleshooting (PHP 5.6 on modern toolchains):**

| Problem | Cause | Fix |
|---|---|---|
| `curl: (28) Failed to connect to museum.php.net` | mirror timeout | Use the GitHub tag URL above |
| `./configure: No such file or directory` | GitHub tags have no generated configure | Run `./buildconf --force` first (needs autoconf) |
| `configure: error: ... libcurl ... easy.h` | `libcurl4-openssl-dev` missing | `apt-get install libcurl4-openssl-dev` **or** drop `--with-curl` |
| `unknown type name 'ZEND_COLD'` / `'ZEND_NORETURN'` | These macros don't exist in PHP 5.6 (added in PHP 7) | **Already fixed in both 5.6 patches** — declaration is plain `ZEND_API void` |
| `unknown type name 'zend_long'` | `zend_long` added in PHP 7.0 | **Already fixed in enhanced 5.6 patch** — uses `long` |
| `re2c: command not found` during `make` | The patch updates `var_unserializer.re`, so make regenerates `var_unserializer.c` from it | `apt-get install re2c` **or** `touch ext/standard/var_unserializer.c` (the patch already ships the generated `.c`) |
| `'*var_hash' is a pointer` (compile error in `var.c`) | You downloaded a stale copy of the enhanced 5.6 patch (before fix `a6c3d04`) | `git pull` — always use the latest patch from this repo |

Community adaptation of the official minimal approach (plus root-cause UAF
fix for the enhanced flavor). Applies cleanly to `php-5.6.40`; compile-tested
on Ubuntu 22.04 (make OK, multipart uploads + `is_uploaded_file()` verified,
`session.upload_progress.enabled` stays On with the enhanced patch).
**Not validated by the PHP Group.** You must still run `make test`,
smoke-test your apps, and keep a rollback binary. **Migrating off 5.6 is
the real answer** — this is a stopgap for legacy apps (old OpenCart 1.x/2.x,
custom CMS) you cannot move today.

### D. Cannot update right now — harden

```bash
sudo ./harden/apply-hardening.sh
```

Appends `php_admin_value`/`php_admin_flag` mitigations to every PHP-FPM
pool and `hestia-php`'s `php.ini`, then restarts services:

- `memory_limit = -1` (removes the controllable OOM trigger)
- `session.upload_progress.enabled = 0`
- conservative `post_max_size` / `upload_max_filesize`
- reduced `max_input_nesting_level` / `max_input_vars`

**Not a complete mitigation** (PHP says so). Blocks known paths, buys time.
**Note:** if you later install the enhanced patch, you can re-enable
`session.upload_progress` — the patch makes it safe.

Edge (nginx) control for routes that don't need uploads:

```nginx
location /api/ {
    if ($content_type ~* "multipart/form-data") { return 403; }
    proxy_pass ...;
}
```

Do **not** blanket-block `PHPSESSID` cookies — breaks sessions, doesn't
stop the parser.

### E. Inventory first

```bash
sudo ./inventory/scan-php-versions.sh
```

Every PHP binary on the host, version, patch status. Run on every server
before updating.

---

## After updating — check for compromise

```bash
# Shells / recon spawned by web workers (last 7 days)
ausexport --interpret 2>/dev/null | grep -E 'php-fpm|apache2' | grep -E '/bin/(ba)?sh|python|curl|wget|nc ' || true

# Web shells in drop points
find /var/www /tmp /var/tmp /dev/shm -type f \( -name '*.php' -o -name '*.phtml' \) \
    -newer /etc/hostname -size -200k 2>/dev/null | head

# Multipart probes in access logs
grep -l 'multipart/form-data' /var/log/nginx/*access* /var/log/apache2/*access* 2>/dev/null | head
```

If found: isolate host, preserve logs, rotate credentials (DB, panel, SSH),
rebuild from known-good.

---

## File layout

```
patches/
  php-8.1-minimal.patch              # official PHP-group minimal backport
  php-8.1-enhanced-universal.patch   # community: root-cause UAF fix + var_unserializer.c bundled
  php-8.1-enhanced-remicollet.patch  # community enhanced for 8.1: adapted for remicollet tree
  php-8.0-minimal.patch              # official PHP-group minimal backport
  php-8.0-enhanced-universal.patch   # community: root-cause UAF fix + var_unserializer.c bundled
  php-8.0-enhanced-remicollet.patch  # community enhanced for 8.0: adapted for remicollet tree
  php-7.4-minimal.patch              # official PHP-group minimal backport
  php-7.4-enhanced-universal.patch   # community: root-cause UAF fix + var_unserializer.c bundled
  php-7.4-enhanced-remicollet.patch  # community enhanced for 7.4: adapted for remicollet tree
  php-7.3-minimal.patch              # backport for PHP 7.3
  php-7.3-enhanced-universal.patch   # community enhanced for 7.3 (vanilla php.net tarball)
  php-7.3-enhanced-remicollet.patch  # community enhanced for 7.3: adapted for remicollet tree
  php-7.2-minimal.patch              # backport for PHP 7.2
  php-7.2-enhanced-universal.patch   # community enhanced for 7.2 (vanilla php.net tarball)
  php-7.2-enhanced-remicollet.patch  # community enhanced for 7.2: adapted for remicollet tree
  php-7.1-minimal.patch              # backport for PHP 7.1
  php-7.1-enhanced-universal.patch   # community enhanced for 7.1 (vanilla php.net tarball)
  php-7.1-enhanced-remicollet.patch  # community enhanced for 7.1: adapted for remicollet tree
  php-7.0-enhanced-universal.patch   # community enhanced for 7.0 (vanilla php.net tarball)
  php-7.0-enhanced-remicollet.patch  # community enhanced for 7.0: adapted for Remi tree & Debian 9 (deb9u12)
  php-5.6-enhanced-universal.patch   # community enhanced for 5.6: root-cause UAF fix (vanilla php.net tarball)
  php-5.6-enhanced-remicollet.patch  # community enhanced for 5.6: adapted for remicollet/php-src-security tree
  php-5.6-minimal-remicollet.patch   # minimal for 5.6: force-disables upload progress (remicollet tree)
  php-5.6-minimal.patch              # minimal for 5.6: force-disables upload progress (vanilla php.net)
  php-5.6-community-backport.patch   # community minimal for 5.6 (force-disable) — legacy alias
harden/
  php.ini-mitigations                # annotated php.ini snippet
  fpm-pool-snippet.conf              # lines to append to FPM pools
  apply-hardening.sh                 # automated, idempotent, backs up originals
build/
  build-patched-php.sh               # download + patch + configure + make install
deploy/
  swap-system-php.sh                 # in-place distro swap: build + backup + smoke + restart
  swap-aapanel-php.sh                # aaPanel / Baota (BT Panel) builder and installer with auto-rollback
  restore-system-php.sh              # rollback one version (earliest *.bak-* + *.swapbak)
  retro-swapbak.sh                   # backfill .swapbak on hosts swapped by older scripts
  DEPLOYMENT.md                      # every pitfall we hit, with real symptoms/fixes
inventory/
  scan-php-versions.sh               # per-host PHP version inventory
tests/
  feedpost/                          # post_max_size bypass verification harness
                                      # (feedtest.php + run.sh <php> <src>: build the
                                      #  ext against a configured tree without phpize,
                                      #  missing Content-Length, 1 MB multipart,
                                      #  see tests/feedpost/README.md)
  cfg-backup-test.sh                 # 4-scenario unit test for the config-backup
                                      #  block of deploy/swap-system-php.sh
  ioncube-mirror-test.sh             # 7-scenario unit test for the loader-ini
                                      #  mirror block of deploy/swap-system-php.sh
  smoke-test.sh                      # 6-scenario unit test for the pre-restart
                                      #  smoke block of deploy/swap-system-php.sh
  retro-test.sh                      # 6-scenario unit test for retro-swapbak.sh
  restore-test.sh                    # 8-scenario unit test for restore-system-php.sh
                                      #  (sandboxed end-to-end run of the real script)
  cvecheck-test.sh                   # 7-scenario unit test for verify/ probe suite
  stress.php                         # high-volume nested array & memory stress harness
  stress-test.sh                     # test driver for array stress and boundary verification
  run-all.sh                         # one-command gate: runs every harness above
```

---

## Tested environments (OpenCart / HestiaCP)

**PHP 5.4.45 enhanced-universal & community-backport** — compiled & verified on Linux (Ubuntu 24.04, GCC 13.3.0):

- ✅ `patch -p1` applies cleanly on pristine vanilla `php-5.4.45.tar.bz2` (CI dry-run matrix green across all commits).
- ✅ C89 / modern GCC compatibility: compiles cleanly with `-std=gnu89 -Wno-error=incompatible-pointer-types`.
- ✅ Session destruction engine fix: in PHP 5.4, `PS(session_status)` was historically set only after session initialize; moving status activation prior to decode allows `php_session_destroy()` to cleanly remove the session file upon refused decode instead of failing with `Trying to destroy uninitialized session`.
- ✅ Upstream parity backport: includes `max_multipart_body_parts` INI directive and counter, plus duplicate MIME header sanitization (`php_mime_get_hdr_value`) and `zend_llist` zeroing.
- ✅ `post_max_size` bypass (GHSA-2cv3-554h-jpmh): verified with `tests/feedpost/` (missing Content-Length, 1 MB multipart, `post_max_size=100K`). Pristine unpatched build accepts all 1 048 576 bytes; patched build truncates to 102 381 bytes and emits official warning `Actual POST length does not match Content-Length`.
- ✅ PHPT test suite (CVE-2026-109619): all 4 bundled security tests (`rfc1867.phpt`, `rfc1867_no_user_code.phpt`, `rfc1867_incomplete_class_reserved_props.phpt`, `incomplete_class_raw_payload_markers.phpt`) pass 100%.
- ✅ Array parsing & memory stress test (`tests/stress.php`): deeply nested array parsing up to depth 60, wide 2000-key arrays, and hash mutation pass cleanly with deterministic checksum (`STRESS_TEST_OK`).

**PHP 5.5.38 enhanced-universal & community-backport** — compiled & verified on Linux (Ubuntu 24.04, GCC 13.3.0):

- ✅ `patch -p1` applies cleanly on pristine vanilla `php-5.5.38.tar.bz2` (CI dry-run matrix green).
- ✅ Compiles cleanly with `-std=gnu89 -Wno-error=incompatible-pointer-types`.
- ✅ Upstream parity backport: includes `max_multipart_body_parts` INI directive and counter, plus duplicate MIME header sanitization (`php_mime_get_hdr_value`) and `zend_llist` zeroing.
- ✅ `post_max_size` bypass (GHSA-2cv3-554h-jpmh): verified with `tests/feedpost/`. Pristine build accepts 1 MB; patched build truncates to 102 381 bytes and emits official warning.
- ✅ PHPT test suite: all 4 bundled security tests pass 100%.
- ✅ Array parsing & memory stress test (`tests/stress.php`): depth 60, 2000 keys pass cleanly (`STRESS_TEST_OK`).

**PHP 5.6.40 enhanced-universal** — built on Ubuntu 22.04 (HestiaCP 1.10.5 host):

- ✅ `patch -p1` applies cleanly on pristine `php-5.6.40`
  (official php.net tarball **and** GitHub tag archive)
- ✅ `buildconf --force` + `configure` + `make -j2` → success, binary runs
- ✅ `multipart/form-data` POST with fields + file upload works
  (`$_POST`, `$_FILES`, `is_uploaded_file()` all correct)
- ✅ `session.upload_progress.enabled => On` (stays enabled — root-cause fix)
- ✅ Enhanced patch at official PHP 8.2.35 parity (v4, 2026-10-22):
  chain-C refusal (`rfc1867_decode_refused` guard stops
  `php_session_rfc1867_update()` and `php_session_rfc1867_cleanup()` after a
  refused decode — a refused decode leaves exactly one warning and the
  destroyed record stays gone), reserved-props rejection in
  `var_unserializer` (a record carrying the incomplete-class bookkeeping
  property names is refused, not silently overwritten), lossless `C:`
  write-back gated to the upload-progress window only
  (`php_var_serialize_set_incomplete_classes_only` — a plain `serialize()`
  of a forged `__PHP_Incomplete_Class_Serialized` property still emits
  `O:`), `$_SESSION` dropped after the upload, per-file `bytes_processed`
  counters written at event time
- ✅ Official 8.2.35 tests adapted for PHP 5.6: `rfc1867_no_user_code.phpt`
  and `rfc1867_incomplete_class_reserved_props.phpt` (bundled in the patch)
  plus `incomplete_class_raw_payload_markers.phpt` (regression control) —
  all PASS under php-cgi; the two rfc1867 tests FAIL on pristine 5.6.40
  (discriminating). 5.6 adaptations: no `getenv()` without arguments
  (PHP 7.1+), `implode()`-form `proc_open()` (the array form is 7.4+),
  heredoc close on a separate line (5.6 rejects `PHP);`), and a
  non-existent class instead of `ArrayObject` for the incomplete-class
  case (`unserialize($s, ['allowed_classes'=>...])` is 7.0+)
- ✅ `make test` subset end-to-end (pristine tarball + this patch → build;
  1376 tests: ext/session, serialize, file, general_functions, main;
  php-cgi tests included): **1162 pass / 210 skip / 2 fail / 2 warn** —
  the 2 fails are the pre-existing `parse_ini_*` cases, identical to the
  stock build's fail list
- ✅ `post_max_size` bypass (GHSA-2cv3-554h-jpmh) — via the
  `tests/feedpost/` harness (missing Content-Length, 1 MB multipart,
  `post_max_size=100K`): pre-patch build accepts all **1 048 576** bytes,
  patched build truncates to **102 381** and emits the official
  "Actual POST length does not match Content-Length" warning
- ✅ Upload-progress decode window (CVE-2026-109619) — session file seeded
  `Evill|O:5:"Evill":0:{}`, `unserialize_callback_func=var_dump`, upload via
  `PHP_SESSION_UPLOAD_PROGRESS` field: pre-patch build runs user code
  during upload (`string(5) "Evill"` ×2 in the response); patched build
  emits nothing, still writes the progress key, and re-encodes the seeded
  payload losslessly; `__wakeup` never fires
- ✅ Remi Collet security tree (`remicollet/php-src-security`,
  branch `PHP-5.6-security-backports`) with `php-5.6-enhanced-remicollet.patch`
  (same v4 parity, adapted to Remi's `if (progress->data)` backport):
  `patch -p1` clean, `buildconf --force` + `configure` + `make -j4` OK,
  subset **1164 pass / 210 skip / 2 fail (pre-existing `parse_ini_*`) /
  3 warn**, the three discriminators PASS under php-cgi

**PHP 7.0.33 enhanced-universal**:

- ✅ `patch -p1` applies cleanly on pristine `php-7.0.33` (21 files)
- ✅ `configure` + `make` → success, CLI binary runs and passes smoke test
- ✅ Incomplete class decode window closed: `incomplete_classes_only` gate in `var_unserializer` before class lookup in `O:` handler (no autoload / callback / `__wakeup`)
- ✅ Discriminator harness matches official golden output (`bool(false)` + `string(20) "upload_progress_key|"`)
- ✅ Official 8.2.35 tests adapted for PHP 7.0 and bundled in the patch:
  `rfc1867_no_user_code.phpt`, `rfc1867_incomplete_class_reserved_props.phpt`
  (plus `rfc1867.phpt`, `rfc1867_sid_invalid.phpt`, regression control
  `incomplete_class_raw_payload_markers.phpt` in the tree). 7.0-specific
  adaptation: the 5.6-style `$_SERVER` environment loop — no-argument
  `getenv()` only exists since PHP 7.1 and aborts a stock 7.0 test run
  with `ArgumentCountError`. Result: **4 pass / 1 fail**, the fail is
  `rfc1867_sid_invalid.phpt` — stock parity, it fails identically on the
  untouched distro 7.0.33 backup (session save-path/env wording)
- ✅ Automated CI dry-run in GitHub Actions verified green
- ✅ 64-bit architecture verification (Issue #6): `#include "zend_execute.h"` added to `Zend/zend_alloc.c` ensuring `zend_get_executed_filename_ex()` return pointer is not truncated. Verified on x86_64 Linux: `tests/lang/bug45392.phpt` and `memory_limit` exhaustion trigger clean fatal errors with 0 segfaults.
- ✅ Dedicated `php-7.0-enhanced-remicollet.patch` verified against `remicollet/php-src-security` (`PHP-7.0-security-backports` branch).

**PHP 7.1.33 enhanced-universal & remicollet**:

- ✅ `patch -p1` applies cleanly on pristine `php-7.1.33` and `php-7.1.9` (contributed by @lovelock)
- ✅ Dedicated `php-7.1-enhanced-remicollet.patch` applies with 0 rejects against `remicollet/php-src-security` (`PHP-7.1-security-backports` branch)
- ✅ Enhanced patch at official PHP 8.2.35 parity: chain-C refusal, reserved-props rejection, `post_max_size` warning hooks, `$_SESSION` dropped after upload
- ✅ Official 8.2.35 security tests adapted for PHP 7.1 PASS under php-cgi
- ✅ Automated CI dry-run and full compile smoke test pass in GitHub Actions

**PHP 7.2.34 enhanced-universal** — built on Ubuntu 22.04 (HestiaCP 1.10.5 host):

- ✅ `patch -p1` applies cleanly on pristine `php-7.2.34` (23 files)
- ✅ `configure` + `make -j4` → success, binary runs (php, php-cgi)
- ✅ `multipart/form-data` POST with fields + file upload works
- ✅ Enhanced patch at official PHP 8.2.35 parity (chain-C refusal
  guard in `php_session_rfc1867_update()` / `php_session_rfc1867_cleanup()`,
  `post_max_size` warning hooks, `$_SESSION` dropped after the upload)
- ✅ Official 8.2.35 test suite (adapted for PHP 7.2): `rfc1867.phpt`,
  `rfc1867_no_user_code.phpt`, `rfc1867_incomplete_class_reserved_props.phpt`,
  `rfc1867_sid_invalid.phpt` — all PASS under php-cgi (same 7.x
  adaptations as 7.3; additionally PHP 7.2's parser rejects the
  `foo(<<<'PHP' ... PHP);` one-line heredoc close)
- ✅ `make test` subset (1605 tests: ext/session, serialize, file,
  general_functions; php-cgi tests included): **1249 pass /
  353 skip / 0 fail / 3 xfail**
- ✅ Stock discriminator: all three adapted tests FAIL on pristine
  7.2.34 and PASS on the patched build; the same subset on stock
  has 1 fail (`rfc1867_sid_invalid.phpt`)
- ✅ `post_max_size` bypass — via the `tests/feedpost/` harness:
  pristine build accepts the whole body silently (`LEN=500`),
  patched build emits the official warning

**PHP 7.3.33 enhanced-universal** — built on Ubuntu 22.04 (HestiaCP 1.10.5 host):

- ✅ `patch -p1` applies cleanly on pristine `php-7.3.33` (25 files)
- ✅ `configure` + `make -j4` → success, binary runs (php, php-cgi)
- ✅ `multipart/form-data` POST with fields + file upload works
- ✅ Enhanced patch at official PHP 8.2.35 parity: chain-C refusal
  (the `rfc1867_decode_refused` guard stops `php_session_rfc1867_update()`
  and `php_session_rfc1867_cleanup()` after a refused decode — ported
  from the 7.4 patch, so a refused decode leaves exactly one warning),
  `post_max_size` "Actual POST length does not match Content-Length"
  warning (both `main/rfc1867.c` hooks), `$_SESSION` dropped after
  the upload
- ✅ Official 8.2.35 test suite (adapted for PHP 7.x): `rfc1867.phpt`,
  `rfc1867_no_user_code.phpt`, `rfc1867_incomplete_class_reserved_props.phpt`,
  `rfc1867_sid_invalid.phpt` — all PASS under php-cgi. 7.x adaptations:
  string-form `proc_open()` (the array form is PHP 7.4+), heredoc close
  written as `PHP` / `);` on separate lines (PHP 7.2 rejects `PHP);`),
  the 7.x invalid-sid warning wording, and no `U::__unserialize`
  (PHP 7.4+ magic) in the expectations
- ✅ `make test` subset (1621 tests: ext/session, serialize, file,
  general_functions; php-cgi tests included): **1269 pass /
  349 skip / 0 fail / 3 xfail**
- ✅ Stock discriminator: all three adapted tests FAIL on pristine
  7.3.33 and PASS on the patched build; the same subset on stock
  has 1 fail (`rfc1867_sid_invalid.phpt`)
- ✅ `post_max_size` bypass — via the `tests/feedpost/` harness
  (missing Content-Length, `post_max_size=100`): pristine build
  accepts the whole body silently (`LEN=500`), patched build emits
  the official "Actual POST length does not match Content-Length" warning

**PHP 7.4.33 enhanced-universal** — built on Ubuntu 22.04 (HestiaCP 1.10.5 host):

- ✅ `patch -p1` applies cleanly on pristine `php-7.4.33`
- ✅ `configure` + `make -j2` → success, binary runs (php, php-cgi)
- ✅ `multipart/form-data` POST with fields + file upload works
- ✅ Enhanced patch at official PHP 8.2.35 parity: chain-C refusal
  (session destroyed when decode hits reserved incomplete-class property
  names), `php_check_cancel_upload`, `post_max_size` "Actual POST length"
  warning at fileupload_done, per-file byte sync before the throttle check
- ✅ Official 8.2.35 test suite (adapted): `rfc1867.phpt`,
  `rfc1867_no_user_code.phpt`, `rfc1867_incomplete_class_reserved_props.phpt`
  — all PASS under php-cgi
- ✅ `make test` subset (1540 tests: ext/session, serialize, file,
  general_functions, main; php-cgi tests skipped): **1195 pass /
  342 skip / 1 fail / 2 xfail** — the single fail
  (`rfc1867_sid_invalid.phpt`) also fails on stock 7.4.33 in this
  environment (save-path/env class, stock parity); the 15 fails of the
  pre-fix build are gone after the rshutdown serializer fix
- ✅ php-cgi tests: `bug72940`, `rfc1867_sid_{cookie,get,post}` PASS
- ✅ `post_max_size` bypass (GHSA-2cv3-554h-jpmh) — via the
  `tests/feedpost/` harness (missing Content-Length): pre-fix build
  accepts the whole body silently (`LEN=500`), patched build emits the
  official "Actual POST length does not match Content-Length" warning
- ✅ Discriminator vs the previous 7.4 build (v1): `bug72940`, `rfc1867`,
  `rfc1867_no_user_code`, `rfc1867_incomplete_class_reserved_props`
  all FAIL on v1 and PASS on the current build

**PHP 8.0.30 enhanced-universal** — built on Ubuntu 22.04 (HestiaCP 1.10.5 host):

- ✅ `patch -p1` applies cleanly on pristine `php-8.0.30` (26 files)
- ✅ `configure` + `make -j4` → success, binary runs (php, php-cgi)
- ✅ `multipart/form-data` POST with fields + file upload works
- ✅ Enhanced patch at official PHP 8.2.35 parity: chain-C refusal,
  `php_check_cancel_upload`, `post_max_size` "Actual POST length" warning
  at fileupload_done, per-file byte sync, `$_SESSION` dropped after the
  upload (same as the official fix)
- ✅ `Zend/zend_vm_execute.h` guards applied as a script-driven patch
  (17 length guards + 17 op1 guards + 34 `zend_mm_safe_error_ex` calls,
  byte-for-byte parity with the 7.4 enhanced tree) — regenerating the file
  with `zend_vm_gen.php` from a newer PHP breaks the VM kind selection
- ✅ Official 8.2.35 test suite (adapted): `rfc1867.phpt`,
  `rfc1867_no_user_code.phpt`, `rfc1867_incomplete_class_reserved_props.phpt`,
  `rfc1867_sid_invalid.phpt` (expectations updated to the official 8.2.35
  post-fix behaviour: `$_SESSION` is `NULL` after the upload) — all PASS
  under php-cgi
- ✅ `make test` subset (1516 tests: ext/session, serialize, file,
  general_functions, main; php-cgi tests skipped): **1182 pass /
  333 skip / 0 fail / 2 xfail**
- ✅ php-cgi tests: `bug72940`, `rfc1867_sid_{cookie,get,post}` PASS
- ✅ `post_max_size` bypass (GHSA-2cv3-554h-jpmh) — via the
  `tests/feedpost/` harness (missing Content-Length): pristine build
  accepts the whole body silently (`LEN=500`), patched build emits the
  official "Actual POST length does not match Content-Length" warning
- ✅ Discriminator vs pristine stock 8.0.30: `rfc1867_no_user_code`,
  `rfc1867_incomplete_class_reserved_props`, `rfc1867_sid_invalid`
  all FAIL on stock and PASS on the patched build

**PHP 8.1.34 enhanced-universal** — built on Ubuntu 22.04 (HestiaCP 1.10.5 host):

- ✅ `patch -p1` applies cleanly on pristine `php-8.1.34` (25 files)
- ✅ `configure` + `make -j4` → success, binary runs (php, php-cgi)
- ✅ `multipart/form-data` POST with fields + file upload works
- ✅ Enhanced patch at official PHP 8.2.35 parity (chain-C refusal,
  `post_max_size` warning, `$_SESSION` dropped after the upload, etc.)
- ✅ `Zend/zend_execute_API.c` adapted to the 8.1 shutdown layout;
  `zend_llist` head/tail reset already present in stock 8.1;
  `zend_vm_execute.h` guards verified at parity (17 length + 17 op1
  guards, 34 `zend_mm_safe_error_ex`)
- ✅ Official 8.2.35 test suite (adapted): `rfc1867.phpt`,
  `rfc1867_no_user_code.phpt`, `rfc1867_incomplete_class_reserved_props.phpt`,
  `rfc1867_sid_invalid.phpt` (post-fix expectations) — all PASS under php-cgi
- ✅ `make test` subset (1542 tests: ext/session, serialize, file,
  general_functions, main; php-cgi tests skipped): **1200 pass /
  341 skip / 0 fail / 2 xfail**
- ✅ php-cgi tests: `bug72940`, `rfc1867_sid_{cookie,get,post}` PASS
- ✅ `post_max_size` bypass (GHSA-2cv3-554h-jpmh) — via the
  `tests/feedpost/` harness: pristine build accepts the whole body
  silently (`LEN=500`), patched build emits the official warning
- ✅ Discriminator vs pristine stock 8.1.34: `rfc1867_no_user_code`,
  `rfc1867_incomplete_class_reserved_props`, `rfc1867_sid_invalid`
  all FAIL on stock and PASS on the patched build

Typical fleet this targets: OpenCart 2.x/3.x on PHP 5.6/7.0–7.3,
HestiaCP / VestaCP panels, Debian 10/11 and Ubuntu 18.04/20.04/22.04
hosts that cannot jump straight to PHP 8.2+.

**Remi Collet Security Backports Tree (`remicollet/php-src-security`)**:

Dedicated patches are available for all branches in Remi Collet's security backports tree:
- `php-5.6-enhanced-remicollet.patch` & `php-5.6-minimal-remicollet.patch` (branch `PHP-5.6-security-backports`)
- `php-7.0-enhanced-remicollet.patch` (branch `PHP-7.0-security-backports`)
- `php-7.1-enhanced-remicollet.patch` (branch `PHP-7.1-security-backports`)
- `php-7.2-enhanced-remicollet.patch` (branch `PHP-7.2-Security-backports`)
- `php-7.3-enhanced-remicollet.patch` (branch `PHP-7.3-security-backports`)
- `php-7.4-enhanced-remicollet.patch` (branch `PHP-7.4-security-backports`)
- `php-8.0-enhanced-remicollet.patch` (branch `PHP-8.0-security-backports`)
- `php-8.1-enhanced-remicollet.patch` (branch `PHP-8.1-security-backports`)

**Key advantage over stock Remi 7.4/8.0/8.1**: Remi's upstream backports commit (`Avoid state corruption via bailout` by Arnaud Le Blanc) completely disables upload progress by forcing `if (!PS(rfc1867_enabled) || true)`. Our enhanced remicollet patches supersede this blunt disable, cleanly restoring functional session upload progress protected by the official PHP 8.2.35 incomplete class mitigation (`MAGIC_MEMBER_SERIALIZED`, `incomplete_classes_only`, dropping `$_SESSION` on startup) while preserving Remi's native `Zend/` and MIME header hardening.

**Server Validation (Ubuntu 20.04 LTS x86_64)**:
- **Remi 5.6**: Compiled clean with `php-5.6-minimal-remicollet.patch`, passes `tests/feedpost/` (`RESULT: FIXED`), memory limit exhaustion clean fatal error (0 segfaults).
- **Remi 7.0**: Compiled clean, passes `tests/feedpost/` (`RESULT: FIXED`), 100% PASS on security test suite, memory limit exhaustion clean fatal error (0 segfaults).
- **Remi 7.4**: Compiled clean, passes `tests/feedpost/` (`RESULT: FIXED`, 1MB truncated to 102381 bytes with official warning), 100% PASS on security test suite.
- **Remi 8.0**: Compiled clean, passes `tests/feedpost/` (`RESULT: FIXED`), 100% PASS on security tests, `tests/stress.php` PASS (`STRESS_TEST_OK`), clean fatal error on memory exhaustion.
- **Remi 8.1**: Compiled clean, passes `tests/feedpost/` (`RESULT: FIXED`), 100% PASS on security tests, `tests/stress.php` PASS (`STRESS_TEST_OK`), clean fatal error on memory exhaustion.

---

## Production validation (fleet run, 2026-10-22)

All **28 installed PHP versions** (9 + 9 + 10 across three live test servers:
`host-a`, `host-b`, `host-c`) were validated in place after the final
swap: the bundled phpt set against the installed `phpX.Y`/`php-cgiX.Y`
binaries, and the `tests/feedpost/` harness against each version.

How the phpt runs were done (stock `run-tests.php`, no `-p`):

```bash
cd /opt/build/src-X.Y.Z        # configured source tree: tests + run-tests.php
TEST_PHP_CGI_EXECUTABLE=/usr/bin/php-cgiX.Y \
TEST_PHP_EXECUTABLE=/usr/bin/phpX.Y \
  /usr/bin/phpX.Y run-tests.php -q ext/session/tests/rfc1867*.phpt \
  ext/standard/tests/serialize/incomplete_class_raw_payload_markers.phpt
```

Notes that matter when you repeat this:

- **No `-p php-cgi`**: pre-7.4 `run-tests.php` shells out to `php -r`
  (a CLI-only flag) to learn `extension_dir` and would feed
  `-d "extension=Usage: ..."` garbage to the child process — empty `.out`
  files and fake failures. `TEST_PHP_CGI_EXECUTABLE` covers the cgi part.
- **Hardened hosts**: hosting `php.ini`s disable `proc_open`, which
  `run-tests.php` itself needs → run
  `phpX.Y -d disable_functions= run-tests.php -q ...` (the children get
  the flag back from run-tests).
- `incomplete_class_raw_payload_markers.phpt` is CLI-only (it expects no
  cgi headers) — keep it in the CLI runner.

Results — every version passes the upload-progress/serializer suite; the
only red mark is `rfc1867_sid_invalid.phpt` on 7.0/7.4, which fails
identically on the untouched pre-swap distro backups (stock parity,
session save-path/env wording — not a regression):

| PHP  | host-a    | host-b | host-c   |
|------|-----------|-------|----------|
| 5.6  | 5/5       | 5/5   | 5/5      |
| 7.0  | 4/1 ◦     | 4/1 ◦ | 4/1 ◦    |
| 7.1  | 5/5       | 5/5   | 5/5      |
| 7.2  | 5/5       | 5/5   | 5/5      |
| 7.3  | 5/5       | 5/5   | 5/5      |
| 7.4  | 4/1 ◦     | 4/1 ◦ | 4/1 ◦    |
| 8.0  | 5/5       | 5/5   | 5/5      |
| 8.1  | 5/5       | 5/5   | 5/5      |
| 8.2  | 5/5       | 5/5   | 5/5      |
| 8.3  | —         | —     | 5/5      |

◦ stock-parity `rfc1867_sid_invalid.phpt` (fails on the stock binary too).

`post_max_size` bypass (feedpost harness, missing Content-Length + 1 MB
body, `post_max_size=100K`): **28/28 FIXED** — every version truncates to
**102 381** bytes and emits the official
`Actual POST length does not match Content-Length` warning instead of
accepting the whole body.

FPM error logs across the fleet (ionCube loader / fatal / undefined
symbol): zero entries after the final swap window.

---

## Verifying a deployed fix (on live FPM / Apache)

`verify/` contains a small, controlled, **non-destructive** validator (not an
exploit) to confirm a build is patched on the real SAPI after deployment: a
token-gated endpoint (`cvecheck.php`) plus a driver that reports PASS/FAIL
(`run-cvecheck.sh` for Linux/macOS, `run-cvecheck.ps1` for Windows PowerShell).

Supports **PHP 5.4 through 8.5** and handles both **minimal** and **enhanced**
patch flavors.

### Quick start:
1. Set `$CVECHECK_TOKEN = 'your_secret';` in `verify/cvecheck.php`.
2. Copy `verify/cvecheck.php` to your web root (`/var/www/html/cvecheck.php`).
3. Run the driver:
   ```bash
   ./verify/run-cvecheck.sh https://example.com/cvecheck.php your_secret
   ```
4. **Delete `cvecheck.php` when finished.**

See [`verify/README.md`](verify/README.md) for full details.

---

## Credits & sources

- PHP security advisory: <https://www.php.net> (21 Oct 2026)
- [GHSA-w8hw-w9fx-j79w](https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w)
  — CVE-2026-109618 (OOM corruption → RCE)
- [GHSA-6wmf-4rv5-p3rp](https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp)
  — CVE-2026-109619 (stale global state → RCE)
- Official minimal backports: php-src branches
  `PHP-{7.4,8.0,8.1}-CVE-2026-109618-109619` by arnaud-lb / iluuu1994.
- Enhanced root-cause UAF fix (zend_long counters):
  [eness/php2shell-CVE-2026-109618-CVE-2026-109619-PoC](https://github.com/eness/php2shell-CVE-2026-109618-CVE-2026-109619-PoC)
- Session-fixation fix: upstream [PR #22113](https://github.com/php/php-src/pull/22113).
- Attack-chain analysis (filename injection, serializer leak):
  [ikow/php2shell-poc](https://github.com/ikow/php2shell-poc).
- Mitigation verifier design inspired by: [vperetti/php-cve-2026-109618-109619-backports](https://github.com/vperetti/php-cve-2026-109618-109619-backports).
- aaPanel / BT Panel deployment reference & RAM-safe build concurrency: [Qsnh/php2shell-fixed](https://github.com/Qsnh/php2shell-fixed).
- Community backports are **not affiliated with or endorsed by the PHP Group.**

## Licence

Patches derived from php-src are under the PHP License v3.01.
