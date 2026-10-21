/*
 * Lists in C: a persistent vector, a 32-way trie of leaves of 32 items plus an
 * inline tail. It owns the layout (list_impl.h is private to it, interp.c and
 * tests/list_test.c): the sized builder and cursor, get, append, set, slice and
 * concat that share leaves, reverse and repeat, and the unboxed leaves of Int
 * and Float lists. Core layer. Design: docs/vm/17-lists.md.
 */
#include "core.h"
#include "list_impl.h"

#include <stdlib.h>
#include <string.h>

#define MAX_LEVELS 12

typedef struct {
  list_branch *root;
  uint32_t shift;
} list_trie;

static size_t trie_items(size_t n) { return n ? list_tail_off(n) : 0; }

static uint32_t shift_for(size_t trie_len) {
  if (trie_len == 0) return 0;
  uint32_t s = LIST_BITS;
  while (trie_len > ((size_t)1 << (s + LIST_BITS))) s += LIST_BITS;
  return s;
}

static size_t stride_of(uint32_t kind) { return kind ? sizeof(uint64_t) : sizeof(agc_value); }

static uint32_t kind_of(agc_value v) { return v.tag == AGC_T_INT || v.tag == AGC_T_FLOAT ? v.tag : 0; }

static void *items_alloc(uint32_t kind, size_t bytes) { return kind ? agc_alloc_atomic(bytes) : agc_alloc(bytes); }

static void item_put(uint32_t kind, char *dst, agc_value v) {
  if (kind) {
    uint64_t word = agc_value_word(v);
    memcpy(dst, &word, sizeof word);
  } else {
    memcpy(dst, &v, sizeof v);
  }
}

static agc_list *list_alloc(size_t len, size_t tail, uint32_t kind) {
  /* tail <= LIST_WIDTH, so the size cannot overflow */
  agc_list *l = agc_alloc(sizeof(agc_list) + tail * stride_of(kind));
  l->len = len;
  l->kind = len ? kind : 0;
  return l;
}

static list_branch *branch_copy(const list_branch *src) {
  list_branch *b = agc_alloc(sizeof(list_branch));
  memcpy(b, src, sizeof(list_branch));
  return b;
}

static char *leaf_copy(uint32_t kind, const char *items, size_t count) {
  size_t stride = stride_of(kind);
  char *leaf = items_alloc(kind, LIST_WIDTH * stride);
  memcpy(leaf, items, count * stride);
  return leaf;
}

static list_branch *branch_chain(uint32_t shift, char *leaf) {
  void *node = leaf;
  for (uint32_t s = LIST_BITS; s <= shift; s += LIST_BITS) {
    list_branch *b = agc_alloc(sizeof(list_branch));
    b->child[0] = node;
    node = b;
  }
  return node;
}

static list_trie trie_add_leaf(list_branch *root, uint32_t shift, size_t off, char *leaf) {
  if (!root) {
    list_branch *top = agc_alloc(sizeof(list_branch));
    top->child[0] = leaf;
    return (list_trie){top, LIST_BITS};
  }
  if (off == (size_t)1 << (shift + LIST_BITS)) {
    list_branch *top = agc_alloc(sizeof(list_branch));
    top->child[0] = root;
    top->child[1] = branch_chain(shift, leaf);
    return (list_trie){top, shift + LIST_BITS};
  }
  list_branch *top = branch_copy(root);
  list_branch *dst = top;
  for (uint32_t s = shift; s > LIST_BITS; s -= LIST_BITS) {
    size_t slot = (off >> s) & LIST_MASK;
    list_branch *src = dst->child[slot];
    if (!src) {
      dst->child[slot] = branch_chain(s - LIST_BITS, leaf);
      return (list_trie){top, shift};
    }
    list_branch *copy = branch_copy(src);
    dst->child[slot] = copy;
    dst = copy;
  }
  dst->child[(off >> LIST_BITS) & LIST_MASK] = leaf;
  return (list_trie){top, shift};
}

static char *leaf_of(const agc_list *l, size_t k) {
  const list_branch *node = l->root;
  for (uint32_t s = l->shift; s > LIST_BITS; s -= LIST_BITS) node = node->child[((k << LIST_BITS) >> s) & LIST_MASK];
  return node->child[k & LIST_MASK];
}

