/*
 * The HTTP body decoder adapter: Content-Length, chunked and close-delimited
 * bodies, fed in pieces and bounded by the limits in http_parse.h. Adapter
 * layer, behind http_parse.h. Design: docs/vm/10-io-http.md §10.6.1.
 */
#include "value.h"
#include "http_parse.h"

#include <stdlib.h>
#include <string.h>

#define FIRST_CAP ((size_t)16384)

typedef struct {
  int code;
  const char *text;
} error_info;

static const error_info errors[] = {
  [AGC_HTTP_ERR_NONE] = {200, "no error"},
  [AGC_HTTP_ERR_HEAD] = {400, "invalid HTTP head"},
  [AGC_HTTP_ERR_BARE_LF] = {400, "HTTP requires CRLF"},
  [AGC_HTTP_ERR_LINE_TOO_LONG] = {431, "HTTP line is too large"},
  [AGC_HTTP_ERR_BLOCK_TOO_LARGE] = {431, "HTTP headers are too large"},
  [AGC_HTTP_ERR_TOO_MANY_HEADERS] = {431, "too many HTTP headers"},
  [AGC_HTTP_ERR_VERSION] = {505, "HTTP version is unsupported"},
  [AGC_HTTP_ERR_METHOD] = {400, "invalid request method"},
  [AGC_HTTP_ERR_CONNECT] = {501, "CONNECT is unsupported"},
  [AGC_HTTP_ERR_TARGET] = {400, "invalid request target"},
  [AGC_HTTP_ERR_OBS_FOLD] = {400, "folded HTTP header lines are not allowed"},
  [AGC_HTTP_ERR_HEADER] = {400, "invalid HTTP header"},
  [AGC_HTTP_ERR_HOST] = {400, "one Host header is required"},
  [AGC_HTTP_ERR_STATUS] = {400, "invalid response status"},
  [AGC_HTTP_ERR_UPGRADE] = {400, "protocol upgrades are unsupported"},
  [AGC_HTTP_ERR_INTERIM] = {400, "too many interim responses"},
  [AGC_HTTP_ERR_AMBIGUOUS] = {400, "ambiguous HTTP body framing"},
  [AGC_HTTP_ERR_LENGTH] = {400, "invalid content length"},
  [AGC_HTTP_ERR_TRANSFER] = {501, "unsupported transfer encoding"},
  [AGC_HTTP_ERR_TOO_LARGE] = {413, "body exceeds max_body_bytes"},
  [AGC_HTTP_ERR_CHUNK] = {400, "invalid chunk size"},
  [AGC_HTTP_ERR_CHUNK_END] = {400, "invalid chunk terminator"},
  [AGC_HTTP_ERR_TRAILER] = {400, "invalid trailer"},
  [AGC_HTTP_ERR_TRUNCATED] = {400, "truncated HTTP body"},
};

static const char *const forbidden_trailers[] = {"content-length", "transfer-encoding", "host", "connection",
                                                 "trailer"};

int agc_http_error_code(agc_http_error error) { return errors[error].code; }

const char *agc_http_error_text(agc_http_error error) { return errors[error].text; }

static bool token_byte(uint8_t c) {
  if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) return true;
  return c && strchr("!#$%&'*+-.^_`|~", c) != NULL;
}

bool agc_http_token(const uint8_t *s, size_t len) {
  if (len == 0) return false;
  for (size_t k = 0; k < len; k++)
    if (!token_byte(s[k])) return false;
  return true;
}

bool agc_http_value_byte(uint8_t c) { return c == '\t' || (c >= 32 && c != 127); }

static uint8_t lower(uint8_t c) { return c >= 'A' && c <= 'Z' ? (uint8_t)(c + 32) : c; }

bool agc_http_named(agc_http_slice name, const char *text) {
  size_t n = strlen(text);
  if (name.len != n) return false;
  for (size_t k = 0; k < n; k++)
    if (lower(name.data[k]) != (uint8_t)text[k]) return false;
  return true;
}

