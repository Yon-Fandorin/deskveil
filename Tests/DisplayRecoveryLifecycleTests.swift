import XCTest
@testable import SoftLock

final class DisplayRecoveryLifecycleTests: XCTestCase {
    func testAbandonedShutdownReclaimsRecoveryWithoutResettingBudgetOrBackoff() {
        var recovery = DisplayRecoveryLifecycle(active: false, attempts: 2, retryAt: 10)
        recovery.resumeAfterInterruptedShutdown(pending: true)
        XCTAssertTrue(recovery.active); XCTAssertEqual(recovery.attempts, 2); XCTAssertEqual(recovery.retryAt, 10)
        XCTAssertFalse(recovery.canAttempt(guardianRunning: false, at: 9))
        XCTAssertTrue(recovery.canAttempt(guardianRunning: false, at: 10))
        var exhausted = DisplayRecoveryLifecycle(active: false, attempts: 3, retryAt: 10)
        exhausted.resumeAfterInterruptedShutdown(pending: true)
        XCTAssertFalse(exhausted.active); XCTAssertEqual(exhausted.attempts, 3)
        var clean = DisplayRecoveryLifecycle()
        clean.resumeAfterInterruptedShutdown(pending: false)
        XCTAssertFalse(clean.active)
    }
    private final class MemoryRecovery: BrightnessRecoveryStore {
        var values: [String: Float] = [:]
        func load() -> DisplayRecoveryLoad<[String: Float]> { values.isEmpty ? .absent : .loaded(values) }
        func save(_ values: [String: Float]) -> Bool { self.values = values; return true }
    }

    func testShownDashboardCannotLaunchAnObservationBeforeCrashRecovery() throws {
        let journal = MemoryRecovery()
        var value: Float = 0.8
        func driver() -> NativeBrightness {
            NativeBrightness(displays: { [1] }, read: { _ in value },
                write: { _, next in value = next; return true }, recovery: journal,
                blackoutEligible: { _ in false })
        }
        // Losing this owner models a crash: recovery survives in the journal.
        var original: NativeBrightness? = driver()
        let off = DisplayPowerCommand(displayID: 1, identity: "1", off: true)
        XCTAssertEqual(original?.controlDisplay(off), .off)
        original = nil
        XCTAssertEqual(value, 0)

        var recovery = DisplayRecoveryLifecycle()
        var helper: NativeBrightness?
        var commands: [String] = []
        func refreshShownDashboard() {
            guard recovery.canObserve(guardianRunning: helper != nil, pendingRecovery: !journal.values.isEmpty) else { return }
            if helper == nil { helper = driver() }
            commands.append("brightness-status")
            _ = helper?.observedBrightness(display: 1, identity: "1")
        }

        XCTAssertFalse(recovery.claimGuardianExit(pending: !journal.values.isEmpty))
        // Session cleanup can refresh the visible dashboard before the handler
        // dispatches restoration. Its read must not acquire the replacement.
        refreshShownDashboard()
        XCTAssertNil(helper)
        XCTAssertTrue(recovery.canAttempt(guardianRunning: helper != nil, at: 0))
        recovery.attempts += 1
        helper = driver()
        commands.append("restore-now")
        XCTAssertTrue(try XCTUnwrap(helper).restore())
        XCTAssertFalse(recovery.canAttempt(guardianRunning: true, at: 1))
        refreshShownDashboard()
        XCTAssertEqual(commands, ["restore-now"])
        XCTAssertEqual(value, 0.8)
        XCTAssertTrue(journal.values.isEmpty)

        recovery.complete() // Matching restoration acknowledgement.
        refreshShownDashboard()
        XCTAssertEqual(commands, ["restore-now", "brightness-status"])
    }

