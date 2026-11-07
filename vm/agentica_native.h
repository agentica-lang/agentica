/*
 * The C API of native modules (#1149): a shared library that exports agentica_native_init and calls the VM only
 * through the table of function pointers (an_api) that every call's env carries, so it links nothing from the
 * agentica binary. Values are opaque terms, read through checked getters. Version 1.1: short calls of scalars,
 * String, Bytes, List, Map, Optional, Result and the program's structs and enums (1.0 had no structs and enums). The
 * VM half is vm/native_module.c; this header is the contract, and it includes nothing of the VM.
 */
#ifndef AGENTICA_NATIVE_H
#define AGENTICA_NATIVE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The API this header describes. The VM loads a module of the same major version and a minor version up to its own:
   an_api and an_module only grow at their end, which is a minor bump. */
#define AN_API_MAJOR 1
#define AN_API_MINOR 1

#if defined(_WIN32)
#define AN_EXPORT __declspec(dllexport)
#else
#define AN_EXPORT __attribute__((visibility("default")))
#endif

/* A value. Its layout is not part of the contract: read it only through the getters. A term is valid until the
   function that got or made it returns: keep it in C locals (the collector scans the C stack), never in static data,
   malloc memory or a resource. */
typedef struct {
  uint64_t opaque[2];
} an_term;

/* One call: the VM, the task and the failure of the call. Valid only during the call. */
typedef struct an_env an_env;

/* A List built one item at a time (an_list_begin, an_list_push, an_list_end), and a walk over a List or a Map. All
   three are opaque, live on the C stack and hold terms, so the rule of an_term applies to them. */
typedef struct {
  uint64_t opaque[8];
} an_list_builder;
typedef struct {
  uint64_t opaque[8];
} an_list_cursor;
typedef struct {
  uint64_t opaque[8];
} an_map_cursor;

/* A function of a module. ARGC is the arity of its signature and ARGV the arguments, each of the declared type at its
   top level (nested values are checked by the getters). Its result is the call's value, unless an_raise, an_badarg or
   a constructor failed during the call: then the call fails with RUNTIME-NATIVE-ERROR, whatever it returns. */
typedef an_term (*an_fn)(an_env *env, int argc, const an_term *argv);

/* The mode of a function (an_function.flags). A short function runs on the calling scheduler, at the same time as
   the calls of other schedulers, so it must be thread-safe; it may allocate and build large results, but never block,
   sleep, wait on I/O, call back into Agentica (a callback of an extern block that it starts runs nothing and gives
   zero) or run longer than about 100 microseconds. A dirty function (a compute
   def) runs on the compute pool; this VM does not run them yet. */
enum { AN_SHORT = 0, AN_DIRTY = 1 };

/* A row of the module's function table. NAME is the Agentica name (`autocommit?` included), SIGNATURE its canonical
   Agentica type, "(Int, String) -> List[Int]": parameters in parentheses separated by ", ", then " -> " and the
   result; Map[K, V] has ", " too. The VM binds a call only when the program declares the same name, the same
   signature, byte for byte, and the same mode. */
typedef struct {
  const char *name;
  const char *signature;
  an_fn fn;
  unsigned flags;
} an_function;

/* The kind of a type of a module (an_type.kind). */
enum { AN_STRUCT = 0, AN_ENUM = 1 };

/* A struct or enum of the program that the module's functions take or return (API 1.1). NAME is its bare name and
   SHAPE its fields or variants in declared order, with their canonical types: "id: Int, tags: List[String]" for a
   struct, "Null | Int(Int) | Pair(Int, Point)" for an enum. The VM binds a function only when the program declares
   every user type of its signature (nested ones too) with the same name, kind and shape, byte for byte. The index of
   the row in the module's table is the TYPE that an_struct, an_get_field, an_enum and an_get_variant take; fields and
   variants count from 0 in declared order. */
typedef struct {
  const char *name;
  int kind;
  const char *shape;
} an_type;

