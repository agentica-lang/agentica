/*
 * The Windows side of the coarse clock (agc_coarse_clock_ms in core.h). Windows has no monotonic clock that is read
 * without the clock source, so there is none here: every caller reads agc_clock_ms.
 * The Linux and macOS side is vm/clock_posix.c. Core layer.
 */
#ifdef _WIN32
#include "core.h"

bool agc_coarse_clock_ms(uint64_t *now_ms, uint64_t *tick_ms) {
  (void)now_ms;
  (void)tick_ms;
  return false;
}

uint64_t agc_loop_clock_tick_ms(void) { return 0; }
#endif
