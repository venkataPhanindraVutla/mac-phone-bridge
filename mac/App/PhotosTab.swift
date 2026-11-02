import AMProtocol
import AppKit
import FeatureFiles
import FeaturePhotos
import SwiftUI

/// The Phone window's Photos tab: the phone's newest 200 photos and videos as thumbnails. A cell
/// drags out as the full file (fetched when dropped) and has "Save to Downloads". The list is
/// fetched each time the tab shows; the thumbnails stay in memory only.
struct PhotosTab: View {
    let model: AppModel
    /// Why the last "Save to Downloads" did not work; cleared by the next one.
    @State private var saveNote: SaveNote?
    /// Each thumbnail decoded once; dropped with the thumbnails.
    @State private var images = ThumbnailImages()

    private var photos: PhotosModel { model.photos }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !photos.available {
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
        // Keyed on the model, not the server: the model learns of a (re)connect later, through
        // the session's work queue, and a refresh before that would find no session.
        .task(id: RefreshKey(available: photos.available, enabled: photos.phoneAvailability?.enabled ?? true,
                             connection: photos.connectionCount)) {
            guard photos.available, photos.phoneAvailability?.enabled ?? true else { return }
            await photos.refresh()
        }
        .onChange(of: photos.thumbnails.count) { images.keep(Set(photos.thumbnails.keys)) }
    }

    @ViewBuilder private var grid: some View {
        if photos.items.isEmpty {
            if photos.loading {
                ProgressView().frame(maxWidth: .infinity)
            } else if photos.listFailed {
                Text("Couldn't load photos from the phone.").foregroundStyle(.secondary)
                Button("Try Again") { Task { await photos.refresh() } }
                    .accessibilityLabel(Text("Try Again"))
            } else {
                Text("No photos yet.").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cell, maximum: Self.cell), spacing: 8)], spacing: 8) {
                    ForEach(photos.items, id: \.id) { item in
                        PhotoCell(item: item, image: images.image(item.id, photos.thumbnails[item.id]))
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
        let photos = photos, id = item.id
        return FilePromise.provider(name: PhotosModel.promisedName(for: item), type: PhotosModel.contentType(for: item)) { url in
            await photos.fetch(id, to: url)
        }
    }

    private struct RefreshKey: Equatable {
        let available: Bool
        let enabled: Bool
        let connection: Int
    }
}

/// Why a save failed, for the note under "Couldn't save to Downloads.". There is no note for a
/// save the user cancelled (`init` returns nil), and no reason line for a failure that is not a
/// transfer's.
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

/// Thumbnails decoded once each, by item ID; an entry is redone only when its bytes change.
/// A plain class, read and filled while the grid renders.
@MainActor
private final class ThumbnailImages {
    private var decoded: [Int64: (jpeg: Data, image: NSImage)] = [:]

    func image(_ id: Int64, _ jpeg: Data?) -> NSImage? {
        guard let jpeg else {
            decoded[id] = nil
            return nil
        }
        if let hit = decoded[id], hit.jpeg == jpeg { return hit.image }
        guard let image = NSImage(data: jpeg) else { return nil }
        decoded[id] = (jpeg, image)
        return image
    }

    /// Forgets every image whose thumbnail the model no longer holds.
    func keep(_ ids: Set<Int64>) {
        decoded = decoded.filter { ids.contains($0.key) }
    }
}

/// One grid cell: the thumbnail (or a placeholder), a duration badge on videos, and one spoken
/// label with the date and the kind.
private struct PhotoCell: View {
    let item: AMPhotoItem
    let image: NSImage?

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
        if let image {
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
        return (seconds >= 3600 ? hours : minutes).string(from: TimeInterval(seconds)) ?? ""
    }

    private static let minutes = durationFormatter([.minute, .second])
    private static let hours = durationFormatter([.hour, .minute, .second])

    private static func durationFormatter(_ units: NSCalendar.Unit) -> DateComponentsFormatter {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = units
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }
}
