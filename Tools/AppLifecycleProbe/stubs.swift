import Foundation
import CoreGraphics

// This probe links no AppDelegate initialization, native panels, brightness,
// event-tap startup, power controller, installer or updater implementation.
func AXIsProcessTrusted() -> Bool { true }
func IsSecureEventInputEnabled() -> Bool { false }
final class Trace { var values: [String] = [] }
final class RelaunchHandoff {
    let token = "fixture-ticket"
    var cancelled = false
    var readyPID: Int32?
    static func create() throws -> RelaunchHandoff { RelaunchHandoff() }
    func ready(for pid: Int32) -> Bool { !cancelled && readyPID == pid }
    func cancel() { cancelled = true }
}
final class NSRunningApplication {
    let processIdentifier: Int32
    var isTerminated = false
    var bundleIdentifier: String? = Bundle.main.bundleIdentifier
    init(_ pid: Int32) { processIdentifier = pid }
}
final class NSWorkspace {
    final class OpenConfiguration {
        var activates = true
        var createsNewApplicationInstance = false
        var arguments: [String] = []
    }
    static let shared = NSWorkspace()
    var completion: ((NSRunningApplication?, Error?) -> Void)?
    var runningApplications: [NSRunningApplication] = []
    func openApplication(at: URL, configuration: OpenConfiguration,
                         completionHandler: @escaping (NSRunningApplication?, Error?) -> Void) {
        precondition(configuration.createsNewApplicationInstance)
        completion = completionHandler
    }
}
final class ApplicationBoundary { var terminations = 0; func terminate(_ value: Any?) { terminations += 1 } }
let NSApp = ApplicationBoundary()
final class NativePrivacyShieldSurface: PrivacyShieldSurface {
    var presented: Bool { fatalError("Native surface forbidden in lifecycle probe") }
    func show() { fatalError("Native surface forbidden") }
    func hide() { fatalError("Native surface forbidden") }
}
final class Surface: PrivacyShieldSurface {
    let trace: Trace
    var presented = false
    init(_ trace: Trace) { self.trace = trace }
    func show() { trace.values.append("shield-show") }
    func hide() { trace.values.append("shield-hide"); presented = false }
}
final class FilterBoundary {
    let model = InputFilter(seedInput: { _ in })
    var enabled = true
    var onAction: ((InputFilterAction) -> Void)? { get { model.onAction } set { model.onAction = newValue } }
    var snapshot: InputFilterSnapshot {
        let s = model.snapshot
        return InputFilterSnapshot(created: true, enabled: enabled, locked: s.locked, blocked: s.blocked,
            passed: s.passed, gestures: s.gestures, heldInput: s.heldInput, releasedBy: s.releasedBy)
    }
    func configure(locked: Bool, normal: KeyboardShortcut, emergency: KeyboardShortcut,
                   deadline: TimeInterval? = nil, deferManualUnlock: Bool = false) {
        model.configure(locked: locked, normal: normal, emergency: emergency, deadline: deadline,
                        deferManualUnlock: deferManualUnlock)
    }
    func markObservationGap() { model.markObservationGap() }
    func heartbeat() { model.heartbeat() }
}
final class Identifier { func hide() {} }
final class Readings {
    func invalidate(_ target: UInt32? = nil) {}
    func receive(_ reply: GuardianReply, at: TimeInterval) -> Bool { false }
}
final class Window { func orderOut(_ value: Any?) {} }
final class Controls { var window: Window? = Window(); func cancelShortcutRecording() {} }
final class Dashboard {
    var isShown = false
    func close() { isShown = false }
    func updateMenu(_ value: Menu) {}
}
struct ItemID { var rawValue = "" }
final class MenuItem { var identifier: ItemID?; var title = "" }
final class Menu { var items: [MenuItem] = [] }
final class Button { var title = "" }
final class StatusItem { var button: Button? = Button() }
final class DisplayControls {
    var hasWork = false
    var pending: Set<String> = []
    func reset() { hasWork = false }
    func expire(at: TimeInterval) {}
    func brightnessTarget(for reply: GuardianReply) -> UInt32? { nil }
    func receive(_ reply: GuardianReply) -> Bool { false }
}
final class History {
    var starts: [String] = []
    var ends: [SessionEndReason] = []
    func started(source: String) { starts.append(source) }
    func ended(_ reason: SessionEndReason, tapEnabled: Bool, secureInput: Bool, macOSState: String,
               requestedReason: SessionEndReason?) { ends.append(reason) }
}
final class Guardian {
    var running = false
    var restores = 0
    var starts = 0
    var sendsSucceed = true
    var commands: [(String, UInt64)] = []
    let trace: Trace
    init(_ trace: Trace) { self.trace = trace }
    @discardableResult func send(_ value: String, id: UInt64 = 0) -> Bool {
        commands.append((value, id))
        if value.hasPrefix("restore") { restores += 1; trace.values.append("restore") }
        return running && sendsSucceed
    }
    func start() throws { starts += 1; running = true }
}
final class Cover {
    var running = false
    var active = false
    var preparing = false
    var prepares = 0
    var reveals = 0
    var failures = 0
    func prepare(id: UInt64) -> Bool { prepares += 1; running = true; preparing = true; return true }
    func reveal(id: UInt64, duration: TimeInterval = 0) { reveals += 1; active = false; preparing = false }
    func showFailure(id: UInt64, reason: String, retry: String, emergency: String) -> Bool {
        failures += 1; return true
    }
    func heartbeat() {}
}
final class Lid {
    var settled = true
    var busy = false
    var preparing = false
    var active = false
    func cancelPreparation() {}
    func prepare(_ completion: @escaping (Result<Void, Error>) -> Void) { fatalError("Native lid preparation forbidden") }
}
final class Awake {
    var active = true
    func stop() {}
    func update(locked: Bool, enabled: Bool, allowBattery: Bool, reservePercent: Int) -> String? { nil }
}
final class Idle { func stop() {} }
final class Install {
    var cleanupPending = false
    var working = false
    func dismissCleanup() {}
    func offerCleanup(in window: Window) {}
}
struct BatteryReserve { static func stored() -> Int { 10 } }
struct NativePowerSource {
    struct Restriction { func message(reservePercent: Int) -> String { "fake restriction" } }
    static func current() -> NativePowerSource { NativePowerSource() }
    func restriction(allowBattery: Bool, reservePercent: Int) -> Restriction? { nil }
}
enum NSSound { static func beep() {} }
struct CoverReply { let id: UInt64; let state: String }
func normalBrightnessTransitionDuration() -> TimeInterval { 0.3 }

