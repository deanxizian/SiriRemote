#include "RemoteAudioState.h"
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <string.h>
#include "../mic/captured/SiriRemoteCaptureIPC.h"

// The UI never opens PCM. This cache contains only a few counters from an authenticated helper.
// IPC replies run off the UI thread; one outstanding query bounds latency and memory use.
static dispatch_queue_t gQueue;
static xpc_connection_t gConnection;
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t gSession, gGeneration, gWrite, gRead, gEpoch, gUpdatedAt;
static uint32_t gProducer, gConsumers;
static int gAvailable, gAuthenticated, gQueryPending;
static uint64_t gFreshnessTicks;

static void initialize_client(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gQueue = dispatch_queue_create("com.deanxi.siriremote.capture.client", DISPATCH_QUEUE_SERIAL);
        mach_timebase_info_data_t info;
        mach_timebase_info(&info);
        gFreshnessTicks = NSEC_PER_SEC * (uint64_t)info.denom / info.numer / 4;
    });
}
static void invalidate_cache(void)
{
    pthread_mutex_lock(&gLock);
    gAvailable = 0;
    gProducer = 0;
    gUpdatedAt = 0;
    pthread_mutex_unlock(&gLock);
}
static void send_request(const char *operation, uint64_t session, uint64_t end_frame)
{
    if (!gConnection) {
        gConnection = xpc_connection_create_mach_service(SRM_CAPTURE_SERVICE, gQueue,
                                                        XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
        if (!gConnection) { gQueryPending = 0; invalidate_cache(); return; }
        xpc_connection_t connection = gConnection;
        xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
            if (gConnection != connection) return;
            if (xpc_get_type(event) == XPC_TYPE_ERROR) {
                gAuthenticated = 0;
                gQueryPending = 0;
                invalidate_cache();
                if (event == XPC_ERROR_CONNECTION_INVALID) {
                    gConnection = NULL;
                    xpc_release(connection);
                }
            }
        });
        xpc_connection_resume(connection);
    }
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, "operation", operation);
    xpc_dictionary_set_uint64(request, "session", session);
    xpc_dictionary_set_uint64(request, "endFrame", end_frame);
    xpc_connection_t connection = gConnection;
    int snapshot = strcmp(operation, "snapshot") == 0;
    xpc_connection_send_message_with_reply(connection, request, gQueue, ^(xpc_object_t reply) {
        if (connection != gConnection) return;
        if (snapshot) gQueryPending = 0;
        if (xpc_get_type(reply) != XPC_TYPE_DICTIONARY ||
            (!gAuthenticated && (xpc_connection_get_euid(connection) != 0 ||
                                 !srm_message_is_authorized(reply, SRM_HELPER_REQUIREMENT)))) {
            invalidate_cache();
            return;
        }
        gAuthenticated = 1;
        pthread_mutex_lock(&gLock);
        if (session == gSession && xpc_dictionary_get_uint64(reply, "session") == gSession) {
            gAvailable = xpc_dictionary_get_bool(reply, "accepted") &&
                         xpc_dictionary_get_bool(reply, "available");
            gGeneration = xpc_dictionary_get_uint64(reply, "generation");
            gWrite = xpc_dictionary_get_uint64(reply, "writeIndex");
            gRead = xpc_dictionary_get_uint64(reply, "readIndex");
            gEpoch = xpc_dictionary_get_uint64(reply, "startIOEpoch");
            gProducer = xpc_dictionary_get_bool(reply, "producerActive");
            gConsumers = (uint32_t)xpc_dictionary_get_uint64(reply, "consumerCount");
            gUpdatedAt = mach_absolute_time();
        }
        pthread_mutex_unlock(&gLock);
    });
    xpc_release(request);
}
int srm_capture_set_active(int active, uint64_t session)
{
    initialize_client();
    if (!session) return -1;
    pthread_mutex_lock(&gLock);
    gSession = active ? session : 0;
    gAvailable = 0;
    gProducer = 0;
    pthread_mutex_unlock(&gLock);
    dispatch_async(gQueue, ^{ send_request(active ? "begin" : "end", session, 0); });
    return 0;
}
void srm_capture_seal(uint64_t session, uint64_t end_frame)
{
    initialize_client();
    dispatch_async(gQueue, ^{ send_request("seal", session, end_frame); });
}
int srm_remote_audio_state(uint64_t *generation, uint64_t *write_index, uint64_t *read_index,
                           uint32_t *producer_active, uint32_t *consumer_count,
                           uint64_t *start_io_epoch)
{
    if (!generation || !write_index || !read_index || !producer_active ||
        !consumer_count || !start_io_epoch) return -1;
    initialize_client();
    pthread_mutex_lock(&gLock);
    uint64_t session = gSession;
    int valid = gAvailable && gUpdatedAt && mach_absolute_time() - gUpdatedAt < gFreshnessTicks;
    *generation = gGeneration;
    *write_index = gWrite;
    *read_index = gRead;
    *producer_active = valid && gProducer;
    *consumer_count = gConsumers;
    *start_io_epoch = gEpoch;
    pthread_mutex_unlock(&gLock);
    if (session) dispatch_async(gQueue, ^{
        if (!gQueryPending) { gQueryPending = 1; send_request("snapshot", session, 0); }
    });
    return valid ? 0 : -1;
}
void srm_remote_audio_state_close(void)
{
    initialize_client();
    dispatch_sync(gQueue, ^{
        if (gConnection) {
            xpc_connection_t previous = gConnection;
            gConnection = NULL;
            xpc_connection_cancel(previous);
            xpc_release(previous);
        }
        gAuthenticated = 0;
        gQueryPending = 0;
        pthread_mutex_lock(&gLock);
        gSession = 0;
        pthread_mutex_unlock(&gLock);
        invalidate_cache();
    });
}

int srm_capture_check_service(void)
{
    initialize_client();
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_retain(done); // the asynchronous reply may outlive the caller's bounded wait
    __block int accepted = 0;
    dispatch_async(gQueue, ^{
        xpc_connection_t connection = xpc_connection_create_mach_service(
            SRM_CAPTURE_SERVICE, gQueue, XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
        if (!connection) { dispatch_semaphore_signal(done); dispatch_release(done); return; }
        xpc_connection_set_event_handler(connection, ^(xpc_object_t event) { (void)event; });
        xpc_connection_resume(connection);
        xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(request, "operation", "snapshot");
        xpc_connection_send_message_with_reply(connection, request, gQueue, ^(xpc_object_t reply) {
            accepted = xpc_get_type(reply) == XPC_TYPE_DICTIONARY &&
                       xpc_connection_get_euid(connection) == 0 &&
                       srm_message_is_authorized(reply, SRM_HELPER_REQUIREMENT) &&
                       xpc_dictionary_get_bool(reply, "accepted");
            xpc_connection_cancel(connection);
            xpc_release(connection);
            dispatch_semaphore_signal(done);
            dispatch_release(done);
        });
        xpc_release(request);
    });
    long timed_out = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    dispatch_release(done);
    return !timed_out && accepted ? 0 : -1;
}
