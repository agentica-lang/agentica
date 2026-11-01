/*
 * The LogRegistry builtins (agc_logger_builtins): the handler table and the
 * global level of std/logger, kept in vm->rt->log. None of them calls a
 * handler; stdlib/logger.agc does, in the task that logs. Service layer.
 * The table is not locked: with tasks on several cores it needs a lock (the
 * same one as the stderr buffer).
 * Design: the grammar's logging section and docs/vm/10-io-multicore.md §10.2.3.
 */
#include "services.h"

#include <string.h>

#define INITIAL_HANDLERS 4
#define DEFAULT_RANK 1

static agc_value ok_void(void) { return agc_result_value(true, agc_void()); }

static agc_value taken_error(const agc_string *name, const char *before, const char *after) {
  agc_string *head = agc_make_string(before, strlen(before), strlen(before));
  agc_string *tail = agc_make_string(after, strlen(after), strlen(after));
  agc_string *text = agc_concat(agc_concat(head, name), tail);
  return agc_result_value(false, agc_string_value(text));
}

static bool find(agc_vm *vm, const agc_string *name, size_t *at) {
  const agc_log_registry *log = &vm->rt->log;
  for (size_t i = 0; i < log->count; i++) {
    if (agc_same_string(vm, agc_as_string(vm, log->items[i].name), name)) {
      *at = i;
      return true;
    }
  }
  return false;
}

static int64_t read_rank(const _Atomic int64_t *rank) { return atomic_load_explicit(rank, memory_order_relaxed); }

/* The writers hold rt->sync, so the three stores need no order between them: a leaf reader reads one of them. */
static void set_ranks(agc_log_registry *log, int64_t level, int64_t lowest) {
  atomic_store_explicit(&log->level, level, memory_order_relaxed);
  atomic_store_explicit(&log->lowest, lowest, memory_order_relaxed);
  atomic_store_explicit(&log->floor, level < 0 ? -1 : level > lowest ? level : lowest, memory_order_relaxed);
}

/* Only a detach needs the full scan: an append can only lower the minimum. */
static void refresh_lowest(agc_log_registry *log) {
  int64_t lowest = AGC_LOG_NO_HANDLER;
  for (size_t i = 0; i < log->count; i++) {
    if (log->items[i].rank < lowest) lowest = log->items[i].rank;
  }
  set_ranks(log, read_rank(&log->level), lowest);
}

/* The array is replaced, never grown in place, and lives in the GC heap: the
 * runtime reaches it through vm->rt, so the names and handler values stay
 * alive for as long as they are attached. */
static void append(agc_log_registry *log, agc_value name, int64_t rank, agc_value handler) {
  if (log->count == log->cap) {
    size_t cap = log->cap ? agc_size_mul(log->cap, 2) : INITIAL_HANDLERS;
    agc_log_handler *items = agc_alloc(agc_size_mul(cap, sizeof *items));
    if (log->count) memcpy(items, log->items, log->count * sizeof *items);
    log->items = items;
    log->cap = cap;
  }
  log->items[log->count++] = (agc_log_handler){name, handler, rank};
  if (rank < read_rank(&log->lowest)) set_ranks(log, read_rank(&log->level), rank);
}

/* LogRegistry.level, .floor and .lowest are leaf rows, so compiled code calls them and `on` compiles a function such
 * as Logger.debug that calls them: each reads one atomic of the registry, which the writers (set_level,
 * install_default, attach, detach) change under rt->sync, and does nothing else. */
static agc_value builtin_level(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  return agc_int(read_rank(&vm->rt->log.level));
}

/* The level a call needs to beat: -1 until the default is installed, then the
 * higher of the global level and the lowest handler rank. A call below it
 * reaches no handler, so a disabled call and a call that no handler accepts
 * both cost one comparison. No handler gives AGC_LOG_NO_HANDLER, above every
 * level. */
static agc_value builtin_floor(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  return agc_int(read_rank(&vm->rt->log.floor));
}

