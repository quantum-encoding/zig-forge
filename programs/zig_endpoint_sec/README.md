# zig_endpoint_sec

Zig client library for Apple's EndpointSecurity framework: create clients, subscribe to AUTH and NOTIFY events, read every event payload the macOS 27 SDK defines, answer AUTH events before their deadline, and mute by process or path.

The bindings are transcribed from the SDK headers on the build machine (`ESTypes.h`, `ESMessageCore.h`, `ESMessage.h`, `ESClient.h`) and checked against Apple's own compiler: `tools/gen_layout_anchors.py` asks `xcrun clang` for every `sizeof`, `offsetof` and enumerator value and writes them to `src/layout_anchors.zig`, which the test suite compares with the Zig types. 133 structs, 329 enumerators, 55 version-gated fields.

## Layers

| File | Role |
|---|---|
| `src/sys.zig` | Raw C surface with the SDK's names. Functions newer than macOS 10.15 are weak imports (`?*const fn`) checked at runtime. |
| `src/enums.zig` | Generated: every `es_*_t` enum, non-exhaustive (`_`) so unknown kernel values never trap. |
| `src/layout_anchors.zig` | Generated: clang's sizes, offsets, enumerator values and the message-version gate table. |
| `src/versioned.zig` | `has`/`get`: fields the header marks "available only if message version >= N" come back as optionals. |
| `src/message.zig` | `Message` (retain/release handle), `Process`, `File`, `Thread`, `Action`. |
| `src/event.zig` | `Event` tagged union with one member per `es_events_t` member; `Exec` with argv/envp/fd iterators and gated `cwd`, `script`, `dyldExecPath`. |
| `src/client.zig` | `Client`: `es_new_client` through an Objective-C block built by `zig_darwin_kit`; subscribe, respond, mute, invert muting, deadlines, `sync`. |

## Use

```zig
const es = @import("endpoint_sec");

const State = struct { seen: u64 = 0 };

fn onMessage(state: *State, client: es.Client, msg: es.Message) void {
    state.seen += 1;
    if (msg.exec()) |x| {
        // x.target() is the new image; msg.process() is whoever called exec.
        std.debug.print("{s} -> {s}\n", .{ msg.process().executable().path(), x.target().executable().path() });
        var args = x.args();
        while (args.next()) |a| std.debug.print("  {s}\n", .{a});
        if (x.findEnv("CLAUDECODE")) |_| { ... }
    }
    switch (msg.event()) {
        .unlink => |u| std.debug.print("unlink {s}\n", .{u.target.path.slice()}),
        else => {},
    }
    if (msg.isAuth()) client.respond(msg, .allow, false) catch {};
}

var state = State{};
var client = try es.Client.init(State, &state, onMessage);
defer client.deinit();
try client.muteSelf();
try client.subscribe(&.{ .ES_EVENT_TYPE_NOTIFY_EXEC, .ES_EVENT_TYPE_AUTH_UNLINK });
```

* `Message` is borrowed inside the handler. To answer an AUTH event later (from another thread, before `msg.deadline()`), `retain()` it and `release()` when done; `deadlineRemainingNanos()` says how long is left.
* `respond` picks `es_respond_flags_result` for `AUTH_OPEN` and `es_respond_auth_result` for everything else.
* `mutePath` uses `es_mute_path` on macOS 12+ and the deprecated prefix/literal calls before that; `TARGET_*` mute types, `invertMuting` and `unmuteAllTargetPaths` need macOS 13+ and return `error.ApiUnavailable` earlier.
* `initDescendants`, deadline-miss modes and `sync` are macOS 27 APIs, weak-linked the same way.
* macOS 10.15's `es_copy_message`/`es_free_message` are bound in `sys` but not used by `Message`; the library assumes macOS 11+.

## Running a client

The process needs the `com.apple.developer.endpoint-security.client` entitlement, Developer ID signing with the hardened runtime, root, and the user's Full Disk Access approval. `Client.init` reports which is missing (`NotEntitled`, `NotPermitted`, `NotPrivileged`). The example:

```
zig build
codesign --sign "Developer ID Application" --entitlements examples/es_tap.entitlements --options runtime --force zig-out/bin/es-tap
sudo zig-out/bin/es-tap            # NOTIFY exec/fork/exit/unlink/rename
sudo zig-out/bin/es-tap --auth-exec  # also AUTH_EXEC, allowed with deadline headroom printed
```

## Audit (2026-09-16)

Against the four promotion checks in the repo `CLAUDE.md`:

1. **External anchors.** Struct sizes, field offsets and enumerator values from Apple clang (`layout_anchors.zig`); the message-version gate table from the header's own comments; block ABI against libdispatch; audit-token indices against libbsm; deadline arithmetic against the kernel `CLOCK_UPTIME_RAW` clock; `es_new_client` called for real and observed to refuse the unentitled test binary. No roundtrip tests.
2. **Name.** A client binding has one direction; `zig_endpoint_sec` reads events and writes responses, both covered.
3. **build.zig** exposes `addModule("endpoint_sec")`, a static `libendpoint_sec.a`, `zig build test`, the example, and `zig build gen-anchors`.
4. **README first sentence** matches the source: client creation, subscription, payload access, AUTH response, muting.

Mutation tests, each observed red then restored green:

| Mutation | Observed |
|---|---|
| `es_event_signal_t.reserved` 56 → 64 | `sizeof 88 != clang 80` |
| `es_event_open_t` fields `fflag`/`file` swapped (same size) | three offset mismatches reported |
| `ES_EVENT_TYPE_NOTIFY_OPEN` 10 → 11 | compile error (duplicate tag); a non-colliding drift is caught by the value anchor |
| `dyld_exec_path` gate 7 → 1 in the table | version-gate tests and the `Exec` gate test red |

`zig-lens --strict` exits 0 on the directory.

## Regenerating for a new SDK

```
zig build gen-anchors    # rewrites src/layout_anchors.zig and src/enums.zig from the active SDK
zig build test           # any struct the new SDK changed fails here until sys.zig is updated
```

## Dependencies

`zig_darwin_kit` (path dependency) for blocks, mach time, audit tokens, version detection and libc memory ownership. Links `libEndpointSecurity` from `/usr/lib`. macOS only, Zig 0.16.
