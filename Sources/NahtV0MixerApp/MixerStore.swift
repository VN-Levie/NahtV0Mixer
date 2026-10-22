import AppKit
import Combine
import AudioRouting
import MixerCore

struct MixerApplication: Identifiable, Equatable {
    let id: String
    let name: String
    let bundleURL: URL?
    var volume: Double
    var isMuted: Bool
    var isActive: Bool
    var isProcessing: Bool
    var error: String?
}

struct RouteRequest: Equatable {
    let processIDs: [UInt32]
    let outputID: UInt32
    let sampleRate: Double
    let gain: Float
    var sourceIsActive = true
    func sameConfiguration(as other: Self) -> Bool {
        processIDs == other.processIDs && outputID == other.outputID && sampleRate == other.sampleRate
    }
}

protocol MixerAudioRoute: AnyObject {
    var hasRenderFailure: Bool { get }
    var configurationIsCurrent: Bool { get }
    var processedFrameCount: UInt64 { get }
    func setGain(_ gain: Float)
    func stop()
}
extension ProcessAudioRoute: MixerAudioRoute {}

struct MixerVolumeIO {
    let read: (UInt32) -> Double?
    let write: (Double, UInt32) throws -> Void

    static let live = MixerVolumeIO(
        read: { AudioCatalog.volume(of: $0) },
        write: { try AudioCatalog.setVolume($0, of: $1) })
}

/// All graph mutations run in order; the render callback reads only the C control state.
final class RouteController {
    private let queue = DispatchQueue(label: "com.levie.NahtV0Mixer.routes", qos: .userInitiated)
    private let generationLock = NSLock()
    private var generation = 0
    private var routes: [String: (route: any MixerAudioRoute, request: RouteRequest, frames: UInt64, progressAt: TimeInterval)] = [:]
    private var failures: [String: (RouteRequest, String)] = [:]
    private let makeRoute: (RouteRequest) throws -> any MixerAudioRoute
    private let now: () -> TimeInterval
    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         makeRoute: @escaping (RouteRequest) throws -> any MixerAudioRoute = {
        try ProcessAudioRoute(processObjectIDs: $0.processIDs, outputDeviceID: $0.outputID, gain: $0.gain)
    }) { self.makeRoute = makeRoute; self.now = now }
    private func nextGeneration() -> Int {
        generationLock.lock(); defer { generationLock.unlock() }
        generation += 1; return generation
    }
    private func isCurrent(_ value: Int) -> Bool {
        generationLock.lock(); defer { generationLock.unlock() }
        return value == generation
    }
    func apply(_ requests: [String: RouteRequest], retry: Bool = false,
               completion: @escaping (Set<String>, [String: String]) -> Void) {
        let version = nextGeneration()
        queue.async { [self] in
            guard isCurrent(version) else { return }
            if retry { failures.removeAll() }
            for id in Array(routes.keys) where requests[id] == nil {
                routes.removeValue(forKey: id)?.route.stop()
            }
            failures = failures.filter { requests[$0.key] != nil }
            for (id, request) in requests {
                guard isCurrent(version) else { return }
                if var state = routes[id] {
                    let route = state.route, previous = state.request
                    if !request.sameConfiguration(as: previous) {
                        route.stop(); routes.removeValue(forKey: id)
                    } else if route.hasRenderFailure || !route.configurationIsCurrent {
                        route.stop(); routes.removeValue(forKey: id)
                        failures[id] = (request, "Audio format changed. Reset this app or toggle the mixer to retry.")
                        continue
                    } else {
                        let frames = route.processedFrameCount
                        if frames != state.frames || !request.sourceIsActive || !previous.sourceIsActive {
                            state.progressAt = now()
                        } else if now() - state.progressAt >= 4 {
                            route.stop(); routes.removeValue(forKey: id)
                            failures[id] = (request, "No audio frames arrived. Check system audio access and toggle the mixer to retry.")
                            continue
                        }
                        state.frames = frames; state.request = request
                        route.setGain(request.gain); routes[id] = state; continue
                    }
                }
                if failures[id]?.0 == request { continue }
                failures.removeValue(forKey: id)
                do {
                    let route = try makeRoute(request)
                    guard isCurrent(version) else { route.stop(); return }
                    routes[id] = (route, request, route.processedFrameCount, now())
                } catch { failures[id] = (request, error.localizedDescription) }
            }
            let controlled = Set(routes.filter { $0.value.route.processedFrameCount > 0 }.keys)
            let errors = failures.mapValues { $0.1 }
            DispatchQueue.main.async { [self] in
                guard isCurrent(version) else { return }
                completion(controlled, errors)
            }
        }
    }
    func stopAll() {
        _ = nextGeneration()
        queue.sync {
            routes.values.forEach { $0.route.stop() }
            routes.removeAll(); failures.removeAll()
        }
    }
}

@MainActor final class MixerStore: ObservableObject {
    static let shared = MixerStore()
    @Published private(set) var applications: [MixerApplication] = []
    @Published private(set) var outputDevices: [AudioOutputDevice] = []
    @Published private(set) var selectedOutputID: UInt32 = 0
    @Published private(set) var systemVolume: Double?
    @Published private(set) var systemMuted: Bool?
    @Published private(set) var isMixerEnabled = false
    @Published private(set) var isBusy = false
    @Published private(set) var lastError: String?
    private let preferences: MixerPreferences
    private let defaults: UserDefaults
    private let volumeIO: MixerVolumeIO
    private let controller = RouteController()
    private var sources: [AudioApplicationSource] = []
    private var sessionLevels: [String: ApplicationLevel] = [:]
    private var controlled: Set<String> = []
    private var routeErrors: [String: String] = [:]
    private var timer: Timer?
    private var notifications: [NSObjectProtocol] = []
    private var suspended = false
    private var stopped = false

