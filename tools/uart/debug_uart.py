# Inline dependency list (PEP 723), read by "uv run"; plain "python" ignores it.
# /// script
# requires-python = ">=3.9"
# dependencies = ["pyserial"]
# ///
"""PC side of the UART debug port (rtl/debug/debug_port.vhd).

Needs pyserial: "pip install -r requirements.txt", or run through uv, which reads the
dependency list at the top of this file:
    uv run tools/uart/debug_uart.py auto ping

Port names differ per computer (COM3... on Windows, /dev/ttyUSB1 on Linux,
/dev/tty.usbserial-... on macOS); list them with "ports", or give "auto" to pick the Cmod by
its FTDI USB ID (0403). The FTDI chip has two channels, A JTAG and B UART; Windows usually
lists only B, Linux both (the UART is the second, ttyUSB1).

The link rate is found by itself: 4 Mbaud first (current bitstreams), then 1 Mbaud (older
ones). A frame stream left running (live_view.py) is stopped first.

Usage (or "uv run" in place of "python"; "auto" or a port name in place of COM5):
    python tools/uart/debug_uart.py ports                  list serial ports, board marked
    python tools/uart/debug_uart.py COM5 ping
    python tools/uart/debug_uart.py COM5 status            all 32 status words
    python tools/uart/debug_uart.py COM5 read 33           one register
    python tools/uart/debug_uart.py COM5 write 32 0x101    one control register
    python tools/uart/debug_uart.py COM5 dump 0 out.png    framebuffer 0 or 1 to PNG
    python tools/uart/debug_uart.py COM5 peek 0x220000 16  hex dump of SRAM bytes
    python tools/uart/debug_uart.py COM5 capture out.png   maze game: freeze, dump the
        front buffer and the pose, render the same frame with the Python model, compare
        pixel by pixel, then unfreeze
For a live picture, run tools/uart/live_view.py (or double-click live_view.bat).
"""

import struct
import sys
import time
import zlib

BAUDS = (4_000_000, 1_000_000)  # Tried in this order
FB_BASE = (0x00000, 0x20000)
WIDTH, HEIGHT = 320, 240
NPIX = WIDTH * HEIGHT


