/*
 * ATS[K, V], the shared tables (docs/grammar/06c-tasks-and-tests.md, "Shared tables"): ATS.new, put, put_new, get,
 * has_key?, delete, clear, add, push, size, keys and to_map. A table is a hash table that keeps insertion order, as
 * CPython's dict does: an array of entries in the order they were put, and an index of slots that point into it.
 * A call takes the table's read-write lock (one of 64, by address, vm/sync.c), so readers run together and a write
 * is alone, and nothing raises or runs user code while it is held (docs/vm/10-io-multicore.md §10.2.3). Service
 * layer.
 */
#include "services.h"

#include <stdatomic.h>

/* What an index slot holds besides the number of an entry. */
#define EMPTY UINT32_MAX
#define DEAD (UINT32_MAX - 1)
#define MIN_SLOTS ((size_t)8)
/* More slots than this would need entry numbers that EMPTY and DEAD take. */
#define MAX_SLOTS ((size_t)1 << 31)

/* A deleted entry has a Void key, which no live one has, and stays in its place until the next rebuild. */
typedef struct {
  agc_value key, value;
  uint64_t hash;
} entry;

/* All but rt and size change only under the write lock. `slots` is a power of two (0 for a table never written or
   just cleared), `cap` two thirds of it, and `used` the entries filled, the deleted ones among them: an entry takes
   one slot for good, so at most `cap` slots are not EMPTY and a probe always ends. */
typedef struct {
  entry *entries;
  uint32_t *index;
  size_t slots, cap, used;
  /* Written under the write lock, read by ATS.size without one. */
  _Atomic int64_t size;
  /* The run that made the table: another run's call is RUNTIME-ATS-CONTEXT. One run is one execution on the VM, so no
     value reaches another today; the check guards any later way to pass values between them. */
  const agc_runtime *rt;
} table;

typedef enum { CHANGE_PUT, CHANGE_PUT_NEW, CHANGE_DELETE, CHANGE_ADD } change;

static agc_string *ascii(const char *text) {
  size_t n = strlen(text);
  return agc_make_string(text, n, n);
}

static table *table_arg(agc_vm *vm, agc_value v, uint32_t span) {
  table *t = agc_as_ats(vm, v);
  if (t->rt != vm->rt) agc_fail(vm, "RUNTIME-ATS-CONTEXT", "the table belongs to another run", span + 1);
  return t;
}

/* The slot of key's entry, or SIZE_MAX. Keys are Int, String or Bytes (agc_key_hash lets no other tag in). Typed code
   never mixes them in one table; forged bytecode may, and keys of different tags are never the same. */
static size_t lookup(const table *t, uint64_t hash, agc_value key) {
  if (!t->slots) return SIZE_MAX;
  size_t mask = t->slots - 1;
  for (size_t at = (size_t)hash & mask;; at = (at + 1) & mask) {
    uint32_t e = t->index[at];
    if (e == EMPTY) return SIZE_MAX;
    if (e != DEAD && t->entries[e].hash == hash && agc_key_same(t->entries[e].key, key)) return at;
  }
}

/* The entry of key, or NULL; *at gets its slot. */
static entry *entry_of(const table *t, uint64_t hash, agc_value key, size_t *at) {
  *at = lookup(t, hash, key);
  return *at == SIZE_MAX ? NULL : &t->entries[t->index[*at]];
}

/* Points the first EMPTY slot of hash's probe at entry number e. */
static void point(table *t, uint64_t hash, uint32_t e) {
  size_t mask = t->slots - 1, at = (size_t)hash & mask;
  while (t->index[at] != EMPTY) at = (at + 1) & mask;
  t->index[at] = e;
}

/* New arrays with the live entries in their order and room for as many again, so the rebuilds of a table cost O(1) a
   write on average, whether it grows or only replaces deleted keys. Returns the entries moved, which the caller
   charges once the lock is dropped. */
