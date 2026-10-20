/*
 * Lazy[T]: an immutable recipe of a source and steps, run one item at a time by a terminal
 * (docs/future/27-iteration-and-concurrency.md §27.4). The prelude (stdlib/prelude/lazy.agc) gives the typed names;
 * the builtins here are prelude-only. Nodes never change after they are made, so a Lazy can be shared by tasks on
 * any scheduler and run more than once: each terminal call has its own run state, and its callbacks run on the task
 * that called it. The I/O sources (File.foreach, ch.lazy) open or read only inside a terminal; their terminal parks
 * on the file job or the channel like any other wait, and so does write_lines, the terminal that writes to a file. A
 * failed `try` in a block ends the run with its error (agc_stepper.escaped). Service layer.
 */
#include "services.h"

typedef enum {
  LAZY_LIST, LAZY_RANGE, LAZY_PRODUCE, LAZY_MAP, LAZY_FILTER, LAZY_TAKE_WHILE, LAZY_DROP_WHILE, LAZY_TAKE, LAZY_DROP,
  LAZY_EACH_SLICE, LAZY_EACH_CONS, LAZY_WITH_INDEX, LAZY_FLAT_MAP, LAZY_CHUNK_WHILE, LAZY_FILE, LAZY_CHANNEL
} lazy_kind;

typedef struct lazy_node lazy_node;

struct lazy_node {
  lazy_kind kind;
  const lazy_node *parent; /* NULL for a source */
  size_t depth;            /* nodes from the source to this one, both included */
  agc_value value;         /* the list or range of a source, the seed of produce, the path of a file, the channel */
  agc_value fn;            /* the callback of a step, or of produce */
  int64_t count;           /* the count of take and drop, the size of each_slice and each_cons, a file's buffer */
  int64_t timeout;         /* a file or channel source: the timeout of each wait */
};

/* The state of one stage in one run. */
typedef struct {
  int64_t left;           /* take and drop: items left; with_index: the next index */
  bool dropping;          /* drop_while: still dropping */
  agc_value *items;       /* each_slice and chunk_while: the group so far; each_cons: a ring of the last items */
  size_t len, cap, head;  /* items used, allocated, and (each_cons) the oldest */
  agc_value prev;         /* chunk_while: the item before */
  agc_list_cursor rest;   /* flat_map: the rest of the list the callback gave */
  bool pending;
} lazy_stage;

typedef enum { LAZY_TO_A, LAZY_EACH, LAZY_REDUCE, LAZY_FIND, LAZY_WRITE } lazy_terminal;

/* What the run waits for: a callback of the source (produce), of a stage or of the terminal; a file job or a channel
   value of an I/O source (WAIT_IO); the close of the source's file before the terminal returns (WAIT_CLOSE); a file
   job of write_lines (WAIT_SINK: the open or a write; WAIT_SINK_CLOSE: its flush and close at the end). */
typedef enum {
  WAIT_NONE, WAIT_SOURCE, WAIT_STAGE, WAIT_TERMINAL, WAIT_IO, WAIT_CLOSE, WAIT_SINK, WAIT_SINK_CLOSE
} lazy_wait;

typedef enum { NEXT_ITEM, NEXT_NONE, NEXT_STEP } lazy_pull;

typedef struct {
  agc_stepper stepper;
  const lazy_node **nodes; /* nodes[0] is the source */
  lazy_stage *stages;
  size_t count;
  size_t ended;
  size_t at;      /* the stage the item enters next; 0 when a new item is needed; count is the terminal */
  agc_value item;
  lazy_wait waiting;
  lazy_terminal terminal;
  agc_value fn, acc;
  agc_value *out;
  size_t out_len, out_cap;
  agc_list_cursor items;  /* a list source */
  int64_t next, last;     /* a range source: the next value and the last one */
  bool more, started;     /* a range source has values left; produce gave its seed */
  agc_value seed;         /* produce: the last item it gave */
  agc_line_reader *lines; /* a file source: its reader, which owns the open file */
  agc_line_writer *sink;  /* write_lines: its writer, which owns the file it writes */
  bool sink_ready;        /* write_lines: the file is open, so items may be pulled */
  agc_value io_last;      /* a file source: the result of the job it waited on */
  agc_value final;        /* the result, kept while the files close */
  uint32_t span;
} lazy_run;

