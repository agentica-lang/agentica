/*
 * The compute pool (vm/compute.c): items run in order on one thread, the pool grows to its size and no further, every
 * end comes back on the loop's thread, an idle pool lets the loop end, and a close drops what no thread took and
 * leaves a running item to its thread.
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

/* One thread takes the items in the order they came. The loop runs until the last end is back, and then ends by itself:
   an idle pool keeps nothing alive. */
static void test_one_thread_keeps_the_order(void) {
  uv_loop_t loop;
  assert(uv_loop_init(&loop) == 0);
  agc_compute *pool = agc_compute_open(&loop, 1, count_finished);
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
  assert(uv_loop_init(&loop) == 0);
  assert(uv_sem_init(&gate, 0) == 0);
  agc_compute *pool = agc_compute_open(&loop, SIZE, count_finished);
  assert(pool);
  for (int k = 0; k <= SIZE; k++) assert(agc_compute_submit(pool, held, NULL));
  while (atomic_load(&inside) < SIZE) agc_test_yield();
  uv_sleep(50);
  assert(atomic_load(&inside) == SIZE && atomic_load(&ran) == 0);
  for (int k = 0; k <= SIZE; k++) uv_sem_post(&gate);
  assert(uv_run(&loop, UV_RUN_DEFAULT) == 0);
  assert(finished == SIZE + 1 && atomic_load(&ran) == SIZE + 1 && atomic_load(&most_inside) == SIZE);
  close_pool(&loop, pool);
  uv_sem_destroy(&gate);
  finished = 0;
  atomic_store(&ran, 0);
}

/* A close does not wait for an item inside its work: the item is never finished, the one behind it never runs, and the
   loop closes. The held thread stays blocked until the process ends, so it is never a finished thread left unjoined. */
static void test_close_leaves_a_running_item(void) {
  uv_loop_t loop;
  assert(uv_loop_init(&loop) == 0);
  assert(uv_sem_init(&gate, 0) == 0);
  agc_compute *pool = agc_compute_open(&loop, 1, count_finished);
  assert(pool);
  assert(agc_compute_submit(pool, held, NULL));
  assert(agc_compute_submit(pool, held, NULL));
  while (atomic_load(&inside) < 1) agc_test_yield();
  close_pool(&loop, pool);
  assert(finished == 0 && atomic_load(&ran) == 0 && atomic_load(&inside) == 1);
}

int main(void) {
  agc_test_deadline(60);
  loop_thread = uv_thread_self();
  test_one_thread_keeps_the_order();
  test_the_pool_grows_to_its_size();
  test_close_leaves_a_running_item();
  printf("compute: ok\n");
  return 0;
}
