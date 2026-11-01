/*
 * The arm64 emitter of the JIT (docs/vm/05-values-execution-builtins.md §6.4): the machine code of each instruction
 * kind, the exit stubs and the entry table, for the AAPCS64 calling convention and Apple's variant of it. Compiled code
 * keeps the VM in x19, the registers R in x20, the constants K in x21 and its depth of native calls in x22, and never
 * touches x18, which Apple reserves. Every instruction is 4 bytes, so the code is position-independent: branches are
 * relative, and helper addresses are built with movz and movk. With AGC_A64_EMIT_TEST a C test on any machine compiles
 * this file into itself under other names (A64) and checks the words it writes, without running them. Core layer.
 */
#include "jit.h"

#if defined(AGC_A64_EMIT_TEST) || (AGC_JIT_HOST && defined(__aarch64__))
#include <stddef.h>
#include <string.h>

/* The seam's names, or the test's own, so that a test binary that also links emit_x64.c has no clash. */
#ifdef AGC_A64_EMIT_TEST
#define A64(name) agc_a64_emit_##name
#else
#define A64(name) agc_emit_##name
#endif

/* The offsets of the tail entry and the native entry in a function's code (see agc_emit_begin). */
enum { A64_TAIL_ENTRY = 4, A64_NATIVE_ENTRY = 8 };
#ifdef __aarch64__
_Static_assert(A64_TAIL_ENTRY == AGC_JIT_TAIL_ENTRY && A64_NATIVE_ENTRY == AGC_JIT_NATIVE_ENTRY,
               "jit.h gives the entries of this emitter");
#endif

/* The general registers by number. x0 to x3 carry arguments and the result (a native RETURN's value in x1 and x2,
   beside its exit word in x0), x9 to x15 are scratch (caller-saved), and x19 to x22 are callee-saved, so they survive
   every helper call. CALLEE holds the code a native call goes to. x16, x17 and x18 are never used. */
enum { X0, X1, X2, X3, T0 = 9, T1, T2, T3, AT = 13, TAGS = 14, CALLEE = 15, VM = 19, REGS, CONSTS, DEPTH, ZR = 31 };

/* The condition codes. The low bit inverts a condition (EQ and NE, LT and GE, ...). */
enum { CC_EQ, CC_NE, CC_HS, CC_LO, CC_VS = 6, CC_HI = 8, CC_LS, CC_GE, CC_LT, CC_GT, CC_LE };

/* A register's tag and payload: registers are 16-byte agc_values, tag at 0 (the full first word is written, as
   agc_word_value builds it) and payload at 8. */
#define TAG(r) ((uint64_t)(r) * 16)
#define WORD(r) ((uint64_t)(r) * 16 + 8)

/* The frame and task fields that a native CALL and TAIL_CALL write and RETURN reads (port.h); jit.h checks their
   offsets and sizes. */
#define FRAME_FIELD(name) ((uint64_t)offsetof(agc_frame, name))
#define TASK_FIELD(name) ((uint64_t)offsetof(agc_task, name))

/* Room for 4 more bytes, or `failed` past the code cap. Once `failed` is set nothing is written any more: put32,
   put32_at and agc_emit_patch do nothing, so a position recorded before the failure is never written into, and
   agc_emit_end lays out nothing. */
static bool grow(agc_emitter *e) {
  if (e->failed) return false;
  if (e->len + 4 > AGC_JIT_CODE_CAP) {
    e->failed = true;
    return false;
  }
  if (e->len + 4 <= e->cap) return true;
  size_t cap = e->cap ? agc_size_mul(e->cap, 2) : 256;
  uint8_t *code = agc_alloc_atomic(cap);
  if (e->len) memcpy(code, e->code, e->len);
  e->code = code;
  e->cap = cap;
  return true;
}

static void put32_at(agc_emitter *e, size_t at, uint32_t word) {
  if (e->failed) return;
  for (int k = 0; k < 4; k++) e->code[at + (size_t)k] = (uint8_t)(word >> (8 * k));
}

/* One instruction, little-endian. */
static void put32(agc_emitter *e, uint32_t word) {
  if (!grow(e)) return;
  put32_at(e, e->len, word);
  e->len += 4;
}

static uint32_t word_at(const agc_emitter *e, size_t at) {
  return (uint32_t)e->code[at] | (uint32_t)e->code[at + 1] << 8 | (uint32_t)e->code[at + 2] << 16 |
         (uint32_t)e->code[at + 3] << 24;
}

/* b to a patch's target, written by agc_emit_end. Every label, exit stub and the epilogue is reached by b, whose 26-bit
   offset covers 128 MiB, twice the code cap, so a function never has a target out of range. */
static void branch_to(agc_emitter *e, agc_jit_patch_kind kind, uint64_t value) {
  agc_emit_patch(e, e->len, kind, value);
  put32(e, 0x14000000u);
}

/* A conditional branch (b.CC) forward inside one instruction's code, its offset written by land. */
static size_t skip_if(agc_emitter *e, int cc) {
  size_t at = e->len;
  put32(e, 0x54000000u | (uint32_t)cc);
  return at;
}

/* An unconditional branch forward inside one instruction's code, its offset written by land. */
static size_t skip(agc_emitter *e) {
  size_t at = e->len;
  put32(e, 0x14000000u);
  return at;
}

/* The branch at AT (skip_if, skip, or cbz and cbnz from skip_zero) now lands here. These skips cross a few
   instructions only, well inside the 1 MiB of a conditional branch. */
static void land(agc_emitter *e, size_t at) {
  if (e->failed) return;
  uint32_t word = word_at(e, at), rel = (uint32_t)(e->len - at) / 4;
  if ((word & 0xFC000000u) == 0x14000000u)
    word |= rel & 0x3FFFFFFu;
  else
    word |= (rel & 0x7FFFFu) << 5;
  put32_at(e, at, word);
}

/* When CC holds, b to the stub that returns STATUS at PC: b.<not CC> over the b, so the far part is always a b. */
static void exit_if(agc_emitter *e, int cc, uint32_t status, uint32_t pc) {
  size_t over = skip_if(e, cc ^ 1);
  branch_to(e, AGC_JIT_PATCH_EXIT, agc_emit_exit_word(status, pc));
  land(e, over);
}

