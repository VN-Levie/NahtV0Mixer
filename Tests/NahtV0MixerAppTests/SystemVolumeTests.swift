import XCTest
@testable import NahtV0MixerApp

final class SystemVolumeTests: XCTestCase {
    @MainActor
    func testSetSystemVolumeWritesClampedValueAndPublishesReadback() async {
        let fixture = VolumeFixture(readback: 0.37)
        let store = fixture.store

        store.setSystemVolume(1.4)

        XCTAssertEqual(fixture.writes.map(\.value), [1])
        XCTAssertEqual(fixture.writes.map(\.outputID), [42])
        XCTAssertEqual(store.systemVolume, 0.37)
        XCTAssertNil(store.lastError)
    }

    @MainActor
    func testSetSystemVolumePreservesErrorAndPublishedValueWhenWriteFails() async {
        let fixture = VolumeFixture(writeError: TestVolumeError.failed)
        let store = fixture.store
        store.setSystemVolume(0.25)

        XCTAssertEqual(fixture.writes.map(\.value), [0.25])
        XCTAssertEqual(fixture.writes.map(\.outputID), [42])
        XCTAssertEqual(store.lastError, "Volume write failed")
        XCTAssertNil(store.systemVolume)
    }

    @MainActor
    func testSetSystemVolumeRejectsNonfiniteInputWithoutWriting() async {
        let fixture = VolumeFixture(readback: 0.4)
        let store = fixture.store
        store.setSystemVolume(.nan)

        XCTAssertTrue(fixture.writes.isEmpty)
        XCTAssertEqual(store.lastError, "Device volume is unavailable.")
        XCTAssertNil(store.systemVolume)
    }
}

@MainActor
private final class VolumeFixture {
    struct Write {
        let value: Double
        let outputID: UInt32
    }

    private let recorder: Recorder
    let store: MixerStore

    var writes: [Write] { recorder.writes }

    init(readback: Double? = nil, writeError: Error? = nil) {
        let name = "NahtV0Mixer.system-volume-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let recorder = Recorder()
        self.recorder = recorder
        let io = MixerVolumeIO(
            read: { _ in readback },
            write: { value, outputID in
                recorder.writes.append(Write(value: value, outputID: outputID))
                if let writeError { throw writeError }
            })
        store = MixerStore(defaults: defaults, volumeIO: io, initialOutputID: 42)
        defaults.removePersistentDomain(forName: name)
    }

    private final class Recorder {
        var writes: [Write] = []
    }
}

private enum TestVolumeError: LocalizedError {
    case failed

    var errorDescription: String? { "Volume write failed" }
}
