# A2854 voice pipeline

The product voice path is intentionally narrow:

```text
Apple PacketLogger → session .pklg → PklgTailReader → ACL/L2CAP/ATT parser
→ OpusVoiceDecoder → 48 kHz mono PCM → stereo shared ring → Siri Remote Mic
```

PacketLogger is detected at `/Applications/PacketLogger.app` and is never redistributed. Capture is
started only while a real Siri-button session requests it; idle SiriRemote does not run PacketLogger
or the decoder. There is no built-in microphone feeder, playback monitor, cloud transcription or
standalone speech-to-text service.

The App controls Capture through `com.deanxi.siriremote.capture` XPC. Both sides verify the actual
message sender's code signature (product identifier and Team ID); a claimed PID is never authority.
PCM uses a root-owned `_coreaudiod`-group `0660` ring; the App receives counters, not audio.
On stop/disconnect, Capture revokes the generation first, sends SIGTERM, reaps asynchronously and
only escalates surviving children to SIGKILL after 400 ms. The next producer starts after reaping.
PacketLogger is prewarmed once at service startup, then runs only during a Siri-button lease.

For offline parser work, use Router's `--no-ring --pklg FILE --exit-on-eof`. Production ring writes
require the root service's current `--generation`; there is no independent unprivileged producer.

Component builds:

```sh
cd router && ./build.sh
cd ../driver && ./build.sh
cd ../captured && ./build.sh
```

The full installer owns system installation and rollback. Component-local install scripts are not
part of the supported product workflow.
