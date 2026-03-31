const std = @import("std");
const builder = @import("builder.zig");

/// Detect strongly connected components using Tarjan's algorithm.
/// Returns cycles (SCCs with more than one node).
pub fn detectCycles(allocator: std.mem.Allocator, graph: *const builder.DependencyGraph) !std.ArrayListUnmanaged([]const []const u8) {
    var cycles: std.ArrayListUnmanaged([]const []const u8) = .empty;

    const n = graph.nodes.items.len;
    if (n == 0) return cycles;

    // Map path -> index
    var path_to_idx = std.StringHashMap(usize).init(allocator);
    for (graph.nodes.items, 0..) |*node, i| {
        try path_to_idx.put(node.path, i);
    }

    // Build adjacency list
    var adj = try allocator.alloc(std.ArrayListUnmanaged(usize), n);
    for (adj) |*a| a.* = .{};

    for (graph.edges.items) |*edge| {
        const from = path_to_idx.get(edge.from) orelse continue;
        const to = path_to_idx.get(edge.to) orelse continue;
        try adj[from].append(allocator, to);
    }

    // Tarjan's state
    var index: usize = 0;
    const indices = try allocator.alloc(i64, n);
    const lowlinks = try allocator.alloc(i64, n);
    const on_stack = try allocator.alloc(bool, n);
    @memset(indices, -1);
    @memset(lowlinks, -1);
    @memset(on_stack, false);

    var stack: std.ArrayListUnmanaged(usize) = .empty;

    for (0..n) |v| {
        if (indices[v] == -1) {
            try strongConnect(allocator, v, &index, indices, lowlinks, on_stack, &stack, adj, graph, &cycles);
        }
    }

    return cycles;
}

fn strongConnect(
    allocator: std.mem.Allocator,
    v: usize,
    index: *usize,
    indices: []i64,
    lowlinks: []i64,
    on_stack: []bool,
    stack: *std.ArrayListUnmanaged(usize),
    adj: []std.ArrayListUnmanaged(usize),
    graph: *const builder.DependencyGraph,
    cycles: *std.ArrayListUnmanaged([]const []const u8),
) !void {
    indices[v] = @intCast(index.*);
    lowlinks[v] = @intCast(index.*);
    index.* += 1;
    try stack.append(allocator, v);
    on_stack[v] = true;

    for (adj[v].items) |w| {
        if (indices[w] == -1) {
            try strongConnect(allocator, w, index, indices, lowlinks, on_stack, stack, adj, graph, cycles);
            lowlinks[v] = @min(lowlinks[v], lowlinks[w]);
        } else if (on_stack[w]) {
            lowlinks[v] = @min(lowlinks[v], indices[w]);
        }
    }

    if (lowlinks[v] == indices[v]) {
        var scc: std.ArrayListUnmanaged([]const u8) = .empty;
        while (true) {
            const w = stack.pop();
            on_stack[w] = false;
            try scc.append(allocator, graph.nodes.items[w].path);
            if (w == v) break;
        }
        // Only report cycles (SCC with > 1 node)
        if (scc.items.len > 1) {
            try cycles.append(allocator, try scc.toOwnedSlice(allocator));
        }
    }
}

// ============================================================================
// Unit Tests
// ============================================================================

test "detectCycles with empty graph" {
    const allocator = std.heap.c_allocator;

    var graph = builder.DependencyGraph{
        .nodes = .{},
        .edges = .{},
        .hub_files = .{},
        .orphan_files = .{},
        .max_depth = 0,
        .cycles = .{},
    };
    defer {
        graph.nodes.deinit(allocator);
        graph.edges.deinit(allocator);
        graph.hub_files.deinit(allocator);
        graph.orphan_files.deinit(allocator);
        graph.cycles.deinit(allocator);
    }

    const cycles = try detectCycles(allocator, &graph);
    defer {
        for (cycles.items) |cycle| {
            allocator.free(cycle);
        }
        cycles.deinit(allocator);
    }

    try std.testing.expectEqual(cycles.items.len, 0);
}

test "detectCycles with single node" {
    const allocator = std.heap.c_allocator;

    var graph = builder.DependencyGraph{
        .nodes = .{},
        .edges = .{},
        .hub_files = .{},
        .orphan_files = .{},
        .max_depth = 0,
        .cycles = .{},
    };
    defer {
        graph.nodes.deinit(allocator);
        graph.edges.deinit(allocator);
        graph.hub_files.deinit(allocator);
        graph.orphan_files.deinit(allocator);
        graph.cycles.deinit(allocator);
    }

    try graph.nodes.append(allocator, .{
        .path = "test.zig",
        .loc = 10,
        .fan_in = 0,
        .fan_out = 0,
        .is_entry = false,
    });

    const cycles = try detectCycles(allocator, &graph);
    defer {
        for (cycles.items) |cycle| {
            allocator.free(cycle);
        }
        cycles.deinit(allocator);
    }

    try std.testing.expectEqual(cycles.items.len, 0);
}
