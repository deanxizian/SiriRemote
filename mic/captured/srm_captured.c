//
//  srm_captured.c — the "Siri Remote Mic" capture daemon.
//
//  Root supervisor with an authenticated XPC lease, protected PCM and asynchronous teardown.
//  Disconnect revokes audio before stopping children; no caller-provided PID is trusted.
//
//  WHY ROOT: PacketLogger's HCI capture and the MobileBluetooth debug traces both require root.
//  A LaunchDaemon is the standard way to grant exactly that, once, instead of a per-use password.
//  The pipeline binaries are unchanged from the validated manual path; this only orchestrates them.
//
//  BUILD: ./build.sh. Installation and removal are owned by the packages in ../../dist.
//

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <notify.h>
#include <dispatch/dispatch.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <limits.h>

#include "SiriRemoteCaptureIPC.h"
#include "srm_audio_owner.h"
#include "srm_runtime_directory.h"

extern char **environ;

// --- fixed product paths -----------------------------------------------------------------------
#define CAPTURE_READY_NOTIF_NAME "com.deanxi.siriremote.audio.capture-ready"
#define CAPTURE_SERVICE_NOTIF_NAME "com.deanxi.siriremote.capture-service"
#define RUNTIME_DIR   "/private/var/run/com.deanxi.siriremote"
#define PKLG_PATH     RUNTIME_DIR "/capture.pklg"
#define READY_PATH    RUNTIME_DIR "/capture-service-ready"
#define SUPPORT_DIR   "/Library/Application Support/SiriRemote"
#define PACKETLOGGER_SOURCE_APP "/Applications/PacketLogger.app"
#define PACKETLOGGER_SOURCE_EXEC \
    PACKETLOGGER_SOURCE_APP "/Contents/Resources/packetlogger"
#define PACKETLOGGER_APP SUPPORT_DIR "/PacketLogger.app"
#define PACKETLOGGER_PENDING_APP SUPPORT_DIR "/.PacketLogger.pending"
#define PACKETLOGGER  PACKETLOGGER_APP "/Contents/Resources/packetlogger"
#define ROUTER_PATH   SUPPORT_DIR "/SiriRemoteAudioRouter"
#define BT_DEBUG_DOMAIN "/Library/Preferences/com.apple.MobileBluetooth.debug"


static pid_t g_packetlogger = -1;
static pid_t g_router = -1;
static int   g_hci_ready = 0;
static int      g_capture_ready_token = -1;
static int      g_capture_service_token = -1;

static void logmsg(const char *fmt, ...)
{
    char ts[32];
    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    strftime(ts, sizeof ts, "%H:%M:%S", &tmv);
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[SiriRemoteCapture %s] ", ts);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    fflush(stderr);
}

static void publish_capture_ready(int ready)
{
    if (g_capture_ready_token < 0) return;
    (void)notify_set_state(g_capture_ready_token, ready ? 1u : 0u);
    notify_post(CAPTURE_READY_NOTIF_NAME);
}

static void publish_capture_service(int ready)
{
    if (g_capture_service_token < 0) return;
    (void)notify_set_state(g_capture_service_token, ready ? (uint64_t)getpid() : 0u);
    notify_post(CAPTURE_SERVICE_NOTIF_NAME);
}

static int publish_service_ready(void)
{
    int descriptor = open(READY_PATH, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (descriptor < 0) {
        logmsg("cannot publish capture-service readiness: %s", strerror(errno));
        return 0;
    }
    close(descriptor);
    return 1;
}

// posix_spawn a child, return its pid (or -1). argv[0] is conventionally the program name.
static pid_t spawn_child(const char *path, char *const argv[])
{
    pid_t pid = -1;
    int rc = posix_spawn(&pid, path, NULL, NULL, argv, environ);
    if (rc != 0) {
        logmsg("spawn %s failed: %s", path, strerror(rc));
        return -1;
    }
    return pid;
}

static void spawn_and_wait(const char *path, char *const argv[])
{
    pid_t pid = spawn_child(path, argv);
    if (pid > 0) waitpid(pid, NULL, 0);
}

static int spawn_and_wait_checked(const char *path, char *const argv[])
{
    pid_t pid = spawn_child(path, argv);
    if (pid <= 0) return 0;
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno == EINTR) continue;
        logmsg("wait for %s failed: %s", path, strerror(errno));
        return 0;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        logmsg("%s exited unsuccessfully (status=%d)", path, status);
        return 0;
    }
    return 1;
}

