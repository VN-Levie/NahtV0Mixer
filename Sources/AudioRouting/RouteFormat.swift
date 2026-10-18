import CoreAudio
import Foundation

/// A snapshot of one HAL stream's client format. Channel numbers are one-based.
struct RouteStreamFormat {
    let startingChannel: UInt32
    let format: AudioStreamBasicDescription
}

struct RouteBufferLayout: Equatable {
    let inputChannels: [UInt32]
    let outputChannels: [UInt32]
    let tapChannelOffset: UInt32
    let tapChannelCount: UInt32
    let sampleRate: Double

    /// Validate the hardware input prefix separately from the tap. A USB device
    /// may contribute microphone channels before the captured application audio.
    static func validated(
        physicalInputChannels: [UInt32],
        physicalOutputChannels: [UInt32],
        aggregateInputChannels: [UInt32],
        aggregateOutputChannels: [UInt32],
        aggregateInputStreams: [RouteStreamFormat],
        aggregateOutputStreams: [RouteStreamFormat],
        tapFormat: AudioStreamBasicDescription
    ) throws -> Self {
        try validatePCM(tapFormat)
        let channelCount = tapFormat.mChannelsPerFrame
        guard (1...2).contains(channelCount),
              !aggregateInputChannels.isEmpty,
              aggregateInputChannels.count <= 32,
              aggregateOutputChannels.count <= 32,
              aggregateInputChannels.allSatisfy({ (1...64).contains($0) }),
              physicalOutputChannels == aggregateOutputChannels,
              aggregateOutputChannels.reduce(UInt64(0), { $0 + UInt64($1) }) == UInt64(channelCount)
        else { throw ProcessAudioRouteError.unsupportedFormat("Only mono or stereo output is supported.") }

        // HAL exposes hardware streams in subdevice-list order; the one tap is
        // the remaining input stream. Refuse merged or ambiguous configurations.
        guard aggregateInputChannels.starts(with: physicalInputChannels) else {
            throw ProcessAudioRouteError.unsupportedFormat("The device's input channel order could not be verified.")
        }
        let hardwareChannels = physicalInputChannels.reduce(UInt64(0)) { $0 + UInt64($1) }
        let allInputChannels = aggregateInputChannels.reduce(UInt64(0)) { $0 + UInt64($1) }
        guard hardwareChannels <= UInt64(UInt32.max),
              allInputChannels == hardwareChannels + UInt64(channelCount) else {
            throw ProcessAudioRouteError.unsupportedFormat("The captured audio could not be separated from hardware inputs.")
        }
        let tapStart = UInt32(hardwareChannels) + 1
        let orderedInputs: [RouteStreamFormat]
        if physicalInputChannels.isEmpty,
           aggregateInputStreams.count == 1,
           allInputChannels == UInt64(channelCount),
           formatsMatch(aggregateInputStreams[0].format, tapFormat) {
            // The built-in speakers report their sole aggregate tap stream at
            // HAL channel 7 while the callback contains just one stereo input
            // buffer. With no hardware input and exactly one matching tap stream,
            // callback channels are unambiguously 1...N. Do not normalize duplex
            // devices, where this could confuse microphone and application audio.
            orderedInputs = [.init(startingChannel: 1, format: aggregateInputStreams[0].format)]
        } else {
            orderedInputs = aggregateInputStreams.sorted { $0.startingChannel < $1.startingChannel }
        }
        var nextChannel: UInt32 = 1
        var tapStreams: [RouteStreamFormat] = []
        for stream in orderedInputs {
            guard stream.startingChannel == nextChannel,
                  stream.format.mChannelsPerFrame > 0,
                  UInt64(nextChannel) + UInt64(stream.format.mChannelsPerFrame) <= UInt64(UInt32.max) else {
                let streams = orderedInputs.map {
                    "start=\($0.startingChannel), channels=\($0.format.mChannelsPerFrame), rate=\($0.format.mSampleRate), flags=\($0.format.mFormatFlags)"
                }.joined(separator: "; ")
                throw ProcessAudioRouteError.unsupportedFormat(
                    "The input stream layout is not contiguous (expected start \(nextChannel), reported start \(stream.startingChannel), channels \(stream.format.mChannelsPerFrame); hardware buffers \(physicalInputChannels), aggregate buffers \(aggregateInputChannels); streams [\(streams)]).")
            }
            nextChannel += stream.format.mChannelsPerFrame
            if stream.startingChannel < tapStart {
                guard nextChannel <= tapStart else {
                    throw ProcessAudioRouteError.unsupportedFormat("Hardware input and application audio overlap.")
                }
            } else {
                tapStreams.append(stream)
                try validatePCM(stream.format)
                guard stream.format.mSampleRate == tapFormat.mSampleRate else {
                    throw ProcessAudioRouteError.unsupportedFormat("Input and output sample rates differ.")
                }
            }
        }
        guard nextChannel == tapStart + channelCount,
              !tapStreams.isEmpty,
              tapStreams.reduce(UInt32(0), { $0 + $1.format.mChannelsPerFrame }) == channelCount else {
            throw ProcessAudioRouteError.unsupportedFormat("The application audio stream is missing.")
        }
        try validateBufferPacking(streams: tapStreams,
                                  channels: Array(aggregateInputChannels.dropFirst(physicalInputChannels.count)),
                                  firstChannel: tapStart)

        let orderedOutputs = aggregateOutputStreams.sorted { $0.startingChannel < $1.startingChannel }
        nextChannel = 1
        for stream in orderedOutputs {
            try validatePCM(stream.format)
            guard stream.startingChannel == nextChannel,
                  stream.format.mSampleRate == tapFormat.mSampleRate else {
                throw ProcessAudioRouteError.unsupportedFormat("The output stream layout or sample rate is unsupported.")
            }
            nextChannel += stream.format.mChannelsPerFrame
        }
        guard nextChannel == channelCount + 1 else {
            throw ProcessAudioRouteError.unsupportedFormat("The output channel count does not match the tap.")
        }
        try validateBufferPacking(streams: orderedOutputs, channels: aggregateOutputChannels, firstChannel: 1)
        return Self(inputChannels: aggregateInputChannels, outputChannels: aggregateOutputChannels,
                    tapChannelOffset: UInt32(hardwareChannels), tapChannelCount: channelCount,
                    sampleRate: tapFormat.mSampleRate)
    }

