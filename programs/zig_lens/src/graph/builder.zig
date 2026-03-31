const std = @import("std");
const models = @import("../models.zig");

pub const GraphNode = struct {
    path: []const u8,
    loc: u32,
    fan_in: u32,
    fan_out: u32,
    is_entry: bool,
};

pub const GraphEdge = struct {
    from: []const u8,
    to: []const u8,
};

pub const DependencyGraph = struct {
    nodes: std.ArrayListUnmanaged(GraphNode),
    edges: std.ArrayListUnmanaged(GraphEdge),
    hub_files: std.ArrayListUnmanaged([]const u8),
    orphan_files: std.ArrayListUnmanaged([]const u8),
    max_depth: u32,
    cycles: std.ArrayListUnmanaged([]const []const u8),

    pub fn init() DependencyGraph {
        return .{
            .nodes = .empty,
            .edges = .empty,
            .hub_files = .empty,
            .orphan_files = .empty,
            .max_depth = 0,
            .cycles = .empty,
        };
    }
};

pub fn buildGraph(allocator: std.mem.Allocator, report: *const models.ProjectReport) !DependencyGraph {
    var graph = DependencyGraph.init();

    // Build file set for quick lookup of local files
    var file_set = std.StringHashMap(u32).init(allocator);
    for (report.files.items, 0..) |*file, idx| {
        try file_set.put(file.relative_path, @intCast(idx));
    }

    // Count fan-in for each file
    var fan_in_map = std.StringHashMap(u32).init(allocator);

    // Build edges from imports
    for (report.files.items) |*file| {
        var fan_out: u32 = 0;
        for (file.imports.items) |*imp| {
            if (imp.kind != .local) continue;

            // Resolve relative path
            const resolved = resolveImportPath(allocator, file.relative_path, imp.path) catch continue;

            // Check if target exists in project
            if (file_set.contains(resolved)) {
                try graph.edges.append(allocator, .{
                    .from = file.relative_path,
                    .to = resolved,
                });
                fan_out += 1;

                const current = fan_in_map.get(resolved) orelse 0;
                try fan_in_map.put(resolved, current + 1);
            }
        }

        const fan_in = fan_in_map.get(file.relative_path) orelse 0;
        const is_entry = std.mem.eql(u8, std.fs.path.basename(file.relative_path), "main.zig") or
            std.mem.eql(u8, std.fs.path.basename(file.relative_path), "build.zig");

        try graph.nodes.append(allocator, .{
            .path = file.relative_path,
            .loc = file.loc,
            .fan_in = fan_in,
            .fan_out = fan_out,
            .is_entry = is_entry,
        });
    }

    // Update fan_in values (second pass since fan_in is computed after edges)
    for (graph.nodes.items) |*node| {
        node.fan_in = fan_in_map.get(node.path) orelse 0;
    }

    // Find hub files (fan_in >= 3)
    for (graph.nodes.items) |*node| {
        if (node.fan_in >= 3) {
            try graph.hub_files.append(allocator, node.path);
        }
    }

    // Find orphan files (no importers, not entry points)
    for (graph.nodes.items) |*node| {
        if (node.fan_in == 0 and !node.is_entry) {
            try graph.orphan_files.append(allocator, node.path);
        }
    }

    return graph;
}

fn resolveImportPath(allocator: std.mem.Allocator, from_file: []const u8, import_path: []const u8) ![]const u8 {
    // Get directory of the source file
    const dir = std.fs.path.dirname(from_file) orelse "";

    if (dir.len == 0) {
        return try allocator.dupe(u8, import_path);
    }

    // Handle relative paths
    if (std.mem.startsWith(u8, import_path, "../")) {
        const parent = std.fs.path.dirname(dir) orelse "";
        if (parent.len == 0) {
            return try allocator.dupe(u8, import_path[3..]);
        }
        return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, import_path[3..] });
    }

    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, import_path });
}