// The probe generator appends exact current App.swift method bodies here.
final class Owner: NSObject {
    let trace = Trace()
    let filter = FilterBoundary()
    let displayIdentifier = Identifier()
    let displayBrightness = Readings()
    var controls: Controls? = Controls()
    let statusDashboard = Dashboard()
    let individualDisplays = DisplayControls()
    let sessionHistory = History()
    let transitionCover = Cover()
    let lidSleep = Lid()
    let keepAwake = Awake()
    let idleActivity = Idle()
    let installation = Install()
    lazy var guardian = Guardian(trace)
    lazy var surface = Surface(trace)
    lazy var privacyShield: PrivacyShield = {
        let s = PrivacyShield(surface: surface, automaticPolling: false, clock: { [weak self] in self?.privacyClock ?? 0 })
        s.onPresented = { [weak self] in self?.restoreBehindPrivacyShield() }
        s.onPresentationFailure = { [weak self] in self?.restoreBehindPrivacyShield() }
        return s
    }()
    let screenDriver = ScreenDriver()
    lazy var screenLock = ScreenLockHandoff(driver: screenDriver)
    var locked = true
    var dimmedSession = true
    var recordingShortcuts = false
    var terminating = false
    var relaunching = false
    var updateQuiescing = false
    var relaunchHandoff: RelaunchHandoff?
    var relaunchTimer: Timer?
    var relaunchHelpersClosing = false
    var resumeDisplayRecoveryAfterShutdown = false
    var privacyRestoreDeferred = false
    var privacyCoverReleaseDeferred = false
    var privacyClock: TimeInterval = 0
    var previousDisplayRecovery = DisplayRecoveryLifecycle()
    var previousDisplayRecoveryPending = false
    var issues = AppIssues()
    var sessionIssue: String? { get { issues[.session] } set { issues[.session] = newValue } }
    var unlockRequestReason: SessionEndReason?
    var sessionLocksOnUnlock = false
    var sessionUsesLid = false
    let normalShortcut = KeyboardShortcut.normal
    let emergencyShortcut = KeyboardShortcut.emergency
    let emergencyLabel = "fixture-emergency"
    let shortcutLabel = "fixture-normal"
    var lockOnUnlockEnabled = true
    var dimScreen = true
    var lidModeEnabled = false
    var errorSoundEnabled = false
    var keepAwakeEnabled = true
    var lidOnBatteryEnabled = false
    var previousTrust: Bool?
    var menuReady = true
    var deadline: TimeInterval?
    var coverPending = false
    var coveredBrightnessRestore = false
    var restoreRetries = 0
    var reseedOnSessionReturn = false
    var operationReplies = OperationReplies()
    var coverPreparationTimer: Timer?
    var coverRevealTimer: Timer?
    var screenLockTimer: Timer?
    var timer: Timer?
    var statusItem: StatusItem! = StatusItem()
    var quickMenu: Menu?
    var recoveryOffers = 0
    override init() {
        super.init()
        filter.model.configure(locked: true, normal: normalShortcut, emergency: emergencyShortcut)
        filter.onAction = { [weak self] action in
            guard let self, action != .lock else { return }
            self.handleInputRelease(action)
        }
    }
    func refreshMenu() {}
    func writeDiagnostics() {}
    func updateControls() {}
    func updateStatusIcon() {}
    func updateDashboard() {}
    func updateLidSleep() {}
    func updateIdleLockPrevention() {}
    func reconcileSessionReturn() {}
    func installTapIfAllowed(checkLiveAccess: Bool = false) {}
    @discardableResult func registerEmergencyHotKey() -> Bool { true }
    func showInputAccessFailure() { fatalError("Native permissions forbidden") }
    func showControls() {}
    func showMessage(_ title: String, _ message: String) {}
    func checkDeferredUpdate() { if !locked && !privacyShield.active { recoveryOffers += 1 } }
    // ORIGINAL_APP_METHODS
    func runTick() { tick() }
    func brightnessOwnerExited() { handleBrightnessGuardianExit() }
    func resumeFailedRelaunch() { recoverFromRelaunchFailure(nil, showAlert: false) }
    func startReplacement() { openReplacementApplication() }
    func otherProcesses() -> [NSRunningApplication] { others() }
    func recoverPrivacy() -> Bool { revealPrivacyFromCommand() }
    func startSession() {
        locked = false; dimmedSession = false
        filter.configure(locked: false, normal: normalShortcut, emergency: emergencyShortcut)
        lock(duration: nil, source: "orchestration-fixture")
    }
    func requestManualUnlock() { requestUnlock(reason: .manual) }
    func receiveCover(_ reply: CoverReply) {
        if operationReplies.accepts(.cover, id: reply.id), reply.state == "covered" {
            transitionCover.active = true; transitionCover.preparing = false
        }
        handleCoverReply(reply)
    }
    func receiveBrightness(_ reply: GuardianReply) { handleBrightnessReply(reply) }
    func advanceScreenLock(at time: TimeInterval) { handleScreenLockResult(screenLock.poll(at: time)) }
    func close() {
        relaunchTimer?.invalidate(); relaunchHandoff?.cancel()
        NSWorkspace.shared.completion = nil; NSWorkspace.shared.runningApplications = []; NSApp.terminations = 0
        timer?.invalidate(); coverPreparationTimer?.invalidate(); coverRevealTimer?.invalidate(); screenLockTimer?.invalidate()
        privacyShield.dismiss(); filter.model.stop()
    }
}
final class ScreenDriver: ScreenLockDriver {
    var available = true
    var current = ScreenLockState.unlocked
    var ready = false
    var requestSucceeds = true
    var requests = 0
    var locksOnRequest = false
    func screenState() -> ScreenLockState { current }
    func lockScreenReady() -> Bool { ready }
    func requestLock() -> Bool {
        requests += 1
        if requestSucceeds && locksOnRequest { current = .locked }
        return requestSucceeds
    }
}
