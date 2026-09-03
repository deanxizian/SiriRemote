#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <libproc.h>

static int parse_positive_number(const char *text, unsigned long maximum,
                                 unsigned long *value)
{
    errno = 0;
    char *end = NULL;
    unsigned long parsed = strtoul(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || parsed == 0 || parsed > maximum) {
        return 0;
    }
    *value = parsed;
    return 1;
}

int main(int argc, char **argv)
{
    if (argc != 4) {
        fprintf(stderr, "usage: %s pid expected-uid expected-executable\n", argv[0]);
        return 2;
    }

    unsigned long parsed_pid = 0;
    unsigned long parsed_uid = 0;
    if (!parse_positive_number(argv[1], INT_MAX, &parsed_pid)
        || !parse_positive_number(argv[2], UINT_MAX, &parsed_uid)) {
        fprintf(stderr, "invalid process identity arguments\n");
        return 2;
    }

    pid_t pid = (pid_t)parsed_pid;
    struct proc_bsdshortinfo process = { 0 };
    int info_size = proc_pidinfo(
        pid, PROC_PIDT_SHORTBSDINFO, 0, &process, (int)sizeof process
    );
    char executable[PROC_PIDPATHINFO_MAXSIZE] = { 0 };
    int path_size = proc_pidpath(pid, executable, sizeof executable);
    if (info_size != (int)sizeof process || path_size <= 0
        || process.pbsi_pid != (uint32_t)pid) {
        fprintf(stderr, "cannot query process %d\n", pid);
        return 1;
    }

    uid_t expected_uid = (uid_t)parsed_uid;
    if (process.pbsi_uid != expected_uid || process.pbsi_ruid != expected_uid
        || strcmp(executable, argv[3]) != 0) {
        fprintf(stderr, "process %d has uid %u/%u and executable %s\n",
                pid, process.pbsi_uid, process.pbsi_ruid, executable);
        return 1;
    }
    return 0;
}
