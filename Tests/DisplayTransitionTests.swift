import XCTest
@testable import SoftLock

final class DisplayTransitionTests: XCTestCase {
    func testOldHideAndOldFadeCompletionCannotRemoveNewCover() {
        var session = CoverSession()
        _ = session.apply(CoverCommand(action: "show", id: 1))
        _ = session.apply(CoverCommand(action: "hide", id: 2))
        _ = session.apply(CoverCommand(action: "show", id: 3))
        XCTAssertFalse(session.didHide(id: 2))
        XCTAssertFalse(session.apply(CoverCommand(action: "hide", id: 2)))
        XCTAssertEqual(session.state, "covered")
    }
}
