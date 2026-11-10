/*
 * Native modules (vm/agentica_native.h, #1149): agc_native_bind binds a "module TYPES CANON SYMBOL LIBRARY" signature
 * of Native.call to a row of a module's function table, loading the module at its first use (agentica_native_init in
 * a shared library, ffi_os.h, or a module the binary carries, agc_native_register); agc_native_call makes a short
 * call on the scheduler, and agc_native_dirty_* a dirty one on the compute pool, whose terms are staged in malloc
 * memory and become values on the scheduler; the an_api table is the VM half of the C API. vm/ffi.c keeps the bound
 * functions in its cache of the run and holds their resources. Service layer. Design: docs/vm/16-architecture.md
 * §16.9 ("Native modules").
 */
#include "agentica_native.h"
#include "ffi_os.h"
#include "services.h"

#include <inttypes.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The deepest nesting of a type in a signature (List[List[...]]); only hand-made bytecode nests deeper. */
#define TYPE_MAX_DEPTH 32
/* The most functions, types and resources a module may declare. */
#define MODULE_MAX_FUNCTIONS 65536
#define MODULE_MAX_TYPES 65536
#define MODULE_MAX_RESOURCES 65536
/* The turn cost of one short call, besides what it builds: like a fast extern call, it cannot stop in the middle. */
#define CALL_COST 64
/* The largest first block of a list builder: a bigger hint is no reason to allocate more before the pushes come. */
#define HINT_MAX 4096
#define REPLACEMENT "\xEF\xBF\xBD"
#define FAILED "RUNTIME-NATIVE-ERROR"
#define NO_OPTIONAL "no Optional enum"
#define KEY_REFUSAL "a Map key is an Int, a String or a Bytes"
/* The size of an an_module of API 1.0, the fields up to function_count: a module of a later minor version is larger,
   and the fields after these are read only when its size covers them. */
#define MODULE_SIZE_1_0 (offsetof(an_module, function_count) + sizeof(uint32_t))
/* The size of an an_module of API 1.1, which adds the type table, and of 1.2, which adds the resource table. */
#define MODULE_SIZE_1_1 (offsetof(an_module, type_count) + sizeof(uint32_t))
#define MODULE_SIZE_1_2 (offsetof(an_module, resource_count) + sizeof(uint32_t))
/* The index of a type of the module that the function's signature does not reach (agc_native_fn.types). */
#define UNBOUND UINT32_MAX
/* About what one Map entry takes, its leaf in the table and its cell in the key list (vm/map.c), so that a Map built
   from Int keys is charged like a List of its pairs. */
#define MAP_ENTRY_BYTES (3 * sizeof(agc_value) + sizeof(agc_keys))
/* The tag of a term that a dirty call staged: no agc_tag has it, so every getter refuses one, and its word is the index
   of its node (agc_native_dirty.nodes). It never leaves the call: dirty_done builds a value for each one. */
#define STAGED_TAG 0x5354u
/* The size of a block of a dirty call's arena; a bigger request gets a block of its own. */
#define CHUNK_BYTES 65536
/* How long a short call may take (its CPU time where known, note_time) in the builds of AGC_LEAF_CHECK before they
   warn, once per function. */
#define SLOW_NS 1000000u
/* A short call that took this long by the clock warns whatever its CPU time (note_time): it blocked or slept, which no
   turn of other threads explains (those measured 4 to 16 ms on a loaded machine). A short call that blocks or sleeps
   for less is not reported. */
#define STALL_NS 100000000u

/* The kinds of type a signature names; KINDS has the names and how many type arguments each takes of all but the last
   two, a struct and an enum of the program, which a signature names by the bare name of a type block. */
typedef enum {
  K_INT, K_FLOAT, K_BOOL, K_STRING, K_BYTES, K_VOID, K_LIST, K_MAP, K_OPTIONAL, K_RESULT, K_STRUCT, K_ENUM, K_RESOURCE
} type_kind;

/* What a node of a dirty call's arena stages (staged.kind). */
enum { N_STRING, N_BYTES, N_LIST, N_MAP, N_PUT, N_SOME, N_OK, N_ERROR, N_STRUCT, N_ENUM, N_RESOURCE };

typedef enum { B_STRUCT, B_ENUM, B_RESOURCE } block_kind;

/* A bound function, in malloc memory that lives as long as the cache of the run (vm/ffi.c): the module's row, its
   library, the outer kind of each parameter and of the result (what agc_native_arguments and the call check) with the
   index of a struct or enum kind in the program's table or of a resource kind in the module's resource table, whether
   the module is one that the binary carries, which a run with no_files may call, and whether the function is dirty.
   TYPES[k] is the program's index of row k of the module's type table, or UNBOUND when the signature does not reach it
   (NULL when the module has no types); RESOURCES[k] whether it reaches row k of the resource table. HOLDS lists the
   parameters that are resources (`hold_count` of them), RESULT_TYPE is the result's text in the row's signature (the
   deep check of AGC_LEAF_CHECK). NEXT links the functions of the library. CALLS and NS are the profile's (one
   scheduler, AGENTICA_VM_TRACE=profile); WARNED is set once a short call took over SLOW_NS. */
struct agc_native_fn {
  const an_function *row;
  struct agc_native_library *lib;
  struct agc_native_fn *next;
  bool carried, dirty;
  uint32_t arity;
  uint8_t result;
  uint8_t params[AGC_FFI_MAX_PARAMS];
  uint32_t result_id;
  uint32_t param_ids[AGC_FFI_MAX_PARAMS];
  const an_type *type_rows;
  uint32_t type_count;
  uint32_t *types;
  const an_resource_type *resource_rows;
  uint32_t resource_count;
  bool *resources;
  uint8_t holds[AGC_FFI_MAX_PARAMS];
  uint32_t hold_count;
  const char *result_type;
  uint64_t calls, ns;
  atomic_bool warned;
};

/* A type block of a signature, "{S<index>=SHAPE}" or "{E<index>=SHAPE}", a struct or enum of the program that the
   function's signature reaches with its index in the program's table, its name there and its shape; or "{R=NAME}", a
   resource of the module, its name in the signature and, once bound, its row in the module's resource table. */
typedef struct {
  block_kind kind;
  uint32_t index;
  const char *name;
  size_t name_len;
  const char *shape;
  size_t shape_len;
} type_block;

/* The type blocks of a signature, which read_blocks checked, sorted by name for find_block. ITEMS is GC memory, which
   a bind that fails leaves to the collector. */
typedef struct {
  type_block *items;
  uint32_t count;
} block_list;

/* A module of the run (agc_runtime.native_modules), in malloc memory, under rt->sync, found by NAME (the library of
   the signature). A carried one has INIT from the start; an opened one gets it from its library at the first bind.
   That bind loads it: MODULE then holds the module, with its type and resource rows sorted by name (TYPE_INDEX,
   RESOURCE_INDEX: pointers to each row's name, for a binary search), or ERROR the message of every later bind, so a
   module that failed is not loaded again. FNS are the functions bound from it. */
typedef struct agc_native_library {
  struct agc_native_library *next;
  CC_OWNS char *name;
  agc_native_init init;
  const an_module *module;
  const char *const **type_index, *const **resource_index;
  struct agc_native_fn *fns;
  char *error;
  bool tried, carried;
} native_library;

/* One call of a module's function, which agc_ffi_refusing_callbacks runs. */
typedef struct {
  const agc_native_fn *fn;
  an_env *env;
  const an_term *argv;
  an_term result;
} module_call;

/* A node of a dirty call: what one constructor made, built into a value by dirty_done. ID is the program's struct
   index (N_STRUCT), the program's variant (N_ENUM) or the resource row (N_RESOURCE); DATA the N bytes of a String,
   Bytes or error message, the N values of a List, struct or enum payload, the N keys then N values of a Map, the Map,
   key and value of an N_PUT, the one value of an N_SOME or N_OK, or the state of an N_RESOURCE (NULL once it has a
   value or was freed). Values in DATA are terms: the call's arguments and what they reach, or staged ones of a lower
   index, since a term exists before a constructor takes it; so building in index order needs no recursion. */
typedef struct {
  uint8_t kind;
  uint32_t id;
  size_t n;
  void *data;
} staged;

/* A block of a dirty call's arena (malloc memory). */
typedef struct arena_chunk {
  struct arena_chunk *next;
  size_t used, cap;
  max_align_t data[];
} arena_chunk;

/* A dirty call, in malloc memory (vm/ffi.c's module_job holds it). The pool thread makes GC memory never: it reads the
   arguments (ARGV, GC values that the job's context keeps alive, immutable, and never moved by the collector) and
   what they reach, and each constructor stages a node (NODES, COUNT of them) in malloc memory, its data in the arena
   (CHUNKS). VM is the scheduler that started it, whose runtime's program the pool thread reads. HELD are the resource
   arguments (HOLDS of them), in the job of vm/ffi.c, which holds them and outlives the call. CODE and MESSAGE
   (malloc'd, MESSAGE_LEN bytes) are its first failure, RESULT what the function returned, RAN set once it has, NS how
   long it took when PROFILE; BYTES is what the staged values are charged when they are built. */
struct agc_native_dirty {
  agc_vm *vm;
  agc_native_fn *fn;
  agc_value argv[AGC_FFI_MAX_PARAMS];
  agc_c_resource *const *held;
  uint32_t holds;
  an_term result;
  const char *code;
  char *message;
  size_t message_len;
  staged *nodes;
  size_t count, cap, bytes;
  arena_chunk *chunks;
  uint64_t ns;
  bool profile, ran;
};

/* The env of one call: the table first, as an_api_of reads it. HELD are its resource arguments (HOLDS of them), which
   vm/ffi.c holds for the call. CODE and MESSAGE are a short call's first failure; DIRTY is the dirty call, NULL for a
   short one. */
struct an_env {
  const an_api *api;
  agc_vm *vm;
  const agc_native_fn *fn;
  agc_c_resource *const *held;
  uint32_t holds;
  const char *code;
  agc_string *message;
  agc_native_dirty *dirty;
};

/* An item of the deep check of a result (AGC_LEAF_CHECK): a value and the text of its declared type. */
typedef struct {
  agc_value v;
  const char *type;
} check_item;

/* What an an_list_builder holds: a GC array of the pushed values, which grows by doubling. */
typedef struct {
  agc_value *items;
  size_t n, cap;
} list_build;

/* What an an_map_cursor holds: the map and its keys in insertion order, taken when the walk starts, and in a dirty
   call their values too (VALUES, else NULL: a short call looks each one up). */
typedef struct {
  const agc_map *map;
  agc_value *keys, *values;
  size_t at, n;
} map_walk;

_Static_assert(sizeof(an_term) == sizeof(agc_value), "a term is a value");
_Static_assert(sizeof(list_build) <= sizeof(an_list_builder), "an_list_builder holds a list_build");
_Static_assert(sizeof(agc_list_cursor) <= sizeof(an_list_cursor), "an_list_cursor holds an agc_list_cursor");
_Static_assert(sizeof(map_walk) <= sizeof(an_map_cursor), "an_map_cursor holds a map_walk");

