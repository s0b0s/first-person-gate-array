"""Stage-4 golden files (heights and ramps), written by build_assets.py.

    ray4_maps.txt    the tile maps the poses use: "M <level>" then 4096 hex tile words
    ray4_poses.txt   one pose per line: map level, px, py, angle, eye, door count, then
                     (x y open) x 8, then the effects: lmod of light types 0..3 and anim,
                     decimal
    ray4_spans.txt   per pose, per column: "C <pose> <col> <z> <spans> <clips> <rx> <ry>",
                     then one line per span "S kind y0 y1 e tex_id tex_col v0 tex_step light side"
                     (fields a kind does not use are 0) and one per clip entry "L z top bot"
    frame4_<k>.txt   the walls, floors and ceilings of pose k (240 lines of 640 hex digits)
    sprite4_cases.txt  sprite engine cases with heights: like sprite_cases.txt plus the clip
                     lists ("L <col> <n> (z top bot) x n" for every column with entries)
    game4_trace.txt  a 1,500-frame autopilot session on level 3 (stairs, a ramp, a raised hall,
                     falls, combat), in the game2_trace.txt format; level 3 plays as level 1
    game4d_trace.txt a scripted session on the directed test map (level.level_test(), map
                     level 9, build/level9.bin): steps of 16 and 24, falls, a -y ramp, the
                     headroom limit; it plays as level 1

Clip entries of a closed window are stored as (z, 1, 0) (render.Column.edge), so top and
bottom always fit in 8 bits.
"""

import build_assets as B
import golden2
import level as L
import render
import sprites

# The heights session on level 3 (see golden2.autopilot)
LEVEL3_ROUTE = [(7.5, 29.0, None), (7.5, 26.7, None), (9.5, 30.5, None), (14.6, 31.5, "use"),
                (17.5, 31.5, None), (20.5, 31.5, None), (21.5, 38.5, None), (22.5, 21.0, None),
                (22.5, 18.4, "use"), (22.5, 14.5, None), (30.5, 14.5, None), (36.5, 14.5, None),
                (41.5, 13.5, None), (38.5, 13.5, None)]
LEVEL3_FACES = {3: "e", 8: "n"}
TRACE_FRAMES = 1500


def heights_poses():
    """(map level, Frame) poses on level 3 that exercise every height case."""
    q = B.q16
    return [
        (3, render.Frame(q(7.5), q(33.5), 768)),                                # stairs ahead
        (3, render.Frame(q(12.6), q(31.5), 0, doors=[(15, 31, 64)])),           # along the ramp
        (3, render.Frame(q(7.5), q(26.6), 230, eye=24 + 32)),                   # down from the platform
        (3, render.Frame(q(22.5), q(28.5), 256, eye=16 + 32)),                  # lower ceiling ahead
        (3, render.Frame(q(36.5), q(10.5), 64, eye=24 + 32)),                   # over the pit
        (3, render.Frame(q(38.5), q(44.5), 0)),                                 # dais in the arena
        (3, render.Frame(q(16.7), q(31.5), 0, eye=5 + 32)),                     # standing on the ramp
        (3, render.Frame(q(41.5), q(13.5), 512, eye=16)),                       # ducked in the pit
        (3, render.Frame(q(7.5), q(29.02), 768, eye=8 + 32)),                   # nose on a riser
        (3, render.Frame(q(17.6), q(31.5), 512, eye=12 + 32)),                  # down the ramp
    ]


def test_map_poses():
    """Poses on the directed test map (level 9): the -y ramp seen from below (its direction
    field 3 must not select ceiling flat 3) and from the top, and the 24 step."""
    q = B.q16
    return [
        (9, render.Frame(q(17.5), q(10.5), 768)),
        (9, render.Frame(q(17.5), q(6.5), 256, eye=8 + 32)),
        (9, render.Frame(q(11.5), q(4.5), 0)),
        (9, render.Frame(q(2.6), q(10.5), 0)),                 # along the ramp chain: > 16 edges
    ]


def effect_poses():
    """Stage-4 effects: the sky over level 1's slime pit (animated slime walls) and over the
    level-3 arena during a strobe, the flickering hall and the glowing room during a muzzle
    flash (render.light_mods gives each frame's offsets)."""
    q = B.q16
    return [
        (1, render.Frame(q(36.5), q(56.5), 768, lmod=render.light_mods(5, False), anim=1)),
        (3, render.Frame(q(36.0), q(34.0), 128, lmod=render.light_mods(20, False), anim=2)),
        (3, render.Frame(q(22.5), q(24.5), 256, eye=16 + 32, lmod=render.light_mods(0, False), anim=3)),
        (3, render.Frame(q(38.5), q(16.5), 0, eye=24 + 32, lmod=render.light_mods(24, True), anim=0)),
    ]


