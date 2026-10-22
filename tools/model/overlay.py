"""Bit-accurate model of the 2D overlay.

Everything is drawn with four primitives into the 320 x 240 framebuffer after walls and sprites:
    rect(x, y, w, h, color)                 solid fill
    text(x, y, scale, color, string)        8x8 font (rtl/display/font_rom.vhd), scale 1 or 2,
                                            only lit font pixels are written (transparent)
    blit(x, y, frame)                       an art frame scaled x2, texel 255 transparent,
                                            clipped to the screen
    map(x, y, cell, seen, actors)           minimap / automap: cell x cell pixels per tile
Layouts are fixed and driven by the HUD values from the game (game.Game.hud()). Numbers are
printed right-aligned in a fixed width with leading spaces, so a layout never moves.

Screens by game flow:
    TITLE, BRIEFING, SCORE, ENDING    full-screen text pages (no 3D view)
    PLAYING, PAUSED, DEAD             3D view + weapon + crosshair + status bar + message +
                                      minimap (or the automap) + PAUSED / death text + debug
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "font"))
from make_font import glyph_rows  # noqa: E402

import art  # noqa: E402
import render  # noqa: E402

W, H = 320, 240
BAR_Y = 208
C_BLACK, C_LGRAY, C_DGRAY, C_LGREEN, C_LCYAN, C_LRED, C_YELLOW, C_WHITE = 0, 7, 8, 10, 11, 12, 14, 15
C_BAR = 16 * 14 + 3          # steel ramp, dark
C_BLUE_KEY = 16 * 10 + 13
C_RED_KEY = 16 * 4 + 13
C_TITLE_BG = 16 * 4 + 2
C_BRIEF_BG = 16 * 10 + 2
C_SCORE_BG = 16 * 7 + 2
C_END_BG = 16 * 11 + 2
MAP_WALL, MAP_OPEN, MAP_DOOR, MAP_EXIT, MAP_PLAYER, MAP_DIR = C_LGRAY, C_DGRAY, C_YELLOW, C_LGREEN, C_LRED, C_YELLOW

MESSAGES = ["", "PICKED UP A HEALTH BONUS", "PICKED UP A MEDIKIT", "PICKED UP ARMOR",
            "PICKED UP BULLETS", "PICKED UP SHELLS", "YOU GOT THE SHOTGUN", "PICKED UP THE BLUE KEY",
            "PICKED UP THE RED KEY", "YOU NEED THE BLUE KEY", "YOU NEED THE RED KEY",
            "A SECRET IS REVEALED"]
BRIEFINGS = {
    1: ["THE BASE HAS GONE QUIET.", "SOLDIERS HOLD THE HALLS.", "FIND THE EXIT SWITCH",
        "IN THE BLUE ROOM."],
    2: ["THE SLIME CAVES ARE TOXIC.", "THE EXIT IS LOCKED.", "FIND THE BLUE KEY",
        "BEYOND THE CAVERN."],
    3: ["THE DARK HALLS.", "A RED KEY OPENS THE ARENA.", "THE BOSS WAITS INSIDE.",
        "END THIS."],
}


def num(v, width):
    return ("%*d" % (width, v))[-width:]


class Canvas:
    def __init__(self, image):
        self.img = image

    def put(self, x, y, c):
        if 0 <= x < W and 0 <= y < H:
            self.img[y * W + x] = c

    def rect(self, x, y, w, h, c):
        for yy in range(y, y + h):
            for xx in range(x, x + w):
                self.put(xx, yy, c)

    def text(self, x, y, scale, c, s):
        for k, ch in enumerate(s):
            rows = glyph_rows(ord(ch) & 127)
            for r in range(8):
                bits = rows[r]
                for b in range(8):
                    if bits & (0x80 >> b):
                        for dy in range(scale):
                            for dx in range(scale):
                                self.put(x + (8 * k + b) * scale + dx, y + r * scale + dy, c)

    def text_center(self, y, scale, c, s):
        self.text((W - len(s) * 8 * scale) // 2, y, scale, c, s)

    def blit(self, x, y, frame, blob, table):
        off, fw, fh = table[frame]
        for u in range(fw):
            for v in range(fh):
                t = blob[off + u * fh + v]
                if t != art.T:
                    for d in range(4):
                        self.put(x + 2 * u + (d & 1), y + 2 * v + (d >> 1), t)


def draw_map(cv, x0, y0, cell, tiles, seen, keys, px, py, cs, sn):
    for ty in range(64):
        for tx in range(64):
            if (tx, ty) not in seen:
                continue
            t = tiles[ty * 64 + tx]
            sp = (t >> 14) & 7
            if t & 15 == 0:
                c = MAP_OPEN
            elif 1 <= sp <= 3:
                c = MAP_DOOR
            elif sp == 4:
                c = MAP_EXIT
            else:
                c = MAP_WALL
            cv.rect(x0 + tx * cell, y0 + ty * cell, cell, cell, c)
    for kind, kx, ky in keys:
        if (kx, ky) in seen:
            c = C_BLUE_KEY if kind == 6 else C_RED_KEY
            cv.rect(x0 + kx * cell, y0 + ky * cell, cell, cell, c)
    cv.rect(x0 + (px >> 16) * cell, y0 + (py >> 16) * cell, cell, cell, MAP_PLAYER)
    dx, dy = (px + 2 * cs) >> 16, (py + 2 * sn) >> 16
    cv.rect(x0 + dx * cell, y0 + dy * cell, cell, cell, MAP_DIR)


def draw_overlay(image, hud, cam, tiles, seen, keys, blob, table, debug_values=(0, 0, 0, 0)):
    """Draws the overlay for the game's flow state into image (the 3D view already drawn).
    cam = (player x, player y, angle) in Q6.16 (the map marker uses the player, not the
    peek camera); keys = [(item kind 6 or 7, tile x, tile y)] of keys still on the floor."""
    cv = Canvas(image)
    flow = hud["flow"]
    if flow == 0:   # TITLE
        cv.rect(0, 0, W, H, C_TITLE_BG)
        cv.text_center(52, 2, C_YELLOW, "FIRST-PERSON")     # the title, two lines at
        cv.text_center(72, 2, C_YELLOW, "GATE ARRAY")       # scale 2 (one would be 368 px)
        cv.text_center(106, 1, C_WHITE, "A SHOOTER IN HARDWARE - NO CPU INSIDE")
        cv.text_center(184, 1, C_WHITE, "PRESS SPACE OR FIRE")
        return
    if flow == 1:   # BRIEFING
        cv.rect(0, 0, W, H, C_BRIEF_BG)
        cv.text_center(30, 2, C_YELLOW, "LEVEL %d" % hud["level"])
        for k, line in enumerate(BRIEFINGS[hud["level"]]):
            cv.text_center(80 + 14 * k, 1, C_WHITE, line)
        cv.text_center(196, 1, C_LGRAY, "PRESS SPACE OR FIRE")
        return
    if flow == 5:   # SCORE
        cv.rect(0, 0, W, H, C_SCORE_BG)
        cv.text_center(30, 2, C_YELLOW, "LEVEL %d DONE" % hud["level"])
        cv.text(64, 80, 1, C_WHITE, "KILLS   " + num(hud["kills"], 3) + " / " + num(hud["total_kills"], 3))
        cv.text(64, 96, 1, C_WHITE, "ITEMS   " + num(hud["items"], 3) + " / " + num(hud["total_items"], 3))
        cv.text(64, 112, 1, C_WHITE, "SECRETS " + num(hud["secrets"], 3) + " / " + num(hud["total_secrets"], 3))
        cv.text(64, 128, 1, C_WHITE, "TIME     " + num(hud["t_min"], 2) + ":" + "%02d" % hud["t_sec"])
        cv.text_center(196, 1, C_LGRAY, "PRESS SPACE OR FIRE")
        return
    if flow == 6:   # ENDING
        cv.rect(0, 0, W, H, C_END_BG)
        cv.text_center(60, 2, C_YELLOW, "YOU WIN")
        cv.text_center(100, 1, C_WHITE, "THE BOSS IS DEAD AND THE BASE IS QUIET.")
        cv.text_center(114, 1, C_WHITE, "THANK YOU FOR PLAYING.")
        cv.text_center(196, 1, C_LGRAY, "PRESS SPACE OR FIRE")
        return
    # PLAYING, PAUSED, DEAD: HUD over the 3D view
    px, py, angle = cam
    cs, sn = render.COS[angle], render.SIN[angle]
    if hud["automap"]:
        cv.rect(0, 0, W, BAR_Y, C_BLACK)
        draw_map(cv, 64, 8, 3, tiles, seen, keys, px, py, cs, sn)
    else:
        if flow != 4:
            cv.blit(96, 88 + hud["bob"], hud["wframe"], blob, table)
        for x, y in ((160, 118), (160, 119), (160, 121), (160, 122),
                     (158, 120), (159, 120), (161, 120), (162, 120)):
            cv.put(x, y, C_WHITE)
        cv.rect(256, 4, 64, 64, C_BLACK)
        draw_map(cv, 256, 4, 1, tiles, seen, keys, px, py, cs, sn)
    cv.rect(0, BAR_Y, W, H - BAR_Y, C_BAR)
    for x, label in ((4, "HEALTH"), (76, "ARMOR"), (148, "AMMO"), (204, "WEAPON"), (268, "KEYS")):
        cv.text(x, 211, 1, C_LGRAY, label)
    cv.text(4, 221, 2, C_YELLOW, num(hud["health"], 3) + "%")
    cv.text(76, 221, 2, C_YELLOW, num(hud["armor"], 3) + "%")
    cv.text(148, 221, 2, C_YELLOW, num(hud["ammo"], 3))
    cv.text(220, 221, 2, C_YELLOW, str(hud["weapon"]))
    cv.rect(268, 222, 12, 12, C_BLUE_KEY if hud["keys"] & 1 else C_DGRAY)
    cv.rect(286, 222, 12, 12, C_RED_KEY if hud["keys"] & 2 else C_DGRAY)
    if hud["msg"]:
        cv.text(4, 4, 1, C_YELLOW, MESSAGES[hud["msg"]])
    if flow == 3:
        cv.rect(100, 96, 120, 24, C_BLACK)
        cv.text_center(100, 2, C_WHITE, "PAUSED")
    if flow == 4:
        cv.text_center(100, 1, C_WHITE, "YOU DIED - PRESS SPACE")
    if hud["debug"]:
        labels = ["RENDER ", "SRAM   ", "LATE   ", "SPRITES"]
        for k, (lab, val) in enumerate(zip(labels, debug_values)):
            cv.text(4, 16 + 10 * k, 1, C_LCYAN, lab + " " + num(val, 7))
