import AMProtocol
import AppKit
import FeatureFiles
import FeaturePhotos
import SwiftUI
import UniformTypeIdentifiers

/// The Phone window's Photos tab: the phone's newest 200 photos and videos as thumbnails. A cell
/// drags out as the full file (fetched when dropped) and has "Save to Downloads". The list is
/// fetched each time the tab shows; the thumbnails stay in memory only.
struct PhotosTab: View {
    let model: AppModel
    /// Why the last "Save to Downloads" did not work; cleared by the next one.
    @State private var saveNote: SaveNote?

    private var photos: PhotosModel { model.photos }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.isConnected || !model.canPhotos {
                Text(model.statusText)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else if Self.needsPhoneSwitch(photos.phoneAvailability) {
                Text("Turn on photo access in the phone app.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                if photos.partialAccess || photos.phoneAvailability?.reason == .partialAccess {
                    Label("Showing only the photos you allowed on the phone.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
                if let saveNote {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Couldn't save to Downloads.")
                        if let reason = saveNote.reason { Text(reason).foregroundStyle(.secondary) }
                    }
                    .accessibilityElement(children: .combine)
                }
                grid
            }
        }
        .padding(.top, 8)
        .task(id: RefreshKey(connected: model.isConnected, shared: model.canPhotos,
                             enabled: photos.phoneAvailability?.enabled ?? true)) {
            guard model.isConnected, model.canPhotos, photos.phoneAvailability?.enabled ?? true else { return }
            await photos.refresh()
        }
    }

    @ViewBuilder private var grid: some View {
        if photos.items.isEmpty {
            if photos.loading { ProgressView().frame(maxWidth: .infinity) }
            Spacer(minLength: 0)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cell, maximum: Self.cell), spacing: 8)], spacing: 8) {
                    ForEach(photos.items, id: \.id) { item in
                        PhotoCell(item: item, jpeg: photos.thumbnails[item.id])
                            .contextMenu {
                                Button("Save to Downloads") { Task { await save(item) } }
                            }
                            .onDrag { provider(for: item) }
                    }
                }
            }
        }
    }

    static let cell: CGFloat = 120

    /// "Turn on photo access in the phone app.": the phone's switch is off, or its permission missing.
    static func needsPhoneSwitch(_ availability: AMFeatureAvailability?) -> Bool {
        guard let availability, !availability.enabled else { return false }
        return availability.reason == .offByUser || availability.reason == .needsPermission
    }

    private func save(_ item: AMPhotoItem) async {
        saveNote = nil
        if case let .failure(failure) = await photos.save(item.id) { saveNote = SaveNote(failure) }
    }

    private func provider(for item: AMPhotoItem) -> NSItemProvider {
        let type = UTType(mimeType: item.mime) ?? (item.video ? .movie : .image)
        let photos = photos, id = item.id
        return FilePromise.provider(name: PhotosModel.promisedName(for: item), type: type) { url in
            await photos.fetch(id, to: url)
        }
    }

    private struct RefreshKey: Equatable {
        let connected: Bool
        let shared: Bool
        let enabled: Bool
    }
}

/// Why a save failed; nil reason when the user cancelled it (it shows no note).
private struct SaveNote {
    let reason: LocalizedStringResource?

    init?(_ failure: TransferFailure) {
        guard case let .transfer(error) = failure else {
            reason = nil
            return
        }
        if error == .cancelled { return nil }
        reason = TransferText.reason(TransferItem(id: "", direction: .receive, name: "", size: 0, kind: .photo,
                                                  state: .failed(error)))
    }
}

/// One grid cell: the thumbnail (or a placeholder), a duration badge on videos, and one spoken
/// label with the date and the kind.
private struct PhotoCell: View {
    let item: AMPhotoItem
    let jpeg: Data?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            thumbnail
                .frame(width: PhotosTab.cell, height: PhotosTab.cell)
                .clipped()
            if item.video {
                Text(Self.duration(item.durationMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    .padding(4)
            }
        }
        .frame(width: PhotosTab.cell, height: PhotosTab.cell)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(.isImage)
    }

    @ViewBuilder private var thumbnail: some View {
        if let jpeg, let image = NSImage(data: jpeg) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Rectangle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: item.video ? "video" : "photo")
                        .foregroundStyle(.secondary)
                }
        }
    }

    private var label: LocalizedStringResource {
        let date = Date(timeIntervalSince1970: Double(item.dateTakenMs) / 1000)
            .formatted(date: .abbreviated, time: .shortened)
        return item.video ? "Video, \(date)" : "Photo, \(date)"
    }

    /// `m:ss`, or `h:mm:ss` from an hour.
    static func duration(_ ms: Int64) -> String {
        let seconds = max(0, Int(ms / 1000))
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: TimeInterval(seconds)) ?? ""
    }
}
