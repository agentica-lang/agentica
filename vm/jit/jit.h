/*
 * The JIT's boundary (docs/vm/05-values-execution-builtins.md §6.4): the interpreter compiles a function, enters its
 * code and handles the exit. The rest is private to vm/jit/, the C tests and the libFuzzer entry point: the emitter of
 * each architecture and the code memory. Core layer.
 */
#ifndef AGC_JIT_H
#define AGC_JIT_H

#include "../core.h"

/* --jit and AGENTICA_JIT: off, on (a function with a loop, a backward jump or a TAIL_CALL of itself with at most
   AGC_JIT_TAIL_PARAMS arguments, is compiled at its AGC_JIT_THRESHOLD-th entry once AGC_JIT_PASSES of its entries
   landed at or before the previous one, unless an innermost loop leaves compiled code for the interpreter more than
   once in AGC_JIT_SPACING instructions, where a builtin that may park counts AGC_JIT_PARK_WEIGHT times) and always
   (every function, at its first entry, for tests). A host without an emitter accepts every mode and runs everything in
   the interpreter. With `on`, a function without a loop gets code only for native calls, at its first CALL, TAIL_CALL
   or CALL_VALUE exit from compiled code when it calls a function (or a function value), else at its
   AGC_JIT_CALLEE_THRESHOLD-th: one without calls runs at most its own few instructions per call, and a compile costs
   about as much as interpreting thousands of them, so one called only a few times from compiled code stays
   interpreted. */
typedef enum { AGC_JIT_OFF, AGC_JIT_ON, AGC_JIT_ALWAYS } agc_jit_mode;
#define AGC_JIT_THRESHOLD 100
#define AGC_JIT_PASSES 32
#define AGC_JIT_CALLEE_THRESHOLD 16
#define AGC_JIT_SPACING 16
/* The trips out that `on` counts for a builtin that may park (agc_jit_parking: channels, task waits, sleeps, stdin,
   files, paths, processes, sockets), which ends the turn when it waits. A task woken from a channel, a task or a
   timer enters the code again only to leave it at the same call, which it retries. Measured with longer loop bodies
   of benchmarks/programs/channel-pingpong.agc, a loop with two such calls broke even at 64 to 96 instructions, where
   a loop with one plain exit breaks even at about 19: such a call costs about three plain exits. An I/O job's call is
   not retried, but its wait costs far more than any trip, so a loop that waits on I/O gains little from code. */
#define AGC_JIT_PARK_WEIGHT 3

/* Why compiled code stopped, besides a failure of agc_status (OVERFLOW, DIVISION_BY_ZERO, INDEX_OUT_OF_RANGE,
   WRONG_TAG), which the interpreter raises at the instruction at `pc` with agc_op_fail. STEP: the STEP at `pc` is the
   slow one; the interpreter runs it (a stop, a yield or a new batch of steps). COST: the instruction at `pc` charged
   turn cost, which the interpreter applies. INTERPRET: the interpreter runs the instruction at `pc` (one without a
   compiled boundary, or a slow path), then enters code again. CALL and RETURN: a call or return that compiled code
   could not make natively (the callee has no code, an array would grow, the call would fail, or the function was not
   called natively), whose shared frame handler run_compiled runs; TAIL_CALL: a tail call that compiled code could not
   make natively (the callee has no code, more than AGC_JIT_TAIL_PARAMS arguments, or registers that would grow the
   file), whose frame replacement (replace_frame) run_compiled runs, as the interpreter does; CALL_VALUE: a call of a
   function value that compiled code could not make natively (agc_jit_call_value said no), whose frame push run_compiled
   runs with the interpreter's call_value (agc_jit_call_value_exit), failures included. RETURNED never reaches
   run_compiled: it is the answer of a natively called function's RETURN to its caller's code. YIELD and RAISE come from
   a builtin that compiled code called (agc_jit_call_builtin): it returned and the turn ends, or it failed or exited,
   and run_compiled jumps to the turn's target. An exit from a natively called function goes up through its callers'
   code unchanged, so run_compiled finds that function's frame on top. */
enum {
  AGC_JIT_EXIT_STEP = 16,
  AGC_JIT_EXIT_COST,
  AGC_JIT_EXIT_INTERPRET,
  AGC_JIT_EXIT_CALL,
  AGC_JIT_EXIT_RETURN,
  AGC_JIT_EXIT_RETURNED,
  AGC_JIT_EXIT_YIELD,
  AGC_JIT_EXIT_RAISE,
  AGC_JIT_EXIT_TAIL_CALL,
  AGC_JIT_EXIT_CALL_VALUE
};

