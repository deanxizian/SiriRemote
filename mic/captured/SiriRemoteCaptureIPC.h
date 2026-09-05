#ifndef SIRI_REMOTE_CAPTURE_IPC_H
#define SIRI_REMOTE_CAPTURE_IPC_H

#include <Security/Security.h>
#include <xpc/xpc.h>

#define SRM_CAPTURE_SERVICE "com.deanxi.siriremote.capture"
#define SRM_APP_REQUIREMENT CFSTR("anchor apple generic and identifier \"com.deanxi.siriremote\" and certificate leaf[subject.OU] = \"96M7FW2XLU\"")
#define SRM_HELPER_REQUIREMENT CFSTR("anchor apple generic and identifier \"SiriRemoteCapture\" and certificate leaf[subject.OU] = \"96M7FW2XLU\"")

// Security derives the guest from the kernel-supplied audit token of this actual XPC message.
// No path, PID, UID, command or claimed signature from the request is trusted.
static inline int srm_message_is_authorized(xpc_object_t message, CFStringRef text)
{
    SecCodeRef code = NULL;
    SecRequirementRef requirement = NULL;
    OSStatus status = SecCodeCreateWithXPCMessage(message, kSecCSDefaultFlags, &code);
    if (status == errSecSuccess)
        status = SecRequirementCreateWithString(text, kSecCSDefaultFlags, &requirement);
    if (status == errSecSuccess)
        status = SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement);
    if (requirement) CFRelease(requirement);
    if (code) CFRelease(code);
    return status == errSecSuccess;
}

#endif
