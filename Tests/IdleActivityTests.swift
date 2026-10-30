import XCTest
@testable import SoftLock

private final class FakeIdleActivity: IdleActivityDriver {
    var system = IdleActivitySnapshot(idleSeconds: 10)
    var result: IdlePulseResult = .posted
    var sent = 0
    func snapshot() -> IdleActivitySnapshot { system }
    func pulse() -> IdlePulseResult { sent += 1; return result }
}

final class IdleActivityTests: XCTestCase {
    func testNativeReleasedCacheDoesNotEraseObservedHeldInput() {
        let tracker = InputHoldTracker()
        tracker.seed(keys: [48], buttons: [1], flags: .maskShift)
        tracker.observe(type: .keyDown, key: 0, button: 0, flags: .maskControl, physical: true, locked: true)
        tracker.observe(type: .leftMouseDown, key: 0, button: 0, flags: [], physical: false, locked: true)
        tracker.reconcileSeededInput(keyIsDown: { _ in false }, buttonIsDown: { _ in false }, modifierFlags: { [] })
        XCTAssertTrue(tracker.snapshot.held)
        XCTAssertEqual(tracker.snapshot.counts["physicalKeys"], 1)
        XCTAssertEqual(tracker.snapshot.counts["injectedButtons"], 1)
        tracker.observe(type: .keyUp, key: 0, button: 0, flags: [], physical: true, locked: true)
        tracker.observe(type: .leftMouseUp, key: 0, button: 0, flags: [], physical: false, locked: true)
        XCTAssertFalse(tracker.snapshot.held)
    }

    func testSeededNativeHeldStateRemainsAndDoesNotGetReintroduced() {
        let tracker = InputHoldTracker()
        tracker.seed(keys: [48, 1], buttons: [0, 1], flags: [.maskControl, .maskShift],
                     hidKeys: [48], hidButtons: [0], hidFlags: .maskControl)
        tracker.observe(type: .keyUp, key: 48, button: 0, flags: [], physical: false, locked: true)
        tracker.observe(type: .leftMouseUp, key: 0, button: 0, flags: [], physical: false, locked: true)
        tracker.observe(type: .flagsChanged, key: 59, button: 0, flags: [], physical: false, locked: true)
        tracker.observe(type: .flagsChanged, key: 58, button: 0, flags: [], physical: true, locked: true)
        XCTAssertEqual(tracker.snapshot.counts["seededKeys"], 2)
        XCTAssertEqual(tracker.snapshot.counts["seededButtons"], 2)
        XCTAssertEqual(tracker.snapshot.flags, [.maskControl, .maskShift],
                       "Injected or unrelated releases must preserve startup input")

        tracker.observe(type: .keyUp, key: 48, button: 0, flags: [], physical: true, locked: true)
        tracker.observe(type: .leftMouseUp, key: 0, button: 0, flags: [], physical: true, locked: true)
        tracker.observe(type: .flagsChanged, key: 59, button: 0, flags: [], physical: true, locked: true)
        tracker.observe(type: .keyUp, key: 1, button: 0, flags: [], physical: true, locked: true)
        tracker.observe(type: .rightMouseUp, key: 0, button: 1, flags: [], physical: true, locked: true)
        tracker.observe(type: .flagsChanged, key: 56, button: 0, flags: [], physical: true, locked: true)
        tracker.reconcileSeededInput(keyIsDown: { _ in true }, buttonIsDown: { _ in true },
                                     modifierFlags: { [.maskControl, .maskShift] })
        XCTAssertEqual(tracker.snapshot.counts["seededKeys"], 1)
        XCTAssertEqual(tracker.snapshot.counts["seededButtons"], 1)
        XCTAssertEqual(tracker.snapshot.flags, .maskShift,
                       "Matching physical releases clear HID seeds despite stale caches; unknown seeds stay conservative")
        XCTAssertTrue(tracker.snapshot.held)
        tracker.reconcileSeededInput(keyIsDown: { _ in false }, buttonIsDown: { _ in false }, modifierFlags: { [] })
        XCTAssertFalse(tracker.snapshot.held)
        tracker.reconcileSeededInput(keyIsDown: { _ in true }, buttonIsDown: { _ in true }, modifierFlags: { .maskControl })
        XCTAssertFalse(tracker.snapshot.held, "Stale native cache must not recreate released seed state")
    }

