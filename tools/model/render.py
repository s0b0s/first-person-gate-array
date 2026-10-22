"""Bit-accurate fixed-point model of the renderer (ray engine + column rasterizer).

This file is the specification the RTL must match bit for bit (the
testbenches compare the RTL with golden files written from it).
Only integer arithmetic; ">>" on negative numbers is an arithmetic shift (floor), exactly
like VHDL shift_right on signed. Fixed-point formats:

    position  Q6.16 unsigned (tile units)     angle  10 bits (1024 per turn, + = clockwise)
    sin/cos   Q2.16 signed                     ray    Q2.16 signed
    deltaDist Q8.16, saturated at DD_MAX      sideDist, perp  Q16.16 (perp <= Q8.16 in practice)
    lineHeight Q12.8 pixels, saturated        texture v, tex_step  Q.16 texels
    rowDist   Q8.16, saturated                z-buffer  perp >> 6 (Q6.10), saturated
    heights   integer units, 64 per tile; eye 0..127 (player floor height + eye height)

Screen: 320 x 240, horizon at row 120 (between rows 119 and 120). Rows are sampled at their
centers (y + 0.5), columns too (camera x from 2x + 1 - 320).

Stage 4 (heights): each column walks the grid front to back with a
window of rows still open (wtop..wbot, initially 0..239) and the current floor and ceiling
heights F and C (those of the camera's tile). At every boundary where the heights change
(a tile edge, or one of the 7 sub-edges inside a ramp tile), at distance d:
    lh = N_LH / d; the screen row (Q.8) of height h is  yq(h) = 120 * 256 + ((lh * (eye - h)) >> 6)
    and the first row at or below a Q.8 coordinate v is  row(v) = (v - 128 + 255) >> 8
    1. floor span    rows max(row(yq(F)), wtop) .. wbot, then wbot = min(wbot, row(yq(F)) - 1)
    2. ceiling span  rows wtop .. min(row(yq(C)) - 1, wbot), then wtop = max(wtop, row(yq(C)))
    3. if the next floor Fn > F: riser rows max(row(yq(Fn)), wtop) .. wbot (texture RISER_TEX),
       wbot = min(wbot, row(yq(Fn)) - 1)
    4. if the next ceiling Cn < C: upper wall rows wtop .. min(row(yq(Cn)) - 1, wbot) (RISER_TEX),
       wtop = max(wtop, row(yq(Cn)))
    5. F, C = Fn, Cn; record the clip entry (z, wtop, wbot); stop if wtop > wbot
At a solid wall (or a closed door) steps 1 and 2 run at the wall distance and the wall fills
the rest of the window. Every row of the column is drawn exactly once. Wall, riser and upper
textures are anchored at yq(64), so texel row = 64 - world height. With every height 0 and
64 this is exactly the stage-3 column (same wall rows, same texture coordinates).
A ramp tile rises from its floor height F (low end) by rise = (floor of the next tile in its
direction) - F, in 8 flat steps: step j (j = 0 at the low end) has floor F + (rise * j) / 8.
Its sub-edges along the ramp axis lie at (sd - dd) + ((k * dd) >> 3), k = 1..7.

Floors and ceilings: rowDist = (e * RINV[y]) >> 8 with e = eye - F (floor) or C - eye
(ceiling) and RINV[y] = (KR << 8) // dy, dy = 256 * |row - horizon| + 128 (a constant ROM).

Stage 4 effects (frame registers lmod and anim, from the game):
    light   every tile light is first offset by lmod[light_type] and clamped to 0..15
            (light_mods(): 0 steady, 1 flicker, 2 strobe, 3 glow, plus 2 for every type
            during the muzzle flash), then darkened with distance as before
    sky     a ceiling pixel whose tile is open and has bit 23 set is the sky texel
            (u = ((angle + SKYX[x]) >> 1) & 255, v = min(63, (y * 17) >> 5)), no light;
            flats[4] is the 256 x 64 sky (textures.sky())
    anim    wall texture 6 (slime) cycles through ROM slots 5, 8, 9, 10 by anim 0..3
"""

import math