/* An exit: 8 bytes, so both calling conventions return it in one register (rax), status in the low half. */
typedef struct {
  uint32_t status, pc;
} agc_jit_exit;

/* Compiled code of one function: runs from instruction `pc` with R the frame's registers and K the program's constants,
   and returns at the first exit. The machine code itself never fails, allocates directly or grows an array: an opcode
   helper it calls may allocate, but never fails (no agc_fail, no longjmp), parks or moves a frame, and it calls a
   builtin only through agc_jit_call_builtin or agc_jit_call_leaf, which catch its failure, or through
   agc_jit_call_plain, the one call with no catch, only for a row of plain_leaves (jit.c) once its checks passed. A
   CALL of a function that has code, and a CALL_VALUE of a function value whose function has code (agc_jit_call_value),
   push its frame in room the task already has and call that code natively (at AGC_JIT_NATIVE_ENTRY), up to
   AGC_JIT_NATIVE_DEPTH calls deep; its RETURN pops it. A TAIL_CALL of a function that has code replaces the top frame
   in place, sets its tail flag and jumps to that code (at AGC_JIT_TAIL_ENTRY), or to instruction 0 for a call of
   itself, so the code that runs may belong to another function than the one entered: after an exit, run_compiled reads
   the top frame again when the frame count changed or the tail flag is set. */
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
   `lock`; `exits[op]` the INTERPRET exits at each opcode that went back to the turn loop, `leaves` the leaf builtins
   that run_compiled called itself, `blocks` the block calls (`map`, `filter`, `times` and the other rows with a native
   kind) that it started itself, `transitions` the CALL, TAIL_CALL, CALL_VALUE and RETURN exits that it ran, `tails`
   the TAIL_CALL exits and `tails_compiled` those whose callee had code (agc_jit_count_tail), all counted only while
   the jit trace is on. `native_only[f]` is set when `on` gives a function without a loop code only
   for native calls and block calls: compiled at a CALL, TAIL_CALL or CALL_VALUE exit from compiled code (the first
   when `calling[f]`, set when f calls, tail-calls or calls a function value, else the AGC_JIT_CALLEE_THRESHOLD-th) or
   at the first block call that compiled code starts with it, and published at a seal, which clears its `skip`.
   `live` is set by the first code published (agc_jit_turn), and `turns` counts the turns that ran the jit copy of the
   turn loop while the jit trace is on. `hot_entries`, `hot_passes` and `hot_calls` are the thresholds of `on`
   (AGC_JIT_THRESHOLD, AGC_JIT_PASSES and AGC_JIT_CALLEE_THRESHOLD, all at least 1), which only agc_fuzz_one lowers,
   so that a mutant's 10,000 steps reach them. The code lives until the process exits, like the program. `work` is
   the compile budget taken, at most `budget` (AGC_JIT_BUDGET; a C test or AGENTICA_VM_TEST_JIT_BUDGET sets less), and
   `spent` is set once a compile did not fit the budget or the code memory: from then on nothing is compiled
   (jit.c). `sample_bits` is the log2 of the sampling interval of agc_jit_turn, `sample_misses` the sampled turns in a
   row before which no entry was counted, and `counted` is set by an entry that `on` counted since the last sampled
   turn. `seal` is agc_jit_mem_seal, which a C test replaces with one that fails, and `sync_cores` is
   agc_jit_mem_sync_cores when the process registered for it, else NULL (agc_jit_use_sync). They come last, so the
   fields the interpreter reads keep their offsets. */
typedef struct agc_jit {
  _Atomic bool *skip;
  _Atomic(agc_jit_code) *code;
  const agc_program *program;
  agc_jit_mode mode;
  const agc_trace *trace;
  _Atomic uint32_t *entries;
  _Atomic size_t used;
  _Atomic uint64_t *exits;
  _Atomic uint64_t leaves, blocks, transitions, turns;
  _Atomic bool live;
  _Atomic bool *native_only;
  _Atomic bool *claimed;
  const bool *calling;
  _Atomic uint32_t *last, *passes;
  _Atomic(uint8_t *) arena;
  struct agc_jit_batch *batch;
  agc_lock *lock;
  size_t page, cap, chunk, chunk_used;
  uint32_t hot_entries, hot_passes, hot_calls;
  _Atomic uint64_t work;
  uint64_t budget;
  _Atomic bool spent;
  _Atomic uint64_t tails, tails_compiled;
  _Atomic uint32_t sample_bits, sample_misses;
  _Atomic bool counted;
  bool (*seal)(void *pages, size_t size);
  bool (*sync_cores)(void);
} agc_jit;