static const struct {
  const char *name;
  size_t len;
  uint8_t arity;
} KINDS[] = {{"Int", 3, 0},  {"Float", 5, 0}, {"Bool", 4, 0}, {"String", 6, 0},   {"Bytes", 5, 0},
             {"Void", 4, 0}, {"List", 4, 1},  {"Map", 3, 2},  {"Optional", 8, 1}, {"Result", 6, 1}};
static const uint32_t KIND_TAGS[] = {AGC_T_INT,    AGC_T_FLOAT, AGC_T_BOOL, AGC_T_STRING, AGC_T_BYTES,
                                     AGC_T_VOID,   AGC_T_LIST,  AGC_T_MAP,  AGC_T_ENUM,   AGC_T_RESULT,
                                     AGC_T_STRUCT, AGC_T_ENUM,  AGC_T_C_RESOURCE};
static const an_api API;

/* Terms and values have the same bytes; memcpy moves them between the two types. */
static agc_value value_of(an_term t) {
  agc_value v;
  memcpy(&v, &t, sizeof v);
  return v;
}

static an_term term_of(agc_value v) {
  an_term t;
  memcpy(&t, &v, sizeof t);
  return t;
}

static agc_string *decoded(const char *text, size_t len) {
  return agc_utf8_decode((const uint8_t *)text, len, REPLACEMENT, false);
}

__attribute__((format(printf, 4, 5))) static _Noreturn void fail_with(agc_vm *vm, const char *code, uint32_t span,
                                                                      const char *format, ...) {
  char text[768];
  va_list ap;
  va_start(ap, format);
  int n = vsnprintf(text, sizeof text, format, ap);
  va_end(ap);
  size_t len = n < 0 ? 0 : (size_t)n < sizeof text ? (size_t)n : sizeof text - 1;
  agc_fail_text(vm, code, decoded(text, len), span);
}

static _Noreturn void bad_signature(agc_vm *vm, uint32_t span) {
  agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: bad native signature", span);
}

static bool skip(const char **at, const char *end, const char *word) {
  size_t len = strlen(word);
  if ((size_t)(end - *at) < len || memcmp(*at, word, len) != 0) return false;
  *at += len;
  return true;
}

static int kind_named(const char *name, size_t len) {
  for (int k = 0; k < (int)(sizeof KINDS / sizeof KINDS[0]); k++)
    if (KINDS[k].len == len && memcmp(KINDS[k].name, name, len) == 0) return k;
  return -1;
}

static bool name_char(char c) {
  return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_';
}

static bool skip_name(const char **at, const char *end, const agc_string *name) {
  if ((size_t)(end - *at) < name->bytes || memcmp(*at, name->data, name->bytes) != 0) return false;
  *at += name->bytes;
  return true;
}

/* Reads the type block at *AT, before END, into B: "{S<index>=SHAPE}" for a struct of program P or "{E<index>=SHAPE}"
   for an enum, with the index in range, or "{R=NAME}" for a resource, NAME an identifier. A shape holds no brace. */
static bool next_block(const agc_program *p, const char **at, const char *end, type_block *b) {
  if (end - *at < 4 || (*at)[0] != '{') return false;
  if ((*at)[1] == 'R' && (*at)[2] == '=') {
    const char *name = *at + 3, *stop = name;
    while (stop < end && name_char(*stop)) stop++;
    if (stop == name || stop == end || *stop != '}') return false;
    *b = (type_block){B_RESOURCE, UNBOUND, name, (size_t)(stop - name), NULL, 0};
    *at = stop + 1;
    return true;
  }
  if ((*at)[1] != 'S' && (*at)[1] != 'E') return false;
  b->kind = (*at)[1] == 'E' ? B_ENUM : B_STRUCT;
  *at += 2;
  const char *digits = *at;
  uint64_t index = 0;
  while (*at < end && **at >= '0' && **at <= '9' && *at - digits < 10) index = index * 10 + (uint64_t)(*(*at)++ - '0');
  if (*at == digits || !skip(at, end, "=")) return false;
  const char *close = memchr(*at, '}', (size_t)(end - *at));
  if (!close || index >= (b->kind == B_ENUM ? p->enum_count : p->struct_count)) return false;
  b->index = (uint32_t)index;
  const agc_string *name = b->kind == B_ENUM ? p->enums[index].name : p->structs[index].name;
  b->name = name->data;
  b->name_len = name->bytes;
  b->shape = *at;
  b->shape_len = (size_t)(close - *at);
  *at = close + 1;
  return true;
}

/* The order of names A (ALEN bytes) and B: by their bytes, then the shorter first. */
static int name_order(const char *a, size_t alen, const char *b, size_t blen) {
  int c = memcmp(a, b, alen < blen ? alen : blen);
  return c ? c : (alen > blen) - (alen < blen);
}

static int block_order(const void *a, const void *b) {
  const type_block *x = a, *y = b;
  return name_order(x->name, x->name_len, y->name, y->name_len);
}

/* The position in LIST of the block whose type is named TEXT (LEN bytes), by binary search. */
static bool find_block(const block_list *list, const char *text, size_t len, uint32_t *found) {
  size_t low = 0, high = list->count;
  while (low < high) {
    size_t mid = low + (high - low) / 2;
    const type_block *b = &list->items[mid];
    int c = name_order(text, len, b->name, b->name_len);
    if (c == 0) {
      *found = (uint32_t)mid;
      return true;
    }
    if (c < 0) {
      high = mid;
    } else {
      low = mid + 1;
    }
  }
  return false;
}

/* Skips one type of a shape, up to the ',', ')' or ' ' that ends it outside brackets. False for an empty or
   unbalanced type; the module's copy of the shape is what checks the rest. */
static bool skip_type(const char **at, const char *end) {
  const char *start = *at;
  size_t depth = 0;
  for (; *at < end; (*at)++) {
    char c = **at;
    if (c == '[') {
      depth++;
    } else if (c == ']') {
      if (depth == 0) return false;
      depth--;
    } else if (depth == 0 && (c == ',' || c == ')' || c == ' ')) {
      break;
    }
  }
  return *at > start && depth == 0;
}

/* Whether NAME is one the front end writes: an identifier, and for a field one that may end in ? or !. The loader takes
   any UTF-8 name, and one holding a separator of a shape (" | ", "(", ", ", ": ") would read one shape as other fields
   or variants than the program has, with other payload counts than the module's. */
static bool shape_name(const agc_string *name, bool field) {
  size_t n = name->bytes;
  if (field && n && (name->data[n - 1] == '?' || name->data[n - 1] == '!')) n--;
  if (n == 0) return false;
  for (size_t k = 0; k < n; k++)
    if (!name_char(name->data[k])) return false;
  return true;
}

/* Whether the shape of B lists the fields of its struct, or the variants of its enum, as program P declares them: the
   same names in the same order, and the same number of payload types for each variant. So the module's tables, which
   the shape must equal, index what the program builds. */
static bool shape_fits(const agc_program *p, const type_block *b) {
  if (b->kind == B_RESOURCE) return true;
  const char *at = b->shape, *end = b->shape + b->shape_len;
  if (b->kind == B_STRUCT) {
    const agc_struct_def *def = &p->structs[b->index];
    for (uint32_t k = 0; k < def->count; k++)
      if ((k && !skip(&at, end, ", ")) || !shape_name(def->fields[k], true) || !skip_name(&at, end, def->fields[k]) ||
          !skip(&at, end, ": ") || !skip_type(&at, end))
        return false;
    return at == end;
  }
  const agc_enum_def *def = &p->enums[b->index];
  for (uint32_t k = 0; k < def->count; k++) {
    const agc_variant_def *v = &p->variants[def->first + k];
    if ((k && !skip(&at, end, " | ")) || !shape_name(v->name, false) || !skip_name(&at, end, v->name)) return false;
    for (uint32_t n = 0; n < v->arity; n++)
      if (!skip(&at, end, n ? ", " : "(") || !skip_type(&at, end)) return false;
    if (v->arity && !skip(&at, end, ")")) return false;
  }
  return at == end;
}

/* Reads the type blocks at the start of a signature, at *AT before END: each in range, fitting the program, and of a
   name no other block has. At most MODULE_MAX_TYPES + MODULE_MAX_RESOURCES, the most rows of distinct names that a
   module can have: each block must name one, so more could never bind. Read once, then sorted, so reading and
   finding blocks takes O(B log B); check_blocks then finds each block in the module's sorted rows (row_named), so a
   bind takes O(B log N) under rt->sync. Bad bytecode fails. */
static block_list read_blocks(agc_vm *vm, const char **at, const char *end, uint32_t span) {
  const agc_program *p = vm->rt->program;
  block_list list = {NULL, 0};
  type_block b;
  const char *start = *at;
  while (*at < end && **at == '{') {
    if (!p || list.count == MODULE_MAX_TYPES + MODULE_MAX_RESOURCES || !next_block(p, at, end, &b))
      bad_signature(vm, span);
    list.count++;
  }
  if (list.count == 0) return list;
  list.items = agc_alloc(agc_size_mul(list.count, sizeof *list.items));
  /* The second pass reads the same bytes as the first, which accepted each block: the signature and the program
     do not change during a bind. */
  for (uint32_t k = 0; k < list.count; k++) {
    (void)next_block(p, &start, end, &list.items[k]);
    if (!shape_fits(p, &list.items[k])) bad_signature(vm, span);
  }
  qsort(list.items, list.count, sizeof *list.items, block_order);
  for (uint32_t k = 1; k < list.count; k++)
    if (block_order(&list.items[k - 1], &list.items[k]) == 0) bad_signature(vm, span);
  return list;
}

/* Reads one type at *AT, before END, with no recursion: NEED[d] counts the type arguments still to read at depth d.
   Gives the kind of the outer type, with in *ID the program's index of a struct or enum kind, or the position in
   BLOCKS of a resource's block (agc_native_bind turns it into the row), or -1 when the text is no canonical type. A
   name that is no kind is the type of a block of BLOCKS. Each turn of the loop reads a name or fails, so the loop
   ends. */
static int parse_type(const char **at, const char *end, const block_list *blocks, uint32_t *id) {
  uint8_t need[TYPE_MAX_DEPTH];
  size_t depth = 0;
  int outer = -1;
  for (;;) {
    const char *name = *at;
    while (*at < end && name_char(**at)) (*at)++;
    size_t len = (size_t)(*at - name);
    int kind = kind_named(name, len);
    uint32_t at_block = 0;
    if (kind < 0 && len && find_block(blocks, name, len, &at_block)) {
      block_kind b = blocks->items[at_block].kind;
      kind = b == B_ENUM ? K_ENUM : b == B_STRUCT ? K_STRUCT : K_RESOURCE;
    }
    if (kind < 0) return -1;
    if (outer < 0) {
      outer = kind;
      // cchecker: ignore CC-TIDY-CLANG-ANALYZER-CORE-NULLDEREFERENCE: kinds >= K_STRUCT come from a found block
      *id = kind == K_RESOURCE ? at_block : kind >= K_STRUCT ? blocks->items[at_block].index : 0;
    }
    if (kind < K_STRUCT && KINDS[kind].arity) {
      if (depth == TYPE_MAX_DEPTH || !skip(at, end, "[")) return -1;
      need[depth++] = KINDS[kind].arity;
      continue;
    }
    for (;;) {
      if (depth == 0) return outer;
      if (--need[depth - 1] > 0) {
        if (!skip(at, end, ", ")) return -1;
        break;
      }
      if (!skip(at, end, "]")) return -1;
      depth--;
    }
  }
}

