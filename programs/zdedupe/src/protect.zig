//! Locations a delete never touches.
//!
//! A scan may be pointed at a whole disk, and a duplicate inside the operating
//! system, an application bundle or a repository's object store is not a copy
//! anyone can spare: removing it breaks the thing it belongs to, whatever copy
//! survives elsewhere. So these paths are still scanned and still shown, but
//! every way of deleting — the bulk rule, a hand-ticked file, a folder — skips
//! them. The built-in list cannot be switched off; a host can only add to it.
//!
//! **Temp areas.** Build output inside a temporary area (`tempAreaOf`: macOS
//! `/private/tmp` and each account's `/private/var/folders/<a>/<b>/T`, Linux
//! `/tmp` and `/var/tmp`, Windows `%TEMP%`) is not protected by where it is:
//! a build folder there (buildrule.zig decides) and everything inside it.
//! Everything else in a temp area, the area itself, its other folders and
//! its loose files, stays exactly as protected as before, and so does
//! anything the other rules protect (a repository store, a package, a root
//! the user added). Only when every folder between the area and the path is
//! a real folder, not a link, so a path through a link never borrows the
//! exception.
//!
//! Matching is over raw path bytes and allocates nothing. The exception
//! alone looks at the disk, through `Protection.build_output`; without one
//! there is no exception.

const std = @import("std");
const filters = @import("filters.zig");
const types = @import("types.zig");

/// Operating-system and application trees, as absolute roots. One list for
/// every platform: a macOS root that does not exist on Linux costs a compare.
pub const system_roots = [_][]const u8{
    // macOS
    "/System",
    "/Library",
    "/Applications",
    "/private",
    "/cores",
    // Shared Unix
    "/usr",
    "/bin",
    "/sbin",
    "/opt",
    "/etc",
    // Linux
    "/lib",
    "/lib32",
    "/lib64",
    "/libx32",
    "/boot",
    "/var/lib",
    "/snap",
    "/nix",
};

/// Windows system locations, as they sit below any drive root (`C:/`,
/// `D:/`): the OS, installed programs, per-drive system areas and the paging
/// and hibernation files. Matched ignoring case, as NTFS names are.
pub const windows_drive_roots = [_][]const u8{
    "/Windows",
    "/Program Files",
    "/Program Files (x86)",
    "/ProgramData",
    "/System Volume Information",
    "/$Recycle.Bin",
    "/Recovery",
    "/Boot",
    "/EFI",
    "/pagefile.sys",
    "/hiberfil.sys",
    "/swapfile.sys",
};

const windows = @import("builtin").os.tag == .windows;

/// Roots relative to the user's home directory: per-user application data
/// that apps expect to find byte for byte where they left it. `AppData` is
/// Windows' `Library`.
pub const home_roots = [_][]const u8{
    "Library",
    "AppData",
    ".local/share/flatpak",
    ".var/app",
};

/// A path component with exactly this name puts everything below it out of
/// reach: a repository's own store. Deleting one object from `.git` corrupts
/// the repository even though "the same bytes" exist in another clone.
pub const component_names = [_][]const u8{ ".git", ".svn", ".hg", ".bzr" };

/// A directory whose name ends like this is a package: an app, a framework, a
/// plug-in. Its contents are signed and read at fixed paths. Compared
/// ASCII-case-insensitively, as the macOS file system does.
pub const package_suffixes = [_][]const u8{
    ".app",
    ".framework",
    ".bundle",
    ".plugin",
    ".appex",
    ".xpc",
    ".kext",
    ".prefpane",
    ".qlgenerator",
    ".mdimporter",
    ".component",
    ".vst",
    ".vst3",
    ".aaxplugin",
} ++ types.Config.app_library_suffixes;

/// What a path is on disk, as the temp-area exception needs to know.
pub const Place = enum {
    /// A file, a link, or nothing at all.
    other,
    /// A real folder that is not build output.
    folder,
    /// A real folder the build-output rule recognises.
    build_output,
};

