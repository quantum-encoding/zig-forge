// Zigit CLI dispatch. Parses argv[1] to pick a subcommand and hands
// the rest of the arguments to that command's `run` function.
//
// Zig 0.16 ships a new `pub fn main(init: std.process.Init)` entry
// shape — `init.gpa`, `init.io`, and `init.minimal.args` are
// pre-built for us. We translate args into a flat `[]const []const u8`
// up front so subcommands don't have to know about iterators.

const std = @import("std");
const zigit = @import("zigit");

const init_cmd = @import("cli/init.zig");
const hash_object_cmd = @import("cli/hash_object.zig");
const cat_file_cmd = @import("cli/cat_file.zig");
const update_index_cmd = @import("cli/update_index.zig");
const ls_files_cmd = @import("cli/ls_files.zig");
const write_tree_cmd = @import("cli/write_tree.zig");
const commit_tree_cmd = @import("cli/commit_tree.zig");
const add_cmd = @import("cli/add.zig");
const commit_cmd = @import("cli/commit.zig");
const log_cmd = @import("cli/log.zig");
const status_cmd = @import("cli/status.zig");
const diff_cmd = @import("cli/diff.zig");
const branch_cmd = @import("cli/branch.zig");
const switch_cmd = @import("cli/switch.zig");
const checkout_cmd = @import("cli/checkout.zig");
const gc_cmd = @import("cli/gc.zig");
const clone_cmd = @import("cli/clone.zig");
const push_cmd = @import("cli/push.zig");
const merge_cmd = @import("cli/merge.zig");
const rebase_cmd = @import("cli/rebase.zig");
const restore_cmd = @import("cli/restore.zig");
const reset_cmd = @import("cli/reset.zig");
const tag_cmd = @import("cli/tag.zig");
const stash_cmd = @import("cli/stash.zig");
const remote_cmd = @import("cli/remote.zig");
const reflog_cmd = @import("cli/reflog.zig");
const prune_cmd = @import("cli/prune.zig");

