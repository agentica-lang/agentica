/* ATS tables (vm/ats.c): order and snapshots with the invariants of the index and the entries, growth and shrinking,
   mixed key tags, a failed add that changes nothing, the run check, and threads on one table (also under TSan): exact
   totals of racing adds, writes against clears, pushes to one list, and readers without the lock against writes,
   rebuilds and clears that never see a torn value. */
#include "../core.h"
#include "../services.h"
#include "io_harness.h"

#include <assert.h>
#include <setjmp.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <uv.h>

#include "test_support.h"

#define THREADS 4
#define ROUNDS 2000
#define OWN_KEYS 50

static agc_vm vm;

static agc_value call_on(agc_vm *v, const char *name, uint32_t arity, agc_value *args) {
  const agc_builtin *b = agc_find_builtin((const uint8_t *)name, strlen(name), arity);
  assert(b && !b->shared);
  return b->fn(v, args, 0);
}

static agc_value call(const char *name, uint32_t arity, agc_value *args) { return call_on(&vm, name, arity, args); }

static agc_value put(agc_value t, agc_value key, int64_t n) {
  agc_value args[3] = {t, key, agc_int(n)};
  return call("ATS.put", 3, args);
}

static int64_t add_on(agc_vm *v, agc_value t, agc_value key, int64_t n) {
  agc_value args[3] = {t, key, agc_int(n)};
  return agc_as_int(v, call_on(v, "ATS.add", 3, args));
}

static int64_t get_int(agc_value t, agc_value key) {
  agc_value args[2] = {t, key};
  const agc_result *r = agc_as_result(&vm, call("ATS.get", 2, args));
  assert(r->ok);
  return agc_as_int(&vm, r->value);
}

static int64_t size_of(agc_value t) { return agc_as_int(&vm, call("ATS.size", 1, &t)); }

static void fails(const char *name, uint32_t arity, agc_value *args, const char *code) {
  if (AGC_CATCH(vm.fail) == 0) {
    (void)call(name, arity, args);
    assert(!"the call did not fail");
  }
  assert(strcmp(vm.outcome->code, code) == 0);
}

static void test_order(void) {
  agc_value t = call("ATS.new", 0, NULL);
  put(t, agc_test_str("b"), 2);
  put(t, agc_test_str("a"), 1);
  put(t, agc_test_str("b"), 3);
  agc_value del[2] = {t, agc_test_str("b")};
  (void)call("ATS.delete", 2, del);
  put(t, agc_test_str("b"), 4);
  agc_value keys = call("ATS.keys", 1, &t);
  const agc_list *list = agc_as_list(&vm, keys);
  assert(agc_list_len(list) == 2);
  assert(agc_as_string(&vm, agc_list_get(list, 0))->data[0] == 'a');
  assert(agc_as_string(&vm, agc_list_get(list, 1))->data[0] == 'b');
  assert(get_int(t, agc_test_str("b")) == 4 && size_of(t) == 2);
  /* Enough keys for several rebuilds, then every other one removed: the size and the order still hold. */
  agc_value u = call("ATS.new", 0, NULL);
  for (int64_t k = 0; k < 1000; k++) put(u, agc_int((k * 7919) % 1000), k);
  assert(agc_ats_valid(&vm, u));
  for (int64_t k = 0; k < 1000; k += 2) {
    agc_value args[2] = {u, agc_int((k * 7919) % 1000)};
    (void)call("ATS.delete", 2, args);
  }
  assert(size_of(u) == 500 && agc_ats_valid(&vm, u));
  const agc_list *left = agc_as_list(&vm, call("ATS.keys", 1, &u));
  for (size_t k = 0; k < 500; k++)
    assert(agc_as_int(&vm, agc_list_get(left, k)) == (int64_t)((2 * k + 1) * 7919 % 1000));
}

/* Seeded puts and deletes over few keys, so keys come back after a delete: the table stays valid with the size of a
   shadow set. */
