"""Build build/gamedata.bin, the game-data image placed in flash at 0x220000.

Layout (all numbers little endian; offsets are from the start of the image):

    0x0000  8 bytes   magic "SHOOTER0" (the stage-0 bring-up page shows these bytes)
    0x0008  u16       format version (1)
    0x000A  u16       number of directory entries N
    0x000C  N x 12    directory: u32 id, u32 offset, u32 length
    ...               items, each aligned to 256 bytes

Items:
    id 0       test pattern, 4096 bytes, byte i = (7 * i + 3) mod 256 (UART read tests)
    id 1..3    levels 1..3 (tools/model/level.py Level.binary()): 4096 tile words of 3 bytes,
               little endian, index y * 64 + x; start x, start y (u32, Q6.16), start angle
               (u16); actor count (u16) and that many 8-byte actor records; level number (u8)
    id 8       sprite art, 197,632 bytes, column-major frames (tools/model/art.py)
    id 16..33  sound effects 0..17, 11,025 Hz 8-bit unsigned (tools/model/audio.py)
    id 40..42  music loops for levels 1..3, 11,025 Hz 8-bit unsigned

The image must stay under 1,966,080 bytes
(the space between 0x220000 and the end of the 4 MB flash).

scripts/build.tcl puts this file after the bitstream when it exists.

Usage: python tools/flash_image/make_gamedata.py
"""

import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
OUT = ROOT / "build" / "gamedata.bin"
MAX_BYTES = 0x400000 - 0x220000
ITEM_ALIGN = 256

ID_TEST_PATTERN = 0
ID_LEVEL = 1          # + level number - 1
ID_ART = 8
ID_SOUND = 16         # + sound id
ID_MUSIC = 40         # + level - 1


def test_pattern():
    return bytes((7 * i + 3) & 0xFF for i in range(4096))


def build(items):
    header_len = 12 + 12 * len(items)
    offset = (header_len + ITEM_ALIGN - 1) // ITEM_ALIGN * ITEM_ALIGN
    directory = b""
    body = b""
    for item_id, data in items:
        directory += struct.pack("<III", item_id, offset, len(data))
        pad = (-len(data)) % ITEM_ALIGN
        body += data + b"\xFF" * pad
        offset += len(data) + pad
    header = b"SHOOTER0" + struct.pack("<HH", 1, len(items)) + directory
    header += b"\xFF" * ((-len(header)) % ITEM_ALIGN)
    image = header + body
    assert len(image) <= MAX_BYTES, "game data too large: %d bytes" % len(image)
    return image


def main():
    sys.path.insert(0, str(ROOT / "tools" / "model"))
    import art
    import audio
    import level
    items = [(ID_TEST_PATTERN, test_pattern())]
    for n, make in enumerate(level.LEVELS):
        items.append((ID_LEVEL + n, make().binary()))
    items.append((ID_ART, art.art_blob()[0]))
    for sid, blob in enumerate(audio.sound_blobs()):
        items.append((ID_SOUND + sid, blob))
    for n, blob in enumerate(audio.music_blobs()):
        items.append((ID_MUSIC + n, blob))
    image = build(items)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(image)
    print("wrote %s, %d bytes" % (OUT.relative_to(ROOT), len(image)))


if __name__ == "__main__":
    main()
