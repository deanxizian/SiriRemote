//
//  srm_io_sim.c
//
//  Offline coreaudiod-style IO simulator for the Siri Remote Mic HAL plug-in. Loads the
//  bundle in-process (like srm_driver_contract_test), feeds the shared-memory rings paced at
//  exactly 48 kHz on absolute mach deadlines (like the real producers), and drives StartIO →
//  per-cycle GetZeroTimeStamp + Begin/ReadInput/End at a real 512-frame cadence. Nothing is
//  installed and coreaudiod is never contacted.
//
//  Signals are chosen so every output frame attributes its source by SIGN:
//    REMOTE ring   positive triangle in [+0.2, +0.7]   (the router: writes only while the
//                                                       Siri button streams)
//    IGNORED ring  negative triangle in [-0.7, -0.2]   (proves unrelated audio is ignored)
//    silence       exactly 0.0f
//  Both triangles share slope and amplitude span, so one splice threshold covers everything,
//  and any served sample off the ±[0.2,0.7] lattice is manufactured, never real.
//
//  Three phases, one driver instance (fresh StartIO session each):
//    1. REMOTE STEADY   the original coverage: continuity, idempotency under a second client,
//                       a +0.5 s host resync jump, no full-scale garbage, device clock rate.
//                       The ignored ring does not exist.
//    2. REMOTE GAP,     the router stops writing mid-session and later resumes while the
//       SINGLE SOURCE   ignored ring is absent: queued remote tail drains, the rest of the gap
//                       is exact silence, and the remote must come back.
//    3. SOURCE FILTER   an unrelated ring runs throughout; output must remain silent unless the
//                       A2854 ring is live.
//
#include <CoreAudio/AudioServerPlugIn.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "SiriRemoteMicShared.h"

enum {
    kObjectID_Device = 3,
    kObjectID_Stream_Input = 4,

    kRate = 48000,
    kCycleFrames = 512,          // coreaudiod-typical IO quantum
    kChunkFrames = 480,          // producers write 10 ms chunks, like the real cadence
    kTrianglePeriod = 960,       // frames; slope = 2*span/period per frame
    kExpectedPreRollFrames = 24000, // mirror the driver's 500 ms input-source settle reserve
    kExpectedPrimeFrames = 4800,    // mirror the driver's 100 ms jitter gate
};
#define kIgnoredBuiltinName "/SiriRemoteIgnored"
#define kNoCycle 0x7fffffffu
static const double kTriSpan = 0.5;  // |hi - lo| of both triangles

static mach_timebase_info_data_t gTimebase;
static uint64_t ns_to_ticks(uint64_t ns) { return ns * gTimebase.denom / gTimebase.numer; }

// ------------------------------------------------------------------ producers (stand-ins)
typedef struct {
    const char       *name;
    float             lo, hi;
    SRMSharedMemory  *shm;
    pthread_t         thread;
    _Atomic int       stop;
    _Atomic int       writing;   // 0 = paced but not writing (remote: button released)
    uint64_t          written;   // total frames; persists (and freezes) across writing gaps
    float             phase;     // 0..kTrianglePeriod
    int               started;
} SimProducer;

// The sim runs on a machine where the REAL pipeline may be live (installed plug-in in
// coreaudiod, supervisor daemon, producers). SRM_IPC_SUFFIX moves the loaded driver's shm
// rings AND its consumers notification into this private namespace so the simulation never
// wakes the real supervisor and nothing external ever touches these rings.
#define kSimSuffix ".sim"
static SimProducer gRemoteProducer  = { .name = SRM_SHM_NAME kSimSuffix,
                                        .lo = 0.2f,  .hi = 0.7f  };
static SimProducer gIgnoredProducer = { .name = kIgnoredBuiltinName kSimSuffix,
                                        .lo = -0.7f, .hi = -0.2f };

