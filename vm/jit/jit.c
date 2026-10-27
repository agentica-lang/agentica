/*
 * The JIT tier (docs/future/22-jit.md §22): which functions to compile and when, the walk over a function's bytecode
 * that drives the host's emitter, and the code cache and compile budget of a run. Every function can be compiled: an
 * instruction without code of its own leaves for the interpreter, which runs it and comes back. With `on`, only a
 * function with a loop that seldom leaves is compiled, and the small functions it calls. Core layer.
 */
#include "jit.h"

#include <inttypes.h>
#include <string.h>

/* A part of a function that `on` measures: an innermost loop (one that holds no other loop's end) of SIZE
   instructions, or the whole of a function without a loop, with SIZE 0. OUT counts its instructions that leave
   compiled code; once OUT * AGC_JIT_SPACING passes SIZE, its function OWNER stays out. */
typedef struct {
  uint32_t owner, size, out;
} region;

/* A CALL of function CALLEE inside region REGION. */
typedef struct {
  uint32_t callee, region;
} call_site;

/* The code that waits for a seal (seal_batch), under the JIT's lock: BYTES[0 .. LEN) holds the code of FUNCTIONS[k]
   at OFFSETS[k], SIZES[k] bytes long, for k below COUNT. */
struct agc_jit_batch {
  uint8_t *bytes;
  size_t len, cap;
  uint32_t *functions, *offsets, *sizes;
  size_t count, slots;
};

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

/* True when IN always has code of its own. CALL and RETURN have code that may exit, and TAIL_CALL is an exit that
   run_compiled handles (leaves_code). */
static bool has_code(uint32_t op) {
  switch (plain_op(op)) {
    case AGC_OP_MOVE:
    case AGC_OP_CONST:
    case AGC_OP_GLOBAL:
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
    case AGC_OP_LIST:
    case AGC_OP_MAP_GET:
    case AGC_OP_NOT:
    case AGC_OP_FIELD:
    case AGC_OP_IS_VARIANT:
    case AGC_OP_PAYLOAD:
    case AGC_OP_IS_OK:
    case AGC_OP_RESULT_VALUE:
    case AGC_OP_CLOSURE:
    case AGC_OP_STRUCT:
    case AGC_OP_STRUCT_WITH:
    case AGC_OP_ENUM:
    case AGC_OP_TRY:
    case AGC_OP_TRY_STEP:
    case AGC_OP_JUMP:
    case AGC_OP_JUMP_IF_FALSE:
    case AGC_OP_JUMP_IF_TRUE: return true;
    default: return false;
  }
}

/* True for a CALL or a TAIL_CALL of a function of the program: run_compiled makes the frame transition of either and
   goes on in the callee's code when it has some, so settle counts such a call by its callee. */
static bool calls_function(const agc_program *p, agc_instr in) {
  uint32_t bx = (uint32_t)in.b | ((uint32_t)in.c << 16);
  return (in.op == AGC_OP_CALL || in.op == AGC_OP_TAIL_CALL) && bx < p->function_count;
}

/* True when IN makes the `on` heuristic count a trip out of compiled code, when it is not a call of a function of the
   program (calls_function). A leaf builtin, and a block call (a row with a native kind, such as
   `filter`: its native frame and the block's frames), are started by run_compiled itself, which LEAF says to count or
   not, as their exit unwinds the native calls; a direct builtin is called by the code itself, which leaves only when
   the call ends the turn or fails; a RETURN runs once per call. */
static bool leaves_code(const agc_program *p, agc_instr in, bool leaf) {
  uint32_t bx = (uint32_t)in.b | ((uint32_t)in.c << 16);
  if (has_code(in.op) || in.op == AGC_OP_RETURN) return false;
  if (in.op == AGC_OP_CALL || in.op == AGC_OP_TAIL_CALL) return !calls_function(p, in);
  if (in.op != AGC_OP_CALL_BUILTIN) return true;
  const agc_builtin *b = p->builtins[bx];
  return !b->direct && (!(b->leaf || b->native) || leaf);
}

/* Why `on` keeps a function out:
   - A function without a loop runs each instruction at most once per entry, and an entry from the interpreter, the
     exit and the RETURN there cost more than the few instructions it saves; it gets code only to be called natively
     from compiled code, and only when none of its instructions leaves ("none" otherwise, where a leaf builtin counts:
     its exit unwinds every native call).
   - A function with an innermost loop that goes back to the turn loop more than once in AGC_JIT_SPACING instructions
     stays out ("exits"): each round trip costs about as much as interpreting that many instructions, so such a loop
     ran slower compiled.
   A CALL leaves when its callee may not get code, which depends on the callee's own calls, so the decision is a fixed
   point: every function starts callable, and a function that drops out counts one more leaving instruction in each
   region that calls it. Innermost loops never overlap, so each instruction is in at most one region, and each call
   site is counted once, when its callee drops: the work follows the program's size, whatever the order of the
   functions or the size of a caller. */
