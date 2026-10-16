/* Lazy stream sources, transformations and terminal operations.
 * This service shares the resumable line source in files.c.
 * Design: docs/future/27-iteration-and-concurrency.md §27.4.
 */
#include "services.h"

typedef enum { STREAM_ITERATE, STREAM_LINES, STREAM_MAP, STREAM_FILTER, STREAM_TAKE, STREAM_TAKE_WHILE } stream_kind;
typedef enum { STREAM_LIST, STREAM_EACH, STREAM_REDUCE } stream_terminal;
typedef enum {
  STREAM_NONE, STREAM_NEXT, STREAM_MAP_WAIT, STREAM_FILTER_WAIT, STREAM_WHILE_WAIT, STREAM_EACH_WAIT,
  STREAM_REDUCE_WAIT
} stream_wait;

typedef struct stream_node stream_node;

struct stream_node {
  stream_kind kind;
  stream_node *parent;
  agc_value first, second;
  int64_t count;
};

typedef struct {
  agc_stepper stepper;
  stream_node **nodes;
  int64_t *remaining;
  size_t count, stage;
  stream_terminal terminal;
  stream_wait waiting;
  agc_value fn, current, accumulator, outcome;
  agc_file_lines *file;
  agc_value *items;
  size_t output_count, output_capacity;
  int64_t max;
  uint32_t span;
  bool started, source_waiting, source_done, closing;
} stream_run;

static agc_step stream_end(agc_value value) { return (agc_step){AGC_STEP_END, value, agc_void(), agc_void()}; }

static agc_step stream_wait_for_io(void) { return (agc_step){AGC_STEP_WAIT, agc_void(), agc_void(), agc_void()}; }

static agc_step stream_call(agc_value fn, agc_value value) {
  return (agc_step){AGC_STEP_CALL, value, agc_void(), fn};
}

static agc_step stream_call2(agc_value fn, agc_value first, agc_value second) {
  return (agc_step){AGC_STEP_CALL2, first, second, fn};
}

static agc_string *stream_message(const char *message) {
  size_t len = strlen(message);
  return agc_make_string(message, len, len);
}

static stream_node *stream_alloc(stream_kind kind) {
  stream_node *node = agc_alloc(sizeof(stream_node));
  node->kind = kind;
  return node;
}

static agc_value stream_source_iterate(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_as_fn(vm, args[1]);
  stream_node *node = stream_alloc(STREAM_ITERATE);
  node->first = args[0];
  node->second = args[1];
  return agc_stream_value(node);
}

static agc_value stream_source_lines(agc_vm *vm, agc_value *args, uint32_t span) {
  int64_t limit = agc_as_int(vm, args[1]);
  if (limit < 1024 || limit > 16777216)
    agc_fail_argument(vm, "RUNTIME-INVALID-COUNT", stream_message("buffer_bytes must be between 1024 and 16777216"),
                      1, span);
  stream_node *node = stream_alloc(STREAM_LINES);
  node->first = args[0];
  node->second = args[1];
  node->count = agc_as_int(vm, args[2]);
  return agc_stream_value(node);
}

static agc_value stream_transform(agc_vm *vm, agc_value *args, uint32_t span, stream_kind kind) {
  stream_node *parent = agc_as_stream(vm, args[0]);
  stream_node *node = stream_alloc(kind);
  node->parent = parent;
  if (kind == STREAM_TAKE) {
    node->count = agc_as_int(vm, args[1]);
    if (node->count < 0)
      agc_fail_argument(vm, "RUNTIME-INVALID-COUNT", stream_message("count must be nonnegative"), 1, span);
  } else {
    node->first = args[1];
    agc_as_fn(vm, args[1]);
  }
  return agc_stream_value(node);
}

static agc_value builtin_stream_map(agc_vm *vm, agc_value *args, uint32_t span) {
  return stream_transform(vm, args, span, STREAM_MAP);
}

static agc_value builtin_stream_filter(agc_vm *vm, agc_value *args, uint32_t span) {
  return stream_transform(vm, args, span, STREAM_FILTER);
}

static agc_value builtin_stream_take(agc_vm *vm, agc_value *args, uint32_t span) {
  return stream_transform(vm, args, span, STREAM_TAKE);
}

static agc_value builtin_stream_take_while(agc_vm *vm, agc_value *args, uint32_t span) {
  return stream_transform(vm, args, span, STREAM_TAKE_WHILE);
}

