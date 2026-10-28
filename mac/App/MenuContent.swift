import AppKit
import FeatureFind
import FeatureStatus
import SwiftUI

struct MenuContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Top: connection state only.
        if let phone = model.currentPhone, model.isConnected {
            Text(phone.name)
            Text(model.statusText)
        } else {
            Text(model.statusText)
        }
        if let error = model.startupError {
            Text("Can't start: \(error)")
        }

        // Feature items (phone status, Ring phone) are added to this section.
        featureSection

        Divider()
        Button("Pair a phone…") {
            model.startPairing()
            show(WindowID.pairing)
        }
        .disabled(!model.server.isListening)
        .accessibilityLabel(Text("Pair a phone"))
        ForEach(model.pairedPhones, id: \.id) { phone in
            Button("Forget \(phone.name)…") { model.confirmForget(phone) }
                .accessibilityLabel(Text("Forget \(phone.name)"))
        }
        #if DEBUG
        Button("Copy pairing link") {
            if case let .pairing(uri, _) = model.server.state {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(uri.string, forType: .string)
            } else if let uri = model.startPairing() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(uri.string, forType: .string)
            }
        }
        #endif
        Divider()
        Button("Settings…") { show(WindowID.settings) }
            .keyboardShortcut(",")
            .accessibilityLabel(Text("Settings"))
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
            .accessibilityLabel(Text("Quit Android Mirroring"))
    }

    @ViewBuilder private var featureSection: some View {
        if model.canRing {
            Button(model.ring.menuTitle) { Task { await model.ring.toggle(using: model.server) } }
                .accessibilityLabel(Text(model.ring.ringing ? "Stop ringing the phone" : "Ring the phone"))
        }
        if let note = model.ring.note {
            Text(note)
        }
        if model.isConnected, let status = model.phoneStatus.status {
            Text(StatusFormatter.detail(status))
                .accessibilityLabel(Text(StatusFormatter.accessibilityLabel(status)))
        }
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