size_t agc_jit_settle(const agc_program *p, bool *callable, bool *looped, bool *calling) {
  size_t n = p->function_count, longest = 0, jumps = 0, calls = 0, work = 0;
  for (uint32_t k = 0; k < n; k++) {
    const agc_function *f = &p->functions[k];
    if (f->count > longest) longest = f->count;
    for (uint32_t pc = 0; pc < f->count; pc++) {
      uint32_t start;
      agc_instr in = f->code[pc];
      jumps += backward(in, pc, &start);
      calls += calls_function(p, in);
    }
    work += f->count;
  }
  /* Atomic GC memory is not zeroed. ENDS[pc] counts the loop ends before pc; AT[pc] is the region of pc. */
  uint32_t *ends = agc_alloc_atomic(agc_size_mul(longest + 1, sizeof *ends));
  uint32_t *at = agc_alloc_atomic(agc_size_mul(longest + 1, sizeof *at));
  region *regions = agc_alloc_atomic(agc_size_mul(n + jumps + 1, sizeof *regions));
  call_site *sites = agc_alloc_atomic(agc_size_mul(calls + 1, sizeof *sites));
  size_t region_count = 0, site_count = 0;
  for (uint32_t k = 0; k < n; k++) {
    const agc_function *f = &p->functions[k];
    callable[k] = true;
    calling[k] = false;
    ends[0] = 0;
    for (uint32_t pc = 0; pc < f->count; pc++) {
      uint32_t start;
      ends[pc + 1] = ends[pc] + backward(f->code[pc], pc, &start);
      at[pc] = UINT32_MAX;
    }
    looped[k] = ends[f->count] > 0;
    if (!looped[k]) {
      regions[region_count] = (region){k, 0, 0};
      for (uint32_t pc = 0; pc < f->count; pc++) at[pc] = (uint32_t)region_count;
      region_count++;
    }
    for (uint32_t pc = 0; looped[k] && pc < f->count; pc++) {
      uint32_t start;
      if (!backward(f->code[pc], pc, &start) || ends[pc] - ends[start] > 0) continue;
      regions[region_count] = (region){k, pc - start + 1, 0};
      for (uint32_t q = start; q <= pc; q++) at[q] = (uint32_t)region_count;
      region_count++;
    }
    for (uint32_t pc = 0; pc < f->count; pc++) {
      agc_instr in = f->code[pc];
      bool call = calls_function(p, in);
      calling[k] |= call;
      if (at[pc] == UINT32_MAX) continue;
      if (call)
        sites[site_count++] = (call_site){(uint32_t)in.b | ((uint32_t)in.c << 16), at[pc]};
      else
        regions[at[pc]].out += leaves_code(p, in, !looped[k]);
    }
    work += 2 * (size_t)f->count;
  }
  /* by_callee[first[g] .. first[g + 1]) are the regions of the call sites of g. */
  uint32_t *first = agc_alloc_atomic(agc_size_mul(n + 1, sizeof *first));
  memset(first, 0, (n + 1) * sizeof *first);
  for (size_t s = 0; s < site_count; s++) first[sites[s].callee + 1]++;
  for (size_t k = 0; k < n; k++) first[k + 1] += first[k];
  uint32_t *fill = agc_alloc_atomic(agc_size_mul(n + 1, sizeof *fill));
  memcpy(fill, first, (n + 1) * sizeof *fill);
  uint32_t *by_callee = agc_alloc_atomic(agc_size_mul(site_count + 1, sizeof *by_callee));
  for (size_t s = 0; s < site_count; s++) by_callee[fill[sites[s].callee]++] = sites[s].region;
  /* The stack holds each function that dropped, once, until its call sites are counted. */
  uint32_t *stack = agc_alloc_atomic(agc_size_mul(n + 1, sizeof *stack));
  size_t top = 0;
  for (size_t r = 0; r < region_count; r++) {
    uint32_t k = regions[r].owner;
    if (callable[k] && (uint64_t)regions[r].out * AGC_JIT_SPACING > regions[r].size) {
      callable[k] = false;
      stack[top++] = k;
    }
  }
  while (top) {
    uint32_t g = stack[--top];
    for (uint32_t e = first[g]; e < first[g + 1]; e++) {
      region *r = &regions[by_callee[e]];
      r->out++;
      if (callable[r->owner] && (uint64_t)r->out * AGC_JIT_SPACING > r->size) {
        callable[r->owner] = false;
        stack[top++] = r->owner;
      }
    }
    work += first[g + 1] - first[g];
  }
  return work + site_count;
}

#if AGC_JIT_HOST
/* The size of F's code, or 0 when an operand or the code did not fit. Its cases are the set of has_code, CALL and
   RETURN; other instructions leave for the interpreter. */
