import AppKit
import AMProtocol
import AppSession
import ConnectionCore
import CryptoKit
import FeatureBrowse
import FeatureCalls
import FeatureClipboard
import FeatureContacts
import FeatureFiles
import FeatureFind
import FeatureFocus
import FeatureInput
import FeatureMedia
import FeatureMirror
import FeatureNotify
import FeaturePhotos
import FeatureProximity
import FeatureScreenshots
import FeatureShare
import FeatureStatus
import Foundation
import Observation
import os

/// Owns the connection and the feature models. Feature models (phone status, ring) are added
/// here next to `server`; the views only read this object.
@MainActor
@Observable
final class AppModel {
    static let capabilities: Set<String> = [
        "status.v1", "find.v1", "notify.v1", "contacts.v1", "calls.v1", "clipboard.v1", "files.v1", "share.v1",
        "screenshots.v1", "photos.v1", "browse.v1", "media.v1", "dnd.v1",
        "proximity.v1", "input.v1", "liveness.v1", "mirror.v1",
    ]
    /// A pairing code (and its QR) stays valid for this long. Matches the Mac server's lifetime.
    static let pairingLifetime: TimeInterval = 300

    let server: MacServer
    let phoneStatus = PhoneStatusModel()
    let ring = RingModel()
    let notifications: NotificationsModel
    let calls: CallModel
    let clipboard: ClipboardModel
    /// File transfers both ways; received files go to Downloads.
    let transfers: TransferEngine
    /// Links and text shared both ways.
    let share: ShareModel
    /// Phone screenshots, saved where Settings says and announced with a thumbnail.
    let screenshots: ScreenshotInbox
    /// The phone's newest photos and videos for the Phone window; thumbnails in memory only.
    let photos: PhotosModel
    /// The phone's files for the Phone window's Files tab.
    let browse: BrowseModel
    /// The phone's media session, in macOS Now Playing, the menu and the Phone window's Now Playing tab.
    let media: MediaModel
    /// Focus on this Mac and Do Not Disturb on the phone, kept in step ("Sync Focus" in Settings).
    let focus: FocusModel
    /// Locks this Mac when the chosen phone is away ("Auto-Lock" in Settings). Runs whether or not
    /// the phone is connected.
    let proximity: ProximityModel
    /// The phone as trackpad and remote ("Trackpad and Remote" in Settings).
    let input: InputModel
    /// The phone's screen in a window of its own ("Show Phone Screen").
    let mirror: MirrorModel
    /// "Save phone screenshots to" in Settings (default Desktop).
    private(set) var screenshotDestination: ScreenshotDestination = .saved(in: .standard)
    /// Whether phone calls show on this Mac (default on). Off ignores call states and missed calls.
    private(set) var showPhoneCalls: Bool = AppModel.savedShowPhoneCalls
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
    @ObservationIgnored private let screenshotFolders: (desktop: URL, downloads: URL, temp: URL)
    /// The second listener, for transfer bytes (SPEC section 13); runs alongside `server`.
    @ObservationIgnored private let bulk: BulkServer
    @ObservationIgnored private let notificationPresenter: UserNotificationPresenter
    @ObservationIgnored private let icons: IconCache
    @ObservationIgnored private var callPanels: IncomingCallPanels?
    /// The connected phone's contacts, loaded while it is connected and shares contacts.v1.
    @ObservationIgnored private let contacts: ContactsSession
    /// Everything that reaches the notification, contacts and calls models goes through here, so it
    /// is handled one at a time in arrival order.
    @ObservationIgnored private let notifyWork: NotifyWorkQueue
    @ObservationIgnored private var activeObserver: NSObjectProtocol?
    #if FULL_BUILD
    /// The Finder sidebar's phone and the Share menu's outbox; nil when the build has no App Group.
    @ObservationIgnored private var fileProviderBridge: FileProviderBridge?
    @ObservationIgnored private var shareOutbox: ShareOutbox?
    #endif
    /// Held for the life of the process (the model is never deallocated).
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// Ends a mirror session before the Mac sleeps; held for the life of the process.
    @ObservationIgnored private var sleepObserver: NSObjectProtocol?
    /// The mirror window, made the first time it is shown; it makes each session's sink.
    @ObservationIgnored private let mirrorWindow = MirrorWindowHost()
    @ObservationIgnored private static let portKey = "listenPort"
    @ObservationIgnored private static let contactsKey = "contactsForNames"
    @ObservationIgnored private static let callsKey = "showPhoneCalls"
    @ObservationIgnored private static let clipboardKey = "sendMacClipboard"
    @ObservationIgnored private static let syncFocusKey = "syncFocus"
    @ObservationIgnored private static let pointerControlKey = "allowPointerControl"
    private static var savedShowPhoneCalls: Bool {
        UserDefaults.standard.object(forKey: callsKey) as? Bool ?? true
    }
    private static var savedSendMacClipboard: Bool {
        UserDefaults.standard.object(forKey: clipboardKey) as? Bool ?? true
    }
    private static var savedSyncFocus: Bool {
        UserDefaults.standard.object(forKey: syncFocusKey) as? Bool ?? false
    }
    private static var savedAllowPointerControl: Bool {
        UserDefaults.standard.object(forKey: pointerControlKey) as? Bool ?? false
    }
    private static var savedContactsForNames: Bool {
        UserDefaults.standard.object(forKey: contactsKey) as? Bool ?? true
    }
    @ObservationIgnored private static let appLog = Logger(subsystem: "io.github.anmirror.mac", category: "app")
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
        let contacts = ContactsSession(
            enabled: Self.savedContactsForNames,
            open: { phoneID in
                let key = try ContactsKey.load(phoneID: phoneID)
                let url = ContactsStore.fileURL(phoneID: phoneID, in: ContactsStore.defaultDirectory)
                return ContactsStore(file: EncryptedFile(url: url, key: key))
            },
            remove: { Self.removeContacts(phoneID: $0) },
            pairedPhoneIDs: { ((try? store.all()) ?? []).map(\.id) },
            requestSync: { since in
                // Only a phone that shares contacts.v1 gets contacts messages.
                guard server.activePhone?.shared.contains("contacts.v1") == true else { return }
                var request = AMContactsSyncRequest()
                request.sinceMs = since
                try? await server.send(.contactsSync, request, channel: .contacts)
            }
        )
        self.contacts = contacts
        let model = NotificationsModel(
            presenter: presenter, icons: icons,
            load: { Self.loadNotifySettings(phoneID: $0) },
            save: { Self.saveNotifySettings($1, phoneID: $0) },
            copy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            nameFor: { contacts.name(forNumber: $0) },
            send: { type, message in
                // Only a phone that shares notify.v1 gets notify messages.
                guard server.activePhone?.shared.contains("notify.v1") == true else { return }
                try? await server.send(type, message, channel: .notify)
            }
        )
        notifications = model
        let calls = CallModel(
            nameFor: { contacts.name(forNumber: $0) }, presenter: presenter,
            send: { type, message in
                // Only a phone that shares calls.v1 gets calls messages.
                guard server.activePhone?.shared.contains("calls.v1") == true else { return }
                try? await server.send(type, message, channel: .calls)
            }
        )
        self.calls = calls
        notifyWork = NotifyWorkQueue(notifications: model, calls: calls, contacts: contacts)
        let clipboard = ClipboardModel(
            pasteboard: SystemPasteboard(), sendEnabled: Self.savedSendMacClipboard,
            send: { type, message in
                // Only a phone that shares clipboard.v1 gets clipboard messages.
                guard server.activePhone?.shared.contains("clipboard.v1") == true else { return }
                try? await server.send(type, message, channel: .clipboard)
            }
        )
        self.clipboard = clipboard
        // Clipboard-mode files and thumbnail copies a previous run left behind.
        let folders = Self.makeScreenshotFolders()
        screenshotFolders = folders
        try? FileManager.default.removeItem(at: folders.temp)
        let screenshots = ScreenshotInbox(
            presenter: presenter,
            destination: { .saved(in: .standard) },
            folders: folders,
            writeImage: { url in
                guard let image = NSImage(contentsOf: url) else { return false }
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.writeObjects([image])
            },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        )
        self.screenshots = screenshots
        let bulk = BulkServer(identity: KeychainIdentityProvider())
        self.bulk = bulk
        let transfers = TransferEngine(
            bulk: bulk,
            send: { type, message in
                // files.* serve every bulk feature; only a phone that shares one of them gets them.
                guard let shared = server.activePhone?.shared,
                      !shared.isDisjoint(with: TransferEngine.bulkCapabilities) else { return }
                try? await server.send(type, message, channel: .files)
            },
            destination: { Self.destination(for: $0, screenshots: screenshots) },
            // Part files a crash or force quit left in Downloads or Desktop go at launch.
            partsStore: .standard
        )
        self.transfers = transfers
        let browse = BrowseModel(
            engine: transfers,
            send: { type, message in
                // Only a phone that shares browse.v1 gets browse messages.
                guard server.activePhone?.shared.contains("browse.v1") == true else { return }
                try? await server.send(type, message, channel: .browse)
            }
        )
        self.browse = browse
        transfers.onFinished = { item, _, url in
            // Every ending comes here; the inbox looks at the state (only a done one is saved and shown).
            // An upload from the Files tab reloads the folder it went into.
            browse.transferFinished(item)
            guard item.kind == .screenshot else { return }
            Task { await screenshots.finished(item, at: url) }
        }
        let photos = PhotosModel(
            engine: transfers, bulk: bulk,
            send: { type, message in
                // Only a phone that shares photos.v1 gets photos messages.
                guard server.activePhone?.shared.contains("photos.v1") == true else { return }
                try? await server.send(type, message, channel: .photos)
            },
            downloads: folders.downloads
        )
        self.photos = photos
        // Drag-out files a previous run left behind.
        try? FileManager.default.removeItem(at: FilePromise.folder)
        let mirrorWindow = mirrorWindow
        let mirror = MirrorModel(
            bulk: bulk,
            send: { type, message in
                // Only a phone that shares mirror.v1 gets mirror messages.
                guard server.activePhone?.shared.contains("mirror.v1") == true else { return }
                try? await server.send(type, message, channel: .mirror)
            },
            makeSink: { mirrorWindow.makeSink() }
        )
        self.mirror = mirror
        // Thumbnail streams go to the photos model, the mirror streams to the mirror model (never
        // through the session's work queue); the transfer roles to the engine.
        bulk.onLink = { [weak transfers, weak photos, weak mirror] pipe, grant in
            switch grant.role {
            case .thumbnails:
                if let photos { Task { await photos.thumbnailLink(pipe) } } else { pipe.close() }
            case .mirrorVideo, .mirrorAudio, .mirrorControl:
                if let mirror { mirror.link(pipe, grant: grant) } else { pipe.close() }
            default:
                if let transfers { transfers.link(pipe, grant: grant) } else { pipe.close() }
            }
        }
        // After wake the port may change, and the phone may be back before it is ready.
        bulk.onPortChange = { [weak transfers] _ in transfers?.bulkPortChanged() }
        let share = ShareModel(
            clipboard: clipboard, presenter: presenter,
            openURL: { NSWorkspace.shared.open($0) },
            send: { type, message in
                // Only a phone that shares share.v1 gets share messages.
                guard server.activePhone?.shared.contains("share.v1") == true else { return }
                try? await server.send(type, message, channel: .share)
            }
        )
        self.share = share
        let media = MediaModel(
            center: SystemNowPlaying(),
            send: { type, message in
                // Only a phone that shares media.v1 gets media messages.
                guard server.activePhone?.shared.contains("media.v1") == true else { return }
                try? await server.send(type, message, channel: .media)
            }
        )
        self.media = media
        let focus = FocusModel(
            reader: SystemFocusReader(), shortcuts: SystemShortcuts(), enabled: Self.savedSyncFocus,
            send: { type, message in
                // Only a phone that shares dnd.v1 gets dnd messages.
                guard server.activePhone?.shared.contains("dnd.v1") == true else { return }
                try? await server.send(type, message, channel: .dnd)
            }
        )
        self.focus = focus
        let proximity = ProximityModel(
            scanner: CoreBluetoothScanner(), locker: LoginFrameworkLocker(), activity: SystemMacActivity(),
            defaults: .standard
        )
        self.proximity = proximity
        let input = InputModel(
            poster: CGEventPoster(), laser: LaserOverlayPanel(), trust: SystemAccessibilityTrust(),
            enabled: Self.savedAllowPointerControl,
            naturalScrolling: { InputModel.naturalScrolling() },
            send: { type, message in
                // Only a phone that shares input.v1 gets input messages.
                guard server.activePhone?.shared.contains("input.v1") == true else { return }
                try? await server.send(type, message, channel: .input)
            },
            doubleClickInterval: NSEvent.doubleClickInterval
        )
        self.input = input
        notifyWork.register(clipboard)
        notifyWork.register(transfers)
        notifyWork.register(share)
        notifyWork.register(screenshots)
        notifyWork.register(photos)
        notifyWork.register(browse)
        notifyWork.register(media)
        notifyWork.register(focus)
        notifyWork.register(proximity)
        notifyWork.register(input)
        // Only mirror.* control-channel messages go through the queue; mirror bytes ride the bulk links.
        notifyWork.register(mirror)
        #if FULL_BUILD
        // After the models they use, so those are connected first.
        if let group = AppGroup.id, let container = AppGroup.container {
            let paired: @MainActor () -> Set<String> = { Set(((try? store.all()) ?? []).map(\.id)) }
            let bridge = FileProviderBridge(browse: browse, container: container, presenter: presenter,
                                            reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
                                            pairedPhoneIDs: paired)
            let outbox = ShareOutbox(container: container, defaults: UserDefaults(suiteName: group),
                                     transfers: transfers, share: share, pairedPhoneIDs: paired)
            notifyWork.register(bridge)
            notifyWork.register(outbox)
            // The outbox's own copies of shared files go once their transfer ends.
            let finished = transfers.onFinished
            transfers.onFinished = { item, offer, url in
                finished?(item, offer, url)
                outbox.transferFinished(item)
            }
            fileProviderBridge = bridge
            shareOutbox = outbox
        }
        #endif
        calls.enabled = showPhoneCalls
        callPanels = IncomingCallPanels(model: calls)
        server.onEvent = { [weak self] event in self?.handle(event) }
        server.onMessage = { [weak self] envelope in self?.handle(message: envelope) }
        #if FULL_BUILD
        let fileProviderBridge = fileProviderBridge
        #endif
        presenter.onResponse = { actionID, userInfo, reply in
            if screenshots.handleResponse(userInfo: userInfo) { return }
            #if FULL_BUILD
            if fileProviderBridge?.handleResponse(userInfo: userInfo) == true { return }
            #endif
            await model.handleResponse(actionID: actionID, userInfo: userInfo, replyText: reply)
        }
        // The user may allow notifications, Focus status or Accessibility in System Settings and come back.
        // Delivered on the main queue, so the main-actor work runs under assumeIsolated.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if model.authorized == false { Task { await model.refreshAuthorization() } }
                Task { await focus.refreshAuthorization() }
                Task { await input.recheckTrust() }
            }
        }
        refreshPhones()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.server.handleWake()
                self?.bulk.handleWake()
            }
        }
        // The session ends and its links close right here, before the Mac sleeps.
        sleepObserver = MacSleepObserver.install { [weak self] in self?.mirror.macWillSleepNow() }
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

    /// Phone calls are offered only while the connected phone shares `calls.v1`.
    var canCall: Bool { server.activePhone?.shared.contains("calls.v1") ?? false }

    /// Clipboard sync runs only while the connected phone shares `clipboard.v1`.
    var canClipboard: Bool { server.activePhone?.shared.contains("clipboard.v1") ?? false }

    /// Sending files is offered only while the connected phone shares `files.v1`.
    var canSendFiles: Bool { server.activePhone?.shared.contains("files.v1") ?? false }

    /// Sending links, text and the clipboard is offered only while the connected phone shares `share.v1`.
    var canShare: Bool { server.activePhone?.shared.contains("share.v1") ?? false }

    /// Phone screenshots arrive only while the connected phone shares `screenshots.v1`.
    var canScreenshots: Bool { server.activePhone?.shared.contains("screenshots.v1") ?? false }

    /// Phone photos are browsed only while the connected phone shares `photos.v1`.
    var canPhotos: Bool { server.activePhone?.shared.contains("photos.v1") ?? false }

    /// The phone's media is shown and controlled only while the connected phone shares `media.v1`.
    var canMedia: Bool { server.activePhone?.shared.contains("media.v1") ?? false }

    /// What the phone is playing, for the menu and the Now Playing tab; nil when nothing is.
    var nowPlaying: AMMediaState? {
        guard isConnected, canMedia, let state = media.state, state.active else { return nil }
        return state
    }

    /// Why the last thing the user sent (dropped, picked, or the clipboard) did not all go.
    /// Shown in the menu and the Send tab until the next send, connect or disconnect.
    private(set) var sendNotes: [SendNote] = []

    /// "Send File to Phone…": any number of files. Packages can be picked like files; they and
    /// folders are not sent.
    func chooseFilesToSend() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let self else { return }
                self.sendNotes = self.send(fileURLs: panel.urls)
            }
        }
    }

    /// "Send Clipboard to Phone".
    func sendClipboard() async {
        sendNotes = []
        if let note = SendNote(await share.sendClipboard(), fromClipboard: true) { sendNotes = [note] }
    }

    /// A drop on the Send tab: files to the transfer engine, a web link as `share.link`,
    /// anything else as `share.text`, each only when the phone shares that feature.
    func drop(_ items: [DroppedItem]) -> Bool {
        guard isConnected else { return false }
        var fileURLs: [URL] = []
        var shared: [DroppedItem] = []
        for item in items {
            if case let .url(url) = item, url.isFileURL { fileURLs.append(url) } else { shared.append(item) }
        }
        sendNotes = fileURLs.isEmpty ? [] : send(fileURLs: fileURLs)
        guard canShare, !shared.isEmpty else { return !fileURLs.isEmpty }
        let share = share
        Task { [weak self] in
            // In the order dropped.
            for item in shared {
                var note: SendNote?
                switch item {
                case let .url(url):
                    await share.sendLink(url)
                case let .text(text) where text.isEmpty:
                    note = .nothingToSend
                case let .text(text):
                    if let link = LinkRules.link(text) {
                        await share.sendLink(link)
                    } else {
                        note = SendNote(await share.sendText(text), fromClipboard: false)
                    }
                }
                if let note, let self, !self.sendNotes.contains(note) { self.sendNotes.append(note) }
            }
        }
        return true
    }

    /// Sends the files among `urls`; returns why some did not go.
    private func send(fileURLs urls: [URL]) -> [SendNote] {
        let split = SendableFiles.split(urls)
        var notes: [SendNote] = split.skipped > 0 ? [.folders] : []
        if !split.files.isEmpty {
            if canSendFiles {
                transfers.send(files: split.files)
            } else if isConnected {
                notes.append(.filesOff)
            } else {
                notes.append(.notConnected)
            }
        }
        return notes
    }

    /// The "Send Mac clipboard to the phone" switch in Settings.
    var sendMacClipboard: Bool { clipboard.sendEnabled }

    func setSendMacClipboard(_ on: Bool) {
        guard on != clipboard.sendEnabled else { return }
        clipboard.sendEnabled = on
        UserDefaults.standard.set(on, forKey: Self.clipboardKey)
    }

    /// The "Sync Focus with <phone>" switch in Settings (default off), as last clicked. Turning
    /// it on asks for Focus status access, and only then.
    private(set) var syncFocus: Bool = AppModel.savedSyncFocus

    /// Each click applies the latest value when its task runs, so the last click wins however
    /// quickly the switch is toggled (the model drops a call that a later one overtakes).
    func setSyncFocus(_ on: Bool) {
        guard on != syncFocus else { return }
        syncFocus = on
        UserDefaults.standard.set(on, forKey: Self.syncFocusKey)
        Task { [weak self] in
            guard let self else { return }
            await self.focus.setEnabled(self.syncFocus)
        }
    }

    /// The "Allow <phone> to control the pointer" switch in Settings (default off), as last
    /// clicked. Turning it on asks for Accessibility, and only then.
    private(set) var allowPointerControl: Bool = AppModel.savedAllowPointerControl

    /// Each click applies the latest value when its task runs, so the last click wins.
    func setAllowPointerControl(_ on: Bool) {
        guard on != allowPointerControl else { return }
        allowPointerControl = on
        UserDefaults.standard.set(on, forKey: Self.pointerControlKey)
        // Off takes effect now, before anything is awaited: nothing stays held, the laser goes.
        if !on { input.disable() }
        Task { [weak self] in
            guard let self else { return }
            await self.input.setEnabled(self.allowPointerControl)
        }
    }

    /// "Save phone screenshots to" in Settings. Applies from the next screenshot offered.
    func setScreenshotDestination(_ destination: ScreenshotDestination) {
        guard destination != screenshotDestination else { return }
        screenshotDestination = destination
        UserDefaults.standard.set(destination.rawValue, forKey: ScreenshotDestination.defaultsKey)
        askForScreenshotFolderAccess()
    }

    /// Looks into the screenshot folder off the main actor, so macOS asks for Desktop or Downloads
    /// access now rather than when the first screenshot arrives (the engine writes on the main
    /// actor, and a prompt there would hold up everything behind it).
    private func askForScreenshotFolderAccess() {
        let folder: URL
        switch screenshotDestination {
        case .desktop: folder = screenshotFolders.desktop
        case .downloads: folder = screenshotFolders.downloads
        case .clipboard: return
        }
        Task.detached(priority: .utility) { _ = try? FileManager.default.contentsOfDirectory(atPath: folder.path) }
    }

    /// The "Show phone calls" switch in Settings.
    func setShowPhoneCalls(_ on: Bool) {
        guard on != showPhoneCalls else { return }
        showPhoneCalls = on
        UserDefaults.standard.set(on, forKey: Self.callsKey)
        calls.enabled = on
    }

    /// How many contacts the connected phone has shared; 0 when none are loaded.
    var contactsCount: Int { contacts.count }

    /// The "Use phone contacts for caller names" switch in Settings.
    func setContactsForNames(_ on: Bool) {
        guard on != contactsForNames else { return }
        contactsForNames = on
        UserDefaults.standard.set(on, forKey: Self.contactsKey)
        notifyWork.yield(.contactsToggled(on))
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

    // MARK: mirroring

    /// "Show Phone Screen" is offered while the connected phone can show its screen now.
    var canMirror: Bool { isConnected && mirror.canStart }

    /// The menu notice when the connected phone can't show its screen; nil otherwise.
    var mirrorNotice: String? {
        guard isConnected else { return nil }
        return MirrorCopy.notice(mirror.phoneAvailability)
    }

    /// "Show Phone Screen": opens the mirror window, and starts a session unless one is already
    /// starting or running (then the window just comes forward).
    func showMirror() {
        let controller = mirrorWindow.controller(model: mirror, title: { [weak self] in
            self?.currentPhone?.name ?? ""
        })
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        switch mirror.phase {
        case .starting, .running: break
        case .idle, .ended: Task { await mirror.start() }
        }
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
    /// Transfers end here, not through the session's work queue (it never drains while the app
    /// terminates), so a receive under way leaves no part file behind.
    func shutdown() {
        // A button the phone holds is let go, and the laser hidden, before the process ends.
        input.shutdown()
        let hadPhone = server.activePhone != nil
        server.stop()
        transfers.shutdown()
        bulk.stop()
        if hadPhone { Thread.sleep(forTimeInterval: 0.25) }
    }

    private func start() {
        let saved = UserDefaults.standard.integer(forKey: Self.portKey)
        do {
            try server.start(port: UInt16(exactly: saved))
        } catch {
            startupError = String(describing: error)
        }
        do {
            try bulk.start()
        } catch {
            // Transfers stay unavailable; the phone gets no files.endpoint.
            Self.appLog.error("bulk listener did not start: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// Phone files go to Downloads; screenshots where the inbox says (it refuses them unless the
    /// phone shares `screenshots.v1`). Other kinds belong to features this Mac does not have yet,
    /// and are refused.
    private static func destination(for offer: AMTransferOffer, screenshots: ScreenshotInbox) -> IncomingDestination {
        switch offer.kind {
        case .file:
            guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            else { return .refuse(.disabled) }
            return .folder(downloads)
        case .screenshot:
            return screenshots.incomingDestination(for: offer)
        default:
            return .refuse(.disabled)
        }
    }

    /// Desktop and Downloads, and a temp folder for Clipboard mode and notification thumbnails.
    private static func makeScreenshotFolders() -> (desktop: URL, downloads: URL, temp: URL) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        return (
            desktop: fm.urls(for: .desktopDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Desktop"),
            downloads: fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? home.appendingPathComponent("Downloads"),
            temp: fm.temporaryDirectory.appendingPathComponent("io.github.anmirror.mac/screenshots", isDirectory: true)
        )
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
            sendNotes = []
            phoneStatus.reset() // never show the previous session's values
            ring.clearHint()
            notifyWork.handle(event)
            refreshPhones()
            if shared.contains("screenshots.v1") { askForScreenshotFolderAccess() }
            #if DEBUG
            Self.debugLine("connected \(phone.name) shared=\(shared.sorted())")
            #endif
        case let .disconnected(phone):
            sendNotes = []
            phoneStatus.reset()
            ring.reset()
            notifyWork.handle(event)
            #if DEBUG
            Self.debugLine("disconnected \(phone.name)")
            #endif
        case let .unpaired(phone):
            // Forgetting a phone that is not the connected one leaves the live session alone.
            if notifyWork.connectedPhoneID == nil || notifyWork.connectedPhoneID == phone.id {
                phoneStatus.reset()
                ring.reset()
            }
            // Ends the session if it was the connected phone; always wipes what this Mac holds of it.
            notifyWork.handle(event)
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
        if notifyWork.handle(message: envelope) { return }
        switch envelope.type {
        case MessageType.statusUpdate.rawValue:
            if let update = try? AMStatusUpdate(serializedBytes: envelope.payload) { phoneStatus.apply(update) }
        case MessageType.findState.rawValue:
            if let state = try? AMRingState(serializedBytes: envelope.payload) { ring.apply(state) }
        default:
            break
        }
    }

    // MARK: contacts

    /// Deletes a phone's store file and its key.
    private static func removeContacts(phoneID: String) {
        try? FileManager.default.removeItem(at: ContactsStore.fileURL(phoneID: phoneID, in: ContactsStore.defaultDirectory))
        try? ContactsKey.delete(phoneID: phoneID)
    }

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
        proximity.setPhones(pairedPhones, discoveryKey: try? KeychainSecretStore().discoveryKey())
    }
}

/// Why something the user sent did not (all) go.
enum SendNote: Equatable {
    /// Folders and packages are not sent.
    case folders
    /// Files were dropped, but the phone does not take files.
    case filesOff
    case clipboardEmpty
    /// Empty text was dropped.
    case nothingToSend
    case tooLarge
    case notConnected

    /// The note for a text send's outcome; nil when it went.
    init?(_ outcome: ClipboardSendOutcome, fromClipboard: Bool) {
        switch outcome {
        case .sent: return nil
        case .empty: self = fromClipboard ? .clipboardEmpty : .nothingToSend
        case .tooLarge: self = .tooLarge
        case .notConnected: self = .notConnected
        }
    }

    var text: LocalizedStringResource {
        switch self {
        case .folders: "Folders can't be sent yet. Send the files inside instead."
        case .filesOff: "Update the phone app to send files."
        case .clipboardEmpty: "The clipboard is empty."
        case .nothingToSend: "Nothing to send."
        case .tooLarge: "The text is too long to send."
        case .notConnected: "Your phone isn't connected. Nothing was sent."
        }
    }
}
