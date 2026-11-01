/*
 * The JIT tier (docs/vm/05-values-execution-builtins.md §6.4): which functions to compile and when, the walk over a
 * function's bytecode that drives the host's emitter, and the code cache and compile budget of a run. Every function
 * can be compiled: an instruction without code of its own leaves for the interpreter, which runs it and comes back.
 * With `on`, only a function with a loop that seldom leaves is compiled, and the small functions it calls. Core layer.
 */
#include "jit.h"

#include <inttypes.h>
#include <stdlib.h>
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

/* What settle reads of an instruction, by its opcode: agc_jit_settle looks each one up in a table made by op_kind
   once, instead of testing the opcode at each instruction of the program. The first two neither leave compiled code
   nor call, so settle reads no more of them after its first walk. */
enum {
  KIND_CODE,   /* code of its own (has_code), not a jump */
  KIND_RETURN, /* runs once per call */
  /* A CALL_VALUE does not leave: its callee is known only when it runs, and it is called natively once it has code (a
     block or a small function, which `on` compiles at its CALL_VALUE exits), so it is counted as a call of a function
     that may get code. */
  KIND_VALUE,
  KIND_LEAVES, /* no code of its own: a trip out of compiled code */
  KIND_JUMP,   /* JUMP, JUMP_IF_FALSE, JUMP_IF_TRUE: code of its own, the end of a loop when it goes back */
  /* A CALL or TAIL_CALL: of a function of the program when its index is below the function count (compiled code makes
     the call natively when the callee has code, else run_compiled makes the frame transition and goes on in the
     callee's code once it has some, so settle counts the call by its callee), else a trip out. */
  KIND_CALL,
  KIND_TAIL,
  KIND_BUILTIN /* CALL_BUILTIN: see builtin_trips */
};

/* The code that waits for a seal (seal_batch), under the JIT's lock: BYTES[0 .. LEN) holds the code of FUNCTIONS[k]
   at OFFSETS[k], SIZES[k] bytes long, for k below COUNT. */
struct agc_jit_batch {
  uint8_t *bytes;
  size_t len, cap;
  uint32_t *functions, *offsets, *sizes;
  size_t count, slots;
};

/* The hottest leaf rows of the self-compile, which cannot fail once their checks pass: each argument has its tag here
   (AGC_T_VOID: any tag) and, for String.code, its String has one character. Their only agc_fail is agc_as_*'s wrong
   tag or String.code's other count, and running out of memory exits the process. Compiled code checks and calls them
   with no catch (agc_jit_call_plain). vm/tests/jit_test.c checks that each one is a leaf row. */
typedef struct {
  const char *name;
  uint32_t arity;
  agc_jit_plain checks;
} plain_leaf;

static const plain_leaf plain_leaves[] = {
    {"List.size", 1, {{AGC_T_LIST, AGC_T_VOID}, false}},
    {"List.append", 2, {{AGC_T_LIST, AGC_T_VOID}, false}},
    {"ok", 1, {{AGC_T_VOID, AGC_T_VOID}, false}},
    {"Result.ok?", 1, {{AGC_T_RESULT, AGC_T_VOID}, false}},
    {"String.length", 1, {{AGC_T_STRING, AGC_T_VOID}, false}},
    {"String.code", 1, {{AGC_T_STRING, AGC_T_VOID}, true}},
};

/* The rows whose call may park: the turn ends while it waits, for a channel, a task, a timer or stdin (the woken task
   runs the call again) or for an I/O job on the loop or the thread pool (files, paths, processes, sockets, a native
   call or wait). Sorted by strcmp for bsearch; a name stands for each of its arities. Not listed: the `shared` rows
   that never park (Channel.new, Channel.closed?, Task.cancel, the logger, ...), the output rows (puts, IO.print, ...),
   which park only while the output is backed up, and the steppers (File.each_line, Task.map, the Lazy terminals),
   whose call leaves the code once, however often they wait inside it. vm/tests/jit_test.c checks that the list is
   sorted and that each name is a row of the builtin tables. */