static void *producer_main(void *arg)
{
    SimProducer *p = arg;
    const uint64_t t0 = mach_absolute_time();
    const double chunkNs = (double)kChunkFrames / kRate * 1e9;
    uint64_t chunkCount = 0;
    while (!atomic_load_explicit(&p->stop, memory_order_relaxed))
    {
        if (atomic_load_explicit(&p->writing, memory_order_relaxed))
        {
            for (uint32_t i = 0; i < kChunkFrames; ++i)
            {
                const float half = kTrianglePeriod / 2.0f;
                const float frac = p->phase < half ? (p->phase / half) : (2.0f - p->phase / half);
                const uint32_t slot = (uint32_t)((p->written + i) % SRM_RING_FRAMES);
                const float sample = p->lo + (p->hi - p->lo) * frac;
                for (uint32_t channel = 0; channel < SRM_CHANNELS; ++channel)
                {
                    p->shm->ring[(size_t)slot * SRM_CHANNELS + channel] = sample;
                }
                p->phase += 1.0f;
                if (p->phase >= (float)kTrianglePeriod) { p->phase -= (float)kTrianglePeriod; }
            }
            p->written += kChunkFrames;
            atomic_store_explicit(&p->shm->writeIndex, p->written, memory_order_release);
        }
        ++chunkCount;
        mach_wait_until(t0 + ns_to_ticks((uint64_t)(chunkNs * (double)chunkCount)));
    }
    return NULL;
}

static int producer_open(SimProducer *p)
{
    const mode_t previousMask = umask(0);
    int fd = shm_open(p->name, O_CREAT | O_RDWR, 0600);
    umask(previousMask);
    if (fd < 0) { perror("shm_open"); return -1; }
    struct stat info = {0};
    if (fstat(fd, &info) != 0) { perror("fstat"); close(fd); return -1; }
    if (info.st_size == 0 && ftruncate(fd, (off_t)sizeof(SRMSharedMemory)) != 0)
    {
        perror("ftruncate"); close(fd); return -1;
    }
    p->shm = mmap(NULL, sizeof(*p->shm), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p->shm == MAP_FAILED) { perror("mmap"); p->shm = NULL; return -1; }
    atomic_store_explicit(&p->shm->producerActive, 0, memory_order_release);
    const uint64_t oldGeneration =
        (p->shm->magic == SRM_MAGIC && p->shm->version == SRM_VERSION)
            ? atomic_load_explicit(&p->shm->generation, memory_order_acquire)
            : 0;
    p->shm->magic = SRM_MAGIC;
    p->shm->version = SRM_VERSION;
    p->shm->sampleRate = SRM_SAMPLE_RATE;
    p->shm->channels = SRM_CHANNELS;
    p->shm->ringFrames = SRM_RING_FRAMES;
    memset(p->shm->ring, 0, sizeof(p->shm->ring));
    atomic_store_explicit(&p->shm->writeIndex, 0, memory_order_release);
    atomic_store_explicit(&p->shm->readIndex, 0, memory_order_release);
    atomic_store_explicit(&p->shm->playbackStartFrame, 0, memory_order_release);
    atomic_store_explicit(&p->shm->generation, oldGeneration + 1, memory_order_release);
    atomic_store_explicit(&p->shm->producerActive, oldGeneration + 1, memory_order_release);
    atomic_store_explicit(&p->shm->playbackEndFrame, UINT64_MAX, memory_order_release);
    atomic_store_explicit(&p->shm->leaseExpiresAt, UINT64_MAX, memory_order_release);
    p->written = 0;
    p->phase = 0.0f;
    return 0;
}

static int producer_start(SimProducer *p, int writingInitially)
{
    if (producer_open(p) != 0) { return -1; }
    atomic_store_explicit(&p->stop, 0, memory_order_relaxed);
    atomic_store_explicit(&p->writing, writingInitially, memory_order_relaxed);
    if (pthread_create(&p->thread, NULL, producer_main, p) != 0)
    {
        perror("pthread_create");
        return -1;
    }
    p->started = 1;
    return 0;
}

// A producer marked active is not necessarily primed: pthread_create may return before the new
// thread publishes its first 10 ms chunk. Phase 3 models an unrelated producer already running
// when CoreAudio opens a fresh input session, so wait for a small real backlog instead of
// letting host scheduling decide whether the beginning of that session is silent. This does not
// weaken any stream assertion; it makes the fixture establish the state its comment promises.
static int producer_wait_for_frames(SimProducer *p, uint64_t minimumFrames)
{
    const uint64_t deadline = mach_absolute_time() + ns_to_ticks(500000000ULL);
    while (atomic_load_explicit(&p->shm->writeIndex, memory_order_acquire) < minimumFrames)
    {
        if (mach_absolute_time() >= deadline)
        {
            fprintf(stderr, "io sim: %s did not prime %llu frames before the deadline\n",
                    p->name, (unsigned long long)minimumFrames);
            return -1;
        }
        usleep(1000);
    }
    return 0;
}

