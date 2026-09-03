# Siri Remote Mic HAL plug-in

`SiriRemoteAudio.driver` publishes one input-only CoreAudio device:

```text
Display name:  Siri Remote Mic
Bundle ID:     com.deanxi.siriremote.audio.driver
Device UID:    com.deanxi.siriremote.audio.device.v1
Format:        48 kHz, Float32, 2-channel interleaved input
Transport:     USB
Shared memory: /SiriRemoteAudio_v1
```

Decoded mono A2854 samples are copied to left and right. With no remote producer, the HAL returns
silence. It does not open the built-in microphone, change the default input, crossfade a fallback,
or expose an output stream. Each first-client `StartIO` begins a new, seeded device timeline;
delayed zero-timestamp queries catch up directly instead of making CoreAudio busy-loop through
missed periods.

`./build.sh` builds the bundle and runs the process-local contract and I/O simulations. Installing a
HAL plug-in affects the system audio host; use only the full installer, whose bounded native
watchdog rolls back after three consecutive one-second intervals at or above 85% CoreAudio CPU.

The implementation descends from the Forge HAL target and BlackHole. See
`../../SOURCE_PROVENANCE.md` and `vendor/BlackHole-LICENSE.txt`.
