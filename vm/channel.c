/*
 * The Channel builtins: a GC ring of values, with FIFOs of the receivers and
 * senders that wait for it. A call that must wait parks its task on the
 * scheduler. Also the signal channels of System.subscribe and their delivery.
 * Core layer. Design: docs/vm/10-io-scheduler.md §10.2.2 (Channel waits, Stop
 * signals).
 */
#include "core.h"

#define FIRST_SLOTS 8

typedef struct {
  agc_value value;
  uint64_t seq;
} entry;

/* An Address[M] (channel.address): the number it prints, the run that made it, and its channel, held weakly so that an
   address in a table or a message does not keep a dead actor's inbox and the values in it alive. Never written after
   it is made, so any scheduler reads it without a lock. */
typedef struct {
  uint64_t id;
  const agc_runtime *rt;
  agc_weak *channel;
} address;

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
  /* The channel's one address, made by its first channel.address; NULL before. */
  const address *address;
  /* A signal channel (System.subscribe): the AGC_SIGNAL_* bits it wants, 0 for a plain channel, and the next one of
     rt->signal_channels. Cleared by the close, so a closed channel is on no list. Under rt->sync. */
  unsigned signals;
  agc_channel *signal_next;
};

static agc_value ok_void(void) { return agc_result_value(true, agc_void()); }

/* A send through an address whose channel the collector has freed: no task can reach that channel any more. */
static agc_value gone_error(agc_vm *vm) { return agc_error(vm, AGC_KIND_CHANNEL_GONE, "address: gone"); }

/* std/http matches on this text (CHANNEL_CLOSED in stdlib/http.agc). */
static agc_value closed_error(agc_vm *vm) { return agc_error(vm, AGC_KIND_CHANNEL_CLOSED, "channel: closed"); }

static agc_value timed_out_error(agc_vm *vm) { return agc_error(vm, AGC_KIND_CHANNEL_TIMEOUT, "channel: timed out"); }

/* The values of a signal channel come only from the signals it wants. */
static agc_value read_only_error(agc_vm *vm) { return agc_error(vm, AGC_KIND_ARGUMENT, "signal: channel is read only"); }

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
  if (timeout < 0) agc_fail(vm, "RUNTIME-INVALID-DURATION", AGC_CHANNEL_BAD_TIMEOUT, span);
}

