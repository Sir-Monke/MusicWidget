import AppIntents
import SwiftUI
import WidgetKit

@main
struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: NowPlayingState.widgetKind, provider: Provider()) { entry in
            WidgetView(state: entry.state)
        }
        .configurationDisplayName("Now Playing")
        .description("What's playing in Music.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

struct Entry: TimelineEntry {
    var date = Date()
    var state: NowPlayingState
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(state: NowPlayingState())
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(state: .read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // The app reloads the widget whenever Music changes.
        completion(Timeline(entries: [Entry(state: .read())], policy: .never))
    }
}

/// Runs in the widget, which is sandboxed and can't reach Music, so it hands the command to the app.
struct PlayerIntent: AppIntent {
    static let title: LocalizedStringResource = "Control Music"

    @Parameter(title: "Command") var command: String

    init() {}

    init(_ command: PlayerCommand) {
        self.command = command.rawValue
    }

    func perform() async throws -> some IntentResult {
        if let command = PlayerCommand(rawValue: command) {
            DistributedNotificationCenter.default().postNotificationName(
                command.notification, object: nil, userInfo: nil, deliverImmediately: true)
        }
        return .result()
    }
}
