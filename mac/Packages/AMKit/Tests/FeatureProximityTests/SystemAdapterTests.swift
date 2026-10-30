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
    #expect(!noSymbol.lock())
    let noFramework = LoginFrameworkLocker(path: "/System/Library/PrivateFrameworks/AMNoSuch.framework/AMNoSuch")
    #expect(!noFramework.available)
    #expect(!noFramework.lock())
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
}

private func post(_ name: Notification.Name, on center: NotificationCenter) async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            center.post(name: name, object: nil)
            done.resume()
        }
    }
}

/// Lets the main queue run until `condition` holds (at most about a second).
@MainActor private func settle(_ condition: () -> Bool) async {
    var waited = 0
    while !condition(), waited < 100 {
        waited += 1
        try? await Task.sleep(for: .milliseconds(10))
    }
}
