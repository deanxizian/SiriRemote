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
| `app/DoubaoVoiceCoordinator.swift`, `RemoteAudioDemand.swift`, `RemoteAudioState.*`, `SiriRemoteCore/.../RemoteVoiceSession.swift` | New integration using Forge audio ABI | Implements 200 ms promotion after real Ring audio, remote-mic-app-style held Fn lifecycle, generation checks, readiness timeout, 80 ms tail and read-index drain. A session selects Doubao at most once, waits a one-shot 250 ms propagation delay before Fn down, and never changes the input source on Fn up. |
| `mic/OpusVoiceDecoder.swift`, `mic/router/PklgTailReader.swift`, `VoiceFrameParser.swift` | Forge `781a738` | Retains PacketLogger tailing, ACL/L2CAP/ATT validation, dynamic voice handle and Opus decoding; cloud transcription and monitor playback removed. |
| `mic/router/SiriRemoteMicRouter.swift`, `SiriRemoteMicRingWriter.*` | Forge `781a738`, rewritten | Session-only decoder process and mono-to-stereo writer for the new shared ABI. |
| `mic/captured/srm_captured.c`, `srm_capture_demand.h`, `srm_capture_demand_test.c`, `srm_runtime_directory.*` | Forge `781a738`, adapted; demand/runtime policy and tests new | On-demand fixed PacketLogger workflow, SiriRemote-only paths/notifications and restrictive runtime permissions. The service recreates its secure volatile runtime directory after every boot, publishes live process health and runs only a root-owned local snapshot whose Apple signature and identity are revalidated before each spawn. Signed App/CLI identities refresh that snapshot after Apple updates; heavy capture follows only the App's live-PID Siri-button lease. |
| `mic/driver/SiriRemoteMic.c`, `SiriRemoteMic.config.h`, `SiriRemoteMicShared.h` | Forge `781a738`; BlackHole basis | New bundle/device identifiers and stereo ABI; remote producer only, silence when absent, no built-in fallback or second ring; multi-client reads publish one idempotent read cursor. New IO sessions advance the CoreAudio timeline seed and delayed timestamp queries catch up without spinning. |
| `app/create_app_bundle.sh`, `script/build_and_run.sh`, `dist/**`, component build scripts | Forge build layout, substantially rewritten | Unified stable Developer ID signing, fail-closed signing, own-component-only package scripts, payload/signature audit, exact HCI preference restoration, root-only randomized rollback storage, pre-activation rollback validation, kernel process identity checks and a bounded native CoreAudio watchdog. |

Files removed from the product include Forge cloud transcription, OpenAI/DeepSeek credentials,
history/dictionary/polishing, Voice HUD, built-in microphone feeder, generic button mapping and
shortcut recording, Layer/App Wheel UI, Sparkle, DriverKit experiments and their media assets.

## Third-party licenses

- HyperVibe: MIT, notice in `NOTICE`.
- BlackHole: GPL-3.0, `mic/driver/vendor/BlackHole-LICENSE.txt`.
- Opus: BSD/patent notice, `mic/router/Opus-LICENSE.txt`.
