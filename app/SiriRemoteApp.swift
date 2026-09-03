import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var menuBarManager: MenuBarManager?
    private var remoteDetector: RemoteDetector?
    private var remoteInputHandler: RemoteInputHandler?
    private var mediaKeyInterceptor: MediaKeyInterceptor?
    private var touchHandler: TouchHandler?
    private var configWatcher: ConfigFileWatcher?
    private var settingsModel: SettingsModel?
    private var settingsWindow: SettingsWindowController?
    private var voiceCoordinator: DoubaoVoiceCoordinator?
    private var permissionTimer: Timer?
    private var permissionActivationObserver: NSObjectProtocol?
    private var inputSourcesObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var permissionRecoveryPolicy: PermissionRecoveryPolicy?
    private var permissionRelaunchScheduled = false
    private var inputPipelineActive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        ApplicationMenu.install()
        rmDebug("🚀 SiriRemote starting")

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        let menu = MenuBarManager(statusItem: item)
        menuBarManager = menu

        let config = ConfigStore.loadConfig()
        let cursor = CursorController()
        let input = RemoteInputHandler()
        remoteInputHandler = input

        let touch = TouchHandler(cursorController: cursor)
        touch.onTwoFingerTap = { [weak cursor] in cursor?.performRightClick() }
        touchHandler = touch

        let voice = DoubaoVoiceCoordinator()
        voiceCoordinator = voice
        input.onSiriButtonEdge = { [weak voice] pressed in voice?.handleSiri(pressed: pressed) }
        input.onButtonActivity = { [weak touch] in touch?.tryReconnectTrackpad() }

        let model = SettingsModel(config: config)
        settingsModel = model
        model.onConfigChanged = { [weak self] updated in self?.apply(updated, isReload: true) }

        let window = SettingsWindowController(model: model)
        settingsWindow = window
        menu.onOpenApp = { [weak window] in window?.show() }

        configWatcher = ConfigFileWatcher(url: ConfigStore.path) { [weak self] in
            self?.reloadConfigFromDisk()
        }

        apply(config, isReload: false)
        installLifecycleObservers()
        startPermissionMonitoring()

        // Present the primary window on every fresh process launch. Closing it keeps the menu-bar
        // controller alive and hides the Dock icon; reopening it from the status menu restores the
        // regular App role. Command-Q still terminates the process while the window is active.
        DispatchQueue.main.async { window.show() }
    }

    private func apply(_ config: Config, isReload: Bool) {
        if isReload { remoteInputHandler?.prepareForConfigurationReload() }
        let settings = config.settings
        touchHandler?.setTouchEnabled(settings.touchEnabled)
        touchHandler?.cursorSpeed = CGFloat(settings.cursorSpeed)
        touchHandler?.cursorDeadzone = CGFloat(settings.cursorDeadzone)
        touchHandler?.accelMin = CGFloat(settings.accelMin)
        touchHandler?.accelMax = CGFloat(settings.accelMax)
        touchHandler?.accelLowSpeed = CGFloat(settings.accelLowSpeed)
        touchHandler?.accelHighSpeed = CGFloat(settings.accelHighSpeed)
        touchHandler?.accelCurve = CGFloat(settings.accelCurve)
        touchHandler?.clickRiseThreshold = settings.clickRiseThreshold
        touchHandler?.pressMoveMax = settings.pressMoveMax
        touchHandler?.setCircularConfig(settings.circularScroll)
        touchHandler?.scrollScale = CGFloat(
            max(80, min(700, settings.circularScroll.pixelsPerRadian * 4))
        )
    }

    private func reloadConfigFromDisk() {
        do {
            let text = try String(contentsOf: ConfigStore.path, encoding: .utf8)
            let config = try ConfigStore.loadAndValidate(text)
            ConfigStore.clearLoadError()
            settingsModel?.replaceConfigFromDisk(config)
            apply(config, isReload: true)
        } catch {
            settingsModel?.reportConfigLoadError(error)
            NSLog("[SiriRemote] hot reload rejected: \(error.localizedDescription)")
        }
    }

    private func startRemoteDetection() {
        remoteDetector?.stopDetection()
        let detector = RemoteDetector { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .added(let device, _):
                    self.remoteInputHandler?.setRemoteDevice(device)
                case .removed(let device, _):
                    self.remoteInputHandler?.removeRemoteDevice(device)
                case .reset:
                    self.remoteInputHandler?.setRemoteDevice(nil)
                }
                let connected = event.isConnected
                self.menuBarManager?.updateConnectionStatus(connected: connected)
                self.settingsModel?.connected = connected
                if !connected { self.voiceCoordinator?.abort(reason: "遥控器已断开") }
            }
        }
        detector.onSecondRemoteIgnoredChanged = { [weak model = settingsModel] ignored in
            Task { @MainActor in model?.setSecondRemoteIgnored(ignored) }
        }
        remoteDetector = detector
        detector.startDetection()
    }

    private func startMediaInterception() {
        mediaKeyInterceptor?.stop()
        let interceptor = MediaKeyInterceptor()
        interceptor.onMediaKey = { [weak self] key in self?.shouldConsumeMediaKey(key) ?? false }
        interceptor.onAccessibilityRevoked = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let snapshot = SystemReadiness.snapshot()
                self.publishReadiness(snapshot)
                self.suspendInputPipeline(reason: "辅助功能权限已关闭")
            }
        }
        interceptor.start()
        mediaKeyInterceptor = interceptor
    }

    private func shouldConsumeMediaKey(_ key: MediaKeyInterceptor.MediaKeyType) -> Bool {
        let button: String
        switch key {
        case .playPause: button = "playPause"
        case .next: button = "nextTrack"
        case .previous: button = "prevTrack"
        case .volumeUp: button = "volumeUp"
        case .volumeDown: button = "volumeDown"
        case .mute: button = "mute"
        }
        let fromRemote = RemoteInputHandler.lastProcessedButton == button
            && Self.secondsSince(RemoteInputHandler.lastProcessedTime) < 0.3
        let fixedMediaButtons: Set<String> = ["playPause", "volumeUp", "volumeDown", "mute"]
        return fromRemote && fixedMediaButtons.contains(button)
    }

    private func installLifecycleObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.suspendInputPipeline(reason: "Mac 正在睡眠")
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let snapshot = SystemReadiness.snapshot()
                self.publishReadiness(snapshot)
                self.resumeInputPipelineIfReady(snapshot, reason: "Mac 已唤醒")
            }
        })
    }

    private func startPermissionMonitoring() {
        let initial = SystemReadiness.snapshot()
        permissionRecoveryPolicy = PermissionRecoveryPolicy(initial: permissionState(initial))
        publishReadiness(initial)
        if initial.accessibilityGranted, initial.hidInputAvailable {
            resumeInputPipelineIfReady(initial, reason: "启动")
        } else {
            suspendInputPipeline(reason: "启动时输入权限不可用")
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        permissionTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        permissionActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }

        inputSourcesObserver = DistributedNotificationCenter.default().addObserver(
            forName: DoubaoInputSourceCoordinator.enabledSourcesDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The enabled-input-source list changes infrequently, but its UI should update on the
            // actual system event instead of waiting for the two-second safety poll.
            Task { @MainActor in
                rmDebug("⌨️ enabled input sources changed — refreshing readiness")
                self?.refreshPermissions()
            }
        }
    }

    private func refreshPermissions() {
        let snapshot = SystemReadiness.snapshot()
        publishReadiness(snapshot)
        guard var policy = permissionRecoveryPolicy else {
            permissionRecoveryPolicy = PermissionRecoveryPolicy(initial: permissionState(snapshot))
            return
        }
        let actions = policy.update(permissionState(snapshot))
        permissionRecoveryPolicy = policy

        if actions.contains(.relaunchForStaleHIDAuthorization) {
            suspendInputPipeline(reason: "等待权限恢复重启")
            schedulePermissionRecoveryRelaunch()
            return
        }

        let lostInput = actions.contains(.stopAccessibilityInput)
            || actions.contains(.stopHIDInput)
        if lostInput {
            let reason = actions.contains(.stopAccessibilityInput)
                ? "辅助功能权限已关闭"
                : "遥控器输入通道不可用"
            suspendInputPipeline(reason: reason)
        }

        let gainedInput = actions.contains(.startAccessibilityInput)
            || actions.contains(.startHIDInput)
        if gainedInput {
            resumeInputPipelineIfReady(snapshot, reason: "输入权限已恢复")
        }
    }

    /// The App owns one all-or-nothing input pipeline. Partial shutdown is unsafe: a live touch
    /// callback or HID callback can otherwise post another event after held state was released.
    private func suspendInputPipeline(reason: String) {
        let wasActive = inputPipelineActive
        inputPipelineActive = false
        touchHandler?.stop()
        voiceCoordinator?.abort(reason: reason)
        remoteInputHandler?.suspendInput()
        remoteDetector?.stopDetection()
        mediaKeyInterceptor?.stop()
        if wasActive {
            rmDebug("🛟 input pipeline suspended and all held state released: \(reason)")
        }
    }

    private func resumeInputPipelineIfReady(
        _ snapshot: SystemReadinessSnapshot,
        reason: String
    ) {
        guard snapshot.accessibilityGranted, snapshot.hidInputAvailable else { return }
        guard !inputPipelineActive else { return }
        inputPipelineActive = true
        touchHandler?.start()
        startRemoteDetection()
        startMediaInterception()
        rmDebug("✅ input pipeline active: \(reason)")
    }

    private func permissionState(_ snapshot: SystemReadinessSnapshot) -> PermissionGrantState {
        PermissionGrantState(
            accessibilityGranted: snapshot.accessibilityGranted,
            hidInputAvailable: snapshot.hidInputAvailable
        )
    }

    private func publishReadiness(_ snapshot: SystemReadinessSnapshot) {
        menuBarManager?.updatePermissionStatus(ready: snapshot.corePermissionsGranted)
        menuBarManager?.updateHIDInputAvailability(snapshot.hidInputAvailable)
        settingsModel?.updateReadiness(snapshot)
    }

    /// IOHID's ListenEvent decision is process-scoped on current macOS releases. When the App was
    /// launched while Accessibility was disabled, enabling Accessibility can leave IOHID denied
    /// until the next process. Reopen the already-installed, stably signed App exactly once and let
    /// normal termination cleanup release every held input before the old instance exits.
    private func schedulePermissionRecoveryRelaunch() {
        guard !permissionRelaunchScheduled else { return }
        permissionRelaunchScheduled = true
        rmDebug("🔐 Accessibility restored while IOHID authorization is stale — relaunching once")

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--settings", "--permission-recovery"]
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { [weak self] application, error in
            Task { @MainActor in
                if let error {
                    self?.permissionRelaunchScheduled = false
                    rmDebug("⚠️ permission recovery relaunch failed: \(error.localizedDescription)")
                    let snapshot = SystemReadiness.snapshot()
                    self?.publishReadiness(snapshot)
                    self?.resumeInputPipelineIfReady(snapshot, reason: "权限恢复重启失败后的原地恢复")
                    return
                }
                rmDebug("🔐 permission recovery process started pid=\(application?.processIdentifier ?? 0)")
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow?.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { cleanup() }

    private func cleanup() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        if let observer = permissionActivationObserver {
            NotificationCenter.default.removeObserver(observer)
            permissionActivationObserver = nil
        }
        if let observer = inputSourcesObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            inputSourcesObserver = nil
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
        configWatcher = nil
        suspendInputPipeline(reason: "App 正在退出")
        voiceCoordinator?.shutdown()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        srm_remote_audio_state_close()
    }

    private static let timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return value
    }()

    private static func secondsSince(_ start: UInt64) -> Double {
        guard start > 0 else { return .infinity }
        let elapsed = mach_absolute_time() &- start
        return Double(elapsed) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
}