/* cbz (or cbnz with NONZERO) on the 64-bit (WIDE) or 32-bit register R, forward, its offset written by land. */
static size_t skip_zero(agc_emitter *e, bool nonzero, bool wide, int r) {
  size_t at = e->len;
  put32(e, (wide ? 0xB4000000u : 0x34000000u) | (nonzero ? 0x01000000u : 0) | (uint32_t)r);
  return at;
}

/* mov DST, SRC on 64 bits (orr DST, xzr, SRC), or on 32 bits, which clears the high half. */
static void move_reg(agc_emitter *e, bool wide, int dst, int src) {
  put32(e, (wide ? 0xAA0003E0u : 0x2A0003E0u) | (uint32_t)src << 16 | (uint32_t)dst);
}

/* A 64-bit immediate: movz and three movk, always four instructions, so that a word's size never depends on it. */
static void move_imm64(agc_emitter *e, int r, uint64_t v) {
  put32(e, 0xD2800000u | (uint32_t)(v & 0xFFFF) << 5 | (uint32_t)r);
  for (uint32_t hw = 1; hw < 4; hw++)
    put32(e, 0xF2800000u | hw << 21 | (uint32_t)((v >> (16 * hw)) & 0xFFFF) << 5 | (uint32_t)r);
}

/* A 32-bit immediate, zero-extended: movz, and movk when the high half is not 0. */
static void move_imm32(agc_emitter *e, int r, uint32_t v) {
  put32(e, 0xD2800000u | (v & 0xFFFF) << 5 | (uint32_t)r);
  if (v >> 16) put32(e, 0xF2800000u | 1u << 21 | (v >> 16) << 5 | (uint32_t)r);
}

/* DST = BASE + OFF. Register and field offsets stay below 2^32 (R reaches 65,535 registers of 16 bytes), so one add
   covers 12 bits, two cover 24, and AT holds anything larger. */
static void add_imm(agc_emitter *e, int dst, int base, uint64_t off) {
  if (off >> 32) {
    e->failed = true;
    return;
  }
  if (off <= 0xFFF) {
    put32(e, 0x91000000u | (uint32_t)off << 10 | (uint32_t)base << 5 | (uint32_t)dst);
  } else if (off <= 0xFFFFFF) {
    put32(e, 0x91400000u | (uint32_t)(off >> 12) << 10 | (uint32_t)base << 5 | (uint32_t)dst);
    if (off & 0xFFF) put32(e, 0x91000000u | (uint32_t)(off & 0xFFF) << 10 | (uint32_t)dst << 5 | (uint32_t)dst);
  } else {
    move_imm32(e, AT, (uint32_t)off);
    put32(e, 0x8B000000u | (uint32_t)AT << 16 | (uint32_t)base << 5 | (uint32_t)dst);
  }
}

/* A load or store of SIZE bytes (OP is its unsigned-offset form) at [BASE + OFF]: the scaled 12-bit offset when it
   fits, else the address in AT first. */
static void memory(agc_emitter *e, uint32_t op, unsigned size, int rt, int base, uint64_t off) {
  if (off % size == 0 && off / size <= 0xFFF) {
    put32(e, op | (uint32_t)(off / size) << 10 | (uint32_t)base << 5 | (uint32_t)rt);
    return;
  }
  add_imm(e, AT, base, off);
  put32(e, op | (uint32_t)AT << 5 | (uint32_t)rt);
}

static void load(agc_emitter *e, int rt, int base, uint64_t off) { memory(e, 0xF9400000u, 8, rt, base, off); }
static void store(agc_emitter *e, int base, uint64_t off, int rt) { memory(e, 0xF9000000u, 8, rt, base, off); }
static void load32(agc_emitter *e, int rt, int base, uint64_t off) { memory(e, 0xB9400000u, 4, rt, base, off); }
static void load8(agc_emitter *e, int rt, int base, uint64_t off) { memory(e, 0x39400000u, 1, rt, base, off); }
static void store32(agc_emitter *e, int base, uint64_t off, int rt) { memory(e, 0xB9000000u, 4, rt, base, off); }
static void store8(agc_emitter *e, int base, uint64_t off, int rt) { memory(e, 0x39000000u, 1, rt, base, off); }

/* The 32-bit field at [BASE + OFF] plus DELTA (1 or -1), through T3: the task's frame_count and depth, which only
   the thread that runs the task touches. */
static void bump32(agc_emitter *e, int base, uint64_t off, int delta) {
  load32(e, T3, base, off);
  put32(e, (delta > 0 ? 0x11000400u : 0x51000400u) | (uint32_t)T3 << 5 | (uint32_t)T3); /* add or sub w12, w12, #1 */
  store32(e, base, off, T3);
}

/* cmp R, V on 64 (WIDE) or 32 bits; above 12 bits V goes through T3 first. */
static void compare_imm(agc_emitter *e, bool wide, int r, uint64_t v) {
  uint32_t sf = wide ? 0x80000000u : 0;
  if (v <= 0xFFF) {
    put32(e, 0x7100001Fu | sf | (uint32_t)v << 10 | (uint32_t)r << 5);
    return;
  }
  if (v >> 32) {
    e->failed = true;
    return;
  }
  move_imm32(e, T3, (uint32_t)v);
  put32(e, 0x6B00001Fu | sf | (uint32_t)T3 << 16 | (uint32_t)r << 5);
}

/* cmp X, Y on 64 bits. */
static void compare(agc_emitter *e, int x, int y) { put32(e, 0xEB00001Fu | (uint32_t)y << 16 | (uint32_t)x << 5); }

/* cset wR, CC: R is 0 or 1, the payload of agc_bool. */
static void set_bool(agc_emitter *e, int r, int cc) { put32(e, 0x1A9F07E0u | (uint32_t)(cc ^ 1) << 12 | (uint32_t)r); }

/* The 32-bit tag of register R in T0, compared with TAG. */
static void compare_tag(agc_emitter *e, uint32_t r, agc_tag tag) {
  load32(e, T0, REGS, TAG(r));
  compare_imm(e, false, T0, (uint64_t)tag);
}