/* The JIT of a run, or NULL for AGC_JIT_OFF, on a host without an emitter and when MODE compiles no function of
   PROGRAM (then the run has the interpreter of AGC_JIT_OFF). TRACE gets the jit category's lines. */
agc_jit *agc_jit_new(const agc_program *program, agc_jit_mode mode, const agc_trace *trace);
/* Decides, before anything is compiled, how arm64 code that one thread seals becomes safe to run on the others: when
   REGISTER_SYNC (agc_jit_mem_sync_register) succeeds, each seal runs SYNC_CORES and native calls have no isb; else
   each native call runs isb before it branches. agc_jit_new calls it once; a C test calls it again with stubs. */
void agc_jit_use_sync(agc_jit *jit, bool (*register_sync)(void), bool (*sync_cores)(void));
/* The code of FUNCTION, entered at instruction PC, compiled now if this entry makes it hot, or NULL to interpret it.
   Any scheduler may call it. */
agc_jit_code agc_jit_code_of(agc_jit *jit, uint32_t function, uint32_t pc);
/* False once FUNCTION stays interpreted: the test the interpreter makes before it asks agc_jit_code_of. */
static inline bool agc_jit_may_run(agc_jit *jit, uint32_t function) {
  return !atomic_load_explicit(&jit->skip[function], memory_order_relaxed);
}
/* True when the turn VM is about to run for its task runs the jit copy of the turn loop; false, the plain copy, the
   code of --jit off. Every turn does once some code is published. Before that, the entries of `on` are counted only in
   the jit copy, so a turn runs it when one of the task's AGC_JIT_TOP_FRAMES top frames is of a function the reload may
   enter (or the task has more frames than that), which catches a long loop the turn starts in, and a turn drawn at
   random, one in AGC_JIT_SAMPLE on average, on each scheduler does in any case, which counts a function that runs only
   inside turns (a callee that returns before the turn ends, the work of a task that parks or ends within its turn).
   The draw is random so that tasks taking turns in a fixed rhythm (a ping-pong) cannot all fall between samples. A
   run of sampled turns with no entry counted doubles the interval, up to one in AGC_JIT_SAMPLE_MAX, and one after an
   entry was counted sets it back to AGC_JIT_SAMPLE: the jit copy interprets slower than the plain copy (up to 1.4
   times, benchmarks/programs/logger-disabled.agc), so a run whose functions that may get code never run pays that in
   few turns. So a run whose functions that may get code run seldom or never keeps the plain loop for nearly every
   turn, without a test of the JIT inside it. */
#define AGC_JIT_TOP_FRAMES 64
#define AGC_JIT_SAMPLE 16
#define AGC_JIT_SAMPLE_MAX 256
bool agc_jit_turn(agc_jit *jit, agc_vm *vm);
/* The code of FUNCTION for the frame a CALL, TAIL_CALL or CALL_VALUE exit just made (BLOCK false), or for the block a
   block call started from compiled code just called (BLOCK set): its code, or, for a function without a loop that
   `on` compiles only to be called from compiled code, its code compiled now if this exit makes it hot; NULL to
   interpret it. It counts an entry only for such a function. A block is hot at once, as a function that calls is:
   the block call calls it for each item. */
agc_jit_code agc_jit_callee_code(agc_jit *jit, uint32_t function, bool block);
/* True when FUNCTION gets code only for native calls and block calls from compiled code (a function without a loop,
   with `on`): the interpreter enters that code only to resume a frame of it, or at its first instruction when a native
   frame sits below that frame (a block call; run_compiled). */
static inline bool agc_jit_native_only(agc_jit *jit, uint32_t function) {
  return atomic_load_explicit(&jit->native_only[function], memory_order_relaxed);
}
/* The CALL_VALUE exit at instruction OUT.pc of F, whose frame (at BASE) is on top: the interpreter's CALL_VALUE
   (agc_task_call), which pushes the frame of the function value in R[a] or fails as there. Counts the transition and
   returns the callee. */
