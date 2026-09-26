//! Disk space — where the bytes on a volume went
//!
//! A disk-space scan walks like a duplicate scan and stops there: no file is
//! opened, nothing is hashed. Every regular file the walk stat'ed is placed in
//! the folder tree, and every folder carries what its whole subtree adds up
//! to — files, bytes on disk, apparent bytes, and bytes per file type. That
//! tree is written into the result store (a blob behind `Header.space`, see
//! store.zig), and the results session answers the questions a disk-space view
//! asks of it: what is in this folder, largest first; what types and sizes of
//! file fill it; the largest files and folders anywhere below it.
//!
//! **Only the top of each level leaves the core.** A folder's children are
//! ranked in here and a host receives the first N plus one "everything else"
//! remainder, so a folder holding a million files costs the UI a few hundred
//! rows. A whole-disk scan stays a mapped file on disk, never a document.
//!
//! **Layout.** Folders are stored in preorder — sorted by path with `/` below
//! every other byte — so a folder's descendants are the contiguous run
//! `[i, subtree_end)`. Files are stored grouped by folder in that same order,
//! largest first within a folder, so a subtree's files are one contiguous run
//! too and "the largest files under X" is one linear pass over a slice.
//!
//! **What a byte means.** `bytes` is space on disk (allocated blocks): a
//! sparse or compressed file counts what it occupies, a cloud placeholder
//! whose content lives in iCloud counts (almost) nothing. `logical` is the
//! apparent size a file manager shows. Every inode counts once: of several
//! hard links the lexicographically smallest path holds the bytes and the
//! others are counted in `hard_links` only. APFS clones share blocks the
//! filesystem does not report, so a cloned file is counted in full.
//!
//! **What a scan never does.** It never opens a file, and on macOS it walks
//! with dataless materialization off (`FastWalker.setNoMaterialize`): a folder
//! that only exists in iCloud is reported unreadable instead of downloaded.
//! Symlinks are not followed, so a link cycle cannot loop the walk. What cannot
//! be read marks its folder `incomplete`, all the way up.
//!
//! **Types.** Seven categories: media, documents, code, archives,
//! applications, system, other. A file's extension decides, except inside a
//! folder that decides for everything it holds: an app bundle is applications
//! whatever its files are called, a dependency or VCS store (`node_modules`,
//! `.git`, `DerivedData`) is code, and the operating system's own trees are
//! system. The outermost such folder wins.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const fast_walker = @import("fast_walker.zig");
const store = @import("store.zig");
const filters = @import("filters.zig");
const removed_mod = @import("removed.zig");
const protect_mod = @import("protect.zig");
const session_mod = @import("session.zig");
const pstat = @import("pstat.zig");
const dedupe = @import("dedupe.zig");
const libc = std.c;

const Allocator = std.mem.Allocator;

// ===========================================================================
// Categories
// ===========================================================================

/// Numbering is part of the store format.
pub const Category = enum(u8) {
    media = 0,
    documents = 1,
    code = 2,
    archives = 3,
    applications = 4,
    system = 5,
    other = 6,
};
pub const category_count = @typeInfo(Category).@"enum".fields.len;

const by_extension = std.StaticStringMap(Category).initComptime(.{
    // Images, including camera raw and editor documents
    .{ "jpg", .media },      .{ "jpeg", .media },     .{ "png", .media },     .{ "gif", .media },
    .{ "heic", .media },     .{ "heif", .media },     .{ "webp", .media },    .{ "avif", .media },
    .{ "tif", .media },      .{ "tiff", .media },     .{ "bmp", .media },     .{ "svg", .media },
    .{ "ico", .media },      .{ "icns", .media },     .{ "psd", .media },     .{ "psb", .media },
    .{ "raw", .media },      .{ "cr2", .media },      .{ "cr3", .media },     .{ "nef", .media },
    .{ "arw", .media },      .{ "dng", .media },      .{ "orf", .media },     .{ "rw2", .media },
    .{ "raf", .media },      .{ "xcf", .media },      .{ "exr", .media },     .{ "hdr", .media },
    .{ "blend", .media },    .{ "obj", .media },      .{ "fbx", .media },     .{ "glb", .media },
    .{ "gltf", .media },     .{ "usdz", .media },     .{ "stl", .media },
    // Video
    .{ "mp4", .media },      .{ "m4v", .media },      .{ "mov", .media },     .{ "mkv", .media },
    .{ "avi", .media },      .{ "wmv", .media },      .{ "flv", .media },     .{ "webm", .media },
    .{ "mpg", .media },      .{ "mpeg", .media },     .{ "mts", .media },     .{ "m2ts", .media },
    .{ "3gp", .media },      .{ "braw", .media },     .{ "r3d", .media },     .{ "prproj", .media },
    .{ "fcpbundle", .media },
    // Audio
    .{ "mp3", .media },      .{ "m4a", .media },      .{ "aac", .media },     .{ "wav", .media },
    .{ "aif", .media },      .{ "aiff", .media },     .{ "flac", .media },    .{ "alac", .media },
    .{ "ogg", .media },      .{ "opus", .media },     .{ "wma", .media },     .{ "mid", .media },
    .{ "midi", .media },     .{ "caf", .media },      .{ "logicx", .media },  .{ "band", .media },
    // Documents
    .{ "pdf", .documents },  .{ "doc", .documents },  .{ "docx", .documents }, .{ "xls", .documents },
    .{ "xlsx", .documents }, .{ "ppt", .documents },  .{ "pptx", .documents }, .{ "pages", .documents },
    .{ "numbers", .documents }, .{ "key", .documents }, .{ "odt", .documents }, .{ "ods", .documents },
    .{ "odp", .documents },  .{ "rtf", .documents },  .{ "txt", .documents }, .{ "md", .documents },
    .{ "markdown", .documents }, .{ "epub", .documents }, .{ "mobi", .documents }, .{ "csv", .documents },
    .{ "tsv", .documents },  .{ "tex", .documents },  .{ "log", .documents }, .{ "eml", .documents },
    .{ "emlx", .documents }, .{ "mbox", .documents }, .{ "msg", .documents }, .{ "vcf", .documents },
    .{ "ics", .documents },  .{ "djvu", .documents }, .{ "xps", .documents },
    // Source, project and build files
    .{ "c", .code },         .{ "h", .code },         .{ "cc", .code },       .{ "cpp", .code },
    .{ "cxx", .code },       .{ "hpp", .code },       .{ "hh", .code },       .{ "m", .code },
    .{ "mm", .code },        .{ "swift", .code },     .{ "rs", .code },       .{ "zig", .code },
    .{ "go", .code },        .{ "py", .code },        .{ "pyc", .code },      .{ "ipynb", .code },
    .{ "js", .code },        .{ "mjs", .code },       .{ "cjs", .code },      .{ "ts", .code },
    .{ "tsx", .code },       .{ "jsx", .code },       .{ "svelte", .code },   .{ "vue", .code },
    .{ "java", .code },      .{ "class", .code },     .{ "jar", .code },      .{ "kt", .code },
    .{ "kts", .code },       .{ "scala", .code },     .{ "rb", .code },       .{ "php", .code },
    .{ "cs", .code },        .{ "fs", .code },        .{ "lua", .code },      .{ "dart", .code },
    .{ "sh", .code },        .{ "zsh", .code },       .{ "bash", .code },     .{ "fish", .code },
    .{ "ps1", .code },       .{ "pl", .code },        .{ "r", .code },        .{ "jl", .code },
    .{ "hs", .code },        .{ "ex", .code },        .{ "exs", .code },      .{ "erl", .code },
    .{ "clj", .code },       .{ "ml", .code },        .{ "nim", .code },      .{ "sql", .code },
    .{ "json", .code },      .{ "yaml", .code },      .{ "yml", .code },      .{ "toml", .code },
    .{ "xml", .code },       .{ "html", .code },      .{ "htm", .code },      .{ "css", .code },
    .{ "scss", .code },      .{ "sass", .code },      .{ "less", .code },     .{ "wasm", .code },
    .{ "o", .code },         .{ "a", .code },         .{ "lib", .code },      .{ "rlib", .code },
    .{ "rmeta", .code },     .{ "pdb", .code },       .{ "dsym", .code },     .{ "map", .code },
    .{ "lock", .code },      .{ "gradle", .code },    .{ "cmake", .code },    .{ "mk", .code },
    .{ "pbxproj", .code },   .{ "xcconfig", .code },  .{ "storyboard", .code }, .{ "xib", .code },
    .{ "pack", .code },      .{ "idx", .code },       .{ "gguf", .code },     .{ "safetensors", .code },
    .{ "onnx", .code },      .{ "mlmodel", .code },   .{ "pt", .code },       .{ "ckpt", .code },
    // Archives and disk images
    .{ "zip", .archives },   .{ "tar", .archives },   .{ "gz", .archives },   .{ "tgz", .archives },
    .{ "bz2", .archives },   .{ "tbz", .archives },   .{ "xz", .archives },   .{ "txz", .archives },
    .{ "zst", .archives },   .{ "lz4", .archives },   .{ "lzma", .archives }, .{ "7z", .archives },
    .{ "rar", .archives },   .{ "cab", .archives },   .{ "iso", .archives },  .{ "img", .archives },
    .{ "sparseimage", .archives }, .{ "sparsebundle", .archives }, .{ "vmdk", .archives }, .{ "vdi", .archives },
    .{ "qcow2", .archives }, .{ "vhd", .archives },   .{ "vhdx", .archives }, .{ "xar", .archives },
    .{ "cpio", .archives },  .{ "sit", .archives },   .{ "sitx", .archives }, .{ "zipx", .archives },
    .{ "bak", .archives },   .{ "backup", .archives },
    // Installers and applications
    .{ "dmg", .applications }, .{ "pkg", .applications }, .{ "mpkg", .applications }, .{ "exe", .applications },
    .{ "msi", .applications }, .{ "msix", .applications }, .{ "appx", .applications }, .{ "deb", .applications },
    .{ "rpm", .applications }, .{ "appimage", .applications }, .{ "flatpak", .applications }, .{ "snap", .applications },
    .{ "apk", .applications }, .{ "ipa", .applications }, .{ "xip", .applications },
    // Operating system and driver files
    .{ "dylib", .system },   .{ "so", .system },      .{ "dll", .system },    .{ "sys", .system },
    .{ "kext", .system },    .{ "drv", .system },     .{ "efi", .system },    .{ "vmem", .system },
});

/// The category a file name alone implies. A leading dot is a hidden file,
/// not an extension: `.bashrc` has none.
pub fn categoryOfName(name: []const u8) Category {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return .other;
    if (dot == 0) return .other;
    const ext = name[dot + 1 ..];
    var buf: [16]u8 = undefined;
    if (ext.len == 0 or ext.len > buf.len) return .other;
    return by_extension.get(std.ascii.lowerString(buf[0..ext.len], ext)) orelse .other;
}

/// A folder that decides the category of everything inside it.
const Context = enum(u8) { none, applications, code, system };

