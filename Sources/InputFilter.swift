import CoreGraphics
import Foundation

enum InputFilterAction: String { case lock, unlock, emergency, interrupted, expired, unresponsive }

struct InputFilterSnapshot {
    let created: Bool
    let enabled: Bool
    let locked: Bool
    let blocked: Int
    let passed: Int
    let gestures: [String: Int]
    let heldInput: HeldInputSnapshot
    var releasedBy: InputFilterAction? = nil
}

/// Owns event delivery and input state. No AppKit, process launches, or power/brightness work
/// is allowed on this path. Commands are delivered to the application on the main queue.
final class InputFilter {
    private let mutex = NSLock()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var locked = false
    private var releasedBy: InputFilterAction?
    private var defersManualUnlock = false
    private var normalBinding = KeyboardShortcut.normal
    private var emergencyBinding = KeyboardShortcut.emergency
    private var shortcutsSuspended = false
    private var observationInterrupted = false
    private var captureKeys: Set<Int64> = []
    private var generation = 0
    private var configurationEpoch: UInt64 = 0
    private var deadline: TimeInterval?
    private var mainHeartbeat = ProcessInfo.processInfo.systemUptime
    private var swallowedKeys: Set<Int64> = []
    private var blocked = 0
    private var passed = 0
    private var gestures: [String: Int] = [:]
    private let input = InputHoldTracker()
    private let seedInput: (InputHoldTracker) -> Void
    init(seedInput: @escaping (InputHoldTracker) -> Void = { $0.seed() }) { self.seedInput = seedInput }
    var onAction: ((InputFilterAction) -> Void)? // Set once, before starting the filter.
    var captureGestureInFlight: Bool {
        mutex.lock(); defer { mutex.unlock() }; return !captureKeys.isEmpty
    }

    var snapshot: InputFilterSnapshot {
        mutex.lock(); defer { mutex.unlock() }
        input.reconcileSeededInput()
        return InputFilterSnapshot(created: tap != nil,
                                   enabled: tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false,
                                   locked: locked, blocked: blocked, passed: passed,
                                   gestures: gestures, heldInput: input.snapshot, releasedBy: releasedBy)
    }

    func configure(locked value: Bool, shortcut: Int64, deadline: TimeInterval? = nil,
                   deferManualUnlock: Bool = false) {
        configure(locked: value, normal: KeyboardShortcut(keyCode: UInt32(shortcut), modifiers: KeyboardShortcut.normal.modifiers),
                  emergency: .emergency, deadline: deadline, deferManualUnlock: deferManualUnlock)
    }

    func configure(locked value: Bool, normal: KeyboardShortcut, emergency: KeyboardShortcut,
                   deadline: TimeInterval? = nil, deferManualUnlock: Bool = false) {
        mutex.lock(); defer { mutex.unlock() }
        configurationEpoch += 1
        releasedBy = nil
        if value && !locked { blocked = 0; passed = 0; gestures = [:] }
        locked = value
        defersManualUnlock = value && deferManualUnlock
        normalBinding = normal; emergencyBinding = emergency
        self.deadline = deadline
        mainHeartbeat = ProcessInfo.processInfo.systemUptime
    }
    func suspendShortcuts(_ value: Bool) {
        mutex.lock(); defer { mutex.unlock() }
        guard !locked else { return }
        shortcutsSuspended = value
    }
    func markObservationGap() {
        mutex.lock(); observationInterrupted = true; mutex.unlock()
    }
    @discardableResult func resumeObservation(secureInput: Bool, consoleActive: Bool, observationEnabled: Bool) -> Bool {
        mutex.lock(); defer { mutex.unlock() }
        guard observationInterrupted, !locked, !secureInput, consoleActive, observationEnabled else { return false }
        seedInput(input); swallowedKeys.removeAll(); captureKeys.removeAll(); observationInterrupted = false
        return true
    }

    func heartbeat() {
        mutex.lock(); defer { mutex.unlock() }
        mainHeartbeat = ProcessInfo.processInfo.systemUptime
    }

    /// Secure login can hide key-up events from the previous session. Reseed only
    /// after macOS has authenticated the user, never during active input blocking.
    func reseedAfterSessionBoundary() {
        mutex.lock(); defer { mutex.unlock() }
        guard !locked else { return }
        seedInput(input)
        swallowedKeys.removeAll()
        captureKeys.removeAll()
        observationInterrupted = false
    }

    /// The input thread releases the lock even if the UI cannot process its timer or shortcut.
    func checkHealth(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        mutex.lock()
        let action: InputFilterAction?
        if locked, let deadline, now >= deadline { action = .expired }
        else if locked && now - mainHeartbeat > 4 { action = .unresponsive }
        else { action = nil }
        if let action { locked = false; releasedBy = action }
        let epoch = configurationEpoch
        mutex.unlock()
        if let action { dispatch(action, epoch: epoch) }
    }

