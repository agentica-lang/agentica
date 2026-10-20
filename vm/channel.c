/*
 * The Channel builtins: a GC ring of values, with FIFOs of the receivers and
 * senders that wait for it. A call that must wait parks its task on the
 * scheduler. Core layer. Design: docs/future/27-iteration-and-concurrency.md
 * §27.2 and docs/vm/10-io-scheduler.md §10.2.2 (Channel waits).
 */
#include "core.h"

#define FIRST_SLOTS 8

typedef struct {
  agc_value value;
  uint64_t seq;
} entry;

struct agc_channel {
  entry *ring;
  size_t slots, head, count, capacity;
  size_t reserved_values, reserved_slots;
  uint64_t sent;
  /* A receiver that had parked left without a value: its recv timed out or its task was cancelled. std/http reads
     it (HttpWire.awaited?) to tell a caller that gave up from one that has not parked yet. */
  bool closed, abandoned;
  agc_resource *state;
  agc_task *receivers, *receivers_tail, *senders, *senders_tail;
};

static agc_value ok_void(void) { return agc_result_value(true, agc_void()); }

static agc_value closed_error(void) { return agc_error_value("channel: closed"); }

static agc_value timed_out_error(void) { return agc_error_value("channel: timed out"); }

static void grow(agc_vm *vm, agc_channel *c) {
  size_t slots = agc_size_mul(c->slots, 2);
  if (slots > c->capacity && c->slots < c->capacity) slots = c->capacity;
  entry *ring = agc_alloc(agc_size_mul(slots, sizeof(entry)));
  for (size_t k = 0; k < c->count; k++) ring[k] = c->ring[(c->head + k) % c->slots];
  agc_charge(vm, c->count);
  c->ring = ring;
  c->slots = slots;
  c->head = 0;
}

static void push_back(agc_vm *vm, agc_channel *c, agc_value v, uint64_t seq) {
  if (c->count == c->slots) grow(vm, c);
  c->ring[(c->head + c->count++) % c->slots] = (entry){v, seq};
}

static void give_back(agc_vm *vm, agc_channel *c, agc_value v, uint64_t seq) {
  if (c->count == c->slots) grow(vm, c);
  c->head = (c->head + c->slots - 1) % c->slots;
  c->ring[c->head] = (entry){v, seq};
  c->count++;
  for (size_t k = 0; k + 1 < c->count; k++) {
    entry *a = &c->ring[(c->head + k) % c->slots];
    entry *b = &c->ring[(c->head + k + 1) % c->slots];
    if (a->seq < b->seq) break;
    entry swap = *a;
    *a = *b;
    *b = swap;
  }
}

static agc_value pop_front(agc_channel *c) {
  agc_value v = c->ring[c->head].value;
  c->ring[c->head] = (entry){agc_void(), 0};
  c->head = (c->head + 1) % c->slots;
  c->count--;
  return v;
}

/* The waiter queues change under rt->sync, like every shared list: pop_live, leave_queue and the enqueue in `wait`
   check it. */
static agc_task *pop_live(agc_vm *vm, agc_task **head, agc_task **tail) {
  agc_sync_assert(vm);
  while (*head) {
    agc_task *t = *head;
    agc_task_remove(head, tail, t);
    if (agc_task_waiting(t)) return t;
  }
  return NULL;
}

static bool reserve_value(agc_vm *vm, agc_channel *c, agc_value v, uint64_t seq) {
  agc_task *t = pop_live(vm, &c->receivers, &c->receivers_tail);
  if (!t) return false;
  t->channel.value = v;
  t->channel.seq = seq;
  t->channel.reserved = true;
  agc_task_wake(vm, t, "channel");
  return true;
}

static bool reserve_slot(agc_vm *vm, agc_channel *c) {
  agc_task *t = pop_live(vm, &c->senders, &c->senders_tail);
  if (!t) return false;
  t->channel.reserved = true;
  agc_task_wake(vm, t, "channel");
  return true;
}

