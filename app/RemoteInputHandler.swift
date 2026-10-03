//
//  RemoteInputHandler.swift
//  SiriRemote
//
//  A2854-only HID input. HyperVibe's device opening and touch guarding are retained; ordinary
//  buttons use one fixed product layout while Siri owns the selected voice tool's lifecycle.
//

import AppKit
import Foundation
import IOKit
import IOKit.hid

final class RemoteInputHandler {
    private var devices: [IOHIDDevice] = []
    private var deviceSources: [IOHIDDevice: String] = [:]
    private var buttonState = MultiRemoteButtonState<String, String>()
    private var acceptingInput = false
    private let mediaController = MediaController()
    private let appSwitcher = AppSwitcherKeyLatch()
    private var fixedButtons = FixedButtonHoldState()
    private let heldOutput = HeldButtonOutput(post: HeldButtonEmitter.post)
    private var repeatTimer: DispatchSourceTimer?

    var onButtonActivity: (() -> Void)?
    var onPhysicalButtonStateChanged: ((_ rawName: String, _ pressed: Bool) -> Void)?
    var onPhysicalButtonStateReset: (() -> Void)?
    var onSiriButtonEdge: ((_ pressed: Bool) -> Void)?
    var onSiriButtonCancelled: (() -> Void)?
    /// True consumes a remote volume press as a voice-mode chord, without changing system volume.
    var onVoiceVolumeButton: ((VoiceVolumeButton) -> Bool)?

    private var initialPressSuppressionDeadline: [String: UInt64] = [:]
    private var suppressedInitialButtons: [String: Set<String>] = [:]
    private static let initialPressSuppressionWindowNanoseconds: UInt64 = 750_000_000

    private static var touchGuardDeadlineNanos: UInt64 = 0
    static var touchGuardDuration: Double = 0.2
    static var isTouchGuarded: Bool {
        DispatchTime.now().uptimeNanoseconds < touchGuardDeadlineNanos
    }
    static func armTouchGuard(_ seconds: Double = touchGuardDuration) {
        touchGuardDeadlineNanos = DispatchTime.now().uptimeNanoseconds
            &+ UInt64(seconds * 1_000_000_000)
    }
    private static let onGlassButtons: Set<String> =
        ["ringUp", "ringDown", "ringLeft", "ringRight", "select"]

    // MARK: - HID interface lifetime

