import XCTest
@testable import SoftLock

private final class DDCRouteFixture: DDCBrightnessTransport {
    var identities: [UInt32: String] = [1: "monitor"]
    var routes: [UInt32: DDCBrightnessRoute] = [1: .init(identity: "monitor", framebufferID: 10, proxyID: 11)]
    var values: [UInt64: (current: UInt16, maximum: UInt16)] = [11: (75, 100)]
    var writes: [(UInt64, UInt16)] = []
    var routeReads = 0
    var beforeRoute: ((Int) -> Void)?
    func identity(_ display: UInt32) -> String? { identities[display] }
    func route(_ display: UInt32, identity: String) -> DDCBrightnessRoute? {
        routeReads += 1; beforeRoute?(routeReads)
        return routes[display]
    }
    func read(_ route: DDCBrightnessRoute) -> (current: UInt16, maximum: UInt16)? { values[route.proxyID] }
    func write(_ route: DDCBrightnessRoute, value: UInt16) -> Bool {
        writes.append((route.proxyID, value))
        guard let previous = values[route.proxyID] else { return false }
        values[route.proxyID] = (value, previous.maximum); return true
    }
}

final class DDCBrightnessTests: XCTestCase {
    func testBrightnessPacketsRejectCorruptAndUnrelatedReplies() {
        XCTAssertEqual(DDCBrightnessPacket.set(90), [0x84, 0x03, 0x10, 0, 0x5a, 0xf2])
        func reply(result: UInt8 = 0, feature: UInt8 = 0x10, maximum: UInt8 = 100, current: UInt8 = 90) -> [UInt8] {
            var bytes: [UInt8] = [0x6e, 0x88, 0x02, result, feature, 0, 0, maximum, 0, current]
            bytes.append(bytes.reduce(0x50, ^)); return bytes
        }
        XCTAssertEqual(DDCBrightnessPacket.decode(reply())?.current, 90)
        XCTAssertEqual(DDCBrightnessPacket.decode(reply())?.maximum, 100)
        var damaged = reply(); damaged[10] ^= 1
        for bytes in [damaged, reply(result: 1), reply(feature: 0x12), reply(maximum: 0), reply(current: 101), []] {
            XCTAssertNil(DDCBrightnessPacket.decode(bytes))
        }
    }
    func testKnownConnectionRebindsAndReadsNewMaximumAfterPortMove() {
        let fixture = DDCRouteFixture()
        let ddc = NativeDDCBrightness(transport: fixture)
        XCTAssertEqual(ddc.read(1, identity: "monitor"), 0.75)
        fixture.routes[1] = .init(identity: "monitor", framebufferID: 20, proxyID: 21)
        fixture.values[21] = (150, 200)
        XCTAssertTrue(ddc.write(1, identity: "monitor", value: 0.5, verify: true))
        XCTAssertEqual(fixture.writes.map { $0.0 }, [21])
        XCTAssertEqual(fixture.writes.map { $0.1 }, [100])
        XCTAssertEqual(fixture.values[11]?.current, 75)
    }
    func testReusedDisplayIDAndMissingRouteNeverUseKnownService() {
        let fixture = DDCRouteFixture()
        let driver = NativeDDCBrightness(transport: fixture)
        XCTAssertNotNil(driver.read(1, identity: "monitor"))
        fixture.identities[1] = "replacement"
        XCTAssertFalse(driver.write(1, identity: "monitor", value: 0, verify: false))
        XCTAssertTrue(fixture.writes.isEmpty)
        fixture.identities[1] = "monitor"
        XCTAssertNotNil(driver.read(1, identity: "monitor"))
        fixture.routes.removeValue(forKey: 1)
        XCTAssertFalse(driver.write(1, identity: "monitor", value: 0, verify: false))
        XCTAssertTrue(fixture.writes.isEmpty)
    }
    func testRouteChangeImmediatelyBeforeWriteAbortsRatherThanUsingOldMaximum() {
        let fixture = DDCRouteFixture()
        let ddc = NativeDDCBrightness(transport: fixture)
        XCTAssertNotNil(ddc.read(1, identity: "monitor"))
        let beforeWrite = fixture.routeReads + 2
        fixture.beforeRoute = { count in
            if count == beforeWrite {
                fixture.routes[1] = .init(identity: "monitor", framebufferID: 20, proxyID: 21)
                fixture.values[21] = (100, 200)
            }
        }
        XCTAssertFalse(ddc.write(1, identity: "monitor", value: 0, verify: true))
        XCTAssertTrue(fixture.writes.isEmpty)
        fixture.beforeRoute = nil
        XCTAssertTrue(ddc.write(1, identity: "monitor", value: 0.5, verify: true))
        XCTAssertTrue(fixture.writes.isEmpty) // New route was already at its own 50%.
        XCTAssertEqual(fixture.values[11]?.current, 75)
    }

}
