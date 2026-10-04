//! zig_doom/src/agent_bridge.zig
//!
//! Agent mode (`--agent`): an external decision-maker plays through
//! stdin/stdout while the platform window still shows the game.
//!
//! Out, every `period` tics: one JSON line (it always starts with `{"t":`)
//! describing what the player can perceive — vitals, weapon and ammo, the
//! monsters and pickups in line of sight with their distance and bearing,
//! how far the player can walk at five bearings before something blocks it
//! (and whether that something is a door, or a solid thing such as a barrel
//! or pillar that can be walked around), whether the last command
//! actually moved the player, and `nav`: the next waypoint toward the
//! nearest unexplored part of the level and toward the exit (see
//! agent_nav.zig). Bearings are
//! degrees relative to where the player faces, positive to the LEFT, the
//! same sense as a positive turn.
//!
//! In, any time: one command per line, applied every tic until the next
//! one arrives:
//!
//!   cmd <forward> <side> <turn> <buttons> [weapon]
//!
//! forward/side -50..50 (50 = run; side positive = strafe right), turn
//! -1280..1280 angleturn units per tic (positive = left), buttons 1 = fire
//! and 2 = use, weapon a WeaponType index (0 fist … 7 chainsaw) to switch to.
//! Use and a weapon switch act once per command line: DOOM fires use on
//! the press, so holding it across tics would make every later press a no-op.
//! A command lapses after `hold_tics` so a stalled agent stops the player
//! rather than walking it into a wall forever.
//!
//!   go explore   |   go exit   |   go xy <x> <y>   |   go none
//!
//! hands locomotion to the game (agent_drive.zig): route-finding, path
//! smoothing, speed control on corners and stairs, doors, the exit switch,
//! and getting unstuck all happen here, every tic. While a goal is set it
//! owns forward, turn and use; `go none` returns them to `cmd` lines.
//!
//!   aim <id> [fire]   |   aim xy <x> <y>   |   aim none
//!
//! turns toward a monster or item by the `id` a state line gave it, every
//! tic, from its live position — the aim loop closes here at 35 Hz instead
//! of across the agent's round trip, which overshoots. With `fire`, the
//! attack button is pressed only on tics when the target is lined up. Ids are
//! stable for as long as the thing exists. `aim xy` steers to a map point
//! (a route waypoint's `x`/`y`). While aiming, a command's turn is ignored;
//! and unless firing, its forward speed is cut while the target is well off
//! to the side — stop to turn past 60°, slow past 30° — so the player turns
//! onto a point instead of orbiting it.

const std = @import("std");
const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

const defs = @import("defs.zig");
const fixed = @import("fixed.zig");
const info = @import("info.zig");
const game_mod = @import("game.zig");
const user = @import("play/user.zig");
const tick = @import("play/tick.zig");
const mobj_mod = @import("play/mobj.zig");
const sight = @import("play/sight.zig");
const maputl = @import("play/maputl.zig");
const setup = @import("play/setup.zig");
const agent_nav = @import("agent_nav.zig");
const agent_drive = @import("agent_drive.zig");
const pspr = @import("play/pspr.zig");

const MapObject = mobj_mod.MapObject;

/// Monsters further than this are not reported (map units).
const MONSTER_RANGE: f64 = 2048;
const ITEM_RANGE: f64 = 1024;
const MAX_MONSTERS = 6;
const MAX_ITEMS = 5;
/// Bearings the walk probes are cast at, degrees, positive = left.
const PROBE_BEARINGS = [_]f64{ 60, 30, 0, -30, -60 };
const PROBE_RANGE: f64 = 1024;
/// The player is 56 units tall and steps up at most 24.
const PLAYER_HEIGHT: f64 = 56;
const MAX_STEP: f64 = 24;

