"""Bit-accurate model of the sprite engine.

Input: the camera (position Q6.16, angle, eye height 0..127), the sprite table from the game
(actor index, x and y in Q6.10, art frame, tile light, flags: bit 0 fullbright, bit 1 hitscan
target, floor height 0..64 under the sprite), the wall z-buffer of this frame (z = perp >> 6,
Q6.10), the clip lists of this frame (stage 4: per column, the open window (z, top, bottom)
after each height edge, nearest first) and the art (frame table + column-major texels, index
255 transparent).

Per sprite (same projection as the walls, so a 64-texel frame stands one tile tall):
    rel     = (x << 6) - cam                      Q.16 tiles
    depth   = (rx * cos + ry * sin) >> 16         distance along the view
    lateral = (-rx * sin + ry * cos) >> 16        sideways offset
    culled when depth < DEPTH_MIN (1/8 tile)
    lh      = div_sat(N_LH, depth, LH_MAX)        Q.8 pixels per tile (wall lineHeight)
    w_f, h_f = (lh * width) >> 6, (lh * height) >> 6
    center  = 160 * 256 + ((lateral * lh) >> 16), left = center - (w_f >> 1)
    bottom  = 120 * 256 + ((lh * (eye - floor)) >> 6),  top = bottom - h_f
    columns x0..x1 and rows y0..y1 by the pixel-center rule, clipped to the screen
    step    = (depth * M_TS) >> 16                texels per pixel, Q.16 (as for walls)
    z       = min(depth >> 6, 65535); light = 15 if fullbright else
              clamp(light - min(15, depth >> 18))
Sprites are drawn far to near (sort by depth, larger first; equal depths keep table order).
A column is drawn only where z < wall z, and only in the rows of the column's window at the
sprite's depth: the window of the last clip entry with entry z <= sprite z (rows 0..239 if
none). Texel 255 is skipped; u = ((x * 256 + 128 - left) * step) >> 8 and v likewise from the
top (counted from the sprite's first row, also for rows the window hides), both clamped to the
frame size.
Spans (for next frame's hitscan): (actor index, x0, x1, z) of every drawn target sprite.
"""

from render import div_sat, N_LH, LH_MAX, M_TS, LIGHT_SHIFT, COS, SIN, W, H, HORIZON

DEPTH_MIN = 8192
TRANSPARENT = 255


def project(sp, cam_x, cam_y, angle, eye, table):
    """Projection of one sprite table entry, or None when culled."""
    idx, sx, sy, frame, light, flags, floor = sp
    cs, sn = COS[angle], SIN[angle]
    rx = (sx << 6) - cam_x
    ry = (sy << 6) - cam_y
    depth = (rx * cs + ry * sn) >> 16
    lateral = (-rx * sn + ry * cs) >> 16
    if depth < DEPTH_MIN:
        return None
    lh = div_sat(N_LH, depth, LH_MAX)
    off, fw, fh = table[frame]
    w_f = (lh * fw) >> 6
    h_f = (lh * fh) >> 6
    center = 160 * 256 + ((lateral * lh) >> 16)
    left = center - (w_f >> 1)
    bottom = HORIZON * 256 + ((lh * (eye - floor)) >> 6)
    top = bottom - h_f
    x0 = (left - 128 + 255) >> 8
    x1 = ((left + w_f - 128 + 255) >> 8) - 1
    y0 = (top - 128 + 255) >> 8
    y1 = ((bottom - 128 + 255) >> 8) - 1
    x0c, x1c = max(x0, 0), min(x1, W - 1)
    y0c, y1c = max(y0, 0), min(y1, H - 1)
    if x0c > x1c or y0c > y1c:
        return None
    step = (depth * M_TS) >> 16
    if flags & 1:
        lvl = 15
    else:
        lvl = max(0, min(15, light - min(15, depth >> LIGHT_SHIFT)))
    return {"idx": idx, "frame": frame, "depth": depth, "z": min(depth >> 6, 0xFFFF),
            "left": left, "top": top, "x0": x0c, "x1": x1c, "y0": y0c, "y1": y1c,
            "step": step, "light": lvl, "target": bool(flags & 2), "off": off, "fw": fw, "fh": fh}


def window(clips, z):
    """Rows still open at depth z in one column: the last clip entry with entry z <= z."""
    top, bot = 0, H - 1
    for cz, ct, cb in clips:
        if cz > z:
            break
        top, bot = ct, cb
    return top, bot


def draw_sprites(image, sprites, cam_x, cam_y, angle, eye, zwall, art, table, lights, clips=None):
    """Draws into image (flat list, y * 320 + x); returns (spans, pixels written).
    clips: per column list of (z, top, bottom) from render.column (None: no height edges)."""
    projs = []
    for order, sp in enumerate(sprites):
        p = project(sp, cam_x, cam_y, angle, eye, table)
        if p is not None:
            projs.append((p, order))
    projs.sort(key=lambda po: (-po[0]["depth"], po[1]))
    spans = []
    written = 0
    for p, _ in projs:
        if p["target"]:
            spans.append((p["idx"], p["x0"], p["x1"], p["z"]))
        v_start = ((p["y0"] * 256 + 128 - p["top"]) * p["step"]) >> 8
        for x in range(p["x0"], p["x1"] + 1):
            if p["z"] >= zwall[x]:
                continue
            wt, wb = window(clips[x], p["z"]) if clips is not None else (0, H - 1)
            u = ((x * 256 + 128 - p["left"]) * p["step"]) >> 8
            ucol = min(u >> 16, p["fw"] - 1)
            v = v_start
            base = p["off"] + ucol * p["fh"]
            for y in range(p["y0"], p["y1"] + 1):
                vrow = min(v >> 16, p["fh"] - 1)
                v += p["step"]
                texel = art[base + vrow]
                if texel != TRANSPARENT and wt <= y <= wb:
                    image[y * W + x] = lights[p["light"]][texel]
                    written += 1
    return spans, written