/// Answers `Place` for a path; buildrule.zig provides the real one.
pub const BuildOutput = struct {
    ctx: ?*anyopaque = null,
    /// What `path` is on disk. With `rule` false only whether it is a real
    /// folder is asked, and any real folder may answer `.folder`.
    classify: *const fn (ctx: ?*anyopaque, path: []const u8, rule: bool) Place,
};

/// The temporary area `path` lies in (the area's own path, a prefix of
/// `path`), or null. Real paths: macOS `/tmp` is `/private/tmp`.
pub fn tempAreaOf(home: ?[]const u8, path: []const u8) ?[]const u8 {
    for ([_][]const u8{ "/private/tmp", "/tmp", "/var/tmp" }) |area| {
        if (filters.isAtOrUnder(path, area)) return path[0..area.len];
    }
    // Each account's own: /private/var/folders/<a>/<b>/T, which is $TMPDIR
    // (its siblings C and 0 are caches and state, not temporary).
    const folders = "/private/var/folders/";
    if (std.mem.startsWith(u8, path, folders)) {
        var parts = std.mem.splitScalar(u8, path[folders.len..], '/');
        const a = parts.next() orelse return null;
        const b = parts.next() orelse return null;
        const t = parts.next() orelse return null;
        if (a.len > 0 and b.len > 0 and std.mem.eql(u8, t, "T")) return path[0 .. folders.len + a.len + 1 + b.len + 1 + 1];
    }
    // %TEMP%: <home>/AppData/Local/Temp, compared as NTFS compares names.
    if (windows) {
        const h = home orelse return null;
        const tail = "/AppData/Local/Temp";
        if (path.len < h.len + tail.len) return null;
        if (!std.ascii.eqlIgnoreCase(path[0..h.len], h)) return null;
        if (!std.ascii.eqlIgnoreCase(path[h.len..][0..tail.len], tail)) return null;
        const end = h.len + tail.len;
        if (path.len == end or path[end] == '/') return path[0..end];
    }
    return null;
}

pub const Protection = struct {
    /// The user's home directory, without a trailing slash; null when unknown,
    /// which leaves `home_roots` unenforced.
    home: ?[]const u8 = null,
    /// Absolute roots the user added. Borrowed.
    user: []const []const u8 = &.{},
    /// The build-output rule on disk, for the temp-area exception; null
    /// leaves every temp area as protected as the rest of its tree.
    build_output: ?BuildOutput = null,

    /// True when a delete must leave `path` alone.
    pub fn protects(self: *const Protection, path: []const u8) bool {
        if (protectedPlace(self.home, path) and !self.tempBuildOutput(path)) return true;
        for (self.user) |root| {
            if (filters.isAtOrUnder(path, root)) return true;
        }
        for (types.Config.app_library_dirs) |dirs| {
            if (containsDirs(path, dirs)) return true;
        }
        return inProtectedComponent(path);
    }

    /// `path` is build output inside a temp area, or inside build output
    /// there, with only real folders between the area and it.
    /// Not inlined: inside `protects` it slows every path's other checks,
    /// and it runs only for paths in protected places.
    noinline fn tempBuildOutput(self: *const Protection, path: []const u8) bool {
        const rule = self.build_output orelse return false;
        const area = tempAreaOf(self.home, path) orelse return false;
        if (path.len <= area.len + 1) return false;
        var found = false;
        // The folders between the area and the item, nearest the area first.
        // Each must be a real folder; below a build folder that is all that
        // is asked of them.
        var end = area.len;
        while (std.mem.indexOfScalarPos(u8, path, end + 1, '/')) |slash| {
            switch (rule.classify(rule.ctx, path[0..slash], !found)) {
                .build_output => found = true,
                .folder => {},
                .other => return false,
            }
            end = slash;
        }
        // The item itself, when nothing above it is: a folder may be build
        // output, a file or a link never is.
        if (!found) found = rule.classify(rule.ctx, path, true) == .build_output;
        return found;
    }

    /// True when deleting the folder `dir` would take a protected location
    /// with it: the folder is protected, or a protected root lies inside it
    /// (a system root, the home folder, a per-user root, a game library where
    /// it sits in the home folder, a root the user added). Repository stores
    /// and packages inside a folder do not count — deleting a whole backup
    /// copy of a project, `.git` and all, is the point of the folder view. A
    /// game library elsewhere (`steamapps` on another drive) can only be seen
    /// in a scanned tree, which marks the folders above it.
    pub fn guardsFolder(self: *const Protection, dir: []const u8) bool {
        if (self.protects(dir)) return true;
        for (system_roots) |root| {
            if (filters.isAtOrUnder(root, dir)) return true;
        }
        if (windows) {
            // A drive root, or a folder holding one of its system locations.
            if (belowDrive(dir)) |rest| {
                for (windows_drive_roots) |root| {
                    if (atOrUnderIgnoreCase(root, rest)) return true;
                }
            }
        }
        if (self.home) |home| {
            if (filters.isAtOrUnder(home, dir)) return true;
            for (home_roots) |root| {
                if (holdsBelowHome(home, root, dir)) return true;
            }
            for (types.Config.app_library_dirs) |dirs| {
                if (holdsBelowHome(home, dirs[1..], dir)) return true;
            }
        }
        for (self.user) |root| {
            if (filters.isAtOrUnder(root, dir)) return true;
        }
        return false;
    }
};

