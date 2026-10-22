"""Synthetic stress cases for the sprite engine testbench (sim/tb_sprite_engine.vhd).

The session cases in sim/golden/sprite_cases.txt (from build_assets.py) draw few sprite pixels,
so this adds cases built to reach the corners of tools/model/sprites.py: a full table of 32
entries, sprites right at the near limit (cover the whole screen, clipped on every side),
sprites behind the camera or just below DEPTH_MIN, equal depths (stable order), fullbright and
distance-darkened ones, sprites past the screen edges, and a z-buffer with near walls in some
columns. The expected images come from sprites.draw_sprites, same file format.

Usage: python tools/model/sprite_stress.py     (needs build/art.bin; run build_assets.py first)
"""

import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import art                      # noqa: E402
import golden2                  # noqa: E402
import palette as pal_mod       # noqa: E402
import render                   # noqa: E402
import sprites                  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent.parent
OUT = ROOT / "sim" / "golden" / "sprite_stress.txt"


def sprite_at(cam_x, cam_y, angle, dist, side, rnd, idx):
    """Table entry about dist tiles ahead and side tiles to the right of the camera (Q.16)."""
    cs, sn = render.COS[angle], render.SIN[angle]
    wx = cam_x + ((dist * cs - side * sn) >> 16)
    wy = cam_y + ((dist * sn + side * cs) >> 16)
    sx = max(0, min(65535, wx >> 6))
    sy = max(0, min(65535, wy >> 6))
    frame = rnd.randrange(61)
    light = rnd.randrange(16)
    flags = rnd.randrange(4)
    return (idx, sx, sy, frame, light, flags, 0)


def make_case(rnd, kind):
    cam_x = rnd.randrange(8 << 16, 56 << 16)
    cam_y = rnd.randrange(8 << 16, 56 << 16)
    angle = rnd.randrange(1024)
    eye = rnd.randrange(65)
    table = []
    if kind == "full":
        for i in range(32):
            dist = rnd.randrange(1 << 15, 12 << 16)
            side = rnd.randrange(-(6 << 16), 6 << 16)
            table.append(sprite_at(cam_x, cam_y, angle, dist, side, rnd, i))
    elif kind == "near":
        # At and around the near limit, plus some behind the camera
        for i, dist in enumerate((8192, 8300, 9000, 12000, 6000, -40000, 20000)):
            side = rnd.randrange(-(1 << 14), 1 << 14)
            table.append(sprite_at(cam_x, cam_y, angle, dist, side, rnd, i))
    elif kind == "ties":
        # Several entries at one spot: equal depths keep table order
        e = sprite_at(cam_x, cam_y, angle, 3 << 16, 0, rnd, 0)
        for i in range(6):
            table.append((i, e[1], e[2], rnd.randrange(61), rnd.randrange(16), rnd.randrange(4), 0))
    elif kind == "edges":
        # Past the left and right edges and far away (darkened, tiny)
        for i in range(12):
            dist = rnd.choice((1 << 16, 2 << 16, 20 << 16, 40 << 16))
            side = rnd.choice((-1, 1)) * rnd.randrange(dist // 2, dist * 2 + 1)
            table.append(sprite_at(cam_x, cam_y, angle, dist, side, rnd, i))
    else:
        table = []
    # Wall z: far everywhere, near walls in a few column ranges
    zwall = [rnd.randrange(30000, 65536) for _ in range(320)]
    for _ in range(4):
        a = rnd.randrange(320)
        b = min(320, a + rnd.randrange(1, 60))
        z = rnd.randrange(100, 4000)
        for x in range(a, b):
            zwall[x] = z
    base = [(x * 7 + y * 3) & 0xFF for y in range(240) for x in range(320)]
    return cam_x, cam_y, angle, eye, table, zwall, base


def main():
    pal = pal_mod.palette()
    lights = pal_mod.light_table(pal)
    blob, ftable = art.art_blob()
    rnd = random.Random(424)
    cases = []
    for kind in ("full", "near", "ties", "edges", "full", "near", "empty"):
        cx, cy, ang, eye, st, zw, base = make_case(rnd, kind)
        exp = list(base)
        spans, written = sprites.draw_sprites(exp, st, cx, cy, ang, eye, zw, blob, ftable, lights)
        print("%-5s sprites %2d spans %2d pixels %d" % (kind, len(st), len(spans), written))
        cases.append((cx, cy, ang, eye, st, zw, base, exp, spans))
    golden2.write_sprite_cases(OUT, cases)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