/* Reads "(T, ...) -> R" at *AT into FN's arity, kinds and type indexes. A parameter is never Void. */
static bool parse_canon(const char **at, const char *end, const block_list *blocks, agc_native_fn *fn) {
  if (!skip(at, end, "(")) return false;
  if (!skip(at, end, ")")) {
    for (;;) {
      int kind = fn->arity < AGC_FFI_MAX_PARAMS ? parse_type(at, end, blocks, &fn->param_ids[fn->arity]) : -1;
      if (kind < 0 || kind == K_VOID) return false;
      fn->params[fn->arity++] = (uint8_t)kind;
      if (skip(at, end, ")")) break;
      if (!skip(at, end, ", ")) return false;
    }
  }
  int result = skip(at, end, " -> ") ? parse_type(at, end, blocks, &fn->result_id) : -1;
  fn->result = (uint8_t)result;
  return result >= 0;
}

static native_library *library_new(agc_vm *vm, const char *name, size_t len, agc_native_init init) {
  agc_runtime *rt = vm->rt;
  agc_sync_assert(vm);
  native_library *lib = calloc(1, sizeof *lib);
  if (!lib) agc_out_of_memory();
  lib->name = agc_ffi_text_copy(name, len);
  lib->init = init;
  lib->carried = init != NULL;
  lib->next = rt->native_modules;
  rt->native_modules = lib;
  return lib;
}

/* The type table of module M: none for a module of API 1.0, whose an_module ends before it. */
static uint32_t module_types(const an_module *m, const an_type **rows) {
  *rows = m->size >= MODULE_SIZE_1_1 ? m->types : NULL;
  return m->size >= MODULE_SIZE_1_1 ? m->type_count : 0;
}

/* The resource table of module M: none before API 1.2. */
static uint32_t module_resources(const an_module *m, const an_resource_type **rows) {
  *rows = m->size >= MODULE_SIZE_1_2 ? m->resources : NULL;
  return m->size >= MODULE_SIZE_1_2 ? m->resource_count : 0;
}

/* Rows of a type or resource table are found by a pointer to their first field, the name. */
static int name_ref_order(const void *a, const void *b) {
  return strcmp(**(const char *const *const *)a, **(const char *const *const *)b);
}

/* The rows of a table (COUNT rows of STRIDE bytes, each starting with its name) sorted by name, as pointers to their
   names, in *INDEX (malloc'd, NULL for none); a message in ERROR (SIZE bytes) when two rows have one name, which would
   make the type that a signature names by it ambiguous, else NULL. So a load takes O(N log N) and a lookup O(log N). */
static const char *sort_rows(const void *rows, uint32_t count, size_t stride, const char *what,
                             const char *const ***index, char *error, size_t size) {
  *index = NULL;
  if (count == 0) return NULL;
  const char *const **sorted = malloc(agc_size_mul(count, sizeof *sorted));
  if (!sorted) agc_out_of_memory();
  for (uint32_t k = 0; k < count; k++) sorted[k] = (const char *const *)(const void *)((const char *)rows + k * stride);
  qsort(sorted, count, sizeof *sorted, name_ref_order);
  *index = sorted;
  for (uint32_t k = 1; k < count; k++)
    if (strcmp(*sorted[k - 1], *sorted[k]) == 0) {
      snprintf(error, size, "the module's %s table has two rows named %.64s", what, *sorted[k]);
      return error;
    }
  return NULL;
}

/* The row of the sorted INDEX (COUNT rows) named NAME (LEN bytes), or NULL. */
static const void *row_named(const char *const *const *index, uint32_t count, const char *name, size_t len) {
  size_t low = 0, high = index ? count : 0;
  while (low < high) {
    size_t mid = low + (high - low) / 2;
    const char *row = *index[mid];
    int c = name_order(name, len, row, strlen(row));
    if (c == 0) return index[mid];
    if (c < 0) {
      high = mid;
    } else {
      low = mid + 1;
    }
  }
  return NULL;
}

/* What is wrong with the module M that an init gave, as a message in ERROR (SIZE bytes), or NULL. Only the fields of
   API 1.0 are read, which every module of major version 1 has (MODULE_SIZE_1_0), and the type and resource tables
   when SIZE covers them. */
static const char *module_problem(const an_module *m, char *error, size_t size) {
  if (!m) return "agentica_native_init returned no module";
  if (m->major != AN_API_MAJOR || m->minor > AN_API_MINOR || m->size < MODULE_SIZE_1_0) {
    snprintf(error, size, "the module was built for native API %u.%u, and this VM has %u.%u", (unsigned)m->major,
             (unsigned)m->minor, (unsigned)AN_API_MAJOR, (unsigned)AN_API_MINOR);
    return error;
  }
  if (m->function_count > MODULE_MAX_FUNCTIONS || (m->function_count && !m->functions))
    return "the module's function table is not valid";
  for (uint32_t k = 0; k < m->function_count; k++) {
    const an_function *row = &m->functions[k];
    if (!row->name || !row->signature || !row->fn || (row->flags & ~(unsigned)AN_DIRTY)) {
      snprintf(error, size, "row %u of the module's function table is not valid", (unsigned)k);
      return error;
    }
  }
  const an_type *types;
  uint32_t type_count = module_types(m, &types);
  if (type_count > MODULE_MAX_TYPES || (type_count && !types)) return "the module's type table is not valid";
  for (uint32_t k = 0; k < type_count; k++) {
    if (!types[k].name || !types[k].shape || (types[k].kind != AN_STRUCT && types[k].kind != AN_ENUM)) {
      snprintf(error, size, "row %u of the module's type table is not valid", (unsigned)k);
      return error;
    }
  }
  const an_resource_type *resources;
  uint32_t resource_count = module_resources(m, &resources);
  if (resource_count > MODULE_MAX_RESOURCES || (resource_count && !resources))
    return "the module's resource table is not valid";
  for (uint32_t k = 0; k < resource_count; k++) {
    if (!resources[k].name) {
      snprintf(error, size, "row %u of the module's resource table is not valid", (unsigned)k);
      return error;
    }
  }
  return NULL;
}

/* Sorts the rows of LIB's module (sort_rows): NULL, or in ERROR the message of two rows of one name, in one table or
   a type and a resource (one merge of the two sorted indexes): a signature names both kinds by their bare names. */
static const char *index_module(native_library *lib, char *error, size_t size) {
  const an_type *types;
  const an_resource_type *resources;
  uint32_t type_count = module_types(lib->module, &types);
  uint32_t resource_count = module_resources(lib->module, &resources);
  const char *problem = sort_rows(types, type_count, sizeof *types, "type", &lib->type_index, error, size);
  if (problem) return problem;
  problem = sort_rows(resources, resource_count, sizeof *resources, "resource", &lib->resource_index, error, size);
  if (problem) return problem;
  for (uint32_t t = 0, r = 0; t < type_count && r < resource_count;) {
    int c = strcmp(*lib->type_index[t], *lib->resource_index[r]);
    if (c == 0) {
      snprintf(error, size, "the module has a type and a resource named %.64s", *lib->type_index[t]);
      return error;
    }
    if (c < 0) {
      t++;
    } else {
      r++;
    }
  }
  return NULL;
}

/* Loads LIB: its init (the export of its library, or the one it was registered with), the checks of the module, its
   rows sorted by name and its load function. NULL, or the message of the failure (malloc'd). One module named two ways
   ("libx.so" and its path) has one init, so the module that another entry of FIRST, the list of the run, loaded is
   taken as it is: init and load run once. */
static char *library_load(native_library *lib, const native_library *first) {
  char error[512];
  if (!lib->init) {
    void *entry = agc_ffi_symbol(lib->name, "agentica_native_init", error, sizeof error);
    if (!entry) return agc_ffi_text_copy(error, strlen(error));
    /* POSIX and Windows give a function's address as an object pointer. */
    memcpy(&lib->init, &entry, sizeof lib->init);
  }
  for (const native_library *other = first; other; other = other->next) {
    if (other == lib || !other->tried || other->init != lib->init) continue;
    if (other->error) return agc_ffi_text_copy(other->error, strlen(other->error));
    lib->module = other->module;
    (void)index_module(lib, error, sizeof error);
    return NULL;
  }
  const an_module *m = lib->init(&API);
  const char *problem = module_problem(m, error, sizeof error);
  if (!problem) {
    lib->module = m;
    problem = index_module(lib, error, sizeof error);
  }
  if (!problem && m->load) {
    const char *refused = m->load();
    if (refused) {
      snprintf(error, sizeof error, "the module refused to load: %s", refused);
      problem = error;
    }
  }
  if (!problem) return NULL;
  lib->module = NULL;
  return agc_ffi_text_copy(problem, strlen(problem));
}

/* The module of the library NAME (LEN bytes), loaded at its first bind. Under rt->sync (vm/ffi.c, find_entry). */
static native_library *module_of(agc_vm *vm, const char *name, size_t len, uint32_t span) {
  agc_runtime *rt = vm->rt;
  agc_sync_assert(vm);
  native_library *lib = rt->native_modules;
  while (lib && (strlen(lib->name) != len || memcmp(lib->name, name, len) != 0)) lib = lib->next;
  if (!lib) {
    /* The fuzz driver opens no library: only the modules that the binary carries run there. */
    if (rt->no_files) agc_fail(vm, "RUNTIME-NATIVE-DENIED", "native calls are off in this run", span);
    lib = library_new(vm, name, len, NULL);
  }
  if (!lib->tried) {
    lib->tried = true;
    lib->error = library_load(lib, rt->native_modules);
  }
  if (lib->error) fail_with(vm, "RUNTIME-NATIVE-LOAD", span, "native module %s: %s", lib->name, lib->error);
  return lib;
}

/* The rows of LIB's type and resource tables named NAME (LEN bytes), or NULL. */
static const an_type *type_row(const native_library *lib, const char *name, size_t len) {
  const an_type *rows;
  return row_named(lib->type_index, module_types(lib->module, &rows), name, len);
}

static const an_resource_type *resource_row(const native_library *lib, const char *name, size_t len) {
  const an_resource_type *rows;
  return row_named(lib->resource_index, module_resources(lib->module, &rows), name, len);
}

/* Each struct or enum block must be a type of the module LIB, of its name, with the same kind and the same shape, byte
   for byte, and each resource block a resource of LIB, whose row it then holds; else RUNTIME-NATIVE-SIGNATURE. */
