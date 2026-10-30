import AMProtocol
import AppKit
import Foundation
import SwiftProtobuf
import Testing
@testable import FeatureMedia

/// Records what the model asks of macOS Now Playing.
@MainActor
private final class FakeCenter: NowPlayingCenter {
    var shows: [(info: NowPlayingInfo, playing: Bool, commands: RemoteCommands)] = []
    var clears = 0
    var onCommand: ((AMMediaCommandKind, Double?) -> Void)?

    func show(_ info: NowPlayingInfo, playing: Bool, commands: RemoteCommands) {
        shows.append((info, playing, commands))
    }

    func clear() { clears += 1 }
}

@MainActor
private final class Sent {
    var commands: [AMMediaCommand] = []
    var types: [MessageType] = []
}

/// A clock the test moves by hand.
private final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@MainActor
private func rig() -> (MediaModel, FakeCenter, Sent, TestClock) {
    let center = FakeCenter()
    let sent = Sent()
    let clock = TestClock()
    let model = MediaModel(
        center: center,
        send: { type, message in
            sent.types.append(type)
            if let c = message as? AMMediaCommand { sent.commands.append(c) }
        },
        now: { clock.now })
    return (model, center, sent, clock)
}

private let shared: Set<String> = ["status.v1", "media.v1"]

private func envelope<M: SwiftProtobuf.Message>(_ type: MessageType, _ message: M) -> AMEnvelope {
    var e = AMEnvelope()
    e.channel = .media
    e.type = type.rawValue
    e.payload = (try? message.serializedData()) ?? Data()
    return e
}

private func availability(_ enabled: Bool, _ reason: AMAvailabilityReason = .unspecified) -> AMEnvelope {
    var a = AMFeatureAvailability()
    a.enabled = enabled
    a.reason = reason
    return envelope(.mediaAvailability, a)
}

private func playing(key: String = "s1", artworkKey: String = "", canSeek: Bool = true,
                     playing: Bool = true, speed: Float = 1, positionMs: Int64 = 30_000) -> AMMediaState {
    var s = AMMediaState()
    s.active = true
    s.sessionKey = key
    s.appLabel = "Player"
    s.title = "Song"
    s.artist = "Band"
    s.album = "Record"
    s.durationMs = 200_000
    s.positionMs = positionMs
    s.playing = playing
    s.speed = speed
    s.canPlay = true
    s.canPause = true
    s.canNext = true
    s.canPrevious = false
    s.canSeek = canSeek
    s.artworkKey = artworkKey
    var v = AMMediaVolume()
    v.current = 5
    v.max = 15
    s.volume = v
    return s
}

private func inactive() -> AMMediaState { AMMediaState() }

private func artwork(_ key: String, _ jpeg: Data) -> AMEnvelope {
    var a = AMMediaArtwork()
    a.artworkKey = key
    a.jpeg = jpeg
    return envelope(.mediaArtwork, a)
}

/// Connects a phone that shares media.v1 and reports media control on.
@MainActor
private func connectOn(_ model: MediaModel, phoneID: String = "P1") async {
    await model.connected(phoneID: phoneID, phoneName: "Pixel", shared: shared)
    await model.message(availability(true))
}

@MainActor @Test func activeStateShowsNowPlaying() async {
    let (model, center, _, _) = rig()
    await connectOn(model)
    await model.message(envelope(.mediaState, playing(speed: 1.5)))
    #expect(model.state?.title == "Song")
    #expect(center.shows.count == 1)
    let shown = center.shows.last
    #expect(shown?.info == NowPlayingInfo(title: "Song", artist: "Band", album: "Record", durationSeconds: 200,
                                         elapsedSeconds: 30, rate: 1.5, artwork: nil))
    #expect(shown?.playing == true)
    #expect(shown?.commands == RemoteCommands(play: true, pause: true, toggle: true, next: true,
                                              previous: false, seek: true))
    // Paused: the rate is 0, whatever the speed.
    await model.message(envelope(.mediaState, playing(playing: false, speed: 1.5)))
    #expect(center.shows.last?.info.rate == 0)
    #expect(center.shows.last?.playing == false)
    // Playing at speed 0 counts as 1.
    await model.message(envelope(.mediaState, playing(speed: 0)))
    #expect(center.shows.last?.info.rate == 1)
}

@MainActor @Test func inactiveClearsNowPlaying() async {
    let (model, center, _, _) = rig()
    await connectOn(model)
    await model.message(envelope(.mediaState, playing()))
    await model.message(envelope(.mediaState, inactive()))
    #expect(center.clears == 1)
    #expect(center.shows.count == 1)
    #expect(model.state?.active == false)
    #expect(model.positionMs(now: Date()) == 0)
}

