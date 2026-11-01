/*
 * The arm64 emitter (vm/jit/emit_a64.c) on any machine: this file compiles the emitter into itself under the names
 * agc_a64_emit_* (AGC_A64_EMIT_TEST), so it checks the words it writes without running them, beside emit_x64.c on
 * x86-64. The encodings were checked against an assembler (llvm-mc -triple=aarch64 -show-encoding). Running the code
 * is vm/tests/jit_test.c's job, on arm64.
 */
#define AGC_A64_EMIT_TEST 1
#include "../jit/emit_a64.c"

#include "test_support.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

/* The word at byte AT of the code. */
static uint32_t at(const agc_emitter *e, size_t offset) {
  assert(offset + 4 <= e->len);
  return word_at(e, offset);
}

/* The N words from byte START must be WANT. */
static void expect_words(const agc_emitter *e, size_t start, const uint32_t *want, size_t n, const char *what) {
  for (size_t k = 0; k < n; k++)
    if (at(e, start + 4 * k) != want[k]) {
      fprintf(stderr, "jit-a64-test: %s word %zu: got %08x, want %08x\n", what, k, at(e, start + 4 * k), want[k]);
      abort();
    }
}

/* Where the b at byte OFFSET lands. */
static size_t b_target(const agc_emitter *e, size_t offset) {
  uint32_t word = at(e, offset);
  assert((word & 0xFC000000u) == 0x14000000u);
  int32_t rel = (int32_t)(word << 6) >> 6;
  return (size_t)((int64_t)offset + 4 * (int64_t)rel);
}

/* The entry from C, the tail entry and the native entry, and the table that the entry from C reads: its adr and
   movz/movk give the table, whose offsets lead to each instruction. */
static void entries(void) {
  agc_emitter e;
  agc_a64_emit_begin(&e, 2);
  agc_a64_emit_label(&e, 0);
  agc_a64_emit_move(&e, 1, 2);
  agc_a64_emit_label(&e, 1);
  agc_a64_emit_jump(&e, 0);
  size_t size = agc_a64_emit_end(&e);
  assert(size == e.len && size % 4 == 0);
  /* Offset 0 branches over both entries to the entry from C, which saves the frame first. */
  size_t from_c = b_target(&e, 0);
  assert(at(&e, from_c) == 0xA9BD7BFDu);
  /* The tail entry branches to instruction 0; the native entry saves the frame, counts one more depth and takes R. */
  assert(b_target(&e, A64_TAIL_ENTRY) == e.labels[0]);
  static const uint32_t native[] = {
    0xA9BD7BFDu, /* stp x29, x30, [sp, #-48]! */
    0x910003FDu, /* mov x29, sp */
    0xA90153F3u, /* stp x19, x20, [sp, #16] */
    0xA9025BF5u, /* stp x21, x22, [sp, #32] */
    0x910006D6u, /* add x22, x22, #1 */
    0xAA0103F4u, /* mov x20, x1 */
  };
  expect_words(&e, A64_NATIVE_ENTRY, native, sizeof native / sizeof native[0], "native entry");
  assert(b_target(&e, A64_NATIVE_ENTRY + sizeof native) == e.labels[0]);
  /* The table: adr x10, . then movz and movk x11 with its distance. */
  assert(at(&e, e.entry) == 0x1000000Au);
  uint32_t lo = (at(&e, e.entry + 4) >> 5) & 0xFFFF, hi = (at(&e, e.entry + 8) >> 5) & 0xFFFF;
  size_t table = e.entry + (lo | hi << 16);
  assert(table == e.len - 8); /* the two 4-byte offsets */
  for (uint32_t pc = 0; pc < 2; pc++) {
    int32_t offset = (int32_t)at(&e, table + (size_t)4 * pc);
    assert((size_t)((int64_t)table + offset) == e.labels[pc]);
  }
  /* The JUMP at instruction 1 goes back to instruction 0. */
  assert(b_target(&e, e.labels[1]) == e.labels[0]);
}

