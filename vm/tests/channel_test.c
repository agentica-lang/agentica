/*
 * The Channel builtins, called directly with hand-made tasks and no bytecode:
 * ring growth and its turn cost, wrap-around, capacity and waiter order, when a
 * channel counts as abandoned by its receiver, and when a wait's clock starts.
 */
#include "../core.h"
#include "test_support.h"

#include <assert.h>
#include <stdatomic.h>
#include <string.h>
#include <time.h>

#if defined(__linux__) || defined(__APPLE__)

enum { NEW, SEND, RECV, CLOSE, CLOSED, COUNT };

static agc_vm vm;
static agc_task *main_task;
static const agc_builtin *calls[COUNT];
static uint64_t ids;

static agc_task *make_task(void) {
  agc_task *t = agc_alloc(sizeof(agc_task));
  t->id = ++ids;
  t->state = AGC_TASK_RUNNING;
  return t;
}

static agc_value run(agc_task *t, int which, agc_value *args, bool *parked) {
  vm.task = t;
  t->state = AGC_TASK_RUNNING;
  if (t->parked) agc_io_finish(&vm, t);
  t->retry = false;
  agc_value result = calls[which]->fn(&vm, args, 0);
  vm.task = main_task;
  *parked = t->parking;
  if (t->parking) {
    t->parking = false;
    t->state = AGC_TASK_PARKED;
  }
  return result;
}

static agc_value now(agc_task *t, int which, agc_value *args) {
  bool parked;
  agc_value result = run(t, which, args, &parked);
  assert(!parked);
  return result;
}

static void wait(agc_task *t, int which, agc_value *args) {
  bool parked;
  run(t, which, args, &parked);
  assert(parked && t->state == AGC_TASK_PARKED);
}

static agc_value make_channel(int64_t capacity) {
  agc_value args[1] = {agc_int(capacity)};
  return now(main_task, NEW, args);
}

static agc_value send(agc_task *t, agc_value ch, int64_t value, int64_t timeout) {
  agc_value args[3] = {ch, agc_int(value), agc_int(timeout)};
  return now(t, SEND, args);
}

static agc_value recv(agc_task *t, agc_value ch, int64_t timeout) {
  agc_value args[2] = {ch, agc_int(timeout)};
  return now(t, RECV, args);
}

static void wait_send(agc_task *t, agc_value ch, int64_t value, int64_t timeout) {
  agc_value args[3] = {ch, agc_int(value), agc_int(timeout)};
  wait(t, SEND, args);
}

static void wait_recv(agc_task *t, agc_value ch, int64_t timeout) {
  agc_value args[2] = {ch, agc_int(timeout)};
  wait(t, RECV, args);
}

static void close_channel(agc_value ch) {
  agc_value args[1] = {ch};
  now(main_task, CLOSE, args);
}

static bool closed(agc_value ch) {
  agc_value args[1] = {ch};
  return agc_as_bool(&vm, now(main_task, CLOSED, args));
}

static bool got(agc_value result, int64_t value) {
  const agc_result *r = agc_as_result(&vm, result);
  return r->ok && agc_as_int(&vm, r->value) == value;
}

static bool failed(agc_value result, const char *text) {
  const agc_result *r = agc_as_result(&vm, result);
  const agc_string *s = agc_as_string(&vm, r->value);
  return !r->ok && s->bytes == strlen(text) && memcmp(s->data, text, s->bytes) == 0;
}

static agc_task *ready_head(void) { return agc_test_ready_head(vm.rt->runq); }

static agc_task *next_ready(void) {
  agc_task *t = agc_runq_pop(vm.rt->runq);
  assert(t);
  return t;
}

static void settle(void) {
  assert(!ready_head());
  vm.task = main_task;
}

static bool sent(agc_value result) {
  const agc_result *r = agc_as_result(&vm, result);
  return r->ok && agc_is(r->value, AGC_T_VOID);
}

