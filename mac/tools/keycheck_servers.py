"""RTMP servers that misbehave on purpose, for mac/tools/check_keycheck.py.

`tools/mock_rtmp.py` is the Windows project's server and it only ever says
yes. It may be imported by Mac tooling and never edited, so every server that
says no, hangs up, chatters or lies lives here instead, in a Mac-owned file.

Each one accepts connections on 127.0.0.1, on a port of its own, on a thread
of its own (the client is another PROCESS, the Swift probe, so the GIL is not
the problem it is for mock_rtmp), and keeps a record of what it was sent:

    connections        how many times anybody connected
    commands           every AMF0 command name, in order
    types              every message type id, in order
    tags               audio, video and data messages (8, 9, 18)
    after_publish      raw BYTES received after the publish command ended
    publish_chunk      the chunk stream the publish came on
    publish_stream     the message stream id it came on

Modes:

    accept             answers everything; publish gets NetStream.Publish.Start.
                       createStream hands out stream id 7, and releaseStream and
                       FCPublish are answered with a _result of their own, so a
                       client that takes the first _result in sight as the
                       createStream answer publishes on the wrong stream.
    refuse             publish gets onStatus at level error, BadName, with the
                       description "Publish Rejected: Invalid URL", which is
                       Facebook's own answer to a wrong key.
    hangup_publish     closes the socket the moment publish arrives, which is
                       YouTube's answer to a wrong key.
    hangup_handshake   closes the socket after C0 and C1.
    chatter            completes the handshake, never answers a command, and
                       sends a ping request every fifty milliseconds for ever.
    huge               answers the handshake, then after connect declares a
                       16 MB command message and starts sending it.
    icecast401         an HTTP source server that refuses the password.

Nothing here touches the internet.
"""
import socket
import struct
import threading
import time

HANDSHAKE_SIZE = 1536
COMMAND = 20


def amf_string(value):
    raw = value.encode("utf-8")
    return b"\x02" + struct.pack(">H", len(raw)) + raw


def amf_number(value):
    return b"\x00" + struct.pack(">d", float(value))


def amf_null():
    return b"\x05"


def amf_object(pairs):
    out = b"\x03"
    for name, value in pairs:
        raw = name.encode("utf-8")
        out += struct.pack(">H", len(raw)) + raw
        out += amf_number(value) if isinstance(value, (int, float)) else amf_string(value)
    return out + b"\x00\x00\x09"


def amf_decode(data, at=0):
    """Just enough AMF0 to read a command name and its transaction."""
    marker = data[at]
    at += 1
    if marker == 0x00:
        return struct.unpack_from(">d", data, at)[0], at + 8
    if marker == 0x02:
        length = struct.unpack_from(">H", data, at)[0]
        at += 2
        return data[at:at + length].decode("utf-8", "replace"), at + length
    raise ValueError("marker %d" % marker)


def message(type_id, payload, chunk_stream=3, stream_id=0, timestamp=0):
    """One message, chunked at 128, the size every client assumes at first."""
    head = (bytes([chunk_stream]) + struct.pack(">I", timestamp)[1:]
            + struct.pack(">I", len(payload))[1:] + bytes([type_id])
            + struct.pack("<I", stream_id))
    out = head + payload[:128]
    at = 128
    while at < len(payload):
        out += bytes([0xC0 | chunk_stream]) + payload[at:at + 128]
        at += 128
    return out


class Closed(Exception):
    pass


class _Peer:
    """One client connection: handshake and chunk reading."""

    def __init__(self, sock, record):
        self.sock = sock
        self.record = record
        self.buf = b""
        self.in_chunk = 128
        self.last = {}
        self.partial = {}
        self.counting = False

    def recv(self, n):
        while len(self.buf) < n:
            try:
                block = self.sock.recv(65536)
            except OSError:
                raise Closed()
            if not block:
                raise Closed()
            if self.counting:
                self.record["after_publish"] += len(block)
            self.buf += block
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def send(self, data):
        self.sock.sendall(data)

    def handshake(self):
        self.recv(1 + HANDSHAKE_SIZE)
        s1 = struct.pack(">II", int(time.time()), 0) + bytes(HANDSHAKE_SIZE - 8)
        self.send(b"\x03" + s1 + s1)
        self.recv(HANDSHAKE_SIZE)

    def read_message(self):
        """(type, chunk stream, stream id, payload) of the next whole message."""
        while True:
            first = self.recv(1)[0]
            fmt, csid = first >> 6, first & 0x3F
            if csid == 0:
                csid = 64 + self.recv(1)[0]
            elif csid == 1:
                low, high = self.recv(2)
                csid = 64 + low + (high << 8)
            last = self.last.get(csid, {"length": 0, "type": 0, "stream": 0, "ext": False})
            if fmt == 0:
                raw = self.recv(11)
                ts = int.from_bytes(raw[0:3], "big")
                length = int.from_bytes(raw[3:6], "big")
                type_id = raw[6]
                stream = struct.unpack("<I", raw[7:11])[0]
            elif fmt == 1:
                raw = self.recv(7)
                ts = int.from_bytes(raw[0:3], "big")
                length = int.from_bytes(raw[3:6], "big")
                type_id = raw[6]
                stream = last["stream"]
            elif fmt == 2:
                ts = int.from_bytes(self.recv(3), "big")
                length, type_id, stream = last["length"], last["type"], last["stream"]
            else:
                ts = 0
                length, type_id, stream = last["length"], last["type"], last["stream"]
            ext = last["ext"] if fmt == 3 else ts == 0xFFFFFF
            if ext:
                self.recv(4)
            self.last[csid] = {"length": length, "type": type_id, "stream": stream, "ext": ext}
            held = self.partial.get(csid, b"")
            want = min(self.in_chunk, length - len(held))
            held += self.recv(want) if want > 0 else b""
            if len(held) < length:
                self.partial[csid] = held
                continue
            self.partial.pop(csid, None)
            if type_id == 1 and len(held) >= 4:
                self.in_chunk = struct.unpack(">I", held[:4])[0] & 0x7FFFFFFF
            self.record["types"].append(type_id)
            if type_id in (8, 9, 18):
                self.record["tags"] += 1
            return type_id, csid, stream, held


