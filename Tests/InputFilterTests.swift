import CoreGraphics
import XCTest
@testable import SoftLock

final class InputFilterTests: XCTestCase {
    func testFirstReleaseIntentSurvivesLaterHealthSignalsUntilConfigurationChanges() {
        let filter = InputFilter(seedInput: { _ in })
        filter.configure(locked: true, shortcut: 37)
        _ = filter.handle(type: .keyDown, event: event(.keyDown, key: 37, flags: [.maskControl,.maskCommand,.maskAlternate]))
        XCTAssertEqual(filter.snapshot.releasedBy, .unlock)
        _ = filter.handle(type: .tapDisabledByTimeout, event: event(.mouseMoved))
        filter.checkHealth(at: ProcessInfo.processInfo.systemUptime + 5)
        filter.heartbeat(); filter.markObservationGap()
        XCTAssertEqual(filter.snapshot.releasedBy, .unlock)
        filter.configure(locked: false, shortcut: 37)
        XCTAssertNil(filter.snapshot.releasedBy)
    }

    func testFreshEmergencyOverridesAutomaticReleaseIntent() {
        let filter = InputFilter(seedInput: { _ in })
        filter.configure(locked: true, shortcut: 37)
        filter.checkHealth(at: ProcessInfo.processInfo.systemUptime + 5)
        XCTAssertEqual(filter.snapshot.releasedBy, .unresponsive)
        _ = filter.handle(type: .keyDown, event: event(.keyDown, key: 32, flags: [.maskControl,.maskCommand,.maskAlternate]))
        XCTAssertEqual(filter.snapshot.releasedBy, .emergency)
        filter.stop(); XCTAssertNil(filter.snapshot.releasedBy)
    }
    func testQueuedRecoveryCannotReleaseAReplacementSession() {
        for expired in [true, false] {
            let filter = InputFilter()
            var deliveries = 0
            filter.onAction = { _ in deliveries += 1 }
            filter.configure(locked: true, shortcut: 37, deadline: ProcessInfo.processInfo.systemUptime - 1)
            if expired { filter.checkHealth() }
            else { _ = filter.handle(type: .tapDisabledByTimeout, event: event(.mouseMoved)) }
            filter.configure(locked: false, shortcut: 37)
            filter.configure(locked: true, shortcut: 37)
            let drained = expectation(description: "previous action queue drained")
            DispatchQueue.main.async { drained.fulfill() }
            wait(for: [drained], timeout: 1)
            XCTAssertEqual(deliveries, 0, "Old expiry/interruption must not reach a new session")
            XCTAssertTrue(filter.snapshot.locked)
        }
    }

