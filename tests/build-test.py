#!/usr/bin/env python3
"""Build/OOM regressions using real patch/tar and simulated configure/make/PHP."""
import io
import os
import shlex
import shutil
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.tools = self.work / 'tools'
        self.tools.mkdir()
        self.prefix = self.work / 'installed php'
        self.patch = self.work / 'input patch.diff'
        self.patch.write_text('--- a/example\n+++ b/example\n@@ -1 +1 @@\n-old\n+new\n')
        self.env = dict(os.environ, PATH=str(self.tools) + os.pathsep + os.environ['PATH'], STATE=str(self.work))
        self.php = self.work / 'fake-php'
        self.php.write_text('''#!/bin/bash
case "$*" in *stream_get_transports*) printf 'P2S_TRANSPORTS:%s\\n' "${TRANSPORTS-ssl,tls}"; exit "${TRANSPORT_RC:-0}" ;; esac
case "${OOM_MODE:-pass}" in
 pass) echo OOM_BEFORE; echo 'Allowed memory size exhausted' >&2; exit 1 ;;
 graceful) printf 'OOM_BEFORE\\nOOM_SHUTDOWN\\n'; echo 'Allowed memory size exhausted' >&2; exit 255 ;;
 empty) exit 1 ;;
 success) echo OOM_BEFORE; exit 0 ;;
 diagnostic_missing) echo OOM_BEFORE; exit 1 ;;
esac
''')
        self.php.chmod(0o755)
        make = self.tools / 'make'
        make.write_text('''#!/bin/bash
if [ "$1" = install ]; then
 echo INSTALL >> "$STATE/events"
 prefix=$(cat "$STATE/prefix")
 mkdir -p "$prefix/bin"
 cp sapi/cli/php "$prefix/bin/php"
else
 [ "${BUILD_FAIL:-0}" = 0 ] || exit 7
 mkdir -p sapi/cli sapi/fpm
 cp "$STATE/fake-php" sapi/cli/php
 cp "$STATE/fake-php" sapi/fpm/php-fpm
fi
''')
        make.chmod(0o755)
        configure = '''#!/bin/bash
printf '%s\\n' "$@" > "$STATE/args"
for arg; do case "$arg" in --prefix=*) printf '%s' "${arg#*=}" > "$STATE/prefix" ;; esac; done
'''
        build_dir = self.work / '.php2shell-build'
        build_dir.mkdir()
        with tarfile.open(build_dir / 'php-7.4.33.tar.gz', 'w:gz') as archive:
            for name, content, mode in [('example', 'old\n', 0o644), ('configure', configure, 0o755)]:
                item = tarfile.TarInfo('php-7.4.33/' + name)
                item.size = len(content.encode())
                item.mode = mode
                archive.addfile(item, io.BytesIO(content.encode()))

    def run_build(self, **env):
        return subprocess.run(['bash', str(ROOT / 'build/build-patched-php.sh'), '7.4.33', str(self.patch), str(self.prefix), '--without-curl'], cwd=self.work, env=dict(self.env, **env), text=True, capture_output=True)

    def test_absolute_patch_prefix_spaces_and_configure_arguments(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        args = (self.work / 'args').read_text().splitlines()
        self.assertIn('--without-curl', args)
        self.assertNotIn('7.4.33', args)
        self.assertNotIn(str(self.patch), args)
        self.assertNotIn(str(self.prefix), args)
        self.assertTrue((self.prefix / 'bin/php').is_file())

    def test_relative_patch(self):
        self.patch = Path('input patch.diff')
        self.assertEqual(self.run_build().returncode, 0)

    def test_rerun_starts_from_pristine_sources(self):
        self.assertEqual(self.run_build().returncode, 0)
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_oom_failure_prevents_install(self):
        for mode in ['graceful', 'empty', 'success', 'diagnostic_missing']:
            with self.subTest(mode=mode):
                result = self.run_build(OOM_MODE=mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.work / 'events').exists())

    def test_compile_failure_prevents_install(self):
        self.assertNotEqual(self.run_build(BUILD_FAIL='1').returncode, 0)
        self.assertFalse((self.work / 'events').exists())

    def test_failed_patch_prevents_configure(self):
        self.patch.write_text('invalid patch\n')
        self.assertNotEqual(self.run_build().returncode, 0)
        self.assertFalse((self.work / 'args').exists())

    def test_corrupt_archive_prevents_configure(self):
        (self.work / '.php2shell-build/php-7.4.33.tar.gz').write_text('broken')
        self.assertNotEqual(self.run_build().returncode, 0)
        self.assertFalse((self.work / 'args').exists())

    def test_failed_download_is_not_cached(self):
        archive = self.work / '.php2shell-build/php-7.4.33.tar.gz'
        archive.unlink()
        curl = self.tools / 'curl'
        curl.write_text('#!/bin/bash\nwhile [ $# -gt 0 ]; do if [ "$1" = -o ]; then echo partial > "$2"; shift 2; else shift; fi; done\nexit 22\n')
        curl.chmod(0o755)
        self.assertNotEqual(self.run_build().returncode, 0)
        self.assertFalse(archive.exists())

    def test_system_swap_uses_real_probe_exit_code(self):
        source = (ROOT / 'deploy/swap-system-php.sh').read_text()
        block = source[source.index('# Patch verification probe'):source.index('# --- swap')]
        sandbox = self.work / 'source'
        (sandbox / 'sapi/cli').mkdir(parents=True)
        (sandbox / 'sapi/cli/php').symlink_to(self.php)
        baseline = self.work / 'transports'
        baseline.write_text('P2S_TRANSPORTS:ssl,tls\n')
        for mode, expected in [('pass', 0), ('graceful', 1), ('empty', 1)]:
            result = subprocess.run(['bash', '-eu', '-c', block], cwd=sandbox, env=dict(self.env, HERE=str(ROOT / 'deploy'), PATCH='test.patch', OOM_MODE=mode, TRANSPORT_BASELINE=str(baseline)), capture_output=True)
            self.assertEqual(result.returncode, expected, result.stderr)

    def aapanel_script(self):
        panel_root = self.work / 'panel'
        state = panel_root / 'php-cve2026'
        state.mkdir(parents=True)
        prefix = panel_root / 'php/74'
        (prefix / 'bin').mkdir(parents=True)
        (prefix / 'sbin').mkdir()
        raw = "'./configure' " + shlex.quote('--prefix=' + str(prefix))
        (prefix / 'bin/php').write_text("#!/bin/bash\nprintf '%s\\n' " + shlex.quote('Configure Command => ' + raw) + "\n")
        (prefix / 'bin/php').chmod(0o755)
        (prefix / 'sbin/php-fpm').touch()
        shutil.copyfile(self.work / '.php2shell-build/php-7.4.33.tar.gz', state / 'php-7.4.33.tar.gz')
        for name, content in [('id', '#!/bin/sh\necho 0\n'), ('ldd', '#!/bin/sh\nexit 0\n')]:
            (self.tools / name).write_text(content)
            (self.tools / name).chmod(0o755)
        source = (ROOT / 'deploy/swap-aapanel-php.sh').read_text()
        source = source.replace('/www/server', str(panel_root))
        source = source.replace('REPO_ROOT="$(cd "$HERE/.." && pwd)"', 'REPO_ROOT=' + shlex.quote(str(ROOT)))
        script = self.work / 'aapanel.sh'
        script.write_text(source)
        return script, state

    def test_aapanel_relative_patch_survives_cd(self):
        script, _ = self.aapanel_script()
        result = subprocess.run(['bash', str(script), 'build', '74', self.patch.name], cwd=self.work, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_aapanel_bad_archive_stops_before_configure(self):
        script, state = self.aapanel_script()
        (state / 'php-7.4.33.tar.gz').write_text('broken')
        result = subprocess.run(['bash', str(script), 'build', '74', self.patch.name], cwd=self.work, env=self.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Source extraction failed', result.stdout)
        self.assertFalse((self.work / 'args').exists())

    def test_aapanel_rollback_refuses_to_move_running_prefix(self):
        source = (ROOT / 'deploy/swap-aapanel-php.sh').read_text()
        restore = source[source.index('restore() {'):source.index('do_install() {')]
        prefix = self.work / 'prefix'
        prefix.mkdir()
        (prefix / 'sentinel').write_text('original')
        code = 'fpm_stop() { return 1; }; die() { exit 1; }; ' + restore + '\nrestore unused 1'
        result = subprocess.run(['bash', '-u', '-c', code], env=dict(self.env, PREFIX=str(prefix)), capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertTrue((prefix / 'sentinel').exists())
        self.assertFalse(Path(str(prefix) + '.failed').exists())

    def test_transport_guard_rejects_losses(self):
        baseline = self.work / 'transports'
        helper = str(ROOT / 'build/verify-transports.sh')
        result = subprocess.run([helper, 'snapshot', str(self.php), str(baseline)], env=self.env, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for transports, expected in [('ssl,tls', 0), ('ssl', 1), ('tls', 1), ('', 1), ('tcp', 1)]:
            with self.subTest(transports=transports):
                result = subprocess.run([helper, 'check', str(self.php), str(baseline)], env=dict(self.env, TRANSPORTS=transports), capture_output=True)
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_transport_probe_errors_do_not_mean_empty_list(self):
        baseline = self.work / 'transports'
        helper = str(ROOT / 'build/verify-transports.sh')
        result = subprocess.run([helper, 'snapshot', str(self.php), str(baseline)], env=dict(self.env, TRANSPORT_RC='1'), capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(baseline.exists())

    def test_absent_transport_baseline_is_not_accepted(self):
        result = subprocess.run([str(ROOT / 'build/verify-transports.sh'), 'check', str(self.php), str(self.work / 'absent')], env=self.env, capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_aapanel_tls_loss_aborts_before_stopping_service(self):
        script, _ = self.aapanel_script()
        prefix = self.work / 'panel/php/74'
        old_php = prefix / 'bin/php'
        old_php.write_text('#!/bin/sh\necho P2S_TRANSPORTS:ssl,tls\n')
        source_dir = self.work / 'built'
        (source_dir / 'sapi/cli').mkdir(parents=True)
        (source_dir / 'sapi/fpm').mkdir(parents=True)
        for binary in [source_dir / 'sapi/cli/php', source_dir / 'sapi/fpm/php-fpm']:
            binary.write_text('#!/bin/sh\necho P2S_TRANSPORTS:ssl\n')
            binary.chmod(0o755)
        init = self.work / 'init'
        init.write_text('#!/bin/sh\nexit 0\n')
        init.chmod(0o755)
        log_dir = self.work / 'logs'
        log_dir.mkdir()
        source = script.read_text()
        install = source[source.index('do_install() {'):source.index('do_rollback() {')]
        functions = 'is_patched() { return 0; }; fpm_running() { return 0; }; info() { :; }; die() { echo "$*"; exit 1; }; fpm_stop() { touch "$STATE/stopped"; }; '
        env = dict(self.env, PREFIX=str(prefix), SRC_DIR=str(source_dir), INIT=str(init), LOG_DIR=str(log_dir), VER='74', REPO_ROOT=str(ROOT))
        result = subprocess.run(['bash', '-u', '-c', functions + install + '\ndo_install'], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('installation aborted', result.stdout)
        self.assertFalse((self.work / 'stopped').exists())

    def test_intentionally_absent_tls_does_not_block_replacement(self):
        baseline = self.work / 'no-tls'
        helper = str(ROOT / 'build/verify-transports.sh')
        env = dict(self.env, TRANSPORTS='')
        snapshot = subprocess.run([helper, 'snapshot', str(self.php), str(baseline)], env=env, capture_output=True)
        self.assertEqual(snapshot.returncode, 0, snapshot.stderr)
        result = subprocess.run([helper, 'check', str(self.php), str(baseline)], env=env, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
