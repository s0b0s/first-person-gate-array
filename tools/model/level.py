"""Levels: readable room lists turned into tile words and actor lists.

Tile word (24 bits):
    3:0 wall_tex (0 open, 1..15 wall texture)   5:4 floor_tex   7:6 ceil_tex
    11:8 light   13:12 light_type   16:14 special   19:17 floor_h   22:20 ceil_h
    23 door orientation: 0 = door plane perpendicular to x (rays and the player cross it while
       moving in x), 1 = perpendicular to y
Special codes: 1 door, 2 locked door (needs key 1, blue), 3 locked door (key 2, red), 4 exit
switch (a wall tile you "use"), 5 secret (a floor tile, counted once), 6 toxic floor, 7 ramp
(stage 4).
Doors (specials 1..3) must have walls on both sides across their axis, so a ray or the player
can only cross a door tile along the door's axis (check_doors() enforces it).

Stage 4 heights: floor height = floor_h * 8 units (0..56), ceiling = 64 - ceil_h * 8 units
(64..8); a tile is 64 units tall. Flat levels have every floor_h and ceil_h at 0, which is
the stage-3 game. A ramp (special 7) keeps its direction in ceil_tex (0 +x, 1 -x, 2 +y, 3 -y;
the ramp's ceiling flat is then flat 0) and rises from its own floor height to the floor
height of the next tile in that direction (check_heights() enforces walls on its two sides,
open tiles or doors at its ends, and chains of ramps in one direction). Bit 23 of an open, non-door tile marks a sky ceiling
(stage 4).

Level item in flash (level.binary()): 4096 tile words x 3 bytes little endian, start x u32,
start y u32 (Q6.16), start angle u16, actor count u16, then count x 8-byte actor records
(little endian, layout in actors.py), then the level number u8.
"""

import actors as A

SIZE = 64
WALL_CHARS = {1: "#", 2: "S", 3: "W", 4: "M", 5: "T", 6: "G", 7: "B", 8: "D"}
DOOR_TEX = 8
SWITCH_TEX = 5
SP_DOOR, SP_LOCKED1, SP_LOCKED2, SP_EXIT, SP_SECRET, SP_TOXIC, SP_RAMP = 1, 2, 3, 4, 5, 6, 7
RAMP_DIRS = {"+x": 0, "-x": 1, "+y": 2, "-y": 3}
RAMP_STEP = {0: (1, 0), 1: (-1, 0), 2: (0, 1), 3: (0, -1)}   # (dx, dy) toward the high end
MAX_LEVEL_ACTORS = 24        # leave 8 actor slots for fireballs and dropped items


