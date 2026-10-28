import AMProtocol
import AppKit
import ConnectionCore
import SwiftUI

struct PairingWindow: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var hostWindow: NSWindow?

    var body: some View {
        VStack(spacing: 16) {
            content
        }
        .padding(24)
        .frame(width: 360)
        .onDisappear { model.cancelPairing() }
        .background(HostWindowReader { hostWindow = $0 })
        // A close that only hides the window does not run onDisappear. Matched by object
        // identity with this view's own window, not by its title.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if let closing = note.object as? NSWindow, let hostWindow, closing === hostWindow {
                model.cancelPairing()
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let name = model.pairedName, !isPairing {
            pairedView(name)
        } else if let failure = model.pairingFailure, !isPairing {
            failureView(failure)
        } else {
            switch model.server.state {
            case let .pairing(uri, code):
                if let code { codeView(code) } else { qrView(uri) }
            default:
                // Nothing open (for example the Mac is not listening yet).
                VStack(spacing: 12) {
                    Text("No pairing in progress").font(.headline)
                    Button("Show new code") { model.startPairing() }
                        .accessibilityLabel(Text("Show new code"))
                }
            }
        }
    }

    private var isPairing: Bool {
        if case .pairing = model.server.state { return true }
        return false
    }

    private func qrView(_ uri: PairingURI) -> some View {
        VStack(spacing: 12) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = model.pairingDeadline.map { $0.timeIntervalSince(context.date) } ?? 0
                // Expired, or used up by wrong codes: the Mac no longer accepts it either.
                if remaining > 0, !model.server.pairingSecretSpent {
                    VStack(spacing: 12) {
                        QRCodeView(text: uri.string).frame(width: 240, height: 240)
                        Text("Scan this with the Android Mirroring app on your phone")
                            .multilineTextAlignment(.center)
                        Text("Expires in \(Self.format(remaining))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("Expires in \(Self.format(remaining))"))
                    }
                } else {
                    VStack(spacing: 12) {
                        Text("This code has expired").font(.headline)
                        Button("Show new code") { model.startPairing() }
                            .accessibilityLabel(Text("Show new code"))
                    }
                }
            }
            Button("Cancel") { dismiss() }
                .accessibilityLabel(Text("Cancel pairing"))
        }
    }

    private func codeView(_ code: String) -> some View {
        VStack(spacing: 16) {
            Text("Does your phone show this code?")
            Text(code)
                .font(.system(size: 48, weight: .semibold, design: .monospaced))
                .tracking(6)
                .accessibilityLabel(Text(Self.spoken(code)))
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(Text("Cancel pairing"))
                Button("Confirm") { model.confirmPairing() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(Text("Confirm the code matches"))
            }
        }
    }

    private func pairedView(_ name: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("Paired with \(name)").font(.headline)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(Text("Done"))
        }
    }

    private func failureView(_ failure: LocalizedStringResource) -> some View {
        VStack(spacing: 12) {
            Text(failure).multilineTextAlignment(.center)
            Button("Show new code") { model.startPairing() }
                .accessibilityLabel(Text("Show new code"))
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "123456" -> "1 2 3 4 5 6" so VoiceOver reads digit by digit.
    static func spoken(_ code: String) -> String {
        code.map(String.init).joined(separator: " ")
    }
}

/// Reports the NSWindow that hosts the view it is attached to.
private struct HostWindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in onChange(view?.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in onChange(view?.window) }
    }
}