def all_poses():
    """The stage-1 level-1 poses (flat; their images equal the stage-1 goldens but for one
    pixel), then the heights poses, the test-map poses and the effects poses."""
    lv1 = L.level1()
    return ([(1, fr) for fr in B.test_poses(lv1)] + heights_poses() + test_map_poses() +
            effect_poses())


def write_ray_goldens(golden, walls, flats, lights, preview=None):
    """Maps, poses, spans and frame images; returns (pose count, divider operand pairs)."""
    maps = {1: L.level1().tile_words(), 3: L.level3().tile_words(), 9: L.level_test().tile_words()}
    with open(golden / "ray4_maps.txt", "w", encoding="ascii", newline="\n") as f:
        for n, tiles in sorted(maps.items()):
            f.write("M %d\n" % n)
            f.write(" ".join("%06X" % t for t in tiles) + "\n")
    poses = all_poses()
    pose_lines, span_lines = [], []
    divs = set()
    for k, (m, fr) in enumerate(poses):
        doors = list(fr.doors) + [(0, 0, 0)] * (render.DOORS_MAX - len(fr.doors))
        fields = [m, fr.px, fr.py, fr.angle, fr.eye, len(fr.doors)]
        for d in doors[:render.DOORS_MAX]:
            fields += list(d)
        fields += list(fr.lmod) + [fr.anim]
        pose_lines.append(" ".join(str(v) for v in fields))
        image, descs = render.render_frame(fr, maps[m], walls, flats, lights)
        with open(golden / ("frame4_%d.txt" % k), "w", encoding="ascii", newline="\n") as f:
            f.write("\n".join("".join("%02X" % p for p in image[y * 320:(y + 1) * 320])
                              for y in range(240)) + "\n")
        if preview is not None:
            preview(k, image)
        for d in descs:
            span_lines.append("C %d %d %d %d %d %d %d" % (k, d["col"], d["z"], len(d["spans"]),
                                                       len(d["clips"]), d["rx"], d["ry"]))
            divs.add((1 << 32, abs(d["rx"])))
            divs.add((1 << 32, abs(d["ry"])))
            for s in d["spans"]:
                if s["kind"] == render.WALL:
                    span_lines.append("S %d %d %d 0 %d %d %d %d %d %d" % (
                        s["kind"], s["y0"], s["y1"], s["tex_id"], s["tex_col"], s["v0"],
                        s["tex_step"], s["light"], s["side"]))
                else:
                    span_lines.append("S %d %d %d %d 0 0 0 0 0 0" % (s["kind"], s["y0"], s["y1"], s["e"]))
            for z, top, bot in d["clips"]:
                span_lines.append("L %d %d %d" % (z, top, bot))
            divs.update((render.N_LH, dd) for dd in d["edge_d"])
    with open(golden / "ray4_poses.txt", "w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(pose_lines) + "\n")
    with open(golden / "ray4_spans.txt", "w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(span_lines) + "\n")
    return len(poses), divs


def write_sprite_cases(path, records, frames_wanted, walls, flats, lights, blob, table):
    """Sprite engine cases from the heights session: frames with sprites on raised floors and
    behind ledges; includes each column's clip list."""
    out = []
    n = 0
    for k in frames_wanted:
        r = records[k]
        if not r["sprites"]:
            continue
        cx, cy, ang, eye = r["cam"]
        fr = render.Frame(cx, cy, ang, eye, r["doors"], *r["fx"])
        base, descs = render.render_frame(fr, r["tiles"], walls, flats, lights)
        zwall = [d["z"] for d in descs]
        clips = [d["clips"] for d in descs]
        exp = list(base)
        spans, _ = sprites.draw_sprites(exp, r["sprites"], cx, cy, ang, eye, zwall, blob, table,
                                        lights, clips)
        out.append("C %d" % n)
        out.append("K %d %d %d %d" % (cx, cy, ang, eye))
        st = r["sprites"]
        out.append("P %d %s" % (len(st), " ".join("%d %d %d %d %d %d %d" % e for e in st)))
        out.append("Z " + " ".join(str(z) for z in zwall))
        for x in range(320):
            if clips[x]:
                out.append("L %d %d %s" % (x, len(clips[x]), " ".join("%d %d %d" % c for c in clips[x])))
        out.append("B")
        out.append(golden2.hex_image(base))
        out.append("E")
        out.append(golden2.hex_image(exp))
        out.append("Q %d %s" % (len(spans), " ".join("%d %d %d %d" % e for e in spans)))
        n += 1
    with open(path, "w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    return n


def clipped_scenes():
    """Hand-placed sprites on level 3 where the height windows must clip them: (name, Frame,
    [(x, y in tiles, art frame)]). Every sprite stands on the floor under its center."""
    q = B.q16
    return [
        ("pit", render.Frame(q(36.5), q(10.5), 64, eye=24 + 32), [(41.5, 13.5, 0), (42.7, 14.6, 9)]),
        ("dais", render.Frame(q(38.5), q(44.5), 0), [(51.5, 44.5, 0), (46.5, 45.5, 27), (51.0, 42.0, 18)]),
        ("lowceil", render.Frame(q(22.5), q(28.5), 256, eye=16 + 32), [(21.5, 38.5, 27), (24.5, 41.5, 18)]),
        ("platform", render.Frame(q(7.5), q(34.5), 768, eye=16), [(7.5, 26.6, 0), (5.5, 27.2, 9), (10.0, 28.5, 18)]),
        ("ramp", render.Frame(q(12.6), q(31.5), 0, doors=[(15, 31, 64)]), [(17.2, 31.5, 0), (19.5, 31.5, 27)]),
        ("stairs_duck", render.Frame(q(7.5), q(32.5), 768, eye=8), [(7.5, 27.0, 27), (8.5, 30.6, 0)]),
    ]


def write_clipped_sprite_cases(path, walls, flats, lights, blob, table):
    """Sprite cases where clipping matters, in the sprite4_cases.txt format; appends to the file.
    Returns (cases, pixels the clip windows hid in total)."""
    import game as G
    g = G.Game(levels=[L.level3(), L.level2(), L.level3()])
    tiles = g.tiles
    out = []
    hidden = 0
    with open(path, encoding="ascii") as f:
        n = sum(1 for line in f if line.startswith("C "))
    for name, fr, placed in clipped_scenes():
        st = []
        for i, (x, y, fm) in enumerate(placed):
            sx, sy = int(round(x * 1024)), int(round(y * 1024))
            light = render.tile_light(tiles[int(y) * 64 + int(x)])
            st.append((i, sx, sy, fm, light, 2, g.floor_at(sx << 6, sy << 6)))
        base, descs = render.render_frame(fr, tiles, walls, flats, lights)
        zwall = [d["z"] for d in descs]
        clips = [d["clips"] for d in descs]
        exp = list(base)
        spans, _ = sprites.draw_sprites(exp, st, fr.px, fr.py, fr.angle, fr.eye, zwall, blob, table,
                                        lights, clips)
        unclipped = list(base)
        sprites.draw_sprites(unclipped, st, fr.px, fr.py, fr.angle, fr.eye, zwall, blob, table, lights)
        hidden += sum(1 for a, b in zip(exp, unclipped) if a != b)
        out.append("C %d %s" % (n, name))
        out.append("K %d %d %d %d" % (fr.px, fr.py, fr.angle, fr.eye))
        out.append("P %d %s" % (len(st), " ".join("%d %d %d %d %d %d %d" % e for e in st)))
        out.append("Z " + " ".join(str(z) for z in zwall))
        for x in range(320):
            if clips[x]:
                out.append("L %d %d %s" % (x, len(clips[x]), " ".join("%d %d %d" % c for c in clips[x])))
        out.append("B")
        out.append(golden2.hex_image(base))
        out.append("E")
        out.append(golden2.hex_image(exp))
        out.append("Q %d %s" % (len(spans), " ".join("%d %d %d %d" % e for e in spans)))
        n += 1
    with open(path, "a", encoding="ascii", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    return len(clipped_scenes()), hidden


def directed_script():
    """The scripted session on the test map (see level.level_test)."""
    import game as G
    S = G.Snapshot
    return [(1, S()), (1, S(use=True)), (1, S(use=True)),     # title, briefing, load
            (224, S(move=1)),                                 # east: up 16, down, up 24, down
            (8, S(turn=32)),                                  # face south
            (140, S(move=1)),                                 # up 8, down the ramp, ceilings 40 / 32
            (16, S(turn=32)),                                 # face north
            (60, S(move=1, run=True))]                        # back up the ramp


def write_directed_trace(path, assets):
    lv = L.level_test()
    return golden2.write_trace(path, 0, assets, levels=[lv, lv, lv], script=directed_script())


def write_game_trace(path, assets):
    """The heights session; returns its per-frame records."""
    return golden2.write_trace(path, TRACE_FRAMES, assets, LEVEL3_ROUTE, LEVEL3_FACES,
                               [L.level3(), L.level2(), L.level3()])
