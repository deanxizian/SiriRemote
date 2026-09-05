#ifndef SRM_AUDIO_OWNER_H
#define SRM_AUDIO_OWNER_H

#include <fcntl.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <string.h>
#include <sys/mman.h>
#include "../driver/SiriRemoteAudioAccess.h"

static inline uint64_t srm_audio_revoke(SRMSharedMemory *ring)
{
    // Revoke first. An old writer may still publish its OLD token, which cannot become live.
    uint64_t next = atomic_fetch_add_explicit(&ring->generation, 1, memory_order_acq_rel) + 1;
    if (next == 0) next = atomic_fetch_add_explicit(&ring->generation, 1, memory_order_acq_rel) + 1;
    atomic_store_explicit(&ring->producerActive, 0, memory_order_release);
    atomic_store_explicit(&ring->leaseExpiresAt, 0, memory_order_release);
    return next;
}

// Only after the previous producer has been reaped. Keep the same kernel object so clients
// already holding the microphone see the new generation without reopening the device.
static inline uint64_t srm_audio_begin(SRMSharedMemory *ring)
{
    uint64_t next = srm_audio_revoke(ring);
    memset(ring->ring, 0, sizeof(ring->ring));
    atomic_store_explicit(&ring->writeIndex, 0, memory_order_release);
    atomic_store_explicit(&ring->readIndex, 0, memory_order_release);
    atomic_store_explicit(&ring->playbackStartFrame, 0, memory_order_release);
    atomic_store_explicit(&ring->playbackEndFrame, UINT64_MAX, memory_order_release);
    return next;
}

// Called before dispatch/XPC starts threads: temporarily change the effective creation group.
// Darwin POSIX shm does not support fchmod; reject existing objects with unexpected metadata.
static inline SRMSharedMemory *srm_audio_prepare(void)
{
    gid_t group = srm_audio_group();
    if (geteuid() != 0 || group == (gid_t)-1) { errno = EPERM; return NULL; }
    gid_t saved_group = getegid();
    if (setegid(group) != 0) return NULL;
    mode_t saved_mask = umask(0007);
    int fd = shm_open(SRM_SHM_NAME, O_CREAT | O_EXCL | O_RDWR, 0660);
    int created = fd >= 0;
    int create_error = errno;
    umask(saved_mask);
    if (setegid(saved_group) != 0) { if (fd >= 0) close(fd); return NULL; }
    if (fd < 0 && create_error == EEXIST) fd = shm_open(SRM_SHM_NAME, O_RDWR, 0);
    if (fd < 0) return NULL;
    if ((created && ftruncate(fd, sizeof(SRMSharedMemory)) != 0) ||
        srm_audio_validate(fd, 0, group, 0660) != 0) { close(fd); return NULL; }
    SRMSharedMemory *ring = mmap(NULL, sizeof(*ring), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (ring == MAP_FAILED) return NULL;
    if (created) {
        ring->magic = SRM_MAGIC;
        ring->version = SRM_VERSION;
        ring->sampleRate = SRM_SAMPLE_RATE;
        ring->channels = SRM_CHANNELS;
        ring->ringFrames = SRM_RING_FRAMES;
    } else if (ring->magic != SRM_MAGIC || ring->version != SRM_VERSION ||
               ring->sampleRate != SRM_SAMPLE_RATE || ring->channels != SRM_CHANNELS ||
               ring->ringFrames != SRM_RING_FRAMES) {
        munmap(ring, sizeof(*ring));
        errno = EINVAL;
        return NULL;
    }
    srm_audio_begin(ring);
    return ring;
}

#endif
