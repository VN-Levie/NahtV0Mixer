import AppKit
import Combine
import XCTest
@testable import AudioRouting
@testable import NahtV0MixerApp

final class MixerMenuTests: XCTestCase {
    @MainActor
    func testOpeningMenuOnlyReadsStateAndShowsNativeCommands() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let menu = fixture.controller.menu
        fixture.controller.menuNeedsUpdate(menu)
        XCTAssertTrue(fixture.source.actions.isEmpty)
        XCTAssertTrue(fixture.loginBackend.requests.isEmpty)
        XCTAssertEqual(try item("Per-app mixer", in: menu).state, .off)
        XCTAssertFalse(try slider("Player", in: menu).isEnabled)
        let output = try XCTUnwrap(item("Output: Speakers", in: menu).submenu)
        XCTAssertEqual(try item("Speakers", in: output).state, .on)
        XCTAssertEqual(try item("Headphones", in: output).state, .off)
    }

    @MainActor
    func testVolumeAndMuteActionsReachOnlyTheirIntendedTargets() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.source.isMixerEnabled = true
        let menu = fixture.controller.menu
        fixture.controller.menuNeedsUpdate(menu)
        let system = try slider("System volume", in: menu)
        system.doubleValue = 0.45
        system.sendAction(system.action, to: system.target)
        system.sendAction(system.action, to: system.target)
        let player = try slider("Player", in: menu)
        player.doubleValue = 0.3
        player.sendAction(player.action, to: player.target)
        invoke(try button("Mute", row: "System volume", in: menu))
        invoke(try button("Mute", row: "Player", in: menu))
        invoke(try button("Reset volume", row: "Player", in: menu))
        XCTAssertNil(menu.items.first { $0.title == "Player" }?.submenu)
        let outputs = try XCTUnwrap(item("Output: Speakers", in: menu).submenu)
        invoke(try item("Headphones", in: outputs))
        XCTAssertEqual(fixture.source.actions, ["system:0.45", "player:0.3", "system-muted:true",
                                               "player-muted:true", "reset:player", "output:2"])
    }

    @MainActor
    func testRefreshDuringTrackingKeepsControlsAndRejectsStaleApplicationActions() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.source.isMixerEnabled = true
        let controller = fixture.controller
        let menu = controller.menu
        controller.menuNeedsUpdate(menu)
        let system = try slider("System volume", in: menu)
        let player = try slider("Player", in: menu)
        let mute = try button("Mute", row: "Player", in: menu)
        controller.menuWillOpen(menu)
        fixture.source.systemVolume = 0.8
        fixture.source.applications = []
        controller.refreshValues()
        controller.menuNeedsUpdate(menu)
        XCTAssertTrue(controller.isTracking)
        XCTAssertTrue(try slider("System volume", in: menu) === system)
        XCTAssertEqual(system.doubleValue, 0.8)
        XCTAssertFalse(player.isEnabled)
        XCTAssertFalse(mute.isEnabled)
        player.sendAction(player.action, to: player.target)
        invoke(mute)
        XCTAssertTrue(fixture.source.actions.isEmpty)
        controller.menuDidClose(menu)
        controller.menuNeedsUpdate(menu)
        XCTAssertFalse(controller.isTracking)
        XCTAssertFalse(menu.items.contains { $0.title == "Player" })
    }

    @MainActor
    func testMixerOffAndBusyDisableAudioActionsAndUnknownVolumeIsUnavailable() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let menu = fixture.controller.menu
        fixture.controller.menuNeedsUpdate(menu)
        invoke(try item("Per-app mixer", in: menu))
        fixture.controller.refreshValues()
        XCTAssertEqual(fixture.source.actions, ["enabled:true"])
        XCTAssertTrue(try slider("Player", in: menu).isEnabled)
        fixture.source.isBusy = true
        fixture.source.systemVolume = nil
        fixture.controller.refreshValues()
        XCTAssertFalse(try slider("System volume", in: menu).isEnabled)
        XCTAssertFalse(try slider("Player", in: menu).isEnabled)
        invoke(try item("Per-app mixer", in: menu))
        XCTAssertEqual(fixture.source.actions, ["enabled:true"])
    }

    @MainActor
    func testSettingsChangeOnlyAfterExplicitSelectionAndApplyNextOpening() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        controller.menuNeedsUpdate(controller.menu)
        let settings = try XCTUnwrap(item("Settings", in: controller.menu).submenu)
        let languages = try XCTUnwrap(item("Language", in: settings).submenu)
        invoke(try item("Tiếng Việt", in: languages))
        XCTAssertEqual(fixture.preferences.language, .vietnamese)
        XCTAssertTrue(fixture.loginBackend.requests.isEmpty)
        invoke(try item("Launch at login", in: settings))
        XCTAssertEqual(fixture.loginBackend.requests, [true])
        controller.menuNeedsUpdate(controller.menu)
        XCTAssertNotNil(controller.menu.items.first { $0.title == "Cài đặt" })
        XCTAssertTrue(fixture.source.actions.isEmpty)
    }

    @MainActor
    private func item(_ title: String, in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { $0.title == title && $0.view == nil })
    }

    @MainActor
    private func slider(_ title: String, in menu: NSMenu) throws -> NSSlider {
        let view = try XCTUnwrap(menu.items.first { $0.title == title && $0.view != nil }?.view)
        return try XCTUnwrap(view.subviews.compactMap { $0 as? NSSlider }.first)
    }

    @MainActor
    private func invoke(_ item: NSMenuItem) {
        NSApplication.shared.sendAction(item.action!, to: item.target, from: item)
    }

    @MainActor
    private func button(_ title: String, row: String, in menu: NSMenu) throws -> NSButton {
        let view = try XCTUnwrap(menu.items.first { $0.title == row && $0.view != nil }?.view)
        let stack = try XCTUnwrap(view.subviews.compactMap { $0 as? NSStackView }.first)
        return try XCTUnwrap(stack.views.compactMap { $0 as? NSButton }.first { $0.toolTip == title })
    }

    @MainActor
    private func invoke(_ control: NSControl) { control.sendAction(control.action, to: control.target) }
}