static void stream_setup(agc_vm *vm, stream_run *run, agc_value value) {
  stream_node *node = agc_as_stream(vm, value);
  size_t count = 0;
  stream_node *source = node;
  while (source->parent) {
    count = agc_size_add(count, 1);
    source = source->parent;
  }
  size_t length = agc_size_add(count, 1);
  run->nodes = agc_alloc(agc_size_mul(length, sizeof(stream_node *)));
  run->remaining = agc_alloc_atomic(agc_size_mul(length, sizeof(int64_t)));
  run->count = length;
  run->nodes[0] = source;
  run->remaining[0] = source->count;
  size_t at = count;
  while (node->parent) {
    run->nodes[at] = node;
    run->remaining[at] = node->count;
    at--;
    node = node->parent;
  }
}

static bool stream_zero_take(const stream_run *run) {
  for (size_t i = 1; i < run->count; i++)
    if (run->nodes[i]->kind == STREAM_TAKE && run->remaining[i] == 0) return true;
  return false;
}

static agc_value stream_result(bool ok, agc_value value) { return agc_result_value(ok, value); }

static agc_value stream_result_error(const char *message) {
  size_t len = strlen(message);
  return stream_result(false, agc_string_value(agc_make_string(message, len, len)));
}

static void stream_list_push(stream_run *run, agc_value value) {
  if (run->output_count == run->output_capacity) {
    size_t max = (size_t)run->max;
    size_t capacity = run->output_capacity ? (run->output_capacity > max / 2 ? max : run->output_capacity * 2)
                                           : (max < 16 ? max : 16);
    agc_value *items = agc_alloc(agc_size_mul(capacity, sizeof(agc_value)));
    if (run->output_count) memcpy(items, run->items, agc_size_mul(run->output_count, sizeof(agc_value)));
    run->items = items;
    run->output_capacity = capacity;
  }
  run->items[run->output_count++] = value;
}

static agc_step stream_stop(agc_vm *vm, stream_run *run, agc_value outcome, bool resumed) {
  if (!run->file || run->source_done) return stream_end(outcome);
  if (!run->closing) {
    run->closing = true;
    run->outcome = outcome;
    resumed = false;
  }
  agc_value result = agc_void();
  agc_file_line_status status = agc_file_lines_close(vm, run->file, resumed, run->outcome, &result);
  run->source_waiting = status == AGC_FILE_LINE_WAIT;
  return status == AGC_FILE_LINE_WAIT ? stream_wait_for_io() : stream_end(result);
}

static agc_step stream_complete(agc_vm *vm, stream_run *run, bool resumed) {
  if (run->terminal == STREAM_LIST)
    return stream_stop(vm, run,
                       stream_result(true, agc_list_value(agc_list_from_array(run->items, run->output_count))), resumed);
  if (run->terminal == STREAM_REDUCE)
    return stream_stop(vm, run, stream_result(true, run->accumulator), resumed);
  return stream_stop(vm, run, stream_result(true, agc_void()), resumed);
}

