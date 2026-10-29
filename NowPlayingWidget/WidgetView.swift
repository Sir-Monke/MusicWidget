import SwiftUI
import WidgetKit

struct WidgetView: View {
    let state: NowPlayingState
    /// For the README render: ImageRenderer can't draw the system progress bar, so draw a still one.
    var isSnapshot = false

    var body: some View {
        face
            .containerBackground(for: .widget) { backdrop }
            .widgetURL(state.needsPermission
                ? URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
                : nil)
    }

    /// The widget without its background, which only shows in full-colour mode.
    var face: some View {
        HStack(spacing: 14) {
            cover
            VStack(alignment: .leading, spacing: 0) {
                titles
                Spacer(minLength: 6)
                if state.duration > 0 {
                    progress.padding(.bottom, 6)
                }
                controls
            }
        }
        .padding(14)
        .environment(\.colorScheme, .dark)
        .animation(.smooth(duration: 0.45), value: trackID)
    }

    /// Blurred cover behind everything, like Apple's own Music widget.
    @ViewBuilder var backdrop: some View {
        if let artwork {
            Image(nsImage: artwork)
                .resizable()
                .scaledToFill()
                .blur(radius: 40, opaque: true)
                .overlay(LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.5)],
                                        startPoint: .top, endPoint: .bottom))
        } else {
            LinearGradient(colors: [Color(white: 0.2), Color(white: 0.11)], startPoint: .top, endPoint: .bottom)
        }
    }

    private var artwork: NSImage? { state.artwork.flatMap(NSImage.init(data:)) }

    private var trackID: String { "\(state.title)\n\(state.artist)" }

    private var cover: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let artwork {
                    // fullColor, or the clear and tinted desktop styles paint the cover as a flat block.
                    Image(nsImage: artwork).resizable()
                        .widgetAccentedRenderingMode(.fullColor)
                        .scaledToFill()
                } else {
                    ZStack {
                        Rectangle().fill(.white.opacity(0.1))
                        Image(systemName: "music.note")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            .id("\(state.album)\n\(state.artist)")
            .transition(.opacity)
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.needsPermission ? "Allow access to Music" : state.title.isEmpty ? "Not Playing" : state.title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            if !state.artist.isEmpty {
                Text(state.artist)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .id(trackID)
        .transition(.push(from: .bottom))
    }

    /// Runs by itself while playing, so the widget never reloads just to move the bar.
    private var progress: some View {
        HStack(spacing: 8) {
            if state.isPlaying && !isSnapshot {
                let song = state.start...state.start.addingTimeInterval(state.duration)
                Text(timerInterval: song, countsDown: false)
                    .frame(width: 34, alignment: .leading)
                    .multilineTextAlignment(.leading)
                ProgressView(timerInterval: song, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                (Text("-") + Text(timerInterval: song, countsDown: true))
                    .frame(width: 38, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
            } else {
                let elapsed = min(max(0, state.isPlaying ? Date.now.timeIntervalSince(state.start) : state.elapsed),
                                  state.duration)
                Text(clock(elapsed))
                    .frame(width: 34, alignment: .leading)
                if isSnapshot {
                    Capsule()
                        .fill(.white.opacity(0.25))
                        .frame(height: 4)
                        .overlay(alignment: .leading) {
                            GeometryReader { bar in
                                Capsule().fill(.white).frame(width: bar.size.width * elapsed / state.duration)
                            }
                        }
                } else {
                    ProgressView(value: elapsed, total: state.duration)
                }
                Text("-" + clock(state.duration - elapsed))
                    .frame(width: 38, alignment: .trailing)
            }
        }
        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
        .foregroundStyle(.secondary)
        .progressViewStyle(.linear)
        .tint(.white)
    }

    private var controls: some View {
        HStack(spacing: 22) {
            skipButton(.previous, symbol: "backward.fill", label: "Previous")
            playButton
            skipButton(.next, symbol: "forward.fill", label: "Next")
        }
        .frame(maxWidth: .infinity)
    }

    /// A white disc with the symbol cut out of it, so it reads in every desktop widget style.
    private var playButton: some View {
        Button(intent: PlayerIntent(.playPause)) {
            Circle()
                .fill(.white)
                .overlay {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .offset(x: state.isPlaying ? 0 : 1.5)   // optical centre of the triangle
                        .contentTransition(.symbolEffect(.replace))
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .frame(width: 40, height: 40)
                .invalidatableContent()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.isPlaying ? "Pause" : "Play")
    }

    private func skipButton(_ command: PlayerCommand, symbol: String, label: String) -> some View {
        Button(intent: PlayerIntent(command)) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func clock(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds)).formatted(.time(pattern: .minuteSecond))
    }
}
