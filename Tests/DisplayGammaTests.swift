import XCTest
@testable import SoftLock

private final class GammaMemory: GammaRecoveryStore {
    var values: [String: DisplayGammaTable] = [:]
    var writable = true
    var readable = true
    var onSave: (() -> Void)?
    func load() -> DisplayRecoveryLoad<[String: DisplayGammaTable]> { readable ? (values.isEmpty ? .absent : .loaded(values)) : .failed }
    func save(_ next: [String: DisplayGammaTable]) -> Bool {
        guard writable else { return false }
        values = next; onSave?(); return true
    }
}
private final class GammaBrightnessMemory: BrightnessRecoveryStore {
    var values: [String: Float] = [:]
    var readable = true
    func load() -> DisplayRecoveryLoad<[String: Float]> { readable ? (values.isEmpty ? .absent : .loaded(values)) : .failed }
    func save(_ next: [String: Float]) -> Bool { values = next; return true }
}

final class DisplayGammaTests: XCTestCase {
    private let original = DisplayGammaTable(red: [0, 0.12, 0.8, 1], green: [0, 0.2, 0.7, 0.9], blue: [0, 0.1, 0.6, 0.85])

    func testGammaCaptureAndDurableSaveCannotWriteToAReusedDisplayID() {
        for replaceDuringRead in [true, false] {
            let recovery = GammaMemory(); var identity = "original", writes = 0
            if !replaceDuringRead { recovery.onSave = { identity = "replacement" } }
            let blackout = ExternalBlackout(read: { [original] _ in
                if replaceDuringRead { identity = "replacement" }; return original
            }, write: { _, _ in writes += 1; return true }, recovery: recovery)
            let brightness = NativeBrightness(displays: { [1] }, read: { _ in nil }, write: { _, _ in true },
                identity: { _ in identity }, blackout: blackout, blackoutEligible: { _ in true })
            XCTAssertEqual(brightness.controlDisplay(.init(displayID: 1, identity: "original", off: true)), .unsupported)
            XCTAssertEqual(writes, 0)
            if !replaceDuringRead {
                XCTAssertEqual(recovery.values["original"], original)
                XCTAssertFalse(brightness.restore()); XCTAssertEqual(writes, 0)
                recovery.onSave = nil; identity = "original"
                XCTAssertTrue(brightness.restore()); XCTAssertEqual(writes, 1)
            }
        }
    }
    func testIdentityReplacedByHardwareWriteCannotReceiveThePreviousDisplaysGamma() {
        let recovery = GammaMemory(), physical = GammaBrightnessMemory()
        var identity = "original", gammaWrites = 0, replace = true
        let blackout = ExternalBlackout(read: { [original] _ in original },
            write: { _, _ in gammaWrites += 1; return true }, recovery: recovery)
        let brightness = NativeBrightness(displays: { [1] }, read: { _ in 0.8 }, write: { _, _ in
            if replace { replace = false; identity = "replacement" }; return true
        }, identity: { _ in identity }, recovery: physical, blackout: blackout, blackoutEligible: { _ in true })
        XCTAssertEqual(brightness.controlDisplay(.init(displayID: 1, identity: "original", off: true)), .recoveryNeeded)
        XCTAssertEqual(gammaWrites, 0); XCTAssertEqual(recovery.values["original"], original)
        XCTAssertEqual(physical.values["original"], 0.8)
        XCTAssertFalse(brightness.restore()); XCTAssertEqual(gammaWrites, 0)
    }

    func testZeroPhysicalBrightnessStillRestoresExactOriginalColors() {
        let recovery = GammaMemory()
        var gamma = original
        let blackout = ExternalBlackout(read: { _ in gamma }, write: { _, table in gamma = table; return true }, recovery: recovery)
        let brightness = NativeBrightness(displays: { [2] }, read: { _ in 0 }, write: { _, _ in true }, blackout: blackout)
        XCTAssertEqual(brightness.dim(), 1)
        XCTAssertEqual(gamma, original.scaled(0))
        XCTAssertEqual(recovery.values["2"], original)
        XCTAssertTrue(brightness.restore())
        XCTAssertEqual(gamma, original)
        XCTAssertFalse(brightness.hasPendingRestore)
        XCTAssertTrue(recovery.values.isEmpty)
    }

