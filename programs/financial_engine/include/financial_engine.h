/**
 * Financial Engine - High-Frequency Trading System C API
 *
 * Production-grade C FFI for ultra-low-latency trading engine.
 * Enables integration with Rust, C++, Python, and other languages.
 *
 * Performance:
 * - Sub-microsecond tick processing
 * - 290,000+ ticks/second throughput
 * - Lock-free signal queue
 * - Custom memory pools for zero-GC
 *
 * Thread Safety:
 * - HFT_Engine is thread-safe per-instance
 * - NOT thread-safe across multiple instances
 * - All operations on a single engine must be called from the same thread
 *
 * Usage Pattern:
 *   HFT_Config config = { ... };
 *   HFT_Error err;
 *   HFT_Engine* engine = hft_engine_create(&config, &err);
 *
 *   HFT_MarketTick tick = { ... };
 *   hft_process_tick(engine, &tick);
 *
 *   HFT_Signal signal;
 *   if (hft_get_signal(engine, &signal) == HFT_SUCCESS) {
 *       // Process signal
 *   }
 *
 *   hft_engine_destroy(engine);
 */

#ifndef FINANCIAL_ENGINE_H
#define FINANCIAL_ENGINE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * Opaque Types
 * ============================================================================ */

/**
 * Opaque handle to HFT engine instance.
 *
 * Lifetime:
 * - Created with hft_engine_create()
 * - Destroyed with hft_engine_destroy()
 * - Must not be used after destroy
 */
typedef struct HFT_Engine HFT_Engine;

/* ============================================================================
 * Configuration
 * ============================================================================ */

/**
 * Executor type for order execution.
 *
 * PAPER: Paper trading mode - logs orders but doesn't execute (default)
 * ZMQ:   ZeroMQ to Go Trade Executor (requires running broker)
 * NONE:  No execution - signal generation only
 */
typedef enum {
    HFT_EXECUTOR_PAPER = 0,  /* Paper trading (no real orders, just logging) */
    HFT_EXECUTOR_ZMQ = 1,    /* ZeroMQ to Go Trade Executor */
    HFT_EXECUTOR_NONE = 2,   /* No execution (signal generation only) */
} HFT_ExecutorType;

/**
 * Engine configuration parameters.
 *
 * All rate limits are per-second.
 * All decimal values (position, spread, edge) are in i128 fixed-point
 * with 6 decimal places (1_000_000 = 1.0).
 */
typedef struct {
    uint32_t max_order_rate;         /* Orders per second limit */
    uint32_t max_message_rate;       /* Messages per second limit */
    uint32_t latency_threshold_us;   /* Alert if latency exceeds (microseconds) */
    uint32_t tick_buffer_size;       /* Size of tick history buffer */
    bool     enable_logging;         /* Enable debug logging */

    /* Default strategy parameters */
    __int128 max_position_value;     /* Max position in fixed-point (µ units) */
    __int128 max_spread_value;       /* Max spread in fixed-point (µ units) */
    __int128 min_edge_value;         /* Min edge in fixed-point (µ units) */
    uint32_t tick_window;            /* Tick window for strategy */

    /* Executor selection */
    HFT_ExecutorType executor_type;  /* Trade execution venue */
} HFT_Config;

/* ============================================================================
 * Error Codes
 * ============================================================================ */

/**
 * Error codes returned by engine functions.
 */
typedef enum {
    HFT_SUCCESS = 0,              /* Operation succeeded */
    HFT_OUT_OF_MEMORY = -1,       /* Memory allocation failed */
    HFT_INVALID_CONFIG = -2,      /* Invalid configuration parameters */
    HFT_INVALID_HANDLE = -3,      /* Invalid engine handle (NULL) */
    HFT_INIT_FAILED = -4,         /* Engine initialization failed */
    HFT_STRATEGY_ADD_FAILED = -5, /* Failed to add strategy */
    HFT_PROCESS_TICK_FAILED = -6, /* Failed to process market tick */
    HFT_INVALID_SYMBOL = -7,      /* Invalid symbol (empty or too long) */
    HFT_QUEUE_EMPTY = -8,         /* Signal queue is empty */
    HFT_QUEUE_FULL = -9,          /* Signal queue is full */
} HFT_Error;

/* ============================================================================
 * Market Data
 * ============================================================================ */

/**
 * Market tick (quote update).
 *
 * Borrow semantics:
 * - symbol_ptr must remain valid during hft_process_tick() call
 * - All decimal values are i128 fixed-point with 6 decimal places
 */