class DebugPort:
    def __init__(self, port, baud=BAUDS[0]):
        try:
            import serial  # pyserial, imported here so --help works without it
        except ImportError:
            sys.exit("pyserial is missing: run 'pip install -r requirements.txt', or run this "
                     "script with 'uv run' instead of 'python'")
        self.port, self.baud = port, baud
        self.ser = serial.Serial(port, baud, timeout=2)
        self.ser.reset_input_buffer()

    @classmethod
    def connect(cls, port, bauds=BAUDS):
        """Open the port at the first rate the board answers on."""
        for baud in bauds:
            dp = cls(port, baud)
            if dp.sync():
                return dp
            dp.close()
        raise IOError("no answer from the board on %s at %s baud" %
                      (port, " or ".join(str(b) for b in bauds)))

    def close(self):
        try:
            self.ser.close()
        except Exception:
            pass

    def drain(self, quiet=0.05, limit=0.15):
        """Discard input until the line has been silent for quiet seconds; False if it is
        still busy after limit seconds (a frame stream is running)."""
        self.ser.timeout = quiet
        end = time.monotonic() + limit
        try:
            while time.monotonic() < end:
                if not self.ser.read(65536):
                    return True
            return False
        finally:
            self.ser.timeout = 2

    def send_spaced(self, data):
        """Send bytes 2 ms apart. At the wrong rate each byte then reaches the board as a
        short burst that decodes to 0xFC..0xFF (bits 2..7 see the idle line), never a
        command, so probing cannot write anything."""
        for b in data:
            self.ser.write(bytes([b]))
            self.ser.flush()
            time.sleep(0.002)

    def sync(self):
        """Stop a running frame stream, then check the link with a ping."""
        if not self.drain():
            self.send_spaced(b"V\x00")       # the board finishes its frame, then says K
            if not self.drain(limit=2.0):
                return False
        self.ser.reset_input_buffer()
        self.ser.timeout = 0.3
        try:
            self.send_spaced(b"P")
            return self.ser.read(1) == b"K"
        finally:
            self.ser.timeout = 2

    def _read(self, n):
        data = self.ser.read(n)
        if len(data) != n:
            raise IOError("expected %d bytes, got %d" % (n, len(data)))
        return data

    def ping(self):
        self.ser.write(b"P")
        return self._read(1) == b"K"

    def read_reg(self, n):
        self.ser.write(b"R" + bytes([n]))
        return struct.unpack("<I", self._read(4))[0]

    def write_reg(self, n, value):
        self.ser.write(b"W" + bytes([n]) + struct.pack("<I", value))
        if self._read(1) != b"K":
            raise IOError("register write not acknowledged")

    def read_sram(self, addr, length):
        out = b""
        # Chunks keep each command short enough for the 2 s read timeout
        while length > 0:
            n = min(length, 65536)
            self.ser.write(b"M" + struct.pack("<I", addr)[:3] + struct.pack("<I", n)[:3])
            out += self._read(n)
            addr += n
            length -= n
        return out

    def write_sram(self, addr, data):
        self.ser.write(b"S" + struct.pack("<I", addr)[:3] + struct.pack("<I", len(data))[:3] + data)
        if self._read(1) != b"K":
            raise IOError("SRAM write not acknowledged")

    def stream(self, on):
        """Frame stream on or off; False if the bitstream has no 'V' command."""
        self.ser.write(b"V" + bytes([1 if on else 0]))
        reply = self._read(1)
        if reply == b"?":
            self._read(1)  # the argument byte was taken as a second unknown command
            return False
        return reply == b"K"


# ----------------------------------------------------------------------------------------
# Frame stream ('V'): 'F', frame number (2 bytes), pixel count (3), flags, tint, palette
# count, RLE data, 16-bit pixel sum (2). RLE: a byte other than ESC is one pixel; ESC n v
# is n pixels of value v.
# ----------------------------------------------------------------------------------------
ESC = 0xFF
HEADER = 9


def encode_rle(pixels):
    """The debug port's encoder in Python (for tests and size estimates)."""
    out = bytearray()

    def flush(v, n):
        if n >= 3 or v == ESC:
            out.extend((ESC, n, v))
        else:
            out.extend(bytes((v,)) * n)
    run_v, run_n = 0, 0
    for p in pixels:
        if run_n and (p != run_v or run_n == 255):
            flush(run_v, run_n)
            run_n = 0
        run_v, run_n = p, run_n + 1
    flush(run_v, run_n)
    return bytes(out)


def stream_frame(pixels, number=0, flags=1, tint=0, pal_count=0):
    """One whole stream frame as the debug port sends it."""
    head = b"F" + struct.pack("<H", number & 0xFFFF) + struct.pack("<I", len(pixels))[:3]
    head += bytes((flags, tint, pal_count))
    return head + encode_rle(pixels) + struct.pack("<H", sum(pixels) & 0xFFFF)


class Frame:
    def __init__(self, number, flags, tint, pal_count, pixels):
        self.number, self.flags, self.tint, self.pal_count = number, flags, tint, pal_count
        self.pixels = pixels
        self.blank = bool(flags & 2)
        self.pattern = (flags >> 4) & 7


