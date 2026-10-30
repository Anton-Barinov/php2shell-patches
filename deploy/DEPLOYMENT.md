# Deploying php2shell patches over a distro PHP: known pitfalls

When you apply these patches to a PHP that is **already installed by the
distribution** (Debian/Ubuntu + third-party repo) and swap the system
binaries in place, the patch itself is only half of the job. The other half
is surviving the *build configuration*: a source build configured like a
distro package must reproduce everything the distro package relies on,
otherwise live sites break.

We hit every item below during a real rollout. Each one broke sites in a
different way. This document exists so you don't have to rediscover them.

There are two safe deployment paths:

* **Side-by-side install** (recommended if you can switch pools/nginx to a
  new prefix): `build/build-patched-php.sh` — builds into its own prefix,
  touches nothing system-wide.
* **In-place swap** (drop-in replacement of `/usr/bin/phpX.Y`,
  `/usr/sbin/php-fpmX.Y`, `/usr/bin/php-cgiX.Y`, distro scan-dir modules keep
  working): `deploy/swap-system-php.sh` — encodes every fix from this
  document and refuses to swap if the module baseline check fails.

---

## P1. `--disable-all` removes extensions the distro compiles in → HTTP 500

**What happens.** Configure a source build with `--disable-all` (a natural
instinct: "small auditable build, distro loads its own `.so` anyway") and
swap it in. Sites immediately return **HTTP 500**:

```
PHP Fatal error: Uncaught Error: Undefined constant "INPUT_GET" in .../SomePlugin.php
```

**Why.** `INPUT_GET`, `INPUT_POST`, `INPUT_SERVER`, ... are constants of the
**filter** extension. On Debian/Ubuntu PHP, filter (and a few others) are
*compiled into* the binary — there is no `filter.so` and no
`filter.ini` in the scan dir. `--disable-all` switches filter off, nothing
can load it at runtime, and every framework that touches `INPUT_*`
(WordPress, OpenCart, phpMyAdmin, ...) fatals on the first request.
Modules compiled into the distro binary with no packaged `.ini` on typical
Debian/Ubuntu PHP: `filter`, `hash`, `session`, `libxml`, `zlib`, `openssl`,
`pcntl`, `sodium` (7.2+), `mhash` (5.6) — all of them need an explicit
configure flag under `--disable-all`.

**Fix.**

* Always add `--enable-filter` next to `--disable-all`.
* Treat "is this module compiled into the distro binary but has no packaged
  `.ini`?" as a checklist question — `deploy/swap-system-php.sh` answers it
  automatically: it snapshots `phpX.Y -m` from the *installed* binary before
  the swap and refuses to proceed if any baseline module is neither compiled
  into the new binary nor available as a packaged `.so`.

**How to verify.** `phpX.Y -m` after the swap must be a superset of the
module list before the swap (compare against a saved baseline; the swap
script does this).

---

## P2. Broken `extension_dir` → no packaged modules load, fpm pools die

**What happens.** fpm starts (or starts and exits), every FastCGI request
returns 500/502, and logs fill with:

```
Unable to load dynamic library 'tokenizer.so'
(tried: /usr/lib/php//usr/lib/php/20180731/tokenizer.so ...)
```

**Why.** The swap script writes a scan-dir ini that pins the packaged
module directory:

```sh
EXTDIR="$(php$XY -r 'echo ini_get("extension_dir");')"
API="${EXTDIR##*/}"                 # correct
printf 'extension_dir=/usr/lib/php/%s\n' "$API"
```

An earlier version used `${EXTDIR##*-}`, which strips up to the last `-`.
A path like `/usr/lib/php/20180731` contains no `-`, so the expansion
returned the *whole* path, producing
`extension_dir=/usr/lib/php//usr/lib/php/20180731`. Every packaged `.so`
then failed to load — mysqli, curl, mbstring, tokenizer — and the pools
became useless.

**Fix.** Use `${EXTDIR##*/}` (basename of the directory, i.e. the PHP API
number). Validate with `phpX.Y -r 'echo ini_get("extension_dir");'` after
the swap and `phpX.Y -m`.

