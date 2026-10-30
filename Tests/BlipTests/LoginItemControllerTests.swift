import Foundation
import ServiceManagement
import Testing
@testable import Blip

@Suite("Launch on Login")
@MainActor
struct LoginItemControllerTests {
    @Test("Opening settings reads macOS without changing registration", arguments: [
        SMAppService.Status.notRegistered, .enabled, .requiresApproval, .notFound,
    ])
    func readsSystemState(status: SMAppService.Status) {
        let service = FakeLoginItemService(status: status)
        let controller = LoginItemController(service: service)

        #expect(controller.isEnabled == (status == .enabled))
        #expect(controller.requiresApproval == (status == .requiresApproval))
        #expect(service.registerCalls == 0)
        #expect(service.unregisterCalls == 0)
    }

    @Test("Toggle registers and unregisters the app")
    func togglesRegistration() {
        let service = FakeLoginItemService()
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)
        #expect(controller.isEnabled)
        #expect(service.registerCalls == 1)

        controller.setEnabled(false)
        #expect(!controller.isEnabled)
        #expect(service.unregisterCalls == 1)
        #expect(controller.errorMessage == nil)
    }

    @Test("External changes are respected and redundant calls are avoided")
    func respectsSystemChanges() {
        let service = FakeLoginItemService()
        let controller = LoginItemController(service: service)

        service.status = .enabled
        controller.setEnabled(true)
        #expect(controller.isEnabled)
        #expect(service.registerCalls == 0)

        service.status = .notRegistered
        controller.refresh()
        #expect(!controller.isEnabled)
        controller.setEnabled(false)
        #expect(service.unregisterCalls == 0)
        #expect(service.registerCalls == 0)
    }

    @Test("Registration awaiting approval is not reported as enabled")
    func pendingApproval() {
        let service = FakeLoginItemService()
        service.registrationStatus = .requiresApproval
        var settingsOpened = false
        let controller = LoginItemController(service: service, openSettings: { settingsOpened = true })

        controller.setEnabled(true)
        #expect(!controller.isEnabled)
        #expect(controller.requiresApproval)

        controller.setEnabled(true)
        #expect(settingsOpened)
        #expect(service.registerCalls == 1)

        controller.setEnabled(false)
        #expect(service.unregisterCalls == 1)
        #expect(!controller.requiresApproval)
    }

    @Test("Failed changes show an error and retain the actual system state", arguments: [true, false])
    func failedChanges(enabled: Bool) {
        let service = FakeLoginItemService(status: enabled ? .notRegistered : .enabled)
        service.operationError = NSError(domain: "LoginItemTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Registration failed",
        ])
        let controller = LoginItemController(service: service)

        controller.setEnabled(enabled)
        #expect(controller.isEnabled == !enabled)
        #expect(controller.errorMessage?.contains("Registration failed") == true)

        service.operationError = nil
        controller.setEnabled(enabled)
        #expect(controller.isEnabled == enabled)
        #expect(controller.errorMessage == nil)
    }
}

@MainActor
private final class FakeLoginItemService: LoginItemService {
    var status: SMAppService.Status
    var registrationStatus: SMAppService.Status = .enabled
    var operationError: Error?
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    init(status: SMAppService.Status = .notRegistered) {
        self.status = status
    }

    func register() throws {
        registerCalls += 1
        if let operationError { throw operationError }
        status = registrationStatus
    }

    func unregister() throws {
        unregisterCalls += 1
        if let operationError { throw operationError }
        status = .notRegistered
    }
}
