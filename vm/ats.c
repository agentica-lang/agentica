/*
 * ATS[K, V], the shared tables (docs/grammar/06c-tasks-and-tests.md, "Shared tables"): ATS.new, put, put_new, get,
 * has_key?, delete, clear, add, push, size, keys and to_map. A table is a hash table that keeps insertion order, as
 * CPython's dict does: an array of entries in the order they were put, and an index of slots that point into it.
 * A write takes the table's read-write lock (one of 64, by address, vm/sync.c), and nothing raises or runs user code
 * while it is held (docs/vm/10-io-multicore.md §10.2.3). A read takes no lock and writes no shared memory: it checks
 * a sequence number that writes change around them, and tries again (read_at). Service layer.
 */
#include "services.h"

#include <stdatomic.h>

/* What an index slot holds besides the number of an entry. */
#define EMPTY UINT32_MAX
#define DEAD (UINT32_MAX - 1)
#define MIN_SLOTS ((size_t)8)
/* More slots than this would need entry numbers that EMPTY and DEAD take. */
#define MAX_SLOTS ((size_t)1 << 31)
/* The tries of a read without the lock before it takes the read lock, so a reader gets through a stream of writes. */
#define READ_TRIES 8

/* A key or a value is two atomic words, its tag and its payload. A reader without the lock may load them from two
   writes, a torn value that it throws away (read_at). A deleted entry has a Void key tag, which no live one has, and
   stays in its place until the next rebuild. */
typedef struct {
  _Atomic uint64_t hash, key, value;
  _Atomic uint32_t key_tag, value_tag;
} entry;

/* The arrays of a table, in one object that a rebuild or a clear replaces whole and never changes again: a reader that
   loaded it keeps it alive for the collector. `slots` is a power of two and `cap` two thirds of it; `index` points
   past the `cap` entries, at the `slots` index slots. */
typedef struct {
  size_t slots, cap;
  _Atomic uint32_t *index;
  entry entries[];
} block;

/* A write takes the write lock and makes `seq` odd while it changes the table; a read takes no lock (read_at). The
   entries filled, the deleted ones among them, are `used`, which only writers touch: an entry takes one slot for good,
   so at most `cap` slots are not EMPTY and a probe always ends. */
typedef struct {
  /* NULL for a table never written or just cleared. */
  _Atomic(block *) block;
  _Atomic uint64_t seq;
  size_t used;
  /* Written under the write lock, read by ATS.size without one. */
  _Atomic int64_t size;
  /* The run that made the table: another run's call is RUNTIME-ATS-CONTEXT. One run is one execution on the VM, so no
     value reaches another today; the check guards any later way to pass values between them. */
  const agc_runtime *rt;
} table;

/* What ATS.keys and ATS.to_map copy out of an entry. */
typedef struct {
  agc_value key, value;
  uint64_t hash;
} item;

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

/* The payload first: a reader that loads a new key tag (acquire) also sees its payload. */
static void store(_Atomic uint32_t *tag, _Atomic uint64_t *word, agc_value v) {
  atomic_store_explicit(word, agc_value_word(v), memory_order_release);
  atomic_store_explicit(tag, v.tag, memory_order_release);
}

static agc_value load(const _Atomic uint32_t *tag, const _Atomic uint64_t *word) {
  uint32_t t = atomic_load_explicit(tag, memory_order_acquire);
  return agc_word_value(t, atomic_load_explicit(word, memory_order_acquire));
}

static agc_value key_of(const entry *e) { return load(&e->key_tag, &e->key); }

static agc_value value_of(const entry *e) { return load(&e->value_tag, &e->value); }

/* The entry of key, or NULL; *at, unless NULL, gets its slot. Keys are Int, String or Bytes (agc_key_hash lets no
   other tag in). Typed code never mixes them in one table; forged bytecode may, and keys of different tags are never
   the same. A reader without the lock may run it while a writer changes b. A slot only goes from EMPTY to an entry to
   DEAD, so a slot the probe saw taken stays taken, and at most `cap` of them ever are: the probe meets an EMPTY slot
   within one turn of the index. The entry is filled before its slot points at it, and a delete changes only the
   key's tag, so the key it compares is whole. */