**Rollback note.** When restoring distro binaries, remove stale
`00-swap-extension-dir.ini` leftovers as well, or the *distro* binary will
inherit the broken path (this exact mistake cost us extra downtime).

---

## P3. Packaged `.so` files reference symbols your build doesn't export

**What happens.** fpm comes up with warnings on nearly every module:

```
fileinfo.so: undefined symbol: pcre_exec
opcache.so:  undefined symbol: pcre2_code_free_8
zip.so:      undefined symbol: pcre2_match_8
```

**Why, part 1 — visibility.** PHP's configure appends
`-fvisibility=hidden` to CFLAGS **after** user-provided flags, so putting
`-fvisibility=default` in `CFLAGS` is silently overridden. Static
extensions (mysqlnd, pcre, libxml internals) end up hidden, and packaged
`.so` files that expect those symbols refuse to load.

**Fix 1.** After configure, strip it from the generated Makefile:

```sh
sed -i 's/-fvisibility=hidden//g' Makefile
```

**Why, part 2 — PCRE linking.** The packaged `.so` files carry **no PCRE
`DT_NEEDED` of their own**: they resolve `pcre_exec` (5.6–7.2) /
`pcre2_match_8` (7.3+) from the *binary's* link scope. The distro links
external PCRE in every version — 5.6–7.2 against `libpcre.so.3`, **7.3 and
newer against `libpcre2-8`** (yes, 7.3 already uses PCRE2). Bundled-PCRE
builds rename those symbols (`php_pcre_exec`, `php_pcre2_*`), so the
packaged modules fail to load with `undefined symbol`.

**Fix 2** (replicate what the distro build links):

* PHP **5.6–7.2** (PCRE1): `--with-pcre-regex=/usr` **and** `libpcre3-dev`.
  On multiarch layouts configure looks for `/usr/lib/libpcre.(a|so)` and
  fails; add the compatibility link:
  `ln -sfn x86_64-linux-gnu/libpcre.so /usr/lib/libpcre.so`
* PHP **7.3**: the flag is the same (`--with-pcre-regex=/usr`), but 7.3's
  configure maps `DIR=/usr` onto pkg-config **`libpcre2-8 >= 10.30`** —
  install `libpcre2-dev`, otherwise configure dies with
  `PCRE2 version 10.30 or later is required`.
* PHP **≥ 7.4**: `--with-external-pcre` + `libpcre2-dev`. (`--with-external-pcre`
  exists in 7.4–8.x; bundled pcre2 would rename every symbol and leave
  `pcre2_match_8` unresolved in the packaged `.so` files — visibility
  fix 1 does not help there.)

---

## P4. `Type=notify` units vs vanilla php-fpm

**What happens.** After the swap, `systemctl restart phpX.Y-fpm` hangs or
the unit flaps.

**Why.** Third-party repo units declare `Type=notify`; their fpm master
sends `sd_notify`. A vanilla php-fpm build does not, so systemd waits for
"ready" and times out / restarts.