    func testPhysicalLockChordReleasesAreObservedEvenWhenDiscarded() {
        let tracker = InputHoldTracker()
        let chord: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
        tracker.observe(type: .flagsChanged, key: 55, button: 0, flags: chord, physical: true, locked: false)
        tracker.observe(type: .keyDown, key: 37, button: 0, flags: chord, physical: true, locked: false)
        XCTAssertTrue(tracker.snapshot.held)
        tracker.observe(type: .keyUp, key: 37, button: 0, flags: chord, physical: true, locked: true)
        tracker.observe(type: .flagsChanged, key: 55, button: 0, flags: [], physical: true, locked: true)
        XCTAssertFalse(tracker.snapshot.held)
        XCTAssertTrue(tracker.snapshot.flags.isEmpty)
    }

    func testInjectedInputRemainsHeldAfterPhysicalRelease() {
        let tracker = InputHoldTracker()
        tracker.observe(type: .keyDown, key: 1, button: 0, flags: [], physical: false, locked: true)
        tracker.observe(type: .keyDown, key: 1, button: 0, flags: [], physical: true, locked: true)
        tracker.observe(type: .keyUp, key: 1, button: 0, flags: [], physical: true, locked: true)
        XCTAssertTrue(tracker.snapshot.held)
        tracker.observe(type: .keyUp, key: 1, button: 0, flags: [], physical: false, locked: true)
        XCTAssertFalse(tracker.snapshot.held)
        tracker.observe(type: .leftMouseDown, key: 0, button: 0, flags: [], physical: false, locked: true)
        XCTAssertTrue(tracker.snapshot.held)
        tracker.observe(type: .leftMouseUp, key: 0, button: 0, flags: [], physical: false, locked: true)
        XCTAssertFalse(tracker.snapshot.held)

        tracker.observe(type: .flagsChanged, key: 55, button: 0, flags: .maskCommand, physical: false, locked: true)
        tracker.observe(type: .flagsChanged, key: 55, button: 0, flags: [], physical: true, locked: true)
        tracker.observe(type: .keyDown, key: 1, button: 0, flags: [], physical: false, locked: true)
        tracker.observe(type: .keyUp, key: 1, button: 0, flags: [], physical: false, locked: true)
        tracker.observe(type: .flagsChanged, key: 56, button: 0, flags: [], physical: false, locked: true)
        XCTAssertTrue(tracker.snapshot.held, "Unrelated automation must not release an explicit modifier hold")
        XCTAssertEqual(tracker.snapshot.flags, .maskCommand)
        XCTAssertEqual(tracker.snapshot.counts["injectedModifiers"], 1)
        tracker.observe(type: .flagsChanged, key: 55, button: 0, flags: [], physical: false, locked: true)
        XCTAssertFalse(tracker.snapshot.held)

        for flagsChangedRelease in [false, true] {
            tracker.observe(type: .keyDown, key: 58, button: 0, flags: .maskAlternate, physical: false, locked: true)
            tracker.observe(type: .flagsChanged, key: 56, button: 0, flags: [], physical: false, locked: true)
            tracker.observe(type: .keyDown, key: 1, button: 0, flags: [], physical: false, locked: true)
            tracker.observe(type: .keyUp, key: 1, button: 0, flags: [], physical: false, locked: true)
            XCTAssertEqual(tracker.snapshot.flags, .maskAlternate)
            tracker.observe(type: flagsChangedRelease ? .flagsChanged : .keyUp, key: 58, button: 0,
                            flags: [], physical: false, locked: true)
            XCTAssertFalse(tracker.snapshot.held)
        }

        tracker.observe(type: .flagsChanged, key: 55, button: 0, flags: .maskCommand, physical: false, locked: true)
        tracker.observe(type: .flagsChanged, key: 54, button: 0, flags: .maskCommand, physical: false, locked: true)
        tracker.observe(type: .flagsChanged, key: 55, button: 0, flags: .maskCommand, physical: false, locked: true)
        tracker.observe(type: .keyDown, key: 1, button: 0, flags: [], physical: false, locked: true)
        tracker.observe(type: .keyUp, key: 1, button: 0, flags: [], physical: false, locked: true)
        XCTAssertEqual(tracker.snapshot.flags, .maskCommand, "The other Command side is still held")
        tracker.observe(type: .flagsChanged, key: 54, button: 0, flags: [], physical: false, locked: true)
        XCTAssertFalse(tracker.snapshot.held)

        tracker.observe(type: .keyDown, key: 1, button: 0, flags: .maskCommand, physical: false, locked: true)
        tracker.observe(type: .keyUp, key: 1, button: 0, flags: [], physical: false, locked: true)
        XCTAssertFalse(tracker.snapshot.held, "Context-only flags still end with the ordinary key sequence")
    }

