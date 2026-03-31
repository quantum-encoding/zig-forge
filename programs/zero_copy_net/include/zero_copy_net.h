/**
 * Zero-Copy Network Stack - C FFI Header
 *
 * Ultra-low-latency TCP networking with io_uring
 *
 * Performance:
 * - <10ns buffer allocation
 * - <1µs io_uring syscall overhead
 * - <2µs TCP echo RTT
 * - 10M+ msgs/sec throughput
 *
 * Thread Safety:
 * - ZCN_Server is NOT thread-safe
 * - All operations must be called from the same thread
 * - Callbacks invoked on same thread as zcn_server_run_once()
 *
 * Example Usage:
 *
 * ```c
 * ZCN_Config config = {
 *     .address = "127.0.0.1",
 *     .port = 8080,
 *     .io_uring_entries = 256,
 *     .buffer_pool_size = 1024,
 *     .buffer_size = 4096,
 * };
 *
 * ZCN_Error err;
 * ZCN_Server* server = zcn_server_create(&config, &err);
 * if (!server) {
 *     fprintf(stderr, "Failed: %s\n", zcn_error_string(err));
 *     return 1;
 * }
 *
 * zcn_server_set_callbacks(server, my_context, on_accept, on_data, on_close);
 * zcn_server_start(server);
 *
 * while (running) {
 *     zcn_server_run_once(server);
 * }
 *
 * zcn_server_destroy(server);
 * ```
 */

#ifndef ZERO_COPY_NET_H
#define ZERO_COPY_NET_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>
#include <stdint.h>

/* ============================================================================
 * Types
 * ============================================================================ */

/**
 * Opaque server handle
 */
typedef struct ZCN_Server ZCN_Server;

/**
 * Configuration for server creation
 */
typedef struct {
    const char* address;      /* Bind address (e.g., "127.0.0.1" or "0.0.0.0") */
    uint16_t port;            /* Port to listen on */
    uint32_t io_uring_entries;/* io_uring queue depth (e.g., 256) */
    uint32_t buffer_pool_size;/* Number of buffers to pre-allocate */
    uint32_t buffer_size;     /* Size of each buffer in bytes (e.g., 4096) */
} ZCN_Config;

/**
 * Error codes
 */
typedef enum {
    ZCN_SUCCESS = 0,                /* Operation succeeded */
    ZCN_ERROR_INVALID_CONFIG = -1,  /* Invalid configuration parameters */
    ZCN_ERROR_OUT_OF_MEMORY = -2,   /* Memory allocation failed */
    ZCN_ERROR_IO_URING_INIT = -3,   /* Failed to initialize io_uring */
    ZCN_ERROR_BIND_FAILED = -4,     /* Failed to bind to address */
    ZCN_ERROR_LISTEN_FAILED = -5,   /* Failed to listen on socket */
    ZCN_ERROR_INVALID_HANDLE = -6,  /* Invalid server handle (NULL) */
    ZCN_ERROR_CONNECTION_NOT_FOUND = -7, /* Connection not found */
    ZCN_ERROR_NO_BUFFER = -8,       /* No buffer available in pool */
    ZCN_ERROR_SEND_FAILED = -9,     /* Send operation failed */
} ZCN_Error;

/**
 * Statistics
 */
typedef struct {
    size_t total_buffers;      /* Total buffers in pool */
    size_t buffers_in_use;     /* Buffers currently in use */
    size_t buffers_free;       /* Buffers available */
    size_t connections_active; /* Active connections */
} ZCN_Stats;

/**
 * Callback invoked when a new connection is accepted
 *
 * @param user_data Opaque pointer passed to zcn_server_set_callbacks
 * @param fd        File descriptor of the new connection
 *
 * Thread: Called on same thread as zcn_server_run_once()
 */
typedef void (*ZCN_OnAccept)(void* user_data, int fd);

/**
 * Callback invoked when data is received from a connection
 *
 * @param user_data Opaque pointer passed to zcn_server_set_callbacks
 * @param fd        File descriptor of the connection
 * @param data      Pointer to received data (VALID ONLY DURING CALLBACK)
 * @param len       Length of received data in bytes
 *
 * IMPORTANT: The data pointer is only valid during the callback.
 *            If you need the data after the callback returns, you MUST copy it.
 *
 * Thread: Called on same thread as zcn_server_run_once()
 */
typedef void (*ZCN_OnData)(void* user_data, int fd, const uint8_t* data, size_t len);

/**
 * Callback invoked when a connection is closed
 *
 * @param user_data Opaque pointer passed to zcn_server_set_callbacks
 * @param fd        File descriptor of the closed connection
 *
 * Thread: Called on same thread as zcn_server_run_once()
 */
typedef void (*ZCN_OnClose)(void* user_data, int fd);

/* ============================================================================
 * Functions
 * ============================================================================ */