static int secure_root_owned_path(const char *path, int directory)
{
    struct stat metadata;
    if (lstat(path, &metadata) != 0) return 0;
    if (directory ? !S_ISDIR(metadata.st_mode) : !S_ISREG(metadata.st_mode)) return 0;
    return metadata.st_uid == 0 && (metadata.st_mode & (S_IWGRP | S_IWOTH)) == 0;
}

static SecStaticCodeRef copy_validated_apple_code(const char *path,
                                                  CFStringRef requirement_text,
                                                  SecCSFlags extra_flags)
{
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault, (const UInt8 *)path, (CFIndex)strlen(path), false
    );
    if (url == NULL) return NULL;

    SecStaticCodeRef code = NULL;
    SecRequirementRef requirement = NULL;
    OSStatus result = SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &code);
    if (result == errSecSuccess) {
        result = SecRequirementCreateWithString(
            requirement_text, kSecCSDefaultFlags, &requirement
        );
    }
    if (result == errSecSuccess) {
        SecCSFlags flags = kSecCSCheckAllArchitectures | kSecCSStrictValidate
            | kSecCSRestrictSymlinks | kSecCSRestrictSidebandData | extra_flags;
        result = SecStaticCodeCheckValidity(code, flags, requirement);
    }

    if (requirement != NULL) CFRelease(requirement);
    CFRelease(url);
    if (result != errSecSuccess) {
        logmsg("Apple code-signature validation failed for %s (OSStatus=%d)",
               path, (int)result);
        if (code != NULL) CFRelease(code);
        return NULL;
    }
    return code;
}

// kSecCodeInfoUnique is the CDHash selected by macOS for this exact signed code. Unlike the stable
// signing identifier, it changes when Apple ships a new PacketLogger binary. Comparing both the App
// and its packetlogger CLI lets the daemon refresh its protected copy without trusting mutable
// version strings or timestamps from /Applications.
static CFDataRef copy_validated_code_hash(const char *path, CFStringRef requirement_text,
                                          SecCSFlags extra_flags)
{
    SecStaticCodeRef code = copy_validated_apple_code(path, requirement_text, extra_flags);
    if (code == NULL) return NULL;

    CFDictionaryRef information = NULL;
    OSStatus result = SecCodeCopySigningInformation(
        code, kSecCSDefaultFlags, &information
    );
    CFDataRef identity = NULL;
    if (result == errSecSuccess && information != NULL) {
        CFTypeRef value = CFDictionaryGetValue(information, kSecCodeInfoUnique);
        if (value != NULL && CFGetTypeID(value) == CFDataGetTypeID()) {
            identity = CFDataCreateCopy(kCFAllocatorDefault, (CFDataRef)value);
        }
    }
    if (information != NULL) CFRelease(information);
    CFRelease(code);

    if (identity == NULL) {
        logmsg("cannot read validated code identity for %s (OSStatus=%d)",
               path, (int)result);
    }
    return identity;
}

typedef struct {
    CFDataRef app;
    CFDataRef executable;
} PacketLoggerCodeIdentity;

static void release_packetlogger_identity(PacketLoggerCodeIdentity *identity)
{
    if (identity->app != NULL) CFRelease(identity->app);
    if (identity->executable != NULL) CFRelease(identity->executable);
    identity->app = NULL;
    identity->executable = NULL;
}

static int copy_packetlogger_identity(const char *app_path, int require_protected_copy,
                                      PacketLoggerCodeIdentity *identity)
{
    identity->app = NULL;
    identity->executable = NULL;
    if (access(app_path, F_OK) != 0) return 0;

    char executable[PATH_MAX];
    int length = snprintf(executable, sizeof executable,
                          "%s/Contents/Resources/packetlogger", app_path);
    if (length <= 0 || (size_t)length >= sizeof executable) return 0;
    if (require_protected_copy
        && (!secure_root_owned_path(SUPPORT_DIR, 1)
            || !secure_root_owned_path(app_path, 1)
            || !secure_root_owned_path(executable, 0))) {
        logmsg("PacketLogger protected snapshot has unsafe ownership or permissions");
        return 0;
    }

    identity->app = copy_validated_code_hash(
        app_path,
        CFSTR("anchor apple and identifier \"com.apple.PacketLogger\""),
        kSecCSCheckNestedCode
    );
    if (identity->app != NULL) {
        identity->executable = copy_validated_code_hash(
            executable,
            CFSTR("anchor apple and identifier \"com.apple.packetlogger\""),
            kSecCSDefaultFlags
        );
    }
    if (identity->app == NULL || identity->executable == NULL) {
        release_packetlogger_identity(identity);
        return 0;
    }
    return 1;
}

