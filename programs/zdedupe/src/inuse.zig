//! Which running process is using a folder, if any
//!
//! `zdedupe clean --trash` judges a folder by age, and a long-running server
//! reads its `node_modules` without writing it, so the folder passes while the
//! server still depends on it. Moved, the server keeps running from the Trash,
//! breaks at its next restart, and Empty Trash refuses with "in use". This
//! answers the remaining question just before a move, from the operating
//! system's own view of each process: its working directory, its executable,
//! its open files, and the files it has mapped. The last matters as much as
//! the rest: a native module or shared library stays mapped after its
//! descriptor is closed, so a look at descriptors alone would miss one.
//!
//! Only this user's processes can be read without privileges, and a process
//! that exits mid-look is simply gone. Being unable to list processes, or
//! running out of memory while reading one, is `.unknown`, never `.free`: what
//! was not seen may not be concluded.
//! A process that holds nothing open under the folder cannot be seen here, as
//! a script that imported everything at start and closed its files.
//!
//! Windows has no implementation. `clean --trash` never reaches this there:
//! its age check is unsupported, so no folder is eligible.

const std = @import("std");
const builtin = @import("builtin");
const libc = @import("sys.zig").c;
const filters = @import("filters.zig");
const dirstream = @import("dirstream.zig");

const Allocator = std.mem.Allocator;

pub const Holder = struct { pid: i32, command: []const u8 };

pub const Answer = union(enum) {
    free,
    held: Holder,
    /// The process list could not be read.
    unknown,
};

/// Who, other than this process, is using `folder`, a real path. Anything
/// returned lives in `arena`.
pub fn holderOf(arena: Allocator, folder: []const u8) Answer {
    if (comptime builtin.os.tag == .windows) return .free;
    return search(arena, folder, libc.getpid());
}

fn search(arena: Allocator, folder: []const u8, skip: ?i32) Answer {
    if (comptime builtin.os.tag.isDarwin()) return darwin.search(arena, folder, skip);
    if (comptime builtin.os.tag == .linux) return linux.search(arena, folder, skip);
    return .free;
}

/// The bytes of `buf` before its first NUL.
fn cString(buf: []const u8) []const u8 {
    return buf[0 .. std.mem.indexOfScalar(u8, buf, 0) orelse buf.len];
}

