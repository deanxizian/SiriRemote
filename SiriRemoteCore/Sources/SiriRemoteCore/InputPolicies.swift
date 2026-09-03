import Foundation

/// Keeps the two surface switches independent: ordinary touch controls never depend on the
/// circular-scroll switch, and the outer ring never depends on the ordinary touch switch.
public struct TouchFeaturePolicy: Equatable, Sendable {
    public enum Input: Sendable {
        case pointerOrGesture
        case circularScroll
        case physicalButton
    }

    public var touchEnabled: Bool
    public var circularScrollEnabled: Bool

    public init(touchEnabled: Bool, circularScrollEnabled: Bool) {
        self.touchEnabled = touchEnabled
        self.circularScrollEnabled = circularScrollEnabled
    }

    public func permits(_ input: Input) -> Bool {
        switch input {
        case .pointerOrGesture: return touchEnabled
        case .circularScroll: return circularScrollEnabled
        case .physicalButton: return true
        }
    }
}

/// Pure edge state shared by real held inputs such as Fn. The platform adapter decides whether an
/// OS event was posted successfully; state changes only after that succeeds.
public struct HeldInputLatch: Equatable, Sendable {
    public private(set) var isHeld = false

    public init() {}

    /// Returns true only when the caller must emit a new down/up edge.
    public func needsTransition(to wanted: Bool) -> Bool { isHeld != wanted }

    public mutating func commit(_ held: Bool) { isHeld = held }
}

/// Tracks whether this process owns a synthetic left-button down edge. The platform adapter uses
/// this to avoid both duplicate downs and an unrelated mouse-up when the user is physically holding
/// a real mouse button. Teardown emits an up only when this latch says SiriRemote owns the down.
public struct SyntheticMouseButtonLatch: Equatable, Sendable {
    public private(set) var isDown = false

    public init() {}

    public mutating func beginDown() -> Bool {
        guard !isDown else { return false }
        isDown = true
        return true
    }

    public mutating func endUp() -> Bool {
        guard isDown else { return false }
        isDown = false
        return true
    }
}

/// Pure permission/capability edge policy. Accessibility supplies both event posting and event
/// listening, but macOS can keep IOHID's effective ListenEvent result stale for the lifetime of a
/// process that launched while Accessibility was disabled. In that exact transition the only
/// reliable recovery is one controlled App relaunch.
public struct PermissionGrantState: Equatable, Sendable {
    public var accessibilityGranted: Bool
    public var hidInputAvailable: Bool

    public init(accessibilityGranted: Bool, hidInputAvailable: Bool) {
        self.accessibilityGranted = accessibilityGranted
        self.hidInputAvailable = hidInputAvailable
    }
}

public enum PermissionRecoveryAction: Equatable, Sendable {
    case stopAccessibilityInput
    case startAccessibilityInput
    case stopHIDInput
    case startHIDInput
    case relaunchForStaleHIDAuthorization
}

public struct PermissionRecoveryPolicy: Equatable, Sendable {
    private var previous: PermissionGrantState
    private var requestedRelaunch = false

    public init(initial: PermissionGrantState) {
        previous = initial
    }

    public mutating func update(
        _ current: PermissionGrantState
    ) -> [PermissionRecoveryAction] {
        var actions: [PermissionRecoveryAction] = []

        if previous.accessibilityGranted != current.accessibilityGranted {
            actions.append(current.accessibilityGranted
                ? .startAccessibilityInput
                : .stopAccessibilityInput)
        }
        if previous.hidInputAvailable != current.hidInputAvailable {
            actions.append(current.hidInputAvailable ? .startHIDInput : .stopHIDInput)
        }

        // This is the observed macOS failure mode: the App starts while Accessibility is off,
        // reports ListenEvent as denied, then Accessibility becomes live but IOHID stays denied
        // until process launch. Relaunch exactly once; the new process starts with a fresh TCC view
        // and cannot loop because its initial state produces no edge.
        if !previous.accessibilityGranted,
           current.accessibilityGranted,
           !current.hidInputAvailable,
           !requestedRelaunch {
            requestedRelaunch = true
            actions.append(.relaunchForStaleHIDAuthorization)
        }

        previous = current
        return actions
    }
}
