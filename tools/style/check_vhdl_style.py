"""Check VHDL files against the team's formatting rules.

Usage:
    python tools/style/check_vhdl_style.py            every .vhd under rtl/ and sim/
    python tools/style/check_vhdl_style.py file.vhd   just these files

Rules checked (outside comments and string literals):
    - keyboard characters only (ASCII), no trailing whitespace
    - tab indentation (no line starts with spaces)
    - spaces around <=, =>, := and after commas
    - "port map (" and "generic map (" with a space before the parenthesis
    - "then" on the same line as its if/elsif
    - no column alignment: no run of two or more spaces inside code
    - exactly one space before an end-of-line comment
    - a header block ("-- Module Name:") near the top of each file
Exit status 1 if anything is found. Generated files are checked too.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent


def split_code_comment(line):
    """Return (code, comment) with string and character literals blanked out in code."""
    code = []
    i = 0
    in_str = False
    while i < len(line):
        c = line[i]
        if in_str:
            code.append("_" if c != '"' else '"')
            if c == '"':
                in_str = False
        elif c == '"':
            in_str = True
            code.append(c)
        elif c == "'" and i + 2 < len(line) and line[i + 2] == "'" and \
                (i == 0 or not (line[i - 1].isalnum() or line[i - 1] == ")")):
            code.append("'_'")
            i += 2
        elif c == "-" and line[i:i + 2] == "--":
            return "".join(code), line[i:]
        else:
            code.append(c)
        i += 1
    return "".join(code), ""


def check(path):
    problems = []
    text = path.read_bytes()
    try:
        lines = text.decode("ascii").split("\n")
    except UnicodeDecodeError:
        return ["%s: non-ASCII characters" % path]
    if not any("Module Name:" in l for l in lines[:12]):
        problems.append("%s: no header block (-- Module Name:)" % path)
    for n, line in enumerate(lines, 1):
        where = "%s:%d" % (path.relative_to(ROOT) if path.is_relative_to(ROOT) else path, n)
        line = line.rstrip(chr(13))
        if line.rstrip() != line:
            problems.append(where + ": trailing whitespace")
        if line.startswith(" "):
            problems.append(where + ": indentation with spaces")
        code, comment = split_code_comment(line.rstrip())
        stripped = code.strip()
        if not stripped:
            continue
        for op in ("<=", "=>", ":="):
            for m in re.finditer(re.escape(op), code):
                before = code[m.start() - 1] if m.start() > 0 else " "
                after = code[m.end()] if m.end() < len(code) else " "
                if op == "<=" and before in "<>/=":
                    continue
                if before not in " \t" or after not in " \t":
                    problems.append(where + ": no space around %s" % op)
        if re.search(r",[^ \t]", code.rstrip()):
            problems.append(where + ": no space after comma")
        if re.search(r"\b(port|generic) map\(", code, re.IGNORECASE):
            problems.append(where + ": missing space in 'map ('")
        if re.fullmatch(r"then", stripped, re.IGNORECASE):
            problems.append(where + ": 'then' on its own line")
        if re.search(r"\S {2,}\S", code.strip()):
            problems.append(where + ": column alignment (two or more spaces)")
        if comment and code.strip():
            if not code.endswith(" ") or code.endswith("  ") or code.endswith("\t"):
                problems.append(where + ": need exactly one space before the comment")
    return problems


def main():
    files = [Path(a).resolve() for a in sys.argv[1:]] or \
        sorted(list((ROOT / "rtl").rglob("*.vhd")) + list((ROOT / "sim").rglob("*.vhd")))
    problems = []
    for f in files:
        problems += check(f)
    for p in problems:
        print(p)
    print("%d files, %d problems" % (len(files), len(problems)))
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