agc_http_slice agc_http_trim(agc_http_slice s) {
  while (s.len && (s.data[0] == ' ' || s.data[0] == '\t')) {
    s.data++;
    s.len--;
  }
  while (s.len && (s.data[s.len - 1] == ' ' || s.data[s.len - 1] == '\t')) s.len--;
  return s;
}

static bool digits(agc_http_slice s, uint64_t *value) {
  if (s.len == 0) return false;
  uint64_t v = 0;
  for (size_t k = 0; k < s.len; k++) {
    if (s.data[k] < '0' || s.data[k] > '9') return false;
    unsigned d = (unsigned)(s.data[k] - '0');
    v = v > (UINT64_MAX - d) / 10 ? UINT64_MAX : v * 10 + d;
  }
  *value = v;
  return true;
}

static agc_http_error lengths(agc_http_slice value, bool *seen, uint64_t *length) {
  size_t start = 0;
  for (size_t k = 0; k <= value.len; k++) {
    if (k < value.len && value.data[k] != ',') continue;
    uint64_t v;
    if (!digits(agc_http_trim((agc_http_slice){value.data + start, k - start}), &v)) return AGC_HTTP_ERR_LENGTH;
    if (*seen && v != *length) return AGC_HTTP_ERR_LENGTH;
    *seen = true;
    *length = v;
    start = k + 1;
  }
  return AGC_HTTP_ERR_NONE;
}

agc_http_error agc_http_framing(agc_http_head *head, bool request) {
  bool has_length = false, chunked = false;
  size_t transfers = 0;
  uint64_t length = 0;
  for (size_t k = 0; k < head->count; k++) {
    const agc_http_field *f = &head->fields[k];
    if (agc_http_named(f->name, "content-length")) {
      agc_http_error bad = lengths(f->value, &has_length, &length);
      if (bad != AGC_HTTP_ERR_NONE) return bad;
    } else if (agc_http_named(f->name, "transfer-encoding")) {
      transfers++;
      chunked = agc_http_named(agc_http_trim(f->value), "chunked");
    }
  }
  if (has_length && transfers) return AGC_HTTP_ERR_AMBIGUOUS;
  head->length = 0;
  if (transfers) {
    if (transfers != 1 || !chunked) return AGC_HTTP_ERR_TRANSFER;
    head->frame = AGC_HTTP_FRAME_CHUNKED;
  } else if (has_length || request) {
    head->frame = AGC_HTTP_FRAME_LENGTH;
    head->length = length;
  } else {
    head->frame = AGC_HTTP_FRAME_CLOSE;
  }
  return AGC_HTTP_ERR_NONE;
}

static void fail(agc_http_body *b, agc_http_error error) {
  b->state = AGC_HTTP_BODY_FAILED;
  b->error = error;
}

static void reserve(agc_http_body *b, size_t need) {
  if (need <= b->cap) return;
  size_t cap = b->cap > FIRST_CAP / 2 ? agc_size_mul(b->cap, 2) : FIRST_CAP;
  if (b->limit < cap) cap = (size_t)b->limit;
  if (cap < need) cap = need;
  uint8_t *bigger = realloc(b->data, cap);
  if (!bigger) agc_out_of_memory();
  b->data = bigger;
  b->cap = cap;
}

static void append(agc_http_body *b, const uint8_t *data, size_t n) {
  if (!n) return;
  reserve(b, b->len + n);
  memcpy(b->data + b->len, data, n);
  b->len += n;
}

void agc_http_body_init(agc_http_body *b, agc_http_frame frame, uint64_t length, uint64_t limit) {
  memset(b, 0, sizeof *b);
  b->frame = frame;
  b->limit = limit;
  b->state = frame == AGC_HTTP_FRAME_CHUNKED ? AGC_HTTP_BODY_SIZE : AGC_HTTP_BODY_DATA;
  if (frame != AGC_HTTP_FRAME_LENGTH) return;
  if (length > limit) {
    fail(b, AGC_HTTP_ERR_TOO_LARGE);
  } else if (length == 0) {
    b->state = AGC_HTTP_BODY_DONE;
  } else {
    b->remaining = length;
    reserve(b, (size_t)length);
  }
}

