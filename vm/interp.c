#include "core.h"
#include "list_impl.h"

#include <inttypes.h>
#include <math.h>
#include <string.h>

struct agc_native {
  agc_native_kind kind;
  uint32_t span;
  bool started;
  bool more;
  size_t count;
  int64_t cur, last, dir;
  agc_value list, fn, acc, item;
  agc_list_cursor items;
  agc_list_builder out;
  agc_value *kept;
  agc_stepper *stepper;
};

static _Noreturn void raise_failure(agc_vm *vm) {
  agc_stack_capture(vm, &vm->rt->outcome);
  longjmp(vm->in_turn ? vm->turn : vm->fail, 1);
}

void agc_fail(agc_vm *vm, const char *code, const char *message, uint32_t span) {
  agc_outcome *o = &vm->rt->outcome;
  o->kind = AGC_FAILED;
  o->code = code;
  o->message = message;
  o->message_len = strlen(message);
  o->text = NULL;
  o->span = span;
  raise_failure(vm);
}

void agc_fail_text(agc_vm *vm, const char *code, const agc_string *message, uint32_t span) {
  agc_outcome *o = &vm->rt->outcome;
  o->kind = AGC_FAILED;
  o->code = code;
  o->text = message;
  o->message = message->data;
  o->message_len = message->bytes;
  o->span = span;
  raise_failure(vm);
}

void agc_exit(agc_vm *vm, int64_t code) {
  vm->rt->outcome.kind = AGC_EXITED;
  vm->rt->outcome.exit_code = code;
  longjmp(vm->in_turn ? vm->turn : vm->fail, 1);
}

void agc_stop(agc_vm *vm, int sig) {
  AGC_TRACE(&vm->rt->trace, AGC_TRACE_SCHED, "stop signal=%d", sig);
  agc_exit(vm, 128 + sig);
}

agc_task *agc_new_task(agc_vm *vm) {
  agc_task *t = agc_alloc(sizeof(agc_task));
  t->id = atomic_fetch_add(&vm->rt->next_task_id, 1);
  t->state = AGC_TASK_READY;
  t->result = agc_void();
  return t;
}

void agc_vm_init(agc_vm *vm, const agc_program *program, FILE *out, FILE *err, int64_t max_steps) {
  memset(vm, 0, sizeof *vm);
  agc_runtime *rt = agc_alloc(sizeof(agc_runtime));
  rt->program = program;
  rt->out.file = out;
  rt->out.fd = -1;
  rt->err.file = err;
  rt->err.fd = -1;
  atomic_init(&rt->steps_left, max_steps);
  rt->in.fd = -1;
  rt->flush_timeout = AGC_FLUSH_TIMEOUT_MS;
  rt->hash_key[0] = 0x0706050403020100ULL;
  rt->hash_key[1] = 0x0f0e0d0c0b0a0908ULL;
  rt->args = agc_list_value(agc_list_from_array(NULL, 0));
  atomic_init(&rt->next_task_id, 1);
  agc_trace_parse(&rt->trace, NULL, 2);
  vm->rt = rt;
  vm->main = vm->task = agc_new_task(vm);
  agc_random_seed(&vm->task->random, 0);
}

void agc_charge(agc_vm *vm, uint64_t units) {
  agc_task *t = vm->task;
  uint64_t room = (uint64_t)INT64_MAX - (uint64_t)t->turn_cost;
  t->turn_cost += (int64_t)(units < room ? units : room);
}

void agc_charge_bytes(agc_vm *vm, size_t bytes) { agc_charge(vm, bytes / AGC_COST_BYTES); }

static void sync_budget(agc_vm *vm) {
  int64_t spent = vm->stop_set - vm->next_stop;
  vm->turn_left -= spent;
  vm->batch -= spent;
  vm->stop_set = vm->next_stop;
}

static void set_counter(agc_vm *vm) {
  int64_t c = vm->turn_left < vm->batch ? vm->turn_left : vm->batch;
  if (c < 0) c = 0;
  vm->next_stop = vm->stop_set = c;
}

static void take_steps(agc_vm *vm, int64_t want) {
  int64_t left = atomic_load(&vm->rt->steps_left);
  int64_t got;
  do {
    got = left < want ? left : want;
  } while (!atomic_compare_exchange_weak(&vm->rt->steps_left, &left, left - got));
  vm->batch += got;
}

static void end_turn_now(agc_vm *vm) {
  vm->yield = true;
  vm->next_stop = vm->stop_set = 0;
}

