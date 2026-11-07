/*
 * Maps in C: the persistent 32-way HAMT behind Map and Set, hashed with SipHash-1-3 keyed by vm->rt->hash_key (an Int
 * key with a keyed bijection), with agc_map_put, get and delete (and their _hash variants for tests), agc_map_add_hash
 * (put that leaves a member alone, for Set), agc_map_keys in insertion order, agc_set_subset and the pair walk of ==
 * (agc_map_pairs). The order is a key list, newest first, where a delete leaves a dead cell instead of copying the
 * list. Core layer.
 * Design: docs/vm/05-values-execution-builtins.md §5.1.
 */
#include "core.h"

#include <stdlib.h>
#include <string.h>

#define HAMT_BITS 5u
#define HAMT_HASH_BITS 64u

#define SIPROUND                                                                                   \
  do {                                                                                             \
    v0 += v1;                                                                                      \
    v1 = rotl(v1, 13);                                                                             \
    v1 ^= v0;                                                                                      \
    v0 = rotl(v0, 32);                                                                             \
    v2 += v3;                                                                                      \
    v3 = rotl(v3, 16);                                                                             \
    v3 ^= v2;                                                                                      \
    v0 += v3;                                                                                      \
    v3 = rotl(v3, 21);                                                                             \
    v3 ^= v0;                                                                                      \
    v2 += v1;                                                                                      \
    v1 = rotl(v1, 17);                                                                             \
    v1 ^= v2;                                                                                      \
    v2 = rotl(v2, 32);                                                                             \
  } while (0)

/* A key with its value. seq is the key's insertion number, the one its key
   list cell carries. */
typedef struct {
  uint64_t hash, seq;
  agc_value key, value;
} hamt_leaf;

/* A node holds its leaves in slot order, then its child pointers in slot order,
   in one block: a child link costs 8 bytes, not a whole leaf, so the copy of a
   put's path stays small. datamap and nodemap mark the slots of the leaves and
   the children. A collision node (below the last hash bit) has both maps 0 and
   only leaves, whose keys share the full hash. */
struct agc_hamt {
  uint32_t datamap, nodemap, leaves, children;
  hamt_leaf leaf[];
};

static uint64_t rotl(uint64_t x, unsigned b) { return (x << b) | (x >> (64 - b)); }

static uint64_t siphash13(const uint64_t key[2], uint64_t domain, const uint8_t *in, size_t len) {
  uint64_t v0 = 0x736f6d6570736575ULL ^ key[0], v1 = 0x646f72616e646f6dULL ^ key[1];
  uint64_t v2 = 0x6c7967656e657261ULL ^ key[0], v3 = 0x7465646279746573ULL ^ key[1];
  v3 ^= domain;
  SIPROUND;
  v0 ^= domain;
  size_t full = len - len % 8;
  for (size_t i = 0; i < full; i += 8) {
    uint64_t m = 0;
    for (unsigned k = 0; k < 8; k++) m |= (uint64_t)in[i + k] << (8 * k);
    v3 ^= m;
    SIPROUND;
    v0 ^= m;
  }
  uint64_t b = (uint64_t)len << 56;
  for (size_t k = 0; k < len % 8; k++) b |= (uint64_t)in[full + k] << (8 * k);
  v3 ^= b;
  SIPROUND;
  v0 ^= b;
  v2 ^= 0xff;
  SIPROUND;
  SIPROUND;
  SIPROUND;
  return v0 ^ v1 ^ v2 ^ v3;
}

/* The hash of an Int key: the key XORed with the run's hash key, then the finalizer of MurmurHash3 (fmix64). Only the
   key before the mix matters: an XOR after it would rename the slots of every node in the same way, and the table
   would keep its shape, so there is none. Every step is a bijection of 64-bit words, so two different Ints never
   share a hash. The table only chains keys with the same full hash (a collision node), so no choice of Int keys,
   even one that knows the key, makes a lookup scan: the worst it can do is put keys at the last level, 13 nodes down
   (HAMT_HASH_BITS / HAMT_BITS + 1). SipHash stays for String and Bytes keys, whose full hashes can collide. */
