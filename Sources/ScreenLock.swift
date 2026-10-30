import CoreGraphics
import Darwin
import Foundation

enum ScreenLockState: String { case locked, unlocked, unavailable }

protocol ScreenLockDriver {
    var available: Bool { get }
    func screenState() -> ScreenLockState
    func lockScreenReady() -> Bool
    func requestLock() -> Bool
}

/// Runtime-bound private API, also used by Hammerspoon. A returned call is only
/// a request; the session dictionary must independently confirm the lock.
final class NativeScreenLock: ScreenLockDriver {
    private typealias Lock = @convention(c) () -> Void
    private let library: UnsafeMutableRawPointer?
    private let lockScreen: Lock?

    init() {
        library = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY)
        if let library, let symbol = dlsym(library, "SACLockScreenImmediate") {
            lockScreen = unsafeBitCast(symbol, to: Lock.self)
        } else { lockScreen = nil }
    }

    deinit { if let library { dlclose(library) } }
    var available: Bool { lockScreen != nil }

    func screenState() -> ScreenLockState {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return .unavailable }
        if session["CGSSessionScreenIsLocked"] as? Bool == true { return .locked }
        guard session[kCGSessionOnConsoleKey as String] as? Bool == true else { return .unavailable }
        return .unlocked
    }

    func lockScreenReady() -> Bool {
        // A session can be locked while loginwindow's full-screen surface is
        // still transparent. Read window metadata only; no screen capture.
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        var loginPIDs = Set<pid_t>()
        let opaque = windows.compactMap { window -> CGRect? in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let alpha = window[kCGWindowAlpha as String] as? Double, alpha >= 0.999,
                  let level = window[kCGWindowLayer as String] as? Int,
                  level > CGWindowLevelForKey(.screenSaverWindow),
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            if !loginPIDs.contains(pid) {
                var path = [CChar](repeating: 0, count: 4096)
                guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                      String(cString: path) == "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow" else { return nil }
                loginPIDs.insert(pid)
            }
            return rect
        }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).allSatisfy { display in
            opaque.contains { $0.contains(CGDisplayBounds(display)) }
        }
    }

    func requestLock() -> Bool {
        guard let lockScreen else { return false }
        lockScreen()
        return true
    }
}

enum ScreenLockHandoffResult: Equatable {
    case waiting, confirmed, failed(String)
}

/// Confirmation gate only. AppDelegate retains ownership of input, brightness,
/// and power until this gate confirms macOS has taken over.
final class ScreenLockHandoff {
    private let driver: ScreenLockDriver
    private let timeout: TimeInterval
    private let settleDuration: TimeInterval
    private let clock: () -> TimeInterval
    private var deadline: TimeInterval?
    private var observedLockAt: TimeInterval?
    private var presentationReadyAt: TimeInterval?
    private var failure: String?
    private(set) var failureReason: String?
    private(set) var state = "idle"
    private(set) var requestSubmitted = false
    var emergencyLabel = KeyboardShortcut.emergency.label
    var pending: Bool { deadline != nil }
    var requiresConfirmation: Bool { pending || state == "failed" }
    // Secure login can disable the event tap. Once the OS lock is observed,
    // that interruption must not uncover the desktop before settling finishes.
    var keepCoverOnInputInterruption: Bool {
        requiresConfirmation && (observedLockAt != nil || driver.screenState() == .locked)
    }
    var available: Bool { driver.available }
    var screenState: ScreenLockState { driver.screenState() }

    init(driver: ScreenLockDriver, timeout: TimeInterval = 5, settleDuration: TimeInterval = 0.3,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.driver = driver; self.timeout = timeout; self.settleDuration = settleDuration; self.clock = clock
    }

    func begin(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> ScreenLockHandoffResult {
        guard !pending else { return .waiting }
        presentationReadyAt = nil
        failureReason = nil
        let started = clock()
        let current = driver.screenState()
        let observedAt = now + max(0, clock() - started)
        if current == .locked {
            deadline = observedAt + timeout
            observedLockAt = observedAt
            state = "settling"
            return poll(at: observedAt)
        }
        guard driver.available, current == .unlocked else {
            return fail(L10n.text("macOS 잠금을 요청할 수 없습니다."))
        }
        deadline = observedAt + timeout
        observedLockAt = nil
        failure = nil
        requestSubmitted = false
        state = "waiting"
        let requestedAt = clock()
        guard driver.requestLock() else { return fail(L10n.text("macOS 잠금 요청에 실패했습니다.")) }
        requestSubmitted = true
        // A synchronous request can take time. Start settling at the actual
        // post-call observation, while preserving an explicitly supplied test clock.
        return poll(at: observedAt + max(0, clock() - requestedAt))
    }

    func poll(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> ScreenLockHandoffResult {
        guard requiresConfirmation else {
            return state == "confirmed" ? .confirmed : .failed(L10n.text("잠금 전환이 취소됐습니다."))
        }
        let started = clock()
        let current = driver.screenState()
        let observedAt = now + max(0, clock() - started)
        if current == .locked && observedLockAt == nil {
            observedLockAt = observedAt
            deadline = max(deadline ?? observedAt, observedAt + settleDuration + 1)
        }
        if let observedLockAt {
            state = "settling"
            // A return to the unlocked console after an observed lock means macOS
            // has already authenticated the user (including Touch ID / Watch).
            if current == .unlocked && observedAt - observedLockAt >= settleDuration { return confirm() }
            let checkingAt = clock()
            let ready = current == .locked && driver.lockScreenReady()
            let checkedAt = observedAt + max(0, clock() - checkingAt)
            if ready {
                if presentationReadyAt == nil {
                    presentationReadyAt = checkedAt
                    deadline = max(deadline ?? checkedAt, checkedAt + settleDuration + 1)
                }
                if checkedAt - presentationReadyAt! >= settleDuration { return confirm() }
            } else { presentationReadyAt = nil }
        }
        guard let deadline else { return .failed(failure ?? L10n.text("잠금 전환이 취소됐습니다.")) }
        if observedAt >= deadline { return fail(L10n.text("macOS 잠금을 확인하지 못했습니다.")) }
        return .waiting
    }

    func reset() { deadline = nil; observedLockAt = nil; presentationReadyAt = nil; failure = nil; failureReason = nil; state = "idle"; requestSubmitted = false }
    func cancel() { deadline = nil; observedLockAt = nil; presentationReadyAt = nil; state = "cancelled" }
    func preparationFailed(_ reason: String) -> ScreenLockHandoffResult { fail(reason) }
    private func confirm() -> ScreenLockHandoffResult {
        deadline = nil; state = "confirmed"
        return .confirmed
    }
    private func fail(_ reason: String) -> ScreenLockHandoffResult {
        deadline = nil; observedLockAt = nil; presentationReadyAt = nil; state = "failed"
        let message = reason + L10n.text(" 입력 차단은 유지됩니다. %@로 긴급 해제할 수 있습니다.", String(describing: emergencyLabel))
        failureReason = reason
        failure = message
        return .failed(message)
    }
}
