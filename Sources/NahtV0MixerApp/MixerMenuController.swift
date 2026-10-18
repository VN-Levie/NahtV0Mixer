import AppKit
import AudioRouting
import Combine

/// The menu reads state and sends explicit user actions; opening it never starts audio routing.
@MainActor
protocol MixerMenuSource: AnyObject {
    var objectWillChange: ObservableObjectPublisher { get }
    var applications: [MixerApplication] { get }
    var outputDevices: [AudioOutputDevice] { get }
    var selectedOutputID: UInt32 { get }
    var systemVolume: Double? { get }
    var systemMuted: Bool? { get }
    var isMixerEnabled: Bool { get }
    var isBusy: Bool { get }
    var lastError: String? { get }
    func setMixerEnabled(_ enabled: Bool)
    func setSystemVolume(_ value: Double)
    func setSystemMuted(_ value: Bool)
    func selectOutput(_ id: UInt32)
    func setVolume(_ value: Double, for id: String)
    func setMuted(_ muted: Bool, for id: String)
    func resetApplication(_ id: String)
}

extension MixerStore: MixerMenuSource {}

@MainActor
final class MixerMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu(title: "NahtV0Mixer")
    private(set) var isTracking = false
    private let store: any MixerMenuSource
    private let preferences: AppPreferences
    private let loginItems: LoginItems
    private let quit: () -> Void
    private var observations: Set<AnyCancellable> = []
    private var valueUpdates: [() -> Void] = []
    private var updateQueued = false

    init(store: any MixerMenuSource, preferences: AppPreferences, loginItems: LoginItems,
         quit: @escaping () -> Void) {
        self.store = store
        self.preferences = preferences
        self.loginItems = loginItems
        self.quit = quit
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        store.objectWillChange.sink { [weak self] in self?.queueValueUpdate() }.store(in: &observations)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu, !isTracking else { return }
        loginItems.refresh()
        rebuild()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu { isTracking = true }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === self.menu { isTracking = false }
    }

    private func queueValueUpdate() {
        guard !updateQueued else { return }
        updateQueued = true
        // @Published emits before the value changes. Common modes also run during menu tracking.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateQueued = false
                self.refreshValues()
            }
        }
    }

    func refreshValues() { valueUpdates.forEach { $0() } }

    private func rebuild() {
        valueUpdates.removeAll()
        menu.removeAllItems()
        menu.appearance = preferences.theme.appearance

        let outputName = store.outputDevices.first { $0.id == store.selectedOutputID }?.name
        let outputTitle = outputName.map { "\(text("Output")): \($0)" } ?? text("Output")
        let outputs = submenu(outputTitle, in: menu)
        if store.outputDevices.isEmpty { status(text("No output device"), in: outputs) }
        for device in store.outputDevices {
            action(device.name, in: outputs, enabled: { [store] in !store.isBusy },
                   checked: { [store] in store.selectedOutputID == device.id }) { [store] in
                guard !store.isBusy else { return }
                store.selectOutput(device.id)
            }
        }
        let system = volume(text("System volume"), image: NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil),
            onMute: { [store] in
                guard !store.isBusy, let muted = store.systemMuted else { return }
                store.setSystemMuted(!muted)
            }, onChange: { [store] value in
                guard !store.isBusy, store.systemVolume != nil else { return }
                store.setSystemVolume(value)
            })
        valueUpdates.append { [store] in
            system.update(value: store.systemVolume, enabled: !store.isBusy, muted: store.systemMuted,
                          muteEnabled: !store.isBusy, resetEnabled: false)
        }

        menu.addItem(.separator())
        action(text("Per-app mixer"), in: menu, enabled: { [store] in !store.isBusy },
               checked: { [store] in store.isMixerEnabled }) { [store] in
            guard !store.isBusy else { return }
            store.setMixerEnabled(!store.isMixerEnabled)
        }
        if !store.isMixerEnabled { status(text("Requires system audio access."), in: menu) }
        if let error = store.lastError { status(text(error), in: menu) }
        if store.applications.isEmpty { status(text("No apps are playing audio"), in: menu) }
        for application in store.applications { addApplication(application) }

        menu.addItem(.separator())
        addSettings()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        status("NahtV0Mixer \(version)", in: menu)
        action(text("Quit"), in: menu, keyEquivalent: "q", handler: quit)
        refreshValues()
    }

    private func addApplication(_ application: MixerApplication) {
        let id = application.id
        let available: () -> Bool = { [store] in
            store.isMixerEnabled && !store.isBusy && store.applications.contains { $0.id == id }
        }
        let icon = application.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
        let row = volume(application.name, image: icon,
            onMute: { [store] in
                guard available(), let current = store.applications.first(where: { $0.id == id }) else { return }
                store.setMuted(!current.isMuted, for: id)
            }, onReset: { [store] in
                guard !store.isBusy, store.applications.contains(where: { $0.id == id }) else { return }
                store.resetApplication(id)
            }, onChange: { [store] value in
                guard available() else { return }
                store.setVolume(value, for: id)
            })
        valueUpdates.append { [store] in
            let current = store.applications.first { $0.id == id }
            row.update(value: current?.volume, enabled: available(), muted: current?.isMuted,
                       muteEnabled: available(), resetEnabled: !store.isBusy && current != nil)
        }
        if let error = application.error { status(text(error), in: menu) }
    }

    private func addSettings() {
        let settings = submenu(text("Settings"), in: menu)
        let languages = submenu(text("Language"), in: settings)
        for (language, title) in [(MixerLanguage.system, text("System")), (.english, "English"), (.vietnamese, "Tiếng Việt")] {
            action(title, in: languages, checked: { [preferences] in preferences.language == language }) { [preferences] in
                preferences.language = language
            }
        }
        let themes = submenu(text("Appearance"), in: settings)
        for (theme, title) in [(MixerTheme.system, text("System")), (.light, text("Light")), (.dark, text("Dark"))] {
            action(title, in: themes, checked: { [preferences] in preferences.theme == theme }) { [preferences] in
                preferences.theme = theme
            }
        }
        settings.addItem(.separator())
        action(text("Launch at login"), in: settings,
               enabled: { [loginItems] in loginItems.state != .unavailable },
               checked: { [loginItems] in loginItems.state.isRequested }) { [loginItems] in
            loginItems.setEnabled(!loginItems.state.isRequested)
        }
        if loginItems.state == .needsApproval {
            status(text("Waiting for approval in System Settings."), in: settings)
            action(text("Open Login Items"), in: settings) { [loginItems] in loginItems.openSystemSettings() }
        } else if loginItems.state == .unavailable {
            status(text("Launch at login is unavailable. Move the app to Applications first."), in: settings)
        }
        if let error = loginItems.error { status(text(error), in: settings) }
    }

    private func text(_ english: String) -> String { preferences.text(english) }

    private func submenu(_ title: String, in parent: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let child = NSMenu(title: title)
        child.autoenablesItems = false
        item.submenu = child
        parent.addItem(item)
        return child
    }

    private func status(_ title: String, in menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func action(_ title: String, in menu: NSMenu, keyEquivalent: String = "",
                        enabled: @escaping () -> Bool = { true }, checked: @escaping () -> Bool = { false },
                        handler: @escaping () -> Void) {
        let item = MixerMenuAction(title: title, keyEquivalent: keyEquivalent, handler: handler)
        menu.addItem(item)
        valueUpdates.append {
            item.isEnabled = enabled()
            item.state = checked() ? .on : .off
        }
    }

    private func volume(_ title: String, image: NSImage?, onMute: @escaping () -> Void,
                        onReset: (() -> Void)? = nil, onChange: @escaping (Double) -> Void) -> VolumeMenuView {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let view = VolumeMenuView(title: title, image: image, muteLabel: text("Mute"), unmuteLabel: text("Unmute"),
                                  resetLabel: text("Reset volume"),
                                  onMute: onMute, onReset: onReset, onChange: onChange)
        item.view = view
        menu.addItem(item)
        return view
    }
}

@MainActor
private final class MixerMenuAction: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func invoke() {
        guard isEnabled else { return }
        handler()
    }
}
