"""Procedural textures (original art, no licensing questions).

Every texture is 64 x 64 palette indices, generated from integer hashes so the output is the
same on every machine and Python version.

Wall textures (tile wall_tex 1..8; stage 1 uses 8 of the planned 12):
    1 brick    2 stone blocks    3 wood planks    4 metal panels
    5 tech panel with lights     6 green slime stone    7 blue tiles    8 door
    ROM slots 8..10 (stage 4): slime frames 1..3; texture 6 cycles through slots
    5, 8, 9, 10 (render.wall_texture_index), the drips sliding down 4 rows per frame
Flats (floor_tex / ceil_tex 0..3):
    0 floor tiles    1 dirt and gravel    2 ceiling panels with lamps    3 wood ceiling
Sky (stage 4): 256 x 64, column-major (u * 64 + v), drawn without light over tiles marked
as sky; u follows the view angle (two repeats per turn), v the screen row.

Storage (what the RTL ROMs expect):
    walls column-major: texel (u, v) at u * 64 + v  (the rasterizer walks down a column)
    flats row-major:    texel (u, v) at v * 64 + u
"""

from palette import ramp_index

SIZE = 64
GRAY, BROWN, TAN, RED, ORANGE, YELLOW, GREEN, OLIVE, TEAL, BLUE, PURPLE, FLESH, BRICK, \
    STEEL, STONE = range(1, 16)


def hash2(x, y, seed):
    """Deterministic 0..65535 noise from integer coordinates."""
    h = (x * 374761393 + y * 668265263 + seed * 2246822519) & 0xFFFFFFFF
    h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
    return (h ^ (h >> 16)) & 0xFFFF


def shade(ramp, s):
    return ramp_index(ramp, max(0, min(15, int(s))))


def noise(x, y, seed, amount):
    return (hash2(x, y, seed) * (2 * amount + 1)) // 65536 - amount


