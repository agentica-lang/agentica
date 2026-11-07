/*
 * Native modules (vm/agentica_native.h, #1149): agc_native_bind binds a "module TYPES CANON SYMBOL LIBRARY" signature
 * of Native.call to a row of a module's function table, loading the module at its first use (agentica_native_init in
 * a shared library, ffi_os.h, or a module the binary carries, agc_native_register); agc_native_call makes a short
 * call on the scheduler; and the an_api table is the VM half of the C API. vm/ffi.c keeps the bound functions in its
 * cache of the run. Service layer.
 */
#include "agentica_native.h"
#include "ffi_os.h"
#include "services.h"

#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The deepest nesting of a type in a signature (List[List[...]]); only hand-made bytecode nests deeper. */
#define TYPE_MAX_DEPTH 32
/* The most functions and types a module may declare. */
#define MODULE_MAX_FUNCTIONS 65536
#define MODULE_MAX_TYPES 65536
/* The turn cost of one short call, besides what it builds: like a fast extern call, it cannot stop in the middle. */
#define CALL_COST 64
/* The largest first block of a list builder: a bigger hint is no reason to allocate more before the pushes come. */
#define HINT_MAX 4096
#define REPLACEMENT "\xEF\xBF\xBD"
#define FAILED "RUNTIME-NATIVE-ERROR"
#define NO_OPTIONAL "no Optional enum"
/* The size of an an_module of API 1.0, the fields up to function_count: a module of a later minor version is larger,
   and the fields after these are read only when its size covers them. */
#define MODULE_SIZE_1_0 (offsetof(an_module, function_count) + sizeof(uint32_t))
/* The size of an an_module of API 1.1, which adds the type table. */
#define MODULE_SIZE_1_1 (offsetof(an_module, type_count) + sizeof(uint32_t))
/* The index of a type of the module that the function's signature does not reach (agc_native_fn.types). */
#define UNBOUND UINT32_MAX
/* About what one Map entry takes, its leaf in the table and its cell in the key list (vm/map.c), so that a Map built
   from Int keys is charged like a List of its pairs. */
#define MAP_ENTRY_BYTES (3 * sizeof(agc_value) + sizeof(agc_keys))

/* The kinds of type a signature names; KINDS has the names and how many type arguments each takes of all but the last
   two, a struct and an enum of the program, which a signature names by the bare name of a type block. */
typedef enum {
  K_INT, K_FLOAT, K_BOOL, K_STRING, K_BYTES, K_VOID, K_LIST, K_MAP, K_OPTIONAL, K_RESULT, K_STRUCT, K_ENUM
} type_kind;

/* A bound function, in malloc memory that lives as long as the cache of the run (vm/ffi.c): the module's row, the
   outer kind of each parameter and of the result (what agc_native_call checks) with the index of a struct or enum
   kind in the program's table, whether the module is one that the binary carries, which a run with no_files may call,
   and the module's type table, with TYPES[k] the program's index of row k, or UNBOUND when the signature does not
   reach it (NULL when the module has no types). */
struct agc_native_fn {
  const an_function *row;
  bool carried;
  uint32_t arity;
  uint8_t result;
  uint8_t params[AGC_FFI_MAX_PARAMS];
  uint32_t result_id;
  uint32_t param_ids[AGC_FFI_MAX_PARAMS];
  const an_type *type_rows;
  uint32_t type_count;
  uint32_t *types;
};

/* A type block of a signature, "{S<index>=SHAPE}" or "{E<index>=SHAPE}": a struct or enum of the program that the
   function's signature reaches, its index in the program's table, its name there and its shape. */
