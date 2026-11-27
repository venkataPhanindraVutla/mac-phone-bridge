import AMProtocol
import Foundation
import Testing
@testable import FeatureNotify

@MainActor
private final class Disk {
    var data: Data?
    var saves = 0
}

@MainActor
private final class Clock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
private func history(days: Int = 7, disk: Disk = Disk(), clock: Clock = Clock()) -> NotificationHistory {
    NotificationHistory(retentionDays: days, load: { disk.data }, save: { disk.data = $0; disk.saves += 1 },
                        now: { clock.now }, saveDelay: nil)
}

private func posted(key: String = "k1", package: String = "com.chat", app: String = "Chat", title: String = "Ann",
                    text: String = "hello", alert: Bool = true) -> AMPhoneNotification {
    var n = AMPhoneNotification()
    n.key = key; n.package = package; n.appName = app; n.title = title; n.text = text; n.alert = alert
    return n
}

@MainActor @Test func postsAreKeptNewestFirstAndLive() {
    let clock = Clock()
    let h = history(clock: clock)
    h.record(posted(key: "a", text: "one"), title: "Ann", phoneID: "P1")
    clock.now += 60
    h.record(posted(key: "b", package: "com.bank", app: "", title: "Bank", text: "Your code is 482913"), title: "Bank", phoneID: "P1")
    #expect(h.entries.map(\.key) == ["b", "a"])
    #expect(h.entries.allSatisfy { $0.live })
    #expect(h.entries[0].appName == "com.bank") // no app name: the package
    #expect(h.entries[0].code == "482913")
    #expect(h.entries[1].code == nil)
}

@MainActor @Test func updatesReplaceTheirRow() {
    let clock = Clock()
    let h = history(clock: clock)
    h.record(posted(key: "a", text: "hi"), title: "Ann", phoneID: "P1")
    clock.now += 10
    h.record(posted(key: "b"), title: "Bob", phoneID: "P1")
    clock.now += 10
    // A silent update keeps its place and time.
    h.record(posted(key: "a", text: "hi\nthere", alert: false), title: "Ann", phoneID: "P1")
    #expect(h.entries.map(\.key) == ["b", "a"])
    #expect(h.entries[1].text == "hi\nthere")
    #expect(h.entries[1].postedAt == Clock().now)
    // An alerting one moves to the top.
    h.record(posted(key: "a", text: "hi\nthere\nagain"), title: "Ann", phoneID: "P1")
    #expect(h.entries.map(\.key) == ["a", "b"])
    #expect(h.entries.count == 2)
    // Once gone from the phone, the same key starts a new row.
    h.removed(key: "a", phoneID: "P1")
    #expect(h.entries[0].live == false)
    h.record(posted(key: "a", text: "new"), title: "Ann", phoneID: "P1")
    #expect(h.entries.map(\.text) == ["new", "hi\nthere\nagain", "hello"])
}

@MainActor @Test func snapshotAndDisconnectSetWhatIsLive() {
    let h = history()
    h.record(posted(key: "a"), title: "Ann", phoneID: "P1")
    h.record(posted(key: "b"), title: "Bob", phoneID: "P1")
    h.record(posted(key: "c"), title: "Cy", phoneID: "P2")
    h.disconnected()
    #expect(h.entries.allSatisfy { !$0.live })
    h.active(keys: ["b"], phoneID: "P1")
    #expect(h.entries.filter(\.live).map(\.key) == ["b"])
}

@MainActor @Test func emptyAndOffAreNotKept() {
    let disk = Disk()
    let h = history(days: 0, disk: disk)
    h.record(posted(), title: "Ann", phoneID: "P1")
    #expect(h.entries.isEmpty)
    let on = history()
    on.record(posted(title: "", text: ""), title: "", phoneID: "P1")
    #expect(on.entries.isEmpty)
}

@MainActor @Test func oldEntriesAndTheOverflowGo() {
    let clock = Clock()
    let h = history(days: 1, clock: clock)
    h.record(posted(key: "old"), title: "Ann", phoneID: "P1")
    clock.now += 86_400 + 1
    h.record(posted(key: "new"), title: "Ann", phoneID: "P1")
    #expect(h.entries.map(\.key) == ["new"])
    for i in 0..<(NotificationHistory.maxEntries + 5) {
        h.record(posted(key: "k\(i)"), title: "Ann", phoneID: "P1")
    }
    #expect(h.entries.count == NotificationHistory.maxEntries)
    #expect(h.entries.first?.key == "k\(NotificationHistory.maxEntries + 4)")
}

@MainActor @Test func savedEncodedAndLoadedBack() {
    let disk = Disk()
    let h = history(disk: disk)
    h.record(posted(key: "a", text: "kept"), title: "Ann", phoneID: "P1")
    h.flush()
    #expect(disk.saves == 1)
    let again = history(disk: disk)
    #expect(again.entries.map(\.text) == ["kept"])
    // Nothing is live after a restart: the phone tells again.
    #expect(again.entries.allSatisfy { !$0.live })
}

@MainActor @Test func turningOffClearsAndForgetDropsOnePhone() {
    let disk = Disk()
    let h = history(disk: disk)
    h.record(posted(key: "a"), title: "Ann", phoneID: "P1")
    h.record(posted(key: "b"), title: "Bob", phoneID: "P2")
    h.forget(phoneID: "P1")
    #expect(h.entries.map(\.phoneID) == ["P2"])
    h.keepOnly(phoneIDs: [])
    #expect(h.entries.isEmpty)
    h.record(posted(key: "c"), title: "Cy", phoneID: "P2")
    h.retentionDays = 0
    h.flush()
    #expect(h.entries.isEmpty)
    #expect(disk.data == nil) // the file goes
}

@MainActor @Test func unreadableFileStartsEmpty() {
    let disk = Disk()
    disk.data = Data("not json".utf8)
    #expect(history(disk: disk).entries.isEmpty)
}

@MainActor @Test func theNotificationsModelFeedsTheHistory() async {
    let h = Harness()
    let kept = history()
    h.model.history = kept
    h.contacts["+1 555 123 4567"] = "Mum"
    await h.connect()
    await h.model.posted(posted(key: "a", title: "+1 555 123 4567", text: "Call me"))
    await h.model.posted(posted(key: "b"))
    #expect(kept.entries.map(\.title) == ["Ann", "Mum"])
    h.model.removed({ var r = AMNotificationRemoved(); r.key = "b"; return r }())
    #expect(kept.entries.filter { $0.live }.map(\.key) == ["a"])
    var snap = AMActiveNotifications()
    snap.keys = ["b"]
    await h.model.snapshot(snap)
    #expect(kept.entries.filter { $0.live }.map(\.key) == ["b"])
    h.model.disconnected()
    #expect(kept.entries.allSatisfy { !$0.live })
    await h.model.forget(phoneID: "P1")
    #expect(kept.entries.isEmpty)
}
