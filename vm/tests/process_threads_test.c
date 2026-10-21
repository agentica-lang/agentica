/*
 * Process and child channel builtins called on a scheduler thread while the test's thread is the I/O thread (§16.9),
 * in orders set by the calls: a close behind a read's START, a read cancelled from another thread, an exit and a
 * deadline (both orders), a read's deadline and its pause, a wait cancelled past its deadline, and the channel.
 * vm-tsan runs it.
 */
#include "../core.h"
#include "io_harness.h"
#include "test_support.h"

#include <signal.h>
#include <stdlib.h>
#include <sys/types.h>

#if defined(__linux__) || defined(__APPLE__)
#define on_thread agc_test_on_thread

static agc_vm vm;
static agc_task *one, *two;

/* The values the test keeps between steps live here, where the collector sees them. */
static agc_value child;

typedef agc_test_call calling;

static calling call(agc_task *task, const char *name, uint32_t arity, agc_value a, agc_value b, agc_value c,
                    agc_value d) {
  return agc_test_call_of(&vm, task, name, arity, a, b, c, d);
}

#define start agc_test_start
#define take agc_test_take

static void wait_woken(const calling *c) { agc_test_wait_woken(&vm, c->task); }

/* A whole call: every process step parks with several schedulers, the loop runs it, and the result is taken. */
static agc_value step(calling c) {
  assert(start(&c));
  wait_woken(&c);
  return take(&c);
}

static agc_value text(const char *s) { return agc_string_value(agc_make_string(s, strlen(s), strlen(s))); }

static agc_value sh(const char *script) {
  agc_value args[] = {text("-c"), text(script)};
  return agc_list_value(agc_list_from_array(args, 2));
}

static agc_value ok_of(agc_value v) {
  agc_result *r = agc_as_result(&vm, v);
  if (!r->ok) {
    const agc_string *s = agc_as_string(&vm, r->value);
    fprintf(stderr, "%.*s\n", (int)s->bytes, s->data);
  }
  assert(r->ok);
  return r->value;
}

static bool is_text(agc_value v, const char *expected) {
  const agc_string *s = agc_as_string(&vm, v);
  return s->bytes == strlen(expected) && memcmp(s->data, expected, s->bytes) == 0;
}

static bool error_is(agc_value v, const char *message) {
  agc_result *r = agc_as_result(&vm, v);
  return !r->ok && is_text(r->value, message);
}

static void wait_ms(unsigned ms) { uv_sleep(ms); }

static void captured(const char *script) {
  child = ok_of(step(call(one, "Process.spawn_captured", 4, text("sh"), sh(script), text("."), agc_int(5000))));
}

static void plain(const char *script) {
  child = ok_of(step(call(one, "Process.spawn", 3, text("sh"), sh(script), agc_int(5000), agc_void())));
}

static agc_value read_line(agc_task *task, int64_t timeout) {
  return step(call(task, "Process.read_line", 2, child, agc_int(timeout), agc_void(), agc_void()));
}

static agc_value wait_child(int64_t timeout) {
  return step(call(one, "Process.wait", 2, child, agc_int(timeout), agc_void(), agc_void()));
}

static void close_child(void) {
  (void)step(call(one, "Process.close", 1, child, agc_void(), agc_void(), agc_void()));
  child = agc_nil();
}

/* The loop closes with every handle closed; its end released the guard of the children, so the next case makes one. */
static void settle(void) {
  agc_test_pump_until_idle(&vm);
  agc_test_settle_loop(&vm);
  vm.rt->process_guard = NULL;
}

static void service_on_thread(void *arg) {
  (void)arg;
  agc_test_service(&vm);
}

static void detach_one(void *arg) {
  (void)arg;
  vm.task = one;
  atomic_store(&one->state, AGC_TASK_RUNNING);
  agc_io_detach(&vm, one);
}

static void end_detached_job(void) {
  agc_test_wait_for_hand_over(&vm);
  on_thread(service_on_thread, NULL);
}

/* Every step of a child is a request to the I/O thread: the spawn, a send, a read, the wait and the close park their
   task, and the results are those of one scheduler. A call after the close fails at once. */