void agc_turn_begin(agc_vm *vm) {
  vm->turn_left = AGC_TURN_STEPS;
  vm->batch = 0;
  vm->turn_cost_used = 0;
  vm->yield = false;
  take_steps(vm, AGC_TURN_STEPS);
  set_counter(vm);
}

void agc_turn_finish(agc_vm *vm) {
  sync_budget(vm);
  if (vm->batch > 0) atomic_fetch_add(&vm->rt->steps_left, vm->batch);
  vm->batch = 0;
  vm->next_stop = vm->stop_set = 0;
}

static void step_slow(agc_vm *vm, int64_t n, uint32_t span) {
  sync_budget(vm);
  if (vm->batch < n) take_steps(vm, n - vm->batch + AGC_TURN_STEPS);
  if (vm->batch < n)
    agc_fail(vm, "RUNTIME-STEP-LIMIT", "execution step budget exhausted", span + (uint32_t)vm->batch);
  vm->batch -= n;
  vm->turn_left -= n;
  if (vm->turn_left <= 0) {
    end_turn_now(vm);
    return;
  }
  set_counter(vm);
}

static void count_step(agc_vm *vm, uint32_t span) {
  if (vm->next_stop > 1) {
    vm->next_stop--;
    return;
  }
  step_slow(vm, 1, span);
}

static bool apply_cost(agc_vm *vm) {
  int64_t c = vm->task->turn_cost;
  vm->task->turn_cost = 0;
  if (vm->rt->no_turn_cost) return false;
  vm->turn_cost_used = vm->turn_cost_used < INT64_MAX - c ? vm->turn_cost_used + c : INT64_MAX;
  sync_budget(vm);
  vm->turn_left = vm->turn_left > INT64_MIN + c ? vm->turn_left - c : INT64_MIN;
  if (vm->turn_left <= 0) {
    end_turn_now(vm);
    return true;
  }
  set_counter(vm);
  return false;
}

bool agc_turn_charge(agc_vm *vm) { return vm->task->turn_cost && apply_cost(vm); }

static void ensure_registers(agc_vm *vm, agc_task *t, size_t needed, uint32_t span) {
  if (needed <= t->reg_capacity) return;
  if (needed > AGC_MAX_REGISTERS) agc_fail(vm, "RUNTIME-STACK-OVERFLOW", "call depth limit exceeded", span);
  size_t capacity = t->reg_capacity ? t->reg_capacity : 256;
  while (capacity < needed) capacity *= 2;
  agc_value *regs = agc_alloc(agc_size_mul(capacity, sizeof(agc_value)));
  if (t->reg_capacity) memcpy(regs, t->regs, t->reg_capacity * sizeof(agc_value));
  t->regs = regs;
  t->reg_capacity = capacity;
}

static agc_frame *new_frame(agc_task *t) {
  if (t->frame_count == t->frame_capacity) {
    uint32_t capacity = t->frame_capacity ? t->frame_capacity * 2 : 64;
    agc_frame *frames = agc_alloc(agc_size_mul(capacity, sizeof(agc_frame)));
    if (t->frame_count) memcpy(frames, t->frames, t->frame_count * sizeof(agc_frame));
    t->frames = frames;
    t->frame_capacity = capacity;
  }
  return &t->frames[t->frame_count++];
}

static void push_frame(agc_vm *vm, agc_task *t, uint32_t function, uint32_t base, uint32_t ret, uint32_t span) {
  if (t->depth >= AGC_MAX_DEPTH) agc_fail(vm, "RUNTIME-STACK-OVERFLOW", "call depth limit exceeded", span);
  ensure_registers(vm, t, (size_t)base + vm->rt->program->functions[function].registers, span);
  agc_frame *frame = new_frame(t);
  frame->function = function;
  frame->pc = 0;
  frame->base = base;
  frame->ret = ret;
  frame->tail = false;
  frame->native = NULL;
  t->depth++;
}

static void call_value(agc_vm *vm, agc_task *t, agc_value value, uint32_t window, const agc_value *args, uint32_t argc,
                       uint32_t ret, uint32_t span) {
  const agc_program *p = vm->rt->program;
  const agc_fn *fn = agc_as_fn(vm, value);
  if (fn->function >= p->function_count || p->functions[fn->function].params != argc ||
      p->functions[fn->function].captures != fn->n)
    agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: function value does not match its call", span);
  push_frame(vm, t, fn->function, window, ret, span);
  agc_value *R = t->regs + window;
  if (args) memcpy(R, args, (size_t)argc * sizeof(agc_value));
  if (fn->n) memcpy(R + argc, fn->captured, (size_t)fn->n * sizeof(agc_value));
}

