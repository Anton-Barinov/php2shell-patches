# Interpreting php2shell-check

The scanner reports evidence about the executable on disk and its SAPI default
configuration. It does not certify all applications, FPM pools, loaded Apache
modules, or workers that still run an old executable after a package update.
Check each web SAPI after restarting it. PHP CLI settings do not establish the
settings used by a website.

```bash
./php2shell-check --json
./php2shell-check --binary /usr/sbin/php-fpm7.4
./php2shell-check --binary /usr/bin/php7.4 --probe-oom
```

`--probe-oom` is optional and CLI-only. It starts a separate process with `-n`,
an 8M request limit and one 32M allocation. It observes whether request shutdown
runs. It does not execute an RCE payload or exercise the session UAF. A graceful
OOM with known soft-OOM patch evidence is not classified as a legacy bailout.

| Status | Meaning |
| --- | --- |
| PATCHED | Allocator fix evidence and disabled upload progress in SAPI defaults; effective pool/application settings still require checking. |
| MITIGATED | Some protection evidence, but allocator or serializer protection remains unconfirmed. |
| UNKNOWN | Insufficient evidence, failed inspection, or an unrecognized vendor build. Missing symbols do not prove an unpatched binary. |
| VULNERABLE | Optional CLI probe observed legacy graceful OOM without recognized allocator fix evidence; remediation and vendor investigation required. This does not demonstrate RCE. |

Exit codes: 0 for patch evidence on every discovered runtime, 1 for observed
legacy OOM behaviour, 2 for partial/unknown results or an empty inventory.
JSON represents an unreadable upload-progress setting as `null`, not `false`.
`patch_applied` denotes allocator fix evidence, not complete coverage of all CVEs.
Version thresholds are those documented in this repository; a header or version
string is not independent verification of vendor source provenance.

## Why individual fingerprints are insufficient

- `max_multipart_body_parts` and multipart parsing limits are independent of the
  allocator fix; `max_input_vars` can also cap parsed POST fields on old builds.
- The POST length warning only establishes evidence of a multipart change.
- Session incomplete-class markers alone do not establish allocator safety.
- Allocator symbols alone do not establish session serializer safety.
- Empty output from an unsupported `php-fpm -r` command is not an INI setting.
- A disabled setting in one pool does not disable the setting in every pool.
- A stripped/custom binary may lack searchable function names despite a backport.

## HTTP and controlled SAPI diagnostics

`--url` always returns `INCONCLUSIVE` (exit 2) for a successful observation.
Headers, cookies, WAF/CDN responses and small multipart requests cannot establish
memory safety or effective serializer settings. POST requests can invoke normal
application handlers; select a diagnostic URL you control.

`verify/cvecheck.php` with the Bash/PowerShell drivers checks observable behaviour
on an explicitly deployed, token-gated endpoint. It does not exercise actual UAF
or serializer object-injection chains. The OOM allocation is bounded and is skipped
if the request-local 32M limit cannot be established. Proxy 500/502 responses,
network failures, absent error messages and healthy follow-up requests do not
prove an allocator fix. These diagnostic drivers return 2 when no explicit
probe failure occurred, because security verification remains incomplete.

`tests/stress.php` checks array/runtime consistency, not exploit resistance.
`tests/feedpost/` specifically tests enforcement of `post_max_size` without an
honest Content-Length. Its runner reports `RESULT: FIXED` or `RESULT: BYPASS`;
exit 0 means the experiment completed, not necessarily that the build is fixed.
Full security validation additionally requires trusted patch provenance and
regression tests for each relevant allocator, UAF and serializer path.

## Offline regression coverage

`python3 tests/checker-test.py` uses fake PHP and curl executables to exercise
classification, failed settings, JSON escaping, FPM inspection, upstream and
unrecognized versions, allocator/session/multipart fingerprints and HTTP ambiguity.
It is included in `tests/run-all.sh` and the existing CI tooling job. These tests
verify scanner decisions; they do not substitute for building each PHP backport.

## Runtime coverage and transport compatibility

The default inventory includes CLI, CGI, FPM and LiteSpeed binaries under the
known panel prefixes; every executable receives its own verdict. Deep scans
also include `php-cgi*` and `lsphp*` and preserve paths containing spaces.
Build utilities (`phpize`, `php-config`) and backup trees are excluded from
automatic inventory. `--binary` can explicitly inspect an otherwise excluded
path. An undiscovered or unreadable SAPI cannot be certified by another SAPI.

JSON includes `ssl_transport`, `tls_transport` (true/false/null) and
`serialize_handler`. These are read from that SAPI's `-i` output. `null` means
unreadable, and `unknown` means the serializer could not be read. Exact `ssl`
and `tls` registry entries are required; `tlsv1.2` alone does not establish
availability of the generic `tls://` transport. This is a compatibility check,
not a TLS handshake, certificate validation, or CVE verdict.
