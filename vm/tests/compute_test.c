/*
 * The compute pool (vm/compute.c): items run in order on one thread, the pool grows to its size and no further, also in
 * a burst, every end comes back on the loop's thread, an idle pool lets the loop end, and a close drops what no thread
 * took and leaves a running item to its thread. Direct items, submitted from other threads, end on the pool thread and
 * keep the loop out of it.
 */
#include "../core.h"
#include "test_support.h"

#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <uv.h>

#define ITEMS 200
#define SIZE 3

static uv_thread_t loop_thread;
static int order[ITEMS], numbers[ITEMS];
static _Atomic int next_slot, inside, most_inside, ran;
static int finished;
static uv_sem_t gate;

static void on_loop_thread(void) {
  uv_thread_t self = uv_thread_self();
  assert(uv_thread_equal(&self, &loop_thread));
}

static void count_finished(void *item) {
  (void)item;
  on_loop_thread();
  finished++;
}

static void record(void *item) {
  order[atomic_fetch_add(&next_slot, 1)] = *(int *)item;
}

static void held(void *item) {
  (void)item;
  int now = atomic_fetch_add(&inside, 1) + 1;
  for (int seen = atomic_load(&most_inside); now > seen && !atomic_compare_exchange_weak(&most_inside, &seen, now);) {
  }
  uv_sem_wait(&gate);
  atomic_fetch_sub(&inside, 1);
  atomic_fetch_add(&ran, 1);
}

static void close_pool(uv_loop_t *loop, agc_compute *pool) {
  agc_compute_close(pool);
  assert(uv_run(loop, UV_RUN_DEFAULT) == 0);
  assert(uv_loop_close(loop) == 0);
}

/* A loop, a closed gate for `held` and a pool of `size` threads. */
static agc_compute *open_gated(uv_loop_t *loop, uint32_t size) {
  assert(uv_loop_init(loop) == 0);
  assert(uv_sem_init(&gate, 0) == 0);
  agc_compute *pool = agc_compute_open(loop, size, count_finished, NULL);
  assert(pool);
  return pool;
}

static void close_gated(uv_loop_t *loop, agc_compute *pool) {
  close_pool(loop, pool);
  uv_sem_destroy(&gate);
  finished = 0;
  atomic_store(&ran, 0);
}

/* One thread takes the items in the order they came. The loop runs until the last end is back, and then ends by itself:
   an idle pool keeps nothing alive. */
static void test_one_thread_keeps_the_order(void) {
  uv_loop_t loop;
  assert(uv_loop_init(&loop) == 0);
  agc_compute *pool = agc_compute_open(&loop, 1, count_finished, NULL);
  assert(pool);
  for (int k = 0; k < ITEMS; k++) {
    numbers[k] = k;
    assert(agc_compute_submit(pool, record, &numbers[k]));
  }
  assert(uv_run(&loop, UV_RUN_DEFAULT) == 0);
  assert(finished == ITEMS && atomic_load(&next_slot) == ITEMS);
  for (int k = 0; k < ITEMS; k++) assert(order[k] == k);
  close_pool(&loop, pool);
  finished = 0;
}

/* SIZE items that wait hold every thread; one more waits in the queue until a thread is free. */
static void test_the_pool_grows_to_its_size(void) {
  uv_loop_t loop;
  agc_compute *pool = open_gated(&loop, SIZE);
  for (int k = 0; k <= SIZE; k++) assert(agc_compute_submit(pool, held, NULL));
  while (atomic_load(&inside) < SIZE) agc_test_yield();
  uv_sleep(50);
  assert(atomic_load(&inside) == SIZE && atomic_load(&ran) == 0);
  for (int k = 0; k <= SIZE; k++) uv_sem_post(&gate);
  assert(uv_run(&loop, UV_RUN_DEFAULT) == 0);
  assert(finished == SIZE + 1 && atomic_load(&ran) == SIZE + 1 && atomic_load(&most_inside) == SIZE);
  close_gated(&loop, pool);
}

/* A burst behind one idle thread: a woken thread leaves `idle` only once it has the lock, so the items that come before
   then must still start threads, and SIZE items run at once. */
