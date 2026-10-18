import Combine
import Foundation
import ServiceManagement

enum LoginItemState: Equatable {
    case off, on, needsApproval, unavailable
    var isRequested: Bool { self == .on || self == .needsApproval }
}

@MainActor
protocol LoginItemBackend {
    var state: LoginItemState { get }
    func changeRegistration(to enabled: Bool) throws
}

@MainActor
private struct MainApplicationLoginItem: LoginItemBackend {
    var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .off
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }
    func changeRegistration(to enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }
}

@MainActor
final class LoginItems: ObservableObject {
    @Published private(set) var state: LoginItemState
    @Published private(set) var error: String?
    private let backend: any LoginItemBackend

    init(backend: (any LoginItemBackend)? = nil) {
        let selected = backend ?? MainApplicationLoginItem()
        self.backend = selected
        state = selected.state
        // Merely launching or opening settings never registers a login item.
    }

    func refresh() { state = backend.state }

    func setEnabled(_ enabled: Bool) {
        refresh()
        error = nil
        guard enabled != state.isRequested else { return }
        do { try backend.changeRegistration(to: enabled) }
        catch { self.error = error.localizedDescription }
        // Report what Service Management actually accepted, including approval
        // pending or a failure that left the previous registration in place.
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
