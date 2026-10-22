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
  (pre-deployment) backup of each.
* **`Text file busy`**: you cannot `cp` over a running fpm binary.
  `install(1)` unlinks+creates, so it is safe; plain `cp -a` is not. If you
  restore backups by hand, `systemctl stop` the pool first.
* **Restart is not atomic**: each `systemctl restart phpX.Y-fpm` drops
  in-flight requests for ~1s per pool. Restarting every version in a loop
  multiplies the visible outage — restart only what you changed, and watch
  your monitoring during the rollout.
* **Rollback procedure** (what we used when sites went down):
  1. restore the earliest `*.bak-*` for `php`, `php-cgi`, `php-fpm`
     (stop fpm units first!);
  2. remove swap artifacts:
     `rm /etc/php/*/mods-available/00-swap-extension-dir.ini`,
     restore `;disabled-by-swap extension=` lines (P5) or rename
     `*.disabled-by-swap` files back;
  3. `systemctl restart` every affected `phpX.Y-fpm`;
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
   matches; check `php -m` for the loader line after every swap.

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
