<?php
// feedtest.php <n-bytes> — feeds an n-byte multipart POST body with a
// *missing* Content-Length (SG(request_info).content_length = 0) through
// rfc1867_post_handler(), like zend_test_handle_post_data() does on 8.2+.
// (No PHP 7+ syntax here — the harness runs on 5.6 too.)
$n = isset($argv[1]) ? (int)$argv[1] : 0;
$data = "--b\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n"
      . str_repeat("a", $n) . "\r\n--b--\r\n";
feed_multipart($data, "multipart/form-data; boundary=b");
echo "LEN=", isset($_POST["a"]) ? strlen($_POST["a"]) : -1, "\n";