/* The first `shared` leaves are leaves first, first + 1, ... of src, which has the same kind; the rest are slices of one new block of items. */
static char *trie_make(agc_list *l, size_t items, uint32_t kind, const agc_list *src, size_t first, size_t shared) {
  /* the bound of 16-byte items for every kind, checked before shift_for: a len above SIZE_MAX / 16 ends in the out-of-memory exit here (17.7) */
  (void)agc_size_mul(items, sizeof(agc_value));
  size_t leaf_bytes = LIST_WIDTH * stride_of(kind);
  size_t bytes = agc_size_mul((items >> LIST_BITS) - shared, leaf_bytes);
  list_branch *levels[MAX_LEVELS];
  size_t leaves = items >> LIST_BITS;
  uint32_t shift = shift_for(items);
  size_t depth = 0;
  size_t count = leaves;
  for (uint32_t s = LIST_BITS; s <= shift; s += LIST_BITS) {
    count = (count + LIST_MASK) >> LIST_BITS;
    levels[depth++] = agc_alloc(agc_size_mul(count, sizeof(list_branch)));
  }
  char *block = bytes ? items_alloc(kind, bytes) : NULL;
  for (size_t k = 0; k < leaves; k++)
    levels[0][k >> LIST_BITS].child[k & LIST_MASK] =
        k < shared ? (void *)leaf_of(src, first + k) : block + (k - shared) * leaf_bytes;
  count = leaves;
  for (size_t d = 1; d < depth; d++) {
    count = (count + LIST_MASK) >> LIST_BITS;
    for (size_t k = 0; k < count; k++) levels[d][k >> LIST_BITS].child[k & LIST_MASK] = levels[d - 1] + k;
  }
  l->root = levels[depth - 1];
  l->shift = shift;
  return block;
}

static const char *list_chunk(const agc_list *l, size_t i, size_t *start, size_t *end) {
  size_t off = list_tail_off(l->len);
  if (i >= off) {
    *start = off;
    *end = l->len;
    return (const char *)l->tail;
  }
  const list_branch *node = l->root;
  for (uint32_t s = l->shift; s > LIST_BITS; s -= LIST_BITS) node = node->child[(i >> s) & LIST_MASK];
  *start = i & ~(size_t)LIST_MASK;
  *end = *start + LIST_WIDTH;
  return node->child[(i >> LIST_BITS) & LIST_MASK];
}

static void builder_begin(agc_list_builder *b, size_t n, uint32_t kind, const agc_list *src, size_t first,
                          size_t shared) {
  size_t items = trie_items(n);
  size_t stride = stride_of(kind);
  agc_list *l = list_alloc(n, n - items, kind);
  char *block = items ? trie_make(l, items, kind, src, first, shared) : NULL;
  b->out = l;
  b->n = n;
  b->kind = kind;
  b->next = block ? block : (char *)l->tail;
  b->stop = block ? block + (items - shared * LIST_WIDTH) * stride : (char *)l->tail + (n - items) * stride;
  b->after = block ? (char *)l->tail : NULL;
}

static void builder_advance(agc_list_builder *b) {
  if (!b->after) abort();
  b->next = b->after;
  b->stop = b->after + (b->n - list_tail_off(b->n)) * stride_of(b->kind);
  b->after = NULL;
}

/* v has the builder's kind, or the builder is of agc_values */
static void builder_push(agc_list_builder *b, agc_value v) {
  if (b->next == b->stop) builder_advance(b);
  item_put(b->kind, b->next, v);
  b->next += stride_of(b->kind);
}

static void builder_put(agc_list_builder *b, const char *src, size_t bytes) {
  while (bytes) {
    if (b->next == b->stop) builder_advance(b);
    size_t room = (size_t)(b->stop - b->next);
    size_t part = room < bytes ? room : bytes;
    memcpy(b->next, src, part);
    b->next += part;
    src += part;
    bytes -= part;
  }
}

