import Foundation

public struct ApplicationLevel: Codable, Equatable, Sendable {
    public var volume: Double
    public var muted: Bool
    public init(volume: Double = 1, muted: Bool = false) {
        self.volume = Self.clamp(volume); self.muted = muted
    }
    public var gain: Float { muted ? 0 : Float(Self.clamp(volume)) }
    public var needsProcessing: Bool { muted || volume < 0.9999 }
    public static func clamp(_ value: Double) -> Double { value.isFinite ? max(0, min(1, value)) : 1 }
}

public final class MixerPreferences {
    private let defaults: UserDefaults
    private let key = "applicationLevels.v1"
    public private(set) var levels: [String: ApplicationLevel]
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), data.count <= 1_048_576,
           let decoded = try? JSONDecoder().decode([String: ApplicationLevel].self, from: data) {
            levels = decoded.mapValues { ApplicationLevel(volume: $0.volume, muted: $0.muted) }
        } else { levels = [:] }
    }
    public func level(for id: String) -> ApplicationLevel { levels[id] ?? ApplicationLevel() }
    public func set(_ level: ApplicationLevel, for id: String) {
        guard !id.hasPrefix("process:"), id.count <= 512 else { return }
        levels[id] = ApplicationLevel(volume: level.volume, muted: level.muted)
        persist()
    }
    public func remove(_ id: String) { levels.removeValue(forKey: id); persist() }
    private func persist() {
        if let data = try? JSONEncoder().encode(levels) { defaults.set(data, forKey: key) }
    }
}