    func testCannotBlackoutWithoutDurablySavedValidOriginal() {
        let recovery = GammaMemory(); recovery.writable = false
        var writes = 0
        let blackout = ExternalBlackout(read: { [original] _ in original },
            write: { _, _ in writes += 1; return true }, recovery: recovery)
        XCTAssertFalse(blackout.prepare(2, identity: "external"))
        XCTAssertFalse(blackout.apply(2, identity: "external", factor: 0, verify: true))
        XCTAssertEqual(writes, 0)
        recovery.writable = true
        let invalid = ExternalBlackout(read: { _ in DisplayGammaTable(red: [.nan, 1], green: [0, 1], blue: [0, 1]) },
            write: { _, _ in writes += 1; return true }, recovery: recovery)
        XCTAssertFalse(invalid.prepare(2, identity: "external"))
        XCTAssertEqual(writes, 0)
    }

    func testUnverifiedGammaRestoreDoesNotReleaseCoverAndRecoversAfterReconnect() {
        let gammaRecovery = GammaMemory(), physicalRecovery = GammaBrightnessMemory()
        var gamma = original, physical: Float = 0.9, ignoreRestore = false
        func controller(_ id: UInt32) -> NativeBrightness {
            let blackout = ExternalBlackout(read: { _ in gamma }, write: { _, table in
                if !ignoreRestore { gamma = table }; return true
            }, recovery: gammaRecovery)
            return NativeBrightness(displays: { [id] }, read: { _ in physical }, write: { _, value in physical = value; return true },
                identity: { _ in "same-monitor" }, recovery: physicalRecovery, blackout: blackout)
        }
        let first = controller(2)
        XCTAssertEqual(first.dim(duration: 1, at: 0), 1)
        XCTAssertTrue(first.advanceTransitions(at: 1).isEmpty)
        XCTAssertEqual(gamma, original.scaled(0))
        ignoreRestore = true
        XCTAssertTrue(first.restore(duration: 1, at: 1))
        XCTAssertEqual(first.advanceTransitions(at: 2), [.restoreFailed])
        XCTAssertTrue(first.hasPendingRestore)
        XCTAssertEqual(gammaRecovery.values["same-monitor"], original)
        XCTAssertEqual(physicalRecovery.values["same-monitor"], 0.9)
        ignoreRestore = false
        let restarted = controller(9)
        XCTAssertTrue(restarted.restore())
        XCTAssertEqual(gamma, original)
        XCTAssertFalse(restarted.hasPendingRestore)
        XCTAssertTrue(gammaRecovery.values.isEmpty)
        XCTAssertTrue(physicalRecovery.values.isEmpty)
    }

    func testOnlyExternalGammaIsChangedAndUnexpectedResetIsBlackenedAgain() {
        let recovery = GammaMemory()
        let other = original.scaled(0.8)
        var tables: [UInt32: DisplayGammaTable] = [1: original, 2: original, 3: other]
        var physical: [UInt32: Float] = [1: 0.4, 2: 0.9, 3: 0.7]
        var gammaWrites = Set<UInt32>()
        let blackout = ExternalBlackout(read: { tables[$0] }, write: { id, table in
            gammaWrites.insert(id); tables[id] = table; return true
        }, recovery: recovery)
        let brightness = NativeBrightness(displays: { [1, 2, 3] }, read: { physical[$0] },
            write: { id, value in physical[id] = value; return true }, blackout: blackout, blackoutEligible: { $0 != 1 })
        XCTAssertEqual(brightness.dim(), 3)
        XCTAssertEqual(gammaWrites, [2, 3])
        XCTAssertEqual(tables[1], original)
        tables[2] = original
        brightness.maintainDim()
        XCTAssertEqual(tables[2], original.scaled(0))
        XCTAssertTrue(brightness.restore())
        XCTAssertEqual(tables[1], original)
        XCTAssertEqual(tables[2], original)
        XCTAssertEqual(tables[3], other)
        XCTAssertEqual(physical, [1: 0.4, 2: 0.9, 3: 0.7])
    }

