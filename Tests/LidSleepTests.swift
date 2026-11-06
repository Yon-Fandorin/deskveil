import Darwin
import XCTest
@testable import SoftLock

final class LidSleepTests: XCTestCase {
    func testSocketDisconnectRetriesWithoutReportingSessionLoss() throws {
        try withConnectionServer(connections: 2, reply: { attempt, peer in
            if attempt == 2 { try lidWriteLine(peer, ["protocol": LidPaths.protocolVersion, "phase": "active", "session": "same"]) }
        }) { connection in
            let state = try connection.exchange(["session": "same"])
            XCTAssertEqual(state["phase"] as? String, "active")
            let diagnostic = try XCTUnwrap(connection.lastExchangeDiagnostics)
            XCTAssertEqual(diagnostic["recovered"] as? Bool, true)
            let failure = try XCTUnwrap((diagnostic["failures"] as? [[String: Any]])?.first)
            XCTAssertEqual(failure["code"] as? Int, Int(ECONNRESET))
            XCTAssertEqual(failure["operation"] as? String, "read")
        }
    }

    func testTimedOutReplyCanReconnectWithinOneBoundedExchange() throws {
        try withConnectionServer(connections: 2, timeout: 1, reply: { attempt, peer in
            if attempt == 1 { usleep(550_000) }
            else { try lidWriteLine(peer, ["protocol": LidPaths.protocolVersion, "phase": "active"]) }
        }) { connection in
            let began = lidTime()
            XCTAssertEqual(try connection.exchange([:])["phase"] as? String, "active")
            XCTAssertLessThan(lidTime() - began, 1.2)
            let diagnostic = try XCTUnwrap(connection.lastExchangeDiagnostics)
            XCTAssertEqual(diagnostic["recovered"] as? Bool, true)
            XCTAssertEqual((diagnostic["failures"] as? [[String: Any]])?.first?["code"] as? Int, Int(ETIMEDOUT))
        }
    }

    func testProtocolAndPeerFailuresAreNotRetried() throws {
        try withConnectionServer(connections: 1, reply: { _, peer in
            try lidWriteLine(peer, ["protocol": LidPaths.protocolVersion + 1])
        }) { connection in
            XCTAssertThrowsError(try connection.exchange([:]))
            XCTAssertEqual((connection.lastExchangeDiagnostics?["failures"] as? [[String: Any]])?.count, 1)
            XCTAssertEqual(connection.lastExchangeDiagnostics?["recovered"] as? Bool, false)
        }
        try withConnectionServer(connections: 1, peerUID: getuid() + 1, reply: { _, _ in
            XCTFail("An untrusted server received a request")
        }) { connection in
            XCTAssertThrowsError(try connection.exchange([:]))
            XCTAssertEqual((connection.lastExchangeDiagnostics?["failures"] as? [[String: Any]])?.count, 1)
        }
    }

    func testRepeatedDisconnectStopsAfterTwoAttemptsWithErrorDetails() throws {
        try withConnectionServer(connections: 2, reply: { _, _ in }) { connection in
            XCTAssertThrowsError(try connection.exchange([:]))
            let diagnostic = try XCTUnwrap(connection.lastExchangeDiagnostics)
            XCTAssertEqual(diagnostic["recovered"] as? Bool, false)
            XCTAssertEqual((diagnostic["failures"] as? [[String: Any]])?.count, 2)
        }
    }

    func testRepeatedReplyTimeoutsShareOneDeadline() throws {
        try withConnectionServer(connections: 2, timeout: 0.6, reply: { _, _ in usleep(350_000) }) { connection in
            let began = lidTime()
            XCTAssertThrowsError(try connection.exchange([:]))
            XCTAssertLessThan(lidTime() - began, 0.8)
            XCTAssertEqual((connection.lastExchangeDiagnostics?["failures"] as? [[String: Any]])?.count, 2)
        }
    }