pub const Bridge = struct {
    /// Tics between state lines (35 tics = 1 s).
    period: u32 = 7,
    /// Tics a command stays in force without a newer one.
    hold_tics: u32 = 35,

    cmd: user.TicCmd = .{},
    weapon_pending: ?u8 = null,
    /// Use rides the first tic of a command only, as a fresh press.
    press_use: bool = false,
    aim_uid: ?u32 = null,
    aim_point: ?[2]f64 = null,
    aim_fire: bool = false,
    cmd_age: u32 = 0,
    use_pending: bool = false,

    line: [512]u8 = undefined,
    line_len: usize = 0,

    last_x: f64 = 0,
    last_y: f64 = 0,
    has_last: bool = false,
    tics: u32 = 0,
    nav: agent_nav.Nav,
    drive: agent_drive.Drive = .{},

    /// Make stdin non-blocking: the game loop polls it every frame.
    pub fn init(alloc: std.mem.Allocator, period: u32) Bridge {
        const flags = c.fcntl(0, c.F_GETFL, @as(c_int, 0));
        if (flags >= 0) _ = c.fcntl(0, c.F_SETFL, flags | c.O_NONBLOCK);
        return .{ .period = if (period == 0) 7 else period, .nav = agent_nav.Nav.init(alloc) };
    }

    pub fn deinit(self: *Bridge) void {
        self.nav.deinit();
    }

    /// Read whatever commands have arrived; the last complete one wins.
    pub fn poll(self: *Bridge) void {
        var buf: [1024]u8 = undefined;
        while (true) {
            const n = c.read(0, &buf, buf.len);
            if (n <= 0) return;
            for (buf[0..@intCast(n)]) |ch| {
                if (ch == '\n') {
                    self.parseLine(self.line[0..self.line_len]);
                    self.line_len = 0;
                } else if (self.line_len < self.line.len) {
                    self.line[self.line_len] = ch;
                    self.line_len += 1;
                }
            }
        }
    }

    fn parseLine(self: *Bridge, raw: []const u8) void {
        var it = std.mem.tokenizeScalar(u8, std.mem.trim(u8, raw, " \r\t"), ' ');
        const verb = it.next() orelse return;
        if (std.mem.eql(u8, verb, "go")) {
            const what = it.next() orelse return;
            if (std.mem.eql(u8, what, "explore")) {
                self.drive.setGoal(.explore);
            } else if (std.mem.eql(u8, what, "exit")) {
                self.drive.setGoal(.exit);
            } else if (std.mem.eql(u8, what, "xy")) {
                const x = std.fmt.parseFloat(f64, it.next() orelse return) catch return;
                const y = std.fmt.parseFloat(f64, it.next() orelse return) catch return;
                self.drive.setGoal(.{ .point = .{ x, y } });
            } else if (std.mem.eql(u8, what, "none")) {
                self.drive.setGoal(null);
            }
            return;
        }
        if (std.mem.eql(u8, verb, "aim")) {
            const target = it.next() orelse return;
            self.aim_uid = null;
            self.aim_point = null;
            self.aim_fire = false;
            if (std.mem.eql(u8, target, "xy")) {
                const x = std.fmt.parseFloat(f64, it.next() orelse return) catch return;
                const y = std.fmt.parseFloat(f64, it.next() orelse return) catch return;
                self.aim_point = .{ x, y };
                return;
            }
            self.aim_uid = parseUid(target);
            self.aim_fire = if (it.next()) |f| std.mem.eql(u8, f, "fire") else false;
            return;
        }
        if (!std.mem.eql(u8, verb, "cmd")) return;
        const fwd = parseClamped(it.next(), -50, 50) orelse return;
        const side = parseClamped(it.next(), -50, 50) orelse return;
        const turn = parseClamped(it.next(), -1280, 1280) orelse return;
        const buttons = parseClamped(it.next(), 0, 3) orelse return;
        const weapon = parseClamped(it.next(), 0, defs.NUMWEAPONS - 1);
        self.cmd = .{
            .forwardmove = @intCast(fwd),
            .sidemove = @intCast(side),
            .angleturn = @intCast(turn),
            .buttons = @as(u8, @intCast(buttons)) & ~@as(u8, user.BT_USE),
        };
        self.press_use = buttons & user.BT_USE != 0;
        self.weapon_pending = if (weapon) |w| @intCast(w) else null;
        self.use_pending = buttons & user.BT_USE != 0;
        self.cmd_age = 0;
    }

    /// The command for this tic, steered onto the aim target when there is one.
    pub fn ticCmd(self: *Bridge, game: *game_mod.Game) user.TicCmd {
        const lapsed = self.cmd_age >= self.hold_tics;
        var out = self.baseCmd();
        if (lapsed) return out;
        const pmo = game.players[game.consoleplayer].mobj orelse return out;
        if (self.drive.goal != null and game.state == .level) {
            if (game.level) |*lvl| {
                var solids: [MAX_SOLIDS]Solid = undefined;
                const n_solids = nearbySolids(pmo, &solids);
                self.drive.steer(&self.nav, lvl, pmo, solids[0..n_solids], &out);
                return out;
            }
        }
        var b: ?f64 = null;
        if (self.aim_uid) |uid| {
            if (findByUid(uid)) |target| {
                b = bearing(pmo, target);
                out.buttons &= ~@as(u8, user.BT_ATTACK);
                if (self.aim_fire and lined_up(b.?, distance(pmo, target))) out.buttons |= user.BT_ATTACK;
            } else {
                // Gone (killed, picked up): stop aiming.
                self.aim_uid = null;
                out.angleturn = 0;
            }
        } else if (self.aim_point) |pt| {
            b = bearingTo(pmo, pt[0], pt[1]);
        }
        if (b) |deg| {
            // Close half the error each tic: quick, and no overshoot.
            out.angleturn = @intFromFloat(std.math.clamp(deg * TURN_PER_DEG * 0.5, -1280, 1280));
            if (!self.aim_fire) {
                const off = @abs(deg);
                if (off > 60) {
                    out.forwardmove = 0;
                } else if (off > 30) {
                    out.forwardmove = @divTrunc(out.forwardmove, 3);
                }
            }
        }
        return out;
    }

    /// The last command line as this tic's command: use and a weapon change
    /// ride one tic only, and a lapsed command is no command.
    fn baseCmd(self: *Bridge) user.TicCmd {
        if (self.cmd_age >= self.hold_tics) return .{};
        self.cmd_age += 1;
        var out = self.cmd;
        if (self.press_use) {
            out.buttons |= user.BT_USE;
            self.press_use = false;
        }
        if (self.weapon_pending) |w| {
            out.buttons |= user.BT_CHANGE | (w << user.BT_WEAPONSHIFT);
            self.weapon_pending = null;
        }
        return out;
    }

    /// Outside a level, USE is what moves the game on.
    pub fn takeUse(self: *Bridge) bool {
        const u = self.use_pending;
        self.use_pending = false;
        return u;
    }

    /// Called once per game tic; writes a state line every `period` tics.
    pub fn afterTic(self: *Bridge, game: *game_mod.Game) void {
        self.tics += 1;
        if (game.state == .level) {
            if (game.level) |*lvl| {
                if (game.players[game.consoleplayer].mobj) |pmo| self.nav.markVisited(lvl, pmo);
            }
        }
        if (self.tics % self.period != 0) return;
        var buf: [8192]u8 = undefined;
        const text = self.formatState(game, &buf) catch return;
        writeAll(text);
    }

    fn formatState(self: *Bridge, game: *game_mod.Game, buf: []u8) ![]const u8 {
        var w = std.Io.Writer.fixed(buf);
        const player = &game.players[game.consoleplayer];
        try w.print("{{\"t\":{d},\"map\":\"E{d}M{d}\",\"skill\":{d}", .{
            self.tics, game.episode, game.map, @intFromEnum(game.skill),
        });
        const mode: []const u8 = switch (game.state) {
            .level => if (player.player_state == .dead) "dead" else "playing",
            .intermission => "intermission",
            .finale => "finale",
            .demoscreen => "menu",
        };
        try w.print(",\"mode\":\"{s}\"", .{mode});
        const going: []const u8 = if (self.drive.goal) |g| @tagName(g) else "none";
        try w.print(",\"going\":\"{s}\"", .{going});
        if (self.drive.heading()) |h| try w.print(",\"heading\":{{\"x\":{d:.0},\"y\":{d:.0}}}", .{ h[0], h[1] });

        const pmo = player.mobj orelse {
            try w.writeAll("}\n");
            return w.buffered();
        };
        const px = toUnits(pmo.x);
        const py = toUnits(pmo.y);
        const moved = if (self.has_last) std.math.hypot(px - self.last_x, py - self.last_y) else 0;
        self.last_x = px;
        self.last_y = py;
        self.has_last = true;

        const weapon = player.ready_weapon;
        const ammo_type = pspr.weaponinfo[@intFromEnum(weapon)].ammo;
        const ammo: i32 = if (ammo_type == .no_ammo) -1 else player.ammo[@intFromEnum(ammo_type)];
        try w.print(
            ",\"player\":{{\"x\":{d:.0},\"y\":{d:.0},\"angle\":{d:.0},\"health\":{d},\"armor\":{d},\"weapon\":\"{s}\",\"ammo\":{d}," ++
                "\"moved\":{d:.0},\"hurt\":{},\"kills\":{d},\"total_kills\":{d}",
            .{
                px, py, @as(f64, @floatFromInt(pmo.angle)) / 4294967296.0 * 360.0, player.health, player.armor_points,  @tagName(weapon), ammo,
                moved,         player.damage_count > 0, player.kill_count, game.total_kills,
            },
        );
        if (player.attacker) |a| {
            if (player.damage_count > 0 and a != pmo) {
                try w.print(",\"hurt_from_deg\":{d:.0}", .{bearing(pmo, a)});
            }
        }
        try w.writeAll(",\"weapons\":[");
        var first = true;
        for (player.weapon_owned, 0..) |owned, i| {
            if (!owned) continue;
            const wt: defs.WeaponType = @enumFromInt(i);
            const at = pspr.weaponinfo[i].ammo;
            const left: i32 = if (at == .no_ammo) -1 else player.ammo[@intFromEnum(at)];
            if (left == 0) continue;
            try w.print("{s}{{\"id\":{d},\"name\":\"{s}\",\"ammo\":{d}}}", .{
                if (first) "" else ",", i, @tagName(wt), left,
            });
            first = false;
        }
        try w.writeAll("]}");

        // Line-of-sight perception over every live map object.
        var monsters: [MAX_MONSTERS]Seen = undefined;
        var n_monsters: usize = 0;
        var items: [MAX_ITEMS]Seen = undefined;
        var n_items: usize = 0;
        const level_ptr: ?*const @TypeOf(game.level.?) = if (game.level) |*l| l else null;
        const cap = tick.getThinkerCap();
        var current = cap.next;
        while (current != null and current != cap) {
            const th = current.?;
            current = th.next;
            const func = th.function orelse continue;
            if (func != @as(tick.ThinkFn, @ptrCast(&mobj_mod.mobjThinker))) continue;
            const mo: *MapObject = @fieldParentPtr("thinker", th);
            if (mo == pmo) continue;
            const is_monster = mo.flags & info.MF_COUNTKILL != 0 and mo.health > 0;
            const is_item = mo.flags & info.MF_SPECIAL != 0;
            if (!is_monster and !is_item) continue;
            const dist = std.math.hypot(toUnits(mo.x) - px, toUnits(mo.y) - py);
            if (dist > (if (is_monster) MONSTER_RANGE else ITEM_RANGE)) continue;
            if (!sight.checkSight(pmo, mo, level_ptr)) continue;
            const seen = Seen{
                .mo = mo,
                .dist = dist,
                .bearing = bearing(pmo, mo),
                .targeting_me = mo.target == pmo,
            };
            if (is_monster) {
                insertNearest(&monsters, &n_monsters, seen);
            } else {
                insertNearest(&items, &n_items, seen);
            }
        }
        try w.writeAll(",\"monsters\":[");
        for (monsters[0..n_monsters], 0..) |m, i| {
            try w.print("{s}{{\"id\":\"m{x}\",\"kind\":\"{s}\",\"x\":{d:.0},\"y\":{d:.0},\"dist\":{d:.0},\"bearing\":{d:.1},\"health\":{d},\"targeting_me\":{}}}", .{
                if (i == 0) "" else ",", uidOf(m.mo), kindName(m.mo.mobj_type), toUnits(m.mo.x), toUnits(m.mo.y), m.dist, m.bearing, m.mo.health, m.targeting_me,
            });
        }
        try w.writeAll("],\"items\":[");
        for (items[0..n_items], 0..) |it, i| {
            try w.print("{s}{{\"id\":\"i{x}\",\"kind\":\"{s}\",\"x\":{d:.0},\"y\":{d:.0},\"dist\":{d:.0},\"bearing\":{d:.1}}}", .{
                if (i == 0) "" else ",", uidOf(it.mo), kindName(it.mo.mobj_type), toUnits(it.mo.x), toUnits(it.mo.y), it.dist, it.bearing,
            });
        }
        var solids: [MAX_SOLIDS]Solid = undefined;
        const n_solids = nearbySolids(pmo, &solids);
        try w.writeAll("],\"walls\":[");
        if (level_ptr) |lvl| {
            for (PROBE_BEARINGS, 0..) |b, i| {
                const hit = probe(lvl, pmo, b, solids[0..n_solids]);
                try w.print("{s}{{\"bearing\":{d:.0},\"clear\":{d:.0},\"door\":{},\"thing\":{}}}", .{
                    if (i == 0) "" else ",", b, hit.dist, hit.door, hit.thing,
                });
            }
        }
        try w.writeAll("]");
        if (level_ptr) |lvl| {
            if (self.nav.plan(lvl, pmo)) |plan| {
                try w.print(",\"nav\":{{\"seen\":{d},\"sectors\":{d}", .{ plan.seen, plan.sectors });
                inline for (.{ "explore", "exit" }) |name| {
                    if (@field(plan, name)) |route| {
                        const wp = clearAim(lvl, pmo, route, solids[0..n_solids]);
                        try w.print(",\"" ++ name ++ "\":{{\"x\":{d:.0},\"y\":{d:.0},\"bearing\":{d:.1},\"hop\":{d:.0},\"dist\":{d:.0},\"door\":{},\"switch\":{}}}", .{
                            wp.x,
                            wp.y,
                            bearingTo(pmo, wp.x, wp.y),
                            std.math.hypot(wp.x - px, wp.y - py),
                            wp.dist,
                            wp.door,
                            wp.switch_,
                        });
                    }
                }
                try w.writeAll("}");
            }
        }
        try w.writeAll("}\n");
        return w.buffered();
    }
};

