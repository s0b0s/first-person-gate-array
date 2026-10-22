"""Stage-5 golden files (sound alerts and the ambush flag), written by build_assets.py.

    game5a_trace.txt  a scripted session on the directed alert map (level.level_alert(), map
                      level 10, build/level10.bin), in the game2_trace.txt format; it plays as
                      level 1. A first shot wakes only the Grunt around the corner; the Grunt
                      behind the closed door and the ambusher stay asleep; the door is opened
                      (the far Grunt is beyond sight range, so it stays asleep); a second shot
                      wakes the far Grunt through the open door; the ambusher never wakes.
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
