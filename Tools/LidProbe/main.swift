import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit
import IOKit.ps

// Read-only hardware observation, separate from the installed app.
// This executable never changes power settings, brightness, permissions, or input.
// Display presence and event counts alone do not prove computer-use compatibility.

func onACPower() -> Bool {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
    return source as String == kIOPSACPowerValue
}

func lidState() -> [String: Bool] {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard root != 0 else { return [:] }
    defer { IOObjectRelease(root) }
    var result: [String: Bool] = [:]
    for key in ["AppleClamshellState", "AppleClamshellCausesSleep", "SleepDisabled"] {
        if let value = IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool {
            result[key] = value
        }
    }
    return result
}

func hidIdleSeconds() -> Double {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    guard service != 0 else { return -1 }
    defer { IOObjectRelease(service) }
    guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString,
        kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else { return -1 }
    return value.doubleValue / 1e9
}

func appState(pid: pid_t) -> [String: Any]? {
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
    let executable = URL(fileURLWithPath: String(cString: path))
    let macOS = executable.deletingLastPathComponent()
    let contents = macOS.deletingLastPathComponent()
    let bundle = contents.deletingLastPathComponent()
    // Follow the selected process, including installations outside this checkout.
    // App writes its diagnostics beside its own bundle.
    guard executable.lastPathComponent == "SoftLock", macOS.lastPathComponent == "MacOS",
          contents.lastPathComponent == "Contents", bundle.pathExtension == "app",
          Bundle(url: bundle)?.bundleIdentifier == "dev.local.softlock",
          let data = try? Data(contentsOf: bundle.deletingLastPathComponent()
            .appendingPathComponent("SoftLock-diagnostics.json")),
          let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          state["pid"] as? Int == Int(pid),
          let timestamp = state["updatedAt"] as? String,
          let updated = ISO8601DateFormatter().date(from: timestamp),
          (-2...10).contains(Date().timeIntervalSince(updated)) else { return nil }
    return state
}

func write(_ record: [String: Any], to output: FileHandle = .standardOutput) {
    var record = record
    record["at"] = ISO8601DateFormatter().string(from: Date())
    record["uptime"] = ProcessInfo.processInfo.systemUptime
    if var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
        data.append(10)
        try? output.write(contentsOf: data)
    }
}

func monitor(pid: pid_t, duration: TimeInterval = 180) -> Never {
    let clock = ContinuousClock()
    let began = clock.now
    repeat {
        var count: UInt32 = 0
        let query = CGGetOnlineDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        if count > 0 { _ = CGGetOnlineDisplayList(count, &displays, &count) }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let state = appState(pid: pid)
        let elapsed = began.duration(to: clock.now).components
        let allEvents = CGEventType(rawValue: UInt32.max)!
        write([
            "kind": "monitor", "lid": lidState(), "onAC": onACPower(),
            "elapsed": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
            "displayQuery": query.rawValue,
            "displays": displays.prefix(Int(count)).map { id -> [String: Any] in
                ["id": id, "builtin": CGDisplayIsBuiltin(id) != 0,
                 "active": CGDisplayIsActive(id) != 0, "asleep": CGDisplayIsAsleep(id) != 0,
                 "width": CGDisplayPixelsWide(id), "height": CGDisplayPixelsHigh(id)]
            },
            "sessionAvailable": session != nil,
            "sessionIdle": CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: allEvents),
            "hidEventIdle": CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: allEvents),
            "hidSystemIdle": hidIdleSeconds(),
            "hidHeldKeyCount": (0..<128).filter { $0 != 57 && CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) }.count,
            "onConsole": session?[kCGSessionOnConsoleKey as String] as? Bool ?? false,
            "macOSLocked": session?["CGSSessionScreenIsLocked"] as? Bool ?? false,
            "appFresh": state != nil,
            "softLocked": state?["locked"] as? Bool ?? false,
            "tapEnabled": state?["tapEnabled"] as? Bool ?? false,
            "idleState": state?["idleLockPreventionState"] as? String ?? "unavailable",
            "idlePulses": state?["idleActivityPulses"] as? Int ?? 0,
            "idleVerified": state?["idleActivityVerified"] as? Int ?? 0,
            "heldInput": state?["heldInput"] as? Bool ?? false,
            "issue": state?["issue"] as? String ?? "",
            "passedEvents": state?["passedEvents"] as? Int ?? 0,
            "blockedEvents": state?["blockedEvents"] as? Int ?? 0
        ])
        if duration > 0 { Thread.sleep(forTimeInterval: 1) }
    } while began.duration(to: clock.now) < .seconds(duration)
    exit(0)
}

let args = CommandLine.arguments
guard args.count >= 3, let pid = Int32(args[2]), pid > 0 else { exit(64) }
switch args[1] {
case "--monitor":
    let duration = args.count > 3 ? Double(args[3]) ?? 0 : 180
    guard duration.isFinite, duration > 0, duration <= 86520 else { exit(64) }
    monitor(pid: pid, duration: duration)
case "--snapshot": monitor(pid: pid, duration: 0)
default: exit(64)
}