static size_t emit_function(agc_emitter *e, const agc_jit *jit, const agc_function *f) {
  const agc_program *p = jit->program;
  agc_emit_begin(e, f->count);
  for (uint32_t pc = 0; pc < f->count && !e->failed; pc++) {
    agc_instr in = f->code[pc];
    agc_opcode op = (agc_opcode)plain_op(in.op);
    uint32_t bx = (uint32_t)in.b | ((uint32_t)in.c << 16);
    agc_emit_label(e, pc);
    switch (op) {
      case AGC_OP_MOVE: agc_emit_move(e, in.a, in.b); break;
      case AGC_OP_CONST: agc_emit_const(e, in.a, bx); break;
      case AGC_OP_GLOBAL:
        /* The loader checks bx, and the indexes of STRUCT and ENUM below; the C tests' hand-made code may not. */
        if (bx < p->global_count)
          agc_emit_global(e, in.a, (uint64_t)(uintptr_t)&p->globals[bx], pc);
        else
          agc_emit_exit(e, AGC_JIT_EXIT_INTERPRET, pc);
        break;
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
      case AGC_OP_LIST: agc_emit_list(e, in); break;
      case AGC_OP_CLOSURE:
        /* As for CALL, the loader checks bx. */
        if (bx < p->function_count)
          agc_emit_closure(e, in, p->functions[bx].captures);
        else
          agc_emit_exit(e, AGC_JIT_EXIT_INTERPRET, pc);
        break;
      case AGC_OP_MAP_GET: agc_emit_map_get(e, in, pc); break;
      case AGC_OP_STRUCT:
        if (in.c < p->struct_count)
          agc_emit_new(e, in, (uint64_t)(uintptr_t)agc_jit_struct, in.c, p->structs[in.c].count);
        else
          agc_emit_exit(e, AGC_JIT_EXIT_INTERPRET, pc);
        break;
      case AGC_OP_STRUCT_WITH:
        if (in.c < p->update_count)
          agc_emit_struct_with(e, in, pc, (uint64_t)(uintptr_t)&p->updates[in.c]);
        else
          agc_emit_exit(e, AGC_JIT_EXIT_INTERPRET, pc);
        break;
      case AGC_OP_ENUM:
        if (in.c < p->variant_count)
          agc_emit_new(e, in, (uint64_t)(uintptr_t)agc_jit_enum, (uint64_t)(uintptr_t)&p->variants[in.c], in.c);
        else
          agc_emit_exit(e, AGC_JIT_EXIT_INTERPRET, pc);
        break;
      case AGC_OP_NOT:
      case AGC_OP_FIELD:
      case AGC_OP_IS_VARIANT:
      case AGC_OP_PAYLOAD:
      case AGC_OP_IS_OK:
      case AGC_OP_RESULT_VALUE:
      case AGC_OP_TRY:
      case AGC_OP_TRY_STEP: agc_emit_read(e, op, in, pc); break;
      case AGC_OP_JUMP: agc_emit_jump(e, bx); break;
      case AGC_OP_JUMP_IF_FALSE:
      case AGC_OP_JUMP_IF_TRUE: agc_emit_branch(e, in.a, op == AGC_OP_JUMP_IF_TRUE, bx, pc); break;
      case AGC_OP_CALL:
        /* The loader checks bx; the C tests' hand-made code may not. */
        if (bx < p->function_count)
          agc_emit_call(e, in, pc, (uint64_t)(uintptr_t)&jit->code[bx], p->functions[bx].registers);
        else
          agc_emit_exit(e, AGC_JIT_EXIT_CALL, pc);
        break;
      case AGC_OP_TAIL_CALL:
        /* As for CALL, the loader checks bx. */
        agc_emit_exit(e, bx < p->function_count ? AGC_JIT_EXIT_TAIL_CALL : AGC_JIT_EXIT_INTERPRET, pc);
        break;
      case AGC_OP_RETURN: agc_emit_return(e, in.a, pc); break;
      case AGC_OP_CALL_BUILTIN:
        /* As for CALL, the C tests' hand-made code may have no builtin table. */
        if (bx < p->builtin_count && p->builtins[bx]->direct)
          agc_emit_builtin(e, in, pc, (uint64_t)(uintptr_t)p->builtins[bx], f->spans[pc]);
        else
          agc_emit_exit(e, AGC_JIT_EXIT_INTERPRET, pc);
        break;
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

/* Code memory is sealed by whole pages, and a sealed page is read-execute for good (another scheduler may be running
   its code), so no later function can be written into it. To share pages, the code of a function without a loop that
   `on` compiles for native calls waits in the batch, a buffer of ordinary memory, and is sealed with the functions
   after it: at AGC_JIT_CALLEE_THRESHOLD more CALL exits of a function in it, when the interpreter enters a function
   that just compiled (which must run now), or when the batch holds AGC_JIT_BATCH bytes. So functions that get hot
   about together, such as the callees of one long loop body, share a seal, even when several schedulers run them.
   Each seal takes the next pages of the run's code memory, each function at a multiple of 16 bytes. The batch, the
   chunks, `cap` and `used` change under the lock. */
#define CODE_ALIGN ((size_t)16)
#define AGC_JIT_BATCH ((size_t)16 * 1024)
/* The first chunk of code memory; each next one is twice as big, so the address space follows the code (an address
   space limit counts reserved pages too). */
#define AGC_JIT_FIRST_CHUNK ((size_t)1024 * 1024)

static size_t aligned(size_t n) { return (n + CODE_ALIGN - 1) / CODE_ALIGN * CODE_ALIGN; }
static size_t whole_pages(const agc_jit *jit, size_t n) { return (n + jit->page - 1) / jit->page * jit->page; }

/* PAGES bytes of code memory, opened writable: the next pages of the current chunk, or of a new chunk reserved when
   they do not fit it (twice as big as the last one, or only PAGES when that is refused). NULL when the memory
   fails; then `cap` drops to `used`, so nothing is compiled any more (lock held). */
static uint8_t *take(agc_jit *jit, size_t pages) {
  uint8_t *arena = atomic_load_explicit(&jit->arena, memory_order_relaxed);
  if (!arena || pages > jit->chunk - jit->chunk_used) {
    size_t want = jit->chunk ? agc_size_mul(jit->chunk, 2) : AGC_JIT_FIRST_CHUNK;
    if (want > AGC_JIT_CODE_CAP) want = AGC_JIT_CODE_CAP;
    if (want < pages) want = pages;
    arena = agc_jit_mem_reserve(want);
    if (!arena && want > pages) arena = agc_jit_mem_reserve(want = pages);
    if (!arena) {
      AGC_TRACE(jit->trace, AGC_TRACE_JIT, "memory pages=%zu", pages);
      jit->cap = atomic_load_explicit(&jit->used, memory_order_relaxed);
      return NULL;
    }
    atomic_store_explicit(&jit->arena, arena, memory_order_relaxed);
    jit->chunk = want;
    jit->chunk_used = 0;
  }
  uint8_t *memory = arena + jit->chunk_used;
  jit->chunk_used += pages;
  atomic_store_explicit(&jit->used, atomic_load_explicit(&jit->used, memory_order_relaxed) + pages,
                        memory_order_relaxed);
  if (agc_jit_mem_open(memory, pages)) return memory;
  AGC_TRACE(jit->trace, AGC_TRACE_JIT, "memory pages=%zu", pages);
  jit->cap = atomic_load_explicit(&jit->used, memory_order_relaxed);
  return NULL;
}

/* True when SIZE more bytes after the batch fit the code memory left (lock held). */
static bool fits(agc_jit *jit, size_t size) {
  size_t used = atomic_load_explicit(&jit->used, memory_order_relaxed);
  return size <= jit->cap && whole_pages(jit, aligned(jit->batch->len) + size) <= jit->cap - used;
}

/* Appends the SIZE bytes of CODE, the code of FUNCTION, to the batch (lock held). */
static void batch_add(struct agc_jit_batch *b, uint32_t function, const uint8_t *code, size_t size) {
  size_t at = aligned(b->len);
  if (at + size > b->cap) {
    size_t cap = b->cap ? b->cap : AGC_JIT_BATCH;
    while (cap < at + size) cap = agc_size_mul(cap, 2);
    uint8_t *bytes = agc_alloc_atomic(cap);
    if (b->len) memcpy(bytes, b->bytes, b->len);
    b->bytes = bytes;
    b->cap = cap;
  }
  if (b->count == b->slots) {
    size_t slots = b->slots ? agc_size_mul(b->slots, 2) : 64;
    uint32_t *lists[3] = {b->functions, b->offsets, b->sizes};
    for (int k = 0; k < 3; k++) {
      uint32_t *list = agc_alloc_atomic(agc_size_mul(slots, sizeof *list));
      if (b->count) memcpy(list, lists[k], b->count * sizeof *list);
      lists[k] = list;
    }
    b->functions = lists[0];
    b->offsets = lists[1];
    b->sizes = lists[2];
    b->slots = slots;
  }
  /* int3 between two functions: never run. */
  memset(b->bytes + b->len, AGC_EMIT_PAD, at - b->len);
  memcpy(b->bytes + at, code, size);
  b->len = at + size;
  b->functions[b->count] = function;
  b->offsets[b->count] = (uint32_t)at;
  b->sizes[b->count++] = (uint32_t)size;
}

/* FUNCTION's code at CODE, SIZE bytes, published, or FUNCTION kept interpreted when CODE is NULL. */
static void publish(agc_jit *jit, uint32_t function, agc_jit_code code, size_t size) {
  const agc_function *f = &jit->program->functions[function];
  if (!code) {
    skip(jit, function);
    return;
  }
  atomic_store_explicit(&jit->code[function], code, memory_order_release);
  /* From the next turn on, every turn runs the jit copy of the turn loop (agc_jit_turn). */
  atomic_store_explicit(&jit->live, true, memory_order_release);
  /* From now on the reload tests a function compiled for native calls, and run_compiled enters it only to resume a
     frame, or at its first instruction when a native frame sits below (a block call). */
  if (agc_jit_native_only(jit, function)) atomic_store_explicit(&jit->skip[function], false, memory_order_relaxed);
  AGC_TRACE(jit->trace, AGC_TRACE_JIT, "compile function=%.*s instructions=%" PRIu32 " bytes=%zu",
            agc_trace_len(f->name->bytes), f->name->data, f->count, size);
}

/* Seals the batch, and after it the SIZE bytes of CODE, the code of FUNCTION, when CODE is not NULL, in the next pages
   of the run's code memory, and publishes them all. The pages are opened writable, filled and sealed read-execute,
   and the code is published only after the seal. When the memory fails, they stay interpreted and nothing is
   compiled any more (lock held, and fits said yes for each function). */
static void seal_batch(agc_jit *jit, uint32_t function, const uint8_t *code, size_t size) {
  struct agc_jit_batch *b = jit->batch;
  size_t at = aligned(b->len), len = code ? at + size : b->len;
  if (!len) return;
  size_t pages = whole_pages(jit, len);
  uint8_t *memory = take(jit, pages);
  bool sealed = memory != NULL;
  if (sealed) {
    if (b->len) memcpy(memory, b->bytes, b->len);
    if (code) {
      memset(memory + b->len, AGC_EMIT_PAD, at - b->len);
      memcpy(memory + at, code, size);
    }
    sealed = agc_jit_mem_seal(memory, pages);
    if (!sealed) {
      AGC_TRACE(jit->trace, AGC_TRACE_JIT, "memory pages=%zu", pages);
      jit->cap = atomic_load_explicit(&jit->used, memory_order_relaxed);
    }
  }
  for (size_t k = 0; k < b->count; k++)
    publish(jit, b->functions[k], sealed ? (agc_jit_code)(uintptr_t)(memory + b->offsets[k]) : NULL, b->sizes[k]);
  if (code) publish(jit, function, sealed ? (agc_jit_code)(uintptr_t)(memory + at) : NULL, size);
  b->len = b->count = 0;
}

/* True when FUNCTION claims it now: only that scheduler compiles it, or keeps it out for good. */
static bool claim(agc_jit *jit, uint32_t function) {
  bool unclaimed = false;
  return atomic_compare_exchange_strong_explicit(&jit->claimed[function], &unclaimed, true, memory_order_acq_rel,
                                                 memory_order_acquire);
}

/* Takes COST units of the compile budget, or nothing and false when they do not fit what is left. A compare-and-swap,
   so schedulers that compile at once never take more than the budget together. */
static bool charge(agc_jit *jit, uint64_t cost) {
  uint64_t work = atomic_load_explicit(&jit->work, memory_order_relaxed);
  do {
    if (work > jit->budget || cost > jit->budget - work) return false;
  } while (!atomic_compare_exchange_weak_explicit(&jit->work, &work, work + cost, memory_order_relaxed,
                                                  memory_order_relaxed));
  return true;
}

/* Stops compiling for the rest of the run, once, as FUNCTION (claimed by the caller, which keeps it out) did not fit
   the budget's WHAT, "work" or "bytes": every function that no scheduler claimed is claimed here and stays
   interpreted, so the reload no longer asks for it and nothing walks it. A function claimed before (compiled, in the
   batch, or being compiled on another scheduler) goes on as it was. The trace's `functions` are those that could
   still have been compiled. */
static void spend(agc_jit *jit, uint32_t function, const char *what) {
  if (atomic_exchange_explicit(&jit->spent, true, memory_order_relaxed)) return;
  uint32_t left = 1;
  for (uint32_t k = 0; k < jit->program->function_count; k++) {
    if (!claim(jit, k)) continue;
    if (agc_jit_may_run(jit, k) || agc_jit_native_only(jit, k)) left++;
    skip(jit, k);
  }
  const agc_function *f = &jit->program->functions[function];
  AGC_TRACE(jit->trace, AGC_TRACE_JIT,
            "budget spent=%s function=%.*s work=%" PRIu64 " bytes=%zu functions=%" PRIu32, what,
            agc_trace_len(f->name->bytes), f->name->data, atomic_load_explicit(&jit->work, memory_order_relaxed),
            atomic_load_explicit(&jit->used, memory_order_relaxed), left);
}

/* Compiles FUNCTION: its code runs from now on when NOW is set, else it joins the batch. Returns its code, or NULL
   while it waits in the batch, when it stays interpreted, or when another scheduler compiles it. The budget is taken
   before the walk, so a compile past it costs nothing. */
static agc_jit_code compile(agc_jit *jit, uint32_t function, bool now) {
  if (!claim(jit, function)) return atomic_load_explicit(&jit->code[function], memory_order_acquire);
  const agc_function *f = &jit->program->functions[function];
  uint64_t cost = (uint64_t)f->count + AGC_JIT_COMPILE_BASE;
  /* A function that could never fit stays interpreted alone: spending the budget on it would stop the small ones. */
  if (cost > jit->budget) {
    AGC_TRACE(jit->trace, AGC_TRACE_JIT, "skip function=%.*s budget", agc_trace_len(f->name->bytes), f->name->data);
    return skip(jit, function);
  }
  if (!charge(jit, cost)) {
    spend(jit, function, "work");
    return skip(jit, function);
  }
  agc_emitter e;
  size_t size = emit_function(&e, jit, f);
  if (!size) {
    AGC_TRACE(jit->trace, AGC_TRACE_JIT, "skip function=%.*s size", agc_trace_len(f->name->bytes), f->name->data);
    return skip(jit, function);
  }
  struct agc_jit_batch *b = jit->batch;
  agc_lock_take(jit->lock);
  bool full = !fits(jit, size);
  if (full) {
    skip(jit, function);
  } else if (now) {
    seal_batch(jit, function, e.code, size);
  } else {
    batch_add(b, function, e.code, size);
    if (b->len >= AGC_JIT_BATCH) seal_batch(jit, 0, NULL, 0);
  }
  agc_lock_drop(jit->lock);
  if (full) spend(jit, function, "bytes");
  return atomic_load_explicit(&jit->code[function], memory_order_acquire);
}

agc_jit_code agc_jit_code_of(agc_jit *jit, uint32_t function, uint32_t pc) {
  agc_jit_code code = atomic_load_explicit(&jit->code[function], memory_order_acquire);
  if (code || atomic_load_explicit(&jit->skip[function], memory_order_relaxed)) return code;
  if (jit->mode == AGC_JIT_ON) {
    /* An entry that lands at or before the previous one (a call lands at 0) is a pass: a new call, or a loop that went
       round. The returns and the turns inside one pass of a long loop body land further on each time, so a function
       whose loop runs only a few times stays interpreted however many entries it gets. */
    uint32_t last = atomic_load_explicit(&jit->last[function], memory_order_relaxed);
    atomic_store_explicit(&jit->last[function], pc, memory_order_relaxed);
    uint32_t passes = atomic_load_explicit(&jit->passes[function], memory_order_relaxed);
    if (pc <= last && passes < AGC_JIT_PASSES)
      passes = atomic_fetch_add_explicit(&jit->passes[function], 1, memory_order_relaxed) + 1;
    /* The counts stop at their thresholds, so they never wrap. */
    uint32_t entries = atomic_load_explicit(&jit->entries[function], memory_order_relaxed);
    if (entries < AGC_JIT_THRESHOLD)
      entries = atomic_fetch_add_explicit(&jit->entries[function], 1, memory_order_relaxed) + 1;
    if (entries < AGC_JIT_THRESHOLD || passes < AGC_JIT_PASSES) return NULL;
  }
  return compile(jit, function, true);
}

agc_jit_code agc_jit_callee_code(agc_jit *jit, uint32_t function, bool block) {
  agc_jit_code code = atomic_load_explicit(&jit->code[function], memory_order_acquire);
  /* A function the interpreter enters gets its code (and its entries counted) at the reload. */
  if (code || !agc_jit_native_only(jit, function)) return code;
  /* One that calls may run any number of instructions (it may recurse), and a block runs once for each item of its
     call, so its first exit compiles it, at once. */
  if (block || jit->calling[function]) return compile(jit, function, true);
  uint32_t calls = atomic_fetch_add_explicit(&jit->entries[function], 1, memory_order_relaxed) + 1;
  if (calls < AGC_JIT_CALLEE_THRESHOLD) return NULL;
  if (calls == AGC_JIT_CALLEE_THRESHOLD) return compile(jit, function, false);
  if (calls < 2 * AGC_JIT_CALLEE_THRESHOLD) return NULL;
  /* Still in the batch (or still compiling on another scheduler): seal what is there. */
  agc_lock_take(jit->lock);
  seal_batch(jit, 0, NULL, 0);
  agc_lock_drop(jit->lock);
  return atomic_load_explicit(&jit->code[function], memory_order_acquire);
}

agc_jit *agc_jit_new(const agc_program *program, agc_jit_mode mode, const agc_trace *trace) {
  if (mode == AGC_JIT_OFF || !AGC_JIT_HOST) return NULL;
  /* Each function is decided once, here: a function kept out is never counted or walked again, and a run where every
     function is kept out has no JIT (nothing is allocated), so it runs the plain copy of the turn loop, the code of
     --jit off, as most turns of a run with a JIT do while no code is published (agc_jit_turn). */
  size_t n = program->function_count;
  _Atomic bool *skip = agc_alloc_atomic(agc_size_mul(n ? n : 1, sizeof *skip));
  _Atomic bool *native_only = agc_alloc_atomic(agc_size_mul(n ? n : 1, sizeof *native_only));
  bool *callable = agc_alloc_atomic(agc_size_mul(n ? n : 1, sizeof *callable));
  bool *looped = agc_alloc_atomic(agc_size_mul(n ? n : 1, sizeof *looped));
  bool *calling = agc_alloc_atomic(agc_size_mul(n ? n : 1, sizeof *calling));
  if (mode == AGC_JIT_ON) agc_jit_settle(program, callable, looped, calling);
  bool any = false;
  for (uint32_t k = 0; k < n; k++) {
    const agc_function *f = &program->functions[k];
    bool on = mode == AGC_JIT_ON;
    const char *why = !on || callable[k] ? NULL : looped[k] ? "exits" : "none";
    /* With `on`, a function without a loop that may get code is entered only by native calls. */
    bool native = !why && on && !looped[k], entered = !why && !native;
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
  jit->calling = calling;
  jit->code = agc_alloc_atomic(agc_size_mul(n, sizeof *jit->code));
  jit->entries = agc_alloc_atomic(agc_size_mul(n, sizeof *jit->entries));
  jit->claimed = agc_alloc_atomic(agc_size_mul(n, sizeof *jit->claimed));
  jit->last = agc_alloc_atomic(agc_size_mul(n, sizeof *jit->last));
  jit->passes = agc_alloc_atomic(agc_size_mul(n, sizeof *jit->passes));
  jit->batch = agc_alloc(sizeof *jit->batch);
  memset(jit->batch, 0, sizeof *jit->batch);
  /* A mutex from the start: schedulers compile at once from their first turn. */
  jit->lock = agc_lock_new("jit");
  agc_lock_share(jit->lock);
  jit->page = agc_jit_mem_page();
  jit->cap = AGC_JIT_CODE_CAP;
  jit->chunk = jit->chunk_used = 0;
  jit->exits = agc_alloc_atomic(sizeof *jit->exits * AGC_OP_COUNT);
  for (uint32_t k = 0; k < n; k++) {
    atomic_init(&jit->code[k], NULL);
    atomic_init(&jit->entries[k], 0);
    atomic_init(&jit->claimed[k], false);
    atomic_init(&jit->last[k], UINT32_MAX);
    atomic_init(&jit->passes[k], 0);
  }
  for (uint32_t op = 0; op < AGC_OP_COUNT; op++) atomic_init(&jit->exits[op], 0);
  atomic_init(&jit->leaves, 0);
  atomic_init(&jit->blocks, 0);
  atomic_init(&jit->transitions, 0);
  atomic_init(&jit->turns, 0);
  atomic_init(&jit->live, false);
  atomic_init(&jit->spent, false);
  atomic_init(&jit->work, 0);
  jit->budget = AGC_JIT_BUDGET;
  atomic_init(&jit->arena, NULL);
  atomic_init(&jit->used, 0);
  return jit;
}

/* True for a turn drawn at random, one in AGC_JIT_SAMPLE on average (a power of two): a xorshift16 with the shifts 7,
   9, 8, whose period is all 65535 non-zero states, seeded with an odd number made of the scheduler's index. A counter
   would sample every 16th turn, and two tasks that take turns could then put every sample on the one that idles. */
static bool sampled(agc_vm *vm) {
  uint16_t x = vm->jit_sample ? vm->jit_sample : (uint16_t)(vm->index * 2 + 1);
  x ^= (uint16_t)(x << 7);
  x ^= (uint16_t)(x >> 9);
  x ^= (uint16_t)(x << 8);
  vm->jit_sample = x;
  return (x & (AGC_JIT_SAMPLE - 1)) == 0;
}

bool agc_jit_turn(agc_jit *jit, agc_vm *vm) {
  const agc_task *t = vm->task;
  /* The flag only picks the loop, and the jit copy loads each code pointer with acquire, so the acquire here (a plain
     load on x86-64) only keeps "live" meaning "some code is visible" on every scheduler. */
  bool jit_copy = atomic_load_explicit(&jit->live, memory_order_acquire);
  uint32_t n = t->frame_count, low = n > AGC_JIT_TOP_FRAMES ? n - AGC_JIT_TOP_FRAMES : 0;
  /* The sample: a per-scheduler draw, no shared write. */
  if (!jit_copy) jit_copy = sampled(vm);
  /* A deeper stack runs the jit copy, as every run did before: its frames below the top ones may be in a loop that
     gets hot, and walking all of them each turn would cost more than the plain loop saves. */
  if (!jit_copy) jit_copy = low > 0;
  for (uint32_t k = n; !jit_copy && k > low; k--) {
    const agc_frame *frame = &t->frames[k - 1];
    jit_copy = !frame->native && agc_jit_may_run(jit, frame->function);
  }
  if (jit_copy && AGC_TRACE_ON(jit->trace, AGC_TRACE_JIT))
    atomic_fetch_add_explicit(&jit->turns, 1, memory_order_relaxed);
  return jit_copy;
}

void agc_jit_count_exit(agc_jit *jit, uint32_t function, uint32_t pc) {
  uint32_t op = plain_op(jit->program->functions[function].code[pc].op);
  if (op < AGC_OP_COUNT) atomic_fetch_add_explicit(&jit->exits[op], 1, memory_order_relaxed);
}

void agc_jit_count_leaf(agc_jit *jit) { atomic_fetch_add_explicit(&jit->leaves, 1, memory_order_relaxed); }

void agc_jit_count_block(agc_jit *jit) { atomic_fetch_add_explicit(&jit->blocks, 1, memory_order_relaxed); }

void agc_jit_count_transition(agc_jit *jit) { atomic_fetch_add_explicit(&jit->transitions, 1, memory_order_relaxed); }

void agc_jit_report(agc_jit *jit) {
  for (uint32_t op = 0; op < AGC_OP_COUNT; op++) {
    uint64_t count = atomic_load_explicit(&jit->exits[op], memory_order_relaxed);
    if (count) AGC_TRACE(jit->trace, AGC_TRACE_JIT, "exit op=%s count=%" PRIu64, agc_opcode_name(op), count);
  }
  uint64_t leaves = atomic_load_explicit(&jit->leaves, memory_order_relaxed);
  if (leaves) AGC_TRACE(jit->trace, AGC_TRACE_JIT, "leaf count=%" PRIu64, leaves);
  uint64_t blocks = atomic_load_explicit(&jit->blocks, memory_order_relaxed);
  if (blocks) AGC_TRACE(jit->trace, AGC_TRACE_JIT, "block count=%" PRIu64, blocks);
  uint64_t transitions = atomic_load_explicit(&jit->transitions, memory_order_relaxed);
  if (transitions) AGC_TRACE(jit->trace, AGC_TRACE_JIT, "transition count=%" PRIu64, transitions);
  uint64_t turns = atomic_load_explicit(&jit->turns, memory_order_relaxed);
  if (turns) AGC_TRACE(jit->trace, AGC_TRACE_JIT, "turn count=%" PRIu64, turns);
}

#if AGC_LEAF_CHECK
/* Names the direct builtin and what it did that a direct call must not (a row marked direct by mistake). */
static _Noreturn __attribute__((noinline, cold)) void direct_broken(const agc_builtin *b, const char *what) {
  char detail[160];
  (void)snprintf(detail, sizeof detail, "builtin %s/%" PRIu32 " is marked direct but %s", b->name, b->arity, what);
  agc_internal_abort(detail);
}
#endif

/* B's call into *RESULT with its failure or exit caught: false when agc_fail or agc_exit jumped back here. Apart, so
   no local of the caller lives across the jump. */
static __attribute__((noinline)) bool caught(agc_vm *vm, const agc_builtin *b, agc_value *args, uint32_t span,
                                             agc_value *result) {
  agc_catch_buf here;
  vm->jit_catch = &here;
  if (AGC_CATCH(here)) return false;
  *result = b->fn(vm, args, span);
  vm->jit_catch = NULL;
  return true;
}

uint32_t agc_jit_call_builtin(agc_vm *vm, agc_value *args, const agc_builtin *b, uint64_t where) {
  agc_task *t = vm->task;
  uint32_t span = (uint32_t)(where >> 32);
  t->frames[t->frame_count - 1].pc = (uint32_t)where;
  uint64_t units = 0;
  if (b->cost == AGC_COST_SIZE)
    for (uint32_t k = 0; k < b->arity; k++) units += agc_value_units(args[k]);
#if AGC_LEAF_CHECK
  uint32_t frames = t->frame_count, depth = vm->sync_depth;
  bool retry = t->retry;
#endif
  agc_value result;
  if (!caught(vm, b, args, span, &result)) return AGC_JIT_EXIT_RAISE;
#if AGC_LEAF_CHECK
  if (t->parking || t->retry != retry) direct_broken(b, "parked");
  if (t->stepper) direct_broken(b, "started a stepper");
  if (t->frame_count != frames) direct_broken(b, "moved the frames");
  if (vm->sync_depth != depth) direct_broken(b, "left rt->sync taken");
#endif
  args[0] = result;
  if (b->cost == AGC_COST_SIZE) agc_charge(vm, units + agc_value_units(result));
  if (t->turn_cost) agc_turn_charge(vm);
  return vm->yield ? AGC_JIT_EXIT_YIELD : AGC_STATUS_OK;
}

uint32_t agc_jit_map_get(agc_vm *vm, agc_value *dst, const agc_value *map, const agc_value *key) {
  /* agc_key_hash takes only an Int or a String and fails on any other tag, so those leave before the lookup. */
  if (!agc_is(*map, AGC_T_MAP) || !(agc_is(*key, AGC_T_INT) || agc_is(*key, AGC_T_STRING)))
    return AGC_JIT_EXIT_INTERPRET;
  /* A String key charges its bytes. A miss gives the charge back, as the interpreter runs the instruction again and
     charges them itself; restoring turn_cost undoes the whole lookup, since agc_charge is its only side effect. */
  int64_t cost = vm->task->turn_cost;
  agc_value found;
  if (!agc_map_get(vm, agc_as_map(vm, *map), *key, &found)) {
    vm->task->turn_cost = cost;
    return AGC_JIT_EXIT_INTERPRET;
  }
  *dst = found;
  return AGC_STATUS_OK;
}

void agc_jit_list(agc_vm *vm, agc_value *dst, const agc_value *items, uint32_t count) {
  *dst = count ? agc_list_value(agc_list_from_array(items, count)) : vm->rt->empty_list;
}

void agc_jit_closure(agc_value *window, uint32_t function, uint32_t captures) {
  agc_fn *f = agc_new_fn(function, captures);
  for (uint32_t k = 0; k < captures; k++) f->captured[k] = window[k];
  window[0] = agc_fn_value(f);
}

void agc_jit_struct(agc_value *dst, const agc_value *fields, uint32_t type, uint32_t count) {
  agc_struct *st = agc_new_struct(type, count);
  for (uint32_t k = 0; k < count; k++) st->fields[k] = fields[k];
  *dst = agc_struct_value(st);
}

uint32_t agc_jit_struct_with(agc_vm *vm, agc_value *dst, const agc_value *window, const agc_update_def *u) {
  const agc_program *p = vm->rt->program;
  if (!agc_is(window[0], AGC_T_STRUCT)) return AGC_JIT_EXIT_INTERPRET;
  const agc_struct *old = agc_as_struct(vm, window[0]);
  if (old->type != u->type || old->n != p->structs[u->type].count) return AGC_JIT_EXIT_INTERPRET;
  agc_struct *st = agc_new_struct(old->type, old->n);
  memcpy(st->fields, old->fields, (size_t)old->n * sizeof(agc_value));
  for (uint32_t k = 0; k < u->count; k++) st->fields[u->fields[k]] = window[1 + k];
  /* The window is read in full before DST, which may be one of its registers, is written. */
  *dst = agc_struct_value(st);
  agc_charge_bytes(vm, (size_t)old->n * sizeof(agc_value));
  return agc_turn_charge(vm) ? AGC_JIT_EXIT_YIELD : AGC_STATUS_OK;
}

void agc_jit_enum(agc_value *dst, const agc_value *payload, const agc_variant_def *v, uint32_t variant) {
  if (v->arity == 0) {
    *dst = agc_enum_value(v->shared);
    return;
  }
  agc_enum *e = agc_new_enum(variant, v->arity);
  for (uint32_t k = 0; k < v->arity; k++) e->payload[k] = payload[k];
  *dst = agc_enum_value(e);
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
