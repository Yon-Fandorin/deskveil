import AppKit
import Carbon
import CoreGraphics

struct HeldInputSnapshot {
    var held: Bool
    var flags: CGEventFlags
    var counts: [String: Int] = [:]
}

/// Tracks releases before the input filter discards them. WindowServer's cached state can be stale.
final class InputHoldTracker {
    private static let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
    private static let modifierFlags: [Int64: CGEventFlags] = [
        54: .maskCommand, 55: .maskCommand, 56: .maskShift, 58: .maskAlternate,
        59: .maskControl, 60: .maskShift, 61: .maskAlternate, 62: .maskControl, 63: .maskSecondaryFn
    ]
    private static let modifierKeys = Set(modifierFlags.keys).union([57])
    private var physicalKeys: Set<Int64> = []
    private var injectedKeys: Set<Int64> = []
    private var physicalButtons: Set<Int64> = []
    private var injectedButtons: Set<Int64> = []
    private var initialKeys: Set<Int64> = []
    private var initialButtons: Set<Int64> = []
    private var initialHIDKeys: Set<Int64> = []
    private var initialHIDButtons: Set<Int64> = []
    private var physicalModifiers: CGEventFlags = []
    private var injectedModifiers: CGEventFlags = []
    private var injectedModifierKeys: Set<Int64> = []
    private var injectedModifierGestures: CGEventFlags = []
    private var initialModifiers: CGEventFlags = []
    private var initialHIDModifiers: CGEventFlags = []
    private var caps: CGEventFlags = []

    var snapshot: HeldInputSnapshot {
        let injectedFlags = injectedModifierKeys.reduce(injectedModifiers.union(injectedModifierGestures)) {
            $0.union(Self.modifierFlags[$1] ?? [])
        }
        let flags = physicalModifiers.union(injectedFlags).union(initialModifiers)
        return HeldInputSnapshot(held: !flags.isEmpty || !physicalKeys.isEmpty || !injectedKeys.isEmpty
                                 || !initialKeys.isEmpty || !physicalButtons.isEmpty
                                 || !injectedButtons.isEmpty || !initialButtons.isEmpty,
                                 flags: flags.union(caps), counts: [
                                    "physicalKeys": physicalKeys.count, "injectedKeys": injectedKeys.count,
                                    "physicalButtons": physicalButtons.count, "injectedButtons": injectedButtons.count,
                                    "seededKeys": initialKeys.count, "seededButtons": initialButtons.count,
                                    "physicalModifiers": physicalModifiers.isEmpty ? 0 : 1,
                                    "injectedModifiers": injectedFlags.isEmpty ? 0 : 1,
                                    "seededModifiers": initialModifiers.isEmpty ? 0 : 1
                                 ])
    }

