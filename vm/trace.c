/*
 * VM tracing (AGENTICA_VM_TRACE): the parser for the categories, the message
 * and line formatting, and the emitter that writes one line with one write(2).
 * The profile category (calls and steps of each function, time in each builtin)
 * is counted by interp.c and written here at the end of a run.
 * Core layer. Design: docs/vm/08-loader-and-cli.md §9 and
 * docs/future/24-logging.md §24.4.
 */
#include "core.h"

#include <errno.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define CUT_MARK "..."
#define CUT_BYTES (sizeof CUT_MARK - 1)
#define NUMBER_TEXT 48
#define PROFILE_TOP 30
#define PROFILE_FILES 12
#define CONTENT_LIMIT (AGC_TRACE_LINE - 1 - CUT_BYTES)

typedef enum { LEN_INT, LEN_CHAR, LEN_SHORT, LEN_LONG, LEN_LLONG, LEN_SIZE, LEN_MAX, LEN_PTRDIFF } length_kind;

static const char *const category_names[] = {"sched", "io", "proc", "tls", "loader", "gc", "profile"};
static const char hex_digits[] = "0123456789abcdef";

static size_t utf8_width(unsigned char c) { return c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : c >= 0xC0 ? 2 : 1; }

static void drop_partial_utf8(agc_trace_line *l) {
  size_t i = l->len, tail = 0;
  while (i > 0 && tail < 3 && ((unsigned char)l->data[i - 1] & 0xC0) == 0x80) {
    i--;
    tail++;
  }
  if (i > 0 && utf8_width((unsigned char)l->data[i - 1]) > tail + 1) l->len = i - 1;
}

static void put(agc_trace_line *l, const char *s, size_t n) {
  if (l->cut) return;
  size_t room = CONTENT_LIMIT - l->len;
  bool fits = n <= room;
  if (!fits) n = room;
  if (n) memcpy(l->data + l->len, s, n);
  l->len += n;
  if (fits) return;
  l->cut = true;
  drop_partial_utf8(l);
}

static void put_char(agc_trace_line *l, char c) { put(l, &c, 1); }

static bool put_unit(agc_trace_line *l, const char *s, size_t n) {
  if (l->cut || l->len + n > CONTENT_LIMIT - 1) {
    l->cut = true;
    return false;
  }
  memcpy(l->data + l->len, s, n);
  l->len += n;
  return true;
}

static bool special(unsigned char c) { return c <= 0x20 || c == 0x7f || c == '=' || c == '"' || c == '\\'; }

static bool plain(const char *s, size_t n) {
  if (!n) return false;
  for (size_t i = 0; i < n;) {
    if (special((unsigned char)s[i])) return false;
    size_t k = agc_utf8_valid((const uint8_t *)s + i, n - i);
    if (!k) return false;
    i += k;
  }
  return true;
}

static size_t hex_escape(unsigned char c, char esc[6]) {
  esc[0] = '\\';
  esc[1] = 'u';
  esc[2] = '0';
  esc[3] = '0';
  esc[4] = hex_digits[c >> 4];
  esc[5] = hex_digits[c & 15];
  return 6;
}

static size_t escape_of(unsigned char c, char esc[6]) {
  esc[0] = '\\';
  switch (c) {
    case '"': esc[1] = '"'; return 2;
    case '\\': esc[1] = '\\'; return 2;
    case '\b': esc[1] = 'b'; return 2;
    case '\f': esc[1] = 'f'; return 2;
    case '\n': esc[1] = 'n'; return 2;
    case '\r': esc[1] = 'r'; return 2;
    case '\t': esc[1] = 't'; return 2;
    default: break;
  }
  if (c >= 0x20 && c != 0x7f) return 0;
  return hex_escape(c, esc);
}

static void put_quoted(agc_trace_line *l, const char *s, size_t n) {
  if (!put_unit(l, "\"", 1)) return;
  l->quoted = true;
  for (size_t i = 0; i < n;) {
    unsigned char c = (unsigned char)s[i];
    char esc[6];
    size_t k = escape_of(c, esc);
    size_t valid = k ? 0 : agc_utf8_valid((const uint8_t *)s + i, n - i);
    if (!k && !valid) k = hex_escape(c, esc);
    if (valid ? !put_unit(l, s + i, valid) : !put_unit(l, esc, k)) return;
    i += valid ? valid : 1;
  }
  l->data[l->len++] = '"';
  l->quoted = false;
}

static void put_text(agc_trace_line *l, const char *s, size_t n) {
  if (!s) n = 0;
  if (plain(s, n))
    put(l, s, n);
  else
    put_quoted(l, s, n);
}

