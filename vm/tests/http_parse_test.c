#include "../agc.h"
#include "../http_parse.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  char *data;
  size_t len, cap;
} text;

static void add(text *t, const char *s, size_t n) {
  if (t->len + n + 1 > t->cap) {
    t->cap = (t->len + n + 1) * 2;
    t->data = realloc(t->data, t->cap);
    assert(t->data);
  }
  memcpy(t->data + t->len, s, n);
  t->len += n;
  t->data[t->len] = 0;
}

static void adds(text *t, const char *s) { add(t, s, strlen(s)); }

static void repeat(text *t, char c, size_t n) {
  for (size_t k = 0; k < n; k++) add(t, &c, 1);
}

static void headers(text *t, size_t n) {
  char line[32];
  for (size_t k = 0; k < n; k++) {
    snprintf(line, sizeof line, "X-%zu: v\r\n", k);
    adds(t, line);
  }
}

static agc_http_head head;

static int request(const char *s, size_t len) {
  size_t used = 0;
  agc_http_error error = AGC_HTTP_ERR_NONE;
  agc_http_status status = agc_http_parse_request_head((const uint8_t *)s, len, &head, &used, &error);
  if (status == AGC_HTTP_INCOMPLETE) return 0;
  if (status == AGC_HTTP_OK) {
    assert(used == len);
    return 200;
  }
  return agc_http_error_code(error);
}

static int req(const char *s) { return request(s, strlen(s)); }

static int response(const char *s) {
  size_t used = 0;
  agc_http_error error = AGC_HTTP_ERR_NONE;
  agc_http_status status = agc_http_parse_response_head((const uint8_t *)s, strlen(s), &head, &used, &error);
  if (status == AGC_HTTP_INCOMPLETE) return 0;
  if (status == AGC_HTTP_OK) return 200;
  return -(int)error;
}

static int body(agc_http_frame frame, uint64_t length, uint64_t limit, const char *s, size_t len, bool one_byte,
                bool eof, agc_http_body *out) {
  agc_http_body_init(out, frame, length, limit);
  size_t at = 0, none;
  agc_http_status status = agc_http_body_feed(out, NULL, 0, &none);
  while (status == AGC_HTTP_INCOMPLETE && at < len) {
    size_t used;
    size_t n = one_byte ? 1 : len - at;
    status = agc_http_body_feed(out, (const uint8_t *)s + at, n, &used);
    at += used;
    if (status == AGC_HTTP_INCOMPLETE) assert(used == n);
  }
  if (status == AGC_HTTP_INCOMPLETE && eof) status = agc_http_body_end(out);
  if (status == AGC_HTTP_INCOMPLETE) return 0;
  return status == AGC_HTTP_OK ? 200 : agc_http_error_code(out->error);
}

static int chunked(const char *s, uint64_t limit) {
  agc_http_body a, b;
  int bulk = body(AGC_HTTP_FRAME_CHUNKED, 0, limit, s, strlen(s), false, true, &a);
  int bytes = body(AGC_HTTP_FRAME_CHUNKED, 0, limit, s, strlen(s), true, true, &b);
  assert(bulk == bytes);
  if (bulk == 200) assert(a.len == b.len && (a.len == 0 || memcmp(a.data, b.data, a.len) == 0));
  agc_http_body_free(&a);
  agc_http_body_free(&b);
  return bulk;
}

