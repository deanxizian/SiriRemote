//
//  srm_captured.c — the "Siri Remote Mic" capture daemon.
//
//  Runs as root from a LaunchDaemon. SiriRemote publishes `...voice-demand` with its live PID while
//  a physical Siri-button session is primed. Only that live-PID lease may run the heavy, privileged
//  capture pipeline: PacketLogger (HCI capture) feeding SiriRemoteAudioRouter (voice extraction →
//  shared-memory ring). The HAL consumer count is observed for diagnostics only because input
//  methods may keep a virtual microphone open indefinitely. The PID is watched for exit so an App
//  crash cannot leave capture running.
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

#include "srm_capture_demand.h"
#include "srm_runtime_directory.h"

extern char **environ;

// --- fixed product paths -----------------------------------------------------------------------
#define NOTIF_NAME    "com.deanxi.siriremote.audio.consumers"
#define VOICE_NOTIF_NAME "com.deanxi.siriremote.audio.voice-demand"
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

#define RESTART_BACKOFF_SECONDS 1
#define CAPTURE_FILE_WAIT_ATTEMPTS 100

static pid_t g_packetlogger = -1;
static pid_t g_router = -1;
static int   g_pipeline_up = 0;
static int   g_hci_ready = 0;
static dispatch_source_t g_restart_timer = NULL;
static dispatch_source_t g_voice_process = NULL;
static int      g_voice_token = 0;
static int      g_capture_ready_token = -1;
static int      g_capture_service_token = -1;
static uint64_t g_virtual_consumers = 0;
static pid_t    g_voice_pid = 0;

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

static void stop_pipeline(void);

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

static void start_pipeline(void)
{
    if (g_pipeline_up) return;
    publish_capture_ready(0);
    if (!packetlogger_available()) {
        logmsg("PacketLogger missing — remote voice capture remains disabled");
        return;
    }
    // Full Setup never bundles PacketLogger. If the user installs it after this daemon starts,
    // prepare HCI capture lazily on the first real demand; no reboot or daemon reload is required.
    if (!g_hci_ready) ensure_hci_traces();

    g_pipeline_up = 1;
    logmsg("demand active → starting capture pipeline");

    if (mkdir(RUNTIME_DIR, 0700) != 0 && errno != EEXIST) {
        logmsg("cannot create %s: %s", RUNTIME_DIR, strerror(errno));
        g_pipeline_up = 0;
        return;
    }
    (void)chmod(RUNTIME_DIR, 0700);
    unlink(PKLG_PATH);
    char *plargs[] = { "packetlogger", "convert", "-o", PKLG_PATH, NULL };
    g_packetlogger = spawn_packetlogger(plargs);
    if (g_packetlogger < 0) { g_pipeline_up = 0; return; }

    // A created-but-empty file only proves that open(2) succeeded. Do not tell the App capture is
    // ready until PacketLogger has attached to the live HCI stream and written at least one record.
    int capture_file_ready = 0;
    off_t initial_size = 0;
    for (int i = 0; i < CAPTURE_FILE_WAIT_ATTEMPTS; ++i) {
        struct stat st;
        if (stat(PKLG_PATH, &st) == 0 && st.st_size > 0) {
            capture_file_ready = 1;
            initial_size = st.st_size;
            break;
        }
        usleep(50 * 1000);
    }
    if (!capture_file_ready) {
        logmsg("PacketLogger capture stayed empty for 5 seconds");
        stop_pipeline();
        return;
    }

    char *rargs[] = { "SiriRemoteAudioRouter", "--pklg", PKLG_PATH, NULL };
    g_router = spawn_child(ROUTER_PATH, rargs);
    if (g_router < 0) {
        logmsg("router failed to start");
        stop_pipeline();
        return;
    }
    publish_capture_ready(1);
    logmsg("pipeline ready (packetlogger=%d router=%d initial-bytes=%lld)",
           g_packetlogger, g_router, (long long)initial_size);
}

static void stop_pipeline(void)
{
    if (!g_pipeline_up) return;
    g_pipeline_up = 0;
    publish_capture_ready(0);
    struct stat final_capture;
    off_t final_size = stat(PKLG_PATH, &final_capture) == 0 ? final_capture.st_size : -1;
    logmsg("demand idle → stopping capture pipeline (final-bytes=%lld)",
           (long long)final_size);
    // SIGKILL, and NEVER a blocking waitpid here. This handler runs on the main dispatch queue; an
    // earlier version sent SIGINT then `waitpid(..., 0)` and hung the whole daemon when the router
    // didn't exit promptly from its tail loop — a stuck teardown froze all future demand handling.
    // SIGKILL can't be caught or delayed, and the SIGCHLD source below reaps the zombies async. The
    // router/PacketLogger have no state worth flushing here (the .pklg is transient), so this is safe.
    if (g_router > 0)       { kill(g_router, SIGKILL); g_router = -1; }
    if (g_packetlogger > 0) { kill(g_packetlogger, SIGKILL); g_packetlogger = -1; }
    unlink(PKLG_PATH);
}

