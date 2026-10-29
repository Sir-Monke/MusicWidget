import AppKit
import WidgetKit

/// Talks to Music.app with AppleScript. NSAppleScript isn't thread-safe, so every
/// script runs on one serial queue, which also keeps commands and reads in order.
enum Music {
    static let bundleID = "com.apple.Music"
    private static let queue = DispatchQueue(label: "music.applescript")

    struct Track {
        var isPlaying: Bool
        var title: String
        var artist: String
        var album: String
    }

    enum Snapshot {
        case track(Track)
        case nothing
        case notAuthorised
        case failed
    }

    // The `is running` checks stop a status or artwork read from launching Music.
    static let statusScript = """
        if application id "\(bundleID)" is running then
            tell application id "\(bundleID)"
                if player state is not stopped then
                    try
                        set t to current track
                        return {player state is playing, name of t, artist of t, album of t}
                    end try
                end if
            end tell
        end if
        return {}
        """

    static let artworkScript = """
        if application id "\(bundleID)" is running then
            tell application id "\(bundleID)"
                try
                    return raw data of artwork 1 of current track
                end try
                try
                    return data of artwork 1 of current track
                end try
            end tell
        end if
        """

    static func commandScript(_ command: PlayerCommand) -> String {
        "tell application id \"\(bundleID)\" to \(command.rawValue)"
    }

    /// Launches Music if it isn't running, like pressing play on the keyboard.
    static func send(_ command: PlayerCommand) {
        queue.async { _ = try? run(commandScript(command)) }
    }

    static func snapshot() async -> Snapshot {
        await onQueue { () -> Snapshot in
            do {
                let list = try run(statusScript)
                guard list.numberOfItems == 4 else { return .nothing }
                return .track(Track(
                    isPlaying: list.atIndex(1)?.booleanValue ?? false,
                    title: list.atIndex(2)?.stringValue ?? "",
                    artist: list.atIndex(3)?.stringValue ?? "",
                    album: list.atIndex(4)?.stringValue ?? ""))
            } catch let error as ScriptError where error.code == -1743 {
                return .notAuthorised
            } catch {
                return .failed
            }
        }
    }

    static func artwork(artist: String, album: String) async -> NSImage? {
        let data = await onQueue { try? run(artworkScript).data }
        if let data, let image = NSImage(data: data) { return image }
        return await searchArtwork(artist: artist, album: album)
    }

    /// Streamed Apple Music tracks often have no artwork over AppleScript,
    /// so fall back to the public iTunes Search API.
    // ponytail: takes the top album hit for "artist album"; match on collectionName if wrong covers turn up.
    private static func searchArtwork(artist: String, album: String) async -> NSImage? {
        guard !album.isEmpty else { return nil }
        var search = URLComponents(string: "https://itunes.apple.com/search")!
        search.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(album)"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "US"),
        ]
        struct Album: Decodable { let artworkUrl100: String }
        struct Response: Decodable { let results: [Album] }
        guard let json = try? await URLSession.shared.data(from: search.url!).0,
              let small = try? JSONDecoder().decode(Response.self, from: json).results.first?.artworkUrl100,
              let large = URL(string: small.replacingOccurrences(of: "100x100", with: "600x600")),
              let image = try? await URLSession.shared.data(from: large).0
        else { return nil }
        return NSImage(data: image)
    }

    /// Widgets refuse large images, so the widget gets a small JPEG.
    // ponytail: squashes non-square covers; crop to the centre if one ever looks stretched.
    static func thumbnail(_ image: NSImage) -> Data? {
        let side = 300
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage().flatMap {
            NSBitmapImageRep(cgImage: $0).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        }
    }

    private struct ScriptError: Error { let code: Int }

    private static func run(_ source: String) throws -> NSAppleEventDescriptor {
        var info: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&info)
        guard info == nil, let result else {
            // -1743: the user said no to Automation access.
            throw ScriptError(code: info?[NSAppleScript.errorNumber] as? Int ?? 0)
        }
        return result
    }

    private static func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}

/// Writes Music's state for the widget, reloads it, and runs its button presses.
@MainActor
final class Publisher {
    private var state = NowPlayingState.read()
    private var observers: [Any] = []
    private var refreshTask: Task<Void, Never>?

    func start() {
        // Music posts this on every play, pause and track change.
        var observers: [Any] = [DistributedObserver("com.apple.Music.playerInfo") { [weak self] in self?.refresh() }]
        for command in PlayerCommand.allCases {
            observers.append(DistributedObserver(command.notification.rawValue) { [weak self] in
                Music.send(command)
                self?.refresh() // queued behind the command, so it reads the new state
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Music.bundleID else { return }
            MainActor.assumeIsolated { self?.refresh() }
        })
        self.observers = observers
        refresh()
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            var next: NowPlayingState
            switch await Music.snapshot() {
            case .failed:
                return // transient, keep what's showing
            case .nothing:
                next = NowPlayingState()
            case .notAuthorised:
                next = NowPlayingState(needsPermission: true)
            case .track(let track):
                next = NowPlayingState(isPlaying: track.isPlaying, title: track.title,
                                       artist: track.artist, album: track.album)
                if track.album == state.album, track.artist == state.artist {
                    next.artwork = state.artwork
                } else if let image = await Music.artwork(artist: track.artist, album: track.album) {
                    next.artwork = Music.thumbnail(image)
                }
            }
            // Music posts several notifications per change; only reload when something differs.
            guard !Task.isCancelled, next != state else { return }
            state = next
            state.write()
            WidgetCenter.shared.reloadTimelines(ofKind: NowPlayingState.widgetKind)
        }
    }
}

/// Selector-based so it can ask for `.deliverImmediately`. This app is never
/// active, and AppKit can otherwise hold distributed notifications for inactive apps.
private final class DistributedObserver: NSObject {
    private let action: @MainActor () -> Void

    init(_ name: String, action: @escaping @MainActor () -> Void) {
        self.action = action
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(fire), name: NSNotification.Name(name), object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    @objc private func fire() {
        let action = self.action
        Task { @MainActor in action() }
    }
}
