import AMProtocol
import AppKit
import CoreBluetooth
import Foundation
import Testing
@testable import FeatureProximity

// The system adapters. None of these creates a CBCentralManager (that would ask for Bluetooth) or
// calls the real lock.

private var serviceUUID: CBUUID { CBUUID(string: PairingCrypto.bleServiceUUID) }

@Test func serviceDataIsTakenOnlyWhenItIsEightBytesUnderOurUUID() {
    let id = Data(repeating: 0x5A, count: 8)
    #expect(BeaconScannerDelegate.serviceData([CBAdvertisementDataServiceDataKey: [serviceUUID: id]]) == id)
    #expect(BeaconScannerDelegate.serviceData([CBAdvertisementDataServiceDataKey: [serviceUUID: id.prefix(7)]]) == nil)
    #expect(BeaconScannerDelegate.serviceData([CBAdvertisementDataServiceDataKey: [serviceUUID: id + Data([1])]]) == nil)
    let other = CBUUID(string: "0000feaa-0000-1000-8000-00805f9b34fb")
    #expect(BeaconScannerDelegate.serviceData([CBAdvertisementDataServiceDataKey: [other: id]]) == nil)
    #expect(BeaconScannerDelegate.serviceData([:]) == nil)
    // A service-UUID list alone (no service data) is not our beacon.
    #expect(BeaconScannerDelegate.serviceData([CBAdvertisementDataServiceUUIDsKey: [serviceUUID]]) == nil)
}

@Test func managerStatesMap() {
    #expect(BeaconScannerDelegate.map(.poweredOn, authorization: .allowedAlways) == .poweredOn)
    #expect(BeaconScannerDelegate.map(.poweredOff, authorization: .allowedAlways) == .poweredOff)
    #expect(BeaconScannerDelegate.map(.unauthorized, authorization: .denied) == .unauthorized)
    #expect(BeaconScannerDelegate.map(.unsupported, authorization: .allowedAlways) == .unsupported)
    #expect(BeaconScannerDelegate.map(.resetting, authorization: .allowedAlways) == .unknown)
    #expect(BeaconScannerDelegate.map(.unknown, authorization: .notDetermined) == .unknown)
    // The ad-hoc build may report a powered-on manager while access is denied or restricted.
    #expect(BeaconScannerDelegate.map(.poweredOn, authorization: .denied) == .unauthorized)
    #expect(BeaconScannerDelegate.map(.poweredOn, authorization: .restricted) == .unauthorized)
}

/// CoreBluetooth calls the delegate on its own queue: the delegate must not be main-actor isolated
/// (Swift 6 traps at entry), and what it hands on must reach the scanner on the main actor.
@MainActor @Test func delegateCallbacksOffTheMainThreadReachTheScanner() async {
    let scanner = CoreBluetoothScanner()
    let delegate = scanner.delegate
    var states: [ScannerState] = []
    var beacons: [(Data, Int)] = []
    scanner.onState = { states.append($0) }
    scanner.onBeacon = { beacons.append(($0, $1)) }
    scanner.wantsScan = true // as after start(), without creating the manager
    let id = Data(repeating: 0x11, count: 8)
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            #expect(!Thread.isMainThread)
            delegate.deliver(state: .poweredOff, authorization: .allowedAlways)
            delegate.deliver(advertisementData: [CBAdvertisementDataServiceDataKey: [serviceUUID: id]], rssi: -61)
            // 127 means CoreBluetooth has no RSSI for this sighting.
            delegate.deliver(advertisementData: [CBAdvertisementDataServiceDataKey: [serviceUUID: id]], rssi: 127)
            DispatchQueue.main.async { done.resume() }
        }
    }
    #expect(states == [.poweredOff])
    #expect(scanner.state == .poweredOff)
    #expect(beacons.count == 1)
    #expect(beacons.first?.0 == id)
    #expect(beacons.first?.1 == -61)
}

@MainActor @Test func beaconsAfterStopAreDropped() async {
    let scanner = CoreBluetoothScanner()
    let delegate = scanner.delegate
    var beacons = 0
    scanner.onBeacon = { _, _ in beacons += 1 }
    scanner.stop()
    let id = Data(repeating: 0x11, count: 8)
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            delegate.deliver(advertisementData: [CBAdvertisementDataServiceDataKey: [serviceUUID: id]], rssi: -61)
            DispatchQueue.main.async { done.resume() }
        }
    }
    #expect(beacons == 0)
}

