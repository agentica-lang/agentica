/*
 * The Linux and macOS side of the coarse clock (agc_coarse_clock_ms in core.h): Linux's CLOCK_MONOTONIC_COARSE, the
 * monotonic clock as of the last tick, read from the vDSO without touching the clock source, used where an exact read
 * is a system call, and the hook that makes libuv's loop clock that clock too (agc_uv_clock_getres). macOS has no
 * such clock. Both have the CPU clock of a thread (agc_thread_cpu_ns). The Windows side is vm/clock_windows.c. Core
 * layer.
 */
#ifndef _WIN32
/* macOS declares CLOCK_THREAD_CPUTIME_ID only for _DARWIN_C_SOURCE under _POSIX_C_SOURCE. */
#define _DARWIN_C_SOURCE
#include "core.h"

#include <errno.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <time.h>

#if defined(__linux__)
#ifndef CLOCK_MONOTONIC_COARSE
#define CLOCK_MONOTONIC_COARSE 6
#endif

/* The coarse clock is used only where its tick is this short: the bound on how late a timer or Time.monotonic_ms may
   be. A kernel of HZ 100 or more has it. */
#define COARSE_TICK_MAX_MS 10

/* An exact read that takes longer than this is a system call: the vDSO reads a TSC or an arm64 counter in tens of ns,
   a read of an HPET through the kernel takes about a microsecond. */
#define EXACT_READ_COSTLY_NS 200
#define COST_SAMPLES 16

static uint64_t ms_of(const struct timespec *ts) {
  return (uint64_t)ts->tv_sec * 1000u + (uint64_t)ts->tv_nsec / 1000000u;
}

static uint64_t exact_ns(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
  return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
}

/* Whether a read of CLOCK_MONOTONIC costs a system call, timed by the clock itself: the smallest gap between
   consecutive reads, which a preemption or a cold cache only makes longer. Timing the read, not naming the clock
   source (/sys/.../current_clocksource), also covers sources without a vDSO path that a list would miss, a disabled
   vDSO and a container without /sys. AGENTICA_VM_TEST_COARSE_CLOCK=1 or =0 decides instead, so the tests cover both
   modes on any host. */
static bool exact_read_costly(void) {
  const char *forced = getenv("AGENTICA_VM_TEST_COARSE_CLOCK");
  if (forced && (forced[0] == '0' || forced[0] == '1') && !forced[1]) return forced[0] == '1';
  uint64_t best = UINT64_MAX, prev = exact_ns();
  for (int k = 0; k < COST_SAMPLES; k++) {
    uint64_t now = exact_ns();
    if (now >= prev && now - prev < best) best = now - prev;
    prev = now;
  }
  return best > EXACT_READ_COSTLY_NS;
}

/* The tick in ms plus two, decided once: 0 means "not decided yet" and 1 means no coarse clock in use (none, a tick
   past COARSE_TICK_MAX_MS, or an exact read that is cheap). The first decision wins the exchange, so racing first
   callers, whose timings may differ, all keep one answer: libuv's loop clock and the padding of its timers must
   agree. */
static uint64_t tick_plus_two(void) {
  static _Atomic uint64_t cached;
  uint64_t tick = atomic_load_explicit(&cached, memory_order_relaxed);
  if (tick) return tick;
  struct timespec res;
  tick = 1;
  if (clock_getres(CLOCK_MONOTONIC_COARSE, &res) == 0) {
    /* Rounded up: a tick of 3.33 ms (HZ 300) lags by more than 3 ms. */
    uint64_t ms = (uint64_t)res.tv_sec * 1000u + ((uint64_t)res.tv_nsec + 999999u) / 1000000u;
    if (ms <= COARSE_TICK_MAX_MS && exact_read_costly()) tick = ms + 2;
  }
  uint64_t unset = 0;
  if (!atomic_compare_exchange_strong_explicit(&cached, &unset, tick, memory_order_relaxed, memory_order_relaxed))
    return unset;
  return tick;
}

bool agc_coarse_clock_ms(uint64_t *now_ms, uint64_t *tick_ms) {
  uint64_t tick = tick_plus_two();
  if (tick == 1) return false;
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC_COARSE, &ts) != 0) return false;
  *now_ms = ms_of(&ts);
  *tick_ms = tick - 2;
  return true;
}

uint64_t agc_loop_clock_tick_ms(void) {
  uint64_t tick = tick_plus_two();
  return tick == 1 ? 0 : tick - 2;
}

/* libuv's clock_getres (mk/vm.mk compiles the vendored libuv with -Dclock_getres=agc_uv_clock_getres on Linux). libuv
   reads it once, in uv__hrtime, to pick its fast clock, the one of the loop's time and timers: the coarse clock when
   the call succeeds with a resolution of at most 1 ms, else CLOCK_MONOTONIC, which costs a system call per read on a
   host whose clock source has no vDSO path (an HPET), twice per turn of the loop. The answer decides both ways: 1 ms
   when agc_coarse_clock_ms uses the coarse clock, and a failure when it does not, so that a kernel whose coarse clock
   really has a 1 ms tick (HZ 1000) does not get it either. The loop's clock is then the coarse one exactly when that
   function answers, which is how the VM knows to pad its timers by the coarse clock's lag (timer_length in vm/loop.c).
   uv_hrtime and Time.monotonic_ns keep CLOCK_MONOTONIC. */
int agc_uv_clock_getres(clockid_t id, struct timespec *res) {
  if (id != CLOCK_MONOTONIC_COARSE) return clock_getres(id, res);
  if (tick_plus_two() == 1) {
    errno = EINVAL;
    return -1;
  }
  *res = (struct timespec){.tv_sec = 0, .tv_nsec = 1000000};
  return 0;
}
#else
bool agc_coarse_clock_ms(uint64_t *now_ms, uint64_t *tick_ms) {
  (void)now_ms;
  (void)tick_ms;
  return false;
}

uint64_t agc_loop_clock_tick_ms(void) { return 0; }
#endif

/* CLOCK_THREAD_CPUTIME_ID, the scheduler's exact count of the thread's run time, not getrusage(RUSAGE_THREAD), whose
   times Linux samples at the tick (whole ticks of 1 to 10 ms). */
bool agc_thread_cpu_ns(uint64_t *ns) {
#ifdef CLOCK_THREAD_CPUTIME_ID
  struct timespec ts;
  if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) != 0) return false;
  *ns = (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
  return true;
#else
  (void)ns;
  return false;
#endif
}
#endif
