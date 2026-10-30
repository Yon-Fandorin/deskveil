import AppKit
import Darwin

// Only this isolated, separately signed fixture can select these fake modes.
// No AppDelegate, event tap, display, authentication or power backend is linked.
let identifier = Bundle.main.bundleIdentifier ?? ""
guard ["dev.local.softlock.privacy-recovery-probe", "dev.local.softlock.privacy-recovery-probe.foreign"].contains(identifier) else { exit(2) }
let arguments = CommandLine.arguments
if arguments.contains("--reveal-screen") {
    do { print(try PrivacyRecoveryCommand.run() ? "revealed" : "not-active"); exit(0) }
    catch { fputs("\(error)\n", stderr); exit(1) }
}
if let index = arguments.firstIndex(of: "--fixture-foreign-request"), index + 1 < arguments.count,
   identifier.hasSuffix(".foreign"), let pid = Int32(arguments[index + 1]) {
    // Deliberately bypass ONLY this fixture client's server check to prove the
    // real server rejects a differently signed caller before App callbacks.
    do { _ = try PrivacyRecoveryCommand.request(pid: pid, authorizePeer: { _, _ in true }); exit(1) }
    catch { print("rejected"); exit(0) }
}
let bystander = arguments.count == 3 && arguments[2] == "--fixture-bystander"
guard identifier == "dev.local.softlock.privacy-recovery-probe", (arguments.count == 2 || bystander),
      arguments[1].hasPrefix("/private/tmp/softlock-privacy-recovery-probe-") else { exit(2) }
let output = URL(fileURLWithPath: arguments[1])
var info = stat()
guard lstat(output.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700 else { exit(2) }
final class Probe: NSObject, NSApplicationDelegate {
    let gate = DeferredUpdateGate()
    var shield = true
    var requests = 0
    var timer: Timer?
    func save() {
        let value: [String: Any] = ["pid": getpid(), "shield": shield, "requests": requests,
            "pendingUpdate": gate.pending, "available": gate.available,
            "finishedLaunching": NSRunningApplication.current.isFinishedLaunching]
        do { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            .write(to: output.appendingPathComponent(bystander ? "bystander.json" : "state.json"), options: .atomic) }
        catch { exit(3) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if !bystander { do { try gate.start() } catch { exit(3) } }
        gate.onChange = { [weak self] in self?.save() }
        gate.onRevealPrivacy = { [weak self] in
            guard let self else { return false }
            self.requests += 1; let wasActive = self.shield; self.shield = false; self.save()
            return wasActive
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            if bystander { self.save() }
            if FileManager.default.fileExists(atPath: output.appendingPathComponent("stop").path) { NSApp.terminate(nil) }
        }
        save()
    }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate(); gate.stop() }
}
let app = NSApplication.shared
let delegate = Probe(); app.delegate = delegate; app.run()
