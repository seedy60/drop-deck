"""3.8.4: a portable copy keeps its settings beside itself.

    python tests/test_3_8_4.py

HarmonicaPlayer, 20 September 2026, two messages:

    "since i am running the portable copy of TG dropdeck, why don't it make
    a folder called userdata inside of application directory instead of
    writing the data in a folder called TG studios in %appdata% on hard
    drive?"

    "when next build comes out can you have it copy all userdata from the TG
    studios folder to specified userdata pre-made folder in application data
    when it updates? then i can delete the TG studios folder on HD to free
    space"

He is right, and it is not only tidiness: a portable copy that leaves its
board in AppData is portable in name only. Move the folder and the program is
empty.

**Nothing in here runs frozen**, so the portable answer is forced by standing
in for `board._is_portable_copy` and `board.app_dir`, which is exactly the
pair the real thing asks. The real frozen test is the release selftest.
"""

import json
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.environ["APPDATA"] = tempfile.mkdtemp(prefix="dropdeck-384-test-")

from dropdeck import appupdate
from dropdeck import board as boardmod

CHECKS = []


def check(label, condition, detail=""):
    CHECKS.append(bool(condition))
    print(("  ok   " if condition else "  FAIL ") + label
          + (("  " + str(detail)) if detail != "" and not condition else ""))


def heading(text):
    print("\n" + text)


def _saved(board):
    """Write a board to a scratch file and give back the path."""
    path = os.path.join(tempfile.mkdtemp(prefix="dropdeck-384-save-"),
                        "board.json")
    board.save(path)
    return path



def temp_dir(prefix):
    path = tempfile.mkdtemp(prefix=prefix)
    return path


def fill_legacy(**files):
    """Put some settings in the old AppData folder and return where."""
    old = boardmod.legacy_config_dir()
    os.makedirs(old, exist_ok=True)
    for name, text in files.items():
        name = name.replace("__", ".")
        with open(os.path.join(old, name), "w", encoding="utf-8") as handle:
            handle.write(text)
    return old


class Portable:
    """Pretend this copy is the zip, unpacked in a folder of its own.

    Restores everything on the way out, including the cached answer, because
    `config_dir` is worked out once per run on purpose and a test that left
    it set would decide where the NEXT test file writes.
    """

    def __init__(self, portable=True, app_folder=None):
        self.portable = portable
        self.folder = app_folder or temp_dir("dropdeck-384-app-")

    def __enter__(self):
        self._was_app_dir = boardmod.app_dir
        self._was_portable = boardmod._is_portable_copy
        boardmod.app_dir = lambda: self.folder
        boardmod._is_portable_copy = lambda: self.portable
        boardmod._forget_config_dir()
        return self

    def __exit__(self, *_):
        boardmod.app_dir = self._was_app_dir
        boardmod._is_portable_copy = self._was_portable
        boardmod._forget_config_dir()
        return False

    @property
    def userdata(self):
        return os.path.join(self.folder, boardmod.PORTABLE_DATA_DIR)


# ===========================================================================
heading("An installed copy is exactly where it always was")

with Portable(portable=False) as copy:
    where = boardmod.config_dir()
    check("settings stay in AppData",
          boardmod.same_path(where, boardmod.legacy_config_dir()), where)
    check("and no userdata folder is made beside the program",
          not os.path.exists(copy.userdata), copy.folder)
    check("which is what a diagnostic says", boardmod.data_kind() == "in AppData",
          boardmod.data_kind())


# ===========================================================================
heading("A portable copy keeps everything beside itself")

with Portable() as copy:
    where = boardmod.config_dir()
    check("settings go in userdata, beside the program",
          boardmod.same_path(where, copy.userdata), where)
    check("the folder is really made", os.path.isdir(copy.userdata))
    check("the board goes there too",
          boardmod.same_path(os.path.dirname(boardmod.default_board_path()),
                             copy.userdata),
          boardmod.default_board_path())
    check("and a diagnostic says which kind, never the path",
          boardmod.data_kind() == "beside the program", boardmod.data_kind())


# ===========================================================================
heading("A userdata folder made by hand wins, installed or not")
#
# This is the whole of how an INSTALLED copy opts in. One sentence of
# instructions: make a folder called userdata beside the program.

made_by_hand = temp_dir("dropdeck-384-hand-")
os.makedirs(os.path.join(made_by_hand, boardmod.PORTABLE_DATA_DIR))
with Portable(portable=False, app_folder=made_by_hand) as copy:
    where = boardmod.config_dir()
    check("an installed copy follows a userdata folder somebody made",
          boardmod.same_path(where, copy.userdata), where)


# ===========================================================================
heading("A folder named outright wins over both")

named = temp_dir("dropdeck-384-named-")
os.environ[boardmod.DATA_ENV] = named
try:
    with Portable() as copy:
        where = boardmod.config_dir()
        check("TGDROPDECK_DATA is used when it is set",
              boardmod.same_path(where, named), where)
        check("and nothing is written beside the program",
              not os.path.exists(copy.userdata))
finally:
    del os.environ[boardmod.DATA_ENV]