static void test_ring(void) {
  agc_value ch = make_channel(20);
  int64_t start = main_task->turn_cost;
  for (int64_t k = 1; k <= 8; k++) assert(sent(send(main_task, ch, k, 0)));
  assert(main_task->turn_cost == start);
  assert(sent(send(main_task, ch, 9, 0)));
  assert(main_task->turn_cost == start + 8);
  for (int64_t k = 1; k <= 6; k++) assert(got(recv(main_task, ch, 0), k));
  for (int64_t k = 10; k <= 26; k++) assert(sent(send(main_task, ch, k, 0)));
  assert(main_task->turn_cost == start + 8 + 16);
  assert(failed(send(main_task, ch, 27, 0), "channel: timed out"));
  for (int64_t k = 7; k <= 26; k++) assert(got(recv(main_task, ch, 0), k));
  assert(failed(recv(main_task, ch, 0), "channel: timed out"));
  assert(main_task->turn_cost == start + 8 + 16);
  agc_value one = make_channel(1);
  assert(sent(send(main_task, one, 1, 0)));
  assert(failed(send(main_task, one, 2, 0), "channel: timed out"));
  assert(got(recv(main_task, one, 0), 1));
  assert(main_task->turn_cost == start + 8 + 16);
}

static void test_receiver_order(void) {
  agc_value ch = make_channel(2);
  agc_task *a = make_task(), *b = make_task(), *c = make_task();
  wait_recv(a, ch, 5000);
  wait_recv(b, ch, 5000);
  wait_recv(c, ch, 5000);
  send(main_task, ch, 1, 0);
  send(main_task, ch, 2, 0);
  send(main_task, ch, 3, 0);
  assert(next_ready() == a && next_ready() == b && next_ready() == c);
  settle();
  assert(!closed(ch));
  agc_value args[2] = {ch, agc_int(5000)};
  assert(got(now(c, RECV, args), 3));
  assert(got(now(a, RECV, args), 1));
  assert(got(now(b, RECV, args), 2));
  assert(!a->channel.channel && !a->parked && !b->parked && !c->parked);
  close_channel(ch);
  assert(closed(ch));
}

static void test_sender_order(void) {
  agc_value ch = make_channel(1);
  agc_task *a = make_task(), *b = make_task(), *c = make_task();
  send(main_task, ch, 10, 0);
  wait_send(a, ch, 11, 5000);
  wait_send(b, ch, 12, 5000);
  wait_send(c, ch, 13, 5000);
  assert(got(recv(main_task, ch, 0), 10));
  assert(next_ready() == a);
  settle();
  agc_value args_a[3] = {ch, agc_int(11), agc_int(5000)};
  assert(sent(now(a, SEND, args_a)));
  assert(got(recv(main_task, ch, 0), 11));
  assert(next_ready() == b);
  settle();
  agc_value args_b[3] = {ch, agc_int(12), agc_int(5000)};
  assert(sent(now(b, SEND, args_b)));
  assert(got(recv(main_task, ch, 0), 12));
  assert(next_ready() == c);
  settle();
  agc_value args_c[3] = {ch, agc_int(13), agc_int(5000)};
  assert(sent(now(c, SEND, args_c)));
  assert(got(recv(main_task, ch, 0), 13));
  assert(failed(recv(main_task, ch, 0), "channel: timed out"));
}

static void test_cancelled_receiver(void) {
  agc_value ch = make_channel(2);
  agc_task *a = make_task(), *b = make_task();
  wait_recv(a, ch, 5000);
  wait_recv(b, ch, 5000);
  send(main_task, ch, 7, 0);
  assert(ready_head() == a && a->channel.reserved);
  agc_task_cancel(&vm, a);
  assert(a->state == AGC_TASK_DONE && !a->channel.channel && !a->parked);
  assert(next_ready() == b && b->channel.reserved);
  settle();
  assert(!closed(ch));
  agc_value args[2] = {ch, agc_int(5000)};
  assert(got(now(b, RECV, args), 7));
  assert(failed(recv(main_task, ch, 0), "channel: timed out"));
}

