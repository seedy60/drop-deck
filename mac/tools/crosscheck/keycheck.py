# Check my stream key, the Windows side. The repository root is on the path,
# put there by cross_check.py.
#
# `rtmpcheck` is imported whole. The verdicts and the ask first question live
# in methods of the wx settings dialog, which cannot be built without wx, so
# those two methods are lifted out of dropdeck/dialogs.py by their syntax tree
# and run on their own, against the real constants, rtmpcheck and secrets.
# The dialog's fixed sentences are read out of the same tree, which joins
# Python's adjacent string literals exactly as the interpreter does.
import ast
import os

from dropdeck import constants as C
from dropdeck import rtmpcheck, secrets, streamout

SOURCE = os.path.join(os.path.dirname(os.path.abspath(rtmpcheck.__file__)), "dialogs.py")
with open(SOURCE, encoding="utf-8") as handle:
    tree = ast.parse(handle.read())


def lifted(name, extra):
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == name:
            module = ast.Module(body=[node], type_ignores=[])
            space = {"C": C, "rtmpcheck": rtmpcheck, "secrets": secrets}
            space.update(extra)
            exec(compile(module, SOURCE, "exec"), space)
            return space[name]
    raise SystemExit("%s is not in dialogs.py any more" % name)


asked = []


class FakeWx:
    YES_NO = ICON_QUESTION = 0
    YES = 1

    @staticmethod
    def MessageBox(question, title, *_rest):
        asked.append((question, title))
        return 1


verdict = lifted("_key_verdict", {})
agree = lifted("_agree_to_check", {"wx": FakeWx})


def flat(text):
    return text.replace("\n", "\\n")


out = []
for url in ("rtmps://a.rtmps.youtube.com/live2",
            "rtmps://live-api-s.facebook.com:443/rtmp",
            "rtmp://live.restream.io/live", "rtmp://live.restream.io/live/",
            "RTMP://Example.COM/App", "rtmp://example.com",
            "rtmp://example.com:1936/a/b", "  rtmp://padded.example/live  ",
            "https://example.com/live", "not a url", "", "C:/Users/Public",
            "rtmp:///nohost", "udp://239.0.0.1:1234"):
    parts = rtmpcheck.split_url(url)
    out.append("split|%s|%s" % (url, "None" if parts is None else "|".join(map(str, parts))))

for text in ("", "   ", "Start publishing", "  Publish \n Rejected:\tInvalid  URL ",
             "x" * 199, "x" * 200, "x" * 201, "word " * 100):
    out.append("said|%d|%s" % (len(text), rtmpcheck._said({"description": text})))
out.append("said|none|%s" % rtmpcheck._said({}))

for stage in ("handshake", "connect", "createStream", "publish"):
    out.append("gaveup|%s|%s" % (stage, rtmpcheck._gave_up(stage, "x").outcome))

outcomes = (rtmpcheck.ACCEPTED, rtmpcheck.REFUSED, rtmpcheck.NO_SERVER,
            rtmpcheck.NO_ROUTE, rtmpcheck.NO_TLS, rtmpcheck.NO_ANSWER,
            rtmpcheck.BAD_ADDRESS, rtmpcheck.NO_KEY)
for platform in ("youtube", "facebook", "restream", "rtmp"):
    label = streamout.server_label(platform)
    out.append("label|%s|%s" % (platform, label))
    known = C.RTMP_GOES_LIVE_AT_ONCE.get(platform)
    out.append("asks|%s|%s" % (platform, known is not False))
    del asked[:]
    agree(None, platform, label)
    out.append("question|%s|%s" % (platform, flat(asked[0][0]) if asked else "None"))
    if asked:
        out.append("question-title|%s|%s" % (platform, asked[0][1]))
    for outcome in outcomes:
        for said in ("", "Publish Rejected: Invalid URL"):
            text = verdict(None, rtmpcheck.Result(outcome, said), platform, label,
                           "a.rtmps.youtube.com", "abcd-efgh-1234")
            out.append("verdict|%s|%s|%s|%s" % (platform, outcome, said, text))

# The dialog's fixed sentences, found by how they begin.
constants = [node.value for node in ast.walk(tree)
             if isinstance(node, ast.Constant) and isinstance(node.value, str)]
for name, start in (("stillChecking", "Still checking your stream key"),
                    ("declined", "Nothing was checked and nothing was sent"),
                    ("buttonHelp", "Asks the platform whether your stream key"),
                    ("nothingTriedYet", "Nothing tried yet. Check my stream key"),
                    ("checkingWith", "Checking your stream key with ")):
    found = [text for text in constants if text.startswith(start)]
    text = found[0] if found else "MISSING"
    if name == "checkingWith":
        text = text % streamout.server_label("youtube")
    out.append("fixed|%s|%s" % (name, text))
print("\n".join(out))
