import ServiceManagement
import SwiftUI

/// Set by `--render-docs <folder>`: render the README images there instead of running normally.
let docsFolder: URL? = CommandLine.arguments.firstIndex(of: "--render-docs").flatMap { i in
    CommandLine.arguments.indices.contains(i + 1) ? URL(fileURLWithPath: CommandLine.arguments[i + 1]) : nil
}

/// Windowless helper: keeps the widget in step with Music and runs its buttons.
@main
struct MusicWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if CommandLine.arguments.contains("--selftest") { selfTest() }
        guard docsFolder == nil else { return }
        if !Bundle.main.bundlePath.contains("/Applications/") { installAndRelaunch() }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if others.contains(where: { $0 != NSRunningApplication.current && $0.bundleURL?.path.contains("/Applications/") == true }) {
            exit(0)   // already running
        }
        enableLoginItemOnce()
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let publisher = Publisher()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let docsFolder { renderDocs(to: docsFolder) }
        publisher.start()
    }
}

/// Run from Xcode (or a download), the app copies itself into Applications, starts that copy and quits,
/// so it never needs Xcode again. If the copy fails it just keeps running from where it is.
func installAndRelaunch() {
    let fm = FileManager.default
    var folder = URL(fileURLWithPath: "/Applications")
    if !fm.isWritableFile(atPath: folder.path) { folder = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications") }
    let target = folder.appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)

    // Quit the installed copy first, so it can be replaced.
    let old = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        .filter { $0 != NSRunningApplication.current }
    old.forEach { $0.terminate() }
    for _ in 0..<30 where old.contains(where: { !$0.isTerminated }) { Thread.sleep(forTimeInterval: 0.1) }
    old.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }

    do {
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: Bundle.main.bundleURL, to: target)
    } catch {
        print("Music Widget: could not install into \(folder.path): \(error.localizedDescription)")
        return
    }
    // macOS keeps the old widget running from memory; quit it so the new one loads.
    let quitWidget = Process()
    quitWidget.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    quitWidget.arguments = ["-f", "NowPlayingWidget.appex/Contents/MacOS/NowPlayingWidget"]
    try? quitWidget.run()
    quitWidget.waitUntilExit()

    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = [target.path]
    try? open.run()
    open.waitUntilExit()
    exit(0)
}

/// Starts at login by default, once, so the widget keeps updating after a restart.
/// After that, System Settings › General › Login Items is in charge.
func enableLoginItemOnce() {
    let key = "didSetUpLoginItem"
    guard !UserDefaults.standard.bool(forKey: key) else { return }
    UserDefaults.standard.set(true, forKey: key)
    try? SMAppService.mainApp.register()
}