/// `path` lies in an operating-system tree or a per-user application tree.
fn protectedPlace(home: ?[]const u8, path: []const u8) bool {
    for (system_roots) |root| {
        if (filters.isAtOrUnder(path, root)) return true;
    }
    if (windows) {
        if (belowDrive(path)) |rest| {
            for (windows_drive_roots) |root| {
                if (atOrUnderIgnoreCase(rest, root)) return true;
            }
        }
    }
    if (home) |h| {
        if (filters.isAtOrUnder(path, h) and path.len > h.len + 1) {
            const rest = path[h.len + 1 ..];
            for (home_roots) |root| {
                if (filters.isAtOrUnder(rest, root)) return true;
            }
        }
    }
    return false;
}

/// `home/rel` lies at or below `dir`, a folder inside the home folder.
fn holdsBelowHome(home: []const u8, rel: []const u8, dir: []const u8) bool {
    if (dir.len <= home.len + 1 or !filters.isAtOrUnder(dir, home)) return false;
    return filters.isAtOrUnder(rel, dir[home.len + 1 ..]);
}

/// The part of a drive path after its letter: `C:/Windows/x` -> `/Windows/x`,
/// `C:/` -> `/`. Null for anything else.
fn belowDrive(path: []const u8) ?[]const u8 {
    if (filters.rootLen(path) != 3) return null;
    return path[2..];
}

/// `filters.isAtOrUnder`, ignoring ASCII case.
fn atOrUnderIgnoreCase(path: []const u8, base_in: []const u8) bool {
    const base = if (base_in.len > 1 and base_in[base_in.len - 1] == '/') base_in[0 .. base_in.len - 1] else base_in;
    if (base.len == 1 and base[0] == '/') return path.len > 0 and path[0] == '/';
    if (path.len < base.len or !std.ascii.eqlIgnoreCase(path[0..base.len], base)) return false;
    return path.len == base.len or path[base.len] == '/';
}

/// `dirs` (which starts with a slash) appears in `path` as whole components:
/// `/g/steamapps/common/x` and `/g/steamapps` both contain `/steamapps`.
fn containsDirs(path: []const u8, dirs: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, path, from, dirs)) |at| {
        const end = at + dirs.len;
        if (end == path.len or path[end] == '/') return true;
        from = at + 1;
    }
    return false;
}