    func testExplicitEmergencySurvivesTheQueuedLockItFollows() {
        let filter = InputFilter()
        var emergencyDelivered = false
        filter.configure(locked: false, shortcut: 37)
        filter.onAction = { action in
            if case .lock = action { filter.configure(locked: true, shortcut: 37) }
            if case .emergency = action {
                emergencyDelivered = true; filter.configure(locked: false, shortcut: 37)
            }
        }
        _ = filter.handle(type: .keyDown, event: event(.keyDown, key: 37, flags: [.maskControl,.maskCommand,.maskAlternate]))
        _ = filter.handle(type: .keyDown, event: event(.keyDown, key: 32, flags: [.maskControl,.maskCommand,.maskAlternate]))
        let drained = expectation(description: "queued explicit input drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertTrue(emergencyDelivered)
        XCTAssertFalse(filter.snapshot.locked)
    }

    private func event(_ type: CGEventType, key: Int64 = 0, pid: Int64 = 0,
                       flags: CGEventFlags = []) -> CGEvent {
        let event = CGEvent(source: nil)!
        // Private gesture events have an OS-specific payload. Do not ask Quartz to construct
        // one from an empty generic event; pass the callback type separately instead.
        event.type = type.rawValue >= 28 ? .mouseMoved : type
        event.flags = flags
        event.setIntegerValueField(.eventSourceStateID, value: 1)
        event.setIntegerValueField(.eventSourceUnixProcessID, value: pid)
        event.setIntegerValueField(.keyboardEventKeycode, value: key)
        return event
    }

    func testPhysicalReleasesAreTrackedAndAutomationPasses() {
        let filter = InputFilter()
        filter.configure(locked: true, shortcut: 37)
        XCTAssertTrue(filter.handle(type: .keyDown, event: event(.keyDown, key: 0)) == nil)
        XCTAssertTrue(filter.snapshot.heldInput.held)
        XCTAssertTrue(filter.handle(type: .keyUp, event: event(.keyUp, key: 0)) == nil)
        XCTAssertFalse(filter.snapshot.heldInput.held)
        XCTAssertTrue(filter.handle(type: .keyDown, event: event(.keyDown, key: 0, pid: 42)) != nil)
        XCTAssertTrue(filter.snapshot.heldInput.held)
        XCTAssertTrue(filter.handle(type: .keyUp, event: event(.keyUp, key: 0, pid: 42)) != nil)
        XCTAssertFalse(filter.snapshot.heldInput.held)
        XCTAssertEqual(filter.snapshot.blocked, 2)
        XCTAssertEqual(filter.snapshot.passed, 2)
    }

    func testUnlockIntentIsExplicitAndRepeatedShortcutDoesNotToggleAgain() {
        let filter = InputFilter()
        filter.configure(locked: true, shortcut: 37)
        let delivered = expectation(description: "unlock delivered on main")
        delivered.assertForOverFulfill = true
        filter.onAction = { action in
            XCTAssertTrue(Thread.isMainThread)
            if case .unlock = action { delivered.fulfill() } else { XCTFail("unexpected action") }
        }
        let chord = event(.keyDown, key: 37, flags: [.maskControl, .maskCommand, .maskAlternate])
        XCTAssertTrue(filter.handle(type: .keyDown, event: chord) == nil)
        XCTAssertFalse(filter.snapshot.locked)
        XCTAssertTrue(filter.handle(type: .keyDown, event: chord) == nil)
        let repeatWithoutModifiers = event(.keyDown, key: 37)
        repeatWithoutModifiers.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        XCTAssertTrue(filter.handle(type: .keyDown, event: repeatWithoutModifiers) == nil,
                      "Releasing modifiers must not leak the held shortcut's autorepeat")
        filter.suspendShortcuts(true) // Recording can start before the original key is released.
        XCTAssertTrue(filter.handle(type: .keyUp, event: event(.keyUp, key: 37)) == nil)
        filter.suspendShortcuts(false)
        XCTAssertTrue(filter.handle(type: .keyDown, event: event(.keyDown, key: 37)) != nil)
        wait(for: [delivered], timeout: 1)
    }

    func testGatedUnlockKeepsBlockingPhysicalInputButAllowsAutomation() {
        let filter = InputFilter()
        filter.configure(locked: true, shortcut: 37, deferManualUnlock: true)
        let delivered = expectation(description: "gated unlock requested")
        filter.onAction = { action in
            if case .unlock = action { delivered.fulfill() } else { XCTFail("unexpected action") }
        }
        _ = filter.handle(type: .keyDown, event: event(.keyDown, key: 37,
            flags: [.maskControl, .maskCommand, .maskAlternate]))
        XCTAssertTrue(filter.snapshot.locked)
        XCTAssertNil(filter.snapshot.releasedBy)
        XCTAssertTrue(filter.handle(type: .keyDown, event: event(.keyDown, key: 0)) == nil)
        XCTAssertTrue(filter.handle(type: .keyDown, event: event(.keyDown, key: 0, pid: 42)) != nil)
        wait(for: [delivered], timeout: 1)
        filter.configure(locked: false, shortcut: 37) // Owner has confirmed macOS lock.
        XCTAssertTrue(filter.handle(type: .keyDown, event: event(.keyDown, key: 0)) != nil)
    }

    func testCaptureGestureIsSuppressedThroughReleaseBeforeFreshActivation() {
        let filter = InputFilter()
        filter.configure(locked: false, shortcut: 37)
        filter.suspendShortcuts(true)
        let chord = event(.keyDown, key: 37, flags: [.maskControl,.maskCommand,.maskAlternate])
        XCTAssertTrue(filter.handle(type: .keyDown, event: chord) != nil)
        XCTAssertTrue(filter.captureGestureInFlight)
        filter.suspendShortcuts(false)
        let repeated = event(.keyDown, key: 37, flags: chord.flags)
        repeated.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        XCTAssertTrue(filter.handle(type: .keyDown, event: repeated) == nil)
        XCTAssertTrue(filter.handle(type: .keyUp, event: event(.keyUp, key: 37)) == nil)
        XCTAssertFalse(filter.captureGestureInFlight)
        let delivered = expectation(description: "fresh press activates")
        filter.onAction = { if case .lock = $0 { delivered.fulfill() } }
        _ = filter.handle(type: .keyDown, event: chord)
        wait(for: [delivered], timeout: 1)
    }
    func testCustomEmergencyWorksWhileOldDefaultRemainsBlocked() {
        let filter = InputFilter()
        let rescue = KeyboardShortcut(keyCode: 6, modifiers: 4608)
        filter.configure(locked: true, normal: .normal, emergency: rescue, deferManualUnlock: true)
        _ = filter.handle(type: .keyDown, event: event(.keyDown, key: 32, flags: [.maskCommand,.maskAlternate,.maskControl]))
        XCTAssertTrue(filter.snapshot.locked)
        _ = filter.handle(type: .keyDown, event: event(.keyDown, key: 6, flags: [.maskControl,.maskShift]))
        XCTAssertFalse(filter.snapshot.locked)
    }
    func testRecoveryReleasesInputWithoutWaitingForMainQueue() {
        let now = ProcessInfo.processInfo.systemUptime
        let recoveries: [(String, TimeInterval?, (InputFilter) -> Void)] = [
            ("emergency shortcut", nil, { filter in
                _ = filter.handle(type: .keyDown, event: self.event(.keyDown, key: 32,
                    flags: [.maskControl, .maskCommand, .maskAlternate]))
            }),
            ("disabled event tap", nil, { filter in
                _ = filter.handle(type: .tapDisabledByTimeout, event: self.event(.mouseMoved))
            }),
            ("main heartbeat loss", nil, { $0.checkHealth(at: now + 5) }),
            ("trial expiry", now + 3, { $0.checkHealth(at: now + 3) })
        ]
        for (reason, deadline, recover) in recoveries {
            let filter = InputFilter()
            filter.configure(locked: true, shortcut: 37, deadline: deadline, deferManualUnlock: true)
            filter.checkHealth(at: now + 2)
            XCTAssertTrue(filter.snapshot.locked, reason)
            recover(filter)
            XCTAssertFalse(filter.snapshot.locked, reason)
            XCTAssertTrue(filter.handle(type: .keyDown, event: event(.keyDown)) != nil, reason)
        }
    }

    func testIdlePulseIsDiscardedWhenInputChangesBeforeDelivery() {
        let filter = InputFilter()
        let pulse = event(.flagsChanged, pid: 42)
        pulse.setIntegerValueField(.eventSourceUserData, value: 0x534C4944)
        filter.configure(locked: true, shortcut: 37)
        XCTAssertTrue(filter.handle(type: .flagsChanged, event: pulse) != nil)
        _ = filter.handle(type: .keyDown, event: event(.keyDown, key: 0, pid: 42, flags: .maskCommand))
        XCTAssertTrue(filter.handle(type: .flagsChanged, event: pulse) == nil)
        XCTAssertTrue(filter.snapshot.heldInput.held)
        _ = filter.handle(type: .keyUp, event: event(.keyUp, key: 0, pid: 42))
        XCTAssertTrue(filter.handle(type: .flagsChanged, event: pulse) != nil)
        filter.configure(locked: false, shortcut: 37)
        XCTAssertTrue(filter.handle(type: .flagsChanged, event: pulse) == nil)
    }

    func testObservationGapReseedsCurrentInputOnlyAfterSafeResume() {
        var currentKeys: Set<Int64> = []
        var seedCount = 0
        var reseededState: HeldInputSnapshot?
        let filter = InputFilter(seedInput: { tracker in
            tracker.seed(keys: currentKeys, buttons: [], flags: [])
            seedCount += 1; reseededState = tracker.snapshot
        })
        filter.configure(locked: true, shortcut: 37)
        _ = filter.handle(type: .keyDown, event: event(.keyDown, key: 0))
        filter.markObservationGap()
        XCTAssertFalse(filter.resumeObservation(secureInput: false, consoleActive: true, observationEnabled: true))
        XCTAssertEqual(filter.snapshot.heldInput.counts["physicalKeys"], 1)
        filter.configure(locked: false, shortcut: 37)
        XCTAssertFalse(filter.resumeObservation(secureInput: true, consoleActive: true, observationEnabled: true))
        XCTAssertFalse(filter.resumeObservation(secureInput: false, consoleActive: false, observationEnabled: true))
        XCTAssertFalse(filter.resumeObservation(secureInput: false, consoleActive: true, observationEnabled: false))
        XCTAssertEqual(seedCount, 0)
        currentKeys = [12] // Physical input changed while no events were observable.
        XCTAssertTrue(filter.resumeObservation(secureInput: false, consoleActive: true, observationEnabled: true))
        XCTAssertEqual(seedCount, 1)
        XCTAssertEqual(reseededState?.counts["seededKeys"], 1)
        XCTAssertEqual(reseededState?.counts["physicalKeys"], 0)
        XCTAssertEqual(reseededState?.held, true)
        XCTAssertFalse(filter.resumeObservation(secureInput: false, consoleActive: true, observationEnabled: true))
    }

}
