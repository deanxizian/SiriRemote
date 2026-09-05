// Exercise the real XPC audit-token validator, without granting the test a product identity.
#include <assert.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "SiriRemoteCaptureIPC.h"

int main(int argc, char **argv)
{
    int installed = argc == 2 && strcmp(argv[1], "--installed") == 0;
    assert(argc == 1 || installed);
    dispatch_queue_t queue = dispatch_queue_create("srm.auth.test", DISPATCH_QUEUE_SERIAL);
    xpc_connection_t client;
    if (installed) {
        client = xpc_connection_create_mach_service(SRM_CAPTURE_SERVICE, queue,
                                                   XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    } else {
        xpc_connection_t listener = xpc_connection_create(NULL, queue);
        assert(listener);
        xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
            assert(xpc_get_type(peer) == XPC_TYPE_CONNECTION);
            xpc_connection_set_target_queue(peer, queue);
            xpc_connection_set_event_handler(peer, ^(xpc_object_t request) {
                if (xpc_get_type(request) != XPC_TYPE_DICTIONARY) return;
                SecCodeRef sender = NULL;
                assert(SecCodeCreateWithXPCMessage(request, 0, &sender) == errSecSuccess);
                CFRelease(sender); // a real kernel-authenticated message, not a mock
                xpc_object_t reply = xpc_dictionary_create_reply(request);
                xpc_dictionary_set_bool(reply, "accepted",
                                         srm_message_is_authorized(request, SRM_APP_REQUIREMENT));
                xpc_connection_send_message(peer, reply);
                xpc_release(reply);
            });
            xpc_connection_resume(peer);
        });
        xpc_connection_resume(listener);
        xpc_endpoint_t endpoint = xpc_endpoint_create(listener);
        client = xpc_connection_create_from_endpoint(endpoint);
        xpc_release(endpoint);
        xpc_connection_set_target_queue(client, queue);
    }
    assert(client);
    xpc_connection_set_event_handler(client, ^(xpc_object_t event) { (void)event; });
    xpc_connection_resume(client);
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "operation", "begin");
    xpc_dictionary_set_uint64(message, "session", 1);
    xpc_dictionary_set_uint64(message, "pid", getpid());
    xpc_dictionary_set_string(message, "identifier", "com.deanxi.siriremote");
    xpc_dictionary_set_string(message, "team", "96M7FW2XLU");
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block int rejected = 0;
    xpc_connection_send_message_with_reply(client, message, queue, ^(xpc_object_t reply) {
        rejected = xpc_get_type(reply) == XPC_TYPE_DICTIONARY &&
                   xpc_dictionary_get_value(reply, "accepted") != NULL &&
                   !xpc_dictionary_get_bool(reply, "accepted");
        dispatch_semaphore_signal(done);
    });
    assert(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
    assert(rejected);
    xpc_connection_cancel(client);
    puts(installed ? "installed Capture rejected non-product XPC caller: PASS"
                   : "XPC audit-token / forged product identity rejection: PASS");
    return 0;
}
