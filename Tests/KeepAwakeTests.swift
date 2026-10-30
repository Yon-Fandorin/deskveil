import XCTest
import IOKit.pwr_mgt
@testable import SoftLock

private final class FakeWakeAssertions: WakeAssertionDriver {
    var created: [String] = []
    var live: Set<IOPMAssertionID> = []
    var released: [IOPMAssertionID] = []
    var failAt: Int?
    var renewals: [IOPMAssertionID] = []
    var renewalFails = false
    func create(_ type: String, timeout: TimeInterval) throws -> IOPMAssertionID {
        XCTAssertEqual(timeout, KeepAwakeController.leaseDuration)
        created.append(type)
        if created.count == failAt { throw NSError(domain: "Test", code: 1) }
        let id = IOPMAssertionID(created.count)
        live.insert(id)
        return id
    }
    func renew(_ id: IOPMAssertionID, timeout: TimeInterval) throws {
        XCTAssertEqual(timeout, KeepAwakeController.leaseDuration)
        renewals.append(id)
        if renewalFails { throw NSError(domain: "Test", code: 2) }
    }
    func release(_ id: IOPMAssertionID) { released.append(id); live.remove(id) }
}

final class KeepAwakeTests: XCTestCase {
    func testLockUnlockAndPowerTransitions() {
        let driver = FakeWakeAssertions()
        var acPower = true
        var now: TimeInterval = 0
        let awake = KeepAwakeController(driver: driver, powerSource: { PowerSourceState(acPower: acPower) }, now: { now })
        XCTAssertNil(awake.update(locked: false, enabled: true))
        XCTAssertTrue(driver.created.isEmpty)
        XCTAssertNil(awake.update(locked: true, enabled: true))
        XCTAssertTrue(awake.active)
        XCTAssertEqual(driver.created, ["PreventUserIdleDisplaySleep", "PreventUserIdleSystemSleep", "PreventSystemSleep"])
        awake.update(locked: true, enabled: true)
        XCTAssertEqual(driver.created.count, 3, "Polling must not duplicate assertions")
        XCTAssertEqual(driver.renewals.count, 3)
        now += KeepAwakeController.leaseDuration + 1
        XCTAssertFalse(awake.active, "A stale lease must not be reported active after a main-loop pause")
        awake.update(locked: true, enabled: true)
        XCTAssertTrue(awake.active)
        XCTAssertEqual(driver.created.count, 3, "TurnOff leases must reuse their IDs when updates resume")
        acPower = false
        awake.update(locked: true, enabled: true)
        XCTAssertFalse(awake.active)
        XCTAssertTrue(driver.live.isEmpty)
        acPower = true
        awake.update(locked: true, enabled: true)
        XCTAssertTrue(awake.active)
        awake.update(locked: true, enabled: false)
        XCTAssertTrue(driver.live.isEmpty)
        awake.update(locked: true, enabled: true)
        XCTAssertTrue(awake.active)
        awake.update(locked: false, enabled: true)
        XCTAssertTrue(driver.live.isEmpty)
    }

    func testPartialFailureReleasesAssertionsAndCanRetry() {
        let driver = FakeWakeAssertions()
        driver.failAt = 2
        let awake = KeepAwakeController(driver: driver, powerSource: { PowerSourceState(acPower: true) })
        XCTAssertNotNil(awake.update(locked: true, enabled: true))
        XCTAssertFalse(awake.active)
        XCTAssertTrue(driver.live.isEmpty)
        XCTAssertEqual(driver.released, [1])
        driver.failAt = nil
        XCTAssertNil(awake.update(locked: true, enabled: true))
        XCTAssertTrue(awake.active)
        driver.renewalFails = true
        XCTAssertNotNil(awake.update(locked: true, enabled: true))
        XCTAssertFalse(awake.active)
        XCTAssertTrue(driver.live.isEmpty, "A failed renewal must release the entire assertion set")
        driver.renewalFails = false
        XCTAssertNil(awake.update(locked: true, enabled: true))
        XCTAssertTrue(awake.active)
        awake.stop()
        awake.stop()
        XCTAssertEqual(driver.released.count, 7, "Repeated unlock must not release an ID twice")
    }

    func testBatteryOptInSurvivesUnpluggingButReleasesAtReserveOrUnknownCapacity() {
        let driver = FakeWakeAssertions()
        var source = PowerSourceState(acPower: false, batteryPercent: 80)
        let awake = KeepAwakeController(driver: driver, powerSource: { source })
        awake.update(locked: true, enabled: true)
        XCTAssertTrue(driver.live.isEmpty, "Battery use must require an explicit opt-in")
        awake.update(locked: true, enabled: true, allowBattery: true)
        XCTAssertTrue(awake.active)
        source = PowerSourceState(acPower: true)
        awake.update(locked: true, enabled: true, allowBattery: true)
        source = PowerSourceState(acPower: false, batteryPercent: 11)
        awake.update(locked: true, enabled: true, allowBattery: true)
        XCTAssertTrue(awake.active)
        XCTAssertEqual(driver.created.count, 3, "Power transitions must retain the current assertions")
        for percent in [10, 0, -1, 101, nil] as [Int?] {
            source = PowerSourceState(acPower: false, batteryPercent: percent)
            awake.update(locked: true, enabled: true, allowBattery: true)
            XCTAssertFalse(awake.active)
            XCTAssertTrue(driver.live.isEmpty)
        }
        source = PowerSourceState(acPower: true, batteryPercent: 0)
        awake.update(locked: true, enabled: true, allowBattery: true)
        XCTAssertTrue(awake.active, "The battery cutoff must not disable work on external power")
        source = PowerSourceState(acPower: false, batteryPercent: 36)
        awake.update(locked: true, enabled: true, allowBattery: true, reservePercent: 35)
        XCTAssertTrue(awake.active)
        source = PowerSourceState(acPower: false, batteryPercent: 35)
        awake.update(locked: true, enabled: true, allowBattery: true, reservePercent: 35)
        XCTAssertFalse(awake.active, "The selected reserve must replace the default cutoff")
        awake.update(locked: false, enabled: true, allowBattery: true)
        XCTAssertTrue(driver.live.isEmpty)
    }

    func testBatteryReserveAcceptsOnlyFivePercentStepsFromTenPercent() {
        for value in [10, 15, 35, 80] { XCTAssertEqual(BatteryReserve.percent(from: value), value) }
        for value in [nil, true, 5, 9, 11, 81, 20.5, Double.nan, Double.infinity, "20"] as [Any?] {
            XCTAssertNil(BatteryReserve.percent(from: value))
        }
    }

}
