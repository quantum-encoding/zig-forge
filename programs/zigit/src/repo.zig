// Repository discovery and handle.
//
// `discover()` walks up from the current working directory looking
// for a .git/ child, the same way real git does. We don't yet
// support GIT_DIR, GIT_WORK_TREE, or worktree files — first slice
// only needs the simple case.
//
// Zig 0.16 IO model: every filesystem call takes an Io context, and
// directories carry the file-descriptor handle but the user owns the
// close. Repository.deinit closes both directory handles in order.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const object = @import("object/mod.zig");

pub const Repository = struct {
    allocator: std.mem.Allocator,
    io: Io,

    /// Absolute path to .git/. Owned.
    git_dir_path: []u8,

    git_dir: Dir,
    objects_dir: Dir,

    pub fn discover(allocator: std.mem.Allocator, io: Io) !Repository {
        var cwd_buf: [Dir.max_path_bytes]u8 = undefined;
        const cwd_len = try std.process.currentPath(io, &cwd_buf);

        // Walk up looking for a .git/ entry.
        var current: []const u8 = cwd_buf[0..cwd_len];
        while (true) {
            var trial_buf: [Dir.max_path_bytes]u8 = undefined;
            const trial = try std.fmt.bufPrint(&trial_buf, "{s}/.git", .{current});
            if (Dir.openDirAbsolute(io, trial, .{})) |found| {
                var git_dir = found;
                errdefer git_dir.close(io);
                var objects_dir = try git_dir.openDir(io, "objects", .{});
                errdefer objects_dir.close(io);

                const git_dir_owned = try allocator.dupe(u8, trial);
                return .{
                    .allocator = allocator,
                    .io = io,
                    .git_dir_path = git_dir_owned,
                    .git_dir = git_dir,
                    .objects_dir = objects_dir,
                };
            } else |err| switch (err) {
                error.FileNotFound, error.NotDir => {},
                else => return err,
            }

            // Advance to parent.
            const parent = std.fs.path.dirname(current) orelse return error.NotARepository;
            if (std.mem.eql(u8, parent, current)) return error.NotARepository;
            current = parent;
        }
    }

    pub fn deinit(self: *Repository) void {
        self.objects_dir.close(self.io);
        self.git_dir.close(self.io);
        self.allocator.free(self.git_dir_path);
        self.* = undefined;
    }

    pub fn looseStore(self: *Repository) object.LooseStore {
        return object.LooseStore.init(self.objects_dir, self.io);
    }
};
