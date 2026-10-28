/*
 * The x86-64 emitter of the JIT (docs/vm/05-values-execution-builtins.md §6.4): the machine code of each instruction
 * kind, the exit stubs and the entry table, for the System V and the Windows x64 calling conventions. Compiled code
 * keeps the VM in rbx, the registers R in r12, the constants K in r13 and its depth of native calls in r14. Core layer.
 */
#include "jit.h"

#if AGC_JIT_HOST
#include <stddef.h>
#include <string.h>

/* The general registers by their encoding number. */
enum { RAX, RCX, RDX, RBX, RSP, RBP, RSI, RDI, R8, R9, R10, R11, R12, R13, R14, R15 };

/* Condition codes: the low nibble of jcc (0F 80+cc) and setcc (0F 90+cc). */
enum { CC_O = 0x0, CC_AE = 0x3, CC_E = 0x4, CC_NE = 0x5, CC_BE = 0x6, CC_A = 0x7, CC_L = 0xC, CC_LE = 0xE };

/* The argument registers of the calling convention: compiled code is called with (vm, R, K, pc), and calls a helper
   with (vm, dst, a, b). Windows x64 also wants 32 bytes of shadow space above the return address. */
#ifdef _WIN32
#define ARG0 RCX
#define ARG1 RDX
#define ARG2 R8
#define ARG3 R9
#else
#define ARG0 RDI
#define ARG1 RSI
#define ARG2 RDX
#define ARG3 RCX
#endif

#define VM RBX
#define REGS R12
#define CONSTS R13
#define DEPTH R14
/* The shadow space and 8 bytes that keep rsp 16-byte aligned at a helper call, under the 4 saved registers. */
#define FRAME 40

/* A register's tag and payload: registers are 16-byte agc_values, tag at 0 (the full first word is written, as
   agc_word_value builds it) and payload at 8. */
/* Fixed bytes of one instruction (its assembly in a comment beside it). */
#define BYTES(e, ...) put_bytes((e), (const uint8_t[]){__VA_ARGS__}, sizeof((const uint8_t[]){__VA_ARGS__}))

#define TAG(r) ((int64_t)(r) * 16)
#define WORD(r) ((int64_t)(r) * 16 + 8)

/* The frame fields that a native CALL and TAIL_CALL write and RETURN reads (port.h). */
#define FRAME_FIELD(name) ((int64_t)offsetof(agc_frame, name))
#define TASK_FIELD(name) ((int64_t)offsetof(agc_task, name))
#define FIELD_SIZE(type, name) sizeof(((type *)0)->name)

/* agc_emit_call writes a frame as four dwords, a byte and a qword at these offsets, and indexes the frames by a
   shift of 5; it reads frame_count, frame_capacity and depth as dwords and reg_capacity as a qword. */
_Static_assert(sizeof(agc_frame) == 32, "the native CALL indexes frames by a shift of 5");
_Static_assert(offsetof(agc_frame, function) == 0 && offsetof(agc_frame, pc) == 4 && offsetof(agc_frame, base) == 8 &&
                 offsetof(agc_frame, ret) == 12 && offsetof(agc_frame, tail) == 16 &&
                 offsetof(agc_frame, native) == 24,
               "the native CALL writes the frame at these offsets");
_Static_assert(FIELD_SIZE(agc_frame, pc) == 4 && FIELD_SIZE(agc_frame, base) == 4 && FIELD_SIZE(agc_frame, ret) == 4 &&
                 FIELD_SIZE(agc_frame, function) == 4 && FIELD_SIZE(agc_frame, tail) == 1 &&
                 sizeof(agc_native *) == 8,
               "the native CALL writes the frame fields with these sizes");
_Static_assert(FIELD_SIZE(agc_task, frame_count) == 4 && FIELD_SIZE(agc_task, frame_capacity) == 4 &&
                 FIELD_SIZE(agc_task, depth) == 4 && FIELD_SIZE(agc_task, reg_capacity) == 8,
               "the native CALL reads the task's counts with these sizes");

/* The two shapes of the opcode helpers (agc_op_* in core.h). */
typedef agc_status (*binary_helper)(agc_vm *, agc_value *, const agc_value *, const agc_value *);
typedef agc_status (*unary_helper)(agc_vm *, agc_value *, const agc_value *);

/* Room for N more bytes, or `failed` past the code cap. Once `failed` is set nothing is written any more: byte,
   put32_at and patch do nothing, so an offset recorded before the failure, whose bytes may be cut off at the cap, is
   never written into, and agc_emit_end lays out nothing. */
static void grow(agc_emitter *e, size_t n) {
  if (e->len + n > AGC_JIT_CODE_CAP) {
    e->failed = true;
    return;
  }
  if (e->len + n <= e->cap) return;
  size_t cap = e->cap ? e->cap : 256;
  while (cap < e->len + n) cap = agc_size_mul(cap, 2);
  uint8_t *code = agc_alloc_atomic(cap);
  if (e->len) memcpy(code, e->code, e->len);
  e->code = code;
  e->cap = cap;
}

static void byte(agc_emitter *e, uint8_t b) {
  if (!e->failed) grow(e, 1);
  if (!e->failed) e->code[e->len++] = b;
}

static void put_bytes(agc_emitter *e, const uint8_t *data, size_t n) {
  for (size_t k = 0; k < n; k++) byte(e, data[k]);
}

static void word32(agc_emitter *e, uint32_t v) {
  for (int k = 0; k < 4; k++) byte(e, (uint8_t)(v >> (8 * k)));
}

static void word64(agc_emitter *e, uint64_t v) {
  for (int k = 0; k < 8; k++) byte(e, (uint8_t)(v >> (8 * k)));
}

/* Writes over 4 bytes that were written before; nothing after a failure, when they may not all be there. */
static void put32_at(agc_emitter *e, size_t at, uint32_t v) {
  if (e->failed) return;
  for (int k = 0; k < 4; k++) e->code[at + (size_t)k] = (uint8_t)(v >> (8 * k));
}

