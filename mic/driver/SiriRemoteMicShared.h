// Shared-memory ABI between the A2854 decoder and SiriRemoteAudio.driver.
//
// Audio is 48 kHz, stereo-interleaved Float32. The router is the only audio
// producer. The HAL plug-in is the only reader and publishes lightweight
// progress counters so the App can finish a push-to-talk session without
// cutting off the final decoded frames.
#ifndef SIRI_REMOTE_MIC_SHARED_H
#define SIRI_REMOTE_MIC_SHARED_H

#include <stdint.h>
#include <stdatomic.h>

// POSIX names on macOS must start with '/' and remain short.
#define SRM_SHM_NAME     "/SiriRemoteAudio_v2"
#define SRM_MAGIC        0x53524131u   // 'SRA1'
#define SRM_VERSION      2u
#define SRM_SAMPLE_RATE  48000u
#define SRM_CHANNELS     2u
#define SRM_RING_FRAMES  65536u

typedef struct {
    uint32_t          magic;
    uint32_t          version;
    uint32_t          sampleRate;
    uint32_t          channels;
    uint32_t          ringFrames;
    uint32_t          _reserved;

    // Supervisor-owned generation/lease/end; Router owns active token and PCM write progress.
    _Atomic uint64_t  generation;
    // The active value is a generation token, not a boolean. A revoked/late writer can never
    // reactivate a newer generation, even if it races the supervisor's cancellation.
    _Atomic uint64_t  producerActive;
    _Atomic uint64_t  writeIndex;
    _Atomic uint64_t  playbackEndFrame; // UINT64_MAX until the owner seals the tail
    _Atomic uint64_t  leaseExpiresAt;   // mach absolute time; silence if the supervisor dies

    // Consumer-owned state. These are diagnostics/drain signals only; audio
    // rendering remains a pure function of CoreAudio's input sample time.
    _Atomic uint64_t  readIndex;
    _Atomic uint32_t  consumerCount;
    _Atomic uint32_t  _consumerPad;
    _Atomic uint64_t  startIOEpoch;
    _Atomic uint64_t  playbackStartFrame;

    float             ring[SRM_RING_FRAMES * SRM_CHANNELS];
} SRMSharedMemory;

#endif /* SIRI_REMOTE_MIC_SHARED_H */
