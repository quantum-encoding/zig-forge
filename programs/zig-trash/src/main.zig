//! trash — move files to the OS trash, and manage trash contents.
//!
//! macOS:  NSFileManager trashItemAtURL: (Finder Trash, Cmd+Z undo)
//! Linux:  freedesktop.org trash spec (~/.local/share/Trash/)
//!
//! Subcommands:
//!   trash <files...>                           send to trash (default)
//!   trash list [--older <age>] [--project] [--json]
//!   trash size [--bytes]
//!   trash empty [--older <age>] [--yes]
//!   trash restore <pattern> [--to <path>]

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

const c = std.c;

// ═══════════════════════════════════════════════════════════════════════════════
// Entry point + subcommand dispatch
// ═══════════════════════════════════════════════════════════════════════════════

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    const first_arg = args_iter.next() orelse {
        printHelp(io);
        std.process.exit(1);
    };

    // Help/version — check before dispatch
    if (std.mem.eql(u8, first_arg, "-h") or std.mem.eql(u8, first_arg, "--help")) {
        printHelp(io);
        return;
    }
    if (std.mem.eql(u8, first_arg, "-V") or std.mem.eql(u8, first_arg, "--version")) {
        wOut("trash 0.2.0 (zig)\n", .{});
        return;
    }

    // Subcommand dispatch — only if first arg doesn't look like a flag or path
    if (first_arg[0] != '-' and first_arg[0] != '.' and first_arg[0] != '/') {
        if (std.mem.eql(u8, first_arg, "list")) return cmdList(allocator, io, &args_iter);
        if (std.mem.eql(u8, first_arg, "size")) return cmdSize(allocator, io, &args_iter);
        if (std.mem.eql(u8, first_arg, "empty")) return cmdEmpty(allocator, io, &args_iter);
        if (std.mem.eql(u8, first_arg, "restore")) return cmdRestore(allocator, io, &args_iter);
    }

    // Default: send files to trash (re-include first_arg)
    cmdTrash(allocator, io, first_arg, &args_iter);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Subcommand: trash <files...> (send to trash)
// ═══════════════════════════════════════════════════════════════════════════════

fn cmdTrash(allocator: std.mem.Allocator, io: Io, first_arg: []const u8, args_iter: *std.process.Args.Iterator) void {
    var verbose = false;
    var force = false;
    var dry_run = false;
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer paths.deinit(allocator);
    var past_dashdash = false;

    // Process first_arg + remaining args
    const all_args = [_]?[]const u8{first_arg} ++ [_]?[]const u8{null};
    _ = all_args;

    // Helper to process one arg
    const processArg = struct {
        fn f(p: *std.ArrayListUnmanaged([]const u8), alloc: std.mem.Allocator, arg: []const u8, v: *bool, fo: *bool, dr: *bool, past_dd: *bool) void {
            if (past_dd.*) {
                p.append(alloc, arg) catch return;
                return;
            }
            if (std.mem.eql(u8, arg, "--")) {
                past_dd.* = true;
                return;
            }
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                // Can't call printHelp here easily, just set a flag
                return;
            } else if (std.mem.eql(u8, arg, "--dry-run")) {
                dr.* = true;
            } else if (std.mem.eql(u8, arg, "--verbose")) {
                v.* = true;
            } else if (std.mem.eql(u8, arg, "--force")) {
                fo.* = true;
            } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
                for (arg[1..]) |ch| {
                    switch (ch) {
                        'v' => v.* = true,
                        'f' => fo.* = true,
                        'n' => dr.* = true,
                        'r', 'R' => {},
                        else => {
                            wErr("trash: unknown flag '-{c}'\n", .{ch});
                            std.process.exit(1);
                        },
                    }
                }
            } else {
                p.append(alloc, arg) catch return;
            }
        }
    }.f;

    processArg(&paths, allocator, first_arg, &verbose, &force, &dry_run, &past_dashdash);
    while (args_iter.next()) |arg| {
        processArg(&paths, allocator, arg, &verbose, &force, &dry_run, &past_dashdash);
    }

    if (paths.items.len == 0) {
        wErr("trash: no paths specified\n", .{});
        std.process.exit(1);
    }

    var errors: u32 = 0;

    for (paths.items) |path| {
        const path_z = allocator.dupeZ(u8, path) catch {
            errors += 1;
            continue;
        };
        defer allocator.free(path_z);

        if (c.access(path_z, 0) != 0) {
            if (force) {
                if (verbose) wErr("trash: skipping (not found): {s}\n", .{path});
                continue;
            }
            wErr("trash: not found: {s}\n", .{path});
            errors += 1;
            continue;
        }

        // Resolve absolute path
        var rp_buf: [Dir.max_path_bytes]u8 = undefined;
        const resolved = c.realpath(path_z, &rp_buf) orelse {
            wErr("trash: cannot resolve {s}\n", .{path});
            errors += 1;
            continue;
        };
        const abs_path = std.mem.span(resolved);

        if (dry_run) {
            wOut("would trash: {s}\n", .{abs_path});
            continue;
        }

        const trash_name = trashFile(allocator, abs_path) catch {
            wErr("trash: failed to trash {s}\n", .{abs_path});
            errors += 1;
            continue;
        };
        defer if (trash_name) |tn| allocator.free(tn);

        // Write .trashinfo metadata
        if (trash_name) |tn| {
            writeTrashInfo(allocator, io, tn, abs_path) catch {};
        }

        if (verbose) wOut("trashed: {s}\n", .{abs_path});
    }

    if (errors > 0) std.process.exit(1);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Subcommand: trash list
