import XCTest
@testable import SoftLock

final class LidSleepTests: XCTestCase {
    func testImmediateRetryClearsFailedServiceScopeBeforePreparingAgain() {
        let failed = expectation(description: "initial preparation refused")
        let succeeded = expectation(description: "immediate fresh preparation succeeded")
        var phase = "idle", requests: [Bool] = [], first = true
        let controller = LidSleepController(installed: { true }, context: { [:] }, exchange: { message in
            let requested = message["requested"] as? Bool == true
            requests.append(requested)
            if !requested { phase = "idle" }
            else if first { first = false; phase = "failed" }
            else if phase == "idle" { phase = "active" }
            return ["phase": phase, "session": message["session"]!, "reason": phase == "failed" ? "power-required" : ""]
        }, recoveryPending: { false })
        func update() { controller.update(requested: false, locked: false, ready: true, awake: false, durationSeconds: 0) }
        controller.onPreparationUpdate = { update() }
        controller.prepare { result in
            if case .success = result { XCTFail("First preparation must fail") }; failed.fulfill()
        }
        update(); wait(for: [failed], timeout: 2)
        controller.prepare { result in
            if case .failure(let error) = result { XCTFail("Old failure leaked into retry: \(error)") }; succeeded.fulfill()
        }
        update(); wait(for: [succeeded], timeout: 2)
        XCTAssertEqual(requests, [true, false, true])
        XCTAssertTrue(controller.active)
        controller.onPreparationUpdate = nil
    }
    func testReadOnlyIdleQueryDoesNotPreventIdleAdmission() {
        let sent = expectation(description: "read-only query in flight")
        let replied = expectation(description: "read-only query completed")
        let release = DispatchSemaphore(value: 0)
        let controller = LidSleepController(installed: { true }, context: { [:] }, exchange: { message in
            XCTAssertEqual(message["requested"] as? Bool, false)
            sent.fulfill()
            guard release.wait(timeout: .now() + 2) == .success else { throw LidError("Fixture timeout") }
            return ["phase": "idle"]
        }, recoveryPending: { false })
        controller.onChange = { replied.fulfill() }
        controller.update(requested: false, locked: false, ready: true, awake: false, durationSeconds: 0)
        wait(for: [sent], timeout: 2)
        XCTAssertTrue(controller.settled, "A status-only exchange cannot create power ownership")
        release.signal()
        wait(for: [replied], timeout: 2)
        XCTAssertTrue(controller.settled)
        controller.onChange = nil
    }

    func testCancelledInFlightPreparationIsNotSettledUntilScopeEndingAck() {
        let sent = expectation(description: "mutating preparation outstanding")
        let activated = expectation(description: "old preparation response arrived")
        let restored = expectation(description: "scope-ending response acknowledged")
        let release = DispatchSemaphore(value: 0)
        var exchanges = 0
        let controller = LidSleepController(installed: { true }, context: { [:] }, exchange: { message in
            exchanges += 1
            if exchanges == 1 {
                XCTAssertEqual(message["requested"] as? Bool, true)
                sent.fulfill()
                guard release.wait(timeout: .now() + 2) == .success else { throw LidError("Fixture timeout") }
                return ["phase": "active", "session": message["session"]!]
            }
            XCTAssertEqual(message["requested"] as? Bool, false)
            return ["phase": "idle", "session": message["session"]!]
        }, recoveryPending: { false })
        controller.onChange = {
            if controller.active { activated.fulfill() }
            if controller.settled && exchanges > 1 { restored.fulfill() }
        }
        controller.prepare { _ in XCTFail("Cancelled preparation completed") }
        controller.update(requested: false, locked: false, ready: true, awake: false, durationSeconds: 0)
        wait(for: [sent], timeout: 2)
        controller.cancelPreparation()
        XCTAssertFalse(controller.busy)
        XCTAssertFalse(controller.settled, "No receipt yet does not prove an outstanding mutation is safe")
        release.signal()
        wait(for: [activated], timeout: 2)
        XCTAssertFalse(controller.settled)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            controller.update(requested: false, locked: false, ready: true, awake: false, durationSeconds: 0)
        }
        wait(for: [restored], timeout: 2)
        XCTAssertTrue(controller.settled)
        controller.onChange = nil
    }

    func testOldPreparationAndIdleFailuresCannotCompleteANewerPreparation() {
        for transportFailure in [false, true] {
            let sent = expectation(description: "old exchange sent")
            let completed = expectation(description: "new preparation succeeded")
            let release = DispatchSemaphore(value: 0)
            var exchanges = 0
            let controller = LidSleepController(installed: { true }, context: { [:] }, exchange: { message in
                exchanges += 1
                if exchanges == 1 {
                    sent.fulfill()
                    guard release.wait(timeout: .now() + 2) == .success else { throw LidError("Test timed out") }
                    if transportFailure { throw LidError("Old connection failed") }
                    return ["phase": "failed", "reason": "session-not-ready"]
                }
                if message["requested"] as? Bool == false { return ["phase": "idle", "session": message["session"]!] }
                return ["phase": "active", "session": message["session"]!]
            })
            func update() {
                controller.update(requested: false, locked: false, ready: true, awake: false, durationSeconds: 0)
            }
            controller.onPreparationUpdate = { update() }
            if !transportFailure { controller.prepare { _ in XCTFail("Canceled preparation completed") } }
            update()
            wait(for: [sent], timeout: 2)
            controller.cancelPreparation()
            controller.prepare { result in
                if case .failure(let error) = result { XCTFail("Old failure completed the new request: \(error)") }
                completed.fulfill()
            }
            release.signal()
            wait(for: [completed], timeout: 2)
            XCTAssertEqual(exchanges, transportFailure ? 2 : 3, "Outstanding mutating scopes must be released before a fresh preparation")
            XCTAssertTrue(controller.active)
            controller.onPreparationUpdate = nil
        }
    }
}