    static func validatePCM(_ format: AudioStreamBasicDescription) throws {
        guard (1...2).contains(format.mChannelsPerFrame) else {
            throw ProcessAudioRouteError.unsupportedFormat("Only mono or stereo output is supported.")
        }
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bytesPerFrame = (nonInterleaved ? 1 : format.mChannelsPerFrame) * 4
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsPacked != 0,
              format.mFormatFlags & kAudioFormatFlagIsSignedInteger == 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mFormatFlags & kAudioFormatFlagIsAlignedHigh == 0,
              format.mBitsPerChannel == 32,
              format.mBytesPerFrame == bytesPerFrame,
              format.mFramesPerPacket == 1,
              format.mBytesPerPacket == bytesPerFrame,
              format.mSampleRate.isFinite,
              (8000...384000).contains(format.mSampleRate) else {
            throw ProcessAudioRouteError.unsupportedFormat("This output requires native Float32 mono or stereo audio.")
        }
    }

    private static func validateBufferPacking(streams: [RouteStreamFormat], channels: [UInt32], firstChannel: UInt32) throws {
        var expected: [UInt32] = []
        for stream in streams {
            if stream.format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
                expected += Array(repeating: 1, count: Int(stream.format.mChannelsPerFrame))
            } else {
                expected.append(stream.format.mChannelsPerFrame)
            }
        }
        guard streams.first?.startingChannel == firstChannel, expected == channels else {
            throw ProcessAudioRouteError.unsupportedFormat("The device's audio buffers do not match its stream format.")
        }
    }

    private static func formatsMatch(_ lhs: AudioStreamBasicDescription, _ rhs: AudioStreamBasicDescription) -> Bool {
        lhs.mSampleRate == rhs.mSampleRate && lhs.mFormatID == rhs.mFormatID && lhs.mFormatFlags == rhs.mFormatFlags &&
        lhs.mBytesPerPacket == rhs.mBytesPerPacket && lhs.mFramesPerPacket == rhs.mFramesPerPacket &&
        lhs.mBytesPerFrame == rhs.mBytesPerFrame && lhs.mChannelsPerFrame == rhs.mChannelsPerFrame && lhs.mBitsPerChannel == rhs.mBitsPerChannel
    }
}
