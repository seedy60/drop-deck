// Track titles reaching a station, proved offline, for --check-titles.
//
//   TGDropDeck --check-titles <host> <port> <mount> <user> <password>
//
// Until 3.8.4 no title ever left a Mac once it was live: `Streamer.nowPlaying`
// had no caller (analysis N1). A unit check of the address cannot prove the
// request is really made, when, and with what in it, so this drives the REAL
// streamer against a server on this machine, `tools/mock_icecast.py` from the
// Windows project, imported and never edited, and `mac/tools/check_titles.py`
// reads back what arrived.
//
// Every title goes through `MainWindow.titleToSend`, the one function the
// window uses for the station, the card and the words on the picture, so what
// is proved here is what a show sends. Nothing touches the internet.

import Foundation

enum TitleCheck {

    static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count >= 5 else {
            print("usage: --check-titles <host> <port> <mount> <user> <password>")
            return 2
        }
        var settings = StreamSettings()
        settings.host = arguments[0]
        settings.port = Int(arguments[1]) ?? 8000
        settings.mount = arguments[2]
        settings.user = arguments[3]
        settings.password = arguments[4]
        settings.name = "Title check"
        settings.format = C.streamFormatAAC
        settings.bitrate = 128

        let dance = Track(filepath: "/nowhere/the dance.mp3")
        dance.title = "The Dance"
        dance.artist = "Garth Brooks"
        let awkward = Track(filepath: "/nowhere/awkward.mp3")
        awkward.title = "Tom & Jerry's Song = 100% + more"
        awkward.artist = "Ünïcödé Band"
        let untagged = Track(filepath: "/nowhere/station ident.wav")

        // In the order they are sent. The fourth is a track sent with Send
        // what is playing OFF, which must send nothing at all.
        let plan: [(Track, String, Bool)] = [
            (dance, TitleFormat.titleByArtist, true),
            (dance, TitleFormat.artistTitle, true),
            (awkward, TitleFormat.titleByArtist, true),
            (untagged, TitleFormat.artistTitle, false),
            (untagged, TitleFormat.artistTitle, true),
        ]

        let rate = 48000.0
        let group = MixerGroup(mainDeviceUID: nil, bankDevices: [:])
        let streamer = Streamer()

        // The first title is held BEFORE the connection, exactly as Option
        // Shift B does it, so it goes out the moment the station takes us.
        let first = MainWindow.titleToSend(plan[0].0, format: plan[0].1, send: plan[0].2)
        streamer.nowPlaying(first)
        print("title  \(first)")
        guard streamer.start(group: group, settings: settings) else {
            print("FAIL: the streamer refused to start")
            return 1
        }

        // A tone, so the station has a real source and the silence rule never
        // takes it off.
        let frames = 512
        var block = [Float](repeating: 0, count: frames * 2)
        var phase = 0.0
        func feed(_ seconds: Double) {
            let until = Date().addingTimeInterval(seconds)
            while Date() < until {
                for i in 0..<frames {
                    let v = Float(sin(phase)) * 0.25
                    phase += 2 * .pi * 440 / rate
                    block[i * 2] = v
                    block[i * 2 + 1] = v
                }
                block.withUnsafeBufferPointer { p in
                    group.taps.write(key: "main", samples: p.baseAddress!,
                                     frames: frames, rate: rate)
                }
                Thread.sleep(forTimeInterval: Double(frames) / rate)
            }
        }

        feed(1.5)
        guard streamer.state == .live else {
            print("FAIL: never reached the live state (\(streamer.detail))")
            streamer.stop(group: group)
            return 1
        }
        for (track, format, send) in plan.dropFirst() {
            let title = MainWindow.titleToSend(track, format: format, send: send)
            streamer.nowPlaying(title)
            print(title.isEmpty ? "held   (nothing, Send what is playing is off)"
                                : "title  \(title)")
            feed(0.6)
        }
        feed(0.5)
        let sent = streamer.titlesSent
        let accepted = streamer.titlesAccepted
        streamer.stop(group: group)
        group.stop()
        print("sent \(sent), accepted \(accepted)")
        return sent == 4 && accepted == 4 ? 0 : 1
    }
}