static void test_a_burst_starts_threads(void) {
  uv_loop_t loop;
  agc_compute *pool = open_gated(&loop, SIZE);
  numbers[0] = 0;
  atomic_store(&next_slot, 0);
  assert(agc_compute_submit(pool, record, &numbers[0]));
  assert(uv_run(&loop, UV_RUN_DEFAULT) == 0);
  for (int k = 0; k < SIZE; k++) assert(agc_compute_submit(pool, held, NULL));
  while (atomic_load(&inside) < SIZE) agc_test_yield();
  for (int k = 0; k < SIZE; k++) uv_sem_post(&gate);
  assert(uv_run(&loop, UV_RUN_DEFAULT) == 0);
  assert(finished == SIZE + 1 && atomic_load(&ran) == SIZE);
  close_gated(&loop, pool);
}

/* A close does not wait for an item inside its work: the item is never finished, the one behind it never runs, and the
   loop closes. The held thread is detached and stays blocked until the process ends. */
static void test_close_leaves_a_running_item(void) {
  uv_loop_t loop;
  agc_compute *pool = open_gated(&loop, 1);
  assert(agc_compute_submit(pool, held, NULL));
  assert(agc_compute_submit(pool, held, NULL));
  while (atomic_load(&inside) < 1) agc_test_yield();
  close_pool(&loop, pool);
  assert(finished == 0 && atomic_load(&ran) == 0 && atomic_load(&inside) == 1);
}

#define SUBMITTERS 4
#define DIRECT_EACH 500

static _Atomic int ended_direct;

static void not_on_loop_thread(void) {
  uv_thread_t self = uv_thread_self();
  assert(!uv_thread_equal(&self, &loop_thread));
}

static void direct_work(void *item) {
  (void)item;
  atomic_fetch_add(&ran, 1);
}

/* Under the pool's lock, on the pool thread, after the work. */
static void direct_ended(void *item) {
  (void)item;
  not_on_loop_thread();
  atomic_fetch_add(&ended_direct, 1);
}

static void submit_many(void *arg) {
  agc_compute *pool = arg;
  for (int k = 0; k < DIRECT_EACH; k++) assert(agc_compute_submit_direct(pool, direct_work, &numbers[k % ITEMS]));
}

/* Threads that are not the loop's submit at once: every item runs and ends on the pool, none comes back through the
   loop, which has nothing alive, and the pool is busy until the last end. A pool with no `ended` refuses them. */
static void test_direct_items_end_on_the_pool(void) {
  uv_loop_t loop;
  assert(uv_loop_init(&loop) == 0);
  agc_compute *plain = agc_compute_open(&loop, 1, count_finished, NULL);
  assert(plain && !agc_compute_submit_direct(plain, direct_work, &numbers[0]) && !agc_compute_direct_busy(plain));
  agc_compute_close(plain);
  agc_compute *pool = agc_compute_open(&loop, SIZE, count_finished, direct_ended);
  assert(pool);
  uv_thread_t threads[SUBMITTERS];
  for (int k = 0; k < SUBMITTERS; k++) assert(uv_thread_create(&threads[k], submit_many, pool) == 0);
  assert(uv_run(&loop, UV_RUN_DEFAULT) == 0);
  for (int k = 0; k < SUBMITTERS; k++) assert(uv_thread_join(&threads[k]) == 0);
  while (agc_compute_direct_busy(pool)) agc_test_yield();
  assert(atomic_load(&ended_direct) == SUBMITTERS * DIRECT_EACH && atomic_load(&ran) == SUBMITTERS * DIRECT_EACH);
  assert(finished == 0);
  close_pool(&loop, pool);
  atomic_store(&ran, 0);
}

int main(void) {
  agc_test_deadline(60);
  loop_thread = uv_thread_self();
  test_one_thread_keeps_the_order();
  test_the_pool_grows_to_its_size();
  test_a_burst_starts_threads();
  test_close_leaves_a_running_item();
  test_direct_items_end_on_the_pool();
  printf("compute: ok\n");
  return 0;
}