    func testCompletedRecoveryGivesLaterIndependentCrashesAFreshBudget() {
        let journal = MemoryRecovery()
        var value: Float = 0.8
        func driver() -> NativeBrightness {
            NativeBrightness(displays: { [1] }, read: { _ in value },
                write: { _, next in value = next; return true }, recovery: journal,
                blackoutEligible: { _ in false })
        }
        var recovery = DisplayRecoveryLifecycle()
        let off = DisplayPowerCommand(displayID: 1, identity: "1", off: true)
        // More independent successful recoveries than the per-recovery budget.
        for _ in 0..<4 {
            var owner: NativeBrightness? = driver()
            XCTAssertEqual(owner?.controlDisplay(off), .off)
            owner = nil
            XCTAssertEqual(value, 0)
            XCTAssertFalse(recovery.claimGuardianExit(pending: !journal.values.isEmpty))
            XCTAssertFalse(recovery.allowsObservation)
            XCTAssertEqual(recovery.attempts, 0)
            XCTAssertEqual(recovery.retryAt, 0)
            XCTAssertTrue(recovery.canAttempt(guardianRunning: false, at: 0))

            recovery.attempts += 1
            // A previous retry deadline must also end with this recovery.
            recovery.retryAt = 10
            let replacement = driver()
            XCTAssertTrue(replacement.restore())
            XCTAssertEqual(value, 0.8)
            XCTAssertTrue(journal.values.isEmpty)
            recovery.complete()
            XCTAssertTrue(recovery.allowsObservation)
            XCTAssertEqual(recovery.attempts, 0)
            XCTAssertEqual(recovery.retryAt, 0)
        }
    }

    func testExitPreservesAnExistingRecoveryAttemptAndItsRetryDeadline() {
        var recovery = DisplayRecoveryLifecycle(active: true, attempts: 2, retryAt: 10)
        XCTAssertTrue(recovery.claimGuardianExit(pending: true))
        XCTAssertEqual(recovery.attempts, 2)
        XCTAssertEqual(recovery.retryAt, 10)
        XCTAssertFalse(recovery.allowsObservation)
        XCTAssertFalse(recovery.canAttempt(guardianRunning: false, at: 9))
        XCTAssertTrue(recovery.canAttempt(guardianRunning: false, at: 10))
        XCTAssertFalse(recovery.canAttempt(guardianRunning: true, at: 10))
    }

    func testCleanExitAllowsObservationWithoutStartingRecovery() {
        var recovery = DisplayRecoveryLifecycle()
        XCTAssertFalse(recovery.claimGuardianExit(pending: false))
        XCTAssertTrue(recovery.allowsObservation)
        XCTAssertFalse(recovery.canAttempt(guardianRunning: false, at: 0))
        // Exhausted recovery still reports its prior attempt to the exit handler.
        recovery.attempts = 3
        XCTAssertTrue(recovery.claimGuardianExit(pending: true))
        XCTAssertEqual(recovery.attempts, 3)
    }

    func testObservationAdmissionRequiresAnOwnerWhenRecoveryIsPending() {
        let cases: [(active: Bool, running: Bool, pending: Bool, allowed: Bool)] = [
            (false, false, false, true),
            (false, false, true, false),
            (false, true, false, true),
            (false, true, true, true),
            (true, false, false, false),
            (true, false, true, false),
            (true, true, false, false),
            (true, true, true, false)
        ]
        for (active, running, pending, allowed) in cases {
            let recovery = DisplayRecoveryLifecycle(active: active)
            XCTAssertEqual(recovery.canObserve(guardianRunning: running, pendingRecovery: pending), allowed,
                           "active=\(active), running=\(running), pending=\(pending)")
        }
    }

