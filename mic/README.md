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

Component builds:

```sh
cd router && ./build.sh
cd ../driver && ./build.sh
cd ../captured && ./build.sh
```

The full installer owns system installation and rollback. Component-local install scripts are not
part of the supported product workflow.