static uint64_t int_hash(uint64_t key, uint64_t x) {
  x ^= key;
  x ^= x >> 33;
  x *= 0xff51afd7ed558ccdULL;
  x ^= x >> 33;
  x *= 0xc4ceb9fe1a85ec53ULL;
  return x ^ (x >> 33);
}

uint64_t agc_key_hash(agc_vm *vm, agc_value key) {
  if (agc_is(key, AGC_T_INT)) return int_hash(vm->rt->hash_key[0], (uint64_t)agc_as_int(vm, key));
  /* The tag is the domain, so a String and a Bytes of the same bytes hash apart. */
  if (agc_is(key, AGC_T_BYTES)) {
    const agc_bytes *b = agc_as_bytes(vm, key);
    agc_charge_bytes(vm, b->len);
    return siphash13(vm->rt->hash_key, (uint64_t)key.tag, b->data, b->len);
  }
  const agc_string *s = agc_as_string(vm, key);
  agc_charge_bytes(vm, s->bytes);
  return siphash13(vm->rt->hash_key, (uint64_t)key.tag, (const uint8_t *)s->data, s->bytes);
}

static inline bool key_equal(agc_vm *vm, agc_value a, agc_value b) {
  if (a.tag != b.tag) return false;
  if (agc_is(a, AGC_T_INT)) return agc_as_int(vm, a) == agc_as_int(vm, b);
  if (agc_is(a, AGC_T_STRING)) return agc_same_string(vm, agc_as_string(vm, a), agc_as_string(vm, b));
  return agc_same_bytes(vm, agc_as_bytes(vm, a), agc_as_bytes(vm, b));
}

static agc_hamt *const *kids(const agc_hamt *node) { return (agc_hamt *const *)(const void *)(node->leaf + node->leaves); }

static agc_hamt **kids_mut(agc_hamt *node) { return (agc_hamt **)(void *)(node->leaf + node->leaves); }

static size_t node_bytes(uint32_t leaves, uint32_t children) {
  return agc_size_add(sizeof(agc_hamt), agc_size_add(agc_size_mul(leaves, sizeof(hamt_leaf)), agc_size_mul(children, sizeof(agc_hamt *))));
}

static agc_hamt *new_node(uint32_t datamap, uint32_t nodemap, uint32_t leaves, uint32_t children) {
  agc_hamt *node = agc_alloc(node_bytes(leaves, children));
  node->datamap = datamap;
  node->nodemap = nodemap;
  node->leaves = leaves;
  node->children = children;
  return node;
}

static agc_hamt *copy_node(const agc_hamt *node) {
  size_t bytes = node_bytes(node->leaves, node->children);
  agc_hamt *copy = agc_alloc(bytes);
  memcpy(copy, node, bytes);
  return copy;
}

static uint32_t slot_of(uint64_t hash, unsigned shift) { return (uint32_t)(hash >> shift) & 31u; }

/* The set bits of X. Baseline x86-64 has no POPCNT, so __builtin_popcount there is a call into libgcc's
   __popcountdi2 (2.7% of maze-bfs); the bit count below is branch-free and inline. A build for a CPU with POPCNT
   (-mpopcnt, -march=native) and arm64 (cnt) keep the instruction. */
static inline uint32_t bit_count(uint32_t x) {
#if defined(__x86_64__) && !defined(__POPCNT__)
  x -= (x >> 1) & 0x55555555u;
  x = (x & 0x33333333u) + ((x >> 2) & 0x33333333u);
  x = (x + (x >> 4)) & 0x0f0f0f0fu;
  return (x * 0x01010101u) >> 24;
#else
  return (uint32_t)__builtin_popcount(x);
#endif
}

static uint32_t index_of(uint32_t bitmap, uint32_t bit) { return bit_count(bitmap & (bit - 1)); }

/* Copies the n items of src to dst with *add inserted at index at, or, when add
   is NULL, with the item at index at left out. */
