/*
 * A job on the loop (docs/vm/16-architecture.md §16.5): the timer against the completion in both orders, a cancel, and
 * the requests that a second thread sends through the inbox (a queued START, a queued finish, the `more` path, close
 * and poll). The pool work is held by a semaphore, so the test and not the clock decides which event comes first.
 */
#include "../core.h"
#include "io_harness.h"
#include "test_abort.h"
#include "test_support.h"

#include <assert.h>
#include <setjmp.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <uv.h>
#ifndef _WIN32
#include <unistd.h>
#endif

#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
typedef struct {
  uv_sem_t entered, go;
  _Atomic int started, worked;
  int value;
} gate;

typedef struct {
  gate *g;
  int64_t timeout_ms;
} starting;

typedef struct {
  agc_task *task;
  int64_t result;
} finishing;

static int dropped, finished_calls, dropped_without_work, more_calls, idle_drops, swift_done_calls;
static agc_io_job *waiting_job;
static agc_vm vm;

static void gate_work(void *data) {
  gate *g = data;
  atomic_store_explicit(&g->started, 1, memory_order_release);
  uv_sem_post(&g->entered);
  uv_sem_wait(&g->go);
  g->value = 7;
  atomic_store_explicit(&g->worked, 1, memory_order_release);
}

static agc_value gate_done(agc_vm *vm, void *data, agc_value context) {
  gate *g = data;
  finished_calls++;
  int64_t value = g->value + agc_as_int(vm, context);
  uv_sem_destroy(&g->entered);
  uv_sem_destroy(&g->go);
  free(g);
  return agc_int(value);
}

static agc_value gate_expired(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)data;
  (void)context;
  return agc_int(-1);
}

/* Reached after the pool work and the timer are over, so a work that ran has written `value` already. A job whose START
   was dropped never ran its work. */
static void gate_drop(void *data) {
  gate *g = data;
  if (atomic_load_explicit(&g->started, memory_order_acquire))
    assert(g->value == 7);
  else
    dropped_without_work++;
  uv_sem_destroy(&g->entered);
  uv_sem_destroy(&g->go);
  free(g);
  dropped++;
}

static const agc_io_kind gate_io = {gate_work, gate_done, gate_expired, gate_drop, false, "gate", NULL, false, NULL};

/* The `done` half owns the data it is given, so it frees it; a job that is dropped or expired leaves it to `drop`. */
static agc_value idle_done(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)context;
  free(data);
  return agc_int(1);
}

static agc_value idle_expired(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)data;
  (void)context;
  return agc_int(-1);
}

static void idle_drop(void *data) {
  free(data);
  idle_drops++;
}

/* A wait on the loop that nothing ends: only its deadline does, so the job always expires. */
static const agc_io_kind idle_io = {NULL, idle_done, idle_expired, idle_drop, true, "idle", NULL, false, NULL};

static const agc_io_kind nap_io = {NULL, idle_done, idle_expired, NULL, true, "nap", NULL, false, NULL};

static void quick_work(void *data) {
  ((gate *)data)->value = 7;
}

static const agc_io_kind more_io = {quick_work, gate_done, gate_expired, gate_drop, false, "more", NULL, false, NULL};

static void swift_work(void *data) {
  *(int *)data = 1;
}

static agc_value swift_done(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)context;
  assert(*(int *)data == 1);
  free(data);
  swift_done_calls++;
  return agc_void();
}

static void swift_drop(void *data) {
  free(data);
}

/* Pool work that ends at once, for the many-jobs test. */
static const agc_io_kind swift_io = {swift_work, swift_done, swift_done, swift_drop, false, "swift", NULL, false, NULL};

static gate *new_gate(void) {
  gate *g = calloc(1, sizeof *g);
  assert(g && uv_sem_init(&g->entered, 0) == 0 && uv_sem_init(&g->go, 0) == 0);
  return g;
}

#define on_thread agc_test_on_thread

/* The task is running its turn, as a builtin sees it. */
static void running(void) {
  atomic_store(&vm.task->state, AGC_TASK_RUNNING);
}

/* The task parks as a builtin does: the job is its wait and the commit publishes PARKED. Nothing wakes it in between
   (the loop does not run), so the commit holds. */
