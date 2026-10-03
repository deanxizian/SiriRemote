import Foundation

/// Tests the App's actual coordinator and poll path, not a second implementation of its wiring.
/// All OS effects are replaced: no real keys, permissions, input sources, capture or audio access.
@MainActor
private enum Effects {
    static var now: TimeInterval = 0
    static var accessibilityGranted = true
    static var typelessRunning = true
    static var doubaoEnabled = true
    static var keyEvents: [VoiceKeyEvent] = []
    static var returnCount = 0
    static var captures: Set<UInt64> = []

    static func reset() {
        now = 0
        accessibilityGranted = true
        typelessRunning = true
        doubaoEnabled = true
        keyEvents = []
        returnCount = 0
        captures = []
    }
}

@MainActor
enum TypelessIntegration {
    static var isRunning: Bool { Effects.typelessRunning }
}

@MainActor
final class DoubaoInputSourceCoordinator {
    var isSelected: Bool { Effects.doubaoEnabled }
    var isAvailable: Bool { Effects.doubaoEnabled }
    func selectDoubao() -> Bool { Effects.doubaoEnabled }
}

@MainActor
enum VoiceKeyEmitter {
    static func post(_ event: VoiceKeyEvent) -> Bool {
        Effects.keyEvents.append(event)
        return true
    }
}

@MainActor
enum FixedKeyEmitter {
    enum Key { case enter }
    static func tap(_ key: Key) { Effects.returnCount += 1 }
}

@MainActor
final class RemoteAudioDemand {
    func begin(session: UInt64) -> Bool {
        Effects.captures.insert(session)
        return true
    }
    func end(session: UInt64) { Effects.captures.remove(session) }
    func seal(session: UInt64, endFrame: UInt64) {}
}

@MainActor
func srm_remote_audio_state(
    _ generation: UnsafeMutablePointer<UInt64>, _ write: UnsafeMutablePointer<UInt64>,
    _ read: UnsafeMutablePointer<UInt64>, _ active: UnsafeMutablePointer<UInt32>,
    _ consumers: UnsafeMutablePointer<UInt32>, _ epoch: UnsafeMutablePointer<UInt64>
) -> Int32 {
    generation.pointee = 1
    write.pointee = 9600
    read.pointee = 9600
    active.pointee = Effects.captures.isEmpty ? 0 : 1
    consumers.pointee = 1
    epoch.pointee = 1
    return 0
}

func srm_remote_audio_state_close() {}
func rmDebug(_ message: String) {}

@main
@MainActor
enum VoiceCoordinatorTests {
    private static var failures = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    private static func makeCoordinator(_ target: VoiceTarget) -> VoiceCoordinator {
        let coordinator = VoiceCoordinator(clock: { Effects.now },
                                           isAccessibilityGranted: { Effects.accessibilityGranted })
        coordinator.setTarget(target)
        return coordinator
    }

    private static func edge(_ coordinator: VoiceCoordinator, _ down: Bool, at time: TimeInterval) {
        Effects.now = time
        coordinator.handleSiri(pressed: down)
    }

    private static func poll(_ coordinator: VoiceCoordinator, at time: TimeInterval) {
        Effects.now = time
        coordinator.poll()
    }

    private static func doubleTap(_ coordinator: VoiceCoordinator, at start: TimeInterval = 0) {
        edge(coordinator, true, at: start)
        poll(coordinator, at: start + 0.02)
        edge(coordinator, false, at: start + 0.05)
        edge(coordinator, true, at: start + 0.10)
        poll(coordinator, at: start + 0.12)
        edge(coordinator, false, at: start + 0.20)
    }

    private static func checkAvailabilityMatrix() {
        for initial in VoiceTarget.allCases {
            for doubao in [false, true] {
                for typeless in [false, true] {
                    Effects.reset()
                    Effects.doubaoEnabled = doubao
                    Effects.typelessRunning = typeless
                    let coordinator = makeCoordinator(initial)
                    var selected = initial
                    var rejected = 0
                    var attempted = 0
                    coordinator.onSwitchVoiceTarget = {
                        attempted += 1
                        if selected.canSwitchToAlternate(doubaoEnabled: Effects.doubaoEnabled,
                                                         typelessRunning: Effects.typelessRunning) {
                            selected = selected.alternate
                            coordinator.setTarget(selected)
                        } else { rejected += 1 }
                    }
                    coordinator.onSwitchVoiceTargetUnavailable = { rejected += 1 }
                    doubleTap(coordinator)
                    let ready = initial.canSwitchToAlternate(doubaoEnabled: doubao,
                                                              typelessRunning: typeless)
                    let context = "\(initial), Doubao=\(doubao), Typeless=\(typeless)"
                    expect(attempted == 1, "switch must reach destination check: \(context)")
                    expect(selected == (ready ? initial.alternate : initial), context)
                    expect(rejected == (ready ? 0 : 1), "unavailable feedback: \(context)")
                    expect(Effects.returnCount == 0, "double tap cannot send Return: \(context)")
                    expect(Effects.keyEvents.isEmpty, "double tap cannot start recognition: \(context)")
                    expect(Effects.captures.isEmpty, "double tap must end capture: \(context)")
                    coordinator.shutdown()
                }
            }
        }
    }

