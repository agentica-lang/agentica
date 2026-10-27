/*
 * ATS[K, V], the shared tables (docs/grammar/06c-tasks-and-tests.md, "Shared tables"): ATS.new, put, put_new, get,
 * has_key?, delete, add, size, keys and to_map. A table is one atomic pointer to an immutable state: two persistent
 * AVL trees over the same entries, one ordered by key for the lookups and one by insertion number for the snapshots
 * in first-insertion order. A reader loads the pointer; a writer builds the next state from the one it loaded and
 * installs it with compare-and-swap, so each call is atomic on any scheduler without a lock
 * (docs/vm/10-io-multicore.md §10.2.3). Service layer.
 */
#include "services.h"

#include <stdatomic.h>

/* An AVL tree of n entries is at most 1.44 * log2(n + 2) high, so 96 levels hold more entries than memory can: the
   explicit stack of a walk and the recursion of insert and erase stay within it. */
#define MAX_HEIGHT 96

typedef struct {
  agc_value key, value;
  uint64_t seq; /* the insertion number: a key put again after a delete gets a new one */
} entry;

typedef struct node node;

struct node {
  const node *left, *right;
  entry e;
  uint32_t height;
};

/* Never changes once a table holds it, so a reader needs no lock and a snapshot is the pointer. */
typedef struct {
  const node *by_key, *by_seq;
  int64_t size;
  uint64_t next_seq;
} state;

typedef struct {
  _Atomic(const state *) current;
  /* The run that made the table: another run's call is RUNTIME-ATS-CONTEXT. One run is one execution on the VM, so no
     value reaches another today; the check guards any later way to pass values between them. */
  const agc_runtime *rt;
} table;

typedef enum { CHANGE_PUT, CHANGE_PUT_NEW, CHANGE_DELETE, CHANGE_ADD } change;

static const state empty_state = {NULL, NULL, 0, 0};

static agc_string *ascii(const char *text) {
  size_t n = strlen(text);
  return agc_make_string(text, n, n);
}

static uint32_t height(const node *n) { return n ? n->height : 0; }

static const node *make(const node *left, const node *right, entry e) {
  node *n = agc_alloc(sizeof *n);
  uint32_t l = height(left), r = height(right);
  n->left = left;
  n->right = right;
  n->e = e;
  n->height = (l > r ? l : r) + 1;
  return n;
}

/* A node over two subtrees whose heights differ by at most 2, rotated back to AVL balance. */
static const node *balance(const node *left, const node *right, entry e) {
  uint32_t l = height(left), r = height(right);
  if (l > r + 1) {
    if (height(left->left) >= height(left->right)) return make(left->left, make(left->right, right, e), left->e);
    return make(make(left->left, left->right->left, left->e), make(left->right->right, right, e), left->right->e);
  }
  if (r > l + 1) {
    if (height(right->right) >= height(right->left)) return make(make(left, right->left, e), right->right, right->e);
    return make(make(left, right->left->left, e), make(right->left->right, right->right, right->e), right->left->e);
  }
  return make(left, right, e);
}

/* Keys are Int or String. Typed code never mixes them in one table; forged bytecode may, so Ints sort before Strings
   and every comparison stays defined. */
static int compare_keys(agc_vm *vm, agc_value a, agc_value b) {
  bool a_int = agc_is(a, AGC_T_INT), b_int = agc_is(b, AGC_T_INT);
  if (a_int != b_int) return a_int ? -1 : 1;
  if (a_int) {
    int64_t x = agc_as_int(vm, a), y = agc_as_int(vm, b);
    return (x > y) - (x < y);
  }
  const agc_string *s = agc_as_string(vm, a), *t = agc_as_string(vm, b);
  size_t n = s->bytes < t->bytes ? s->bytes : t->bytes;
  int c = n ? memcmp(s->data, t->data, n) : 0;
  if (c) return c < 0 ? -1 : 1;
  return (s->bytes > t->bytes) - (s->bytes < t->bytes);
}

static int order(agc_vm *vm, bool by_seq, entry probe, const node *n) {
  if (by_seq) return (probe.seq > n->e.seq) - (probe.seq < n->e.seq);
  return compare_keys(vm, probe.key, n->e.key);
}

