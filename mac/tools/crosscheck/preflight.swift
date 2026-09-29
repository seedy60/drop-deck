import Foundation

func py(_ b: Bool) -> String { b ? "True" : "False" }
var out: [String] = []

// ---------------------------------------------------------------- labels ---
for key in ["icecast", "shoutcast", "youtube", "facebook", "restream", "rtmp",
            "nonsense", ""] {
    out.append("label|\(key)|\(StreamServers.serverLabel(key))")
    out.append("isrtmp|\(key)|\(py(StreamServers.isRTMP(key)))")
}
for url in ["rtmps://a.rtmps.youtube.com/live2/abcd-key",
            "rtmp://live.restream.io/live", "http://radio.example.com:8000",
            "not a url", "", "rtmps://live-api-s.facebook.com:443/rtmp/FB-1-key",
            "live.example.com/app/KEY"] {
    out.append("host|\(url)|\(StreamServers.hostLabel(url))")
}

// -------------------------------------------------------- bitrate advice ---
for server in ["facebook", "youtube", "restream", "rtmp"] {
    for size in [(1920, 1080, 60), (1920, 1080, 30), (1280, 720, 60),
                 (1280, 720, 30), (854, 480, 30), (640, 360, 30), (1024, 576, 25)] {
        for vb in [400, 500, 1500, 2500, 4000, 6000, 12000] {
            for ab in [128, 320] {
                let got = StreamServers.bitrateAdvice(
                    server: server, width: size.0, height: size.1, fps: size.2,
                    videoKbps: vb, audioKbps: ab)
                out.append("advice|\(server)|\(size.0)|\(size.1)|\(size.2)|\(vb)|\(ab)|\(got)")
            }
        }
    }
}

// ------------------------------------------------------- where it goes ---
for video in [false, true] {
    for name in ["", "Blindside Radio"] {
        for channel in ["", "Tony Gebhard", "  "] {
            for server in ["icecast", "shoutcast", "youtube", "facebook",
                           "restream", "rtmp", "", "nonsense"] {
                for host in ["", "radio.example.com",
                             "rtmps://a.rtmps.youtube.com/live2/k",
                             "rtmp://live.example.com/app/KEY"] {
                    var s = PreflightSettings()
                    s.server = server; s.host = host; s.name = name
                    s.videoName = channel; s.mount = "/live"
                    out.append("goes|\(py(video))|\(name)|\(channel)|\(server)|\(host)|"
                             + Preflighter.whereItGoes(s, video: video))
                }
            }
        }
    }
}

// --------------------------------------------------------- picture words ---
for kind in C.pictureSources {
    for cam in ["", "MacBook Pro Camera"] {
        for pf in ["", "/tmp/nope/art.png"] {
            for name in ["", "Tony's Tunes"] {
                var s = PreflightSettings()
                s.picture = kind; s.camera = cam; s.pictureFile = pf
                s.name = name; s.streamName = ""
                out.append("pic|\(kind)|\(cam)|\(pf)|\(name)|\(Preflighter.pictureWords(s))")
            }
        }
    }
}

// ----------------------------------------------------- going live warning ---
for liveTo in C.liveTo {
    for vs in ["youtube", "facebook", "restream", "rtmp", ""] {
        var b = PreflightBoard()
        b.liveTo = liveTo; b.videoServer = vs
        out.append("warn|\(liveTo)|\(vs)|\(Preflighter.goingLiveWarning(b))")
    }
}

