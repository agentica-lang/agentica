/*
 * The JIT tier (docs/future/22-jit.md §22): which functions to compile and when, the walk over a function's bytecode
 * that drives the host's emitter, and the code cache of a run. Every function can be compiled: an instruction without
 * code of its own leaves for the interpreter, which runs it and comes back. With `on`, only a function with a loop
 * that seldom leaves is compiled. Core layer.
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

/* True when IN at PC jumps back to *START or before it: the end of a loop. */
static bool backward(agc_instr in, uint32_t pc, uint32_t *start) {
  uint32_t op = plain_op(in.op);
  *start = (uint32_t)in.b | ((uint32_t)in.c << 16);
  return (op == AGC_OP_JUMP || op == AGC_OP_JUMP_IF_FALSE || op == AGC_OP_JUMP_IF_TRUE) && *start <= pc;
}

/* True when IN always has code of its own. CALL and RETURN have code that may exit (leaves_code). */
static bool has_code(uint32_t op) {
  switch (plain_op(op)) {
    case AGC_OP_MOVE:
    case AGC_OP_CONST:
    case AGC_OP_STEP:
    case AGC_OP_ADD_I:
    case AGC_OP_SUB_I:
    case AGC_OP_MUL_I:
    case AGC_OP_DIV_I:
    case AGC_OP_MOD_I:
    case AGC_OP_NEG_I:
    case AGC_OP_LT_I:
    case AGC_OP_LE_I:
    case AGC_OP_EQ:
    case AGC_OP_NE:
    case AGC_OP_ADD_F:
    case AGC_OP_SUB_F:
    case AGC_OP_MUL_F:
    case AGC_OP_DIV_F:
    case AGC_OP_NEG_F:
    case AGC_OP_LT_F:
    case AGC_OP_LE_F:
    case AGC_OP_SAME:
    case AGC_OP_CONCAT:
    case AGC_OP_TO_TEXT:
    case AGC_OP_LIST_LEN:
    case AGC_OP_LIST_GET:
    case AGC_OP_NOT:
    case AGC_OP_FIELD:
    case AGC_OP_IS_VARIANT:
    case AGC_OP_PAYLOAD:
    case AGC_OP_IS_OK:
    case AGC_OP_RESULT_VALUE:
    case AGC_OP_JUMP:
    case AGC_OP_JUMP_IF_FALSE:
    case AGC_OP_JUMP_IF_TRUE: return true;
    default: return false;
  }
}

/* True when IN makes the `on` heuristic count a trip out of compiled code. A CALL of a function that may get code
   (CALLABLE) is a native call, and a RETURN runs once per call; a leaf builtin is called by run_compiled itself, which
   LEAF says to count or not. */
static bool leaves_code(const agc_program *p, agc_instr in, const bool *callable, bool leaf) {
  uint32_t bx = (uint32_t)in.b | ((uint32_t)in.c << 16);
  if (has_code(in.op) || in.op == AGC_OP_RETURN) return false;
  if (in.op == AGC_OP_CALL) return bx >= p->function_count || !callable[bx];
  return in.op != AGC_OP_CALL_BUILTIN || !p->builtins[bx]->leaf || leaf;
}

/* Why F stays in the interpreter with MODE, for the trace, or NULL when it may be compiled, with CALLABLE the
   functions that may still get code. `always` compiles every function, so the tests run the emitter on all of them.
   With `on`, a function without a loop runs each instruction at most once per entry, and an entry from the
   interpreter, the exit and the RETURN there cost more than the few instructions it saves; it gets code only to be
   called natively from compiled code, and only when none of its instructions leaves ("none" otherwise, where a leaf
   builtin counts: its exit unwinds every native call). A function with an innermost loop (one that holds no other
   loop's end) that goes back to the turn loop more than once in AGC_JIT_SPACING instructions stays out ("exits"):
   each round trip costs about as much as interpreting that many instructions, so such a loop ran slower compiled.
   LEAVES and ENDS are scratch arrays of f->count + 1 entries: counts before each pc, so that each loop is measured in
   constant time. */
