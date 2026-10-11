#include "agc.h"

#include <inttypes.h>
#include <math.h>
#include <string.h>

void agc_fail(agc_vm *vm, const char *code, const char *message, uint32_t span) {
  vm->outcome.kind = AGC_FAILED;
  vm->outcome.code = code;
  vm->outcome.message = message;
  vm->outcome.message_len = strlen(message);
  vm->outcome.text = NULL;
  vm->outcome.span = span;
  longjmp(vm->fail, 1);
}

void agc_fail_text(agc_vm *vm, const char *code, const agc_string *message, uint32_t span) {
  vm->outcome.kind = AGC_FAILED;
  vm->outcome.code = code;
  vm->outcome.text = message;
  vm->outcome.message = message->data;
  vm->outcome.message_len = message->bytes;
  vm->outcome.span = span;
  longjmp(vm->fail, 1);
}

void agc_exit(agc_vm *vm, int64_t code) {
  vm->outcome.kind = AGC_EXITED;
  vm->outcome.exit_code = code;
  longjmp(vm->fail, 1);
}

void agc_flush(agc_vm *vm) {
  if (fflush(vm->out) != 0) agc_fail(vm, "RUNTIME-INTERNAL", "cannot write to standard output", 0);
}

void agc_write(agc_vm *vm, FILE *stream, const void *data, size_t len) {
  if (len && fwrite(data, 1, len, stream) != len)
    agc_fail(vm, "RUNTIME-INTERNAL",
             stream == vm->err ? "cannot write to standard error" : "cannot write to standard output", 0);
}

void agc_vm_init(agc_vm *vm, const agc_program *program, FILE *out, FILE *err, int64_t max_steps) {
  memset(vm, 0, sizeof *vm);
  vm->program = program;
  vm->out = out;
  vm->err = err;
  vm->steps_left = max_steps;
  vm->in.fd = -1;
  vm->args = agc_list_value(agc_new_list(0));
}

static void ensure_registers(agc_vm *vm, size_t needed, uint32_t span) {
  if (needed <= vm->reg_capacity) return;
  if (needed > AGC_MAX_REGISTERS) agc_fail(vm, "RUNTIME-STACK-OVERFLOW", "call depth limit exceeded", span);
  size_t capacity = vm->reg_capacity ? vm->reg_capacity : 256;
  while (capacity < needed) capacity *= 2;
  agc_value *regs = agc_alloc(agc_size_mul(capacity, sizeof(agc_value)));
  if (vm->reg_capacity) memcpy(regs, vm->regs, vm->reg_capacity * sizeof(agc_value));
  vm->regs = regs;
  vm->reg_capacity = capacity;
}

struct agc_native {
  agc_native_kind kind;
  uint32_t span;
  bool started;
  bool more;
  size_t index, count;
  int64_t cur, last, dir;
  agc_value list, fn, acc;
  agc_list *out;
};

static agc_frame *new_frame(agc_vm *vm) {
  if (vm->frame_count == vm->frame_capacity) {
    uint32_t capacity = vm->frame_capacity ? vm->frame_capacity * 2 : 64;
    agc_frame *frames = agc_alloc(agc_size_mul(capacity, sizeof(agc_frame)));
    if (vm->frame_count) memcpy(frames, vm->frames, vm->frame_count * sizeof(agc_frame));
    vm->frames = frames;
    vm->frame_capacity = capacity;
  }
  return &vm->frames[vm->frame_count++];
}

static void push_frame(agc_vm *vm, uint32_t function, uint32_t base, uint32_t ret, uint32_t span) {
  if (vm->depth >= AGC_MAX_DEPTH) agc_fail(vm, "RUNTIME-STACK-OVERFLOW", "call depth limit exceeded", span);
  ensure_registers(vm, (size_t)base + vm->program->functions[function].registers, span);
  agc_frame *frame = new_frame(vm);
  frame->function = function;
  frame->pc = 0;
  frame->base = base;
  frame->ret = ret;
  frame->native = NULL;
  vm->depth++;
}

