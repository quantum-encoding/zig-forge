/*
 * ABI smoke test — compiles the shipped C header against the real static
 * library and exercises the contract from the C side.
 *
 * Its job is to fail the build if include/http_sentinel.h ever drifts from
 * src/ffi.zig: a renamed or removed export fails to link, a reordered struct
 * field fails the layout assertions below, and a changed return-code value
 * fails the behavioral checks. (C linkage carries no type information, so a
 * changed parameter type is NOT caught here — that pairing is enforced by the
 * matching assertions on the Zig side in src/ffi.zig.) Nothing here touches the
 * network.
 */
#include "http_sentinel.h"

#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    /* Struct layout, as the C compiler sees it. Must match the comptime
     * assertions in src/ffi.zig and quantum_vault's #[repr(C)] mirror. */
    assert(sizeof(HttpResponse) == 24);
    assert(offsetof(HttpResponse, status_code) == 0);
    assert(offsetof(HttpResponse, body_len) == 8);
    assert(offsetof(HttpResponse, truncated) == 16);

    assert(sizeof(HttpHeader) == 32);
    assert(offsetof(HttpHeader, name) == 0);
    assert(offsetof(HttpHeader, name_len) == 8);
    assert(offsetof(HttpHeader, value) == 16);
    assert(offsetof(HttpHeader, value_len) == 24);

    /* Version accessors return static, NUL-terminated storage. */
    const char *v = http_sentinel_version();
    const char *zv = http_sentinel_zig_version();
    assert(v != NULL && v[0] != '\0');
    assert(zv != NULL && strncmp(zv, "zig-", 4) == 0);

    HttpResponse resp;
    unsigned char body[16];

    /* A NULL URL must be rejected without touching the network, and must
     * leave a readable thread-local diagnostic. */
    int rc = http_sentinel_get(NULL, NULL, 0, body, sizeof(body), &resp);
    assert(rc == HTTP_SENTINEL_INVALID_INPUT);

    /* NULL buffer reports the required length rather than dereferencing. */
    size_t need = http_sentinel_get_error(NULL, 128);
    assert(need > 0);

    unsigned char errbuf[256];
    size_t n = http_sentinel_get_error(errbuf, sizeof(errbuf));
    assert(n == need);
    assert(errbuf[n] == 0);

    /* A header count above the 64-slot limit is refused, not silently trimmed
     * (a dropped Authorization header would surface only as a confusing 401). */
    HttpHeader one = { (const unsigned char *)"X-Test", 6, (const unsigned char *)"1", 1 };
    rc = http_sentinel_get((const unsigned char *)"http://127.0.0.1:1/", &one, 65,
                           body, sizeof(body), &resp);
    assert(rc == HTTP_SENTINEL_INVALID_INPUT);

    printf("abi_smoke: ok (%s, %s)\n", v, zv);
    return 0;
}
