/**
 * zig_ingest.h — C API for Zig Ingest Library
 *
 * Parse Zig source files, extract function declarations and call graphs,
 * and insert them into SurrealDB for querying.
 *
 * Build: zig build -Dlib          (shared library)
 *        zig build -Dlib -Dstatic (static library)
 */

#ifndef ZIG_INGEST_H
#define ZIG_INGEST_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * Error Codes
 * ========================================================================= */

#define ZI_SUCCESS          0
#define ZI_INVALID_ARGUMENT 1
#define ZI_OUT_OF_MEMORY    2
#define ZI_NETWORK_ERROR    3
#define ZI_QUERY_ERROR      4
#define ZI_PARSE_ERROR      5
#define ZI_IO_ERROR         6
#define ZI_UNKNOWN_ERROR   -1

/* ============================================================================
 * Types
 * ========================================================================= */

/** Opaque handle to a ZigIngest instance. */
typedef struct ZiHandle ZiHandle;

/** Length-prefixed string (may not be null-terminated internally). */
typedef struct {
    const char* ptr;
    size_t      len;
} ZiString;

/** Configuration for connecting to SurrealDB. */
typedef struct {
    ZiString url;         /**< SurrealDB SQL endpoint (default: http://127.0.0.1:8000/sql) */
    ZiString auth;        /**< Authorization header value (default: Basic cm9vdDpyb290) */
    ZiString ns;          /**< Namespace (default: zig) */
    ZiString db;          /**< Database (default: stdlib_016) */
    ZiString source_dir;  /**< Source directory to ingest */
    bool     dry_run;     /**< Parse only, don't insert to DB */
    bool     verbose;     /**< Show detailed progress */
} ZiConfig;

/** Result of an ingestion operation. */
typedef struct {
    uint32_t  files_processed;
    uint32_t  functions_found;
    uint32_t  calls_found;
    uint32_t  parse_errors;
    uint32_t  insert_errors;
    uint32_t  functions_inserted;
    uint32_t  calls_inserted;
    bool      success;
    int32_t   error_code;
    ZiString  error_message;
} ZiIngestResult;

/** Ingestion statistics (subset of IngestResult). */
typedef struct {
    uint32_t  files_processed;
    uint32_t  functions_found;
    uint32_t  calls_found;
    uint32_t  parse_errors;
    uint32_t  insert_errors;
} ZiIngestStats;

/** Raw string result (for raw queries). */
typedef struct {
    ZiString  value;
    bool      success;
    int32_t   error_code;
    ZiString  error_message;
} ZiStringResult;

/* ============================================================================
 * Lifecycle
 * ========================================================================= */

/**
 * Create a new ZigIngest handle.
 * @param config  Configuration (NULL for defaults).
 * @return Handle, or NULL on failure.
 */
ZiHandle* zi_init(const ZiConfig* config);

/**
 * Destroy a ZigIngest handle and free all resources.
 * @param handle  Handle to destroy (NULL-safe).
 */
void zi_deinit(ZiHandle* handle);

/* ============================================================================
 * Ingestion
 * ========================================================================= */

/**
 * Ingest all .zig files in a directory tree into SurrealDB.
 * Parses AST, extracts functions and call graphs, inserts into DB.
 *
 * @param handle      ZigIngest handle.
 * @param source_dir  Directory path containing .zig files.
 * @param result      Output result struct (call zi_free_result when done).
 */
void zi_ingest_directory(ZiHandle* handle, ZiString source_dir,
                         ZiIngestResult* result);

/* ============================================================================
 * Queries
 * ========================================================================= */

/**
 * Execute a raw SQL query against SurrealDB.
 * @param handle  ZigIngest handle.
 * @param sql     SQL query string.
 * @param result  Output result (call zi_free_string_result when done).
 */
void zi_raw_query(ZiHandle* handle, ZiString sql, ZiStringResult* result);

/* ============================================================================
 * Memory Management
 * ========================================================================= */

/** Free an ingestion result's allocated memory. */
void zi_free_result(ZiIngestResult* result);

/** Free a string result's allocated memory. */
void zi_free_string_result(ZiStringResult* result);

/** Free a single string allocated by the library. */
void zi_free_string(ZiString s);

#ifdef __cplusplus
}
#endif

#endif /* ZIG_INGEST_H */