static void test_a_child_through_posted_steps(void) {
  assert(agc_io_share(&vm, false));
  captured("read x; echo got-$x; exit 5");
  assert(agc_as_result(&vm, step(call(one, "Process.send", 3, child, text("7\n"), agc_int(5000), agc_void())))->ok);
  assert(is_text(ok_of(read_line(one, 5000)), "got-7"));
  assert(agc_as_int(&vm, ok_of(wait_child(5000))) == 5);
  agc_value kept = child;
  close_child();
  calling after = call(one, "Process.read_line", 2, kept, agc_int(1000), agc_void(), agc_void());
  assert(!start(&after));
  assert(error_is(after.result, "process: process is closed"));
  settle();
}

/* A read's START waits in the inbox when a second task, on another scheduler, closes the child, so the close's START
   is queued behind it. The read links and starts reading; the close then shuts the child, which ends the read with the
   closed error. The captured child gets SIGTERM and its grace timer, and the loop ends with every handle closed. */
static void test_close_queued_behind_a_read(void) {
  assert(agc_io_share(&vm, false));
  captured("exec sleep 60");
  calling reading = call(one, "Process.read_line", 2, child, agc_int(60000), agc_void(), agc_void());
  assert(start(&reading));
  calling closing = call(two, "Process.close", 1, child, agc_void(), agc_void(), agc_void());
  assert(start(&closing));
  wait_woken(&reading);
  wait_woken(&closing);
  assert(error_is(take(&reading), "process: process is closed"));
  assert(agc_is(take(&closing), AGC_T_VOID));
  child = agc_nil();
  settle();
}

/* A task parked in read_line is cancelled from another thread before the child writes. The read stays in its slot
   (a process read is cancelled only at its deadline), takes the first line when it comes, and a scheduler ends the
   detached job and drops the result. Its end hands the reader lock on, and the next read takes the second line. */
static void test_a_read_cancelled_from_another_thread(void) {
  assert(agc_io_share(&vm, false));
  agc_runq_share(vm.rt->runq);
  captured("read x; echo first; echo second; exec sleep 60");
  calling reading = call(one, "Process.read_line", 2, child, agc_int(60000), agc_void(), agc_void());
  assert(start(&reading));
  (void)agc_io_poll(&vm, false);
  on_thread(detach_one, NULL);
  assert(agc_as_result(&vm, step(call(two, "Process.send", 3, child, text("go\n"), agc_int(5000), agc_void())))->ok);
  end_detached_job();
  assert(is_text(ok_of(read_line(two, 5000)), "second"));
  close_child();
  settle();
}

/* The child exits and the wait's 1 ms deadline passes before the loop runs: libuv polls before it runs the timers,
   so the exit ends the wait first and its status stands; the timer that fires after changes nothing, and no timer is
   left. Then the other order: the deadline passes while the child runs, the timer's `pause` takes the wait out of the
   list, the exit that comes later readies nothing, and the next wait sees the status. */
static void test_an_exit_and_a_deadline(void) {
  assert(agc_io_share(&vm, false));
  plain("exit 4");
  calling waiting = call(one, "Process.wait", 2, child, agc_int(1), agc_void(), agc_void());
  assert(start(&waiting));
  wait_ms(500);
  wait_woken(&waiting);
  for (int k = 0; k < 10; k++) (void)agc_io_poll(&vm, false);
  assert(agc_as_int(&vm, ok_of(take(&waiting))) == 4);
  (void)agc_io_poll(&vm, false);
  assert(agc_test_armed_timers(&vm) == 0);
  close_child();
  plain("sleep 1; exit 6");
  waiting = call(one, "Process.wait", 2, child, agc_int(5), agc_void(), agc_void());
  assert(start(&waiting));
  wait_woken(&waiting);
  assert(error_is(take(&waiting), "network: operation timed out"));
  assert(agc_as_int(&vm, ok_of(wait_child(5000))) == 6);
  close_child();
  settle();
}

/* A read whose deadline passes before any byte: the `pause` shuts the child before EXPIRED is published, a line that
   the child writes later reaches no request, and the next read finds the child closed. */
static void test_a_read_deadline_before_the_line(void) {
  assert(agc_io_share(&vm, false));
  captured("sleep 1; echo late; exec sleep 60");
  calling reading = call(one, "Process.read_line", 2, child, agc_int(5), agc_void(), agc_void());
  assert(start(&reading));
  wait_woken(&reading);
  assert(error_is(take(&reading), "network: operation timed out"));
  assert(error_is(read_line(one, 1000), "process: process is closed"));
  close_child();
  settle();
}

