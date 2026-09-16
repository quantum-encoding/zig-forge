//! Substitution plans: which value each listed variable takes in variant i.
//!
//! A variable takes part in a plan when it has a `values` list and is not
//! pinned by the scenario or a CLI override (pinning is decided by the
//! caller, which passes the participating variables).
//!
//!   sequence  variant i uses values[i mod len] of every variable; with a
//!             seed, each variable's list is first shuffled deterministically
//!   matrix    the cartesian product, first variable slowest, so variant order
//!             matches nested loops over the legend's declaration order

const std = @import("std");
const legend_mod = @import("legend.zig");
const Legend = legend_mod.Legend;
const VarSpec = legend_mod.VarSpec;
const KV = legend_mod.KV;

/// The list variables of `legend` minus those in `pinned`, declaration order.
pub fn participants(gpa: std.mem.Allocator, legend: *const Legend, pinned: []const []const u8) ![]const *const VarSpec {
    var out: std.ArrayList(*const VarSpec) = .empty;
    errdefer out.deinit(gpa);
    for (legend.vars) |*v| {
        if (v.values.len == 0) continue;
        var is_pinned = false;
        for (pinned) |p| if (std.mem.eql(u8, p, v.name)) {
            is_pinned = true;
        };
        if (!is_pinned) try out.append(gpa, v);
    }
    return out.toOwnedSlice(gpa);
}

pub const Plan = struct {
    vars: []const *const VarSpec,
    /// Per variable, the index order to walk (identity unless shuffled).
    orders: []const []const usize,
    kind: enum { sequence, matrix },
    count: usize,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Plan) void {
        for (self.orders) |o| self.gpa.free(o);
        self.gpa.free(self.orders);
        self.gpa.free(self.vars);
    }

    /// Bindings chosen for variant `i`. Caller frees the slice; values are
    /// borrowed from the legend.
    pub fn pick(self: *const Plan, gpa: std.mem.Allocator, i: usize) ![]const KV {
        const out = try gpa.alloc(KV, self.vars.len);
        switch (self.kind) {
            .sequence => for (self.vars, 0..) |v, k| {
                const idx = self.orders[k][i % v.values.len];
                out[k] = .{ .key = v.name, .value = v.values[idx] };
            },
            .matrix => {
                var rem = i;
                var k = self.vars.len;
                while (k > 0) {
                    k -= 1;
                    const v = self.vars[k];
                    const idx = self.orders[k][rem % v.values.len];
                    rem /= v.values.len;
                    out[k] = .{ .key = v.name, .value = v.values[idx] };
                }
            },
        }
        return out;
    }
};

pub const PlanError = error{ OutOfMemory, NoListVariables, TooManyVariants };

/// `count` variants; `seed` shuffles each variable's list first.
pub fn sequence(gpa: std.mem.Allocator, vars: []const *const VarSpec, count: usize, seed: ?u64) PlanError!Plan {
    if (vars.len == 0) return error.NoListVariables;
    const orders = try makeOrders(gpa, vars, seed);
    return .{ .vars = try gpa.dupe(*const VarSpec, vars), .orders = orders, .kind = .sequence, .count = count, .gpa = gpa };
}

/// Every combination, capped at `max` variants.
pub fn matrix(gpa: std.mem.Allocator, vars: []const *const VarSpec, max: usize) PlanError!Plan {
    if (vars.len == 0) return error.NoListVariables;
    var total: usize = 1;
    for (vars) |v| {
        total = std.math.mul(usize, total, v.values.len) catch return error.TooManyVariants;
        if (total > max) return error.TooManyVariants;
    }
    const orders = try makeOrders(gpa, vars, null);
    return .{ .vars = try gpa.dupe(*const VarSpec, vars), .orders = orders, .kind = .matrix, .count = total, .gpa = gpa };
}

