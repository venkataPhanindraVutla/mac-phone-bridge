import AMProtocol
import Testing
@testable import FeatureStatus

@Test func menuTitleShowsChargingBolt() {
    let idle = PhoneStatus(batteryPercent: 82, charging: false, signalLevel: 3, network: .wifi)
    let plugged = PhoneStatus(batteryPercent: 82, charging: true, signalLevel: 3, network: .wifi)
    #expect(StatusFormatter.menuTitle(idle) == "82%")
    #expect(StatusFormatter.menuTitle(plugged) == "82% ⚡︎")
}

@Test func detailSaysNoServiceForMinusOne() {
    let ok = PhoneStatus(batteryPercent: 82, charging: true, signalLevel: 3, network: .wifi)
    #expect(StatusFormatter.detail(ok) == "Battery 82%, charging · Wi-Fi · Signal 3 of 4")
    let none = PhoneStatus(batteryPercent: 40, charging: false, signalLevel: -1, network: .cellular)
    #expect(StatusFormatter.detail(none) == "Battery 40%, not charging · Mobile data · No service")
}

@Test func accessibilityLabelHasNoSymbols() {
    let s = PhoneStatus(batteryPercent: 82, charging: true, signalLevel: 3, network: .wifi)
    let label = StatusFormatter.accessibilityLabel(s)
    #expect(label.contains("charging"))
    #expect(!label.contains("⚡"))
    #expect(!label.contains("%"))
    #expect(label.contains("3 of 4 bars"))
    let off = PhoneStatus(batteryPercent: 5, charging: false, signalLevel: 0, network: .none)
    #expect(StatusFormatter.accessibilityLabel(off).contains("not charging"))
}

@MainActor @Test func modelAppliesAndResets() {
    let model = PhoneStatusModel()
    var u = AMStatusUpdate()
    u.batteryPercent = 55; u.charging = true; u.signalLevel = 2; u.network = .cellular
    model.apply(u)
    #expect(model.status == PhoneStatus(batteryPercent: 55, charging: true, signalLevel: 2, network: .cellular))
    model.reset()
    #expect(model.status == nil)
}

@Test func backgroundNoteOnlyWhenRestricted() {
    let restricted = PhoneStatus(batteryPercent: 82, charging: false, signalLevel: 3, network: .wifi,
                                 backgroundRestricted: true)
    let exempt = PhoneStatus(batteryPercent: 82, charging: false, signalLevel: 3, network: .wifi)
    #expect(StatusFormatter.backgroundNote(restricted) == "Phone may disconnect when locked")
    #expect(StatusFormatter.backgroundNote(exempt) == nil)
    #expect(exempt.backgroundRestricted == false)
}

@MainActor @Test func applyReadsBackgroundRestricted() {
    let model = PhoneStatusModel()
    var u = AMStatusUpdate()
    u.batteryPercent = 55; u.network = .wifi; u.backgroundRestricted = true
    model.apply(u)
    #expect(model.status?.backgroundRestricted == true)
    u.backgroundRestricted = false
    model.apply(u)
    #expect(model.status?.backgroundRestricted == false)
}