// ═══════════════════════════════════════════════════════════════════════════════

fn cmdList(allocator: std.mem.Allocator, io: Io, args_iter: *std.process.Args.Iterator) void {
    var older_secs: ?i64 = null;
    var project_filter = false;
    var json_output = false;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--older")) {
            const val = args_iter.next() orelse {
                wErr("trash list: --older requires a value (e.g. 7d, 24h)\n", .{});
                std.process.exit(1);
            };
            older_secs = parseAge(val);
            if (older_secs == null) {
                wErr("trash: invalid age '{s}' (use e.g. 7d, 24h)\n", .{val});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--project")) {
            project_filter = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else {
            wErr("trash list: unknown argument '{s}'\n", .{arg});
            std.process.exit(1);
        }
    }

    const cwd: ?[]const u8 = if (project_filter) blk: {
        var buf: [Dir.max_path_bytes]u8 = undefined;
        const n = std.process.currentPath(io, &buf) catch break :blk null;
        break :blk allocator.dupe(u8, buf[0..n]) catch null;
    } else null;
    defer if (cwd) |c_| allocator.free(c_);

    const now_ns = Io.Timestamp.now(io, .real);
    const now_secs: i64 = @intCast(@divFloor(now_ns.nanoseconds, std.time.ns_per_s));

    var entries: std.ArrayListUnmanaged(TrashEntry) = .empty;
    defer {
        for (entries.items) |*e| e.deinit(allocator);
        entries.deinit(allocator);
    }

    const info_path = getInfoDir(allocator) orelse return;
    defer allocator.free(info_path);

    const info_dir = Dir.openDirAbsolute(io, info_path, .{ .iterate = true }) catch return;
    defer @constCast(&info_dir).close(io);
    var iter = info_dir.iterate();

    while (iter.next(io) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".trashinfo")) continue;

        const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ info_path, entry.name }) catch continue;
        defer allocator.free(full);

        var te = readTrashInfo(allocator, io, full) orelse continue;

        // Apply filters
        if (older_secs) |threshold| {
            if (te.timestamp) |ts| {
                if (now_secs - ts < threshold) {
                    te.deinit(allocator);
                    continue;
                }
            }
        }
        if (cwd) |cwd_path| {
            if (!std.mem.startsWith(u8, te.original_path, cwd_path)) {
                te.deinit(allocator);
                continue;
            }
        }

        // Record the trash filename (strip .trashinfo suffix)
        const base = entry.name[0 .. entry.name.len - ".trashinfo".len];
        te.trash_name = allocator.dupe(u8, base) catch null;

        entries.append(allocator, te) catch {
            te.deinit(allocator);
            continue;
        };
    }

    // Sort by date descending (newest first)
    std.mem.sort(TrashEntry, entries.items, {}, struct {
        fn lt(_: void, a: TrashEntry, b: TrashEntry) bool {
            return (a.timestamp orelse 0) > (b.timestamp orelse 0);
        }
    }.lt);

    if (json_output) {
        wOut("[\n", .{});
        for (entries.items, 0..) |e, idx| {
            const tn = e.trash_name orelse "unknown";
            wOut("  {{\"path\":\"{s}\",\"date\":\"{s}\",\"trash_name\":\"{s}\"}}", .{ e.original_path, e.date_str, tn });
            if (idx < entries.items.len - 1) wOut(",\n", .{}) else wOut("\n", .{});
        }
        wOut("]\n", .{});
    } else {
        if (entries.items.len == 0) {
            wOut("Trash is empty (no tracked items).\n", .{});
        } else {
            wOut("{d} item(s) in trash:\n\n", .{entries.items.len});
            for (entries.items) |e| {
                wOut("  {s}  {s}\n", .{ e.date_str, e.original_path });
            }
        }
        // Count untracked files
        const trash_path = getTrashDir(allocator) orelse return;
        defer allocator.free(trash_path);
        const untracked = countUntrackedFiles(allocator, io, trash_path, info_path);
        if (untracked > 0) {
            wOut("\n({d} additional items trashed externally — no metadata)\n", .{untracked});
        }
    }
}