class Server:
    """One misbehaving RTMP (or Icecast) server on a thread."""

    def __init__(self, mode):
        self.mode = mode
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(8)
        self.port = self.sock.getsockname()[1]
        self.stop_flag = threading.Event()
        self.lock = threading.Lock()
        self.record = {"connections": 0, "commands": [], "types": [], "tags": 0,
                       "after_publish": 0, "publish_chunk": None,
                       "publish_stream": None, "pings": 0, "huge_sent": 0,
                       "errors": []}
        self.thread = threading.Thread(target=self._accept, daemon=True)

    @property
    def url(self):
        return "rtmp://127.0.0.1:%d/live" % self.port

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_exc):
        self.stop_flag.set()
        try:
            self.sock.close()
        except OSError:
            pass
        return False

    def settle(self, seconds=1.0):
        """Give the last connection time to finish being recorded."""
        time.sleep(seconds)

    def _accept(self):
        self.sock.settimeout(0.2)
        while not self.stop_flag.is_set():
            try:
                conn, _ = self.sock.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with self.lock:
                self.record["connections"] += 1
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()

    def _serve(self, conn):
        conn.settimeout(30)
        try:
            if self.mode == "icecast401":
                self._icecast(conn)
            else:
                self._rtmp(conn)
        except Closed:
            pass
        except OSError:
            pass
        except Exception as exc:                  # a fault in the server itself
            self.record["errors"].append("%s: %s" % (type(exc).__name__, exc))
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def _icecast(self, conn):
        data = b""
        while b"\r\n\r\n" not in data:
            block = conn.recv(4096)
            if not block:
                return
            data += block
        self.record["commands"].append(data.split(b" ", 1)[0].decode("ascii", "replace"))
        conn.sendall(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n")

    def _rtmp(self, conn):
        peer = _Peer(conn, self.record)
        if self.mode == "hangup_handshake":
            peer.recv(1 + HANDSHAKE_SIZE)
            return
        peer.handshake()
        if self.mode == "chatter":
            self._chatter(peer)
            return
        while True:
            type_id, csid, stream, payload = peer.read_message()
            if type_id != COMMAND:
                continue
            try:
                name, at = amf_decode(payload)
                txn, _ = amf_decode(payload, at)
            except Exception:
                continue
            self.record["commands"].append(name)
            if name == "connect":
                if self.mode == "huge":
                    self._huge(peer)
                    return
                peer.send(message(5, struct.pack(">I", 2500000), 2))
                peer.send(message(COMMAND, amf_string("_result") + amf_number(txn)
                                  + amf_object([("fmsVer", "FMS/3,5,7,7009"),
                                                ("capabilities", 31)])
                                  + amf_object([("level", "status"),
                                                ("code", "NetConnection.Connect.Success"),
                                                ("description", "Connection succeeded.")])))
            elif name in ("releaseStream", "FCPublish"):
                peer.send(message(COMMAND, amf_string("_result") + amf_number(txn)
                                  + amf_null() + amf_null()))
            elif name == "createStream":
                peer.send(message(COMMAND, amf_string("_result") + amf_number(txn)
                                  + amf_null() + amf_number(7)))
            elif name == "publish":
                self.record["publish_chunk"] = csid
                self.record["publish_stream"] = stream
                if self.mode == "hangup_publish":
                    return
                if self.mode == "refuse":
                    info = [("level", "error"), ("code", "NetStream.Publish.BadName"),
                            ("description", "Publish Rejected: Invalid URL")]
                else:
                    info = [("level", "status"), ("code", "NetStream.Publish.Start"),
                            ("description", "Start publishing")]
                peer.send(message(COMMAND, amf_string("onStatus") + amf_number(0)
                                  + amf_null() + amf_object(info), 5, stream))
                # Everything from here is counted, byte by byte, until the
                # client hangs up. The whole claim is that this stays nought.
                peer.counting = True
                # Whatever came in the same read as the publish, after it.
                self.record["after_publish"] += len(peer.buf)

    def _chatter(self, peer):
        """A ping every fifty milliseconds, and never an answer."""
        peer.sock.setblocking(False)
        while not self.stop_flag.is_set():
            ping = struct.pack(">HI", 6, int(time.time() * 1000) & 0xFFFFFFFF)
            try:
                peer.sock.sendall(message(4, ping, 2))
                self.record["pings"] += 1
            except BlockingIOError:
                pass
            except OSError:
                return
            try:
                while True:
                    block = peer.sock.recv(65536)
                    if not block:
                        return
            except BlockingIOError:
                pass
            except OSError:
                return
            time.sleep(0.05)

    def _huge(self, peer):
        """Declare sixteen megabytes, then try to send them."""
        head = (bytes([3]) + b"\x00\x00\x00" + b"\xff\xff\xff" + bytes([COMMAND])
                + struct.pack("<I", 0))
        peer.send(head)
        block = b"A" * 128 + bytes([0xC3])
        peer.sock.settimeout(3)
        sent = 0
        try:
            while sent < 0xFFFFFF and not self.stop_flag.is_set():
                peer.sock.sendall(block)
                sent += len(block)
        except OSError:
            pass
        self.record["huge_sent"] = sent
