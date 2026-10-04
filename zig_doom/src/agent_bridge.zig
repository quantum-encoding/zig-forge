//! zig_doom/src/agent_bridge.zig
//!
//! Agent mode (`--agent`): an external decision-maker plays through
//! stdin/stdout while the platform window still shows the game.
//!
//! Out, every `period` tics: one JSON line (it always starts with `{"t":`)
//! describing what the player can perceive — vitals, weapon and ammo, the
//! monsters and pickups in line of sight with their distance and bearing,
//! and whether the last command actually moved the player. Bearings are
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
//! A command lapses after `hold_tics` so a stalled agent stops the player
//! rather than walking it into a wall forever.

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
const pspr = @import("play/pspr.zig");

const MapObject = mobj_mod.MapObject;

/// Monsters further than this are not reported (map units).
const MONSTER_RANGE: f64 = 2048;
const ITEM_RANGE: f64 = 1024;
const MAX_MONSTERS = 6;
const MAX_ITEMS = 5;

pub const Bridge = struct {
    /// Tics between state lines (35 tics = 1 s).
    period: u32 = 7,
    /// Tics a command stays in force without a newer one.
    hold_tics: u32 = 35,

    cmd: user.TicCmd = .{},
    weapon_pending: ?u8 = null,
    cmd_age: u32 = 0,
    use_pending: bool = false,

    line: [512]u8 = undefined,
    line_len: usize = 0,

    last_x: f64 = 0,
    last_y: f64 = 0,
    has_last: bool = false,
    tics: u32 = 0,

    /// Make stdin non-blocking: the game loop polls it every frame.
    pub fn init(period: u32) Bridge {
        const flags = c.fcntl(0, c.F_GETFL, @as(c_int, 0));
        if (flags >= 0) _ = c.fcntl(0, c.F_SETFL, flags | c.O_NONBLOCK);
        return .{ .period = if (period == 0) 7 else period };
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
            .buttons = @intCast(buttons),
        };
        self.weapon_pending = if (weapon) |w| @intCast(w) else null;
        self.use_pending = buttons & user.BT_USE != 0;
        self.cmd_age = 0;
    }

    /// The command for this tic. A weapon change rides one tic only, and a
    /// lapsed command is no command.
    pub fn ticCmd(self: *Bridge) user.TicCmd {
        if (self.cmd_age >= self.hold_tics) return .{};
        self.cmd_age += 1;
        var out = self.cmd;
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
            ",\"player\":{{\"health\":{d},\"armor\":{d},\"weapon\":\"{s}\",\"ammo\":{d}," ++
                "\"moved\":{d:.0},\"hurt\":{},\"kills\":{d},\"total_kills\":{d}",
            .{
                player.health, player.armor_points,  @tagName(weapon), ammo,
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
            try w.print("{s}{{\"id\":\"m{d}\",\"kind\":\"{s}\",\"dist\":{d:.0},\"bearing\":{d:.1},\"health\":{d},\"targeting_me\":{}}}", .{
                if (i == 0) "" else ",", i, kindName(m.mo.mobj_type), m.dist, m.bearing, m.mo.health, m.targeting_me,
            });
        }
        try w.writeAll("],\"items\":[");
        for (items[0..n_items], 0..) |it, i| {
            try w.print("{s}{{\"id\":\"i{d}\",\"kind\":\"{s}\",\"dist\":{d:.0},\"bearing\":{d:.1}}}", .{
                if (i == 0) "" else ",", i, kindName(it.mo.mobj_type), it.dist, it.bearing,
            });
        }
        try w.writeAll("]}\n");
        return w.buffered();
    }
};

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
    var b = Bridge{ .hold_tics = 2 };
    b.parseLine("cmd 50 -10 900 1 2");
    var t = b.ticCmd();
    try std.testing.expectEqual(@as(i8, 50), t.forwardmove);
    try std.testing.expectEqual(@as(i8, -10), t.sidemove);
    try std.testing.expectEqual(@as(i16, 900), t.angleturn);
    try std.testing.expect(t.buttons & user.BT_ATTACK != 0);
    try std.testing.expect(t.buttons & user.BT_CHANGE != 0);
    t = b.ticCmd();
    try std.testing.expect(t.buttons & user.BT_CHANGE == 0); // one tic only
    t = b.ticCmd();
    try std.testing.expectEqual(@as(i8, 0), t.forwardmove); // lapsed

    b.parseLine("cmd 999 0 -99999 0");
    t = b.ticCmd();
    try std.testing.expectEqual(@as(i8, 50), t.forwardmove);
    try std.testing.expectEqual(@as(i16, -1280), t.angleturn);

    b.parseLine("garbage");
    b.parseLine("cmd 1 2");
    try std.testing.expectEqual(@as(i8, 50), b.ticCmd().forwardmove); // ignored
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
