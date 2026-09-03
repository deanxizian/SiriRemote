import Combine
import Foundation

@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var config: Config
    @Published var connected = false
    @Published private(set) var secondRemoteIgnored = false
    @Published private(set) var readiness = SystemReadiness.snapshot()
    @Published private(set) var launchAtLoginState = LaunchAtLogin.state
    @Published private(set) var configSaveError: String?
    @Published var configLoadError: String?
    @Published var launchAtLoginError: String?

    var onConfigChanged: ((Config) -> Void)?

    init(config: Config) {
        self.config = config
        configLoadError = ConfigStore.lastLoadError
    }

    var touchEnabled: Bool { config.settings.touchEnabled }
    var circularScrollEnabled: Bool { config.settings.circularScroll.enabled }
    var cursorSpeed: Double { config.settings.cursorSpeed }
    var scrollSpeed: Double { config.settings.circularScroll.pixelsPerRadian }
    var launchAtLoginEnabled: Bool { launchAtLoginState.isOn }
    var launchAtLoginAvailable: Bool { launchAtLoginState != .unavailable }
    var launchAtLoginRequiresApproval: Bool { launchAtLoginState == .requiresApproval }

    func startRefreshing() {
        refreshStatus()
    }

    func stopRefreshing() {}

    func refreshStatus() {
        readiness = SystemReadiness.snapshot()
        refreshLaunchAtLoginState()
    }

    /// AppDelegate owns the one process-wide permission/health poll. Publishing that snapshot here
    /// avoids making the settings window issue two extra TCC queries every refresh interval.
    func updateReadiness(_ snapshot: SystemReadinessSnapshot) {
        readiness = snapshot
        refreshLaunchAtLoginState()
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            try LaunchAtLogin.setEnabled(enabled)
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLoginState()
    }

    func clearLaunchAtLoginError() {
        launchAtLoginError = nil
    }

    func setSecondRemoteIgnored(_ ignored: Bool) {
        secondRemoteIgnored = ignored
    }

    func replaceConfigFromDisk(_ newConfig: Config) {
        config = newConfig
        configLoadError = nil
        configSaveError = nil
    }

    func reportConfigLoadError(_ error: Error) {
        configLoadError = error.localizedDescription
    }

    func updateSettings(_ change: (inout Config.Settings) -> Void) {
        commit(config.withSettingsUpdated(change))
    }

    func resetDefaults() {
        do {
            let defaults = try ConfigStore.loadAndValidate(ConfigStore.defaultTemplate)
            commit(defaults)
        } catch {
            configSaveError = error.localizedDescription
        }
    }

    private func commit(_ updated: Config) {
        guard updated != config else { return }
        do {
            try ConfigStore.save(updated)
            ConfigStore.clearLoadError()
            config = updated
            configLoadError = nil
            configSaveError = nil
            onConfigChanged?(updated)
        } catch {
            configSaveError = error.localizedDescription
        }
    }

    private func refreshLaunchAtLoginState() {
        let current = LaunchAtLogin.state
        if launchAtLoginState != current {
            launchAtLoginState = current
        }
    }
}
