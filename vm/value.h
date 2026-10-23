/*
 * The value API that every layer uses: the tagged value type, the program
 * tables, agc_opcode, the memory functions and the Json value API. Layer
 * header: the core, the services and the adapters all include it. Design:
 * docs/vm/15-layers.md §15.4.
 */
#ifndef AGC_VALUE_H
#define AGC_VALUE_H

#include <setjmp.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "trace.h"

/* The first four bytes of every .agcb file. */
#define AGC_MAGIC "AGCB"
#define AGC_FORMAT_VERSION 6
/* The format before the prelude flag of the functions (version 6). The loader still reads it, so that the first binary of
   the bootstrap (checked-in bootstrap/stage0.agcb, which writes it) works until stage0 is refreshed; it has no prelude
   function. Remove it with the refresh. */
#define AGC_FORMAT_PREVIOUS 5
#define AGC_MAX_FILE_BYTES ((size_t)256 * 1024 * 1024)
#define AGC_MAX_DEPTH 10000
#define AGC_MAX_REGISTERS ((size_t)1 << 24)
#define AGC_MAX_MAP_CHUNK 255u
#define AGC_MAX_TYPES 65535u
#define AGC_MAX_GLOBALS 65535u
#define AGC_MAX_TYPE_DEPTH 1024u
#define AGC_SCALAR_TEXT 48
_Static_assert(AGC_SCALAR_TEXT >= 44, "range text needs 44 bytes");
#define AGC_MAX_READ_BYTES ((int64_t)1024 * 1024)
#define AGC_MAX_LIST_COUNT ((int64_t)1024 * 1024)
#define AGC_LIST_WIDTH 32
#define AGC_TURN_STEPS 2000
#define AGC_COST_BYTES 64

typedef enum {
  AGC_T_VOID = 0, AGC_T_NIL, AGC_T_BOOL, AGC_T_INT, AGC_T_FLOAT, AGC_T_STRING, AGC_T_LIST, AGC_T_MAP, AGC_T_STRUCT, AGC_T_ENUM, AGC_T_RESULT, AGC_T_FN, AGC_T_RANGE, AGC_T_JSON, AGC_T_HANDLE, AGC_T_TASK, AGC_T_PROCESS, AGC_T_SOCKET, AGC_T_LISTENER, AGC_T_HTTP_CLIENT, AGC_T_TEST, AGC_T_HTTP_SERVER, AGC_T_CHANNEL, AGC_T_SET, AGC_T_LAZY, AGC_T_C_POINTER, AGC_T_C_RESOURCE
} agc_tag;

typedef struct {
  uint32_t tag;
  union { bool b; int64_t i; double f; void *p; } as;
} agc_value;

static inline uint64_t agc_value_word(agc_value v) {
  uint64_t word;
  memcpy(&word, &v.as, sizeof word);
  return word;
}

_Static_assert(sizeof(agc_value) == 16 && offsetof(agc_value, as) == 8 && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__,
               "agc_word_value builds a value from its two 8-byte words");

static inline agc_value agc_word_value(uint32_t tag, uint64_t word) {
  const uint64_t image[2] = {tag, word};
  agc_value v;
  memcpy(&v, image, sizeof v);
  return v;
}

typedef struct {
  size_t bytes, chars;
  char data[];
} agc_string;

typedef struct agc_list agc_list;

typedef struct {
  agc_list *out;
  char *next, *stop, *after;
  size_t n;
  uint32_t kind;
} agc_list_builder;

typedef struct {
  const agc_list *list;
  size_t index, start, end;
  const char *chunk;
  uint32_t kind;
} agc_list_cursor;

typedef struct agc_hamt agc_hamt;

typedef struct agc_keys {
  agc_value key;
  struct agc_keys *next;
} agc_keys;

