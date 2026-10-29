import AppKit
import SwiftUI

@main
struct AndroidMirroringApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var model: AppModel { appDelegate.model }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            // Template symbol, dimmed while no phone is connected; battery text beside it once the
            // phone has reported.
            HStack(spacing: 4) {
                Image(systemName: model.isConnected ? "iphone" : "iphone.slash")
                    .opacity(model.isConnected ? 1 : 0.55)
                if let title = model.menuBarStatusTitle { Text(title) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                model.menuBarStatusAccessibilityLabel.map { Text($0) } ?? Text(model.menuBarAccessibilityLabel)
            )
        }

        Window("Pair a phone", id: WindowID.pairing) {
            PairingWindow(model: model)
        }
        .windowResizability(.contentSize)

        Window("Phone", id: WindowID.phone) {
            PhoneWindow(model: model)
        }

        Window("Settings", id: WindowID.settings) {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

/// Owns the model (created once, with the delegate) and says goodbye to the phone on quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    lazy var model = AppModel()

    /// The notification centre's delegate must be set before launch finishes, or a click that
    /// relaunched the app is lost: creating the model creates the presenter that sets it.
    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = model
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}

enum WindowID {
    static let pairing = "pairing"
    static let settings = "settings"
    static let phone = "phone"
}