static void check_blocks(agc_vm *vm, const native_library *lib, block_list *blocks, uint32_t span) {
  const an_resource_type *resources;
  (void)module_resources(lib->module, &resources);
  for (uint32_t k = 0; k < blocks->count; k++) {
    type_block *b = &blocks->items[k];
    int name_len = (int)b->name_len;
    if (b->kind == B_RESOURCE) {
      const an_resource_type *row = resource_row(lib, b->name, b->name_len);
      if (!row)
        fail_with(vm, "RUNTIME-NATIVE-SIGNATURE", span, "native module %s has no resource %.*s", lib->name, name_len,
                  b->name);
      b->index = (uint32_t)(row - resources);
      continue;
    }
    const an_type *row = type_row(lib, b->name, b->name_len);
    if (!row)
      fail_with(vm, "RUNTIME-NATIVE-SIGNATURE", span, "native module %s has no type %.*s", lib->name, name_len,
                b->name);
    if (row->kind != (b->kind == B_ENUM ? AN_ENUM : AN_STRUCT) || strlen(row->shape) != b->shape_len ||
        memcmp(row->shape, b->shape, b->shape_len) != 0)
      fail_with(vm, "RUNTIME-NATIVE-SIGNATURE", span,
                "%s %.*s in native module %s is %s, but the program declares %.*s",
                row->kind == AN_ENUM ? "enum" : "struct", name_len, b->name, lib->name, row->shape,
                (int)b->shape_len, b->shape);
  }
}

/* FN's view of the module's tables that the blocks name (check_blocks found each): the program's index of each type
   row, UNBOUND for the others, and whether it reaches each resource row; then the row of each resource kind of a
   parameter or the result, which parse_type gave as the position of its block, and the parameters that are
   resources. */
static void bind_tables(agc_native_fn *fn, const native_library *lib, const block_list *blocks) {
  fn->type_count = module_types(lib->module, &fn->type_rows);
  fn->resource_count = module_resources(lib->module, &fn->resource_rows);
  if (fn->type_count) {
    fn->types = malloc(agc_size_mul(fn->type_count, sizeof *fn->types));
    if (!fn->types) agc_out_of_memory();
    for (uint32_t k = 0; k < fn->type_count; k++) fn->types[k] = UNBOUND;
  }
  if (fn->resource_count) {
    fn->resources = calloc(fn->resource_count, sizeof *fn->resources);
    if (!fn->resources) agc_out_of_memory();
  }
  for (uint32_t k = 0; k < blocks->count; k++) {
    const type_block *b = &blocks->items[k];
    if (b->kind == B_RESOURCE)
      fn->resources[b->index] = true;
    else
      fn->types[type_row(lib, b->name, b->name_len) - fn->type_rows] = b->index;
  }
  for (uint32_t k = 0; k < fn->arity; k++) {
    if (fn->params[k] != K_RESOURCE) continue;
    fn->param_ids[k] = blocks->items[fn->param_ids[k]].index;
    fn->holds[fn->hold_count++] = (uint8_t)k;
  }
  // cchecker: ignore CC-TIDY-CLANG-ANALYZER-CORE-NULLDEREFERENCE: result_id came from a found block
  if (fn->result == K_RESOURCE) fn->result_id = blocks->items[fn->result_id].index;
}

/* The profile's lines of the functions of native modules that ran (AGENTICA_VM_TRACE=profile), by library and bind:
   the calls, the time in C in microseconds and the mode. */
static void report_native(const agc_vm *vm) {
  const agc_trace *tr = &vm->rt->trace;
  for (const native_library *lib = vm->rt->native_modules; lib; lib = lib->next)
    for (const agc_native_fn *fn = lib->fns; fn; fn = fn->next)
      if (fn->calls)
        AGC_TRACE(tr, AGC_TRACE_PROFILE, "native calls=%" PRIu64 " us=%" PRIu64 " mode=%s name=%s module=%s",
                  fn->calls, fn->ns / 1000u, fn->dirty ? "dirty" : "short", fn->row->name, lib->name);
}

/* Binds TEXT, the LEN bytes after "module " of a signature ("TYPES CANON SYMBOL LIBRARY", DIRTY for a compute def).
   The bytecode may hold anything, so the type blocks and the canonical type are parsed with bounds, and each block
   checked against the program, before the module is asked; then the row of SYMBOL must have the same signature, byte
   for byte, and the same mode, and the module the same types and resources. */
agc_native_fn *agc_native_bind(agc_vm *vm, const char *text, size_t len, bool dirty, uint32_t span) {
  const char *at = text, *end = text + len;
  block_list blocks = read_blocks(vm, &at, end, span);
  const char *canon = at;
  agc_native_fn parsed = {0};
  if (!parse_canon(&at, end, &blocks, &parsed)) bad_signature(vm, span);
  size_t canon_len = (size_t)(at - canon);
  if (!skip(&at, end, " ")) bad_signature(vm, span);
  const char *symbol = at;
  while (at < end && *at != ' ') at++;
  size_t symbol_len = (size_t)(at - symbol);
  if (symbol_len == 0 || !skip(&at, end, " ")) bad_signature(vm, span);
  size_t library_len = (size_t)(end - at);
  if (library_len == 0 || memchr(at, 0, library_len) || memchr(symbol, 0, symbol_len))
    agc_fail(vm, "RUNTIME-NATIVE-LOAD", "a library or function name is empty or holds a NUL character", span);
  native_library *lib = module_of(vm, at, library_len, span);
  const an_module *m = lib->module;
  const an_function *row = NULL;
  // cchecker: ignore CC-TIDY-CLANG-ANALYZER-CORE-NULLDEREFERENCE: module_of fails unless lib->module is loaded
  for (uint32_t k = 0; k < m->function_count && !row; k++)
    if (strlen(m->functions[k].name) == symbol_len && memcmp(m->functions[k].name, symbol, symbol_len) == 0)
      row = &m->functions[k];
  if (!row)
    fail_with(vm, "RUNTIME-NATIVE-SIGNATURE", span, "native module %s has no function %.*s", lib->name,
              (int)symbol_len, symbol);
  if (strlen(row->signature) != canon_len || memcmp(row->signature, canon, canon_len) != 0)
    fail_with(vm, "RUNTIME-NATIVE-SIGNATURE", span, "%s in native module %s is %s, but the program declares %.*s",
              row->name, lib->name, row->signature, (int)canon_len, canon);
  if (((row->flags & AN_DIRTY) != 0) != dirty)
    fail_with(vm, "RUNTIME-NATIVE-SIGNATURE", span, "%s in native module %s is %s, but the program declares a %s",
              row->name, lib->name, dirty ? "short function" : "dirty function", dirty ? "compute def" : "def");
  check_blocks(vm, lib, &blocks, span);
  agc_native_fn *fn = malloc(sizeof *fn);
  if (!fn) agc_out_of_memory();
  *fn = parsed;
  fn->row = row;
  fn->lib = lib;
  fn->carried = lib->carried;
  fn->dirty = dirty;
  bind_tables(fn, lib, &blocks);
  /* The row's signature is the canonical one, so its result follows the one ") -> " (no type holds a parenthesis). */
  fn->result_type = strstr(row->signature, ") -> ") + 5;
  atomic_init(&fn->warned, false);
  fn->next = lib->fns;
  lib->fns = fn;
  if (AGC_PROFILE_REPORTS(vm)) vm->profile->report_native = report_native;
  return fn;
}

uint32_t agc_native_arity(const agc_native_fn *fn) { return fn->arity; }

/* The library's list is not unlinked: agc_ffi_forget unbinds every function of the run, then the modules go. */
void agc_native_unbind(agc_native_fn *fn) {
  if (fn) {
    free(fn->types);
    free(fn->resources);
  }
  free(fn);
}

void agc_native_register(agc_vm *vm, const char *library, agc_native_init init) {
  agc_sync_take(vm);
  (void)library_new(vm, library, strlen(library), init);
  agc_sync_drop(vm);
}

void agc_native_forget(agc_runtime *rt) {
  while (rt->native_modules) {
    native_library *lib = rt->native_modules;
    rt->native_modules = lib->next;
    free(lib->name);
    free(lib->error);
    free((void *)lib->type_index);
    free((void *)lib->resource_index);
    free(lib);
  }
}

static bool optional_variant(const agc_program *p, uint32_t variant, bool *some) {
  if (!p || p->optional == UINT32_MAX || (variant != p->optional && variant != p->optional + 1)) return false;
  *some = variant != p->optional;
  return true;
}

/* Whether VARIANT is one of the enum of program P at index ID (a type block checked it), with in *AT its position. */
static bool enum_variant(const agc_program *p, uint32_t id, uint32_t variant, uint32_t *at) {
  const agc_enum_def *def = &p->enums[id];
  if (variant < def->first || variant - def->first >= def->count) return false;
  *at = variant - def->first;
  return true;
}

/* Whether V has the outer type of KIND: its tag, for an Optional the variant of the program's Optional enum, for a
   struct or an enum the type at ID of the program's table, and for a resource the row ID of FN's resource table. */
static bool outer_matches(agc_vm *vm, const agc_native_fn *fn, uint8_t kind, uint32_t id, agc_value v) {
  if (v.tag != KIND_TAGS[kind]) return false;
  bool some;
  uint32_t at;
  switch (kind) {
  case K_OPTIONAL:
    return optional_variant(vm->rt->program, agc_as_enum(vm, v)->variant, &some);
  case K_STRUCT:
    return agc_as_struct(vm, v)->type == id;
  case K_ENUM:
    return id != UNBOUND && enum_variant(vm->rt->program, id, agc_as_enum(vm, v)->variant, &at);
  case K_RESOURCE:
    return id < fn->resource_count && agc_as_c_resource(vm, v)->row == &fn->resource_rows[id];
  default:
    return true;
  }
}

/* The kind of the type whose text starts at *AT, which moves past its name and the "[" of a List, Map, Optional or
   Result, with in *ROW its row in FN's type or resource table for a struct, an enum or a resource; -1 for another
   name. */
static int kind_at(const agc_native_fn *fn, const char **at, uint32_t *row) {
  const char *name = *at;
  while (name_char(**at)) (*at)++;
  size_t len = (size_t)(*at - name);
  int kind = kind_named(name, len);
  if (kind >= 0) {
    if (KINDS[kind].arity) (*at)++;
    return kind;
  }
  const an_type *type = type_row(fn->lib, name, len);
  if (type) {
    *row = (uint32_t)(type - fn->type_rows);
    return type->kind == AN_ENUM ? K_ENUM : K_STRUCT;
  }
  const an_resource_type *resource = resource_row(fn->lib, name, len);
  if (!resource) return -1;
  *row = (uint32_t)(resource - fn->resource_rows);
  return K_RESOURCE;
}

/* Pushes V with its type text TYPE on the check stack (GC memory, so the values stay reachable), growing it. */
static check_item *push_check(check_item *stack, size_t *n, size_t *cap, agc_value v, const char *type) {
  if (*n == *cap) {
    size_t more = agc_size_mul(*cap, 2);
    check_item *grown = agc_alloc(agc_size_mul(more, sizeof *grown));
    memcpy(grown, stack, *n * sizeof *grown);
    stack = grown;
    *cap = more;
  }
  stack[(*n)++] = (check_item){v, type};
  return stack;
}