static agc_step lazy_end(agc_value value) { return (agc_step){.kind = AGC_STEP_END, .value = value}; }

static agc_step lazy_call(agc_value fn, agc_value value) {
  return (agc_step){.kind = AGC_STEP_CALL, .value = value, .fn = fn};
}

static agc_step lazy_call2(agc_value fn, agc_value first, agc_value second) {
  return (agc_step){.kind = AGC_STEP_CALL2, .value = first, .second = second, .fn = fn};
}

static agc_value lazy_error(const char *message) {
  size_t len = strlen(message);
  return agc_result_value(false, agc_string_value(agc_make_string(message, len, len)));
}

/* Argument 1 of the prelude function is the bad one: the count of take, drop, first, each_slice and each_cons, the
   buffer_bytes of File.foreach, the timeout_ms of ch.lazy. */
static _Noreturn void lazy_fail_argument(agc_vm *vm, const char *code, const char *message, uint32_t span) {
  size_t len = strlen(message);
  agc_fail_argument(vm, code, agc_make_string(message, len, len), 1, span);
}

static _Noreturn void lazy_fail_count(agc_vm *vm, const char *message, uint32_t span) {
  lazy_fail_argument(vm, "RUNTIME-INVALID-COUNT", message, span);
}

static lazy_node *lazy_new_source(lazy_kind kind, agc_value value, agc_value fn) {
  lazy_node *node = agc_alloc(sizeof(lazy_node));
  node->kind = kind;
  node->depth = 1;
  node->value = value;
  node->fn = fn;
  return node;
}

static agc_value lazy_source(lazy_kind kind, agc_value value, agc_value fn) {
  return agc_lazy_value(lazy_new_source(kind, value, fn));
}

static agc_value lazy_step_node(agc_vm *vm, agc_value parent, lazy_kind kind, agc_value fn, int64_t count) {
  const lazy_node *before = agc_as_lazy(vm, parent);
  lazy_node *node = agc_alloc(sizeof(lazy_node));
  node->kind = kind;
  node->parent = before;
  node->depth = agc_size_add(before->depth, 1);
  node->fn = fn;
  node->count = count;
  return agc_lazy_value(node);
}

static agc_value builtin_list(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_as_list(vm, args[0]);
  return lazy_source(LAZY_LIST, args[0], agc_void());
}

static agc_value builtin_range(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_as_range(vm, args[0]);
  return lazy_source(LAZY_RANGE, args[0], agc_void());
}

static agc_value builtin_produce(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_as_fn(vm, args[1]);
  return lazy_source(LAZY_PRODUCE, args[0], args[1]);
}

/* __lazy_file(path, buffer_bytes, timeout_ms): File.foreach. Nothing is opened here; a bad timeout or path is the
   error of the terminal, as for File.each_line. */
static agc_value builtin_file(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_as_string(vm, args[0]);
  int64_t buffer = agc_as_int(vm, args[1]);
  if (!agc_lines_buffer_ok(buffer))
    lazy_fail_count(vm, "buffer_bytes must be between 1024 and 16777216", span);
  lazy_node *node = lazy_new_source(LAZY_FILE, args[0], agc_void());
  node->count = buffer;
  node->timeout = agc_as_int(vm, args[2]);
  return agc_lazy_value(node);
}

/* __lazy_channel(channel, timeout_ms): ch.lazy. */
static agc_value builtin_channel(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_as_channel(vm, args[0]);
  int64_t timeout = agc_as_int(vm, args[1]);
  if (timeout < 0) lazy_fail_argument(vm, "RUNTIME-INVALID-DURATION", AGC_CHANNEL_BAD_TIMEOUT, span);
  lazy_node *node = lazy_new_source(LAZY_CHANNEL, args[0], agc_void());
  node->timeout = timeout;
  return agc_lazy_value(node);
}

/* A step of (lazy, f): map, with_index, flat_map, chunk_while. */
static agc_value lazy_fn_step(agc_vm *vm, const agc_value *args, lazy_kind kind) {
  agc_as_fn(vm, args[1]);
  return lazy_step_node(vm, args[0], kind, args[1], 0);
}

static agc_value builtin_map(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return lazy_fn_step(vm, args, LAZY_MAP);
}

static agc_value builtin_with_index(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return lazy_fn_step(vm, args, LAZY_WITH_INDEX);
}

static agc_value builtin_flat_map(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return lazy_fn_step(vm, args, LAZY_FLAT_MAP);
}