# ===========================================================================
heading("A folder that cannot be written to falls back rather than failing")
#
# A zip unpacked into Program Files, or run from a read only stick. Falling
# over here is not an option: this runs before the app has a window to
# apologise in.

missing_drive = "Q:\\no-such-folder\\dropdeck" if os.name == "nt" \
    else "/no-such-root/dropdeck"
os.environ[boardmod.DATA_ENV] = missing_drive
try:
    with Portable():
        where = boardmod.config_dir()
        check("a named folder that refuses falls back to AppData",
              boardmod.same_path(where, boardmod.legacy_config_dir()), where)
        check("and the app says so rather than going quiet",
              "could not be written to" in boardmod.data_note,
              boardmod.data_note)
finally:
    del os.environ[boardmod.DATA_ENV]

with Portable(app_folder=missing_drive):
    where = boardmod.config_dir()
    check("a portable copy in a read only folder falls back too",
          boardmod.same_path(where, boardmod.legacy_config_dir()), where)
    check("and says which folder it is using",
          boardmod.data_kind().startswith("in AppData"), boardmod.data_kind())


# ===========================================================================
heading("The settings already in AppData come with it, once")

old = fill_legacy(board__json='{"slots": []}',
                  errors__log="something happened\n")
with open(os.path.join(old, boardmod.LAST_BOARD_FILE), "w",
          encoding="utf-8") as handle:
    json.dump({"path": os.path.join(old, "board.json")}, handle)

with Portable() as copy:
    where = boardmod.config_dir()
    brought = sorted(os.listdir(where))
    check("the board is brought over", "board.json" in brought, brought)
    check("so is everything else that was in there",
          "errors.log" in brought and boardmod.LAST_BOARD_FILE in brought,
          brought)
    check("the old folder is left exactly as it was",
          os.path.exists(os.path.join(old, "board.json")))
    check("the user is told, in one sentence",
          "userdata" in boardmod.data_note
          and "can be deleted" in boardmod.data_note, boardmod.data_note)
    check("and the long version is written where they can find it",
          os.path.exists(os.path.join(where, boardmod.MOVED_NOTE)))
    with open(os.path.join(where, boardmod.MOVED_NOTE),
              encoding="utf-8") as handle:
        note = handle.read()
    check("which says stream keys do NOT travel with the folder",
          "Credential Manager" in note, note[:120])

    # The one that would have lost a board. last_board.json holds an
    # ABSOLUTE path, and the path it holds is almost always the board in the
    # folder the user has just been told they may delete.
    remembered = boardmod.remembered_board_path()
    check("the remembered board follows into the new folder",
          boardmod.same_path(remembered, os.path.join(where, "board.json")),
          remembered)
    check("rather than pointing back at the folder they will delete",
          not boardmod.same_path(remembered, os.path.join(old, "board.json")),
          remembered)

    # Second run, same folder: nothing said, nothing copied again.
    boardmod._forget_config_dir()
    again = boardmod.config_dir()
    check("a second run says nothing about it", boardmod.data_note == "",
          boardmod.data_note)
    check("and lands in the same folder", boardmod.same_path(again, where))


# ===========================================================================
heading("A userdata folder that is already somebody's is never written over")

with Portable() as copy:
    os.makedirs(copy.userdata, exist_ok=True)
    with open(os.path.join(copy.userdata, "board.json"), "w",
              encoding="utf-8") as handle:
        handle.write('{"mine": true}')
    boardmod._forget_config_dir()
    where = boardmod.config_dir()
    with open(os.path.join(where, "board.json"), encoding="utf-8") as handle:
        kept = handle.read()
    check("a board already in userdata is left alone", "mine" in kept, kept)
    check("and nothing is announced", boardmod.data_note == "",
          boardmod.data_note)


# ===========================================================================
heading("An update carries the settings with it")

#: unpack_beside makes a NEW folder. Without this, updating a portable copy
#: that cannot be replaced in place is a program that has forgotten
#: everything it knew.
old_copy = temp_dir("dropdeck-384-old-")
new_copy = temp_dir("dropdeck-384-new-")
os.makedirs(os.path.join(old_copy, appupdate.USER_DATA_DIR))
with open(os.path.join(old_copy, appupdate.USER_DATA_DIR, "board.json"),
          "w", encoding="utf-8") as handle:
    handle.write('{"carried": true}')

check("the settings folder is carried into the new copy",
      appupdate.carry_user_data(old_copy, new_copy))
carried = os.path.join(new_copy, appupdate.USER_DATA_DIR, "board.json")
check("with the board in it", os.path.exists(carried), carried)
check("and the old copy still has its own",
      os.path.exists(os.path.join(old_copy, appupdate.USER_DATA_DIR,
                                  "board.json")))

# Called twice, or against a copy that already has settings, it must not
# touch what is there.
with open(carried, "w", encoding="utf-8") as handle:
    handle.write('{"newer": true}')
check("a second call changes nothing",
      not appupdate.carry_user_data(old_copy, new_copy))
with open(carried, encoding="utf-8") as handle:
    check("and the newer settings are still the ones there",
          "newer" in handle.read())

check("a copy with no settings folder is not an error",
      not appupdate.carry_user_data(temp_dir("dropdeck-384-bare-"),
                                    temp_dir("dropdeck-384-bare2-")))


