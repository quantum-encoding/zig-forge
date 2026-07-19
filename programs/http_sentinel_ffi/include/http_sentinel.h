/*
 * http_sentinel — blocking C-ABI HTTP/HTTPS client (libhttp_sentinel.a)
 *
 * A synchronous HTTP client for non-Zig hosts, built on Zig's std.http.Client.
 * The caller owns every buffer; the library allocates nothing the caller must
 * free. One TCP + TLS connection is established per call (no keep-alive).
 *
 * Threading: every call builds its own IO context and client, so calls are
 * independent and safe to make concurrently from any number of threads. The
 * last-error message (http_sentinel_get_error) is THREAD-LOCAL — read it on the
 * same thread that made the failing call.
 *
 * TLS: certificate verification is always on (system CA bundle). There is no
 * option to disable it.
 *
 * Timeouts: each request is bounded by a total (connect + send + receive)
 * deadline, 30000 ms by default. Override per-process with the environment
 * variable HTTP_SENTINEL_TIMEOUT_MS; a value of 0 disables the deadline and
 * restores pure-blocking behavior. Expiry returns HTTP_SENTINEL_TIMEOUT.
 *
 * Generated to match src/ffi.zig. Keep the two in sync — the struct layouts and
 * enum values below are asserted against src/ffi.zig by `zig build test`, and
 * are mirrored a third time in quantum_vault's src-tauri/src/core/http_sentinel.rs.
 * Any change here is an FFI break requiring a lockstep consumer update.
 */
#ifndef HTTP_SENTINEL_H
#define HTTP_SENTINEL_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Return codes. 0 is success; every failure is negative. A non-2xx HTTP status
 * is NOT a failure — it is reported as 0 with the status in HttpResponse. */
enum {
    HTTP_SENTINEL_SUCCESS           =  0,
    HTTP_SENTINEL_INVALID_URL       = -1, /* unparseable / overlong / bad scheme */
    HTTP_SENTINEL_CONNECTION_FAILED = -2, /* DNS, refused, unreachable, reset    */
    HTTP_SENTINEL_REQUEST_FAILED    = -3, /* send/receive, decompression failure */
    HTTP_SENTINEL_RESPONSE_TOO_LARGE= -4, /* compressed body exceeded 64 MiB cap */
    HTTP_SENTINEL_INVALID_INPUT     = -5, /* null pointer / >64 headers          */
    HTTP_SENTINEL_TIMEOUT           = -6, /* total request deadline expired      */
    HTTP_SENTINEL_TLS_ERROR         = -7, /* TLS init / CA bundle failure        */
    HTTP_SENTINEL_INTERNAL_ERROR    = -8, /* OOM or unexpected internal state    */
    HTTP_SENTINEL_BUFFER_TOO_SMALL  = -9  /* reserved                            */
};

/* Response metadata. The body itself is copied into the caller's buffer. */
typedef struct {
    /* HTTP status code (200, 404, 500, …). 0 if no response was received. */
    uint16_t status_code;
    /* Bytes written into response_body. Never exceeds response_body_size. */
    size_t   body_len;
    /* True if the body did not fit in response_body; body_len bytes are the
     * valid prefix. For a compressed body this reflects the DECOMPRESSED size. */
    bool     truncated;
} HttpResponse;

/* One request header. Both pointers must be non-NULL; the strings need not be
 * NUL-terminated (the explicit lengths are used). Maximum 64 headers per
 * request — a higher header_count is rejected with HTTP_SENTINEL_INVALID_INPUT
 * rather than silently dropping headers. */
typedef struct {
    const uint8_t *name;
    size_t         name_len;
    const uint8_t *value;
    size_t         value_len;
} HttpHeader;

/*
 * Common contract for all verb functions:
 *
 *   url                 NUL-terminated URL, max 8192 bytes. http and https only.
 *   headers             Array of header_count entries; may be NULL if
 *                       header_count is 0.
 *   header_count        0..64.
 *   request_body        Body bytes; may be NULL if request_body_len is 0. Sent
 *                       with Content-Length (no chunked encoding).
 *   response_body       Caller-owned buffer receiving the response body. On a
 *                       gzip/deflate response the body is decompressed first;
 *                       a corrupt or truncated compressed stream is a hard
 *                       failure (HTTP_SENTINEL_REQUEST_FAILED), never a
 *                       silently partial body.
 *   response_body_size  Capacity of response_body. If the body is larger, the
 *                       first response_body_size bytes are written and
 *                       response->truncated is set.
 *   response            Out-parameter; must be non-NULL. Fully initialized
 *                       before any request is attempted.
 *
 * Returns 0 on a completed exchange, or a negative HTTP_SENTINEL_* code.
 */

int http_sentinel_get(const uint8_t *url,
                      const HttpHeader *headers, size_t header_count,
                      uint8_t *response_body, size_t response_body_size,
                      HttpResponse *response);

int http_sentinel_post(const uint8_t *url,
                       const HttpHeader *headers, size_t header_count,
                       const uint8_t *request_body, size_t request_body_len,
                       uint8_t *response_body, size_t response_body_size,
                       HttpResponse *response);

int http_sentinel_put(const uint8_t *url,
                      const HttpHeader *headers, size_t header_count,
                      const uint8_t *request_body, size_t request_body_len,
                      uint8_t *response_body, size_t response_body_size,
                      HttpResponse *response);

int http_sentinel_patch(const uint8_t *url,
                        const HttpHeader *headers, size_t header_count,
                        const uint8_t *request_body, size_t request_body_len,
                        uint8_t *response_body, size_t response_body_size,
                        HttpResponse *response);

int http_sentinel_delete(const uint8_t *url,
                         const HttpHeader *headers, size_t header_count,
                         uint8_t *response_body, size_t response_body_size,
                         HttpResponse *response);

/* HEAD: no response body is read; only response->status_code is meaningful. */
int http_sentinel_head(const uint8_t *url,
                       const HttpHeader *headers, size_t header_count,
                       HttpResponse *response);

/*
 * Copy this thread's last error message into buf as a NUL-terminated string and
 * return the number of bytes written (excluding the NUL). Truncates to fit.
 * If buf is NULL or buf_size is 0, returns the length that would be required
 * (excluding the NUL) and writes nothing.
 *
 * The message is cleared at the start of every request, so it never carries a
 * stale diagnostic from a previous call.
 */
size_t http_sentinel_get_error(uint8_t *buf, size_t buf_size);

/* Library version, e.g. "http-sentinel-ffi-1.0.0". Static storage; do not free. */
const char *http_sentinel_version(void);

/* Zig toolchain this library was compiled with, e.g. "zig-0.16.0". Static
 * storage; do not free. */
const char *http_sentinel_zig_version(void);

#ifdef __cplusplus
}
#endif

#endif /* HTTP_SENTINEL_H */