/// Bundles: signed packages read at fixed paths, whatever their files are.
const package_suffixes = [_][]const u8{
    ".app",       ".appex",     ".framework", ".bundle",      ".plugin",
    ".xpc",       ".prefpane",  ".qlgenerator", ".mdimporter", ".component",
    ".vst",       ".vst3",      ".aaxplugin", ".saver",       ".wdgt",
};

/// Dependency stores, build output and repository stores.
const code_dirs = [_][]const u8{
    ".git",         ".hg",          ".svn",          "node_modules", "bower_components",
    "DerivedData",  ".venv",        "venv",          "__pycache__",  ".gradle",
    ".m2",          ".cargo",       ".rustup",       ".npm",         ".pnpm-store",
    ".yarn",        ".zig-cache",   "zig-cache",     "zig-out",      "site-packages",
    "Pods",         ".build",       ".next",         ".nuxt",        ".svelte-kit",
    ".turbo",       ".tox",         ".mypy_cache",   ".pytest_cache", ".ruff_cache",
    ".parcel-cache",
};

/// The operating system's own trees.
const system_roots = [_][]const u8{
    "/System", "/Library", "/private", "/cores", "/usr",  "/bin", "/sbin", "/etc",
    "/var",    "/opt",     "/boot",    "/lib",   "/lib32", "/lib64", "/libx32", "/proc",
    "/sys",    "/dev",     "/run",     "/snap",  "/Windows",
};

fn contextOf(parent: Context, path: []const u8, name: []const u8, parent_name: []const u8) Context {
    if (parent != .none) return parent;
    for (package_suffixes) |suffix| {
        if (name.len > suffix.len and std.ascii.endsWithIgnoreCase(name, suffix)) return .applications;
    }
    for (code_dirs) |dir| {
        // zig-lens-ignore: EQL-FOR-SECRETS directory names, not secrets
        if (std.mem.eql(u8, name, dir)) return .code;
    }
    if (std.mem.eql(u8, path, "/Applications")) return .applications;
    for (system_roots) |root| {
        if (filters.isAtOrUnder(path, root)) return .system;
    }
    // Per-user caches and logs: ~/Library/Caches, ~/Library/Logs.
    if (std.mem.eql(u8, parent_name, "Library") and
        (std.mem.eql(u8, name, "Caches") or std.mem.eql(u8, name, "Logs"))) return .system;
    return .none;
}

fn categoryIn(context: Context, name: []const u8) Category {
    return switch (context) {
        .none => categoryOfName(name),
        .applications => .applications,
        .code => .code,
        .system => .system,
    };
}

// ===========================================================================
// Scanning
// ===========================================================================

pub const ScanConfig = struct {
    include_hidden: bool = true,
    /// Names pruned wherever they appear (credential stores, the user's own).
    excludes: []const []const u8 = &.{},
    exclude_paths: []const []const u8 = &.{},
    one_filesystem: bool = true,
    skip_app_libraries: bool = true,
    threads: u32 = 0,
    monitor: ?*types.Monitor = null,
};

/// Where macOS keeps the Data volume that `/` reaches through firmlinks.
const darwin_data_volume = "/System/Volumes/Data";

/// Walk `paths` and write a store holding their folder tree to `out_path`.
/// Roots that cannot be walked at all are counted in the store's
/// `failed_paths`.
pub fn scanToStore(gpa: Allocator, config: ScanConfig, paths: []const []const u8, out_path: []const u8) !void {
    const started = monotonicNs();

    var fw = fast_walker.FastWalker.init(gpa);
    defer fw.deinit();
    fw.setMonitor(config.monitor);
    fw.setIncludeHidden(config.include_hidden);
    fw.setOneFilesystem(config.one_filesystem);
    fw.setSkipAppLibraries(config.skip_app_libraries);
    fw.setThreads(config.threads);
    // Everything a folder holds, each inode once, links never followed, and
    // nothing in the cloud pulled down to be looked at.
    fw.enableTreeRecording();
    fw.setSizeFilter(0, 0);
    fw.setFollowSymlinks(false);
    fw.enableHardLinkDetection();
    fw.setNoMaterialize(true);
    fw.setExcludes(config.excludes);

    const roots = try dedupe.coveringRootsOf(gpa, paths);
    defer gpa.free(roots);

    // macOS `/` is the sealed system volume; the user's data lives on the Data
    // volume, joined in by firmlinks (/Users, /Applications, /private, ...).
    // Walked from `/`, both belong to the scan, and the Data volume's own
    // mount point is left out so nothing is counted twice.
    var exclude_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer exclude_paths.deinit(gpa);
    try exclude_paths.appendSlice(gpa, config.exclude_paths);
    if (comptime builtin.os.tag == .macos) {
        for (roots) |root| {
            if (!std.mem.eql(u8, root, "/")) continue;
            if (pstat.stat(darwin_data_volume)) |st| {
                try fw.allowDevice(st.dev);
                try exclude_paths.append(gpa, darwin_data_volume);
            } else |_| {}
            break;
        }
    }
    fw.setExcludePaths(exclude_paths.items);

    var failed: u64 = 0;
    for (roots) |root| {
        fw.walk(root) catch |err| switch (err) {
            error.OutOfMemory, error.Cancelled => return err,
            else => failed += 1,
        };
    }
    try fw.finish();

    if (config.monitor) |m| m.enter(.analyzing, 0);
    var tree = try build(gpa, .{
        .files = fw.files.items,
        .dirs = fw.dirs.items,
        .excluded = fw.stats.excluded,
        .errors = fw.stats.errors,
        .volume_of = if (roots.len > 0) roots[0] else null,
    });
    defer tree.deinit();
    if (config.monitor) |m| {
        if (m.cancelled()) return error.Cancelled;
        m.enter(.writing, 0);
    }

    const summary: types.DuplicateSummary = .{
        .files_scanned = tree.totals.files,
        .bytes_scanned = tree.totals.logical,
        .duplicate_groups = 0,
        .duplicate_files = 0,
        .space_savings = 0,
        .scan_time_ns = monotonicNs() -| started,
        .excluded_entries = fw.stats.excluded,
        .overlapping_roots = paths.len - roots.len,
    };
    try store.write(out_path, .{
        .groups = &.{},
        .summary = &summary,
        .failed_paths = failed,
        .space = &tree,
    });
}

fn monotonicNs() u64 {
    var ts: libc.timespec = undefined;
    _ = libc.clock_gettime(.MONOTONIC, &ts);
    const ns: i128 = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
    return if (ns > 0) @intCast(ns) else 0;
}

// ===========================================================================
// Aggregates
// ===========================================================================

/// What a subtree adds up to.
pub const Agg = struct {
    files: u64 = 0,
    /// Folders below (not counting the folder itself).
    dirs: u64 = 0,
    /// Bytes on disk.
    bytes: u64 = 0,
    /// Apparent size.
    logical: u64 = 0,
    /// Cloud placeholders, not on disk.
    dataless: u64 = 0,
    /// Bytes on disk per `Category`.
    cat: [category_count]u64 = @splat(0),

    fn add(self: *Agg, other: Agg) void {
        self.files +|= other.files;
        self.dirs +|= other.dirs;
        self.bytes +|= other.bytes;
        self.logical +|= other.logical;
        self.dataless +|= other.dataless;
        for (&self.cat, other.cat) |*a, b| a.* +|= b;
    }

    fn sub(self: *Agg, other: Agg) void {
        self.files -|= other.files;
        self.dirs -|= other.dirs;
        self.bytes -|= other.bytes;
        self.logical -|= other.logical;
        self.dataless -|= other.dataless;
        for (&self.cat, other.cat) |*a, b| a.* -|= b;
    }

    /// The category holding the most bytes; `other` when empty.
    pub fn dominant(self: Agg) Category {
        var best: usize = @intFromEnum(Category.other);
        var best_bytes: u64 = 0;
        for (self.cat, 0..) |b, i| {
            if (b > best_bytes) {
                best = i;
                best_bytes = b;
            }
        }
        return @enumFromInt(best);
    }
};

/// Space a file takes on disk. A filesystem that reports no blocks at all for
/// a non-empty, non-placeholder file (some network and FUSE filesystems) is
/// taken at its apparent size rather than as free.
fn diskBytes(file: *const types.FileEntry) u64 {
    if (file.allocated == 0 and !file.dataless) return file.size;
    return file.allocated;
}

// ===========================================================================
// Building the tree
// ===========================================================================

pub const no_parent: u32 = std.math.maxInt(u32);
/// Files kept in the precomputed "largest anywhere" list.
pub const top_capacity: usize = 1000;

/// What the volume holding the scan looked like when it was scanned.
pub const Volume = struct {
    /// Mount point; owned by the tree.
    mount: []const u8 = "",
    total: u64 = 0,
    free: u64 = 0,
    available: u64 = 0,
};

pub const Totals = struct {
    files: u64 = 0,
    dirs: u64 = 0,
    bytes: u64 = 0,
    logical: u64 = 0,
    dataless_files: u64 = 0,
    dataless_logical: u64 = 0,
    hard_links: u64 = 0,
    excluded: u64 = 0,
    errors: u64 = 0,
    incomplete_dirs: u64 = 0,
    cat_files: [category_count]u64 = @splat(0),
};

const Node = struct {
    /// Index into the walker's directory records.
    source: u32,
    parent: u32,
    subtree_end: u32,
    child_dirs: u32 = 0,
    direct_files: u32 = 0,
    first_file: u64 = 0,
    /// Where the name starts in the path; 0 for a root, whose name is its path.
    name_start: u32,
    context: Context,
    incomplete: bool,
    subtree_incomplete: bool,
    skipped: u32,
    agg: Agg = .{},
};

/// The scanned tree, ready to be written. Borrows the walker's records.
pub const Tree = struct {
    gpa: Allocator,
    files: []const types.FileEntry,
    dirs: []const fast_walker.DirRecord,
    /// By preorder position.
    nodes: []Node,
    /// File position -> index into `files`.
    file_order: []u32,
    /// File position -> preorder folder.
    file_dir: []u32,
    file_cat: []Category,
    /// File positions, largest first.
    top: []u32,
    totals: Totals,
    volume: Volume,

    pub fn deinit(self: *Tree) void {
        const gpa = self.gpa;
        gpa.free(self.nodes);
        gpa.free(self.file_order);
        gpa.free(self.file_dir);
        gpa.free(self.file_cat);
        gpa.free(self.top);
        gpa.free(self.volume.mount);
    }

    fn nameOf(self: *const Tree, i: usize) []const u8 {
        const node = &self.nodes[i];
        return self.dirs[node.source].path[node.name_start..];
    }
};

/// `/` sorts below every other byte, so a sorted list of paths is a preorder
/// walk: `/a`, `/a/b`, `/a/b/c`, `/a-z`.
fn preorderLess(_: void, a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        if (x == y) continue;
        return rank(x) < rank(y);
    }
    return a.len < b.len;
}

fn rank(c: u8) u16 {
    return if (c == '/') 0 else @as(u16, c) + 1;
}

