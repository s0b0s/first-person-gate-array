# Inline dependency list (PEP 723). Plain "python" ignores it; with uv installed,
# "uv run tools/uart/debug_uart.py ..." reads it and fetches pyserial by itself.
# /// script
# requires-python = ">=3.9"
# dependencies = ["pyserial"]
# ///
"""PC side of the UART debug port (rtl/debug/debug_port.vhd).

Needs pyserial, the only package outside the standard library that any tool here uses.
Either install it once:
    pip install -r requirements.txt
or, with uv (https://docs.astral.sh/uv/), skip installing and run the script through uv,
which reads the dependency list at the top of this file:
    uv run tools/uart/debug_uart.py auto ping

The serial port name depends on the computer (COM3, COM7... on Windows, /dev/ttyUSB1 on Linux,
/dev/tty.usbserial-... on macOS), so COM5 below is only an example. Find it with
    python tools/uart/debug_uart.py ports
or give "auto" as the port: it picks the Cmod's UART by its USB ID (FTDI, vendor 0403).
The Cmod's FTDI chip has two channels: A is JTAG (programming), B is the UART. Windows usually
lists only B as a COM port; Linux lists both, and the UART is the second (ttyUSB1).

Usage (or "uv run" in place of "python"; "auto" or a port name in place of COM5):
    python tools/uart/debug_uart.py ports                  list serial ports, board marked
    python tools/uart/debug_uart.py COM5 ping
    python tools/uart/debug_uart.py COM5 status            all 32 status words
    python tools/uart/debug_uart.py COM5 read 33           one register
    python tools/uart/debug_uart.py COM5 write 32 0x101    one control register
    python tools/uart/debug_uart.py COM5 dump 0 out.png    framebuffer 0 or 1 to PNG
    python tools/uart/debug_uart.py COM5 peek 0x220000 16  hex dump of SRAM bytes
    python tools/uart/debug_uart.py COM5 capture out.png   stage-1 game: freeze, dump the
        front buffer and the pose, render the same frame with the Python model, compare
        pixel by pixel, then unfreeze
"""

import struct
import sys
import zlib

BAUD = 1_000_000
FB_BASE = (0x00000, 0x20000)
WIDTH, HEIGHT = 320, 240


class DebugPort:
    def __init__(self, port):
        try:
            import serial  # pyserial, imported here so --help works without it
        except ImportError:
            sys.exit("pyserial is missing: run 'pip install -r requirements.txt', or run this "
                     "script with 'uv run' instead of 'python'")
        self.ser = serial.Serial(port, BAUD, timeout=2)
        self.ser.reset_input_buffer()

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


MODEL_DIR = __import__("pathlib").Path(__file__).resolve().parent.parent / "model"


def default_palette():
    """The power-on palette (tools/model/palette.py)."""
    sys.path.insert(0, str(MODEL_DIR))
    from palette import palette
    return [(r * 255 // 63, g * 255 // 63, b * 255 // 63) for r, g, b in palette()]


def capture(dp, png_path):
    """Freeze the game, dump the front buffer and pose, compare with the model."""
    sys.path.insert(0, str(MODEL_DIR))
    import time
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


def find_board_port():
    """The Cmod's UART: the FTDI port on channel B, or the only FTDI port there is."""
    ftdi = [p for p in list_ports() if p.vid == FTDI_VID]
    uart = [p for p in ftdi if is_uart_channel(p)] or ftdi
    if len(uart) == 1:
        return uart[0].device
    if not uart:
        sys.exit("no FTDI serial port found: is the Cmod plugged in? "
                 "('ports' lists what there is)")
    sys.exit("several FTDI serial ports (%s): give the port name instead of 'auto'" %
             ", ".join(p.device for p in uart))


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
        print("using", port)
    dp = DebugPort(port)
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