fn makeOrders(gpa: std.mem.Allocator, vars: []const *const VarSpec, seed: ?u64) ![]const []const usize {
    var prng = std.Random.DefaultPrng.init(seed orelse 0);
    const rng = prng.random();
    const orders = try gpa.alloc([]const usize, vars.len);
    var made: usize = 0;
    errdefer {
        for (orders[0..made]) |o| gpa.free(o);
        gpa.free(orders);
    }
    for (vars, 0..) |v, k| {
        const o = try gpa.alloc(usize, v.values.len);
        for (o, 0..) |*slot, i| slot.* = i;
        if (seed != null) rng.shuffle(usize, o);
        orders[k] = o;
        made += 1;
    }
    return orders;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Diag = @import("diag.zig").Diag;

const lg =
    \\[[var]]
    \\name = "A"
    \\values = ["a1", "a2"]
    \\[[var]]
    \\name = "B"
    \\values = ["b1", "b2", "b3"]
    \\[[var]]
    \\name = "C"
    \\value = "fixed"
;

test "sequence walks each list round-robin" {
    var d = Diag{};
    var l = try Legend.load(testing.allocator, lg, &d);
    defer l.deinit();
    const vars = try participants(testing.allocator, &l, &.{});
    defer testing.allocator.free(vars);
    try testing.expectEqual(@as(usize, 2), vars.len);
    var p = try sequence(testing.allocator, vars, 4, null);
    defer p.deinit();
    const expect = [_][2][]const u8{ .{ "a1", "b1" }, .{ "a2", "b2" }, .{ "a1", "b3" }, .{ "a2", "b1" } };
    for (expect, 0..) |e, i| {
        const kv = try p.pick(testing.allocator, i);
        defer testing.allocator.free(kv);
        try testing.expectEqualStrings(e[0], kv[0].value);
        try testing.expectEqualStrings(e[1], kv[1].value);
    }
}

test "matrix is the cartesian product in declaration order" {
    var d = Diag{};
    var l = try Legend.load(testing.allocator, lg, &d);
    defer l.deinit();
    const vars = try participants(testing.allocator, &l, &.{});
    defer testing.allocator.free(vars);
    var p = try matrix(testing.allocator, vars, 100);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 6), p.count);
    const expect = [_][2][]const u8{ .{ "a1", "b1" }, .{ "a1", "b2" }, .{ "a1", "b3" }, .{ "a2", "b1" }, .{ "a2", "b2" }, .{ "a2", "b3" } };
    for (expect, 0..) |e, i| {
        const kv = try p.pick(testing.allocator, i);
        defer testing.allocator.free(kv);
        try testing.expectEqualStrings(e[0], kv[0].value);
        try testing.expectEqualStrings(e[1], kv[1].value);
    }
    try testing.expectError(error.TooManyVariants, matrix(testing.allocator, vars, 5));
}

test "pinned variables leave the plan; seed is deterministic" {
    var d = Diag{};
    var l = try Legend.load(testing.allocator, lg, &d);
    defer l.deinit();
    const vars = try participants(testing.allocator, &l, &.{"A"});
    defer testing.allocator.free(vars);
    try testing.expectEqual(@as(usize, 1), vars.len);
    try testing.expectEqualStrings("B", vars[0].name);

    var p1 = try sequence(testing.allocator, vars, 3, 42);
    defer p1.deinit();
    var p2 = try sequence(testing.allocator, vars, 3, 42);
    defer p2.deinit();
    try testing.expectEqualSlices(usize, p1.orders[0], p2.orders[0]);
    // A permutation, not a fixed order.
    var sum: usize = 0;
    for (p1.orders[0]) |x| sum += x;
    try testing.expectEqual(@as(usize, 3), sum);

    const none = try participants(testing.allocator, &l, &.{ "A", "B" });
    defer testing.allocator.free(none);
    try testing.expectError(error.NoListVariables, sequence(testing.allocator, none, 1, null));
}