static void builder_copy(agc_list_builder *b, const agc_list *src, size_t from, size_t count) {
  size_t start, end;
  size_t stride = stride_of(src->kind);
  size_t stop = from + count;
  for (size_t i = from; i < stop; i = end) {
    const char *chunk = list_chunk(src, i, &start, &end);
    if (end > stop) end = stop;
    builder_put(b, chunk + (i - start) * stride, (end - i) * stride);
  }
}

static void builder_replay(agc_list_builder *wide, const agc_list *src, size_t count) {
  agc_list_cursor cursor;
  agc_value v;
  agc_list_cursor_begin(&cursor, src, 0);
  for (size_t k = 0; k < count && agc_list_cursor_next(&cursor, &v); k++) builder_push(wide, v);
}

/* The items written so far are the first `done` of the half-built list: the block, then the tail. */
static void builder_demote(agc_list_builder *b) {
  const agc_list *half = b->out;
  size_t done = b->after ? (size_t)(b->next - leaf_of(half, 0)) / sizeof(uint64_t)
                         : trie_items(b->n) + (size_t)(b->next - (char *)half->tail) / sizeof(uint64_t);
  agc_list_builder wide;
  builder_begin(&wide, b->n, 0, NULL, 0, 0);
  builder_replay(&wide, half, done);
  *b = wide;
}

static agc_list *list_wide(const agc_list *l) {
  agc_list_builder b;
  builder_begin(&b, l->len, 0, NULL, 0, 0);
  builder_replay(&b, l, l->len);
  return agc_list_builder_finish(&b);
}

static agc_list *join_small(const agc_list *a, const agc_list *b) {
  uint32_t kind = a->kind;
  size_t stride = stride_of(kind);
  size_t off = list_tail_off(a->len);
  size_t tail = a->len - off;
  size_t room = LIST_WIDTH - tail;
  size_t len = agc_size_add(a->len, b->len);
  if (b->len <= room) {
    agc_list *r = list_alloc(len, tail + b->len, kind);
    r->root = a->root;
    r->shift = a->shift;
    memcpy(r->tail, a->tail, tail * stride);
    memcpy((char *)r->tail + tail * stride, b->tail, b->len * stride);
    return r;
  }
  char *leaf = leaf_copy(kind, (const char *)a->tail, tail);
  memcpy(leaf + tail * stride, b->tail, room * stride);
  list_trie t = trie_add_leaf(a->root, a->shift, off, leaf);
  agc_list *r = list_alloc(len, b->len - room, kind);
  r->root = t.root;
  r->shift = t.shift;
  memcpy(r->tail, (const char *)b->tail + room * stride, (b->len - room) * stride);
  return r;
}

static agc_list *join_wide(const agc_list *a, const agc_list *b) {
  agc_list_builder out;
  builder_begin(&out, agc_size_add(a->len, b->len), 0, NULL, 0, 0);
  builder_replay(&out, a, a->len);
  builder_replay(&out, b, b->len);
  return agc_list_builder_finish(&out);
}

static void copy_reversed(char *dst, const char *end, size_t count, uint32_t kind) {
  const size_t word = sizeof(uint64_t), value = sizeof(agc_value);
  if (kind) {
    for (size_t k = 0; k < count; k++) memcpy(dst + k * word, end - (k + 1) * word, word);
  } else {
    for (size_t k = 0; k < count; k++) memcpy(dst + k * value, end - (k + 1) * value, value);
  }
}

agc_value agc_list_trie_get(const agc_list *l, size_t i) {
  const list_branch *node = l->root;
  for (uint32_t s = l->shift; s > LIST_BITS; s -= LIST_BITS) node = node->child[(i >> s) & LIST_MASK];
  return list_item(l->kind, node->child[(i >> LIST_BITS) & LIST_MASK], i & LIST_MASK);
}

size_t agc_list_len(const agc_list *l) { return list_len(l); }

agc_value agc_list_get(const agc_list *l, size_t i) { return list_get(l, i); }

uint32_t agc_list_kind(const agc_list *l) { return l->kind; }

void agc_list_builder_sized(agc_list_builder *b, size_t n) {
  *b = (agc_list_builder){.n = n};
  if (!n) builder_begin(b, 0, 0, NULL, 0, 0);
}

