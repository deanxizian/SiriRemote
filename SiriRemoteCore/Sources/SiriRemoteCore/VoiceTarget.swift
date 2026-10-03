import Foundation

/// The selected recognizer changes only input preparation and the shortcut, not audio capture.
public enum VoiceTarget: String, Codable, CaseIterable, Sendable {
    case doubao
    case typeless

    public var requiresInputSourceSelection: Bool { self == .doubao }

    public var alternate: Self { self == .doubao ? .typeless : .doubao }

    /// The platform adapter supplies a fresh enabled-input-source / running-App snapshot. This
    /// deliberately does not claim to inspect either third-party app's private shortcut settings.
    public func canSwitchToAlternate(doubaoEnabled: Bool, typelessRunning: Bool) -> Bool {
        alternate == .doubao ? doubaoEnabled : typelessRunning
    }
}

public enum TypelessVoiceMode: String, CaseIterable, Sendable {
    case dictate, translate, askAnything
}

public enum VoiceVolumeButton: Hashable, Sendable {
    case up, down
}

/// A complete recognizer shortcut, distinct from the individual physical keys used to emit it.
public enum VoiceShortcut: Equatable, Sendable {
    case doubao
    case typeless(TypelessVoiceMode)

    public init(target: VoiceTarget, mode: TypelessVoiceMode = .dictate) {
        self = target == .doubao ? .doubao : .typeless(mode)
    }

    public var target: VoiceTarget {
        if case .doubao = self { return .doubao }
        return .typeless
    }

    /// Modifiers precede a character key; release reverses this order. In particular, Ask Anything
    /// must never send an unmodified Space into the user's selected text.
    public var keys: [VoiceTriggerKey] {
        switch self {
        case .doubao: return [.rightCommand]
        case .typeless(.dictate): return [.function]
        case .typeless(.translate): return [.leftShift, .function]
        case .typeless(.askAnything): return [.function, .space]
        }
    }

    /// Typeless ends all three modes with plain Fn, not a repeat of the mode's start chord.
    public var stopShortcut: VoiceShortcut {
        target == .doubao ? .doubao : .typeless(.dictate)
    }
}

/// macOS virtual key codes and event flags, kept independent of event posting for safe tests.
public enum VoiceTriggerKey: Equatable, Sendable {
    case rightCommand
    case function
    case leftShift
    case space

    public var keyCode: UInt16 {
        switch self {
        case .rightCommand: return 0x36 // kVK_RightCommand
        case .function: return 0x3F // kVK_Function
        case .leftShift: return 0x38 // kVK_Shift
        case .space: return 0x31 // kVK_Space
        }
    }

    public var downFlagsRawValue: UInt64 {
        switch self {
        case .rightCommand: return 0x00100010 // maskCommand | NX_DEVICERCMDKEYMASK
        case .function: return 0x00800000 // maskSecondaryFn
        case .leftShift: return 0x00020002 // maskShift | NX_DEVICELSHIFTKEYMASK
        case .space: return 0
        }
    }
}