static void producer_finish(SimProducer *p)
{
    if (p->started)
    {
        atomic_store_explicit(&p->stop, 1, memory_order_relaxed);
        pthread_join(p->thread, NULL);
        p->started = 0;
    }
    if (p->shm != NULL)
    {
        atomic_store_explicit(&p->shm->producerActive, 0, memory_order_release);
    }
}

// ---------------------------------------------------------------------------- fake host
static OSStatus host_props(AudioServerPlugInHostRef h, AudioObjectID o, UInt32 n,
                           const AudioObjectPropertyAddress *a)
{ (void)h; (void)o; (void)n; (void)a; return noErr; }
static OSStatus host_copy(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef *d)
{ (void)h; (void)k; *d = NULL; return noErr; }
static OSStatus host_write(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef d)
{ (void)h; (void)k; (void)d; return noErr; }
static OSStatus host_delete(AudioServerPlugInHostRef h, CFStringRef k)
{ (void)h; (void)k; return noErr; }
static OSStatus host_config(AudioServerPlugInHostRef h, AudioObjectID d, UInt64 a, void *i)
{ (void)h; (void)d; (void)a; (void)i; return noErr; }
static const AudioServerPlugInHostInterface kFakeHost = {
    host_props, host_copy, host_write, host_delete, host_config
};

// ------------------------------------------------------------------------------- analysis
static unsigned gFailures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { \
    fprintf(stderr, "io sim: FAIL: "); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); \
    ++gFailures; } } while (0)

typedef struct {
    size_t silent, fullScale, discontinuities, transitions;
    size_t firstDiscontinuity;
    Float32 beforeDiscontinuity, afterDiscontinuity;
} StreamStats;

// Splice/garbage scan. Exact 0.0f is served silence; steps out of / into silence are legal
// (underrun edges and gate boundaries). Any other sample-to-sample step above 8x the triangle
// slope is a splice, which catches position jumps while accepting the producer waveform.
static StreamStats analyze_stream(const Float32 *x, size_t total)
{
    const double slope = 2.0 * kTriSpan / (double)kTrianglePeriod;
    const double discontinuityThreshold = 8.0 * slope;
    StreamStats s = {
        .firstDiscontinuity = SIZE_MAX,
    };
    for (size_t i = 0; i < total; ++i)
    {
        const Float32 v = x[i * SRM_CHANNELS];
        for (uint32_t channel = 1; channel < SRM_CHANNELS; ++channel)
        {
            CHECK(x[i * SRM_CHANNELS + channel] == v,
                  "stereo channels differ at frame %zu", i);
        }
        if (v == 0.0f) { ++s.silent; continue; }
        if (fabsf(v) >= 0.999f) { ++s.fullScale; }
        if (i > 0)
        {
            const Float32 p = x[(i - 1) * SRM_CHANNELS];
            if (p == 0.0f) { ++s.transitions; continue; }     // silence boundary: allowed
            if (fabs((double)v - (double)p) > discontinuityThreshold)
            {
                if (s.firstDiscontinuity == SIZE_MAX)
                {
                    s.firstDiscontinuity = i;
                    s.beforeDiscontinuity = p;
                    s.afterDiscontinuity = v;
                }
                ++s.discontinuities;
            }
        }
    }
    return s;
}

// Assert a window is owned by one source: no wrong-sign samples at all, expected-sign samples
// on the producer's amplitude lattice, and at most (1-minFraction) transient-underrun zeros.
static void check_sign_window(const char *phase, const char *label, const Float32 *x,
                              size_t fromFrame, size_t toFrame, int wantPositive,
                              double minFraction)
{
    size_t wrongSign = 0, expected = 0, zeros = 0, offLattice = 0;
    for (size_t i = fromFrame; i < toFrame; ++i)
    {
        const Float32 v = x[i * SRM_CHANNELS];
        if (v == 0.0f) { ++zeros; continue; }
        if ((v > 0.0f) != (wantPositive != 0)) { ++wrongSign; continue; }
        ++expected;
        const double magnitude = fabs((double)v);
        if (magnitude < 0.19 || magnitude > 0.71) { ++offLattice; }
    }
    const size_t total = toFrame - fromFrame;
    CHECK(wrongSign == 0, "%s %s: %zu wrong-source samples in [%zu,%zu)",
          phase, label, wrongSign, fromFrame, toFrame);
    CHECK(offLattice == 0, "%s %s: %zu samples off the producer amplitude lattice",
          phase, label, offLattice);
    CHECK((double)expected >= minFraction * (double)total,
          "%s %s: only %zu of %zu samples from the expected source (zeros=%zu)",
          phase, label, expected, total, zeros);
}