    init(defaults: UserDefaults = .standard, volumeIO: MixerVolumeIO = .live, initialOutputID: UInt32 = 0) {
        self.defaults = defaults
        self.volumeIO = volumeIO
        preferences = MixerPreferences(defaults: defaults)
        selectedOutputID = initialOutputID
        // A fresh installation starts in bypass. Restore only the user's saved
        // explicit choice on later launches, including after app updates.
        isMixerEnabled = defaults.bool(forKey: "perAppMixerEnabled")
    }
    func start() {
        guard timer == nil else { return }
        stopped = false
        refresh()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        let center = NSWorkspace.shared.notificationCenter
        notifications.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.suspended = true; self?.stopRouting(); self?.publishApplications()
            }
        })
        notifications.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspended = false; self?.refresh() }
        })
    }
    func refresh() {
        guard !stopped else { return }
        do {
            outputDevices = try AudioCatalog.outputDevices()
            selectedOutputID = try AudioCatalog.defaultOutputID()
            systemVolume = AudioCatalog.volume(of: selectedOutputID)
            systemMuted = AudioCatalog.muted(selectedOutputID)
            sources = try AudioCatalog.applications()
            sessionLevels = sessionLevels.filter { id, _ in sources.contains { $0.id == id } }
            publishApplications(); reconcile()
        } catch {
            lastError = error.localizedDescription
            stopRouting(); publishApplications()
        }
    }
    func shutdown() {
        stopped = true
        timer?.invalidate(); timer = nil
        notifications.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; notifications.removeAll()
        stopRouting()
    }
    private func stopRouting() {
        controller.stopAll(); controlled.removeAll(); isBusy = false
    }
    func setMixerEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "perAppMixerEnabled")
        isMixerEnabled = enabled
        lastError = nil; isBusy = true
        reconcile(retry: true)
    }
    private func level(_ id: String) -> ApplicationLevel { sessionLevels[id] ?? preferences.level(for: id) }
    private func save(_ level: ApplicationLevel, id: String) {
        if id.hasPrefix("process:") { sessionLevels[id] = level }
        else { preferences.set(level, for: id) }
        // Widget replies must wait for the route queue to accept the gain/mute
        // change and report any setup failure, just like the mixer on/off action.
        lastError = nil; isBusy = true; publishApplications(); reconcile()
    }
    func setVolume(_ value: Double, for id: String) {
        let old = level(id)
        save(ApplicationLevel(volume: value, muted: old.muted), id: id)
    }
    func setMuted(_ muted: Bool, for id: String) {
        save(ApplicationLevel(volume: level(id).volume, muted: muted), id: id)
    }
    func resetApplication(_ id: String) {
        preferences.remove(id); sessionLevels.removeValue(forKey: id)
        routeErrors.removeValue(forKey: id); publishApplications(); reconcile(retry: true)
    }
    func setSystemVolume(_ value: Double) {
        guard value.isFinite else {
            lastError = "Device volume is unavailable."
            return
        }
        let clampedValue = min(max(value, 0), 1)
        do {
            try volumeIO.write(clampedValue, selectedOutputID)
            systemVolume = volumeIO.read(selectedOutputID)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
    func setSystemMuted(_ value: Bool) {
        do { try AudioCatalog.setMuted(value, of: selectedOutputID); lastError = nil; refresh() }
        catch { lastError = error.localizedDescription; refresh() }
    }
    func selectOutput(_ id: UInt32) {
        stopRouting()
        do { try AudioCatalog.selectOutput(id); lastError = nil; refresh() }
        catch { lastError = error.localizedDescription; refresh() }
    }
    private func publishApplications() {
        applications = sources.filter { $0.isActive || controlled.contains($0.id) || level($0.id).needsProcessing }.map { source in
            let saved = level(source.id)
            return MixerApplication(id: source.id, name: source.name, bundleURL: source.bundleURL,
                                    volume: saved.volume, isMuted: saved.muted, isActive: source.isActive,
                                    isProcessing: controlled.contains(source.id), error: routeErrors[source.id])
        }
    }
    private func reconcile(retry: Bool = false) {
        var requests: [String: RouteRequest] = [:]
        var unavailable: [String: String] = [:]
        if isMixerEnabled && !suspended, let output = outputDevices.first(where: { $0.id == selectedOutputID }) {
            for source in sources where level(source.id).needsProcessing {
                // A live route can make its source temporarily report no default output.
                guard source.isActive || controlled.contains(source.id) else { continue }
                guard source.outputDeviceIDs.isEmpty || source.outputDeviceIDs.contains(output.id) || controlled.contains(source.id) else {
                    unavailable[source.id] = "This app is playing on another output device."; continue
                }
                requests[source.id] = RouteRequest(processIDs: source.processObjectIDs, outputID: output.id,
                                                   sampleRate: output.sampleRate, gain: level(source.id).gain,
                                                   sourceIsActive: source.isActive)
            }
        }
        controller.apply(requests, retry: retry) { [weak self] active, errors in
            guard let self, !self.stopped else { return }
            self.controlled = active
            self.routeErrors = unavailable.merging(errors) { _, new in new }
            self.isBusy = false
            self.publishApplications()
        }
    }
}