static void splice_at(void *dst, const void *src, size_t n, size_t size, size_t at, const void *add) {
  char *d = dst;
  const char *s = src;
  memcpy(d, s, at * size);
  if (add) {
    memcpy(d + at * size, add, size);
    memcpy(d + (at + 1) * size, s + at * size, (n - at) * size);
  } else {
    memcpy(d + at * size, s + (at + 1) * size, (n - at - 1) * size);
  }
}

/* Copies one array of a node whose map goes from old_map to new_map, which
   differ at most in bit: the item of that slot comes in (add) or goes out. */
static void splice(void *dst, const void *src, uint32_t old_map, uint32_t new_map, uint32_t bit, size_t size, const void *add) {
  size_t n = bit_count(old_map);
  if (old_map == new_map) memcpy(dst, src, n * size);
  else splice_at(dst, src, n, size, index_of(old_map, bit), new_map & bit ? add : NULL);
}

/* node with the slot bit changed: the maps become datamap and nodemap, and leaf
   or child fills the slot when it comes in. */
static agc_hamt *reshape(const agc_hamt *node, uint32_t bit, uint32_t datamap, uint32_t nodemap, const hamt_leaf *leaf, agc_hamt *child) {
  agc_hamt *copy = new_node(datamap, nodemap, bit_count(datamap), bit_count(nodemap));
  splice(copy->leaf, node->leaf, node->datamap, datamap, bit, sizeof(hamt_leaf), leaf);
  splice(kids_mut(copy), kids(node), node->nodemap, nodemap, bit, sizeof(agc_hamt *), &child);
  return copy;
}

/* A collision node with *add appended, or without its leaf at (add NULL). */
static agc_hamt *collision_with(const agc_hamt *node, uint32_t at, const hamt_leaf *add) {
  agc_hamt *copy = new_node(0, 0, add ? node->leaves + 1 : node->leaves - 1, 0);
  splice_at(copy->leaf, node->leaf, node->leaves, sizeof(hamt_leaf), at, add);
  return copy;
}

static agc_hamt *pair_node(unsigned shift, const hamt_leaf *a, const hamt_leaf *b) { // NOLINT(misc-no-recursion)
  if (shift >= HAMT_HASH_BITS) {
    agc_hamt *node = new_node(0, 0, 2, 0);
    node->leaf[0] = *a;
    node->leaf[1] = *b;
    return node;
  }
  uint32_t sa = slot_of(a->hash, shift), sb = slot_of(b->hash, shift);
  if (sa == sb) {
    agc_hamt *node = new_node(0, 1u << sa, 0, 1);
    kids_mut(node)[0] = pair_node(shift + HAMT_BITS, a, b);
    return node;
  }
  agc_hamt *node = new_node((1u << sa) | (1u << sb), 0, 2, 0);
  node->leaf[sa < sb ? 0 : 1] = *a;
  node->leaf[sa < sb ? 1 : 0] = *b;
  return node;
}

/* Puts leaf under node and returns the new node. With keep, a key that is
   already in returns node itself, so nothing on the path is copied (Set.add of
   a member allocates nothing); *added tells the levels above that the key is
   new. A replaced value keeps the leaf's seq, and so its place in the order. */
