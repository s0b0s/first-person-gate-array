"""Bit-accurate model of the game (stages 1 to 3): the specification of the game sequencer and
the actor engine RTL. Integer arithmetic only; ">>" is an arithmetic (floor) shift.

One call of Game.step(snapshot, spans, zwall) is one frame. spans and zwall are what the renderer
produced for the PREVIOUS frame (hitscan aims at what the player saw): spans is a list of
(actor index, x0, x1, z) for drawn target sprites, zwall the 320 wall z values.

Game flow (flow): TITLE -> BRIEFING -> PLAYING (<-> PAUSED) -> SCORE -> BRIEFING (next level) ...
-> ENDING -> TITLE; PLAYING -> DEAD -> PLAYING (level restarted). Use or a fire press moves on.

Order of one PLAYING frame (the RTL follows exactly this order, including every random() call):
  1. level clock; player turn; duck and peek easing (2 units per frame)
  2. move x then y: walls, closed doors and solid actors block; walls push the player back flush
  3. peek camera: the sideways offset shrinks by 2 until the camera box is free
  4. pickups (actor index order), then secret and toxic floor under the player
  5. use: door / locked door / exit switch 0.75 tile ahead
  6. weapon: select, cooldown, fire (hitscan against the last frame's spans)
  7. actors 0..31 in index order (actions, timers, fireballs); spawned actors take free slots
  8. doors; boss timer; death check; HUD timers
Random numbers: a 16-bit LFSR (x^16 + x^15 + x^13 + x^4 + 1), advanced once per random() call,
which returns the low 8 bits; seeded with 0xACE1 xor (level << 8) when a level loads.
"""

import zlib

import actors as A
import level as level_mod
from render import SIN, COS, EYE_MAX, floor_height, ceil_height, is_ramp, ramp_dir, RAMP_STEP
from render import light_mods, clamp_light

R = 16384             # player box half size, 0.25 tile in Q.16
CAM_HALF = 8192       # peek camera box half size, 1/8 tile
ITEM_HALF = 8192      # pickup box half size of an item, 1/8 tile (Q.16)
WALK_SHIFT, RUN_SHIFT = 4, 3
DOOR_STEP, DOOR_OPEN, DOOR_STAY, DOOR_RETRY, DOORS = 2, 64, 180, 30, 8
IDLE, OPENING, OPEN, CLOSING = 0, 1, 2, 3
TITLE, BRIEFING, PLAYING, PAUSED, DEAD, SCORE, ENDING = range(7)
EYE_STAND, EYE_DUCK, EYE_DEAD = 32, 16, 8
PEEK = 16
# Stage 4 heights (units, 64 per tile): the player and monsters climb steps up to STEP_MAX,
# need PLAYER_H / ACTOR_H of headroom, and fall FALL_ACC faster each frame up to FALL_MAX.
# On a flat level none of this ever triggers, so the stage-3 game is unchanged.
STEP_MAX, PLAYER_H, ACTOR_H = 24, 40, 40
FALL_ACC, FALL_MAX = 2, 16
COOLDOWN = {1: 14, 2: 40}
SHOTGUN_COLS = [160 + 8 * k for k in range(-3, 4)]
MAX_HEALTH, MAX_ARMOR, MAX_BULLETS, MAX_SHELLS = 100, 200, 200, 50
MSG_TIME = 120
BOB = [0, 1, 2, 3, 4, 3, 2, 1]
MAX_SOUNDS = 4
SOUND_PRIORITY = [5, 6, 3, 3, 4, 7, 6, 9, 5, 5, 5, 6, 5, 4, 6, 7, 3, 8]

# Messages (string ids in overlay.py)
M_NONE, M_HEALTH, M_MEDIKIT, M_ARMOR, M_BULLETS, M_SHELLS, M_SHOTGUN, M_KEY1, M_KEY2, \
    M_NEED1, M_NEED2, M_SECRET = range(12)
ITEM_MSG = [M_HEALTH, M_MEDIKIT, M_ARMOR, M_BULLETS, M_SHELLS, M_SHOTGUN, M_KEY1, M_KEY2]


