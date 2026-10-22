"""Procedural sprite art: monsters, items, fireballs and first-person weapons.

Original art, drawn from simple shaded shapes, so there are no licensing questions.
Index 255 is transparent. 61 frames, 197,632 bytes:

    0..37   monsters, 64 x 64: Grunt 0..8, Fiend 9..17, Brute 18..26, Boss 27..37
            per type: 0 stand, 1 walk A, 2 walk B, 3 attack, 4 pain, 5..7 dying, 8 corpse
            (the Boss adds 9 walk C and 10 second attack)
    38..54  items and effects, 32 x 32 (see ITEM_FRAMES)
    55..60  first-person weapons, 64 x 64 (see WEAPON_FRAMES)

Storage in SRAM (copied from flash at boot to ART_BASE = 0x40000): frames one after the
other, column-major (texel (u, v) at offset + u * height + v), so a sprite column is a run of
consecutive bytes. FRAME_TABLE gives (offset from ART_BASE, width, height) per frame.

A texel is one world unit (1/64 tile), the same scale as wall texels, so a 64 x 64 monster
frame stands one tile tall and the renderer's wall texture step works for sprites too.
"""

from palette import ramp_index, TRANSPARENT

T = TRANSPARENT
GRAY, BROWN, TAN, RED, ORANGE, YELLOW, GREEN, OLIVE, TEAL, BLUE, PURPLE, FLESH, BRICK, \
    STEEL, STONE = range(1, 16)

ITEM_FRAMES = ["health", "medikit", "armor", "bullets", "shells", "shotgun", "key1", "key2",
               "fireball_a", "fireball_b", "explosion_a", "explosion_b", "rockets",
               "launcher", "rocket", "barrel", "lamp"]
WEAPON_FRAMES = ["pistol", "pistol_fire", "shotgun", "shotgun_fire", "shotgun_pump", "launcher"]

MONSTER_BASE = {"grunt": 0, "fiend": 9, "brute": 18, "boss": 27}
ITEM_BASE = 38
WEAPON_BASE = 55
ART_BASE = 0x40000


class Canvas:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.p = [[T] * w for _ in range(h)]

    def put(self, x, y, c):
        x, y = int(x), int(y)
        if 0 <= x < self.w and 0 <= y < self.h:
            self.p[y][x] = c

    def ellipse(self, cx, cy, rx, ry, ramp, light=11, dark=4):
        """Filled ellipse shaded from light (top left) to dark (bottom right)."""
        for y in range(int(cy - ry), int(cy + ry) + 1):
            for x in range(int(cx - rx), int(cx + rx) + 1):
                dx, dy = (x - cx) / max(rx, 0.5), (y - cy) / max(ry, 0.5)
                d = dx * dx + dy * dy
                if d <= 1.0:
                    s = light - (dark if d > 0.75 else 0) - int(2 * (dx + dy))
                    self.put(x, y, ramp_index(ramp, max(1, min(15, s))))

    def rect(self, x0, y0, x1, y1, ramp, shade):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                edge = x in (x0, x1) or y in (y0, y1)
                self.put(x, y, ramp_index(ramp, max(1, shade - (3 if edge else 0))))

    def limb(self, x0, y0, x1, y1, width, ramp, shade):
        steps = int(max(abs(x1 - x0), abs(y1 - y0), 1))
        for i in range(steps + 1):
            x = x0 + (x1 - x0) * i / steps
            y = y0 + (y1 - y0) * i / steps
            self.ellipse(x, y, width / 2, width / 2, ramp, shade, 2)

    def column_major(self):
        return [self.p[v][u] for u in range(self.w) for v in range(self.h)]


