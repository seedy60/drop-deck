"""Why the microphone is not working, in words somebody can act on.

Mashal, 19 September 2026, relayed by Tony: Ctrl+M did nothing at all. The
installed copy and the portable one, after a restart, with the Windows
microphone privacy settings checked, and nobody else was seeing it.

Nothing in the app could have said what was wrong, because nothing was
looking. Three different things stop that key, and each needs its own answer:

1. **The key never arrives.** A program that registers Ctrl+M as a system
   wide hotkey takes it from every window on the machine, Drop Deck included,
   and Windows does not tell the window it was taken from. `held_elsewhere`
   asks Windows directly, by trying to register the key and letting go of it
   at once. A screen reader add-on that takes a key through a keyboard hook
   cannot be seen that way, which is why the microphone has a second key and
   the F1 text says how to ask NVDA.
2. **The microphone will not open.** PortAudio's words for that are
   "Unanticipated host error [PaErrorCode -9999]" and a negative number,
   which is accurate and no use to anybody on air. `explain` turns the codes
   Windows really returns into a sentence that says what to do next.
3. **It opens and Windows hands over silence.** Some of Windows' audio paths
   do exactly that when privacy settings block a program, and all of them do
   it for a muted input. `privacy` reads the same switches the Settings page
   writes.

Like `micinput`, this knows nothing about wx, so every answer in it can be
checked against made up input.
"""
from __future__ import annotations

import ctypes
import re
import sys

_WINDOWS = sys.platform == "win32"

# ------------------------------------------------------------- privacy ---
ALLOWED = "allowed"
BLOCKED = "blocked"
UNKNOWN = "unknown"

_CONSENT = (r"Software\Microsoft\Windows\CurrentVersion"
            r"\CapabilityAccessManager\ConsentStore\microphone")
_POLICY = r"SOFTWARE\Policies\Microsoft\Windows\AppPrivacy"
#: LetAppsAccessMicrophone: 0 leaves it to the user, 1 forces it on, 2 off.
_POLICY_FORCE_DENY = 2

#: Where to go, in the Settings app's own words. All three switches, because
#: which registry key each of them writes has moved between versions of
#: Windows, and naming all three costs one sentence.
PRIVACY_FIX = ("Open Windows Settings, Privacy and security, Microphone, and "
               "turn on Microphone access, Let apps access your microphone, "
               "and Let desktop apps access your microphone")

PRIVACY_BLOCKED = ("Windows privacy settings are stopping programs from using "
                   "the microphone. " + PRIVACY_FIX)

POLICY_BLOCKED = ("A policy set by whoever manages this computer stops "
                  "programs from using the microphone, and only they can "
                  "change it")


def _read_registry(root, path, name):
    """One registry value, or None. `root` is "HKLM" or "HKCU"."""
    if not _WINDOWS:
        return None
    try:
        import winreg
        hive = {"HKLM": winreg.HKEY_LOCAL_MACHINE,
                "HKCU": winreg.HKEY_CURRENT_USER}[root]
        with winreg.OpenKey(hive, path) as key:
            return winreg.QueryValueEx(key, name)[0]
    except Exception:
        return None


def privacy(read=_read_registry):
    """What Windows' microphone privacy switches say, as (state, sentence).

    `state` is ALLOWED, BLOCKED or UNKNOWN, and the sentence is empty unless
    it is BLOCKED. Any switch that says Deny counts: they are three different
    questions and a no to any of them is a no to this program.
    """
    try:
        policy = read("HKLM", _POLICY, "LetAppsAccessMicrophone")
        if policy == _POLICY_FORCE_DENY:
            return BLOCKED, POLICY_BLOCKED
        switches = (read("HKLM", _CONSENT, "Value"),
                    read("HKCU", _CONSENT, "Value"),
                    read("HKCU", _CONSENT + r"\NonPackaged", "Value"))
    except Exception:
        return UNKNOWN, ""
    if any(isinstance(value, str) and value.strip().lower() == "deny"
           for value in switches):
        return BLOCKED, PRIVACY_BLOCKED
    if all(value is None for value in switches):
        return UNKNOWN, ""
    return ALLOWED, ""