static agc_value builtin_chunk_while(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return lazy_fn_step(vm, args, LAZY_CHUNK_WHILE);
}

/* __lazy_test(lazy, kind, f): 0 filter, 1 take_while, 2 drop_while (stdlib/prelude/lazy.agc). */
static agc_value builtin_test(agc_vm *vm, agc_value *args, uint32_t span) {
  static const lazy_kind kinds[] = {LAZY_FILTER, LAZY_TAKE_WHILE, LAZY_DROP_WHILE};
  int64_t which = agc_as_int(vm, args[1]);
  if (which < 0 || which > 2) agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: unknown Lazy test step", span);
  agc_as_fn(vm, args[2]);
  return lazy_step_node(vm, args[0], kinds[which], args[2], 0);
}

/* __lazy_count(lazy, kind, count): 0 take, 1 drop. */
static agc_value builtin_count(agc_vm *vm, agc_value *args, uint32_t span) {
  int64_t which = agc_as_int(vm, args[1]);
  if (which < 0 || which > 1) agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: unknown Lazy count step", span);
  int64_t count = agc_as_int(vm, args[2]);
  if (count < 0) lazy_fail_count(vm, "count must be nonnegative", span);
  return lazy_step_node(vm, args[0], which == 0 ? LAZY_TAKE : LAZY_DROP, agc_void(), count);
}

/* __lazy_group(lazy, kind, size): 0 each_slice, 1 each_cons. */
static agc_value builtin_group(agc_vm *vm, agc_value *args, uint32_t span) {
  int64_t which = agc_as_int(vm, args[1]);
  if (which < 0 || which > 1) agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: unknown Lazy group step", span);
  int64_t size = agc_as_int(vm, args[2]);
  if (size < 1) lazy_fail_count(vm, "size must be at least 1", span);
  return lazy_step_node(vm, args[0], which == 0 ? LAZY_EACH_SLICE : LAZY_EACH_CONS, agc_void(), size);
}

/* Room for one more item in a stage's buffer. The buffer grows as items come, never past the size of the step, so a
   large size with few items allocates little. */
static void lazy_grow(lazy_stage *s, size_t limit) {
  if (s->len < s->cap) return;
  size_t cap = s->cap ? (s->cap > limit / 2 ? limit : s->cap * 2) : (limit < 8 ? limit : 8);
  agc_value *items = agc_alloc(agc_size_mul(cap, sizeof(agc_value)));
  /* A ring (each_cons) is full only when cap == limit, so it never grows with head != 0. */
  if (s->len) memcpy(items, s->items, agc_size_mul(s->len, sizeof(agc_value)));
  s->items = items;
  s->cap = cap;
}

static void lazy_push(lazy_stage *s, agc_value item) {
  lazy_grow(s, SIZE_MAX / sizeof(agc_value));
  s->items[s->len++] = item;
}

/* The buffer as a new list; the stage starts empty again. */
static agc_value lazy_group(lazy_stage *s) {
  agc_value list = agc_list_value(agc_list_from_array(s->items, s->len));
  s->len = 0;
  return list;
}

static void lazy_out(lazy_run *run, agc_value item) {
  if (run->out_len == run->out_cap) {
    size_t cap = run->out_cap ? agc_size_mul(run->out_cap, 2) : 16;
    agc_value *out = agc_alloc(agc_size_mul(cap, sizeof(agc_value)));
    if (run->out_len) memcpy(out, run->out, agc_size_mul(run->out_len, sizeof(agc_value)));
    run->out = out;
    run->out_cap = cap;
  }
  run->out[run->out_len++] = item;
}

static void lazy_end_at(lazy_run *run, size_t stage) {
  if (run->ended < stage + 1) run->ended = stage + 1;
}

static agc_value lazy_finish(lazy_run *run) {
  switch (run->terminal) {
    case LAZY_TO_A: return agc_result_value(true, agc_list_value(agc_list_from_array(run->out, run->out_len)));
    case LAZY_EACH: return agc_result_value(true, agc_void());
    case LAZY_REDUCE: return agc_result_value(true, run->acc);
    case LAZY_WRITE: return agc_result_value(true, agc_void());
    case LAZY_FIND: break;
  }
  return lazy_error("not found");
}