static void put_printed(agc_trace_line *l, const char *text, int n) {
  if (n <= 0) return;
  size_t k = (size_t)n < NUMBER_TEXT ? (size_t)n : NUMBER_TEXT - 1;
  put(l, text, k);
}

static void put_signed(agc_trace_line *l, length_kind len, va_list *ap) {
  intmax_t v;
  switch (len) {
    case LEN_CHAR: {
      intmax_t byte = va_arg(*ap, int) & 0xFF;
      v = byte > 0x7F ? byte - 0x100 : byte;
      break;
    }
    case LEN_SHORT: v = (short)va_arg(*ap, int); break;
    case LEN_LONG: v = va_arg(*ap, long); break;
    case LEN_LLONG: v = va_arg(*ap, long long); break;
    case LEN_SIZE:
    case LEN_PTRDIFF: v = va_arg(*ap, ptrdiff_t); break;
    case LEN_MAX: v = va_arg(*ap, intmax_t); break;
    default: v = va_arg(*ap, int);
  }
  char text[NUMBER_TEXT];
  put_printed(l, text, snprintf(text, sizeof text, "%jd", v));
}

static void put_unsigned(agc_trace_line *l, length_kind len, char conversion, va_list *ap) {
  uintmax_t v;
  switch (len) {
    case LEN_CHAR: v = (unsigned char)va_arg(*ap, unsigned); break;
    case LEN_SHORT: v = (unsigned short)va_arg(*ap, unsigned); break;
    case LEN_LONG: v = va_arg(*ap, unsigned long); break;
    case LEN_LLONG: v = va_arg(*ap, unsigned long long); break;
    case LEN_SIZE: v = va_arg(*ap, size_t); break;
    case LEN_PTRDIFF: v = (uintmax_t)va_arg(*ap, ptrdiff_t); break;
    case LEN_MAX: v = va_arg(*ap, uintmax_t); break;
    default: v = va_arg(*ap, unsigned);
  }
  char text[NUMBER_TEXT];
  const char *spec = conversion == 'x' ? "%jx" : conversion == 'X' ? "%jX" : "%ju";
  put_printed(l, text, snprintf(text, sizeof text, spec, v));
}

static const char *length_of(const char *f, length_kind *len) {
  *len = LEN_INT;
  switch (*f) {
    case 'h':
      if (f[1] == 'h') {
        *len = LEN_CHAR;
        return f + 2;
      }
      *len = LEN_SHORT;
      return f + 1;
    case 'l':
      if (f[1] == 'l') {
        *len = LEN_LLONG;
        return f + 2;
      }
      *len = LEN_LONG;
      return f + 1;
    case 'z': *len = LEN_SIZE; return f + 1;
    case 'j': *len = LEN_MAX; return f + 1;
    case 't': *len = LEN_PTRDIFF; return f + 1;
    default: return f;
  }
}

static void put_format(agc_trace_line *l, const char *format, va_list *ap) {
  for (const char *f = format; *f && !l->cut; f++) {
    if (*f != '%') {
      const char *next = strchr(f, '%');
      size_t n = next ? (size_t)(next - f) : strlen(f);
      put(l, f, n);
      f += n - 1;
      continue;
    }
    f++;
    if (*f == '%') {
      put_char(l, '%');
      continue;
    }
    bool precision = f[0] == '.' && f[1] == '*';
    if (precision) f += 2;
    length_kind len;
    f = length_of(f, &len);
    if (*f == 's' && len == LEN_INT) {
      if (precision) {
        int n = va_arg(*ap, int);
        const char *s = va_arg(*ap, const char *);
        put_text(l, s, n > 0 ? (size_t)n : 0);
      } else {
        const char *s = va_arg(*ap, const char *);
        put_text(l, s, s ? strlen(s) : 0);
      }
    } else if (!precision && (*f == 'd' || *f == 'i')) {
      put_signed(l, len, ap);
    } else if (!precision && (*f == 'u' || *f == 'x' || *f == 'X')) {
      put_unsigned(l, len, *f, ap);
    } else {
      put_char(l, '?');
      return;
    }
  }
}

static const char *category_name(unsigned category) {
  for (size_t k = 0; k < sizeof category_names / sizeof category_names[0]; k++)
    if (category == 1u << k) return category_names[k];
  return "?";
}

static void start_line(agc_trace_line *l, const agc_trace *trace, unsigned category) {
  l->len = 0;
  l->cut = false;
  l->quoted = false;
  uint64_t now = agc_trace_now();
  uint64_t d = now > trace->start_ns ? now - trace->start_ns : 0;
  char text[NUMBER_TEXT];
  put(l, "agc-trace +", 11);
  put_printed(l, text,
              snprintf(text, sizeof text, "%" PRIu64 ".%06" PRIu64 " ", d / 1000000000u, (d % 1000000000u) / 1000u));
  const char *name = category_name(category);
  put(l, name, strlen(name));
  put_char(l, ' ');
}

