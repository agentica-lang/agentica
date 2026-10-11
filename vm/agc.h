#ifndef AGC_H
#define AGC_H

#include <setjmp.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#define AGC_FORMAT_VERSION 3
#define AGC_MAX_FILE_BYTES ((size_t)256 * 1024 * 1024)
#define AGC_MAX_DEPTH 10000
#define AGC_MAX_REGISTERS ((size_t)1 << 24)
#define AGC_MAX_MAP_CHUNK 255u
#define AGC_MAX_TYPES 65535u
#define AGC_MAX_TYPE_DEPTH 1024u
#define AGC_SCALAR_TEXT 48
_Static_assert(AGC_SCALAR_TEXT >= 44, "range text needs 44 bytes");
#define AGC_MAX_READ_BYTES ((int64_t)1024 * 1024)
#define AGC_MAX_LIST_COUNT ((int64_t)1024 * 1024)

typedef enum {
  AGC_T_VOID = 0, AGC_T_NIL, AGC_T_BOOL, AGC_T_INT, AGC_T_FLOAT, AGC_T_STRING, AGC_T_LIST, AGC_T_MAP, AGC_T_STRUCT, AGC_T_ENUM, AGC_T_RESULT, AGC_T_FN, AGC_T_RANGE, AGC_T_JSON, AGC_T_HANDLE
} agc_tag;

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

typedef struct agc_hamt agc_hamt;

typedef struct agc_keys {
  agc_value key;
  struct agc_keys *next;
} agc_keys;

typedef struct {
  size_t size;
  agc_hamt *table;
  agc_keys *reversed;
} agc_map;

typedef struct {
  uint32_t type, n;
  agc_value fields[];
} agc_struct;

typedef struct {
  uint32_t variant, n;
  agc_value payload[];
} agc_enum;

typedef struct {
  bool ok;
  agc_value value;
} agc_result;

typedef struct {
  uint32_t function, n;
  agc_value captured[];
} agc_fn;

typedef struct {
  int64_t start, end;
  bool exclusive;
} agc_range;

typedef enum {
  AGC_JSON_NULL, AGC_JSON_BOOL, AGC_JSON_INT, AGC_JSON_BIG, AGC_JSON_FLOAT, AGC_JSON_STRING, AGC_JSON_ARRAY, AGC_JSON_OBJECT
} agc_json_kind;

typedef struct {
  agc_string *key;
  agc_value value;
} agc_json_member;

typedef struct {
  agc_json_kind kind;
  agc_value scalar;
  size_t count;
  agc_json_member *members;
} agc_json;

typedef struct {
  char *data;
  size_t len, cap;
} agc_json_buffer;

typedef enum {
  AGC_JSON_PARSED, AGC_JSON_CONTROL, AGC_JSON_INVALID, AGC_JSON_EMPTY, AGC_JSON_TRAILING, AGC_JSON_NOT_FINITE
} agc_json_status;

