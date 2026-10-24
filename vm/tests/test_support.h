#ifndef AGC_TEST_SUPPORT_H
#define AGC_TEST_SUPPORT_H

#include "../core.h"

#include <assert.h>
#include <string.h>
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

/* One struct S(x) and one enum E with variants v/1 and w/2, as a loaded program holds them, for tests that print
   records and enums through the runtime's program (TO_TEXT walks the defs before it formats the fields). All of the
   storage lives in the struct: point the runtime's program at program while the test runs, then restore it. */
typedef struct {
  agc_string *names[5];
  agc_string *fields[1];
  agc_struct_def structs[1];
  agc_enum_def enums[1];
  agc_variant_def variants[2];
  agc_program program;
} agc_test_shapes;

static inline void agc_test_shapes_init(agc_test_shapes *shapes) {
  shapes->names[0] = agc_make_string("S", 1, 1);
  shapes->names[1] = agc_make_string("x", 1, 1);
  shapes->names[2] = agc_make_string("E", 1, 1);
  shapes->names[3] = agc_make_string("v", 1, 1);
  shapes->names[4] = agc_make_string("w", 1, 1);
  shapes->fields[0] = shapes->names[1];
  shapes->structs[0].name = shapes->names[0];
  shapes->structs[0].count = 1;
  shapes->structs[0].fields = shapes->fields;
  shapes->structs[0].json_name = NULL;
  shapes->structs[0].field_types = NULL;
  shapes->enums[0].name = shapes->names[2];
  shapes->enums[0].first = 0;
  shapes->enums[0].count = 2;
  shapes->variants[0].name = shapes->names[3];
  shapes->variants[0].owner = 0;
  shapes->variants[0].arity = 1;
  shapes->variants[0].shared = NULL;
  shapes->variants[1].name = shapes->names[4];
  shapes->variants[1].owner = 0;
  shapes->variants[1].arity = 2;
  shapes->variants[1].shared = NULL;
  memset(&shapes->program, 0, sizeof shapes->program);
  shapes->program.struct_count = 1;
  shapes->program.structs = shapes->structs;
  shapes->program.enum_count = 1;
  shapes->program.enums = shapes->enums;
  shapes->program.variant_count = 2;
  shapes->program.variants = shapes->variants;
}

#endif
