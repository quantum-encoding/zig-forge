// `zigit remote` — manage `[remote "<name>"]` blocks in .git/config.
//
// Subcommands:
//
//   remote                          List remote names, one per line.
//   remote -v | --verbose           Same, but with two lines per remote:
//                                     <name>\t<url> (fetch)
//                                     <name>\t<pushurl-or-url> (push)
//                                   (Matches `git remote -v` byte-for-byte
//                                   when remote.<name>.pushurl is unset.)
//   remote add NAME URL             Add `[remote "NAME"]` with `url = URL`
//                                   and a default `fetch` refspec.
//   remote remove NAME              Drop every entry under [remote "NAME"].
//                                   `rm` is accepted as an alias.
//   remote show NAME                Print URL + fetch refspecs.
//
// We don't (yet):
//   * Support `set-url` (use add/remove) — trivial follow-up.
//   * Update remote-tracking refs on rename.
//   * Validate URLs.

const std = @import("std");
const Io = std.Io;
const File = Io.File;
const zigit = @import("zigit");

pub fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    var repo = try zigit.Repository.discover(allocator, io);
    defer repo.deinit();

    var cfg = try zigit.config.load(allocator, io, repo.git_dir);
    defer cfg.deinit();

    if (args.len == 0) {
        try listRemotes(allocator, io, &cfg, false);
        return;
    }

    const first = args[0];
    if (std.mem.eql(u8, first, "-v") or std.mem.eql(u8, first, "--verbose")) {
        try listRemotes(allocator, io, &cfg, true);
        return;
    }

    if (std.mem.eql(u8, first, "add")) {
        if (args.len != 3) return error.UsageRemoteAdd;
        try addRemote(allocator, io, &repo, &cfg, args[1], args[2]);
        return;
    }

    if (std.mem.eql(u8, first, "remove") or std.mem.eql(u8, first, "rm")) {
        if (args.len != 2) return error.UsageRemoteRemove;
        try removeRemote(allocator, io, &repo, &cfg, args[1]);
        return;
    }

    if (std.mem.eql(u8, first, "show")) {
        if (args.len != 2) return error.UsageRemoteShow;
        try showRemote(io, &cfg, args[1]);
        return;
    }

    return error.UnknownRemoteSubcommand;
}

fn listRemotes(allocator: std.mem.Allocator, io: Io, cfg: *const zigit.config.Config, verbose: bool) !void {
    const subs_const = try cfg.subsections(allocator, "remote");
    defer allocator.free(subs_const);

    // Real `git remote` lists remotes in lexicographic order, not in
    // .git/config insertion order. Copy into a mutable slice so we can
    // sort.
    const sorted = try allocator.dupe([]const u8, subs_const);
    defer allocator.free(sorted);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    const out = File.stdout();
    var buf: [1024]u8 = undefined;

    for (sorted) |name| {
        if (verbose) {
            const url_key = try std.fmt.allocPrint(allocator, "remote.{s}.url", .{name});
            defer allocator.free(url_key);
            const pushurl_key = try std.fmt.allocPrint(allocator, "remote.{s}.pushurl", .{name});
            defer allocator.free(pushurl_key);

            const fetch_url = cfg.get(url_key) orelse "";
            // Push URL defaults to the fetch URL when remote.<name>.pushurl
            // isn't explicitly set — matches git's behaviour.
            const push_url = cfg.get(pushurl_key) orelse fetch_url;

            const fetch_line = try std.fmt.bufPrint(&buf, "{s}\t{s} (fetch)\n", .{ name, fetch_url });
            try out.writeStreamingAll(io, fetch_line);
            const push_line = try std.fmt.bufPrint(&buf, "{s}\t{s} (push)\n", .{ name, push_url });
            try out.writeStreamingAll(io, push_line);
        } else {
            const line = try std.fmt.bufPrint(&buf, "{s}\n", .{name});
            try out.writeStreamingAll(io, line);
        }
    }
}

fn addRemote(
    allocator: std.mem.Allocator,
    io: Io,
    repo: *zigit.Repository,
    cfg: *zigit.config.Config,
    name: []const u8,
    url: []const u8,
) !void {
    const dotted = try std.fmt.allocPrint(allocator, "remote.{s}.url", .{name});
    defer allocator.free(dotted);
    if (cfg.get(dotted) != null) return error.RemoteAlreadyExists;

    try cfg.set("remote", name, "url", url);

    const fetch_spec = try std.fmt.allocPrint(allocator, "+refs/heads/*:refs/remotes/{s}/*", .{name});
    defer allocator.free(fetch_spec);
    try cfg.set("remote", name, "fetch", fetch_spec);

    try cfg.save(allocator, io, repo.git_dir);
}

fn removeRemote(
    allocator: std.mem.Allocator,
    io: Io,
    repo: *zigit.Repository,
    cfg: *zigit.config.Config,
    name: []const u8,
) !void {
    // Walk the entries list and remove every `remote.<name>.*`. The
    // dotted-key API expects a specific full key; we don't have a
    // pattern matcher, so do it manually here.
    var removed = false;
    var i: usize = 0;
    while (i < cfg.entries.items.len) {
        const e = cfg.entries.items[i];
        if (std.mem.eql(u8, e.section, "remote") and e.subsection != null and
            std.mem.eql(u8, e.subsection.?, name))
        {
            _ = cfg.entries.orderedRemove(i);
            removed = true;
        } else {
            i += 1;
        }
    }

    if (!removed) return error.RemoteNotFound;
    try cfg.save(allocator, io, repo.git_dir);
}

fn showRemote(io: Io, cfg: *const zigit.config.Config, name: []const u8) !void {
    var found = false;
    const out = File.stdout();
    var buf: [1024]u8 = undefined;

    for (cfg.entries.items) |e| {
        if (!std.mem.eql(u8, e.section, "remote")) continue;
        const sub = e.subsection orelse continue;
        if (!std.mem.eql(u8, sub, name)) continue;
        found = true;
        const line = try std.fmt.bufPrint(&buf, "{s} = {s}\n", .{ e.key, e.value });
        try out.writeStreamingAll(io, line);
    }

    if (!found) return error.RemoteNotFound;
}
