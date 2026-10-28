import AppKit
import AMProtocol
import ConnectionCore
import FeatureStatus
import Foundation
import Observation
import os

/// Owns the connection and the feature models. Feature models (phone status, ring) are added
/// here next to `server`; the views only read this object.
@MainActor
@Observable
final class AppModel {
    static let capabilities: Set<String> = ["status.v1", "find.v1"]
    /// A pairing code (and its QR) stays valid for this long. Matches the Mac server's lifetime.
    static let pairingLifetime: TimeInterval = 300

    let server: MacServer
    let phoneStatus = PhoneStatusModel()
    private(set) var pairedPhones: [PairedPhone] = []
    /// When the current QR code expires; nil when no pairing window is open.
    private(set) var pairingDeadline: Date?
    /// Set when pairing finished; shown by the pairing window.
    private(set) var pairedName: String?
    private(set) var pairingFailure: LocalizedStringResource?
    private(set) var startupError: String?

    @ObservationIgnored private let phoneStore: any PairedPhoneStore
    /// Held for the life of the process (the model is never deallocated).
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private static let portKey = "listenPort"
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
        server = MacServer(
            identity: KeychainIdentityProvider(),
            phones: store,
            secrets: KeychainSecretStore(),
            macName: Host.current().localizedName ?? "Mac",
            appVersion: version,
            capabilities: Self.capabilities
        )
        server.onEvent = { [weak self] event in self?.handle(event) }
        server.onMessage = { [weak self] envelope in self?.handle(message: envelope) }
        refreshPhones()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.server.handleWake() }
        }
        start()
    }

    // MARK: derived state

    var isConnected: Bool {
        if case .connected = server.state { return true }
        return false
    }

    /// The phone to show in the menu: the connected one, else the first paired one.
    var currentPhone: PairedPhone? {
        if case let .connected(phone, _) = server.state { return phone }
        return pairedPhones.first
    }

    var statusText: LocalizedStringResource {
        switch server.state {
        case .connected: "Connected"
        case .incompatible: "Update needed: app versions differ"
        case .pairing: "Pairing…"
        case .idle: pairedPhones.isEmpty ? "No phone paired" : "Not connected"
        }
    }

    var menuBarAccessibilityLabel: LocalizedStringResource {
        isConnected ? "Android Mirroring, phone connected" : "Android Mirroring, phone not connected"
    }

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
            refreshPhones()
            #if DEBUG
            Self.debugLine("connected \(phone.name) shared=\(shared.sorted())")
            #endif
        case let .disconnected(phone):
            phoneStatus.reset()
            #if DEBUG
            Self.debugLine("disconnected \(phone.name)")
            #endif
        case .unpaired:
            phoneStatus.reset()
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
        switch envelope.type {
        case MessageType.statusUpdate.rawValue:
            if let update = try? AMStatusUpdate(serializedBytes: envelope.payload) { phoneStatus.apply(update) }
        default:
            break
        }
    }

    private func refreshPhones() {
        pairedPhones = (try? phoneStore.all()) ?? []
    }
}
