"""Sound effects, music and the bit-accurate mixer model.

Assets (original, synthesized here from integer noise and simple waves): 18 sound effects and
3 music loops, 11,025 Hz, 8-bit unsigned (128 = silence), stored in flash.

Mixer (one output sample every 2,048 system clocks = 48,828.125 Hz):
    8 effect voices + 1 music voice. Each voice: position Q.16 in its sound, advancing by
    STEP = round(11025 / 48828.125 * 65536) = 14798 per output sample; the sample used is
    byte[position >> 16] - 128 (nearest, signed). An effect voice ends at the sound's length;
    music loops.
    Effect voice gains: left = (vol * (31 - pan)) >> 5, right = (vol * (31 + pan)) >> 5
    (vol 0..63, pan -31..31). Music gain: MUSIC_VOL, halved while more than 4 effect voices
    play.
    mix = sum of sample * gain over the voices (per channel); out = sat16((mix * master) >> 4)
    with master 0..63 (default 32).
Voice allocation (DOOM rule): a new sound takes the free voice with the lowest index; if none
is free it replaces the playing sound with the lowest priority, if that priority is lower
than the new sound's (lowest index on ties); otherwise the new sound is dropped. Commands
take effect at the start of the next output sample.
"""

import math

RATE = 11025
OUT_RATE = 48828.125
STEP = int(round(RATE / OUT_RATE * 65536))
MUSIC_VOL = 40
VOICES = 8


def noise(i, seed):
    h = (i * 374761393 + seed * 668265263) & 0xFFFFFFFF
    h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
    return ((h ^ (h >> 16)) & 0xFF) - 128


def to_u8(samples):
    return bytes(max(0, min(255, int(round(s)) + 128)) for s in samples)


def env(n, attack, decay_power=1.5):
    out = []
    for i in range(n):
        a = min(1.0, i / max(1, attack))
        d = (1.0 - i / n) ** decay_power
        out.append(a * d)
    return out


def shot(n, seed, tone, gain):
    e = env(n, 20, 2.0)
    return [gain * e[i] * (noise(i, seed) * 0.8 + 40 * math.sin(2 * math.pi * tone * i / RATE))
            for i in range(n)]


def sweep(n, f0, f1, gain, square=False, seed=0, noisy=0.0):
    e = env(n, 50)
    out, ph = [], 0.0
    for i in range(n):
        f = f0 + (f1 - f0) * i / n
        ph += f / RATE
        w = (1 if (ph % 1) < 0.5 else -1) if square else math.sin(2 * math.pi * ph)
        out.append(gain * e[i] * (100 * w + noisy * noise(i, seed)))
    return out


def rumble(n, f, gain, seed):
    e = env(n, 400, 0.8)
    lp, out = 0.0, []
    for i in range(n):
        lp += (noise(i, seed) - lp) * 0.08
        out.append(gain * e[i] * (lp * 1.5 + 30 * math.sin(2 * math.pi * f * i / RATE)))
    return out


def sound_effects():
    """18 effects in sound-id order (actors.S_*)."""
    r = RATE
    return [
        shot(int(0.25 * r), 1, 180, 0.9),                    # 0 pistol
        shot(int(0.45 * r), 2, 90, 1.0),                     # 1 shotgun
        rumble(int(0.6 * r), 60, 0.9, 3),                    # 2 door open
        rumble(int(0.5 * r), 45, 0.9, 4),                    # 3 door close
        sweep(int(0.12 * r), 900, 1400, 0.7, square=True),   # 4 item
        sweep(int(0.3 * r), 500, 1500, 0.7, square=True),    # 5 weapon
        sweep(int(0.3 * r), 300, 150, 0.9, noisy=0.6, seed=5),   # 6 player pain
        sweep(int(0.9 * r), 250, 60, 1.0, noisy=0.8, seed=6),    # 7 player death
        sweep(int(0.4 * r), 200, 350, 0.8, noisy=0.5, seed=7),   # 8 monster sight
        shot(int(0.25 * r), 8, 220, 0.8),                    # 9 monster shot
        sweep(int(0.4 * r), 600, 200, 0.8, noisy=0.7, seed=9),   # 10 fireball launch
        rumble(int(0.6 * r), 80, 1.0, 10),                   # 11 explosion
        sweep(int(0.2 * r), 400, 120, 0.9, noisy=0.9, seed=11),  # 12 claw
        sweep(int(0.25 * r), 350, 200, 0.8, noisy=0.6, seed=12),  # 13 monster pain
        sweep(int(0.7 * r), 300, 50, 0.9, noisy=0.7, seed=13),    # 14 monster death
        sweep(int(0.15 * r), 1200, 800, 0.7, square=True),  # 15 switch
        sweep(int(0.25 * r), 200, 180, 0.7, square=True),   # 16 no way
        sweep(int(1.0 * r), 120, 60, 1.0, noisy=0.6, seed=16),    # 17 boss sight
    ]


