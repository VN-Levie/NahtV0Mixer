import AppKit
import Carbon
import Combine
import MixerWidgetCore

enum MixerLaunch {
    static func isBackground(event: NSAppleEventDescriptor?, arguments: [String]) -> Bool {
        if arguments.contains("--background") { return true }
        guard let event, event.eventClass == kCoreEventClass, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

@main
@MainActor
enum NahtV0MixerApp {
    static func main() {
        if MixerDiagnostics.runIfRequested() { return }
        let application = NSApplication.shared
        let controller = MixerAppDelegate()
        application.delegate = controller
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(controller) { application.run() }
    }
}

@MainActor
final class MixerAppDelegate: NSObject, NSApplicationDelegate {
    private let instance = SingleInstance()
    private var statusItem: NSStatusItem?
    private var mixerMenu: MixerMenuController?
    private var widgetBridge: MixerWidgetBridge?
    private var presentationQueued = false
    private var observations: Set<AnyCancellable> = []
    private var launchFailure: Error?
    private var backgroundLaunch = CommandLine.arguments.contains("--background")
    private var ready = false
    private var ownsMixer = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        MixerPreferenceMigration.migrateIfNeeded()
        do { ownsMixer = try instance.claim() }
        catch { launchFailure = error }
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(openApplication(_:reply:)),
            forEventClass: kCoreEventClass, andEventID: kAEOpenApplication)
    }

    @objc private func openApplication(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        backgroundLaunch = MixerLaunch.isBackground(event: event, arguments: CommandLine.arguments)
        if ready && !backgroundLaunch { showMixer() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Give the initial open Apple event a turn to identify login launches.
        DispatchQueue.main.async { [weak self] in self?.completeLaunch() }
    }

    private func completeLaunch() {
        guard !ready else { return }
        if let launchFailure {
            showLaunchError(launchFailure.localizedDescription)
            NSApp.terminate(nil)
            return
        }
        guard ownsMixer else {
            if backgroundLaunch { NSApp.terminate(nil); return }
            instance.presentOwner { [weak self] accepted in
                if !accepted {
                    self?.showLaunchError(AppPreferences.shared.text("Could not show the running mixer. Open it from its menu bar icon."))
                }
                NSApp.terminate(nil)
            }
            return
        }
        ready = true
        NSApp.appearance = AppPreferences.shared.theme.appearance
        AppPreferences.shared.$theme.sink { theme in NSApp.appearance = theme.appearance }.store(in: &observations)
        let mixerMenu = MixerMenuController(store: MixerStore.shared, preferences: .shared,
                                            loginItems: LoginItems(), quit: { NSApp.terminate(nil) })
        self.mixerMenu = mixerMenu
        let item = NSStatusBar.system.statusItem(withLength: 32)
        item.menu = mixerMenu.menu
        if let button = item.button {
            let image = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png").flatMap(NSImage.init(contentsOf:))
            if let image { image.size = NSSize(width: image.size.width / 2, height: image.size.height / 2) }
            button.image = image ?? NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "NahtV0Mixer")
            button.image?.isTemplate = true
            button.toolTip = "NahtV0Mixer"
            button.setAccessibilityIdentifier("NahtV0MixerStatusItem")
            button.setAccessibilityLabel("NahtV0Mixer")
        }
        statusItem = item
        installApplicationMenu()
        MixerStore.shared.start()
        if let storage = try? WidgetSharedStore.configured() {
            let bridge = MixerWidgetBridge(source: MixerStore.shared, storage: storage)
            widgetBridge = bridge
            bridge.start()
        }
        instance.onPresent = { [weak self] in self?.showMixer() }
        if !backgroundLaunch { showMixer() }
    }

    private func installApplicationMenu() {
        let root = NSMenu()
        let applicationItem = NSMenuItem()
        let menu = NSMenu()
        let quit = NSMenuItem(title: "Quit NahtV0Mixer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        applicationItem.submenu = menu
        root.addItem(applicationItem)
        NSApp.mainMenu = root
    }

    private func showMixer() {
        guard ready, ownsMixer, !presentationQueued, mixerMenu?.isTracking == false else { return }
        presentationQueued = true
        // Native menu tracking is synchronous. Let reopen/instance requests return
        // and acknowledge first, rather than blocking them until the menu closes.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.presentationQueued = false
            guard self.ready, self.ownsMixer, self.mixerMenu?.isTracking == false else { return }
            guard let button = self.statusItem?.button, let menu = self.mixerMenu?.menu else { return }
            let anchor = NSPoint(x: button.bounds.minX,
                                 y: button.isFlipped ? button.bounds.maxY : button.bounds.minY)
            menu.popUp(positioning: nil, at: anchor, in: button)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if ready { showMixer() }
        else { backgroundLaunch = false }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "nahtv0mixer" && $0.host == "show" }) {
            if ready { showMixer() }
            else { backgroundLaunch = false }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        widgetBridge?.stop()
        widgetBridge = nil
        if ownsMixer { MixerStore.shared.shutdown() }
        mixerMenu?.menu.cancelTracking()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        mixerMenu = nil
        observations.removeAll()
        NSAppleEventManager.shared().removeEventHandler(forEventClass: kCoreEventClass, andEventID: kAEOpenApplication)
        instance.release()
    }

    private func showLaunchError(_ detail: String) {
        let alert = NSAlert()
        alert.messageText = AppPreferences.shared.text("Could not start NahtV0Mixer")
        alert.informativeText = detail
        alert.addButton(withTitle: AppPreferences.shared.text("OK"))
        alert.runModal()
    }
}