static void end_line(agc_trace_line *l) {
  if (l->cut) {
    if (l->quoted) l->data[l->len++] = '"';
    memcpy(l->data + l->len, CUT_MARK, CUT_BYTES);
    l->len += CUT_BYTES;
  }
  l->data[l->len++] = '\n';
}

static void write_line(int fd, const agc_trace_line *l) {
  size_t done = 0;
  while (done < l->len) {
    ssize_t n = write(fd, l->data + done, l->len - done);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return;
    done += (size_t)n;
  }
}

static unsigned category_bit(const char *name, size_t n) {
  if (n == 3 && memcmp(name, "all", 3) == 0) return AGC_TRACE_ALL;
  for (size_t k = 0; k < sizeof category_names / sizeof category_names[0]; k++)
    if (strlen(category_names[k]) == n && memcmp(category_names[k], name, n) == 0) return 1u << k;
  return 0;
}

uint64_t agc_trace_now(void) {
  int saved = errno;
  struct timespec ts;
  uint64_t now = 0;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0) now = (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
  errno = saved;
  return now;
}

void agc_trace_message(int fd, const char *text, const char *value, size_t len, bool quoted) {
  int saved = errno;
  agc_trace_line l;
  l.len = 0;
  l.cut = false;
  l.quoted = false;
  put(&l, "agc-trace ", 10);
  put(&l, text, strlen(text));
  put_char(&l, ' ');
  if (quoted)
    put_quoted(&l, value, value ? len : 0);
  else
    put_text(&l, value, len);
  end_line(&l);
  write_line(fd, &l);
  errno = saved;
}

void agc_trace_parse(agc_trace *trace, const char *names, int fd) {
  trace->mask = 0;
  trace->fd = fd;
  trace->start_ns = agc_trace_now();
  if (!AGC_TRACE_BUILD || !names) return;
  for (const char *at = names;;) {
    const char *end = strchr(at, ',');
    size_t n = end ? (size_t)(end - at) : strlen(at);
    if (n) {
      unsigned bit = category_bit(at, n);
      if (bit)
        trace->mask |= bit;
      else
        agc_trace_message(fd, "unknown category", at, n, true);
    }
    if (!end) break;
    at = end + 1;
  }
}

void agc_trace_format(agc_trace_line *line, const agc_trace *trace, unsigned category, const char *format, ...) {
  va_list ap;
  va_start(ap, format);
  start_line(line, trace, category);
  put_format(line, format, &ap);
  va_end(ap);
  end_line(line);
}

void agc_trace_emit(const agc_trace *trace, unsigned category, const char *format, ...) {
  int saved = errno;
  agc_trace_line line;
  va_list ap;
  va_start(ap, format);
  start_line(&line, trace, category);
  put_format(&line, format, &ap);
  va_end(ap);
  end_line(&line);
  write_line(trace->fd, &line);
  errno = saved;
}

/* The indexes of the `limit` (at most PROFILE_TOP) largest non-zero counts, largest first (the lower index first among
 * equal counts). Returns how many there are. */
static size_t top_counts(const uint64_t *counts, size_t n, uint32_t *top, size_t limit) {
  size_t found = 0;
  for (size_t k = 0; k < n; k++) {
    if (counts[k] == 0) continue;
    size_t at = found;
    while (at > 0 && counts[top[at - 1]] < counts[k]) at--;
    if (at >= limit) continue;
    if (found < limit) found++;
    memmove(top + at + 1, top + at, (found - at - 1) * sizeof *top);
    top[at] = (uint32_t)k;
  }
  return found;
}

static uint64_t sum_counts(const uint64_t *counts, size_t n) {
  uint64_t sum = 0;
  for (size_t k = 0; k < n; k++) sum += counts[k];
  return sum;
}

/* Starts the counters of the run when the profile category is on. Called before the first task enters a function. */
void agc_profile_start(agc_vm *vm) {
  if (!AGC_TRACE_ON(&vm->rt->trace, AGC_TRACE_PROFILE)) return;
  const agc_program *p = vm->rt->program;
  agc_profile *profile = agc_alloc(sizeof *profile);
  profile->functions = p->function_count;
  profile->builtins = p->builtin_count;
  profile->calls = agc_alloc(agc_size_mul((size_t)p->function_count + 1, sizeof(uint64_t)));
  profile->steps = agc_alloc(agc_size_mul((size_t)p->function_count + 1, sizeof(uint64_t)));
  profile->builtin_calls = agc_alloc(agc_size_mul((size_t)p->builtin_count + 1, sizeof(uint64_t)));
  profile->builtin_ns = agc_alloc(agc_size_mul((size_t)p->builtin_count + 1, sizeof(uint64_t)));
  profile->start_ns = agc_trace_now();
  agc_gc_measure();
  vm->profile = profile;
}

