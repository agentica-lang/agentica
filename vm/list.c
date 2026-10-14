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

static agc_list *list_alloc(size_t len, size_t tail) {
  /* tail <= LIST_WIDTH, so the size cannot overflow */
  agc_list *l = agc_alloc(sizeof(agc_list) + tail * sizeof(agc_value));
  l->len = len;
  return l;
}

static list_branch *branch_copy(const list_branch *src) {
  list_branch *b = agc_alloc(sizeof(list_branch));
  memcpy(b, src, sizeof(list_branch));
  return b;
}

static list_leaf *leaf_copy(const agc_value *items, size_t count) {
  list_leaf *leaf = agc_alloc(sizeof(list_leaf));
  memcpy(leaf->item, items, count * sizeof(agc_value));
  return leaf;
}

static list_branch *branch_chain(uint32_t shift, list_leaf *leaf) {
  void *node = leaf;
  for (uint32_t s = LIST_BITS; s <= shift; s += LIST_BITS) {
    list_branch *b = agc_alloc(sizeof(list_branch));
    b->child[0] = node;
    node = b;
  }
  return node;
}

static list_trie trie_add_leaf(list_branch *root, uint32_t shift, size_t off, list_leaf *leaf) {
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

static void *trie_make(agc_list *l, size_t items) {
  /* runs before shift_for: a len above SIZE_MAX / 16 ends in the out-of-memory exit here (17.7) */
  size_t bytes = agc_size_mul(items, sizeof(agc_value));
  list_branch *levels[MAX_LEVELS];
  size_t leaves = items >> LIST_BITS;
  uint32_t shift = shift_for(items);
  size_t depth = 0;
  size_t count = leaves;
  for (uint32_t s = LIST_BITS; s <= shift; s += LIST_BITS) {
    count = (count + LIST_MASK) >> LIST_BITS;
    levels[depth++] = agc_alloc(agc_size_mul(count, sizeof(list_branch)));
  }
  void *block = agc_alloc(bytes);
  char *nodes = block;
  size_t size = sizeof(list_leaf);
  count = leaves;
  for (size_t d = 0; d < depth; d++) {
    for (size_t k = 0; k < count; k++) levels[d][k >> LIST_BITS].child[k & LIST_MASK] = nodes + k * size;
    nodes = (char *)levels[d];
    size = sizeof(list_branch);
    count = (count + LIST_MASK) >> LIST_BITS;
  }
  l->root = levels[depth - 1];
  l->shift = shift;
  return block;
}

static const agc_value *list_chunk(const agc_list *l, size_t i, size_t *start, size_t *end) {
  size_t off = list_tail_off(l->len);
  if (i >= off) {
    *start = off;
    *end = l->len;
    return l->tail;
  }
  const list_branch *node = l->root;
  for (uint32_t s = l->shift; s > LIST_BITS; s -= LIST_BITS) node = node->child[(i >> s) & LIST_MASK];
  *start = i & ~(size_t)LIST_MASK;
  *end = *start + LIST_WIDTH;
  return ((const list_leaf *)node->child[(i >> LIST_BITS) & LIST_MASK])->item;
}

static agc_list *join_small(const agc_list *a, const agc_list *b) {
  size_t off = list_tail_off(a->len);
  size_t tail = a->len - off;
  size_t room = LIST_WIDTH - tail;
  size_t len = agc_size_add(a->len, b->len);
  if (b->len <= room) {
    agc_list *r = list_alloc(len, tail + b->len);
    r->root = a->root;
    r->shift = a->shift;
    memcpy(r->tail, a->tail, tail * sizeof(agc_value));
    memcpy(r->tail + tail, b->tail, b->len * sizeof(agc_value));
    return r;
  }
  list_leaf *leaf = leaf_copy(a->tail, tail);
  memcpy(leaf->item + tail, b->tail, room * sizeof(agc_value));
  list_trie t = trie_add_leaf(a->root, a->shift, off, leaf);
  agc_list *r = list_alloc(len, b->len - room);
  r->root = t.root;
  r->shift = t.shift;
  memcpy(r->tail, b->tail + room, (b->len - room) * sizeof(agc_value));
  return r;
}

agc_value agc_list_trie_get(const agc_list *l, size_t i) {
  const list_branch *node = l->root;
  for (uint32_t s = l->shift; s > LIST_BITS; s -= LIST_BITS) node = node->child[(i >> s) & LIST_MASK];
  return ((const list_leaf *)node->child[(i >> LIST_BITS) & LIST_MASK])->item[i & LIST_MASK];
}

size_t agc_list_len(const agc_list *l) { return list_len(l); }

agc_value agc_list_get(const agc_list *l, size_t i) { return list_get(l, i); }

static void builder_put(agc_list_builder *b, const agc_value *src, size_t n) {
  if (n == 0) return;
  agc_list *l = b->out;
  if (n > l->len - b->count) abort();
  size_t off = list_tail_off(l->len);
  size_t at = b->count;
  b->count = at + n;
  if (at < off) {
    size_t head = off - at < n ? off - at : n;
    memcpy((agc_value *)b->leaves + at, src, head * sizeof(agc_value));
    src += head;
    at += head;
    n -= head;
  }
  if (n) memcpy(l->tail + (at - off), src, n * sizeof(agc_value));
}

static void builder_copy(agc_list_builder *b, const agc_list *src, size_t from, size_t count) {
  size_t start, end;
  size_t stop = from + count;
  for (size_t i = from; i < stop; i = end) {
    const agc_value *chunk = list_chunk(src, i, &start, &end);
    if (end > stop) end = stop;
    builder_put(b, chunk + (i - start), end - i);
  }
}

void agc_list_builder_sized(agc_list_builder *b, size_t n) {
  size_t items = trie_items(n);
  b->out = list_alloc(n, n - items);
  b->count = 0;
  b->leaves = items ? trie_make(b->out, items) : NULL;
}

void agc_list_builder_push(agc_list_builder *b, agc_value v) {
  agc_list *l = b->out;
  size_t i = b->count;
  if (i >= l->len) abort();
  b->count = i + 1;
  size_t off = list_tail_off(l->len);
  if (i >= off)
    l->tail[i - off] = v;
  else
    ((agc_value *)b->leaves)[i] = v;
}

agc_list *agc_list_builder_finish(agc_list_builder *b) {
  if (b->count != b->out->len) abort();
  return b->out;
}

agc_list *agc_list_from_array(const agc_value *items, size_t n) {
  agc_list_builder b;
  agc_list_builder_sized(&b, n);
  builder_put(&b, items, n);
  return agc_list_builder_finish(&b);
}

void agc_list_to_array(const agc_list *l, agc_value *out) {
  size_t start, end;
  for (size_t i = 0; i < l->len; i = end) {
    const agc_value *chunk = list_chunk(l, i, &start, &end);
    memcpy(out + i, chunk + (i - start), (end - i) * sizeof(agc_value));
  }
}

void agc_list_cursor_begin(agc_list_cursor *c, const agc_list *l, size_t at) {
  if (at > l->len) abort();
  c->list = l;
  c->index = at;
  c->start = 0;
  c->end = 0;
  c->chunk = NULL;
}

bool agc_list_cursor_next(agc_list_cursor *c, agc_value *out) {
  if (c->index >= c->end) {
    if (c->index >= c->list->len) return false;
    c->chunk = list_chunk(c->list, c->index, &c->start, &c->end);
  }
  *out = c->chunk[c->index - c->start];
  c->index++;
  return true;
}

agc_list *agc_list_append(const agc_list *l, agc_value v) {
  size_t len = agc_size_add(l->len, 1);
  size_t off = trie_items(l->len);
  size_t tail = l->len - off;
  if (tail < LIST_WIDTH) {
    agc_list *r = list_alloc(len, tail + 1);
    r->root = l->root;
    r->shift = l->shift;
    memcpy(r->tail, l->tail, tail * sizeof(agc_value));
    r->tail[tail] = v;
    return r;
  }
  list_trie t = trie_add_leaf(l->root, l->shift, off, leaf_copy(l->tail, LIST_WIDTH));
  agc_list *r = list_alloc(len, 1);
  r->root = t.root;
  r->shift = t.shift;
  r->tail[0] = v;
  return r;
}

agc_list *agc_list_set(const agc_list *l, size_t i, agc_value v) {
  if (i >= l->len) abort();
  size_t off = list_tail_off(l->len);
  size_t tail = l->len - off;
  agc_list *r = list_alloc(l->len, tail);
  r->root = l->root;
  r->shift = l->shift;
  memcpy(r->tail, l->tail, tail * sizeof(agc_value));
  if (i >= off) {
    r->tail[i - off] = v;
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
  list_leaf *leaf = leaf_copy(((const list_leaf *)dst->child[slot])->item, LIST_WIDTH);
  leaf->item[i & LIST_MASK] = v;
  dst->child[slot] = leaf;
  return r;
}

agc_list *agc_list_repeat(agc_value v, size_t n) {
  size_t items = trie_items(n);
  agc_list *l = list_alloc(n, n - items);
  for (size_t k = 0; k < n - items; k++) l->tail[k] = v;
  if (!items) return l;
  list_leaf *leaf = agc_alloc(sizeof(list_leaf));
  for (size_t k = 0; k < LIST_WIDTH; k++) leaf->item[k] = v;
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
    agc_list *r = list_alloc(count, count - off);
    r->root = l->root;
    r->shift = l->shift;
    memcpy(r->tail, l->tail, (count - off) * sizeof(agc_value));
    return r;
  }
  agc_list_builder b;
  agc_list_builder_sized(&b, count);
  builder_copy(&b, l, from, count);
  return agc_list_builder_finish(&b);
}

agc_list *agc_list_reverse(const agc_list *l) {
  agc_list_builder b;
  size_t start, end;
  agc_list_builder_sized(&b, l->len);
  for (size_t high = l->len; high > 0; high = start) {
    const agc_value *chunk = list_chunk(l, high - 1, &start, &end);
    for (size_t i = high; i > start; i--) agc_list_builder_push(&b, chunk[i - 1 - start]);
  }
  return agc_list_builder_finish(&b);
}

agc_list *agc_list_concat(const agc_list *a, const agc_list *b) {
  if (b->len == 0) return (agc_list *)a;
  if (a->len == 0) return (agc_list *)b;
  if (b->len <= LIST_WIDTH) return join_small(a, b);
  agc_list_builder out;
  agc_list_builder_sized(&out, agc_size_add(a->len, b->len));
  builder_copy(&out, a, 0, a->len);
  builder_copy(&out, b, 0, b->len);
  return agc_list_builder_finish(&out);
}