/* The calls of a run that touch shared state: the line reader and writer start file jobs and close the handle, a
   receive changes the channel's lists and parks on them. The run is `unlocked` (agc_stepper), so each takes rt->sync
   only for the call, and a park is registered inside it; the drop comes before the step returns WAIT. A failure
   inside jumps out with the lock held, and agc_sync_reset gives it back. */
static agc_lines_status lazy_lines_next(agc_vm *vm, lazy_run *run, agc_value last, agc_value *out) {
  agc_sync_take(vm);
  agc_lines_status status = agc_lines_next(vm, run->lines, last, out);
  agc_sync_drop(vm);
  return status;
}

static agc_writer_status lazy_write(agc_vm *vm, lazy_run *run, agc_value last, agc_value line, agc_value *out) {
  agc_sync_take(vm);
  agc_writer_status status = agc_writer_next(vm, run->sink, last, line, out);
  agc_sync_drop(vm);
  return status;
}

static agc_recv_status lazy_receive(agc_vm *vm, const lazy_node *source, agc_value *out) {
  agc_sync_take(vm);
  agc_recv_status status = agc_channel_receive(vm, agc_as_channel(vm, source->value), source->timeout, out);
  agc_sync_drop(vm);
  return status;
}

/* Closes the file of a file source, then the file of write_lines, then ends the terminal with `result` (kept in
   run->final while a close waits). Every end of a run comes here, so the files are closed whatever ended it: the end
   of the items, a take or find that had enough, an error from a callback, a failed `try` in a block, a failed read
   or write. A raise, a cancel or --max-steps ends the task instead, and the task's end closes the files it owns. The
   writer's own error (a failed flush or close) is the result when the run had none. */
static agc_step lazy_done(agc_vm *vm, lazy_run *run, agc_value result, agc_value last) {
  if (!run->lines && !run->sink) return lazy_end(result);
  lazy_wait waiting = run->waiting;
  if (waiting != WAIT_CLOSE && waiting != WAIT_SINK_CLOSE) {
    run->final = result;
    if (run->lines) agc_lines_stop(run->lines, result);
    if (run->sink) agc_writer_stop(run->sink, result);
    last = agc_void();
  }
  run->waiting = WAIT_NONE;
  agc_value outcome = agc_void();
  if (run->lines && waiting != WAIT_SINK_CLOSE) {
    if (lazy_lines_next(vm, run, last, &outcome) == AGC_LINES_WAIT) {
      run->waiting = WAIT_CLOSE;
      return (agc_step){.kind = AGC_STEP_WAIT};
    }
    last = agc_void();
  }
  if (run->sink) {
    if (lazy_write(vm, run, last, agc_void(), &outcome) == AGC_WRITER_WAIT) {
      run->waiting = WAIT_SINK_CLOSE;
      return (agc_step){.kind = AGC_STEP_WAIT};
    }
    if (agc_as_result(vm, run->final)->ok) run->final = outcome;
  }
  return lazy_end(run->final);
}

/* write_lines: drives the writer with `line` (Void for none) after a job came back with `last`. False when it waits
   for the next line; true with *step when the run parks on a file job or ends (the open or a write failed). */
static bool lazy_sink(agc_vm *vm, lazy_run *run, agc_value last, agc_value line, agc_step *step) {
  agc_value out = agc_void();
  switch (lazy_write(vm, run, last, line, &out)) {
    case AGC_WRITER_READY: run->sink_ready = true; return false;
    case AGC_WRITER_WAIT:
      run->waiting = WAIT_SINK;
      *step = (agc_step){.kind = AGC_STEP_WAIT};
      return true;
    case AGC_WRITER_END: break;
  }
  *step = lazy_done(vm, run, out, agc_void());
  return true;
}