static int packetlogger_identities_match(const PacketLoggerCodeIdentity *left,
                                         const PacketLoggerCodeIdentity *right)
{
    return CFEqual(left->app, right->app)
        && CFEqual(left->executable, right->executable);
}

static int packetlogger_source_matches_snapshot(int *source_valid, int *snapshot_valid)
{
    PacketLoggerCodeIdentity source_identity = { NULL, NULL };
    PacketLoggerCodeIdentity snapshot_identity = { NULL, NULL };
    *source_valid = copy_packetlogger_identity(
        PACKETLOGGER_SOURCE_APP, 0, &source_identity
    );
    *snapshot_valid = copy_packetlogger_identity(
        PACKETLOGGER_APP, 1, &snapshot_identity
    );
    int matches = *source_valid && *snapshot_valid
        && packetlogger_identities_match(&source_identity, &snapshot_identity);
    release_packetlogger_identity(&source_identity);
    release_packetlogger_identity(&snapshot_identity);
    return matches;
}

static int packetlogger_snapshot_is_trusted(const char *app_path)
{
    PacketLoggerCodeIdentity identity = { NULL, NULL };
    int trusted = copy_packetlogger_identity(app_path, 1, &identity);
    release_packetlogger_identity(&identity);
    return trusted;
}

static void remove_packetlogger_tree(const char *path)
{
    char *arguments[] = { "rm", "-rf", (char *)path, NULL };
    (void)spawn_and_wait_checked("/bin/rm", arguments);
}

// PacketLogger is normally dragged into /Applications and therefore remains user-owned. A root
// daemon must never execute it from that writable location. Copy the fixed Apple-signed bundle to
// the root-owned SiriRemote support directory, strip write access for group/other, validate every
// architecture and nested component, then atomically publish that immutable local snapshot.
static int install_packetlogger_snapshot(void)
{
    if (access(PACKETLOGGER_SOURCE_EXEC, R_OK) != 0) return 0;
    if (!secure_root_owned_path(SUPPORT_DIR, 1)) {
        logmsg("refusing PacketLogger snapshot: %s is not a protected root-owned directory",
               SUPPORT_DIR);
        return 0;
    }

    remove_packetlogger_tree(PACKETLOGGER_PENDING_APP);
    char *copy_arguments[] = {
        "ditto", "--noacl", "--noextattr", "--noqtn",
        PACKETLOGGER_SOURCE_APP, PACKETLOGGER_PENDING_APP, NULL
    };
    char *owner_arguments[] = {
        "chown", "-R", "-P", "root:wheel", PACKETLOGGER_PENDING_APP, NULL
    };
    char *acl_arguments[] = {
        "chmod", "-RN", PACKETLOGGER_PENDING_APP, NULL
    };
    char *mode_arguments[] = {
        "chmod", "-R", "-P", "go-w", PACKETLOGGER_PENDING_APP, NULL
    };
    if (!spawn_and_wait_checked("/usr/bin/ditto", copy_arguments)
        || !spawn_and_wait_checked("/usr/sbin/chown", owner_arguments)
        || !spawn_and_wait_checked("/bin/chmod", acl_arguments)
        || !spawn_and_wait_checked("/bin/chmod", mode_arguments)
        || !packetlogger_snapshot_is_trusted(PACKETLOGGER_PENDING_APP)) {
        remove_packetlogger_tree(PACKETLOGGER_PENDING_APP);
        logmsg("refusing untrusted PacketLogger installation");
        return 0;
    }

    remove_packetlogger_tree(PACKETLOGGER_APP);
    if (rename(PACKETLOGGER_PENDING_APP, PACKETLOGGER_APP) != 0) {
        logmsg("cannot publish protected PacketLogger snapshot: %s", strerror(errno));
        remove_packetlogger_tree(PACKETLOGGER_PENDING_APP);
        return 0;
    }
    int source_valid = 0;
    int snapshot_valid = 0;
    if (!packetlogger_source_matches_snapshot(&source_valid, &snapshot_valid)) {
        logmsg("PacketLogger source changed while creating its protected snapshot");
        remove_packetlogger_tree(PACKETLOGGER_APP);
        return 0;
    }
    logmsg("installed protected Apple-signed PacketLogger snapshot");
    return 1;
}

