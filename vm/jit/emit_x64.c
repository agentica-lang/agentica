/*
 * The x86-64 emitter of the JIT (docs/future/22-jit.md §22): the machine code of each instruction kind, the exit
 * stubs and the entry table, for the System V and the Windows x64 calling conventions. Compiled code keeps the VM in
 * rbx, the registers R in r12 and the constants K in r13. Core layer.
 */
#include "jit.h"

#if AGC_JIT_HOST
#include <stddef.h>
#include <string.h>

/* The general registers by their encoding number. */
enum { RAX, RCX, RDX, RBX, RSP, RBP, RSI, RDI, R8, R9, R10, R11, R12, R13, R14, R15 };

/* Condition codes: the low nibble of jcc (0F 80+cc) and setcc (0F 90+cc). */
enum { CC_O = 0x0, CC_E = 0x4, CC_NE = 0x5, CC_BE = 0x6, CC_L = 0xC, CC_LE = 0xE };

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
#define SHADOW 32

/* A register's tag and payload: registers are 16-byte agc_values, tag at 0 (the full first word is written, as
   agc_word_value builds it) and payload at 8. */
/* Fixed bytes of one instruction (its assembly in a comment beside it). */
#define BYTES(e, ...) put_bytes((e), (const uint8_t[]){__VA_ARGS__}, sizeof((const uint8_t[]){__VA_ARGS__}))

#define TAG(r) ((int64_t)(r) * 16)
#define WORD(r) ((int64_t)(r) * 16 + 8)

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

void agc_emit_begin(agc_emitter *e, uint32_t count) {
  memset(e, 0, sizeof *e);
  e->count = count;
  e->labels = agc_alloc_atomic(agc_size_mul(count ? count : 1, sizeof *e->labels));
  /* The entry: save the registers compiled code keeps (callee-saved in both conventions), keep rsp 16-byte aligned
     for helper calls (3 pushes on the return address) with the shadow space, then jump to instruction pc by the
     table of offsets that agc_emit_end puts after the code. */
  push(e, VM);
  push(e, REGS);
  push(e, CONSTS);
  BYTES(e, 0x48, 0x83, 0xEC, SHADOW); /* sub rsp, 32 */
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

/* HELPER(vm, &R[a], &R[b]) or, with C, HELPER(vm, &R[a], &R[b], &R[c]): an opcode helper writes R[a] only on
   success, and a status other than OK leaves with the pc, for the interpreter to raise. */
static void call_helper(agc_emitter *e, uint64_t helper, agc_instr in, bool c, uint32_t pc) {
  move_reg(e, true, ARG0, VM);
  lea(e, ARG1, REGS, TAG(in.a));
  lea(e, ARG2, REGS, TAG(in.b));
  if (c) lea(e, ARG3, REGS, TAG(in.c));
  move_imm64(e, RAX, helper);
  BYTES(e, 0xFF, 0xD0); /* call rax */
  BYTES(e, 0x85, 0xC0); /* test eax, eax */
  patch(e, jump_to_patch(e, CC_NE), AGC_JIT_PATCH_EXIT_STATUS, (uint64_t)pc << 32);
}

/* After EQ, NE and SAME, as the interpreter does after each: a turn cost (a String compare charges its bytes) leaves
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

/* The instructions that are one call of their opcode helper, the interpreter's own code: the Float operators and
   compares (so NaN, rounding and the result's bits are the C code's), SAME, LIST_LEN and LIST_GET (with its bounds
   check, whose INDEX_OUT_OF_RANGE leaves R[b] and R[c] for the message). */
void agc_emit_helper(agc_emitter *e, agc_opcode op, agc_instr in, uint32_t pc) {
  if (op == AGC_OP_NEG_F || op == AGC_OP_LIST_LEN) {
    unary_helper one = op == AGC_OP_NEG_F ? agc_op_neg_f : agc_op_list_len;
    call_helper(e, (uint64_t)(uintptr_t)one, in, false, pc);
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
    default: two = agc_op_list_get; break;
  }
  call_helper(e, binary(two), in, true, pc);
  if (op == AGC_OP_SAME) cost_exit(e, pc);
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
   is true, as agc_as_bool reads it), FIELD and PAYLOAD (with the field count check), IS_VARIANT, IS_OK and
   RESULT_VALUE. Any wrong tag or bad index leaves for the interpreter, and R[a] is written last. */
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
    default: /* RESULT_VALUE */
      object(e, in.b, AGC_T_RESULT, pc);
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

/* The epilogue, the stubs of the exits (one for each run of patches with the same exit word), then the table of
   entry offsets, each relative to the table, which the entry's lea finds rip-relative. */
size_t agc_emit_end(agc_emitter *e) {
  if (e->failed) return 0;
  size_t epilogue = e->len;
  BYTES(e, 0x48, 0x83, 0xC4, SHADOW); /* add rsp, 32 */
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
  while (!e->failed && e->len % 4) byte(e, 0xCC);
  size_t table = e->len;
  for (uint32_t pc = 0; pc < e->count; pc++) word32(e, (uint32_t)(int32_t)(e->labels[pc] - table));
  put32_at(e, e->entry, (uint32_t)(int32_t)(table - (e->entry + 4)));
  return e->failed ? 0 : e->len;
}
#endif