fn parentPath(path: []const u8) ?[]const u8 {
    if (path.len <= 1) return null;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    return if (slash == 0) "/" else path[0..slash];
}

pub const BuildInput = struct {
    files: []const types.FileEntry,
    dirs: []const fast_walker.DirRecord,
    excluded: u64 = 0,
    errors: u64 = 0,
    /// The first scan root, for the volume figures.
    volume_of: ?[]const u8 = null,
};

pub fn build(gpa: Allocator, input: BuildInput) !Tree {
    const n = input.dirs.len;
    if (n >= no_parent) return error.TooManyFolders;

    // Preorder.
    const order = try gpa.alloc(u32, n);
    defer gpa.free(order);
    for (order, 0..) |*slot, i| slot.* = @intCast(i);
    const Sorter = struct {
        dirs: []const fast_walker.DirRecord,
        fn less(self: @This(), a: u32, b: u32) bool {
            return preorderLess({}, self.dirs[a].path, self.dirs[b].path);
        }
    };
    std.sort.pdq(u32, order, Sorter{ .dirs = input.dirs }, Sorter.less);

    var by_path: std.StringHashMapUnmanaged(u32) = .empty;
    defer by_path.deinit(gpa);
    try by_path.ensureTotalCapacity(gpa, @intCast(n));
    for (order, 0..) |source, i| by_path.putAssumeCapacity(input.dirs[source].path, @intCast(i));

    const nodes = try gpa.alloc(Node, n);
    errdefer gpa.free(nodes);
    var totals: Totals = .{ .excluded = input.excluded, .errors = input.errors };

    for (order, 0..) |source, i| {
        const record = &input.dirs[source];
        const parent: u32 = blk: {
            const p = parentPath(record.path) orelse break :blk no_parent;
            const index = by_path.get(p) orelse break :blk no_parent;
            // Preorder puts a parent first; anything else is not a parent.
            break :blk if (index < i) index else no_parent;
        };
        const name_start: u32 = if (parent == no_parent) 0 else blk: {
            const slash = std.mem.lastIndexOfScalar(u8, record.path, '/').?;
            break :blk @intCast(slash + 1);
        };
        const name = record.path[name_start..];
        const parent_context: Context = if (parent == no_parent) .none else nodes[parent].context;
        const parent_name: []const u8 = if (parent == no_parent) "" else blk: {
            const p = &nodes[parent];
            break :blk input.dirs[p.source].path[p.name_start..];
        };
        nodes[i] = .{
            .source = source,
            .parent = parent,
            .subtree_end = @intCast(i + 1),
            .name_start = name_start,
            .context = contextOf(parent_context, record.path, name, parent_name),
            .incomplete = record.incomplete,
            .subtree_incomplete = record.incomplete,
            .skipped = record.skipped,
        };
        if (record.incomplete) totals.incomplete_dirs += 1;
    }
    var i = n;
    while (i > 0) {
        i -= 1;
        const p = nodes[i].parent;
        if (p == no_parent) continue;
        nodes[p].subtree_end = @max(nodes[p].subtree_end, nodes[i].subtree_end);
        nodes[p].child_dirs += 1;
    }

    // Files, grouped by folder (counting sort), then largest first within one.
    var placed: usize = 0;
    const dir_of = try gpa.alloc(u32, input.files.len);
    defer gpa.free(dir_of);
    for (input.files, dir_of) |*file, *slot| {
        slot.* = no_parent;
        if (file.link_of != null) {
            totals.hard_links += 1;
            continue;
        }
        const p = parentPath(file.path) orelse continue;
        const index = by_path.get(p) orelse continue;
        slot.* = index;
        nodes[index].direct_files += 1;
        placed += 1;
    }
    if (placed >= std.math.maxInt(u32)) return error.TooManyFiles;

    var next: u64 = 0;
    for (nodes) |*node| {
        node.first_file = next;
        next += node.direct_files;
    }
    const file_order = try gpa.alloc(u32, placed);
    errdefer gpa.free(file_order);
    const file_dir = try gpa.alloc(u32, placed);
    errdefer gpa.free(file_dir);
    const file_cat = try gpa.alloc(Category, placed);
    errdefer gpa.free(file_cat);
    {
        const fill = try gpa.alloc(u32, n);
        defer gpa.free(fill);
        @memset(fill, 0);
        for (dir_of, 0..) |d, f| {
            if (d == no_parent) continue;
            const at: usize = @intCast(nodes[d].first_file + fill[d]);
            fill[d] += 1;
            file_order[at] = @intCast(f);
            file_dir[at] = d;
        }
    }
    const BySize = struct {
        files: []const types.FileEntry,
        fn less(self: @This(), a: u32, b: u32) bool {
            const x = diskBytes(&self.files[a]);
            const y = diskBytes(&self.files[b]);
            if (x != y) return x > y;
            return std.mem.order(u8, self.files[a].path, self.files[b].path) == .lt;
        }
    };
    for (nodes) |*node| {
        const start: usize = @intCast(node.first_file);
        std.sort.pdq(u32, file_order[start .. start + node.direct_files], BySize{ .files = input.files }, BySize.less);
    }

    // Direct sums, then up the tree.
    for (file_order, file_dir, file_cat) |f, d, *cat| {
        const file = &input.files[f];
        const name = file.path[(std.mem.lastIndexOfScalar(u8, file.path, '/') orelse 0) + 1 ..];
        cat.* = categoryIn(nodes[d].context, name);
        const bytes = diskBytes(file);
        const agg = &nodes[d].agg;
        agg.files += 1;
        agg.bytes +|= bytes;
        agg.logical +|= file.size;
        agg.cat[@intFromEnum(cat.*)] +|= bytes;
        totals.cat_files[@intFromEnum(cat.*)] += 1;
        if (file.dataless) {
            agg.dataless += 1;
            totals.dataless_logical +|= file.size;
        }
    }
    i = n;
    while (i > 0) {
        i -= 1;
        const p = nodes[i].parent;
        if (p == no_parent) {
            totals.files += nodes[i].agg.files;
            totals.dirs += nodes[i].agg.dirs + 1;
            totals.bytes +|= nodes[i].agg.bytes;
            totals.logical +|= nodes[i].agg.logical;
            totals.dataless_files += nodes[i].agg.dataless;
            continue;
        }
        var child = nodes[i].agg;
        child.dirs += 1;
        nodes[p].agg.add(child);
        if (nodes[i].subtree_incomplete) nodes[p].subtree_incomplete = true;
    }

    // The largest files anywhere.
    const heap_buf = try gpa.alloc(TopK.Entry, @min(top_capacity, placed));
    defer gpa.free(heap_buf);
    var heap: TopK = .{ .items = heap_buf };
    for (file_order, 0..) |f, pos| heap.offer(diskBytes(&input.files[f]), pos);
    const ranked = heap.sorted();
    const top = try gpa.alloc(u32, ranked.len);
    errdefer gpa.free(top);
    for (ranked, top) |entry, *slot| slot.* = @intCast(entry.id);

    var volume: Volume = .{};
    if (input.volume_of) |root| volume = volumeOf(gpa, root) catch .{};
    errdefer gpa.free(volume.mount);
    if (volume.mount.len == 0) volume.mount = try gpa.dupe(u8, "");

    return .{
        .gpa = gpa,
        .files = input.files,
        .dirs = input.dirs,
        .nodes = nodes,
        .file_order = file_order,
        .file_dir = file_dir,
        .file_cat = file_cat,
        .top = top,
        .totals = totals,
        .volume = volume,
    };
}

/// A bounded min-heap that keeps the `items.len` largest keys offered. Ties
/// keep the entry offered first, so the result does not depend on heap order.
pub const TopK = struct {
    items: []Entry,
    len: usize = 0,

    pub const Entry = struct { key: u64, id: u64 };

    fn below(a: Entry, b: Entry) bool {
        if (a.key != b.key) return a.key < b.key;
        return a.id > b.id;
    }

    pub fn offer(self: *TopK, key: u64, id: u64) void {
        if (self.items.len == 0) return;
        const entry: Entry = .{ .key = key, .id = id };
        if (self.len < self.items.len) {
            var at = self.len;
            self.items[at] = entry;
            self.len += 1;
            while (at > 0) {
                const up = (at - 1) / 2;
                if (!below(self.items[at], self.items[up])) break;
                std.mem.swap(Entry, &self.items[at], &self.items[up]);
                at = up;
            }
            return;
        }
        if (!below(self.items[0], entry)) return;
        self.items[0] = entry;
        var at: usize = 0;
        while (true) {
            const l = 2 * at + 1;
            const r = l + 1;
            var least = at;
            if (l < self.len and below(self.items[l], self.items[least])) least = l;
            if (r < self.len and below(self.items[r], self.items[least])) least = r;
            if (least == at) break;
            std.mem.swap(Entry, &self.items[at], &self.items[least]);
            at = least;
        }
    }

    /// Largest first. The heap is consumed.
    pub fn sorted(self: *TopK) []Entry {
        const out = self.items[0..self.len];
        std.sort.pdq(Entry, out, {}, struct {
            fn more(_: void, a: Entry, b: Entry) bool {
                return below(b, a);
            }
        }.more);
        return out;
    }
};

// ===========================================================================
// Volume
// ===========================================================================

const DarwinStatfs = extern struct {
    bsize: u32,
    iosize: i32,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    fsid: [2]i32,
    owner: u32,
    type: u32,
    flags: u32,
    fssubtype: u32,
    fstypename: [16]u8,
    mntonname: [1024]u8,
    mntfromname: [1024]u8,
    flags_ext: u32,
    reserved: [7]u32,
};

/// glibc/musl `struct statvfs` on 64-bit targets; only the leading fields are
/// read, the tail is room for what libc writes after them.
const LinuxStatvfs = extern struct {
    bsize: c_ulong,
    frsize: c_ulong,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    favail: u64,
    fsid: c_ulong,
    flag: c_ulong,
    namemax: c_ulong,
    spare: [16]u64,
};

const statfs_darwin = if (builtin.os.tag.isDarwin())
    @extern(*const fn ([*:0]const u8, *DarwinStatfs) callconv(.c) c_int, .{
        // arm64 has only the 64-bit-inode ABI; x86_64 keeps it behind a suffix.
        .name = if (builtin.cpu.arch == .x86_64) "statfs$INODE64" else "statfs",
    })
else
    void;

const statvfs_linux = if (builtin.os.tag == .linux)
    @extern(*const fn ([*:0]const u8, *LinuxStatvfs) callconv(.c) c_int, .{ .name = "statvfs" })
else
    void;

