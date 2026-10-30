import XCTest
@testable import SoftLock

private final class IndividualBrightnessMemory: BrightnessRecoveryStore {
    var values: [String: Float] = [:]
    var writable = true
    func load() -> DisplayRecoveryLoad<[String: Float]> { values.isEmpty ? .absent : .loaded(values) }
    func save(_ next: [String: Float]) -> Bool {
        guard writable else { return false }
        values = next; return true
    }
}
private final class IndividualGammaMemory: GammaRecoveryStore {
    var values: [String: DisplayGammaTable] = [:]
    var writable = true
    func load() -> DisplayRecoveryLoad<[String: DisplayGammaTable]> { values.isEmpty ? .absent : .loaded(values) }
    func save(_ next: [String: DisplayGammaTable]) -> Bool {
        guard writable else { return false }
        values = next; return true
    }
}

final class IndividualDisplayTests: XCTestCase {
    private func command(_ id: UInt32, _ off: Bool, key: String? = nil) -> DisplayPowerCommand {
        DisplayPowerCommand(displayID: id, identity: key ?? String(id), off: off)
    }
    func testGammaOnlyBlackoutTransfersToGlobalDimAndLockHold() {
        let original = DisplayGammaTable(red: [0, 1], green: [0, 1], blue: [0, 1])
        var gamma = original, hardware: Float = 0.7
        let gammaStore = IndividualGammaMemory(), brightnessStore = IndividualBrightnessMemory()
        let blackout = ExternalBlackout(read: { _ in gamma }, write: { _, next in gamma = next; return true }, recovery: gammaStore)
        let driver = NativeBrightness(displays: { [1, 2] }, read: { $0 == 2 ? hardware : nil },
            write: { id, value in guard id == 2 else { return false }; hardware = value; return true },
            recovery: brightnessStore, blackout: blackout, blackoutEligible: { $0 == 1 })
        XCTAssertEqual(driver.controlDisplay(command(1, true)), .off)
        XCTAssertEqual(gamma, original.scaled(0))
        gamma = original
        XCTAssertEqual(driver.dim(), 1)
        XCTAssertEqual(gamma, original.scaled(0), "Takeover enforces the existing gamma record")
        XCTAssertEqual(hardware, 0)
        for _ in 0..<3 {
            gamma = original
            _ = driver.maintainDim()
            XCTAssertEqual(gamma, original.scaled(0))
        }
        gamma = original
        XCTAssertTrue(driver.holdDim())
        XCTAssertEqual(gamma, original.scaled(0))
        XCTAssertTrue(driver.restore())
        XCTAssertEqual(gamma, original)
        XCTAssertEqual(hardware, 0.7)
        XCTAssertTrue(gammaStore.values.isEmpty)
        XCTAssertTrue(brightnessStore.values.isEmpty)
    }
    func testGammaOnlyGlobalMaintenanceRetainsRecoveryAcrossReconnect() {
        let original = DisplayGammaTable(red: [0, 1], green: [0, 1], blue: [0, 1])
        var gamma = original, online: [UInt32] = [1]
        let store = IndividualGammaMemory()
        let blackout = ExternalBlackout(read: { _ in gamma }, write: { _, value in gamma = value; return true }, recovery: store)
        let driver = NativeBrightness(displays: { online }, read: { _ in nil }, identity: { _ in "A" }, blackout: blackout)
        XCTAssertEqual(driver.controlDisplay(command(1, true, key: "A")), .off)
        _ = driver.dim()
        XCTAssertTrue(driver.holdDim(), "Gamma-only ownership also survives login-window hold")
        online = []
        _ = driver.maintainDim()
        XCTAssertFalse(driver.restore())
        XCTAssertNotNil(store.values["A"])
        online = [9]
        XCTAssertTrue(driver.restore())
        XCTAssertEqual(gamma, original)
        XCTAssertTrue(store.values.isEmpty)
    }
    func testEachButtonChangesOnlyItsOwnDisplayAndRestoresItsOriginal() {
        var values: [UInt32: Float] = [1: 0.7, 2: 0.45, 3: 0.9]
        let store = IndividualBrightnessMemory()
        let driver = NativeBrightness(displays: { [1, 2, 3] }, read: { values[$0] },
            write: { values[$0] = $1; return true }, recovery: store, blackoutEligible: { _ in false })
        XCTAssertEqual(driver.controlDisplay(command(2, true)), .off)
        XCTAssertEqual(values, [1: 0.7, 2: 0, 3: 0.9])
        XCTAssertEqual(driver.controlDisplay(command(1, true)), .off)
        XCTAssertEqual(driver.controlDisplay(command(2, true)), .off)
        XCTAssertEqual(store.values["2"], 0.45)
        XCTAssertEqual(driver.controlDisplay(command(2, false)), .on)
        XCTAssertEqual(values, [1: 0, 2: 0.45, 3: 0.9])
        XCTAssertEqual(store.values, ["1": 0.7])
        XCTAssertTrue(driver.restore())
        XCTAssertEqual(values, [1: 0.7, 2: 0.45, 3: 0.9])
    }
    func testMaintenanceNeverDimsNewDisplaysOrAReusedID() {
        var identities: [UInt32: String] = [1: "A", 2: "B"]
        var values: [UInt32: Float] = [1: 0.8, 2: 0.6]
        let driver = NativeBrightness(displays: { Array(identities.keys) }, read: { values[$0] },
            write: { values[$0] = $1; return true }, identity: { identities[$0]! }, blackoutEligible: { _ in false })
        XCTAssertEqual(driver.controlDisplay(command(2, true, key: "B")), .off)
        identities[2] = "C"; values[2] = 0.9
        XCTAssertEqual(driver.controlDisplay(command(2, true, key: "B")), .unsupported)
        XCTAssertTrue(driver.maintainIndividualDisplays().isEmpty)
        XCTAssertEqual(values[2], 0.9)
        identities[5] = "B"; values[5] = 0.4
        XCTAssertTrue(driver.maintainIndividualDisplays().isEmpty)
        XCTAssertEqual(values[5], 0)
        XCTAssertEqual(values[1], 0.8)
        XCTAssertEqual(values[2], 0.9)
        XCTAssertEqual(driver.controlDisplay(command(5, false, key: "B")), .on)
        XCTAssertEqual(values[5], 0.6)
    }
    func testDuplicateStableIdentityIsRejected() {
        var writes = 0
        let driver = NativeBrightness(displays: { [1, 2] }, read: { _ in 0.5 },
            write: { _, _ in writes += 1; return true }, identity: { _ in "duplicate" }, blackoutEligible: { _ in false })
        XCTAssertEqual(driver.controlDisplay(command(1, true, key: "duplicate")), .unsupported)
        XCTAssertEqual(writes, 0)
    }
    func testExternalGammaOnlyOffAndExactRestorationWithoutReadableBrightness() {
        let original = DisplayGammaTable(red: [0, 0.8, 1], green: [0, 0.6, 0.9], blue: [0, 0.7, 1])
        let store = IndividualGammaMemory()
        var gamma: [UInt32: DisplayGammaTable] = [1: original, 2: original]
        var brightnessWrites = 0
        let blackout = ExternalBlackout(read: { gamma[$0] }, write: { gamma[$0] = $1; return true }, recovery: store)
        let driver = NativeBrightness(displays: { [1, 2] }, read: { _ in nil },
            write: { _, _ in brightnessWrites += 1; return false }, blackout: blackout)
        XCTAssertEqual(driver.controlDisplay(command(2, true)), .off)
        XCTAssertEqual(gamma[2], original.scaled(0))
        XCTAssertEqual(gamma[1], original)
        XCTAssertEqual(brightnessWrites, 0)
        XCTAssertEqual(store.values["2"], original)
        XCTAssertEqual(driver.controlDisplay(command(2, false)), .on)
        XCTAssertEqual(gamma[2], original)
        XCTAssertTrue(store.values.isEmpty)
    }
    func testNoMutationWithoutDurablySavedRecovery() {
        let store = IndividualBrightnessMemory(); store.writable = false
        var writes = 0
        let driver = NativeBrightness(displays: { [1] }, read: { _ in 0.8 },
            write: { _, _ in writes += 1; return true }, recovery: store, blackoutEligible: { _ in false })
        XCTAssertEqual(driver.controlDisplay(command(1, true)), .failed)
        XCTAssertEqual(writes, 0)
        let gamma = DisplayGammaTable(red: [0, 1], green: [0, 1], blue: [0, 1])
        let gammaStore = IndividualGammaMemory(); gammaStore.writable = false
        let blackout = ExternalBlackout(read: { _ in gamma }, write: { _, _ in writes += 1; return true }, recovery: gammaStore)
        let external = NativeBrightness(displays: { [2] }, read: { _ in nil }, blackout: blackout)
        XCTAssertEqual(external.controlDisplay(command(2, true)), .unsupported)
        XCTAssertEqual(writes, 0)
    }
    func testFailedRestoreRetainsJournalAndAllowsRetryWithoutMaintenanceRedimming() {
        let store = IndividualBrightnessMemory()
        var value: Float = 0.8, rejectRestore = false
        let driver = NativeBrightness(displays: { [1] }, read: { _ in value }, write: { _, next in
            if next > 0 && rejectRestore { return false }
            value = next; return true
        }, recovery: store, blackoutEligible: { _ in false })
        XCTAssertEqual(driver.controlDisplay(command(1, true)), .off)
        rejectRestore = true
        XCTAssertEqual(driver.controlDisplay(command(1, false)), .recoveryNeeded)
        XCTAssertEqual(store.values["1"], 0.8)
        rejectRestore = false
        XCTAssertEqual(driver.controlDisplay(command(1, false)), .on)
        XCTAssertTrue(driver.maintainIndividualDisplays().isEmpty)
        XCTAssertEqual(value, 0.8)
        XCTAssertTrue(store.values.isEmpty)
    }
    func testRestartRecoversIndividualOffAndGlobalLockTakesOverWithoutLosingOriginal() {
        var values: [UInt32: Float] = [1: 0.8, 2: 0.5]
        let store = IndividualBrightnessMemory()
        func make() -> NativeBrightness {
            NativeBrightness(displays: { [1, 2] }, read: { values[$0] },
                write: { values[$0] = $1; return true }, recovery: store, blackoutEligible: { _ in false })
        }
        var driver = make()
        XCTAssertEqual(driver.controlDisplay(command(1, true)), .off)
        driver = make()
        XCTAssertTrue(driver.restore())
        XCTAssertEqual(values[1], 0.8)
        XCTAssertEqual(driver.controlDisplay(command(2, true)), .off)
        XCTAssertEqual(driver.dim(), 2)
        XCTAssertEqual(driver.controlDisplay(command(2, false)), .busy)
        XCTAssertTrue(driver.restore())
        XCTAssertEqual(values, [1: 0.8, 2: 0.5])
        XCTAssertTrue(driver.maintainIndividualDisplays().isEmpty)
    }
    func testFailedOffRollsBackOnlyTheSelectedDisplay() {
        var values: [UInt32: Float] = [1: 0.8, 2: 0.6]
        let store = IndividualBrightnessMemory()
        let driver = NativeBrightness(displays: { [1, 2] }, read: { values[$0] }, write: { id, value in
            values[id] = value
            return value != 0 // Simulate a partially applied write followed by failure.
        }, recovery: store, blackoutEligible: { _ in false })
        XCTAssertEqual(driver.controlDisplay(command(2, true)), .failed)
        XCTAssertEqual(values, [1: 0.8, 2: 0.6])
        XCTAssertTrue(store.values.isEmpty)
        XCTAssertTrue(driver.maintainIndividualDisplays().isEmpty)
    }
    func testGammaOnlyRecoverySurvivesRestartAndReconnect() {
        let original = DisplayGammaTable(red: [0, 0.8], green: [0, 0.7], blue: [0, 1])
        let store = IndividualGammaMemory()
        var gamma = original
        func make(_ id: UInt32) -> NativeBrightness {
            let blackout = ExternalBlackout(read: { _ in gamma }, write: { _, next in gamma = next; return true }, recovery: store)
            return NativeBrightness(displays: { [id] }, read: { _ in nil }, identity: { _ in "monitor" }, blackout: blackout)
        }
        var driver = make(2)
        XCTAssertEqual(driver.controlDisplay(command(2, true, key: "monitor")), .off)
        XCTAssertEqual(gamma, original.scaled(0))
        driver = make(9)
        XCTAssertTrue(driver.restore())
        XCTAssertEqual(gamma, original)
        XCTAssertTrue(store.values.isEmpty)
    }
    func testWireValidationAndAcknowledgementsAreScopedToTheExactRequest() throws {
        let first = command(1, true), second = command(2, true)
        let wire = try XCTUnwrap(first.wire)
        XCTAssertEqual(DisplayPowerCommand(payload: String(wire.dropFirst("individual:".count))), first)
        XCTAssertNil(DisplayPowerCommand(payload: "bad"))
        XCTAssertNil(command(0, true).wire)
        var controls = IndividualDisplayControls()
        let one = try XCTUnwrap(controls.begin(first, at: 0))
        let two = try XCTUnwrap(controls.begin(second, at: 0))
        XCTAssertTrue(controls.off.isEmpty)
        XCTAssertNil(controls.begin(first, at: 1))
        XCTAssertTrue(controls.receive(.init(message: "individual-off", id: two)))
        XCTAssertEqual(controls.off, ["2"])
        XCTAssertEqual(controls.pending, ["1"])
        XCTAssertTrue(controls.receive(.init(message: "individual-off", id: one)))
        let on = try XCTUnwrap(controls.begin(command(1, false), at: 2))
        XCTAssertFalse(controls.receive(.init(message: "individual-off", id: one)))
        XCTAssertTrue(controls.receive(.init(message: "individual-on", id: on)))
        XCTAssertEqual(controls.off, ["2"])
    }
    func testTimeoutKeepsRecoveryActionAndLateAcknowledgementCanReconcile() throws {
        var controls = IndividualDisplayControls()
        let id = try XCTUnwrap(controls.begin(command(1, true), at: 10))
        controls.expire(at: 18)
        XCTAssertTrue(controls.pending.isEmpty)
        XCTAssertEqual(controls.off, ["1"])
        XCTAssertNotNil(controls.errors["1"])
        XCTAssertTrue(controls.receive(.init(message: "individual-off", id: id)))
        XCTAssertNil(controls.errors["1"])
        let on = try XCTUnwrap(controls.begin(command(1, false), at: 20))
        XCTAssertTrue(controls.receive(.init(message: "individual-recovery-needed", id: on)))
        XCTAssertEqual(controls.off, ["1"])
        controls.reset()
        XCTAssertFalse(controls.receive(.init(message: "individual-on", id: on)))
    }
    func testMaintenanceRecoveryClearsOnlyTheMatchingVerifiedFailure() throws {
        var controls = IndividualDisplayControls(), session = IndividualDisplaySession()
        let off = command(1, true), id = try XCTUnwrap(controls.begin(off, at: 0))
        session.record(off, id: id, outcome: .off)
        XCTAssertTrue(controls.receive(.init(message: DisplayPowerOutcome.off.rawValue, id: id)))
        let failed = session.maintenance(failed: ["1"], verified: [])
        XCTAssertEqual(failed, [.init(message: "individual-maintenance-failed", id: id)])
        XCTAssertTrue(controls.receive(failed[0]))
        XCTAssertNotNil(controls.errors["1"])
        XCTAssertTrue(session.maintenance(failed: [], verified: []).isEmpty, "A disconnect is not verified recovery")
        let recovered = session.maintenance(failed: [], verified: ["1"])
        XCTAssertEqual(recovered, [.init(message: "individual-maintenance-restored", id: id)])
        XCTAssertTrue(controls.receive(recovered[0]))
        XCTAssertNil(controls.errors["1"])
        let onID = try XCTUnwrap(controls.begin(command(1, false), at: 1))
        XCTAssertFalse(controls.receive(recovered[0]), "An old maintenance reply cannot complete a newer On")
        XCTAssertEqual(controls.pending, ["1"])
        XCTAssertTrue(controls.receive(.init(message: DisplayPowerOutcome.on.rawValue, id: onID)))
    }
    func testFailedOnRetriesOnlyItsIdentityAfterReconnectAndPreservesOtherOffDisplay() throws {
        var identities: [UInt32: String] = [1: "A", 2: "B"]
        var values: [UInt32: Float] = [1: 0.8, 2: 0.6], failRestore = false
        let store = IndividualBrightnessMemory()
        let driver = NativeBrightness(displays: { Array(identities.keys) }, read: { values[$0] }, write: { id, value in
            if value > 0 && failRestore { return false }
            values[id] = value; return true
        }, identity: { identities[$0]! }, recovery: store, blackoutEligible: { _ in false })
        var session = IndividualDisplaySession(), controls = IndividualDisplayControls()
        for (id, key) in [(UInt32(1), "A"), (UInt32(2), "B")] {
            let off = command(id, true, key: key), request = try XCTUnwrap(controls.begin(command(id, true, key: key), at: 0))
            let outcome = driver.controlDisplay(off)
            session.record(off, id: request, outcome: outcome)
            XCTAssertTrue(controls.receive(.init(message: outcome.rawValue, id: request)))
        }
        let on = command(1, false, key: "A"), request = try XCTUnwrap(controls.begin(command(1, false, key: "A"), at: 1))
        failRestore = true
        let outcome = driver.controlDisplay(on)
        XCTAssertEqual(outcome, .recoveryNeeded)
        session.record(on, id: request, outcome: outcome)
        XCTAssertTrue(controls.receive(.init(message: outcome.rawValue, id: request)))
        identities[1] = "C"; values[1] = 0.9
        XCTAssertFalse(driver.retryIndividualRestore("A"))
        XCTAssertEqual(values[1], 0.9)
        identities[3] = "A"; values[3] = 0
        failRestore = false
        XCTAssertTrue(driver.retryIndividualRestore("A"))
        let reply = try XCTUnwrap(session.recovered("A"))
        XCTAssertEqual(reply, .init(message: DisplayPowerOutcome.on.rawValue, id: request))
        XCTAssertTrue(controls.receive(reply))
        XCTAssertEqual(values[3], 0.8)
        XCTAssertEqual(values[2], 0)
        XCTAssertEqual(controls.off, ["B"])
        XCTAssertEqual(store.values, ["B": 0.6])
    }
    func testFailedOffRollbackRecoveryHasDistinctReplyAndCannotCompleteNewRequest() throws {
        var value: Float = 0.8, allowRestore = false
        let driver = NativeBrightness(displays: { [1] }, read: { _ in value }, write: { _, next in
            if next == 0 { value = next; return false }
            if allowRestore { value = next; return true }; return false
        }, blackoutEligible: { _ in false })
        var session = IndividualDisplaySession(), controls = IndividualDisplayControls()
        let off = command(1, true), request = try XCTUnwrap(controls.begin(command(1, true), at: 0))
        let outcome = driver.controlDisplay(off)
        XCTAssertEqual(outcome, .recoveryNeeded)
        session.record(off, id: request, outcome: outcome)
        XCTAssertTrue(controls.receive(.init(message: outcome.rawValue, id: request)))
        allowRestore = true
        XCTAssertTrue(driver.retryIndividualRestore("1"))
        let reply = try XCTUnwrap(session.recovered("1"))
        XCTAssertEqual(reply, .init(message: DisplayPowerOutcome.rollbackRestored.rawValue, id: request))
        XCTAssertTrue(controls.receive(reply))
        XCTAssertTrue(controls.off.isEmpty)
        XCTAssertEqual(value, 0.8)
        XCTAssertNotNil(controls.errors["1"], "Rollback success must retain the failed-Off explanation")
        _ = controls.begin(command(1, true), at: 2)
        XCTAssertFalse(controls.receive(reply))
        session.record(off, id: request, outcome: .recoveryNeeded)
        session.reset()
        XCTAssertNil(session.recovered("1"), "Global ownership cancels individual retries")
    }