/* A Map. A Set is the same struct under AGC_T_SET with every value nil, so it
   shares the HAMT, the first-insertion order and the persistence of map.c. */
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
  AGC_OP_STRUCT_WITH,
  AGC_OP_GLOBAL, AGC_OP_GLOBAL_SET,
  AGC_OP_TRY_STEP,
  AGC_OP_COUNT
} agc_opcode;

/* A STEP or a CONST fused with the instruction after it (docs/vm/03-ir-and-bytecode.md §4.2). Only the loader writes
   these, after it has checked the file, on a STEP or CONST whose next instruction has the opcode in the name (ARITH_I:
   ADD_I, SUB_I or MUL_I); that instruction stays in place. AGC_FUSED_STEP_CONST_* is a STEP before a fused CONST, so
   the three run in one dispatch. The STEP forms come first and the CONST forms last (AGC_FUSED_CONST_FIRST), so the
   profile can tell which plain opcode a fused one starts with. A file never holds them: the loader rejects them as
   unknown opcodes. */
typedef enum {
  AGC_FUSED_STEP_MOVE = AGC_OP_COUNT, AGC_FUSED_STEP_CONST, AGC_FUSED_STEP_FIELD, AGC_FUSED_STEP_LIST_GET,
  AGC_FUSED_STEP_IS_VARIANT, AGC_FUSED_STEP_GLOBAL, AGC_FUSED_STEP_ARITH_I, AGC_FUSED_STEP_LT_I,
  AGC_FUSED_STEP_RETURN,
  AGC_FUSED_STEP_CONST_ARITH_I, AGC_FUSED_STEP_CONST_DIV_I, AGC_FUSED_STEP_CONST_MOD_I, AGC_FUSED_STEP_CONST_LT_I,
  AGC_FUSED_STEP_CONST_LE_I, AGC_FUSED_STEP_CONST_EQ, AGC_FUSED_STEP_CONST_NE,
  AGC_FUSED_CONST_ARITH_I, AGC_FUSED_CONST_DIV_I, AGC_FUSED_CONST_MOD_I, AGC_FUSED_CONST_LT_I, AGC_FUSED_CONST_LE_I,
  AGC_FUSED_CONST_EQ, AGC_FUSED_CONST_NE,
  AGC_FUSED_END,
  AGC_FUSED_CONST_FIRST = AGC_FUSED_CONST_ARITH_I
} agc_fused_opcode;
_Static_assert(AGC_FUSED_STEP_CONST_NE < AGC_FUSED_CONST_FIRST, "the STEP forms come before the CONST forms");

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
typedef struct agc_task agc_task;
typedef struct agc_resource agc_resource;
typedef struct agc_channel agc_channel;

typedef struct {
  agc_resource *reader, *writer;
} agc_lines;

typedef struct {
  agc_resource *state, *reader, *writer;
  agc_lines channel;
} agc_process;

typedef struct {
  agc_resource *state, *reader, *writer;
} agc_socket;

typedef struct {
  agc_resource *state;
  int64_t port;
} agc_listener;

/* An HttpClient: the jobs channel of its owner task and its HttpClientOptions (vm/http_service.c), and the TLS client
   context that its https connections share (vm/tcp.c's, opaque here: made by the first HttpWire.connect_tls, given
   back by HttpWire.drop_tls, which sets tls_dropped; both under rt->sync). The service task drops it once the client
   is closed and its pool has ended; a client never closed keeps it until the run ends. The context reads the CA file
   once, so a change to the file reaches new clients only. */
typedef struct {
  agc_value jobs, options;
  void *tls;
  bool tls_dropped;
} agc_http_client;

/* HttpClientOptions as the record of compiler/catalog/builtins_data.agc lays it out: timeout_ms, idle_timeout_ms,
   max_connections, max_body_bytes, ca_file. HttpWire.service checks the shape, since the std-only rule lives in the
   front end and bytecode can call the builtin with any struct. */
#define AGC_HTTP_OPTIONS_FIELDS 5
#define AGC_HTTP_OPTION_CA_FILE 4

