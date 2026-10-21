#ifndef AGC_TEST_SUPPORT_H
#define AGC_TEST_SUPPORT_H

#include "../core.h"

#include <assert.h>
#ifndef _WIN32
#include <sched.h>
#include <unistd.h>
#else
#include <uv.h>
#endif

/* A broken park or wake path leaves a test waiting for ever instead of failing it. The deadline ends the process with
   SIGALRM's default action, so `make vm-test` fails. Windows has no alarm; its job has the time limit of the CI step. */
#ifndef _WIN32
static inline void agc_test_deadline(unsigned seconds) { alarm(seconds); }
#else
static inline void agc_test_deadline(unsigned seconds) { (void)seconds; }
#endif

/* The body of a busy wait between threads that wait for each other in turn. When they outnumber the free cores (a
   macOS ARM runner has three, shared by the C tests that `make vm-test` runs side by side), a waiter that spins through
   its time slice keeps the thread it waits for off the core, and each turn costs a slice: a test of many turns then
   meets its deadline. Giving the core away lets the other thread run at once. */
static inline void agc_test_yield(void) {
#ifndef _WIN32
  (void)sched_yield();
#else
  uv_sleep(0);
#endif
}

/* The first ready task, left in the queue: it pops every task and pushes them back in order. For tests that run on
   one thread. */
static inline agc_task *agc_test_ready_head(agc_runq *q) {
  agc_task *all[64];
  size_t n = 0;
  for (agc_task *t; n < sizeof all / sizeof all[0] && (t = agc_runq_pop(q));) all[n++] = t;
  for (size_t k = 0; k < n; k++) agc_runq_push(q, all[k]);
  return n ? all[0] : NULL;
}

#endif