static size_t rebuild(table *t) {
  size_t live = (size_t)atomic_load_explicit(&t->size, memory_order_relaxed), slots = MIN_SLOTS;
  while (slots / 3 * 2 < live * 2 + 1) {
    if (slots == MAX_SLOTS) agc_out_of_memory();
    slots *= 2;
  }
  size_t cap = slots / 3 * 2;
  entry *entries = agc_alloc(agc_size_mul(cap, sizeof *entries));
  uint32_t *index = agc_alloc_atomic(agc_size_mul(slots, sizeof *index));
  memset(index, 0xff, slots * sizeof *index);
  size_t n = 0;
  for (size_t k = 0; k < t->used; k++)
    if (!agc_is(t->entries[k].key, AGC_T_VOID)) entries[n++] = t->entries[k];
  t->entries = entries;
  t->index = index;
  t->slots = slots;
  t->cap = cap;
  t->used = n;
  for (size_t k = 0; k < n; k++) point(t, entries[k].hash, (uint32_t)k);
  return n;
}

/* Adds an entry for a key the table does not hold. Returns the entries a rebuild moved. */
static size_t append(table *t, uint64_t hash, agc_value key, agc_value value) {
  size_t moved = t->used == t->cap ? rebuild(t) : 0;
  t->entries[t->used] = (entry){key, value, hash};
  point(t, hash, (uint32_t)t->used++);
  atomic_store_explicit(&t->size, atomic_load_explicit(&t->size, memory_order_relaxed) + 1, memory_order_relaxed);
  return moved;
}

/* Deletes the entry of slot `at`. A table left with an eighth of its entries gets smaller arrays. */
static size_t remove_at(table *t, size_t at) {
  entry *e = &t->entries[t->index[at]];
  e->key = e->value = agc_void();
  t->index[at] = DEAD;
  int64_t size = atomic_load_explicit(&t->size, memory_order_relaxed) - 1;
  atomic_store_explicit(&t->size, size, memory_order_relaxed);
  return (size_t)size * 8 <= t->cap && t->slots > MIN_SLOTS ? rebuild(t) : 0;
}

static agc_value builtin_new(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  table *t = agc_alloc(sizeof *t);
  atomic_init(&t->size, 0);
  t->rt = vm->rt;
  return agc_ats_value(t);
}

/* One write. Everything that can raise runs before the lock is taken or after it is dropped: the key's hash (a wrong
   tag), the amount of an add, and an add that overflows or finds a value that is not an Int, which leave the table as
   it was. */
static agc_value update(agc_vm *vm, agc_value *args, uint32_t span, change c) {
  table *t = table_arg(vm, args[0], span);
  agc_value key = args[1], result = agc_void(), bad = agc_int(0);
  uint64_t hash = agc_key_hash(vm, key);
  int64_t by = c == CHANGE_ADD ? agc_as_int(vm, args[2]) : 0, sum = 0;
  bool overflow = false;
  size_t moved = 0;
  agc_table_lock(vm->rt, t, true);
  size_t at = 0;
  entry *found = entry_of(t, hash, key, &at);
  switch (c) {
    case CHANGE_PUT:
      if (found) found->value = args[2];
      else moved = append(t, hash, key, args[2]);
      break;
    case CHANGE_PUT_NEW:
      result = agc_bool(!found);
      if (!found) moved = append(t, hash, key, args[2]);
      break;
    case CHANGE_DELETE:
      if (found) moved = remove_at(t, at);
      break;
    case CHANGE_ADD:
      if (found && !agc_is(found->value, AGC_T_INT)) {
        bad = found->value;
        break;
      }
      overflow = __builtin_add_overflow(found ? (int64_t)agc_value_word(found->value) : 0, by, &sum);
      if (overflow) break;
      result = agc_int(sum);
      if (found) found->value = result;
      else moved = append(t, hash, key, result);
      break;
  }
  agc_table_unlock(vm->rt, t, true);
  agc_charge(vm, moved);
  if (overflow) agc_fail(vm, "RUNTIME-INTEGER-OVERFLOW", "Int result is outside the 64-bit range", span);
  /* Only forged bytecode puts another value in a table it adds to: the accessor raises its wrong tag. */
  (void)agc_as_int(vm, bad);
  return result;
}