typedef struct {
  agc_resource *state;
  agc_value listener;
  agc_task *group;
} agc_http_server;

struct agc_ffi_call;

/* A resource of native code (vm/ffi.c): the non-NULL C pointer that an extern function declared `-> Name` returned,
   the prepared call of the free function of its block, its name as declared (IO.inspect prints it) and its registry
   entry, whose native is this struct and which holds the owner task (§14.5). `jobs` counts the compute calls that use
   it now. A close marks it `closed` and takes it off its owner; the free runs then, or at the end of the last of those
   calls, so C never sees the pointer freed while a pool thread uses it. Changes under rt->sync. */
typedef struct {
  agc_resource *state;
  void *pointer;
  struct agc_ffi_call *free;
  const char *name;
  uint32_t jobs;
  bool closed, freed;
} agc_c_resource;

typedef struct {
  agc_string *name;
  agc_value body;
  uint32_t span;
} agc_test_case;

typedef agc_value (*agc_builtin_fn)(agc_vm *vm, agc_value *args, uint32_t span);

typedef enum {
  AGC_NATIVE_NONE, AGC_NATIVE_MAP, AGC_NATIVE_FILTER, AGC_NATIVE_REDUCE, AGC_NATIVE_EACH,
  AGC_NATIVE_ANY, AGC_NATIVE_ALL, AGC_NATIVE_SORT_BY,
  AGC_NATIVE_RANGE_EACH, AGC_NATIVE_TIMES, AGC_NATIVE_UPTO, AGC_NATIVE_DOWNTO, AGC_NATIVE_STEPPER
} agc_native_kind;

typedef enum { AGC_COST_NONE, AGC_COST_SIZE } agc_cost_rule;

/* The builtin that every extern function lowers to (vm/ffi.c). Every builtin whose name starts with AGC_NATIVE_PREFIX
   (it, the waits Native.wait_readable and wait_writable, Native.close, Native.null, Native.null?, Native.pointer and
   the reads Native.string_at and bytes_at) is native code: the loader notes whether a program imports one, so a run
   can refuse native code before it starts (agc_ffi_refusal). */
#define AGC_NATIVE_CALL "Native.call"
#define AGC_NATIVE_PREFIX "Native."
#define AGC_NATIVE_PREFIX_LEN (sizeof AGC_NATIVE_PREFIX - 1)

/* No public builtin may have a name that starts with "__": that prefix marks the prelude-only builtins
   (agc_builtin_prelude_only), which the loader accepts only in prelude functions. */
typedef struct {
  const char *name;
  uint32_t arity;
  agc_builtin_fn fn;
  agc_native_kind native;
  agc_cost_rule cost;
  /* The builtin reads or writes state that several schedulers can reach (tasks, channels, handle locks, the logger
     table, stdin, service state): the interpreter calls it with rt->sync held once the VM is shared (agc_share). The
     rest, such as strings, numbers, JSON, lists, maps and the file calls that name a path, run in parallel. A row that
     is not marked must touch none of that state. vm/tests/sync_test.c checks the marks of whole tables and of chosen
     rows; in a shared VM agc_sync_assert in the mutators of the shared lists (docs/vm/16-architecture.md §16.9) fails a
     run that reaches one without the lock, and make test-shared runs the programs that way. */
  bool shared;
  /* A plain C call: the builtin never parks (agc_io_start, agc_task_park), never starts a stepper or a block, never
     charges turn cost (agc_charge, nor a helper that charges, such as a map lookup that hashes a String key) and never
     counts a step or asks to yield; it only returns a value or fails with agc_fail. Its work is O(1) or bounded, so a
     builtin whose work grows with a String or a list (a compare, a copy, a UTF-8 walk) is not a leaf even when it
     charges nothing today. List.append and List.set copy the whole list only when a value's tag does not match a packed
     Int or Float list (list_wide in vm/list.c), which typed code never reaches. CALL_BUILTIN then stores the result and
     goes on without the generic tail. A leaf row is never shared, has AGC_NATIVE_NONE and AGC_COST_NONE
     (vm/tests/sync_test.c checks the tables), and the sanitizer and GC-stress builds abort when a leaf call breaks the
     rule (AGC_LEAF_CHECK in vm/core.h). When unsure, leave a row unmarked. */
  bool leaf;
} agc_builtin;