static void test_value_back_to_buffer(void) {
  agc_value ch = make_channel(3);
  agc_task *a = make_task();
  wait_recv(a, ch, 5000);
  send(main_task, ch, 1, 0);
  send(main_task, ch, 2, 0);
  assert(ready_head() == a);
  agc_task_cancel(&vm, a);
  assert(!ready_head());
  assert(got(recv(main_task, ch, 0), 1));
  assert(got(recv(main_task, ch, 0), 2));
  assert(failed(recv(main_task, ch, 0), "channel: timed out"));
}

static void test_values_back_in_send_order(bool reverse) {
  agc_value ch = make_channel(4);
  agc_task *a = make_task(), *b = make_task();
  wait_recv(a, ch, 5000);
  wait_recv(b, ch, 5000);
  send(main_task, ch, 1, 0);
  send(main_task, ch, 2, 0);
  assert(ready_head() == a && a->next == b);
  agc_task_cancel(&vm, reverse ? b : a);
  agc_task_cancel(&vm, reverse ? a : b);
  assert(!ready_head());
  assert(sent(send(main_task, ch, 3, 0)));
  assert(got(recv(main_task, ch, 0), 1));
  assert(got(recv(main_task, ch, 0), 2));
  assert(got(recv(main_task, ch, 0), 3));
  assert(failed(recv(main_task, ch, 0), "channel: timed out"));
}

static void test_value_back_to_full_buffer(void) {
  agc_value ch = make_channel(1);
  agc_task *a = make_task();
  wait_recv(a, ch, 5000);
  send(main_task, ch, 1, 0);
  send(main_task, ch, 2, 0);
  agc_task_cancel(&vm, a);
  assert(got(recv(main_task, ch, 0), 1));
  assert(got(recv(main_task, ch, 0), 2));
  assert(failed(recv(main_task, ch, 0), "channel: timed out"));
  assert(sent(send(main_task, ch, 3, 0)));
  assert(failed(send(main_task, ch, 4, 0), "channel: timed out"));
}

static void test_values_back_into_wrapped_ring(void) {
  agc_value ch = make_channel(20);
  agc_task *receivers[4];
  for (int64_t k = 0; k < 5; k++) assert(sent(send(main_task, ch, k, 0)));
  for (int64_t k = 0; k < 5; k++) assert(got(recv(main_task, ch, 0), k));
  for (int k = 0; k < 4; k++) {
    receivers[k] = make_task();
    wait_recv(receivers[k], ch, 5000);
  }
  for (int64_t v = 1; v <= 12; v++) assert(sent(send(main_task, ch, v, 0)));
  assert(ready_head() == receivers[0] && receivers[0]->channel.reserved);
  for (int k = 0; k < 4; k++) agc_task_cancel(&vm, receivers[k]);
  assert(!ready_head());
  for (int64_t v = 1; v <= 12; v++) assert(got(recv(main_task, ch, 0), v));
  assert(failed(recv(main_task, ch, 0), "channel: timed out"));
}

static void test_sender_waits_while_over_capacity(void) {
  agc_value ch = make_channel(2);
  agc_task *receiver = make_task(), *sender = make_task();
  wait_recv(receiver, ch, 5000);
  for (int64_t v = 1; v <= 3; v++) assert(sent(send(main_task, ch, v, 0)));
  wait_send(sender, ch, 4, 5000);
  agc_task_cancel(&vm, receiver);
  assert(!ready_head());
  assert(failed(send(main_task, ch, 9, 0), "channel: timed out"));
  assert(got(recv(main_task, ch, 0), 1));
  assert(!ready_head());
  assert(got(recv(main_task, ch, 0), 2));
  assert(ready_head() == sender && sender->channel.reserved);
  assert(next_ready() == sender);
  settle();
  agc_value args[3] = {ch, agc_int(4), agc_int(5000)};
  assert(sent(now(sender, SEND, args)));
  assert(got(recv(main_task, ch, 0), 3));
  assert(got(recv(main_task, ch, 0), 4));
  assert(failed(recv(main_task, ch, 0), "channel: timed out"));
}

