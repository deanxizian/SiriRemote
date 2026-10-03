# Contributing

SiriRemote intentionally supports one hardware target and one fixed control layout. Before opening
a change, please keep the scope aligned with the boundaries in `README.md` and explain any proposed
expansion in an issue first.

## Development checks

Run the portable checks before submitting a pull request:

```sh
swift test --package-path SiriRemoteCore
bash script/test_button_events.sh
bash script/test_voice_coordinator.sh
(cd app && ./build.sh && ./SiriRemote --verify-config)
(cd mic && ./build-test.sh)
(cd mic/captured && SIRIREMOTE_COMPILE_ONLY=1 ./build.sh)
(cd mic/driver && SIRIREMOTE_COMPILE_ONLY=1 ./build.sh)
(cd mic/router && SIRIREMOTE_COMPILE_ONLY=1 ./build.sh)
```

The App build links Apple's private `MultitouchSupport.framework`, so it must run on macOS. Hardware
and permission behavior cannot be exercised in GitHub Actions and must be described in the pull
request when tested locally.

HAL tests load the bundle in-process with private user-only shared memory, including sanitized
cold-attach, revoked-generation and sealed-drain regressions. Never point fixtures at production
PCM. Capture tests exercise kernel XPC message identity and reject forged product metadata. The
production `VoiceSession`, `VoiceShortcutController` and `VoiceKeyLatch` are the same implementations
compiled into the App, not test-only models. Tests cover Doubao's Right Command hold and Typeless's
start chords / plain Fn stop taps without posting real keyboard events. Chord tests check modifier
flags, reverse-order key-up, partial-failure cleanup and per-press mode isolation.
Siri gesture tests cover the 300 ms single/double-tap window, target switching without Return or
recognizer shortcuts, a held second tap, busy/unavailable destinations, and teardown cancellation.
A double-tap save uses the picker's setting; a file-watcher echo of unchanged configuration must
not abort the immediately following hold. Physical tests still need both configured voice apps.
`script/test_voice_coordinator.sh` also compiles the actual App coordinator with a deterministic
clock and isolated platform effects. It exercises its real polling path, including an unavailable
current Typeless app, both destination-readiness combinations, single taps, held presses, app exit
during recognition, and full teardown. Only recording ends when the recognizer is unavailable;
permission loss/disconnect/sleep/configuration changes still cancel the physical gestures too.
These tests do not post input, access the user's audio, or require Accessibility permission.
Media-key regressions exercise NX-before-HID and NX-only chord delivery, plus owned repeat/up
suppression after Siri release. These pure tests do not prove physical event-tap behavior; also
check on a remote that the system volume HUD never appears during a Typeless volume chord.
`FixedButtonHoldState` covers all 12 ordinary buttons: release-only toggles/Return, injected system
repeat timing, full-hold media suppression and cancellation without triggering release actions.
`HeldButtonOutput` tests one down, repeat-downs and one up, including context and teardown cleanup.
`bash script/test_button_events.sh` checks the production Quartz/AppKit and NX event encoding without
posting input; it also runs during local test deployment and CI. Check physical mute/play holds
separately: no state change before release, one change on release, and a new press must work. Test
held directions in the target player (including Bilibili web); unit tests cannot prove its seek
behavior. Never test lock-screen actions or destructive key repeats in the user's documents.
Changes to shared ABI or Capture control require a full component install, not an App-only reload.

Official local deployments and packages require the maintainer's stable Developer ID identity.
Never replace that workflow with ad-hoc signing in a release change. Contributors without that
identity can still run the source and Core checks above.

## Pull requests

- Keep changes focused and include tests for pure state-machine behavior.
- Treat every synthetic key or mouse down as an owned resource with a guaranteed teardown path.
- Do not add PacketLogger, captured Bluetooth traffic, proprietary icons, credentials, or generated
  App/PKG artifacts to the repository.
- Update `SOURCE_PROVENANCE.md` when code is copied or substantially adapted from another project.
- Preserve the notices in `LICENSE`, `NOTICE`, and the component-specific license files.