static void park(agc_task *task) {
  assert(task->parked && task->parking);
  task->parking = false;
  assert(agc_task_commit_park(task));
}

static agc_task *park_on(gate *g, int64_t timeout_ms) {
  agc_task *task = vm.task;
  running();
  agc_io_start(&vm, &gate_io, g, agc_int(100), timeout_ms);
  park(task);
  return task;
}

static void wait_woken(agc_task *task) {
  while (task->state == AGC_TASK_PARKED) assert(agc_io_poll(&vm, true));
  while (agc_runq_pop(vm.rt->runq)) {}
}

static int64_t take(agc_task *task) {
  task->state = AGC_TASK_RUNNING;
  agc_value result = agc_io_finish(&vm, task);
  assert(!task->parked);
  return agc_as_int(&vm, result);
}

static void settle_loop(void) { agc_test_settle_loop(&vm); }

static void pump_until_idle(void) { agc_test_pump_until_idle(&vm); }

static uint64_t armed_timers(void) { return agc_test_armed_timers(&vm); }

/* The timer wins while the work is still blocked: the task takes the timeout and the job stays, because the work is
   still using its data. The work then ends: its end changes nothing, and the data is dropped once, after it finished. */
static void test_timer_before_completion(void) {
  gate *g = new_gate();
  agc_task *task = park_on(g, 1);
  uv_sem_wait(&g->entered);
  wait_woken(task);
  assert(take(task) == -1);
  assert(dropped == 0);
  uv_sem_post(&g->go);
  while (!atomic_load_explicit(&g->worked, memory_order_acquire)) {}
  settle_loop();
  assert(dropped == 1 && finished_calls == 0);
  dropped = 0;
}

/* The work ends first: the task gets the result, and a timer that fires before the task runs changes nothing. */
static void test_completion_before_timer(void) {
  gate *g = new_gate();
  uv_sem_post(&g->go);
  agc_task *task = park_on(g, 10);
  wait_woken(task);
  uint64_t due = agc_clock_ms() + 30;
  while (agc_clock_ms() < due) {}
  agc_io_poll(&vm, false);
  assert(take(task) == 107);
  settle_loop();
  assert(dropped == 0 && finished_calls == 1);
  finished_calls = 0;
}

/* A cancel sets the outcome to CANCELLED: a completion that comes later does not wake the task, and the detached
   ending takes the result and frees the job. */
static void test_cancel_before_completion(void) {
  gate *g = new_gate();
  agc_task *task = park_on(g, 60000);
  uv_sem_wait(&g->entered);
  agc_io_detach(&vm, task);
  uv_sem_post(&g->go);
  while (finished_calls == 0) assert(agc_io_poll(&vm, true));
  assert(task->state == AGC_TASK_PARKED && !task->parked);
  settle_loop();
  assert(finished_calls == 1 && dropped == 0);
  finished_calls = 0;
  task->state = AGC_TASK_RUNNING;
}

static void ready_later(void *arg) {
  agc_io_ready(arg);
}

/* Another thread ends the wait of a job that waits for a minute. The loop belongs to this thread once the inbox
   exists, so the request goes through the inbox, wakes the loop, and the job ends within the test's deadline.
   Without the request the job would wait a minute. */
static void test_request_from_another_thread(void) {
  assert(agc_io_share(&vm, false));
  agc_task *task = vm.task;
  running();
  agc_io_job *job = agc_io_start(&vm, &nap_io, NULL, agc_void(), 60000);
  park(task);
  uv_thread_t thread;
  assert(uv_thread_create(&thread, ready_later, job) == 0);
  wait_woken(task);
  assert(uv_thread_join(&thread) == 0);
  assert(take(task) == 1);
  settle_loop();
}

static void start_gated(void *arg) {
  starting *s = arg;
  running();
  agc_io_start(&vm, &gate_io, s->g, agc_int(100), s->timeout_ms);
}

/* A scheduler's START is still in the inbox when the task is resumed by something else (a PENDING resume) and ends
   the job on the loop's thread: the CLOSE_TIMER and the RELEASE run at once, before the START. The START must then
   start nothing: no timer, no pool work, and the count it carried goes back, so the data is dropped once and the
   loop has nothing alive. A START that started its timer anyway would leave a live timer and a job nobody frees. */