**Fix.** `sed -i 's/^Type=notify/Type=exec/' /lib/systemd/system/phpX.Y-fpm.service`
followed by `systemctl daemon-reload`. Remember to revert this on rollback
(only if your repo's unit relied on it).

---

## P5. Double-loading: static extension + packaged `.ini`

**What happens.** Warnings at startup: `Module "mbstring" is already loaded`,
sometimes with hard failures.

**Why.** The new binary compiles a module in (e.g. via `--enable-mbstring`
or because it is unavoidable), while the distro scan dir still has
`mbstring.ini` saying `extension=mbstring.so`.

**Fix.** After the build, for every module reported by `php -m`, disable the
`extension=` line of the packaged ini (keep the other directives):

```sh
sed -i 's/^extension=/;disabled-by-swap extension=/' /etc/php/X.Y/mods-available/<mod>.ini
```

The swap script does this automatically and idempotently. On rollback,
restore the lines:

```sh
sed -i 's/^;disabled-by-swap extension=/extension=/' /etc/php/X.Y/mods-available/*.ini
```

(older versions of the script renamed whole files to
`*.disabled-by-swap`; rename them back the same way).

---

## P6. Distro maintenance traps (EOL / third-party repositories)

These are not PHP-specific but they bit us during the same rollout:

* **Never run `apt --fix-broken install` on a box with a disabled/EOL repo**
  — it "fixes" broken dependencies by *removing* packages, which can take
  half the hosting stack with them. Install exact `.deb` files with
  `dpkg -i --force-depends` instead, and leave the resolver alone.
* **Stale multiarch symlinks.** A dangling
  `libxml2.so -> libxml2.so.2.9.x` makes the linker fall back to a static
  `libxml2.a`, producing dozens of
  `undefined reference to pow/log10/lzma_*` at link time.
  Fix: `ln -sfn libxml2.so.2 /usr/lib/x86_64-linux-gnu/libxml2.so`.
* **Missing ICU headers** (`unicode/ucnv.h`) show up when libxml2 was built
  with ICU support: install the matching `libicu-dev`.
* **EOL repositories** (e.g. Debian buster) need
  `deb [trusted=yes] http://archive.debian.org/debian buster main` plus
  `apt-get -o Acquire::Check-Valid-Until=false update`. Disable the
  third-party PHP repo (`mv /etc/apt/sources.list.d/php.list ...disabled`)
  before swapping binaries so nothing auto-reinstalls the package over
  your patched build.

---

## P7. Safe swap, downtime window, and rollback

* **Backups**: the swap script copies `phpX.Y`, `php-fpmX.Y`, `php-cgiX.Y`
  to `*.bak-<timestamp>` before replacing them — keep at least the earliest
  (pre-deployment) backup of each. Its `cfg-backup` block additionally keeps
  a fixed-name `<file>.swapbak` for every config it rewrites: the first
  pre-swap state of `mods-available/*.ini` (the `extension=` disable marks)
  and of the fpm unit (`Type=notify`). The first swap owns the `.swapbak`;
  reruns never clobber it (unit-tested by `tests/cfg-backup-test.sh`).
  Hosts swapped by an older script version (no `.swapbak` kept) can
  backfill them with `deploy/retro-swapbak.sh <X.Y>` — it reverses the old
  deterministic seds exactly.
* **`Text file busy`**: you cannot `cp` over a running fpm binary.
  `install(1)` unlinks+creates, so it is safe; plain `cp -a` is not —
  the restore script stops the unit first, and you should too when
  restoring backups by hand.
* **Restart is not atomic**: each `systemctl restart phpX.Y-fpm` drops
  in-flight requests for ~1s per pool. Restarting every version in a loop
  multiplies the visible outage — restart only what you changed, and watch
  your monitoring during the rollout.
* **Pre-restart smoke**: before the restart (and thus before any traffic
  moves) the swap script runs a `post-swap-smoke` block: `php-fpm -t`
  (catches a broken repointed ini path), `php-cgi -v`, the P10
  `mysqli.default_socket` assert (scan-dir ini actually applied) and an
  ionCube `php -m` check when a loader is configured. A failed `fpm -t`
  aborts the swap while the old fpm is still serving. The block is
  unit-tested by `tests/smoke-test.sh` (6 scenarios: healthy, `fpm -t`
  failure, `php-cgi -v` failure, P10 socket regression, missing loader,
  no loader configured).* **Rollback procedure — one command per version**:

  ```bash
  ./deploy/restore-system-php.sh 7.3           # preview first: --dry-run
  ```

  It restores the *earliest* `*.bak-*` of each binary (the oldest backup is
  the untouched distro — later swaps only ever backed up already-swapped
  binaries; it refuses to run when no backup exists), stops the fpm unit
  first (`Text file busy`), restores every `.swapbak` (extension marks,
  `Type=notify` + `daemon-reload`), removes the files we created over
  nothing (`00-swap-extension-dir.ini`, the ioncube mirror — both are
  no-ops for the distro build), then `php-fpm -t` → restart → `is-active`.
  If `fpm -t` fails it still attempts a best-effort start so the version is
  not left down, and then reports the failure.
  The whole script runs under `tests/restore-test.sh` (8 scenarios:
  oldest-`bak` selection, no-backup refusal before touching anything,
  `--dry-run` purity, missing fpm backup, service not running, full-version
  argument normalization, inactive-after-restore, `fpm -t` failure).
  Manual fallback (what we used before the script existed):
  1. restore the earliest `*.bak-*` for `php`, `php-cgi`, `php-fpm`
     (stop fpm units first!);
  2. restore `;disabled-by-swap extension=` lines from `.swapbak`
     (P5) or strip the mark by hand, `rm` `00-swap-extension-dir.ini`;
  3. `systemctl daemon-reload && systemctl restart` every affected
     `phpX.Y-fpm`;
  4. verify with real `Host:`/`--resolve` requests against your vhosts, not
     just `php -v`.
* **`pkill` footgun**: patterns like `pkill -f make` can match your own
  ssh/command line and kill the session. Anchor patterns
  (`pkill -f "^/usr/bin/make"`) or use recorded PIDs.

---

## P8. Validation checklist (do this before pointing traffic at the build)

1. `phpX.Y -m` ⊇ baseline module list (P1, P2) — the swap script asserts it.
2. `phpX.Y -r 'echo ini_get("extension_dir");'` → `/usr/lib/php/<api>`.
3. `systemctl is-active phpX.Y-fpm` **and** a real HTTP request through the
   site's vhost (curl with `--resolve host:443:IP`), checking for
   `Fatal error`/`already loaded`/`undefined symbol` in both response and
   error logs.
4. Extension-heavy smoke test: request upload/session flows (the bundled
   upload-progress discriminator in `tests/` does exactly this) and compare
   with a known-good run. When running such a harness on a hardened host,
   launch it with `-d disable_functions=`: hosting php.ini files routinely
   disable `proc_open`, the harness needs it to drive the cgi upload test,
   and a disabled `proc_open` yields garbage output that has nothing to do
   with the actual vulnerability.
5. Watch out for **loaders that pin a specific PHP build** (e.g. ionCube):
   they may refuse to run against a custom binary even when the version
   matches; check `php -m` for the loader line after every swap. The distro
   keeps `00-ioncube-loader.ini` as a *real file* inside `<sapi>/conf.d`,
   which our `mods-available` scan never reads — the swap script mirrors it
   into `mods-available/10-ioncube-loader.ini`: the `zend_extension=` value
   is taken from the distro ini itself (non-standard loader locations
   survive; a bare filename is resolved into `extension_dir`) and written as
   an absolute path, so it does not depend on ini parse order. If the host
   never had the loader — or it was uninstalled — the block is a no-op / it
    drops a stale mirror instead of warning on every request. The logic is
    unit-tested by `tests/ioncube-mirror-test.sh` (7 scenarios).
6. Run the **bundled security test set** against the *installed* binaries
   (not just the build tree) plus the `tests/feedpost/` harness for every
   swapped version — the exact recipe and the 28-version fleet matrix are
   in the README, "Production validation". Two traps when you repeat it:
   don't pass `-p php-cgi` (pre-7.4 `run-tests.php` invokes `php -r`, a
   CLI-only flag, and the child gets garbage `-d` flags), and on hardened
   hosts prepend `-d disable_functions=` (run-tests itself needs
   `proc_open`). Expected result: everything passes except
   `rfc1867_sid_invalid.phpt` on 7.0/7.4 (stock parity — verify against
   the earliest `*.bak-*` binary if unsure).

