/**
 * Async Scheduler Core - High-Performance C API
 *
 * Work-stealing task scheduler for concurrent execution.
 *
 * Performance:
 * - **10M+ tasks/second** sustained throughput
 * - **<100ns latency** per task spawn
 * - **Work-stealing** for automatic load balancing
 *
 * Features:
 * - Lock-free task queues per worker thread
 * - Work-stealing for load balancing
 * - Automatic CPU count detection
 *
 * ZERO DEPENDENCIES:
 * - No networking
 * - No file I/O
 * - No global state (except scheduler instances)
 *
 * Thread Safety:
 * - Safe to spawn tasks from any thread
 * - Multiple schedulers can coexist
 *
 * Usage Pattern:
 *   // Create scheduler (auto-detect CPUs, 4096 tasks/thread)
 *   AS_Scheduler* sched = as_scheduler_create(0, 4096);
 *   as_scheduler_start(sched);
 *
 *   // Spawn tasks
 *   void my_task(void* ctx) {
 *       printf("Task executed!\n");
 *   }
 *   AS_TaskHandle* task = as_scheduler_spawn(sched, my_task, NULL);
 *
 *   // Wait for completion
 *   as_task_await(task);
 *   as_task_destroy(task);
 *
 *   // Cleanup
 *   as_scheduler_stop(sched);
 *   as_scheduler_destroy(sched);
 */

#ifndef ASYNC_CORE_H
#define ASYNC_CORE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * Opaque Types
 * ============================================================================ */

/**
 * Opaque scheduler handle.
 *
 * Lifetime:
 * - Created with as_scheduler_create()
 * - Started with as_scheduler_start()
 * - Stopped with as_scheduler_stop()
 * - Destroyed with as_scheduler_destroy()
 */
typedef struct AS_Scheduler AS_Scheduler;

/**
 * Opaque task handle.
 *
 * Lifetime:
 * - Created by as_scheduler_spawn()
 * - Destroyed with as_task_destroy()
 */
typedef struct AS_TaskHandle AS_TaskHandle;

/* ============================================================================
 * Core Types
 * ============================================================================ */

/**
 * Task function signature.
 *
 * Parameters:
 *   context - User-provided context pointer (can be NULL)
 */
typedef void (*AS_TaskFunc)(void* context);

/**
 * Task state.
 */
typedef enum {
    AS_TASK_PENDING = 0,     /* Task queued, not started */
    AS_TASK_RUNNING = 1,     /* Task currently executing */
    AS_TASK_COMPLETED = 2,   /* Task finished successfully */
    AS_TASK_FAILED = 3,      /* Task failed */
} AS_TaskState;

/**
 * Error codes.
 */
typedef enum {
    AS_SUCCESS = 0,            /* Operation succeeded */
    AS_OUT_OF_MEMORY = -1,     /* Memory allocation failed */
    AS_INVALID_PARAM = -2,     /* Invalid parameter */
    AS_INVALID_HANDLE = -3,    /* Invalid handle (NULL) */
    AS_TASK_NOT_FOUND = -4,    /* Task not found */
    AS_ALREADY_RUNNING = -5,   /* Scheduler already running */
} AS_Error;

/**
 * Scheduler statistics.
 */
typedef struct {
    size_t thread_count;      /* Number of worker threads */
    uint64_t tasks_spawned;   /* Total tasks spawned */
    uint64_t tasks_completed; /* Total tasks completed */
    size_t tasks_pending;     /* Currently pending tasks */
} AS_Stats;

/* ============================================================================
 * Scheduler Operations
 * ============================================================================ */

/**
 * Create a new async scheduler.
 *
 * Parameters:
 *   thread_count - Number of worker threads (0 = auto-detect CPU count)
 *   queue_size   - Task queue size per thread (power of 2, e.g., 4096)
 *
 * Returns:
 *   Scheduler handle, or NULL on allocation failure
 *
 * Performance:
 *   ~1ms (thread pool initialization)
 *
 * Thread Safety:
 *   Safe to create multiple schedulers
 *
 * Example:
 *   // Auto-detect CPU count, 4096 tasks per thread
 *   AS_Scheduler* sched = as_scheduler_create(0, 4096);
 *   if (!sched) {
 *       fprintf(stderr, "Failed to create scheduler\n");
 *       exit(1);
 *   }
 */
AS_Scheduler* as_scheduler_create(size_t thread_count, size_t queue_size);

