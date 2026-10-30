import XCTest
@testable import SoftLock

final class PrivacyShieldTests: XCTestCase {
    private final class Surface: PrivacyShieldSurface {
        var presented = false
        var shows = 0
        var hides = 0
        func show() { shows += 1 }
        func hide() { hides += 1; presented = false }
    }
    private func begin(_ shield: PrivacyShield, reason: SessionEndReason = .tapUnavailable) -> Bool {
        shield.begin(reason: reason, sessionActive: true, macOSLocked: false)
    }
    func testOnlyTypedAbnormalEndsOfActiveUnlockedSessionsCreateShield() {
        let expected: Set<SessionEndReason> = [.tapInterrupted, .tapUnavailable, .secureInput, .filterReleased,
            .unresponsive, .brightnessGuardianExit, .coverFailure, .powerUnavailable, .lidEnded]
        for reason in SessionEndReason.allCases {
            let surface = Surface(); let shield = PrivacyShield(surface: surface, automaticPolling: false)
            XCTAssertEqual(begin(shield, reason: reason), expected.contains(reason), "\(reason)")
            shield.dismiss()
            XCTAssertFalse(shield.begin(reason: reason, sessionActive: false, macOSLocked: false))
            XCTAssertFalse(shield.begin(reason: reason, sessionActive: true, macOSLocked: true))
        }
    }
    func testPresentationReleasesRestoreButNeverReleasesVisualLatch() {
        let surface = Surface(); let shield = PrivacyShield(surface: surface, automaticPolling: false)
        var restored = 0; shield.onPresented = { restored += 1 }
        XCTAssertTrue(begin(shield)); XCTAssertTrue(shield.awaitingPresentation)
        shield.pollPresentation(); XCTAssertEqual(restored, 0)
        surface.presented = true; shield.pollPresentation(); shield.pollPresentation()
        XCTAssertEqual(restored, 1); XCTAssertTrue(shield.active); XCTAssertTrue(shield.presented)
        XCTAssertFalse(begin(shield)); XCTAssertEqual(surface.shows, 1)
    }
    func testDismissDuringPreparationRejectsLatePresentationAndAllowsFreshLatch() {
        let surface = Surface(); let shield = PrivacyShield(surface: surface, automaticPolling: false)
        var presented = 0; shield.onPresented = { presented += 1 }
        XCTAssertTrue(begin(shield))
        shield.dismiss(); surface.presented = true; shield.pollPresentation()
        XCTAssertFalse(shield.active); XCTAssertFalse(shield.presented); XCTAssertEqual(presented, 0)
        surface.presented = false
        XCTAssertTrue(begin(shield)); XCTAssertEqual(surface.shows, 2)
        surface.presented = true; shield.pollPresentation()
        XCTAssertTrue(shield.active); XCTAssertEqual(presented, 1)
    }
    func testFailedPresentationHasBoundedRestoreDelayAndRetainsLatch() {
        let surface = Surface(); var now: TimeInterval = 0
        let shield = PrivacyShield(surface: surface, automaticPolling: false, clock: { now })
        var failures = 0; shield.onPresentationFailure = { failures += 1 }
        XCTAssertTrue(begin(shield)); now = 1.99; shield.pollPresentation()
        XCTAssertEqual(failures, 0); XCTAssertTrue(shield.awaitingPresentation)
        now = 2; shield.pollPresentation(); now = 100; shield.pollPresentation()
        XCTAssertEqual(failures, 1); XCTAssertFalse(shield.awaitingPresentation); XCTAssertTrue(shield.active)
        surface.presented = true; shield.pollPresentation()
        XCTAssertTrue(shield.presented); XCTAssertFalse(shield.presentationFailed)
    }
    func testTopologyRebuildKeepsLatchWithoutHidingTheSurface() {
        let surface = Surface(); let shield = PrivacyShield(surface: surface, automaticPolling: false)
        XCTAssertTrue(begin(shield)); surface.presented = true; shield.pollPresentation()
        surface.presented = false; shield.rebuild()
        XCTAssertTrue(shield.active); XCTAssertTrue(shield.awaitingPresentation); XCTAssertEqual(surface.hides, 0)
        XCTAssertEqual(surface.shows, 2)
        surface.presented = true; shield.pollPresentation()
        XCTAssertTrue(shield.active); XCTAssertTrue(shield.presented)
        shield.dismiss(); XCTAssertFalse(shield.active); XCTAssertEqual(surface.hides, 1)
    }
    func testRepeatedTopologyNotificationsCannotExtendInitialRestoreDeadline() {
        let surface = Surface(); var now: TimeInterval = 0
        let shield = PrivacyShield(surface: surface, automaticPolling: false, clock: { now })
        var failures = 0; shield.onPresentationFailure = { failures += 1 }
        XCTAssertTrue(begin(shield))
        for instant in [0.5, 1, 1.5, 1.99] {
            now = instant; shield.rebuild(); shield.pollPresentation()
            XCTAssertTrue(shield.awaitingPresentation)
        }
        now = 2; shield.pollPresentation()
        XCTAssertEqual(failures, 1); XCTAssertFalse(shield.awaitingPresentation); XCTAssertTrue(shield.active)
    }
    func testNativeRunLoopPresentationTimerIsNotStarvedByTopologyBursts() {
        let surface = Surface(); var now: TimeInterval = 0
        let shield = PrivacyShield(surface: surface, clock: { now })
        let recovered = expectation(description: "bounded fallback despite repeated notifications")
        shield.onPresentationFailure = { recovered.fulfill() }
        XCTAssertTrue(begin(shield)); now = 3
        let notifications = Timer(timeInterval: 0.005, repeats: true) { _ in shield.rebuild() }
        RunLoop.main.add(notifications, forMode: .common)
        defer { notifications.invalidate(); shield.dismiss() }
        wait(for: [recovered], timeout: 1)
        XCTAssertFalse(shield.awaitingPresentation)
    }
}