---

## P9. PHP 5.6 vs OpenSSL 1.1: build fails in `ext/openssl`

**What happens.** configure passes, then make dies:

```
ext/openssl/openssl.c:4801:13: error: storage size of 'md_ctx' isn’t known
ext/openssl/openssl.c:5233:17: error: storage size of 'cipher_ctx' isn’t known
make: *** [Makefile:521: ext/openssl/openssl.lo] Error 1
```

**Why.** PHP 5.6 predates OpenSSL 1.1: it allocates `EVP_MD_CTX` /
`EVP_CIPHER_CTX` on the stack, and 1.1 made those structs opaque. Official
5.6 only ever supported OpenSSL 1.0.x. Distro packages (sury & co) ship 5.6
against 1.1 by carrying a large backport patchset — a plain php.net tarball
does not.

You cannot just drop `--with-openssl`: Debian/Ubuntu keep openssl compiled
*into* the distro binary (no packaged `openssl.ini`), so the swap script's
baseline check (P1) will refuse the build.

**Fix — build against OpenSSL 1.0.2 locally** (coexists with system
libssl-dev 1.1, no package conflicts):

```sh
curl -LO https://www.openssl.org/source/old/1.0.2/openssl-1.0.2u.tar.gz
tar xzf openssl-1.0.2u.tar.gz && cd openssl-1.0.2u
./config --prefix=/opt/ssl10 shared
make -j"$(nproc)" && make install_sw
echo /opt/ssl10/lib > /etc/ld.so.conf.d/openssl10.conf && ldconfig
```