@MainActor
private final class Fixture {
    let name = "NahtV0Mixer.menu.\(UUID().uuidString)"
    let source = MenuSource()
    let loginBackend = MenuLoginBackend()
    let defaults: UserDefaults
    let preferences: AppPreferences
    let controller: MixerMenuController

    init() {
        _ = NSApplication.shared
        defaults = UserDefaults(suiteName: name)!
        preferences = AppPreferences(defaults: defaults)
        preferences.language = .english
        controller = MixerMenuController(store: source, preferences: preferences,
                                         loginItems: LoginItems(backend: loginBackend), quit: {})
    }

    func cleanUp() { defaults.removePersistentDomain(forName: name) }
}

@MainActor
private final class MenuLoginBackend: LoginItemBackend {
    var state: LoginItemState = .off
    var requests: [Bool] = []
    func changeRegistration(to enabled: Bool) throws {
        requests.append(enabled)
        state = enabled ? .on : .off
    }
}

@MainActor
private final class MenuSource: MixerMenuSource {
    let objectWillChange = ObservableObjectPublisher()
    var applications = [MixerApplication(id: "player", name: "Player", bundleURL: nil, volume: 0.6,
                                        isMuted: false, isActive: true, isProcessing: false, error: nil)]
    var outputDevices = [AudioOutputDevice(id: 1, name: "Speakers", uid: "speaker-fixture", sampleRate: 48_000),
                         AudioOutputDevice(id: 2, name: "Headphones", uid: "headphone-fixture", sampleRate: 48_000)]
    var selectedOutputID: UInt32 = 1
    var systemVolume: Double? = 0.5
    var systemMuted: Bool? = false
    var isMixerEnabled = false
    var isBusy = false
    var lastError: String?
    var actions: [String] = []
    func setMixerEnabled(_ enabled: Bool) { actions.append("enabled:\(enabled)"); isMixerEnabled = enabled }
    func setSystemVolume(_ value: Double) { actions.append("system:\(value)") }
    func setSystemMuted(_ value: Bool) { actions.append("system-muted:\(value)") }
    func selectOutput(_ id: UInt32) { actions.append("output:\(id)") }
    func setVolume(_ value: Double, for id: String) { actions.append("\(id):\(value)") }
    func setMuted(_ muted: Bool, for id: String) { actions.append("\(id)-muted:\(muted)") }
    func resetApplication(_ id: String) { actions.append("reset:\(id)") }
}
