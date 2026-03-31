/**
 * Memory Pool Core - High-Performance C API
 *
 * Ultra-fast memory allocators for deterministic allocation.
 *
 * Performance:
 * - **Fixed Pool**: <10ns alloc, <5ns free
 * - **Arena**: <3ns alloc, O(1) reset
 *
 * Features:
 * - O(1) fixed-size allocation
 * - Sequential bump allocation
 * - Zero fragmentation
 *
 * ZERO DEPENDENCIES:
 * - No networking
 * - No file I/O
 * - No global state (except pool instances)
 *
 * Thread Safety:
 * - Each pool/arena must be used from single thread
 * - Multiple pools/arenas can exist on different threads
 *
 * Usage Pattern (Fixed Pool):
 *   // Create pool for 256 objects of 64 bytes
 *   MP_FixedPool* pool = mp_fixed_pool_create(64, 256);
 *
 *   // Allocate objects
 *   void* obj1 = mp_fixed_pool_alloc(pool);
 *   void* obj2 = mp_fixed_pool_alloc(pool);
 *
 *   // Free objects
 *   mp_fixed_pool_free(pool, obj1);
 *   mp_fixed_pool_free(pool, obj2);
 *
 *   // Or reset entire pool
 *   mp_fixed_pool_reset(pool);
 *
 *   // Cleanup
 *   mp_fixed_pool_destroy(pool);
 *
 * Usage Pattern (Arena):
 *   // Create 1MB arena
 *   MP_Arena* arena = mp_arena_create(1024 * 1024);
 *
 *   // Allocate various sizes
 *   void* buf1 = mp_arena_alloc(arena, 1024, 8);
 *   void* buf2 = mp_arena_alloc(arena, 512, 16);
 *
 *   // Reset entire arena (O(1))
 *   mp_arena_reset(arena);
 *
 *   // Cleanup
 *   mp_arena_destroy(arena);
 */

#ifndef MEMORY_POOL_CORE_H
#define MEMORY_POOL_CORE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * Opaque Types
 * ============================================================================ */

/**
 * Opaque fixed pool handle.
 *
 * Lifetime:
 * - Created with mp_fixed_pool_create()
 * - Destroyed with mp_fixed_pool_destroy()
 */
typedef struct MP_FixedPool MP_FixedPool;

/**
 * Opaque arena allocator handle.
 *
 * Lifetime:
 * - Created with mp_arena_create()
 * - Destroyed with mp_arena_destroy()
 */
typedef struct MP_Arena MP_Arena;

/* ============================================================================
 * Core Types
 * ============================================================================ */

/**
 * Error codes.
 */
typedef enum {
    MP_SUCCESS = 0,            /* Operation succeeded */
    MP_OUT_OF_MEMORY = -1,     /* Allocation failed */
    MP_INVALID_PARAM = -2,     /* Invalid parameter */
    MP_INVALID_HANDLE = -3,    /* Invalid handle (NULL) */
} MP_Error;

/**
 * Fixed pool statistics.
 */
typedef struct {
    size_t object_size;        /* Size of each object */
    size_t capacity;           /* Maximum objects */
    size_t allocated;          /* Currently allocated */
    size_t available;          /* Available slots */
} MP_FixedPoolStats;

/**
 * Arena allocator statistics.
 */
typedef struct {
    size_t buffer_size;        /* Total buffer size */
    size_t offset;             /* Current offset */
    size_t available;          /* Available bytes */
} MP_ArenaStats;

/* ============================================================================
 * Fixed Pool Operations
 * ============================================================================ */

/**
 * Create a new fixed-size memory pool.
 *
 * Parameters:
 *   object_size - Size of each object in bytes (must be > 0)
 *   capacity    - Maximum number of objects (must be > 0)
 *
 * Returns:
 *   Pool handle, or NULL on allocation failure
 *
 * Performance:
 *   ~1µs (initial allocation)
 *
 * Thread Safety:
 *   Safe to create multiple pools
 *
 * Example:
 *   // Pool for 256 objects of 64 bytes each
 *   MP_FixedPool* pool = mp_fixed_pool_create(64, 256);
 *   if (!pool) {
 *       fprintf(stderr, "Failed to create pool\n");
 *       exit(1);
 *   }
 */
MP_FixedPool* mp_fixed_pool_create(size_t object_size, size_t capacity);

/**
 * Destroy fixed pool and free resources.
 *
 * Parameters:
 *   pool - Pool handle (NULL is safe, will be no-op)
 *
 * Note:
 *   Does NOT free objects allocated from the pool
 *   Invalidates all object pointers
 */
void mp_fixed_pool_destroy(MP_FixedPool* pool);

/**
 * Allocate an object from the fixed pool.
 *
 * Parameters:
 *   pool - Pool handle (must not be NULL)
 *
 * Returns:
 *   Pointer to object, or NULL if pool is full
 *
 * Performance:
 *   <10ns per allocation
 *
 * Thread Safety:
 *   Safe if pool is used from single thread
 *
 * Example:
 *   void* obj = mp_fixed_pool_alloc(pool);
 *   if (!obj) {
 *       fprintf(stderr, "Pool exhausted\n");
 *   }
 */