Then point only 5.6 at it (the swap script honours `OPENSSL_OPT`):

```sh
OPENSSL_OPT=--with-openssl=/opt/ssl10 ./swap-system-php.sh 5.6.40 <patch>
```

Keep the system `libssl-dev` installed for 7.0+ builds — 7.0 compiles
against 1.1.x as-is.

---

## P10. `mysqli`/`localhost` DB connections break after the swap

**What happens.** Sites keep working on TCP (`127.0.0.1`) but fail whenever
the app connects with host `localhost`:

```
PHP Fatal error: Uncaught Exception: Error: Could not make a database
link using user@localhost! in .../system/library/db/mysqli.php
```

and the direct test confirms it:

```
php -r '$m=@mysqli_connect("localhost",...); echo mysqli_connect_error();'
# → No such file or directory
php -r '$m=@mysqli_connect("127.0.0.1",...); echo mysqli_connect_error();'
# → connects fine
```

**Why.** For host `localhost` mysqlnd uses `mysqli.default_socket`, and when
that is empty it falls back to the compiled-in `MYSQL_UNIX_PORT`. Distro
builds are compiled with `--with-mysql-sock=/var/run/mysqld/mysqld.sock`,
a vanilla build is not — so it tries a path that does not exist
(`/tmp/mysql.sock`). The distro `php.ini` ships the directive *empty*
(Debian relies on the compiled default), and the swap's scan-dir ini only
pinned `extension_dir`.

**Fix.** The swap script pins both directives in the same scan-dir file it
already writes (scan order runs after `php.ini`, so the value wins):

```
/etc/php/X.Y/mods-available/00-swap-extension-dir.ini
    extension_dir=/usr/lib/php/<api>
    mysqli.default_socket=/var/run/mysqld/mysqld.sock
    pdo_mysql.default_socket=/var/run/mysqld/mysqld.sock
```

For hosts already swapped with an older script version, append the two
`default_socket` lines and `systemctl reload phpX.Y-fpm` — no rebuild needed.

---

## P11. Dynamic library mismatch or missing runtime dependencies (`ldd`)

**What happens.** A freshly compiled binary builds cleanly, but when swapped into
`/usr/bin` or `/usr/sbin`, running `php-fpm` fails immediately with dynamic loader errors:

```
php-fpm7.3: error while loading shared libraries: libssl.so.1.1: cannot open shared object file: No such file or directory
```

**Why.** When compiling on build servers with multiple OpenSSL or curl versions in `/usr/local` or custom toolchains, the binary may link against shared libraries that are not resolvable in the default runtime dynamic link paths of the target environment.