static void call_value(agc_vm *vm, agc_value value, uint32_t window, const agc_value *args, uint32_t argc,
                       uint32_t ret, uint32_t span) {
  const agc_program *p = vm->program;
  const agc_fn *fn = agc_as_fn(vm, value);
  if (fn->function >= p->function_count || p->functions[fn->function].params != argc ||
      p->functions[fn->function].captures != fn->n)
    agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: function value does not match its call", span);
  push_frame(vm, fn->function, window, ret, span);
  agc_value *R = vm->regs + window;
  if (args) memcpy(R, args, (size_t)argc * sizeof(agc_value));
  if (fn->n) memcpy(R + argc, fn->captured, (size_t)fn->n * sizeof(agc_value));
}

static void finish_native(agc_vm *vm, agc_value result) {
  agc_frame *frame = &vm->frames[vm->frame_count - 1];
  uint32_t base = frame->base;
  frame->native = NULL;
  vm->frame_count--;
  vm->regs[base] = result;
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
  size_t n = items->len;
  if (n < 2) return agc_list_value((agc_list *)items);
  size_t *order = agc_alloc_atomic(agc_size_mul(n, sizeof(size_t)));
  size_t *merged = agc_alloc_atomic(agc_size_mul(n, sizeof(size_t)));
  for (size_t k = 0; k < n; k++) order[k] = k;
  for (size_t width = 1; width < n; width *= 2) {
    for (size_t lo = 0; lo < n; lo += 2 * width) {
      size_t mid = n - lo < width ? n : lo + width;
      size_t hi = n - mid < width ? n : mid + width;
      size_t i = lo, j = mid, k = lo;
      while (i < mid && j < hi)
        merged[k++] = key_less(vm, keys->items[order[j]], keys->items[order[i]]) ? order[j++] : order[i++];
      while (i < mid) merged[k++] = order[i++];
      while (j < hi) merged[k++] = order[j++];
    }
    size_t *swap = order;
    order = merged;
    merged = swap;
  }
  agc_list *sorted = agc_new_list(n);
  for (size_t k = 0; k < n; k++) sorted->items[k] = items->items[order[k]];
  return agc_list_value(sorted);
}

static void charge_steps(agc_vm *vm, int64_t count, uint32_t span) {
  if (vm->steps_left < count)
    agc_fail(vm, "RUNTIME-STEP-LIMIT", "execution step budget exhausted", span + (uint32_t)vm->steps_left);
  vm->steps_left -= count;
}

static bool counting(agc_native_kind kind) {
  return kind == AGC_NATIVE_RANGE_EACH || kind == AGC_NATIVE_TIMES || kind == AGC_NATIVE_UPTO ||
         kind == AGC_NATIVE_DOWNTO;
}