const usage =
    \\zigit — git in zig
    \\
    \\Usage: zigit <command> [args]
    \\
    \\Plumbing:
    \\  init [path]                                   Initialise an empty repository
    \\  hash-object [-w] [-t kind] [--stdin] <file>   Compute the object hash
    \\  cat-file (-p|-t|-s|-e) <oid>                  Print, type, size, exists
    \\  update-index --add <file>...                  Stage files into the index
    \\  ls-files [-s|--stage]                         List indexed paths
    \\  write-tree                                    Persist the index as a tree, print oid
    \\  commit-tree TREE [-p PARENT]... -m MSG        Create a commit object, print oid
    \\
    \\Porcelain:
    \\  add <file>...                                 Stage files (wraps update-index --add)
    \\  commit -m <message>                           Snapshot index, advance HEAD's branch
    \\  log [-n N]                                    Walk first-parent chain from HEAD
    \\  status [-s|--porcelain]                       Show staged / unstaged / untracked changes
    \\  diff [--cached] [pathspec...]                 Unified diff: workdir vs index, or index vs HEAD
    \\  branch [-d|-D] [NAME [START]]                 List, create, or delete branches
    \\  switch [-c] NAME                              Move HEAD to branch, update workdir + index
    \\  checkout TARGET                               Branch name → switch; commit oid → detached HEAD
    \\  gc                                            Pack loose objects + refs into a single pack
    \\  clone URL [PATH]                              Read-only smart-HTTPS v2 clone
    \\  push URL [BRANCH]                             Push BRANCH (default = current) to URL
    \\  merge BRANCH                                  Fast-forward when possible, otherwise three-way
    \\  rebase ONTO                                   Replay HEAD's commits on top of ONTO
    \\  restore [--staged] PATH...                    Restore PATH(s) from index (or HEAD if --staged)
    \\  reset [--soft|--mixed|--hard] [TARGET]        Move HEAD ± rewrite index ± rewrite workdir
    \\  tag [-d] [NAME [COMMIT]]                      List, create, or delete lightweight tags
    \\  stash <push|list|pop|drop> [args]             Save/restore work-tree state
    \\  remote [-v|add|remove|show] [args]            Manage [remote "..."] entries
    \\  reflog [show [REF]]                           Show reflog (default HEAD)
    \\  prune [--dry-run]                             Delete unreferenced loose objects
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const environ = init.minimal.environ;

    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    if (args.len < 2) {
        try writeAll(io, .stderr, usage);
        std.process.exit(1);
    }

    const cmd = args[1];
    const rest = args[2..];

    if (std.mem.eql(u8, cmd, "init")) {
        try init_cmd.run(allocator, io, rest);
    } else if (std.mem.eql(u8, cmd, "hash-object")) {
        try hash_object_cmd.run(allocator, io, rest);
    } else if (std.mem.eql(u8, cmd, "cat-file")) {
        try cat_file_cmd.run(allocator, io, rest);
    } else if (std.mem.eql(u8, cmd, "update-index")) {
        try update_index_cmd.run(allocator, io, rest);
    } else if (std.mem.eql(u8, cmd, "ls-files")) {
        try ls_files_cmd.run(allocator, io, rest);
    } else if (std.mem.eql(u8, cmd, "write-tree")) {
        try write_tree_cmd.run(allocator, io, rest);
    } else if (std.mem.eql(u8, cmd, "commit-tree")) {
        try commit_tree_cmd.run(allocator, io, environ, rest);
    } else if (std.mem.eql(u8, cmd, "add")) {
        try add_cmd.run(allocator, io, rest);
    } else if (std.mem.eql(u8, cmd, "commit")) {
        try commit_cmd.run(allocator, io, environ, rest);
    } else if (std.mem.eql(u8, cmd, "log")) {
        try log_cmd.run(allocator, io, rest);
    } else if (std.mem.eql(u8, cmd, "status")) {
        try status_cmd.run(allocator, io, rest);
    } else if (std.mem.eql(u8, cmd, "diff")) {
        try diff_cmd.run(allocator, io, rest);
    } else if (std.mem.eql(u8, cmd, "branch")) {
        try branch_cmd.run(allocator, io, rest);
    } else if (std.mem.eql(u8, cmd, "switch")) {
        // The conflict-message has already been printed by switch
        // itself; we just want a clean exit code without Zig's
        // default error-trace dump.
        switch_cmd.run(allocator, io, environ, rest) catch |err| switch (err) {
            error.WouldLoseChanges => std.process.exit(1),
            else => return err,
        };
    } else if (std.mem.eql(u8, cmd, "checkout")) {
        checkout_cmd.run(allocator, io, rest) catch |err| switch (err) {
            error.WouldLoseChanges => std.process.exit(1),
            else => return err,
        };
    } else if (std.mem.eql(u8, cmd, "gc")) {
        try gc_cmd.run(allocator, io, rest);
    } else if (std.mem.eql(u8, cmd, "clone")) {
        clone_cmd.run(allocator, io, environ, rest) catch |err| switch (err) {
            error.SshTransportNotYetImplemented => {
                try writeAll(io, .stderr,
                    "zigit clone: ssh:// and git@host:path transports aren't implemented yet — use https:// for now.\n");
                std.process.exit(1);
            },
            error.GitTransportNotYetImplemented => {
                try writeAll(io, .stderr,
                    "zigit clone: git:// transport isn't implemented yet — use https:// for now.\n");
                std.process.exit(1);
            },
            else => return err,
        };
    } else if (std.mem.eql(u8, cmd, "push")) {
        try push_cmd.run(allocator, io, environ, rest);
    } else if (std.mem.eql(u8, cmd, "merge")) {
        merge_cmd.run(allocator, io, environ, rest) catch |err| switch (err) {
            error.MergeConflict => std.process.exit(1),
            else => return err,
        };
    } else if (std.mem.eql(u8, cmd, "rebase")) {
        rebase_cmd.run(allocator, io, environ, rest) catch |err| switch (err) {
            error.MergeConflict => std.process.exit(1),
            else => return err,
        };
    } else if (std.mem.eql(u8, cmd, "restore")) {
        restore_cmd.run(allocator, io, rest) catch |err| switch (err) {
            error.PathspecNotFound => std.process.exit(1),
            else => return err,
        };
    } else if (std.mem.eql(u8, cmd, "reset")) {
        try reset_cmd.run(allocator, io, environ, rest);
    } else if (std.mem.eql(u8, cmd, "tag")) {
        try tag_cmd.run(allocator, io, rest);
    } else if (std.mem.eql(u8, cmd, "stash")) {
        stash_cmd.run(allocator, io, environ, rest) catch |err| switch (err) {
            error.StashConflict => std.process.exit(1),
            else => return err,
        };
    } else if (std.mem.eql(u8, cmd, "prune")) {
        try prune_cmd.run(allocator, io, rest);
    } else if (std.mem.eql(u8, cmd, "reflog")) {
        reflog_cmd.run(allocator, io, rest) catch |err| switch (err) {
            error.NoReflogForRef => {
                try writeAll(io, .stderr, "zigit reflog: no reflog for that ref\n");
                std.process.exit(1);
            },
            else => return err,
        };
    } else if (std.mem.eql(u8, cmd, "remote")) {
        remote_cmd.run(allocator, io, rest) catch |err| switch (err) {
            error.RemoteNotFound,
            error.RemoteAlreadyExists,
            error.UsageRemoteAdd,
            error.UsageRemoteRemove,
            error.UsageRemoteShow,
            error.UnknownRemoteSubcommand,
            => {
                var buf: [256]u8 = undefined;
                const msg = try std.fmt.bufPrint(&buf, "zigit remote: {s}\n", .{@errorName(err)});
                try writeAll(io, .stderr, msg);
                std.process.exit(1);
            },
            else => return err,
        };
    } else if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try writeAll(io, .stdout, usage);
    } else {
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "zigit: unknown command '{s}'\n\n", .{cmd});
        try writeAll(io, .stderr, msg);
        try writeAll(io, .stderr, usage);
        std.process.exit(1);
    }
}

const Stream = enum { stdout, stderr };

fn writeAll(io: std.Io, stream: Stream, bytes: []const u8) !void {
    const file: std.Io.File = switch (stream) {
        .stdout => .stdout(),
        .stderr => .stderr(),
    };
    try file.writeStreamingAll(io, bytes);
}
