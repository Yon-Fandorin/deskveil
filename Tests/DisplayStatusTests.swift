import XCTest
@testable import SoftLock

final class DisplayStatusTests: XCTestCase {
    private func status(asleep: Bool = false, active: Bool = true,
                        brightness: Float? = nil, black: Bool? = nil) -> DisplayStatus {
        DisplayStatus(id: 1, name: "Test", builtIn: false, asleep: asleep,
                      active: active, brightness: brightness, blackOutput: black)
    }

    func testZeroBrightnessDoesNotClaimPowerIsOff() {
        XCTAssertEqual(status(brightness: 0).label, L10n.text("최저 밝기"))
        XCTAssertEqual(status(brightness: 0).brightnessPercent, 0)
        XCTAssertEqual(status(brightness: nil).label, L10n.text("출력 활성"))
        XCTAssertNil(status(brightness: nil).brightnessPercent)
    }

    func testSleepAndInactiveTakePrecedenceOverBlackOutput() {
        XCTAssertEqual(status(asleep: true, brightness: 0, black: true).label, L10n.text("잠자기"))
        XCTAssertEqual(status(active: false, black: true).label, L10n.text("비활성"))
        XCTAssertEqual(status(black: true).label, L10n.text("검은 화면 출력"))
        XCTAssertEqual(status(black: false).label, L10n.text("출력 활성"))
    }

    func testBrightnessRejectsInvalidObservations() {
        for value: Float in [.nan, .infinity, -0.1, 1.1] {
            XCTAssertNil(status(brightness: value).brightnessPercent)
        }
        XCTAssertEqual(status(brightness: 0.644).brightnessPercent, 64)
    }
}