fn countUntrackedFiles(allocator: std.mem.Allocator, io: Io, trash_path: []const u8, info_path: []const u8) u32 {
    var count: u32 = 0;
    const dir = Dir.openDirAbsolute(io, trash_path, .{ .iterate = true }) catch return 0;
    defer @constCast(&dir).close(io);
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.name[0] == '.') continue;
        const info_file = std.fmt.allocPrint(allocator, "{s}/{s}.trashinfo", .{ info_path, entry.name }) catch continue;
        defer allocator.free(info_file);
        Dir.accessAbsolute(io, info_file, .{}) catch {
            count += 1;
            continue;
        };
    }
    return count;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Subcommand: trash size
// ═══════════════════════════════════════════════════════════════════════════════

fn cmdSize(allocator: std.mem.Allocator, io: Io, args_iter: *std.process.Args.Iterator) void {
    var bytes_output = false;
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bytes")) {
            bytes_output = true;
        } else {
            wErr("trash size: unknown argument '{s}'\n", .{arg});
            std.process.exit(1);
        }
    }

    const trash_path = getTrashDir(allocator) orelse {
        if (bytes_output) wOut("0\n", .{}) else wOut("0 B\n", .{});
        return;
    };
    defer allocator.free(trash_path);

    const total = dirSizeRecursive(allocator, io, trash_path);

    if (bytes_output) {
        wOut("{d}\n", .{total});
    } else {
        var buf: [64]u8 = undefined;
        const s = humanSize(total, &buf);
        wOut("{s}\n", .{s});
    }
}

fn dirSizeRecursive(allocator: std.mem.Allocator, io: Io, trash_path: []const u8) u64 {
    // On macOS, ~/.Trash/ is TCC-protected — we can't enumerate it.
    // Instead, stat individual files we know about from metadata.
    const info_path = getInfoDir(allocator) orelse return 0;
    defer allocator.free(info_path);

    var total: u64 = 0;
    const dir = Dir.openDirAbsolute(io, info_path, .{ .iterate = true }) catch return 0;
    defer @constCast(&dir).close(io);
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".trashinfo")) continue;
        const base = entry.name[0 .. entry.name.len - ".trashinfo".len];
        const file_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ trash_path, base }) catch continue;
        defer allocator.free(file_path);
        const file_z = allocator.dupeZ(u8, file_path) catch continue;
        defer allocator.free(file_z);

        var st: Stat = undefined;
        if (lstat(file_z, &st) == 0) {
            total += @intCast(@max(st.size, 0));
        }
    }
    return total;
}

// macOS stat struct
const Stat = extern struct {
    dev: i32, mode: u16, nlink: u16, ino: u64, uid: u32, gid: u32, rdev: i32,
    atime: c.timespec, mtime: c.timespec, ctime: c.timespec, _btime: c.timespec,
    size: i64, blocks: i64, blksize: i32, flags: u32, gen: u32, _spare: i32, _reserved: [2]i64,
};
extern "c" fn lstat(path: [*:0]const u8, buf: *Stat) c_int;

// ═══════════════════════════════════════════════════════════════════════════════
// Subcommand: trash empty
// ═══════════════════════════════════════════════════════════════════════════════

fn cmdEmpty(allocator: std.mem.Allocator, io: Io, args_iter: *std.process.Args.Iterator) void {
    var older_secs: ?i64 = null;
    var confirmed = false;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--older")) {
            const val = args_iter.next() orelse {
                wErr("trash empty: --older requires a value\n", .{});
                std.process.exit(1);
            };
            older_secs = parseAge(val);
            if (older_secs == null) {
                wErr("trash: invalid age '{s}' (use e.g. 7d, 24h)\n", .{val});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            confirmed = true;
        } else {
            wErr("trash empty: unknown argument '{s}'\n", .{arg});
            std.process.exit(1);
        }
    }

    const trash_path = getTrashDir(allocator) orelse {
        wOut("Trash is already empty.\n", .{});
        return;
    };
    defer allocator.free(trash_path);

    const info_path = getInfoDir(allocator) orelse return;
    defer allocator.free(info_path);

    if (older_secs != null) {
        emptyOlderThan(allocator, io, trash_path, info_path, older_secs.?, confirmed);
    } else {
        emptyAll(allocator, io, trash_path, info_path, confirmed);
    }
}

fn emptyOlderThan(allocator: std.mem.Allocator, io: Io, trash_path: []const u8, info_path: []const u8, threshold: i64, confirmed: bool) void {
    const now_ns = Io.Timestamp.now(io, .real);
    const now_secs: i64 = @intCast(@divFloor(now_ns.nanoseconds, std.time.ns_per_s));

    var to_delete: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (to_delete.items) |item| allocator.free(item);
        to_delete.deinit(allocator);
    }

    const dir = Dir.openDirAbsolute(io, info_path, .{ .iterate = true }) catch return;
    defer @constCast(&dir).close(io);
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".trashinfo")) continue;

        const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ info_path, entry.name }) catch continue;
        defer allocator.free(full);

        var te = readTrashInfo(allocator, io, full) orelse continue;
        defer te.deinit(allocator);

        if (te.timestamp) |ts| {
            if (now_secs - ts >= threshold) {
                const base = entry.name[0 .. entry.name.len - ".trashinfo".len];
                to_delete.append(allocator, allocator.dupe(u8, base) catch continue) catch continue;
            }
        }
    }

    if (to_delete.items.len == 0) {
        wOut("No items match the age filter.\n", .{});
        return;
    }

    if (!confirmed) {
        wOut("Permanently delete {d} item(s)? [y/N] ", .{to_delete.items.len});
        if (!readConfirmation()) {
            wOut("Cancelled.\n", .{});
            return;
        }
    }

    var deleted: u32 = 0;
    for (to_delete.items) |name| {
        deleteTrashItem(allocator, trash_path, info_path, name);
        deleted += 1;
    }
    wOut("Permanently deleted {d} item(s).\n", .{deleted});
}

