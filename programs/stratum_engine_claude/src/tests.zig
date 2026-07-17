//! Test aggregator: forces every in-tree `test { … }` block to be analyzed and
//! run under `zig build test`. Prior to this, the test target rooted at
//! `main.zig` only ran the single test block in that file — the ~40 other test
//! blocks (HMAC RFC vectors, SHA256d, SIMD midstate parity, protocol parsing,
//! etc.) were compiled-but-never-referenced and so never executed.
//!
//! Zig only runs a file's tests when that file is semantically referenced from
//! the test root; `_ = @import(...)` provides that reference. Files that depend
//! on Linux-only io_uring/epoll code are gated behind a comptime OS check so the
//! aggregator still builds (and runs the portable tests) on macOS.

const builtin = @import("builtin");

// Existing behaviour: keep the original root's tests running.
comptime {
    _ = @import("main.zig");
}

// Portable tests — no Linux-only syscalls, compile everywhere.
comptime {
    _ = @import("crypto/hmac.zig");
    _ = @import("crypto/sha256d.zig");
    _ = @import("crypto/dispatch.zig");
    _ = @import("crypto/sha256_midstate.zig");
    _ = @import("crypto/sha256_avx2.zig");
    _ = @import("crypto/sha256_avx2_midstate.zig");
    _ = @import("crypto/sha256_avx512.zig");
    _ = @import("crypto/sha256_avx512_midstate.zig");
    _ = @import("crypto/tls_mbedtls.zig");
    _ = @import("metrics/stats.zig");
    _ = @import("stratum/protocol.zig");
    _ = @import("execution/websocket.zig");
    _ = @import("miner/worker.zig");
    _ = @import("miner/dispatcher.zig");
    _ = @import("storage/sqlite.zig");
}

// Linux-only tests — pull in io_uring/epoll-dependent modules only when the
// target actually supports them.
comptime {
    if (builtin.os.tag == .linux) {
        _ = @import("bitcoin/mempool.zig");
        _ = @import("crypto/tls.zig");
        _ = @import("execution/exchange_client.zig");
        _ = @import("proxy/pool_manager.zig");
        _ = @import("proxy/server.zig");
        _ = @import("proxy/websocket.zig");
        _ = @import("proxy/miner_registry.zig");
        _ = @import("stratum/client.zig");
        _ = @import("strategy/logic.zig");
    }
}