/**
 * Destroy scheduler and free resources.
 *
 * Parameters:
 *   scheduler - Scheduler handle (NULL is safe, will be no-op)
 *
 * Note:
 *   Automatically stops worker threads if still running
 *   Waits for pending tasks to complete
 */
void as_scheduler_destroy(AS_Scheduler* scheduler);

/**
 * Start the scheduler's worker threads.
 *
 * Parameters:
 *   scheduler - Scheduler handle (must not be NULL)
 *
 * Returns:
 *   AS_SUCCESS or error code
 *
 * Performance:
 *   ~100µs (thread spawn time)
 *
 * Thread Safety:
 *   Safe to call once per scheduler
 *
 * Example:
 *   AS_Error err = as_scheduler_start(sched);
 *   if (err != AS_SUCCESS) {
 *       fprintf(stderr, "Failed to start: %s\n", as_error_string(err));
 *   }
 */
AS_Error as_scheduler_start(AS_Scheduler* scheduler);

/**
 * Stop the scheduler's worker threads.
 *
 * Parameters:
 *   scheduler - Scheduler handle (must not be NULL)
 *
 * Note:
 *   Graceful shutdown - waits for pending tasks to complete
 *   Safe to call multiple times
 */
void as_scheduler_stop(AS_Scheduler* scheduler);

/**
 * Spawn a task on the scheduler.
 *
 * Parameters:
 *   scheduler - Scheduler handle (must not be NULL)
 *   func      - Task function to execute
 *   context   - User context to pass to function (can be NULL)
 *
 * Returns:
 *   Task handle, or NULL on error
 *
 * Performance:
 *   <100ns per spawn
 *
 * Thread Safety:
 *   Safe to call from any thread
 *
 * Example:
 *   void my_task(void* ctx) {
 *       int* value = (int*)ctx;
 *       printf("Task executed: %d\n", *value);
 *   }
 *
 *   int data = 42;
 *   AS_TaskHandle* task = as_scheduler_spawn(sched, my_task, &data);
 *   if (!task) {
 *       fprintf(stderr, "Failed to spawn task\n");
 *   }
 */
AS_TaskHandle* as_scheduler_spawn(
    AS_Scheduler* scheduler,
    AS_TaskFunc func,
    void* context
);

/**
 * Get scheduler statistics.
 *
 * Parameters:
 *   scheduler - Scheduler handle (must not be NULL)
 *   stats_out - Output statistics
 *
 * Returns:
 *   AS_SUCCESS or AS_INVALID_HANDLE
 *
 * Thread Safety:
 *   Safe to call from any thread
 */
AS_Error as_scheduler_stats(
    const AS_Scheduler* scheduler,
    AS_Stats* stats_out
);

/* ============================================================================
 * Task Operations
 * ============================================================================ */

/**
 * Wait for a task to complete.
 *
 * Parameters:
 *   task - Task handle (must not be NULL)
 *
 * Returns:
 *   AS_SUCCESS or error code
 *
 * Note:
 *   Blocks until task completes
 *   Uses yielding to avoid busy-wait
 *
 * Example:
 *   AS_TaskHandle* task = as_scheduler_spawn(sched, my_func, NULL);
 *   as_task_await(task);  // Block until complete
 *   as_task_destroy(task);
 */
AS_Error as_task_await(AS_TaskHandle* task);

/**
 * Get task state.
 *
 * Parameters:
 *   task - Task handle (must not be NULL)
 *
 * Returns:
 *   Task state or AS_TASK_FAILED if handle is NULL
 *
 * Thread Safety:
 *   Safe to call from any thread
 *
 * Example:
 *   AS_TaskState state = as_task_get_state(task);
 *   if (state == AS_TASK_COMPLETED) {
 *       printf("Task done!\n");
 *   }
 */
AS_TaskState as_task_get_state(const AS_TaskHandle* task);

/**
 * Destroy task handle.
 *
 * Parameters:
 *   task - Task handle (NULL is safe, will be no-op)
 *
 * Note:
 *   Does NOT cancel the task, just frees the handle
 *   Safe to call after task completes
 */
void as_task_destroy(AS_TaskHandle* task);

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
const char* as_error_string(AS_Error error_code);

/**
 * Get library version string.
 *
 * Returns:
 *   Null-terminated version string (e.g., "1.0.0-core")
 */
const char* as_version(void);

/**
 * Get performance info string.
 *
 * Returns:
 *   Null-terminated performance summary
 */
const char* as_performance_info(void);

#ifdef __cplusplus
}
#endif

#endif /* ASYNC_CORE_H */
