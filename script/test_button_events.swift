import AppKit
import Carbon.HIToolbox

/// Builds the production event encoder but never calls CGEvent.post. This executable is not an
/// App and does not seize hardware, request permissions, or install an event tap.
@main
enum ButtonEventTests {
    static func main() {
        let edges: [HeldButtonEdge] = [.down, .repeatDown, .up]
        let keyboard: [(FixedRemoteButton, Int)] = [
            (.menu, kVK_Delete), (.ringUp, kVK_UpArrow), (.ringDown, kVK_DownArrow),
            (.ringLeft, kVK_LeftArrow), (.ringRight, kVK_RightArrow)
        ]
        for (button, keyCode) in keyboard {
            for edge in edges {
                let output = HeldButtonEmitter.makeEvent(button, edge)!
                let event = output.event
                precondition(output.tap == .cghidEventTap)
                precondition(event.type == (edge.isDown ? .keyDown : .keyUp))
                precondition(event.getIntegerValueField(.keyboardEventKeycode) == keyCode)
                precondition(event.getIntegerValueField(.keyboardEventAutorepeat)
                             == (edge.isRepeat ? 1 : 0))
                let appKitEvent = NSEvent(cgEvent: event)!
                precondition(appKitEvent.isARepeat == edge.isRepeat)
                precondition(appKitEvent.keyCode == keyCode)
                precondition(event.flags.isEmpty)
            }
        }
        for (button, code) in [(FixedRemoteButton.volumeUp, NX_KEYTYPE_SOUND_UP),
                               (.volumeDown, NX_KEYTYPE_SOUND_DOWN)] {
            for edge in edges {
                let output = HeldButtonEmitter.makeEvent(button, edge)!
                precondition(output.tap == .cgSessionEventTap)
                let event = NSEvent(cgEvent: output.event)!
                precondition(event.type == .systemDefined && event.subtype.rawValue == 8)
                precondition((event.data1 >> 16) == code)
                precondition(((event.data1 >> 8) & 0xff) == (edge.isDown ? 0xa : 0xb))
                precondition((event.data1 & 1) == (edge.isRepeat ? 1 : 0))
            }
        }
        for button in FixedRemoteButton.allCases where !button.repeatsWhileHeld {
            for edge in edges { precondition(HeldButtonEmitter.makeEvent(button, edge) == nil) }
        }
        print("✓ production held-key encoding: Quartz/AppKit autorepeat, NX volume and release")
    }
}
