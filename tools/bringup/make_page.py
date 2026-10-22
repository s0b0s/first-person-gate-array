"""Build the stage-0 bring-up status page ROM (rtl/bringup/page_rom.vhd).

The page is 40 x 30 character cells (8 x 8 pixels each, 320 x 240). The layout below is
plain text with fields in braces that show live hardware values in hex:

    {W.N}     the low N hex digits of value word W (0..31)
    {W.N.S}   N hex digits of word W starting at nibble S (nibble 0 = bits 3:0)

Each ROM entry is 9 bits:
    bit 8 = 0: bits 6:0 are an ASCII character
    bit 8 = 1: a hex digit; bits 7:3 = value word, bits 2:0 = nibble index
The painter (rtl/bringup/text_painter.vhd) turns field entries into digits at draw time.
The value words are wired up in rtl/top/bringup_top.vhd; keep this list and that file
in step:

     0 build id                       16 keyboard errors P(7:0) F(15:8) T(23:16)
     1 SRAM passes(31:16) errors      17 mouse errors P F T(+tx)
     2 SRAM first bad address         18 key-state vector
     3 SRAM want(15:8) got(7:0)       19 mouse X total(31:16) Y total(15:0)
       phase(19:16)                   20 mouse buttons(3:0) state(7:4) retries(15:8)
     4 flash JEDEC id                 21 UART rx bytes(31:16) tx bytes(15:0)
     5 flash data bytes 0..3          22 frames(31:16) late frames(15:0)
     6 flash data bytes 4..7          23 SRAM busy cycles in the last frame
     7 (spare)                        24 input snapshot bits 31:0
   8-11 keyboard bytes, newest first  25 input snapshot bits 39:32
  12-15 mouse bytes, newest first     26 overruns(15:0) pcb_on(16) locked(20)
                                      27 audio on(0) pattern(6:4)

It also writes sim/golden/page_expected.txt, the image the painter must draw (one line of
320 two-digit hex palette indices per pixel row) when value word w holds
test_value(w) = (0x9E3779B9 * (w + 1)) mod 2^32; sim/tb_text_painter.vhd uses the same values.

Usage: python tools/bringup/make_page.py
"""

import re
import sys
from pathlib import Path
import sys as _sys
_sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "style"))
import headers  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent.parent
OUT = ROOT / "rtl" / "bringup" / "page_rom.vhd"
GOLDEN = ROOT / "sim" / "golden" / "page_expected.txt"
COLS, ROWS = 40, 30
COLOR_BLACK, COLOR_LIGHT_GREEN, COLOR_YELLOW, COLOR_WHITE = 0, 10, 14, 15

sys.path.insert(0, str(ROOT / "tools" / "font"))
from make_font import glyph_rows  # noqa: E402


def history(word):
    """Eight bytes of a history pair, newest first: {w.2} {w.2.2} .. {w+1.2.6}."""
    cells = []
    for w in (word, word + 1):
        for b in range(4):
            cells.append("{%d.2.%d}" % (w, 2 * b))
    return " ".join(cells)


LAYOUT = [
    "SHOOTER GAME  STAGE 0 BRING-UP",
    "========================================",
    "BUILD {0.8}  PCB {26.1.4} MMCM {26.1.5}",
    "FRAMES {22.4.4} LATE {22.4} BUS {23.6}",
    "LINE OVERRUNS {26.4}",
    "SRAM TEST 40000-7FFFF  PHASE {3.1.4}",
    " PASSES {1.4.4}  ERRORS {1.4}",
    " FIRST BAD {2.5}  WANT {3.2.2} GOT {3.2}",
    "FLASH ID {4.6}  (C22016 / 20BA16)",
    " DATA @220000 {5.8} {6.8}",
    "KEYBOARD  ERRORS P{16.2} F{16.2.2} T{16.2.4}",
    " " + history(8),
    " " + history(10),
    " KEYS {18.6}",
    "MOUSE  STATE {20.1.1}  RETRY {20.2.2}",
    " BUTTONS {20.1}  ERR P{17.2} F{17.2.2} T{17.2.4}",
    " " + history(12),
    " " + history(14),
    " X TOTAL {19.4.4}  Y TOTAL {19.4}",
    "SNAPSHOT {25.2}{24.8}",
    "UART  RX {21.4.4}  TX {21.4}",
    "AUDIO {27.1}  PATTERN {27.1.4}",
    "",
    "BTN1: NEXT PATTERN   BTN0: RESET",
    "UART 1000000 8N1: P PING, R/W REGS,",
    " M READ SRAM, S WRITE SRAM",
]

