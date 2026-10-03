//! Locations a delete never touches.
//!
//! A scan may be pointed at a whole disk, and a duplicate inside the operating
//! system, an application bundle or a repository's object store is not a copy
//! anyone can spare: removing it breaks the thing it belongs to, whatever copy
//! survives elsewhere. So these paths are still scanned and still shown, but
//! every way of deleting — the bulk rule, a hand-ticked file, a folder — skips
//! them. The built-in list cannot be switched off; a host can only add to it.
//!
//! Matching is over raw path bytes and allocates nothing.

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

pub const Protection = struct {
    /// The user's home directory, without a trailing slash; null when unknown,
    /// which leaves `home_roots` unenforced.
    home: ?[]const u8 = null,
    /// Absolute roots the user added. Borrowed.
    user: []const []const u8 = &.{},

    /// True when a delete must leave `path` alone.
    pub fn protects(self: *const Protection, path: []const u8) bool {
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
        if (self.home) |home| {
            if (filters.isAtOrUnder(path, home) and path.len > home.len + 1) {
                const rest = path[home.len + 1 ..];
                for (home_roots) |root| {
                    if (filters.isAtOrUnder(rest, root)) return true;
                }
            }
        }
        for (self.user) |root| {
            if (filters.isAtOrUnder(path, root)) return true;
        }
        for (types.Config.app_library_dirs) |dirs| {
            if (containsDirs(path, dirs)) return true;
        }
        return inProtectedComponent(path);
    }

    /// True when deleting the folder `dir` would take a protected location
    /// with it: the folder is protected, or a protected root lies inside it.
    /// Repository stores and packages inside a folder do not count — deleting
    /// a whole backup copy of a project, `.git` and all, is the point of the
    /// folder view.
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
        }
        for (self.user) |root| {
            if (filters.isAtOrUnder(root, dir)) return true;
        }
        return false;
    }
};

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

/// `dirs` (which starts with a slash) appears in `path` as whole components
/// followed by more path: `/g/steamapps/common/x` contains `/steamapps`.
fn containsDirs(path: []const u8, dirs: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, path, from, dirs)) |at| {
        const end = at + dirs.len;
        if (end < path.len and path[end] == '/') return true;
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