typedef struct {
    const uint8_t* symbol_ptr;    /* Pointer to symbol string (NOT null-terminated) */
    uint32_t       symbol_len;    /* Length of symbol string (max 32) */
    __int128       bid_value;     /* Bid price (fixed-point, 6 decimals) */
    __int128       ask_value;     /* Ask price (fixed-point, 6 decimals) */
    __int128       bid_size_value;/* Bid size (fixed-point, 6 decimals) */
    __int128       ask_size_value;/* Ask size (fixed-point, 6 decimals) */
    int64_t        timestamp;     /* Unix timestamp (seconds) */
    uint64_t       sequence;      /* Sequence number (for ordering) */
} HFT_MarketTick;

/* ============================================================================
 * Trading Signals
 * ============================================================================ */

/**
 * Trading signal generated by strategy.
 *
 * Borrow semantics:
 * - symbol_ptr must remain valid while signal is in use
 * - Action: 0=hold, 1=buy, 2=sell
 */
typedef struct {
    const uint8_t* symbol_ptr;         /* Pointer to symbol string */
    uint32_t       symbol_len;         /* Length of symbol string */
    uint32_t       action;             /* 0=hold, 1=buy, 2=sell */
    float          confidence;         /* Confidence level (0.0 to 1.0) */
    __int128       target_price_value; /* Target price (fixed-point) */
    __int128       quantity_value;     /* Quantity (fixed-point) */
    int64_t        timestamp;          /* Signal timestamp */
} HFT_Signal;

/* ============================================================================
 * Statistics
 * ============================================================================ */

/**
 * Engine performance statistics.
 */
typedef struct {
    uint64_t ticks_processed;     /* Total ticks processed */
    uint64_t signals_generated;   /* Total signals generated */
    uint64_t orders_sent;         /* Total orders sent */
    uint64_t trades_executed;     /* Total trades executed */
    uint64_t avg_latency_us;      /* Average latency (microseconds) */
    uint64_t peak_latency_us;     /* Peak latency (microseconds) */
    uint32_t queue_depth;         /* Current signal queue depth */
    uint32_t queue_capacity;      /* Signal queue capacity */
} HFT_Stats;

/* ============================================================================
 * Lifecycle Functions
 * ============================================================================ */

/**
 * Create a new HFT engine instance.
 *
 * Parameters:
 *   config     - Engine configuration (must not be NULL)
 *   out_error  - Output error code (optional, can be NULL)
 *
 * Returns:
 *   Opaque engine handle, or NULL on failure.
 *   Check out_error for failure reason.
 *
 * Thread Safety:
 *   Safe to create multiple engines from different threads.
 *   Each engine must be used from a single thread.
 *
 * Example:
 *   HFT_Config config = { .max_order_rate = 10000, ... };
 *   HFT_Error err;
 *   HFT_Engine* engine = hft_engine_create(&config, &err);
 *   if (!engine) {
 *       fprintf(stderr, "Failed: %s\n", hft_error_string(err));
 *   }
 */
HFT_Engine* hft_engine_create(const HFT_Config* config, HFT_Error* out_error);

/**
 * Destroy engine and free all resources.
 *
 * Parameters:
 *   engine - Engine handle (NULL is safe, will be no-op)
 *
 * Thread Safety:
 *   Must be called from the same thread that uses the engine.
 *
 * Note:
 *   After destroy, the handle is invalid and must not be used.
 */
void hft_engine_destroy(HFT_Engine* engine);

/* ============================================================================
 * Market Data Processing
 * ============================================================================ */

/**
 * Process a market tick (quote update).
 *
 * Parameters:
 *   engine - Engine handle (must not be NULL)
 *   tick   - Market tick data (must not be NULL)
 *
 * Returns:
 *   HFT_SUCCESS on success
 *   HFT_INVALID_HANDLE if engine is NULL
 *   HFT_INVALID_SYMBOL if symbol is empty or too long (>32)
 *   HFT_PROCESS_TICK_FAILED on processing error
 *
 * Performance:
 *   Sub-microsecond processing time
 *   290,000+ ticks/second throughput
 *
 * Example:
 *   HFT_MarketTick tick = {
 *       .symbol_ptr = (const uint8_t*)"BTCUSD",
 *       .symbol_len = 6,
 *       .bid_value = 50000000000,  // $50,000.00
 *       .ask_value = 50001000000,  // $50,001.00
 *       ...
 *   };
 *   HFT_Error err = hft_process_tick(engine, &tick);
 */
