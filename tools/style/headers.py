"""The project's VHDL file header block, in one place (the format the team uses in its labs).

    block(...)        builds a header block from its fields
    rewrite(path)     rewrites the header of an existing .vhd file into this format, keeping
                      its date, description, dependencies, revision and limitations

Used by tools/model/export.py, tools/font/make_font.py and tools/bringup/make_page.py for the
generated files, and run once over rtl/ and sim/ (python tools/style/headers.py) to convert
the hand-written ones.
"""

import re
import sys
from pathlib import Path

PROJECT = "First-Person Gate Array"
ENGINEER = "Matthew Gordon"
RULE = "-" * 74
INDENT = "--                 "
WIDTH = 78

ACRONYMS = {"sram": "SRAM", "ps2": "PS/2", "uart": "UART", "i2s": "I2S", "vga": "VGA",
            "crc": "CRC", "bcd": "BCD", "rom": "ROM", "ram": "RAM", "fifo": "FIFO",
            "rx": "Receiver", "tx": "Transmitter", "tb": "Testbench", "pkg": "Package",
            "io": "I/O", "hw": "Hardware", "ooc": "OOC", "spi": "SPI", "hud": "HUD"}
DESIGN_NAMES = {
    "bringup_top": "Bring-up Diagnostics Top Level", "game_top": "Stage-1 Game Top Level",
    "shooter_top": "First-Person Gate Array Top Level", "game_seq": "Stage-1 Game Sequencer",
    "game_core": "Game Core", "render_top": "Wall Renderer", "frame_renderer": "Frame Renderer",
    "ray_engine": "Ray Engine", "column_rasterizer": "Column Rasterizer",
    "sprite_engine": "Sprite Engine", "overlay": "2D Overlay", "overlay_bcd": "Binary to BCD",
    "power_gate": "PWR_SENSE Gate", "clock_reset": "Clocks and Resets",
    "reset_sync": "Reset Synchronizer", "pulse_sync": "Pulse Synchronizer",
    "debounce": "Button Debouncer", "sync_fifo": "Synchronous FIFO",
    "sram_port_mux": "SRAM Port Multiplexer", "tile_map": "Tile Map RAM",
    "page_rom": "Bring-up Page ROM", "font_rom": "Font ROM", "wall_rom": "Wall Texture ROM",
    "anim_rom": "Animated Texture ROM", "flat_rom": "Floor and Ceiling Texture ROM",
    "light_rom": "Light Table ROM", "sky_rom": "Sky Texture ROM",
    "asset_loader": "Asset Loader", "level_loader": "Level Loader",
    "replay_unit": "Replay Unit", "debug_port": "UART Debug Port",
    "audio_mixer": "Audio Mixer", "audio_ram": "Audio Sample RAM", "tone_gen": "Test Tone",
    "flash_reader": "SPI Flash Reader", "flash_arbiter": "Flash Arbiter",
    "flash_probe": "Flash JEDEC ID Probe", "text_painter": "Text Painter",
    "sram_tester": "SRAM Tester", "core_crc": "State CRC-32", "divider": "Restoring Divider",
    "sprite_fifo": "Sprite Pixel FIFO", "input_snapshot": "Input Snapshot",
    "ps2_input": "PS/2 Keyboard and Mouse Input", "ps2_host": "PS/2 Host",
    "ps2_keyboard": "PS/2 Keyboard", "ps2_mouse": "PS/2 Mouse",
    "vga_timing": "VGA Timing", "display_pixel": "Display Pixel Path",
    "line_fetcher": "Line Fetcher", "line_buffer": "Line Buffer", "palette_ram": "Palette RAM",
    "display_controller": "Display Controller", "buffer_manager": "Buffer Manager",
    "map_init_pkg": "Level 1 Map Package", "game_tables_pkg": "Game Tables Package",
    "text_pkg": "Text Strings Package", "render_types_pkg": "Renderer Types Package",
    "render_pkg": "Renderer Constants Package", "palette_pkg": "Palette Package",
    "game_pkg": "Game Constants Package", "hw_pkg": "Hardware Constants Package",
    "tb_pkg": "Testbench Support Package", "sram_model": "SRAM Model",
    "spi_flash_model": "SPI Flash Model", "ps2_device_model": "PS/2 Device Model",
    "vga_monitor": "VGA Monitor", "i2s_receiver_model": "I2S Receiver Model",
}


def design_name(module):
    if module in DESIGN_NAMES:
        return DESIGN_NAMES[module]
    words = module.split("_")
    if words[0] == "tb":
        return design_name("_".join(words[1:])) + " Testbench"
    return " ".join(ACRONYMS.get(w, w.capitalize()) for w in words)


def wrap(text, first):
    """Header lines for a field: the first line starts with first, the rest with INDENT."""
    words = text.split()
    lines, cur = [], first
    for w in words:
        if len(cur) + len(w) + 1 > WIDTH and cur.strip() not in ("--",) and cur != first:
            lines.append(cur.rstrip())
            cur = INDENT
        cur += ("" if cur.endswith(" ") else " ") + w
    lines.append(cur.rstrip())
    return lines