W, H = 320, 240
HORIZON = 120
PLANE_Q = 43254                       # tan(FOV / 2) = 0.66 in Q.16 (FOV about 66.8 deg)
K = (W / 2) / (PLANE_Q / 65536.0)     # wall height in pixels of a 1-tile wall at distance 1
N_LH = int(round(K * (1 << 24)))      # lineHeight Q.8 = N_LH / perp_q16
LH_MAX = (1 << 20) - 1                # lineHeight saturation (4095.996 px)
M_TS = int(round(64 * 65536 / K))     # tex_step Q.16 = (perp_q16 * M_TS) >> 16
KR = int(round(K * (1 << 18)))        # rowDist Q.16 = (e * KR) / dy_q8
DD_MAX = (1 << 24) - 1                # deltaDist and rowDist saturation (256 tiles)
PERP_MIN = 1 << 8                     # 1/256 tile: never divide by a zero distance
MAX_STEPS = 128                       # DDA gives up (treated as a hit) after this many cells
LIGHT_SHIFT = 18                      # one light level darker per 4 tiles of distance
DOORS_MAX = 8
EYE_MAX = 127                         # eye height register: player floor + eye, 7 bits
RISER_TEX = 2                         # wall texture of risers and upper walls (stone)
CLIP_MAX = 16                         # clip entries kept per column (sprite clipping)
SP_RAMP = 7
RAMP_STEP = {0: (1, 0), 1: (-1, 0), 2: (0, 1), 3: (0, -1)}   # direction -> (dx, dy), toward the high end

# Span kinds
CEIL, FLOOR, WALL = 0, 1, 2

SKY_W = 256
SLIME_TEX = 6
SLIME_SLOTS = (5, 8, 9, 10)