void agc_list_builder_more(agc_list_builder *b, agc_value v) {
  if (!b->out)
    builder_begin(b, b->n, kind_of(v), NULL, 0, 0);
  else if (b->kind && v.tag != b->kind)
    builder_demote(b);
  builder_push(b, v);
}

agc_list *agc_list_builder_finish(agc_list_builder *b) {
  if (!b->out || b->after || b->next != b->stop) abort();
  return b->out;
}

agc_list *agc_list_of_bytes(const uint8_t *data, size_t n) {
  agc_list_builder b;
  agc_list_builder_sized(&b, n);
  for (size_t k = 0; k < n; k++) agc_list_builder_push(&b, agc_int(data[k]));
  return agc_list_builder_finish(&b);
}

agc_list *agc_list_from_array(const agc_value *items, size_t n) {
  agc_list_builder b;
  uint32_t kind = n ? kind_of(items[0]) : 0;
  if (kind) {
    builder_begin(&b, n, kind, NULL, 0, 0);
    size_t k = 0;
    while (k < n && items[k].tag == kind) agc_list_builder_push(&b, items[k++]);
    if (k == n) return agc_list_builder_finish(&b);
  }
  builder_begin(&b, n, 0, NULL, 0, 0);
  builder_put(&b, (const char *)items, n * sizeof(agc_value));
  return agc_list_builder_finish(&b);
}

void agc_list_to_array(const agc_list *l, agc_value *out) {
  agc_list_cursor cursor;
  agc_list_cursor_begin(&cursor, l, 0);
  size_t k = 0;
  while (agc_list_cursor_next(&cursor, out + k)) k++;
}

void agc_list_cursor_begin(agc_list_cursor *c, const agc_list *l, size_t at) {
  if (at > l->len) abort();
  c->list = l;
  c->index = at;
  c->start = 0;
  c->end = 0;
  c->chunk = NULL;
  c->kind = l->kind;
}

bool agc_list_cursor_fill(agc_list_cursor *c) {
  if (c->index >= c->list->len) return false;
  c->chunk = list_chunk(c->list, c->index, &c->start, &c->end);
  return true;
}

agc_list *agc_list_append(const agc_list *l, agc_value v) {
  uint32_t kind = l->len ? l->kind : kind_of(v);
  if (kind && v.tag != kind) {
    l = list_wide(l);
    kind = 0;
  }
  size_t stride = stride_of(kind);
  size_t len = agc_size_add(l->len, 1);
  size_t off = trie_items(l->len);
  size_t tail = l->len - off;
  if (tail < LIST_WIDTH) {
    agc_list *r = list_alloc(len, tail + 1, kind);
    r->root = l->root;
    r->shift = l->shift;
    memcpy(r->tail, l->tail, tail * stride);
    item_put(kind, (char *)r->tail + tail * stride, v);
    return r;
  }
  list_trie t = trie_add_leaf(l->root, l->shift, off, leaf_copy(kind, (const char *)l->tail, LIST_WIDTH));
  agc_list *r = list_alloc(len, 1, kind);
  r->root = t.root;
  r->shift = t.shift;
  item_put(kind, (char *)r->tail, v);
  return r;
}

agc_list *agc_list_set(const agc_list *l, size_t i, agc_value v) {
  if (i >= l->len) abort();
  if (l->kind && v.tag != l->kind) l = list_wide(l);
  uint32_t kind = l->kind;
  size_t stride = stride_of(kind);
  size_t off = list_tail_off(l->len);
  size_t tail = l->len - off;
  agc_list *r = list_alloc(l->len, tail, kind);
  r->root = l->root;
  r->shift = l->shift;
  memcpy(r->tail, l->tail, tail * stride);
  if (i >= off) {
    item_put(kind, (char *)r->tail + (i - off) * stride, v);
    return r;
  }
  list_branch *dst = branch_copy(l->root);
  r->root = dst;
  for (uint32_t s = l->shift; s > LIST_BITS; s -= LIST_BITS) {
    size_t slot = (i >> s) & LIST_MASK;
    list_branch *copy = branch_copy(dst->child[slot]);
    dst->child[slot] = copy;
    dst = copy;
  }
  size_t slot = (i >> LIST_BITS) & LIST_MASK;
  char *leaf = leaf_copy(kind, dst->child[slot], LIST_WIDTH);
  item_put(kind, leaf + (i & LIST_MASK) * stride, v);
  dst->child[slot] = leaf;
  return r;
}