@MainActor @Test func disconnectClearsNowPlaying() async {
    let (model, center, sent, _) = rig()
    await connectOn(model)
    await model.message(artwork("k1", Data("jpeg".utf8)))
    await model.message(envelope(.mediaState, playing(artworkKey: "k1")))
    #expect(model.artwork == Data("jpeg".utf8))
    model.disconnected()
    #expect(center.clears == 1)
    #expect(model.state == nil)
    #expect(model.artwork == nil)
    #expect(model.phoneAvailability == nil)
    // The cache went too: the same key after reconnecting has no artwork until it is sent again.
    await connectOn(model)
    await model.message(envelope(.mediaState, playing(artworkKey: "k1")))
    #expect(model.artwork == nil)
    // And nothing goes for a session that is over.
    model.disconnected()
    await model.command(.toggle)
    #expect(sent.commands.isEmpty)
}

@MainActor @Test func forgetClearsNowPlaying() async {
    let (model, center, _, _) = rig()
    await connectOn(model)
    await model.message(envelope(.mediaState, playing()))
    // Another phone forgotten leaves this session alone.
    await model.forget(phoneID: "P2")
    #expect(center.clears == 0)
    #expect(model.state != nil)
    await model.forget(phoneID: "P1")
    #expect(center.clears == 1)
    #expect(model.state == nil)
    #expect(model.phoneAvailability == nil)
}

@MainActor @Test func seekDisabledWithoutSeekAction() async {
    let (model, center, _, _) = rig()
    await connectOn(model)
    await model.message(envelope(.mediaState, playing(canSeek: false)))
    #expect(center.shows.last?.commands.seek == false)
    #expect(center.shows.last?.commands.play == true)
}

@MainActor @Test func artworkArrivingAfterStateUpdatesNowPlaying() async {
    let (model, center, _, clock) = rig()
    await connectOn(model)
    await model.message(envelope(.mediaState, playing(artworkKey: "k1")))
    #expect(model.artwork == nil)
    #expect(center.shows.last?.info.artwork == nil)
    // Another key's artwork is cached but changes nothing shown.
    await model.message(artwork("k2", Data("other".utf8)))
    #expect(model.artwork == nil)
    #expect(center.shows.count == 1)
    // Two seconds into the track: shown again at the position now, not the one the state was sent at.
    clock.advance(2)
    await model.message(artwork("k1", Data("jpeg".utf8)))
    #expect(model.artwork == Data("jpeg".utf8))
    #expect(center.shows.count == 2)
    #expect(center.shows.last?.info.artwork == Data("jpeg".utf8))
    #expect(center.shows.last?.info.elapsedSeconds == 32)
    // A later state naming the cached key has it at once.
    await model.message(envelope(.mediaState, playing(artworkKey: "k2")))
    #expect(model.artwork == Data("other".utf8))
    // No key: no artwork.
    await model.message(envelope(.mediaState, playing()))
    #expect(model.artwork == nil)
}

@MainActor @Test func commandUsesCurrentSessionKey() async {
    let (model, _, sent, _) = rig()
    await connectOn(model)
    await model.message(envelope(.mediaState, playing(key: "s1")))
    await model.command(.pause)
    await model.message(envelope(.mediaState, playing(key: "s2")))
    await model.command(.seek, positionMs: 12_345)
    await model.command(.setVolume, volume: 7)
    #expect(sent.types == [.mediaCommand, .mediaCommand, .mediaCommand])
    #expect(sent.commands.map(\.sessionKey) == ["s1", "s2", "s2"])
    #expect(sent.commands.map(\.kind) == [.pause, .seek, .setVolume])
    #expect(sent.commands[1].positionMs == 12_345)
    #expect(sent.commands[2].volume == 7)
}

@MainActor @Test func commandWithoutActiveStateSendsNothing() async {
    let (model, _, sent, _) = rig()
    await connectOn(model)
    await model.command(.play)
    await model.message(envelope(.mediaState, inactive()))
    await model.command(.play)
    #expect(sent.commands.isEmpty)
    // A phone that does not share media.v1 gets nothing, whatever it sends.
    await model.connected(phoneID: "P1", phoneName: "Pixel", shared: ["status.v1"])
    await model.message(availability(true))
    await model.message(envelope(.mediaState, playing()))
    #expect(model.state == nil)
    await model.command(.play)
    #expect(sent.commands.isEmpty)
}

@MainActor @Test func commandWithAvailabilityOffSendsNothing() async {
    let (model, center, sent, _) = rig()
    await connectOn(model)
    await model.message(envelope(.mediaState, playing()))
    await model.message(availability(false, .offByUser))
    #expect(model.phoneAvailability?.reason == .offByUser)
    await model.command(.toggle)
    #expect(sent.commands.isEmpty)
    // Switched off: what was playing is no longer shown.
    #expect(center.clears == 1)
    #expect(model.state == nil)
    // Back on, the phone's next state is shown and commands go again.
    await model.message(availability(true))
    await model.message(envelope(.mediaState, playing()))
    await model.command(.toggle)
    #expect(sent.commands.map(\.kind) == [.toggle])
}

