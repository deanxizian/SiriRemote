#ifndef SIRI_REMOTE_AUDIO_ACCESS_H
#define SIRI_REMOTE_AUDIO_ACCESS_H

#include <errno.h>
#include <grp.h>
#include <sys/stat.h>
#include <unistd.h>
#include "SiriRemoteMicShared.h"

// Production PCM is owned by root and accessible only to the CoreAudio service group.
// The UI obtains counters over authenticated XPC and never maps this object.
static inline gid_t srm_audio_group(void)
{
    struct group *group = getgrnam("_coreaudiod");
    return group ? group->gr_gid : (gid_t)-1;
}

static inline int srm_audio_validate(int fd, uid_t owner, gid_t group, mode_t mode)
{
    struct stat info;
    if (fstat(fd, &info) != 0) return -1;
    // Darwin reports POSIX shm lengths rounded up to the host VM page size.
    const size_t page = (size_t)getpagesize();
    const off_t size = (off_t)((sizeof(SRMSharedMemory) + page - 1) / page * page);
    if (info.st_uid != owner || info.st_gid != group ||
        (info.st_mode & 0777) != mode || info.st_size != size) {
        errno = EPERM;
        return -1;
    }
    return 0;
}

static inline int srm_audio_active(const SRMSharedMemory *shared)
{
    uint64_t generation = atomic_load_explicit(&shared->generation, memory_order_acquire);
    return generation != 0 && atomic_load_explicit(&shared->producerActive,
                                                   memory_order_acquire) == generation;
}

#endif