class Level:
    def __init__(self, name, number):
        self.name = name
        self.number = number
        self.wall = [[1] * SIZE for _ in range(SIZE)]   # [y][x] wall texture, 0 = open
        self.floor = [[0] * SIZE for _ in range(SIZE)]
        self.ceil = [[2] * SIZE for _ in range(SIZE)]
        self.light = [[10] * SIZE for _ in range(SIZE)]
        self.ltype = [[0] * SIZE for _ in range(SIZE)]
        self.special = [[0] * SIZE for _ in range(SIZE)]
        self.door = [[None] * SIZE for _ in range(SIZE)]  # orientation 0 / 1
        self.fh = [[0] * SIZE for _ in range(SIZE)]       # floor_h 0..7 (x 8 units)
        self.ch = [[0] * SIZE for _ in range(SIZE)]       # ceil_h 0..7 (ceiling 64 - 8 ceil_h)
        self.ramp_dir = [[None] * SIZE for _ in range(SIZE)]
        self.sky = [[False] * SIZE for _ in range(SIZE)]
        self.start = (1.5, 1.5, 0)                        # x, y in tiles, angle 0..1023
        self.actors = []                                  # (x, y, type, kind)

    def zone(self, x0, y0, x1, y1, light=None, floor=None, ceil=None, ltype=None):
        """Floor, ceiling, light and light type for x0..x1, y0..y1 (inclusive)."""
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                if light is not None:
                    self.light[y][x] = light
                if floor is not None:
                    self.floor[y][x] = floor
                if ceil is not None:
                    self.ceil[y][x] = ceil
                if ltype is not None:
                    self.ltype[y][x] = ltype

    def room(self, x0, y0, x1, y1, walltex, light, floor=0, ceil=2):
        """Open x0..x1, y0..y1; the surrounding wall ring gets walltex."""
        for y in range(y0 - 1, y1 + 2):
            for x in range(x0 - 1, x1 + 2):
                inside = x0 <= x <= x1 and y0 <= y <= y1
                if inside:
                    self.wall[y][x] = 0
                elif self.wall[y][x] != 0:
                    self.wall[y][x] = walltex
        self.zone(x0 - 1, y0 - 1, x1 + 1, y1 + 1, light, floor, ceil)

    def corridor(self, x0, y0, x1, y1, light=10, floor=0, ceil=2):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                self.wall[y][x] = 0
        self.zone(x0, y0, x1, y1, light, floor, ceil)

    def pillar(self, x, y, walltex):
        self.wall[y][x] = walltex

    def heights(self, x0, y0, x1, y1, fh=None, ch=None):
        """Floor height step fh (x 8 units) and ceiling drop ch for x0..x1, y0..y1."""
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                if fh is not None:
                    self.fh[y][x] = fh
                if ch is not None:
                    self.ch[y][x] = ch

    def ramp(self, x0, y0, x1, y1, direction):
        """Ramp tiles x0..x1, y0..y1 rising toward direction ("+x", "-x", "+y", "-y")."""
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                assert self.wall[y][x] == 0
                self.special[y][x] = SP_RAMP
                self.ramp_dir[y][x] = RAMP_DIRS[direction]

    def set_sky(self, x0, y0, x1, y1):
        """Sky ceiling over the open tiles of x0..x1, y0..y1 (walls and doors keep theirs)."""
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                if self.wall[y][x] == 0 and self.door[y][x] is None:
                    self.sky[y][x] = True

    def add_door(self, x, y, orientation, special=SP_DOOR):
        self.wall[y][x] = DOOR_TEX
        self.door[y][x] = orientation
        self.special[y][x] = special

    def exit_switch(self, x, y):
        assert self.wall[y][x] != 0
        self.wall[y][x] = SWITCH_TEX
        self.special[y][x] = SP_EXIT

    def secret(self, x, y):
        assert self.wall[y][x] == 0
        self.special[y][x] = SP_SECRET

    def toxic(self, x0, y0, x1, y1):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                if self.wall[y][x] == 0:
                    self.special[y][x] = SP_TOXIC

    def monster(self, x, y, typ, ambush=False):
        """ambush (stage 5): the monster ignores sound alerts (wakes by sight or when hit)."""
        self.actors.append((x + 0.5, y + 0.5, typ, 1 if ambush else 0))

    def item(self, x, y, kind):
        self.actors.append((x + 0.5, y + 0.5, A.ITEM, kind))

    def check_doors(self):
        for y in range(SIZE):
            for x in range(SIZE):
                o = self.door[y][x]
                if o is None:
                    continue
                if o == 0:
                    across = [(x, y - 1), (x, y + 1)]
                    along = [(x - 1, y), (x + 1, y)]
                else:
                    across = [(x - 1, y), (x + 1, y)]
                    along = [(x, y - 1), (x, y + 1)]
                for cx, cy in across:
                    assert self.wall[cy][cx] != 0 and self.door[cy][cx] is None, \
                        "door at %d,%d needs walls at %d,%d" % (x, y, cx, cy)
                for cx, cy in along:
                    assert self.wall[cy][cx] == 0, "door at %d,%d needs open %d,%d" % (x, y, cx, cy)

    def check_heights(self):
        for y in range(SIZE):
            for x in range(SIZE):
                assert self.fh[y][x] * 8 <= 64 - self.ch[y][x] * 8 - 8,                     "tile %d,%d: floor above its ceiling" % (x, y)
                if self.door[y][x] is not None:
                    # A door tile takes the heights of both tiles along its axis
                    o = self.door[y][x]
                    for cx, cy in (((x - 1, y), (x + 1, y)) if o == 0 else ((x, y - 1), (x, y + 1))):
                        assert (self.fh[cy][cx], self.ch[cy][cx]) == (self.fh[y][x], self.ch[y][x]),                             "door at %d,%d: heights differ from %d,%d" % (x, y, cx, cy)
                if self.sky[y][x]:
                    assert self.wall[y][x] == 0 and self.door[y][x] is None
                d = self.ramp_dir[y][x]
                if d is None:
                    continue
                dx, dy = RAMP_STEP[d]
                assert self.ch[y][x] == 0 and not self.sky[y][x], "ramp %d,%d: full-height ceiling" % (x, y)
                for sx, sy in ((dy, dx), (-dy, -dx)):          # the two sides: walls or the same ramp
                    cx, cy = x + sx, y + sy
                    assert self.wall[cy][cx] != 0 or self.ramp_dir[cy][cx] == d,                         "ramp %d,%d: side %d,%d must be a wall or the same ramp" % (x, y, cx, cy)
                for ex, ey in ((x + dx, y + dy), (x - dx, y - dy)):
                    # The two ends: open or a door, and no ramp unless it continues this one
                    assert self.wall[ey][ex] == 0 or self.door[ey][ex] is not None,                         "ramp %d,%d: end %d,%d must be open or a door" % (x, y, ex, ey)
                    assert self.ramp_dir[ey][ex] in (None, d),                         "ramp %d,%d: end %d,%d is a ramp in another direction" % (x, y, ex, ey)
                bx, by = x - dx, y - dy
                assert self.ramp_dir[by][bx] == d or self.fh[y][x] == self.fh[by][bx],                     "ramp %d,%d: its low end must match the tile behind it" % (x, y)

    def check(self):
        self.check_doors()
        self.check_heights()
        for i in range(SIZE):
            for x, y in ((i, 0), (i, SIZE - 1), (0, i), (SIZE - 1, i)):
                assert self.wall[y][x] != 0, "the map border must be solid"
        assert len(self.actors) <= MAX_LEVEL_ACTORS
        for x, y, _, _ in self.actors:
            assert self.wall[int(y)][int(x)] == 0, "actor inside a wall at %s,%s" % (x, y)

    def tile_words(self):
        """64 x 64 tile words, index y * 64 + x."""
        self.check()
        words = []
        for y in range(SIZE):
            for x in range(SIZE):
                w = self.wall[y][x] & 15
                w |= (self.floor[y][x] & 3) << 4
                if self.ramp_dir[y][x] is not None:
                    w |= (self.ramp_dir[y][x] & 3) << 6
                else:
                    w |= (self.ceil[y][x] & 3) << 6
                w |= (self.light[y][x] & 15) << 8
                w |= (self.ltype[y][x] & 3) << 12
                w |= (self.special[y][x] & 7) << 14
                w |= (self.fh[y][x] & 7) << 17
                w |= (self.ch[y][x] & 7) << 20
                if self.door[y][x] is not None:
                    w |= (self.door[y][x] & 1) << 23
                elif self.sky[y][x]:
                    w |= 1 << 23
                words.append(w)
        return words

    def actor_records(self):
        """Initial actor records (64-bit ints), in level order."""
        recs = []
        for x, y, typ, kind in self.actors:
            if typ == A.ITEM:
                state = A.STATES.key[(A.ITEM, "idle")]
                health = kind
                flags = 1                       # active
            else:
                state = A.STATES.key[(typ, "stand")]
                health = A.TYPES[typ].health
                flags = 1 | 2 | (8 if kind else 0)   # active, solid, ambush
            timer = A.STATES.rows[state][1]
            recs.append(A.pack_actor(int(round(x * 1024)), int(round(y * 1024)), state, timer,
                                     health, typ, flags))
        return recs

    def binary(self):
        sx, sy, sa = self.start
        data = bytearray()
        for t in self.tile_words():
            data += bytes((t & 0xFF, (t >> 8) & 0xFF, (t >> 16) & 0xFF))
        data += int(round(sx * 65536)).to_bytes(4, "little")
        data += int(round(sy * 65536)).to_bytes(4, "little")
        data += (sa & 1023).to_bytes(2, "little")
        recs = self.actor_records()
        data += len(recs).to_bytes(2, "little")
        for r in recs:
            data += r.to_bytes(8, "little")
        data += bytes((self.number,))
        return bytes(data)

    def write_ascii(self, path):
        lines = ["%s, %d x %d. Start x=%.2f y=%.2f angle=%d" % ((self.name, SIZE, SIZE) + self.start),
                 "Legend: . open, " + ", ".join("%s tex %d" % (c, t) for t, c in WALL_CHARS.items()) +
                 ", X exit switch, $ secret, ~ toxic, 1/2 locked doors, m monster, i item",
                 "Light per tile is in the zone list in tools/model/level.py.", ""]
        sx, sy, _ = self.start
        marks = {}
        for x, y, typ, kind in self.actors:
            marks[(int(x), int(y))] = "i" if typ == A.ITEM else "m"
        for y in range(SIZE):
            row = ""
            for x in range(SIZE):
                sp = self.special[y][x]
                if (x, y) == (int(sx), int(sy)):
                    row += "P"
                elif (x, y) in marks:
                    row += marks[(x, y)]
                elif sp == SP_EXIT:
                    row += "X"
                elif sp in (SP_LOCKED1, SP_LOCKED2):
                    row += str(sp - 1)
                elif sp == SP_SECRET:
                    row += "$"
                elif sp == SP_TOXIC:
                    row += "~"
                elif self.wall[y][x] == 0:
                    row += "."
                else:
                    row += WALL_CHARS.get(self.wall[y][x], "?")
            lines.append(row)
        with open(path, "w", encoding="ascii", newline="\n") as f:
            f.write("\n".join(lines) + "\n")