/* A callback came back with `last`, for the stage at run->at (or the source, or the terminal). */
static bool lazy_resume(agc_vm *vm, lazy_run *run, agc_value last, agc_step *done) {
  lazy_wait waiting = run->waiting;
  if (waiting == WAIT_CLOSE || waiting == WAIT_SINK_CLOSE) {
    *done = lazy_done(vm, run, run->final, last);
    return true;
  }
  run->waiting = WAIT_NONE;
  if (run->stepper.escaped) {
    /* A failed `try` in the block that just returned: `last` is its error, and it ends the run. */
    run->stepper.escaped = false;
    if (waiting != WAIT_SOURCE && waiting != WAIT_STAGE && waiting != WAIT_TERMINAL)
      agc_fail(vm, "RUNTIME-INTERNAL", "a Lazy block escaped while no block ran", run->span);
    if (agc_as_result(vm, last)->ok) agc_fail(vm, "RUNTIME-INTERNAL", "a Lazy block escaped with ok", run->span);
    *done = lazy_done(vm, run, last, agc_void());
    return true;
  }
  if (waiting == WAIT_SINK) {
    if (lazy_sink(vm, run, last, agc_void(), done)) return true;
    run->at = 0;
    return false;
  }
  if (waiting == WAIT_IO) {
    /* A file job's result; a channel wait is a retry park, so its `last` means nothing and the receive runs again. */
    run->io_last = last;
    return false;
  }
  if (waiting == WAIT_SOURCE) {
    run->seed = last;
    run->item = last;
    run->at = 1;
    return false;
  }
  if (waiting == WAIT_TERMINAL) {
    run->at = 0;
    if (run->terminal == LAZY_EACH && !agc_as_result(vm, last)->ok) {
      *done = lazy_done(vm, run, last, agc_void());
      return true;
    }
    if (run->terminal == LAZY_REDUCE) run->acc = last;
    if (run->terminal == LAZY_FIND && agc_as_bool(vm, last)) {
      *done = lazy_done(vm, run, agc_result_value(true, run->item), agc_void());
      return true;
    }
    return false;
  }
  size_t i = run->at;
  lazy_stage *s = &run->stages[i];
  switch (run->nodes[i]->kind) {
    case LAZY_WITH_INDEX:
      s->left++;
      run->item = last;
      run->at++;
      break;
    case LAZY_MAP:
      run->item = last;
      run->at++;
      break;
    case LAZY_FILTER: run->at = agc_as_bool(vm, last) ? i + 1 : 0; break;
    case LAZY_TAKE_WHILE:
      if (agc_as_bool(vm, last)) {
        run->at++;
      } else {
        lazy_end_at(run, i);
        run->at = 0;
      }
      break;
    case LAZY_DROP_WHILE:
      if (agc_as_bool(vm, last)) {
        run->at = 0;
      } else {
        s->dropping = false;
        run->at++;
      }
      break;
    case LAZY_FLAT_MAP:
      agc_list_cursor_begin(&s->rest, agc_as_list(vm, last), 0);
      s->pending = true;
      run->at = 0;
      break;
    case LAZY_CHUNK_WHILE:
      if (agc_as_bool(vm, last)) {
        lazy_push(s, run->item);
        s->prev = run->item;
        run->at = 0;
      } else {
        agc_value group = lazy_group(s);
        lazy_push(s, run->item);
        s->prev = run->item;
        run->item = group;
        run->at++;
      }
      break;
    default: agc_fail(vm, "RUNTIME-INTERNAL", "a Lazy step without a callback got a result", run->span);
  }
  return false;
}

/* An I/O source's next item: NEXT_ITEM with run->item, NEXT_NONE when the source ended, NEXT_STEP with *call when
   the run waits (a file job, a channel value) or ends (a read error, a timeout). */
static lazy_pull lazy_io(agc_vm *vm, lazy_run *run, const lazy_node *source, agc_step *call) {
  if (source->kind == LAZY_CHANNEL) {
    switch (lazy_receive(vm, source, &run->item)) {
      case AGC_RECV_VALUE: return NEXT_ITEM;
      case AGC_RECV_CLOSED: return NEXT_NONE;
      case AGC_RECV_TIMED_OUT: *call = lazy_end(lazy_error("channel: timed out")); return NEXT_STEP;
      case AGC_RECV_WAIT: break;
    }
  } else {
    agc_value last = run->io_last, out = agc_void();
    run->io_last = agc_void();
    switch (lazy_lines_next(vm, run, last, &out)) {
      case AGC_LINES_LINE: run->item = out; return NEXT_ITEM;
      case AGC_LINES_END:
        /* The reader closed the file before it gave END. */
        if (agc_as_result(vm, out)->ok) return NEXT_NONE;
        *call = lazy_end(out);
        return NEXT_STEP;
      case AGC_LINES_WAIT: break;
    }
  }
  run->waiting = WAIT_IO;
  *call = (agc_step){.kind = AGC_STEP_WAIT};
  return NEXT_STEP;
}