static agc_step stream_step(agc_vm *vm, agc_stepper *self, agc_value last) {
  stream_run *run = (stream_run *)self;
  if (run->closing) return stream_stop(vm, run, run->outcome, true);
  if (run->waiting != STREAM_NONE) {
    stream_wait waiting = run->waiting;
    run->waiting = STREAM_NONE;
    if (waiting == STREAM_NEXT) {
      run->current = last;
      run->stage = 1;
      agc_count_step(vm, run->span);
    } else if (waiting == STREAM_MAP_WAIT) {
      run->current = last;
      run->stage++;
    }
    else if (waiting == STREAM_FILTER_WAIT) {
      run->stage = agc_as_bool(vm, last) ? run->stage + 1 : 0;
    } else if (waiting == STREAM_WHILE_WAIT) {
      if (!agc_as_bool(vm, last)) return stream_complete(vm, run, false);
      run->stage++;
    } else if (waiting == STREAM_EACH_WAIT || waiting == STREAM_REDUCE_WAIT) {
      if (waiting == STREAM_EACH_WAIT) {
        const agc_result *result = agc_as_result(vm, last);
        if (!result->ok) return stream_stop(vm, run, last, false);
      } else run->accumulator = last;
      run->stage = 0;
    }
  }
  for (;;) {
    if (run->stage == 0) {
      if (stream_zero_take(run)) return stream_complete(vm, run, false);
      stream_node *source = run->nodes[0];
      if (source->kind == STREAM_LINES) {
        agc_value line = agc_void();
        agc_file_line_status status = agc_file_lines_pull(vm, run->file, run->source_waiting, last, &line);
        run->source_waiting = status == AGC_FILE_LINE_WAIT;
        if (status == AGC_FILE_LINE_WAIT) return stream_wait_for_io();
        if (status == AGC_FILE_LINE_END) {
          run->source_done = true;
          if (!agc_as_result(vm, line)->ok) return stream_end(line);
          return stream_complete(vm, run, false);
        }
        run->current = line;
        run->stage = 1;
        agc_count_step(vm, run->span);
        continue;
      }
      if (!run->started) {
        run->current = source->first;
        run->started = true;
        run->stage = 1;
        agc_count_step(vm, run->span);
      } else {
        run->waiting = STREAM_NEXT;
        return stream_call(source->second, run->current);
      }
    }
    if (run->stage < run->count) {
      size_t i = run->stage;
      stream_node *node = run->nodes[i];
      if (node->kind == STREAM_TAKE) {
        if (run->remaining[i] == 0) return stream_complete(vm, run, false);
        run->remaining[i]--;
        run->stage++;
      } else {
        run->waiting = node->kind == STREAM_MAP ? STREAM_MAP_WAIT
                       : node->kind == STREAM_FILTER ? STREAM_FILTER_WAIT : STREAM_WHILE_WAIT;
        return stream_call(node->first, run->current);
      }
      continue;
    }
    if (run->terminal == STREAM_LIST) {
      if ((int64_t)run->output_count == run->max)
        return stream_stop(vm, run, stream_result_error("stream: exceeds max items"), false);
      stream_list_push(run, run->current);
    } else if (run->terminal == STREAM_EACH) {
      run->waiting = STREAM_EACH_WAIT;
      return stream_call(run->fn, run->current);
    } else {
      run->waiting = STREAM_REDUCE_WAIT;
      return stream_call2(run->fn, run->accumulator, run->current);
    }
    run->stage = 0;
  }
}

static agc_value stream_terminal_start(agc_vm *vm, agc_value *args, uint32_t span, stream_terminal terminal) {
  stream_run *run = agc_alloc(sizeof(stream_run));
  run->stepper.step = stream_step;
  run->terminal = terminal;
  run->span = span;
  run->outcome = agc_void();
  stream_setup(vm, run, args[0]);
  if (terminal == STREAM_LIST) {
    run->max = agc_as_int(vm, args[1]);
    if (run->max < 0)
      agc_fail_argument(vm, "RUNTIME-INVALID-COUNT", stream_message("max must be nonnegative"), 1, span);
  } else if (terminal == STREAM_EACH) {
    run->fn = args[1];
    agc_as_fn(vm, run->fn);
  } else {
    run->accumulator = args[1];
    run->fn = args[2];
    agc_as_fn(vm, run->fn);
  }
  if (terminal == STREAM_LIST && run->max == 0)
    return stream_result(true, agc_list_value(agc_list_from_array(NULL, 0)));
  stream_node *source = run->nodes[0];
  if (source->kind == STREAM_LINES) {
    if (source->count <= 0) return stream_result_error("filesystem: timeout must be positive milliseconds");
    run->file = agc_file_lines_new(source->first, (size_t)agc_as_int(vm, source->second), source->count);
  }
  agc_task_stepper(vm, &run->stepper);
  return agc_void();
}

static agc_value builtin_stream_to_list(agc_vm *vm, agc_value *args, uint32_t span) {
  return stream_terminal_start(vm, args, span, STREAM_LIST);
}

static agc_value builtin_stream_each(agc_vm *vm, agc_value *args, uint32_t span) {
  return stream_terminal_start(vm, args, span, STREAM_EACH);
}

static agc_value builtin_stream_reduce(agc_vm *vm, agc_value *args, uint32_t span) {
  return stream_terminal_start(vm, args, span, STREAM_REDUCE);
}

const agc_builtin agc_lazy_stream_builtins[] = {
  {"Stream.lines", 3, stream_source_lines, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"__stream_iterate", 2, stream_source_iterate, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"__stream_to_list", 2, builtin_stream_to_list, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"__stream_each", 2, builtin_stream_each, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"__stream_reduce", 3, builtin_stream_reduce, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"__stream_map", 2, builtin_stream_map, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"__stream_filter", 2, builtin_stream_filter, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"__stream_take", 2, builtin_stream_take, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"__stream_take_while", 2, builtin_stream_take_while, AGC_NATIVE_NONE, AGC_COST_NONE},
};

const size_t agc_lazy_stream_builtin_count = sizeof agc_lazy_stream_builtins / sizeof agc_lazy_stream_builtins[0];