/// The point along the waypoint's portal span to head for: the one nearest
/// the midpoint that a straight walk reaches without hitting a wall or a
/// solid thing — so a barrel in the middle of a doorway is walked round,
/// not pushed against. The midpoint when no sample is clear.
fn clearAim(level: *const setup.Level, pmo: *const MapObject, wp: agent_nav.Waypoint, solids: []const Solid) agent_nav.Waypoint {
    const fractions = [_]f64{ 0.5, 0.4, 0.6, 0.3, 0.7, 0.2, 0.8 };
    const px = toUnits(pmo.x);
    const py = toUnits(pmo.y);
    for (fractions) |f| {
        const x = wp.x1 + (wp.x2 - wp.x1) * f;
        const y = wp.y1 + (wp.y2 - wp.y1) * f;
        const want = std.math.hypot(x - px, y - py);
        if (want < 1) return wp;
        const hit = probe(level, pmo, bearingTo(pmo, x, y), solids);
        // The portal line itself is the far end; reaching it is enough.
        if (hit.dist >= want - 2) {
            var out = wp;
            out.x = x;
            out.y = y;
            return out;
        }
    }
    return wp;
}

/// Degrees from where `from` faces to the point (x, y), positive = left.
fn bearingTo(from: *const MapObject, x: f64, y: f64) f64 {
    const facing = @as(f64, @floatFromInt(from.angle)) / 4294967296.0 * 360.0;
    var d = std.math.atan2(y - toUnits(from.y), x - toUnits(from.x)) * 180.0 / std.math.pi - facing;
    while (d > 180) d -= 360;
    while (d < -180) d += 360;
    return d;
}