HFT_Error hft_process_tick(HFT_Engine* engine, const HFT_MarketTick* tick);

/* ============================================================================
 * Signal Retrieval
 * ============================================================================ */

/**
 * Get the next trading signal (non-blocking).
 *
 * Parameters:
 *   engine     - Engine handle (must not be NULL)
 *   signal_out - Output signal (must not be NULL)
 *
 * Returns:
 *   HFT_SUCCESS if signal retrieved
 *   HFT_QUEUE_EMPTY if no signals available
 *   HFT_INVALID_HANDLE if engine is NULL
 *
 * Note:
 *   This is a non-blocking call. Returns immediately if queue is empty.
 *   Signal queue is lock-free for minimal latency.
 *
 * Example:
 *   HFT_Signal signal;
 *   while (hft_get_signal(engine, &signal) == HFT_SUCCESS) {
 *       // Process signal
 *   }
 */
HFT_Error hft_get_signal(HFT_Engine* engine, HFT_Signal* signal_out);

/**
 * Push a signal to the queue (for strategy → execution bridge).
 *
 * Parameters:
 *   engine - Engine handle (must not be NULL)
 *   signal - Signal to push (must not be NULL)
 *
 * Returns:
 *   HFT_SUCCESS if signal pushed
 *   HFT_QUEUE_FULL if queue is at capacity
 *   HFT_INVALID_HANDLE if engine is NULL
 *
 * Note:
 *   Queue capacity is 1024 signals.
 *   This is typically used by strategy modules to send signals to execution.
 */
HFT_Error hft_push_signal(HFT_Engine* engine, const HFT_Signal* signal);

/* ============================================================================
 * Statistics
 * ============================================================================ */

/**
 * Get engine performance statistics.
 *
 * Parameters:
 *   engine    - Engine handle (must not be NULL)
 *   stats_out - Output statistics (must not be NULL)
 *
 * Returns:
 *   HFT_SUCCESS on success
 *   HFT_INVALID_HANDLE if engine is NULL
 *
 * Note:
 *   Statistics are updated in real-time during operation.
 *
 * Example:
 *   HFT_Stats stats;
 *   hft_get_stats(engine, &stats);
 *   printf("Ticks: %lu, Latency: %lu µs\n",
 *          stats.ticks_processed, stats.avg_latency_us);
 */
HFT_Error hft_get_stats(const HFT_Engine* engine, HFT_Stats* stats_out);

/* ============================================================================
 * Error Handling
 * ============================================================================ */

/**
 * Get human-readable error string.
 *
 * Parameters:
 *   error_code - Error code from any function
 *
 * Returns:
 *   Null-terminated error string (always valid, never NULL)
 *
 * Note:
 *   Returned string is static and must not be freed.
 *
 * Example:
 *   HFT_Error err = hft_process_tick(engine, &tick);
 *   if (err != HFT_SUCCESS) {
 *       fprintf(stderr, "Error: %s\n", hft_error_string(err));
 *   }
 */
const char* hft_error_string(HFT_Error error_code);

/**
 * Get library version string.
 *
 * Returns:
 *   Null-terminated version string (e.g., "1.0.0-forge")
 */
const char* hft_version(void);

/* ============================================================================
 * Backward Compatibility (Deprecated)
 * ============================================================================
 *
 * These functions maintain compatibility with existing Go bridge code.
 * New code should use the handle-based API above.
 * ============================================================================ */

/**
 * Initialize global legacy engine instance.
 *
 * @deprecated Use hft_engine_create() instead.
 *
 * Returns: 0 on success, negative error code on failure.
 */
int hft_init(void);

/**
 * Process tick with legacy global engine.
 *
 * @deprecated Use hft_process_tick() with handle instead.
 */
int hft_process_tick_legacy(const HFT_MarketTick* tick);

/**
 * Get next signal from legacy global engine.
 *
 * @deprecated Use hft_get_signal() with handle instead.
 *
 * Returns: 1 if signal retrieved, 0 if queue empty, negative on error.
 */
int hft_get_next_signal(HFT_Signal* signal_out);

/**
 * Get stats from legacy global engine.
 *
 * @deprecated Use hft_get_stats() with handle instead.
 */
int hft_get_stats_legacy(HFT_Stats* stats_out);

/**
 * Cleanup legacy global engine.
 *
 * @deprecated Use hft_engine_destroy() with handle instead.
 */
void hft_cleanup(void);

#ifdef __cplusplus
}
#endif

#endif /* FINANCIAL_ENGINE_H */
