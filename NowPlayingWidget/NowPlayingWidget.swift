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
        // The app reloads the widget whenever Music changes; the progress bar and times run by themselves.
        completion(Timeline(entries: [Entry(state: .read())], policy: .never))
    }
}
