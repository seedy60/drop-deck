# The repository root is on the path already, put there by cross_check.py.
#
# Test the cable: the verdict half of dropdeck/cabletest.py against the Mac's
# CableTest.swift. The recording is made by hand here and in the Swift half the
# same way, so the level to six places, the share of silence, the number of
# gaps and every sentence have to agree. Nothing here opens a sound card.
#
# Every signal is built from the same arithmetic on both sides: the level
# times the sine of (2 pi hz / rate) times the sample number, in double
# precision, then cast to single, exactly as cabletest.tone makes it.
import numpy as np

from dropdeck import cabletest as T

out = []
out.append("const|%s|%s|%s|%s|%s|%s|%s" % (
    T.TONE_HZ, T.TONE_LEVEL, T.SECONDS, T.GAP_BELOW, T.GAP_BLOCK, T.ARRIVED_DB,
    T.GAP_SHARE_OK))


def tone(count, rate, hz=1000.0, level=0.3):
    block, _ = T.tone(count, rate, 0.0, hz=hz, level=level)
    return block[:, 0].copy()


def holes(signal, every, length, start=0):
    signal = signal.copy()
    for at in range(start, len(signal), every):
        signal[at:at + length] = 0.0
    return signal


CASES = []
CASES.append(("clean48", tone(48000, 48000), 48000, "Drop Deck Audio"))
CASES.append(("clean44", tone(77175, 44100), 44100, ""))
CASES.append(("clean96", tone(96000, 96000), 96000, "Loopback Audio"))
CASES.append(("silence", np.zeros(48000, dtype=np.float32), 48000, "x"))
CASES.append(("quiet", tone(48000, 48000, level=0.0005), 48000, ""))
CASES.append(("faint", tone(48000, 48000, level=0.002), 48000, ""))
CASES.append(("holed", holes(tone(48000, 48000), 4800, 240), 48000, ""))
CASES.append(("many", holes(tone(48000, 48000), 640, 64), 48000, ""))
CASES.append(("late", holes(tone(48000, 48000), 480000, 4800), 48000, "late"))
CASES.append(("tiny", np.full(10, 0.5, dtype=np.float32), 48000, ""))
CASES.append(("short", tone(100, 48000), 48000, ""))
CASES.append(("low", tone(48000, 48000, hz=961.0), 48000, ""))
CASES.append(("high", tone(48000, 48000, hz=1039.5), 48000, ""))
CASES.append(("off", tone(48000, 48000, hz=1200.0), 48000, ""))
CASES.append(("loud", tone(47999, 48000, level=0.99), 48000, ""))

for name, signal, rate, heard in CASES:
    signal = np.asarray(signal, dtype=np.float32)
    out.append("level|%s|%.6f" % (name, T.level_at(signal, rate)))
    share, runs = T.silence_in(signal)
    out.append("silence|%s|%.6f|%d" % (name, share, runs))
    result = T.judge(signal, rate, heard)
    out.append("judge|%s|%s|%d|%s" % (name, result.ok, result.rate, result.said))

print("\n".join(out))
