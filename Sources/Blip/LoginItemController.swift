import Combine
import ServiceManagement

@MainActor
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

/// macOS owns this preference. Never persist a separate flag or re-register at launch:
/// that would override changes the user makes in System Settings.
@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?

    private let service: any LoginItemService
    private let openSettings: () -> Void

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }

    init(
        service: any LoginItemService = SMAppService.mainApp,
        openSettings: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() }
    ) {
        self.service = service
        self.openSettings = openSettings
        status = service.status
    }

    func refresh() {
        status = service.status
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        refresh()

        // A denied registration needs approval, not another registration attempt.
        if enabled, requiresApproval {
            openLoginItemsSettings()
            return
        }
        guard enabled != isEnabled || (!enabled && requiresApproval) else { return }

        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            errorMessage = "Could not \(enabled ? "enable" : "disable") Launch on Login: \(error.localizedDescription)"
        }
        // Read back even on failure; a registration can be awaiting user approval.
        refresh()
    }

    func openLoginItemsSettings() {
        openSettings()
    }
}
