#include "agc.h"

#include <stdlib.h>
#include <string.h>

#ifdef __linux__
#include <limits.h>
#include <uv.h>
#endif

#define LIMIT ((size_t)1048576)
#define READ_AHEAD ((size_t)4096)
#define WRITE_CHUNK ((size_t)1 << 30)

static const char bad_timeout[] = "network: timeout must be positive milliseconds";
static const char timed_out[] = "network: operation timed out";

agc_value agc_error_value(const char *message) {
  size_t n = strlen(message);
  return agc_result_value(false, agc_string_value(agc_make_string(message, n, n)));
}

agc_value agc_stream_bad_timeout(void) { return agc_error_value(bad_timeout); }

agc_value agc_stream_timed_out(void) { return agc_error_value(timed_out); }

agc_resource *agc_new_lock(agc_vm *vm) {
  agc_resource *lock = agc_alloc(sizeof(agc_resource));
  lock->id = agc_resource_id(vm);
  lock->slot = SIZE_MAX;
  lock->context = agc_void();
  return lock;
}

bool agc_stream_lock(agc_vm *vm, agc_resource *lock, int64_t *timeout, agc_value *result) {
  if (*timeout <= 0) {
    *result = agc_stream_bad_timeout();
    return false;
  }
  agc_lock_status status = agc_handle_wait(vm, lock, timeout);
  if (status == AGC_LOCK_TAKEN) return true;
  *result = status == AGC_LOCK_WAIT ? agc_void() : agc_stream_timed_out();
  return false;
}

size_t agc_inbuf_pending(const agc_inbuf *b) { return b->end - b->start; }

void agc_inbuf_free(agc_inbuf *b) {
  free(b->data);
  b->data = NULL;
  b->start = b->end = b->cap = 0;
}

static size_t line_window(const agc_inbuf *b) {
  size_t have = agc_inbuf_pending(b);
  return have < LIMIT + 1 ? have : LIMIT + 1;
}

bool agc_inbuf_ready(const agc_inbuf *b, bool line, size_t count) {
  size_t have = agc_inbuf_pending(b);
  if (b->eof || b->error) return true;
  if (!line) return have >= count;
  size_t window = line_window(b);
  return have > LIMIT || (window && memchr(b->data + b->start, '\n', window));
}

size_t agc_inbuf_want(const agc_inbuf *b, bool line, size_t count) {
  size_t have = agc_inbuf_pending(b);
  if (!line && count > have && count - have > READ_AHEAD) return count - have;
  return READ_AHEAD;
}

uint8_t *agc_inbuf_room(agc_inbuf *b, size_t want) {
  if (b->start == b->end) b->start = b->end = 0;
  if (b->cap - b->end >= want) return b->data + b->end;
  size_t used = agc_inbuf_pending(b);
  if (b->start) {
    memmove(b->data, b->data + b->start, used);
    b->start = 0;
    b->end = used;
    if (b->cap - used >= want) return b->data + b->end;
  }
  size_t cap = b->cap ? b->cap : READ_AHEAD;
  while (cap - used < want) cap = agc_size_mul(cap, 2);
  uint8_t *bigger = realloc(b->data, cap);
  if (!bigger) return NULL;
  b->data = bigger;
  b->cap = cap;
  return b->data + b->end;
}

void agc_inbuf_got(agc_inbuf *b, int64_t n, bool eof) {
  if (n > 0)
    b->end += (size_t)n;
  else if (eof)
    b->eof = true;
  else if (n < 0)
    b->error = (int)-n;
}

agc_value agc_inbuf_line(agc_vm *vm, agc_inbuf *b, const char *too_long, const char *at_end, bool *over) {
  size_t have = agc_inbuf_pending(b);
  size_t window = line_window(b);
  const uint8_t *data = have ? b->data + b->start : NULL;
  const uint8_t *lf = window ? memchr(data, '\n', window) : NULL;
  size_t len = have, consume = have;
  *over = false;
  if (lf) {
    len = (size_t)(lf - data);
    consume = len + 1;
    if (len && data[len - 1] == '\r') len--;
  } else if (have > LIMIT) {
    *over = true;
    return agc_error_value(too_long);
  } else if (have == 0) {
    if (b->error) return agc_system_error(vm, "error reading from stream port", b->error);
    return agc_error_value(at_end);
  }
  b->start += consume;
  size_t chars;
  if (!agc_utf8_chars(data, len, &chars)) return agc_utf8_error(data, len);
  return agc_result_value(true, agc_string_value(agc_make_string((const char *)data, len, chars)));
}

agc_value agc_inbuf_bytes(agc_vm *vm, agc_inbuf *b, size_t count) {
  size_t have = agc_inbuf_pending(b);
  size_t n = have < count ? have : count;
  if (n == 0 && count > 0 && b->error) return agc_system_error(vm, "error reading from stream port", b->error);
  agc_list *l = agc_new_list(n);
  for (size_t k = 0; k < n; k++) l->items[k] = agc_int(b->data[b->start + k]);
  b->start += n;
  return agc_result_value(true, agc_list_value(l));
}

#ifdef __linux__
static unsigned chunk(size_t len) { return (unsigned)(len < WRITE_CHUNK ? len : WRITE_CHUNK); }

int agc_stream_write(struct uv_stream_s *stream, struct uv_write_s *req, uint8_t **copy, const uint8_t *data,
                     size_t len, void (*done)(struct uv_write_s *req, int status)) {
  size_t sent = 0;
  while (sent < len) {
    uv_buf_t b = uv_buf_init((char *)data + sent, chunk(len - sent));
    int n = uv_try_write(stream, &b, 1);
    if (n == UV_EAGAIN) break;
    if (n < 0) return n;
    sent += (size_t)n;
  }
  if (sent == len) return 0;
  size_t rest = len - sent;
  size_t count = (rest + WRITE_CHUNK - 1) / WRITE_CHUNK;
  if (count > UINT_MAX) agc_out_of_memory();
  *copy = malloc(rest);
  uv_buf_t *bufs = calloc(count, sizeof(uv_buf_t));
  if (!*copy || !bufs) agc_out_of_memory();
  memcpy(*copy, data + sent, rest);
  for (size_t k = 0; k < count; k++) {
    size_t at = k * WRITE_CHUNK;
    bufs[k] = uv_buf_init((char *)*copy + at, chunk(rest - at));
  }
  int rc = uv_write(req, stream, bufs, (unsigned)count, done);
  free(bufs);
  if (!rc) return 1;
  free(*copy);
  *copy = NULL;
  return rc;
}
#endif