static void test_random_changes(void) {
  agc_value t = call("ATS.new", 0, NULL);
  bool present[200] = {false};
  int64_t count = 0;
  uint64_t seed = 12345;
  for (int k = 0; k < 4000; k++) {
    seed = seed * 6364136223846793005u + 1442695040888963407u;
    int64_t key = (int64_t)((seed >> 33) % 200);
    agc_value args[3] = {t, agc_int(key), agc_int(k)};
    if ((seed >> 20) % 3 == 0) {
      (void)call("ATS.delete", 2, args);
      count -= present[key];
      present[key] = false;
    } else {
      (void)call("ATS.put", 3, args);
      count += !present[key];
      present[key] = true;
    }
    if (k % 100 == 0) assert(agc_ats_valid(&vm, t));
  }
  assert(agc_ats_valid(&vm, t) && size_of(t) == count);
}

static agc_value raw(const char *s, size_t n) { return agc_bytes_value(agc_make_bytes((const uint8_t *)s, n)); }

/* Typed code keeps one key type per table; forged bytecode may mix them. An Int, a String and a Bytes of the same
   bytes are three keys, sorted by tag; Bytes keys sort by byte, then the shorter first; another tag is
   RUNTIME-INTERNAL and leaves the table as it was. */
static void test_mixed_keys(void) {
  agc_value t = call("ATS.new", 0, NULL);
  put(t, raw("a\0", 2), 1);
  put(t, agc_test_str("a"), 2);
  put(t, raw("a", 1), 3);
  put(t, agc_int(97), 4);
  put(t, raw("", 0), 5);
  put(t, raw("a\0", 2), 6);
  assert(size_of(t) == 5 && agc_ats_valid(&vm, t));
  assert(get_int(t, agc_test_str("a")) == 2 && get_int(t, raw("a", 1)) == 3 && get_int(t, agc_int(97)) == 4);
  assert(get_int(t, raw("", 0)) == 5 && get_int(t, raw("a\0", 2)) == 6);
  agc_value del[2] = {t, raw("a", 1)};
  (void)call("ATS.delete", 2, del);
  assert(size_of(t) == 4 && get_int(t, agc_test_str("a")) == 2 && agc_ats_valid(&vm, t));
  agc_value wrong[3] = {t, agc_bool(true), agc_int(0)};
  fails("ATS.put", 3, wrong, "RUNTIME-INTERNAL");
  assert(size_of(t) == 4);
}

/* A table that grew and lost nearly all its keys keeps the order of the rest; one key put and deleted many times
   stays small (a rebuild drops the deleted entries); a value that is not an Int, which only forged bytecode can
   put next to an add, fails and changes nothing. */
static void test_growth(void) {
  agc_value t = call("ATS.new", 0, NULL);
  for (int64_t k = 0; k < 5000; k++) put(t, agc_int(k), k);
  assert(size_of(t) == 5000 && agc_ats_valid(&vm, t));
  for (int64_t k = 0; k < 5000; k++) {
    agc_value args[2] = {t, agc_int(k)};
    if (k % 1000 != 7) (void)call("ATS.delete", 2, args);
  }
  assert(size_of(t) == 5 && agc_ats_valid(&vm, t));
  const agc_list *left = agc_as_list(&vm, call("ATS.keys", 1, &t));
  assert(agc_list_len(left) == 5);
  for (size_t k = 0; k < 5; k++) assert(agc_as_int(&vm, agc_list_get(left, k)) == (int64_t)(1000 * k + 7));
  for (int64_t k = 0; k < 20000; k++) {
    agc_value args[3] = {t, agc_test_str("again"), agc_int(k)};
    (void)call("ATS.put", 3, args);
    if (k % 2 == 0) (void)call("ATS.delete", 2, args);
  }
  assert(size_of(t) == 6 && agc_ats_valid(&vm, t) && get_int(t, agc_test_str("again")) == 19999);
  const agc_list *keys = agc_as_list(&vm, call("ATS.keys", 1, &t));
  assert(agc_as_string(&vm, agc_list_get(keys, 5))->data[0] == 'a');
  agc_value text[3] = {t, agc_int(1), agc_test_str("text")};
  (void)call("ATS.put", 3, text);
  agc_value add[3] = {t, agc_int(1), agc_int(1)};
  fails("ATS.add", 3, add, "RUNTIME-INTERNAL");
  assert(size_of(t) == 7 && agc_ats_valid(&vm, t));
}

