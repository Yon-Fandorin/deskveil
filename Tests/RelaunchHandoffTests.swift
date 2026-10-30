import Darwin
import Foundation
import XCTest
@testable import SoftLock

final class RelaunchHandoffTests: XCTestCase {
    private var root: URL!
    private let parent = RelaunchHandoff.Peer(pid: 101, uid: getuid(), seconds: 10, microseconds: 1, executable: "/fixture/SoftLock")
    private let child = RelaunchHandoff.Peer(pid: 102, uid: getuid(), seconds: 11, microseconds: 1, executable: "/fixture/SoftLock")
    private var peers: [pid_t: RelaunchHandoff.Peer] = [:]
    private var living = Set<pid_t>()
    private var allowed = true

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("softlock-relaunch-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        peers = [parent.pid: parent, child.pid: child]; living = [parent.pid, child.pid]; allowed = true
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func context(_ peer: RelaunchHandoff.Peer) -> RelaunchHandoff.Context {
        .init(root: root, own: peer, requirement: "fixture-signer-and-id", lookup: { self.peers[$0] },
              alive: { self.living.contains($0) }, authorized: { _, _, _ in self.allowed })
    }
    private func directory(_ handoff: RelaunchHandoff) -> URL {
        root.appendingPathComponent("softlock-relaunch-\(getuid())-\(handoff.token)")
    }

    func testReadyIsNotPermissionToStartBeforeExactPredecessorExits() throws {
        let old = try RelaunchHandoff.create(context: context(parent))
        XCTAssertFalse(old.ready(for: child.pid))
        let replacement = try RelaunchHandoff.accept(old.token, context: context(child))
        XCTAssertTrue(old.ready(for: child.pid)); XCTAssertFalse(old.ready(for: 103))
        XCTAssertEqual(replacement.predecessorState(), .waiting)
        peers[parent.pid] = nil // Native inspection can transiently fail.
        XCTAssertEqual(replacement.predecessorState(), .waiting)
        living.remove(parent.pid)
        XCTAssertEqual(replacement.predecessorState(), .released)
        replacement.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory(old).path))
    }

    func testFailureCancellationNeverAdmitsReplacement() throws {
        let old = try RelaunchHandoff.create(context: context(parent))
        let replacement = try RelaunchHandoff.accept(old.token, context: context(child))
        old.cancel()
        XCTAssertEqual(replacement.predecessorState(), .cancelled)
        XCTAssertThrowsError(try RelaunchHandoff.accept(old.token, context: context(child)))
    }

    func testPeerSignerUIDExecutableAndProcessIncarnationAreRequired() throws {
        let old = try RelaunchHandoff.create(context: context(parent)); defer { old.cancel() }
        allowed = false
        XCTAssertThrowsError(try RelaunchHandoff.accept(old.token, context: context(child)))
        allowed = true
        for peer in [
            RelaunchHandoff.Peer(pid: child.pid, uid: child.uid + 1, seconds: 11, microseconds: 1, executable: child.executable),
            RelaunchHandoff.Peer(pid: child.pid, uid: child.uid, seconds: 11, microseconds: 1, executable: "/other/SoftLock")
        ] { XCTAssertThrowsError(try RelaunchHandoff.accept(old.token, context: context(peer))) }
        peers[parent.pid] = .init(pid: parent.pid, uid: parent.uid, seconds: 12, microseconds: 1, executable: parent.executable)
        XCTAssertThrowsError(try RelaunchHandoff.accept(old.token, context: context(child)))
        peers[parent.pid] = parent
        let replacement = try RelaunchHandoff.accept(old.token, context: context(child))
        peers[child.pid] = .init(pid: child.pid, uid: child.uid, seconds: 13, microseconds: 1, executable: child.executable)
        XCTAssertFalse(old.ready(for: child.pid))
        peers[parent.pid] = peers[child.pid].map { .init(pid: parent.pid, uid: $0.uid, seconds: $0.seconds, microseconds: 1, executable: $0.executable) }
        XCTAssertEqual(replacement.predecessorState(), .released)
    }

    func testTicketPathsAndRecordPermissionsAreNotAuthority() throws {
        XCTAssertThrowsError(try RelaunchHandoff.accept("../record.json", context: context(child)))
        let old = try RelaunchHandoff.create(context: context(parent)); defer { old.cancel() }
        let record = directory(old).appendingPathComponent("record.json")
        XCTAssertEqual(chmod(record.path, 0o644), 0)
        XCTAssertThrowsError(try RelaunchHandoff.accept(old.token, context: context(child)))
        XCTAssertEqual(chmod(record.path, 0o600), 0)
        let saved = root.appendingPathComponent("saved.json")
        try FileManager.default.moveItem(at: record, to: saved)
        try FileManager.default.createSymbolicLink(at: record, withDestinationURL: saved)
        XCTAssertThrowsError(try RelaunchHandoff.accept(old.token, context: context(child)))
        old.cancel()
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    }
}