const Probe = struct { dist: f64, door: bool, thing: bool = false };

/// A solid map object near the player, as a circle the player's own
/// radius cannot enter.
const Solid = agent_drive.Obstacle;
const MAX_SOLIDS = 48;
const SOLID_RANGE: f64 = 512;
const PLAYER_RADIUS: f64 = 16;

fn nearbySolids(pmo: *const MapObject, out: *[MAX_SOLIDS]Solid) usize {
    const px = toUnits(pmo.x);
    const py = toUnits(pmo.y);
    var n: usize = 0;
    const cap = tick.getThinkerCap();
    var current = cap.next;
    while (current != null and current != cap and n < out.len) {
        const th = current.?;
        current = th.next;
        const func = th.function orelse continue;
        if (func != @as(tick.ThinkFn, @ptrCast(&mobj_mod.mobjThinker))) continue;
        const mo: *MapObject = @fieldParentPtr("thinker", th);
        if (mo == pmo or mo.flags & info.MF_SOLID == 0) continue;
        const x = toUnits(mo.x);
        const y = toUnits(mo.y);
        if (std.math.hypot(x - px, y - py) > SOLID_RANGE) continue;
        out[n] = .{ .x = x, .y = y, .r = toUnits(mo.radius) + PLAYER_RADIUS };
        n += 1;
    }
    return n;
}

