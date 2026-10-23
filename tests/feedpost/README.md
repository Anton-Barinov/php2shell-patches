# tests/feedpost — `post_max_size` bypass verification harness (GHSA-2cv3-554h-jpmh)

A tiny PHP extension that reproduces the official upstream test scenario
(`zend_test_handle_post_data()` in PHP 8.2.35) on old branches: it runs the
multipart POST handler over an arbitrary body **with `Content-Length = 0`
(i.e. missing)** — the condition under which `post_max_size` could be
bypassed on SAPIs whose `read_post()` does not honour Content-Length
(e.g. Apache with chunked/HTTP-1.0 bodies).

`feed_multipart(string $body, string $content_type): array` parses `$body`
via `rfc1867_post_handler()` and returns what landed in `$_POST`.

Files:

- `feedpost.c`, `php_feedpost.h`, `config.m4` — the extension
- `feedtest.php` — the test driver (PHP 5.6-compatible syntax)
- `run.sh <php-binary> <configured-src-dir>` — builds `feedpost.so` and runs
  both checks; exit 0 = FIXED, 1 = bypass still present

## Quick run (no phpize needed) — used on production hosts

`run.sh` compiles the `.so` straight against an already-configured
php-src tree (`main/php_config.h` present, i.e. `./configure` was run) —
servers usually ship PHP without the `phpize`/`php-config` dev tools:

```bash
cd tests/feedpost
./run.sh /usr/bin/php7.3 /opt/build/src-7.3.33
# → RESULT: FIXED (warning emitted, truncated to 102381 <= 102400)
```

On hardened hosting `php.ini`s (`disable_functions` contains `proc_open`,
which both the harness and `$_FILES` plumbing may need) launch the php
binary with `-d disable_functions=` — `run.sh` does that for you.

## Manual build with phpize (installed PHP with dev tools)

```bash
cd tests/feedpost
/path/to/php/bin/phpize
./configure --with-php-config=/path/to/php/bin/php-config
make
```

## Test script (`feedtest.php`)

```bash
EXT="-d extension=modules/feedpost.so"
php $EXT -d post_max_size=100K feedtest.php 5          # sanity: LEN=5, no warning
php $EXT -d post_max_size=100K feedtest.php 1048576    # see table below
```

(`feedtest.php <n>` feeds an n-byte multipart field with missing
Content-Length and prints `LEN=<n or 102381>` plus the warning, if any.)

## Expected results (`post_max_size=100K`, body = 1 MB)

| Build | Result |
|---|---|
| Pre-patch (stock / minimal) | `LEN=1048576` — **bypass**: full body accepted, no warning |
| Patched (enhanced, `7f24333`+) | `LEN=102381` — truncated at the limit, plus `Warning: Actual POST length does not match Content-Length, and exceeds 102400 bytes` |

Fleet status (2026-10-22): **28/28 installed versions FIXED** across the
three production servers (see the main README, "Production validation").

Note: the multipart handler writes into the global `$_POST`
(like the official upstream test), not into the returned array.
