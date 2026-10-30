import CoreGraphics
import Foundation
import Darwin

enum BrightnessTransitionResult: Equatable {
    case restored, dimFailed, restoreFailed
}

/// One dim failure restores all affected displays; report the final recovery outcome.
func brightnessTransitionReplies(_ results: [BrightnessTransitionResult], brightness: NativeBrightness,
                                 dimID: UInt64, restoreID: UInt64) -> [GuardianReply] {
    if results.contains(.dimFailed) {
        var replies = [GuardianReply(message: "dimmed:0", id: dimID)]
        if !brightness.restore() { replies.append(GuardianReply(message: "restore-failed", id: dimID)) }
        return replies
    }
    return results.compactMap { result in
        switch result {
        case .restored: return GuardianReply(message: "restored", id: restoreID)
        case .restoreFailed: return GuardianReply(message: "restore-failed", id: restoreID)
        case .dimFailed: return nil
        }
    }
}

func normalBrightnessTransitionDuration() -> TimeInterval {
    guard let value = UserDefaults.standard.object(forKey: "brightnessTransitionDuration") as? NSNumber else { return 0.3 }
    let duration = value.doubleValue
    return duration.isFinite && (0...2).contains(duration) ? duration : 0.3
}

private struct BrightnessFade {
    let from: Float
    let to: Float
    let started: TimeInterval
    let duration: TimeInterval
    let restoring: Bool

    func value(at now: TimeInterval) -> Float {
        let progress = Float(min(1, max(0, (now - started) / duration)))
        let eased = progress * progress * (3 - 2 * progress)
        return from + (to - from) * eased
    }
}

/// Physical brightness and external output gamma. Displays remain connected for automation.
final class NativeBrightness {
    typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
    private var library: UnsafeMutableRawPointer?
    private var getBrightness: Get?
    private var setBrightness: SetBrightness?
    private lazy var ddc = NativeDDCBrightness()
    private var nativeDisplays = Set<String>()
    private var saved: [String: Float] = [:]
    private var fades: [String: BrightnessFade] = [:]
    private var dimming = false
    private var individualTargets = Set<String>()
    private(set) var verifiedIndividualMaintenance = Set<String>()
    private var dimFailures = Set<String>()
    private var lastDDCMaintenance: TimeInterval = -.infinity
    private var recovery: BrightnessRecoveryStore?
    private var recoveryLoadFailed = false
    private var emptyRecoveryPending = false
    private var blackout: ExternalBlackout?
    private var blackoutEligible: (UInt32) -> Bool = { CGDisplayIsBuiltin($0) == 0 }
    private var displayProvider: (() -> [UInt32])?
    private var identityProvider: ((UInt32) -> String)?
    private var readOverride: ((UInt32) -> Float?)?
    private var writeOverride: ((UInt32, Float) -> Bool)?
    private var verifyOverride: ((UInt32, Float) -> Bool)?
    private(set) var unsupportedDisplays = 0
    var transitioning: Bool { !fades.isEmpty }
    private var hasRecoveryLoadFailure: Bool { recoveryLoadFailed || blackout?.recoveryLoadFailed == true }
    var hasPendingRestore: Bool { recoveryLoadFailed || emptyRecoveryPending || !saved.isEmpty || blackout?.hasPendingRestore == true }

    init(displays: @escaping () -> [UInt32], read: ((UInt32) -> Float?)? = nil,
         write: ((UInt32, Float) -> Bool)? = nil, identity: @escaping (UInt32) -> String = { String($0) },
         recovery: BrightnessRecoveryStore? = nil, verify: ((UInt32, Float) -> Bool)? = nil,
         blackout: ExternalBlackout? = nil, blackoutEligible: @escaping (UInt32) -> Bool = { _ in true },
         nativeGet: Get? = nil, nativeSet: SetBrightness? = nil) {
        displayProvider = displays; identityProvider = identity
        readOverride = read; writeOverride = write; verifyOverride = verify
        self.recovery = recovery
        self.blackout = blackout; self.blackoutEligible = blackoutEligible
        getBrightness = nativeGet; setBrightness = nativeSet
        loadRecovery()
    }

