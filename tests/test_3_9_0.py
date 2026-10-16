"""3.9.0: a board that travels, and a recording that says what it is doing.

    python tests/test_3_9_0.py

Ali Moosa, 14 October 2026:

    "I exported my soundboard to Google Drive, then I try opening it again.
    It does not import the board with the original files that were part of
    the board. In my case the playlist."

A board only ever held where its sounds were on the computer it was made on,
so on any other computer every one of them was missing, even with the sounds
sitting beside the board in the same Drive folder. Three answers: a board
looks in its own folder for what is missing when it opens, a sound kept under
the board's folder is saved relative to it, and File, Export board with its
sounds makes one folder that opens anywhere, the Mac included.

Siena, October 2026, on Windows and the Mac: starting or stopping a recording
did not say whether it had started or stopped, and there was no way to pause
one. And the microphone was on the Playlist menu here and on On air on the
Mac, for no reason anybody could give.
"""

import json
import os
import shutil
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.environ["APPDATA"] = tempfile.mkdtemp(prefix="dropdeck-390-test-")

import numpy as np
import soundfile as sf
import wx

from dropdeck import board as boardmod
from dropdeck import constants as C
from dropdeck import recorder
from dropdeck.board import Board
from dropdeck.playlist import Track
from dropdeck.streamout import CHANNELS, AirBus

CHECKS = []
RATE = 48000


def check(label, condition, detail=""):
    CHECKS.append(bool(condition))
    print(("  ok   " if condition else "  FAIL ") + label
          + (("  " + str(detail)) if detail != "" and not condition else ""))


def heading(text):
    print("\n" + text)


def tone_file(folder, name, seconds=0.2, hz=440.0):
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, name)
    t = np.arange(int(RATE * seconds)) / float(RATE)
    wave = (0.2 * np.sin(2 * np.pi * hz * t)).astype(np.float32)
    sf.write(path, np.repeat(wave[:, None], 2, axis=1), RATE)
    return path