/// How far the player could walk from where it stands along `rel_deg`
/// before a line stops it: one-sided walls, lines flagged blocking, and
/// two-sided lines whose opening is too low or whose step is too high (a
/// closed door is the last kind, and carries a special — reported as a door).
fn probe(level: *const setup.Level, from: *const MapObject, rel_deg: f64, solids: []const Solid) Probe {
    const ox = toUnits(from.x);
    const oy = toUnits(from.y);
    const facing = @as(f64, @floatFromInt(from.angle)) / 4294967296.0 * 2.0 * std.math.pi;
    const a = facing + rel_deg * std.math.pi / 180.0;
    const dx = @cos(a);
    const dy = @sin(a);
    const floor = toUnits(from.floorz);
    var best = Probe{ .dist = PROBE_RANGE, .door = false };
    for (level.lines) |*line| {
        const v1 = level.vertices[line.v1];
        const v2 = level.vertices[line.v2];
        const ax = toUnits(v1.x);
        const ay = toUnits(v1.y);
        const ex = toUnits(v2.x) - ax;
        const ey = toUnits(v2.y) - ay;
        // Solve origin + t·dir = v1 + u·edge.
        const den = dx * ey - dy * ex;
        if (@abs(den) < 1e-9) continue;
        const t = ((ax - ox) * ey - (ay - oy) * ex) / den;
        const u = ((ax - ox) * dy - (ay - oy) * dx) / den;
        if (t <= 1 or t >= best.dist or u < 0 or u > 1) continue;
        if (!blocks(level, line, floor)) continue;
        best = .{ .dist = t, .door = line.special != 0 };
    }
    // Solid things: the first entry of the ray into each circle.
    for (solids) |sd| {
        const fx = sd.x - ox;
        const fy = sd.y - oy;
        const along = fx * dx + fy * dy;
        if (along <= 0) continue;
        const off2 = fx * fx + fy * fy - along * along;
        const r2 = sd.r * sd.r;
        if (off2 > r2) continue;
        const t = @max(along - @sqrt(r2 - off2), 0);
        if (t < best.dist) best = .{ .dist = t, .door = false, .thing = true };
    }
    return best;
}

