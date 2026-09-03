import Foundation

/// Publishes App-owned capture demand without overwriting the HAL driver's independent consumer
/// count. The root capture service also watches this PID and tears down if the App crashes.
final class RemoteAudioDemand {
    static let notification = "com.deanxi.siriremote.audio.voice-demand"
    static let captureReadyNotification = "com.deanxi.siriremote.audio.capture-ready"

    private var token: Int32 = -1
    private var captureReadyToken: Int32 = -1
    private(set) var active = false

    init() {
        if notify_register_check(Self.notification, &token) != NOTIFY_STATUS_OK { token = -1 }
        if notify_register_check(
            Self.captureReadyNotification, &captureReadyToken
        ) != NOTIFY_STATUS_OK { captureReadyToken = -1 }
    }

    deinit {
        setActive(false)
        if token >= 0 { notify_cancel(token) }
        if captureReadyToken >= 0 { notify_cancel(captureReadyToken) }
    }

    var captureReady: Bool {
        guard captureReadyToken >= 0 else { return false }
        var state: UInt64 = 0
        return notify_get_state(captureReadyToken, &state) == NOTIFY_STATUS_OK && state == 1
    }

    @discardableResult
    func setActive(_ wanted: Bool) -> Bool {
        guard token >= 0 else { return false }
        let ownPID = UInt64(ProcessInfo.processInfo.processIdentifier)
        if wanted {
            guard !active else { return true }
            guard notify_set_state(token, ownPID) == NOTIFY_STATUS_OK else { return false }
            notify_post(Self.notification)
            active = true
            return true
        }

        guard active else { return true }
        var owner: UInt64 = 0
        if notify_get_state(token, &owner) == NOTIFY_STATUS_OK, owner == ownPID {
            _ = notify_set_state(token, 0)
            notify_post(Self.notification)
        }
        active = false
        return true
    }
}