SCALE = [0, 2, 3, 5, 7, 8, 10]           # natural minor


def music_loop(level, seconds=30):
    """A 30 s chiptune loop per level: square lead, triangle bass, noise hats; original notes."""
    n = int(seconds * RATE)
    bpm = 120 + 10 * level
    beat = 60.0 / bpm
    root = [57, 52, 50][level - 1]        # A3, E3, D3 (MIDI)
    out = [0.0] * n
    eighth = int(beat / 2 * RATE)
    steps = n // eighth
    ph_lead = ph_bass = 0.0
    for k in range(steps):
        bar, pos = divmod(k, 8)
        chord = [0, 5, 3, 4][bar % 4]
        deg = (chord + (noise(k, 100 + level) & 7)) % 7 if pos % 2 else chord
        lead = root + 12 + SCALE[deg % 7] + 12 * (deg // 7)
        bass = root - 12 + SCALE[chord]
        fl = 440 * 2 ** ((lead - 69) / 12)
        fb = 440 * 2 ** ((bass - 69) / 12)
        for i in range(eighth):
            j = k * eighth + i
            if j >= n:
                break
            e = (1 - i / eighth) ** 0.7
            ph_lead += fl / RATE
            ph_bass += fb / RATE
            sq = 1 if (ph_lead % 1) < 0.5 else -1
            tri = 4 * abs((ph_bass % 1) - 0.5) - 1
            hat = noise(j, 7) * (1 - i / (eighth / 4)) if i < eighth / 4 and pos % 2 == 0 else 0
            out[j] = 28 * sq * e + 40 * tri + 0.25 * hat
    return out


def sound_blobs():
    return [to_u8(s) for s in sound_effects()]


def music_blobs():
    return [to_u8(music_loop(l)) for l in (1, 2, 3)]


class Mixer:
    """Bit-accurate mixer: call command() for new sounds, then sample() once per output sample."""

    def __init__(self, sounds, music=None, master=32):
        self.sounds = sounds            # list of bytes
        self.music = music              # bytes or None
        self.master = master
        self.v = [None] * VOICES        # (sound id, position, gain_l, gain_r, priority)
        self.mpos = 0
        self.pending = []

    def command(self, sid, vol, pan, priority):
        self.pending.append((sid, vol, pan, priority))

    def _start(self, sid, vol, pan, pri):
        gl = (vol * (31 - pan)) >> 5
        gr = (vol * (31 + pan)) >> 5
        for i in range(VOICES):
            if self.v[i] is None:
                self.v[i] = [sid, 0, gl, gr, pri]
                return
        low = min(range(VOICES), key=lambda i: (self.v[i][4], i))
        if self.v[low][4] < pri:
            self.v[low] = [sid, 0, gl, gr, pri]

    def sample(self):
        for c in self.pending:
            self._start(*c)
        self.pending = []
        left = right = 0
        busy = 0
        for i in range(VOICES):
            v = self.v[i]
            if v is None:
                continue
            data = self.sounds[v[0]]
            idx = v[1] >> 16
            if idx >= len(data):
                self.v[i] = None
                continue
            s = data[idx] - 128
            left += s * v[2]
            right += s * v[3]
            v[1] += STEP
            busy += 1
        if self.music:
            s = self.music[(self.mpos >> 16) % len(self.music)] - 128
            g = MUSIC_VOL >> 1 if busy > 4 else MUSIC_VOL
            left += s * g
            right += s * g
            self.mpos += STEP
            if (self.mpos >> 16) >= len(self.music):
                self.mpos -= len(self.music) << 16

        def sat(x):
            return max(-32768, min(32767, x))
        return sat((left * self.master) >> 4), sat((right * self.master) >> 4)
