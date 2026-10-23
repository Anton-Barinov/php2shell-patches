<?php
/**
 * Stress test for nested array parsing, memory boundaries, and array mutation
 * under patched PHP runtimes (CVE-2026-109618 / CVE-2026-109619).
 *
 * Exercises:
 *  - Deeply nested array parsing (up to depth 60) via parse_str
 *  - High volume array creation (2000+ keys)
 *  - Sparse integer keys and multi-dimensional hash tables
 *  - Array mutation: packed-to-hash growth, element unsetting, ksort, array_merge
 *  - Iteration with references (&$vv) and in-loop key addition
 *  - Works on PHP 5.4 through 8.x with or without ext/json
 */

// Allow high key count for parse_str in this test
ini_set('max_input_vars', '10000');

mt_srand(42);
$q = array();
for ($i = 0; $i < 300; $i++) {
    $q[] = 'a[]=' . $i;
    $q[] = 'h[k' . $i . ']=' . $i;
    $q[] = 'n[x][y' . $i . '][]=' . $i;
    $q[] = 'm[' . ($i % 7) . '][' . ($i % 5) . ']=' . $i;
    $q[] = 's[' . ($i * 3) . ']=' . $i;   // sparse int keys
}
$q[] = 'one[only]=1';
$q[] = 'single[]=x';
$q[] = 'e[]=';

// Deterministic shuffle
usort($q, function ($x, $y) {
    return strcmp(md5($x), md5($y));
});

$raw_query = implode('&', $q);
$r = array();
parse_str($raw_query, $r);

$out = array();
foreach ($r as $k => $v) {
    $c = $v; // copy-on-write
    if (is_array($c)) {
        $c['new_' . $k] = 1; // trigger packed -> hash transition
        $keys = array_keys($c);
        if (!empty($keys)) {
            unset($c[$keys[0]]); // element deletion
        }
        ksort($c);
        $c = array_merge($c, array('z' => 1), array(5, 6));

        // Use serialize for compatibility across minimal/full builds
        $encoded = array_map('serialize', array_values($c));
        $c2 = array_flip($encoded);

        // Reference modification during iteration
        $iter = 0;
        foreach ($c as $kk => &$vv) {
            if (++$iter % 3 == 0) {
                $c['add' . $iter] = $iter;
            }
        }
        unset($vv);

        $out[$k] = array(
            count($c),
            count($c2),
            md5(serialize($c)),
            md5(serialize($v))
        );
    }
}
ksort($out);

// 1. Output summary hash of array transformations
$hash = md5(serialize($out));
$cnt_a = isset($r['a']) ? count($r['a']) : 0;
$cnt_h = isset($r['h']) ? count($r['h']) : 0;
$cnt_nx = isset($r['n']['x']) ? count($r['n']['x']) : 0;
$cnt_s = isset($r['s']) ? count($r['s']) : 0;

echo "ARRAY_STRESS_HASH: {$hash}\n";
echo "COUNTS: a={$cnt_a} h={$cnt_h} n_x={$cnt_nx} s={$cnt_s}\n";

// 2. Deep nesting test (depth 60) + wide array (2000 keys)
$deep_keys = str_repeat('d', 1) . str_repeat('[a]', 60) . '=1';
$wide_keys = 'w[' . implode(']=1&w[', range(1, 2000)) . ']=1';
$r2 = array();
parse_str($deep_keys . '&' . $wide_keys, $r2);

$d = isset($r2['d']) ? $r2['d'] : null;
$depth = 0;
while (is_array($d)) {
    $d = reset($d);
    $depth++;
}

$wcount = isset($r2['w']) ? count($r2['w']) : 0;
$sum = isset($r2['w']) ? array_sum(array_keys($r2['w'])) : 0;

echo "DEEP_NESTING: depth={$depth}\n";
echo "WIDE_ARRAY: count={$wcount} sum={$sum}\n";

// Assertions for test harness
$ok = true;
if ($depth !== 60) {
    echo "ERROR: Expected depth 60, got {$depth}\n";
    $ok = false;
}
if ($wcount !== 2000) {
    echo "ERROR: Expected wide array count 2000, got {$wcount}\n";
    $ok = false;
}
if ($sum !== 2001000) {
    echo "ERROR: Expected wide sum 2001000, got {$sum}\n";
    $ok = false;
}
if ($cnt_a !== 300 || $cnt_h !== 300 || $cnt_nx !== 300 || $cnt_s !== 300) {
    echo "ERROR: Array counts mismatch\n";
    $ok = false;
}

if ($ok) {
    echo "STRESS_TEST_OK\n";
    exit(0);
} else {
    echo "STRESS_TEST_FAIL\n";
    exit(1);
}