static agc_value free_slot_for_senders(agc_task *a, agc_task *b) {
  agc_value ch = make_channel(1);
  send(main_task, ch, 1, 0);
  wait_send(a, ch, 2, 5000);
  wait_send(b, ch, 3, 5000);
  assert(got(recv(main_task, ch, 0), 1));
  return ch;
}

static void test_reserved_sender_to_receiver(void) {
  agc_task *a = make_task(), *b = make_task(), *r = make_task();
  agc_value ch = free_slot_for_senders(a, b);
  assert(next_ready() == a);
  settle();
  wait_recv(r, ch, 5000);
  agc_value args_a[3] = {ch, agc_int(2), agc_int(5000)};
  assert(sent(now(a, SEND, args_a)));
  assert(next_ready() == r && next_ready() == b && b->channel.reserved);
  settle();
  agc_value args_r[2] = {ch, agc_int(5000)};
  assert(got(now(r, RECV, args_r), 2));
  agc_value args_b[3] = {ch, agc_int(3), agc_int(5000)};
  assert(sent(now(b, SEND, args_b)));
  assert(got(recv(main_task, ch, 0), 3));
  assert(failed(recv(main_task, ch, 0), "channel: timed out"));
}

static void test_cancelled_sender(void) {
  agc_task *a = make_task(), *b = make_task();
  agc_value ch = free_slot_for_senders(a, b);
  assert(ready_head() == a && a->channel.reserved);
  agc_task_cancel(&vm, a);
  assert(next_ready() == b && b->channel.reserved);
  settle();
  assert(failed(send(main_task, ch, 9, 0), "channel: timed out"));
  agc_value args[3] = {ch, agc_int(3), agc_int(5000)};
  assert(sent(now(b, SEND, args)));
  assert(got(recv(main_task, ch, 0), 3));
  assert(failed(recv(main_task, ch, 0), "channel: timed out"));
}

static void test_cancelled_sender_frees_slot(void) {
  agc_value ch = make_channel(1);
  agc_task *a = make_task();
  send(main_task, ch, 1, 0);
  wait_send(a, ch, 2, 5000);
  assert(got(recv(main_task, ch, 0), 1));
  agc_task_cancel(&vm, a);
  assert(!ready_head());
  assert(sent(send(main_task, ch, 3, 0)));
  assert(got(recv(main_task, ch, 0), 3));
  assert(failed(recv(main_task, ch, 0), "channel: timed out"));
}

static void test_close_with_reserved_value(void) {
  agc_value ch = make_channel(2);
  agc_task *a = make_task(), *b = make_task();
  wait_recv(a, ch, 5000);
  send(main_task, ch, 5, 0);
  close_channel(ch);
  assert(!closed(ch));
  assert(next_ready() == a);
  settle();
  agc_value args_b[2] = {ch, agc_int(5000)};
  wait(b, RECV, args_b);
  agc_value args_a[2] = {ch, agc_int(5000)};
  assert(got(now(a, RECV, args_a), 5));
  assert(closed(ch));
  assert(next_ready() == b);
  settle();
  assert(failed(now(b, RECV, args_b), "channel: closed"));
}

static void test_close_cancels_reserved_value(void) {
  agc_value ch = make_channel(2);
  agc_task *a = make_task();
  wait_recv(a, ch, 5000);
  send(main_task, ch, 5, 0);
  close_channel(ch);
  assert(!closed(ch));
  agc_task_cancel(&vm, a);
  assert(!closed(ch));
  assert(got(recv(main_task, ch, 0), 5));
  assert(closed(ch));
  assert(failed(recv(main_task, ch, 0), "channel: closed"));
}

