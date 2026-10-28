import AMProtocol
import Observation

/// What the phone last told us. `signalLevel` is 0...4, or -1 for no SIM / no service.
public struct PhoneStatus: Equatable, Sendable {
    public var batteryPercent: Int
    public var charging: Bool
    public var signalLevel: Int
    public var network: AMNetworkKind

    public init(batteryPercent: Int, charging: Bool, signalLevel: Int, network: AMNetworkKind) {
        self.batteryPercent = batteryPercent
        self.charging = charging
        self.signalLevel = signalLevel
        self.network = network
    }
}

/// Latest phone status; nil while no phone is connected (call `reset()` on disconnect).
@MainActor
@Observable
public final class PhoneStatusModel {
    public private(set) var status: PhoneStatus?

    public init() {}

    public func apply(_ update: AMStatusUpdate) {
        status = PhoneStatus(
            batteryPercent: min(max(Int(update.batteryPercent), 0), 100),
            charging: update.charging,
            signalLevel: min(max(Int(update.signalLevel), -1), 4),
            network: update.network
        )
    }

    public func reset() { status = nil }
}
