/*
 * The set-once outcome and the reference count of a job (docs/vm/16-architecture.md §16.5, rules 2 to 4), under threads:
 * racing writers get exactly one winner whose data every reader sees, and exactly one holder drops the last reference.
 */
#include "../core.h"
#include "test_support.h"

#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <uv.h>

#define RACERS 3
#define ROUNDS 20000
#define COUNTERS 4
#define COUNTER_ROUNDS 5000

static _Atomic int outcomes[ROUNDS];
static int payload[ROUNDS][RACERS + 1];
static _Atomic int wins[ROUNDS];
static _Atomic int go, entered, observed;

static void spin(int n) {
  for (volatile int k = 0; k < n; k++) {}
}

/* Three threads set a different outcome of the same round. Each writes its own payload slot first, so a reader that
   sees an outcome through the acquire load must also see the payload of the thread that set it. */
static void racer(void *arg) {
  int self = (int)(uintptr_t)arg;
  agc_job_outcome value = (agc_job_outcome)(self + 1);
  for (int round = 0; round < ROUNDS; round++) {
    while (atomic_load_explicit(&go, memory_order_acquire) <= round) {}
    spin((round * 7 + self * 11) % 37);
    payload[round][value] = round * 10 + (int)value;
    if (agc_job_settle(&outcomes[round], value)) atomic_fetch_add(&wins[round], 1);
    atomic_fetch_add_explicit(&entered, 1, memory_order_release);
  }
}

static void watcher(void *arg) {
  (void)arg;
  for (int round = 0; round < ROUNDS; round++) {
    agc_job_outcome seen;
    while ((seen = agc_job_outcome_of(&outcomes[round])) == AGC_JOB_PENDING) {}
    assert(payload[round][seen] == round * 10 + (int)seen);
    atomic_store_explicit(&observed, round + 1, memory_order_release);
  }
}

static void test_outcome_is_set_once(void) {
  uv_thread_t racers[RACERS], observer;
  for (uintptr_t k = 0; k < RACERS; k++) assert(uv_thread_create(&racers[k], racer, (void *)k) == 0);
  assert(uv_thread_create(&observer, watcher, NULL) == 0);
  for (int round = 0; round < ROUNDS; round++) {
    atomic_store_explicit(&go, round + 1, memory_order_release);
    while (atomic_load_explicit(&entered, memory_order_acquire) < (round + 1) * RACERS) {}
    assert(atomic_load(&wins[round]) == 1);
    assert(agc_job_outcome_of(&outcomes[round]) != AGC_JOB_PENDING);
  }
  for (size_t k = 0; k < RACERS; k++) assert(uv_thread_join(&racers[k]) == 0);
  assert(uv_thread_join(&observer) == 0);
  assert(atomic_load(&observed) == ROUNDS);
}

static _Atomic int refs;
static _Atomic int lasts;
static int uses[COUNTERS];

/* The count starts at one reference for each thread. Every thread takes and gives back references, records its own
   uses, and gives back the one it was born with. Exactly one thread drops the last, and that thread sees every use. */
static void counter(void *arg) {
  int self = (int)(uintptr_t)arg;
  for (int k = 0; k < COUNTER_ROUNDS; k++) {
    agc_job_ref(&refs);
    uses[self]++;
    assert(!agc_job_unref(&refs));
  }
  if (agc_job_unref(&refs)) {
    atomic_fetch_add(&lasts, 1);
    for (int t = 0; t < COUNTERS; t++) assert(uses[t] == COUNTER_ROUNDS);
  }
}

static void test_last_reference(void) {
  atomic_store(&refs, COUNTERS);
  uv_thread_t threads[COUNTERS];
  for (uintptr_t k = 0; k < COUNTERS; k++) assert(uv_thread_create(&threads[k], counter, (void *)k) == 0);
  for (size_t k = 0; k < COUNTERS; k++) assert(uv_thread_join(&threads[k]) == 0);
  assert(atomic_load(&lasts) == 1 && atomic_load(&refs) == 0);
}

int main(void) {
  agc_test_deadline(120);
  test_outcome_is_set_once();
  test_last_reference();
  puts("outcome tests passed");
  return 0;
}