    init() {
        recovery = FileBrightnessRecovery()
        blackout = ExternalBlackout()
        loadRecovery()
        library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        if let library, let get = dlsym(library, "DisplayServicesGetBrightness"),
           let set = dlsym(library, "DisplayServicesSetBrightness") {
            getBrightness = unsafeBitCast(get, to: Get.self)
            setBrightness = unsafeBitCast(set, to: SetBrightness.self)
        }
    }
    deinit { if let library { dlclose(library) } }

    private func loadRecovery() {
        switch recovery?.load() ?? .absent {
        case .loaded(let values): saved = values; emptyRecoveryPending = values.isEmpty
        case .failed: recoveryLoadFailed = true
        case .absent: break
        }
    }
    private func reloadRecoveryForRestore() -> Bool {
        if recoveryLoadFailed, case .loaded(let values) = recovery?.load() ?? .absent {
            saved.merge(values) { original, _ in original }
            recoveryLoadFailed = false
            emptyRecoveryPending = saved.isEmpty
        }
        let gammaReady = blackout?.reloadRecoveryForRestore() ?? true
        guard !recoveryLoadFailed, gammaReady else { return false }
        if emptyRecoveryPending {
            guard saved.isEmpty, recovery?.save([:]) ?? true else { return false }
            emptyRecoveryPending = false
        }
        return blackout?.clearEmptyRecoveryForRestore() ?? true
    }

    private func onlineDisplays() -> [UInt32] {
        if let displayProvider { return displayProvider() }
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return [] }
        var displays = [UInt32](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }
    private func targets() -> [String: UInt32] {
        var result: [String: UInt32] = [:], duplicates = Set<String>()
        for display in onlineDisplays() {
            let key: String
            if let identityProvider { key = identityProvider(display) }
            else {
                guard let identity = ddc.identity(display) else { continue }
                key = identity
            }
            if result[key] != nil { duplicates.insert(key) }
            result[key] = display
        }
        for key in duplicates { result.removeValue(forKey: key) }
        return result
    }
    func readableDisplays() -> Int { currentValues().count }
    private func matchesTarget(_ display: UInt32, key: String) -> Bool { targets()[key] == display }
    func currentValues() -> [UInt32: Float] {
        var values: [UInt32: Float] = [:]
        for (key, display) in targets() { values[display] = readValue(display, key: key) }
        return values
    }
    /// Observe one currently matched display without dimming or recovery writes.
    func observedBrightness(display: UInt32, identity: String) -> Float? {
        guard targets()[identity] == display,
              displayProvider != nil || CGDisplayIsAsleep(display) == 0 else { return nil }
        return readValue(display, key: identity)
    }
    private func readValue(_ display: UInt32, key: String) -> Float? {
        guard matchesTarget(display, key: key) else { return nil }
        if let readOverride {
            let value = readOverride(display)
            return matchesTarget(display, key: key) ? value : nil
        }
        var value: Float = 0
        if getBrightness?(display, &value) == 0, value.isFinite, (0...1).contains(value) {
            guard matchesTarget(display, key: key) else { return nil }
            nativeDisplays.insert(key); return value
        }
        guard CGDisplayIsBuiltin(display) == 0 else { return nil }
        let observed = ddc.read(display, identity: key)
        return matchesTarget(display, key: key) ? observed : nil
    }
    private func writeValue(_ display: UInt32, key: String, value: Float, verify: Bool = false) -> Bool {
        guard !hasRecoveryLoadFailure, matchesTarget(display, key: key) else { return false }
        if let writeOverride {
            return writeOverride(display, value) && matchesTarget(display, key: key) &&
                (!verify || (verifyOverride?(display, value) ?? true)) && matchesTarget(display, key: key)
        }
        // Recovery after restart must discover its backend before the first write.
        if !nativeDisplays.contains(key), !ddc.known(key), readValue(display, key: key) == nil { return false }
        guard matchesTarget(display, key: key) else { return false }
        if nativeDisplays.contains(key) {
            guard setBrightness?(display, value) == 0 else { return false }
            guard matchesTarget(display, key: key) else { return false }
            guard verify else { return true }
            var observed: Float = 0
            guard getBrightness?(display, &observed) == 0, observed.isFinite, (0...1).contains(observed) else { return false }
            return matchesTarget(display, key: key) && abs(observed - value) <= 0.005
        }
        return ddc.write(display, identity: key, value: value, verify: verify)
    }
    private func remember(_ key: String, value: Float) -> Bool {
        guard !hasRecoveryLoadFailure else { return false }
        if saved[key] != nil { return true }
        var next = saved; next[key] = value
        guard recovery?.save(next) ?? true else { return false }
        saved = next; emptyRecoveryPending = false; return true
    }
    private func writeLevel(_ display: UInt32, key: String, value: Float, verify: Bool, restoring: Bool = false) -> Bool {
        let hardware = writeValue(display, key: key, value: value, verify: verify)
        guard let blackout, blackout.pendingIdentities.contains(key) else { return hardware }
        // Restore the exact saved table even if physical brightness was already zero.
        if restoring && verify && value == saved[key] {
            let gamma = blackout.restore(display, identity: key, isCurrent: { self.matchesTarget(display, key: key) })
            return hardware && gamma
        }
        let original = saved[key] ?? 0
        let factor = original > 0 ? min(1, max(0, value / original)) : 0
        let gamma = blackout.apply(display, identity: key, factor: factor, verify: verify, isCurrent: { self.matchesTarget(display, key: key) })
        return hardware && gamma
    }
    private func forget(_ key: String) -> Bool {
        guard !hasRecoveryLoadFailure else { return false }
        var next = saved; next.removeValue(forKey: key)
        guard recovery?.save(next) ?? true else { return false }
        saved = next; emptyRecoveryPending = false; return true
    }

