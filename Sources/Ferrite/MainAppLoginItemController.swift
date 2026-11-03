import ServiceManagement
import FerriteCore

final class MainAppLoginItemController: KeepAwakeLoginItemControlling {
    var needsApproval: Bool { SMAppService.mainApp.status != .enabled }

    func ensureRegistered() throws -> Bool {
        let service = SMAppService.mainApp
        if service.status == .notRegistered { try service.register() }
        return service.status != .enabled
    }
}
