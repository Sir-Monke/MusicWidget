import AppIntents
import Foundation

/// What the widget shows. The app writes it whenever Music changes; the widget reads it.
struct NowPlayingState: Codable, Equatable {
    static let widgetKind = "NowPlaying"

    enum RepeatMode: Int, Codable { case off, all, one }

    var isPlaying = false
    var title = ""
    var artist = ""
    var album = ""
    var artwork: Data?
    var needsPermission = false
    /// Song length in seconds, 0 when Music doesn't know (radio).
    var duration: TimeInterval = 0
    /// How far into the song Music was at `asOf`.
    var elapsed: TimeInterval = 0
    var asOf = Date.distantPast
    var shuffle = false
    var repeatMode = RepeatMode.off
    /// Whether the song is favourited in Music. Always false for songs it won't say.
    var favourite = false

    /// When the song would have started had it played straight through, so the widget's clock can run by itself.
    var start: Date { asOf.addingTimeInterval(-elapsed) }

    /// When the widget should redraw to move its progress bar: a dozen times or fewer until the song
    /// ends while it plays, otherwise once. macOS draws every one up front, so more makes skips slow.
    func entryDates(from now: Date = .now) -> [Date] {
        let left = start.addingTimeInterval(duration).timeIntervalSince(now)
        guard isPlaying, duration > 0, left > 0 else { return [now] }
        return stride(from: 0, to: left, by: max(5, left / 12)).map { now.addingTimeInterval($0) }
    }

    /// Same song and settings, with the clock within a second of where it was. Music posts several
    /// notifications for one change, and this stops each of them reloading the widget.
    func looksLike(_ other: NowPlayingState) -> Bool {
        let drift = isPlaying ? abs(start.timeIntervalSince(other.start)) : abs(elapsed - other.elapsed)
        var a = self, b = other
        (a.elapsed, a.asOf, b.elapsed, b.asOf) = (0, .distantPast, 0, .distantPast)
        return a == b && drift < 1.5
    }

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
    case previous, playPause, next, shuffle, repeatMode, favourite

    /// Music's own name and Apple event code, for the three that are one word to Music and
    /// need to be instant. The rest are property changes, and go as AppleScript.
    var transport: (name: String, eventID: String)? {
        switch self {
        case .previous: ("previous track", "Prev")
        case .playPause: ("playpause", "PlPs")
        case .next: ("next track", "Next")
        default: nil
        }
    }

    var notification: Notification.Name { Notification.Name("io.github.sir-monke.musicwidget.\(rawValue)") }
}

/// A widget button. The widget is sandboxed and can't reach Music, so it hands the command to the app.
struct PlayerIntent: AppIntent {
    static let title: LocalizedStringResource = "Control Music"

    @Parameter(title: "Command") var command: String

    init() {}

    init(_ command: PlayerCommand) {
        self.command = command.rawValue
    }

    func perform() async throws -> some IntentResult {
        guard let command = PlayerCommand(rawValue: command) else { return .result() }
        let before = NowPlayingState.read()
        DistributedNotificationCenter.default().postNotificationName(
            command.notification, object: nil, userInfo: nil, deliverImmediately: true)
        // The widget redraws when this returns, so give the app a moment to save the new state:
        // the button then flips once, straight to the right thing.
        for _ in 0..<15 where NowPlayingState.read() == before {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return .result()
    }
}
