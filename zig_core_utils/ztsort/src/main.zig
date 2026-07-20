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

    // Find a cycle among the not-yet-emitted nodes, report each member to stderr
    // in GNU tsort's format, and return the index of the node to force-emit to
    // break the cycle. Mirrors GNU tsort: it walks the successor chain from the
    // lowest-index remaining node until it revisits a node on the current path.
    fn reportCycle(self: *Graph, input_name: []const u8) !usize {
        // Lowest-index node still on the graph.
        var start: usize = 0;
        while (start < self.nodes.items.len and self.nodes.items[start].emitted) : (start += 1) {}
        std.debug.assert(start < self.nodes.items.len);

        // path[k] = node visited at step k; pos_stamp marks a node's step+1 (0 = unvisited on this walk).
        var path = std.ArrayListUnmanaged(usize).empty;
        defer path.deinit(self.allocator);
        const pos_stamp = try self.allocator.alloc(usize, self.nodes.items.len);
        defer self.allocator.free(pos_stamp);
        @memset(pos_stamp, 0);

        var cur: usize = start;
        var cycle_begin: usize = start; // node where the cycle closes
        while (true) {
            if (pos_stamp[cur] != 0) {
                // Revisited a node on the current path: cycle is path[pos..].
                cycle_begin = cur;
                break;
            }
            try path.append(self.allocator, cur);
            pos_stamp[cur] = path.items.len; // step+1
            // Follow the first not-yet-emitted successor.
            var next: ?usize = null;
            for (self.nodes.items[cur].successors.items) |succ| {
                if (!self.nodes.items[succ].emitted) {
                    next = succ;
                    break;
                }
            }
            if (next) |n| {
                cur = n;
            } else {
                // Dead end without closing a cycle: treat the start node as a
                // singleton loop so we still make progress.
                cycle_begin = start;
                break;
            }
        }

        // Report the loop. GNU: "<prog>: <input>: input contains a loop:" then
        // one "<prog>: <name>" line per cycle member.
        writeStderr("ztsort: ");
        writeStderr(input_name);
        writeStderr(": input contains a loop:\n");

        const begin_step = pos_stamp[cycle_begin]; // 1-based; 0 only if dead-end singleton
        const from_idx = if (begin_step == 0) 0 else begin_step - 1;
        var k: usize = from_idx;
        while (k < path.items.len) : (k += 1) {
            const member = self.nodes.items[path.items[k]].name;
            writeStderr("ztsort: ");
            writeStderr(member);
            writeStderr("\n");
        }

        return cycle_begin;
    }

    // Topologically sort. Emits a full total ordering even in the presence of
    // cycles (matching GNU tsort), reporting each detected loop to stderr.
    // Returns true iff the graph was acyclic.
    fn topoSort(self: *Graph, out: *OutputBuffer, input_name: []const u8) !bool {
        // Kahn's algorithm with cycle-breaking.
        var queue = std.ArrayListUnmanaged(usize).empty;
        defer queue.deinit(self.allocator);

        // Seed with all in_degree-0 nodes.
        for (self.nodes.items, 0..) |node, i| {
            if (node.in_degree == 0) {
                try queue.append(self.allocator, i);
            }
        }

        var had_loop = false;
        var count: usize = 0;
        while (count < self.nodes.items.len) {
            // Drain everything currently emittable.
            while (queue.items.len > 0) {
                const idx = queue.orderedRemove(0);
                const node = &self.nodes.items[idx];

                if (node.emitted) continue;
                node.emitted = true;

                out.write(node.name);
                out.writeByte('\n');
                count += 1;

                for (node.successors.items) |succ_idx| {
                    const succ = &self.nodes.items[succ_idx];
                    succ.in_degree -|= 1;
                    if (succ.in_degree == 0 and !succ.emitted) {
                        try queue.append(self.allocator, succ_idx);
                    }
                }
            }

            if (count < self.nodes.items.len) {
                // A cycle remains. Report it and break it by force-emitting a
                // node from the cycle, then continue.
                had_loop = true;
                const forced = try self.reportCycle(input_name);
                self.nodes.items[forced].in_degree = 0;
                try queue.append(self.allocator, forced);
            }
        }

        return !had_loop;
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

extern "c" fn strerror(errnum: c_int) callconv(.c) [*:0]u8;

fn errno() c_int {
    return std.c._errno().*;
}

fn writeStderr(s: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, s.ptr, s.len);
}