/* What agentica_native_init returns, in static memory. MAJOR, MINOR and SIZE are the API the module was built for
   (AN_API_MAJOR, AN_API_MINOR, sizeof(an_module)): fields are only ever added at the end, so SIZE tells the VM which
   ones a module has (a 1.0 module ends at function_count). LOAD runs once, right after agentica_native_init, and
   returns NULL, or a message that refuses the module (RUNTIME-NATIVE-LOAD). */
typedef struct an_module {
  uint32_t major, minor, size;
  const char *name;
  const char *(*load)(void);
  const an_function *functions;
  uint32_t function_count;
  const an_type *types;
  uint32_t type_count;
} an_module;

/* The table of the VM's functions; each wrapper below calls one. Fields are only ever added at its end. */
typedef struct an_api {
  uint32_t major, minor, size;
  an_term (*make_int)(an_env *env, int64_t n);
  bool (*get_int)(an_env *env, an_term t, int64_t *n);
  an_term (*make_float)(an_env *env, double x);
  bool (*get_float)(an_env *env, an_term t, double *x);
  an_term (*make_bool)(an_env *env, bool b);
  bool (*get_bool)(an_env *env, an_term t, bool *b);
  an_term (*make_void)(an_env *env);
  an_term (*make_string)(an_env *env, const char *data, size_t len);
  bool (*get_string)(an_env *env, an_term t, const char **data, size_t *len);
  an_term (*make_bytes)(an_env *env, const void *data, size_t len);
  an_term (*bytes_fill)(an_env *env, size_t len, uint8_t **data);
  bool (*get_bytes)(an_env *env, an_term t, const uint8_t **data, size_t *len);
  an_term (*make_list)(an_env *env, const an_term *items, size_t n);
  void (*list_begin)(an_env *env, an_list_builder *b, size_t hint);
  void (*list_push)(an_env *env, an_list_builder *b, an_term item);
  an_term (*list_end)(an_env *env, an_list_builder *b);
  bool (*list_cursor)(an_env *env, an_term list, an_list_cursor *c, size_t *len);
  bool (*list_next)(an_env *env, an_list_cursor *c, an_term *item);
  an_term (*map_from)(an_env *env, const an_term *keys, const an_term *values, size_t n);
  an_term (*map_put)(an_env *env, an_term map, an_term key, an_term value);
  bool (*map_get)(an_env *env, an_term map, an_term key, an_term *value);
  bool (*map_cursor)(an_env *env, an_term map, an_map_cursor *c, size_t *len);
  bool (*map_next)(an_env *env, an_map_cursor *c, an_term *key, an_term *value);
  an_term (*make_none)(an_env *env);
  an_term (*make_some)(an_env *env, an_term value);
  bool (*get_optional)(an_env *env, an_term t, bool *some, an_term *value);
  an_term (*make_ok)(an_env *env, an_term value);
  an_term (*make_error)(an_env *env, const char *message, size_t len);
  bool (*get_result)(an_env *env, an_term t, bool *ok, an_term *value);
  an_term (*raise)(an_env *env, const char *message);
  an_term (*badarg)(an_env *env, int index);
  an_term (*make_struct)(an_env *env, uint32_t type, const an_term *fields);
  bool (*get_field)(an_env *env, an_term t, uint32_t type, uint32_t field, an_term *out);
  an_term (*make_enum)(an_env *env, uint32_t type, uint32_t variant, const an_term *payload);
  bool (*get_variant)(an_env *env, an_term t, uint32_t type, uint32_t *variant, const an_term **payload);
} an_api;

/* The one export of a module: the VM calls it once per run (a process runs one program), at the first call, with the
   table it will pass in every env (API->minor says which fields it has). */
typedef const an_module *(*an_init)(const an_api *api);

/* The number of rows of a table that is an array. */
#define AN_COUNT(TABLE) ((uint32_t)(sizeof(TABLE) / sizeof((TABLE)[0])))