static void cancel_restart_timer(void)
{
    if (g_restart_timer) {
        dispatch_source_cancel(g_restart_timer);
        g_restart_timer = NULL;
    }
}

static int process_is_alive(pid_t pid)
{
    if (pid <= 0) return 0;
    if (kill(pid, 0) == 0) return 1;
    return errno == EPERM;
}

static int demand_is_active(void)
{
    return srm_capture_should_run(g_virtual_consumers, g_voice_pid,
                                  process_is_alive(g_voice_pid));
}

static void schedule_pipeline_restart(void)
{
    if (g_restart_timer != NULL || !demand_is_active()) return;
    g_restart_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                              dispatch_get_main_queue());
    if (g_restart_timer == NULL) {
        logmsg("cannot create pipeline restart timer");
        return;
    }
    dispatch_source_set_timer(
        g_restart_timer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)RESTART_BACKOFF_SECONDS * NSEC_PER_SEC),
        DISPATCH_TIME_FOREVER,
        (uint64_t)(0.1 * NSEC_PER_SEC)
    );
    dispatch_source_set_event_handler(g_restart_timer, ^{
        cancel_restart_timer();
        if (demand_is_active()) start_pipeline();
    });
    dispatch_resume(g_restart_timer);
}

static void reconcile_demand(void)
{
    if (demand_is_active()) {
        start_pipeline();
    } else {
        cancel_restart_timer();
        // The App clears its lease only after the 80 ms tail and Ring drain. There is no consumer
        // renegotiation to debounce here, so release PacketLogger and the decoder immediately.
        stop_pipeline();
    }
}

// The HAL owns this count. Keep observing it for diagnostics and future drain telemetry, but never
// use it to wake capture: Doubao and system speech services can hold input IO while completely idle.
static void handle_virtual_demand(int token)
{
    uint64_t state = 0;
    if (notify_get_state(token, &state) != NOTIFY_STATUS_OK) return;
    if (state != g_virtual_consumers) {
        g_virtual_consumers = state;
        logmsg("virtual mic consumers=%llu (capture policy unchanged)",
               (unsigned long long)state);
    }
}

static void cancel_voice_process_watch(void)
{
    if (g_voice_process != NULL) {
        dispatch_source_cancel(g_voice_process);
        g_voice_process = NULL;
    }
}

static void watch_voice_process(pid_t pid)
{
    cancel_voice_process_watch();
    if (!process_is_alive(pid)) {
        g_voice_pid = 0;
        return;
    }
    g_voice_process = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid,
                                              DISPATCH_PROC_EXIT,
                                              dispatch_get_main_queue());
    if (g_voice_process == NULL) {
        logmsg("cannot watch voice owner pid %d — demand will follow explicit release", pid);
        return;
    }
    dispatch_source_set_event_handler(g_voice_process, ^{
        if (g_voice_pid != pid) return;
        logmsg("voice owner pid %d exited — releasing demand", pid);
        g_voice_pid = 0;
        cancel_voice_process_watch();
        reconcile_demand();
    });
    dispatch_resume(g_voice_process);
}

// App-owned priming demand carries the owner PID so a crash cannot leave capture running.
static void handle_voice_demand(int token)
{
    uint64_t state = 0;
    if (notify_get_state(token, &state) != NOTIFY_STATUS_OK) state = 0;
    pid_t requested = state > 0 && state <= INT32_MAX ? (pid_t)state : 0;
    if (!process_is_alive(requested)) requested = 0;
    if (requested != g_voice_pid) {
        g_voice_pid = requested;
        watch_voice_process(requested);
        logmsg("voice demand %s", requested > 0 ? "active" : "idle");
    }
    reconcile_demand();
}

static void terminate_daemon(void)
{
    unlink(READY_PATH);
    publish_capture_service(0);
    publish_capture_ready(0);
    cancel_restart_timer();
    stop_pipeline();
    exit(0);
}