static void test_start_queued_then_ended_inline(void) {
  assert(agc_io_share(&vm, false));
  agc_task *task = vm.task;
  starting s = {new_gate(), 60000};
  on_thread(start_gated, &s);
  park(task);
  assert(armed_timers() == 0 && dropped == 0);
  assert(take(task) == -1);
  assert(dropped == 0);
  agc_io_poll(&vm, false);
  assert(!uv_loop_alive(agc_io_uv(&vm)) && armed_timers() == 0);
  settle_loop();
  assert(dropped == 1 && dropped_without_work == 1);
  dropped = dropped_without_work = 0;
}

static void finish_on_thread(void *arg) {
  finishing *f = arg;
  f->result = take(f->task);
}

/* The task ends its job from a scheduler's thread, resumed with the outcome still PENDING: the outcome becomes
   EXPIRED, the timer close and the release are requests that wait in the inbox (nothing is freed on that thread), and
   the loop's thread then runs them. With the timer closed and the work over, the loop has nothing alive. */
static void test_finish_from_another_thread(void) {
  assert(agc_io_share(&vm, false));
  gate *g = new_gate();
  agc_task *task = park_on(g, 60000);
  finishing f = {task, 0};
  on_thread(finish_on_thread, &f);
  assert(f.result == -1);
  assert(armed_timers() == 1 && dropped == 0);
  uv_sem_post(&g->go);
  pump_until_idle();
  settle_loop();
  assert(dropped == 1 && finished_calls == 0);
  dropped = 0;
}

static bool keep_waiting(void *data, agc_io_job *job) {
  (void)data;
  more_calls++;
  waiting_job = job;
  return true;
}

static void start_waiting(void) {
  running();
  agc_io_start_then(&vm, &more_io, new_gate(), agc_int(100), 60000, keep_waiting);
  park(vm.task);
}

/* The `more` step keeps the job waiting on the loop after its pool work; agc_io_ready ends the wait, and the task
   then gets the result of the work. */
static void test_more_keeps_the_wait(void) {
  agc_task *task = vm.task;
  start_waiting();
  while (more_calls == 0) assert(agc_io_poll(&vm, true));
  assert(task->state == AGC_TASK_PARKED);
  agc_io_ready(waiting_job);
  wait_woken(task);
  assert(take(task) == 107);
  settle_loop();
  assert(finished_calls == 1);
  finished_calls = more_calls = 0;
}

static bool wait_started, pause_saw_wait;

static bool start_wait(void *data, agc_io_job *job) {
  (void)data;
  (void)job;
  wait_started = true;
  return true;
}

static void pause_idle(void *data) {
  (void)data;
  pause_saw_wait = wait_started;
}

/* A wait on the loop whose deadline stops it (`pause`) before EXPIRED is published. */
static const agc_io_kind paused_io = {NULL, idle_done, idle_expired, idle_drop, true, "paused", NULL, false,
                                      pause_idle};

static void start_paused(void *arg) {
  (void)arg;
  running();
  int *data = malloc(sizeof *data);
  assert(data);
  agc_io_start_then(&vm, &paused_io, data, agc_void(), 0, start_wait);
}

/* A scheduler starts a wait on the loop with a deadline of 0 ms. Its `more` step starts the wait in the job's START
   on the loop's thread, before the timer is armed, so the timer, which can only fire after that request, always
   finds the wait started and pauses it. A wait started by a second request could come after the deadline, and its
   callback could then run beside `expired`. */
static void test_wait_starts_before_its_deadline(void) {
  assert(agc_io_share(&vm, false));
  agc_task *task = vm.task;
  wait_started = pause_saw_wait = false;
  on_thread(start_paused, NULL);
  park(task);
  assert(!wait_started);
  wait_woken(task);
  assert(wait_started && pause_saw_wait);
  assert(take(task) == -1);
  settle_loop();
  assert(idle_drops == 1);
  idle_drops = 0;
}

/* The task gives up the wait on the loop (resumed with the outcome PENDING) and its releases are queued; a service
   callback then ends the wait late. Only the one that clears `busy` owns the wait piece's count, so the late end must
   change nothing: with a second drop the job would be freed while the ready list still names it. */
