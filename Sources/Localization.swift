import Foundation

/// Uses the app bundle in packaged builds and the module bundle in SwiftPM tests.
/// Uses the app preference when set, otherwise the macOS per-app language.
/// The selection is frozen for this process; changing it requires a safe restart.
enum L10n {
    private static let resources: Bundle = {
        if Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en") != nil {
            return .main
        }
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }()

    static let bundle: Bundle = {
        let language = AppLanguage.selection()
        guard language != .system, let url = resources.url(forResource: language.rawValue, withExtension: "lproj"),
              let localized = Bundle(url: url) else { return resources }
        return localized
    }()

    private static let english = resources.url(forResource: "en", withExtension: "lproj")
        .flatMap(Bundle.init(url:))

    static func text(_ key: String, _ arguments: String...) -> String {
        let selected = bundle
        let fallback = english?.localizedString(forKey: key, value: key, table: nil) ?? key
        let template = selected.localizedString(forKey: key, value: fallback, table: nil)
        guard !arguments.isEmpty else { return template }
        // Values are strings, never format directives. Preserve literal percent signs.
        let format = template.replacingOccurrences(of: "%", with: "%%")
            .replacingOccurrences(of: "%%@", with: "%@")
        return String(format: format, locale: Locale.current, arguments: arguments)
    }
}

/// Only DeskVeil's own preference is written; macOS language preferences stay intact.
enum AppLanguage: String, CaseIterable {
    case system, en, ko
    static let preferenceKey = "interfaceLanguage"

    static func selection(in defaults: UserDefaults = .standard) -> AppLanguage {
        defaults.string(forKey: preferenceKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    func store(in defaults: UserDefaults = .standard) {
        if self == .system { defaults.removeObject(forKey: Self.preferenceKey) }
        else { defaults.set(rawValue, forKey: Self.preferenceKey) }
    }

    var title: String {
        switch self {
        case .system: return L10n.text("macOS 설정 따르기")
        case .en: return "English"
        case .ko: return "한국어"
        }
    }
}
