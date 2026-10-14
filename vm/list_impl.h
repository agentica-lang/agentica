#ifndef AGC_LIST_IMPL_H
#define AGC_LIST_IMPL_H

#include <stdlib.h>

#include "value.h"

#define LIST_BITS 5
#define LIST_WIDTH AGC_LIST_WIDTH
#define LIST_MASK 31
_Static_assert(AGC_LIST_WIDTH == (1 << LIST_BITS) && LIST_MASK == LIST_WIDTH - 1, "list nodes are 32 wide");

typedef struct {
  void *child[LIST_WIDTH];
} list_branch;

typedef struct {
  agc_value item[LIST_WIDTH];
} list_leaf;

/* tail holds the last ((len - 1) & 31) + 1 items (none when len is 0); root is NULL exactly when len <= 32. */
struct agc_list {
  size_t len;
  list_branch *root;
  uint32_t shift;
  agc_value tail[];
};

static inline size_t list_len(const agc_list *l) { return l->len; }

static inline size_t list_tail_off(size_t len) { return (len - 1) & ~(size_t)LIST_MASK; }

static inline agc_value list_get(const agc_list *l, size_t i) {
  if (i >= l->len) abort();
  size_t off = list_tail_off(l->len);
  if (i >= off) return l->tail[i - off];
  const list_branch *node = l->root;
  for (uint32_t s = l->shift; s > LIST_BITS; s -= LIST_BITS) node = node->child[(i >> s) & LIST_MASK];
  return ((const list_leaf *)node->child[(i >> LIST_BITS) & LIST_MASK])->item[i & LIST_MASK];
}

#endif
