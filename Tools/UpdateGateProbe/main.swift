import Darwin
import Foundation

// Compile with DeferredUpdate.swift only. No AppKit, event tap, brightness or
// power backend exists in this process, even for malformed fixture commands.
struct LidError: Error { let message: String; init(_ message: String) { self.message = message } }
enum PrivacyRecoveryCommand {
    static func authorizedClient(_ pid: pid_t, _ uid: uid_t) -> Bool { false }
}
let directory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
var info = stat()
guard directory.hasPrefix("/private/tmp/softlock-update-fixture-"), lstat(directory, &info) == 0,
      info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { exit(2) }
let gate = DeferredUpdateGate()
do { try gate.start() } catch { fputs("fixture gate failed: \(error)\n", stderr); exit(1) }
var finishing = false
gate.onCommit = { gate.stop(); exit(0) }
let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
    guard gate.pending, !finishing else { return }
    let readiness = UpdateReadiness(blocking: !FileManager.default.fileExists(atPath: directory + "/release"))
    if let reason = readiness.waitingReason { gate.reportWaiting(reason) }
    else {
        finishing = true
        gate.finish { sent in if !sent { gate.stop(); exit(1) } }
    }
}
RunLoop.main.add(timer, forMode: .common)
print("fixture-only \(getpid())"); fflush(stdout)
RunLoop.main.run()
