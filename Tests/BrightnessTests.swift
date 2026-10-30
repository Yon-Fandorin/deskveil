import XCTest
@testable import SoftLock

private enum NativeBrightnessStub {
    static var value: Float = 0.8
    static var ignoreWrite = false
    static var readFails = false
    static var identity = "original"
    static var writes = 0
}

final class BrightnessTests: XCTestCase {
    func testNativeGetterCannotAuthorizeAWriteAfterItsDisplayIdentityChanges() {
        NativeBrightnessStub.identity = "original"; NativeBrightnessStub.writes = 0
        let get: NativeBrightness.Get = { _, value in
            value.pointee = 0.8; NativeBrightnessStub.identity = "replacement"; return 0
        }
        let set: NativeBrightness.SetBrightness = { _, _ in NativeBrightnessStub.writes += 1; return 0 }
        let brightness = NativeBrightness(displays: { [1] }, identity: { _ in NativeBrightnessStub.identity },
            blackoutEligible: { _ in false }, nativeGet: get, nativeSet: set)
        XCTAssertEqual(brightness.controlDisplay(.init(displayID: 1, identity: "original", off: true)), .unsupported)
        XCTAssertEqual(NativeBrightnessStub.writes, 0)
    }
    private final class MemoryRecovery: BrightnessRecoveryStore {
        var values: [String: Float] = [:]
        var writable = true
        var readable = true
        var onSave: (() -> Void)?
        func load() -> DisplayRecoveryLoad<[String: Float]> { readable ? (values.isEmpty ? .absent : .loaded(values)) : .failed }
        func save(_ values: [String: Float]) -> Bool {
            guard writable else { return false }
            self.values = values; onSave?(); return true
        }
    }

    func testIdentityReplacedDuringReadCannotDimTheReplacement() {
        var identity = "original", writes = 0
        let brightness = NativeBrightness(displays: { [1] }, read: { _ in identity = "replacement"; return 0.8 },
            write: { _, _ in writes += 1; return true }, identity: { _ in identity }, blackoutEligible: { _ in false })
        XCTAssertEqual(brightness.controlDisplay(.init(displayID: 1, identity: "original", off: true)), .unsupported)
        XCTAssertEqual(writes, 0)
    }

    func testIdentityReplacedDuringDurableSaveRetainsOriginalWithoutWrongDisplayWrite() {
        let recovery = MemoryRecovery(); var identity = "original", writes = 0
        recovery.onSave = { identity = "replacement" }
        let brightness = NativeBrightness(displays: { [1] }, read: { _ in 0.8 },
            write: { _, _ in writes += 1; return true }, identity: { _ in identity }, recovery: recovery,
            blackoutEligible: { _ in false })
        XCTAssertEqual(brightness.controlDisplay(.init(displayID: 1, identity: "original", off: true)), .recoveryNeeded)
        XCTAssertEqual(writes, 0); XCTAssertEqual(recovery.values["original"], 0.8)
        recovery.onSave = nil
        XCTAssertFalse(brightness.restore()); XCTAssertEqual(writes, 0)
        identity = "original"
        XCTAssertTrue(brightness.restore()); XCTAssertEqual(writes, 1); XCTAssertTrue(recovery.values.isEmpty)
    }

    func testEachDisplayRestoresItsOwnBrightnessAndUnsupportedDisplaysStayUntouched() {
        var values: [UInt32: Float] = [1: 0.8, 2: 0.9, 3: 0.4, 4: 0.7]
        let brightness = NativeBrightness(displays: { [1, 2, 3, 4] }, read: { $0 == 4 ? nil : values[$0] },
            write: { values[$0] = $1; return true })
        XCTAssertEqual(brightness.dim(), 3)
        XCTAssertEqual(brightness.unsupportedDisplays, 1)
        XCTAssertEqual(values[4], 0.7)
        XCTAssertTrue(brightness.restore())
        XCTAssertEqual(values, [1: 0.8, 2: 0.9, 3: 0.4, 4: 0.7])
    }

