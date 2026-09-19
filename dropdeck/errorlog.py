"""Faults that would otherwise vanish without a trace.

A released copy is a windowed program with no console. wxPython hands an
exception raised inside an event handler to `sys.excepthook`, and the default
hook prints it to a stderr that does not exist, so a key whose handler raises
simply does nothing: no sound, no speech, and nothing anywhere to find
afterwards. Measured 19 September 2026: a handler raising under
`ProcessEvent` and under the event loop both arrive at `sys.excepthook`.

That is the shape of Mashal's report, Ctrl+M doing nothing at all on one
machine, and the app had no way to tell anybody why. So:

- every such fault is written to `errors.log` beside the board, with the
  whole traceback, where support can ask for it;
- and a one line summary of each, WHERE and WHAT KIND, is kept for the
  feedback window. Never the message: an exception's message can carry a
  file path or a sound's name, and the feedback promise is that neither is
  ever sent.

Nothing here speaks. A fault in a timer can repeat four times a second, and a
fault that turns into an announcement at a random moment in a show is a new
fault. The places that must not fail silently, like the microphone key, catch
their own and say so in words.

Nothing here is allowed to raise either, or the safety net becomes the fall.
"""
from __future__ import annotations

import os
import sys
import threading
import time
import traceback
from collections import deque

LOG_NAME = "errors.log"
#: Past this the log starts again, keeping the most recent half. A log that
#: grows for ever on somebody's disk is its own bug.
MAX_BYTES = 256 * 1024
#: How many summaries the feedback window gets.
KEEP = 8

_recent = deque(maxlen=KEEP)
_lock = threading.Lock()
_installed = False
_previous = {}


def log_path():
    try:
        from .board import config_dir
        return os.path.join(config_dir(), LOG_NAME)
    except Exception:
        return None


def where(tb):
    """The innermost place in THIS app's code, as "module.function".

    The innermost frame is often inside wx or numpy, which says nothing about
    which of our commands failed. The last frame that belongs to the
    `dropdeck` package does.
    """
    ours = None
    last = None
    for frame in traceback.extract_tb(tb):
        name = frame.filename.replace("\\", "/")
        module = os.path.splitext(os.path.basename(name))[0]
        last = "%s.%s" % (module, frame.name)
        if "/dropdeck/" in name or name.startswith("dropdeck/"):
            ours = last
    return ours or last or "unknown"


def summary(exc_type, tb):
    return "%s: %s" % (where(tb), getattr(exc_type, "__name__", "Error"))


def record(exc_type, exc, tb, thread=None):
    """Write one fault down. Returns its one line summary. Never raises."""
    try:
        line = summary(exc_type, tb)
        with _lock:
            if line not in _recent:
                _recent.append(line)
        _write(exc_type, exc, tb, thread)
        return line
    except Exception:
        return ""


def record_current(thread=None):
    """The same, for the exception being handled right now."""
    exc_type, exc, tb = sys.exc_info()
    if exc_type is None:
        return ""
    return record(exc_type, exc, tb, thread)


def recent():
    """What went wrong this session, as "module.function: Kind" lines."""
    with _lock:
        return list(_recent)


def _write(exc_type, exc, tb, thread):
    path = log_path()
    if not path:
        return
    try:
        from . import constants as C
        version = C.APP_VERSION
    except Exception:
        version = "?"
    text = "".join(traceback.format_exception(exc_type, exc, tb))
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    entry = "=== %s  version %s  thread %s\n%s\n" % (
        stamp, version, thread or threading.current_thread().name, text)
    with _lock:
        try:
            if os.path.getsize(path) > MAX_BYTES:
                with open(path, "r", encoding="utf-8", errors="replace") as fh:
                    kept = fh.read()[-MAX_BYTES // 2:]
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(kept)
        except OSError:
            pass
        try:
            with open(path, "a", encoding="utf-8") as fh:
                fh.write(entry)
        except OSError:
            pass


def _hook(exc_type, exc, tb):
    if not issubclass(exc_type, KeyboardInterrupt):
        record(exc_type, exc, tb)
    previous = _previous.get("sys")
    if previous is not None:
        try:
            previous(exc_type, exc, tb)
        except Exception:
            pass


def _thread_hook(args):
    if args.exc_type is not SystemExit:
        record(args.exc_type, args.exc_value, args.exc_traceback,
               thread=getattr(args.thread, "name", None))
    previous = _previous.get("thread")
    if previous is not None:
        try:
            previous(args)
        except Exception:
            pass


def install():
    """Catch what nothing else catches. Safe to call more than once."""
    global _installed
    if _installed:
        return
    _installed = True
    _previous["sys"] = sys.excepthook
    _previous["thread"] = getattr(threading, "excepthook", None)
    sys.excepthook = _hook
    if _previous["thread"] is not None:
        threading.excepthook = _thread_hook