/* The tag of register R must be TAG, else the instruction at PC fails with a wrong tag, as agc_as_int does. */
static void need_tag(agc_emitter *e, uint32_t r, agc_tag tag, uint32_t pc) {
  compare_tag(e, r, tag);
  exit_if(e, CC_NE, AGC_STATUS_WRONG_TAG, pc);
}

/* The tag of register R must be TAG, else the interpreter runs the instruction at PC, and fails as it does. */
static void tag_or_interpret(agc_emitter *e, uint32_t r, agc_tag tag, uint32_t pc) {
  compare_tag(e, r, tag);
  exit_if(e, CC_NE, AGC_JIT_EXIT_INTERPRET, pc);
}

/* R[a] = VALUE with TAG: the full tag word, then the payload. */
static void store_value(agc_emitter *e, uint32_t a, agc_tag tag, int value) {
  move_imm32(e, TAGS, (uint32_t)tag);
  store(e, REGS, TAG(a), TAGS);
  store(e, REGS, WORD(a), value);
}

/* R[a] = the 16 bytes at [BASE + OFF], both words read before either is written, so R[a] may be the source. */
static void copy_value(agc_emitter *e, uint32_t a, int base, uint64_t off) {
  load(e, T0, base, off);
  load(e, T1, base, off + 8);
  store(e, REGS, TAG(a), T0);
  store(e, REGS, WORD(a), T1);
}

/* The frame of compiled code: x29 and x30, then x19 to x22, 48 bytes, so sp stays 16-byte aligned at every call. */
static void save_registers(agc_emitter *e) {
  put32(e, 0xA9BD7BFDu); /* stp x29, x30, [sp, #-48]! */
  put32(e, 0x910003FDu); /* mov x29, sp */
  put32(e, 0xA90153F3u); /* stp x19, x20, [sp, #16] */
  put32(e, 0xA9025BF5u); /* stp x21, x22, [sp, #32] */
}

void A64(begin)(agc_emitter *e, uint32_t count) {
  agc_emit_start(e, count);
  /* The entry from C at offset 0 branches over the two entries of compiled code. The tail entry at A64_TAIL_ENTRY,
     which a native TAIL_CALL of another function branches to with everything as it is (the frame's R, the native
     depth, the frame of the caller's code, which every function lays out the same way): instruction 0. The native
     entry at A64_NATIVE_ENTRY, which a native CALL of compiled code calls with the callee's R in x1, x19 and x21 being
     the same for every function: one more native call deep, then instruction 0. */
  size_t over = skip(e);
  branch_to(e, AGC_JIT_PATCH_LABEL, 0);
  save_registers(e);
  put32(e, 0x910006D6u); /* add x22, x22, #1 */
  move_reg(e, true, REGS, X1);
  branch_to(e, AGC_JIT_PATCH_LABEL, 0);
  land(e, over);
  /* The entry from C: no native call below, then instruction pc by the table of offsets that agc_emit_end puts after
     the code. adr gives this instruction's address, and the movz and movk after it, written by agc_emit_end, its
     distance to the table, so the table may be anywhere in the code's 64 MiB. */
  save_registers(e);
  move_reg(e, true, DEPTH, ZR);
  move_reg(e, true, VM, X0);
  move_reg(e, true, REGS, X1);
  move_reg(e, true, CONSTS, X2);
  move_reg(e, false, T0, X3);
  e->entry = (uint32_t)e->len;
  put32(e, 0x10000000u | T1);              /* adr x10, . */
  put32(e, 0xD2800000u | T2);              /* movz x11, #(table - entry) & 0xFFFF */
  put32(e, 0xF2A00000u | T2);              /* movk x11, #(table - entry) >> 16, lsl #16 */
  put32(e, 0x8B0B014Au);                   /* add x10, x10, x11 */
  put32(e, 0xB8A97949u);                   /* ldrsw x9, [x10, x9, lsl #2] */
  put32(e, 0x8B090149u);                   /* add x9, x10, x9 */
  put32(e, 0xD61F0120u);                   /* br x9 */
}

void A64(label)(agc_emitter *e, uint32_t pc) {
  if (pc < e->count) e->labels[pc] = (uint32_t)e->len;
}

void A64(move)(agc_emitter *e, uint32_t a, uint32_t b) { copy_value(e, a, REGS, TAG(b)); }

void A64(const)(agc_emitter *e, uint32_t a, uint32_t k) { copy_value(e, a, CONSTS, TAG(k)); }

/* GLOBAL: the value in the slot, a program table that is never written after the entry function, so no lock; a slot
   with tag Void was never set (hand-made bytecode), and the interpreter fails on it as it does. */
void A64(global)(agc_emitter *e, uint32_t a, uint64_t slot, uint32_t pc) {
  move_imm64(e, T2, slot);
  load32(e, T0, T2, 0);
  compare_imm(e, false, T0, AGC_T_VOID);
  exit_if(e, CC_EQ, AGC_JIT_EXIT_INTERPRET, pc);
  copy_value(e, a, T2, 0);
}

/* The STEP's fast path, as the interpreter's: while vm->next_stop > n, take n from it; else exit for the slow path
   (step_slow), which may stop the run, end the turn or take a new batch. next_stop is read from memory each time. */
void A64(step)(agc_emitter *e, uint32_t n, uint32_t pc) {
  load(e, T0, VM, offsetof(agc_vm, next_stop));
  move_imm32(e, T1, n);
  compare(e, T0, T1);
  exit_if(e, CC_LE, AGC_JIT_EXIT_STEP, pc);
  put32(e, 0xCB0A0129u); /* sub x9, x9, x10 */
  store(e, VM, offsetof(agc_vm, next_stop), T0);
}

/* DIV_I and MOD_I, the dividend in x9: the divisor is checked for 0, and for -1, where sdiv would give INT64_MIN for
   INT64_MIN: the quotient is then the negation (overflow for INT64_MIN) and the remainder 0, as agc_op_div_i and
   agc_op_mod_i say. sdiv rounds toward zero, as C does, and msub takes the remainder with the dividend's sign. */