static agc_value builtin_set_level(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_sync_assert(vm);
  (void)span;
  agc_log_registry *log = &vm->rt->log;
  set_ranks(log, agc_as_int(vm, args[0]), read_rank(&log->lowest));
  return agc_void();
}

static agc_value builtin_lowest(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  return agc_int(read_rank(&vm->rt->log.lowest));
}

/* One native call with no yield between the check and the writes: two tasks
 * that make their first calls together install the console handler once, and
 * a later detach stays in effect because the level is no longer -1. */
static agc_value builtin_install_default(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_sync_assert(vm);
  (void)span;
  agc_log_registry *log = &vm->rt->log;
  (void)agc_as_fn(vm, args[0]);
  if (read_rank(&log->level) != -1) return agc_void();
  agc_string *name = agc_make_string("console", 7, 7);
  size_t at;
  if (!find(vm, name, &at)) append(log, agc_string_value(name), DEFAULT_RANK, args[0]);
  set_ranks(log, DEFAULT_RANK, read_rank(&log->lowest));
  return agc_void();
}

static agc_value builtin_attach(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_sync_assert(vm);
  (void)span;
  agc_string *name = agc_as_string(vm, args[0]);
  int64_t rank = agc_as_int(vm, args[1]);
  (void)agc_as_fn(vm, args[2]);
  size_t at;
  if (find(vm, name, &at)) return taken_error(name, "a handler named \"", "\" is already attached");
  append(&vm->rt->log, args[0], rank, args[2]);
  return ok_void();
}

static agc_value builtin_detach(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_sync_assert(vm);
  (void)span;
  agc_log_registry *log = &vm->rt->log;
  agc_string *name = agc_as_string(vm, args[0]);
  size_t at;
  if (!find(vm, name, &at)) return taken_error(name, "no handler named \"", "\" is attached");
  memmove(&log->items[at], &log->items[at + 1], (log->count - at - 1) * sizeof *log->items);
  log->count--;
  memset(&log->items[log->count], 0, sizeof *log->items);
  refresh_lowest(log);
  return ok_void();
}

static agc_value builtin_names(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  const agc_log_registry *log = &vm->rt->log;
  agc_list_builder b;
  agc_list_builder_sized(&b, log->count);
  for (size_t i = 0; i < log->count; i++) agc_list_builder_push(&b, log->items[i].name);
  return agc_list_value(agc_list_builder_finish(&b));
}

/* The list is a copy, so a handler that attaches or detaches another does not
 * change the handlers of the event in progress. */
static agc_value builtin_handlers(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_log_registry *log = &vm->rt->log;
  int64_t rank = agc_as_int(vm, args[0]);
  size_t n = 0;
  for (size_t i = 0; i < log->count; i++) n += log->items[i].rank <= rank;
  agc_list_builder b;
  agc_list_builder_sized(&b, n);
  for (size_t i = 0; i < log->count; i++) {
    if (log->items[i].rank <= rank) agc_list_builder_push(&b, log->items[i].handler);
  }
  return agc_list_value(agc_list_builder_finish(&b));
}

static agc_value builtin_task_id(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  return agc_int((int64_t)vm->task->id);
}

const agc_builtin agc_logger_builtins[] = {
  {"LogRegistry.level", 0, builtin_level, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false},
  {"LogRegistry.floor", 0, builtin_floor, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false},
  {"LogRegistry.set_level", 1, builtin_set_level, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
  {"LogRegistry.lowest", 0, builtin_lowest, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false},
  {"LogRegistry.install_default", 1, builtin_install_default, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
  {"LogRegistry.attach", 3, builtin_attach, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false, false},
  {"LogRegistry.detach", 1, builtin_detach, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false, false},
  {"LogRegistry.names", 0, builtin_names, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false, false},
  {"LogRegistry.handlers", 1, builtin_handlers, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false, false},
  {"LogRegistry.task_id", 0, builtin_task_id, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
};

const size_t agc_logger_builtin_count = sizeof agc_logger_builtins / sizeof agc_logger_builtins[0];
