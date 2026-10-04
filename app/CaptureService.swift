import Foundation
import ServiceManagement

/// The service belongs to this signed App bundle. It is deliberately independent of Open at Login.
enum CaptureService {
    static let plistName = "com.deanxi.siriremote.capture.plist"
    static let executableRelativePath = "Contents/Library/LaunchServices/SiriRemoteCapture"
    static let plistRelativePath = "Contents/Library/LaunchDaemons/" + plistName

    static var status: SMAppService.Status { service.status }
    private static var service: SMAppService { .daemon(plistName: plistName) }

    static func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Fixed installer operations only: no caller-supplied executable, label or filesystem path.
    /// PackageKit invokes these in the console user's session after checking the installed App's
    /// identity and root ownership. SMAppService itself enforces approval for the root daemon.
    static func runCommand(_ argument: String) -> Int32? {
        guard ["--register-capture", "--unregister-capture", "--prepare-capture-update",
               "--capture-service-status"]
            .contains(argument) else { return nil }
        guard Bundle.main.bundleURL.path == "/Applications/SiriRemote.app" else {
            fputs("Capture registration requires /Applications/SiriRemote.app\n", stderr)
            return 1
        }
        do {
            let daemon = service
            switch argument {
            case "--register-capture":
                // Never re-register a service the user has disabled / not yet approved.
                if daemon.status != .enabled && daemon.status != .requiresApproval {
                    do {
                        try daemon.register()
                    } catch {
                        // macOS can report LaunchDeniedByUser after successfully registering a
                        // daemon that awaits approval. Keep it pending, never silently enable it.
                        guard daemon.status == .requiresApproval else { throw error }
                    }
                }
                guard daemon.status == .enabled || daemon.status == .requiresApproval else {
                    throw CocoaError(.executableLoad)
                }
            case "--unregister-capture":
                if daemon.status == .enabled || daemon.status == .requiresApproval {
                    try unregisterAndWait(daemon)
                }
            case "--prepare-capture-update":
                // Preserve a disabled / pending registration when replacing the same bundle.
                // Unregistering it would discard the user's decision before re-registration.
                if daemon.status == .enabled { try unregisterAndWait(daemon) }
            default: break
            }
            print(statusLine(daemon.status))
            return 0
        } catch {
            let nsError = error as NSError
            fputs("SIRIREMOTE_CAPTURE_SERVICE_ERROR: \(nsError.domain)/\(nsError.code): \(nsError.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func statusLine(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "SIRIREMOTE_CAPTURE_ENABLED"
        case .requiresApproval: return "SIRIREMOTE_CAPTURE_REQUIRES_APPROVAL"
        case .notRegistered: return "SIRIREMOTE_CAPTURE_NOT_REGISTERED"
        case .notFound: return "SIRIREMOTE_CAPTURE_NOT_FOUND"
        @unknown default: return "SIRIREMOTE_CAPTURE_UNKNOWN"
        }
    }

    private static func unregisterAndWait(_ daemon: SMAppService) throws {
        // SMAppService's synchronous unregister returns before launchd has reaped the old job.
        // Wait for the completion API before the installer replaces the bundle or registers again.
        let result = UnregisterResult()
        daemon.unregister { error in result.complete(error) }
        let deadline = Date().addingTimeInterval(15)
        while !result.snapshot.completed && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let snapshot = result.snapshot
        guard snapshot.completed else { throw CocoaError(.userCancelled) }
        if let error = snapshot.error { throw error }
    }

    private final class UnregisterResult: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private var error: Error?

        var snapshot: (completed: Bool, error: Error?) {
            lock.lock()
            defer { lock.unlock() }
            return (completed, error)
        }

        func complete(_ error: Error?) {
            lock.lock()
            defer { lock.unlock() }
            self.error = error
            completed = true
        }
    }
}
