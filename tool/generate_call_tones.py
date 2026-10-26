#!/usr/bin/env python3
"""Regenerates assets/calls/ringtone.wav and ringback.wav (8 kHz, mono, 16 bit).

The tones are synthesised, so the repository carries no third party audio:
  ringback: 440 + 480 Hz, 1.2 s on, 2.8 s off (what the caller hears).
  ringtone: two 0.35 s warbles of 880/1100 Hz, then silence (what the callee
            hears while the app is in the foreground).
Both loop seamlessly: they start and end in silence.
"""
import math
import struct
import wave

RATE = 8000


def tone(freqs, seconds, volume=0.5, fade=0.02):
    n = int(RATE * seconds)
    out = []
    for i in range(n):
        t = i / RATE
        s = sum(math.sin(2 * math.pi * f * t) for f in freqs) / len(freqs)
        edge = min(i, n - 1 - i) / (RATE * fade)
        out.append(s * volume * min(1.0, edge))
    return out


def silence(seconds):
    return [0.0] * int(RATE * seconds)


def write(path, samples):
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(
            b''.join(struct.pack('<h', int(max(-1, min(1, s)) * 32767)) for s in samples)
        )


ringback = tone([440, 480], 1.2) + silence(2.8)
warble = tone([880], 0.175) + tone([1100], 0.175)
ringtone = warble + silence(0.15) + warble + silence(2.15)

write('assets/calls/ringback.wav', ringback)
write('assets/calls/ringtone.wav', ringtone)