typedef enum {
  AGC_OP_MOVE, AGC_OP_CONST, AGC_OP_STEP,
  AGC_OP_ADD_I, AGC_OP_SUB_I, AGC_OP_MUL_I, AGC_OP_DIV_I, AGC_OP_MOD_I, AGC_OP_NEG_I,
  AGC_OP_NOT, AGC_OP_LT_I, AGC_OP_LE_I, AGC_OP_EQ, AGC_OP_NE,
  AGC_OP_JUMP, AGC_OP_JUMP_IF_FALSE, AGC_OP_JUMP_IF_TRUE,
  AGC_OP_CALL, AGC_OP_CALL_BUILTIN, AGC_OP_RETURN,
  AGC_OP_ADD_F, AGC_OP_SUB_F, AGC_OP_MUL_F, AGC_OP_DIV_F, AGC_OP_NEG_F, AGC_OP_LT_F, AGC_OP_LE_F,
  AGC_OP_CONCAT, AGC_OP_TO_TEXT, AGC_OP_INSPECT,
  AGC_OP_LIST, AGC_OP_LIST_LEN, AGC_OP_LIST_GET,
  AGC_OP_STRUCT, AGC_OP_FIELD, AGC_OP_ENUM, AGC_OP_IS_VARIANT, AGC_OP_PAYLOAD, AGC_OP_SAME,
  AGC_OP_TAIL_CALL,
  AGC_OP_TRY, AGC_OP_IS_OK, AGC_OP_RESULT_VALUE,
  AGC_OP_MAP, AGC_OP_MAP_GET,
  AGC_OP_CALL_VALUE, AGC_OP_CLOSURE,
  AGC_OP_RANGE, AGC_OP_RANGE_BOUNDS,
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

typedef void (*agc_release_fn)(void *native);

typedef struct {
  size_t slot;
  void *native;
  agc_release_fn release;
  agc_value context;
} agc_resource;

typedef struct agc_registry agc_registry;
typedef struct agc_loop agc_loop;

typedef struct {
  void (*work)(void *data);
  agc_value (*done)(agc_vm *vm, void *data, agc_value context);
  agc_value (*expired)(agc_vm *vm, agc_value context);
  void (*drop)(void *data);
} agc_io_kind;

typedef agc_value (*agc_builtin_fn)(agc_vm *vm, agc_value *args, uint32_t span);

typedef enum {
  AGC_NATIVE_NONE, AGC_NATIVE_MAP, AGC_NATIVE_FILTER, AGC_NATIVE_REDUCE, AGC_NATIVE_EACH,
  AGC_NATIVE_ANY, AGC_NATIVE_ALL, AGC_NATIVE_SORT_BY,
  AGC_NATIVE_RANGE_EACH, AGC_NATIVE_TIMES, AGC_NATIVE_UPTO, AGC_NATIVE_DOWNTO
} agc_native_kind;

typedef struct {
  const char *name;
  uint32_t arity;
  agc_builtin_fn fn;
  agc_native_kind native;
} agc_builtin;

typedef struct {
  agc_string *name;
  uint32_t params, captures, registers, span, count;
  agc_instr *code;
  uint32_t *spans;
} agc_function;

typedef enum {
  AGC_TYPE_INT, AGC_TYPE_FLOAT, AGC_TYPE_BOOL, AGC_TYPE_STRING, AGC_TYPE_LIST, AGC_TYPE_MAP, AGC_TYPE_STRUCT
} agc_type_kind;

typedef struct {
  uint32_t kind, arg;
} agc_type;

typedef struct {
  agc_string *name;
  uint32_t count;
  agc_string **fields;
  agc_string *json_name;
  uint32_t *field_types;
} agc_struct_def;

typedef struct {
  agc_string *name;
  uint32_t first, count;
} agc_enum_def;

typedef struct {
  agc_string *name;
  uint32_t owner, arity;
  agc_enum *shared;
} agc_variant_def;

typedef struct {
  uint32_t source_count, span_count, constant_count, builtin_count, function_count, entry;
  uint32_t struct_count, type_count, enum_count, variant_count, max_fields, max_arity;
  agc_source *sources;
  agc_span *spans;
  agc_value *constants;
  agc_struct_def *structs;
  agc_type *types;
  agc_enum_def *enums;
  agc_variant_def *variants;
  const agc_builtin **builtins;
  agc_function *functions;
} agc_program;

typedef struct agc_native agc_native;

typedef struct {
  uint32_t function, pc, base, ret;
  agc_native *native;
} agc_frame;

typedef enum { AGC_DONE, AGC_FAILED, AGC_EXITED } agc_outcome_kind;

typedef enum { AGC_STYLE_PLAIN, AGC_STYLE_AI, AGC_STYLE_JSON } agc_style;

typedef struct {
  agc_outcome_kind kind;
  const char *code;
  const char *message;
  const agc_string *text;
  size_t message_len;
  uint32_t span;
  int64_t exit_code;
} agc_outcome;

typedef struct {
  uint64_t s[4];
} agc_random;

typedef struct {
  int fd;
  bool flush_out, pending_eof;
  uint8_t *buf;
  size_t start, end, cap;
} agc_input;

struct agc_vm {
  const agc_program *program;
  FILE *out, *err;
  int64_t steps_left;
  agc_value *regs;
  size_t reg_capacity;
  agc_frame *frames;
  uint32_t frame_capacity, frame_count, depth;
  agc_input in;
  agc_random random;
  agc_value args;
  const agc_string *cursor;
  size_t cursor_index, cursor_offset;
  agc_registry *registry;
  agc_loop *loop;
  agc_resource *parked;
  agc_string *cwd;
  bool no_files;
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
agc_value agc_map_value(agc_map *m);
agc_value agc_struct_value(agc_struct *s);
agc_value agc_enum_value(agc_enum *e);
agc_value agc_result_value(bool ok, agc_value value);
agc_value agc_fn_value(agc_fn *f);
agc_value agc_range_value(int64_t start, int64_t end, bool exclusive);
agc_value agc_json_value(agc_json *j);
agc_value agc_handle_value(agc_resource *r);
bool agc_as_bool(agc_vm *vm, agc_value v);
int64_t agc_as_int(agc_vm *vm, agc_value v);
double agc_as_float(agc_vm *vm, agc_value v);
agc_string *agc_as_string(agc_vm *vm, agc_value v);
agc_list *agc_as_list(agc_vm *vm, agc_value v);
agc_map *agc_as_map(agc_vm *vm, agc_value v);
agc_struct *agc_as_struct(agc_vm *vm, agc_value v);
agc_enum *agc_as_enum(agc_vm *vm, agc_value v);
agc_result *agc_as_result(agc_vm *vm, agc_value v);
agc_fn *agc_as_fn(agc_vm *vm, agc_value v);
agc_range *agc_as_range(agc_vm *vm, agc_value v);
agc_json *agc_as_json(agc_vm *vm, agc_value v);
agc_resource *agc_as_handle(agc_vm *vm, agc_value v);
char *agc_cstr(const agc_string *s);
bool agc_range_bounds(const agc_range *r, int64_t *first, int64_t *last);
bool agc_is(agc_value v, agc_tag tag);

size_t agc_float_text(double x, char out[AGC_SCALAR_TEXT]);
size_t agc_utf8_width(uint8_t lead);
uint32_t agc_utf8_next(const uint8_t *s, size_t len, size_t *at);
size_t agc_utf8_valid(const uint8_t *s, size_t len);
bool agc_utf8_chars(const uint8_t *data, size_t len, size_t *chars);
agc_string *agc_utf8_decode(const uint8_t *data, size_t len, const char *replacement, bool tail);
agc_string *agc_new_string(size_t bytes, size_t chars);
agc_string *agc_make_string(const char *data, size_t bytes, size_t chars);
agc_list *agc_new_list(size_t len);
agc_struct *agc_new_struct(uint32_t type, uint32_t n);
agc_enum *agc_new_enum(uint32_t variant, uint32_t n);
agc_fn *agc_new_fn(uint32_t function, uint32_t n);

void agc_map_seed(uint64_t k0, uint64_t k1);
uint64_t agc_key_hash(agc_vm *vm, agc_value key);
agc_map *agc_new_map(void);
agc_map *agc_map_put(agc_vm *vm, const agc_map *m, agc_value key, agc_value value);
agc_map *agc_map_put_hash(agc_vm *vm, const agc_map *m, uint64_t hash, agc_value key, agc_value value);
bool agc_map_get(agc_vm *vm, const agc_map *m, agc_value key, agc_value *value);
bool agc_map_get_hash(agc_vm *vm, const agc_map *m, uint64_t hash, agc_value key, agc_value *value);
agc_value *agc_map_keys(agc_vm *vm, const agc_map *m, uint32_t span);
agc_map *agc_map_delete(agc_vm *vm, const agc_map *m, agc_value key);
agc_map *agc_map_delete_hash(agc_vm *vm, const agc_map *m, uint64_t hash, agc_value key);

extern const uint32_t agc_write_raw_ranges[][2];
extern const size_t agc_write_raw_count;
extern const uint32_t agc_write_joiner_ranges[][2];
extern const size_t agc_write_joiner_count;
extern const uint32_t agc_write_blank_ranges[][2];
extern const size_t agc_write_blank_count;
bool agc_in_ranges(const uint32_t (*ranges)[2], size_t count, uint32_t cp);
bool agc_write_raw(uint32_t cp);
size_t agc_write_form(const agc_string *s, char *out, size_t *chars);
agc_string *agc_concat(const agc_string *a, const agc_string *b);
size_t agc_scalar_text(agc_vm *vm, agc_value v, char text[AGC_SCALAR_TEXT]);
agc_string *agc_text(agc_vm *vm, agc_value v);
agc_string *agc_debug(agc_vm *vm, agc_value v);
const agc_struct_def *agc_struct_def_of(agc_vm *vm, const agc_struct *st);

agc_value agc_sort_by_keys(agc_vm *vm, const agc_list *items, const agc_list *keys);

extern const uint32_t agc_upcase_map[][4];
extern const size_t agc_upcase_map_count;
extern const uint32_t agc_downcase_map[][4];
extern const size_t agc_downcase_map_count;
extern const uint32_t agc_cased_ranges[][2];
extern const size_t agc_cased_count;
extern const uint32_t agc_case_ignorable_ranges[][2];
extern const size_t agc_case_ignorable_count;

typedef enum { AGC_NUMBER_OK, AGC_NUMBER_INVALID, AGC_NUMBER_OVERFLOW } agc_number_status;

size_t agc_utf8_encode(uint32_t cp, char out[4]);
size_t agc_utf8_count(const uint8_t *s, size_t len);
size_t agc_utf8_offset(agc_vm *vm, const agc_string *s, size_t index);
#define AGC_NOT_FOUND SIZE_MAX
size_t agc_text_find(const agc_string *text, const agc_string *part, size_t from);
agc_string *agc_change_case(const agc_string *s, bool up);
agc_number_status agc_parse_int(const uint8_t *s, size_t len, int64_t *value);
agc_number_status agc_parse_float(const uint8_t *s, size_t len, double *value);
agc_string *agc_around(const char *before, const agc_string *part, const char *after);
extern const agc_builtin agc_string_builtins[];
extern const size_t agc_string_builtin_count;

extern const agc_builtin agc_number_builtins[];
extern const size_t agc_number_builtin_count;

const char *agc_json_version(void);
agc_json_status agc_json_parse(const uint8_t *text, size_t len, agc_value *out);
const char *agc_json_status_message(agc_json_status status);
agc_string *agc_json_ascii(const char *text, size_t n);
void *agc_json_grow(void *stack, size_t *capacity, size_t depth, size_t size);
void agc_json_put(agc_json_buffer *b, const char *text, size_t n);
agc_value agc_json_leaf(agc_json_kind kind, agc_value scalar);
agc_value agc_json_object(agc_json_member *members, size_t n);
agc_value agc_json_array(agc_list *items);
const agc_json_member *agc_json_find(const agc_json *j, const agc_string *key);
bool agc_json_to_float(agc_vm *vm, const agc_json *j, double *out);
agc_value agc_json_decode(agc_vm *vm, agc_value root, uint32_t type);
agc_value agc_json_schema(agc_vm *vm, uint32_t type);
agc_string *agc_json_encode(agc_vm *vm, agc_value v, uint32_t span);
agc_value agc_json_from(agc_vm *vm, agc_value v, uint32_t span);
extern const agc_builtin agc_json_builtins[];
extern const size_t agc_json_builtin_count;
extern const agc_builtin agc_file_builtins[];
extern const size_t agc_file_builtin_count;
const agc_builtin *agc_find_builtin(const uint8_t *name, size_t len, uint32_t arity);

agc_resource *agc_register(agc_vm *vm, void *native, agc_release_fn release);
void agc_unregister(agc_vm *vm, agc_resource *r);
const char *agc_uv_version(void);
void agc_io_start(agc_vm *vm, const agc_io_kind *kind, void *data, agc_value context, int64_t timeout_ms);
void agc_io_park(agc_vm *vm, size_t reg);
void agc_io_close(agc_vm *vm);

bool agc_load(const uint8_t *data, size_t len, agc_program **program, char *error, size_t error_size);

void agc_vm_init(agc_vm *vm, const agc_program *program, FILE *out, FILE *err, int64_t max_steps);
agc_outcome agc_vm_run(agc_vm *vm);
_Noreturn void agc_fail(agc_vm *vm, const char *code, const char *message, uint32_t span);
_Noreturn void agc_fail_text(agc_vm *vm, const char *code, const agc_string *message, uint32_t span);
_Noreturn void agc_exit(agc_vm *vm, int64_t code);
void agc_write(agc_vm *vm, FILE *stream, const void *data, size_t len);
void agc_flush(agc_vm *vm);

void agc_random_seed(agc_random *r, uint64_t seed);
uint64_t agc_random_next(agc_random *r);
double agc_random_float(agc_random *r);
bool agc_random_int(agc_random *r, int64_t low, int64_t high, int64_t *out);

void agc_input_open(agc_vm *vm, int fd, bool flush_out);
int agc_input_peek(agc_vm *vm);
agc_string *agc_input_line(agc_vm *vm);
agc_string *agc_input_all(agc_vm *vm);
bool agc_input_bytes(agc_vm *vm, size_t count, agc_list **out);

void agc_print_diagnostic(FILE *err, const agc_program *program, const agc_outcome *outcome, agc_style style);

int agc_fuzz_one(const uint8_t *data, size_t len);

#endif