# ===========================================================================
heading("An in place update never writes over the settings it is replacing")

#: finish_update copies the staging folder over the running one. A staging
#: folder should never hold a userdata, because it is unpacked from the zip
#: and never run, but if one ever appeared it would replace a real board
#: with an empty one. That folder is the only one in there that is the
#: user's rather than the program's.
source = temp_dir("dropdeck-384-staging-")
target = temp_dir("dropdeck-384-target-")
os.makedirs(os.path.join(source, appupdate.USER_DATA_DIR))
with open(os.path.join(source, appupdate.USER_DATA_DIR, "board.json"),
          "w", encoding="utf-8") as handle:
    handle.write('{"from_the_zip": true}')
with open(os.path.join(source, "TG Drop Deck.exe"), "w") as handle:
    handle.write("new")
os.makedirs(os.path.join(target, appupdate.USER_DATA_DIR))
with open(os.path.join(target, appupdate.USER_DATA_DIR, "board.json"),
          "w", encoding="utf-8") as handle:
    handle.write('{"the_users_own": true}')

ok, message = appupdate.finish_update(target, 0, source=source)
check("the update is written", ok, message)
with open(os.path.join(target, appupdate.USER_DATA_DIR, "board.json"),
          encoding="utf-8") as handle:
    survived = handle.read()
check("and the board that was there is still the board that is there",
      "the_users_own" in survived, survived)
check("while the program files did arrive",
      os.path.exists(os.path.join(target, "TG Drop Deck.exe")))


# ===========================================================================
heading("Nothing here can raise on the way to a window")

#: config_dir runs before wx exists and before the error log is installed.
#: Anything it raises is a program that will not start at all.
class Exploding:
    def __call__(self):
        raise RuntimeError("no")


with Portable() as copy:
    boardmod._is_portable_copy = Exploding()
    boardmod._forget_config_dir()
    try:
        where = boardmod.config_dir()
        raised = ""
    except Exception as exc:
        where = ""
        raised = str(exc)
    check("a broken portable check falls back rather than raising",
          not raised and boardmod.same_path(where,
                                            boardmod.legacy_config_dir()),
          raised or where)

# And the real one, unmocked: it must answer without a frozen build.
try:
    answer = boardmod._is_portable_copy()
    raised = ""
except Exception as exc:
    answer = None
    raised = str(exc)
check("and the real check answers from source without raising",
      raised == "" and answer is False, raised or answer)


# ===========================================================================
# Going live to YouTube and Facebook: the key can be checked, and the app
# can no longer say a show is going out when it is not.
#
# Joshua, 20 September 2026: "pressing ctrl B it says it's going live to
# youtube but nothing shows on my channel, i have the stream key and channel
# name in the settings like it said to do."
# ===========================================================================

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools"))

import wx                                                       # noqa: E402

from dropdeck import constants as C                             # noqa: E402
from dropdeck import picturefeed                                # noqa: E402
from dropdeck import rtmpcheck                                  # noqa: E402
from dropdeck import secrets                                    # noqa: E402
from dropdeck import streamout                                  # noqa: E402
from dropdeck.board import Board                                # noqa: E402
from dropdeck.dialogs import GoLiveDialog, SettingsDialog       # noqa: E402
from dropdeck.ui import DropDeckFrame                           # noqa: E402
from mock_rtmp import MockRTMP                                  # noqa: E402


heading("The stream key can be checked, and nothing is broadcast")

with MockRTMP.spawn(seconds=15) as server:
    base, good_key = server.url.rsplit("/", 1)
    answer = rtmpcheck.verify(base, good_key)
    check("a key the server accepts comes back accepted",
          answer.outcome == rtmpcheck.ACCEPTED, answer.outcome)
    check("with the server's own words kept",
          "publish" in (answer.server_said or "").lower(), answer.server_said)

# The whole safety argument: not one byte of media, and no FLV at all.
result = server.result()
check("not one audio packet was sent", result.audio == 0, result.counts)
check("not one video packet either", result.video == 0, result.counts)
check("and no FLV metadata went out", result.counts.get("data", 0) == 0,
      result.counts)
check("the server saw a publish, so the key really was offered",
      any("publish" in str(c) for c in result.commands), result.commands)
check("and it reached the publishing state", result.publishing)

check("no key is answered without touching the network",
      rtmpcheck.verify("rtmps://a.rtmps.youtube.com/live2", "").outcome
      == rtmpcheck.NO_KEY)
check("and so is an address that is not RTMP",
      rtmpcheck.verify("https://example.com/live", "k").outcome
      == rtmpcheck.BAD_ADDRESS)
check("a name that does not resolve says so",
      rtmpcheck.verify("rtmps://nothing.invalid.example/live2", "k").outcome
      == rtmpcheck.NO_SERVER)

check("an address is split the way an encoder splits it",
      rtmpcheck.split_url("rtmps://a.rtmps.youtube.com/live2")
      == ("rtmps", "a.rtmps.youtube.com", 443, "live2"),
      rtmpcheck.split_url("rtmps://a.rtmps.youtube.com/live2"))