/* Defines agentica_native_init for a module NAME with the function table FUNCTIONS and LOAD (or NULL); AN_MODULE_TYPES
   adds the type table TYPES. Both tables are arrays. */
#define AN_MODULE(NAME, FUNCTIONS, LOAD) AN_MODULE_TABLES_(NAME, FUNCTIONS, AN_COUNT(FUNCTIONS), NULL, 0, LOAD)
#define AN_MODULE_TYPES(NAME, FUNCTIONS, TYPES, LOAD) \
  AN_MODULE_TABLES_(NAME, FUNCTIONS, AN_COUNT(FUNCTIONS), TYPES, AN_COUNT(TYPES), LOAD)
#define AN_MODULE_TABLES_(NAME, FUNCTIONS, FUNCTION_COUNT, TYPES, TYPE_COUNT, LOAD)                       \
  AN_EXPORT const an_module *agentica_native_init(const an_api *api);                                    \
  AN_EXPORT const an_module *agentica_native_init(const an_api *api) {                                   \
    static const an_module an_module_value = {AN_API_MAJOR, AN_API_MINOR, sizeof(an_module), NAME, LOAD, \
                                              FUNCTIONS, FUNCTION_COUNT, TYPES, TYPE_COUNT};               \
    (void)api;                                                                                           \
    return &an_module_value;                                                                             \
  }

/* The table of the call: the VM's env starts with a pointer to it. */
static inline const an_api *an_api_of(an_env *env) { return *(const an_api *const *)(const void *)env; }

/* Scalars. Each getter returns false, and leaves its output alone, when the term is of another type. */
static inline an_term an_int(an_env *env, int64_t n) { return an_api_of(env)->make_int(env, n); }
static inline bool an_get_int(an_env *env, an_term t, int64_t *n) { return an_api_of(env)->get_int(env, t, n); }
static inline an_term an_float(an_env *env, double x) { return an_api_of(env)->make_float(env, x); }
static inline bool an_get_float(an_env *env, an_term t, double *x) { return an_api_of(env)->get_float(env, t, x); }
static inline an_term an_bool(an_env *env, bool b) { return an_api_of(env)->make_bool(env, b); }
static inline bool an_get_bool(an_env *env, an_term t, bool *b) { return an_api_of(env)->get_bool(env, t, b); }
static inline an_term an_void(an_env *env) { return an_api_of(env)->make_void(env); }

/* String: the data is UTF-8 (an_string fails the call on bad UTF-8) and has no NUL at its end. What an_get_string
   gives is borrowed, read-only, and lasts for the call: copy it to keep it. */
static inline an_term an_string(an_env *env, const char *data, size_t len) {
  return an_api_of(env)->make_string(env, data, len);
}
static inline bool an_get_string(an_env *env, an_term t, const char **data, size_t *len) {
  return an_api_of(env)->get_string(env, t, data, len);
}

/* Bytes. an_bytes_fill makes LEN zeroed bytes and gives where they are: write them before the function returns. */
static inline an_term an_bytes(an_env *env, const void *data, size_t len) {
  return an_api_of(env)->make_bytes(env, data, len);
}
static inline an_term an_bytes_fill(an_env *env, size_t len, uint8_t **data) {
  return an_api_of(env)->bytes_fill(env, len, data);
}
static inline bool an_get_bytes(an_env *env, an_term t, const uint8_t **data, size_t *len) {
  return an_api_of(env)->get_bytes(env, t, data, len);
}

/* List: an_list copies N items; a builder takes any number of pushes (HINT is the expected count); a cursor walks a
   List in order, and an_list_next returns false at its end. */
static inline an_term an_list(an_env *env, const an_term *items, size_t n) {
  return an_api_of(env)->make_list(env, items, n);
}
static inline void an_list_begin(an_env *env, an_list_builder *b, size_t hint) {
  an_api_of(env)->list_begin(env, b, hint);
}
static inline void an_list_push(an_env *env, an_list_builder *b, an_term item) {
  an_api_of(env)->list_push(env, b, item);
}
static inline an_term an_list_end(an_env *env, an_list_builder *b) { return an_api_of(env)->list_end(env, b); }
static inline bool an_list_cursor_begin(an_env *env, an_term list, an_list_cursor *c, size_t *len) {
  return an_api_of(env)->list_cursor(env, list, c, len);
}
static inline bool an_list_next(an_env *env, an_list_cursor *c, an_term *item) {
  return an_api_of(env)->list_next(env, c, item);
}

