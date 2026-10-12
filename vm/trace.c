#include "agc.h"

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
#define CONTENT_LIMIT (AGC_TRACE_LINE - 1 - CUT_BYTES)

typedef enum { LEN_INT, LEN_CHAR, LEN_SHORT, LEN_LONG, LEN_LLONG, LEN_SIZE, LEN_MAX, LEN_PTRDIFF } length_kind;

static const char *const category_names[] = {"sched", "io", "proc", "tls", "loader", "gc"};
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