uint32_t agc_jit_call_value_exit(agc_vm *vm, agc_jit *jit, const agc_function *f, agc_jit_exit out, uint32_t base);
/* Counts an INTERPRET exit at instruction PC of FUNCTION, when the jit trace is on (the exit's slow path). */
void agc_jit_count_exit(agc_jit *jit, uint32_t function, uint32_t pc);
/* Counts a leaf builtin that run_compiled called between two runs of compiled code, when the jit trace is on: a leaf
   at native depth 0, or a row of plain_leaves whose check failed (else compiled code calls it itself). */
void agc_jit_count_leaf(agc_jit *jit);
/* Counts a block call (a builtin row with a native kind) that run_compiled started, when the jit trace is on. */
void agc_jit_count_block(agc_jit *jit);
/* Counts a CALL, TAIL_CALL, CALL_VALUE or RETURN exit that run_compiled ran, when the jit trace is on. */
void agc_jit_count_transition(agc_jit *jit);
/* Counts a TAIL_CALL exit in `tails`, and in `tails_compiled` when the callee's code slot SLOT holds code (the register
   file had to grow, or it takes more than AGC_JIT_TAIL_PARAMS arguments). Compiled code calls it before the exit, and
   only code compiled while the jit trace is on (agc_emit_tail_call). */
void agc_jit_count_tail(agc_jit *jit, _Atomic(agc_jit_code) *slot);
/* At the end of a run, the jit trace's `exit op=OP count=N` lines, one for each opcode that compiled code left to the
   turn loop at, `leaf count=N`, the leaf builtins called between two runs of compiled code (at native depth 0, or a
   plain leaf whose check failed), `block count=N`, the block calls started there, `transition count=N`, the
   calls, tail calls and returns that left compiled code (a native call, tail call or return does not), `transition
   op=tail-call count=N compiled=M`, the tail calls among them and those of a callee that had code, and `turn
   count=N`, the turns that ran the jit copy of the turn loop. */
void agc_jit_report(agc_jit *jit);
/* The CALL_BUILTIN of a row marked direct (agc_builtin.direct) in compiled code, as the interpreter's generic tail
   runs it: ARGS is the window R + a, WHERE the instruction's span in the high half and its pc + 1 in the low half,
   which becomes the top frame's pc first (the stack trace and the error's span read it). It charges the cost of an
   AGC_COST_SIZE row and applies the task's turn cost. It answers AGC_STATUS_OK, the result in ARGS[0], for the code
   to go on; AGC_JIT_EXIT_YIELD when the call ended the turn (the result written); AGC_JIT_EXIT_RAISE when the builtin
   failed or exited: agc_fail recorded the failure and the stack and jumped to vm->jit_catch, here, so no longjmp
   crosses compiled code, and run_compiled hands it on. The call either completes or raises, as in the interpreter;
   a direct row never parks, starts a stepper or a native frame, or moves the frames, so nothing is left half done. */
uint32_t agc_jit_call_builtin(agc_vm *vm, agc_value *args, const agc_builtin *b, uint64_t where);
/* The CALL_BUILTIN of a leaf row (agc_builtin.leaf) in compiled code, as the interpreter's call_leaf runs it, with
   ARGS and WHERE as for agc_jit_call_builtin. A leaf charges no cost, counts no step and never ends the turn, so it
   answers AGC_STATUS_OK, the result in ARGS[0], or AGC_JIT_EXIT_RAISE when it failed (caught as above). Compiled
   code calls it only below a native call, which then stays on the C stack; at native depth 0 the leaf takes the
   INTERPRET exit, which unwinds nothing and costs less than the catch. A row that agc_jit_plain_of knows goes
   through agc_jit_call_plain instead. */
uint32_t agc_jit_call_leaf(agc_vm *vm, agc_value *args, const agc_builtin *b, uint64_t where);
/* What compiled code checks before it calls a row of plain_leaves (jit.c) with agc_jit_call_plain: the tag of each
   argument (AGC_T_VOID: any), and with ONE_CHAR that the first argument, a String, has exactly one character. */
typedef struct {
  uint8_t tags[2];
  bool one_char;
} agc_jit_plain;
/* The checks of B, or NULL when B is not one of the leaf rows that cannot fail once those checks pass (plain_leaves
   in jit.c). */
