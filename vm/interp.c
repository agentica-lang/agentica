#include "agc.h"

#include <inttypes.h>
#include <math.h>
#include <string.h>

void agc_fail(agc_vm *vm, const char *code, const char *message, uint32_t span) {
  vm->outcome.kind = AGC_FAILED;
  vm->outcome.code = code;
  vm->outcome.message = message;
  vm->outcome.span = span;
  longjmp(vm->fail, 1);
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

static void push_frame(agc_vm *vm, uint32_t function, uint32_t base, uint32_t span) {
  if (vm->depth >= AGC_MAX_DEPTH) agc_fail(vm, "RUNTIME-STACK-OVERFLOW", "call depth limit exceeded", span);
  ensure_registers(vm, (size_t)base + vm->program->functions[function].registers, span);
  if (vm->depth == vm->frame_capacity) {
    uint32_t capacity = vm->frame_capacity ? vm->frame_capacity * 2 : 64;
    agc_frame *frames = agc_alloc(agc_size_mul(capacity, sizeof(agc_frame)));
    if (vm->depth) memcpy(frames, vm->frames, vm->depth * sizeof(agc_frame));
    vm->frames = frames;
    vm->frame_capacity = capacity;
  }
  vm->frames[vm->depth].function = function;
  vm->frames[vm->depth].pc = 0;
  vm->frames[vm->depth].base = base;
  vm->depth++;
}

static bool equal_values(agc_vm *vm, agc_value x, agc_value y) {
  if (agc_is(x, AGC_T_INT) && agc_is(y, AGC_T_INT)) return agc_as_int(vm, x) == agc_as_int(vm, y);
  if (agc_is(x, AGC_T_FLOAT) && agc_is(y, AGC_T_FLOAT)) return agc_as_float(vm, x) == agc_as_float(vm, y);
  if (agc_is(x, AGC_T_NIL) && agc_is(y, AGC_T_NIL)) return true;
  if (agc_is(x, AGC_T_STRING) && agc_is(y, AGC_T_STRING)) {
    const agc_string *a = agc_as_string(vm, x), *b = agc_as_string(vm, y);
    return a->bytes == b->bytes && (a->bytes == 0 || memcmp(a->data, b->data, a->bytes) == 0);
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

static void run(agc_vm *vm) {
  const agc_program *p = vm->program;
  push_frame(vm, p->entry, 0, 0);
  for (;;) {
    agc_frame *frame = &vm->frames[vm->depth - 1];
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
      case AGC_OP_STEP:
        if (vm->steps_left < in.a)
          agc_fail(vm, "RUNTIME-STEP-LIMIT", "execution step budget exhausted", s + (uint32_t)vm->steps_left);
        vm->steps_left -= in.a;
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
          R[in.a] = v->shared;
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
      case AGC_OP_CALL: push_frame(vm, bx, frame->base + in.a, s); break;
      case AGC_OP_CALL_BUILTIN: {
        uint32_t base = frame->base + in.a;
        agc_value result = p->builtins[bx]->fn(vm, vm->regs + base, s);
        vm->regs[base] = result;
        break;
      }
      case AGC_OP_RETURN: {
        agc_value result = R[in.a];
        uint32_t base = frame->base;
        vm->depth--;
        if (vm->depth == 0) return;
        vm->regs[base] = result;
        break;
      }
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
