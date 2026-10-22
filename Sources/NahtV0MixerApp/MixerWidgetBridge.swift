import AppKit
import Combine
import MixerWidgetCore
import WidgetKit

@MainActor
protocol WidgetMixerSource: MixerMenuSource {
    func refresh()
}

extension MixerStore: WidgetMixerSource {}

/// The app is the only audio owner. The extension only exchanges records inside
/// the signed App Group; it cannot start a second route or audio-capture process.
@MainActor
final class MixerWidgetBridge {
    private let source: any WidgetMixerSource
    private let storage: WidgetSharedStore
    private let sessionID = UUID()
    private let now: () -> Date
    private let reload: () -> Void
    private var timer: Timer?
    private var observation: AnyCancellable?
    private var running = false
    private var updateQueued = false
    private var lastContent: WidgetSnapshot?
    private var lastWrite = Date.distantPast
    private var lastReload = Date.distantPast
    private var pendingReload = false
    private var pending: WidgetCommand?
    private var lastPrune = Date.distantPast
    private var iconCache: [String: Data] = [:]
    private var iconAttempts: Set<String> = []

    init(source: any WidgetMixerSource, storage: WidgetSharedStore,
         now: @escaping () -> Date = Date.init,
         reload: @escaping () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedStore.kind) }) {
        self.source = source
        self.storage = storage
        self.now = now
        self.reload = reload
    }

    func start(scheduleTimer: Bool = true) {
        guard !running else { return }
        running = true
        observation = source.objectWillChange.sink { [weak self] in
            guard let self, !self.updateQueued else { return }
            self.updateQueued = true
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                MainActor.assumeIsolated {
                    self?.updateQueued = false
                    self?.publish()
                }
            }
        }
        publish(forceReload: true)
        if scheduleTimer {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate(); timer = nil
        observation?.cancel(); observation = nil
        try? storage.writeSnapshot(snapshot(at: now()))
        if let pending { finish(pending, error: "NahtV0Mixer stopped. Open the app and try again.") }
        reload()
    }

    func poll() {
        guard running else { return }
        if let command = pending {
            // Route changes complete asynchronously. Acknowledge the actual result,
            // not the optimistic enabled state published before Core Audio starts.
            if !source.isBusy {
                finish(command, error: commandError(command))
                pending = nil
            } else if now().timeIntervalSince(command.issuedAt) > 10 {
                finish(command, error: "Audio setup is still in progress. Check NahtV0Mixer.")
                pending = nil
            }
        }
        if pending == nil {
            for command in storage.pendingCommands() {
                if storage.readReply(id: command.id) != nil {
                    try? storage.removeCommand(id: command.id)
                    continue
                }
                do {
                    try command.validate(sessionID: sessionID,
                        appIDs: Set(source.applications.filter(\.isActive).map(\.id)), at: now())
                    try apply(command.action)
                    if source.isBusy {
                        pending = command
                        break
                    }
                    finish(command, error: commandError(command))
                } catch {
                    finish(command, error: error.localizedDescription)
                }
            }
        }
        publish()
        if now().timeIntervalSince(lastPrune) >= 60 {
            storage.prune(at: now()); lastPrune = now()
        }
    }

    private func apply(_ action: WidgetAction) throws {
        guard !source.isBusy else { throw BridgeError.busy }
        switch action {
        case let .setSystemVolume(value):
            guard source.systemVolume != nil else { throw BridgeError.volumeUnavailable }
            source.setSystemVolume(value)
        case let .setSystemMuted(muted):
            guard source.systemMuted != nil else { throw BridgeError.muteUnavailable }
            source.setSystemMuted(muted)
        case let .setMixerEnabled(enabled):
            if source.isMixerEnabled != enabled { source.setMixerEnabled(enabled) }
        case let .setAppVolume(id, value):
            guard source.isMixerEnabled else { throw BridgeError.mixerOff }
            source.setVolume(value, for: id)
        case let .setAppMuted(id, muted):
            guard source.isMixerEnabled else { throw BridgeError.mixerOff }
            source.setMuted(muted, for: id)
        case .refresh:
            source.refresh()
        }
    }

    private func commandError(_ command: WidgetCommand) -> String? {
        if let error = source.lastError { return error }
        switch command.action {
        case let .setAppVolume(id, _), let .setAppMuted(id, _):
            return source.applications.first { $0.id == id }?.error
        case .setMixerEnabled(true):
            return source.applications.compactMap(\.error).first
        default:
            return nil
        }
    }

    private func finish(_ command: WidgetCommand, error: String?) {
        let result = snapshot(at: now())
        do {
            try storage.writeSnapshot(result)
            try storage.writeReply(WidgetReply(id: command.id, snapshot: result, error: error))
            try storage.removeCommand(id: command.id)
        } catch {
            // Keep the command for a later attempt if the shared store is unavailable.
            // All write actions set an explicit value and are safe to repeat.
        }
        lastWrite = now()
        lastContent = snapshot(at: .distantPast)
        pendingReload = false; lastReload = now(); reload()
    }

    private func publish(forceReload: Bool = false) {
        guard running else { return }
        let content = snapshot(at: .distantPast)
        let changed = content != lastContent
        if changed || now().timeIntervalSince(lastWrite) >= 30 {
            do {
                try storage.writeSnapshot(snapshot(at: now()))
                lastContent = content; lastWrite = now()
                pendingReload = pendingReload || changed
            } catch { return }
        }
        if forceReload || (pendingReload && now().timeIntervalSince(lastReload) >= 60) {
            pendingReload = false; lastReload = now(); reload()
        }
    }

    private func snapshot(at date: Date) -> WidgetSnapshot {
        let playing = source.applications.filter(\.isActive)
        let IDs = Set(playing.map(\.id))
        iconCache = iconCache.filter { IDs.contains($0.key) }
        iconAttempts.formIntersection(IDs)
        return WidgetSnapshot(sessionID: sessionID, updatedAt: date, isRunning: running,
            mixerEnabled: running && source.isMixerEnabled, isBusy: running && source.isBusy,
            systemVolume: source.systemVolume, systemMuted: source.systemMuted,
            outputName: source.outputDevices.first { $0.id == source.selectedOutputID }?.name ?? "",
            apps: running ? playing.prefix(32).enumerated().map { index, app in
                WidgetAppState(id: app.id, name: app.name, volume: app.volume, isMuted: app.isMuted,
                               isPlaying: true, iconPNG: index < 4 ? icon(for: app) : nil)
            } : [], error: source.lastError)
    }

    private func icon(for app: MixerApplication) -> Data? {
        if iconAttempts.contains(app.id) { return iconCache[app.id] }
        iconAttempts.insert(app.id)
        guard let url = app.bundleURL,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSWorkspace.shared.icon(forFile: url.path).draw(in: NSRect(x: 0, y: 0, width: 48, height: 48))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]), png.count <= 10_240 else { return nil }
        iconCache[app.id] = png
        return png
    }
}

private enum BridgeError: LocalizedError {
    case busy, mixerOff, volumeUnavailable, muteUnavailable
    var errorDescription: String? {
        switch self {
        case .busy: return "NahtV0Mixer is busy. Try again."
        case .mixerOff: return "Enable Per-app mixer first."
        case .volumeUnavailable: return "Volume is unavailable on this output."
        case .muteUnavailable: return "Mute is unavailable on this output."
        }
    }
}
