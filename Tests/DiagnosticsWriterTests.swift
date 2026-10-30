import XCTest
@testable import SoftLock

final class DiagnosticsWriterTests: XCTestCase {
    func testBlockedDiskDoesNotBlockMainAndOnlyNewestPendingSnapshotIsWritten() {
        let started = expectation(description: "disk write started")
        let mainContinued = expectation(description: "main loop continued")
        let gate = DispatchSemaphore(value: 0)
        let mutex = NSLock()
        var written: [Data] = []
        let writer = DiagnosticsWriter { data in
            XCTAssertFalse(Thread.isMainThread)
            mutex.lock(); written.append(data); let first = written.count == 1; mutex.unlock()
            if first { started.fulfill(); _ = gate.wait(timeout: .now() + 3) }
            return true
        }
        writer.submit(Data("first".utf8))
        wait(for: [started], timeout: 1)
        for value in 0..<100 { writer.submit(Data("pending-\(value)".utf8)) }
        DispatchQueue.main.async { mainContinued.fulfill() }
        wait(for: [mainContinued], timeout: 1)
        gate.signal()
        XCTAssertTrue(writer.flush())
        mutex.lock(); let result = written; mutex.unlock()
        XCTAssertEqual(result, [Data("first".utf8), Data("pending-99".utf8)])
    }

    func testWriteFailureIsReportedOnMainAndNextSubmissionCanRetry() {
        let finished = expectation(description: "failed write followed by retry")
        var attempts = 0
        let writer = DiagnosticsWriter { _ in attempts += 1; return attempts > 1 }
        let data = Data("snapshot".utf8)
        writer.submit(data) { success in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertFalse(success)
            writer.submit(data) { success in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertTrue(success)
                finished.fulfill()
            }
        }
        wait(for: [finished], timeout: 2)
        XCTAssertTrue(writer.flush())
    }

    func testAtomicFileContainsLatestCompleteSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("diagnostics.json")
        let writer = DiagnosticsWriter(url: url)
        writer.submit(Data("{\"sequence\":1}".utf8))
        let latest = Data("{\"sequence\":2,\"complete\":true}".utf8)
        writer.submit(latest)
        XCTAssertTrue(writer.flush())
        XCTAssertEqual(try Data(contentsOf: url), latest)
    }
}
