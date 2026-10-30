import Foundation

struct DisplayPowerCommand: Codable, Equatable {
    let displayID: UInt32
    let identity: String
    let off: Bool

    var valid: Bool { displayID != 0 && !identity.isEmpty && identity.utf8.count <= 256 }
    var wire: String? {
        guard valid, let data = try? JSONEncoder().encode(self) else { return nil }
        return "individual:" + data.base64EncodedString()
    }
    init(displayID: UInt32, identity: String, off: Bool) {
        self.displayID = displayID; self.identity = identity; self.off = off
    }
    init?(payload: String) {
        guard payload.utf8.count <= 1024, let data = Data(base64Encoded: payload),
              let command = try? JSONDecoder().decode(Self.self, from: data), command.valid else { return nil }
        self = command
    }
}

enum DisplayPowerOutcome: String {
    case off = "individual-off", on = "individual-on"
    case unsupported = "individual-unsupported", failed = "individual-failed"
    case recoveryNeeded = "individual-recovery-needed", busy = "individual-busy"
    case rollbackRestored = "individual-rollback-restored"
}

/// UI state changes only on the matching helper acknowledgement, never on click.
struct IndividualDisplayControls {
    private struct Request {
        let id: UInt64
        let command: DisplayPowerCommand
        let deadline: TimeInterval
        var pending: Bool
    }
    private var nextID: UInt64 = 0
    private var requests: [String: Request] = [:]
    private(set) var off: Set<String> = []
    private(set) var errors: [String: String] = [:]
    var pending: Set<String> { Set(requests.filter { $0.value.pending }.keys) }
    var hasWork: Bool { !off.isEmpty || !pending.isEmpty }

    func brightnessTarget(for reply: GuardianReply) -> DisplayBrightnessTarget? {
        guard reply.message.hasPrefix("individual-"),
              let request = requests.values.first(where: { $0.id == reply.id }) else { return nil }
        return DisplayBrightnessTarget(displayID: request.command.displayID, identity: request.command.identity)
    }

    mutating func begin(_ command: DisplayPowerCommand, at now: TimeInterval) -> UInt64? {
        guard command.valid, !pending.contains(command.identity) else { return nil }
        nextID += 1
        requests[command.identity] = Request(id: nextID, command: command, deadline: now + 8, pending: true)
        errors.removeValue(forKey: command.identity)
        return nextID
    }
    @discardableResult mutating func receive(_ reply: GuardianReply) -> Bool {
        guard reply.message.hasPrefix("individual-"),
              let (key, request) = requests.first(where: { $0.value.id == reply.id }) else { return false }
        switch reply.message {
        case DisplayPowerOutcome.off.rawValue where request.command.off:
            off.insert(key); errors.removeValue(forKey: key)
        case DisplayPowerOutcome.on.rawValue where !request.command.off:
            off.remove(key); errors.removeValue(forKey: key)
        case DisplayPowerOutcome.rollbackRestored.rawValue where request.command.off:
            off.remove(key)
            errors[key] = L10n.text("화면 변경에 실패해 원래 화면으로 복원했습니다.")
        case DisplayPowerOutcome.unsupported.rawValue:
            errors[key] = L10n.text("이 화면은 개별 끄기를 지원하지 않습니다.")
        case DisplayPowerOutcome.busy.rawValue:
            errors[key] = L10n.text("다른 화면 처리가 끝난 뒤 다시 시도해주세요.")
        case DisplayPowerOutcome.recoveryNeeded.rawValue:
            off.insert(key)
            errors[key] = L10n.text("원래 화면을 복원하지 못했습니다. 켜기를 다시 누르거나 긴급 해제해주세요.")
        case DisplayPowerOutcome.failed.rawValue:
            errors[key] = L10n.text("화면 변경에 실패했습니다. 연결 상태를 확인해주세요.")
        case "individual-maintenance-restored" where request.command.off && off.contains(key):
            errors.removeValue(forKey: key)
        case "individual-maintenance-failed" where request.command.off && off.contains(key):
            errors[key] = L10n.text("화면을 어둡게 유지하지 못했습니다. 켜기로 복원한 뒤 다시 시도해주세요.")
        default: return false
        }
        requests[key]?.pending = false
        return true
    }
    mutating func expire(at now: TimeInterval) {
        for (key, request) in requests where request.pending && now >= request.deadline {
            requests[key]?.pending = false
            // The command may have reached the display even if its reply was lost.
            off.insert(key)
            errors[key] = L10n.text("화면 응답이 지연됩니다. 켜기로 복원하거나 긴급 해제해주세요.")
        }
    }
    mutating func reset() { requests.removeAll(); off.removeAll(); errors.removeAll() }
}

/// Guardian acknowledgements retain the request that authorized each effect.
/// Recovery of a failed Off rolls back that request; it never acknowledges On.
struct IndividualDisplaySession {
    struct Recovery {
        let id: UInt64
        let rollback: Bool
    }
    private var offRequests: [String: UInt64] = [:]
    private(set) var recoveries: [String: Recovery] = [:]
    private var failures = Set<String>()

    mutating func record(_ command: DisplayPowerCommand, id: UInt64, outcome: DisplayPowerOutcome) {
        switch outcome {
        case .off:
            offRequests[command.identity] = id
            recoveries.removeValue(forKey: command.identity)
        case .on, .failed:
            offRequests.removeValue(forKey: command.identity)
            recoveries.removeValue(forKey: command.identity)
        case .recoveryNeeded:
            offRequests.removeValue(forKey: command.identity)
            recoveries[command.identity] = Recovery(id: id, rollback: command.off)
        default: return
        }
        failures.remove(command.identity)
    }
    mutating func maintenance(failed: Set<String>, verified: Set<String>) -> [GuardianReply] {
        var replies: [GuardianReply] = []
        for key in failed.subtracting(failures).sorted() {
            if let id = offRequests[key] { replies.append(.init(message: "individual-maintenance-failed", id: id)) }
        }
        for key in failures.intersection(verified).subtracting(failed).sorted() {
            if let id = offRequests[key] { replies.append(.init(message: "individual-maintenance-restored", id: id)) }
        }
        failures.subtract(verified.subtracting(failed))
        failures.formUnion(failed)
        return replies
    }
    mutating func recovered(_ identity: String) -> GuardianReply? {
        guard let request = recoveries.removeValue(forKey: identity) else { return nil }
        return GuardianReply(message: request.rollback ? DisplayPowerOutcome.rollbackRestored.rawValue : DisplayPowerOutcome.on.rawValue,
                             id: request.id)
    }
    mutating func reset() { offRequests.removeAll(); recoveries.removeAll(); failures.removeAll() }
}