static int hex(uint8_t c) {
  if (c >= '0' && c <= '9') return c - '0';
  c = lower(c);
  return c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1;
}

static void size_done(agc_http_body *b) {
  if (b->size > b->limit - b->len) {
    fail(b, AGC_HTTP_ERR_TOO_LARGE);
    return;
  }
  b->line = 0;
  if (b->size == 0) {
    b->state = AGC_HTTP_BODY_TRAILER;
    return;
  }
  b->remaining = b->size;
  b->size = 0;
  b->state = AGC_HTTP_BODY_CHUNK;
}

static void size_byte(agc_http_body *b, uint8_t c) {
  int d = hex(c);
  if (b->line > 0 && c == '\r') {
    b->state = AGC_HTTP_BODY_SIZE_LF;
    return;
  }
  if (b->state == AGC_HTTP_BODY_SIZE && d >= 0) {
    b->size = b->size > (UINT64_MAX - 15) / 16 ? UINT64_MAX : b->size * 16 + (uint64_t)d;
  } else if (b->state == AGC_HTTP_BODY_SIZE && b->line > 0 && c == ';') {
    b->state = AGC_HTTP_BODY_EXTENSION;
  } else if (b->state != AGC_HTTP_BODY_EXTENSION || c < 32 || c > 126) {
    fail(b, AGC_HTTP_ERR_CHUNK);
    return;
  }
  if (++b->line > AGC_HTTP_MAX_LINE) fail(b, AGC_HTTP_ERR_LINE_TOO_LONG);
}

static bool forbidden(const agc_http_body *b) {
  for (size_t k = 0; k < sizeof forbidden_trailers / sizeof forbidden_trailers[0]; k++)
    if (b->name_len == strlen(forbidden_trailers[k]) && memcmp(b->name, forbidden_trailers[k], b->name_len) == 0)
      return true;
  return false;
}

static void trailer_end(agc_http_body *b) {
  b->block += b->line + 2;
  if (b->block > AGC_HTTP_MAX_BLOCK) {
    fail(b, AGC_HTTP_ERR_BLOCK_TOO_LARGE);
    return;
  }
  b->line = 0;
  b->state = AGC_HTTP_BODY_TRAILER;
  if (++b->count > AGC_HTTP_MAX_HEADERS) fail(b, AGC_HTTP_ERR_TOO_MANY_HEADERS);
}

static bool trailer_name(agc_http_body *b, uint8_t c) {
  if (c == ':' && b->name_len > 0) {
    if (forbidden(b)) return false;
    b->state = AGC_HTTP_BODY_TRAILER_VALUE;
    return true;
  }
  if (!token_byte(c)) return false;
  if (b->name_len < sizeof b->name) b->name[b->name_len] = (char)lower(c);
  b->name_len++;
  return true;
}

