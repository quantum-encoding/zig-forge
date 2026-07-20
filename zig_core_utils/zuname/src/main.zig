//! zuname - Print system information
//!
//! High-performance uname implementation in Zig.

const std = @import("std");
const builtin = @import("builtin");
const libc = std.c;

const VERSION = "1.0.0";

// Operating-system string, derived from the build target rather than a
// hardcoded literal. GNU `uname -o` prints "GNU/Linux" on Linux and "Darwin"
// on macOS; the installed GNU reference on this host confirms "Darwin".
const OS_STRING = switch (builtin.os.tag) {
    .linux => "GNU/Linux",
    .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .maccatalyst => "Darwin",
    else => @tagName(builtin.os.tag),
};

const UNKNOWN = "unknown";

// NOTE: do NOT hand-roll the utsname layout. On Darwin the C `uname(3)` writes
// 256-byte fields (_SYS_NAMELEN = 256); the previous 65-byte `extern struct`
// under-sized the buffer by ~1.1 KB and smashed the stack on every call.
// `std.posix.uname()` returns a target-sized `utsname` (see std.c.utsname:
// [255:0]u8 fields on Darwin, [64:0]u8 on Linux).

const Config = struct {
    kernel_name: bool = false,
    nodename: bool = false,
    release: bool = false,
    version: bool = false,
    machine: bool = false,
    processor: bool = false,
    hardware: bool = false,
    os: bool = false,
    all: bool = false,
};

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn printUsage() void {
    // GNU routes --help to stdout, not stderr.
    const usage =
        \\Usage: zuname [OPTION]...
        \\Print certain system information.  With no OPTION, same as -s.
        \\
        \\  -a, --all                print all information, in the following order,
        \\                             except omit -p and -i if unknown:
        \\  -s, --kernel-name        print the kernel name
        \\  -n, --nodename           print the network node hostname
        \\  -r, --kernel-release     print the kernel release
        \\  -v, --kernel-version     print the kernel version
        \\  -m, --machine            print the machine hardware name
        \\  -p, --processor          print the processor type (non-portable)
        \\  -i, --hardware-platform  print the hardware platform (non-portable)
        \\  -o, --operating-system   print the operating system
        \\      --help     display this help and exit
        \\      --version  output version information and exit
        \\
    ;
    writeStdout(usage);
}

fn printVersion() void {
    // GNU routes --version to stdout, not stderr.
    writeStdout("zuname " ++ VERSION ++ "\n");
}

// Slice a null-terminated fixed-size utsname field up to its terminator.
fn fieldSlice(field: []const u8) []const u8 {
    var len: usize = 0;
    while (len < field.len and field[len] != 0) : (len += 1) {}
    return field[0..len];
}

// Processor type (`uname -p`). Derived from the CPU type reported by the
// kernel. On Apple Silicon GNU/native `uname -p` prints "arm" (the base CPU
// type with the 64-bit ABI bit masked off); on Intel it prints "i386".
fn processorType() []const u8 {
    if (builtin.os.tag == .macos or builtin.os.tag == .ios or
        builtin.os.tag == .tvos or builtin.os.tag == .watchos)
    {
        var cputype: i32 = 0;
        var size: usize = @sizeOf(i32);
        if (libc.sysctlbyname("hw.cputype", &cputype, &size, null, 0) == 0) {
            // Mask CPU_ARCH_ABI64 (0x01000000) and CPU_ARCH_ABI64_32 (0x02000000).
            const base = cputype & ~@as(i32, 0x03000000);
            return switch (base) {
                12 => "arm", // CPU_TYPE_ARM
                7 => "i386", // CPU_TYPE_X86
                18 => "powerpc", // CPU_TYPE_POWERPC
                else => UNKNOWN,
            };
        }
    }
    return UNKNOWN;
}

// Hardware platform (`uname -i`). GNU prints "unknown" on Darwin (no
// UNAME_HARDWARE_PLATFORM); we mirror that.
fn hardwarePlatform() []const u8 {
    return UNKNOWN;
}

fn dieTryHelp() noreturn {
    writeStderr("Try 'zuname --help' for more information.\n");
    std.process.exit(1);
}