static void test_late_end_after_abandon(void) {
  assert(agc_io_share(&vm, false));
  agc_task *task = vm.task;
  start_waiting();
  while (more_calls == 0) assert(agc_io_poll(&vm, true));
  finishing f = {task, 0};
  on_thread(finish_on_thread, &f);
  assert(f.result == -1);
  agc_io_ready(waiting_job);
  pump_until_idle();
  settle_loop();
  assert(dropped == 1 && finished_calls == 0);
  dropped = dropped_without_work = finished_calls = more_calls = 0;
}

static void start_idle(void *arg) {
  running();
  agc_io_start(&vm, &idle_io, arg, agc_void(), 60000);
}

/* A request still in the inbox when the run ends holds a count that only its handler gives back: closing the loop
   runs it first. The START here starts a timer that the close then closes; the job and its data are freed. */
static void test_close_runs_queued_requests(void) {
  assert(agc_io_share(&vm, false));
  agc_task *task = vm.task;
  int *data = calloc(1, sizeof *data);
  assert(data);
  on_thread(start_idle, data);
  park(task);
  settle_loop();
  assert(idle_drops == 1);
  idle_drops = 0;
  task->state = AGC_TASK_RUNNING;
  task->parked = NULL;
}

static void start_short(void *arg) {
  running();
  agc_io_start(&vm, &idle_io, arg, agc_void(), 50);
}

/* An inbox that does not keep the loop alive makes a loop with nothing else look idle: a poll must still run the
   requests queued in it, or the START below would wait for ever. */
static void test_poll_runs_queued_requests(void) {
  assert(agc_io_share(&vm, false));
  agc_task *task = vm.task;
  int *data = calloc(1, sizeof *data);
  assert(data);
  on_thread(start_short, data);
  park(task);
  assert(!uv_loop_alive(agc_io_uv(&vm)));
  assert(agc_io_poll(&vm, false));
  wait_woken(task);
  assert(take(task) == -1);
  settle_loop();
  assert(idle_drops == 1);
  idle_drops = 0;
}

/* A scheduler's thread starts a job that expires at once (a deadline of zero) and commits the park as the scheduler does:
   it records its task before it posts the START, so the wake always finds it. The loop's thread polls meanwhile; a
   lost wake leaves the task parked for ever, and the deadline of the test ends the process. */
static void start_instant(void *arg) {
  (void)arg;
  agc_io_start(&vm, &nap_io, NULL, agc_void(), 0);
  vm.task->parking = false;
  if (!agc_task_commit_park(vm.task)) {
    atomic_store(&vm.task->state, AGC_TASK_READY);
    agc_runq_push(vm.rt->runq, vm.task);
  }
}

static void test_instant_job_wakes_its_task(void) {
  assert(agc_io_share(&vm, false));
  agc_task *task = vm.task;
  for (int round = 0; round < 2000; round++) {
    task->state = AGC_TASK_RUNNING;
    on_thread(start_instant, NULL);
    agc_task *woken;
    while (!(woken = agc_runq_pop(vm.rt->runq))) agc_io_poll(&vm, false);
    assert(woken == task);
    assert(take(task) == -1);
  }
  settle_loop();
}

#define MANY_JOBS 20000

/* Many jobs end in one run: each ending sweeps, and a sweep must cost what ended and not what is alive (it once
   scanned the whole registry, so MANY_JOBS endings cost MANY_JOBS squared steps). Every job's `done` runs once, its
   data is freed once, and the registry is empty at the close. */
static void test_many_jobs_end(void) {
  for (int k = 0; k < MANY_JOBS; k++) {
    int *data = calloc(1, sizeof *data);
    assert(data);
    agc_io_detached(&vm, &swift_io, data, agc_void(), AGC_JOB_QUIET);
  }
  while (swift_done_calls < MANY_JOBS) assert(agc_io_poll(&vm, true));
  settle_loop();
  assert(swift_done_calls == MANY_JOBS);
  swift_done_calls = 0;
}
static uv_thread_t done_thread;

/* The `done` half records the thread that runs it. */
static agc_value where_done(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)context;
  free(data);
  done_thread = uv_thread_self();
  swift_done_calls++;
  return agc_void();
}

static const agc_io_kind where_io = {swift_work, where_done, where_done, swift_drop, false, "where", NULL, false, NULL};

