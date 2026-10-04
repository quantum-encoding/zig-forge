#!/usr/bin/env python3
"""levelgen — compile a tile-map level spec into a DOOM PWAD.

A level is drawn as an ASCII grid; each character is one 64x64 tile:

    #  wall (solid; a space is void, the same)
    .  floor
    @  player start (floor)    X  exit: walking onto it ends the level
    D  door (opens with use)   ~  nukage (damaging, sunk 8 below)
    1-9  floor raised 16*n — a run of rising digits is a stair
    monsters:  z zombieman  s shotgun guy  i imp  d demon  c cacodemon  b baron
    items:     + medikit  k stimpack  h health bonus  a ammo clip
               A box of bullets  e shells  g shotgun  r armor bonus

Tiles with identical properties that touch become one sector; walls are
emitted only where properties change, and straight runs are merged into
single linedefs. The JSON wrapper adds seeded random spawns on top:

    {"name": "E1M1", "seed": 7, "map": ["#####", "#@..#", ...],
     "spawn": [{"thing": "imp", "count": 12, "on": "."}],
     "textures": {"wall": "STARTAN3", "floor": "FLOOR4_8", "ceiling": "CEIL3_5"},
     "ceiling": 128, "light": 192}

Output is a PWAD with empty node lumps; run a node builder (ZDBSP) over it
before playing — tools/levelgen/make-level.sh does both.

    levelgen.py spec.json out.wad
"""

import json
import random
import struct
import sys

TILE = 64

THINGS = {
    "player": 1,
    "zombieman": 3004, "shotgun_guy": 9, "imp": 3001, "demon": 3002,
    "cacodemon": 3005, "baron": 3003,
    "medikit": 2012, "stimpack": 2011, "health_bonus": 2014, "ammo_clip": 2007,
    "box_of_bullets": 2048, "shells": 2008, "shotgun": 2001, "armor_bonus": 2015,
}
GLYPH_THING = {
    "@": "player", "z": "zombieman", "s": "shotgun_guy", "i": "imp", "d": "demon",
    "c": "cacodemon", "b": "baron", "+": "medikit", "k": "stimpack",
    "h": "health_bonus", "a": "ammo_clip", "A": "box_of_bullets", "e": "shells",
    "g": "shotgun", "r": "armor_bonus",
}

# Linedef flags and specials.
ML_BLOCKING, ML_TWOSIDED, ML_DONTPEGTOP, ML_DONTPEGBOTTOM = 1, 4, 8, 16
DOOR_SPECIAL = 1      # DR: open with use, close after a wait
EXIT_WALK_SPECIAL = 52  # W1: exit level
NUKAGE_SPECIAL = 5    # 10% damage floor


class SpecError(Exception):
    pass


def tile_key(ch, cfg):
    """The sector properties a tile implies; None for a wall."""
    floor, ceil = 0, cfg["ceiling"]
    tex = cfg["textures"]
    if ch in "# ":
        return None
    if ch == "D":
        return ("door", 0, 0, tex["door_floor"], tex["ceiling"], cfg["light"], 0)
    if ch == "~":
        return ("nukage", -8, ceil, "NUKAGE1", tex["ceiling"], cfg["light"], NUKAGE_SPECIAL)
    if ch == "X":
        return ("exit", 0, ceil, tex["exit_floor"], tex["ceiling"], cfg["light"], 0)
    if ch.isdigit() and ch != "0":
        h = 16 * int(ch)
        return ("floor", h, ceil + h, tex["floor"], tex["ceiling"], cfg["light"], 0)
    if ch in ".@" or ch in GLYPH_THING:
        return ("floor", 0, ceil, tex["floor"], tex["ceiling"], cfg["light"], 0)
    raise SpecError(f"unknown tile {ch!r}")


