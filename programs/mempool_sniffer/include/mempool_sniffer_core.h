/**
 * Mempool Sniffer Core - C FFI
 *
 * High-performance Bitcoin mempool transaction sniffer with io_uring async I/O
 *
 * Features:
 * - Real-time Bitcoin P2P connection
 * - SIMD-accelerated hash processing
 * - Whale transaction detection (>1 BTC)
 * - Callback-based event notification
 * - Zero-copy packet parsing
 *
 * Performance: <1µs latency per transaction
 */

#ifndef MEMPOOL_SNIFFER_CORE_H
#define MEMPOOL_SNIFFER_CORE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle to sniffer instance */
typedef struct MS_Sniffer MS_Sniffer;

/* Transaction hash (32 bytes, big-endian for display) */
typedef struct {
    uint8_t bytes[32];
} MS_TxHash;

/* Transaction information */
typedef struct {
    MS_TxHash hash;
    int64_t value_satoshis;  /* Total output value in satoshis */
    uint32_t input_count;
    uint32_t output_count;
    uint8_t is_whale;        /* 1 if value >= 1 BTC */
} MS_Transaction;

/* Connection status */
typedef enum {
    MS_STATUS_DISCONNECTED = 0,
    MS_STATUS_CONNECTING = 1,
    MS_STATUS_CONNECTED = 2,
    MS_STATUS_HANDSHAKE_COMPLETE = 3,
} MS_Status;

/* Error codes */
typedef enum {
    MS_SUCCESS = 0,
    MS_OUT_OF_MEMORY = 1,
    MS_CONNECTION_FAILED = 2,
    MS_INVALID_HANDLE = 3,
    MS_ALREADY_RUNNING = 4,
    MS_NOT_RUNNING = 5,
    MS_IO_ERROR = 6,
} MS_Error;

/* Callback for transaction events */
typedef void (*MS_TxCallback)(const MS_Transaction* tx, void* user_data);

/* Callback for connection status changes */
typedef void (*MS_StatusCallback)(MS_Status status, const char* message, void* user_data);

/**
 * Create a new mempool sniffer instance
 *
 * @param node_ip IPv4 address of Bitcoin node (e.g., "216.107.135.88")
 * @param port    Port number (typically 8333 for mainnet)
 * @return        Sniffer handle or NULL on error
 */
MS_Sniffer* ms_sniffer_create(const char* node_ip, uint16_t port);

/**
 * Destroy sniffer instance and free resources
 *
 * @param sniffer Sniffer handle (NULL safe)
 */
void ms_sniffer_destroy(MS_Sniffer* sniffer);

/**
 * Set transaction callback
 *
 * Called when a new transaction is detected in the mempool
 *
 * @param sniffer   Sniffer handle
 * @param callback  Function to call on transaction events
 * @param user_data Opaque pointer passed to callback
 * @return          Error code
 */
MS_Error ms_sniffer_set_tx_callback(
    MS_Sniffer* sniffer,
    MS_TxCallback callback,
    void* user_data
);

/**
 * Set status callback
 *
 * Called on connection status changes
 *
 * @param sniffer   Sniffer handle
 * @param callback  Function to call on status changes
 * @param user_data Opaque pointer passed to callback
 * @return          Error code
 */
MS_Error ms_sniffer_set_status_callback(
    MS_Sniffer* sniffer,
    MS_StatusCallback callback,
    void* user_data
);

/**
 * Start the sniffer (non-blocking)
 *
 * Connects to Bitcoin node and begins listening for transactions.
 * Returns immediately - use callbacks to receive events.
 *
 * @param sniffer Sniffer handle
 * @return        Error code
 */
MS_Error ms_sniffer_start(MS_Sniffer* sniffer);

/**
 * Stop the sniffer
 *
 * Disconnects from Bitcoin node and stops event callbacks.
 *
 * @param sniffer Sniffer handle
 * @return        Error code
 */
MS_Error ms_sniffer_stop(MS_Sniffer* sniffer);

/**
 * Check if sniffer is running
 *
 * @param sniffer Sniffer handle
 * @return        1 if running, 0 otherwise
 */
int ms_sniffer_is_running(const MS_Sniffer* sniffer);

/**
 * Get current connection status
 *
 * @param sniffer Sniffer handle
 * @return        Current status
 */
MS_Status ms_sniffer_get_status(const MS_Sniffer* sniffer);

/**
 * Get error message for error code
 *
 * @param error Error code
 * @return      Human-readable error string
 */
const char* ms_error_string(MS_Error error);

/**
 * Get library version
 *
 * @return Version string (e.g., "1.0.0-core")
 */
const char* ms_version(void);

/**
 * Get performance information
 *
 * @return Performance description string
 */
const char* ms_performance_info(void);

#ifdef __cplusplus
}
#endif

#endif /* MEMPOOL_SNIFFER_CORE_H */