static void start_detached(void *arg) {
  agc_io_detached(&vm, &where_io, arg, agc_void(), AGC_JOB_QUIET);
}

static void service_on_thread(void *arg) {
  (void)arg;
  agc_test_service(&vm);
}

/* A detached job that finishes while a second thread runs the schedulers is ended by a scheduler: the I/O role finds it
   ready, queues it and nudges the run queue, and `done` runs on the thread that services (agc_io_service), never on the
   loop's thread. The nudge ends an idle wait with NULL and one caller takes it. */
static void test_detached_ends_on_a_scheduler(void) {
  assert(agc_io_share(&vm, false));
  agc_runq_share(vm.rt->runq);
  uv_thread_t loop_thread = uv_thread_self();
  int *data = calloc(1, sizeof *data);
  assert(data);
  swift_done_calls = 0;
  on_thread(start_detached, data);
  while (!agc_runq_nudged(vm.rt->runq)) assert(agc_io_poll(&vm, true));
  assert(swift_done_calls == 0);
  assert(agc_runq_wait(vm.rt->runq) == NULL);
  assert(agc_runq_take_nudge(vm.rt->runq) && !agc_runq_take_nudge(vm.rt->runq));
  on_thread(service_on_thread, NULL);
  assert(swift_done_calls == 1 && !uv_thread_equal(&done_thread, &loop_thread));
  pump_until_idle();
  settle_loop();
}

static void wait_for_hand_over(void) { agc_test_wait_for_hand_over(&vm); }

static void start_then_cancel(void *arg) {
  start_gated(arg);
  agc_io_detach(&vm, vm.task);
}

/* A cancelled task's START and DETACH are still in the inbox when the run ends, and agc_io_goodbye runs them. The
   START must start nothing (no pool work, no timer): work begun after main returned could truncate a file before the
   exit. The job then ends as dropped, without `done`. A START with no task (an output or flush job) still runs. */
static void test_task_start_after_the_run_is_over(void) {
  assert(agc_io_share(&vm, false));
  agc_runq_share(vm.rt->runq);
  agc_task *task = vm.task;
  starting s = {new_gate(), 60000};
  on_thread(start_then_cancel, &s);
  task->parking = false;
  task->state = AGC_TASK_RUNNING;
  atomic_store(&vm.rt->over, true);
  agc_io_goodbye(&vm);
  assert(!uv_loop_alive(agc_io_uv(&vm)) && armed_timers() == 0);
  int *data = calloc(1, sizeof *data);
  assert(data);
  swift_done_calls = 0;
  on_thread(start_detached, data);
  agc_io_goodbye(&vm);
  pump_until_idle();
  wait_for_hand_over();
  on_thread(service_on_thread, NULL);
  pump_until_idle();
  settle_loop();
  assert(dropped == 1 && dropped_without_work == 1 && finished_calls == 0 && swift_done_calls == 1);
  dropped = dropped_without_work = swift_done_calls = 0;
  atomic_store(&vm.rt->over, false);
}

/* A detached job that is ready twice before a scheduler takes it: its timer fires and it is handed over, then its work
   ends and the drain finds it again, with another job listed behind it. It stays listed once (a second link would cut
   the list and lose that job), the second ready-list count goes back, each `done` runs once, and the loop closes with
   an empty registry. */
static void test_job_ready_twice_is_listed_once(void) {
  assert(agc_io_share(&vm, false));
  gate *g = new_gate();
  agc_task *task = park_on(g, 5);
  uv_sem_wait(&g->entered);
  task->state = AGC_TASK_RUNNING;
  agc_io_detach(&vm, task);
  wait_for_hand_over();
  /* A second job behind it, so a second link of the first would cut the list here. */
  swift_done_calls = 0;
  int *data = calloc(1, sizeof *data);
  assert(data);
  on_thread(start_detached, data);
  wait_for_hand_over();
  uv_sem_post(&g->go);
  pump_until_idle();
  assert(finished_calls == 0 && swift_done_calls == 0);
  on_thread(service_on_thread, NULL);
  assert(finished_calls == 1 && swift_done_calls == 1 && dropped == 0);
  pump_until_idle();
  settle_loop();
  agc_resource *probe = agc_register(&vm, NULL, NULL);
  assert(probe->slot == 0);
  agc_unregister(&vm, probe);
  finished_calls = swift_done_calls = 0;
}

