#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include "srm_audio_owner.h"
#include "SiriRemoteCaptureIPC.h"

int main(void)
{
    SRMSharedMemory *ring = calloc(1, sizeof(*ring));
    assert(ring);
    uint64_t old = srm_audio_begin(ring);
    atomic_store(&ring->producerActive, old);
    atomic_store(&ring->writeIndex, 9600);
    ring->ring[0] = 0.4f;
    assert(srm_audio_active(ring));
    srm_audio_revoke(ring);
    assert(!srm_audio_active(ring));
    atomic_store(&ring->producerActive, old); // a late writer after cancellation/SIGKILL
    assert(!srm_audio_active(ring));
    uint64_t replacement = srm_audio_begin(ring);
    assert(replacement != old && atomic_load(&ring->writeIndex) == 0 && ring->ring[0] == 0);
    atomic_store(&ring->producerActive, replacement);
    uint64_t expected = old;
    assert(!atomic_compare_exchange_strong(&ring->producerActive, &expected, 0));
    assert(srm_audio_active(ring)); // old cleanup cannot revoke the replacement
    free(ring);

    char name[32];
    snprintf(name, sizeof name, "/srm-security-%d", getpid());
    int fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
    assert(fd >= 0 && ftruncate(fd, sizeof(SRMSharedMemory)) == 0);
    struct stat info;
    assert(fstat(fd, &info) == 0);
    if (srm_audio_validate(fd, geteuid(), getegid(), 0600) != 0)
        fprintf(stderr, "shm metadata uid=%u gid=%u mode=%o size=%lld; expected %u:%u 600 %zu\n",
                info.st_uid, info.st_gid, info.st_mode & 0777, (long long)info.st_size,
                geteuid(), getegid(), sizeof(SRMSharedMemory));
    assert(srm_audio_validate(fd, geteuid(), getegid(), 0600) == 0);
    assert(srm_audio_validate(fd, geteuid() + 1, getegid(), 0600) != 0);
    assert(srm_audio_validate(fd, geteuid(), getegid(), 0666) != 0);
    assert(srm_audio_validate(fd, geteuid(), getegid() + 1, 0600) != 0);
    close(fd);
    shm_unlink(name);

    xpc_object_t forged = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(forged, "pid", getpid());
    xpc_dictionary_set_string(forged, "identifier", "com.deanxi.siriremote");
    xpc_dictionary_set_string(forged, "team", "96M7FW2XLU");
    assert(!srm_message_is_authorized(forged, SRM_APP_REQUIREMENT));
    xpc_release(forged);
    puts("audio ownership, revocation, generation and forged-identity tests: PASS");
    return 0;
}