    private static func checkSingleTapAndHoldWhenTypelessIsUnavailable() {
        for held in [false, true] {
            Effects.reset()
            Effects.typelessRunning = false
            let coordinator = makeCoordinator(.typeless)
            var switches = 0
            coordinator.onSwitchVoiceTarget = { switches += 1 }
            edge(coordinator, true, at: 0)
            poll(coordinator, at: 0.02)
            edge(coordinator, false, at: held ? 0.5 : 0.05)
            // Exercise the real pending-tap Timer too. Effects use the injected clock and mocks;
            // the short run-loop wait never sends Return to the user's foreground application.
            Effects.now = 1
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            expect(Effects.returnCount == (held ? 0 : 1), "unavailable recognizer preserves tap/hold")
            expect(switches == 0, "one physical press cannot switch")
            expect(Effects.keyEvents.isEmpty, "unavailable recognizer cannot receive shortcuts")
            expect(Effects.captures.isEmpty, "unavailable recognizer must stop capture")
            coordinator.shutdown()
        }
    }

    private static func checkExitDuringVoiceThenSwitchAndRecord() {
        for exitAt in [0.33, 0.50] {
            Effects.reset()
            let coordinator = makeCoordinator(.typeless)
            var selected = VoiceTarget.typeless
            coordinator.onSwitchVoiceTarget = {
                selected = selected.alternate
                coordinator.setTarget(selected)
            }
            edge(coordinator, true, at: 0)
            poll(coordinator, at: 0.3)
            poll(coordinator, at: 0.32)
            if exitAt > 0.44 { poll(coordinator, at: 0.44) }
            Effects.typelessRunning = false
            poll(coordinator, at: exitAt)
            poll(coordinator, at: exitAt + 0.13)
            expect(Effects.captures.isEmpty, "Typeless exit ends capture")
            expect(Effects.keyEvents.map(\.key) == [.function, .function],
                   "Typeless exit releases Fn without another start")
            expect(Effects.keyEvents.map(\.isDown) == [true, false], "Fn remains paired")
            edge(coordinator, false, at: 0.8)
            doubleTap(coordinator, at: 1)
            expect(selected == .doubao, "can switch after Typeless exits mid-session")
            edge(coordinator, true, at: 1.21)
            poll(coordinator, at: 1.51)
            poll(coordinator, at: 1.53)
            edge(coordinator, false, at: 2)
            poll(coordinator, at: 2.1)
            expect(Array(Effects.keyEvents.suffix(2)).map(\.key) == [.rightCommand, .rightCommand],
                   "next hold uses Doubao")
            expect(Array(Effects.keyEvents.suffix(2)).map(\.isDown) == [true, false],
                   "next hold releases Right Command")
            expect(Effects.returnCount == 0, "recording failure cannot become Return")
            expect(Effects.captures.isEmpty, "next hold finishes capture")
            coordinator.shutdown()
        }
    }

    private static func checkFullAbortStillCancelsGestures() {
        for reason in ["permission", "disconnect", "sleep", "configuration"] {
            Effects.reset()
            let coordinator = makeCoordinator(.typeless)
            var switches = 0
            coordinator.onSwitchVoiceTarget = { switches += 1 }
            edge(coordinator, true, at: 0)
            edge(coordinator, false, at: 0.05)
            if reason == "permission" {
                Effects.accessibilityGranted = false
                poll(coordinator, at: 0.06)
                Effects.accessibilityGranted = true
            } else { coordinator.abort(reason: reason) }
            edge(coordinator, true, at: 0.1)
            poll(coordinator, at: 0.12)
            edge(coordinator, false, at: 0.2)
            expect(switches == 0, "\(reason) must discard the first tap")
            coordinator.shutdown()
            Effects.now = 1
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            expect(Effects.returnCount == 0, "shutdown cancels deferred Return after \(reason)")
            expect(Effects.keyEvents.isEmpty, "abort cannot emit recognizer shortcuts")
            expect(Effects.captures.isEmpty, "abort ends capture")
        }
    }

    static func main() {
        checkAvailabilityMatrix()
        checkSingleTapAndHoldWhenTypelessIsUnavailable()
        checkExitDuringVoiceThenSwitchAndRecord()
        checkFullAbortStillCancelsGestures()
        guard failures == 0 else { exit(1) }
        print("✓ production VoiceCoordinator: availability, double tap, single tap, exit and teardown")
    }
}