static void divide(agc_emitter *e, bool mod, agc_instr in, uint32_t pc) {
  load(e, T1, REGS, WORD(in.c));
  size_t nonzero = skip_zero(e, true, true, T1);
  branch_to(e, AGC_JIT_PATCH_EXIT, agc_emit_exit_word(AGC_STATUS_DIVISION_BY_ZERO, pc));
  land(e, nonzero);
  put32(e, 0xB100055Fu); /* cmn x10, #1 */
  size_t not_minus_one = skip_if(e, CC_NE);
  if (mod) {
    move_reg(e, true, T0, ZR);
  } else {
    put32(e, 0xEB0903E9u); /* negs x9, x9 */
    exit_if(e, CC_VS, AGC_STATUS_OVERFLOW, pc);
  }
  size_t done = skip(e);
  land(e, not_minus_one);
  put32(e, 0x9ACA0D2Bu); /* sdiv x11, x9, x10 */
  if (mod)
    put32(e, 0x9B0AA569u); /* msub x9, x11, x10, x9 */
  else
    move_reg(e, true, T0, T2);
  land(e, done);
}

/* The Int operators and compares, inline: both tags first (WRONG_TAG), then the operation with its overflow check,
   and the result written last, so R[a] is left alone on any exit, as the helpers leave dst. */
void A64(int)(agc_emitter *e, agc_opcode op, agc_instr in, uint32_t pc) {
  need_tag(e, in.b, AGC_T_INT, pc);
  if (op == AGC_OP_NEG_I) {
    load(e, T0, REGS, WORD(in.b));
    put32(e, 0xEB0903E9u); /* negs x9, x9 */
    exit_if(e, CC_VS, AGC_STATUS_OVERFLOW, pc);
    store_value(e, in.a, AGC_T_INT, T0);
    return;
  }
  need_tag(e, in.c, AGC_T_INT, pc);
  load(e, T0, REGS, WORD(in.b));
  switch (op) {
    case AGC_OP_DIV_I:
    case AGC_OP_MOD_I: divide(e, op == AGC_OP_MOD_I, in, pc); break;
    case AGC_OP_LT_I:
    case AGC_OP_LE_I:
      load(e, T1, REGS, WORD(in.c));
      compare(e, T0, T1);
      set_bool(e, T0, op == AGC_OP_LT_I ? CC_LT : CC_LE);
      store_value(e, in.a, AGC_T_BOOL, T0);
      return;
    case AGC_OP_MUL_I:
      /* The product overflows when its high half (smulh) is not the sign of its low half. */
      load(e, T1, REGS, WORD(in.c));
      put32(e, 0x9B0A7D2Bu); /* mul x11, x9, x10 */
      put32(e, 0x9B4A7D2Cu); /* smulh x12, x9, x10 */
      put32(e, 0xEB8BFD9Fu); /* cmp x12, x11, asr #63 */
      exit_if(e, CC_NE, AGC_STATUS_OVERFLOW, pc);
      move_reg(e, true, T0, T2);
      break;
    default:
      load(e, T1, REGS, WORD(in.c));
      put32(e, op == AGC_OP_ADD_I ? 0xAB0A0129u : 0xEB0A0129u); /* adds or subs x9, x9, x10 */
      exit_if(e, CC_VS, AGC_STATUS_OVERFLOW, pc);
      break;
  }
  store_value(e, in.a, AGC_T_INT, T0);
}

/* Calls FN, whose arguments are in place. */
static void call_fn(agc_emitter *e, uint64_t fn) {
  move_imm64(e, T0, fn);
  put32(e, 0xD63F0120u); /* blr x9 */
}

/* Calls FN, whose arguments are in place, and leaves with its status at PC when it is not 0. */
static void call_status(agc_emitter *e, uint64_t fn, uint32_t pc) {
  call_fn(e, fn);
  size_t ok = skip_zero(e, false, false, X0);
  branch_to(e, AGC_JIT_PATCH_EXIT_STATUS, (uint64_t)pc << 32);
  land(e, ok);
}

/* The first three arguments of a helper call: vm, &R[a], &R[b]. */
static void helper_args(agc_emitter *e, agc_instr in) {
  move_reg(e, true, X0, VM);
  add_imm(e, X1, REGS, TAG(in.a));
  add_imm(e, X2, REGS, TAG(in.b));
}

/* HELPER(vm, &R[a], &R[b]) or, with C, HELPER(vm, &R[a], &R[b], &R[c]): an opcode helper writes R[a] only on
   success, and a status other than OK leaves with the pc, for the interpreter to raise. */
static void call_helper(agc_emitter *e, uint64_t helper, agc_instr in, bool c, uint32_t pc) {
  helper_args(e, in);
  if (c) add_imm(e, X3, REGS, TAG(in.c));
  call_status(e, helper, pc);
}

/* After EQ, NE, SAME, CONCAT and TO_TEXT, as the interpreter does after each: a turn cost leaves for the interpreter
   to apply. */
static void cost_exit(agc_emitter *e, uint32_t pc) {
  load(e, T0, VM, offsetof(agc_vm, task));
  load(e, T0, T0, TASK_FIELD(turn_cost));
  size_t none = skip_zero(e, false, true, T0);
  branch_to(e, AGC_JIT_PATCH_EXIT, agc_emit_exit_word(AGC_JIT_EXIT_COST, pc));
  land(e, none);
}

/* EQ and NE: two Ints inline; any other pair through agc_op_eq or agc_op_ne. */
void A64(equal)(agc_emitter *e, agc_opcode op, agc_instr in, uint32_t pc) {
  bool eq = op == AGC_OP_EQ;
  /* Both tags Int, in one test: ccmp compares R[c]'s tag only when R[b]'s is Int, else sets Z clear (nzcv 0). */
  load32(e, T0, REGS, TAG(in.b));
  load32(e, T1, REGS, TAG(in.c));
  compare_imm(e, false, T0, AGC_T_INT);
  /* ccmp w10, #INT, #0, eq */
  put32(e, 0x7A400800u | (uint32_t)AGC_T_INT << 16 | (uint32_t)CC_EQ << 12 | (uint32_t)T1 << 5);
  size_t slow = skip_if(e, CC_NE);
  load(e, T0, REGS, WORD(in.b));
  load(e, T1, REGS, WORD(in.c));
  compare(e, T0, T1);
  set_bool(e, T0, eq ? CC_EQ : CC_NE);
  store_value(e, in.a, AGC_T_BOOL, T0);
  size_t done = skip(e);
  land(e, slow);
  call_helper(e, (uint64_t)(uintptr_t)(eq ? agc_op_eq : agc_op_ne), in, true, pc);
  land(e, done);
  cost_exit(e, pc);
}