def block(module, date, description_lines, dependencies, revisions, comments, simulation=False,
          generated_note=None):
    """description_lines are kept line by line (they are already wrapped); dependencies is a
    list of names; revisions a list of (number, text); comments a list of lines or empty."""
    out = []
    if generated_note:
        out.append("-- " + generated_note)
    out += [RULE,
            "-- Company:        Johns Hopkins University Whiting School of Engineering",
            INDENT + "Department of Electrical and Computer Engineering",
            "-- Engineer:       " + ENGINEER,
            "--",
            "-- Create Date:    " + date,
            "-- Design Name:    " + design_name(module),
            "-- Module Name:    " + module,
            "-- Project Name:   " + PROJECT,
            "-- Target Devices: " + ("Simulation only (Vivado xsim)" if simulation else
                                     "Digilent Cmod A7-35T, Artix-7 FPGAs"),
            "-- Tool versions:  " + ("Vivado 2025.1 xsim, VHDL-2008" if simulation else
                                     "Vivado 2025.1, VHDL-93")]
    for k, line in enumerate(description_lines):
        if k > 0 and not line:
            out.append("--")
        else:
            out.append(("-- Description:    " if k == 0 else INDENT) + line)
    out.append("--")
    out += wrap(", ".join(dependencies), "-- Dependencies:   ")
    out.append("--")
    out.append("-- Revision:")
    for num, text in revisions:
        out += wrap("%s - %s" % (num, text), "-- Revision")
    out.append("-- Additional Comments:")
    for line in (comments or ["None."]):
        out.append(INDENT + line)
    out.append(RULE)
    return "\n".join(out) + "\n"


FIELD = re.compile(r"^-- ([A-Za-z ]+):\s*(.*)$")


def parse(header_lines):
    """Fields of an existing header: {name: [lines]} (continuation lines appended)."""
    fields, cur = {}, None
    for line in header_lines:
        if line.startswith("-- Generated by"):
            fields["Generated"] = [line[3:]]
            cur = None
            continue
        if re.fullmatch(r"-+", line.strip()) and len(line.strip()) > 2:
            cur = None
            continue
        m = FIELD.match(line)
        if m and not line.startswith(INDENT):
            cur = m.group(1).strip()
            fields.setdefault(cur, []).append(m.group(2).rstrip())
        elif cur is not None and line.startswith("--"):
            # Continuation (indentation beyond the field column kept); a bare "--" is a blank
            # line inside the field
            if line.startswith(INDENT):
                fields[cur].append(line[len(INDENT):].rstrip())
            else:
                fields[cur].append(line[2:].strip())
    return fields


def ieee_uses(body):
    deps = []
    for name, pat in (("IEEE.std_logic_1164", r"IEEE\.std_logic_1164"),
                      ("IEEE.numeric_std", r"IEEE\.numeric_std"),
                      ("IEEE.math_real", r"IEEE\.math_real"), ("std.textio", r"std\.textio"),
                      ("UNISIM", r"library UNISIM")):
        if re.search(pat, body):
            deps.append(name)
    return deps


def revisions_of(rev_lines, generated):
    """Revision history, oldest first: every "X.YY - text" entry of the old field, after
    0.01 File Created (and 1.00 First working version when the oldest entry is later)."""
    # A header already in this format has "Revision X.YY - text" lines
    text = " ".join(re.sub(r"^Revision\s+", "", l.strip()) for l in rev_lines if l.strip())
    parts = re.split(r"(?:^|\s)(\d+\.\d\d)\s+-\s+", text)
    entries = [(parts[k], parts[k + 1].strip().rstrip(";")) for k in range(1, len(parts) - 1, 2)]
    entries = [e for e in entries if e[0] != "0.01"]
    revs = [("0.01", "File Created")]
    if not entries:
        revs.append(("1.00", text or ("Generated" if generated else "First working version")))
        return revs
    entries.sort(key=lambda e: tuple(int(x) for x in e[0].split(".")))
    if entries[0][0] != "1.00":
        revs.append(("1.00", "First working version"))
    return revs + entries


def rewrite(path):
    path = Path(path)
    text = path.read_text(encoding="ascii")
    lines = text.split("\n")
    # The header is the comment block before the first line of code (a file such as
    # text_pkg.vhd has no library clause)
    end = next(k for k, l in enumerate(lines) if l.strip() and not l.startswith("--"))
    header, body = lines[:end], "\n".join(lines[end:])
    f = parse(header)
    module = f["Module Name"][0].split()[0]
    simulation = path.as_posix().split("/")[-2] in ("sim", "models", "pkg") and "/sim/" in path.as_posix()
    date = f.get("Create Date", ["10/21/2026"])[0]
    desc = [l for l in f.get("Description", [""])]
    while desc and not desc[-1]:
        desc.pop()
    for key in ("Limitations",):
        while f.get(key) and not f[key][-1]:
            f[key].pop()
    old_deps = " ".join(f.get("Dependencies", [])).replace(" ,", ",")
    deps = ["VHDL-2008" if simulation else "VHDL-93"] + ieee_uses(body)
    for d in re.split(r",\s*", old_deps):
        d = d.strip().rstrip(".")
        if d and d not in deps and not d.startswith("IEEE.") and \
                d not in ("std.textio", "UNISIM", "VHDL-93", "VHDL-2008"):
            deps.append(d)
    generated = "Generated" in f
    revs = revisions_of(f.get("Revision", []), generated)
    comments = [l for l in f.get("Limitations", []) + f.get("Additional Comments", [])
                if l and l != "None."]
    new = block(module, date, desc, deps, revs, comments, simulation,
                f["Generated"][0] if generated else None)
    path.write_text(new + body, encoding="ascii", newline="\n")


def main():
    root = Path(__file__).resolve().parent.parent.parent
    files = [Path(a) for a in sys.argv[1:]] or \
        sorted(list((root / "rtl").rglob("*.vhd")) + list((root / "sim").rglob("*.vhd")))
    for p in files:
        rewrite(p)
    print("rewrote %d headers" % len(files))


if __name__ == "__main__":
    main()
