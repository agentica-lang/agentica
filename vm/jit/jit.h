/*
 * The JIT's boundary (docs/future/22-jit.md §22): the interpreter compiles a function, enters its code and handles
 * the exit. The rest is private to vm/jit/ and the C tests: the emitter of each architecture and the code memory.
 * Core layer.
 */
#ifndef AGC_JIT_H
#define AGC_JIT_H

#include "../core.h"

/* --jit and AGENTICA_JIT: off, on (a function with a loop is compiled at its AGC_JIT_THRESHOLD-th entry once
   AGC_JIT_PASSES of its entries landed at or before the previous one, unless an innermost loop leaves compiled code
   for the interpreter more than once in AGC_JIT_SPACING instructions) and always
   (every function, at its first entry, for tests). A host without an emitter accepts every mode and runs everything
   in the interpreter. With `on`, a function without a loop gets code only for native calls, at its first CALL exit
   from compiled code when it calls a function, else at its AGC_JIT_CALLEE_THRESHOLD-th: one without calls runs at
   most its own few instructions per call, and a compile costs about as much as interpreting thousands of them, so
   one called only a few times from compiled code stays interpreted. */
typedef enum { AGC_JIT_OFF, AGC_JIT_ON, AGC_JIT_ALWAYS } agc_jit_mode;
#define AGC_JIT_THRESHOLD 100
#define AGC_JIT_PASSES 32
#define AGC_JIT_CALLEE_THRESHOLD 16
#define AGC_JIT_SPACING 16

/* Why compiled code stopped, besides a failure of agc_status (OVERFLOW, DIVISION_BY_ZERO, INDEX_OUT_OF_RANGE,
   WRONG_TAG), which the interpreter raises at the instruction at `pc` with agc_op_fail. STEP: the STEP at `pc` is the
   slow one; the interpreter runs it (a stop, a yield or a new batch of steps). COST: the instruction at `pc` charged
   turn cost, which the interpreter applies. INTERPRET: the interpreter runs the instruction at `pc` (one without a
   compiled boundary, or a slow path), then enters code again. CALL and RETURN: a call or return that compiled code
   could not make natively (the callee has no code, an array would grow, the call would fail, or the function was not
   called natively), whose shared frame handler run_compiled runs. RETURNED never reaches run_compiled: it is the
   answer of a natively called function's RETURN to its caller's code. An exit from a natively called function goes
   up through its callers' code unchanged, so run_compiled finds that function's frame on top. */
enum {
  AGC_JIT_EXIT_STEP = 16,
  AGC_JIT_EXIT_COST,
  AGC_JIT_EXIT_INTERPRET,
  AGC_JIT_EXIT_CALL,
  AGC_JIT_EXIT_RETURN,
  AGC_JIT_EXIT_RETURNED
};

/* An exit: 8 bytes, so both calling conventions return it in one register (rax), status in the low half. */
typedef struct {
  uint32_t status, pc;
} agc_jit_exit;

/* Compiled code of one function: runs from instruction `pc` with R the frame's registers and K the program's
   constants, and returns at the first exit. The machine code itself never fails, allocates directly, calls a builtin
   or grows an array: an opcode helper it calls may allocate, but never fails (no agc_fail, no longjmp), parks or
   moves a frame. A CALL of a function that has code pushes its frame in room the task already has and calls that
   code natively (at AGC_JIT_NATIVE_ENTRY), up to AGC_JIT_NATIVE_DEPTH calls deep; its RETURN pops it. */
typedef agc_jit_exit (*agc_jit_code)(agc_vm *vm, agc_value *R, const agc_value *K, uint32_t pc);

/* On a function that calls compiled code: clang's -fsanitize=function reads a type word before each indirect call
   target, which compiled code does not have. */
#if defined(__clang__)
#define AGC_JIT_CALLER __attribute__((no_sanitize("function")))
#else
#define AGC_JIT_CALLER
#endif