FIELD = re.compile(r"\{(\d+)\.(\d+)(?:\.(\d+))?\}")


def expand(line):
    """Return the list of 9-bit cell codes for one layout line."""
    cells = []
    pos = 0
    for m in FIELD.finditer(line):
        cells.extend(ord(c) for c in line[pos:m.start()])
        word, digits = int(m.group(1)), int(m.group(2))
        start = int(m.group(3) or 0)
        assert 0 <= word < 32 and 1 <= digits and start + digits <= 8, m.group(0)
        for nib in range(start + digits - 1, start - 1, -1):
            cells.append(0x100 | (word << 3) | nib)
        pos = m.end()
    cells.extend(ord(c) for c in line[pos:])
    assert len(cells) <= COLS, "line too long (%d): %s" % (len(cells), line)
    assert all(c >= 0x100 or 0x20 <= c < 0x7F for c in cells), line
    return cells + [0x20] * (COLS - len(cells))


def test_value(w):
    return (0x9E3779B9 * (w + 1)) & 0xFFFFFFFF


def render(rom, values):
    """The page as the painter draws it: 240 rows of 320 palette indices."""
    image = []
    for y in range(240):
        row = []
        for x in range(320):
            cell = rom[(y // 8) * COLS + x // 8]
            if cell & 0x100:
                digit = (values[(cell >> 3) & 31] >> (4 * (cell & 7))) & 15
                char = ord("0123456789ABCDEF"[digit])
            else:
                char = cell & 0x7F
            lit = glyph_rows(char)[y % 8] & (0x80 >> (x % 8))
            if not lit:
                row.append(COLOR_BLACK)
            elif y < 8:
                row.append(COLOR_YELLOW)
            elif cell & 0x100:
                row.append(COLOR_LIGHT_GREEN)
            else:
                row.append(COLOR_WHITE)
        image.append(row)
    return image


def main():
    assert len(LAYOUT) <= ROWS
    rom = []
    for line in LAYOUT + [""] * (ROWS - len(LAYOUT)):
        rom.extend(expand(line))
    image = render(rom, [test_value(w) for w in range(32)])
    GOLDEN.parent.mkdir(parents=True, exist_ok=True)
    lines = ["".join("%02X" % p for p in row) for row in image]
    GOLDEN.write_text("\n".join(lines) + "\n", encoding="ascii", newline="\n")
    rows = []
    for r in range(ROWS):
        chunk = rom[r * COLS:(r + 1) * COLS]
        words = ", ".join('"%s"' % format(c, "09b") for c in chunk)
        sep = "," if r < ROWS - 1 else ""
        rows.append("\t\t-- row %d\n\t\t%s%s" % (r, words, sep))
    body = "\n".join(rows)
    text = f"""{headers.block('page_rom', "10/21/2026", ['Bring-up status page, 40 x 30 cells, 9 bits per cell:', 'bit 8 = 0: ASCII character in bits 6:0;', 'bit 8 = 1: hex digit of value word bits 7:3, nibble', 'bits 2:0. Synchronous read, address = row * 40 + col.', 'Clock domain: clk_i. Latency 1 cycle.'], ["VHDL-93", "IEEE.std_logic_1164", "IEEE.numeric_std"], [("0.01", "File Created"), ("1.00", "Generated by tools/bringup/make_page.py")], [], generated_note="Generated by tools/bringup/make_page.py. Do not edit by hand; edit the script and rerun.")}library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity page_rom is
	port(
		clk_i: in std_logic; -- Clock
		addr_i: in std_logic_vector(10 downto 0); -- row * 40 + col (0..1199)
		cell_o: out std_logic_vector(8 downto 0) -- Cell code
	);
end page_rom;

architecture arch of page_rom is
	type rom_t is array (0 to 2047) of std_logic_vector(8 downto 0);
	constant ROM: rom_t := (
{body},
		others => "000100000"
	);
begin
	process(clk_i)
	begin
		if rising_edge(clk_i) then
			cell_o <= ROM(to_integer(unsigned(addr_i)));
		end if;
	end process;
end arch;
"""
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding="ascii", newline="\n")
    print("wrote", OUT.relative_to(ROOT), "and", GOLDEN.relative_to(ROOT))


if __name__ == "__main__":
    main()
