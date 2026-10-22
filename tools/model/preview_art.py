"""Write build/preview/art_sheet.png: every sprite frame on one contact sheet."""

import struct
import sys
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import art  # noqa: E402
import palette  # noqa: E402


def main():
    blob, table = art.art_blob()
    pal = palette.palette()
    cols, cell = 10, 66
    rows = (len(table) + cols - 1) // cols
    w, h = cols * cell, rows * cell
    img = [[(40, 40, 48)] * w for _ in range(h)]
    for i, (off, fw, fh) in enumerate(table):
        ox, oy = (i % cols) * cell, (i // cols) * cell
        for u in range(fw):
            for v in range(fh):
                p = blob[off + u * fh + v]
                if p != art.T:
                    r, g, b = pal[p]
                    img[oy + v + (64 - fh)][ox + u] = (r * 4, g * 4, b * 4)
    raw = b"".join(b"\x00" + bytes(c for px in row for c in px) for row in img)

    def chunk(k, p):
        c = struct.pack(">I", len(p)) + k + p
        return c + struct.pack(">I", zlib.crc32(k + p) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    out = HERE.parent.parent / "build" / "preview" / "art_sheet.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(png)
    print("wrote", out, len(blob), "bytes of art")


if __name__ == "__main__":
    main()
