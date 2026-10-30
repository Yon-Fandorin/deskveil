import Darwin
import XCTest
@testable import SoftLock

final class DeferredUpdateTests: XCTestCase {
    func testCommitQueuedBeyondItsLeaseResumesOwnerInsteadOfTerminatingLate() throws {
        let accepted = DispatchSemaphore(value: 0)
        let sendCommit = DispatchSemaphore(value: 0)
        let gate = DeferredUpdateGate(commitLease: 0.02, clock: {
            if !Thread.isMainThread { accepted.signal() }
            return ProcessInfo.processInfo.systemUptime
        })
        try gate.start(); defer { gate.stop() }
        let prepared = expectation(description: "owner prepared")
        let resumed = expectation(description: "expired commit resumes owner")
        let disconnected = expectation(description: "expired commit closes peer")
        gate.onCommit = { XCTFail("A late commit must not terminate after updater leaves") }
        gate.onDisconnect = { resumed.fulfill() }
        gate.onChange = {
            if gate.pending { gate.finish { ok in XCTAssertTrue(ok); prepared.fulfill() } }
        }
        DispatchQueue.global().async {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0); defer { close(fd) }
            var address = try! DeferredUpdateGate.address(DeferredUpdateGate.socketPath(pid: getpid()))
            XCTAssertEqual(withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }, 0)
            let wire = Data("{\"command\":\"defer\",\"version\":\"0.7.99\"}\n".utf8)
            _ = wire.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            var buffer = Data()
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while ProcessInfo.processInfo.systemUptime < deadline {
                var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&pollFD, 1, 100) > 0 else { continue }
                var bytes = [UInt8](repeating: 0, count: 1024)
                let count = read(fd, &bytes, bytes.count)
                guard count > 0 else { break }
                buffer.append(contentsOf: bytes.prefix(count))
                if String(decoding: buffer, as: UTF8.self).contains("\"ready\"") {
                    guard sendCommit.wait(timeout: .now() + 2) == .success else {
                        return XCTFail("Main did not finish preparation before commit")
                    }
                    let commit = Data("{\"command\":\"commit\"}\n".utf8)
                    _ = commit.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                    var closing = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    XCTAssertGreaterThan(poll(&closing, 1, 2000), 0)
                    XCTAssertEqual(read(fd, &bytes, bytes.count), 0)
                    disconnected.fulfill(); return
                }
            }
            XCTFail("No preparation received")
        }
        wait(for: [prepared], timeout: 2)
        sendCommit.signal()
        XCTAssertEqual(accepted.wait(timeout: .now() + 2), .success)
        Thread.sleep(forTimeInterval: 0.08) // Deliberately stall only this test's Main.
        wait(for: [resumed, disconnected], timeout: 3)
        XCTAssertFalse(gate.pending)
    }
    func testStaleSocketFromExitedProcessCanBeReplaced() throws {
        try FileManager.default.createDirectory(atPath: DeferredUpdateGate.directory,
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try DeferredUpdateGate.address(DeferredUpdateGate.socketPath(pid: getpid()))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(fd)
        XCTAssertEqual(bound, 0)
        let gate = DeferredUpdateGate()
        try gate.start()
        XCTAssertTrue(gate.available)
        gate.stop()
    }

    func testEveryActiveScopeDefersReplacementIncludingCombinedScopes() {
        for mask in 0..<128 {
            let value = UpdateReadiness(blocking: mask & 1 != 0, recording: mask & 2 != 0,
                transitioning: mask & 4 != 0, recovering: mask & 8 != 0,
                individualDisplays: mask & 16 != 0, lidBusy: mask & 32 != 0, stopping: mask & 64 != 0)
            XCTAssertEqual(value.waitingReason == nil, mask == 0, "Unsafe update admission mask \(mask)")
        }
    }

    func testLiveRendezvousWaitsUntilOwnerExplicitlyApprovesWithoutInputOrPower() throws {
        let gate = DeferredUpdateGate()
        try gate.start()
        defer { gate.stop() }
        let pending = expectation(description: "pending request on main")
        let ready = expectation(description: "ready received")
        let sent = expectation(description: "ready sent")
        let committed = expectation(description: "explicit commit received")
        let renewed = expectation(description: "prepared lease renewed without commit")
        gate.onRenew = { renewed.fulfill() }
        gate.onCommit = { committed.fulfill() }
        gate.onChange = {
            guard gate.pending else { return }
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(gate.version, "0.7.99")
            gate.reportWaiting(UpdateReadiness(blocking: true).waitingReason!)
            pending.fulfill()
        }
        DispatchQueue.global().async {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(fd) }
            var address = try! DeferredUpdateGate.address(DeferredUpdateGate.socketPath(pid: getpid()))
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            XCTAssertEqual(connected, 0)
            let wire = Data("{\"command\":\"defer\",\"version\":\"0.7.99\"}\n".utf8)
            XCTAssertEqual(wire.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }, wire.count)
            var buffer = Data()
            var sawWaiting = false, sawReady = false
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !sawReady && ProcessInfo.processInfo.systemUptime < deadline {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 100) > 0 else { continue }
                var bytes = [UInt8](repeating: 0, count: 1024)
                let count = read(fd, &bytes, bytes.count)
                guard count > 0 else { break }
                buffer.append(contentsOf: bytes.prefix(count))
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer[..<newline]; buffer.removeSubrange(...newline)
                    let response = try! JSONSerialization.jsonObject(with: line) as! [String: Any]
                    if response["state"] as? String == "waiting" { sawWaiting = true }
                    if response["state"] as? String == "ready" { sawReady = true }
                }
            }
            XCTAssertTrue(sawWaiting); XCTAssertTrue(sawReady)
            let commit = Data("{\"command\":\"renew\"}\n{\"command\":\"commit\"}\n".utf8)
            XCTAssertEqual(commit.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }, commit.count)
            ready.fulfill()
        }
        wait(for: [pending], timeout: 2)
        XCTAssertTrue(gate.pending)
        gate.finish { success in XCTAssertTrue(success); sent.fulfill() }
        wait(for: [sent, ready, renewed, committed], timeout: 3)
    }

    func testHistoryDistinguishesFailureReasonsWithoutRecordingInput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = SessionHistory(directory: directory)
        history.started(source: "shortcut")
        history.ended(.secureInput, tapEnabled: true, secureInput: true, macOSState: "unlocked")
        XCTAssertEqual(history.lastEnd["reason"], "secureInput")
        history.ended(.tapUnavailable, tapEnabled: false, secureInput: false, macOSState: "unlocked", requestedReason: .lidLimit)
        XCTAssertTrue(history.flush())
        let rows = try String(contentsOf: directory.appendingPathComponent("application-session.jsonl"))
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1]["reason"] as? String, "secureInput")
        XCTAssertEqual(rows[2]["reason"] as? String, "tapUnavailable")
        XCTAssertEqual(rows[2]["requestedReason"] as? String, "lidLimit")
        XCTAssertNil(rows[1]["key"]); XCTAssertNil(rows[1]["text"])
        XCTAssertEqual(SessionHistory(directory: directory).lastEnd["reason"], "tapUnavailable")
        XCTAssertEqual(SessionHistory(directory: directory).lastEnd["requestedReason"], "lidLimit")
    }

    func testHistoryFileContentionDoesNotBlockSessionOwner() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let history = SessionHistory(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("application-session.jsonl").path
        let fd = open(path, O_WRONLY | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { _ = flock(fd, LOCK_UN); close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let returned = expectation(description: "owner remains responsive")
        DispatchQueue.global().async {
            history.ended(.secureInput, tapEnabled: true, secureInput: true, macOSState: "unlocked")
            returned.fulfill()
        }
        wait(for: [returned], timeout: 2)
        XCTAssertTrue(history.flush())
        XCTAssertEqual(history.lastEnd["reason"], "secureInput")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)).count, 0)
        _ = flock(fd, LOCK_UN)
        history.ended(.emergency, tapEnabled: true, secureInput: false, macOSState: "unlocked")
        XCTAssertTrue(history.flush())
        let rows = try Data(contentsOf: URL(fileURLWithPath: path)).split(separator: 10)
        XCTAssertEqual(rows.count, 1)
        let row = try JSONSerialization.jsonObject(with: Data(rows[0])) as? [String: Any]
        XCTAssertEqual(row?["reason"] as? String, "emergency")
    }

    func testDisconnectAfterPreparationNeverCommitsExit() throws {
        let gate = DeferredUpdateGate()
        try gate.start()
        defer { gate.stop() }
        let sent = expectation(description: "preparation sent")
        let cancelled = expectation(description: "disconnect resumes owner")
        gate.onCommit = { XCTFail("Readiness without commit must not authorize exit") }
        gate.onDisconnect = { cancelled.fulfill() }
        gate.onChange = {
            if gate.pending { gate.finish { success in XCTAssertTrue(success); sent.fulfill() } }
        }
        DispatchQueue.global().async {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { close(fd) }
            var address = try! DeferredUpdateGate.address(DeferredUpdateGate.socketPath(pid: getpid()))
            XCTAssertEqual(withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }, 0)
            let wire = Data("{\"command\":\"defer\",\"version\":\"0.7.99\"}\n".utf8)
            _ = wire.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            var buffer = Data()
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while ProcessInfo.processInfo.systemUptime < deadline {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 100) > 0 else { continue }
                var bytes = [UInt8](repeating: 0, count: 1024)
                let count = read(fd, &bytes, bytes.count)
                guard count > 0 else { break }
                buffer.append(contentsOf: bytes.prefix(count))
                if String(decoding: buffer, as: UTF8.self).contains("\"ready\"") { return }
            }
            XCTFail("Preparation was not received")
        }
        wait(for: [sent, cancelled], timeout: 3)
        XCTAssertFalse(gate.pending)
    }
}
