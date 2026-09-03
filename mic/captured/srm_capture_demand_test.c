#include <stdio.h>

#include "srm_capture_demand.h"

static unsigned g_failures = 0;

#define CHECK(condition, message) do { \
    if (!(condition)) { \
        fprintf(stderr, "capture demand test: FAIL: %s\n", message); \
        ++g_failures; \
    } \
} while (0)

int main(void)
{
    CHECK(!srm_capture_should_run(0, 0, 0),
          "idle state started the pipeline");
    CHECK(!srm_capture_should_run(1, 0, 0),
          "one persistent virtual-mic consumer started the pipeline");
    CHECK(!srm_capture_should_run(UINT64_MAX, 0, 0),
          "virtual-mic consumer count affected capture policy");
    CHECK(!srm_capture_should_run(1, 321, 0),
          "a dead voice owner started the pipeline");
    CHECK(!srm_capture_should_run(0, 0, 1),
          "an invalid voice PID started the pipeline");
    CHECK(srm_capture_should_run(0, 321, 1),
          "a live App voice lease did not start the pipeline");
    CHECK(srm_capture_should_run(7, 321, 1),
          "virtual consumers suppressed a valid App voice lease");

    if (g_failures != 0) return 1;
    puts("capture demand test: PASS");
    return 0;
}