/* MAP_GET: a call of agc_jit_map_get, which leaves for the interpreter on a missing key or a wrong tag; a String key's
   charge leaves to be applied, as the interpreter applies it after the instruction. */
void A64(map_get)(agc_emitter *e, agc_instr in, uint32_t pc) {
  call_helper(e, (uint64_t)(uintptr_t)agc_jit_map_get, in, true, pc);
  cost_exit(e, pc);
}

/* LIST: agc_jit_list(vm, &R[a], &R[b], c), which never fails, so no status to test. */
void A64(list)(agc_emitter *e, agc_instr in) {
  helper_args(e, in);
  move_imm32(e, X3, in.c);
  call_fn(e, (uint64_t)(uintptr_t)agc_jit_list);
}

/* CLOSURE: agc_jit_closure(&R[a], bx, captures), which never fails, so no status to test. */
void A64(closure)(agc_emitter *e, agc_instr in, uint32_t captures) {
  add_imm(e, X0, REGS, TAG(in.a));
  move_imm32(e, X1, (uint32_t)in.b | ((uint32_t)in.c << 16));
  move_imm32(e, X2, captures);
  call_fn(e, (uint64_t)(uintptr_t)agc_jit_closure);
}

/* STRUCT and ENUM: FN(&R[a], &R[b], x, y), which never fails, so no status to test. */
void A64(new)(agc_emitter *e, agc_instr in, uint64_t fn, uint64_t x, uint64_t y) {
  add_imm(e, X0, REGS, TAG(in.a));
  add_imm(e, X1, REGS, TAG(in.b));
  move_imm64(e, X2, x);
  move_imm64(e, X3, y);
  call_fn(e, fn);
}

/* STRUCT_WITH: agc_jit_struct_with(vm, &R[a], &R[b], update), which leaves for the interpreter on a receiver of
   another struct, and applies the copy's charge itself, leaving with YIELD when that ends the turn. */
void A64(struct_with)(agc_emitter *e, agc_instr in, uint32_t pc, uint64_t update) {
  helper_args(e, in);
  move_imm64(e, X3, update);
  call_status(e, (uint64_t)(uintptr_t)agc_jit_struct_with, pc);
}

/* One call of an opcode HELPER (with R[c] when TWO), then the cost exit when CHARGED, as on x86-64. */
void A64(helper)(agc_emitter *e, uint64_t helper, bool two, bool charged, agc_instr in, uint32_t pc) {
  call_helper(e, helper, in, two, pc);
  if (charged) cost_exit(e, pc);
}

/* x11 = the object R[b] points to, once its tag is TAG. */
static void object(agc_emitter *e, uint32_t b, agc_tag tag, uint32_t pc) {
  tag_or_interpret(e, b, tag, pc);
  load(e, T2, REGS, WORD(b));
}

/* The 32-bit count at [x11 + AT] must be above INDEX, else the interpreter runs the instruction (and fails with its
   RUNTIME-INTERNAL on hand-made bytecode); then R[a] = the agc_value at [x11 + FIRST + 16 * INDEX]. */
static void item(agc_emitter *e, uint32_t a, size_t at, size_t first, uint32_t index, uint32_t pc) {
  load32(e, T0, T2, at);
  compare_imm(e, false, T0, index);
  exit_if(e, CC_LS, AGC_JIT_EXIT_INTERPRET, pc);
  copy_value(e, a, T2, first + (size_t)index * sizeof(agc_value));
}

/* The instructions that read a value without a helper, as the interpreter's cases do: NOT (any payload other than 0
   is true, as agc_as_bool reads it), FIELD and PAYLOAD (with the field count check), IS_VARIANT, IS_OK,
   RESULT_VALUE, and TRY and TRY_STEP on an ok Result. Any wrong tag or bad index leaves for the interpreter, and so
   does the error of a TRY, which returns from the frame; R[a] is written last. */
void A64(read)(agc_emitter *e, agc_opcode op, agc_instr in, uint32_t pc) {
  switch (op) {
    case AGC_OP_NOT:
      tag_or_interpret(e, in.b, AGC_T_BOOL, pc);
      load(e, T0, REGS, WORD(in.b));
      compare_imm(e, true, T0, 0);
      set_bool(e, T0, CC_EQ);
      store_value(e, in.a, AGC_T_BOOL, T0);
      break;
    case AGC_OP_FIELD:
    case AGC_OP_PAYLOAD: {
      bool field = op == AGC_OP_FIELD;
      object(e, in.b, field ? AGC_T_STRUCT : AGC_T_ENUM, pc);
      size_t count = field ? offsetof(agc_struct, n) : offsetof(agc_enum, n);
      item(e, in.a, count, field ? offsetof(agc_struct, fields) : offsetof(agc_enum, payload), in.c, pc);
      break;
    }
    case AGC_OP_IS_VARIANT:
      object(e, in.b, AGC_T_ENUM, pc);
      load32(e, T0, T2, offsetof(agc_enum, variant));
      compare_imm(e, false, T0, in.c);
      set_bool(e, T0, CC_EQ);
      store_value(e, in.a, AGC_T_BOOL, T0);
      break;
    case AGC_OP_IS_OK:
      object(e, in.b, AGC_T_RESULT, pc);
      load8(e, T0, T2, offsetof(agc_result, ok));
      store_value(e, in.a, AGC_T_BOOL, T0);
      break;
    default: /* RESULT_VALUE, TRY and TRY_STEP */
      object(e, in.b, AGC_T_RESULT, pc);
      if (op != AGC_OP_RESULT_VALUE) {
        load8(e, T0, T2, offsetof(agc_result, ok));
        size_t ok = skip_zero(e, true, false, T0);
        branch_to(e, AGC_JIT_PATCH_EXIT, agc_emit_exit_word(AGC_JIT_EXIT_INTERPRET, pc));
        land(e, ok);
      }
      copy_value(e, in.a, T2, offsetof(agc_result, value));
      break;
  }
}

