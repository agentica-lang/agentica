/*
 * Native modules (vm/agentica_native.h, #1149): agc_native_bind binds a "module CANON SYMBOL LIBRARY" signature of
 * Native.call to a row of a module's function table, loading the module at its first use (agentica_native_init in
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
/* The most functions a module may declare. */
#define MODULE_MAX_FUNCTIONS 65536
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
/* About what one Map entry takes, its leaf in the table and its cell in the key list (vm/map.c), so that a Map built
   from Int keys is charged like a List of its pairs. */
#define MAP_ENTRY_BYTES (3 * sizeof(agc_value) + sizeof(agc_keys))

/* The kinds of type a signature names; KINDS has their names and how many type arguments each takes. */
typedef enum { K_INT, K_FLOAT, K_BOOL, K_STRING, K_BYTES, K_VOID, K_LIST, K_MAP, K_OPTIONAL, K_RESULT } type_kind;

/* A bound function, in malloc memory that lives as long as the cache of the run (vm/ffi.c): the module's row, the
   outer kind of each parameter and of the result (what agc_native_call checks), and whether the module is one that
   the binary carries, which a run with no_files may call. */
struct agc_native_fn {
  const an_function *row;
  bool carried;
  uint32_t arity;
  uint8_t result;
  uint8_t params[AGC_FFI_MAX_PARAMS];
};

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
static const uint32_t KIND_TAGS[] = {AGC_T_INT,  AGC_T_FLOAT, AGC_T_BOOL, AGC_T_STRING, AGC_T_BYTES,
                                     AGC_T_VOID, AGC_T_LIST,  AGC_T_MAP,  AGC_T_ENUM,   AGC_T_RESULT};
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

/* Reads one type at *AT, before END, with no recursion: NEED[d] counts the type arguments still to read at depth d.
   Gives the kind of the outer type, or -1 when the text is no canonical type. Each turn of the loop reads a name or
   fails, so the loop ends. */