static void check_all_silent(const char *phase, const char *label, const Float32 *x,
                             size_t fromFrame, size_t toFrame)
{
    size_t nonZero = 0, firstAt = SIZE_MAX, lastAt = 0;
    for (size_t i = fromFrame; i < toFrame; ++i)
    {
        if (x[i * SRM_CHANNELS] != 0.0f)
        {
            ++nonZero;
            if (firstAt == SIZE_MAX) { firstAt = i; }
            lastAt = i;
        }
    }
    CHECK(nonZero == 0,
          "%s %s: %zu non-silent samples in [%zu,%zu) first=%zu(%.4f) last=%zu(%.4f)",
          phase, label, nonZero, fromFrame, toFrame,
          firstAt, firstAt != SIZE_MAX ? (double)x[firstAt * SRM_CHANNELS] : 0.0,
          lastAt, (double)x[lastAt * SRM_CHANNELS]);
}

static size_t first_sample_with_sign(const Float32 *x, size_t fromFrame, size_t toFrame,
                                     int wantPositive)
{
    for (size_t i = fromFrame; i < toFrame; ++i)
    {
        const Float32 value = x[i * SRM_CHANNELS];
        if (value != 0.0f && (value > 0.0f) == (wantPositive != 0)) { return i; }
    }
    return SIZE_MAX;
}

// ------------------------------------------------------------------------------ phase run
typedef struct {
    const char *name;
    unsigned    totalCycles;
    unsigned    jumpAtCycle;       // kNoCycle = no resync jump
    unsigned    jumpFrames;
    int         primeRemoteAfterStart;
    int         primeIgnoredAfterStart;
    unsigned    remoteStartCycle;  // kNoCycle = leave the writer gate untouched
    unsigned    remoteStopCycle;
    unsigned    remoteResumeCycle;
    // outputs
    Float32    *stream;            // totalCycles * kCycleFrames, allocated by run_phase
    unsigned    idemMismatches;
    unsigned    comparedWindows;
    unsigned    firstIdemMismatchCycle;
    unsigned    firstIdemMismatchFrame;
    Float32     firstIdemValueA, firstIdemValueB;
    double      wrapRate;
} PhaseRun;

