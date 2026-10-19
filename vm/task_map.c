/*
 * Task.map: runs a block for each item of a list in its own task, at most `limit` at a time, each item with its own
 * deadline, and gives one Result per item in input order. The caller parks in a stepper and does all the work in its
 * own turns, so every spawn, cancel and slot write happens with the caller as the running task. Core layer. Design:
 * docs/future/27-iteration-and-concurrency.md §27.1 and docs/vm/10-io-scheduler.md §10.2.1 (Task.map).
 */
#include "core.h"

#define MAX_LIMIT 1024

typedef struct map_group map_group;

/* One item. While `running` it is on the group's running list, which is in start order; an item that ended waits on
   the ended list (linked by `next`) until the caller runs. */
typedef struct map_item {
  map_group *group;
  agc_task *task;
  size_t index;
  uint64_t deadline;
  struct map_item *prev, *next;
  bool running;
} map_item;

/* The stepper is the first member, because the interpreter hands the group's own pointer back to map_step. */
struct map_group {
  agc_stepper stepper;
  agc_task *caller;
  const agc_list *items;
  agc_value fn;
  agc_value *slots;
  size_t count, next, running, settled, limit;
  int64_t timeout;
  uint32_t span;
  map_item *oldest, *newest, *ended, *ended_last;
};

static void running_add(map_group *g, map_item *it) {
  it->prev = g->newest;
  it->next = NULL;
  if (g->newest)
    g->newest->next = it;
  else
    g->oldest = it;
  g->newest = it;
  g->running++;
}

static void running_remove(map_group *g, map_item *it) {
  if (it->prev)
    it->prev->next = it->next;
  else
    g->oldest = it->next;
  if (it->next)
    it->next->prev = it->prev;
  else
    g->newest = it->prev;
  it->prev = it->next = NULL;
  it->running = false;
  g->running--;
}

/* The end hook of an item task (finish_task calls it for a return, a crash and a cancel). An item that already ran out
   of time is settled and the hook has nothing to do. An item that is cancelled otherwise was reached by the cancel of
   its caller (items are the caller's children, so only a cancel of the caller or an ancestor gets to them): its slot
   is never written and the caller, which is about to end, is not woken. An item that still has files to close is not
   settled, as for Task.await (state DONE and no close pending): it puts the hook back, and agc_task_close_done calls it
   again when the last close ends. */
static void item_ended(agc_vm *vm, agc_task *t) {
  map_item *it = t->end_data;
  if (!it->running || t->cancelled) {
    t->end_data = NULL;
    return;
  }
  if (t->closing) {
    t->end = item_ended;
    return;
  }
  t->end_data = NULL;
  map_group *g = it->group;
  running_remove(g, it);
  if (g->ended_last)
    g->ended_last->next = it;
  else
    g->ended = it;
  g->ended_last = it;
  agc_task_wake(vm, g->caller, "map");
}

/* A crashed item is observed here, so its crash is not reported as unobserved; the caller reads it as a value. */
static agc_value item_result(agc_vm *vm, const map_group *g, agc_task *t) {
  if (t->crashed) {
    agc_task_observe(vm, t);
    return agc_result_value(false, agc_string_value(t->crash));
  }
  if (!agc_is(t->result, AGC_T_RESULT))
    agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: a Task.map block did not give a Result", g->span);
  return t->result;
}

static void collect(agc_vm *vm, map_group *g) {
  while (g->ended) {
    map_item *it = g->ended;
    g->ended = it->next;
    if (!g->ended) g->ended_last = NULL;
    it->next = NULL;
    g->slots[it->index] = item_result(vm, g, it->task);
    g->settled++;
  }
}

/* Every item has the same timeout and starts in input order, so the deadlines grow along the running list and the
   oldest item is the only one to look at. The slot is written before the cancel, so the end hook sees a settled item.
   An item that already ended (it crashed or returned) but is still closing its files has nothing to cancel; it is
   settled as timed out at its deadline, and a crash of it, which nobody will read, counts as observed. */
static void expire(agc_vm *vm, map_group *g, uint64_t now) {
  while (g->oldest && g->oldest->deadline <= now) {
    map_item *it = g->oldest;
    running_remove(g, it);
    g->slots[it->index] = agc_error_value("task: timed out");
    g->settled++;
    if (it->task->crashed) agc_task_observe(vm, it->task);
    agc_task_cancel(vm, it->task);
  }
}

/* The items are children of the caller, spawned with its random stream split as Task.spawn does, so a run with a seed
   is the same however long the items take. */
static void start(agc_vm *vm, map_group *g, uint64_t now) {
  while (g->running < g->limit && g->next < g->count) {
    agc_count_step(vm, g->span);
    agc_value arg = agc_list_get(g->items, g->next);
    map_item *it = agc_alloc(sizeof(map_item));
    it->group = g;
    it->index = g->next++;
    it->deadline = now + (uint64_t)g->timeout;
    it->running = true;
    it->task = agc_task_spawn_seeded(vm, vm->task, g->fn, &arg, 1, g->span);
    it->task->end = item_ended;
    it->task->end_data = it;
    running_add(g, it);
  }
}

/* Runs on the caller each time it wakes: an item ended, or the timer of the oldest deadline fired. The caller never
   waits on anything else, so it has a timer for as long as an item runs. */
static agc_step map_step(agc_vm *vm, agc_stepper *self, agc_value last) {
  (void)last;
  map_group *g = (map_group *)self;
  collect(vm, g);
  uint64_t now = agc_clock_ms();
  expire(vm, g, now);
  start(vm, g, now);
  if (g->settled == g->count) {
    agc_charge(vm, g->count);
    return (agc_step){AGC_STEP_END, agc_list_value(agc_list_from_array(g->slots, g->count))};
  }
  if (!g->oldest) agc_fail(vm, "RUNTIME-INTERNAL", "Task.map has pending items and none running", g->span);
  agc_io_start(vm, &agc_wait_io, NULL, agc_void(), (int64_t)(g->oldest->deadline - now));
  return (agc_step){AGC_STEP_WAIT, agc_void()};
}

/* The arguments are checked before any item starts, and before the empty-list shortcut. */
static agc_value builtin_map(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_list *items = agc_as_list(vm, args[0]);
  int64_t limit = agc_as_int(vm, args[1]);
  int64_t timeout = agc_as_int(vm, args[2]);
  agc_as_fn(vm, args[3]);
  if (limit < 1 || limit > MAX_LIMIT)
    agc_fail(vm, "RUNTIME-INVALID-COUNT", "limit must be between 1 and 1024", span + 2);
  if (timeout <= 0) agc_fail(vm, "RUNTIME-INVALID-DURATION", "timeout must be positive milliseconds", span + 3);
  size_t count = agc_list_len(items);
  if (count == 0) return args[0];
  map_group *g = agc_alloc(sizeof(map_group));
  g->stepper.step = map_step;
  g->caller = vm->task;
  g->items = items;
  g->fn = args[3];
  g->slots = agc_alloc(agc_size_mul(count, sizeof(agc_value)));
  g->count = count;
  g->limit = (size_t)limit;
  g->timeout = timeout;
  g->span = span;
  agc_task_stepper(vm, &g->stepper);
  return agc_void();
}

const agc_builtin agc_task_map_builtins[] = {
  {"Task.map", 4, builtin_map, AGC_NATIVE_NONE, AGC_COST_NONE, true},
};

const size_t agc_task_map_builtin_count = sizeof agc_task_map_builtins / sizeof agc_task_map_builtins[0];
