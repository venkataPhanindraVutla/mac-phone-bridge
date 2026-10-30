import AMProtocol
import CoreBluetooth
import Foundation

public enum ScannerState: Equatable, Sendable { case unknown, poweredOff, unauthorized, unsupported, poweredOn }

/// Hears the phones' proximity beacons.
@MainActor
public protocol BeaconScanner: AnyObject {
    var state: ScannerState { get }
    var onState: ((ScannerState) -> Void)? { get set }
    /// The 8 bytes of service data under the proximity UUID, and the RSSI.
    var onBeacon: ((Data, Int) -> Void)? { get set }
    /// Scans while Bluetooth is on. The first call creates the system scanner, which is when macOS
    /// asks for Bluetooth access, so it is called only once the auto-lock setting is on.
    func start()
    func stop()
}

/// Scans with CoreBluetooth for the phone's advertisement (SPEC section 22): a legacy advertisement
/// whose only element is service data under the proximity UUID, with no service-UUID list. So it
/// scans for every peripheral, with duplicates (one RSSI sample per advertisement), and keeps only
/// the sightings that carry exactly 8 bytes of service data under that UUID.
///
/// The manager runs on a queue of its own. Its delegate is not main-actor isolated (CoreBluetooth
/// calls it on that queue, and Swift 6 traps on an isolated entry point there); it hands each
/// result to the main queue, in order.
@MainActor
public final class CoreBluetoothScanner: BeaconScanner {
    public private(set) var state: ScannerState
    public var onState: ((ScannerState) -> Void)?
    public var onBeacon: ((Data, Int) -> Void)?

    /// Internal, for tests: the delegate the manager is given.
    let delegate: BeaconScannerDelegate
    /// Internal, for tests: whether `start()` is in effect.
    var wantsScan = false
    private var manager: CBCentralManager?
    private let queue = DispatchQueue(label: "io.github.anmirror.mac.proximity.ble")

    public init() {
        // Reading the class property asks nothing; only creating a manager does.
        state = BeaconScannerDelegate.blocked(CBManager.authorization) ? .unauthorized : .unknown
        delegate = BeaconScannerDelegate()
        delegate.forward = Self.forwarder(to: self)
    }

    public func start() {
        wantsScan = true
        if let manager {
            if state == .poweredOn { scan(manager) }
            return
        }
        // No "turn on Bluetooth" alert from macOS: Settings says it.
        manager = CBCentralManager(delegate: delegate, queue: queue,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    public func stop() {
        wantsScan = false
        if let manager, state == .poweredOn { manager.stopScan() }
    }

    private func scan(_ manager: CBCentralManager) {
        manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    fileprivate func received(_ event: BeaconScannerDelegate.Event) {
        switch event {
        case let .state(new):
            state = new
            if new == .poweredOn, wantsScan, let manager { scan(manager) }
            onState?(new)
        case let .beacon(data, rssi):
            guard wantsScan else { return }
            onBeacon?(data, rssi)
        }
    }

    /// Made outside the main actor, so the closure isn't isolated to it: it runs on CoreBluetooth's
    /// queue and hops to the main queue itself.
    nonisolated private static func forwarder(
        to scanner: CoreBluetoothScanner
    ) -> @Sendable (BeaconScannerDelegate.Event) -> Void {
        { [weak scanner] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { scanner?.received(event) }
            }
        }
    }
}

/// CoreBluetooth's delegate for `CoreBluetoothScanner`; safe on any thread.
final class BeaconScannerDelegate: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case state(ScannerState)
        case beacon(Data, Int)
    }

    private static var serviceUUID: CBUUID { CBUUID(string: PairingCrypto.bleServiceUUID) }

    /// Set once, before the manager exists.
    var forward: (@Sendable (Event) -> Void)?

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        deliver(state: central.state, authorization: CBManager.authorization)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        deliver(advertisementData: advertisementData, rssi: RSSI.intValue)
    }

    // MARK: internal, for tests

    func deliver(state: CBManagerState, authorization: CBManagerAuthorization) {
        forward?(.state(Self.map(state, authorization: authorization)))
    }

    func deliver(advertisementData: [String: Any], rssi: Int) {
        // 127: CoreBluetooth has no RSSI for this sighting.
        guard rssi != 127, let data = Self.serviceData(advertisementData) else { return }
        forward?(.beacon(data, rssi))
    }

    static func serviceData(_ advertisementData: [String: Any]) -> Data? {
        guard let byUUID = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
              let data = byUUID[serviceUUID], data.count == 8 else { return nil }
        return Data(data)
    }

    /// Denied or restricted access reads as unauthorized whatever the manager's state says (the
    /// ad-hoc build may differ from a signed one here).
    static func map(_ state: CBManagerState, authorization: CBManagerAuthorization) -> ScannerState {
        if blocked(authorization) { return .unauthorized }
        switch state {
        case .poweredOn: return .poweredOn
        case .poweredOff: return .poweredOff
        case .unauthorized: return .unauthorized
        case .unsupported: return .unsupported
        case .unknown, .resetting: return .unknown
        @unknown default: return .unknown
        }
    }

    static func blocked(_ authorization: CBManagerAuthorization) -> Bool {
        authorization == .denied || authorization == .restricted
    }
}
