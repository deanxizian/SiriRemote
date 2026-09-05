// Non-real-time authenticated capture control and cached diagnostics. No PCM access in the App.
#ifndef SIRI_REMOTE_AUDIO_STATE_H
#define SIRI_REMOTE_AUDIO_STATE_H

#include <stdint.h>

int srm_remote_audio_state(uint64_t *generation,
                           uint64_t *write_index,
                           uint64_t *read_index,
                           uint32_t *producer_active,
                           uint32_t *consumer_count,
                           uint64_t *start_io_epoch);
void srm_remote_audio_state_close(void);
int srm_capture_set_active(int active, uint64_t session);
void srm_capture_seal(uint64_t session, uint64_t end_frame);
// Bounded, read-only CLI diagnostic. Never call from the App's UI/event loop.
int srm_capture_check_service(void);

#endif
