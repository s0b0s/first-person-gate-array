"""Build the 8x8 font ROM used for on-screen text (bring-up pages, HUD, debug overlay).

The glyphs below were drawn by hand for this project (5 x 7 pixel shapes placed in the
top-left of an 8 x 8 cell, leaving one blank column on the right and one blank row at the
bottom as spacing). Codes 0x20 to 0x5F have their own glyphs; lowercase 0x60 to 0x7E reuse
the uppercase shapes; 0x7F is a solid block; control codes 0x00 to 0x1F are blank except
0x01 (a small right arrow) and 0x02 (a hollow box).

Output: rtl/display/font_rom.vhd, a synchronous ROM of 128 characters x 8 rows x 8 bits
(1 KB, one BRAM18 or 32 LUTs worth of distributed ROM, Vivado decides).

Usage: python tools/font/make_font.py
"""

from pathlib import Path
import sys as _sys
_sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "style"))
import headers  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent.parent
OUT = ROOT / "rtl" / "display" / "font_rom.vhd"

# Each glyph: 7 rows of 5 pixels, '#' = lit.
GLYPHS = {
    " ": [".....", ".....", ".....", ".....", ".....", ".....", "....."],
    "!": ["..#..", "..#..", "..#..", "..#..", "..#..", ".....", "..#.."],
    '"': [".#.#.", ".#.#.", ".....", ".....", ".....", ".....", "....."],
    "#": [".#.#.", ".#.#.", "#####", ".#.#.", "#####", ".#.#.", ".#.#."],
    "$": ["..#..", ".####", "#.#..", ".###.", "..#.#", "####.", "..#.."],
    "%": ["##...", "##..#", "...#.", "..#..", ".#...", "#..##", "...##"],
    "&": [".##..", "#..#.", "#.#..", ".#...", "#.#.#", "#..#.", ".##.#"],
    "'": ["..#..", "..#..", ".#...", ".....", ".....", ".....", "....."],
    "(": ["...#.", "..#..", ".#...", ".#...", ".#...", "..#..", "...#."],
    ")": [".#...", "..#..", "...#.", "...#.", "...#.", "..#..", ".#..."],
    "*": [".....", "..#..", "#.#.#", ".###.", "#.#.#", "..#..", "....."],
    "+": [".....", "..#..", "..#..", "#####", "..#..", "..#..", "....."],
    ",": [".....", ".....", ".....", ".....", ".##..", "..#..", ".#..."],
    "-": [".....", ".....", ".....", "#####", ".....", ".....", "....."],
    ".": [".....", ".....", ".....", ".....", ".....", ".##..", ".##.."],
    "/": [".....", "....#", "...#.", "..#..", ".#...", "#....", "....."],
    "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
    "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
    "3": ["#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."],
    "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
    "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
    "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
    "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
    "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
    "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
    ":": [".....", ".##..", ".##..", ".....", ".##..", ".##..", "....."],
    ";": [".....", ".##..", ".##..", ".....", ".##..", "..#..", ".#..."],
    "<": ["...#.", "..#..", ".#...", "#....", ".#...", "..#..", "...#."],
    "=": [".....", ".....", "#####", ".....", "#####", ".....", "....."],
    ">": [".#...", "..#..", "...#.", "....#", "...#.", "..#..", ".#..."],
    "?": [".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.."],
    "@": [".###.", "#...#", "....#", ".##.#", "#.#.#", "#.#.#", ".###."],
    "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "B": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
    "C": [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."],
    "D": ["###..", "#..#.", "#...#", "#...#", "#...#", "#..#.", "###.."],
    "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
    "F": ["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
    "G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".####"],
    "H": ["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "I": [".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "J": ["..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.."],
    "K": ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
    "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
    "M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
    "N": ["#...#", "#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#"],
    "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "P": ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
    "Q": [".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"],
    "R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
    "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
    "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
    "U": ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "V": ["#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
    "W": ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "#.#.#", ".#.#."],
    "X": ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],
    "Y": ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."],
    "Z": ["#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"],
    "[": [".###.", ".#...", ".#...", ".#...", ".#...", ".#...", ".###."],
    "\\": [".....", "#....", ".#...", "..#..", "...#.", "....#", "....."],
    "]": [".###.", "...#.", "...#.", "...#.", "...#.", "...#.", ".###."],
    "^": ["..#..", ".#.#.", "#...#", ".....", ".....", ".....", "....."],
    "_": [".....", ".....", ".....", ".....", ".....", ".....", "#####"],
}

SPECIAL = {
    0x01: [".....", "..#..", "...#.", "#####", "...#.", "..#..", "....."],
    0x02: ["#####", "#...#", "#...#", "#...#", "#...#", "#...#", "#####"],
}


def glyph_rows(code):
    """Return the 8 row bytes of character `code` (bit 7 = leftmost pixel)."""
    if code == 0x7F:
        return [0xFF] * 8
    if code in SPECIAL:
        shape = SPECIAL[code]
    elif 0x20 <= code <= 0x7E:
        ch = chr(code)
        if "a" <= ch <= "z":
            ch = ch.upper()
        shape = GLYPHS.get(ch, GLYPHS["?"]) if ch not in "`{|}~" else GLYPHS[" "]
    else:
        shape = GLYPHS[" "]
    rows = []
    for line in shape:
        assert len(line) == 5, line
        value = 0
        for i, c in enumerate(line):
            if c == "#":
                value |= 0x80 >> i
        rows.append(value)
    rows.append(0)
    return rows


def main():
    for k, v in GLYPHS.items():
        assert len(v) == 7, k
    words = []
    for code in range(128):
        words.extend(glyph_rows(code))
    lines = []
    for i in range(0, len(words), 8):
        chunk = ", ".join('x"%02X"' % w for w in words[i:i + 8])
        sep = "," if i + 8 < len(words) else ""
        lines.append("\t\t%s%s -- 0x%02X" % (chunk, sep, i // 8))
    table = "\n".join(lines)
    vhdl = f"""{headers.block('font_rom', "10/21/2026", ['8x8 character font, 128 characters (ASCII codes; lowercase', 'shows as uppercase). Synchronous read: the row byte for', '(char_i, row_i) appears on bits_o one clock after the', 'address. Bit 7 of bits_o is the leftmost pixel of the row.', 'Clock domain: any (clk_i). Latency 1 cycle, 1 read/cycle.'], ["VHDL-93", "IEEE.std_logic_1164", "IEEE.numeric_std"], [("0.01", "File Created"), ("1.00", "Generated by tools/font/make_font.py")], [], generated_note="Generated by tools/font/make_font.py. Do not edit by hand; edit the script and rerun.")}library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity font_rom is
	port(
		clk_i: in std_logic;
		char_i: in std_logic_vector(6 downto 0); -- ASCII code
		row_i: in std_logic_vector(2 downto 0); -- Row within the cell, 0 = top
		bits_o: out std_logic_vector(7 downto 0) -- Row pixels, bit 7 = leftmost
	);
end font_rom;

architecture arch of font_rom is
	type rom_t is array (0 to 1023) of std_logic_vector(7 downto 0);
	constant ROM: rom_t := (
{table}
	);
	signal addr: std_logic_vector(9 downto 0);
begin
	addr <= char_i & row_i;

	process(clk_i)
	begin
		if rising_edge(clk_i) then
			bits_o <= ROM(to_integer(unsigned(addr)));
		end if;
	end process;
end arch;
"""
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(vhdl, encoding="ascii", newline="\n")
    print("wrote", OUT.relative_to(ROOT))


if __name__ == "__main__":
    main()
