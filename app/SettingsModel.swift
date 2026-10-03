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
    var voiceTarget: VoiceTarget { config.settings.voiceTarget }
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

    /// Uses the same persistent setting as the picker. No window activation, input-source
    /// selection or third-party app launching is needed just to choose the next voice target.
    func switchVoiceTarget() -> String? {
        refreshStatus()
        let current = voiceTarget
        guard current.canSwitchToAlternate(
            doubaoEnabled: readiness.doubaoInputSourceEnabled,
            typelessRunning: readiness.typelessStatus == .running
        ) else {
            return current.alternate == .doubao
                ? L("Enable Doubao Input Method first") : L("Start Typeless first")
        }
        if commit(config.withSettingsUpdated({ $0.voiceTarget = current.alternate })) { return nil }
        return configSaveError ?? L("Unknown Error")
    }

    func resetDefaults() {
        do {
            let defaults = try ConfigStore.loadAndValidate(ConfigStore.defaultTemplate)
            commit(defaults.withSettingsUpdated { $0.voiceTarget = config.settings.voiceTarget })
        } catch {
            configSaveError = error.localizedDescription
        }
    }

    @discardableResult
    private func commit(_ updated: Config) -> Bool {
        guard updated != config else { return true }
        do {
            try ConfigStore.save(updated)
            ConfigStore.clearLoadError()
            config = updated
            configLoadError = nil
            configSaveError = nil
            onConfigChanged?(updated)
            return true
        } catch {
            configSaveError = error.localizedDescription
            return false
        }
    }

    private func refreshLaunchAtLoginState() {
        let current = LaunchAtLogin.state
        if launchAtLoginState != current {
            launchAtLoginState = current
        }
    }
}
