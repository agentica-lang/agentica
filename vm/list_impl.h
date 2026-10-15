/*
 * The private layout of a list: struct agc_list, the trie node type and the
 * inline length and read used by the hot loops. Only list.c, interp.c and
 * tests/list_test.c include it. Core header. Design: docs/vm/17-lists.md.
 */
#ifndef AGC_LIST_IMPL_H
#define AGC_LIST_IMPL_H

#include <stdlib.h>
#include <string.h>

#include "value.h"

#define LIST_BITS 5
#define LIST_WIDTH AGC_LIST_WIDTH
#define LIST_MASK 31
_Static_assert(AGC_LIST_WIDTH == (1 << LIST_BITS) && LIST_MASK == LIST_WIDTH - 1, "list nodes are 32 wide");

typedef struct {
  void *child[LIST_WIDTH];
} list_branch;

/*
 * kind is 0 when the items are agc_values, else AGC_T_INT or AGC_T_FLOAT when all of them
 * have that tag and each is stored as its 8 raw bytes (17.12); an empty list has kind 0. A
 * leaf is 32 items of that kind. tail holds the last ((len - 1) & 31) + 1 items (none when
 * len is 0); root is NULL exactly when len <= 32.
 */
struct agc_list {
  size_t len;
  list_branch *root;
  uint32_t shift;
  uint32_t kind;
  agc_value tail[];
};

static inline size_t list_len(const agc_list *l) { return l->len; }

static inline size_t list_tail_off(size_t len) { return (len - 1) & ~(size_t)LIST_MASK; }

static inline agc_value list_item(uint32_t kind, const char *items, size_t k) {
  uint64_t image[2];
  if (kind) {
    image[0] = kind;
    memcpy(&image[1], items + k * sizeof image[1], sizeof image[1]);
  } else {
    memcpy(image, items + k * sizeof(agc_value), sizeof image);
  }
  agc_value v;
  memcpy(&v, image, sizeof v);
  return v;
}

agc_value agc_list_trie_get(const agc_list *l, size_t i);

static inline agc_value list_at(const agc_list *l, size_t i) {
  size_t off = list_tail_off(l->len);
  if (i >= off) return list_item(l->kind, (const char *)l->tail, i - off);
  return agc_list_trie_get(l, i);
}

static inline agc_value list_get(const agc_list *l, size_t i) {
  if (i >= l->len) abort();
  return list_at(l, i);
}

#endif