def compile_spec(spec):
    cfg = {
        "ceiling": spec.get("ceiling", 128),
        "light": spec.get("light", 192),
        "textures": {
            "wall": "STARTAN3", "floor": "FLOOR4_8", "ceiling": "CEIL3_5",
            "door": "DOOR3", "door_track": "DOORTRAK", "door_floor": "FLAT20",
            "step": "STEP1", "exit_floor": "FLAT14", "exit_wall": "EXITSIGN",
            **spec.get("textures", {}),
        },
    }
    rows = spec["map"]
    if not rows:
        raise SpecError("empty map")
    width = max(len(r) for r in rows)
    grid = [r.ljust(width, "#") for r in rows]
    height = len(grid)

    def at(i, j):
        """Tile at column i, row j counted from the BOTTOM (y grows up)."""
        if 0 <= i < width and 0 <= j < height:
            return grid[height - 1 - j][i]
        return "#"

    keys = {(i, j): tile_key(at(i, j), cfg) for i in range(width) for j in range(height)}

    # Sectors: connected tiles with the same key.
    sector_of, sectors = {}, []
    for start, key in keys.items():
        if key is None or start in sector_of:
            continue
        idx = len(sectors)
        sectors.append(key)
        stack = [start]
        sector_of[start] = idx
        while stack:
            i, j = stack.pop()
            for n in ((i + 1, j), (i - 1, j), (i, j + 1), (i, j - 1)):
                if n not in sector_of and keys.get(n) == key:
                    sector_of[n] = idx
                    stack.append(n)

    # Unit edges, clockwise round each tile so the tile is on the right
    # (DOOM's front side); a shared edge is emitted once, from one side.
    edges = []
    for (i, j), s in sector_of.items():
        x0, y0, x1, y1 = i * TILE, j * TILE, (i + 1) * TILE, (j + 1) * TILE
        for (nx, ny), (a, b) in (
            ((i, j + 1), ((x0, y1), (x1, y1))),   # top, heading east
            ((i + 1, j), ((x1, y1), (x1, y0))),   # right, heading south
            ((i, j - 1), ((x1, y0), (x0, y0))),   # bottom, heading west
            ((i - 1, j), ((x0, y0), (x0, y1))),   # left, heading north
        ):
            other = sector_of.get((nx, ny))
            if other == s:
                continue
            if other is not None and other < s:
                continue  # emitted from the other side
            edges.append((a, b, s, other))

    # Merge straight runs with the same sectors on each side.
    by_start = {}
    for e in edges:
        by_start.setdefault((e[0], e[2], e[3]), []).append(e)
    used, merged = set(), []
    starts = {(e[1], e[2], e[3]) for e in edges}
    for e in edges:
        if id(e) in used or (e[0], e[2], e[3]) in starts and _has_pred(e, edges):
            continue
        a, b, s, o = e
        used.add(id(e))
        while True:
            nxt = [f for f in by_start.get((b, s, o), []) if id(f) not in used and _same_dir(a, b, f[0], f[1])]
            if not nxt:
                break
            used.add(id(nxt[0]))
            b = nxt[0][1]
        merged.append((a, b, s, o))
    for e in edges:  # anything left (loops) as-is
        if id(e) not in used:
            merged.append(e)

    # Lumps.
    verts, vindex = [], {}

    def vert(p):
        if p not in vindex:
            vindex[p] = len(verts)
            verts.append(p)
        return vindex[p]

    lines, sides = [], []
    tex = cfg["textures"]
    for a, b, s, o in merged:
        fs = sectors[s]
        if o is None:
            wall = tex["exit_wall"] if fs[0] == "exit" else (tex["door_track"] if fs[0] == "door" else tex["wall"])
            flags = ML_BLOCKING | (ML_DONTPEGBOTTOM if fs[0] == "door" else 0)
            sides.append((0, 0, "-", "-", wall, s))
            lines.append((vert(a), vert(b), flags, 0, 0, len(sides) - 1, 0xFFFF))
            continue
        bs = sectors[o]
        if fs[0] == "door":
            # Vanilla DOOM fires a use special only from the line's front, so
            # a door line faces OUT of the door: flip it to put the room in front.
            a, b, s, o = b, a, o, s
            fs, bs = bs, fs
        special = 0
        if "door" in (fs[0], bs[0]):
            special = DOOR_SPECIAL
        elif "exit" in (fs[0], bs[0]):
            special = EXIT_WALK_SPECIAL
        upper_f = tex["door"] if bs[0] == "door" else tex["wall"]
        upper_b = tex["door"] if fs[0] == "door" else tex["wall"]
        lower = tex["step"]
        sides.append((0, 0, upper_f, lower, "-", s))
        front = len(sides) - 1
        sides.append((0, 0, upper_b, lower, "-", o))
        back = len(sides) - 1
        flags = ML_TWOSIDED | (ML_DONTPEGTOP if special == DOOR_SPECIAL else 0)
        lines.append((vert(a), vert(b), flags, special, 0, front, back))

    # Things: glyphs first, then seeded random spawns on free tiles.
    things = []
    occupied = set()
    for (i, j) in sorted(sector_of):
        ch = at(i, j)
        if ch in GLYPH_THING:
            things.append(_thing(GLYPH_THING[ch], i, j))
            occupied.add((i, j))
    if not any(t[3] == THINGS["player"] for t in things):
        raise SpecError("no player start (@)")
    rng = random.Random(spec.get("seed", 0))
    for sp in spec.get("spawn", []):
        name = sp["thing"]
        if name not in THINGS:
            raise SpecError(f"unknown thing {name!r}")
        on = sp.get("on", ".")
        free = sorted(p for p in sector_of if at(*p) in on and p not in occupied)
        if sp["count"] > len(free):
            raise SpecError(f"{sp['count']} {name} but only {len(free)} free tiles on {on!r}")
        for p in rng.sample(free, sp["count"]):
            things.append(_thing(name, *p, angle=rng.choice((0, 90, 180, 270))))
            occupied.add(p)

    return {
        "THINGS": b"".join(struct.pack("<hhhhh", *t) for t in things),
        "LINEDEFS": b"".join(struct.pack("<hhhhhHH", *l) for l in lines),
        "SIDEDEFS": b"".join(
            struct.pack("<hh8s8s8sh", x, y, _name(u), _name(lo), _name(m), sec)
            for x, y, u, lo, m, sec in sides
        ),
        "VERTEXES": b"".join(struct.pack("<hh", x, y) for x, y in verts),
        "SECTORS": b"".join(
            struct.pack("<hh8s8shhh", f, c, _name(ft), _name(ct), light, special, 0)
            for _, f, c, ft, ct, light, special in sectors
        ),
    }, {"sectors": len(sectors), "lines": len(lines), "things": len(things),
        "monsters": sum(1 for t in things if t[3] in MONSTERS)}