/* prelude marks a function of the compiler prelude (docs/future/25-ruby-typed-idioms.md §25.6): its spans are not
   the user's, so a runtime error in it is reported at the call the user wrote (agc_fail). */
typedef struct {
  agc_string *name;
  uint32_t params, captures, registers, span, count;
  bool prelude;
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

/* One struct update (`value.with(...)`): the struct it applies to and the
   fields it overwrites, strictly increasing and below that struct's field
   count. The loader checks both, so STRUCT_WITH indexes without a bounds test. */
typedef struct {
  uint32_t type, count;
  uint32_t *fields;
} agc_update_def;

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
  uint32_t struct_count, type_count, enum_count, variant_count, max_fields, max_arity, update_count, global_count;
  agc_source *sources;
  agc_span *spans;
  agc_value *constants;
  agc_struct_def *structs;
  agc_type *types;
  agc_enum_def *enums;
  agc_variant_def *variants;
  agc_update_def *updates;
  const agc_builtin **builtins;
  agc_function *functions;
  /* The index in builtins of the first native import (a name that starts with AGC_NATIVE_PREFIX), and of the first
     function that calls it, or UINT32_MAX. */
  uint32_t native_import, native_function;
  /* The Globals slots (module constants, docs/future/44-module-constants.md
     §44.8): global_count values in zeroed memory, so an unset slot has tag
     AGC_T_VOID. No module constant has type Void (44.5), so tag 0 means "never
     set"; a hand-made CONST of a Void and a GLOBAL_SET can unset a slot again.
     The only part of a loaded program that a run writes. The loader allows
     GLOBAL_SET only in the entry function, which has no backward jump and, in
     a file with slots, cannot be called, so each GLOBAL_SET runs at most once,
     in straight line, before main. After the entry tail-calls main the table
     is read-only and needs no lock. A hand-made entry could spawn a task
     before its last write, which only a multicore scheduler would turn into a
     race: docs/vm/10-io-multicore.md §10.2.3 says what that build must do. The
     table lives inside the program, allocated by the loader, so the collector
     scans it as it scans constants. A loaded program is run once; the slots
     keep their values after the run. */
  agc_value *globals;
} agc_program;

typedef struct {
  uint64_t s[4];
} agc_random;

typedef struct {
  uint64_t collections, heap, free, since, total_ms;
} agc_gc_info;

void agc_init(void);
void agc_release_all(void);
void agc_set_alloc_limit(jmp_buf *target, size_t limit);
void *agc_alloc(size_t size);
void *agc_alloc_atomic(size_t size);
size_t agc_size_add(size_t a, size_t b);
size_t agc_size_mul(size_t a, size_t b);
void agc_out_of_memory(void);
unsigned agc_gc_version(void);
void agc_gc_allow_threads(void);
bool agc_gc_thread_enter(void);
void agc_gc_thread_leave(void);
void agc_gc_pause(void);
void agc_gc_resume(void);
bool agc_gc_stats(agc_gc_info *info);
void agc_gc_measure(void);
void agc_gc_collect(void);

