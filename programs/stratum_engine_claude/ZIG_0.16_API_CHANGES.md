# Zig 0.16 API Changes Reference

This document details the breaking API changes encountered when working with Zig 0.16.0-dev.1484+ compared to earlier versions. Created to assist future development on this codebase.

## Build Environment

- **Zig Version**: 0.16.0-dev.1484+d0ba6642b
- **Patched Zig Location**: `/home/founder/Downloads/zig-0.16-patched`
- **System Zig Location**: `/usr/local/zig`

---

## 1. ArrayList API Changes

### Old API (Zig 0.13 and earlier)
```zig
var list = std.ArrayList(T).init(allocator);
defer list.deinit();

try list.append(item);
try list.appendSlice(slice);
try list.insert(index, item);
const slice = list.toOwnedSlice();
```

### New API (Zig 0.16+)
```zig
// init() removed for some types - use initCapacity instead
var list = try std.ArrayList(T).initCapacity(allocator, initial_capacity);
defer list.deinit(allocator);  // allocator now required

try list.append(allocator, item);  // allocator required
try list.appendSlice(allocator, slice);  // allocator required
try list.insert(allocator, index, item);  // allocator required
const slice = try list.toOwnedSlice(allocator);  // allocator required, returns error
```

### Key Differences
- `init(allocator)` → `initCapacity(allocator, capacity)` for some element types
- `deinit()` → `deinit(allocator)`
- `append(item)` → `append(allocator, item)`
- `appendSlice(slice)` → `appendSlice(allocator, slice)`
- `insert(index, item)` → `insert(allocator, index, item)`
- `toOwnedSlice()` → `toOwnedSlice(allocator)` (now returns error union)

---

## 2. Time API Changes

### Old API
```zig
const timestamp = std.time.timestamp();  // Returns i64 Unix timestamp
std.time.sleep(nanoseconds);
```

### New API (Zig 0.16+)
```zig
// std.time.timestamp() REMOVED
// std.time.sleep() REMOVED

// Use C library directly:
var ts: std.posix.timespec = undefined;
_ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
const timestamp: i64 = ts.sec;

// For sleep, use posix.nanosleep:
std.posix.nanosleep(seconds, nanoseconds);
```

### Compatibility Helper (src/utils/compat.zig)
```zig
const std = @import("std");
const posix = std.posix;

pub fn timestamp() i64 {
    var ts: posix.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return ts.sec;
}

pub fn timestampMs() i64 {
    var ts: posix.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}
```

---

## 3. IO/Stream API Changes

### Old API
```zig
var stream = std.io.fixedBufferStream(buffer);
const writer = stream.writer();
try writer.writeAll("data");
return stream.getWritten();
```

### New API (Zig 0.16+)
```zig
// std.io module restructured to std.Io (capital I)
// fixedBufferStream removed

// Alternative 1: Use std.fmt.bufPrint directly
const result = try std.fmt.bufPrint(buffer, "format {}", .{args});

// Alternative 2: Custom buffer writer
pub const BufferWriter = struct {
    buffer: []u8,
    pos: usize,

    pub fn init(buffer: []u8) BufferWriter {
        return .{ .buffer = buffer, .pos = 0 };
    }

    pub fn write(self: *BufferWriter, data: []const u8) !void {
        if (self.pos + data.len > self.buffer.len) return error.NoSpaceLeft;
        @memcpy(self.buffer[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    pub fn getWritten(self: *const BufferWriter) []const u8 {
        return self.buffer[0..self.pos];
    }
};
```

---

## 4. Signal Handling Changes

### Old API
```zig
fn sigHandler(_: c_int) callconv(.C) void {
    // handle signal
}

const sigaction = posix.Sigaction{
    .handler = .{ .handler = sigHandler },
    .mask = posix.empty_sigset,
    .flags = 0,
};
try posix.sigaction(posix.SIG.INT, &sigaction, null);
```

### New API (Zig 0.16+)
```zig
// callconv(.C) → callconv(.c) (lowercase)
// posix.empty_sigset → posix.sigemptyset()
// posix.SIG.INT → .INT (enum inference)
// sigaction() no longer returns error

fn sigHandler(_: posix.SIG) callconv(.c) void {
    // handle signal
}

const sigaction = posix.Sigaction{
    .handler = .{ .handler = sigHandler },
    .mask = posix.sigemptyset(),
    .flags = 0,
};
posix.sigaction(.INT, &sigaction, null);  // no try needed
posix.sigaction(.TERM, &sigaction, null);
```

---

## 5. CallingConvention Changes

### Old API
```zig
fn callback() callconv(.C) void {}
```

### New API (Zig 0.16+)
```zig
fn callback() callconv(.c) void {}  // lowercase 'c'
```

---

## 6. Thread Spawn Changes

### Old API
```zig
const thread = try std.Thread.spawn(.{}, function, .{arg});
```

### New API (Zig 0.16+)
```zig
// If function expects a pointer, you must pass a pointer
fn threadFn(ptr: *MyStruct) void { ... }

// WRONG: Passing value when function expects pointer
const thread = try std.Thread.spawn(.{}, threadFn, .{my_struct});

// CORRECT: Pass address
const thread = try std.Thread.spawn(.{}, threadFn, .{&my_struct});
```

---

## 7. HashMaps

### Old API
```zig
var map = std.StringHashMap(V).init(allocator);
defer map.deinit();
```

### New API (Zig 0.16+)
```zig
// Same, but some operations may need allocator
var map = std.StringHashMap(V).init(allocator);
defer map.deinit();  // deinit still works without allocator for HashMap
```

---

## 8. Atomic Operations

### Mostly Unchanged
```zig
var atomic = std.atomic.Value(bool).init(true);
atomic.store(false, .release);
const val = atomic.load(.acquire);
```

---

## 9. Format Specifiers

### Unchanged but Note
```zig
// For hex formatting with padding, use:
std.fmt.bufPrint(buf, "{x:0>8}", .{value})  // 8 hex chars, zero-padded

// For formatting integers as hex from byte arrays:
@as(u256, @bitCast(byte_array))  // Ensure sizes match exactly
```

---

## Migration Checklist

When porting code to Zig 0.16+:

1. [ ] Replace `ArrayList.init()` with `ArrayList.initCapacity()`
2. [ ] Add allocator parameter to all ArrayList methods
3. [ ] Replace `std.time.timestamp()` with C clock_gettime
4. [ ] Replace `std.time.sleep()` with `posix.nanosleep()`
5. [ ] Replace `std.io.fixedBufferStream()` with `std.fmt.bufPrint()`
6. [ ] Change `callconv(.C)` to `callconv(.c)`
7. [ ] Change signal handler parameter from `c_int` to `posix.SIG`
8. [ ] Replace `posix.empty_sigset` with `posix.sigemptyset()`
9. [ ] Remove `try` from `posix.sigaction()` calls
10. [ ] Verify Thread.spawn passes pointers when functions expect pointers

---

## Files Modified for Zig 0.16 Compatibility

- `src/proxy/server.zig` - ArrayList, timestamp
- `src/proxy/miner_registry.zig` - ArrayList, timestamp
- `src/proxy/pool_manager.zig` - ArrayList, timestamp
- `src/proxy/websocket.zig` - ArrayList, timestamp, buffer streams
- `src/storage/sqlite.zig` - ArrayList
- `src/main_proxy.zig` - Signal handling, sleep, thread spawn
- `src/utils/compat.zig` - NEW: Compatibility helpers

---

## Reference Links

- Zig Standard Library: `/usr/local/zig/lib/std/`
- Patched Zig: `/home/founder/Downloads/zig-0.16-patched/lib/std/`
