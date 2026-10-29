import AMProtocol
import FeatureClipboard
import FeatureFiles
import FeatureShare
import SwiftUI
import UniformTypeIdentifiers

/// The Phone window's Send tab: a drop zone for files, links and text, and the transfer list.
struct SendTab: View {
    let model: AppModel
    @State private var targeted = false
    @State private var folderDropped = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isConnected, let phone = model.currentPhone, model.canSendFiles || model.canShare {
                dropZone(phone: phone.name)
                if folderDropped {
                    Text("Folders can't be sent yet. Send the files inside instead.")
                        .foregroundStyle(.secondary)
                }
                if let note = TransferText.note(model.share.lastOutcome) {
                    Text(note).foregroundStyle(.secondary)
                }
                HStack {
                    if model.canSendFiles {
                        Button("Send File to Phone…") { model.chooseFilesToSend() }
                    }
                    if model.canShare {
                        Button("Send Clipboard to Phone") { Task { await model.share.sendClipboard() } }
                    }
                }
            } else {
                Text(model.statusText)
                    .foregroundStyle(.secondary)
            }
            transferList
        }
        .padding(.top, 8)
        .onChange(of: model.isConnected) { folderDropped = false }
    }

    private func dropZone(phone: String) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
            .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
            .background(RoundedRectangle(cornerRadius: 10).fill(targeted ? Color.accentColor.opacity(0.08) : .clear))
            .overlay {
                Text("Drop files to send to \(phone)")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding()
            }
            .frame(minHeight: 140)
            .accessibilityElement(children: .combine)
            .dropDestination(for: DroppedItem.self) { items, _ in
                drop(items)
            } isTargeted: { targeted = $0 }
    }

    @ViewBuilder private var transferList: some View {
        let items = model.transfers.transfers
        if !items.isEmpty {
            List(items) { item in
                TransferRow(item: item) { model.transfers.cancel(item.id) }
            }
            .listStyle(.inset)
        } else {
            Spacer(minLength: 0)
        }
    }

    /// Files go to the transfer engine, a web link as `share.link`, anything else as `share.text`.
    /// Folders are not sent, nor anything the phone does not share a feature for.
    private func drop(_ items: [DroppedItem]) -> Bool {
        guard model.isConnected else { return false }
        var files: [URL] = []
        var shared: [DroppedItem] = []
        var folder = false
        for item in items {
            switch item {
            case let .url(url) where url.isFileURL:
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    folder = true
                } else {
                    files.append(url)
                }
            case .url, .text:
                shared.append(item)
            }
        }
        folderDropped = folder
        var taken = folder
        if model.canSendFiles, !files.isEmpty {
            model.transfers.send(files: files)
            taken = true
        }
        if model.canShare, !shared.isEmpty {
            let share = model.share
            Task {
                // In the order dropped.
                for item in shared {
                    switch item {
                    case let .url(url):
                        await share.sendLink(url)
                    case let .text(text):
                        if let link = LinkRules.link(text) { await share.sendLink(link) } else { await share.sendText(text) }
                    }
                }
            }
            taken = true
        }
        return taken
    }
}

/// What can be dropped on the zone: a URL (a file, or a web link) or plain text.
enum DroppedItem: Transferable {
    case url(URL)
    case text(String)

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { (url: URL) in DroppedItem.url(url) }
        ProxyRepresentation { (text: String) in DroppedItem.text(text) }
    }
}

/// One transfer: its name and progress with Cancel while under way, how it ended once over.
struct TransferRow: View {
    let item: TransferItem
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(TransferText.title(item))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !item.isFinal {
                    ProgressView(value: TransferText.fraction(item))
                        .accessibilityHidden(true)
                } else if let reason = TransferText.reason(item) {
                    Text(reason)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if !item.isFinal {
                Button("Cancel", action: cancel)
                    .accessibilityLabel(Text(TransferText.cancelLabel(item)))
            }
        }
        .padding(.vertical, 2)
    }
}

/// The words for transfers, shared by the Send tab and the menu. Only `item.name` (the
/// sanitized name) is ever shown.
enum TransferText {
    static func percent(_ item: TransferItem) -> Int {
        guard item.size > 0 else { return item.isFinal ? 100 : 0 }
        return Int((Double(min(item.done, item.size)) / Double(item.size) * 100).rounded(.down))
    }

    static func fraction(_ item: TransferItem) -> Double { Double(percent(item)) / 100 }

    /// "Sending <name> · 40%" while under way, "Couldn't send <name>." once failed.
    static func title(_ item: TransferItem) -> LocalizedStringResource {
        let name = item.name
        switch (item.state, item.direction) {
        case (.queued, .send), (.waiting, .send), (.active, .send):
            return "Sending \(name) · \(percent(item))%"
        case (.queued, .receive), (.waiting, .receive), (.active, .receive):
            return "Receiving \(name) · \(percent(item))%"
        case (.done, .send):
            return "Sent \(name)"
        case (.done, .receive):
            return "Received \(name)"
        case (.failed, .send), (.cancelled, .send):
            return "Couldn't send \(name)."
        case (.failed, .receive), (.cancelled, .receive):
            return "Couldn't receive \(name)."
        }
    }

    /// Why a transfer did not finish; nil while under way or once done.
    static func reason(_ item: TransferItem) -> LocalizedStringResource? {
        switch item.state {
        case .queued, .waiting, .active, .done: return nil
        case .cancelled: return "Cancelled."
        case let .failed(error):
            let sending = item.direction == .send
            switch error {
            case .noSpace: return sending ? "Not enough space on the phone." : "Not enough space on the Mac."
            case .interrupted: return "The connection was lost."
            case .hashMismatch: return "The file changed or was damaged on the way."
            case .cancelled: return "Cancelled."
            case .timedOut: return "The phone didn't answer."
            case .io: return "The file couldn't be read or saved."
            case .notFound: return "The file is no longer there."
            case .unspecified, .denied, .disabled, .badTarget, .UNRECOGNIZED:
                return sending ? "The phone didn't take the file." : "This Mac can't take this file."
            }
        }
    }

    static func cancelLabel(_ item: TransferItem) -> LocalizedStringResource {
        item.direction == .send ? "Cancel sending \(item.name)" : "Cancel receiving \(item.name)"
    }

    /// Why an explicit send of text did not go; nil when it went (or none was tried).
    static func note(_ outcome: ClipboardSendOutcome?) -> LocalizedStringResource? {
        switch outcome {
        case .empty: "The clipboard is empty."
        case .tooLarge: "The text is too long to send."
        case .sent, .notConnected, nil: nil
        }
    }
}