static agc_hamt *put(agc_vm *vm, const agc_hamt *node, unsigned shift, const hamt_leaf *leaf, bool *added, bool keep) { // NOLINT(misc-no-recursion)
  if (shift >= HAMT_HASH_BITS) {
    for (uint32_t k = 0; k < node->leaves; k++) {
      if (key_equal(vm, node->leaf[k].key, leaf->key)) {
        if (keep) return (agc_hamt *)node;
        agc_hamt *copy = copy_node(node);
        copy->leaf[k].value = leaf->value;
        return copy;
      }
    }
    *added = true;
    return collision_with(node, node->leaves, leaf);
  }
  uint32_t bit = 1u << slot_of(leaf->hash, shift);
  if (node->datamap & bit) {
    uint32_t at = index_of(node->datamap, bit);
    const hamt_leaf *old = &node->leaf[at];
    if (old->hash == leaf->hash && key_equal(vm, old->key, leaf->key)) {
      if (keep) return (agc_hamt *)node;
      agc_hamt *copy = copy_node(node);
      copy->leaf[at].value = leaf->value;
      return copy;
    }
    *added = true;
    agc_hamt *child = pair_node(shift + HAMT_BITS, old, leaf);
    return reshape(node, bit, node->datamap & ~bit, node->nodemap | bit, NULL, child);
  }
  if (node->nodemap & bit) {
    uint32_t at = index_of(node->nodemap, bit);
    agc_hamt *child = put(vm, kids(node)[at], shift + HAMT_BITS, leaf, added, keep);
    if (keep && !*added) return (agc_hamt *)node;
    agc_hamt *copy = copy_node(node);
    kids_mut(copy)[at] = child;
    return copy;
  }
  *added = true;
  return reshape(node, bit, node->datamap | bit, node->nodemap, leaf, NULL);
}

agc_map *agc_new_map(void) { return agc_alloc(sizeof(agc_map)); }

static agc_map *map_with(agc_vm *vm, const agc_map *m, uint64_t hash, agc_value key, agc_value value, bool keep) {
  hamt_leaf leaf;
  memset(&leaf, 0, sizeof leaf);
  leaf.hash = hash;
  leaf.seq = m->next_seq;
  leaf.key = key;
  leaf.value = value;
  bool added = false;
  agc_hamt *table;
  if (m->table) {
    table = put(vm, m->table, 0, &leaf, &added, keep);
    if (keep && !added) return (agc_map *)m;
  } else {
    table = new_node(1u << slot_of(hash, 0), 0, 1, 0);
    table->leaf[0] = leaf;
    added = true;
  }
  agc_map *result = agc_new_map();
  result->table = table;
  result->size = added ? agc_size_add(m->size, 1) : m->size;
  result->dead = m->dead;
  result->dropped = m->dropped;
  result->reversed = m->reversed;
  result->next_seq = m->next_seq;
  if (added) {
    agc_keys *cell = agc_alloc(sizeof(agc_keys));
    cell->key = key;
    cell->next = m->reversed;
    cell->seq = m->next_seq;
    cell->hash = hash;
    result->reversed = cell;
    result->next_seq++;
  }
  return result;
}

agc_map *agc_map_put_hash(agc_vm *vm, const agc_map *m, uint64_t hash, agc_value key, agc_value value) {
  return map_with(vm, m, hash, key, value, false);
}

agc_map *agc_map_add_hash(agc_vm *vm, const agc_map *m, uint64_t hash, agc_value key, agc_value value) {
  return map_with(vm, m, hash, key, value, true);
}

agc_map *agc_map_put(agc_vm *vm, const agc_map *m, agc_value key, agc_value value) {
  return agc_map_put_hash(vm, m, agc_key_hash(vm, key), key, value);
}

/* The leaf of key, or NULL. */
static const hamt_leaf *find(agc_vm *vm, const agc_hamt *node, uint64_t hash, agc_value key) {
  for (unsigned shift = 0; node; shift += HAMT_BITS) {
    if (shift >= HAMT_HASH_BITS) {
      for (uint32_t k = 0; k < node->leaves; k++)
        if (key_equal(vm, node->leaf[k].key, key)) return &node->leaf[k];
      return NULL;
    }
    uint32_t bit = 1u << slot_of(hash, shift);
    if (node->datamap & bit) {
      const hamt_leaf *leaf = &node->leaf[index_of(node->datamap, bit)];
      return leaf->hash == hash && key_equal(vm, leaf->key, key) ? leaf : NULL;
    }
    if (!(node->nodemap & bit)) return NULL;
    node = kids(node)[index_of(node->nodemap, bit)];
  }
  return NULL;
}

static int by_falling_seq(const void *a, const void *b) {
  uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
  return x < y ? 1 : x > y ? -1 : 0;
}

/* The set of M's dead seqs, its memory from ALLOC; false when the dropped list does not match the map, which a valid
   map never does. */
