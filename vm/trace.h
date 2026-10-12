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

enum {
  AGC_TRACE_SCHED = 1u << 0,
  AGC_TRACE_IO = 1u << 1,
  AGC_TRACE_PROC = 1u << 2,
  AGC_TRACE_TLS = 1u << 3,
  AGC_TRACE_LOADER = 1u << 4,
  AGC_TRACE_GC = 1u << 5,
  AGC_TRACE_ALL = (1u << 6) - 1
};

typedef struct {
  unsigned mask;
  int fd;
  uint64_t start_ns;
} agc_trace;

typedef struct {
  size_t len;
  bool cut, quoted;
  char data[AGC_TRACE_LINE];
} agc_trace_line;

static inline int agc_trace_len(size_t n) { return n > INT_MAX ? INT_MAX : (int)n; }

uint64_t agc_trace_now(void);
void agc_trace_parse(agc_trace *trace, const char *names, int fd);
void agc_trace_message(int fd, const char *text, const char *value, size_t len, bool quoted);
void agc_trace_format(agc_trace_line *line, const agc_trace *trace, unsigned category, const char *format, ...)
  __attribute__((format(printf, 4, 5)));
void agc_trace_emit(const agc_trace *trace, unsigned category, const char *format, ...)
  __attribute__((format(printf, 3, 4)));

#endif