static void request_heads(void) {
  assert(req("GET /a?b=1 HTTP/1.1\r\nHost: x\r\n\r\n") == 200);
  assert(head.method.len == 3 && head.target.len == 6 && head.count == 1);
  assert(head.frame == AGC_HTTP_FRAME_LENGTH && head.length == 0);
  assert(req("GET / HTTP/1.1\r\nHost: x\r\n") == 0);
  assert(req("GET / HTTP/1.1\r") == 0);
  assert(req("GET  /  HTTP/1.1\r\nHost: x\r\n\r\n") == 200);
  assert(req("\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\n") == 200);
  assert(req("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n") == 400);
  assert(req("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\nContent-Length: 5\r\n\r\n") == 400);
  assert(req("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n") == 400);
  assert(req("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\n") == 200);
  assert(head.length == 5);
  assert(req("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5, 5\r\n\r\n") == 200 && head.length == 5);
  assert(req("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5,\r\n\r\n") == 400);
  assert(req("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: -5\r\n\r\n") == 400);
  assert(req("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n") == 200);
  assert(head.frame == AGC_HTTP_FRAME_CHUNKED);
  assert(req("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\n") == 501);
  assert(req("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, chunked\r\n\r\n") == 501);
  assert(req("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n") == 501);
  assert(req("GET / HTTP/1.1\nHost: x\r\n\r\n") == 400);
  assert(req("GET / HTTP/1.1\r\nHost: x\n\r\n") == 400);
  assert(req("\nGET / HTTP/1.1\r\nHost: x\r\n\r\n") == 400);
  assert(req("GET / HTTP/1\r\n") == 505);
  assert(req("GET / HTTP/2\r\nHost: x\r\n\r\n") == 505);
  assert(req("GET / HTTP/1.10\r\nHost: x\r\n\r\n") == 505);
  assert(req("GET / HTTP/2.0\r\nHost: x\r\n\r\n") == 505);
  assert(req("GET / HTTX/1.1\r\nHost: x\r\n\r\n") == 400);
  assert(req("GET / HTTP/1.1 \r\nHost: x\r\n\r\n") == 400);
  assert(req("garbage\r\n") == 400);
  assert(req("GET http://x/ HTTP/1.1\r\nHost: x\r\n\r\n") == 400);
  assert(req("GET /\xc3\xa9 HTTP/1.1\r\nHost: x\r\n\r\n") == 400);
  assert(req("GET * HTTP/1.1\r\nHost: x\r\n\r\n") == 400);
  assert(req("OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n") == 200);
  assert(req("G(T / HTTP/1.1\r\nHost: x\r\n\r\n") == 400);
  assert(req("CONNECT x:443 HTTP/1.1\r\nHost: x\r\n\r\n") == 501);
  assert(req("GET / HTTP/1.1\r\nHost: x\r\nX-A: 1\r\n  folded\r\n\r\n") == 400);
  assert(req("GET / HTTP/1.1\r\nHost: x\r\nBad Name: 1\r\n\r\n") == 400);
  assert(req("GET / HTTP/1.1\r\nHost: x\r\nX-A: a\x01" "b\r\n\r\n") == 400);
  assert(req("GET / HTTP/1.1\r\n\r\n") == 400);
  assert(req("GET / HTTP/1.1\r\nHost: \r\n\r\n") == 400);
  assert(req("GET / HTTP/1.1\r\nHost: x\r\nHost: y\r\n\r\n") == 400);
}