static bool dead_set(const agc_map *m, agc_seq_set *set, void *(*alloc)(size_t size)) {
  memset(set, 0, sizeof *set);
  set->lo = m->next_seq;
  set->hi = m->next_seq;
  for (const agc_seqs *d = m->dropped; d; d = d->next) {
    if (set->n == m->dead || d->seq >= m->next_seq) return false;
    set->n++;
    if (d->seq < set->lo) set->lo = d->seq;
  }
  if (set->n != m->dead) return false;
  /* The bitmap takes no more words than an array of the seqs would. */
  if (set->hi - set->lo <= (uint64_t)set->n * 64) {
    size_t words = (size_t)((set->hi - set->lo) / 64 + 1);
    set->bits = alloc(agc_size_mul(words, sizeof(uint64_t)));
    memset(set->bits, 0, words * sizeof(uint64_t));
    for (const agc_seqs *d = m->dropped; d; d = d->next) {
      uint64_t at = d->seq - set->lo;
      set->bits[at / 64] |= (uint64_t)1 << (at % 64);
    }
    return true;
  }
  set->seqs = alloc(agc_size_mul(set->n, sizeof(uint64_t)));
  size_t k = 0;
  for (const agc_seqs *d = m->dropped; d; d = d->next) set->seqs[k++] = d->seq;
  qsort(set->seqs, set->n, sizeof(uint64_t), by_falling_seq);
  return true;
}

static void dead_begin(agc_vm *vm, const agc_map *m, agc_seq_set *set) {
  if (!dead_set(m, set, agc_alloc_atomic)) agc_fail(vm, "RUNTIME-INTERNAL", "map dead keys do not match", 0);
}

static void *heap_alloc(size_t size) {
  void *p = malloc(size ? size : 1);
  if (!p) agc_out_of_memory();
  return p;
}

/* Whether seq is in the set. Called with falling seqs, as the key list gives
   them. */
static bool seq_in(agc_seq_set *set, uint64_t seq) {
  if (set->bits) {
    if (seq < set->lo || seq >= set->hi) return false;
    uint64_t at = seq - set->lo;
    return (set->bits[at / 64] >> (at % 64)) & 1;
  }
  while (set->at < set->n && set->seqs[set->at] > seq) set->at++;
  return set->at < set->n && set->seqs[set->at] == seq;
}

bool agc_map_get_hash(agc_vm *vm, const agc_map *m, uint64_t hash, agc_value key, agc_value *value) {
  const hamt_leaf *leaf = find(vm, m->table, hash, key);
  if (leaf) *value = leaf->value;
  return leaf != NULL;
}

bool agc_map_get(agc_vm *vm, const agc_map *m, agc_value key, agc_value *value) {
  return agc_map_get_hash(vm, m, agc_key_hash(vm, key), key, value);
}

agc_value *agc_map_keys(agc_vm *vm, const agc_map *m, uint32_t span) {
  agc_value *keys = agc_alloc(agc_size_mul(m->size, sizeof(agc_value)));
  size_t k = m->size;
  if (m->dead == 0) {
    for (const agc_keys *cell = m->reversed; cell && k > 0; cell = cell->next) keys[--k] = cell->key;
  } else {
    agc_seq_set dead;
    dead_begin(vm, m, &dead);
    for (const agc_keys *cell = m->reversed; cell && k > 0; cell = cell->next)
      if (!seq_in(&dead, cell->seq)) keys[--k] = cell->key;
  }
  if (k != 0) agc_fail(vm, "RUNTIME-INTERNAL", "map key list does not match its table", span);
  return keys;
}

bool agc_map_keys_into(const agc_map *m, agc_value *keys) {
  agc_seq_set dead;
  if (m->dead && !dead_set(m, &dead, heap_alloc)) return false;
  size_t k = m->size;
  for (const agc_keys *cell = m->reversed; cell && k > 0; cell = cell->next)
    if (m->dead == 0 || !seq_in(&dead, cell->seq)) keys[--k] = cell->key;
  if (m->dead) {
    free(dead.bits);
    free(dead.seqs);
  }
  return k == 0;
}

