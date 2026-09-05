#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

int main(void)
{
    const char *names[] = { "/SiriRemoteAudio_v1", "/SiriRemoteAudio_v2" };
    int failed = 0;
    for (unsigned i = 0; i < sizeof names / sizeof names[0]; ++i) {
        if (shm_unlink(names[i]) != 0 && errno != ENOENT) {
            fprintf(stderr, "SiriRemote shared-memory cleanup failed: %s\n", strerror(errno));
            failed = 1;
        }
    }
    return failed;
}
