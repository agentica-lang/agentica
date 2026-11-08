/*
 * The choice of the coarse clock (vm/clock_posix.c) in both modes that AGENTICA_VM_TEST_COARSE_CLOCK forces: the libuv
 * hook agrees with agc_coarse_clock_ms whatever the kernel's tick, and libuv's loop time follows the choice. Each mode
 * runs in a child process, since the choice is made once per process. Linux only.
 */
#include "../core.h"

#include <assert.h>
#include <stdio.h>

#ifdef __linux__
#include <stdlib.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <uv.h>

static uint64_t ms_now(clockid_t id) {
  struct timespec ts;
  assert(clock_gettime(id, &ts) == 0);
  return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

/* The hook succeeds for the coarse clock, with 1 ms, exactly when the VM uses it, and fails otherwise whatever the
   kernel's real resolution: a pass-through on a HZ 1000 kernel (1 ms) would give libuv the coarse clock that the
   padding does not expect. Other clocks pass through. Then over a few ms sleeps, which reach every lag of the coarse
   clock: the loop time lies between two coarse reads around it in the coarse mode, and is never behind an exact read
   before it in the exact mode. Either check fails within a few rounds if libuv reads the other clock. */
static void check_mode(bool coarse) {
  assert(setenv("AGENTICA_VM_TEST_COARSE_CLOCK", coarse ? "1" : "0", 1) == 0);
  uint64_t before, after, tick;
  assert(agc_coarse_clock_ms(&before, &tick) == coarse);
  assert(agc_loop_clock_tick_ms() == (coarse ? tick : 0));
  struct timespec res;
  int got = agc_uv_clock_getres(CLOCK_MONOTONIC_COARSE, &res);
  if (coarse)
    assert(got == 0 && res.tv_sec == 0 && res.tv_nsec == 1000000);
  else
    assert(got == -1);
  assert(agc_uv_clock_getres(CLOCK_MONOTONIC, &res) == 0);
  uv_loop_t loop;
  assert(uv_loop_init(&loop) == 0);
  for (int k = 0; k < 24; k++) {
    before = coarse ? ms_now(CLOCK_MONOTONIC_COARSE) : ms_now(CLOCK_MONOTONIC);
    uv_update_time(&loop);
    uint64_t now = uv_now(&loop);
    if (coarse) {
      after = ms_now(CLOCK_MONOTONIC_COARSE);
      assert(before <= now && now <= after);
    } else {
      assert(now >= before);
    }
    uv_sleep(1);
  }
  assert(uv_loop_close(&loop) == 0);
}

static void in_child(bool coarse) {
  pid_t pid = fork();
  assert(pid >= 0);
  if (pid == 0) {
    check_mode(coarse);
    _exit(0);
  }
  int status = 0;
  assert(waitpid(pid, &status, 0) == pid);
  assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

int main(void) {
  in_child(true);
  in_child(false);
  puts("clock tests passed");
  return 0;
}
#else
int main(void) {
  puts("clock tests skipped: not Linux");
  return 0;
}
#endif