/* The text after the type at AT (one type of a signature or a shape, NUL-terminated module text). */
static const char *after_type(const char *at) {
  // cchecker: ignore CC-TIDY-CLANG-ANALYZER-CORE-NONNULLPARAMCHECKER: AT is a checked signature or shape
  const char *end = at + strlen(at);
  return skip_type(&at, end) ? at : end;
}

/* Whether all of V is of the declared result type of FN, nested values included (the builds of AGC_LEAF_CHECK check
   every result so, so a bug of a module shows in its tests): a walk with a stack, whose items are the values left to
   check and the text of each one's type, read in the row's signature and the shapes of its types. The value is finite
   and acyclic, so the walk ends. Every struct and enum it meets is one the signature reaches, so FN binds it. */
static bool deep_fits(agc_vm *vm, const agc_native_fn *fn, agc_value result) {
  size_t n = 0, cap = 16;
  check_item *stack = agc_alloc(cap * sizeof *stack);
  stack = push_check(stack, &n, &cap, result, fn->result_type);
  while (n) {
    check_item item = stack[--n];
    const char *at = item.type;
    uint32_t row = 0;
    int kind = kind_at(fn, &at, &row);
    uint32_t id = kind == K_STRUCT || kind == K_ENUM ? fn->types[row] : row;
    if (kind < 0 || !outer_matches(vm, fn, (uint8_t)kind, id, item.v)) return false;
    if (kind == K_LIST) {
      agc_list_cursor c;
      agc_value v;
      agc_list_cursor_begin(&c, agc_as_list(vm, item.v), 0);
      while (agc_list_cursor_next(&c, &v)) stack = push_check(stack, &n, &cap, v, at);
    } else if (kind == K_MAP) {
      const agc_map *m = agc_as_map(vm, item.v);
      const char *value_type = after_type(at) + 2;
      agc_value *keys = agc_map_keys(vm, m, 0), value;
      for (size_t k = 0; k < m->size && agc_map_get(vm, m, keys[k], &value); k++) {
        stack = push_check(stack, &n, &cap, keys[k], at);
        stack = push_check(stack, &n, &cap, value, value_type);
      }
    } else if (kind == K_OPTIONAL) {
      const agc_enum *e = agc_as_enum(vm, item.v);
      bool some = e->variant != vm->rt->program->optional;
      if (e->n != (some ? 1u : 0u)) return false;
      if (some) stack = push_check(stack, &n, &cap, e->payload[0], at);
    } else if (kind == K_RESULT) {
      const agc_result *r = agc_as_result(vm, item.v);
      if (!r->ok && !agc_is(r->value, AGC_T_STRING)) return false;
      if (r->ok) stack = push_check(stack, &n, &cap, r->value, at);
    } else if (kind == K_STRUCT) {
      const agc_struct *s = agc_as_struct(vm, item.v);
      if (s->n != vm->rt->program->structs[id].count) return false;
      const char *field = fn->type_rows[row].shape;
      for (uint32_t k = 0; k < s->n; k++) {
        field = strstr(field, ": ") + 2;
        stack = push_check(stack, &n, &cap, s->fields[k], field);
        field = after_type(field);
      }
    } else if (kind == K_ENUM) {
      const agc_enum *e = agc_as_enum(vm, item.v);
      uint32_t variant = 0;
      (void)enum_variant(vm->rt->program, id, e->variant, &variant);
      if (e->n != vm->rt->program->variants[e->variant].arity) return false;
      const char *shape = fn->type_rows[row].shape;
      for (uint32_t k = 0; k < variant; k++) shape = strstr(shape, " | ") + 3;
      const char *payload = strchr(shape, '(');
      const char *next = strstr(shape, " | ");
      if (payload && (!next || payload < next)) payload++;
      for (uint32_t k = 0; k < e->n; k++) {
        stack = push_check(stack, &n, &cap, e->payload[k], payload);
        payload = after_type(payload) + 2;
      }
    }
  }
  return true;
}

/* The module's function, with the callbacks of extern blocks refused: a call never calls back into Agentica. */
static void run_module(void *arg) {
  module_call *call = arg;
  call->result = call->fn->row->fn(call->env, (int)call->fn->arity, call->argv);
}

/* The time of one call of FN, NS (wall time): the profile's counts (one scheduler), and in the builds of
   AGC_LEAF_CHECK one warning per short function that took over SLOW_NS, ten times the about 100 microseconds that a
   short call may take. Where the thread's CPU time before the call is known (CPU_BEFORE; NULL for a dirty call or
   where agc_thread_cpu_ns does not answer), a call under STALL_NS is judged by the CPU time it used: its wall time
   also counts the turns of other threads and processes (a busy machine, a shared CI runner: a few ms per turn) and
   the waits on a lock that another scheduler holds. So a call that blocks or sleeps under STALL_NS is not reported;
   one that blocks for STALL_NS or more still warns. Those builds
   only test, so the line goes straight to the C stream. */
static void note_time(agc_vm *vm, agc_native_fn *fn, uint64_t ns, const uint64_t *cpu_before) {
  if (AGC_PROFILE_REPORTS(vm)) {
    fn->calls++;
    fn->ns += ns;
  }
  if (!AGC_LEAF_CHECK || fn->dirty || ns <= SLOW_NS) return;
  uint64_t cpu_ns;
  if (ns < STALL_NS && cpu_before && agc_thread_cpu_ns(&cpu_ns)) ns = cpu_ns - *cpu_before;
  if (ns > SLOW_NS && !atomic_exchange(&fn->warned, true))
    fprintf(stderr, "agentica: warning: the short native function %s took %" PRIu64 " us; declare it compute def\n",
            fn->row->name, ns / 1000u);
}

/* Fails OUT when its value is not of FN's result type: its outer type, and in the builds of AGC_LEAF_CHECK all of
   it. */
static void check_result(agc_vm *vm, const agc_native_fn *fn, agc_native_outcome *out) {
  if (outer_matches(vm, fn, fn->result, fn->result_id, out->value) &&
      (!AGC_LEAF_CHECK || deep_fits(vm, fn, out->value)))
    return;
  char text[256];
  int n = snprintf(text, sizeof text, "%s returned a value that is not of its result type", fn->row->name);
  out->code = FAILED;
  out->message = decoded(text, n < 0 ? 0 : (size_t)n < sizeof text ? (size_t)n : sizeof text - 1);
  out->value = agc_void();
}

uint32_t agc_native_arguments(agc_vm *vm, const agc_native_fn *fn, const agc_list *args, agc_value *argv,
                              agc_c_resource **held, uint32_t span) {
  /* The fuzz driver's runs have no compute pool to wait for at their end: only short calls of carried modules. */
  if (vm->rt->no_files && (!fn->carried || fn->dirty))
    agc_fail(vm, "RUNTIME-NATIVE-DENIED", "native calls are off in this run", span);
  agc_list_cursor cursor;
  agc_list_cursor_begin(&cursor, args, 0);
  for (uint32_t k = 0; k < fn->arity; k++) {
    if (!agc_list_cursor_next(&cursor, &argv[k]) || !outer_matches(vm, fn, fn->params[k], fn->param_ids[k], argv[k]))
      agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: a native argument of another type", span);
  }
  for (uint32_t k = 0; k < fn->hold_count; k++) held[k] = agc_as_c_resource(vm, argv[fn->holds[k]]);
  return fn->hold_count;
}

/* One short call of FN with ARGV (agc_native_arguments checked them), on this scheduler without rt->sync: the module
   must be thread-safe (agentica_native.h). The result's type is checked after; a failure goes back in the outcome,
   for vm/ffi.c to raise once it has let go of HELD, so no longjmp crosses the module's frames (only out of memory,
   which exits, the fuzz driver's allocation limit and the consistency checks of vm/map.c, which a valid map never
   fails, leave from inside an API call). The terms C gets are on this stack and the values they name stay reachable
   from the caller's registers. */
agc_native_outcome agc_native_call(agc_vm *vm, agc_native_fn *fn, const agc_value *argv, agc_c_resource *const *held,
                                   uint32_t holds) {
  an_term terms[AGC_FFI_MAX_PARAMS];
  for (uint32_t k = 0; k < fn->arity; k++) terms[k] = term_of(argv[k]);
  agc_charge(vm, CALL_COST);
  an_env env = {&API, vm, fn, held, holds, NULL, NULL, NULL};
  module_call made = {fn, &env, terms, {{0, 0}}};
  bool timed = AGC_PROFILE_REPORTS(vm) || AGC_LEAF_CHECK;
  uint64_t cpu_ns = 0;
  bool cpu_known = AGC_LEAF_CHECK && agc_thread_cpu_ns(&cpu_ns);
  uint64_t began = timed ? agc_trace_now() : 0;
  agc_ffi_refusing_callbacks(run_module, &made);
  if (timed) note_time(vm, fn, agc_trace_now() - began, cpu_known ? &cpu_ns : NULL);
  agc_native_outcome out = {value_of(made.result), env.code, env.message};
  if (!out.code) check_result(vm, fn, &out);
  return out;
}

/* SIZE bytes of the arena of D, aligned for any C object; the arena lives until agc_native_dirty_free. */
static void *arena_take(agc_native_dirty *d, size_t size) {
  size_t align = _Alignof(max_align_t);
  size = size ? agc_size_add(size, align - 1) & ~(align - 1) : align;
  arena_chunk *c = d->chunks;
  if (!c || c->cap - c->used < size) {
    size_t cap = size > CHUNK_BYTES ? size : CHUNK_BYTES;
    c = malloc(agc_size_add(sizeof *c, cap));
    if (!c) agc_out_of_memory();
    c->next = d->chunks;
    c->used = 0;
    c->cap = cap;
    d->chunks = c;
  }
  void *at = (char *)c->data + c->used;
  c->used += size;
  // cchecker: ignore CC-GCC-ANALYZER-MALLOC-LEAK: the chunk is linked on d->chunks, which agc_native_dirty_free frees
  return at;
}

/* A new node of D, and the term that names it. */
static an_term stage(agc_native_dirty *d, uint8_t kind, uint32_t id, size_t n, void *data) {
  if (d->count == d->cap) {
    size_t cap = d->cap ? agc_size_mul(d->cap, 2) : 64;
    staged *nodes = realloc(d->nodes, agc_size_mul(cap, sizeof *nodes));
    if (!nodes) agc_out_of_memory();
    d->nodes = nodes;
    d->cap = cap;
  }
  d->nodes[d->count] = (staged){kind, id, n, data};
  // cchecker: ignore CC-GCC-ANALYZER-MALLOC-LEAK: d->nodes keeps the block, which agc_native_dirty_free frees
  return term_of(agc_word_value(STAGED_TAG, d->count++));
}