    func seed() {
        let keys = Set((0..<128).map(Int64.init).filter {
            !Self.modifierKeys.contains($0) && CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0))
        })
        let buttons = Set((0..<32).map(Int64.init).filter {
            guard let button = CGMouseButton(rawValue: UInt32($0)) else { return false }
            return CGEventSource.buttonState(.combinedSessionState, button: button)
        })
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let hidKeys = keys.filter { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) }
        let hidButtons = buttons.filter { value in
            guard let button = CGMouseButton(rawValue: UInt32(value)) else { return false }
            return CGEventSource.buttonState(.hidSystemState, button: button)
        }
        seed(keys: keys, buttons: buttons, flags: flags, hidKeys: hidKeys, hidButtons: hidButtons,
             hidFlags: CGEventSource.flagsState(.hidSystemState))
    }

    func seed(keys: Set<Int64>, buttons: Set<Int64>, flags: CGEventFlags,
              hidKeys: Set<Int64> = [], hidButtons: Set<Int64> = [], hidFlags: CGEventFlags = []) {
        // Native tables have no process identity. Unknown/combined-only seeds
        // need native release confirmation; matching physical ups can retire HID
        // candidates even when filtering those ups leaves the caches stale.
        physicalKeys = []; injectedKeys = []
        physicalButtons = []; injectedButtons = []
        physicalModifiers = []; injectedModifiers = []
        injectedModifierKeys = []
        injectedModifierGestures = []
        initialKeys = keys
        initialButtons = buttons
        initialHIDKeys = keys.intersection(hidKeys)
        initialHIDButtons = buttons.intersection(hidButtons)
        initialModifiers = flags.intersection(Self.modifiers)
        initialHIDModifiers = initialModifiers.intersection(hidFlags)
        caps = flags.intersection(.maskAlphaShift)
    }

    /// State copied before the tap started has no matching down event in this tracker.
    /// Reconcile only seeded entries once both native state tables report a release.
    /// Never reconcile observed down events against these caches: filtered hardware downs
    /// may not appear there, and filtered ups may leave the caches incorrectly pressed.
    func reconcileSeededInput(
        keyIsDown: (Int64) -> Bool = { key in
            [.combinedSessionState, .hidSystemState].contains { CGEventSource.keyState($0, key: CGKeyCode(key)) }
        },
        buttonIsDown: (Int64) -> Bool = { value in
            guard let button = CGMouseButton(rawValue: UInt32(value)) else { return false }
            return [.combinedSessionState, .hidSystemState].contains { CGEventSource.buttonState($0, button: button) }
        },
        modifierFlags: () -> CGEventFlags = {
            CGEventSource.flagsState(.combinedSessionState).union(CGEventSource.flagsState(.hidSystemState))
        }) {
        guard !initialKeys.isEmpty || !initialButtons.isEmpty || !initialModifiers.isEmpty else { return }
        initialKeys = initialKeys.filter(keyIsDown)
        initialButtons = initialButtons.filter(buttonIsDown)
        initialModifiers.formIntersection(modifierFlags())
        initialHIDKeys.formIntersection(initialKeys)
        initialHIDButtons.formIntersection(initialButtons)
        initialHIDModifiers.formIntersection(initialModifiers)
    }

    func observe(type: CGEventType, key: Int64, button: Int64, flags: CGEventFlags, physical: Bool, locked: Bool) {
        switch type {
        case .keyDown:
            if key != 57 {
                if physical { physicalKeys.insert(key) } else { injectedKeys.insert(key) }
            }
            if !physical && Self.modifierFlags[key] != nil { injectedModifierKeys.insert(key) }
        case .keyUp:
            if physical && initialHIDKeys.remove(key) != nil { initialKeys.remove(key) }
            if physical { physicalKeys.remove(key) } else { injectedKeys.remove(key) }
            if !physical {
                injectedModifierKeys.remove(key)
                if let modifier = Self.modifierFlags[key], !flags.contains(modifier) {
                    injectedModifierGestures.remove(modifier)
                }
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if physical { physicalButtons.insert(button) } else { injectedButtons.insert(button) }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if physical && initialHIDButtons.remove(button) != nil { initialButtons.remove(button) }
            if physical { physicalButtons.remove(button) } else { injectedButtons.remove(button) }
        default: break
        }
        if [.flagsChanged, .keyDown, .keyUp].contains(type) {
            if type == .flagsChanged {
                // A filtered physical release may never update native caches. Only
                // retire its matching HID seed; injected or unrelated releases do
                // not establish that startup input was released. HID state/source
                // metadata cannot distinguish overlapping automation per process.
                if physical, let modifier = Self.modifierFlags[key], !flags.contains(modifier),
                   initialHIDModifiers.contains(modifier) {
                    initialModifiers.remove(modifier)
                    initialHIDModifiers.remove(modifier)
                }
                if physical { physicalKeys.subtract(Self.modifierKeys) }
                else if let modifier = Self.modifierFlags[key] {
                    // Ordinary event flags describe that event's context. A
                    // matching gesture releases the modifier group; flags do
                    // not identify which side or automation process held it.
                    if flags.contains(modifier) { injectedModifierGestures.insert(modifier) }
                    else {
                        injectedModifierGestures.remove(modifier)
                        let released = injectedModifierKeys.filter { Self.modifierFlags[$0] == modifier }
                        injectedModifierKeys.subtract(released)
                        injectedKeys.subtract(released)
                    }
                }
            }
            if physical { physicalModifiers = flags.intersection(Self.modifiers) }
            else { injectedModifiers = flags.intersection(Self.modifiers) }
            if !physical || !locked { caps = flags.intersection(.maskAlphaShift) }
        }
    }
}

struct IdleActivitySnapshot {
    var idleSeconds: TimeInterval
    var permission = true
    var sessionAvailable = true
    var onConsole = true
    var screenLocked = false
    var displayAsleep = false
    var screenSaverRunning = false
    var secureInput = false
    var inputHeld = false

    var unsafeReason: String? {
        if !permission { return "permission" }
        if !sessionAvailable || !onConsole { return "other-session" }
        if screenLocked { return "macOS-locked" }
        if displayAsleep { return "display-asleep" }
        if screenSaverRunning { return "screen-saver" }
        if secureInput { return "secure-input" }
        if inputHeld { return "input-held" }
        return nil
    }
}

enum IdlePulseResult { case posted, skipped, unavailable }

protocol IdleActivityDriver {
    func snapshot() -> IdleActivitySnapshot
    func pulse() -> IdlePulseResult
}

struct NativeIdleActivity: IdleActivityDriver {
    private static let allInput = CGEventType(rawValue: UInt32.max)!
    var inputState: (() -> HeldInputSnapshot?)? = nil

