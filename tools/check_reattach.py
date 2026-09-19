"""Does a program source really come back when its program is opened again.

    python tools/check_reattach.py

Tony, 19 September 2026: "i noticed it wouldn't once i opened chrome again,
drop deck was looking for chrome's specific window or whatever. just
chrome.exe". A capture belongs to one process, and a program opened again is
a new process with a new number.

This is the proof and the only thing that can be: a real program playing a
real tone is captured, closed, and started again as a NEW process playing a
DIFFERENT tone, while the frame's own watcher runs. It passes only if the
source says it went, says it came back, and then carries the new tone. The
tests in tests/test_3_8_3.py stand the program in with a fake, which proves
the wiring and nothing about Windows.

The program is pythonw.exe playing through the default output, so this makes
two short quiet tones on the speakers. It says "skipped" if pythonw.exe is
already running, because then it cannot tell its own program from yours.
"""

import os
import subprocess
import sys
import tempfile
import textwrap
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.environ["APPDATA"] = tempfile.mkdtemp(prefix="dropdeck-reattach-")

import numpy as np
import wx

from dropdeck import constants as C
from dropdeck import proccapture
from dropdeck.ui import DropDeckFrame

RATE = 48000
FAILED = []

TONE = textwrap.dedent('''
    import sys, time
    import numpy as np, sounddevice as sd
    HZ = float(sys.argv[1])
    phase = 0.0
    def callback(outdata, frames, time_info, status):
        global phase
        step = 2.0 * np.pi * HZ / 48000
        t = phase + step * np.arange(frames)
        phase = float((t[-1] + step) % (2.0 * np.pi))
        wave = (0.12 * np.sin(t)).astype(np.float32)
        outdata[:] = np.repeat(wave[:, None], outdata.shape[1], axis=1)
    with sd.OutputStream(samplerate=48000, channels=2, dtype="float32",
                         callback=callback, blocksize=480):
        time.sleep(float(sys.argv[2]))
''')


def say(label, ok, extra=""):
    if not ok:
        FAILED.append(label)
    print(("  ok   " if ok else "  FAIL ") + label
          + (("  " + str(extra)) if extra != "" else ""))


def loudest(block, rate):
    """The strongest frequency, at the rate the source DELIVERS at.

    A source is resampled to the output's rate, not to any fixed one: here
    the first run of this read 653 Hz for a 600 Hz tone, which is exactly
    48000 over 44100, the rate this machine's output runs at.
    """
    if not len(block) or float(np.abs(block[:, 0]).max()) < 1e-4:
        return None
    mono = block[:, 0].astype(np.float64)
    spectrum = np.abs(np.fft.rfft(mono * np.hanning(len(mono))))
    return float(np.fft.rfftfreq(len(mono), 1.0 / rate)[
        int(np.argmax(spectrum))])


def pythonw():
    return os.path.join(os.path.dirname(sys.executable), "pythonw.exe")


def main():
    if not proccapture.supported():
        print("  skip this Windows cannot capture one program")
        return 0
    if proccapture.is_running("pythonw.exe"):
        print("  skip pythonw.exe is already running here, so this could not "
              "tell its own program from yours")
        return 0
    script = os.path.join(tempfile.mkdtemp(), "tone.py")
    with open(script, "w", encoding="utf-8") as handle:
        handle.write(TONE)

    app = wx.App(False)
    frame = DropDeckFrame(None)
    said = []
    frame.speaker.say = lambda text, *a, **k: said.append(text)
    frame.board.speech_level = C.SPEECH_ALL

    first = subprocess.Popen([pythonw(), script, "600", "30"])
    time.sleep(2.5)
    frame.apply_sources([{"name": "Tone", "kind": "program",
                          "program": "pythonw.exe", "monitor": True,
                          "on_air": True}])
    source = frame.sources[0]
    say("the program source opens", source.is_open, source.last_error)
    time.sleep(1.0)
    rate = frame.mixer.samplerate
    heard = loudest(source.read(rate), rate)
    say("and hears the first program", heard and abs(heard - 600) < 20, heard)

    def watch(seconds, until):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            frame._next_source_watch = 0.0
            frame._watch_program_sources()
            if until():
                return True
            time.sleep(0.25)
        return False

    first.terminate()
    first.wait(5)
    gone = watch(8, lambda: any("closed" in s for s in said))
    say("closing it is noticed and said", gone, said[-1:])
    say("and the source is no longer capturing", not source.is_open)

    second = subprocess.Popen([pythonw(), script, "900", "30"])
    try:
        back = watch(C.SOURCE_SETTLE_SECONDS + 12,
                     lambda: any(" is back" in s for s in said))
        say("the program opened again, a new process, is found by name",
            back, said[-1:])
        say("and it really is capturing again", source.is_open,
            source.last_error)
        time.sleep(1.0)
        source.read(rate)                     # what built up while waiting
        time.sleep(1.0)
        heard = loudest(source.read(rate), rate)
        say("and hears the NEW program, not silence",
            heard and abs(heard - 900) < 20, heard)
    finally:
        second.terminate()
        frame.stop_sources()
        frame.stop_background_work()
        frame.mixer.close()
        frame.Destroy()

    print()
    print("%d FAILED" % len(FAILED) if FAILED else
          "A program source comes back by itself.")
    return 1 if FAILED else 0


if __name__ == "__main__":
    code = main()
    sys.stdout.flush()
    os._exit(code)
