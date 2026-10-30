import AppKit
import Darwin

// A separately identified, headless app. No production AppDelegate, input,
// brightness, overlays or power controller is linked or instantiated here.
guard Bundle.main.bundleIdentifier == "dev.local.softlock.relaunch-probe" else { exit(2) }
let arguments = CommandLine.arguments
func argument(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
guard let raw = argument("--probe-output"), raw.hasPrefix("/private/tmp/softlock-relaunch-probe-") else { exit(2) }
let output = URL(fileURLWithPath: raw)
var info = stat()
guard lstat(output.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700 else { exit(2) }
func report(_ name: String, _ value: [String: Any]) {
    do { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: output.appendingPathComponent(name), options: .atomic) }
    catch { exit(3) }
}
final class Probe: NSObject, NSApplicationDelegate {
    let installation = InstallationFlow()
    var ticket: RelaunchHandoff?
    var waiter: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if arguments.contains("--probe-child") {
            guard let parent = argument("--probe-parent-pid").flatMap(Int32.init) else { exit(2) }
            installation.begin {
                let parentAlive = kill(parent, 0) == 0 || errno == EPERM
                let others = NSWorkspace.shared.runningApplications.filter {
                    $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0.processIdentifier != getpid() && !$0.isTerminated
                }
                report("child.json", ["pid": getpid(), "parentAliveAtAdmission": parentAlive,
                       "otherInstancesAtAdmission": others.count, "usedOriginalInstallationFlow": true])
                NSApp.terminate(nil)
            }
            return
        }
        guard arguments.contains("--probe-parent") else { exit(2) }
        do { ticket = try RelaunchHandoff.create() } catch { report("error.json", ["error": error.localizedDescription]); exit(3) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false; configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--probe-child", "--probe-output", output.path, "--probe-parent-pid", String(getpid()),
                                   "--relaunch-handoff", ticket!.token]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { running, error in
            DispatchQueue.main.async {
                guard let running, error == nil else {
                    report("error.json", ["error": error?.localizedDescription ?? "No replacement"]); self.ticket?.cancel(); exit(3)
                }
                let deadline = ProcessInfo.processInfo.systemUptime + 15
                self.waiter = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
                    if !running.isTerminated && self.ticket?.ready(for: running.processIdentifier) == true {
                        timer.invalidate()
                        report("parent.json", ["pid": getpid(), "authenticatedReadyPID": running.processIdentifier])
                        NSApp.terminate(nil)
                    } else if running.isTerminated || ProcessInfo.processInfo.systemUptime >= deadline {
                        timer.invalidate(); self.ticket?.cancel(); report("error.json", ["error": "No authenticated readiness"]); exit(3)
                    }
                }
            }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { installation.stop() }
}
let app = NSApplication.shared
let delegate = Probe(); app.delegate = delegate; app.run()
