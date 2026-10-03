import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Platform encoding for held keys. Event construction is separate from posting so regression
/// tests inspect the real Quartz/NX repeat flags without typing into the user's foreground App.
enum HeldButtonEmitter {
    static func post(_ button: FixedRemoteButton, _ edge: HeldButtonEdge) -> Bool {
        guard let output = makeEvent(button, edge) else { return false }
        output.event.post(tap: output.tap)
        return true
    }

    static func makeEvent(
        _ button: FixedRemoteButton, _ edge: HeldButtonEdge
    ) -> (event: CGEvent, tap: CGEventTapLocation)? {
        switch button {
        case .menu: return keyboard(CGKeyCode(kVK_Delete), edge)
        case .ringUp: return keyboard(CGKeyCode(kVK_UpArrow), edge)
        case .ringDown: return keyboard(CGKeyCode(kVK_DownArrow), edge)
        case .ringLeft: return keyboard(CGKeyCode(kVK_LeftArrow), edge)
        case .ringRight: return keyboard(CGKeyCode(kVK_RightArrow), edge)
        case .volumeUp: return media(NX_KEYTYPE_SOUND_UP, edge)
        case .volumeDown: return media(NX_KEYTYPE_SOUND_DOWN, edge)
        default: return nil
        }
    }

    private static func keyboard(
        _ keyCode: CGKeyCode, _ edge: HeldButtonEdge
    ) -> (CGEvent, CGEventTapLocation)? {
        guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState),
                                  virtualKey: keyCode, keyDown: edge.isDown) else { return nil }
        event.flags = []
        event.setIntegerValueField(.keyboardEventAutorepeat, value: edge.isRepeat ? 1 : 0)
        event.setIntegerValueField(.eventSourceUserData, value: 0x53524B48) // SRKH
        return (event, .cghidEventTap)
    }

    private static func media(
        _ keyCode: Int32, _ edge: HeldButtonEdge
    ) -> (CGEvent, CGEventTapLocation)? {
        // NX media repeat events use the low bit of data1, with no intervening key-up. Posting
        // at the session tap bypasses our HID-level interception of the remote's native stream.
        let keyFlags = ((edge.isDown ? 0xa : 0xb) << 8) | (edge.isRepeat ? 1 : 0)
        guard let event = NSEvent.otherEvent(
            with: .systemDefined, location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(keyFlags)),
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            subtype: 8, data1: Int(keyCode << 16) | keyFlags, data2: -1
        )?.cgEvent else { return nil }
        event.setIntegerValueField(.eventSourceUserData, value: 0x53524D48) // SRMH
        return (event, .cgSessionEventTap)
    }
}
