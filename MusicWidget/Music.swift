import AppKit
import WidgetKit

/// Talks to Music.app. NSAppleScript isn't thread-safe, so every script runs on one serial queue;
/// the buttons skip that queue and send Apple events directly (see `send`).
enum Music {
    static let bundleID = "com.apple.Music"
    private static let queue = DispatchQueue(label: "music.applescript")

    struct Track {
        var isPlaying: Bool
        var title: String
        var artist: String
        var album: String
        var elapsed: TimeInterval
        var duration: TimeInterval
    }

    enum Snapshot {
        case track(Track)
        /// Stopped, or Music isn't open.
        case nothing
        /// Playing or paused, but Music can't say what yet: between songs, or loading one.
        case busy
        case notAuthorised
        case failed

        var isSettled: Bool {
            switch self {
            case .nothing, .busy: false
            default: true
            }
        }
    }

    // Every property is asked for on its own: an Apple Music song that isn't in the library can refuse
    // any one of them, and asking together loses the whole song when it does.
    // The `is running` checks stop a status or artwork read from launching Music.
    static let statusScript = """
        if application id "\(bundleID)" is running then
            tell application id "\(bundleID)"
                set s to player state
                set n to ""
                set a to ""
                set b to ""
                set p to 0
                set d to 0
                try
                    set n to name of current track
                end try
                try
                    set a to artist of current track
                end try
                try
                    set b to album of current track
                end try
                try
                    set p to player position as real
                end try
                try
                    set d to (duration of current track) as real
                end try
                return {s is playing, s is stopped, n, a, b, p, d}
            end tell
        end if
        return {}
        """

    // Streamed songs can take seconds to hand over a cover, and every read waits behind this one.
    static let artworkScript = """
        if application id "\(bundleID)" is running then
            tell application id "\(bundleID)"
                with timeout of 2 seconds
                    try
                        return raw data of artwork 1 of current track
                    end try
                    try
                        return data of artwork 1 of current track
                    end try
                end timeout
            end tell
        end if
        """

    static let positionScript = "tell application id \"\(bundleID)\" to player position"

    // Compiled once, on first use: compiling loads Music's whole dictionary, the slow part of every read.
    private static let status = compiled(statusScript)
    private static let artworkReader = compiled(artworkScript)
    private static let positionReader = compiled(positionScript)

    private static func compiled(_ source: String) -> NSAppleScript? {
        let script = NSAppleScript(source: source)
        _ = script?.compileAndReturnError(nil)
        return script
    }

