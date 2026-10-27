import SwiftUI

@main
struct AndroidMirroringApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            // Template symbol; dimmed while no phone is connected.
            Image(systemName: model.isConnected ? "iphone" : "iphone.slash")
                .opacity(model.isConnected ? 1 : 0.55)
                .accessibilityLabel(Text(model.menuBarAccessibilityLabel))
        }

        Window("Pair a phone", id: WindowID.pairing) {
            PairingWindow(model: model)
        }
        .windowResizability(.contentSize)

        Window("Settings", id: WindowID.settings) {
            SettingsView()
        }
        .windowResizability(.contentSize)
    }
}

enum WindowID {
    static let pairing = "pairing"
    static let settings = "settings"
}
