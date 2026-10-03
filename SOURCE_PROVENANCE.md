# Source provenance

SiriRemote is a GPL-3.0-only derivative of
[`SiriRemoteForge v0.2.0-beta.8`](https://github.com/HOLODATA-COM/SiriRemoteForge/releases/tag/v0.2.0-beta.8)
at commit `781a738ef3402c3c5eea5e2faa4ae53c9e4ffbc5`.

SiriRemoteForge itself contains code derived from
[`machinarii/hypervibe`](https://github.com/machinarii/hypervibe) commit
`1e7746aabb22636df3f6410fcb2c92bb9e2217ab`. The required MIT notice is kept in
`NOTICE` and in packaged artifacts.

[`HD838A/remote-mic-app`](https://github.com/HD838A/remote-mic-app) commit
`b233a88cc4457b00413dda6b37ec8b4af12c5121` was consulted as a behavioral
reference only. No icon or other proprietary asset was copied.

Typeless behavior was additionally checked against remote-mic-app commit
`764c18a762a36d1ca70a2e9aee90dea96a9f0cf8`: `VoiceFnTapSessionController.swift`
(120 ms paired Fn taps, drain before stop, and cancellation ownership),
`VoiceKeyMode.swift` and `KeyboardInjector.swift` (Right Command keycode 54 with
`maskCommand | NX_DEVICERCMDKEYMASK`, Fn keycode 63 with `maskSecondaryFn`, paired key-up),
`OnboardingFlow.swift` (Typeless bundle identifier), and the preferred-input-source policy
(standalone Typeless does not select a TIS input source). The integration below is independently
implemented on SiriRemote's existing audio lifecycle; no assets or full upstream controller were copied.

Typeless mode chords are a new SiriRemote implementation using the documented
[Translate](https://www.typeless.com/help/quickstart/translate) and
[Ask anything](https://www.typeless.com/help/quickstart/ask-anything) shortcuts (checked 2026-10-04):
Fn + Left Shift / Fn + Space start their respective modes; plain Fn stops both. No Typeless code,
assets, private preferences, or APIs are copied or accessed.

## File-level record

| Files | Origin | Changes in SiriRemote |
| --- | --- | --- |
| `app/RemoteDetector.swift` | Forge `781a738`; HyperVibe lineage | Restricted to VID `0x004C` / PID `0x0315`, one physical remote, multi-interface lifetime and second-remote notice. |
| `app/RemoteInputHandler.swift`, `AppSwitcherKeyLatch.swift` | Forge `781a738`; HyperVibe HID foundation; fixed integration new | Retains safe HID opening, edge deduplication, passive Siri-hold capture and touch guard. Ordinary buttons use a fixed layout; TV owns a paired Command down/up lifetime with left/right navigation and teardown release. Physical centre is Return, while surface tap remains a touch-gated mouse click. Typeless Siri + volume presses are consumed as per-press mode choices before media output. |
| `app/FixedKeyEmitter.swift` | Extracted and reduced from Forge/HyperVibe key emission | Typed emitter for the fixed Return, Delete, arrow and lock-screen actions; string shortcut parsing and arbitrary mappings were removed. |
| `app/TouchHandler.swift`, `CursorController.swift`, `MultitouchSupport.h` | Forge `781a738`; HyperVibe `1e7746a` lineage | Retains touch, pointer acceleration, subpixel movement, multi-display edges, two-finger and circular scrolling; adds independent runtime gates and teardown. |
| `app/MediaController.swift`, `MediaKeyInterceptor.swift`, `MenuBarManager.swift` | Forge `781a738`; HyperVibe lineage | Reduced to the fixed controls and simplified SiriRemote menu. Media interception routes volume chords before whole-hold HID duplicate checks and owns suppressed repeat/up edges via the new Core policy; returns borrowed Quartz events without retaining them. |
| `SiriRemoteCore/Sources/**` | Forge `781a738`, substantially reduced | Provides the settings schema, independent touch gates, held-input safety, permission recovery, multi-interface aggregation and remote-voice state machines. Generic mapping, shortcut and ordinary-button gesture types were removed. |
| `SiriRemoteCore/.../FixedButtonHoldState.swift`, `HeldButtonOutput.swift` and related tests | New implementation | Explicit behavior for all 12 ordinary buttons: release-only toggles/Return, system-timed repeat-downs within one held down/up pair, no catch-up bursts, context-bound cancellation and whole-hold native media suppression. App uses one on-demand timer; no idle repeat polling. Teardown cancels release actions. |
| `app/HeldButtonEmitter.swift`, `script/test_button_events.*` | New implementation | Held keyboard/volume event encoding with Quartz/AppKit or NX autorepeat flags. Platform regression checks construct production events without posting them. |
| `app/ConfigStore.swift`, `SettingsModel.swift`, `SettingsView.swift`, `SettingsWindow.swift` | Forge `781a738`, substantially rewritten | Four settings pages separate permissions, touch/ring controls, fixed button behavior and voice readiness. Configuration persists touch, circular scroll and the voice target; retired mapping/profile files are archived rather than migrated. |
| `app/DoubaoInputSourceCoordinator.swift` | New integration; remote-mic-app `b233a88` reference | Selects the fixed, already-enabled Doubao Pinyin TIS mode and never calls the onboarding-only enable API from a Siri-button event. The selected source intentionally remains active after voice input. |
| `app/VoiceKeyEmitter.swift`, `SiriRemoteCore/.../VoiceKeyLatch.swift` and related tests | New integration; remote-mic-app `b233a88` and `764c18a` behavioral references; chord ownership new | Pairs Doubao Right Command (54, command + right-side flag) and Typeless Fn (63), Left Shift (56) and Space (49). Chords retain cumulative modifier flags and reverse key-up order; partial failures release only owned edges. Constants are checked against macOS SDK headers without posting events. Right Option remains reserved for Doubao hands-free mode. |
| `app/VoiceCoordinator.swift`, `RemoteAudioDemand.swift`, `RemoteAudioState.*`, `SiriRemoteCore/.../VoiceSession.swift` | New integration; Forge audio and remote-mic-app lifecycle references | Shared PTT engine: 300 ms hold threshold, 1.5 s preparation bound, generation checks, pending press during drain, an 80 ms last-frame quiet window bounded at 300 ms and a 750 ms sealed drain. Only Doubao selects an input source. The App receives authenticated XPC counters and never maps PCM. |
| `SiriRemoteCore/.../VoiceTarget.swift`, `VoiceShortcutController.swift`, `RemoteVoiceSession.swift`, `app/TypelessIntegration.swift` and related tests | New implementation; remote-mic-app `764c18a` behavioral reference; mode chords follow Typeless public documentation | Doubao Right Command holds and Typeless 120 ms start chords / plain Fn stops share one serialized controller. Siri + volume selects a mode before recognition starts; queued physical presses keep separate mode state, short chords never send Return. Poll-driven, generation-scoped cleanup and queued-start cancellation prevent delayed events from toggling a following session. Typeless discovery uses only public AppKit APIs. |
| Siri double-tap integration in `RemoteVoiceSession.swift`, `VoiceCoordinator.swift`, `SettingsModel.swift`, `SiriRemoteApp.swift` | New implementation | A 300 ms single-tap window arbitrates Return versus a persisted voice-target switch, never latched recording. Only ready destinations switch while idle; the menu bar stays unchanged and no windows activate. Pending taps cancel on teardown; unchanged config watcher echoes do not interrupt the next hold. |
| `script/test_voice_coordinator.*`; clock and permission seams in `app/VoiceCoordinator.swift` | New implementation | Tests the production App polling/gesture wiring with isolated platform effects. An unavailable recognizer stops recording without erasing single/double-tap state; full input teardown still cancels gestures. Covers switching away from stopped Typeless, destination checks, key release and subsequent recording. |
| `mic/OpusVoiceDecoder.swift`, `mic/router/PklgTailReader.swift`, `VoiceFrameParser.swift` | Forge `781a738` | Retains PacketLogger tailing, ACL/L2CAP/ATT validation, dynamic voice handle and Opus decoding; cloud transcription and monitor playback removed. |
| `mic/router/SiriRemoteMicRouter.swift`, `SiriRemoteMicRingWriter.*` | Forge `781a738`, rewritten | Session-only decoder process and mono-to-stereo writer for the new shared ABI. |
| `mic/captured/srm_captured.c`, `srm_runtime_directory.*` | Forge `781a738`, adapted; runtime policy/tests new | Fixed PacketLogger workflow, protected root-owned Apple-signed snapshot and restrictive capture-file permissions. Authenticated connection-owned leases replace PID-based Darwin demand; revoke audio before asynchronous SIGTERM/reaping, with bounded SIGKILL escalation. Startup prepares silent PCM before serving input clients. |
| `mic/driver/SiriRemoteMic.c`, `SiriRemoteMic.config.h`, `SiriRemoteMicShared.h` | Forge `781a738`; BlackHole basis | Independent identifiers; stereo ABI v2; generation-token and heartbeat-gated single producer; sealed final-frame drain; no fallback ring. Multi-client reads are idempotent; cold attachment retries only on a control queue. Sanitized in-process lifecycle tests complement contract and paced I/O simulations. |
| `app/create_app_bundle.sh`, `script/build_and_run.sh`, `dist/**`, component build scripts | Forge build layout, substantially rewritten | Unified stable Developer ID signing, fail-closed signing, own-component-only package scripts, payload/signature audit, exact HCI preference restoration, root-only randomized rollback storage, pre-activation rollback validation, kernel process identity checks and a bounded native CoreAudio watchdog. |

Files removed from the product include Forge cloud transcription, OpenAI/DeepSeek credentials,
history/dictionary/polishing, Voice HUD, built-in microphone feeder, generic button mapping and
shortcut recording, Layer/App Wheel UI, Sparkle, DriverKit experiments and their media assets.

## Third-party licenses

New security code: `mic/captured/SiriRemoteCaptureIPC.h`, `srm_audio_owner.h`,
`srm_audio_security_test.c`, `srm_capture_auth_test.c`, `mic/driver/SiriRemoteAudioAccess.h`
and `srm_lifecycle_test.c`. PCM is root:_coreaudiod 0660; Security.framework validates actual
XPC message senders against product identifiers and Team ID. Tests use isolated namespaces.
The insecure standalone tone writer and superseded PID-demand policy/tests were removed.

- HyperVibe: MIT, notice in `NOTICE`.
- BlackHole: GPL-3.0, `mic/driver/vendor/BlackHole-LICENSE.txt`.
- Opus: BSD/patent notice, `mic/router/Opus-LICENSE.txt`.
