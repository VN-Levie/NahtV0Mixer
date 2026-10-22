import AppKit
import AppIntents
import SwiftUI
import WidgetKit
import MixerWidgetCore

struct NahtV0MixerWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let isPreview: Bool
}

struct NahtV0MixerWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> NahtV0MixerWidgetEntry {
        NahtV0MixerWidgetEntry(date: Date(), snapshot: .preview, isPreview: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (NahtV0MixerWidgetEntry) -> Void) {
        if context.isPreview {
            completion(NahtV0MixerWidgetEntry(date: Date(), snapshot: .preview, isPreview: true))
        } else {
            completion(entryFromStore())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NahtV0MixerWidgetEntry>) -> Void) {
        let entry = context.isPreview
            ? NahtV0MixerWidgetEntry(date: Date(), snapshot: .preview, isPreview: true)
            : entryFromStore()
        let now = Date()
        var entries = [entry]

        if !context.isPreview, entry.snapshot.isRunning {
            let staleDate = entry.snapshot.updatedAt.addingTimeInterval(91)
            if staleDate > now {
                entries.append(NahtV0MixerWidgetEntry(date: staleDate, snapshot: entry.snapshot, isPreview: false))
            }
        }

        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(5 * 60))))
    }

    private func entryFromStore() -> NahtV0MixerWidgetEntry {
        let snapshot: WidgetSnapshot
        if let store = try? WidgetSharedStore.configured(), let stored = store.readSnapshot() {
            snapshot = stored
        } else {
            snapshot = .unavailable
        }
        return NahtV0MixerWidgetEntry(date: Date(), snapshot: snapshot, isPreview: false)
    }
}

private extension WidgetSnapshot {
    static var preview: WidgetSnapshot {
        WidgetSnapshot(
            sessionID: UUID(uuidString: "B7D2D63B-2C47-4DA1-BAE6-2F5EA9965AB7")!,
            updatedAt: Date().addingTimeInterval(-12),
            isRunning: true,
            mixerEnabled: true,
            systemVolume: 0.62,
            systemMuted: false,
            outputName: "MacBook Speakers",
            apps: [
                WidgetAppState(id: "preview.music", name: "Music", volume: 0.78, isMuted: false, isPlaying: true),
                WidgetAppState(id: "preview.browser", name: "Browser", volume: 0.34, isMuted: false, isPlaying: true),
                WidgetAppState(id: "preview.chat", name: "Chat", volume: 0.18, isMuted: true, isPlaying: true)
            ]
        )
    }
}

