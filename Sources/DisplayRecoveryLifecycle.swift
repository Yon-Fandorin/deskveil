import Foundation

/// Recovery owns replacement-helper startup before dashboard observations can.
struct DisplayRecoveryLifecycle {
    var active = false
    var attempts = 0
    var retryAt: TimeInterval = 0
    private(set) var displayIssue: String?
    var allowsObservation: Bool { !active }
    var issue: String? {
        if active { return L10n.text("화면 복구를 시도하고 있습니다. 복원이 확인될 때까지 기다려주세요.") }
        if attempts > 0 { return L10n.text("화면 복구를 시작하지 못했습니다. 긴급 해제로 다시 시도하거나 DeskVeil을 다시 실행해주세요.") }
        return nil
    }

    /// A new explicit restore gets a fresh bounded retry budget. Shutdown may
    /// still send to its current helper, but must not claim a replacement.
    @discardableResult
    mutating func requestRestore(pending: Bool, allowRestart: Bool) -> Bool {
        guard pending, allowRestart else { return false }
        active = true
        attempts = 0
        retryAt = 0
        return true
    }

    mutating func recordFailure(at now: TimeInterval) {
        active = attempts < 3
        retryAt = now + 1
    }

    mutating func recordGuardianExitIssue() -> String {
        let message = L10n.text("화면 보조 프로세스가 종료됐습니다. 계속 어두우면 DeskVeil을 다시 실행해주세요.")
        displayIssue = message
        return message
    }

    mutating func complete(issues: inout AppIssues) {
        if let displayIssue, issues[.display] == displayIssue { issues[.display] = nil }
        issues[.brightness] = nil
        complete()
    }

    /// Another recovery owner can finish without delivering this app an ack.
    /// Retire that history only after admission verifies no journal remains.
    mutating func prepareNewMutation(pendingRecovery: Bool, issues: inout AppIssues) {
        guard !active, !pendingRecovery, attempts > 0 || displayIssue != nil else { return }
        complete(issues: &issues)
    }

    /// Acknowledged restoration releases ownership and the completed retry budget.
    mutating func complete() {
        active = false
        attempts = 0
        retryAt = 0
        displayIssue = nil
    }

    /// Return whether an earlier recovery attempt needs its failure recorded.
    /// Claim new recovery synchronously, before any UI refresh can reenter.
    mutating func claimGuardianExit(pending: Bool) -> Bool {
        let wasRecovering = active || attempts > 0
        if pending && !wasRecovering {
            active = true
            attempts = 0
            retryAt = 0
        }
        return wasRecovering
    }

    /// A failed relaunch returns the lifetime to this app after the closing
    /// helper has exited. Keep the existing retry budget and backoff intact.
    mutating func resumeAfterInterruptedShutdown(pending: Bool) {
        if pending && attempts < 3 { active = true }
    }

    func canAttempt(guardianRunning: Bool, at now: TimeInterval) -> Bool {
        active && !guardianRunning && now >= retryAt
    }

    /// Observations may share an existing owner, but cannot launch an owner
    /// that would load pending recovery without any restoration intent.
    func canObserve(guardianRunning: Bool, pendingRecovery: Bool) -> Bool {
        !active && !needsRestoreBeforeStartingGuardian(guardianRunning: guardianRunning, pendingRecovery: pendingRecovery)
    }

    func needsRestoreBeforeStartingGuardian(guardianRunning: Bool, pendingRecovery: Bool) -> Bool {
        !guardianRunning && pendingRecovery
    }

    /// A live individual-Off owner can transfer to a global session. Unresolved
    /// restoration must keep its acknowledgement, warning and retry ownership.
    func blocksInputSession(guardianRunning: Bool, pendingRecovery: Bool) -> Bool {
        active || (pendingRecovery && (attempts > 0 || !guardianRunning))
    }
}