/* Whether V is a term that D staged, with in *AT its node; false for any other value, and for a staged tag past the
   nodes, which only a module that kept a term past its call has. */
static bool staged_at(const agc_native_dirty *d, agc_value v, size_t *at) {
  if (v.tag != STAGED_TAG || agc_value_word(v) >= d->count) return false;
  *at = (size_t)agc_value_word(v);
  return true;
}

static bool valid_term(const agc_native_dirty *d, agc_value v) {
  size_t at;
  return v.tag != STAGED_TAG || staged_at(d, v, &at);
}

/* The N terms at ITEMS copied into D's arena as values, or NULL (the call fails) when one is not valid. */
static agc_value *stage_values(agc_native_dirty *d, const an_term *items, size_t n) {
  agc_value *copy = arena_take(d, agc_size_mul(n, sizeof *copy));
  for (size_t k = 0; k < n; k++) {
    copy[k] = value_of(items[k]);
    if (!valid_term(d, copy[k])) return NULL;
  }
  return copy;
}

/* A copy of LEN bytes in D's arena. */
static void *stage_bytes(agc_native_dirty *d, const void *data, size_t len) {
  void *copy = arena_take(d, len);
  if (len) memcpy(copy, data, len);
  return copy;
}

/* The values a node holds, N of them (none for text, bytes and a resource). */
static const agc_value *node_items(const staged *s, size_t *n) {
  switch (s->kind) {
  case N_LIST:
  case N_STRUCT:
  case N_ENUM: *n = s->n; break;
  case N_MAP: *n = agc_size_mul(s->n, 2); break;
  case N_PUT: *n = 3; break;
  case N_SOME:
  case N_OK: *n = 1; break;
  default: *n = 0; break;
  }
  return s->data;
}

/* The value that V stands for once the nodes below it are BUILT. */
static agc_value resolved(const agc_native_dirty *d, const agc_value *built, agc_value v) {
  size_t at;
  return staged_at(d, v, &at) ? built[at] : v;
}

static agc_value text_of(agc_vm *vm, const staged *s) {
  size_t chars = 0;
  (void)agc_utf8_chars(s->data, s->n, &chars);
  return agc_string_value(agc_small_string(vm, s->data, s->n, chars));
}

/* The value of node S of D, the nodes below it BUILT. A resource gets its value and leaves the node. */
static agc_value build_node(agc_vm *vm, agc_native_dirty *d, staged *s, const agc_value *built) {
  const agc_value *items = s->data;
  switch (s->kind) {
  case N_STRING: return text_of(vm, s);
  case N_BYTES: return agc_bytes_value(agc_make_bytes(s->data, s->n));
  case N_LIST: {
    agc_list_builder b;
    agc_list_builder_sized(&b, s->n);
    for (size_t k = 0; k < s->n; k++) agc_list_builder_push(&b, resolved(d, built, items[k]));
    return agc_list_value(agc_list_builder_finish(&b));
  }
  case N_MAP: {
    agc_map *m = agc_new_map();
    for (size_t k = 0; k < s->n; k++)
      m = agc_map_put(vm, m, resolved(d, built, items[k]), resolved(d, built, items[s->n + k]));
    return agc_map_value(m);
  }
  case N_PUT: {
    const agc_map *m = agc_as_map(vm, resolved(d, built, items[0]));
    return agc_map_value(agc_map_put(vm, m, resolved(d, built, items[1]), resolved(d, built, items[2])));
  }
  case N_SOME: return agc_optional_make(vm->rt->program, true, resolved(d, built, items[0]));
  case N_OK: return agc_result_value(true, resolved(d, built, items[0]));
  case N_ERROR: return agc_result_value(false, text_of(vm, s));
  case N_STRUCT: {
    agc_struct *st = agc_new_struct(s->id, (uint32_t)s->n);
    for (size_t k = 0; k < s->n; k++) st->fields[k] = resolved(d, built, items[k]);
    return agc_struct_value(st);
  }
  case N_ENUM: {
    agc_enum *e = agc_new_enum(s->id, (uint32_t)s->n);
    for (size_t k = 0; k < s->n; k++) e->payload[k] = resolved(d, built, items[k]);
    return agc_enum_value(e);
  }
  default: {
    const an_resource_type *row = &d->fn->resource_rows[s->id];
    void *state = s->data;
    s->data = NULL;
    return agc_ffi_module_resource(vm, row, row->name, state, d->held, d->holds);
  }
  }
}

void agc_native_dirty_states(agc_native_dirty *d, void (*take)(const void *row, void *state, void *arg), void *arg) {
  for (size_t k = d->count; k-- > 0;) {
    staged *s = &d->nodes[k];
    if (s->kind != N_RESOURCE || !s->data) continue;
    void *state = s->data;
    s->data = NULL;
    take(&d->fn->resource_rows[s->id], state, arg);
  }
}

static void free_state_now(const void *row, void *state, void *arg) {
  (void)arg;
  agc_native_free_state(row, state);
}

/* Frees the state of each resource node of D that has no value: the module's free function, on this scheduler. */
static void drop_staged(agc_native_dirty *d) { agc_native_dirty_states(d, free_state_now, NULL); }

/* The value of D's result: each node that it reaches is built, in index order, so the nodes below one are built
   first; the others are not, and the state of a resource among them is freed, newest first. BUILT is GC memory, so a
   value built stays reachable through the next allocations. */
static agc_value build(agc_vm *vm, agc_native_dirty *d) {
  agc_value result = value_of(d->result);
  size_t at;
  bool *live = calloc(d->count ? d->count : 1, sizeof *live);
  if (!live) agc_out_of_memory();
  if (staged_at(d, result, &at)) live[at] = true;
  for (size_t k = d->count; k-- > 0;) {
    if (!live[k]) continue;
    size_t n;
    const agc_value *items = node_items(&d->nodes[k], &n);
    for (size_t j = 0; j < n; j++)
      if (staged_at(d, items[j], &at)) live[at] = true;
  }
  agc_value *built = d->count ? agc_alloc(agc_size_mul(d->count, sizeof *built)) : NULL;
  for (size_t k = 0; k < d->count; k++) {
    if (live[k]) built[k] = build_node(vm, d, &d->nodes[k], built);
  }
  free(live);
  drop_staged(d);
  return resolved(d, built, result);
}

agc_native_dirty *agc_native_dirty_new(agc_vm *vm, agc_native_fn *fn, const agc_value *argv,
                                       agc_c_resource *const *held, uint32_t holds) {
  agc_native_dirty *d = calloc(1, sizeof *d);
  if (!d) agc_out_of_memory();
  d->vm = vm;
  d->fn = fn;
  d->profile = AGC_PROFILE_REPORTS(vm);
  memcpy(d->argv, argv, fn->arity * sizeof *argv);
  d->held = held;
  d->holds = holds;
  agc_charge(vm, CALL_COST);
  return d;
}

/* On a pool thread: C reads the arguments in place and stages what it makes (agc_native_dirty). */
void agc_native_dirty_run(agc_native_dirty *d) {
  an_term terms[AGC_FFI_MAX_PARAMS];
  for (uint32_t k = 0; k < d->fn->arity; k++) terms[k] = term_of(d->argv[k]);
  an_env env = {&API, d->vm, d->fn, d->held, d->holds, NULL, NULL, d};
  module_call made = {d->fn, &env, terms, {{0, 0}}};
  uint64_t began = d->profile ? agc_trace_now() : 0;
  agc_ffi_refusing_callbacks(run_module, &made);
  if (d->profile) d->ns = agc_trace_now() - began;
  d->result = made.result;
  d->ran = true;
}

agc_native_outcome agc_native_dirty_done(agc_vm *vm, agc_native_dirty *d, bool take) {
  agc_native_outcome out = {agc_void(), NULL, NULL};
  if (d->ran) note_time(vm, d->fn, d->ns, NULL);
  if (!take || d->code) {
    drop_staged(d);
    if (take) {
      out.code = d->code;
      out.message = decoded(d->message, d->message_len);
    }
    return out;
  }
  agc_charge_bytes(vm, d->bytes);
  out.value = build(vm, d);
  check_result(vm, d->fn, &out);
  return out;
}

/* After dirty_done nothing is left to free but memory. Without it (a job dropped once the run is over) a resource
   state is freed as memory alone: its module's free function never runs on the I/O thread. */
void agc_native_dirty_free(agc_native_dirty *d) {
  if (!d) return;
  for (size_t k = 0; k < d->count; k++)
    if (d->nodes[k].kind == N_RESOURCE) free(d->nodes[k].data);
  while (d->chunks) {
    arena_chunk *c = d->chunks;
    d->chunks = c->next;
    free(c);
  }
  free(d->nodes);
  free(d->message);
  free(d);
}

/* The module's free function, with the callbacks of extern blocks refused, as for any free function. */
static void run_free_state(void *arg) {
  void **parts = arg;
  const an_resource_type *row = parts[0];
  row->free(parts[1]);
}

void agc_native_free_state(const void *row, void *state) {
  const an_resource_type *type = row;
  if (type->free) {
    void *parts[2] = {(void *)type, state};
    agc_ffi_refusing_callbacks(run_free_state, parts);
  }
  free(state);
}

/* Keeps the first failure of the call: CODE with "NAME: TEXT" (LEN bytes, decoded, as the module's text may not be
   UTF-8). Returns Void, the value of a constructor that failed. A short call makes only GC memory here, which the
   fuzz driver's allocation limit may leave behind; a dirty one keeps the text in malloc memory, decoded once it is
   back on a scheduler. */
static an_term env_fail(an_env *env, const char *code, const char *text, size_t len) {
  const char *name = env->fn->row->name;
  agc_native_dirty *d = env->dirty;
  if (d && !d->code) {
    size_t head = strlen(name);
    d->message_len = agc_size_add(agc_size_add(head, 2), len);
    d->message = malloc(d->message_len);
    if (!d->message) agc_out_of_memory();
    memcpy(d->message, name, head);
    memcpy(d->message + head, ": ", 2);
    if (len) memcpy(d->message + head + 2, text, len);
    d->code = code;
  } else if (!d && !env->code) {
    agc_string *head = agc_concat(decoded(name, strlen(name)), decoded(": ", 2));
    env->message = agc_concat(head, decoded(text, len));
    env->code = code;
  }
  return term_of(agc_void());
}

static an_term env_refuse(an_env *env, const char *text) { return env_fail(env, FAILED, text, strlen(text)); }

static an_term bad_term(an_env *env) { return env_refuse(env, "a term is not valid: one of another call"); }

static an_term api_int(an_env *env, int64_t n) {
  (void)env;
  return term_of(agc_int(n));
}

static bool api_get_int(an_env *env, an_term t, int64_t *n) {
  agc_value v = value_of(t);
  if (!agc_is(v, AGC_T_INT)) return false;
  *n = agc_as_int(env->vm, v);
  return true;
}

static an_term api_float(an_env *env, double x) {
  (void)env;
  return term_of(agc_float(x));
}

static bool api_get_float(an_env *env, an_term t, double *x) {
  agc_value v = value_of(t);
  if (!agc_is(v, AGC_T_FLOAT)) return false;
  *x = agc_as_float(env->vm, v);
  return true;
}