    func testExhaustedRecoveryCannotRelaunchObservationHelpersOnRefresh() {
        var recovery = DisplayRecoveryLifecycle(active: false, attempts: 3, retryAt: 10)
        var guardianRunning = false
        var launches = 0
        func refreshShownDashboard() {
            guard recovery.canObserve(guardianRunning: guardianRunning, pendingRecovery: true) else { return }
            if !guardianRunning { launches += 1; guardianRunning = true }
        }
        // A failed recovery refreshes the UI, and subsequent UI ticks must not
        // bypass the exhausted retry budget by starting a read-only helper.
        for _ in 0..<4 {
            XCTAssertTrue(recovery.claimGuardianExit(pending: true))
            XCTAssertFalse(recovery.canAttempt(guardianRunning: guardianRunning, at: 20))
            refreshShownDashboard()
            XCTAssertFalse(guardianRunning)
        }
        XCTAssertEqual(launches, 0)
        XCTAssertTrue(recovery.allowsObservation, "Explicit user controls remain available")
        // A live individual-Off owner can still provide observations while its
        // recovery journal protects the intentionally dark display.
        XCTAssertTrue(recovery.canObserve(guardianRunning: true, pendingRecovery: true))
    }

    func testEmergencyRestoreAfterExhaustionKeepsWarningUntilVerifiedCompletion() {
        for succeeds in [true, false] {
            let journal = MemoryRecovery()
            var value: Float = 0.8, writable = true
            func driver() -> NativeBrightness {
                NativeBrightness(displays: { [1] }, read: { _ in value }, write: { _, next in
                    guard writable else { return false }; value = next; return true
                }, recovery: journal, blackoutEligible: { _ in false })
            }
            var oldOwner: NativeBrightness? = driver()
            XCTAssertEqual(oldOwner?.controlDisplay(.init(displayID: 1, identity: "1", off: true)), .off)
            oldOwner = nil
            var recovery = DisplayRecoveryLifecycle(active: false, attempts: 3, retryAt: 100)
            var issues = AppIssues()
            issues[.display] = recovery.recordGuardianExitIssue()

            // Emergency unlock's send cannot reach the absent owner. Its fresh
            // restore intent must own the bounded replacement attempt instead.
            XCTAssertTrue(recovery.requestRestore(pending: !journal.values.isEmpty, allowRestart: true))
            issues[.brightness] = recovery.issue
            XCTAssertNotNil(issues.current)
            XCTAssertEqual(recovery.attempts, 0)
            XCTAssertTrue(recovery.canAttempt(guardianRunning: false, at: 0))
            XCTAssertFalse(recovery.canObserve(guardianRunning: false, pendingRecovery: true))
            writable = succeeds
            for attempt in 1...(succeeds ? 1 : 3) {
                recovery.attempts += 1
                let replacement = driver()
                if replacement.restore() {
                    recovery.complete(issues: &issues)
                } else {
                    recovery.recordFailure(at: TimeInterval(attempt))
                    issues[.brightness] = recovery.issue
                    XCTAssertNotNil(issues.current)
                    XCTAssertFalse(journal.values.isEmpty)
                }
            }
            if succeeds {
                XCTAssertEqual(value, 0.8)
                XCTAssertTrue(journal.values.isEmpty)
                XCTAssertNil(issues.current)
                XCTAssertEqual(recovery.attempts, 0)
            } else {
                XCTAssertEqual(value, 0)
                XCTAssertEqual(recovery.attempts, 3)
                XCTAssertFalse(recovery.canAttempt(guardianRunning: false, at: 100))
                XCTAssertFalse(recovery.canObserve(guardianRunning: false, pendingRecovery: true))
                XCTAssertNotNil(issues[.brightness], "Exhaustion must retain an actionable warning")
            }
        }
    }

    func testCompletionClearsOnlyTheDisplayWarningOwnedByRecovery() {
        for replaced in [false, true] {
            var recovery = DisplayRecoveryLifecycle()
            var issues = AppIssues()
            issues[.display] = recovery.recordGuardianExitIssue()
            issues[.brightness] = "복원 대기"
            if replaced { issues[.display] = "다른 화면 작업 오류" }
            recovery.complete(issues: &issues)
            XCTAssertNil(issues[.brightness])
            XCTAssertEqual(issues[.display], replaced ? "다른 화면 작업 오류" : nil)
        }
    }