struct NahtV0MixerWidget: Widget {
    let kind = WidgetSharedStore.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NahtV0MixerWidgetProvider()) { entry in
            NahtV0MixerWidgetView(entry: entry)
        }
        .configurationDisplayName("NahtV0Mixer")
        .description("Control system and per-app audio volume.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

@main
struct NahtV0MixerWidgetBundle: WidgetBundle {
    var body: some Widget {
        NahtV0MixerWidget()
    }
}

struct NahtV0MixerWidgetView: View {
    let entry: NahtV0MixerWidgetEntry

    var body: some View {
        Group {
            switch family {
            case .systemLarge:
                LargeMixerView(entry: entry)
            default:
                MediumMixerView(entry: entry)
            }
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
    }

    @Environment(\.widgetFamily) private var family
}

struct MediumMixerView: View {
    let entry: NahtV0MixerWidgetEntry

    private var snapshot: WidgetSnapshot { entry.snapshot }
    private var playingApps: [WidgetAppState] { snapshot.apps.filter(\.isPlaying).prefix(2).map { $0 } }
    private var controlsEnabled: Bool {
        !entry.isPreview && snapshot.isRunning && !snapshot.isBusy
    }
    private var mixerControlsEnabled: Bool {
        controlsEnabled && snapshot.mixerEnabled
    }

    var body: some View {
        GeometryReader { proxy in
            let rowHeight = max(28, min(40, (proxy.size.height - 28) / 3))
            VStack(alignment: .leading, spacing: 0) {
                if !snapshot.isRunning {
                    OfflineRow().frame(height: rowHeight)
                    Divider().padding(.leading, 31)
                    EmptyMixerRow().frame(height: rowHeight)
                    Divider().padding(.leading, 31)
                    EmptyMixerRow().frame(height: rowHeight)
                } else {
                    MixerSystemRow(snapshot: snapshot, enabled: controlsEnabled).frame(height: rowHeight)
                    Divider().padding(.leading, 31)
                    ForEach(0..<2, id: \.self) { index in
                        VStack(spacing: 0) {
                            if index < playingApps.count {
                                MixerAppRow(app: playingApps[index], enabled: mixerControlsEnabled)
                            } else {
                                EmptyMixerRow()
                            }
                        }
                        .frame(height: rowHeight)
                        if index == 0 { Divider().padding(.leading, 31) }
                    }
                }
                footer.frame(height: 24)
            }
        }
        .padding(10)
    }

    private var footer: some View {
        MixerWidgetFooter(entry: entry, enabled: controlsEnabled)
    }

}

struct LargeMixerView: View {
    let entry: NahtV0MixerWidgetEntry

    private var snapshot: WidgetSnapshot { entry.snapshot }
    private var playingApps: [WidgetAppState] { snapshot.apps.filter(\.isPlaying).prefix(4).map { $0 } }
    private var controlsEnabled: Bool {
        !entry.isPreview && snapshot.isRunning && !snapshot.isBusy
    }
    private var mixerControlsEnabled: Bool { controlsEnabled && snapshot.mixerEnabled }

    var body: some View {
        GeometryReader { proxy in
            let rowHeight = max(36, min(54, (proxy.size.height - 28) / 5))
            VStack(alignment: .leading, spacing: 0) {
                if !snapshot.isRunning {
                    OfflineRow().frame(height: rowHeight)
                    Divider().padding(.leading, 31)
                    ForEach(0..<4, id: \.self) { index in
                        EmptyMixerRow().frame(height: rowHeight)
                        if index < 3 { Divider().padding(.leading, 31) }
                    }
                } else {
                    MixerSystemRow(snapshot: snapshot, enabled: controlsEnabled).frame(height: rowHeight)
                    Divider().padding(.leading, 31)
                    ForEach(0..<4, id: \.self) { index in
                        VStack(spacing: 0) {
                            if index < playingApps.count {
                                MixerAppRow(app: playingApps[index], enabled: mixerControlsEnabled)
                            } else {
                                EmptyMixerRow()
                            }
                        }
                        .frame(height: rowHeight)
                        if index < 3 { Divider().padding(.leading, 31) }
                    }
                }
                MixerWidgetFooter(entry: entry, enabled: controlsEnabled)
                    .frame(height: 24)
            }
        }
        .padding(13)
    }
}

/// Only archive-safe SwiftUI labels and plain intent buttons. Platform-backed
/// switch and borderless control styles cannot be rendered by the widget host.
struct MixerWidgetFooter: View {
    let entry: NahtV0MixerWidgetEntry
    let enabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button(intent: MixerWidgetIntent(action: .toggleMixer, enabled: !entry.snapshot.mixerEnabled)) {
                Label(entry.snapshot.mixerEnabled ? "Mixer On" : "Mixer Off",
                      systemImage: entry.snapshot.mixerEnabled ? "power.circle.fill" : "power.circle")
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .accessibilityLabel(entry.snapshot.mixerEnabled ? "Turn mixer off" : "Turn mixer on")
            .invalidatableContent()
            Spacer()
            if entry.snapshot.isRunning && !entry.snapshot.isFresh(at: entry.date) {
                Button(intent: MixerWidgetIntent(action: .refresh)) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .help("Update playback information")
            }
            Link(destination: URL(string: "nahtv0mixer://show")!) {
                Image(systemName: "arrow.up.forward.app")
            }
            .accessibilityLabel("Open NahtV0Mixer")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

struct MixerSystemRow: View {
    let snapshot: WidgetSnapshot
    let enabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill")
                .frame(width: 23)
            Text(snapshot.outputName.isEmpty ? "System" : snapshot.outputName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let volume = snapshot.systemVolume {
                Button(intent: MixerWidgetIntent(action: .setSystemVolume, value: nextPreset(volume))) {
                    HStack(spacing: 2) {
                        Text(volume, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .frame(width: 56, alignment: .trailing)
                .help("Set volume to \(Int(nextPreset(volume) * 100))%")
                .accessibilityLabel("System volume \(Int(volume * 100))%, next preset \(Int(nextPreset(volume) * 100))%")
                .invalidatableContent()
            } else { Text("—").foregroundStyle(.secondary) }
            Button(intent: MixerWidgetIntent(action: .toggleSystemMute, enabled: !(snapshot.systemMuted ?? false))) {
                Image(systemName: snapshot.systemMuted == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(.plain)
            .disabled(!enabled || snapshot.systemMuted == nil)
            .accessibilityLabel(snapshot.systemMuted == true ? "Unmute system" : "Mute system")
            .frame(width: 22)
        }
        .font(.callout)
    }
}

struct MixerAppRow: View {
    let app: WidgetAppState
    let enabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(app: app)
                .frame(width: 23, height: 23)
            Text(app.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button(intent: MixerWidgetIntent(action: .setAppVolume, applicationID: app.id, value: nextPreset(app.volume))) {
                HStack(spacing: 2) {
                    Text(app.volume, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .frame(width: 56, alignment: .trailing)
            .help("Set volume to \(Int(nextPreset(app.volume) * 100))%")
            .accessibilityLabel("\(app.name) volume \(Int(app.volume * 100))%, next preset \(Int(nextPreset(app.volume) * 100))%")
            .invalidatableContent()
            Button(intent: MixerWidgetIntent(action: .toggleAppMute, applicationID: app.id, enabled: !app.isMuted)) {
                Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .accessibilityLabel(app.isMuted ? "Unmute \(app.name)" : "Mute \(app.name)")
            .frame(width: 22)
        }
        .font(.callout)
    }
}

struct AppIcon: View {
    let app: WidgetAppState

    var body: some View {
        if let data = app.iconPNG, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: app.isMuted ? "speaker.slash" : "app")
                .foregroundStyle(.secondary)
        }
    }
}

struct OfflineRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2")
                .frame(width: 23)
            VStack(alignment: .leading, spacing: 2) {
                Text("NahtV0Mixer offline")
                Text("Open the app to reconnect")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Link(destination: URL(string: "nahtv0mixer://show")!) {
                Image(systemName: "arrow.up.forward.app")
            }
            .accessibilityLabel("Open NahtV0Mixer")
        }
        .font(.callout)
    }
}

struct EmptyMixerRow: View {
    var body: some View {
        Color.clear
            .accessibilityHidden(true)
    }
}

private func nextPreset(_ value: Double) -> Double {
    [0.25, 0.50, 0.75, 1.0].first(where: { $0 > value + 0.01 }) ?? 0.25
}
