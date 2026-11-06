import ConnectionCore
import FeatureProximity
import SwiftUI

/// Settings › Auto-Lock: lock this Mac when the phone is away (F-15). The switch, the signal
/// threshold and delay, "Test mode" with live readouts, a line for each reason it can't lock, and
/// a reminder that it never unlocks.
struct AutoLockSettings: View {
    let proximity: ProximityModel
    let phone: PairedPhone

    /// On for this phone; the setting may be for another paired phone.
    private var isOn: Bool { proximity.enabled && proximity.phoneID == phone.id }

    var body: some View {
        Section("Auto-Lock") {
            Toggle("Lock this Mac when \(phone.name) is away", isOn: Binding(
                get: { isOn },
                set: { proximity.setEnabled($0, phoneID: phone.id) }
            ))
            .accessibilityLabel(Text("Lock this Mac when \(phone.name) is away"))
            if isOn {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Signal threshold")
                        Spacer()
                        Text("\(proximity.config.thresholdDBm) dBm").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: threshold, in: Double(ProximityConfig.thresholdRange.lowerBound)...Double(ProximityConfig.thresholdRange.upperBound), step: 1)
                        .accessibilityLabel(Text("Signal threshold"))
                        .accessibilityValue(Text("\(proximity.config.thresholdDBm) dBm"))
                }
                Stepper(value: delay, in: ProximityConfig.delayRange, step: 5) {
                    HStack {
                        Text("Lock after")
                        Spacer()
                        Text("\(Int(proximity.config.delay)) seconds").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel(Text("Lock after"))
                .accessibilityValue(Text("\(Int(proximity.config.delay)) seconds"))
                Toggle("Test mode", isOn: Binding(
                    get: { proximity.testMode },
                    set: { proximity.testMode = $0 }
                ))
                .accessibilityLabel(Text("Test mode"))
                if proximity.testMode {
                    readouts
                }
                ForEach(Array(blockerLines.enumerated()), id: \.offset) { _, line in
                    Text(line).foregroundStyle(.secondary)
                }
            }
            Text("This Mac never unlocks itself.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var readouts: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let rssi = proximity.smoothedRSSI {
                Text("Signal: \(rssi) dBm")
            } else {
                Text("No signal")
            }
            Text(proximity.zone == .near ? "Near" : "Away")
            switch proximity.decision {
            case let .countdown(remaining):
                Text("Locking in \(Int(remaining.rounded(.up))) s")
            case .lock:
                Text("Would lock now")
            case .none:
                EmptyView()
            }
            Text("Mac idle for \(Int(proximity.idleSeconds)) s")
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    /// One line per reason it can't lock that the user can act on or should know about (shown in
    /// test mode too). The screen being locked or asleep needs no line, nor Bluetooth before it has
    /// reported.
    private var blockerLines: [LocalizedStringResource] {
        let b = proximity.blockers
        var lines: [LocalizedStringResource] = []
        if b.contains(.bluetoothOff), proximity.scannerState != .unknown { lines.append("Turn on Bluetooth on this Mac.") }
        if b.contains(.bluetoothUnauthorized) { lines.append("Allow Bluetooth for Mac Phone Bridge in System Settings.") }
        if b.contains(.lockUnavailable) { lines.append("Locking isn't available on this macOS version") }
        if b.contains(.scannerStalled) { lines.append("Bluetooth on this Mac stopped reporting nearby devices.") }
        if b.contains(.macInUse) { lines.append("Not locking while a video or call keeps the screen awake.") }
        switch proximity.phoneIssue {
        case .switchOff: lines.append("Turn on “Let your Mac lock when you walk away” in the phone app.")
        case .needsPermission: lines.append("Allow Nearby devices for Mac Phone Bridge on the phone.")
        case .bluetooth: lines.append("Bluetooth is off on the phone, or it can't advertise.")
        case .needsUpdate: lines.append("Update the phone app to use Auto-Lock.")
        case nil: break
        }
        if b.contains(.noRecentSession) { lines.append("Auto-Lock is paused until \(phone.name) connects to this Mac again.") }
        return lines
    }

    private var threshold: Binding<Double> {
        Binding(
            get: { Double(proximity.config.thresholdDBm) },
            set: { proximity.config.thresholdDBm = Int($0.rounded()) }
        )
    }

    private var delay: Binding<TimeInterval> {
        Binding(
            get: { proximity.config.delay },
            set: { proximity.config.delay = $0 }
        )
    }
}
