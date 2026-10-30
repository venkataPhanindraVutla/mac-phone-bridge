import AMProtocol
import AppKit
import Foundation
import MediaPlayer

/// What macOS Now Playing shows for the phone's track.
public struct NowPlayingInfo: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var durationSeconds: Double
    /// The position when the state was sent; macOS moves it on at `rate`.
    public var elapsedSeconds: Double
    /// 0 while paused.
    public var rate: Double
    /// JPEG bytes.
    public var artwork: Data?

    public init(title: String, artist: String, album: String, durationSeconds: Double, elapsedSeconds: Double,
                rate: Double, artwork: Data?) {
        self.title = title
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
        self.elapsedSeconds = elapsedSeconds
        self.rate = rate
        self.artwork = artwork
    }
}

/// Which remote commands (media keys, Control Center, headphones) are enabled.
public struct RemoteCommands: Equatable, Sendable {
    public var play, pause, toggle, next, previous, seek: Bool

    public init(play: Bool, pause: Bool, toggle: Bool, next: Bool, previous: Bool, seek: Bool) {
        self.play = play
        self.pause = pause
        self.toggle = toggle
        self.next = next
        self.previous = previous
        self.seek = seek
    }
}

/// macOS Now Playing and its remote commands, behind a protocol so the model can be tested.
@MainActor
public protocol NowPlayingCenter: AnyObject {
    func show(_ info: NowPlayingInfo, playing: Bool, commands: RemoteCommands)
    /// Nothing playing: no info, state stopped, and the command handlers removed.
    func clear()
    /// A remote command; the seconds are the position asked for by a scrub (`SEEK`), else nil.
    var onCommand: ((AMMediaCommandKind, Double?) -> Void)? { get set }
}

/// The real one: `MPNowPlayingInfoCenter.default()` and `MPRemoteCommandCenter.shared()`.
/// Handlers are added at the first `show` and removed by `clear`, so while nothing is playing on
/// the phone the media keys go to other apps.
///
/// MediaPlayer calls the artwork request and the command handlers on threads of its own. Those
/// closures are made in `nonisolated` helpers: a closure formed in this main-actor class would be
/// main-actor isolated, and Swift 6 traps when it runs anywhere else.
@MainActor
public final class SystemNowPlaying: NowPlayingCenter {
    public var onCommand: ((AMMediaCommandKind, Double?) -> Void)?

    /// The command and its target token, for removing them.
    private var targets: [(command: MPRemoteCommand, token: Any)] = []
    /// The last artwork made, so the same JPEG is not decoded at every state.
    private var artworkMemo: (jpeg: Data, artwork: MPMediaItemArtwork)?

    public init() {}

    public func show(_ info: NowPlayingInfo, playing: Bool, commands: RemoteCommands) {
        let remote = MPRemoteCommandCenter.shared()
        if targets.isEmpty { addTargets(remote) }
        remote.playCommand.isEnabled = commands.play
        remote.pauseCommand.isEnabled = commands.pause
        remote.togglePlayPauseCommand.isEnabled = commands.toggle
        remote.nextTrackCommand.isEnabled = commands.next
        remote.previousTrackCommand.isEnabled = commands.previous
        remote.changePlaybackPositionCommand.isEnabled = commands.seek

        var values: [String: Any] = [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyArtist: info.artist,
            MPMediaItemPropertyAlbumTitle: info.album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: info.elapsedSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: info.rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if info.durationSeconds > 0 {
            values[MPMediaItemPropertyPlaybackDuration] = info.durationSeconds
        } else {
            // Duration 0: unknown or live (SPEC section 20).
            values[MPNowPlayingInfoPropertyIsLiveStream] = true
        }
        if let artwork = artwork(info.artwork) { values[MPMediaItemPropertyArtwork] = artwork }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = values
        center.playbackState = playing ? .playing : .paused
    }

    public func clear() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        let remote = MPRemoteCommandCenter.shared()
        for command in Self.commands(remote) { command.isEnabled = false }
        for target in targets { target.command.removeTarget(target.token) }
        targets = []
        artworkMemo = nil
    }

    private static func commands(_ remote: MPRemoteCommandCenter) -> [MPRemoteCommand] {
        [remote.playCommand, remote.pauseCommand, remote.togglePlayPauseCommand, remote.nextTrackCommand,
         remote.previousTrackCommand, remote.changePlaybackPositionCommand]
    }

    private func addTargets(_ remote: MPRemoteCommandCenter) {
        let kinds: [(MPRemoteCommand, AMMediaCommandKind)] = [
            (remote.playCommand, .play), (remote.pauseCommand, .pause), (remote.togglePlayPauseCommand, .toggle),
            (remote.nextTrackCommand, .next), (remote.previousTrackCommand, .previous),
            (remote.changePlaybackPositionCommand, .seek),
        ]
        let forward = forwarder()
        for (command, kind) in kinds {
            let token = command.addTarget(handler: Self.remoteHandler(kind, forward: forward))
            targets.append((command, token))
        }
    }

    /// A command handler, safe on any thread: `.seek` takes the position from the event.
    nonisolated static func remoteHandler(
        _ kind: AMMediaCommandKind, forward: @escaping @Sendable (AMMediaCommandKind, Double?) -> Void
    ) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { event in
            if kind == .seek {
                guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
                forward(.seek, event.positionTime)
            } else {
                forward(kind, nil)
            }
            return .success
        }
    }

    /// Hands a command from any thread to `onCommand` on the main actor.
    func forwarder() -> @Sendable (AMMediaCommandKind, Double?) -> Void {
        { [weak self] kind, seconds in Task { @MainActor in self?.onCommand?(kind, seconds) } }
    }

    /// Artwork whose image MediaPlayer may ask for on any thread.
    nonisolated static func makeArtwork(_ image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func artwork(_ jpeg: Data?) -> MPMediaItemArtwork? {
        guard let jpeg else { return nil }
        if let memo = artworkMemo, memo.jpeg == jpeg { return memo.artwork }
        guard let image = NSImage(data: jpeg) else { return nil }
        let artwork = Self.makeArtwork(image)
        artworkMemo = (jpeg, artwork)
        return artwork
    }
}
