import Foundation

struct VoiceSequenceTracker {
    enum Decision: Equatable {
        case first
        case next
        case duplicate
        case conceal(Int)
        case discontinuity
    }

    private var previous: UInt16?

    mutating func observe(_ sequence: UInt16) -> Decision {
        guard let previous else {
            self.previous = sequence
            return .first
        }
        let distance = Int(sequence &- previous)
        if distance == 0 { return .duplicate }
        self.previous = sequence
        if distance == 1 { return .next }
        if distance <= 10 { return .conceal(distance - 1) }
        return .discontinuity
    }
}
