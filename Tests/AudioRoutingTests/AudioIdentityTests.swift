import XCTest
@testable import AudioRouting

final class AudioIdentityTests: XCTestCase {
    func testEmptyProcessIdentityRemainsSessionSpecific() async {
        await MainActor.run {
            let identity = AppAudioIdentity.resolve(pid: 42, processBundleID: "", bundleURL: nil, name: "", candidates: [])
            XCTAssertEqual(identity.id, "process:42")
            XCTAssertEqual(identity.name, "Audio process 42")
        }
    }
    func testNestedHelperUsesOutermostApplicationBundle() {
        let path = URL(fileURLWithPath: "/Applications/Browser.app/Contents/Frameworks/Browser Framework.framework/Helpers/Browser Helper.app")
        XCTAssertEqual(AppAudioIdentity.enclosingApplication(path)?.path, "/Applications/Browser.app")
        XCTAssertNil(AppAudioIdentity.enclosingApplication(URL(fileURLWithPath: "/usr/bin/afplay")))
    }
}
