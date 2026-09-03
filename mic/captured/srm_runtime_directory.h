#ifndef SRM_RUNTIME_DIRECTORY_H
#define SRM_RUNTIME_DIRECTORY_H

#include <errno.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

// /private/var/run is intentionally cleared at boot. The daemon, not the installer, therefore owns
// recreating its private runtime directory. Reject files and symlinks so a privileged launch cannot
// be redirected outside the fixed SiriRemote path.
static inline int srm_prepare_runtime_directory(const char *path, uid_t required_owner)
{
    struct stat info;
    if (lstat(path, &info) != 0) {
        if (errno != ENOENT || mkdir(path, 0700) != 0) return -1;
        if (lstat(path, &info) != 0) return -1;
    }
    if (!S_ISDIR(info.st_mode) || info.st_uid != required_owner) {
        errno = !S_ISDIR(info.st_mode) ? ENOTDIR : EPERM;
        return -1;
    }
    return chmod(path, 0700);
}

#endif
