"""A whole frame as the hardware draws it: walls (render.py), then sprites (sprites.py), then
the 2D overlay (overlay.py), from the state the game model hands to the renderer.

render_game_frame(game, assets) returns (image, spans, zwall); spans and zwall feed the next
frame's game.step() (hitscan aims at what the player saw).
"""

import golden2
import overlay
import render
import sprites

TEXT_FLOWS = (0, 1, 5, 6)     # TITLE, BRIEFING, SCORE, ENDING: no 3D view


def render_game_frame(game, assets, debug_values=(0, 0, 0, 0)):
    walls, flats, lights, blob, table = assets
    hud = game.hud()
    if hud["flow"] in TEXT_FLOWS:
        image = [0] * (render.W * render.H)
        overlay.draw_overlay(image, hud, (game.px, game.py, game.angle), game.tiles, game.seen,
                             golden2.key_positions(game), blob, table)
        return image, [], [0xFFFF] * render.W
    eye = game.view_eye()
    fr = render.Frame(game.cam_x, game.cam_y, game.angle, eye, game.render_doors(),
                      game.lmod(), game.anim())
    image, descs = render.render_frame(fr, game.tiles, walls, flats, lights, game.seen)
    zwall = [d["z"] for d in descs]
    spans, _ = sprites.draw_sprites(image, game.sprite_table(), game.cam_x, game.cam_y,
                                    game.angle, eye, zwall, blob, table, lights,
                                    [d["clips"] for d in descs])
    overlay.draw_overlay(image, hud, (game.px, game.py, game.angle), game.tiles, game.seen,
                         golden2.key_positions(game), blob, table, debug_values)
    return image, spans, zwall
