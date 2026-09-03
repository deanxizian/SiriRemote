import Carbon.HIToolbox
import CoreGraphics

/// Emits only the keyboard actions owned by SiriRemote's fixed button layout.
///
/// Keeping this API typed prevents hand-edited strings from reintroducing the retired generic
/// shortcut engine. Every call posts a complete, paired key sequence.
enum FixedKeyEmitter {
    enum Key {
        case enter
        case delete
        case up
        case down
        case left
        case right

        var keyCode: CGKeyCode {
            switch self {
            case .enter: return CGKeyCode(kVK_Return)
            case .delete: return CGKeyCode(kVK_Delete)
            case .up: return CGKeyCode(kVK_UpArrow)
            case .down: return CGKeyCode(kVK_DownArrow)
            case .left: return CGKeyCode(kVK_LeftArrow)
            case .right: return CGKeyCode(kVK_RightArrow)
            }
        }
    }

    private struct Modifier {
        let keyCode: CGKeyCode
        let flag: CGEventFlags
    }

    private static let control = Modifier(
        keyCode: CGKeyCode(kVK_Control),
        flag: CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x1)
    )
    private static let command = Modifier(
        keyCode: CGKeyCode(kVK_Command),
        flag: CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x8)
    )

    static func tap(_ key: Key) {
        post(key.keyCode, modifiers: [])
    }

    static func lockScreen() {
        post(CGKeyCode(kVK_ANSI_Q), modifiers: [control, command])
    }

    private static func post(_ keyCode: CGKeyCode, modifiers: [Modifier]) {
        let source = CGEventSource(stateID: .combinedSessionState)
        var flags: CGEventFlags = []

        for modifier in modifiers {
            flags.insert(modifier.flag)
            let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: modifier.keyCode,
                keyDown: true
            )
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }

        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        for modifier in modifiers.reversed() {
            flags.remove(modifier.flag)
            let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: modifier.keyCode,
                keyDown: false
            )
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}