void* mp_fixed_pool_alloc(MP_FixedPool* pool);

/**
 * Free an object back to the fixed pool.
 *
 * Parameters:
 *   pool - Pool handle (must not be NULL)
 *   ptr  - Object pointer (must have been allocated from this pool)
 *
 * Performance:
 *   <5ns per free
 *
 * Thread Safety:
 *   Safe if pool is used from single thread
 *
 * Example:
 *   mp_fixed_pool_free(pool, obj);
 */
void mp_fixed_pool_free(MP_FixedPool* pool, void* ptr);

/**
 * Reset the fixed pool (free all objects).
 *
 * Parameters:
 *   pool - Pool handle (must not be NULL)
 *
 * Note:
 *   Invalidates all previously allocated pointers
 *   O(capacity) operation
 *
 * Example:
 *   mp_fixed_pool_reset(pool);
 *   // All previous allocations are now invalid
 */
void mp_fixed_pool_reset(MP_FixedPool* pool);

/**
 * Get fixed pool statistics.
 *
 * Parameters:
 *   pool      - Pool handle (must not be NULL)
 *   stats_out - Output statistics
 *
 * Returns:
 *   MP_SUCCESS or MP_INVALID_HANDLE
 *
 * Thread Safety:
 *   Safe to call from any thread
 *
 * Example:
 *   MP_FixedPoolStats stats;
 *   mp_fixed_pool_stats(pool, &stats);
 *   printf("Allocated: %zu/%zu\n", stats.allocated, stats.capacity);
 */
MP_Error mp_fixed_pool_stats(
    const MP_FixedPool* pool,
    MP_FixedPoolStats* stats_out
);

/* ============================================================================
 * Arena Allocator Operations
 * ============================================================================ */

/**
 * Create a new arena allocator.
 *
 * Parameters:
 *   size - Total buffer size in bytes (must be > 0)
 *
 * Returns:
 *   Arena handle, or NULL on allocation failure
 *
 * Performance:
 *   ~1µs (initial allocation)
 *
 * Thread Safety:
 *   Safe to create multiple arenas
 *
 * Example:
 *   // Arena with 1MB buffer
 *   MP_Arena* arena = mp_arena_create(1024 * 1024);
 *   if (!arena) {
 *       fprintf(stderr, "Failed to create arena\n");
 *       exit(1);
 *   }
 */
MP_Arena* mp_arena_create(size_t size);

/**
 * Destroy arena and free resources.
 *
 * Parameters:
 *   arena - Arena handle (NULL is safe, will be no-op)
 *
 * Note:
 *   Frees all memory allocated from the arena
 */
void mp_arena_destroy(MP_Arena* arena);

/**
 * Allocate memory from the arena.
 *
 * Parameters:
 *   arena     - Arena handle (must not be NULL)
 *   size      - Allocation size in bytes
 *   alignment - Alignment requirement (must be power of 2)
 *
 * Returns:
 *   Pointer to allocated memory, or NULL if arena is full
 *
 * Performance:
 *   <3ns per allocation
 *
 * Thread Safety:
 *   Safe if arena is used from single thread
 *
 * Example:
 *   // Allocate 1KB with 16-byte alignment
 *   void* buf = mp_arena_alloc(arena, 1024, 16);
 *   if (!buf) {
 *       fprintf(stderr, "Arena exhausted\n");
 *   }
 */
void* mp_arena_alloc(MP_Arena* arena, size_t size, size_t alignment);

/**
 * Reset the arena (free all allocations).
 *
 * Parameters:
 *   arena - Arena handle (must not be NULL)
 *
 * Note:
 *   Invalidates all previously allocated pointers
 *   O(1) operation
 *
 * Example:
 *   mp_arena_reset(arena);
 *   // All previous allocations are now invalid
 */
void mp_arena_reset(MP_Arena* arena);

/**
 * Get arena statistics.
 *
 * Parameters:
 *   arena     - Arena handle (must not be NULL)
 *   stats_out - Output statistics
 *
 * Returns:
 *   MP_SUCCESS or MP_INVALID_HANDLE
 *
 * Thread Safety:
 *   Safe to call from any thread
 *
 * Example:
 *   MP_ArenaStats stats;
 *   mp_arena_stats(arena, &stats);
 *   printf("Used: %zu/%zu bytes\n", stats.offset, stats.buffer_size);
 */
MP_Error mp_arena_stats(
    const MP_Arena* arena,
    MP_ArenaStats* stats_out
);

/* ============================================================================
 * Utility Functions
 * ============================================================================ */

/**
 * Get human-readable error string.
 *
 * Parameters:
 *   error_code - Error code from any function
 *
 * Returns:
 *   Null-terminated error string (always valid, never NULL)
 */
const char* mp_error_string(MP_Error error_code);

/**
 * Get library version string.
 *
 * Returns:
 *   Null-terminated version string (e.g., "1.0.0-core")
 */
const char* mp_version(void);

/**
 * Get performance info string.
 *
 * Returns:
 *   Null-terminated performance summary
 */
const char* mp_performance_info(void);

#ifdef __cplusplus
}
#endif

#endif /* MEMORY_POOL_CORE_H */