fn blocks(level: *const setup.Level, line: *const setup.Line, floor: f64) bool {
    if (line.sidenum[1] < 0) return true;
    if (line.flags & defs.ML_BLOCKING != 0) return true;
    const open = maputl.lineOpening(line, level.sectors) orelse return true;
    if (toUnits(open.range) < PLAYER_HEIGHT) return true;
    return toUnits(open.bottom) - floor > MAX_STEP;
}

const Seen = struct {
    mo: *MapObject,
    dist: f64,
    bearing: f64,
    targeting_me: bool,
};

/// Keep the `cap` nearest, sorted by distance.
fn insertNearest(list: anytype, n: *usize, seen: Seen) void {
    const cap = list.len;
    var i: usize = n.*;
    if (i == cap) {
        if (seen.dist >= list[cap - 1].dist) return;
        i = cap - 1;
    } else {
        n.* += 1;
    }
    while (i > 0 and list[i - 1].dist > seen.dist) : (i -= 1) list[i] = list[i - 1];
    list[i] = seen;
}

/// `angleturn` units per degree: 65536 of them make a full turn.
const TURN_PER_DEG: f64 = 65536.0 / 360.0;

/// A stable handle for a map object: its address, which does not change
/// while it exists. Printed as hex after an `m`/`i` prefix.
fn uidOf(mo: *const MapObject) u32 {
    return @truncate(@intFromPtr(mo) >> 4);
}

