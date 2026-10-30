import Darwin
import Foundation
import XCTest
@testable import SoftLock

final class LidInstallationTests: XCTestCase {
    func testApprovalTracksHelperAndClientIdentityRatherThanAppVersion() {
        let identity = LidInstallationIdentity(uid: 501,
            clientRequirement: "identifier \"dev.local.softlock\" and certificate leaf = H\"\(String(repeating: "a", count: 40))\"",
            helperHash: String(repeating: "b", count: 40))
        var configuration = identity.configuration
        configuration["version"] = "unrelated UI version"
        configuration["clientHash"] = "unrelated UI executable hash"
        XCTAssertTrue(identity.matches(configuration))
        for (key, value) in [("uid", 502 as Any), ("protocol", -1),
                             ("clientRequirement", "identifier \"dev.local.softlock\""),
                             ("helperHash", String(repeating: "c", count: 40))] {
            var changed = configuration
            changed[key] = value
            XCTAssertFalse(identity.matches(changed), key)
            changed.removeValue(forKey: key)
            XCTAssertFalse(identity.matches(changed), "Missing \(key)")
        }
    }
}

final class LidInstallationTransactionTests: XCTestCase {
    private final class Power: LidPowerBackend {
        var value = true
        var failRestore = false
        var mutations: [Bool] = []
        func disabled() throws -> Bool { value }
        func configuredDisabled() throws -> Bool { value }
        func setDisabled(_ value: Bool) throws {
            mutations.append(value)
            if failRestore { throw LidError("injected recovery failure") }
            self.value = value
        }
    }

    private final class Fixture {
        let directory: URL
        let stage: URL
        let files: LidInstallationFiles
        let identity = LidInstallationIdentity(uid: 501, clientRequirement: "test-client", helperHash: "new-helper")
        let power = Power()
        var loaded: Bool
        var launches: [String] = []
        var failBootstrap = false
        var preserveStage = false

