"""Golden files for sound alerts and the ambush flag, written by build_assets.py.

game5a_trace.txt  scripted session on the directed alert map (level.level_alert(), map
                  level 10, build/level10.bin), game2_trace.txt format, plays as level 1.
                  Shot 1 wakes only the Grunt around the corner (not the one behind the
                  closed door, not the ambusher); the door opens (the far Grunt is out of
                  sight range); shot 2 wakes the far Grunt; the ambusher never wakes.
"""

import game as G
import golden2
import level as L

S = G.Snapshot


def alert_script():
    return [(1, S()), (1, S(use=True)), (1, S(use=True)),     # title, briefing, load
            (1, S(fire=True)),                                # shot 1
            (30, S()),
            (8, S(turn=32)),                                  # face south
            (60, S(move=1)),                                  # to the closed door
            (1, S(use=True)),                                 # open it
            (40, S()),
            (1, S(fire=True)),                                # shot 2, through the open door
            (20, S())]


def alert_frames():
    return sum(n for n, _ in alert_script())


def write_alert_trace(path, assets):
    lv = L.level_alert()
    return golden2.write_trace(path, 0, assets, levels=[lv, lv, lv], script=alert_script())
