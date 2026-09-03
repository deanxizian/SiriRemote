/// Tracks the HID interfaces belonging to the one selected physical A2854.
public struct RemoteInterfaceRegistry<Key: Hashable> {
    public private(set) var interfaces: Set<Key> = []
    public init() {}
    public var count: Int { interfaces.count }
    public var isConnected: Bool { !interfaces.isEmpty }

    @discardableResult public mutating func add(_ key: Key) -> Bool {
        interfaces.insert(key).inserted
    }
    @discardableResult public mutating func remove(_ key: Key) -> Bool {
        interfaces.remove(key) != nil
    }
    public mutating func removeAll() { interfaces.removeAll() }
}

public enum SharedButtonTransition: Equatable {
    case duplicate
    case sourceOnly
    case globalDown
    case globalUp
}

/// Collapses duplicated logical button edges across A2854's HID interfaces. A logical release is
/// emitted only after the last interface holding that button releases or disappears.
public struct MultiRemoteButtonState<Source: Hashable, Button: Hashable> {
    private var heldBySource: [Source: Set<Button>] = [:]
    public init() {}

    public var heldButtons: Set<Button> {
        heldBySource.values.reduce(into: Set<Button>()) { $0.formUnion($1) }
    }

    public func isPressed(_ button: Button) -> Bool {
        heldBySource.values.contains { $0.contains(button) }
    }

    public mutating func update(source: Source, button: Button,
                                pressed: Bool) -> SharedButtonTransition {
        let sourceWasPressed = heldBySource[source]?.contains(button) == true
        guard sourceWasPressed != pressed else { return .duplicate }
        let wasGloballyPressed = isPressed(button)
        if pressed {
            heldBySource[source, default: []].insert(button)
        } else {
            heldBySource[source]?.remove(button)
            if heldBySource[source]?.isEmpty == true { heldBySource[source] = nil }
        }
        let isGloballyPressed = isPressed(button)
        guard wasGloballyPressed != isGloballyPressed else { return .sourceOnly }
        return isGloballyPressed ? .globalDown : .globalUp
    }

    public mutating func removeSource(_ source: Source) -> Set<Button> {
        guard let removed = heldBySource.removeValue(forKey: source) else { return [] }
        return Set(removed.filter { !isPressed($0) })
    }

    public mutating func removeAll() { heldBySource.removeAll() }
}