const char *const agc_jit_parking[] = {
    "Channel.recv", "Channel.send", "Dir.list", "Dir.mkdir", "Dir.mkdir_private", "File.append_text", "File.close",
    "File.flush", "File.lstat", "File.open", "File.read_bytes.bytes", "File.read_line", "File.read_text",
    "File.replace", "File.sha256.bytes", "File.stat", "File.try_lock", "File.write", "File.write_bytes.bytes",
    "File.write_text", "FrontEnd.stdin_bytes.bytes", "HttpWire.accept", "HttpWire.connect_context", "HttpWire.connect_tls", "HttpWire.idle?",
    "HttpWire.read_head.bytes", "HttpWire.read_response", "HttpWire.wait", "IO.eof?", "IO.gets", "IO.gets!", "IO.read",
    "IO.read_bytes.bytes", "Native.call", "Native.wait_readable", "Native.wait_writable", "Path.real", "Path.remove",
    "Path.rename", "Process.channel_close", "Process.channel_read_line", "Process.channel_send", "Process.close",
    "Process.close_stdin", "Process.output", "Process.parent_read_line", "Process.parent_send",
    "Process.read_available", "Process.read_bytes.bytes", "Process.read_line", "Process.send",
    "Process.send_bytes.bytes", "Process.spawn", "Process.spawn_captured", "Process.spawn_channel", "Process.wait",
    "TCP.accept", "TCP.connect", "TCP.listen", "TCP.read_line", "TCP.recv_bytes.bytes", "TCP.send",
    "TCP.send_bytes.bytes", "TLS.client_context", "TLS.connect", "TLS.listen", "TLS.server_context", "Task.await",
    "Task.await_result", "Task.sleep", "Test.run",
};
const size_t agc_jit_parking_count = sizeof agc_jit_parking / sizeof agc_jit_parking[0];

static int name_order(const void *key, const void *item) { return strcmp(key, *(const char *const *)item); }

/* The opcode a fused one starts with (vm/value.h): its STEP or CONST, compiled alone like the instruction after it,
   which the loader left in place. */
static uint32_t plain_op(uint32_t op) {
  if (op < AGC_OP_COUNT || op >= AGC_FUSED_END) return op;
  return op >= AGC_FUSED_CONST_FIRST ? AGC_OP_CONST : AGC_OP_STEP;
}

/* True when OP (a fused one: its STEP or CONST) always has code of its own. CALL, CALL_VALUE, TAIL_CALL and RETURN
   have code that may exit (op_kind). */
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

/* The kind of OP for settle, from has_code and plain_op. */
static uint8_t op_kind(uint32_t op) {
  uint32_t plain = plain_op(op);
  if (plain == AGC_OP_JUMP || plain == AGC_OP_JUMP_IF_FALSE || plain == AGC_OP_JUMP_IF_TRUE) return KIND_JUMP;
  if (has_code(op)) return KIND_CODE;
  switch (op) {
    case AGC_OP_RETURN: return KIND_RETURN;
    case AGC_OP_CALL_VALUE: return KIND_VALUE;
    case AGC_OP_CALL: return KIND_CALL;
    case AGC_OP_TAIL_CALL: return KIND_TAIL;
    case AGC_OP_CALL_BUILTIN: return KIND_BUILTIN;
    default: return KIND_LEAVES;
  }
}

/* The kind of IN, from KINDS (op_kind of each opcode below AGC_FUSED_END); any other opcode has no code. */
static uint32_t kind_of(const uint8_t *kinds, agc_instr in) {
  return in.op < AGC_FUSED_END ? kinds[in.op] : KIND_LEAVES;
}

/* True when IN at PC of function SELF of P, of kind KIND_JUMP or KIND_TAIL, jumps back to *START or before it: the
   end of a loop. A TAIL_CALL of SELF is one too, back to instruction 0, when its code is a jump there
   (agc_emit_tail_call: at most AGC_JIT_TAIL_PARAMS arguments). */
static bool backward(const agc_program *p, agc_instr in, uint32_t kind, uint32_t pc, uint32_t self, uint32_t *start) {
  *start = (uint32_t)in.b | ((uint32_t)in.c << 16);
  if (kind == KIND_TAIL) {
    bool again = *start == self && p->functions[self].params <= AGC_JIT_TAIL_PARAMS;
    *start = 0;
    return again;
  }
  return *start <= pc;
}