static const char *kept_out(const agc_program *p, const agc_function *f, agc_jit_mode mode, uint32_t *leaves,
                            uint32_t *ends, const bool *callable) {
  if (mode != AGC_JIT_ON) return NULL;
  leaves[0] = ends[0] = 0;
  for (uint32_t pc = 0; pc < f->count; pc++) {
    uint32_t start;
    ends[pc + 1] = ends[pc] + backward(f->code[pc], pc, &start);
    leaves[pc + 1] = leaves[pc] + leaves_code(p, f->code[pc], callable, false);
  }
  if (!ends[f->count]) {
    for (uint32_t pc = 0; pc < f->count; pc++)
      if (leaves_code(p, f->code[pc], callable, true)) return "none";
    return NULL;
  }
  for (uint32_t pc = 0; pc < f->count; pc++) {
    uint32_t start;
    if (!backward(f->code[pc], pc, &start) || ends[pc] - ends[start] > 0) continue;
    uint64_t size = (uint64_t)pc - start + 1, out = leaves[pc + 1] - leaves[start];
    if (out * AGC_JIT_SPACING > size) return "exits";
  }
  return NULL;
}

#if AGC_JIT_HOST
/* The size of F's code, or 0 when an operand or the code did not fit. Its cases are the set of has_code, CALL and
   RETURN; other instructions leave for the interpreter. */
static size_t emit_function(agc_emitter *e, const agc_jit *jit, const agc_function *f) {
  agc_emit_begin(e, f->count);
  for (uint32_t pc = 0; pc < f->count && !e->failed; pc++) {
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
      case AGC_OP_ADD_F:
      case AGC_OP_SUB_F:
      case AGC_OP_MUL_F:
      case AGC_OP_DIV_F:
      case AGC_OP_NEG_F:
      case AGC_OP_LT_F:
      case AGC_OP_LE_F:
      case AGC_OP_SAME:
      case AGC_OP_CONCAT:
      case AGC_OP_TO_TEXT:
      case AGC_OP_LIST_LEN:
      case AGC_OP_LIST_GET: agc_emit_helper(e, op, in, pc); break;
      case AGC_OP_NOT:
      case AGC_OP_FIELD:
      case AGC_OP_IS_VARIANT:
      case AGC_OP_PAYLOAD:
      case AGC_OP_IS_OK:
      case AGC_OP_RESULT_VALUE: agc_emit_read(e, op, in, pc); break;
      case AGC_OP_JUMP: agc_emit_jump(e, bx); break;
      case AGC_OP_JUMP_IF_FALSE:
      case AGC_OP_JUMP_IF_TRUE: agc_emit_branch(e, in.a, op == AGC_OP_JUMP_IF_TRUE, bx, pc); break;
      case AGC_OP_CALL:
        /* The loader checks bx; the C tests' hand-made code may not. */
        if (bx < jit->program->function_count)
          agc_emit_call(e, in, pc, (uint64_t)(uintptr_t)&jit->code[bx], jit->program->functions[bx].registers);
        else
          agc_emit_exit(e, AGC_JIT_EXIT_CALL, pc);
        break;
      case AGC_OP_RETURN: agc_emit_return(e, in.a, pc); break;
      default: agc_emit_exit(e, AGC_JIT_EXIT_INTERPRET, pc); break;
    }
  }
  return agc_emit_end(e);
}
#else
/* No emitter for this architecture: every function stays interpreted. */
static size_t emit_function(agc_emitter *e, const agc_jit *jit, const agc_function *f) {
  (void)e;
  (void)jit;
  (void)f;
  return 0;
}
#endif

static agc_jit_code skip(agc_jit *jit, uint32_t function) {
  atomic_store_explicit(&jit->skip[function], true, memory_order_relaxed);
  atomic_store_explicit(&jit->native_only[function], false, memory_order_relaxed);
  return NULL;
}