    func testShutdownRestoreCannotClaimAReplacementOrResetExhaustedBudget() {
        var recovery = DisplayRecoveryLifecycle(active: false, attempts: 3, retryAt: 100)
        XCTAssertFalse(recovery.requestRestore(pending: true, allowRestart: false))
        XCTAssertEqual(recovery.attempts, 3)
        XCTAssertEqual(recovery.retryAt, 100)
        XCTAssertFalse(recovery.canAttempt(guardianRunning: false, at: 200))
        XCTAssertNotNil(recovery.issue)
        XCTAssertFalse(recovery.requestRestore(pending: false, allowRestart: true))
    }

    func testNewOffDefersForAnOwnerGapButCanShareALiveIndividualOwner() {
        for running in [false, true] {
            let journal = MemoryRecovery()
            var values: [UInt32: Float] = [1: 0.8, 2: 0.6]
            func driver() -> NativeBrightness {
                NativeBrightness(displays: { [1, 2] }, read: { values[$0] },
                    write: { values[$0] = $1; return true }, recovery: journal,
                    blackoutEligible: { _ in false })
            }
            var owner: NativeBrightness? = driver()
            XCTAssertEqual(owner?.controlDisplay(.init(displayID: 1, identity: "1", off: true)), .off)
            if !running { owner = nil }
            var recovery = DisplayRecoveryLifecycle()
            let requested = DisplayPowerCommand(displayID: 2, identity: "2", off: true)
            if recovery.needsRestoreBeforeStartingGuardian(guardianRunning: running, pendingRecovery: !journal.values.isEmpty) {
                XCTAssertTrue(recovery.requestRestore(pending: true, allowRestart: true))
                XCTAssertTrue(recovery.canAttempt(guardianRunning: false, at: 0))
                let replacement = driver()
                XCTAssertTrue(replacement.restore())
                XCTAssertEqual(values, [1: 0.8, 2: 0.6], "The new Off is deferred until old output is restored")
                XCTAssertTrue(journal.values.isEmpty)
            } else {
                XCTAssertTrue(running)
                XCTAssertEqual(owner?.controlDisplay(requested), .off)
                XCTAssertEqual(values, [1: 0, 2: 0])
                XCTAssertEqual(journal.values, ["1": 0.8, "2": 0.6])
            }
        }
    }

    func testInputOnlyAndTrialAdmissionDeferUnresolvedDisplayRecovery() {
        let cases: [(active: Bool, attempts: Int, running: Bool, pending: Bool)] = [
            (true, 1, true, true),
            (true, 1, true, false), // Restoration acknowledgement still pending.
            (false, 3, false, true),
            (false, 3, true, true),
            (false, 0, false, true) // Old owner exited before its callback.
        ]
        for session in ["input-only", "trial"] {
            for (active, attempts, running, pending) in cases {
                let recovery = DisplayRecoveryLifecycle(active: active, attempts: attempts, retryAt: 100)
                XCTAssertFalse(AppDelegate.canStartInputSession(locked: false, recording: false,
                    restoring: false, coverActive: false, coverPreparing: false,
                    displayRecoveryUnresolved: recovery.blocksInputSession(
                        guardianRunning: running, pendingRecovery: pending)),
                    "\(session): active=\(active), attempts=\(attempts), running=\(running), pending=\(pending)")
            }
        }
        let clean = DisplayRecoveryLifecycle()
        XCTAssertTrue(AppDelegate.canStartInputSession(locked: false, recording: false,
            restoring: false, coverActive: false, coverPreparing: false,
            displayRecoveryUnresolved: clean.blocksInputSession(guardianRunning: false, pendingRecovery: false)))
    }