fn emptyAll(allocator: std.mem.Allocator, io: Io, trash_path: []const u8, info_path: []const u8, confirmed: bool) void {
    const total = dirSizeRecursive(allocator, io, trash_path);

    // Count tracked items from metadata (macOS TCC blocks enumeration of ~/.Trash/)
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    {
        const dir = Dir.openDirAbsolute(io, info_path, .{ .iterate = true }) catch return;
        defer @constCast(&dir).close(io);
        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".trashinfo")) continue;
            const base = entry.name[0 .. entry.name.len - ".trashinfo".len];
            names.append(allocator, allocator.dupe(u8, base) catch continue) catch continue;
        }
    }

    if (names.items.len == 0) {
        wOut("Trash is empty (no tracked items).\n", .{});
        return;
    }

    if (!confirmed) {
        var size_buf: [64]u8 = undefined;
        const size_str = humanSize(total, &size_buf);
        wOut("Permanently delete {d} item(s) ({s})? [y/N] ", .{ names.items.len, size_str });
        if (!readConfirmation()) {
            wOut("Cancelled.\n", .{});
            return;
        }
    }

    var deleted: u32 = 0;
    for (names.items) |name| {
        // Delete the actual file from trash
        const file_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ trash_path, name }) catch continue;
        defer allocator.free(file_path);
        const file_z = allocator.dupeZ(u8, file_path) catch continue;
        defer allocator.free(file_z);

        // Try unlink first (files), then rmdir (empty dirs), then recursive delete
        if (c.unlink(file_z) == 0) {
            deleted += 1;
        } else if (c.rmdir(file_z) == 0) {
            deleted += 1;
        } else {
            // For non-empty directories, use recursive C delete
            recursiveDelete(allocator, file_z);
            deleted += 1;
        }

        // Delete the .trashinfo
        const info_file = std.fmt.allocPrint(allocator, "{s}/{s}.trashinfo", .{ info_path, name }) catch continue;
        defer allocator.free(info_file);
        const info_z = allocator.dupeZ(u8, info_file) catch continue;
        defer allocator.free(info_z);
        _ = c.unlink(info_z);
    }

    var size_buf: [64]u8 = undefined;
    const size_str = humanSize(total, &size_buf);
    wOut("Permanently deleted {d} item(s) ({s}).\n", .{ deleted, size_str });
}

fn recursiveDelete(allocator: std.mem.Allocator, path_z: [*:0]const u8) void {
    const dir = c.opendir(path_z) orelse return;
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |entry| {
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name = std.mem.span(name_ptr);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        const full = allocPrintZ(allocator, "{s}/{s}", .{ std.mem.span(path_z), name }) catch continue;
        defer allocator.free(full);

        if (entry.type == 4) { // DT_DIR
            recursiveDelete(allocator, full);
        } else {
            _ = c.unlink(full);
        }
    }
    _ = c.rmdir(path_z);
}

fn deleteTrashItem(allocator: std.mem.Allocator, trash_path: []const u8, info_path: []const u8, name: []const u8) void {
    // Delete file/dir from trash
    const file_path = allocPrintZ(allocator, "{s}/{s}", .{ trash_path, name }) catch return;
    defer allocator.free(file_path);
    if (c.unlink(file_path) != 0) {
        if (c.rmdir(file_path) != 0) {
            recursiveDelete(allocator, file_path);
        }
    }

    // Delete .trashinfo
    const info_file = allocPrintZ(allocator, "{s}/{s}.trashinfo", .{ info_path, name }) catch return;
    defer allocator.free(info_file);
    _ = c.unlink(info_file);
}

fn readConfirmation() bool {
    if (c.isatty(0) == 0) {
        wErr("trash: refusing to empty without --yes (stdin is not a terminal)\n", .{});
        return false;
    }
    var buf: [16]u8 = undefined;
    const n = c.read(0, &buf, buf.len);
    if (n <= 0) return false;
    return buf[0] == 'y' or buf[0] == 'Y';
}

// ═══════════════════════════════════════════════════════════════════════════════
// Subcommand: trash restore
// ═══════════════════════════════════════════════════════════════════════════════