class StreamDecoder:
    """Turns stream bytes into Frames. Feed it whatever arrives; damaged frames (bad
    header, wrong sum) are skipped and the decoder looks for the next 'F'."""

    def __init__(self, npix=NPIX):
        self.npix = npix
        self.buf = bytearray()
        self.bad = 0        # damaged frames and junk bytes skipped
        self._reset()

    def _reset(self):
        self.head = None    # header fields once a plausible header is seen
        self.out = bytearray()
        self.pos = 0        # next unread byte of buf

    def _resync(self):
        """Drop the frame start in buf and look for the next 'F'."""
        self.bad += 1
        nxt = self.buf.find(b"F", 1)
        del self.buf[:nxt if nxt > 0 else len(self.buf)]
        self._reset()

    def feed(self, data):
        self.buf += data
        frames = []
        while True:
            if self.head is None:
                start = self.buf.find(b"F")
                if start < 0:
                    self.bad += 1 if self.buf else 0
                    self.buf.clear()
                    return frames
                if start:
                    self.bad += 1
                    del self.buf[:start]
                if len(self.buf) < HEADER:
                    return frames
                h = self.buf
                count = h[3] | (h[4] << 8) | (h[5] << 16)
                flags = h[6]
                if count != self.npix or not flags & 1 or flags & 0x8C or h[7] > 3:
                    self._resync()
                    continue
                self.head = (h[1] | (h[2] << 8), flags, h[7], h[8])
                self.pos = HEADER
            # RLE data: copy literal stretches between ESC bytes in one go
            buf, out, need = self.buf, self.out, self.npix
            while len(out) < need and self.pos < len(buf):
                esc = buf.find(ESC, self.pos)
                end = len(buf) if esc < 0 else esc
                take = min(end - self.pos, need - len(out))
                out += buf[self.pos:self.pos + take]
                self.pos += take
                if len(out) == need or esc < 0 or self.pos < esc:
                    continue
                if esc + 2 >= len(buf):
                    break                       # the run's n and v have not arrived yet
                n, v = buf[esc + 1], buf[esc + 2]
                if n == 0 or len(out) + n > need:
                    break
                out += bytes((v,)) * n
                self.pos = esc + 3
            if len(out) < need:
                if self.pos + 2 < len(buf) and buf[self.pos] == ESC and \
                        (buf[self.pos + 1] == 0 or len(out) + buf[self.pos + 1] > need):
                    self._resync()              # impossible run: damaged frame
                    continue
                return frames
            if len(buf) < self.pos + 2:
                return frames
            if buf[self.pos] | (buf[self.pos + 1] << 8) != sum(out) & 0xFFFF:
                self._resync()
                continue
            number, flags, tint, pal = self.head
            frames.append(Frame(number, flags, tint, pal, bytes(out)))
            del self.buf[:self.pos + 2]
            self._reset()


MODEL_DIR = __import__("pathlib").Path(__file__).resolve().parent.parent / "model"


