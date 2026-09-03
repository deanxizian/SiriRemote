// Non-real-time snapshot of the remote microphone shared-memory contract.
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

#endif