fn cmdRestore(allocator: std.mem.Allocator, io: Io, args_iter: *std.process.Args.Iterator) void {
    var pattern: ?[]const u8 = null;
    var restore_to: ?[]const u8 = null;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--to")) {
            restore_to = args_iter.next() orelse {
                wErr("trash restore: --to requires a path\n", .{});
                std.process.exit(1);
            };
        } else if (arg[0] != '-') {
            pattern = arg;
        } else {
            wErr("trash restore: unknown argument '{s}'\n", .{arg});
            std.process.exit(1);
        }
    }

    if (pattern == null) {
        wErr("trash restore: specify a pattern to match (substring of original path)\n", .{});
        std.process.exit(1);
    }

    const info_path = getInfoDir(allocator) orelse {
        wErr("trash restore: no metadata directory found\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(info_path);

    const trash_path = getTrashDir(allocator) orelse return;
    defer allocator.free(trash_path);

    // Find matching entries
    var matches: std.ArrayListUnmanaged(TrashEntry) = .empty;
    defer {
        for (matches.items) |*m| m.deinit(allocator);
        matches.deinit(allocator);
    }

    const dir = Dir.openDirAbsolute(io, info_path, .{ .iterate = true }) catch return;
    defer @constCast(&dir).close(io);
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".trashinfo")) continue;

        const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ info_path, entry.name }) catch continue;
        defer allocator.free(full);

        var te = readTrashInfo(allocator, io, full) orelse continue;

        if (std.mem.indexOf(u8, te.original_path, pattern.?) != null) {
            const base = entry.name[0 .. entry.name.len - ".trashinfo".len];
            te.trash_name = allocator.dupe(u8, base) catch null;
            matches.append(allocator, te) catch {
                te.deinit(allocator);
                continue;
            };
        } else {
            te.deinit(allocator);
        }
    }

    if (matches.items.len == 0) {
        wErr("trash restore: no items matching '{s}'\n", .{pattern.?});
        std.process.exit(1);
    }

    // If multiple matches, prompt
    var selected: usize = 0;
    if (matches.items.len > 1) {
        wOut("Multiple matches for '{s}':\n\n", .{pattern.?});
        for (matches.items, 1..) |m, num| {
            wOut("  {d}) {s}  {s}\n", .{ num, m.date_str, m.original_path });
        }
        wOut("\nEnter number to restore (0 to cancel): ", .{});

        if (c.isatty(0) == 0) {
            wErr("trash restore: multiple matches — run interactively or refine pattern\n", .{});
            std.process.exit(1);
        }

        var buf: [16]u8 = undefined;
        const n = c.read(0, &buf, buf.len);
        if (n <= 0) std.process.exit(1);
        const input = std.mem.trimEnd(u8, buf[0..@intCast(n)], "\n\r");
        const choice = std.fmt.parseInt(usize, input, 10) catch {
            wErr("trash restore: invalid selection\n", .{});
            std.process.exit(1);
        };
        if (choice == 0 or choice > matches.items.len) {
            wOut("Cancelled.\n", .{});
            return;
        }
        selected = choice - 1;
    }

    const to_restore = matches.items[selected];
    const tn = to_restore.trash_name orelse {
        wErr("trash restore: cannot determine trash filename\n", .{});
        std.process.exit(1);
    };

    const dest = restore_to orelse to_restore.original_path;

    // Check destination doesn't exist
    const dest_z = allocator.dupeZ(u8, dest) catch std.process.exit(1);
    defer allocator.free(dest_z);
    if (c.access(dest_z, 0) == 0) {
        wErr("trash restore: destination already exists: {s}\n", .{dest});
        std.process.exit(1);
    }

    // Create parent directory if needed
    if (std.fs.path.dirname(dest)) |parent| {
        Dir.createDirAbsolute(io, parent, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                wErr("trash restore: cannot create parent directory: {s}\n", .{parent});
                std.process.exit(1);
            },
        };
    }

    // Move file back using rename
    const src_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ trash_path, tn }) catch return;
    defer allocator.free(src_path);
    Dir.renameAbsolute(src_path, dest, io) catch {
        wErr("trash restore: failed to move {s} → {s}\n", .{ src_path, dest });
        if (comptime builtin.os.tag == .macos) {
            wErr("hint: grant Full Disk Access to your terminal app in\n", .{});
            wErr("  System Settings > Privacy & Security > Full Disk Access\n", .{});
        }
        std.process.exit(1);
    };

    // Remove .trashinfo
    const info_file_path = std.fmt.allocPrint(allocator, "{s}/{s}.trashinfo", .{ info_path, tn }) catch return;
    defer allocator.free(info_file_path);
    Dir.deleteFileAbsolute(io, info_file_path) catch {};

    wOut("restored: {s}\n", .{dest});
}

// ═══════════════════════════════════════════════════════════════════════════════
// Trash send (platform dispatch)
// ═══════════════════════════════════════════════════════════════════════════════

