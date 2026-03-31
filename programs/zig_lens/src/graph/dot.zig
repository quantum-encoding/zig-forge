const std = @import("std");
const builder = @import("builder.zig");

pub fn writeDot(allocator: std.mem.Allocator, graph: *const builder.DependencyGraph, project_name: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;

    try appendFmt(allocator, &buf, "digraph \"{s}\" {{\n", .{project_name});
    try appendFmt(allocator, &buf, "  rankdir=LR;\n", .{});
    try appendFmt(allocator, &buf, "  node [shape=box, style=filled, fontname=\"monospace\", fontsize=10];\n", .{});
    try appendFmt(allocator, &buf, "  edge [color=\"#666666\"];\n\n", .{});

    // Group by directory using subgraphs
    var dirs = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(allocator);

    for (graph.nodes.items) |*node| {
        const dir = std.fs.path.dirname(node.path) orelse "";
        const entry = try dirs.getOrPut(dir);
        if (!entry.found_existing) {
            entry.value_ptr.* = .empty;
        }
        try entry.value_ptr.append(allocator, node.path);
    }

    var cluster_id: u32 = 0;
    var dir_it = dirs.iterator();
    while (dir_it.next()) |entry| {
        const dir = entry.key_ptr.*;
        const files = entry.value_ptr.items;

        if (dir.len > 0) {
            try appendFmt(allocator, &buf, "  subgraph cluster_{d} {{\n", .{cluster_id});
            try appendFmt(allocator, &buf, "    label=\"{s}\";\n", .{dir});
            try appendFmt(allocator, &buf, "    style=dashed;\n", .{});
            try appendFmt(allocator, &buf, "    color=\"#999999\";\n", .{});
        }

        for (files) |path| {
            const color = nodeColor(graph, path);
            const basename = std.fs.path.basename(path);
            try appendFmt(allocator, &buf, "  \"{s}\" [label=\"{s}\", fillcolor=\"{s}\"];\n", .{ path, basename, color });
        }

        if (dir.len > 0) {
            try appendFmt(allocator, &buf, "  }}\n", .{});
        }
        cluster_id += 1;
    }

    try appendFmt(allocator, &buf, "\n", .{});

    // Edges
    for (graph.edges.items) |*edge| {
        try appendFmt(allocator, &buf, "  \"{s}\" -> \"{s}\";\n", .{ edge.from, edge.to });
    }

    try appendFmt(allocator, &buf, "}}\n", .{});

    return buf.items;
}

fn nodeColor(graph: *const builder.DependencyGraph, path: []const u8) []const u8 {
    for (graph.nodes.items) |*node| {
        if (std.mem.eql(u8, node.path, path)) {
            if (node.is_entry) return "#90EE90"; // green - entry points
            if (node.fan_in >= 3) return "#87CEEB"; // blue - hub modules
            if (node.fan_in == 0) return "#D3D3D3"; // gray - leaf/orphan
            return "#FFFACD"; // light yellow - normal
        }
    }
    return "#FFFFFF";
}

fn appendFmt(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    try buf.appendSlice(allocator, s);
}
