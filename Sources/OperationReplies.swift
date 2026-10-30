import Foundation

struct GuardianReply: Equatable {
    let message: String
    let id: UInt64
    init(message: String, id: UInt64) { self.message = message; self.id = id }
    init?(_ raw: String) {
        let parts = raw.split(separator: "@", maxSplits: 1)
        guard parts.count == 2, let id = UInt64(parts[1]) else { return nil }
        self.message = String(parts[0]); self.id = id
    }
}

/// Each effect has its own expected reply; a heartbeat never supersedes work.
struct OperationReplies {
    enum Operation: String, CaseIterable {
        case dim, cover, coverRelease, restore, failureCover, failureRestore
    }
    private var next: UInt64 = 0
    private var expected: [Operation: UInt64] = [:]
    mutating func begin(_ operation: Operation) -> UInt64 {
        next += 1; expected[operation] = next; return next
    }
    func accepts(_ operation: Operation, id: UInt64) -> Bool { expected[operation] == id }
    func current(_ operation: Operation) -> UInt64? { expected[operation] }
    mutating func finish(_ operation: Operation, id: UInt64) -> Bool {
        guard accepts(operation, id: id) else { return false }
        expected.removeValue(forKey: operation); return true
    }
    mutating func cancel(_ operation: Operation) { expected.removeValue(forKey: operation) }
    mutating func cancelAll() { expected.removeAll() }
}
