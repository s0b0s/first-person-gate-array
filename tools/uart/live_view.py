# Inline dependency list (PEP 723), read by "uv run"; plain "python" ignores it.
# /// script
# requires-python = ">=3.9"
# dependencies = ["pyserial", "pygame-ce"]
# ///
"""Live picture of the game over the Cmod's USB-UART, in a window that works like a monitor.

    uv run tools/uart/live_view.py            (or double-click tools/uart/live_view.bat)
    uv run tools/uart/live_view.py --selftest round-trip test of the stream decoder, and
                                              stream sizes and frame rates for model frames

Nothing to press: it finds the board's port, finds the link rate (12 Mbaud, else 4 or 1
Mbaud) and shows frames until the window is closed. Unplugging, resetting or reprogramming the board
shows "waiting for board" in the title bar and it reconnects by itself.

Two ways to get frames:
    stream   bitstreams with the 'V' command: the board sends each new front buffer,
             run-length encoded and, in current bitstreams, only where it changed since
             the frame before (delta frames; a key frame with every pixel when the
             viewer asks, e.g. after a damaged frame) (rtl/debug/debug_port.vhd)
    polling  older bitstreams: read the display status word for the front buffer, then
             the 76,800 bytes with 'M'
Both can tear (a frame swap during the transfer); the debug_uart.py "capture" command
freezes the game for exact dumps.

Colors follow rtl/display/display_pixel.vhd: palette (tools/model/palette.py; the game
never rewrites it), then the screen tint, then the 2x2 dither. The dither is shown as its
average over the 2x2 block (what the eye sees), not pixel by pixel. Test patterns and
blanking are drawn the same way the display path draws them. Light levels are already in
the framebuffer (the renderer applies the light tables), so nothing else is needed.
Player input stays on the PS/2 keyboard and mouse; this window sends the game nothing.
"""

import os
import sys
import threading
import time
from collections import deque
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "model"))
import debug_uart as du  # noqa: E402

W, H = du.WIDTH, du.HEIGHT
SCALE = 3  # Starting window size: 960 x 720
PATTERN_BANDS, PATTERN_CHECKER, PATTERN_GRID, PATTERN_GRADIENT = 1, 2, 3, 4  # game_pkg
TINTS = {1: (63, 0, 0), 2: (63, 52, 0), 3: (0, 63, 0)}  # game_pkg TINT_RED, TINT_GOLD, TINT_GREEN
TITLE = "First-Person Gate Array"


# ----------------------------------------------------------------------------------------
# What the VGA output shows (rtl/display/display_pixel.vhd)
# ----------------------------------------------------------------------------------------
def dac_level(c6):
    """8-bit brightness of a 6-bit channel after the 2x2 dither: the four pixels of the
    block show min(15, (c + d) / 4) for d = 0..3, a 4-bit DAC level each (17 per step)."""
    return round(sum(min(15, (c6 + d) >> 2) for d in range(4)) * 17 / 4)


def vga_palette(tint):
    """256 RGB colors for one screen tint: (3 c + t) / 4 per channel, then the dither."""
    from palette import palette
    t = TINTS.get(tint)
    out = []
    for rgb in palette():
        if t:
            rgb = [(3 * c + tc) >> 2 for c, tc in zip(rgb, t)]
        out.append(tuple(dac_level(c) for c in rgb))
    return out


def pattern_indices(pattern):
    """Palette-index picture of the checker, grid or gradient test pattern."""
    out = bytearray(W * H)
    for y in range(H):
        for x in range(W):
            border = x in (0, W - 1) or y in (0, H - 1)
            if pattern == PATTERN_CHECKER:
                v = 0x0F if border else (0x07 if (x ^ y) & 1 else 0x00)
            elif pattern == PATTERN_GRID:
                v = 0x0F if border or x % 8 == 0 or y % 8 == 0 else 0x00
            else:  # gradient: 32x32 screen-pixel cells, 20 per row
                v = ((y >> 4) * 20 + (x >> 4)) & 0xFF
            out[y * W + x] = v
    return bytes(out)


