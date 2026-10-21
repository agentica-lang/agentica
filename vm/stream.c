/*
 * What processes and TCP share: agc_inbuf, the input buffer with line reads
 * (1 MiB limit), and the stream write and lock helpers. Service layer.
 * Design: docs/vm/10-io-tls.md §10.3.1.
 */
#include "net_os.h"
#include "services.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
#include <limits.h>
#include <uv.h>
#endif

#define LIMIT ((size_t)1048576)
#define READ_AHEAD ((size_t)4096)
#define WRITE_CHUNK ((size_t)1 << 30)

static const char bad_timeout[] = "network: timeout must be positive milliseconds";
static const char timed_out[] = "network: operation timed out";

static size_t byte_escape(const uint8_t *data, size_t len, size_t at, char out[5]) {
  static const char named[] = "abtnvfr";
  uint8_t b = data[at];
  if (b == '"' || b == '\\') {
    out[0] = '\\';
    out[1] = (char)b;
    return 2;
  }
  if (b >= 32 && b < 127) {
    out[0] = (char)b;
    return 1;
  }
  out[0] = '\\';
  if (b >= 7 && b <= 13) {
    out[1] = named[b - 7];
    return 2;
  }
  if (b == 27) {
    out[1] = 'e';
    return 2;
  }
  bool pad = at + 1 < len && data[at + 1] >= '0' && data[at + 1] <= '7';
  int n = snprintf(out + 1, 4, pad ? "%03o" : "%o", (unsigned)b);
  return 1 + (size_t)n;
}

agc_value agc_utf8_error(const uint8_t *data, size_t len) {
  static const char prefix[] = "bytes->string/utf-8: byte string is not a well-formed UTF-8 encoding\n  byte string: ";
  char form[261];
  char message[512];
  size_t form_len = 0;
  size_t message_len = sizeof prefix - 1;
  memcpy(form + form_len, "#\"", 2);
  form_len += 2;
  for (size_t at = 0; at < len && form_len <= 256; at++) {
    char piece[5];
    size_t piece_len = byte_escape(data, len, at, piece);
    memcpy(form + form_len, piece, piece_len);
    form_len += piece_len;
  }
  form[form_len++] = '"';
  memcpy(message, prefix, message_len);
  if (form_len > 256) {
    memcpy(message + message_len, form, 253);
    memcpy(message + message_len + 253, "...", 3);
    message_len += 256;
  } else {
    memcpy(message + message_len, form, form_len);
    message_len += form_len;
  }
  agc_string *decoded = agc_utf8_decode((const uint8_t *)message, message_len, "\xEF\xBF\xBD", false);
  return agc_result_value(false, agc_string_value(decoded));
}

#if !defined(__linux__) && !defined(__APPLE__) && !defined(_WIN32)
agc_value agc_system_error(agc_vm *vm, const char *what, int err) {
  (void)vm;
  (void)err;
  return agc_error_value(what);
}
#endif

agc_value agc_stream_bad_timeout(void) { return agc_error_value(bad_timeout); }

agc_value agc_stream_timed_out(void) { return agc_error_value(timed_out); }

agc_value agc_stream_written(agc_vm *vm, int status) {
  static const char write_failed[] = "error writing to stream port";
  return status < 0 ? agc_system_error(vm, write_failed, agc_net_errno(status)) : agc_result_value(true, agc_void());
}

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
  b->start = b->end = b->cap = b->scanned = 0;
}

/* The pending bytes of B, or NULL when there are none: an empty buffer may have no memory, and NULL + 0 is undefined
   behavior. */
static const uint8_t *pending_at(const agc_inbuf *b) { return agc_inbuf_pending(b) ? b->data + b->start : NULL; }

static const uint8_t *find_lf(agc_inbuf *b) {
  size_t have = agc_inbuf_pending(b);
  size_t window = have < LIMIT + 1 ? have : LIMIT + 1;
  if (b->scanned >= window) return NULL;
  const uint8_t *data = b->data + b->start;
  const uint8_t *lf = memchr(data + b->scanned, '\n', window - b->scanned);
  b->scanned = lf ? (size_t)(lf - data) : window;
  return lf;
}