SIN = [int(round(math.sin(2 * math.pi * a / 1024) * 65536)) for a in range(1024)]
COS = [SIN[(a + 256) & 1023] for a in range(1024)]
# Camera x per column, Q.16, floor division (Python // floors like the table generator)
CAMX = [((2 * x + 1 - W) * 65536) // W for x in range(W)]
# View angle offset of each column (1024 per turn), for the sky
SKYX = [int(round(math.atan(CAMX[x] * PLANE_Q / 65536 / 65536) * 512 / math.pi)) for x in range(W)]


def row_dy(y):
    """Q.8 distance of row y's center from the horizon line."""
    return 256 * (y - HORIZON) + 128 if y >= HORIZON else 256 * (HORIZON - 1 - y) + 128


RINV = [(KR << 8) // row_dy(y) for y in range(H)]


def div_sat(n, d, qmax):
    """Unsigned restoring division as the RTL divider does it: floor(n / d), saturated."""
    if d == 0:
        return qmax
    q = n // d
    return qmax if q > qmax else q


def wall_tex(t):
    return t & 15


def is_door(t):
    """Doors and locked doors (specials 1, 2, 3)."""
    return 1 <= ((t >> 14) & 7) <= 3


def door_orient(t):
    return (t >> 23) & 1


def tile_light(t):
    return (t >> 8) & 15


def clamp_light(v):
    return 0 if v < 0 else (15 if v > 15 else v)


def light_mods(n, flash):
    """Light offsets of the four light types for frame n (0..255) of the level clock:
    steady, flicker (hashed, about 3 frames in 8 darker by 5), strobe (16 frames dark by 8,
    16 bright), glow (a 32-frame triangle down to -7); the muzzle flash adds 2 to all."""
    f = 2 if flash else 0
    flick = -5 if ((n * 40503) >> 7) & 7 < 3 else 0
    strobe = -8 if n & 16 else 0
    g = n & 31
    glow = -((g if g < 16 else 31 - g) >> 1)
    return (f, f + flick, f + strobe, f + glow)


def light_type(t):
    return (t >> 12) & 3


def is_sky(t):
    """An open, non-door tile with bit 23 set has a sky ceiling."""
    return (t & 15) == 0 and (t >> 23) & 1 == 1


def floor_height(t):
    return ((t >> 17) & 7) * 8


def ceil_height(t):
    return 64 - ((t >> 20) & 7) * 8


def is_ramp(t):
    return ((t >> 14) & 7) == SP_RAMP


def ramp_dir(t):
    return (t >> 6) & 3


def ramp_step_height(tiles, mx, my, t, q):
    """Floor of step q of a ramp tile, q counted along +x (directions 0, 1) or +y (2, 3)."""
    d = ramp_dir(t)
    dx, dy = RAMP_STEP[d]
    rise = floor_height(tiles[((my + dy) & 63) * 64 + ((mx + dx) & 63)]) - floor_height(t)
    j = q if d in (0, 2) else 7 - q
    return floor_height(t) + (rise * j) // 8


def row_dist(y, e):
    """rowDist in Q.16 of row y for a floor or ceiling e units from the eye."""
    v = (e * RINV[y]) >> 8
    return DD_MAX if v > DD_MAX else v


class Frame:
    """Renderer registers for one frame (what the game hands the renderer)."""

    def __init__(self, px, py, angle, eye=32, doors=(), lmod=(0, 0, 0, 0), anim=0):
        self.px = px              # Q6.16
        self.py = py
        self.angle = angle & 1023
        self.eye = eye            # 0..127 units above height 0 (player floor + eye height)
        self.doors = list(doors)  # up to 8 of (tile x, tile y, open 0..64)
        self.lmod = tuple(lmod)   # light offsets by light type, -8..2 (light_mods)
        self.anim = anim & 3      # animated texture frame

    def light(self, t):
        """A tile's light after its light type's offset."""
        return clamp_light(tile_light(t) + self.lmod[light_type(t)])

    def door_open(self, mx, my):
        for x, y, o in self.doors[:DOORS_MAX]:
            if x == mx and y == my:
                return o
        return 0


class Column:
    """Span emitter for one screen column (the ray engine's back half)."""

    def __init__(self, fr, x, rx, ry):
        self.fr, self.x, self.rx, self.ry = fr, x, rx, ry
        self.wtop, self.wbot = 0, H - 1
        self.spans = []
        self.clips = []
        self.divs = []                  # every distance divided into N_LH (divider vectors)

    def closed(self):
        return self.wtop > self.wbot

    def proj(self, d):
        """lh (Q.8) at distance d, and the function giving the first row at or below height h."""
        lh = div_sat(N_LH, d, LH_MAX)
        self.divs.append(d)
        eye = self.fr.eye

        def row_of(h):
            yq = (HORIZON << 8) + ((lh * (eye - h)) >> 6)
            return (yq - 128 + 255) >> 8
        return lh, row_of

    def flats(self, row_of, F, C):
        """Steps 1 and 2: the current floor and ceiling up to this distance."""
        eye = self.fr.eye
        rf = row_of(F)
        a = max(rf, self.wtop)
        if a <= self.wbot:
            assert 0 <= eye - F <= EYE_MAX
            self.spans.append({"kind": FLOOR, "y0": a, "y1": self.wbot, "e": eye - F})
        self.wbot = min(self.wbot, rf - 1)
        rc = row_of(C)
        b = min(rc - 1, self.wbot)
        if self.wtop <= b:
            assert 0 <= C - eye <= EYE_MAX
            self.spans.append({"kind": CEIL, "y0": self.wtop, "y1": b, "e": C - eye})
        self.wtop = max(self.wtop, rc)

    def textured(self, y0, y1, d, tex_id, tex_col, light, side):
        """A wall, riser or upper-wall span, texture anchored at height 64."""
        lh, row_of = self.proj(d)
        tex_step = (d * M_TS) >> 16
        top_f = (HORIZON << 8) + ((lh * (self.fr.eye - 64)) >> 6)
        v0 = ((y0 * 256 + 128 - top_f) * tex_step) >> 8
        self.spans.append({"kind": WALL, "y0": y0, "y1": y1, "tex_id": tex_id, "tex_col": tex_col,
                           "v0": v0, "tex_step": tex_step, "light": light, "side": side})

    def edge(self, d, F, C, Fn, Cn, tex_col, light, side):
        """A height change at distance d from (F, C) to (Fn, Cn); returns True if the window
        closed. light is the effective light of the near side (for risers and upper walls)."""
        lh, row_of = self.proj(d)
        self.flats(row_of, F, C)
        if Fn > F:
            rt = row_of(Fn)
            a = max(rt, self.wtop)
            if a <= self.wbot:
                self.textured(a, self.wbot, d, RISER_TEX, tex_col, light, side)
            self.wbot = min(self.wbot, rt - 1)
        if Cn < C:
            rb = row_of(Cn)
            b = min(rb - 1, self.wbot)
            if self.wtop <= b:
                self.textured(self.wtop, b, d, RISER_TEX, tex_col, light, side)
            self.wtop = max(self.wtop, rb)
        # A closed window is stored as (z, 1, 0), so rows always fit in 8 bits
        entry = (min(d >> 6, 0xFFFF), self.wtop, self.wbot) if not self.closed() else (min(d >> 6, 0xFFFF), 1, 0)
        if len(self.clips) == CLIP_MAX:
            self.clips[-1] = entry
        else:
            self.clips.append(entry)
        return self.closed()

    def wall(self, d, F, C, tex_id, tex_col, light, side):
        """The final wall at distance d: the last floor and ceiling, then the wall."""
        lh, row_of = self.proj(d)
        self.flats(row_of, F, C)
        if self.wtop <= self.wbot:
            self.textured(self.wtop, self.wbot, d, tex_id, tex_col, light, side)
        self.wtop, self.wbot = 1, 0


def hit_tex_col(fr, d, side, rx, ry):
    """Texture column where the ray meets a boundary at distance d (mirrored on two faces)."""
    if side == 0:
        w = fr.py + ((d * ry) >> 16)
    else:
        w = fr.px + ((d * rx) >> 16)
    tc = (w & 0xFFFF) >> 10
    if (side == 0 and rx > 0) or (side == 1 and ry < 0):
        tc = 63 - tc
    return tc


def column(fr, x, tiles):
    """Ray engine for screen column x: the column's spans, clip entries and z (a dict)."""
    cs, sn = COS[fr.angle], SIN[fr.angle]
    plx = (-sn * PLANE_Q) >> 16
    ply = (cs * PLANE_Q) >> 16
    cam = CAMX[x]
    rx = cs + ((plx * cam) >> 16)
    ry = sn + ((ply * cam) >> 16)
    ddx = div_sat(1 << 32, abs(rx), DD_MAX)
    ddy = div_sat(1 << 32, abs(ry), DD_MAX)
    px, py = fr.px, fr.py
    mx, my = px >> 16, py >> 16
    fx, fy = px & 0xFFFF, py & 0xFFFF
    if rx < 0:
        sx, sdx = -1, (fx * ddx) >> 16
    else:
        sx, sdx = 1, ((65536 - fx) * ddx) >> 16
    if ry < 0:
        sy, sdy = -1, (fy * ddy) >> 16
    else:
        sy, sdy = 1, ((65536 - fy) * ddy) >> 16

    col = Column(fr, x, rx, ry)
    t = tiles[(my & 63) * 64 + (mx & 63)]
    light = fr.light(t)                 # light of the cell in front of the next boundary
    C = ceil_height(t)
    # Ramp state of the current tile: axis (0 x, 1 y) and step index q along +axis
    ramp_axis = None
    if is_ramp(t):
        ramp_axis = 0 if ramp_dir(t) in (0, 1) else 1
        q = ((fx if ramp_axis == 0 else fy) >> 13)
        F = ramp_step_height(tiles, mx & 63, my & 63, t, q)
    else:
        F = floor_height(t)
    d_enter = 0
    cells = [(mx & 63, my & 63)]   # every cell the DDA visits (minimap "seen" bits)
    steps = 0
    z = None
    while True:
        cur_mx, cur_my, cur_t = mx & 63, my & 63, t
        # Tie-break: equal side distances step in y (fixed rule, no corner flicker between frames)
        if sdx < sdy:
            sdx += ddx
            mx += sx
            side = 0
            d_next = sdx - ddx
        else:
            sdy += ddy
            my += sy
            side = 1
            d_next = sdy - ddy
        # Ramp sub-edges of the tile being left, nearest first
        if ramp_axis is not None:
            sd, dd, mv = (sdx, ddx, sx) if ramp_axis == 0 else (sdy, ddy, sy)
            if (ramp_axis == 0 and side == 0) or (ramp_axis == 1 and side == 1):
                sd -= dd                # undo this step: sd of the tile being left
            near = sd - dd              # distance of the tile's near edge on the ramp axis
            for k in range(1, 8):
                dk = near + ((k * dd) >> 3)
                if dk <= d_enter or dk >= d_next:
                    continue
                q = k if mv > 0 else 7 - k
                Fn = ramp_step_height(tiles, cur_mx, cur_my, cur_t, q)
                dl = max(dk, PERP_MIN)
                lt = clamp_light(light - min(15, dl >> LIGHT_SHIFT) - ramp_axis)
                if col.edge(dl, F, C, Fn, C, hit_tex_col(fr, dl, ramp_axis, rx, ry), lt, ramp_axis):
                    z = min(dl >> 6, 0xFFFF)
                    break
                F = Fn
            if z is not None:
                break
        steps += 1
        cells.append((mx & 63, my & 63))
        t = tiles[(my & 63) * 64 + (mx & 63)]
        dw = max(d_next, PERP_MIN)
        if steps >= MAX_STEPS or (wall_tex(t) != 0 and not (is_door(t) and door_orient(t) == side)):
            # Solid wall (or the DDA gave up)
            lw = clamp_light(light - min(15, dw >> LIGHT_SHIFT) - side)
            col.wall(dw, F, C, wall_tex(t), hit_tex_col(fr, dw, side, rx, ry), lw, side)
            z = min(dw >> 6, 0xFFFF)
            break
        if wall_tex(t) != 0:
            # A door on its axis: the door plane is half a cell in: entered at sd - dd,
            # far edge at sd
            if side == 0:
                dmid = sdx - (ddx >> 1)
                other = sdy
                along = py + ((dmid * ry) >> 16)
            else:
                dmid = sdy - (ddy >> 1)
                other = sdx
                along = px + ((dmid * rx) >> 16)
            frac = along & 0xFFFF
            opened = fr.door_open(mx & 63, my & 63) << 10      # 0..65536
            if dmid < other and frac >= opened:
                dw = max(dmid, PERP_MIN)
                lw = clamp_light(light - min(15, dw >> LIGHT_SHIFT) - side)
                col.wall(dw, F, C, wall_tex(t), (frac - opened) >> 10, lw, side)
                z = min(dw >> 6, 0xFFFF)
                break
        # An open tile (or an open door): its heights at the entry point
        if is_ramp(t):
            ramp_axis = 0 if ramp_dir(t) in (0, 1) else 1
            if side == ramp_axis:
                q = 0 if (sx if ramp_axis == 0 else sy) > 0 else 7
            else:
                a = (px + ((d_next * rx) >> 16)) if ramp_axis == 0 else (py + ((d_next * ry) >> 16))
                q = (a & 0xFFFF) >> 13
            Fn = ramp_step_height(tiles, mx & 63, my & 63, t, q)
        else:
            ramp_axis = None
            Fn = floor_height(t)
        Cn = ceil_height(t)
        if Fn != F or Cn != C:
            lt = clamp_light(light - min(15, dw >> LIGHT_SHIFT) - side)
            if col.edge(dw, F, C, Fn, Cn, hit_tex_col(fr, dw, side, rx, ry), lt, side):
                z = min(dw >> 6, 0xFFFF)
                break
        F, C = Fn, Cn
        light = fr.light(t)
        d_enter = d_next

    return {"col": x, "spans": col.spans, "clips": col.clips, "z": z, "rx": rx, "ry": ry,
            "steps": steps, "cells": cells, "edge_d": col.divs}


def wall_texture_index(tex_id, anim=0):
    """Texture ROM slot of wall texture id 1..15 (8 textures; slime animates over 4 slots)."""
    if tex_id == SLIME_TEX:
        return SLIME_SLOTS[anim & 3]
    return (tex_id - 1) & 7


def raster_spans(fr, d, tiles, walls, flats, lights, out):
    """Column rasterizer: draws every span of descriptor list d into out[y] (240 entries)."""
    for s in d["spans"]:
        if s["kind"] == WALL:
            v = s["v0"]
            for y in range(s["y0"], s["y1"] + 1):
                trow = min(v >> 16, 63)
                v += s["tex_step"]
                texel = walls[wall_texture_index(s["tex_id"], fr.anim)][s["tex_col"] * 64 + trow]
                out[y] = lights[s["light"]][texel]
        else:
            for y in range(s["y0"], s["y1"] + 1):
                rd = row_dist(y, s["e"])
                wx = fr.px + ((rd * d["rx"]) >> 16)
                wy = fr.py + ((rd * d["ry"]) >> 16)
                t = tiles[((wy >> 16) & 63) * 64 + ((wx >> 16) & 63)]
                if s["kind"] == CEIL and is_sky(t):
                    su = ((fr.angle + SKYX[d["col"]]) >> 1) & (SKY_W - 1)
                    sv = min(63, (y * 17) >> 5)
                    out[y] = flats[4][su * 64 + sv]
                    continue
                u = (wx >> 10) & 63
                vv = (wy >> 10) & 63
                if s["kind"] == FLOOR:
                    flat = (t >> 4) & 3
                elif is_ramp(t):
                    flat = 0                     # a ramp's ceil_tex holds its direction
                else:
                    flat = (t >> 6) & 3
                texel = flats[flat][vv * 64 + u]
                lvl = clamp_light(fr.light(t) - min(15, rd >> LIGHT_SHIFT))
                out[y] = lights[lvl][texel]


def render_frame(fr, tiles, walls, flats, lights, seen=None):
    """Walls, floors and ceilings: returns (image as a flat list y * 320 + x, descriptors).
    If seen is a set, every cell a ray visited is added to it."""
    image = [0] * (W * H)
    descs = []
    for x in range(W):
        d = column(fr, x, tiles)
        descs.append(d)
        if seen is not None:
            seen.update(d["cells"])
        out = [None] * H
        raster_spans(fr, d, tiles, walls, flats, lights, out)
        assert None not in out, "column %d: a row was not drawn" % x
        for y in range(H):
            image[y * W + x] = out[y]
    return image, descs