static agc_value wait(agc_vm *vm, agc_channel *c, agc_task *t, int64_t timeout, bool sending) {
  if (timeout == 0) {
    stop_waiting(t);
    return timed_out_error(vm);
  }
  /* A waiter is woken with a reservation, by a close, or by its timer. The first two never get here, so a resumed
     waiter's timer fired: it timed out. */
  if (resumed(t, c)) {
    stop_waiting(t);
    return timed_out_error(vm);
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
  agc_task_park_within(vm, agc_timeout_length(vm, timeout));
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

/* The send of Channel.send and Address.send, after the timeout is checked. */
static agc_value send_value(agc_vm *vm, agc_channel *c, agc_value v, int64_t timeout) {
  agc_task *t = vm->task;
  if (c->signals) return read_only_error(vm);
  if (resumed(t, c)) {
    leave_queue(vm, c, t);
    if (c->closed) {
      stop_waiting(t);
      return closed_error(vm);
    }
    if (t->channel.reserved) {
      stop_waiting(t);
      c->reserved_slots--;
      deliver(vm, c, v, true);
      offer_slot(vm, c);
      return ok_void();
    }
  }
  if (c->closed) {
    stop_waiting(t);
    return closed_error(vm);
  }
  if (deliver(vm, c, v, false)) {
    stop_waiting(t);
    return ok_void();
  }
  return wait(vm, c, t, timeout, true);
}

static agc_value builtin_send(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_channel *c = agc_as_channel(vm, args[0]);
  int64_t timeout = agc_as_int(vm, args[2]);
  check_timeout(vm, timeout, span + 3);
  return send_value(vm, c, args[1], timeout);
}

/* channel.address: made at the first call and kept, so every address of a channel is one object and == compares
   identity. The row is shared, so two schedulers never make two. */
static agc_value builtin_address(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_sync_assert(vm);
  agc_channel *c = agc_as_channel(vm, args[0]);
  if (!c->address) {
    address *a = agc_alloc(sizeof *a);
    a->id = ++vm->rt->addresses;
    a->rt = vm->rt;
    a->channel = agc_weak_new(c);
    c->address = a;
  }
  return agc_address_value(c->address);
}

/* Address.send: Channel.send on the address's channel while it lives. A parked sender holds its channel
   (agc_task.channel), so the retry after its wake finds it again. The row is shared: the weak read takes the
   collector's alloc lock while rt->sync is held (the order every allocation under rt->sync already takes), and
   send_value needs rt->sync, as Channel.send does. */
static agc_value builtin_address_send(agc_vm *vm, agc_value *args, uint32_t span) {
  const address *a = agc_as_address(vm, args[0]);
  if (a->rt != vm->rt) agc_fail(vm, "RUNTIME-ADDRESS-CONTEXT", "the address belongs to another run", span + 1);
  int64_t timeout = agc_as_int(vm, args[2]);
  check_timeout(vm, timeout, span + 3);
  agc_channel *c = agc_weak_get(a->channel);
  if (!c) return gone_error(vm);
  return send_value(vm, c, args[1], timeout);
}

/* The number an address prints with (<Address 1>), counted per run from 1. */
uint64_t agc_address_id(agc_vm *vm, agc_value v) { return ((const address *)agc_as_address(vm, v))->id; }

/* The receive of Channel.recv and of a Lazy over a channel (port.h). */
agc_recv_status agc_channel_receive(agc_vm *vm, agc_channel *c, int64_t timeout, agc_value *out) {
  agc_sync_assert(vm);
  agc_task *t = vm->task;
  bool parked = resumed(t, c);
  if (parked) {
    leave_queue(vm, c, t);
    if (t->channel.reserved) {
      *out = t->channel.value;
      stop_waiting(t);
      c->reserved_values--;
      drained(vm, c);
      return AGC_RECV_VALUE;
    }
  }
  if (c->count > 0) {
    stop_waiting(t);
    *out = take(vm, c);
    return AGC_RECV_VALUE;
  }
  if (c->closed && c->reserved_values == 0) {
    stop_waiting(t);
    return AGC_RECV_CLOSED;
  }
  agc_value result = wait(vm, c, t, timeout, false);
  /* Woken by its deadline, the receiver did not park again: it timed out. */
  if (parked && !resumed(t, c)) c->abandoned = true;
  return agc_is(result, AGC_T_VOID) ? AGC_RECV_WAIT : AGC_RECV_TIMED_OUT;
}

static agc_value builtin_recv(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_channel *c = agc_as_channel(vm, args[0]);
  int64_t timeout = agc_as_int(vm, args[1]);
  check_timeout(vm, timeout, span + 2);
  agc_value v = agc_void();
  switch (agc_channel_receive(vm, c, timeout, &v)) {
    case AGC_RECV_VALUE: return agc_result_value(true, v);
    case AGC_RECV_CLOSED: return closed_error(vm);
    case AGC_RECV_TIMED_OUT: return timed_out_error(vm);
    case AGC_RECV_WAIT: break;
  }
  return agc_void();
}

/* The subscribed signals of the run: the union of the masks of its signal channels. */
static unsigned subscribed(const agc_vm *vm) {
  unsigned mask = 0;
  for (const agc_channel *c = vm->rt->signal_channels; c; c = c->signal_next) mask |= c->signals;
  return mask;
}

/* The end of a subscription: off the list, then the process mask without it, so a signal that only this channel
   wanted takes the stop path again. */
static void unsubscribe(agc_vm *vm, agc_channel *c) {
  agc_channel **at = &vm->rt->signal_channels;
  while (*at && *at != c) at = &(*at)->signal_next;
  if (*at) *at = c->signal_next;
  c->signal_next = NULL;
  c->signals = 0;
  agc_io_signals_set(vm, subscribed(vm));
}

static void shut(agc_vm *vm, agc_channel *c) {
  if (c->closed) return;
  c->closed = true;
  if (c->signals) unsubscribe(vm, c);
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

/* The close flag, as Ruby's Queue#closed?, whatever is still buffered: a producer reads it between sends to learn
   that the reader has gone before its next send fails. */
static agc_value builtin_closed(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_bool(agc_as_channel(vm, args[0])->closed);
}

/* No value is left to receive: none in the ring and none handed to a woken receiver that has not taken it yet (it may
   leave and give the value back, agc_channel_leave). Once a channel is closed no value arrives and this count only
   falls, so `closed?` then `empty?`, in that order, is the closed-and-drained state, and it stays true. */
static agc_value builtin_empty(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_channel *c = agc_as_channel(vm, args[0]);
  return agc_bool(c->count == 0 && c->reserved_values == 0);
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

/* A send that never waits, for the notice of a monitor (vm/task.c): the value goes to a waiting receiver, else into the
   ring, past the capacity when the channel is full, so an open channel never loses a notice. Senders still wait until
   the count is below the capacity, so the ring holds at most one value more than the capacity per monitor of the
   channel. False, and nothing sent, when the channel is closed or a signal channel (System.subscribe). */
bool agc_channel_offer(agc_vm *vm, agc_channel *c, agc_value v) {
  agc_sync_assert(vm);
  return !c->closed && !c->signals && deliver(vm, c, v, true);
}

/* The variant ids of System.Signal, by AGC_SIGNAL_* index, found by name the first time (under rt->sync, as every
   signal row is shared): a forged program without the enum fails here with RUNTIME-INTERNAL. */
static const uint32_t *signal_variants(agc_vm *vm) {
  static const char *const names[AGC_SIGNAL_COUNT] = {"Term", "Int", "Hup", "Usr1", "Usr2", "Quit", "Kill"};
  agc_runtime *rt = vm->rt;
  if (!rt->signal_found) {
    for (unsigned k = 0; k < AGC_SIGNAL_COUNT; k++)
      rt->signal_variants[k] = agc_builtin_variant(vm, "System.Signal", names[k], 0);
    rt->signal_found = true;
  }
  return rt->signal_variants;
}

/* The AGC_SIGNAL_* index of a System.Signal value. */
static unsigned signal_index(agc_vm *vm, agc_value v) {
  const uint32_t *ids = signal_variants(vm);
  uint32_t variant = agc_as_enum(vm, v)->variant;
  for (unsigned k = 0; k < AGC_SIGNAL_COUNT; k++)
    if (ids[k] == variant) return k;
  agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: not a System.Signal value", 0);
}

/* System.subscribe(signals): a new channel that receives each listed signal, owned by the calling task like a handle,
   so its end (any end) or Channel.close ends the subscription. Its capacity is the number of signals, one pending
   value each (agc_signals_deliver). Quit (the VM's force stop) and Kill cannot be caught. */
static agc_value builtin_subscribe(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_list *list = agc_as_list(vm, args[0]);
  size_t n = agc_list_len(list);
  agc_charge(vm, n);
  unsigned mask = 0;
  for (size_t k = 0; k < n; k++) {
    unsigned index = signal_index(vm, agc_list_get(list, k));
    if (index >= AGC_SIGNAL_DELIVERED)
      agc_fail(vm, "RUNTIME-INVALID-SIGNAL", "System.Signal.Quit and System.Signal.Kill cannot be subscribed to",
               span + 1);
    mask |= 1u << index;
  }
  if (!mask) return agc_error(vm, AGC_KIND_ARGUMENT, "signal: no signals");
  if (!agc_io_signals_supported())
    return agc_error(vm, AGC_KIND_SYSTEM_SIGNAL, "signal: not supported on this system");
  /* A signal ignored at start stays ignored; the call fails only when nothing is left to subscribe to (#1533). */
  mask &= ~agc_io_signals_ignored();
  if (!mask) return agc_error(vm, AGC_KIND_SYSTEM_SIGNAL, "signal: ignored when the program started");
  size_t capacity = 0;
  for (unsigned k = 0; k < AGC_SIGNAL_DELIVERED; k++) capacity += (mask >> k) & 1u;
  agc_channel *c = agc_alloc(sizeof(agc_channel));
  c->capacity = c->slots = capacity;
  c->ring = agc_alloc(agc_size_mul(c->slots, sizeof(entry)));
  c->signals = mask;
  agc_own(vm, agc_channel_claim(vm, c), close_owned);
  c->signal_next = vm->rt->signal_channels;
  vm->rt->signal_channels = c;
  agc_io_signals_set(vm, subscribed(vm));
  return agc_result_value(true, agc_channel_value(c));
}

/* System.signal_number(signal): the OS number, so 128 + it is the exit code of a process that the signal ended. */
static agc_value builtin_signal_number(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_int(agc_io_signal_number(signal_index(vm, args[0])));
}

/* Whether a value of the signal VARIANT waits in the ring: a signal is queued only when it has no pending value, so a
   burst gives one value per signal and the ring never fills. */
static bool queued(agc_vm *vm, const agc_channel *c, uint32_t variant) {
  for (size_t k = 0; k < c->count; k++)
    if (agc_as_enum(vm, c->ring[(c->head + k) % c->slots].value)->variant == variant) return true;
  return false;
}

/* Between turns (check_stop in vm/task.c): each signal the handler recorded goes to every channel that wants it, as
   one value at most, without waiting. A signal that no channel wants any more (its last subscription ended after the
   handler saw it) takes the stop path instead. */
bool agc_signals_deliver(agc_vm *vm) {
  unsigned pending = agc_io_signals_take();
  if (!pending) return false;
  bool delivered = false;
  agc_runtime *rt = vm->rt;
  agc_sync_take(vm);
  for (unsigned k = 0; k < AGC_SIGNAL_DELIVERED; k++) {
    if (!(pending & (1u << k))) continue;
    bool wanted = false;
    for (agc_channel *c = rt->signal_channels; c; c = c->signal_next) {
      if (!(c->signals & (1u << k))) continue;
      wanted = true;
      uint32_t variant = rt->signal_variants[k];
      if (!queued(vm, c, variant))
        delivered |= deliver(vm, c, agc_enum_value(rt->program->variants[variant].shared), false);
    }
    if (!wanted) agc_io_signals_stop(k);
  }
  agc_sync_drop(vm);
  return delivered;
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
  {"Channel.new", 1, builtin_new, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
  {"Channel.send", 3, builtin_send, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
  {"Channel.recv", 2, builtin_recv, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
  {"Channel.close", 1, builtin_close, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
  {"Channel.closed?", 1, builtin_closed, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
  {"Channel.empty?", 1, builtin_empty, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
  {"Channel.address", 1, builtin_address, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
  {"Address.send", 3, builtin_address_send, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
  {"System.subscribe", 1, builtin_subscribe, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
  {"System.signal_number", 1, builtin_signal_number, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
};

const size_t agc_channel_builtin_count = sizeof agc_channel_builtins / sizeof agc_channel_builtins[0];