/// Size and free space of the volume holding `path`, and where it is mounted.
/// On macOS the figures are the APFS container's, which is what Finder shows.
pub fn volumeOf(gpa: Allocator, path: []const u8) !Volume {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&buf);

    if (comptime builtin.os.tag.isDarwin()) {
        var st: DarwinStatfs = undefined;
        if (statfs_darwin(path_z, &st) != 0) return error.StatFailed;
        const block: u64 = st.bsize;
        const mount = std.mem.sliceTo(&st.mntonname, 0);
        return .{
            .mount = try gpa.dupe(u8, mount),
            .total = st.blocks *| block,
            .free = st.bfree *| block,
            .available = st.bavail *| block,
        };
    } else if (comptime builtin.os.tag == .linux) {
        var st: LinuxStatvfs = undefined;
        if (statvfs_linux(path_z, &st) != 0) return error.StatFailed;
        const block: u64 = if (st.frsize != 0) st.frsize else st.bsize;
        return .{
            .mount = try mountPointOf(gpa, path),
            .total = st.blocks *| block,
            .free = st.bfree *| block,
            .available = st.bavail *| block,
        };
    } else {
        return error.Unsupported;
    }
}

/// The highest ancestor of `path` on the same device: its mount point.
fn mountPointOf(gpa: Allocator, path: []const u8) ![]u8 {
    var buf: [4096]u8 = undefined;
    const dev = (pstat.stat(zOf(&buf, path) orelse return gpa.dupe(u8, path)) catch return gpa.dupe(u8, path)).dev;
    var current = path;
    while (parentPath(current)) |up| {
        const st = pstat.stat(zOf(&buf, up) orelse break) catch break;
        if (st.dev != dev) break;
        current = up;
    }
    return gpa.dupe(u8, current);
}

fn zOf(buf: *[4096]u8, path: []const u8) ?[*:0]const u8 {
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf);
}

// ===========================================================================
// The blob
// ===========================================================================
//
// Behind `store.Header.space`: offsets inside are relative to the blob's
// first byte, every section 8-byte aligned.
//
//     BlobHeader (256 bytes)
//     DIRS     DirRecord[]    preorder
//     FILES    FileRecord[]   grouped by folder in DIRS order, largest first
//     TOP      u64[]          file indices, largest first (<= top_capacity)
//     STRINGS  u8[]           names: folders, then files, then the mount point

pub const blob_magic = "ZDSPACE1".*;
pub const blob_version: u32 = 1;
pub const blob_header_size: usize = 256;

pub const Section = store.Section;

pub const BlobHeader = extern struct {
    magic: [8]u8 = blob_magic,
    version: u32 = blob_version,
    header_size: u32 = blob_header_size,
    dirs: Section = .{},
    files: Section = .{},
    top: Section = .{},
    strings: Section = .{},
    total_files: u64 = 0,
    total_dirs: u64 = 0,
    bytes: u64 = 0,
    logical: u64 = 0,
    dataless_files: u64 = 0,
    dataless_logical: u64 = 0,
    hard_links: u64 = 0,
    excluded: u64 = 0,
    errors: u64 = 0,
    incomplete_dirs: u64 = 0,
    volume_total: u64 = 0,
    volume_free: u64 = 0,
    volume_available: u64 = 0,
    mount_offset: u64 = 0,
    mount_len: u32 = 0,
    _pad: u32 = 0,
    cat_files: [category_count]u64 = @splat(0),
};

pub const dir_flag_incomplete: u32 = 1 << 0;
pub const dir_flag_subtree_incomplete: u32 = 1 << 1;

pub const DirRecord = extern struct {
    name_offset: u64,
    /// Index of the folder's first file in FILES.
    first_file: u64,
    files: u64,
    dirs: u64,
    bytes: u64,
    logical: u64,
    dataless: u64,
    cat: [category_count]u64,
    name_len: u32,
    /// `no_parent` for a scan root, whose name is its full path.
    parent: u32,
    /// One past the last folder below this one.
    subtree_end: u32,
    child_dirs: u32,
    direct_files: u32,
    skipped: u32,
    flags: u32,
    _pad: u32 = 0,

    pub fn agg(self: *const DirRecord) Agg {
        return .{
            .files = self.files,
            .dirs = self.dirs,
            .bytes = self.bytes,
            .logical = self.logical,
            .dataless = self.dataless,
            .cat = self.cat,
        };
    }
};

pub const file_flag_dataless: u8 = 1 << 0;
pub const file_flag_hard_linked: u8 = 1 << 1;

pub const FileRecord = extern struct {
    name_offset: u64,
    bytes: u64,
    logical: u64,
    mtime: i64,
    dir: u32,
    name_len: u16,
    category: u8,
    flags: u8,

    pub fn agg(self: *const FileRecord) Agg {
        var out: Agg = .{
            .files = 1,
            .bytes = self.bytes,
            .logical = self.logical,
            .dataless = @intFromBool(self.flags & file_flag_dataless != 0),
        };
        out.cat[self.categoryIndex()] = self.bytes;
        return out;
    }

    pub fn categoryIndex(self: *const FileRecord) usize {
        return @min(self.category, category_count - 1);
    }
};

comptime {
    std.debug.assert(@sizeOf(BlobHeader) == blob_header_size);
    std.debug.assert(@sizeOf(DirRecord) == 144);
    std.debug.assert(@sizeOf(FileRecord) == 40);
}

/// Append the tree to `out` as a blob; returns its (offset, length).
pub fn writeBlob(out: *store.FileWriter, tree: *const Tree) store.WriteError!Section {
    try out.alignTo(8);
    const start = out.offset;
    const totals = &tree.totals;
    var header: BlobHeader = .{
        .total_files = totals.files,
        .total_dirs = totals.dirs,
        .bytes = totals.bytes,
        .logical = totals.logical,
        .dataless_files = totals.dataless_files,
        .dataless_logical = totals.dataless_logical,
        .hard_links = totals.hard_links,
        .excluded = totals.excluded,
        .errors = totals.errors,
        .incomplete_dirs = totals.incomplete_dirs,
        .volume_total = tree.volume.total,
        .volume_free = tree.volume.free,
        .volume_available = tree.volume.available,
        .cat_files = totals.cat_files,
    };
    try out.write(std.mem.asBytes(&header));

    var names: u64 = 0;

    try out.alignTo(8);
    header.dirs = .{ .offset = out.offset - start, .count = tree.nodes.len };
    for (tree.nodes, 0..) |*node, i| {
        const name = tree.nameOf(i);
        const name_len = std.math.cast(u32, name.len) orelse return error.StringTooLong;
        try out.write(std.mem.asBytes(&DirRecord{
            .name_offset = names,
            .first_file = node.first_file,
            .files = node.agg.files,
            .dirs = node.agg.dirs,
            .bytes = node.agg.bytes,
            .logical = node.agg.logical,
            .dataless = node.agg.dataless,
            .cat = node.agg.cat,
            .name_len = name_len,
            .parent = node.parent,
            .subtree_end = node.subtree_end,
            .child_dirs = node.child_dirs,
            .direct_files = node.direct_files,
            .skipped = node.skipped,
            .flags = (if (node.incomplete) dir_flag_incomplete else 0) |
                (if (node.subtree_incomplete) dir_flag_subtree_incomplete else 0),
        }));
        names += name_len;
    }

    try out.alignTo(8);
    header.files = .{ .offset = out.offset - start, .count = tree.file_order.len };
    for (tree.file_order, tree.file_dir, tree.file_cat) |f, d, cat| {
        const file = &tree.files[f];
        const name = baseName(file.path);
        const name_len = std.math.cast(u16, name.len) orelse return error.StringTooLong;
        try out.write(std.mem.asBytes(&FileRecord{
            .name_offset = names,
            .bytes = diskBytes(file),
            .logical = file.size,
            .mtime = file.mtime,
            .dir = d,
            .name_len = name_len,
            .category = @intFromEnum(cat),
            .flags = (if (file.dataless) file_flag_dataless else 0) |
                (if (file.nlink > 1) file_flag_hard_linked else 0),
        }));
        names += name_len;
    }

    try out.alignTo(8);
    header.top = .{ .offset = out.offset - start, .count = tree.top.len };
    for (tree.top) |pos| {
        const value: u64 = pos;
        try out.write(std.mem.asBytes(&value));
    }

    try out.alignTo(8);
    header.strings.offset = out.offset - start;
    for (0..tree.nodes.len) |i| try out.write(tree.nameOf(i));
    for (tree.file_order) |f| try out.write(baseName(tree.files[f].path));
    header.mount_offset = names;
    header.mount_len = std.math.cast(u32, tree.volume.mount.len) orelse return error.StringTooLong;
    try out.write(tree.volume.mount);
    names += tree.volume.mount.len;
    header.strings.count = names;

    const length = out.offset - start;
    try out.flush();
    try out.rewriteAt(std.mem.asBytes(&header), start);
    return .{ .offset = start, .count = length };
}

fn baseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

// ===========================================================================
// Reading
// ===========================================================================

pub const ReadError = error{ Invalid, OutOfRange };

