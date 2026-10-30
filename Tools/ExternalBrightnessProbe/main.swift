import CoreGraphics
import Darwin
import Foundation

// A mutating probe is a standalone experiment. Telemetry files can be stale
// or belong to another copy, so inspect actual processes before touching DDC.
func requireNoRunningSoftLock() throws {
    let required = proc_listallpids(nil, 0)
    guard required > 0 else { throw NSError(domain: "SoftLockProbe", code: 1) }
    var pids = [pid_t](repeating: 0, count: Int(required) + 1024)
    let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    guard count > 0, count < pids.count else { throw NSError(domain: "SoftLockProbe", code: 2) }
    for pid in pids.prefix(Int(count)) where pid > 0 {
        var bytes = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { continue }
        let path = String(cString: bytes)
        guard path.hasSuffix("/Contents/MacOS/SoftLock") else { continue }
        let info = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        let data = try? Data(contentsOf: info)
        let metadata = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        // An unreadable/deleted bundle cannot be treated as proof of absence.
        if let identifier = metadata?["CFBundleIdentifier"] as? String, identifier != "dev.local.softlock" { continue }
        throw NSError(domain: "SoftLockProbe", code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Quit every SoftLock instance before the brightness smoke test"])
    }
}

#if SOFTLOCK_PROBE_GUARD_ONLY
// This binary contains ONLY process inspection. Native display/power code is
// not linked, even when the guard permits a test; safe for automated checks.
do { try requireNoRunningSoftLock(); print("GUARD allows standalone test") }
catch { print("GUARD rejected running or unverified SoftLock"); exit(2) }
#else

// Uses the app's real DDC transport and recovery engine. No input blocking or OS lock.
let smoke = CommandLine.arguments.contains("--smoke")
var smokeLease: Int32?
if smoke {
    do { try requireNoRunningSoftLock() }
    catch { print("Stop: \(error.localizedDescription)"); exit(1) }
    guard let lease = FileBrightnessRecovery.acquireGuardianLease() else {
        print("Stop: another brightness owner is running"); exit(1)
    }
    smokeLease = lease
    guard !FileManager.default.fileExists(atPath: FileBrightnessRecovery.url.path),
          !FileManager.default.fileExists(atPath: FileGammaRecovery.url.path) else {
        print("Stop: pending display recovery"); exit(1)
    }
}
defer { if let lease = smokeLease { close(lease) } }
// Baselines are captured only after the exclusive lease; another smoke cannot
// restore a temporary dim value observed while its predecessor was running.
let driver = NativeDDCBrightness()
var count: UInt32 = 0
guard CGGetOnlineDisplayList(0, nil, &count) == .success else { exit(1) }
var displays = [UInt32](repeating: 0, count: Int(count))
guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { exit(1) }
let external = displays.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
guard !external.isEmpty else { print("No external displays"); exit(1) }
setvbuf(stdout, nil, _IOLBF, 0)

var originals: [UInt32: Float] = [:]
var identities: [UInt32: String] = [:]
for display in external {
    guard let identity = driver.identity(display), let value = driver.read(display, identity: identity) else {
        print("display=\(display) DDC brightness unavailable"); exit(1)
    }
    originals[display] = value; identities[display] = identity
    print("display=\(display) brightness=\(value) checksum=valid")
}
guard Set(identities.values).count == external.count else { print("Ambiguous display identities"); exit(1) }
guard smoke else { print("Read only; no brightness changed"); exit(0) }

for display in external {
    let identity = identities[display]!, original = originals[display]!
    let recovery = FileBrightnessRecovery()
    guard recovery.save(Dictionary(uniqueKeysWithValues: originals.map { (identities[$0.key]!, $0.value) })) else { exit(1) }
    var selected = [display]
    let brightness = NativeBrightness(displays: { selected },
        read: { driver.read($0, identity: identities[$0]!) },
        write: { driver.write($0, identity: identities[$0]!, value: $1, verify: false) },
        identity: { identities[$0]! }, recovery: recovery,
        verify: { id, value in
            guard let actual = driver.read(id, identity: identities[id]!) else { return false }
            return abs(actual - value) < 0.005
        })
    let target = max(0, original - 0.05)
    let dimmed = brightness.dim(to: target)
    let observed = driver.read(display, identity: identity)
    let othersUnchanged = external.filter { $0 != display }.allSatisfy { other in
        guard let actual = driver.read(other, identity: identities[other]!) else { return false }
        return abs(actual - originals[other]!) < 0.005
    }
    // Always restore before checking test assertions or moving to the next monitor.
    selected = Array(external)
    var restored = false
    for _ in 0..<3 {
        if brightness.restore() { restored = true; break }
        usleep(100_000)
    }
    let final = driver.read(display, identity: identity)
    print("display=\(display) before=\(original) lowered=\(observed ?? -1) restored=\(final ?? -1)")
    guard othersUnchanged, dimmed == 1, let observed, abs(observed - target) < 0.005,
          restored, let final, abs(final - original) < 0.005 else {
        print("FAIL; recovery record retained if restoration was not confirmed"); exit(1)
    }
}
print("PASS external brightness write and restore; no input or power settings changed")

#endif