def level1():
    """Level 1: doors and an exit switch; Grunts and one Fiend."""
    lv = Level("Level 1", 1)
    lv.room(4, 4, 15, 13, 2, light=13, floor=0, ceil=2)       # A: start hall
    lv.room(28, 4, 39, 15, 5, light=12, floor=0, ceil=2)      # B: tech room
    lv.room(24, 28, 47, 43, 4, light=11, floor=0, ceil=2)     # C: metal hall
    for px, py in ((30, 33), (30, 38), (41, 33), (41, 38)):
        lv.pillar(px, py, 6)
    lv.room(4, 30, 11, 45, 3, light=7, floor=1, ceil=3)       # D: dark wooden room
    lv.zone(4, 30, 11, 45, ltype=1)                           #    flickering light
    lv.room(56, 24, 60, 40, 7, light=14, floor=0, ceil=2)     # E: blue tiles
    lv.room(28, 48, 45, 58, 6, light=6, floor=1, ceil=3)      # F: slime pit
    lv.set_sky(28, 48, 45, 58)                                #    open to the sky
    lv.corridor(16, 8, 27, 8)
    lv.corridor(33, 16, 33, 27)
    lv.corridor(12, 36, 23, 36)
    lv.corridor(48, 30, 55, 30)
    lv.corridor(8, 14, 8, 29)
    lv.corridor(36, 44, 36, 47)
    lv.add_door(16, 8, 0)
    lv.add_door(33, 16, 1)
    lv.add_door(23, 36, 0)
    lv.add_door(48, 30, 0)
    lv.add_door(8, 20, 1)
    lv.add_door(36, 45, 1)
    lv.exit_switch(61, 32)                                   # east wall of room E
    lv.secret(4, 45)                                         # corner of the dark room
    lv.start = (9.5, 8.5, 0)
    # Enemies
    lv.monster(34, 9, A.GRUNT)
    lv.monster(37, 12, A.GRUNT)
    lv.monster(28, 36, A.GRUNT)
    lv.monster(44, 30, A.GRUNT)
    lv.monster(8, 40, A.GRUNT)
    lv.monster(58, 36, A.FIEND)
    lv.monster(35, 54, A.GRUNT)
    lv.monster(40, 56, A.GRUNT)
    # Items
    lv.item(13, 11, A.I_BULLETS)
    lv.item(38, 5, A.I_HEALTH)
    lv.item(46, 42, A.I_SHOTGUN)
    lv.item(25, 42, A.I_SHELLS)
    lv.item(5, 44, A.I_MEDIKIT)
    lv.item(59, 25, A.I_ARMOR)
    lv.item(30, 57, A.I_BULLETS)
    return lv


