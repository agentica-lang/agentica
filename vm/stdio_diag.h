/*
 * Temporary Linux ThreadSanitizer diagnostics for issue 616. This header is removed after the CI probe; it does not
 * expose a runtime API. Records use an inherited nonblocking pipe so diagnostics never take a FILE lock or wait.
 * The event values and FD contract are private to the temporary test probe.
 */
#ifndef AGC_STDIO_DIAG_H
#define AGC_STDIO_DIAG_H

#if defined(__linux__) && defined(__clang__)
#if __has_feature(thread_sanitizer)
#define AGC_STDIO_DIAG_ENABLED 1
#endif
#endif

#include <stdint.h>

#ifdef AGC_STDIO_DIAG_ENABLED
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <unistd.h>
#endif

enum {
  AGC_DIAG_SETTLE_BEFORE = 16,
  AGC_DIAG_SETTLE_AFTER = 17,
  AGC_DIAG_OUTPUT_END_BEFORE = 18,
  AGC_DIAG_OUTPUT_END_AFTER = 19,
  AGC_DIAG_EXIT_BEFORE = 20,
  AGC_DIAG_STOP_BLOCKED = 21,
  AGC_DIAG_BEFORE_EXIT = 22,
  AGC_DIAG_TRYLOCK_BEFORE = 32,
  AGC_DIAG_TRYLOCK_AFTER = 33,
  AGC_DIAG_FFLUSH_BEFORE = 34,
  AGC_DIAG_FFLUSH_AFTER = 35,
  AGC_DIAG_UNLOCK_BEFORE = 36,
  AGC_DIAG_UNLOCK_AFTER = 37
};

#ifdef AGC_STDIO_DIAG_ENABLED
static inline void agc_stdio_diag(uint8_t event, uint8_t stream, int value) {
  int saved = errno;
  const char *text = getenv("AGC_616_TSAN_DIAG_FD");
  if (text && *text) {
    char *end = NULL;
    long parsed = strtol(text, &end, 10);
    if (end && !*end && parsed >= 3 && parsed <= INT_MAX) {
      int fd = (int)parsed;
      int flags = fcntl(fd, F_GETFL);
      if (flags >= 0 && (flags & O_NONBLOCK)) {
        uint8_t record[6] = {event, stream, (uint8_t)value, (uint8_t)((unsigned)value >> 8),
                             (uint8_t)((unsigned)value >> 16), (uint8_t)((unsigned)value >> 24)};
        (void)write(fd, record, sizeof record);
      }
    }
  }
  errno = saved;
}
#else
static inline void agc_stdio_diag(uint8_t event, uint8_t stream, int value) {
  (void)event;
  (void)stream;
  (void)value;
}
#endif

#endif