        init(installed: Bool = true) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("softlock-installer-" + UUID().uuidString)
            let root = directory.appendingPathComponent("service")
            files = LidInstallationFiles(root: root.path, plist: directory.appendingPathComponent("job.plist").path,
                socket: directory.appendingPathComponent("control.sock").path,
                lock: directory.appendingPathComponent("recovery.lock").path)
            stage = root.appendingPathComponent(".install-test")
            loaded = installed
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Self.helper(stage.appendingPathComponent("Helper.app"), marker: "new-helper")
            if installed {
                try Self.helper(URL(fileURLWithPath: files.helper), marker: "old-helper")
                try Data("old-configuration".utf8).write(to: URL(fileURLWithPath: files.configuration))
                try Data("old-job".utf8).write(to: URL(fileURLWithPath: files.plist))
            }
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        static func helper(_ url: URL, marker: String) throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: url.appendingPathComponent("marker"))
        }

        func marker(_ path: String) throws -> String {
            try String(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("marker"), encoding: .utf8)
        }

        func environment() -> LidInstallationEnvironment {
            LidInstallationEnvironment(files: files, owner: geteuid(), lockTimeout: 0.02, power: power,
                command: { [self] arguments, _ in
                    precondition(arguments.first == "/bin/launchctl")
                    let action = arguments[1]
                    launches.append(action)
                    switch action {
                    case "print":
                        guard loaded else { throw LidError("test job absent") }
                    case "bootout": loaded = false
                    case "bootstrap":
                        if failBootstrap { failBootstrap = false; throw LidError("injected bootstrap failure") }
                        guard !loaded else { throw LidError("test job already loaded") }
                        loaded = true
                    default: preconditionFailure("Unexpected installation command")
                    }
                    return ""
                })
        }

        func install(remove: Bool = false, environment: LidInstallationEnvironment? = nil) throws {
            try performLidInstallationTransaction(stage: stage, identity: identity, remove: remove,
                environment: environment ?? self.environment(), preserveStage: &preserveStage)
        }

        func assertPreviousInstallation(file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(try marker(files.helper), "old-helper", file: file, line: line)
            XCTAssertEqual(try String(contentsOfFile: files.configuration), "old-configuration", file: file, line: line)
            XCTAssertEqual(try String(contentsOfFile: files.plist), "old-job", file: file, line: line)
            XCTAssertTrue(loaded, "Previous job must be restarted", file: file, line: line)
            XCTAssertFalse(preserveStage, file: file, line: line)
        }
    }

    func testExistingHelperSurvivesFailureOfItsFirstBackupMove() throws {
        let fixture = try Fixture()
        var environment = fixture.environment()
        environment.moveItem = { source, destination in
            if source.path == fixture.files.helper { throw LidError("injected first backup failure") }
            try FileManager.default.moveItem(at: source, to: destination)
        }
        XCTAssertThrowsError(try fixture.install(environment: environment))
        try fixture.assertPreviousInstallation()
        XCTAssertEqual(fixture.launches.filter { $0 == "bootstrap" }.count, 1)
    }

    func testInstallationLockRejectsUnsafeFilesBeforePreflight() throws {
        for failure in ["symlink", "directory", "fifo", "owner", "writable"] {
            let fixture = try Fixture()
            let path = fixture.directory.appendingPathComponent("installation.lock").path
            var owner = geteuid()
            switch failure {
            case "symlink":
                try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: fixture.files.configuration)
            case "directory":
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
            case "fifo":
                XCTAssertEqual(mkfifo(path, 0o600), 0)
            default:
                try Data().write(to: URL(fileURLWithPath: path))
                XCTAssertEqual(chmod(path, failure == "writable" ? 0o622 : 0o600), 0)
                if failure == "owner" { owner += 1 }
            }
            XCTAssertThrowsError(try withLidInstallationLock(path: path, owner: owner, timeout: 0.02) {
                XCTFail("Unsafe installation lock reached preflight: \(failure)")
                try fixture.install()
            })
            try fixture.assertPreviousInstallation()
            XCTAssertTrue(fixture.launches.isEmpty, failure)
        }
    }

    func testInstallationLockTimeoutLeavesFilesAndJobUntouchedAndRetainsItsInode() throws {
        let fixture = try Fixture()
        let path = fixture.directory.appendingPathComponent("installation.lock").path
        let held = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        XCTAssertGreaterThanOrEqual(held, 0)
        defer { close(held) }
        XCTAssertEqual(flock(held, LOCK_EX | LOCK_NB), 0)
        var before = stat()
        XCTAssertEqual(fstat(held, &before), 0)
        var entered = false
        XCTAssertThrowsError(try withLidInstallationLock(path: path, owner: geteuid(), timeout: 0.02) {
            entered = true
            try fixture.install()
        })
        XCTAssertFalse(entered)
        try fixture.assertPreviousInstallation()
        XCTAssertTrue(fixture.launches.isEmpty)
        XCTAssertEqual(flock(held, LOCK_UN), 0)
        XCTAssertThrowsError(try withLidInstallationLock(path: path, owner: geteuid()) {
            throw LidError("injected locked operation failure")
        })
        try withLidInstallationLock(path: path, owner: geteuid()) {}
        var after = stat()
        XCTAssertEqual(lstat(path, &after), 0)
        XCTAssertEqual(after.st_dev, before.st_dev)
        XCTAssertEqual(after.st_ino, before.st_ino)
    }

    func testConcurrentInstallationsSerializePreflightBackupCommitAndRollback() throws {
        let fixture = try Fixture()
        let path = fixture.directory.appendingPathComponent("installation.lock").path
        let firstCommit = expectation(description: "first installer reached commit")
        let secondAttempt = expectation(description: "second installer attempting the same lock")
        let firstFinished = expectation(description: "first installer cleaned its stage")
        let secondFinished = expectation(description: "second installer rolled back")
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        defer { releaseFirst.signal() }
        let eventLock = NSLock()
        var events: [String] = []
        let record: (String) -> Void = { event in
            eventLock.lock(); events.append(event); eventLock.unlock()
        }
        var environment = fixture.environment()
        environment.readFile = { path in
            if path == fixture.files.configuration { record("first-backup") }
            return try Data(contentsOf: URL(fileURLWithPath: path))
        }
        let firstCommand = environment.command
        var firstBootstrap = true
        environment.command = { arguments, timeout in
            if arguments[1] == "bootstrap" && firstBootstrap {
                firstBootstrap = false
                record("first-commit")
                firstCommit.fulfill()
                guard releaseFirst.wait(timeout: .now() + 10) == .success else { throw LidError("installer barrier timed out") }
            }
            return try firstCommand(arguments, timeout)
        }
        let firstEnvironment = environment
        DispatchQueue(label: "softlock-test-first-installer").async {
            defer { firstFinished.fulfill() }
            do {
                try withLidInstallationLock(path: path, owner: geteuid()) {
                    defer {
                        if !fixture.preserveStage { try? FileManager.default.removeItem(at: fixture.stage) }
                        record("first-cleanup")
                    }
                    record("first-preflight")
                    XCTAssertEqual(try fixture.marker(fixture.files.helper), "old-helper")
                    XCTAssertEqual(try String(contentsOfFile: fixture.files.configuration), "old-configuration")
                    try fixture.install(environment: firstEnvironment)
                }
            } catch { XCTFail("First installation failed: \(error)") }
        }
        wait(for: [firstCommit], timeout: 2)
        DispatchQueue(label: "softlock-test-second-installer").async {
            defer { secondFinished.fulfill() }
            secondAttempt.fulfill()
            do {
                try withLidInstallationLock(path: path, owner: geteuid(), timeout: 5) {
                    secondEntered.signal()
                    record("second-preflight")
                    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stage.path), "Preflight must follow the previous stage cleanup")
                    XCTAssertTrue(fixture.identity.matches(try lidJSON(fixture.files.configuration)))
                    let stage = URL(fileURLWithPath: fixture.files.root).appendingPathComponent(".install-second")
                    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                                                            attributes: [.posixPermissions: 0o700])
                    var preserveStage = false
                    defer {
                        if !preserveStage { try? FileManager.default.removeItem(at: stage) }
                        record("second-cleanup")
                    }
                    try Fixture.helper(stage.appendingPathComponent("Helper.app"), marker: "second-helper")
                    let identity = LidInstallationIdentity(uid: 501, clientRequirement: "test-client", helperHash: "second-helper")
                    var environment = fixture.environment()
                    environment.readFile = { path in
                        let data = try Data(contentsOf: URL(fileURLWithPath: path))
                        if path == fixture.files.configuration {
                            record("second-backup")
                            let configuration = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                            XCTAssertTrue(fixture.identity.matches(configuration), "Backup must contain the first committed identity")
                        }
                        return data
                    }
                    let command = environment.command
                    var bootstraps = 0
                    environment.command = { arguments, timeout in
                        if arguments[1] == "bootstrap" {
                            bootstraps += 1
                            record(bootstraps == 1 ? "second-commit-failed" : "second-rollback")
                        }
                        return try command(arguments, timeout)
                    }
                    fixture.failBootstrap = true
                    XCTAssertThrowsError(try performLidInstallationTransaction(stage: stage, identity: identity, remove: false,
                        environment: environment, preserveStage: &preserveStage)) { error in
                        XCTAssertEqual(error.localizedDescription, "injected bootstrap failure")
                    }
                    XCTAssertFalse(preserveStage)
                    XCTAssertEqual(try fixture.marker(fixture.files.helper), "new-helper")
                    XCTAssertTrue(fixture.identity.matches(try lidJSON(fixture.files.configuration)))
                    XCTAssertTrue(fixture.loaded)
                }
            } catch { XCTFail("Second installer scope failed: \(error)") }
        }
        wait(for: [secondAttempt], timeout: 2)
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 0.1), .timedOut,
                       "The second preflight must wait while the first commits")
        releaseFirst.signal()
        wait(for: [firstFinished, secondFinished], timeout: 5)
        eventLock.lock(); let order = events; eventLock.unlock()
        XCTAssertEqual(order, ["first-preflight", "first-backup", "first-commit", "first-cleanup",
                               "second-preflight", "second-backup", "second-commit-failed", "second-rollback", "second-cleanup"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: fixture.files.root)
            .appendingPathComponent(".install-second").path))
    }

    func testBackupReadFailureAfterAuthenticationLeavesPreviousInstallationRunning() throws {
        for configuration in [true, false] {
            let fixture = try Fixture()
            var environment = fixture.environment()
            let failedPath = configuration ? fixture.files.configuration : fixture.files.plist
            environment.readFile = { path in
                if path == failedPath { throw LidError("injected read error after authentication") }
                return try Data(contentsOf: URL(fileURLWithPath: path))
            }
            XCTAssertThrowsError(try fixture.install(environment: environment))
            try fixture.assertPreviousInstallation()
            XCTAssertTrue(fixture.launches.isEmpty, "Backup failure must precede any service operation")
        }
    }

    func testPostUnloadFailuresRestartTheUnchangedPreviousJob() throws {
        for failure in ["lock-open", "lock-timeout", "receipt-type", "receipt-value", "power-restore"] {
            let fixture = try Fixture()
            let environment = fixture.environment()
            var heldLock: Int32 = -1
            defer { if heldLock >= 0 { close(heldLock) } }
            switch failure {
            case "lock-open":
                try FileManager.default.createSymbolicLink(atPath: fixture.files.lock, withDestinationPath: "/dev/null")
            case "lock-timeout":
                heldLock = open(fixture.files.lock, O_RDWR | O_CREAT, 0o600)
                XCTAssertGreaterThanOrEqual(heldLock, 0)
                XCTAssertEqual(flock(heldLock, LOCK_EX | LOCK_NB), 0)
            case "receipt-type":
                try FileManager.default.createSymbolicLink(atPath: fixture.files.receipt, withDestinationPath: fixture.files.configuration)
            case "receipt-value":
                try lidWriteJSON(["baselineDisabled": true], fixture.files.receipt)
            case "power-restore":
                try lidWriteJSON(["baselineDisabled": false], fixture.files.receipt)
                fixture.power.failRestore = true
            default: preconditionFailure("Unknown test failure")
            }
            XCTAssertThrowsError(try fixture.install(environment: environment), failure)
            try fixture.assertPreviousInstallation()
            XCTAssertEqual(fixture.launches.filter { $0 == "bootstrap" }.count, 1, failure)
            XCTAssertFalse(fixture.launches.isEmpty, failure)
            if failure != "power-restore" { XCTAssertTrue(fixture.power.mutations.isEmpty, failure) }
        }
    }

    func testInvalidBackupOwnershipStopsBeforeUnloadingPreviousJob() throws {
        let fixture = try Fixture()
        var environment = fixture.environment()
        environment.owner = geteuid() + 1
        XCTAssertThrowsError(try fixture.install(environment: environment))
        try fixture.assertPreviousInstallation()
        XCTAssertTrue(fixture.launches.isEmpty)
    }

    func testBootstrapFailureRestoresThePreviousBundleAndConfiguration() throws {
        let fixture = try Fixture()
        fixture.failBootstrap = true
        XCTAssertThrowsError(try fixture.install())
        try fixture.assertPreviousInstallation()
        XCTAssertEqual(fixture.launches.filter { $0 == "bootstrap" }.count, 2)
    }

    func testReplacementMoveFailureRestoresThePreviousBundle() throws {
        let fixture = try Fixture()
        var environment = fixture.environment()
        environment.moveItem = { source, destination in
            if source == fixture.stage.appendingPathComponent("Helper.app") {
                throw LidError("injected replacement move failure")
            }
            try FileManager.default.moveItem(at: source, to: destination)
        }
        XCTAssertThrowsError(try fixture.install(environment: environment))
        try fixture.assertPreviousInstallation()
    }

    func testFailedFirstInstallationRemovesItsUncommittedFiles() throws {
        let fixture = try Fixture(installed: false)
        fixture.failBootstrap = true
        XCTAssertThrowsError(try fixture.install())
        for path in [fixture.files.helper, fixture.files.configuration, fixture.files.plist] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
        XCTAssertFalse(fixture.loaded)
    }

    func testInstallRecoversAReceiptBeforeLoadingTheNewHelper() throws {
        let fixture = try Fixture()
        try lidWriteJSON(["baselineDisabled": false], fixture.files.receipt)
        try fixture.install()
        XCTAssertEqual(try fixture.marker(fixture.files.helper), "new-helper")
        XCTAssertTrue(fixture.identity.matches(try lidJSON(fixture.files.configuration)))
        let job = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: fixture.files.plist)), format: nil) as? [String: Any]
        XCTAssertEqual(job?["ProgramArguments"] as? [String], [fixture.files.executable, "--lid-service"])
        XCTAssertEqual(fixture.power.mutations, [false])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.files.receipt))
        XCTAssertTrue(fixture.loaded)
    }

    func testRemovalFailureRestartsThePreviousInstallation() throws {
        let fixture = try Fixture()
        try FileManager.default.createSymbolicLink(atPath: fixture.files.state, withDestinationPath: fixture.directory.path)
        XCTAssertThrowsError(try fixture.install(remove: true))
        try fixture.assertPreviousInstallation()
    }

    func testFailedRollbackPreservesTheOriginalHelperAndRecoveryFiles() throws {
        let fixture = try Fixture()
        fixture.failBootstrap = true
        var environment = fixture.environment()
        environment.moveItem = { source, destination in
            if source.lastPathComponent == "Previous.app" { throw LidError("injected rollback move failure") }
            try FileManager.default.moveItem(at: source, to: destination)
        }
        XCTAssertThrowsError(try fixture.install(environment: environment))
        XCTAssertTrue(fixture.preserveStage)
        XCTAssertFalse(fixture.loaded)
        XCTAssertEqual(try fixture.marker(fixture.stage.appendingPathComponent("Previous.app").path), "old-helper")
        XCTAssertEqual(try String(contentsOf: fixture.stage.appendingPathComponent("previous-service.json")), "old-configuration")
        XCTAssertEqual(try String(contentsOf: fixture.stage.appendingPathComponent("previous-job.plist")), "old-job")
    }

    func testStagingFailureLeavesThePreviousJobRunning() throws {
        let fixture = try Fixture()
        try FileManager.default.removeItem(at: fixture.stage)
        XCTAssertThrowsError(try fixture.install())
        try fixture.assertPreviousInstallation()
        XCTAssertTrue(fixture.launches.isEmpty)
    }

    func testRemovalKeepsPowerRecoveryAndStopsTheJob() throws {
        let fixture = try Fixture()
        try lidWriteJSON(["baselineDisabled": false], fixture.files.receipt)
        try fixture.install(remove: true)
        XCTAssertFalse(fixture.loaded)
        XCTAssertEqual(fixture.power.mutations, [false])
        for path in [fixture.files.helper, fixture.files.configuration, fixture.files.plist, fixture.files.receipt] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }
}

final class LidJournalTests: XCTestCase {
    func testDiagnosticReaderLockDoesNotDelayRecoveryWriters() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("softlock-journal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("session.jsonl").path
        try Data().write(to: URL(fileURLWithPath: path))
        let reader = open(path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(reader, 0)
        defer { close(reader) }
        XCTAssertEqual(flock(reader, LOCK_SH | LOCK_NB), 0)
        let finished = expectation(description: "Logging skips a reader's held lock")
        DispatchQueue.global().async {
            LidJournal(path).emit("recovering")
            finished.fulfill()
        }
        wait(for: [finished], timeout: 0.5)
        flock(reader, LOCK_UN)
        LidJournal(path).emit("restored")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let records = data.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        XCTAssertEqual(records.compactMap { $0["event"] as? String }, ["restored"])
    }
}
