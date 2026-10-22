import AppKit
import AudioToolbox
import CoreAudio

public struct AudioOutputDevice: Identifiable, Equatable, Sendable {
    public let id: UInt32
    public let name: String
    public let uid: String
    public let sampleRate: Double
}

public struct AudioApplicationSource: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let bundleURL: URL?
    public let processObjectIDs: [UInt32]
    public let outputDeviceIDs: [UInt32]
    public let isActive: Bool
}

public struct AudioCatalogError: LocalizedError {
    let operation: String
    let status: OSStatus
    public var errorDescription: String? { "\(operation) (Core Audio \(status))." }
}

private enum HALValue {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
    static func read<T>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: T) throws -> T {
        var address = address, value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr, size == MemoryLayout<T>.size else { throw AudioCatalogError(operation: "Could not read audio device", status: status == noErr ? kAudioHardwareBadPropertySizeError : status) }
        return value
    }
    static func ids(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> [UInt32] {
        var address = address, size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
        guard status == noErr else { throw AudioCatalogError(operation: "Could not list audio sources", status: status) }
        guard size > 0, size <= 1_048_576, size % 4 == 0 else { return [] }
        var values = [UInt32](repeating: 0, count: Int(size) / 4)
        status = values.withUnsafeMutableBytes { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { throw AudioCatalogError(operation: "Could not list audio sources", status: status) }
        return Array(values.prefix(Int(size) / 4))
    }
    static func string(_ id: UInt32, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector), reference: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &reference) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        guard status == noErr, let reference else { return nil }
        return reference.takeRetainedValue() as String
    }
    static func writable(_ id: UInt32, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address, writable: DarwinBoolean = false
        return AudioObjectHasProperty(id, &address) && AudioObjectIsPropertySettable(id, &address, &writable) == noErr && writable.boolValue
    }
    static func write<T>(_ id: UInt32, _ address: AudioObjectPropertyAddress, _ value: T) throws {
        guard writable(id, address) else { throw AudioCatalogError(operation: "This device does not support that control", status: kAudioHardwareUnknownPropertyError) }
        var address = address, value = value
        let status = withUnsafeBytes(of: &value) { AudioObjectSetPropertyData(id, &address, 0, nil, UInt32($0.count), $0.baseAddress!) }
        guard status == noErr else { throw AudioCatalogError(operation: "Could not change audio device", status: status) }
    }
    static func channelCount(_ id: UInt32, scope: AudioObjectPropertyScope) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: scope), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size, size < 65_536 else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

public enum AudioCatalog {
    public static func processObjectIDs(forPID pid: pid_t) throws -> [UInt32] {
        try HALValue.ids(AudioObjectID(kAudioObjectSystemObject), HALValue.address(kAudioHardwarePropertyProcessObjectList)).filter {
            (try? HALValue.read($0, HALValue.address(kAudioProcessPropertyPID), initial: pid_t(0))) == pid
        }
    }
    public static func defaultOutputID() throws -> UInt32 {
        try HALValue.read(AudioObjectID(kAudioObjectSystemObject), HALValue.address(kAudioHardwarePropertyDefaultOutputDevice), initial: UInt32(0))
    }
    public static func outputDevices() throws -> [AudioOutputDevice] {
        try HALValue.ids(AudioObjectID(kAudioObjectSystemObject), HALValue.address(kAudioHardwarePropertyDevices)).compactMap { id in
            guard HALValue.channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0,
                  let uid = HALValue.string(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix("com.levie.NahtV0Mixer.route."),
                  !uid.hasPrefix("vn.levie.NahtV0Mixer.route.") else { return nil }
            let name = HALValue.string(id, kAudioObjectPropertyName) ?? "Audio device"
            let rate = (try? HALValue.read(id, HALValue.address(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))) ?? 0
            return AudioOutputDevice(id: id, name: name, uid: uid, sampleRate: rate)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public static func selectOutput(_ id: UInt32) throws {
        guard try outputDevices().contains(where: { $0.id == id }) else { throw AudioCatalogError(operation: "Output device is no longer available", status: kAudioHardwareBadDeviceError) }
        try HALValue.write(AudioObjectID(kAudioObjectSystemObject), HALValue.address(kAudioHardwarePropertyDefaultOutputDevice), id)
    }
    private static func volumeControls(_ id: UInt32) -> [AudioObjectPropertyAddress] {
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar] {
            let address = HALValue.address(selector, scope: kAudioObjectPropertyScopeOutput)
            if HALValue.writable(id, address) { return [address] }
        }
        return (1...max(1, HALValue.channelCount(id, scope: kAudioObjectPropertyScopeOutput))).compactMap { channel in
            let address = HALValue.address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: UInt32(channel))
            return HALValue.writable(id, address) ? address : nil
        }
    }
    public static func volume(of id: UInt32) -> Double? {
        volumeControls(id).compactMap { try? HALValue.read(id, $0, initial: Float32(0)) }.max().map { Double($0) }
    }
    public static func setVolume(_ volume: Double, of id: UInt32) throws {
        let controls = volumeControls(id)
        guard !controls.isEmpty, volume.isFinite else { throw AudioCatalogError(operation: "Device volume is unavailable", status: kAudioHardwareUnknownPropertyError) }
        let target = Float32(max(0, min(1, volume)))
        let old = controls.map { (try? HALValue.read(id, $0, initial: Float32(0))) ?? 0 }
        let maximum = old.max() ?? 0
        for (index, control) in controls.enumerated() {
            let adjusted = controls.count > 1 && maximum > 0 ? target * old[index] / maximum : target
            try HALValue.write(id, control, adjusted)
        }
    }
    public static func muted(_ id: UInt32) -> Bool? {
        let address = HALValue.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
        guard HALValue.writable(id, address), let value = try? HALValue.read(id, address, initial: UInt32(0)) else { return nil }
        return value != 0
    }
    public static func setMuted(_ muted: Bool, of id: UInt32) throws {
        try HALValue.write(id, HALValue.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput), UInt32(muted ? 1 : 0))
    }

