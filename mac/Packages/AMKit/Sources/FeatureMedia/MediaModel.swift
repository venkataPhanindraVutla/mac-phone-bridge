import AMProtocol
import AppKit
import ConnectionCore
import Foundation
import Observation
import os
import SwiftProtobuf

/// The phone's media session (SPEC section 20), while the phone shares `media.v1`: its
/// `media.state` is shown in macOS Now Playing (and read by the menu and the Phone window), its
/// artwork is kept in memory for the session, and the user's commands (menu, window, media keys,
/// Control Center) go back as `media.command` naming the current session key.
///
/// Commands are user-triggered, so they need only an active state; a phone that reports media
/// control off gets none, and what it was playing stops being shown.
///
/// The `media` log has one line per command answered: `command <kind> rtt <ms> ms`, measured to
/// the first `media.state` from that session after it. Titles, artists, albums and app labels
/// are never logged.
@MainActor
@Observable
public final class MediaModel: SessionFeature {
    public let messagePrefixes = ["media."]

    /// The phone's last `media.state` this session; nil or `active == false`: nothing playing.
    public private(set) var state: AMMediaState?
    /// The current state's artwork (JPEG), once it has arrived.
    public private(set) var artwork: Data?
    /// `artwork` decoded, for the menu and the Phone window; nil when it is no image. It goes
    /// with `artwork`, so no image outlives the session.
    public private(set) var artworkImage: NSImage?
    /// The phone's last `media.availability`; nil until the first one of this connection.
    public private(set) var phoneAvailability: AMFeatureAvailability?
    /// Each command answered, with its round trip (for the sim; the log line is written anyway).
    @ObservationIgnored public var onRoundTrip: ((AMMediaCommandKind, Duration) -> Void)?

    @ObservationIgnored private let center: any NowPlayingCenter
    @ObservationIgnored private let send: @MainActor (MessageType, any SwiftProtobuf.Message & Sendable) async -> Void
    @ObservationIgnored private let now: () -> Date
    /// The phone in session, while it shares `media.v1`.
    @ObservationIgnored private var phoneID: String?
    /// When `state` arrived, for extrapolating its position.
    @ObservationIgnored private var receivedAt: Date?
    @ObservationIgnored private var cache = ArtworkCache()
    /// By kind: the session key named and when the command was sent, until that session's next state.
    @ObservationIgnored private var sent: [AMMediaCommandKind: (sessionKey: String, at: Date)] = [:]
    /// Whether Now Playing shows something, so it is cleared only then.
    @ObservationIgnored private var shown = false
    /// The last remote command's send (internal, for tests).
    @ObservationIgnored var remoteCommand: Task<Void, Never>?
    private static let log = Logger(subsystem: "io.github.anmirror.mac", category: "media")

    public init(center: any NowPlayingCenter,
                send: @escaping @MainActor (MessageType, any SwiftProtobuf.Message & Sendable) async -> Void,
                now: @escaping () -> Date = Date.init) {
        self.center = center
        self.send = send
        self.now = now
        center.onCommand = { [weak self] kind, seconds in self?.remote(kind, seconds: seconds) }
    }

    // MARK: SessionFeature

    public func connected(phoneID: String, phoneName: String, shared: Set<String>) async {
        reset()
        self.phoneID = shared.contains("media.v1") ? phoneID : nil
    }

    public func disconnected() {
        phoneID = nil
        reset()
    }

    public func message(_ envelope: AMEnvelope) async {
        guard phoneID != nil else { return }
        switch MessageType(rawValue: envelope.type) {
        case .mediaState:
            if let s = try? AMMediaState(serializedBytes: envelope.payload) { apply(s) }
        case .mediaArtwork:
            guard let a = try? AMMediaArtwork(serializedBytes: envelope.payload), !a.artworkKey.isEmpty else { return }
            cache.put(a.artworkKey, a.jpeg)
            if let s = state, s.active, s.artworkKey == a.artworkKey {
                setArtwork(a.jpeg)
                showNowPlaying()
            }
        case .mediaAvailability:
            guard let a = try? AMFeatureAvailability(serializedBytes: envelope.payload) else { return }
            phoneAvailability = a
            // Switched off on the phone: no more states come, so what was playing is not shown.
            if !a.enabled { clearState() }
        default:
            break
        }
    }

