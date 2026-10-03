import AppKit

enum TypelessStatus: Equatable {
    case notInstalled, notRunning, running
}

/// Only public application discovery APIs. Do not read Typeless's private preferences,
/// change its shortcut, select a TIS input source, or alter the system's default microphone.
enum TypelessIntegration {
    static let bundleIdentifier = "now.typeless.desktop"
    static var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
    static var isRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { !$0.isTerminated }
    }
    static var status: TypelessStatus {
        if isRunning { return .running }
        return applicationURL == nil ? .notInstalled : .notRunning
    }

    static func openDownload() {
        guard let url = URL(string: "https://www.typeless.com/") else { return }
        NSWorkspace.shared.open(url)
    }
}
