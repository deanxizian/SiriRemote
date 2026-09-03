// Bounded post-install CoreAudio watchdog.
//
// The previous shell implementation launched ps/tr/awk several times per sample. When the audio
// process table was already unhealthy, one ps call could stall long enough for PackageKit to kill
// the entire postinstall script at its 600-second ceiling. This helper samples process CPU time
// directly through libproc and uses CLOCK_MONOTONIC for a hard, small wall-clock window.

#include <errno.h>
#include <libproc.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

#define NSEC_PER_SEC 1000000000ULL
#define MAX_PIDS 32768
#define PROCESS_NAME_CAPACITY 4096

typedef struct {
    uint64_t driverCPU;
    uint64_t coreAudioCPU;
    unsigned driverCount;
    unsigned coreAudioCount;
} CPUSnapshot;

static uint64_t monotonic_ns(void)
{
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return 0;
    return (uint64_t)value.tv_sec * NSEC_PER_SEC + (uint64_t)value.tv_nsec;
}

static void sleep_until(uint64_t deadline)
{
    for (;;) {
        const uint64_t now = monotonic_ns();
        if (now == 0 || now >= deadline) return;
        const uint64_t remaining = deadline - now;
        struct timespec delay = {
            .tv_sec = (time_t)(remaining / NSEC_PER_SEC),
            .tv_nsec = (long)(remaining % NSEC_PER_SEC),
        };
        if (nanosleep(&delay, NULL) == 0 || errno != EINTR) return;
    }
}

static int is_driver_process(const char *name)
{
    return name != NULL && strstr(name, "SiriRemoteAudio.driver") != NULL;
}

static int read_process_cpu(pid_t pid, uint64_t *result)
{
    struct rusage_info_v2 usage;
    memset(&usage, 0, sizeof usage);
    if (proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&usage) != 0) return 0;
    if (UINT64_MAX - usage.ri_user_time < usage.ri_system_time) return 0;
    *result = usage.ri_user_time + usage.ri_system_time;
    return 1;
}

static int take_snapshot(CPUSnapshot *snapshot)
{
    pid_t *pids = calloc(MAX_PIDS, sizeof *pids);
    if (pids == NULL) return 0;

    const int bytes = proc_listpids(PROC_ALL_PIDS, 0, pids,
                                    (int)(MAX_PIDS * sizeof *pids));
    if (bytes <= 0) {
        free(pids);
        return 0;
    }

    memset(snapshot, 0, sizeof *snapshot);
    const int count = bytes / (int)sizeof *pids;
    for (int index = 0; index < count; ++index) {
        if (pids[index] <= 0) continue;
        char name[PROCESS_NAME_CAPACITY];
        memset(name, 0, sizeof name);
        if (proc_name(pids[index], name, sizeof name) <= 0) continue;

        const int driver = is_driver_process(name);
        const int coreAudio = strcmp(name, "coreaudiod") == 0;
        if (!driver && !coreAudio) continue;

        uint64_t cpu = 0;
        if (!read_process_cpu(pids[index], &cpu)) continue;
        if (driver) {
            if (UINT64_MAX - snapshot->driverCPU < cpu) continue;
            snapshot->driverCPU += cpu;
            ++snapshot->driverCount;
        }
        if (coreAudio) {
            if (UINT64_MAX - snapshot->coreAudioCPU < cpu) continue;
            snapshot->coreAudioCPU += cpu;
            ++snapshot->coreAudioCount;
        }
    }
    free(pids);
    return 1;
}

static double interval_percent(uint64_t before, uint64_t after, uint64_t elapsed)
{
    if (elapsed == 0 || after < before) return 0.0;
    return ((double)(after - before) / (double)elapsed) * 100.0;
}

static int parse_positive(const char *value, unsigned *result)
{
    char *end = NULL;
    errno = 0;
    const unsigned long parsed = strtoul(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || parsed == 0 || parsed > 3600) return 0;
    *result = (unsigned)parsed;
    return 1;
}

