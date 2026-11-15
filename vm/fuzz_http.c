/*
 * The libFuzzer entry point of the HTTP head and body parsers (make vm-libfuzz-http). The first byte of an input picks
 * a request or a response head and where to cut the body; the rest is the bytes on the wire. A check that fails
 * aborts: a prefix parses to more than the whole, a head written back with agc_http_put_headers parses to another
 * head (a refusal for a head limit is fine), or a body cut in two decodes otherwise. Driver layer. Design:
 * docs/vm/11-build-ci-supply-chain.md (Fuzzing).
 */
#include "core.h"
#include "http_fields.h"
#include "http_parse.h"

#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size); // NOLINT(readability-identifier-naming)

#define BODY_LIMIT ((uint64_t)1 << 20)
#define PREFIXES 64

static void check(bool ok, const char *what) {
  if (ok) return;
  fprintf(stderr, "fuzz_http: %s\n", what);
  abort();
}

static agc_http_status parse(bool request, const uint8_t *buf, size_t len, agc_http_head *head, size_t *used,
                             agc_http_error *error) {
  *used = 0;
  return request ? agc_http_parse_request_head(buf, len, head, used, error)
                 : agc_http_parse_response_head(buf, len, head, used, error);
}

static bool same_slice(agc_http_slice a, agc_http_slice b) {
  return a.len == b.len && (a.len == 0 || memcmp(a.data, b.data, a.len) == 0);
}

static void prefix(bool request, const uint8_t *buf, size_t k, agc_http_status whole, size_t used) {
  static agc_http_head head;
  size_t at;
  agc_http_error error;
  agc_http_status s = parse(request, buf, k, &head, &at, &error);
  if (whole == AGC_HTTP_OK) {
    check(k < used ? s == AGC_HTTP_INCOMPLETE : s == AGC_HTTP_OK && at == used, "a prefix parses otherwise");
  } else {
    check(s != AGC_HTTP_OK, "a prefix parses where the whole does not");
    check(s != AGC_HTTP_ERROR || whole == AGC_HTTP_ERROR, "a prefix fails where the whole is incomplete");
  }
}

/* About PREFIXES cuts spread over the input, and every cut in the last bytes of the head (or of the input). */
static void prefixes(bool request, const uint8_t *buf, size_t len, agc_http_status whole, size_t used) {
  size_t step = len / PREFIXES + 1;
  for (size_t k = 0; k < len; k += step) prefix(request, buf, k, whole, used);
  size_t end = whole == AGC_HTTP_OK ? used : len;
  for (size_t k = end > 4 ? end - 4 : 0; k <= end + 1 && k < len; k++) prefix(request, buf, k, whole, used);
}

static agc_string *latin1(const agc_http_slice s) {
  size_t extra = 0;
  for (size_t k = 0; k < s.len; k++) extra += s.data[k] >= 0x80;
  agc_string *out = agc_new_string(s.len + extra, s.len);
  size_t at = 0;
  for (size_t k = 0; k < s.len; k++) {
    if (s.data[k] < 0x80) {
      out->data[at++] = (char)s.data[k];
    } else {
      out->data[at++] = (char)(0xC0 | (s.data[k] >> 6));
      out->data[at++] = (char)(0x80 | (s.data[k] & 0x3F));
    }
  }
  return out;
}

/* The head as std/http sends it: each character of the UTF-8 head as one Latin-1 byte. */
static size_t wire(uint8_t *data, size_t len) {
  size_t out = 0;
  for (size_t at = 0; at < len;) {
    uint32_t cp = agc_utf8_next(data, len, &at);
    check(cp <= 0xFF, "a written head holds a character above U+00FF");
    data[out++] = (uint8_t)cp;
  }
  return out;
}