static int packetlogger_available(void)
{
    if (access(PACKETLOGGER_SOURCE_EXEC, R_OK) != 0) {
        remove_packetlogger_tree(PACKETLOGGER_APP);
        return 0;
    }

    int source_valid = 0;
    int snapshot_valid = 0;
    int matches_source = packetlogger_source_matches_snapshot(
        &source_valid, &snapshot_valid
    );

    if (!source_valid) {
        logmsg("refusing untrusted PacketLogger source; removing protected snapshot");
        remove_packetlogger_tree(PACKETLOGGER_APP);
        return 0;
    }
    if (matches_source) return 1;
    if (snapshot_valid) {
        logmsg("Apple PacketLogger changed; refreshing protected snapshot");
    }
    remove_packetlogger_tree(PACKETLOGGER_APP);
    return install_packetlogger_snapshot();
}

// Validate again immediately before each privileged execution. The snapshot and all of its parent
// directories are root-owned and non-writable to users, so the successful result remains valid
// between this check and posix_spawn.
static pid_t spawn_packetlogger(char *const argv[])
{
    if (!packetlogger_snapshot_is_trusted(PACKETLOGGER_APP)) {
        logmsg("refusing to execute an untrusted PacketLogger snapshot");
        return -1;
    }
    return spawn_child(PACKETLOGGER, argv);
}



// Enable the Bluetooth HCI debug traces PacketLogger needs to see the remote's voice notifications
// (RawAudioTrace) and defeat the profile-required wall (HCISkipAuth). These reset on reboot, so the
// daemon re-asserts them; SIGUSR1 (-30) makes bluetoothd reload debug config WITHOUT disconnecting.
static void ensure_hci_traces(void)
{
    char *dargs[] = {
        "defaults", "write", BT_DEBUG_DOMAIN, "HCITraces", "-dict",
        "StackDebugEnabled", "-bool", "true",
        "HCILiveTraces",     "-bool", "true",
        "HCIFileTraces",     "-bool", "true",
        "RawAudioTrace",     "-bool", "true",
        "HIDTrace",          "-bool", "true",
        "HCISkipAuth",       "-bool", "true",
        NULL
    };
    spawn_and_wait("/usr/bin/defaults", dargs);
    char *kargs[] = { "killall", "-30", "bluetoothd", NULL };
    spawn_and_wait("/usr/bin/killall", kargs);
    g_hci_ready = 1;
    logmsg("HCI debug traces asserted");
}

// PacketLogger's first launch after boot can spend several seconds loading frameworks. Pay that
// cost once at daemon startup, before a physical Siri hold has a latency budget. No capture is kept.
static void prewarm_packetlogger(void)
{
    const char *warm = RUNTIME_DIR "/prewarm.pklg";
    if (mkdir(RUNTIME_DIR, 0700) != 0 && errno != EEXIST) {
        logmsg("cannot create runtime directory for PacketLogger prewarm: %s", strerror(errno));
        return;
    }
    (void)chmod(RUNTIME_DIR, 0700);
    unlink(warm);
    char *plargs[] = { "packetlogger", "convert", "-o", (char *)warm, NULL };
    pid_t pid = spawn_packetlogger(plargs);
    if (pid <= 0) return;
    off_t observed_size = 0;
    for (int i = 0; i < 200; ++i) {
        struct stat st;
        if (stat(warm, &st) == 0 && st.st_size > 0) {
            observed_size = st.st_size;
            break;
        }
        usleep(50 * 1000);
    }
    usleep(200 * 1000);
    kill(pid, SIGKILL);
    waitpid(pid, NULL, 0);
    unlink(warm);
    logmsg("PacketLogger pre-warmed (initial-bytes=%lld)", (long long)observed_size);
}


