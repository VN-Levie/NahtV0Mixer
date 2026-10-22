import Foundation
import XCTest
@testable import MixerWidgetCore

final class WidgetCoreTests: XCTestCase {
    private func temporaryStore() throws -> (WidgetSharedStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try WidgetSharedStore(directory: url), url)
    }

    func testSnapshotRoundTripAndFreshness() throws {
        let (store, _) = try temporaryStore()
        let session = UUID()
        let snapshot = WidgetSnapshot(sessionID: session, updatedAt: Date(), isRunning: true, mixerEnabled: true,
                                      systemVolume: 0.5, outputName: "Built-in", apps: [WidgetAppState(id: "a", name: "A", volume: 0.7, isMuted: false, isPlaying: true)])
        try store.writeSnapshot(snapshot)
        XCTAssertEqual(store.readSnapshot(), snapshot)
        XCTAssertTrue(snapshot.isFresh())
        XCTAssertFalse(WidgetSnapshot(sessionID: session, updatedAt: Date().addingTimeInterval(-91), isRunning: true).isFresh())
        XCTAssertFalse(WidgetSnapshot.unavailable.isFresh())
        XCTAssertFalse(WidgetSnapshot(schemaVersion: 2, isRunning: true).isFresh())
    }

    func testCommandReplyRoundTrip() throws {
        let (store, _) = try temporaryStore()
        let session = UUID()
        let command = WidgetCommand(sessionID: session, action: .setAppVolume(id: "a", value: 0.4))
        try store.submit(command)
        XCTAssertEqual(store.pendingCommands(), [command])
        let reply = WidgetReply(id: command.id, snapshot: WidgetSnapshot(sessionID: session), error: nil)
        try store.writeReply(reply)
        XCTAssertEqual(store.readReply(id: command.id), reply)
        try store.removeCommand(id: command.id)
        try store.removeReply(id: command.id)
        XCTAssertTrue(store.pendingCommands().isEmpty)
        XCTAssertNil(store.readReply(id: command.id))
    }

    func testCommandValidation() throws {
        let session = UUID(); let appIDs: Set<String> = ["a"]
        try WidgetCommand(sessionID: session, action: .setSystemVolume(1)).validate(sessionID: session, appIDs: appIDs)
        XCTAssertThrowsError(try WidgetCommand(sessionID: UUID(), action: .refresh).validate(sessionID: session, appIDs: appIDs))
        XCTAssertThrowsError(try WidgetCommand(sessionID: session, issuedAt: Date().addingTimeInterval(-11), action: .refresh).validate(sessionID: session, appIDs: appIDs))
        XCTAssertThrowsError(try WidgetCommand(sessionID: session, action: .setSystemVolume(.nan)).validate(sessionID: session, appIDs: appIDs))
        XCTAssertThrowsError(try WidgetCommand(sessionID: session, action: .setAppMuted(id: "missing", muted: true)).validate(sessionID: session, appIDs: appIDs))
    }

    func testMalformedAndSymlinkRecordsAreIgnored() throws {
        let (store, root) = try temporaryStore()
        let commands = root.appendingPathComponent("commands")
        try Data("bad".utf8).write(to: commands.appendingPathComponent("\(UUID().uuidString).json"))
        let outside = root.appendingPathComponent("outside.json"); try Data("outside".utf8).write(to: outside)
        let link = commands.appendingPathComponent("\(UUID().uuidString).json"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertTrue(store.pendingCommands().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
    }

    func testRecordIdentityMustMatchFilename() throws {
        let (store, root) = try temporaryStore(); let session = UUID()
        let command = WidgetCommand(sessionID: session, action: .refresh)
        let otherID = UUID()
        let data = try JSONEncoder().encode(command)
        try data.write(to: root.appendingPathComponent("commands/\(otherID.uuidString).json"))
        XCTAssertTrue(store.pendingCommands().isEmpty)

        let reply = WidgetReply(id: otherID, snapshot: WidgetSnapshot(sessionID: session))
        let replyData = try JSONEncoder().encode(reply)
        try replyData.write(to: root.appendingPathComponent("replies/\(command.id.uuidString).json"))
        XCTAssertNil(store.readReply(id: command.id))
    }

    func testPruneRemovesOldOwnedRecordsOnly() throws {
        let (store, root) = try temporaryStore(); let session = UUID()
        let command = WidgetCommand(sessionID: session, issuedAt: Date().addingTimeInterval(-100_000), action: .refresh)
        try store.submit(command)
        let unrelated = root.appendingPathComponent("keep.txt"); try Data("keep".utf8).write(to: unrelated)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-100_000)], ofItemAtPath: root.appendingPathComponent("commands/\(command.id.uuidString).json").path)
        store.prune()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("commands/\(command.id.uuidString).json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
}
