/**
 * Coinbase FIX 5.0 SP2 C FFI Interface
 *
 * This header provides C-compatible bindings for the Coinbase FIX executor,
 * enabling high-frequency trading via FIX 5.0 SP2 protocol.
 *
 * Build: zig build coinbase-fix
 * Link: -lcoinbase_fix
 */

#ifndef COINBASE_FIX_H
#define COINBASE_FIX_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// =============================================================================
// Types
// =============================================================================

/**
 * Opaque handle to Coinbase FIX executor instance
 */
typedef void* CoinbaseHandle;

/**
 * Order side
 */
typedef enum {
    COINBASE_SIDE_BUY = 0,
    COINBASE_SIDE_SELL = 1
} CoinbaseSide;

/**
 * Order type
 */
typedef enum {
    COINBASE_ORDER_MARKET = 0,
    COINBASE_ORDER_LIMIT = 1
} CoinbaseOrderType;

/**
 * Error codes returned by FIX operations
 */
typedef enum {
    COINBASE_SUCCESS = 0,
    COINBASE_ERR_NOT_CONNECTED = -1,
    COINBASE_ERR_INVALID_ORDER = -2,
    COINBASE_ERR_SEND_FAILED = -3,
    COINBASE_ERR_CONNECTION_FAILED = -4,
    COINBASE_ERR_AUTH_FAILED = -5,
    COINBASE_ERR_UNKNOWN = -99
} CoinbaseErrorCode;

/**
 * Execution result from order operations
 * Note: price and quantity use fixed-point decimal representation
 *       actual_value = value / 10^scale
 */
typedef struct {
    uint64_t order_id;            // Unique order identifier
    bool success;                 // True if operation succeeded
    int64_t fill_price_value;     // Fill price (fixed-point value)
    uint8_t fill_price_scale;     // Fill price decimal scale
    int64_t fill_quantity_value;  // Fill quantity (fixed-point value)
    uint8_t fill_quantity_scale;  // Fill quantity decimal scale
    int64_t timestamp;            // Unix timestamp of execution
    int32_t error_code;           // Error code (0 = success)
} CoinbaseExecutionResult;

/**
 * Executor status information
 */
typedef struct {
    bool connected;           // True if connected to FIX gateway
    uint64_t orders_sent;     // Total orders sent
    uint64_t orders_filled;   // Total orders filled
    uint64_t orders_rejected; // Total orders rejected
} CoinbaseExecutorStatus;

/**
 * Batch order structure for bulk submissions
 */
typedef struct {
    uint64_t signal_id;           // Signal/strategy identifier
    const char* symbol;           // Trading pair (e.g., "BTC-USD")
    CoinbaseSide side;            // Buy or sell
    CoinbaseOrderType order_type; // Market or limit
    int64_t quantity_value;       // Order quantity (fixed-point)
    uint8_t quantity_scale;       // Quantity decimal scale
    int64_t price_value;          // Limit price (fixed-point)
    uint8_t price_scale;          // Price decimal scale
} CoinbaseBatchOrder;

/**
 * Callback function type for execution reports
 */
typedef void (*CoinbaseExecutionCallback)(
    const CoinbaseExecutionResult* result,
    void* user_data
);

// =============================================================================
// Lifecycle Functions
// =============================================================================

/**
 * Create a new Coinbase FIX executor
 *
 * @param api_key     Coinbase API key
 * @param api_secret  Coinbase API secret (base64)
 * @param passphrase  Coinbase API passphrase
 * @param use_sandbox True for sandbox environment, false for production
 * @return Handle to executor, or NULL on failure
 *
 * Example:
 *   CoinbaseHandle handle = coinbase_fix_create(
 *       "your-api-key",
 *       "your-base64-secret",
 *       "your-passphrase",
 *       true  // sandbox mode
 *   );
 */
CoinbaseHandle coinbase_fix_create(
    const char* api_key,
    const char* api_secret,
    const char* passphrase,
    bool use_sandbox
);

/**
 * Destroy a Coinbase FIX executor and free resources
 *
 * @param handle Executor handle (safe to pass NULL)
 */
void coinbase_fix_destroy(CoinbaseHandle handle);

// =============================================================================
// Connection Functions
// =============================================================================

/**
 * Connect to Coinbase FIX gateway
 *
 * @param handle Executor handle
 * @return COINBASE_SUCCESS on success, error code on failure
 *
 * Note: This establishes TCP connection and performs FIX logon with
 *       HMAC-SHA256 authentication.
 */
CoinbaseErrorCode coinbase_fix_connect(CoinbaseHandle handle);

