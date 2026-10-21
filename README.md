# php2shell patches — CVE-2026-109618 / CVE-2026-109619 for old PHP (5.6–8.1) & OpenCart / HestiaCP

Emergency backports and hardening for **CVE-2026-109618** and **CVE-2026-109619**
("php2shell") — two critical unauthenticated RCE vulnerabilities in PHP,
CVSS v4.0 **9.2**. Fixed upstream 21 Oct 2026 (PHP 8.5.12 / 8.4.27 / 8.3.36 /
8.2.35). **PHP 5.6, 7.x, 8.0, 8.1 are EOL and get no official fix** — this
repo packages EOL backports (official + community) plus emergency hardening
for legacy stacks: **OpenCart, WordPress, Drupal, Joomla, Magento**, any
HestiaCP / VestaCP / cPanel host still running old PHP.

> **There is no complete mitigation. Updating to a fixed release (or applying
> a real patch below) is the only safe choice.** Hardening alone only blocks
> known attack paths and buys time.

---

## Two patch flavors — pick your trade-off

| | **minimal** (official PHP-group) | **enhanced-universal** (community) |
|---|---|---|
| Fixes CVE-2026-109618 (OOM → RCE) | ✅ | ✅ |
| Fixes CVE-2026-109619 (upload_progress UAF) | ✅ by **disabling** upload_progress | ✅ by **fixing the root cause** (counters as `zend_long`, no dangling `zval*`) |
| `multipart/form-data` file uploads | ✅ work | ✅ work |
| Session upload **progress bar** | ❌ disabled | ✅ **still works** |
| Blocks session-fixation via POST body | ❌ | ✅ (PR #22113) |
| Sanitizes filename in session file (LFI / handler-mismatch) | ❌ | ✅ |
| Resets `PS(serializer)` between FPM requests | ❌ | ✅ |
| Officially blessed by PHP Group | ✅ (7.4/8.0/8.1 branches) | ❌ (community, but combines official OOM fix + root-cause UAF fix) |

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
| 8.5.x < 8.5.12 | ✅ official | `apt upgrade` / distro package, or build from source |
| 8.4.x < 8.4.27 | ✅ official | same |
| 8.3.x < 8.3.36 | ✅ official | same |
| 8.2.x < 8.2.35 | ✅ official | same (note: 8.2 EOL 31 Dec 2026 — plan upgrade) |
| 8.1.x | ⚠️ backport | `php-8.1-minimal.patch` (PHP group) **or** `php-8.1-enhanced-universal.patch` |
| 8.0.x | ⚠️ backport | `php-8.0-minimal.patch` (PHP group) **or** `php-8.0-enhanced-universal.patch` |
| 7.4.x | ⚠️ backport | `php-7.4-minimal.patch` (official) **or** `php-7.4-enhanced-universal.patch` |
| 7.3.x | ⚠️ backport | `php-7.3-minimal.patch` **or** `php-7.3-enhanced-universal.patch` |
| 7.2.x | ⚠️ backport | `php-7.2-minimal.patch` **or** `php-7.2-enhanced-universal.patch` |
| 7.0 – 7.1 | ❌ none | **migrate**, or apply hardening + consider the 7.2 backport patches |
| 5.6.x | ❌ none | **migrate**. Community backport: `php-5.6-enhanced-universal.patch` (recommended — root-cause fix, keeps uploads) or `php-5.6-community-backport.patch` (minimal). **Test first.** |

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

## How to apply

### A. Supported branch (8.2–8.5) — just update

```bash
apt-get update
apt-get install --only-upgrade 'php8.*' php-fpm
systemctl restart 'php8.*-fpm'
# HestiaCP panel's own PHP:
apt-get install hestia-php && systemctl restart hestia
```

### B. PHP 7.2 / 7.3 / 7.4 / 8.0 / 8.1 — build patched

```bash
apt-get install -y build-essential autoconf bison re2c pkg-config \
    libxml2-dev libssl-dev libcurl4-openssl-dev libsqlite3-dev \
    libonig-dev libzip-dev

# Enhanced (recommended if you need working upload progress / OpenCart forms):
./build/build-patched-php.sh 7.4.33 patches/php-7.4-enhanced-universal.patch /opt/php-7.4-patched
# Or for PHP 7.3.33 / 7.2.34:
./build/build-patched-php.sh 7.3.33 patches/php-7.3-enhanced-universal.patch /opt/php-7.3-patched
./build/build-patched-php.sh 7.2.34 patches/php-7.2-enhanced-universal.patch /opt/php-7.2-patched

# Or minimal (official approach, disables upload progress):
./build/build-patched-php.sh 7.4.33 patches/php-7.4-minimal.patch /opt/php-7.4-patched
./build/build-patched-php.sh 7.3.33 patches/php-7.3-minimal.patch /opt/php-7.3-patched
./build/build-patched-php.sh 7.2.34 patches/php-7.2-minimal.patch /opt/php-7.2-patched
```

Then switch HestiaCP FPM pools / templates to the new binary, or install
alongside system PHP and migrate domains one at a time.
**Run `make test` before production.**

### C. PHP 5.6 — last resort

```bash
# Sources: use the GitHub tag (museum.php.net may time out)
curl -L -o php-5.6.40.tar.gz https://github.com/php/php-src/archive/refs/tags/php-5.6.40.tar.gz
mkdir php-5.6 && tar xzf php-5.6.40.tar.gz -C php-5.6 --strip-components=1
cd php-5.6
./buildconf --force          # GitHub tags ship without a configure script

# Enhanced (recommended — root-cause UAF fix, keeps upload progress / forms):
patch -p1 < ../patches/php-5.6-enhanced-universal.patch
./configure --prefix=/opt/php-5.6-patched --disable-cgi --enable-fpm \
    --without-openssl --with-zlib --enable-mbstring --with-sqlite3 \
    --with-pdo-sqlite --enable-session --with-gettext --enable-sockets \
    --without-curl --without-pear --disable-phpdbg
make -j"$(nproc)"

# Or minimal (force-disables upload progress):
patch -p1 < ../patches/php-5.6-community-backport.patch
# ... same configure/make
```

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
  php-7.4-minimal.patch              # official PHP-group minimal backport
  php-7.4-enhanced-universal.patch   # community: root-cause UAF fix + fixation/filename/serializer, keeps progress bars
  php-8.0-minimal.patch              # official PHP-group minimal backport
  php-8.1-minimal.patch              # official PHP-group minimal backport
  php-5.6-enhanced-universal.patch   # community enhanced for 5.6: root-cause UAF fix + fixation/filename/serializer, keeps progress bars
  php-5.6-community-backport.patch   # community minimal for 5.6 (force-disable) — TEST FIRST
harden/
  php.ini-mitigations                # annotated php.ini snippet
  fpm-pool-snippet.conf              # lines to append to FPM pools
  apply-hardening.sh                 # automated, idempotent, backs up originals
build/
  build-patched-php.sh               # download + patch + configure + make install
inventory/
  scan-php-versions.sh               # per-host PHP version inventory
tests/
  feedpost/                          # post_max_size bypass verification harness
                                     # (phpize ext for PHP 5.6: feeds a multipart
                                     #  body with missing Content-Length, see
                                     #  tests/feedpost/README.md)
```

---

## Tested environments (OpenCart / HestiaCP)

**PHP 5.6.40 enhanced-universal** — built on Ubuntu 22.04 (HestiaCP 1.10.5 host):

- ✅ `patch -p1` applies cleanly on pristine `php-5.6.40`
  (official php.net tarball **and** GitHub tag archive)
- ✅ `buildconf --force` + `configure` + `make -j2` → success, binary runs
- ✅ `multipart/form-data` POST with fields + file upload works
  (`$_POST`, `$_FILES`, `is_uploaded_file()` all correct)
- ✅ `session.upload_progress.enabled => On` (stays enabled — root-cause fix)
- ✅ `make test` (1373 tests: ext/session, serialize, file,
  general_functions, main): **1106 pass / 245 skip / 20 fail / 2 warn** —
  result byte-identical to the pre-enhancement build (same 20
  pre-existing fails, zero regressions from the new fixes)
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
- Community backports are **not affiliated with or endorsed by the PHP Group.**

## Licence

Patches derived from php-src are under the PHP License v3.01.