/**
 * Create a new TCP server
 *
 * @param config    Configuration (must not be NULL)
 * @param out_error Optional: receives error code on failure (can be NULL)
 * @return          Server handle on success, NULL on failure
 *
 * Example:
 * ```c
 * ZCN_Config config = {
 *     .address = "127.0.0.1",
 *     .port = 8080,
 *     .io_uring_entries = 256,
 *     .buffer_pool_size = 1024,
 *     .buffer_size = 4096,
 * };
 *
 * ZCN_Error err;
 * ZCN_Server* server = zcn_server_create(&config, &err);
 * if (!server) {
 *     fprintf(stderr, "Error: %s\n", zcn_error_string(err));
 * }
 * ```
 */
ZCN_Server* zcn_server_create(const ZCN_Config* config, ZCN_Error* out_error);

/**
 * Destroy server and free all resources
 *
 * @param server Server handle (can be NULL, no-op)
 *
 * Thread: Must be called from the same thread that created the server
 */
void zcn_server_destroy(ZCN_Server* server);

/**
 * Set callback functions
 *
 * @param server    Server handle (must not be NULL)
 * @param user_data Opaque pointer passed to all callbacks (can be NULL)
 * @param on_accept Callback for new connections (can be NULL)
 * @param on_data   Callback for received data (can be NULL)
 * @param on_close  Callback for closed connections (can be NULL)
 *
 * Thread: Must be called from the same thread that created the server
 *
 * Example:
 * ```c
 * struct MyContext {
 *     // Your state here
 * };
 *
 * void on_data_handler(void* user_data, int fd, const uint8_t* data, size_t len) {
 *     struct MyContext* ctx = (struct MyContext*)user_data;
 *     // Process data
 * }
 *
 * struct MyContext ctx = { ... };
 * zcn_server_set_callbacks(server, &ctx, NULL, on_data_handler, NULL);
 * ```
 */
void zcn_server_set_callbacks(
    ZCN_Server* server,
    void* user_data,
    ZCN_OnAccept on_accept,
    ZCN_OnData on_data,
    ZCN_OnClose on_close
);

/**
 * Start accepting connections
 *
 * @param server Server handle (must not be NULL)
 * @return       ZCN_SUCCESS on success, error code on failure
 *
 * Must be called before zcn_server_run_once()
 *
 * Thread: Must be called from the same thread that created the server
 */
ZCN_Error zcn_server_start(ZCN_Server* server);

/**
 * Run event loop once (poll for events)
 *
 * @param server Server handle (must not be NULL)
 * @return       ZCN_SUCCESS on success, error code on failure
 *
 * This function:
 * 1. Waits for one io_uring event
 * 2. Processes the event (accept, recv, send completion)
 * 3. Invokes appropriate callbacks
 * 4. Returns
 *
 * Call this in a loop from your event loop:
 *
 * ```c
 * while (running) {
 *     ZCN_Error err = zcn_server_run_once(server);
 *     if (err != ZCN_SUCCESS) {
 *         // Handle error
 *     }
 * }
 * ```
 *
 * Thread: Must be called from the same thread that created the server
 */
ZCN_Error zcn_server_run_once(ZCN_Server* server);

/**
 * Send data to a connection
 *
 * @param server Server handle (must not be NULL)
 * @param fd     File descriptor of the connection
 * @param data   Data to send (must not be NULL)
 * @param len    Length of data in bytes
 * @return       ZCN_SUCCESS on success, error code on failure
 *
 * Note: This function copies the data to an internal buffer.
 *
 * Thread: Must be called from the same thread that created the server
 *
 * Example:
 * ```c
 * const char* msg = "Hello, world!";
 * ZCN_Error err = zcn_server_send(server, fd, (const uint8_t*)msg, strlen(msg));
 * if (err != ZCN_SUCCESS) {
 *     fprintf(stderr, "Send failed: %s\n", zcn_error_string(err));
 * }
 * ```
 */
ZCN_Error zcn_server_send(
    ZCN_Server* server,
    int fd,
    const uint8_t* data,
    size_t len
);

/**
 * Get server statistics
 *
 * @param server Server handle (can be NULL, returns zeroed stats)
 * @return       Statistics snapshot
 *
 * Thread: Safe to call from any thread, but returns a snapshot that may be stale
 *
 * Example:
 * ```c
 * ZCN_Stats stats = zcn_server_get_stats(server);
 * printf("Active connections: %zu\n", stats.connections_active);
 * printf("Buffers in use: %zu/%zu\n", stats.buffers_in_use, stats.total_buffers);
 * ```
 */
ZCN_Stats zcn_server_get_stats(const ZCN_Server* server);

/**
 * Get human-readable error string
 *
 * @param error_code Error code
 * @return           Null-terminated error description string
 *
 * Thread: Safe to call from any thread
 *
 * Example:
 * ```c
 * ZCN_Error err = zcn_server_start(server);
 * if (err != ZCN_SUCCESS) {
 *     fprintf(stderr, "Error: %s\n", zcn_error_string(err));
 * }
 * ```
 */
const char* zcn_error_string(ZCN_Error error_code);

#ifdef __cplusplus
}
#endif

#endif /* ZERO_COPY_NET_H */
