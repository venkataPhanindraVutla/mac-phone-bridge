import AMProtocol
import FeatureFocus
import SwiftUI

/// Settings › Focus: the "Sync Focus" switch, a line for each direction, and the Shortcuts steps
/// while the two shortcuts are missing.
struct FocusSettings: View {
    let model: AppModel
    let phoneName: String

    /// The Shortcuts steps; the README has the same words.
    static let steps: [LocalizedStringResource] = [
        "Open the Shortcuts app and create a new shortcut.",
        "Add the action “Set Focus”, choose Do Not Disturb, and set it to turn On.",
        "Name the shortcut “Mac Phone Bridge Focus On”.",
        "Create a second shortcut that turns Do Not Disturb Off, named “Mac Phone Bridge Focus Off”.",
        "Come back here and click Check Again.",
    ]

    private var focus: FocusModel { model.focus }

    var body: some View {
        Section("Focus") {
            Toggle("Sync Focus with \(phoneName)", isOn: Binding(
                get: { model.syncFocus },
                set: { model.setSyncFocus($0) }
            ))
            .accessibilityLabel(Text("Sync Focus with \(phoneName)"))
            if focus.enabled {
                Text(phoneToMac).foregroundStyle(.secondary)
                if let macToPhone {
                    Text(macToPhone).foregroundStyle(.secondary)
                }
                if focus.lastRunFailed {
                    Text("Couldn't run the Focus shortcut.").foregroundStyle(.red)
                }
                if focus.shortcutsInstalled != true {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(verbatim: "\(index + 1).").monospacedDigit()
                                Text(step)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    Button("Check Again") {
                        let focus = focus
                        Task { await focus.checkShortcuts() }
                    }
                }
            }
        }
        .onAppear {
            let focus = focus
            Task { await focus.refreshAuthorization() }
        }
    }

    /// Phone to Mac: works once both shortcuts are installed and the phone sends (its switch is on).
    private var phoneToMac: LocalizedStringResource {
        if focus.shortcutsInstalled != true { return "Install the two Shortcuts to let your phone turn on Focus" }
        if focus.phoneAvailability?.sends.enabled == false { return "Turn on Do Not Disturb sync in the phone app." }
        return "Your phone's Do Not Disturb turns on Focus on this Mac."
    }

    /// Mac to phone: needs Focus status access here and Do Not Disturb sync on the phone. Nothing
    /// is said about the phone before it has reported.
    private var macToPhone: LocalizedStringResource? {
        switch focus.authorization {
        case .denied, .notDetermined:
            return "Allow Mac Phone Bridge to read your Focus status in System Settings."
        case .unavailable:
            return "This build of Mac Phone Bridge can't read Focus status."
        case .authorized:
            guard let applies = focus.phoneAvailability?.applies else { return nil }
            if applies.enabled { return "Focus on this Mac turns on Do Not Disturb on your phone." }
            return applies.reason == .needsPermission
                ? "Allow Do Not Disturb access in the phone app."
                : "Turn on Do Not Disturb sync in the phone app."
        }
    }
}
