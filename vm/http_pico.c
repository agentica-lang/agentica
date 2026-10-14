/*
 * The HTTP head adapter: our own pre-scan and start-line checks, then
 * picohttpparser, then the token, value, Host and status checks. The only file
 * that includes picohttpparser.h. Adapter layer, behind http_parse.h. Design:
 * docs/vm/10-io-http.md §10.6 and §10.6.1.
 */
#include "http_parse.h"

#include <picohttpparser.h>
#include <string.h>

typedef struct {
  size_t start, len, next;
} line_span;

typedef struct {
  size_t end;
} head_scan;

static agc_http_status failed(agc_http_error *error, agc_http_error e) {
  *error = e;
  return AGC_HTTP_ERROR;
}

static agc_http_status next_line(const uint8_t *buf, size_t len, size_t from, line_span *line, agc_http_error *error) {
  const uint8_t *lf = from < len ? memchr(buf + from, '\n', len - from) : NULL;
  if (!lf) return len - from > AGC_HTTP_MAX_LINE + 1 ? failed(error, AGC_HTTP_ERR_LINE_TOO_LONG) : AGC_HTTP_INCOMPLETE;
  size_t at = (size_t)(lf - buf);
  if (at == from || buf[at - 1] != '\r') return failed(error, AGC_HTTP_ERR_BARE_LF);
  line->start = from;
  line->len = at - 1 - from;
  line->next = at + 1;
  if (line->len > AGC_HTTP_MAX_LINE) return failed(error, AGC_HTTP_ERR_LINE_TOO_LONG);
  return AGC_HTTP_OK;
}

static bool same(agc_http_slice s, const char *text) {
  size_t n = strlen(text);
  return s.len == n && memcmp(s.data, text, n) == 0;
}

static bool version_shape(agc_http_slice v) {
  if (v.len <= 5 || memcmp(v.data, "HTTP/", 5) != 0) return false;
  for (size_t k = 5; k < v.len; k++)
    if (v.data[k] != '.' && (v.data[k] < '0' || v.data[k] > '9')) return false;
  return true;
}

static size_t split_words(const uint8_t *s, size_t len, agc_http_slice *words, size_t max) {
  if (len == 0 || s[0] == ' ' || s[len - 1] == ' ') return 0;
  size_t n = 0;
  for (size_t k = 0; k < len;) {
    size_t start = k;
    while (k < len && s[k] != ' ') k++;
    if (n == max) return max + 1;
    words[n].data = s + start;
    words[n++].len = k - start;
    while (k < len && s[k] == ' ') k++;
  }
  return n;
}

static agc_http_error request_line(const uint8_t *s, size_t len) {
  agc_http_slice w[3];
  if (split_words(s, len, w, 3) != 3 || !version_shape(w[2])) return AGC_HTTP_ERR_HEAD;
  if (!same(w[2], "HTTP/1.1")) return AGC_HTTP_ERR_VERSION;
  if (same(w[0], "CONNECT")) return AGC_HTTP_ERR_CONNECT;
  if (!agc_http_token(w[0].data, w[0].len)) return AGC_HTTP_ERR_METHOD;
  for (size_t k = 0; k < w[1].len; k++)
    if (w[1].data[k] < 33 || w[1].data[k] > 126) return AGC_HTTP_ERR_TARGET;
  if (w[1].data[0] != '/' && !(same(w[1], "*") && same(w[0], "OPTIONS"))) return AGC_HTTP_ERR_TARGET;
  return AGC_HTTP_ERR_NONE;
}

static agc_http_error response_line(const uint8_t *s, size_t len) {
  size_t k = 0;
  while (k < len && s[k] != ' ') k++;
  agc_http_slice version = {s, k};
  if (!same(version, "HTTP/1.1")) return version_shape(version) ? AGC_HTTP_ERR_VERSION : AGC_HTTP_ERR_HEAD;
  if (k == len) return AGC_HTTP_ERR_HEAD;
  while (k < len && s[k] == ' ') k++;
  if (len - k < 3) return AGC_HTTP_ERR_HEAD;
  for (size_t d = 0; d < 3; d++)
    if (s[k + d] < '0' || s[k + d] > '9') return AGC_HTTP_ERR_HEAD;
  if (len - k > 3 && s[k + 3] != ' ') return AGC_HTTP_ERR_HEAD;
  return AGC_HTTP_ERR_NONE;
}

