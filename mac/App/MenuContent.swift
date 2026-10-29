import AppKit
import FeatureCalls
import FeatureFiles
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
        if model.isConnected, model.canNotify {
            if model.notifications.authorized == false {
                Text("Allow notifications for Android Mirroring in System Settings.")
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .accessibilityLabel(Text("Open notification settings in System Settings"))
            }
            if let availability = model.notifications.phoneAvailability,
               !availability.enabled, availability.reason == .needsPermission {
                Text("Turn on notification access in the phone app.")
            }
        }
        if model.isConnected, model.canClipboard, let availability = model.clipboard.phoneAvailability,
           !availability.enabled, availability.reason == .offByUser {
            Text("Turn on clipboard sharing in the phone app.")
        }
        if model.isConnected {
            sendSection
        }
        if model.isConnected, model.canCall, let call = model.calls.active {
            Text("On a call with \(model.calls.displayName(call)) · \(model.calls.elapsedText ?? "00:00")")
            if call.muteSupported {
                if call.muted {
                    Button("Unmute") { Task { await model.calls.toggleMute() } }
                        .accessibilityLabel(Text("Unmute"))
                } else {
                    Button("Mute") { Task { await model.calls.toggleMute() } }
                        .accessibilityLabel(Text("Mute"))
                }
            }
            Button("Hang up") { Task { await model.calls.hangUp() } }
                .accessibilityLabel(Text("Hang up"))
        }
        if model.isConnected, let status = model.phoneStatus.status {
            Text(StatusFormatter.detail(status))
                .accessibilityLabel(Text(StatusFormatter.accessibilityLabel(status)))
        }
    }

    /// Sending to the phone and the transfers under way (connected only).
    @ViewBuilder private var sendSection: some View {
        Button("Show Phone Window") { show(WindowID.phone) }
            .accessibilityLabel(Text("Show Phone Window"))
        if model.canSendFiles {
            Button("Send File to Phone…") { model.chooseFilesToSend() }
                .accessibilityLabel(Text("Send File to Phone"))
        }
        if model.canShare {
            Button("Send Clipboard to Phone") { Task { await model.share.sendClipboard() } }
                .accessibilityLabel(Text("Send Clipboard to Phone"))
            if let note = TransferText.note(model.share.lastOutcome) {
                Text(note)
            }
        }
        ForEach(model.transfers.transfers.filter { !$0.isFinal }) { item in
            Menu {
                Button("Cancel") { model.transfers.cancel(item.id) }
                    .accessibilityLabel(Text(TransferText.cancelLabel(item)))
            } label: {
                Text(TransferText.title(item))
            }
        }
        if let failure = model.transfers.lastFailure {
            Text(TransferText.title(failure))
            if let reason = TransferText.reason(failure) {
                Text(reason)
            }
        }
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