/* The steps and calls of the functions defined in each source file, in the order of the program's sources. */
static void sum_by_file(const agc_program *p, const agc_profile *profile, uint64_t *steps, uint64_t *calls) {
  for (uint32_t id = 0; id < profile->functions; id++) {
    uint32_t file = p->spans[p->functions[id].span].source;
    steps[file] += profile->steps[id];
    calls[file] += profile->calls[id];
  }
}

/* One total line, then the functions with the most steps, the source files with the most steps and the builtins that
 * took the most time, each with its counts. The loops of map, each and the like are the function "<native>". Builtin
 * time is wall time of the call itself: a builtin that waits (a sleep, a read) is timed until it parks, and the
 * garbage collector runs inside the allocations of any of them. `gc_ms` and `collections` are those of the whole
 * process so far, not of this runtime: the report of the program that `agentica FILE.agc` runs counts the front end's
 * collections too. */
void agc_profile_report(agc_vm *vm) {
  const agc_profile *profile = vm->profile;
  if (!profile) return;
  const agc_trace *tr = &vm->rt->trace;
  const agc_program *p = vm->rt->program;
  size_t functions = (size_t)profile->functions + 1, builtins = (size_t)profile->builtins + 1;
  agc_gc_info gc = {0};
  agc_gc_stats(&gc);
  AGC_TRACE(tr, AGC_TRACE_PROFILE,
            "total wall_ms=%" PRIu64 " steps=%" PRIu64 " calls=%" PRIu64 " builtin_calls=%" PRIu64
            " builtin_ms=%" PRIu64 " gc_ms=%" PRIu64 " collections=%" PRIu64,
            (agc_trace_now() - profile->start_ns) / 1000000u, sum_counts(profile->steps, functions),
            sum_counts(profile->calls, functions), sum_counts(profile->builtin_calls, builtins),
            sum_counts(profile->builtin_ns, builtins) / 1000000u, gc.total_ms, gc.collections);
  uint32_t top[PROFILE_TOP];
  size_t found = top_counts(profile->steps, functions, top, PROFILE_TOP);
  for (size_t k = 0; k < found; k++) {
    uint32_t id = top[k];
    if (id == profile->functions) {
      AGC_TRACE(tr, AGC_TRACE_PROFILE, "fn calls=0 steps=%" PRIu64 " name=<native>", profile->steps[id]);
      continue;
    }
    const agc_function *fn = &p->functions[id];
    const agc_span *at = &p->spans[fn->span];
    const agc_string *file = p->sources[at->source].name;
    AGC_TRACE(tr, AGC_TRACE_PROFILE, "fn calls=%" PRIu64 " steps=%" PRIu64 " name=%.*s at=%.*s:%" PRIu32,
              profile->calls[id], profile->steps[id], agc_trace_len(fn->name->bytes), fn->name->data,
              agc_trace_len(file->bytes), file->data, at->start_line);
  }
  uint64_t *file_steps = agc_alloc(agc_size_mul((size_t)p->source_count + 1, sizeof(uint64_t)));
  uint64_t *file_calls = agc_alloc(agc_size_mul((size_t)p->source_count + 1, sizeof(uint64_t)));
  sum_by_file(p, profile, file_steps, file_calls);
  found = top_counts(file_steps, p->source_count, top, PROFILE_FILES);
  for (size_t k = 0; k < found; k++) {
    const agc_string *file = p->sources[top[k]].name;
    AGC_TRACE(tr, AGC_TRACE_PROFILE, "file calls=%" PRIu64 " steps=%" PRIu64 " name=%.*s", file_calls[top[k]],
              file_steps[top[k]], agc_trace_len(file->bytes), file->data);
  }
  found = top_counts(profile->builtin_ns, builtins, top, PROFILE_TOP);
  for (size_t k = 0; k < found; k++) {
    uint32_t id = top[k];
    const char *name = id < profile->builtins ? p->builtins[id]->name : "";
    AGC_TRACE(tr, AGC_TRACE_PROFILE, "builtin calls=%" PRIu64 " us=%" PRIu64 " name=%s", profile->builtin_calls[id],
              profile->builtin_ns[id] / 1000u, name);
  }
}
