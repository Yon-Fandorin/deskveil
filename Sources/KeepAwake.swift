import Foundation
import IOKit.ps
import IOKit.pwr_mgt

enum BatteryReserve {
    static let preferenceKey = "batteryReservePercent"
    static let defaultPercent = 10
    static let range = 10...80
    static let step = 5
    static let choices = Array(stride(from: range.lowerBound, through: range.upperBound, by: step))

    static func percent(from value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let percent = number.doubleValue
        guard percent.isFinite, percent.rounded() == percent, percent.truncatingRemainder(dividingBy: Double(step)) == 0,
              Double(range.lowerBound)...Double(range.upperBound) ~= percent else { return nil }
        return Int(percent)
    }

    static func stored(in defaults: UserDefaults = .standard) -> Int {
        percent(from: defaults.object(forKey: preferenceKey)) ?? defaultPercent
    }
}

struct PowerSourceState {
    let acPower: Bool
    var batteryPercent: Int? = nil

    func restriction(allowBattery: Bool, reservePercent: Int = BatteryReserve.defaultPercent) -> PowerRestriction? {
        if acPower { return nil }
        guard allowBattery else { return .externalPowerRequired }
        guard let batteryPercent, (0...100).contains(batteryPercent) else { return .batteryUnavailable }
        return batteryPercent > reservePercent ? nil : .batteryLow
    }
}

enum PowerRestriction: String {
    case externalPowerRequired = "power-required"
    case batteryLow = "battery-low"
    case batteryUnavailable = "battery-unavailable"

    func message(reservePercent: Int = BatteryReserve.defaultPercent) -> String {
        switch self {
        case .externalPowerRequired:
            return L10n.text("전원을 연결하거나 ‘배터리에서도 계속 실행’을 켜주세요.")
        case .batteryLow:
            return L10n.text("배터리가 %@% 이하라 작업 유지를 종료했습니다. 전원을 연결한 뒤 다시 차단해주세요.", String(describing: reservePercent))
        case .batteryUnavailable:
            return L10n.text("배터리 잔량을 확인할 수 없어 작업 유지를 중단했습니다. 전원을 연결한 뒤 다시 시도해주세요.")
        }
    }
}

enum NativePowerSource {
    static func current() -> PowerSourceState {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else {
            return PowerSourceState(acPower: false)
        }
        var percent: Int?
        let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  info[kIOPSIsPresentKey] as? Bool != false,
                  let capacity = info[kIOPSCurrentCapacityKey] as? Double,
                  let maximum = info[kIOPSMaxCapacityKey] as? Double,
                  capacity.isFinite, maximum.isFinite, maximum > 0, (0...maximum).contains(capacity) else { continue }
            percent = Int((capacity / maximum * 100).rounded(.down))
            break
        }
        return PowerSourceState(acPower: type as String == kIOPSACPowerValue, batteryPercent: percent)
    }
}

protocol WakeAssertionDriver {
    func create(_ type: String, timeout: TimeInterval) throws -> IOPMAssertionID
    func renew(_ id: IOPMAssertionID, timeout: TimeInterval) throws
    func release(_ id: IOPMAssertionID)
}

struct NativeWakeAssertions: WakeAssertionDriver {
    func create(_ type: String, timeout: TimeInterval) throws -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithDescription(type as CFString,
            "SoftLock: active input session" as CFString, nil, nil, nil,
            timeout, kIOPMAssertionTimeoutActionTurnOff as CFString, &id)
        guard result == kIOReturnSuccess else {
            throw NSError(domain: "SoftLock.Power", code: Int(result),
                          userInfo: [NSLocalizedDescriptionKey: "\(type): \(result)"])
        }
        return id
    }

    func renew(_ id: IOPMAssertionID, timeout: TimeInterval) throws {
        // Updating the timeout also re-arms an assertion that timed out with TurnOff.
        let result = IOPMAssertionSetProperty(id, kIOPMAssertionTimeoutKey as CFString, NSNumber(value: timeout))
        guard result == kIOReturnSuccess else {
            throw NSError(domain: "SoftLock.Power", code: Int(result),
                          userInfo: [NSLocalizedDescriptionKey: "assertion renewal: \(result)"])
        }
    }

    func release(_ id: IOPMAssertionID) { IOPMAssertionRelease(id) }

}

/// Owns the same three assertion types as caffeinate -dis within the chosen power scope.
/// Power Management turns them off if main-loop updates stop; process exit removes them.
final class KeepAwakeController {
    static let assertionTypes = ["PreventUserIdleDisplaySleep", "PreventUserIdleSystemSleep", "PreventSystemSleep"]
    static let leaseDuration: TimeInterval = 6
    private let driver: WakeAssertionDriver
    private let powerSource: () -> PowerSourceState
    private let now: () -> TimeInterval
    private var ids: [IOPMAssertionID] = []
    private var leaseExpiresAt: TimeInterval?
    private(set) var source = PowerSourceState(acPower: false)
    var acPower: Bool { source.acPower }
    var active: Bool {
        ids.count == Self.assertionTypes.count && leaseExpiresAt.map { now() < $0 } == true
    }

    init(driver: WakeAssertionDriver = NativeWakeAssertions(),
         powerSource: @escaping () -> PowerSourceState = NativePowerSource.current,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.driver = driver
        self.powerSource = powerSource
        self.now = now
    }

    @discardableResult
    func update(locked: Bool, enabled: Bool, allowBattery: Bool = false,
                reservePercent: Int = BatteryReserve.defaultPercent) -> String? {
        source = powerSource()
        guard locked && enabled && source.restriction(allowBattery: allowBattery, reservePercent: reservePercent) == nil else { stop(); return nil }
        let started = now()
        do {
            if ids.isEmpty {
                for type in Self.assertionTypes { ids.append(try driver.create(type, timeout: Self.leaseDuration)) }
            } else {
                for id in ids { try driver.renew(id, timeout: Self.leaseDuration) }
            }
            // powerd schedules timeout values in whole seconds; keep local status conservative.
            leaseExpiresAt = started + Self.leaseDuration - 1
            return nil
        } catch {
            stop()
            return L10n.text("잠자기 방지를 유지할 수 없습니다: %@", String(describing: error.localizedDescription))
        }
    }

    func stop() {
        ids.forEach { driver.release($0) }
        ids.removeAll()
        leaseExpiresAt = nil
    }

    deinit { stop() }
}
