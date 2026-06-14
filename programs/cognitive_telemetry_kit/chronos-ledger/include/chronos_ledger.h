/*
 * chronos_ledger — tamper-evident accountability log for AI agents (C-ABI).
 *
 * Tamper-evidence: each event is canonicalised (RFC 8785) and folded into a
 * rolling SHA-256 chain head; ML-DSA-65 signs the head on milestones. Callers
 * build the event body as ordinary JSON (any key order); the library
 * canonicalises before hashing so Zig, Go and Swift agree on the bytes.
 *
 * Determinism guardrail: JSON floats and integers that do not fit int64 are
 * REJECTED (CL_ERR_FLOAT / CL_ERR_NUMBER). Send large magnitudes and timestamps
 * (seq, *_ns, *_ms, byte counts) as decimal STRINGS.
 *
 * Memory: buffers returned via out-parameters are heap-allocated by the library
 * and must be released with cl_free().
 */
#ifndef CHRONOS_LEDGER_H
#define CHRONOS_LEDGER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Fixed sizes (ML-DSA-65 / FIPS 204). */
#define CL_PK_LEN 1952  /* public key  */
#define CL_SK_LEN 4032  /* secret key  */
#define CL_SIG_LEN 3309 /* signature   */
#define CL_HEAD_HEX_LEN 64 /* chain head as lowercase hex (no NUL) */

/* Return codes. */
#define CL_OK 0
#define CL_ERR_ALLOC (-1)
#define CL_ERR_FLOAT (-2)            /* JSON float in event body            */
#define CL_ERR_NUMBER (-3)           /* integer exceeds int64 (use a string) */
#define CL_ERR_RESERVED (-4)         /* body used a reserved key (v/seq/prev/this/sig) */
#define CL_ERR_NO_KEY (-5)           /* milestone append on a keyless chain */
#define CL_ERR_SIGN (-6)             /* keygen / signing failure            */
#define CL_ERR_PARSE (-7)            /* malformed JSON                      */
#define CL_ERR_ARG (-8)              /* null handle / bad argument          */
#define CL_ERR_EMIT_UNAVAIL (-9)     /* sink socket missing / send failed   */
#define CL_ERR_EMIT_WOULDBLOCK (-10) /* sink buffer full right now          */

/* Opaque hash-chain handle. */
typedef struct cl_chain cl_chain;

/*
 * Generate an ML-DSA-65 keypair.
 *   seed_ptr : 32 bytes for deterministic generation, or NULL for system RNG.
 *   out_pk   : caller buffer of CL_PK_LEN bytes.
 *   out_sk   : caller buffer of CL_SK_LEN bytes.
 */
int cl_generate_keypair(const uint8_t *seed_ptr, uint8_t *out_pk, uint8_t *out_sk);

/* Create a client-side chain (forwards events, cannot sign). NULL on OOM. */
cl_chain *cl_chain_create(void);

/* Create a sink-side chain that signs milestone heads. NULL on OOM. */
cl_chain *cl_chain_create_signing(const uint8_t *sk /*CL_SK_LEN*/, const uint8_t *pk /*CL_PK_LEN*/);

void cl_chain_destroy(cl_chain *chain);

/* Write the current chain head into out_head_hex (CL_HEAD_HEX_LEN bytes, no NUL). */
int cl_chain_head_hex(cl_chain *chain, uint8_t *out_head_hex);

/*
 * Append one event.
 *   content_json : event body as a JSON object (any key order, no reserved keys).
 *   milestone    : non-zero → sign the new head (chain must hold a key).
 *   out_json/out_len : receive a newly-allocated canonical shipped event
 *                      (includes "this", plus "sig" on a signed milestone).
 *                      Free with cl_free(*out_json, *out_len).
 *   out_head_hex : CL_HEAD_HEX_LEN bytes, the new chain head.
 * Returns CL_OK or a negative CL_ERR_*.
 */
int cl_append(cl_chain *chain,
              const uint8_t *content_json, size_t content_len,
              int milestone,
              uint8_t **out_json, size_t *out_len,
              uint8_t *out_head_hex);

/*
 * Verify a shipped event against a public key. Outputs are 0/1. An event is
 * trustworthy only when chain_ok AND (for milestones) sig_ok are both 1.
 */
int cl_verify(const uint8_t *pk /*CL_PK_LEN*/,
              const uint8_t *shipped_json, size_t json_len,
              int *out_chain_ok, int *out_sig_present, int *out_sig_ok);

/* Free a buffer returned by cl_append. */
void cl_free(uint8_t *ptr, size_t len);

/*
 * Non-blocking, fire-and-forget send of one payload to the privileged sink at
 * an AF_UNIX datagram socket. Never blocks the caller; returns
 * CL_ERR_EMIT_WOULDBLOCK or CL_ERR_EMIT_UNAVAIL if the sink can't take it now.
 */
int cl_emit(const uint8_t *socket_path, size_t path_len,
            const uint8_t *payload, size_t payload_len);

#ifdef __cplusplus
}
#endif

#endif /* CHRONOS_LEDGER_H */
