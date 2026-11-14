import CoreLocation
import FeatureHotspot
import SwiftUI

/// The menu's hotspot items (SPEC 25): "Use Phone Hotspot" while the phone is connected,
/// "Join <phone>'s Hotspot" while it is not but its hotspot is known, and how it went.
struct HotspotMenu: View {
    let model: AppModel

    private var hotspot: HotspotModel { model.hotspot }

    var body: some View {
        if let phone = model.currentPhone {
            if model.isConnected, hotspot.phoneID != nil {
                if case .joined = hotspot.phase {
                    Text("Using \(phone.name)'s hotspot")
                    Button("Turn Off Hotspot") { Task { await hotspot.turnOff() } }
                        .disabled(hotspot.phase.isBusy)
                } else {
                    Button("Use Phone Hotspot") { Task { await hotspot.useHotspot() } }
                        .disabled(!hotspot.canUseHotspot)
                        .accessibilityLabel(Text("Use Phone Hotspot"))
                    if hotspot.phoneAvailability?.enabled == false {
                        Text("Set up Full mode on the phone to start its hotspot from here.")
                    }
                }
            } else if !model.isConnected, hotspot.savedNetwork(for: phone.id) != nil {
                Button("Join \(phone.name)'s Hotspot") { Task { await hotspot.joinSaved(phoneID: phone.id) } }
                    .disabled(hotspot.phase.isBusy)
                Text("Turn on the hotspot on the phone first.")
            }
            if let line = Self.line(hotspot.phase) {
                Text(line)
            }
        }
    }

    static func line(_ phase: HotspotModel.Phase) -> LocalizedStringResource? {
        switch phase {
        case .idle, .joined: nil
        case .turningOn: "Turning on the hotspot…"
        case .joining: "Joining the hotspot…"
        case .turningOff: "Turning off the hotspot…"
        case .failed(.needsSetup): "Full mode isn't ready on the phone. Open the phone app to set it up."
        case .failed(.refused): "The phone didn't turn on its hotspot. Check its mobile data."
        case .failed(.failed): "Couldn't turn on the phone's hotspot."
        case .failed(.joinFailed): "Couldn't join the phone's hotspot. Is it on, and is Location allowed in System Settings?"
        }
    }
}

/// Asks for Location once (macOS hides Wi-Fi names without it), then joins with CoreWLAN.
@MainActor
final class LocationGatedJoiner: NSObject, WiFiJoining, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func join(_ network: HotspotNetwork) async throws {
        await askForLocation()
        try await CoreWLANJoiner().join(network)
    }

    private func askForLocation() async {
        manager.delegate = self
        guard manager.authorizationStatus == .notDetermined else { return }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            self?.resumeAll()
        }
        defer { timeout.cancel() }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let decided = manager.authorizationStatus != .notDetermined
        Task { @MainActor [weak self] in if decided { self?.resumeAll() } }
    }

    private func resumeAll() {
        let w = waiters
        waiters = []
        for c in w { c.resume() }
    }
}
