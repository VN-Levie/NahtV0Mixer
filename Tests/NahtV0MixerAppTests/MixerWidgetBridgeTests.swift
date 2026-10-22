import AppKit
import Combine
import XCTest
@testable import AudioRouting
@testable import MixerWidgetCore
@testable import NahtV0MixerApp

@MainActor
final class MixerWidgetBridgeTests: XCTestCase {
    func testStartPublishesOfflineDisabledStateWithoutAudioActions() async throws {
        let fixture = try Fixture()
        fixture.source.outputDevices = []
        fixture.source.systemVolume = nil
        fixture.source.systemMuted = nil
        let bridge = try fixture.bridge()
        bridge.start(scheduleTimer: false)
        let snapshot = try XCTUnwrap(fixture.store.readSnapshot())
        XCTAssertTrue(snapshot.isRunning)
        XCTAssertFalse(snapshot.mixerEnabled)
        XCTAssertNil(snapshot.systemVolume)
        XCTAssertNil(snapshot.systemMuted)
        XCTAssertEqual(fixture.source.actions, [])
        XCTAssertEqual(fixture.reloads, 1)
        bridge.stop()
    }

    func testSystemVolumeAndMuteWorkWhilePerAppMixerDisabled() async throws {
        let fixture = try Fixture(); let bridge = try fixture.bridge()
        bridge.start(scheduleTimer: false)
        let session = try fixture.sessionID()
        try fixture.store.submit(WidgetCommand(sessionID: session, issuedAt: fixture.now.addingTimeInterval(-0.1), action: .setSystemVolume(0.4)))
        try fixture.store.submit(WidgetCommand(sessionID: session, issuedAt: fixture.now, action: .setSystemMuted(true)))
        bridge.poll()
        XCTAssertEqual(fixture.source.actions, ["system:0.4", "system-muted:true"])
        XCTAssertEqual(fixture.store.pendingCommands().count, 0)
        bridge.stop()
    }

    func testAppActionsAreBlockedWhenMixerOff() async throws {
        let fixture = try Fixture(); let bridge = try fixture.bridge()
        bridge.start(scheduleTimer: false)
        let commandID = try fixture.submit(.setAppVolume(id: "player", value: 0.3))
        bridge.poll()
        XCTAssertTrue(fixture.source.actions.isEmpty)
        let reply = try XCTUnwrap(fixture.store.readReply(id: commandID))
        XCTAssertNotNil(reply.error)
        bridge.stop()
    }

    func testUnknownAppStaleSessionAndExpiredCommandsAreRejected() async throws {
        let fixture = try Fixture(); let bridge = try fixture.bridge()
        bridge.start(scheduleTimer: false)
        let session = try fixture.sessionID()
        try fixture.store.submit(WidgetCommand(sessionID: session, issuedAt: fixture.now, action: .setAppMuted(id: "missing", muted: true)))
        let stale = WidgetCommand(sessionID: UUID(), issuedAt: fixture.now, action: .refresh)
        try fixture.store.submit(stale)
        let expired = WidgetCommand(sessionID: session, issuedAt: fixture.now.addingTimeInterval(-11), action: .refresh)
        try fixture.store.submit(expired)
        bridge.poll()
        XCTAssertEqual(fixture.source.actions, [])
        XCTAssertEqual(fixture.store.pendingCommands().count, 0)
        bridge.stop()
    }

    func testCommandWithExistingReplyIsNotReexecuted() async throws {
        let fixture = try Fixture(); let bridge = try fixture.bridge()
        bridge.start(scheduleTimer: false)
        let session = try fixture.sessionID()
        let command = WidgetCommand(sessionID: session, issuedAt: fixture.now, action: .setSystemVolume(0.2))
        try fixture.store.submit(command)
        try fixture.store.writeReply(WidgetReply(id: command.id, snapshot: try XCTUnwrap(fixture.store.readSnapshot())))
        bridge.poll()
        XCTAssertTrue(fixture.source.actions.isEmpty)
        XCTAssertTrue(fixture.store.pendingCommands().isEmpty)
        bridge.stop()
    }

    func testBusyCompletionAcknowledgesOnlyAfterBusyClears() async throws {
        let fixture = try Fixture(); let bridge = try fixture.bridge()
        bridge.start(scheduleTimer: false)
        let session = try fixture.sessionID()
        fixture.source.busyOnEnable = true
        let command = WidgetCommand(sessionID: session, issuedAt: fixture.now, action: .setMixerEnabled(true))
        try fixture.store.submit(command)
        bridge.poll()
        XCTAssertEqual(fixture.source.actions, ["enabled:true"])
        XCTAssertEqual(fixture.store.pendingCommands().count, 1)
        XCTAssertNil(fixture.store.readReply(id: command.id))
        fixture.source.isBusy = false
        bridge.poll()
        XCTAssertTrue(fixture.store.pendingCommands().isEmpty)
        XCTAssertNotNil(fixture.store.readReply(id: command.id))
        bridge.stop()
    }

