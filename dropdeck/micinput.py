"""The microphone: an input stream, a gain, and optional monitoring.

The first piece of the live-show side of the app. Three jobs, and they are
deliberately separate:

**Capture.** One `sounddevice.InputStream`, opened at the smallest block the
device will take and asked for low latency, because a monitored microphone with
a lag on it is unusable, you hear yourself late and you cannot speak over it.

**Ducking.** While the microphone is open, everything musical gets out of the
way. That is not done by listening to the level: it is done by the fact that the
microphone is *on*. A gate that opens on your voice clips the first syllable of
every sentence, and one that stays open ducks the bed when you cough. Open means
ducked; closed means back up. `DuckBus` already exists for exactly this, it is
how a drop on one sound card ducks a bed on another, so the microphone simply
publishes onto it under its own key.

**Monitoring.** Off by default, and it says why: on speakers it is a feedback
loop. On headphones it is how you know you are live. The captured blocks go into
a small ring buffer that the output mixer drains; if it runs dry the mixer gets
silence rather than a stall, because a starved monitor must never take the
music down with it.

Like `engine.py` and `mixer.py`, this module knows nothing about wx.
"""

from __future__ import annotations

import threading

import numpy as np
import sounddevice as sd
import soxr

from . import constants as C
from .engine import CHANNELS, db_to_gain
from .mixer import all_devices, host_api_names

#: The key the microphone publishes under on the shared DuckBus. Anything but
#: a mixer's own key, which is what the mixers publish their own drops under.
DUCK_KEY = "microphone"

#: The ways Windows offers one microphone, in the order a failed one is
#: retried. WDM-KS is not on the list: it takes the device away from every
#: other program while it is open, which is not something to fall back into.
FALLBACK_APIS = ("Windows WASAPI", "Windows DirectSound", "MME")

#: MME cuts every device name to 31 characters, so the same microphone is
#: "Microphone (Yeti Stereo Microph" there and the full name everywhere else.
MME_NAME_LENGTH = 31

#: What `fell_back_from` says when the microphone asked for was the system
#: default. It cannot be None, because None is "it opened as asked", and a
#: default that would not open was then never mentioned anywhere.
SYSTEM_DEFAULT = "system default"


def input_devices():
    """Every input the machine offers, newest APIs first.

    Same shape and the same ordering as ``mixer.output_devices``: WASAPI at the
    top because that is where the low latency and the virtual cables are.

    Never raises. This runs inside the Ctrl+M handler, and a device list that
    raised there made the key do nothing at all, with nothing said.
    """
    hostapis = host_api_names()
    found = []
    for index, dev in all_devices():
        if dev["hostapi"] >= len(hostapis):
            continue
        if dev["max_input_channels"] < 1:
            continue
        found.append({
            "index": index,
            "name": dev["name"],
            "hostapi": hostapis[dev["hostapi"]],
            "channels": dev["max_input_channels"],
            "samplerate": int(dev["default_samplerate"]),
        })
    preferred = {"Windows WASAPI": 0, "Windows DirectSound": 1, "MME": 2}
    found.sort(key=lambda d: (preferred.get(d["hostapi"], 3), d["name"].lower()))
    return found


def describe_input(device):
    """A spoken-friendly name for one input index, or the system default."""
    if device is None:
        try:
            return "%s (system default)" % sd.query_devices(kind="input")["name"]
        except Exception:
            return "system default"
    try:
        info = sd.query_devices(device)
        return "%s (%s)" % (info["name"],
                            sd.query_hostapis(info["hostapi"])["name"])
    except Exception:
        return "unknown device"


def resolve_input(spec):
    """Turn a saved {name, hostapi} back into a live index, or None.

    Remembered by name for the same reason outputs are: indices move the moment
    anything is plugged in or unplugged.
    """
    if not spec or not spec.get("name"):
        return None
    name = spec.get("name")
    hostapi = spec.get("hostapi")
    devices = input_devices()
    for device in devices:
        if device["name"] == name and device["hostapi"] == hostapi:
            return device["index"]
    for device in devices:
        if device["name"] == name:
            return device["index"]
    return None


def _same_microphone(a, b):
    """Are two device names the same microphone under two host APIs.

    Equal, or one is the other cut short the way MME cuts every name.
    """
    if not a or not b:
        return False
    if a == b:
        return True
    short, full = sorted((a, b), key=len)
    return len(short) == MME_NAME_LENGTH and full.startswith(short)