/* The tree with e in place of the entry of the same order, or added. */
static const node *insert(agc_vm *vm, const node *t, bool by_seq, entry e) { // NOLINT(misc-no-recursion)
  if (!t) return make(NULL, NULL, e);
  int c = order(vm, by_seq, e, t);
  if (c < 0) return balance(insert(vm, t->left, by_seq, e), t->right, t->e);
  if (c > 0) return balance(t->left, insert(vm, t->right, by_seq, e), t->e);
  return make(t->left, t->right, e);
}

static const node *remove_min(const node *t, entry *min) { // NOLINT(misc-no-recursion)
  if (!t->left) {
    *min = t->e;
    return t->right;
  }
  return balance(remove_min(t->left, min), t->right, t->e);
}

/* The tree without the entry of e's order, which it holds. */
static const node *erase(agc_vm *vm, const node *t, bool by_seq, entry e) { // NOLINT(misc-no-recursion)
  if (!t) return NULL;
  int c = order(vm, by_seq, e, t);
  if (c < 0) return balance(erase(vm, t->left, by_seq, e), t->right, t->e);
  if (c > 0) return balance(t->left, erase(vm, t->right, by_seq, e), t->e);
  if (!t->left) return t->right;
  if (!t->right) return t->left;
  entry min;
  const node *right = remove_min(t->right, &min);
  return balance(t->left, right, min);
}

static const node *find(agc_vm *vm, const node *t, agc_value key) {
  while (t) {
    int c = compare_keys(vm, key, t->e.key);
    if (!c) return t;
    t = c < 0 ? t->left : t->right;
  }
  return NULL;
}

static table *table_arg(agc_vm *vm, agc_value v, uint32_t span) {
  table *t = agc_as_ats(vm, v);
  if (t->rt != vm->rt) agc_fail(vm, "RUNTIME-ATS-CONTEXT", "the table belongs to another run", span + 1);
  return t;
}

/* A key is an Int or a String; a String key costs its bytes, as in a Map lookup. */
static agc_value key_arg(agc_vm *vm, agc_value key) {
  if (!agc_is(key, AGC_T_INT)) agc_charge(vm, agc_as_string(vm, key)->bytes / AGC_COST_BYTES);
  return key;
}

static const state *load(table *t) { return atomic_load_explicit(&t->current, memory_order_acquire); }

/* Installs next over seen; false when another call installed a state first, and the caller builds again from that
   one. The release orders the nodes before the pointer that publishes them. The caller holds seen, so the collector
   cannot free it and give its address to a newer state: a CAS that matches it saw no change (no ABA). */
static bool install(table *t, const state *seen, const state *next) {
  if (next == seen) return true;
  return atomic_compare_exchange_strong_explicit(&t->current, &seen, next, memory_order_acq_rel,
                                                 memory_order_acquire);
}

/* The state with key set to value: a new key gets the next insertion number, a present one keeps its own. */
static const state *with_put(agc_vm *vm, const state *s, const node *found, agc_value key, agc_value value) {
  state *next = agc_alloc(sizeof *next);
  *next = *s;
  entry e = {key, value, found ? found->e.seq : s->next_seq};
  next->by_key = insert(vm, s->by_key, false, e);
  next->by_seq = insert(vm, s->by_seq, true, e);
  if (!found) {
    next->size++;
    next->next_seq++;
  }
  return next;
}

/* The state without the entry found. */
static const state *without(agc_vm *vm, const state *s, const node *found) {
  state *next = agc_alloc(sizeof *next);
  *next = *s;
  next->by_key = erase(vm, s->by_key, false, found->e);
  next->by_seq = erase(vm, s->by_seq, true, found->e);
  next->size--;
  return next;
}

static agc_value builtin_new(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  table *t = agc_alloc(sizeof *t);
  atomic_init(&t->current, &empty_state);
  t->rt = vm->rt;
  return agc_ats_value(t);
}

/* The state after one change of key, or s itself when the change leaves the table as it is; *result gets the result
   of the call. An add that overflows fails here, before anything is installed, so the table keeps its value. */
static const state *changed(agc_vm *vm, const state *s, change c, agc_value key, agc_value value, uint32_t span,
                            agc_value *result) {
  const node *found = find(vm, s->by_key, key);
  switch (c) {
    case CHANGE_PUT: *result = agc_void(); return with_put(vm, s, found, key, value);
    case CHANGE_PUT_NEW: *result = agc_bool(!found); return found ? s : with_put(vm, s, NULL, key, value);
    case CHANGE_DELETE: *result = agc_void(); return found ? without(vm, s, found) : s;
    case CHANGE_ADD: {
      int64_t sum = 0;
      if (__builtin_add_overflow(found ? agc_as_int(vm, found->e.value) : 0, agc_as_int(vm, value), &sum))
        agc_fail(vm, "RUNTIME-INTEGER-OVERFLOW", "Int result is outside the 64-bit range", span);
      *result = agc_int(sum);
      return with_put(vm, s, found, key, *result);
    }
  }
  return s;
}

