import AppKit
import AudioRouting
import SwiftUI

struct MixerView: View {
    @ObservedObject var store: MixerStore
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var loginItems: LoginItems
    let quit: () -> Void
    @State private var showingSettings = false
    @State private var applicationListHeight: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if showingSettings { settings }
            else { mixer }
            Divider()
            HStack {
                Text(showingSettings ? version : "NahtV0Mixer")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(preferences.text("Quit"), action: quit)
                    .buttonStyle(.borderless)
                    .keyboardShortcut("q", modifiers: .command)
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(PopoverMaterial())
        .preferredColorScheme(preferences.theme.colorScheme)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItems.refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if showingSettings {
                Button { showingSettings = false } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .help(preferences.text("Back"))
                    .accessibilityLabel(preferences.text("Back"))
            }
            Text(preferences.text(showingSettings ? "Settings" : "Sound")).font(.headline)
            Spacer()
            if !showingSettings {
                if store.isBusy { ProgressView().controlSize(.small) }
                Button { showingSettings = true; loginItems.refresh() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help(preferences.text("Settings"))
                    .accessibilityLabel(preferences.text("Settings"))
            }
        }
    }

    private var mixer: some View {
        VStack(alignment: .leading, spacing: 12) {
            outputControls
            Divider()
            Toggle(preferences.text("Per-app mixer"), isOn: Binding(get: { store.isMixerEnabled }, set: store.setMixerEnabled))
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(store.isBusy)
            if !store.isMixerEnabled {
                Text(preferences.text("Requires system audio access."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = store.lastError { errorMessage(error) }
            if store.applications.isEmpty {
                Label(preferences.text("No apps are playing audio"), systemImage: "waveform")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(store.applications.enumerated()), id: \.element.id) { index, application in
                            if index > 0 { Divider().padding(.vertical, 10) }
                            applicationRow(application)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: ApplicationListHeight.self, value: geometry.size.height)
                    })
                }
                .frame(height: min(280, max(1, applicationListHeight)))
                .onPreferenceChange(ApplicationListHeight.self) { height in
                    let measured = ceil(height)
                    if abs(measured - applicationListHeight) > 0.5 { applicationListHeight = measured }
                }
            }
        }
    }

    private var outputControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(preferences.text("Output"), selection: Binding(get: { store.selectedOutputID }, set: store.selectOutput)) {
                if store.outputDevices.isEmpty { Text(preferences.text("No output device")).tag(UInt32(0)) }
                ForEach(store.outputDevices) { device in Text(device.name).tag(device.id) }
            }
            .pickerStyle(.menu)
            .disabled(store.outputDevices.isEmpty || store.isBusy)
            HStack(spacing: 8) {
                muteButton(muted: store.systemMuted ?? false, label: preferences.text("System volume"),
                           action: { store.setSystemMuted(!(store.systemMuted ?? false)) })
                    .disabled(store.systemMuted == nil || store.isBusy)
                    .help(preferences.text(store.systemMuted == nil ? "Mute unavailable on this device" : (store.systemMuted == true ? "Unmute" : "Mute")))
                Slider(value: Binding(get: { store.systemVolume ?? 0 }, set: store.setSystemVolume), in: 0...1)
                    .disabled(store.systemVolume == nil || store.isBusy)
                    .accessibilityLabel(preferences.text("System volume"))
                    .accessibilityValue(store.systemVolume.map(percent) ?? preferences.text("Volume unavailable on this device"))
                Text(store.systemVolume.map(percent) ?? "—")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            if store.systemVolume == nil {
                Text(preferences.text("Volume unavailable on this device")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func applicationRow(_ application: MixerApplication) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                applicationIcon(application).frame(width: 20, height: 20)
                Text(application.name).font(.callout.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                if !application.isActive {
                    Text(preferences.text("Idle")).font(.caption).foregroundStyle(.secondary)
                }
                Button { store.resetApplication(application.id) } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .help(preferences.text("Reset volume"))
                    .accessibilityLabel("\(preferences.text("Reset volume")): \(application.name)")
                    .disabled(store.isBusy)
            }
            HStack(spacing: 8) {
                muteButton(muted: application.isMuted, label: application.name,
                           action: { store.setMuted(!application.isMuted, for: application.id) })
                Slider(value: Binding(get: { application.volume }, set: { store.setVolume($0, for: application.id) }), in: 0...1)
                    .accessibilityLabel(application.name)
                    .accessibilityValue(percent(application.volume))
                Text(percent(application.volume)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            .disabled(!store.isMixerEnabled || store.isBusy)
            if let error = application.error { errorMessage(error) }
        }
    }

    @ViewBuilder private func applicationIcon(_ application: MixerApplication) -> some View {
        if let url = application.bundleURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
        } else {
            Image(systemName: "app.fill").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }

    private func muteButton(muted: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 20)
        }
        .buttonStyle(.borderless)
        .help(preferences.text(muted ? "Unmute" : "Mute"))
        .accessibilityLabel("\(preferences.text(muted ? "Unmute" : "Mute")): \(label)")
    }

    private func errorMessage(_ message: String) -> some View {
        Label(preferences.text(message), systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                .toggleStyle(.switch).controlSize(.small)
            if loginItems.state == .needsApproval {
                Text(preferences.text("Waiting for approval in System Settings."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(preferences.text("Open Login Items")) { loginItems.openSystemSettings() }
            } else if loginItems.state == .unavailable {
                Text(preferences.text("Launch at login is unavailable. Move the app to Applications first."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = loginItems.error { errorMessage(error) }
        }
    }

    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        return "\(preferences.text("Version")) \(version)"
    }
    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}

private struct ApplicationListHeight: PreferenceKey {
    static var defaultValue: CGFloat = 1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Use AppKit's semantic popover material, including system transparency and
/// accessibility behavior. The popover supplies its own corners and shadow.
private struct PopoverMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
