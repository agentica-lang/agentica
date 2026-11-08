/*
 * The Linux and macOS side of the coarse clock (agc_coarse_clock_ms in core.h): Linux's CLOCK_MONOTONIC_COARSE, the
 * monotonic clock as of the last tick, read from the vDSO without touching the clock source, and the hook that makes
 * libuv's loop clock that clock too (agc_uv_clock_getres). macOS has no such clock. The Windows side is
 * vm/clock_windows.c. Core layer.
 */
#ifndef _WIN32
#include "core.h"

#include <stdatomic.h>
#include <time.h>

#if defined(__linux__)
#ifndef CLOCK_MONOTONIC_COARSE
#define CLOCK_MONOTONIC_COARSE 6
#endif

/* The coarse clock is used only where its tick is this short: the bound on how late a timer or Time.monotonic_ms may
   be. A kernel of HZ 100 or more has it. */
#define COARSE_TICK_MAX_MS 10

static uint64_t ms_of(const struct timespec *ts) {
  return (uint64_t)ts->tv_sec * 1000u + (uint64_t)ts->tv_nsec / 1000000u;
}

/* The tick in ms plus two, read once: 0 means "not read yet" (a race reads it twice, to the same value) and 1 means no
   usable coarse clock (none, or a tick past COARSE_TICK_MAX_MS). */
static uint64_t tick_plus_two(void) {
  static _Atomic uint64_t cached;
  uint64_t tick = atomic_load_explicit(&cached, memory_order_relaxed);
  if (!tick) {
    struct timespec res;
    tick = 1;
    if (clock_getres(CLOCK_MONOTONIC_COARSE, &res) == 0) {
      /* Rounded up: a tick of 3.33 ms (HZ 300) lags by more than 3 ms. */
      uint64_t ms = (uint64_t)res.tv_sec * 1000u + ((uint64_t)res.tv_nsec + 999999u) / 1000000u;
      if (ms <= COARSE_TICK_MAX_MS) tick = ms + 2;
    }
    atomic_store_explicit(&cached, tick, memory_order_relaxed);
  }
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
   its resolution is at most 1 ms, else CLOCK_MONOTONIC, which costs a system call per read on a host whose clock source
   has no vDSO path (an HPET), twice per turn of the loop. Saying 1 ms whenever agc_coarse_clock_ms has the clock makes
   the loop's clock the coarse one exactly when that function answers, which is how the VM knows to pad its timers by a
   tick (timer_length in vm/loop.c). uv_hrtime and Time.monotonic_ns keep CLOCK_MONOTONIC. */
int agc_uv_clock_getres(clockid_t id, struct timespec *res) {
  if (id != CLOCK_MONOTONIC_COARSE || tick_plus_two() == 1) return clock_getres(id, res);
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
#endif