    func start() -> Bool {
        mutex.lock(); let existing = tap, blocking = locked; mutex.unlock()
        guard !blocking else { return false }
        if let existing, CFMachPortIsValid(existing) {
            if CGEvent.tapIsEnabled(tap: existing) { return true }
            markObservationGap()
            CGEvent.tapEnable(tap: existing, enable: true)
            if CGEvent.tapIsEnabled(tap: existing) { return true }
            // A valid port can still fail to resume. Recreate it once while unlocked.
        }
        if existing != nil { stop() }
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: InputPolicy.eventMask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<InputFilter>.fromOpaque(context).takeUnretainedValue().handle(type: type, event: event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else { return false }
        mutex.lock()
        tap = created
        generation += 1
        let currentGeneration = generation
        seedInput(input)
        mutex.unlock()
        let ready = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [self] in
            Thread.current.name = "SoftLock input filter"
            let loop = CFRunLoopGetCurrent()!
            mutex.lock(); if generation == currentGeneration { runLoop = loop }; mutex.unlock()
            CFRunLoopAddSource(loop, source, .commonModes)
            let watchdog = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault,
                CFAbsoluteTimeGetCurrent() + 0.25, 0.25, 0, 0) { [weak self] _ in
                    guard let self else { return }
                    self.mutex.lock(); let active = self.generation == currentGeneration; self.mutex.unlock()
                    if active { self.checkHealth() }
                }
            CFRunLoopAddTimer(loop, watchdog, .commonModes)
            CGEvent.tapEnable(tap: created, enable: true)
            ready.signal()
            CFRunLoopRun()
            CFRunLoopTimerInvalidate(watchdog)
            CFRunLoopRemoveSource(loop, source, .commonModes)
        }
        ready.wait()
        return snapshot.enabled
    }

    func stop() {
        mutex.lock()
        let oldTap = tap, loop = runLoop
        tap = nil; runLoop = nil; locked = false; releasedBy = nil
        generation += 1; configurationEpoch += 1; observationInterrupted = true
        mutex.unlock()
        if let oldTap { CGEvent.tapEnable(tap: oldTap, enable: false); CFMachPortInvalidate(oldTap) }
        if let loop { CFRunLoopStop(loop) }
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        mutex.lock()
        let result = filter(type: type, event: event)
        let epoch = configurationEpoch
        mutex.unlock()
        if let action = result.action { dispatch(action, epoch: epoch) }
        return result.pass ? Unmanaged.passUnretained(event) : nil
    }

    private func dispatch(_ action: InputFilterAction, epoch: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.mutex.lock(); let current = self.configurationEpoch == epoch; self.mutex.unlock()
            // Explicit emergency intent must survive the preceding queued lock;
            // stale automatic recovery and ordinary commands remain scoped.
            if case .emergency = action { self.onAction?(action) }
            else if current { self.onAction?(action) }
        }
    }

    private func filter(type: CGEventType, event: CGEvent) -> (pass: Bool, action: InputFilterAction?) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if locked { releasedBy = .interrupted }
            locked = false // Release immediately, even when the main queue is busy.
            observationInterrupted = true
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return (true, .interrupted)
        }
        let physical = InputPolicy.isPhysical(event)
        if type == .flagsChanged && event.getIntegerValueField(.eventSourceUserData) == 0x534C4944 {
            // Input can change between pulse creation and delivery. Never send
            // its older modifier snapshot to apps after a new gesture or unlock.
            let current = input.snapshot
            guard locked, !current.held, event.flags == current.flags else { return (false, nil) }
        } else {
            input.observe(type: type, key: event.getIntegerValueField(.keyboardEventKeycode),
                          button: event.getIntegerValueField(.mouseEventButtonNumber), flags: event.flags,
                          physical: physical, locked: locked)
        }
        if locked && InputPolicy.gestureTypes.contains(type.rawValue) {
            let key = "type:\(type.rawValue) state:\(event.getIntegerValueField(.eventSourceStateID)) pid:\(event.getIntegerValueField(.eventSourceUnixProcessID)) \(physical ? "blocked" : "passed")"
            if gestures.count < 64 || gestures[key] != nil { gestures[key, default: 0] += 1 }
        }
        guard physical else {
            if locked { passed += 1 }
            return (true, nil)
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if swallowedKeys.contains(key) {
            if type == .keyDown { return (false, nil) }
            if type == .keyUp { swallowedKeys.remove(key); return (false, nil) }
        }
        if shortcutsSuspended && !locked {
            if type == .keyDown { captureKeys.insert(key) }
            if type == .keyUp { captureKeys.remove(key) }
            return (true, nil)
        }
        if captureKeys.contains(key) && [.keyDown, .keyUp].contains(type) {
            if type == .keyUp { captureKeys.remove(key) }
            return (false, nil)
        }
        let toggle = normalBinding.matches(type: type, keyCode: key, flags: event.flags)
        let emergency = emergencyBinding.matches(type: type, keyCode: key, flags: event.flags)
        if toggle || emergency {
            // A repeated down or duplicate down without a release cannot enqueue another toggle.
            let first = swallowedKeys.insert(key).inserted
            let action: InputFilterAction? = first && event.getIntegerValueField(.keyboardEventAutorepeat) == 0
                ? (emergency ? .emergency : (locked ? .unlock : .lock)) : nil
            // A normal unlock can be gated by macOS lock confirmation. Emergency
            // and watchdog recovery still release immediately on the input thread.
            if action == .emergency { releasedBy = .emergency }
            if let action, locked && (emergency || !defersManualUnlock) {
                locked = false; releasedBy = action
            }
            return (false, action)
        }
        if locked { blocked += 1; return (false, nil) }
        return (true, nil)
    }
}