const darwin = struct {
    extern "c" fn proc_listallpids(buffer: ?*anyopaque, buffersize: c_int) c_int;
    extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;
    extern "c" fn proc_pidfdinfo(pid: c_int, fd: c_int, flavor: c_int, buffer: ?*anyopaque, buffersize: c_int) c_int;
    extern "c" fn proc_pidpath(pid: c_int, buffer: ?*anyopaque, buffersize: u32) c_int;
    extern "c" fn proc_name(pid: c_int, buffer: ?*anyopaque, buffersize: u32) c_int;

    // <sys/proc_info.h>. Its records are read as bytes at these offsets rather
    // than declared, because only a path and two integers are wanted from
    // structures of several hundred bytes.
    const flavor_list_fds = 1;
    const flavor_region_path = 8;
    const flavor_vnode_paths = 9;
    const flavor_fd_vnode_path = 2;
    const fd_type_vnode = 1;
    const path_max = 1024;

    const fd_record_size = 8; // struct proc_fdinfo
    const fd_record_type = 4;
    const vnode_paths_size = 2352; // struct proc_vnodepathinfo
    const vnode_paths_cwd = 152;
    const fd_path_size = 1200; // struct vnode_fdinfowithpath
    const fd_path_path = 176;
    const region_size = 1272; // struct proc_regionwithpathinfo
    const region_address = 80;
    const region_length = 88;
    const region_path = 248;

    fn search(arena: Allocator, folder: []const u8, skip: ?i32) Answer {
        const estimate = proc_listallpids(null, 0);
        if (estimate <= 0) return .unknown;
        // Room for processes started since the estimate.
        const capacity: usize = @as(usize, @intCast(estimate)) + 64;
        const pids = arena.alloc(c_int, capacity) catch return .unknown;
        defer arena.free(pids);
        const count = proc_listallpids(pids.ptr, @intCast(capacity * @sizeOf(c_int)));
        if (count <= 0) return .unknown;

        for (pids[0..@min(@as(usize, @intCast(count)), capacity)]) |pid| {
            if (pid <= 0) continue;
            if (skip != null and pid == skip.?) continue;
            const held = holds(arena, pid, folder) catch return .unknown;
            if (held) return .{ .held = .{ .pid = pid, .command = command(arena, pid) } };
        }
        return .free;
    }

    fn holds(arena: Allocator, pid: c_int, folder: []const u8) Allocator.Error!bool {
        var exe: [4 * path_max]u8 = undefined;
        const exe_len = proc_pidpath(pid, &exe, exe.len);
        if (exe_len > 0 and filters.isAtOrUnder(exe[0..@intCast(exe_len)], folder)) return true;

        var paths: [vnode_paths_size]u8 align(8) = undefined;
        if (proc_pidinfo(pid, flavor_vnode_paths, 0, &paths, paths.len) == paths.len) {
            const cwd = cString(paths[vnode_paths_cwd..][0..path_max]);
            if (filters.isAtOrUnder(cwd, folder)) return true;
        }
        return try holdsAnOpenFile(arena, pid, folder) or holdsAMapping(pid, folder);
    }

    fn holdsAnOpenFile(arena: Allocator, pid: c_int, folder: []const u8) Allocator.Error!bool {
        const needed = proc_pidinfo(pid, flavor_list_fds, 0, null, 0);
        if (needed <= 0) return false;
        // Room for descriptors opened since the first call.
        const records = try arena.alignedAlloc(u8, .@"8", @as(usize, @intCast(needed)) + 32 * fd_record_size);
        defer arena.free(records);
        const got = proc_pidinfo(pid, flavor_list_fds, 0, records.ptr, @intCast(records.len));
        if (got <= 0) return false;

        var offset: usize = 0;
        while (offset + fd_record_size <= @as(usize, @intCast(got))) : (offset += fd_record_size) {
            const fd = std.mem.readInt(i32, records[offset..][0..4], builtin.cpu.arch.endian());
            const kind = std.mem.readInt(u32, records[offset + fd_record_type ..][0..4], builtin.cpu.arch.endian());
            if (kind != fd_type_vnode) continue;
            var info: [fd_path_size]u8 align(8) = undefined;
            if (proc_pidfdinfo(pid, fd, flavor_fd_vnode_path, &info, info.len) != info.len) continue;
            if (filters.isAtOrUnder(cString(info[fd_path_path..][0..path_max]), folder)) return true;
        }
        return false;
    }

    /// Each call answers with the first region at or above `address`.
    fn holdsAMapping(pid: c_int, folder: []const u8) bool {
        var address: u64 = 0;
        var region: [region_size]u8 align(8) = undefined;
        while (proc_pidinfo(pid, flavor_region_path, address, &region, region.len) == region.len) {
            if (filters.isAtOrUnder(cString(region[region_path..][0..path_max]), folder)) return true;
            const start = std.mem.readInt(u64, region[region_address..][0..8], builtin.cpu.arch.endian());
            const length = std.mem.readInt(u64, region[region_length..][0..8], builtin.cpu.arch.endian());
            const next = start +% length;
            if (next <= address) return false;
            address = next;
        }
        return false;
    }

    fn command(arena: Allocator, pid: c_int) []const u8 {
        var name: [2 * path_max]u8 = undefined;
        const len = proc_name(pid, &name, name.len);
        if (len <= 0) return "unknown";
        return arena.dupe(u8, name[0..@intCast(len)]) catch "unknown";
    }
};

