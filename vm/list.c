#include "core.h"
#include "list_impl.h"

#include <stdlib.h>
#include <string.h>

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
  agc_list *l = agc_alloc(agc_size_add(sizeof(agc_list), agc_size_mul(tail, sizeof(agc_value))));
  l->len = len;
  return l;
}

static list_branch *branch_copy(const list_branch *src) {
  list_branch *b = agc_alloc(sizeof(list_branch));
  memcpy(b, src, sizeof(list_branch));
  return b;
}

static list_leaf *leaf_copy(const agc_value *items) {
  list_leaf *leaf = agc_alloc(sizeof(list_leaf));
  memcpy(leaf->item, items, sizeof(leaf->item));
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

static void builder_attach(agc_list *l, size_t i, list_leaf *leaf) {
  list_branch *node = l->root;
  for (uint32_t s = l->shift; s > LIST_BITS; s -= LIST_BITS) {
    size_t slot = (i >> s) & LIST_MASK;
    list_branch *next = node->child[slot];
    if (!next) {
      next = agc_alloc(sizeof(list_branch));
      node->child[slot] = next;
    }
    node = next;
  }
  node->child[(i >> LIST_BITS) & LIST_MASK] = leaf;
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
  list_leaf *leaf = leaf_copy(a->tail);
  memcpy(leaf->item + tail, b->tail, room * sizeof(agc_value));
  list_trie t = trie_add_leaf(a->root, a->shift, off, leaf);
  agc_list *r = list_alloc(len, b->len - room);
  r->root = t.root;
  r->shift = t.shift;
  memcpy(r->tail, b->tail + room, (b->len - room) * sizeof(agc_value));
  return r;
}

size_t agc_list_len(const agc_list *l) { return list_len(l); }

agc_value agc_list_get(const agc_list *l, size_t i) { return list_get(l, i); }

void agc_list_builder_sized(agc_list_builder *b, size_t n) {
  (void)agc_size_mul(n, sizeof(agc_value));
  size_t items = trie_items(n);
  agc_list *l = list_alloc(n, n - items);
  if (items) {
    l->root = agc_alloc(sizeof(list_branch));
    l->shift = shift_for(items);
  }
  b->out = l;
  b->count = 0;
  b->leaf = NULL;
}

void agc_list_builder_push(agc_list_builder *b, agc_value v) {
  agc_list *l = b->out;
  size_t i = b->count;
  if (i >= l->len) abort();
  b->count = i + 1;
  size_t off = list_tail_off(l->len);
  if (i >= off) {
    l->tail[i - off] = v;
    return;
  }
  list_leaf *leaf = b->leaf;
  if ((i & LIST_MASK) == 0) {
    leaf = agc_alloc(sizeof(list_leaf));
    b->leaf = leaf;
    builder_attach(l, i, leaf);
  }
  leaf->item[i & LIST_MASK] = v;
}

agc_list *agc_list_builder_finish(agc_list_builder *b) {
  if (b->count != b->out->len) abort();
  return b->out;
}

agc_list *agc_list_from_array(const agc_value *items, size_t n) {
  if (n <= LIST_WIDTH) {
    agc_list *l = list_alloc(n, n);
    if (n) memcpy(l->tail, items, n * sizeof(agc_value));
    return l;
  }
  agc_list_builder b;
  agc_list_builder_sized(&b, n);
  for (size_t k = 0; k < n; k++) agc_list_builder_push(&b, items[k]);
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
  list_trie t = trie_add_leaf(l->root, l->shift, off, leaf_copy(l->tail));
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
  list_leaf *leaf = leaf_copy(((const list_leaf *)dst->child[slot])->item);
  leaf->item[i & LIST_MASK] = v;
  dst->child[slot] = leaf;
  return r;
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
  agc_list_cursor c;
  agc_list_builder_sized(&b, count);
  agc_list_cursor_begin(&c, l, from);
  for (size_t k = 0; k < count; k++) {
    agc_value v;
    if (!agc_list_cursor_next(&c, &v)) abort();
    agc_list_builder_push(&b, v);
  }
  return agc_list_builder_finish(&b);
}

agc_list *agc_list_concat(const agc_list *a, const agc_list *b) {
  if (b->len == 0) return (agc_list *)a;
  if (a->len == 0) return (agc_list *)b;
  if (b->len <= LIST_WIDTH) return join_small(a, b);
  agc_list_builder out;
  agc_list_cursor c;
  agc_value v;
  agc_list_builder_sized(&out, agc_size_add(a->len, b->len));
  agc_list_cursor_begin(&c, a, 0);
  while (agc_list_cursor_next(&c, &v)) agc_list_builder_push(&out, v);
  agc_list_cursor_begin(&c, b, 0);
  while (agc_list_cursor_next(&c, &v)) agc_list_builder_push(&out, v);
  return agc_list_builder_finish(&out);
}