def level2():
    """Level 2: a blue key behind slime and a locked door to the exit; Fiends join in."""
    lv = Level("Level 2", 2)
    lv.room(4, 4, 13, 13, 4, light=12)                        # A: start, metal
    lv.room(24, 4, 41, 13, 1, light=11)                       # B: brick hall
    lv.room(24, 22, 41, 37, 6, light=8, floor=1, ceil=3)      # C: slime cavern
    lv.toxic(26, 26, 39, 33)
    lv.room(48, 22, 58, 31, 7, light=13)                      # D: key room
    lv.room(4, 26, 15, 41, 2, light=10)                       # E: stone yard
    lv.room(4, 50, 21, 58, 5, light=14)                       # F: exit room
    for px, py in ((28, 7), (33, 10), (38, 7)):
        lv.pillar(px, py, 4)
    lv.corridor(14, 8, 23, 8)
    lv.corridor(32, 14, 32, 21)
    lv.corridor(42, 27, 47, 27)
    lv.corridor(16, 34, 23, 34)
    lv.corridor(10, 42, 10, 49)
    lv.add_door(18, 8, 0)
    lv.add_door(32, 18, 1)
    lv.add_door(45, 27, 0)
    lv.add_door(20, 34, 0)
    lv.add_door(10, 46, 1, SP_LOCKED1)                        # needs the blue key
    lv.exit_switch(22, 54)
    lv.secret(58, 31)
    lv.start = (8.5, 8.5, 0)
    lv.monster(30, 5, A.GRUNT)
    lv.monster(40, 12, A.GRUNT)
    lv.monster(36, 6, A.FIEND)
    lv.monster(27, 24, A.FIEND)
    lv.monster(39, 35, A.GRUNT)
    lv.monster(55, 25, A.FIEND)
    lv.monster(57, 30, A.GRUNT)
    lv.monster(6, 30, A.BRUTE)
    lv.monster(12, 38, A.GRUNT)
    lv.monster(14, 56, A.FIEND)
    lv.item(56, 26, A.I_KEY1)
    lv.item(12, 12, A.I_SHOTGUN)
    lv.item(41, 4, A.I_SHELLS)
    lv.item(24, 37, A.I_MEDIKIT)
    lv.item(50, 23, A.I_ARMOR)
    lv.item(5, 40, A.I_SHELLS)
    lv.item(15, 27, A.I_HEALTH)
    lv.item(6, 52, A.I_BULLETS)
    return lv


