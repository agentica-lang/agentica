/* ATS tables (vm/ats.c): order and snapshots, an add that overflows and leaves the table unchanged, the run check,
   and threads that update one table at once through the compare-and-swap with exact totals (also under TSan). */
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

static agc_value text(const char *s) { return agc_string_value(agc_make_string(s, strlen(s), strlen(s))); }

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
  if (setjmp(vm.fail) == 0) {
    (void)call(name, arity, args);
    assert(!"the call did not fail");
  }
  assert(strcmp(vm.outcome->code, code) == 0);
}

static void test_order(void) {
  agc_value t = call("ATS.new", 0, NULL);
  put(t, text("b"), 2);
  put(t, text("a"), 1);
  put(t, text("b"), 3);
  agc_value del[2] = {t, text("b")};
  (void)call("ATS.delete", 2, del);
  put(t, text("b"), 4);
  agc_value keys = call("ATS.keys", 1, &t);
  const agc_list *list = agc_as_list(&vm, keys);
  assert(agc_list_len(list) == 2);
  assert(agc_as_string(&vm, agc_list_get(list, 0))->data[0] == 'a');
  assert(agc_as_string(&vm, agc_list_get(list, 1))->data[0] == 'b');
  assert(get_int(t, text("b")) == 4 && size_of(t) == 2);
  /* Enough keys for every rotation of the trees, then every other one removed: the size and the order still hold. */
  agc_value u = call("ATS.new", 0, NULL);
  for (int64_t k = 0; k < 1000; k++) put(u, agc_int((k * 7919) % 1000), k);
  for (int64_t k = 0; k < 1000; k += 2) {
    agc_value args[2] = {u, agc_int((k * 7919) % 1000)};
    (void)call("ATS.delete", 2, args);
  }
  assert(size_of(u) == 500);
  const agc_list *left = agc_as_list(&vm, call("ATS.keys", 1, &u));
  for (size_t k = 0; k < 500; k++)
    assert(agc_as_int(&vm, agc_list_get(left, k)) == (int64_t)((2 * k + 1) * 7919 % 1000));
}

static void test_overflow_keeps_the_value(void) {
  agc_value t = call("ATS.new", 0, NULL);
  put(t, text("max"), INT64_MAX);
  agc_value args[3] = {t, text("max"), agc_int(1)};
  fails("ATS.add", 3, args, "RUNTIME-INTEGER-OVERFLOW");
  assert(get_int(t, text("max")) == INT64_MAX && size_of(t) == 1);
  agc_value fresh[3] = {t, text("min"), agc_int(INT64_MIN)};
  (void)call("ATS.add", 3, fresh);
  agc_value under[3] = {t, text("min"), agc_int(-1)};
  fails("ATS.add", 3, under, "RUNTIME-INTEGER-OVERFLOW");
  assert(get_int(t, text("min")) == INT64_MIN && size_of(t) == 2);
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
  agc_value counter = text("counter");
  char name[32];
  for (int r = 0; r < ROUNDS; r++) {
    add_on(v, shared_table, counter, 1);
    snprintf(name, sizeof name, "t%d-%d", (int)k, r % OWN_KEYS);
    add_on(v, shared_table, text(name), 1);
    snprintf(name, sizeof name, "tmp%d", (int)k);
    agc_value args[3] = {shared_table, text(name), agc_int(r)};
    (void)call_on(v, "ATS.put", 3, args);
    (void)call_on(v, "ATS.delete", 2, args);
  }
  agc_gc_thread_leave();
}

static void test_threads(void) {
  shared_table = call("ATS.new", 0, NULL);
  for (int k = 0; k < THREADS; k++) {
    workers[k] = vm;
    workers[k].task = agc_new_task(&workers[k]);
  }
  assert(uv_barrier_init(&gate, THREADS) == 0);
  uv_thread_t threads[THREADS];
  for (intptr_t k = 0; k < THREADS; k++) assert(uv_thread_create(&threads[k], worker, (void *)k) == 0);
  for (int k = 0; k < THREADS; k++) assert(uv_thread_join(&threads[k]) == 0);
  uv_barrier_destroy(&gate);
  assert(get_int(shared_table, text("counter")) == (int64_t)THREADS * ROUNDS);
  assert(size_of(shared_table) == 1 + THREADS * OWN_KEYS);
  char name[32];
  for (int k = 0; k < THREADS; k++)
    for (int j = 0; j < OWN_KEYS; j++) {
      snprintf(name, sizeof name, "t%d-%d", k, j);
      assert(get_int(shared_table, text(name)) == ROUNDS / OWN_KEYS);
    }
}

int main(void) {
  agc_test_deadline(120);
  agc_test_io_vm(&vm);
  /* agc_charge counts on the running task; a failure jumps to vm.fail, outside a turn. */
  if (!vm.task) vm.task = agc_new_task(&vm);
  test_order();
  test_overflow_keeps_the_value();
  test_other_run();
  test_threads();
  puts("ats tests passed");
  return 0;
}