static int counted_done, counted_drop;
static uv_thread_t counted_drop_thread;

static agc_value counted_done_half(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)context;
  free(data);
  counted_done++;
  return agc_int(1);
}

static agc_value counted_expired(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)data;
  (void)context;
  return agc_int(-1);
}

static void counted_drop_half(void *data) {
  free(data);
  counted_drop_thread = uv_thread_self();
  counted_drop++;
}

/* Stops the wait only at its deadline, as a request whose send cannot be taken back does. */
static bool cancel_at_deadline(agc_vm *vm, void *data, agc_value context, bool deadline) {
  (void)vm;
  (void)data;
  (void)context;
  return deadline;
}

static const agc_io_kind counted_io = {NULL,  counted_done_half, counted_expired, counted_drop_half, true, "counted",
                                       NULL,  false,             NULL};
static const agc_io_kind deadline_cancel_io = {NULL,  counted_done_half, counted_expired, counted_drop_half,
                                               true,  "deadline",        cancel_at_deadline, false, NULL};

static agc_task *to_detach;

static void detach_on_thread(void *arg) {
  (void)arg;
  agc_io_detach(&vm, to_detach);
}

/* Runs inside uv_run: a scheduler detaches the job after this pass's requests ran and before its drain. */
static void detach_during_run(uv_timer_t *timer) {
  on_thread(detach_on_thread, NULL);
  uv_close((uv_handle_t *)timer, NULL);
}

/* A job whose wait is over sits on the ready list when a scheduler detaches it. The drain of that pass finds it
   detached before its DETACH request ran and leaves it alone; the request then puts it back on the list, it is handed
   to a scheduler, and it ends once: `done` runs (the outcome was DONE first), `drop` never. */
static void test_detach_from_a_scheduler_while_ready(void) {
  assert(agc_io_share(&vm, false));
  agc_task *task = vm.task;
  running();
  int *data = malloc(sizeof *data);
  assert(data);
  agc_io_job *job = agc_io_start(&vm, &counted_io, data, agc_void(), -1);
  park(task);
  agc_io_ready(job);
  task->state = AGC_TASK_RUNNING;
  to_detach = task;
  static uv_timer_t timer;
  assert(uv_timer_init(agc_io_uv(&vm), &timer) == 0);
  assert(uv_timer_start(&timer, detach_during_run, 0, 0) == 0);
  counted_done = counted_drop = 0;
  assert(agc_io_poll(&vm, false));
  assert(counted_done == 0 && counted_drop == 0 && !task->parked);
  wait_for_hand_over();
  on_thread(service_on_thread, NULL);
  assert(counted_done == 1 && counted_drop == 0);
  pump_until_idle();
  settle_loop();
  assert(counted_done == 1 && counted_drop == 0);
}

/* A detached job on a shared loop whose deadline passes while it still waits: a scheduler ends it (agc_io_service),
   finds it busy, and posts its deadline cancel (EXPIRE_CANCEL) instead of ending it. The I/O thread runs the cancel,
   which stops the wait, and puts the job back on the ready list; a scheduler then ends it and posts its `drop`, which
   runs once on the I/O thread (§16.5: what the data reaches, such as a socket, belongs to that thread). */
static void test_expire_cancel_from_a_scheduler(void) {
  assert(agc_io_share(&vm, false));
  agc_runq_share(vm.rt->runq);
  uv_thread_t loop_thread = uv_thread_self();
  agc_task *task = vm.task;
  running();
  int *data = malloc(sizeof *data);
  assert(data);
  (void)agc_io_start(&vm, &deadline_cancel_io, data, agc_void(), 5);
  park(task);
  task->state = AGC_TASK_RUNNING;
  agc_io_detach(&vm, task);
  counted_done = counted_drop = 0;
  wait_for_hand_over();
  on_thread(service_on_thread, NULL);
  assert(counted_done == 0 && counted_drop == 0);
  wait_for_hand_over();
  on_thread(service_on_thread, NULL);
  assert(counted_done == 0 && counted_drop == 0);
  while (counted_drop == 0) assert(agc_io_poll(&vm, true));
  assert(counted_drop == 1 && uv_thread_equal(&counted_drop_thread, &loop_thread));
  pump_until_idle();
  settle_loop();
  assert(counted_drop == 1);
}