static agc_value builtin_put(agc_vm *vm, agc_value *args, uint32_t span) { return update(vm, args, span, CHANGE_PUT); }

static agc_value builtin_put_new(agc_vm *vm, agc_value *args, uint32_t span) {
  return update(vm, args, span, CHANGE_PUT_NEW);
}

static agc_value builtin_delete(agc_vm *vm, agc_value *args, uint32_t span) {
  return update(vm, args, span, CHANGE_DELETE);
}

static agc_value builtin_add(agc_vm *vm, agc_value *args, uint32_t span) { return update(vm, args, span, CHANGE_ADD); }

/* The arrays go to the collector whole, so the time does not grow with the table. */
static agc_value builtin_clear(agc_vm *vm, agc_value *args, uint32_t span) {
  table *t = table_arg(vm, args[0], span);
  agc_table_lock(vm->rt, t, true);
  t->entries = NULL;
  t->index = NULL;
  t->slots = t->cap = t->used = 0;
  atomic_store_explicit(&t->size, 0, memory_order_relaxed);
  agc_table_unlock(vm->rt, t, true);
  return agc_void();
}

/* Whether the table holds key, and its value in *value. */
static bool read_at(agc_vm *vm, table *t, uint64_t hash, agc_value key, agc_value *value) {
  agc_table_lock(vm->rt, t, false);
  size_t at = 0;
  const entry *found = entry_of(t, hash, key, &at);
  if (found) *value = found->value;
  agc_table_unlock(vm->rt, t, false);
  return found != NULL;
}

static bool read_key(agc_vm *vm, agc_value *args, uint32_t span, agc_value *value) {
  table *t = table_arg(vm, args[0], span);
  return read_at(vm, t, agc_key_hash(vm, args[1]), args[1], value);
}

/* Appending to a list allocates and, on a value that is not a List (forged bytecode), raises, so it runs with no
   lock: the call reads the list, builds the longer one, and stores it only if the key still holds the list it read
   (the same object: lists never change). Else another call came first and it starts again, which is charged. */
static agc_value builtin_push(agc_vm *vm, agc_value *args, uint32_t span) {
  table *t = table_arg(vm, args[0], span);
  agc_value key = args[1];
  uint64_t hash = agc_key_hash(vm, key);
  for (;;) {
    agc_value seen = agc_void();
    bool had = read_at(vm, t, hash, key, &seen);
    agc_list *next = had ? agc_list_append(agc_as_list(vm, seen), args[2]) : agc_list_from_array(&args[2], 1);
    size_t moved = 0;
    agc_table_lock(vm->rt, t, true);
    size_t at = 0;
    entry *found = entry_of(t, hash, key, &at);
    bool same = found ? had && found->value.tag == seen.tag && agc_value_word(found->value) == agc_value_word(seen)
                      : !had;
    if (same && found) found->value = agc_list_value(next);
    else if (same) moved = append(t, hash, key, agc_list_value(next));
    agc_table_unlock(vm->rt, t, true);
    agc_charge(vm, moved);
    if (same) return agc_int((int64_t)agc_list_len(next));
    agc_charge(vm, 1);
  }
}

static agc_value builtin_get(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_value value = agc_void();
  if (read_key(vm, args, span, &value)) return agc_result_value(true, value);
  agc_string *message = agc_concat(agc_concat(ascii("key "), agc_debug(vm, args[1])), ascii(" is not in the table"));
  return agc_error_string(vm, AGC_KIND_ERROR, message);
}

static agc_value builtin_has_key(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_value value = agc_void();
  return agc_bool(read_key(vm, args, span, &value));
}

static agc_value builtin_size(agc_vm *vm, agc_value *args, uint32_t span) {
  return agc_int(atomic_load_explicit(&table_arg(vm, args[0], span)->size, memory_order_relaxed));
}