static void test_clear(void) {
  agc_value t = call("ATS.new", 0, NULL);
  for (int64_t k = 0; k < 100; k++) put(t, agc_int(k), k);
  const agc_list *before = agc_as_list(&vm, call("ATS.keys", 1, &t));
  (void)call("ATS.clear", 1, &t);
  agc_value probe[2] = {t, agc_int(7)};
  assert(size_of(t) == 0 && agc_ats_valid(&vm, t) && !agc_as_bool(&vm, call("ATS.has_key?", 2, probe)));
  assert(agc_list_len(before) == 100);
  (void)call("ATS.clear", 1, &t);
  put(t, agc_int(7), 70);
  put(t, agc_int(3), 30);
  const agc_list *after = agc_as_list(&vm, call("ATS.keys", 1, &t));
  assert(agc_list_len(after) == 2 && agc_as_int(&vm, agc_list_get(after, 0)) == 7 && get_int(t, agc_int(7)) == 70);
  agc_runtime *mine = vm.rt;
  agc_runtime other = *mine;
  vm.rt = &other;
  fails("ATS.clear", 1, &t, "RUNTIME-ATS-CONTEXT");
  vm.rt = mine;
  assert(size_of(t) == 2);
}

static void test_overflow_keeps_the_value(void) {
  agc_value t = call("ATS.new", 0, NULL);
  put(t, agc_test_str("max"), INT64_MAX);
  agc_value args[3] = {t, agc_test_str("max"), agc_int(1)};
  fails("ATS.add", 3, args, "RUNTIME-INTEGER-OVERFLOW");
  assert(get_int(t, agc_test_str("max")) == INT64_MAX && size_of(t) == 1);
  agc_value fresh[3] = {t, agc_test_str("min"), agc_int(INT64_MIN)};
  (void)call("ATS.add", 3, fresh);
  agc_value under[3] = {t, agc_test_str("min"), agc_int(-1)};
  fails("ATS.add", 3, under, "RUNTIME-INTEGER-OVERFLOW");
  assert(get_int(t, agc_test_str("min")) == INT64_MIN && size_of(t) == 2);
}

static void test_other_run(void) {
  agc_value t = call("ATS.new", 0, NULL);
  agc_runtime *mine = vm.rt;
  agc_runtime other = *mine;
  vm.rt = &other;
  fails("ATS.size", 1, &t, "RUNTIME-ATS-CONTEXT");
  vm.rt = mine;
  assert(size_of(t) == 0);
}

static agc_vm workers[THREADS];
static uv_barrier_t gate;
static agc_value shared_table;

/* Each thread adds to one shared counter and to keys of its own, and puts then deletes keys of its own, so every
   install races the other threads' installs on the same pointer. */
static void worker(void *arg) {
  intptr_t k = (intptr_t)arg;
  agc_vm *v = &workers[k];
  assert(agc_gc_thread_enter());
  uv_barrier_wait(&gate);
  agc_value counter = agc_test_str("counter");
  char name[32];
  for (int r = 0; r < ROUNDS; r++) {
    add_on(v, shared_table, counter, 1);
    snprintf(name, sizeof name, "t%d-%d", (int)k, r % OWN_KEYS);
    add_on(v, shared_table, agc_test_str(name), 1);
    snprintf(name, sizeof name, "tmp%d", (int)k);
    agc_value args[3] = {shared_table, agc_test_str(name), agc_int(r)};
    (void)call_on(v, "ATS.put", 3, args);
    (void)call_on(v, "ATS.delete", 2, args);
  }
  agc_gc_thread_leave();
}

/* Runs first on thread 0 and rest on the others, over a new shared table, and waits for them. */
static void race(uv_thread_cb first, uv_thread_cb rest) {
  agc_share(&vm);
  shared_table = call("ATS.new", 0, NULL);
  for (int k = 0; k < THREADS; k++) {
    workers[k] = vm;
    workers[k].task = agc_new_task(&workers[k]);
  }
  assert(uv_barrier_init(&gate, THREADS) == 0);
  uv_thread_t threads[THREADS];
  for (intptr_t k = 0; k < THREADS; k++) assert(uv_thread_create(&threads[k], k ? rest : first, (void *)k) == 0);
  for (int k = 0; k < THREADS; k++) assert(uv_thread_join(&threads[k]) == 0);
  uv_barrier_destroy(&gate);
}