/* The `done` half of the first job raises, as a failing builtin would. */
static agc_value raising_done(agc_vm *vm, void *data, agc_value context) {
  (void)context;
  free(data);
  agc_fail(vm, "RUNTIME-INTERNAL", "done raised", 0);
}

static const agc_io_kind raising_io = {swift_work, raising_done, raising_done, swift_drop, false, "raise", NULL, false, NULL};

static void start_raising(void *arg) {
  agc_io_detached(&vm, &raising_io, arg, agc_void(), AGC_JOB_QUIET);
}

static int service_raised;
static agc_task *task_after_raise;

static void service_raising(void *arg) {
  agc_task *before = arg;
  if (setjmp(vm.fail) == 0) {
    (void)agc_io_service(&vm);
    assert(!"the raising done did not raise");
  }
  service_raised++;
  task_after_raise = vm.task;
  agc_sync_reset(&vm);
  vm.task = before;
  /* The job after the one that raised is still on the list, and the next call ends it. */
  assert(swift_done_calls == 0);
  assert(agc_io_service(&vm) && swift_done_calls == 1);
  assert(!agc_io_service(&vm));
}

/* A `done` that raises on a scheduler: the jobs after it stay on the service list for the next call, every reference
   goes back (the loop closes with an empty registry), and vm->task never points at a dead frame. */
static void test_raising_done_on_a_scheduler(void) {
  assert(agc_io_share(&vm, false));
  int *first = calloc(1, sizeof *first), *second = calloc(1, sizeof *second);
  assert(first && second);
  swift_done_calls = 0;
  on_thread(start_raising, first);
  wait_for_hand_over();
  on_thread(start_detached, second);
  wait_for_hand_over();
  agc_task *before = vm.task;
  on_thread(service_raising, before);
  assert(service_raised == 1 && task_after_raise && task_after_raise != before);
  pump_until_idle();
  settle_loop();
}

static int left_drops;

static void left_drop(void *data) {
  free(data);
  left_drops++;
}

static const agc_io_kind left_io = {swift_work, where_done, where_done, left_drop, false, "left", NULL, false, NULL};

static void start_left(void *arg) {
  agc_io_detached(&vm, &left_io, arg, agc_void(), AGC_JOB_QUIET);
}

/* A detached job handed to a scheduler that never services it, because the run ends first: the close gives back the
   count that the service list holds, `drop` frees the data once, `done` never runs, and the registry ends empty. */
static void test_unserviced_job_is_freed_at_the_close(void) {
  assert(agc_io_share(&vm, false));
  int *data = calloc(1, sizeof *data);
  assert(data);
  swift_done_calls = 0;
  on_thread(start_left, data);
  wait_for_hand_over();
  settle_loop();
  assert(left_drops == 1 && swift_done_calls == 0);
  /* An empty registry gives the next resource slot 0. */
  agc_resource *probe = agc_register(&vm, NULL, NULL);
  assert(probe->slot == 0);
  agc_unregister(&vm, probe);
}

#define GUARDED_JOBS 4

/* Stands for the shared state of the tasks (a waiter list, the task tree): changed only with rt->sync held. */
static int guarded;
static _Atomic bool hammering, hammer_started;

static agc_value guarded_done(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)context;
  free(data);
  guarded++;
  swift_done_calls++;
  return agc_void();
}

static const agc_io_kind guarded_io = {swift_work, guarded_done, guarded_done, swift_drop, false, "guarded", NULL,
                                       false, NULL};

static void start_guarded(void *arg) {
  agc_io_detached(&vm, &guarded_io, arg, agc_void(), AGC_JOB_QUIET);
}

/* Another scheduler changes the same state under the lock until told to stop. It says it started before its first
   change, so no change of it is ordered before the service by that flag. */
static void hammer(void *arg) {
  agc_vm *other = arg;
  assert(agc_gc_thread_enter());
  atomic_store(&hammer_started, true);
  while (atomic_load(&hammering)) {
    agc_sync_take(other);
    guarded++;
    agc_sync_drop(other);
  }
  agc_gc_thread_leave();
}

