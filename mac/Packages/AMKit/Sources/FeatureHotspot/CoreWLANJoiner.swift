import CoreWLAN
import Foundation

/// Joins with CoreWLAN: scans for the hotspot by name (it may take a few seconds to show up
/// after the phone turns it on), then associates. macOS shows Wi-Fi names to apps only with
/// Location access, which the app asks for before calling this.
public struct CoreWLANJoiner: WiFiJoining {
    public enum JoinError: Error { case noWiFi, notFound }

    /// Scans this many times, `pause` apart.
    let scans: Int
    let pause: Duration

    public init(scans: Int = 6, pause: Duration = .seconds(2)) {
        self.scans = scans
        self.pause = pause
    }

    public func join(_ network: HotspotNetwork) async throws {
        guard let wifi = CWWiFiClient.shared().interface() else { throw JoinError.noWiFi }
        if !wifi.powerOn() { try wifi.setPower(true) }
        for attempt in 0..<scans {
            if attempt > 0 { try await Task.sleep(for: pause) }
            let found = try? wifi.scanForNetworks(withName: network.ssid)
            if let target = found?.first(where: { $0.ssid == network.ssid }) ?? found?.first {
                try wifi.associate(to: target, password: network.passphrase.isEmpty ? nil : network.passphrase)
                return
            }
        }
        throw JoinError.notFound
    }
}