static void test_close_with_reserved_slot(void) {
  agc_value ch = make_channel(1);
  agc_task *a = make_task(), *b = make_task();
  send(main_task, ch, 1, 0);
  wait_send(a, ch, 2, 5000);
  agc_value args_b[3] = {ch, agc_int(3), agc_int(5000)};
  wait(b, SEND, args_b);
  assert(got(recv(main_task, ch, 0), 1));
  assert(ready_head() == a);
  close_channel(ch);
  assert(next_ready() == a && next_ready() == b);
  settle();
  agc_value args_a[3] = {ch, agc_int(2), agc_int(5000)};
  assert(failed(now(a, SEND, args_a), "channel: closed"));
  assert(failed(now(b, SEND, args_b), "channel: closed"));
  assert(closed(ch));
  assert(failed(recv(main_task, ch, 0), "channel: closed"));
}

static void test_close_wakes_receivers(void) {
  agc_value ch = make_channel(2);
  agc_task *a = make_task(), *b = make_task();
  wait_recv(a, ch, 5000);
  wait_recv(b, ch, 5000);
  close_channel(ch);
  assert(next_ready() == a && next_ready() == b);
  settle();
  agc_value args[2] = {ch, agc_int(5000)};
  assert(failed(now(a, RECV, args), "channel: closed"));
  assert(failed(now(b, RECV, args), "channel: closed"));
}

static void test_timeout_before_reservation(void) {
  agc_value ch = make_channel(2);
  agc_task *a = make_task(), *b = make_task();
  wait_recv(a, ch, 20);
  wait_recv(b, ch, 5000);
  struct timespec delay = {0, 80000000L};
  while (nanosleep(&delay, &delay) != 0) {}
  assert(agc_timers_run(&vm));
  assert(ready_head() == a && a->channel.channel);
  send(main_task, ch, 8, 0);
  assert(a->next == b);
  assert(next_ready() == a && next_ready() == b && b->channel.reserved);
  settle();
  agc_value args_a[2] = {ch, agc_int(20)};
  assert(failed(now(a, RECV, args_a), "channel: timed out"));
  assert(!a->channel.channel);
  agc_value args_b[2] = {ch, agc_int(5000)};
  assert(got(now(b, RECV, args_b), 8));
}

static void test_reservation_beats_deadline(void) {
  agc_value ch = make_channel(2);
  agc_task *a = make_task();
  wait_recv(a, ch, 20);
  agc_timers_settle(&vm);
  send(main_task, ch, 4, 0);
  struct timespec delay = {0, 80000000L};
  while (nanosleep(&delay, &delay) != 0) {}
  assert(agc_timers_run(&vm));
  assert(next_ready() == a);
  settle();
  agc_value args[2] = {ch, agc_int(20)};
  assert(got(now(a, RECV, args), 4));
}

/* A wait reads no clock when it parks (agc_task_park_within, #629). A peer that answers before the clock starts, even
   after the timeout has passed (a long turn of the peer), hands over its value and the timer is dropped unfired. A
   wait still parked at the end of the next turn starts its clock there and times out at the deadline. A retry whose
   deadline is exactly now times out without parking again. */
static void test_clock_starts_late(void) {
  agc_value ch = make_channel(1);
  agc_task *a = make_task();
  wait_recv(a, ch, 20);
  assert(a->timer.pending && a->timer.deadline == 20);
  struct timespec delay = {0, 40000000L};
  while (nanosleep(&delay, &delay) != 0) {}
  send(main_task, ch, 5, 0);
  assert(!agc_timers_run(&vm));
  assert(!a->timer.heap && !a->timer.pending && next_ready() == a);
  settle();
  agc_value args[2] = {ch, agc_int(20)};
  assert(got(now(a, RECV, args), 5));
  wait_recv(a, ch, 20);
  assert(!agc_timers_run(&vm) && !a->timer.pending && a->timer.heap == &vm.timers);
  uint64_t deadline = a->timer.deadline;
  while (agc_clock_ms() < deadline) {
    struct timespec tick = {0, 2000000L};
    while (nanosleep(&tick, &tick) != 0) {}
  }
  assert(agc_timers_run(&vm) && next_ready() == a);
  settle();
  a->timer.deadline = agc_clock_ms();
  assert(failed(now(a, RECV, args), "channel: timed out"));
  assert(!a->channel.channel && !a->timer.heap);
}