static void test_threads(void) {
  race(worker, worker);
  assert(get_int(shared_table, agc_test_str("counter")) == (int64_t)THREADS * ROUNDS);
  assert(size_of(shared_table) == 1 + THREADS * OWN_KEYS && agc_ats_valid(&vm, shared_table));
  char name[32];
  for (int k = 0; k < THREADS; k++)
    for (int j = 0; j < OWN_KEYS; j++) {
      snprintf(name, sizeof name, "t%d-%d", k, j);
      assert(get_int(shared_table, agc_test_str(name)) == ROUNDS / OWN_KEYS);
    }
}

/* Every thread pushes to one shared key and to a key of its own: no item is lost, and each own list is in order. */
static void pusher(void *arg) {
  intptr_t k = (intptr_t)arg;
  agc_vm *v = &workers[k];
  assert(agc_gc_thread_enter());
  uv_barrier_wait(&gate);
  for (int r = 0; r < ROUNDS; r++) {
    agc_value all[3] = {shared_table, agc_test_str("all"), agc_int(r)};
    assert(agc_as_int(v, call_on(v, "ATS.push", 3, all)) >= r + 1);
    agc_value own[3] = {shared_table, agc_int(k), agc_int(r)};
    assert(agc_as_int(v, call_on(v, "ATS.push", 3, own)) == r + 1);
  }
  agc_gc_thread_leave();
}

static const agc_list *list_at(agc_value t, agc_value key) {
  agc_value args[2] = {t, key};
  const agc_result *r = agc_as_result(&vm, call("ATS.get", 2, args));
  assert(r->ok);
  return agc_as_list(&vm, r->value);
}

static void test_push(void) {
  race(pusher, pusher);
  assert(agc_ats_valid(&vm, shared_table) && size_of(shared_table) == THREADS + 1);
  const agc_list *all = list_at(shared_table, agc_test_str("all"));
  assert(agc_list_len(all) == (size_t)THREADS * ROUNDS);
  static int seen[ROUNDS];
  for (size_t k = 0; k < agc_list_len(all); k++) seen[agc_as_int(&vm, agc_list_get(all, k))]++;
  for (size_t r = 0; r < ROUNDS; r++) assert(seen[r] == THREADS);
  for (int64_t k = 0; k < THREADS; k++) {
    const agc_list *own = list_at(shared_table, agc_int(k));
    assert(agc_list_len(own) == ROUNDS);
    for (size_t r = 0; r < ROUNDS; r += 97) assert(agc_as_int(&vm, agc_list_get(own, r)) == (int64_t)r);
  }
  /* Forged bytecode can push to a key that holds no list: it fails and the value stays. */
  agc_value t = call("ATS.new", 0, NULL);
  put(t, agc_int(1), 5);
  agc_value args[3] = {t, agc_int(1), agc_int(6)};
  fails("ATS.push", 3, args, "RUNTIME-INTERNAL");
  assert(get_int(t, agc_int(1)) == 5);
}

static atomic_bool clearing_done;

/* Clears the table while the other threads add to it. */
static void clearer(void *arg) {
  agc_vm *v = &workers[(intptr_t)arg];
  assert(agc_gc_thread_enter());
  uv_barrier_wait(&gate);
  for (int r = 0; r < ROUNDS; r++) (void)call_on(v, "ATS.clear", 1, &shared_table);
  atomic_store(&clearing_done, true);
  agc_gc_thread_leave();
}

/* Adds 1 to its own key until the clears are over, then ROUNDS times more. A clear takes the key away whole, so each
   add gives 1 or the last result plus 1, and the adds after the last clear all count. */
static void clear_writer(void *arg) {
  intptr_t k = (intptr_t)arg;
  agc_vm *v = &workers[k];
  assert(agc_gc_thread_enter());
  uv_barrier_wait(&gate);
  int64_t last = 0, after = 0;
  while (after < ROUNDS) {
    bool done = atomic_load(&clearing_done);
    int64_t now = add_on(v, shared_table, agc_int(k), 1);
    assert(now == 1 || now == last + 1);
    last = now;
    if (done) after++;
  }
  agc_gc_thread_leave();
}