/// A validated view over a blob. Holds no allocations.
pub const Reader = struct {
    bytes: []const u8,
    header: BlobHeader,

    /// Validates the header, every section, and the folder table's shape (parents
    /// before children, subtree runs nested, file runs contiguous), so no
    /// traversal below can loop or index out of range.
    pub fn init(bytes: []const u8) ReadError!Reader {
        if (bytes.len < blob_header_size) return error.Invalid;
        const header = std.mem.bytesToValue(BlobHeader, bytes[0..blob_header_size]);
        if (!std.mem.eql(u8, &header.magic, &blob_magic)) return error.Invalid;
        if (header.version != blob_version or header.header_size != blob_header_size) return error.Invalid;
        const sections = [_]struct { Section, usize }{
            .{ header.dirs, @sizeOf(DirRecord) },
            .{ header.files, @sizeOf(FileRecord) },
            .{ header.top, @sizeOf(u64) },
            .{ header.strings, 1 },
        };
        for (sections) |entry| {
            const section, const size = entry;
            const offset = std.math.cast(usize, section.offset) orelse return error.Invalid;
            const count = std.math.cast(usize, section.count) orelse return error.Invalid;
            const len = std.math.mul(usize, count, size) catch return error.Invalid;
            const end = std.math.add(usize, offset, len) catch return error.Invalid;
            if (offset < blob_header_size or offset % 8 != 0 or end > bytes.len) return error.Invalid;
        }
        const self: Reader = .{ .bytes = bytes, .header = header };
        if (header.dirs.count >= no_parent) return error.Invalid;
        const n: u32 = @intCast(header.dirs.count);
        var expected_file: u64 = 0;
        for (0..n) |i| {
            const d = try self.dir(i);
            if (d.parent != no_parent) {
                if (d.parent >= i) return error.Invalid;
                const p = try self.dir(d.parent);
                if (d.subtree_end > p.subtree_end) return error.Invalid;
            }
            if (d.subtree_end <= i or d.subtree_end > n) return error.Invalid;
            if (d.first_file != expected_file) return error.Invalid;
            expected_file += d.direct_files;
        }
        if (expected_file != header.files.count) return error.Invalid;
        for (0..self.topCount()) |i| {
            if (try self.topFile(i) >= header.files.count) return error.Invalid;
        }
        return self;
    }

    pub fn dirCount(self: *const Reader) u32 {
        return @intCast(self.header.dirs.count);
    }

    pub fn fileCount(self: *const Reader) u64 {
        return self.header.files.count;
    }

    pub fn topCount(self: *const Reader) usize {
        return @intCast(self.header.top.count);
    }

    fn record(self: *const Reader, section: Section, comptime T: type, i: u64) ReadError!T {
        if (i >= section.count) return error.OutOfRange;
        const start: usize = @intCast(section.offset + i * @sizeOf(T));
        return std.mem.bytesToValue(T, self.bytes[start..][0..@sizeOf(T)]);
    }

    pub fn dir(self: *const Reader, i: u64) ReadError!DirRecord {
        return self.record(self.header.dirs, DirRecord, i);
    }

    pub fn file(self: *const Reader, i: u64) ReadError!FileRecord {
        const f = try self.record(self.header.files, FileRecord, i);
        if (f.dir >= self.header.dirs.count) return error.OutOfRange;
        return f;
    }

    pub fn topFile(self: *const Reader, i: usize) ReadError!u64 {
        return self.record(self.header.top, u64, i);
    }

    pub fn string(self: *const Reader, offset: u64, len: u64) ReadError![]const u8 {
        const end = std.math.add(u64, offset, len) catch return error.OutOfRange;
        if (end > self.header.strings.count) return error.OutOfRange;
        const base: usize = @intCast(self.header.strings.offset);
        return self.bytes[base + @as(usize, @intCast(offset)) ..][0..@intCast(len)];
    }

    pub fn dirName(self: *const Reader, d: *const DirRecord) ReadError![]const u8 {
        return self.string(d.name_offset, d.name_len);
    }

    pub fn fileName(self: *const Reader, f: *const FileRecord) ReadError![]const u8 {
        return self.string(f.name_offset, f.name_len);
    }

    pub fn mount(self: *const Reader) ReadError![]const u8 {
        return self.string(self.header.mount_offset, self.header.mount_len);
    }

    /// One past the last file of folder `i`'s subtree.
    pub fn subtreeFileEnd(self: *const Reader, d: *const DirRecord) ReadError!u64 {
        if (d.subtree_end >= self.dirCount()) return self.fileCount();
        return (try self.dir(d.subtree_end)).first_file;
    }

    /// Exact path bytes of folder `i`.
    pub fn dirPath(self: *const Reader, arena: Allocator, i: u32) ![]u8 {
        var parts: std.ArrayListUnmanaged([]const u8) = .empty;
        var at = i;
        var guard: usize = 0;
        while (true) : (guard += 1) {
            if (guard > self.dirCount()) return error.Invalid;
            const d = try self.dir(at);
            try parts.append(arena, try self.dirName(&d));
            if (d.parent == no_parent) break;
            at = d.parent;
        }
        return joinReversed(arena, parts.items, null);
    }

    /// Exact path bytes of file `i`.
    pub fn filePath(self: *const Reader, arena: Allocator, i: u64) ![]u8 {
        const f = try self.file(i);
        const dir_path = try self.dirPath(arena, f.dir);
        return joinReversed(arena, &.{dir_path}, try self.fileName(&f));
    }

    /// Where a path lies in the tree, by exact bytes: a folder, a file, or
    /// nothing in these results.
    pub fn locate(self: *const Reader, path: []const u8) ReadError!?Located {
        const n = self.dirCount();
        var root: u32 = 0;
        while (root < n) {
            const d = try self.dir(root);
            const name = try self.dirName(&d);
            if (filters.isAtOrUnder(path, name)) return self.locateUnder(root, name, path);
            root = d.subtree_end;
        }
        return null;
    }

    fn locateUnder(self: *const Reader, root: u32, root_name: []const u8, path: []const u8) ReadError!?Located {
        if (path.len == root_name.len) return .{ .dir = root };
        const rest = if (std.mem.eql(u8, root_name, "/")) path[1..] else path[root_name.len + 1 ..];
        var current = root;
        var parts = std.mem.splitScalar(u8, rest, '/');
        while (parts.next()) |part| {
            const last = parts.peek() == null;
            if (try self.childDirNamed(current, part)) |child| {
                current = child;
                continue;
            }
            if (!last) return null;
            return if (try self.directFileNamed(current, part)) |f| .{ .file = f } else null;
        }
        return .{ .dir = current };
    }

    fn childDirNamed(self: *const Reader, parent: u32, name: []const u8) ReadError!?u32 {
        const p = try self.dir(parent);
        var c = parent + 1;
        while (c < p.subtree_end) {
            const d = try self.dir(c);
            if (std.mem.eql(u8, try self.dirName(&d), name)) return c;
            c = d.subtree_end;
        }
        return null;
    }

    fn directFileNamed(self: *const Reader, parent: u32, name: []const u8) ReadError!?u64 {
        const p = try self.dir(parent);
        for (p.first_file..p.first_file + p.direct_files) |f| {
            const rec = try self.file(f);
            if (std.mem.eql(u8, try self.fileName(&rec), name)) return f;
        }
        return null;
    }
};

pub const Located = union(enum) { dir: u32, file: u64 };

fn joinReversed(arena: Allocator, parts: []const []const u8, leaf: ?[]const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i = parts.len;
    while (i > 0) {
        i -= 1;
        try appendComponent(arena, &out, parts[i]);
    }
    if (leaf) |name| try appendComponent(arena, &out, name);
    return out.items;
}

fn appendComponent(arena: Allocator, out: *std.ArrayListUnmanaged(u8), part: []const u8) !void {
    if (out.items.len > 0 and out.items[out.items.len - 1] != '/') try out.append(arena, '/');
    try out.appendSlice(arena, part);
}

// ===========================================================================
// What has been removed since the scan
// ===========================================================================

/// The removed overlay (paths) resolved against the tree: which folder and
/// file runs are gone, and what each gone piece added up to, so a folder's
/// totals can be corrected with two binary searches instead of a walk.
pub const RemovedIndex = struct {
    generation: u64 = std.math.maxInt(u64),
    /// Disjoint, sorted: preorder runs of removed folders.
    dir_runs: std.ArrayListUnmanaged(Run) = .empty,
    /// Disjoint, sorted: file-index runs removed (whole folders and single files).
    file_runs: std.ArrayListUnmanaged(Run) = .empty,
    /// Sorted by `at`: the folder a removed piece sat in (or was).
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    /// prefix[i] = sum of entries[0..i].
    prefix: std.ArrayListUnmanaged(Agg) = .empty,
    cat_files: [category_count]u64 = @splat(0),

    pub const Run = struct { start: u64, end: u64 };
    const Entry = struct { at: u32, agg: Agg };

    pub fn deinit(self: *RemovedIndex, gpa: Allocator) void {
        self.dir_runs.deinit(gpa);
        self.file_runs.deinit(gpa);
        self.entries.deinit(gpa);
        self.prefix.deinit(gpa);
    }

    pub fn isEmpty(self: *const RemovedIndex) bool {
        return self.entries.items.len == 0;
    }

    pub fn total(self: *const RemovedIndex) Agg {
        return if (self.prefix.items.len == 0) .{} else self.prefix.items[self.prefix.items.len - 1];
    }

    pub fn refresh(self: *RemovedIndex, gpa: Allocator, r: *const Reader, removed: *const removed_mod.Removed) !void {
        if (self.generation == removed.generation) return;
        self.dir_runs.clearRetainingCapacity();
        self.file_runs.clearRetainingCapacity();
        self.entries.clearRetainingCapacity();
        self.prefix.clearRetainingCapacity();
        self.cat_files = @splat(0);

        var dirs: std.ArrayListUnmanaged(u32) = .empty;
        defer dirs.deinit(gpa);
        var files: std.ArrayListUnmanaged(u64) = .empty;
        defer files.deinit(gpa);
        var it = removed.paths.keyIterator();
        while (it.next()) |key| {
            const found = try r.locate(key.*) orelse continue;
            switch (found) {
                .dir => |d| try dirs.append(gpa, d),
                .file => |f| try files.append(gpa, f),
            }
        }
        std.sort.pdq(u32, dirs.items, {}, std.sort.asc(u32));
        std.sort.pdq(u64, files.items, {}, std.sort.asc(u64));

        for (dirs.items) |d| {
            const rec = try r.dir(d);
            if (self.dir_runs.items.len > 0 and d < self.dir_runs.items[self.dir_runs.items.len - 1].end) continue;
            try self.dir_runs.append(gpa, .{ .start = d, .end = rec.subtree_end });
            var agg = rec.agg();
            agg.dirs += 1;
            try self.entries.append(gpa, .{ .at = d, .agg = agg });
            const first = rec.first_file;
            const end = try r.subtreeFileEnd(&rec);
            if (end > first) try self.file_runs.append(gpa, .{ .start = first, .end = end });
            for (first..end) |f| {
                const file = try r.file(f);
                self.cat_files[file.categoryIndex()] += 1;
            }
        }
        var lone: std.ArrayListUnmanaged(Run) = .empty;
        defer lone.deinit(gpa);
        for (files.items) |f| {
            const rec = try r.file(f);
            if (self.dirRemoved(rec.dir)) continue;
            if (lone.items.len > 0 and lone.items[lone.items.len - 1].start == f) continue;
            try lone.append(gpa, .{ .start = f, .end = f + 1 });
            try self.entries.append(gpa, .{ .at = rec.dir, .agg = rec.agg() });
            self.cat_files[rec.categoryIndex()] += 1;
        }
        try self.file_runs.appendSlice(gpa, lone.items);
        std.sort.pdq(Run, self.file_runs.items, {}, struct {
            fn less(_: void, a: Run, b: Run) bool {
                return a.start < b.start;
            }
        }.less);
        std.sort.pdq(Entry, self.entries.items, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                return a.at < b.at;
            }
        }.less);
        try self.prefix.ensureTotalCapacity(gpa, self.entries.items.len + 1);
        var running: Agg = .{};
        self.prefix.appendAssumeCapacity(running);
        for (self.entries.items) |entry| {
            running.add(entry.agg);
            self.prefix.appendAssumeCapacity(running);
        }
        self.generation = removed.generation;
    }

    fn containing(runs: []const Run, at: u64) bool {
        // Last run starting at or before `at`.
        var lo: usize = 0;
        var hi: usize = runs.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (runs[mid].start <= at) lo = mid + 1 else hi = mid;
        }
        return lo > 0 and at < runs[lo - 1].end;
    }

    pub fn dirRemoved(self: *const RemovedIndex, d: u32) bool {
        return containing(self.dir_runs.items, d);
    }

    pub fn fileRemoved(self: *const RemovedIndex, f: u64) bool {
        return containing(self.file_runs.items, f);
    }

    fn lowerBound(self: *const RemovedIndex, at: u64) usize {
        var lo: usize = 0;
        var hi: usize = self.entries.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.entries.items[mid].at < at) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// What was removed from inside folders `[start, end)` (preorder).
    pub fn inside(self: *const RemovedIndex, start: u64, end: u64) Agg {
        if (self.entries.items.len == 0) return .{};
        const lo = self.lowerBound(start);
        const hi = self.lowerBound(end);
        var out = self.prefix.items[hi];
        out.sub(self.prefix.items[lo]);
        return out;
    }

    /// How many file indices in `[start, end)` are removed.
    pub fn removedFilesIn(self: *const RemovedIndex, start: u64, end: u64) u64 {
        var count: u64 = 0;
        for (self.file_runs.items) |run| {
            if (run.end <= start) continue;
            if (run.start >= end) break;
            count += @min(run.end, end) - @max(run.start, start);
        }
        return count;
    }

    /// Walks the alive file indices of `[start, end)` in order.
    pub fn aliveFiles(self: *const RemovedIndex, start: u64, end: u64) AliveIterator {
        var lo: usize = 0;
        var hi: usize = self.file_runs.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.file_runs.items[mid].end <= start) lo = mid + 1 else hi = mid;
        }
        return .{ .runs = self.file_runs.items[lo..], .at = start, .end = end };
    }
};

