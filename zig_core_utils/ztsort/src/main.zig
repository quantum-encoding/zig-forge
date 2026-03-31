const std = @import("std");
const posix = std.posix;
const libc = std.c;

const Node = struct {
    name: []const u8,
    successors: std.ArrayListUnmanaged(usize), // nodes that must come after this one
    in_degree: usize, // count of predecessors
    emitted: bool,
};

const Graph = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(Node),
    name_map: std.StringHashMapUnmanaged(usize),

    fn init(allocator: std.mem.Allocator) Graph {
        return .{
            .allocator = allocator,
            .nodes = .empty,
            .name_map = .empty,
        };
    }

    fn deinit(self: *Graph) void {
        for (self.nodes.items) |*node| {
            node.successors.deinit(self.allocator);
            self.allocator.free(node.name);
        }
        self.nodes.deinit(self.allocator);
        self.name_map.deinit(self.allocator);
    }

    fn getOrCreateNode(self: *Graph, name: []const u8) !usize {
        if (self.name_map.get(name)) |idx| {
            return idx;
        }
        const idx = self.nodes.items.len;
        const name_copy = try self.allocator.dupe(u8, name);
        try self.nodes.append(self.allocator, .{
            .name = name_copy,
            .successors = .empty,
            .in_degree = 0,
            .emitted = false,
        });
        try self.name_map.put(self.allocator, name_copy, idx);
        return idx;
    }

    fn addEdge(self: *Graph, from: usize, to: usize) !void {
        // from must come before to
        // Add to as a successor of from
        try self.nodes.items[from].successors.append(self.allocator, to);
        // Increment to's in_degree
        self.nodes.items[to].in_degree += 1;
    }

    fn topoSort(self: *Graph, out: *OutputBuffer) !bool {
        // Kahn's algorithm
        var queue = std.ArrayListUnmanaged(usize).empty;
        defer queue.deinit(self.allocator);

        // Find all nodes with in_degree 0
        for (self.nodes.items, 0..) |node, i| {
            if (node.in_degree == 0) {
                try queue.append(self.allocator, i);
            }
        }

        var count: usize = 0;
        while (queue.items.len > 0) {
            const idx = queue.orderedRemove(0);
            const node = &self.nodes.items[idx];

            if (node.emitted) continue;
            node.emitted = true;

            out.write(node.name);
            out.writeByte('\n');
            count += 1;

            // For each successor, decrement in_degree
            for (node.successors.items) |succ_idx| {
                const succ = &self.nodes.items[succ_idx];
                succ.in_degree -|= 1;
                if (succ.in_degree == 0 and !succ.emitted) {
                    try queue.append(self.allocator, succ_idx);
                }
            }
        }

        return count == self.nodes.items.len;
    }
};

const OutputBuffer = struct {
    buf: [8192]u8 = undefined,
    pos: usize = 0,

    fn write(self: *OutputBuffer, data: []const u8) void {
        for (data) |c| self.writeByte(c);
    }

    fn writeByte(self: *OutputBuffer, c: u8) void {
        self.buf[self.pos] = c;
        self.pos += 1;
        if (self.pos == self.buf.len) self.flush();
    }

    fn flush(self: *OutputBuffer) void {
        if (self.pos > 0) {
            _ = libc.write(libc.STDOUT_FILENO, &self.buf, self.pos);
            self.pos = 0;
        }
    }
};

fn readInput(allocator: std.mem.Allocator, fd: c_int) ![]u8 {
    var content = std.ArrayListUnmanaged(u8).empty;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = libc.read(fd, &buf, buf.len);
        if (n <= 0) break;
        try content.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    return content.toOwnedSlice(allocator);
}

fn parseInput(graph: *Graph, input: []const u8) !void {
    var tokens = std.ArrayListUnmanaged([]const u8).empty;
    defer tokens.deinit(graph.allocator);

    var i: usize = 0;
    while (i < input.len) {
        // Skip whitespace
        while (i < input.len and (input[i] == ' ' or input[i] == '\t' or input[i] == '\n' or input[i] == '\r')) {
            i += 1;
        }
        if (i >= input.len) break;

        // Read token
        const start = i;
        while (i < input.len and input[i] != ' ' and input[i] != '\t' and input[i] != '\n' and input[i] != '\r') {
            i += 1;
        }
        try tokens.append(graph.allocator, input[start..i]);
    }

    // Process pairs
    var j: usize = 0;
    while (j + 1 < tokens.items.len) : (j += 2) {
        const from_name = tokens.items[j];
        const to_name = tokens.items[j + 1];

        const from = try graph.getOrCreateNode(from_name);
        const to = try graph.getOrCreateNode(to_name);

        if (from != to) {
            try graph.addEdge(from, to);
        }
    }

    // Handle odd token (single node)
    if (tokens.items.len % 2 == 1) {
        _ = try graph.getOrCreateNode(tokens.items[tokens.items.len - 1]);
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();

    var file_path: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            const help =
                \\Usage: ztsort [FILE]
                \\Topologically sort input pairs.
                \\
                \\Read pairs of strings indicating partial ordering.
                \\Output a total ordering consistent with the partial ordering.
                \\
            ;
            _ = libc.write(libc.STDOUT_FILENO, help.ptr, help.len);
            return;
        } else if (arg.len > 0 and arg[0] != '-') {
            file_path = arg;
        }
    }

    var graph = Graph.init(allocator);
    defer graph.deinit();

    const input = if (file_path) |path| blk: {
        var path_buf: [4096]u8 = undefined;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(&path_buf);
        const fd = libc.open(path_z, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd < 0) {
            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "ztsort: {s}: cannot open\n", .{path}) catch return;
            _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
            std.process.exit(1);
        }
        defer _ = libc.close(fd);
        break :blk try readInput(allocator, fd);
    } else try readInput(allocator, libc.STDIN_FILENO);
    defer allocator.free(input);

    try parseInput(&graph, input);

    var out = OutputBuffer{};
    const success = try graph.topoSort(&out);
    out.flush();

    if (!success) {
        _ = libc.write(libc.STDERR_FILENO, "ztsort: input contains a loop\n", 31);
        std.process.exit(1);
    }
}