    func testStopPublishesNotRunningAndHeartbeatReloadIsThrottled() async throws {
        let fixture = try Fixture(); let bridge = try fixture.bridge()
        bridge.start(scheduleTimer: false)
        XCTAssertEqual(fixture.reloads, 1)
        bridge.poll(); bridge.poll(); bridge.poll()
        XCTAssertEqual(fixture.reloads, 1)
        bridge.stop()
        let snapshot = try XCTUnwrap(fixture.store.readSnapshot())
        XCTAssertFalse(snapshot.isRunning)
        XCTAssertEqual(fixture.reloads, 2)
    }

    func testAppMuteWaitsForRouteFailureAndReturnsItToWidget() async throws {
        let fixture = try Fixture(); let bridge = try fixture.bridge()
        fixture.source.isMixerEnabled = true
        fixture.source.busyOnAppChange = true
        bridge.start(scheduleTimer: false)
        let id = try fixture.submit(.setAppMuted(id: "player", muted: true))
        bridge.poll()
        XCTAssertEqual(fixture.source.actions, ["player-muted:true"])
        XCTAssertNil(fixture.store.readReply(id: id))
        fixture.source.applications[0].error = "Audio access denied"
        fixture.source.isBusy = false
        bridge.poll()
        XCTAssertEqual(fixture.store.readReply(id: id)?.error, "Audio access denied")
        XCTAssertTrue(fixture.store.pendingCommands().isEmpty)
        bridge.stop()
    }

    func testAppVolumeWaitsForRouteCompletionBeforeSuccess() async throws {
        let fixture = try Fixture(); let bridge = try fixture.bridge()
        fixture.source.isMixerEnabled = true
        fixture.source.busyOnAppChange = true
        bridge.start(scheduleTimer: false)
        let id = try fixture.submit(.setAppVolume(id: "player", value: 0.25))
        bridge.poll()
        XCTAssertNil(fixture.store.readReply(id: id))
        fixture.source.isBusy = false
        bridge.poll()
        let reply = try XCTUnwrap(fixture.store.readReply(id: id))
        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.snapshot.apps.first?.volume, 0.25)
        bridge.stop()
    }
}

@MainActor
private final class Fixture {
    let source = FakeWidgetMixerSource()
    let store: WidgetSharedStore
    var now = Date(timeIntervalSince1970: 1_700_000_000)
    var reloads = 0

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NahtV0MixerWidgetTests-\(UUID().uuidString)")
        store = try WidgetSharedStore(directory: url)
    }

    deinit { try? FileManager.default.removeItem(at: store.directory) }

    func bridge() throws -> MixerWidgetBridge {
        MixerWidgetBridge(source: source, storage: store, now: { self.now }, reload: { self.reloads += 1 })
    }

    func sessionID() throws -> UUID { try XCTUnwrap(store.readSnapshot()?.sessionID) }
    func commandID() throws -> UUID { try XCTUnwrap(store.pendingCommands().first?.id) }
    func submit(_ action: WidgetAction) throws -> UUID {
        let command = WidgetCommand(sessionID: try sessionID(), issuedAt: now, action: action)
        try store.submit(command)
        return command.id
    }
}

@MainActor
private final class FakeWidgetMixerSource: WidgetMixerSource {
    let objectWillChange = ObservableObjectPublisher()
    var applications = [MixerApplication(id: "player", name: "Player", bundleURL: nil, volume: 0.6,
                                          isMuted: false, isActive: true, isProcessing: false, error: nil)]
    var outputDevices = [AudioOutputDevice(id: 1, name: "Speakers", uid: "fixture", sampleRate: 48_000)]
    var selectedOutputID: UInt32 = 1
    var systemVolume: Double? = 0.5
    var systemMuted: Bool? = false
    var isMixerEnabled = false
    var isBusy = false
    var lastError: String?
    var actions: [String] = []
    var busyOnEnable = false
    var busyOnAppChange = false

    func setMixerEnabled(_ enabled: Bool) {
        actions.append("enabled:\(enabled)")
        isMixerEnabled = enabled
        if busyOnEnable { isBusy = true }
    }
    func setSystemVolume(_ value: Double) { actions.append("system:\(value)") ; systemVolume = value }
    func setSystemMuted(_ value: Bool) { actions.append("system-muted:\(value)") ; systemMuted = value }
    func selectOutput(_ id: UInt32) { selectedOutputID = id }
    func setVolume(_ value: Double, for id: String) {
        actions.append("\(id):\(value)")
        if let index = applications.firstIndex(where: { $0.id == id }) { applications[index].volume = value }
        if busyOnAppChange { isBusy = true }
    }
    func setMuted(_ muted: Bool, for id: String) {
        actions.append("\(id)-muted:\(muted)")
        if let index = applications.firstIndex(where: { $0.id == id }) { applications[index].isMuted = muted }
        if busyOnAppChange { isBusy = true }
    }
    func resetApplication(_ id: String) {}
    func refresh() { actions.append("refresh") }
}
