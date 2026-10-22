"""Short scripted session for the system testbench (sim/tb_shooter_top.vhd).

The whole design runs from the 12 MHz oscillator, so every frame costs 16.7 ms of simulated
time; the 1500-frame autopilot session (golden2.py) is far too long for it. This session
reaches gameplay on frame 2 and then exercises movement, turning, running, firing (hitscan
and sounds) and the automap.

write_system_trace(path, assets) writes, per frame k:
    F k <snapshot, 10 hex digits>        the input (the testbench plays it via the replay unit)
    G k <flow> <crc 8 hex> <sounds> <tint>
    E                                    then 240 lines of 640 hex digits: the frame as drawn
"""

import frame
import game as G

S = G.Snapshot

# One snapshot per frame
SESSION = [
    S(),                                # 0 title
    S(use=True),                        # 1 -> briefing
    S(use=True),                        # 2 -> level 1 loads, playing
    S(move=1),                          # 3 walk forward
    S(move=1, turn=40),                 # 4 walk and turn
    S(fire=True),                       # 5 shoot (fire edge): hitscan, sound
    S(move=1, strafe=1),                # 6 walk and strafe
    S(move=1, turn=-60, run=True),      # 7 run and turn back
    S(fire=True),                       # 8 shoot again
    S(automap=True),                    # 9 automap on
    S(move=1),                          # 10 walk with the automap
    S(automap=True, turn=20),           # 11 automap off
]


def write_system_trace(path, assets):
    g = G.Game()
    spans, zwall = [], [0xFFFF] * 320
    out = []
    flows = []
    for k, s in enumerate(SESSION):
        g.step(s, spans, zwall)
        image, spans, zwall = frame.render_game_frame(g, assets)
        out.append("F %d %010X" % (k, s.pack()))
        out.append("G %d %d %08X %d %d" % (k, g.flow, g.state_crc(), len(g.sounds), g.tint()))
        out.append("E")
        out.extend("".join("%02X" % p for p in image[y * 320:(y + 1) * 320]) for y in range(240))
        flows.append(g.flow)
    with open(path, "w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    return flows
