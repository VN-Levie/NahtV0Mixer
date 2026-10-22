import Foundation
import XCTest
@testable import MixerWidgetCore

final class WidgetCoreControlRequestTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(
        mixerEnabled: Bool = true,
        volume: Double? = 0.5,
        muted: Bool? = false,
        appVolume: Double = 0.5,
        appMuted: Bool = false
    ) -> WidgetSnapshot {
        WidgetSnapshot(
            updatedAt: now, isRunning: true, mixerEnabled: mixerEnabled,
            systemVolume: volume, systemMuted: muted,
            apps: [WidgetAppState(id: "a", name: "A", volume: appVolume, isMuted: appMuted, isPlaying: true)]
        )
    }

    func testRepeatedTogglesUseCurrentSnapshot() throws {
        let before = snapshot(mixerEnabled: false)
        let after = snapshot(muted: true, appMuted: true)
        XCTAssertEqual(try WidgetControlRequest.toggleMixer.resolve(in: before, at: now), .setMixerEnabled(true))
        XCTAssertEqual(try WidgetControlRequest.toggleMixer.resolve(in: after, at: now), .setMixerEnabled(false))
        XCTAssertEqual(try WidgetControlRequest.toggleSystemMute.resolve(in: before, at: now), .setSystemMuted(true))
        XCTAssertEqual(try WidgetControlRequest.toggleSystemMute.resolve(in: after, at: now), .setSystemMuted(false))
        XCTAssertEqual(try WidgetControlRequest.toggleAppMute(id: "a").resolve(in: snapshot(), at: now), .setAppMuted(id: "a", muted: true))
        XCTAssertEqual(try WidgetControlRequest.toggleAppMute(id: "a").resolve(in: after, at: now), .setAppMuted(id: "a", muted: false))
    }

    func testVolumeRequestsAdvanceFromCurrentVolumeAndWrap() throws {
        let samples: [(Double, Double)] = [(0, 0.25), (0.18, 0.25), (0.24, 0.50), (0.25, 0.50), (0.50, 0.75), (0.75, 1), (1, 0.25)]
        for (current, expected) in samples {
            let currentSnapshot = snapshot(volume: current, appVolume: current)
            XCTAssertEqual(try WidgetControlRequest.nextSystemVolumePreset.resolve(in: currentSnapshot, at: now), .setSystemVolume(expected))
            XCTAssertEqual(try WidgetControlRequest.nextAppVolumePreset(id: "a").resolve(in: currentSnapshot, at: now), .setAppVolume(id: "a", value: expected))
        }
    }

    func testUnavailableControlsAndUnknownAppsAreRejected() {
        assertResolutionError(.unavailable, request: .toggleSystemMute, snapshot: snapshot(muted: nil))
        assertResolutionError(.unavailable, request: .nextSystemVolumePreset, snapshot: snapshot(volume: nil))
        assertResolutionError(.unknownApp, request: .toggleAppMute(id: "missing"), snapshot: snapshot())
        assertResolutionError(.unknownApp, request: .nextAppVolumePreset(id: "missing"), snapshot: snapshot())
        assertResolutionError(.mixerDisabled, request: .toggleAppMute(id: "a"), snapshot: snapshot(mixerEnabled: false))
        assertResolutionError(.mixerDisabled, request: .nextAppVolumePreset(id: "a"), snapshot: snapshot(mixerEnabled: false))
    }

    func testInvalidCurrentVolumesNeverProduceCommands() {
        for invalid in [Double.nan, .infinity, -.infinity, -0.01, 1.01] {
            let currentSnapshot = snapshot(volume: invalid, appVolume: invalid)
            assertResolutionError(.invalidVolume, request: .nextSystemVolumePreset, snapshot: currentSnapshot)
            assertResolutionError(.invalidVolume, request: .nextAppVolumePreset(id: "a"), snapshot: currentSnapshot)
        }
    }

    func testSnapshotSafetyChecksApplyBeforeResolving() {
        let unavailableSnapshots = [
            WidgetSnapshot(updatedAt: now),
            WidgetSnapshot(schemaVersion: 2, updatedAt: now, isRunning: true),
            WidgetSnapshot(updatedAt: now, isRunning: true, isBusy: true)
        ]
        for unavailable in unavailableSnapshots {
            assertResolutionError(.stale, request: .toggleMixer, snapshot: unavailable)
            assertResolutionError(.stale, request: .refresh, snapshot: unavailable)
        }
        for age in [-91.0, 6.0] {
            let stale = WidgetSnapshot(updatedAt: now.addingTimeInterval(age), isRunning: true)
            assertResolutionError(.stale, request: .toggleMixer, snapshot: stale)
        }
    }

    func testRefreshMayRecoverAnOldSnapshot() throws {
        let stale = WidgetSnapshot(updatedAt: now.addingTimeInterval(-91), isRunning: true)
        XCTAssertEqual(try WidgetControlRequest.refresh.resolve(in: stale, at: now), .refresh)
    }

    func testResolvedCommandRemainsExplicitAndBoundToSnapshotSession() throws {
        let current = snapshot(mixerEnabled: false)
        let command = WidgetCommand(sessionID: current.sessionID, issuedAt: now,
                                    action: try WidgetControlRequest.toggleMixer.resolve(in: current, at: now))
        let decoded = try JSONDecoder().decode(WidgetCommand.self, from: JSONEncoder().encode(command))
        XCTAssertEqual(decoded.action, .setMixerEnabled(true))
        try decoded.validate(sessionID: current.sessionID, appIDs: ["a"], at: now)
        XCTAssertThrowsError(try decoded.validate(sessionID: UUID(), appIDs: ["a"], at: now)) {
            XCTAssertEqual($0 as? WidgetCommandValidationError, .wrongSession)
        }
    }

    private func assertResolutionError(
        _ expected: WidgetControlRequestError,
        request: WidgetControlRequest,
        snapshot: WidgetSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try request.resolve(in: snapshot, at: now), file: file, line: line) {
            XCTAssertEqual($0 as? WidgetControlRequestError, expected, file: file, line: line)
        }
    }
}
