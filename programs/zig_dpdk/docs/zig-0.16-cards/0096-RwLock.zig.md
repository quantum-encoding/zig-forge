# Migration Card: std.Thread.RwLock

## 1) Concept

This file implements a reader-writer lock (RwLock) for kernel threads, supporting either one exclusive writer or multiple concurrent readers. The implementation automatically selects between three backends based on the compilation target: single-threaded (for deadlock detection in debug mode), pthread-based (when pthreads are available), or a default atomic-based implementation. 

The key design provides a unified interface for thread synchronization where operations either succeed immediately (tryLock variants) or block until the lock is acquired (lock variants). The API is designed to be initialized with default values and requires no explicit initialization function or allocator.

## 2) The 0.11 vs 0.16 Diff

**No Breaking Changes Detected** - This API follows the same patterns in both versions:

- **No Allocator Requirements**: The struct uses default initialization (`RwLock{}`) without requiring an explicit allocator
- **No I/O Interface Changes**: This is a pure synchronization primitive without I/O dependencies
- **No Error Handling Changes**: All operations are either boolean (try variants) or void (blocking variants) with no error returns
- **Consistent API Structure**: Uses direct struct initialization rather than factory functions

The migration pattern remains identical:
```zig
// Both 0.11 and 0.16
var rwl = RwLock{};
rwl.lock();
// ... critical section
rwl.unlock();
```

## 3) The Golden Snippet

```zig
const std = @import("std");
const RwLock = std.Thread.RwLock;

var rwl = RwLock{};
var shared_data: i32 = 0;

// Writer thread
rwl.lock();
defer rwl.unlock();
shared_data += 1;

// Reader thread  
rwl.lockShared();
defer rwl.unlockShared();
const value = shared_data;
```

## 4) Dependencies

- `std.debug.assert` - Runtime assertions
- `std.testing` - Test framework
- `std.Thread.Mutex` - Used by DefaultRwLock implementation
- `std.Thread.Semaphore` - Used by DefaultRwLock implementation  
- `std.c.pthread_rwlock_t` - Pthreads backend (when enabled)
- `std.mem` - Bit manipulation utilities
- `std.math` - Integer constants
- `std.atomic` - Atomic operations (implicitly via @atomic* builtins)

**Note**: This is a stable synchronization primitive with minimal migration impact between 0.11 and 0.16. The API structure and usage patterns remain consistent.