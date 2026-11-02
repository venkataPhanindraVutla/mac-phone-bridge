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
            MenuBarLabel(model: model)
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

    /// Opening the app again (Finder, Spotlight, Launchpad) shows a window, so the app is reachable
    /// when the menu bar has no room for its icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NotificationCenter.default.post(name: .showMainWindow, object: nil) }
        return true
    }

    /// With a phone connected, quitting waits (briefly) for the goodbye to reach the network.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.server.activePhone != nil else { return .terminateNow }
        Task { @MainActor in
            await model.shutdownAndFlush()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}

/// The menu-bar icon. It lives as long as the app, so it also opens windows on request.
private struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: model.isConnected ? "iphone" : "iphone.slash")
                .opacity(model.isConnected ? 1 : 0.55)
            if let title = model.menuBarStatusTitle { Text(title) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            model.menuBarStatusAccessibilityLabel.map { Text($0) } ?? Text(model.menuBarAccessibilityLabel)
        )
        .onReceive(NotificationCenter.default.publisher(for: .showMainWindow)) { _ in
            let id = model.isConnected ? WindowID.phone : WindowID.pairing
            if id == WindowID.pairing { _ = model.startPairing() }
            openWindow(id: id)
            NSApp.activate(ignoringOtherApps: true)
            // An agent app's activation can leave the new window behind the front app's windows.
            DispatchQueue.main.async {
                NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(id) == true }?.orderFrontRegardless()
            }
        }
    }
}

extension Notification.Name {
    static let showMainWindow = Notification.Name("io.github.anmirror.showMainWindow")
}

enum WindowID {
    static let pairing = "pairing"
    static let settings = "settings"
    static let phone = "phone"
}
