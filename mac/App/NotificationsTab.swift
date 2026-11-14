import AppKit
import FeatureNotify
import SwiftUI

/// The Phone window's Notifications tab: the notification history, newest first and grouped by
/// day, with search, an app filter and Clear History. A click on a row shows all of its text and
/// its Copy buttons. A green dot marks a notification that is still on the phone.
struct NotificationsTab: View {
    let model: AppModel
    @State private var query = ""
    /// The package shown, or nil for all apps.
    @State private var app: String?
    @State private var selected: HistoryEntry.ID?
    @State private var confirmClear = false

    private var history: NotificationHistory { model.notificationHistory }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if history.retentionDays == 0 {
                Text("Notification history is off. Turn it on in Settings, under Notifications.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                bar
                list
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Entries past their days go while the window is open too.
        .onAppear { history.prune() }
        .confirmationDialog("Clear notification history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) {
                history.clear()
                selected = nil
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    private var bar: some View {
        HStack {
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text("Search notifications"))
            Picker("App", selection: $app) {
                Text("All apps").tag(String?.none)
                ForEach(apps, id: \.package) { a in
                    Text(verbatim: a.name).tag(String?.some(a.package))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 160)
            .accessibilityLabel(Text("App"))
            Button("Clear History…") { confirmClear = true }
                .disabled(history.entries.isEmpty)
        }
    }

    @ViewBuilder private var list: some View {
        let shown = HistoryText.filter(history.entries, query: query, package: app)
        if shown.isEmpty {
            VStack {
                Spacer()
                Text(history.entries.isEmpty
                     ? "No notifications yet. Phone notifications that reach this Mac show up here."
                     : "No notifications match.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List {
                ForEach(HistoryText.days(shown), id: \.day) { group in
                    Section(HistoryText.dayTitle(group.day)) {
                        ForEach(group.entries) { entry in
                            row(entry)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ entry: HistoryEntry) -> some View {
        let open = selected == entry.id
        return HStack(alignment: .top, spacing: 10) {
            icon(for: entry.package)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(verbatim: entry.appName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if entry.live {
                        Circle().fill(.green).frame(width: 6, height: 6)
                            .accessibilityLabel(Text("Still on the phone"))
                    }
                }
                if !entry.title.isEmpty {
                    Text(verbatim: entry.title).fontWeight(.semibold)
                }
                if !entry.text.isEmpty {
                    Text(verbatim: entry.text)
                        .lineLimit(open ? nil : 2)
                        .textSelection(.enabled)
                }
                if open {
                    HStack {
                        Button("Copy Text") { copy([entry.title, entry.text].filter { !$0.isEmpty }.joined(separator: "\n")) }
                        if let code = entry.code {
                            Button("Copy Code") { copy(code) }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            Text(entry.postedAt, style: .time)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { selected = open ? nil : entry.id }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(open ? "Hides the full text" : "Shows the full text and Copy buttons"))
    }

    @ViewBuilder private func icon(for package: String) -> some View {
        if let url = model.appIconURL(package: package), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().frame(width: 24, height: 24).accessibilityHidden(true)
        } else {
            Image(systemName: "app").frame(width: 24, height: 24).accessibilityHidden(true)
        }
    }

    /// Apps in the history, by name.
    private var apps: [(package: String, name: String)] {
        var seen: [String: String] = [:]
        for e in history.entries where seen[e.package] == nil { seen[e.package] = e.appName }
        return seen.map { ($0.key, $0.value) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var footer: String {
        let days = history.retentionDays
        return days == 1
            ? String(localized: "Kept for 1 day. A green dot means it is still on the phone.")
            : String(localized: "Kept for \(days) days. A green dot means it is still on the phone.")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Grouping, search and wording for the history list.
enum HistoryText {
    static func filter(_ entries: [HistoryEntry], query: String, package: String?) -> [HistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return entries.filter { e in
            (package == nil || e.package == package)
                && (needle.isEmpty || [e.appName, e.title, e.text].contains { $0.localizedCaseInsensitiveContains(needle) })
        }
    }

    /// Entries (newest first) by the day they came, newest day first.
    static func days(_ entries: [HistoryEntry]) -> [(day: Date, entries: [HistoryEntry])] {
        var out: [(day: Date, entries: [HistoryEntry])] = []
        for e in entries {
            let day = Calendar.current.startOfDay(for: e.postedAt)
            if out.last?.day == day { out[out.count - 1].entries.append(e) } else { out.append((day, [e])) }
        }
        return out
    }

    static func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return String(localized: "Today") }
        if Calendar.current.isDateInYesterday(day) { return String(localized: "Yesterday") }
        return day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    static func retention(_ days: Int) -> String {
        switch days {
        case 0: String(localized: "Off")
        case 1: String(localized: "For 1 day")
        default: String(localized: "For \(days) days")
        }
    }
}