/* One write: build the next state from the one loaded, and build again from the newer one when another call
   installed it first. */
static agc_value update(agc_vm *vm, agc_value *args, uint32_t span, change c) {
  table *t = table_arg(vm, args[0], span);
  agc_value key = key_arg(vm, args[1]);
  agc_value value = c == CHANGE_DELETE ? agc_void() : args[2];
  agc_value result = agc_void();
  const state *seen;
  do {
    seen = load(t);
  } while (!install(t, seen, changed(vm, seen, c, key, value, span, &result)));
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

static agc_value builtin_get(agc_vm *vm, agc_value *args, uint32_t span) {
  table *t = table_arg(vm, args[0], span);
  const node *found = find(vm, load(t)->by_key, key_arg(vm, args[1]));
  if (found) return agc_result_value(true, found->e.value);
  agc_string *message = agc_concat(agc_concat(ascii("key "), agc_debug(vm, args[1])), ascii(" is not in the table"));
  return agc_result_value(false, agc_string_value(message));
}

static agc_value builtin_has_key(agc_vm *vm, agc_value *args, uint32_t span) {
  table *t = table_arg(vm, args[0], span);
  return agc_bool(find(vm, load(t)->by_key, key_arg(vm, args[1])) != NULL);
}

static agc_value builtin_size(agc_vm *vm, agc_value *args, uint32_t span) {
  return agc_int(load(table_arg(vm, args[0], span))->size);
}

/* Calls visit on each entry of the snapshot in insertion order: an in-order walk of by_seq with an explicit stack. */
static void each_entry(const state *s, void (*visit)(agc_vm *vm, entry e, void *data), agc_vm *vm, void *data) {
  const node *stack[MAX_HEIGHT];
  size_t depth = 0;
  const node *at = s->by_seq;
  while (at || depth) {
    while (at) {
      stack[depth++] = at;
      at = at->left;
    }
    at = stack[--depth];
    visit(vm, at->e, data);
    at = at->right;
  }
}

static void add_key(agc_vm *vm, entry e, void *data) {
  (void)vm;
  agc_list_builder_more(data, e.key);
}

static void add_pair(agc_vm *vm, entry e, void *data) {
  agc_map **map = data;
  *map = agc_map_put(vm, *map, e.key, e.value);
}

/* The snapshot is the loaded pointer: building the list or map takes no lock and holds back no writer. */
static agc_value builtin_keys(agc_vm *vm, agc_value *args, uint32_t span) {
  const state *s = load(table_arg(vm, args[0], span));
  agc_charge(vm, (uint64_t)s->size);
  agc_list_builder b;
  agc_list_builder_sized(&b, (size_t)s->size);
  each_entry(s, add_key, vm, &b);
  return agc_list_value(agc_list_builder_finish(&b));
}

static agc_value builtin_to_map(agc_vm *vm, agc_value *args, uint32_t span) {
  const state *s = load(table_arg(vm, args[0], span));
  agc_charge(vm, (uint64_t)s->size);
  agc_map *map = agc_new_map();
  each_entry(s, add_pair, vm, &map);
  return agc_map_value(map);
}

/* No row is shared or a leaf: a call takes no lock (the atomic pointer orders the writers), and a call charges for
   String keys and snapshots. */
const agc_builtin agc_ats_builtins[] = {
  {"ATS.new", 0, builtin_new, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"ATS.put", 3, builtin_put, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"ATS.put_new", 3, builtin_put_new, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"ATS.get", 2, builtin_get, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"ATS.has_key?", 2, builtin_has_key, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"ATS.delete", 2, builtin_delete, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"ATS.add", 3, builtin_add, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"ATS.size", 1, builtin_size, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"ATS.keys", 1, builtin_keys, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"ATS.to_map", 1, builtin_to_map, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
};

const size_t agc_ats_builtin_count = sizeof agc_ats_builtins / sizeof agc_ats_builtins[0];