    static func commandScript(_ command: PlayerCommand) -> String {
        "tell application id \"\(bundleID)\" to \(command.rawValue)"
    }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Sends the button straight to Music as an Apple event and doesn't wait for a reply, so it never
    /// queues behind a slow read. If Music isn't running, AppleScript instead, which launches it.
    static func send(_ command: PlayerCommand) {
        guard isRunning else {
            queue.async { _ = try? run(NSAppleScript(source: commandScript(command))) }
            return
        }
        let event = NSAppleEventDescriptor(
            eventClass: fourCharCode("hook"), eventID: fourCharCode(eventID(command)),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: bundleID),
            returnID: -1, transactionID: 0)   // kAutoGenerateReturnID, kAnyTransactionID
        _ = try? event.sendEvent(options: [.noReply], timeout: 1)
    }

    /// Music's own code for each command, after the "hook" class: `next track` is hookNext.
    static func eventID(_ command: PlayerCommand) -> String {
        switch command {
        case .previous: "Prev"
        case .playPause: "PlPs"
        case .next: "Next"
        }
    }

    static func fourCharCode(_ code: String) -> FourCharCode {
        code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    static func snapshot() async -> Snapshot {
        await onQueue { () -> Snapshot in
            do {
                let list = try run(status)
                guard list.numberOfItems == 7 else { return .nothing }   // Music isn't open
                let title = list.atIndex(3)?.stringValue ?? ""
                guard !title.isEmpty else {
                    // Music won't name the song: stopped, or still loading the next one.
                    return list.atIndex(2)?.booleanValue == true ? .nothing : .busy
                }
                return .track(Track(
                    isPlaying: list.atIndex(1)?.booleanValue ?? false,
                    title: title,
                    artist: list.atIndex(4)?.stringValue ?? "",
                    album: list.atIndex(5)?.stringValue ?? "",
                    elapsed: seconds(list.atIndex(6)?.doubleValue),
                    duration: seconds(list.atIndex(7)?.doubleValue)))
            } catch let error as ScriptError where error.code == -1743 {
                return .notAuthorised
            } catch {
                return .failed
            }
        }
    }

    /// Music's playerInfo notification says what's playing, and unlike AppleScript it does so for every
    /// song, including Apple Music songs that aren't in the library. Nil when it doesn't name the song.
    static func snapshot(playerInfo info: [AnyHashable: Any]?) -> Snapshot? {
        let state = info?["Player State"] as? String
        if state == "Stopped" { return .nothing }
        guard let title = info?["Name"] as? String else { return nil }
        return .track(Track(
            isPlaying: state == "Playing",
            title: title,
            artist: info?["Artist"] as? String ?? "",
            album: info?["Album"] as? String ?? "",
            elapsed: 0,
            duration: seconds((info?["Total Time"] as? NSNumber).map { $0.doubleValue / 1000 })))
    }

    /// Where in the song Music is. Asked separately: it works even when Music won't describe the song.
    static func position() async -> TimeInterval {
        await onQueue { seconds((try? run(positionReader))?.doubleValue) }
    }

    /// A failed coercion can come back as NaN, which the state file's JSON can't hold.
    private static func seconds(_ value: Double?) -> TimeInterval {
        guard let value, value.isFinite, value >= 0 else { return 0 }
        return value
    }

    static func artwork(artist: String, album: String) async -> NSImage? {
        let data = await onQueue { try? run(artworkReader).data }
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
        // 5 seconds, not the default minute, so a bad connection can't leave a song without its cover for long.
        guard let json = try? await URLSession.shared.data(for: URLRequest(url: search.url!, timeoutInterval: 5)).0,
              let small = try? JSONDecoder().decode(Response.self, from: json).results.first?.artworkUrl100,
              let large = URL(string: small.replacingOccurrences(of: "100x100", with: "600x600")),
              let image = try? await URLSession.shared.data(for: URLRequest(url: large, timeoutInterval: 5)).0
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

    private static func run(_ script: NSAppleScript?) throws -> NSAppleEventDescriptor {
        var info: NSDictionary?
        let result = script?.executeAndReturnError(&info)
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
    /// Covers of recently played albums, so coming back to one shows its cover at once.
    private let covers: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 50
        return cache
    }()

    func start() {
        // Music posts this on every play, pause and song change.
        var observers: [Any] = [DistributedObserver("com.apple.Music.playerInfo") { [weak self] note in
            let snapshot = Music.snapshot(playerInfo: note.userInfo)
            Task { @MainActor [weak self] in self?.playerInfo(snapshot) }
        }]
        for command in PlayerCommand.allCases {
            observers.append(DistributedObserver(command.notification.rawValue) { [weak self] _ in
                Music.send(command)
                // Most changes also post playerInfo; this read catches the rest, like restarting a song.
                Task { @MainActor [weak self] in self?.refresh() }
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
        if let cover = state.artwork {
            covers.setObject(cover as NSData, forKey: Self.coverKey(artist: state.artist, album: state.album))
        }
        // Redraw once at launch, so a new version of the widget shows straight away.
        WidgetCenter.shared.reloadTimelines(ofKind: NowPlayingState.widgetKind)
        refresh()
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            var snapshot = await Music.snapshot()
            // As one song hands over to the next, Music can't say what's playing for a moment, and it
            // doesn't post again once it can. So while Music is open, keep checking every second for a
            // while, showing the last song meanwhile. Only a stop that lasts two seconds shows Not Playing.
            // Any new notification cancels this and starts over.
            for second in 1...15 where !snapshot.isSettled && Music.isRunning {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                if second == 2, case .nothing = snapshot { await show(.nothing) }
                snapshot = await Music.snapshot()
            }
            await show(snapshot)
        }
    }

    /// Music's notification already names the song, so only the position is asked for.
    func playerInfo(_ snapshot: Music.Snapshot?) {
        guard let snapshot else { return refresh() }
        refreshTask?.cancel()
        refreshTask = Task {
            if case .track(var track) = snapshot {
                track.elapsed = await Music.position()
                await show(.track(track))
            } else {
                // Mid-skip Music can post Stopped for a moment; the next song's notification cancels this.
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await show(snapshot)
            }
        }
    }

    private func show(_ snapshot: Music.Snapshot) async {
        var next: NowPlayingState
        switch snapshot {
        case .failed, .busy:
            return // transient, keep what's showing
        case .nothing:
            next = NowPlayingState()
        case .notAuthorised:
            next = NowPlayingState(needsPermission: true)
        case .track(let track):
            next = NowPlayingState(isPlaying: track.isPlaying, title: track.title,
                                   artist: track.artist, album: track.album,
                                   duration: track.duration, elapsed: track.elapsed, asOf: .now)
            next.artwork = covers.object(forKey: Self.coverKey(artist: track.artist, album: track.album)) as Data?
        }
        guard !Task.isCancelled else { return }
        // Song first, so a skip shows straight away; the cover follows once it's found.
        if !next.looksLike(state) { publish(next) }
        if case .track(let track) = snapshot, next.artwork == nil,
           let image = await Music.artwork(artist: track.artist, album: track.album),
           let cover = Music.thumbnail(image), !Task.isCancelled {
            covers.setObject(cover as NSData, forKey: Self.coverKey(artist: track.artist, album: track.album))
            next.artwork = cover
            publish(next)
        }
    }

    private static func coverKey(artist: String, album: String) -> NSString {
        "\(artist)\n\(album)" as NSString
    }

    private func publish(_ next: NowPlayingState) {
        state = next
        state.write()
        WidgetCenter.shared.reloadTimelines(ofKind: NowPlayingState.widgetKind)
    }
}

/// Selector-based so it can ask for `.deliverImmediately`. This app is never
/// active, and AppKit can otherwise hold distributed notifications for inactive apps.
private final class DistributedObserver: NSObject {
    private let action: (Notification) -> Void

    init(_ name: String, action: @escaping (Notification) -> Void) {
        self.action = action
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(fire(_:)), name: NSNotification.Name(name), object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    @objc private func fire(_ note: Notification) {
        action(note)
    }
}
