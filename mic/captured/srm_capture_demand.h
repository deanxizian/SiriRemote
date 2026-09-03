#ifndef SRM_CAPTURE_DEMAND_H
#define SRM_CAPTURE_DEMAND_H

#include <stdint.h>

// Opening Siri Remote Mic is not a request to wake Bluetooth capture. Input methods may keep the
// CoreAudio device open indefinitely, including while no physical Siri-button session exists.
// Only the App-owned, live-PID voice lease is allowed to run PacketLogger and the decoder.
static inline int srm_capture_should_run(uint64_t virtual_consumers,
                                         int voice_owner_pid,
                                         int voice_owner_alive)
{
    (void)virtual_consumers;
    return voice_owner_pid > 0 && voice_owner_alive;
}

#endif
