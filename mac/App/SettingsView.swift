import AppKit
import ConnectionCore
import FeatureInput
import FeatureNotify
import FeatureScreenshots
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
                Section("Clipboard") {
                    Toggle("Send Mac clipboard to the phone", isOn: Binding(
                        get: { model.sendMacClipboard },
                        set: { model.setSendMacClipboard($0) }
                    ))
                    .accessibilityLabel(Text("Send Mac clipboard to the phone"))
                }
                FocusSettings(model: model, phoneName: phone.name)
                AutoLockSettings(proximity: model.proximity, phone: phone)
                Section("Trackpad and Remote") {
                    Toggle("Allow \(phone.name) to control the pointer", isOn: Binding(
                        get: { model.allowPointerControl },
                        set: { model.setAllowPointerControl($0) }
                    ))
                    .accessibilityLabel(Text("Allow \(phone.name) to control the pointer"))
                    if model.allowPointerControl, !model.input.trusted {
                        Text("Allow Android Mirroring in System Settings › Privacy & Security › Accessibility.")
                            .foregroundStyle(.secondary)
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .accessibilityLabel(Text("Open Accessibility settings in System Settings"))
                    }
                }
                .onAppear {
                    let input = model.input
                    Task { await input.recheckTrust() }
                }
                Section("Screen Mirroring") {
                    Toggle("Play phone audio on this Mac", isOn: Binding(
                        get: { model.playMirrorAudio },
                        set: { model.setPlayMirrorAudio($0) }
                    ))
                    .accessibilityLabel(Text("Play phone audio on this Mac"))
                    Toggle("Turn the phone's screen off while mirroring", isOn: Binding(
                        get: { model.mirrorScreenOff },
                        set: { model.setMirrorScreenOff($0) }
                    ))
                    .accessibilityLabel(Text("Turn the phone's screen off while mirroring"))
                }
                Section("Screenshots") {
                    Picker("Save phone screenshots to", selection: Binding(
                        get: { model.screenshotDestination },
                        set: { model.setScreenshotDestination($0) }
                    )) {
                        Text("Desktop").tag(ScreenshotDestination.desktop)
                        Text("Downloads").tag(ScreenshotDestination.downloads)
                        Text("Clipboard").tag(ScreenshotDestination.clipboard)
                    }
                    .accessibilityLabel(Text("Save phone screenshots to"))
                }
                Section("Calls") {
                    Toggle("Show phone calls", isOn: Binding(
                        get: { model.showPhoneCalls },
                        set: { model.setShowPhoneCalls($0) }
                    ))
                    .accessibilityLabel(Text("Show phone calls"))
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
        // Test mode never locks: it must not stay on once Settings closes.
        .onDisappear { model.proximity.testMode = false }
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