const linux = struct {
    fn search(arena: Allocator, folder: []const u8, skip: ?i32) Answer {
        var proc = dirstream.ReaddirStream.open("/proc") orelse return .unknown;
        defer proc.close();
        var saw_a_process = false;
        while (proc.next() catch null) |entry| {
            const pid = std.fmt.parseInt(i32, std.mem.span(entry.name), 10) catch continue;
            saw_a_process = true;
            if (skip != null and pid == skip.?) continue;
            const held = holds(arena, pid, folder) catch return .unknown;
            if (held) return .{ .held = .{ .pid = pid, .command = command(arena, pid) } };
        }
        return if (saw_a_process) .free else .unknown;
    }

    fn linkIsUnder(path: [*:0]const u8, folder: []const u8) bool {
        var target: [4096]u8 = undefined;
        const n = libc.readlink(path, &target, target.len);
        return n > 0 and filters.isAtOrUnder(target[0..@intCast(n)], folder);
    }

    fn holds(arena: Allocator, pid: i32, folder: []const u8) Allocator.Error!bool {
        var buf: [64]u8 = undefined;
        for ([_][]const u8{ "exe", "cwd" }) |link| {
            const path = std.fmt.bufPrintSentinel(&buf, "/proc/{d}/{s}", .{ pid, link }, 0) catch continue;
            if (linkIsUnder(path.ptr, folder)) return true;
        }
        return holdsAnOpenFile(pid, folder) or try holdsAMapping(arena, pid, folder);
    }

    fn holdsAnOpenFile(pid: i32, folder: []const u8) bool {
        var buf: [64]u8 = undefined;
        const fds = std.fmt.bufPrintSentinel(&buf, "/proc/{d}/fd", .{pid}, 0) catch return false;
        var dir = dirstream.ReaddirStream.open(fds.ptr) orelse return false;
        defer dir.close();
        var link_buf: [96]u8 = undefined;
        while (dir.next() catch null) |entry| {
            const link = std.fmt.bufPrintSentinel(&link_buf, "/proc/{d}/fd/{s}", .{ pid, std.mem.span(entry.name) }, 0) catch continue;
            if (linkIsUnder(link.ptr, folder)) return true;
        }
        return false;
    }

    /// Each line of `maps` ends with the mapped file's path, the first `/` on it.
    fn holdsAMapping(arena: Allocator, pid: i32, folder: []const u8) Allocator.Error!bool {
        const maps = try readAll(arena, pid, "maps") orelse return false;
        defer arena.free(maps);
        var lines = std.mem.splitScalar(u8, maps, '\n');
        while (lines.next()) |line| {
            const slash = std.mem.indexOfScalar(u8, line, '/') orelse continue;
            if (filters.isAtOrUnder(line[slash..], folder)) return true;
        }
        return false;
    }

    /// The whole of a `/proc/<pid>/` file, or null when it cannot be read (the
    /// process is another user's, or gone). These report a size of zero, so it
    /// is read until it ends.
    fn readAll(arena: Allocator, pid: i32, name: []const u8) Allocator.Error!?[]u8 {
        var buf: [64]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&buf, "/proc/{d}/{s}", .{ pid, name }, 0) catch return null;
        const fd = libc.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        if (fd < 0) return null;
        defer _ = libc.close(fd);

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(arena);
        var chunk: [16 * 1024]u8 = undefined;
        while (true) {
            const n = libc.read(fd, &chunk, chunk.len);
            if (n < 0) {
                out.deinit(arena);
                return null;
            }
            if (n == 0) break;
            try out.appendSlice(arena, chunk[0..@intCast(n)]);
        }
        return try out.toOwnedSlice(arena);
    }

    fn command(arena: Allocator, pid: i32) []const u8 {
        const comm = (readAll(arena, pid, "comm") catch return "unknown") orelse return "unknown";
        const name = std.mem.trimEnd(u8, comm, "\n");
        return if (name.len == 0) "unknown" else name;
    }
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;
const Scratch = @import("testing_scratch.zig").Scratch;

extern "c" fn usleep(microseconds: c_uint) c_int;

const Fixture = struct {
    scratch: Scratch,
    folder: []const u8,

    fn init(arena: Allocator, label: []const u8) !Fixture {
        const scratch = try Scratch.init(testing.allocator, label);
        try scratch.makeDir("node_modules");
        try scratch.writeFile("node_modules/addon.node", "native module bytes");
        try scratch.makeDir("node_modules-old");
        try scratch.writeFile("node_modules-old/kept", "a name that begins the same");
        return .{ .scratch = scratch, .folder = try std.fmt.allocPrint(arena, "{s}/node_modules", .{scratch.path}) };
    }

    fn deinit(self: *Fixture) void {
        self.scratch.deinit();
    }

    fn openFile(self: *const Fixture, arena: Allocator, sub_path: []const u8) !c_int {
        const joined = try self.scratch.join(sub_path);
        defer testing.allocator.free(joined);
        const path = try arena.dupeSentinel(u8, joined, 0);
        const fd = libc.open(path.ptr, .{ .ACCMODE = .RDONLY });
        try testing.expect(fd >= 0);
        return fd;
    }
};

fn expectHeldBySelf(answer: Answer) !void {
    try testing.expectEqual(libc.getpid(), answer.held.pid);
    try testing.expect(answer.held.command.len > 0);
}

test "an open file under the folder holds it, until it is closed" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var f = try Fixture.init(a, "inuse-open");
    defer f.deinit();

    try testing.expectEqual(Answer.free, search(a, f.folder, null));
    const fd = try f.openFile(a, "node_modules/addon.node");
    try expectHeldBySelf(search(a, f.folder, null));
    _ = libc.close(fd);
    try testing.expectEqual(Answer.free, search(a, f.folder, null));
}

test "a mapping holds the folder after its descriptor is closed" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var f = try Fixture.init(a, "inuse-map");
    defer f.deinit();

    const fd = try f.openFile(a, "node_modules/addon.node");
    const mapped = try std.posix.mmap(null, 19, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
    _ = libc.close(fd);
    try expectHeldBySelf(search(a, f.folder, null));
    std.posix.munmap(mapped);
    try testing.expectEqual(Answer.free, search(a, f.folder, null));
}

