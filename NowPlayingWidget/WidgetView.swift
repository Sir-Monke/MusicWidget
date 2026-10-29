import SwiftUI
import WidgetKit

struct WidgetView: View {
    let state: NowPlayingState

    private var artwork: NSImage? { state.artwork.flatMap(NSImage.init(data:)) }

    private var title: String {
        if state.needsPermission { return "Allow access to Music" }
        return state.title.isEmpty ? "Not Playing" : state.title
    }

    var body: some View {
        HStack(spacing: 14) {
            cover
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                if !state.artist.isEmpty {
                    Text(state.artist)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                controls
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .padding(14)
        .environment(\.colorScheme, .dark)
        .containerBackground(for: .widget) { background }
        .widgetURL(state.needsPermission
            ? URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
            : nil)
    }

    private var cover: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let artwork {
                    // Without this, the clear/tinted desktop style paints the cover as a flat tint.
                    Image(nsImage: artwork).resizable()
                        .widgetAccentedRenderingMode(.fullColor)
                        .scaledToFill()
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: "music.note")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var controls: some View {
        HStack(spacing: 0) {
            button(.previous, symbol: "backward.fill", size: 18)
            button(.playPause, symbol: state.isPlaying ? "pause.fill" : "play.fill", size: 24)
            button(.next, symbol: "forward.fill", size: 18)
        }
    }

    private func button(_ command: PlayerCommand, symbol: String, size: CGFloat) -> some View {
        Button(intent: PlayerIntent(command)) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(maxWidth: .infinity, minHeight: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var background: some View {
        if let artwork {
            // Soft wash of the cover, like Apple's own Music widget.
            Image(nsImage: artwork)
                .resizable()
                .scaledToFill()
                .blur(radius: 40, opaque: true)
                .overlay(.black.opacity(0.35))
        } else {
            Color(white: 0.16)
        }
    }
}