/* The head as the VM writes one: the start line, then the fields through agc_http_put_headers. */
static void round_trip(agc_vm *vm, bool request, const agc_http_head *head) {
  agc_http_bytes b = {0};
  char line[32];
  if (request) {
    agc_http_put(&b, head->method.data, head->method.len);
    agc_http_put_text(&b, " ");
    agc_http_put(&b, head->target.data, head->target.len);
    agc_http_put_text(&b, " HTTP/1.1\r\n");
  } else {
    snprintf(line, sizeof line, "HTTP/1.1 %03d ", head->status);
    agc_http_put_text(&b, line);
    agc_string *reason = latin1(head->reason);
    agc_http_put(&b, reason->data, reason->bytes);
    agc_http_put_text(&b, "\r\n");
  }
  agc_list_builder fields;
  agc_list_builder_sized(&fields, head->count);
  for (size_t k = 0; k < head->count; k++) {
    agc_struct *field = agc_new_struct(0, 2);
    field->fields[0] = agc_string_value(latin1(head->fields[k].name));
    field->fields[1] = agc_string_value(latin1(head->fields[k].value));
    agc_list_builder_push(&fields, agc_struct_value(field));
  }
  size_t count = 0;
  bool too_large;
  const char *bad = agc_http_put_headers(vm, &b, agc_list_builder_finish(&fields), NULL, 0, NULL, NULL, &count,
                                         &too_large);
  if (bad) {
    check(too_large, bad);
    free(b.data);
    return;
  }
  agc_http_put_text(&b, "\r\n");
  b.len = wire(b.data, b.len);
  static agc_http_head again;
  size_t used;
  agc_http_error error;
  agc_http_status s = parse(request, b.data, b.len, &again, &used, &error);
  // #1646: the writer does not count the final empty line in the block, so it can write a block the parser refuses.
  if (s == AGC_HTTP_ERROR && error == AGC_HTTP_ERR_BLOCK_TOO_LARGE) {
    free(b.data);
    return;
  }
  check(s == AGC_HTTP_OK && used == b.len, "a written head does not parse");
  check(again.count == head->count && again.frame == head->frame && again.length == head->length &&
            again.status == head->status && same_slice(again.method, head->method) &&
            same_slice(again.reason, head->reason) &&
            same_slice(again.target, head->target),
        "a written head parses to another head");
  for (size_t k = 0; k < head->count; k++)
    check(same_slice(again.fields[k].name, head->fields[k].name) &&
              same_slice(again.fields[k].value, head->fields[k].value),
          "a written field parses to another field");
  free(b.data);
}

static agc_http_status decode(const agc_http_head *head, const uint8_t *in, size_t len, size_t cut,
                              agc_http_body *body) {
  agc_http_body_init(body, head->frame, head->length, BODY_LIMIT);
  agc_http_status s = AGC_HTTP_INCOMPLETE;
  size_t done = 0;
  for (size_t end = cut; done < len && s == AGC_HTTP_INCOMPLETE; end = len) {
    size_t used = 0;
    s = agc_http_body_feed(body, in + done, end - done, &used);
    check(used <= end - done, "the body decoder used more than it got");
    done += used;
    if (used == 0 && end == len) break;
  }
  return s == AGC_HTTP_INCOMPLETE ? agc_http_body_end(body) : s;
}

static void bodies(const agc_http_head *head, const uint8_t *in, size_t len, size_t cut) {
  agc_http_body whole, split;
  agc_http_status a = decode(head, in, len, len, &whole);
  agc_http_status b = decode(head, in, len, cut, &split);
  check(a == b && whole.error == split.error, "a cut body decodes otherwise");
  check(whole.len == split.len && (whole.len == 0 || memcmp(whole.data, split.data, whole.len) == 0),
        "a cut body gives other bytes");
  agc_http_body_free(&whole);
  agc_http_body_free(&split);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  if (size < 1) return 0;
  bool request = !(data[0] & 1);
  const uint8_t *buf = data + 1;
  size_t len = size - 1;
  static agc_http_head head;
  size_t used;
  agc_http_error error;
  agc_http_status whole = parse(request, buf, len, &head, &used, &error);
  check(whole != AGC_HTTP_OK || used <= len, "a head used more than it got");
  check(whole != AGC_HTTP_ERROR || error != AGC_HTTP_ERR_NONE, "an error without a reason");
  prefixes(request, buf, len, whole, used);
  if (whole != AGC_HTTP_OK) return 0;
  agc_init();
  jmp_buf over_limit;
  agc_vm *volatile vm = NULL;
  if (setjmp(over_limit)) {
    if (vm) agc_io_close(vm);
    agc_release_all();
    return 0;
  }
  agc_set_alloc_limit(&over_limit, (size_t)256 << 20);
  vm = agc_alloc(sizeof(agc_vm));
  agc_vm_init(vm, NULL, stdout, stderr, INT64_MAX);
  round_trip(vm, request, &head);
  if (request || head.status >= 200) bodies(&head, buf + used, len - used, (len - used) * (data[0] >> 1) / 128);
  agc_io_close(vm);
  agc_release_all();
  return 0;
}