    func testActualMaintenanceFailureRecoversOnlyAfterSuccessfulVerification() {
        let original = DisplayGammaTable(red: [0, 1], green: [0, 1], blue: [0, 1])
        var gamma = original, writable = true
        let blackout = ExternalBlackout(read: { _ in gamma }, write: { _, table in
            guard writable else { return false }; gamma = table; return true
        }, recovery: IndividualGammaMemory())
        let driver = NativeBrightness(displays: { [1] }, read: { _ in nil }, blackout: blackout)
        var session = IndividualDisplaySession()
        session.record(command(1, true), id: 9, outcome: driver.controlDisplay(command(1, true)))
        gamma = original; writable = false
        XCTAssertEqual(session.maintenance(failed: driver.maintainIndividualDisplays(), verified: driver.verifiedIndividualMaintenance),
                       [.init(message: "individual-maintenance-failed", id: 9)])
        XCTAssertTrue(driver.verifiedIndividualMaintenance.isEmpty)
        writable = true
        XCTAssertEqual(session.maintenance(failed: driver.maintainIndividualDisplays(), verified: driver.verifiedIndividualMaintenance),
                       [.init(message: "individual-maintenance-restored", id: 9)])
        XCTAssertEqual(gamma, original.scaled(0))
        XCTAssertTrue(session.maintenance(failed: driver.maintainIndividualDisplays(), verified: driver.verifiedIndividualMaintenance).isEmpty)
    }