# -------------------------------------------------------------- errors ---
#: HRESULTs out of Windows' audio stack. PortAudio reports them as a signed
#: decimal after "WASAPI error" or "DirectSound error", so they are compared
#: as unsigned here.
_E_ACCESSDENIED = 0x80070005
_AUDCLNT_E_DEVICE_INVALIDATED = 0x88890004
_AUDCLNT_E_UNSUPPORTED_FORMAT = 0x88890008
_AUDCLNT_E_DEVICE_IN_USE = 0x8889000A
_AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED = 0x8889000E
_AUDCLNT_E_ENDPOINT_CREATE_FAILED = 0x8889000F
_AUDCLNT_E_SERVICE_NOT_RUNNING = 0x88890010
_DSERR_ALLOCATED = 0x8878000A
_DSERR_NODRIVER = 0x88780078

#: waveIn results, which is what MME reports.
_MMSYSERR_BADDEVICEID = 2
_MMSYSERR_ALLOCATED = 4
_MMSYSERR_NODRIVER = 6
_WAVERR_BADFORMAT = 32

#: PortAudio's own.
_PA_DEVICE_UNAVAILABLE = -9985
_PA_INVALID_DEVICE = -9996
_PA_INVALID_RATE = -9997
_PA_INVALID_CHANNELS = -9998
_PA_HOST_ERROR = -9999

ACCESS_DENIED = ("Windows refused Drop Deck access to it, which is what the "
                 "privacy settings do. " + PRIVACY_FIX)
#: The exclusive mode switch is only in the old Sound control panel on
#: Windows 11, not in Settings, so the sentence says how to reach it.
IN_USE = ("Another program is holding it for itself. Close the other "
          "programs using it, or press Windows+R, type mmsys.cpl, open the "
          "microphone's Properties on the Recording tab, and on Advanced "
          "turn off Allow applications to take exclusive control of this "
          "device")
GONE = ("Windows no longer has it. It may be unplugged, or disabled in "
        "Windows Sound settings")
NOT_AVAILABLE = ("Windows says it is not available. Another program may be "
                 "holding it, or it has been unplugged")
NO_SERVICE = ("The Windows Audio service is not running. Restarting the "
              "computer usually brings it back")
NO_DRIVER = "Windows has no working driver for it"
BAD_FORMAT = "It would not take any of the formats Drop Deck asked for"
REFUSED = ("Windows would not open it and did not say why. Privacy settings "
           "are the usual cause, then another program holding it")
NOTHING_THERE = "Windows has no microphone to give Drop Deck"


def _hresults(text):
    found = set()
    for api in ("WASAPI", "DirectSound", "WDM-KS"):
        for value in re.findall(api + r" error (-?\d+)", text):
            found.add(int(value) & 0xFFFFFFFF)
    return found


def explain(text):
    """The failure a microphone reported, as one plain sentence.

    `text` is what `MicInput.last_error` holds: every attempt's PortAudio
    error, joined. When the attempts failed for different reasons the most
    specific one wins, because "access denied" at one rate and "invalid
    sample rate" at another is a privacy problem, not a format problem.
    """
    text = str(text or "")
    lowered = text.lower()
    codes = _hresults(text)
    mme = {int(value) for value in re.findall(r"MME error (-?\d+)", text)}
    portaudio = {int(value)
                 for value in re.findall(r"PaErrorCode (-?\d+)", text)}

    if (_E_ACCESSDENIED in codes or "e_accessdenied" in lowered
            or "access is denied" in lowered):
        return ACCESS_DENIED
    if (codes & {_AUDCLNT_E_DEVICE_IN_USE, _DSERR_ALLOCATED,
                 _AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED}
            or _MMSYSERR_ALLOCATED in mme
            or "audclnt_e_device_in_use" in lowered):
        return IN_USE
    if (_AUDCLNT_E_DEVICE_INVALIDATED in codes or _MMSYSERR_BADDEVICEID in mme
            or _PA_INVALID_DEVICE in portaudio
            or "audclnt_e_device_invalidated" in lowered):
        return GONE
    if (_AUDCLNT_E_SERVICE_NOT_RUNNING in codes
            or "audclnt_e_service_not_running" in lowered):
        return NO_SERVICE
    if (codes & {_DSERR_NODRIVER, _AUDCLNT_E_ENDPOINT_CREATE_FAILED}
            or _MMSYSERR_NODRIVER in mme):
        return NO_DRIVER
    if _PA_DEVICE_UNAVAILABLE in portaudio:
        return NOT_AVAILABLE
    if (_AUDCLNT_E_UNSUPPORTED_FORMAT in codes or _WAVERR_BADFORMAT in mme
            or (portaudio and portaudio <= {_PA_INVALID_RATE,
                                            _PA_INVALID_CHANNELS})):
        return BAD_FORMAT
    if "no microphone available" in lowered:
        return NOTHING_THERE
    return REFUSED