def level3():
    """Level 3: dark rooms and the boss arena; killing the Boss ends the game. Stage 4
    heights: stairs to a platform, a ramp, a raised hall with a lower ceiling, a pit, drops
    and a dais."""
    lv = Level("Level 3", 3)
    lv.room(4, 26, 11, 37, 3, light=9)                        # A: start
    lv.heights(4, 26, 11, 27, fh=3)                           #    platform 24 high
    lv.heights(4, 28, 11, 28, fh=2)                           #    three stairs up to it
    lv.heights(4, 29, 11, 29, fh=1)
    lv.room(18, 20, 27, 43, 1, light=4, floor=1, ceil=3)      # B: dark brick maze hall
    lv.heights(18, 20, 27, 43, fh=2)                          #    16 high
    lv.heights(18, 36, 27, 43, ch=1)                          #    lower ceiling at the far end
    lv.zone(18, 20, 27, 43, ltype=1)                          #    flickering light
    for px, py in ((20, 24), (24, 28), (20, 32), (24, 36), (20, 40)):
        lv.pillar(px, py, 1)
    lv.room(34, 8, 47, 19, 2, light=3, floor=1, ceil=3)       # C: very dark stone room
    lv.heights(34, 8, 47, 19, fh=3)                           #    24 high
    lv.heights(40, 12, 43, 15, fh=0)                          #    with a pit 24 deep
    lv.zone(34, 8, 47, 19, ltype=3)                           #    glowing light
    lv.room(34, 32, 59, 57, 4, light=10)                      # D: boss arena
    lv.heights(44, 42, 49, 47, fh=1)                          #    dais under the Boss
    for px, py in ((40, 38), (53, 38), (40, 51), (53, 51)):
        lv.pillar(px, py, 6)
    lv.set_sky(34, 32, 59, 57)                                # D: outdoors (after its pillars)
    lv.corridor(12, 31, 17, 31)
    lv.ramp(16, 31, 17, 31, "+x")                             # A to B: a ramp up 16
    lv.heights(17, 31, 17, 31, fh=1)
    lv.corridor(22, 14, 33, 14, light=5)
    lv.corridor(22, 15, 22, 19, light=5)
    lv.heights(22, 14, 33, 14, fh=2)                          # B to C at B's height, step up 8
    lv.zone(22, 14, 33, 14, ltype=2)                          #    strobing light
    lv.heights(22, 15, 22, 19, fh=2)
    lv.corridor(28, 40, 33, 40)
    lv.heights(28, 40, 33, 40, fh=2)                          # B to the arena: a drop of 16
    lv.add_door(15, 31, 0)
    lv.add_door(30, 40, 0, SP_LOCKED2)                        # only way into the arena: red key
    lv.add_door(22, 17, 1)
    lv.secret(47, 19)
    lv.start = (7.5, 31.5, 0)
    lv.monster(23, 22, A.GRUNT)
    lv.monster(26, 30, A.FIEND)
    lv.monster(19, 38, A.BRUTE)
    lv.monster(25, 42, A.GRUNT)
    lv.monster(36, 10, A.FIEND)
    lv.monster(45, 17, A.BRUTE, ambush=True)                 # guards room C
    lv.monster(46, 45, A.BOSS, ambush=True)                  # waits in the arena until seen
    lv.monster(36, 55, A.FIEND)
    lv.monster(57, 34, A.FIEND)
    lv.item(46, 9, A.I_KEY2)
    lv.item(10, 27, A.I_SHOTGUN)
    lv.item(11, 36, A.I_SHELLS)
    lv.item(27, 21, A.I_MEDIKIT)
    lv.item(35, 18, A.I_ARMOR)
    lv.item(34, 33, A.I_SHELLS)
    lv.item(59, 57, A.I_MEDIKIT)
    lv.item(19, 43, A.I_BULLETS)
    return lv