static void request_limits(void) {
  text t = {0};
  adds(&t, "GET /");
  repeat(&t, 'a', AGC_HTTP_MAX_LINE);
  adds(&t, " HTTP/1.1\r\nHost: x\r\n\r\n");
  assert(req(t.data) == 431);
  t.len = 0;
  adds(&t, "GET /");
  repeat(&t, 'a', AGC_HTTP_MAX_LINE + 10);
  assert(req(t.data) == 431);
  t.len = 0;
  adds(&t, "GET / HTTP/1.1\r\nHost: x\r\nX-Big: ");
  repeat(&t, 'a', AGC_HTTP_MAX_LINE - 7);
  adds(&t, "\r\n\r\n");
  assert(req(t.data) == 200);
  t.len = 0;
  adds(&t, "GET / HTTP/1.1\r\nHost: x\r\nX-Big: ");
  repeat(&t, 'a', AGC_HTTP_MAX_LINE - 6);
  adds(&t, "\r\n\r\n");
  assert(req(t.data) == 431);
  t.len = 0;
  adds(&t, "GET / HTTP/1.1\r\nHost: x\r\n");
  for (int k = 0; k < 9; k++) {
    adds(&t, "X-Big: ");
    repeat(&t, 'a', 8000);
    adds(&t, "\r\n");
  }
  assert(req(t.data) == 431);
  t.len = 0;
  adds(&t, "GET / HTTP/1.1\r\nHost: x\r\n");
  headers(&t, 99);
  adds(&t, "\r\n");
  assert(req(t.data) == 200 && head.count == 100);
  t.len = 0;
  adds(&t, "\r\nGET / HTTP/1.1\r\nHost: x\r\n");
  headers(&t, 99);
  adds(&t, "\r\n");
  assert(req(t.data) == 200);
  t.len = 0;
  adds(&t, "GET / HTTP/1.1\r\nHost: x\r\n");
  headers(&t, 100);
  adds(&t, "\r\n");
  assert(req(t.data) == 431);
  t.len = 0;
  adds(&t, "GET / HTTP/1.1\r\nHost: x\r\n");
  headers(&t, 149);
  assert(req(t.data) == 431);
  t.len = 0;
  adds(&t, "GET / HTTP/2.0\r\n");
  headers(&t, 101);
  adds(&t, "\r\n");
  assert(req(t.data) == 505);
  free(t.data);
}

static void response_heads(void) {
  assert(response("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n") == 200);
  assert(head.status == 200 && head.frame == AGC_HTTP_FRAME_LENGTH && head.length == 3);
  assert(response("HTTP/1.1 200 OK\r\nServer: x\r\n\r\n") == 200 && head.frame == AGC_HTTP_FRAME_CLOSE);
  assert(response("HTTP/1.1 204\r\n\r\n") == 200 && head.status == 204);
  assert(response("HTTP/1.1  200  Fine  \r\n\r\n") == 200);
  assert(response("HTTP/1.1 100 Continue\r\n\r\n") == 200 && head.status == 100);
  assert(response("HTTP/1.1 200 OK\r\n") == 0);
  assert(response("HTTP/1.0 200 OK\r\n\r\n") == -AGC_HTTP_ERR_VERSION);
  assert(response("HTTP/2 200 OK\r\n\r\n") == -AGC_HTTP_ERR_VERSION);
  assert(response("HTTX/1.1 200 OK\r\n\r\n") == -AGC_HTTP_ERR_HEAD);
  assert(response("HTTP/1.1 099 Low\r\n\r\n") == -AGC_HTTP_ERR_STATUS);
  assert(response("HTTP/1.1 600 High\r\n\r\n") == -AGC_HTTP_ERR_STATUS);
  assert(response("HTTP/1.1 101 Switching\r\n\r\n") == -AGC_HTTP_ERR_UPGRADE);
  assert(response("HTTP/1.1 20 OK\r\n\r\n") == -AGC_HTTP_ERR_HEAD);
  assert(response("HTTP/1.1 2000 OK\r\n\r\n") == -AGC_HTTP_ERR_HEAD);
  assert(response("HTTP/1.1 200 O\x01K\r\n\r\n") == -AGC_HTTP_ERR_HEAD);
  assert(response("HTTP/1.1 200 OK\nServer: x\r\n\r\n") == -AGC_HTTP_ERR_BARE_LF);
  assert(response("HTTP/1.1 200 OK\r\nX: 1\r\n folded\r\n\r\n") == -AGC_HTTP_ERR_OBS_FOLD);
  assert(response("HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n") == -AGC_HTTP_ERR_LENGTH);
  assert(response("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n") == -AGC_HTTP_ERR_TRANSFER);
}