// --------------------------------------------------------- the whole check ---
var n = 0
for liveTo in C.liveTo {
    for pair in [("icecast", ""), ("icecast", "radio.example.com"),
                 ("youtube", ""),
                 ("youtube", "rtmps://a.rtmps.youtube.com/live2/key"),
                 ("facebook", "rtmps://live-api-s.facebook.com:443/rtmp/k"),
                 ("restream", "rtmp://live.restream.io/live")] {
        for password in ["", "secret"] {
            for picture in C.pictureSources {
                for mic in [true, false] {
                    for titles in [true, false] {
                        for audioRunning in [true, false] {
                            for micOpen in [true, false] {
                                for screenReady in [true, false] {
                                    n += 1
                                    if n % 7 != 0 { continue }
                                    var s = PreflightSettings()
                                    s.server = pair.0; s.host = pair.1
                                    s.mount = "/live"; s.name = "Blindside Radio"
                                    s.password = password; s.format = "mp3"
                                    s.bitrate = 128; s.picture = picture
                                    s.pictureFile = "/tmp/nope/art.png"
                                    s.camera = "MacBook Pro Camera"
                                    s.videoWidth = 1280; s.videoHeight = 720
                                    s.videoFPS = 30; s.videoBitrate = 2500
                                    var b = PreflightBoard()
                                    b.liveTo = liveTo; b.videoServer = pair.0
                                    b.streamMic = mic; b.streamTitles = titles
                                    let pf = Preflighter.check(
                                        settings: s, board: b,
                                        audioRunning: audioRunning, micOpen: micOpen,
                                        screenReady: screenReady, screenReason: "")
                                    out.append("check|\(n)|\(pf.target)|\(py(pf.blocked))|\(pf.spoken())")
                                    for note in pf.notes {
                                        out.append("  note|\(note.level.rawValue)|\(note.fix)|\(note.text)")
                                    }
                                    out.append("  summary|\(pf.summary())")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
// ------------------------------------------------------ picture notes ---
for consumer in [Preflighter.forStream, Preflighter.forRecording] {
    for picture in C.pictureSources {
        for cam in ["", "MacBook Pro Camera"] {
            for pf in ["", "/tmp/nope/art.png"] {
                for titles in [true, false] {
                    for screenReady in [true, false] {
                        var s = PreflightSettings()
                        s.picture = picture; s.camera = cam; s.pictureFile = pf
                        s.name = "Blindside Radio"
                        s.videoWidth = 1280; s.videoHeight = 720
                        var b = PreflightBoard()
                        b.liveTo = C.liveToAudio; b.videoServer = ""
                        b.streamMic = true; b.streamTitles = titles
                        let notes = Preflighter.pictureNotes(
                            settings: s, board: b, screenReady: screenReady,
                            screenReason: "", consumer: consumer)
                        out.append("picnotes|\(consumer)|\(picture)|\(cam)|\(pf)|"
                                 + "\(py(titles))|\(py(screenReady))|\(notes.count)")
                        for note in notes {
                            out.append("  note|\(note.level.rawValue)|\(note.fix)|\(note.text)")
                        }
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------- note order ---
for pair in [("youtube", "rtmps://a.rtmps.youtube.com/live2/k"),
             ("facebook", "rtmps://live-api-s.facebook.com:443/rtmp/k"),
             ("restream", "rtmp://live.restream.io/live")] {
    for titles in [true, false] {
        for vb in [400, 2500] {
            var s = PreflightSettings()
            s.server = pair.0; s.host = pair.1; s.mount = "/live"
            s.name = "Blindside Radio"; s.password = "secret"
            s.format = "mp3"; s.bitrate = 128; s.picture = C.pictureCard
            s.pictureFile = ""; s.camera = ""
            s.videoWidth = 1280; s.videoHeight = 720; s.videoFPS = 30
            s.videoBitrate = vb
            var b = PreflightBoard()
            b.liveTo = C.liveToVideo; b.videoServer = pair.0
            b.streamMic = true; b.streamTitles = titles
            let pf = Preflighter.check(settings: s, board: b)
            out.append("order|\(pair.0)|\(py(titles))|\(vb)|\(pf.notes.count)")
            for note in pf.notes {
                out.append("  note|\(note.level.rawValue)|\(note.fix)|\(note.text)")
            }
        }
    }
}
print(out.joined(separator: "\n"))
