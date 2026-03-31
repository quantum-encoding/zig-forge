/// Platform abstraction layer — compile-time selection between Linux and Zigix.
///
/// On Linux: uses libc, termios, PTY, /proc, poll(2)
/// On Zigix: uses direct syscalls, UART, kernel stats, process table

const builtin = @import("builtin");

pub const is_zigix = builtin.os.tag == .freestanding;
pub const is_linux = !is_zigix;

const backend = if (is_zigix) @import("platform/zigix.zig") else @import("platform/linux.zig");

// Re-export all platform functions
pub const termInit = backend.termInit;
pub const termDeinit = backend.termDeinit;
pub const termSize = backend.termSize;
pub const writeOutput = backend.writeOutput;
pub const readInput = backend.readInput;

pub const ProcessHandle = backend.ProcessHandle;
pub const spawnProcess = backend.spawnProcess;
pub const readProcessOutput = backend.readProcessOutput;
pub const writeProcessInput = backend.writeProcessInput;
pub const isProcessAlive = backend.isProcessAlive;

pub const SystemStats = backend.SystemStats;
pub const getSystemStats = backend.getSystemStats;
pub const getWallClock = backend.getWallClock;
pub const sleepMs = backend.sleepMs;
pub const getAllocator = backend.getAllocator;
