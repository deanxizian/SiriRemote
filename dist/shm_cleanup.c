#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

int main(void)
{
    if (shm_unlink("/SiriRemoteAudio_v1") == 0 || errno == ENOENT) return 0;
    fprintf(stderr, "SiriRemote shared-memory cleanup failed: %s\n", strerror(errno));
    return 1;
}
