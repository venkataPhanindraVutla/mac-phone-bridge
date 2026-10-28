import AMProtocol
import Foundation
import Observation
import os

/// The connected phone's contacts on this Mac: loads its store while it is connected and shares
/// contacts.v1, asks for what is missing, applies batches, and wipes stores when sharing ends.
/// Every method is called from the app's ordered work stream, one at a time.
@MainActor
@Observable
public final class ContactsSession {
    private static let log = Logger(subsystem: "io.github.anmirror.mac", category: "contacts")

    /// The loaded store; nil while no phone is connected, the switch is off, or the phone does not share.
    public private(set) var store: ContactsStore?
    /// The phone `store` belongs to.
    public private(set) var storePhoneID: String?
    /// The connected phone that shares contacts.v1, nil otherwise.
    @ObservationIgnored public private(set) var connectedPhoneID: String?
    /// The phone's last `contacts.availability`; nil until the first one of this connection.
    @ObservationIgnored private var phoneEnabled: Bool?

    /// The Mac's "Use phone contacts for caller names" switch, as of the work handled so far.
    @ObservationIgnored public private(set) var enabled: Bool
    @ObservationIgnored private let open: (String) throws -> ContactsStore
    @ObservationIgnored private let remove: (String) -> Void
    @ObservationIgnored private let pairedPhoneIDs: () -> [String]
    @ObservationIgnored private let requestSync: @MainActor (Int64) async -> Void

    /// - Parameters:
    ///   - enabled: the Mac's "Use phone contacts for caller names" switch at launch.
    ///   - open: loads (or creates) a phone's store.
    ///   - remove: deletes a phone's store file and key, whether or not it is loaded.
    ///   - requestSync: sends `contacts.sync` with this `since_ms` to the connected phone.
    public init(
        enabled: Bool,
        open: @escaping (String) throws -> ContactsStore,
        remove: @escaping (String) -> Void,
        pairedPhoneIDs: @escaping () -> [String],
        requestSync: @escaping @MainActor (Int64) async -> Void
    ) {
        self.enabled = enabled
        self.open = open
        self.remove = remove
        self.pairedPhoneIDs = pairedPhoneIDs
        self.requestSync = requestSync
    }

    /// Contacts in the loaded store; 0 when none is loaded.
    public var count: Int { store?.count ?? 0 }

    public func name(forNumber raw: String) -> String? { store?.name(forNumber: raw) }

    // MARK: Session

    public func connected(phoneID: String) async {
        connectedPhoneID = phoneID
        phoneEnabled = nil
        guard enabled else { return }
        await openStore(phoneID: phoneID)
    }

    public func disconnected() {
        // Decrypted contacts stay in memory only while the phone is connected.
        unload()
        connectedPhoneID = nil
        phoneEnabled = nil
    }

    public func message(_ envelope: AMEnvelope) async {
        switch envelope.type {
        case MessageType.contactsBatch.rawValue:
            guard enabled, let store, let batch = try? AMContactsBatch(serializedBytes: envelope.payload) else { return }
            do { try store.apply(batch) } catch {
                Self.log.error("contacts batch not stored: \(String(describing: error), privacy: .public)")
            }
        case MessageType.contactsAvailability.rawValue:
            guard let a = try? AMFeatureAvailability(serializedBytes: envelope.payload),
                  let phoneID = connectedPhoneID else { return }
            let before = phoneEnabled
            phoneEnabled = a.enabled
            // Recorded even while this Mac's switch is off, so turning it on knows what the phone said.
            if !a.enabled {
                // The phone stopped sharing (switch off or permission gone): nothing of it stays here.
                wipe(phoneID: phoneID)
            } else if before == false, enabled {
                // Sharing came back: start again from nothing.
                await openStore(phoneID: phoneID)
            }
        default:
            break
        }
    }

    /// The Mac's switch changed. The value travels with the work, so a quick off-then-on still wipes.
    public func toggled(on: Bool) async {
        enabled = on
        if on {
            // Not while the phone says it does not share: it would not answer.
            if let phoneID = connectedPhoneID, phoneEnabled != false { await openStore(phoneID: phoneID) }
        } else {
            unload(wiping: true)
            for id in pairedPhoneIDs() { remove(id) }
        }
    }

    /// The phone was forgotten: its store goes. Another phone's loaded store is left alone.
    public func forget(phoneID: String) {
        wipe(phoneID: phoneID)
    }

    // MARK: Helpers

    /// Loads the phone's store and asks for what it lacks.
    private func openStore(phoneID: String) async {
        if store == nil || storePhoneID != phoneID {
            unload()
            do {
                store = try open(phoneID)
                storePhoneID = phoneID
            } catch {
                Self.log.error("contacts store unavailable: \(String(describing: error), privacy: .public)")
                return
            }
        }
        guard let store else { return }
        await requestSync(store.syncMs)
    }

    private func wipe(phoneID: String) {
        if storePhoneID == phoneID { unload(wiping: true) }
        remove(phoneID)
    }

    private func unload(wiping: Bool = false) {
        store?.abandonSync()
        if wiping { try? store?.wipe() }
        store = nil
        storePhoneID = nil
    }
}
