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

## File-level record

| Files | Origin | Changes in SiriRemote |
| --- | --- | --- |
| `app/RemoteDetector.swift` | Forge `781a738`; HyperVibe lineage | Restricted to VID `0x004C` / PID `0x0315`, one physical remote, multi-interface lifetime and second-remote notice. |
| `app/RemoteInputHandler.swift`, `AppSwitcherKeyLatch.swift` | Forge `781a738`; HyperVibe HID foundation; fixed integration new | Retains safe HID opening, edge deduplication, passive Siri-hold capture and touch guard. Ordinary buttons use a fixed layout; TV owns a paired Command down/up lifetime with left/right navigation and teardown release. Physical centre is Return, while surface tap remains a touch-gated mouse click. |
| `app/FixedKeyEmitter.swift` | Extracted and reduced from Forge/HyperVibe key emission | Typed emitter for the fixed Return, Delete, arrow and lock-screen actions; string shortcut parsing and arbitrary mappings were removed. |
| `app/TouchHandler.swift`, `CursorController.swift`, `MultitouchSupport.h` | Forge `781a738`; HyperVibe `1e7746a` lineage | Retains touch, pointer acceleration, subpixel movement, multi-display edges, two-finger and circular scrolling; adds independent runtime gates and teardown. |
| `app/MediaController.swift`, `MediaKeyInterceptor.swift`, `MenuBarManager.swift` | Forge `781a738`; HyperVibe lineage | Reduced to the fixed controls and simplified SiriRemote menu. |
| `SiriRemoteCore/Sources/**` | Forge `781a738`, substantially reduced | Provides the settings schema, independent touch gates, held-input safety, permission recovery, multi-interface aggregation and remote-voice state machines. Generic mapping, shortcut and ordinary-button gesture types were removed. |
| `app/ConfigStore.swift`, `SettingsModel.swift`, `SettingsView.swift`, `SettingsWindow.swift` | Forge `781a738`, substantially rewritten | Four settings pages separate permissions, touch/ring controls, fixed button behavior and voice readiness. Configuration persists only touch and circular-scroll settings; retired mapping/profile files are archived rather than migrated. |
| `app/DoubaoInputSourceCoordinator.swift` | New integration; remote-mic-app `b233a88` reference | Selects the fixed, already-enabled Doubao Pinyin TIS mode and never calls the onboarding-only enable API from a Siri-button event. The selected source intentionally remains active after voice input. |
| `app/FunctionKeyLatch.swift` | New integration; remote-mic-app `b233a88` reference | Idempotent CGEvent keycode 63 + `maskSecondaryFn` hold: one down when the voice session becomes ready and one up after teardown/drain. |
| `app/DoubaoVoiceCoordinator.swift`, `RemoteAudioDemand.swift`, `RemoteAudioState.*`, `SiriRemoteCore/.../DoubaoVoiceSession.swift` | New integration; Forge audio and remote-mic-app lifecycle references | Production testable PTT engine: shared 300 ms hold threshold, 1.5 s preparation bound, one input-source selection, paired Fn, generation checks, pending press during drain, an 80 ms last-frame quiet window bounded at 300 ms and a 750 ms sealed drain. The App only receives authenticated XPC counters and never maps PCM. |
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