static void bodies(void) {
  agc_http_body b;
  assert(body(AGC_HTTP_FRAME_LENGTH, 5, 10, "hello", 5, false, false, &b) == 200 && b.len == 5);
  agc_http_body_free(&b);
  assert(body(AGC_HTTP_FRAME_LENGTH, 5, 10, "hel", 3, false, true, &b) == 400);
  agc_http_body_free(&b);
  assert(body(AGC_HTTP_FRAME_LENGTH, 11, 10, "", 0, false, false, &b) == 413);
  agc_http_body_free(&b);
  assert(body(AGC_HTTP_FRAME_LENGTH, 0, 10, "", 0, false, false, &b) == 200 && b.len == 0);
  assert(body(AGC_HTTP_FRAME_CLOSE, 0, 10, "0123456789", 10, true, true, &b) == 200 && b.len == 10);
  agc_http_body_free(&b);
  assert(body(AGC_HTTP_FRAME_CLOSE, 0, 10, "0123456789x", 11, false, true, &b) == 413);
  agc_http_body_free(&b);
  assert(chunked("5;name=v\r\nhello\r\n6\r\n world\r\n0\r\nX-Trailer: ok\r\n\r\n", 100) == 200);
  assert(chunked("A\r\n0123456789\r\n0\r\n\r\n", 10) == 200);
  assert(chunked("B\r\n0123456789x\r\n0\r\n\r\n", 10) == 413);
  assert(chunked("ffffffffffffffffffffffff\r\n", 1000) == 413);
  assert(chunked("zz\r\n", 100) == 400);
  assert(chunked("\r\n", 100) == 400);
  assert(chunked("5 \r\nhello\r\n0\r\n\r\n", 100) == 400);
  assert(chunked("5\nhello\r\n0\r\n\r\n", 100) == 400);
  assert(chunked("5\r\nhelloXY0\r\n\r\n", 100) == 400);
  assert(chunked("5\r\nhello\r\n0\r\n", 100) == 400);
  assert(chunked("0\r\nContent-Length: 5\r\n\r\n", 100) == 400);
  assert(chunked("0\r\nTrailer: x\r\n\r\n", 100) == 400);
  assert(chunked("0\r\nBad Name: x\r\n\r\n", 100) == 400);
  assert(chunked("0\r\nX: a\x01\r\n\r\n", 100) == 400);
  assert(chunked("0\r\nX: a\n\r\n", 100) == 400);
  text t = {0};
  adds(&t, "1;");
  repeat(&t, 'e', AGC_HTTP_MAX_LINE);
  adds(&t, "\r\nx\r\n0\r\n\r\n");
  assert(chunked(t.data, 100) == 431);
  t.len = 0;
  adds(&t, "0\r\nX: ");
  repeat(&t, 'a', AGC_HTTP_MAX_LINE);
  adds(&t, "\r\n\r\n");
  assert(chunked(t.data, 100) == 431);
  t.len = 0;
  adds(&t, "0\r\n");
  for (int k = 0; k < 9; k++) {
    adds(&t, "X: ");
    repeat(&t, 'a', 8000);
    adds(&t, "\r\n");
  }
  adds(&t, "\r\n");
  assert(chunked(t.data, 100) == 431);
  t.len = 0;
  adds(&t, "0\r\n");
  headers(&t, 100);
  adds(&t, "\r\n");
  assert(chunked(t.data, 100) == 200);
  t.len = 0;
  adds(&t, "0\r\n");
  headers(&t, 101);
  adds(&t, "\r\n");
  assert(chunked(t.data, 100) == 431);
  free(t.data);
  assert(body(AGC_HTTP_FRAME_CHUNKED, 0, 100, "5\r\nhello\r\n0\r\n\r\nNEXT", 19, false, false, &b) == 200);
  assert(b.len == 5 && memcmp(b.data, "hello", 5) == 0);
  agc_http_body_free(&b);
}

int main(void) {
  request_heads();
  request_limits();
  response_heads();
  bodies();
  assert(agc_http_error_code(AGC_HTTP_ERR_TOO_LARGE) == 413);
  assert(agc_http_error_code(AGC_HTTP_ERR_CONNECT) == 501);
  puts("http parse tests passed");
  return 0;
}
