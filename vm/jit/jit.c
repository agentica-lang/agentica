/*
 * The JIT tier (docs/future/22-jit.md §22): which functions to compile and when, the walk over a function's bytecode
 * that drives the host's emitter, and the code cache of a run. A function is compiled only when every instruction is
 * in the set the emitter knows; any other keeps it in the interpreter. Core layer.
 */
#include "jit.h"

#include <inttypes.h>
#include <string.h>

#define PAGE ((size_t)4096)

/* The opcode a fused one starts with (vm/value.h): its STEP or CONST, compiled alone like the instruction after it,
   which the loader left in place. */
static uint32_t plain_op(uint32_t op) {
  if (op < AGC_OP_COUNT || op >= AGC_FUSED_END) return op;
  return op >= AGC_FUSED_CONST_FIRST ? AGC_OP_CONST : AGC_OP_STEP;
}

#if AGC_JIT_HOST
/* The code of F, or 0 with *BAD the pc of the first instruction the emitter does not know (UINT32_MAX when an operand
   or the code did not fit). The set: MOVE, CONST, STEP, the Int operators and compares, EQ, NE, the jumps and RETURN. */
static size_t emit_function(agc_emitter *e, const agc_function *f, uint32_t *bad) {
  agc_emit_begin(e, f->count);
  for (uint32_t pc = 0; pc < f->count; pc++) {
    agc_instr in = f->code[pc];
    agc_opcode op = (agc_opcode)plain_op(in.op);
    uint32_t bx = (uint32_t)in.b | ((uint32_t)in.c << 16);
    agc_emit_label(e, pc);
    switch (op) {
      case AGC_OP_MOVE: agc_emit_move(e, in.a, in.b); break;
      case AGC_OP_CONST: agc_emit_const(e, in.a, bx); break;
      case AGC_OP_STEP: agc_emit_step(e, in.a, pc); break;
      case AGC_OP_ADD_I:
      case AGC_OP_SUB_I:
      case AGC_OP_MUL_I:
      case AGC_OP_DIV_I:
      case AGC_OP_MOD_I:
      case AGC_OP_NEG_I:
      case AGC_OP_LT_I:
      case AGC_OP_LE_I: agc_emit_int(e, op, in, pc); break;
      case AGC_OP_EQ:
      case AGC_OP_NE: agc_emit_equal(e, op, in, pc); break;
      case AGC_OP_JUMP: agc_emit_jump(e, bx); break;
      case AGC_OP_JUMP_IF_FALSE:
      case AGC_OP_JUMP_IF_TRUE: agc_emit_branch(e, in.a, op == AGC_OP_JUMP_IF_TRUE, bx, pc); break;
      /* The interpreter runs RETURN: it pops the frame and resumes the caller, which may be a native frame. */
      case AGC_OP_RETURN: agc_emit_exit(e, AGC_JIT_EXIT_INTERPRET, pc); break;
      default: *bad = pc; return 0;
    }
    if (e->failed) break;
  }
  *bad = UINT32_MAX;
  return agc_emit_end(e);
}
#else
/* No emitter for this architecture: every function stays interpreted. */
static size_t emit_function(agc_emitter *e, const agc_function *f, uint32_t *bad) {
  (void)e;
  (void)f;
  *bad = UINT32_MAX;
  return 0;
}
#endif

static agc_jit_code skip(agc_jit *jit, uint32_t function) {
  atomic_store_explicit(&jit->skip[function], true, memory_order_relaxed);
  return NULL;
}

static agc_jit_code compile(agc_jit *jit, uint32_t function) {
  const agc_function *f = &jit->program->functions[function];
  agc_emitter e;
  uint32_t bad;
  size_t size = emit_function(&e, f, &bad);
  if (!size) {
    const char *op = bad < f->count ? agc_opcode_name(plain_op(f->code[bad].op)) : "size";
    AGC_TRACE(jit->trace, AGC_TRACE_JIT, "skip function=%.*s pc=%" PRIu32 " op=%s", agc_trace_len(f->name->bytes),
              f->name->data, bad, op);
    return skip(jit, function);
  }
  size_t pages = (size + PAGE - 1) / PAGE * PAGE;
  if (atomic_fetch_add(&jit->used, pages) + pages > AGC_JIT_CODE_CAP) {
    atomic_fetch_sub(&jit->used, pages);
    AGC_TRACE(jit->trace, AGC_TRACE_JIT, "full function=%.*s", agc_trace_len(f->name->bytes), f->name->data);
    return skip(jit, function);
  }
  void *memory = agc_jit_mem_map(size);
  if (memory) memcpy(memory, e.code, size);
  if (!memory || !agc_jit_mem_seal(memory, size)) {
    if (memory) agc_jit_mem_unmap(memory, size);
    atomic_fetch_sub(&jit->used, pages);
    return skip(jit, function);
  }
  agc_jit_code code = (agc_jit_code)(uintptr_t)memory;
  agc_jit_code first = NULL;
  if (!atomic_compare_exchange_strong_explicit(&jit->code[function], &first, code, memory_order_acq_rel,
                                               memory_order_acquire)) {
    agc_jit_mem_unmap(memory, size);
    atomic_fetch_sub(&jit->used, pages);
    return first;
  }
  AGC_TRACE(jit->trace, AGC_TRACE_JIT, "compile function=%.*s instructions=%" PRIu32 " bytes=%zu",
            agc_trace_len(f->name->bytes), f->name->data, f->count, size);
  return code;
}

agc_jit_code agc_jit_code_of(agc_jit *jit, uint32_t function) {
  agc_jit_code code = atomic_load_explicit(&jit->code[function], memory_order_acquire);
  if (code || atomic_load_explicit(&jit->skip[function], memory_order_relaxed)) return code;
  if (jit->mode == AGC_JIT_ON &&
      atomic_fetch_add_explicit(&jit->entries[function], 1, memory_order_relaxed) + 1 < AGC_JIT_THRESHOLD)
    return NULL;
  return compile(jit, function);
}

agc_jit *agc_jit_new(const agc_program *program, agc_jit_mode mode, const agc_trace *trace) {
  if (mode == AGC_JIT_OFF || !AGC_JIT_HOST) return NULL;
  size_t n = program->function_count ? program->function_count : 1;
  agc_jit *jit = agc_alloc(sizeof *jit);
  jit->program = program;
  jit->mode = mode;
  jit->trace = trace;
  jit->code = agc_alloc_atomic(agc_size_mul(n, sizeof *jit->code));
  jit->entries = agc_alloc_atomic(agc_size_mul(n, sizeof *jit->entries));
  jit->skip = agc_alloc_atomic(agc_size_mul(n, sizeof *jit->skip));
  for (size_t k = 0; k < n; k++) {
    atomic_init(&jit->code[k], NULL);
    atomic_init(&jit->entries[k], 0);
    atomic_init(&jit->skip[k], false);
  }
  atomic_init(&jit->used, 0);
  return jit;
}

bool agc_jit_mode_parse(const char *word, agc_jit_mode *mode) {
  if (strcmp(word, "off") == 0)
    *mode = AGC_JIT_OFF;
  else if (strcmp(word, "on") == 0)
    *mode = AGC_JIT_ON;
  else if (strcmp(word, "always") == 0)
    *mode = AGC_JIT_ALWAYS;
  else
    return false;
  return true;
}