static agc_http_status scan_head(const uint8_t *buf, size_t len, bool request, head_scan *scan, agc_http_error *error) {
  size_t from = 0;
  if (request && len && buf[0] == '\n') return failed(error, AGC_HTTP_ERR_BARE_LF);
  if (request && len && buf[0] == '\r') {
    if (len < 2) return AGC_HTTP_INCOMPLETE;
    if (buf[1] != '\n') return failed(error, AGC_HTTP_ERR_HEAD);
    from = 2;
  }
  line_span line;
  agc_http_status status = next_line(buf, len, from, &line, error);
  if (status != AGC_HTTP_OK) return status;
  agc_http_error bad = request ? request_line(buf + line.start, line.len) : response_line(buf + line.start, line.len);
  if (bad != AGC_HTTP_ERR_NONE) return failed(error, bad);
  size_t block = 0, count = 0;
  for (size_t at = line.next;;) {
    status = next_line(buf, len, at, &line, error);
    if (status == AGC_HTTP_INCOMPLETE && block + (len - at) > AGC_HTTP_MAX_BLOCK)
      return failed(error, AGC_HTTP_ERR_BLOCK_TOO_LARGE);
    if (status != AGC_HTTP_OK) return status;
    block += line.len + 2;
    if (block > AGC_HTTP_MAX_BLOCK) return failed(error, AGC_HTTP_ERR_BLOCK_TOO_LARGE);
    if (line.len == 0) {
      scan->end = line.next;
      return AGC_HTTP_OK;
    }
    if (++count > AGC_HTTP_MAX_HEADERS) return failed(error, AGC_HTTP_ERR_TOO_MANY_HEADERS);
    at = line.next;
  }
}

static agc_http_status copy_fields(agc_http_head *out, const struct phr_header *fields, size_t count,
                                   agc_http_error *error) {
  out->count = count;
  for (size_t k = 0; k < count; k++) {
    if (!fields[k].name) return failed(error, AGC_HTTP_ERR_OBS_FOLD);
    out->fields[k].name.data = (const uint8_t *)fields[k].name;
    out->fields[k].name.len = fields[k].name_len;
    out->fields[k].value = agc_http_trim((agc_http_slice){(const uint8_t *)fields[k].value, fields[k].value_len});
    if (!agc_http_token(out->fields[k].name.data, out->fields[k].name.len)) return failed(error, AGC_HTTP_ERR_HEADER);
    for (size_t b = 0; b < out->fields[k].value.len; b++)
      if (!agc_http_value_byte(out->fields[k].value.data[b])) return failed(error, AGC_HTTP_ERR_HEADER);
  }
  return AGC_HTTP_OK;
}

static agc_http_status framed(agc_http_head *out, bool request, size_t end, size_t *used, agc_http_error *error) {
  agc_http_error bad = agc_http_framing(out, request);
  if (bad != AGC_HTTP_ERR_NONE) return failed(error, bad);
  *used = end;
  return AGC_HTTP_OK;
}

agc_http_status agc_http_parse_request_head(const uint8_t *buf, size_t len, agc_http_head *out, size_t *used,
                                            agc_http_error *error) {
  *error = AGC_HTTP_ERR_NONE;
  head_scan scan;
  agc_http_status status = scan_head(buf, len, true, &scan, error);
  if (status != AGC_HTTP_OK) return status;
  struct phr_header fields[AGC_HTTP_MAX_HEADERS];
  size_t count = AGC_HTTP_MAX_HEADERS;
  const char *method, *target;
  size_t method_len, target_len;
  int minor;
  int r = phr_parse_request((const char *)buf, scan.end, &method, &method_len, &target, &target_len, &minor, fields,
                            &count, 0);
  if (r < 0 || (size_t)r != scan.end) return failed(error, AGC_HTTP_ERR_HEAD);
  memset(out, 0, sizeof *out);
  out->method = (agc_http_slice){(const uint8_t *)method, method_len};
  out->target = (agc_http_slice){(const uint8_t *)target, target_len};
  status = copy_fields(out, fields, count, error);
  if (status != AGC_HTTP_OK) return status;
  size_t hosts = 0;
  bool empty = false;
  for (size_t k = 0; k < out->count; k++) {
    if (!agc_http_named(out->fields[k].name, "host")) continue;
    hosts++;
    empty = empty || out->fields[k].value.len == 0;
  }
  if (hosts != 1 || empty) return failed(error, AGC_HTTP_ERR_HOST);
  return framed(out, true, scan.end, used, error);
}

agc_http_status agc_http_parse_response_head(const uint8_t *buf, size_t len, agc_http_head *out, size_t *used,
                                             agc_http_error *error) {
  *error = AGC_HTTP_ERR_NONE;
  head_scan scan;
  agc_http_status status = scan_head(buf, len, false, &scan, error);
  if (status != AGC_HTTP_OK) return status;
  struct phr_header fields[AGC_HTTP_MAX_HEADERS];
  size_t count = AGC_HTTP_MAX_HEADERS;
  const char *reason;
  size_t reason_len;
  int minor, code;
  int r = phr_parse_response((const char *)buf, scan.end, &minor, &code, &reason, &reason_len, fields, &count, 0);
  if (r < 0 || (size_t)r != scan.end) return failed(error, AGC_HTTP_ERR_HEAD);
  memset(out, 0, sizeof *out);
  out->status = code;
  out->reason = (agc_http_slice){(const uint8_t *)reason, reason_len};
  if (code < 100 || code > 599) return failed(error, AGC_HTTP_ERR_STATUS);
  if (code == 101) return failed(error, AGC_HTTP_ERR_UPGRADE);
  status = copy_fields(out, fields, count, error);
  if (status != AGC_HTTP_OK) return status;
  if (code < 200) {
    *used = scan.end;
    return AGC_HTTP_OK;
  }
  return framed(out, false, scan.end, used, error);
}
