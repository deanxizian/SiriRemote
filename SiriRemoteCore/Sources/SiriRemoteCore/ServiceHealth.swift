import Foundation

enum InstalledServiceStatus: Equatable {
    case notInstalled
    case notRunning
    case running
}

enum InstalledServiceHealth {
    static func resolve(
        componentsInstalled: Bool,
        advertisedPID: Int32?,
        isProcessAlive: (Int32) -> Bool
    ) -> InstalledServiceStatus {
        guard componentsInstalled else { return .notInstalled }
        guard let advertisedPID, advertisedPID > 0,
              isProcessAlive(advertisedPID) else { return .notRunning }
        return .running
    }
}
