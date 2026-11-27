import AMProtocol
import ConnectionCore
import Foundation
import Observation
import os
import SwiftProtobuf

/// A phone hotspot the Mac can join (SPEC 25). The passphrase is never logged.
public struct HotspotNetwork: Codable, Equatable, Sendable {
    public let ssid: String
    public let passphrase: String
    /// `AMHotspotSecurity` raw value.
    public let security: Int

    public init(ssid: String, passphrase: String, security: Int) {
        self.ssid = ssid
        self.passphrase = passphrase
        self.security = security
    }
}

/// Joins a Wi-Fi network (CoreWLAN in the app; a fake in tests).
public protocol WiFiJoining: Sendable {
    func join(_ network: HotspotNetwork) async throws
}

/// One-click hotspot (`hotspot.v1`, SPEC 25). While a phone that shares it is connected,
/// `useHotspot()` asks it to turn its hotspot on, keeps the network it answers with (per phone,
/// through `store`), and joins it. With no phone connected, `joinSaved(phoneID:)` joins the
/// network kept from before (the user turned the hotspot on at the phone). `turnOff()` asks the
/// connected phone to turn it off.
///
/// Joining moves the Mac to the phone's network, so the session usually drops and comes back:
/// `phase` survives that.
@MainActor
@Observable
public final class HotspotModel: SessionFeature {
    public let messagePrefixes = ["hotspot."]
    public static let capability = "hotspot.v1"
    /// How long a request waits for the phone's `hotspot.state`.
    static let answerTimeout: Duration = .seconds(40)

    public enum Problem: Equatable, Sendable {
        /// Full mode is not ready on the phone.
        case needsSetup
        /// The phone would not turn it on (its maker, no mobile data, a policy).
        case refused
        /// The phone did not answer, or something else failed there.
        case failed
        /// The hotspot is on, but this Mac could not join it.
        case joinFailed
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case turningOn
        case joining
        case joined(ssid: String)
        case turningOff
        case failed(Problem)

        public var isBusy: Bool { self == .turningOn || self == .joining || self == .turningOff }
    }

    public private(set) var phase: Phase = .idle
    /// The phone's last `hotspot.availability`; nil until the first one of this connection.
    public private(set) var phoneAvailability: AMFeatureAvailability?
    /// The phone in session, while it shares `hotspot.v1`.
    public private(set) var phoneID: String?

    @ObservationIgnored private let send: @MainActor (MessageType, any SwiftProtobuf.Message & Sendable) async -> Void
    @ObservationIgnored private let joiner: any WiFiJoining
    @ObservationIgnored private let load: (String) -> HotspotNetwork?
    @ObservationIgnored private let store: (String, HotspotNetwork?) -> Void
    @ObservationIgnored private var waiting: CheckedContinuation<AMHotspotState?, Never>?
    @ObservationIgnored var answerTimeout: Duration = HotspotModel.answerTimeout
    private static let log = Logger(subsystem: "io.github.anmirror.mac", category: "hotspot")

    public init(send: @escaping @MainActor (MessageType, any SwiftProtobuf.Message & Sendable) async -> Void,
                joiner: any WiFiJoining,
                load: @escaping (String) -> HotspotNetwork?, store: @escaping (String, HotspotNetwork?) -> Void) {
        self.send = send
        self.joiner = joiner
        self.load = load
        self.store = store
    }

    // MARK: SessionFeature

    public func connected(phoneID: String, phoneName: String, shared: Set<String>) async {
        self.phoneID = shared.contains(Self.capability) ? phoneID : nil
        phoneAvailability = nil
    }

    public func disconnected() {
        phoneID = nil
        phoneAvailability = nil
        answer(nil)
    }

    public func message(_ envelope: AMEnvelope) async {
        guard phoneID != nil else { return }
        switch MessageType(rawValue: envelope.type) {
        case .hotspotAvailability:
            phoneAvailability = try? AMFeatureAvailability(serializedBytes: envelope.payload)
        case .hotspotState:
            answer(try? AMHotspotState(serializedBytes: envelope.payload))
        default:
            break
        }
    }

    public func forget(phoneID: String) async {
        store(phoneID, nil)
    }

    // MARK: actions

    /// The connected phone can turn its hotspot on now.
    public var canUseHotspot: Bool { phoneID != nil && phoneAvailability?.enabled == true && !phase.isBusy }

    /// The network kept for `phoneID`, if any.
    public func savedNetwork(for phoneID: String) -> HotspotNetwork? { load(phoneID) }

    /// Asks the connected phone to turn its hotspot on, then joins it.
    public func useHotspot() async {
        guard let phoneID, canUseHotspot else { return }
        phase = .turningOn
        var request = AMHotspotRequest()
        request.on = true
        guard let state = await ask(request) else {
            phase = .failed(.failed)
            return
        }
        guard state.on, !state.ssid.isEmpty else {
            phase = .failed(Self.problem(state.failure))
            return
        }
        let network = HotspotNetwork(ssid: state.ssid, passphrase: state.passphrase, security: state.security.rawValue)
        store(phoneID, network)
        await join(network)
    }

    /// Joins the hotspot kept for `phoneID` (the phone is not connected; its hotspot is on).
    public func joinSaved(phoneID: String) async {
        guard !phase.isBusy, let network = load(phoneID) else { return }
        await join(network)
    }

    /// Asks the connected phone to turn its hotspot off.
    public func turnOff() async {
        guard phoneID != nil, !phase.isBusy else { return }
        phase = .turningOff
        var request = AMHotspotRequest()
        request.on = false
        // The answer may never come: turning it off can cut this very connection.
        _ = await ask(request)
        phase = .idle
    }

    // MARK: helpers

    private func join(_ network: HotspotNetwork) async {
        phase = .joining
        do {
            try await joiner.join(network)
            phase = .joined(ssid: network.ssid)
        } catch {
            Self.log.error("join failed: \(String(describing: type(of: error)), privacy: .public)")
            phase = .failed(.joinFailed)
        }
    }

    /// Sends `request` and waits for the phone's `hotspot.state`; nil on timeout or disconnect.
    private func ask(_ request: AMHotspotRequest) async -> AMHotspotState? {
        answer(nil) // one request at a time
        let timeout = answerTimeout
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.answer(nil)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            waiting = continuation
            Task { await send(.hotspotRequest, request) }
        }
    }

    private func answer(_ state: AMHotspotState?) {
        let w = waiting
        waiting = nil
        w?.resume(returning: state)
    }

    static func problem(_ f: AMHotspotFailure) -> Problem {
        switch f {
        case .needsSetup: .needsSetup
        case .refused: .refused
        default: .failed
        }
    }
}
