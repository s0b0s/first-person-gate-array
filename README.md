# First-Person Gate Array

A first-person shooter game built entirely from digital logic on a small FPGA board, with no
processor anywhere (no soft CPU, no microcontroller). The 3D renderer, monsters, game rules,
keyboard and mouse interface and sound are all state machines and memories written in VHDL.

## What the game is

Walk through a textured 3D maze, open doors, collect keys, health, ammo and weapons, and fight
monsters that see you, chase you and shoot back. Three levels, the last ending with a boss.
Later levels add floor and ceiling heights, steps, ramps and pits, flickering and glowing
lights, outdoor areas with a sky, and animated slime walls. Gunfire wakes monsters in nearby
rooms, except those lying in ambush.

There is a status bar, a minimap, a full-screen automap, title, briefing and score screens,
and stereo sound effects and music.

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

Two frames live in SRAM: the game draws one while the monitor shows the other. Drawing takes
about 3 to 6 ms of the 16.8 ms frame (the 25 MHz pixel clock gives 59.5 Hz).

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
| Weapons | 1, 2, or right click to cycle |
| Automap | Tab |
| Pause | Esc |

## How it was built

The design grew in steps, each ending in a bitstream that builds and meets timing:

| In order | What it added | Top level |
| --- | --- | --- |
| Bring-up | Test patterns, SRAM and flash tests, raw keyboard and mouse codes, test tone, UART | `bringup_top` |
| First maze | A textured maze to walk through, with doors and collision | `game_top` |
| Full game | Monsters, weapons, items, keys, HUD, maps, sound, three levels | `shooter_top` |
| Heights | Floor and ceiling heights, steps, ramps, light effects, sky, animated walls | `shooter_top` |
| Alerts | Monsters woken by gunfire, and ambushing monsters | `shooter_top` |

## How it was checked

A Python model of the whole game (`tools/model/`) is the reference. It generates the
textures, levels and sounds and the "golden" frames, game states and audio samples. Every
hardware block has a self-checking testbench that matches the model bit for bit. The largest
test boots the complete design from a simulated flash chip and plays a scripted session.

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

You need Vivado 2025.1 (xsim runs the testbenches) and Python 3.9 or newer. The Python tools
use only the standard library, except the UART tools in `tools/uart/`: the debug tool needs
`pyserial` (`pip install -r requirements.txt`) and the live viewer also `pygame-ce`. With
[uv](https://docs.astral.sh/uv/), `uv run tools/uart/debug_uart.py ...` installs what each needs.
Run everything from the repository root.

On a fresh clone, run the first two steps first: they write the art, level and game-data
files into `build/` that the testbenches and the flash image read.

| Step | Command |
| --- | --- |
| Generate the assets, ROM contents and test data | `python tools/model/build_assets.py` |
| Build the flash game-data image | `python tools/flash_image/make_gamedata.py` |
| Run every testbench (the full-system test sets the pace) | `python scripts/run_sim.py` |
| Run only the testbenches whose inputs changed since they last passed | `python scripts/run_sim.py --changed` |
| Run some testbenches | `python scripts/run_sim.py tb_sram tb_ray_engine` |
| Check the code style | `python tools/style/check_vhdl_style.py` and `python tools/style/check_vhdl_structure.py` |
| Build the bitstream and flash image | `vivado -mode batch -source scripts/build.tcl -tclargs shooter_top` |

The build writes `build/shooter_top/shooter_top.bit` (load straight into the FPGA) and
`shooter_top.mcs` (program into flash so the game boots on its own). `bringup_top` (board and
wiring test pages) and `game_top` (the first playable maze) build the same way.

## Watching the game without a monitor

`tools/uart/live_view.py` (or double-click `tools/uart/live_view.bat`) shows the game in a
window over the board's USB cable, like a second monitor. It finds the board and the link rate
by itself and reconnects when the board is reset, reprogrammed or unplugged; close the window
to stop it. The board streams each new frame at 12 Mbaud, sending only the pixels that changed
since the frame before, run-length encoded, so the window keeps up with the game's 60 frames a
second; a whole new view while turning fast takes longer. Older bitstreams without the stream
command are read frame by frame instead. The keyboard and mouse stay on the board. `tools/uart/debug_uart.py` reads and writes registers and memory, and
its `capture` command freezes the game for an exact frame dump.

## Art and sound

All textures, sprites, sounds and music are original, generated by `tools/model/`. No assets
from other games are used.