bool agc_inbuf_ready(agc_inbuf *b, bool line, size_t count) {
  if (b->eof || b->error) return true;
  if (!line) return agc_inbuf_pending(b) >= count;
  return agc_inbuf_pending(b) > LIMIT || find_lf(b);
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

/* Puts LEN bytes back in front of the pending input: bytes a reader took past
   what it used (std/http's chunked framing reads), so the next read sees them
   first. False when memory runs out. */
bool agc_inbuf_unread(agc_inbuf *b, const uint8_t *data, size_t len) {
  if (!len) return true;
  if (b->start < len) {
    size_t used = agc_inbuf_pending(b), need = agc_size_add(len, used);
    if (b->cap < need) {
      uint8_t *bigger = realloc(b->data, need);
      if (!bigger) return false;
      b->data = bigger;
      b->cap = need;
    }
    if (used) memmove(b->data + len, b->data + b->start, used);
    b->start = len;
    b->end = len + used;
  }
  b->start -= len;
  memcpy(b->data + b->start, data, len);
  b->scanned = 0;
  return true;
}

void agc_inbuf_got(agc_inbuf *b, int64_t n, bool eof) {
  if (n > 0)
    b->end += (size_t)n;
  else if (eof)
    b->eof = true;
  else if (n < 0)
    b->error = agc_net_errno((int)n);
}

/* Where the next line read of B ends: a line (DATA, LEN bytes at DATA without the LF and one CR before it, CONSUME
   bytes to drop), more than LIMIT bytes without an LF (OVER), bytes without an LF that end in a read error (FAILED),
   or nothing left (END). A final line without an LF is a line at EOF. */
static agc_cut_status spot_line(agc_inbuf *b, const uint8_t **data, size_t *len, size_t *consume) {
  size_t have = agc_inbuf_pending(b);
  *data = pending_at(b);
  const uint8_t *lf = find_lf(b);
  *len = *consume = have;
  if (lf) {
    *len = (size_t)(lf - *data);
    *consume = *len + 1;
    if (*len && (*data)[*len - 1] == '\r') (*len)--;
    return AGC_CUT_DATA;
  }
  if (have > LIMIT) return AGC_CUT_OVER;
  if (b->error) return AGC_CUT_FAILED;
  return have == 0 ? AGC_CUT_END : AGC_CUT_DATA;
}

static agc_value line_value(agc_vm *vm, agc_cut_status status, int error, const uint8_t *data, size_t len,
                            const char *too_long, const char *at_end) {
  if (status == AGC_CUT_OVER) return agc_error_value(too_long);
  if (status == AGC_CUT_FAILED) return agc_system_error(vm, "error reading from stream port", error);
  if (status == AGC_CUT_END) return agc_error_value(at_end);
  size_t chars;
  if (!agc_utf8_chars(data, len, &chars)) return agc_utf8_error(data, len);
  return agc_result_value(true, agc_string_value(agc_small_string(vm, (const char *)data, len, chars)));
}

agc_value agc_inbuf_line(agc_vm *vm, agc_inbuf *b, const char *too_long, const char *at_end, bool *over) {
  const uint8_t *data;
  size_t len, consume;
  agc_cut_status status = spot_line(b, &data, &len, &consume);
  *over = status == AGC_CUT_OVER;
  if (status == AGC_CUT_DATA) {
    b->start += consume;
    b->scanned = 0;
  }
  return line_value(vm, status, b->error, data, len, too_long, at_end);
}

void agc_inbuf_take(agc_inbuf *b, size_t n) {
  b->start += n;
  b->scanned = b->scanned > n ? b->scanned - n : 0;
}

static agc_value bytes_value(const uint8_t *data, size_t n) {
  agc_list_builder out;
  agc_list_builder_sized(&out, n);
  for (size_t k = 0; k < n; k++) agc_list_builder_push(&out, agc_int(data[k]));
  return agc_result_value(true, agc_list_value(agc_list_builder_finish(&out)));
}

agc_value agc_inbuf_bytes(agc_vm *vm, agc_inbuf *b, size_t count) {
  size_t have = agc_inbuf_pending(b);
  size_t n = have < count ? have : count;
  if (n == 0 && count > 0 && b->error) return agc_system_error(vm, "error reading from stream port", b->error);
  agc_value result = bytes_value(pending_at(b), n);
  agc_inbuf_take(b, n);
  return result;
}

static void cut_copy(agc_inbuf_cut *cut, const uint8_t *data, size_t len) {
  cut->len = len;
  cut->data = NULL;
  if (!len) return;
  cut->data = malloc(len);
  if (!cut->data) agc_out_of_memory();
  memcpy(cut->data, data, len);
}

void agc_inbuf_cut_line(agc_inbuf *b, agc_inbuf_cut *cut) {
  const uint8_t *data;
  size_t len, consume;
  cut->status = spot_line(b, &data, &len, &consume);
  cut->error = b->error;
  cut_copy(cut, data, cut->status == AGC_CUT_DATA ? len : 0);
  if (cut->status != AGC_CUT_DATA) return;
  b->start += consume;
  b->scanned = 0;
}

void agc_inbuf_cut_bytes(agc_inbuf *b, size_t count, agc_inbuf_cut *cut) {
  size_t have = agc_inbuf_pending(b);
  size_t n = have < count ? have : count;
  cut->error = b->error;
  cut->status = n == 0 && count > 0 && b->error ? AGC_CUT_FAILED : AGC_CUT_DATA;
  cut_copy(cut, pending_at(b), cut->status == AGC_CUT_DATA ? n : 0);
  if (cut->status == AGC_CUT_DATA) agc_inbuf_take(b, n);
}

agc_value agc_inbuf_cut_line_value(agc_vm *vm, const agc_inbuf_cut *cut, const char *too_long, const char *at_end) {
  return line_value(vm, cut->status, cut->error, cut->data, cut->len, too_long, at_end);
}

agc_value agc_inbuf_cut_bytes_value(agc_vm *vm, const agc_inbuf_cut *cut) {
  if (cut->status == AGC_CUT_FAILED) return agc_system_error(vm, "error reading from stream port", cut->error);
  return bytes_value(cut->data, cut->len);
}

void agc_inbuf_cut_free(agc_inbuf_cut *cut) {
  free(cut->data);
  cut->data = NULL;
  cut->len = 0;
}

#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
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