/* The trips out of compiled code that the `on` heuristic counts for a CALL_BUILTIN of row BX of P, in a function
   without a loop when LOOPLESS: none, one, or AGC_JIT_PARK_WEIGHT for a builtin that leaves and may park
   (agc_jit_parking). A block call (a row with a native kind, such as `filter`: its native frame and the block's
   frames) is started by run_compiled itself, which LOOPLESS says to count or not, as its exit unwinds the native
   calls; a direct builtin is called by the code itself, which leaves only when the call ends the turn or fails, and so
   is a leaf below a native call (at native depth 0 it leaves, but unwinds nothing). ROWS[BX] keeps the answer of each
   row, which is the same at each of its call sites: bit 0 once known, bit 1 when it leaves from a loop, bit 2 when it
   leaves from a function without one, bit 3 when it may park. */
static uint32_t builtin_trips(const agc_program *p, uint8_t *rows, uint32_t bx, bool loopless) {
  uint8_t row = rows[bx];
  if (!row) {
    const agc_builtin *b = p->builtins[bx];
    bool leaves = !(b->direct || b->leaf);
    row = (uint8_t)(1u | (unsigned)(leaves && !b->native) << 1 | (unsigned)leaves << 2 |
                    (unsigned)(leaves && agc_jit_parks(b)) << 3);
    rows[bx] = row;
  }
  if (!(row & (loopless ? 4u : 2u))) return 0;
  return row & 8u ? AGC_JIT_PARK_WEIGHT : 1;
}

/* ITEMS, an atomic GC block of *CAP items of SIZE bytes whose first COUNT are set, with room for NEED items: when it
   has too little, a new block of twice the size or more with the same first COUNT items. */
static void *grow(void *items, size_t *cap, size_t count, size_t need, size_t size) {
  if (need <= *cap) return items;
  *cap = 2 * *cap > need ? 2 * *cap : need;
  void *bigger = agc_alloc_atomic(agc_size_mul(*cap, size));
  if (count) memcpy(bigger, items, count * size);
  return bigger;
}

/* Why `on` keeps a function out:
   - A function without a loop runs each instruction at most once per entry, and an entry from the interpreter, the
     exit and the RETURN there cost more than the few instructions it saves; it gets code only to be called natively
     from compiled code, and only when none of its instructions leaves ("none" otherwise, where a block call counts:
     its exit unwinds every native call).
   - A function with an innermost loop that goes back to the turn loop more than once in AGC_JIT_SPACING instructions
     stays out ("exits"): each round trip costs about as much as interpreting that many instructions, so such a loop
     ran slower compiled. A builtin that may park counts AGC_JIT_PARK_WEIGHT round trips (builtin_trips).
   A CALL leaves when its callee may not get code, which depends on the callee's own calls, so the decision is a fixed
   point: every function starts callable, and a function that drops out counts one more leaving instruction in each
   region that calls it. Innermost loops never overlap, so each instruction is in at most one region, and each call
   site is counted once, when its callee drops: the work follows the program's size, whatever the order of the
   functions or the size of a caller. */
