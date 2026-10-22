"""Actor types, the state table and the actor record.

DOOM's idea: every enemy, item and projectile is a record that walks through a table of
states. Each state names a sprite frame, a duration in frames (60 per second; 63 = forever),
an action and the next state. Entry actions run once when a state is entered; LOOK, CHASE and
FLY run on every frame spent in their state.

Actor record (64 bits, BRAM, 32 actors):
    15:0  x, Q6.10 tiles       31:16 y, Q6.10       38:32 state (0..127)
    44:39 timer (frames left; 63 = forever)          56:45 health (0..4095); fireballs:
          direction 0..15 (22.5 deg steps, clockwise from +x); items: item kind
    59:57 type   62:60 flags (60 active, 61 solid, 62 awake)   63 ambush (stage 5: the
    monster ignores sound alerts and wakes only by sight or when hit)
State table entry (22 bits): 4:0 frame, 10:5 duration, 14:11 action, 21:15 next.
"""

from art import MONSTER_BASE, ITEM_BASE

# Types
GRUNT, FIEND, BRUTE, BOSS, FIREBALL, ITEM = range(6)
MONSTERS = (GRUNT, FIEND, BRUTE, BOSS)

# Actions
A_NONE, A_LOOK, A_CHASE, A_FACE, A_MELEE, A_SHOOT, A_FIRE, A_PAIN, A_DIE, A_REMOVE, \
    A_FLY, A_EXPLODE = range(12)
PER_FRAME = (A_LOOK, A_CHASE, A_FLY)
FOREVER = 63

# Item kinds (in the health field of an item actor)
I_HEALTH, I_MEDIKIT, I_ARMOR, I_BULLETS, I_SHELLS, I_SHOTGUN, I_KEY1, I_KEY2 = range(8)

# Fireball and explosion frames inside the item/effect range of the art
F_FIRE_A, F_FIRE_B, F_EXPL_A, F_EXPL_B = ITEM_BASE + 8, ITEM_BASE + 9, ITEM_BASE + 10, ITEM_BASE + 11


class TypeParams:
    def __init__(self, health, speed, ranged, melee, rng, atk_mask, pain_chance, melee_mult,
                 see_sound, pain_sound, death_sound):
        self.health = health          # starting health
        self.speed = speed            # Q6.10 tiles per frame on each axis
        self.ranged = ranged          # 0 none, A_SHOOT or A_FIRE
        self.melee = melee            # has a melee attack
        self.range = rng              # ranged attack range, Q6.10 (Manhattan)
        self.atk_mask = atk_mask      # attack when (random & mask) == 0 while in range
        self.pain_chance = pain_chance  # pain when random < pain_chance (0..256)
        self.melee_mult = melee_mult  # melee damage = mult * (1 + (random & 7))
        self.see_sound, self.pain_sound, self.death_sound = see_sound, pain_sound, death_sound


# Sound ids (index into the flash sound directory; see audio.py)
S_PISTOL, S_SHOTGUN, S_DOOR_OPEN, S_DOOR_CLOSE, S_ITEM, S_WEAPON, S_PLAYER_PAIN, \
    S_PLAYER_DEATH, S_SIGHT, S_SHOOT, S_FIRE, S_EXPLODE, S_CLAW, S_PAIN, S_DEATH, S_SWITCH, \
    S_NOWAY, S_BOSS_SIGHT = range(18)

TYPES = {
    GRUNT: TypeParams(30, 40, A_SHOOT, False, 10 << 10, 31, 200, 0, S_SIGHT, S_PAIN, S_DEATH),
    FIEND: TypeParams(60, 32, A_FIRE, True, 14 << 10, 63, 160, 3, S_SIGHT, S_PAIN, S_DEATH),
    BRUTE: TypeParams(150, 72, 0, True, 0, 0, 80, 4, S_SIGHT, S_PAIN, S_DEATH),
    BOSS: TypeParams(1000, 32, A_FIRE, False, 20 << 10, 31, 20, 0, S_BOSS_SIGHT, S_PAIN, S_DEATH),
}

WAKE_RANGE = 12 << 10      # Manhattan distance, Q6.10
MELEE_RANGE = 1280         # 1.25 tiles
STOP_RANGE = 768           # stop walking closer than 0.75 tile
ACTOR_HALF = 256           # actor box half size, 0.25 tile in Q6.10
FIRE_SPEED = 128           # fireball speed, 1/8 tile per frame


class StateTable:
    """Builds the 128-entry table; remembers each type's key states."""

    def __init__(self):
        self.rows = []      # (frame, duration, action, next)
        self.names = []
        self.key = {}       # (type, name) -> index

    def add(self, typ, name, frame, dur, action, nxt=None):
        idx = len(self.rows)
        self.rows.append([frame, dur, action, nxt])
        self.names.append("%s_%s" % (typ, name))
        self.key[(typ, name)] = idx
        return idx

    def link(self, typ, name, target):
        self.rows[self.key[(typ, name)]][3] = self.key[(typ, target)]