    func snapshot() -> IdleActivitySnapshot {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let inputHeld = inputState?()?.held ?? [CGEventSourceStateID.combinedSessionState, .hidSystemState].contains { state in
            (0..<128).contains { $0 != 57 && CGEventSource.keyState(state, key: CGKeyCode($0)) }
                || (0..<32).contains {
                    guard let button = CGMouseButton(rawValue: UInt32($0)) else { return false }
                    return CGEventSource.buttonState(state, button: button)
                }
        }
        return IdleActivitySnapshot(
            // HID activity can reset even when WindowServer does not forward
            // an unchanged flags event into the combined-session state table.
            idleSeconds: CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: Self.allInput),
            permission: AXIsProcessTrusted(),
            sessionAvailable: session != nil,
            onConsole: session?[kCGSessionOnConsoleKey as String] as? Bool ?? false,
            screenLocked: session?["CGSSessionScreenIsLocked"] as? Bool ?? false,
            displayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0,
            screenSaverRunning: NSWorkspace.shared.runningApplications.contains {
                ["com.apple.ScreenSaver.Engine", "com.apple.ScreenSaver.Engine.legacyScreenSaver"].contains($0.bundleIdentifier ?? "")
            },
            secureInput: IsSecureEventInputEnabled(),
            inputHeld: inputHeld)
    }

    /// The modifier state stays exactly as it was; no keyboard key, text, click, or pointer motion.
    static func makePulse(flags: CGEventFlags) -> CGEvent? {
        guard let source = CGEventSource(stateID: .privateState), let event = CGEvent(source: source) else { return nil }
        event.type = .flagsChanged
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: 0x534C4944)
        return event
    }

    func pulse() -> IdlePulseResult {
        guard snapshot().unsafeReason == nil else { return .skipped }
        let flags = inputState?()?.flags ?? CGEventSource.flagsState(.combinedSessionState)
        guard flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]).isEmpty else {
            return .skipped
        }
        guard let event = Self.makePulse(flags: flags) else { return .unavailable }
        event.post(tap: .cghidEventTap)
        return .posted
    }
}

/// Verifies HID activity within the active keep-awake scope. Actual macOS screen-lock
/// state is monitored separately rather than inferred from this timer.
final class IdleActivityController {
    private let driver: IdleActivityDriver
    private let threshold: TimeInterval
    private var pendingAt: TimeInterval?
    private var lastAttempt: TimeInterval?
    private(set) var scoped = false
    private(set) var state = "inactive"
    private(set) var idleSeconds: TimeInterval = 0
    private(set) var pulseCount = 0
    private(set) var verifiedCount = 0

    var statusText: String {
        switch state {
        case "inactive": return L10n.text("꺼짐")
        case "verified": return L10n.text("예방 신호 확인됨")
        case "verifying": return L10n.text("동작 확인 중")
        case "waiting-for-idle": return L10n.text("입력이 없으면 동작")
        case "paused:input-held", "paused:input-changed": return L10n.text("입력 중 · 대기")
        case "paused:permission": return L10n.text("손쉬운 사용 권한 필요")
        case "paused:other-session": return L10n.text("사용자 전환 · 중단")
        case "paused:macOS-locked": return L10n.text("macOS 잠금 중 · 중단")
        case "paused:screen-saver": return L10n.text("화면 보호기 · 중단")
        case "paused:display-asleep": return L10n.text("화면 잠자기 · 중단")
        case "paused:secure-input": return L10n.text("암호 등 보안 입력 중 · 중단")
        default: return L10n.text("상태 확인 필요")
        }
    }

    init(driver: IdleActivityDriver = NativeIdleActivity(), threshold: TimeInterval = 5) {
        self.driver = driver
        self.threshold = threshold
    }

    @discardableResult
    func update(active: Bool, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> String? {
        scoped = active
        guard active else { stop(); return nil }
        let snapshot = driver.snapshot()
        idleSeconds = snapshot.idleSeconds
        if let reason = snapshot.unsafeReason {
            pendingAt = nil
            state = "paused:\(reason)"
            return nil
        }
        guard idleSeconds.isFinite && idleSeconds >= 0 else {
            state = "idle-time-unavailable"
            return L10n.text("자동 잠금 방지: 유휴 시간을 읽을 수 없습니다.")
        }
        if let pendingAt {
            guard now >= pendingAt + 1 else { return nil }
            self.pendingAt = nil
            if idleSeconds < max(2, now - pendingAt + 1) {
                verifiedCount += 1
                state = "verified"
            } else {
                state = "idle-reset-failed"
                return L10n.text("자동 잠금 방지 신호가 유휴 시간을 초기화하지 못했습니다.")
            }
        }
        guard idleSeconds >= threshold else {
            if state != "verified" { state = "waiting-for-idle" }
            return nil
        }
        guard lastAttempt.map({ now >= $0 + threshold }) ?? true else { return nil }
        lastAttempt = now
        switch driver.pulse() {
        case .posted:
            pendingAt = now
            pulseCount += 1
            state = "verifying"
        case .skipped: state = "paused:input-changed"
        case .unavailable:
            state = "pulse-unavailable"
            return L10n.text("자동 잠금 방지 신호를 생성할 수 없습니다.")
        }
        return nil
    }

    func stop() {
        scoped = false
        pendingAt = nil
        lastAttempt = nil
        state = "inactive"
    }
}