/* Calls VISIT with every value of M, in table order, with no hash and no charge. A path from the root has at most
   HAMT_HASH_BITS / HAMT_BITS + 2 nodes (the last a collision node), so the walk keeps its path on a fixed stack: a
   node's leaves are visited when the walk enters it, then its children one by one. */
void agc_map_each_value(const agc_map *m, void (*visit)(agc_value value, void *data), void *data) {
  enum { PATH_MAX_NODES = HAMT_HASH_BITS / HAMT_BITS + 2 };
  const agc_hamt *nodes[PATH_MAX_NODES];
  uint32_t next[PATH_MAX_NODES];
  size_t depth = 0;
  const agc_hamt *enter = m->table;
  while (enter || depth) {
    if (enter) {
      if (depth == PATH_MAX_NODES) agc_internal_abort("map table deeper than its hash");
      for (uint32_t k = 0; k < enter->leaves; k++) visit(enter->leaf[k].value, data);
      nodes[depth] = enter;
      next[depth++] = 0;
      enter = NULL;
      continue;
    }
    const agc_hamt *node = nodes[depth - 1];
    if (next[depth - 1] == node->children)
      depth--;
    else
      enter = kids(node)[next[depth - 1]++];
  }
}

/* One value of M, the first leaf down the first children, with no hash and no charge; false for an empty map. A
   child is never empty, so the descent ends on a node with a leaf. */
bool agc_map_any_value(const agc_map *m, agc_value *out) {
  const agc_hamt *node = m->table;
  while (node && !node->leaves) node = node->children ? kids(node)[0] : NULL;
  if (!node) return false;
  *out = node->leaf[0].value;
  return true;
}

/* True when every element of a is in b. The key list is walked newest first
   because order does not matter here, and it needs no array. */
bool agc_set_subset(agc_vm *vm, const agc_map *a, const agc_map *b) {
  if (a->size > b->size) return false;
  agc_value present;
  agc_seq_set dead = {NULL, NULL, 0, 0, 0, 0};
  if (a->dead > 0) dead_begin(vm, a, &dead);
  for (const agc_keys *cell = a->reversed; cell; cell = cell->next)
    if ((a->dead == 0 || !seq_in(&dead, cell->seq)) && !agc_map_get_hash(vm, b, cell->hash, cell->key, &present))
      return false;
  return true;
}

/* Starts a walk over the live keys of a with their values in a and in b. The caller compares the sizes first. */
void agc_map_pairs_begin(agc_vm *vm, agc_map_pairs *walk, const agc_map *a, const agc_map *b) {
  memset(walk, 0, sizeof *walk);
  walk->a = a;
  walk->b = b;
  walk->cell = a->reversed;
  if (a->dead > 0) dead_begin(vm, a, &walk->dead);
}

/* The next live key of a, newest first: true with its value in a (left) and in b (right), or false at the end. A key
   that b lacks ends the walk at once with walk->missing set. The cached hash of the cell finds the key in both tables
   without hashing it again (no charge for a String key). */
bool agc_map_pairs_next(agc_vm *vm, agc_map_pairs *walk, agc_value *left, agc_value *right) {
  while (walk->cell) {
    const agc_keys *cell = walk->cell;
    walk->cell = cell->next;
    if (walk->a->dead > 0 && seq_in(&walk->dead, cell->seq)) continue;
    if (agc_map_get_hash(vm, walk->a, cell->hash, cell->key, left) &&
        agc_map_get_hash(vm, walk->b, cell->hash, cell->key, right))
      return true;
    walk->missing = true;
    walk->cell = NULL;
  }
  return false;
}

/* Removes key from under node: the new node, node itself when the key is not
   there (*removed stays false), or NULL when nothing is left. A child left
   with one leaf and no children is pulled up into its parent as a leaf, so
   every child holds at least two keys. */