@MainActor @Test func missingLockSymbolIsUnavailable() {
    let noSymbol = LoginFrameworkLocker(symbol: "AMNoSuchLockSymbol")
    #expect(!noSymbol.available)
    #expect(noSymbol.lock() == nil)
    let noFramework = LoginFrameworkLocker(path: "/System/Library/PrivateFrameworks/AMNoSuch.framework/AMNoSuch")
    #expect(!noFramework.available)
    #expect(noFramework.lock() == nil)
}

/// NSWorkspace posts sleep and wake on the main thread, but nothing guarantees it: a post from
/// another thread must not trap, and must still mark the Mac asleep and then awake.
@MainActor @Test func sleepAndWakePostedOffTheMainThreadAreHandled() async {
    let center = NotificationCenter()
    let activity = SystemMacActivity(center: center)
    var wakes = 0
    activity.onWake = { wakes += 1 }
    await post(NSWorkspace.screensDidSleepNotification, on: center)
    await settle { activity.asleep }
    #expect(activity.asleep)
    await post(NSWorkspace.didWakeNotification, on: center)
    await settle { !activity.asleep }
    #expect(!activity.asleep)
    #expect(wakes == 1)
    await post(NSWorkspace.willSleepNotification, on: center)
    await settle { activity.asleep }
    #expect(activity.asleep)
    await post(NSWorkspace.screensDidWakeNotification, on: center)
    await settle { !activity.asleep }
    #expect(wakes == 2)
}

@MainActor @Test func systemActivityReadsWithoutTrapping() {
    let activity = SystemMacActivity(center: NotificationCenter())
    #expect(activity.idleSeconds() >= 0)
    _ = activity.screenLocked
    _ = activity.screenKeptAwake
}

@Test func displaySleepAssertionsCountAsInUse() {
    #expect(SystemMacActivity.keepsScreenAwake(["PreventUserIdleDisplaySleep": 1]))
    #expect(SystemMacActivity.keepsScreenAwake(["NoDisplaySleepAssertion": 2]))
    #expect(!SystemMacActivity.keepsScreenAwake(["PreventUserIdleDisplaySleep": 0, "NoDisplaySleepAssertion": 0]))
    // Keeping the system (not the screen) awake is not someone watching.
    #expect(!SystemMacActivity.keepsScreenAwake(["PreventUserIdleSystemSleep": 1]))
    #expect(!SystemMacActivity.keepsScreenAwake([:]))
}

/// Any advertisement, ours or not, is a heartbeat, forwarded at most once a second however many
/// sightings arrive.
@MainActor @Test func heartbeatIsCoalescedToOncePerSecond() async {
    let scanner = CoreBluetoothScanner()
    let delegate = scanner.delegate
    let clock = TestUptime()
    delegate.uptime = { clock.value }
    var heartbeats = 0
    scanner.onHeartbeat = { heartbeats += 1 }
    scanner.wantsScan = true
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            let other: [String: Any] = [CBAdvertisementDataLocalNameKey: "headphones"]
            for _ in 0..<50 { delegate.deliver(advertisementData: other, rssi: -70) }
            clock.value = 0.5
            delegate.deliver(advertisementData: other, rssi: -70)
            clock.value = 1.0
            delegate.deliver(advertisementData: other, rssi: -70)
            // A sighting without an RSSI is still a sign the scan is running.
            clock.value = 2.5
            delegate.deliver(advertisementData: other, rssi: 127)
            DispatchQueue.main.async { done.resume() }
        }
    }
    #expect(heartbeats == 3)
}

@MainActor @Test func appNapActivityIsHeldOnlyWhileScanning() {
    let scanner = CoreBluetoothScanner()
    #expect(!scanner.holdsActivity)
    scanner.holdActivity(true)
    #expect(scanner.holdsActivity)
    scanner.holdActivity(true) // idempotent
    scanner.stop()
    #expect(!scanner.holdsActivity)
}

private final class TestUptime: @unchecked Sendable {
    var value: TimeInterval = 0
}

private func post(_ name: Notification.Name, on center: NotificationCenter) async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            center.post(name: name, object: nil)
            done.resume()
        }
    }
}

/// Lets the main queue run until `condition` holds (at most 30 s: generous, as on a busy runner
/// the main queue can be seconds behind; the bound only matters when the test fails).
@MainActor private func settle(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(30)
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
}