/// Returns the filename in trash (for metadata writing), or null.
fn trashFile(allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
    if (comptime builtin.os.tag == .macos) {
        return try trashMacOS(allocator, path);
    } else if (comptime builtin.os.tag == .linux) {
        return try trashLinux(allocator, path);
    } else {
        @compileError("unsupported platform");
    }
}

// ─── macOS: NSFileManager trashItemAtURL: ────────────────────────────────────

const trashMacOS = if (builtin.os.tag == .macos) struct {
    const Class = *opaque {};
    const SEL = *opaque {};
    const id = *opaque {};

    extern "c" fn objc_getClass(name: [*:0]const u8) ?Class;
    extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
    extern "c" fn objc_msgSend() void;

    fn call(allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
        const NSFileManager = objc_getClass("NSFileManager") orelse return error.ObjcClassNotFound;
        const NSString = objc_getClass("NSString") orelse return error.ObjcClassNotFound;
        const NSURL = objc_getClass("NSURL") orelse return error.ObjcClassNotFound;

        const fm: id = msg(id, Class, NSFileManager, sel_registerName("defaultManager"), .{});

        const path_z = try std.heap.page_allocator.dupeZ(u8, path);
        defer std.heap.page_allocator.free(path_z);
        const ns_path: id = msg(id, Class, NSString, sel_registerName("stringWithUTF8String:"), .{path_z.ptr});
        const url: id = msg(id, Class, NSURL, sel_registerName("fileURLWithPath:"), .{ns_path});

        var result_url: ?id = null;
        var err_ptr: ?id = null;
        const ok = msg(bool, id, fm, sel_registerName("trashItemAtURL:resultingItemURL:error:"), .{ url, &result_url, &err_ptr });

        if (!ok) return error.TrashFailed;

        // Extract filename from the resulting URL
        if (result_url) |rurl| {
            const result_nsurl_path: id = msg(id, id, rurl, sel_registerName("path"), .{});
            const last_comp: id = msg(id, id, result_nsurl_path, sel_registerName("lastPathComponent"), .{});
            const utf8: [*:0]const u8 = msg([*:0]const u8, id, last_comp, sel_registerName("UTF8String"), .{});
            return allocator.dupe(u8, std.mem.span(utf8)) catch null;
        }

        return null;
    }

    fn msg(comptime Ret: type, comptime Target: type, target: Target, sel: SEL, extra: anytype) Ret {
        const fields = @typeInfo(@TypeOf(extra)).@"struct".fields;
        const Fn = switch (fields.len) {
            0 => *const fn (Target, SEL) callconv(.c) Ret,
            1 => *const fn (Target, SEL, fields[0].type) callconv(.c) Ret,
            2 => *const fn (Target, SEL, fields[0].type, fields[1].type) callconv(.c) Ret,
            3 => *const fn (Target, SEL, fields[0].type, fields[1].type, fields[2].type) callconv(.c) Ret,
            else => @compileError("too many args"),
        };
        const func: Fn = @ptrCast(&objc_msgSend);
        return switch (fields.len) {
            0 => func(target, sel),
            1 => func(target, sel, extra[0]),
            2 => func(target, sel, extra[0], extra[1]),
            3 => func(target, sel, extra[0], extra[1], extra[2]),
            else => unreachable,
        };
    }
}.call else unreachable;

// ─── Linux: freedesktop.org trash spec ───────────────────────────────────────

const trashLinux = if (builtin.os.tag == .linux) struct {
    fn call(allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
        const home = c.getenv("HOME") orelse return error.NoHome;
        const home_s = std.mem.span(home);
        const files_dir = try std.fmt.allocPrint(allocator, "{s}/.local/share/Trash/files", .{home_s});
        defer allocator.free(files_dir);
        const info_dir = try std.fmt.allocPrint(allocator, "{s}/.local/share/Trash/info", .{home_s});
        defer allocator.free(info_dir);

        // Ensure directories exist
        const files_z = try allocator.dupeZ(u8, files_dir);
        defer allocator.free(files_z);
        _ = c.mkdir(files_z, 0o700);
        const info_dir_z = try allocator.dupeZ(u8, info_dir);
        defer allocator.free(info_dir_z);
        _ = c.mkdir(info_dir_z, 0o700);

        // Determine trash filename (handle collisions)
        const basename = std.fs.path.basename(path);
        var final_name = try allocator.dupe(u8, basename);

        var suffix: u32 = 2;
        while (true) {
            const dest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ files_dir, final_name });
            defer allocator.free(dest);
            const dest_z = try allocator.dupeZ(u8, dest);
            defer allocator.free(dest_z);
            if (c.access(dest_z, 0) == 0) {
                allocator.free(final_name);
                final_name = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ basename, suffix });
                suffix += 1;
                if (suffix > 10000) return error.TooManyCollisions;
            } else break;
        }

        // Move the file
        const dest_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ files_dir, final_name });
        defer allocator.free(dest_path);

        const src_z = try allocator.dupeZ(u8, path);
        defer allocator.free(src_z);
        const dst_z = try allocator.dupeZ(u8, dest_path);
        defer allocator.free(dst_z);

        if (c.rename(src_z, dst_z) != 0) return error.RenameFailed;

        // Write .trashinfo
        const info_file = try std.fmt.allocPrint(allocator, "{s}/{s}.trashinfo", .{ info_dir, final_name });
        defer allocator.free(info_file);

        const now = timestampToIso8601();
        const content = try std.fmt.allocPrint(allocator, "[Trash Info]\nPath={s}\nDeletionDate={s}\n", .{ path, &now });
        defer allocator.free(content);

        const info_file_z = try allocator.dupeZ(u8, info_file);
        defer allocator.free(info_file_z);

        // Write using C file API
        const fp = c.fopen(info_file_z, "w") orelse return error.FileOpenFailed;
        _ = c.fwrite(content.ptr, 1, content.len, fp);
        _ = c.fclose(fp);

        return final_name;
    }
}.call else unreachable;