    @MainActor public static func applications() throws -> [AudioApplicationSource] {
        let processes = try HALValue.ids(AudioObjectID(kAudioObjectSystemObject), HALValue.address(kAudioHardwarePropertyProcessObjectList))
        let running = NSWorkspace.shared.runningApplications
        struct Entry {
            var identity: AppAudioIdentity
            var processes: [UInt32] = []
            var devices: Set<UInt32> = []
            var active = false
        }
        var entries: [String: Entry] = [:]
        for process in processes {
            guard let pid = try? HALValue.read(process, HALValue.address(kAudioProcessPropertyPID), initial: pid_t(0)),
                  pid > 0, pid != getpid() else { continue }
            let active = ((try? HALValue.read(process, HALValue.address(kAudioProcessPropertyIsRunningOutput), initial: UInt32(0))) ?? 0) != 0
            let devices = (try? HALValue.ids(process, HALValue.address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput))) ?? []
            let app = running.first { $0.processIdentifier == pid } ?? NSRunningApplication(processIdentifier: pid)
            let bundleID = HALValue.string(process, kAudioProcessPropertyBundleID)
            let identity = AppAudioIdentity.resolve(pid: pid, processBundleID: bundleID, bundleURL: app?.bundleURL,
                                                    name: app?.localizedName, candidates: running)
            guard identity.id != "com.levie.NahtV0Mixer", identity.id != "vn.levie.NahtV0Mixer", !identity.id.hasPrefix("com.apple.audio."),
                  !["com.apple.systemsounds", "systemsoundserverd", "com.apple.audiomxd", "com.apple.controlcenter"].contains(identity.id),
                  identity.name != "coreaudiod" else { continue }
            var entry = entries[identity.id] ?? Entry(identity: identity)
            entry.processes.append(process); entry.devices.formUnion(devices); entry.active = entry.active || active
            entries[identity.id] = entry
        }
        return entries.values.map {
            AudioApplicationSource(id: $0.identity.id, name: $0.identity.name, bundleURL: $0.identity.bundleURL,
                                   processObjectIDs: $0.processes.sorted(), outputDeviceIDs: $0.devices.sorted(), isActive: $0.active)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct AppAudioIdentity {
    var id: String
    var name: String
    var bundleURL: URL?
    static func enclosingApplication(_ url: URL) -> URL? {
        let parts = url.standardizedFileURL.pathComponents
        guard let end = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(parts[...end])))
    }
    @MainActor static func resolve(pid: pid_t, processBundleID: String?, bundleURL: URL?, name: String?, candidates: [NSRunningApplication]) -> Self {
        let processBundleID = processBundleID.flatMap { $0.isEmpty ? nil : $0 }
        let name = name.flatMap { $0.isEmpty ? nil : $0 }
        let location = bundleURL ?? name.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
        if let url = location.flatMap(enclosingApplication), let bundle = Bundle(url: url), let id = bundle.bundleIdentifier {
            let owner = candidates.first { $0.bundleIdentifier == id }
            return Self(id: id, name: owner?.localizedName ?? (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                        ?? url.deletingPathExtension().lastPathComponent, bundleURL: url)
        }
        if let id = processBundleID, let owner = candidates.filter({ candidate in
            guard let candidateID = candidate.bundleIdentifier else { return false }
            return id == candidateID || id.hasPrefix(candidateID + ".")
        }).max(by: { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }), let ownerID = owner.bundleIdentifier {
            return Self(id: ownerID, name: owner.localizedName ?? ownerID, bundleURL: owner.bundleURL)
        }
        let label = name.map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0).lastPathComponent : $0 }
        return Self(id: processBundleID ?? "process:\(pid)", name: label ?? processBundleID ?? "Audio process \(pid)", bundleURL: bundleURL)
    }
}