pub const AliveIterator = struct {
    runs: []const RemovedIndex.Run,
    at: u64,
    end: u64,

    pub fn next(self: *AliveIterator) ?u64 {
        while (self.at < self.end) {
            if (self.runs.len > 0 and self.at >= self.runs[0].start) {
                if (self.at < self.runs[0].end) {
                    self.at = self.runs[0].end;
                    continue;
                }
                self.runs = self.runs[1..];
                continue;
            }
            defer self.at += 1;
            return self.at;
        }
        return null;
    }
};

// ===========================================================================
// Queries
// ===========================================================================

pub const By = enum { folder, type, size };

pub const ChildrenQuery = struct {
    /// A folder id; null with no `path` = every scan root.
    node: ?u32 = null,
    /// Or a folder by path (the lossy spelling a UI holds, or exact bytes).
    path: ?[]const u8 = null,
    by: By = .folder,
    /// Items in the folder view; clamped to `max_children`.
    limit: usize = 150,
    /// Items per group in the type and size views; clamped to `max_per_group`.
    per_group: usize = 40,
};

pub const LargestKind = enum { files, folders };

pub const LargestQuery = struct {
    node: ?u32 = null,
    path: ?[]const u8 = null,
    kind: LargestKind = .files,
    type: ?Category = null,
    limit: usize = 100,
};

pub const max_children: usize = 500;
pub const max_per_group: usize = 200;
pub const max_largest: usize = 200;
/// A folder whose largest subfolder holds at least this share of it is only
/// a wrapper around that subfolder, and is left out of the largest folders.
pub const wrapper_share: f64 = 0.9;

/// Size bands for `By.size`, largest first. Keys are part of the protocol.
pub const size_bands = [_]struct { key: []const u8, min: u64 }{
    .{ .key = "over_1g", .min = 1 << 30 },
    .{ .key = "100m_1g", .min = 100 << 20 },
    .{ .key = "10m_100m", .min = 10 << 20 },
    .{ .key = "1m_10m", .min = 1 << 20 },
    .{ .key = "under_1m", .min = 0 },
};

fn bandOf(bytes: u64) usize {
    for (size_bands, 0..) |band, i| {
        if (bytes >= band.min) return i;
    }
    return size_bands.len - 1;
}

