import AMProtocol
import FeatureFiles
import FeatureShare
import SwiftUI
import UniformTypeIdentifiers

/// The Phone window's Send tab: a drop zone for files, links and text, and the transfer list.
struct SendTab: View {
    let model: AppModel
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isConnected, let phone = model.currentPhone, model.canSendFiles || model.canShare {
                dropZone(phone: phone.name)
                ForEach(model.sendNotes, id: \.self) { note in
                    Text(note.text).foregroundStyle(.secondary)
                }
                HStack {
                    if model.canSendFiles {
                        Button("Send File to Phone…") { model.chooseFilesToSend() }
                    }
                    if model.canShare {
                        Button("Send Clipboard to Phone") { Task { await model.sendClipboard() } }
                    }
                }
            } else {
                Text(model.statusText)
                    .foregroundStyle(.secondary)
            }
            transferList
        }
        .padding(.top, 8)
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
                model.drop(items)
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
                if !item.isFinal, item.state != .queued {
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
        case (.queued, .send):
            return "Waiting to send \(name)"
        case (.queued, .receive):
            return "Waiting to receive \(name)"
        case (.waiting, .send), (.active, .send):
            return "Sending \(name) · \(percent(item))%"
        case (.waiting, .receive), (.active, .receive):
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

    /// The menu's failure line: one file by name, several by count.
    static func failureTitle(_ failure: TransferFailureSummary) -> LocalizedStringResource {
        guard failure.count > 1 else { return title(failure.newest) }
        return failure.newest.direction == .send
            ? "Couldn't send \(failure.count) files." : "Couldn't receive \(failure.count) files."
    }

    /// The reason under the failure line; nil when the files failed for different reasons.
    static func failureReason(_ failure: TransferFailureSummary) -> LocalizedStringResource? {
        failure.sameReason ? reason(failure.newest) : nil
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
            case .disabled where sending:
                // The phone's switch for this is off.
                return item.targeted ? "Turn on file browsing in the phone app." : "Turn on file sharing in the phone app."
            case .unspecified, .denied, .disabled, .badTarget, .UNRECOGNIZED:
                return sending ? "The phone didn't take the file." : "This Mac can't take this file."
            }
        }
    }

    static func cancelLabel(_ item: TransferItem) -> LocalizedStringResource {
        item.direction == .send ? "Cancel sending \(item.name)" : "Cancel receiving \(item.name)"
    }
}
