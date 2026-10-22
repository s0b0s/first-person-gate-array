"""Check VHDL files against the team's structural rules (the
lecture conventions and the course's own modules). tools/style/check_vhdl_style.py checks the
formatting; this checks the structure.

Usage:
    python tools/style/check_vhdl_structure.py            every .vhd under rtl/ and sim/
    python tools/style/check_vhdl_structure.py file.vhd   just these files

Rules (code outside comments and string literals):
    header      every field of the team's header block (tools/style/headers.py): Company,
                Engineer, Create Date, Design Name, Module Name, Project Name (First-Person
                Gate Array), Target Devices, Tool versions, Description, Dependencies,
                Revision, Additional Comments
    library     "library IEEE;" (upper case, as in the course), numeric_std only (no
                std_logic_arith, std_logic_unsigned, std_logic_signed)
    vhdl93      in rtl/, no VHDL-2008 predefined functions (maximum, minimum, to_string,
                to_hstring...): xvhdl's 93 mode accepts them, Vivado synthesis does not
    arch        every architecture is named arch
    component   instances use component declarations, never "entity work.x"
    begin       "begin" on its own line
    map         one association per line inside port map ( / generic map (
    clocked     a process with rising_edge and a reset in its sensitivity list is (clk, rst)
                and tests the reset before rising_edge; in rtl/, rising_edge only of a clock (a
                name with "clk" in it, or C as in the course); a process with rising_edge and no
                reset is reported as "no reset" for review (allowed for RAM, ROM and pipeline
                registers only)
    names       generics and constants in upper case; in rtl/ (except rtl/top/) every entity
                port ends in _i, _o or _io
    sync        no synchronizer instance with fewer than 3 stages
    testbench   every sim/tb_*.vhd has a clock process and a separate reset process
Exit status 1 if anything is found (the "no reset" review list does not count).
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_vhdl_style import split_code_comment  # noqa: E402

# The team's header block (tools/style/headers.py writes it)
HEADER_FIELDS = ["Company:", "Engineer:", "Create Date:", "Design Name:", "Module Name:",
                 "Project Name:   First-Person Gate Array", "Target Devices:", "Tool versions:",
                 "Description:", "Dependencies:", "Revision:", "Additional Comments:"]


def code_lines(lines):
    """(line number, code without comments and strings, comment) for every line."""
    out = []
    for n, line in enumerate(lines, 1):
        code, comment = split_code_comment(line.rstrip())
        out.append((n, code, comment))
    return out


def check(path):
    problems, review = [], []
    rel = path.relative_to(ROOT).as_posix() if path.is_relative_to(ROOT) else str(path)
    is_rtl = rel.startswith("rtl/")
    lines = path.read_text(encoding="ascii").split("\n")
    cl = code_lines(lines)

    def bad(n, msg):
        problems.append("%s:%d: %s" % (rel, n, msg))

    # header: the comment block before the first library clause
    first_lib = next((k for k, l in enumerate(lines) if l.lower().startswith("library")), len(lines))
    head = "\n".join(lines[:first_lib])
    for f in HEADER_FIELDS:
        if "-- " + f not in head:
            bad(1, "header block without '%s'" % f)

    for n, code, _ in cl:
        low = code.lower()
        # library
        if re.match(r"\s*library\s+ieee\s*;", low) and not re.match(r"\s*library\s+IEEE\s*;", code):
            bad(n, "write 'library IEEE;' (upper case)")
        if re.search(r"std_logic_(arith|unsigned|signed)", low):
            bad(n, "numeric_std only (no std_logic_arith/unsigned/signed)")
        # VHDL-93 design: predefined VHDL-2008 functions that xsim's 93 mode accepts but
        # Vivado synthesis rejects (found the hard way: maximum() in ps2_input)
        if is_rtl:
            m = re.search(r"\b(maximum|minimum|to_string|to_hstring|to_ostring|to_bstring)\s*\(", low)
            if m:
                bad(n, "%s() is VHDL-2008; the design is VHDL-93" % m.group(1))
        # arch
        m = re.match(r"\s*architecture\s+(\w+)\s+of\s+\w+", code, re.IGNORECASE)
        if m and m.group(1) != "arch":
            bad(n, "architecture named '%s', not arch" % m.group(1))
        # component
        if re.search(r":\s*entity\s+\w+\.", low):
            bad(n, "direct entity instantiation; declare a component")
        # begin
        s = code.strip()
        if re.search(r"\bbegin\b", s, re.IGNORECASE) and s.lower() != "begin":
            bad(n, "'begin' not on its own line")
        # names: constants
        m = re.match(r"\s*constant\s+(\w+)\s*:", code, re.IGNORECASE)
        if m and m.group(1) != m.group(1).upper():
            bad(n, "constant '%s' not in upper case" % m.group(1))
        # sync
        m = re.search(r"\bSTAGES\s*=>\s*(\d+)", code)
        if m and int(m.group(1)) < 3:
            bad(n, "synchronizer with %s stages (3 or more)" % m.group(1))

    # map: one association per line inside port map ( / generic map (
    depth = None
    for n, code, _ in cl:
        if re.search(r"\b(port|generic)\s+map\s*\(", code, re.IGNORECASE):
            depth = 0
            after = re.split(r"\bmap\s*\(", code, flags=re.IGNORECASE)[1]
            depth = 1 + after.count("(") - after.count(")")
            if after.count("=>") > 0:
                bad(n, "association on the 'map (' line")
            continue
        if depth is not None:
            # Count only top-level associations: an aggregate such as (others => '0') inside
            # one association has its own "=>"
            flat = code
            while re.search(r"\([^()]*\)", flat):
                flat = re.sub(r"\([^()]*\)", "", flat)
            if flat.count("=>") > 1:
                bad(n, "more than one association on a line in a port or generic map")
            depth += code.count("(") - code.count(")")
            if depth <= 0:
                depth = None

    # generics (upper case) and entity ports (suffixes) from the entity declarations
    text_code = "\n".join(code for _, code, _ in cl)
    for m in re.finditer(r"\bentity\s+(\w+)\s+is\b(.*?)\bend\b", text_code, re.IGNORECASE | re.DOTALL):
        body = m.group(2)
        start_line = text_code[:m.start()].count("\n") + 1
        g = re.search(r"\bgeneric\s*\((.*?)\)\s*;\s*(port\b|$)", body, re.IGNORECASE | re.DOTALL)
        if g:
            for gm in re.finditer(r"(\w+)\s*:\s*\w", g.group(1)):
                if gm.group(1) != gm.group(1).upper():
                    bad(start_line, "generic '%s' not in upper case" % gm.group(1))
        if is_rtl and not rel.startswith("rtl/top/"):
            p = re.search(r"\bport\s*\((.*)\)\s*;", body, re.IGNORECASE | re.DOTALL)
            if p:
                for pm in re.finditer(r"(\w+)\s*:\s*(in|out|inout|buffer)\b", p.group(1), re.IGNORECASE):
                    name = pm.group(1)
                    if not re.search(r"_(i|o|io)$", name):
                        bad(start_line, "port '%s' of %s without _i/_o/_io" % (name, m.group(1)))

    # clocked processes
    i = 0
    while i < len(cl):
        n, code, _ = cl[i]
        m = re.match(r"\s*(\w+\s*:\s*)?process\s*(\((.*?)\))?", code, re.IGNORECASE)
        if not m or "end process" in code.lower():
            i += 1
            continue
        sens = [x.strip() for x in (m.group(3) or "").split(",") if x.strip()]
        body = []
        j = i + 1
        while j < len(cl) and not re.match(r"\s*end\s+process", cl[j][1], re.IGNORECASE):
            body.append(cl[j])
            j += 1
        edges = [(bn, re.search(r"rising_edge\s*\(\s*(\w+)", bc, re.IGNORECASE)) for bn, bc, _ in body]
        edges = [(bn, e.group(1)) for bn, e in edges if e]
        resets = [x for x in sens if re.search(r"rst|reset", x, re.IGNORECASE)]
        for bn, clk in edges:
            # The design must detect edges of data by comparing with a register, never with
            # rising_edge (course rule); testbenches and models may watch a bus or a line
            if is_rtl and "clk" not in clk.lower() and clk != "C":
                bad(bn, "rising_edge of '%s', not a clock" % clk)
        if edges and sens:
            if resets:
                if len(sens) != 2:
                    bad(n, "clocked process with reset: sensitivity list should be (clk, rst), is (%s)" % ", ".join(sens))
                first_edge = edges[0][0]
                rst_test = [bn for bn, bc, _ in body
                            if re.search(r"\bif\s*\(?\s*\(?%s\b" % re.escape(resets[0]), bc, re.IGNORECASE)]
                if not rst_test or rst_test[0] > first_edge:
                    bad(n, "reset not tested before rising_edge")
            else:
                review.append("%s:%d: clocked process without reset (%s)" % (rel, n, ", ".join(sens)))
        i = j + 1

    # testbench processes
    if rel.startswith("sim/tb_"):
        procs = []
        k = 0
        while k < len(cl):
            if re.match(r"\s*(\w+\s*:\s*)?process\b", cl[k][1], re.IGNORECASE):
                j = k + 1
                body = []
                while j < len(cl) and not re.match(r"\s*end\s+process", cl[j][1], re.IGNORECASE):
                    body.append(cl[j][1])
                    j += 1
                procs.append("\n".join(body))
                k = j
            k += 1
        # (character literals reach here blanked as '_', see split_code_comment)
        clock = [p for p in procs if len(re.findall(r"\b(clk\w*|C)\s*<=\s*'_'", p)) >= 2 and
                 "wait for" in p]
        reset = [p for p in procs if re.search(r"\b(rst\w*|reset\w*|btn\w*|R)\s*<=", p) and
                 p not in clock]
        if not clock:
            bad(1, "testbench without a clock process")
        if not reset:
            bad(1, "testbench without a separate reset process")
    return problems, review


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    files = [Path(a).resolve() for a in args] or \
        sorted(list((ROOT / "rtl").rglob("*.vhd")) + list((ROOT / "sim").rglob("*.vhd")))
    problems, review = [], []
    for f in files:
        p, r = check(f)
        problems += p
        review += r
    for p in problems:
        print(p)
    if "--review" in sys.argv:
        for r in review:
            print("review: " + r)
    print("%d files, %d problems, %d clocked processes without reset (review with --review)" %
          (len(files), len(problems), len(review)))
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