    func testDisconnectedDisplayRecoverySurvivesRestartWithoutTouchingReusedID() {
        let recovery = MemoryRecovery()
        var identity = "first", value: Float = 0.9
        var brightness: NativeBrightness? = NativeBrightness(displays: { [2] }, read: { _ in value },
            write: { _, next in value = next; return true }, identity: { _ in identity }, recovery: recovery)
        XCTAssertEqual(brightness?.dim(), 1)
        identity = "replacement"; value = 0.4
        XCTAssertFalse(brightness!.restore())
        XCTAssertEqual(value, 0.4)
        XCTAssertEqual(recovery.values["first"], 0.9)
        brightness = nil
        // The original monitor reconnects with a different CGDisplayID.
        identity = "first"; value = 0
        let restarted = NativeBrightness(displays: { [8] }, read: { _ in value },
            write: { _, next in value = next; return true }, identity: { _ in identity }, recovery: recovery)
        XCTAssertTrue(restarted.restore())
        XCTAssertEqual(value, 0.9)
        XCTAssertTrue(recovery.values.isEmpty)
    }

    func testMissingDurableSavePreventsAnyBrightnessWrite() {
        let recovery = MemoryRecovery(); recovery.writable = false
        var writes = 0
        let brightness = NativeBrightness(displays: { [2] }, read: { _ in 0.9 },
            write: { _, _ in writes += 1; return true }, recovery: recovery)
        XCTAssertEqual(brightness.dim(), 0)
        XCTAssertEqual(writes, 0)
    }

    func testRecoveryRecordIsKeptUntilActualBrightnessIsConfirmed() {
        let recovery = MemoryRecovery()
        var value: Float = 0.9, verified = false
        let brightness = NativeBrightness(displays: { [2] }, read: { _ in value },
            write: { _, next in value = next; return true }, recovery: recovery, verify: { _, _ in verified })
        XCTAssertEqual(brightness.dim(), 0)
        XCTAssertFalse(brightness.restore())
        XCTAssertFalse(recovery.values.isEmpty)
        verified = true
        XCTAssertTrue(brightness.restore())
        XCTAssertEqual(value, 0.9)
        XCTAssertTrue(recovery.values.isEmpty)
    }

    func testNativeRestoreKeepsRecoveryUntilGetterConfirmsTheWrittenValue() {
        NativeBrightnessStub.value = 0.8
        NativeBrightnessStub.ignoreWrite = false
        NativeBrightnessStub.readFails = false
        let recovery = MemoryRecovery()
        let get: NativeBrightness.Get = { _, value in
            guard !NativeBrightnessStub.readFails else { return -1 }
            value.pointee = NativeBrightnessStub.value; return 0
        }
        let set: NativeBrightness.SetBrightness = { _, value in
            if !NativeBrightnessStub.ignoreWrite { NativeBrightnessStub.value = value }
            return 0
        }
        let brightness = NativeBrightness(displays: { [1] }, recovery: recovery, nativeGet: get, nativeSet: set)
        XCTAssertEqual(brightness.dim(), 1)
        XCTAssertEqual(NativeBrightnessStub.value, 0)
        NativeBrightnessStub.ignoreWrite = true
        XCTAssertFalse(brightness.restore())
        XCTAssertEqual(recovery.values["1"], 0.8, "A write acknowledgement alone cannot discard recovery")
        NativeBrightnessStub.ignoreWrite = false
        NativeBrightnessStub.readFails = true
        XCTAssertFalse(brightness.restore())
        XCTAssertEqual(recovery.values["1"], 0.8)
        NativeBrightnessStub.readFails = false
        XCTAssertTrue(brightness.restore())
        XCTAssertEqual(NativeBrightnessStub.value, 0.8)
        XCTAssertTrue(recovery.values.isEmpty)
    }