def default_palette():
    """The power-on palette (tools/model/palette.py)."""
    sys.path.insert(0, str(MODEL_DIR))
    from palette import palette
    return [(r * 255 // 63, g * 255 // 63, b * 255 // 63) for r, g, b in palette()]


def capture(dp, png_path):
    """Freeze the game, dump the front buffer and pose, compare with the model."""
    sys.path.insert(0, str(MODEL_DIR))
    import render
    import palette as pal_mod
    import textures
    import level as level_mod
    ctrl = dp.read_reg(32)
    dp.write_reg(32, ctrl | (1 << 16))       # freeze: no new frames, front buffer stays
    try:
        time.sleep(0.1)
        front = (dp.read_reg(16) >> 2) & 1  # bit 0 pcb_on, 1 locked, 2 front
        px, py = dp.read_reg(1), dp.read_reg(2)
        w3 = dp.read_reg(3)
        angle, eye = w3 & 1023, (w3 >> 16) & 127
        doors = []
        for k in range(8):
            d = dp.read_reg(17 + k)
            if (d >> 12) & 127:
                doors.append((d & 63, (d >> 6) & 63, (d >> 12) & 127))
        data = dp.read_sram(FB_BASE[front], WIDTH * HEIGHT)
    finally:
        dp.write_reg(32, ctrl)
    write_png(png_path, data, default_palette())
    lights = pal_mod.light_table(pal_mod.palette())
    tiles = level_mod.level1().tile_words()
    image, _ = render.render_frame(render.Frame(px, py, angle, eye, doors), tiles,
                                   textures.wall_textures(), textures.flat_textures(), lights)
    diff = sum(1 for a, b in zip(data, image) if a != b)
    print("pose x=%.4f y=%.4f angle=%d eye=%d doors=%s" % (px / 65536, py / 65536, angle, eye, doors))
    print("board CRC32 %08X  model CRC32 %08X  differing pixels: %d"
          % (zlib.crc32(data) & 0xFFFFFFFF, zlib.crc32(bytes(image)) & 0xFFFFFFFF, diff))


def write_png(path, indices, pal):
    raw = b""
    for y in range(HEIGHT):
        raw += b"\x00" + b"".join(bytes(pal[i]) for i in indices[y * WIDTH:(y + 1) * WIDTH])

    def chunk(kind, payload):
        c = struct.pack(">I", len(payload)) + kind + payload
        return c + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(png)


FTDI_VID = 0x0403  # the Cmod's USB chip (FT2232H): one channel JTAG, one UART


def list_ports():
    try:
        from serial.tools import list_ports as lp
    except ImportError:
        sys.exit("pyserial is missing: run 'pip install -r requirements.txt', or run this "
                 "script with 'uv run' instead of 'python'")
    return sorted(lp.comports(), key=lambda p: p.device)


def is_uart_channel(p):
    """Channel B of the FT2232H: Windows gives it a serial number ending in B, Linux and
    macOS an interface location ending in .1 (channel A is .0)."""
    return (p.serial_number or "").endswith("B") or (p.location or "").endswith(".1")


def board_ports():
    """Candidate Cmod UARTs: the FTDI ports on channel B, or every FTDI port if none is."""
    ftdi = [p for p in list_ports() if p.vid == FTDI_VID]
    return [p.device for p in ([p for p in ftdi if is_uart_channel(p)] or ftdi)]


def find_board_port():
    """The Cmod's UART for the command line: exactly one candidate, or exit."""
    uart = board_ports()
    if len(uart) == 1:
        return uart[0]
    if not uart:
        sys.exit("no FTDI serial port found: is the Cmod plugged in? "
                 "('ports' lists what there is)")
    sys.exit("several FTDI serial ports (%s): give the port name instead of 'auto'" %
             ", ".join(uart))


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "ports":
        for p in list_ports():
            mark = "  <- Cmod UART" if p.vid == FTDI_VID and is_uart_channel(p) else ""
            print("%-24s %s%s" % (p.device, p.description, mark))
        return
    if len(sys.argv) < 3:
        print(__doc__)
        return
    port, cmd, args = sys.argv[1], sys.argv[2], sys.argv[3:]
    if port == "auto":
        port = find_board_port()
    try:
        dp = DebugPort.connect(port)
    except IOError as e:
        sys.exit(str(e))
    print("using %s at %d baud" % (port, dp.baud))
    if cmd == "ping":
        print("OK" if dp.ping() else "no answer")
    elif cmd == "status":
        for n in range(32):
            print("%2d  %08X" % (n, dp.read_reg(n)))
    elif cmd == "read":
        print("%08X" % dp.read_reg(int(args[0], 0)))
    elif cmd == "write":
        dp.write_reg(int(args[0], 0), int(args[1], 0))
    elif cmd == "dump":
        data = dp.read_sram(FB_BASE[int(args[0])], WIDTH * HEIGHT)
        write_png(args[1], data, default_palette())
        print("wrote", args[1], "CRC32 %08X" % (zlib.crc32(data) & 0xFFFFFFFF))
    elif cmd == "capture":
        capture(dp, args[0] if args else "capture.png")
    elif cmd == "peek":
        addr, n = int(args[0], 0), int(args[1], 0)
        data = dp.read_sram(addr, n)
        for i in range(0, n, 16):
            print("%05X  %s" % (addr + i, " ".join("%02X" % b for b in data[i:i + 16])))
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
