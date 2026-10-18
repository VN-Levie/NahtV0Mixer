import CMixerDSP
import CoreAudio
import XCTest

final class MixerDSPTests: XCTestCase {
    func testInitialMuteAppliesBeforeFirstBuffer() throws {
        let state = try makeState(inputs: [2], outputs: [2], gain: 0)
        defer { nm_dsp_destroy(state) }
        let input = BufferFixture(channels: [2], frames: 80, fill: 0.8)
        let output = BufferFixture(channels: [2], frames: 80, fill: 0.9)
        nm_dsp_render(state, input.pointer, output.pointer)
        XCTAssertEqual(output.samples(0), Array(repeating: 0, count: 160))
        XCTAssertEqual(nm_dsp_peak(state), 0)
        XCTAssertEqual(nm_dsp_input_peak(state), 0.8)
        XCTAssertEqual(nm_dsp_processed_frames(state), 80)
        XCTAssertFalse(nm_dsp_failed(state))
    }

    func testGainRampsOverTenMillisecondsAndStaysMuted() throws {
        let state = try makeState(inputs: [1], outputs: [1], gain: 1)
        defer { nm_dsp_destroy(state) }
        nm_dsp_set_gain(state, 0)
        let input = BufferFixture(channels: [1], frames: 100, fill: 1)
        let output = BufferFixture(channels: [1], frames: 100)
        nm_dsp_render(state, input.pointer, output.pointer)
        let samples = output.samples(0)
        XCTAssertEqual(samples[0], 79.0 / 80, accuracy: 0.00001)
        XCTAssertEqual(samples[79], 0)
        XCTAssertEqual(Array(samples[80...]), Array(repeating: 0, count: 20))
        for pair in zip(samples, samples.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.0, pair.1)
            XCTAssertLessThanOrEqual(pair.0 - pair.1, 1.0 / 80 + 0.00001)
        }
    }

    func testRampIsContinuousAcrossUnevenCallbacks() throws {
        let contiguous = try makeState(inputs: [1], outputs: [1], gain: 0)
        let split = try makeState(inputs: [1], outputs: [1], gain: 0)
        defer { nm_dsp_destroy(contiguous); nm_dsp_destroy(split) }
        nm_dsp_set_gain(contiguous, 0.7)
        nm_dsp_set_gain(split, 0.7)
        let wholeInput = BufferFixture(channels: [1], frames: 100, fill: 1)
        let wholeOutput = BufferFixture(channels: [1], frames: 100)
        nm_dsp_render(contiguous, wholeInput.pointer, wholeOutput.pointer)
        var joined: [Float] = []
        for frames in [17, 41, 42] {
            let input = BufferFixture(channels: [1], frames: frames, fill: 1)
            let output = BufferFixture(channels: [1], frames: frames)
            nm_dsp_render(split, input.pointer, output.pointer)
            joined += output.samples(0)
        }
        XCTAssertEqual(joined, wholeOutput.samples(0))
    }

    func testRetargetingRampUsesCurrentGainWithoutJump() throws {
        let state = try makeState(inputs: [1], outputs: [1], gain: 0)
        defer { nm_dsp_destroy(state) }
        nm_dsp_set_gain(state, 1)
        let input = BufferFixture(channels: [1], frames: 20, fill: 1)
        let firstOutput = BufferFixture(channels: [1], frames: 20)
        nm_dsp_render(state, input.pointer, firstOutput.pointer)
        nm_dsp_set_gain(state, 0)
        let secondOutput = BufferFixture(channels: [1], frames: 20)
        nm_dsp_render(state, input.pointer, secondOutput.pointer)
        let last = firstOutput.samples(0).last!
        let next = secondOutput.samples(0)[0]
        XCTAssertLessThan(next, last)
        XCTAssertEqual(next, last - last / 80, accuracy: 0.000001)
    }

    func testHardwareMicrophoneInputIsNeverCopied() throws {
        let state = try makeState(inputs: [1, 2], outputs: [2], offset: 1, gain: 0.5)
        defer { nm_dsp_destroy(state) }
        let input = BufferFixture(channels: [1, 2], frames: 2, fill: 0.99)
        input.setSamples(1, [0.2, -0.4, 0.6, -0.8])
        let output = BufferFixture(channels: [2], frames: 2)
        nm_dsp_render(state, input.pointer, output.pointer)
        XCTAssertEqual(output.samples(0), [0.1, -0.2, 0.3, -0.4])
        XCTAssertEqual(nm_dsp_peak(state), 0.4)
        XCTAssertEqual(nm_dsp_input_peak(state), 0.8)
        XCTAssertFalse(nm_dsp_failed(state))
    }

    func testPlanarTapMapsToInterleavedOutput() throws {
        let state = try makeState(inputs: [2, 1, 1], outputs: [2], offset: 2, gain: 1)
        defer { nm_dsp_destroy(state) }
        let input = BufferFixture(channels: [2, 1, 1], frames: 3, fill: 0.99)
        input.setSamples(1, [0.1, 0.2, 0.3])
        input.setSamples(2, [-0.1, -0.2, -0.3])
        let output = BufferFixture(channels: [2], frames: 3)
        nm_dsp_render(state, input.pointer, output.pointer)
        XCTAssertEqual(output.samples(0), [0.1, -0.1, 0.2, -0.2, 0.3, -0.3])
    }

    func testDisabledHardwareInputBufferMayBeNull() throws {
        let state = try makeState(inputs: [1, 2], outputs: [2], offset: 1, gain: 1)
        defer { nm_dsp_destroy(state) }
        let input = BufferFixture(channels: [1, 2], frames: 2, fill: 0.25)
        input.disableBuffer(0)
        let output = BufferFixture(channels: [2], frames: 2)
        nm_dsp_render(state, input.pointer, output.pointer)
        XCTAssertFalse(nm_dsp_failed(state))
        XCTAssertEqual(output.samples(0), [0.25, 0.25, 0.25, 0.25])
    }

    func testInterleavedTapMapsToPlanarOutput() throws {
        let state = try makeState(inputs: [2], outputs: [1, 1], gain: 1)
        defer { nm_dsp_destroy(state) }
        let input = BufferFixture(channels: [2], frames: 2)
        input.setSamples(0, [0.25, -0.5, 0.75, -1])
        let output = BufferFixture(channels: [1, 1], frames: 2)
        nm_dsp_render(state, input.pointer, output.pointer)
        XCTAssertEqual(output.samples(0), [0.25, 0.75])
        XCTAssertEqual(output.samples(1), [-0.5, -1])
    }

    func testInvalidSamplesAreSilentAndFiniteSamplesAreClipped() throws {
        let state = try makeState(inputs: [1], outputs: [1], gain: 1)
        defer { nm_dsp_destroy(state) }
        let input = BufferFixture(channels: [1], frames: 6)
        input.setSamples(0, [.nan, .infinity, -.infinity, 3, -2, 0.5])
        let output = BufferFixture(channels: [1], frames: 6)
        nm_dsp_render(state, input.pointer, output.pointer)
        XCTAssertEqual(output.samples(0), [0, 0, 0, 1, -1, 0.5])
        XCTAssertEqual(nm_dsp_peak(state), 1)
    }

    func testInvalidAndOutOfRangeGainNeverBoosts() throws {
        for (gain, expected): (Float, Float) in [(.nan, 0), (.infinity, 0), (-1, 0), (4, 0.5)] {
            let state = try makeState(inputs: [1], outputs: [1], gain: gain)
            defer { nm_dsp_destroy(state) }
            let input = BufferFixture(channels: [1], frames: 1, fill: 0.5)
            let output = BufferFixture(channels: [1], frames: 1)
            nm_dsp_render(state, input.pointer, output.pointer)
            XCTAssertEqual(output.samples(0), [expected])
        }
    }

    func testLayoutChangeClearsOutputAndLatchesFailure() throws {
        let state = try makeState(inputs: [2], outputs: [2], gain: 1)
        defer { nm_dsp_destroy(state) }
        let input = BufferFixture(channels: [1], frames: 4, fill: 1)
        let output = BufferFixture(channels: [2], frames: 4, fill: 1)
        nm_dsp_render(state, input.pointer, output.pointer)
        XCTAssertTrue(nm_dsp_failed(state))
        XCTAssertEqual(output.samples(0), Array(repeating: 0, count: 8))
        let repairedInput = BufferFixture(channels: [2], frames: 4, fill: 1)
        nm_dsp_render(state, repairedInput.pointer, output.pointer)
        XCTAssertEqual(output.samples(0), Array(repeating: 0, count: 8))
    }

    func testTruncatedSourceBufferCannotOverread() throws {
        let state = try makeState(inputs: [1], outputs: [1], gain: 1)
        defer { nm_dsp_destroy(state) }
        let input = BufferFixture(channels: [1], frames: 3, fill: 1)
        let output = BufferFixture(channels: [1], frames: 4, fill: 1)
        nm_dsp_render(state, input.pointer, output.pointer)
        XCTAssertTrue(nm_dsp_failed(state))
        XCTAssertEqual(output.samples(0), [0, 0, 0, 0])
    }

    func testFormatNotificationStopsProcessingUntilRouteRebuilt() throws {
        let state = try makeState(inputs: [1], outputs: [1], gain: 1)
        defer { nm_dsp_destroy(state) }
        var address = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        XCTAssertEqual(nm_dsp_property_changed(0, 1, &address, UnsafeMutableRawPointer(state)), noErr)
        let input = BufferFixture(channels: [1], frames: 4, fill: 0.5)
        let output = BufferFixture(channels: [1], frames: 4, fill: 0.5)
        nm_dsp_render(state, input.pointer, output.pointer)
        XCTAssertTrue(nm_dsp_failed(state))
        XCTAssertEqual(output.samples(0), [0, 0, 0, 0])
        XCTAssertEqual(nm_dsp_processed_frames(state), 0)
    }

    func testFrameCounterAccumulatesFramesNotStereoSamples() throws {
        let state = try makeState(inputs: [2], outputs: [2], gain: 0.5)
        defer { nm_dsp_destroy(state) }
        XCTAssertEqual(nm_dsp_processed_frames(state), 0)
        for frames in [17, 41] {
            let input = BufferFixture(channels: [2], frames: frames, fill: 0.4)
            let output = BufferFixture(channels: [2], frames: frames)
            nm_dsp_render(state, input.pointer, output.pointer)
        }
        XCTAssertEqual(nm_dsp_processed_frames(state), 58)
        XCTAssertEqual(nm_dsp_input_peak(state), 0.4)
        XCTAssertEqual(nm_dsp_peak(state), 0.2)
    }

    func testInvalidConfigurationIsRejectedBeforeRendering() {
        XCTAssertNil(createState(inputs: [1, 2], outputs: [2], offset: 0, gain: 1))
        XCTAssertNil(createState(inputs: [2], outputs: [1], offset: 0, gain: 1))
        XCTAssertNil(createState(inputs: [2], outputs: [2], offset: 0, gain: 1, rate: .nan))
        XCTAssertNil(createState(inputs: [2], outputs: [2], offset: 0, gain: 1, rate: 0))
        XCTAssertNil(createState(inputs: [0, 2], outputs: [2], offset: 0, gain: 1))
    }

    private func makeState(inputs: [UInt32], outputs: [UInt32], offset: UInt32 = 0, gain: Float) throws -> OpaquePointer {
        try XCTUnwrap(createState(inputs: inputs, outputs: outputs, offset: offset, gain: gain))
    }

    private func createState(inputs: [UInt32], outputs: [UInt32], offset: UInt32, gain: Float, rate: Double = 8000) -> OpaquePointer? {
        inputs.withUnsafeBufferPointer { input in
            outputs.withUnsafeBufferPointer { output in
                nm_dsp_create(input.baseAddress!, UInt32(input.count), output.baseAddress!, UInt32(output.count),
                              offset, outputs.reduce(0, +), rate, gain)
            }
        }
    }
}