void agc_task_call(agc_vm *vm, agc_task *t, agc_value fn, const agc_value *args, uint32_t argc, uint32_t span) {
  call_value(vm, t, fn, 0, args, argc, 0, span);
}

void agc_task_enter(agc_vm *vm, agc_task *t, uint32_t function) { push_frame(vm, t, function, 0, 0, 0); }

static void finish_native(agc_vm *vm, agc_value result) {
  agc_task *t = vm->task;
  agc_frame *frame = &t->frames[t->frame_count - 1];
  uint32_t base = frame->base;
  frame->native = NULL;
  t->frame_count--;
  t->regs[base] = result;
  if (t->turn_cost) apply_cost(vm);
}

static bool key_less(agc_vm *vm, agc_value a, agc_value b) {
  if (agc_is(a, AGC_T_STRING)) {
    const agc_string *x = agc_as_string(vm, a), *y = agc_as_string(vm, b);
    size_t n = x->bytes < y->bytes ? x->bytes : y->bytes;
    int order = n ? memcmp(x->data, y->data, n) : 0;
    return order < 0 || (order == 0 && x->bytes < y->bytes);
  }
  if (agc_is(a, AGC_T_FLOAT)) {
    double x = agc_as_float(vm, a), y = agc_as_float(vm, b);
    if (isnan(x)) return false;
    if (isnan(y)) return true;
    return x < y;
  }
  return agc_as_int(vm, a) < agc_as_int(vm, b);
}

agc_value agc_sort_by_keys(agc_vm *vm, const agc_list *items, const agc_list *keys) {
  size_t n = agc_list_len(items);
  if (n < 2) return agc_list_value((agc_list *)items);
  uint64_t rounds = 0;
  for (size_t width = 1; width < n; width *= 2) rounds++;
  agc_charge(vm, (uint64_t)n * rounds);
  size_t *order = agc_alloc_atomic(agc_size_mul(n, sizeof(size_t)));
  size_t *merged = agc_alloc_atomic(agc_size_mul(n, sizeof(size_t)));
  agc_value *sort_keys = agc_alloc(agc_size_mul(n, sizeof(agc_value)));
  agc_list_to_array(keys, sort_keys);
  for (size_t k = 0; k < n; k++) order[k] = k;
  for (size_t width = 1; width < n; width *= 2) {
    for (size_t lo = 0; lo < n; lo += 2 * width) {
      size_t mid = n - lo < width ? n : lo + width;
      size_t hi = n - mid < width ? n : mid + width;
      size_t i = lo, j = mid, k = lo;
      while (i < mid && j < hi)
        merged[k++] = key_less(vm, sort_keys[order[j]], sort_keys[order[i]]) ? order[j++] : order[i++];
      while (i < mid) merged[k++] = order[i++];
      while (j < hi) merged[k++] = order[j++];
    }
    size_t *swap = order;
    order = merged;
    merged = swap;
  }
  agc_list_builder sorted;
  agc_list_builder_sized(&sorted, n);
  for (size_t k = 0; k < n; k++) agc_list_builder_push(&sorted, list_get(items, order[k]));
  return agc_list_value(agc_list_builder_finish(&sorted));
}

static bool counting(agc_native_kind kind) {
  return kind == AGC_NATIVE_RANGE_EACH || kind == AGC_NATIVE_TIMES || kind == AGC_NATIVE_UPTO ||
         kind == AGC_NATIVE_DOWNTO;
}

static void resume_stepper(agc_vm *vm) {
  agc_task *t = vm->task;
  agc_frame *frame = &t->frames[t->frame_count - 1];
  agc_native *st = frame->native;
  uint32_t base = frame->base;
  agc_step next = st->stepper->step(vm, st->stepper, t->regs[base]);
  switch (next.kind) {
    case AGC_STEP_CALL:
      count_step(vm, st->span);
      call_value(vm, t, st->fn, base + 1, &next.value, 1, base, st->span);
      t->turn_cost++;
      apply_cost(vm);
      return;
    case AGC_STEP_WAIT:
      if (!t->parking) agc_fail(vm, "RUNTIME-INTERNAL", "a step waited without a pending job", st->span);
      t->park_reg = base;
      return;
    case AGC_STEP_END: finish_native(vm, next.value); return;
  }
}

