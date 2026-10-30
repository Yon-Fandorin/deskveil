import XCTest
@testable import SoftLock

private final class FakeScreenLock: ScreenLockDriver {
    var available = true
    var current: ScreenLockState = .unlocked
    var accepted = true
    var presented = true
    var onRequest: (() -> Void)?
    var requests = 0
    func screenState() -> ScreenLockState { current }
    func lockScreenReady() -> Bool { presented }
    func requestLock() -> Bool { requests += 1; onRequest?(); return accepted }
}

final class ScreenLockTests: XCTestCase {
    func testFailureReasonIsSeparateFromLocalizedRecoveryInstructions() {
        let handoff = ScreenLockHandoff(driver: FakeScreenLock(), clock: { 0 })
        let reason = "Opaque reason: 입력 차단은 유지"
        handoff.emergencyLabel = "⌃⌥⌘U"
        guard case .failed(let message) = handoff.preparationFailed(reason) else {
            return XCTFail("Expected preparation failure")
        }
        XCTAssertEqual(handoff.failureReason, reason)
        XCTAssertTrue(message.hasPrefix(reason))
        XCTAssertTrue(message.contains(handoff.emergencyLabel))
        handoff.reset()
        XCTAssertNil(handoff.failureReason)
    }

    func testFailedUnconfirmedHandoffCannotKeepDeferringSecureInputRecovery() {
        let driver = FakeScreenLock()
        let handoff = ScreenLockHandoff(driver: driver, clock: { 0 })
        XCTAssertEqual(handoff.begin(at: 10), .waiting)
        XCTAssertTrue(handoff.pending)
        if case .failed = handoff.poll(at: 16) {} else { XCTFail("Expected bounded handoff timeout") }
        XCTAssertEqual(handoff.state, "failed")
        XCTAssertFalse(handoff.pending)
        XCTAssertFalse(handoff.keepCoverOnInputInterruption)
        XCTAssertEqual(driver.current, .unlocked)
    }

    func testLogicalLockDoesNotRevealBeforeOpaqueLoginSurfaceSettles() {
        let driver = FakeScreenLock()
        driver.presented = false
        let handoff = ScreenLockHandoff(driver: driver, clock: { 0 })
        _ = handoff.begin(at: 10)
        driver.current = .locked
        XCTAssertEqual(handoff.poll(at: 10.1), .waiting)
        XCTAssertEqual(handoff.poll(at: 11), .waiting)
        driver.presented = true
        XCTAssertEqual(handoff.poll(at: 11.1), .waiting)
        XCTAssertEqual(handoff.poll(at: 11.41), .confirmed)
    }

    func testInterruptedLoginSurfaceMustSettleAgain() {
        let driver = FakeScreenLock()
        let handoff = ScreenLockHandoff(driver: driver, clock: { 0 })
        _ = handoff.begin(at: 10)
        driver.current = .locked
        _ = handoff.poll(at: 10.1)
        driver.presented = false
        XCTAssertEqual(handoff.poll(at: 10.3), .waiting)
        driver.presented = true
        XCTAssertEqual(handoff.poll(at: 10.4), .waiting)
        XCTAssertEqual(handoff.poll(at: 10.6), .waiting)
        XCTAssertEqual(handoff.poll(at: 10.71), .confirmed)
    }

    func testInputInterruptionOnlyKeepsCoverAfterActualLockEvidence() {
        let driver = FakeScreenLock()
        let handoff = ScreenLockHandoff(driver: driver, clock: { 0 })
        _ = handoff.begin(at: 10)
        XCTAssertFalse(handoff.keepCoverOnInputInterruption)
        driver.current = .unavailable
        XCTAssertFalse(handoff.keepCoverOnInputInterruption)
        driver.current = .locked
        XCTAssertTrue(handoff.keepCoverOnInputInterruption)
        _ = handoff.poll(at: 10.1)
        driver.current = .unlocked
        XCTAssertTrue(handoff.keepCoverOnInputInterruption)
        XCTAssertEqual(handoff.poll(at: 10.41), .confirmed)
        XCTAssertFalse(handoff.keepCoverOnInputInterruption)
        handoff.reset()
        XCTAssertFalse(handoff.keepCoverOnInputInterruption)
    }

    func testFastAuthenticationDuringCoveredTransitionStillCompletes() {
        let driver = FakeScreenLock()
        var now: TimeInterval = 10
        let handoff = ScreenLockHandoff(driver: driver, clock: { now })
        driver.onRequest = { [weak driver] in now = 10.5; driver?.current = .locked }
        _ = handoff.begin(at: 10)
        driver.current = .unlocked
        XCTAssertEqual(handoff.poll(at: 10.6), .waiting, "Request latency is not lock settling time")
        XCTAssertEqual(handoff.poll(at: 10.81), .confirmed)
    }

    func testLockAtRequestDeadlineHasTimeToFinishTransition() {
        let driver = FakeScreenLock()
        let handoff = ScreenLockHandoff(driver: driver, clock: { 0 })
        _ = handoff.begin(at: 10)
        driver.current = .locked
        XCTAssertEqual(handoff.poll(at: 15), .waiting)
        XCTAssertEqual(handoff.poll(at: 15.31), .confirmed)
    }

    func testRequestDoesNotConfirmOrRepeatBeforeObservedLock() {
        let driver = FakeScreenLock()
        let handoff = ScreenLockHandoff(driver: driver, settleDuration: 0, clock: { 0 })
        XCTAssertEqual(handoff.begin(at: 10), .waiting)
        XCTAssertEqual(handoff.begin(at: 11), .waiting)
        XCTAssertEqual(driver.requests, 1)
        XCTAssertEqual(handoff.poll(at: 12), .waiting)
        driver.current = .unavailable // Session resignation is not lock confirmation.
        XCTAssertEqual(handoff.poll(at: 13), .waiting)
        driver.current = .locked
        XCTAssertEqual(handoff.poll(at: 14), .confirmed)
        XCTAssertFalse(handoff.pending)
        XCTAssertEqual(handoff.state, "confirmed")
    }

    func testTimeoutKeepsConfirmationRequiredAndCanRetry() {
        let driver = FakeScreenLock()
        let handoff = ScreenLockHandoff(driver: driver, settleDuration: 0, clock: { 0 })
        _ = handoff.begin(at: 10)
        guard case .failed = handoff.poll(at: 15) else { return XCTFail("false success") }
        XCTAssertTrue(handoff.requiresConfirmation)
        XCTAssertFalse(handoff.pending)
        XCTAssertEqual(handoff.begin(at: 20), .waiting)
        XCTAssertEqual(driver.requests, 2)
    }

    func testDelayedLockAfterTimeoutStillConfirms() {
        let driver = FakeScreenLock()
        let handoff = ScreenLockHandoff(driver: driver, settleDuration: 0, clock: { 0 })
        _ = handoff.begin(at: 10)
        _ = handoff.poll(at: 15)
        driver.current = .locked
        XCTAssertEqual(handoff.poll(at: 16), .confirmed)
    }

}