void A64(jump)(agc_emitter *e, uint32_t target) { branch_to(e, AGC_JIT_PATCH_LABEL, target); }

/* JUMP_IF_TRUE (WHEN) or JUMP_IF_FALSE: R[a] must be a Bool, whose payload is 0 or 1. */
void A64(branch)(agc_emitter *e, uint32_t a, bool when, uint32_t target, uint32_t pc) {
  need_tag(e, a, AGC_T_BOOL, pc);
  load(e, T0, REGS, WORD(a));
  size_t over = skip_zero(e, !when, true, T0);
  branch_to(e, AGC_JIT_PATCH_LABEL, target);
  land(e, over);
}

void A64(exit)(agc_emitter *e, uint32_t status, uint32_t pc) {
  branch_to(e, AGC_JIT_PATCH_EXIT, agc_emit_exit_word(status, pc));
}

/* The arguments of a builtin call helper: vm, &R[a], BUILTIN and span << 32 | pc + 1. */
static void builtin_args(agc_emitter *e, agc_instr in, uint32_t pc, uint64_t builtin, uint32_t span) {
  move_reg(e, true, X0, VM);
  add_imm(e, X1, REGS, TAG(in.a));
  move_imm64(e, X2, builtin);
  move_imm64(e, X3, ((uint64_t)span << 32) | (pc + 1));
}

/* agc_jit_call_builtin(vm, &R[a], builtin, span << 32 | pc + 1), or agc_jit_call_leaf for a LEAF row: it runs the
   builtin and answers 0 to go on, or the exit (YIELD, RAISE) to return at PC, as an opcode helper's status. A leaf
   at native depth 0 takes the INTERPRET exit instead: with no native call to unwind, run_compiled's plain call of the
   leaf and the entry back cost less than the catch of agc_jit_call_leaf. */
void A64(builtin)(agc_emitter *e, agc_instr in, uint32_t pc, uint64_t builtin, uint32_t span, bool leaf) {
  if (leaf) {
    size_t deep = skip_zero(e, true, true, DEPTH);
    branch_to(e, AGC_JIT_PATCH_EXIT, agc_emit_exit_word(AGC_JIT_EXIT_INTERPRET, pc));
    land(e, deep);
  }
  builtin_args(e, in, pc, builtin, span);
  call_status(e, (uint64_t)(uintptr_t)(leaf ? agc_jit_call_leaf : agc_jit_call_builtin), pc);
}

/* agc_jit_call_plain(vm, &R[a], builtin, span << 32 | pc + 1) once each argument has its tag in PLAIN and, for
   ONE_CHAR, the String in R[a] (its tag checked first) has one character. */
void A64(plain_leaf)(agc_emitter *e, agc_instr in, uint32_t pc, uint64_t builtin, uint32_t span,
                     const agc_jit_plain *plain) {
  for (uint32_t k = 0; k < 2; k++)
    if (plain->tags[k] != AGC_T_VOID) tag_or_interpret(e, (uint32_t)in.a + k, plain->tags[k], pc);
  if (plain->one_char) {
    load(e, T2, REGS, WORD(in.a));
    load(e, T0, T2, offsetof(agc_string, chars));
    compare_imm(e, true, T0, 1);
    exit_if(e, CC_NE, AGC_JIT_EXIT_INTERPRET, pc);
  }
  builtin_args(e, in, pc, builtin, span);
  call_fn(e, (uint64_t)(uintptr_t)agc_jit_call_plain);
}

/* b to the epilogue when CC holds, which returns x0 (and x1, x2) to the caller as they are. */
static void epilogue_if(agc_emitter *e, int cc) {
  size_t over = skip_if(e, cc ^ 1);
  branch_to(e, AGC_JIT_PATCH_EPILOGUE, 0);
  land(e, over);
}

/* CALLEE = the code in the code table's SLOT, read when the call runs, then compared with 0 (EQ when the callee has
   none). The load acquires (ldar), so the code that another thread wrote and published with a release store is seen
   whole; a native call then branches there (call_code), after an isb unless the seal synchronized every core. */
static void load_code(agc_emitter *e, uint64_t slot) {
  move_imm64(e, T1, slot);
  put32(e, 0xC8DFFC00u | (uint32_t)T1 << 5 | (uint32_t)CALLEE); /* ldar x15, [x10] */
  compare_imm(e, true, CALLEE, 0);
}

/* The flags for R + 16 * END against the end of the register file, regs + 16 * reg_capacity, of the task in T0: HI
   when the window would pass it. */
static void compare_room(agc_emitter *e, uint64_t end) {
  load(e, T2, T0, TASK_FIELD(reg_capacity));
  load(e, T3, T0, TASK_FIELD(regs));
  put32(e, 0x8B00118Bu | (uint32_t)T2 << 16); /* add x11, x12, x11, lsl #4 */
  add_imm(e, T3, REGS, TAG(end));
  compare(e, T3, T2);
}

/* T1 = &frames[frame_count - 1], the top frame of the task in T0. */
static void top_frame(agc_emitter *e) {
  load32(e, T1, T0, TASK_FIELD(frame_count));
  load(e, T2, T0, TASK_FIELD(frames));
  put32(e, 0x8B0A156Au); /* add x10, x11, x10, lsl #5 */
  put32(e, 0xD100814Au); /* sub x10, x10, #32 */
}

/* Branches to CALLEE + ENTRY (blr with LINK, else br). The code may be another thread's, just sealed: an isb first
   drops what this core fetched before, unless each seal makes every thread pass such an event (call_isb false; the
   argument is at the seal in jit.c). */
static void call_code(agc_emitter *e, uint32_t entry, bool link) {
  add_imm(e, CALLEE, CALLEE, entry);
  if (e->call_isb) put32(e, 0xD5033FDFu);                       /* isb */
  put32(e, (link ? 0xD63F0000u : 0xD61F0000u) | (uint32_t)CALLEE << 5); /* blr or br x15 */
}

