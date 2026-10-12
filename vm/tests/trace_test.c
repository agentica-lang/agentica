#include "../agc.h"

#include <assert.h>
#include <inttypes.h>
#include <string.h>

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
  assert(l->len <= AGC_TRACE_LINE && l->len + 4 >= AGC_TRACE_LINE);
  assert(memcmp(l->data + l->len - 4, "...\n", 4) == 0);
}

int main(void) {
  agc_trace t;
  agc_trace_parse(&t, NULL, 2);
  assert(t.mask == 0 && t.fd == 2);
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

  agc_trace_line l;
  agc_trace_format(&l, &t, AGC_TRACE_IO, "start job=%" PRIu64 " task=%zu timeout_ms=%" PRId64 " x=%x pct=%%", UINT64_MAX,
                   (size_t)3, (int64_t)-1, 255u);
  assert(strcmp(body(&l, "io"), "start job=18446744073709551615 task=3 timeout_ms=-1 x=ff pct=%\n") == 0);

  agc_trace_format(&l, &t, AGC_TRACE_SCHED, "spawn fn=%.*s kind=%s", 4, "mainXYZ", "read");
  assert(strcmp(body(&l, "sched"), "spawn fn=main kind=read\n") == 0);

  agc_trace_format(&l, &t, AGC_TRACE_PROC, "spawn path=%.*s", 0, "ignored");
  assert(strcmp(body(&l, "proc"), "spawn path=\"\"\n") == 0);

  agc_trace_format(&l, &t, AGC_TRACE_LOADER, "file path=%s", "/tmp/caf\xC3\xA9.agcb");
  assert(strcmp(body(&l, "loader"), "file path=/tmp/caf\xC3\xA9.agcb\n") == 0);

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

  longer[sizeof longer - 1] = '\0';
  agc_trace_format(&l, &t, AGC_TRACE_IO, "n=%d %s", 1, longer);
  check_cut(&l);
  puts("trace tests passed");
  return 0;
}
