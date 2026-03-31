/**
 * Sentient Network - Signal Broadcast FFI
 *
 * High-performance ZMQ PUB/SUB signal distribution for trading intelligence.
 *
 * Usage from Rust:
 *   #[link(name = "signal_broadcast", kind = "static")]
 *   extern "C" {
 *       fn sentient_publisher_create(endpoint: *const c_char) -> *mut SignalPublisher;
 *       // ...
 *   }
 */

#ifndef SIGNAL_BROADCAST_H
#define SIGNAL_BROADCAST_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// =============================================================================
// Signal Types
// =============================================================================

/** Trading signal action */
typedef enum {
    SIGNAL_ACTION_BUY = 0,
    SIGNAL_ACTION_SELL = 1,
    SIGNAL_ACTION_HOLD = 2,
    SIGNAL_ACTION_CLOSE_LONG = 3,
    SIGNAL_ACTION_CLOSE_SHORT = 4,
    SIGNAL_ACTION_SCALE_IN = 5,
    SIGNAL_ACTION_SCALE_OUT = 6,
} SignalAction;

/** Asset class */
typedef enum {
    ASSET_CLASS_CRYPTO = 0,
    ASSET_CLASS_STOCKS = 1,
    ASSET_CLASS_FOREX = 2,
    ASSET_CLASS_FUTURES = 3,
    ASSET_CLASS_OPTIONS = 4,
} AssetClass;

/** Time horizon */
typedef enum {
    TIME_HORIZON_SCALP = 0,
    TIME_HORIZON_INTRADAY = 1,
    TIME_HORIZON_SWING = 2,
    TIME_HORIZON_POSITION = 3,
    TIME_HORIZON_LONG_TERM = 4,
} TimeHorizon;

/**
 * Trading signal structure (96 bytes, cache-line aligned)
 *
 * This is the core message type for signal distribution.
 * Binary format for zero-copy transmission.
 */
typedef struct __attribute__((packed)) {
    // Header (32 bytes)
    uint64_t signal_id;       // Unique monotonic ID
    int64_t  timestamp_ns;    // Nanosecond timestamp
    uint64_t sequence;        // Sequence number for ordering
    uint32_t flags;           // Reserved flags
    uint32_t _pad;            // Alignment padding

    // Symbol (16 bytes)
    char symbol[16];          // Null-terminated symbol

    // Signal data (32 bytes)
    uint8_t  action;          // SignalAction enum
    uint8_t  asset_class;     // AssetClass enum
    uint8_t  time_horizon;    // TimeHorizon enum
    uint8_t  confidence;      // 0-100 percentage
    uint8_t  _pad2[4];        // Padding
    double   current_price;   // Current price
    double   target_price;    // Target price (0 if not set)
    double   stop_loss;       // Stop loss (0 if not set)

    // Risk parameters (16 bytes)
    float    suggested_size_pct;  // Position size % (0.0-1.0)
    float    max_leverage;        // Max leverage (1.0 = no leverage)
    float    risk_score;          // 0.0-1.0 risk score
    uint32_t expires_in_ms;       // Expiration in ms (0 = no expiry)
} TradingSignal;

// Compile-time size assertion
_Static_assert(sizeof(TradingSignal) == 96, "TradingSignal must be 96 bytes");

// =============================================================================
// Opaque Handle Types
// =============================================================================

typedef struct SignalPublisher SignalPublisher;
typedef struct SignalSubscriber SignalSubscriber;

// =============================================================================
// Publisher Functions
// =============================================================================

/**
 * Create a new signal publisher bound to the given endpoint.
 *
 * @param endpoint ZMQ endpoint (e.g., "tcp://*:5555")
 * @return Publisher handle, or NULL on failure
 */
SignalPublisher* sentient_publisher_create(const char* endpoint);

/**
 * Destroy a publisher and release resources.
 *
 * @param publisher Publisher handle
 */
void sentient_publisher_destroy(SignalPublisher* publisher);

/**
 * Publish a trading signal to all subscribers.
 *
 * The signal's sequence and timestamp are set automatically.
 *
 * @param publisher Publisher handle
 * @param signal Signal to publish (modified with seq/timestamp)
 * @return 0 on success, -1 on failure
 */
int sentient_publisher_send(SignalPublisher* publisher, TradingSignal* signal);

/**
 * Publish a heartbeat message.
 *
 * @param publisher Publisher handle
 * @return 0 on success, -1 on failure
 */
int sentient_publisher_heartbeat(SignalPublisher* publisher);

/**
 * Get publisher statistics.
 *
 * @param publisher Publisher handle
 * @param signals Output: total signals sent
 * @param bytes Output: total bytes sent
 */
void sentient_publisher_stats(const SignalPublisher* publisher,
                               uint64_t* signals,
                               uint64_t* bytes);

// =============================================================================
// Subscriber Functions
// =============================================================================

/**
 * Create a new signal subscriber connected to the given endpoint.
 *
 * @param endpoint ZMQ endpoint (e.g., "tcp://server:5555")
 * @return Subscriber handle, or NULL on failure
 */
SignalSubscriber* sentient_subscriber_create(const char* endpoint);

/**
 * Destroy a subscriber and release resources.
 *
 * @param subscriber Subscriber handle
 */
void sentient_subscriber_destroy(SignalSubscriber* subscriber);

/**
 * Subscribe to signals for a specific symbol.
 *
 * @param subscriber Subscriber handle
 * @param symbol Symbol to subscribe to (e.g., "BTCUSD")
 * @return 0 on success, -1 on failure
 */
int sentient_subscriber_subscribe(SignalSubscriber* subscriber, const char* symbol);

/**
 * Subscribe to all signals.
 *
 * @param subscriber Subscriber handle
 * @return 0 on success, -1 on failure
 */
int sentient_subscriber_subscribe_all(SignalSubscriber* subscriber);

/**
 * Subscribe to heartbeat messages.
 *
 * @param subscriber Subscriber handle
 * @return 0 on success, -1 on failure
 */
int sentient_subscriber_subscribe_heartbeat(SignalSubscriber* subscriber);

/**
 * Receive a signal (blocking).
 *
 * @param subscriber Subscriber handle
 * @param signal Output: received signal
 * @return 0 on success, -1 on failure
 */
int sentient_subscriber_recv(SignalSubscriber* subscriber, TradingSignal* signal);

/**
 * Try to receive a signal (non-blocking).
 *
 * @param subscriber Subscriber handle
 * @param signal Output: received signal (if available)
 * @return 0 if signal received, -1 if no signal available
 */
int sentient_subscriber_try_recv(SignalSubscriber* subscriber, TradingSignal* signal);

/**
 * Get subscriber statistics.
 *
 * @param subscriber Subscriber handle
 * @param received Output: total signals received
 * @param last_seq Output: last sequence number seen
 */
void sentient_subscriber_stats(const SignalSubscriber* subscriber,
                                uint64_t* received,
                                uint64_t* last_seq);

// =============================================================================
// Signal Helper Functions
// =============================================================================

/**
 * Create a zero-initialized signal.
 *
 * @return New TradingSignal with all fields zeroed
 */
TradingSignal sentient_signal_create(void);

/**
 * Set the symbol field of a signal.
 *
 * @param signal Signal to modify
 * @param symbol Null-terminated symbol string
 */
void sentient_signal_set_symbol(TradingSignal* signal, const char* symbol);

#ifdef __cplusplus
}
#endif

#endif // SIGNAL_BROADCAST_H