def brick():
    t = [[0] * SIZE for _ in range(SIZE)]
    for v in range(SIZE):
        row = v // 16
        for u in range(SIZE):
            uu = (u + (16 if row % 2 else 0)) % SIZE
            mortar = (v % 16 in (0, 15)) or (uu % 32 in (0, 31))
            if mortar:
                t[v][u] = shade(STONE, 6 + noise(u, v, 1, 1))
            else:
                b = 9 + noise(uu // 32, row, 2, 2) + noise(u, v, 3, 1)
                if v % 16 == 1:
                    b += 2
                t[v][u] = shade(BRICK, b)
    return t


def stone():
    t = [[0] * SIZE for _ in range(SIZE)]
    for v in range(SIZE):
        for u in range(SIZE):
            bx, by = u // 32, v // 21
            edge = (u % 32 in (0, 31)) or (v % 21 == 0)
            b = 9 + noise(bx, by, 5, 2) + noise(u, v, 6, 2)
            if edge:
                b = 4 + noise(u, v, 7, 1)
            elif hash2(u // 3, v // 3, 8) < 1200:
                b -= 4  # cracks and pits
            t[v][u] = shade(GRAY, b)
    return t


def wood():
    t = [[0] * SIZE for _ in range(SIZE)]
    for v in range(SIZE):
        for u in range(SIZE):
            plank = u // 16
            seam = u % 16 == 0
            grain = noise(plank, v // 2, 9, 1) + (2 if (u * 7 + v // 3 + plank * 5) % 11 == 0 else 0)
            b = 3 if seam else 8 + noise(plank, 0, 10, 2) + grain
            if (v + plank * 23) % 64 == 30 and not seam:
                b = 4  # plank end
            t[v][u] = shade(BROWN, b)
    return t


def metal():
    t = [[0] * SIZE for _ in range(SIZE)]
    for v in range(SIZE):
        for u in range(SIZE):
            seam = (u % 32 in (0, 31)) or (v % 32 in (0, 31))
            rivet = (u % 32 in (3, 28)) and (v % 32 in (3, 28))
            b = 9 + noise(u, v, 11, 1) + (u % 32) // 16
            if seam:
                b = 4
            if rivet:
                b = 14
            t[v][u] = shade(STEEL, b)
    return t


def tech():
    t = metal()
    for v in range(SIZE):
        for u in range(SIZE):
            if 12 <= u < 52 and 20 <= v < 44:
                b = 3 + noise(u, v, 12, 1)
                t[v][u] = shade(STEEL, b)
                if v in (26, 32, 38) and 16 <= u < 48 and (u // 4) % 2 == 0:
                    t[v][u] = shade(GREEN, 13 + noise(u, v, 13, 2))
    return t


def slime(phase=0):
    """Stone with green slime dripping down; phase 1..3 slides the drips down 4 rows each
    (phase 0 is the stage-1 texture)."""
    t = stone()
    for v in range(SIZE):
        for u in range(SIZE):
            vv = (v - 4 * phase) % SIZE
            drip = (vv < 12 + (hash2(u // 4, 0, 14) % 30))
            if drip:
                t[v][u] = shade(GREEN, 7 + noise(u, vv, 15, 3))
    return t


def blue_tiles():
    t = [[0] * SIZE for _ in range(SIZE)]
    for v in range(SIZE):
        for u in range(SIZE):
            grout = (u % 16 == 0) or (v % 16 == 0)
            b = 4 if grout else 9 + noise(u // 16, v // 16, 16, 2) + noise(u, v, 17, 1)
            t[v][u] = shade(BLUE if not grout else GRAY, b if not grout else 6)
    return t


def door():
    t = [[0] * SIZE for _ in range(SIZE)]
    for v in range(SIZE):
        for u in range(SIZE):
            frame = u < 4 or u >= 60 or v < 4 or v >= 60
            b = 10 + noise(u, v, 18, 1)
            ramp = STEEL
            if frame:
                b = 5
            elif 8 <= u < 56 and v % 12 == 6:
                b = 6  # horizontal ribs
            if 50 <= u < 54 and 28 <= v < 36:
                ramp, b = YELLOW, 12  # handle
            t[v][u] = shade(ramp, b)
    return t


def floor_tiles():
    t = [[0] * SIZE for _ in range(SIZE)]
    for v in range(SIZE):
        for u in range(SIZE):
            checker = ((u // 32) + (v // 32)) % 2
            grout = (u % 32 == 0) or (v % 32 == 0)
            b = 3 if grout else (8 if checker else 6) + noise(u, v, 19, 1)
            t[v][u] = shade(TAN if checker else STONE, b)
    return t


def dirt():
    t = [[0] * SIZE for _ in range(SIZE)]
    for v in range(SIZE):
        for u in range(SIZE):
            b = 6 + noise(u, v, 20, 2) + noise(u // 4, v // 4, 21, 2)
            t[v][u] = shade(BROWN, b)
    return t


def ceiling_panels():
    t = [[0] * SIZE for _ in range(SIZE)]
    for v in range(SIZE):
        for u in range(SIZE):
            seam = (u % 32 == 0) or (v % 32 == 0)
            lamp = 12 <= u % 32 < 20 and 12 <= v % 32 < 20
            if lamp:
                t[v][u] = shade(YELLOW, 15)
            else:
                t[v][u] = shade(GRAY, 4 if seam else 8 + noise(u, v, 22, 1))
    return t


def wood_ceiling():
    t = wood()
    # Rotate so the boards run the other way from the walls
    return [[t[u][v] for u in range(SIZE)] for v in range(SIZE)]


WALLS = [brick, stone, wood, metal, tech, slime, blue_tiles, door]
FLATS = [floor_tiles, dirt, ceiling_panels, wood_ceiling]


SKY_W, SKY_H = 256, 64


def sky():
    """256 x 64 sky: a blue gradient, soft clouds, distant mountains along the bottom."""
    t = [[0] * SKY_W for _ in range(SKY_H)]
    for u in range(SKY_W):
        # Mountain ridge height from two octaves of hashed noise, smoothed over 8 columns
        ridge = 0
        for k in range(-4, 4):
            uu = (u + k) % SKY_W
            ridge += hash2(uu // 16, 0, 41) % 12 + hash2(uu // 5, 0, 42) % 5
        ridge = 46 + ridge // 8 // 2
        for v in range(SKY_H):
            if v >= ridge:
                t[v][u] = shade(PURPLE, 3 + noise(u, v, 43, 1))
                continue
            level = 2 + (v * 9) // SKY_H                     # darker at the top
            cloud = hash2(u // 8, v // 4, 44) % 100 + hash2(u // 3, v // 2, 45) % 40
            if cloud > 118 and v < 40:
                t[v][u] = shade(GRAY, 12 + noise(u, v, 46, 2))
            else:
                t[v][u] = shade(BLUE, level + noise(u, v, 47, 1))
    return [t[v][u] for u in range(SKY_W) for v in range(SKY_H)]


def wall_textures():
    """List of 11 textures, each a flat list in column-major order (u * 64 + v): the 8 wall
    textures (ROM slots 0..7), then slime frames 1..3 (slots 8..10)."""
    out = []
    for f in WALLS + [lambda: slime(1), lambda: slime(2), lambda: slime(3)]:
        t = f()
        out.append([t[v][u] for u in range(SIZE) for v in range(SIZE)])
    return out


def flat_textures():
    """List of 4 flats, each a flat list in row-major order (v * 64 + u), then the sky as a
    5th entry (256 x 64, column-major; render.raster_spans reads flats[4])."""
    out = []
    for f in FLATS:
        t = f()
        out.append([t[v][u] for v in range(SIZE) for u in range(SIZE)])
    out.append(sky())
    return out
