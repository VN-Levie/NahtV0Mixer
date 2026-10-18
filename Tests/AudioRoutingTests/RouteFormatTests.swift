import CoreAudio
import XCTest
@testable import AudioRouting

final class RouteFormatTests: XCTestCase {
    func testStereoOutputOnlyLayout() throws {
        let layout = try makeLayout()
        XCTAssertEqual(layout.tapChannelOffset, 0)
        XCTAssertEqual(layout.tapChannelCount, 2)
        XCTAssertEqual(layout.sampleRate, 48000)
    }

    func testSoleTapUsesCallbackChannelsWhenHALReportsStartingChannelSeven() throws {
        let layout = try makeLayout(inputStreams: [stream(start: 7, channels: 2)])
        XCTAssertEqual(layout.tapChannelOffset, 0)
        XCTAssertEqual(layout.tapChannelCount, 2)
        XCTAssertEqual(layout.inputChannels, [2])
    }

    func testDuplexTapStartingChannelIsNeverNormalized() {
        XCTAssertThrowsError(try makeLayout(physicalInputs: [1], inputs: [1, 2], inputStreams: [
            stream(start: 1, channels: 1), stream(start: 7, channels: 2)
        ]))
    }

    func testDuplexDeviceSkipsPhysicalInputBeforeTap() throws {
        let layout = try makeLayout(physicalInputs: [1, 2], inputs: [1, 2, 2], inputStreams: [
            stream(start: 1, channels: 1), stream(start: 2, channels: 2), stream(start: 4, channels: 2)
        ])
        XCTAssertEqual(layout.tapChannelOffset, 3)
        XCTAssertEqual(layout.inputChannels, [1, 2, 2])
    }

    func testNonInterleavedStereoBuffers() throws {
        let format = pcm(channels: 2, planar: true)
        let layout = try RouteBufferLayout.validated(
            physicalInputChannels: [], physicalOutputChannels: [1, 1],
            aggregateInputChannels: [1, 1], aggregateOutputChannels: [1, 1],
            aggregateInputStreams: [.init(startingChannel: 1, format: format)],
            aggregateOutputStreams: [.init(startingChannel: 1, format: format)], tapFormat: format)
        XCTAssertEqual(layout.outputChannels, [1, 1])
    }

    func testMonoDevice() throws {
        let format = pcm(channels: 1)
        let layout = try RouteBufferLayout.validated(
            physicalInputChannels: [], physicalOutputChannels: [1],
            aggregateInputChannels: [1], aggregateOutputChannels: [1],
            aggregateInputStreams: [.init(startingChannel: 1, format: format)],
            aggregateOutputStreams: [.init(startingChannel: 1, format: format)], tapFormat: format)
        XCTAssertEqual(layout.tapChannelCount, 1)
    }

    func testAmbiguousHardwareInputOrderIsRejected() {
        XCTAssertThrowsError(try makeLayout(physicalInputs: [1], inputs: [2, 1], inputStreams: [
            stream(start: 1, channels: 2), stream(start: 3, channels: 1)
        ]))
    }

    func testHardwareInputCannotOverlapTap() {
        XCTAssertThrowsError(try makeLayout(physicalInputs: [1], inputs: [1, 2], inputStreams: [
            stream(start: 1, channels: 2), stream(start: 3, channels: 1)
        ]))
    }

    func testMissingAndExtraTapChannelsAreRejected() {
        XCTAssertThrowsError(try makeLayout(inputs: [1], inputStreams: [stream(start: 1, channels: 1)]))
        XCTAssertThrowsError(try makeLayout(inputs: [2, 1], inputStreams: [stream(start: 1, channels: 2), stream(start: 3, channels: 1)]))
    }

    func testSampleRateMismatchIsRejected() {
        var wrongRate = pcm(channels: 2)
        wrongRate.mSampleRate = 44100
        XCTAssertThrowsError(try makeLayout(inputStreams: [.init(startingChannel: 1, format: wrongRate)]))
    }

    func testPlanarFlagMustMatchActualBuffers() {
        XCTAssertThrowsError(try makeLayout(inputStreams: [.init(startingChannel: 1, format: pcm(channels: 2, planar: true))]))
    }

    func testIntegerMultichannelAndInvalidFloatFormatsAreRejected() {
        var integer = pcm(channels: 2)
        integer.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        XCTAssertThrowsError(try RouteBufferLayout.validatePCM(integer))
        XCTAssertThrowsError(try RouteBufferLayout.validatePCM(pcm(channels: 6)))
        var corrupt = pcm(channels: 2)
        corrupt.mBytesPerFrame = 4
        XCTAssertThrowsError(try RouteBufferLayout.validatePCM(corrupt))
        corrupt = pcm(channels: 2)
        corrupt.mSampleRate = .nan
        XCTAssertThrowsError(try RouteBufferLayout.validatePCM(corrupt))
    }

    private func makeLayout(physicalInputs: [UInt32] = [], inputs: [UInt32] = [2],
                             inputStreams: [RouteStreamFormat]? = nil) throws -> RouteBufferLayout {
        try RouteBufferLayout.validated(
            physicalInputChannels: physicalInputs, physicalOutputChannels: [2],
            aggregateInputChannels: inputs, aggregateOutputChannels: [2],
            aggregateInputStreams: inputStreams ?? [stream(start: 1, channels: 2)],
            aggregateOutputStreams: [stream(start: 1, channels: 2)], tapFormat: pcm(channels: 2))
    }

    private func stream(start: UInt32, channels: UInt32) -> RouteStreamFormat {
        .init(startingChannel: start, format: pcm(channels: channels))
    }

    private func pcm(channels: UInt32, planar: Bool = false) -> AudioStreamBasicDescription {
        let bytes = (planar ? 1 : channels) * 4
        return AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                           mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | (planar ? kAudioFormatFlagIsNonInterleaved : 0),
                                           mBytesPerPacket: bytes, mFramesPerPacket: 1, mBytesPerFrame: bytes,
                                           mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }
}