private final class BufferFixture {
    let pointer: UnsafeMutablePointer<AudioBufferList>
    private let storage: UnsafeMutableRawPointer
    private var data: [UnsafeMutablePointer<Float>] = []
    private var counts: [Int] = []

    init(channels: [UInt32], frames: Int, fill: Float = 0) {
        let bytes = MemoryLayout<AudioBufferList>.size + (channels.count - 1) * MemoryLayout<AudioBuffer>.size
        storage = .allocate(byteCount: bytes, alignment: MemoryLayout<AudioBufferList>.alignment)
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
        pointer = storage.assumingMemoryBound(to: AudioBufferList.self)
        pointer.pointee.mNumberBuffers = UInt32(channels.count)
        let buffers = UnsafeMutableAudioBufferListPointer(pointer)
        for (index, channelCount) in channels.enumerated() {
            let count = frames * Int(channelCount)
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: max(count, 1))
            samples.initialize(repeating: fill, count: count)
            data.append(samples)
            counts.append(count)
            buffers[index] = AudioBuffer(mNumberChannels: channelCount, mDataByteSize: UInt32(count * 4), mData: samples)
        }
    }

    func samples(_ buffer: Int) -> [Float] { Array(UnsafeBufferPointer(start: data[buffer], count: counts[buffer])) }
    func setSamples(_ buffer: Int, _ samples: [Float]) {
        precondition(samples.count == counts[buffer])
        for (index, sample) in samples.enumerated() { data[buffer][index] = sample }
    }
    func disableBuffer(_ buffer: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(pointer)
        buffers[buffer].mData = nil
    }

    deinit {
        for (index, pointer) in data.enumerated() {
            pointer.deinitialize(count: counts[index])
            pointer.deallocate()
        }
        storage.deallocate()
    }
}
