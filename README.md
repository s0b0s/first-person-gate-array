# First-Person Gate Array

A first-person shooter built entirely out of digital logic on a small FPGA board. There is no
processor anywhere in the design: no soft CPU in the FPGA and no microcontroller on the side.
The 3D renderer, the monsters, the game rules, the keyboard and mouse interface and the sound
are all state machines and memories written in VHDL.

## What the game is

You walk through a textured 3D maze, open doors, pick up keys, health, ammo and weapons, and
fight monsters that see you, chase you and shoot back. There are three levels, the last one
ending with a boss. Later levels have rooms with different floor and ceiling heights, steps,
ramps and pits, flickering and glowing lights, outdoor areas with a sky, and animated slime
walls. Firing a gun makes noise that wakes up monsters in nearby rooms, unless they are set
to lie in ambush.

The screen also shows a status bar, a minimap and a full-screen automap, along with title,
briefing and score screens. Sound effects and music play in stereo.

## How it runs

- **Board:** Digilent Cmod A7-35T (a Xilinx Artix-7 FPGA with 512 KB of external SRAM and 4 MB
  of flash).
- **Video:** 320x240 pixels, each drawn as a 2x2 block on a standard 640x480, 60 Hz VGA monitor
  through a Digilent Pmod VGA. Colors come from a 256-entry palette.
- **Input:** a PS/2 keyboard and a PS/2 mouse through two Digilent Pmod PS2 boards.
- **Sound:** stereo through a Digilent Pmod I2S2 to headphones.
- **Boot:** the design and all game data load from the board's flash at power-up, so no PC is
  needed.

The modules plug into a small custom carrier PCB. Inside the FPGA, the main blocks are:

| Block | What it does |
| --- | --- |
| Ray engine | Casts one ray per screen column through the tile map to find the walls |
| Column rasterizer | Draws each column: walls, floors, ceilings, sky, lighting |
| Sprite engine | Draws monsters, items and projectiles, hidden correctly behind walls |
| Overlay | Status bar, minimap, automap and text screens |
| Game core | Player movement, collision, doors, monsters, weapons, pickups, levels |
| Display controller | Reads the finished frame from SRAM and sends it to the monitor |
| PS/2 host | Talks to the keyboard and mouse |
| Audio mixer | Mixes 8 sound effect voices and a music track |
| SRAM and flash controllers | Shared memory access and loading game data at boot |

Two frames are kept in SRAM: the game draws the next frame into one while the monitor shows
the other. A frame takes about 3 to 6 ms to draw out of the 16.7 ms available at 60 Hz.

## Controls

| Action | Keys |
| --- | --- |
| Move forward / back | W / S, or the up / down arrows |
| Strafe | A / D |
| Turn | Mouse, or the left / right arrows |
| Fire | Left click, or Ctrl |
| Use (doors, switches) | Space |
| Run | Shift |
| Duck | Hold C |
| Peek left / right | Hold Q / E |
| Weapons | 1, 2, 3, or right click to cycle |
| Automap | Tab |
| Pause | Esc |

## Development stages

The design was built in stages, each ending in a working bitstream, and comments in the code
refer to them:

| Stage | What it added | Top level |
| --- | --- | --- |
| 0 | Bring-up: test patterns, SRAM and flash tests, raw keyboard and mouse codes, test tone, UART | `bringup_top` |
| 1 | A textured maze to walk through, with doors and collision | `game_top` |
| 2 and 3 | The full game: monsters, weapons, items, keys, HUD, maps, sound, three levels | `shooter_top` |
| 4 | Floor and ceiling heights, steps, ramps, light effects, sky, animated walls | `shooter_top` |
| 5 | Monsters woken by gunfire, and ambushing monsters | `shooter_top` |

## How it was checked

A Python model of the whole game (in `tools/model/`) is the reference. It generates the
textures, levels and sounds, and it produces "golden" outputs: whole frames, game states and
audio samples. Every hardware block has a self-checking simulation testbench that compares
its output with the model, pixel for pixel and bit for bit. The largest test boots the
complete design from a simulated flash chip and plays a scripted session.

## Repository layout

| Folder | Contents |
| --- | --- |
| `rtl/` | The hardware design (VHDL), one block per file |
| `sim/` | Simulation testbenches and models of the SRAM, flash, keyboard, mouse and monitor |
| `constraints/` | Pin assignments and timing constraints for the board |
| `scripts/` | Build the bitstream and run the simulations |
| `tools/` | Python: the game model, asset generators, flash image builder, style checkers, PC debug tools |
| `assets/levels/` | Text pictures of the three level maps, written by the model, so a person can read the levels |
| `build/` | Everything generated (not kept in git) |

## Building

You need Vivado 2025.1 (its simulator, xsim, runs the testbenches) and Python 3.9 or newer.
The Python tools use only the standard library, so building and simulating need no packages.
The one exception is the UART debug tool (`tools/uart/debug_uart.py`), which needs `pyserial`.
Either install it with `pip install -r requirements.txt`, or, if you use
[uv](https://docs.astral.sh/uv/), run that script as `uv run tools/uart/debug_uart.py ...` and
uv fetches `pyserial` by itself. Run everything from the repository root.

On a fresh clone, run the first two steps before anything else. They write the art, level
and game-data files into `build/`, which the testbenches and the flash image read.

| Step | Command |
| --- | --- |
| Generate the assets, ROM contents and test data | `python tools/model/build_assets.py` |
| Build the flash game-data image | `python tools/flash_image/make_gamedata.py` |
| Run every testbench (about 30 minutes; most of it is the full-boot test) | `python scripts/run_sim.py` |
| Run some testbenches | `python scripts/run_sim.py tb_sram tb_ray_engine` |
| Check the code style | `python tools/style/check_vhdl_style.py` and `python tools/style/check_vhdl_structure.py` |
| Build the bitstream and flash image | `vivado -mode batch -source scripts/build.tcl -tclargs shooter_top` |

The build writes `build/shooter_top/shooter_top.bit` (to load straight into the FPGA) and
`shooter_top.mcs` (to program into flash, so the game boots on its own). Two smaller designs
build the same way: `bringup_top` shows test pages for checking the board and its wiring, and
`game_top` is the first playable maze.

## Art and sound

All textures, sprites, sounds and music are original, generated by the Python scripts in
`tools/model/`. No assets from other games are used.
