import AppKit
import AMProtocol
import ConnectionCore
import CryptoKit
import FeatureContacts
import FeatureFind
import FeatureNotify
import FeatureStatus
import Foundation
import Observation
import os

/// Owns the connection and the feature models. Feature models (phone status, ring) are added
/// here next to `server`; the views only read this object.
@MainActor
@Observable
final class AppModel {
    static let capabilities: Set<String> = ["status.v1", "find.v1", "notify.v1", "contacts.v1"]
    /// A pairing code (and its QR) stays valid for this long. Matches the Mac server's lifetime.
    static let pairingLifetime: TimeInterval = 300

    let server: MacServer
    let phoneStatus = PhoneStatusModel()
    let ring = RingModel()
    let notifications: NotificationsModel
    /// Whether phone contacts name callers and notification titles (default on). Turning it off wipes the stores.
    private(set) var contactsForNames: Bool = AppModel.savedContactsForNames
    private(set) var pairedPhones: [PairedPhone] = []
    /// When the current QR code expires; nil when no pairing window is open.
    private(set) var pairingDeadline: Date?
    /// Set when pairing finished; shown by the pairing window.
    private(set) var pairedName: String?
    private(set) var pairingFailure: LocalizedStringResource?
    private(set) var startupError: String?

    @ObservationIgnored private let phoneStore: any PairedPhoneStore
    @ObservationIgnored private let notificationPresenter: UserNotificationPresenter
    @ObservationIgnored private let icons: IconCache
    /// The connected phone's contacts, loaded while it is connected and shares contacts.v1.
    @ObservationIgnored private let contactsSlot = ContactsSlot()
    /// The phone's last `contacts.availability`; nil until the first one of this connection.
    @ObservationIgnored private var contactsPhoneEnabled: Bool?
    /// Everything that reaches `notifications` goes through here, so it is handled one at a time in arrival order.
    @ObservationIgnored private let notifyWork: AsyncStream<NotifyWork>.Continuation
    @ObservationIgnored private var notifyDrain: Task<Void, Never>?
    @ObservationIgnored private var activeObserver: NSObjectProtocol?
    /// Held for the life of the process (the model is never deallocated).
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private static let portKey = "listenPort"
    @ObservationIgnored private static let contactsKey = "contactsForNames"
    private static var savedContactsForNames: Bool {
        UserDefaults.standard.object(forKey: contactsKey) as? Bool ?? true
    }
    #if DEBUG
    private static func debugLine(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
    @ObservationIgnored private static let log = Logger(subsystem: "io.github.anmirror.mac", category: "debug")
    #endif

    init() {
        let store = KeychainPairedPhoneStore()
        phoneStore = store
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let server = MacServer(
            identity: KeychainIdentityProvider(),
            phones: store,
            secrets: KeychainSecretStore(),
            macName: Host.current().localizedName ?? "Mac",
            appVersion: version,
            capabilities: Self.capabilities
        )
        self.server = server

        let presenter = UserNotificationPresenter()
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let icons = IconCache(directory: caches.appendingPathComponent("io.github.anmirror.mac/notify-icons"))
        notificationPresenter = presenter
        self.icons = icons
        let slot = contactsSlot
        notifications = NotificationsModel(
            presenter: presenter, icons: icons,
            load: { Self.loadNotifySettings(phoneID: $0) },
            save: { Self.saveNotifySettings($1, phoneID: $0) },
            copy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            nameFor: { slot.store?.name(forNumber: $0) },
            send: { type, message in
                // Only a phone that shares notify.v1 gets notify messages.
                guard server.activePhone?.shared.contains("notify.v1") == true else { return }
                try? await server.send(type, message, channel: .notify)
            }
        )
        let (stream, continuation) = AsyncStream.makeStream(of: NotifyWork.self)
        notifyWork = continuation
        server.onEvent = { [weak self] event in self?.handle(event) }
        server.onMessage = { [weak self] envelope in self?.handle(message: envelope) }
        let model = notifications
        notifyDrain = Task { @MainActor [weak self] in
            for await work in stream {
                switch work {
                case let .connected(phoneID): await model.connected(phoneID: phoneID)
                case .disconnected: model.disconnected()
                case let .message(envelope): _ = await NotifyRouter.route(envelope, to: model)
                case let .contactsConnected(phoneID): await self?.contactsConnected(phoneID: phoneID)
                case .contactsDisconnected: self?.contactsDisconnected()
                case let .contactsMessage(envelope): await self?.contactsMessage(envelope)
                case .contactsToggled: await self?.contactsToggled()
                case let .contactsForget(phoneID): self?.contactsForget(phoneID: phoneID)
                }
            }
        }
        presenter.onResponse = { actionID, userInfo, reply in
            await model.handleResponse(actionID: actionID, userInfo: userInfo, replyText: reply)
        }
        // The user may allow notifications in System Settings and come back.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if model.authorized == false { Task { await model.refreshAuthorization() } }
            }
        }
        refreshPhones()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.server.handleWake() }
        }
        start()
    }

    // MARK: derived state
    // Connection display and feature items follow `server.activePhone` only: an open pairing
    // window must not make a connected phone look disconnected.

    var isConnected: Bool { server.activePhone != nil }

    /// The phone to show in the menu: the connected one, else the first paired one.
    var currentPhone: PairedPhone? { server.activePhone?.phone ?? pairedPhones.first }

    var statusText: LocalizedStringResource {
        if server.activePhone != nil { return "Connected" }
        switch server.state {
        case .connected: return "Connected"
        case .incompatible: return "Update needed: app versions differ"
        case .pairing: return "Pairing…"
        case .idle: return pairedPhones.isEmpty ? "No phone paired" : "Not connected"
        }
    }

    var menuBarAccessibilityLabel: LocalizedStringResource {
        isConnected ? "Android Mirroring, phone connected" : "Android Mirroring, phone not connected"
    }

    /// Find my phone is offered only while the connected phone shares `find.v1`.
    var canRing: Bool { server.activePhone?.shared.contains("find.v1") ?? false }

    /// Phone notifications are offered only while the connected phone shares `notify.v1`.
    var canNotify: Bool { server.activePhone?.shared.contains("notify.v1") ?? false }

    /// How many contacts the connected phone has shared; 0 when none are loaded.
    var contactsCount: Int { contactsSlot.store?.count ?? 0 }

    /// The "Use phone contacts for caller names" switch in Settings.
    func setContactsForNames(_ on: Bool) {
        guard on != contactsForNames else { return }
        contactsForNames = on
        UserDefaults.standard.set(on, forKey: Self.contactsKey)
        notifyWork.yield(.contactsToggled)
    }

    /// The cached app icon for the Settings list.
    func appIconURL(package: String) -> URL? { icons.url(for: package) }

    /// Status text for the menu-bar icon; nil unless a phone is connected and has reported.
    var menuBarStatusTitle: String? {
        guard isConnected, let status = phoneStatus.status else { return nil }
        return StatusFormatter.menuTitle(status)
    }

    /// Spoken label for the menu-bar item when status is showing.
    var menuBarStatusAccessibilityLabel: String? {
        guard isConnected, let status = phoneStatus.status else { return nil }
        return String(localized: "Android Mirroring, phone connected") + ", " + StatusFormatter.accessibilityLabel(status)
    }

    // MARK: pairing

    /// Opens (or replaces) the pairing window's secret and starts the 5-minute countdown.
    @discardableResult
    func startPairing() -> PairingURI? {
        guard server.isListening else { return nil }
        pairedName = nil
        pairingFailure = nil
        let uri = server.beginPairing()
        pairingDeadline = Date().addingTimeInterval(Self.pairingLifetime)
        #if DEBUG
        Self.log.info("pairing uri: \(uri.string, privacy: .public)")
        Self.debugLine("pairing uri: \(uri.string)")
        #endif
        return uri
    }

    /// Called when the pairing window closes. Declining closes the server's pairing window
    /// (before or after a phone has been verified); it is a no-op when none is open.
    func cancelPairing() {
        if case .pairing = server.state { server.confirmPairing(false) }
        pairingDeadline = nil
    }

    func confirmPairing() { server.confirmPairing(true) }

    // MARK: forget

    /// Confirms with the user, then unpairs.
    func confirmForget(_ phone: PairedPhone) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "Forget \(phone.name)?")
        alert.informativeText = String(localized: "This Mac will stop talking to the phone. You can pair it again later.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Forget"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await server.forget(phoneID: phone.id) }
    }

    // MARK: server

    /// App quit: tell the phone (`system.goodbye SHUTDOWN`) and close. The goodbye is queued on
    /// the connection's own queue; a short pause lets it reach the wire before the process ends.
    func shutdown() {
        let hadPhone = server.activePhone != nil
        server.stop()
        if hadPhone { Thread.sleep(forTimeInterval: 0.25) }
    }

    private func start() {
        let saved = UserDefaults.standard.integer(forKey: Self.portKey)
        do {
            try server.start(port: UInt16(exactly: saved))
        } catch {
            startupError = String(describing: error)
        }
    }

    private func handle(_ event: MacServerEvent) {
        switch event {
        case let .listening(port):
            UserDefaults.standard.set(Int(port), forKey: Self.portKey)
            #if DEBUG
            if ProcessInfo.processInfo.environment["AM_DEBUG_BEGIN_PAIRING"] == "1", pairingDeadline == nil {
                startPairing()
            }
            #endif
        case .listenerFailed:
            // The remembered port stayed busy; use any free one from now on.
            UserDefaults.standard.removeObject(forKey: Self.portKey)
            try? server.start(port: 0)
        case let .pairingCode(code):
            #if DEBUG
            Self.log.info("pairing code: \(code, privacy: .public)")
            Self.debugLine("pairing code: \(code)")
            if ProcessInfo.processInfo.environment["AM_DEBUG_AUTO_CONFIRM"] == "1" { server.confirmPairing(true) }
            #endif
        case let .paired(phone):
            pairedName = phone.name
            pairingDeadline = nil
            refreshPhones()
        case let .connected(phone, shared):
            phoneStatus.reset() // never show the previous session's values
            ring.clearHint()
            // Contacts first, so the store is there when the phone's first notifications are shown.
            if shared.contains("contacts.v1") { notifyWork.yield(.contactsConnected(phone.id)) }
            if shared.contains("notify.v1") { notifyWork.yield(.connected(phone.id)) }
            refreshPhones()
            #if DEBUG
            Self.debugLine("connected \(phone.name) shared=\(shared.sorted())")
            #endif
        case let .disconnected(phone):
            phoneStatus.reset()
            ring.reset()
            notifyWork.yield(.disconnected)
            notifyWork.yield(.contactsDisconnected)
            #if DEBUG
            Self.debugLine("disconnected \(phone.name)")
            #endif
        case let .unpaired(phone):
            phoneStatus.reset()
            ring.reset()
            notifyWork.yield(.disconnected)
            notifyWork.yield(.contactsDisconnected)
            notifyWork.yield(.contactsForget(phone.id)) // a forgotten phone leaves no contacts behind
            UserDefaults.standard.removeObject(forKey: Self.notifySettingsKey(phoneID: phone.id))
            refreshPhones()
        case let .rejected(reason):
            switch reason {
            case .pairingCancelled, .pairingRejected, .pairingTimedOut:
                if pairingDeadline != nil { pairingFailure = PairingCopy.message(for: .pairingRejected) }
            case .pairingExpired:
                if pairingDeadline != nil { pairingFailure = PairingCopy.message(for: .pairingExpired) }
            default:
                break
            }
        }
    }

    private func handle(message envelope: AMEnvelope) {
        if envelope.type.hasPrefix("notify.") {
            notifyWork.yield(.message(envelope))
            return
        }
        if envelope.type.hasPrefix("contacts.") {
            notifyWork.yield(.contactsMessage(envelope))
            return
        }
        switch envelope.type {
        case MessageType.statusUpdate.rawValue:
            if let update = try? AMStatusUpdate(serializedBytes: envelope.payload) { phoneStatus.apply(update) }
        case MessageType.findState.rawValue:
            if let state = try? AMRingState(serializedBytes: envelope.payload) { ring.apply(state) }
        default:
            break
        }
    }

    // MARK: contacts (all run on the ordered work stream)

    private func contactsConnected(phoneID: String) async {
        contactsPhoneEnabled = nil
        guard contactsForNames else { return }
        await openContacts(phoneID: phoneID)
    }

    /// Loads the phone's store and asks for what it lacks.
    private func openContacts(phoneID: String) async {
        if contactsSlot.store == nil {
            do {
                let key = try ContactsKey.load(phoneID: phoneID)
                let url = ContactsStore.fileURL(phoneID: phoneID, in: ContactsStore.defaultDirectory)
                contactsSlot.store = ContactsStore(file: EncryptedFile(url: url, key: key))
            } catch {
                Self.contactsLog.error("contacts store unavailable: \(String(describing: error), privacy: .public)")
                return
            }
        }
        await requestContacts()
    }

    private func requestContacts() async {
        guard let store = contactsSlot.store, server.activePhone?.shared.contains("contacts.v1") == true else { return }
        var request = AMContactsSyncRequest()
        request.sinceMs = store.syncMs
        try? await server.send(.contactsSync, request, channel: .contacts)
    }

    private func contactsDisconnected() {
        // Decrypted contacts stay in memory only while the phone is connected.
        contactsSlot.store?.abandonSync()
        contactsSlot.store = nil
        contactsPhoneEnabled = nil
    }

    private func contactsMessage(_ envelope: AMEnvelope) async {
        guard contactsForNames else { return }
        switch envelope.type {
        case MessageType.contactsBatch.rawValue:
            guard let store = contactsSlot.store, let batch = try? AMContactsBatch(serializedBytes: envelope.payload) else { return }
            do { try store.apply(batch) } catch {
                Self.contactsLog.error("contacts batch not stored: \(String(describing: error), privacy: .public)")
            }
        case MessageType.contactsAvailability.rawValue:
            guard let a = try? AMFeatureAvailability(serializedBytes: envelope.payload) else { return }
            let before = contactsPhoneEnabled
            contactsPhoneEnabled = a.enabled
            // The user turned sharing on (or allowed the permission) on the phone mid-session: ask now.
            if a.enabled, before == false { await requestContacts() }
        default:
            break
        }
    }

    private func contactsToggled() async {
        if contactsForNames {
            if let phone = server.activePhone, phone.shared.contains("contacts.v1") {
                await openContacts(phoneID: phone.phone.id)
            }
        } else {
            for phone in pairedPhones { Self.removeContacts(phoneID: phone.id, store: contactsSlot.store) }
            contactsSlot.store = nil
        }
    }

    private func contactsForget(phoneID: String) {
        Self.removeContacts(phoneID: phoneID, store: contactsSlot.store)
        contactsSlot.store = nil
    }

    /// Deletes a phone's store file and its key, whether or not the store is loaded.
    private static func removeContacts(phoneID: String, store: ContactsStore?) {
        try? store?.wipe()
        try? FileManager.default.removeItem(at: ContactsStore.fileURL(phoneID: phoneID, in: ContactsStore.defaultDirectory))
        try? ContactsKey.delete(phoneID: phoneID)
    }

    private static let contactsLog = Logger(subsystem: "io.github.anmirror.mac", category: "contacts")

    private static func notifySettingsKey(phoneID: String) -> String { "notifySettings." + phoneID }

    private static func loadNotifySettings(phoneID: String) -> NotifySettings {
        guard let data = UserDefaults.standard.data(forKey: notifySettingsKey(phoneID: phoneID)),
              let settings = try? JSONDecoder().decode(NotifySettings.self, from: data) else { return NotifySettings() }
        return settings
    }

    private static func saveNotifySettings(_ settings: NotifySettings, phoneID: String) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: notifySettingsKey(phoneID: phoneID))
    }

    private func refreshPhones() {
        pairedPhones = (try? phoneStore.all()) ?? []
    }
}

/// One unit of work for the notification model, handled in the order it arrived.
private enum NotifyWork: Sendable {
    case connected(String)
    case disconnected
    case message(AMEnvelope)
    case contactsConnected(String)
    case contactsDisconnected
    case contactsMessage(AMEnvelope)
    case contactsToggled
    case contactsForget(String)
}

/// Holds the connected phone's contacts for the notification model's name lookup.
@MainActor
@Observable
private final class ContactsSlot {
    var store: ContactsStore?
}