    @discardableResult
    func dim(to target: Float = 0, duration: TimeInterval = 0, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Int {
        guard target.isFinite, (0...1).contains(target) else { return 0 }
        guard !hasRecoveryLoadFailure else { unsupportedDisplays = max(1, onlineDisplays().count); return 0 }
        dimming = true
        individualTargets.removeAll()
        dimFailures.removeAll()
        var changed = 0
        unsupportedDisplays = 0
        let displays = targets()
        unsupportedDisplays = max(0, onlineDisplays().count - displays.count)
        for (key, display) in displays.sorted(by: { $0.value < $1.value }) {
            if let fade = fades[key], !fade.restoring { changed += 1; continue }
            guard let brightness = readValue(display, key: key), brightness.isFinite, (0...1).contains(brightness),
                  remember(key, value: brightness) else {
                // An individual gamma-only blackout already has durable recovery
                // state. Global ownership must keep it even without readable DDC.
                _ = blackout?.enforce(display, identity: key, isCurrent: { self.matchesTarget(display, key: key) })
                dimFailures.insert(key); unsupportedDisplays += 1; continue
            }
            let gammaReady = !blackoutEligible(display) || blackout?.prepare(display, identity: key, isCurrent: { self.matchesTarget(display, key: key) }) != false
            if !gammaReady { dimFailures.insert(key); unsupportedDisplays += 1 }
            let dimmed = min(brightness, target)
            let animated = duration.isFinite && duration > 0 && brightness > dimmed
            if writeLevel(display, key: key, value: animated ? brightness : dimmed, verify: !animated) {
                if animated { fades[key] = BrightnessFade(from: brightness, to: dimmed, started: now, duration: duration, restoring: false) }
                else { fades.removeValue(forKey: key) }
                changed += 1
            } else {
                dimFailures.insert(key)
                if gammaReady { unsupportedDisplays += 1 }
                if let original = saved[key], writeLevel(display, key: key, value: original, verify: true, restoring: true) { _ = forget(key) }
            }
        }
        return changed
    }

    /// The command carries both the current ID and stable identity: an ID reused
    /// by another monitor must never receive a delayed click intended for its predecessor.
    func controlDisplay(_ command: DisplayPowerCommand) -> DisplayPowerOutcome {
        guard command.valid, !dimming, !transitioning else { return .busy }
        if command.off {
            guard !hasRecoveryLoadFailure else { return .recoveryNeeded }
        } else {
            guard reloadRecoveryForRestore() else { return .recoveryNeeded }
        }
        let displays = targets()
        if !command.off {
            // On releases our ownership of this identity even after disconnect
            // or a port move. Never use the click's obsolete ID for restoration.
            let owned = individualTargets.contains(command.identity) || saved[command.identity] != nil ||
                blackout?.pendingIdentities.contains(command.identity) == true
            guard owned || displays[command.identity] == command.displayID else { return .unsupported }
            return restoreIndividual(command.identity, displays: displays)
        }
        guard displays[command.identity] == command.displayID else { return .unsupported }
        let key = command.identity, display = command.displayID
        if individualTargets.contains(key) { return .off }
        let brightness = readValue(display, key: key)
        let gammaRequired = blackoutEligible(display)
        // External monitors may lack readable DDC brightness; gamma alone can
        // black their output while preserving the remote desktop connection.
        guard brightness != nil || gammaRequired else { return .unsupported }
        if gammaRequired {
            guard let blackout, blackout.prepare(display, identity: key, isCurrent: { self.matchesTarget(display, key: key) }) else { return .unsupported }
        }
        if let brightness {
            guard brightness.isFinite, (0...1).contains(brightness), remember(key, value: brightness) else {
                return rollbackIndividual(key, displays: displays)
            }
        }
        let changed = brightness != nil
            ? writeLevel(display, key: key, value: 0, verify: true)
            : blackout?.apply(display, identity: key, factor: 0, verify: true, isCurrent: { self.matchesTarget(display, key: key) }) == true
        guard changed else { return rollbackIndividual(key, displays: displays) }
        individualTargets.insert(key)
        return .off
    }

    private func rollbackIndividual(_ key: String, displays: [String: UInt32]) -> DisplayPowerOutcome {
        restoreIndividual(key, displays: displays) == .on ? .failed : .recoveryNeeded
    }
    private func restoreIndividual(_ key: String, displays: [String: UInt32]) -> DisplayPowerOutcome {
        individualTargets.remove(key)
        guard reloadRecoveryForRestore() else { return .recoveryNeeded }
        guard let display = displays[key] else { return .recoveryNeeded }
        var restored = true
        if let brightness = saved[key] {
            restored = writeLevel(display, key: key, value: brightness, verify: true, restoring: true)
            if restored { restored = forget(key) }
        } else if blackout?.pendingIdentities.contains(key) == true {
            restored = blackout?.restore(display, identity: key, isCurrent: { self.matchesTarget(display, key: key) }) == true
        }
        return restored ? .on : .recoveryNeeded
    }

    /// Retry only an explicitly requested On or failed-Off rollback. Resolving
    /// the current identity here allows reconnect without touching other targets.
    func retryIndividualRestore(_ identity: String) -> Bool {
        guard !dimming, !transitioning else { return false }
        return restoreIndividual(identity, displays: targets()) == .on
    }

    /// Selected monitors only; newly connected monitors remain untouched.
    func maintainIndividualDisplays() -> Set<String> {
        verifiedIndividualMaintenance.removeAll()
        guard !hasRecoveryLoadFailure else { return individualTargets }
        guard !dimming, !individualTargets.isEmpty else { return [] }
        let displays = targets()
        var failures = Set<String>()
        let now = ProcessInfo.processInfo.systemUptime
        let checkDDC = now - lastDDCMaintenance >= 2
        if checkDDC { lastDDCMaintenance = now }
        for key in individualTargets {
            guard let display = displays[key] else { continue }
            let checkHardware = writeOverride != nil || nativeDisplays.contains(key) || checkDDC
            let hardware = saved[key] == nil || !checkHardware || writeValue(display, key: key, value: 0, verify: true)
            let gamma = blackout?.enforce(display, identity: key, isCurrent: { self.matchesTarget(display, key: key) }) ?? true
            if !hardware || !gamma { failures.insert(key) }
            else if saved[key] == nil || checkHardware { verifiedIndividualMaintenance.insert(key) }
        }
        return failures
    }

    func holdDim() -> Bool {
        guard !hasRecoveryLoadFailure else { return false }
        let keys = Set(saved.keys).union(blackout?.pendingIdentities ?? [])
        guard !keys.isEmpty else { return false }
        fades.removeAll()
        let displays = targets()
        var success = true
        for key in keys {
            guard let display = displays[key] else { success = false; continue }
            let held = saved[key] != nil ? writeLevel(display, key: key, value: 0, verify: true)
                : blackout?.enforce(display, identity: key, isCurrent: { self.matchesTarget(display, key: key) }) == true
            if !held { success = false }
        }
        return success
    }

    @discardableResult
    func restore(duration: TimeInterval = 0, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        dimming = false
        individualTargets.removeAll()
        dimFailures.removeAll(); unsupportedDisplays = 0
        guard reloadRecoveryForRestore() else { fades.removeAll(); return false }
        let displays = targets()
        for (key, brightness) in Array(saved) {
            guard let display = displays[key] else { fades.removeValue(forKey: key); continue }
            if duration.isFinite && duration > 0, let current = readValue(display, key: key), current != brightness {
                fades[key] = BrightnessFade(from: current, to: brightness, started: now, duration: duration, restoring: true)
            } else {
                fades.removeValue(forKey: key)
                if writeLevel(display, key: key, value: brightness, verify: true, restoring: true) { _ = forget(key) }
            }
        }
        // A crash may leave only a gamma recovery record. Resolve its stable identity too.
        for key in blackout?.pendingIdentities ?? [] where saved[key] == nil {
            if let display = displays[key] { _ = blackout?.restore(display, identity: key, isCurrent: { self.matchesTarget(display, key: key) }) }
        }
        return saved.keys.allSatisfy { fades[$0]?.restoring == true } &&
            (blackout?.pendingIdentities ?? []).allSatisfy { fades[$0]?.restoring == true }
    }

    @discardableResult
    func advanceTransitions(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [BrightnessTransitionResult] {
        guard !hasRecoveryLoadFailure else { return [] }
        var results: [BrightnessTransitionResult] = []
        var finishedRestore = false
        let displays = targets()
        for (key, fade) in Array(fades) {
            let finished = now >= fade.started + fade.duration
            guard let display = displays[key], writeLevel(display, key: key, value: finished ? fade.to : fade.value(at: now), verify: finished, restoring: fade.restoring) else {
                fades.removeValue(forKey: key)
                if fade.restoring { results.append(.restoreFailed) }
                else {
                    results.append(.dimFailed)
                    if let display = displays[key], let original = saved[key], writeLevel(display, key: key, value: original, verify: true, restoring: true) {
                        if !forget(key) { results.append(.restoreFailed) }
                    } else { results.append(.restoreFailed) }
                }
                continue
            }
            if finished {
                fades.removeValue(forKey: key)
                if fade.restoring {
                    if forget(key) { finishedRestore = true }
                    else { results.append(.restoreFailed) }
                }
            }
        }
        if finishedRestore && !hasPendingRestore { results.append(.restored) }
        return results
    }

    @discardableResult
    func maintainDim() -> Int {
        guard !hasRecoveryLoadFailure, dimming else { return 0 }
        let displays = targets()
        let now = ProcessInfo.processInfo.systemUptime
        let checkDDC = now - lastDDCMaintenance >= 2
        if checkDDC { lastDDCMaintenance = now }
        dimFailures.formIntersection(displays.keys)
        for (key, display) in displays where fades[key] == nil {
            let newDisplay = saved[key] == nil
            let checkHardware = newDisplay || writeOverride != nil || nativeDisplays.contains(key) || checkDDC
            var current: Float?
            if newDisplay {
                current = readValue(display, key: key)
                guard let current, current.isFinite, (0...1).contains(current), remember(key, value: current) else {
                    _ = blackout?.enforce(display, identity: key, isCurrent: { self.matchesTarget(display, key: key) })
                    dimFailures.insert(key); continue
                }
            }
            // Capture recovery state before changing each supported control.
            let gammaReady = !blackoutEligible(display) || blackout?.prepare(display, identity: key, isCurrent: { self.matchesTarget(display, key: key) }) != false
            var hardwareOK = true
            if checkHardware {
                if let value = current ?? readValue(display, key: key), value.isFinite, (0...1).contains(value) {
                    hardwareOK = value == 0 || writeValue(display, key: key, value: 0, verify: true)
                } else { hardwareOK = false }
            }
            // Gamma maintenance is cheap and must not wait for the DDC interval.
            let gammaOK = blackout?.enforce(display, identity: key, isCurrent: { self.matchesTarget(display, key: key) }) ?? true
            if !hardwareOK || !gammaReady || !gammaOK { dimFailures.insert(key) }
            else if checkHardware { dimFailures.remove(key) }
        }
        unsupportedDisplays = dimFailures.count + max(0, onlineDisplays().count - displays.count)
        return displays.count - dimFailures.count
    }
}

private final class BrightnessGuardianFixtureRecovery: BrightnessRecoveryStore {
    var readable = false
    private var values: [String: Float] = ["fixture": 0.75]
    func load() -> DisplayRecoveryLoad<[String: Float]> { readable ? .loaded(values) : .failed }
    func save(_ values: [String: Float]) -> Bool { self.values = values; return true }
}

/// Owns saved brightness in another process. EOF (including SIGKILL of the app)
/// or a missing main-run-loop heartbeat restores the display independently.
func runBrightnessGuardian(fixture: Bool = false) -> Never {
    signal(SIGPIPE, SIG_IGN) // A closed reply pipe must not skip final brightness recovery.
    let lease = fixture ? nil : FileBrightnessRecovery.acquireGuardianLease()
    guard fixture || lease != nil else { exit(1) }
    defer { if let lease { close(lease) } }
    // The lifecycle fixture has no native backend, file store, gamma controller
    // or recovery lease. Even a malformed test cannot touch production state.
    let fixtureRecovery: BrightnessGuardianFixtureRecovery?
    if fixture, ProcessInfo.processInfo.environment["SOFTLOCK_FIXTURE_RECOVERY_READ_FAILURE"] == "1" {
        fixtureRecovery = BrightnessGuardianFixtureRecovery()
    } else { fixtureRecovery = nil }
    var fixtureValue: Float = fixtureRecovery == nil ? 0.75 : 0
    let brightness = fixture
        ? NativeBrightness(displays: { [1] }, read: { _ in fixtureValue }, write: { display, value in
            fixtureValue = value
            let row: [String: Any] = ["fixtureDisplay": display, "value": value]
            if let data = try? JSONSerialization.data(withJSONObject: row) {
                try? FileHandle.standardError.write(contentsOf: data + Data([10]))
            }
            return true
        },
                           identity: { _ in "fixture" }, recovery: fixtureRecovery, blackoutEligible: { _ in false })
        : NativeBrightness()
    var pending = Data()
    var lastHeartbeat = ProcessInfo.processInfo.systemUptime
    var running = true
    var maintainingDim = false
    var maintainedDisplayCount = 0
    var wantsRestore = false
    var lastRestoreAttempt: TimeInterval = -.infinity
    var lockHoldUntil: TimeInterval = 0
    var dimID: UInt64 = 0
    var restoreID: UInt64 = 0
    var individualSession = IndividualDisplaySession()
    var lastIndividualRestoreAttempt: TimeInterval = -.infinity
    func emit(_ message: String, id: UInt64) {
        print(id == 0 ? message : "\(message)@\(id)"); fflush(stdout)
    }
    while running {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
        // Animate in the helper so the input filter's main thread stays responsive.
        let holdingLockTransition = ProcessInfo.processInfo.systemUptime < lockHoldUntil
        let result = poll(&descriptor, 1, brightness.transitioning || holdingLockTransition ? 16 : 500)
        if result < 0 && errno != EINTR { break }
        if result > 0 {
            var bytes = [UInt8](repeating: 0, count: 1024)
            let length = read(STDIN_FILENO, &bytes, bytes.count)
            if length <= 0 { break }
            lastHeartbeat = ProcessInfo.processInfo.systemUptime
            pending.append(contentsOf: bytes.prefix(length))
            while let newline = pending.firstIndex(of: 10) {
                let command = String(decoding: pending[..<newline], as: UTF8.self)
                pending.removeSubrange(...newline)
                let tagged = command.split(separator: "@", maxSplits: 1)
                let id = tagged.count == 2 ? UInt64(tagged[1]) ?? 0 : 0
                let parts = (tagged.first ?? "").split(separator: ":", maxSplits: 1)
                let name = parts.first.map(String.init) ?? command
                let requested = parts.count == 2 ? Double(parts[1]) : nil
                let duration = requested.flatMap { $0.isFinite && (0...2).contains($0) ? $0 : nil }
                    ?? normalBrightnessTransitionDuration()
                switch name {
                case "fixture-recovery-readable":
                    if fixture { fixtureRecovery?.readable = true }
                case "brightness-status":
                    guard parts.count == 2, let target = DisplayBrightnessTarget(payload: String(parts[1])) else { continue }
                    // A read must not delay an animated or protected lock transition.
                    let value = brightness.transitioning || holdingLockTransition || maintainingDim || (wantsRestore && brightness.hasPendingRestore)
                        ? nil : brightness.observedBrightness(display: target.displayID, identity: target.identity)
                    if let message = DisplayBrightnessObservation(target: target, value: value).message {
                        emit(message, id: id)
                    }
                case "individual":
                    guard parts.count == 2, let command = DisplayPowerCommand(payload: String(parts[1])) else {
                        emit(DisplayPowerOutcome.failed.rawValue, id: id); continue
                    }
                    guard !maintainingDim, !(wantsRestore && brightness.hasPendingRestore), !holdingLockTransition, !brightness.transitioning else {
                        emit(DisplayPowerOutcome.busy.rawValue, id: id); continue
                    }
                    wantsRestore = false
                    let outcome = brightness.controlDisplay(command)
                    individualSession.record(command, id: id, outcome: outcome)
                    if outcome == .recoveryNeeded { lastIndividualRestoreAttempt = ProcessInfo.processInfo.systemUptime }
                    emit(outcome.rawValue, id: id)
                case "dim":
                    individualSession.reset()
                    dimID = id; restoreID = 0
                    lockHoldUntil = 0
                    wantsRestore = false
                    let count = brightness.dim(duration: duration)
                    maintainedDisplayCount = count
                    maintainingDim = true
                    emit("dimmed:\(count)", id: dimID)
                    if count > 0 && brightness.unsupportedDisplays > 0 { emit("dim-partial:\(brightness.unsupportedDisplays)", id: dimID) }
                case "restore", "restore-now":
                    individualSession.reset()
                    restoreID = id
                    lockHoldUntil = 0
                    maintainingDim = false
                    wantsRestore = true; lastRestoreAttempt = ProcessInfo.processInfo.systemUptime
                    let accepted = brightness.restore(duration: name == "restore-now" ? 0 : duration)
                    emit(accepted ? (brightness.transitioning ? "restoring" : "restored") : "restore-failed", id: restoreID)
                case "hold-for-lock":
                    lockHoldUntil = ProcessInfo.processInfo.systemUptime + 12
                    maintainingDim = brightness.holdDim()
                case "quit": running = false
                default: break // heartbeat
                }
            }
        }
        if ProcessInfo.processInfo.systemUptime - lastHeartbeat > 4 { break }
        let results = brightness.advanceTransitions()
        if results.contains(.dimFailed) { maintainingDim = false }
        for reply in brightnessTransitionReplies(results, brightness: brightness, dimID: dimID, restoreID: restoreID) {
            emit(reply.message, id: reply.id)
            fflush(stdout)
        }
        if maintainingDim {
            let previous = brightness.unsupportedDisplays
            let count = brightness.maintainDim()
            if brightness.unsupportedDisplays != previous || (maintainedDisplayCount == 0 && count > 0) {
                emit("dim-partial:\(brightness.unsupportedDisplays)", id: dimID)
            }
            maintainedDisplayCount = count
        }
        let failedIndividuals = brightness.maintainIndividualDisplays()
        for reply in individualSession.maintenance(failed: failedIndividuals, verified: brightness.verifiedIndividualMaintenance) {
            emit(reply.message, id: reply.id)
        }
        if !individualSession.recoveries.isEmpty && ProcessInfo.processInfo.systemUptime - lastIndividualRestoreAttempt >= 2 {
            lastIndividualRestoreAttempt = ProcessInfo.processInfo.systemUptime
            for key in individualSession.recoveries.keys.sorted() where brightness.retryIndividualRestore(key) {
                if let reply = individualSession.recovered(key) { emit(reply.message, id: reply.id) }
            }
        }
        if wantsRestore && !brightness.transitioning && brightness.hasPendingRestore &&
            ProcessInfo.processInfo.systemUptime - lastRestoreAttempt >= 2 {
            lastRestoreAttempt = ProcessInfo.processInfo.systemUptime
            if brightness.restore() { emit("restored", id: restoreID) }
        }
    }
    for _ in 0..<3 {
        if brightness.restore() { break }
        usleep(100_000)
    }
    exit(0)
}

struct GuardianMessages {
    private var pending = Data()

    mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var messages: [String] = []
        while let newline = pending.firstIndex(of: 10) {
            messages.append(String(decoding: pending[..<newline], as: UTF8.self))
            pending.removeSubrange(...newline)
        }
        return messages
    }
}

final class BrightnessGuardian {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var messages = GuardianMessages()
    var onMessage: ((String) -> Void)?
    var onExit: (() -> Void)?
    var running: Bool { process?.isRunning == true }

    func start() throws {
        if let process, process.isRunning { return }
        output?.readabilityHandler = nil
        try? input?.close(); try? output?.close()
        input = nil; output = nil; process = nil
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = ["--brightness-guardian"]
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] child in
            DispatchQueue.main.async {
                guard let self, self.process === child else { return }
                self.output?.readabilityHandler = nil
                try? self.output?.close()
                try? self.input?.close()
                self.output = nil
                self.input = nil
                self.process = nil
                self.onExit?()
            }
        }
        try child.run()
        process = child
        messages = GuardianMessages()
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        // Installing this child-capturing handler only after launch avoids a
        // Process/Pipe/handler retain cycle when run() throws.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                guard let self, self.process === child else { return }
                for message in self.messages.append(data) { self.onMessage?(message) }
            }
        }
    }

    @discardableResult func send(_ command: String, id: UInt64 = 0) -> Bool {
        guard let input else { return false }
        let tagged = id == 0 ? command : "\(command)@\(id)"
        do { try input.write(contentsOf: Data((tagged + "\n").utf8)); return true }
        catch { try? input.close(); self.input = nil; return false }
    }

    func close() {
        send("restore")
        send("quit")
        try? input?.close()
        input = nil
    }
}