static agc_hamt *take(agc_vm *vm, const agc_hamt *node, unsigned shift, uint64_t hash, agc_value key, bool *removed, uint64_t *seq) { // NOLINT(misc-no-recursion)
  if (shift >= HAMT_HASH_BITS) {
    for (uint32_t k = 0; k < node->leaves; k++) {
      if (key_equal(vm, node->leaf[k].key, key)) {
        *removed = true;
        *seq = node->leaf[k].seq;
        return node->leaves == 1 ? NULL : collision_with(node, k, NULL);
      }
    }
    return (agc_hamt *)node;
  }
  uint32_t bit = 1u << slot_of(hash, shift);
  if (node->datamap & bit) {
    const hamt_leaf *leaf = &node->leaf[index_of(node->datamap, bit)];
    if (leaf->hash != hash || !key_equal(vm, leaf->key, key)) return (agc_hamt *)node;
    *removed = true;
    *seq = leaf->seq;
    if (node->leaves + node->children == 1) return NULL;
    return reshape(node, bit, node->datamap & ~bit, node->nodemap, NULL, NULL);
  }
  if (!(node->nodemap & bit)) return (agc_hamt *)node;
  uint32_t at = index_of(node->nodemap, bit);
  agc_hamt *child = take(vm, kids(node)[at], shift + HAMT_BITS, hash, key, removed, seq);
  if (!*removed) return (agc_hamt *)node;
  if (!child) {
    if (node->leaves + node->children == 1) return NULL;
    return reshape(node, bit, node->datamap, node->nodemap & ~bit, NULL, NULL);
  }
  if (child->leaves == 1 && child->children == 0)
    return reshape(node, bit, node->datamap | bit, node->nodemap & ~bit, &child->leaf[0], NULL);
  agc_hamt *copy = copy_node(node);
  kids_mut(copy)[at] = child;
  return copy;
}

/* Rebuilds the key list of m without its dead cells, in one block. A delete
   only counts its cell as dead, so deletes cost O(log n); this pass runs once
   the dead cells outnumber the live ones, which keeps the list under twice
   the size. Only the block's first cell is pointed to from outside it. */
static void compact_keys(agc_vm *vm, agc_map *m) {
  /* The rebuild grows with the map: a persisted map at the threshold rebuilds on every derived delete. */
  agc_charge(vm, m->size + m->dead);
  agc_seq_set dead;
  dead_begin(vm, m, &dead);
  agc_keys *block = agc_alloc(agc_size_mul(m->size, sizeof(agc_keys)));
  size_t k = 0;
  for (const agc_keys *cell = m->reversed; cell && k < m->size; cell = cell->next) {
    if (seq_in(&dead, cell->seq)) continue;
    block[k] = *cell;
    block[k].next = k + 1 < m->size ? &block[k + 1] : NULL;
    k++;
  }
  if (k != m->size) agc_fail(vm, "RUNTIME-INTERNAL", "map key list does not match its table", 0);
  m->reversed = block;
  m->dropped = NULL;
  m->dead = 0;
}

agc_map *agc_map_delete_hash(agc_vm *vm, const agc_map *m, uint64_t hash, agc_value key) {
  bool removed = false;
  uint64_t seq = 0;
  agc_hamt *table = m->table ? take(vm, m->table, 0, hash, key, &removed, &seq) : NULL;
  if (!removed) return (agc_map *)m;
  if (m->size == 1) return agc_as_map(vm, vm->rt->empty_map);
  agc_map *result = agc_new_map();
  result->table = table;
  result->size = m->size - 1;
  result->dead = m->dead + 1;
  result->reversed = m->reversed;
  result->next_seq = m->next_seq;
  agc_seqs *dropped = agc_alloc(sizeof(agc_seqs));
  dropped->seq = seq;
  dropped->next = m->dropped;
  result->dropped = dropped;
  if (result->dead > result->size) compact_keys(vm, result);
  return result;
}

agc_map *agc_map_delete(agc_vm *vm, const agc_map *m, agc_value key) {
  return agc_map_delete_hash(vm, m, agc_key_hash(vm, key), key);
}