typedef struct {
  bool is_enum;
  uint32_t index;
  const agc_string *name;
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
   That bind loads it: MODULE then holds the module, or ERROR the message of every later bind, so a module that failed
   is not loaded again. */
typedef struct agc_native_library {
  struct agc_native_library *next;
  char *name;
  agc_native_init init;
  const an_module *module;
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

/* The env of one call: the table first, as an_api_of reads it. CODE and MESSAGE are the call's first failure. */
struct an_env {
  const an_api *api;
  agc_vm *vm;
  const agc_native_fn *fn;
  const char *code;
  agc_string *message;
};

/* What an an_list_builder holds: a GC array of the pushed values, which grows by doubling. */
typedef struct {
  agc_value *items;
  size_t n, cap;
} list_build;

/* What an an_map_cursor holds: the map and its keys in insertion order, taken when the walk starts. */
typedef struct {
  const agc_map *map;
  agc_value *keys;
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
static const uint32_t KIND_TAGS[] = {AGC_T_INT,  AGC_T_FLOAT, AGC_T_BOOL,   AGC_T_STRING, AGC_T_BYTES, AGC_T_VOID,
                                     AGC_T_LIST, AGC_T_MAP,   AGC_T_ENUM,   AGC_T_RESULT, AGC_T_STRUCT, AGC_T_ENUM};
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
   for an enum, with the index in range. A shape holds no brace. */
static bool next_block(const agc_program *p, const char **at, const char *end, type_block *b) {
  if (end - *at < 4 || (*at)[0] != '{' || ((*at)[1] != 'S' && (*at)[1] != 'E')) return false;
  b->is_enum = (*at)[1] == 'E';
  *at += 2;
  const char *digits = *at;
  uint64_t index = 0;
  while (*at < end && **at >= '0' && **at <= '9' && *at - digits < 10) index = index * 10 + (uint64_t)(*(*at)++ - '0');
  if (*at == digits || !skip(at, end, "=")) return false;
  const char *close = memchr(*at, '}', (size_t)(end - *at));
  if (!close || index >= (b->is_enum ? p->enum_count : p->struct_count)) return false;
  b->index = (uint32_t)index;
  b->name = b->is_enum ? p->enums[index].name : p->structs[index].name;
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
  const agc_string *x = ((const type_block *)a)->name, *y = ((const type_block *)b)->name;
  return name_order(x->data, x->bytes, y->data, y->bytes);
}

/* The block of LIST whose type is named TEXT (LEN bytes), by binary search. */
static bool find_block(const block_list *list, const char *text, size_t len, type_block *found) {
  size_t low = 0, high = list->count;
  while (low < high) {
    size_t mid = low + (high - low) / 2;
    const agc_string *name = list->items[mid].name;
    int c = name_order(text, len, name->data, name->bytes);
    if (c == 0) {
      *found = list->items[mid];
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
  const char *at = b->shape, *end = b->shape + b->shape_len;
  if (!b->is_enum) {
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
   name no other block has. At most MODULE_MAX_TYPES, as each must be a type of the module, whose names differ. Read
   once, then sorted, so a bind takes O(B log B) under rt->sync. Bad bytecode fails. */
static block_list read_blocks(agc_vm *vm, const char **at, const char *end, uint32_t span) {
  const agc_program *p = vm->rt->program;
  block_list list = {NULL, 0};
  type_block b;
  const char *start = *at;
  while (*at < end && **at == '{') {
    if (!p || list.count == MODULE_MAX_TYPES || !next_block(p, at, end, &b)) bad_signature(vm, span);
    list.count++;
  }
  if (list.count == 0) return list;
  list.items = agc_alloc(agc_size_mul(list.count, sizeof *list.items));
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
   Gives the kind of the outer type, with in *ID the program's index of a struct or enum kind, or -1 when the text is
   no canonical type. A name that is no kind is the type of a block of BLOCKS. Each turn of the loop reads a name or
   fails, so the loop ends. */
static int parse_type(const char **at, const char *end, const block_list *blocks, uint32_t *id) {
  uint8_t need[TYPE_MAX_DEPTH];
  size_t depth = 0;
  int outer = -1;
  for (;;) {
    const char *name = *at;
    while (*at < end && name_char(**at)) (*at)++;
    size_t len = (size_t)(*at - name);
    int kind = kind_named(name, len);
    type_block block = {0};
    if (kind < 0 && len && find_block(blocks, name, len, &block)) kind = block.is_enum ? K_ENUM : K_STRUCT;
    if (kind < 0) return -1;
    if (outer < 0) {
      outer = kind;
      *id = block.index;
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

static int row_order(const void *a, const void *b) {
  return strcmp((*(const an_type *const *)a)->name, (*(const an_type *const *)b)->name);
}

/* A message in ERROR (SIZE bytes) when two of the COUNT rows of a type table have one name, which would make the type
   that a signature names by it ambiguous; else NULL. Sorted copy of the rows, so a load takes O(N log N). */
static const char *twin_type(const an_type *types, uint32_t count, char *error, size_t size) {
  if (count < 2) return NULL;
  const an_type **sorted = malloc(agc_size_mul(count, sizeof *sorted));
  if (!sorted) agc_out_of_memory();
  for (uint32_t k = 0; k < count; k++) sorted[k] = &types[k];
  qsort(sorted, count, sizeof *sorted, row_order);
  const char *problem = NULL;
  for (uint32_t k = 1; k < count && !problem; k++)
    if (strcmp(sorted[k - 1]->name, sorted[k]->name) == 0) {
      snprintf(error, size, "the module's type table has two types named %.64s", sorted[k]->name);
      problem = error;
    }
  free(sorted);
  return problem;
}

/* What is wrong with the module M that an init gave, as a message in ERROR (SIZE bytes), or NULL. Only the fields of
   API 1.0 are read, which every module of major version 1 has (MODULE_SIZE_1_0), and the type table when SIZE covers
   it. */
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
  return twin_type(types, type_count, error, size);
}

/* Loads LIB: its init (the export of its library, or the one it was registered with), the checks of the module and
   its load function. NULL, or the message of the failure (malloc'd). One module named two ways ("libx.so" and its
   path) has one init, so the module that another entry of FIRST, the list of the run, loaded is taken as it is: init
   and load run once. */
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
    lib->module = other->module;
    return other->error ? agc_ffi_text_copy(other->error, strlen(other->error)) : NULL;
  }
  const an_module *m = lib->init(&API);
  const char *problem = module_problem(m, error, sizeof error);
  if (!problem && m->load) {
    const char *refused = m->load();
    if (refused) {
      snprintf(error, sizeof error, "the module refused to load: %s", refused);
      problem = error;
    }
  }
  if (problem) return agc_ffi_text_copy(problem, strlen(problem));
  lib->module = m;
  return NULL;
}

/* The module of the library NAME (LEN bytes), loaded at its first bind. Under rt->sync (vm/ffi.c, find_entry). */
static const native_library *module_of(agc_vm *vm, const char *name, size_t len, uint32_t span) {
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

/* The row of the module's type table named NAME, or NULL. */
static const an_type *type_row(const an_type *rows, uint32_t count, const agc_string *name) {
  for (uint32_t k = 0; k < count; k++)
    if (strlen(rows[k].name) == name->bytes && memcmp(rows[k].name, name->data, name->bytes) == 0) return &rows[k];
  return NULL;
}

/* Each type block must be a type of the module LIB, of its name, with the same kind and the same shape, byte for
   byte; else RUNTIME-NATIVE-SIGNATURE. */
static void check_types(agc_vm *vm, const native_library *lib, const block_list *blocks, uint32_t span) {
  const an_type *rows;
  uint32_t count = module_types(lib->module, &rows);
  for (uint32_t k = 0; k < blocks->count; k++) {
    const type_block b = blocks->items[k];
    const an_type *row = type_row(rows, count, b.name);
    int name_len = (int)b.name->bytes;
    if (!row)
      fail_with(vm, "RUNTIME-NATIVE-SIGNATURE", span, "native module %s has no type %.*s", lib->name, name_len,
                b.name->data);
    if (row->kind != (b.is_enum ? AN_ENUM : AN_STRUCT) || strlen(row->shape) != b.shape_len ||
        memcmp(row->shape, b.shape, b.shape_len) != 0)
      fail_with(vm, "RUNTIME-NATIVE-SIGNATURE", span,
                "%s %.*s in native module %s is %s, but the program declares %.*s",
                row->kind == AN_ENUM ? "enum" : "struct", name_len, b.name->data, lib->name, row->shape,
                (int)b.shape_len, b.shape);
  }
}

/* The program's index of each row of the module's type table that a block names, UNBOUND for the others; NULL for a
   module with no types. check_types found every block. */
static uint32_t *bound_types(const block_list *blocks, const an_type *rows, uint32_t count) {
  if (count == 0) return NULL;
  uint32_t *types = malloc(agc_size_mul(count, sizeof *types));
  if (!types) agc_out_of_memory();
  for (uint32_t k = 0; k < count; k++) types[k] = UNBOUND;
  for (uint32_t k = 0; k < blocks->count; k++)
    types[type_row(rows, count, blocks->items[k].name) - rows] = blocks->items[k].index;
  return types;
}

/* Binds TEXT, the LEN bytes after "module " of a signature ("TYPES CANON SYMBOL LIBRARY", DIRTY for a compute def).
   The bytecode may hold anything, so the type blocks and the canonical type are parsed with bounds, and each block
   checked against the program, before the module is asked; then the row of SYMBOL must have the same signature, byte
   for byte, and the same mode, and the module the same types. */
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
  const native_library *lib = module_of(vm, at, library_len, span);
  const an_module *m = lib->module;
  const an_function *row = NULL;
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
  if (dirty)
    fail_with(vm, "RUNTIME-NATIVE-SIGNATURE", span, "%s in native module %s: this VM does not run dirty functions yet",
              row->name, lib->name);
  check_types(vm, lib, &blocks, span);
  agc_native_fn *fn = malloc(sizeof *fn);
  if (!fn) agc_out_of_memory();
  *fn = parsed;
  fn->row = row;
  fn->carried = lib->carried;
  fn->type_count = module_types(m, &fn->type_rows);
  fn->types = bound_types(&blocks, fn->type_rows, fn->type_count);
  return fn;
}

uint32_t agc_native_arity(const agc_native_fn *fn) { return fn->arity; }

void agc_native_unbind(agc_native_fn *fn) {
  if (fn) free(fn->types);
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

/* Whether V has the outer type of KIND: its tag, for an Optional the variant of the program's Optional enum, and for
   a struct or an enum the type at ID of the program's table. */
static bool outer_matches(agc_vm *vm, uint8_t kind, uint32_t id, agc_value v) {
  if (v.tag != KIND_TAGS[kind]) return false;
  bool some;
  uint32_t at;
  switch (kind) {
  case K_OPTIONAL:
    return optional_variant(vm->rt->program, agc_as_enum(vm, v)->variant, &some);
  case K_STRUCT:
    return agc_as_struct(vm, v)->type == id;
  case K_ENUM:
    return enum_variant(vm->rt->program, id, agc_as_enum(vm, v)->variant, &at);
  default:
    return true;
  }
}

/* The module's function, with the callbacks of extern blocks refused: a short call never calls back into Agentica. */
static void run_module(void *arg) {
  module_call *call = arg;
  call->result = call->fn->row->fn(call->env, (int)call->fn->arity, call->argv);
}

/* One short call of FN with ARGS (its arity of values, which vm/ffi.c checked), on this scheduler without rt->sync:
   the module must be thread-safe (agentica_native.h). Each argument has the outer type of its parameter before C
   sees it, and the result after; a failure that the env holds fails the call once C has returned, so no longjmp
   crosses the module's frames (only out of memory, which exits, the fuzz driver's allocation limit and the
   consistency checks of vm/map.c, which a valid map never fails, leave from inside an API call). The terms C gets
   are on this stack and the values they name stay reachable from the caller's registers. */
agc_value agc_native_call(agc_vm *vm, const agc_native_fn *fn, const agc_list *args, uint32_t span) {
  if (vm->rt->no_files && !fn->carried) agc_fail(vm, "RUNTIME-NATIVE-DENIED", "native calls are off in this run", span);
  an_term argv[AGC_FFI_MAX_PARAMS];
  agc_list_cursor cursor;
  agc_list_cursor_begin(&cursor, args, 0);
  for (uint32_t k = 0; k < fn->arity; k++) {
    agc_value v;
    if (!agc_list_cursor_next(&cursor, &v) || !outer_matches(vm, fn->params[k], fn->param_ids[k], v))
      agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: a native argument of another type", span);
    argv[k] = term_of(v);
  }
  agc_charge(vm, CALL_COST);
  an_env env = {&API, vm, fn, NULL, NULL};
  module_call made = {fn, &env, argv, {{0, 0}}};
  agc_ffi_refusing_callbacks(run_module, &made);
  agc_value v = value_of(made.result);
  if (env.code) agc_fail_text(vm, env.code, env.message, span);
  if (!outer_matches(vm, fn->result, fn->result_id, v))
    fail_with(vm, FAILED, span, "%s returned a value that is not of its result type", fn->row->name);
  return v;
}

/* Keeps the first failure of the call: CODE with "NAME: TEXT" (LEN bytes, decoded, as the module's text may not be
   UTF-8). Returns Void, the value of a constructor that failed. Only GC memory is made, which the fuzz driver's
   allocation limit may leave behind. */
static an_term env_fail(an_env *env, const char *code, const char *text, size_t len) {
  if (!env->code) {
    const char *name = env->fn->row->name;
    agc_string *head = agc_concat(decoded(name, strlen(name)), decoded(": ", 2));
    env->message = agc_concat(head, decoded(text, len));
    env->code = code;
  }
  return term_of(agc_void());
}

static an_term env_refuse(an_env *env, const char *text) { return env_fail(env, FAILED, text, strlen(text)); }

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

/* The String of DATA, or NULL when it is not UTF-8. */
static agc_string *checked_string(an_env *env, const char *data, size_t len) {
  size_t chars;
  if (!agc_utf8_chars((const uint8_t *)data, len, &chars)) return NULL;
  agc_charge_bytes(env->vm, len);
  return agc_small_string(env->vm, data, len, chars);
}

static an_term api_string(an_env *env, const char *data, size_t len) {
  agc_string *s = checked_string(env, data, len);
  return s ? term_of(agc_string_value(s)) : env_refuse(env, "an_string got text that is not UTF-8");
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
  agc_charge_bytes(env->vm, len);
  return term_of(agc_bytes_value(agc_make_bytes(data, len)));
}

/* The bytes are zeroed, so a module that writes fewer than LEN shows no old memory. */
static an_term api_bytes_fill(an_env *env, size_t len, uint8_t **data) {
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

static an_term api_list(an_env *env, const an_term *items, size_t n) {
  agc_charge_bytes(env->vm, agc_size_mul(n, sizeof(agc_value)));
  agc_list_builder b;
  agc_list_builder_sized(&b, n);
  for (size_t k = 0; k < n; k++) agc_list_builder_push(&b, value_of(items[k]));
  return term_of(agc_list_value(agc_list_builder_finish(&b)));
}

/* The builder's state goes through memcpy both ways, so C's opaque words are never read as another type. The array
   is charged as it grows, by the slots each step adds, so a module that never calls an_list_end pays too, and
   list_end charges nothing more. */
static void api_list_begin(an_env *env, an_list_builder *b, size_t hint) {
  list_build build = {NULL, 0, hint < HINT_MAX ? hint : HINT_MAX};
  if (build.cap) {
    agc_charge_bytes(env->vm, build.cap * sizeof(agc_value));
    build.items = agc_alloc(build.cap * sizeof(agc_value));
  }
  memcpy(b, &build, sizeof build);
}

static void api_list_push(an_env *env, an_list_builder *b, an_term item) {
  list_build build;
  memcpy(&build, b, sizeof build);
  if (build.n == build.cap) {
    size_t cap = build.cap ? agc_size_mul(build.cap, 2) : 8;
    agc_charge_bytes(env->vm, agc_size_mul(cap - build.cap, sizeof(agc_value)));
    agc_value *items = agc_alloc(agc_size_mul(cap, sizeof(agc_value)));
    if (build.n) memcpy(items, build.items, build.n * sizeof(agc_value));
    build.items = items;
    build.cap = cap;
  }
  build.items[build.n++] = value_of(item);
  memcpy(b, &build, sizeof build);
}

static an_term api_list_end(an_env *env, an_list_builder *b) {
  list_build build;
  (void)env;
  memcpy(&build, b, sizeof build);
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

/* The keys a Map takes: an Int, a String or a Bytes (vm/map.c fails on any other). */
static bool map_key(agc_value key) {
  return agc_is(key, AGC_T_INT) || agc_is(key, AGC_T_STRING) || agc_is(key, AGC_T_BYTES);
}

static an_term api_map_from(an_env *env, const an_term *keys, const an_term *values, size_t n) {
  agc_charge_bytes(env->vm, agc_size_mul(n, MAP_ENTRY_BYTES));
  agc_map *m = agc_new_map();
  for (size_t k = 0; k < n; k++) {
    agc_value key = value_of(keys[k]);
    if (!map_key(key)) return env_refuse(env, "a Map key is an Int, a String or a Bytes");
    m = agc_map_put(env->vm, m, key, value_of(values[k]));
  }
  return term_of(agc_map_value(m));
}

static an_term api_map_put(an_env *env, an_term map, an_term key, an_term value) {
  agc_value m = value_of(map), k = value_of(key);
  if (!agc_is(m, AGC_T_MAP)) return env_refuse(env, "an_map_put got a value that is not a Map");
  if (!map_key(k)) return env_refuse(env, "a Map key is an Int, a String or a Bytes");
  agc_charge_bytes(env->vm, MAP_ENTRY_BYTES);
  return term_of(agc_map_value(agc_map_put(env->vm, agc_as_map(env->vm, m), k, value_of(value))));
}

static bool api_map_get(an_env *env, an_term map, an_term key, an_term *value) {
  agc_value m = value_of(map), k = value_of(key), found;
  if (!agc_is(m, AGC_T_MAP) || !map_key(k) || !agc_map_get(env->vm, agc_as_map(env->vm, m), k, &found)) return false;
  *value = term_of(found);
  return true;
}

static bool api_map_cursor(an_env *env, an_term map, an_map_cursor *c, size_t *len) {
  agc_value v = value_of(map);
  if (!agc_is(v, AGC_T_MAP)) return false;
  const agc_map *m = agc_as_map(env->vm, v);
  agc_charge_bytes(env->vm, agc_size_mul(m->size, sizeof(agc_value)));
  map_walk walk = {m, m->size ? agc_map_keys(env->vm, m, 0) : NULL, 0, m->size};
  memcpy(c, &walk, sizeof walk);
  if (len) *len = m->size;
  return true;
}

/* Every key of the walk is in its map, which never changes: the lookup always finds it. */
static bool api_map_next(an_env *env, an_map_cursor *c, an_term *key, an_term *value) {
  map_walk walk;
  memcpy(&walk, c, sizeof walk);
  agc_value found;
  if (walk.at == walk.n || !agc_map_get(env->vm, walk.map, walk.keys[walk.at], &found)) return false;
  *key = term_of(walk.keys[walk.at++]);
  *value = term_of(found);
  memcpy(c, &walk, sizeof walk);
  return true;
}

/* An Optional needs the program's Optional enum, which only hand-made bytecode lacks. */
static an_term optional_term(an_env *env, bool some, agc_value value) {
  const agc_program *p = env->vm->rt->program;
  if (!p || p->optional == UINT32_MAX) return env_fail(env, "RUNTIME-INTERNAL", NO_OPTIONAL, sizeof NO_OPTIONAL - 1);
  return term_of(agc_optional_make(p, some, value));
}

static an_term api_none(an_env *env) { return optional_term(env, false, agc_void()); }

static an_term api_some(an_env *env, an_term value) { return optional_term(env, true, value_of(value)); }

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
  (void)env;
  return term_of(agc_result_value(true, value_of(value)));
}

static an_term api_error(an_env *env, const char *message, size_t len) {
  agc_string *s = checked_string(env, message, len);
  return s ? term_of(agc_result_value(false, agc_string_value(s)))
           : env_refuse(env, "an_error got a message that is not UTF-8");
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

static an_term api_struct(an_env *env, uint32_t type, const an_term *fields) {
  uint32_t id = bound_type(env->fn, type, AN_STRUCT);
  if (id == UNBOUND) return env_refuse(env, "an_struct got a type that the function's signature does not reach");
  uint32_t n = env->vm->rt->program->structs[id].count;
  if (n && !fields) return env_refuse(env, "an_struct got no fields");
  agc_charge_bytes(env->vm, agc_size_mul(n, sizeof(agc_value)));
  agc_struct *s = agc_new_struct(id, n);
  for (uint32_t k = 0; k < n; k++) s->fields[k] = value_of(fields[k]);
  return term_of(agc_struct_value(s));
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
  agc_charge_bytes(env->vm, agc_size_mul(v->arity, sizeof(agc_value)));
  agc_enum *e = agc_new_enum(at, v->arity);
  for (uint32_t k = 0; k < v->arity; k++) e->payload[k] = value_of(payload[k]);
  return term_of(agc_enum_value(e));
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

static const an_api API = {
  AN_API_MAJOR,     AN_API_MINOR,     sizeof(an_api),   api_int,          api_get_int,      api_float,
  api_get_float,    api_bool,         api_get_bool,     api_void,         api_string,       api_get_string,
  api_bytes,        api_bytes_fill,   api_get_bytes,    api_list,         api_list_begin,   api_list_push,
  api_list_end,     api_list_cursor,  api_list_next,    api_map_from,     api_map_put,      api_map_get,
  api_map_cursor,   api_map_next,     api_none,         api_some,         api_get_optional, api_ok,
  api_error,        api_get_result,   api_raise,        api_badarg,       api_struct,       api_get_field,
  api_enum,         api_get_variant,  api_get_payload,
};
