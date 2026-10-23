#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "php.h"
#include "SAPI.h"
#include "rfc1867.h"
#include "php_feedpost.h"

static char *g_feed_data = NULL;
static size_t g_feed_len = 0;
static size_t g_feed_pos = 0;

#if PHP_VERSION_ID >= 70000
static size_t feed_read_post(char *buffer, size_t count_bytes)
#else
static int feed_read_post(char *buffer, uint count_bytes TSRMLS_DC)
#endif
{
	size_t avail, n;

	if (g_feed_data == NULL) {
		return 0;
	}
	avail = g_feed_len - g_feed_pos;
	n = avail < count_bytes ? avail : count_bytes;
	if (n == 0) {
		return 0;
	}
	memcpy(buffer, g_feed_data + g_feed_pos, n);
	g_feed_pos += n;
	return n;
}

/* feed_multipart(string $body, string $content_type): array
 *
 * Mimics zend_test_handle_post_data() (PHP 8.2+, used by the official
 * GHSA-2cv3-554h-jpmh tests): runs the multipart POST handler over an
 * arbitrary body while SG(request_info).content_length = 0 — i.e. with a
 * missing Content-Length, the condition under which post_max_size could be
 * bypassed on SAPIs whose read_post() ignores content_length. Returns the
 * parsed $_POST array.
 */
PHP_FUNCTION(feed_multipart)
{
	char *data, *ct;
#if PHP_VERSION_ID >= 70000
	size_t data_len, ct_len;
	size_t (*old_read_post)(char *, size_t);
	zval arr;
#else
	int data_len, ct_len;
	int (*old_read_post)(char *, uint TSRMLS_DC);
	zval *arr;
#endif
	sapi_request_info old_ri;
	int64_t old_rpb;
#if PHP_VERSION_ID >= 50600
	unsigned char old_post_read;
#endif

#if PHP_VERSION_ID >= 70000
	if (zend_parse_parameters(ZEND_NUM_ARGS(), "ss", &data, &data_len, &ct, &ct_len) == FAILURE) {
#else
	if (zend_parse_parameters(ZEND_NUM_ARGS() TSRMLS_CC, "ss", &data, &data_len, &ct, &ct_len) == FAILURE) {
#endif
		return;
	}

	old_read_post = sapi_module.read_post;
	old_ri = SG(request_info);
	old_rpb = SG(read_post_bytes);
#if PHP_VERSION_ID >= 50600
	old_post_read = SG(post_read);
#endif

	g_feed_data = data;
	g_feed_len = data_len;
	g_feed_pos = 0;

	sapi_module.read_post = feed_read_post;
	SG(request_info).content_length = 0;
	SG(request_info).request_method = "POST";
	SG(read_post_bytes) = 0;
#if PHP_VERSION_ID >= 50600
	SG(post_read) = 0;
#endif

#if PHP_VERSION_ID >= 70000
	array_init(&arr);
	rfc1867_post_handler(ct, &arr);

	/* PHP 7+: destroy_uploaded_files_hash() is exported; it unlinks the
	 * temp files and frees the hash but leaves the SG() pointer stale. */
	if (SG(rfc1867_uploaded_files)) {
		destroy_uploaded_files_hash();
		SG(rfc1867_uploaded_files) = NULL;
	}

	sapi_module.read_post = old_read_post;
	SG(request_info) = old_ri;
	SG(read_post_bytes) = old_rpb;
#if PHP_VERSION_ID >= 50600
	SG(post_read) = old_post_read;
#endif
	g_feed_data = NULL;
	g_feed_len = 0;
	g_feed_pos = 0;

	RETVAL_ZVAL(&arr, 0, 1);
#else
	MAKE_STD_ZVAL(arr);
	array_init(arr);

	rfc1867_post_handler(ct, arr TSRMLS_CC);

	/* destroy_uploaded_files_hash() is not exported (hidden visibility);
	 * inline equivalent: unlink temp files, destroy the hash. */
	if (SG(rfc1867_uploaded_files)) {
		HashTable *ht = SG(rfc1867_uploaded_files);
		HashPosition pos;
		char **path;

		for (zend_hash_internal_pointer_reset_ex(ht, &pos);
				zend_hash_get_current_data_ex(ht, (void **)&path, &pos) == SUCCESS;
				zend_hash_move_forward_ex(ht, &pos)) {
			if (path && *path) {
				unlink(*path);
			}
		}
		zend_hash_destroy(ht);
		FREE_HASHTABLE(ht);
		SG(rfc1867_uploaded_files) = NULL;
	}

	sapi_module.read_post = old_read_post;
	SG(request_info) = old_ri;
	SG(read_post_bytes) = old_rpb;
#if PHP_VERSION_ID >= 50600
	SG(post_read) = old_post_read;
#endif
	g_feed_data = NULL;
	g_feed_len = 0;
	g_feed_pos = 0;

	RETVAL_ZVAL(arr, 1, 1);
#endif
}

ZEND_BEGIN_ARG_INFO_EX(arginfo_feed_multipart, 0, 0, 2)
	ZEND_ARG_INFO(0, body)
	ZEND_ARG_INFO(0, content_type)
ZEND_END_ARG_INFO()

static zend_function_entry feedpost_functions[] = {
	PHP_FE(feed_multipart, arginfo_feed_multipart)
	PHP_FE_END
};

zend_module_entry feedpost_module_entry = {
	STANDARD_MODULE_HEADER,
	"feedpost",
	feedpost_functions,
	NULL,
	NULL,
	NULL,
	NULL,
	NULL,
	PHP_FEEDPOST_VERSION,
	STANDARD_MODULE_PROPERTIES
};

#ifdef COMPILE_DL_FEEDPOST
ZEND_GET_MODULE(feedpost)
#endif