/* Map: persistent, so an_map_put returns a new Map. A key is an Int, a String or a Bytes; another key fails the
   call. an_map_from builds one in a single pass (a row); a cursor walks the pairs in insertion order. */
static inline an_term an_map_from(an_env *env, const an_term *keys, const an_term *values, size_t n) {
  return an_api_of(env)->map_from(env, keys, values, n);
}
static inline an_term an_map_put(an_env *env, an_term map, an_term key, an_term value) {
  return an_api_of(env)->map_put(env, map, key, value);
}
static inline bool an_map_get(an_env *env, an_term map, an_term key, an_term *value) {
  return an_api_of(env)->map_get(env, map, key, value);
}
static inline bool an_map_cursor_begin(an_env *env, an_term map, an_map_cursor *c, size_t *len) {
  return an_api_of(env)->map_cursor(env, map, c, len);
}
static inline bool an_map_next(an_env *env, an_map_cursor *c, an_term *key, an_term *value) {
  return an_api_of(env)->map_next(env, c, key, value);
}

/* Optional and Result. The error of a Result carries a String message, as in the language. */
static inline an_term an_none(an_env *env) { return an_api_of(env)->make_none(env); }
static inline an_term an_some(an_env *env, an_term value) { return an_api_of(env)->make_some(env, value); }
static inline bool an_get_optional(an_env *env, an_term t, bool *some, an_term *value) {
  return an_api_of(env)->get_optional(env, t, some, value);
}
static inline an_term an_ok(an_env *env, an_term value) { return an_api_of(env)->make_ok(env, value); }
static inline an_term an_error(an_env *env, const char *message, size_t len) {
  return an_api_of(env)->make_error(env, message, len);
}
static inline bool an_get_result(an_env *env, an_term t, bool *ok, an_term *value) {
  return an_api_of(env)->get_result(env, t, ok, value);
}

/* Structs and enums of the module's type table (an_type). an_struct takes one term per field, in declared order;
   an_enum takes the variant's payload (NULL for a variant without one). A TYPE that is not a row of the table, or
   whose type the function's signature does not reach, a field or variant out of range, or a missing payload fails the
   call. The getters return false for a term of another type; an_get_variant gives the payload as an array that lasts
   for the call (NULL for a variant without one). */
static inline an_term an_struct(an_env *env, uint32_t type, const an_term *fields) {
  return an_api_of(env)->make_struct(env, type, fields);
}
static inline bool an_get_field(an_env *env, an_term t, uint32_t type, uint32_t field, an_term *out) {
  return an_api_of(env)->get_field(env, t, type, field, out);
}
static inline an_term an_enum(an_env *env, uint32_t type, uint32_t variant, const an_term *payload) {
  return an_api_of(env)->make_enum(env, type, variant, payload);
}
static inline bool an_get_variant(an_env *env, an_term t, uint32_t type, uint32_t *variant,
                                  const an_term **payload) {
  return an_api_of(env)->get_variant(env, t, type, variant, payload);
}

/* Failures: the call fails with RUNTIME-NATIVE-ERROR once the function returns, with MESSAGE (copied now; NUL
   terminated) or "argument INDEX + 1 is not valid". The first failure of a call wins. Both return Void, so a function
   can `return an_raise(env, "...")`. */
static inline an_term an_raise(an_env *env, const char *message) { return an_api_of(env)->raise(env, message); }
static inline an_term an_badarg(an_env *env, int index) { return an_api_of(env)->badarg(env, index); }

#ifdef __cplusplus
}
#endif

#endif