def humanoid(c, body, skin, pose, size=1.0, horns=False, head_ramp=None, bulk=1.0):
    """A standing figure in a 64 x 64 frame, feet on the bottom row.

    pose: stand, walk_a, walk_b, attack, attack2, pain, die1, die2, die3, corpse.
    """
    s = size
    cx = 32
    if pose in ("die1", "die2", "die3", "corpse"):
        # Falling over: lower and wider each step, corpse flat on the ground
        k = {"die1": 0.75, "die2": 0.5, "die3": 0.3, "corpse": 0.18}[pose]
        h = 56 * s * k
        c.ellipse(cx, 63 - h / 2, 14 * s * bulk + (1 - k) * 12, h / 2 + 2, body, 8)
        c.ellipse(cx + (1 - k) * 16, 63 - h * 0.8, 6 * s, 6 * s * max(k, 0.4), head_ramp or skin, 9)
        if pose in ("die3", "corpse"):
            for i in range(6):
                c.put(cx - 10 + 4 * i, 62, ramp_index(RED, 6))
                c.put(cx - 9 + 4 * i, 63, ramp_index(RED, 4))
        return
    lean = {"pain": -3, "attack": 2, "attack2": 2}.get(pose, 0)
    legs = {"walk_a": 6, "walk_b": -6}.get(pose, 0)
    top = 63 - int(56 * s)
    # Legs
    c.limb(cx - 6 * bulk, 63 - 22 * s, cx - 6 * bulk - legs, 62, 7 * s * bulk, body, 6)
    c.limb(cx + 6 * bulk, 63 - 22 * s, cx + 6 * bulk + legs, 62, 7 * s * bulk, body, 7)
    # Torso
    c.ellipse(cx + lean, top + 30 * s, 12 * s * bulk, 16 * s, body, 10)
    # Arms
    if pose in ("attack", "attack2"):
        c.limb(cx + 10 * bulk, top + 22 * s, cx + 24, top + 26 * s, 6 * s, skin, 9)
        c.limb(cx - 10 * bulk, top + 22 * s, cx + 18, top + 30 * s, 6 * s, skin, 8)
        flash = YELLOW if pose == "attack" else ORANGE
        c.ellipse(cx + 27, top + 26 * s, 4, 4, flash, 15, 1)
    else:
        swing = 4 if pose == "walk_a" else (-4 if pose == "walk_b" else 0)
        up = -10 if pose == "pain" else 0
        c.limb(cx - 12 * bulk, top + 22 * s, cx - 15 * bulk + swing, top + 42 * s + up, 6 * s, skin, 8)
        c.limb(cx + 12 * bulk, top + 22 * s, cx + 15 * bulk - swing, top + 42 * s + up, 6 * s, skin, 9)
    # Head
    c.ellipse(cx + lean, top + 9 * s, 8 * s, 8 * s, head_ramp or skin, 11)
    for ex in (-3, 3):
        c.put(int(cx + lean + ex), int(top + 8 * s), ramp_index(RED if pose != "pain" else YELLOW, 15))
    if horns:
        c.limb(cx + lean - 6, top + 4, cx + lean - 10, top - 2, 3, TAN, 12)
        c.limb(cx + lean + 6, top + 4, cx + lean + 10, top - 2, 3, TAN, 12)


POSES = ["stand", "walk_a", "walk_b", "attack", "pain", "die1", "die2", "die3", "corpse"]


def monster_frames():
    frames = []
    for pose in POSES:  # Grunt: soldier in olive with a skin-colored head
        c = Canvas(64, 64)
        humanoid(c, OLIVE, FLESH, pose, size=0.9)
        frames.append(c)
    for pose in POSES:  # Fiend: brown imp with horns
        c = Canvas(64, 64)
        humanoid(c, BROWN, BRICK, pose, size=0.85, horns=True)
        frames.append(c)
    for pose in POSES:  # Brute: bulky pink demon
        c = Canvas(64, 64)
        humanoid(c, FLESH, FLESH, pose, size=0.8, bulk=1.5, head_ramp=RED)
        frames.append(c)
    for pose in POSES + ["walk_a", "attack2"]:  # Boss: big steel and purple
        c = Canvas(64, 64)
        humanoid(c, STEEL, PURPLE, pose, size=1.0, horns=True, bulk=1.3, head_ramp=PURPLE)
        frames.append(c)
    assert len(frames) == 38
    return frames