/* MOVE, CONST and STEP, word for word. */
static void words(void) {
  agc_emitter e;
  agc_a64_emit_begin(&e, 1);
  size_t start = e.len;
  agc_a64_emit_move(&e, 1, 2);
  static const uint32_t move[] = {
    0xF9401289u, /* ldr x9, [x20, #32] */
    0xF940168Au, /* ldr x10, [x20, #40] */
    0xF9000A89u, /* str x9, [x20, #16] */
    0xF9000E8Au, /* str x10, [x20, #24] */
  };
  expect_words(&e, start, move, 4, "MOVE");
  start = e.len;
  agc_a64_emit_const(&e, 3, 1);
  static const uint32_t constant[] = {
    0xF9400AA9u, /* ldr x9, [x21, #16] */
    0xF9400EAAu, /* ldr x10, [x21, #24] */
    0xF9001A89u, /* str x9, [x20, #48] */
    0xF9001E8Au, /* str x10, [x20, #56] */
  };
  expect_words(&e, start, constant, 4, "CONST");
  start = e.len;
  agc_a64_emit_step(&e, 3, 0);
  uint32_t next_stop = (uint32_t)(offsetof(agc_vm, next_stop) / 8);
  const uint32_t step[] = {
    0xF9400269u | next_stop << 10, /* ldr x9, [x19, #next_stop] */
    0xD280006Au,                   /* movz x10, #3 */
    0xEB0A013Fu,                   /* cmp x9, x10 */
    0x5400004Cu,                   /* b.gt over the exit */
    0x14000000u,                   /* b to the STEP exit (written by agc_emit_end) */
    0xCB0A0129u,                   /* sub x9, x9, x10 */
    0xF9000269u | next_stop << 10, /* str x9, [x19, #next_stop] */
  };
  expect_words(&e, start, step, 7, "STEP");
  /* EQ tests both tags in one branch: ccmp compares R[c]'s tag only when R[b]'s is Int. */
  start = e.len;
  agc_a64_emit_equal(&e, AGC_OP_EQ, (agc_instr){0, 1, 2, 3}, 0);
  static const uint32_t equal[] = {
    0xB9402289u, /* ldr w9, [x20, #32] */
    0xB940328Au, /* ldr w10, [x20, #48] */
    0x71000D3Fu, /* cmp w9, #3 */
    0x7A430940u, /* ccmp w10, #3, #0, eq */
    0x54000121u, /* b.ne to the call of agc_op_eq */
  };
  expect_words(&e, start, equal, 5, "EQ");
  /* A register past the scaled 12-bit offsets takes its address in x13 first. */
  start = e.len;
  agc_a64_emit_move(&e, 0, 5000);
  uint32_t first = at(&e, start);
  assert((first & 0xFFC00000u) == 0x91400000u && (first & 0x1F) == AT && ((first >> 5) & 0x1F) == REGS);
  /* A constant whose offset does not fit 32 bits keeps the function interpreted. */
  agc_a64_emit_const(&e, 0, UINT32_MAX);
  assert(agc_a64_emit_end(&e) == 0);
}

/* Every kind of instruction in one function: the code is laid out, each patched b lands inside it, and no word is
   left a b to offset 0 (a patch not written). AGENTICA_A64_DUMP=FILE writes the code for a disassembler. */
static void every_kind(void) {
  agc_emitter e;
  enum { COUNT = 28 };
  agc_a64_emit_begin(&e, COUNT);
  uint32_t pc = 0;
  agc_instr in = {0, 1, 2, 3};
  agc_jit_plain plain = {{AGC_T_STRING, AGC_T_INT}, true};
  agc_a64_emit_label(&e, pc);
  agc_a64_emit_move(&e, 1, 2);
  agc_a64_emit_label(&e, ++pc);
  agc_a64_emit_global(&e, 1, 0x123456789ABCull, pc);
  agc_a64_emit_label(&e, ++pc);
  agc_a64_emit_step(&e, 70000, pc);
  static const agc_opcode ints[] = {AGC_OP_ADD_I, AGC_OP_SUB_I, AGC_OP_MUL_I, AGC_OP_DIV_I,
                                    AGC_OP_MOD_I, AGC_OP_NEG_I, AGC_OP_LT_I,  AGC_OP_LE_I};
  for (size_t k = 0; k < sizeof ints / sizeof ints[0]; k++) {
    agc_a64_emit_label(&e, ++pc);
    agc_a64_emit_int(&e, ints[k], in, pc);
  }
  agc_a64_emit_label(&e, ++pc);
  agc_a64_emit_equal(&e, AGC_OP_EQ, in, pc);
  agc_a64_emit_label(&e, ++pc);
  agc_a64_emit_helper(&e, (uint64_t)(uintptr_t)agc_op_concat, true, true, in, pc);
  agc_a64_emit_label(&e, ++pc);
  agc_a64_emit_read(&e, AGC_OP_FIELD, in, pc);
  agc_a64_emit_label(&e, ++pc);
  agc_a64_emit_read(&e, AGC_OP_TRY, in, pc);
  agc_a64_emit_label(&e, ++pc);
  agc_a64_emit_map_get(&e, in, pc);
  agc_a64_emit_label(&e, ++pc);
  agc_a64_emit_list(&e, in);
  agc_a64_emit_label(&e, ++pc);
  agc_a64_emit_struct_with(&e, in, pc, 0x1000);
  agc_a64_emit_label(&e, ++pc);
  agc_a64_emit_map(&e, in, pc);
  agc_a64_emit_label(&e, ++pc);
  agc_a64_emit_builtin(&e, in, pc, 0x2000, 7, true);
  agc_a64_emit_label(&e, ++pc);
  agc_a64_emit_plain_leaf(&e, in, pc, 0x3000, 7, &plain);
  agc_a64_emit_label(&e, ++pc);
  agc_a64_emit_call(&e, in, pc, 0x4000, 9);
  agc_a64_emit_label(&e, ++pc);
  agc_a64_emit_tail_call(&e, in, pc, false, 0x4000, 2, 9, 0x5000);
  agc_a64_emit_label(&e, ++pc);
  agc_a64_emit_tail_call(&e, in, pc, true, 0x4000, 2, 9, 0);
  agc_a64_emit_label(&e, ++pc);
  agc_a64_emit_call_value(&e, in, pc);
  agc_a64_emit_label(&e, ++pc);
  agc_a64_emit_branch(&e, 1, true, 0, pc);
  agc_a64_emit_label(&e, ++pc);
  agc_a64_emit_return(&e, 1, pc);
  agc_a64_emit_label(&e, ++pc);
  agc_a64_emit_exit(&e, AGC_JIT_EXIT_INTERPRET, pc);
  assert(pc + 1 == COUNT);
  size_t size = agc_a64_emit_end(&e);
  assert(size > 0);
  for (size_t k = 0; k < e.patch_count; k++) {
    size_t to = b_target(&e, e.patches[k].at);
    assert(to > 0 && to < e.len && to % 4 == 0);
  }
  const char *dump = getenv("AGENTICA_A64_DUMP");
  if (dump && *dump) {
    FILE *out = fopen(dump, "w");
    assert(out);
    for (size_t k = 0; k < e.len; k += 4) fprintf(out, ".inst 0x%08x\n", at(&e, k));
    fclose(out);
  }
}

