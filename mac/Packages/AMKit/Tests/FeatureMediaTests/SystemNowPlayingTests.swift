import AMProtocol
import AppKit
import Foundation
import MediaPlayer
import Testing
@testable import FeatureMedia

private func testImage() -> NSImage {
    NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
        NSColor.red.setFill()
        rect.fill()
        return true
    }
}

/// Runs `work` on a background queue, as MediaPlayer does with artwork requests and remote commands.
private func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: work()) }
    }
}

@MainActor @Test func artworkImageCanBeRequestedOffTheMainThread() async {
    nonisolated(unsafe) let artwork = SystemNowPlaying.makeArtwork(testImage())
    let size = await offMain { artwork.image(at: CGSize(width: 4, height: 4))?.size }
    #expect(size == CGSize(width: 4, height: 4))
}

@MainActor @Test func remoteCommandHandlersRunOffTheMainThread() async {
    let center = SystemNowPlaying()
    var got: [(kind: AMMediaCommandKind, seconds: Double?)] = []
    center.onCommand = { got.append(($0, $1)) }
    nonisolated(unsafe) let toggle = SystemNowPlaying.remoteHandler(.toggle, forward: center.forwarder())
    nonisolated(unsafe) let seek = SystemNowPlaying.remoteHandler(.seek, forward: center.forwarder())
    // MediaPlayer events can't be made outside MediaPlayer ("cannot be initialized externally").
    // A plain object stands in: the play/pause/next handlers never look at the event, and the
    // seek handler's cast to MPChangePlaybackPositionCommandEvent fails on it.
    let statuses = await offMain {
        let event = unsafeBitCast(NSObject(), to: MPRemoteCommandEvent.self)
        return [toggle(event), seek(event)]
    }
    #expect(statuses == [.success, .commandFailed])
    // Forwarded to the main actor.
    let deadline = ContinuousClock.now + .seconds(30)
    while got.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
    #expect(got.count == 1)
    #expect(got.first?.kind == .toggle)
    #expect(got.first?.seconds == nil)
}
