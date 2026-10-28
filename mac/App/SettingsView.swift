import AppKit
import ConnectionCore
import FeatureNotify
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var errorText: String?
    @State private var notify = NotifySettings()

    var body: some View {
        Form {
            Toggle("Open at login", isOn: $openAtLogin)
                .accessibilityLabel(Text("Open at login"))
                .onChange(of: openAtLogin) { _, enabled in apply(enabled) }
            if let errorText {
                Text(errorText).foregroundStyle(.red)
            }
            if let phone = model.currentPhone {
                Section("Contacts") {
                    Toggle("Use phone contacts for caller names", isOn: Binding(
                        get: { model.contactsForNames },
                        set: { model.setContactsForNames($0) }
                    ))
                    .accessibilityLabel(Text("Use phone contacts for caller names"))
                    if model.contactsForNames, model.contactsCount > 0 {
                        Text("\(model.contactsCount) contacts")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Notifications") {
                    Toggle("Show phone notifications", isOn: binding(\.enabled, phone: phone))
                        .accessibilityLabel(Text("Show phone notifications"))
                    if notify.enabled {
                        ForEach(apps, id: \.package) { app in
                            HStack {
                                icon(for: app.package)
                                Toggle(app.name, isOn: appBinding(app.package, phone: phone))
                                    .accessibilityLabel(Text("Show notifications from \(app.name)"))
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .onAppear {
            openAtLogin = SMAppService.mainApp.status == .enabled
            reloadNotify()
        }
        .onChange(of: model.currentPhone?.id) { _, _ in reloadNotify() }
    }

    private var apps: [(package: String, name: String)] {
        notify.seenApps.map { (package: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @ViewBuilder private func icon(for package: String) -> some View {
        if let url = model.appIconURL(package: package), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().frame(width: 20, height: 20).accessibilityHidden(true)
        } else {
            Image(systemName: "app").frame(width: 20, height: 20).accessibilityHidden(true)
        }
    }

    private func reloadNotify() {
        if let phone = model.currentPhone { notify = model.notifications.settings(for: phone.id) }
    }

    private func binding(_ keyPath: WritableKeyPath<NotifySettings, Bool>, phone: PairedPhone) -> Binding<Bool> {
        Binding(
            get: { notify[keyPath: keyPath] },
            set: { value in
                notify[keyPath: keyPath] = value
                save(phone)
            }
        )
    }

    /// On means not muted.
    private func appBinding(_ package: String, phone: PairedPhone) -> Binding<Bool> {
        Binding(
            get: { !notify.mutedPackages.contains(package) },
            set: { on in
                if on { notify.mutedPackages.remove(package) } else { notify.mutedPackages.insert(package) }
                save(phone)
            }
        )
    }

    private func save(_ phone: PairedPhone) {
        let value = notify
        Task { await model.notifications.update(value, phoneID: phone.id) }
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
