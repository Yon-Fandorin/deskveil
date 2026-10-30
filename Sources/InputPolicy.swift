import CoreGraphics

/// Event metadata is a compatibility heuristic, not authentication.
enum InputPolicy {
    // Quartz's DockControl (30), paired gesture markers (29), and gesture
    // variants are private event types. See docs/engineering.md.
    static let gestureTypes: Set<UInt32> = [18, 19, 20, 28, 29, 30, 31, 32, 33, 34, 37, 38]
    static let eventTypes: [UInt32] = [1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 14, 22, 23, 24, 25, 26, 27]
        + gestureTypes.sorted()
    static let eventMask = eventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) }

    static func isPhysical(sourceState: Int64, processID: Int64) -> Bool {
        sourceState == CGEventSourceStateID.hidSystemState.rawValue && processID == 0
    }

    static func isPhysical(_ event: CGEvent) -> Bool {
        isPhysical(sourceState: event.getIntegerValueField(.eventSourceStateID),
                   processID: event.getIntegerValueField(.eventSourceUnixProcessID))
    }

    static func matchesShortcut(type: CGEventType, keyCode: Int64,
                                flags: CGEventFlags, expectedKey: Int64) -> Bool {
        let relevant: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        let expected: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
        return type == .keyDown && keyCode == expectedKey
            && flags.intersection(relevant) == expected
    }
}