static void service_all(void *arg) {
  (void)arg;
  assert(agc_io_service(&vm));
}

/* The `done` of a detached job changes the shared state of the tasks, so agc_io_service runs it with rt->sync held:
   make vm-tsan reports a race here if it did not, since another scheduler changes the same state under the lock. */
static void test_service_holds_sync(void) {
  agc_share(&vm);
  assert(agc_io_share(&vm, false));
  agc_vm other = vm;
  other.sync_depth = 0;
  swift_done_calls = 0;
  for (int k = 0; k < GUARDED_JOBS; k++) {
    int *data = calloc(1, sizeof *data);
    assert(data);
    on_thread(start_guarded, data);
    wait_for_hand_over();
  }
  atomic_store(&hammering, true);
  uv_thread_t thread;
  assert(uv_thread_create(&thread, hammer, &other) == 0);
  while (!atomic_load(&hammer_started)) {}
  on_thread(service_all, NULL);
  atomic_store(&hammering, false);
  assert(uv_thread_join(&thread) == 0);
  assert(swift_done_calls == GUARDED_JOBS);
  /* Read after the join: every change is in, and newer clang refuses a global that is only written. */
  assert(guarded >= GUARDED_JOBS);
  pump_until_idle();
  settle_loop();
}

static const agc_io_kind timer_only_io = {NULL, idle_done, idle_expired, NULL, false, "timer", NULL, false, NULL};

/* A kind with no work and no wait would be a bare deadline, which is a task timer: start_job refuses it before it
   registers anything. */
static void test_timer_only_kind_is_refused(void) {
  running();
  agc_task *task = vm.task;
  if (setjmp(vm.fail) == 0) {
    (void)agc_io_start(&vm, &timer_only_io, NULL, agc_void(), 5);
    assert(!"a timer-only kind was started");
  }
  assert(!task->parked);
  task->parking = false;
  settle_loop();
}

#ifndef _WIN32
static void nothing(void *data) { (void)data; }

static void call_after_close(void *arg) {
  (void)arg;
  agc_io_call(&vm, nothing, NULL);
}

/* Child process: closes the inbox while a job is still held by its pool work, then a second thread posts to it. */
static void post_after_close_child(void) {
  agc_init();
  agc_gc_allow_threads();
  agc_io_init();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  assert(agc_io_share(&vm, false));
  gate *g = new_gate();
  running();
  agc_io_job *job = agc_io_start(&vm, &gate_io, g, agc_int(1), 60000);
  vm.task->parking = false;
  uv_sem_wait(&g->entered);
  assert(!agc_io_close(&vm));
  on_thread(call_after_close, job);
}

/* A post from another thread after agc_inbox_close has no consumer: it must end the process loudly (SIGABRT), not run
   inline or vanish; the child's message must say so, so an abort for another reason fails the test. It runs in a
   child, first of all, before any thread exists in this process. */
static void test_post_after_close_is_loud(void) {
  agc_test_aborts_with(post_after_close_child, "a request was posted to the I/O thread after the loop closed");
}
#endif

#endif

int main(void) {
  agc_test_deadline(120);
#if defined(__linux__) || defined(__APPLE__)
  test_post_after_close_is_loud();
#endif
#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
  agc_init();
  agc_gc_allow_threads();
  agc_io_init();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  test_timer_before_completion();
  test_completion_before_timer();
  test_cancel_before_completion();
  test_request_from_another_thread();
  test_start_queued_then_ended_inline();
  test_finish_from_another_thread();
  test_more_keeps_the_wait();
  test_wait_starts_before_its_deadline();
  test_late_end_after_abandon();
  test_close_runs_queued_requests();
  test_poll_runs_queued_requests();
  test_instant_job_wakes_its_task();
  test_many_jobs_end();
  test_detached_ends_on_a_scheduler();
  test_task_start_after_the_run_is_over();
  test_job_ready_twice_is_listed_once();
  test_detach_from_a_scheduler_while_ready();
  test_expire_cancel_from_a_scheduler();
  test_raising_done_on_a_scheduler();
  test_unserviced_job_is_freed_at_the_close();
  test_timer_only_kind_is_refused();
  test_service_holds_sync();
#endif
  puts("job tests passed");
  return 0;
}