check("including a port written out in full",
      rtmpcheck.split_url("rtmps://live-api-s.facebook.com:443/rtmp")
      == ("rtmps", "live-api-s.facebook.com", 443, "rtmp"))
check("and a plain rtmp address keeps its own port",
      rtmpcheck.split_url("rtmp://example.com/live")[2] == 1935)

# **A socket that closes is only a refusal AFTER the publish.** YouTube says
# nothing at all when a key is wrong, it simply hangs up. The same silence
# during the handshake is the network, and telling somebody their key is
# wrong over a network fault sends them hunting for a key that was fine.
check("a drop at the publish is read as a refusal",
      rtmpcheck._gave_up("publish", "closed").outcome == rtmpcheck.REFUSED)
check("a drop during the handshake is not",
      rtmpcheck._gave_up("handshake", "closed").outcome
      == rtmpcheck.NO_ANSWER)
check("nor is one at connect",
      rtmpcheck._gave_up("connect", "closed").outcome == rtmpcheck.NO_ANSWER)


heading("What the check says, outcome by outcome")

app = wx.App(redirect=False)
frame = DropDeckFrame()
prefs = SettingsDialog(frame, frame.board, frame.mixer, mic=frame.mic,
                       page=SettingsDialog.PAGE_VIDEO)


def verdict(outcome, platform="youtube", said="", key="abcd-efgh"):
    return prefs._key_verdict(rtmpcheck.Result(outcome, said), platform,
                              streamout.server_label(platform),
                              "a.rtmps.youtube.com", key)


yes = verdict(rtmpcheck.ACCEPTED)
check("an accepted YouTube key says so, and says nothing was broadcast",
      "accepted your stream key" in yes and "nothing was broadcast" in yes,
      yes)
check("and names the reason a good key still shows nothing",
      "auto start" in yes and "Go live" in yes, yes)
fb = verdict(rtmpcheck.ACCEPTED, "facebook")
check("an accepted Facebook key says nothing was posted",
      "nothing was posted" in fb and "Go Live Now" in fb, fb)
no = verdict(rtmpcheck.REFUSED, said="Publish Rejected: Invalid URL")
check("a refusal repeats the platform's own words",
      "Publish Rejected: Invalid URL" in no, no)
quiet = verdict(rtmpcheck.REFUSED)
check("a refusal with no words still explains itself",
      "closed the connection" in quiet and "expired" in quiet, quiet)
check("and never puts the whole key on screen",
      "abcd-efgh" not in quiet and "efgh" in quiet, quiet)
for outcome in (rtmpcheck.NO_SERVER, rtmpcheck.NO_ROUTE, rtmpcheck.NO_TLS,
                rtmpcheck.NO_ANSWER, rtmpcheck.NO_KEY,
                rtmpcheck.BAD_ADDRESS):
    line = verdict(outcome)
    check("%s is a plain sentence" % outcome,
          line and line[0].isupper() and line.rstrip().endswith("."), line)
    check("%s says no URL out loud" % outcome,
          "rtmps://" not in line and "http" not in line, line)

check("only a platform that goes live on connect asks first",
      C.RTMP_GOES_LIVE_AT_ONCE.get("youtube") is True
      and not C.RTMP_GOES_LIVE_AT_ONCE.get("facebook"))
check("and that fact is read now rather than merely held",
      "RTMP_GOES_LIVE_AT_ONCE" in open(
          os.path.join(os.path.dirname(os.path.dirname(
              os.path.abspath(__file__))), "dropdeck", "dialogs.py"),
          encoding="utf-8").read())


heading("A stream key that is really there is never wiped by pressing OK")

#: The one that would have cost Joshua his key. `_loaded_key` read the
#: credential store alone while `_stream_settings` reads the store OR
#: `board.video_key`, so on a machine whose credential store refuses a write
#: the box came up empty over a key that was in force, and OK, seeing an
#: empty box, forgot it.
frame.board.video_key = "fallback-key-1234"
frame.board.stream_name = ""
again = SettingsDialog(frame, frame.board, frame.mixer, mic=frame.mic,
                       page=SettingsDialog.PAGE_VIDEO)
check("the box shows a key that lives on the board",
      again.video_settings["key"] == "fallback-key-1234",
      again.video_settings["key"])
check("which is the same key the streamer would use",
      frame._stream_settings().get("password") == "fallback-key-1234"
      if frame.board.live_to == C.LIVE_TO_VIDEO else True)
again.Destroy()


heading("Renaming a station takes the key with it")

frame.board.video_key = ""
frame.board.stream_name = "Old Name"
stored = secrets.store("Old Name", "key-for-old-name")
if not stored:
    check("SKIPPED: this machine has no credential store", True)
else:
    # What the OK handler does, in the order it does it.
    was_called = frame.board.stream_name
    frame.board.stream_name = "New Name"
    secrets.store("New Name", "key-for-old-name")
    if was_called and was_called != frame.board.stream_name:
        secrets.forget(was_called)
    check("the key is found under the new name",
          secrets.fetch("New Name") == "key-for-old-name")
    check("and is not left behind under the old one",
          secrets.fetch("Old Name") == "")
    secrets.forget("New Name")
