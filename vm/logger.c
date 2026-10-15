/*
 * The LogRegistry builtins (agc_logger_builtins): the handler table and the
 * global level of std/logger, kept in vm->rt->log. None of them calls a
 * handler; stdlib/logger.agc does, in the task that logs. Service layer.
 * Design: docs/future/24-logging.md §24.2 and docs/vm/10-io-multicore.md §10.2.3.
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

static void refresh_lowest(agc_log_registry *log) {
  int64_t lowest = AGC_LOG_NO_HANDLER;
  for (size_t i = 0; i < log->count; i++) {
    if (log->items[i].rank < lowest) lowest = log->items[i].rank;
  }
  log->lowest = lowest;
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
  refresh_lowest(log);
}

static agc_value builtin_level(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  return agc_int(vm->rt->log.level);
}

static agc_value builtin_set_level(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  vm->rt->log.level = agc_as_int(vm, args[0]);
  return agc_void();
}

static agc_value builtin_lowest(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  return agc_int(vm->rt->log.lowest);
}

/* One native call with no yield between the check and the writes: two tasks
 * that make their first calls together install the console handler once, and
 * a later detach stays in effect because the level is no longer -1. */
static agc_value builtin_install_default(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_log_registry *log = &vm->rt->log;
  (void)agc_as_fn(vm, args[0]);
  if (log->level != -1) return agc_void();
  agc_string *name = agc_make_string("console", 7, 7);
  append(log, agc_string_value(name), DEFAULT_RANK, args[0]);
  log->level = DEFAULT_RANK;
  return agc_void();
}

static agc_value builtin_attach(agc_vm *vm, agc_value *args, uint32_t span) {
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
  {"LogRegistry.level", 0, builtin_level, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"LogRegistry.set_level", 1, builtin_set_level, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"LogRegistry.lowest", 0, builtin_lowest, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"LogRegistry.install_default", 1, builtin_install_default, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"LogRegistry.attach", 3, builtin_attach, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"LogRegistry.detach", 1, builtin_detach, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"LogRegistry.names", 0, builtin_names, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"LogRegistry.handlers", 1, builtin_handlers, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"LogRegistry.task_id", 0, builtin_task_id, AGC_NATIVE_NONE, AGC_COST_NONE},
};

const size_t agc_logger_builtin_count = sizeof agc_logger_builtins / sizeof agc_logger_builtins[0];
