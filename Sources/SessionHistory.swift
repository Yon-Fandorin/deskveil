import Darwin
import Foundation

enum SessionEndReason: String, CaseIterable {
    case manual, emergency, trialExpired, lidLimit, tapInterrupted, tapUnavailable
    case secureInput, filterReleased, unresponsive, systemSleep, sessionInactive
    case macOSLockConfirmed, applicationQuit, relaunch, update, other
    case lidEnded, coverFailure, brightnessGuardianExit, powerUnavailable
}

/// Records transitions and health flags only: never keys, text or screenshots.
final class SessionHistory {
    private(set) var lastEnd: [String: String] = [:]
    private let journal: LidJournal?
    private let queue = DispatchQueue(label: "dev.local.softlock.session-history", qos: .utility)
    private let writes = DispatchGroup()
    init(directory: URL? = nil) {
        let directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SoftLock", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var info = stat()
        if lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
           info.st_uid == getuid(), info.st_mode & 0o022 == 0 {
            journal = LidJournal(directory.appendingPathComponent("application-session.jsonl").path)
        } else { journal = nil }
        if let journal {
            var file = stat()
            if lstat(journal.path, &file) == 0, file.st_mode & S_IFMT == S_IFREG,
               file.st_uid == getuid(), file.st_size <= 1_100_000,
               let data = try? Data(contentsOf: URL(fileURLWithPath: journal.path)) {
                for line in data.split(separator: 10).reversed() {
                    guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          row["event"] as? String == "session-ended", let reason = row["reason"] as? String,
                          let at = row["occurredAt"] as? String ?? row["at"] as? String else { continue }
                    lastEnd = ["reason": reason, "at": at]
                    if let requested = row["requestedReason"] as? String, !requested.isEmpty {
                        lastEnd["requestedReason"] = requested
                    }
                    break
                }
            }
        }
    }
    private func record(_ event: String, _ fields: [String: Any]) {
        guard let journal else { return }
        let fields = fields.merging(["occurredAt": ISO8601DateFormatter().string(from: Date())]) { old, _ in old }
        let writes = writes
        writes.enter()
        queue.async { journal.emit(event, fields); writes.leave() }
    }
    @discardableResult func flush(timeout: TimeInterval = 1) -> Bool {
        writes.wait(timeout: .now() + timeout) == .success
    }
    func started(source: String) { record("session-started", ["source": source, "pid": getpid()]) }
    func ended(_ reason: SessionEndReason, tapEnabled: Bool, secureInput: Bool, macOSState: String,
               requestedReason: SessionEndReason? = nil) {
        lastEnd = ["reason": reason.rawValue, "at": ISO8601DateFormatter().string(from: Date())]
        if let requestedReason { lastEnd["requestedReason"] = requestedReason.rawValue }
        record("session-ended", ["reason": reason.rawValue, "pid": getpid(), "occurredAt": lastEnd["at"]!,
            "tapEnabled": tapEnabled, "secureInput": secureInput, "macOSState": macOSState,
            "requestedReason": requestedReason?.rawValue ?? ""])
    }
}