static int run_phase(AudioServerPlugInDriverRef driver, PhaseRun *run)
{
    run->stream = calloc((size_t)run->totalCycles * kCycleFrames * SRM_CHANNELS,
                         sizeof(Float32));
    if (run->stream == NULL) { fprintf(stderr, "io sim: out of memory\n"); return -1; }
    run->idemMismatches = 0;
    run->comparedWindows = 0;
    run->firstIdemMismatchCycle = kNoCycle;
    run->firstIdemMismatchFrame = 0;
    run->wrapRate = 0;

    const uint64_t epochBefore = atomic_load_explicit(
        &gRemoteProducer.shm->startIOEpoch, memory_order_acquire);
    OSStatus status = (*driver)->StartIO(driver, kObjectID_Device, 1);
    CHECK(status == noErr, "%s: StartIO status=%d", run->name, (int)status);
    if (status != noErr) { return -1; }
    CHECK(atomic_load_explicit(&gRemoteProducer.shm->consumerCount, memory_order_acquire) == 1,
          "%s: shared consumerCount did not become 1", run->name);
    CHECK(atomic_load_explicit(&gRemoteProducer.shm->startIOEpoch, memory_order_acquire)
              == epochBefore + 1,
          "%s: startIOEpoch did not advance exactly once", run->name);

    if (run->primeRemoteAfterStart)
    {
        const uint64_t afterStart =
            atomic_load_explicit(&gRemoteProducer.shm->writeIndex, memory_order_acquire);
        if (producer_wait_for_frames(&gRemoteProducer,
                                     afterStart + 10 * kChunkFrames) != 0)
        {
            return -1;
        }
    }
    if (run->primeIgnoredAfterStart)
    {
        // StartIO deliberately parks the reader at the producer's current write index so a new
        // session never replays old microphone audio. Establish ten fresh 10 ms chunks after
        // that reset before advancing the simulated CoreAudio timeline. Without this handshake,
        // host thread scheduling (rather than the driver) decides whether phase 3's fixed startup
        // window contains enough audio to prove this unrelated producer is ignored. The extra
        // margin keeps an overloaded CI host from starving the fixture during assertions.
        const uint64_t afterStart =
            atomic_load_explicit(&gIgnoredProducer.shm->writeIndex, memory_order_acquire);
        if (producer_wait_for_frames(&gIgnoredProducer,
                                     afterStart + 10 * kChunkFrames) != 0)
        {
            return -1;
        }
    }

    Float32 bufferB[kCycleFrames * SRM_CHANNELS];

    // Zero-timestamp wrap timing: record wall ticks at each sample-time advance.
    Float64 lastZtsSample = -1.0;
    uint64_t firstWrapTicks = 0, lastWrapTicks = 0;
    Float64 firstWrapSample = 0, lastWrapSample = 0;

    const uint64_t t0 = mach_absolute_time();
    const double cycleNs = (double)kCycleFrames / kRate * 1e9;

    for (unsigned k = 0; k < run->totalCycles; ++k)
    {
        if (k == run->remoteStartCycle)
        {
            atomic_store_explicit(&gRemoteProducer.shm->producerActive,
                atomic_load_explicit(&gRemoteProducer.shm->generation, memory_order_acquire),
                memory_order_release);
            atomic_store_explicit(&gRemoteProducer.writing, 1, memory_order_release);
        }
        if (k == run->remoteStopCycle)
        { atomic_store_explicit(&gRemoteProducer.writing, 0, memory_order_release); }
        if (k == run->remoteResumeCycle)
        { atomic_store_explicit(&gRemoteProducer.writing, 1, memory_order_release); }

        mach_wait_until(t0 + ns_to_ticks((uint64_t)(cycleNs * (double)(k + 1))));

        Float64 ztsSample = 0; UInt64 ztsHost = 0, seed = 0;
        status = (*driver)->GetZeroTimeStamp(driver, kObjectID_Device, 1,
                                             &ztsSample, &ztsHost, &seed);
        CHECK(status == noErr, "%s: GetZeroTimeStamp status=%d", run->name, (int)status);
        if (ztsSample != lastZtsSample)
        {
            lastZtsSample = ztsSample;
            lastWrapTicks = mach_absolute_time();
            lastWrapSample = ztsSample;
            if (firstWrapTicks == 0 && ztsSample > 0)
            {
                firstWrapTicks = lastWrapTicks;
                firstWrapSample = ztsSample;
            }
        }

        AudioServerPlugInIOCycleInfo cycle;
        memset(&cycle, 0, sizeof(cycle));
        cycle.mIOCycleCounter = k + 1;
        cycle.mNominalIOBufferFrameSize = kCycleFrames;
        const Float64 inputTime = (Float64)((uint64_t)k * kCycleFrames
            + ((run->jumpAtCycle != kNoCycle && k >= run->jumpAtCycle) ? run->jumpFrames : 0));
        cycle.mInputTime.mSampleTime = inputTime;
        cycle.mInputTime.mHostTime = mach_absolute_time();
        cycle.mInputTime.mFlags = kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid;
        cycle.mCurrentTime = cycle.mInputTime;

        // Snapshot the producers around the double read: if a chunk lands between the two
        // reads, the second may legitimately serve a longer leading edge, so only quiescent
        // window pairs are compared for idempotency.
        const uint64_t remoteBefore =
            atomic_load_explicit(&gRemoteProducer.shm->writeIndex, memory_order_acquire);
        const uint64_t ignoredBefore = (gIgnoredProducer.shm != NULL)
            ? atomic_load_explicit(&gIgnoredProducer.shm->writeIndex, memory_order_acquire) : 0;

        (*driver)->BeginIOOperation(driver, kObjectID_Device, 1,
                                    kAudioServerPlugInIOOperationReadInput, kCycleFrames, &cycle);
        Float32 *outA = run->stream + (size_t)k * kCycleFrames * SRM_CHANNELS;
        status = (*driver)->DoIOOperation(driver, kObjectID_Device, kObjectID_Stream_Input, 1,
                                          kAudioServerPlugInIOOperationReadInput, kCycleFrames,
                                          &cycle, outA, NULL);
        CHECK(status == noErr, "%s: ReadInput A status=%d cycle=%u", run->name, (int)status, k);
        const uint64_t readAfterA = atomic_load_explicit(
            &gRemoteProducer.shm->readIndex, memory_order_acquire);

        // Client 2: the host reads the SAME timeline window again. Contractually this must
        // return the same audio. Compare only fully-served windows (no silence anywhere) so
        // a legitimate leading-edge underrun between the two calls is not miscounted.
        memset(bufferB, 0x55, sizeof(bufferB));
        status = (*driver)->DoIOOperation(driver, kObjectID_Device, kObjectID_Stream_Input, 2,
                                          kAudioServerPlugInIOOperationReadInput, kCycleFrames,
                                          &cycle, bufferB, NULL);
        CHECK(status == noErr, "%s: ReadInput B status=%d cycle=%u", run->name, (int)status, k);
        const uint64_t readAfterB = atomic_load_explicit(
            &gRemoteProducer.shm->readIndex, memory_order_acquire);
        CHECK(readAfterB == readAfterA,
              "%s: second client advanced readIndex (%llu -> %llu) at cycle %u",
              run->name, (unsigned long long)readAfterA,
              (unsigned long long)readAfterB, k);
        (*driver)->EndIOOperation(driver, kObjectID_Device, 1,
                                  kAudioServerPlugInIOOperationReadInput, kCycleFrames, &cycle);

        const uint64_t remoteAfter =
            atomic_load_explicit(&gRemoteProducer.shm->writeIndex, memory_order_acquire);
        const uint64_t ignoredAfter = (gIgnoredProducer.shm != NULL)
            ? atomic_load_explicit(&gIgnoredProducer.shm->writeIndex, memory_order_acquire) : 0;

        Boolean fullyServed = true;
        for (unsigned i = 0; i < kCycleFrames; ++i)
        {
            if (outA[(size_t)i * SRM_CHANNELS] == 0.0f) { fullyServed = false; break; }
        }
        if (fullyServed && remoteBefore == remoteAfter && ignoredBefore == ignoredAfter)
        {
            ++run->comparedWindows;
            if (memcmp(outA, bufferB, sizeof(bufferB)) != 0)
            {
                if (run->firstIdemMismatchCycle == kNoCycle)
                {
                    run->firstIdemMismatchCycle = k;
                    for (unsigned i = 0; i < kCycleFrames * SRM_CHANNELS; ++i)
                    {
                        if (outA[i] != bufferB[i])
                        {
                            run->firstIdemMismatchFrame = i;
                            run->firstIdemValueA = outA[i];
                            run->firstIdemValueB = bufferB[i];
                            break;
                        }
                    }
                }
                ++run->idemMismatches;
            }
        }
    }

    status = (*driver)->StopIO(driver, kObjectID_Device, 1);
    CHECK(status == noErr, "%s: StopIO status=%d", run->name, (int)status);
    CHECK(atomic_load_explicit(&gRemoteProducer.shm->consumerCount, memory_order_acquire) == 0,
          "%s: shared consumerCount did not return to 0", run->name);

    if (lastWrapTicks > firstWrapTicks && lastWrapSample > firstWrapSample)
    {
        const double ns = (double)(lastWrapTicks - firstWrapTicks)
                        * gTimebase.numer / gTimebase.denom;
        run->wrapRate = (lastWrapSample - firstWrapSample) / (ns / 1e9);
    }
    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 2)
    {
        fprintf(stderr, "usage: %s /path/to/SiriRemoteAudio\n", argv[0]);
        return 2;
    }
    mach_timebase_info(&gTimebase);

    // Private IPC namespace: must be set BEFORE the driver's Initialize reads it.
    setenv("SRM_IPC_SUFFIX", kSimSuffix, 1);
    // Clean slate; in particular the unrelated ring must be absent for phases 1-2.
    shm_unlink(gRemoteProducer.name);
    shm_unlink(gIgnoredProducer.name);

    void *bundle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (bundle == NULL) { fprintf(stderr, "io sim: dlopen: %s\n", dlerror()); return 2; }
    typedef void *(*FactoryFunction)(CFAllocatorRef, CFUUIDRef);
    FactoryFunction factory = (FactoryFunction)dlsym(bundle, "BlackHole_Create");
    if (factory == NULL) { fprintf(stderr, "io sim: dlsym: %s\n", dlerror()); return 2; }
    AudioServerPlugInDriverRef driver =
        (AudioServerPlugInDriverRef)factory(NULL, kAudioServerPlugInTypeUUID);
    if (driver == NULL) { fprintf(stderr, "io sim: factory failed\n"); return 2; }
    if ((*driver)->Initialize(driver, &kFakeHost) != noErr)
    {
        fprintf(stderr, "io sim: Initialize failed\n");
        return 2;
    }

    if (producer_start(&gRemoteProducer, 1) != 0) { return 2; }

    // ---- phase 1: remote steady + resync jump (unrelated source absent) ----
    PhaseRun phase1 = {
        .name = "phase1", .totalCycles = 380,
        .jumpAtCycle = 200, .jumpFrames = 24000,   // +0.5 s forward ~2.1 s in
        .primeRemoteAfterStart = 1,
        .remoteStartCycle = kNoCycle, .remoteStopCycle = kNoCycle,
        .remoteResumeCycle = kNoCycle,
    };
    if (run_phase(driver, &phase1) != 0) { return 2; }
    {
        const size_t total = (size_t)phase1.totalCycles * kCycleFrames;
        const StreamStats s = analyze_stream(phase1.stream, total);
        printf("io sim: phase1 cycles=%u served=%zu silent=%zu (%.1f%%) transitions=%zu\n",
               phase1.totalCycles, total - s.silent, s.silent,
               100.0 * (double)s.silent / (double)total, s.transitions);
        printf("io sim: phase1 full-scale=%zu discontinuities=%zu idempotency: %u of %u differ\n",
               s.fullScale, s.discontinuities, phase1.idemMismatches, phase1.comparedWindows);
        printf("io sim: phase1 zero-timestamp implied rate=%.1f Hz (nominal %d)\n",
               phase1.wrapRate, kRate);
        CHECK(s.fullScale == 0, "phase1: %zu full-scale samples (garbage or gain clipping)",
              s.fullScale);
        CHECK(s.discontinuities == 0, "phase1: %zu splices in served audio", s.discontinuities);
        CHECK(phase1.idemMismatches == 0,
              "phase1: %u re-read windows differed — ReadInput is not idempotent",
              phase1.idemMismatches);
        CHECK(phase1.comparedWindows > phase1.totalCycles / 2,
              "phase1: too few fully-served windows (%u) to judge", phase1.comparedWindows);
        CHECK(s.silent < total / 4, "phase1: excessive silence (%zu of %zu frames)",
              s.silent, total);
        CHECK(phase1.wrapRate == 0 ||
              (phase1.wrapRate > kRate * 0.95 && phase1.wrapRate < kRate * 1.05),
              "phase1: device clock off nominal: %.1f Hz", phase1.wrapRate);
        free(phase1.stream);
    }

    // ---- phase 2: remote gap; queued remote audio drains, then exact silence ----
    // Remote writes until ~0.50 s, gap until ~1.21 s, then resumes. 165 cycles ~ 1.76 s.
    PhaseRun phase2 = {
        .name = "phase2", .totalCycles = 165,
        .jumpAtCycle = kNoCycle, .jumpFrames = 0,
        .primeRemoteAfterStart = 1,
        .remoteStartCycle = kNoCycle, .remoteStopCycle = 47, .remoteResumeCycle = 113,
    };
    if (run_phase(driver, &phase2) != 0) { return 2; }
    {
        const size_t total = (size_t)phase2.totalCycles * kCycleFrames;
        const size_t resumeFrame = (size_t)phase2.remoteResumeCycle * kCycleFrames;
        const StreamStats s = analyze_stream(phase2.stream, total);
        printf("io sim: phase2 served=%zu silent=%zu full-scale=%zu discontinuities=%zu "
               "idempotency: %u of %u differ\n",
               total - s.silent, s.silent, s.fullScale, s.discontinuities,
               phase2.idemMismatches, phase2.comparedWindows);
        check_sign_window("phase2", "remote before release", phase2.stream,
                          12000, 22500, 1, 0.95);
        // A new StartIO session preserves at most 500 ms of pre-roll, and this fixture adds
        // 100 ms of priming before its clock starts. After release, those queued remote frames
        // must drain before the device becomes silent. Allow one producer chunk for a write
        // already in flight, then require exact silence until reactivation.
        const size_t releaseFrame = (size_t)phase2.remoteStopCycle * kCycleFrames;
        const size_t drainDeadline = releaseFrame + kExpectedPreRollFrames
            + kExpectedPrimeFrames + kChunkFrames;
        CHECK(drainDeadline < resumeFrame,
              "phase2: invalid drain window [%zu,%zu)", drainDeadline, resumeFrame);
        check_all_silent("phase2", "single-source gap is silent after bounded drain",
                         phase2.stream, drainDeadline, resumeFrame);
        check_sign_window("phase2", "remote after re-press", phase2.stream,
                          67500, total, 1, 0.95);
        CHECK(s.fullScale == 0, "phase2: %zu full-scale samples", s.fullScale);
        CHECK(s.discontinuities == 0, "phase2: %zu splices in served audio", s.discontinuities);
        CHECK(phase2.idemMismatches == 0, "phase2: %u re-read windows differed",
              phase2.idemMismatches);
        CHECK(phase2.comparedWindows > phase2.totalCycles / 3,
              "phase2: too few fully-served windows (%u) to judge", phase2.comparedWindows);
        free(phase2.stream);
    }

    // ---- phase 3: an unrelated producer must never become device input ----
    atomic_store_explicit(&gRemoteProducer.writing, 0, memory_order_release);
    atomic_store_explicit(&gRemoteProducer.shm->producerActive, 0, memory_order_release);
    if (producer_start(&gIgnoredProducer, 1) != 0) { return 2; }
    if (producer_wait_for_frames(&gIgnoredProducer, 3 * kChunkFrames) != 0) { return 2; }
    PhaseRun phase3 = {
        .name = "phase3", .totalCycles = 285,
        .jumpAtCycle = kNoCycle, .jumpFrames = 0,
        .primeIgnoredAfterStart = 1,
        .remoteStartCycle = 24, .remoteStopCycle = 94, .remoteResumeCycle = 188,
    };
    if (run_phase(driver, &phase3) != 0) { return 2; }
    {
        const size_t total = (size_t)phase3.totalCycles * kCycleFrames;
        const size_t releaseFrame = (size_t)phase3.remoteStopCycle * kCycleFrames;
        const StreamStats s = analyze_stream(phase3.stream, total);
        const size_t ignoredAt =
            first_sample_with_sign(phase3.stream, releaseFrame, total, 0);
        printf("io sim: phase3 served=%zu silent=%zu full-scale=%zu discontinuities=%zu "
               "idempotency: %u of %u differ\n",
               total - s.silent, s.silent, s.fullScale, s.discontinuities,
               phase3.idemMismatches, phase3.comparedWindows);
        printf("io sim: phase3 release at frame %zu ignored-source sample=%zu\n",
               releaseFrame, ignoredAt);

        check_all_silent("phase3", "unrelated source ignored at session start", phase3.stream,
                         4800, 11800);
        check_sign_window("phase3", "(a) fresh remote owns the device", phase3.stream,
                          21600, 45600, 1, 0.95);
        CHECK(ignoredAt == SIZE_MAX,
              "(b) ignored source leaked into device at frame %zu", ignoredAt);
        const size_t resumeFrame = (size_t)phase3.remoteResumeCycle * kCycleFrames;
        const size_t drainDeadline = releaseFrame + kExpectedPreRollFrames
            + kExpectedPrimeFrames + kChunkFrames;
        CHECK(drainDeadline < resumeFrame - kCycleFrames,
              "phase3: invalid drain window [%zu,%zu)",
              drainDeadline, resumeFrame - kCycleFrames);
        check_all_silent("phase3", "(b) release gap stays silent", phase3.stream,
                         drainDeadline, resumeFrame - kCycleFrames);
        check_sign_window("phase3", "(c) remote resumes and takes back", phase3.stream,
                          106000, total, 1, 0.95);
        CHECK(s.fullScale == 0, "phase3 (d): %zu full-scale samples", s.fullScale);
        CHECK(s.discontinuities == 0,
              "phase3 (d): %zu splices — first at frame %zu (%.6f -> %.6f)",
              s.discontinuities, s.firstDiscontinuity,
              (double)s.beforeDiscontinuity, (double)s.afterDiscontinuity);
        CHECK(phase3.idemMismatches == 0,
              "phase3 (d): %u re-read windows differed — first cycle %u frame %u "
              "(%.6f vs %.6f)",
              phase3.idemMismatches, phase3.firstIdemMismatchCycle,
              phase3.firstIdemMismatchFrame,
              (double)phase3.firstIdemValueA, (double)phase3.firstIdemValueB);
        CHECK(phase3.comparedWindows > phase3.totalCycles / 3,
              "phase3: too few fully-served windows (%u) to judge", phase3.comparedWindows);
        free(phase3.stream);
    }

    producer_finish(&gRemoteProducer);
    producer_finish(&gIgnoredProducer);
    shm_unlink(gRemoteProducer.name);   // the private .sim namespace leaves nothing behind
    shm_unlink(gIgnoredProducer.name);

    dlclose(bundle);
    if (gFailures != 0)
    {
        fprintf(stderr, "io sim: %u failure(s)\n", gFailures);
        return 1;
    }
    puts("io sim: PASS");
    return 0;
}