/* The JIT of a run. `skip[f]` is set once function f will not be compiled (by agc_jit_new for most), so the
   interpreter's reload tests one byte for it; `code[f]` is its code (NULL until compiled), published with a release
   store after its pages are sealed, so a scheduler that loads it with acquire sees finished code. Only the scheduler
   that sets `claimed[f]` (a compare-and-swap) compiles f, so no copy is ever made twice: another one that asks
   meanwhile interprets f until the code is published. `entries` are the entries counted in the `on` mode (the CALL
   exits, for a function without a loop), `last[f]` the pc of f's last entry, `passes[f]` its entries that landed at
   or before the one before, `arena` the current chunk of code memory (`chunk` bytes reserved, `chunk_used` of them
   taken), `used` the bytes taken in all chunks, `cap` the most it may take (AGC_JIT_CODE_CAP, or `used` once the
   memory failed), `page` the host's page size, and `batch` the code that waits for a seal (jit.c), all under
   `lock`; `exits[op]` the INTERPRET exits at each opcode that went back
   to the turn loop, `leaves` the leaf builtins that run_compiled called itself and `transitions` the CALL and RETURN
   exits that it ran, all counted only while the jit trace is on. `native_only[f]` is set when `on` gives a function
   without a loop code only for native calls: compiled at a CALL exit from compiled code (the first when
   `calling[f]`, set when f calls a function, else the AGC_JIT_CALLEE_THRESHOLD-th) and published at a seal, which
   clears its `skip`. The code lives until the process exits, like the program. */
typedef struct agc_jit {
  _Atomic bool *skip;
  _Atomic(agc_jit_code) *code;
  const agc_program *program;
  agc_jit_mode mode;
  const agc_trace *trace;
  _Atomic uint32_t *entries;
  _Atomic size_t used;
  _Atomic uint64_t *exits;
  _Atomic uint64_t leaves, transitions;
  _Atomic bool *native_only;
  _Atomic bool *claimed;
  const bool *calling;
  _Atomic uint32_t *last, *passes;
  _Atomic(uint8_t *) arena;
  struct agc_jit_batch *batch;
  agc_lock *lock;
  size_t page, cap, chunk, chunk_used;
} agc_jit;

/* The JIT of a run, or NULL for AGC_JIT_OFF, on a host without an emitter and when MODE compiles no function of
   PROGRAM (then the run has the interpreter of AGC_JIT_OFF). TRACE gets the jit category's lines. */
agc_jit *agc_jit_new(const agc_program *program, agc_jit_mode mode, const agc_trace *trace);
/* The code of FUNCTION, entered at instruction PC, compiled now if this entry makes it hot, or NULL to interpret it.
   Any scheduler may call it. */
agc_jit_code agc_jit_code_of(agc_jit *jit, uint32_t function, uint32_t pc);
/* False once FUNCTION stays interpreted: the test the interpreter makes before it asks agc_jit_code_of. */
static inline bool agc_jit_may_run(agc_jit *jit, uint32_t function) {
  return !atomic_load_explicit(&jit->skip[function], memory_order_relaxed);
}
/* The code of FUNCTION for the frame a CALL exit just pushed: its code, or, for a function without a loop that `on`
   compiles only to be called from compiled code, its code compiled now if this exit makes it hot; NULL to interpret
   it. It counts an entry only for such a function. */
agc_jit_code agc_jit_callee_code(agc_jit *jit, uint32_t function);
/* True when FUNCTION gets code only for native calls from compiled code (a function without a loop, with `on`): the
   interpreter enters that code only to resume a frame of it. */
static inline bool agc_jit_native_only(agc_jit *jit, uint32_t function) {
  return atomic_load_explicit(&jit->native_only[function], memory_order_relaxed);
}
/* Counts an INTERPRET exit at instruction PC of FUNCTION, when the jit trace is on (the exit's slow path). */
void agc_jit_count_exit(agc_jit *jit, uint32_t function, uint32_t pc);
/* Counts a leaf builtin that run_compiled called between two runs of compiled code, when the jit trace is on. */
void agc_jit_count_leaf(agc_jit *jit);
/* Counts a CALL or RETURN exit that run_compiled ran, when the jit trace is on. */
void agc_jit_count_transition(agc_jit *jit);
/* At the end of a run, the jit trace's `exit op=OP count=N` lines, one for each opcode that compiled code left to the
   turn loop at, `leaf count=N`, the leaf builtins called between two runs of compiled code, and `transition count=N`,
   the calls and returns that left compiled code (a native one does not). */
void agc_jit_report(agc_jit *jit);
/* "off", "on" or "always" in *MODE; false for any other word. */
bool agc_jit_mode_parse(const char *word, agc_jit_mode *mode);

/* Private to vm/jit/ and the C tests from here. */

/* The architecture that has an emitter: x86-64 (emit_x64.c). Elsewhere the JIT compiles nothing. */
#if defined(__x86_64__) || defined(_M_X64)
#define AGC_JIT_HOST 1
#else
#define AGC_JIT_HOST 0
#endif

/* The offset of the native entry in a function's code (after the 2-byte jump of the entry from C), and the most
   native calls nested on the C stack: about 80 bytes each. A deeper CALL exits, which unwinds them all. */
#define AGC_JIT_NATIVE_ENTRY 2
#define AGC_JIT_NATIVE_DEPTH 256