    func testMonitorConnectedDuringDimmingIsBlackenedAndRestoresItsOwnOriginal() {
        let recovery = GammaMemory()
        let other = original.scaled(0.8)
        var displays: [UInt32] = [2]
        var tables: [UInt32: DisplayGammaTable] = [2: original, 3: other]
        var physical: [UInt32: Float] = [2: 0.9, 3: 0.7]
        let blackout = ExternalBlackout(read: { tables[$0] }, write: { id, table in
            tables[id] = table; return true
        }, recovery: recovery)
        let brightness = NativeBrightness(displays: { displays }, read: { physical[$0] },
            write: { id, value in physical[id] = value; return true }, blackout: blackout)
        XCTAssertEqual(brightness.dim(), 1)
        displays.append(3)
        brightness.maintainDim()
        XCTAssertEqual(physical[3], 0)
        XCTAssertEqual(tables[3], other.scaled(0))
        XCTAssertEqual(recovery.values["3"], other)
        XCTAssertTrue(brightness.restore())
        XCTAssertEqual(physical, [2: 0.9, 3: 0.7])
        XCTAssertEqual(tables, [2: original, 3: other])
        physical[3] = 0.6
        brightness.maintainDim()
        XCTAssertEqual(physical[3], 0.6, "Restoration ends discovery and dim maintenance")
    }

    func testMaintenanceReportsRejectedBlackoutAndClearsFailureAfterRecovery() {
        let recovery = GammaMemory()
        var table = original, writable = true, hardwareWritable = true
        var physical: Float = 0.9
        let blackout = ExternalBlackout(read: { _ in table }, write: { _, next in
            guard writable else { return false }
            table = next; return true
        }, recovery: recovery)
        let brightness = NativeBrightness(displays: { [2] }, read: { _ in physical },
            write: { _, value in
                guard hardwareWritable else { return false }
                physical = value; return true
            }, blackout: blackout)
        XCTAssertEqual(brightness.dim(), 1)
        table = original; writable = false
        brightness.maintainDim()
        XCTAssertEqual(brightness.unsupportedDisplays, 1)
        XCTAssertEqual(table, original)
        writable = true
        brightness.maintainDim()
        XCTAssertEqual(brightness.unsupportedDisplays, 0)
        XCTAssertEqual(table, original.scaled(0))
        physical = 0.4; hardwareWritable = false
        brightness.maintainDim()
        XCTAssertEqual(brightness.unsupportedDisplays, 1)
        hardwareWritable = true
        brightness.maintainDim()
        XCTAssertEqual(brightness.unsupportedDisplays, 0)
        XCTAssertEqual(physical, 0)
        XCTAssertTrue(brightness.restore())
        XCTAssertEqual(physical, 0.9)
        XCTAssertEqual(table, original)
    }