/* The next item for the first stage that is not ended: the rest of a flat_map list (the one nearest the terminal
   first, since its items came from an older item), then what an ended stage still holds, then the source. NEXT_NONE
   with run->at still 0 when no item came yet (a stage was ended); NEXT_STEP with *call when the run must call produce,
   wait for an I/O source, or end. */
static lazy_pull lazy_next(agc_vm *vm, lazy_run *run, agc_step *call) {
  size_t low = run->ended > 1 ? run->ended : 1;
  for (size_t j = run->count; j-- > low;) {
    lazy_stage *s = &run->stages[j];
    if (!s->pending) continue;
    if (agc_list_cursor_next(&s->rest, &run->item)) {
      run->at = j + 1;
      return NEXT_ITEM;
    }
    s->pending = false;
  }
  if (run->ended > 0) {
    size_t f = run->ended;
    run->ended++;
    if (f >= run->count) return NEXT_NONE;
    lazy_stage *s = &run->stages[f];
    lazy_kind kind = run->nodes[f]->kind;
    if ((kind == LAZY_EACH_SLICE || kind == LAZY_CHUNK_WHILE) && s->len > 0) {
      run->item = lazy_group(s);
      run->at = f + 1;
      return NEXT_ITEM;
    }
    return NEXT_NONE;
  }
  const lazy_node *source = run->nodes[0];
  switch (source->kind) {
    case LAZY_LIST:
      if (!agc_list_cursor_next(&run->items, &run->item)) {
        run->ended = 1;
        return NEXT_NONE;
      }
      break;
    case LAZY_RANGE:
      if (!run->more) {
        run->ended = 1;
        return NEXT_NONE;
      }
      run->item = agc_int(run->next);
      run->more = run->next != run->last;
      if (run->more) run->next++;
      break;
    case LAZY_PRODUCE:
      if (run->started) {
        run->waiting = WAIT_SOURCE;
        *call = lazy_call(source->fn, run->seed);
        return NEXT_STEP;
      }
      run->started = true;
      run->seed = source->value;
      run->item = source->value;
      break;
    case LAZY_FILE:
    case LAZY_CHANNEL: {
      lazy_pull pulled = lazy_io(vm, run, source, call);
      if (pulled == NEXT_NONE) run->ended = 1;
      if (pulled != NEXT_ITEM) return pulled;
      break;
    }
    default: agc_fail(vm, "RUNTIME-INTERNAL", "a Lazy without a source", run->span);
  }
  run->at = 1;
  return NEXT_ITEM;
}

/* A terminal is a stepper (port.h). It pulls one item from the source and moves it through the stages in order until
   a stage drops it, holds it in a buffer, or it reaches the terminal; a callback ends the step with a call and its
   result comes back as `last`. Every item that enters the first stage (from the source, a flat_map list or a flush)
   costs one step through agc_step_turn; each stage it passes without a callback, and each item to_a keeps, charges
   one unit of turn cost, an each_cons window its size more. A step whose turn ran out returns AGC_STEP_YIELD, so an
   endless source or a deep recipe with no callback still meets --max-steps, other tasks' turns and a cancel.

   The end of the items moves from the source toward the terminal: `ended` counts the stages, from the source, that
   will give nothing more (the source ran out, a take had its count, a take_while saw false). Once a stage is ended,
   the next one first gives out what it still holds (the rest of a flat_map list, then the last slice or chunk), and
   is then ended too. The run is over when every stage is. */
