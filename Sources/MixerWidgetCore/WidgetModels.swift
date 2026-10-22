import Foundation

public struct WidgetAppState: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let volume: Double
    public let isMuted: Bool
    public let isPlaying: Bool
    public let iconPNG: Data?

    public init(id: String, name: String, volume: Double, isMuted: Bool, isPlaying: Bool, iconPNG: Data? = nil) {
        self.id = id
        self.name = name
        self.volume = volume
        self.isMuted = isMuted
        self.isPlaying = isPlaying
        self.iconPNG = iconPNG
    }
}

public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sessionID: UUID
    public let updatedAt: Date
    public let isRunning: Bool
    public let mixerEnabled: Bool
    public let isBusy: Bool
    public let systemVolume: Double?
    public let systemMuted: Bool?
    public let outputName: String
    public let apps: [WidgetAppState]
    public let error: String?

    public init(
        schemaVersion: Int = 1,
        sessionID: UUID = UUID(),
        updatedAt: Date = Date(),
        isRunning: Bool = false,
        mixerEnabled: Bool = false,
        isBusy: Bool = false,
        systemVolume: Double? = nil,
        systemMuted: Bool? = nil,
        outputName: String = "",
        apps: [WidgetAppState] = [],
        error: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.updatedAt = updatedAt
        self.isRunning = isRunning
        self.mixerEnabled = mixerEnabled
        self.isBusy = isBusy
        self.systemVolume = systemVolume
        self.systemMuted = systemMuted
        self.outputName = outputName
        self.apps = apps
        self.error = error
    }

    public static var unavailable: WidgetSnapshot { WidgetSnapshot() }

    public func isFresh(at now: Date = Date()) -> Bool {
        guard schemaVersion == 1, isRunning else { return false }
        let age = now.timeIntervalSince(updatedAt)
        return age >= -5 && age <= 90
    }
}

public enum WidgetAction: Codable, Equatable, Sendable {
    case setSystemVolume(Double)
    case setSystemMuted(Bool)
    case setMixerEnabled(Bool)
    case setAppVolume(id: String, value: Double)
    case setAppMuted(id: String, muted: Bool)
    case refresh
}

/// A user gesture is resolved against the current shared state before it becomes
/// an explicit, replay-safe command for the app.
public enum WidgetControlRequest: Equatable, Sendable {
    case toggleMixer
    case toggleSystemMute
    case nextSystemVolumePreset
    case toggleAppMute(id: String)
    case nextAppVolumePreset(id: String)
    case refresh

    public func resolve(in snapshot: WidgetSnapshot, at now: Date = Date()) throws -> WidgetAction {
        guard snapshot.schemaVersion == 1, snapshot.isRunning, !snapshot.isBusy,
              self == .refresh || snapshot.isFresh(at: now) else {
            throw WidgetControlRequestError.stale
        }

        switch self {
        case .toggleMixer:
            return .setMixerEnabled(!snapshot.mixerEnabled)
        case .toggleSystemMute:
            guard let muted = snapshot.systemMuted else { throw WidgetControlRequestError.unavailable }
            return .setSystemMuted(!muted)
        case .nextSystemVolumePreset:
            guard let volume = snapshot.systemVolume else { throw WidgetControlRequestError.unavailable }
            return .setSystemVolume(try Self.nextPreset(after: volume))
        case let .toggleAppMute(id):
            let app = try app(id: id, in: snapshot)
            return .setAppMuted(id: app.id, muted: !app.isMuted)
        case let .nextAppVolumePreset(id):
            let app = try app(id: id, in: snapshot)
            return .setAppVolume(id: app.id, value: try Self.nextPreset(after: app.volume))
        case .refresh:
            return .refresh
        }
    }

    private func app(id: String, in snapshot: WidgetSnapshot) throws -> WidgetAppState {
        guard snapshot.mixerEnabled else { throw WidgetControlRequestError.mixerDisabled }
        guard let app = snapshot.apps.first(where: { $0.id == id }) else {
            throw WidgetControlRequestError.unknownApp
        }
        return app
    }

    private static func nextPreset(after volume: Double) throws -> Double {
        guard volume.isFinite, (0...1).contains(volume) else {
            throw WidgetControlRequestError.invalidVolume
        }
        return [0.25, 0.50, 0.75, 1.0].first(where: { $0 > volume + 0.01 }) ?? 0.25
    }
}

public enum WidgetControlRequestError: LocalizedError, Equatable, Sendable {
    case stale
    case unavailable
    case mixerDisabled
    case unknownApp
    case invalidVolume

    public var errorDescription: String? {
        switch self {
        case .stale: return "The mixer data is stale. Refresh the widget and try again."
        case .unavailable: return "That audio control is unavailable. Refresh the widget and try again."
        case .mixerDisabled: return "Enable the mixer before changing an app."
        case .unknownApp: return "That app is no longer available. Refresh the widget and try again."
        case .invalidVolume: return "The requested volume is invalid."
        }
    }
}

public struct WidgetCommand: Codable, Equatable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let issuedAt: Date
    public let action: WidgetAction

    public init(id: UUID = UUID(), sessionID: UUID, issuedAt: Date = Date(), action: WidgetAction) {
        self.id = id
        self.sessionID = sessionID
        self.issuedAt = issuedAt
        self.action = action
    }

    public func validate(sessionID expectedSessionID: UUID, appIDs: Set<String>, at now: Date = Date()) throws {
        guard sessionID == expectedSessionID else { throw WidgetCommandValidationError.wrongSession }
        let age = now.timeIntervalSince(issuedAt)
        guard age >= -5 else { throw WidgetCommandValidationError.issuedInFuture }
        guard age <= 10 else { throw WidgetCommandValidationError.expired }

        switch action {
        case let .setSystemVolume(value):
            try Self.validateVolume(value)
        case let .setAppVolume(id, value):
            guard appIDs.contains(id) else { throw WidgetCommandValidationError.unknownApp(id) }
            try Self.validateVolume(value)
        case let .setAppMuted(id, _):
            guard appIDs.contains(id) else { throw WidgetCommandValidationError.unknownApp(id) }
        case .setSystemMuted, .setMixerEnabled, .refresh:
            break
        }
    }

    private static func validateVolume(_ value: Double) throws {
        guard value.isFinite, (0...1).contains(value) else {
            throw WidgetCommandValidationError.invalidVolume(value)
        }
    }
}

public enum WidgetCommandValidationError: LocalizedError, Equatable, Sendable {
    case expired
    case issuedInFuture
    case wrongSession
    case invalidVolume(Double)
    case unknownApp(String)

    public var errorDescription: String? {
        switch self {
        case .expired, .issuedInFuture: return "This widget action expired. Try again."
        case .wrongSession: return "NahtV0Mixer restarted. Refresh the widget and try again."
        case .invalidVolume: return "The requested volume is invalid."
        case .unknownApp: return "That app is no longer playing audio. Refresh the widget."
        }
    }
}

public struct WidgetReply: Codable, Equatable, Sendable {
    public let id: UUID
    public let snapshot: WidgetSnapshot
    public let error: String?

    public init(id: UUID, snapshot: WidgetSnapshot, error: String? = nil) {
        self.id = id
        self.snapshot = snapshot
        self.error = error
    }
}
