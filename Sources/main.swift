import AppKit
import CoreGraphics

let lidArguments = CommandLine.arguments
func lidArgument(_ name: String) -> String? {
    guard let index = lidArguments.firstIndex(of: name), index + 1 < lidArguments.count else { return nil }
    return lidArguments[index + 1]
}
if lidArguments.contains("--lid-install") || lidArguments.contains("--lid-uninstall") {
    guard let raw = lidArgument("--app-pid"), let pid = Int32(raw), pid > 1 else { exit(2) }
    runLidInstaller(appPID: pid, remove: lidArguments.contains("--lid-uninstall"))
}
if lidArguments.contains("--lid-install-plan") {
    do { try printLidInstallationPlan(); exit(0) }
    catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
if lidArguments.contains("--reveal-screen") {
    do {
        print(try PrivacyRecoveryCommand.run() ? L10n.text("화면 가림을 해제했습니다.") : L10n.text("해제할 화면 가림이 없습니다. 입력 차단은 변경하지 않았습니다."))
        exit(0)
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
if lidArguments.contains("--lid-service-status") {
    let value: [String: Any] = ["state": (try? lidJSON(LidPaths.state)) ?? [:],
        "configuration": (try? lidJSON(LidPaths.configuration)) ?? [:],
        "configuredSleepDisabled": (try? NativeLidPower().configuredDisabled()).map { $0 as Any } ?? NSNull(),
        "power": lidRootProperties(), "recoveryPending": FileManager.default.fileExists(atPath: LidPaths.receipt)]
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
       let string = String(data: data, encoding: .utf8) { print(string) }
    exit(0)
}

if CommandLine.arguments.contains("--brightness-guardian") { runBrightnessGuardian() }
if CommandLine.arguments.contains("--brightness-guardian-fixture") { runBrightnessGuardian(fixture: true) }
if CommandLine.arguments.contains("--transition-cover-guardian") { runTransitionCoverGuardian() }

if CommandLine.arguments.contains("--diagnostics") {
    print("Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted")")
    print("Listen access: \(CGPreflightListenEventAccess())")
    print("Post access: \(CGPreflightPostEventAccess())")
    for (name, types) in [("keyboard", [UInt32(10), 11, 12]), ("full", InputPolicy.eventTypes)] {
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) }
        let probe = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                     options: .defaultTap, eventsOfInterest: mask,
                                     callback: { _, _, event, _ in Unmanaged.passUnretained(event) }, userInfo: nil)
        print("Active \(name) filter creation: \(probe != nil)")
        if let probe { CGEvent.tapEnable(tap: probe, enable: false); CFMachPortInvalidate(probe) }
    }
    let values = NativeBrightness().currentValues()
    print("Readable brightness displays: \(values.count)")
    print("Current display brightness: \(values)")
    let screenLock = NativeScreenLock()
    print("macOS lock request available: \(screenLock.available)")
    print("macOS screen state: \(screenLock.screenState())")
    print("No input block, brightness change, or permission prompt was performed.")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
if CommandLine.arguments.contains("--ui-smoke-test") {
    Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
        print(delegate.checkUI() ? "PASS menu UI initialized, input remains unlocked" : "FAIL menu UI")
        fflush(stdout)
        NSApp.terminate(nil)
    }
}
app.run()