/// Everything a query reads.
pub const View = struct {
    r: *const Reader,
    removed: *const RemovedIndex,
    guard: protect_mod.Protection,
    arena: Allocator,

    /// Folder `d` with what was removed from it taken off.
    pub fn dirAgg(self: *const View, d: u32, rec: *const DirRecord) Agg {
        var agg = rec.agg();
        agg.sub(self.removed.inside(@as(u64, d) + 1, rec.subtree_end));
        return agg;
    }

    /// Every root together.
    pub fn allAgg(self: *const View) !Agg {
        var agg: Agg = .{};
        var c: u32 = 0;
        const n = self.r.dirCount();
        while (c < n) {
            const d = try self.r.dir(c);
            if (!self.removed.dirRemoved(c)) {
                var one = self.dirAgg(c, &d);
                one.dirs += 1;
                agg.add(one);
            }
            c = d.subtree_end;
        }
        return agg;
    }

    /// The folder a query names, or null for every root. `error.NotFound`
    /// when it names something that is not an alive folder in these results.
    pub fn resolve(self: *const View, node: ?u32, path: ?[]const u8) !?u32 {
        if (node) |d| {
            if (d >= self.r.dirCount() or self.removed.dirRemoved(d)) return error.NotFound;
            return d;
        }
        const p = path orelse return null;
        const trimmed = if (p.len > 1) std.mem.trimEnd(u8, p, "/") else p;
        const found = (try self.r.locate(trimmed)) orelse (try self.locateLossy(trimmed)) orelse return error.NotFound;
        return switch (found) {
            .dir => |d| if (self.removed.dirRemoved(d)) error.NotFound else d,
            .file => error.NotFound,
        };
    }

    /// A path a UI sent back is the lossy spelling; retry by comparing
    /// spellings when the bytes did not match (a name that is not UTF-8).
    fn locateLossy(self: *const View, path: []const u8) !?Located {
        const n = self.r.dirCount();
        for (0..n) |i| {
            const spelled = try session_mod.lossy(self.arena, try self.r.dirPath(self.arena, @intCast(i)));
            if (std.mem.eql(u8, spelled, path)) return .{ .dir = @intCast(i) };
        }
        return null;
    }

    const Scope = struct {
        dir: ?u32,
        agg: Agg,
        dir_start: u32,
        dir_end: u32,
        file_start: u64,
        file_end: u64,
    };

    fn scope(self: *const View, dir: ?u32) !Scope {
        if (dir) |d| {
            const rec = try self.r.dir(d);
            return .{
                .dir = d,
                .agg = self.dirAgg(d, &rec),
                .dir_start = d,
                .dir_end = rec.subtree_end,
                .file_start = rec.first_file,
                .file_end = try self.r.subtreeFileEnd(&rec),
            };
        }
        return .{
            .dir = null,
            .agg = try self.allAgg(),
            .dir_start = 0,
            .dir_end = self.r.dirCount(),
            .file_start = 0,
            .file_end = self.r.fileCount(),
        };
    }

    // --- JSON pieces -------------------------------------------------------

    fn writeDir(self: *const View, json: *std.json.Stringify, d: u32, rec: *const DirRecord, agg: Agg) !void {
        const path = try self.r.dirPath(self.arena, d);
        try json.beginObject();
        try json.objectField("kind");
        try json.write("dir");
        try json.objectField("id");
        try json.write(d);
        try json.objectField("name");
        try json.write(try session_mod.lossy(self.arena, try self.r.dirName(rec)));
        try json.objectField("path");
        try json.write(try session_mod.lossy(self.arena, path));
        try json.objectField("bytes");
        try json.write(agg.bytes);
        try json.objectField("logical");
        try json.write(agg.logical);
        try json.objectField("files");
        try json.write(agg.files);
        try json.objectField("dirs");
        try json.write(agg.dirs);
        try json.objectField("type");
        try json.write(@tagName(agg.dominant()));
        try json.objectField("mtime");
        try json.write(0);
        try json.objectField("incomplete");
        try json.write(rec.flags & dir_flag_subtree_incomplete != 0);
        try json.objectField("dataless");
        try json.write(agg.dataless);
        try json.objectField("hard_linked");
        try json.write(false);
        try json.objectField("protected");
        try json.write(self.guard.guardsFolder(path));
        try json.objectField("root");
        try json.write(rec.parent == no_parent);
        try json.endObject();
    }

    fn writeFile(self: *const View, json: *std.json.Stringify, f: u64, rec: *const FileRecord) !void {
        const path = try self.r.filePath(self.arena, f);
        try json.beginObject();
        try json.objectField("kind");
        try json.write("file");
        try json.objectField("id");
        try json.write(f);
        try json.objectField("name");
        try json.write(try session_mod.lossy(self.arena, try self.r.fileName(rec)));
        try json.objectField("path");
        try json.write(try session_mod.lossy(self.arena, path));
        try json.objectField("bytes");
        try json.write(rec.bytes);
        try json.objectField("logical");
        try json.write(rec.logical);
        try json.objectField("files");
        try json.write(1);
        try json.objectField("dirs");
        try json.write(0);
        try json.objectField("type");
        try json.write(@tagName(@as(Category, @enumFromInt(rec.categoryIndex()))));
        try json.objectField("mtime");
        try json.write(if (rec.mtime > 0) rec.mtime *| 1000 else 0);
        try json.objectField("incomplete");
        try json.write(false);
        try json.objectField("dataless");
        try json.write(@as(u64, @intFromBool(rec.flags & file_flag_dataless != 0)));
        try json.objectField("hard_linked");
        try json.write(rec.flags & file_flag_hard_linked != 0);
        try json.objectField("protected");
        try json.write(self.guard.protects(path));
        try json.objectField("root");
        try json.write(false);
        try json.endObject();
    }

    fn writeTypes(json: *std.json.Stringify, agg: Agg, files: ?[category_count]u64) !void {
        try json.beginArray();
        for (0..category_count) |i| {
            try json.beginObject();
            try json.objectField("type");
            try json.write(@tagName(@as(Category, @enumFromInt(i))));
            try json.objectField("bytes");
            try json.write(agg.cat[i]);
            if (files) |counts| {
                try json.objectField("files");
                try json.write(counts[i]);
            }
            try json.endObject();
        }
        try json.endArray();
    }

    fn writeRest(json: *std.json.Stringify, count: u64, bytes: u64) !void {
        try json.objectField("rest");
        try json.beginObject();
        try json.objectField("count");
        try json.write(count);
        try json.objectField("bytes");
        try json.write(bytes);
        try json.endObject();
    }

    /// The scope as a node: a folder, or the stand-in for every root.
    fn writeScopeNode(self: *const View, json: *std.json.Stringify, s: *const Scope) !void {
        if (s.dir) |d| {
            const rec = try self.r.dir(d);
            return self.writeDir(json, d, &rec, s.agg);
        }
        try json.beginObject();
        try json.objectField("kind");
        try json.write("all");
        try json.objectField("id");
        try json.write(null);
        try json.objectField("name");
        try json.write("");
        try json.objectField("path");
        try json.write("");
        try json.objectField("bytes");
        try json.write(s.agg.bytes);
        try json.objectField("logical");
        try json.write(s.agg.logical);
        try json.objectField("files");
        try json.write(s.agg.files);
        try json.objectField("dirs");
        try json.write(s.agg.dirs);
        try json.objectField("type");
        try json.write(@tagName(s.agg.dominant()));
        try json.objectField("mtime");
        try json.write(0);
        try json.objectField("incomplete");
        try json.write(self.r.header.incomplete_dirs > 0);
        try json.objectField("dataless");
        try json.write(s.agg.dataless);
        try json.objectField("hard_linked");
        try json.write(false);
        try json.objectField("protected");
        try json.write(true);
        try json.objectField("root");
        try json.write(false);
        try json.endObject();
    }

    // --- children ------------------------------------------------------------

    pub fn children(self: *const View, json: *std.json.Stringify, query: ChildrenQuery) !void {
        const dir = try self.resolve(query.node, query.path);
        const s = try self.scope(dir);

        try json.beginObject();
        try json.objectField("node");
        try self.writeScopeNode(json, &s);
        try json.objectField("types");
        try writeTypes(json, s.agg, null);
        try json.objectField("trail");
        try json.beginArray();
        if (dir) |d| {
            var chain: std.ArrayListUnmanaged(u32) = .empty;
            var at = d;
            while (true) {
                try chain.append(self.arena, at);
                const rec = try self.r.dir(at);
                if (rec.parent == no_parent) break;
                at = rec.parent;
            }
            var i = chain.items.len;
            while (i > 0) {
                i -= 1;
                const rec = try self.r.dir(chain.items[i]);
                try json.beginObject();
                try json.objectField("id");
                try json.write(chain.items[i]);
                try json.objectField("name");
                try json.write(try session_mod.lossy(self.arena, try self.r.dirName(&rec)));
                try json.endObject();
            }
        }
        try json.endArray();
        try json.objectField("by");
        try json.write(@tagName(query.by));
        try json.objectField("groups");
        try json.beginArray();
        switch (query.by) {
            .folder => try self.folderGroup(json, &s, @min(query.limit, max_children)),
            .type, .size => try self.bandGroups(json, &s, query.by, @min(query.per_group, max_per_group)),
        }
        try json.endArray();
        try json.endObject();
    }

    const Item = struct { bytes: u64, kind: enum { dir, file }, id: u64 };

    /// Subfolders and files directly inside, merged largest first. Files are
    /// already stored largest first, so only the subfolders need sorting.
    fn folderGroup(self: *const View, json: *std.json.Stringify, s: *const Scope, limit: usize) !void {
        var subdirs: std.ArrayListUnmanaged(Item) = .empty;
        var c: u32 = if (s.dir) |d| d + 1 else 0;
        while (c < s.dir_end) {
            const rec = try self.r.dir(c);
            if (!self.removed.dirRemoved(c)) {
                try subdirs.append(self.arena, .{ .bytes = self.dirAgg(c, &rec).bytes, .kind = .dir, .id = c });
            }
            c = rec.subtree_end;
        }
        std.sort.pdq(Item, subdirs.items, {}, struct {
            fn more(_: void, a: Item, b: Item) bool {
                if (a.bytes != b.bytes) return a.bytes > b.bytes;
                return a.id < b.id;
            }
        }.more);

        var file_start: u64 = 0;
        var file_end: u64 = 0;
        if (s.dir) |d| {
            const rec = try self.r.dir(d);
            file_start = rec.first_file;
            file_end = rec.first_file + rec.direct_files;
        }
        var files = self.removed.aliveFiles(file_start, file_end);
        const alive_files = (file_end - file_start) - self.removed.removedFilesIn(file_start, file_end);

        try json.beginObject();
        try json.objectField("key");
        try json.write("all");
        try json.objectField("bytes");
        try json.write(s.agg.bytes);
        try json.objectField("files");
        try json.write(s.agg.files);
        try json.objectField("items");
        try json.beginArray();
        var shown: u64 = 0;
        var shown_bytes: u64 = 0;
        var next_dir: usize = 0;
        var next_file = files.next();
        var next_file_rec: ?FileRecord = if (next_file) |f| try self.r.file(f) else null;
        while (shown < limit) {
            const dir_item: ?Item = if (next_dir < subdirs.items.len) subdirs.items[next_dir] else null;
            if (dir_item == null and next_file_rec == null) break;
            const take_dir = if (dir_item) |di| (next_file_rec == null or di.bytes >= next_file_rec.?.bytes) else false;
            if (take_dir) {
                const item = dir_item.?;
                const id: u32 = @intCast(item.id);
                const rec = try self.r.dir(id);
                try self.writeDir(json, id, &rec, self.dirAgg(id, &rec));
                shown_bytes +|= item.bytes;
                next_dir += 1;
            } else {
                const rec = next_file_rec.?;
                try self.writeFile(json, next_file.?, &rec);
                shown_bytes +|= rec.bytes;
                next_file = files.next();
                next_file_rec = if (next_file) |f| try self.r.file(f) else null;
            }
            shown += 1;
        }
        try json.endArray();
        const total_items = subdirs.items.len + alive_files;
        try writeRest(json, total_items - shown, s.agg.bytes -| shown_bytes);
        try json.endObject();
    }

    /// Every file in the subtree, grouped by type or size band.
    fn bandGroups(self: *const View, json: *std.json.Stringify, s: *const Scope, by: By, per_group: usize) !void {
        const band_count = if (by == .type) category_count else size_bands.len;
        var heaps: [category_count]TopK = undefined;
        var bytes: [category_count]u64 = @splat(0);
        var counts: [category_count]u64 = @splat(0);
        for (heaps[0..band_count]) |*heap| {
            heap.* = .{ .items = try self.arena.alloc(TopK.Entry, per_group) };
        }
        var files = self.removed.aliveFiles(s.file_start, s.file_end);
        while (files.next()) |f| {
            const rec = try self.r.file(f);
            const band = if (by == .type) rec.categoryIndex() else bandOf(rec.bytes);
            bytes[band] +|= rec.bytes;
            counts[band] += 1;
            heaps[band].offer(rec.bytes, f);
        }

        var order: [category_count]usize = undefined;
        for (order[0..band_count], 0..) |*slot, i| slot.* = i;
        if (by == .type) {
            std.sort.pdq(usize, order[0..band_count], &bytes, struct {
                fn more(b: *const [category_count]u64, x: usize, y: usize) bool {
                    if (b[x] != b[y]) return b[x] > b[y];
                    return x < y;
                }
            }.more);
        }
        for (order[0..band_count]) |band| {
            if (counts[band] == 0) continue;
            try json.beginObject();
            try json.objectField("key");
            try json.write(if (by == .type) @tagName(@as(Category, @enumFromInt(band))) else size_bands[band].key);
            try json.objectField("bytes");
            try json.write(bytes[band]);
            try json.objectField("files");
            try json.write(counts[band]);
            try json.objectField("items");
            try json.beginArray();
            var shown_bytes: u64 = 0;
            const ranked = heaps[band].sorted();
            for (ranked) |entry| {
                const rec = try self.r.file(entry.id);
                try self.writeFile(json, entry.id, &rec);
                shown_bytes +|= rec.bytes;
            }
            try json.endArray();
            try writeRest(json, counts[band] - ranked.len, bytes[band] -| shown_bytes);
            try json.endObject();
        }
    }

    // --- largest -------------------------------------------------------------

    pub fn largest(self: *const View, json: *std.json.Stringify, query: LargestQuery) !void {
        const dir = try self.resolve(query.node, query.path);
        const s = try self.scope(dir);
        const limit = @min(query.limit, max_largest);

        try json.beginObject();
        try json.objectField("kind");
        try json.write(@tagName(query.kind));
        try json.objectField("items");
        try json.beginArray();
        switch (query.kind) {
            .files => try self.largestFiles(json, &s, query.type, limit),
            .folders => try self.largestFolders(json, &s, limit),
        }
        try json.endArray();
        try json.endObject();
    }

    fn largestFiles(self: *const View, json: *std.json.Stringify, s: *const Scope, want: ?Category, limit: usize) !void {
        // Every root and no type: the precomputed list, unless deletions ate
        // into it so far that it might no longer hold the true top.
        if (s.dir == null and want == null) {
            var picked: std.ArrayListUnmanaged(u64) = .empty;
            for (0..self.r.topCount()) |i| {
                if (picked.items.len == limit) break;
                const f = try self.r.topFile(i);
                if (!self.removed.fileRemoved(f)) try picked.append(self.arena, f);
            }
            const exhaustive = self.r.topCount() < top_capacity;
            if (picked.items.len == limit or exhaustive) {
                for (picked.items) |f| {
                    const rec = try self.r.file(f);
                    try self.writeFile(json, f, &rec);
                }
                return;
            }
        }
        var heap: TopK = .{ .items = try self.arena.alloc(TopK.Entry, limit) };
        var files = self.removed.aliveFiles(s.file_start, s.file_end);
        while (files.next()) |f| {
            const rec = try self.r.file(f);
            if (want) |w| {
                if (rec.categoryIndex() != @intFromEnum(w)) continue;
            }
            heap.offer(rec.bytes, f);
        }
        for (heap.sorted()) |entry| {
            const rec = try self.r.file(entry.id);
            try self.writeFile(json, entry.id, &rec);
        }
    }

    /// Folders below the scope by their whole size, leaving out wrappers: a
    /// folder that is 90% one subfolder says nothing that subfolder does not.
    fn largestFolders(self: *const View, json: *std.json.Stringify, s: *const Scope, limit: usize) !void {
        const first: u32 = if (s.dir) |d| d + 1 else 0;
        const count = s.dir_end - first;
        const sizes = try self.arena.alloc(u64, count);
        const biggest_child = try self.arena.alloc(u64, count);
        @memset(biggest_child, 0);
        for (0..count) |k| {
            const d: u32 = first + @as(u32, @intCast(k));
            const rec = try self.r.dir(d);
            sizes[k] = if (self.removed.dirRemoved(d)) 0 else self.dirAgg(d, &rec).bytes;
            if (rec.parent != no_parent and rec.parent >= first) {
                const p = rec.parent - first;
                biggest_child[p] = @max(biggest_child[p], sizes[k]);
            }
        }
        var heap: TopK = .{ .items = try self.arena.alloc(TopK.Entry, limit) };
        for (0..count) |k| {
            const d: u32 = first + @as(u32, @intCast(k));
            if (sizes[k] == 0) continue;
            const rec = try self.r.dir(d);
            // Scan roots are the scope, not findings inside it.
            if (rec.parent == no_parent) continue;
            const share = @as(f64, @floatFromInt(biggest_child[k])) / @as(f64, @floatFromInt(sizes[k]));
            if (share >= wrapper_share) continue;
            heap.offer(sizes[k], d);
        }
        for (heap.sorted()) |entry| {
            const d: u32 = @intCast(entry.id);
            const rec = try self.r.dir(d);
            try self.writeDir(json, d, &rec, self.dirAgg(d, &rec));
        }
    }

    // --- overview ------------------------------------------------------------

    pub fn overview(self: *const View, json: *std.json.Stringify, roots: []const []const u8, generated_at: i64, scan_time_ns: u64) !void {
        const h = &self.r.header;
        const all = try self.allAgg();
        var cat_files = h.cat_files;
        for (&cat_files, self.removed.cat_files) |*a, b| a.* -|= b;

        try json.beginObject();
        try json.objectField("roots");
        try json.beginArray();
        for (roots) |root| try json.write(try session_mod.lossy(self.arena, root));
        try json.endArray();
        try json.objectField("generated_at");
        try json.write(generated_at);
        try json.objectField("scan_time_ns");
        try json.write(scan_time_ns);
        try json.objectField("volume");
        try json.beginObject();
        try json.objectField("mount");
        try json.write(try session_mod.lossy(self.arena, try self.r.mount()));
        try json.objectField("total");
        try json.write(h.volume_total);
        try json.objectField("free");
        try json.write(h.volume_free);
        try json.objectField("available");
        try json.write(h.volume_available);
        try json.endObject();
        inline for (.{
            .{ "files", all.files },
            .{ "dirs", all.dirs },
            .{ "bytes", all.bytes },
            .{ "logical", all.logical },
            .{ "dataless_files", all.dataless },
            .{ "dataless_logical", h.dataless_logical },
            .{ "hard_links", h.hard_links },
            .{ "excluded", h.excluded },
            .{ "errors", h.errors },
            .{ "incomplete_dirs", h.incomplete_dirs },
            .{ "removed_count", self.removed.entries.items.len },
            .{ "removed_bytes", self.removed.total().bytes },
        }) |field| {
            try json.objectField(field[0]);
            try json.write(field[1]);
        }
        try json.objectField("types");
        try writeTypes(json, all, cat_files);
        try json.endObject();
    }
};

