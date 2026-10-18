import AppKit
import Carbon
import Combine
import SwiftUI

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
    private var panel: NSPopover?
    private var loginItems: LoginItems?
    private var observations: Set<AnyCancellable> = []
    private var launchFailure: Error?
    private var backgroundLaunch = CommandLine.arguments.contains("--background")
    private var ready = false
    private var ownsMixer = false

    func applicationWillFinishLaunching(_ notification: Notification) {
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
        let loginItems = LoginItems()
        self.loginItems = loginItems
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 400, height: 610)
        popover.contentViewController = NSHostingController(rootView: MixerView(
            store: .shared, preferences: .shared, loginItems: loginItems,
            quit: { NSApp.terminate(nil) }))
        panel = popover
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "NahtV0Mixer")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(toggleMixer(_:))
            button.toolTip = "NahtV0Mixer"
            button.setAccessibilityIdentifier("NahtV0MixerStatusItem")
            button.setAccessibilityLabel("NahtV0Mixer")
        }
        statusItem = item
        installApplicationMenu()
        MixerStore.shared.start()
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

    @objc private func toggleMixer(_ sender: Any?) {
        if panel?.isShown == true { panel?.performClose(sender) }
        else { showMixer() }
    }

    private func showMixer() {
        guard ready, ownsMixer, let panel, let button = statusItem?.button else { return }
        loginItems?.refresh()
        NSApp.activate(ignoringOtherApps: true)
        if !panel.isShown { panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
        panel.contentViewController?.view.window?.makeKey()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if ready { showMixer() }
        else { backgroundLaunch = false }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        if ownsMixer { MixerStore.shared.shutdown() }
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
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