static int parse_type(const char **at, const char *end) {
  uint8_t need[TYPE_MAX_DEPTH];
  size_t depth = 0;
  int outer = -1;
  for (;;) {
    const char *name = *at;
    while (*at < end && ((**at >= 'A' && **at <= 'Z') || (**at >= 'a' && **at <= 'z'))) (*at)++;
    int kind = kind_named(name, (size_t)(*at - name));
    if (kind < 0) return -1;
    if (outer < 0) outer = kind;
    if (KINDS[kind].arity) {
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

/* Reads "(T, ...) -> R" at *AT into FN's arity and kinds. A parameter is never Void. */
static bool parse_canon(const char **at, const char *end, agc_native_fn *fn) {
  if (!skip(at, end, "(")) return false;
  if (!skip(at, end, ")")) {
    for (;;) {
      int kind = fn->arity < AGC_FFI_MAX_PARAMS ? parse_type(at, end) : -1;
      if (kind < 0 || kind == K_VOID) return false;
      fn->params[fn->arity++] = (uint8_t)kind;
      if (skip(at, end, ")")) break;
      if (!skip(at, end, ", ")) return false;
    }
  }
  int result = skip(at, end, " -> ") ? parse_type(at, end) : -1;
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

/* What is wrong with the module M that an init gave, as a message in ERROR (SIZE bytes), or NULL. Only the fields of
   API 1.0 are read, which every module of major version 1 has (MODULE_SIZE_1_0). */
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
  return NULL;
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

/* Binds TEXT, the LEN bytes after "module " of a signature ("CANON SYMBOL LIBRARY", DIRTY for a compute def). The
   bytecode may hold anything, so the canonical type is parsed with bounds before the module is asked; then the row of
   SYMBOL must have the same signature, byte for byte, and the same mode. */
agc_native_fn *agc_native_bind(agc_vm *vm, const char *text, size_t len, bool dirty, uint32_t span) {
  const char *at = text, *end = text + len;
  agc_native_fn parsed = {0};
  if (!parse_canon(&at, end, &parsed)) bad_signature(vm, span);
  size_t canon_len = (size_t)(at - text);
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
  if (strlen(row->signature) != canon_len || memcmp(row->signature, text, canon_len) != 0)
    fail_with(vm, "RUNTIME-NATIVE-SIGNATURE", span, "%s in native module %s is %s, but the program declares %.*s",
              row->name, lib->name, row->signature, (int)canon_len, text);
  if (((row->flags & AN_DIRTY) != 0) != dirty)
    fail_with(vm, "RUNTIME-NATIVE-SIGNATURE", span, "%s in native module %s is %s, but the program declares a %s",
              row->name, lib->name, dirty ? "short function" : "dirty function", dirty ? "compute def" : "def");
  if (dirty)
    fail_with(vm, "RUNTIME-NATIVE-SIGNATURE", span, "%s in native module %s: this VM does not run dirty functions yet",
              row->name, lib->name);
  agc_native_fn *fn = malloc(sizeof *fn);
  if (!fn) agc_out_of_memory();
  *fn = parsed;
  fn->row = row;
  fn->carried = lib->carried;
  return fn;
}

uint32_t agc_native_arity(const agc_native_fn *fn) { return fn->arity; }

void agc_native_unbind(agc_native_fn *fn) { free(fn); }

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

/* Whether V has the outer type of KIND: its tag, and for an Optional the variant of the program's Optional enum. */
static bool outer_matches(agc_vm *vm, uint8_t kind, agc_value v) {
  if (v.tag != KIND_TAGS[kind]) return false;
  bool some;
  return kind != K_OPTIONAL || optional_variant(vm->rt->program, agc_as_enum(vm, v)->variant, &some);
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
    if (!agc_list_cursor_next(&cursor, &v) || !outer_matches(vm, fn->params[k], v))
      agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: a native argument of another type", span);
    argv[k] = term_of(v);
  }
  agc_charge(vm, CALL_COST);
  an_env env = {&API, vm, fn, NULL, NULL};
  module_call made = {fn, &env, argv, {{0, 0}}};
  agc_ffi_refusing_callbacks(run_module, &made);
  agc_value v = value_of(made.result);
  if (env.code) agc_fail_text(vm, env.code, env.message, span);
  if (!outer_matches(vm, fn->result, v))
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

/* The builder's state goes through memcpy both ways, so C's opaque words are never read as another type. */
static void api_list_begin(an_env *env, an_list_builder *b, size_t hint) {
  (void)env;
  list_build build = {NULL, 0, hint < HINT_MAX ? hint : HINT_MAX};
  if (build.cap) build.items = agc_alloc(build.cap * sizeof(agc_value));
  memcpy(b, &build, sizeof build);
}

static void api_list_push(an_env *env, an_list_builder *b, an_term item) {
  (void)env;
  list_build build;
  memcpy(&build, b, sizeof build);
  if (build.n == build.cap) {
    size_t cap = build.cap ? agc_size_mul(build.cap, 2) : 8;
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
  memcpy(&build, b, sizeof build);
  agc_charge_bytes(env->vm, agc_size_mul(build.n, sizeof(agc_value)));
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

static const an_api API = {
  AN_API_MAJOR,     AN_API_MINOR,     sizeof(an_api),   api_int,          api_get_int,      api_float,
  api_get_float,    api_bool,         api_get_bool,     api_void,         api_string,       api_get_string,
  api_bytes,        api_bytes_fill,   api_get_bytes,    api_list,         api_list_begin,   api_list_push,
  api_list_end,     api_list_cursor,  api_list_next,    api_map_from,     api_map_put,      api_map_get,
  api_map_cursor,   api_map_next,     api_none,         api_some,         api_get_optional, api_ok,
  api_error,        api_get_result,   api_raise,        api_badarg,
};
