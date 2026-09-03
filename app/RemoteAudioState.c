#include "RemoteAudioState.h"

#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stddef.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "../mic/driver/SiriRemoteMicShared.h"

static SRMSharedMemory *gRemote = NULL;

static int attach_remote(void)
{
    if (gRemote != NULL) return 0;
    int descriptor = shm_open(SRM_SHM_NAME, O_RDONLY, 0);
    if (descriptor < 0) return -1;
    struct stat info = {0};
    if (fstat(descriptor, &info) != 0 || info.st_size < (off_t)sizeof(SRMSharedMemory)) {
        close(descriptor);
        return -1;
    }
    void *mapping = mmap(NULL, sizeof(SRMSharedMemory), PROT_READ, MAP_SHARED, descriptor, 0);
    close(descriptor);
    if (mapping == MAP_FAILED) return -1;
    gRemote = (SRMSharedMemory *)mapping;
    return 0;
}

static int valid_remote(void)
{
    return gRemote != NULL &&
        gRemote->magic == SRM_MAGIC &&
        gRemote->version == SRM_VERSION &&
        gRemote->sampleRate == SRM_SAMPLE_RATE &&
        gRemote->channels == SRM_CHANNELS &&
        gRemote->ringFrames == SRM_RING_FRAMES;
}

int srm_remote_audio_state(uint64_t *generation,
                           uint64_t *write_index,
                           uint64_t *read_index,
                           uint32_t *producer_active,
                           uint32_t *consumer_count,
                           uint64_t *start_io_epoch)
{
    if (generation == NULL || write_index == NULL || read_index == NULL ||
        producer_active == NULL || consumer_count == NULL || start_io_epoch == NULL) return -1;
    *generation = 0;
    *write_index = 0;
    *read_index = 0;
    *producer_active = 0;
    *consumer_count = 0;
    *start_io_epoch = 0;
    if (attach_remote() != 0 || !valid_remote()) return -1;
    *generation = atomic_load_explicit(&gRemote->generation, memory_order_acquire);
    *write_index = atomic_load_explicit(&gRemote->writeIndex, memory_order_acquire);
    *read_index = atomic_load_explicit(&gRemote->readIndex, memory_order_acquire);
    *producer_active = atomic_load_explicit(&gRemote->producerActive, memory_order_acquire);
    *consumer_count = atomic_load_explicit(&gRemote->consumerCount, memory_order_acquire);
    *start_io_epoch = atomic_load_explicit(&gRemote->startIOEpoch, memory_order_acquire);
    return 0;
}

void srm_remote_audio_state_close(void)
{
    if (gRemote == NULL) return;
    munmap(gRemote, sizeof(SRMSharedMemory));
    gRemote = NULL;
}
