import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Owns the synthetic Command key for the physical TV-button lifetime.
///
/// TV down holds Command and taps Tab once, keeping the macOS app switcher visible. While the
/// button remains down, the remote's left/right buttons call `movePrevious`/`moveNext`. Every
/// disconnect, sleep, configuration reload and App shutdown calls `end`, so Command cannot stick.
final class AppSwitcherKeyLatch {
    private var latch = HeldInputLatch()

    var isActive: Bool { latch.isHeld }

    private static let commandFlags = CGEventFlags(
        rawValue: CGEventFlags.maskCommand.rawValue | 0x8 // NX_DEVICELCMDKEYMASK
    )
    private static let shiftFlags = CGEventFlags(
        rawValue: CGEventFlags.maskShift.rawValue | 0x2 // NX_DEVICELSHIFTKEYMASK
    )
    private static let syntheticMarker: Int64 = 0x53524153 // SRAS

    @discardableResult
    func begin() -> Bool {
        guard latch.needsTransition(to: true) else { return true }
        guard postKey(CGKeyCode(kVK_Command), isDown: true, flags: Self.commandFlags) else {
            return false
        }
        latch.commit(true)
        guard tap(CGKeyCode(kVK_Tab), flags: Self.commandFlags) else {
            _ = end()
            return false
        }
        return true
    }

    @discardableResult
    func moveNext() -> Bool {
        guard isActive else { return false }
        return tap(CGKeyCode(kVK_Tab), flags: Self.commandFlags)
    }

    @discardableResult
    func movePrevious() -> Bool {
        guard isActive else { return false }
        let combined = Self.commandFlags.union(Self.shiftFlags)
        guard postKey(CGKeyCode(kVK_Shift), isDown: true, flags: combined) else {
            return false
        }
        defer { _ = postKey(CGKeyCode(kVK_Shift), isDown: false, flags: Self.commandFlags) }
        return tap(CGKeyCode(kVK_Tab), flags: combined)
    }

    @discardableResult
    func end() -> Bool {
        guard latch.needsTransition(to: false) else { return true }
        let posted = postKey(CGKeyCode(kVK_Command), isDown: false, flags: [])
        // Clear local ownership even if CoreGraphics could not allocate an event; retaining stale
        // state would prevent a later physical TV press from creating a fresh, paired sequence.
        latch.commit(false)
        return posted
    }

    private func tap(_ keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard postKey(keyCode, isDown: true, flags: flags) else { return false }
        return postKey(keyCode, isDown: false, flags: flags)
    }

    private func postKey(_ keyCode: CGKeyCode,
                         isDown: Bool,
                         flags: CGEventFlags) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: isDown
              ) else {
            rmDebug("⌨️ unable to construct app-switcher key event")
            return false
        }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        event.post(tap: .cghidEventTap)
        return true
    }
}