    func testOnlyActiveScopePulsesAndRequiresObservedIdleReset() {
        let driver = FakeIdleActivity()
        let activity = IdleActivityController(driver: driver)
        activity.update(active: false, at: 0)
        XCTAssertEqual(driver.sent, 0)
        XCTAssertNil(activity.update(active: true, at: 10))
        XCTAssertEqual(driver.sent, 1)
        XCTAssertEqual(activity.state, "verifying")
        XCTAssertEqual(activity.verifiedCount, 0)
        driver.system.idleSeconds = 1
        XCTAssertNil(activity.update(active: true, at: 11))
        XCTAssertEqual(activity.state, "verified")
        XCTAssertEqual(activity.verifiedCount, 1)
        driver.system.idleSeconds = 6
        activity.update(active: false, at: 16)
        XCTAssertEqual(driver.sent, 1)
        XCTAssertFalse(activity.scoped)
        XCTAssertEqual(activity.state, "inactive")
    }

    func testUnsafeSessionInputAndPermissionConditionsNeverPulse() {
        let changes: [(inout IdleActivitySnapshot) -> Void] = [
            { $0.permission = false }, { $0.sessionAvailable = false }, { $0.onConsole = false },
            { $0.screenLocked = true }, { $0.displayAsleep = true }, { $0.screenSaverRunning = true },
            { $0.secureInput = true }, { $0.inputHeld = true }
        ]
        for change in changes {
            let driver = FakeIdleActivity()
            change(&driver.system)
            let activity = IdleActivityController(driver: driver)
            XCTAssertNil(activity.update(active: true, at: 10))
            XCTAssertEqual(driver.sent, 0)
            XCTAssertTrue(activity.state.hasPrefix("paused:"))
        }
    }

    func testRecentInputSkipsPulseAndFailedIdleResetIsReported() {
        let driver = FakeIdleActivity()
        let activity = IdleActivityController(driver: driver)
        driver.system.idleSeconds = 1
        activity.update(active: true, at: 10)
        XCTAssertEqual(driver.sent, 0)
        driver.system.idleSeconds = 6
        activity.update(active: true, at: 15)
        driver.system.idleSeconds = 7
        XCTAssertNotNil(activity.update(active: true, at: 16))
        XCTAssertEqual(activity.state, "idle-reset-failed")
        XCTAssertEqual(activity.verifiedCount, 0)
        activity.update(active: true, at: 17)
        XCTAssertEqual(driver.sent, 1, "Failed verification must not generate an event every tick")
    }

}
