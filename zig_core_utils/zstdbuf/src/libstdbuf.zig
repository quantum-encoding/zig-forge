//! libstdbuf — the pre-loaded companion library for zstdbuf.
//!
//! This mirrors GNU coreutils' libstdbuf.c. zstdbuf sets _STDBUF_I/_STDBUF_O/
//! _STDBUF_E in the child's environment and pre-loads this library (via
//! DYLD_INSERT_LIBRARIES on macOS, LD_PRELOAD elsewhere). Our constructor runs
//! before the child's main(), reads those variables, and calls setvbuf() on the
//! matching stdio stream so the requested buffering actually takes effect.
//!
//!   value "L"     -> line buffered   (_IOLBF)
//!   value "0"     -> unbuffered      (_IONBF)
//!   value "<n>"   -> fully buffered with an n-byte buffer (_IOFBF)

const std = @import("std");
const builtin = @import("builtin");

const _IOFBF: c_int = 0;
const _IOLBF: c_int = 1;
const _IONBF: c_int = 2;

const FILE = opaque {};
extern "c" fn setvbuf(stream: *FILE, buf: ?[*]u8, mode: c_int, size: usize) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn malloc(size: usize) ?[*]u8;

// The stdio stream globals differ by platform: macOS exposes __std{in,out,err}p,
// glibc/musl expose std{in,out,err} directly.
const darwin = builtin.os.tag.isDarwin();

extern "c" var __stdinp: *FILE;
extern "c" var __stdoutp: *FILE;
extern "c" var __stderrp: *FILE;
extern "c" var stdin: *FILE;
extern "c" var stdout: *FILE;
extern "c" var stderr: *FILE;

const Stream = enum { in, out, err };

fn stream(comptime which: Stream) *FILE {
    if (darwin) {
        return switch (which) {
            .in => __stdinp,
            .out => __stdoutp,
            .err => __stderrp,
        };
    } else {
        return switch (which) {
            .in => stdin,
            .out => stdout,
            .err => stderr,
        };
    }
}

fn applyOne(env_name: [*:0]const u8, fp: *FILE) void {
    const raw = getenv(env_name) orelse return;
    const s = std.mem.span(raw);
    if (s.len == 0) return;

    if (s[0] == 'L') {
        _ = setvbuf(fp, null, _IOLBF, 0);
        return;
    }

    const size = std.fmt.parseInt(usize, s, 10) catch return;
    if (size == 0) {
        _ = setvbuf(fp, null, _IONBF, 0);
        return;
    }

    // Allocate the buffer setvbuf will use. If malloc fails, leave the stream
    // as-is rather than crashing the host process.
    const buf = malloc(size) orelse return;
    _ = setvbuf(fp, buf, _IOFBF, size);
}

fn stdbufConstructor() callconv(.c) void {
    applyOne("_STDBUF_I", stream(.in));
    applyOne("_STDBUF_O", stream(.out));
    applyOne("_STDBUF_E", stream(.err));
}

// Register the constructor. On macOS the loader calls every pointer in
// __DATA,__mod_init_func; on ELF platforms it calls every pointer in
// .init_array. `export` keeps the pointer from being stripped.
const init_section = if (darwin) "__DATA,__mod_init_func" else ".init_array";
export const _stdbuf_init_ptr: *const fn () callconv(.c) void linksection(init_section) = &stdbufConstructor;
