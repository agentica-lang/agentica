#include "core.h"
#include "list_impl.h"

#include <stdlib.h>
#include <string.h>

static agc_list *list_new(size_t n) {
  agc_list *l = agc_alloc(agc_size_add(sizeof(agc_list), agc_size_mul(n, sizeof(agc_value))));
  l->len = n;
  return l;
}

size_t agc_list_len(const agc_list *l) { return list_len(l); }

agc_value agc_list_get(const agc_list *l, size_t i) { return list_get(l, i); }

void agc_list_builder_sized(agc_list_builder *b, size_t n) {
  b->out = list_new(n);
  b->count = 0;
  b->leaf = NULL;
}

void agc_list_builder_push(agc_list_builder *b, agc_value v) {
  if (b->count >= b->out->len) abort();
  b->out->items[b->count++] = v;
}

agc_list *agc_list_builder_finish(agc_list_builder *b) {
  if (b->count != b->out->len) abort();
  return b->out;
}

agc_list *agc_list_from_array(const agc_value *items, size_t n) {
  agc_list *l = list_new(n);
  if (n) memcpy(l->items, items, n * sizeof(agc_value));
  return l;
}

void agc_list_to_array(const agc_list *l, agc_value *out) {
  if (l->len) memcpy(out, l->items, l->len * sizeof(agc_value));
}

void agc_list_cursor_begin(agc_list_cursor *c, const agc_list *l, size_t at) {
  if (at > l->len) abort();
  c->list = l;
  c->index = at;
  c->start = 0;
  c->end = l->len;
  c->chunk = l->items;
}

bool agc_list_cursor_next(agc_list_cursor *c, agc_value *out) {
  if (c->index >= c->end) return false;
  *out = c->chunk[c->index - c->start];
  c->index++;
  return true;
}

agc_list *agc_list_append(const agc_list *l, agc_value v) {
  agc_list *r = list_new(agc_size_add(l->len, 1));
  if (l->len) memcpy(r->items, l->items, l->len * sizeof(agc_value));
  r->items[l->len] = v;
  return r;
}

agc_list *agc_list_set(const agc_list *l, size_t i, agc_value v) {
  if (i >= l->len) abort();
  agc_list *r = list_new(l->len);
  memcpy(r->items, l->items, l->len * sizeof(agc_value));
  r->items[i] = v;
  return r;
}

agc_list *agc_list_slice(const agc_list *l, size_t from, size_t count) {
  if (from > l->len || count > l->len - from) abort();
  if (from == 0 && count == l->len) return (agc_list *)l;
  agc_list *r = list_new(count);
  if (count) memcpy(r->items, l->items + from, count * sizeof(agc_value));
  return r;
}

agc_list *agc_list_concat(const agc_list *a, const agc_list *b) {
  if (b->len == 0) return (agc_list *)a;
  if (a->len == 0) return (agc_list *)b;
  agc_list *r = list_new(agc_size_add(a->len, b->len));
  memcpy(r->items, a->items, a->len * sizeof(agc_value));
  memcpy(r->items + a->len, b->items, b->len * sizeof(agc_value));
  return r;
}
