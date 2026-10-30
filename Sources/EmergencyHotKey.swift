import Carbon

/// Registration is transactional; failed replacement preserves the old binding.
struct HotKeyRegistration {
    private(set) var shortcut = KeyboardShortcut.emergency
    private(set) var activeID: UInt32?
    private var nextID: UInt32 = 0
    private(set) var suspended = false
    mutating func replace(_ candidate: KeyboardShortcut, register: (KeyboardShortcut, UInt32) -> Bool,
                          remove: (UInt32) -> Void) -> Bool {
        if candidate == shortcut && activeID != nil { return true }
        nextID += 1
        guard register(candidate, nextID) else { return false }
        if let activeID { remove(activeID) }
        shortcut = candidate; activeID = nextID
        return true
    }
    mutating func suspend(remove: (UInt32) -> Void) {
        suspended = true
        if let activeID { remove(activeID) }
        activeID = nil
    }
    mutating func resume(register: (KeyboardShortcut, UInt32) -> Bool, remove: (UInt32) -> Void) -> Bool {
        let result = replace(shortcut, register: register, remove: remove)
        suspended = false; return result
    }
    func accepts(id: UInt32) -> Bool { !suspended && activeID == id }
}

final class EmergencyHotKey {
    private var model = HotKeyRegistration()
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    var onEmergency: (() -> Void)?
    var shortcut: KeyboardShortcut { model.shortcut }
    var active: Bool { model.activeID != nil && !model.suspended }

    private func installHandler() -> Bool {
        if handler != nil { return true }
        var kind = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return noErr }
            let owner = Unmanaged<EmergencyHotKey>.fromOpaque(context).takeUnretainedValue()
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            if result == noErr && identifier.signature == 0x534C434B && owner.model.accepts(id: identifier.id) {
                owner.onEmergency?()
            }
            return noErr
        }, 1, &kind, Unmanaged.passUnretained(self).toOpaque(), &handler) == noErr
    }
    private func register(_ shortcut: KeyboardShortcut, id: UInt32) -> Bool {
        var reference: EventHotKeyRef?
        guard RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
            EventHotKeyID(signature: 0x534C434B, id: id), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &reference) == noErr, let reference else { return false }
        references[id] = reference; return true
    }
    private func remove(id: UInt32) { if let reference = references.removeValue(forKey: id) { UnregisterEventHotKey(reference) } }
    func replace(_ shortcut: KeyboardShortcut) -> Bool {
        guard installHandler() else { return false }
        return model.replace(shortcut, register: { self.register($0, id: $1) }, remove: { self.remove(id: $0) })
    }
    func suspend() { model.suspend { self.remove(id: $0) } }
    func resume() -> Bool {
        model.resume(register: { self.register($0, id: $1) }, remove: { self.remove(id: $0) })
    }
    func close() {
        model.suspend { self.remove(id: $0) }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
    deinit { close() }
}