frame.board.stream_name = ""


heading("Ctrl+B says why it will not go, rather than reading the summary")

frame.board.live_to = C.LIVE_TO_VIDEO
blocked = frame._report_for({
    "server": "youtube", "host": C.RTMP_INGEST["youtube"], "password": "",
    "format": "aac", "bitrate": 128, "name": "", "video_name": "",
    "picture": C.PICTURE_CARD, "video_width": 1280, "video_height": 720,
    "video_fps": 30, "video_bitrate": 2500})
box = GoLiveDialog(frame, blocked)
check("a blocked broadcast really is blocked", blocked.blocked)
#: Jessica's audit: landing on the OTHER box was tried and is worse. A screen
#: reader reads the line at the caret of an edit control, not the whole
#: value, so it would read one warning and leave the summary unread. One
#: window, one place it always reads from, and the reason first.
check("focus is on what will go out, as it always is",
      box.FindFocus() is box.what, box.FindFocus())
check("and the first thing it reads is why the show is not going out",
      box.what.GetValue().splitlines()[0].startswith("Not going out:"),
      box.what.GetValue().splitlines()[0])
check("which names the missing key",
      "stream key" in box.what.GetValue().splitlines()[0].lower(),
      box.what.GetValue().splitlines()[0])
check("the summary is still all there under it",
      "Going to:" in box.what.GetValue(), box.what.GetValue())
check("and Enter presses the default button rather than being eaten",
      hasattr(box, "_on_char_hook"))
box.Destroy()

fine = frame._report_for({
    "server": "youtube", "host": C.RTMP_INGEST["youtube"],
    "password": "a-key", "format": "aac", "bitrate": 128, "name": "Mine",
    "video_name": "", "picture": C.PICTURE_CARD, "video_width": 1280,
    "video_height": 720, "video_fps": 30, "video_bitrate": 2500})
box = GoLiveDialog(frame, fine)
check("when nothing is wrong, focus is still on what will go out",
      box.FindFocus() is box.what, box.FindFocus())
box.Destroy()


heading("Ctrl+B is still the choice of destination, even when you decline")

#: Mark's audit wanted this put back on "stay off air", and it was tried.
#: `tests/test_3_8_2.py` asserts the opposite on purpose: 3.8.2 gave each
#: destination its own key so that pressing one IS choosing where the show
#: goes, and the choice has to outlive the question or the On air menu and
#: Ctrl+Shift+B disagree with the key just pressed. Written down here so the
#: next person to think it is a bug finds the answer before the change.
frame.board.live_to = C.LIVE_TO_AUDIO
frame.board.ask_before_live = True
real_cleared = frame._cleared_to_go
frame._cleared_to_go = lambda: False
try:
    frame.toggle_stream(to=C.LIVE_TO_VIDEO)
finally:
    frame._cleared_to_go = real_cleared
check("the key that was pressed still decides where Ctrl+B goes",
      frame.board.live_to == C.LIVE_TO_VIDEO, frame.board.live_to)
frame.board.live_to = C.LIVE_TO_AUDIO


heading("A refusal stops, whichever attempt it happens on")

bus = streamout.AirBus(48000)
streamer = streamout.Streamer(bus, {"server": "youtube", "host": "x",
                                    "bitrate": 128})
streamer.attempts = 4          # a reconnect, not the first try
for message, retry in (("the stream key was refused", False),
                       ("there is no stream key", False),
                       # NOT fatal: it is the message for a stream that HAD
                       # been carrying sound and stopped, which is a USB
                       # interface hiccuping or a machine waking from sleep,
                       # and every one of those is worth reconnecting
                       # through. The zero bytes case below is the fatal one.
                       ("the audio stopped arriving", True),
                       ("could not find a.rtmps.youtube.com", True),
                       ("no sound ever reached the stream, so nothing was "
                        "broadcast", False),
                       ("connection reset by peer", True),
                       ("the server went away", True)):
    streamer.error = message
    check("%r %s" % (message[:38],
                     "keeps trying" if retry else "stops"),
          streamer._retryable() is retry, streamer._retryable())
streamer.attempts = 1          # and on the very first try
streamer.error = "could not find a.rtmps.youtube.com. Check the server address"
check("a name that will not resolve at Ctrl+B is a misspelt address",
      streamer._retryable() is False)
streamer.attempts = 3
check("the same message on a reconnect is the network, and it keeps trying",
      streamer._retryable() is True)
check("and the guard is consulted on every attempt, not only the first",
      "if not self._retryable():" in open(
          os.path.join(os.path.dirname(os.path.dirname(
              os.path.abspath(__file__))), "dropdeck", "streamout.py"),
          encoding="utf-8").read())


heading("An address that is not RTMP never reaches the encoder")

#: A board file is plain JSON and people send each other boards. This one
#: would have written the live microphone to a file, with the app saying
#: ON AIR and the pre-flight calling it a custom RTMP server.
for address in ("C:/Users/Public", "file:///C:/out.flv", "http://example.com",
                "udp://239.0.0.1:1234", "/tmp/out"):
    destination = streamout.RtmpDestination(
        {"server": "rtmp", "host": address, "password": "out.flv",
         "bitrate": 128}, 48000)
    try:
        destination.url()
        refused = ""
    except streamout.SinkError as exc:
        refused = str(exc)
    check("%r is refused" % address[:24], "rtmp" in refused.lower(), refused)