def alternatives(device):
    """The same microphone reached another way, best first.

    One physical microphone appears several times over, once per host API,
    and they fail independently: a device another program has taken for
    itself under WASAPI can still be shared under DirectSound or MME, and a
    driver that refuses one format on one path takes it on another. So when
    the chosen one will not open, these are tried before giving up.

    For the system default it is each host API's own default input, since
    PortAudio's default is only ever MME's.
    """
    try:
        hostapis = sd.query_hostapis()
    except Exception:
        return []
    names = [h["name"] for h in hostapis]
    order = {api: rank for rank, api in enumerate(FALLBACK_APIS)}
    devices = input_devices()
    if device is None:
        found = []
        for api in FALLBACK_APIS:
            if api not in names:
                continue
            index = hostapis[names.index(api)].get("default_input_device", -1)
            if isinstance(index, int) and index >= 0:
                found.append(index)
        return found
    here = next((d for d in devices if d["index"] == device), None)
    if here is None:
        return []
    if _ambiguous(here["name"], devices):
        return []
    found = [d for d in devices
             if d["index"] != device and d["hostapi"] in order
             and _same_microphone(d["name"], here["name"])
             and not _ambiguous(d["name"], devices)]
    found.sort(key=lambda d: order[d["hostapi"]])
    return [d["index"] for d in found]


def _default_input_index():
    """The index PortAudio opens for "the system default", or None."""
    try:
        return int(sd.query_devices(kind="input")["index"])
    except Exception:
        return None


def _ambiguous(name, devices):
    """Could this name be more than one microphone.

    MME cuts names to 31 characters, so "Headset Microphone (Plantronics" is
    a BT600 and a Blackwire at once. Mark, 19 September 2026: with the BT600
    refusing, the other headset opened and was announced as the one chosen.
    A cut name counts as a microphone only when exactly one full name starts
    with it and no other MME device carries it.
    """
    if len(name) != MME_NAME_LENGTH:
        return False
    longer = {d["name"] for d in devices
              if len(d["name"]) > MME_NAME_LENGTH
              and d["name"].startswith(name)}
    same_cut = sum(1 for d in devices
                   if d["hostapi"] == "MME" and d["name"] == name)
    return len(longer) > 1 or same_cut > 1


def host_api_of(device):
    """The host API a device index belongs to, for saying how it opened."""
    try:
        info = sd.query_devices(device, kind="input") if device is None \
            else sd.query_devices(device)
        return sd.query_hostapis(info["hostapi"])["name"]
    except Exception:
        return ""


def input_rate(device):
    """The rate a microphone actually wants, or a sane guess."""
    try:
        if device is None:
            info = sd.query_devices(kind="input")
        else:
            info = sd.query_devices(device)
        return int(info["default_samplerate"])
    except Exception:
        return C.DEFAULT_SAMPLERATE


class _Ring:
    """A block of audio written by one callback and drained by another.

    Nothing here locks: MicInput owns the lock, because the two rings are
    written in the same breath and a reader must not see one updated and not
    the other.
    """

    def __init__(self, frames=None):
        self.buf = np.zeros((frames or C.MIC_RING_FRAMES, CHANNELS),
                            dtype=np.float32)
        self.write_at = 0
        self.available = 0

    def clear(self):
        self.buf[:] = 0.0
        self.write_at = 0
        self.available = 0

    def write(self, block):
        room = len(self.buf)
        count = min(len(block), room)
        end = self.write_at + count
        if end <= room:
            self.buf[self.write_at:end] = block[:count]
        else:
            first = room - self.write_at
            self.buf[self.write_at:] = block[:first]
            self.buf[:end - room] = block[first:count]
        self.write_at = end % room
        self.available = min(room, self.available + count)

    def read(self, frames):
        out = np.zeros((frames, CHANNELS), dtype=np.float32)
        count = min(frames, self.available)
        if count <= 0:
            return out
        room = len(self.buf)
        start = (self.write_at - self.available) % room
        end = start + count
        if end <= room:
            out[:count] = self.buf[start:end]
        else:
            first = room - start
            out[:first] = self.buf[start:]
            out[first:count] = self.buf[:end - room]
        self.available -= count
        return out