int main(void)
{
    umask(077);
    signal(SIGTERM, SIG_IGN);
    signal(SIGINT, SIG_IGN);
    signal(SIGPIPE, SIG_IGN);

    uint32_t service_rc = notify_register_check(
        CAPTURE_SERVICE_NOTIF_NAME, &g_capture_service_token
    );
    if (service_rc == NOTIFY_STATUS_OK) publish_capture_service(0);
    else {
        g_capture_service_token = -1;
        logmsg("notify_register_check(%s) failed: %u", CAPTURE_SERVICE_NOTIF_NAME, service_rc);
    }

    if (geteuid() != 0 || srm_prepare_runtime_directory(RUNTIME_DIR, 0) != 0) {
        logmsg("cannot prepare secure runtime directory: %s", strerror(errno));
        return 1;
    }
    unlink(READY_PATH);

    dispatch_source_t sigterm = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue()
    );
    dispatch_source_t sigint = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue()
    );
    if (sigterm == NULL || sigint == NULL) {
        logmsg("cannot create termination signal sources");
        return 1;
    }
    dispatch_source_set_event_handler(sigterm, ^{ terminate_daemon(); });
    dispatch_source_set_event_handler(sigint, ^{ terminate_daemon(); });
    dispatch_resume(sigterm);
    dispatch_resume(sigint);

    logmsg("starting");
    // This marker means launchd successfully started the signed service. PacketLogger pre-warming
    // is an optimization, not an installer transaction: publish first so a cold framework load can
    // continue in the daemon without holding PackageKit's postinstall script open.
    if (!publish_service_ready()) return 1;
    if (!packetlogger_available()) {
        logmsg("PacketLogger not installed — leaving Bluetooth HCI debug traces unchanged");
    } else {
        // One boot-time preparation avoids spending the 1.5-second Siri hold budget rewriting
        // Bluetooth debug settings. PacketLogger and the decoder still remain stopped while idle.
        ensure_hci_traces();
        prewarm_packetlogger();
    }

    uint32_t ready_rc = notify_register_check(
        CAPTURE_READY_NOTIF_NAME, &g_capture_ready_token
    );
    if (ready_rc == NOTIFY_STATUS_OK) publish_capture_ready(0);
    else logmsg("notify_register_check(%s) failed: %u", CAPTURE_READY_NOTIF_NAME, ready_rc);

    // Reap any child that dies on its own (e.g. PacketLogger quitting) so it can't linger as a
    // zombie. If either half of a live pipeline dies, tear down its sibling and retry once after a
    // fixed delay. The delay prevents a broken PacketLogger/router from creating a CPU-heavy loop.
    dispatch_source_t sigchld = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGCHLD, 0,
                                                       dispatch_get_main_queue());
    dispatch_source_set_event_handler(sigchld, ^{
        int status;
        pid_t dead;
        int pipeline_child_died = 0;
        while ((dead = waitpid(-1, &status, WNOHANG)) > 0) {
            if (dead == g_router)       { g_router = -1; pipeline_child_died = 1; }
            if (dead == g_packetlogger) { g_packetlogger = -1; pipeline_child_died = 1; }
        }
        if (pipeline_child_died && g_pipeline_up) {
            logmsg("capture pipeline exited unexpectedly — restarting after backoff");
            stop_pipeline();
            schedule_pipeline_restart();
        }
    });
    signal(SIGCHLD, SIG_DFL);   // let the dispatch source observe; default disposition delivers it
    dispatch_resume(sigchld);

    int token = 0;
    uint32_t rc = notify_register_dispatch(NOTIF_NAME, &token, dispatch_get_main_queue(), ^(int t) {
        handle_virtual_demand(t);
    });
    if (rc != NOTIFY_STATUS_OK) {
        logmsg("notify_register_dispatch(%s) failed: %u — consumer diagnostics unavailable",
               NOTIF_NAME, rc);
    }

    uint32_t voice_rc = notify_register_dispatch(VOICE_NOTIF_NAME, &g_voice_token,
                                                  dispatch_get_main_queue(), ^(int t) {
        handle_voice_demand(t);
    });
    if (voice_rc != NOTIFY_STATUS_OK) {
        logmsg("notify_register_dispatch(%s) failed: %u — App-owned capture demand is unavailable",
               VOICE_NOTIF_NAME, voice_rc);
    }

    if (voice_rc == NOTIFY_STATUS_OK) publish_capture_service(1);
    if (rc == NOTIFY_STATUS_OK) handle_virtual_demand(token);
    if (voice_rc == NOTIFY_STATUS_OK) handle_voice_demand(g_voice_token);
    logmsg("watching voice demand on %s (consumer telemetry: %s)", VOICE_NOTIF_NAME,
           rc == NOTIFY_STATUS_OK ? NOTIF_NAME : "unavailable");
    dispatch_main();
    return 0;
}