const agc_jit_plain *agc_jit_plain_of(const agc_builtin *b);
/* The CALL_BUILTIN of such a row in compiled code, once its checks passed: a plain call that writes ARGS[0], with no
   catch, as nothing can fail. WHERE is as for agc_jit_call_builtin; only the checked builds read it, which call
   through agc_jit_call_leaf and abort if the row failed. */
void agc_jit_call_plain(agc_vm *vm, agc_value *args, const agc_builtin *b, uint64_t where);
/* MAP_GET in compiled code, as the interpreter's case runs it: *DST = the value of *KEY in *MAP, and AGC_STATUS_OK.
   A missing key, or a wrong tag (hand-made bytecode), answers AGC_JIT_EXIT_INTERPRET with DST and the turn cost left
   alone, so the interpreter runs the instruction and fails as it does. A String key charges its bytes to the task's
   turn cost, which compiled code then leaves to apply, as after EQ. It never fails, allocates or parks. */
uint32_t agc_jit_map_get(agc_vm *vm, agc_value *dst, const agc_value *map, const agc_value *key);
/* LIST in compiled code, as the interpreter's case: *DST = a new List of the COUNT values at ITEMS (the window the
   loader checked), or the run's empty List. It may allocate; it charges nothing and never fails or parks. */
void agc_jit_list(agc_vm *vm, agc_value *dst, const agc_value *items, uint32_t count);
/* CLOSURE in compiled code, as the interpreter's case: WINDOW[0] = a new function value of FUNCTION that holds the
   CAPTURES values at WINDOW (the window the loader checked). It allocates; it charges nothing and never fails or
   parks. */
void agc_jit_closure(agc_value *window, uint32_t function, uint32_t captures);
/* STRUCT in compiled code, as the interpreter's case: *DST = a new struct of TYPE that holds the COUNT values at FIELDS
   (the window the loader checked). It allocates; it charges nothing and never fails or parks. */
void agc_jit_struct(agc_value *dst, const agc_value *fields, uint32_t type, uint32_t count);
/* ENUM in compiled code, as the interpreter's case: *DST = the shared value of V, the definition of VARIANT, when it
   has no payload, else a new one that holds the V->arity values at PAYLOAD (the window the loader checked). It may
   allocate; it charges nothing and never fails or parks. */
void agc_jit_enum(agc_value *dst, const agc_value *payload, const agc_variant_def *v, uint32_t variant);
/* STRUCT_WITH in compiled code, as the interpreter's case: *DST = a copy of the struct in WINDOW[0] with the fields
   of U set to WINDOW[1..] (the window the loader checked). The copy charges its size and applies the task's turn
   cost, as the interpreter does after it: AGC_STATUS_OK for the code to go on, or AGC_JIT_EXIT_YIELD when that ended
   the turn (the result written), as agc_jit_call_builtin answers; a struct of 4 or more fields charges at each copy,
   so a COST exit would leave the code at every update. A receiver that is not a struct of U's type with its declared
   field count answers AGC_JIT_EXIT_INTERPRET with DST and the turn cost left alone, so the interpreter runs the
   instruction and fails as it does. It allocates; it never fails or parks. */
uint32_t agc_jit_struct_with(agc_vm *vm, agc_value *dst, const agc_value *window, const agc_update_def *u);
/* CALL_VALUE in compiled code, the first half of a native call of a function value: when WINDOW[0] is a function
   value whose function has code and takes ARGC arguments and its captures (the checks of call_value), and the task
   has room for its frame, its registers and one more depth without growing an array or failing, it pushes the frame
   as call_value does (base at WINDOW + 1, the result to WINDOW[0], the captures after the arguments), with the
   caller's pc after instruction PC, and returns that code, which the caller's code then calls at its native entry.
   Otherwise it changes nothing and returns NULL, and the code takes the CALL_VALUE exit, where call_value pushes the
   frame or fails as in the interpreter. It never fails, allocates or parks. */
agc_jit_code agc_jit_call_value(agc_vm *vm, agc_value *window, uint32_t argc, uint32_t pc);
/* RETURN of *RESULT in compiled code that no native call runs (vm/interp.c): the return of a block to the block call
   that called it (`map`, `filter`, `times` and the other rows with a native kind) when that call goes on with
   another call of the same function. It does what the interpreter's RETURN and the native frame do (the block's value
   taken, the step or turn cost of a call charged, which may end the turn), but the frame stays and starts over at
   instruction 0 with the next arguments. It answers the frame's registers, for the code to go on at instruction 0
   (or to take the YIELD exit at AGC_JIT_PC_RESTART when the turn ended). Any other RETURN (no native frame below, a
   stepper, the last item, a value that ends the call or that it would fail on, a slow step, a function value of
   another function, a frame that a native tail call reached) answers NULL with nothing changed, and the code takes
   the RETURN exit. It never fails or parks; it may allocate. */
