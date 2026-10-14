import Testing
@testable import FlowLiteCore

@Suite struct HotkeyStateMachineTests {
    @Test func holdStartsThenStops() {
        var m = HotkeyStateMachine()
        #expect(m.handle(.triggerDown(withControl: false), at: 0) == .dictateStart)
        #expect(m.handle(.triggerUp, at: 1.0) == .dictateStop)
    }

    @Test func shortTapCancels() {
        var m = HotkeyStateMachine()
        #expect(m.handle(.triggerDown(withControl: false), at: 0) == .dictateStart)
        #expect(m.handle(.triggerUp, at: 0.1) == .cancel)
    }

    @Test func otherKeyWhileHoldingCancelsAndReleaseIsIgnored() {
        var m = HotkeyStateMachine()
        _ = m.handle(.triggerDown(withControl: false), at: 0)
        #expect(m.handle(.otherKeyDown, at: 0.5) == .cancel)
        #expect(m.handle(.triggerUp, at: 1.0) == nil)
    }

    @Test func escapeWhileHoldingCancels() {
        var m = HotkeyStateMachine()
        _ = m.handle(.triggerDown(withControl: false), at: 0)
        #expect(m.handle(.escape, at: 0.5) == .cancel)
    }

    @Test func doubleTapLocksUntilNextPress() {
        var m = HotkeyStateMachine()
        #expect(m.handle(.triggerDown(withControl: false), at: 0) == .dictateStart)
        #expect(m.handle(.triggerUp, at: 0.1) == .cancel)
        #expect(m.handle(.triggerDown(withControl: false), at: 0.3) == .dictateStart)
        #expect(m.handle(.triggerUp, at: 0.4) == nil)
        #expect(m.handle(.otherKeyDown, at: 2.0) == nil)
        #expect(m.handle(.triggerDown(withControl: false), at: 5.0) == .dictateStop)
        #expect(m.handle(.triggerUp, at: 5.1) == nil)
        #expect(m.handle(.triggerDown(withControl: false), at: 6.0) == .dictateStart)
        #expect(m.handle(.triggerUp, at: 7.0) == .dictateStop)
    }

    @Test func tapThenHoldIsANormalHold() {
        var m = HotkeyStateMachine()
        _ = m.handle(.triggerDown(withControl: false), at: 0)
        _ = m.handle(.triggerUp, at: 0.1)
        #expect(m.handle(.triggerDown(withControl: false), at: 0.3) == .dictateStart)
        #expect(m.handle(.triggerUp, at: 1.5) == .dictateStop)
        #expect(m.handle(.triggerDown(withControl: false), at: 3.0) == .dictateStart)
        #expect(m.handle(.triggerUp, at: 4.0) == .dictateStop)
    }

    @Test func otherKeyDuringSecondPressCancels() {
        var m = HotkeyStateMachine()
        _ = m.handle(.triggerDown(withControl: false), at: 0)
        _ = m.handle(.triggerUp, at: 0.1)
        _ = m.handle(.triggerDown(withControl: false), at: 0.3)
        #expect(m.handle(.otherKeyDown, at: 0.35) == .cancel)
        #expect(m.handle(.triggerUp, at: 0.4) == nil)
    }

    @Test func slowSecondPressIsANormalHold() {
        var m = HotkeyStateMachine()
        _ = m.handle(.triggerDown(withControl: false), at: 0)
        _ = m.handle(.triggerUp, at: 0.1)
        #expect(m.handle(.triggerDown(withControl: false), at: 1.0) == .dictateStart)
        #expect(m.handle(.triggerUp, at: 2.0) == .dictateStop)
    }

    @Test func controlChordIsCommandMode() {
        var m = HotkeyStateMachine()
        #expect(m.handle(.triggerDown(withControl: true), at: 0) == .commandStart)
        #expect(m.handle(.triggerUp, at: 1.0) == .commandStop)
    }

    @Test func escapeCancelsLockedRecording() {
        var m = HotkeyStateMachine()
        _ = m.handle(.triggerDown(withControl: false), at: 0)
        _ = m.handle(.triggerUp, at: 0.1)
        _ = m.handle(.triggerDown(withControl: false), at: 0.3)
        #expect(m.handle(.escape, at: 3.0) == .cancel)
        #expect(m.handle(.triggerUp, at: 3.1) == nil)
    }

    @Test func strayEventsWhileIdleDoNothing() {
        var m = HotkeyStateMachine()
        #expect(m.handle(.triggerUp, at: 0) == nil)
        #expect(m.handle(.otherKeyDown, at: 0) == nil)
        #expect(m.handle(.escape, at: 0) == nil)
    }
}
