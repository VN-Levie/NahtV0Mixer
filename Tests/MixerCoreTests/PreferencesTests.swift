import XCTest
@testable import MixerCore

final class MixerPreferencesTests: XCTestCase {
    func testPersistentBundleLevelAndMuteKeepSeparateValues() throws {
        let name = "NahtV0Mixer.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = MixerPreferences(defaults: defaults)
        preferences.set(ApplicationLevel(volume: 0.35, muted: true), for: "app.example")
        let loaded = MixerPreferences(defaults: defaults).level(for: "app.example")
        XCTAssertEqual(loaded.volume, 0.35)
        XCTAssertTrue(loaded.muted)
        XCTAssertEqual(loaded.gain, 0)
        preferences.remove("app.example")
        XCTAssertEqual(MixerPreferences(defaults: defaults).level(for: "app.example"), ApplicationLevel())
    }
    func testProcessIdentifiersAreNeverPersistedAcrossLaunches() throws {
        let name = "NahtV0Mixer.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = MixerPreferences(defaults: defaults)
        preferences.set(ApplicationLevel(volume: 0), for: "process:123")
        XCTAssertEqual(MixerPreferences(defaults: defaults).level(for: "process:123"), ApplicationLevel())
    }
    func testInvalidGainAndCorruptPreferencesDoNotMuteOrBoostUnexpectedly() throws {
        XCTAssertEqual(ApplicationLevel(volume: .nan).gain, 1)
        XCTAssertEqual(ApplicationLevel(volume: .infinity).gain, 1)
        XCTAssertEqual(ApplicationLevel(volume: -1).gain, 0)
        XCTAssertEqual(ApplicationLevel(volume: 2).gain, 1)
        XCTAssertFalse(ApplicationLevel().needsProcessing)
        XCTAssertTrue(ApplicationLevel(muted: true).needsProcessing)
        let name = "NahtV0Mixer.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("invalid".utf8), forKey: "applicationLevels.v1")
        XCTAssertTrue(MixerPreferences(defaults: defaults).levels.isEmpty)
    }
}
