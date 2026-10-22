"""Game palette and light table.

Palette: 256 entries of 18-bit color (6 bits per channel).
    0..15     the 16 basic colors of the stage-0 palette (text and test pages use them)
    16..255   15 ramps of 16 shades, ramp r at 16 r .. 16 r + 15, darkest first
    255       (brightest shade of ramp 15) is reserved as the sprite transparent index

Light table: LIGHT[level][index] for level 0 (darkest) .. 15 (full). Level 15 maps every index
to itself. Lower levels scale the color by (level + 1) / 16 and pick the shade of the same
ramp with the closest brightness, so hues stay put as walls fade into the dark (DOOM's
COLORMAP idea). Basic colors 0..15 pick the closest color in the whole palette.
"""

BASIC = [
    (0, 0, 0), (0, 0, 42), (0, 42, 0), (0, 42, 42),
    (42, 0, 0), (42, 0, 42), (42, 21, 0), (42, 42, 42),
    (21, 21, 21), (21, 21, 63), (21, 63, 21), (21, 63, 63),
    (63, 21, 21), (63, 21, 63), (63, 63, 21), (63, 63, 63),
]

# Ramps 1..15: (darkest, brightest) RGB666 end points
RAMPS = [
    ((2, 2, 2), (63, 63, 63)),      # 1 gray
    ((6, 3, 1), (50, 36, 22)),      # 2 brown (wood, dirt)
    ((10, 8, 4), (60, 54, 40)),     # 3 tan, sand
    ((8, 1, 1), (63, 18, 14)),      # 4 red
    ((10, 4, 0), (63, 40, 8)),      # 5 orange
    ((10, 9, 0), (63, 60, 18)),     # 6 yellow, gold
    ((1, 6, 1), (24, 63, 20)),      # 7 green
    ((4, 6, 2), (36, 44, 20)),      # 8 olive
    ((0, 6, 7), (20, 60, 58)),      # 9 teal
    ((1, 2, 9), (24, 36, 63)),      # 10 blue
    ((5, 1, 8), (48, 24, 60)),      # 11 purple
    ((9, 5, 4), (63, 46, 38)),      # 12 flesh, pink
    ((7, 3, 2), (50, 24, 16)),      # 13 brick red-brown
    ((3, 4, 6), (38, 44, 54)),      # 14 steel blue-gray
    ((5, 5, 4), (54, 52, 46)),      # 15 warm stone gray (index 255 = transparent)
]

TRANSPARENT = 255
LEVELS = 16


def ramp_index(ramp, shade):
    """Palette index of shade 0..15 of ramp 1..15."""
    return 16 * ramp + shade


def palette():
    pal = list(BASIC)
    for lo, hi in RAMPS:
        for s in range(16):
            # Slight gamma so the dark end has more steps
            t = (s / 15.0) ** 0.85
            pal.append(tuple(int(round(a + (b - a) * t)) for a, b in zip(lo, hi)))
    assert len(pal) == 256
    return pal


def brightness(c):
    r, g, b = c
    return 0.30 * r + 0.59 * g + 0.11 * b


def light_table(pal):
    table = []
    for level in range(LEVELS):
        f = (level + 1) / 16.0
        row = []
        for i, c in enumerate(pal):
            if level == LEVELS - 1:
                row.append(i)
                continue
            target = tuple(v * f for v in c)
            if i >= 16:
                ramp = i // 16
                cands = range(16 * ramp, 16 * ramp + 16)
            else:
                cands = range(256)
            best = min(cands, key=lambda j: (sum((pal[j][k] - target[k]) ** 2 for k in range(3)), j))
            row.append(best)
        table.append(row)
    return table