size_t agc_jit_settle(const agc_program *p, bool *callable, bool *looped, bool *calling) {
  uint8_t kinds[AGC_FUSED_END];
  for (uint32_t op = 0; op < AGC_FUSED_END; op++) kinds[op] = op_kind(op);
  size_t n = p->function_count, longest = 0, work = 0;
  for (uint32_t k = 0; k < n; k++)
    if (p->functions[k].count > longest) longest = p->functions[k].count;
  /* Atomic GC memory is not zeroed. MARKS holds the pcs of a function that settle reads after its first walk; LAST[j]
     is the pc of the loop end of the function's region j. REGIONS, SITES and ROWS grow as needed. */
  uint32_t *marks = agc_alloc_atomic(agc_size_mul(longest + 1, sizeof *marks));
  uint32_t *last = agc_alloc_atomic(agc_size_mul(longest + 1, sizeof *last));
  size_t region_cap = n + 1, site_cap = n + 1, row_cap = 0, region_count = 0, site_count = 0;
  region *regions = agc_alloc_atomic(agc_size_mul(region_cap, sizeof *regions));
  call_site *sites = agc_alloc_atomic(agc_size_mul(site_cap, sizeof *sites));
  uint8_t *rows = NULL;
  for (uint32_t k = 0; k < n; k++) {
    const agc_function *f = &p->functions[k];
    callable[k] = true;
    calling[k] = false;
    /* The one walk over every instruction marks the ones the rest reads: a jump back, a call of any kind, and an
       instruction without code. Most instructions have code, so the rest reads few. */
    size_t m = 0;
    for (uint32_t pc = 0; pc < f->count; pc++) {
      agc_instr in = f->code[pc];
      uint32_t kind = kind_of(kinds, in), bx = (uint32_t)in.b | ((uint32_t)in.c << 16);
      marks[m] = pc;
      m += (kind > KIND_RETURN) & ((kind != KIND_JUMP) | (bx <= pc));
    }
    work += f->count + m;
    regions = grow(regions, &region_cap, region_count, region_count + m + 1, sizeof *regions);
    sites = grow(sites, &site_cap, site_count, site_count + m + 1, sizeof *sites);
    /* The innermost loops, in order: a loop end is one when the loop end before it (LATEST) is not inside its loop.
       They never overlap, and a function without a loop is one region. */
    size_t first_region = region_count;
    uint32_t latest = UINT32_MAX;
    for (size_t j = 0; j < m; j++) {
      uint32_t pc = marks[j], start, kind = kind_of(kinds, f->code[pc]);
      if ((kind != KIND_JUMP && kind != KIND_TAIL) || !backward(p, f->code[pc], kind, pc, k, &start)) continue;
      if (latest == UINT32_MAX || latest < start) {
        last[region_count - first_region] = pc;
        regions[region_count++] = (region){k, pc - start + 1, 0};
      }
      latest = pc;
    }
    looped[k] = latest != UINT32_MAX;
    if (!looped[k]) regions[region_count++] = (region){k, 0, 0};
    /* The call sites and the trips out of each region; R is the first region that does not end before PC. */
    size_t r = first_region;
    for (size_t j = 0; j < m; j++) {
      uint32_t pc = marks[j];
      agc_instr in = f->code[pc];
      uint32_t kind = kind_of(kinds, in), bx = (uint32_t)in.b | ((uint32_t)in.c << 16);
      if (kind == KIND_JUMP) continue;
      bool call = (kind == KIND_CALL || kind == KIND_TAIL) && bx < n;
      calling[k] |= call || kind == KIND_VALUE;
      if (kind == KIND_VALUE) continue;
      if (looped[k]) {
        while (r < region_count && last[r - first_region] < pc) r++;
        if (r == region_count || last[r - first_region] - regions[r].size + 1 > pc) continue;
      }
      if (call)
        sites[site_count++] = (call_site){bx, (uint32_t)r};
      else if (kind != KIND_BUILTIN)
        regions[r].out++;
      else {
        if (bx >= row_cap) {
          size_t known = row_cap;
          rows = grow(rows, &row_cap, known, (size_t)bx + 1, 1);
          memset(rows + known, 0, row_cap - known);
        }
        regions[r].out += builtin_trips(p, rows, bx, !looped[k]);
      }
    }
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

bool agc_jit_parks(const agc_builtin *b) {
  return b->name &&
         bsearch(b->name, agc_jit_parking, agc_jit_parking_count, sizeof agc_jit_parking[0], name_order) != NULL;
}

const agc_jit_plain *agc_jit_plain_of(const agc_builtin *b) {
  if (!b->leaf) return NULL;
  for (size_t k = 0; k < sizeof plain_leaves / sizeof plain_leaves[0]; k++)
    if (b->arity == plain_leaves[k].arity && strcmp(b->name, plain_leaves[k].name) == 0)
      return &plain_leaves[k].checks;
  return NULL;
}

void agc_emit_start(agc_emitter *e, uint32_t count) {
  memset(e, 0, sizeof *e);
  e->count = count;
  e->labels = agc_alloc_atomic(agc_size_mul(count ? count : 1, sizeof *e->labels));
}

void agc_emit_patch(agc_emitter *e, size_t at, agc_jit_patch_kind kind, uint64_t value) {
  if (e->failed) return;
  if (e->patch_count == e->patch_cap) {
    size_t cap = e->patch_cap ? agc_size_mul(e->patch_cap, 2) : 64;
    agc_jit_patch *patches = agc_alloc_atomic(agc_size_mul(cap, sizeof *patches));
    if (e->patch_count) memcpy(patches, e->patches, e->patch_count * sizeof *patches);
    e->patches = patches;
    e->patch_cap = cap;
  }
  e->patches[e->patch_count++] = (agc_jit_patch){(uint32_t)at, kind, value};
}

bool agc_emit_patches(agc_emitter *e, size_t epilogue, agc_emit_stub stub, agc_emit_link link) {
  /* Patches of one exit word come one after another, so a stub serves its run and a new run lays out a new one. */
  size_t run = 0;
  agc_jit_patch last = {0, AGC_JIT_PATCH_LABEL, 0};
  for (size_t k = 0; k < e->patch_count; k++) {
    agc_jit_patch p = e->patches[k];
    size_t to;
    if (p.kind == AGC_JIT_PATCH_LABEL) {
      if (p.value >= e->count) return false;
      to = e->labels[p.value];
    } else if (p.kind == AGC_JIT_PATCH_EPILOGUE) {
      to = epilogue;
    } else if (p.kind == last.kind && p.value == last.value) {
      to = run;
    } else {
      to = run = e->len;
      last = p;
      stub(e, p, epilogue);
    }
    link(e, p.at, to);
  }
  return true;
}

#if AGC_JIT_HOST
/* The opcode helper of an instruction that is one helper call (agc_emit_helper), with *TWO_OPERANDS for the shape
   with R[c], and *CHARGED when a charge then leaves to be applied, as the interpreter applies it after the
   instruction. */
static uint64_t opcode_helper(agc_opcode op, bool *two_operands, bool *charged) {
  *two_operands = !(op == AGC_OP_NEG_F || op == AGC_OP_LIST_LEN || op == AGC_OP_TO_TEXT);
  *charged = op == AGC_OP_TO_TEXT || op == AGC_OP_SAME || op == AGC_OP_CONCAT;
  agc_status (*one)(agc_vm *, agc_value *, const agc_value *) = NULL;
  agc_status (*two)(agc_vm *, agc_value *, const agc_value *, const agc_value *) = NULL;
  switch (op) {
    case AGC_OP_NEG_F: one = agc_op_neg_f; break;
    case AGC_OP_LIST_LEN: one = agc_op_list_len; break;
    case AGC_OP_TO_TEXT: one = agc_op_to_text; break;
    case AGC_OP_ADD_F: two = agc_op_add_f; break;
    case AGC_OP_SUB_F: two = agc_op_sub_f; break;
    case AGC_OP_MUL_F: two = agc_op_mul_f; break;
    case AGC_OP_DIV_F: two = agc_op_div_f; break;
    case AGC_OP_LT_F: two = agc_op_lt_f; break;
    case AGC_OP_LE_F: two = agc_op_le_f; break;
    case AGC_OP_SAME: two = agc_op_same; break;
    case AGC_OP_CONCAT: two = agc_op_concat; break;
    default: two = agc_op_list_get; break;
  }
  return one ? (uint64_t)(uintptr_t)one : (uint64_t)(uintptr_t)two;
}

/* The size of F's code, or 0 when an operand or the code did not fit. Its cases are the set of has_code, CALL,
   CALL_VALUE and RETURN; other instructions leave for the interpreter. */
static size_t emit_function(agc_emitter *e, const agc_jit *jit, const agc_function *f) {
  const agc_program *p = jit->program;
  uint32_t self = (uint32_t)(f - p->functions);
  uint64_t counter = AGC_TRACE_ON(jit->trace, AGC_TRACE_JIT) ? (uint64_t)(uintptr_t)jit : 0;
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
      case AGC_OP_LIST_GET: {
        bool two, charged;
        uint64_t helper = opcode_helper(op, &two, &charged);
        agc_emit_helper(e, helper, two, charged, in, pc);
        break;
      }
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
        if (bx < p->function_count)
          agc_emit_tail_call(e, in, pc, bx == self, (uint64_t)(uintptr_t)&jit->code[bx], p->functions[bx].params,
                             p->functions[bx].registers, counter);
        else
          agc_emit_exit(e, AGC_JIT_EXIT_INTERPRET, pc);
        break;
      case AGC_OP_CALL_VALUE: agc_emit_call_value(e, in, pc); break;
      case AGC_OP_RETURN: agc_emit_return(e, in.a, pc); break;
      case AGC_OP_CALL_BUILTIN: {
        /* As for CALL, the C tests' hand-made code may have no builtin table. */
        const agc_builtin *b = bx < p->builtin_count ? p->builtins[bx] : NULL;
        const agc_jit_plain *plain = b ? agc_jit_plain_of(b) : NULL;
        if (plain)
          agc_emit_plain_leaf(e, in, pc, (uint64_t)(uintptr_t)b, f->spans[pc], plain);
        else if (b && (b->direct || b->leaf))
          agc_emit_builtin(e, in, pc, (uint64_t)(uintptr_t)b, f->spans[pc], b->leaf);
        else
          agc_emit_exit(e, AGC_JIT_EXIT_INTERPRET, pc);
        break;
      }
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
   after it: at `hot_calls` (AGC_JIT_CALLEE_THRESHOLD) more CALL exits of a function in it, when the interpreter enters
   a function that just compiled (which must run now), or when the batch holds AGC_JIT_BATCH bytes. So functions that
   get hot about together, such as the callees of one long loop body, share a seal, even when several schedulers run
   them. Each seal takes the next pages of the run's code memory, each function at a multiple of 16 bytes. The batch,
   the chunks, `cap` and `used` change under the lock. */
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
    /* The sample of agc_jit_turn reads it; a load first, so most entries write no shared line. */
    if (!atomic_load_explicit(&jit->counted, memory_order_relaxed))
      atomic_store_explicit(&jit->counted, true, memory_order_relaxed);
    /* An entry that lands at or before the previous one (a call lands at 0) is a pass: a new call, or a loop that went
       round. The returns and the turns inside one pass of a long loop body land further on each time, so a function
       whose loop runs only a few times stays interpreted however many entries it gets. */
    uint32_t last = atomic_load_explicit(&jit->last[function], memory_order_relaxed);
    atomic_store_explicit(&jit->last[function], pc, memory_order_relaxed);
    uint32_t passes = atomic_load_explicit(&jit->passes[function], memory_order_relaxed);
    if (pc <= last && passes < jit->hot_passes)
      passes = atomic_fetch_add_explicit(&jit->passes[function], 1, memory_order_relaxed) + 1;
    /* The counts stop at their thresholds, so they never wrap. */
    uint32_t entries = atomic_load_explicit(&jit->entries[function], memory_order_relaxed);
    if (entries < jit->hot_entries)
      entries = atomic_fetch_add_explicit(&jit->entries[function], 1, memory_order_relaxed) + 1;
    if (entries < jit->hot_entries || passes < jit->hot_passes) return NULL;
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
  if (calls < jit->hot_calls) return NULL;
  if (calls == jit->hot_calls) return compile(jit, function, false);
  if (calls < 2 * jit->hot_calls) return NULL;
  /* Still in the batch (or still compiling on another scheduler): seal what is there. */
  agc_lock_take(jit->lock);
  seal_batch(jit, 0, NULL, 0);
  agc_lock_drop(jit->lock);
  return atomic_load_explicit(&jit->code[function], memory_order_acquire);
}

/* The log2 of AGC_JIT_SAMPLE and of AGC_JIT_SAMPLE_MAX. */
#define AGC_JIT_SAMPLE_BITS 4u
#define AGC_JIT_SAMPLE_MAX_BITS 8u
#define AGC_JIT_SAMPLE_MISSES 8u
_Static_assert(AGC_JIT_SAMPLE == 1u << AGC_JIT_SAMPLE_BITS && AGC_JIT_SAMPLE_MAX == 1u << AGC_JIT_SAMPLE_MAX_BITS,
               "the sample bits match the intervals");

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
  jit->hot_entries = AGC_JIT_THRESHOLD;
  jit->hot_passes = AGC_JIT_PASSES;
  jit->hot_calls = AGC_JIT_CALLEE_THRESHOLD;
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
  atomic_init(&jit->tails, 0);
  atomic_init(&jit->tails_compiled, 0);
  atomic_init(&jit->turns, 0);
  atomic_init(&jit->live, false);
  atomic_init(&jit->spent, false);
  atomic_init(&jit->work, 0);
  jit->budget = AGC_JIT_BUDGET;
  atomic_init(&jit->sample_bits, AGC_JIT_SAMPLE_BITS);
  atomic_init(&jit->sample_misses, 0);
  atomic_init(&jit->counted, false);
  atomic_init(&jit->arena, NULL);
  atomic_init(&jit->used, 0);
  return jit;
}

/* True for a turn drawn at random, one in 2^BITS on average: a xorshift16 with the shifts 7, 9, 8, whose period is all
   65535 non-zero states, seeded with an odd number made of the scheduler's index. A counter would sample every 16th
   turn, and two tasks that take turns could then put every sample on the one that idles. */
static bool sampled(agc_vm *vm, uint32_t bits) {
  uint16_t x = vm->jit_sample ? vm->jit_sample : (uint16_t)(vm->index * 2 + 1);
  x ^= (uint16_t)(x << 7);
  x ^= (uint16_t)(x >> 9);
  x ^= (uint16_t)(x << 8);
  vm->jit_sample = x;
  return (x & ((1u << bits) - 1)) == 0;
}

/* The draw of a turn while no code is published. A sampled turn reads whether an entry was counted since the last
   one (on any scheduler): if so the interval goes back to AGC_JIT_SAMPLE; after AGC_JIT_SAMPLE_MISSES sampled turns
   in a row with none, it doubles, up to AGC_JIT_SAMPLE_MAX. Not at the first miss: in a ping-pong whose work runs in
   one task's turns only, about half the samples land on the other task's turns. Only sampled turns write, and only
   a field whose value changes, so the shared line stays cold. Two schedulers that sample at once may undo each
   other's store: a reset can be lost, and the interval go back to what the other read (up to AGC_JIT_SAMPLE_MAX).
   That is harmless: the next counted entry resets it again at the next sampled turn. */
static bool sample(agc_jit *jit, agc_vm *vm) {
  uint32_t bits = atomic_load_explicit(&jit->sample_bits, memory_order_relaxed);
  if (!sampled(vm, bits)) return false;
  uint32_t was = atomic_load_explicit(&jit->sample_misses, memory_order_relaxed);
  uint32_t next = AGC_JIT_SAMPLE_BITS, misses = 0;
  bool counted = atomic_load_explicit(&jit->counted, memory_order_relaxed) &&
                 atomic_exchange_explicit(&jit->counted, false, memory_order_relaxed);
  if (!counted) {
    next = bits;
    misses = was + 1;
    if (misses == AGC_JIT_SAMPLE_MISSES) {
      misses = 0;
      if (next < AGC_JIT_SAMPLE_MAX_BITS) next++;
    }
  }
  if (misses != was) atomic_store_explicit(&jit->sample_misses, misses, memory_order_relaxed);
  if (next != bits) atomic_store_explicit(&jit->sample_bits, next, memory_order_relaxed);
  return true;
}

bool agc_jit_turn(agc_jit *jit, agc_vm *vm) {
  const agc_task *t = vm->task;
  /* The flag only picks the loop, and the jit copy loads each code pointer with acquire, so the acquire here (a plain
     load on x86-64) only keeps "live" meaning "some code is visible" on every scheduler. */
  bool jit_copy = atomic_load_explicit(&jit->live, memory_order_acquire);
  uint32_t n = t->frame_count, low = n > AGC_JIT_TOP_FRAMES ? n - AGC_JIT_TOP_FRAMES : 0;
  /* The sample: a per-scheduler draw; only a sampled turn writes the shared interval. */
  if (!jit_copy) jit_copy = sample(jit, vm);
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

void agc_jit_count_tail(agc_jit *jit, _Atomic(agc_jit_code) *slot) {
  atomic_fetch_add_explicit(&jit->tails, 1, memory_order_relaxed);
  /* A trace hint: another scheduler may publish the callee's code between the code's own check and this load. */
  if (atomic_load_explicit(slot, memory_order_relaxed))
    atomic_fetch_add_explicit(&jit->tails_compiled, 1, memory_order_relaxed);
}

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
  uint64_t tails = atomic_load_explicit(&jit->tails, memory_order_relaxed);
  if (tails)
    AGC_TRACE(jit->trace, AGC_TRACE_JIT, "transition op=tail-call count=%" PRIu64 " compiled=%" PRIu64, tails,
              atomic_load_explicit(&jit->tails_compiled, memory_order_relaxed));
  uint64_t turns = atomic_load_explicit(&jit->turns, memory_order_relaxed);
  if (turns) AGC_TRACE(jit->trace, AGC_TRACE_JIT, "turn count=%" PRIu64, turns);
}

#if AGC_LEAF_CHECK
/* Names the direct or leaf builtin and what it did that its call from compiled code must not (a row marked by
   mistake). */
static _Noreturn __attribute__((noinline, cold)) void direct_broken(const agc_builtin *b, const char *what) {
  char detail[160];
  (void)snprintf(detail, sizeof detail, "builtin %s/%" PRIu32 " is marked %s but %s", b->name, b->arity,
                 b->leaf ? "leaf" : "direct", what);
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

uint32_t agc_jit_call_leaf(agc_vm *vm, agc_value *args, const agc_builtin *b, uint64_t where) {
  agc_task *t = vm->task;
  t->frames[t->frame_count - 1].pc = (uint32_t)where;
#if AGC_LEAF_CHECK
  /* The interpreter's call_leaf checks the same rule; here a broken row would also have left a cost or a stop that
     compiled code never applies. */
  int64_t cost = t->turn_cost, stop = vm->next_stop, left = vm->turn_left;
  uint32_t frames = t->frame_count, depth = vm->sync_depth;
  bool yielded = vm->yield, retry = t->retry;
#endif
  agc_value result;
  if (!caught(vm, b, args, (uint32_t)(where >> 32), &result)) return AGC_JIT_EXIT_RAISE;
#if AGC_LEAF_CHECK
  if (t->parking || t->retry != retry || t->stepper || t->frame_count != frames || vm->sync_depth != depth ||
      t->turn_cost != cost || vm->next_stop != stop || vm->turn_left != left || vm->yield != yielded)
    direct_broken(b, "broke the leaf rule");
#endif
  args[0] = result;
  return AGC_STATUS_OK;
}

void agc_jit_call_plain(agc_vm *vm, agc_value *args, const agc_builtin *b, uint64_t where) {
#if AGC_LEAF_CHECK
  /* The checked builds catch it anyway, and stop when a row of plain_leaves failed or broke the leaf rule. */
  if (agc_jit_call_leaf(vm, args, b, where) != AGC_STATUS_OK) direct_broken(b, "failed with the tags it needs");
#else
  (void)where;
  args[0] = b->fn(vm, args, 0);
#endif
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

uint32_t agc_jit_call_value_exit(agc_vm *vm, agc_jit *jit, const agc_function *f, agc_jit_exit out, uint32_t base) {
  agc_task *t = vm->task;
  agc_instr in = f->code[out.pc];
  uint32_t at = base + in.a;
  if (AGC_TRACE_ON(jit->trace, AGC_TRACE_JIT)) agc_jit_count_transition(jit);
  agc_task_call(vm, t, t->regs[at], at + 1, NULL, in.b, at, f->spans[out.pc]);
  return t->frames[t->frame_count - 1].function;
}

agc_jit_code agc_jit_call_value(agc_vm *vm, agc_value *window, uint32_t argc, uint32_t pc) {
  const agc_program *p = vm->rt->program;
  agc_task *t = vm->task;
  if (!agc_is(window[0], AGC_T_FN)) return NULL;
  const agc_fn *fn = agc_as_fn(vm, window[0]);
  if (fn->function >= p->function_count) return NULL;
  const agc_function *callee = &p->functions[fn->function];
  if (callee->params != argc || callee->captures != fn->n) return NULL;
  agc_jit_code code = atomic_load_explicit(&vm->rt->jit->code[fn->function], memory_order_acquire);
  /* WINDOW is R + a of the frame on top, inside the register file. */
  size_t base = (size_t)(window - t->regs) + 1;
  if (!code || t->frame_count >= t->frame_capacity || t->depth >= AGC_MAX_DEPTH ||
      base + callee->registers > t->reg_capacity)
    return NULL;
  t->frames[t->frame_count - 1].pc = pc + 1;
  t->frames[t->frame_count++] =
    (agc_frame){.function = fn->function, .pc = 0, .base = (uint32_t)base, .ret = (uint32_t)base - 1};
  t->depth++;
  /* The loader keeps params + captures within the callee's registers, which fit the file (checked above). */
  if (fn->n) memcpy(window + 1 + argc, fn->captured, (size_t)fn->n * sizeof(agc_value));
  return code;
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