// ===========================================================================
// History
// ===========================================================================
//
// One JSON file per volume in a folder the host names, so a rescan can say
// what grew. Each scan contributes its totals and the size of every folder
// down to `history_depth` below a root that holds a noticeable share.

pub const history_max_entries: usize = 30;
pub const history_depth: u32 = 3;
pub const history_max_folders: usize = 3000;
const history_min_folder: u64 = 1 << 20;

const HistoryFolder = struct { path: []const u8, bytes: u64 };

const HistoryEntry = struct {
    generated_at: i64,
    roots: []const []const u8,
    total: u64 = 0,
    free: u64 = 0,
    bytes: u64 = 0,
    files: u64 = 0,
    types: [category_count]u64 = @splat(0),
    folders: []const HistoryFolder = &.{},
};

const HistoryFile = struct {
    version: u32 = 1,
    mount: []const u8 = "",
    entries: []const HistoryEntry = &.{},
};

pub const HistoryInput = struct {
    dir: []const u8,
    roots: []const []const u8,
    /// Epoch milliseconds, the scan's own.
    generated_at: i64,
};

/// Record this scan in the volume's history (once per scan) and describe the
/// history: every scan's totals, and what grew and shrank since the previous
/// scan of the same roots. Uses the scan's own figures, not what deleting
/// since has changed.
pub fn history(gpa: Allocator, arena: Allocator, r: *const Reader, json: *std.json.Stringify, input: HistoryInput) !void {
    const mount = try r.mount();
    const lossy_mount = try session_mod.lossy(arena, mount);
    const file_path = try historyPath(arena, input.dir, lossy_mount);

    var loaded: HistoryFile = .{ .mount = lossy_mount };
    if (removed_mod.readWholeFile(gpa, file_path.ptr, 64 * 1024 * 1024)) |bytes| {
        defer gpa.free(bytes);
        if (std.json.parseFromSliceLeaky(HistoryFile, arena, bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        })) |parsed| loaded = parsed else |_| {}
    } else |_| {}

    const roots = try arena.alloc([]const u8, input.roots.len);
    for (input.roots, roots) |root, *slot| slot.* = try session_mod.lossy(arena, root);

    const current = try currentEntry(arena, r, roots, input.generated_at);

    var entries: std.ArrayListUnmanaged(HistoryEntry) = .empty;
    var recorded = false;
    for (loaded.entries) |entry| {
        if (entry.generated_at == current.generated_at and sameRoots(entry.roots, roots)) recorded = true;
        try entries.append(arena, entry);
    }
    if (!recorded) {
        try entries.append(arena, current);
        std.sort.pdq(HistoryEntry, entries.items, {}, struct {
            fn less(_: void, a: HistoryEntry, b: HistoryEntry) bool {
                return a.generated_at < b.generated_at;
            }
        }.less);
        if (entries.items.len > history_max_entries) {
            const drop = entries.items.len - history_max_entries;
            entries.items = entries.items[drop..];
        }
        writeHistory(arena, file_path, .{ .mount = lossy_mount, .entries = entries.items }) catch {};
    }

    // The latest earlier scan of the same folders.
    var previous: ?HistoryEntry = null;
    for (entries.items) |entry| {
        if (entry.generated_at < current.generated_at and sameRoots(entry.roots, roots)) previous = entry;
    }

    try json.beginObject();
    try json.objectField("mount");
    try json.write(lossy_mount);
    try json.objectField("current");
    try json.write(current.generated_at);
    try json.objectField("previous");
    if (previous) |p| try json.write(p.generated_at) else try json.write(null);
    try json.objectField("entries");
    try json.beginArray();
    for (entries.items) |entry| {
        try json.beginObject();
        try json.objectField("generated_at");
        try json.write(entry.generated_at);
        try json.objectField("roots");
        try json.write(entry.roots);
        try json.objectField("total");
        try json.write(entry.total);
        try json.objectField("free");
        try json.write(entry.free);
        try json.objectField("used");
        try json.write(entry.total -| entry.free);
        try json.objectField("bytes");
        try json.write(entry.bytes);
        try json.objectField("files");
        try json.write(entry.files);
        try json.objectField("same_roots");
        try json.write(sameRoots(entry.roots, roots));
        try json.endObject();
    }
    try json.endArray();

    const Change = struct { path: []const u8, before: ?u64, now: u64, delta: i64 };
    var changes: std.ArrayListUnmanaged(Change) = .empty;
    if (previous) |p| {
        var before: std.StringHashMapUnmanaged(u64) = .empty;
        for (p.folders) |folder| try before.put(arena, folder.path, folder.bytes);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (current.folders) |folder| {
            try seen.put(arena, folder.path, {});
            const was = before.get(folder.path);
            const delta = signedDelta(folder.bytes, was orelse 0);
            if (delta != 0) try changes.append(arena, .{ .path = folder.path, .before = was, .now = folder.bytes, .delta = delta });
        }
        for (p.folders) |folder| {
            if (seen.contains(folder.path)) continue;
            // Gone, or shrunk below what a scan records; treat as 0 either way.
            try changes.append(arena, .{ .path = folder.path, .before = folder.bytes, .now = 0, .delta = signedDelta(0, folder.bytes) });
        }
    }
    std.sort.pdq(Change, changes.items, {}, struct {
        fn less(_: void, a: Change, b: Change) bool {
            if (a.delta != b.delta) return a.delta > b.delta;
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.less);

    const Emit = struct {
        fn one(j: *std.json.Stringify, rd: *const Reader, change: Change) !void {
            try j.beginObject();
            try j.objectField("path");
            try j.write(change.path);
            try j.objectField("id");
            if (rd.locate(change.path) catch null) |found| switch (found) {
                .dir => |d| try j.write(d),
                .file => try j.write(null),
            } else try j.write(null);
            try j.objectField("before");
            if (change.before) |b| try j.write(b) else try j.write(null);
            try j.objectField("now");
            try j.write(change.now);
            try j.objectField("delta");
            try j.write(change.delta);
            try j.endObject();
        }
    };
    try json.objectField("growth");
    try json.beginArray();
    var shown: usize = 0;
    for (changes.items) |change| {
        if (change.delta <= 0 or shown == 30) break;
        try Emit.one(json, r, change);
        shown += 1;
    }
    try json.endArray();
    try json.objectField("shrink");
    try json.beginArray();
    shown = 0;
    var i = changes.items.len;
    while (i > 0 and shown < 15) {
        i -= 1;
        if (changes.items[i].delta >= 0) break;
        try Emit.one(json, r, changes.items[i]);
        shown += 1;
    }
    try json.endArray();
    try json.endObject();
}

fn signedDelta(now: u64, before: u64) i64 {
    const max: u64 = std.math.maxInt(i64);
    if (now >= before) return @intCast(@min(now - before, max));
    return -@as(i64, @intCast(@min(before - now, max)));
}

fn sameRoots(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a) |x| {
        for (b) |y| {
            if (std.mem.eql(u8, x, y)) break;
        } else return false;
    }
    return true;
}

fn currentEntry(arena: Allocator, r: *const Reader, roots: []const []const u8, generated_at: i64) !HistoryEntry {
    const h = &r.header;
    var types_bytes: [category_count]u64 = @splat(0);
    var total: Agg = .{};
    var c: u32 = 0;
    const n = r.dirCount();
    while (c < n) {
        const d = try r.dir(c);
        total.add(d.agg());
        c = d.subtree_end;
    }
    types_bytes = total.cat;

    const threshold = @max(history_min_folder, total.bytes / 2000);
    var heap: TopK = .{ .items = try arena.alloc(TopK.Entry, history_max_folders) };
    var depth = try arena.alloc(u32, n);
    for (0..n) |i| {
        const d = try r.dir(i);
        depth[i] = if (d.parent == no_parent) 0 else depth[d.parent] + 1;
        if (depth[i] > history_depth or d.bytes < threshold) continue;
        heap.offer(d.bytes, i);
    }
    const ranked = heap.sorted();
    const folders = try arena.alloc(HistoryFolder, ranked.len);
    for (ranked, folders) |entry, *slot| {
        const d = try r.dir(entry.id);
        slot.* = .{ .path = try session_mod.lossy(arena, try r.dirPath(arena, @intCast(entry.id))), .bytes = d.bytes };
    }
    return .{
        .generated_at = generated_at,
        .roots = roots,
        .total = h.volume_total,
        .free = h.volume_free,
        .bytes = total.bytes,
        .files = total.files,
        .types = types_bytes,
        .folders = folders,
    };
}

fn historyPath(arena: Allocator, dir: []const u8, mount: []const u8) ![:0]u8 {
    const key = std.hash.Wyhash.hash(0, mount);
    const trimmed = if (dir.len > 1) std.mem.trimEnd(u8, dir, "/") else dir;
    return std.fmt.allocPrintSentinel(arena, "{s}/space-history-{x:0>16}.json", .{ trimmed, key }, 0);
}

fn writeHistory(arena: Allocator, path: [:0]const u8, file: HistoryFile) !void {
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(file, .{}, &out.writer);
    const bytes = out.written();

    const partial = try std.fmt.allocPrintSentinel(arena, "{s}.partial", .{path}, 0);
    const fd = libc.open(partial.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(libc.mode_t, 0o600));
    if (fd < 0) return error.CannotCreateFile;
    var written: usize = 0;
    while (written < bytes.len) {
        const n = libc.write(fd, bytes.ptr + written, bytes.len - written);
        if (n < 0) {
            if (libc.errno(n) == .INTR) continue;
            _ = libc.close(fd);
            _ = libc.unlink(partial.ptr);
            return error.WriteFailed;
        }
        if (n == 0) break;
        written += @intCast(n);
    }
    if (libc.close(fd) != 0 or written != bytes.len) {
        _ = libc.unlink(partial.ptr);
        return error.WriteFailed;
    }
    if (libc.rename(partial.ptr, path.ptr) != 0) {
        _ = libc.unlink(partial.ptr);
        return error.RenameFailed;
    }
}
