import AppKit
import Carbon
import CoreGraphics

struct KeyboardShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    static let supported = UInt32(cmdKey | optionKey | controlKey | shiftKey)
    static let normal = KeyboardShortcut(keyCode: 37, modifiers: UInt32(cmdKey | optionKey | controlKey))
    static let emergency = KeyboardShortcut(keyCode: 32, modifiers: UInt32(cmdKey | optionKey | controlKey))

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode; self.modifiers = modifiers & Self.supported
    }
    init(event: NSEvent) {
        var value: UInt32 = 0
        for (flag, bit) in [(NSEvent.ModifierFlags.command, cmdKey), (.option, optionKey), (.control, controlKey), (.shift, shiftKey)] {
            if event.modifierFlags.contains(flag) { value |= UInt32(bit) }
        }
        self.init(keyCode: UInt32(event.keyCode), modifiers: value)
    }
    var eventFlags: CGEventFlags {
        var value: CGEventFlags = []
        for (bit, flag) in [(cmdKey, CGEventFlags.maskCommand), (optionKey, .maskAlternate), (controlKey, .maskControl), (shiftKey, .maskShift)] {
            if modifiers & UInt32(bit) != 0 { value.insert(flag) }
        }
        return value
    }
    var nsModifiers: NSEvent.ModifierFlags {
        var value: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { value.insert(.command) }
        if modifiers & UInt32(controlKey) != 0 { value.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { value.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { value.insert(.shift) }
        return value
    }
    var label: String {
        var prefix = ""
        for (bit, glyph) in [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")] {
            if modifiers & UInt32(bit) != 0 { prefix += glyph }
        }
        return prefix + Self.keys[keyCode, default: L10n.text("키 %@", String(describing: keyCode))]
    }
    var keyEquivalent: String { Self.keys[keyCode, default: ""].lowercased() }
    func matches(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        type == .keyDown && keyCode == Int64(self.keyCode) &&
            flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]) == eventFlags
    }
    func validationError(other: KeyboardShortcut) -> String? {
        guard Self.keys[keyCode] != nil, modifiers & ~Self.supported == 0, modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else {
            return L10n.text("⌘·⌥·⌃ 중 하나 이상과 다른 키를 함께 눌러주세요.")
        }
        guard self != other else { return L10n.text("차단·해제와 긴급 해제는 서로 다른 조합이어야 합니다.") }
        let common: [KeyboardShortcut] = [
            .init(keyCode: 12, modifiers: UInt32(cmdKey)), .init(keyCode: 48, modifiers: UInt32(cmdKey)),
            .init(keyCode: 53, modifiers: UInt32(cmdKey | optionKey)),
            .init(keyCode: 12, modifiers: UInt32(cmdKey | controlKey))
        ]
        if common.contains(self) { return L10n.text("macOS에서 사용하는 조합입니다. 다른 키를 지정해주세요.") }
        return nil
    }
    var usedBySystem: Bool {
        var hotKeys: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&hotKeys) == noErr, let entries = hotKeys?.takeRetainedValue() as? [[String: Any]] else { return false }
        return entries.contains { entry in
            entry[kHISymbolicHotKeyEnabled as String] as? Bool == true &&
            (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value == keyCode &&
            ((entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value ?? 0) & Self.supported == modifiers
        }
    }
    static let keys: [UInt32: String] = [
        0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",
        18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",36:"↩",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"⇥",49:"Space",50:"`",51:"⌫",53:"⎋",
        65:"Num .",67:"Num *",69:"Num +",71:"Clear",75:"Num /",76:"Num ↩",78:"Num -",81:"Num =",82:"Num 0",83:"Num 1",84:"Num 2",85:"Num 3",86:"Num 4",87:"Num 5",88:"Num 6",89:"Num 7",91:"Num 8",92:"Num 9",
        64:"F17",79:"F18",80:"F19",90:"F20",96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",103:"F11",105:"F13",106:"F16",107:"F14",109:"F10",111:"F12",113:"F15",114:"Help",115:"Home",116:"Page Up",117:"⌦",118:"F4",119:"End",120:"F2",121:"Page Down",122:"F1",123:"←",124:"→",125:"↓",126:"↑"
    ]
}

struct ShortcutPreferences {
    let normal: KeyboardShortcut
    let emergency: KeyboardShortcut
    init(defaults: UserDefaults = .standard) {
        self.init(normalData: defaults.data(forKey: "normalShortcut"),
                  emergencyData: defaults.data(forKey: "emergencyShortcut"))
    }
    init(normalData: Data? = nil, emergencyData: Data? = nil) {
        func read(_ data: Data?) -> KeyboardShortcut? {
            guard let data else { return nil }
            return try? JSONDecoder().decode(KeyboardShortcut.self, from: data)
        }
        let candidate = read(normalData) ?? .normal
        let rescue = read(emergencyData) ?? .emergency
        let sentinel = KeyboardShortcut(keyCode: 999, modifiers: 0)
        let safeNormal = candidate.validationError(other: sentinel) == nil ? candidate : .normal
        let safeEmergency = rescue.validationError(other: sentinel) == nil ? rescue : .emergency
        self.normal = safeNormal == safeEmergency ? .normal : safeNormal
        self.emergency = safeNormal == safeEmergency ? .emergency : safeEmergency
    }
    static func save(_ shortcut: KeyboardShortcut, emergency: Bool, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(shortcut) { defaults.set(data, forKey: emergency ? "emergencyShortcut" : "normalShortcut") }
    }
}