    func testFileRecoveryIsRemovedOnlyAfterRestoration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileBrightnessRecovery(url: directory.appendingPathComponent("brightness.json"))
        var value: Float = 0.9
        var first: NativeBrightness? = NativeBrightness(displays: { [2] }, read: { _ in value },
            write: { _, next in value = next; return true }, identity: { _ in "monitor" }, recovery: store)
        XCTAssertEqual(first?.dim(), 1)
        first = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
        let next = NativeBrightness(displays: { [3] }, read: { _ in value },
            write: { _, next in value = next; return true }, identity: { _ in "monitor" }, recovery: store)
        XCTAssertTrue(next.restore())
        XCTAssertEqual(value, 0.9)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testFileRecoveryDistinguishesAbsentEmptyInvalidAndUnreadable() throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileBrightnessRecovery(url: directory.appendingPathComponent("brightness.json"))
        XCTAssertEqual(store.load(), .absent)
        try Data("{}".utf8).write(to: store.url)
        XCTAssertEqual(store.load(), .loaded([:]))
        for text in ["{", "[]", "{\"monitor\":0.8,\"\":0.4}", "{\"monitor\":0.8,\"invalid\":1.1}"] {
            let data = Data(text.utf8)
            try data.write(to: store.url)
            XCTAssertEqual(store.load(), .failed, text)
            XCTAssertEqual(try Data(contentsOf: store.url), data)
        }
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)
        XCTAssertEqual(store.load(), .failed, "A present directory cannot be an absent journal")
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: directory.appendingPathComponent("missing.json"))
        XCTAssertEqual(store.load(), .failed, "A dangling journal link is a read failure")
    }

    func testUnreadableCrashJournalBlocksMutationAndFalseRestoreUntilOriginalCanBeLoaded() throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileBrightnessRecovery(url: directory.appendingPathComponent("brightness.json"))
        var value: Float = 0.8, writes = 0, verified = true
        func driver() -> NativeBrightness {
            NativeBrightness(displays: { [3] }, read: { _ in value }, write: { _, next in
                writes += 1; value = next; return true
            }, identity: { _ in "monitor" }, recovery: store, verify: { _, _ in verified }, blackoutEligible: { _ in false })
        }
        var original: NativeBrightness? = driver()
        XCTAssertEqual(original?.controlDisplay(.init(displayID: 3, identity: "monitor", off: true)), .off)
        XCTAssertEqual(value, 0)
        let originalData = try Data(contentsOf: store.url)
        original = nil
        let damaged = Data("{\"monitor\":".utf8)
        try damaged.write(to: store.url)
        let replacement = driver()
        writes = 0
        XCTAssertTrue(replacement.hasPendingRestore)
        XCTAssertFalse(replacement.restore())
        XCTAssertEqual(replacement.dim(), 0)
        XCTAssertEqual(replacement.controlDisplay(.init(displayID: 3, identity: "monitor", off: true)), .recoveryNeeded)
        XCTAssertEqual(replacement.controlDisplay(.init(displayID: 3, identity: "monitor", off: false)), .recoveryNeeded)
        XCTAssertFalse(replacement.retryIndividualRestore("monitor"))
        XCTAssertFalse(replacement.holdDim())
        XCTAssertEqual(replacement.maintainDim(), 0)
        XCTAssertTrue(replacement.maintainIndividualDisplays().isEmpty)
        XCTAssertTrue(replacement.advanceTransitions().isEmpty)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(try Data(contentsOf: store.url), damaged, "Unknown recovery must never be replaced with the current zero")

        try FileManager.default.removeItem(at: store.url)
        XCTAssertFalse(replacement.restore(), "Disappearance does not verify an unknown original")
        XCTAssertTrue(replacement.hasPendingRestore)
        try originalData.write(to: store.url)
        verified = false
        XCTAssertFalse(replacement.restore())
        XCTAssertEqual(try Data(contentsOf: store.url), originalData)
        XCTAssertTrue(replacement.hasPendingRestore)
        verified = true
        XCTAssertTrue(replacement.restore())
        XCTAssertEqual(value, 0.8)
        XCTAssertFalse(replacement.hasPendingRestore)
        XCTAssertEqual(store.load(), .absent)
        value = 0.6
        XCTAssertEqual(replacement.controlDisplay(.init(displayID: 3, identity: "monitor", off: true)), .off)
        XCTAssertEqual(store.load(), .loaded(["monitor": 0.6]))
        XCTAssertTrue(replacement.restore())
        XCTAssertEqual(value, 0.6)
    }

    func testInitiallyAbsentOrEmptyJournalCanStartAndRestoreNormally() throws {
        for emptyFile in [false, true] {
            let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = FileBrightnessRecovery(url: directory.appendingPathComponent("brightness.json"))
            if emptyFile { try Data("{}".utf8).write(to: store.url) }
            var value: Float = 0.7
            let brightness = NativeBrightness(displays: { [1] }, read: { _ in value },
                write: { _, next in value = next; return true }, recovery: store, blackoutEligible: { _ in false })
            XCTAssertEqual(brightness.hasPendingRestore, emptyFile)
            XCTAssertTrue(brightness.restore())
            XCTAssertEqual(store.load(), .absent, "Explicit restore removes a valid empty journal")
            XCTAssertEqual(brightness.dim(), 1)
            XCTAssertTrue(brightness.restore())
            XCTAssertEqual(value, 0.7)
            XCTAssertEqual(store.load(), .absent)
        }
    }

    func testDimRollbackFailureUsesCurrentDimIdentityAndShowsRecoveryInstruction() {
        var writesAllowed = true
        let brightness = NativeBrightness(displays: { [1] }, read: { _ in 0.75 }, write: { _,_ in writesAllowed })
        _ = brightness.dim(duration: 0.6, at: 60)
        writesAllowed = false
        let results = brightness.advanceTransitions(at: 60.3)
        let replies = brightnessTransitionReplies(results, brightness: brightness, dimID: 41, restoreID: 0)
        XCTAssertEqual(replies, [.init(message: "dimmed:0", id: 41), .init(message: "restore-failed", id: 41)])
        let issue = AppDelegate.dimFailureIssue(replies[1], expectedID: 41, emergencyLabel: "⌃⇧Z")
        XCTAssertTrue(issue?.contains("⌃⇧Z") == true)
        XCTAssertTrue(issue?.contains(L10n.text("화면 복원에 실패했습니다. %@로 긴급 해제하고, 계속 어두우면 DeskVeil을 다시 실행해주세요.", "⌃⇧Z")) == true)
        XCTAssertNil(AppDelegate.dimFailureIssue(replies[1], expectedID: 42, emergencyLabel: "⌃⇧Z"))
    }

    func testSuccessfulDimRecoveryDoesNotReportAnEarlierRollbackFailure() {
        var writesAllowed = true
        let brightness = NativeBrightness(displays: { [1] }, read: { _ in 0.75 }, write: { _,_ in writesAllowed })
        _ = brightness.dim(duration: 0.6, at: 60)
        writesAllowed = false
        let results = brightness.advanceTransitions(at: 60.3)
        writesAllowed = true
        XCTAssertEqual(brightnessTransitionReplies(results, brightness: brightness, dimID: 41, restoreID: 0),
                       [.init(message: "dimmed:0", id: 41)])
    }

    func testHoldDimStopsTransitionWithoutLosingOriginalBrightness() {
        var value: Float = 0.8
        let brightness = NativeBrightness(displays: { [1] }, read: { _ in value },
            write: { _, next in value = next; return true })
        brightness.dim(duration: 0.3, at: 10)
        brightness.advanceTransitions(at: 10.1)
        XCTAssertTrue(brightness.holdDim())
        XCTAssertEqual(value, 0)
        XCTAssertFalse(brightness.transitioning)
        XCTAssertTrue(brightness.restore())
        XCTAssertEqual(value, 0.8)
    }

    func testDimAndRestoreProgressWithoutAmbientMaintenanceCancellingFade() {
        var value: Float = 0.8
        let brightness = NativeBrightness(displays: { [1] }, read: { _ in value },
                                          write: { _, next in value = next; return true })
        XCTAssertEqual(brightness.dim(duration: 0.3, at: 10), 1)
        XCTAssertEqual(value, 0.8)
        XCTAssertTrue(brightness.transitioning)
        brightness.advanceTransitions(at: 10.075)
        let first = value
        XCTAssertGreaterThan(first, 0)
        XCTAssertLessThan(first, 0.8)
        brightness.maintainDim()
        XCTAssertEqual(value, first, "Ambient maintenance must not jump to zero during a fade")
        brightness.advanceTransitions(at: 10.15)
        XCTAssertLessThan(value, first)
        brightness.advanceTransitions(at: 10.3)
        XCTAssertEqual(value, 0)
        XCTAssertFalse(brightness.transitioning)
        value = 0.2 // Simulate ambient brightness changing while dimmed.
        brightness.maintainDim()
        XCTAssertEqual(value, 0)
        XCTAssertTrue(brightness.restore(duration: 0.3, at: 11))
        XCTAssertEqual(value, 0)
        brightness.advanceTransitions(at: 11.15)
        XCTAssertGreaterThan(value, 0)
        XCTAssertLessThan(value, 0.8)
        XCTAssertEqual(brightness.advanceTransitions(at: 11.3), [.restored])
        XCTAssertEqual(value, 0.8)
        XCTAssertFalse(brightness.transitioning)
        brightness.maintainDim()
        XCTAssertEqual(value, 0.8, "Maintenance must stop after restoration")
    }

    func testRelockReversesRestoreWithoutSavingAnIntermediateOriginal() {
        var value: Float = 0.65
        let brightness = NativeBrightness(displays: { [1] }, read: { _ in value },
                                          write: { _, next in value = next; return true })
        brightness.dim()
        brightness.restore(duration: 0.6, at: 30)
        brightness.advanceTransitions(at: 30.3)
        let partial = value
        XCTAssertEqual(brightness.dim(duration: 0.6, at: 30.3), 1)
        brightness.advanceTransitions(at: 30.6)
        XCTAssertLessThan(value, partial)
        brightness.advanceTransitions(at: 31)
        XCTAssertEqual(value, 0)
        XCTAssertTrue(brightness.restore())
        XCTAssertEqual(value, 0.65)
    }

    func testEmergencyRestoreCancelsAnimationImmediately() {
        var value: Float = 0.6
        let brightness = NativeBrightness(displays: { [1] }, read: { _ in value },
                                          write: { _, next in value = next; return true })
        brightness.dim(duration: 0.6, at: 40)
        brightness.advanceTransitions(at: 40.2)
        XCTAssertTrue(brightness.restore())
        XCTAssertEqual(value, 0.6)
        XCTAssertFalse(brightness.transitioning)
        brightness.advanceTransitions(at: 41)
        XCTAssertEqual(value, 0.6)
    }

    func testFailedAnimatedRestoreRetainsOriginalForImmediateRetry() {
        var value: Float = 0.8
        var rejectRestore = false
        let brightness = NativeBrightness(displays: { [1] }, read: { _ in value },
            write: { _, next in
                if rejectRestore { return false }
                value = next
                return true
            })
        brightness.dim()
        XCTAssertTrue(brightness.restore(duration: 0.6, at: 50))
        rejectRestore = true
        XCTAssertEqual(brightness.advanceTransitions(at: 50.3), [.restoreFailed])
        XCTAssertFalse(brightness.transitioning)
        rejectRestore = false
        XCTAssertTrue(brightness.restore())
        XCTAssertEqual(value, 0.8)
    }

    func testRepeatDimKeepsOriginalAndNextLockGetsNewBrightness() {
        var value: Float = 0.65
        let brightness = NativeBrightness(displays: { [1] }, read: { _ in value },
                                          write: { _, next in value = next; return true })
        XCTAssertEqual(brightness.dim(), 1)
        XCTAssertEqual(value, 0)
        XCTAssertEqual(brightness.dim(), 1)
        XCTAssertTrue(brightness.restore())
        XCTAssertEqual(value, 0.65)
        value = 0.35
        XCTAssertEqual(brightness.dim(), 1)
        XCTAssertTrue(brightness.restore())
        XCTAssertEqual(value, 0.35)
    }

    func testRelockAfterPartialRestoreFailureDimsAndPreservesOriginal() {
        var value: Float = 0.8
        var writable = true
        let brightness = NativeBrightness(displays: { [1] }, read: { _ in value },
            write: { _, next in
                guard writable else { return false }
                value = next; return true
            })
        brightness.dim()
        brightness.restore(duration: 0.6, at: 10)
        brightness.advanceTransitions(at: 10.3)
        XCTAssertGreaterThan(value, 0)
        XCTAssertLessThan(value, 0.8)
        writable = false
        XCTAssertEqual(brightness.advanceTransitions(at: 10.6), [.restoreFailed])
        writable = true
        XCTAssertEqual(brightness.dim(duration: 0.3, at: 11), 1)
        brightness.advanceTransitions(at: 11.3)
        XCTAssertEqual(value, 0)
        XCTAssertTrue(brightness.restore())
        XCTAssertEqual(value, 0.8)
    }

}
