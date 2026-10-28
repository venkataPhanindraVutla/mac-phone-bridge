import AMProtocol
import Foundation
import Network

/// Publishes the listener as `_anmirror._tcp` with no personal data (SPEC sections 1 and 6):
/// a random instance name `am-<8 hex>`, and TXT `v=1`, `r=<rotating ID>`. Both change at every
/// 15-minute epoch boundary, and the name also changes on wake, so the name cannot be used to
/// follow the Mac over time. Phones find their Mac by TXT `r`, never by the name.
@MainActor
public final class BonjourAdvertiser {
    public nonisolated static let serviceType = "_anmirror._tcp"
    public nonisolated static let epochSeconds: Double = 900

    private let discoveryKey: Data
    private let clock: () -> Date
    private weak var listener: NWListener?
    private var republish: Task<Void, Never>?
    private var instanceName = BonjourAdvertiser.randomInstanceName()
    /// The epoch `instanceName` was made for; nil forces a new name at the next publish.
    private var nameEpoch: Int64?

    public init(discoveryKey: Data, clock: @escaping () -> Date = Date.init) {
        self.discoveryKey = discoveryKey
        self.clock = clock
    }

    /// `am-` and 8 random lowercase hex digits.
    public nonisolated static func randomInstanceName() -> String {
        "am-" + PairingCrypto.randomBytes(4).map { String(format: "%02x", $0) }.joined()
    }

    public nonisolated static func txt(discoveryKey: Data, unixSeconds: Int64) -> [String: String] {
        ["v": "1", "r": PairingCrypto.rotatingID(discoveryKey: discoveryKey, unixSeconds: unixSeconds)]
    }

    /// Time from `unixSeconds` to the start of the next epoch (a full epoch on a boundary).
    public nonisolated static func secondsUntilNextEpoch(unixSeconds: Double) -> Double {
        let into = unixSeconds.truncatingRemainder(dividingBy: epochSeconds)
        return epochSeconds - (into < 0 ? into + epochSeconds : into)
    }

    /// Sets the listener's service (call before or after `start`) and keeps TXT `r` current.
    public func attach(to listener: NWListener) {
        self.listener = listener
        publish()
        republish?.cancel()
        republish = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = Self.secondsUntilNextEpoch(unixSeconds: self.clock().timeIntervalSince1970) + 0.5
                do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                self.publish()
            }
        }
    }

    /// The name to publish now: a fresh random one once the epoch has changed.
    func currentInstanceName() -> String {
        let epoch = Int64((clock().timeIntervalSince1970 / Self.epochSeconds).rounded(.down))
        if nameEpoch != epoch {
            if nameEpoch != nil { instanceName = Self.randomInstanceName() }
            nameEpoch = epoch
        }
        return instanceName
    }

    /// A new random name from the next publish on (after wake from sleep).
    public func rotateInstanceName() {
        instanceName = Self.randomInstanceName()
        nameEpoch = nil
    }

    public func stop() {
        republish?.cancel()
        republish = nil
        listener = nil
    }

    private func publish() {
        guard let listener else { return }
        let now = Int64(clock().timeIntervalSince1970.rounded(.down))
        let record = NWTXTRecord(Self.txt(discoveryKey: discoveryKey, unixSeconds: now))
        listener.service = NWListener.Service(name: currentInstanceName(), type: Self.serviceType,
                                              domain: nil, txtRecord: record)
    }
}
