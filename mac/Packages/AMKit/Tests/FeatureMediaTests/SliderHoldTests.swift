import Testing
@testable import FeatureMedia

@Test func dragShowsTheDraggedValue() {
    var hold = SliderHold()
    #expect(hold.value == nil)
    hold.drag(10)
    hold.drag(12)
    #expect(hold.value == 12)
    // A state while dragging does not take the thumb away.
    hold.stateArrived()
    #expect(hold.value == 12)
}

@Test func releasedValueIsKeptUntilTheNextState() {
    var hold = SliderHold()
    hold.drag(12)
    let release = hold.release()
    #expect(release?.value == 12)
    #expect(hold.value == 12)
    hold.stateArrived()
    #expect(hold.value == nil)
}

@Test func releasedValueGoesAfterTheTimeout() {
    var hold = SliderHold()
    hold.drag(12)
    let first = hold.release()!
    hold.timedOut(first.id)
    #expect(hold.value == nil)
    // An old release's timeout leaves a newer drag or release alone.
    hold.drag(20)
    let second = hold.release()!
    hold.timedOut(first.id)
    #expect(hold.value == 20)
    hold.drag(25)
    hold.timedOut(second.id)
    #expect(hold.value == 25)
}

@Test func releaseWithoutDragSendsNothing() {
    var hold = SliderHold()
    #expect(hold.release() == nil)
}
