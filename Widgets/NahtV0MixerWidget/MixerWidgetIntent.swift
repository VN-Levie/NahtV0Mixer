import AppIntents
import Foundation
import WidgetKit
import MixerWidgetCore

enum MixerWidgetAction: String, AppEnum {
    case toggleMixer
    case toggleSystemMute
    case setSystemVolume
    case toggleAppMute
    case setAppVolume
    case refresh

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Mixer action")
    static var caseDisplayRepresentations: [MixerWidgetAction: DisplayRepresentation] = [
        .toggleMixer: "Mixer on/off",
        .toggleSystemMute: "System mute",
        .setSystemVolume: "System volume",
        .toggleAppMute: "App mute",
        .setAppVolume: "App volume",
        .refresh: "Refresh"
    ]
}

struct MixerWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Control NahtV0Mixer"
    static var description = IntentDescription("Change a volume, mute state, or mixer state from the widget.")
    static var openAppWhenRun = false

    @Parameter(title: "Action")
    var action: MixerWidgetAction

    @Parameter(title: "Application ID")
    var applicationID: String

    @Parameter(title: "Value")
    var value: Double

    @Parameter(title: "Enabled")
    var enabled: Bool

    init(action: MixerWidgetAction, applicationID: String = "", value: Double = 0, enabled: Bool = false) {
        self.action = action
        self.applicationID = applicationID
        self.value = value
        self.enabled = enabled
    }

    init() {
        self.action = .refresh
        self.applicationID = ""
        self.value = 0
        self.enabled = false
    }

    func perform() async throws -> some IntentResult {
        let store: WidgetSharedStore
        do {
            store = try WidgetSharedStore.configured()
        } catch {
            throw MixerWidgetIntentError.offline
        }

        guard let snapshot = store.readSnapshot() else {
            throw MixerWidgetIntentError.stale
        }

        // Archived timeline parameters can lag behind completed actions. Resolve
        // each gesture from the fresh snapshot, then queue an explicit value so
        // replaying a command never toggles or advances the volume twice.
        let request: WidgetControlRequest
        switch action {
        case .toggleMixer:
            request = .toggleMixer
        case .toggleSystemMute:
            request = .toggleSystemMute
        case .setSystemVolume:
            request = .nextSystemVolumePreset
        case .toggleAppMute:
            request = .toggleAppMute(id: applicationID)
        case .setAppVolume:
            request = .nextAppVolumePreset(id: applicationID)
        case .refresh:
            request = .refresh
        }

        let commandAction = try request.resolve(in: snapshot)
        let command = WidgetCommand(sessionID: snapshot.sessionID, action: commandAction)
        do {
            try store.submit(command)
            defer {
                try? store.removeCommand(id: command.id)
                try? store.removeReply(id: command.id)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while ContinuousClock.now < deadline {
                if let reply = store.readReply(id: command.id) {
                    if let error = reply.error, !error.isEmpty { throw MixerWidgetIntentError.app(error) }
                    WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedStore.kind)
                    return .result()
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw MixerWidgetIntentError.timeout
        } catch is CancellationError {
            throw MixerWidgetIntentError.cancelled
        } catch let error as MixerWidgetIntentError {
            throw error
        } catch {
            throw MixerWidgetIntentError.app(error.localizedDescription)
        }
    }
}

enum MixerWidgetIntentError: Error, LocalizedError {
    case offline
    case stale
    case timeout
    case cancelled
    case app(String)

    var errorDescription: String? {
        switch self {
        case .offline: return "NahtV0Mixer is offline or unavailable."
        case .stale: return "The mixer data is stale. Refresh the widget and try again."
        case .timeout: return "NahtV0Mixer did not respond within 3 seconds."
        case .cancelled: return "The mixer action was cancelled."
        case let .app(message): return message
        }
    }
}
