"""Synthesises the Tropa event sounds (mono 16-bit WAV, standard library only).

Usage: python tools/make_sounds.py <output_dir> [set ...]
Sets: A (clean synth motif), B (glass bell), C (soft pluck). Each set gets one WAV per event plus demo_<set>.wav
with all events one after another (for listening).
"""
import math
import os
import struct
import sys
import wave

RATE = 44100

# Note names -> frequency
def hz(name):
    names = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
    n = names[name[0]]
    octave = int(name[-1])
    semis = n + 12 * (octave - 4) - 9  # relative to A4
    return 440.0 * 2 ** (semis / 12)


# --- timbres: f(freq, t, dur) -> sample in -1..1 (before the envelope of the note)

def timbre_synth(f, t, dur):
    return math.sin(2 * math.pi * f * t) + 0.3 * math.sin(4 * math.pi * f * t) + 0.1 * math.sin(6 * math.pi * f * t)


def timbre_bell(f, t, dur):
    index = 2.5 * math.exp(-t * 5)
    return math.sin(2 * math.pi * f * t + index * math.sin(2 * math.pi * f * 2.0 * t))


def timbre_pluck(f, t, dur):
    s = 0.0
    for n in range(1, 7):
        s += math.sin(2 * math.pi * f * n * t) * math.exp(-t * (6 + 9 * n)) / (n * n)
    return s * 2.2


TIMBRES = {
    "A": (timbre_synth, 0.004, 9.0),   # attack s, decay rate per second
    "B": (timbre_bell, 0.002, 4.5),
    "C": (timbre_pluck, 0.002, 5.0),
}


def tone(f, dur, timbre, vol=0.6, tail=0.25):
    fn, attack, decay = timbre
    n = int((dur + tail) * RATE)
    out = []
    for i in range(n):
        t = i / RATE
        env = min(1.0, t / attack) * math.exp(-t * decay * (1.0 if t > dur else 0.35))
        # hard release at the end of the note body so notes do not smear into the next one
        out.append(fn(f, t, dur) * env * vol)
    return out


def thump(f0, dur, vol=0.8):
    # low "knock": a sine whose pitch falls quickly
    n = int(dur * RATE)
    out = []
    phase = 0.0
    for i in range(n):
        t = i / RATE
        f = f0 * (1 + 0.8 * math.exp(-t * 30))
        phase += 2 * math.pi * f / RATE
        out.append(math.sin(phase) * math.exp(-t * 18) * vol)
    return out


def mix(parts):
    """parts: list of (start_seconds, samples)"""
    end = max(int(s * RATE) + len(x) for s, x in parts)
    buf = [0.0] * end
    for s, x in parts:
        o = int(s * RATE)
        for i, v in enumerate(x):
            buf[o + i] += v
    peak = max(1e-9, max(abs(v) for v in buf))
    scale = min(1.0, 0.89 / peak)
    return [v * scale for v in buf]


def seq(notes, timbre, vol=0.6):
    """notes: list of (name, start_seconds, duration)"""
    return mix([(s, tone(hz(n), d, timbre, vol)) for n, s, d in notes])


def build(set_name):
    tm = TIMBRES[set_name]
    sounds = {
        "start": seq([("E5", 0.00, 0.07), ("B5", 0.10, 0.12)], tm),
        "stop": seq([("B5", 0.00, 0.07), ("E5", 0.10, 0.14)], tm),
        "half": seq([("E5", 0.00, 0.08), ("A5", 0.11, 0.14), ("E5", 0.45, 0.08), ("B5", 0.56, 0.22)], tm),
        "goal": seq([("C5", 0.00, 0.14), ("E5", 0.16, 0.14), ("G5", 0.32, 0.14), ("C6", 0.50, 0.55)], tm, 0.65),
        "offroute": mix([(0.0, thump(95, 0.30)), (0.32, thump(95, 0.30))]),
        "back": seq([("G5", 0.00, 0.30), ("D6", 0.02, 0.45)], tm, 0.5),
        "gps_off": seq([("A5", 0.00, 0.16), ("E5", 0.20, 0.16), ("A5", 0.40, 0.16), ("E5", 0.60, 0.16), ("A5", 0.80, 0.16), ("E5", 1.00, 0.16)], tm, 0.75),
        "hint": seq([("E6", 0.00, 0.06)], tm, 0.3),
        "turn_left": seq([("G5", 0.00, 0.07), ("D5", 0.09, 0.10)], tm, 0.55),
        "turn_right": seq([("D5", 0.00, 0.07), ("G5", 0.09, 0.10)], tm, 0.55),
    }
    return sounds


def write_wav(path, samples):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, v)) * 32767)) for v in samples))


def main():
    out = sys.argv[1]
    sets = sys.argv[2:] or ["A", "B", "C"]
    for s in sets:
        sounds = build(s)
        d = os.path.join(out, s)
        os.makedirs(d, exist_ok=True)
        demo = []
        for name, data in sounds.items():
            write_wav(os.path.join(d, name + ".wav"), data)
            demo += data + [0.0] * int(0.9 * RATE)
        write_wav(os.path.join(out, "demo_" + s + ".wav"), demo)
        print("set", s, "->", d)


if __name__ == "__main__":
    main()