fn parseUid(tok: []const u8) ?u32 {
    if (tok.len < 2 or (tok[0] != 'm' and tok[0] != 'i')) return null;
    return std.fmt.parseInt(u32, tok[1..], 16) catch null;
}

/// The live map object with this uid: monsters only while alive.
fn findByUid(uid: u32) ?*MapObject {
    const cap = tick.getThinkerCap();
    var current = cap.next;
    while (current != null and current != cap) {
        const th = current.?;
        current = th.next;
        const func = th.function orelse continue;
        if (func != @as(tick.ThinkFn, @ptrCast(&mobj_mod.mobjThinker))) continue;
        const mo: *MapObject = @fieldParentPtr("thinker", th);
        if (uidOf(mo) != uid) continue;
        if (mo.flags & info.MF_COUNTKILL != 0 and mo.health <= 0) return null;
        return mo;
    }
    return null;
}

fn distance(a: *const MapObject, b: *const MapObject) f64 {
    return std.math.hypot(toUnits(b.x) - toUnits(a.x), toUnits(b.y) - toUnits(a.y));
}

/// Close enough to straight ahead to hit: a monster is ~40 units wide, so
/// the tolerance widens as it gets nearer.
fn lined_up(bearing_deg: f64, dist: f64) bool {
    const half_width = std.math.atan(20.0 / @max(dist, 1.0)) * 180.0 / std.math.pi;
    return @abs(bearing_deg) <= @max(half_width, 3.0);
}

fn toUnits(v: fixed.Fixed) f64 {
    return @as(f64, @floatFromInt(v.raw())) / 65536.0;
}

/// Degrees from where `from` faces to `to`, -180..180, positive = left.
fn bearing(from: *const MapObject, to: *const MapObject) f64 {
    const abs = maputl.pointToAngle2(from.x, from.y, to.x, to.y);
    const rel: i32 = @bitCast(abs -% from.angle);
    return @as(f64, @floatFromInt(rel)) * 180.0 / 2147483648.0;
}

/// What a model can reason about: `MT_MISC11` is a medikit, `MT_TROOP` an
/// imp. Anything unlisted falls back to its engine name without `MT_`.
fn kindName(t: info.MobjType) []const u8 {
    return switch (t) {
        .MT_POSSESSED => "zombieman",
        .MT_SHOTGUY => "shotgun_guy",
        .MT_CHAINGUY => "chaingunner",
        .MT_TROOP => "imp",
        .MT_SERGEANT => "demon",
        .MT_SHADOWS => "spectre",
        .MT_SKULL => "lost_soul",
        .MT_HEAD => "cacodemon",
        .MT_BRUISER => "baron_of_hell",
        .MT_KNIGHT => "hell_knight",
        .MT_MISC0 => "green_armor",
        .MT_MISC1 => "blue_armor",
        .MT_MISC2 => "health_bonus",
        .MT_MISC3 => "armor_bonus",
        .MT_MISC4 => "blue_keycard",
        .MT_MISC5 => "red_keycard",
        .MT_MISC6 => "yellow_keycard",
        .MT_MISC7 => "yellow_skull_key",
        .MT_MISC8 => "red_skull_key",
        .MT_MISC9 => "blue_skull_key",
        .MT_MISC10 => "stimpack",
        .MT_MISC11 => "medikit",
        .MT_MISC12 => "soulsphere",
        .MT_INV => "invulnerability",
        .MT_MISC13 => "berserk",
        .MT_INS => "invisibility",
        .MT_MISC14 => "radiation_suit",
        .MT_MISC15 => "computer_map",
        .MT_MISC16 => "light_amp_visor",
        .MT_MEGA => "megasphere",
        .MT_CLIP => "ammo_clip",
        .MT_MISC17 => "box_of_bullets",
        .MT_MISC18 => "rocket",
        .MT_MISC19 => "box_of_rockets",
        .MT_MISC20 => "energy_cell",
        .MT_MISC21 => "energy_cell_pack",
        .MT_MISC22 => "shotgun_shells",
        .MT_MISC23 => "box_of_shells",
        .MT_MISC24 => "backpack",
        .MT_MISC25 => "bfg9000",
        .MT_CHAINGUN => "chaingun",
        .MT_MISC26 => "chainsaw",
        .MT_MISC27 => "rocket_launcher",
        .MT_MISC28 => "plasma_rifle",
        .MT_MISC29 => "shotgun",
        .MT_MISC30 => "super_shotgun",
        else => blk: {
            const name = @tagName(t);
            break :blk if (std.mem.startsWith(u8, name, "MT_")) name[3..] else name;
        },
    };
}