static void test_clear_races_writers(void) {
  atomic_store(&clearing_done, false);
  race(clearer, clear_writer);
  assert(size_of(shared_table) == THREADS - 1 && agc_ats_valid(&vm, shared_table));
  for (int64_t k = 1; k < THREADS; k++) assert(get_int(shared_table, agc_int(k)) >= ROUNDS);
}

#define READ_KEYS 4
#define READ_ROUNDS 40000
#define FILLER 600

static agc_value read_texts[READ_KEYS];
static atomic_bool writing_done;
static atomic_int_fast64_t reads_seen;

static void put_on(agc_vm *v, agc_value t, agc_value key, agc_value value) {
  agc_value args[3] = {t, key, value};
  (void)call_on(v, "ATS.put", 3, args);
}

/* Key k holds the Int k or the String "s<k>", and the two swap all the time, so a value torn between them has the tag
   of one and the payload of the other. Fillers make the table grow and shrink, and a clear now and then empties it. */
static void read_writer(void *arg) {
  agc_vm *v = &workers[(intptr_t)arg];
  assert(agc_gc_thread_enter());
  uv_barrier_wait(&gate);
  for (int r = 0; r < READ_ROUNDS; r++) {
    for (int64_t k = 0; k < READ_KEYS; k++) put_on(v, shared_table, agc_int(k), r % 2 ? agc_int(k) : read_texts[k]);
    if (r % 512 == 3) {
      for (int64_t k = 0; k < FILLER; k++) put_on(v, shared_table, agc_int(1000 + k), agc_int(k));
      for (int64_t k = 0; k < FILLER; k++) {
        agc_value args[2] = {shared_table, agc_int(1000 + k)};
        (void)call_on(v, "ATS.delete", 2, args);
      }
    }
    if (r % 1024 == 5) (void)call_on(v, "ATS.clear", 1, &shared_table);
  }
  atomic_store(&writing_done, true);
  agc_gc_thread_leave();
}

/* Reads with no lock while read_writer runs: a key is missing or holds one of its two values, whole. */
static void reader(void *arg) {
  intptr_t id = (intptr_t)arg;
  agc_vm *v = &workers[id];
  assert(agc_gc_thread_enter());
  uv_barrier_wait(&gate);
  uint64_t seed = (uint64_t)id;
  int64_t reads = 0;
  while (!atomic_load(&writing_done)) {
    seed = seed * 6364136223846793005u + 1442695040888963407u;
    int64_t k = (int64_t)((seed >> 33) % READ_KEYS);
    agc_value args[2] = {shared_table, agc_int(k)};
    const agc_result *r = agc_as_result(v, call_on(v, "ATS.get", 2, args));
    reads++;
    if (!r->ok) continue;
    if (agc_is(r->value, AGC_T_INT)) {
      assert(agc_as_int(v, r->value) == k);
      continue;
    }
    const agc_string *text = agc_as_string(v, r->value), *want = agc_as_string(v, read_texts[k]);
    assert(text == want && memcmp(text->data, want->data, want->bytes) == 0);
    (void)agc_as_bool(v, call_on(v, "ATS.has_key?", 2, args));
  }
  atomic_fetch_add(&reads_seen, reads);
  agc_gc_thread_leave();
}

static void test_readers_race_writes(void) {
  char name[16];
  for (int k = 0; k < READ_KEYS; k++) {
    snprintf(name, sizeof name, "s%d", k);
    read_texts[k] = agc_test_str(name);
  }
  atomic_store(&writing_done, false);
  atomic_store(&reads_seen, 0);
  race(read_writer, reader);
  assert(atomic_load(&reads_seen) >= THREADS - 1 && agc_ats_valid(&vm, shared_table));
}

int main(void) {
  agc_test_deadline(120);
  agc_test_io_vm(&vm);
  /* agc_charge counts on the running task; a failure jumps to vm.fail, outside a turn. */
  if (!vm.task) vm.task = agc_new_task(&vm);
  test_order();
  test_random_changes();
  test_mixed_keys();
  test_growth();
  test_clear();
  test_overflow_keeps_the_value();
  test_other_run();
  test_threads();
  test_clear_races_writers();
  test_push();
  test_readers_race_writes();
  puts("ats tests passed");
  return 0;
}