static entry *lookup(block *b, uint64_t hash, agc_value key, size_t *at) {
  if (!b) return NULL;
  size_t mask = b->slots - 1, slot = (size_t)hash & mask;
  _Atomic uint32_t *index = b->index;
  for (;; slot = (slot + 1) & mask) {
    uint32_t e = atomic_load_explicit(&index[slot], memory_order_acquire);
    if (e == EMPTY) return NULL;
    if (e == DEAD) continue;
    entry *found = &b->entries[e];
    if (atomic_load_explicit(&found->hash, memory_order_acquire) == hash && agc_key_same(key_of(found), key)) {
      if (at) *at = slot;
      return found;
    }
  }
}

/* lookup for a writer, which holds the write lock. */
static entry *lookup_held(table *t, uint64_t hash, agc_value key, size_t *at) {
  return lookup(atomic_load_explicit(&t->block, memory_order_relaxed), hash, key, at);
}

/* Points the first EMPTY slot of hash's probe at entry number e. */
static inline void point(block *b, uint64_t hash, uint32_t e) {
  _Atomic uint32_t *index = b->index;
  size_t mask = b->slots - 1, at = (size_t)hash & mask;
  while (atomic_load_explicit(&index[at], memory_order_relaxed) != EMPTY) at = (at + 1) & mask;
  atomic_store_explicit(&index[at], e, memory_order_release);
}

/* A reader that finds `seq` as it was before its lookup saw no write in between: a writer's stores are releases after
   it made `seq` odd, so a reader that loads one of them (acquire) then loads the odd `seq` or a later one. */
static void write_begin(table *t) {
  atomic_store_explicit(&t->seq, atomic_load_explicit(&t->seq, memory_order_relaxed) + 1, memory_order_relaxed);
}

static void write_end(table *t) {
  atomic_store_explicit(&t->seq, atomic_load_explicit(&t->seq, memory_order_relaxed) + 1, memory_order_release);
}

/* A new block with the live entries in their order and room for as many again, so the rebuilds of a table cost O(1) a
   write on average, whether it grows or only replaces deleted keys. It is filled before it is published, and the old
   one stays as it was for the readers still in it. Returns the entries moved, which the caller charges once the lock
   is dropped. */
static size_t rebuild(table *t) {
  size_t live = (size_t)atomic_load_explicit(&t->size, memory_order_relaxed), slots = MIN_SLOTS;
  while (slots / 3 * 2 < live * 2 + 1) {
    if (slots == MAX_SLOTS) agc_out_of_memory();
    slots *= 2;
  }
  size_t cap = slots / 3 * 2;
  size_t bytes = agc_size_add(agc_size_mul(cap, sizeof(entry)), agc_size_mul(slots, sizeof(uint32_t)));
  block *b = agc_alloc(agc_size_add(sizeof *b, bytes));
  b->slots = slots;
  b->cap = cap;
  b->index = (_Atomic uint32_t *)(void *)&b->entries[cap];
  memset(b->index, 0xff, slots * sizeof *b->index);
  const block *old = atomic_load_explicit(&t->block, memory_order_relaxed);
  size_t n = 0;
  for (size_t k = 0; k < t->used; k++) {
    const entry *from = &old->entries[k];
    if (atomic_load_explicit(&from->key_tag, memory_order_relaxed) == AGC_T_VOID) continue;
    entry *to = &b->entries[n];
    uint64_t hash = atomic_load_explicit(&from->hash, memory_order_relaxed);
    atomic_store_explicit(&to->hash, hash, memory_order_relaxed);
    store(&to->key_tag, &to->key, key_of(from));
    store(&to->value_tag, &to->value, value_of(from));
    point(b, hash, (uint32_t)n++);
  }
  atomic_store_explicit(&t->block, b, memory_order_release);
  t->used = n;
  return n;
}