typedef enum { PipelineIdle, PipelinePreparing, PipelineCapturing, PipelineStopping } PipelinePhase;
static PipelinePhase g_phase;
static SRMSharedMemory *g_audio;
static xpc_connection_t g_owner;
static uint64_t g_owner_session, g_pipeline_generation;
static _Atomic uint64_t g_operation_epoch;
static dispatch_queue_t g_work_queue;
static dispatch_source_t g_clock;
static int g_work_busy, g_terminating;
static uint64_t g_ticks_per_second, g_prepare_deadline, g_stop_deadline;
static void reconcile_pipeline(void);

static void update_clock(void)
{
    int needed = g_owner != NULL || g_phase != PipelineIdle || g_work_busy;
    dispatch_source_set_timer(g_clock,
        needed ? dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC) : DISPATCH_TIME_FOREVER,
        needed ? 20 * NSEC_PER_MSEC : DISPATCH_TIME_FOREVER, 2 * NSEC_PER_MSEC);
}
static void drop_owner(void)
{
    if (g_owner) xpc_release(g_owner);
    g_owner = NULL;
    g_owner_session = 0;
}
static void stop_pipeline(void)
{
    if (g_phase != PipelineStopping) {
        atomic_fetch_add_explicit(&g_operation_epoch, 1, memory_order_acq_rel);
        srm_audio_revoke(g_audio);
        publish_capture_ready(0);
        g_phase = PipelineStopping;
        g_stop_deadline = mach_absolute_time() + g_ticks_per_second * 4 / 10;
        if (g_router > 0) kill(g_router, SIGTERM);
        if (g_packetlogger > 0) kill(g_packetlogger, SIGTERM);
        logmsg("capture revoked; stopping children asynchronously");
    }
    update_clock();
}
static void reap_child(pid_t *child)
{
    if (*child <= 0) return;
    int status;
    pid_t result = waitpid(*child, &status, WNOHANG);
    if (result == *child || (result < 0 && errno == ECHILD)) *child = -1;
}
static void clock_tick(void)
{
    uint64_t now = mach_absolute_time();
    pid_t old_router = g_router, old_packetlogger = g_packetlogger;
    // Do not steal worker-owned validation/prewarm children from their waitpid.
    reap_child(&g_router);
    reap_child(&g_packetlogger);
    if (g_phase != PipelineStopping &&
        ((old_router > 0 && g_router < 0) || (old_packetlogger > 0 && g_packetlogger < 0))) {
        logmsg("capture child exited; failing the current session");
        drop_owner();
        stop_pipeline();
    }
    if (g_phase == PipelineStopping) {
        if (now >= g_stop_deadline) {
            if (g_router > 0) kill(g_router, SIGKILL);
            if (g_packetlogger > 0) kill(g_packetlogger, SIGKILL);
        }
        if (g_router < 0 && g_packetlogger < 0 && !g_work_busy) {
            unlink(PKLG_PATH);
            g_phase = PipelineIdle;
            if (g_terminating) exit(0);
            reconcile_pipeline();
        }
    } else if (g_phase == PipelinePreparing && !g_work_busy && g_packetlogger > 0) {
        struct stat info;
        if (stat(PKLG_PATH, &info) == 0 && info.st_size > 0) {
            char generation[32];
            snprintf(generation, sizeof generation, "%llu", (unsigned long long)g_pipeline_generation);
            char *args[] = { "SiriRemoteAudioRouter", "--pklg", PKLG_PATH,
                             "--generation", generation, NULL };
            g_router = spawn_child(ROUTER_PATH, args);
            if (g_router > 0) {
                g_phase = PipelineCapturing;
                publish_capture_ready(1);
                logmsg("pipeline ready (packetlogger=%d router=%d generation=%s)",
                       g_packetlogger, g_router, generation);
            } else { drop_owner(); stop_pipeline(); }
        } else if (now >= g_prepare_deadline) {
            logmsg("capture preparation deadline exceeded");
            drop_owner();
            stop_pipeline();
        }
    }
    if (g_owner && (g_phase == PipelinePreparing || g_phase == PipelineCapturing))
        atomic_store_explicit(&g_audio->leaseExpiresAt, now + g_ticks_per_second / 2,
                              memory_order_release);
    if (!g_owner && g_phase == PipelineIdle && !g_work_busy) update_clock();
}
static void reconcile_pipeline(void)
{
    if (!g_owner) {
        if (g_phase != PipelineIdle || g_work_busy) stop_pipeline();
        return;
    }
    if (g_phase != PipelineIdle || g_work_busy || g_terminating) return;
    g_phase = PipelinePreparing;
    g_work_busy = 1;
    uint64_t operation = atomic_fetch_add_explicit(&g_operation_epoch, 1, memory_order_acq_rel) + 1;
    g_prepare_deadline = mach_absolute_time() + g_ticks_per_second * 13 / 10;
    update_clock();
    // Expensive validation and child waits never block the control/XPC queue.
    dispatch_async(g_work_queue, ^{
        int valid = packetlogger_available();
        if (valid && !g_hci_ready) ensure_hci_traces();
        if (valid) valid = packetlogger_snapshot_is_trusted(PACKETLOGGER_APP);
        dispatch_async(dispatch_get_main_queue(), ^{
            g_work_busy = 0;
            if (operation != atomic_load_explicit(&g_operation_epoch, memory_order_acquire)
                || !g_owner || g_terminating) { stop_pipeline(); return; }
            if (!valid || mach_absolute_time() >= g_prepare_deadline) {
                logmsg("capture unavailable or preparation deadline exceeded");
                drop_owner();
                stop_pipeline();
                return;
            }
            g_pipeline_generation = srm_audio_begin(g_audio);
            atomic_store_explicit(&g_audio->leaseExpiresAt,
                                  mach_absolute_time() + g_ticks_per_second / 2, memory_order_release);
            unlink(PKLG_PATH);
            // The worker just authenticated this immutable, root-owned snapshot.
            char *args[] = { "packetlogger", "convert", "-o", PKLG_PATH, NULL };
            g_packetlogger = spawn_child(PACKETLOGGER, args);
            if (g_packetlogger <= 0) { drop_owner(); stop_pipeline(); }
        });
    });
}
static void reply_snapshot(xpc_connection_t peer, xpc_object_t request, int accepted)
{
    xpc_object_t reply = xpc_dictionary_create_reply(request);
    if (!reply) return;
    xpc_dictionary_set_bool(reply, "accepted", accepted);
    xpc_dictionary_set_uint64(reply, "session", peer == g_owner ? g_owner_session : 0);
    if (accepted) {
        xpc_dictionary_set_bool(reply, "available", g_owner == peer &&
                                g_phase != PipelineStopping && g_phase != PipelineIdle);
        xpc_dictionary_set_uint64(reply, "generation",
                                 atomic_load_explicit(&g_audio->generation, memory_order_acquire));
        xpc_dictionary_set_bool(reply, "producerActive", srm_audio_active(g_audio));
        xpc_dictionary_set_uint64(reply, "writeIndex",
                                 atomic_load_explicit(&g_audio->writeIndex, memory_order_acquire));
        xpc_dictionary_set_uint64(reply, "readIndex",
                                 atomic_load_explicit(&g_audio->readIndex, memory_order_acquire));
        xpc_dictionary_set_uint64(reply, "consumerCount",
                                 atomic_load_explicit(&g_audio->consumerCount, memory_order_acquire));
        xpc_dictionary_set_uint64(reply, "startIOEpoch",
                                 atomic_load_explicit(&g_audio->startIOEpoch, memory_order_acquire));
    }
    xpc_connection_send_message(peer, reply);
    xpc_release(reply);
}
static void accept_peer(xpc_connection_t peer)
{
    xpc_connection_set_target_queue(peer, dispatch_get_main_queue());
    __block int authenticated = 0;
    xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
        if (xpc_get_type(message) == XPC_TYPE_ERROR) {
            if (g_owner == peer) { drop_owner(); stop_pipeline(); }
            return;
        }
        if (xpc_get_type(message) != XPC_TYPE_DICTIONARY) return;
        const char *operation = xpc_dictionary_get_string(message, "operation");
        if (!operation) { reply_snapshot(peer, message, 0); return; }
        int snapshot = strcmp(operation, "snapshot") == 0;
        // Cache only diagnostic access. Every mutation authenticates its actual message sender.
        if ((!authenticated || !snapshot) && !srm_message_is_authorized(message, SRM_APP_REQUIREMENT)) {
            reply_snapshot(peer, message, 0);
            return;
        }
        authenticated = 1;
        uint64_t session = xpc_dictionary_get_uint64(message, "session");
        int accepted = 1;
        if (strcmp(operation, "begin") == 0) {
            if (!session || (g_owner && g_owner != peer)) accepted = 0;
            else {
                if (g_owner && session != g_owner_session) stop_pipeline();
                if (!g_owner) { g_owner = peer; xpc_retain(peer); }
                g_owner_session = session;
                reconcile_pipeline();
            }
        } else if (strcmp(operation, "end") == 0) {
            if (g_owner == peer && session == g_owner_session) { drop_owner(); stop_pipeline(); }
        } else if (strcmp(operation, "seal") == 0) {
            if (g_owner == peer && session == g_owner_session) {
                uint64_t end = xpc_dictionary_get_uint64(message, "endFrame");
                uint64_t written = atomic_load_explicit(&g_audio->writeIndex, memory_order_acquire);
                uint64_t previous = atomic_load_explicit(&g_audio->playbackEndFrame, memory_order_acquire);
                if (end > written) end = written;
                if (end > previous) end = previous;
                atomic_store_explicit(&g_audio->playbackEndFrame, end, memory_order_release);
            } else accepted = 0;
        } else if (!snapshot) accepted = 0;
        reply_snapshot(peer, message, accepted);
    });
    xpc_connection_resume(peer);
}
static void terminate_daemon(void)
{
    g_terminating = 1;
    unlink(READY_PATH);
    publish_capture_service(0);
    drop_owner();
    stop_pipeline();
}
int main(void)
{
    umask(077);
    if (geteuid() != 0 || srm_prepare_runtime_directory(RUNTIME_DIR, 0) != 0 ||
        (g_audio = srm_audio_prepare()) == NULL) {
        logmsg("cannot prepare protected audio/runtime state: %s", strerror(errno));
        return 1;
    }
    shm_unlink("/SiriRemoteAudio_v1");
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    g_ticks_per_second = NSEC_PER_SEC * (uint64_t)timebase.denom / timebase.numer;
    signal(SIGTERM, SIG_IGN);
    signal(SIGINT, SIG_IGN);
    signal(SIGPIPE, SIG_IGN);
    g_work_queue = dispatch_queue_create("com.deanxi.siriremote.capture.prepare", DISPATCH_QUEUE_SERIAL);
    g_clock = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(g_clock, ^{ clock_tick(); });
    dispatch_source_set_timer(g_clock, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    dispatch_resume(g_clock);
    dispatch_source_t term = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0,
                                                     dispatch_get_main_queue());
    dispatch_source_t interrupt = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0,
                                                          dispatch_get_main_queue());
    dispatch_source_set_event_handler(term, ^{ terminate_daemon(); });
    dispatch_source_set_event_handler(interrupt, ^{ terminate_daemon(); });
    dispatch_resume(term);
    dispatch_resume(interrupt);
    notify_register_check(CAPTURE_SERVICE_NOTIF_NAME, &g_capture_service_token);
    notify_register_check(CAPTURE_READY_NOTIF_NAME, &g_capture_ready_token);
    publish_capture_ready(0);
    xpc_connection_t listener = xpc_connection_create_mach_service(
        SRM_CAPTURE_SERVICE, dispatch_get_main_queue(), XPC_CONNECTION_MACH_SERVICE_LISTENER);
    if (!listener) { logmsg("cannot create authenticated capture listener"); return 1; }
    xpc_connection_set_event_handler(listener, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_CONNECTION) accept_peer(event);
    });
    xpc_connection_resume(listener);
    if (!publish_service_ready()) return 1;
    publish_capture_service(1);
    logmsg("protected audio ready; authenticated capture listener started");
    g_work_busy = 1;
    update_clock();
    dispatch_async(g_work_queue, ^{
        if (packetlogger_available()) { ensure_hci_traces(); prewarm_packetlogger(); }
        dispatch_async(dispatch_get_main_queue(), ^{
            g_work_busy = 0;
            if (g_phase == PipelineStopping) return;
            reconcile_pipeline();
            update_clock();
        });
    });
    dispatch_main();
    return 0;
}
