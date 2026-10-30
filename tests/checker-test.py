#!/usr/bin/env python3
"""Offline verdict regressions: fake PHP/curl executables, no target servers."""
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CheckerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)

    def check(self, version='7.4.33', signatures='', upload='On', name='php', probe=False, transports=None):
        binary = self.work / name
        binary.write_text('''#!/bin/bash
# %s
case " $* " in
  *" -v "*) printf 'startup warning\\nPHP %s (test)\\n' ;;
  *" -i "*) printf 'Loaded Configuration File => /test/quoted"path.ini\\nsession.upload_progress.enabled => %s => %s\\n%s' ;;
  *" -r "*)
    case "$*" in
      *P2S_BEFORE*) printf 'P2S_BEFORE\\nAllowed memory size exhausted\\n%s'; exit %s ;;
      *) echo cli ;;
    esac ;;
esac
''' % (signatures, version, upload, upload,
       '' if transports is None else 'Registered Stream Socket Transports => ' + transports + '\\nsession.serialize_handler => php_serialize => php_serialize\\n',
       '' if 'zend_mm_safe_error_ex' in signatures else 'P2S_SHUTDOWN\n',
       '1' if 'zend_mm_safe_error_ex' in signatures else '255'))
        binary.chmod(0o755)
        args = [str(ROOT / 'php2shell-check'), '--binary', str(binary), '--json']
        if probe:
            args.append('--probe-oom')
        result = subprocess.run(args, text=True, capture_output=True)
        data = json.loads(result.stdout)
        return result.returncode, data['installations'][0]

    def test_multipart_marker_is_not_full_patch(self):
        rc, row = self.check(signatures='Actual POST length does not match Content-Length max_multipart_body_parts')
        self.assertEqual((rc, row['status'], row['patch_applied']), (2, 'UNKNOWN', False))

    def test_session_marker_is_not_allocator_fix(self):
        self.assertEqual(self.check(signatures='incomplete_classes_only __PHP_Incomplete_Class_Serialized')[1]['status'], 'UNKNOWN')

    def test_allocator_alone_does_not_close_serializer(self):
        self.assertEqual(self.check(signatures='zend_mm_safe_error_ex')[1]['status'], 'MITIGATED')

    def test_minimal_patch_and_disabled_progress(self):
        rc, row = self.check(signatures='zend_mm_safe_error_ex', upload='Off')
        self.assertEqual((rc, row['status']), (0, 'PATCHED'))
        self.assertEqual(row['ini_path'], '/test/quoted"path.ini')

    def test_soft_oom_needs_session_evidence(self):
        for sig in ['zend_handle_delayed_oom', 'memory_hard_limit_percent']:
            with self.subTest(sig=sig):
                self.assertEqual(self.check(signatures=sig)[1]['status'], 'MITIGATED')

    def test_ini_only_is_partial(self):
        self.assertEqual(self.check(upload='Off')[1]['status'], 'MITIGATED')

    def test_fpm_uses_info_not_cli_r(self):
        row = self.check(name='php-fpm', upload='On')[1]
        self.assertEqual((row['sapi'], row['upload_progress']), ('fpm', True))

    def test_failed_setting_is_unknown_not_disabled(self):
        row = self.check(name='php-fpm', upload='')[1]
        self.assertIsNone(row['upload_progress'])
        self.assertEqual(row['status'], 'UNKNOWN')

    def test_old_and_future_versions_not_implicitly_safe(self):
        for ver in ['5.3.29', '8.6.0', '8.5.12RC1', 'unknown']:
            with self.subTest(version=ver):
                self.assertEqual(self.check(version=ver)[1]['status'], 'UNKNOWN')

    def test_upstream_version_with_upload_on_is_partial(self):
        for ver in ['8.2.35', '8.3.36', '8.4.27', '8.5.12']:
            with self.subTest(version=ver):
                self.assertEqual(self.check(version=ver)[1]['status'], 'MITIGATED')

    def test_bounded_opt_in_probe(self):
        self.assertEqual(self.check(probe=True)[1]['status'], 'VULNERABLE')
        self.assertEqual(self.check(probe=True, signatures='zend_mm_safe_error_ex', upload='Off')[1]['status'], 'PATCHED')

    def test_remote_headers_cookies_and_cdn_are_not_proof(self):
        curl = self.work / 'curl'
        curl.write_text('''#!/bin/bash
output=0
while [ $# -gt 0 ]; do
  case "$1" in
    -w) output=1; shift 2 ;;
    -D) printf 'HTTP/1.1 200 OK\\r\\nServer: cloudflare\\r\\nX-Powered-By: PHP/8.5.12\\r\\nSet-Cookie: PHPSESSID=test\\r\\n' > "$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ "$output" = 1 ] && printf 200
exit 0
''')
        curl.chmod(0o755)
        env = dict(os.environ, PATH=str(self.work) + os.pathsep + os.environ['PATH'])
        result = subprocess.run([str(ROOT / 'php2shell-check'), '--url', 'https://offline.invalid/', '--json'], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)['status'], 'INCONCLUSIVE')

    def test_proxy_failure_is_not_a_successful_patch_probe(self):
        curl = self.work / 'curl'
        curl.write_text("""#!/bin/bash
case "$*" in
  *"-o /dev/null"*) printf 200 ;;
  *t=oom*)
    while [ $# -gt 0 ]; do
      if [ "$1" = -o ]; then : > "$2"; shift 2; else shift; fi
    done
    printf 502 ;;
  *t=multipart*) printf 'POST_count=1000\\nok\\n' ;;
  *) printf 'php=7.4.33\\nsapi=fpm-fcgi\\nfix_marker=PRESENT\\nsession.upload_progress.enabled=1\\nok\\n' ;;
esac
""")
        curl.chmod(0o755)
        env = dict(os.environ, PATH=str(self.work) + os.pathsep + os.environ['PATH'])
        result = subprocess.run(['bash', str(ROOT / 'verify/run-cvecheck.sh'), 'https://offline.invalid/', 'test'], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertNotIn('PASS - worker died', result.stdout)
        self.assertIn('UNKNOWN - no OOM entry marker', result.stdout)

    def test_transports_are_reported_without_affecting_cve_verdict(self):
        for transports, ssl, tls in [('tcp, ssl, tls, tlsv1.2', True, True), ('tcp, tlsv1.2', False, False), (None, None, None)]:
            with self.subTest(transports=transports):
                _, row = self.check(transports=transports)
                self.assertEqual((row['ssl_transport'], row['tls_transport']), (ssl, tls))
                self.assertEqual(row['status'], 'UNKNOWN')
                if transports is not None:
                    self.assertEqual(row['serialize_handler'], 'php_serialize')

    def test_litespeed_and_cgi_are_distinct_sapis(self):
        self.assertEqual(self.check(name='lsphp')[1]['sapi'], 'litespeed')
        self.assertEqual(self.check(name='php8.1-cgi')[1]['sapi'], 'cgi')

    def test_discovery_includes_panel_cgi_and_litespeed_but_not_tools(self):
        root = self.work / 'fake-root'
        paths = ['www/server/php/74/bin/php', 'www/server/php/74/bin/php-cgi',
                 'www/server/php/74/bin/lsphp', 'www/server/php/74/sbin/php-fpm',
                 'opt/plesk/php/8.1/bin/php-cgi', 'usr/bin/phpize', 'usr/bin/php-config',
                 'opt/php74.old/bin/php', 'opt/custom path/deep/bin/lsphp']
        for name in paths:
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('#!/bin/sh\nexit 0\n')
            target.chmod(0o755)
        source = (ROOT / 'php2shell-check').read_text()
        function = source[source.index('discover_php_binaries() {'):source.index('# Consume the entire match stream')]
        function = re.sub(r'/(usr|opt|www|home|var)(?=/|[ \n])', lambda match: str(root) + match.group(0), function)
        code = 'OPT_BINARY=""; OPT_ALL=1; resolve_path() { printf "%s\\n" "$1"; }; ps() { :; }; ' + function + '\ndiscover_php_binaries'
        result = subprocess.run(['bash', '-c', code], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        found = result.stdout.splitlines()
        self.assertIn(str(root / paths[1]), found)
        self.assertIn(str(root / paths[2]), found)
        self.assertIn(str(root / paths[4]), found)
        self.assertIn(str(root / paths[-1]), found)
        self.assertNotIn(str(root / 'usr/bin/phpize'), found)
        self.assertNotIn(str(root / 'usr/bin/php-config'), found)
        self.assertNotIn(str(root / 'opt/php74.old/bin/php'), found)


if __name__ == '__main__':
    unittest.main()
