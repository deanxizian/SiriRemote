import Foundation
import ServiceManagement

enum LaunchAtLogin {
    enum State: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case unavailable

        var isOn: Bool {
            self == .enabled || self == .requiresApproval
        }
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .requiresApproval
        // A freshly installed main app can have no Background Task Management record yet.
        // Registration is what creates that record, so present this as an ordinary off state.
        case .notFound: return .disabled
        @unknown default: return .unavailable
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard SMAppService.mainApp.status != .enabled,
                  SMAppService.mainApp.status != .requiresApproval else { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status != .notRegistered,
                  SMAppService.mainApp.status != .notFound else { return }
            try SMAppService.mainApp.unregister()
        }
    }
}