agc_value agc_result_value(bool ok, agc_value value);
agc_value agc_range_value(int64_t start, int64_t end, bool exclusive);
agc_value agc_handle_value(agc_resource *r);
agc_value agc_task_value(agc_task *t);
agc_value agc_process_value(agc_process *p);
agc_value agc_socket_value(agc_socket *s);
agc_value agc_listener_value(agc_listener *l);
agc_value agc_http_client_value(agc_http_client *c);
agc_value agc_test_case_value(agc_test_case *c);
agc_value agc_http_server_value(agc_http_server *s);
agc_value agc_channel_value(agc_channel *c);
/* A Lazy recipe (vm/lazy.c): an immutable node that the VM never looks inside outside that file. */
agc_value agc_lazy_value(const void *node);
/* A C.Pointer of native code (vm/ffi.c), which may be NULL, and a resource. */
agc_value agc_c_pointer_value(void *pointer);
agc_value agc_c_resource_value(agc_c_resource *r);
agc_resource *agc_as_handle(agc_vm *vm, agc_value v);
agc_task *agc_as_task(agc_vm *vm, agc_value v);
agc_process *agc_as_process(agc_vm *vm, agc_value v);
agc_socket *agc_as_socket(agc_vm *vm, agc_value v);
agc_listener *agc_as_listener(agc_vm *vm, agc_value v);
agc_http_client *agc_as_http_client(agc_vm *vm, agc_value v);
agc_test_case *agc_as_test_case(agc_vm *vm, agc_value v);
agc_http_server *agc_as_http_server(agc_vm *vm, agc_value v);
agc_channel *agc_as_channel(agc_vm *vm, agc_value v);
const void *agc_as_lazy(agc_vm *vm, agc_value v);
void *agc_as_c_pointer(agc_vm *vm, agc_value v);
agc_c_resource *agc_as_c_resource(agc_vm *vm, agc_value v);
/* The constructors and checked accessors of the common value types are inline: the interpreter and the builtins
 * use them on every instruction, and a call for each access (they used to live in value.c) cost more than the
 * Int add they served. A value of the wrong type calls agc_wrong_tag, which fails with RUNTIME-INTERNAL and does not
 * return. The rest of the code still never reads the union. */
_Noreturn void agc_wrong_tag(agc_vm *vm);

static inline agc_value agc_void(void) {
  agc_value v;
  memset(&v, 0, sizeof v);
  v.tag = AGC_T_VOID;
  return v;
}

static inline agc_value agc_nil(void) {
  agc_value v;
  v.tag = AGC_T_NIL;
  v.as.i = 0;
  return v;
}

static inline agc_value agc_bool(bool b) {
  agc_value v;
  v.tag = AGC_T_BOOL;
  v.as.i = b;
  return v;
}

static inline agc_value agc_int(int64_t i) {
  agc_value v;
  v.tag = AGC_T_INT;
  v.as.i = i;
  return v;
}

static inline agc_value agc_float(double f) {
  agc_value v;
  v.tag = AGC_T_FLOAT;
  v.as.f = f;
  return v;
}

static inline agc_value agc_string_value(agc_string *s) {
  agc_value v;
  v.tag = AGC_T_STRING;
  v.as.p = s;
  return v;
}

static inline agc_value agc_list_value(agc_list *l) {
  agc_value v;
  v.tag = AGC_T_LIST;
  v.as.p = l;
  return v;
}

static inline agc_value agc_map_value(agc_map *m) {
  agc_value v;
  v.tag = AGC_T_MAP;
  v.as.p = m;
  return v;
}

static inline agc_value agc_set_value(agc_map *m) {
  agc_value v;
  v.tag = AGC_T_SET;
  v.as.p = m;
  return v;
}

static inline agc_value agc_struct_value(agc_struct *s) {
  agc_value v;
  v.tag = AGC_T_STRUCT;
  v.as.p = s;
  return v;
}

static inline agc_value agc_enum_value(agc_enum *e) {
  agc_value v;
  v.tag = AGC_T_ENUM;
  v.as.p = e;
  return v;
}

static inline agc_value agc_fn_value(agc_fn *f) {
  agc_value v;
  v.tag = AGC_T_FN;
  v.as.p = f;
  return v;
}

static inline agc_value agc_json_value(agc_json *j) {
  agc_value v;
  v.tag = AGC_T_JSON;
  v.as.p = j;
  return v;
}

static inline bool agc_as_bool(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_BOOL) agc_wrong_tag(vm);
  return v.as.i != 0;
}