MONSTERS = {THINGS[n] for n in ("zombieman", "shotgun_guy", "imp", "demon", "cacodemon", "baron")}


def _has_pred(e, edges):
    return any(f[1] == e[0] and f[2] == e[2] and f[3] == e[3] and _same_dir(f[0], f[1], e[0], e[1]) for f in edges)


def _same_dir(a, b, c, d):
    return (b[0] - a[0]) * (d[1] - c[1]) == (b[1] - a[1]) * (d[0] - c[0]) and \
        (b[0] - a[0]) * (d[0] - c[0]) + (b[1] - a[1]) * (d[1] - c[1]) > 0


def _thing(name, i, j, angle=90):
    # Skill flags 1|2|4: present on every skill.
    return (i * TILE + TILE // 2, j * TILE + TILE // 2, angle, THINGS[name], 7)


def _name(s):
    return s.upper().encode("ascii")[:8].ljust(8, b"\0")


def write_pwad(path, map_name, lumps):
    order = ["THINGS", "LINEDEFS", "SIDEDEFS", "VERTEXES", "SEGS", "SSECTORS",
             "NODES", "SECTORS", "REJECT", "BLOCKMAP"]
    entries = [(map_name, b"")] + [(n, lumps.get(n, b"")) for n in order]
    body, directory, offset = b"", b"", 12
    for name, data in entries:
        directory += struct.pack("<ii8s", offset, len(data), _name(name))
        body += data
        offset += len(data)
    with open(path, "wb") as f:
        f.write(struct.pack("<4sii", b"PWAD", len(entries), offset))
        f.write(body)
        f.write(directory)


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[-1].strip(), file=sys.stderr)
        return 2
    with open(argv[1]) as f:
        spec = json.load(f)
    try:
        lumps, stats = compile_spec(spec)
    except SpecError as e:
        print(f"levelgen: {e}", file=sys.stderr)
        return 1
    write_pwad(argv[2], spec.get("name", "E1M1"), lumps)
    print(json.dumps(stats))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
