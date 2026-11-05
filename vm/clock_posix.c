/*
 * The Linux and macOS side of the coarse clock (agc_coarse_clock_ms in core.h): Linux's CLOCK_MONOTONIC_COARSE, the
 * monotonic clock as of the last tick, read from the vDSO without touching the clock source. macOS has no such clock.
 * The Windows side is vm/clock_windows.c. Core layer.
 */
#ifndef _WIN32
#include "core.h"

#include <stdatomic.h>
#include <time.h>

#if defined(__linux__)
#ifndef CLOCK_MONOTONIC_COARSE
#define CLOCK_MONOTONIC_COARSE 6
#endif

static uint64_t ms_of(const struct timespec *ts) {
  return (uint64_t)ts->tv_sec * 1000u + (uint64_t)ts->tv_nsec / 1000000u;
}

/* The resolution is read once, plus one so that 0 means "not read yet" (a race reads it twice, to the same value). */
bool agc_coarse_clock_ms(uint64_t *now_ms, uint64_t *tick_ms) {
  static _Atomic uint64_t tick_plus_one;
  uint64_t tick = atomic_load_explicit(&tick_plus_one, memory_order_relaxed);
  if (!tick) {
    struct timespec res;
    if (clock_getres(CLOCK_MONOTONIC_COARSE, &res) != 0) return false;
    tick = ms_of(&res) + 1;
    atomic_store_explicit(&tick_plus_one, tick, memory_order_relaxed);
  }
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC_COARSE, &ts) != 0) return false;
  *now_ms = ms_of(&ts);
  *tick_ms = tick - 1;
  return true;
}
#else
bool agc_coarse_clock_ms(uint64_t *now_ms, uint64_t *tick_ms) {
  (void)now_ms;
  (void)tick_ms;
  return false;
}
#endif
#endif