agc_value *agc_jit_block_return(agc_vm *vm, const agc_value *result);
/* The pc of an exit taken by a frame that starts over at instruction 0 (agc_jit_block_return): run_compiled sets the
   top frame's pc to the exit's pc + 1, which wraps to 0. */
#define AGC_JIT_PC_RESTART UINT32_MAX
/* "off", "on" or "always" in *MODE; false for any other word. */
bool agc_jit_mode_parse(const char *word, agc_jit_mode *mode);

/* Private to vm/jit/, the C tests and the libFuzzer entry point (vm/fuzz_libfuzzer.c) from here. */

/* The architectures that have an emitter: x86-64 (emit_x64.c), and little-endian arm64 on Linux and macOS
   (emit_a64.c, which writes its words little-endian). Elsewhere (Windows on arm64, big-endian arm64, 32-bit machines)
   the JIT compiles nothing. */
#if defined(__x86_64__) || defined(_M_X64)
#define AGC_JIT_HOST 1
#elif defined(__aarch64__) && defined(__AARCH64EL__) && !defined(_WIN32)
#define AGC_JIT_HOST 1
#else
#define AGC_JIT_HOST 0
#endif

/* The offsets of the tail entry and of the native entry in a function's code: on x86-64 after the 2-byte jump of the
   entry from C and the 5-byte jump of the tail entry, on arm64 after one branch each. And the most native calls nested
   on the C stack: about 80 bytes each. A deeper CALL exits, which unwinds them all; a native TAIL_CALL nests
   nothing. */
#if defined(__aarch64__)
#define AGC_JIT_TAIL_ENTRY 4
#define AGC_JIT_NATIVE_ENTRY 8
#else
#define AGC_JIT_TAIL_ENTRY 2
#define AGC_JIT_NATIVE_ENTRY 7
#endif
#define AGC_JIT_NATIVE_DEPTH 256

/* Both emitters' native CALL writes a frame as four dwords, a byte and a qword at these offsets, and indexes the
   frames by a shift of 5; it reads frame_count, frame_capacity and depth as dwords and reg_capacity as a qword. */
#if AGC_JIT_HOST
#define AGC_JIT_FIELD_SIZE(type, name) sizeof(((type *)0)->name)
_Static_assert(sizeof(agc_frame) == 32, "the native CALL indexes frames by a shift of 5");
_Static_assert(offsetof(agc_frame, function) == 0 && offsetof(agc_frame, pc) == 4 && offsetof(agc_frame, base) == 8 &&
                 offsetof(agc_frame, ret) == 12 && offsetof(agc_frame, tail) == 16 &&
                 offsetof(agc_frame, native) == 24,
               "the native CALL writes the frame at these offsets");
_Static_assert(AGC_JIT_FIELD_SIZE(agc_frame, pc) == 4 && AGC_JIT_FIELD_SIZE(agc_frame, base) == 4 &&
                 AGC_JIT_FIELD_SIZE(agc_frame, ret) == 4 && AGC_JIT_FIELD_SIZE(agc_frame, function) == 4 &&
                 AGC_JIT_FIELD_SIZE(agc_frame, tail) == 1 && sizeof(agc_native *) == 8,
               "the native CALL writes the frame fields with these sizes");
_Static_assert(AGC_JIT_FIELD_SIZE(agc_task, frame_count) == 4 && AGC_JIT_FIELD_SIZE(agc_task, frame_capacity) == 4 &&
                 AGC_JIT_FIELD_SIZE(agc_task, depth) == 4 && AGC_JIT_FIELD_SIZE(agc_task, reg_capacity) == 8,
               "the native CALL reads the task's counts with these sizes");
#endif

/* Before a thread runs compiled code, which another thread may have written and sealed: on arm64 the seal's cache
   maintenance reaches every core, but a core may still hold instructions it fetched before, so the thread that runs
   the code synchronizes its context first (isb). Nothing on x86-64, whose instruction fetch is coherent. */