/* After the native call of a callee's code: AGC_JIT_EXIT_RETURNED in w0 hands over its value in x1:x2 for R[a]; the
   callee leaves its own registers as they were, as return_value does (#807). Any other exit word is the callee's (or
   a deeper callee's), with its frame on top, and goes up unchanged. */
static void returned(agc_emitter *e, uint32_t a) {
  compare_imm(e, false, X0, AGC_JIT_EXIT_RETURNED);
  epilogue_if(e, CC_NE);
  store(e, REGS, TAG(a), X1);
  store(e, REGS, WORD(a), X2);
}

/* CALL of function bx with the window at R[a], as a native call when it can be one, as on x86-64: the callee has code
   (load_code), the native depth is below AGC_JIT_NATIVE_DEPTH, and the task has room for the frame, its REGISTERS and
   one more depth without growing an array or failing. The frame is written as push_frame writes it, with the
   caller's pc after the CALL. Anything else exits for run_compiled. */
void A64(call)(agc_emitter *e, agc_instr in, uint32_t pc, uint64_t slot, uint32_t registers) {
  uint32_t function = (uint32_t)in.b | ((uint32_t)in.c << 16);
  compare_imm(e, true, DEPTH, AGC_JIT_NATIVE_DEPTH);
  exit_if(e, CC_HS, AGC_JIT_EXIT_CALL, pc);
  load_code(e, slot);
  exit_if(e, CC_EQ, AGC_JIT_EXIT_CALL, pc);
  load(e, T0, VM, offsetof(agc_vm, task));
  load32(e, T1, T0, TASK_FIELD(frame_count));
  load32(e, T2, T0, TASK_FIELD(frame_capacity));
  put32(e, 0x6B0B015Fu); /* cmp w10, w11 */
  exit_if(e, CC_HS, AGC_JIT_EXIT_CALL, pc);
  load32(e, T1, T0, TASK_FIELD(depth));
  compare_imm(e, false, T1, AGC_MAX_DEPTH);
  exit_if(e, CC_HS, AGC_JIT_EXIT_CALL, pc);
  compare_room(e, (uint64_t)in.a + registers);
  exit_if(e, CC_HI, AGC_JIT_EXIT_CALL, pc);
  /* T1 = the caller's frame, the top one; the callee's is the next. */
  top_frame(e);
  move_imm32(e, T3, pc + 1);
  store32(e, T1, FRAME_FIELD(pc), T3);
  load32(e, T3, T1, FRAME_FIELD(base));
  add_imm(e, T3, T3, in.a);
  store32(e, T1, 32 + FRAME_FIELD(base), T3);
  store32(e, T1, 32 + FRAME_FIELD(ret), T3);
  move_imm32(e, T3, function);
  store32(e, T1, 32 + FRAME_FIELD(function), T3);
  store32(e, T1, 32 + FRAME_FIELD(pc), ZR);
  store8(e, T1, 32 + FRAME_FIELD(tail), ZR);
  store(e, T1, 32 + FRAME_FIELD(native), ZR);
  bump32(e, T0, TASK_FIELD(frame_count), 1);
  bump32(e, T0, TASK_FIELD(depth), 1);
  add_imm(e, X1, REGS, TAG(in.a));
  call_code(e, A64_NATIVE_ENTRY, true);
  returned(e, in.a);
}

/* The TAIL_CALL exit at PC when CC holds (always for CC < 0). With COUNTER, the jit trace's agc_jit_count_tail(COUNTER,
   SLOT) runs first, which counts it (and whether the callee in SLOT had code). */
static void tail_exit(agc_emitter *e, int cc, uint32_t pc, uint64_t counter, uint64_t slot) {
  if (!counter) {
    if (cc < 0)
      A64(exit)(e, AGC_JIT_EXIT_TAIL_CALL, pc);
    else
      exit_if(e, cc, AGC_JIT_EXIT_TAIL_CALL, pc);
    return;
  }
  size_t over = cc < 0 ? 0 : skip_if(e, cc ^ 1);
  move_imm64(e, X0, counter);
  move_imm64(e, X1, slot);
  call_fn(e, (uint64_t)(uintptr_t)agc_jit_count_tail);
  A64(exit)(e, AGC_JIT_EXIT_TAIL_CALL, pc);
  if (cc >= 0) land(e, over);
}

/* TAIL_CALL of function bx with the window at R[a], in place, as on x86-64 (agc_emit_tail_call there): the top frame
   takes the callee's PARAMS arguments into R[0..) and becomes the callee's (pc 0, tail set). For itself (SELF) that is
   a branch to instruction 0; another function needs code and room for its REGISTERS, and then the code branches to
   its tail entry at the same native depth, on the same C stack. Anything else takes the TAIL_CALL exit with nothing
   changed. */
void A64(tail_call)(agc_emitter *e, agc_instr in, uint32_t pc, bool self, uint64_t slot, uint32_t params,
                    uint32_t registers, uint64_t counter) {
  if (params > AGC_JIT_TAIL_PARAMS) {
    tail_exit(e, -1, pc, counter, slot);
    return;
  }
  if (!self) {
    load_code(e, slot);
    tail_exit(e, CC_EQ, pc, counter, slot);
    load(e, T0, VM, offsetof(agc_vm, task));
    compare_room(e, registers);
    tail_exit(e, CC_HI, pc, counter, slot);
  }
  /* The window is copied upwards one register at a time, which is right as R[k] is never above R[a + k]. */
  for (uint32_t k = 0; in.a && k < params; k++) A64(move)(e, k, (uint32_t)in.a + k);
  load(e, T0, VM, offsetof(agc_vm, task));
  top_frame(e);
  if (!self) {
    move_imm32(e, T3, (uint32_t)in.b | ((uint32_t)in.c << 16));
    store32(e, T1, FRAME_FIELD(function), T3);
  }
  store32(e, T1, FRAME_FIELD(pc), ZR);
  move_imm32(e, T3, 1);
  store8(e, T1, FRAME_FIELD(tail), T3);
  if (self) {
    A64(jump)(e, 0);
    return;
  }
  call_code(e, A64_TAIL_ENTRY, false);
}

