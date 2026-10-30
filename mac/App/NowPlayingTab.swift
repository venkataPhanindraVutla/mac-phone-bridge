import AMProtocol
import AppKit
import FeatureMedia
import SwiftUI

/// The Phone window's Now Playing tab: what the phone is playing, its transport buttons, and the
/// Position and Volume sliders (a seek or a volume change is sent when the slider is let go).
struct NowPlayingTab: View {
    let model: AppModel
    /// Each slider's own value while dragged, and after release until the phone's next state.
    @State private var seek = SliderHold()
    @State private var volume = SliderHold()

    private var media: MediaModel { model.media }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.isConnected || !model.canMedia {
                Text(model.statusText)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else if let notice = MediaNotice.text(media.phoneAvailability) {
                Text(notice)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else if let state = model.nowPlaying {
                playing(state)
            } else {
                Text("Nothing is playing on the phone.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: media.state) {
            seek.stateArrived()
            volume.stateArrived()
        }
    }

    @ViewBuilder private func playing(_ state: AMMediaState) -> some View {
        HStack(alignment: .top, spacing: 16) {
            artwork
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: NowPlayingText.title(state))
                    .font(.title3.weight(.semibold))
                if !state.artist.isEmpty {
                    Text(verbatim: state.artist)
                }
                if !state.appLabel.isEmpty {
                    Text(verbatim: state.appLabel)
                        .foregroundStyle(.secondary)
                }
                transport(state)
                    .padding(.top, 8)
            }
            .accessibilityElement(children: .contain)
        }
        position(state)
        volumeSlider(state)
        Spacer(minLength: 0)
    }

    @ViewBuilder private var artwork: some View {
        Group {
            if let image = media.artworkImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 160, height: 160)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }

    private func transport(_ state: AMMediaState) -> some View {
        HStack(spacing: 12) {
            Button { send(.previous) } label: { Image(systemName: "backward.fill") }
                .disabled(!state.canPrevious)
                .accessibilityLabel(Text("Previous"))
            if state.playing {
                Button { send(.pause) } label: { Image(systemName: "pause.fill") }
                    .disabled(!state.canPause)
                    .accessibilityLabel(Text("Pause"))
            } else {
                Button { send(.play) } label: { Image(systemName: "play.fill") }
                    .disabled(!state.canPlay)
                    .accessibilityLabel(Text("Play"))
            }
            Button { send(.next) } label: { Image(systemName: "forward.fill") }
                .disabled(!state.canNext)
                .accessibilityLabel(Text("Next"))
        }
        .controlSize(.large)
    }

    private func position(_ state: AMMediaState) -> some View {
        // Redrawn every second, so the position moves while playing.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = Double(max(state.durationMs, 0))
            let current = seek.value ?? Double(media.positionMs(now: context.date))
            VStack(alignment: .leading, spacing: 2) {
                Slider(
                    value: Binding(get: { current }, set: { seek.drag($0) }),
                    in: 0...max(duration, 1),
                    onEditingChanged: { editing in
                        guard !editing, let release = seek.release() else { return }
                        Task {
                            await media.command(.seek, positionMs: Int64(release.value.rounded()))
                            try? await Task.sleep(for: Self.answerTimeout)
                            seek.timedOut(release.id)
                        }
                    }
                ) {
                    Text("Position")
                }
                .labelsHidden()
                .disabled(!state.canSeek || duration <= 0)
                .accessibilityLabel(Text("Position"))
                .accessibilityValue(Text(verbatim: NowPlayingText.clock(Int64(current))))
                HStack {
                    Text(verbatim: NowPlayingText.clock(Int64(current)))
                    Spacer()
                    if duration > 0 {
                        Text(verbatim: "-" + NowPlayingText.clock(Int64(duration - min(current, duration))))
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private func volumeSlider(_ state: AMMediaState) -> some View {
        if state.hasVolume, state.volume.max > 0 {
            let max = Double(state.volume.max)
            let current = volume.value ?? Double(state.volume.current)
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Slider(
                    value: Binding(get: { current }, set: { volume.drag($0) }),
                    in: 0...max, step: 1,
                    onEditingChanged: { editing in
                        guard !editing, let release = volume.release() else { return }
                        Task {
                            await media.command(.setVolume, volume: UInt32(release.value.rounded()))
                            try? await Task.sleep(for: Self.answerTimeout)
                            volume.timedOut(release.id)
                        }
                    }
                ) {
                    Text("Volume")
                }
                .labelsHidden()
                .disabled(state.volume.fixed)
                .accessibilityLabel(Text("Volume"))
                .accessibilityValue(Text(verbatim: "\(Int(current))"))
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    /// How long a released slider waits for the phone's next state before showing the phone's value.
    private static let answerTimeout: Duration = .seconds(1)

    private func send(_ kind: AMMediaCommandKind) {
        Task { await media.command(kind) }
    }
}

/// The line under the track: `"\(artist) · \(app)"`, or whichever of the two there is.
enum NowPlayingText {
    static func byline(_ state: AMMediaState) -> Text? {
        switch (state.artist.isEmpty, state.appLabel.isEmpty) {
        case (false, false): Text("\(state.artist) · \(state.appLabel)")
        case (false, true): Text(verbatim: state.artist)
        case (true, false): Text(verbatim: state.appLabel)
        case (true, true): nil
        }
    }

    /// The track title; the app's name when the phone gave none.
    static func title(_ state: AMMediaState) -> String {
        state.title.isEmpty ? state.appLabel : state.title
    }

    /// `m:ss`, e.g. `3:07` (minutes go past 59).
    static func clock(_ ms: Int64) -> String {
        let seconds = max(0, ms) / 1000
        return String(format: "%lld:%02lld", seconds / 60, seconds % 60)
    }
}

/// The phone notice when its media control is off, for the menu and the tab.
enum MediaNotice {
    static func text(_ availability: AMFeatureAvailability?) -> LocalizedStringResource? {
        guard let availability, !availability.enabled else { return nil }
        switch availability.reason {
        case .offByUser: return "Turn on media control in the phone app."
        case .needsPermission: return "Turn on notification access in the phone app."
        default: return nil
        }
    }
}

/// The phone's artwork at a given size: a menu item shows an image at its own `size`.
enum ArtworkImage {
    /// A copy of `image` fitted into `side` × `side` points.
    static func sized(_ image: NSImage?, side: CGFloat) -> NSImage? {
        guard let image, image.size.width > 0, image.size.height > 0,
              let sized = image.copy() as? NSImage else { return nil }
        let scale = side / max(image.size.width, image.size.height)
        sized.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return sized
    }
}
