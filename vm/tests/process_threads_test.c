/*
 * Process and child channel builtins called on a scheduler thread while the test's thread is the I/O thread (§16.9),
 * in orders set by the calls: a close behind a read's START, a read cancelled from another thread, an exit and a
 * deadline (both orders), a read's deadline and its pause, a wait cancelled past its deadline, the channel, and a
 * spawn in a callback of native code. vm-tsan runs it.
 */
#include "../core.h"
#include "io_harness.h"
#include "test_support.h"

#include <setjmp.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/types.h>
/* mallinfo2 is glibc 2.33; the release build links against glibc 2.28 (release.yml), where the count is
   skipped. */
#if defined(__GLIBC__) && !defined(AGC_NO_GC) && (__GLIBC__ > 2 || __GLIBC_MINOR__ >= 33)
#include <malloc.h>
#define MALLOC_COUNT 1
#endif

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

static agc_value sh(const char *script) {
  agc_value args[] = {agc_test_str("-c"), agc_test_str(script)};
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
  child = ok_of(step(call(one, "Process.spawn_captured.options", 3, agc_test_str("sh"), sh(script),
                          agc_test_process_options(agc_test_str(".")), agc_void())));
}

static void plain(const char *script) {
  child = ok_of(step(call(one, "Process.spawn.options", 3, agc_test_str("sh"), sh(script),
                          agc_test_process_options(agc_test_str(".")), agc_void())));
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

static void detach_one(void *arg) {
  (void)arg;
  vm.task = one;
  atomic_store(&one->state, AGC_TASK_RUNNING);
  agc_io_detach(&vm, one);
}

static void end_detached_job(void) {
  agc_test_wait_for_hand_over(&vm);
  on_thread(agc_test_service, &vm);
}

/* Every step of a child is a request to the I/O thread: the spawn, a send, a read, the wait and the close park their
   task, and the results are those of one scheduler. A call after the close fails at once. */
static void test_a_child_through_posted_steps(void) {
  assert(agc_io_share(&vm, false));
  captured("read x; echo got-$x; exit 5");
  agc_value sent = step(call(one, "Process.send", 3, child, agc_test_str("7\n"), agc_int(5000), agc_void()));
  assert(agc_as_result(&vm, sent)->ok);
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
  agc_value sent = step(call(two, "Process.send", 3, child, agc_test_str("go\n"), agc_int(5000), agc_void()));
  assert(agc_as_result(&vm, sent)->ok);
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
  assert(error_is(take(&waiting), "process: operation timed out"));
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
  assert(error_is(take(&reading), "process: operation timed out"));
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
  assert(error_is(take(&reading), "process: operation timed out"));
  assert(error_is(read_line(one, 1000), "process: process is closed"));
  close_child();
  settle();
}

static agc_value poll_line(int64_t timeout) {
  return step(call(one, "Process.poll_line", 2, child, agc_int(timeout), agc_void(), agc_void()));
}

/* poll_line's deadline passes while only part of a line has come: the `pause` takes the read out of its slot but
   keeps the child, the next poll finds the whole line, and the program still answers. */
static void test_a_poll_deadline_keeps_the_child_and_its_partial_line(void) {
  assert(agc_io_share(&vm, false));
  captured("printf par; read x; echo tial; read y; echo $y");
  assert(error_is(poll_line(5), "process: operation timed out"));
  agc_value sent = step(call(one, "Process.send", 3, child, agc_test_str("go\nback\n"), agc_int(5000), agc_void()));
  assert(agc_as_result(&vm, sent)->ok);
  assert(is_text(ok_of(poll_line(5000)), "partial"));
  assert(is_text(ok_of(poll_line(5000)), "back"));
  close_child();
  settle();
}

/* The task gives a linked poll up (woken by something else): the stop that its `expired` half posts takes the poll out
   of its slot but keeps the child, so the line that comes after is read whole, CRLF included, by a byte read and the
   next poll. */
static void test_a_poll_given_up_keeps_the_child_and_the_next_line(void) {
  assert(agc_io_share(&vm, false));
  captured("read x; sleep 0.3; printf 'second\\r\\nthird\\n'; exec sleep 60");
  calling polling = call(one, "Process.poll_line", 2, child, agc_int(60000), agc_void(), agc_void());
  assert(start(&polling));
  (void)agc_io_poll(&vm, false);
  agc_value sent = step(call(two, "Process.send", 3, child, agc_test_str("go\n"), agc_int(5000), agc_void()));
  assert(agc_as_result(&vm, sent)->ok);
  assert(error_is(take(&polling), "process: operation timed out"));
  wait_ms(600);
  for (int k = 0; k < 10; k++) (void)agc_io_poll(&vm, false);
  agc_value bytes = ok_of(step(call(one, "Process.read_bytes.bytes", 3, child, agc_int(8), agc_int(5000), agc_void())));
  size_t len = 0;
  const uint8_t *data = agc_bytes_data(&vm, bytes, &len);
  assert(len == 8 && memcmp(data, "second\r\n", 8) == 0);
  assert(is_text(ok_of(poll_line(5000)), "third"));
  close_child();
  settle();
}

/* A poll's task is cancelled after `finish` cut its line: the drop gives the line back, so the next poll reads it. */
static void test_a_poll_cancelled_after_its_line_gives_the_line_back(void) {
  assert(agc_io_share(&vm, false));
  captured("printf 'first\\r\\nsecond\\n'; exec sleep 60");
  calling polling = call(one, "Process.poll_line", 2, child, agc_int(60000), agc_void(), agc_void());
  assert(start(&polling));
  wait_woken(&polling);
  on_thread(detach_one, NULL);
  end_detached_job();
  agc_value bytes = ok_of(step(call(one, "Process.read_bytes.bytes", 3, child, agc_int(7), agc_int(5000), agc_void())));
  size_t len = 0;
  const uint8_t *data = agc_bytes_data(&vm, bytes, &len);
  assert(len == 7 && memcmp(data, "first\r\n", 7) == 0);
  assert(is_text(ok_of(poll_line(5000)), "second"));
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
  child = ok_of(step(call(one, "Process.spawn_channel.options", 3, agc_test_str("sh"),
                          sh("read x <&3; echo \"got:$x\" >&4; read y <&3 || echo end >&4"),
                          agc_test_process_options(agc_test_str(".")), agc_void())));
  assert(agc_as_result(&vm, step(call(one, "Process.channel_send", 3, child, agc_test_str("hi\n"), agc_int(5000),
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

/* The code of the failure of a call of B, or "nothing" when it returns. No local lives across the catch. */
static const char *fail_code(const agc_builtin *b, agc_value *args) {
  if (AGC_CATCH(vm.fail) != 0) return vm.outcome->code;
  (void)b->fn(&vm, args, 0);
  return "nothing";
}

/* Spawns in a callback of native code, on the scheduler thread, where a spawn parks: each fails with
   RUNTIME-NATIVE-CALLBACK (caught at vm.fail, where a failure outside a turn goes), after the launch it made is freed
   and before the child exists (#1064). With glibc's count of the bytes malloc has out (values live on the GC heap,
   which is not malloc's), a thousand refusals grow it by less than 64 bytes each, where a launch is kilobytes. */
static void spawn_in_callback(void *arg) {
  (void)arg;
  const agc_builtin *b = agc_find_builtin((const uint8_t *)"Process.spawn.options", strlen("Process.spawn.options"), 3);
  assert(b);
  agc_value args[] = {agc_test_str("sh"), sh("exit 0"), agc_test_process_options(agc_test_str("."))};
  vm.task = one;
  vm.in_turn = false;
  one->callbacks = 1;
  assert(strcmp(fail_code(b, args), "RUNTIME-NATIVE-CALLBACK") == 0);
#if MALLOC_COUNT
  size_t before = mallinfo2().uordblks;
  for (int k = 0; k < 1000; k++) assert(strcmp(fail_code(b, args), "RUNTIME-NATIVE-CALLBACK") == 0);
  assert(mallinfo2().uordblks < before + (size_t)64 * 1000);
#endif
  one->callbacks = 0;
  vm.in_turn = true;
}

static void test_a_spawn_in_a_callback(void) {
  assert(agc_io_share(&vm, false));
  on_thread(spawn_in_callback, NULL);
  settle();
}
#endif

int main(void) {
#if defined(__linux__) || defined(__APPLE__)
  agc_test_deadline(120);
  agc_test_io_vm(&vm);
  one = vm.task;
  two = agc_alloc(sizeof(agc_task));
  test_a_child_through_posted_steps();
  test_close_queued_behind_a_read();
  test_a_read_cancelled_from_another_thread();
  test_an_exit_and_a_deadline();
  test_a_read_deadline_before_the_line();
  test_a_read_deadline_stops_the_child_before_the_task_takes_it();
  test_a_wait_cancelled_past_its_deadline();
  test_a_poll_deadline_keeps_the_child_and_its_partial_line();
  test_a_poll_given_up_keeps_the_child_and_the_next_line();
  test_a_poll_cancelled_after_its_line_gives_the_line_back();
  test_the_channel_through_posted_steps();
  test_a_spawn_in_a_callback();
#endif
  puts("process threads tests passed");
  return 0;
}