/// A repository store anywhere in the path, the file itself included (a
/// worktree's `.git` is a file), or a package directory above the file.
fn inProtectedComponent(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    var last: []const u8 = "";
    var dirs_seen = false;
    while (it.next()) |part| {
        if (part.len == 0) continue;
        for (component_names) |name| {
            if (std.mem.eql(u8, part, name)) return true;
        }
        // Checked one step behind, so the file's own name is never taken for
        // a package: a download called `Tool.app` next to nothing is a file.
        if (dirs_seen and isPackage(last)) return true;
        last = part;
        dirs_seen = true;
    }
    return false;
}

fn isPackage(name: []const u8) bool {
    for (package_suffixes) |suffix| {
        if (name.len > suffix.len and std.ascii.endsWithIgnoreCase(name, suffix)) return true;
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "system roots are protected by whole components" {
    const p: Protection = .{};
    try testing.expect(p.protects("/usr/lib/libc.so"));
    try testing.expect(p.protects("/Applications/Foo.app/Contents/x"));
    try testing.expect(p.protects("/System/Library/x"));
    try testing.expect(!p.protects("/usrlocal/x"));
    try testing.expect(!p.protects("/home/u/Downloads/libc.so"));
}

test "home roots need a known home" {
    const without: Protection = .{};
    try testing.expect(!without.protects("/Users/u/Library/Caches/x"));
    const with: Protection = .{ .home = "/Users/u" };
    try testing.expect(with.protects("/Users/u/Library/Caches/x"));
    try testing.expect(!with.protects("/Users/u/LibraryBackup/x"));
    try testing.expect(!with.protects("/Users/u/Documents/Library/x"));
    try testing.expect(!with.protects("/Users/other/Library/x"));
}

test "repository stores and packages anywhere" {
    const p: Protection = .{};
    try testing.expect(p.protects("/home/u/proj/.git/objects/ab/cdef"));
    try testing.expect(p.protects("/home/u/wt/.git"));
    try testing.expect(p.protects("/home/u/Downloads/Tool.app/Contents/MacOS/tool"));
    try testing.expect(p.protects("/Volumes/x/Pics.photoslibrary/originals/a.jpg"));
    try testing.expect(p.protects("/mnt/Games/steamapps/common/g/data.pak"));
    try testing.expect(p.protects("/mnt/Games/steamapps"));
    try testing.expect(p.protects("/home/u/.local/share/Steam"));
    try testing.expect(!p.protects("/mnt/Games"));
    // The file's own name is not a package, and look-alikes are not stores.
    try testing.expect(!p.protects("/home/u/Downloads/Tool.app"));
    try testing.expect(!p.protects("/home/u/proj/.gitignore"));
    try testing.expect(!p.protects("/home/u/notsteamapps/x"));
    try testing.expect(!p.protects("/home/u/.app/x"));
}

test "user roots add to the list" {
    const user = [_][]const u8{"/data/masters"};
    const p: Protection = .{ .user = &user };
    try testing.expect(p.protects("/data/masters/a.wav"));
    try testing.expect(!p.protects("/data/mastersheet/a.wav"));
}

test "a folder that holds a protected root is guarded" {
    const user = [_][]const u8{"/data/masters"};
    const p: Protection = .{ .home = "/Users/u", .user = &user };
    try testing.expect(p.guardsFolder("/"));
    try testing.expect(p.guardsFolder("/Users"));
    try testing.expect(p.guardsFolder("/data"));
    try testing.expect(p.guardsFolder("/Users/u/Library/Application Support"));
    try testing.expect(!p.guardsFolder("/Users/u/work/proj-backup"));
    // A whole project copy, repository included, is a folder anyone may drop.
    try testing.expect(!p.guardsFolder("/Users/u/old/proj"));
}

test "a folder holding a per-user root or a game library in the home folder is guarded" {
    const p: Protection = .{ .home = "/home/u" };
    try testing.expect(p.guardsFolder("/home/u/.local"));
    try testing.expect(p.guardsFolder("/home/u/.local/share"));
    try testing.expect(p.guardsFolder("/home/u/.local/share/Steam"));
    try testing.expect(p.guardsFolder("/home/u/.var"));
    try testing.expect(!p.guardsFolder("/home/u/.local/bin"));
    try testing.expect(!p.guardsFolder("/home/u/.localstuff"));
    try testing.expect(!p.guardsFolder("/home/u/Documents"));
    // Only by path where the home folder puts it; elsewhere the scanned tree
    // says what a folder holds.
    try testing.expect(!p.guardsFolder("/mnt/Games"));
}

test "Windows system locations are protected on every drive, whatever the case" {
    if (!windows) return error.SkipZigTest;
    const t = std.testing;
    const p: Protection = .{ .home = "C:/Users/rich" };
    try t.expect(p.protects("C:/Windows/System32/kernel32.dll"));
    try t.expect(p.protects("C:/windows/notepad.exe"));
    try t.expect(p.protects("D:/System Volume Information/x"));
    try t.expect(p.protects("C:/Program Files (x86)/App/a.dll"));
    try t.expect(p.protects("C:/pagefile.sys"));
    try t.expect(p.protects("C:/Users/rich/AppData/Local/x.db"));
    try t.expect(!p.protects("C:/Users/rich/Documents/a.pdf"));
    try t.expect(!p.protects("C:/Windowsx/a"));
    try t.expect(p.guardsFolder("C:/"));
    try t.expect(p.guardsFolder("C:/Users"));
    try t.expect(!p.guardsFolder("C:/Users/rich/Documents"));
}

/// A disk where `build` lists the build folders, `links` the links and
/// `files` the files; every other path is a real folder.
const FakeDisk = struct {
    build: []const []const u8 = &.{},
    links: []const []const u8 = &.{},
    files: []const []const u8 = &.{},

    fn hook(self: *const FakeDisk) BuildOutput {
        return .{ .ctx = @constCast(self), .classify = classify };
    }

    fn classify(ctx: ?*anyopaque, path: []const u8, _: bool) Place {
        const self: *const FakeDisk = @ptrCast(@alignCast(ctx.?));
        for (self.build) |b| if (std.mem.eql(u8, b, path)) return .build_output;
        for (self.links) |l| if (std.mem.eql(u8, l, path)) return .other;
        for (self.files) |f| if (std.mem.eql(u8, f, path)) return .other;
        return .folder;
    }
};

test "temp areas, by real path" {
    try testing.expectEqualStrings("/private/tmp", tempAreaOf(null, "/private/tmp/x/node_modules").?);
    try testing.expectEqualStrings("/private/var/folders/ab/cd123/T", tempAreaOf(null, "/private/var/folders/ab/cd123/T/zig/o").?);
    try testing.expectEqualStrings("/tmp", tempAreaOf(null, "/tmp/build").?);
    try testing.expectEqualStrings("/var/tmp", tempAreaOf(null, "/var/tmp/x").?);
    // The caches and state beside T are not temporary.
    try testing.expect(tempAreaOf(null, "/private/var/folders/ab/cd123/C/x") == null);
    try testing.expect(tempAreaOf(null, "/private/var/folders/ab/T/x") == null);
    try testing.expect(tempAreaOf(null, "/private/tmpfoo/x") == null);
    try testing.expect(tempAreaOf(null, "/private/etc/x") == null);
}

test "build output in a temp area is not protected; the rest of it is" {
    const disk: FakeDisk = .{
        // A path through a link resolves past it: /private/tmp/s/link may lead
        // to /private/etc, whose node_modules is then a build folder by path.
        .build = &.{ "/private/tmp/s/app/node_modules", "/private/var/folders/ab/cd/T/w/zcache3", "/private/tmp/s/link/node_modules" },
        .links = &.{ "/private/tmp/s/link", "/private/tmp/s/link-to-build", "/private/tmp/s/app/node_modules/lnk" },
        .files = &.{ "/private/tmp/s/notes.txt", "/private/tmp/s/app/node_modules/a.js" },
    };
    const p: Protection = .{ .home = "/Users/u", .build_output = disk.hook() };
    const user_roots = [_][]const u8{"/private/tmp/s/app/node_modules/keep"};
    const with_user: Protection = .{ .home = "/Users/u", .user = &user_roots, .build_output = disk.hook() };

    // A build folder there, and anything inside one.
    try testing.expect(!p.protects("/private/tmp/s/app/node_modules"));
    try testing.expect(!p.protects("/private/tmp/s/app/node_modules/a.js"));
    try testing.expect(!p.protects("/private/tmp/s/app/node_modules/pkg/lib/x.js"));
    try testing.expect(!p.protects("/private/var/folders/ab/cd/T/w/zcache3/o/abc/lib.a"));
    try testing.expect(!p.guardsFolder("/private/tmp/s/app/node_modules"));
    // The area, its other folders and its loose files stay protected.
    try testing.expect(p.protects("/private/tmp"));
    try testing.expect(p.protects("/private/tmp/s"));
    try testing.expect(p.protects("/private/tmp/s/app"));
    try testing.expect(p.protects("/private/tmp/s/notes.txt"));
    try testing.expect(p.guardsFolder("/private/tmp/s/app"));
    // Other rules still hold inside build output.
    try testing.expect(p.protects("/private/tmp/s/app/node_modules/dep/.git/HEAD"));
    try testing.expect(p.protects("/private/tmp/s/app/node_modules/Tool.app/Contents/x"));
    try testing.expect(with_user.protects("/private/tmp/s/app/node_modules/keep/x"));
    try testing.expect(with_user.guardsFolder("/private/tmp/s/app/node_modules"));
    // A link above the path does not lend the exception, even one named
    // like build output (a link is never a build folder).
    try testing.expect(p.protects("/private/tmp/s/link/node_modules"));
    try testing.expect(p.protects("/private/tmp/s/link/node_modules/a.js"));
    try testing.expect(p.protects("/private/tmp/s/link-to-build/node_modules/a.js"));
    // Inside build output too: a link between the build folder and the item.
    try testing.expect(p.protects("/private/tmp/s/app/node_modules/lnk/a.js"));
    try testing.expect(!p.protects("/private/tmp/s/app/node_modules/lnk"));
    // Outside temp areas nothing changes: build output in /private/etc or
    // $TMPDIR's sibling caches stays protected.
    const etc: FakeDisk = .{ .build = &.{ "/private/etc/node_modules", "/private/var/folders/ab/cd/C/zcache" } };
    const p2: Protection = .{ .build_output = etc.hook() };
    try testing.expect(p2.protects("/private/etc/node_modules"));
    try testing.expect(p2.protects("/private/var/folders/ab/cd/C/zcache"));
    // Without the rule there is no exception.
    const bare: Protection = .{};
    try testing.expect(bare.protects("/private/tmp/s/app/node_modules"));
}

test "Windows: build output in %TEMP% is not protected, the rest of AppData is" {
    if (!windows) return error.SkipZigTest;
    const disk: FakeDisk = .{ .build = &.{ "C:/Users/rich/AppData/Local/Temp/w/node_modules", "C:/Users/rich/AppData/Local/x/node_modules" } };
    const p: Protection = .{ .home = "C:/Users/rich", .build_output = disk.hook() };
    try testing.expect(!p.protects("C:/Users/rich/AppData/Local/Temp/w/node_modules"));
    try testing.expectEqualStrings("C:/Users/rich/appdata/local/temp", tempAreaOf("C:/Users/rich", "C:/Users/rich/appdata/local/temp/w").?);
    try testing.expect(p.protects("C:/Users/rich/AppData/Local/Temp/w"));
    try testing.expect(p.protects("C:/Users/rich/AppData/Local/Temp"));
    try testing.expect(p.protects("C:/Users/rich/AppData/Local/x/node_modules"));
}
