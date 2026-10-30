import XCTest
@testable import SoftLock

final class DisplayIdentificationTests: XCTestCase {
    private func display(_ id: UInt32, _ identity: String? = "A", name: String = "Monitor",
                         asleep: Bool = false, active: Bool = true, brightness: Float? = nil,
                         black: Bool = false) -> DisplayStatus {
        DisplayStatus(id: id, name: name, builtIn: false, asleep: asleep, active: active,
                      brightness: brightness, blackOutput: black, identity: identity)
    }
    func testSelectedMonitorGetsItsCurrentNameAndListNumber() {
        let selected = display(2)
        let result = DisplayIdentification.resolve(selected, current: [display(1, "B"), display(2, name: "Renamed")])
        XCTAssertEqual(result, DisplayIdentification(displayID: 2, identity: "A", name: "Renamed", number: 2))
        XCTAssertEqual(DisplayIdentification.resolve(selected, current: [display(2)])?.number, 1)
    }
    func testDisconnectedReusedOrAmbiguousIdentityCannotBeMarked() {
        let selected = display(2)
        XCTAssertNil(DisplayIdentification.resolve(selected, current: []))
        XCTAssertNil(DisplayIdentification.resolve(selected, current: [display(2, "B")]))
        XCTAssertNil(DisplayIdentification.resolve(selected, current: [display(3)]))
        XCTAssertNil(DisplayIdentification.resolve(selected, current: [display(2), display(3)]))
        XCTAssertNil(DisplayIdentification.resolve(display(2, nil), current: [display(2, nil)]))
    }
    func testInactiveDarkAndSleepingScreensAreNotWokenForIdentification() {
        let selected = display(2)
        for current in [display(2, asleep: true), display(2, active: false),
                        display(2, brightness: 0), display(2, black: true)] {
            XCTAssertNil(DisplayIdentification.resolve(selected, current: [current]))
        }
        XCTAssertNotNil(DisplayIdentification.resolve(selected, current: [display(2, brightness: nil)]))
    }
}