static inline void agc_jit_sync(void) {
#if defined(__aarch64__)
  __asm__ __volatile__("isb" : : : "memory");
#endif
}

/* The most arguments of a native TAIL_CALL: its code moves each one, so a callee with more (the loader allows 65,534)
   takes the TAIL_CALL exit instead, and the code of one TAIL_CALL stays small, as the compile budget counts it as one
   instruction. */
#define AGC_JIT_TAIL_PARAMS 32

/* The most code memory a run takes, counted in bytes, and so the most one function takes; past it, functions stay
   interpreted. It is reserved in chunks as it fills, and each seal takes the next whole pages of a chunk, which the
   functions sealed together share. */
#define AGC_JIT_CODE_CAP ((size_t)64 * 1024 * 1024)

/* The compile budget of a run, so that no program pays an unbounded compile cost (thousands of hot functions, say):
   each compile takes the function's instructions plus AGC_JIT_COMPILE_BASE units of work before it walks them (a walk
   costs about 1.5 us an instruction on x86-64, and the emitter's set-up and a seal about 30 us), and the code takes
   bytes of AGC_JIT_CODE_CAP. The first compile that fits neither stops compiling for the rest of the run: every
   function not compiled yet stays interpreted, and the jit trace says `budget`. A unit is not a time, so the same
   program compiles the same functions on every host. The front end's self-compile takes about 120000 units with
   `always`, 32000 with `on`. */
