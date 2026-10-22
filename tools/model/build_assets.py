"""Build every generated asset and golden file from the Python model (single source of truth).

    python tools/model/build_assets.py            assets, VHDL, golden vectors
    python tools/model/build_assets.py --preview  also preview PNGs in build/preview/

Outputs:
    rtl/pkg/palette_pkg.vhd        game palette (power-on palette RAM contents)
    rtl/pkg/render_pkg.vhd         renderer constants, sin and camera-x tables
    rtl/pkg/map_init_pkg.vhd       level 1 tile words (map BRAM power-on contents)
    rtl/render/wall_rom.vhd        8 wall textures, column-major, 32 KB
    rtl/render/flat_rom.vhd        4 floor/ceiling flats, row-major, 16 KB
    rtl/render/light_rom.vhd       light table, 16 levels x 256 indices, 4 KB
    assets/levels/level1.txt       readable picture of level 1
    build/level1.bin               level 1 item for the flash image
    sim/golden/divider.txt         divider operands and results (n d q)
    sim/golden/ray4_*.txt, frame4_<k>.txt   renderer poses, spans and frames (golden4.py)
    sim/golden/game_trace.txt      frozen stage-1 trace (game_seq.vhd), not regenerated
    sim/golden/game2_trace.txt, game4_trace.txt, game4d_trace.txt, sprite*, overlay_cases,
    frame_cases, mixer_case, system_trace   (golden2.py, golden4.py, system_session.py)
"""

import struct
import sys
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))

import palette as pal_mod  # noqa: E402
import textures  # noqa: E402
import level as level_mod  # noqa: E402
import render  # noqa: E402
import game as game_mod  # noqa: E402
import export  # noqa: E402
import actors  # noqa: E402
import art  # noqa: E402
import frame  # noqa: E402
import golden2  # noqa: E402
import overlay  # noqa: E402
import sprites  # noqa: E402
import system_session  # noqa: E402
import golden4  # noqa: E402
import golden5  # noqa: E402

GOLDEN = ROOT / "sim" / "golden"


