"""Check my stream key, and the streamers' truth, proved offline.

The Mac port of Windows 3.8.4's key check (`mac/Sources/StreamKeyCheck.swift`)
is safe for one reason only: after the publish command it sends NOTHING. Not
metadata, not a codec header, not a byte of sound or picture, not even
FCUnpublish or deleteStream. This runs the real Swift, built out of the app's
own sources the way `check_rtmp.py` builds its publisher, against servers on
this machine, and counts what arrives.

    python3 mac/tools/check_keycheck.py

What it proves:

  * against `tools/mock_rtmp.py`, the Windows project's own server, imported
    and never edited: ACCEPTED, the five commands and nothing else, zero audio,
    video and data messages;
  * against a Mac-owned server that counts raw BYTES: nought bytes after the
    publish command, the publish on chunk stream 4, on the stream id the
    server handed out (7, not the 1 everybody assumes);
  * refused with the platform's own words quoted; a hang up after publish is
    a refusal; a hang up during the handshake is NOT a refusal; a server
    pinging every fifty milliseconds cannot hold the check past its timeout;
    a server declaring a 16 MB message is refused without the memory;
  * an address that does not resolve and a port nothing listens on are
    reported as what they are;
  * the video streamer stops, once, on a refusal and on a hang up after
    publish, instead of retrying all night; it stops with Windows' sentence
    when no sound ever reaches it; and the radio streamer stops, once, on a
    refused password.

Nothing here touches the internet. `nothing.invalid.example` is a reserved
name that no resolver will ever answer for.
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, HERE)

TARGET = "arm64-apple-macos14.0"
FRAMEWORKS = ["AppKit", "AVFoundation", "AudioToolbox", "CoreAudio", "Accelerate",
              "UniformTypeIdentifiers", "Network", "Carbon", "Security", "CoreText",
              "CoreGraphics", "CoreMedia", "CoreVideo", "CoreImage", "VideoToolbox",
              "ScreenCaptureKit", "Vision", "ImageIO"]


def build(work):
    """The app's own sources, plus the probe, as one binary."""
    running = subprocess.run(["pgrep", "-fl", "swiftc"], capture_output=True, text=True)
    if running.stdout.strip():
        raise SystemExit("Another swiftc is running, and one Mac build at a time is "
                         "the rule. Try again when it has finished:\n" + running.stdout)
    sources = [os.path.join(ROOT, "mac", "Sources", name)
               for name in sorted(os.listdir(os.path.join(ROOT, "mac", "Sources")))
               if name.endswith(".swift") and name != "main.swift"]
    main = os.path.join(work, "main.swift")
    shutil.copy(os.path.join(HERE, "keycheck_probe.swift"), main)

    vendor = os.path.join(ROOT, "mac", "vendor")
    dylib = os.path.join(work, "libmp3lame.dylib")
    shutil.copy(os.path.join(vendor, "libmp3lame.dylib"), dylib)
    subprocess.run(["codesign", "--force", "--sign", "-", dylib],
                   capture_output=True, text=True)

    binary = os.path.join(work, "keycheck_probe")
    flags = ["swiftc", "-Onone", "-target", TARGET,
             "-import-objc-header", os.path.join(ROOT, "mac", "Sources", "LAMEBridge.h"),
             "-I", os.path.join(vendor, "include"), "-L", vendor, "-lmp3lame",
             "-Xlinker", "-rpath", "-Xlinker", work, "-o", binary]
    for framework in FRAMEWORKS:
        flags += ["-framework", framework]
    made = subprocess.run(flags + sources + [main], capture_output=True, text=True)
    if made.returncode:
        raise SystemExit("the probe did not compile:\n" + made.stderr[-4000:])
    return binary


def run(binary, *args, timeout=60):
    started = time.monotonic()
    out = subprocess.run([binary] + [str(a) for a in args], capture_output=True,
                         text=True, timeout=timeout, cwd=ROOT)
    took = time.monotonic() - started
    for line in out.stdout.splitlines():
        if line.startswith("RESULT "):
            result = json.loads(line[len("RESULT "):])
            result["_wall"] = took
            return result
    raise SystemExit("the probe said nothing useful:\n%s\n%s"
                     % (out.stdout[-2000:], out.stderr[-2000:]))


def free_port():
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    return port


