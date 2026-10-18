import Foundation
import XCTest
@testable import NahtV0MixerApp

final class PreferencesTests: XCTestCase {
    @MainActor
    func testFreshPreferencesFollowSystemWithoutWritingDefaults() async throws {
        let name = "NahtV0Mixer.preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.language, .system)
        XCTAssertEqual(preferences.theme, .system)
        XCTAssertNil(defaults.object(forKey: "interfaceLanguage"))
        XCTAssertNil(defaults.object(forKey: "interfaceTheme"))
    }

    @MainActor
    func testPreferenceChangesSurviveRecreation() async throws {
        let name = "NahtV0Mixer.preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.language = .vietnamese
        preferences.theme = .dark
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.language, .vietnamese)
        XCTAssertEqual(restored.theme, .dark)
        XCTAssertEqual(restored.text("Settings"), "Cài đặt")
    }

    @MainActor
    func testUnknownStoredValuesRecoverToSystem() async throws {
        let name = "NahtV0Mixer.preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("old-language", forKey: "interfaceLanguage")
        defaults.set("unknown-theme", forKey: "interfaceTheme")
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.language, .system)
        XCTAssertEqual(preferences.theme, .system)
    }

    func testSystemLanguageUsesPrimaryPreferenceAndExplicitChoiceWins() {
        XCTAssertEqual(MixerLanguage.system.languageCode(preferredLanguages: ["vi-VN", "en"]), "vi")
        XCTAssertEqual(MixerLanguage.system.languageCode(preferredLanguages: ["en-US", "vi"]), "en")
        XCTAssertEqual(MixerLanguage.system.languageCode(preferredLanguages: []), "en")
        XCTAssertEqual(MixerLanguage.english.languageCode(preferredLanguages: ["vi"]), "en")
        XCTAssertEqual(MixerLanguage.vietnamese.languageCode(preferredLanguages: ["en"]), "vi")
    }

    func testUntranslatedDiagnosticsRemainReadable() {
        XCTAssertEqual(LocalText.text("Core Audio returned -50", languageCode: "vi"), "Core Audio returned -50")
        XCTAssertEqual(LocalText.text("Settings", languageCode: "en"), "Settings")
    }

    @MainActor
    func testLoginItemInitAndRefreshNeverRegister() async {
        let backend = FakeLoginBackend()
        let login = LoginItems(backend: backend)
        login.refresh()
        XCTAssertEqual(login.state, .off)
        XCTAssertTrue(backend.requests.isEmpty)
    }

    @MainActor
    func testLoginItemShowsApprovalAndCanDisablePendingRegistration() async {
        let backend = FakeLoginBackend()
        backend.nextState = .needsApproval
        let login = LoginItems(backend: backend)
        login.setEnabled(true)
        XCTAssertEqual(login.state, .needsApproval)
        XCTAssertTrue(login.state.isRequested)
        backend.nextState = .off
        login.setEnabled(false)
        XCTAssertEqual(login.state, .off)
        XCTAssertEqual(backend.requests, [true, false])
    }

    @MainActor
    func testRegistrationFailureReportsActualState() async {
        let backend = FakeLoginBackend()
        backend.failure = NSError(domain: "LoginTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Registration failed"])
        let login = LoginItems(backend: backend)
        login.setEnabled(true)
        XCTAssertEqual(login.state, .off)
        XCTAssertEqual(login.error, "Registration failed")
        backend.state = .on
        login.refresh()
        XCTAssertEqual(login.state, .on)
    }

    @MainActor
    func testAlreadyRequestedLoginItemIsNotRegisteredAgain() async {
        let backend = FakeLoginBackend()
        backend.state = .needsApproval
        let login = LoginItems(backend: backend)
        login.setEnabled(true)
        XCTAssertTrue(backend.requests.isEmpty)
    }
}

@MainActor
private final class FakeLoginBackend: LoginItemBackend {
    var state: LoginItemState = .off
    var nextState: LoginItemState = .on
    var failure: Error?
    var requests: [Bool] = []
    func changeRegistration(to enabled: Bool) throws {
        requests.append(enabled)
        if let failure { throw failure }
        state = nextState
    }
}
