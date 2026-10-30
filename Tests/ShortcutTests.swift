import XCTest
import Carbon
import CoreGraphics
@testable import SoftLock

final class ShortcutTests: XCTestCase {
    func testCustomChordRequiresExactModifiersButIgnoresCapsLock() {
        let shortcut = KeyboardShortcut(keyCode: 35, modifiers: UInt32(controlKey | optionKey))
        XCTAssertTrue(shortcut.matches(type: .keyDown, keyCode: 35, flags: [.maskControl,.maskAlternate,.maskAlphaShift]))
        XCTAssertFalse(shortcut.matches(type: .keyDown, keyCode: 35, flags: [.maskControl,.maskAlternate,.maskShift]))
        XCTAssertFalse(shortcut.matches(type: .keyUp, keyCode: 35, flags: shortcut.eventFlags))
        XCTAssertEqual(shortcut.label, "⌃⌥P")
    }
    func testBareTypingModifiersAndDuplicateBindingsAreRejected() {
        XCTAssertNotNil(KeyboardShortcut(keyCode: 0, modifiers: 0).validationError(other: .emergency))
        XCTAssertNotNil(KeyboardShortcut(keyCode: 0, modifiers: UInt32(shiftKey)).validationError(other: .emergency))
        XCTAssertNotNil(KeyboardShortcut(keyCode: 56, modifiers: UInt32(cmdKey)).validationError(other: .emergency))
        XCTAssertNotNil(KeyboardShortcut.emergency.validationError(other: .emergency))
        XCTAssertNotNil(KeyboardShortcut(keyCode: 12, modifiers: UInt32(cmdKey | controlKey)).validationError(other: .emergency))
    }
    func testBothCustomBindingsRoundTripEvenWhenNormalUsesOldEmergency() throws {
        let emergency = KeyboardShortcut(keyCode: 6, modifiers: UInt32(controlKey | shiftKey))
        let preferences = ShortcutPreferences(normalData: try JSONEncoder().encode(KeyboardShortcut.emergency),
                                              emergencyData: try JSONEncoder().encode(emergency))
        XCTAssertEqual(preferences.normal, .emergency)
        XCTAssertEqual(preferences.emergency, emergency)
    }
    func testBrokenAndConflictingPreferencesRecoverToSafeDefaults() throws {
        let data = try JSONEncoder().encode(KeyboardShortcut.normal)
        let preferences = ShortcutPreferences(normalData: data, emergencyData: data)
        XCTAssertEqual(preferences.normal, .normal)
        XCTAssertEqual(preferences.emergency, .emergency)
        XCTAssertEqual(ShortcutPreferences(normalData: Data("broken".utf8)).normal, .normal)
    }
    func testFailedHotkeyReplacementPreservesOldBindingAndRegistration() {
        var state = HotKeyRegistration()
        var removed: [UInt32] = []
        XCTAssertTrue(state.replace(.emergency, register: { _,_ in true }, remove: { removed.append($0) }))
        let id = state.activeID
        let candidate = KeyboardShortcut(keyCode: 6, modifiers: UInt32(controlKey | shiftKey))
        XCTAssertFalse(state.replace(candidate, register: { _,_ in false }, remove: { removed.append($0) }))
        XCTAssertEqual(state.shortcut, .emergency); XCTAssertEqual(state.activeID, id)
        XCTAssertTrue(removed.isEmpty)
    }
    func testOldCallbacksAndSuspendedHotkeysAreIgnored() {
        var state = HotKeyRegistration()
        _ = state.replace(.emergency, register: { _,_ in true }, remove: { _ in })
        let old = state.activeID!
        state.suspend { _ in }
        XCTAssertFalse(state.accepts(id: old))
        _ = state.resume(register: { _,_ in true }, remove: { _ in })
        XCTAssertFalse(state.accepts(id: old))
        XCTAssertTrue(state.accepts(id: state.activeID!))
    }
}