    func testSignalDuringSocketWaitDoesNotEndTheExchange() throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { descriptors.forEach { close($0) } }
        let previous = signal(SIGUSR1, { _ in })
        defer { _ = signal(SIGUSR1, previous) }
        let waiter = pthread_self(), writer = descriptors[1]
        let sent = expectation(description: "signal followed by socket readiness")
        DispatchQueue.global().async {
            usleep(20_000)
            pthread_kill(waiter, SIGUSR1)
            usleep(20_000)
            var byte: UInt8 = 10
            _ = write(writer, &byte, 1)
            sent.fulfill()
        }
        try lidWaitForSocket(descriptors[0], events: Int16(POLLIN), deadline: lidTime() + 1, operation: "read")
        wait(for: [sent], timeout: 1)
    }

    func testNonblockingSocketWriteWaitsForBufferSpace() throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { descriptors.forEach { close($0) } }
        let writer = descriptors[0], reader = descriptors[1]
        XCTAssertEqual(fcntl(writer, F_SETFL, O_NONBLOCK), 0)
        var bufferSize: Int32 = 1024
        XCTAssertEqual(setsockopt(writer, SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size)), 0)
        var fill = [UInt8](repeating: 32, count: 1024), filled = 0
        while true {
            let count = write(writer, &fill, fill.count)
            if count < 0 { XCTAssertEqual(errno, EAGAIN); break }
            filled += count
        }
        let message: [String: Any] = ["protocol": LidPaths.protocolVersion]
        let expected = filled + (try JSONSerialization.data(withJSONObject: message).count) + 1
        let drained = expectation(description: "socket buffer drained")
        DispatchQueue.global().async {
            usleep(50_000)
            var bytes = [UInt8](repeating: 0, count: 1024), received = 0
            do {
                while received < expected {
                    try lidWaitForSocket(reader, events: Int16(POLLIN), deadline: lidTime() + 1, operation: "fixture-drain")
                    let count = read(reader, &bytes, bytes.count)
                    guard count > 0 else { throw lidSocketError("fixture-drain") }
                    received += count
                }
            } catch { XCTFail("Socket drain failed: \(error)") }
            drained.fulfill()
        }
        try lidWriteLine(writer, message, deadline: lidTime() + 1)
        wait(for: [drained], timeout: 2)
    }

    func testMissingServiceRetriesWithinBudget() {
        let connection = LidConnection(path: "/nonexistent/deskveil.sock", timeout: 0.2)
        XCTAssertThrowsError(try connection.exchange([:]))
        XCTAssertEqual((connection.lastExchangeDiagnostics?["failures"] as? [[String: Any]])?.count, 2)
    }

    func testConnectionFailureIsJournaledWithSessionAndOriginalError() {
        let logged = expectation(description: "original transport failure recorded")
        let controller = LidSleepController(installed: { true }, context: { [:] }, exchange: { _ in
            throw lidSocketError("read", code: ETIMEDOUT)
        }, recoveryPending: { false })
        controller.onConnectionEvent = { event in
            XCTAssertEqual(event["recovered"] as? Bool, false)
            XCTAssertEqual(event["requested"] as? Bool, true)
            XCTAssertFalse((event["session"] as? String ?? "").isEmpty)
            let failure = (event["failures"] as? [[String: Any]])?.first
            XCTAssertEqual(failure?["domain"] as? String, NSPOSIXErrorDomain)
            XCTAssertEqual(failure?["code"] as? Int, Int(ETIMEDOUT))
            XCTAssertEqual(failure?["operation"] as? String, "read")
            logged.fulfill()
        }
        controller.prepare { result in
            guard case .failure(let error) = result else { XCTFail("Failed transport completed preparation"); return }
            XCTAssertEqual(error.localizedDescription, L10n.text("전원 보조 도구 응답이 지연되고 있습니다."))
        }
        controller.update(requested: false, locked: false, ready: true, awake: false, durationSeconds: 0)
        wait(for: [logged], timeout: 2)
        XCTAssertFalse(controller.lastConnectionEvent.isEmpty)
    }

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

    private func withConnectionServer(connections: Int, timeout: TimeInterval = 1, peerUID: uid_t? = nil,
                                      reply: @escaping (Int, Int32) throws -> Void,
                                      test: (LidConnection) throws -> Void) throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("lid-client-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("control.sock").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw lidSocketError("fixture-socket") }
        defer { close(listener) }
        var address = try lidSocketAddress(path)
        guard lidWithAddress(&address, { Darwin.bind(listener, $0, $1) }) == 0, listen(listener, 4) == 0 else {
            throw lidSocketError("fixture-bind")
        }
        let served = expectation(description: "native socket fixture completed")
        DispatchQueue.global().async {
            defer { served.fulfill() }
            for attempt in 1...connections {
                do {
                    try lidWaitForSocket(listener, events: Int16(POLLIN), deadline: lidTime() + 2, operation: "fixture-accept")
                    let peer = accept(listener, nil, nil)
                    guard peer >= 0 else { throw lidSocketError("fixture-accept") }
                    defer { close(peer) }
                    var request = Data(), bytes = [UInt8](repeating: 0, count: 1024)
                    while !request.contains(10) {
                        try lidWaitForSocket(peer, events: Int16(POLLIN), deadline: lidTime() + 2, operation: "fixture-read")
                        let count = read(peer, &bytes, bytes.count)
                        if count == 0 { return }
                        guard count > 0 else { throw lidSocketError("fixture-read") }
                        request.append(contentsOf: bytes.prefix(count))
                    }
                    try reply(attempt, peer)
                } catch { XCTFail("Native socket fixture failed: \(error)"); return }
            }
        }
        defer { wait(for: [served], timeout: 3) }
        try test(LidConnection(path: path, peerUID: peerUID ?? getuid(), timeout: timeout))
    }
}