def build_states():
    st = StateTable()
    for typ in MONSTERS:
        st.add(typ, "stand", 0, 10, A_LOOK)
        st.add(typ, "chase_a", 1, 8, A_CHASE)
        st.add(typ, "chase_b", 2, 8, A_CHASE)
        st.add(typ, "aim", 0, 10, A_FACE)
        ranged = TYPES[typ].ranged or A_NONE
        st.add(typ, "attack", 3, 12, ranged)
        st.add(typ, "melee", 3, 12, A_MELEE)
        st.add(typ, "pain", 4, 8, A_PAIN)
        st.add(typ, "die1", 5, 6, A_DIE)
        st.add(typ, "die2", 6, 6, A_NONE)
        st.add(typ, "die3", 7, 6, A_NONE)
        st.add(typ, "corpse", 8, FOREVER, A_NONE)
        st.link(typ, "stand", "stand")
        st.link(typ, "chase_a", "chase_b")
        st.link(typ, "chase_b", "chase_a")
        st.link(typ, "aim", "attack")
        st.link(typ, "attack", "chase_a")
        st.link(typ, "melee", "chase_a")
        st.link(typ, "pain", "chase_a")
        st.link(typ, "die1", "die2")
        st.link(typ, "die2", "die3")
        st.link(typ, "die3", "corpse")
        st.link(typ, "corpse", "corpse")
    # The Boss fires twice: attack (frame 3) then attack2 (frame 10)
    st.add(BOSS, "attack2", 10, 12, A_FIRE)
    st.link(BOSS, "attack", "attack2")
    st.link(BOSS, "attack2", "chase_a")
    # Fireball: frames are absolute (effect range); the frame field holds frame - ITEM_BASE
    st.add(FIREBALL, "fly_a", F_FIRE_A - ITEM_BASE, 4, A_FLY)
    st.add(FIREBALL, "fly_b", F_FIRE_B - ITEM_BASE, 4, A_FLY)
    st.add(FIREBALL, "expl_a", F_EXPL_A - ITEM_BASE, 6, A_EXPLODE)
    st.add(FIREBALL, "expl_b", F_EXPL_B - ITEM_BASE, 6, A_NONE)
    st.add(FIREBALL, "gone", 0, 1, A_REMOVE)
    st.link(FIREBALL, "fly_a", "fly_b")
    st.link(FIREBALL, "fly_b", "fly_a")
    st.link(FIREBALL, "expl_a", "expl_b")
    st.link(FIREBALL, "expl_b", "gone")
    st.link(FIREBALL, "gone", "gone")
    # Items stand still forever; their frame comes from the item kind
    st.add(ITEM, "idle", 0, FOREVER, A_NONE)
    st.link(ITEM, "idle", "idle")
    assert len(st.rows) <= 128
    for r in st.rows:
        assert r[3] is not None
    return st


STATES = build_states()


def state_word(row):
    frame, dur, action, nxt = row
    return (frame & 31) | ((dur & 63) << 5) | ((action & 15) << 11) | ((nxt & 127) << 15)


def sprite_frame(typ, state, health):
    """Global art frame id of an actor in a state."""
    frame = STATES.rows[state][0]
    if typ == ITEM:
        return ITEM_BASE + health
    if typ == FIREBALL:
        return ITEM_BASE + frame
    base = {GRUNT: MONSTER_BASE["grunt"], FIEND: MONSTER_BASE["fiend"],
            BRUTE: MONSTER_BASE["brute"], BOSS: MONSTER_BASE["boss"]}[typ]
    return base + frame


# Type parameter ROM for the RTL (one 64-bit word per type 0..3)
def type_words():
    words = []
    for typ in MONSTERS:
        p = TYPES[typ]
        k = STATES.key
        w = p.health | (p.speed << 12) | ((1 if p.ranged == A_SHOOT else 2 if p.ranged == A_FIRE else 0) << 20)
        w |= int(p.melee) << 22 | (p.range >> 10) << 23 | p.atk_mask << 28 | p.pain_chance << 34
        w |= p.melee_mult << 43 | k[(typ, "chase_a")] << 46 | k[(typ, "pain")] << 53
        words.append(w)
    return words


# 16 fireball directions, 22.5 deg apart, clockwise from +x (y points down the map)
FIRE_VEL = [(round(FIRE_SPEED * __import__("math").cos(i * __import__("math").pi / 8)),
             round(FIRE_SPEED * __import__("math").sin(i * __import__("math").pi / 8)))
            for i in range(16)]


def direction16(dx, dy):
    """Direction index 0..15 toward (dx, dy) using only compares of small multiples."""
    ax, ay = abs(dx), abs(dy)
    if ay * 5 < ax:
        sub = 0
    elif ay * 3 < ax * 2:
        sub = 1
    elif ay * 2 < ax * 3:
        sub = 2
    elif ay < ax * 5:
        sub = 3
    else:
        sub = 4
    if dx >= 0 and dy >= 0:
        return sub
    if dx < 0 and dy >= 0:
        return 8 - sub
    if dx < 0 and dy < 0:
        return 8 + sub
    return (16 - sub) & 15


def pack_actor(x, y, state, timer, health, typ, flags):
    """64-bit actor record (layout in the module docstring)."""
    return ((x & 0xFFFF) | ((y & 0xFFFF) << 16) | ((state & 127) << 32) | ((timer & 63) << 39) |
            ((health & 4095) << 45) | ((typ & 7) << 57) | ((flags & 15) << 60))


def unpack_actor(w):
    return {"x": w & 0xFFFF, "y": (w >> 16) & 0xFFFF, "state": (w >> 32) & 127,
            "timer": (w >> 39) & 63, "health": (w >> 45) & 4095, "type": (w >> 57) & 7,
            "flags": (w >> 60) & 15}