static void resume_native(agc_vm *vm) {
  agc_task *t = vm->task;
  agc_frame *frame = &t->frames[t->frame_count - 1];
  agc_native *st = frame->native;
  uint32_t base = frame->base;
  if (st->kind == AGC_NATIVE_STEPPER) {
    resume_stepper(vm);
    return;
  }
  if (counting(st->kind)) {
    if (!st->more) {
      finish_native(vm, agc_void());
      return;
    }
    count_step(vm, st->span);
    agc_value arg = agc_int(st->cur);
    st->more = st->cur != st->last;
    if (st->more) st->cur += st->dir;
    call_value(vm, t, st->fn, base + 1, &arg, 1, base, st->span);
    return;
  }
  if (st->started) {
    agc_value got = t->regs[base];
    switch (st->kind) {
      case AGC_NATIVE_MAP:
      case AGC_NATIVE_SORT_BY: agc_list_builder_push(&st->out, got); break;
      case AGC_NATIVE_FILTER:
        if (agc_as_bool(vm, got)) st->kept[st->count++] = st->item;
        break;
      case AGC_NATIVE_ANY:
        if (agc_as_bool(vm, got)) {
          finish_native(vm, agc_bool(true));
          return;
        }
        break;
      case AGC_NATIVE_ALL:
        if (!agc_as_bool(vm, got)) {
          finish_native(vm, agc_bool(false));
          return;
        }
        break;
      case AGC_NATIVE_REDUCE: st->acc = got; break;
      default: break;
    }
  }
  st->started = true;
  if (agc_list_cursor_next(&st->items, &st->item)) {
    agc_value args[2];
    uint32_t argc = 0;
    if (st->kind == AGC_NATIVE_REDUCE) args[argc++] = st->acc;
    args[argc++] = st->item;
    call_value(vm, t, st->fn, base + 1, args, argc, base, st->span);
    t->turn_cost++;
    apply_cost(vm);
    return;
  }
  agc_value result = agc_void();
  switch (st->kind) {
    case AGC_NATIVE_MAP: result = agc_list_value(agc_list_builder_finish(&st->out)); break;
    case AGC_NATIVE_FILTER: result = agc_list_value(agc_list_from_array(st->kept, st->count)); break;
    case AGC_NATIVE_ANY: result = agc_bool(false); break;
    case AGC_NATIVE_ALL: result = agc_bool(true); break;
    case AGC_NATIVE_REDUCE: result = st->acc; break;
    case AGC_NATIVE_SORT_BY:
      result = agc_sort_by_keys(vm, agc_as_list(vm, st->list), agc_list_builder_finish(&st->out));
      break;
    default: break;
  }
  finish_native(vm, result);
}

static void push_native(agc_vm *vm, agc_native *st, uint32_t base) {
  agc_frame *frame = new_frame(vm->task);
  frame->function = 0;
  frame->pc = 0;
  frame->base = base;
  frame->ret = base;
  frame->tail = false;
  frame->native = st;
  resume_native(vm);
}

static void start_native(agc_vm *vm, agc_native_kind kind, uint32_t base, uint32_t span) {
  agc_native *st = agc_alloc(sizeof(agc_native));
  const agc_value *args = vm->task->regs + base;
  st->kind = kind;
  st->span = span;
  if (counting(kind)) {
    st->dir = 1;
    if (kind == AGC_NATIVE_RANGE_EACH) {
      st->more = agc_range_bounds(agc_as_range(vm, args[0]), &st->cur, &st->last);
      st->fn = args[1];
    } else if (kind == AGC_NATIVE_TIMES) {
      int64_t n = agc_as_int(vm, args[0]);
      st->more = n > 0;
      st->cur = 0;
      st->last = st->more ? n - 1 : 0;
      st->fn = args[1];
    } else {
      st->cur = agc_as_int(vm, args[0]);
      st->last = agc_as_int(vm, args[1]);
      st->fn = args[2];
      if (kind == AGC_NATIVE_DOWNTO) st->dir = -1;
      st->more = kind == AGC_NATIVE_DOWNTO ? st->cur >= st->last : st->cur <= st->last;
    }
    agc_as_fn(vm, st->fn);
  } else {
    st->list = args[0];
    if (kind == AGC_NATIVE_REDUCE) {
      st->acc = args[1];
      st->fn = args[2];
    } else {
      st->fn = args[1];
    }
    const agc_list *items = agc_as_list(vm, st->list);
    size_t len = agc_list_len(items);
    agc_as_fn(vm, st->fn);
    agc_list_cursor_begin(&st->items, items, 0);
    if (kind == AGC_NATIVE_MAP || kind == AGC_NATIVE_SORT_BY) agc_list_builder_sized(&st->out, len);
    if (kind == AGC_NATIVE_FILTER) st->kept = agc_alloc(agc_size_mul(len, sizeof(agc_value)));
  }
  push_native(vm, st, base);
}