fn readInput(allocator: std.mem.Allocator, fd: c_int) ![]u8 {
    var content = std.ArrayListUnmanaged(u8).empty;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = libc.read(fd, &buf, buf.len);
        if (n < 0) {
            // Retry on interrupt / would-block rather than truncating input.
            const e = errno();
            if (e == @intFromEnum(std.c.E.INTR) or e == @intFromEnum(std.c.E.AGAIN)) continue;
            return error.ReadFailed;
        }
        if (n == 0) break; // genuine EOF
        try content.appendSlice(allocator, buf[0..@intCast(n)]);
    }
    return content.toOwnedSlice(allocator);
}

fn parseInput(graph: *Graph, input: []const u8, input_name: []const u8) !void {
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

    // GNU tsort: an odd number of tokens is a fatal error.
    if (tokens.items.len % 2 == 1) {
        writeStderr("ztsort: ");
        writeStderr(input_name);
        writeStderr(": input contains an odd number of tokens\n");
        std.process.exit(1);
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
}

const version_text =
    \\ztsort (zig-forge coreutils) 1.0
    \\Topological sort, compatible with GNU tsort (coreutils) behavior.
    \\
;

const help_text =
    \\Usage: ztsort [OPTION] [FILE]
    \\Write totally ordered list consistent with the partial ordering in FILE.
    \\
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\      --help     display this help and exit
    \\      --version  output version information and exit
    \\
;

// Emit "ztsort: <pre><mid><post>\n" + the standard --help hint, then exit 1.
// Direct writes keep arbitrarily long operands/options from being truncated.
fn usageError(pre: []const u8, mid: []const u8, post: []const u8) noreturn {
    writeStderr("ztsort: ");
    writeStderr(pre);
    writeStderr(mid);
    writeStderr(post);
    writeStderr("\n");
    writeStderr("Try 'ztsort --help' for more information.\n");
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();

    var file_path: ?[]const u8 = null; // null => stdin
    var input_name: []const u8 = "-"; // name used in diagnostics
    var operand_seen = false;
    var options_done = false;

    while (args.next()) |arg| {
        if (!options_done and arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
            // Long option.
            if (std.mem.eql(u8, arg, "--")) {
                options_done = true;
            } else if (std.mem.eql(u8, arg, "--help")) {
                _ = libc.write(libc.STDOUT_FILENO, help_text.ptr, help_text.len);
                return;
            } else if (std.mem.eql(u8, arg, "--version")) {
                _ = libc.write(libc.STDOUT_FILENO, version_text.ptr, version_text.len);
                return;
            } else {
                usageError("unrecognized option '", arg, "'");
            }
        } else if (!options_done and arg.len >= 2 and arg[0] == '-') {
            // Short option cluster. tsort defines no short options.
            usageError("invalid option -- '", arg[1..2], "'");
        } else {
            // Operand: "-" means stdin; anything else is a filename.
            if (operand_seen) {
                usageError("extra operand '", arg, "'");
            }
            operand_seen = true;
            if (std.mem.eql(u8, arg, "-")) {
                file_path = null;
                input_name = "-";
            } else {
                file_path = arg;
                input_name = arg;
            }
        }
    }

    var graph = Graph.init(allocator);
    defer graph.deinit();

    const input = if (file_path) |path| blk: {
        // NUL-terminate via an allocation (no fixed-size stack buffer / no OOB).
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        const fd = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd < 0) {
            // Direct writes: the path may be arbitrarily long (a fixed bufPrint
            // buffer would truncate/fail and must never swallow the error).
            const reason = strerror(errno());
            writeStderr("ztsort: ");
            writeStderr(path);
            writeStderr(": ");
            writeStderr(std.mem.span(reason));
            writeStderr("\n");
            std.process.exit(1);
        }
        defer _ = libc.close(fd);
        break :blk try readInput(allocator, fd);
    } else try readInput(allocator, libc.STDIN_FILENO);
    defer allocator.free(input);

    try parseInput(&graph, input, input_name);

    var out = OutputBuffer{};
    const success = try graph.topoSort(&out, input_name);
    out.flush();

    if (!success) {
        // Loop members were already reported by topoSort; GNU exits 1.
        std.process.exit(1);
    }
}