    func testInputAdmissionAllowsLiveIndividualOffOwnershipToTransferToGlobalDim() {
        let journal = MemoryRecovery()
        var value: Float = 0.8
        let owner = NativeBrightness(displays: { [1] }, read: { _ in value },
            write: { _, next in value = next; return true }, recovery: journal,
            blackoutEligible: { _ in false })
        XCTAssertEqual(owner.controlDisplay(.init(displayID: 1, identity: "1", off: true)), .off)
        let recovery = DisplayRecoveryLifecycle()
        XCTAssertTrue(AppDelegate.canStartInputSession(locked: false, recording: false,
            restoring: false, coverActive: false, coverPreparing: false,
            displayRecoveryUnresolved: recovery.blocksInputSession(
                guardianRunning: true, pendingRecovery: !journal.values.isEmpty)))
        XCTAssertEqual(owner.dim(), 1)
        XCTAssertTrue(owner.restore())
        XCTAssertEqual(value, 0.8)
        XCTAssertTrue(journal.values.isEmpty)
    }

    func testExternallyCompletedRecoveryRetiresHistoryBeforeANewMutation() {
        for individual in [true, false] {
            let journal = MemoryRecovery()
            var value: Float = 0.8
            func driver() -> NativeBrightness {
                NativeBrightness(displays: { [1] }, read: { _ in value },
                    write: { _, next in value = next; return true }, recovery: journal,
                    blackoutEligible: { _ in false })
            }
            let off = DisplayPowerCommand(displayID: 1, identity: "1", off: true)
            var original: NativeBrightness? = driver()
            XCTAssertEqual(original?.controlDisplay(off), .off)
            original = nil
            var recovery = DisplayRecoveryLifecycle(active: false, attempts: 3, retryAt: 100)
            var issues = AppIssues()
            issues[.display] = recovery.recordGuardianExitIssue()
            issues[.brightness] = recovery.issue

            // A different owner restores the journal without this app's ack.
            XCTAssertTrue(driver().restore())
            XCTAssertTrue(journal.values.isEmpty)
            issues[.display] = "새로운 별도 화면 오류"
            if !individual {
                XCTAssertTrue(AppDelegate.canStartInputSession(locked: false, recording: false,
                    restoring: false, coverActive: false, coverPreparing: false,
                    displayRecoveryUnresolved: recovery.blocksInputSession(
                        guardianRunning: false, pendingRecovery: !journal.values.isEmpty)))
            }
            recovery.prepareNewMutation(pendingRecovery: !journal.values.isEmpty, issues: &issues)
            XCTAssertEqual(recovery.attempts, 0)
            XCTAssertEqual(recovery.retryAt, 0)
            XCTAssertNil(issues[.brightness])
            XCTAssertEqual(issues[.display], "새로운 별도 화면 오류")

            var nextOwner: NativeBrightness? = driver()
            if individual { XCTAssertEqual(nextOwner?.controlDisplay(off), .off) }
            else { XCTAssertEqual(nextOwner?.dim(), 1) }
            nextOwner = nil
            XCTAssertFalse(recovery.claimGuardianExit(pending: !journal.values.isEmpty))
            XCTAssertTrue(recovery.active)
            XCTAssertEqual(recovery.attempts, 0)
            XCTAssertTrue(recovery.canAttempt(guardianRunning: false, at: 0))
            XCTAssertFalse(recovery.canObserve(guardianRunning: false, pendingRecovery: true))
        }

        var awaitingAck = DisplayRecoveryLifecycle(active: true, attempts: 1, retryAt: 10)
        var issues = AppIssues()
        issues[.brightness] = awaitingAck.issue
        awaitingAck.prepareNewMutation(pendingRecovery: false, issues: &issues)
        XCTAssertTrue(awaitingAck.active, "Empty storage cannot bypass an active acknowledgement fence")
        XCTAssertEqual(awaitingAck.attempts, 1)
        XCTAssertNotNil(issues[.brightness])
    }
}
