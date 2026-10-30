import XCTest
@testable import SoftLock

final class DisplayBrightnessTests: XCTestCase {
    private let a = DisplayBrightnessTarget(displayID: 1, identity: "A")
    private let b = DisplayBrightnessTarget(displayID: 2, identity: "B")
    private func reply(_ target: DisplayBrightnessTarget, _ value: Float?, id: UInt64) -> GuardianReply {
        GuardianReply(message: DisplayBrightnessObservation(target: target, value: value).message!, id: id)
    }
    func testReadOnlyWireAndInvalidPayloads() {
        XCTAssertEqual(DisplayBrightnessTarget(payload: String(a.wire!.dropFirst("brightness-status:".count))), a)
        XCTAssertNil(DisplayBrightnessTarget(displayID: 0, identity: "A").wire)
        XCTAssertNil(DisplayBrightnessTarget(payload: "not-base64"))
        XCTAssertNil(DisplayBrightnessObservation(target: a, value: .nan).message)
        XCTAssertNil(DisplayBrightnessObservation(target: a, value: 1.1).message)
    }
    func testFreshValuesAreScopedAndExpireWithoutGuessing() throws {
        var state = DisplayBrightnessReadings()
        let request = try XCTUnwrap(state.begin([a, b], at: 0))
        XCTAssertNil(state.begin([a, b], at: 0.1))
        XCTAssertTrue(state.receive(reply(request.target, 0.9, id: request.id), at: 0.2))
        XCTAssertEqual(state.value(for: request.target, at: 1), 0.9)
        XCTAssertNil(state.value(for: request.target, at: 5.3))
        let reusedID = DisplayBrightnessTarget(displayID: request.target.displayID, identity: "replacement")
        XCTAssertNil(state.value(for: reusedID, at: 1))
        let next = try XCTUnwrap(state.begin([a, b], at: 0.3))
        XCTAssertNotEqual(next.target, request.target)
    }
    func testDisconnectAndInvalidationRejectOldResponses() throws {
        var state = DisplayBrightnessReadings()
        let old = try XCTUnwrap(state.begin([a], at: 0))
        let next = try XCTUnwrap(state.begin([b], at: 0.1))
        XCTAssertFalse(state.receive(reply(a, 0.9, id: old.id), at: 0.2))
        XCTAssertTrue(state.receive(reply(b, 0.5, id: next.id), at: 0.2))
        state.invalidate()
        XCTAssertNil(state.value(for: b, at: 0.3))
        let current = try XCTUnwrap(state.begin([b], at: 0.3))
        XCTAssertNotEqual(current.id, next.id)
        XCTAssertFalse(state.receive(reply(b, 0.5, id: next.id), at: 0.4))
    }
    func testChangingOneDisplayPreservesOtherReadingsAndInFlightQuery() throws {
        var state = DisplayBrightnessReadings()
        let first = try XCTUnwrap(state.begin([a], at: 0))
        XCTAssertTrue(state.receive(reply(a, 0.8, id: first.id), at: 0.1))
        let second = try XCTUnwrap(state.begin([a, b], at: 0.2))
        XCTAssertTrue(state.receive(reply(b, 0.6, id: second.id), at: 0.3))
        let refreshing = try XCTUnwrap(state.begin([a, b], at: 3))
        XCTAssertEqual(refreshing.target, a)
        state.invalidate(b)
        XCTAssertEqual(state.value(for: a, at: 3.1), 0.8)
        XCTAssertNil(state.value(for: b, at: 3.1))
        XCTAssertEqual(state.pending?.id, refreshing.id)
        XCTAssertTrue(state.receive(reply(a, 0.7, id: refreshing.id), at: 3.2))
        XCTAssertEqual(state.begin([a, b], at: 3.3)?.target, b, "Changed display retries without clearing another monitor")
    }
    func testChangedDisplayRejectsPreMutationReplyWithoutClearingAnotherSample() throws {
        var state = DisplayBrightnessReadings()
        let first = try XCTUnwrap(state.begin([b], at: 0))
        XCTAssertTrue(state.receive(reply(b, 0.6, id: first.id), at: 0.1))
        let old = try XCTUnwrap(state.begin([a, b], at: 0.2))
        state.invalidate(a)
        XCTAssertNil(state.pending)
        XCTAssertFalse(state.receive(reply(a, 0.9, id: old.id), at: 0.3))
        XCTAssertEqual(state.value(for: b, at: 0.3), 0.6)
        let fresh = try XCTUnwrap(state.begin([a, b], at: 0.4))
        XCTAssertNotEqual(fresh.id, old.id)
        XCTAssertFalse(state.receive(reply(a, 0.9, id: old.id), at: 0.5))
        XCTAssertTrue(state.receive(reply(a, 0, id: fresh.id), at: 0.6))
        XCTAssertEqual(state.value(for: a, at: 0.7), 0)
    }
    func testFailedAndTimedOutQueriesBackOffAndCanRetry() throws {
        var state = DisplayBrightnessReadings()
        let first = try XCTUnwrap(state.begin([a], at: 0))
        XCTAssertTrue(state.receive(reply(a, nil, id: first.id), at: 0.1))
        XCTAssertNil(state.begin([a], at: 3))
        let second = try XCTUnwrap(state.begin([a], at: 10))
        XCTAssertNil(state.begin([a], at: 14.1))
        XCTAssertFalse(state.receive(reply(a, 0.9, id: second.id), at: 14.2))
        XCTAssertNotNil(state.begin([a], at: 20))
    }
    func testReceiveExpiresMatchingRequestWithoutAnotherPoll() throws {
        for time: TimeInterval in [4, 10, -0.1, .nan, .infinity] {
            var state = DisplayBrightnessReadings()
            let request = try XCTUnwrap(state.begin([a], at: 0))
            XCTAssertFalse(state.receive(reply(a, 0.9, id: request.id), at: time))
            XCTAssertNil(state.pending)
            XCTAssertNil(state.value(for: a, at: 10))
        }
        var state = DisplayBrightnessReadings()
        let request = try XCTUnwrap(state.begin([a], at: 0))
        XCTAssertFalse(state.receive(reply(a, 0.9, id: request.id + 1), at: 10))
        XCTAssertEqual(state.pending?.id, request.id, "Unrelated replies cannot complete the current request")
        XCTAssertFalse(state.receive(reply(a, 0.9, id: request.id), at: 10))
    }
    func testReadCannotWriteOrUseReassignedDisplayID() {
        var reads: [UInt32] = [], writes = 0
        let brightness = NativeBrightness(displays: { [1, 2] }, read: { reads.append($0); return 0.9 },
            write: { _, _ in writes += 1; return true }, identity: { $0 == 1 ? "A" : "B" })
        XCTAssertNil(brightness.observedBrightness(display: 2, identity: "A"))
        XCTAssertTrue(reads.isEmpty)
        XCTAssertEqual(brightness.observedBrightness(display: 1, identity: "A"), 0.9)
        XCTAssertEqual(reads, [1])
        XCTAssertEqual(writes, 0)
        XCTAssertFalse(brightness.hasPendingRestore)
    }
    func testFallbackPreservesNativeAndInactiveObservations() {
        let display = DisplayStatus(id: 2, name: "External", builtIn: false, asleep: false,
            active: true, brightness: nil, blackOutput: false, identity: "A")
        XCTAssertEqual(display.withFallbackBrightness(0.9).brightnessPercent, 90)
        XCTAssertEqual(display.withFallbackBrightness(0.9).withFallbackBrightness(0.5).brightnessPercent, 90)
        let asleep = DisplayStatus(id: 2, name: "External", builtIn: false, asleep: true,
            active: true, brightness: nil, blackOutput: nil, identity: "A")
        XCTAssertNil(asleep.withFallbackBrightness(0.9).brightness)
        XCTAssertNil(display.withFallbackBrightness(.nan).brightness)
    }
}