test "a working directory under the folder holds it" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var f = try Fixture.init(a, "inuse-cwd");
    defer f.deinit();

    const here = libc.open(".", .{ .ACCMODE = .RDONLY });
    try testing.expect(here >= 0);
    defer _ = libc.close(here);
    const inside = try a.dupeSentinel(u8, f.folder, 0);
    try testing.expectEqual(@as(c_int, 0), libc.chdir(inside.ptr));
    defer _ = libc.fchdir(here);
    try expectHeldBySelf(search(a, f.folder, null));
}

/// The path of the running test binary.
fn ownExecutable(buf: []u8) ![:0]const u8 {
    if (comptime builtin.os.tag.isDarwin()) {
        const n = darwin.proc_pidpath(libc.getpid(), buf.ptr, @intCast(buf.len - 1));
        if (n <= 0) return error.SkipZigTest;
        buf[@intCast(n)] = 0;
        return buf[0..@intCast(n) :0];
    }
    const n = libc.readlink("/proc/self/exe", buf.ptr, buf.len - 1);
    if (n <= 0) return error.SkipZigTest;
    buf[@intCast(n)] = 0;
    return buf[0..@intCast(n) :0];
}

test "a running executable under the folder holds it, with another process's pid and name" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var f = try Fixture.init(a, "inuse-exe");
    defer f.deinit();

    // A program copied into the folder, as esbuild and workerd sit in node_modules:
    // this test binary, which waits on its stdin when told to serve a build runner.
    var own_buf: [4096]u8 = undefined;
    const own = try ownExecutable(&own_buf);
    const source = libc.open(own.ptr, .{ .ACCMODE = .RDONLY });
    try testing.expect(source >= 0);
    var program: std.ArrayListUnmanaged(u8) = .empty;
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = libc.read(source, &chunk, chunk.len);
        try testing.expect(n >= 0);
        if (n == 0) break;
        try program.appendSlice(a, chunk[0..@intCast(n)]);
    }
    _ = libc.close(source);
    try f.scratch.writeFile("node_modules/esbuild", program.items);
    const joined = try f.scratch.join("node_modules/esbuild");
    defer testing.allocator.free(joined);
    const exe = try a.dupeSentinel(u8, joined, 0);
    try testing.expectEqual(@as(c_int, 0), libc.chmod(exe.ptr, 0o755));

    var pipe_fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), libc.pipe(&pipe_fds));
    const child = libc.fork();
    try testing.expect(child >= 0);
    if (child == 0) {
        _ = libc.dup2(pipe_fds[0], 0);
        _ = libc.close(pipe_fds[1]);
        // It answers on stdout, which belongs to this test run.
        _ = libc.dup2(libc.open("/dev/null", .{ .ACCMODE = .WRONLY }), 1);
        const argv = [_:null]?[*:0]const u8{ exe.ptr, "--listen=-", null };
        const envp = [_:null]?[*:0]const u8{null};
        _ = libc.execve(exe.ptr, &argv, &envp);
        libc._exit(127);
    }
    _ = libc.close(pipe_fds[0]);
    defer {
        _ = libc.close(pipe_fds[1]);
        _ = libc.kill(child, .KILL);
        _ = libc.waitpid(child, null, 0);
    }

    // The child holds the folder from the moment it has exec'd. Linux shows the
    // new executable a moment before the new name, so wait for both.
    var answer: Answer = .free;
    for (0..20) |_| {
        answer = holderOf(a, f.folder);
        if (answer == .held and std.mem.indexOf(u8, answer.held.command, "esbuild") != null) break;
        _ = usleep(50 * std.time.us_per_ms);
    }
    try testing.expect(answer == .held);
    try testing.expectEqual(child, answer.held.pid);
    try testing.expect(std.mem.indexOf(u8, answer.held.command, "esbuild") != null);
}

test "a folder whose name merely begins the same is not held" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var f = try Fixture.init(a, "inuse-prefix");
    defer f.deinit();

    const fd = try f.openFile(a, "node_modules-old/kept");
    defer _ = libc.close(fd);
    try testing.expectEqual(Answer.free, search(a, f.folder, null));
}

test "this process does not count as using a folder" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var f = try Fixture.init(a, "inuse-self");
    defer f.deinit();

    const fd = try f.openFile(a, "node_modules/addon.node");
    defer _ = libc.close(fd);
    try testing.expectEqual(Answer.free, holderOf(a, f.folder));
}