fn parseClamped(tok: ?[]const u8, lo: i32, hi: i32) ?i32 {
    const v = std.fmt.parseInt(i32, tok orelse return null, 10) catch return null;
    return std.math.clamp(v, lo, hi);
}

fn writeAll(bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = std.c.write(1, rest.ptr, rest.len);
        if (n <= 0) return;
        rest = rest[@intCast(n)..];
    }
}

test "commands parse, clamp, and lapse" {
    var b = Bridge{ .hold_tics = 2, .nav = agent_nav.Nav.init(std.testing.allocator) };
    b.parseLine("aim m1a2b fire");
    try std.testing.expectEqual(@as(?u32, 0x1a2b), b.aim_uid);
    try std.testing.expect(b.aim_fire);
    b.parseLine("aim xy 1056 -3616");
    try std.testing.expectEqual(@as(?u32, null), b.aim_uid);
    try std.testing.expectEqual(@as(f64, -3616), b.aim_point.?[1]);
    b.parseLine("aim none");
    try std.testing.expectEqual(@as(?u32, null), b.aim_uid);
    try std.testing.expectEqual(@as(?[2]f64, null), b.aim_point);
    b.parseLine("cmd 50 -10 900 1 2");
    var t = b.baseCmd();
    try std.testing.expectEqual(@as(i8, 50), t.forwardmove);
    try std.testing.expectEqual(@as(i8, -10), t.sidemove);
    try std.testing.expectEqual(@as(i16, 900), t.angleturn);
    try std.testing.expect(t.buttons & user.BT_ATTACK != 0);
    try std.testing.expect(t.buttons & user.BT_CHANGE != 0);
    t = b.baseCmd();
    try std.testing.expect(t.buttons & user.BT_CHANGE == 0); // one tic only

    b.parseLine("cmd 0 0 0 2");
    try std.testing.expect(b.baseCmd().buttons & user.BT_USE != 0);
    try std.testing.expect(b.baseCmd().buttons & user.BT_USE == 0); // a press, not a hold
    b.parseLine("cmd 0 0 0 2");
    try std.testing.expect(b.baseCmd().buttons & user.BT_USE != 0); // each line presses again
    t = b.baseCmd();
    try std.testing.expectEqual(@as(i8, 0), t.forwardmove); // lapsed

    b.parseLine("cmd 999 0 -99999 0");
    t = b.baseCmd();
    try std.testing.expectEqual(@as(i8, 50), t.forwardmove);
    try std.testing.expectEqual(@as(i16, -1280), t.angleturn);

    b.parseLine("garbage");
    b.parseLine("cmd 1 2");
    try std.testing.expectEqual(@as(i8, 50), b.baseCmd().forwardmove); // ignored
}

test "nearest-first insertion keeps the closest" {
    var dummy: MapObject = .{};
    var list: [2]Seen = undefined;
    var n: usize = 0;
    for ([_]f64{ 300, 100, 200, 50 }) |d| {
        insertNearest(&list, &n, .{ .mo = &dummy, .dist = d, .bearing = 0, .targeting_me = false });
    }
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(f64, 50), list[0].dist);
    try std.testing.expectEqual(@as(f64, 100), list[1].dist);
}