// ═══════════════════════════════════════════════════════════════════════════════
// Metadata: .trashinfo read/write
// ═══════════════════════════════════════════════════════════════════════════════

const TrashEntry = struct {
    original_path: []const u8,
    date_str: []const u8,
    timestamp: ?i64,
    trash_name: ?[]const u8,

    fn deinit(self: *TrashEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.original_path);
        allocator.free(self.date_str);
        if (self.trash_name) |tn| allocator.free(tn);
    }
};

fn writeTrashInfo(allocator: std.mem.Allocator, io: Io, trash_filename: []const u8, original_path: []const u8) !void {
    // On Linux, trashLinux already writes .trashinfo — skip
    if (comptime builtin.os.tag == .linux) return;

    const info_path = getInfoDir(allocator) orelse return error.NoInfoDir;
    defer allocator.free(info_path);

    // Ensure metadata directory exists
    Dir.createDirAbsolute(io, info_path, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}.trashinfo", .{ info_path, trash_filename });
    defer allocator.free(file_path);

    const now = timestampToIso8601();
    const content = try std.fmt.allocPrint(allocator, "[Trash Info]\nPath={s}\nDeletionDate={s}\n", .{ original_path, &now });
    defer allocator.free(content);

    const file = Dir.createFileAbsolute(io, file_path, .{}) catch return;
    defer file.close(io);
    file.writeStreamingAll(io, content) catch {};
}

fn readTrashInfo(allocator: std.mem.Allocator, io: Io, path: []const u8) ?TrashEntry {
    _ = io;
    // Use C file API for simplicity — .trashinfo files are tiny
    const path_z = allocator.dupeZ(u8, path) catch return null;
    defer allocator.free(path_z);

    const fp = c.fopen(path_z, "r") orelse return null;
    defer _ = c.fclose(fp);

    var buf: [4096]u8 = undefined;
    const total = c.fread(&buf, 1, buf.len, fp);
    if (total == 0) return null;
    const content = buf[0..total];

    var original_path: ?[]const u8 = null;
    var date_str: ?[]const u8 = null;

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "Path=")) {
            original_path = allocator.dupe(u8, line["Path=".len..]) catch null;
        } else if (std.mem.startsWith(u8, line, "DeletionDate=")) {
            date_str = allocator.dupe(u8, line["DeletionDate=".len..]) catch null;
        }
    }

    const op = original_path orelse return null;
    const ds = date_str orelse {
        allocator.free(op);
        return null;
    };

    return .{
        .original_path = op,
        .date_str = ds,
        .timestamp = parseIso8601(ds),
        .trash_name = null,
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
// Platform helpers
// ═══════════════════════════════════════════════════════════════════════════════

fn getTrashDir(allocator: std.mem.Allocator) ?[]const u8 {
    const home = std.mem.span(c.getenv("HOME") orelse return null);
    if (comptime builtin.os.tag == .macos) {
        return std.fmt.allocPrint(allocator, "{s}/.Trash", .{home}) catch null;
    } else {
        return std.fmt.allocPrint(allocator, "{s}/.local/share/Trash/files", .{home}) catch null;
    }
}

fn getInfoDir(allocator: std.mem.Allocator) ?[]const u8 {
    const home = std.mem.span(c.getenv("HOME") orelse return null);
    if (comptime builtin.os.tag == .macos) {
        return std.fmt.allocPrint(allocator, "{s}/.Trash/.trash-metadata", .{home}) catch null;
    } else {
        return std.fmt.allocPrint(allocator, "{s}/.local/share/Trash/info", .{home}) catch null;
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Time helpers
// ═══════════════════════════════════════════════════════════════════════════════

extern "c" fn time(tloc: ?*c.time_t) c.time_t;
extern "c" fn localtime(timer: *const c.time_t) ?*const extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};

fn timestampToIso8601() [19]u8 {
    var t: c.time_t = undefined;
    _ = time(&t);
    const tm = localtime(&t);
    var buf: [19]u8 = undefined;
    if (tm) |lt| {
        _ = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
            @as(u32, @intCast(lt.tm_year + 1900)),
            @as(u32, @intCast(lt.tm_mon + 1)),
            @as(u32, @intCast(lt.tm_mday)),
            @as(u32, @intCast(lt.tm_hour)),
            @as(u32, @intCast(lt.tm_min)),
            @as(u32, @intCast(lt.tm_sec)),
        }) catch {};
    } else {
        @memcpy(&buf, "1970-01-01T00:00:00");
    }
    return buf;
}