/* A task cancelled while its wait is pending leaves the slot empty: nothing starts or fires for it later. */
static void test_cancel_pending_wait(void) {
  agc_value ch = make_channel(1);
  agc_task *a = make_task();
  uint64_t armed = atomic_load(&vm.rt->timers_armed);
  wait_recv(a, ch, 5000);
  assert(a->timer.pending && atomic_load(&vm.rt->timers_armed) == armed + 1);
  agc_task_cancel(&vm, a);
  assert(!a->timer.heap && !a->timer.pending && !atomic_load(&vm.timers.pending));
  assert(atomic_load(&vm.rt->timers_armed) == armed);
  agc_timers_settle(&vm);
  (void)agc_timers_run(&vm);
  assert(!a->timer.heap && !ready_head());
}

/* Abandoned (HttpWire.awaited? is its negation): only a receiver that parked and left without a value sets it. A
   sender before any receiver parks, a poll, and a receiver that gets its value do not. */
static void test_abandoned(void) {
  agc_value ch = make_channel(1);
  const agc_channel *c = agc_as_channel(&vm, ch);
  assert(sent(send(main_task, ch, 1, 0)));
  assert(!agc_channel_abandoned(&vm, c));
  assert(got(recv(main_task, ch, 0), 1));
  assert(failed(recv(main_task, ch, 0), "channel: timed out"));
  assert(!agc_channel_abandoned(&vm, c));
  agc_task *a = make_task();
  wait_recv(a, ch, 5000);
  send(main_task, ch, 2, 0);
  assert(next_ready() == a);
  settle();
  agc_value args[2] = {ch, agc_int(5000)};
  assert(got(now(a, RECV, args), 2));
  assert(!agc_channel_abandoned(&vm, c));
  agc_task *b = make_task();
  wait_recv(b, ch, 5000);
  agc_task_cancel(&vm, b);
  assert(agc_channel_abandoned(&vm, c));
  agc_value timed = make_channel(1);
  agc_task *d = make_task();
  wait_recv(d, timed, 20);
  agc_timers_settle(&vm);
  struct timespec delay = {0, 80000000L};
  while (nanosleep(&delay, &delay) != 0) {}
  assert(agc_timers_run(&vm));
  assert(next_ready() == d);
  settle();
  assert(!agc_channel_abandoned(&vm, agc_as_channel(&vm, timed)));
  agc_value args_d[2] = {timed, agc_int(20)};
  assert(failed(now(d, RECV, args_d), "channel: timed out"));
  assert(agc_channel_abandoned(&vm, agc_as_channel(&vm, timed)));
}

int main(void) {
  agc_test_deadline(300);
  agc_init();
  agc_io_init();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  main_task = vm.task;
  static const char *names[COUNT] = {"Channel.new", "Channel.send", "Channel.recv", "Channel.close", "Channel.closed?"};
  static const uint32_t arities[COUNT] = {1, 3, 2, 1, 1};
  for (int k = 0; k < COUNT; k++) {
    calls[k] = agc_find_builtin((const uint8_t *)names[k], strlen(names[k]), arities[k]);
    assert(calls[k]);
  }
  test_ring();
  test_receiver_order();
  test_sender_order();
  test_cancelled_receiver();
  test_value_back_to_buffer();
  test_values_back_in_send_order(false);
  test_values_back_in_send_order(true);
  test_value_back_to_full_buffer();
  test_values_back_into_wrapped_ring();
  test_sender_waits_while_over_capacity();
  test_reserved_sender_to_receiver();
  test_cancelled_sender();
  test_cancelled_sender_frees_slot();
  test_close_with_reserved_value();
  test_close_cancels_reserved_value();
  test_close_with_reserved_slot();
  test_close_wakes_receivers();
  test_timeout_before_reservation();
  test_reservation_beats_deadline();
  test_abandoned();
  test_clock_starts_late();
  test_cancel_pending_wait();
  assert(agc_io_close(&vm));
  puts("channel tests passed");
  return 0;
}
#else
int main(void) {
  puts("channel tests passed");
  return 0;
}
#endif