static inline int64_t agc_as_int(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_INT) agc_wrong_tag(vm);
  return v.as.i;
}

static inline double agc_as_float(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_FLOAT) agc_wrong_tag(vm);
  return v.as.f;
}

static inline agc_string *agc_as_string(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_STRING) agc_wrong_tag(vm);
  return v.as.p;
}

static inline agc_list *agc_as_list(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_LIST) agc_wrong_tag(vm);
  return v.as.p;
}

static inline agc_map *agc_as_map(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_MAP) agc_wrong_tag(vm);
  return v.as.p;
}

static inline agc_map *agc_as_set(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_SET) agc_wrong_tag(vm);
  return v.as.p;
}

static inline agc_struct *agc_as_struct(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_STRUCT) agc_wrong_tag(vm);
  return v.as.p;
}

static inline agc_enum *agc_as_enum(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_ENUM) agc_wrong_tag(vm);
  return v.as.p;
}

static inline agc_result *agc_as_result(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_RESULT) agc_wrong_tag(vm);
  return v.as.p;
}

static inline agc_fn *agc_as_fn(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_FN) agc_wrong_tag(vm);
  return v.as.p;
}

static inline agc_range *agc_as_range(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_RANGE) agc_wrong_tag(vm);
  return v.as.p;
}

static inline agc_json *agc_as_json(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_JSON) agc_wrong_tag(vm);
  return v.as.p;
}

static inline bool agc_is(agc_value v, agc_tag tag) { return v.tag == (uint32_t)tag; }

char *agc_cstr(const agc_string *s);
uint8_t *agc_byte_list(agc_vm *vm, const agc_list *values, size_t limit);
bool agc_range_bounds(const agc_range *r, int64_t *first, int64_t *last);

size_t agc_float_text(double x, char out[AGC_SCALAR_TEXT]);
size_t agc_utf8_width(uint8_t lead);
uint32_t agc_utf8_next(const uint8_t *s, size_t len, size_t *at);
size_t agc_utf8_valid(const uint8_t *s, size_t len);
size_t agc_utf8_count(const uint8_t *s, size_t len);
bool agc_utf8_chars(const uint8_t *data, size_t len, size_t *chars);
agc_string *agc_utf8_decode(const uint8_t *data, size_t len, const char *replacement, bool tail);
agc_string *agc_new_string(size_t bytes, size_t chars);
agc_string *agc_make_string(const char *data, size_t bytes, size_t chars);
/* The String of these bytes: the run's shared empty String for no bytes, its shared one-character String for one ASCII
   byte, else a new String. chars is the number of characters in the bytes. */
agc_string *agc_small_string(agc_vm *vm, const char *data, size_t bytes, size_t chars);
agc_value agc_error_value(const char *message);
agc_struct *agc_new_struct(uint32_t type, uint32_t n);
agc_enum *agc_new_enum(uint32_t variant, uint32_t n);
agc_fn *agc_new_fn(uint32_t function, uint32_t n);

uint64_t agc_key_hash(agc_vm *vm, agc_value key);
agc_map *agc_new_map(void);
agc_map *agc_map_put(agc_vm *vm, const agc_map *m, agc_value key, agc_value value);
agc_map *agc_map_put_hash(agc_vm *vm, const agc_map *m, uint64_t hash, agc_value key, agc_value value);
agc_map *agc_map_add_hash(agc_vm *vm, const agc_map *m, uint64_t hash, agc_value key, agc_value value);
bool agc_map_get(agc_vm *vm, const agc_map *m, agc_value key, agc_value *value);
bool agc_map_get_hash(agc_vm *vm, const agc_map *m, uint64_t hash, agc_value key, agc_value *value);
agc_value *agc_map_keys(agc_vm *vm, const agc_map *m, uint32_t span);
bool agc_set_subset(agc_vm *vm, const agc_map *a, const agc_map *b);
agc_map *agc_map_delete(agc_vm *vm, const agc_map *m, agc_value key);
agc_map *agc_map_delete_hash(agc_vm *vm, const agc_map *m, uint64_t hash, agc_value key);

