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
    /// Some advertisement, from any device, was seen: the scan is alive. At most once a second.
    var onHeartbeat: (() -> Void)? { get set }
    /// Scans while Bluetooth is on. The first call creates the system scanner, which is when macOS
    /// asks for Bluetooth access, so it is called only once the auto-lock setting is on.
    func start()
    func stop()
    /// Stops and starts the scan again, when it seems stalled.
    func rescan()
}

/// Scans with CoreBluetooth for the phone's advertisement (SPEC section 22): a legacy advertisement
/// whose only element is service data under the proximity UUID, with no service-UUID list. So it
/// scans for every peripheral, with duplicates (one RSSI sample per advertisement), and keeps only
/// the sightings that carry exactly 8 bytes of service data under that UUID. Every other sighting
/// only feeds the heartbeat.
///
/// The manager runs on a queue of its own, and is only driven there. Its delegate is not main-actor
/// isolated (CoreBluetooth calls it on that queue, and Swift 6 traps on an isolated entry point
/// there); it hands each result to the main queue, in order.
///
/// While scanning it holds a `ProcessInfo` activity, so App Nap can't throttle the scan.
@MainActor
public final class CoreBluetoothScanner: BeaconScanner {
    public private(set) var state: ScannerState
    public var onState: ((ScannerState) -> Void)?
    public var onBeacon: ((Data, Int) -> Void)?
    public var onHeartbeat: (() -> Void)?

    /// Internal, for tests: the delegate the manager is given.
    let delegate: BeaconScannerDelegate
    /// Internal, for tests: whether `start()` is in effect.
    var wantsScan = false
    private var driver: ScanDriver?
    private var activity: NSObjectProtocol?

    public init() {
        // Reading the class property asks nothing; only creating a manager does.
        state = BeaconScannerDelegate.blocked(CBManager.authorization) ? .unauthorized : .unknown
        delegate = BeaconScannerDelegate()
        delegate.forward = Self.forwarder(to: self)
    }

    public func start() {
        wantsScan = true
        holdActivity(true)
        if let driver {
            if state == .poweredOn { driver.scan() }
            return
        }
        driver = ScanDriver(delegate: delegate)
    }

    public func stop() {
        wantsScan = false
        holdActivity(false)
        driver?.stop()
    }

    public func rescan() {
        guard wantsScan, state == .poweredOn else { return }
        driver?.rescan()
    }

    /// Internal, for tests: whether the App Nap activity is held.
    var holdsActivity: Bool { activity != nil }

    func holdActivity(_ on: Bool) {
        if on, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Auto-Lock listens for the phone's Bluetooth signal")
        } else if !on, let held = activity {
            ProcessInfo.processInfo.endActivity(held)
            activity = nil
        }
    }

    fileprivate func received(_ event: BeaconScannerDelegate.Event) {
        switch event {
        case let .state(new):
            state = new
            if new == .poweredOn, wantsScan { driver?.scan() }
            onState?(new)
        case let .beacon(data, rssi):
            guard wantsScan else { return }
            onBeacon?(data, rssi)
        case .heartbeat:
            guard wantsScan else { return }
            onHeartbeat?()
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

/// Owns the manager and drives it only on its own queue.
private final class ScanDriver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.anmirror.mac.proximity.ble")
    /// Touched only on `queue` after init.
    private let manager: CBCentralManager

    init(delegate: BeaconScannerDelegate) {
        // No "turn on Bluetooth" alert from macOS: Settings says it.
        manager = CBCentralManager(delegate: delegate, queue: queue,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func scan() {
        queue.async { [self] in startScan() }
    }

    func stop() {
        queue.async { [self] in
            if manager.state == .poweredOn { manager.stopScan() }
        }
    }

    func rescan() {
        queue.async { [self] in
            guard manager.state == .poweredOn else { return }
            manager.stopScan()
            startScan()
        }
    }

    private func startScan() {
        guard manager.state == .poweredOn else { return }
        manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }
}

/// CoreBluetooth's delegate for `CoreBluetoothScanner`; safe on any thread.
final class BeaconScannerDelegate: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case state(ScannerState)
        case beacon(Data, Int)
        case heartbeat
    }

    private static var serviceUUID: CBUUID { CBUUID(string: PairingCrypto.bleServiceUUID) }

    /// Set once, before the manager exists.
    var forward: (@Sendable (Event) -> Void)?
    /// A monotonic clock for the heartbeat; set by tests before any delivery.
    var uptime: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private let lock = NSLock()
    private var lastHeartbeat: TimeInterval?

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
        heartbeat()
        // 127: CoreBluetooth has no RSSI for this sighting.
        guard rssi != 127, let data = Self.serviceData(advertisementData) else { return }
        forward?(.beacon(data, rssi))
    }

    /// At most one a second, so other devices' sightings cost the main queue next to nothing.
    private func heartbeat() {
        let now = uptime()
        let due = lock.withLock { () -> Bool in
            if let last = lastHeartbeat, now - last < 1 { return false }
            lastHeartbeat = now
            return true
        }
        if due { forward?(.heartbeat) }
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
