import AppKit
import AudioRouting
import SwiftUI

struct MixerView: View {
    @ObservedObject var store: MixerStore
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var loginItems: LoginItems
    let quit: () -> Void
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showingSettings { settings }
            else { mixer }
            Divider()
            HStack {
                Text(showingSettings ? version : preferences.text("Close this panel to keep the mixer running."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(preferences.text("Quit"), action: quit)
                    .keyboardShortcut("q", modifiers: .command)
            }
            .padding(14)
        }
        .frame(width: 400, height: 610)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(preferences.theme.colorScheme)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItems.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3").font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("NahtV0Mixer").font(.headline)
                Text(preferences.text(showingSettings ? "Settings" : "Mixer"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !showingSettings {
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help(preferences.text("Refresh"))
                    .accessibilityLabel(preferences.text("Refresh"))
                    .disabled(store.isBusy)
            }
            Button { showingSettings.toggle(); loginItems.refresh() } label: {
                Image(systemName: showingSettings ? "chevron.left" : "gearshape")
            }
            .buttonStyle(.borderless)
            .help(preferences.text(showingSettings ? "Back" : "Settings"))
            .accessibilityLabel(preferences.text(showingSettings ? "Back" : "Settings"))
        }
        .padding(16)
    }

    private var mixer: some View {
        VStack(alignment: .leading, spacing: 12) {
            outputControls
            Divider()
            Toggle(isOn: Binding(get: { store.isMixerEnabled }, set: store.setMixerEnabled)) {
                Text(preferences.text("Per-app mixer")).fontWeight(.medium)
            }
            .toggleStyle(.switch)
            .disabled(store.isBusy)
            if !store.isMixerEnabled {
                Text(preferences.text("Enable to adjust each app. macOS may request system audio recording access."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = store.lastError { errorMessage(error) }
            HStack {
                Text(preferences.text("Applications")).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if store.isBusy { ProgressView().controlSize(.small).scaleEffect(0.75) }
            }
            ScrollView {
                if store.applications.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform").font(.title2)
                        Text(preferences.text("No apps are playing audio")).fontWeight(.medium)
                        Text(preferences.text("Play audio in an app to see it here.")).font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(store.applications) { application in
                            applicationRow(application)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var outputControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(preferences.text("Output"), selection: Binding(get: { store.selectedOutputID }, set: store.selectOutput)) {
                if store.outputDevices.isEmpty {
                    Text(preferences.text("No output device")).tag(UInt32(0))
                }
                ForEach(store.outputDevices, id: \.id) { device in
                    Text(device.name).tag(device.id)
                }
            }
            .disabled(store.outputDevices.isEmpty || store.isBusy)
            HStack(spacing: 10) {
                muteButton(muted: store.systemMuted ?? false,
                           label: preferences.text("System volume"),
                           action: { store.setSystemMuted(!(store.systemMuted ?? false)) })
                    .disabled(store.systemMuted == nil || store.isBusy)
                    .help(preferences.text(store.systemMuted == nil ? "Mute unavailable on this device" : (store.systemMuted == true ? "Unmute" : "Mute")))
                Slider(value: Binding(get: { store.systemVolume ?? 0 }, set: store.setSystemVolume), in: 0...1)
                    .disabled(store.systemVolume == nil || store.isBusy)
                    .accessibilityLabel(preferences.text("System volume"))
                    .accessibilityValue(store.systemVolume.map(percent) ?? preferences.text("Volume unavailable on this device"))
                Text(store.systemVolume.map(percent) ?? "—")
                    .font(.callout.monospacedDigit()).frame(width: 44, alignment: .trailing)
            }
            if store.systemVolume == nil {
                Text(preferences.text("Volume unavailable on this device")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func applicationRow(_ application: MixerApplication) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                applicationIcon(application).frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(application.name).font(.callout.weight(.medium)).lineLimit(1)
                    HStack(spacing: 4) {
                        Circle().fill(application.isActive ? Color.green : Color.secondary.opacity(0.45)).frame(width: 5, height: 5)
                        Text(preferences.text(application.isActive ? "Playing" : "Idle"))
                        if application.isProcessing {
                            Text("·")
                            Text(preferences.text("Controlled"))
                        }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button { store.resetApplication(application.id) } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .help(preferences.text("Reset volume"))
                    .accessibilityLabel("\(preferences.text("Reset volume")): \(application.name)")
                    .disabled(store.isBusy)
            }
            HStack(spacing: 10) {
                muteButton(muted: application.isMuted, label: application.name,
                           action: { store.setMuted(!application.isMuted, for: application.id) })
                Slider(value: Binding(get: { application.volume }, set: { store.setVolume($0, for: application.id) }), in: 0...1)
                    .accessibilityLabel(application.name)
                    .accessibilityValue(percent(application.volume))
                Text(percent(application.volume)).font(.callout.monospacedDigit()).frame(width: 44, alignment: .trailing)
            }
            .disabled(!store.isMixerEnabled || store.isBusy)
            if let error = application.error { errorMessage(error) }
        }
        .padding(11)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func applicationIcon(_ application: MixerApplication) -> some View {
        if let url = application.bundleURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
        } else {
            Image(systemName: "app.fill").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }

    private func muteButton(muted: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .frame(width: 20)
                .foregroundStyle(muted ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.borderless)
        .help(preferences.text(muted ? "Unmute" : "Mute"))
        .accessibilityLabel("\(preferences.text(muted ? "Unmute" : "Mute")): \(label)")
    }

    private func errorMessage(_ message: String) -> some View {
        Label(preferences.text(message), systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker(preferences.text("Language"), selection: $preferences.language) {
                Text(preferences.text("System")).tag(MixerLanguage.system)
                Text("English").tag(MixerLanguage.english)
                Text("Tiếng Việt").tag(MixerLanguage.vietnamese)
            }
            Picker(preferences.text("Appearance"), selection: $preferences.theme) {
                Text(preferences.text("System")).tag(MixerTheme.system)
                Text(preferences.text("Light")).tag(MixerTheme.light)
                Text(preferences.text("Dark")).tag(MixerTheme.dark)
            }
            Divider()
            Toggle(preferences.text("Launch at login"), isOn: Binding(
                get: { loginItems.state.isRequested }, set: loginItems.setEnabled))
            if loginItems.state == .needsApproval {
                Text(preferences.text("Waiting for approval in System Settings."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(preferences.text("Open Login Items")) { loginItems.openSystemSettings() }
            } else if loginItems.state == .unavailable {
                Text(preferences.text("Launch at login is unavailable. Move the app to Applications first."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = loginItems.error { errorMessage(error) }
            Spacer()
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        return "\(preferences.text("Version")) \(version)"
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}