def level_test():
    """Directed stage-4 test map (not a game level; tools/model/golden4.py drives it with a
    scripted session). Along y = 3..5: a step up 16, a drop back to 0, then a step up 24 from 0
    (exactly STEP_MAX; higher steps cannot be reached anyway, since a floor above 24 leaves less
    than the 40 units of headroom under the 64-unit ceiling), then a drop to 0. A corridor south
    at x = 17 starts 8 up and goes down a ramp rising toward -y (its direction field 3 also
    tests the ramp ceiling rule), then under a ceiling exactly 40 above the floor (passable) to
    one 32 above it (refused)."""
    lv = Level("Test", 9)
    lv.room(2, 3, 18, 5, 1, light=12)
    lv.heights(7, 3, 9, 5, fh=2)                              # step up 16
    lv.heights(13, 3, 15, 5, fh=3)                            # step up 24 from 0
    lv.corridor(17, 6, 17, 14, light=12)
    lv.heights(17, 6, 17, 7, fh=1)                            # 8 up at the north end
    lv.ramp(17, 8, 17, 8, "-y")                               # rises from 0 (south) to 8 (north)
    lv.heights(17, 11, 17, 12, ch=3)                          # ceiling 40 above the floor: passes
    lv.heights(17, 13, 17, 14, ch=4)                          # ceiling 32 above the floor: refused
    # A separate corridor with a chain of three ramps: seen end-on, one column crosses 24
    # height edges, more than the 16 clip entries a column keeps (the last one is rewritten)
    lv.corridor(2, 10, 12, 10, light=12)
    lv.ramp(5, 10, 7, 10, "+x")
    lv.heights(6, 10, 6, 10, fh=1)
    lv.heights(7, 10, 7, 10, fh=2)
    lv.heights(8, 10, 12, 10, fh=3)
    lv.start = (3.5, 4.5, 0)
    return lv


def level_alert():
    """Directed stage-5 test map (not a game level; golden4.py drives it with a scripted
    session): from the start room A, room B lies around a corner (no line of sight) with a
    normal Grunt and an ambushing Grunt; room C lies behind a closed door with a Grunt. A shot
    from A must wake only B's normal Grunt; after the door is opened, a second shot must also
    wake C's Grunt; B's ambusher must stay asleep."""
    lv = Level("Alert test", 10)
    lv.room(2, 2, 6, 8, 2, light=12)                          # A: start
    lv.corridor(7, 5, 10, 5)
    lv.corridor(10, 2, 10, 4)
    lv.room(11, 1, 15, 3, 2, light=12)                        # B: around the corner
    lv.corridor(10, 1, 10, 1)
    lv.corridor(4, 10, 4, 23)                                 # C: behind the door, a long
    lv.room(2, 24, 6, 28, 2, light=12)                        #    corridor to a far room
    lv.add_door(4, 9, 1)                                      #    (beyond the sight range)
    lv.monster(14, 2, A.GRUNT)
    lv.monster(15, 1, A.GRUNT, ambush=True)
    lv.monster(3, 27, A.GRUNT)
    lv.start = (4.5, 5.5, 0)
    return lv


LEVELS = [level1, level2, level3]