/// `--selftest`: checks the state file, that every script compiles against Music, and cover shrinking, then exits.
@MainActor func selfTest() -> Never {
    let state = NowPlayingState(isPlaying: true, title: "Song", artist: "Artist", album: "Album", artwork: Data([1, 2, 3]))
    let decoded = (try? JSONEncoder().encode(state)).flatMap { try? JSONDecoder().decode(NowPlayingState.self, from: $0) }
    precondition(decoded == state, "state survives the trip to disk and back")
    precondition(NowPlayingState.url.path.hasSuffix("/Library/Application Support/MusicWidget/now-playing.json")
                 && !NowPlayingState.url.path.contains("/Containers/"),
                 "state lives in the real home folder, where the widget's sandbox lets it read")

    let playing = NowPlayingState(isPlaying: true, title: "Song", duration: 200, elapsed: 50, asOf: .now)
    var readAgain = playing
    (readAgain.elapsed, readAgain.asOf) = (51.2, playing.asOf.addingTimeInterval(1.2))
    precondition(readAgain.looksLike(playing), "the same moment read again a second later doesn't reload the widget")
    var skipped = playing
    skipped.elapsed = 120
    precondition(!skipped.looksLike(playing), "jumping within the song does")
    var paused = playing
    paused.isPlaying = false
    precondition(!paused.looksLike(playing), "pausing does")
    precondition(abs(playing.start.timeIntervalSince(playing.asOf) + 50) < 0.001, "the clock starts where the song began")

    let dates = playing.entryDates(from: playing.asOf)
    let end = playing.start.addingTimeInterval(playing.duration)
    precondition(dates.first == playing.asOf && dates.count > 1 && dates.count <= 12 && dates.last! < end,
                 "a playing song gets a few redraws until it ends, at most 12")
    precondition(Music.fourCharCode("hook") == 0x686F_6F6B, "Apple event codes pack like the C literal 'hook'")

    let info: [AnyHashable: Any] = ["Name": "Song", "Artist": "Artist", "Album": "Album",
                                    "Player State": "Paused", "Total Time": 169_000]
    if case .track(let track)? = Music.snapshot(playerInfo: info) {
        precondition(track.title == "Song" && track.artist == "Artist" && track.album == "Album"
                     && !track.isPlaying && track.duration == 169, "Music's notification reads as the song")
    } else {
        preconditionFailure("Music's notification reads as the song")
    }
    if case .nothing? = Music.snapshot(playerInfo: ["Player State": "Stopped"]) {} else {
        preconditionFailure("Stopped reads as nothing playing")
    }
    precondition(Music.snapshot(playerInfo: ["Player State": "Playing"]) == nil,
                 "a notification without a song name falls back to asking AppleScript")
    if let music = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Music.bundleID),
       let name = Bundle(url: music)?.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String,
       let dictionary = try? String(contentsOf: music.appendingPathComponent("Contents/Resources/\(name)"), encoding: .utf8) {
        for command in PlayerCommand.allCases {
            precondition(dictionary.contains("name=\"\(command.rawValue)\" code=\"hook\(Music.eventID(command))\""),
                         "Music's dictionary has \(command.rawValue) as hook\(Music.eventID(command))")
        }
    } else {
        print("selftest: Music's scripting dictionary not found, command codes unchecked")
    }
    precondition(paused.entryDates(from: playing.asOf) == [playing.asOf], "a paused song gets one")
    precondition(playing.entryDates(from: end.addingTimeInterval(5)).count == 1, "a song that's over gets one")

    for source in [Music.statusScript, Music.artworkScript, Music.positionScript]
                    + PlayerCommand.allCases.map(Music.commandScript) {
        var error: NSDictionary?
        let compiled = NSAppleScript(source: source)?.compileAndReturnError(&error) ?? false
        precondition(compiled, "script compiles against Music: \(error ?? [:])")
    }

    let big = NSImage(size: NSSize(width: 1400, height: 1400), flipped: false) { rect in
        NSColor.orange.setFill()
        rect.fill()
        return true
    }
    let thumbnail = Music.thumbnail(big).flatMap(NSBitmapImageRep.init(data:))
    precondition(thumbnail?.pixelsWide == 300 && thumbnail?.pixelsHigh == 300, "covers shrink to 300px for the widget")

    print("selftest ok")
    exit(0)
}

/// `--render-docs <folder>`: draws the real widget, playing a made-up song with a made-up cover,
/// on a light and a dark desktop, then exits.
@MainActor func renderDocs(to folder: URL) -> Never {
    // A low sun sinking into the sea.
    let cover = NSImage(size: NSSize(width: 600, height: 600), flipped: false) { rect in
        NSGradient(colors: [NSColor(srgbRed: 0.35, green: 0.29, blue: 0.50, alpha: 1),
                            NSColor(srgbRed: 0.93, green: 0.52, blue: 0.40, alpha: 1),
                            NSColor(srgbRed: 0.99, green: 0.80, blue: 0.50, alpha: 1)])?
            .draw(in: rect, angle: -90)
        NSColor(srgbRed: 1, green: 0.94, blue: 0.80, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 200, y: 130, width: 200, height: 200)).fill()
        NSGradient(starting: NSColor(srgbRed: 0.18, green: 0.21, blue: 0.38, alpha: 1),
                   ending: NSColor(srgbRed: 0.44, green: 0.36, blue: 0.53, alpha: 1))?
            .draw(in: NSRect(x: 0, y: 0, width: 600, height: 220), angle: 90)
        return true
    }
    let widget = WidgetView(state: NowPlayingState(
        isPlaying: true, title: "Low Sun Over the Harbour", artist: "Evening Tide", album: "Evening Tide",
        artwork: Music.thumbnail(cover), duration: 236, elapsed: 83, asOf: .now))

    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let desktops: [(String, [Color])] = [
        ("light", [Color(red: 0.98, green: 0.95, blue: 0.90), Color(red: 0.95, green: 0.79, blue: 0.65)]),
        ("dark", [Color(red: 0.12, green: 0.13, blue: 0.21), Color(red: 0.29, green: 0.20, blue: 0.27)]),
    ]
    for (name, colors) in desktops {
        let page = widget.face
            .frame(width: 338, height: 158)
            .background { widget.backdrop }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            .frame(width: 520, height: 280)
            .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
        let renderer = ImageRenderer(content: page)
        renderer.scale = 2
        let png = renderer.cgImage.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
        try? png?.write(to: folder.appendingPathComponent("hero-\(name).png"))
    }
    print("rendered README images into \(folder.path)")
    exit(0)
}
