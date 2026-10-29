import ServiceManagement
import SwiftUI

/// Windowless helper: keeps the widget in step with Music and runs its buttons.
@main
struct MusicWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if CommandLine.arguments.contains("--selftest") { selfTest() }
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

    for source in [Music.statusScript, Music.artworkScript] + PlayerCommand.allCases.map(Music.commandScript) {
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
