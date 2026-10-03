import Foundation

/// The selected recognizer changes only input preparation and the shortcut, not audio capture.
public enum VoiceTarget: String, Codable, CaseIterable, Sendable {
    case doubao
    case typeless

    public var requiresInputSourceSelection: Bool { self == .doubao }

    public var triggerKey: VoiceTriggerKey { self == .doubao ? .rightCommand : .function }
}

/// macOS virtual key codes and event flags, kept independent of event posting for safe tests.
public enum VoiceTriggerKey: Equatable, Sendable {
    case rightCommand
    case function

    public var keyCode: UInt16 {
        switch self {
        case .rightCommand: return 0x36 // kVK_RightCommand
        case .function: return 0x3F // kVK_Function
        }
    }

    public var downFlagsRawValue: UInt64 {
        switch self {
        case .rightCommand: return 0x00100010 // maskCommand | NX_DEVICERCMDKEYMASK
        case .function: return 0x00800000 // maskSecondaryFn
        }
    }
}
