"""Track titles reaching a station, proved offline.

Until 3.8.4 no title ever left the Mac once it was live: `Streamer.nowPlaying`
had no caller. This runs the BUILT app's `--check-titles` against
`tools/mock_icecast.py`, the Windows project's own stand in for Icecast,
imported and never edited, and reads back every metadata request it received.

    python3 mac/tools/check_titles.py

What it proves:

  * the title held before going live is sent the moment the station takes the
    connection, and each later one as it changes;
  * "Title by Artist" is Windows' own wording, taken from
    `dropdeck.playlist.Track.display_name` when this interpreter can import
    it, and "Artist - Title" is the other order;
  * the request is Icecast's: /admin/metadata, the mount, mode updinfo, the
    song, charset UTF-8, and the source's password;
  * a title with an ampersand, an equals sign, a plus and accented letters
    arrives exactly as written;
  * with Send what is playing off, nothing is sent at all.

Nothing here touches the internet.
"""
import os
import subprocess
import sys
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, ROOT)

from mock_icecast import MockServer  # noqa: E402

APP = os.path.expanduser(
    "~/Library/Application Support/TG Studios Build/drop-deck-mac/"
    "TG Drop Deck.app/Contents/MacOS/TGDropDeck")


def windows_wording(title, artist):
    """What Windows calls a track, from its own code when that can be read."""
    try:
        from dropdeck.playlist import Track
    except Exception:
        return "%s by %s" % (title, artist), "literal, dropdeck needs numpy"
    track = Track("/nowhere/x.mp3")
    track.title = title
    track.artist = artist
    return track.display_name, "dropdeck.playlist.Track.display_name"


def main():
    if not os.path.exists(APP):
        print("FAIL  no built app at %s. Build it first." % APP)
        return 1
    dance, source = windows_wording("The Dance", "Garth Brooks")
    awkward, _ = windows_wording("Tom & Jerry's Song = 100% + more",
                                 "Ünïcödé Band")
    wanted = [dance, "Garth Brooks - The Dance", awkward, "station ident"]

    failures = 0

    def check(name, ok, detail=""):
        nonlocal failures
        print("  %s  %s%s" % ("ok  " if ok else "FAIL", name,
                              ("  " + detail) if detail else ""))
        if not ok:
            failures += 1

    with MockServer(password="hackme") as server:
        run = subprocess.run([APP, "--check-titles", "127.0.0.1", str(server.port),
                              "/live", "source", "hackme"],
                             capture_output=True, text=True, timeout=60)
        print(run.stdout.rstrip())
        check("the app ran its titles to the end", run.returncode == 0,
              run.stderr.strip()[-300:])
        seen = list(server.metadata)

    songs = []
    for path in seen:
        parsed = urllib.parse.urlparse(path)
        query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
        songs.append(query.get("song", [""])[0])
        check("it went to /admin/metadata", parsed.path == "/admin/metadata", path)
        check("for the mount it streams to", query.get("mount") == ["/live"])
        check("as an update", query.get("mode") == ["updinfo"])
        check("saying the text is UTF-8", query.get("charset") == ["UTF-8"])

    print("  Windows' wording taken from: %s" % source)
    check("exactly these titles, in this order, and nothing else",
          songs == wanted, "got %r" % songs)
    check("Title by Artist is Windows' own wording", songs[:1] == [dance],
          "%r" % songs[:1])
    check("with Send what is playing off, nothing was sent for that track",
          len(songs) == 4)
    print("")
    print("All title checks passed." if not failures
          else "%d title checks failed." % failures)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
