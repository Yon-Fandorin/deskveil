import XCTest
@testable import SoftLock

final class LocalizationTests: XCTestCase {
    func testAppLanguageDefaultsAndInvalidPreferencesFollowMacOS() {
        let suite = "dev.local.softlock.language-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppLanguage.selection(in: defaults), .system)
        defaults.set("unknown", forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(AppLanguage.selection(in: defaults), .system)
    }

    func testExplicitLanguageRoundTripsWithoutChangingMacOSPreferences() {
        let suite = "dev.local.softlock.language-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["ko", "en"], forKey: "AppleLanguages")
        defaults.set(true, forKey: "dimScreenEnabled")
        for language in [AppLanguage.en, .ko, .system] {
            language.store(in: defaults)
            XCTAssertEqual(AppLanguage.selection(in: defaults), language)
            XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["ko", "en"])
            XCTAssertTrue(defaults.bool(forKey: "dimScreenEnabled"))
        }
        XCTAssertNil(defaults.object(forKey: AppLanguage.preferenceKey))
    }
}