static int self_test(void)
{
    int failed = 0;
    if (!is_driver_process("Core Audio Driver (SiriRemoteAudio.driver)")) ++failed;
    if (is_driver_process("Core Audio Driver (Another.driver)")) ++failed;
    if (fabs(interval_percent(100, 500000100, NSEC_PER_SEC) - 50.0) > 0.001) ++failed;
    if (interval_percent(500, 100, NSEC_PER_SEC) != 0.0) ++failed;
    if (failed != 0) {
        fprintf(stderr, "coreaudio watchdog self-test: %d failure(s)\n", failed);
        return 1;
    }
    puts("coreaudio watchdog self-test: PASS");
    return 0;
}

int main(int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "--self-test") == 0) return self_test();
    if (argc != 4) {
        fprintf(stderr, "usage: %s seconds threshold-percent consecutive-samples\n", argv[0]);
        return 2;
    }

    unsigned seconds = 0;
    unsigned threshold = 0;
    unsigned streakLimit = 0;
    if (!parse_positive(argv[1], &seconds) || !parse_positive(argv[2], &threshold)
        || !parse_positive(argv[3], &streakLimit)) {
        fputs("coreaudio watchdog: arguments must be positive integers\n", stderr);
        return 2;
    }

    CPUSnapshot previous;
    if (!take_snapshot(&previous)) {
        fputs("coreaudio watchdog: initial process sample failed\n", stderr);
        return 2;
    }
    const int watchDriver = previous.driverCount > 0;
    if (!watchDriver && previous.coreAudioCount == 0) {
        fputs("coreaudio watchdog: no CoreAudio process found\n", stderr);
        return 2;
    }

    const uint64_t started = monotonic_ns();
    if (started == 0) {
        fputs("coreaudio watchdog: monotonic clock unavailable\n", stderr);
        return 2;
    }
    const uint64_t deadline = started + (uint64_t)seconds * NSEC_PER_SEC;
    uint64_t previousTime = started;
    double peak = 0.0;
    double coreAudioPeak = 0.0;
    unsigned highStreak = 0;
    unsigned sampleNumber = 0;

    while (previousTime < deadline) {
        uint64_t next = started + (uint64_t)(sampleNumber + 1) * NSEC_PER_SEC;
        if (next > deadline) next = deadline;
        sleep_until(next);

        CPUSnapshot current;
        if (!take_snapshot(&current)) {
            fputs("coreaudio watchdog: process sample failed\n", stderr);
            return 2;
        }
        const uint64_t currentTime = monotonic_ns();
        if (currentTime == 0) return 2;

        if (watchDriver && current.driverCount == 0) {
            fputs("coreaudio watchdog: SiriRemote driver host disappeared\n", stderr);
            return 2;
        }
        if (!watchDriver && current.coreAudioCount == 0) {
            fputs("coreaudio watchdog: coreaudiod disappeared\n", stderr);
            return 2;
        }

        const double driverPercent = interval_percent(
            previous.driverCPU, current.driverCPU, currentTime - previousTime);
        const double coreAudioPercent = interval_percent(
            previous.coreAudioCPU, current.coreAudioCPU, currentTime - previousTime);
        const double selected = watchDriver ? driverPercent : coreAudioPercent;
        if (selected > peak) peak = selected;
        if (coreAudioPercent > coreAudioPeak) coreAudioPeak = coreAudioPercent;

        if (selected >= (double)threshold) ++highStreak;
        else highStreak = 0;
        if (highStreak >= streakLimit) {
            fprintf(stderr,
                    "coreaudio watchdog: %s stayed at or above %u%% for %u samples\n",
                    watchDriver ? "SiriRemoteAudio.driver host" : "coreaudiod",
                    threshold, streakLimit);
            return 1;
        }

        previous = current;
        previousTime = currentTime;
        ++sampleNumber;
        if (currentTime >= deadline) break;
    }

    printf("coreaudio watchdog: PASS (%s peak %.1f%%; coreaudiod peak %.1f%%; %us)\n",
           watchDriver ? "SiriRemoteAudio.driver host" : "coreaudiod",
           peak, coreAudioPeak, seconds);
    return 0;
}