kept = streamout.RtmpDestination(
    {"server": "rtmp", "host": "rtmp://example.com/live", "password": "k",
     "bitrate": 128}, 48000)
check("and a real one still works",
      kept.url() == "rtmp://example.com/live/k", kept.url())

sneaky = os.path.join(tempfile.mkdtemp(prefix="dropdeck-384-board-"),
                      "given-to-me.json")
loaded = Board()
loaded.video_server = "rtmp"
loaded.video_host = "rtmp://example.com/live"
loaded.save(sneaky)
with open(sneaky, encoding="utf-8") as handle:
    raw = json.load(handle)
raw["video_host"] = "C:/Users/Public"
raw["video_server"] = "rtmp"
with open(sneaky, "w", encoding="utf-8") as handle:
    json.dump(raw, handle)
reopened = Board.load(sneaky)
#: Empty is the right answer, not a repaired one: there is no honest
#: address to substitute for a custom server, so the board opens with none
#: and the pre-flight stops with "there is no video platform set up yet".
#: What must never survive is the path.
check("a board file cannot smuggle one in either",
      "Public" not in reopened.video_host, reopened.video_host)
check("and what is left is either nothing or a real RTMP address",
      not reopened.video_host or reopened.video_host.startswith("rtmp"),
      reopened.video_host)


heading("Ctrl+Shift+B says when nothing has left the machine")


class Pretend:
    running = True
    state = streamout.ON_AIR
    on_air_for = 12.0
    backlog = 0.0
    reconnects = 0
    bytes_sent = 0
    detail = ""
    error = ""
    _destination = None


frame.streamer = Pretend()
said = frame.stream_status()
check("a stream that has sent nothing says so",
      "nothing has left this machine" in said, said)
Pretend.bytes_sent = 900000
said = frame.stream_status()
check("and one that is really going out does not",
      "nothing has left this machine" not in said, said)
frame.streamer = None


heading("Where listeners connect is actually saved")

#: Typed, read back by the dialog's own property, and then dropped on the
#: floor: nothing in the app ever assigned it.
frame.board.stream_stats_url = ""
page = SettingsDialog(frame, frame.board, frame.mixer, mic=frame.mic,
                      page=SettingsDialog.PAGE_STREAM)
page.stream_stats.SetValue("https://listen.example.com/status-json.xsl")
check("the OK handler has somewhere to put it",
      "stream_stats_url = stream" in open(
          os.path.join(os.path.dirname(os.path.dirname(
              os.path.abspath(__file__))), "dropdeck", "ui.py"),
          encoding="utf-8").read().replace('board.stream_stats_url',
                                           'stream_stats_url'))
frame.board.stream_stats_url = page.stream_settings["stats_url"]
check("and it survives a save and a load",
      Board.load(_saved(frame.board)).stream_stats_url
      == "https://listen.example.com/status-json.xsl")
page.Destroy()


heading("A camera is not lost by opening Preferences too fast")

frame.board.camera = "My Webcam"
quick = SettingsDialog(frame, frame.board, frame.mixer, mic=frame.mic,
                       page=SettingsDialog.PAGE_VIDEO)
quick._cameras = []                      # the list has not come back yet
check("a camera is kept while the list is still loading",
      quick.picture_settings["camera"] == "My Webcam",
      quick.picture_settings["camera"])
quick._cameras = ["Another Webcam"]      # the list came back without it
check("and cleared only once we know it is not there",
      quick.picture_settings["camera"] == "",
      quick.picture_settings["camera"])
quick.Destroy()


heading("A picture that will not start is said, not swallowed")

feed = picturefeed.PictureFeed(lambda: {"picture": C.PICTURE_CARD})
real_open = feed._open


def explode():
    raise RuntimeError("no picture today")


feed._open = explode
handle = feed.acquire("test")
check("acquire does not raise", handle is not None)
check("and the reason is kept where it can be said",
      "could not be started" in (feed.reason or ""), feed.reason)
feed._open = real_open
feed.release("test")


heading("FFmpeg's log level is put back")

import av                                                        # noqa: E402
before = av.logging.get_level()
with streamout._ffmpeg_log():
    pass
check("one broadcast does not leave every later decode at INFO",
      av.logging.get_level() == before,
      (before, av.logging.get_level()))


heading("The audits' own findings, each with a check of its own")

# ---- Mark 2: verify() must always come back --------------------------------
import socket as _socket                                         # noqa: E402
import struct as _struct                                         # noqa: E402
import threading as _threading                                   # noqa: E402
import time as _time                                             # noqa: E402