def write_png(path, w, h, indices, pal):
    rgb = [tuple(v * 255 // 63 for v in c) for c in pal]
    raw = b""
    for y in range(h):
        raw += b"\x00" + b"".join(bytes(rgb[i]) for i in indices[y * w:(y + 1) * w])

    def chunk(kind, payload):
        c = struct.pack(">I", len(payload)) + kind + payload
        return c + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_bytes(png)


def q16(v):
    return int(round(v * 65536))


def test_poses(lv):
    sx, sy, sa = lv.start
    return [
        render.Frame(q16(sx), q16(sy), sa),                                  # 0 start
        render.Frame(q16(sx), q16(sy), 200),                                 # 1 turned
        render.Frame(q16(13.5), q16(8.5), 0, doors=[(16, 8, 32)]),           # 2 door half open
        render.Frame(q16(35.5), q16(30.5), 300),                             # 3 big hall
        render.Frame(q16(35.5), q16(30.5), 300, eye=16),                     # 4 ducked
        render.Frame(q16(4.26), q16(6.0), 512),                              # 5 wall close-up
        render.Frame(q16(10.0), q16(10.0), 128),                             # 6 corners, 45 deg
        render.Frame(q16(20.5), q16(8.5), 512, doors=[(16, 8, 64), (33, 16, 10)]),  # 7 open door
        # 8: exactly on a pillar corner looking up-left: every column starts with
        # sideDistX == sideDistY == 0, so the DDA tie-break decides whether the ray
        # hits the pillar at once (x first) or slides past it (y first, the rule)
        render.Frame(q16(31.0), q16(33.0), 640),
    ]


def text_strings():
    """(VHDL name, text) of every fixed overlay string, in model order."""
    out = [("MSG_%d" % i, m) for i, m in enumerate(overlay.MESSAGES) if m]
    for lvl, lines in overlay.BRIEFINGS.items():
        out += [("BRIEF_%d_%d" % (lvl, k), t) for k, t in enumerate(lines)]
    out += [("TITLE_0", "FIRST-PERSON"), ("TITLE_1", "GATE ARRAY"),
            ("TITLE_2", "A SHOOTER IN HARDWARE - NO CPU INSIDE"), ("PRESS", "PRESS SPACE OR FIRE"),
            ("END_0", "YOU WIN"), ("END_1", "THE BOSS IS DEAD AND THE BASE IS QUIET."),
            ("END_2", "THANK YOU FOR PLAYING."), ("PAUSED", "PAUSED"),
            ("DIED", "YOU DIED - PRESS SPACE")]
    return out


def type_rows():
    rows = []
    k = actors.STATES.key
    for typ in actors.MONSTERS:
        p = actors.TYPES[typ]
        ranged = 1 if p.ranged == actors.A_SHOOT else (2 if p.ranged == actors.A_FIRE else 0)
        rows.append([p.health, p.speed, ranged, int(p.melee), p.range >> 10, p.atk_mask,
                     p.pain_chance, p.melee_mult, k[(typ, "chase_a")], k[(typ, "pain")],
                     k[(typ, "aim")], k[(typ, "melee")], k[(typ, "die1")], k[(typ, "stand")]])
    return rows


def stage2_goldens(assets, pal, preview, records4=()):
    """Game trace, sprite, overlay and mixer golden files (tools/model/golden2.py)."""
    walls, flats, lights, blob, table = assets
    records = golden2.write_trace(GOLDEN / "game2_trace.txt", 1500, assets)
    # Sprite cases: session frames with several sprites on screen
    cases = []
    for k in (290, 440, 700, 760, 1000, 1330):
        r = records[k]
        if r["flow"] != game_mod.PLAYING:
            continue
        cx, cy, ang, eye = r["cam"]
        fr = render.Frame(cx, cy, ang, eye, r["doors"], *r["fx"])
        base, descs = render.render_frame(fr, r["tiles"], walls, flats, lights)
        zwall = [d["z"] for d in descs]
        exp = list(base)
        spans, _ = sprites.draw_sprites(exp, r["sprites"], cx, cy, ang, eye, zwall, blob, table, lights)
        cases.append((cx, cy, ang, eye, r["sprites"], zwall, base, exp, spans))
    golden2.write_sprite_cases(GOLDEN / "sprite_cases.txt", cases)
    # Overlay cases: every screen and HUD state
    ocases = []

    def add(name, r, hud_changes, dbg=(0, 0, 0, 0)):
        hud = dict(r["hud"])
        hud.update(hud_changes)
        cx, cy, ang, eye = r["cam"]
        if hud["flow"] in frame.TEXT_FLOWS:
            base = [0] * (320 * 240)
        else:
            fr = render.Frame(cx, cy, ang, eye, r["doors"], *r["fx"])
            base, descs = render.render_frame(fr, r["tiles"], walls, flats, lights)
            sprites.draw_sprites(base, r["sprites"], cx, cy, ang, eye, [d["z"] for d in descs],
                                 blob, table, lights)
        exp = list(base)
        overlay.draw_overlay(exp, hud, r["player"], r["tiles"], r["seen"], r["keys"], blob, table, dbg)
        ocases.append((name, hud, r["player"][0], r["player"][1], r["player"][2], r["tiles"],
                       r["seen"], r["keys"], dbg, base, exp))
        if preview:
            write_png(ROOT / "build" / "preview" / ("overlay_%s.png" % name), 320, 240, exp, pal)

    add("title", records[0], {})
    add("briefing", records[40], {})
    add("playing", records[700], {})
    add("message", records[1000], {})
    add("automap", records[1000], {"automap": True})
    add("paused", records[760], {"flow": game_mod.PAUSED})
    add("dead", records[760], {"flow": game_mod.DEAD})
    add("debug", records[440], {"debug": True}, (177657, 33012, 2, 5))
    add("keys", records[700], {"keys": 3, "health": 200, "armor": 155, "ammo": 7, "weapon": 2})
    # Key markers: no key lies in a seen cell during the session, so place them by hand (the
    # hardware has one blue and one red slot): both keys on seen cells (minimap and automap),
    # then the red key on an unseen cell, where it must not show
    seen_cells = sorted(records[1000]["seen"])
    unseen = [(x, y) for y in range(64) for x in range(64) if (x, y) not in records[1000]["seen"]]
    blue = (actors.I_KEY1,) + seen_cells[len(seen_cells) // 3]
    keyrec = dict(records[1000], keys=[blue, (actors.I_KEY2,) + seen_cells[2 * len(seen_cells) // 3]])
    add("keymarks", keyrec, {})
    add("keymarks_automap", keyrec, {"automap": True})
    add("keymarks_hidden", dict(records[1000], keys=[blue, (actors.I_KEY2,) + unseen[0]]), {})
    score = [r for r in records if r["flow"] == game_mod.SCORE][0]
    add("score", score, {})
    add("ending", score, {"flow": game_mod.ENDING})
    golden2.write_overlay_cases(GOLDEN / "overlay_cases.txt", ocases)
    # Frame cases: the whole stage-2 renderer. The first two playing frames
    # after the level 1 load run back to back (the seen set grows); the
    # later ones start from a cleared seen set, as after a level load.
    fcases = []
    seen = set()

    def add_frame(name, clear, r, dbg=(0, 0, 0, 0)):
        if clear:
            seen.clear()
        hud = r["hud"]
        cx, cy, ang, eye = r["cam"]
        spans = []
        if hud["flow"] in frame.TEXT_FLOWS:
            image = [0] * (320 * 240)
        else:
            fr = render.Frame(cx, cy, ang, eye, r["doors"], *r["fx"])
            image, descs = render.render_frame(fr, r["tiles"], walls, flats, lights, seen)
            spans, _ = sprites.draw_sprites(image, r["sprites"], cx, cy, ang, eye,
                                            [d["z"] for d in descs], blob, table, lights,
                                            [d["clips"] for d in descs])
        overlay.draw_overlay(image, hud, r["player"], r["tiles"], seen, r["keys"], blob, table, dbg)
        fcases.append((name, clear, r, dbg, image, spans))

    first = [k for k, r in enumerate(records) if r["flow"] == game_mod.PLAYING][0]
    add_frame("briefing", 1, records[first - 1])
    add_frame("first", 1, records[first])
    add_frame("second", 0, records[first + 1])
    add_frame("sprites", 1, records[700])
    debug_rec = dict(records[440])
    debug_rec["hud"] = dict(debug_rec["hud"], debug=True)
    add_frame("debug", 1, debug_rec, (177657, 33012, 2, 5))
    if fcases[1][4] != records[first]["image"]:
        raise SystemExit("frame case 'first' differs from the session frame")
    # Stage 4: two frames of the heights session (level 3), each after a seen clear
    for name, k in (("stairs", 120), ("ramp_hall", 520)):
        if k < len(records4):
            add_frame(name, 1, records4[k])
    golden2.write_frame_cases(GOLDEN / "frame_cases.txt", fcases)
    golden2.write_mixer_case(GOLDEN / "mixer_case.txt")
    return len(records), len(cases), len(ocases)


def main():
    preview = "--preview" in sys.argv
    pal = pal_mod.palette()
    lights = pal_mod.light_table(pal)
    walls = textures.wall_textures()
    flats = textures.flat_textures()
    blob, table = art.art_blob()
    levels = [f() for f in level_mod.LEVELS]
    lv = levels[0]
    tiles = lv.tile_words()

    for l in levels:
        l.write_ascii(ROOT / "assets" / "levels" / ("level%d.txt" % l.number))
        (ROOT / "build").mkdir(exist_ok=True)
        (ROOT / "build" / ("level%d.bin" % l.number)).write_bytes(l.binary())
    (ROOT / "build" / "art.bin").write_bytes(blob)
    export.palette_pkg(ROOT / "rtl" / "pkg" / "palette_pkg.vhd", pal)
    export.render_pkg(ROOT / "rtl" / "pkg" / "render_pkg.vhd")
    export.map_init_pkg(ROOT / "rtl" / "pkg" / "map_init_pkg.vhd", tiles, lv.start)
    export.game_tables_pkg(ROOT / "rtl" / "pkg" / "game_tables_pkg.vhd",
                           [actors.state_word(r) for r in actors.STATES.rows], type_rows(),
                           actors.FIRE_VEL, game_mod.SOUND_PRIORITY, table, actors.STATES.names)
    export.text_pkg(ROOT / "rtl" / "pkg" / "text_pkg.vhd", text_strings())
    # Two ROMs, not one 11-slot ROM on a 16-bit address: Vivado builds the whole 64 K
    # address space of the latter (16 BRAM36 instead of 8 + 3)
    export.rom_entity(ROOT / "rtl" / "render" / "wall_rom.vhd", "wall_rom",
                      """Wall textures 1..8 (ROM slots 0..7): 64 x 64 palette indices,
                      column-major. Address = slot(14:12) & u(11:6) & v(5:0).""",
                      8 * 4096, [p for t in walls[:8] for p in t], 15)
    export.rom_entity(ROOT / "rtl" / "render" / "anim_rom.vhd", "anim_rom",
                      """Animation frames 1..3 of the slime wall (ROM slots 8..10):
                      64 x 64 palette indices, column-major.
                      Address = (slot - 8)(13:12) & u(11:6) & v(5:0).""",
                      3 * 4096, [p for t in walls[8:] for p in t], 14)
    export.rom_entity(ROOT / "rtl" / "render" / "flat_rom.vhd", "flat_rom",
                      """Floor and ceiling flats: 4 of 64 x 64 palette indices,
                      row-major. Address = flat(13:12) & v(11:6) & u(5:0).""",
                      4 * 4096, [p for t in flats[:4] for p in t], 14)
    export.rom_entity(ROOT / "rtl" / "render" / "sky_rom.vhd", "sky_rom",
                      """Sky: 256 x 64 palette indices, column-major, drawn
                      without light. Address = u(13:6) & v(5:0).""",
                      len(flats[4]), flats[4], 14)
    export.rom_entity(ROOT / "rtl" / "render" / "light_rom.vhd", "light_rom",
                      """Light table: palette index darkened to light level
                      0..15 (15 = unchanged). Address = level(11:8) & index(7:0).""",
                      4096, [i for row in lights for i in row], 12)

    # Renderer goldens: ray4_*.txt and frame4_*.txt (golden4.py); the first nine poses are the
    # stage-1 level-1 poses (frame4_0.txt is the first frame tb_game_top expects).
    n_poses, divs = golden4.write_ray_goldens(
        GOLDEN, walls, flats, lights,
        (lambda k, image: write_png(ROOT / "build" / "preview" / ("frame4_%d.png" % k),
                                    render.W, render.H, image, pal)) if preview else None)
    qmax = (1 << 24) - 1
    edge = [(0, 1), (1, 1), (5, 0), ((1 << 33) - 1, 1), ((1 << 33) - 1, (1 << 24) - 1),
            (1 << 32, 256), (1 << 32, 257), (1 << 32, 65536), (12345, 12346), (1 << 24, 1),
            ((1 << 24) - 1, 1), (render.N_LH, 1), (render.N_LH, render.PERP_MIN)]
    vecs = sorted((n, d, render.div_sat(n, d, qmax)) for n, d in divs | set(edge))
    export.write(GOLDEN / "divider.txt", "\n".join("%d %d %d" % v for v in vecs) + "\n")
    assets = (walls, flats, lights, blob, table)
    records4 = golden4.write_game_trace(GOLDEN / "game4_trace.txt", assets)
    golden4.write_directed_trace(GOLDEN / "game4d_trace.txt", assets)
    (ROOT / "build" / "level9.bin").write_bytes(level_mod.level_test().binary())
    golden5.write_alert_trace(GOLDEN / "game5a_trace.txt", assets)
    (ROOT / "build" / "level10.bin").write_bytes(level_mod.level_alert().binary())
    n_sprite4 = golden4.write_sprite_cases(GOLDEN / "sprite4_cases.txt", records4,
                                           (100, 130, 400, 560, 700, 900, 1100, 1300),
                                           walls, flats, lights, blob, table)
    n_clip, hidden = golden4.write_clipped_sprite_cases(GOLDEN / "sprite4_cases.txt", walls, flats,
                                                        lights, blob, table)
    if hidden == 0:
        raise SystemExit("the clipped sprite cases hide no pixel")
    n_sprite4 += n_clip
    # sim/golden/game_trace.txt is the frozen stage-1 trace of rtl/game/game_seq.vhd; the
    # stage-2 game core uses game2_trace.txt, stage 4 also game4_trace.txt
    n_frames, n_sprite, n_overlay = stage2_goldens(assets, pal, preview, records4)
    system_session.write_system_trace(GOLDEN / "system_trace.txt", assets)
    print("built assets: %d golden poses, %d divider vectors, %d game frames, %d sprite cases "
          "(+%d with heights), %d overlay cases" % (n_poses, len(vecs), n_frames, n_sprite,
                                                     n_sprite4, n_overlay))


if __name__ == "__main__":
    main()
