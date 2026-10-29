import AMProtocol
import AppKit
import FeatureBrowse
import FeatureFiles
import SwiftUI
import UniformTypeIdentifiers

/// The Phone window's Files tab: the phone's browse roots, one folder at a time, paged as the
/// list scrolls. Files drag out (fetched when dropped) and drop in (sent into the folder shown);
/// folders can be made, renamed and deleted where the root is writable.
struct FilesTab: View {
    let model: AppModel
    @State private var selection = Set<String>()
    @State private var naming: Naming?
    @State private var nameText = ""
    @State private var deleting: AMBrowseEntry?
    @State private var droppedFolders = false
    @State private var dropTargeted = false

    private var browse: BrowseModel { model.browse }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !browse.available {
                Text(model.statusText)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else if browse.phoneAvailability?.enabled == false || (browse.rootsLoaded && browse.roots.isEmpty) {
                noticeLine
                Text("Turn on file browsing in the phone app.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else if !browse.rootsLoaded {
                if browse.notice != nil {
                    noticeLine
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
                Spacer(minLength: 0)
            } else {
                toolbar
                pathBar
                noticeLine
                if droppedFolders {
                    Text("Folders can't be sent yet. Send the files inside instead.")
                        .foregroundStyle(.secondary)
                }
                list
            }
        }
        .padding(.top, 8)
        // Keyed on the model, not the server: it learns of a (re)connect through the session's queue.
        .task(id: browse.available) {
            if browse.available, !browse.rootsLoaded { browse.refreshRoots() }
        }
        .onChange(of: browse.roots.map(\.id)) { openFirstRootIfNone() }
        .onAppear { openFirstRootIfNone() }
        .onChange(of: browse.location) {
            selection = []
            droppedFolders = false
        }
        .alert(Text(naming?.title ?? ""), isPresented: isNaming, presenting: naming) { what in
            TextField("Name", text: $nameText)
            Button { commitName(what) } label: { Text(what.confirm) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(deleteTitle, isPresented: isDeleting, presenting: deleting) { entry in
            Button("Delete", role: .destructive) { Task { await browse.delete(entry) } }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text(entry.isDir
                 ? "This deletes the folder and everything in it from the phone. This can't be undone."
                 : "This deletes it from the phone. This can't be undone.")
        }
    }

    // MARK: toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(browse.roots, id: \.id) { root in
                    Button(root.name) { Task { await browse.open(BrowseLocation(rootID: root.id)) } }
                }
            } label: {
                Text(currentRoot?.name ?? String(localized: "Choose Folder"))
            }
            .fixedSize()
            .accessibilityLabel(Text("Phone folder"))
            Button {
                Task { await browse.up() }
            } label: {
                Label("Up", systemImage: "chevron.up")
            }
            .disabled(browse.location?.parent == nil)
            Spacer(minLength: 0)
            Button("New Folder") { startNaming(.newFolder) }
                .disabled(!writable)
            Button("Rename") { if let entry = selectedEntry { startNaming(.rename(entry)) } }
                .disabled(!writable || selectedEntry == nil)
            Button("Delete") { deleting = selectedEntry }
                .disabled(!writable || selectedEntry == nil)
        }
    }

    /// The root, then each folder of the path; each opens that folder.
    @ViewBuilder private var pathBar: some View {
        if let location = browse.location, let root = currentRoot {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    crumb(root.name, BrowseLocation(rootID: location.rootID))
                    ForEach(Array(location.segments.enumerated()), id: \.offset) { i, name in
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        crumb(name, BrowseLocation(rootID: location.rootID,
                                                   path: location.segments.prefix(i + 1).joined(separator: "/")))
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Path"))
        }
    }

    private func crumb(_ name: String, _ target: BrowseLocation) -> some View {
        Button(name) { Task { await browse.open(target) } }
            .buttonStyle(.link)
            .lineLimit(1)
            .disabled(target == browse.location)
    }

    @ViewBuilder private var noticeLine: some View {
        if let notice = browse.notice {
            Label { Text(Self.text(notice)) } icon: { Image(systemName: "exclamationmark.triangle") }
                .foregroundStyle(.secondary)
        }
    }

    // MARK: list

    private var list: some View {
        let rows = browse.entries.enumerated().map { Row(index: $0.offset, entry: $0.element) }
        let count = rows.count
        return Table(of: Row.self, selection: $selection) {
            TableColumn("Name") { row in
                Label {
                    Text(row.entry.name).lineLimit(1).truncationMode(.middle)
                } icon: {
                    Image(systemName: row.entry.isDir ? "folder" : "doc")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(Self.label(row.entry)))
                // The next page loads as the end of the loaded ones scrolls into view.
                .onAppear {
                    if row.index >= count - Self.prefetch { Task { await browse.loadMore() } }
                }
            }
            TableColumn("Size") { row in
                Text(row.entry.isDir ? "" : Self.size(row.entry.size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 80, max: 120)
            TableColumn("Modified") { row in
                Text(Self.date(row.entry.modifiedMs))
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 150, max: 220)
        } rows: {
            ForEach(rows) { row in
                // Folders do not drag out: only files can be fetched.
                TableRow(row).itemProvider { row.entry.isDir ? nil : provider(for: row.entry) }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let entry = entry(ids) {
                if entry.isDir {
                    Button("Open") { open(entry) }
                }
                if writable {
                    Button("Rename") { startNaming(.rename(entry)) }
                    Button("Delete") { deleting = entry }
                }
            }
        } primaryAction: { ids in
            if let entry = entry(ids), entry.isDir { open(entry) }
        }
        .onKeyPress(.return) {
            guard let entry = selectedEntry, entry.isDir else { return .ignored }
            open(entry)
            return .handled
        }
        .onDeleteCommand {
            if writable, let entry = selectedEntry { deleting = entry }
        }
        .overlay {
            if rows.isEmpty {
                if browse.loading {
                    ProgressView()
                } else if browse.location != nil {
                    Text("This folder is empty.").foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            drop(urls)
        } isTargeted: { dropTargeted = $0 && writable }
    }

    /// Rows past this many from the end start the next page.
    static let prefetch = 40

    // MARK: actions

    private var currentRoot: AMBrowseRoot? {
        guard let location = browse.location else { return nil }
        return browse.roots.first { $0.id == location.rootID }
    }

    private var writable: Bool { currentRoot?.writable ?? false }

    private var selectedEntry: AMBrowseEntry? { entry(selection) }

    /// The one entry named by `ids`; nil for none or several.
    private func entry(_ ids: Set<String>) -> AMBrowseEntry? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return browse.entries.first { $0.name == id }
    }

    private func open(_ entry: AMBrowseEntry) {
        guard let location = browse.location else { return }
        Task { await browse.open(location.appending(entry.name)) }
    }

    private func openFirstRootIfNone() {
        guard browse.location == nil, browse.notice == nil, let first = browse.roots.first else { return }
        Task { await browse.open(BrowseLocation(rootID: first.id)) }
    }

    private func drop(_ urls: [URL]) -> Bool {
        guard writable else { return false }
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        droppedFolders = SendableFiles.split(files).skipped > 0
        Task { await browse.upload(files) }
        return true
    }

    /// Drag-out: fetched from the folder shown when the drag began, once the drop lands.
    private func provider(for entry: AMBrowseEntry) -> NSItemProvider? {
        guard let folder = browse.location else { return nil }
        let browse = browse
        return FilePromise.provider(name: entry.name, type: Self.contentType(entry)) { url in
            await browse.download(entry, in: folder, to: url)
        }
    }

    private func startNaming(_ what: Naming) {
        if case let .rename(entry) = what { nameText = entry.name } else { nameText = "" }
        naming = what
    }

    private func commitName(_ what: Naming) {
        let name = nameText
        switch what {
        case .newFolder: Task { await browse.makeFolder(named: name) }
        case let .rename(entry): Task { await browse.rename(entry, to: name) }
        }
    }

    private var isNaming: Binding<Bool> {
        Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var deleteTitle: Text {
        Text("Delete “\(deleting?.name ?? "")”?")
    }

    // MARK: words

    static func text(_ notice: BrowseNotice) -> LocalizedStringResource {
        switch notice {
        case .revoked: "The phone no longer has access to this folder. Pick it again in the phone app."
        case .notFound: "It's no longer on the phone."
        case .denied: "The phone doesn't allow changes here."
        case .exists: "That name is taken, or files are still being copied into it."
        case .badName: "That name can't be used on the phone."
        case .failed: "The phone couldn't do that."
        case .timedOut: "The phone didn't answer."
        }
    }

    static func label(_ entry: AMBrowseEntry) -> LocalizedStringResource {
        entry.isDir ? "Folder, \(entry.name)" : "File, \(entry.name), \(size(entry.size))"
    }

    static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    static func date(_ ms: Int64) -> String {
        guard ms > 0 else { return "" }
        return Date(timeIntervalSince1970: Double(ms) / 1000).formatted(date: .abbreviated, time: .shortened)
    }

    /// The entry's type for a drag: from its MIME type, else its extension, else plain data.
    static func contentType(_ entry: AMBrowseEntry) -> UTType {
        if let type = UTType(mimeType: entry.mime), !type.isDynamic { return type }
        let ext = (entry.name as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic { return type }
        return .data
    }
}

/// One listed entry; entry names are unique within a folder.
private struct Row: Identifiable {
    let index: Int
    let entry: AMBrowseEntry
    var id: String { entry.name }
}

private enum Naming {
    case newFolder
    case rename(AMBrowseEntry)

    var title: LocalizedStringResource {
        switch self {
        case .newFolder: "New Folder"
        case .rename: "Rename"
        }
    }

    var confirm: LocalizedStringResource {
        switch self {
        case .newFolder: "Create"
        case .rename: "Rename"
        }
    }
}