/* CALL_VALUE of the function value in R[a] with in.b arguments after it, as a native call when it can be one: below
   AGC_JIT_NATIVE_DEPTH, agc_jit_call_value(vm, &R[a], argc, pc) checks the value and the room, pushes the frame as
   call_value does, and returns the callee's code (read with an acquire load), called at its native entry. A NULL
   answer takes the CALL_VALUE exit with nothing pushed. */
void A64(call_value)(agc_emitter *e, agc_instr in, uint32_t pc) {
  compare_imm(e, true, DEPTH, AGC_JIT_NATIVE_DEPTH);
  exit_if(e, CC_HS, AGC_JIT_EXIT_CALL_VALUE, pc);
  move_reg(e, true, X0, VM);
  add_imm(e, X1, REGS, TAG(in.a));
  move_imm32(e, X2, in.b);
  move_imm32(e, X3, pc);
  call_fn(e, (uint64_t)(uintptr_t)agc_jit_call_value);
  move_reg(e, true, CALLEE, X0);
  compare_imm(e, true, CALLEE, 0);
  exit_if(e, CC_EQ, AGC_JIT_EXIT_CALL_VALUE, pc);
  add_imm(e, X1, REGS, TAG((uint64_t)in.a + 1));
  call_code(e, A64_NATIVE_ENTRY, true);
  returned(e, in.a);
}

/* RETURN R[a]: under a native call (x22 above 0), the frame popped as return_value pops it, and
   AGC_JIT_EXIT_RETURNED with R[a] in x1:x2 for the caller's code (returned). Else agc_jit_block_return(vm, &R[a])
   first: when the frame returns to a block call that calls the same function again, the frame starts over with the
   next arguments, and the code goes on at instruction 0 with its registers (or takes the YIELD exit at
   AGC_JIT_PC_RESTART when the turn ended, which leaves the frame's pc at 0); otherwise the RETURN exit for
   run_compiled. */
void A64(return)(agc_emitter *e, uint32_t a, uint32_t pc) {
  size_t native = skip_zero(e, true, true, DEPTH);
  move_reg(e, true, X0, VM);
  add_imm(e, X1, REGS, TAG(a));
  call_fn(e, (uint64_t)(uintptr_t)agc_jit_block_return);
  size_t again = skip_zero(e, true, true, X0);
  branch_to(e, AGC_JIT_PATCH_EXIT, agc_emit_exit_word(AGC_JIT_EXIT_RETURN, pc));
  land(e, again);
  move_reg(e, true, REGS, X0);
  load8(e, T0, VM, offsetof(agc_vm, yield));
  size_t go_on = skip_zero(e, false, false, T0);
  branch_to(e, AGC_JIT_PATCH_EXIT, agc_emit_exit_word(AGC_JIT_EXIT_YIELD, AGC_JIT_PC_RESTART));
  land(e, go_on);
  A64(jump)(e, 0);
  land(e, native);
  load(e, X1, REGS, TAG(a));
  load(e, X2, REGS, WORD(a));
  load(e, T0, VM, offsetof(agc_vm, task));
  bump32(e, T0, TASK_FIELD(frame_count), -1);
  bump32(e, T0, TASK_FIELD(depth), -1);
  move_imm32(e, X0, AGC_JIT_EXIT_RETURNED);
  branch_to(e, AGC_JIT_PATCH_EPILOGUE, 0);
}

/* b from FROM to TO, both byte offsets in the code, which is at most AGC_JIT_CODE_CAP long: in range of the 26-bit
   word offset either way. The entry's movz/movk carry the table's distance in 32 bits, which the cap also bounds. */
_Static_assert(AGC_JIT_CODE_CAP < (128u << 20), "a b reaches 128 MiB either way: every target in the code is in range");
static uint32_t b_to(size_t from, size_t to) {
  int64_t words = ((int64_t)to - (int64_t)from) / 4;
  return 0x14000000u | ((uint32_t)words & 0x3FFFFFFu);
}

/* The stub of an exit: x0 = the exit word (with the helper's status for EXIT_STATUS), then back to the epilogue. */
static void exit_stub(agc_emitter *e, agc_jit_patch p, size_t epilogue) {
  if (p.kind == AGC_JIT_PATCH_EXIT_STATUS) {
    move_reg(e, false, X0, X0); /* the helper's status, high half cleared */
    move_imm64(e, X1, p.value);
    put32(e, 0xAA010000u); /* orr x0, x0, x1 */
  } else {
    move_imm64(e, X0, p.value);
  }
  size_t back = skip(e);
  put32_at(e, back, b_to(back, epilogue));
}

static void link_b(agc_emitter *e, size_t at, size_t to) { put32_at(e, at, b_to(at, to)); }

/* The epilogue, the stubs of the exits (one for each run of patches with the same exit word), then the table of
   entry offsets, each relative to the table, which the entry's adr and movz/movk find. */
size_t A64(end)(agc_emitter *e) {
  if (e->failed) return 0;
  size_t epilogue = e->len;
  put32(e, 0xA9425BF5u); /* ldp x21, x22, [sp, #32] */
  put32(e, 0xA94153F3u); /* ldp x19, x20, [sp, #16] */
  put32(e, 0xA8C37BFDu); /* ldp x29, x30, [sp], #48 */
  put32(e, 0xD65F03C0u); /* ret */
  if (!agc_emit_patches(e, epilogue, exit_stub, link_b)) return 0;
  size_t table = e->len;
  for (uint32_t pc = 0; pc < e->count; pc++) {
    if (!grow(e)) break;
    put32_at(e, e->len, (uint32_t)(int32_t)((int64_t)e->labels[pc] - (int64_t)table));
    e->len += 4;
  }
  if (e->failed) return 0;
  uint32_t distance = (uint32_t)(table - e->entry);
  put32_at(e, e->entry + 4, word_at(e, e->entry + 4) | (distance & 0xFFFF) << 5);
  put32_at(e, e->entry + 8, word_at(e, e->entry + 8) | (distance >> 16) << 5);
  return e->len;
}
#endif