static agc_step lazy_step(agc_vm *vm, agc_stepper *self, agc_value last) {
  lazy_run *run = (lazy_run *)self;
  agc_step step;
  if (run->waiting != WAIT_NONE && lazy_resume(vm, run, last, &step)) return step;
  /* write_lines opens its file before it pulls the first item, so a failed open reads nothing. */
  if (run->sink && !run->sink_ready && lazy_sink(vm, run, agc_void(), agc_void(), &step)) return step;
  for (;;) {
    if (run->at == 0) {
      lazy_pull pulled = lazy_next(vm, run, &step);
      if (pulled == NEXT_STEP) return step.kind == AGC_STEP_END ? lazy_done(vm, run, step.value, agc_void()) : step;
      if (pulled == NEXT_NONE) {
        if (run->ended > run->count) return lazy_done(vm, run, lazy_finish(run), agc_void());
        continue;
      }
      /* Both run: the charge of the stages before must not be skipped when the step count ends the turn first. */
      bool charged = agc_turn_charge(vm);
      if (agc_step_turn(vm, run->span) || charged) return (agc_step){.kind = AGC_STEP_YIELD};
    }
    if (run->at == run->count) {
      switch (run->terminal) {
        case LAZY_TO_A:
          lazy_out(run, run->item);
          agc_charge(vm, 1);
          run->at = 0;
          continue;
        case LAZY_EACH:
        case LAZY_FIND: run->waiting = WAIT_TERMINAL; return lazy_call(run->fn, run->item);
        case LAZY_REDUCE: run->waiting = WAIT_TERMINAL; return lazy_call2(run->fn, run->acc, run->item);
        case LAZY_WRITE:
          run->at = 0;
          if (lazy_sink(vm, run, agc_void(), run->item, &step)) return step;
          continue;
      }
    }
    size_t i = run->at;
    const lazy_node *node = run->nodes[i];
    lazy_stage *s = &run->stages[i];
    switch (node->kind) {
      case LAZY_MAP:
      case LAZY_FILTER:
      case LAZY_TAKE_WHILE:
      case LAZY_FLAT_MAP: run->waiting = WAIT_STAGE; return lazy_call(node->fn, run->item);
      case LAZY_WITH_INDEX: run->waiting = WAIT_STAGE; return lazy_call2(node->fn, run->item, agc_int(s->left));
      case LAZY_DROP_WHILE:
        if (s->dropping) {
          run->waiting = WAIT_STAGE;
          return lazy_call(node->fn, run->item);
        }
        run->at++;
        break;
      case LAZY_CHUNK_WHILE:
        if (s->len > 0) {
          run->waiting = WAIT_STAGE;
          return lazy_call2(node->fn, s->prev, run->item);
        }
        lazy_push(s, run->item);
        s->prev = run->item;
        run->at = 0;
        break;
      case LAZY_TAKE:
        /* A take with nothing left is already ended (here or at the start), so no item reaches it; the test is
           purely defensive. */
        if (s->left == 0) {
          lazy_end_at(run, i);
          run->at = 0;
          break;
        }
        if (--s->left == 0) lazy_end_at(run, i);
        run->at++;
        break;
      case LAZY_DROP:
        if (s->left > 0) {
          s->left--;
          run->at = 0;
        } else {
          run->at++;
        }
        break;
      case LAZY_EACH_SLICE:
        lazy_grow(s, (size_t)node->count);
        s->items[s->len++] = run->item;
        if (s->len == (size_t)node->count) {
          run->item = lazy_group(s);
          run->at++;
        } else {
          run->at = 0;
        }
        break;
      case LAZY_EACH_CONS: {
        size_t size = (size_t)node->count;
        if (s->len < size) {
          lazy_grow(s, size);
          s->items[s->len++] = run->item;
        } else {
          s->items[s->head] = run->item;
          s->head = (s->head + 1) % size;
        }
        if (s->len < size) {
          run->at = 0;
          break;
        }
        agc_list_builder window;
        agc_list_builder_sized(&window, size);
        for (size_t k = 0; k < size; k++) agc_list_builder_push(&window, s->items[(s->head + k) % size]);
        run->item = agc_list_value(agc_list_builder_finish(&window));
        agc_charge(vm, size);
        run->at++;
        break;
      }
      default: agc_fail(vm, "RUNTIME-INTERNAL", "a Lazy source in the middle of a recipe", run->span);
    }
    /* Every stage that reaches here passed (or held, or dropped) the item without a callback. */
    agc_charge(vm, 1);
  }
}

/* Starts a terminal on the calling task. fn is the callback (none for to_a) and acc the initial value of reduce;
   write_lines passes its path and timeout in them. */
