# Siri Remote Mic HAL plug-in

`SiriRemoteAudio.driver` publishes one input-only CoreAudio device:

```text
Display name:  Siri Remote Mic
Bundle ID:     com.deanxi.siriremote.audio.driver
Device UID:    com.deanxi.siriremote.audio.device.v1
Format:        48 kHz, Float32, 2-channel interleaved input
Transport:     USB
Shared memory: /SiriRemoteAudio_v2 (root:_coreaudiod, 0660)
```

Decoded mono A2854 samples are copied to left and right. With no remote producer, the HAL returns
silence. It does not open the built-in microphone, change the default input, crossfade a fallback,
or expose an output stream. Each first-client `StartIO` begins a new, seeded device timeline;
delayed zero-timestamp queries catch up directly instead of making CoreAudio busy-loop through
missed periods.

Capture creates the initially silent ABI v2 ring before accepting authenticated XPC sessions.
The App never maps PCM; it receives only counters over XPC. Router and HAL validate ownership,
permissions and the page-rounded ABI size before mapping. A generation-token producer lease and
a 500 ms supervisor heartbeat prevent old PCM from becoming active after cancellation or a crash.
If CoreAudio opens first, a control-queue timer retries attachment; ReadInput never opens/maps IPC.
The timer stops once attached or when the last consumer closes.

`./build.sh` builds the bundle and runs contract, multi-client I/O and ASan/UBSan lifecycle tests.
All fixtures use separate user-only IPC namespaces. The old production-ring tone writer was removed.
`SIRIREMOTE_COMPILE_ONLY=1 ./build.sh` builds/tests without signing or installing (CI only). Installing a
HAL plug-in affects the system audio host; use only the full installer, whose bounded native
watchdog rolls back after three consecutive one-second intervals at or above 85% CoreAudio CPU.

The implementation descends from the Forge HAL target and BlackHole. See
`../../SOURCE_PROVENANCE.md` and `vendor/BlackHole-LICENSE.txt`.
