/* Header fields and message bytes shared by the HTTP client and server
   (docs/vm/10-io-http.md §10.7). */
#include "http_fields.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *const header_fields[] = {"name", "value"};

void agc_http_put(agc_http_bytes *b, const void *data, size_t n) {
  if (!n) return;
  if (b->cap - b->len < n) {
    size_t cap = b->cap ? b->cap : 256;
    while (cap - b->len < n) cap = agc_size_mul(cap, 2);
    uint8_t *bigger = realloc(b->data, cap);
    if (!bigger) agc_out_of_memory();
    b->data = bigger;
    b->cap = cap;
  }
  memcpy(b->data + b->len, data, n);
  b->len += n;
}

void agc_http_put_text(agc_http_bytes *b, const char *text) { agc_http_put(b, text, strlen(text)); }

static const char *put_value(agc_http_bytes *b, const agc_string *value) {
  for (size_t at = 0; at < value->bytes;) {
    uint32_t cp = agc_utf8_next((const uint8_t *)value->data, value->bytes, &at);
    if (cp > 255 || !agc_http_value_byte((uint8_t)cp)) return "header values must be Latin-1 text without control characters";
    uint8_t ch = (uint8_t)cp;
    agc_http_put(b, &ch, 1);
  }
  return NULL;
}

const char *agc_http_put_headers(agc_vm *vm, agc_http_bytes *b, const agc_list *headers, const char *const *managed,
                                 size_t managed_count, const char *managed_reason, const char *skip, size_t *count) {
  size_t block = b->len;
  for (size_t k = 0; k < headers->len; k++) {
    const agc_struct *h = agc_as_struct(vm, headers->items[k]);
    if (h->n != 2) return "invalid header";
    const agc_string *name = agc_as_string(vm, h->fields[0]);
    const agc_string *value = agc_as_string(vm, h->fields[1]);
    if (!agc_http_token((const uint8_t *)name->data, name->bytes)) return "header names must be HTTP tokens";
    agc_http_slice slice = {(const uint8_t *)name->data, name->bytes};
    for (size_t m = 0; m < managed_count; m++)
      if (agc_http_named(slice, managed[m])) return managed_reason;
    if (skip && agc_http_named(slice, skip)) continue;
    size_t start = b->len;
    agc_http_put(b, name->data, name->bytes);
    agc_http_put_text(b, ": ");
    const char *bad = put_value(b, value);
    if (bad) return bad;
    agc_http_put_text(b, "\r\n");
    if (b->len - start > AGC_HTTP_MAX_LINE + 2) return "a header line is too large";
    if (++*count > AGC_HTTP_MAX_HEADERS) return "too many headers";
  }
  if (b->len - block > AGC_HTTP_MAX_BLOCK) return "headers are too large";
  return NULL;
}

void agc_http_fields_keep(agc_http_fields *f, const agc_http_head *head) {
  size_t total = 0;
  for (size_t k = 0; k < head->count; k++) total += head->fields[k].name.len + head->fields[k].value.len;
  f->count = head->count;
  f->sizes = calloc(head->count ? head->count * 2 : 1, sizeof(size_t));
  f->data = malloc(total ? total : 1);
  if (!f->sizes || !f->data) agc_out_of_memory();
  size_t at = 0;
  for (size_t k = 0; k < head->count; k++) {
    const agc_http_field *field = &head->fields[k];
    for (size_t b = 0; b < field->name.len; b++) {
      uint8_t ch = field->name.data[b];
      f->data[at++] = ch >= 'A' && ch <= 'Z' ? (uint8_t)(ch + 32) : ch;
    }
    if (field->value.len) memcpy(f->data + at, field->value.data, field->value.len);
    at += field->value.len;
    f->sizes[2 * k] = field->name.len;
    f->sizes[2 * k + 1] = field->value.len;
  }
}

void agc_http_fields_free(agc_http_fields *f) {
  free(f->sizes);
  free(f->data);
  f->sizes = NULL;
  f->data = NULL;
  f->count = 0;
}

size_t agc_http_fields_bytes(const agc_http_fields *f) {
  size_t total = 0;
  for (size_t k = 0; k < 2 * f->count; k++) total += f->sizes[k];
  return total;
}

static agc_string *latin1(const uint8_t *data, size_t len) {
  size_t extra = 0;
  for (size_t k = 0; k < len; k++) extra += data[k] >= 0x80;
  agc_string *s = agc_new_string(agc_size_add(len, extra), len);
  size_t at = 0;
  for (size_t k = 0; k < len; k++) {
    if (data[k] < 0x80) {
      s->data[at++] = (char)data[k];
    } else {
      s->data[at++] = (char)(0xC0 | (data[k] >> 6));
      s->data[at++] = (char)(0x80 | (data[k] & 0x3F));
    }
  }
  return s;
}

agc_value agc_http_header_list(agc_vm *vm, const agc_http_fields *f) {
  uint32_t header_type = agc_builtin_struct(vm, "Header", header_fields, 2);
  agc_list *headers = agc_new_list(f->count);
  size_t at = 0;
  for (size_t k = 0; k < f->count; k++) {
    agc_struct *h = agc_new_struct(header_type, 2);
    size_t name = f->sizes[2 * k], value = f->sizes[2 * k + 1];
    h->fields[0] = agc_string_value(agc_make_string((const char *)f->data + at, name, name));
    h->fields[1] = agc_string_value(latin1(f->data + at + name, value));
    at += name + value;
    headers->items[k] = agc_struct_value(h);
  }
  return agc_list_value(headers);
}

static bool value_closes(agc_http_slice v) {
  size_t start = 0;
  for (size_t at = 0; at <= v.len; at++) {
    if (at < v.len && v.data[at] != ',') continue;
    if (agc_http_named(agc_http_trim((agc_http_slice){v.data + start, at - start}), "close")) return true;
    start = at + 1;
  }
  return false;
}

bool agc_http_closes(const agc_http_head *head) {
  for (size_t k = 0; k < head->count; k++)
    if (agc_http_named(head->fields[k].name, "connection") && value_closes(head->fields[k].value)) return true;
  return false;
}

agc_http_slice agc_http_text(agc_vm *vm, agc_value v) {
  const agc_string *s = agc_as_string(vm, v);
  return (agc_http_slice){(const uint8_t *)s->data, s->bytes};
}

bool agc_http_list_closes(agc_vm *vm, const agc_list *headers) {
  for (size_t k = 0; k < headers->len; k++) {
    const agc_struct *h = agc_as_struct(vm, headers->items[k]);
    if (agc_http_named(agc_http_text(vm, h->fields[0]), "connection") && value_closes(agc_http_text(vm, h->fields[1])))
      return true;
  }
  return false;
}

agc_value agc_http_error_result(const char *prefix, const char *reason) {
  size_t size = agc_size_add(strlen(prefix), strlen(reason) + 1);
  char *text = agc_alloc_atomic(size);
  snprintf(text, size, "%s%s", prefix, reason);
  return agc_error_value(text);
}
