#include "../agc.h"

#include <assert.h>
#include <inttypes.h>
#include <limits.h>
#include <string.h>
#include <sys/types.h>

#ifndef _WIN32
#include <unistd.h>
#endif

#define BODY_MAX (AGC_TRACE_LINE + 1)

static char body_text[BODY_MAX];

static const char *body(const agc_trace_line *l, const char *category) {
  assert(l->len >= 1 && l->len <= AGC_TRACE_LINE);
  assert(l->data[l->len - 1] == '\n');
  for (size_t i = 0; i + 1 < l->len; i++) assert(l->data[i] != '\n');
  memcpy(body_text, l->data, l->len);
  body_text[l->len] = '\0';
  const char *at = body_text;
  assert(strncmp(at, "agc-trace +", 11) == 0);
  at += 11;
  assert(*at >= '0' && *at <= '9');
  while (*at >= '0' && *at <= '9') at++;
  assert(*at == '.');
  at++;
  for (int k = 0; k < 6; k++, at++) assert(*at >= '0' && *at <= '9');
  assert(*at == ' ');
  at++;
  size_t n = strlen(category);
  assert(strncmp(at, category, n) == 0 && at[n] == ' ');
  return at + n + 1;
}

static void check_cut(const agc_trace_line *l) {
  assert(l->len <= AGC_TRACE_LINE && l->len + 6 >= AGC_TRACE_LINE);
  assert(memcmp(l->data + l->len - 4, "...\n", 4) == 0);
}

