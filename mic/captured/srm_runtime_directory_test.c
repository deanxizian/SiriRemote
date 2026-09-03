#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "srm_runtime_directory.h"

static unsigned g_failures = 0;

#define CHECK(condition, message) do { \
    if (!(condition)) { \
        fprintf(stderr, "runtime directory test: FAIL: %s\n", message); \
        ++g_failures; \
    } \
} while (0)

int main(void)
{
    char parent[] = "/tmp/siriremote-runtime-test.XXXXXX";
    CHECK(mkdtemp(parent) != NULL, "could not create temporary parent");

    char runtime[PATH_MAX];
    snprintf(runtime, sizeof runtime, "%s/runtime", parent);
    CHECK(srm_prepare_runtime_directory(runtime, geteuid()) == 0,
          "missing runtime directory was not created");

    struct stat info;
    CHECK(lstat(runtime, &info) == 0 && S_ISDIR(info.st_mode),
          "created runtime path is not a directory");
    CHECK((info.st_mode & 0777) == 0700, "runtime directory mode is not 0700");

    CHECK(chmod(runtime, 0755) == 0, "could not loosen test directory mode");
    CHECK(srm_prepare_runtime_directory(runtime, geteuid()) == 0,
          "existing runtime directory was rejected");
    CHECK(lstat(runtime, &info) == 0 && (info.st_mode & 0777) == 0700,
          "existing runtime directory mode was not repaired");

    CHECK(rmdir(runtime) == 0, "could not remove test runtime directory");
    int descriptor = open(runtime, O_WRONLY | O_CREAT | O_EXCL, 0600);
    CHECK(descriptor >= 0, "could not create unsafe regular-file fixture");
    if (descriptor >= 0) close(descriptor);
    CHECK(srm_prepare_runtime_directory(runtime, geteuid()) != 0,
          "regular file was accepted as the runtime directory");
    unlink(runtime);

    CHECK(symlink(parent, runtime) == 0, "could not create unsafe symlink fixture");
    CHECK(srm_prepare_runtime_directory(runtime, geteuid()) != 0,
          "symlink was accepted as the runtime directory");
    unlink(runtime);
    rmdir(parent);

    if (g_failures != 0) return 1;
    puts("runtime directory test: PASS");
    return 0;
}
