//
//  SiriRemoteMicRingWriter.c
//
#include "SiriRemoteMicRingWriter.h"

#include <errno.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "../driver/SiriRemoteMicShared.h"
#include "../driver/SiriRemoteAudioAccess.h"

static int gFileDescriptor = -1;
static SRMSharedMemory *gShared = NULL;
static uint64_t gWriteIndex = 0;
static uint64_t gGeneration = 0;
static dispatch_source_t gParentWatch;
static char gLastError[256] = {0};

static void set_error(const char *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    (void)vsnprintf(gLastError, sizeof(gLastError), format, arguments);
    va_end(arguments);
}

int srm_ring_writer_open(uint64_t generation)
{
    if (gShared != NULL) { return 0; }

    const int descriptor = shm_open(SRM_SHM_NAME, O_RDWR, 0);
    if (descriptor < 0)
    {
        set_error("shm_open(%s): %s", SRM_SHM_NAME, strerror(errno));
        return -1;
    }

    if (generation == 0 || srm_audio_validate(descriptor, 0, srm_audio_group(), 0660) != 0)
    {
        set_error("fstat(%s): %s", SRM_SHM_NAME, strerror(errno));
        close(descriptor);
        return -1;
    }

    SRMSharedMemory *shared = mmap(NULL, sizeof(*shared), PROT_READ | PROT_WRITE,
                                   MAP_SHARED, descriptor, 0);
    if (shared == MAP_FAILED)
    {
        set_error("mmap(%s): %s", SRM_SHM_NAME, strerror(errno));
        close(descriptor);
        return -1;
    }

    if (shared->magic != SRM_MAGIC || shared->version != SRM_VERSION ||
        atomic_load_explicit(&shared->generation, memory_order_acquire) != generation) {
        set_error("capture generation was revoked");
        munmap(shared, sizeof(*shared));
        close(descriptor);
        return -1;
    }

    gFileDescriptor = descriptor;
    gShared = shared;
    gWriteIndex = 0;
    gGeneration = generation;
    gLastError[0] = '\0';
    return 0;
}

void srm_ring_writer_set_active(int active)
{
    if (gShared != NULL)
    {
        if (active) {
            atomic_store_explicit(&gShared->producerActive, gGeneration, memory_order_release);
        } else {
            uint64_t expected = gGeneration;
            atomic_compare_exchange_strong_explicit(&gShared->producerActive, &expected, 0,
                                                    memory_order_acq_rel, memory_order_acquire);
        }
    }
}

int srm_ring_writer_write_int16(const int16_t *samples, size_t frameCount)
{
    if (gShared == NULL || samples == NULL ||
        atomic_load_explicit(&gShared->generation, memory_order_acquire) != gGeneration)
    {
        set_error("ring writer is not open");
        return -1;
    }

    for (size_t frame = 0; frame < frameCount; ++frame)
    {
        const uint64_t absoluteFrame = gWriteIndex + frame;
        const uint32_t slot = (uint32_t)(absoluteFrame % SRM_RING_FRAMES);
        const float sample = (float)samples[frame] / 32768.0f;
        const size_t offset = (size_t)slot * SRM_CHANNELS;
        gShared->ring[offset] = sample;
        gShared->ring[offset + 1] = sample;
    }

    gWriteIndex += frameCount;
    atomic_store_explicit(&gShared->writeIndex, gWriteIndex, memory_order_release);
    return 0;
}

uint64_t srm_ring_writer_write_index(void)
{
    return gWriteIndex;
}

const char *srm_ring_writer_last_error(void)
{
    return gLastError;
}

void srm_ring_writer_close(void)
{
    if (gShared != NULL)
    {
        srm_ring_writer_set_active(0);
        munmap(gShared, sizeof(*gShared));
        gShared = NULL;
    }
    if (gFileDescriptor >= 0)
    {
        close(gFileDescriptor);
        gFileDescriptor = -1;
    }
    gWriteIndex = 0;
}

static void signal_cleanup(int signalNumber)
{
    if (gShared != NULL)
    {
        srm_ring_writer_set_active(0);
    }
    _exit(128 + signalNumber);
}

void srm_ring_writer_install_signal_cleanup(void)
{
    struct sigaction action = {0};
    action.sa_handler = signal_cleanup;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;
    (void)sigaction(SIGINT, &action, NULL);
    (void)sigaction(SIGTERM, &action, NULL);
    (void)sigaction(SIGHUP, &action, NULL);
    pid_t parent = getppid();
    if (parent <= 1) signal_cleanup(SIGTERM);
    gParentWatch = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)parent,
                                          DISPATCH_PROC_EXIT,
                                          dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    if (gParentWatch) {
        dispatch_source_set_event_handler(gParentWatch, ^{ signal_cleanup(SIGTERM); });
        dispatch_resume(gParentWatch);
    }
}