def sext(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def sign(v):
    return (v > 0) - (v < 0)


class Snapshot:
    """The 40-bit per-frame input snapshot (bit positions SNAP_* in game_pkg)."""

    def __init__(self, turn=0, move=0, strafe=0, run=False, fire=False, use=False, duck=False,
                 peek_l=False, peek_r=False, wsel=0, wcycle=False, automap=False, menu=False,
                 debug=False):
        self.turn, self.move, self.strafe, self.run, self.fire, self.use = turn, move, strafe, run, fire, use
        self.duck, self.peek_l, self.peek_r, self.wsel, self.wcycle = duck, peek_l, peek_r, wsel, wcycle
        self.automap, self.menu, self.debug = automap, menu, debug

    def pack(self):
        w = self.turn & 0xFFF
        w |= (self.move & 3) << 12
        w |= (self.strafe & 3) << 14
        bits = [self.run, self.fire, self.use, self.duck, self.peek_l, self.peek_r]
        for i, b in enumerate(bits):
            w |= int(b) << (16 + i)
        w |= (self.wsel & 3) << 22
        w |= int(self.wcycle) << 24 | int(self.automap) << 25 | int(self.menu) << 26 | int(self.debug) << 27
        return w

    @staticmethod
    def unpack(w):
        return Snapshot(sext(w, 12), sext(w >> 12, 2), sext(w >> 14, 2), bool(w >> 16 & 1),
                        bool(w >> 17 & 1), bool(w >> 18 & 1), bool(w >> 19 & 1), bool(w >> 20 & 1),
                        bool(w >> 21 & 1), (w >> 22) & 3, bool(w >> 24 & 1), bool(w >> 25 & 1),
                        bool(w >> 26 & 1), bool(w >> 27 & 1))


class Door:
    def __init__(self):
        self.x = self.y = self.open = self.timer = 0
        self.state = IDLE


class Actor:
    def __init__(self, rec=0):
        f = A.unpack_actor(rec)
        self.x, self.y, self.state, self.timer = f["x"], f["y"], f["state"], f["timer"]
        self.health, self.type = f["health"], f["type"]
        self.active = bool(f["flags"] & 1)
        self.ambush = bool(f["flags"] & 8)          # stage 5: deaf to sound alerts
        self.solid = bool(f["flags"] & 2)
        self.awake = bool(f["flags"] & 4)

    def pack(self):
        flags = int(self.active) | int(self.solid) << 1 | int(self.awake) << 2 | int(self.ambush) << 3
        return A.pack_actor(self.x, self.y, self.state, self.timer, self.health, self.type, flags)


class Player:
    def __init__(self):
        self.health, self.armor, self.bullets, self.shells = 100, 0, 50, 0
        self.weapons = 1      # bit 0 pistol, bit 1 shotgun
        self.weapon = 1

    def copy(self):
        p = Player()
        p.__dict__.update(self.__dict__)
        return p


class Game:
    def __init__(self, levels=None):
        self.levels = levels or [f() for f in level_mod.LEVELS]
        self.flow = TITLE
        self.level = 1
        self.prev_fire = False
        self.debug = False
        self.player = Player()
        self.saved = Player()
        self.tiles = list(self.levels[0].tile_words())
        self.actors = [Actor() for _ in range(32)]
        self.doors = [Door() for _ in range(DOORS)]
        self.seen = set()
        self.reset_level_state(1)
        self.sounds = []

    # ---------------------------------------------------------------- level and flow
    def reset_level_state(self, n):
        lv = self.levels[n - 1]
        sx, sy, sa = lv.start
        self.tiles = list(lv.tile_words())
        recs = lv.actor_records()
        self.actors = [Actor(r) for r in recs] + [Actor() for _ in range(32 - len(recs))]
        self.doors = [Door() for _ in range(DOORS)]
        self.px, self.py, self.angle = int(round(sx * 65536)), int(round(sy * 65536)), sa & 1023
        self.eye, self.off = EYE_STAND, 0
        self.z = self.box_floor(self.px, self.py, R)
        self.vz = 0
        self.cam_x, self.cam_y = self.px, self.py
        self.keys = 0
        self.cooldown = self.flash = 0
        self.damage_flash = self.pickup_flash = 0
        self.msg, self.msg_timer = M_NONE, 0
        self.phase = 0
        self.kills = self.items = self.secrets = 0
        self.total_kills = sum(1 for a in self.actors if a.active and a.type in A.MONSTERS)
        self.total_items = sum(1 for a in self.actors if a.active and a.type == A.ITEM)
        self.total_secrets = sum(1 for t in self.tiles if (t >> 14) & 7 == level_mod.SP_SECRET)
        self.t_frames = self.t_sec = self.t_min = 0
        self.lfsr = 0xACE1 ^ (n << 8)
        self.boss_timer = 0
        self.level_done = False
        self.dead_timer = 0
        self.automap = False
        self.seen = set()

    def load_level(self, n, restart=False):
        self.level = n
        if restart:
            self.player = self.saved.copy()
        else:
            self.saved = self.player.copy()
        self.reset_level_state(n)

    def random(self):
        s = self.lfsr
        self.lfsr = ((s << 1) & 0xFFFF) | (((s >> 15) ^ (s >> 14) ^ (s >> 12) ^ (s >> 3)) & 1)
        return self.lfsr & 255

    # ---------------------------------------------------------------- map helpers
    def tile(self, cx, cy):
        return self.tiles[(cy & 63) * 64 + (cx & 63)]

    def door_at(self, x, y):
        for d in self.doors:
            if d.state != IDLE and d.x == x and d.y == y:
                return d
        return None

    def solid(self, cx, cy):
        t = self.tile(cx, cy)
        if (t & 15) == 0:
            return False
        if 1 <= (t >> 14) & 7 <= 3:
            d = self.door_at(cx & 63, cy & 63)
            return not (d is not None and d.open == DOOR_OPEN)
        return True

    def floor_at(self, x, y):
        """Floor height under the point (x, y) in Q.16 tiles; a ramp rises smoothly
        from its low end (its own floor) to the next tile's floor in its direction."""
        cx, cy = x >> 16, y >> 16
        t = self.tile(cx, cy)
        f = floor_height(t)
        if not is_ramp(t):
            return f
        d = ramp_dir(t)
        dx, dy = RAMP_STEP[d]
        rise = floor_height(self.tile(cx + dx, cy + dy)) - f
        frac = (x if d in (0, 1) else y) & 0xFFFF
        s = frac if d in (0, 2) else 65536 - frac
        return f + ((rise * s) >> 16)

    def box_floor(self, x, y, half):
        """Highest floor under the four corners of a box (the player stands on ledges)."""
        return max(self.floor_at(x + ox, y + oy) for ox in (-half, half) for oy in (-half, half))

    def blocks(self, cx, cy, z, height):
        """Cell (cx, cy) stops a body standing at height z: a solid cell, a step up of more
        than STEP_MAX (ramps never, their ends match their neighbors), or less headroom than
        height."""
        if self.solid(cx, cy):
            return True
        t = self.tile(cx, cy)
        f = floor_height(t)
        if not is_ramp(t) and f > z + STEP_MAX:
            return True
        return ceil_height(t) < max(f, z) + height

    def box_hits(self, x, y, half, solid_fn):
        for cy in ((y - half) >> 16, (y + half) >> 16):
            for cx in ((x - half) >> 16, (x + half) >> 16):
                if solid_fn(cx, cy):
                    return True
        return False

    def actor_blocks(self, x, y):
        """A solid actor overlaps the player box at (x, y) (Q.16)."""
        for a in self.actors:
            if a.active and a.solid:
                if abs((a.x << 6) - x) < R + (A.ACTOR_HALF << 6) and abs((a.y << 6) - y) < R + (A.ACTOR_HALF << 6):
                    return True
        return False

    # ---------------------------------------------------------------- player
    def move_x(self, dx):
        nx = self.px + dx
        if dx == 0:
            return
        if self.box_hits(nx, self.py, R, lambda a, b: self.blocks(a, b, self.z, PLAYER_H)):
            if dx > 0:
                self.px = max(self.px, (((nx + R) >> 16) << 16) - R - 1)
            else:
                self.px = min(self.px, ((((nx - R) >> 16) + 1) << 16) + R)
        elif not self.actor_blocks(nx, self.py):
            self.px = nx

    def move_y(self, dy):
        ny = self.py + dy
        if dy == 0:
            return
        if self.box_hits(self.px, ny, R, lambda a, b: self.blocks(a, b, self.z, PLAYER_H)):
            if dy > 0:
                self.py = max(self.py, (((ny + R) >> 16) << 16) - R - 1)
            else:
                self.py = min(self.py, ((((ny - R) >> 16) + 1) << 16) + R)
        elif not self.actor_blocks(self.px, ny):
            self.py = ny

    def in_cell(self, x, y, half, cx, cy):
        return self.box_hits(x, y, half, lambda a, b: a == cx and b == cy)

    def damage_player(self, dmg):
        p = self.player
        if p.health <= 0:
            return
        if p.armor > 0:
            saved = (dmg * 21) >> 6
            if saved > p.armor:
                saved = p.armor
            p.armor -= saved
            dmg -= saved
        p.health -= dmg
        if p.health < 0:
            p.health = 0
        self.damage_flash = 8
        self.sound(A.S_PLAYER_DEATH if p.health == 0 else A.S_PLAYER_PAIN, None)

    def message(self, m):
        self.msg, self.msg_timer = m, MSG_TIME

    # ---------------------------------------------------------------- sound
    def sound(self, sid, actor):
        if len(self.sounds) >= MAX_SOUNDS:
            return
        if actor is None:
            self.sounds.append((sid, 63, 0))
            return
        dx = abs((actor.x << 6) - self.px) >> 10
        dy = abs((actor.y << 6) - self.py) >> 10
        d = dx + dy - (min(dx, dy) >> 1)          # units (1 tile = 64)
        if d <= 200:
            vol = 63
        elif d >= 1200:
            vol = 0
        else:
            vol = min(63, ((1200 - d) * 65) >> 10)
        if vol == 0:
            return
        rx = (actor.x << 6) - self.px
        ry = (actor.y << 6) - self.py
        lateral = (rx * -SIN[self.angle] + ry * COS[self.angle]) >> 16   # Q.16 tiles
        pan = max(-31, min(31, lateral >> 11))     # 1/32 tile per step
        self.sounds.append((sid, vol, pan))

    # ---------------------------------------------------------------- doors
    def door_blocked(self, d):
        if self.in_cell(self.px, self.py, R, d.x, d.y):
            return True
        for a in self.actors:
            if a.active and a.solid and self.in_cell(a.x << 6, a.y << 6, A.ACTOR_HALF << 6, d.x, d.y):
                return True
        return False

    def use_door(self, cx, cy):
        d = self.door_at(cx, cy)
        if d is None:
            for e in self.doors:
                if e.state == IDLE:
                    e.x, e.y, e.open, e.timer, e.state = cx, cy, 0, 0, OPENING
                    self.sound(A.S_DOOR_OPEN, None)
                    return
            return
        if d.state == OPEN:
            if not self.door_blocked(d):
                d.state = CLOSING
                self.sound(A.S_DOOR_CLOSE, None)
        elif d.state == CLOSING:
            d.state = OPENING

    def update_doors(self):
        for d in self.doors:
            if d.state == OPENING:
                d.open += DOOR_STEP
                if d.open >= DOOR_OPEN:
                    d.open, d.state, d.timer = DOOR_OPEN, OPEN, DOOR_STAY
            elif d.state == OPEN:
                d.timer -= 1
                if d.timer == 0:
                    if self.door_blocked(d):
                        d.timer = DOOR_RETRY
                    else:
                        d.state = CLOSING
            elif d.state == CLOSING:
                if self.door_blocked(d):
                    d.state = OPENING
                else:
                    d.open -= DOOR_STEP
                    if d.open <= 0:
                        d.open, d.state = 0, IDLE

    # ---------------------------------------------------------------- actors
    def dist(self, a):
        return abs((self.px >> 6) - a.x) + abs((self.py >> 6) - a.y)

    def los(self, a):
        """Bresenham walk from the actor's cell to the player's; walls and closed doors block."""
        x, y = a.x >> 10, a.y >> 10
        x1, y1 = self.px >> 16, self.py >> 16
        dx, dy = abs(x1 - x), abs(y1 - y)
        sx, sy = sign(x1 - x), sign(y1 - y)
        err = dx - dy
        for _ in range(64):
            if x == x1 and y == y1:
                return True
            e2 = 2 * err
            if e2 > -dy:
                err -= dy
                x += sx
            if e2 < dx:
                err += dx
                y += sy
            if (x != x1 or y != y1) and self.solid(x, y):
                return False
        return False

    def enter(self, i, s):
        a = self.actors[i]
        a.state = s
        a.timer = A.STATES.rows[s][1]
        act = A.STATES.rows[s][2]
        if act not in A.PER_FRAME:
            self.action(i, act)

    def actor_floor(self, a):
        """Floor height under an actor's center."""
        return self.floor_at(a.x << 6, a.y << 6)

    def actor_move_ok(self, x, y, z):
        """Actor box (Q6.10) at (x, y) touches no cell that stops a body standing at z."""
        h = A.ACTOR_HALF
        for cy in ((y - h) >> 10, (y + h) >> 10):
            for cx in ((x - h) >> 10, (x + h) >> 10):
                if self.blocks(cx, cy, z, ACTOR_H):
                    return False
        return True

    def spawn(self, x, y, typ, state, health, flags):
        for j, b in enumerate(self.actors):
            if not b.active:
                b.x, b.y, b.type, b.health = x, y, typ, health
                b.active, b.solid, b.awake = bool(flags & 1), bool(flags & 2), bool(flags & 4)
                b.ambush = False
                b.state, b.timer = state, A.STATES.rows[state][1]
                return j
        return None

    def action(self, i, act):
        a = self.actors[i]
        p = A.TYPES.get(a.type)
        if act == A.A_SHOOT:
            self.sound(A.S_SHOOT, a)
            if self.los(a):
                chance = max(40, 200 - (self.dist(a) >> 7))
                if self.random() < chance:
                    self.damage_player(3 * (1 + (self.random() & 3)))
        elif act == A.A_FIRE:
            self.sound(A.S_FIRE, a)
            d16 = A.direction16((self.px >> 6) - a.x, (self.py >> 6) - a.y)
            self.spawn(a.x, a.y, A.FIREBALL, A.STATES.key[(A.FIREBALL, "fly_a")], d16, 1)
        elif act == A.A_MELEE:
            self.sound(A.S_CLAW, a)
            if self.dist(a) < A.MELEE_RANGE:
                self.damage_player(p.melee_mult * (1 + (self.random() & 7)))
        elif act == A.A_PAIN:
            self.sound(p.pain_sound, a)
        elif act == A.A_DIE:
            a.solid = False
            self.kills += 1
            self.sound(p.death_sound, a)
            if a.type == A.GRUNT:
                self.spawn(a.x, a.y, A.ITEM, A.STATES.key[(A.ITEM, "idle")], A.I_BULLETS, 1)
            if a.type == A.BOSS:
                self.boss_timer = 180
        elif act == A.A_EXPLODE:
            self.sound(A.S_EXPLODE, a)
        elif act == A.A_REMOVE:
            a.active = False

    def damage_actor(self, i, dmg):
        a = self.actors[i]
        if not (a.active and a.solid):
            return
        a.health -= dmg
        if a.health <= 0:
            a.health = 0
            self.enter(i, A.STATES.key[(a.type, "die1")])
            return
        was_awake = a.awake
        a.awake = True
        if self.random() < A.TYPES[a.type].pain_chance:
            self.enter(i, A.STATES.key[(a.type, "pain")])
        elif not was_awake:
            self.enter(i, A.STATES.key[(a.type, "chase_a")])

    def chase(self, i):
        a = self.actors[i]
        p = A.TYPES[a.type]
        k = A.STATES.key
        d = self.dist(a)
        if p.ranged and d < p.range and self.los(a):
            if (self.random() & p.atk_mask) == 0:
                self.enter(i, k[(a.type, "aim")])
                return True
        if p.melee and d < A.MELEE_RANGE:
            self.enter(i, k[(a.type, "melee")])
            return True
        if d >= A.STOP_RANGE:
            tx, ty = (self.px >> 6) - a.x, (self.py >> 6) - a.y
            sx = max(-p.speed, min(p.speed, tx))
            sy = max(-p.speed, min(p.speed, ty))
            if sx != 0 and self.actor_move_ok(a.x + sx, a.y, self.actor_floor(a)):
                a.x += sx
            if sy != 0 and self.actor_move_ok(a.x, a.y + sy, self.actor_floor(a)):
                a.y += sy
        return False

    def fly(self, i):
        a = self.actors[i]
        vx, vy = A.FIRE_VEL[a.health & 15]
        a.x = (a.x + vx) & 0xFFFF
        a.y = (a.y + vy) & 0xFFFF
        if self.solid(a.x >> 10, a.y >> 10):
            self.enter(i, A.STATES.key[(A.FIREBALL, "expl_a")])
            return True
        hit = A.ACTOR_HALF + 128
        if abs((self.px >> 6) - a.x) < hit and abs((self.py >> 6) - a.y) < hit:
            self.damage_player(3 * (1 + (self.random() & 7)))
            self.enter(i, A.STATES.key[(A.FIREBALL, "expl_a")])
            return True
        return False

    def actor_step(self, i):
        a = self.actors[i]
        if not a.active:
            return
        act = A.STATES.rows[a.state][2]
        changed = False
        if act == A.A_LOOK:
            if self.dist(a) < A.WAKE_RANGE and self.los(a):
                a.awake = True
                self.sound(A.TYPES[a.type].see_sound, a)
                self.enter(i, A.STATES.key[(a.type, "chase_a")])
                changed = True
        elif act == A.A_CHASE:
            changed = self.chase(i)
        elif act == A.A_FLY:
            changed = self.fly(i)
        if not changed and a.timer != A.FOREVER:
            a.timer -= 1
            if a.timer == 0:
                self.enter(i, A.STATES.rows[a.state][3])

    # ---------------------------------------------------------------- weapon
    def hitscan(self, col, spans, zwall, dmg):
        best = None
        for idx, x0, x1, z in spans:
            if x0 <= col <= x1 and z < zwall[col]:
                if best is None or z < best[1]:
                    best = (idx, z)
        if best is not None:
            self.damage_actor(best[0], dmg)

    def weapon(self, s, spans, zwall):
        p = self.player
        if s.wsel and (p.weapons >> (s.wsel - 1)) & 1:
            p.weapon = s.wsel
        elif s.wcycle:
            p.weapon = 2 if (p.weapon == 1 and p.weapons & 2) else 1
        if self.cooldown > 0:
            self.cooldown -= 1
        if self.flash > 0:
            self.flash -= 1
        if s.fire and self.cooldown == 0:
            if p.weapon == 1 and p.bullets > 0:
                p.bullets -= 1
                self.cooldown, self.flash = COOLDOWN[1], 4
                self.sound(A.S_PISTOL, None)
                self.hitscan(160, spans, zwall, 5 * (1 + (self.random() & 3)))
                self.alert()
            elif p.weapon == 2 and p.shells > 0:
                p.shells -= 1
                self.cooldown, self.flash = COOLDOWN[2], 4
                self.sound(A.S_SHOTGUN, None)
                for col in SHOTGUN_COLS:
                    self.hitscan(col, spans, zwall, 5 * (1 + (self.random() & 3)))
                self.alert()

    def alert(self):
        """Stage 5 sound alert: the shot is heard in every cell connected to the player's
        through open cells (4 neighbors; walls and closed doors stop it). Every sleeping,
        living monster there that is not an ambusher wakes as if it had seen the player.
        Actors are woken in slot order, after the shot's hitscan."""
        start = ((self.px >> 16) & 63, (self.py >> 16) & 63)
        heard = {start}
        queue = [start]
        k = 0
        while k < len(queue):
            x, y = queue[k]
            k += 1
            for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                nx, ny = nx & 63, ny & 63
                if (nx, ny) not in heard and not self.solid(nx, ny):
                    heard.add((nx, ny))
                    queue.append((nx, ny))
        for i, a in enumerate(self.actors):
            if (a.active and a.solid and a.type in A.MONSTERS and not a.awake and not a.ambush
                    and ((a.x >> 10) & 63, (a.y >> 10) & 63) in heard
                    and A.STATES.rows[a.state][2] == A.A_LOOK):
                a.awake = True
                self.sound(A.TYPES[a.type].see_sound, a)
                self.enter(i, A.STATES.key[(a.type, "chase_a")])

    def weapon_frame(self):
        import art
        if self.player.weapon == 1:
            return art.WEAPON_BASE + (1 if self.flash > 0 else 0)
        if self.cooldown > 36:
            return art.WEAPON_BASE + 3
        if self.cooldown > 16:
            return art.WEAPON_BASE + 4
        return art.WEAPON_BASE + 2

    # ---------------------------------------------------------------- pickups and specials
    def pickup(self, i):
        a = self.actors[i]
        p = self.player
        kind = a.health
        took = True
        if kind == A.I_HEALTH:
            took = p.health < MAX_HEALTH
            p.health = min(MAX_HEALTH, p.health + 10)
        elif kind == A.I_MEDIKIT:
            took = p.health < MAX_HEALTH
            p.health = min(MAX_HEALTH, p.health + 25)
        elif kind == A.I_ARMOR:
            took = p.armor < 100
            p.armor = max(p.armor, 100)
        elif kind == A.I_BULLETS:
            took = p.bullets < MAX_BULLETS
            p.bullets = min(MAX_BULLETS, p.bullets + 10)
        elif kind == A.I_SHELLS:
            took = p.shells < MAX_SHELLS
            p.shells = min(MAX_SHELLS, p.shells + 4)
        elif kind == A.I_SHOTGUN:
            p.weapons |= 2
            p.weapon = 2
            p.shells = min(MAX_SHELLS, p.shells + 8)
        elif kind == A.I_KEY1:
            self.keys |= 1
        elif kind == A.I_KEY2:
            self.keys |= 2
        if took:
            a.active = False
            self.items += 1
            self.pickup_flash = 6
            self.message(ITEM_MSG[kind])
            self.sound(A.S_WEAPON if kind == A.I_SHOTGUN else A.S_ITEM, None)

    def specials(self):
        cx, cy = self.px >> 16, self.py >> 16
        t = self.tile(cx, cy)
        sp = (t >> 14) & 7
        self.on_toxic = sp == level_mod.SP_TOXIC
        if sp == level_mod.SP_SECRET:
            self.secrets += 1
            self.tiles[(cy & 63) * 64 + (cx & 63)] = t & ~(7 << 14)
            self.message(M_SECRET)
        elif self.on_toxic and (self.t_frames & 31) == 0:
            self.damage_player(5)

    def use(self):
        ux = self.px + ((COS[self.angle] * 3) >> 2)
        uy = self.py + ((SIN[self.angle] * 3) >> 2)
        cx, cy = (ux >> 16) & 63, (uy >> 16) & 63
        t = self.tile(cx, cy)
        sp = (t >> 14) & 7
        if sp == level_mod.SP_DOOR:
            self.use_door(cx, cy)
        elif sp in (level_mod.SP_LOCKED1, level_mod.SP_LOCKED2):
            need = 1 if sp == level_mod.SP_LOCKED1 else 2
            if self.keys & need:
                self.use_door(cx, cy)
            else:
                self.message(M_NEED1 if need == 1 else M_NEED2)
                self.sound(A.S_NOWAY, None)
        elif sp == level_mod.SP_EXIT:
            self.level_done = True
            self.sound(A.S_SWITCH, None)

    # ---------------------------------------------------------------- one frame
    def step(self, s, spans=(), zwall=None):
        zwall = zwall or [0xFFFF] * 320
        self.sounds = []
        fire_edge = s.fire and not self.prev_fire
        self.prev_fire = s.fire
        go = s.use or fire_edge
        if s.debug:
            self.debug = not self.debug
        if self.flow == TITLE:
            if go:
                self.player = Player()
                self.level = 1
                self.flow = BRIEFING
        elif self.flow == BRIEFING:
            if go:
                self.load_level(self.level)
                self.flow = PLAYING
        elif self.flow == PAUSED:
            if s.menu:
                self.flow = PLAYING
        elif self.flow == DEAD:
            self.dead_timer += 1
            if self.eye > EYE_DEAD:
                self.eye -= 2
            if self.dead_timer > 30 and go:
                self.load_level(self.level, restart=True)
                self.flow = PLAYING
        elif self.flow == SCORE:
            if go:
                if self.level < len(self.levels):
                    self.level += 1
                    self.flow = BRIEFING
                else:
                    self.flow = ENDING
        elif self.flow == ENDING:
            if go:
                self.flow = TITLE
        elif self.flow == PLAYING:
            if s.menu:
                self.flow = PAUSED
            else:
                self.play(s, spans, zwall)

    def play(self, s, spans, zwall):
        p = self.player
        # 1. Clock, turn, duck and peek
        self.t_frames += 1
        if self.t_frames == 60:
            self.t_frames = 0
            self.t_sec += 1
            if self.t_sec == 60:
                self.t_sec = 0
                self.t_min = min(99, self.t_min + 1)
        self.angle = (self.angle + s.turn) & 1023
        target = EYE_DUCK if s.duck else EYE_STAND
        self.eye += 2 * sign(target - self.eye)
        peek = PEEK * ((1 if s.peek_r else 0) - (1 if s.peek_l else 0))
        self.off += 2 * sign(peek - self.off)
        if s.automap:
            self.automap = not self.automap
        # 2. Movement
        cs, sn = COS[self.angle], SIN[self.angle]
        vx = s.move * cs - s.strafe * sn
        vy = s.move * sn + s.strafe * cs
        shift = (RUN_SHIFT if s.run else WALK_SHIFT) + (1 if s.duck else 0)
        self.move_x(vx >> shift)
        self.move_y(vy >> shift)
        if s.move or s.strafe:
            self.phase = (self.phase + 1) & 31
        target = self.box_floor(self.px, self.py, R)
        if self.z > target:
            self.vz = min(self.vz + FALL_ACC, FALL_MAX)
            self.z = max(target, self.z - self.vz)
            if self.z == target:
                self.vz = 0
        else:
            self.z = target
            self.vz = 0
        # 3. Peek camera
        while self.off != 0:
            cx = self.px + ((-sn * self.off) >> 6)
            cy = self.py + ((cs * self.off) >> 6)
            if not self.box_hits(cx, cy, CAM_HALF, self.solid):
                break
            self.off -= 2 * sign(self.off)
        self.cam_x = self.px + ((-sn * self.off) >> 6)
        self.cam_y = self.py + ((cs * self.off) >> 6)
        # 4. Pickups, specials
        for i, a in enumerate(self.actors):
            if a.active and a.type == A.ITEM:
                if abs((a.x << 6) - self.px) < R + ITEM_HALF and abs((a.y << 6) - self.py) < R + ITEM_HALF:
                    self.pickup(i)
        self.specials()
        # 5. Use
        if s.use:
            self.use()
        # 6. Weapon
        self.weapon(s, spans, zwall)
        # 7. Actors
        for i in range(32):
            self.actor_step(i)
        # 8. World
        self.update_doors()
        if self.boss_timer > 0:
            self.boss_timer -= 1
            if self.boss_timer == 0:
                self.level_done = True
        if self.damage_flash > 0:
            self.damage_flash -= 1
        if self.pickup_flash > 0:
            self.pickup_flash -= 1
        if self.msg_timer > 0:
            self.msg_timer -= 1
            if self.msg_timer == 0:
                self.msg = M_NONE
        if p.health <= 0:
            self.flow = DEAD
            self.dead_timer = 0
        elif self.level_done:
            self.flow = SCORE

    # ---------------------------------------------------------------- outputs
    def render_doors(self):
        return [(d.x, d.y, d.open) for d in self.doors if d.state != IDLE]

    def fx_frame(self):
        """Frame number of the level clock that drives the light types and animations."""
        return (self.t_sec * 60 + self.t_frames) & 255

    def lmod(self):
        """Light offsets by light type for this frame (render.light_mods)."""
        return light_mods(self.fx_frame(), self.flash > 0)

    def anim(self):
        """Animated texture frame 0..3 (changes every 8 frames)."""
        return (self.fx_frame() >> 3) & 3

    def view_eye(self):
        """Renderer eye height: floor contact plus eye height, 7 bits."""
        return min(EYE_MAX, self.z + self.eye)

    def sprite_table(self):
        """Up to 32 sprites in actor order: (actor index, x, y (Q6.10), frame, light, flags,
        floor height under the sprite)."""
        out = []
        for i, a in enumerate(self.actors):
            if not a.active:
                continue
            frame = A.sprite_frame(a.type, a.state, a.health)
            t = self.tile(a.x >> 10, a.y >> 10)
            light = clamp_light(((t >> 8) & 15) + self.lmod()[(t >> 12) & 3])
            bright = a.type == A.FIREBALL
            target = a.solid and a.type in A.MONSTERS
            out.append((i, a.x, a.y, frame, light, int(bright) | int(target) << 1,
                        self.actor_floor(a)))
        return out

    def tint(self):
        if self.damage_flash > 0:
            return 1
        if self.pickup_flash > 0:
            return 2
        if self.flow == PLAYING and getattr(self, "on_toxic", False):
            return 3
        return 0

    def hud(self):
        p = self.player
        return {
            "flow": self.flow, "level": self.level, "health": p.health, "armor": p.armor,
            "ammo": p.bullets if p.weapon == 1 else p.shells, "weapon": p.weapon,
            "keys": self.keys, "wframe": self.weapon_frame(),
            "bob": BOB[(self.phase >> 2) & 7] if self.flow == PLAYING else 0,
            "msg": self.msg, "kills": self.kills, "total_kills": self.total_kills,
            "items": self.items, "total_items": self.total_items, "secrets": self.secrets,
            "total_secrets": self.total_secrets, "t_min": self.t_min, "t_sec": self.t_sec,
            "automap": self.automap, "debug": self.debug,
        }

    def state_crc(self):
        """Per-frame game-state checksum for replay validation (the RTL and the
        board must give the same CRC every frame): CRC32 (zlib) over the state words,
        each as 8 bytes little endian."""
        data = b"".join((w & 0xFFFFFFFFFFFFFFFF).to_bytes(8, "little") for w in self.state_words())
        return zlib.crc32(data) & 0xFFFFFFFF

    def state_words(self):
        """What the game testbench compares each frame (91 words: 19 scalars, 8 doors x 5,
        32 actor records). Word 5 = eye | z << 8 | vz << 16 (z and vz are 0 on flat levels,
        so stage-3 sessions keep their CRCs)."""
        p = self.player
        w = [self.flow, self.level, self.px, self.py, self.angle,
             self.eye | (self.z << 8) | (self.vz << 16), self.off & 0xFF,
             p.health, p.armor, p.bullets, p.shells, p.weapons, p.weapon, self.keys,
             self.cooldown, self.kills, self.items, self.secrets, self.lfsr]
        for d in self.doors:
            w += [d.x, d.y, d.open, d.state, d.timer]
        for a in self.actors:
            w.append(a.pack())
        return w