static an_term api_bool(an_env *env, bool b) {
  (void)env;
  return term_of(agc_bool(b));
}

static bool api_get_bool(an_env *env, an_term t, bool *b) {
  agc_value v = value_of(t);
  if (!agc_is(v, AGC_T_BOOL)) return false;
  *b = agc_as_bool(env->vm, v);
  return true;
}

static an_term api_void(an_env *env) {
  (void)env;
  return term_of(agc_void());
}

/* A String of DATA, or for a dirty call a node of KIND (N_STRING or N_ERROR) with a copy; Void, the call failed with
   REFUSAL, when DATA is not UTF-8. */
static an_term text_term(an_env *env, uint8_t kind, const char *data, size_t len, const char *refusal) {
  size_t chars;
  if (!agc_utf8_chars((const uint8_t *)data, len, &chars)) return env_refuse(env, refusal);
  agc_native_dirty *d = env->dirty;
  if (d) {
    d->bytes += len;
    return stage(d, kind, 0, len, stage_bytes(d, data, len));
  }
  agc_charge_bytes(env->vm, len);
  agc_value s = agc_string_value(agc_small_string(env->vm, data, len, chars));
  return term_of(kind == N_ERROR ? agc_result_value(false, s) : s);
}

static an_term api_string(an_env *env, const char *data, size_t len) {
  return text_term(env, N_STRING, data, len, "an_string got text that is not UTF-8");
}

static bool api_get_string(an_env *env, an_term t, const char **data, size_t *len) {
  agc_value v = value_of(t);
  if (!agc_is(v, AGC_T_STRING)) return false;
  const agc_string *s = agc_as_string(env->vm, v);
  *data = s->data;
  *len = s->bytes;
  return true;
}

static an_term api_bytes(an_env *env, const void *data, size_t len) {
  agc_native_dirty *d = env->dirty;
  if (d) {
    d->bytes += len;
    return stage(d, N_BYTES, 0, len, stage_bytes(d, data, len));
  }
  agc_charge_bytes(env->vm, len);
  return term_of(agc_bytes_value(agc_make_bytes(data, len)));
}

/* The bytes are zeroed, so a module that writes fewer than LEN shows no old memory. */
static an_term api_bytes_fill(an_env *env, size_t len, uint8_t **data) {
  agc_native_dirty *d = env->dirty;
  if (d) {
    d->bytes += len;
    *data = len ? arena_take(d, len) : NULL;
    if (len) memset(*data, 0, len);
    return stage(d, N_BYTES, 0, len, *data);
  }
  agc_charge_bytes(env->vm, len);
  if (len == 0) {
    *data = NULL;
    return term_of(agc_bytes_value(agc_empty_bytes()));
  }
  agc_bytes *b = agc_new_bytes(len);
  memset(b->data, 0, len);
  *data = b->data;
  return term_of(agc_bytes_value(b));
}

static bool api_get_bytes(an_env *env, an_term t, const uint8_t **data, size_t *len) {
  agc_value v = value_of(t);
  if (!agc_is(v, AGC_T_BYTES)) return false;
  *data = agc_bytes_data(env->vm, v, len);
  return true;
}

/* In a dirty call, a node of KIND with ID over a copy of the N ITEMS (a List, a struct or an enum value). */
static an_term stage_items(an_env *env, uint8_t kind, uint32_t id, const an_term *items, size_t n) {
  agc_native_dirty *d = env->dirty;
  agc_value *copy = stage_values(d, items, n);
  if (!copy) return bad_term(env);
  d->bytes += agc_size_mul(n, sizeof(agc_value));
  return stage(d, kind, id, n, copy);
}

static an_term api_list(an_env *env, const an_term *items, size_t n) {
  if (env->dirty) return stage_items(env, N_LIST, 0, items, n);
  agc_charge_bytes(env->vm, agc_size_mul(n, sizeof(agc_value)));
  agc_list_builder b;
  agc_list_builder_sized(&b, n);
  for (size_t k = 0; k < n; k++) agc_list_builder_push(&b, value_of(items[k]));
  return term_of(agc_list_value(agc_list_builder_finish(&b)));
}

/* A builder's items are charged as they are taken, so a module that never calls an_list_end pays too, and list_end
   charges nothing more; they are GC memory, or a dirty call's arena. */
static void charge_items(an_env *env, size_t slots) {
  size_t bytes = agc_size_mul(slots, sizeof(agc_value));
  if (env->dirty)
    env->dirty->bytes += bytes;
  else
    agc_charge_bytes(env->vm, bytes);
}

static agc_value *new_items(an_env *env, size_t slots) {
  size_t bytes = agc_size_mul(slots, sizeof(agc_value));
  return env->dirty ? arena_take(env->dirty, bytes) : agc_alloc(bytes);
}

/* The builder's state goes through memcpy both ways, so C's opaque words are never read as another type. */
static void api_list_begin(an_env *env, an_list_builder *b, size_t hint) {
  list_build build = {NULL, 0, hint < HINT_MAX ? hint : HINT_MAX};
  if (build.cap) {
    charge_items(env, build.cap);
    build.items = new_items(env, build.cap);
  }
  memcpy(b, &build, sizeof build);
}

static void api_list_push(an_env *env, an_list_builder *b, an_term item) {
  list_build build;
  memcpy(&build, b, sizeof build);
  agc_value v = value_of(item);
  if (env->dirty && !valid_term(env->dirty, v)) {
    (void)bad_term(env);
    return;
  }
  if (build.n == build.cap) {
    size_t cap = build.cap ? agc_size_mul(build.cap, 2) : 8;
    charge_items(env, cap - build.cap);
    agc_value *items = new_items(env, cap);
    if (build.n) memcpy(items, build.items, build.n * sizeof(agc_value));
    build.items = items;
    build.cap = cap;
  }
  build.items[build.n++] = v;
  memcpy(b, &build, sizeof build);
}

static an_term api_list_end(an_env *env, an_list_builder *b) {
  list_build build;
  memcpy(&build, b, sizeof build);
  if (env->dirty) return stage(env->dirty, N_LIST, 0, build.n, build.items);
  return term_of(agc_list_value(agc_list_from_array(build.items, build.n)));
}

static bool api_list_cursor(an_env *env, an_term list, an_list_cursor *c, size_t *len) {
  agc_value v = value_of(list);
  if (!agc_is(v, AGC_T_LIST)) return false;
  const agc_list *l = agc_as_list(env->vm, v);
  agc_list_cursor cursor;
  agc_list_cursor_begin(&cursor, l, 0);
  memcpy(c, &cursor, sizeof cursor);
  if (len) *len = agc_list_len(l);
  return true;
}

static bool api_list_next(an_env *env, an_list_cursor *c, an_term *item) {
  (void)env;
  agc_list_cursor cursor;
  memcpy(&cursor, c, sizeof cursor);
  agc_value v;
  bool more = agc_list_cursor_next(&cursor, &v);
  memcpy(c, &cursor, sizeof cursor);
  if (more) *item = term_of(v);
  return more;
}

/* The keys a Map takes: an Int, a String or a Bytes (vm/map.c fails on any other), or in a dirty call a String or
   Bytes that it staged. */
static bool map_key(const an_env *env, agc_value key) {
  size_t at;
  if (env->dirty && staged_at(env->dirty, key, &at))
    return env->dirty->nodes[at].kind == N_STRING || env->dirty->nodes[at].kind == N_BYTES;
  return agc_is(key, AGC_T_INT) || agc_is(key, AGC_T_STRING) || agc_is(key, AGC_T_BYTES);
}

static an_term api_map_from(an_env *env, const an_term *keys, const an_term *values, size_t n) {
  for (size_t k = 0; k < n; k++)
    if (!map_key(env, value_of(keys[k]))) return env_refuse(env, KEY_REFUSAL);
  agc_native_dirty *d = env->dirty;
  if (d) {
    agc_value *both = arena_take(d, agc_size_mul(agc_size_mul(n, 2), sizeof *both));
    for (size_t k = 0; k < n; k++) {
      both[k] = value_of(keys[k]);
      both[n + k] = value_of(values[k]);
      if (!valid_term(d, both[n + k])) return bad_term(env);
    }
    d->bytes += agc_size_mul(n, MAP_ENTRY_BYTES);
    return stage(d, N_MAP, 0, n, both);
  }
  agc_charge_bytes(env->vm, agc_size_mul(n, MAP_ENTRY_BYTES));
  agc_map *m = agc_new_map();
  for (size_t k = 0; k < n; k++) m = agc_map_put(env->vm, m, value_of(keys[k]), value_of(values[k]));
  return term_of(agc_map_value(m));
}

static an_term api_map_put(an_env *env, an_term map, an_term key, an_term value) {
  agc_value m = value_of(map), k = value_of(key);
  agc_native_dirty *d = env->dirty;
  size_t at;
  bool staged_map = d && staged_at(d, m, &at) && (d->nodes[at].kind == N_MAP || d->nodes[at].kind == N_PUT);
  if (!staged_map && !agc_is(m, AGC_T_MAP)) return env_refuse(env, "an_map_put got a value that is not a Map");
  if (!map_key(env, k)) return env_refuse(env, KEY_REFUSAL);
  if (d) {
    an_term three[3] = {map, key, value};
    agc_value *copy = stage_values(d, three, 3);
    if (!copy) return bad_term(env);
    d->bytes += MAP_ENTRY_BYTES;
    return stage(d, N_PUT, 0, 3, copy);
  }
  agc_charge_bytes(env->vm, MAP_ENTRY_BYTES);
  return term_of(agc_map_value(agc_map_put(env->vm, agc_as_map(env->vm, m), k, value_of(value))));
}

/* A dirty call looks up with no charge (agc_map_find): the pool thread must not touch the scheduler's task. What the
   lookup reads is charged with the result. */
static bool api_map_get(an_env *env, an_term map, an_term key, an_term *value) {
  agc_value m = value_of(map), k = value_of(key), found;
  if (!agc_is(m, AGC_T_MAP) || (!agc_is(k, AGC_T_INT) && !agc_is(k, AGC_T_STRING) && !agc_is(k, AGC_T_BYTES)))
    return false;
  const agc_map *table = agc_as_map(env->vm, m);
  agc_native_dirty *d = env->dirty;
  bool hit = d ? agc_map_find(env->vm->rt->hash_key, table, k, &found, &d->bytes)
               : agc_map_get(env->vm, table, k, &found);
  if (!hit) return false;
  *value = term_of(found);
  return true;
}