/* Adds an entry for a key the table does not hold. Returns the entries a rebuild moved. */
static size_t append(table *t, uint64_t hash, agc_value key, agc_value value) {
  block *b = atomic_load_explicit(&t->block, memory_order_relaxed);
  size_t moved = 0;
  if (!b || t->used == b->cap) {
    moved = rebuild(t);
    b = atomic_load_explicit(&t->block, memory_order_relaxed);
  }
  entry *e = &b->entries[t->used];
  atomic_store_explicit(&e->hash, hash, memory_order_release);
  store(&e->value_tag, &e->value, value);
  store(&e->key_tag, &e->key, key);
  point(b, hash, (uint32_t)t->used++);
  atomic_store_explicit(&t->size, atomic_load_explicit(&t->size, memory_order_relaxed) + 1, memory_order_relaxed);
  return moved;
}

/* Deletes entry e of slot `at`. The value goes, but the key keeps its payload until the next rebuild: a reader may
   have loaded the old tag and be about to load the payload. A table left with an eighth of its entries gets a smaller
   block. */
static size_t remove_at(table *t, entry *e, size_t at) {
  block *b = atomic_load_explicit(&t->block, memory_order_relaxed);
  store(&e->value_tag, &e->value, agc_void());
  atomic_store_explicit(&e->key_tag, AGC_T_VOID, memory_order_release);
  atomic_store_explicit(&b->index[at], DEAD, memory_order_release);
  int64_t size = atomic_load_explicit(&t->size, memory_order_relaxed) - 1;
  atomic_store_explicit(&t->size, size, memory_order_relaxed);
  return (size_t)size * 8 <= b->cap && b->slots > MIN_SLOTS ? rebuild(t) : 0;
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
  write_begin(t);
  size_t at = 0;
  entry *found = lookup_held(t, hash, key, &at);
  agc_value now = agc_void();
  switch (c) {
    case CHANGE_PUT:
      if (found) store(&found->value_tag, &found->value, args[2]);
      else moved = append(t, hash, key, args[2]);
      break;
    case CHANGE_PUT_NEW:
      result = agc_bool(!found);
      if (!found) moved = append(t, hash, key, args[2]);
      break;
    case CHANGE_DELETE:
      if (found) moved = remove_at(t, found, at);
      break;
    case CHANGE_ADD:
      if (found) now = value_of(found);
      if (found && !agc_is(now, AGC_T_INT)) {
        bad = now;
        break;
      }
      overflow = __builtin_add_overflow(found ? (int64_t)agc_value_word(now) : 0, by, &sum);
      if (overflow) break;
      result = agc_int(sum);
      if (found) store(&found->value_tag, &found->value, result);
      else moved = append(t, hash, key, result);
      break;
  }
  write_end(t);
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

/* The block goes to the collector whole, once no reader is in it, so the time does not grow with the table. */
static agc_value builtin_clear(agc_vm *vm, agc_value *args, uint32_t span) {
  table *t = table_arg(vm, args[0], span);
  agc_table_lock(vm->rt, t, true);
  write_begin(t);
  atomic_store_explicit(&t->block, NULL, memory_order_release);
  t->used = 0;
  atomic_store_explicit(&t->size, 0, memory_order_relaxed);
  write_end(t);
  agc_table_unlock(vm->rt, t, true);
  return agc_void();
}

static const entry *find(table *t, uint64_t hash, agc_value key) {
  return lookup(atomic_load_explicit(&t->block, memory_order_acquire), hash, key, NULL);
}

/* read_at when its first try failed: more tries, then the read lock, which keeps writers out. */
static __attribute__((noinline)) bool read_again(agc_vm *vm, table *t, uint64_t hash, agc_value key,
                                                 agc_value *value) {
  for (unsigned tries = 1, pauses = 1; tries < READ_TRIES; tries++) {
    pauses = agc_spin_step(pauses);
    uint64_t seq = atomic_load_explicit(&t->seq, memory_order_acquire);
    const entry *found = find(t, hash, key);
    agc_value seen = found ? value_of(found) : agc_void();
    if (!(seq & 1) && atomic_load_explicit(&t->seq, memory_order_acquire) == seq) {
      *value = seen;
      return found != NULL;
    }
  }
  agc_table_lock(vm->rt, t, false);
  const entry *found = find(t, hash, key);
  if (found) *value = value_of(found);
  agc_table_unlock(vm->rt, t, false);
  return found != NULL;
}

/* Whether the table holds key, and its value in *value. A try takes no lock: it keeps what it found only if `seq` was
   even and the same before and after (write_begin), else a write ran meanwhile and what it loaded, a value torn
   between two writes among it, is thrown away unread. */
static bool read_at(agc_vm *vm, table *t, uint64_t hash, agc_value key, agc_value *value) {
  uint64_t seq = atomic_load_explicit(&t->seq, memory_order_acquire);
  const entry *found = find(t, hash, key);
  uint32_t tag = AGC_T_VOID;
  uint64_t word = 0;
  if (found) {
    tag = atomic_load_explicit(&found->value_tag, memory_order_acquire);
    word = atomic_load_explicit(&found->value, memory_order_acquire);
  }
  if (__builtin_expect(!(seq & 1) && atomic_load_explicit(&t->seq, memory_order_acquire) == seq, 1)) {
    if (found) *value = agc_word_value(tag, word);
    return found != NULL;
  }
  return read_again(vm, t, hash, key, value);
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
    write_begin(t);
    entry *found = lookup_held(t, hash, key, NULL);
    agc_value now = found ? value_of(found) : agc_void();
    bool same = found ? had && now.tag == seen.tag && agc_value_word(now) == agc_value_word(seen) : !had;
    if (same && found) store(&found->value_tag, &found->value, agc_list_value(next));
    else if (same) moved = append(t, hash, key, agc_list_value(next));
    write_end(t);
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
static const item *snapshot(agc_vm *vm, agc_value v, uint32_t span, size_t *n) {
  table *t = table_arg(vm, v, span);
  item *copy = NULL;
  for (size_t room = 0;;) {
    agc_table_lock(vm->rt, t, false);
    size_t used = t->used;
    if (used <= room) {
      const block *b = atomic_load_explicit(&t->block, memory_order_relaxed);
      for (size_t k = 0; k < used; k++)
        copy[k] = (item){key_of(&b->entries[k]), value_of(&b->entries[k]),
                         atomic_load_explicit(&b->entries[k].hash, memory_order_relaxed)};
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
  const item *entries = snapshot(vm, args[0], span, &n);
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
  const item *entries = snapshot(vm, args[0], span, &n);
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
  block *b = atomic_load_explicit(&t->block, memory_order_relaxed);
  size_t live = 0, taken = 0, dead = 0, slots = b ? b->slots : 0, cap = b ? b->cap : 0;
  if (t->used > cap || cap != slots / 3 * 2 || (slots & (slots - 1))) return false;
  for (size_t k = 0; k < t->used; k++) {
    entry *e = &b->entries[k];
    agc_value key = key_of(e);
    if (agc_is(key, AGC_T_VOID)) continue;
    size_t at = 0;
    if (lookup(b, atomic_load_explicit(&e->hash, memory_order_relaxed), key, &at) != e) return false;
    live++;
  }
  for (size_t k = 0; k < slots; k++) {
    uint32_t e = atomic_load_explicit(&b->index[k], memory_order_relaxed);
    taken += e != EMPTY;
    dead += e == DEAD;
  }
  return (int64_t)live == atomic_load_explicit(&t->size, memory_order_relaxed) && taken == t->used &&
         dead == t->used - live;
}

/* No row is shared or a leaf: a call takes no rt->sync, only the table's own lock or none (a read), and it charges for
   String and Bytes keys, rebuilds and snapshots. */
const agc_builtin agc_ats_builtins[] = {
  {"ATS.new", 0, builtin_new, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false, false},
  {"ATS.put", 3, builtin_put, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false, false},
  {"ATS.put_new", 3, builtin_put_new, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false, false},
  {"ATS.get", 2, builtin_get, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false, false},
  {"ATS.has_key?", 2, builtin_has_key, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false, false},
  {"ATS.delete", 2, builtin_delete, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false, false},
  {"ATS.clear", 1, builtin_clear, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false, false},
  {"ATS.add", 3, builtin_add, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false, false},
  {"ATS.size", 1, builtin_size, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false, false},
  {"ATS.keys", 1, builtin_keys, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false, false},
  {"ATS.to_map", 1, builtin_to_map, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false, false},
  {"ATS.push", 3, builtin_push, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false, false},
};

const size_t agc_ats_builtin_count = sizeof agc_ats_builtins / sizeof agc_ats_builtins[0];
