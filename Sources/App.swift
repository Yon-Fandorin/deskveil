import AppKit
import Carbon
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let displayStatus = DisplayStatusReader()
    private let displayIdentifier = DisplayIdentifier()
    private var displayBrightness = DisplayBrightnessReadings()
    private var individualDisplays = IndividualDisplayControls()
    private let dashboard = MenuDashboard()
    private lazy var statusDashboard = StatusDashboard(dashboard: dashboard)
    private var quickMenu: NSMenu?
    private let filter = InputFilter()
    private var controls: ControlWindow?
    private var timer: Timer?
    private var deadline: TimeInterval?
    private var dimmedSession = false
    private var locked = false
    private var sessionLocksOnUnlock = false
    private let screenLock = ScreenLockHandoff(driver: NativeScreenLock())
    private var screenLockTimer: Timer?
    private let transitionCover = DisplayTransitionCover()
    private var coveredBrightnessRestore = false
    private var coverRevealTimer: Timer?
    private var reseedOnSessionReturn = false
    private var sessionInputReseeds = 0
    private var issues = AppIssues()
    private var sessionIssue: String? {
        get { issues[.session] }
        set { issues[.session] = newValue }
    }
    private let guardian = BrightnessGuardian()
    private var previousDisplayRecovery = DisplayRecoveryLifecycle()
    private let keepAwake = KeepAwakeController()
    private let lidSleep = LidSleepController()
    private var sessionUsesLid = false
    private lazy var idleActivity = IdleActivityController(driver: NativeIdleActivity(inputState: { [weak self] in
        self?.filter.snapshot.heldInput
    }))
    private let emergencyKeys = EmergencyHotKey()
    private var recordingShortcuts = false
    private var operationReplies = OperationReplies()
    private var coverPending = false
    private var coverPreparationTimer: Timer?
    private var restoreRetries = 0
    private var observers: [NSObjectProtocol] = []
    private var lastDiagnosticData: Data?
    private var lastDiagnosticTime: TimeInterval = 0
    private let diagnosticsWriter = DiagnosticsWriter(url: Bundle.main.bundleURL.deletingLastPathComponent()
        .appendingPathComponent("SoftLock-diagnostics.json"))
    private var previousTrust: Bool?
    private var menuReady = false
    private var relaunching = false
    private var relaunchHelpersClosing = false
    private var resumeDisplayRecoveryAfterShutdown = false
    private var terminating = false
    private var relaunchTimer: Timer?
    private var relaunchHandoff: RelaunchHandoff?
    private let installation = InstallationFlow()
    private var normalStarted = false
    private let updateGate = DeferredUpdateGate()
    private let sessionHistory = SessionHistory()
    private var updateQuiescing = false
    private var updateWaitingReason: String?
    private var unlockRequestReason: SessionEndReason?
    private let privacyShield = PrivacyShield()
    private var privacyRestoreDeferred = false
    private var privacyCoverReleaseDeferred = false

    func writeDiagnostics() {
        let state = filter.snapshot
        let now = ProcessInfo.processInfo.systemUptime
        var lidStatus = lidSleep.snapshot
        lidStatus.removeValue(forKey: "at")
        let snapshot: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundle": Bundle.main.bundleURL.path,
            "accessibility": AXIsProcessTrusted(),
            "listenAccess": CGPreflightListenEventAccess(),
            "postAccess": CGPreflightPostEventAccess(),
            "tapCreated": state.created,
            "tapEnabled": state.enabled,
            "inputReleasedBy": state.releasedBy?.rawValue ?? "",
            "secureInput": IsSecureEventInputEnabled(),
            "locked": locked,
            "lockOnUnlockEnabled": lockOnUnlockEnabled,
            "normalShortcut": normalShortcut.label,
            "emergencyShortcut": emergencyShortcut.label,
            "emergencyHotKeyRegistered": emergencyKeys.active,
            "shortcutRecording": recordingShortcuts,
            "shortcutCapture": controls?.shortcutCaptureDiagnostics ?? [:],
            "coverPreparing": coverPending,
            "errorSoundEnabled": errorSoundEnabled,
            "screenLockHandoff": screenLock.state,
            "transitionCoverActive": transitionCover.active,
            "coveredBrightnessRestore": coveredBrightnessRestore,
            "privacyShieldActive": privacyShield.active,
            "privacyShieldPresented": privacyShield.presented,
            "privacyShieldPresentationFailed": privacyShield.presentationFailed,
            "privacyBrightnessRestoreDeferred": privacyRestoreDeferred,
            "privacyCoverReleaseDeferred": privacyCoverReleaseDeferred,
            "sessionInputReseeds": sessionInputReseeds,
            "screenLockAvailable": screenLock.available,
            "macOSScreenLocked": screenLock.screenState == .locked,
            "macOSScreenState": screenLock.screenState.rawValue,
            "dimScreenEnabled": dimScreen,
            "brightnessTransitionDuration": normalBrightnessTransitionDuration(),
            "keepAwakeEnabled": keepAwakeEnabled,
            "keepAwakeActive": keepAwake.active,
            "lidModeEnabled": lidModeEnabled,
            "lidOnBatteryEnabled": lidOnBatteryEnabled,
            "batteryPercent": keepAwake.source.batteryPercent.map { $0 as Any } ?? NSNull(),
            "batteryReservePercent": BatteryReserve.stored(),
            "lidDurationSeconds": LidDuration.stored(),
            "lidModeSession": sessionUsesLid,
            "lidServiceInstalled": lidSleep.installed,
            "lidServicePhase": lidSleep.phase,
            "lidServiceReason": lidSleep.reason,
            "lidPreparationSeconds": lidSleep.preparationDuration ?? -1,
            "lidServiceStatus": lidStatus,
            "lidClosed": lidRootProperties()["AppleClamshellState"] ?? false,
            "systemSleepDisabled": lidRootProperties()["SleepDisabled"] ?? false,
            "lidRecoveryPending": FileManager.default.fileExists(atPath: LidPaths.receipt),
            "acPower": keepAwake.acPower,
            "idleLockPreventionScoped": idleActivity.scoped,
            "idleLockPreventionState": idleActivity.state,
            "idleActivityPulses": idleActivity.pulseCount,
            "idleActivityVerified": idleActivity.verifiedCount,

            "gestureCounts": state.gestures,
            "blockedEvents": state.blocked,
            "passedEvents": state.passed,
            "heldInput": state.heldInput.held,
            "heldInputCounts": state.heldInput.counts,
            "sessionDimmed": dimmedSession,
            "individualDisplaysOff": individualDisplays.off.sorted(),
            "individualDisplaysPending": individualDisplays.pending.sorted(),
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            "lastSessionEnd": sessionHistory.lastEnd,
            "updatePending": updateGate.pending,
            "updateQuiescing": updateQuiescing,
            "updateVersion": updateGate.version ?? "",
            "updateGateAvailable": updateGate.available,
            "issue": issues.current ?? ""
        ]
        guard let stateData = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]),
              stateData != lastDiagnosticData || now - lastDiagnosticTime >= 5 else { return }
        var telemetry = snapshot
        telemetry["hidIdleSeconds"] = idleActivity.idleSeconds
        telemetry["sessionIdleSeconds"] = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        telemetry["lidServiceUpdatedAt"] = lidSleep.snapshot["at"]
        telemetry["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: telemetry, options: [.prettyPrinted, .sortedKeys]) else { return }
        diagnosticsWriter.submit(data) { [weak self] succeeded in
            guard succeeded, let self else { return }
            self.lastDiagnosticData = stateData
            self.lastDiagnosticTime = now
        }
    }

    func checkUI() -> Bool {
        let identifiers = Set(quickMenu?.items.compactMap { $0.identifier?.rawValue } ?? [])
        return statusItem?.button?.image != nil && !locked &&
            Set(["quick-toggle", "quick-settings", "quick-about", "quick-quit"]).isSubset(of: identifiers)
    }

    private var dimScreen: Bool {
        get { UserDefaults.standard.bool(forKey: "dimScreen") }
        set { UserDefaults.standard.set(newValue, forKey: "dimScreen") }
    }
    private var keepAwakeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "keepAwakeEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "keepAwakeEnabled") }
    }
    private var lidModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "lidModeEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "lidModeEnabled") }
    }
    private var lidOnBatteryEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "lidOnBatteryEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "lidOnBatteryEnabled") }
    }
    private var normalShortcut: KeyboardShortcut { ShortcutPreferences().normal }
    private var emergencyShortcut: KeyboardShortcut { ShortcutPreferences().emergency }
    private var lockOnUnlockEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "lockOnUnlockEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "lockOnUnlockEnabled") }
    }
    private var errorSoundEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "errorSoundEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "errorSoundEnabled") }
    }
    private var shortcutLabel: String { normalShortcut.label }
    private var emergencyLabel: String { emergencyShortcut.label }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installation.begin { [weak self] in self?.startApplication() }
    }

    private func startApplication() {
        guard !normalStarted, !terminating else { return }
        normalStarted = true
        privacyShield.onPresented = { [weak self] in self?.restoreBehindPrivacyShield() }
        privacyShield.onPresentationFailure = { [weak self] in
            guard let self else { return }
            self.sessionIssue = L10n.text("화면 가림 표시를 확인하지 못했습니다. 가림 해제 또는 긴급 해제로 복구해주세요.")
            self.restoreBehindPrivacyShield()
        }
        privacyShield.onChange = { [weak self] in self?.refreshMenu() }
        updateGate.onRevealPrivacy = { [weak self] in self?.revealPrivacyFromCommand() ?? false }
        updateGate.onChange = { [weak self] in self?.refreshMenu() }
        updateGate.onRenew = { [weak self] in
            guard let self, self.updateQuiescing, !self.terminating else { return }
            self.waitForUpdateCommit()
        }
        updateGate.onDisconnect = { [weak self] in
            guard let self, self.updateQuiescing, !self.terminating else { return }
            self.updateQuiescing = false
            self.relaunchTimer?.invalidate(); self.relaunchTimer = nil
            self.recoverFromRelaunchFailure(nil, showAlert: false)
        }
        updateGate.onCommit = { [weak self] in
            guard let self, self.updateQuiescing, !self.terminating else { return }
            self.relaunchTimer?.invalidate(); self.relaunchTimer = nil
            guard !self.locked, !self.recordingShortcuts, !self.guardian.running,
                  !self.transitionCover.running, self.lidSleep.settled,
                  !self.previousDisplayRecoveryPending else {
                self.updateQuiescing = false
                self.updateGate.stop(); try? self.updateGate.start()
                self.recoverFromRelaunchFailure(L10n.text("정리 상태가 변경되어 업데이트를 적용하지 않았습니다."), showAlert: false)
                return
            }
            NSApp.terminate(nil)
        }
        UserDefaults.standard.register(defaults: ["dimScreen": false,
            "keepAwakeEnabled": true, "lidModeEnabled": false, "lidOnBatteryEnabled": false,
            "lockOnUnlockEnabled": true, "errorSoundEnabled": false])
        NSApp.setActivationPolicy(.accessory)
        signal(SIGPIPE, SIG_IGN)
        lidSleep.onChange = { [weak self] in self?.refreshMenu() }
        lidSleep.onPreparationUpdate = { [weak self] in self?.updateLidSleep() }
        lidSleep.onUnexpectedEnd = { [weak self] reason, issue in
            guard let self, self.locked, self.sessionUsesLid, !self.coverPending, !self.screenLock.requiresConfirmation else { return }
            // A chosen deadline is a normal end, so retain the user's macOS
            // authentication flow instead of exposing the desktop on expiry.
            if reason == "session-limit" { self.requestUnlock(reason: .lidLimit); return }
            self.issues[.lid] = issue
            self.unlock(immediateBrightness: true, reason: .lidEnded)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        dashboard.onDisplayPower = { [weak self] display, off in self?.setDisplayPower(display, off: off) }
        dashboard.onDisplayIdentify = { [weak self] display in self?.identifyDisplay(display) }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.displayIdentifier.hide(); self?.privacyShield.rebuild()
            })
        guardian.onMessage = { [weak self] raw in
            guard let reply = GuardianReply(raw) else { return }
            self?.handleBrightnessReply(reply)
        }
        guardian.onExit = { [weak self] in self?.handleBrightnessGuardianExit() }
        transitionCover.onReply = { [weak self] reply in self?.handleCoverReply(reply) }
        transitionCover.onExit = { [weak self] in
            guard let self else { return }
            if self.locked || self.coverPending || self.coveredBrightnessRestore {
                self.unlock(issue: L10n.text("화면 전환 보조 프로세스가 종료되어 입력 차단을 해제했습니다."), immediateBrightness: true, reason: .coverFailure)
            }
        }
        emergencyKeys.onEmergency = { [weak self] in
            guard let self, !self.recordingShortcuts, !self.filter.captureGestureInFlight else { return }
            self.unlock(immediateBrightness: true, reason: .emergency)
        }
        filter.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .lock: self.lock(duration: nil, source: "shortcut")
            default: self.handleInputRelease(action)
            }
        }
        filter.configure(locked: false, normal: normalShortcut, emergency: emergencyShortcut)
        registerEmergencyHotKey()
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in self?.unlock(immediateBrightness: true, reason: .systemSleep) })
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in self?.sessionBecameInactive() })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.sessionBecameInactive() })
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in self?.reconcileSessionReturn() })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.reconcileSessionReturn() })
        timer = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)
        refreshMenu()
        installTapIfAllowed()
        keepAwake.update(locked: false, enabled: keepAwakeEnabled)
        writeDiagnostics()
        previousDisplayRecovery.active = previousDisplayRecoveryPending
        attemptPreviousDisplayRecovery()
        try? updateGate.start()
        writeDiagnostics()
        if !filter.snapshot.enabled || CommandLine.arguments.contains("--show-controls") { showControls() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        displayIdentifier.hide()
        terminating = true
        updateGate.stop()
        installation.stop()
        statusDashboard.close()
        guard normalStarted else { return }
        previousDisplayRecovery.active = false
        relaunchTimer?.invalidate(); relaunchTimer = nil
        controls?.cancelShortcutRecording()
        unlock(immediateBrightness: true, reason: .applicationQuit)
        filter.stop()
        guardian.close()
        timer?.invalidate()
        emergencyKeys.close()
        transitionCover.close()
        lidSleep.disconnect()
        sessionHistory.flush(timeout: 0.2)
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    @discardableResult private func registerEmergencyHotKey() -> Bool {
        guard !relaunching else { return false }
        screenLock.emergencyLabel = emergencyLabel
        if !emergencyKeys.replace(emergencyShortcut) || !emergencyKeys.resume() {
            issues[.emergency] = L10n.text("긴급 해제 단축키가 다른 앱과 겹칩니다. 설정에서 다른 조합을 지정해주세요.")
            return false
        }
        issues[.emergency] = nil
        return true
    }

    private func setShortcutRecording(_ recording: Bool) {
        guard !recording || (!relaunching && !relaunchHelpersClosing && !terminating && !updateQuiescing && !privacyShield.active) else { return }
        guard !locked else { return }
        recordingShortcuts = recording
        filter.suspendShortcuts(recording)
        if recording { emergencyKeys.suspend() }
        else if !relaunching {
            issues[.emergency] = emergencyKeys.resume() ? nil : L10n.text("긴급 해제 키를 다시 연결하지 못했습니다. 다른 조합을 지정해주세요.")
            refreshMenu()
        }
    }

    private func changeShortcuts(normal: KeyboardShortcut, emergency: KeyboardShortcut) -> String? {
        guard !relaunching else { return L10n.text("앱을 다시 시작한 뒤 변경해주세요.") }
        guard !locked else { return L10n.text("입력 차단을 해제한 뒤 변경해주세요.") }
        if let error = normal.validationError(other: emergency) ?? emergency.validationError(other: normal) { return error }
        if normal.usedBySystem || emergency.usedBySystem { return L10n.text("macOS에서 사용하는 조합입니다. 다른 키를 지정해주세요.") }
        guard emergencyKeys.replace(emergency) else {
            return L10n.text("긴급 해제 키가 다른 앱에서 사용 중입니다. 다른 조합을 지정해주세요.")
        }
        issues[.emergency] = nil
        ShortcutPreferences.save(normal, emergency: false)
        ShortcutPreferences.save(emergency, emergency: true)
        screenLock.emergencyLabel = emergency.label
        filter.configure(locked: false, normal: normal, emergency: emergency)
        issues[.shortcut] = nil; refreshMenu(); return nil
    }

    private func installTapIfAllowed(checkLiveAccess: Bool = false) {
        guard !relaunching else { return }
        guard !filter.snapshot.enabled else { issues[.input] = nil; return }
        guard checkLiveAccess || AXIsProcessTrusted() else { return }
        if !filter.start() {
            issues[.input] = L10n.text("입력 차단 기능을 준비하지 못했습니다. 손쉬운 사용을 허용한 뒤 ‘권한 다시 확인’을 눌러주세요.")
        } else { issues[.input] = nil }
        refreshMenu()
    }

    private func lock(duration: TimeInterval?, lidPrepared: Bool = false, source: String = "user") {
        guard !installation.working else { return }
        if lidSleep.preparing && !lidPrepared {
            lidSleep.cancelPreparation(); updateLidSleep(); refreshMenu(); return
        }
        guard Self.canStartInputSession(locked: locked, recording: recordingShortcuts,
            restoring: coveredBrightnessRestore, coverActive: transitionCover.active || privacyShield.active,
            coverPreparing: transitionCover.preparing,
            displayRecoveryUnresolved: previousDisplayRecovery.blocksInputSession(
                guardianRunning: guardian.running, pendingRecovery: previousDisplayRecoveryPending)) else { return }
        displayIdentifier.hide()
        previousDisplayRecovery.prepareNewMutation(pendingRecovery: previousDisplayRecoveryPending, issues: &issues)
        installation.dismissCleanup()
        guard !relaunching, !relaunchHelpersClosing else { return }
        guard individualDisplays.pending.isEmpty else {
            issues[.display] = L10n.text("화면 처리가 끝난 뒤 입력 차단을 시작해주세요.")
            refreshMenu(); return
        }
        guard !lidSleep.busy else { showControls(); return }
        reconcileSessionReturn()
        installTapIfAllowed(checkLiveAccess: true)
        reconcileSessionReturn()
        guard filter.snapshot.enabled else {
            showInputAccessFailure()
            return
        }
        guard !IsSecureEventInputEnabled() else {
            showMessage(L10n.text("현재 입력을 차단할 수 없습니다"), L10n.text("보안 입력이 활성화되어 있습니다. 암호 입력창 등을 닫고 다시 시도해주세요."))
            return
        }
        guard registerEmergencyHotKey() else { refreshMenu(); showControls(); return }
        if duration == nil && lockOnUnlockEnabled &&
            (!screenLock.available || screenLock.screenState != .unlocked) {
            sessionIssue = L10n.text("macOS 잠금 전환을 사용할 수 없습니다. ‘해제할 때 macOS 잠금’을 끄면 입력 차단만 사용할 수 있습니다.")
            showControls()
            return
        }
        if duration == nil && lidModeEnabled && !lidPrepared {
            if let restriction = NativePowerSource.current().restriction(allowBattery: lidOnBatteryEnabled, reservePercent: BatteryReserve.stored()) {
                issues[.lid] = restriction.message(reservePercent: BatteryReserve.stored())
                showControls(); return
            }
            lidSleep.prepare { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    guard self.lidModeEnabled, !self.relaunching else { self.updateLidSleep(); return }
                    self.lock(duration: nil, lidPrepared: true, source: source)
                case .failure(let error):
                    self.issues[.lid] = error.localizedDescription; self.refreshMenu(); self.showControls()
                }
            }
            updateLidSleep(); refreshMenu(); return
        }
        if lidPrepared && (!lidSleep.active || NativePowerSource.current().restriction(allowBattery: lidOnBatteryEnabled, reservePercent: BatteryReserve.stored()) != nil) {
            issues[.lid] = L10n.text("덮개 모드 준비가 중단됐습니다. 전원과 배터리 상태를 확인한 뒤 다시 시도해주세요.")
            updateLidSleep(); showControls(); return
        }
        issues[.lid] = nil
        issues[.brightness] = nil
        sessionIssue = nil
        operationReplies.cancelAll()
        screenLock.reset()
        deadline = duration.map { ProcessInfo.processInfo.systemUptime + $0 }
        sessionLocksOnUnlock = lockOnUnlockEnabled && duration == nil
        locked = true
        sessionHistory.started(source: source)
        sessionUsesLid = lidPrepared
        filter.configure(locked: true, normal: normalShortcut, emergency: emergencyShortcut, deadline: deadline,
                         deferManualUnlock: sessionLocksOnUnlock)
        controls?.window?.orderOut(nil)
        dimmedSession = dimScreen && duration == nil
        issues[.power] = keepAwake.update(locked: true, enabled: keepAwakeEnabled, allowBattery: sessionUsesLid && lidOnBatteryEnabled, reservePercent: BatteryReserve.stored())
        if sessionUsesLid && !keepAwake.active {
            unlock(issue: issues[.power] ?? L10n.text("잠자기 방지를 준비하지 못해 차단 시작을 취소했습니다."), immediateBrightness: true, reason: .powerUnavailable)
            return
        }
        updateIdleLockPrevention()
        // A trial always keeps the screen visible. Only the user's normal lock dims it.
        if dimmedSession {
            individualDisplays.reset()
            do {
                try guardian.start()
                guardian.send("dim:\(normalBrightnessTransitionDuration())", id: operationReplies.begin(.dim))
            }
            catch {
                dimmedSession = false
                issues[.brightness] = L10n.text("밝기 보조 프로세스를 실행할 수 없습니다. 화면을 켠 채 입력만 차단합니다.")
            }
        }
        updateLidSleep()
        refreshMenu()
    }

    static func canStartInputSession(locked: Bool, recording: Bool, restoring: Bool,
                                     coverActive: Bool, coverPreparing: Bool,
                                     displayRecoveryUnresolved: Bool = false) -> Bool {
        !locked && !recording && !restoring && !coverActive && !coverPreparing && !displayRecoveryUnresolved
    }

    func unlock(issue: String? = nil, immediateBrightness: Bool = false, restoreBehindCover: Bool = false,
                reason: SessionEndReason = .other) {
        if [.manual, .emergency, .applicationQuit, .relaunch, .update].contains(reason) {
            privacyShield.dismiss()
            privacyRestoreDeferred = false; privacyCoverReleaseDeferred = false
        }
        if privacyShield.begin(reason: reason, sessionActive: locked && !terminating && !relaunching,
                               macOSLocked: screenLock.screenState == .locked && !screenLock.requiresConfirmation &&
                                    !coverPending && !transitionCover.active && !transitionCover.preparing) {
            statusDashboard.close(); controls?.window?.orderOut(nil)
        }
        if locked {
            sessionHistory.ended(reason, tapEnabled: filter.snapshot.enabled,
                secureInput: IsSecureEventInputEnabled(), macOSState: screenLock.screenState.rawValue,
                requestedReason: unlockRequestReason)
        }
        displayIdentifier.hide()
        let hadTransitionCover = transitionCover.active || transitionCover.preparing || coverPending
        let restorePending = previousDisplayRecoveryPending || individualDisplays.hasWork || dimmedSession
        let ownsRestore = previousDisplayRecovery.requestRestore(pending: restorePending,
            allowRestart: !terminating && !relaunching && !relaunchHelpersClosing)
        individualDisplays.reset()
        issues[.display] = nil
        if restorePending {
            issues[.brightness] = previousDisplayRecovery.issue ?? issues[.brightness] ?? L10n.text("화면 복원을 아직 확인하지 못했습니다.")
        } else { issues[.brightness] = nil }
        lidSleep.cancelPreparation()
        let needsBrightnessAck = restoreBehindCover && dimmedSession
        coverPreparationTimer?.invalidate(); coverPreparationTimer = nil; coverPending = false
        coverRevealTimer?.invalidate(); coverRevealTimer = nil
        operationReplies.cancelAll()
        coveredBrightnessRestore = needsBrightnessAck
        restoreRetries = 0
        privacyCoverReleaseDeferred = privacyShield.active && !privacyShield.presented &&
            (privacyCoverReleaseDeferred || hadTransitionCover)
        if !restoreBehindCover && !privacyCoverReleaseDeferred {
            transitionCover.reveal(id: operationReplies.begin(.coverRelease))
        }
        if screenLock.requiresConfirmation {
            screenLock.cancel()
            if issue == nil { sessionIssue = nil }
        }
        screenLockTimer?.invalidate(); screenLockTimer = nil
        locked = false; sessionLocksOnUnlock = false; unlockRequestReason = nil
        sessionUsesLid = false
        filter.configure(locked: false, normal: normalShortcut, emergency: emergencyShortcut)
        dimmedSession = false; keepAwake.stop(); idleActivity.stop(); deadline = nil
        issues[.power] = nil; issues[.idle] = nil
        updateLidSleep()
        privacyRestoreDeferred = privacyShield.awaitingPresentation
        if privacyRestoreDeferred {
            if let issue { sessionIssue = issue }
            if statusItem != nil { refreshMenu() }
            return
        }
        let restoreID = operationReplies.begin(.restore)
        let sent = guardian.send(immediateBrightness || issue != nil ? "restore-now" : "restore:\(normalBrightnessTransitionDuration())", id: restoreID)
        if !sent && ownsRestore { attemptPreviousDisplayRecovery() }
        if needsBrightnessAck { scheduleRestoreTimeout() }
        else if restoreBehindCover && !privacyCoverReleaseDeferred {
            transitionCover.reveal(id: operationReplies.begin(.coverRelease), duration: 0.15)
        }
        if let issue { sessionIssue = issue }
        if statusItem != nil { refreshMenu() }
    }

    private func restoreBehindPrivacyShield() {
        // A logical OS-lock flag is not an opaque login screen. A healthy
        // transition cover stays until the replacement privacy surface is real.
        if privacyCoverReleaseDeferred && privacyShield.presented {
            privacyCoverReleaseDeferred = false
            transitionCover.reveal(id: operationReplies.begin(.coverRelease))
        }
        guard privacyRestoreDeferred else { return }
        privacyRestoreDeferred = false
        if !guardian.send("restore-now", id: operationReplies.begin(.restore)) {
            attemptPreviousDisplayRecovery()
        }
        writeDiagnostics()
    }

    private func revealPrivacyFromCommand() -> Bool {
        guard privacyShield.active, !locked, !terminating, !relaunching, !updateQuiescing,
              !screenLock.requiresConfirmation, !coverPending, !transitionCover.preparing,
              !coveredBrightnessRestore else { return false }
        unlock(immediateBrightness: true, reason: .emergency)
        writeDiagnostics()
        return !privacyShield.active
    }

    private func requestUnlock(reason: SessionEndReason = .manual) {
        guard locked else { return }
        guard sessionLocksOnUnlock else { unlock(reason: reason); return }
        guard !screenLock.pending, !coverPending else { return }
        // Preserve why authentication was requested as well as its outcome.
        if unlockRequestReason == nil { unlockRequestReason = reason }
        sessionIssue = nil
        operationReplies.cancel(.failureRestore); operationReplies.cancel(.failureCover)
        let id = operationReplies.begin(.cover)
        coverPending = true
        guard transitionCover.prepare(id: id) else {
            coverPending = false
            handleScreenLockResult(screenLock.preparationFailed(L10n.text("화면 전환 보조 프로세스를 준비할 수 없습니다.")))
            return
        }
        idleActivity.stop()
        issues[.idle] = nil
        updateLidSleep()
        let timer = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
            guard let self, self.coverPending, self.operationReplies.accepts(.cover, id: id) else { return }
            self.coverPending = false
            self.handleScreenLockResult(self.screenLock.preparationFailed(L10n.text("화면 전환 준비 응답을 받지 못했습니다.")))
        }
        coverPreparationTimer?.invalidate(); coverPreparationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        refreshMenu()
    }

    private func handleCoverReply(_ reply: CoverReply) {
        if operationReplies.accepts(.cover, id: reply.id) {
            guard coverPending else { return }
            coverPending = false; coverPreparationTimer?.invalidate(); coverPreparationTimer = nil
            operationReplies.cancel(.cover)
            if reply.state == "covered" {
                if dimmedSession { guardian.send("hold-for-lock") }
                handleScreenLockResult(screenLock.begin())
            } else {
                handleScreenLockResult(screenLock.preparationFailed(L10n.text("검은 전환 화면을 준비할 수 없습니다.")))
            }
        } else if operationReplies.accepts(.failureCover, id: reply.id), reply.state == "failure" {
            operationReplies.cancel(.failureCover)
            // The readable error surface is opaque before the backlight is restored.
            guardian.send("restore-now", id: operationReplies.begin(.failureRestore))
        } else if reply.state == "released" {
            _ = operationReplies.finish(.coverRelease, id: reply.id)
            writeDiagnostics()
        }
    }

    private func handleBrightnessReply(_ reply: GuardianReply) {
        if reply.message.hasPrefix("brightness-status:") {
            if displayBrightness.receive(reply, at: ProcessInfo.processInfo.systemUptime), statusDashboard.isShown { updateDashboard() }
            return
        }
        let changedDisplay = individualDisplays.brightnessTarget(for: reply)
        if individualDisplays.receive(reply) {
            if let changedDisplay { displayBrightness.invalidate(changedDisplay) }
            issues[.display] = nil
            if statusDashboard.isShown { updateDashboard() }
            writeDiagnostics()
            return
        }
        guard !reply.message.hasPrefix("individual-") else { return }
        displayBrightness.invalidate()
        if operationReplies.accepts(.dim, id: reply.id), reply.message == "dim-partial:0" {
            issues[.brightness] = nil
        } else if let issue = Self.dimFailureIssue(reply, expectedID: operationReplies.current(.dim), emergencyLabel: emergencyLabel) {
            issues[.brightness] = issue
        } else if operationReplies.accepts(.failureRestore, id: reply.id) {
            if reply.message == "restored" {
                dimmedSession = false; _ = operationReplies.finish(.failureRestore, id: reply.id)
                issues[.brightness] = nil
            } else if reply.message == "restore-failed" {
                issues[.brightness] = L10n.text("화면 복원에 실패했습니다. %@로 긴급 해제하고, 계속 어두우면 DeskVeil을 다시 실행해주세요.", String(describing: emergencyLabel))
            }
        } else if operationReplies.accepts(.restore, id: reply.id) {
            if reply.message == "restored" {
                _ = operationReplies.finish(.restore, id: reply.id)
                previousDisplayRecovery.complete(issues: &issues)
                if coveredBrightnessRestore { finishCoveredRestore() }
            } else if reply.message == "restore-failed" {
                if coveredBrightnessRestore { retryCoveredRestore() }
                else { issues[.brightness] = L10n.text("화면 복원에 실패했습니다. DeskVeil을 다시 실행해주세요.") }
            }
        }
        writeDiagnostics()
    }

    private var previousDisplayRecoveryPending: Bool {
        FileManager.default.fileExists(atPath: FileBrightnessRecovery.url.path) ||
            FileManager.default.fileExists(atPath: FileGammaRecovery.url.path)
    }

    private func handleBrightnessGuardianExit() {
        displayBrightness.invalidate()
        guard !terminating, !relaunching, !relaunchHelpersClosing else { return }
        // Claim recovery before unlock or dashboard refresh can start a helper
        // for observation. That helper must first receive the pending restore.
        let wasRecovering = previousDisplayRecovery.claimGuardianExit(pending: previousDisplayRecoveryPending)
        if individualDisplays.hasWork {
            individualDisplays.reset()
            issues[.display] = previousDisplayRecovery.recordGuardianExitIssue()
        }
        if coveredBrightnessRestore {
            finishCoveredRestore(issue: L10n.text("화면 복구 프로세스가 종료됐습니다. 계속 어두우면 DeskVeil을 다시 실행해주세요."))
        } else if locked && dimmedSession {
            unlock(issue: L10n.text("밝기 보조 프로세스가 종료되어 입력 차단을 해제했습니다."), reason: .brightnessGuardianExit)
        }
        if wasRecovering {
            previousDisplayRecoveryFailed()
        } else if !previousDisplayRecoveryPending {
            previousDisplayRecovery.complete(issues: &issues)
        }
        attemptPreviousDisplayRecovery()
        if statusDashboard.isShown { updateDashboard() }
    }

    private func attemptPreviousDisplayRecovery() {
        guard !locked, !terminating, !relaunching, !relaunchHelpersClosing, !privacyShield.awaitingPresentation,
              previousDisplayRecovery.canAttempt(guardianRunning: guardian.running, at: ProcessInfo.processInfo.systemUptime) else { return }
        guard previousDisplayRecoveryPending else {
            previousDisplayRecovery.complete(issues: &issues); return
        }
        previousDisplayRecovery.attempts += 1
        do {
            try guardian.start()
            if !guardian.send("restore-now", id: operationReplies.begin(.restore)) { previousDisplayRecoveryFailed() }
        } catch { previousDisplayRecoveryFailed() }
    }

    private func previousDisplayRecoveryFailed() {
        // A just-exited instance may still own recovery. Retry without replacing
        // its journal or silently claiming that the screen has been restored.
        guard previousDisplayRecoveryPending else {
            previousDisplayRecovery.complete(issues: &issues); refreshMenu(); return
        }
        previousDisplayRecovery.recordFailure(at: ProcessInfo.processInfo.systemUptime)
        issues[.brightness] = previousDisplayRecovery.issue
        refreshMenu()
    }

    static func dimFailureIssue(_ reply: GuardianReply, expectedID: UInt64?, emergencyLabel: String) -> String? {
        guard expectedID == reply.id else { return nil }
        if reply.message == "dimmed:0" { return L10n.text("화면 밝기를 제어할 수 없습니다. 입력 차단은 유지됩니다.") }
        if reply.message.hasPrefix("dim-partial:"), let count = Int(reply.message.dropFirst("dim-partial:".count)), count > 0 {
            return L10n.text("화면 %@개를 완전히 어둡게 하지 못했습니다. 입력 차단은 유지됩니다.", String(describing: count))
        }
        if reply.message == "restore-failed" { return L10n.text("화면 복원에 실패했습니다. %@로 긴급 해제하고, 계속 어두우면 DeskVeil을 다시 실행해주세요.", String(describing: emergencyLabel)) }
        return nil
    }

    private func scheduleRestoreTimeout() {
        coverRevealTimer?.invalidate()
        let id = operationReplies.current(.restore)
        let timer = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
            guard let self, self.coveredBrightnessRestore, self.operationReplies.current(.restore) == id else { return }
            self.retryCoveredRestore()
        }
        coverRevealTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func retryCoveredRestore() {
        guard coveredBrightnessRestore else { return }
        if restoreRetries == 0 {
            restoreRetries = 1
            guardian.send("restore-now", id: operationReplies.begin(.restore))
            scheduleRestoreTimeout()
        } else {
            // The cover expires, but a later acknowledgement can still clear the restore error.
            finishCoveredRestore(issue: L10n.text("화면 복원을 확인하지 못했습니다. 계속 어두우면 DeskVeil을 다시 실행해주세요."))
        }
    }
    private func finishCoveredRestore(issue: String? = nil) {
        guard coveredBrightnessRestore else { return }
        coveredBrightnessRestore = false
        coverRevealTimer?.invalidate(); coverRevealTimer = nil
        if !privacyCoverReleaseDeferred {
            transitionCover.reveal(id: operationReplies.begin(.coverRelease), duration: 0.15)
        }
        if let issue { issues[.brightness] = issue }
        writeDiagnostics()
    }

    private func reconcileSessionReturn() {
        if reseedOnSessionReturn { filter.markObservationGap() }
        if filter.resumeObservation(secureInput: IsSecureEventInputEnabled(), consoleActive: screenLock.screenState == .unlocked,
                                    observationEnabled: filter.snapshot.enabled) {
            reseedOnSessionReturn = false; sessionInputReseeds += 1; writeDiagnostics()
        }
    }

    private func sessionBecameInactive() {
        displayIdentifier.hide()
        filter.markObservationGap()
        reseedOnSessionReturn = true
        if !locked && (coveredBrightnessRestore || transitionCover.active) { return }
        // Session resignation and Secure Event Input can precede the login window.
        // Neither is proof that macOS has locked the desktop.
        if locked && screenLock.requiresConfirmation { handleScreenLockResult(screenLock.poll()) }
        else {
            if screenLock.screenState == .locked { reseedOnSessionReturn = true }
            unlock(immediateBrightness: true, reason: .sessionInactive)
        }
    }

    @objc private func pollScreenLock() {
        guard locked, screenLock.pending else { return }
        handleScreenLockResult(screenLock.poll())
    }

    private func handleScreenLockResult(_ result: ScreenLockHandoffResult) {
        switch result {
        case .confirmed:
            // The login window owns authentication before input/brightness are restored.
            sessionIssue = nil
            reseedOnSessionReturn = true
            unlock(immediateBrightness: true, restoreBehindCover: true, reason: .macOSLockConfirmed)
            return
        case .waiting:
            if screenLockTimer == nil {
                let timer = Timer(timeInterval: 0.05, target: self,
                    selector: #selector(pollScreenLock), userInfo: nil, repeats: true)
                screenLockTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            } else { return }
        case .failed(let issue):
            screenLockTimer?.invalidate(); screenLockTimer = nil
            if errorSoundEnabled && sessionIssue != issue { NSSound.beep() }
            sessionIssue = issue
            let id = operationReplies.begin(.failureCover)
            _ = transitionCover.showFailure(id: id, reason: screenLock.failureReason ?? issue, retry: shortcutLabel, emergency: emergencyLabel)
        }
        refreshMenu()
    }

    @objc private func tick() {
        individualDisplays.expire(at: ProcessInfo.processInfo.systemUptime)
        if relaunchHelpersClosing && !guardian.running && !transitionCover.running && lidSleep.settled {
            relaunchHelpersClosing = false
        }
        if resumeDisplayRecoveryAfterShutdown && !relaunching && !relaunchHelpersClosing {
            resumeDisplayRecoveryAfterShutdown = false
            previousDisplayRecovery.resumeAfterInterruptedShutdown(pending: previousDisplayRecoveryPending)
        }
        let trusted = AXIsProcessTrusted()
        if previousTrust == true && !trusted { controls?.cancelShortcutRecording(); filter.markObservationGap() }
        previousTrust = trusted
        if IsSecureEventInputEnabled() || !filter.snapshot.enabled { filter.markObservationGap() }
        reconcileSessionReturn()
        filter.heartbeat()
        attemptPreviousDisplayRecovery()
        guardian.send("ping")
        transitionCover.heartbeat()
        if locked && screenLock.keepCoverOnInputInterruption {
            handleScreenLockResult(screenLock.poll())
        }
        if locked {
            if let deadline, ProcessInfo.processInfo.systemUptime >= deadline { unlock(reason: .trialExpired); return }
            let input = filter.snapshot
            if screenLock.keepCoverOnInputInterruption {
                // macOS already owns input; retain the cover through the settling interval.
            } else if !input.locked, let action = input.releasedBy {
                handleInputRelease(action)
            } else if !input.enabled {
                unlock(issue: L10n.text("입력 감시를 유지할 수 없어 차단을 해제했습니다."), reason: .tapUnavailable)
            } else if IsSecureEventInputEnabled() && !screenLock.pending {
                // A covered authentication request has a bounded timeout;
                // failed handoff must not suppress this recovery indefinitely.
                unlock(issue: L10n.text("보안 입력이 활성화되어 입력 차단을 해제했습니다."), reason: .secureInput)
            } else if !input.locked { unlock(reason: .filterReleased) }
        } else { installTapIfAllowed() }
        issues[.power] = keepAwake.update(locked: locked, enabled: keepAwakeEnabled, allowBattery: sessionUsesLid && lidOnBatteryEnabled, reservePercent: BatteryReserve.stored())
        updateIdleLockPrevention()
        updateLidSleep()
        statusItem.button?.title = locked ? (deadline.map { L10n.text(" %@초", String(describing: remainingSeconds($0))) } ?? L10n.text(" 차단")) : ""
        if menuReady != (filter.snapshot.enabled && trusted) { refreshMenu() }
        else { updateControls(); updateStatusIcon() }
        if statusDashboard.isShown { updateDashboard() }
        if let deadline, locked {
            quickMenu?.items.first(where: { $0.identifier?.rawValue == "quick-countdown" })?.title = L10n.text("%@초 후 자동 해제", String(describing: remainingSeconds(deadline)))
            if statusDashboard.isShown, let quickMenu { statusDashboard.updateMenu(quickMenu) }
        }
        writeDiagnostics()
        checkDeferredUpdate()
        if installation.cleanupPending && !locked && !relaunching && !recordingShortcuts &&
            !previousDisplayRecovery.active && !coveredBrightnessRestore && !coverPending &&
            !transitionCover.active && lidSleep.settled {
            showControls()
            if let window = controls?.window { installation.offerCleanup(in: window) }
        }
    }

    private func remainingSeconds(_ deadline: TimeInterval) -> Int {
        max(0, Int(ceil(deadline - ProcessInfo.processInfo.systemUptime)))
    }

    private func handleInputRelease(_ action: InputFilterAction) {
        // Release intent is retained under the input mutex before its callback
        // reaches Main. A tick must not turn a queued manual unlock into a fault.
        let cause = action == .emergency ? action : (filter.snapshot.releasedBy ?? action)
        if cause == .emergency {
            if !recordingShortcuts { unlock(immediateBrightness: true, reason: .emergency) }
            return
        }
        guard locked else { return }
        switch cause {
        case .unlock: requestUnlock()
        case .interrupted:
            filter.markObservationGap()
            if screenLock.keepCoverOnInputInterruption { handleScreenLockResult(screenLock.poll()) }
            else { unlock(issue: L10n.text("입력 감시가 중단되어 차단을 해제했습니다."), reason: .tapInterrupted) }
        case .expired: unlock(reason: .trialExpired)
        case .unresponsive: unlock(issue: L10n.text("앱 응답이 지연되어 입력 차단을 해제했습니다."), reason: .unresponsive)
        case .lock, .emergency: break
        }
    }

    private var stateLabel: String {
        if updateQuiescing { return L10n.text("업데이트 적용 중") }
        if privacyShield.active { return L10n.text("입력 차단 중단 · 화면 가림 유지") }
        if lidSleep.preparing { return L10n.text("덮개 모드 준비 중") }
        if locked && (screenLock.pending || coverPending) { return L10n.text("macOS 잠금으로 전환 중") }
        if locked && screenLock.state == "failed" { return L10n.text("잠금 전환 실패 · 입력 차단 유지") }
        if locked { return deadline.map { L10n.text("테스트 중 · %@초 후 해제", String(describing: remainingSeconds($0))) } ?? L10n.text("입력 차단 중") }
        if !AXIsProcessTrusted() { return L10n.text("권한 설정 필요") }
        if !filter.snapshot.enabled { return L10n.text("입력 차단 준비 실패") }
        return issues.current == nil ? L10n.text("대기 중") : L10n.text("상태 확인 필요")
    }

    private func updateLidSleep() {
        lidSleep.update(requested: sessionUsesLid && locked && lidModeEnabled && !coverPending && !screenLock.requiresConfirmation,
            locked: locked, ready: AXIsProcessTrusted() && filter.snapshot.enabled, awake: keepAwake.active,
            durationSeconds: LidDuration.stored(), allowBattery: lidOnBatteryEnabled, reservePercent: BatteryReserve.stored())
    }

    private func updateIdleLockPrevention() {
        let previouslyVerified = idleActivity.verifiedCount
        let active = locked && keepAwake.active && !screenLock.pending && !coverPending &&
            !(screenLock.requiresConfirmation && screenLock.requestSubmitted)
        if let issue = idleActivity.update(active: active) { issues[.idle] = issue }
        else if !active || idleActivity.verifiedCount > previouslyVerified { issues[.idle] = nil }
    }

    private func setupLidMode(remove: Bool = false) {
        guard !locked, !lidSleep.busy, lidSleep.settled, !relaunching, !relaunchHelpersClosing,
              !updateQuiescing, !terminating, !privacyShield.active else { return }
        controls?.cancelShortcutRecording()
        lidSleep.install(remove: remove) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if remove { self.lidModeEnabled = false }
                self.issues[.lid] = nil
            case .failure(let error): self.issues[.lid] = error.localizedDescription
            }
            self.updateLidSleep(); self.refreshMenu()
        }
    }

    private func updateStatusIcon() {
        let ready = filter.snapshot.enabled && AXIsProcessTrusted() && issues.current == nil
        let icon = ready || locked ? DeskVeilBrand.mark(size: 20, covered: locked || privacyShield.active)
            : NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: L10n.text("DeskVeil 상태 확인 필요"))
        statusItem.button?.image = icon
        statusItem.button?.toolTip = L10n.text("DeskVeil · %@\n%@ 차단·해제 · %@ 긴급 해제", String(describing: stateLabel), String(describing: shortcutLabel), String(describing: emergencyLabel))
    }

    @objc private func showStatusDashboard() {
        updateDashboard()
        if let button = statusItem.button { statusDashboard.toggle(relativeTo: button) }
    }

    private var canControlIndividualDisplays: Bool {
        !locked && !relaunching && !relaunchHelpersClosing && !terminating && !recordingShortcuts &&
            previousDisplayRecovery.allowsObservation && !coveredBrightnessRestore && !coverPending &&
            !lidSleep.busy && !transitionCover.active && !privacyShield.active
    }

    private func setDisplayPower(_ display: DisplayStatus, off: Bool) {
        guard canControlIndividualDisplays, let identity = display.identity else { return }
        displayIdentifier.hide()
        previousDisplayRecovery.prepareNewMutation(pendingRecovery: previousDisplayRecoveryPending, issues: &issues)
        if previousDisplayRecovery.needsRestoreBeforeStartingGuardian(
            guardianRunning: guardian.running, pendingRecovery: previousDisplayRecoveryPending) {
            previousDisplayRecovery.requestRestore(pending: true, allowRestart: true)
            individualDisplays.reset()
            issues[.display] = L10n.text("이전 화면을 복구한 뒤 화면 버튼을 다시 눌러주세요.")
            issues[.brightness] = previousDisplayRecovery.issue
            attemptPreviousDisplayRecovery()
            updateDashboard()
            writeDiagnostics()
            return
        }
        let command = DisplayPowerCommand(displayID: display.id, identity: identity, off: off)
        guard let wire = command.wire,
              let id = individualDisplays.begin(command, at: ProcessInfo.processInfo.systemUptime) else { return }
        issues[.display] = nil
        displayBrightness.invalidate(DisplayBrightnessTarget(displayID: display.id, identity: identity))
        do {
            try guardian.start()
            if !guardian.send(wire, id: id) {
                _ = individualDisplays.receive(GuardianReply(message: DisplayPowerOutcome.recoveryNeeded.rawValue, id: id))
            }
        } catch {
            _ = individualDisplays.receive(GuardianReply(message: DisplayPowerOutcome.failed.rawValue, id: id))
        }
        updateDashboard()
        writeDiagnostics()
    }

    private func updateDashboard() {
        let now = ProcessInfo.processInfo.systemUptime
        let observed = displayStatus.read()
        let candidates = (observed ?? []).compactMap { display -> DisplayBrightnessTarget? in
            guard !display.builtIn, display.active, !display.asleep, display.brightness == nil,
                  let identity = display.identity, !individualDisplays.pending.contains(identity) else { return nil }
            return DisplayBrightnessTarget(displayID: display.id, identity: identity)
        }
        if !canControlIndividualDisplays || !previousDisplayRecovery.canObserve(
            guardianRunning: guardian.running, pendingRecovery: previousDisplayRecoveryPending) {
            displayBrightness.invalidate()
        } else if let request = displayBrightness.begin(candidates, at: now), let wire = request.target.wire {
            do {
                try guardian.start()
                if !guardian.send(wire, id: request.id) { displayBrightness.invalidate() }
            } catch { displayBrightness.invalidate() }
        }
        let displays = observed?.map { display -> DisplayStatus in
            guard let identity = display.identity else { return display }
            return display.withFallbackBrightness(displayBrightness.value(
                for: DisplayBrightnessTarget(displayID: display.id, identity: identity), at: now))
        }
        let input = filter.snapshot
        dashboard.update(MenuDashboardState(displays: displays, locked: locked,
            awake: keepAwake.active, dimming: dimmedSession, issue: issues.current,
            inputAvailable: input.enabled && AXIsProcessTrusted() && !IsSecureEventInputEnabled(),
            inputBlocking: input.locked, awakeEnabled: keepAwakeEnabled,
            displayControlsEnabled: canControlIndividualDisplays, offDisplays: individualDisplays.off,
            pendingDisplays: individualDisplays.pending, displayIssues: individualDisplays.errors,
            updateStatus: updateGate.version.map { L10n.text("v%@ 업데이트 대기 · %@", String(describing: $0), String(describing: updateWaitingReason ?? L10n.text("상태 확인 중"))) }))
        statusDashboard.resize()
    }

    private func identifyDisplay(_ display: DisplayStatus) {
        guard canControlIndividualDisplays, let identity = display.identity,
              !individualDisplays.off.contains(identity), !individualDisplays.pending.contains(identity) else { return }
        guard let current = displayStatus.read(), let target = DisplayIdentification.resolve(display, current: current),
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == target.displayID
              }), displayIdentifier.show(target, in: screen.frame) else {
            issues[.identification] = L10n.text("화면 연결 상태가 바뀌었습니다. 목록에서 다시 선택해주세요.")
            updateDashboard()
            return
        }
        if issues[.identification] != nil {
            issues[.identification] = nil
            updateDashboard()
        }
    }

    private func refreshMenu() {
        updateStatusIcon()
        menuReady = filter.snapshot.enabled && AXIsProcessTrusted()
        quickMenu = QuickMenu.make(target: self, locked: locked, ready: menuReady,
            shortcut: normalShortcut, remaining: deadline.map(remainingSeconds),
            locksOnUnlock: sessionLocksOnUnlock, handoffPending: screenLock.pending || coverPending,
            toggle: #selector(toggleLock), settings: #selector(showControls),
            permissions: #selector(showPermissionControls), about: #selector(showAbout), quit: #selector(quit))
        if updateQuiescing, let quickMenu {
            for item in quickMenu.items where ["quick-toggle", "quick-settings", "quick-about"].contains(item.identifier?.rawValue) {
                item.isEnabled = false
                if item.identifier?.rawValue == "quick-toggle" { item.title = L10n.text("업데이트 적용 중…") }
            }
        }
        if privacyShield.active, let primary = quickMenu?.items.first(where: { $0.identifier?.rawValue == "quick-toggle" }) {
            primary.title = L10n.text("화면 가림 해제"); primary.action = #selector(toggleLock)
            primary.isEnabled = true
        }
        statusItem.menu = nil
        statusItem.button?.target = self
        statusItem.button?.action = #selector(showStatusDashboard)
        if let quickMenu { statusDashboard.updateMenu(quickMenu) }
        if statusDashboard.isShown { updateDashboard() }
        statusItem.button?.title = locked ? (deadline.map { L10n.text(" %@초", String(describing: remainingSeconds($0))) } ?? L10n.text(" 차단")) : ""
        updateControls()
        writeDiagnostics()
    }

    private func showMessage(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.text("확인"))
        alert.runModal()
    }

    @objc private func toggleLock() {
        if privacyShield.active { unlock(immediateBrightness: true, reason: .emergency) }
        else if locked { requestUnlock() } else { lock(duration: nil) }
    }
    @objc private func quit() {
        relaunchHandoff?.cancel(); relaunchHandoff = nil
        NSApp.terminate(nil)
    }
    private func showInputAccessFailure() {
        if issues[.input] == nil { issues[.input] = L10n.text("입력 차단을 준비할 수 없습니다. 권한을 다시 확인해주세요.") }
        writeDiagnostics()
        showPermissionControls()
    }
    private var languageChangeAllowed: Bool {
        !updateGate.pending && UpdateReadiness(blocking: locked, recording: recordingShortcuts,
            transitioning: coverPending || screenLock.requiresConfirmation || transitionCover.active || transitionCover.preparing || privacyShield.active,
            recovering: coveredBrightnessRestore || previousDisplayRecovery.active || previousDisplayRecoveryPending,
            individualDisplays: individualDisplays.hasWork,
            lidBusy: lidSleep.busy || !lidSleep.settled,
            stopping: terminating || relaunching || relaunchHelpersClosing || installation.working).waitingReason == nil
    }

    @objc private func relaunch() {
        guard !relaunching, !relaunchHelpersClosing, !lidSleep.busy, !privacyShield.active else { return }
        relaunching = true
        previousDisplayRecovery.active = false
        relaunchHelpersClosing = true
        controls?.cancelShortcutRecording()
        unlock(immediateBrightness: true, reason: .relaunch)
        // Release global hooks before launching the replacement, so its emergency hotkey
        // registration does not collide with the exiting instance.
        filter.stop()
        emergencyKeys.close()
        timer?.invalidate(); timer = nil
        guardian.close()
        transitionCover.close()
        // A replacement must not capture dim brightness while the old owner
        // still has a restore queued. Process exit follows its final restore.
        let expiresAt = ProcessInfo.processInfo.systemUptime + 6
        let waiter = Timer(timeInterval: 0.05, repeats: true) { [weak self] waiter in
            guard let self else { waiter.invalidate(); return }
            self.updateLidSleep()
            if !self.guardian.running && !self.transitionCover.running && self.lidSleep.settled {
                waiter.invalidate(); self.relaunchTimer = nil
                self.relaunchHelpersClosing = false
                self.lidSleep.disconnect()
                self.openReplacementApplication()
            } else if ProcessInfo.processInfo.systemUptime >= expiresAt {
                waiter.invalidate(); self.relaunchTimer = nil
                self.recoverFromRelaunchFailure(L10n.text("보조 프로세스 종료를 확인하지 못했습니다. 종료가 확인된 뒤 다시 시도해주세요."))
            }
        }
        relaunchTimer = waiter
        RunLoop.main.add(waiter, forMode: .common)
    }

    private func checkDeferredUpdate() {
        guard updateGate.pending, !updateQuiescing else { return }
        let readiness = UpdateReadiness(blocking: locked, recording: recordingShortcuts,
            transitioning: coverPending || screenLock.requiresConfirmation || transitionCover.active || transitionCover.preparing || privacyShield.active,
            recovering: coveredBrightnessRestore || previousDisplayRecovery.active || previousDisplayRecoveryPending,
            individualDisplays: individualDisplays.hasWork,
            lidBusy: lidSleep.busy || !lidSleep.settled,
            stopping: terminating || relaunching || relaunchHelpersClosing || installation.working)
        if let reason = readiness.waitingReason {
            updateWaitingReason = reason
            updateGate.reportWaiting(reason)
            return
        }
        // Fence new locks on this same main-thread turn before stopping hooks.
        updateQuiescing = true; relaunching = true; relaunchHelpersClosing = true
        updateWaitingReason = L10n.text("현재 앱 정리 중")
        controls?.cancelShortcutRecording()
        unlock(immediateBrightness: true, reason: .update)
        filter.stop(); emergencyKeys.close()
        timer?.invalidate(); timer = nil
        guardian.close(); transitionCover.close()
        let expiresAt = ProcessInfo.processInfo.systemUptime + 8
        let waiter = Timer(timeInterval: 0.05, repeats: true) { [weak self] waiter in
            guard let self, self.updateQuiescing else { waiter.invalidate(); return }
            self.updateLidSleep()
            self.updateGate.reportWaiting(L10n.text("현재 앱 정리 중"))
            if !self.guardian.running && !self.transitionCover.running && self.lidSleep.settled {
                waiter.invalidate(); self.relaunchTimer = nil
                self.lidSleep.disconnect()
                self.updateGate.finish { [weak self] sent in
                    guard let self, self.updateQuiescing else { return }
                    if sent {
                        self.waitForUpdateCommit()
                    }
                    else {
                        self.updateQuiescing = false
                        self.recoverFromRelaunchFailure(nil, showAlert: false)
                    }
                }
            } else if ProcessInfo.processInfo.systemUptime >= expiresAt {
                waiter.invalidate(); self.relaunchTimer = nil
                self.updateQuiescing = false
                self.updateGate.stop()
                try? self.updateGate.start()
                self.recoverFromRelaunchFailure(L10n.text("화면 복원을 확인하지 못해 업데이트를 적용하지 않았습니다."), showAlert: false)
            }
        }
        relaunchTimer = waiter
        RunLoop.main.add(waiter, forMode: .common)
    }

    private func waitForUpdateCommit() {
        relaunchTimer?.invalidate()
        let timeout = Timer(timeInterval: 30, repeats: false) { [weak self] _ in
            guard let self, self.updateQuiescing else { return }
            self.updateQuiescing = false
            self.updateGate.stop(); try? self.updateGate.start()
            self.recoverFromRelaunchFailure(L10n.text("업데이트 승인을 받지 못해 현재 버전을 유지합니다."), showAlert: false)
        }
        relaunchTimer = timeout
        RunLoop.main.add(timeout, forMode: .common)
    }

    private func openReplacementApplication() {
        let handoff: RelaunchHandoff
        do { handoff = try RelaunchHandoff.create() }
        catch { recoverFromRelaunchFailure(error.localizedDescription); return }
        relaunchHandoff = handoff
        let expiresAt = ProcessInfo.processInfo.systemUptime + 15
        // Launch Services can wait before invoking its completion. Keep the
        // current owner recoverable throughout that wait as well as readiness.
        let timeout = Timer(timeInterval: 15, repeats: false) { [weak self] _ in
            guard let self, self.relaunchHandoff === handoff else { return }
            self.recoverFromRelaunchFailure(L10n.text("새 앱의 시작을 확인하지 못해 현재 앱을 유지합니다."))
        }
        relaunchTimer = timeout
        RunLoop.main.add(timeout, forMode: .common)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--show-controls", "--relaunch-handoff", handoff.token]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { running, error in
            DispatchQueue.main.async {
                guard self.relaunching, self.relaunchHandoff === handoff else { return }
                if let error {
                    self.recoverFromRelaunchFailure(error.localizedDescription)
                }
                else if let running {
                    self.relaunchTimer?.invalidate(); self.relaunchTimer = nil
                    let waiter = Timer(timeInterval: 0.05, repeats: true) { [weak self] waiter in
                        guard let self, self.relaunchHandoff === handoff else { waiter.invalidate(); return }
                        if !running.isTerminated && handoff.ready(for: running.processIdentifier) {
                            waiter.invalidate(); self.relaunchTimer = nil
                            // Leave the ticket for the replacement to consume
                            // after this process actually exits.
                            NSApp.terminate(nil)
                        } else if running.isTerminated || ProcessInfo.processInfo.systemUptime >= expiresAt {
                            waiter.invalidate(); self.relaunchTimer = nil
                            self.recoverFromRelaunchFailure(L10n.text("새 앱의 시작을 확인하지 못해 현재 앱을 유지합니다."))
                        }
                    }
                    self.relaunchTimer = waiter
                    RunLoop.main.add(waiter, forMode: .common)
                } else {
                    self.recoverFromRelaunchFailure(L10n.text("새 앱을 실행하지 못해 현재 앱을 유지합니다."))
                }
            }
        }
    }

    private func recoverFromRelaunchFailure(_ issue: String?, showAlert: Bool = true) {
        relaunchTimer?.invalidate(); relaunchTimer = nil
        relaunchHandoff?.cancel(); relaunchHandoff = nil
        controls?.cancelShortcutRecording()
        relaunching = false
        resumeDisplayRecoveryAfterShutdown = true
        // A timed-out closing helper still owns its saved state. tick clears
        // this fence after exit; settings and emergency recovery remain usable.
        registerEmergencyHotKey()
        installTapIfAllowed()
        timer = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)
        if let issue { sessionIssue = issue }
        refreshMenu()
        if showAlert, let issue { showMessage(L10n.text("다시 시작 실패"), issue) }
    }
    @objc private func openPermissions() {
        // Open the existing settings pane directly. The asynchronous system prompt
        // can outlive a permission grant and leave a redundant alert on screen.
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func showControls() {
        if controls == nil {
            controls = ControlWindow(
                onTrial: { [weak self] seconds in self?.lock(duration: seconds) },
                onSettings: { [weak self] dim, awake, fade, lockOnUnlock in
                    guard let self, !self.locked else { return }
                    self.dimScreen = dim
                    self.keepAwakeEnabled = awake
                    if !awake { self.lidModeEnabled = false }
                    self.lockOnUnlockEnabled = lockOnUnlock
                    UserDefaults.standard.set(fade, forKey: "brightnessTransitionDuration")
                    self.filter.configure(locked: false, normal: self.normalShortcut, emergency: self.emergencyShortcut)
                    self.refreshMenu()
                },
                onPermissions: { [weak self] in self?.openPermissions() },
                onRetry: { [weak self] in
                    guard let self, !self.locked else { return }
                    self.installTapIfAllowed(checkLiveAccess: true)
                    self.registerEmergencyHotKey()
                    self.refreshMenu()
                },
                onRelaunch: { [weak self] in self?.relaunch() },
                onShortcutChange: { [weak self] normal, emergency in
                    guard let self else { return L10n.text("앱을 다시 열어주세요.") }
                    let error = self.changeShortcuts(normal: normal, emergency: emergency)
                    if let error { self.issues[.shortcut] = error; self.refreshMenu() }
                    return error
                },
                onShortcutRecording: { [weak self] recording in self?.setShortcutRecording(recording) },
                onLanguageChange: { [weak self] language in
                    guard let self, self.languageChangeAllowed else { return }
                    language.store()
                    self.relaunch()
                },
                onErrorSoundChange: { [weak self] enabled in
                    guard let self, !self.locked else { return }
                    self.errorSoundEnabled = enabled
                    self.writeDiagnostics()
                },
                onLidChange: { [weak self] enabled in
                    guard let self, !self.locked, !self.lidSleep.busy else { return }
                    self.lidModeEnabled = enabled
                    if enabled { self.keepAwakeEnabled = true }
                    self.issues[.lid] = nil; self.updateLidSleep(); self.refreshMenu()
                    if enabled && self.lidSleep.needsSetup { self.showPermissionControls() }
                },
                onLidBatteryChange: { [weak self] enabled in
                    guard let self, !self.locked, !self.lidSleep.busy else { return }
                    self.lidOnBatteryEnabled = enabled
                    self.issues[.lid] = nil; self.updateLidSleep(); self.refreshMenu()
                },
                onBatteryReserveChange: { [weak self] percent in
                    guard let self, !self.locked, !self.lidSleep.busy,
                          BatteryReserve.percent(from: percent) != nil,
                          percent != BatteryReserve.stored() else { return }
                    UserDefaults.standard.set(percent, forKey: BatteryReserve.preferenceKey)
                    self.issues[.lid] = nil; self.refreshMenu()
                },
                onLidDurationChange: { [weak self] seconds in
                    guard let self, !self.locked, !self.lidSleep.busy,
                          LidDuration.seconds(from: seconds) != nil else { return }
                    UserDefaults.standard.set(seconds, forKey: LidDuration.preferenceKey)
                    self.refreshMenu()
                },
                onLidSetup: { [weak self] in self?.setupLidMode() },
                onLidRemove: { [weak self] in self?.setupLidMode(remove: true) },
                onLidLog: { [weak self] in self?.lidSleep.revealLog() })
        }
        updateControls()
        controls?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateControls() {
        guard let controls else { return }
        let input = filter.snapshot
        let sourceLabel = keepAwake.acPower ? L10n.text("전원 연결됨") : L10n.text("배터리 %@%", String(describing: keepAwake.source.batteryPercent.map(String.init) ?? "—"))
        let power = keepAwake.active ? L10n.text("동작 중 · %@", String(describing: sourceLabel)) :
            (!keepAwakeEnabled ? L10n.text("사용 안 함") : (!locked ? L10n.text("차단 시작 시 동작") :
                (keepAwake.acPower || (lidModeEnabled && lidOnBatteryEnabled) ? L10n.text("상태 확인 필요") : L10n.text("전원 연결 시 동작"))))
        controls.update(ControlWindowState(
            locked: locked, ready: input.enabled, title: stateLabel,
            dim: dimScreen, awake: keepAwakeEnabled, shortcut: normalShortcut, emergency: emergencyShortcut,
            fade: normalBrightnessTransitionDuration(),
            lockOnUnlock: lockOnUnlockEnabled,
            errorSound: errorSoundEnabled,
            powerStatus: power, idleStatus: idleActivity.statusText,
            physicalEvents: input.blocked, softwareEvents: input.passed,
            accessibility: AXIsProcessTrusted(),
            issue: issues.current,
            lidEnabled: lidModeEnabled, lidOnBattery: lidOnBatteryEnabled, batteryReservePercent: BatteryReserve.stored(), lidStatus: lidSleep.statusText,
            lidDurationSeconds: LidDuration.stored(),
            lidInstalled: lidSleep.installed, lidNeedsSetup: lidSleep.needsSetup,
            lidBusy: lidSleep.busy || lidSleep.recovering || !lidSleep.settled,
            lidSetupTitle: lidSleep.setupTitle,
            lidHasLog: FileManager.default.fileExists(atPath: LidPaths.log),
            lidHasService: FileManager.default.fileExists(atPath: LidPaths.configuration), updating: updateQuiescing,
            privacyShielded: privacyShield.active, languageChangeAllowed: languageChangeAllowed))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard normalStarted else { installation.raise(); return false }
        if !locked { showControls() }
        return true
    }

    @objc private func showPermissionControls() {
        showControls()
        controls?.showPermissions()
    }
    @objc private func showAbout() { QuickMenu.showAbout() }
}
