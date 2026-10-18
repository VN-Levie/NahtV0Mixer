import AppKit
import Carbon
import XCTest
@testable import NahtV0MixerApp

final class LifecycleTests: XCTestCase {
    func testRegularLaunchShowsPanelAndBackgroundArgumentSuppressesIt() {
        XCTAssertFalse(MixerLaunch.isBackground(event: nil, arguments: ["NahtV0Mixer"]))
        XCTAssertTrue(MixerLaunch.isBackground(event: nil, arguments: ["NahtV0Mixer", "--background"]))
    }

    func testLoginAppleEventIsBackgroundButOtherEventsAreNot() {
        let login = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: kAEOpenApplication,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        login.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        XCTAssertTrue(MixerLaunch.isBackground(event: login, arguments: []))
        let reopened = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: kAEReopenApplication,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        reopened.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        XCTAssertFalse(MixerLaunch.isBackground(event: reopened, arguments: []))
    }

    func testOnlyOneLeaseCanOwnTheSameAppAndExitReleasesIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("instance.lock")
        var first = try InstanceLease.take(url)
        XCTAssertNotNil(first)
        XCTAssertNil(try InstanceLease.take(url))
        withExtendedLifetime(first) {}
        first = nil
        let replacement = try InstanceLease.take(url)
        XCTAssertNotNil(replacement)
        withExtendedLifetime(replacement) {}
    }

    func testStaleLockFileDoesNotPreventLaunch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("instance.lock")
        try Data("old process data".utf8).write(to: url)
        let lease = try InstanceLease.take(url)
        XCTAssertNotNil(lease)
        withExtendedLifetime(lease) {}
    }

    func testLockRefusesSymbolicLink() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let realFile = folder.appendingPathComponent("unrelated")
        let link = folder.appendingPathComponent("instance.lock")
        try Data("preserve".utf8).write(to: realFile)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realFile)
        XCTAssertThrowsError(try InstanceLease.take(link))
        XCTAssertEqual(try String(contentsOf: realFile, encoding: .utf8), "preserve")
    }
}