/* A REX prefix: W for 64-bit operands, R, X and B extend the reg, index and base fields. Left out when it adds
   nothing, unless W is set. */
static void rex(agc_emitter *e, bool w, int reg, int base) {
  uint8_t r = (uint8_t)(0x40 | (w ? 8 : 0) | ((reg & 8) ? 4 : 0) | ((base & 8) ? 1 : 0));
  if (r != 0x40) byte(e, r);
}

/* ModRM for [base + disp32] with REG in the reg field. rsp and r12 as a base need a SIB byte. Every memory operand
   takes the 32-bit displacement form, which keeps each instruction's size fixed. */
static void memory(agc_emitter *e, int reg, int base, int64_t disp) {
  if (disp < INT32_MIN || disp > INT32_MAX) {
    e->failed = true;
    disp = 0;
  }
  byte(e, (uint8_t)(0x80 | ((reg & 7) << 3) | (base & 7)));
  if ((base & 7) == RSP) byte(e, 0x24);
  word32(e, (uint32_t)(int32_t)disp);
}

/* OP reg, [base + disp] (or [base + disp], reg for the store forms), with a one-byte or 0F-prefixed opcode. */
static void op_mem(agc_emitter *e, bool w, uint32_t opcode, int reg, int base, int64_t disp) {
  rex(e, w, reg, base);
  if (opcode > 0xFF) byte(e, (uint8_t)(opcode >> 8));
  byte(e, (uint8_t)opcode);
  memory(e, reg, base, disp);
}

static void load(agc_emitter *e, int reg, int base, int64_t disp) { op_mem(e, true, 0x8B, reg, base, disp); }

static void store(agc_emitter *e, int base, int64_t disp, int reg) { op_mem(e, true, 0x89, reg, base, disp); }

/* mov qword [base + disp], imm32 (sign-extended): a tag with the padding word zero. */
static void store_imm(agc_emitter *e, int base, int64_t disp, int32_t imm) {
  op_mem(e, true, 0xC7, 0, base, disp);
  word32(e, (uint32_t)imm);
}

/* cmp dword or qword [base + disp], imm8. */
static void compare_imm8(agc_emitter *e, bool w, int base, int64_t disp, int8_t imm) {
  op_mem(e, w, 0x83, 7, base, disp);
  byte(e, (uint8_t)imm);
}

/* mov DST, SRC on 64 or 32 bits (the 32-bit form clears the high half). */
static void move_reg(agc_emitter *e, bool w, int dst, int src) {
  rex(e, w, src, dst);
  byte(e, 0x89);
  byte(e, (uint8_t)(0xC0 | ((src & 7) << 3) | (dst & 7)));
}

static void lea(agc_emitter *e, int reg, int base, int64_t disp) { op_mem(e, true, 0x8D, reg, base, disp); }

static void move_imm64(agc_emitter *e, int reg, uint64_t imm) {
  rex(e, true, 0, reg);
  byte(e, (uint8_t)(0xB8 | (reg & 7)));
  word64(e, imm);
}

static void push(agc_emitter *e, int reg) {
  rex(e, false, 0, reg);
  byte(e, (uint8_t)(0x50 | (reg & 7)));
}

static void pop(agc_emitter *e, int reg) {
  rex(e, false, 0, reg);
  byte(e, (uint8_t)(0x58 | (reg & 7)));
}

/* A jump with a 32-bit offset still to write (jcc, or jmp for CC < 0); the offset's position. */
static size_t jump_to_patch(agc_emitter *e, int cc) {
  if (cc < 0) {
    byte(e, 0xE9);
  } else {
    byte(e, 0x0F);
    byte(e, (uint8_t)(0x80 | cc));
  }
  size_t at = e->len;
  word32(e, 0);
  return at;
}

/* The offset at AT now points here: a jump forward inside one instruction's code. */
static void land(agc_emitter *e, size_t at) { put32_at(e, at, (uint32_t)(int32_t)(e->len - (at + 4))); }

