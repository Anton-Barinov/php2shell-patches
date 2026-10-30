<?php
/*
 * cvecheck.php — non-destructive mitigation validator for CVE-2026-109618 / 109619 ("php2shell").
 *
 * Compatible with PHP 5.4, 5.5, 5.6, 7.x, 8.x.
 *
 * This is NOT an exploit. It probes the observable behaviour that the patch
 * changes, so an operator can confirm a build is patched on the real SAPI
 * (mod_php / PHP-FPM) after deploying it. It never attempts code execution.
 *
 * SAFETY:
 *   - Access is gated by a token (?k=). Set CVECHECK_TOKEN below before deploy.
 *   - The OOM probe caps memory_limit to 32M for its own request only, so it
 *     exhausts that worker's request budget, not the host's RAM.
 *   - Deploy it to an isolated path, run the checks, then DELETE it. Do not
 *     leave it installed.
 */

$CVECHECK_TOKEN = 'CHANGE_ME';   // set a random value; pass it as ?k=<token>

/* Polyfill hash_equals for PHP 5.4 / 5.5 */
if (!function_exists('hash_equals')) {
    function hash_equals($known_string, $user_string) {
        $ret = 0;
        $klen = strlen($known_string);
        $ulen = strlen($user_string);
        if ($klen !== $ulen) {
            return false;
        }
        for ($i = 0; $i < $klen; $i++) {
            $ret |= (ord($known_string[$i]) ^ ord($user_string[$i]));
        }
        return $ret === 0;
    }
}

if (!isset($_GET['k']) || !hash_equals($CVECHECK_TOKEN, (string)$_GET['k'])) {
    header('HTTP/1.1 403 Forbidden');
    header('Content-Type: text/plain');
    echo "forbidden\n";
    exit;
}

$t = isset($_GET['t']) ? $_GET['t'] : 'info';
header('Content-Type: text/plain');

if ($t === 'info') {
    /* max_multipart_body_parts exists in patched builds (or 8.2+):
       on an unpatched branch ini_get() returns "" (empty/false). */
    $mmbp = ini_get('max_multipart_body_parts');
    $uprog = ini_get('session.upload_progress.enabled');

    echo "php=" . PHP_VERSION . "\n";
    echo "sapi=" . PHP_SAPI . "\n";
    echo "max_multipart_body_parts=" . ($mmbp !== false ? $mmbp : "") . "\n";
    echo "max_input_vars=" . ini_get('max_input_vars') . "\n";
    echo "session.upload_progress.enabled=" . ($uprog !== false ? $uprog : "") . "\n";
    echo "memory_limit=" . ini_get('memory_limit') . "\n";
    echo "pid=" . getmypid() . "\n";
    echo "fix_marker=" . (($mmbp === '' || $mmbp === false) ? "ABSENT" : "PRESENT") . "\n";
    echo "ok\n";

} elseif ($t === 'multipart') {
    /* The runner POSTs more parts than max_input_vars. A patched/hardened
       parser caps the number of parsed parts; count($_POST) reflects the cap. */
    echo "POST_count=" . count($_POST) . "\n";
    echo "FILES_count=" . count($_FILES) . "\n";
    echo "pid=" . getmypid() . "\n";
    echo "ok\n";

} elseif ($t === 'oom') {
    /* Drive this request to an allocation failure under a low, request-local
       memory_limit. In a PATCHED build the worker ends the process (_exit)
       instead of longjmp-ing back through partially-initialised request state,
       so the client sees the connection close with no graceful
       "Allowed memory size ... exhausted" fatal in the body. */
    @ini_set('memory_limit', '32M');
    if (ini_get('memory_limit') !== '32M') {
        echo "OOM_PROBE_UNAVAILABLE\n";
        exit;
    }
    register_shutdown_function(function () { echo "graceful_shutdown\n"; });
    echo "before_oom pid=" . getmypid() . "\n";
    for (ob_start(); ob_get_level(); ) { ob_end_flush(); }
    flush();
    $a = str_repeat('x', 64 * 1024 * 1024);
    echo "AFTER_OOM_SHOULD_NOT_PRINT\n";

} else {
    echo "unknown t\n";
}
