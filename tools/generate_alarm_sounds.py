"""Generate bundled alarm WAV tones for the Care Cube app.

Synthesizes short loopable tones with the standard library only.
Output: care_cube/assets/audio/*.wav
"""
import math
import os
import struct
import wave

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "audio")

RATE = 22050


def write_wav(name, samples):
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, name)
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(
            struct.pack("<h", max(-32767, min(32767, int(s * 32767))))
            for s in samples
        ))
    print(f"wrote {path} ({len(samples) / RATE:.1f}s)")


def t_seconds(n):
    return [i / RATE for i in range(n)]


def envelope(dur, attack=0.01, release=0.05):
    def env(t):
        a = 1.0
        if t < attack:
            a = t / attack
        if dur - t < release:
            a = min(a, (dur - t) / release)
        return a
    return env


def silence(dur):
    return [0.0] * int(dur * RATE)


def tone(freq, dur, volume=0.85):
    env = envelope(dur)
    return [volume * env(t) * math.sin(2 * math.pi * freq * t) for t in t_seconds(int(dur * RATE))]


def add_into(base, offset_s, samples):
    start = int(offset_s * RATE)
    for i, s in enumerate(samples):
        idx = start + i
        if idx < len(base):
            base[idx] += s
    return base


def loopable(*segments):
    """Concatenate segments and fade the join to avoid clicks on loop."""
    out = []
    for seg in segments:
        out.extend(seg)
    fade = int(0.003 * RATE)
    n = len(out)
    for i in range(fade):
        f = i / fade
        out[n - fade + i] *= min(1.0, f)
        out[i] *= min(1.0, f)
    return out


def classic_beep():
    # short square-ish bursts via harmonics, classic 'beep-beep'
    segs = []
    for _ in range(2):
        burst = [0.0] * int(0.30 * RATE)
        burst = add_into(burst, 0.0, tone(880, 0.26, 0.7))
        burst = [min(1.0, max(-1.0, s * 2.0)) for s in burst]
        segs.append(burst)
        segs.append(silence(0.22))
    return loopable(*segs)


def siren():
    # rising/falling two-tone
    total = int(3.0 * RATE)
    out = [0.0] * total
    env = envelope(3.0, 0.05, 0.05)
    for i in range(total):
        t = i / RATE
        f = 660 + 280 * math.sin(2 * math.pi * 0.8 * t)
        out[i] = env(t) * 0.7 * math.sin(2 * math.pi * f * t)
    return out


def urgent():
    # fast high double-pulse
    segs = []
    for _ in range(2):
        segs.append(tone(1200, 0.12, 0.8))
        segs.append(silence(0.05))
        segs.append(tone(1200, 0.12, 0.8))
        segs.append(silence(0.10))
    return loopable(*segs)


def gentle_chime():
    # soft chime: two overlapping sine notes with slow decay
    dur = 1.8
    out = [0.0] * int(dur * RATE)
    out = add_into(out, 0.0, tone(523, 1.6, 0.5))
    out = add_into(out, 0.0, tone(659, 1.4, 0.4))
    out = add_into(out, 0.25, tone(784, 1.2, 0.35))
    return out


if __name__ == "__main__":
    write_wav("alarm_classic.wav", classic_beep())
    write_wav("alarm_siren.wav", siren())
    write_wav("alarm_urgent.wav", urgent())
    write_wav("alarm_gentle.wav", gentle_chime())