size_t agc_list_len(const agc_list *l);
agc_value agc_list_get(const agc_list *l, size_t i);
void agc_list_builder_sized(agc_list_builder *b, size_t n);
void agc_list_builder_more(agc_list_builder *b, agc_value v);
agc_list *agc_list_builder_finish(agc_list_builder *b);
agc_list *agc_list_from_array(const agc_value *items, size_t n);
/* A List of Int with one item per byte (0 to 255): the one copy of bytes into a list (stdin, streams, HTTP). */
agc_list *agc_list_of_bytes(const uint8_t *data, size_t n);
void agc_list_to_array(const agc_list *l, agc_value *out);
void agc_list_cursor_begin(agc_list_cursor *c, const agc_list *l, size_t at);
bool agc_list_cursor_fill(agc_list_cursor *c);
agc_list *agc_list_append(const agc_list *l, agc_value v);
agc_list *agc_list_set(const agc_list *l, size_t i, agc_value v);
agc_list *agc_list_slice(const agc_list *l, size_t from, size_t count);
agc_list *agc_list_concat(const agc_list *a, const agc_list *b);
agc_list *agc_list_reverse(const agc_list *l);
agc_list *agc_list_repeat(agc_value v, size_t n);
uint32_t agc_list_kind(const agc_list *l);

static inline void agc_list_builder_push(agc_list_builder *b, agc_value v) {
  if (b->next == b->stop || (b->kind && v.tag != b->kind)) {
    agc_list_builder_more(b, v);
  } else if (b->kind) {
    *(uint64_t *)b->next = agc_value_word(v);
    b->next += sizeof(uint64_t);
  } else {
    *(agc_value *)b->next = v;
    b->next += sizeof(agc_value);
  }
}

static inline bool agc_list_cursor_next(agc_list_cursor *c, agc_value *out) {
  if (c->index >= c->end && !agc_list_cursor_fill(c)) return false;
  size_t k = c->index++ - c->start;
  if (c->kind) {
    uint64_t word;
    memcpy(&word, c->chunk + k * sizeof word, sizeof word);
    *out = agc_word_value(c->kind, word);
  } else {
    *out = ((const agc_value *)c->chunk)[k];
  }
  return true;
}

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
agc_string *agc_test_text(agc_vm *vm, agc_value v);
bool agc_same_string(agc_vm *vm, const agc_string *x, const agc_string *y);
bool agc_equal(agc_vm *vm, agc_value a, agc_value b, uint32_t span);
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

agc_string *agc_json_ascii(const char *text, size_t n);
void *agc_json_grow(void *stack, size_t *capacity, size_t depth, size_t size);
agc_json *agc_json_container(bool object, size_t n, agc_list_builder *items);
void agc_json_store(agc_json *node, agc_list_builder *items, size_t k, agc_value v);
agc_value agc_json_finish(agc_json *node, agc_list_builder *items, size_t n);
void agc_json_put(agc_json_buffer *b, const char *text, size_t n);
agc_value agc_json_leaf(agc_json_kind kind, agc_value scalar);
agc_value agc_json_number(int64_t n);
agc_json_member agc_json_pair(const char *key, agc_value value);
agc_value agc_json_object(agc_json_member *members, size_t n);
agc_value agc_json_array(agc_list *items);
const agc_json_member *agc_json_find(const agc_json *j, const agc_string *key);
agc_string *agc_json_encode(agc_vm *vm, agc_value v, uint32_t span);
agc_value agc_json_from(agc_vm *vm, agc_value v, uint32_t span);

void agc_random_seed(agc_random *r, uint64_t seed);
uint64_t agc_random_next(agc_random *r);
double agc_random_float(agc_random *r);
bool agc_random_int(agc_random *r, int64_t low, int64_t high, int64_t *out);

#endif