/* The `pause` of a read's deadline shuts the child on the I/O thread when the timer fires, before the task has taken
   the timeout: the plain child gets SIGKILL and the loop reaps it while the expired job still waits for its task.
   Without the pause the child would live until the `expired` half posts its stop. */
static void test_a_read_deadline_stops_the_child_before_the_task_takes_it(void) {
  assert(agc_io_share(&vm, false));
  plain("echo $$; exec sleep 60");
  const agc_string *line = agc_as_string(&vm, ok_of(read_line(one, 5000)));
  char digits[32];
  assert(line->bytes > 0 && line->bytes < sizeof digits);
  memcpy(digits, line->data, line->bytes);
  digits[line->bytes] = 0;
  pid_t pid = (pid_t)strtol(digits, NULL, 10);
  calling reading = call(one, "Process.read_line", 2, child, agc_int(5), agc_void(), agc_void());
  assert(start(&reading));
  wait_woken(&reading);
  uint64_t due = agc_clock_ms() + 10000;
  while (kill(pid, 0) == 0 && agc_clock_ms() < due) (void)agc_io_poll(&vm, false);
  assert(kill(pid, 0) != 0);
  assert(error_is(take(&reading), "network: operation timed out"));
  assert(error_is(read_line(one, 1000), "process: process is closed"));
  close_child();
  settle();
}

/* A task parked in a wait is cancelled, then the deadline passes. A scheduler finds the job still waiting and posts
   its cancel; the I/O thread stops the wait (the cancel half, at the deadline), the job comes back dropping, and a
   scheduler ends it with `drop`, which runs on the I/O thread. The child is closed after. */
static void test_a_wait_cancelled_past_its_deadline(void) {
  assert(agc_io_share(&vm, false));
  agc_runq_share(vm.rt->runq);
  plain("exec sleep 60");
  calling waiting = call(one, "Process.wait", 2, child, agc_int(30), agc_void(), agc_void());
  assert(start(&waiting));
  (void)agc_io_poll(&vm, false);
  on_thread(detach_one, NULL);
  wait_ms(60);
  end_detached_job();
  end_detached_job();
  close_child();
  settle();
}

/* The child channel through posted steps: a line each way, the close of the write side (the child reads the end),
   and the end of input after the child exits. */
static void test_the_channel_through_posted_steps(void) {
  assert(agc_io_share(&vm, false));
  child = ok_of(step(call(one, "Process.spawn_channel", 4, text("sh"),
                          sh("read x <&3; echo \"got:$x\" >&3; read y <&3 || echo end >&3"), text("."),
                          agc_int(5000))));
  assert(agc_as_result(&vm, step(call(one, "Process.channel_send", 3, child, text("hi\n"), agc_int(5000),
                                      agc_void())))->ok);
  agc_value line = step(call(one, "Process.channel_read_line", 2, child, agc_int(5000), agc_void(), agc_void()));
  assert(is_text(ok_of(line), "got:hi"));
  assert(agc_as_result(&vm, step(call(one, "Process.channel_close", 2, child, agc_int(5000), agc_void(),
                                      agc_void())))->ok);
  line = step(call(one, "Process.channel_read_line", 2, child, agc_int(5000), agc_void(), agc_void()));
  assert(is_text(ok_of(line), "end"));
  assert(agc_as_int(&vm, ok_of(wait_child(5000))) == 0);
  line = step(call(one, "Process.channel_read_line", 2, child, agc_int(5000), agc_void(), agc_void()));
  assert(error_is(line, "process: end of input"));
  close_child();
  settle();
}
#endif

int main(void) {
#if defined(__linux__) || defined(__APPLE__)
  agc_test_deadline(120);
  agc_test_io_vm(&vm);
  vm.rt->allow_run = true;
  one = vm.task;
  two = agc_alloc(sizeof(agc_task));
  test_a_child_through_posted_steps();
  test_close_queued_behind_a_read();
  test_a_read_cancelled_from_another_thread();
  test_an_exit_and_a_deadline();
  test_a_read_deadline_before_the_line();
  test_a_read_deadline_stops_the_child_before_the_task_takes_it();
  test_a_wait_cancelled_past_its_deadline();
  test_the_channel_through_posted_steps();
#endif
  puts("process threads tests passed");
  return 0;
}