fn dieInvalidOption(c: u8) noreturn {
    var ch = [_]u8{c};
    writeStderr("zuname: invalid option -- '");
    writeStderr(&ch);
    writeStderr("'\n");
    dieTryHelp();
}

fn dieUnrecognized(opt: []const u8) noreturn {
    writeStderr("zuname: unrecognized option '");
    writeStderr(opt);
    writeStderr("'\n");
    dieTryHelp();
}

fn dieExtraOperand(op: []const u8) noreturn {
    writeStderr("zuname: extra operand '");
    writeStderr(op);
    writeStderr("'\n");
    dieTryHelp();
}

fn setShort(cfg: *Config, c: u8) void {
    switch (c) {
        'a' => cfg.all = true,
        's' => cfg.kernel_name = true,
        'n' => cfg.nodename = true,
        'r' => cfg.release = true,
        'v' => cfg.version = true,
        'm' => cfg.machine = true,
        'p' => cfg.processor = true,
        'i' => cfg.hardware = true,
        'o' => cfg.os = true,
        else => dieInvalidOption(c),
    }
}

fn setLong(cfg: *Config, arg: []const u8) void {
    if (std.mem.eql(u8, arg, "--all")) {
        cfg.all = true;
    } else if (std.mem.eql(u8, arg, "--kernel-name")) {
        cfg.kernel_name = true;
    } else if (std.mem.eql(u8, arg, "--nodename")) {
        cfg.nodename = true;
    } else if (std.mem.eql(u8, arg, "--kernel-release")) {
        cfg.release = true;
    } else if (std.mem.eql(u8, arg, "--kernel-version")) {
        cfg.version = true;
    } else if (std.mem.eql(u8, arg, "--machine")) {
        cfg.machine = true;
    } else if (std.mem.eql(u8, arg, "--processor")) {
        cfg.processor = true;
    } else if (std.mem.eql(u8, arg, "--hardware-platform")) {
        cfg.hardware = true;
    } else if (std.mem.eql(u8, arg, "--operating-system")) {
        cfg.os = true;
    } else {
        dieUnrecognized(arg);
    }
}

pub fn main(init: std.process.Init) !void {
    var cfg = Config{};
    var any_flag = false;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    while (args_iter.next()) |arg| {
        // --help / --version take effect immediately, wherever they appear.
        if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        } else if (arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
            setLong(&cfg, arg);
            any_flag = true;
        } else if (arg.len >= 2 and arg[0] == '-') {
            // Bundled short options: parse each character individually.
            for (arg[1..]) |c| setShort(&cfg, c);
            any_flag = true;
        } else {
            // Non-option operand (uname takes none) or a bare "-".
            dieExtraOperand(arg);
        }
    }

    // Default to -s if no flags were requested.
    if (!any_flag) {
        cfg.kernel_name = true;
    }

    const uts = std.posix.uname();

    var first = true;

    const emit = struct {
        fn f(first_p: *bool, slice: []const u8) void {
            if (!first_p.*) writeStdout(" ");
            first_p.* = false;
            writeStdout(slice);
        }
    }.f;

    if (cfg.all or cfg.kernel_name) emit(&first, fieldSlice(&uts.sysname));
    if (cfg.all or cfg.nodename) emit(&first, fieldSlice(&uts.nodename));
    if (cfg.all or cfg.release) emit(&first, fieldSlice(&uts.release));
    if (cfg.all or cfg.version) emit(&first, fieldSlice(&uts.version));
    if (cfg.all or cfg.machine) emit(&first, fieldSlice(&uts.machine));

    // Under -a, processor/hardware are omitted when unknown (GNU behavior);
    // when requested explicitly they are always printed (even "unknown").
    if (cfg.processor or cfg.all) {
        const p = processorType();
        if (cfg.processor or !std.mem.eql(u8, p, UNKNOWN)) emit(&first, p);
    }
    if (cfg.hardware or cfg.all) {
        const h = hardwarePlatform();
        if (cfg.hardware or !std.mem.eql(u8, h, UNKNOWN)) emit(&first, h);
    }
    if (cfg.os or cfg.all) emit(&first, OS_STRING);

    writeStdout("\n");
}