agc_list *agc_list_repeat(agc_value v, size_t n) {
  /* the bound trie_make has, checked before shift_for (17.7) */
  (void)agc_size_mul(n, sizeof(agc_value));
  uint32_t kind = kind_of(v);
  size_t stride = stride_of(kind);
  size_t items = trie_items(n);
  agc_list *l = list_alloc(n, n - items, kind);
  for (size_t k = 0; k < n - items; k++) item_put(kind, (char *)l->tail + k * stride, v);
  if (!items) return l;
  char *leaf = items_alloc(kind, LIST_WIDTH * stride);
  for (size_t k = 0; k < LIST_WIDTH; k++) item_put(kind, leaf + k * stride, v);
  uint32_t shift = shift_for(items);
  void *full = leaf;
  void *last = leaf;
  size_t count = items >> LIST_BITS;
  for (uint32_t s = LIST_BITS; s <= shift; s += LIST_BITS) {
    size_t used = ((count - 1) & LIST_MASK) + 1;
    list_branch *f = agc_alloc(sizeof(list_branch));
    list_branch *e = agc_alloc(sizeof(list_branch));
    for (size_t k = 0; k < LIST_WIDTH; k++) f->child[k] = full;
    for (size_t k = 0; k + 1 < used; k++) e->child[k] = full;
    e->child[used - 1] = last;
    full = f;
    last = e;
    count = (count + LIST_MASK) >> LIST_BITS;
  }
  l->root = last;
  l->shift = shift;
  return l;
}

agc_list *agc_list_slice(const agc_list *l, size_t from, size_t count) {
  if (from > l->len || count > l->len - from) abort();
  if (from == 0 && count == l->len) return (agc_list *)l;
  size_t off = trie_items(l->len);
  if (from == 0 && count > off) {
    agc_list *r = list_alloc(count, count - off, l->kind);
    r->root = l->root;
    r->shift = l->shift;
    memcpy(r->tail, l->tail, (count - off) * stride_of(l->kind));
    return r;
  }
  agc_list_builder b;
  size_t shared = (from & LIST_MASK) == 0 && count >= l->len / 2 ? trie_items(count) >> LIST_BITS : 0;
  builder_begin(&b, count, l->kind, l, from >> LIST_BITS, shared);
  builder_copy(&b, l, from + shared * LIST_WIDTH, count - shared * LIST_WIDTH);
  return agc_list_builder_finish(&b);
}

agc_list *agc_list_reverse(const agc_list *l) {
  agc_list_builder b;
  size_t start, end;
  size_t stride = stride_of(l->kind);
  builder_begin(&b, l->len, l->kind, NULL, 0, 0);
  for (size_t high = l->len; high > 0; high = start) {
    const char *chunk = list_chunk(l, high - 1, &start, &end);
    for (size_t i = high; i > start;) {
      if (b.next == b.stop) builder_advance(&b);
      size_t room = (size_t)(b.stop - b.next) / stride;
      size_t part = room < i - start ? room : i - start;
      copy_reversed(b.next, chunk + (i - start) * stride, part, l->kind);
      b.next += part * stride;
      i -= part;
    }
  }
  return agc_list_builder_finish(&b);
}

agc_list *agc_list_concat(const agc_list *a, const agc_list *b) {
  if (b->len == 0) return (agc_list *)a;
  if (a->len == 0) return (agc_list *)b;
  if (a->kind != b->kind) return join_wide(a, b);
  if (b->len <= LIST_WIDTH) return join_small(a, b);
  agc_list_builder out;
  size_t shared = trie_items(a->len) >> LIST_BITS;
  builder_begin(&out, agc_size_add(a->len, b->len), a->kind, a, 0, shared);
  builder_copy(&out, a, shared * LIST_WIDTH, a->len - shared * LIST_WIDTH);
  builder_copy(&out, b, 0, b->len);
  return agc_list_builder_finish(&out);
}
