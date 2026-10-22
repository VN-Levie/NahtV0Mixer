import Foundation
import Combine
import XCTest
@testable import NahtV0MixerApp

final class PreferencesTests: XCTestCase {
    @MainActor
    func testNeverSeenLoginServiceCanRegisterWhenUserEnablesIt() async {
        let backend = FakeLoginBackend()
        backend.state = LoginItemState(serviceStatus: .notFound)
        let login = LoginItems(backend: backend)
        login.refresh()
        XCTAssertEqual(login.state, .off)
        XCTAssertTrue(backend.requests.isEmpty)
        login.setEnabled(true)
        XCTAssertEqual(backend.requests, [true])
        XCTAssertEqual(login.state, .on)
    }

    @MainActor
    func testMixerRemembersExplicitEnableAndDisableAcrossLaunches() async throws {
        let name = "NahtV0Mixer.enabled-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = MixerStore(defaults: defaults)
        XCTAssertFalse(first.isMixerEnabled)
        XCTAssertNil(defaults.object(forKey: "perAppMixerEnabled"))
        // No start()/device discovery: these instances have no routable outputs.
        first.setMixerEnabled(true)
        first.shutdown()
        let next = MixerStore(defaults: defaults)
        XCTAssertTrue(next.isMixerEnabled)
        next.setMixerEnabled(false)
        next.shutdown()
        XCTAssertFalse(MixerStore(defaults: defaults).isMixerEnabled)
    }

    func testBundleMigrationPreservesExistingChoicesAndCopiesOnlyKnownPreferencesOnce() throws {
        let oldName = "NahtV0Mixer.legacy-test.\(UUID().uuidString)"
        let newName = "NahtV0Mixer.migration-test.\(UUID().uuidString)"
        let old = try XCTUnwrap(UserDefaults(suiteName: oldName))
        let new = try XCTUnwrap(UserDefaults(suiteName: newName))
        defer { old.removePersistentDomain(forName: oldName); new.removePersistentDomain(forName: newName) }
        old.set("vietnamese", forKey: "interfaceLanguage")
        old.set("dark", forKey: "interfaceTheme")
        old.set(Data("{}".utf8), forKey: "applicationLevels.v1")
        old.set(true, forKey: "perAppMixerEnabled")
        old.set("unrelated", forKey: "anotherSetting")
        new.set("light", forKey: "interfaceTheme")
        MixerPreferenceMigration.migrateIfNeeded(destination: new, legacy: old)
        XCTAssertEqual(new.string(forKey: "interfaceLanguage"), "vietnamese")
        XCTAssertEqual(new.string(forKey: "interfaceTheme"), "light")
        XCTAssertNotNil(new.data(forKey: "applicationLevels.v1"))
        XCTAssertTrue(new.bool(forKey: "perAppMixerEnabled"))
        XCTAssertNil(new.object(forKey: "anotherSetting"))
        new.removeObject(forKey: "interfaceLanguage")
        MixerPreferenceMigration.migrateIfNeeded(destination: new, legacy: old)
        XCTAssertNil(new.object(forKey: "interfaceLanguage"))
    }

    func testBundleMigrationPreservesExplicitDisabledMixerAndDoesNotOverwriteNewChoice() throws {
        let oldName = "NahtV0Mixer.legacy-enabled.\(UUID().uuidString)"
        let newName = "NahtV0Mixer.new-enabled.\(UUID().uuidString)"
        let old = try XCTUnwrap(UserDefaults(suiteName: oldName))
        let new = try XCTUnwrap(UserDefaults(suiteName: newName))
        defer { old.removePersistentDomain(forName: oldName); new.removePersistentDomain(forName: newName) }
        old.set(false, forKey: "perAppMixerEnabled")
        MixerPreferenceMigration.migrateIfNeeded(destination: new, legacy: old)
        XCTAssertEqual(new.object(forKey: "perAppMixerEnabled") as? Bool, false)
        new.set(true, forKey: "perAppMixerEnabled")
        MixerPreferenceMigration.migrateIfNeeded(destination: new, legacy: old)
        XCTAssertTrue(new.bool(forKey: "perAppMixerEnabled"))
    }

    @MainActor
    func testAppMuteAndVolumeRemainBusyUntilRouteQueueCompletes() async throws {
        let name = "NahtV0Mixer.busy-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = MixerStore(defaults: defaults)
        defer { store.shutdown() }
        for muteAction in [true, false] {
            let completed = expectation(description: "Route reconciliation completed")
            let observation = store.$isBusy.dropFirst().filter { !$0 }.prefix(1).sink { _ in completed.fulfill() }
            if muteAction { store.setMuted(true, for: "test.player") }
            else { store.setVolume(0.25, for: "test.player") }
            XCTAssertTrue(store.isBusy)
            await fulfillment(of: [completed], timeout: 2)
            withExtendedLifetime(observation) {}
            XCTAssertFalse(store.isBusy)
        }
    }

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
