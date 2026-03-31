/**
 * zig_code_query.h — C API for Zig Code Query Library
 *
 * Query SurrealDB code knowledge bases (Zig stdlib call graphs)
 * and ingest files/folders for agent-accessible knowledge retrieval.
 *
 * Build: zig build -Dlib       (shared library)
 *        zig build -Dlib -Dstatic (static library)
 */

#ifndef ZIG_CODE_QUERY_H
#define ZIG_CODE_QUERY_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * Error Codes
 * ========================================================================= */

#define ZCQ_SUCCESS          0
#define ZCQ_INVALID_ARGUMENT 1
#define ZCQ_OUT_OF_MEMORY    2
#define ZCQ_NETWORK_ERROR    3
#define ZCQ_QUERY_ERROR      4
#define ZCQ_PARSE_ERROR      5
#define ZCQ_IO_ERROR         6
#define ZCQ_NOT_FOUND        7
#define ZCQ_UNKNOWN_ERROR   -1

/* ============================================================================
 * Types
 * ========================================================================= */

/** Opaque handle to a CodeQuery instance. */
typedef struct ZcqHandle ZcqHandle;

/** Length-prefixed string (may not be null-terminated internally). */
typedef struct {
    const char* ptr;
    size_t      len;
} ZcqString;

/** Configuration for connecting to SurrealDB. */
typedef struct {
    ZcqString url;    /**< SurrealDB SQL endpoint (default: http://127.0.0.1:8000/sql) */
    ZcqString auth;   /**< Authorization header value (default: Basic cm9vdDpyb290) */
    ZcqString ns;     /**< Namespace (default: zig) */
    ZcqString db;     /**< Database (default: stdlib_016) */
} ZcqConfig;

/** Options for file/folder ingestion. */
typedef struct {
    uint32_t chunk_size;        /**< Characters per chunk (default: 4096) */
    uint32_t overlap;           /**< Overlap between chunks (default: 256) */
    bool     recursive;         /**< Recurse into subdirectories (default: true) */
    const ZcqString* extensions;     /**< Optional file extension filter */
    uint32_t extensions_count;  /**< Number of extensions in filter */
} ZcqIngestOptions;

/** Result of an ingestion operation. */
typedef struct {
    uint32_t  documents_created;
    uint32_t  chunks_created;
    uint32_t  documents_skipped;
    uint32_t  errors;
    bool      success;
    int32_t   error_code;
    ZcqString error_message;
} ZcqIngestResult;

/** Database statistics. */
typedef struct {
    int64_t   function_count;
    int64_t   edge_count;
    int64_t   document_count;
    int64_t   chunk_count;
    bool      success;
    int32_t   error_code;
    ZcqString error_message;
} ZcqStatsResult;

/** Generic query result (JSON payload). */
typedef struct {
    ZcqString json_data;    /**< JSON array of results */
    uint32_t  total_count;
    bool      success;
    int32_t   error_code;
    ZcqString error_message;
} ZcqQueryResult;

/** Document list result. */
typedef struct {
    ZcqString json_data;    /**< JSON array of document objects */
    uint32_t  count;
    bool      success;
    int32_t   error_code;
    ZcqString error_message;
} ZcqDocumentList;

/** Raw string result. */
typedef struct {
    ZcqString value;
    bool      success;
    int32_t   error_code;
    ZcqString error_message;
} ZcqStringResult;

/* ============================================================================
 * Lifecycle
 * ========================================================================= */

/**
 * Create a new CodeQuery handle.
 * @param config  Configuration (NULL for defaults).
 * @return Handle, or NULL on failure.
 */
ZcqHandle* zcq_init(const ZcqConfig* config);

/**
 * Destroy a CodeQuery handle and free all resources.
 * @param handle  Handle to destroy (NULL-safe).
 */
void zcq_deinit(ZcqHandle* handle);

/* ============================================================================
 * Ingestion
 * ========================================================================= */

/**
 * Ingest a single file into the knowledge base.
 * @param handle  CodeQuery handle.
 * @param path    File path.
 * @param opts    Ingestion options (NULL for defaults).
 * @param result  Output result struct.
 */
void zcq_ingest_file(ZcqHandle* handle, ZcqString path,
                     const ZcqIngestOptions* opts, ZcqIngestResult* result);

/**
 * Ingest all files in a folder (optionally recursive).
 * @param handle  CodeQuery handle.
 * @param path    Folder path.
 * @param opts    Ingestion options (NULL for defaults).
 * @param result  Output result struct.
 */
void zcq_ingest_folder(ZcqHandle* handle, ZcqString path,
                       const ZcqIngestOptions* opts, ZcqIngestResult* result);

/**
 * Remove a document and its chunks by path.
 * @param handle  CodeQuery handle.
 * @param path    Document path.
 * @return ZCQ_SUCCESS or error code.
 */
int32_t zcq_remove_document(ZcqHandle* handle, ZcqString path);

/**
 * List all ingested documents.
 * @param handle  CodeQuery handle.
 * @param result  Output document list (call zcq_free_document_list when done).
 */
void zcq_list_documents(ZcqHandle* handle, ZcqDocumentList* result);

/* ============================================================================
 * Queries
 * ========================================================================= */

/**
 * Search functions by name.
 * @param handle  CodeQuery handle.
 * @param term    Search term.
 * @param result  Output result (call zcq_free_result when done).
 */
void zcq_find(ZcqHandle* handle, ZcqString term, ZcqQueryResult* result);

/**
 * Search across ingested knowledge chunks.
 * @param handle  CodeQuery handle.
 * @param term    Search term.
 * @param result  Output result (call zcq_free_result when done).
 */
void zcq_search_chunks(ZcqHandle* handle, ZcqString term, ZcqQueryResult* result);

/**
 * Execute a raw SQL query against SurrealDB.
 * @param handle  CodeQuery handle.
 * @param sql     SQL query string.
 * @param result  Output result (call zcq_free_string_result when done).
 */
void zcq_raw_query(ZcqHandle* handle, ZcqString sql, ZcqStringResult* result);

/**
 * Get database statistics.
 * @param handle  CodeQuery handle.
 * @param result  Output stats result.
 */
void zcq_stats(ZcqHandle* handle, ZcqStatsResult* result);

/* ============================================================================
 * Memory Management
 * ========================================================================= */

/** Free a query result's allocated memory. */
void zcq_free_result(ZcqQueryResult* result);

/** Free a document list's allocated memory. */
void zcq_free_document_list(ZcqDocumentList* result);

/** Free a string result's allocated memory. */
void zcq_free_string_result(ZcqStringResult* result);

/** Free a single string allocated by the library. */
void zcq_free_string(ZcqString s);

#ifdef __cplusplus
}
#endif

#endif /* ZIG_CODE_QUERY_H */