/* The index of the first word from byte START that is WORD, or SIZE_MAX. */
static size_t find_word(const agc_emitter *e, size_t start, uint32_t word) {
  for (size_t k = start; k + 4 <= e->len; k += 4)
    if (at(e, k) == word) return k;
  return SIZE_MAX;
}

/* A native CALL reads the code slot with ldar and runs isb before its blr; a TAIL_CALL of another function runs isb
   before its br; a native RETURN hands over its value in x1 and x2 with RETURNED in w0. */
static void native_calls(void) {
  agc_emitter e;
  agc_a64_emit_begin(&e, 3);
  agc_a64_emit_label(&e, 0);
  agc_a64_emit_call(&e, (agc_instr){0, 2, 1, 0}, 0, 0x4000, 9);
  size_t tail = e.len;
  agc_a64_emit_label(&e, 1);
  agc_a64_emit_tail_call(&e, (agc_instr){0, 2, 1, 0}, 1, false, 0x4000, 2, 9, 0);
  size_t ret = e.len;
  agc_a64_emit_label(&e, 2);
  agc_a64_emit_return(&e, 3, 2);
  size_t size = agc_a64_emit_end(&e);
  assert(size > 0);
  size_t ldar = find_word(&e, e.labels[0], 0xC8DFFD4Fu); /* ldar x15, [x10] */
  size_t isb = find_word(&e, ldar, 0xD5033FDFu);
  assert(ldar < tail && isb < tail && at(&e, isb + 4) == 0xD63F01E0u); /* blr x15 */
  assert(at(&e, isb - 4) == 0x910021EFu);                                   /* add x15, x15, #8: the native entry */
  isb = find_word(&e, tail, 0xD5033FDFu);
  assert(isb < ret && at(&e, isb + 4) == 0xD61F01E0u && at(&e, isb - 4) == 0x910011EFu); /* add #4, br x15 */
  /* The native RETURN: cbnz x22 at its start, and ldr x1, x2 from R[3] (bytes 48 and 56) on that path. */
  assert((at(&e, ret) & 0xFF00001Fu) == 0xB5000000u + DEPTH);
  assert(find_word(&e, ret, 0xF9401A81u) != SIZE_MAX && find_word(&e, ret, 0xF9401E82u) != SIZE_MAX);
}

/* When every seal synchronizes the cores (call_isb false, agc_jit_use_sync), a native CALL and a TAIL_CALL branch
   right after the add of the entry, with no isb anywhere. */
static void calls_without_isb(void) {
  agc_emitter e;
  agc_a64_emit_begin(&e, 2);
  e.call_isb = false;
  agc_a64_emit_label(&e, 0);
  agc_a64_emit_call(&e, (agc_instr){0, 2, 1, 0}, 0, 0x4000, 9);
  agc_a64_emit_label(&e, 1);
  agc_a64_emit_tail_call(&e, (agc_instr){0, 2, 1, 0}, 1, false, 0x4000, 2, 9, 0);
  assert(agc_a64_emit_end(&e) > 0);
  assert(find_word(&e, 0, 0xD5033FDFu) == SIZE_MAX);
  size_t blr = find_word(&e, e.labels[0], 0xD63F01E0u), br = find_word(&e, e.labels[1], 0xD61F01E0u);
  assert(blr < e.labels[1] && at(&e, blr - 4) == 0x910021EFu && br != SIZE_MAX && at(&e, br - 4) == 0x910011EFu);
}

/* The cap: a function whose code would pass AGC_JIT_CODE_CAP fails and writes nothing more. */
static void cap(void) {
  agc_emitter e;
  agc_a64_emit_begin(&e, 1);
  e.len = AGC_JIT_CODE_CAP - 2;
  agc_a64_emit_move(&e, 1, 2);
  assert(e.failed && agc_a64_emit_end(&e) == 0);
}

int main(void) {
  agc_init();
  entries();
  words();
  every_kind();
  native_calls();
  calls_without_isb();
  cap();
  return 0;
}
