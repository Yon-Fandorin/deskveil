#!/usr/bin/env python3
"""Run original App method bodies with fake OS boundaries, never the real app."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'Sources/App.swift').read_text()
names = ['unlock','restoreBehindPrivacyShield','handleInputRelease','requestUnlock','tick',
         'attemptPreviousDisplayRecovery','previousDisplayRecoveryFailed',
         'recoverFromRelaunchFailure','remainingSeconds','handleBrightnessGuardianExit','finishCoveredRestore','openReplacementApplication','revealPrivacyFromCommand',
         'lock','canStartInputSession','handleCoverReply','handleBrightnessReply','dimFailureIssue',
         'handleScreenLockResult','pollScreenLock','scheduleRestoreTimeout','retryCoveredRestore']
bodies = {}
for name in names:
    starts = list(re.finditer(r'^    (?:@objc )?(?:private )?(?:static )?func '+re.escape(name)+r'\(',source,re.M))
    if len(starts) != 1: raise RuntimeError('Ambiguous original method: '+name)
    start = starts[0].start()
    end = re.search(r'^    }$',source[start:],re.M)
    if end is None: raise RuntimeError('Missing original method end: '+name)
    bodies[name] = source[start:start+end.end()]
installation = (ROOT / 'Sources/Installation.swift').read_text()
start = installation.index('    private func others()')
end = re.search(r'^    }$', installation[start:], re.M)
if end is None: raise RuntimeError('Missing original singleton peer method')
bodies['others'] = installation[start:start+end.end()]
stubs = (ROOT / 'Tools/AppLifecycleProbe/stubs.swift').read_text()
assert stubs.count('    // ORIGINAL_APP_METHODS') == 1
owner = stubs.replace('    // ORIGINAL_APP_METHODS','\n\n'.join(bodies.values()))
enum_source = (ROOT/'Sources/SessionHistory.swift').read_text()
enum_source = enum_source[enum_source.index('enum SessionEndReason'):enum_source.index('/// Records')]
shield = (ROOT/'Sources/PrivacyShield.swift').read_text().split('/// Nonactivating windows',1)[0]
shield = shield.replace('import AppKit','import Foundation',1)
cases = r'''
func expect(_ value: @autoclosure () -> Bool, _ label: String) throws {
    if !value() { throw NSError(domain: "LifecycleProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
}
func chord(_ owner: Owner, emergency: Bool = false) {
    let event = CGEvent(source: nil)!
    event.type = .keyDown; event.flags = [.maskControl,.maskCommand,.maskAlternate]
    event.setIntegerValueField(.eventSourceStateID, value: 1)
    event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
    event.setIntegerValueField(.keyboardEventKeycode, value: emergency ? 32 : 37)
    _ = owner.filter.model.handle(type: .keyDown, event: event)
}
func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
func startNormalUnlock(_ owner: Owner) throws {
    owner.startSession()
    try expect(owner.locked && owner.filter.snapshot.locked && owner.dimmedSession, "normal start did not own input and dimming")
    try expect(owner.sessionHistory.starts == ["orchestration-fixture"], "normal start was not recorded")
    guard let dim = owner.operationReplies.current(.dim) else { throw NSError(domain: "missing dim request", code: 1) }
    owner.receiveBrightness(.init(message: "dimmed:1", id: dim))
    owner.requestManualUnlock()
    try expect(owner.coverPending && owner.locked && owner.filter.snapshot.locked, "manual request released before cover ACK")
    try expect(owner.screenDriver.requests == 0 && owner.guardian.restores == 0, "authentication or brightness escaped cover gate")
}
func acknowledgeCover(_ owner: Owner) throws {
    guard let cover = owner.operationReplies.current(.cover) else { throw NSError(domain: "missing cover request", code: 1) }
    owner.receiveCover(.init(id: cover, state: "covered"))
}
func confirmAuthentication(_ owner: Owner) {
    owner.screenDriver.ready = true
    let now = ProcessInfo.processInfo.systemUptime
    owner.advanceScreenLock(at: now + 1)
    owner.advanceScreenLock(at: now + 2)
}
var passed = 0
func test(_ name: String, _ body: () throws -> Void) throws { try body(); passed += 1; print("PASS original-App orchestration: \(name)") }
do {
    try test("normal unlock reconciled by tick before queued action") {
        let o = Owner(); defer { o.close() }; chord(o)
        try expect(!o.filter.snapshot.locked && o.locked, "release must precede queued delivery")
        o.runTick(); drain()
        try expect(!o.locked && !o.privacyShield.active, "normal unlock must never latch privacy")
        try expect(o.sessionHistory.ends == [.manual], "manual cause lost or duplicated")
    }
    try test("manual release followed by tap disable keeps user intent") {
        let o = Owner(); defer { o.close() }; chord(o)
        _ = o.filter.model.handle(type: .tapDisabledByTimeout, event: CGEvent(source: nil)!)
        o.filter.enabled = false; o.runTick(); drain()
        try expect(!o.privacyShield.active && o.sessionHistory.ends == [.manual], "later health callback replaced explicit intent")
    }
    try test("abnormal release covered before restore and no implicit reveal") {
        let o = Owner(); defer { o.close() }
        o.unlock(reason: .tapUnavailable)
        try expect(o.privacyShield.active && o.privacyRestoreDeferred && o.guardian.restores == 0, "restore escaped presentation gate")
        o.unlock(reason: .sessionInactive)
        try expect(o.privacyShield.active && o.guardian.restores == 0, "session boundary revealed or restored early")
        o.surface.presented = true; o.privacyShield.pollPresentation()
        try expect(o.guardian.restores == 1 && o.privacyShield.active, "opaque presentation did not restore under latch")
        try expect(o.trace.values.first == "shield-show", "brightness restored before showing shield")
    }
    try test("emergency during pending presentation ignores later presentation") {
        let o = Owner(); defer { o.close() }; o.unlock(reason: .unresponsive)
        o.unlock(immediateBrightness: true, reason: .emergency)
        let count = o.guardian.restores; o.surface.presented = true; o.privacyShield.pollPresentation()
        try expect(!o.privacyShield.active && !o.privacyRestoreDeferred && count == 1 && o.guardian.restores == count, "late callback touched emergency recovery")
    }
    try test("brightness guardian loss while login is translucent transfers an opaque cover") {
        let o = Owner(); defer { o.close() }
        o.screenDriver.current = .locked; _ = o.screenLock.begin()
        o.transitionCover.active = true; o.previousDisplayRecoveryPending = true
        o.brightnessOwnerExited()
        try expect(!o.locked && o.privacyShield.active && o.privacyCoverReleaseDeferred, "logical lock bypassed privacy transfer")
        try expect(o.transitionCover.active && o.transitionCover.reveals == 0 && o.guardian.starts == 0, "healthy cover removed before replacement")
        o.surface.presented = true; o.privacyShield.pollPresentation()
        try expect(o.transitionCover.reveals == 1 && o.guardian.starts == 1 && o.privacyShield.active, "opaque replacement did not take over")
    }
    try test("failed replacement restores brightness without exposing translucent login") {
        let o = Owner(); defer { o.close() }
        o.screenDriver.current = .locked; _ = o.screenLock.begin()
        o.transitionCover.active = true; o.previousDisplayRecoveryPending = true
        o.brightnessOwnerExited(); o.privacyClock = 3; o.privacyShield.pollPresentation()
        try expect(o.guardian.starts == 1 && !o.privacyRestoreDeferred, "bounded brightness recovery was stranded")
        o.unlock(reason: .sessionInactive)
        o.unlock(restoreBehindCover: true, reason: .macOSLockConfirmed)
        try expect(o.transitionCover.active && o.transitionCover.reveals == 0 && o.privacyCoverReleaseDeferred, "later release bypassed the retained cover")
        o.unlock(immediateBrightness: true, reason: .emergency)
        try expect(!o.transitionCover.active && !o.privacyShield.active && !o.privacyCoverReleaseDeferred, "explicit rescue could not dismiss")
    }
    try test("logical OS lock during pending cover preparation cannot bypass transfer") {
        let o = Owner(); defer { o.close() }
        o.screenDriver.current = .locked; o.coverPending = true; o.transitionCover.preparing = true
        o.previousDisplayRecoveryPending = true; o.brightnessOwnerExited()
        try expect(o.privacyShield.active && o.privacyCoverReleaseDeferred && o.transitionCover.reveals == 0, "pre-ACK cover was removed on logical lock")
        o.surface.presented = true; o.privacyShield.pollPresentation()
        try expect(o.transitionCover.reveals == 1, "prepared replacement did not release prior cover")
    }
    try test("health release upgraded to explicit emergency before tick") {
        let o = Owner(); defer { o.close() }
        o.filter.model.checkHealth(at: ProcessInfo.processInfo.systemUptime+5); chord(o, emergency: true)
        o.runTick(); drain()
        try expect(!o.privacyShield.active && o.sessionHistory.ends == [.emergency], "explicit rescue was classified as failure")
    }
    try test("deferred manual unlock retains covered authentication path") {
        let o = Owner(); defer { o.close() }; o.sessionLocksOnUnlock = true
        o.filter.model.configure(locked: true, normal: .normal, emergency: .emergency, deferManualUnlock: true)
        chord(o); o.runTick(); drain()
        try expect(o.locked && o.filter.snapshot.locked && o.transitionCover.prepares == 1 && !o.privacyShield.active, "authentication handoff bypassed")
    }
    try test("normal start connects cover, authentication, brightness and cover release ACKs") {
        let o = Owner(); defer { o.close() }; o.screenDriver.locksOnRequest = true
        try startNormalUnlock(o)
        try acknowledgeCover(o)
        try expect(o.screenDriver.requests == 1 && o.locked && o.transitionCover.active, "cover ACK failed to begin covered authentication")
        try expect(o.guardian.commands.contains { $0.0 == "hold-for-lock" } && o.guardian.restores == 0, "brightness was restored before authentication")
        confirmAuthentication(o)
        try expect(!o.locked && !o.filter.snapshot.locked && o.coveredBrightnessRestore && o.transitionCover.active, "authentication did not transfer to covered restore")
        let restore = o.operationReplies.current(.restore)!
        o.receiveBrightness(.init(message: "restored", id: restore))
        try expect(!o.coveredBrightnessRestore && !o.transitionCover.active && !o.previousDisplayRecovery.active, "brightness ACK did not finish recovery and reveal")
        let reveal = o.operationReplies.current(.coverRelease)!
        o.receiveCover(.init(id: reveal, state: "released"))
        try expect(o.operationReplies.current(.coverRelease) == nil && o.issues[.brightness] == nil, "cover release ACK retained completed owner")
        try expect(o.sessionHistory.ends == [.macOSLockConfirmed] && !o.privacyShield.active, "normal authentication was misclassified")
    }
    try test("failed restore and stale ACKs cannot reveal the authentication cover") {
        let o = Owner(); defer { o.close() }; o.screenDriver.locksOnRequest = true
        try startNormalUnlock(o); try acknowledgeCover(o); confirmAuthentication(o)
        let first = o.operationReplies.current(.restore)!
        o.receiveBrightness(.init(message: "restored", id: first - 1))
        try expect(o.coveredBrightnessRestore && o.transitionCover.active, "unrelated brightness ACK revealed cover")
        o.receiveBrightness(.init(message: "restore-failed", id: first))
        let retry = o.operationReplies.current(.restore)!
        try expect(retry != first && o.restoreRetries == 1 && o.transitionCover.active, "failed restore did not retain cover for bounded retry")
        o.receiveBrightness(.init(message: "restored", id: first))
        try expect(o.coveredBrightnessRestore && o.transitionCover.active, "late first restore ACK completed retry")
        o.receiveBrightness(.init(message: "restored", id: retry))
        try expect(!o.coveredBrightnessRestore && !o.transitionCover.active, "current retry ACK could not finish")
    }
    try test("failed OS lock keeps input blocked and waits for opaque failure ACK before restore") {
        let o = Owner(); defer { o.close() }; o.screenDriver.requestSucceeds = false
        try startNormalUnlock(o); try acknowledgeCover(o)
        try expect(o.locked && o.filter.snapshot.locked && o.screenLock.state == "failed", "failed authentication released input")
        try expect(o.transitionCover.failures == 1 && o.guardian.restores == 0, "failure brightness escaped readable opaque surface")
        let failure = o.operationReplies.current(.failureCover)!
        o.receiveCover(.init(id: failure, state: "failure"))
        let restore = o.operationReplies.current(.failureRestore)!
        try expect(o.guardian.restores == 1 && o.locked, "opaque failure ACK did not restore brightness under input block")
        o.receiveBrightness(.init(message: "restored", id: restore))
        try expect(!o.dimmedSession && o.locked && o.filter.snapshot.locked, "failure restore ACK released input")
        o.unlock(immediateBrightness: true, reason: .emergency)
        try expect(!o.locked && !o.transitionCover.active && !o.privacyShield.active, "explicit emergency could not recover failed handoff")
    }
    try test("late cover ACK after emergency cannot restart OS authentication") {
        let o = Owner(); defer { o.close() }; try startNormalUnlock(o)
        let stale = o.operationReplies.current(.cover)!
        o.unlock(immediateBrightness: true, reason: .emergency)
        o.receiveCover(.init(id: stale, state: "covered"))
        try expect(o.screenDriver.requests == 0 && !o.locked && !o.filter.snapshot.locked, "stale cover ACK restarted cancelled authentication")
        try expect(!o.coverPending && !o.transitionCover.active && !o.privacyShield.active, "stale cover ACK recreated a latch")
    }
    try test("failed relaunch recovers only after late closing owner exits") {
        let o = Owner(); defer { o.close() }; o.locked = false
        o.filter.model.configure(locked: false, normal: .normal, emergency: .emergency)
        o.previousDisplayRecoveryPending = true; o.previousDisplayRecovery.attempts = 2
        o.relaunching = true; o.relaunchHelpersClosing = true; o.guardian.running = true
        o.resumeFailedRelaunch(); o.runTick()
        try expect(o.guardian.starts == 0, "live closing recovery owner was replaced")
        o.guardian.running = false; o.runTick()
        try expect(o.guardian.starts == 1 && o.guardian.restores == 1 && o.previousDisplayRecovery.attempts == 3, "late owner exit lost restore or retry budget")
    }
    try test("failed relaunch with already closed helpers resumes pending restore") {
        let o = Owner(); defer { o.close() }; o.locked = false
        o.filter.model.configure(locked: false, normal: .normal, emergency: .emergency)
        o.previousDisplayRecoveryPending = true; o.relaunching = true
        o.resumeFailedRelaunch(); o.runTick()
        try expect(o.guardian.starts == 1 && o.guardian.restores == 1, "reopen failure left restoration unowned")
    }
    try test("relaunch failure cannot reset exhausted restore budget") {
        let o = Owner(); defer { o.close() }; o.locked = false
        o.filter.model.configure(locked: false, normal: .normal, emergency: .emergency)
        o.previousDisplayRecoveryPending = true; o.previousDisplayRecovery.attempts = 3; o.relaunching = true
        o.resumeFailedRelaunch(); o.runTick()
        try expect(o.guardian.starts == 0 && o.previousDisplayRecovery.attempts == 3, "exhausted budget was reset")
    }
    try test("restart timeout is armed before Launch Services completion and ignores late callbacks") {
        let o = Owner(); defer { o.close() }; o.relaunching = true
        o.startReplacement()
        let ticket = o.relaunchHandoff
        let completion = NSWorkspace.shared.completion
        try expect(o.relaunchTimer != nil && completion != nil, "launch wait has no timeout")
        o.relaunchTimer?.fire()
        try expect(!o.relaunching && ticket?.cancelled == true && o.relaunchTimer == nil, "launch wait timeout did not recover owner")
        completion?(NSRunningApplication(102), nil); drain()
        try expect(NSApp.terminations == 0 && o.relaunchTimer == nil, "late launch callback restarted cancelled handoff")
    }
    try test("restart completion waits for authenticated replacement readiness") {
        let o = Owner(); defer { o.close() }; o.relaunching = true; o.startReplacement()
        let ticket = o.relaunchHandoff
        NSWorkspace.shared.completion?(NSRunningApplication(102), nil); drain()
        o.relaunchTimer?.fire()
        try expect(NSApp.terminations == 0, "launch success alone terminated owner")
        ticket?.readyPID = 102; o.relaunchTimer?.fire()
        try expect(NSApp.terminations == 1 && o.relaunchTimer == nil && ticket?.cancelled == false, "ready owner did not leave ticket for successor")
    }
    try test("failed replacement preserves owner and cancels readiness") {
        let o = Owner(); defer { o.close() }; o.relaunching = true; o.startReplacement()
        let ticket = o.relaunchHandoff
        NSWorkspace.shared.completion?(nil, NSError(domain: "fixture", code: 1)); drain()
        try expect(!o.relaunching && ticket?.cancelled == true && o.relaunchTimer == nil && NSApp.terminations == 0, "launch failure lost owner")
    }
    try test("singleton ignores only a kernel-confirmed exited workspace entry") {
        let o = Owner(); defer { o.close() }
        let dead = NSRunningApplication(Int32.max), live = NSRunningApplication(getppid())
        NSWorkspace.shared.runningApplications = [dead, live]
        let others = o.otherProcesses()
        try expect(others.count == 1 && others[0] === live, "stale workspace snapshot killed successor or bypassed live singleton")
    }
    try test("privacy command never ends an ordinary input session") {
        let o = Owner(); defer { o.close() }
        try expect(!o.recoverPrivacy() && o.locked && o.filter.snapshot.locked, "recovery command ended input blocking")
        try expect(o.sessionHistory.ends.isEmpty, "recovery without shield recorded session release")
    }
    try test("privacy command recovers only its active visual latch") {
        let o = Owner(); defer { o.close() }; o.unlock(reason: .tapUnavailable)
        try expect(o.recoverPrivacy() && !o.privacyShield.active && !o.locked, "signed recovery could not clear latch")
        try expect(!o.recoverPrivacy(), "repeated recovery reported nonexistent latch")
    }
    try test("privacy command cannot interrupt an authentication transition") {
        let o = Owner(); defer { o.close() }; o.unlock(reason: .tapUnavailable)
        o.screenDriver.current = .locked
        _ = o.screenLock.begin()
        try expect(!o.recoverPrivacy() && o.privacyShield.active && o.screenLock.requiresConfirmation, "recovery cancelled authentication state")
    }
    print("PASS \(passed) original-App orchestration scenarios; no native input, brightness, power, windows, installation or OS lock")
} catch { fputs("FAIL \(error)\n", stderr); exit(1) }
'''
with tempfile.TemporaryDirectory(prefix='softlock-app-lifecycle-',dir='/private/tmp') as raw:
    directory = Path(raw)
    (directory/'main.swift').write_text(owner+'\n'+cases)
    (directory/'PrivacyModel.swift').write_text(enum_source+'\n'+shield)
    binary = directory/'lifecycle-probe'
    subprocess.run(['swiftc',str(ROOT/'Sources/Localization.swift'),'-module-cache-path',str(ROOT/'.build/clang-cache'),
        *[str(ROOT/'Sources'/f'{name}.swift') for name in ['InputPolicy','InputFilter','IdleActivity','Shortcut','ScreenLock','AppIssues','DisplayRecoveryLifecycle','OperationReplies']],
        str(directory/'PrivacyModel.swift'),str(directory/'main.swift'),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
print(json.dumps({'originalAppMethodsSHA256':{name:hashlib.sha256(body.encode()).hexdigest() for name,body in bodies.items()},
                  'nativeBoundaries':'stubbed; original App initializer and native surfaces not linked'},sort_keys=True))