/* A copy of the entries, the deleted ones among them, taken under the read lock; *n gets their count. The copy is
   allocated with no lock held, since an allocation can start a collection and the lock also holds back the writers
   of other tables: if the table grew past it meanwhile, a larger one is taken. The list or map is built from the copy
   with the lock dropped, so a large table holds back a writer only for the copy. */
static const entry *snapshot(agc_vm *vm, agc_value v, uint32_t span, size_t *n) {
  table *t = table_arg(vm, v, span);
  entry *copy = NULL;
  for (size_t room = 0;;) {
    agc_table_lock(vm->rt, t, false);
    size_t used = t->used;
    if (used <= room) {
      if (used) memcpy(copy, t->entries, used * sizeof *copy);
      agc_table_unlock(vm->rt, t, false);
      *n = used;
      agc_charge(vm, used);
      return copy;
    }
    agc_table_unlock(vm->rt, t, false);
    room = used;
    copy = agc_alloc(agc_size_mul(room, sizeof *copy));
    agc_charge(vm, 1);
  }
}

static agc_value builtin_keys(agc_vm *vm, agc_value *args, uint32_t span) {
  size_t n = 0;
  const entry *entries = snapshot(vm, args[0], span, &n);
  size_t live = 0;
  for (size_t k = 0; k < n; k++) live += !agc_is(entries[k].key, AGC_T_VOID);
  agc_list_builder b;
  agc_list_builder_sized(&b, live);
  for (size_t k = 0; k < n; k++)
    if (!agc_is(entries[k].key, AGC_T_VOID)) agc_list_builder_more(&b, entries[k].key);
  return agc_list_value(agc_list_builder_finish(&b));
}

static agc_value builtin_to_map(agc_vm *vm, agc_value *args, uint32_t span) {
  size_t n = 0;
  const entry *entries = snapshot(vm, args[0], span, &n);
  agc_map *map = agc_new_map();
  for (size_t k = 0; k < n; k++)
    if (!agc_is(entries[k].key, AGC_T_VOID))
      map = agc_map_put_hash(vm, map, entries[k].hash, entries[k].key, entries[k].value);
  return agc_map_value(map);
}

/* For the C test (vm/tests/ats_test.c), on a table no thread is writing: the counts agree, every live entry is found
   through the index at its own number, and every entry, live or deleted, holds exactly one slot. */
bool agc_ats_valid(agc_vm *vm, agc_value v) {
  const table *t = agc_as_ats(vm, v);
  size_t live = 0, taken = 0, dead = 0;
  if (t->used > t->cap || t->cap != t->slots / 3 * 2 || (t->slots & (t->slots - 1))) return false;
  for (size_t k = 0; k < t->used; k++) {
    const entry *e = &t->entries[k];
    if (agc_is(e->key, AGC_T_VOID)) continue;
    size_t at = lookup(t, e->hash, e->key);
    if (at == SIZE_MAX || t->index[at] != k) return false;
    live++;
  }
  for (size_t k = 0; k < t->slots; k++) {
    taken += t->index[k] != EMPTY;
    dead += t->index[k] == DEAD;
  }
  return (int64_t)live == atomic_load_explicit(&t->size, memory_order_relaxed) && taken == t->used &&
         dead == t->used - live;
}

/* No row is shared or a leaf: a call takes the table's own lock, not rt->sync, and it charges for String and Bytes
   keys, rebuilds and snapshots. */
const agc_builtin agc_ats_builtins[] = {
  {"ATS.new", 0, builtin_new, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"ATS.put", 3, builtin_put, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"ATS.put_new", 3, builtin_put_new, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"ATS.get", 2, builtin_get, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"ATS.has_key?", 2, builtin_has_key, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"ATS.delete", 2, builtin_delete, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"ATS.clear", 1, builtin_clear, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"ATS.add", 3, builtin_add, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"ATS.size", 1, builtin_size, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"ATS.keys", 1, builtin_keys, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"ATS.to_map", 1, builtin_to_map, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"ATS.push", 3, builtin_push, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
};

const size_t agc_ats_builtin_count = sizeof agc_ats_builtins / sizeof agc_ats_builtins[0];