class MicInput:
    """One microphone. Open or closed, with a gain and an optional monitor.

    The capture rate is the MICROPHONE's, not the speakers'. They are very
    often different - a headset at 44100 next to an interface at 48000 - and
    PortAudio simply refuses to open an input at a rate the device does not
    offer:

        Error opening InputStream: Invalid sample rate [PaErrorCode -9997]

    So the microphone opens at a rate it will accept, and the monitored audio
    is resampled to the output's rate on the way through. When the two match,
    which is the common case, nothing is resampled at all.
    """

    #: Silenced by hand from the source control list, and soloed there.
    #: Neither is saved: both are things you do during a show.
    muted = False
    soloed = False

    def __init__(self, duck_bus=None, samplerate=None, device=None,
                 gain_db=0.0, monitor=False):
        self.duck_bus = duck_bus
        self.device = device
        #: The rate the OUTPUT runs at, which is what monitored audio has to
        #: arrive in. Kept in step with the mixer by whoever owns both.
        self.output_rate = int(samplerate or C.DEFAULT_SAMPLERATE)
        #: The rate the microphone is actually open at. Set by start().
        self.samplerate = self.output_rate
        self.gain_db = float(gain_db)
        #: Which part of a stereo input carries the voice.
        #:
        #: The microphone used to be opened with channels=1, which takes the
        #: FIRST channel and nothing else. That is right for a headset and
        #: wrong for the way a lot of broadcasters actually work: a hardware
        #: mixer's output arrives as a stereo pair on a line input, and if
        #: the voice is on the right, or the left is a different source
        #: entirely, one channel is all you get and it is the wrong one.
        #:
        #: JamminJerry, on Mastodon, 4 September 2026, with four sound cards
        #: into a mixer: "I can't get my microphone from my mixer on the air
        #: though."
        self.channel = "mix"
        self.monitor = bool(monitor)
        self.stream = None
        self.last_error = None
        #: The device that was asked for, when a different way of reaching the
        #: same microphone is what actually opened. None when it opened as
        #: asked. Said out loud, because a microphone that opened by another
        #: route is still worth knowing about.
        self.fell_back_from = None
        #: Counted by the capture callback since the last open, so the app can
        #: tell "nothing arrived" from "silence arrived" from "a voice
        #: arrived". A real microphone is never digitally silent.
        self.blocks_seen = 0
        self.signal_seen = False
        #: Goes up by one every time the microphone opens, so a check
        #: scheduled for one opening can tell it is not looking at a later one.
        self.openings = 0
        #: How many channels the device was actually opened with.
        self.channels_open = 1
        #: Peak of the most recent block, 0 to 1, for a level readout. This
        #: one is BEFORE the processing, because it is what a gain control
        #: needs to be set against.
        self.peak = 0.0
        #: And after it, which is what actually leaves the building.
        self.processed_peak = 0.0
        self.overruns = 0

        #: Gate, equaliser, compressor and limiter. None means the voice
        #: goes out exactly as it arrives, which is what happens when the
        #: processing library is not installed.
        self.chain = None

        #: On air. Separate from monitoring on purpose: a presenter working
        #: on speakers hears nothing back and is still being broadcast, and a
        #: presenter checking their headphones is not necessarily live.
        self.on_air = False

        self._lock = threading.Lock()
        #: What the speakers drain, and what the stream drains. Two readers
        #: cannot share one ring, because each takes what it reads away.
        self._monitor = _Ring()
        self._air = _Ring()
        #: Set when the microphone's rate differs from the output's. Stateful,
        #: because resampling each block independently would click at every
        #: block boundary.
        self._resampler = None

    # ------------------------------------------------------------- state ---
    @property
    def is_open(self):
        return self.stream is not None

    @property
    def gain(self):
        return db_to_gain(self.gain_db)

    @property
    def gain_reduction_db(self):
        """How hard the compressor is working, or zero if there is none."""
        chain = self.chain
        return chain.gain_reduction_db if chain is not None else 0.0

    def describe(self):
        return describe_input(self.device)

    @property
    def resampling(self):
        """Is the microphone running at a different rate from the output."""
        return self.samplerate != self.output_rate

    def set_output_rate(self, rate):
        """The output moved to a device with another rate. Follow it.

        Called when the soundboard's output changes. A microphone left at the
        old rate would monitor sharp or flat by however far the two differ.
        """
        rate = int(rate or C.DEFAULT_SAMPLERATE)
        if rate == self.output_rate:
            return False
        self.output_rate = rate
        if self.is_open:
            self.start()          # reopens, and rebuilds the resampler
        else:
            self._reset_ring()
        return True

    # ------------------------------------------------------------ opening --
    def candidate_rates(self):
        """Rates to try, best first.

        The output's rate first, because matching it means no resampling at
        all. Then what the microphone itself says it wants, then the two rates
        every device on earth supports. Duplicates removed, order kept.
        """
        wanted = [self.output_rate, input_rate(self.device), 48000, 44100]
        seen = []
        for rate in wanted:
            rate = int(rate or 0)
            if rate > 0 and rate not in seen:
                seen.append(rate)
        return seen

    def _channel_counts(self):
        """How many channels to ask the device for, best first."""
        try:
            info = sd.query_devices(self.device)
            most = int(info.get("max_input_channels", 1))
        except Exception:
            most = 2
        return [2, 1] if most >= 2 else [1]

    def _try_open(self, channels, rate, failures):
        """One attempt at one shape. True if the microphone is now running."""
        stream = None
        before = (self.samplerate, self.channels_open)
        try:
            stream = sd.InputStream(
                device=self.device,
                samplerate=rate,
                channels=channels,
                dtype="float32",
                blocksize=C.BLOCKSIZE,
                latency="low",
                callback=self._callback,
            )
            # The rate and the resampler are settled BEFORE the stream starts,
            # so its first callback already resamples from the right rate.
            # And all of it is inside the guard, which matters: this used to
            # run after it, so anything it raised left a RUNNING stream behind
            # with the state half set, escaped the key handler, and every
            # later Ctrl+M raised again on its way through: a key that did
            # nothing, on or off, with nothing said anywhere.
            self.samplerate = rate
            self.channels_open = channels
            self._reset_ring()
            # Counted from here, before the callback can run, so the first
            # blocks of this opening are never credited to the last one.
            self.blocks_seen = 0
            self.signal_seen = False
            stream.start()
            self.stream = stream
            self._publish(True)
        except Exception as exc:  # no microphone, in use, rate or shape refused
            failures.append("%d Hz, %d channel: %s" % (rate, channels, exc))
            if stream is not None:
                try:
                    stream.abort()
                    stream.close()
                except Exception:
                    pass
            self.stream = None
            self.samplerate, self.channels_open = before
            return False
        self.last_error = None
        self.openings += 1
        return True

    def _open_any_shape(self, failures):
        """Every channel count and rate, on whatever self.device is."""
        # Two channels where the device has them, so a mixer feeding a stereo
        # pair can have either side or both, and one where it does not. Two is
        # tried first and one is the fallback, because a working microphone on
        # the wrong channel beats no microphone at all.
        for wanted in self._channel_counts():
            for rate in self.candidate_rates():
                if self._try_open(wanted, rate, failures):
                    return True
        return False

    def start(self, device=None, other_routes=True):
        """Open the microphone. Returns True if it is actually running.

        Nothing opens a microphone on its own: this is only ever called
        because somebody pressed the key. An app that quietly turned a
        microphone on at startup would be a different kind of program.

        If the device will not open at all, the SAME microphone is tried
        through the other ways Windows offers it (see `alternatives`) before
        this gives up, and `fell_back_from` says so. It is never a different
        microphone: somebody who chose the one on their desk does not want
        the one in their laptop lid switched on behind their back.
        """
        if device is not None:
            self.device = device
        self.stop()
        self.fell_back_from = None

        failures = []
        if self._open_any_shape(failures):
            return True

        asked = self.device
        if other_routes:
            # The system default IS a device, MME's default input, and it has
            # just been tried under its own index as well as under None.
            tried = {asked, _default_input_index() if asked is None else asked}
            for index in alternatives(asked):
                if index in tried:
                    continue
                tried.add(index)
                self.device = index
                if self._open_any_shape(failures):
                    self.fell_back_from = (SYSTEM_DEFAULT if asked is None
                                           else asked)
                    return True
            self.device = asked

        self.stream = None
        # Every rate, not just the last one. "Invalid sample rate" on its own
        # does not say which rates were tried, which is the only useful part.
        self.last_error = "; ".join(failures) or "no microphone available"
        self._publish(False)
        return False

    @property
    def opened_via(self):
        """Which of Windows' ways in the open microphone is using."""
        return host_api_of(self.device) if self.is_open else ""

    def stop(self):
        """Close the microphone and put the music back up."""
        was_open = self.stream is not None
        if self.stream is not None:
            try:
                self.stream.stop()
                self.stream.close()
            except Exception:
                pass
            self.stream = None
        self.peak = 0.0
        self._publish(False)
        try:
            self._reset_ring()
        except Exception:
            # Closing has to work whatever state the last opening left behind,
            # or the key that turns the microphone off stops working too.
            self._resampler = None
        return was_open

    def toggle(self, device=None):
        """Returns True if the microphone is open afterwards."""
        if self.is_open:
            self.stop()
            return False
        return self.start(device=device)

    def close(self):
        self.stop()
        if self.duck_bus is not None:
            self.duck_bus.forget(DUCK_KEY)

    def _publish(self, live):
        """Tell every output whether the microphone is open.

        This is the whole ducking story. Open means the music gets out of the
        way; closed means it comes back. No level detection, no gate, nothing
        that can clip the first word of a sentence.
        """
        if self.duck_bus is not None:
            self.duck_bus.publish(DUCK_KEY, bool(live))

    # ------------------------------------------------------------ capture --
    def _reset_ring(self):
        with self._lock:
            self._monitor.clear()
            self._air.clear()
        # The resampler is NOT conditional on there being a voice chain. It
        # ended up nested inside that check when the processing went in, so a
        # copy without pedalboard had no resampler at all and the microphone
        # went into the rings at its own rate while being drained at the
        # output's: monitoring and broadcasting sharp or flat by however far
        # the two differ.
        with self._lock:
            if self.samplerate != self.output_rate:
                self._resampler = soxr.ResampleStream(
                    self.samplerate, self.output_rate, CHANNELS,
                    dtype="float32")
            else:
                self._resampler = None
        chain = self.chain
        if chain is not None:
            # Envelopes and filters remember the last thing they heard, and
            # the last thing they heard was a different microphone.
            chain.reset()

    def _callback(self, indata, frames, time_info, status):
        if status:
            self.overruns += 1
        block = np.asarray(indata, dtype=np.float32)
        if block.ndim == 2:
            if block.shape[1] >= 2:
                # Which half of a stereo input the voice is actually on.
                # "mix" averages rather than sums, so choosing it never makes
                # a centred voice 6 dB louder than choosing a side.
                if self.channel == "left":
                    block = block[:, 0]
                elif self.channel == "right":
                    block = block[:, 1]
                else:
                    block = block[:, :2].mean(axis=1)
            else:
                block = block[:, 0]
        block = block * self.gain
        peak = float(np.abs(block).max()) if frames else 0.0
        self.peak = peak
        self.blocks_seen += 1
        if peak > 0.0:
            self.signal_seen = True
        if not self.monitor and not self.on_air:
            return
        # One channel up the middle of both. Written into the rings under the
        # lock; each reader drains its own from its own callback.
        stereo = np.repeat(block[:, None], CHANNELS, axis=1)
        # Resampled OUTSIDE the lock. soxr allocates, and the output callback
        # takes this same lock to read the monitor, so holding it across the
        # resample couples two real time threads: a hitch on the microphone
        # thread became a hitch in the show. The resampler is only ever
        # touched by this callback and by _reset_ring, which stops the stream
        # first, so it needs no lock of its own.
        resampler = self._resampler
        if resampler is not None:
            # The microphone and the speakers are on different clocks and
            # different rates. Resampled once here, so both readers only ever
            # deal in the output's rate and can add it straight in.
            try:
                stereo = resampler.resample_chunk(stereo)
            except Exception:
                return
            if not len(stereo):
                return

        # Processed OUTSIDE the lock. It is only a tenth of a millisecond, but
        # the output callback takes this same lock to read the monitor, and
        # there is no reason to make it wait behind a compressor.
        chain = self.chain
        if chain is not None:
            stereo = chain.process(stereo)
        self.processed_peak = (float(np.abs(stereo).max())
                               if len(stereo) else 0.0)

        with self._lock:
            if self.monitor:
                self._monitor.write(stereo)
            if self.on_air:
                self._air.write(stereo)

    def read(self, frames):
        """Drain up to ``frames`` of monitored audio. Never blocks.

        Returns a (frames, CHANNELS) block, zero-padded when the microphone has
        not produced enough yet. Two streams have two clocks and they drift; a
        monitor running dry has to be silence for a moment, never a stall in
        the output callback that would take the music with it.
        """
        if not self.monitor or not self.is_open:
            return np.zeros((frames, CHANNELS), dtype=np.float32)
        with self._lock:
            return self._monitor.read(frames)

    def read_air(self, frames):
        """The same, for the stream. Its own tap, drained independently.

        Monitoring and broadcasting are different questions and each reader
        takes what it reads away, so the answer to one cannot come out of the
        other's ring.
        """
        if not self.on_air or not self.is_open:
            return np.zeros((frames, CHANNELS), dtype=np.float32)
        with self._lock:
            return self._air.read(frames)