static void start_stepper(agc_vm *vm, const agc_builtin *b, uint32_t base, uint32_t span) {
  agc_task *t = vm->task;
  agc_native *st = agc_alloc(sizeof(agc_native));
  st->kind = AGC_NATIVE_STEPPER;
  st->span = span;
  st->stepper = t->stepper;
  st->fn = t->regs[base + b->arity - 1];
  t->stepper = NULL;
  agc_as_fn(vm, st->fn);
  push_native(vm, st, base);
}

static void replace_frame(agc_vm *vm, uint32_t function, uint32_t window, uint32_t span) {
  agc_task *t = vm->task;
  agc_frame *frame = &t->frames[t->frame_count - 1];
  const agc_function *callee = &vm->rt->program->functions[function];
  ensure_registers(vm, t, (size_t)frame->base + callee->registers, span);
  agc_value *R = t->regs + frame->base;
  memmove(R, R + window, (size_t)callee->params * sizeof(agc_value));
  frame->function = function;
  frame->pc = 0;
  frame->tail = true;
}

static bool return_value(agc_vm *vm, agc_value result) {
  agc_task *t = vm->task;
  uint32_t ret = t->frames[t->frame_count - 1].ret;
  t->frame_count--;
  t->depth--;
  if (t->frame_count == 0) {
    t->result = result;
    return false;
  }
  t->regs[ret] = result;
  if (t->frames[t->frame_count - 1].native) resume_native(vm);
  return true;
}

static bool equal_values(agc_vm *vm, agc_value x, agc_value y) {
  if (agc_is(x, AGC_T_INT) && agc_is(y, AGC_T_INT)) return agc_as_int(vm, x) == agc_as_int(vm, y);
  if (agc_is(x, AGC_T_FLOAT) && agc_is(y, AGC_T_FLOAT)) return agc_as_float(vm, x) == agc_as_float(vm, y);
  if (agc_is(x, AGC_T_NIL) && agc_is(y, AGC_T_NIL)) return true;
  if (agc_is(x, AGC_T_STRING) && agc_is(y, AGC_T_STRING))
    return agc_same_string(vm, agc_as_string(vm, x), agc_as_string(vm, y));
  if (agc_is(x, AGC_T_RANGE) && agc_is(y, AGC_T_RANGE)) {
    const agc_range *a = agc_as_range(vm, x), *b = agc_as_range(vm, y);
    return a->start == b->start && a->end == b->end && a->exclusive == b->exclusive;
  }
  return agc_as_bool(vm, x) == agc_as_bool(vm, y);
}

static bool same_values(agc_vm *vm, agc_value x, agc_value y) {
  if (x.tag != y.tag) return false;
  if (agc_is(x, AGC_T_FLOAT)) {
    double a = agc_as_float(vm, x), b = agc_as_float(vm, y);
    return isnan(a) ? isnan(b) : a == b && signbit(a) == signbit(b);
  }
  return equal_values(vm, x, y);
}

static _Noreturn void index_out_of_range(agc_vm *vm, int64_t index, size_t len, uint32_t span) {
  char text[96];
  int n = snprintf(text, sizeof text, "index %" PRId64 " is outside a list of length %zu", index, len);
  char *message = agc_alloc_atomic((size_t)n + 1);
  memcpy(message, text, (size_t)n + 1);
  agc_fail(vm, "RUNTIME-INDEX-OUT-OF-RANGE", message, span);
}

static _Noreturn void key_not_found(agc_vm *vm, agc_value key, uint32_t span) {
  static const char before[] = "key ", after[] = " is not in the map";
  const agc_string *form = agc_debug(vm, key);
  size_t len = agc_size_add(agc_size_add(sizeof before - 1, form->bytes), sizeof after);
  char *message = agc_alloc_atomic(len);
  memcpy(message, before, sizeof before - 1);
  memcpy(message + sizeof before - 1, form->data, form->bytes);
  memcpy(message + sizeof before - 1 + form->bytes, after, sizeof after);
  agc_fail(vm, "RUNTIME-KEY-NOT-FOUND", message, span);
}