#define AGC_JIT_BUDGET ((uint64_t)1000000)
#define AGC_JIT_COMPILE_BASE 32

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
   passes AGC_JIT_CODE_CAP; from then on nothing is written, and the function stays interpreted. `call_isb` (true
   unless the JIT's seals synchronize every core, agc_jit_use_sync) makes the arm64 emitter put isb before the branch
   of a native call. The buffers are GC memory without pointers. */
typedef struct {
  uint8_t *code;
  size_t len, cap;
  uint32_t *labels, count, entry;
  agc_jit_patch *patches;
  size_t patch_count, patch_cap;
  bool failed, call_isb;
} agc_emitter;

/* The byte of the host's code that fills a gap no code runs (before the entry table, between two functions sealed
   together): int3 on x86-64; on arm64 four of them make udf #0, which is always undefined. */
#if defined(__aarch64__)
#define AGC_EMIT_PAD 0x00
#else
#define AGC_EMIT_PAD 0xCC
#endif

/* What the two emitters share (jit.c). agc_emit_start empties E for a function of COUNT instructions;
   agc_emit_patch records an offset to write once the function is laid out. agc_emit_patches, in agc_emit_end once
   the epilogue is written, links every patch with LINK (the jump at AT to TO): to its label, to the epilogue, or to
   the exit stub of its run of patches with the same exit word, which STUB lays out at the end of the code first. It
   is false on a label past the function. */
typedef void (*agc_emit_stub)(agc_emitter *e, agc_jit_patch p, size_t epilogue);
typedef void (*agc_emit_link)(agc_emitter *e, size_t at, size_t to);
void agc_emit_start(agc_emitter *e, uint32_t count);
void agc_emit_patch(agc_emitter *e, size_t at, agc_jit_patch_kind kind, uint64_t value);
bool agc_emit_patches(agc_emitter *e, size_t epilogue, agc_emit_stub stub, agc_emit_link link);
/* The exit word of STATUS at PC, as compiled code returns it in one register. */
static inline uint64_t agc_emit_exit_word(uint32_t status, uint32_t pc) { return ((uint64_t)pc << 32) | status; }

/* The emitter of the host (emit_x64.c or emit_a64.c), one call for each kind of instruction. agc_emit_end lays out
   the epilogue, the exit stubs and the entry table, and returns the size of the finished code, or 0 when it failed. */
void agc_emit_begin(agc_emitter *e, uint32_t count);
void agc_emit_label(agc_emitter *e, uint32_t pc);
void agc_emit_move(agc_emitter *e, uint32_t a, uint32_t b);
void agc_emit_const(agc_emitter *e, uint32_t a, uint32_t k);
/* GLOBAL into R[a] from the slot at SLOT: an unset slot (tag Void) leaves for the interpreter. */
void agc_emit_global(agc_emitter *e, uint32_t a, uint64_t slot, uint32_t pc);
void agc_emit_step(agc_emitter *e, uint32_t n, uint32_t pc);
void agc_emit_int(agc_emitter *e, agc_opcode op, agc_instr in, uint32_t pc);
void agc_emit_equal(agc_emitter *e, agc_opcode op, agc_instr in, uint32_t pc);
void agc_emit_helper(agc_emitter *e, uint64_t helper, bool two, bool charged, agc_instr in, uint32_t pc);
void agc_emit_read(agc_emitter *e, agc_opcode op, agc_instr in, uint32_t pc);
void agc_emit_map_get(agc_emitter *e, agc_instr in, uint32_t pc);
void agc_emit_list(agc_emitter *e, agc_instr in);
/* CLOSURE of function bx, which holds CAPTURES values: a call of agc_jit_closure. */
void agc_emit_closure(agc_emitter *e, agc_instr in, uint32_t captures);
/* STRUCT or ENUM: a call of FN(&R[a], &R[b], X, Y) (agc_jit_struct, agc_jit_enum), which never fails. */
void agc_emit_new(agc_emitter *e, agc_instr in, uint64_t fn, uint64_t x, uint64_t y);
/* STRUCT_WITH of the update definition at UPDATE: a call of agc_jit_struct_with, which may leave. */
void agc_emit_struct_with(agc_emitter *e, agc_instr in, uint32_t pc, uint64_t update);
void agc_emit_jump(agc_emitter *e, uint32_t target);
void agc_emit_branch(agc_emitter *e, uint32_t a, bool when, uint32_t target, uint32_t pc);
void agc_emit_exit(agc_emitter *e, uint32_t status, uint32_t pc);
/* CALL_BUILTIN of the direct row at BUILTIN, whose span is SPAN: a call of agc_jit_call_builtin, or of
   agc_jit_call_leaf when the row is a LEAF. */
void agc_emit_builtin(agc_emitter *e, agc_instr in, uint32_t pc, uint64_t builtin, uint32_t span, bool leaf);
/* CALL_BUILTIN of the leaf row at BUILTIN that agc_jit_plain_of gave PLAIN: its checks (a failed one takes the
   INTERPRET exit, for the interpreter to fail as it does) and a call of agc_jit_call_plain, at any native depth. */
void agc_emit_plain_leaf(agc_emitter *e, agc_instr in, uint32_t pc, uint64_t builtin, uint32_t span,
                         const agc_jit_plain *plain);
/* CALL with SLOT the address of the callee's entry in the code table and REGISTERS the callee's register count. */
void agc_emit_call(agc_emitter *e, agc_instr in, uint32_t pc, uint64_t slot, uint32_t registers);
/* TAIL_CALL with SLOT the address of the callee's entry in the code table, PARAMS and REGISTERS the callee's counts,
   and SELF set when the callee is the function itself: a jump to instruction 0. Past AGC_JIT_TAIL_PARAMS, the
   TAIL_CALL exit. COUNTER, the JIT when its trace is on (else
   0), gets each exit counted (agc_jit_count_tail). */
void agc_emit_tail_call(agc_emitter *e, agc_instr in, uint32_t pc, bool self, uint64_t slot, uint32_t params,
                        uint32_t registers, uint64_t counter);
/* CALL_VALUE: a native call when agc_jit_call_value pushed the frame, else the CALL_VALUE exit. */
void agc_emit_call_value(agc_emitter *e, agc_instr in, uint32_t pc);
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
/* Linux arm64 only (false elsewhere): sync_register registers the process for membarrier's SYNC_CORE command, once
   when the JIT starts, and sync_cores runs it, so that every thread of the process passes a context synchronization
   event before the call returns (agc_jit_use_sync). */
bool agc_jit_mem_sync_register(void);
bool agc_jit_mem_sync_cores(void);

/* Settles the `on` decision of every function of PROGRAM: CALLABLE[f] stays true when f may get code, LOOPED[f] is
   set when f has a loop and CALLING[f] when it calls a function of the program. Returns the work it did
   (instructions read and call sites counted), which the C test bounds by the program's size. */
size_t agc_jit_settle(const agc_program *program, bool *callable, bool *looped, bool *calling);
/* The names of the builtin rows whose call may park, sorted (jit.c), and whether B is one of them: `on` counts such a
   call AGC_JIT_PARK_WEIGHT trips out. */
extern const char *const agc_jit_parking[];
extern const size_t agc_jit_parking_count;
bool agc_jit_parks(const agc_builtin *b);

#endif
