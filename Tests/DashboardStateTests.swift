import XCTest
@testable import SoftLock

final class DashboardStateTests: XCTestCase {
    private func state() -> MenuDashboardState {
        MenuDashboardState(displays: [], locked: false, awake: false, dimming: false, issue: nil)
    }

    func testEnabledSleepPreventionWaitsForSessionInsteadOfClaimingDisabled() {
        var value = state()
        value.awakeEnabled = true
        XCTAssertEqual(value.awakeLabel, L10n.text("잠자기 방지 대기"))
        value.locked = true
        XCTAssertEqual(value.awakeLabel, L10n.text("잠자기 방지 중단"))
        value.awake = true
        XCTAssertEqual(value.awakeLabel, L10n.text("잠자기 방지 중"))
        value.awake = false
        value.awakeEnabled = false
        XCTAssertEqual(value.awakeLabel, L10n.text("잠자기 방지 사용 안 함"))
    }

    func testRequestedBlockingDoesNotClaimSuccessWhenTapIsUnavailable() {
        var value = state()
        value.locked = true
        value.inputBlocking = true
        XCTAssertEqual(value.inputStatus, .blocked)
        value.inputAvailable = false
        XCTAssertEqual(value.inputStatus, .interrupted)
        value.locked = false
        value.inputBlocking = false
        XCTAssertEqual(value.inputStatus, .unavailable)
        value.inputAvailable = true
        XCTAssertEqual(value.inputStatus, .released)
    }

    func testActualFilterSnapshotWinsOverSessionIntent() {
        var value = state()
        value.locked = true
        value.inputBlocking = false
        XCTAssertEqual(value.inputStatus, .interrupted)
        value.locked = false
        value.inputBlocking = true
        XCTAssertEqual(value.inputStatus, .blocked)
    }
}