static agc_turn_result park_task(agc_task *t) {
  t->parking = false;
  t->state = AGC_TASK_PARKED;
  return AGC_TURN_PARKED;
}

agc_turn_result agc_run_turn(agc_vm *vm) {
  const agc_program *p = vm->rt->program;
  agc_task *t = vm->task;
  if (t->frame_count == 0) return AGC_TURN_DONE;
  if (t->frames[t->frame_count - 1].native) {
    resume_native(vm);
    if (t->parking) return park_task(t);
    if (vm->yield) return AGC_TURN_YIELD;
  }
  for (;;) {
    agc_frame *frame = &t->frames[t->frame_count - 1];
    const agc_function *fn = &p->functions[frame->function];
    agc_value *R = t->regs + frame->base;
    uint32_t pc = frame->pc;
    agc_instr in = fn->code[pc];
    uint32_t s = fn->spans[pc];
    uint32_t bx = (uint32_t)in.b | ((uint32_t)in.c << 16);
    frame->pc = pc + 1;
    int64_t x, y, z;
    switch (in.op) {
      case AGC_OP_MOVE: R[in.a] = R[in.b]; break;
      case AGC_OP_CONST: R[in.a] = p->constants[bx]; break;
      case AGC_OP_STEP:
        if (vm->next_stop > in.a) {
          vm->next_stop -= in.a;
          break;
        }
        step_slow(vm, in.a, s);
        if (vm->yield) return AGC_TURN_YIELD;
        break;
      case AGC_OP_ADD_I:
      case AGC_OP_SUB_I:
      case AGC_OP_MUL_I: {
        x = agc_as_int(vm, R[in.b]);
        y = agc_as_int(vm, R[in.c]);
        bool overflow = in.op == AGC_OP_ADD_I   ? __builtin_add_overflow(x, y, &z)
                        : in.op == AGC_OP_SUB_I ? __builtin_sub_overflow(x, y, &z)
                                                : __builtin_mul_overflow(x, y, &z);
        if (overflow) agc_fail(vm, "RUNTIME-INTEGER-OVERFLOW", "Int result is outside the 64-bit range", s);
        R[in.a] = agc_int(z);
        break;
      }
      case AGC_OP_DIV_I:
      case AGC_OP_MOD_I:
        x = agc_as_int(vm, R[in.b]);
        y = agc_as_int(vm, R[in.c]);
        if (y == 0) agc_fail(vm, "RUNTIME-DIVISION-BY-ZERO", "division by zero", s);
        if (in.op == AGC_OP_MOD_I) {
          R[in.a] = agc_int(y == -1 ? 0 : x % y);
        } else {
          if (x == INT64_MIN && y == -1)
            agc_fail(vm, "RUNTIME-INTEGER-OVERFLOW", "Int result is outside the 64-bit range", s);
          R[in.a] = agc_int(x / y);
        }
        break;
      case AGC_OP_NEG_I:
        x = agc_as_int(vm, R[in.b]);
        if (x == INT64_MIN) agc_fail(vm, "RUNTIME-INTEGER-OVERFLOW", "Int result is outside the 64-bit range", s);
        R[in.a] = agc_int(-x);
        break;
      case AGC_OP_ADD_F: R[in.a] = agc_float(agc_as_float(vm, R[in.b]) + agc_as_float(vm, R[in.c])); break;
      case AGC_OP_SUB_F: R[in.a] = agc_float(agc_as_float(vm, R[in.b]) - agc_as_float(vm, R[in.c])); break;
      case AGC_OP_MUL_F: R[in.a] = agc_float(agc_as_float(vm, R[in.b]) * agc_as_float(vm, R[in.c])); break;
      case AGC_OP_DIV_F: {
        double divisor = agc_as_float(vm, R[in.c]);
        double dividend = agc_as_float(vm, R[in.b]);
        if (divisor == 0) agc_fail(vm, "RUNTIME-DIVISION-BY-ZERO", "division by zero", s);
        R[in.a] = agc_float(dividend / divisor);
        break;
      }
      case AGC_OP_NEG_F: R[in.a] = agc_float(-agc_as_float(vm, R[in.b])); break;
      case AGC_OP_LT_F: R[in.a] = agc_bool(agc_as_float(vm, R[in.b]) < agc_as_float(vm, R[in.c])); break;
      case AGC_OP_LE_F: R[in.a] = agc_bool(agc_as_float(vm, R[in.b]) <= agc_as_float(vm, R[in.c])); break;
      case AGC_OP_CONCAT: {
        agc_string *joined = agc_concat(agc_as_string(vm, R[in.b]), agc_as_string(vm, R[in.c]));
        R[in.a] = agc_string_value(joined);
        agc_charge_bytes(vm, joined->bytes);
        if (t->turn_cost && apply_cost(vm)) return AGC_TURN_YIELD;
        break;
      }
      case AGC_OP_TO_TEXT:
        R[in.a] = agc_string_value(agc_text(vm, R[in.b]));
        if (t->turn_cost && apply_cost(vm)) return AGC_TURN_YIELD;
        break;
      case AGC_OP_INSPECT:
        R[in.a] = agc_string_value(agc_debug(vm, R[in.b]));
        if (t->turn_cost && apply_cost(vm)) return AGC_TURN_YIELD;
        break;
      case AGC_OP_LIST: R[in.a] = agc_list_value(agc_list_from_array(&R[in.b], in.c)); break;
      case AGC_OP_LIST_LEN: R[in.a] = agc_int((int64_t)list_len(agc_as_list(vm, R[in.b]))); break;
      case AGC_OP_LIST_GET: {
        const agc_list *l = agc_as_list(vm, R[in.b]);
        x = agc_as_int(vm, R[in.c]);
        size_t len = list_len(l);
        if (x < 0 || (uint64_t)x >= len) index_out_of_range(vm, x, len, s);
        R[in.a] = list_at(l, (size_t)x);
        break;
      }
      case AGC_OP_MAP: {
        agc_map *m = agc_new_map();
        for (uint32_t k = 0; k < in.c; k++)
          m = agc_map_put(vm, m, R[(uint32_t)in.b + 2 * k], R[(uint32_t)in.b + 2 * k + 1]);
        R[in.a] = agc_map_value(m);
        if (t->turn_cost && apply_cost(vm)) return AGC_TURN_YIELD;
        break;
      }
      case AGC_OP_MAP_GET: {
        agc_value found;
        if (!agc_map_get(vm, agc_as_map(vm, R[in.b]), R[in.c], &found)) key_not_found(vm, R[in.c], s);
        R[in.a] = found;
        if (t->turn_cost && apply_cost(vm)) return AGC_TURN_YIELD;
        break;
      }
      case AGC_OP_STRUCT: {
        uint32_t n = p->structs[in.c].count;
        agc_struct *st = agc_new_struct(in.c, n);
        for (uint32_t k = 0; k < n; k++) st->fields[k] = R[(uint32_t)in.b + k];
        R[in.a] = agc_struct_value(st);
        break;
      }
      case AGC_OP_FIELD: {
        const agc_struct *st = agc_as_struct(vm, R[in.b]);
        if (in.c >= st->n) agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: field index out of range", 0);
        R[in.a] = st->fields[in.c];
        break;
      }
      case AGC_OP_ENUM: {
        const agc_variant_def *v = &p->variants[in.c];
        if (v->arity == 0) {
          R[in.a] = agc_enum_value(v->shared);
          break;
        }
        agc_enum *e = agc_new_enum(in.c, v->arity);
        for (uint32_t k = 0; k < v->arity; k++) e->payload[k] = R[(uint32_t)in.b + k];
        R[in.a] = agc_enum_value(e);
        break;
      }
      case AGC_OP_IS_VARIANT: R[in.a] = agc_bool(agc_as_enum(vm, R[in.b])->variant == in.c); break;
      case AGC_OP_PAYLOAD: {
        const agc_enum *e = agc_as_enum(vm, R[in.b]);
        if (in.c >= e->n) agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: payload index out of range", 0);
        R[in.a] = e->payload[in.c];
        break;
      }
      case AGC_OP_SAME:
        R[in.a] = agc_bool(same_values(vm, R[in.b], R[in.c]));
        if (t->turn_cost && apply_cost(vm)) return AGC_TURN_YIELD;
        break;
      case AGC_OP_NOT: R[in.a] = agc_bool(!agc_as_bool(vm, R[in.b])); break;
      case AGC_OP_LT_I: R[in.a] = agc_bool(agc_as_int(vm, R[in.b]) < agc_as_int(vm, R[in.c])); break;
      case AGC_OP_LE_I: R[in.a] = agc_bool(agc_as_int(vm, R[in.b]) <= agc_as_int(vm, R[in.c])); break;
      case AGC_OP_EQ:
        R[in.a] = agc_bool(equal_values(vm, R[in.b], R[in.c]));
        if (t->turn_cost && apply_cost(vm)) return AGC_TURN_YIELD;
        break;
      case AGC_OP_NE:
        R[in.a] = agc_bool(!equal_values(vm, R[in.b], R[in.c]));
        if (t->turn_cost && apply_cost(vm)) return AGC_TURN_YIELD;
        break;
      case AGC_OP_JUMP: frame->pc = bx; break;
      case AGC_OP_JUMP_IF_FALSE:
        if (!agc_as_bool(vm, R[in.a])) frame->pc = bx;
        break;
      case AGC_OP_JUMP_IF_TRUE:
        if (agc_as_bool(vm, R[in.a])) frame->pc = bx;
        break;
      case AGC_OP_CALL: push_frame(vm, t, bx, frame->base + in.a, frame->base + in.a, s); break;
      case AGC_OP_CALL_VALUE: {
        uint32_t at = frame->base + in.a;
        call_value(vm, t, t->regs[at], at + 1, NULL, in.b, at, s);
        break;
      }
      case AGC_OP_CLOSURE: {
        uint32_t n = p->functions[bx].captures;
        agc_fn *f = agc_new_fn(bx, n);
        for (uint32_t k = 0; k < n; k++) f->captured[k] = R[(uint32_t)in.a + k];
        R[in.a] = agc_fn_value(f);
        break;
      }
      case AGC_OP_TAIL_CALL: replace_frame(vm, bx, in.a, s); break;
      case AGC_OP_RANGE:
        R[in.a] = agc_range_value(agc_as_int(vm, R[in.b]), agc_as_int(vm, R[(uint32_t)in.b + 1]), in.c != 0);
        break;
      case AGC_OP_RANGE_BOUNDS: {
        int64_t first, last;
        bool more = agc_range_bounds(agc_as_range(vm, R[in.b]), &first, &last);
        R[in.a] = agc_int(first);
        R[(uint32_t)in.a + 1] = agc_int(last);
        R[(uint32_t)in.a + 2] = agc_bool(more);
        break;
      }
      case AGC_OP_CALL_BUILTIN: {
        uint32_t base = frame->base + in.a;
        const agc_builtin *b = p->builtins[bx];
        if (b->native) {
          start_native(vm, b->native, base, s);
          if (vm->yield) return AGC_TURN_YIELD;
          break;
        }
        uint64_t units = 0;
        if (b->cost == AGC_COST_SIZE)
          for (uint32_t k = 0; k < b->arity; k++) units += agc_value_units(t->regs[base + k]);
        agc_value result = b->fn(vm, t->regs + base, s);
        if (t->stepper) {
          start_stepper(vm, b, base, s);
          if (t->parking) return park_task(t);
          if (vm->yield) return AGC_TURN_YIELD;
          break;
        }
        if (t->parking) {
          t->parking = false;
          if (t->retry) frame->pc = pc;
          t->park_reg = base;
          t->state = AGC_TASK_PARKED;
          return AGC_TURN_PARKED;
        }
        t->regs[base] = result;
        if (b->cost == AGC_COST_SIZE) agc_charge(vm, units + agc_value_units(result));
        if (t->turn_cost) apply_cost(vm);
        if (vm->yield) return AGC_TURN_YIELD;
        break;
      }
      case AGC_OP_RETURN:
        if (!return_value(vm, R[in.a])) return AGC_TURN_DONE;
        if (t->parking) return park_task(t);
        if (vm->yield) return AGC_TURN_YIELD;
        break;
      case AGC_OP_TRY: {
        const agc_result *r = agc_as_result(vm, R[in.b]);
        if (r->ok) {
          R[in.a] = r->value;
        } else {
          if (t->frame_count == 1 && t == vm->main)
            agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: try in the entry function", s);
          if (!return_value(vm, R[in.b])) return AGC_TURN_DONE;
          if (t->parking) return park_task(t);
          if (vm->yield) return AGC_TURN_YIELD;
        }
        break;
      }
      case AGC_OP_IS_OK: R[in.a] = agc_bool(agc_as_result(vm, R[in.b])->ok); break;
      case AGC_OP_RESULT_VALUE: R[in.a] = agc_as_result(vm, R[in.b])->value; break;
      default: agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: unknown opcode", 0);
    }
  }
}