def _chatterbox(port, ready):
    """A server that finishes the handshake and then talks for ever.

    Every control message it sends is a `continue` in the reader, so a loop
    counter bounds nothing: this is what ran for thirty seconds against a
    documented ten second timeout, leaving the button disabled for the rest
    of the session because the answer never arrived.
    """
    listener = _socket.socket()
    listener.setsockopt(_socket.SOL_SOCKET, _socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", port))
    listener.listen(1)
    ready.set()
    try:
        client, _ = listener.accept()
        client.recv(1537)
        client.sendall(bytes([3]) + bytes(1536) + bytes(1536))
        client.recv(1536)
        while True:
            payload = _struct.pack(">HI", 6, 0)
            head = (bytes([2]) + b"\x00\x00\x00"
                    + _struct.pack(">I", len(payload))[1:] + bytes([4])
                    + _struct.pack("<I", 0))
            client.sendall(head + payload)
            _time.sleep(0.05)
    except Exception:
        pass


_port = 19353
_ready = _threading.Event()
_threading.Thread(target=_chatterbox, args=(_port, _ready), daemon=True).start()
_ready.wait(3)
_began = _time.monotonic()
_answer = rtmpcheck.verify("rtmp://127.0.0.1:%d/live" % _port, "k", timeout=3)
_took = _time.monotonic() - _began
check("a server that never answers still comes back",
      _answer.outcome == rtmpcheck.NO_ANSWER, _answer.outcome)
check("inside the time it was given", _took < 6.0, "%.1fs" % _took)
check("and says so in words a person can act on",
      "in time" in _answer.detail, _answer.detail)

check("a message too large to be a command is refused",
      rtmpcheck.MAX_MESSAGE <= 1024 * 1024, rtmpcheck.MAX_MESSAGE)

# ---- Jessica 3: never speak a status code ----------------------------------
check("a status code is never offered as the platform's words",
      rtmpcheck._said({"code": "NetStream.Publish.BadName"}) == "",
      rtmpcheck._said({"code": "NetStream.Publish.BadName"}))
check("a real description is",
      rtmpcheck._said({"code": "X", "description": "Publish Rejected"})
      == "Publish Rejected")
check("and a server cannot make a spoken line any length it likes",
      len(rtmpcheck._said({"description": "x" * 5000}))
      <= rtmpcheck.SAY_LIMIT, len(rtmpcheck._said({"description": "x" * 5000})))

# ---- Jessica 2: no address and no Windows error in a spoken line -----------
for _outcome in (rtmpcheck.NO_SERVER, rtmpcheck.NO_ROUTE, rtmpcheck.NO_TLS):
    _line = prefs._key_verdict(
        rtmpcheck.Result(_outcome, detail="[WinError 10060] it went wrong"),
        "youtube", "YouTube Live", "a.rtmps.youtube.com", "abcd-efgh")
    check("%s names the platform, not its address" % _outcome,
          "a.rtmps.youtube.com" not in _line, _line)
    check("%s never reads a Windows error out" % _outcome,
          "WinError" not in _line and "10060" not in _line, _line)

# ---- Jessica 5: who gets asked before a check ------------------------------
check("Facebook is known safe and is not asked about",
      C.RTMP_GOES_LIVE_AT_ONCE.get("facebook") is False)
check("a server Drop Deck does not know is an unknown, not a promise",
      C.RTMP_GOES_LIVE_AT_ONCE.get("rtmp") is None,
      C.RTMP_GOES_LIVE_AT_ONCE.get("rtmp"))
check("and so is Restream", C.RTMP_GOES_LIVE_AT_ONCE.get("restream") is None)

# ---- Jessica 1: the button keeps focus while a check runs ------------------
check("the button is not disabled under the user's finger",
      not hasattr(prefs, "_set_video_test_enabled"))
check("a second press is refused by a flag instead",
      prefs._checking is False)
prefs._checking = True
prefs._test_rtmp({"host": C.RTMP_INGEST["youtube"], "key": "abcd",
                  "server": "youtube"})
check("which says so rather than starting a second check",
      "Still checking" in prefs.picture_result.GetValue(),
      prefs.picture_result.GetValue())
check("and the button is still enabled", prefs.video_test.IsEnabled())
prefs._checking = False
check("the reassurance is in the box, where a keyboard user meets it",
      "no sound and no picture"
      in SettingsDialog(frame, frame.board, frame.mixer, mic=frame.mic,
                        page=SettingsDialog.PAGE_VIDEO).picture_result
      .GetValue())

# ---- Mark 6: an untouched key box changes nothing --------------------------


class Video(dict):
    pass


frame.board.video_key = "came-in-on-somebody-elses-board"
frame.board.stream_name = "Mine"
secrets.forget("Mine")
frame._apply_stream_key({"key": "came-in-on-somebody-elses-board",
                         "key_changed": False}, "Mine", "Mine")
check("a key nobody touched is not promoted into Credential Manager",
      secrets.fetch("Mine") == "", secrets.fetch("Mine"))
check("and is left exactly where it was",
      frame.board.video_key == "came-in-on-somebody-elses-board")

# ---- Mark 5: a rename must not rob a station that is still on the shelf ----
if secrets.store("Alpha", "ALPHA-KEY") and secrets.store("Beta", "BETA-KEY"):
    frame.board.stream_stations = [{"stream_name": "Alpha"},
                                   {"stream_name": "Beta"}]
    frame.board.video_key = ""
    frame._apply_stream_key({"key": "ALPHA-KEY", "key_changed": False},
                            "Alpha", "A New Name")
    check("renaming carries the key to the new name",
          secrets.fetch("A New Name") == "ALPHA-KEY",
          secrets.fetch("A New Name"))
    check("and does NOT rob the saved station of the same name",
          secrets.fetch("Alpha") == "ALPHA-KEY", secrets.fetch("Alpha"))
    check("the other station is untouched",
          secrets.fetch("Beta") == "BETA-KEY")
    # A name that is no longer a station SHOULD be cleaned up.
    frame.board.stream_stations = [{"stream_name": "Beta"}]
    frame._apply_stream_key({"key": "ALPHA-KEY", "key_changed": False},
                            "Alpha", "A New Name")
    check("a name that is no longer a station is tidied away",
          secrets.fetch("Alpha") == "", secrets.fetch("Alpha"))
    for gone in ("Alpha", "Beta", "A New Name", "Mine"):
        secrets.forget(gone)
else:
    check("SKIPPED: this machine has no credential store", True)
frame.board.stream_stations = []
frame.board.video_key = ""

# ---- Mark 10: a saved station is whitelisted like a board file -------------
frame.board.stream_stations = [{
    "stream_name": "Their Setup", "video_server": "rtmp",
    "video_host": "C:/Users/Public", "live_to": C.LIVE_TO_VIDEO}]
frame.board.video_host = C.RTMP_INGEST["youtube"]
frame.board.load_station("Their Setup")
check("a saved station cannot smuggle a path in either",
      "Public" not in frame.board.video_host, frame.board.video_host)
frame.board.stream_stations = []

# ---- Mark 11: an address with no scheme is kept so it can be corrected -----
from dropdeck.board import _rtmp_address                          # noqa: E402
check("an address somebody typed without rtmp is kept, not erased",
      _rtmp_address("live.example.com/app") == "live.example.com/app")
check("but the encoder still refuses it", True)
try:
    streamout.RtmpDestination(
        {"server": "rtmp", "host": "live.example.com/app", "password": "k",
         "bitrate": 128}, 48000).url()
    _refused = ""
except streamout.SinkError as exc:
    _refused = str(exc)
check("with a sentence saying what it has to start with",
      "rtmp" in _refused.lower(), _refused)


heading("The settings move never tells you to delete a board it did not copy")

with Portable() as copy:
    old = fill_legacy(board__json='{"slots": []}')
    # A board.json that cannot be read, which is a real state on this
    # machine: Dropbox and virus scanners hold new files open.
    real_copy2 = shutil.copy2

    def refuse(source, target, *a, **kw):
        if os.path.basename(source) == "board.json":
            raise OSError(32, "being used by another process")
        return real_copy2(source, target, *a, **kw)

    shutil.copy2 = refuse
    try:
        boardmod._forget_config_dir()
        where = boardmod.config_dir()
    finally:
        shutil.copy2 = real_copy2
    check("the board really did not arrive",
          not os.path.exists(os.path.join(where, "board.json")),
          sorted(os.listdir(where)))
    check("so the user is told NOT to delete the old folder",
          "do NOT delete" in boardmod.data_note, boardmod.data_note)
    check("and is told what to do about it",
          "start Drop Deck again" in boardmod.data_note, boardmod.data_note)

with Portable() as copy:
    old = fill_legacy(board__json='{"slots": []}')
    with open(os.path.join(old, boardmod.LAST_BOARD_FILE), "w",
              encoding="utf-8") as handle:
        json.dump({"path": os.path.join(old, "board.json")}, handle)
    # One already in the new folder, which the copy skips, so it never
    # appeared in what was brought and was never repointed.
    os.makedirs(copy.userdata, exist_ok=True)
    with open(os.path.join(copy.userdata, boardmod.LAST_BOARD_FILE), "w",
              encoding="utf-8") as handle:
        json.dump({"path": os.path.join(old, "board.json")}, handle)
    boardmod._forget_config_dir()
    where = boardmod.config_dir()
    remembered = boardmod.remembered_board_path()
    check("a remembered board is followed even when its note was already there",
          boardmod.same_path(remembered, os.path.join(where, "board.json")),
          remembered)

with Portable() as copy:
    os.environ[boardmod.DATA_ENV] = temp_dir("dropdeck-384-named2-")
    try:
        fill_legacy(board__json='{"slots": []}')
        boardmod._forget_config_dir()
        boardmod.config_dir()
        check("a folder somebody named is not called 'beside the program'",
              "beside the program" not in boardmod.data_note,
              boardmod.data_note)
        check("and the sentence does not end in a full stop, so the startup "
              "line does not say two",
              not boardmod.data_note.rstrip().endswith("."),
              boardmod.data_note)
    finally:
        del os.environ[boardmod.DATA_ENV]


# ===========================================================================
prefs.Destroy()
frame.stop_background_work()
frame.mixer.close()
frame.Destroy()


# ===========================================================================
shutil.rmtree(made_by_hand, ignore_errors=True)
print("\n%d/%d checks passed" % (sum(CHECKS), len(CHECKS)))
sys.stdout.flush()
os._exit(0 if all(CHECKS) else 1)