# ---------------------------------------------------------------- keys ---
MOD_ALT, MOD_CONTROL, MOD_SHIFT, MOD_WIN = 0x0001, 0x0002, 0x0004, 0x0008
_MOD_NOREPEAT = 0x4000
_ERROR_HOTKEY_ALREADY_REGISTERED = 1409
#: Any id this thread is not using. It is held for a few microseconds.
_PROBE_ID = 0xBF3D
_VK_TAB = 0x09
_VK_F4 = 0x73

#: Keys Windows keeps for itself and reports as taken on every machine.
#: Ctrl+Alt+Tab is the persistent task switcher, and the menu already says
#: Windows usually has it; Alt+F4 is on the File menu because it closes a
#: window everywhere, and Windows delivers it as that, not as a key. Measured
#: 19 September 2026: of the 94 keys the app answers to, these two and only
#: these two report as taken on a machine where nothing else holds any.
#: Saying so at every start would be noise that teaches people to ignore the
#: line.
WINDOWS_OWN = {(MOD_CONTROL | MOD_ALT, _VK_TAB), (MOD_ALT, _VK_F4)}

_user32 = None


def _dll():
    global _user32
    if not _WINDOWS:
        return None
    if _user32 is None:
        try:
            from ctypes import wintypes
            dll = ctypes.WinDLL("user32", use_last_error=True)
            dll.RegisterHotKey.argtypes = [wintypes.HWND, ctypes.c_int,
                                           wintypes.UINT, wintypes.UINT]
            dll.RegisterHotKey.restype = wintypes.BOOL
            dll.UnregisterHotKey.argtypes = [wintypes.HWND, ctypes.c_int]
            dll.UnregisterHotKey.restype = wintypes.BOOL
            _user32 = dll
        except Exception:
            return None
    return _user32


def held_elsewhere(mods, vk):
    """Has another program taken this key for the whole machine?

    True if it has, False if the key is free, None if this cannot be asked.
    Asked the only way Windows answers: by registering the key ourselves and
    letting go at once. It fails with ERROR_HOTKEY_ALREADY_REGISTERED only
    when somebody else holds it, and while anybody holds it, Windows hands
    every press to them and never to the window that has focus.
    """
    dll = _dll()
    if dll is None:
        return None
    try:
        if dll.RegisterHotKey(None, _PROBE_ID,
                              (int(mods) & 0x000F) | _MOD_NOREPEAT, int(vk)):
            dll.UnregisterHotKey(None, _PROBE_ID)
            return False
        return ctypes.get_last_error() == _ERROR_HOTKEY_ALREADY_REGISTERED
    except Exception:
        return None


def taken_elsewhere(keys, own=()):
    """Which of these keys another program holds, as their labels.

    `keys` is (label, mods, vk) for every key the app answers to. `own` is
    the (mods, vk) of anything this app has registered itself, because a
    global hotkey of ours looks exactly like somebody else's from here.
    """
    mine = {(int(m) & 0x000F, int(v)) for m, v in own}
    labels = []
    seen = set()
    for label, mods, vk in keys:
        key = (int(mods) & 0x000F, int(vk))
        if key in seen or key in mine or key in WINDOWS_OWN:
            continue
        seen.add(key)
        if held_elsewhere(*key):
            labels.append(label)
    return labels


def join(words):
    """"A", "A and B", "A, B and C". For a sentence that lists keys."""
    words = [w for w in words if w]
    if len(words) <= 1:
        return "".join(words)
    return ", ".join(words[:-1]) + " and " + words[-1]


def keys_sentence(labels, mic_key="Ctrl+M", spare="Alt+Shift+M"):
    """What to say when keys are taken. Empty when none are."""
    if not labels:
        return ""
    shown = list(labels[:6])
    more = len(labels) - len(shown)
    if more:
        shown.append("%d more" % more)
    one = len(labels) == 1
    line = ("Another program on this computer has taken %s for itself, so "
            "pressing %s never reaches Drop Deck"
            % (join(shown), "it" if one else "them"))
    if mic_key in labels and spare in labels:
        line += ". Microphone on, in the Playlist menu, still works"
    elif mic_key in labels:
        line += (". %s turns the microphone on and off as well, and so does "
                 "Microphone on in the Playlist menu" % spare)
    return line
