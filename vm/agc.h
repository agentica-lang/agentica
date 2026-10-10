#ifndef AGC_H
#define AGC_H

#include <setjmp.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#define AGC_FORMAT_VERSION 1
#define AGC_MAX_FILE_BYTES ((size_t)256 * 1024 * 1024)
#define AGC_MAX_DEPTH 10000
#define AGC_MAX_REGISTERS ((size_t)1 << 24)
#define AGC_FLOAT_TEXT 40

typedef enum { AGC_T_VOID = 0, AGC_T_NIL, AGC_T_BOOL, AGC_T_INT, AGC_T_FLOAT, AGC_T_STRING, AGC_T_LIST } agc_tag;

typedef struct {
  uint32_t tag;
  union { bool b; int64_t i; double f; void *p; } as;
} agc_value;

typedef struct {
  size_t bytes, chars;
  char data[];
} agc_string;

typedef struct {
  size_t len;
  agc_value items[];
} agc_list;

typedef enum {
  AGC_OP_MOVE, AGC_OP_CONST, AGC_OP_STEP,
  AGC_OP_ADD_I, AGC_OP_SUB_I, AGC_OP_MUL_I, AGC_OP_DIV_I, AGC_OP_MOD_I, AGC_OP_NEG_I,
  AGC_OP_NOT, AGC_OP_LT_I, AGC_OP_LE_I, AGC_OP_EQ, AGC_OP_NE,
  AGC_OP_JUMP, AGC_OP_JUMP_IF_FALSE, AGC_OP_JUMP_IF_TRUE,
  AGC_OP_CALL, AGC_OP_CALL_BUILTIN, AGC_OP_RETURN,
  AGC_OP_ADD_F, AGC_OP_SUB_F, AGC_OP_MUL_F, AGC_OP_DIV_F, AGC_OP_NEG_F, AGC_OP_LT_F, AGC_OP_LE_F,
  AGC_OP_CONCAT, AGC_OP_TO_TEXT, AGC_OP_INSPECT,
  AGC_OP_LIST, AGC_OP_LIST_LEN, AGC_OP_LIST_GET,
  AGC_OP_COUNT
} agc_opcode;

typedef struct { uint16_t op, a, b, c; } agc_instr;

typedef struct { uint32_t source, start_line, start_column, end_line, end_column; } agc_span;

typedef struct {
  agc_string *name;
  agc_string *text;
  uint32_t lines;
  uint32_t *line_start;
  uint32_t *line_chars;
} agc_source;

typedef struct agc_vm agc_vm;

typedef agc_value (*agc_builtin_fn)(agc_vm *vm, agc_value *args, uint32_t span);

typedef struct {
  const char *name;
  uint32_t arity;
  agc_builtin_fn fn;
} agc_builtin;

typedef struct {
  agc_string *name;
  uint32_t params, captures, registers, span, count;
  agc_instr *code;
  uint32_t *spans;
} agc_function;

typedef struct {
  uint32_t source_count, span_count, constant_count, builtin_count, function_count, entry;
  agc_source *sources;
  agc_span *spans;
  agc_value *constants;
  const agc_builtin **builtins;
  agc_function *functions;
} agc_program;

typedef struct { uint32_t function, pc, base; } agc_frame;

typedef enum { AGC_DONE, AGC_FAILED } agc_outcome_kind;

typedef enum { AGC_STYLE_PLAIN, AGC_STYLE_AI, AGC_STYLE_JSON } agc_style;

typedef struct {
  agc_outcome_kind kind;
  const char *code;
  const char *message;
  uint32_t span;
} agc_outcome;

struct agc_vm {
  const agc_program *program;
  FILE *out, *err;
  int64_t steps_left;
  agc_value *regs;
  size_t reg_capacity;
  agc_frame *frames;
  uint32_t frame_capacity, depth;
  agc_outcome outcome;
  jmp_buf fail;
};

void agc_init(void);
void *agc_alloc(size_t size);
void *agc_alloc_atomic(size_t size);
size_t agc_size_add(size_t a, size_t b);
size_t agc_size_mul(size_t a, size_t b);
void agc_out_of_memory(void);
unsigned agc_gc_version(void);

agc_value agc_void(void);
agc_value agc_nil(void);
agc_value agc_bool(bool b);
agc_value agc_int(int64_t i);
agc_value agc_float(double f);
agc_value agc_string_value(agc_string *s);
agc_value agc_list_value(agc_list *l);
bool agc_as_bool(agc_vm *vm, agc_value v);
int64_t agc_as_int(agc_vm *vm, agc_value v);
double agc_as_float(agc_vm *vm, agc_value v);
agc_string *agc_as_string(agc_vm *vm, agc_value v);
agc_list *agc_as_list(agc_vm *vm, agc_value v);
bool agc_is(agc_value v, agc_tag tag);

size_t agc_float_text(double x, char out[AGC_FLOAT_TEXT]);
size_t agc_utf8_width(uint8_t lead);
bool agc_utf8_chars(const uint8_t *data, size_t len, size_t *chars);
agc_string *agc_new_string(size_t bytes, size_t chars);
agc_string *agc_make_string(const char *data, size_t bytes, size_t chars);
agc_list *agc_new_list(size_t len);

extern const uint32_t agc_write_raw_ranges[][2];
extern const size_t agc_write_raw_count;
extern const uint32_t agc_write_joiner_ranges[][2];
extern const size_t agc_write_joiner_count;
extern const uint32_t agc_write_blank_ranges[][2];
extern const size_t agc_write_blank_count;
bool agc_write_raw(uint32_t cp);
size_t agc_write_form(const agc_string *s, char *out, size_t *chars);
agc_string *agc_concat(const agc_string *a, const agc_string *b);
size_t agc_scalar_text(agc_vm *vm, agc_value v, char text[AGC_FLOAT_TEXT]);
agc_string *agc_text(agc_vm *vm, agc_value v);
agc_string *agc_debug(agc_vm *vm, agc_value v);

const agc_builtin *agc_find_builtin(const uint8_t *name, size_t len, uint32_t arity);

bool agc_load(const uint8_t *data, size_t len, agc_program **program, char *error, size_t error_size);

void agc_vm_init(agc_vm *vm, const agc_program *program, FILE *out, FILE *err, int64_t max_steps);
agc_outcome agc_vm_run(agc_vm *vm);
_Noreturn void agc_fail(agc_vm *vm, const char *code, const char *message, uint32_t span);
void agc_write(agc_vm *vm, FILE *stream, const void *data, size_t len);

void agc_print_diagnostic(FILE *err, const agc_program *program, const agc_outcome *outcome, agc_style style);

int agc_fuzz_one(const uint8_t *data, size_t len);

#endif