def item_frame(name):
    c = Canvas(32, 32)
    if name == "health":
        c.rect(10, 18, 21, 31, GRAY, 13)
        c.rect(14, 20, 17, 29, RED, 13)
        c.rect(11, 23, 20, 26, RED, 13)
    elif name == "medikit":
        c.rect(4, 14, 27, 31, GRAY, 14)
        c.rect(13, 16, 18, 29, RED, 13)
        c.rect(6, 20, 25, 25, RED, 13)
    elif name == "armor":
        c.ellipse(16, 22, 12, 9, GREEN, 12)
        c.rect(14, 15, 17, 30, GREEN, 8)
    elif name == "bullets":
        for i in range(4):
            c.rect(6 + 5 * i, 18, 9 + 5 * i, 31, YELLOW, 12)
            c.rect(6 + 5 * i, 16, 9 + 5 * i, 18, BRICK, 10)
    elif name == "shells":
        c.rect(6, 22, 25, 31, RED, 10)
        for i in range(4):
            c.rect(8 + 4 * i, 18, 10 + 4 * i, 22, YELLOW, 13)
    elif name == "shotgun":
        c.rect(2, 25, 29, 27, STEEL, 9)
        c.rect(16, 26, 29, 29, BROWN, 8)
    elif name in ("key1", "key2"):
        ramp = BLUE if name == "key1" else RED
        c.ellipse(12, 22, 5, 5, ramp, 13)
        c.rect(16, 21, 28, 23, ramp, 12)
        c.rect(24, 24, 25, 27, ramp, 12)
    elif name in ("fireball_a", "fireball_b"):
        r = 9 if name == "fireball_a" else 11
        c.ellipse(16, 16, r, r, ORANGE, 13)
        c.ellipse(16, 16, r // 2, r // 2, YELLOW, 15)
    elif name in ("explosion_a", "explosion_b"):
        r = 12 if name == "explosion_a" else 15
        c.ellipse(16, 16, r, r, RED, 12)
        c.ellipse(16, 16, r - 5, r - 5, ORANGE, 14)
        c.ellipse(16, 16, 3, 3, YELLOW, 15)
    elif name == "rockets":
        c.rect(8, 14, 13, 31, STEEL, 11)
        c.rect(18, 14, 23, 31, STEEL, 11)
        c.rect(8, 10, 13, 14, RED, 12)
        c.rect(18, 10, 23, 14, RED, 12)
    elif name == "launcher":
        c.rect(1, 22, 30, 28, OLIVE, 9)
        c.rect(10, 28, 14, 31, BROWN, 8)
    elif name == "rocket":
        c.ellipse(16, 16, 6, 6, STEEL, 12)
        c.ellipse(16, 16, 3, 3, ORANGE, 15)
    elif name == "barrel":
        c.rect(8, 8, 23, 31, GREEN, 9)
        c.rect(8, 8, 23, 10, GRAY, 10)
    elif name == "lamp":
        c.rect(15, 10, 16, 31, STEEL, 8)
        c.ellipse(16, 8, 6, 6, YELLOW, 15)
    return c


def weapon_frame(name):
    c = Canvas(64, 64)
    if name.startswith("pistol"):
        c.rect(26, 34, 37, 63, STEEL, 9)
        c.rect(28, 26, 35, 34, STEEL, 11)
        c.limb(20, 63, 30, 48, 10, FLESH, 10)
        if name == "pistol_fire":
            c.ellipse(32, 18, 9, 9, YELLOW, 15)
            c.ellipse(32, 18, 4, 4, ORANGE, 15)
    elif name.startswith("shotgun"):
        drop = 6 if name == "shotgun_pump" else 0
        c.rect(25, 24 + drop, 30, 63, STEEL, 8)
        c.rect(33, 24 + drop, 38, 63, STEEL, 9)
        c.rect(23, 44 + drop, 40, 63, BROWN, 9)
        c.limb(14, 63, 26, 52 + drop, 10, FLESH, 10)
        c.limb(50, 63, 40, 54 + drop, 10, FLESH, 9)
        if name == "shotgun_fire":
            c.ellipse(32, 15, 12, 10, YELLOW, 15)
            c.ellipse(32, 15, 6, 5, ORANGE, 15)
    elif name == "launcher":
        c.rect(20, 20, 43, 63, OLIVE, 9)
        c.ellipse(32, 22, 9, 6, GRAY, 4)
        c.limb(12, 63, 22, 50, 10, FLESH, 10)
    return c


def all_frames():
    """List of (canvas, kind) for the 61 frames in frame-id order."""
    frames = [(c, "monster") for c in monster_frames()]
    frames += [(item_frame(n), "item") for n in ITEM_FRAMES]
    frames += [(weapon_frame(n), "weapon") for n in WEAPON_FRAMES]
    assert len(frames) == 61
    return frames


def art_blob():
    """(blob bytes, frame table [(offset, width, height)]) for the flash image and the RTL."""
    blob = bytearray()
    table = []
    for c, _ in all_frames():
        table.append((len(blob), c.w, c.h))
        blob += bytes(c.column_major())
    assert len(blob) == 197632
    return bytes(blob), table