static bool hex(char c) { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'); }

static void check_quoted_cut(const agc_trace_line *l) {
  check_cut(l);
  const char *at = strstr(body_text, "=\"");
  assert(at);
  at += 2;
  for (;;) {
    unsigned char c = (unsigned char)*at;
    if (c == '"') break;
    assert(c >= 0x20 && c != 0x7f);
    if (c != '\\') {
      at++;
      continue;
    }
    if (at[1] == 'u') {
      assert(hex(at[2]) && hex(at[3]) && hex(at[4]) && hex(at[5]));
      at += 6;
    } else {
      assert(strchr("\"\\bfnrt", at[1]) && at[1]);
      at += 2;
    }
  }
  assert(strcmp(at, "\"...\n") == 0);
  size_t chars;
  assert(agc_utf8_chars((const uint8_t *)l->data, l->len, &chars));
}

int main(void) {
  agc_trace t;
  agc_trace_parse(&t, NULL, 2);
  assert(t.mask == 0 && t.fd == 2);
#if AGC_TRACE_BUILD
  agc_trace_parse(&t, "sched,io,,gc", 2);
  assert(t.mask == (AGC_TRACE_SCHED | AGC_TRACE_IO | AGC_TRACE_GC));
  agc_trace_parse(&t, "all", 2);
  assert(t.mask == AGC_TRACE_ALL);
  assert(!AGC_TRACE_ON(&t, 1u << 7));
#ifndef _WIN32
  int fds[2];
  assert(pipe(fds) == 0);
  agc_trace_parse(&t, "io,bad name,loader", fds[1]);
  assert(t.mask == (AGC_TRACE_IO | AGC_TRACE_LOADER));
  char warning[128] = {0};
  ssize_t got = read(fds[0], warning, sizeof warning - 1);
  assert(got > 0 && strcmp(warning, "agc-trace unknown category \"bad name\"\n") == 0);
  close(fds[0]);
  close(fds[1]);
#endif
#endif

  agc_trace_line l;
  agc_trace_format(&l, &t, AGC_TRACE_IO, "start job=%" PRIu64 " task=%zu timeout_ms=%" PRId64 " x=%x pct=%%", UINT64_MAX,
                   (size_t)3, (int64_t)-1, 255u);
  assert(strcmp(body(&l, "io"), "start job=18446744073709551615 task=3 timeout_ms=-1 x=ff pct=%\n") == 0);

  agc_trace_format(&l, &t, AGC_TRACE_IO, "d=%d i=%i u=%u x=%x X=%X", -5, 7, 7u, 255u, 255u);
  assert(strcmp(body(&l, "io"), "d=-5 i=7 u=7 x=ff X=FF\n") == 0);
  agc_trace_format(&l, &t, AGC_TRACE_IO, "hhd=%hhd hhu=%hhu hd=%hd hu=%hu", (signed char)-1, (unsigned char)200,
                   (short)-300, (unsigned short)65535);
  assert(strcmp(body(&l, "io"), "hhd=-1 hhu=200 hd=-300 hu=65535\n") == 0);
  agc_trace_format(&l, &t, AGC_TRACE_IO, "ld=%ld lu=%lu lld=%lld llu=%llu", -5L, 5UL, LLONG_MIN, ULLONG_MAX);
  assert(strcmp(body(&l, "io"), "ld=-5 lu=5 lld=-9223372036854775808 llu=18446744073709551615\n") == 0);
  agc_trace_format(&l, &t, AGC_TRACE_IO, "zu=%zu zd=%zd jd=%jd ju=%ju td=%td", (size_t)9, (ssize_t)-9, INTMAX_MIN,
                   UINTMAX_MAX, (ptrdiff_t)-4);
  assert(strcmp(body(&l, "io"),
                "zu=9 zd=-9 jd=-9223372036854775808 ju=18446744073709551615 td=-4\n") == 0);
  agc_trace_format(&l, &t, AGC_TRACE_IO, "c=%c d=%d", 'x', 1);
  assert(strcmp(body(&l, "io"), "c=?\n") == 0);
  agc_trace_format(&l, &t, AGC_TRACE_IO, "w=%5d d=%d", 1, 2);
  assert(strcmp(body(&l, "io"), "w=?\n") == 0);

  agc_trace_format(&l, &t, AGC_TRACE_SCHED, "spawn fn=%.*s kind=%s", 4, "mainXYZ", "read");
  assert(strcmp(body(&l, "sched"), "spawn fn=main kind=read\n") == 0);

  agc_trace_format(&l, &t, AGC_TRACE_PROC, "spawn path=%.*s", 0, "ignored");
  assert(strcmp(body(&l, "proc"), "spawn path=\"\"\n") == 0);

  agc_trace_format(&l, &t, AGC_TRACE_LOADER, "file path=%s", "/tmp/caf\xC3\xA9.agcb");
  assert(strcmp(body(&l, "loader"), "file path=/tmp/caf\xC3\xA9.agcb\n") == 0);

  agc_trace_format(&l, &t, AGC_TRACE_LOADER, "file path=%s next=%s", "a\x80" "b", "c \xC3");
  assert(strcmp(body(&l, "loader"), "file path=\"a\\u0080b\" next=\"c \\u00c3\"\n") == 0);
  agc_trace_format(&l, &t, AGC_TRACE_LOADER, "file path=%.*s", 4, "x\xE2\x82y");
  assert(strcmp(body(&l, "loader"), "file path=\"x\\u00e2\\u0082y\"\n") == 0);

  static const char special[] = "a b=\"c\\\n\r\t\b\f\x01\x1f\x7f\0z";
  agc_trace_format(&l, &t, AGC_TRACE_LOADER, "reject reason=%.*s", (int)(sizeof special - 1), special);
  assert(strcmp(body(&l, "loader"),
                "reject reason=\"a b=\\\"c\\\\\\n\\r\\t\\b\\f\\u0001\\u001f\\u007f\\u0000z\"\n") == 0);

  static char longer[4096];
  memset(longer, 'x', sizeof longer);
  agc_trace_format(&l, &t, AGC_TRACE_GC, "collect at=%.*s", (int)sizeof longer, longer);
  check_cut(&l);
  body(&l, "gc");

  memset(longer, '\n', sizeof longer);
  agc_trace_format(&l, &t, AGC_TRACE_GC, "collect at=%.*s", (int)sizeof longer, longer);
  check_cut(&l);
  body(&l, "gc");

  for (size_t k = 0; k + 1 < sizeof longer; k += 2) {
    longer[k] = '\xC3';
    longer[k + 1] = '\xA9';
  }
  for (size_t shift = 0; shift < 2; shift++) {
    agc_trace_format(&l, &t, AGC_TRACE_GC, "%.*scollect at=%.*s", (int)shift, "yy", (int)sizeof longer, longer);
    check_cut(&l);
    size_t chars;
    assert(agc_utf8_chars((const uint8_t *)l.data, l.len, &chars));
  }

  static const char *const units[] = {"\n", "\x01", "\xC3\xA9 ", "\"", " \xE2\x82\xAC\xF0\x9F\x98\x80", "\x80", "\xF0\x9F\x98"};
  for (size_t u = 0; u < sizeof units / sizeof units[0]; u++) {
    size_t n = strlen(units[u]);
    for (size_t k = 0; k + n <= sizeof longer; k += n) memcpy(longer + k, units[u], n);
    size_t used = sizeof longer - sizeof longer % n;
    for (size_t shift = 0; shift < 7; shift++) {
      agc_trace_format(&l, &t, AGC_TRACE_GC, "%.*scollect at=%.*s", (int)shift, "yyyyyy", (int)used, longer);
      body(&l, "gc");
      check_quoted_cut(&l);
    }
  }

  memset(longer, 'x', sizeof longer);
  longer[sizeof longer - 1] = '\0';
  agc_trace_format(&l, &t, AGC_TRACE_IO, "n=%d %s", 1, longer);
  check_cut(&l);
  puts("trace tests passed");
  return 0;
}
