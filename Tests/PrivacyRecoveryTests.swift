import Darwin
import XCTest
@testable import SoftLock

final class PrivacyRecoveryTests: XCTestCase {
    private final class Clock {
        let lock = NSLock()
        var value: TimeInterval = 0
        let accepted = DispatchSemaphore(value: 0)
        func read() -> TimeInterval {
            lock.lock(); let result = value; lock.unlock()
            if !Thread.isMainThread { accepted.signal() }
            return result
        }
        func expire() { lock.lock(); value = 3; lock.unlock() }
    }

    private func request(_ complete: @escaping (Result<Bool, Error>) -> Void,
                         authorizePeer: @escaping (pid_t, uid_t) -> Bool = { _, _ in true }) {
        DispatchQueue.global().async {
            complete(Result { try PrivacyRecoveryCommand.request(pid: getpid(), authorizePeer: authorizePeer) })
        }
    }

    private func connect() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try DeferredUpdateGate.address(DeferredUpdateGate.socketPath(pid: getpid()))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(fd); throw LidError("fixture connect failed") }
        return fd
    }
    private func send(_ text: String, to fd: Int32) {
        let data = Data(text.utf8)
        XCTAssertEqual(data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }, data.count)
    }

    func testRecoveryAcknowledgementStaysSeparateFromUpdateApproval() throws {
        let gate = DeferredUpdateGate(authorizeRecovery: { pid, uid in pid == getpid() && uid == getuid() })
        try gate.start(); defer { gate.stop() }
        var requests = 0
        gate.onRevealPrivacy = { XCTAssertTrue(Thread.isMainThread); requests += 1; return true }
        gate.onCommit = { XCTFail("Privacy reveal committed an update") }
        let done = expectation(description: "explicit privacy recovery")
        request { result in XCTAssertEqual(try? result.get(), true); done.fulfill() }
        wait(for: [done], timeout: 4)
        XCTAssertEqual(requests, 1); XCTAssertFalse(gate.pending); XCTAssertTrue(gate.available)
    }

    func testRecoveryWorksWhileAnUpdaterWaitsWithoutChangingItsPendingState() throws {
        let gate = DeferredUpdateGate(authorizeRecovery: { _, _ in true })
        try gate.start(); defer { gate.stop() }
        let updater = try connect(); defer { close(updater) }
        let pending = expectation(description: "updater waiting")
        gate.onChange = { if gate.pending { pending.fulfill() } }
        gate.onRevealPrivacy = { true }
        gate.onCommit = { XCTFail("Recovery must not commit the waiting update") }
        send("{\"command\":\"defer\",\"version\":\"0.7.99\"}\n", to: updater)
        wait(for: [pending], timeout: 2)
        gate.onChange = nil
        let recovered = expectation(description: "independent recovery")
        request { result in XCTAssertEqual(try? result.get(), true); recovered.fulfill() }
        wait(for: [recovered], timeout: 4)
        XCTAssertTrue(gate.pending); XCTAssertEqual(gate.version, "0.7.99")
    }

    func testInactiveOwnerReturnsNegativeAcknowledgementWithoutStateChange() throws {
        let gate = DeferredUpdateGate(authorizeRecovery: { _, _ in true })
        try gate.start(); defer { gate.stop() }
        gate.onRevealPrivacy = { false }
        let done = expectation(description: "not active")
        request { result in XCTAssertEqual(try? result.get(), false); done.fulfill() }
        wait(for: [done], timeout: 4)
        XCTAssertFalse(gate.pending)
    }

    func testBothServerAndClientRejectUnauthorizedPeers() throws {
        for serverAllows in [false, true] {
            let gate = DeferredUpdateGate(authorizeRecovery: { _, _ in serverAllows })
            try gate.start(); defer { gate.stop() }
            gate.onRevealPrivacy = { XCTFail("Untrusted recovery reached App owner"); return true }
            let done = expectation(description: "peer rejected")
            request({ result in
                if case .success = result { XCTFail("Unauthorized recovery succeeded") }
                done.fulfill()
            }, authorizePeer: { _, _ in !serverAllows })
            wait(for: [done], timeout: 4)
        }
    }

    func testQueuedRecoveryExpiresInsteadOfRevealingAfterClientWait() throws {
        let clock = Clock()
        let gate = DeferredUpdateGate(clock: clock.read, authorizeRecovery: { _, _ in true })
        try gate.start(); defer { gate.stop() }
        gate.onRevealPrivacy = { XCTFail("Expired request revealed a later screen"); return true }
        let done = expectation(description: "expired connection ends")
        request { result in
            if case .success = result { XCTFail("Expired request was acknowledged") }
            done.fulfill()
        }
        XCTAssertEqual(clock.accepted.wait(timeout: .now() + 2), .success)
        clock.expire()
        wait(for: [done], timeout: 4)
    }

    func testDisconnectedRecoveryCannotRevealAndStopRestartRejectsOldGeneration() throws {
        let clock = Clock()
        let gate = DeferredUpdateGate(clock: clock.read, authorizeRecovery: { _, _ in true })
        try gate.start(); defer { gate.stop() }
        var requests = 0; gate.onRevealPrivacy = { requests += 1; return true }
        let fd = try connect()
        send("{\"command\":\"reveal-privacy\"}\n", to: fd)
        XCTAssertEqual(clock.accepted.wait(timeout: .now() + 2), .success)
        close(fd)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(requests, 0)
        let stale = try connect()
        send("{\"command\":\"reveal-privacy\"}\n", to: stale)
        XCTAssertEqual(clock.accepted.wait(timeout: .now() + 2), .success)
        gate.stop(); try gate.start(); close(stale)
        let current = expectation(description: "new lifecycle recovers")
        request { result in XCTAssertEqual(try? result.get(), true); current.fulfill() }
        wait(for: [current], timeout: 4)
        XCTAssertEqual(requests, 1)
    }
}