static void offer_slot(agc_vm *vm, agc_channel *c) {
  if (c->count + c->reserved_slots < c->capacity && reserve_slot(vm, c)) c->reserved_slots++;
}

static bool deliver(agc_vm *vm, agc_channel *c, agc_value v, bool has_slot) {
  uint64_t seq = c->sent;
  if (reserve_value(vm, c, v, seq)) {
    c->reserved_values++;
  } else {
    if (!has_slot && c->count + c->reserved_slots >= c->capacity) return false;
    push_back(vm, c, v, seq);
  }
  c->sent++;
  return true;
}

static agc_value take(agc_vm *vm, agc_channel *c) {
  agc_value v = pop_front(c);
  offer_slot(vm, c);
  return v;
}

static void drained(agc_vm *vm, agc_channel *c) {
  if (c->closed && c->count == 0 && c->reserved_values == 0)
    agc_task_wake_all(vm, &c->receivers, &c->receivers_tail, "channel");
}

static void leave_queue(agc_vm *vm, agc_channel *c, agc_task *t) {
  agc_sync_assert(vm);
  if (t->channel.reserved) return;
  if (t->channel.sending)
    agc_task_remove(&c->senders, &c->senders_tail, t);
  else
    agc_task_remove(&c->receivers, &c->receivers_tail, t);
}

static void stop_waiting(agc_task *t) { t->channel = (agc_channel_wait){0}; }

static bool resumed(const agc_task *t, const agc_channel *c) { return t->channel.channel == c; }

static void check_timeout(agc_vm *vm, int64_t timeout, uint32_t span) {
  if (timeout < 0) agc_fail(vm, "RUNTIME-INVALID-DURATION", "channel timeout must be nonnegative", span);
}

static agc_value wait(agc_vm *vm, agc_channel *c, agc_task *t, int64_t timeout, bool sending) {
  if (timeout == 0) {
    stop_waiting(t);
    return timed_out_error();
  }
  uint64_t now = agc_clock_ms();
  if (!t->channel.deadline) t->channel.deadline = now + (uint64_t)timeout;
  if (t->channel.deadline <= now) {
    stop_waiting(t);
    return timed_out_error();
  }
  agc_sync_assert(vm);
  agc_task_parking(vm);
  t->channel.channel = c;
  t->channel.sending = sending;
  t->channel.reserved = false;
  if (sending)
    agc_task_enqueue(&c->senders, &c->senders_tail, t);
  else
    agc_task_enqueue(&c->receivers, &c->receivers_tail, t);
  agc_task_park_until(vm, t->channel.deadline, true);
  return agc_void();
}

static agc_value builtin_new(agc_vm *vm, agc_value *args, uint32_t span) {
  int64_t capacity = agc_as_int(vm, args[0]);
  if (capacity < 1 || capacity > AGC_MAX_LIST_COUNT)
    agc_fail(vm, "RUNTIME-INVALID-COUNT", "channel capacity must be between 1 and 1048576", span + 1);
  agc_channel *c = agc_alloc(sizeof(agc_channel));
  c->capacity = (size_t)capacity;
  c->slots = c->capacity < FIRST_SLOTS ? c->capacity : FIRST_SLOTS;
  c->ring = agc_alloc(agc_size_mul(c->slots, sizeof(entry)));
  return agc_channel_value(c);
}

static agc_value builtin_send(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_channel *c = agc_as_channel(vm, args[0]);
  int64_t timeout = agc_as_int(vm, args[2]);
  check_timeout(vm, timeout, span + 3);
  agc_task *t = vm->task;
  if (resumed(t, c)) {
    leave_queue(vm, c, t);
    if (c->closed) {
      stop_waiting(t);
      return closed_error();
    }
    if (t->channel.reserved) {
      stop_waiting(t);
      c->reserved_slots--;
      deliver(vm, c, args[1], true);
      offer_slot(vm, c);
      return ok_void();
    }
  }
  if (c->closed) {
    stop_waiting(t);
    return closed_error();
  }
  if (deliver(vm, c, args[1], false)) {
    stop_waiting(t);
    return ok_void();
  }
  return wait(vm, c, t, timeout, true);
}

