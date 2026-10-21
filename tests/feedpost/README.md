# tests/feedpost — `post_max_size` bypass verification harness (GHSA-2cv3-554h-jpmh)

A tiny phpize extension for PHP 5.6 that reproduces the official upstream
test scenario (`zend_test_handle_post_data()` in PHP 8.2.35) on old branches:
it runs the multipart POST handler over an arbitrary body **with
`Content-Length = 0` (i.e. missing)** — the condition under which
`post_max_size` could be bypassed on SAPIs whose `read_post()` does not
honour Content-Length (e.g. Apache with chunked/HTTP-1.0 bodies).

`feed_multipart(string $body, string $content_type): array` parses `$body`
via `rfc1867_post_handler()` and returns what landed in `$_POST`.

## Build

Requires an **installed** PHP (run `make install` after building the patched
tree, e.g. prefix `/opt/php-5.6-v3`):

```bash
cd tests/feedpost
/path/to/php/bin/phpize
./configure --with-php-config=/path/to/php/bin/php-config
make
```

## Test script

```php
<?php
// feedtest.php
$n = (int)$argv[1];
$data = "--b\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n"
      . str_repeat("a", $n) . "\r\n--b--\r\n";
feed_multipart($data, "multipart/form-data; boundary=b");
echo "LEN=", isset($_POST["a"]) ? strlen($_POST["a"]) : -1, "\n";
```

## Expected results (`post_max_size=100K`, body = 1 MB)

| Build | Result |
|---|---|
| Pre-patch (stock / minimal) | `LEN=1048576` — **bypass**: full body accepted, no warning |
| Patched (enhanced, `7f24333`+) | `LEN=102381` — truncated at the limit, plus `Warning: Actual POST length does not match Content-Length, and exceeds 102400 bytes` |

```bash
EXT="-d extension=modules/feedpost.so"
php $EXT -d post_max_size=100K feedtest.php 5          # sanity: LEN=5, no warning
php $EXT -d post_max_size=100K feedtest.php 1048576    # see table above
```

Note: the multipart handler writes into the global `$_POST`
(like the official upstream test), not into the returned array.
