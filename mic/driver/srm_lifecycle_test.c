// In-process HAL regressions. Private, user-only IPC; no installed device or service is used.
#include <CoreAudio/AudioServerPlugIn.h>
#include <assert.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "../captured/srm_audio_owner.h"

static OSStatus props(AudioServerPlugInHostRef h, AudioObjectID o, UInt32 n,
                      const AudioObjectPropertyAddress *a)
{ (void)h; (void)o; (void)n; (void)a; return noErr; }
static OSStatus copy(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef *d)
{ (void)h; (void)k; *d = NULL; return noErr; }
static OSStatus write_property(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef d)
{ (void)h; (void)k; (void)d; return noErr; }
static OSStatus remove_property(AudioServerPlugInHostRef h, CFStringRef k)
{ (void)h; (void)k; return noErr; }
static OSStatus config(AudioServerPlugInHostRef h, AudioObjectID d, UInt64 a, void *i)
{ (void)h; (void)d; (void)a; (void)i; return noErr; }
static const AudioServerPlugInHostInterface host = {props, copy, write_property, remove_property, config};
static float output[512 * SRM_CHANNELS];

static void read_audio(AudioServerPlugInDriverRef driver, unsigned time, float expected)
{
    AudioServerPlugInIOCycleInfo cycle = {0};
    cycle.mInputTime.mSampleTime = time;
    cycle.mInputTime.mFlags = kAudioTimeStampSampleTimeValid;
    memset(output, 0x55, sizeof output);
    assert((*driver)->DoIOOperation(driver, 3, 4, 1, kAudioServerPlugInIOOperationReadInput,
                                   512, &cycle, output, NULL) == noErr);
    for (size_t i = 0; i < sizeof output / sizeof output[0]; ++i) {
        if (output[i] != expected)
            fprintf(stderr, "sample time=%u index=%zu got=%f expected=%f\n", time, i, output[i], expected);
        assert(output[i] == expected);
    }
}

static uint64_t publish(SRMSharedMemory *ring, float sample, unsigned frames)
{
    uint64_t generation = srm_audio_begin(ring);
    for (unsigned i = 0; i < frames * SRM_CHANNELS; ++i) ring->ring[i] = sample;
    atomic_store(&ring->writeIndex, frames);
    atomic_store(&ring->leaseExpiresAt, UINT64_MAX);
    atomic_store(&ring->producerActive, generation);
    return generation;
}

int main(int argc, char **argv)
{
    assert(argc == 2);
    char suffix[16], name[32];
    snprintf(suffix, sizeof suffix, ".t%d", getpid());
    snprintf(name, sizeof name, "%s%s", SRM_SHM_NAME, suffix);
    assert(setenv("SRM_IPC_SUFFIX", suffix, 1) == 0);
    void *bundle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!bundle) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    typedef void *(*Factory)(CFAllocatorRef, CFUUIDRef);
    Factory factory = (Factory)dlsym(bundle, "BlackHole_Create");
    assert(factory);
    AudioServerPlugInDriverRef driver = factory(NULL, kAudioServerPlugInTypeUUID);
    assert(driver && (*driver)->Initialize(driver, &host) == noErr);
    assert((*driver)->StartIO(driver, 3, 1) == noErr);
    read_audio(driver, 0, 0); // microphone open BEFORE the ring exists

    int fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
    assert(fd >= 0 && ftruncate(fd, sizeof(SRMSharedMemory)) == 0);
    SRMSharedMemory *ring = mmap(NULL, sizeof(*ring), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    assert(ring != MAP_FAILED);
    close(fd);
    ring->magic = SRM_MAGIC;
    ring->version = SRM_VERSION;
    ring->sampleRate = SRM_SAMPLE_RATE;
    ring->channels = SRM_CHANNELS;
    ring->ringFrames = SRM_RING_FRAMES;
    uint64_t first = publish(ring, 0.25f, 10000);
    for (unsigned i = 0; i < 200 && !atomic_load(&ring->consumerCount); ++i) usleep(5000);
    assert(atomic_load(&ring->consumerCount) == 1);
    assert(atomic_load(&ring->startIOEpoch) == 1);
    read_audio(driver, 512, 0.25f); // no second StartIO was required
    uint64_t consumed = atomic_load(&ring->readIndex);
    read_audio(driver, 512, 0.25f);
    assert(atomic_load(&ring->readIndex) == consumed); // same host window is idempotent

    atomic_store(&ring->leaseExpiresAt, 0); // helper crash: even cached audio must be silent
    read_audio(driver, 512, 0);
    atomic_store(&ring->leaseExpiresAt, UINT64_MAX);
    read_audio(driver, 1024, 0.25f);
    consumed = atomic_load(&ring->readIndex);
    atomic_store(&ring->playbackEndFrame, consumed);
    read_audio(driver, 1536, 0);
    read_audio(driver, 2048, 0);
    assert(atomic_load(&ring->readIndex) == consumed); // never claim to drain unwritten audio

    srm_audio_revoke(ring); // owner revokes BEFORE graceful exit / eventual SIGKILL
    atomic_store(&ring->producerActive, first); // dying old producer's late store
    read_audio(driver, 1024, 0); // previously cached window must not replay
    assert((*driver)->StopIO(driver, 3, 1) == noErr);
    assert((*driver)->StartIO(driver, 3, 1) == noErr);
    read_audio(driver, 0, 0); // reopen cannot replay the prior session's 500 ms tail

    publish(ring, -0.25f, 512); // a sealed short final fragment must bypass the prime gate
    atomic_store(&ring->playbackEndFrame, 512);
    read_audio(driver, 512, -0.25f);
    read_audio(driver, 1024, 0);
    assert(atomic_load(&ring->readIndex) == 512);
    assert((*driver)->StopIO(driver, 3, 1) == noErr);
    assert(atomic_load(&ring->consumerCount) == 0);
    munmap(ring, sizeof(*ring));
    shm_unlink(name);
    // Keep the bundle loaded until process exit: dispatch may still be releasing a canceled timer.
    puts("HAL cold attach, lease expiry, stale-generation silence, sealed drain: PASS (ASan/UBSan)");
    return 0;
}