static agc_value builtin_recv(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_channel *c = agc_as_channel(vm, args[0]);
  int64_t timeout = agc_as_int(vm, args[1]);
  check_timeout(vm, timeout, span + 2);
  agc_task *t = vm->task;
  bool parked = resumed(t, c);
  if (parked) {
    leave_queue(vm, c, t);
    if (t->channel.reserved) {
      agc_value v = t->channel.value;
      stop_waiting(t);
      c->reserved_values--;
      drained(vm, c);
      return agc_result_value(true, v);
    }
  }
  if (c->count > 0) {
    stop_waiting(t);
    return agc_result_value(true, take(vm, c));
  }
  if (c->closed && c->reserved_values == 0) {
    stop_waiting(t);
    return closed_error();
  }
  agc_value result = wait(vm, c, t, timeout, false);
  /* Woken by its deadline, the receiver did not park again: it timed out. */
  if (parked && !resumed(t, c)) c->abandoned = true;
  return result;
}

static void shut(agc_vm *vm, agc_channel *c) {
  if (c->closed) return;
  c->closed = true;
  if (c->state) {
    agc_unregister(vm, c->state);
    c->state = NULL;
  }
  c->reserved_slots = 0;
  agc_task_wake_all(vm, &c->senders, &c->senders_tail, "channel");
  drained(vm, c);
}

static void close_owned(agc_vm *vm, agc_resource *r, agc_task *ender) {
  (void)ender;
  shut(vm, agc_as_channel(vm, r->context));
}

static agc_value builtin_close(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  shut(vm, agc_as_channel(vm, args[0]));
  return agc_void();
}

static agc_value builtin_closed(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_channel *c = agc_as_channel(vm, args[0]);
  return agc_bool(c->closed && c->count == 0 && c->reserved_values == 0);
}

agc_resource *agc_channel_claim(agc_vm *vm, agc_channel *c) {
  if (c->closed) return NULL;
  if (!c->state) {
    c->state = agc_register(vm, NULL, NULL);
    c->state->close = close_owned;
    c->state->context = agc_channel_value(c);
  }
  return !c->state->owner || c->state->owner == vm->task ? c->state : NULL;
}

/* Whether a receiver that had parked on c left without a value (a recv timeout or a cancel). A receiver that has
   not parked yet does not count, so a sender cannot mistake a caller that is still on its way for one that left. */
bool agc_channel_abandoned(agc_vm *vm, const agc_channel *c) {
  agc_sync_assert(vm);
  return c->abandoned;
}

void agc_channel_leave(agc_vm *vm, agc_task *t) {
  agc_sync_assert(vm);
  const agc_channel_wait w = t->channel;
  agc_channel *c = w.channel;
  leave_queue(vm, c, t);
  stop_waiting(t);
  if (!w.sending) c->abandoned = true;
  if (!w.reserved) return;
  if (w.sending) {
    if (!c->closed && !reserve_slot(vm, c)) c->reserved_slots--;
  } else if (!reserve_value(vm, c, w.value, w.seq)) {
    give_back(vm, c, w.value, w.seq);
    c->reserved_values--;
  }
}

const agc_builtin agc_channel_builtins[] = {
  {"Channel.new", 1, builtin_new, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"Channel.send", 3, builtin_send, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"Channel.recv", 2, builtin_recv, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"Channel.close", 1, builtin_close, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"Channel.closed?", 1, builtin_closed, AGC_NATIVE_NONE, AGC_COST_NONE, true},
};

const size_t agc_channel_builtin_count = sizeof agc_channel_builtins / sizeof agc_channel_builtins[0];
