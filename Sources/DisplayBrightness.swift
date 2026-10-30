import Foundation

/// Read-only requests share the brightness guardian's serialized DDC transport.
struct DisplayBrightnessTarget: Codable, Hashable {
    let displayID: UInt32
    let identity: String
    var valid: Bool { displayID != 0 && !identity.isEmpty && identity.utf8.count <= 256 }
    var wire: String? {
        guard valid, let data = try? JSONEncoder().encode(self) else { return nil }
        return "brightness-status:" + data.base64EncodedString()
    }
    init(displayID: UInt32, identity: String) { self.displayID = displayID; self.identity = identity }
    init?(payload: String) {
        guard payload.utf8.count <= 1024, let data = Data(base64Encoded: payload),
              let target = try? JSONDecoder().decode(Self.self, from: data), target.valid else { return nil }
        self = target
    }
}

struct DisplayBrightnessObservation: Codable {
    let target: DisplayBrightnessTarget
    let value: Float?
    var message: String? {
        guard target.valid, value == nil || Self.valid(value!),
              let data = try? JSONEncoder().encode(self) else { return nil }
        return "brightness-status:" + data.base64EncodedString()
    }
    static func valid(_ value: Float) -> Bool { value.isFinite && (0...1).contains(value) }
    init(target: DisplayBrightnessTarget, value: Float?) { self.target = target; self.value = value }
    init?(message: String) {
        let prefix = "brightness-status:"
        guard message.hasPrefix(prefix), message.utf8.count <= 2048,
              let data = Data(base64Encoded: String(message.dropFirst(prefix.count))),
              let sample = try? JSONDecoder().decode(Self.self, from: data), sample.target.valid,
              sample.value == nil || Self.valid(sample.value!) else { return nil }
        self = sample
    }
}

/// Main-thread cache. A sample belongs to both the current ID and stable UUID;
/// stale replies, reconnects and expired measurements cannot supply a percentage.
struct DisplayBrightnessReadings {
    struct Request { let target: DisplayBrightnessTarget; let id: UInt64; let started: TimeInterval }
    private struct Sample { let value: Float?; let received: TimeInterval }
    private var samples: [DisplayBrightnessTarget: Sample] = [:]
    private var attempted: [DisplayBrightnessTarget: TimeInterval] = [:]
    private var nextID: UInt64 = 0
    private(set) var pending: Request?

    mutating func begin(_ candidates: [DisplayBrightnessTarget], at now: TimeInterval) -> Request? {
        let eligible = Set(candidates.filter(\.valid))
        samples = samples.filter { eligible.contains($0.key) }
        attempted = attempted.filter { eligible.contains($0.key) }
        if let request = pending, !eligible.contains(request.target) || !Self.current(request, at: now) { pending = nil }
        guard pending == nil else { return nil }
        let target = candidates.filter { candidate in
            guard eligible.contains(candidate) else { return false }
            let interval: TimeInterval = samples[candidate]?.value == nil ? 10 : 3
            return attempted[candidate].map { now - $0 >= interval } ?? true
        }.min { (attempted[$0] ?? -.infinity) < (attempted[$1] ?? -.infinity) }
        guard let target else { return nil }
        nextID += 1
        let request = Request(target: target, id: nextID, started: now)
        pending = request; attempted[target] = now
        return request
    }
    @discardableResult mutating func receive(_ reply: GuardianReply, at now: TimeInterval) -> Bool {
        guard let request = pending, request.id == reply.id else { return false }
        guard Self.current(request, at: now) else { pending = nil; return false }
        guard
              let sample = DisplayBrightnessObservation(message: reply.message), sample.target == request.target else { return false }
        pending = nil
        samples[request.target] = Sample(value: sample.value, received: now)
        return true
    }
    func value(for target: DisplayBrightnessTarget, at now: TimeInterval) -> Float? {
        guard let sample = samples[target], now >= sample.received, now - sample.received <= 5 else { return nil }
        return sample.value
    }
    mutating func invalidate() { pending = nil; samples.removeAll(); attempted.removeAll() }
    mutating func invalidate(_ target: DisplayBrightnessTarget) {
        if pending?.target == target { pending = nil }
        samples.removeValue(forKey: target)
        attempted.removeValue(forKey: target)
    }
    private static func current(_ request: Request, at now: TimeInterval) -> Bool {
        let elapsed = now - request.started
        return elapsed.isFinite && elapsed >= 0 && elapsed < 4
    }
}
