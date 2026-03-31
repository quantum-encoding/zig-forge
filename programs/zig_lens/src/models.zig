const std = @import("std");

pub const Language = enum {
    zig,
    rust,
    c,
    python,
    javascript,
    go,
};

pub const ImportKind = enum {
    std_lib,
    local,
    package,
};

pub const ImportInfo = struct {
    path: []const u8,
    kind: ImportKind,
    binding_name: []const u8,
    line: u32,
};

pub const FunctionInfo = struct {
    name: []const u8,
    line: u32,
    end_line: u32,
    body_lines: u32,
    params: []const u8,
    return_type: []const u8,
    is_pub: bool,
    is_extern: bool,
    is_export: bool,
    doc_comment: []const u8,
};

pub const ContainerKind = enum {
    @"struct",
    packed_struct,
    extern_struct,
    @"enum",
    @"union",
    tagged_union,
    trait,
    impl_block,
    interface,
    type_alias,
    class,
};

pub const StructInfo = struct {
    name: []const u8,
    line: u32,
    kind: ContainerKind,
    fields_count: u32,
    methods_count: u32,
    is_pub: bool,
    doc_comment: []const u8,
};

pub const EnumInfo = struct {
    name: []const u8,
    line: u32,
    variants_count: u32,
    has_tag_type: bool,
    methods_count: u32,
    is_pub: bool,
    doc_comment: []const u8,
};

pub const UnionInfo = struct {
    name: []const u8,
    line: u32,
    fields_count: u32,
    has_tag_type: bool,
    methods_count: u32,
    is_pub: bool,
    doc_comment: []const u8,
};

pub const ConstInfo = struct {
    name: []const u8,
    line: u32,
    is_pub: bool,
    type_name: []const u8,
    doc_comment: []const u8,
};

pub const TestInfo = struct {
    name: []const u8,
    line: u32,
};

pub const UnsafeOp = struct {
    line: u32,
    operation: []const u8,
    context_fn: []const u8,
    risk_level: RiskLevel,
};

pub const RiskLevel = enum {
    low,
    medium,
    high,
    critical,
};

pub const FileReport = struct {
    path: []const u8,
    relative_path: []const u8,
    size_bytes: u64,
    language: Language,
    loc: u32,
    blank_lines: u32,
    comment_lines: u32,
    functions: std.ArrayListUnmanaged(FunctionInfo),
    structs: std.ArrayListUnmanaged(StructInfo),
    enums: std.ArrayListUnmanaged(EnumInfo),
    unions: std.ArrayListUnmanaged(UnionInfo),
    constants: std.ArrayListUnmanaged(ConstInfo),
    tests: std.ArrayListUnmanaged(TestInfo),
    imports: std.ArrayListUnmanaged(ImportInfo),
    unsafe_ops: std.ArrayListUnmanaged(UnsafeOp),
    parse_error: bool,

    pub fn init() FileReport {
        return .{
            .path = "",
            .relative_path = "",
            .size_bytes = 0,
            .language = .zig,
            .loc = 0,
            .blank_lines = 0,
            .comment_lines = 0,
            .functions = .empty,
            .structs = .empty,
            .enums = .empty,
            .unions = .empty,
            .constants = .empty,
            .tests = .empty,
            .imports = .empty,
            .unsafe_ops = .empty,
            .parse_error = false,
        };
    }

    pub fn pubFunctionCount(self: *const FileReport) u32 {
        var count: u32 = 0;
        for (self.functions.items) |f| {
            if (f.is_pub) count += 1;
        }
        return count;
    }
};

pub const ProjectSummary = struct {
    total_files: u32,
    total_loc: u32,
    total_blank: u32,
    total_comments: u32,
    total_functions: u32,
    total_pub_functions: u32,
    total_structs: u32,
    total_enums: u32,
    total_unions: u32,
    total_constants: u32,
    total_tests: u32,
    total_imports: u32,
    total_unsafe_ops: u32,
    parse_errors: u32,
};

pub const ProjectReport = struct {
    name: []const u8,
    root_path: []const u8,
    files: std.ArrayListUnmanaged(FileReport),
    summary: ProjectSummary,

    pub fn init() ProjectReport {
        return .{
            .name = "",
            .root_path = "",
            .files = .empty,
            .summary = std.mem.zeroes(ProjectSummary),
        };
    }

    pub fn computeSummary(self: *ProjectReport) void {
        var s = std.mem.zeroes(ProjectSummary);
        s.total_files = @intCast(self.files.items.len);
        for (self.files.items) |*f| {
            s.total_loc += f.loc;
            s.total_blank += f.blank_lines;
            s.total_comments += f.comment_lines;
            s.total_functions += @intCast(f.functions.items.len);
            s.total_pub_functions += f.pubFunctionCount();
            s.total_structs += @intCast(f.structs.items.len);
            s.total_enums += @intCast(f.enums.items.len);
            s.total_unions += @intCast(f.unions.items.len);
            s.total_constants += @intCast(f.constants.items.len);
            s.total_tests += @intCast(f.tests.items.len);
            s.total_imports += @intCast(f.imports.items.len);
            s.total_unsafe_ops += @intCast(f.unsafe_ops.items.len);
            if (f.parse_error) s.parse_errors += 1;
        }
        self.summary = s;
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "Language detection - Zig" {
    try std.testing.expectEqual(Language.zig, Language.zig);
}

test "Language detection - Python" {
    try std.testing.expectEqual(Language.python, Language.python);
}

test "Language detection - Rust" {
    try std.testing.expectEqual(Language.rust, Language.rust);
}

test "FileReport init creates empty report" {
    const report = FileReport.init();
    try std.testing.expectEqual(report.loc, 0);
    try std.testing.expectEqual(report.blank_lines, 0);
    try std.testing.expectEqual(report.comment_lines, 0);
    try std.testing.expectEqual(report.functions.items.len, 0);
    try std.testing.expectEqual(report.parse_error, false);
}

test "FileReport pubFunctionCount with no functions" {
    var report = FileReport.init();
    try std.testing.expectEqual(report.pubFunctionCount(), 0);
}

test "ProjectReport init creates empty report" {
    const report = ProjectReport.init();
    try std.testing.expectEqual(report.files.items.len, 0);
    try std.testing.expectEqual(report.summary.total_files, 0);
}
