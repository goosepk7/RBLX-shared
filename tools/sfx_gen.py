#!/usr/bin/env python3
"""Procedural SFX for RBLX-shared (brief §10): layered synthesis rendered to .ogg.

    python3 tools/sfx_gen.py            # writes assets/sfx/*.ogg
    python3 tools/sfx_gen.py --check    # renders to a temp dir, fails if any file differs
    python3 tools/sfx_gen.py --list     # names and durations

Needs numpy and ffmpeg (libvorbis). Every sound is a pure function of its name and a fixed seed,
and ffmpeg runs in bit-exact mode, so the output is byte-stable and `--check` can run in CI.
After regenerating, refresh the manifest hashes:
    lune run tools/verify_assets --fix-hashes && lune run tools/gen_asset_ids

Sounds here are the framework's UI and feedback set (§5.7): click, hover, open, close, tab,
toast, pop, success, fail, thump, plus purchase, win, checkpoint, unlock and gameplay fail.
Repeated sounds get 3-4 variations (`sfx_ui_click_1` .. `_4`); shared Audio picks one at random
and never repeats the last. Game-specific sounds (footfalls, engines) live in each game repo.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import subprocess
import sys
import tempfile
import wave

import numpy as np

RATE = 44100
OUT_DIR = os.path.join("assets", "sfx")
PEAK = 10 ** (-3 / 20)  # normalize to -3 dBFS


# --- building blocks -------------------------------------------------------------------------

def t_axis(seconds: float) -> np.ndarray:
    return np.arange(int(RATE * seconds)) / RATE


def env(seconds: float, attack: float, decay: float, curve: float = 4.0) -> np.ndarray:
    """Linear attack then exponential decay (time constant decay / curve) to the end."""
    t = t_axis(seconds)
    a = np.clip(t / max(attack, 1e-4), 0, 1)
    d = np.exp(-np.maximum(t - attack, 0) * curve / max(decay, 1e-4))
    return a * d


def sine(freq, seconds: float, phase: float = 0.0) -> np.ndarray:
    """`freq` may be a number or an array (a sweep); integrates the phase."""
    n = int(RATE * seconds)
    f = np.broadcast_to(np.asarray(freq, dtype=float), (n,))
    return np.sin(2 * np.pi * np.cumsum(f) / RATE + phase)


def sweep(f0: float, f1: float, seconds: float, shape: float = 1.0) -> np.ndarray:
    x = np.linspace(0, 1, int(RATE * seconds)) ** shape
    return f0 * (f1 / f0) ** x  # exponential (musical) sweep


def soft_square(freq, seconds: float, drive: float = 3.0) -> np.ndarray:
    return np.tanh(drive * sine(freq, seconds)) / np.tanh(drive)


def saw(freq: float, seconds: float, partials: int = 12) -> np.ndarray:
    out = np.zeros(int(RATE * seconds))
    for k in range(1, partials + 1):
        out += sine(freq * k, seconds) / k
    return out * 0.6


def noise(rng: np.random.Generator, seconds: float) -> np.ndarray:
    return rng.uniform(-1, 1, int(RATE * seconds))


def lowpass(x: np.ndarray, cutoff: float) -> np.ndarray:
    """One-pole low-pass, run twice for a 12 dB/oct slope."""
    a = np.exp(-2 * np.pi * cutoff / RATE)
    for _ in range(2):
        y = np.empty_like(x)
        acc = 0.0
        for i, v in enumerate(x):
            acc = (1 - a) * v + a * acc
            y[i] = acc
        x = y
    return x


def highpass(x: np.ndarray, cutoff: float) -> np.ndarray:
    return x - lowpass(x, cutoff)


def bell(freq: float, seconds: float, decay: float, brightness: float = 1.0) -> np.ndarray:
    """Inharmonic partials of a small bell / glass."""
    ratios = [(1.0, 1.0), (2.76, 0.45 * brightness), (5.40, 0.22 * brightness), (8.93, 0.10 * brightness)]
    out = np.zeros(int(RATE * seconds))
    for ratio, amp in ratios:
        out += amp * sine(freq * ratio, seconds) * env(seconds, 0.002, decay / ratio ** 0.5)
    return out


def pluck(freq: float, seconds: float, decay: float = 0.25) -> np.ndarray:
    tone = 0.7 * sine(freq, seconds) + 0.25 * sine(freq * 2, seconds) + 0.1 * sine(freq * 3, seconds)
    return tone * env(seconds, 0.003, decay)


def place(total: float, *parts: tuple[float, np.ndarray]) -> np.ndarray:
    """Mixes (start_seconds, signal) parts into one buffer of `total` seconds."""
    out = np.zeros(int(RATE * total))
    for start, sig in parts:
        i = int(RATE * start)
        j = min(len(out), i + len(sig))
        out[i:j] += sig[: j - i]
    return out


def note(name: str) -> float:
    """'C5' -> Hz (A4 = 440)."""
    names = {"C": -9, "D": -7, "E": -5, "F": -4, "G": -2, "A": 0, "B": 2}
    semis = names[name[0]]
    rest = name[1:]
    if rest.startswith("#"):
        semis += 1
        rest = rest[1:]
    elif rest.startswith("b"):
        semis -= 1
        rest = rest[1:]
    octave = int(rest)
    return 440.0 * 2 ** ((semis + (octave - 4) * 12) / 12)


def finish(x: np.ndarray, fade_ms: float = 6.0) -> np.ndarray:
    x = x - np.mean(x)
    n = int(RATE * fade_ms / 1000)
    if n > 0 and len(x) > 2 * n:
        x[:n] *= np.linspace(0, 1, n)
        x[-n:] *= np.linspace(1, 0, n)
    peak = np.max(np.abs(x))
    if peak > 0:
        x = x * (PEAK / peak)
    return x


# --- the sounds ------------------------------------------------------------------------------

def ui_click(rng, v: int):
    # A tactile tick: short filtered noise transient over a pitched blip. Variations shift the
    # pitch a few semitones so rapid tapping doesn't sound mechanical.
    d = 0.06
    f = [1900, 2100, 1750, 2300][v - 1]
    tick = highpass(noise(rng, d), 2500) * env(d, 0.0005, 0.008, 6)
    blip = sine(sweep(f * 1.15, f, d, 0.5), d) * env(d, 0.001, 0.035)
    body = sine(f / 4, d) * env(d, 0.001, 0.02) * 0.4
    return 0.5 * tick + blip + body


def ui_hover(rng, v: int):
    d = 0.05
    f = [2600, 2900, 2400][v - 1]
    return sine(f, d) * env(d, 0.004, 0.03) * 0.6 + 0.08 * highpass(noise(rng, d), 4000) * env(d, 0.001, 0.01)


def ui_open(rng, _v):
    d = 0.16
    tone = soft_square(sweep(420, 980, d, 0.8), d, 1.5) * env(d, 0.01, 0.14, 3)
    air = lowpass(noise(rng, d), 3000) * env(d, 0.03, 0.1) * 0.2
    return tone + air


def ui_close(rng, _v):
    d = 0.15
    tone = soft_square(sweep(900, 400, d, 0.8), d, 1.5) * env(d, 0.005, 0.13, 3)
    air = lowpass(noise(rng, d), 2500) * env(d, 0.01, 0.08) * 0.2
    return tone + air


def ui_tab(rng, _v):
    # Wood-block knock.
    d = 0.09
    return (
        sine(sweep(820, 700, d, 0.3), d) * env(d, 0.001, 0.05, 5)
        + 0.5 * sine(1640, d) * env(d, 0.001, 0.02, 5)
        + 0.25 * lowpass(noise(rng, d), 1800) * env(d, 0.0005, 0.01)
    )


def ui_toast(_rng, _v):
    d = 0.42
    return place(d, (0, bell(note("E6"), d, 0.35, 0.6)), (0.07, 0.7 * bell(note("B6"), d - 0.07, 0.3, 0.5)))


def ui_pop(rng, v: int):
    # Bubble pop: fast upward sweep with a tiny noise burst.
    d = 0.08
    f0, f1 = [(320, 1300), (380, 1500), (280, 1150)][v - 1]
    bubble = sine(sweep(f0, f1, d, 0.6), d) * env(d, 0.001, 0.05, 4)
    burst = highpass(noise(rng, d), 3000) * env(d, 0.0005, 0.006, 6) * 0.35
    return bubble + burst


def ui_success(_rng, _v):
    d = 0.5
    c, e, g = note("C5"), note("E5"), note("G5")
    return place(
        d,
        (0.00, pluck(c, 0.45, 0.22)),
        (0.07, pluck(e, 0.40, 0.22)),
        (0.14, pluck(g, 0.36, 0.3)),
        (0.14, 0.35 * bell(note("G6"), 0.36, 0.3, 0.4)),
    )


def ui_fail(_rng, _v):
    # Two falling square-ish tones a semitone apart: a friendly "bwomp", not a buzzer.
    d = 0.42
    first = soft_square(sweep(note("A3"), note("G#3"), 0.18), 0.18, 2) * env(0.18, 0.005, 0.16, 2)
    second = soft_square(sweep(note("F3"), note("E3"), 0.26), 0.26, 2) * env(0.26, 0.005, 0.24, 3)
    return lowpass(place(d, (0, first), (0.15, second)), 1800)


def ui_thump(rng, _v):
    # Bass thump for big NumberPops: pitch-dropping sine kick plus a soft click.
    d = 0.3
    kick = sine(sweep(140, 48, d, 0.35), d) * env(d, 0.002, 0.22, 3)
    click = lowpass(noise(rng, d), 1200) * env(d, 0.0005, 0.012, 6) * 0.5
    return kick + click


def fx_purchase(rng, _v):
    # Coin chime with shimmer: two bright bells and a sprinkle of high ticks.
    d = 0.75
    sparkle = np.zeros(int(RATE * d))
    for i in range(6):
        start = 0.05 + i * 0.06
        f = rng.uniform(4200, 6400)
        tick = sine(f, 0.05) * env(0.05, 0.001, 0.03)
        sparkle += place(d, (start, tick * 0.2))
    return place(d, (0, bell(note("G6"), 0.7, 0.5)), (0.08, 0.9 * bell(note("C7"), 0.67, 0.55))) + sparkle


def fx_win(_rng, _v):
    # Rising chime, C major up an octave, bell on top.
    d = 0.9
    parts = [(0.00, "C6"), (0.07, "E6"), (0.14, "G6"), (0.21, "C7")]
    sig = [(start, pluck(note(n), d - start, 0.3) * (0.8 + 0.1 * i)) for i, (start, n) in enumerate(parts)]
    sig.append((0.21, 0.6 * bell(note("C7"), d - 0.21, 0.6)))
    return place(d, *sig)


def fx_checkpoint(_rng, _v):
    d = 0.6
    return bell(note("A5"), d, 0.45, 0.7) + 0.3 * sine(note("A4"), d) * env(d, 0.004, 0.3)


def fx_unlock(_rng, _v):
    # Short fanfare: brassy (filtered saw) G-C-E-G with a held C major chord.
    d = 1.3
    hits = [(0.00, "G4", 0.12), (0.12, "C5", 0.12), (0.24, "E5", 0.12)]
    parts = []
    for start, n, length in hits:
        parts.append((start, lowpass(saw(note(n), length), 2600) * env(length, 0.01, length, 2)))
    chord_len = d - 0.36
    chord = sum(lowpass(saw(note(n), chord_len), 2200) for n in ["C5", "E5", "G5", "C6"])
    parts.append((0.36, chord * env(chord_len, 0.02, chord_len, 2.2)))
    parts.append((0.36, 0.5 * bell(note("C7"), chord_len, 0.6)))
    return place(d, *parts)


def fx_fail(rng, _v):
    # Gameplay fail: low thud and a short down-sweep (pairs with camera shake).
    d = 0.45
    thud = sine(sweep(110, 40, d, 0.4), d) * env(d, 0.002, 0.3, 3)
    dust = lowpass(noise(rng, d), 600) * env(d, 0.002, 0.15) * 0.6
    tone = soft_square(sweep(note("D4"), note("A3"), 0.3), 0.3, 1.5) * env(0.3, 0.01, 0.28, 3) * 0.35
    return thud + dust + place(d, (0.03, tone))


SOUNDS: dict[str, tuple] = {
    # name: (function, variations)
    "sfx_ui_click": (ui_click, 4),
    "sfx_ui_hover": (ui_hover, 3),
    "sfx_ui_open": (ui_open, 0),
    "sfx_ui_close": (ui_close, 0),
    "sfx_ui_tab": (ui_tab, 0),
    "sfx_ui_toast": (ui_toast, 0),
    "sfx_ui_pop": (ui_pop, 3),
    "sfx_ui_success": (ui_success, 0),
    "sfx_ui_fail": (ui_fail, 0),
    "sfx_ui_thump": (ui_thump, 0),
    "sfx_purchase": (fx_purchase, 0),
    "sfx_win": (fx_win, 0),
    "sfx_checkpoint": (fx_checkpoint, 0),
    "sfx_unlock": (fx_unlock, 0),
    "sfx_fail": (fx_fail, 0),
}


def render_all() -> dict[str, np.ndarray]:
    out: dict[str, np.ndarray] = {}
    for base, (fn, variations) in SOUNDS.items():
        for v in range(1, variations + 1) if variations else [0]:
            name = f"{base}_{v}" if variations else base
            seed = int.from_bytes(hashlib.sha256(name.encode()).digest()[:8], "little")
            rng = np.random.default_rng(seed)
            out[name] = finish(np.asarray(fn(rng, v), dtype=float))
    return out


def _ogg_crc_table() -> list[int]:
    table = []
    for i in range(256):
        r = i << 24
        for _ in range(8):
            r = ((r << 1) ^ 0x04C11DB7) if r & 0x80000000 else (r << 1)
        table.append(r & 0xFFFFFFFF)
    return table


_OGG_CRC = _ogg_crc_table()


def fix_ogg_serial(data: bytes, serial: int = 0x52424C58) -> bytes:
    """ffmpeg picks a random Ogg stream serial even in bit-exact mode. Rewrite it in every
    page (and the page CRC) so the file is byte-stable."""
    out = bytearray(data)
    pos = 0
    while pos < len(out):
        if out[pos : pos + 4] != b"OggS":
            raise ValueError(f"not an Ogg page at byte {pos}")
        segments = out[pos + 26]
        header_len = 27 + segments
        body_len = sum(out[pos + 27 : pos + 27 + segments])
        end = pos + header_len + body_len
        out[pos + 14 : pos + 18] = serial.to_bytes(4, "little")
        out[pos + 22 : pos + 26] = b"\0\0\0\0"
        crc = 0
        for byte in out[pos:end]:
            crc = ((crc << 8) & 0xFFFFFFFF) ^ _OGG_CRC[((crc >> 24) & 0xFF) ^ byte]
        out[pos + 22 : pos + 26] = crc.to_bytes(4, "little")
        pos = end
    return bytes(out)


def write_ogg(samples: np.ndarray, path: str) -> None:
    pcm = (np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes()
    with tempfile.TemporaryDirectory() as tmp:
        wav_path = os.path.join(tmp, "in.wav")
        with wave.open(wav_path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(pcm)
        subprocess.run(
            [
                "ffmpeg", "-y", "-loglevel", "error", "-fflags", "+bitexact", "-i", wav_path,
                "-map_metadata", "-1", "-c:a", "libvorbis", "-q:a", "5", "-flags:a", "+bitexact",
                os.path.join(tmp, "out.ogg"),
            ],
            check=True,
        )
        with open(os.path.join(tmp, "out.ogg"), "rb") as f:
            data = fix_ogg_serial(f.read())
    with open(path, "wb") as f:
        f.write(data)


def sha256(path: str) -> str:
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="fail if assets/sfx differs from a fresh render")
    parser.add_argument("--list", action="store_true", help="print names and durations")
    parser.add_argument("--out", default=OUT_DIR)
    args = parser.parse_args()

    sounds = render_all()
    if args.list:
        for name, samples in sounds.items():
            print(f"{name:24s} {len(samples) / RATE:.2f} s")
        return 0

    if args.check:
        bad = []
        with tempfile.TemporaryDirectory() as tmp:
            for name, samples in sounds.items():
                fresh = os.path.join(tmp, name + ".ogg")
                write_ogg(samples, fresh)
                committed = os.path.join(args.out, name + ".ogg")
                if not os.path.exists(committed) or sha256(committed) != sha256(fresh):
                    bad.append(name)
        if bad:
            print("FAIL sfx_gen: out of date: " + ", ".join(bad) + " (run python3 tools/sfx_gen.py)")
            return 1
        print(f"PASS sfx_gen: {len(sounds)} sounds match")
        return 0

    os.makedirs(args.out, exist_ok=True)
    for name, samples in sounds.items():
        write_ogg(samples, os.path.join(args.out, name + ".ogg"))
    print(f"wrote {len(sounds)} sounds to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
