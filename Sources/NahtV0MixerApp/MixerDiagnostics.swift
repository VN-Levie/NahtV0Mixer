import AppKit
import AudioRouting
import MixerWidgetCore
import ServiceManagement

@MainActor enum MixerDiagnostics {
    static func runIfRequested() -> Bool {
        if CommandLine.arguments.contains("--widget-status") {
            do {
                let storage = try WidgetSharedStore.configured()
                let snapshot = storage.readSnapshot() ?? .unavailable
                let report: [String: Any] = [
                    "running": snapshot.isRunning, "fresh": snapshot.isFresh(),
                    "mixerEnabled": snapshot.mixerEnabled,
                    "launchAtLoginStatus": SMAppService.mainApp.status.rawValue,
                    "systemVolume": snapshot.systemVolume as Any? ?? NSNull(),
                    "systemMuted": snapshot.systemMuted as Any? ?? NSNull(),
                    "playingApps": snapshot.apps.filter(\.isPlaying).map(\.name),
                    "captureStarted": false
                ]
                let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            } catch {
                fputs("Widget shared state is unavailable: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return true
        }
        if CommandLine.arguments.contains("--audio-check") {
            _ = NSApplication.shared
            exit(AudioCheck.run())
        }
        guard CommandLine.arguments.contains("--diagnose") else { return false }
        _ = NSApplication.shared
        do {
            let outputs = try AudioCatalog.outputDevices()
            let apps = try AudioCatalog.applications()
            let payload: [String: Any] = [
                "defaultOutputID": try AudioCatalog.defaultOutputID(),
                "outputs": outputs.map { ["id": $0.id, "name": $0.name, "sampleRate": $0.sampleRate] as [String: Any] },
                "applications": apps.map { ["name": $0.name, "id": $0.id, "active": $0.isActive,
                                              "processCount": $0.processObjectIDs.count] as [String: Any] },
                "captureStarted": false
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch { fputs("Audio discovery failed: \(error.localizedDescription)\n", stderr); exit(1) }
        return true
    }
}