static void resume_native(agc_vm *vm) {
  agc_frame *frame = &vm->frames[vm->frame_count - 1];
  agc_native *st = frame->native;
  uint32_t base = frame->base;
  if (counting(st->kind)) {
    if (!st->more) {
      finish_native(vm, agc_void());
      return;
    }
    charge_steps(vm, 1, st->span);
    agc_value arg = agc_int(st->cur);
    st->more = st->cur != st->last;
    if (st->more) st->cur += st->dir;
    call_value(vm, st->fn, base + 1, &arg, 1, base, st->span);
    return;
  }
  const agc_list *items = agc_as_list(vm, st->list);
  if (st->started) {
    agc_value got = vm->regs[base];
    switch (st->kind) {
      case AGC_NATIVE_MAP:
      case AGC_NATIVE_SORT_BY: st->out->items[st->count++] = got; break;
      case AGC_NATIVE_FILTER:
        if (agc_as_bool(vm, got)) st->out->items[st->count++] = items->items[st->index - 1];
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
  if (st->index < items->len) {
    agc_value args[2];
    uint32_t argc = 0;
    if (st->kind == AGC_NATIVE_REDUCE) args[argc++] = st->acc;
    args[argc++] = items->items[st->index++];
    call_value(vm, st->fn, base + 1, args, argc, base, st->span);
    return;
  }
  agc_value result = agc_void();
  switch (st->kind) {
    case AGC_NATIVE_MAP:
    case AGC_NATIVE_FILTER:
      st->out->len = st->count;
      result = agc_list_value(st->out);
      break;
    case AGC_NATIVE_ANY: result = agc_bool(false); break;
    case AGC_NATIVE_ALL: result = agc_bool(true); break;
    case AGC_NATIVE_REDUCE: result = st->acc; break;
    case AGC_NATIVE_SORT_BY: result = agc_sort_by_keys(vm, items, st->out); break;
    default: break;
  }
  finish_native(vm, result);
}

static void start_native(agc_vm *vm, agc_native_kind kind, uint32_t base, uint32_t span) {
  agc_native *st = agc_alloc(sizeof(agc_native));
  const agc_value *args = vm->regs + base;
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
    size_t len = agc_as_list(vm, st->list)->len;
    agc_as_fn(vm, st->fn);
    if (kind == AGC_NATIVE_MAP || kind == AGC_NATIVE_FILTER || kind == AGC_NATIVE_SORT_BY) st->out = agc_new_list(len);
  }
  agc_frame *frame = new_frame(vm);
  frame->function = 0;
  frame->pc = 0;
  frame->base = base;
  frame->ret = base;
  frame->native = st;
  resume_native(vm);
}

static void replace_frame(agc_vm *vm, uint32_t function, uint32_t window, uint32_t span) {
  agc_frame *frame = &vm->frames[vm->frame_count - 1];
  const agc_function *callee = &vm->program->functions[function];
  ensure_registers(vm, (size_t)frame->base + callee->registers, span);
  agc_value *R = vm->regs + frame->base;
  memmove(R, R + window, (size_t)callee->params * sizeof(agc_value));
  frame->function = function;
  frame->pc = 0;
}

static bool return_value(agc_vm *vm, agc_value result) {
  uint32_t ret = vm->frames[vm->frame_count - 1].ret;
  vm->frame_count--;
  vm->depth--;
  if (vm->frame_count == 0) return false;
  vm->regs[ret] = result;
  if (vm->frames[vm->frame_count - 1].native) resume_native(vm);
  return true;
}

static bool equal_values(agc_vm *vm, agc_value x, agc_value y) {
  if (agc_is(x, AGC_T_INT) && agc_is(y, AGC_T_INT)) return agc_as_int(vm, x) == agc_as_int(vm, y);
  if (agc_is(x, AGC_T_FLOAT) && agc_is(y, AGC_T_FLOAT)) return agc_as_float(vm, x) == agc_as_float(vm, y);
  if (agc_is(x, AGC_T_NIL) && agc_is(y, AGC_T_NIL)) return true;
  if (agc_is(x, AGC_T_STRING) && agc_is(y, AGC_T_STRING)) {
    const agc_string *a = agc_as_string(vm, x), *b = agc_as_string(vm, y);
    return a->bytes == b->bytes && (a->bytes == 0 || memcmp(a->data, b->data, a->bytes) == 0);
  }
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

static void run(agc_vm *vm) {
  const agc_program *p = vm->program;
  push_frame(vm, p->entry, 0, 0, 0);
  for (;;) {
    agc_frame *frame = &vm->frames[vm->frame_count - 1];
    const agc_function *fn = &p->functions[frame->function];
    agc_value *R = vm->regs + frame->base;
    uint32_t pc = frame->pc;
    agc_instr in = fn->code[pc];
    uint32_t s = fn->spans[pc];
    uint32_t bx = (uint32_t)in.b | ((uint32_t)in.c << 16);
    frame->pc = pc + 1;
    int64_t x, y, z;
    switch (in.op) {
      case AGC_OP_MOVE: R[in.a] = R[in.b]; break;
      case AGC_OP_CONST: R[in.a] = p->constants[bx]; break;
      case AGC_OP_STEP: charge_steps(vm, in.a, s); break;
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
      case AGC_OP_CONCAT:
        R[in.a] = agc_string_value(agc_concat(agc_as_string(vm, R[in.b]), agc_as_string(vm, R[in.c])));
        break;
      case AGC_OP_TO_TEXT: R[in.a] = agc_string_value(agc_text(vm, R[in.b])); break;
      case AGC_OP_INSPECT: R[in.a] = agc_string_value(agc_debug(vm, R[in.b])); break;
      case AGC_OP_LIST: {
        agc_list *l = agc_new_list(in.c);
        for (uint32_t k = 0; k < in.c; k++) l->items[k] = R[(uint32_t)in.b + k];
        R[in.a] = agc_list_value(l);
        break;
      }
      case AGC_OP_LIST_LEN: R[in.a] = agc_int((int64_t)agc_as_list(vm, R[in.b])->len); break;
      case AGC_OP_LIST_GET: {
        const agc_list *l = agc_as_list(vm, R[in.b]);
        x = agc_as_int(vm, R[in.c]);
        if (x < 0 || (uint64_t)x >= l->len) index_out_of_range(vm, x, l->len, s);
        R[in.a] = l->items[x];
        break;
      }
      case AGC_OP_MAP: {
        agc_map *m = agc_new_map();
        for (uint32_t k = 0; k < in.c; k++)
          m = agc_map_put(vm, m, R[(uint32_t)in.b + 2 * k], R[(uint32_t)in.b + 2 * k + 1]);
        R[in.a] = agc_map_value(m);
        break;
      }
      case AGC_OP_MAP_GET: {
        agc_value found;
        if (!agc_map_get(vm, agc_as_map(vm, R[in.b]), R[in.c], &found)) key_not_found(vm, R[in.c], s);
        R[in.a] = found;
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
      case AGC_OP_SAME: R[in.a] = agc_bool(same_values(vm, R[in.b], R[in.c])); break;
      case AGC_OP_NOT: R[in.a] = agc_bool(!agc_as_bool(vm, R[in.b])); break;
      case AGC_OP_LT_I: R[in.a] = agc_bool(agc_as_int(vm, R[in.b]) < agc_as_int(vm, R[in.c])); break;
      case AGC_OP_LE_I: R[in.a] = agc_bool(agc_as_int(vm, R[in.b]) <= agc_as_int(vm, R[in.c])); break;
      case AGC_OP_EQ: R[in.a] = agc_bool(equal_values(vm, R[in.b], R[in.c])); break;
      case AGC_OP_NE: R[in.a] = agc_bool(!equal_values(vm, R[in.b], R[in.c])); break;
      case AGC_OP_JUMP: frame->pc = bx; break;
      case AGC_OP_JUMP_IF_FALSE:
        if (!agc_as_bool(vm, R[in.a])) frame->pc = bx;
        break;
      case AGC_OP_JUMP_IF_TRUE:
        if (agc_as_bool(vm, R[in.a])) frame->pc = bx;
        break;
      case AGC_OP_CALL: push_frame(vm, bx, frame->base + in.a, frame->base + in.a, s); break;
      case AGC_OP_CALL_VALUE: {
        uint32_t at = frame->base + in.a;
        call_value(vm, vm->regs[at], at + 1, NULL, in.b, at, s);
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
        if (p->builtins[bx]->native) {
          start_native(vm, p->builtins[bx]->native, base, s);
          break;
        }
        agc_value result = p->builtins[bx]->fn(vm, vm->regs + base, s);
        vm->regs[base] = result;
        break;
      }
      case AGC_OP_RETURN:
        if (!return_value(vm, R[in.a])) return;
        break;
      case AGC_OP_TRY: {
        const agc_result *r = agc_as_result(vm, R[in.b]);
        if (r->ok) {
          R[in.a] = r->value;
        } else {
          if (vm->frame_count == 1) agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: try in the entry function", s);
          return_value(vm, R[in.b]);
        }
        break;
      }
      case AGC_OP_IS_OK: R[in.a] = agc_bool(agc_as_result(vm, R[in.b])->ok); break;
      case AGC_OP_RESULT_VALUE: R[in.a] = agc_as_result(vm, R[in.b])->value; break;
      default: agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: unknown opcode", 0);
    }
  }
}

agc_outcome agc_vm_run(agc_vm *vm) {
  if (setjmp(vm->fail) == 0) {
    run(vm);
    vm->outcome.kind = AGC_DONE;
  }
  return vm->outcome;
}
