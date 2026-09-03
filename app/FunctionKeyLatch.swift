import ApplicationServices
import Foundation

/// Low-level Fn ownership for Doubao's hold-to-talk lifecycle. The first voice frame-ready session
/// sends one keyDown and owns it until the final audio drain sends the paired keyUp. Idempotence and
/// the unconditional release path prevent duplicate edges and a stuck Fn after teardown.
final class FunctionKeyLatch {
    private var latch = HeldInputLatch()
    var isHeld: Bool { latch.isHeld }
    private static let keyCode: CGKeyCode = 63
    private static let syntheticMarker: Int64 = 0x53524D46 // SRMF

    @discardableResult
    func press() -> Bool {
        guard latch.needsTransition(to: true) else { return true }
        guard post(isDown: true) else { return false }
        latch.commit(true)
        return true
    }

    @discardableResult
    func release() -> Bool {
        guard latch.needsTransition(to: false) else { return true }
        let posted = post(isDown: false)
        // A failed synthetic key-up must not leave the App's ownership state latched forever.
        latch.commit(false)
        return posted
    }

    private func post(isDown: Bool) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: Self.keyCode,
                keyDown: isDown
              ) else {
            rmDebug("🎙 unable to construct synthetic Fn \(isDown ? "down" : "up")")
            return false
        }
        event.flags = isDown ? .maskSecondaryFn : []
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        event.post(tap: .cghidEventTap)
        return true
    }
}
