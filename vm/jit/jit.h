/*
 * The JIT's boundary (docs/future/22-jit.md §22): the interpreter compiles a function, enters its code and handles
 * the exit. The rest is private to vm/jit/ and the C tests: the emitter of each architecture and the code memory.
 * Core layer.
 */
#ifndef AGC_JIT_H
#define AGC_JIT_H

#include "../core.h"

/* --jit and AGENTICA_JIT: off, on (a function is compiled after AGC_JIT_THRESHOLD entries) and always (at its first
   entry, for tests). A host without an emitter accepts every mode and runs everything in the interpreter. */
typedef enum { AGC_JIT_OFF, AGC_JIT_ON, AGC_JIT_ALWAYS } agc_jit_mode;
#define AGC_JIT_THRESHOLD 100

/* Why compiled code stopped, besides a failure of agc_status (OVERFLOW, DIVISION_BY_ZERO, WRONG_TAG), which the
   interpreter raises at the instruction at `pc` with agc_op_fail. STEP: the STEP at `pc` is the slow one; the
   interpreter runs it (a stop, a yield or a new batch of steps). COST: the instruction at `pc` charged turn cost,
   which the interpreter applies. INTERPRET: the interpreter goes on at `pc` (RETURN). */
enum { AGC_JIT_EXIT_STEP = 16, AGC_JIT_EXIT_COST, AGC_JIT_EXIT_INTERPRET };

/* An exit: 8 bytes, so both calling conventions return it in one register (rax), status in the low half. */
typedef struct {
  uint32_t status, pc;
} agc_jit_exit;

/* Compiled code of one function: runs from instruction `pc` with R the frame's registers and K the program's
   constants, and returns at the first exit. It never fails, allocates, calls a builtin or moves a frame. */
typedef agc_jit_exit (*agc_jit_code)(agc_vm *vm, agc_value *R, const agc_value *K, uint32_t pc);

/* On a function that calls compiled code: clang's -fsanitize=function reads a type word before each indirect call
   target, which compiled code does not have. */
#if defined(__clang__)
#define AGC_JIT_CALLER __attribute__((no_sanitize("function")))
#else
#define AGC_JIT_CALLER
#endif

/* The JIT of a run. `skip[f]` is set once function f will not be compiled, so the interpreter's reload tests one
   byte for it; `code[f]` is its code (NULL until compiled), published with a release store after the pages are
   sealed, so a scheduler that loads it with acquire sees finished code; two schedulers that compile one function at
   once keep the first and unmap the second. `entries` are the entries counted in the `on` mode, `used` the code
   memory taken. The code lives until the process exits, like the program. */
typedef struct agc_jit {
  _Atomic bool *skip;
  _Atomic(agc_jit_code) *code;
  const agc_program *program;
  agc_jit_mode mode;
  const agc_trace *trace;
  _Atomic uint32_t *entries;
  _Atomic size_t used;
} agc_jit;

/* The JIT of a run, or NULL for AGC_JIT_OFF and on a host without an emitter. TRACE gets the jit category's lines. */
agc_jit *agc_jit_new(const agc_program *program, agc_jit_mode mode, const agc_trace *trace);
/* The code of FUNCTION, compiled now if this entry makes it hot, or NULL to interpret it. Any scheduler may call it. */
agc_jit_code agc_jit_code_of(agc_jit *jit, uint32_t function);
/* False once FUNCTION stays interpreted: the test the interpreter makes before it asks agc_jit_code_of. */
static inline bool agc_jit_may_run(agc_jit *jit, uint32_t function) {
  return !atomic_load_explicit(&jit->skip[function], memory_order_relaxed);
}
/* "off", "on" or "always" in *MODE; false for any other word. */
bool agc_jit_mode_parse(const char *word, agc_jit_mode *mode);

/* Private to vm/jit/ and the C tests from here. */

/* The architecture that has an emitter: x86-64 (emit_x64.c). Elsewhere the JIT compiles nothing. */
#if defined(__x86_64__) || defined(_M_X64)
#define AGC_JIT_HOST 1
#else
#define AGC_JIT_HOST 0
#endif

/* The most code memory a run takes, counted in 4 KiB pages, and so the most one function takes; past it, functions
   stay interpreted. */
#define AGC_JIT_CODE_CAP ((size_t)64 * 1024 * 1024)

/* Exit words share the status half with agc_status, so every status is below the first exit. */
_Static_assert((int)AGC_STATUS_COUNT <= (int)AGC_JIT_EXIT_STEP, "an agc_status value overlaps the JIT's exits");

/* A 32-bit offset written once the function is laid out: to the code of instruction `value` (LABEL), or to the exit
   stub that returns the exit word `value` (EXIT), or the status in eax with the pc in the high half of `value`
   (EXIT_STATUS, after a helper call). */
typedef enum { AGC_JIT_PATCH_LABEL, AGC_JIT_PATCH_EXIT, AGC_JIT_PATCH_EXIT_STATUS } agc_jit_patch_kind;
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

/* The emitter of the host (emit_x64.c), one call for each kind of instruction. agc_emit_end lays out the epilogue,
   the exit stubs and the entry table, and returns the size of the finished code, or 0 when it failed. */
void agc_emit_begin(agc_emitter *e, uint32_t count);
void agc_emit_label(agc_emitter *e, uint32_t pc);
void agc_emit_move(agc_emitter *e, uint32_t a, uint32_t b);
void agc_emit_const(agc_emitter *e, uint32_t a, uint32_t k);
void agc_emit_step(agc_emitter *e, uint32_t n, uint32_t pc);
void agc_emit_int(agc_emitter *e, agc_opcode op, agc_instr in, uint32_t pc);
void agc_emit_equal(agc_emitter *e, agc_opcode op, agc_instr in, uint32_t pc);
void agc_emit_jump(agc_emitter *e, uint32_t target);
void agc_emit_branch(agc_emitter *e, uint32_t a, bool when, uint32_t target, uint32_t pc);
void agc_emit_exit(agc_emitter *e, uint32_t status, uint32_t pc);
size_t agc_emit_end(agc_emitter *e);

/* Code memory (mem_posix.c, mem_windows.c): pages are mapped writable, filled, then sealed read and execute; never
   writable and executable at once. The icache is flushed at the seal. */
void *agc_jit_mem_map(size_t size);
bool agc_jit_mem_seal(void *pages, size_t size);
void agc_jit_mem_unmap(void *pages, size_t size);

#endif
