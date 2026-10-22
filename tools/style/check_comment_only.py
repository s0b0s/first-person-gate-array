"""Check that the edits since a snapshot changed only comments (and blank lines).

Usage: python tools/style/check_comment_only.py <snapshot dir> [paths...]
Compares every .vhd under rtl/ and sim/ (or the given paths) with the same file in the
snapshot, after removing comments, trailing spaces and blank lines. Exit status 1 if code
changed anywhere.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_vhdl_style import split_code_comment  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent.parent


def code_of(path):
    out = []
    for line in path.read_text(encoding="ascii").split("\n"):
        code, _ = split_code_comment(line.rstrip())
        if code.strip():
            out.append(code.rstrip())
    return out


def main():
    snap = Path(sys.argv[1]).resolve()
    files = [Path(a).resolve() for a in sys.argv[2:]] or \
        sorted(list((ROOT / "rtl").rglob("*.vhd")) + list((ROOT / "sim").rglob("*.vhd")))
    bad = []
    for f in files:
        rel = f.relative_to(ROOT)
        old = snap / rel
        if not old.exists() or code_of(old) != code_of(f):
            bad.append(str(rel))
    for b in bad:
        print("code changed:", b)
    print("%d files compared, %d with code changes" % (len(files), len(bad)))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
