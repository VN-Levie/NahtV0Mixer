import CMixerDSP
import CoreAudio
import Foundation

public enum ProcessAudioRouteError: LocalizedError {
    case noSource
    case unsupportedFormat(String)
    case coreAudio(String, OSStatus)
    case allocationFailed

    public var errorDescription: String? {
        switch self {
        case .noSource: return "No eligible application audio source is available."
        case .unsupportedFormat(let reason): return reason
        case .coreAudio(let operation, let status): return "\(operation) failed (Core Audio \(status))."
        case .allocationFailed: return "The audio processing buffer could not be created."
        }
    }
}

/// One process group routed to one physical output. All lifecycle and health
/// operations belong on one serial control queue. Gain and peak are atomic.
public final class ProcessAudioRoute {
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var didStart = false
    private var dsp: OpaquePointer?
    private var outputDeviceID: AudioObjectID
    private var layout: RouteBufferLayout?
    private var originalOutputFormat: AudioStreamBasicDescription?
    private var tapFormat: AudioStreamBasicDescription?
    private var tapDescription: CATapDescription?
    private var physicalInputChannels: [UInt32] = []
    private var physicalOutputChannels: [UInt32] = []
    private var stopped = false
    private var callbackMayBeLive = false
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress)] = []
    private var listenerMayBeLive = false

    public init(processObjectIDs: [UInt32], outputDeviceID: UInt32, gain: Float) throws {
        self.outputDeviceID = outputDeviceID
        do {
            try create(processObjectIDs: processObjectIDs, gain: gain)
        } catch {
            stop()
            throw error
        }
    }

    deinit {
        stop()
        // In an exceptional HAL teardown failure, retaining a few bytes is
        // safer than freeing memory still referenced by an IOProc.
        if !callbackMayBeLive && !listenerMayBeLive { nm_dsp_destroy(dsp) }
    }

    public func setGain(_ gain: Float) {
        if let dsp { nm_dsp_set_gain(dsp, gain) }
    }

    public var peak: Float { dsp.map { nm_dsp_peak($0) } ?? 0 }
    /// Last valid callback's source peak, before gain; excludes hardware inputs.
    public var inputPeak: Float { dsp.map { nm_dsp_input_peak($0) } ?? 0 }
    /// Valid audio frames processed since start (not samples or audible frames).
    public var processedFrameCount: UInt64 { dsp.map { nm_dsp_processed_frames($0) } ?? 0 }
    public var hasRenderFailure: Bool { dsp.map { nm_dsp_failed($0) } ?? false }

    /// Poll on the route control queue after device changes and periodically.
    /// No capture/permission request occurs here. False means stop this route.
    public var configurationIsCurrent: Bool {
        guard !stopped, let layout, let tapFormat, let originalOutputFormat else { return false }
        do {
            let currentOutputs = try Self.streams(outputDeviceID, scope: kAudioObjectPropertyScopeOutput)
            guard currentOutputs.count == 1,
                  Self.sameFormat(currentOutputs[0].format, originalOutputFormat),
                  try Self.bufferChannels(outputDeviceID, scope: kAudioObjectPropertyScopeInput) == physicalInputChannels,
                  try Self.bufferChannels(outputDeviceID, scope: kAudioObjectPropertyScopeOutput) == physicalOutputChannels else { return false }
            let actual = try RouteBufferLayout.validated(
                physicalInputChannels: physicalInputChannels,
                physicalOutputChannels: physicalOutputChannels,
                aggregateInputChannels: Self.bufferChannels(aggregateID, scope: kAudioObjectPropertyScopeInput),
                aggregateOutputChannels: Self.bufferChannels(aggregateID, scope: kAudioObjectPropertyScopeOutput),
                aggregateInputStreams: Self.streams(aggregateID, scope: kAudioObjectPropertyScopeInput),
                aggregateOutputStreams: Self.streams(aggregateID, scope: kAudioObjectPropertyScopeOutput),
                tapFormat: tapFormat)
            return actual == layout && !hasRenderFailure
        } catch { return false }
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        if let dsp {
            // Even if HAL refuses a teardown call, any surviving callback stays
            // silent before the original application path is unmuted below.
            nm_dsp_invalidate(dsp)
            for (objectID, var address) in listeners {
                let status = AudioObjectRemovePropertyListener(objectID, &address, nm_dsp_property_changed, UnsafeMutableRawPointer(dsp))
                if status != noErr { listenerMayBeLive = true }
            }
            listeners.removeAll()
        }
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            if didStart {
                let status = AudioDeviceStop(aggregateID, ioProcID)
                if status == noErr { callbackMayBeLive = false }
            }
            let status = AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            if status == noErr { callbackMayBeLive = false }
            self.ioProcID = nil
        }
        didStart = false
        if aggregateID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(aggregateID)
            if status == noErr { callbackMayBeLive = false }
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            // Make the original path audible even if HAL cannot destroy the tap.
            if let tapDescription { Self.unmuteTap(tapID, description: tapDescription) }
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        tapDescription = nil
    }

    private func create(processObjectIDs: [UInt32], gain: Float) throws {
        var sources: [AudioObjectID] = []
        for objectID in Set(processObjectIDs).sorted() where objectID != kAudioObjectUnknown {
            let pid: pid_t = try Self.read(objectID, selector: kAudioProcessPropertyPID, initial: 0)
            if pid != ProcessInfo.processInfo.processIdentifier { sources.append(objectID) }
        }
        guard !sources.isEmpty else { throw ProcessAudioRouteError.noSource }
        let outputUID = try Self.string(outputDeviceID, selector: kAudioDevicePropertyDeviceUID)
        let outputStreams = try Self.streams(outputDeviceID, scope: kAudioObjectPropertyScopeOutput)
        guard outputStreams.count == 1, outputStreams[0].startingChannel == 1 else {
            throw ProcessAudioRouteError.unsupportedFormat("Devices with multiple output streams are not supported yet.")
        }
        try RouteBufferLayout.validatePCM(outputStreams[0].format)
        originalOutputFormat = outputStreams[0].format
        physicalInputChannels = try Self.bufferChannels(outputDeviceID, scope: kAudioObjectPropertyScopeInput)
        physicalOutputChannels = try Self.bufferChannels(outputDeviceID, scope: kAudioObjectPropertyScopeOutput)

        let description = CATapDescription(processes: sources, deviceUID: outputUID, stream: 0)
        description.name = "NahtV0Mixer application audio"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        tapDescription = description
        try Self.check(AudioHardwareCreateProcessTap(description, &tapID), "Creating application audio tap")
        let format: AudioStreamBasicDescription = try Self.read(tapID, selector: kAudioTapPropertyFormat,
                                                               initial: AudioStreamBasicDescription())
        try RouteBufferLayout.validatePCM(format)
        guard Self.sameFormat(format, outputStreams[0].format) else {
            throw ProcessAudioRouteError.unsupportedFormat("The captured format differs from the selected output.")
        }
        tapFormat = format
        let tapUID = try Self.string(tapID, selector: kAudioTapPropertyUID)
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NahtV0Mixer private route",
            kAudioAggregateDeviceUIDKey: "com.levie.NahtV0Mixer.route.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
            // A start must complete even while the selected app is silent.
            kAudioAggregateDeviceTapAutoStartKey: false
        ]
        try Self.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID), "Creating audio route")

        let activeSubdevices = try Self.ids(aggregateID, selector: kAudioAggregateDevicePropertyActiveSubDeviceList)
        let activeSubtaps = try Self.ids(aggregateID, selector: kAudioAggregateDevicePropertySubTapList)
        guard activeSubdevices.count == 1, activeSubtaps.count == 1,
              try Self.string(activeSubdevices[0], selector: kAudioDevicePropertyDeviceUID) == outputUID else {
            throw ProcessAudioRouteError.unsupportedFormat("The private route's device membership could not be verified.")
        }
        let resolved = try RouteBufferLayout.validated(
            physicalInputChannels: physicalInputChannels,
            physicalOutputChannels: physicalOutputChannels,
            aggregateInputChannels: Self.bufferChannels(aggregateID, scope: kAudioObjectPropertyScopeInput),
            aggregateOutputChannels: Self.bufferChannels(aggregateID, scope: kAudioObjectPropertyScopeOutput),
            aggregateInputStreams: Self.streams(aggregateID, scope: kAudioObjectPropertyScopeInput),
            aggregateOutputStreams: Self.streams(aggregateID, scope: kAudioObjectPropertyScopeOutput),
            tapFormat: format)
        layout = resolved
        dsp = resolved.inputChannels.withUnsafeBufferPointer { inputs in
            resolved.outputChannels.withUnsafeBufferPointer { outputs in
                nm_dsp_create(inputs.baseAddress!, UInt32(inputs.count), outputs.baseAddress!, UInt32(outputs.count),
                              resolved.tapChannelOffset, resolved.tapChannelCount, resolved.sampleRate, gain)
            }
        }
        guard let dsp else { throw ProcessAudioRouteError.allocationFailed }
        // Invalidate immediately on a format/topology notification, before a
        // periodic controller check. The listener is also C and allocation-free.
        for device in [outputDeviceID, aggregateID] {
            for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput] {
                try addListener(device, selector: kAudioDevicePropertyStreamConfiguration, scope: scope)
                for stream in try Self.ids(device, selector: kAudioDevicePropertyStreams, scope: scope) {
                    try addListener(stream, selector: kAudioStreamPropertyVirtualFormat)
                }
            }
        }
        try Self.check(AudioDeviceCreateIOProcID(aggregateID, nm_dsp_io_proc, UnsafeMutableRawPointer(dsp), &ioProcID),
                       "Creating audio renderer")
        guard let ioProcID else { throw ProcessAudioRouteError.allocationFailed }
        if resolved.tapChannelOffset > 0 {
            let inputStreams = try Self.streams(aggregateID, scope: kAudioObjectPropertyScopeInput)
            let useMask: [UInt32] = inputStreams.map { $0.startingChannel > resolved.tapChannelOffset ? 1 : 0 }
            let result = useMask.withUnsafeBufferPointer {
                nm_configure_input_stream_usage(aggregateID, ioProcID, $0.baseAddress!, UInt32($0.count))
            }
            try Self.check(result, "Disabling hardware input streams")
        }
        callbackMayBeLive = true
        try Self.check(AudioDeviceStart(aggregateID, ioProcID), "Starting audio route")
        didStart = true
    }

    private func addListener(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws {
        guard let dsp else { return }
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        try Self.check(AudioObjectAddPropertyListener(object, &address, nm_dsp_property_changed, UnsafeMutableRawPointer(dsp)),
                       "Watching audio format changes")
        listeners.append((object, address))
    }

    private static func unmuteTap(_ tapID: AudioObjectID, description: CATapDescription) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        // We own the original description; no ambiguous ownership convention
        // for kAudioTapPropertyDescription reads is needed during cleanup.
        description.muteBehavior = .unmuted
        var reference = Unmanaged.passUnretained(description).toOpaque()
        withUnsafePointer(to: &reference) {
            _ = AudioObjectSetPropertyData(tapID, &address, 0, nil,
                                           UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), $0)
        }
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw ProcessAudioRouteError.coreAudio(operation, status) }
    }

    private static func read<T: BitwiseCopyable>(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutableBytes(of: &value) { storage in
            try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, storage.baseAddress!), "Reading audio device state")
        }
        guard size == MemoryLayout<T>.size else {
            throw ProcessAudioRouteError.unsupportedFormat("Core Audio returned an unexpected property size.")
        }
        return value
    }

    private static func string(_ object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var reference: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &reference) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        try check(status, "Reading audio device identifier")
        guard let reference else { throw ProcessAudioRouteError.unsupportedFormat("The audio device has no identifier.") }
        // Both DeviceUID and TapUID explicitly transfer a retained CFString to
        // the caller in AudioHardwareBase.h / AudioHardware.h.
        return reference.takeRetainedValue() as String
    }

    private static func ids(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "Reading audio stream list")
        guard size % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else {
            throw ProcessAudioRouteError.unsupportedFormat("The audio stream list has an invalid size.")
        }
        if size == 0 { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try result.withUnsafeMutableBytes { storage in
            try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, storage.baseAddress!), "Reading audio stream list")
        }
        return Array(result.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func streams(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [RouteStreamFormat] {
        try ids(device, selector: kAudioDevicePropertyStreams, scope: scope).map { stream in
            RouteStreamFormat(startingChannel: try read(stream, selector: kAudioStreamPropertyStartingChannel, initial: UInt32(0)),
                              format: try read(stream, selector: kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription()))
        }
    }

    private static func bufferChannels(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [UInt32] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "Reading audio buffer layout")
        // A zero-stream device may return just the count plus alignment padding,
        // rather than sizeof(AudioBufferList), which includes one AudioBuffer.
        guard size >= MemoryLayout<UInt32>.size else {
            throw ProcessAudioRouteError.unsupportedFormat("The audio buffer layout is incomplete.")
        }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let capacity = Int(size)
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage), "Reading audio buffer layout")
        guard size >= MemoryLayout<UInt32>.size else {
            throw ProcessAudioRouteError.unsupportedFormat("The audio buffer layout changed while it was being read.")
        }
        let count = Int(storage.load(as: UInt32.self))
        if count == 0 { return [] }
        let requiredSize = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers)! + count * MemoryLayout<AudioBuffer>.size
        guard count <= 32, requiredSize <= capacity, requiredSize <= Int(size) else {
            throw ProcessAudioRouteError.unsupportedFormat("The audio buffer layout exceeds supported limits.")
        }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).map(\.mNumberChannels)
    }

    private static func sameFormat(_ lhs: AudioStreamBasicDescription, _ rhs: AudioStreamBasicDescription) -> Bool {
        lhs.mSampleRate == rhs.mSampleRate && lhs.mFormatID == rhs.mFormatID && lhs.mFormatFlags == rhs.mFormatFlags &&
        lhs.mBytesPerPacket == rhs.mBytesPerPacket && lhs.mFramesPerPacket == rhs.mFramesPerPacket &&
        lhs.mBytesPerFrame == rhs.mBytesPerFrame && lhs.mChannelsPerFrame == rhs.mChannelsPerFrame && lhs.mBitsPerChannel == rhs.mBitsPerChannel
    }
}
