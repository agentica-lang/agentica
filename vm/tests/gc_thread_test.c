/*
 * Boehm with threads (docs/vm/10-io-multicore.md §10.2.3, "GC"): threads that libuv starts register with the
 * collector, allocate, and are scanned and stopped by collections that any of them starts. Each thread keeps its
 * list head only in a local variable, so a collector that missed its stack would free live nodes, and the check of the
 * list afterwards would fail. The sanitizer build has no collector; there the test only runs the threads.
 */
#include "../value.h"

#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <uv.h>

#define THREADS 4
#define NODES 20000
#define ROUNDS 5

typedef struct node {
  struct node *next;
  uint64_t value;
} node;

static _Atomic int finished;
static _Atomic bool failed;

/* Builds NODES nodes holding SEED + k, collects between rounds, and checks every node. */
static void build_and_check(uint64_t seed) {
  node *head = NULL;
  for (uint64_t k = 0; k < NODES; k++) {
    node *n = agc_alloc(sizeof *n);
    n->next = head;
    n->value = seed + k;
    head = n;
    if (k % (NODES / ROUNDS) == 0) agc_gc_collect();
  }
  uint64_t expect = seed + NODES;
  for (const node *n = head; n; n = n->next) {
    if (n->value != --expect) atomic_store(&failed, true);
  }
  if (expect != seed) atomic_store(&failed, true);
}

static void work(void *arg) {
  if (!agc_gc_thread_enter()) {
    atomic_store(&failed, true);
    return;
  }
  build_and_check((uint64_t)(uintptr_t)arg * 1000000u);
  atomic_fetch_add(&finished, 1);
  agc_gc_thread_leave();
}

int main(void) {
  agc_init();
  agc_gc_allow_threads();
  uv_thread_t threads[THREADS];
  for (uintptr_t k = 0; k < THREADS; k++) assert(uv_thread_create(&threads[k], work, (void *)(k + 1)) == 0);
  build_and_check(0);
  for (size_t k = 0; k < THREADS; k++) assert(uv_thread_join(&threads[k]) == 0);
  assert(!atomic_load(&failed) && atomic_load(&finished) == THREADS);
  /* The collector still works for the main thread once the others have left. */
  build_and_check(7);
  agc_gc_collect();
  puts("gc thread tests passed");
  return 0;
}
