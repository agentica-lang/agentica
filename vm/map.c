#include "core.h"

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

typedef struct {
  agc_hamt *child;
  uint64_t hash;
  agc_value key, value;
} hamt_entry;

struct agc_hamt {
  uint32_t bitmap, n;
  hamt_entry entries[];
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

uint64_t agc_key_hash(agc_vm *vm, agc_value key) {
  if (agc_is(key, AGC_T_INT)) {
    uint64_t x = (uint64_t)agc_as_int(vm, key);
    uint8_t bytes[8];
    for (unsigned k = 0; k < 8; k++) bytes[k] = (uint8_t)(x >> (8 * k));
    return siphash13(vm->rt->hash_key, (uint64_t)key.tag, bytes, sizeof bytes);
  }
  const agc_string *s = agc_as_string(vm, key);
  agc_charge_bytes(vm, s->bytes);
  return siphash13(vm->rt->hash_key, (uint64_t)key.tag, (const uint8_t *)s->data, s->bytes);
}

static bool key_equal(agc_vm *vm, agc_value a, agc_value b) {
  if (a.tag != b.tag) return false;
  if (agc_is(a, AGC_T_INT)) return agc_as_int(vm, a) == agc_as_int(vm, b);
  return agc_same_string(vm, agc_as_string(vm, a), agc_as_string(vm, b));
}

static agc_hamt *new_node(uint32_t bitmap, uint32_t n) {
  agc_hamt *node = agc_alloc(agc_size_add(sizeof(agc_hamt), agc_size_mul(n, sizeof(hamt_entry))));
  node->bitmap = bitmap;
  node->n = n;
  return node;
}

static uint32_t slot_of(uint64_t hash, unsigned shift) { return (uint32_t)(hash >> shift) & 31u; }

static uint32_t index_of(uint32_t bitmap, uint32_t bit) { return (uint32_t)__builtin_popcount(bitmap & (bit - 1)); }

static agc_hamt *pair_node(unsigned shift, const hamt_entry *a, const hamt_entry *b) { // NOLINT(misc-no-recursion)
  if (shift >= HAMT_HASH_BITS) {
    agc_hamt *node = new_node(0, 2);
    node->entries[0] = *a;
    node->entries[1] = *b;
    return node;
  }
  uint32_t sa = slot_of(a->hash, shift), sb = slot_of(b->hash, shift);
  if (sa == sb) {
    agc_hamt *node = new_node(1u << sa, 1);
    node->entries[0].child = pair_node(shift + HAMT_BITS, a, b);
    return node;
  }
  agc_hamt *node = new_node((1u << sa) | (1u << sb), 2);
  node->entries[sa < sb ? 0 : 1] = *a;
  node->entries[sa < sb ? 1 : 0] = *b;
  return node;
}

static agc_hamt *copy_node(const agc_hamt *node, uint32_t bitmap, uint32_t n) {
  agc_hamt *copy = new_node(bitmap, n);
  memcpy(copy->entries, node->entries, (size_t)(n < node->n ? n : node->n) * sizeof(hamt_entry));
  return copy;
}

static agc_hamt *insert_at(const agc_hamt *node, uint32_t bitmap, uint32_t at, const hamt_entry *leaf) {
  agc_hamt *copy = new_node(bitmap, node->n + 1);
  memcpy(copy->entries, node->entries, (size_t)at * sizeof(hamt_entry));
  copy->entries[at] = *leaf;
  memcpy(copy->entries + at + 1, node->entries + at, (size_t)(node->n - at) * sizeof(hamt_entry));
  return copy;
}

static agc_hamt *put(agc_vm *vm, const agc_hamt *node, unsigned shift, const hamt_entry *leaf, bool *added) { // NOLINT(misc-no-recursion)
  if (shift >= HAMT_HASH_BITS) {
    for (uint32_t k = 0; k < node->n; k++) {
      if (key_equal(vm, node->entries[k].key, leaf->key)) {
        agc_hamt *copy = copy_node(node, 0, node->n);
        copy->entries[k].value = leaf->value;
        return copy;
      }
    }
    *added = true;
    return insert_at(node, 0, node->n, leaf);
  }
  uint32_t bit = 1u << slot_of(leaf->hash, shift);
  uint32_t at = index_of(node->bitmap, bit);
  if (!(node->bitmap & bit)) {
    *added = true;
    return insert_at(node, node->bitmap | bit, at, leaf);
  }
  const hamt_entry *entry = &node->entries[at];
  hamt_entry replacement = *entry;
  if (entry->child) {
    replacement.child = put(vm, entry->child, shift + HAMT_BITS, leaf, added);
  } else if (entry->hash == leaf->hash && key_equal(vm, entry->key, leaf->key)) {
    replacement.value = leaf->value;
  } else {
    memset(&replacement, 0, sizeof replacement);
    replacement.child = pair_node(shift + HAMT_BITS, entry, leaf);
    *added = true;
  }
  agc_hamt *copy = copy_node(node, node->bitmap, node->n);
  copy->entries[at] = replacement;
  return copy;
}

agc_map *agc_new_map(void) { return agc_alloc(sizeof(agc_map)); }

agc_map *agc_map_put_hash(agc_vm *vm, const agc_map *m, uint64_t hash, agc_value key, agc_value value) {
  hamt_entry leaf;
  memset(&leaf, 0, sizeof leaf);
  leaf.hash = hash;
  leaf.key = key;
  leaf.value = value;
  bool added = false;
  agc_map *result = agc_new_map();
  if (m->table) {
    result->table = put(vm, m->table, 0, &leaf, &added);
  } else {
    result->table = new_node(1u << slot_of(hash, 0), 1);
    result->table->entries[0] = leaf;
    added = true;
  }
  result->size = added ? agc_size_add(m->size, 1) : m->size;
  result->reversed = m->reversed;
  if (added) {
    agc_keys *cell = agc_alloc(sizeof(agc_keys));
    cell->key = key;
    cell->next = m->reversed;
    result->reversed = cell;
  }
  return result;
}

agc_map *agc_map_put(agc_vm *vm, const agc_map *m, agc_value key, agc_value value) {
  return agc_map_put_hash(vm, m, agc_key_hash(vm, key), key, value);
}

bool agc_map_get_hash(agc_vm *vm, const agc_map *m, uint64_t hash, agc_value key, agc_value *value) {
  const agc_hamt *node = m->table;
  for (unsigned shift = 0; node; shift += HAMT_BITS) {
    if (shift >= HAMT_HASH_BITS) {
      for (uint32_t k = 0; k < node->n; k++) {
        if (key_equal(vm, node->entries[k].key, key)) {
          *value = node->entries[k].value;
          return true;
        }
      }
      return false;
    }
    uint32_t bit = 1u << slot_of(hash, shift);
    if (!(node->bitmap & bit)) return false;
    const hamt_entry *entry = &node->entries[index_of(node->bitmap, bit)];
    if (entry->child) {
      node = entry->child;
      continue;
    }
    if (entry->hash != hash || !key_equal(vm, entry->key, key)) return false;
    *value = entry->value;
    return true;
  }
  return false;
}

bool agc_map_get(agc_vm *vm, const agc_map *m, agc_value key, agc_value *value) {
  return agc_map_get_hash(vm, m, agc_key_hash(vm, key), key, value);
}

agc_value *agc_map_keys(agc_vm *vm, const agc_map *m, uint32_t span) {
  agc_value *keys = agc_alloc(agc_size_mul(m->size, sizeof(agc_value)));
  size_t k = m->size;
  for (const agc_keys *cell = m->reversed; cell && k > 0; cell = cell->next) keys[--k] = cell->key;
  if (k != 0) agc_fail(vm, "RUNTIME-INTERNAL", "map key list does not match its table", span);
  return keys;
}

static agc_hamt *remove_at(const agc_hamt *node, uint32_t bitmap, uint32_t at) {
  agc_hamt *copy = new_node(bitmap, node->n - 1);
  memcpy(copy->entries, node->entries, (size_t)at * sizeof(hamt_entry));
  memcpy(copy->entries + at, node->entries + at + 1, (size_t)(node->n - at - 1) * sizeof(hamt_entry));
  return copy;
}

static agc_hamt *take(agc_vm *vm, agc_hamt *node, unsigned shift, uint64_t hash, agc_value key, bool *removed) { // NOLINT(misc-no-recursion)
  if (shift >= HAMT_HASH_BITS) {
    for (uint32_t k = 0; k < node->n; k++) {
      if (key_equal(vm, node->entries[k].key, key)) {
        *removed = true;
        return node->n == 1 ? NULL : remove_at(node, 0, k);
      }
    }
    return node;
  }
  uint32_t bit = 1u << slot_of(hash, shift);
  if (!(node->bitmap & bit)) return node;
  uint32_t at = index_of(node->bitmap, bit);
  const hamt_entry *entry = &node->entries[at];
  if (entry->child) {
    agc_hamt *child = take(vm, entry->child, shift + HAMT_BITS, hash, key, removed);
    if (!*removed) return node;
    if (!child) return node->n == 1 ? NULL : remove_at(node, node->bitmap & ~bit, at);
    agc_hamt *copy = copy_node(node, node->bitmap, node->n);
    if (child->n == 1 && !child->entries[0].child) copy->entries[at] = child->entries[0];
    else copy->entries[at].child = child;
    return copy;
  }
  if (entry->hash != hash || !key_equal(vm, entry->key, key)) return node;
  *removed = true;
  return node->n == 1 ? NULL : remove_at(node, node->bitmap & ~bit, at);
}

agc_map *agc_map_delete_hash(agc_vm *vm, const agc_map *m, uint64_t hash, agc_value key) {
  bool removed = false;
  agc_hamt *table = m->table ? take(vm, m->table, 0, hash, key, &removed) : NULL;
  if (!removed) return (agc_map *)m;
  agc_map *result = agc_new_map();
  result->table = table;
  result->size = m->size - 1;
  agc_keys **tail = &result->reversed;
  for (const agc_keys *cell = m->reversed; cell; cell = cell->next) {
    if (key_equal(vm, cell->key, key)) {
      *tail = cell->next;
      break;
    }
    agc_keys *copy = agc_alloc(sizeof(agc_keys));
    copy->key = cell->key;
    *tail = copy;
    tail = &copy->next;
  }
  return result;
}

agc_map *agc_map_delete(agc_vm *vm, const agc_map *m, agc_value key) {
  return agc_map_delete_hash(vm, m, agc_key_hash(vm, key), key);
}