@MainActor @Test func commandBeforeAnyAvailabilityGoes() async {
    // R27: commands are user-triggered, so a phone that has not reported availability yet gets them.
    let (model, _, sent, _) = rig()
    await model.connected(phoneID: "P1", phoneName: "Pixel", shared: shared)
    await model.message(envelope(.mediaState, playing()))
    #expect(model.phoneAvailability == nil)
    await model.command(.toggle)
    #expect(sent.commands.map(\.kind) == [.toggle])
}

@MainActor @Test func artworkImageIsDecodedAndGoesWithTheSession() async {
    let (model, _, _, _) = rig()
    let jpeg = testJPEG()
    await connectOn(model)
    await model.message(artwork("k1", jpeg))
    await model.message(envelope(.mediaState, playing(artworkKey: "k1")))
    #expect(model.artworkImage != nil)
    // Bytes that are no image: none.
    await model.message(artwork("bad", Data("jpeg".utf8)))
    await model.message(envelope(.mediaState, playing(artworkKey: "bad")))
    #expect(model.artwork != nil)
    #expect(model.artworkImage == nil)
    await model.message(envelope(.mediaState, playing(artworkKey: "k1")))
    #expect(model.artworkImage != nil)
    model.disconnected()
    #expect(model.artworkImage == nil)
}

@MainActor @Test func remoteToggleSendsToggle() async {
    let (model, center, sent, _) = rig()
    await connectOn(model)
    await model.message(envelope(.mediaState, playing()))
    center.onCommand?(.toggle, nil)
    await model.remoteCommand?.value
    #expect(sent.commands.map(\.kind) == [.toggle])
    #expect(sent.commands.first?.sessionKey == "s1")
    // A scrub in Control Center is a seek, in milliseconds.
    center.onCommand?(.seek, 42.5)
    await model.remoteCommand?.value
    #expect(sent.commands.map(\.kind) == [.toggle, .seek])
    #expect(sent.commands.last?.positionMs == 42_500)
}

@MainActor @Test func roundTripIsMeasuredToNextState() async {
    let (model, _, _, clock) = rig()
    var trips: [(AMMediaCommandKind, Duration)] = []
    model.onRoundTrip = { trips.append(($0, $1)) }
    await connectOn(model)
    await model.message(envelope(.mediaState, playing(key: "s1")))
    #expect(trips.isEmpty)
    await model.command(.toggle)
    clock.advance(0.040)
    // Another session's state is not the answer, and the command is never answered after it.
    await model.message(envelope(.mediaState, playing(key: "other")))
    #expect(trips.isEmpty)
    await model.message(envelope(.mediaState, playing(key: "s1")))
    #expect(trips.isEmpty)
    await model.command(.toggle)
    clock.advance(0.120)
    await model.message(envelope(.mediaState, playing(key: "s1", playing: false)))
    #expect(trips.count == 1)
    #expect(trips.first?.0 == .toggle)
    #expect(trips.first?.1 == .milliseconds(120))
    // Reported once: the next state is not another round trip.
    clock.advance(1)
    await model.message(envelope(.mediaState, playing(key: "s1")))
    #expect(trips.count == 1)
}

@MainActor @Test func commandSentFromRoundTripIsMeasuredToTheStateAfter() async {
    // What am-mac-sim --media-toggle does: a second TOGGLE once the first one's state is back.
    let (model, _, sent, clock) = rig()
    var trips: [Duration] = []
    model.onRoundTrip = { _, rtt in
        trips.append(rtt)
        if trips.count == 1 { Task { await model.command(.toggle) } }
    }
    await connectOn(model)
    await model.message(envelope(.mediaState, playing(playing: false)))
    await model.command(.toggle)
    clock.advance(0.010)
    await model.message(envelope(.mediaState, playing(playing: true)))
    #expect(trips == [.milliseconds(10)])
    let secondSent = await waitFor { sent.commands.count == 2 }
    #expect(secondSent)
    clock.advance(0.025)
    await model.message(envelope(.mediaState, playing(playing: false)))
    #expect(trips == [.milliseconds(10), .milliseconds(25)])
}

@MainActor @Test func positionFollowsTheClock() async {
    let (model, _, _, clock) = rig()
    await connectOn(model)
    #expect(model.positionMs(now: clock.now) == 0)
    await model.message(envelope(.mediaState, playing(positionMs: 10_000)))
    #expect(model.positionMs(now: clock.now.addingTimeInterval(2)) == 12_000)
}

private func testJPEG() -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                               samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .jpeg, properties: [:])!
}

@MainActor
private func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}