/**
 * Disconnect from Coinbase FIX gateway
 *
 * @param handle Executor handle
 */
void coinbase_fix_disconnect(CoinbaseHandle handle);

/**
 * Check if connected to FIX gateway
 *
 * @param handle Executor handle
 * @return True if connected
 */
bool coinbase_fix_is_connected(CoinbaseHandle handle);

// =============================================================================
// Order Functions
// =============================================================================

/**
 * Send a new order to Coinbase
 *
 * @param handle          Executor handle
 * @param signal_id       Signal/strategy identifier for tracking
 * @param symbol          Trading pair (e.g., "BTC-USD")
 * @param side            COINBASE_SIDE_BUY or COINBASE_SIDE_SELL
 * @param order_type      COINBASE_ORDER_MARKET or COINBASE_ORDER_LIMIT
 * @param quantity_value  Order quantity (fixed-point integer)
 * @param quantity_scale  Decimal places for quantity
 * @param price_value     Limit price (fixed-point integer), ignored for market
 * @param price_scale     Decimal places for price
 * @param result          Pointer to receive execution result
 * @return COINBASE_SUCCESS on success, error code on failure
 *
 * Example (buy 0.1 BTC at limit price $50000):
 *   CoinbaseExecutionResult result;
 *   coinbase_fix_send_order(
 *       handle,
 *       12345,                  // signal_id
 *       "BTC-USD",              // symbol
 *       COINBASE_SIDE_BUY,      // side
 *       COINBASE_ORDER_LIMIT,   // order_type
 *       1,                      // quantity: 0.1 (value=1, scale=1)
 *       1,                      // quantity_scale
 *       5000000,                // price: 50000 (value=5000000, scale=2)
 *       2,                      // price_scale
 *       &result
 *   );
 */
CoinbaseErrorCode coinbase_fix_send_order(
    CoinbaseHandle handle,
    uint64_t signal_id,
    const char* symbol,
    CoinbaseSide side,
    CoinbaseOrderType order_type,
    int64_t quantity_value,
    uint8_t quantity_scale,
    int64_t price_value,
    uint8_t price_scale,
    CoinbaseExecutionResult* result
);

/**
 * Cancel an existing order
 *
 * @param handle   Executor handle
 * @param order_id Order ID to cancel
 * @return COINBASE_SUCCESS on success, error code on failure
 */
CoinbaseErrorCode coinbase_fix_cancel_order(CoinbaseHandle handle, uint64_t order_id);

/**
 * Send multiple orders in a batch
 *
 * @param handle  Executor handle
 * @param orders  Array of batch orders
 * @param count   Number of orders in array
 * @param results Array to receive execution results (same size as orders)
 * @return Number of successfully sent orders
 */
size_t coinbase_fix_send_batch(
    CoinbaseHandle handle,
    const CoinbaseBatchOrder* orders,
    size_t count,
    CoinbaseExecutionResult* results
);

// =============================================================================
// Status Functions
// =============================================================================

/**
 * Get executor status
 *
 * @param handle Executor handle
 * @param status Pointer to receive status
 * @return COINBASE_SUCCESS on success
 */
CoinbaseErrorCode coinbase_fix_get_status(
    CoinbaseHandle handle,
    CoinbaseExecutorStatus* status
);

/**
 * Poll for incoming FIX messages (non-blocking)
 *
 * @param handle Executor handle
 * @return COINBASE_SUCCESS on success
 *
 * Note: Call this regularly in your event loop to process
 *       execution reports and heartbeats.
 */
CoinbaseErrorCode coinbase_fix_poll(CoinbaseHandle handle);

// =============================================================================
// Callback Functions
// =============================================================================

/**
 * Register callback for execution reports
 *
 * @param callback  Function to call on execution reports
 * @param user_data User data passed to callback
 */
void coinbase_fix_set_callback(
    CoinbaseExecutionCallback callback,
    void* user_data
);

// =============================================================================
// Utility Functions
// =============================================================================

/**
 * Get library version string
 *
 * @return Version string (e.g., "1.0.0-fix50sp2")
 */
const char* coinbase_fix_version(void);

/**
 * Get FIX session version
 *
 * @return Session version string (e.g., "FIXT.1.1")
 */
const char* coinbase_fix_session_version(void);

/**
 * Get FIX application version ID
 *
 * @return Application version ID (e.g., "9" for FIX 5.0 SP2)
 */
const char* coinbase_fix_app_version_id(void);

#ifdef __cplusplus
}
#endif

#endif /* COINBASE_FIX_H */