static agc_jit_code compile(agc_jit *jit, uint32_t function) {
  const agc_function *f = &jit->program->functions[function];
  agc_emitter e;
  size_t size = emit_function(&e, jit, f);
  if (!size) {
    AGC_TRACE(jit->trace, AGC_TRACE_JIT, "skip function=%.*s size", agc_trace_len(f->name->bytes), f->name->data);
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

agc_jit_code agc_jit_callee_code(agc_jit *jit, uint32_t function) {
  agc_jit_code code = atomic_load_explicit(&jit->code[function], memory_order_acquire);
  /* A function the interpreter enters gets its code (and its entries counted) at the reload. */
  if (code || !agc_jit_native_only(jit, function)) return code;
  code = compile(jit, function);
  /* From now on the reload tests it, and run_compiled enters it only to resume a frame. */
  if (code) atomic_store_explicit(&jit->skip[function], false, memory_order_relaxed);
  return code;
}

agc_jit *agc_jit_new(const agc_program *program, agc_jit_mode mode, const agc_trace *trace) {
  if (mode == AGC_JIT_OFF || !AGC_JIT_HOST) return NULL;
  /* Each function is decided once, here: a function kept out is never counted or walked again, and a run where every
     function is kept out has no JIT (nothing is allocated), so it runs the plain copy of the turn loop, the code of
     --jit off. */
  size_t n = program->function_count, longest = 0;
  for (uint32_t k = 0; k < n; k++)
    if (program->functions[k].count > longest) longest = program->functions[k].count;
  uint32_t *leaves = agc_alloc_atomic(agc_size_mul(longest + 1, sizeof *leaves));
  uint32_t *ends = agc_alloc_atomic(agc_size_mul(longest + 1, sizeof *ends));
  _Atomic bool *skip = agc_alloc_atomic(agc_size_mul(n ? n : 1, sizeof *skip));
  _Atomic bool *native_only = agc_alloc_atomic(agc_size_mul(n ? n : 1, sizeof *native_only));
  bool *callable = agc_alloc_atomic(agc_size_mul(n ? n : 1, sizeof *callable));
  for (uint32_t k = 0; k < n; k++) callable[k] = true;
  /* A call stays in compiled code only when its callee may get code, which depends on the callee's own calls: each
     round drops the functions that leave given the last round's set. A few rounds settle the call chains of real
     programs; a set that is still too wide after them only costs speed. */
  for (int round = 0; mode == AGC_JIT_ON && round < 8; round++) {
    bool changed = false;
    for (uint32_t k = 0; k < n; k++) {
      if (!callable[k] || !kept_out(program, &program->functions[k], mode, leaves, ends, callable)) continue;
      callable[k] = false;
      changed = true;
    }
    if (!changed) break;
  }
  bool any = false;
  for (uint32_t k = 0; k < n; k++) {
    const agc_function *f = &program->functions[k];
    const char *why = kept_out(program, f, mode, leaves, ends, callable);
    /* With `on`, a function without a loop that may get code is entered only by native calls. */
    bool native = !why && mode == AGC_JIT_ON && !ends[f->count], entered = !why && !native;
    atomic_init(&skip[k], !entered);
    atomic_init(&native_only[k], native);
    if (entered)
      any = true;
    else if (why)
      AGC_TRACE(trace, AGC_TRACE_JIT, "skip function=%.*s loop=%s", agc_trace_len(f->name->bytes), f->name->data, why);
  }
  if (!any) return NULL;
  agc_jit *jit = agc_alloc(sizeof *jit);
  jit->program = program;
  jit->mode = mode;
  jit->trace = trace;
  jit->skip = skip;
  jit->native_only = native_only;
  jit->code = agc_alloc_atomic(agc_size_mul(n, sizeof *jit->code));
  jit->entries = agc_alloc_atomic(agc_size_mul(n, sizeof *jit->entries));
  jit->exits = agc_alloc_atomic(sizeof *jit->exits * AGC_OP_COUNT);
  for (uint32_t k = 0; k < n; k++) {
    atomic_init(&jit->code[k], NULL);
    atomic_init(&jit->entries[k], 0);
  }
  for (uint32_t op = 0; op < AGC_OP_COUNT; op++) atomic_init(&jit->exits[op], 0);
  atomic_init(&jit->leaves, 0);
  atomic_init(&jit->transitions, 0);
  atomic_init(&jit->used, 0);
  return jit;
}

void agc_jit_count_exit(agc_jit *jit, uint32_t function, uint32_t pc) {
  uint32_t op = plain_op(jit->program->functions[function].code[pc].op);
  if (op < AGC_OP_COUNT) atomic_fetch_add_explicit(&jit->exits[op], 1, memory_order_relaxed);
}

void agc_jit_count_leaf(agc_jit *jit) { atomic_fetch_add_explicit(&jit->leaves, 1, memory_order_relaxed); }

void agc_jit_count_transition(agc_jit *jit) { atomic_fetch_add_explicit(&jit->transitions, 1, memory_order_relaxed); }

void agc_jit_report(agc_jit *jit) {
  for (uint32_t op = 0; op < AGC_OP_COUNT; op++) {
    uint64_t count = atomic_load_explicit(&jit->exits[op], memory_order_relaxed);
    if (count) AGC_TRACE(jit->trace, AGC_TRACE_JIT, "exit op=%s count=%" PRIu64, agc_opcode_name(op), count);
  }
  uint64_t leaves = atomic_load_explicit(&jit->leaves, memory_order_relaxed);
  if (leaves) AGC_TRACE(jit->trace, AGC_TRACE_JIT, "leaf count=%" PRIu64, leaves);
  uint64_t transitions = atomic_load_explicit(&jit->transitions, memory_order_relaxed);
  if (transitions) AGC_TRACE(jit->trace, AGC_TRACE_JIT, "transition count=%" PRIu64, transitions);
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
