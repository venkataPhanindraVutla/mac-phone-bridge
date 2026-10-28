import AMProtocol
import Testing
import UserNotifications
@testable import FeatureNotify

private func action(_ index: UInt32, _ title: String, reply: Bool = false) -> AMNotificationAction {
    var a = AMNotificationAction()
    a.index = index; a.title = title; a.isReply = reply
    return a
}

@MainActor
@Test func registryCapsAt64AndReusesIdentical() {
    var applied: [Set<UNNotificationCategory>] = []
    let registry = CategoryRegistry { applied.append($0) }

    let first = registry.categoryID(actions: [action(0, "T0")], hasCode: false)
    #expect(first.hasPrefix("c|") && first.count == 2 + 16)
    #expect(registry.categoryID(actions: [action(0, "T0")], hasCode: false) == first)
    #expect(applied.count == 1)                         // identical: nothing re-registered

    for i in 1..<64 { _ = registry.categoryID(actions: [action(0, "T\(i)")], hasCode: false) }
    #expect(registry.count == 64)
    _ = registry.categoryID(actions: [action(0, "T0")], hasCode: false)   // touch: T0 is now most recent
    let before = applied.count
    _ = registry.categoryID(actions: [action(0, "T64")], hasCode: false)  // evicts T1, the least recently used
    #expect(registry.count == 64)
    #expect(applied.count == before + 1)
    #expect(applied.last?.count == 64)
    let ids = Set(applied.last!.map(\.identifier))
    #expect(ids.contains(first))
    #expect(!ids.contains(CategoryRegistry.identifier(actions: [action(0, "T1")], hasCode: false)))
}

@MainActor
@Test func differentShapesGetDifferentIDs() {
    let plain = CategoryRegistry.identifier(actions: [action(0, "Open")], hasCode: false)
    #expect(plain != CategoryRegistry.identifier(actions: [action(0, "Open")], hasCode: true))
    #expect(plain != CategoryRegistry.identifier(actions: [action(0, "Open", reply: true)], hasCode: false))
}