static void patch(agc_emitter *e, size_t at, agc_jit_patch_kind kind, uint64_t value) {
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

static uint64_t exit_word(uint32_t status, uint32_t pc) { return ((uint64_t)pc << 32) | status; }

/* jcc (or jmp for CC < 0) to the stub that returns STATUS at PC. */
static void exit_if(agc_emitter *e, int cc, uint32_t status, uint32_t pc) {
  patch(e, jump_to_patch(e, cc), AGC_JIT_PATCH_EXIT, exit_word(status, pc));
}

/* The tag of register R must be TAG, else the instruction at PC fails with a wrong tag, as agc_as_int does. */
static void need_tag(agc_emitter *e, uint32_t r, agc_tag tag, uint32_t pc) {
  compare_imm8(e, false, REGS, TAG(r), (int8_t)tag);
  exit_if(e, CC_NE, AGC_STATUS_WRONG_TAG, pc);
}

/* R[a] = RAX with TAG: the full tag word, then the payload. */
static void store_value(agc_emitter *e, uint32_t a, agc_tag tag) {
  store_imm(e, REGS, TAG(a), (int32_t)tag);
  store(e, REGS, WORD(a), RAX);
}

/* setcc al; movzx eax, al: RAX is 0 or 1, the payload of agc_bool. */
static void set_bool(agc_emitter *e, int cc) {
  BYTES(e, 0x0F, (uint8_t)(0x90 | cc), 0xC0, 0x0F, 0xB6, 0xC0);
}

/* Saves the registers compiled code keeps (callee-saved in both conventions) and keeps rsp 16-byte aligned for
   helper calls (4 pushes on the return address, then FRAME). */
static void save_registers(agc_emitter *e) {
  push(e, VM);
  push(e, REGS);
  push(e, CONSTS);
  push(e, DEPTH);
}

void agc_emit_begin(agc_emitter *e, uint32_t count) {
  memset(e, 0, sizeof *e);
  e->count = count;
  e->labels = agc_alloc_atomic(agc_size_mul(count ? count : 1, sizeof *e->labels));
  /* The entry from C at offset 0 jumps over the two entries of compiled code. The tail entry at AGC_JIT_TAIL_ENTRY,
     which a native TAIL_CALL of another function jumps to with everything as it is (the frame's R, the native depth,
     the stack of the caller's code, which every function lays out the same way): instruction 0. The native entry at
     AGC_JIT_NATIVE_ENTRY, which a native CALL of compiled code calls with the callee's R in ARG1, rbx and r13 being
     the same for every function: one more native call deep, then instruction 0. */
  BYTES(e, 0xEB, 0x00); /* jmp short entry */
  size_t over = e->len - 1;
  patch(e, jump_to_patch(e, -1), AGC_JIT_PATCH_LABEL, 0);
  save_registers(e);
  BYTES(e, 0x49, 0xFF, 0xC6);        /* inc r14 */
  BYTES(e, 0x48, 0x83, 0xEC, FRAME); /* sub rsp, 40 */
  move_reg(e, true, REGS, ARG1);
  patch(e, jump_to_patch(e, -1), AGC_JIT_PATCH_LABEL, 0);
  if (!e->failed) e->code[over] = (uint8_t)(e->len - (over + 1));
  /* The entry from C: no native call below, then instruction pc by the table of offsets that agc_emit_end puts after
     the code. */
  save_registers(e);
  BYTES(e, 0x45, 0x31, 0xF6);        /* xor r14d, r14d */
  BYTES(e, 0x48, 0x83, 0xEC, FRAME); /* sub rsp, 40 */
  move_reg(e, true, VM, ARG0);
  move_reg(e, true, REGS, ARG1);
  move_reg(e, true, CONSTS, ARG2);
  move_reg(e, false, RAX, ARG3);
  BYTES(e, 0x48, 0x8D, 0x0D);             /* lea rcx, [rip + table] */
  e->entry = (uint32_t)e->len;
  word32(e, 0);
  BYTES(e, 0x48, 0x63, 0x04, 0x81);       /* movsxd rax, dword [rcx + rax*4] */
  BYTES(e, 0x48, 0x01, 0xC8);             /* add rax, rcx */
  BYTES(e, 0xFF, 0xE0);                   /* jmp rax */
}

void agc_emit_label(agc_emitter *e, uint32_t pc) {
  if (pc < e->count) e->labels[pc] = (uint32_t)e->len;
}

void agc_emit_move(agc_emitter *e, uint32_t a, uint32_t b) {
  load(e, RAX, REGS, TAG(b));
  load(e, RDX, REGS, WORD(b));
  store(e, REGS, TAG(a), RAX);
  store(e, REGS, WORD(a), RDX);
}

void agc_emit_const(agc_emitter *e, uint32_t a, uint32_t k) {
  load(e, RAX, CONSTS, TAG(k));
  load(e, RDX, CONSTS, WORD(k));
  store(e, REGS, TAG(a), RAX);
  store(e, REGS, WORD(a), RDX);
}

/* GLOBAL: the value in the slot, a program table that is never written after the entry function, so no lock; a slot
   with tag Void was never set (hand-made bytecode), and the interpreter fails on it as it does. */
void agc_emit_global(agc_emitter *e, uint32_t a, uint64_t slot, uint32_t pc) {
  move_imm64(e, RAX, slot);
  compare_imm8(e, false, RAX, 0, AGC_T_VOID);
  exit_if(e, CC_E, AGC_JIT_EXIT_INTERPRET, pc);
  load(e, RCX, RAX, 0);
  load(e, RDX, RAX, 8);
  store(e, REGS, TAG(a), RCX);
  store(e, REGS, WORD(a), RDX);
}

/* The STEP's fast path, as the interpreter's: while vm->next_stop > n, take n from it; else exit for the slow path
   (step_slow), which may stop the run, end the turn or take a new batch. next_stop is read from memory each time. */
void agc_emit_step(agc_emitter *e, uint32_t n, uint32_t pc) {
  load(e, RAX, VM, (int64_t)offsetof(agc_vm, next_stop));
  BYTES(e, 0x48, 0x3D); /* cmp rax, n */
  word32(e, n);
  exit_if(e, CC_LE, AGC_JIT_EXIT_STEP, pc);
  BYTES(e, 0x48, 0x2D); /* sub rax, n */
  word32(e, n);
  store(e, VM, (int64_t)offsetof(agc_vm, next_stop), RAX);
}

/* DIV_I and MOD_I: the divisor in rcx is checked for 0 and for -1, where idiv would trap on INT64_MIN: the quotient
   is then the negation (overflow for INT64_MIN) and the remainder 0, as agc_op_div_i and agc_op_mod_i say. */
static void divide(agc_emitter *e, bool mod, agc_instr in, uint32_t pc) {
  load(e, RCX, REGS, WORD(in.c));
  BYTES(e, 0x48, 0x85, 0xC9); /* test rcx, rcx */
  exit_if(e, CC_E, AGC_STATUS_DIVISION_BY_ZERO, pc);
  load(e, RAX, REGS, WORD(in.b));
  BYTES(e, 0x48, 0x83, 0xF9, 0xFF); /* cmp rcx, -1 */
  size_t not_minus_one = jump_to_patch(e, CC_NE);
  if (mod) {
    BYTES(e, 0x31, 0xC0); /* xor eax, eax */
  } else {
    BYTES(e, 0x48, 0xF7, 0xD8); /* neg rax */
    exit_if(e, CC_O, AGC_STATUS_OVERFLOW, pc);
  }
  size_t done = jump_to_patch(e, -1);
  land(e, not_minus_one);
  BYTES(e, 0x48, 0x99);       /* cqo */
  BYTES(e, 0x48, 0xF7, 0xF9); /* idiv rcx */
  if (mod) BYTES(e, 0x48, 0x89, 0xD0); /* mov rax, rdx */
  land(e, done);
}

/* The Int operators and compares, inline: both tags first (WRONG_TAG), then the operation with its overflow check,
   and the result written last, so R[a] is left alone on any exit, as the helpers leave dst. */
void agc_emit_int(agc_emitter *e, agc_opcode op, agc_instr in, uint32_t pc) {
  need_tag(e, in.b, AGC_T_INT, pc);
  if (op == AGC_OP_NEG_I) {
    load(e, RAX, REGS, WORD(in.b));
    BYTES(e, 0x48, 0xF7, 0xD8); /* neg rax */
    exit_if(e, CC_O, AGC_STATUS_OVERFLOW, pc);
    store_value(e, in.a, AGC_T_INT);
    return;
  }
  need_tag(e, in.c, AGC_T_INT, pc);
  switch (op) {
    case AGC_OP_DIV_I:
    case AGC_OP_MOD_I: divide(e, op == AGC_OP_MOD_I, in, pc); break;
    case AGC_OP_LT_I:
    case AGC_OP_LE_I:
      load(e, RAX, REGS, WORD(in.b));
      op_mem(e, true, 0x3B, RAX, REGS, WORD(in.c)); /* cmp rax, [c] */
      set_bool(e, op == AGC_OP_LT_I ? CC_L : CC_LE);
      store_value(e, in.a, AGC_T_BOOL);
      return;
    default:
      load(e, RAX, REGS, WORD(in.b));
      /* add, sub or imul rax, [c] */
      op_mem(e, true, op == AGC_OP_ADD_I ? 0x03 : op == AGC_OP_SUB_I ? 0x2B : 0x0FAF, RAX, REGS, WORD(in.c));
      exit_if(e, CC_O, AGC_STATUS_OVERFLOW, pc);
      break;
  }
  store_value(e, in.a, AGC_T_INT);
}

/* Calls FN, whose arguments are in place. */
static void call_fn(agc_emitter *e, uint64_t fn) {
  move_imm64(e, RAX, fn);
  BYTES(e, 0xFF, 0xD0); /* call rax */
}

/* Calls FN, whose arguments are in place, and leaves with its status at PC when it is not 0. */
static void call_status(agc_emitter *e, uint64_t fn, uint32_t pc) {
  call_fn(e, fn);
  BYTES(e, 0x85, 0xC0); /* test eax, eax */
  patch(e, jump_to_patch(e, CC_NE), AGC_JIT_PATCH_EXIT_STATUS, (uint64_t)pc << 32);
}

/* The first three arguments of a helper call: vm, &R[a], &R[b]. */
static void helper_args(agc_emitter *e, agc_instr in) {
  move_reg(e, true, ARG0, VM);
  lea(e, ARG1, REGS, TAG(in.a));
  lea(e, ARG2, REGS, TAG(in.b));
}

/* HELPER(vm, &R[a], &R[b]) or, with C, HELPER(vm, &R[a], &R[b], &R[c]): an opcode helper writes R[a] only on
   success, and a status other than OK leaves with the pc, for the interpreter to raise. */
static void call_helper(agc_emitter *e, uint64_t helper, agc_instr in, bool c, uint32_t pc) {
  helper_args(e, in);
  if (c) lea(e, ARG3, REGS, TAG(in.c));
  call_status(e, helper, pc);
}

/* After EQ, NE, SAME, CONCAT and TO_TEXT, as the interpreter does after each: a turn cost (a String compare charges
   its bytes, CONCAT its joined bytes, TO_TEXT a compound, String or Json form) leaves
   for the interpreter to apply. */
static void cost_exit(agc_emitter *e, uint32_t pc) {
  load(e, RAX, VM, (int64_t)offsetof(agc_vm, task));
  compare_imm8(e, true, RAX, (int64_t)offsetof(agc_task, turn_cost), 0);
  exit_if(e, CC_NE, AGC_JIT_EXIT_COST, pc);
}

static uint64_t binary(binary_helper helper) { return (uint64_t)(uintptr_t)helper; }

/* EQ and NE: two Ints inline; any other pair through agc_op_eq or agc_op_ne. */
void agc_emit_equal(agc_emitter *e, agc_opcode op, agc_instr in, uint32_t pc) {
  compare_imm8(e, false, REGS, TAG(in.b), AGC_T_INT);
  size_t slow_b = jump_to_patch(e, CC_NE);
  compare_imm8(e, false, REGS, TAG(in.c), AGC_T_INT);
  size_t slow_c = jump_to_patch(e, CC_NE);
  load(e, RAX, REGS, WORD(in.b));
  op_mem(e, true, 0x3B, RAX, REGS, WORD(in.c)); /* cmp rax, [c] */
  set_bool(e, op == AGC_OP_EQ ? CC_E : CC_NE);
  store_value(e, in.a, AGC_T_BOOL);
  size_t done = jump_to_patch(e, -1);
  land(e, slow_b);
  land(e, slow_c);
  call_helper(e, binary(op == AGC_OP_EQ ? agc_op_eq : agc_op_ne), in, true, pc);
  land(e, done);
  cost_exit(e, pc);
}

/* MAP_GET: a call of agc_jit_map_get, which leaves for the interpreter on a missing key or a wrong tag; a String key's
   charge leaves to be applied, as the interpreter applies it after the instruction. */
void agc_emit_map_get(agc_emitter *e, agc_instr in, uint32_t pc) {
  call_helper(e, (uint64_t)(uintptr_t)agc_jit_map_get, in, true, pc);
  cost_exit(e, pc);
}

/* LIST: agc_jit_list(vm, &R[a], &R[b], c), which never fails, so no status to test. */
void agc_emit_list(agc_emitter *e, agc_instr in) {
  helper_args(e, in);
  move_imm64(e, ARG3, in.c);
  call_fn(e, (uint64_t)(uintptr_t)agc_jit_list);
}

/* CLOSURE: agc_jit_closure(&R[a], bx, captures), which never fails, so no status to test. */
void agc_emit_closure(agc_emitter *e, agc_instr in, uint32_t captures) {
  lea(e, ARG0, REGS, TAG(in.a));
  move_imm64(e, ARG1, (uint32_t)in.b | ((uint32_t)in.c << 16));
  move_imm64(e, ARG2, captures);
  call_fn(e, (uint64_t)(uintptr_t)agc_jit_closure);
}

/* STRUCT and ENUM: FN(&R[a], &R[b], x, y), which never fails, so no status to test. */
void agc_emit_new(agc_emitter *e, agc_instr in, uint64_t fn, uint64_t x, uint64_t y) {
  lea(e, ARG0, REGS, TAG(in.a));
  lea(e, ARG1, REGS, TAG(in.b));
  move_imm64(e, ARG2, x);
  move_imm64(e, ARG3, y);
  call_fn(e, fn);
}

/* STRUCT_WITH: agc_jit_struct_with(vm, &R[a], &R[b], update), which leaves for the interpreter on a receiver of
   another struct, and applies the copy's charge itself, leaving with YIELD when that ends the turn. */
void agc_emit_struct_with(agc_emitter *e, agc_instr in, uint32_t pc, uint64_t update) {
  helper_args(e, in);
  move_imm64(e, ARG3, update);
  call_status(e, (uint64_t)(uintptr_t)agc_jit_struct_with, pc);
}

/* The instructions that are one call of their opcode helper, the interpreter's own code: the Float operators and
   compares (so NaN, rounding and the result's bits are the C code's), SAME, CONCAT and TO_TEXT (whose charges the
   cost_exit applies, as the interpreter does), LIST_LEN and LIST_GET (with its bounds
   check, whose INDEX_OUT_OF_RANGE leaves R[b] and R[c] for the message). */
void agc_emit_helper(agc_emitter *e, agc_opcode op, agc_instr in, uint32_t pc) {
  if (op == AGC_OP_NEG_F || op == AGC_OP_LIST_LEN || op == AGC_OP_TO_TEXT) {
    unary_helper one = op == AGC_OP_NEG_F ? agc_op_neg_f : op == AGC_OP_LIST_LEN ? agc_op_list_len : agc_op_to_text;
    call_helper(e, (uint64_t)(uintptr_t)one, in, false, pc);
    if (op == AGC_OP_TO_TEXT) cost_exit(e, pc);
    return;
  }
  binary_helper two;
  switch (op) {
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
  call_helper(e, binary(two), in, true, pc);
  if (op == AGC_OP_SAME || op == AGC_OP_CONCAT) cost_exit(e, pc);
}

/* The tag of register R must be TAG, else the interpreter runs the instruction at PC, and fails as it does. */
static void tag_or_interpret(agc_emitter *e, uint32_t r, agc_tag tag, uint32_t pc) {
  compare_imm8(e, false, REGS, TAG(r), (int8_t)tag);
  exit_if(e, CC_NE, AGC_JIT_EXIT_INTERPRET, pc);
}

/* rcx = the object R[b] points to, once its tag is TAG. */
static void object(agc_emitter *e, uint32_t b, agc_tag tag, uint32_t pc) {
  tag_or_interpret(e, b, tag, pc);
  load(e, RCX, REGS, WORD(b));
}

/* The 32-bit count at [rcx + AT] must be above INDEX, else the interpreter runs the instruction (and fails with its
   RUNTIME-INTERNAL on hand-made bytecode); then R[a] = the agc_value at [rcx + FIRST + 16 * INDEX], both words read
   before either is written, so R[a] may be R[b]. */
static void item(agc_emitter *e, uint32_t a, size_t at, size_t first, uint32_t index, uint32_t pc) {
  op_mem(e, false, 0x81, 7, RCX, (int64_t)at); /* cmp dword [rcx + at], index */
  word32(e, index);
  exit_if(e, CC_BE, AGC_JIT_EXIT_INTERPRET, pc);
  load(e, RAX, RCX, (int64_t)(first + (size_t)index * sizeof(agc_value)));
  load(e, RDX, RCX, (int64_t)(first + (size_t)index * sizeof(agc_value) + 8));
  store(e, REGS, TAG(a), RAX);
  store(e, REGS, WORD(a), RDX);
}

/* The instructions that read a value without a helper, as the interpreter's cases do: NOT (any payload other than 0
   is true, as agc_as_bool reads it), FIELD and PAYLOAD (with the field count check), IS_VARIANT, IS_OK,
   RESULT_VALUE, and TRY and TRY_STEP on an ok Result. Any wrong tag or bad index leaves for the interpreter, and so
   does the error of a TRY, which returns from the frame; R[a] is written last. */
void agc_emit_read(agc_emitter *e, agc_opcode op, agc_instr in, uint32_t pc) {
  switch (op) {
    case AGC_OP_NOT:
      tag_or_interpret(e, in.b, AGC_T_BOOL, pc);
      compare_imm8(e, true, REGS, WORD(in.b), 0);
      set_bool(e, CC_E);
      store_value(e, in.a, AGC_T_BOOL);
      break;
    case AGC_OP_FIELD:
      object(e, in.b, AGC_T_STRUCT, pc);
      item(e, in.a, offsetof(agc_struct, n), offsetof(agc_struct, fields), in.c, pc);
      break;
    case AGC_OP_PAYLOAD:
      object(e, in.b, AGC_T_ENUM, pc);
      item(e, in.a, offsetof(agc_enum, n), offsetof(agc_enum, payload), in.c, pc);
      break;
    case AGC_OP_IS_VARIANT:
      object(e, in.b, AGC_T_ENUM, pc);
      op_mem(e, false, 0x81, 7, RCX, (int64_t)offsetof(agc_enum, variant)); /* cmp dword [rcx + variant], c */
      word32(e, in.c);
      set_bool(e, CC_E);
      store_value(e, in.a, AGC_T_BOOL);
      break;
    case AGC_OP_IS_OK:
      object(e, in.b, AGC_T_RESULT, pc);
      op_mem(e, false, 0x0FB6, RAX, RCX, (int64_t)offsetof(agc_result, ok)); /* movzx eax, byte [rcx + ok] */
      store_value(e, in.a, AGC_T_BOOL);
      break;
    default: /* RESULT_VALUE, TRY and TRY_STEP */
      object(e, in.b, AGC_T_RESULT, pc);
      if (op != AGC_OP_RESULT_VALUE) {
        op_mem(e, false, 0x80, 7, RCX, (int64_t)offsetof(agc_result, ok)); /* cmp byte [rcx + ok], 0 */
        byte(e, 0);
        exit_if(e, CC_E, AGC_JIT_EXIT_INTERPRET, pc);
      }
      load(e, RAX, RCX, (int64_t)offsetof(agc_result, value));
      load(e, RDX, RCX, (int64_t)offsetof(agc_result, value) + 8);
      store(e, REGS, TAG(in.a), RAX);
      store(e, REGS, WORD(in.a), RDX);
      break;
  }
}

void agc_emit_jump(agc_emitter *e, uint32_t target) {
  patch(e, jump_to_patch(e, -1), AGC_JIT_PATCH_LABEL, target);
}

/* JUMP_IF_TRUE (WHEN) or JUMP_IF_FALSE: R[a] must be a Bool, whose payload is 0 or 1. */
void agc_emit_branch(agc_emitter *e, uint32_t a, bool when, uint32_t target, uint32_t pc) {
  need_tag(e, a, AGC_T_BOOL, pc);
  compare_imm8(e, true, REGS, WORD(a), 0);
  patch(e, jump_to_patch(e, when ? CC_NE : CC_E), AGC_JIT_PATCH_LABEL, target);
}

void agc_emit_exit(agc_emitter *e, uint32_t status, uint32_t pc) { exit_if(e, -1, status, pc); }

/* agc_jit_call_builtin(vm, &R[a], builtin, span << 32 | pc + 1): it runs the builtin and answers 0 to go on, or the
   exit (YIELD, RAISE) to return at PC, as an opcode helper's status. */
void agc_emit_builtin(agc_emitter *e, agc_instr in, uint32_t pc, uint64_t builtin, uint32_t span) {
  move_reg(e, true, ARG0, VM);
  lea(e, ARG1, REGS, TAG(in.a));
  move_imm64(e, ARG2, builtin);
  move_imm64(e, ARG3, ((uint64_t)span << 32) | (pc + 1));
  call_status(e, (uint64_t)(uintptr_t)agc_jit_call_builtin, pc);
}

/* CALL of function bx with the window at R[a], as a native call when it can be one: the callee has code (its slot in
   the code table at SLOT, read when the call runs), the native depth is below AGC_JIT_NATIVE_DEPTH, and the task has
   room for the frame, its REGISTERS and one more depth without growing an array or failing, so no pointer that a
   compiled caller holds moves. The frame is written as push_frame writes it, with the caller's pc after the CALL for
   a stack trace and the return. Anything else, and the frame push that may grow or fail, exits for run_compiled.
   The callee answers AGC_JIT_EXIT_RETURNED after its RETURN, and the code goes on; any other exit word is the
   callee's (or a deeper callee's), with its frame on top, and goes up unchanged. */
void agc_emit_call(agc_emitter *e, agc_instr in, uint32_t pc, uint64_t slot, uint32_t registers) {
  uint32_t function = (uint32_t)in.b | ((uint32_t)in.c << 16);
  BYTES(e, 0x49, 0x81, 0xFE); /* cmp r14, depth */
  word32(e, AGC_JIT_NATIVE_DEPTH);
  exit_if(e, CC_AE, AGC_JIT_EXIT_CALL, pc);
  move_imm64(e, RAX, slot);
  load(e, R11, RAX, 0);
  BYTES(e, 0x4D, 0x85, 0xDB); /* test r11, r11 */
  exit_if(e, CC_E, AGC_JIT_EXIT_CALL, pc);
  load(e, RCX, VM, (int64_t)offsetof(agc_vm, task));
  op_mem(e, false, 0x8B, RAX, RCX, TASK_FIELD(frame_count));    /* mov eax, [rcx + frame_count] */
  op_mem(e, false, 0x3B, RAX, RCX, TASK_FIELD(frame_capacity)); /* cmp eax, [rcx + frame_capacity] */
  exit_if(e, CC_AE, AGC_JIT_EXIT_CALL, pc);
  op_mem(e, false, 0x81, 7, RCX, TASK_FIELD(depth)); /* cmp dword [rcx + depth], AGC_MAX_DEPTH */
  word32(e, AGC_MAX_DEPTH);
  exit_if(e, CC_AE, AGC_JIT_EXIT_CALL, pc);
  /* R + 16 * (a + registers) must not pass regs + 16 * reg_capacity, the end of the register file. */
  load(e, RDX, RCX, TASK_FIELD(reg_capacity));
  BYTES(e, 0x48, 0xC1, 0xE2, 0x04);                        /* shl rdx, 4 */
  op_mem(e, true, 0x03, RDX, RCX, TASK_FIELD(regs));       /* add rdx, [rcx + regs] */
  lea(e, R10, REGS, TAG((uint64_t)in.a + registers));
  BYTES(e, 0x49, 0x39, 0xD2); /* cmp r10, rdx */
  exit_if(e, CC_A, AGC_JIT_EXIT_CALL, pc);
  /* rax = &frames[frame_count], the new frame; the caller's is the one before it. */
  BYTES(e, 0x48, 0xC1, 0xE0, 0x05); /* shl rax, 5 */
  op_mem(e, true, 0x03, RAX, RCX, TASK_FIELD(frames)); /* add rax, [rcx + frames] */
  op_mem(e, false, 0xC7, 0, RAX, FRAME_FIELD(pc) - 32); /* mov dword [rax - 32 + pc], pc + 1 */
  word32(e, pc + 1);
  op_mem(e, false, 0x8B, RDX, RAX, FRAME_FIELD(base) - 32); /* mov edx, [rax - 32 + base] */
  BYTES(e, 0x81, 0xC2);                                     /* add edx, a */
  word32(e, in.a);
  op_mem(e, false, 0x89, RDX, RAX, FRAME_FIELD(base)); /* mov [rax + base], edx */
  op_mem(e, false, 0x89, RDX, RAX, FRAME_FIELD(ret));  /* mov [rax + ret], edx */
  op_mem(e, false, 0xC7, 0, RAX, FRAME_FIELD(function)); /* mov dword [rax + function], bx */
  word32(e, function);
  op_mem(e, false, 0xC7, 0, RAX, FRAME_FIELD(pc)); /* mov dword [rax + pc], 0 */
  word32(e, 0);
  op_mem(e, false, 0xC6, 0, RAX, FRAME_FIELD(tail)); /* mov byte [rax + tail], 0 */
  byte(e, 0);
  store_imm(e, RAX, FRAME_FIELD(native), 0);
  op_mem(e, false, 0xFF, 0, RCX, TASK_FIELD(frame_count)); /* inc dword [rcx + frame_count] */
  op_mem(e, false, 0xFF, 0, RCX, TASK_FIELD(depth));       /* inc dword [rcx + depth] */
  lea(e, ARG1, REGS, TAG(in.a));
  BYTES(e, 0x49, 0x83, 0xC3, AGC_JIT_NATIVE_ENTRY); /* add r11, native entry */
  BYTES(e, 0x41, 0xFF, 0xD3);                       /* call r11 */
  BYTES(e, 0x83, 0xF8, AGC_JIT_EXIT_RETURNED);      /* cmp eax, RETURNED */
  patch(e, jump_to_patch(e, CC_NE), AGC_JIT_PATCH_EPILOGUE, 0);
}

/* The TAIL_CALL exit at PC when CC holds (always for CC < 0). With COUNTER, the jit trace's agc_jit_count_tail(COUNTER,
   SLOT) runs first, which counts it (and whether the callee in SLOT had code): run_compiled's call_exit cannot tell a
   tail call from a call without growing. */
static void tail_exit(agc_emitter *e, int cc, uint32_t pc, uint64_t counter, uint64_t slot) {
  if (!counter) {
    exit_if(e, cc, AGC_JIT_EXIT_TAIL_CALL, pc);
    return;
  }
  size_t over = cc < 0 ? 0 : jump_to_patch(e, cc ^ 1); /* the inverse condition: the low bit of the code */
  move_imm64(e, ARG0, counter);
  move_imm64(e, ARG1, slot);
  call_fn(e, (uint64_t)(uintptr_t)agc_jit_count_tail);
  exit_if(e, -1, AGC_JIT_EXIT_TAIL_CALL, pc);
  if (cc >= 0) land(e, over);
}

/* TAIL_CALL of function bx with the window at R[a], in place, as replace_frame does it: the top frame keeps its base,
   ret and depth, takes the callee's PARAMS arguments from the window into R[0..), and becomes the callee's (pc 0, tail
   set). For itself (SELF) that is a jump to instruction 0. Another function needs code (its slot in the code table at
   SLOT, read when the call runs) and room for its REGISTERS in the register file, as replace_frame would grow it;
   then the code jumps to that code's tail entry, at the same native depth and on the same stack, so a chain of tail
   calls never grows the C stack. run_compiled reads the top frame again after an exit when the frame count changed
   or the frame's tail flag is set, which this sets. Anything else takes the TAIL_CALL exit with nothing changed, for
   run_compiled. The tail call itself charges nothing, as in the interpreter: the callee's
   STEPs do (the loader makes every function that calls start with one). The window is copied upwards one register at
   a time, which is right as R[k] is never above R[a + k]; a callee of more than AGC_JIT_TAIL_PARAMS arguments always
   takes the exit, so that copy stays short. COUNTER, when the jit trace is on, counts each exit (tail_exit). */
void agc_emit_tail_call(agc_emitter *e, agc_instr in, uint32_t pc, bool self, uint64_t slot, uint32_t params,
                        uint32_t registers, uint64_t counter) {
  uint32_t function = (uint32_t)in.b | ((uint32_t)in.c << 16);
  if (params > AGC_JIT_TAIL_PARAMS) {
    tail_exit(e, -1, pc, counter, slot);
    return;
  }
  if (!self) {
    move_imm64(e, RAX, slot);
    load(e, R11, RAX, 0);
    BYTES(e, 0x4D, 0x85, 0xDB); /* test r11, r11 */
    tail_exit(e, CC_E, pc, counter, slot);
  }
  load(e, RCX, VM, (int64_t)offsetof(agc_vm, task));
  if (!self) {
    /* R + 16 * registers must not pass regs + 16 * reg_capacity, the end of the register file. */
    load(e, RDX, RCX, TASK_FIELD(reg_capacity));
    BYTES(e, 0x48, 0xC1, 0xE2, 0x04);                  /* shl rdx, 4 */
    op_mem(e, true, 0x03, RDX, RCX, TASK_FIELD(regs)); /* add rdx, [rcx + regs] */
    lea(e, R10, REGS, TAG(registers));
    BYTES(e, 0x49, 0x39, 0xD2); /* cmp r10, rdx */
    tail_exit(e, CC_A, pc, counter, slot);
  }
  for (uint32_t k = 0; in.a && k < params; k++) agc_emit_move(e, k, (uint32_t)in.a + k);
  /* rax = &frames[frame_count]: the top frame is the one before it. */
  op_mem(e, false, 0x8B, RAX, RCX, TASK_FIELD(frame_count)); /* mov eax, [rcx + frame_count] */
  BYTES(e, 0x48, 0xC1, 0xE0, 0x05);                          /* shl rax, 5 */
  op_mem(e, true, 0x03, RAX, RCX, TASK_FIELD(frames));       /* add rax, [rcx + frames] */
  if (!self) {
    op_mem(e, false, 0xC7, 0, RAX, FRAME_FIELD(function) - 32); /* mov dword [rax - 32 + function], bx */
    word32(e, function);
  }
  op_mem(e, false, 0xC7, 0, RAX, FRAME_FIELD(pc) - 32); /* mov dword [rax - 32 + pc], 0 */
  word32(e, 0);
  op_mem(e, false, 0xC6, 0, RAX, FRAME_FIELD(tail) - 32); /* mov byte [rax - 32 + tail], 1 */
  byte(e, 1);
  if (self) {
    agc_emit_jump(e, 0);
    return;
  }
  BYTES(e, 0x49, 0x83, 0xC3, AGC_JIT_TAIL_ENTRY); /* add r11, tail entry */
  BYTES(e, 0x41, 0xFF, 0xE3);                     /* jmp r11 */
}

/* CALL_VALUE of the function value in R[a] with in.b arguments after it, as a native call when it can be one:
   below AGC_JIT_NATIVE_DEPTH, agc_jit_call_value(vm, &R[a], argc, pc) checks the value and the room and pushes the
   frame (base a + 1, result to R[a]) as call_value does, and returns the callee's code, which is called at its native
   entry as a native CALL calls it. Its native RETURN leaves the result in its R[0], the caller's R[a + 1], which is
   moved to R[a]. A NULL answer takes the CALL_VALUE exit with nothing pushed; an exit of the callee goes up
   unchanged, with its frame on top, whose RETURN then writes R[a] through return_value. */
void agc_emit_call_value(agc_emitter *e, agc_instr in, uint32_t pc) {
  BYTES(e, 0x49, 0x81, 0xFE); /* cmp r14, depth */
  word32(e, AGC_JIT_NATIVE_DEPTH);
  exit_if(e, CC_AE, AGC_JIT_EXIT_CALL_VALUE, pc);
  move_reg(e, true, ARG0, VM);
  lea(e, ARG1, REGS, TAG(in.a));
  move_imm64(e, ARG2, in.b);
  move_imm64(e, ARG3, pc);
  call_fn(e, (uint64_t)(uintptr_t)agc_jit_call_value);
  BYTES(e, 0x48, 0x85, 0xC0); /* test rax, rax */
  exit_if(e, CC_E, AGC_JIT_EXIT_CALL_VALUE, pc);
  lea(e, ARG1, REGS, TAG((uint64_t)in.a + 1));
  BYTES(e, 0x48, 0x83, 0xC0, AGC_JIT_NATIVE_ENTRY); /* add rax, native entry */
  BYTES(e, 0xFF, 0xD0);                             /* call rax */
  BYTES(e, 0x83, 0xF8, AGC_JIT_EXIT_RETURNED);      /* cmp eax, RETURNED */
  patch(e, jump_to_patch(e, CC_NE), AGC_JIT_PATCH_EPILOGUE, 0);
  agc_emit_move(e, in.a, (uint32_t)in.a + 1);
}

/* RETURN R[a]: under a native call, as return_value does it (the frame's ret is its base, R[0], where the native
   CALL put it), and AGC_JIT_EXIT_RETURNED to the caller's code; else the exit for run_compiled. */
void agc_emit_return(agc_emitter *e, uint32_t a, uint32_t pc) {
  BYTES(e, 0x4D, 0x85, 0xF6); /* test r14, r14 */
  exit_if(e, CC_E, AGC_JIT_EXIT_RETURN, pc);
  load(e, RAX, REGS, TAG(a));
  load(e, RDX, REGS, WORD(a));
  store(e, REGS, TAG(0), RAX);
  store(e, REGS, WORD(0), RDX);
  load(e, RCX, VM, (int64_t)offsetof(agc_vm, task));
  op_mem(e, false, 0xFF, 1, RCX, TASK_FIELD(frame_count)); /* dec dword [rcx + frame_count] */
  op_mem(e, false, 0xFF, 1, RCX, TASK_FIELD(depth));       /* dec dword [rcx + depth] */
  byte(e, 0xB8); /* mov eax, RETURNED */
  word32(e, AGC_JIT_EXIT_RETURNED);
  patch(e, jump_to_patch(e, -1), AGC_JIT_PATCH_EPILOGUE, 0);
}

/* The epilogue, the stubs of the exits (one for each run of patches with the same exit word), then the table of
   entry offsets, each relative to the table, which the entry's lea finds rip-relative. */
size_t agc_emit_end(agc_emitter *e) {
  if (e->failed) return 0;
  size_t epilogue = e->len;
  BYTES(e, 0x48, 0x83, 0xC4, FRAME); /* add rsp, 40 */
  pop(e, DEPTH);
  pop(e, CONSTS);
  pop(e, REGS);
  pop(e, VM);
  byte(e, 0xC3); /* ret */
  size_t stub = 0;
  agc_jit_patch last = {0, AGC_JIT_PATCH_LABEL, 0};
  for (size_t k = 0; k < e->patch_count; k++) {
    agc_jit_patch p = e->patches[k];
    size_t to;
    if (p.kind == AGC_JIT_PATCH_LABEL) {
      if (p.value >= e->count) return 0;
      to = e->labels[p.value];
    } else if (p.kind == AGC_JIT_PATCH_EPILOGUE) {
      to = epilogue;
    } else if (p.kind == last.kind && p.value == last.value) {
      to = stub;
    } else {
      to = stub = e->len;
      last = p;
      if (p.kind == AGC_JIT_PATCH_EXIT_STATUS) {
        move_reg(e, false, RAX, RAX); /* mov eax, eax: the helper's status, high half cleared */
        move_imm64(e, RCX, p.value);
        BYTES(e, 0x48, 0x09, 0xC8); /* or rax, rcx */
      } else {
        move_imm64(e, RAX, p.value);
      }
      size_t back = jump_to_patch(e, -1);
      put32_at(e, back, (uint32_t)(int32_t)(epilogue - (back + 4)));
    }
    put32_at(e, p.at, (uint32_t)(int32_t)(to - (p.at + 4)));
  }
  while (!e->failed && e->len % 4) byte(e, AGC_EMIT_PAD);
  size_t table = e->len;
  for (uint32_t pc = 0; pc < e->count; pc++) word32(e, (uint32_t)(int32_t)(e->labels[pc] - table));
  put32_at(e, e->entry, (uint32_t)(int32_t)(table - (e->entry + 4)));
  return e->failed ? 0 : e->len;
}
#endif