    func setRemoteDevice(_ device: IOHIDDevice?) {
        guard let device else {
            acceptingInput = false
            releaseAllInput()
            for opened in devices { close(opened) }
            devices.removeAll()
            deviceSources.removeAll()
            initialPressSuppressionDeadline.removeAll()
            suppressedInitialButtons.removeAll()
            return
        }
        guard !devices.contains(where: { $0 == device }) else { return }

        let usagePage = property(device, kIOHIDPrimaryUsagePageKey) ?? -1
        let shouldSeize = usagePage != 0x20
        let requested = IOOptionBits(
            shouldSeize ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone
        )
        var result = IOHIDDeviceOpen(device, requested)
        if result != kIOReturnSuccess, shouldSeize {
            rmDebug(String(format: "⚠️ seize failed 0x%X; retrying non-exclusive", result))
            result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        guard result == kIOReturnSuccess else {
            rmDebug(String(format: "⚠️ HID open failed 0x%X", result))
            return
        }

        // Button ownership is per HID interface, not per physical remote. A2854 mirrors some
        // edges across interfaces; MultiRemoteButtonState collapses those edges globally while
        // still being able to release the exact state owned by an interface that disappears.
        let source = remoteInterfaceID(for: device)
        devices.append(device)
        deviceSources[device] = source
        acceptingInput = true
        initialPressSuppressionDeadline[source] = DispatchTime.now().uptimeNanoseconds
            &+ Self.initialPressSuppressionWindowNanoseconds
        IOHIDDeviceRegisterInputValueCallback(
            device, inputValueCallback, Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDDeviceScheduleWithRunLoop(
            device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue
        )
        rmDebug(String(
            format: "%@ A2854 interface usage=0x%X/0x%X source=%@",
            shouldSeize ? "🔒 opened" : "🔓 opened non-exclusive",
            usagePage,
            property(device, kIOHIDPrimaryUsageKey) ?? -1,
            source
        ))
    }

    func removeRemoteDevice(_ device: IOHIDDevice) {
        guard let index = devices.firstIndex(where: { $0 == device }) else { return }
        let source = deviceSources[device] ?? remoteInterfaceID(for: device)
        close(device)
        devices.remove(at: index)
        deviceSources[device] = nil
        acceptingInput = !devices.isEmpty
        initialPressSuppressionDeadline[source] = nil
        suppressedInitialButtons[source] = nil
        let released = buttonState.removeSource(source)
        for button in released {
            onPhysicalButtonStateChanged?(button, false)
            if button == "siri" {
                onSiriButtonCancelled?()
            } else {
                routeFixedButton(button, pressed: false, cancelled: true)
            }
        }
        if devices.isEmpty {
            releaseAllInput()
            rmDebug("🛰 last A2854 interface removed; input state released")
        } else {
            rmDebug("🛰 A2854 interface removed; sibling interfaces remain")
        }
    }

    private func close(_ device: IOHIDDevice) {
        IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(
            device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue
        )
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func remoteInterfaceID(for device: IOHIDDevice) -> String {
        let service = IOHIDDeviceGetService(device)
        var registryID: UInt64 = 0
        if service != 0 {
            _ = IORegistryEntryGetRegistryEntryID(service, &registryID)
        }
        if registryID != 0 { return "registry-entry:\(registryID)" }

        // A registry entry ID is present on real IOHID devices. Keep a deterministic fallback for
        // unusual firmware/test doubles without conflating two interfaces from one remote.
        let usagePage = property(device, kIOHIDPrimaryUsagePageKey) ?? -1
        let usage = property(device, kIOHIDPrimaryUsageKey) ?? -1
        let location = property(device, kIOHIDLocationIDKey) ?? -1
        return "\(a2854PhysicalIdentity(device))/\(usagePage):\(usage):\(location)"
    }

    private func property(_ device: IOHIDDevice, _ key: String) -> Int? {
        IOHIDDeviceGetProperty(device, key as CFString) as? Int
    }

    // MARK: - HID edges

    func handleInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let sourceDevice = IOHIDElementGetDevice(element)
        // IOHID can already have queued a callback when its device is unscheduled. Teardown marks
        // input inactive first, and this membership check prevents that stale callback from posting
        // a fresh mouse/key/Fn edge after all held state was released.
        guard acceptingInput, let source = deviceSources[sourceDevice] else { return }
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        guard let button = identifyButton(page: usagePage, usage: usage) else { return }

        onButtonActivity?()
        let pressed = IOHIDValueGetIntegerValue(value) == 1
        let transition = buttonState.update(source: source, button: button, pressed: pressed)
        if button == "mute" || button == "playPause" {
            rmDebug("🎮 HID \(button) value=\(IOHIDValueGetIntegerValue(value)) edge=\(transition)")
        }
        guard transition != .duplicate else { return }

        if pressed, let deadline = initialPressSuppressionDeadline.removeValue(forKey: source),
           DispatchTime.now().uptimeNanoseconds <= deadline {
            // Suppress the matching release only when this interface created the logical down.
            // A mirrored source-only edge may later become the last owner after another interface
            // disappears; its release must then propagate to close the already-emitted hold.
            if transition == .globalDown {
                suppressedInitialButtons[source, default: []].insert(button)
            }
            return
        }
        if !pressed, suppressedInitialButtons[source]?.remove(button) != nil {
            if suppressedInitialButtons[source]?.isEmpty == true {
                suppressedInitialButtons[source] = nil
            }
            return
        }
        guard transition != .sourceOnly else { return }

        onPhysicalButtonStateChanged?(button, pressed)
        if button == "siri" {
            onSiriButtonEdge?(pressed)
            return
        }

        if pressed, Self.onGlassButtons.contains(button) { Self.armTouchGuard() }
        routeFixedButton(button, pressed: pressed)
    }

    private func identifyButton(page: UInt32, usage: UInt32) -> String? {
        switch (page, usage) {
        case (0x01, 0x86), (0x01, 0x40): return "menu"
        case (0x0C, 0x42): return "ringUp"
        case (0x0C, 0x43): return "ringDown"
        case (0x0C, 0x44): return "ringLeft"
        case (0x0C, 0x45): return "ringRight"
        case (0x0C, 0x04): return "siri"
        case (0x0C, 0x60), (0x0C, 0x223): return "tv"
        case (0x0C, 0x80), (0x0C, 0x41), (0x09, 0x01): return "select"
        case (0x0C, 0xCD): return "playPause"
        case (0x0C, 0xE9): return "volumeUp"
        case (0x0C, 0xEA): return "volumeDown"
        case (0x0C, 0x224), (0x0C, 0x40): return "menu"
        case (0x0C, 0x30): return "power"
        case (0x0C, 0xE2), (0x0C, 0x20): return "mute"
        default: return nil
        }
    }

    // MARK: - Fixed product layout

    private func routeFixedButton(_ button: String, pressed: Bool, cancelled: Bool = false) {
        guard let button = FixedRemoteButton(rawValue: button) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let commands: [FixedButtonHoldState.Command]
        if pressed {
            // Read at the start of each hold so changes to the macOS Keyboard settings apply on
            // the next press. The repeat engine preserves one down/up pair for the entire hold.
            let timing = ButtonRepeatTiming(
                delay: NSEvent.keyRepeatDelay, interval: NSEvent.keyRepeatInterval
            )
            commands = fixedButtons.press(button, at: now, timing: timing)
        } else {
            commands = fixedButtons.release(button, at: now, cancelled: cancelled)
        }
        for command in commands { perform(command) }
        scheduleRepeat()
    }

    private func perform(_ command: FixedButtonHoldState.Command) {
        switch command {
        case .activate(let button):
            activateOnRelease(button)
        case .beginHold(.tv):
            stopAppSwitcherNavigationRepeats()
            if !appSwitcher.begin() { NSSound.beep() }
        case .beginHold(let button):
            performHeldButton(button, repeating: false)
        case .repeatHold(let button):
            performHeldButton(button, repeating: true)
        case .endHold(let button):
            if button == .tv {
                _ = appSwitcher.end()
                stopAppSwitcherNavigationRepeats()
            } else {
                heldOutput.end(button)
            }
        }
    }

    private func performHeldButton(_ button: FixedRemoteButton, repeating: Bool) {
        switch button {
        case .ringLeft where appSwitcher.isActive:
            _ = appSwitcher.movePrevious()
        case .ringRight where appSwitcher.isActive:
            _ = appSwitcher.moveNext()
        default:
            if button == .volumeUp || button == .volumeDown,
               onVoiceVolumeButton?(button == .volumeUp ? .up : .down) == true {
                // A chord can also take over an already-held volume button. End that OS hold,
                // and do not resume its repeats if Siri is released before the volume button.
                heldOutput.end(button)
                fixedButtons.consumeUntilRelease(button)
                return
            }
            let posted = repeating ? heldOutput.repeatDown(button) : heldOutput.begin(button)
            if !posted {
                heldOutput.end(button)
                fixedButtons.consumeUntilRelease(button)
                rmDebug("⌨️ unable to construct held-button event for \(button.rawValue)")
            }
        }
    }

    private func activateOnRelease(_ button: FixedRemoteButton) {
        switch button {
        case .power:
            // macOS does not permit third-party software to bypass the lock-screen credential.
            // The public user-facing action is therefore Lock Screen (and, if already locked, the
            // synthetic key activity may wake the authentication UI but never unlocks it).
            _ = appSwitcher.end()
            stopAppSwitcherNavigationRepeats()
            FixedKeyEmitter.lockScreen()
        case .select:
            // A real physical release emits Return once. A light surface tap remains a mouse
            // click in TouchHandler and is governed solely by settings.touchEnabled.
            FixedKeyEmitter.tap(.enter)
        case .playPause:
            mediaController.sendMediaKey(.playPause)
        case .mute:
            mediaController.sendMediaKey(.mute)
        default:
            break
        }
    }

    private func stopAppSwitcherNavigationRepeats() {
        // A direction held while choosing an App must not turn into arrow presses in that App
        // when TV is released. Require a new physical direction press in the new context.
        fixedButtons.consumeUntilRelease(.ringLeft)
        fixedButtons.consumeUntilRelease(.ringRight)
        heldOutput.end(.ringLeft)
        heldOutput.end(.ringRight)
    }

    /// Suppress the remote's native media stream for its entire hold, not just the first 300 ms.
    func shouldSuppressMediaKey(_ key: MediaKeyInterceptor.MediaKeyType) -> Bool {
        let button: FixedRemoteButton
        switch key {
        case .mute: button = .mute
        case .playPause: button = .playPause
        case .volumeUp: button = .volumeUp
        case .volumeDown: button = .volumeDown
        case .next, .previous: return false
        }
        return fixedButtons.suppressesNativeMedia(button, at: ProcessInfo.processInfo.systemUptime)
    }

    // MARK: - Teardown

    func prepareForConfigurationReload() {
        cancelAllInput()
    }

    func cancelAllInput() {
        releaseAllInput()
    }

    func suspendInput() {
        acceptingInput = false
        releaseAllInput()
    }

    private func releaseAllInput() {
        if buttonState.heldButtons.contains("siri") { onSiriButtonCancelled?() }
        stopRepeating()
        for command in fixedButtons.reset() { perform(command) }
        heldOutput.releaseAll()
        _ = appSwitcher.end()
        buttonState.removeAll()
        onPhysicalButtonStateReset?()
    }

    private func scheduleRepeat() {
        guard let deadline = fixedButtons.nextRepeatAt else {
            stopRepeating()
            return
        }
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        // A disabled key-repeat preference can be represented by an enormous delay. Avoid
        // overflowing DispatchTime's nanosecond conversion or falling back to a fast repeat.
        let fireAt: DispatchTime = delay < Double(Int64.max / 1_000_000_000)
            ? .now() + delay : .distantFuture
        if let timer = repeatTimer {
            timer.schedule(deadline: fireAt, leeway: .milliseconds(5))
        } else {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: fireAt, leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in
                guard let self, self.acceptingInput else { return }
                let due = self.fixedButtons.takeRepeats(at: ProcessInfo.processInfo.systemUptime)
                for command in due { self.perform(command) }
                self.scheduleRepeat()
            }
            repeatTimer = timer
            timer.resume()
        }
    }

    private func stopRepeating() {
        repeatTimer?.setEventHandler {}
        repeatTimer?.cancel()
        repeatTimer = nil
    }
}

private func inputValueCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard result == kIOReturnSuccess, let context else { return }
    _ = sender
    Unmanaged<RemoteInputHandler>.fromOpaque(context)
        .takeUnretainedValue()
        .handleInputValue(value)
}
