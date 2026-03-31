# Zig 0.16.0-dev.1303 Quick Reference

Fast lookup for common API changes when migrating from earlier Zig 0.16 versions.

---

## Build System

```zig
// OLD
const exe = b.addExecutable(.{
    .name = "app",
    .root = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});

// NEW
const exe = b.addExecutable(.{
    .name = "app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

---

## Time Functions

### Get Current Unix Timestamp (seconds)

```zig
// OLD
const now = std.time.timestamp();

// NEW
const now = @as(i64, @intCast((std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable).sec));
```

### Get Milliseconds

```zig
// OLD
const now_ms = std.time.milliTimestamp();

// NEW
const now_ms = blk: {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
    break :blk @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(ts.nsec, 1_000_000);
};
```

### Get Nanoseconds

```zig
// OLD
const now_ns = std.time.nanoTimestamp();

// NEW
const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
const now_ns = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
```

---

## ArrayList

### Initialize

```zig
// OLD
.items_list = std.ArrayList(T){
    .items = &.{},
    .capacity = 0,
    .allocator = allocator,
},

// NEW
.items_list = .{},
```

### Deinit

```zig
// OLD
self.items_list.deinit();

// NEW
self.items_list.deinit(self.allocator);
```

### Append

```zig
// OLD
try self.items_list.append(item);

// NEW
try self.items_list.append(self.allocator, item);
```

---

## File Operations

### File Reader

```zig
// OLD
var file_reader = file.reader();

// NEW
var threaded: std.Io.Threaded = .init_single_threaded;
const io = threaded.ioBasic();
var buffer: [8192]u8 = undefined;
var file_reader = file.reader(io, &buffer);
```

---

## HTTP Client

```zig
// OLD
const client = http.Client{ .allocator = allocator };

// NEW
const HttpClient = struct {
    client: http.Client,
    threaded: std.Io.Threaded,

    pub fn init(allocator: std.mem.Allocator) HttpClient {
        var threaded: std.Io.Threaded = .init_single_threaded;
        return .{
            .client = http.Client{ .allocator = allocator, .io = threaded.io() },
            .threaded = threaded,
        };
    }
};
```

---

## Type Annotations

### @intCast

```zig
// OLD
const value = @intCast(some_int);

// NEW
const value = @as(i64, @intCast(some_int));
```

### Anonymous Types

```zig
// OLD (error)
const pos_side = Position.side;

// NEW
const pos_side = @TypeOf(@as(Position, undefined).side);
```

---

## Common Patterns

### Timestamp in Struct Initialization

```zig
const order = Order{
    .id = 123,
    .timestamp = @as(i64, @intCast((std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable).sec)),
    // ...
};
```

### Performance Timing

```zig
const start_ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
const start = @as(i128, start_ts.sec) * 1_000_000_000 + start_ts.nsec;

// ... do work ...

const end_ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
const end = @as(i128, end_ts.sec) * 1_000_000_000 + end_ts.nsec;
const elapsed_ns = end - start;
```

---

## DWARF Bug Workaround

If you get "missing dwarf relocation target" panic with system libraries:

```zig
// Force release mode for specific executable
const workaround_optimize = if (optimize == .Debug) .ReleaseFast else optimize;
const exe = b.addExecutable(.{
    .name = "my-app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = workaround_optimize,  // Use this instead of optimize
    }),
});
```

---

## Search & Replace Regex

For bulk migrations, these patterns can help:

```bash
# timestamp() calls
OLD: std\.time\.timestamp\(\)
NEW: @as(i64, @intCast((std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable).sec))

# ArrayList initialization
OLD: std\.ArrayList\([^)]+\)\s*{\s*\.items\s*=\s*&\.\{\},\s*\.capacity\s*=\s*0,\s*\.allocator\s*=\s*[^,]+,\s*}
NEW: .{}

# ArrayList deinit
OLD: \.deinit\(\);
SEARCH: self\.([a-z_]+)\.deinit\(\);
REPLACE: self.\1.deinit(self.allocator);

# ArrayList append
SEARCH: \.append\(([^)]+)\)
REPLACE: .append(self.allocator, \1)
```

---

## Zig Version Check

```bash
zig version
# Should output: 0.16.0-dev.1303+ee0a0f119
```

---

## Common Errors

### "no field named 'root'"
- Change `.root` to `.root_module` with `b.createModule()`

### "struct 'time' has no member named 'timestamp'"
- Replace with `clock_gettime()` pattern

### "@intCast must have a known result type"
- Add `@as(type, @intCast(...))` wrapper

### "missing dwarf relocation target"
- Apply DWARF workaround (force release mode)

### "member function expected 2 argument(s), found 1"
- ArrayList methods now need allocator parameter

### "missing struct field: io"
- Add Io.Threaded for http.Client

---

## Quick Test Commands

```bash
# Clean build
rm -rf zig-cache zig-out && zig build

# Build specific target
zig build-exe src/main.zig

# Run tests
zig build test

# Check dependencies
ldd zig-out/bin/my-app
```

---

Generated: 2025-11-23
Zig Version: 0.16.0-dev.1303+ee0a0f119
