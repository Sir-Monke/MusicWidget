import Foundation

/// What the widget shows. The app writes it whenever Music changes; the widget reads it.
struct NowPlayingState: Codable, Equatable {
    static let widgetKind = "NowPlaying"

    var isPlaying = false
    var title = ""
    var artist = ""
    var album = ""
    var artwork: Data?
    var needsPermission = false

    /// The real home folder, not the widget's sandbox container, so both sides
    /// agree on the path. The widget's entitlements allow reading this folder.
    static let url: URL = {
        let home = String(cString: getpwuid(getuid())!.pointee.pw_dir)
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/MusicWidget/now-playing.json")
    }()

    static func read() -> NowPlayingState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(NowPlayingState.self, from: data)
        else { return NowPlayingState() }
        return state
    }

    func write() {
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
    }
}

/// Widget buttons post these and the app runs them, since only the app can talk to Music.
enum PlayerCommand: String, CaseIterable {
    case previous = "previous track"
    case playPause = "playpause"
    case next = "next track"

    var notification: Notification.Name { Notification.Name("io.github.sir-monke.musicwidget.\(self)") }
}
