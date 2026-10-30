import XCTest
@testable import SoftLock

final class OperationRepliesTests: XCTestCase {
    func testOldRestoreAndErrorsCannotCompleteAnotherRestore() {
        var gate = OperationReplies()
        let old = gate.begin(.restore); let current = gate.begin(.restore)
        XCTAssertFalse(gate.finish(.restore, id: old))
        XCTAssertTrue(gate.accepts(.restore, id: current))
        XCTAssertTrue(gate.finish(.restore, id: current))
        XCTAssertFalse(gate.accepts(.restore, id: current))
    }
    func testCoverAcknowledgementAndDimReplyHaveSeparateOwners() {
        var gate = OperationReplies()
        let dim = gate.begin(.dim), cover = gate.begin(.cover)
        XCTAssertTrue(gate.accepts(.dim, id: dim))
        XCTAssertTrue(gate.accepts(.cover, id: cover))
        gate.cancelAll()
        XCTAssertFalse(gate.accepts(.cover, id: cover))
        let new = gate.begin(.cover)
        XCTAssertGreaterThan(new, cover)
    }
    func testEachOperationRetainsItsReplyUntilItsOwnerCompletesOrCancels() {
        var gate = OperationReplies()
        var replies: [OperationReplies.Operation: UInt64] = [:]
        for operation in OperationReplies.Operation.allCases { replies[operation] = gate.begin(operation) }
        XCTAssertEqual(Set(replies.values).count, replies.count)
        for (operation, id) in replies {
            XCTAssertEqual(gate.current(operation), id)
            for other in OperationReplies.Operation.allCases where other != operation {
                XCTAssertFalse(gate.accepts(other, id: id))
            }
        }
        gate.cancel(.failureCover)
        XCTAssertNil(gate.current(.failureCover))
        for (operation, id) in replies where operation != .failureCover {
            XCTAssertTrue(gate.finish(operation, id: id))
        }
    }
}