fn parseIso8601(s: []const u8) ?i64 {
    if (s.len < 19) return null;
    const year = std.fmt.parseInt(u32, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u32, s[5..7], 10) catch return null;
    const mday = std.fmt.parseInt(u32, s[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u32, s[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u32, s[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u32, s[17..19], 10) catch return null;

    // Approximate timestamp for age comparison
    const y = if (year >= 1970) year - 1970 else return null;
    const days: i64 = @as(i64, @intCast(y)) * 365 + @as(i64, @intCast(y / 4)) -
        @as(i64, @intCast(y / 100)) + @as(i64, @intCast(y / 400));
    const month_days = [_]u32{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
    const m_days: i64 = if (month >= 1 and month <= 12) @intCast(month_days[month - 1]) else return null;
    const total_days = days + m_days + @as(i64, @intCast(mday)) - 1;

    return total_days * 86400 + @as(i64, @intCast(hour)) * 3600 +
        @as(i64, @intCast(minute)) * 60 + @as(i64, @intCast(second));
}

fn parseAge(s: []const u8) ?i64 {
    if (s.len < 2) return null;
    const unit = s[s.len - 1];
    const num = std.fmt.parseInt(i64, s[0 .. s.len - 1], 10) catch return null;
    return switch (unit) {
        'd' => num * 86400,
        'h' => num * 3600,
        'm' => num * 60,
        else => null,
    };
}

fn humanSize(bytes: u64, buf: []u8) []const u8 {
    const f: f64 = @floatFromInt(bytes);
    if (bytes < 1024) {
        return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "? B";
    } else if (bytes < 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.1} KiB", .{f / 1024.0}) catch "? KiB";
    } else if (bytes < 1024 * 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.1} MiB", .{f / (1024.0 * 1024.0)}) catch "? MiB";
    } else {
        return std.fmt.bufPrint(buf, "{d:.2} GiB", .{f / (1024.0 * 1024.0 * 1024.0)}) catch "? GiB";
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Output helpers
// ═══════════════════════════════════════════════════════════════════════════════

fn allocPrintZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    const z = try allocator.dupeZ(u8, s);
    allocator.free(s);
    return z;
}

fn wOut(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = c.write(1, s.ptr, s.len);
}

fn wErr(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = c.write(2, s.ptr, s.len);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Help
// ═══════════════════════════════════════════════════════════════════════════════

fn printHelp(io: Io) void {
    _ = io;
    const help =
        \\trash — move files to the system trash, and manage trash contents
        \\
        \\USAGE:
        \\    trash [OPTIONS] <path>...          Send files to trash
        \\    trash list [OPTIONS]               List trashed items
        \\    trash size [--bytes]               Show total trash size
        \\    trash empty [OPTIONS]              Permanently delete trash
        \\    trash restore <pattern>            Restore from trash
        \\
        \\OPTIONS (send-to-trash):
        \\    -n, --dry-run   Show what would be trashed without doing it
        \\    -v, --verbose   Print each path as it is trashed
        \\    -f, --force     Ignore missing files (no error)
        \\    -r              Accepted for rm compatibility (directories always work)
        \\    -h, --help      Show this help
        \\    -V, --version   Show version
        \\
        \\LIST OPTIONS:
        \\    --older <age>   Filter by age (e.g. 7d, 24h, 30m)
        \\    --project       Only items from current directory tree
        \\    --json          Machine-readable JSON output
        \\
        \\EMPTY OPTIONS:
        \\    --older <age>   Only delete items older than age
        \\    --yes, -y       Skip confirmation prompt
        \\
        \\RESTORE OPTIONS:
        \\    --to <path>     Restore to a different location
        \\
        \\EXAMPLES:
        \\    trash file.txt                     # trash a file
        \\    trash -v src/old/ tmp/*.log        # trash dir + glob, verbose
        \\    trash list                         # see what's in trash
        \\    trash list --older 7d --json       # old items as JSON
        \\    trash list --project               # only items from cwd
        \\    trash size                         # total trash size
        \\    trash empty --older 7d --yes       # purge week-old items
        \\    trash empty --yes                  # purge everything
        \\    trash restore myfile               # restore by name match
        \\    trash restore myfile --to ./here   # restore to specific path
        \\
        \\PLATFORMS:
        \\    macOS    Finder Trash (Cmd+Z to undo)
        \\    Linux    freedesktop.org trash spec
        \\
    ;
    _ = c.write(1, help.ptr, help.len);
}
