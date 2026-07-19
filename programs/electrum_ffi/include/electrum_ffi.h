/*
 * electrum_ffi.h — C-ABI surface of programs/electrum_ffi
 *
 * Static library of Electrum wallet-protocol *helpers*: scripthash
 * computation, JSON-RPC 2.0 request framing, and response parsing. It
 * performs NO networking — the calling layer (quantum_vault's Rust core)
 * owns sockets and TLS.
 *
 * This header is the single source of truth for the exported symbols and
 * struct layouts. Per zig-forge/CLAUDE.md the "lockstep consumers" rule
 * applies: any change to a symbol name, signature, or struct layout below
 * must be mirrored in quantum_vault/src-tauri/src/core/electrum.rs (which
 * hand-declares the same extern block and #[repr(C)] structs). Today the
 * two agree; this header makes that mechanically checkable.
 *
 * Buffer-size contracts (the library reads/writes fixed-length buffers the
 * caller must provide; these lengths are NOT parameters):
 *   - pubkey_hash:        exactly 20 bytes (hash160)
 *   - out_scripthash_hex: exactly 64 bytes (SHA-256 scripthash, lowercase hex)
 *   - out_scripthash:     exactly 32 bytes (decoded scripthash)
 *   - hex (scripthash):   exactly 64 bytes
 *   - out_txid_hex:       exactly 64 bytes (txid, lowercase hex)
 */

#ifndef ELECTRUM_FFI_H
#define ELECTRUM_FFI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Result / error codes returned by the C-ABI functions.
 *
 * Request builders and length-returning parsers return a NON-NEGATIVE byte
 * length on success, or one of these NEGATIVE codes on failure. Fixed-output
 * functions return `ELECTRUM_SUCCESS` (0) on success. Mirrors the Zig
 * `ElectrumResult` enum in src/ffi.zig.
 */
typedef enum {
    ELECTRUM_SUCCESS           =  0,
    ELECTRUM_PARSE_ERROR       = -1,
    ELECTRUM_INVALID_SCRIPTHASH = -2,
    ELECTRUM_BUFFER_TOO_SMALL  = -3,
    ELECTRUM_NULL_POINTER      = -4,
    ELECTRUM_INVALID_RESPONSE  = -5,
    ELECTRUM_SERVER_ERROR      = -6,
} ElectrumResult;

/* Unspent transaction output. Matches Zig `CUtxo` (extern struct). */
typedef struct {
    uint8_t  txid[32];  /* internal byte order (reversed from display hex) */
    uint32_t vout;
    uint64_t value;     /* satoshis */
    uint32_t height;    /* 0 = unconfirmed */
} CUtxo;

/* Address balance. Matches Zig `CBalance` (extern struct). */
typedef struct {
    uint64_t confirmed;
    int64_t  unconfirmed;
} CBalance;

/* Transaction-history entry. Matches Zig `CTxHistoryEntry` (extern struct). */
typedef struct {
    uint8_t txid[32];
    int32_t height;     /* 0 or negative if unconfirmed */
    uint64_t fee;       /* satoshis, 0 if not provided */
} CTxHistoryEntry;

/* --- Scripthash computation --- */

/* pubkey_hash: 20 bytes in, out_scripthash_hex: 64 bytes out. */
int electrum_scripthash_p2wpkh(const uint8_t *pubkey_hash, uint8_t *out_scripthash_hex);
int electrum_scripthash_p2pkh(const uint8_t *pubkey_hash, uint8_t *out_scripthash_hex);
int electrum_scripthash_from_script(const uint8_t *script, size_t script_len, uint8_t *out_scripthash_hex);

/* --- JSON-RPC request building --- */
/* Each returns the number of bytes written to out_request (newline-terminated
 * JSONL frame), or a negative ElectrumResult code. */

int electrum_build_get_balance_request(const uint8_t *scripthash_hex, uint32_t request_id, uint8_t *out_request, size_t out_request_size);
int electrum_build_listunspent_request(const uint8_t *scripthash_hex, uint32_t request_id, uint8_t *out_request, size_t out_request_size);
int electrum_build_get_history_request(const uint8_t *scripthash_hex, uint32_t request_id, uint8_t *out_request, size_t out_request_size);
int electrum_build_broadcast_request(const uint8_t *raw_tx_hex, size_t raw_tx_hex_len, uint32_t request_id, uint8_t *out_request, size_t out_request_size);
int electrum_build_get_tx_request(const uint8_t *txid_hex, uint32_t request_id, uint8_t *out_request, size_t out_request_size);
int electrum_build_subscribe_headers_request(uint32_t request_id, uint8_t *out_request, size_t out_request_size);
int electrum_build_version_request(const uint8_t *client_name, size_t client_name_len, const uint8_t *protocol_version, size_t protocol_version_len, uint32_t request_id, uint8_t *out_request, size_t out_request_size);

/* --- Response parsing --- */

/* Fills *out_balance; returns ELECTRUM_SUCCESS or a negative code. */
int electrum_parse_balance_response(const uint8_t *response, size_t response_len, CBalance *out_balance);
/* Returns the number of UTXOs written (<= max_utxos), or a negative code. */
int electrum_parse_listunspent_response(const uint8_t *response, size_t response_len, CUtxo *out_utxos, size_t max_utxos);
/* Returns the number of history entries written (<= max_entries), or a negative code. */
int electrum_parse_history_response(const uint8_t *response, size_t response_len, CTxHistoryEntry *out_entries, size_t max_entries);
/* out_txid_hex: 64 bytes out. Returns ELECTRUM_SUCCESS, or a negative code
 * (ELECTRUM_SERVER_ERROR if the response carried a JSON-RPC error object). */
int electrum_parse_broadcast_response(const uint8_t *response, size_t response_len, uint8_t *out_txid_hex);
/* Writes the raw-transaction hex to out_raw_tx_hex; returns its length, or a negative code. */
int electrum_parse_get_tx_response(const uint8_t *response, size_t response_len, uint8_t *out_raw_tx_hex, size_t out_raw_tx_size);
/* Returns the tip block height (>= 0), or a negative code. */
int electrum_parse_headers_response(const uint8_t *response, size_t response_len);

/* --- Utilities --- */

/* Copies up to buf_size-1 bytes of the thread-local last-error message into
 * buf (NUL-terminated); returns the number of bytes written, or, if buf_size
 * is 0, the length of the pending message. */
size_t electrum_get_error(uint8_t *buf, size_t buf_size);
/* hex: 64 bytes in, out_scripthash: 32 bytes out. */
int electrum_hex_to_scripthash(const uint8_t *hex, uint8_t *out_scripthash);
/* sizeof(CUtxo) / sizeof(CBalance) as seen by the library — for ABI checks. */
size_t electrum_utxo_size(void);
size_t electrum_balance_size(void);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ELECTRUM_FFI_H */