/* The most code memory a run takes, counted in bytes, and so the most one function takes; past it, functions stay
   interpreted. It is reserved in chunks as it fills, and each seal takes the next whole pages of a chunk, which the
   functions sealed together share. */
#define AGC_JIT_CODE_CAP ((size_t)64 * 1024 * 1024)

/* Exit words share the status half with agc_status, so every status is below the first exit. */
_Static_assert((int)AGC_STATUS_COUNT <= (int)AGC_JIT_EXIT_STEP, "an agc_status value overlaps the JIT's exits");

/* A 32-bit offset written once the function is laid out: to the code of instruction `value` (LABEL), or to the exit
   stub that returns the exit word `value` (EXIT), or the status in eax with the pc in the high half of `value`
   (EXIT_STATUS, after a helper call), or to the epilogue with rax as it is (EPILOGUE). */
typedef enum {
  AGC_JIT_PATCH_LABEL,
  AGC_JIT_PATCH_EXIT,
  AGC_JIT_PATCH_EXIT_STATUS,
  AGC_JIT_PATCH_EPILOGUE
} agc_jit_patch_kind;
typedef struct {
  uint32_t at;
  agc_jit_patch_kind kind;
  uint64_t value;
} agc_jit_patch;

/* The machine code of one function as it is written: `labels[pc]` is where instruction pc starts, `entry` the offset
   that the entry table's address goes to. `failed` is set when an operand does not fit the encoding or the code
   passes AGC_JIT_CODE_CAP; from then on nothing is written, and the function stays interpreted. The buffers are GC
   memory without pointers. */
typedef struct {
  uint8_t *code;
  size_t len, cap;
  uint32_t *labels, count, entry;
  agc_jit_patch *patches;
  size_t patch_count, patch_cap;
  bool failed;
} agc_emitter;

/* The byte of the host's code that fills a gap no code runs (before the entry table, between two functions sealed
   together): int3 on x86-64. */
#define AGC_EMIT_PAD 0xCC

/* The emitter of the host (emit_x64.c), one call for each kind of instruction. agc_emit_end lays out the epilogue,
   the exit stubs and the entry table, and returns the size of the finished code, or 0 when it failed. */
void agc_emit_begin(agc_emitter *e, uint32_t count);
void agc_emit_label(agc_emitter *e, uint32_t pc);
void agc_emit_move(agc_emitter *e, uint32_t a, uint32_t b);
void agc_emit_const(agc_emitter *e, uint32_t a, uint32_t k);
void agc_emit_step(agc_emitter *e, uint32_t n, uint32_t pc);
void agc_emit_int(agc_emitter *e, agc_opcode op, agc_instr in, uint32_t pc);
void agc_emit_equal(agc_emitter *e, agc_opcode op, agc_instr in, uint32_t pc);
void agc_emit_helper(agc_emitter *e, agc_opcode op, agc_instr in, uint32_t pc);
void agc_emit_read(agc_emitter *e, agc_opcode op, agc_instr in, uint32_t pc);
void agc_emit_jump(agc_emitter *e, uint32_t target);
void agc_emit_branch(agc_emitter *e, uint32_t a, bool when, uint32_t target, uint32_t pc);
void agc_emit_exit(agc_emitter *e, uint32_t status, uint32_t pc);
/* CALL with SLOT the address of the callee's entry in the code table and REGISTERS the callee's register count. */
void agc_emit_call(agc_emitter *e, agc_instr in, uint32_t pc, uint64_t slot, uint32_t registers);
void agc_emit_return(agc_emitter *e, uint32_t a, uint32_t pc);
size_t agc_emit_end(agc_emitter *e);

/* Code memory (mem_posix.c, mem_windows.c): a range of pages is reserved without access, then each part of it is
   opened writable, filled and sealed read and execute, once; never writable and executable at once, and never
   writable again. The icache is flushed at the seal. Sizes and addresses are whole pages of agc_jit_mem_page bytes;
   unmap releases a whole reservation. */
size_t agc_jit_mem_page(void);
void *agc_jit_mem_reserve(size_t size);
bool agc_jit_mem_open(void *pages, size_t size);
bool agc_jit_mem_seal(void *pages, size_t size);
void agc_jit_mem_unmap(void *pages, size_t size);

/* Settles the `on` decision of every function of PROGRAM: CALLABLE[f] stays true when f may get code, LOOPED[f] is
   set when f has a loop and CALLING[f] when it calls a function of the program. Returns the work it did
   (instructions read and call sites counted), which the C test bounds by the program's size. */
size_t agc_jit_settle(const agc_program *program, bool *callable, bool *looped, bool *calling);

#endif