    func testDisconnectedOnStopsRedimmingAndRetriesIdentityWithoutTouchingReusedID() {
        var identities: [UInt32: String] = [1: "A"]
        var values: [UInt32: Float] = [1: 0.8]
        let driver = NativeBrightness(displays: { Array(identities.keys) }, read: { values[$0] },
            write: { values[$0] = $1; return true }, identity: { identities[$0]! }, blackoutEligible: { _ in false })
        XCTAssertEqual(driver.controlDisplay(command(1, true, key: "A")), .off)
        identities[1] = "B"; values[1] = 0.9
        let on = command(1, false, key: "A")
        XCTAssertEqual(driver.controlDisplay(on), .recoveryNeeded)
        XCTAssertEqual(values[1], 0.9)
        identities[3] = "A"; values[3] = 0.4
        XCTAssertTrue(driver.maintainIndividualDisplays().isEmpty)
        XCTAssertEqual(values[3], 0.4, "An accepted On must release blackout intent before A reconnects")
        XCTAssertTrue(driver.retryIndividualRestore("A"))
        XCTAssertEqual(values[3], 0.8)
        XCTAssertEqual(values[1], 0.9)
    }
    func testStaleIDOnRestoresOwnedMonitorAtItsNewIDAndRejectsUnownedIdentity() {
        var identities: [UInt32: String] = [1: "A"]
        var values: [UInt32: Float] = [1: 0.8]
        let driver = NativeBrightness(displays: { Array(identities.keys) }, read: { values[$0] },
            write: { values[$0] = $1; return true }, identity: { identities[$0]! }, blackoutEligible: { _ in false })
        XCTAssertEqual(driver.controlDisplay(command(1, true, key: "A")), .off)
        identities = [1: "B", 3: "A"]; values = [1: 0.9, 3: 0]
        XCTAssertEqual(driver.controlDisplay(command(1, false, key: "A")), .on)
        XCTAssertEqual(values, [1: 0.9, 3: 0.8])
        XCTAssertEqual(driver.controlDisplay(command(1, false, key: "unowned")), .unsupported)
        XCTAssertEqual(values, [1: 0.9, 3: 0.8])
        values[3] = 0.5
        XCTAssertTrue(driver.maintainIndividualDisplays().isEmpty)
        XCTAssertEqual(values[3], 0.5)
    }

}