static agc_value lazy_start(agc_vm *vm, agc_value recipe, lazy_terminal terminal, agc_value fn, agc_value acc,
                            uint32_t span) {
  const lazy_node *node = agc_as_lazy(vm, recipe);
  if (terminal != LAZY_TO_A && terminal != LAZY_WRITE) agc_as_fn(vm, fn);
  lazy_run *run = agc_alloc(sizeof(lazy_run));
  run->stepper.step = lazy_step;
  run->stepper.no_block = true;
  run->terminal = terminal;
  run->fn = fn;
  run->acc = acc;
  run->span = span;
  run->count = node->depth;
  run->nodes = agc_alloc(agc_size_mul(run->count, sizeof(lazy_node *)));
  run->stages = agc_alloc(agc_size_mul(run->count, sizeof(lazy_stage)));
  for (size_t i = run->count; i-- > 0; node = node->parent) {
    if (!node || (i == 0) != (node->parent == NULL))
      agc_fail(vm, "RUNTIME-INTERNAL", "a Lazy recipe with a wrong depth", span);
    run->nodes[i] = node;
    run->stages[i].left = node->kind == LAZY_WITH_INDEX ? 0 : node->count;
    run->stages[i].dropping = node->kind == LAZY_DROP_WHILE;
    /* take(0) ends its stage before any item is pulled, so the source is never read (produce never calls f). */
    if (node->kind == LAZY_TAKE && node->count == 0) lazy_end_at(run, i);
  }
  agc_charge(vm, run->count);
  const lazy_node *source = run->nodes[0];
  if (source->kind == LAZY_LIST) agc_list_cursor_begin(&run->items, agc_as_list(vm, source->value), 0);
  if (source->kind == LAZY_RANGE) run->more = agc_range_bounds(agc_as_range(vm, source->value), &run->next, &run->last);
  if (source->kind == LAZY_FILE) run->lines = agc_lines_new(vm, source->value, source->count, source->timeout, span);
  if (terminal == LAZY_WRITE) run->sink = agc_writer_new(vm, fn, agc_as_int(vm, acc), span);
  /* A run reads immutable nodes and writes only this run, which belongs to the calling task. An I/O source also starts
     file jobs, closes the file and parks on channel lists, and write_lines starts file jobs: they take rt->sync around
     those calls only (lazy_lines_next, lazy_receive, lazy_write), so a long to_a or a chain of steps never holds it. */
  run->stepper.unlocked = true;
  agc_task_stepper(vm, &run->stepper);
  return agc_void();
}

static agc_value builtin_to_a(agc_vm *vm, agc_value *args, uint32_t span) {
  return lazy_start(vm, args[0], LAZY_TO_A, agc_void(), agc_void(), span);
}

static agc_value builtin_each(agc_vm *vm, agc_value *args, uint32_t span) {
  return lazy_start(vm, args[0], LAZY_EACH, args[1], agc_void(), span);
}

static agc_value builtin_reduce(agc_vm *vm, agc_value *args, uint32_t span) {
  return lazy_start(vm, args[0], LAZY_REDUCE, args[2], args[1], span);
}

static agc_value builtin_find(agc_vm *vm, agc_value *args, uint32_t span) {
  return lazy_start(vm, args[0], LAZY_FIND, args[1], agc_void(), span);
}

/* __lazy_write_lines(lazy, path, timeout_ms): the file opens in the terminal; a bad timeout or path is its error. */
static agc_value builtin_write_lines(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_as_string(vm, args[1]);
  agc_as_int(vm, args[2]);
  return lazy_start(vm, args[0], LAZY_WRITE, args[1], args[2], span);
}

/* No row touches state other tasks can reach: a recipe is immutable and a run belongs to the calling task, so no row
   takes rt->sync. The steps of a terminal run unlocked (agc_stepper.unlocked); over a file or a channel, and in
   write_lines, they take it around the reader, the receive and the writer only. Callbacks run as bytecode. */
const agc_builtin agc_lazy_builtins[] = {
  {"__lazy_list", 1, builtin_list, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"__lazy_range", 1, builtin_range, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"__lazy_produce", 2, builtin_produce, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"__lazy_file", 3, builtin_file, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"__lazy_channel", 2, builtin_channel, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"__lazy_map", 2, builtin_map, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"__lazy_with_index", 2, builtin_with_index, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"__lazy_flat_map", 2, builtin_flat_map, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"__lazy_chunk_while", 2, builtin_chunk_while, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"__lazy_test", 3, builtin_test, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"__lazy_count", 3, builtin_count, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"__lazy_group", 3, builtin_group, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"__lazy_to_a", 1, builtin_to_a, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"__lazy_each", 2, builtin_each, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"__lazy_reduce", 3, builtin_reduce, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"__lazy_find", 2, builtin_find, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"__lazy_write_lines", 3, builtin_write_lines, AGC_NATIVE_NONE, AGC_COST_NONE, false},
};

const size_t agc_lazy_builtin_count = sizeof agc_lazy_builtins / sizeof agc_lazy_builtins[0];