    public func forget(phoneID: String) async {
        guard self.phoneID == nil || self.phoneID == phoneID else { return }
        self.phoneID = nil
        reset()
    }

    // MARK: media

    /// The position now, extrapolated from the last state; 0 when nothing is playing.
    public func positionMs(now date: Date) -> Int64 {
        guard let s = state, s.active, let receivedAt else { return 0 }
        return PositionClock.positionMs(s, receivedAt: receivedAt, now: date)
    }

    /// Sends a command for the current session. Nothing goes without an active state, or while
    /// the phone reports media control off.
    public func command(_ kind: AMMediaCommandKind, positionMs: Int64 = 0, volume: UInt32 = 0) async {
        guard phoneID != nil, let s = state, s.active, phoneAvailability?.enabled != false else { return }
        var c = AMMediaCommand()
        c.sessionKey = s.sessionKey
        c.kind = kind
        c.positionMs = positionMs
        c.volume = volume
        sent[kind] = (s.sessionKey, now())
        await send(.mediaCommand, c)
    }

    /// A media key, Control Center or headphone command. Never on the ordered queue: it only sends.
    private func remote(_ kind: AMMediaCommandKind, seconds: Double?) {
        let positionMs = seconds.map { Int64(($0 * 1000).rounded()) } ?? 0
        remoteCommand = Task { [weak self] in await self?.command(kind, positionMs: positionMs) }
    }

    private func apply(_ s: AMMediaState) {
        let at = now()
        state = s
        receivedAt = at
        setArtwork(s.active && !s.artworkKey.isEmpty ? cache.get(s.artworkKey) : nil)
        if s.active {
            showNowPlaying()
        } else if shown {
            shown = false
            center.clear()
        }
        reportRoundTrips(sessionKey: s.sessionKey, at: at)
    }

    private func showNowPlaying() {
        guard let s = state, s.active else { return }
        // The position now: artwork may arrive a while after its state.
        let info = NowPlayingInfo(
            title: s.title, artist: s.artist, album: s.album,
            durationSeconds: Double(s.durationMs) / 1000, elapsedSeconds: Double(positionMs(now: now())) / 1000,
            rate: s.playing ? (s.speed > 0 ? Double(s.speed) : 1) : 0, artwork: artwork)
        let commands = RemoteCommands(
            play: s.canPlay, pause: s.canPause, toggle: s.canPlay || s.canPause,
            next: s.canNext, previous: s.canPrevious, seek: s.canSeek)
        shown = true
        center.show(info, playing: s.playing, commands: commands)
    }

    /// Commands sent to `sessionKey` are answered by this state: log and report each once. Any
    /// sent to another session are dropped: that session is no longer the phone's.
    private func reportRoundTrips(sessionKey: String, at: Date) {
        let answered = sent.filter { $0.value.sessionKey == sessionKey }.sorted { $0.key.rawValue < $1.key.rawValue }
        sent = [:]
        for (kind, command) in answered {
            let seconds = max(0, at.timeIntervalSince(command.at))
            let ms = Int64((seconds * 1000).rounded())
            Self.log.info("command \(Self.name(kind), privacy: .public) rtt \(ms, privacy: .public) ms")
            onRoundTrip?(kind, .milliseconds(ms))
        }
    }

    /// Nothing playing: Now Playing cleared, state and artwork gone.
    private func clearState() {
        if shown {
            shown = false
            center.clear()
        }
        state = nil
        setArtwork(nil)
        receivedAt = nil
        sent = [:]
    }

    private func setArtwork(_ jpeg: Data?) {
        guard jpeg != artwork else { return }
        artwork = jpeg
        artworkImage = jpeg.flatMap(NSImage.init(data:))
    }

    private func reset() {
        clearState()
        cache.clear()
        phoneAvailability = nil
    }

    /// The enum name for the log, e.g. `TOGGLE`.
    static func name(_ kind: AMMediaCommandKind) -> String {
        switch kind {
        case .unspecified: "UNSPECIFIED"
        case .play: "PLAY"
        case .pause: "PAUSE"
        case .toggle: "TOGGLE"
        case .next: "NEXT"
        case .previous: "PREVIOUS"
        case .seek: "SEEK"
        case .setVolume: "SET_VOLUME"
        case let .UNRECOGNIZED(n): "UNRECOGNIZED_\(n)"
        }
    }
}