static void trailer_byte(agc_http_body *b, uint8_t c) {
  if (b->state == AGC_HTTP_BODY_TRAILER && c != '\r') {
    b->name_len = 0;
    b->state = AGC_HTTP_BODY_TRAILER_NAME;
  }
  bool good;
  switch (b->state) {
    case AGC_HTTP_BODY_TRAILER:
      b->state = AGC_HTTP_BODY_END_LF;
      return;
    case AGC_HTTP_BODY_TRAILER_NAME:
      good = trailer_name(b, c);
      break;
    case AGC_HTTP_BODY_TRAILER_VALUE:
      if (c == '\r') {
        b->state = AGC_HTTP_BODY_TRAILER_LF;
        return;
      }
      good = agc_http_value_byte(c);
      break;
    case AGC_HTTP_BODY_TRAILER_LF:
      if (c == '\n')
        trailer_end(b);
      else
        fail(b, AGC_HTTP_ERR_TRAILER);
      return;
    default:
      if (c != '\n') {
        fail(b, AGC_HTTP_ERR_TRAILER);
        return;
      }
      b->block += 2;
      if (b->block > AGC_HTTP_MAX_BLOCK)
        fail(b, AGC_HTTP_ERR_BLOCK_TOO_LARGE);
      else
        b->state = AGC_HTTP_BODY_DONE;
      return;
  }
  if (!good)
    fail(b, AGC_HTTP_ERR_TRAILER);
  else if (++b->line > AGC_HTTP_MAX_LINE)
    fail(b, AGC_HTTP_ERR_LINE_TOO_LONG);
}

static void frame_byte(agc_http_body *b, uint8_t c) {
  switch (b->state) {
    case AGC_HTTP_BODY_SIZE:
    case AGC_HTTP_BODY_EXTENSION:
      size_byte(b, c);
      return;
    case AGC_HTTP_BODY_SIZE_LF:
      if (c != '\n')
        fail(b, AGC_HTTP_ERR_CHUNK);
      else
        size_done(b);
      return;
    case AGC_HTTP_BODY_CHUNK_CR:
      if (c != '\r')
        fail(b, AGC_HTTP_ERR_CHUNK_END);
      else
        b->state = AGC_HTTP_BODY_CHUNK_LF;
      return;
    case AGC_HTTP_BODY_CHUNK_LF:
      if (c != '\n')
        fail(b, AGC_HTTP_ERR_CHUNK_END);
      else
        b->state = AGC_HTTP_BODY_SIZE;
      return;
    default:
      trailer_byte(b, c);
      return;
  }
}

static size_t data(agc_http_body *b, const uint8_t *in, size_t len) {
  if (b->frame == AGC_HTTP_FRAME_CLOSE) {
    if (len > b->limit - b->len) {
      fail(b, AGC_HTTP_ERR_TOO_LARGE);
      return 0;
    }
    append(b, in, len);
    return len;
  }
  size_t n = len < b->remaining ? len : (size_t)b->remaining;
  append(b, in, n);
  b->remaining -= n;
  if (b->remaining == 0)
    b->state = b->state == AGC_HTTP_BODY_CHUNK ? AGC_HTTP_BODY_CHUNK_CR : AGC_HTTP_BODY_DONE;
  return n;
}

static agc_http_status body_status(const agc_http_body *b) {
  if (b->state == AGC_HTTP_BODY_DONE) return AGC_HTTP_OK;
  return b->state == AGC_HTTP_BODY_FAILED ? AGC_HTTP_ERROR : AGC_HTTP_INCOMPLETE;
}

agc_http_status agc_http_body_feed(agc_http_body *b, const uint8_t *in, size_t len, size_t *used) {
  size_t k = 0;
  while (k < len && b->state != AGC_HTTP_BODY_DONE && b->state != AGC_HTTP_BODY_FAILED) {
    if (b->state == AGC_HTTP_BODY_DATA || b->state == AGC_HTTP_BODY_CHUNK)
      k += data(b, in + k, len - k);
    else
      frame_byte(b, in[k++]);
  }
  *used = k;
  return body_status(b);
}

agc_http_status agc_http_body_end(agc_http_body *b) {
  if (b->state == AGC_HTTP_BODY_DATA && b->frame == AGC_HTTP_FRAME_CLOSE) b->state = AGC_HTTP_BODY_DONE;
  if (b->state != AGC_HTTP_BODY_DONE && b->state != AGC_HTTP_BODY_FAILED) fail(b, AGC_HTTP_ERR_TRUNCATED);
  return body_status(b);
}

void agc_http_body_free(agc_http_body *b) {
  free(b->data);
  b->data = NULL;
  b->len = b->cap = 0;
}