**Fix.** Before touching system binaries or replacing production files, `swap-system-php.sh` and `swap-aapanel-php.sh` run dynamic library resolution checks (`ldd`) on `sapi/cli/php` and `sapi/fpm/php-fpm`. If any `not found` dependency is detected, the script terminates immediately with `FATAL: ... has unresolved dynamic library dependencies`.

---

## aaPanel / Baota (BT Panel) Deployments

If your server runs **aaPanel** or **Baota**, PHP installations reside in `/www/server/php/<ver>` (e.g., `/www/server/php/74`). Standard distro packages (`/etc/php/X.Y`) are not used; instead, aaPanel uses self-contained builds managed via `/etc/init.d/php-fpm-<ver>`.

Use `deploy/swap-aapanel-php.sh`:
- **Build**: `./deploy/swap-aapanel-php.sh build <ver> [patch-file]`
  - Automatically extracts original configure flags via `php -i`.
  - Discovers custom libraries from `/usr/local` and sets `PKG_CONFIG_PATH`.
  - Employs RAM-safe concurrency to avoid OOM kills.
  - Verifies the patched binary offline before installation.
- **Install**: `./deploy/swap-aapanel-php.sh install <ver>`
  - Creates a dated snapshot `/www/server/php/<ver>.bak-<timestamp>`.
  - Gracefully restarts `php-fpm`.
  - Tests configuration via `php-fpm -t`.
  - Verifies module baseline matches pre-swap state.
  - Automatically performs full rollback if any check fails.



## Build verification and rollback preflight

Keep the `build/` and `deploy/` directories together when copying tooling to a
server. All three builders now use `build/verify-exit-oom.sh` to validate this
repository's `_exit(1)` allocator behaviour. The probe requires an entry marker,
an allocation failure diagnostic, exit code 1 and no shutdown/continuation marker.
An arbitrary silent exit 1 no longer counts as a successful verification. The
probe is CLI-only and does not establish complete UAF/serializer CVE coverage.

`build/build-patched-php.sh` runs this check before `make install` and again on
the installed CLI. Configure options follow the optional prefix:

```bash
./build/build-patched-php.sh 7.4.33 patches/php-7.4-enhanced-universal.patch /opt/php-7.4-patched --without-curl
```

Patch paths and the installation prefix are resolved before changing directory.
The downloaded tarball is cached only after curl succeeds. Every invocation
extracts a fresh source tree in `.php2shell-build/`; changes to the previous
extracted tree are discarded. Configure options should be supplied as arguments.

`swap-system-php.sh` now respects `BUILD_ROOT` for its extracted source tree as
well as its archives and baseline files. `swap-aapanel-php.sh` stops immediately
if extraction or entering the source directory fails and resolves an explicitly
supplied relative patch before entering that directory.

`restore-system-php.sh` refuses to begin if any existing CLI/FPM/CGI binary has
no backup. Recover the complete backup set before retrying; partial rollback is
not reported as success. A missing current binary is recreated from its backup.
aaPanel rollback also refuses to move the installation prefix if FPM cannot be
stopped, so a live process cannot be left using libraries from a moved tree.

Offline regressions are in `tests/build-test.py` and `tests/restore-test.sh` and
run through the existing `tests/run-all.sh` CI gate. They exercise script control
flow with fake compilers/PHP binaries; they do not replace compiling the actual
PHP branches on the intended Linux distribution.

## Preserve SSL/TLS transports when replacing PHP

`build/verify-transports.sh` lists the CLI's registered stream transports without
making a network connection. The system and aaPanel swap tools snapshot the
installed CLI and refuse a replacement that loses an existing `ssl` or `tls`
transport, before stopping the existing service or installing files. A failed
probe or absent baseline aborts the check; neither is interpreted as an empty
transport list. aaPanel verifies the installed binary again and performs its
module/patch checks before starting the new FPM.

This detects the missing-OpenSSL regression that can break SMTP/HTTPS streams
after a source rebuild even when patch signatures are present. It does not
certify protocol negotiation, trusted certificates, FPM pool settings or a
third-party extension ABI. The comparison uses each CLI's default configuration;
web SAPI overrides still need separate inspection.
