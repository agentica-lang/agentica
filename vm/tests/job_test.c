/*
 * A job on the loop (docs/vm/16-architecture.md §16.5): the timer against the completion in both orders, a cancel, and
 * the requests that a second thread sends through the inbox (a queued START, a queued finish, the `more` path, close
 * and poll). The pool work is held by a semaphore, so the test and not the clock decides which event comes first.
 */
#include "../core.h"
#include "test_support.h"

#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <uv.h>
#ifndef _WIN32
#include <fcntl.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
typedef struct {
  uv_sem_t entered, go;
  _Atomic int started, worked;
  int value;
} gate;

/* What a second thread runs, with the registration the garbage collector needs. */
typedef struct {
  void (*fn)(void *arg);
  void *arg;
} hop;

typedef struct {
  gate *g;
  int64_t timeout_ms;
} starting;

typedef struct {
  agc_task *task;
  int64_t result;
} finishing;

static int dropped, finished_calls, dropped_without_work, more_calls, idle_drops, swift_done_calls;
static agc_io_job *waiting_job, *last_job;
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

static const agc_io_kind gate_io = {gate_work, gate_done, gate_expired, gate_drop, false, "gate", NULL, false};

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

/* A timer only: the timer is its one piece. */
static const agc_io_kind idle_io = {NULL, idle_done, idle_expired, idle_drop, false, "idle", NULL, false};

static const agc_io_kind nap_io = {NULL, idle_done, idle_expired, NULL, false, "nap", NULL, false};

static void quick_work(void *data) {
  ((gate *)data)->value = 7;
}

static const agc_io_kind more_io = {quick_work, gate_done, gate_expired, gate_drop, false, "more", NULL, false};

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
static const agc_io_kind swift_io = {swift_work, swift_done, swift_done, swift_drop, false, "swift", NULL, false};

static gate *new_gate(void) {
  gate *g = calloc(1, sizeof *g);
  assert(g && uv_sem_init(&g->entered, 0) == 0 && uv_sem_init(&g->go, 0) == 0);
  return g;
}

static void hop_main(void *arg) {
  hop *h = arg;
  assert(agc_gc_thread_enter());
  h->fn(h->arg);
  agc_gc_thread_leave();
}

/* Runs FN on a second thread and waits for it: the thread plays a scheduler, and the loop's thread (the caller) does
   not touch the VM meanwhile. */
static void on_thread(void (*fn)(void *arg), void *arg) {
  hop h = {fn, arg};
  uv_thread_t thread;
  assert(uv_thread_create(&thread, hop_main, &h) == 0);
  assert(uv_thread_join(&thread) == 0);
}

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
  last_job = agc_io_start(&vm, &gate_io, g, agc_int(100), timeout_ms);
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

static void settle_loop(void) {
  bool closed = false;
  for (int attempt = 0; attempt < 500 && !closed; attempt++) closed = agc_io_close(&vm);
  assert(closed && vm.rt->loop == NULL);
}

static void pump_until_idle(void) {
  while (uv_loop_alive(agc_io_uv(&vm))) (void)agc_io_poll(&vm, true);
}

static void count_timers(uv_handle_t *handle, void *arg) {
  if (handle->type == UV_TIMER && uv_is_active(handle)) *(uint64_t *)arg += 1;
}

/* How many job timers are armed on the loop. */
static uint64_t armed_timers(void) {
  uint64_t count = 0;
  uv_walk(agc_io_uv(&vm), count_timers, &count);
  return count;
}

static void longest_due(uv_handle_t *handle, void *arg) {
  if (handle->type != UV_TIMER || !uv_is_active(handle)) return;
  uint64_t due = uv_timer_get_due_in((uv_timer_t *)handle);
  if (due > *(uint64_t *)arg) *(uint64_t *)arg = due;
}

/* The longest time to go of an armed job timer, in milliseconds. */
static uint64_t latest_due(void) {
  uint64_t due = 0;
  uv_walk(agc_io_uv(&vm), longest_due, &due);
  return due;
}

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

/* A cancel sets the outcome to CANCELLED: a request to move the timer is refused afterwards (the timer keeps its
   minute), a completion that comes later does not wake the task, and the detached ending takes the result and frees
   the job. */
static void test_cancel_before_completion(void) {
  gate *g = new_gate();
  agc_task *task = park_on(g, 60000);
  uv_sem_wait(&g->entered);
  agc_io_detach(&vm, task);
  agc_io_extend(last_job, 1);
  assert(latest_due() > 30000);
  uv_sem_post(&g->go);
  while (finished_calls == 0) assert(agc_io_poll(&vm, true));
  assert(task->state == AGC_TASK_PARKED && !task->parked);
  settle_loop();
  assert(finished_calls == 1 && dropped == 0);
  finished_calls = 0;
  task->state = AGC_TASK_RUNNING;
}

static void extend_later(void *arg) {
  agc_io_extend(arg, 1);
}

/* Another thread asks to move the timer of a job that waits for a minute. The loop belongs to this thread once the
   inbox exists, so the request goes through the inbox, wakes the loop, and the timer then fires within the test's
   deadline. Without the request the job would wait a minute. */
static void test_request_from_another_thread(void) {
  assert(agc_io_share(&vm, false));
  agc_task *task = vm.task;
  running();
  agc_io_job *job = agc_io_start(&vm, &nap_io, NULL, agc_void(), 60000);
  park(task);
  uv_thread_t thread;
  assert(uv_thread_create(&thread, extend_later, job) == 0);
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
  assert(take(task) == 1);
  settle_loop();
  assert(idle_drops == 0);
}

/* A scheduler's thread starts a job that ends at once (a timer of zero) and commits the park as the scheduler does:
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
    assert(take(task) == 1);
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

static const agc_io_kind where_io = {swift_work, where_done, where_done, swift_drop, false, "where", NULL, false};

static void start_detached(void *arg) {
  agc_io_detached(&vm, &where_io, arg, agc_void(), AGC_JOB_QUIET);
}

static void service_on_thread(void *arg) {
  (void)arg;
  assert(agc_io_service(&vm));
  assert(!agc_io_service(&vm));
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

#ifndef _WIN32
static void extend_after_close(void *arg) {
  agc_io_extend(arg, 5);
}

/* Child process: closes the inbox while a job is still held by its pool work, then a second thread posts to it. */
static void post_after_close_child(void) {
  struct rlimit none = {0, 0};
  setrlimit(RLIMIT_CORE, &none);
  alarm(60);
  int quiet = open("/dev/null", O_WRONLY);
  if (quiet >= 0) dup2(quiet, 2);
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
  on_thread(extend_after_close, job);
  _exit(0);
}

/* A post from another thread after agc_inbox_close has no consumer: it must end the process loudly (SIGABRT), not run
   inline or vanish. It runs in a child, first of all, before any thread exists in this process. */
static void test_post_after_close_is_loud(void) {
  pid_t pid = fork();
  assert(pid >= 0);
  if (pid == 0) post_after_close_child();
  int status = 0;
  assert(waitpid(pid, &status, 0) == pid);
  assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);
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
  test_late_end_after_abandon();
  test_close_runs_queued_requests();
  test_poll_runs_queued_requests();
  test_instant_job_wakes_its_task();
  test_many_jobs_end();
  test_detached_ends_on_a_scheduler();
#endif
  puts("job tests passed");
  return 0;
}