def main():
    import mock_rtmp                      # the Windows server, read only
    from keycheck_servers import Server   # the Mac's own, that say no

    problems = []

    def check(name, condition, detail=""):
        print("  %s  %s%s" % ("ok  " if condition else "FAIL", name,
                              "" if detail == "" else "  " + str(detail)))
        if not condition:
            problems.append(name)

    def nothing_after_publish(result):
        sent = result.get("sent", [])
        return bool(sent) and sent[-1] == "publish" and result.get("tags_sent") == 0

    with tempfile.TemporaryDirectory() as work:
        print("Building the probe out of the app's own sources...")
        binary = build(work)

        print("")
        print("Against tools/mock_rtmp.py, the Windows server")
        with mock_rtmp.spawn(seconds=20) as server:
            base = server.url.rsplit("/", 1)[0]
            result = run(binary, "keycheck", base, "test")
            seen = server.finish()
        check("the key is ACCEPTED", result["outcome"] == "accepted", result["outcome"])
        check("the server saw the five commands and nothing else",
              seen.commands == ["connect", "releaseStream", "FCPublish",
                                "createStream", "publish"], seen.commands)
        check("it reached publishing", seen.publishing)
        check("audio 0, video 0, data 0 arrived",
              seen.counts == {"audio": 0, "video": 0, "data": 0}, seen.counts)
        check("the server reported no fault", not seen.error, seen.error)
        check("and this end wrote nothing after publish",
              nothing_after_publish(result), result.get("sent"))
        check("it took under two seconds", result["seconds"] < 2,
              "%.2f s" % result["seconds"])

        print("")
        print("Against a Mac-owned server that counts every byte")
        with Server("accept") as server:
            result = run(binary, "keycheck", server.url, "a-good-key")
            server.settle()
            record = dict(server.record)
        check("ACCEPTED", result["outcome"] == "accepted", result["outcome"])
        check("NOUGHT bytes arrived after the publish command",
              record["after_publish"] == 0, record["after_publish"])
        check("no audio, video or data message at all", record["tags"] == 0, record["types"])
        check("publish came on chunk stream 4", record["publish_chunk"] == 4,
              record["publish_chunk"])
        check("on the stream id the server handed out, not the one everybody assumes",
              record["publish_stream"] == 7, record["publish_stream"])
        check("the last thing this end wrote was publish",
              nothing_after_publish(result), result.get("sent"))

        print("")
        print("A refusal, with the platform's own words")
        with Server("refuse") as server:
            result = run(binary, "keycheck", server.url, "wrong-key-1234")
            server.settle()
            record = dict(server.record)
        check("REFUSED", result["outcome"] == "refused", result["outcome"])
        check("quoting the description", result["said"] == "Publish Rejected: Invalid URL",
              result["said"])
        check("and the sentence says it",
              "It said: Publish Rejected: Invalid URL." in result["verdict"], result["verdict"])
        check("with no status code in it", "NetStream" not in result["verdict"])
        check("nothing arrived after publish", record["after_publish"] == 0,
              record["after_publish"])

        print("")
        print("A hang up after publish, which is YouTube's answer to a wrong key")
        with Server("hangup_publish") as server:
            result = run(binary, "keycheck", server.url, "wrong-key-5678")
            server.settle()
        check("REFUSED, not a network fault", result["outcome"] == "refused",
              "%s at %s" % (result["outcome"], result["stage"]))
        check("with the sentence for a platform that says nothing",
              "closed the connection without saying why" in result["verdict"],
              result["verdict"])
        check("in well under the timeout", result["seconds"] < 2, "%.2f s" % result["seconds"])

        print("")
        print("A hang up during the handshake")
        with Server("hangup_handshake") as server:
            result = run(binary, "keycheck", server.url, "a-key")
        check("NO ANSWER, not a refusal: the key was never asked about",
              result["outcome"] == "no-answer" and result["stage"] == "handshake",
              "%s at %s" % (result["outcome"], result["stage"]))

        print("")
        print("A chatterbox pinging every fifty milliseconds and never answering")
        with Server("chatter") as server:
            result = run(binary, "keycheck", server.url, "a-key")
            pings = server.record["pings"]
        check("the check returns within its timeout plus one second",
              result["seconds"] <= result["timeout"] + 1,
              "%.2f s against %.0f, %d pings" % (result["seconds"], result["timeout"], pings))
        check("and says the server did not answer",
              result["outcome"] == "no-answer" and "did not answer" in result["verdict"],
              result["outcome"])

        print("")
        print("A server declaring a 16 MB message")
        with Server("huge") as server:
            result = run(binary, "keycheck", server.url, "a-key")
            server.settle(0.5)
            pushed = server.record["huge_sent"]
        grew = result["rss_after"] - result["rss_before"]
        check("it is refused, as the network, not as the key",
              result["outcome"] == "no-answer", "%s at %s" % (result["outcome"], result["stage"]))
        check("and quickly", result["seconds"] < 3, "%.2f s" % result["seconds"])
        check("without holding it: the probe grew by under 4 MB",
              grew < 4 * 1024 * 1024,
              "grew %.1f MB, the server got %.1f MB out before it stopped"
              % (grew / 1048576.0, pushed / 1048576.0))

        print("")
        print("Addresses that go nowhere")
        result = run(binary, "keycheck", "rtmp://nothing.invalid.example/live", "a-key")
        check("a name that does not resolve is NO SERVER", result["outcome"] == "no-server",
              result["outcome"])
        port = free_port()
        result = run(binary, "keycheck", "rtmp://127.0.0.1:%d/live" % port, "a-key")
        check("a port nothing listens on is NO ROUTE, at once",
              result["outcome"] == "no-route" and result["seconds"] < 3,
              "%s in %.2f s" % (result["outcome"], result["seconds"]))

        print("")
        print("The video streamer, told no")
        with Server("refuse") as server:
            result = run(binary, "video", server.url, "wrong-key", "rtmp", 8)
            server.settle(0.5)
            connections = server.record["connections"]
        check("a refused key is FAILED, not retried", result["final"] == "failed",
              result["states"])
        check("after exactly one connection", connections == 1 and result["attempts"] == 1,
              "%d connections, %d attempts" % (connections, result["attempts"]))
        check("and it says what the platform said",
              "Publish Rejected: Invalid URL" in result["detail"], result["detail"])
        check("once", sum(1 for s in result["states"] if s.startswith("failed")) == 1,
              result["states"])
        check("and never claimed to be on air",
              not any(s.startswith("live") for s in result["states"]), result["states"])

        with Server("hangup_publish") as server:
            result = run(binary, "video", server.url, "wrong-key", "rtmp", 8)
            server.settle(0.5)
            connections = server.record["connections"]
        check("a hang up in the publish grace is a refusal, FAILED",
              result["final"] == "failed" and connections == 1,
              "%s after %d connections: %s" % (result["final"], connections, result["states"]))
        check("in Windows' words, with the platform's name",
              result["detail"].startswith("Custom RTMP server would not take the stream key"),
              result["detail"])

        print("")
        print("The video streamer with no sound going into it")
        with mock_rtmp.spawn(seconds=30) as server:
            base = server.url.rsplit("/", 1)[0]
            result = run(binary, "video", base, "test", "rtmp", 14, timeout=90)
            seen = server.finish()
        check("it went live, and then stopped rather than sitting on air",
              any(s.startswith("live") for s in result["states"]) and result["final"] == "failed",
              result["states"])
        check("saying no sound ever reached the stream",
              result["detail"].startswith("no sound ever reached the stream, so nothing was broadcast"),
              result["detail"])
        check("no audio frame and no video frame went out",
              seen.counts.get("video") == 0 and seen.counts.get("audio", 0) <= 1,
              "%s (the one audio message is the AAC sequence header sent at connect)"
              % seen.counts)
        check("and it counted nothing as sent", result["media_bytes"] == 0, result["media_bytes"])

        print("")
        print("The radio streamer, told the password is wrong")
        with Server("icecast401") as server:
            result = run(binary, "radio", "127.0.0.1", server.port, 6)
            server.settle(0.5)
            connections = server.record["connections"]
        check("FAILED, and it stays failed", result["final"] == "failed", result["states"])
        check("after exactly one connection", connections == 1 and result["attempts"] == 1,
              "%d connections, %d attempts" % (connections, result["attempts"]))
        check("never overwritten with trying again",
              not any(s.startswith("retrying") for s in result["states"]), result["states"])

        print("")
        print("Refusals Windows retries are retried (audit 1, finding 1)")
        with Server("icecast403") as server:
            result = run(binary, "radio", "127.0.0.1", server.port, 4)
            server.settle(0.5)
            connections = server.record["connections"]
        check("a 403 mount in use is tried again, not FAILED",
              not any(s.startswith("failed") for s in result["states"])
              and any(s.startswith("retrying") for s in result["states"]), result["states"])
        check("on another connection", connections >= 2 and result["attempts"] >= 2,
              "%d connections, %d attempts" % (connections, result["attempts"]))

        with Server("error_connect") as server:
            result = run(binary, "video", server.url, "a-key", "rtmp", 4)
            server.settle(0.5)
            connections = server.record["connections"]
        check("a plain _error that says nothing of the key is tried again, not FAILED",
              not any(s.startswith("failed") for s in result["states"])
              and any(s.startswith("retrying") for s in result["states"]), result["states"])
        check("on another connection", connections >= 2 and result["attempts"] >= 2,
              "%d connections, %d attempts" % (connections, result["attempts"]))

    print("")
    if problems:
        print("%d check%s failed." % (len(problems), "" if len(problems) == 1 else "s"))
        return 1
    print("Everything checked out.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
