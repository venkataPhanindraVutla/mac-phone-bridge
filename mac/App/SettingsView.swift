import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var errorText: String?

    var body: some View {
        Form {
            Toggle("Open at login", isOn: $openAtLogin)
                .accessibilityLabel(Text("Open at login"))
                .onChange(of: openAtLogin) { _, enabled in apply(enabled) }
            if let errorText {
                Text(errorText).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .onAppear { openAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private func apply(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