/* A dirty call takes the keys and values into its arena, with no GC memory and no charge (agc_map_entries_into). */
static bool api_map_cursor(an_env *env, an_term map, an_map_cursor *c, size_t *len) {
  agc_value v = value_of(map);
  if (!agc_is(v, AGC_T_MAP)) return false;
  const agc_map *m = agc_as_map(env->vm, v);
  agc_native_dirty *d = env->dirty;
  charge_items(env, d ? agc_size_mul(m->size, 2) : m->size);
  agc_value *keys = NULL, *values = NULL;
  if (m->size && d) {
    keys = new_items(env, agc_size_mul(m->size, 2));
    values = keys + m->size;
    if (!agc_map_entries_into(env->vm->rt->hash_key, m, keys, values, &d->bytes)) {
      (void)env_refuse(env, "a Map's key list does not match its table");
      return false;
    }
  } else if (m->size) {
    keys = agc_map_keys(env->vm, m, 0);
  }
  map_walk walk = {m, keys, values, 0, m->size};
  memcpy(c, &walk, sizeof walk);
  if (len) *len = m->size;
  return true;
}

/* Every key of the walk is in its map, which never changes: the lookup always finds it. */
static bool api_map_next(an_env *env, an_map_cursor *c, an_term *key, an_term *value) {
  map_walk walk;
  memcpy(&walk, c, sizeof walk);
  agc_value found;
  if (walk.at == walk.n) return false;
  if (walk.values)
    found = walk.values[walk.at];
  else if (!agc_map_get(env->vm, walk.map, walk.keys[walk.at], &found))
    return false;
  *key = term_of(walk.keys[walk.at++]);
  *value = term_of(found);
  memcpy(c, &walk, sizeof walk);
  return true;
}

/* An Optional needs the program's Optional enum, which only hand-made bytecode lacks. none is the one value that the
   loader made, so a dirty call needs no node for it. */
static an_term optional_term(an_env *env, bool some, an_term value) {
  const agc_program *p = env->vm->rt->program;
  if (!p || p->optional == UINT32_MAX) return env_fail(env, "RUNTIME-INTERNAL", NO_OPTIONAL, sizeof NO_OPTIONAL - 1);
  agc_native_dirty *d = env->dirty;
  if (d && some) {
    agc_value *copy = stage_values(d, &value, 1);
    if (!copy) return bad_term(env);
    d->bytes += 2 * sizeof(agc_value);
    return stage(d, N_SOME, 0, 1, copy);
  }
  return term_of(agc_optional_make(p, some, some ? value_of(value) : agc_void()));
}

static an_term api_none(an_env *env) { return optional_term(env, false, term_of(agc_void())); }

static an_term api_some(an_env *env, an_term value) { return optional_term(env, true, value); }

static bool api_get_optional(an_env *env, an_term t, bool *some, an_term *value) {
  agc_value v = value_of(t);
  if (!agc_is(v, AGC_T_ENUM)) return false;
  const agc_enum *e = agc_as_enum(env->vm, v);
  bool is_some;
  if (!optional_variant(env->vm->rt->program, e->variant, &is_some) || (is_some && e->n < 1)) return false;
  *some = is_some;
  if (is_some) *value = term_of(e->payload[0]);
  return true;
}

static an_term api_ok(an_env *env, an_term value) {
  agc_native_dirty *d = env->dirty;
  if (d) {
    agc_value *copy = stage_values(d, &value, 1);
    if (!copy) return bad_term(env);
    d->bytes += 2 * sizeof(agc_value);
    return stage(d, N_OK, 0, 1, copy);
  }
  return term_of(agc_result_value(true, value_of(value)));
}

static an_term api_error(an_env *env, const char *message, size_t len) {
  return text_term(env, N_ERROR, message, len, "an_error got a message that is not UTF-8");
}

static bool api_get_result(an_env *env, an_term t, bool *ok, an_term *value) {
  agc_value v = value_of(t);
  if (!agc_is(v, AGC_T_RESULT)) return false;
  const agc_result *r = agc_as_result(env->vm, v);
  *ok = r->ok;
  *value = term_of(r->value);
  return true;
}

static an_term api_raise(an_env *env, const char *message) {
  return env_refuse(env, message ? message : "an_raise got no message");
}

static an_term api_badarg(an_env *env, int index) {
  char text[64];
  int n = snprintf(text, sizeof text, "argument %lld is not valid", (long long)index + 1);
  return env_fail(env, FAILED, text, (size_t)n);
}

/* The program's index of row TYPE of the module's type table when the row is of KIND and the function's signature
   reaches it, else UNBOUND. */
static uint32_t bound_type(const agc_native_fn *fn, uint32_t type, int kind) {
  if (type >= fn->type_count || fn->type_rows[type].kind != kind) return UNBOUND;
  return fn->types[type];
}

/* A struct, or an enum value with a payload, of N values: built now, or in a dirty call a node of KIND with ID. */
static an_term compound(an_env *env, uint8_t kind, uint32_t id, const an_term *items, uint32_t n) {
  if (env->dirty) return stage_items(env, kind, id, items, n);
  agc_charge_bytes(env->vm, agc_size_mul(n, sizeof(agc_value)));
  if (kind == N_STRUCT) {
    agc_struct *s = agc_new_struct(id, n);
    for (uint32_t k = 0; k < n; k++) s->fields[k] = value_of(items[k]);
    return term_of(agc_struct_value(s));
  }
  agc_enum *e = agc_new_enum(id, n);
  for (uint32_t k = 0; k < n; k++) e->payload[k] = value_of(items[k]);
  return term_of(agc_enum_value(e));
}

static an_term api_struct(an_env *env, uint32_t type, const an_term *fields) {
  uint32_t id = bound_type(env->fn, type, AN_STRUCT);
  if (id == UNBOUND) return env_refuse(env, "an_struct got a type that the function's signature does not reach");
  uint32_t n = env->vm->rt->program->structs[id].count;
  if (n && !fields) return env_refuse(env, "an_struct got no fields");
  return compound(env, N_STRUCT, id, fields, n);
}

static bool api_get_field(an_env *env, an_term t, uint32_t type, uint32_t field, an_term *out) {
  uint32_t id = bound_type(env->fn, type, AN_STRUCT);
  agc_value v = value_of(t);
  if (id == UNBOUND || !agc_is(v, AGC_T_STRUCT)) return false;
  const agc_struct *s = agc_as_struct(env->vm, v);
  if (s->type != id || field >= s->n) return false;
  *out = term_of(s->fields[field]);
  return true;
}

/* A variant without a payload is the one value the loader made for it, as the ENUM instruction gives. */
static an_term api_enum(an_env *env, uint32_t type, uint32_t variant, const an_term *payload) {
  uint32_t id = bound_type(env->fn, type, AN_ENUM);
  if (id == UNBOUND) return env_refuse(env, "an_enum got a type that the function's signature does not reach");
  const agc_program *p = env->vm->rt->program;
  if (variant >= p->enums[id].count) return env_refuse(env, "an_enum got a variant that the enum does not have");
  uint32_t at = p->enums[id].first + variant;
  const agc_variant_def *v = &p->variants[at];
  if (v->arity == 0 && v->shared) return term_of(agc_enum_value(v->shared));
  if (v->arity && !payload) return env_refuse(env, "an_enum got no payload for a variant that has one");
  return compound(env, N_ENUM, at, payload, v->arity);
}

/* The enum value of T when it is of row TYPE, with in *AT its variant's position in the enum. Allocates nothing, so a
   getter may run where GC memory may not be made. */
static const agc_enum *enum_of(an_env *env, an_term t, uint32_t type, uint32_t *at) {
  uint32_t id = bound_type(env->fn, type, AN_ENUM);
  agc_value v = value_of(t);
  if (id == UNBOUND || !agc_is(v, AGC_T_ENUM)) return NULL;
  const agc_program *p = env->vm->rt->program;
  const agc_enum *e = agc_as_enum(env->vm, v);
  if (!enum_variant(p, id, e->variant, at) || e->n != p->variants[e->variant].arity) return NULL;
  return e;
}

static bool api_get_variant(an_env *env, an_term t, uint32_t type, uint32_t *variant) {
  uint32_t at;
  if (!enum_of(env, t, type, &at)) return false;
  *variant = at;
  return true;
}

static bool api_get_payload(an_env *env, an_term t, uint32_t type, uint32_t k, an_term *out) {
  uint32_t at;
  const agc_enum *e = enum_of(env, t, type, &at);
  if (!e || k >= e->n) return false;
  *out = term_of(e->payload[k]);
  return true;
}

/* A short call makes the resource at once (vm/ffi.c: registered, owned by the calling task, coming from the call's
   resource arguments); a dirty one stages it with its state, made here in malloc memory, as a pool thread may. */
static void *api_resource_new(an_env *env, uint32_t type, an_term *out) {
  const agc_native_fn *fn = env->fn;
  if (!out) {
    (void)env_refuse(env, "an_resource_new got no place for the resource");
    return NULL;
  }
  if (type >= fn->resource_count || !fn->resources[type]) {
    *out = env_refuse(env, "an_resource_new got a resource that the function's signature does not reach");
    return NULL;
  }
  const an_resource_type *row = &fn->resource_rows[type];
  void *state = calloc(1, row->size ? row->size : 1);
  if (!state) agc_out_of_memory();
  agc_native_dirty *d = env->dirty;
  if (d) {
    d->bytes += sizeof(agc_c_resource);
    *out = stage(d, N_RESOURCE, type, 0, state);
    return state;
  }
  agc_charge_bytes(env->vm, sizeof(agc_c_resource));
  *out = term_of(agc_ffi_module_resource(env->vm, row, row->name, state, env->held, env->holds));
  return state;
}

/* Only a resource argument of the call: vm/ffi.c holds each one, so its state is not freed while C runs, also when
   another task closes it meanwhile. */
static bool api_get_resource(an_env *env, an_term t, uint32_t type, void **state) {
  agc_value v = value_of(t);
  if (!agc_is(v, AGC_T_C_RESOURCE) || type >= env->fn->resource_count) return false;
  const agc_c_resource *res = agc_as_c_resource(env->vm, v);
  for (uint32_t k = 0; k < env->holds; k++)
    if (env->held[k] == res && res->row == &env->fn->resource_rows[type]) {
      *state = res->pointer;
      return true;
    }
  return false;
}

/* The thread is marked blocked for the collector while FN runs (agc_gc_blocking), so a C library that switches to a
   stack of its own is never stopped there; a thread the collector does not know (the compute pool) runs FN as is. */
static void api_blocking(an_env *env, void (*fn)(void *arg), void *arg) {
  (void)env;
  agc_gc_blocking(fn, arg);
}

static const an_api API = {
  AN_API_MAJOR,       AN_API_MINOR,     sizeof(an_api),   api_int,          api_get_int,      api_float,
  api_get_float,      api_bool,         api_get_bool,     api_void,         api_string,       api_get_string,
  api_bytes,          api_bytes_fill,   api_get_bytes,    api_list,         api_list_begin,   api_list_push,
  api_list_end,       api_list_cursor,  api_list_next,    api_map_from,     api_map_put,      api_map_get,
  api_map_cursor,     api_map_next,     api_none,         api_some,         api_get_optional, api_ok,
  api_error,          api_get_result,   api_raise,        api_badarg,       api_struct,       api_get_field,
  api_enum,           api_get_variant,  api_get_payload,  api_resource_new, api_get_resource, api_blocking,
};