def raw(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


# ===========================================================================
heading("A sound kept beside the board is saved relative to it")

home = tempfile.mkdtemp(prefix="dropdeck-390-drive-")
show = os.path.join(home, "My show")
inside = tone_file(os.path.join(show, "Sounds"), "intro.wav")
outside_dir = tempfile.mkdtemp(prefix="dropdeck-390-elsewhere-")
outside = tone_file(outside_dir, "outro.wav")
b = Board()
b.slots[0].filepath = inside
b.slots[1].filepath = outside
b.playlist.tracks.append(Track(filepath=inside))
b.drops.paths.append(inside)
board_path = os.path.join(show, "My show.json")
b.save(board_path)
data = raw(board_path)
check("a pad under the board's folder is written relative, forward slashes",
      data["slots"][0]["filepath"] == "Sounds/intro.wav",
      data["slots"][0]["filepath"])
check("so is a playlist track",
      data["playlist"]["tracks"][0]["filepath"] == "Sounds/intro.wav",
      data["playlist"]["tracks"][0]["filepath"])
check("and a drop", data["drops"]["paths"] == ["Sounds/intro.wav"],
      data["drops"]["paths"])
check("a sound anywhere else keeps its full path",
      data["slots"][1]["filepath"] == outside, data["slots"][1]["filepath"])
check("no backslash anywhere in a relative path, because the Mac reads it",
      "\\" not in data["slots"][0]["filepath"])
check("the board in memory still holds full paths",
      os.path.isabs(b.slots[0].filepath))
again = Board.load(board_path)
check("and it loads straight back to the same files",
      os.path.normcase(again.slots[0].filepath) == os.path.normcase(inside)
      and os.path.normcase(again.playlist.tracks[0].filepath)
      == os.path.normcase(inside),
      again.slots[0].filepath)
check("with nothing missing", again.missing_count == 0, again.missing_count)
check("and nothing to report found", again.found_beside == 0)

moved = os.path.join(tempfile.mkdtemp(prefix="dropdeck-390-moved-"), "My show")
shutil.copytree(show, moved)
carried = Board.load(os.path.join(moved, "My show.json"))
check("the folder copied somewhere else entirely opens with its sounds",
      os.path.normcase(carried.slots[0].filepath)
      == os.path.normcase(os.path.join(moved, "Sounds", "intro.wav")),
      carried.slots[0].filepath)


# ===========================================================================
heading("Ali's board: opened on another computer, sounds beside it")

drive = tempfile.mkdtemp(prefix="dropdeck-390-ali-")
tone_file(os.path.join(drive, "Show sounds"), "Intro.mp3.wav")
for name in ("intro.wav", "outro.wav", "ad one.wav"):
    tone_file(os.path.join(drive, "Show sounds"), name)
ali = {
    "app": C.APP_NAME, "format": 2,
    "slots": [{"filepath": r"C:\Users\ali\Music\intro.wav"}],
    "playlist": {"tracks": [
        {"filepath": r"C:\Users\ali\Music\intro.wav"},
        {"filepath": r"C:\Users\ali\Music\ad one.wav"},
        {"filepath": "/Users/siena/Google Drive/outro.wav"},
    ]},
    "drops": {"paths": [r"D:\Drops\outro.wav"]},
}
ali_path = os.path.join(drive, "Ali show.json")
with open(ali_path, "w", encoding="utf-8") as handle:
    json.dump(ali, handle)
opened = Board.load(ali_path)
check("every pad is found beside the board", not opened.missing_slots,
      [s.filepath for s in opened.missing_slots])
check("every playlist track, including one written on a Mac",
      not opened.playlist.missing,
      [t.filepath for t in opened.playlist.missing])
check("and the drops", not opened.drops.missing, opened.drops.missing)
check("it counts what it found, drops included", opened.found_beside == 5,
      opened.found_beside)
check("and the board is NOT marked changed, because a guess is not a fact",
      opened.dirty is False)
opened.save(ali_path)
kept = raw(ali_path)
check("saving writes the paths the file had, not the guesses (Mark: an "
      "unplugged drive's path was replaced for good)",
      kept["slots"][0]["filepath"] == r"C:\Users\ali\Music\intro.wav"
      and kept["playlist"]["tracks"][1]["filepath"]
      == r"C:\Users\ali\Music\ad one.wav"
      and kept["drops"]["paths"] == [r"D:\Drops\outro.wav"],
      [kept["slots"][0]["filepath"], kept["drops"]["paths"]])
check("and a Mac path stays a Mac path, not C:\\Users\\siena",
      kept["playlist"]["tracks"][2]["filepath"]
      == "/Users/siena/Google Drive/outro.wav",
      kept["playlist"]["tracks"][2]["filepath"])
again_ali = Board.load(ali_path)
check("so the next open finds them beside the board again",
      again_ali.missing_count == 0 and again_ali.found_beside == 5,
      again_ali.found_beside)
ali_copy = os.path.join(drive, "Ali show copy.json")
shutil.copy(ali_path, ali_copy)
relinked = Board.load(ali_copy)
relinked.relink(os.path.join(drive, "Show sounds"))
relinked.save(ali_copy)
check("but a relink the user chose IS written down",
      raw(ali_copy)["slots"][0]["filepath"] != r"C:\Users\ali\Music\intro.wav",
      raw(ali_copy)["slots"][0]["filepath"])
os.remove(ali_copy)


heading("The look beside the board guesses carefully (Mark)")

careful = tempfile.mkdtemp(prefix="dropdeck-390-careful-")
deep_one = tone_file(os.path.join(careful, "a", "b"), "x.wav")
near_one = tone_file(os.path.join(careful, "z"), "x.wav")
tone_file(os.path.join(careful, "music"), "applause.flac.wav")
os.rename(os.path.join(careful, "music", "applause.flac.wav"),
          os.path.join(careful, "music", "applause.flac"))
tone_file(careful, "Jingles.wav")
guess = {"app": C.APP_NAME, "format": 2, "slots": [
    {"filepath": r"Q:\gone\x.wav"},
    {"filepath": r"Q:\gone\applause.wav"},
    {"filepath": r"Q:\gone\Jingles", "folder_count": None},
]}
guess_path = os.path.join(careful, "guess.json")
with open(guess_path, "w", encoding="utf-8") as handle:
    json.dump(guess, handle)
g = Board.load(guess_path)
check("where a name is there twice, the shallower one wins",
      os.path.normcase(g.slots[0].filepath) == os.path.normcase(near_one),
      g.slots[0].filepath)
check("a different file with the same name and another extension is not "
      "taken", g.slots[1].is_missing, g.slots[1].filepath)
check("a pad that may have been a folder is not turned into a file",
      g.slots[2].is_missing, g.slots[2].filepath)

real_index = boardmod._index_folder


def slow_index(*args, **kw):
    time.sleep(8)
    return real_index(*args, **kw)


boardmod._index_folder = slow_index
began = time.monotonic()
slow = Board.load(guess_path)
took = time.monotonic() - began
boardmod._index_folder = real_index
check("a folder that takes eight seconds to list holds the load for the "
      "bound and no longer", took < C.BESIDE_SEARCH_SECONDS + 1.5,
      "%.1f s" % took)
check("and finds nothing rather than something half looked at",
      slow.found_beside == 0)


heading("What the board cannot find, it counts in full")

lost = Board()
lost.slots[0].filepath = r"Q:\gone\a.wav"
lost.playlist.tracks.append(Track(filepath=r"Q:\gone\b.wav"))
lost.playlist.tracks.append(Track(filepath=r"Q:\gone\c.wav"))
lost.drops.paths.append(r"Q:\gone\d.wav")
check("pads, running order and drops all count as missing",
      lost.missing_count == 4, lost.missing_count)


heading("The look beside the board is bounded")

deep = tempfile.mkdtemp(prefix="dropdeck-390-deep-")
tone_file(os.path.join(deep, "a", "b", "c", "d", "e"), "buried.wav")
tone_file(os.path.join(deep, "a"), "near.wav")
index, _folders = boardmod._index_folder(deep, depth=C.BESIDE_SEARCH_DEPTH)
check("a sound a few folders down is found", "near.wav" in index)
check("one buried five folders deep is not looked for",
      "buried.wav" not in index)
index, _folders = boardmod._index_folder(deep, entries=1)
check("the entry ceiling stops the walk", "buried.wav" not in index)
index, _folders = boardmod._index_folder(deep, seconds=-1)
check("and so does the clock", "buried.wav" not in index)
index, _folders = boardmod._index_folder(deep)
check("a relink the user asked for still walks the whole tree",
      "buried.wav" in index)

nothing = Board()
check("a board with no path looks nowhere and does not raise",
      nothing.find_beside() == [])


heading("A path from either system gives up its file name")

check("a Windows path", boardmod._basename(r"G:\My Drive\Show\intro.mp3")
      == "intro.mp3")
check("a Mac path", boardmod._basename("/Users/siena/Drive/intro.mp3")
      == "intro.mp3")
check("a folder with a slash on the end",
      boardmod._basename("C:\\Sounds\\Countdown\\") == "Countdown")
check("nothing at all", boardmod._basename(None) == "")

mac_board = Board()
mac_board.slots[0].filepath = "/Users/siena/Google Drive/SienaT Radio/intro.wav"
mac_board.slots[0].folder_count = None
fixed = mac_board.relink(os.path.join(drive, "Show sounds"))
check("a relink here repairs a pad written on the Mac",
      not mac_board.missing_slots and len(fixed) == 1,
      mac_board.slots[0].filepath)


# ===========================================================================
heading("Export board with its sounds")

src = tempfile.mkdtemp(prefix="dropdeck-390-src-")
one = tone_file(os.path.join(src, "pads"), "jingle.wav")
same_name = tone_file(os.path.join(src, "other"), "jingle.wav", hz=880.0)
song = tone_file(os.path.join(src, "music"), "song.wav", seconds=0.5)
countdown = os.path.join(src, "Countdown")
tone_file(countdown, "ten.wav")
tone_file(countdown, "nine.wav")
with open(os.path.join(countdown, "notes.txt"), "w") as handle:
    handle.write("not a sound")

live = Board()
live.path = os.path.join(src, "Live show.json")
live.slots[0].filepath = one
live.slots[1].filepath = same_name
live.slots[2].filepath = countdown
live.slots[2].scan_folder(force=True)
live.slots[3].filepath = r"Q:\nowhere\lost.wav"
live.playlist.tracks.append(Track(filepath=song))
live.playlist.tracks.append(Track(filepath=one))
live.drops.paths.append(song)
before = json.dumps(live.to_dict(), sort_keys=True)

target = os.path.join(tempfile.mkdtemp(prefix="dropdeck-390-out-"), "Live show")
steps = []
result = live.export_with_sounds(target, name="Live show",
                                 progress=lambda d, t: steps.append((d, t)))
check("the board file is written into the folder",
      result["board"] == os.path.join(target, "Live show.json")
      and os.path.isfile(result["board"]), result["board"])
copied = sorted(os.listdir(os.path.join(target, C.EXPORT_SOUNDS_FOLDER)))
check("each sound is copied once, a shared one only once",
      result["copied"] == 5, result["copied"])
check("two different files with one name both survive",
      "jingle.wav" in copied and "jingle (2).wav" in copied, copied)
check("a folder pad comes across as a folder of its sounds and nothing else",
      sorted(os.listdir(os.path.join(target, C.EXPORT_SOUNDS_FOLDER,
                                     "Countdown")))
      == ["nine.wav", "ten.wav"])
check("the missing sound is reported, not invented",
      result["missing"] == [r"Q:\nowhere\lost.wav"], result["missing"])
check("the size is reported", result["bytes"] > 0)
check("progress only ever goes up and finishes at the total",
      steps and all(a[0] <= b[0] for a, b in zip(steps, steps[1:]))
      and steps[-1][0] == steps[-1][1], steps[-3:])
check("no half copied file is left behind",
      not any(n.endswith(".part") for _r, _d, files in os.walk(target)
              for n in files))
out = raw(result["board"])
paths = ([s.get("filepath") for s in out["slots"] if s.get("filepath")]
         + [t["filepath"] for t in out["playlist"]["tracks"]]
         + out["drops"]["paths"])
carried_paths = [p for p in paths if p != r"Q:\nowhere\lost.wav"]
check("every copied path in the board is relative to it",
      all(p.startswith(C.EXPORT_SOUNDS_FOLDER + "/") for p in carried_paths),
      carried_paths)
check("with forward slashes, for the Mac",
      not any("\\" in p for p in carried_paths))
check("the two jingles point at their own copies",
      out["slots"][0]["filepath"] == "Sounds/jingle.wav"
      and out["slots"][1]["filepath"] == "Sounds/jingle (2).wav",
      [out["slots"][0]["filepath"], out["slots"][1]["filepath"]])
check("the board in the app is not changed by exporting it",
      json.dumps(live.to_dict(), sort_keys=True) == before)

elsewhere = os.path.join(tempfile.mkdtemp(prefix="dropdeck-390-far-"), "Copy")
shutil.copytree(target, elsewhere)
shutil.rmtree(src)
far = Board.load(os.path.join(elsewhere, "Live show.json"))
check("the export opens on another computer with the originals gone",
      far.missing_count == 1, far.missing_count)
check("the folder pad still plays at random from its own sounds",
      far.slots[2].is_folder and far.slots[2].scan_folder(force=True) == 2)
check("the jingle that was different is still different",
      sf.info(far.slots[1].filepath).frames > 0
      and far.slots[0].filepath != far.slots[1].filepath)

heading("Export, when things go wrong (Mark)")

shaky = tempfile.mkdtemp(prefix="dropdeck-390-shaky-")
keep_a = tone_file(os.path.join(shaky, "in"), "a.wav")
vanish = tone_file(os.path.join(shaky, "in"), "b.wav")
shaky_board = Board()
shaky_board.path = os.path.join(shaky, "Shaky.json")
shaky_board.slots[0].filepath = keep_a
shaky_board.slots[1].filepath = vanish
snapshot = shaky_board.to_dict()
snap_paths = shaky_board.sound_paths()
shaky_board.slots[2].filepath = tone_file(os.path.join(shaky, "in"), "late.wav")


def lose_b(done, total):
    if os.path.exists(vanish) and done > 0:
        os.remove(vanish)


out_dir = os.path.join(shaky, "out")
shaky_result = shaky_board.export_with_sounds(
    out_dir, name="Shaky", progress=lose_b, data=snapshot, paths=snap_paths)
check("a sound that vanishes part way is counted missing and the rest carry "
      "on", shaky_result["copied"] == 1 and vanish in shaky_result["missing"]
      and os.path.isfile(shaky_result["board"]), shaky_result)
shaky_out = raw(shaky_result["board"])
check("its pad keeps the path it had", shaky_out["slots"][1]["filepath"]
      == vanish, shaky_out["slots"][1]["filepath"])
check("the board exported is the board as it was when asked, not a pad added "
      "during the copy", not (shaky_out["slots"][2] or {}).get("filepath"),
      shaky_out["slots"][2])
try:
    shaky_board.export_with_sounds(out_dir, name="Shaky")
    check("an export never writes over a board already there", False)
except FileExistsError:
    check("an export never writes over a board already there", True)

stopped_at = tempfile.mkdtemp(prefix="dropdeck-390-stop-")
big = Board()
big.path = os.path.join(stopped_at, "big.json")
big.slots[0].filepath = tone_file(os.path.join(stopped_at, "in"), "long.wav",
                                  seconds=12.0)


def stop_part_way(done, total):
    if done > 0:
        raise boardmod.ExportStopped("stop")


try:
    big.export_with_sounds(os.path.join(stopped_at, "out"),
                           progress=stop_part_way)
    check("an export can be stopped", False)
except boardmod.ExportStopped:
    check("an export can be stopped", True)
check("and a stopped copy leaves no partial file",
      not any(n.endswith(".part") for _r, _d, files
              in os.walk(os.path.join(stopped_at, "out")) for n in files))


# ===========================================================================
heading("Pause and resume: the file carries on, and the gap is not in it")


def feed(bus, seconds, hz=440.0):
    position, total = 0, int(RATE * seconds)
    while position < total:
        n = min(1024, total - position)
        t = np.arange(position, position + n) / float(RATE)
        wave = (0.3 * np.sin(2 * np.pi * hz * t)).astype(np.float32)
        bus.write("main", np.repeat(wave[:, None], CHANNELS, axis=1), RATE)
        position += n
        time.sleep(n / float(RATE) * 0.5)


where = tempfile.mkdtemp(prefix="dropdeck-390-rec-")
bus = AirBus(RATE)
rec = recorder.Recorder(bus, fmt="wav", folder=where)
rec.start()
check("a recording starts unpaused", rec.paused is False)
feed(bus, 1.0, hz=500.0)
time.sleep(0.4)
rec.pause()
check("it pauses", rec.paused)
check("and says so when asked", "paused" in rec.describe(), rec.describe())
time.sleep(0.3)
held = rec.elapsed
feed(bus, 1.5, hz=2000.0)
time.sleep(0.4)
check("its clock stands still while paused",
      abs(rec.elapsed - held) < 0.05, "%.2f then %.2f" % (held, rec.elapsed))
rec.resume()
check("it resumes", rec.paused is False)
feed(bus, 1.0, hz=500.0)
time.sleep(0.4)
path = rec.stop()
audio, rate = sf.read(path)
length = len(audio) / float(rate)
check("the file is the two halves and not the pause",
      abs(length - 2.0) < 0.3, "%.2f s" % length)
spectrum = np.abs(np.fft.rfft(audio[:, 0]))
freqs = np.fft.rfftfreq(len(audio), 1.0 / rate)
paused_tone = spectrum[np.argmin(np.abs(freqs - 2000.0))]
kept_tone = spectrum[np.argmin(np.abs(freqs - 500.0))]
check("nothing played during the pause is in it",
      paused_tone < kept_tone * 0.01,
      "%.1f against %.1f" % (paused_tone, kept_tone))
check("and nothing was lost to a full ring while it waited",
      rec.losing_audio == 0, rec.losing_audio)
rec2 = recorder.Recorder(AirBus(RATE), fmt="wav", folder=where)
rec2.pause()
rec2.start()
check("a recording started fresh is never born paused", rec2.paused is False)
rec2.stop()


# ===========================================================================
heading("The window: menus, keys and what is said")

from dropdeck.ui import DropDeckFrame, ID_MIC_SETTINGS, ID_MIC_TOGGLE, \
    ID_RECORD_PAUSE, ID_EXPORT

app = wx.App(redirect=False)
frame = DropDeckFrame()


def pump(ms):
    end = time.time() + ms / 1000.0
    while time.time() < end:
        app.Yield()
        time.sleep(0.01)


class Ears:
    def __init__(self):
        self.heard = []

    def say(self, text, interrupt=True):
        self.heard.append(text)


ears = Ears()
frame.speaker = ears
bar = frame.GetMenuBar()


def menu_named(label):
    for at in range(bar.GetMenuCount()):
        if bar.GetMenuLabelText(at).replace("&", "") == label:
            return bar.GetMenu(at)
    return None


air, playlist_menu, file_menu = (menu_named("On air"), menu_named("Playlist"),
                                 menu_named("File"))
check("the microphone is on the On air menu, as on the Mac",
      air.FindItemById(ID_MIC_TOGGLE) is not None
      and air.FindItemById(ID_MIC_SETTINGS) is not None)
check("and no longer on the Playlist menu",
      playlist_menu.FindItemById(ID_MIC_TOGGLE) is None
      and playlist_menu.FindItemById(ID_MIC_SETTINGS) is None)
check("its keys did not move",
      "Ctrl+M" in air.FindItemById(ID_MIC_TOGGLE).GetItemLabel()
      and "Ctrl+Shift+M" in air.FindItemById(ID_MIC_SETTINGS).GetItemLabel())
check("Pause recording is on On air with Alt+Shift+R",
      air.FindItemById(ID_RECORD_PAUSE) is not None
      and "Alt+Shift+R" in air.FindItemById(ID_RECORD_PAUSE).GetItemLabel())
check("Export board with its sounds is on the File menu",
      file_menu.FindItemById(ID_EXPORT) is not None)

speech_was = frame.board.speech_level
frame.board.record_folder = tempfile.mkdtemp(prefix="dropdeck-390-ui-")
frame.board.record_format = "wav"

ears.heard.clear()
frame.toggle_record_pause()
check("pausing with nothing recording says so",
      ears.heard and ears.heard[-1].startswith("Nothing is recording"),
      ears.heard)

ears.heard.clear()
frame.start_recording()
check("starting says Recording started, first",
      ears.heard and ears.heard[-1].startswith("Recording started"),
      ears.heard)
pump(300)
ears.heard.clear()
frame.toggle_record_pause()
check("Alt+Shift+R pauses it", frame.recorder.paused)
check("and says Recording paused",
      ears.heard and ears.heard[-1].startswith("Recording paused"),
      ears.heard)
check("the menu now offers to resume",
      air.FindItemById(ID_RECORD_PAUSE).GetItemLabelText().startswith("Resume"))
ears.heard.clear()
frame.toggle_record_pause()
check("pressed again it resumes", frame.recorder.paused is False)
check("and says Recording resumed", ears.heard == ["Recording resumed"],
      ears.heard)
check("the menu is back to Pause",
      air.FindItemById(ID_RECORD_PAUSE).GetItemLabelText().startswith("Pause"))
pump(300)
ears.heard.clear()
frame.stop_recording()
check("stopping says Recording stopped, first",
      ears.heard and ears.heard[-1].startswith("Recording stopped"),
      ears.heard)
check("and still says where it went",
      ears.heard and "Saved as" in ears.heard[-1], ears.heard)
pump(300)
check("and the file's path is never read out after either sentence, which "
      "cut both off from 3.8.1 to 3.9.0",
      not any(os.path.isabs(line) for line in ears.heard), ears.heard)

frame.board.speech_level = C.SPEECH_NONE
ears.heard.clear()
frame.start_recording()
check("at speech level none it still says it started, and only that",
      ears.heard == ["Recording started"], ears.heard)
ears.heard.clear()
frame.stop_recording()
check("and that it stopped", ears.heard == ["Recording stopped"], ears.heard)
check("the detail is still on the status bar",
      frame.status.GetStatusText(1).startswith("Recording stopped. Saved as"),
      frame.status.GetStatusText(1))
frame.board.speech_level = speech_was

ears.heard.clear()
frame._menu_closed_at = time.monotonic()
frame.announce_recording("Recording started", "detail")
check("straight after a menu closes, it waits for the screen reader",
      ears.heard == [], ears.heard)
# A timer needs the real event loop; Yield does not run it.
wx.CallLater(C.AFTER_MENU_SPEECH_MS + 600, app.ExitMainLoop)
app.MainLoop()
check("and then says it", "Recording started. detail" in ears.heard,
      ears.heard)
frame._menu_closed_at = None

from dropdeck import ui as uimod
blocker = os.path.join(stopped_at if False else tempfile.mkdtemp(), "Taken")
open(blocker, "w").close()
check("a FILE where the export folder would go is not mistaken for room "
      "(Mark: NotADirectoryError on the window thread)",
      uimod._empty_or_absent(blocker) is False)
check("a relative recording path is still a file name and never read out",
      uimod._is_a_file_name(r"my recordings\Drop Deck Stream 001.wav"))
check("a sentence is not", not uimod._is_a_file_name(
    "The recording is losing audio. The machine cannot keep up."))
check("a folder is said by its name and the folder it is in",
      uimod._short_place(r"G:\My Drive\Ali show") == "Ali show, in My Drive",
      uimod._short_place(r"G:\My Drive\Ali show"))

ears.heard.clear()
frame._load_into(ali_path)
check("loading a carried board says what it found beside itself",
      ears.heard and "found beside the board" in ears.heard[-1]
      and ".json" not in ears.heard[-1], ears.heard)

frame.board.path = os.path.join(stopped_at, "big.json")
frame.board.slots[0].filepath = big.slots[0].filepath
check("an export is named after its board",
      frame._export_name() == "big", frame._export_name())
frame.board.path = os.path.join(stopped_at, "board.json")
check("but the settings folder's board.json is not called 'board'",
      frame._export_name() == "Drop Deck board", frame._export_name())
ears.heard.clear()
frame._run_export(os.path.join(stopped_at, "ui export"), "Drop Deck board")
deadline = time.time() + 20
while getattr(frame, "_exporting", False) and time.time() < deadline:
    pump(100)
check("an export from the menu says where it went and how to open it",
      ears.heard and ears.heard[-1].startswith("Export finished")
      and "on any computer" in ears.heard[-1]
      and "\\" not in ears.heard[-1], ears.heard[-1:])

frame.stop_background_work()
frame.mixer.close()
frame.Destroy()

print("\n%d/%d checks passed" % (sum(CHECKS), len(CHECKS)))
sys.stdout.flush()
os._exit(0 if all(CHECKS) else 1)
