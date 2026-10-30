import Foundation

/// Zero means no deadline. A deadline belongs to one session, not each heartbeat.
enum LidDuration {
    static let preferenceKey = "lidDurationSeconds"
    static let maximumHours = 24 * 365
    static let choices: [(seconds: Int, title: String)] = [
        (0, L10n.text("무제한")), (3600, L10n.text("1시간")), (14400, L10n.text("4시간")), (28800, L10n.text("8시간")),
        (43200, L10n.text("12시간")), (86400, L10n.text("24시간")), (172800, L10n.text("48시간")),
        (259200, L10n.text("72시간")), (604800, L10n.text("7일"))
    ]

    static func seconds(from value: Any?, simulation: Bool = false) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let seconds = number.doubleValue
        guard seconds.isFinite, seconds >= 0, seconds <= Double(maximumHours * 3600),
              seconds == 0 || (simulation ? seconds >= 0.3 : seconds >= 3600 && seconds.truncatingRemainder(dividingBy: 3600) == 0) else { return nil }
        return seconds
    }

    static func stored(in defaults: UserDefaults = .standard) -> Int {
        Int(seconds(from: defaults.object(forKey: preferenceKey)) ?? 0)
    }

    static func remainingText(_ seconds: Double) -> String {
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes < 60 { return L10n.text("%@분 남음", String(describing: minutes)) }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? L10n.text("%@시간 남음", String(describing: hours)) : L10n.text("%@시간 %@분 남음", String(describing: hours), String(describing: rest))
    }
}