def bands_rgb():
    """The 12 color bands: band i lights only output bit 11 - i (R3 first, B0 last), no
    palette, tint or dither. 640-pixel band edges 20 + 50 i and 62 + 50 i are even, so
    they fall on game pixel 10 + 25 i and 31 + 25 i."""
    row = bytearray(3 * W)
    for i in range(12):
        chan, bit = i // 4, 3 - i % 4
        for x in range(10 + 25 * i, 31 + 25 * i):
            row[3 * x + chan] = (1 << bit) * 17
    return bytes(row) * H


# ----------------------------------------------------------------------------------------
# The link (background thread)
# ----------------------------------------------------------------------------------------
class Link(threading.Thread):
    QUIET = 1.5  # Seconds without a frame before the board is checked and the stream restarted

    def __init__(self):
        super().__init__(daemon=True)
        self.lock = threading.Lock()
        self.stopping = threading.Event()
        self.frame = None
        self.serial = 0           # Frames received so far (the window redraws when it changes)
        self.times = deque()      # Arrival times of the last few seconds of frames
        self.status = "waiting for board"
        self.dp = None

    # Shared state
    def publish(self, frame):
        now = time.monotonic()
        with self.lock:
            self.frame = frame
            self.serial += 1
            self.times.append(now)
            while self.times and now - self.times[0] > 3.0:
                self.times.popleft()

    def latest(self):
        with self.lock:
            return self.serial, self.frame

    def title(self):
        with self.lock:
            times, status = list(self.times), self.status
        if status == "waiting for board":
            return "%s - waiting for board" % TITLE
        fps = 0.0
        if len(times) >= 2 and time.monotonic() - times[-1] < 2.0:
            fps = (len(times) - 1) / (times[-1] - times[0])
        return "%s - %s - %.1f fps" % (TITLE, status, fps)

    def set_status(self, text):
        with self.lock:
            self.status = text
            if text == "waiting for board":
                self.times.clear()

    # Thread body: connect, run, and on any trouble start over
    def run(self):
        while not self.stopping.is_set():
            try:
                self.session()
            except Exception:
                pass
            finally:
                if self.dp:
                    self.dp.close()
                    self.dp = None
            self.set_status("waiting for board")
            self.stopping.wait(0.5)

    def session(self):
        ports = du.board_ports()
        if not ports:
            return
        for port in ports:
            try:
                self.dp = du.DebugPort.connect(port)
                break
            except Exception:
                self.dp = None
        if not self.dp:
            return
        dp = self.dp
        build = dp.read_reg(0)
        rate = "%d Mbaud" % (dp.baud // 1_000_000)
        if dp.stream(True):
            self.set_status("%s %s stream" % (dp.port, rate))
            self.run_stream(dp)
        else:
            self.set_status("%s %s polling" % (dp.port, rate))
            self.run_poll(dp, build)

    def run_stream(self, dp):
        dec = du.StreamDecoder()
        dp.ser.timeout = 0.1
        last = asked = time.monotonic()
        try:
            while not self.stopping.is_set():
                data = dp.ser.read(max(1, dp.ser.in_waiting))
                now = time.monotonic()
                for frame in dec.feed(data):
                    self.publish(frame)
                    last = now
                if dec.need_key and now - asked > 1.0:
                    # A delta frame could not be applied: ask for a whole frame. Its 'K'
                    # arrives between frames and the decoder skips it.
                    dp.ser.write(b"V\x01")
                    asked = now
                if now - last > self.QUIET:
                    # No frames: game frozen, board reset (stream off) or reprogrammed. A
                    # ping tells which; restarting the stream also sends one frame at once.
                    if not dp.sync() or not dp.stream(True):
                        return
                    dp.ser.timeout = 0.1
                    dec = du.StreamDecoder()
                    last = time.monotonic()
        finally:
            if self.stopping.is_set():
                # Leave the board quiet for debug_uart.py
                dp.ser.write(b"V\x00")
                dp.drain(limit=1.0)

    def run_poll(self, dp, build):
        # The display word: 16 in the games, 28 in the bring-up design (0 in older builds)
        bringup = (build >> 8) & 0xFF == 0x00
        word = 28 if bringup else 16
        old = (build & 0xFF) < 2  # Builds before the display word: use the PC overrides
        n = 0
        while not self.stopping.is_set():
            w = dp.read_reg(word)
            front, tint, pattern, blank = (w >> 2) & 1, (w >> 4) & 3, (w >> 8) & 7, (w >> 12) & 1
            if old:
                ctrl = dp.read_reg(32)
                tint = (ctrl >> 12) & 3
                pattern = (ctrl >> 4) & 7 if ctrl & 0x80 else 0
            pixels = dp.read_sram(du.FB_BASE[front], du.NPIX)
            n += 1
            self.publish(du.Frame(n, 1 | (blank << 1) | (pattern << 4), tint, 0, pixels))


# ----------------------------------------------------------------------------------------
# The window (main thread)
# ----------------------------------------------------------------------------------------
def frame_surface(pygame, frame, palettes, patterns):
    if frame.blank:
        surf = pygame.Surface((W, H))
        surf.fill((0, 0, 0))
        return surf
    if frame.pattern == PATTERN_BANDS:
        return pygame.image.frombuffer(patterns[PATTERN_BANDS], (W, H), "RGB")
    # Checker, grid and gradient replace the framebuffer; patterns 0 and 5..7 show it
    surf = pygame.image.frombuffer(patterns.get(frame.pattern, frame.pixels), (W, H), "P")
    surf.set_palette(palettes[frame.tint & 3])
    return surf


def view():
    os.environ.setdefault("PYGAME_HIDE_SUPPORT_PROMPT", "1")
    import pygame
    pygame.init()
    screen = pygame.display.set_mode((W * SCALE, H * SCALE), pygame.RESIZABLE)
    pygame.display.set_caption(TITLE + " - waiting for board")
    palettes = [vga_palette(t) for t in range(4)]
    patterns = {p: pattern_indices(p) for p in (PATTERN_CHECKER, PATTERN_GRID, PATTERN_GRADIENT)}
    patterns[PATTERN_BANDS] = bands_rgb()

    link = Link()
    link.start()
    clock = pygame.time.Clock()
    shown, surf, dirty, next_title = -1, None, True, 0.0
    running = True
    while running:
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False
            elif event.type in (pygame.VIDEORESIZE, pygame.WINDOWSIZECHANGED, pygame.WINDOWEXPOSED):
                dirty = True
        serial, frame = link.latest()
        if serial != shown and frame is not None:
            shown = serial
            try:
                surf = frame_surface(pygame, frame, palettes, patterns)
            except Exception:
                surf = None
            dirty = True
        if dirty:
            # Largest 4:3 picture that fits, centered, nearest-neighbor scaled
            sw, sh = screen.get_size()
            scale = min(sw / W, sh / H)
            dw, dh = max(1, int(W * scale)), max(1, int(H * scale))
            screen.fill((0, 0, 0))
            if surf is not None:
                screen.blit(pygame.transform.scale(surf, (dw, dh)), ((sw - dw) // 2, (sh - dh) // 2))
            pygame.display.flip()
            dirty = False
        now = time.monotonic()
        if now >= next_title:
            pygame.display.set_caption(link.title())
            next_title = now + 0.5
        clock.tick(60)
    link.stopping.set()
    link.join(2.0)
    pygame.quit()


# ----------------------------------------------------------------------------------------
# Self test: decoder round trip and stream sizes
# ----------------------------------------------------------------------------------------
def selftest():
    import random
    rng = random.Random(1)
    golden = HERE.parent.parent / "sim" / "golden"

    def load(path):
        rows = path.read_text().split()
        return bytes(int(r[i:i + 2], 16) for r in rows for i in range(0, len(r), 2))

    samples = []
    for name in ("page_expected.txt", "frame4_0.txt", "frame4_5.txt", "frame4_12.txt", "frame4_20.txt"):
        if (golden / name).exists():
            samples.append((name, load(golden / name)))
    samples.append(("random noise (worst case)", bytes(rng.randrange(256) for _ in range(du.NPIX))))
    samples.append(("all 255 (ESC)", bytes([255]) * du.NPIX))
    samples.append(("flat color", bytes([17]) * du.NPIX))

    # Round trip: every sample through the stream in random chunk sizes, with junk before
    # it and a damaged frame in the middle that must be skipped
    stream = b"K\x00junk" + b"".join(du.stream_frame(p, n) for n, (_, p) in enumerate(samples))
    damaged = bytearray(du.stream_frame(samples[0][1], 99))
    damaged[len(damaged) // 2] ^= 0x55
    stream += bytes(damaged) + du.stream_frame(samples[1][1], 100)
    dec, got, i = du.StreamDecoder(), [], 0
    while i < len(stream):
        n = rng.randrange(1, 5000)
        got += dec.feed(stream[i:i + n])
        i += n
    want = [(n, p) for n, (_, p) in enumerate(samples)] + [(100, samples[1][1])]
    ok = [(f.number, f.pixels) for f in got] == want
    print("decoder round trip (%d frames, junk, one damaged frame skipped): %s"
          % (len(want), "PASS" if ok else "FAIL"))

    # Delta frames: a key frame, then deltas; a damaged delta sets need_key and frames are
    # dropped until the next key frame
    page = samples[0][1]
    page2 = bytearray(page)
    for i in range(3000, 3400):          # a few counter digits change
        page2[i] ^= 0x0A
    page2 = bytes(page2)
    seq = [(0, page, None), (1, page2, page), (2, page2, page2), (3, page, page2)]
    stream = b"".join(du.stream_frame(p, n, prev=b) for n, p, b in seq)
    dec, got = du.StreamDecoder(), []
    for i in range(0, len(stream), 777):
        got += dec.feed(stream[i:i + 777])
    ok_d = [(f.number, f.pixels) for f in got] == [(n, p) for n, p, _ in seq]
    bad = bytearray(du.stream_frame(page, 4, prev=page))
    bad[12] ^= 0x01
    got2 = dec.feed(bytes(bad)) + dec.feed(du.stream_frame(page2, 5, prev=page))
    ok_k = dec.need_key and not got2
    got3 = dec.feed(du.stream_frame(page2, 6))
    ok_k = ok_k and [f.number for f in got3] == [6] and not dec.need_key
    print("delta frames round trip: %s; damaged delta -> key frame needed, then recovered: %s"
          % ("PASS" if ok_d else "FAIL", "PASS" if ok_k else "FAIL"))
    ok = ok and ok_d and ok_k

    print("\n%-34s %8s %7s %9s %9s" % ("frame", "bytes", "ratio", "12 Mbaud", "4 Mbaud"))
    rows = [(name, len(du.stream_frame(p))) for name, p in samples]
    rows.append(("page, a few digits changed (delta)", len(du.stream_frame(page2, prev=page))))
    rows.append(("page, nothing changed (delta)", len(du.stream_frame(page, prev=page))))
    frames4 = [p for name, p in samples if name.startswith("frame4")]
    if len(frames4) >= 2:
        rows.append(("game view to another (delta)", len(du.stream_frame(frames4[1], prev=frames4[0]))))
    for name, size in rows:
        print("%-34s %8d %6.2fx %6.1f fps %6.1f fps" % (name, size, du.NPIX / size,
              min(60.0, 12e6 / 10 / size), min(60.0, 4e6 / 10 / size)))
    print("%-34s %8d %7s %6.1f fps %6.1f fps" % ("polling ('M', any frame)", du.NPIX, "-",
          12e6 / 10 / du.NPIX, 4e6 / 10 / du.NPIX))
    print("(frame rates are link limits, capped at the game's 60)")
    return 0 if ok else 1


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    view()
