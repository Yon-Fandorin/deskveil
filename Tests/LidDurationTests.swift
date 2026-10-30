import XCTest
@testable import SoftLock

final class LidDurationTests: XCTestCase {
    func testDurationRequiresExplicitNumericUnlimitedOrWholeHours() {
        for invalid: Any in [true, "0", -1, 0.5, 3599, 3601, Double.infinity, Double.nan, 8761 * 3600] {
            XCTAssertNil(LidDuration.seconds(from: invalid), "\(invalid)")
        }
        XCTAssertNil(LidDuration.seconds(from: nil))
        XCTAssertEqual(LidDuration.seconds(from: 0), 0)
        XCTAssertEqual(LidDuration.seconds(from: 36 * 3600), 36 * 3600)
        XCTAssertEqual(LidDuration.seconds(from: 8760 * 3600), 8760 * 3600)
    }
}