    func testGammaOnlyRecoverySurvivesRestartUntilVerifiedAndThenRemovesFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recovery = FileGammaRecovery(url: directory.appendingPathComponent("gamma.json"))
        XCTAssertTrue(recovery.save(["monitor": original]))
        var gamma = original.scaled(0), acknowledge = false
        let blackout = ExternalBlackout(read: { _ in gamma }, write: { _, table in
            if acknowledge { gamma = table }; return true
        }, recovery: recovery)
        let brightness = NativeBrightness(displays: { [8] }, read: { _ in 0.9 }, write: { _, _ in true },
            identity: { _ in "monitor" }, blackout: blackout)
        XCTAssertFalse(brightness.restore())
        XCTAssertTrue(brightness.hasPendingRestore)
        XCTAssertEqual(recovery.load(), .loaded(["monitor": original]))
        acknowledge = true
        XCTAssertTrue(brightness.restore())
        XCTAssertEqual(gamma, original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.url.path))
    }

    func testGammaFileRecoveryRejectsTheWholeJournalIfAnyEntryIsInvalid() throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileGammaRecovery(url: directory.appendingPathComponent("gamma.json"))
        XCTAssertEqual(store.load(), .absent)
        try Data("{}".utf8).write(to: store.url)
        XCTAssertEqual(store.load(), .loaded([:]))
        let invalid = DisplayGammaTable(red: [0, 2], green: [0, 1], blue: [0, 1])
        let mismatched = DisplayGammaTable(red: [0, 1], green: [0], blue: [0, 1])
        for values in [["monitor": original, "invalid": invalid], ["monitor": original, "invalid": mismatched], ["monitor": original, "": original]] {
            let data = try JSONEncoder().encode(values)
            try data.write(to: store.url)
            XCTAssertEqual(store.load(), .failed)
            XCTAssertEqual(try Data(contentsOf: store.url), data)
        }
        try Data("{".utf8).write(to: store.url)
        XCTAssertEqual(store.load(), .failed)
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)
        XCTAssertEqual(store.load(), .failed)
    }

    func testUnreadableGammaJournalCannotCaptureBlackAsOriginalOrAcknowledgeRestoration() throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileGammaRecovery(url: directory.appendingPathComponent("gamma.json"))
        XCTAssertTrue(store.save(["monitor": original]))
        let originalData = try Data(contentsOf: store.url)
        let damaged = Data("{\"monitor\":".utf8)
        try damaged.write(to: store.url)
        var gamma = original.scaled(0), writes = 0, hardwareWrites = 0, acknowledge = false
        let blackout = ExternalBlackout(read: { _ in gamma }, write: { _, table in
            writes += 1; if acknowledge { gamma = table }; return true
        }, recovery: store)
        let brightness = NativeBrightness(displays: { [8] }, read: { _ in 0.9 }, write: { _, _ in
            hardwareWrites += 1; return true
        }, identity: { _ in "monitor" }, blackout: blackout)
        XCTAssertTrue(brightness.hasPendingRestore)
        XCTAssertFalse(brightness.restore())
        XCTAssertEqual(brightness.dim(), 0)
        XCTAssertEqual(brightness.controlDisplay(.init(displayID: 8, identity: "monitor", off: true)), .recoveryNeeded)
        XCTAssertFalse(blackout.prepare(8, identity: "monitor"))
        XCTAssertFalse(blackout.apply(8, identity: "monitor", factor: 0, verify: true))
        XCTAssertFalse(blackout.enforce(8, identity: "monitor"))
        XCTAssertFalse(blackout.restore(8, identity: "monitor"))
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(hardwareWrites, 0)
        XCTAssertEqual(try Data(contentsOf: store.url), damaged)
        try FileManager.default.removeItem(at: store.url)
        XCTAssertFalse(brightness.restore())
        XCTAssertTrue(brightness.hasPendingRestore)
        try originalData.write(to: store.url)
        XCTAssertFalse(brightness.restore(), "A successful write must still be read back")
        XCTAssertEqual(try Data(contentsOf: store.url), originalData)
        XCTAssertTrue(brightness.hasPendingRestore)
        acknowledge = true
        XCTAssertTrue(brightness.restore())
        XCTAssertEqual(gamma, original)
        XCTAssertEqual(hardwareWrites, 0, "Gamma-only recovery cannot acquire physical brightness ownership")
        XCTAssertFalse(brightness.hasPendingRestore)
        XCTAssertEqual(store.load(), .absent)
        XCTAssertTrue(blackout.prepare(8, identity: "monitor"))
        XCTAssertTrue(blackout.apply(8, identity: "monitor", factor: 0, verify: true))
        XCTAssertTrue(blackout.restore(8, identity: "monitor"))
        XCTAssertEqual(gamma, original)
    }

    func testOneUnreadableJournalBlocksBothBackendsAndRetryKeepsTheOtherOriginal() {
        for physicalFails in [true, false] {
            let physicalRecovery = GammaBrightnessMemory(), gammaRecovery = GammaMemory()
            physicalRecovery.values = ["monitor": 0.9]
            gammaRecovery.values = ["monitor": original]
            physicalRecovery.readable = !physicalFails
            gammaRecovery.readable = physicalFails
            var physical: Float = 0, gamma = original.scaled(0), hardwareWrites = 0, gammaWrites = 0
            let blackout = ExternalBlackout(read: { _ in gamma }, write: { _, table in
                gammaWrites += 1; gamma = table; return true
            }, recovery: gammaRecovery)
            let brightness = NativeBrightness(displays: { [8] }, read: { _ in physical }, write: { _, value in
                hardwareWrites += 1; physical = value; return true
            }, identity: { _ in "monitor" }, recovery: physicalRecovery, blackout: blackout)
            XCTAssertFalse(brightness.restore())
            XCTAssertEqual(brightness.dim(), 0)
            XCTAssertEqual(brightness.controlDisplay(.init(displayID: 8, identity: "monitor", off: true)), .recoveryNeeded)
            XCTAssertEqual(hardwareWrites, 0)
            XCTAssertEqual(gammaWrites, 0)
            XCTAssertEqual(physicalRecovery.values, ["monitor": 0.9])
            XCTAssertEqual(gammaRecovery.values, ["monitor": original])
            // The already-loaded owner's original wins over a later store read.
            if physicalFails { gammaRecovery.values["monitor"] = original.scaled(0) }
            else { physicalRecovery.values["monitor"] = 0 }
            physicalRecovery.readable = true; gammaRecovery.readable = true
            XCTAssertEqual(brightness.controlDisplay(.init(displayID: 2, identity: "monitor", off: false)), .on)
            XCTAssertEqual(physical, 0.9)
            XCTAssertEqual(gamma, original)
            XCTAssertFalse(brightness.hasPendingRestore)
            XCTAssertTrue(physicalRecovery.values.isEmpty)
            XCTAssertTrue(gammaRecovery.values.isEmpty)
        }
    }

    func testInitiallyAbsentOrEmptyGammaJournalCanBlackoutAndRestoreNormally() throws {
        for emptyFile in [false, true] {
            let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = FileGammaRecovery(url: directory.appendingPathComponent("gamma.json"))
            if emptyFile { try Data("{}".utf8).write(to: store.url) }
            var gamma = original
            let blackout = ExternalBlackout(read: { _ in gamma }, write: { _, table in gamma = table; return true }, recovery: store)
            XCTAssertEqual(blackout.hasPendingRestore, emptyFile)
            XCTAssertTrue(blackout.restore(8, identity: "monitor"))
            XCTAssertEqual(store.load(), .absent, "Explicit restore removes a valid empty journal")
            XCTAssertTrue(blackout.prepare(8, identity: "monitor"))
            XCTAssertTrue(blackout.apply(8, identity: "monitor", factor: 0, verify: true))
            XCTAssertTrue(blackout.restore(8, identity: "monitor"))
            XCTAssertEqual(gamma, original)
            XCTAssertEqual(store.load(), .absent)
        }
    }

    func testEmptyJournalDeleteFailureKeepsRecoveryPendingUntilRetry() throws {
        for failGamma in [false, true] {
            let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
            let physicalDirectory = directory.appendingPathComponent("physical"), gammaDirectory = directory.appendingPathComponent("gamma")
            try FileManager.default.createDirectory(at: physicalDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: gammaDirectory, withIntermediateDirectories: true)
            let failedDirectory = failGamma ? gammaDirectory : physicalDirectory
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: failedDirectory.path)
                try? FileManager.default.removeItem(at: directory)
            }
            let physicalStore = FileBrightnessRecovery(url: physicalDirectory.appendingPathComponent("brightness.json"))
            let gammaStore = FileGammaRecovery(url: gammaDirectory.appendingPathComponent("gamma.json"))
            let empty = Data("{}".utf8)
            try empty.write(to: physicalStore.url); try empty.write(to: gammaStore.url)
            var writes = 0
            let blackout = ExternalBlackout(read: { [original] _ in original }, write: { _, _ in
                writes += 1; return true
            }, recovery: gammaStore)
            let brightness = NativeBrightness(displays: { [1] }, read: { _ in 0.8 }, write: { _, _ in
                writes += 1; return true
            }, recovery: physicalStore, blackout: blackout)
            XCTAssertTrue(brightness.hasPendingRestore)
            XCTAssertEqual(try Data(contentsOf: physicalStore.url), empty, "Loading must not delete a journal")
            XCTAssertEqual(try Data(contentsOf: gammaStore.url), empty)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: failedDirectory.path)
            let failedURL = failGamma ? gammaStore.url : physicalStore.url
            guard !FileManager.default.isDeletableFile(atPath: failedURL.path) else {
                throw XCTSkip("This user bypasses temporary-directory write permissions")
            }
            XCTAssertFalse(brightness.restore())
            XCTAssertTrue(brightness.hasPendingRestore)
            XCTAssertEqual(try Data(contentsOf: failedURL), empty)
            XCTAssertEqual(writes, 0)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: failedDirectory.path)
            XCTAssertTrue(brightness.restore())
            XCTAssertFalse(brightness.hasPendingRestore)
            XCTAssertEqual(physicalStore.load(), .absent)
            XCTAssertEqual(gammaStore.load(), .absent)
            XCTAssertEqual(writes, 0)
        }
    }
}
