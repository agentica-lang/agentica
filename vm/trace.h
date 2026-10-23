/*
 * The VM trace state: the agc_trace struct, the category bits, and the
 * AGC_TRACE macros that the core uses to emit events. Core header. Design:
 * docs/vm/08-loader-and-cli.md §9.
 */
#ifndef AGC_TRACE_H
#define AGC_TRACE_H

#include <limits.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifndef AGC_TRACE_BUILD
#define AGC_TRACE_BUILD 1
#endif

#define AGC_TRACE_LINE 512
#define AGC_TRACE_ON(tr, category) (AGC_TRACE_BUILD && ((tr)->mask & (category)))
#define AGC_TRACE(tr, category, ...)                                          \
  do {                                                                        \
    if (AGC_TRACE_ON(tr, category)) agc_trace_emit((tr), (category), __VA_ARGS__); \
  } while (0)

#if defined(__MINGW32__)
#define AGC_PRINTF_FORMAT(format_index, first_argument) \
  __attribute__((format(gnu_printf, format_index, first_argument)))
#else
#define AGC_PRINTF_FORMAT(format_index, first_argument) \
  __attribute__((format(printf, format_index, first_argument)))
#endif

/* The event categories. The profile counts every step and call, which slows the run, so "all" leaves it out. */
enum {
  AGC_TRACE_SCHED = 1u << 0,
  AGC_TRACE_IO = 1u << 1,
  AGC_TRACE_PROC = 1u << 2,
  AGC_TRACE_TLS = 1u << 3,
  AGC_TRACE_LOADER = 1u << 4,
  AGC_TRACE_GC = 1u << 5,
  AGC_TRACE_PROFILE = 1u << 6,
  AGC_TRACE_JIT = 1u << 7,
  AGC_TRACE_ALL = ((1u << 6) - 1) | AGC_TRACE_JIT
};

/* `profile_every`: the profile writes folded stacks sampled every that many steps instead of its report
   (AGENTICA_PROFILE_FORMAT=folded), or 0. `profile_stacks`: the most distinct stacks it keeps, or 0 for its own limit
   (set only by the test switch AGENTICA_VM_TEST_PROFILE_STACKS). */
typedef struct {
  unsigned mask;
  int fd;
  uint64_t start_ns;
  uint64_t profile_every;
  uint32_t profile_stacks;
} agc_trace;

typedef struct {
  size_t len;
  bool cut, quoted;
  char data[AGC_TRACE_LINE];
} agc_trace_line;

static inline int agc_trace_len(size_t n) { return n > INT_MAX ? INT_MAX : (int)n; }

uint64_t agc_trace_now(void);
void agc_trace_parse(agc_trace *trace, const char *names, int fd);
unsigned agc_trace_mask(const char *names);
void agc_trace_message(int fd, const char *text, const char *value, size_t len, bool quoted);
void agc_trace_write(int fd, const char *data, size_t len);
void agc_trace_format(agc_trace_line *line, const agc_trace *trace, unsigned category, const char *format, ...)
  AGC_PRINTF_FORMAT(4, 5);
void agc_trace_emit(const agc_trace *trace, unsigned category, const char *format, ...)
  AGC_PRINTF_FORMAT(3, 4);

#undef AGC_PRINTF_FORMAT

#endif
