import Foundation

/// One authenticated XPC lease per physical voice session; no caller-supplied PID is published.
final class RemoteAudioDemand {
    private var session: UInt64?

    @discardableResult
    func begin(session: UInt64) -> Bool {
        self.session = session
        return srm_capture_set_active(1, session) == 0
    }

    func seal(session: UInt64, endFrame: UInt64) {
        guard self.session == session else { return }
        srm_capture_seal(session, endFrame)
    }

    func end(session: UInt64) {
        guard self.session == session else { return }
        _ = srm_capture_set_active(0, session)
        self.session = nil
    }

    deinit {
        if let session { _ = srm_capture_set_active(0, session) }
    }
}
